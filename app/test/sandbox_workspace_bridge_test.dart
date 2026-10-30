// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **B5：沙箱与 App 工作区打通**（2026-10-30）—— `userws` 挂载 + workdir + SAF 回退。
//
// ============================================================================
// 这个文件锁住什么（先红后绿 + 变异验证过的行为）
// ============================================================================
// 1. **物理工作区**（App 私有外部目录）⇒ 幂等注册
//    `userws = HOST_PRIVATE_DIR(hostPath=工作区) + bindTo=/opt/ws-real`，
//    且沙箱执行默认 `workdir=/opt/ws-real` —— 这样 `ls` 看到的就是用户文件。
// 2. **幂等**：同一能力实例连跑两条命令只注册一次；新实例看到已注册的同形状
//    挂载点就跳过（`mounted(already)`）。
// 3. **SAF 工作区没有物理路径** ⇒ **不挂载**、`workdir=/workspace`，并在结果里
//    如实写"两套 FS"（每实例只提示一次）。
// 4. **挂载失败如实报错**：继续以 `/workspace` 跑，但把失败原因写进结果，
//    **不假装**挂上了。
// 5. **reset 只回滚 rootfs，不删用户工作区**：不产生任何删文件/卸挂载调用；
//    重置后下次执行会重新注册（幂等）。
// 6. **只挂工作区根**：不额外挂 sessions / keys / memory / shared_prefs 等私有目录。
// 7. **装配层不漏传**：`buildDeviceCapabilities(includeSandbox:true)` 必须把
//    `workspaceRoot` 传给沙箱能力（与 git 那次漏传同类回归）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/sandbox_service.dart';
import 'package:heracles_backend/heracles_backend.dart';

const String kPhysicalWorkspace =
    '/storage/emulated/0/Android/data/com.theohowie.heracles/files/app-workspace';
const String kSafWorkspace = '/storage/emulated/0/Documents/my-project';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SandboxChannelClient.channelName);
  const outputChannel = MethodChannel(SandboxChannelClient.outputChannelName);

  final calls = <String>[];
  final registerArgs = <Map<String, Object?>>[];
  final executeArgs = <Map<String, Object?>>[];
  final mounted = <Map<String, Object?>>[];

  Future<void> push(String method, Map<String, Object?> args) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      SandboxChannelClient.outputChannelName,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  /// 假 Kotlin 沙箱：status 就绪；execute 立刻吐输出 + done；register/list 记账。
  ///
  /// [onReset] 用来模拟「宿主 rootfs reset 的真实删除范围」——真实 Kotlin 只删
  /// rootfs 目录/快照，**不碰用户工作区**（工作区是 bind 源，在 rootfs 之外）。
  void mockSandbox({
    bool registerOk = true,
    String registerError = 'backend 校验失败: bindTo 不在白名单',
    void Function()? onReset,
    List<Map<String, Object?>>? resetArgs,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final args =
          (call.arguments as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
      switch (call.method) {
        case 'status':
        case 'activate':
          return <String, Object?>{
            'ok': true,
            'installed': true,
            'rootfsSummary': 'bundled-minimal',
            'prootReady': true,
            'channels': <Object?>[],
          };
        case 'listMounts':
          return <String, Object?>{
            'ok': true,
            'mounts': mounted.map((m) => Map<String, Object?>.from(m)).toList(),
          };
        case 'registerMount':
          registerArgs.add(Map<String, Object?>.from(args));
          if (!registerOk) {
            return <String, Object?>{'ok': false, 'error': registerError};
          }
          // 模拟 Kotlin MountRegistry：同名覆盖
          mounted.removeWhere((m) => m['name'] == args['name']);
          mounted.add(<String, Object?>{
            'name': args['name'],
            'backend': args['backend'],
            'readOnly': args['readOnly'],
            'bindTo': args['bindTo'],
            'description': args['description'],
          });
          return <String, Object?>{'ok': true};
        case 'execute':
          executeArgs.add(Map<String, Object?>.from(args));
          scheduleMicrotask(() async {
            await push('output', <String, Object?>{
              'id': 'x',
              'stream': 1,
              'chunk': 'ok',
            });
            await push('done', <String, Object?>{
              'id': 'x',
              'result': <String, Object?>{
                'exitCode': 0,
                'stdout': 'ok',
                'stderr': '',
                'durationMs': 3,
                'timedOut': false,
                'cancelled': false,
                'truncated': false,
              },
            });
          });
          return <String, Object?>{'ok': true, 'id': 'x'};
        case 'reset':
          resetArgs?.add(Map<String, Object?>.from(args));
          onReset?.call();
          return <String, Object?>{
            'ok': true,
            'installed': true,
            'rootfsSummary': 'bundled-minimal (reset)',
            'prootReady': true,
            'channels': <Object?>[],
          };
        default:
          return <String, Object?>{'ok': false, 'error': '未知方法 ${call.method}'};
      }
    });
  }

  setUp(() {
    calls.clear();
    registerArgs.clear();
    executeArgs.clear();
    mounted.clear();
    mockSandbox();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(outputChannel, null);
  });

  group('物理工作区 ⇒ userws 挂载 + workdir=/opt/ws-real', () {
    test('★★★ 注册 userws（HOST_PRIVATE_DIR + bindTo）/opt/ws-real）且执行 workdir 透传',
        () async {
      final cap = ChannelSandboxCapability(workspacePath: kPhysicalWorkspace);

      final r = await cap.run('ls');

      expect(r, isA<CapabilitySuccess>());
      expect(registerArgs, hasLength(1), reason: '物理工作区必须注册一个 userws 挂载');
      final reg = registerArgs.single;
      expect(reg['name'], 'userws');
      expect(reg['backend'], SandboxMountBackend.hostPrivateDir.wireValue);
      expect(reg['hostPath'], kPhysicalWorkspace,
          reason: '★ hostPath 必须是用户工作区本身');
      expect(reg['bindTo'], '/opt/ws-real',
          reason: '★ /opt 在 ProotEngine.ALLOWED_BIND_TARGETS 白名单内');
      expect(reg['readOnly'], isFalse, reason: '要能写回，必须读写挂载');

      expect(executeArgs.single['workdir'], '/opt/ws-real',
          reason: '★ 默认工作目录必须是挂载点，否则 ls 看到的还是沙箱自己的目录');
      final md = (r as CapabilitySuccess).metadata!;
      expect(md['workdir'], '/opt/ws-real');
      expect(md['userwsMount'], 'mounted');
    });

    test('★★★ 幂等：同实例两条命令只注册一次；新实例看到已注册则跳过', () async {
      final cap = ChannelSandboxCapability(workspacePath: kPhysicalWorkspace);
      await cap.run('ls');
      await cap.run('pwd');
      expect(registerArgs, hasLength(1), reason: '同实例不允许每条命令都 register');

      // 模拟"下一次 run"的新实例：注册表里已经有同形状挂载点
      final cap2 = ChannelSandboxCapability(workspacePath: kPhysicalWorkspace);
      final r2 = await cap2.run('ls');
      expect(registerArgs, hasLength(1),
          reason: '★ 已注册同形状挂载点 ⇒ 跳过 register（幂等）');
      expect(executeArgs.last['workdir'], '/opt/ws-real');
      expect((r2 as CapabilitySuccess).metadata!['userwsMount'],
          'mounted(already)');
    });

    test('★★ 只挂工作区根：不额外挂 sessions/keys/memory/shared_prefs', () async {
      final cap = ChannelSandboxCapability(workspacePath: kPhysicalWorkspace);
      await cap.run('ls');

      expect(registerArgs, hasLength(1), reason: '只能有 userws 一个挂载');
      final hostPaths = registerArgs.map((a) => '${a['hostPath']}');
      for (final p in hostPaths) {
        expect(p, kPhysicalWorkspace);
        expect(p.contains('/sessions'), isFalse);
        expect(p.contains('/memory'), isFalse);
        expect(p.toLowerCase().contains('key'), isFalse);
        expect(p.contains('shared_prefs'), isFalse);
      }
    });
  });

  group('SAF 工作区（无物理路径）⇒ 不挂载 + 如实提示', () {
    test('★★★ 不注册挂载、workdir=/workspace，且结果首次说明"两套 FS"', () async {
      final cap = ChannelSandboxCapability(workspacePath: kSafWorkspace);
      final ok1 = (await cap.run('ls')) as CapabilitySuccess;
      final text1 = ok1.data;

      expect(registerArgs, isEmpty,
          reason: '★ SAF 没有物理路径 —— 绝不能拿一个 App 写不了的路径去 bind');
      expect(executeArgs.single['workdir'], '/workspace',
          reason: 'SAF 回退：保持 guest /workspace');
      expect(text1, contains('SAF'));
      expect(text1, contains('两套 FS'),
          reason: '必须如实告诉模型"那是沙箱自己的 FS"，别让它在 shell 里找用户文件');
      expect(ok1.metadata!['userwsMount'], 'saf-no-physical-path');

      // 提示只给一次（不污染每条命令输出）
      final ok2 = (await cap.run('pwd')) as CapabilitySuccess;
      expect(ok2.data, isNot(contains('两套 FS')));
    });

    test('★★ 显式 workspaceIsSaf 覆盖优先于路径形状（测试缝）', () async {
      // 路径看着像物理路径，但调用方明确说这是 SAF ⇒ 必须按 SAF 处理
      final cap = ChannelSandboxCapability(
        workspacePath: kPhysicalWorkspace,
        workspaceIsSaf: true,
      );
      await cap.run('ls');
      expect(registerArgs, isEmpty);
      expect(executeArgs.single['workdir'], '/workspace');
    });
  });

  group('挂载失败 ⇒ 如实报错，不假装', () {
    test('★★★ 注册失败：继续在 /workspace 跑，但结果写明失败原因', () async {
      mockSandbox(registerOk: false, registerError: 'bindTo 不在白名单');
      final cap = ChannelSandboxCapability(workspacePath: kPhysicalWorkspace);

      final r = await cap.run('ls');
      final ok = r as CapabilitySuccess;

      expect(registerArgs, hasLength(1));
      expect(executeArgs.single['workdir'], '/workspace',
          reason: '挂不上就回退到沙箱自己的工作区');
      expect(ok.data, contains('挂载失败'));
      expect(ok.data, contains('bindTo 不在白名单'),
          reason: '★ 宿主给的原因要原样带给模型，不能吞');
      expect(ok.metadata!['userwsMount'], 'failed');
    });
  });

  group('reset 不删用户工作区', () {
    test('★★★ reset 只调沙箱 reset；不产生任何删文件/卸挂载调用；之后会重新注册（幂等）',
        () async {
      final cap = ChannelSandboxCapability(workspacePath: kPhysicalWorkspace);
      await cap.run('ls');
      expect(registerArgs, hasLength(1));

      calls.clear();
      final r = await cap.reset();
      expect(r, isA<CapabilitySuccess>());

      // reset 链路上不得出现任何"删工作区/卸挂载"的调用
      expect(calls, contains('reset'));
      for (final m in calls) {
        expect(m, isNot('delete'));
        expect(m, isNot('removeMount'));
        expect(m, isNot('fs.delete'));
      }
      // 用户工作区路径绝不能出现在任何"删除"类参数里（这里干脆断言没出现删除方法）

      // 重置后挂载注册可能失效 ⇒ 下次执行重新注册（幂等）
      mounted.clear(); // 模拟 rootfs 换了、挂载表被清空
      await cap.run('ls');
      expect(registerArgs, hasLength(2),
          reason: 'reset 后应重新注册一次（否则重置一次就永远看不到工作区）');
      expect(executeArgs.last['workdir'], '/opt/ws-real');
    });

    test('★★★ reset 的删除范围只在 rootfs：工作区文件仍在（mock 宿主 rootfs wipe）',
        () async {
      // 用真实宿主目录模拟两个位置：rootfs（会被宿主 reset 清掉）与用户工作区
      // （bind 源，**不在 rootfs 内，绝不能被 reset 删**）。
      final base = Directory.systemTemp.createTempSync('b5-reset-');
      addTearDown(() {
        if (base.existsSync()) base.deleteSync(recursive: true);
      });
      final rootfsDir = Directory('${base.path}/rootfs')..createSync();
      final wsDir = Directory('${base.path}/app-workspace')..createSync();
      final rootfsMarker = File('${rootfsDir.path}/os-release')
        ..writeAsStringSync('ID=alpine\n');
      final userFile = File('${wsDir.path}/notes.txt')
        ..writeAsStringSync('用户文件-必须存活\n');

      var mockResetDeletedRootfs = false;
      final resetArgs = <Map<String, Object?>>[];
      mockSandbox(
        resetArgs: resetArgs,
        onReset: () {
          // 模拟真实 Kotlin reset：**只删 rootfs 目录内容**（这里删一个代表文件）
          mockResetDeletedRootfs = true;
          if (rootfsMarker.existsSync()) rootfsMarker.deleteSync();
        },
      );

      final cap = ChannelSandboxCapability(
        workspacePath: wsDir.path,
        workspaceIsSaf: false, // temp 路径不匹配生产形状 ⇒ 显式当物理工作区
      );
      await cap.run('ls');
      expect(registerArgs.single['hostPath'], wsDir.path);

      final r = await cap.reset();
      expect(r, isA<CapabilitySuccess>());

      // 先证明 mock 的 reset **真的删了东西**（否则下面的断言就是空跑）
      expect(mockResetDeletedRootfs, isTrue);
      expect(rootfsMarker.existsSync(), isFalse,
          reason: 'mock 的 reset 应删掉 rootfs 代表文件（锁定删除范围真的生效）');

      // ★ 核心断言：reset 绝不能碰用户工作区
      expect(userFile.existsSync(), isTrue,
          reason: '★ reset 只回滚 rootfs；用户工作区是 bind 源，删了 = 用户数据丢失');
      expect(userFile.readAsStringSync(), contains('用户文件-必须存活'));

      // reset 的调用参数里也不得出现工作区路径（防"顺手把路径传下去让它删"）
      for (final a in resetArgs) {
        for (final v in a.values) {
          expect('$v', isNot(contains(wsDir.path)),
              reason: 'reset 参数里不该出现用户工作区路径');
        }
      }
    });
  });

  group('装配层（buildDeviceCapabilities）', () {
    test('★★★ includeSandbox:true 必须把 workspaceRoot 传给沙箱能力（防漏传回归）',
        () async {
      final caps = buildDeviceCapabilities(
        workspaceRoot: kPhysicalWorkspace,
        includeSandbox: true,
      );
      expect(caps.sandbox, isA<ChannelSandboxCapability>());

      final r = await caps.sandbox!.run('ls');
      expect(r, isA<CapabilitySuccess>());
      expect(registerArgs, hasLength(1),
          reason: '★ 装配层漏传 workspacePath ⇒ 永远不会挂载用户工作区');
      expect(registerArgs.single['hostPath'], kPhysicalWorkspace);
      expect(executeArgs.single['workdir'], '/opt/ws-real');
    });

    test('★★ 无 workspacePath（CLI/纯 Dart）⇒ 不挂载、workdir=/workspace、无 SAF 提示',
        () async {
      final cap = ChannelSandboxCapability();
      final r = await cap.run('ls');
      expect(registerArgs, isEmpty);
      expect(executeArgs.single['workdir'], '/workspace');
      expect((r as CapabilitySuccess).metadata!['userwsMount'], 'none');
      expect(r.data, isNot(contains('两套 FS')));
    });
  });
}
