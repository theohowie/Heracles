// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// 沙箱 Dart 客户端的单元测试（纯 Dart + mock MethodChannel，不需要设备）。
//
// 覆盖点：
//   1. 通道没注册时**不抛**，返回结构化失败
//   2. status / activate 的解码
//   3. execute 的提交语义（立即返回 id，输出走流）
//   4. 流式输出（output / done / error 三种推送）落到对应 Stream
//   5. 只读挂载写入的错误码可区分（13）
//   6. 未注册挂载点的错误码可区分（12）
//   7. 命令里的 `@name` 由**宿主侧**解析 —— Dart 侧绝不自己拼物理路径

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/sandbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SandboxChannelClient.channelName);
  const outputChannel = MethodChannel(SandboxChannelClient.outputChannelName);

  /// 装一个假的 Kotlin 侧：把方法名 → 返回值的映射交给 handler。
  void mockSandbox(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) => handler(call));
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(outputChannel, null);
  });

  group('通道缺失 / 异常时永不抛', () {
    test('通道没注册 → 结构化失败，不抛 MissingPluginException', () async {
      // 不装 handler ⇒ invokeMethod 抛 MissingPluginException
      final s = SandboxService();
      final status = await s.status();
      expect(status.installed, isFalse);
      expect(status.ready, isFalse);

      final raw = await const SandboxChannelClient().call('status');
      expect(raw['ok'], isFalse);
      expect(raw['error'].toString(), contains('不可用'));
    });

    test('通道抛 PlatformException → 收敛成 ok=false', () async {
      mockSandbox((call) async => throw PlatformException(code: 'boom'));
      final raw = await const SandboxChannelClient().call('status');
      expect(raw['ok'], isFalse);
      expect(raw['error'].toString(), contains('boom'));
    });

    test('返回形状不对 → 收敛成 ok=false（而不是崩溃）', () async {
      mockSandbox((call) async => 'not a map');
      final raw = await const SandboxChannelClient().call('status');
      expect(raw['ok'], isFalse);
      expect(raw['error'].toString(), contains('形状'));
    });
  });

  group('status / activate 解码', () {
    test('status 解码 rootfs 摘要与四条通道', () async {
      mockSandbox((call) async {
        expect(call.method, 'status');
        return <String, Object?>{
          'ok': true,
          'installed': true,
          'rootfsSummary': 'bundled-minimal (source=1, 9040693 B, snapshots=0)',
          'prootReady': true,
          'channels': <Object?>[
            <String, Object?>{'type': 0, 'name': '普通 App', 'available': true, 'reason': '', 'risk': 0},
            <String, Object?>{'type': 1, 'name': 'Shizuku', 'available': false, 'reason': '未运行', 'risk': 1},
          ],
        };
      });
      final s = SandboxService();
      final st = await s.status();
      expect(st.installed, isTrue);
      expect(st.prootReady, isTrue);
      expect(st.ready, isTrue);
      expect(st.rootfsSummary, contains('bundled-minimal'));
      expect(st.channels.length, 2);
      expect(st.channels[0].available, isTrue);
      expect(st.channels[1].available, isFalse);
      expect(st.channels[1].reason, '未运行');
    });

    test('activate 传 ociRef 时才带参数，不传时参数为空', () async {
      final seen = <String, Object?>{};
      mockSandbox((call) async {
        if (call.method == 'activate') {
          seen.addAll((call.arguments as Map).cast<String, Object?>());
        }
        return <String, Object?>{'ok': true, 'installed': true};
      });
      final s = SandboxService();
      await s.activate();
      expect(seen.containsKey('ociRef'), isFalse, reason: '不传就不该带这个 key');

      await s.activate(ociRef: 'docker.io/library/alpine:3.20');
      expect(seen['ociRef'], 'docker.io/library/alpine:3.20');
    });
  });

  group('execute 提交语义', () {
    test('提交后立即拿到 id，不在 result 里等输出', () async {
      mockSandbox((call) async {
        expect(call.method, 'execute');
        final args = (call.arguments as Map).cast<String, Object?>();
        expect(args['command'], 'echo hi');
        expect(args['workdir'], '/workspace');
        return <String, Object?>{'ok': true, 'id': 'sbx-1'};
      });
      final s = SandboxService();
      final submit = await s.execute('echo hi');
      expect(submit.ok, isTrue);
      expect(submit.id, 'sbx-1');
    });

    test('提交失败时不返回假 id', () async {
      mockSandbox((call) async => <String, Object?>{
            'ok': false,
            'error': '未注册的挂载点 @nope',
          });
      final s = SandboxService();
      final submit = await s.execute('cat @nope/x');
      expect(submit.ok, isFalse);
      expect(submit.id, isEmpty);
      expect(submit.error, contains('@nope'));
    });
  });

  group('流式输出', () {
    test('output / done 事件按 id 落到对应 Stream', () async {
      mockSandbox((call) async => <String, Object?>{'ok': true, 'id': 'sbx-9'});
      final s = SandboxService();
      await s.execute('echo hi');

      final chunks = <SandboxOutputChunk>[];
      final dones = <SandboxExecDone>[];
      final sub1 = s.outputStream.listen(chunks.add);
      final sub2 = s.doneStream.listen(dones.add);

      // 模拟原生侧推送
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        SandboxChannelClient.outputChannelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('output', <String, Object?>{
            'id': 'sbx-9',
            'stream': 1,
            'chunk': 'hello',
          }),
        ),
        (_) {},
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        SandboxChannelClient.outputChannelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('done', <String, Object?>{
            'id': 'sbx-9',
            'result': <String, Object?>{
              'exitCode': 0,
              'stdout': 'hello',
              'stderr': '',
              'durationMs': 42,
              'timedOut': false,
              'cancelled': false,
              'truncated': false,
            },
          }),
        ),
        (_) {},
      );
      await Future<void>.delayed(Duration.zero);

      expect(chunks.length, 1);
      expect(chunks.single.chunk, 'hello');
      expect(chunks.single.isStdout, isTrue);
      expect(dones.length, 1);
      expect(dones.single.id, 'sbx-9');
      expect(dones.single.result.exitCode, 0);
      expect(dones.single.result.success, isTrue);
      expect(dones.single.result.durationMs, 42);

      await sub1.cancel();
      await sub2.cancel();
    });

    test('error 事件能区分「未注册挂载」与「只读挂载」', () async {
      mockSandbox((call) async => <String, Object?>{'ok': true, 'id': 'sbx-10'});
      final s = SandboxService();
      await s.execute('cat @nope/x');

      final errs = <SandboxExecError>[];
      final sub = s.errorStream.listen(errs.add);

      Future<void> push(int code, String msg) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          SandboxChannelClient.outputChannelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('error', <String, Object?>{
              'id': 'sbx-10',
              'code': code,
              'message': msg,
            }),
          ),
          (_) {},
        );
      }

      await push(kSandboxCodeMountUnknown, "未注册的挂载点 '@nope'");
      await push(kSandboxCodeMountReadOnly, '挂载点 @libs 是只读的');
      await Future<void>.delayed(Duration.zero);

      expect(errs.length, 2);
      expect(errs[0].isUnknownMount, isTrue);
      expect(errs[1].isReadOnlyMount, isTrue);
      await sub.cancel();
    });
  });

  group('文件 / 挂载', () {
    test('只读挂载写入 → 错误码 13，可据此给用户明确提示', () async {
      mockSandbox((call) async => <String, Object?>{
            'ok': false,
            'text': null,
            'size': 0,
            'errorCode': kSandboxCodeMountReadOnly,
            'error': '挂载点 @libs 是只读的，拒绝写入：@libs/x.so',
          });
      final s = SandboxService();
      final r = await s.writeFile('@libs/x.so', 'nope');
      expect(r.ok, isFalse);
      expect(r.isReadOnly, isTrue);
      expect(r.error, contains('只读'));
    });

    test('未注册挂载点 → 错误码 12', () async {
      mockSandbox((call) async => <String, Object?>{
            'ok': false,
            'text': null,
            'size': 0,
            'errorCode': kSandboxCodeMountUnknown,
            'error': "未注册的挂载点 '@nope'",
          });
      final s = SandboxService();
      final r = await s.readFile('@nope/x');
      expect(r.ok, isFalse);
      expect(r.isUnknownMount, isTrue);
    });

    test('registerMount 把 backend 编成 wireValue（不是字符串）', () async {
      Map<Object?, Object?>? seen;
      mockSandbox((call) async {
        if (call.method == 'registerMount') {
          seen = (call.arguments as Map).cast<Object?, Object?>();
        }
        return <String, Object?>{'ok': true};
      });
      final s = SandboxService();
      await s.registerMount(
        name: 'libs',
        backend: SandboxMountBackend.hostPrivateDir,
        hostPath: '/data/data/x/files/libs',
        readOnly: true,
      );
      expect(seen!['backend'], 1, reason: 'HOST_PRIVATE_DIR 的 wireValue 必须是 1');
      expect(seen!['readOnly'], isTrue);
      expect(seen!['name'], 'libs');
    });

    test('listMounts 解码 prefix 与只读标记', () async {
      mockSandbox((call) async => <String, Object?>{
            'ok': true,
            'mounts': <Object?>[
              <String, Object?>{
                'name': 'workspace',
                'backend': 0,
                'readOnly': false,
                'bindTo': '',
                'description': '工作区',
              },
              <String, Object?>{
                'name': 'libs',
                'backend': 1,
                'readOnly': true,
                'bindTo': '/opt/libs',
                'description': '共享库',
              },
            ],
          });
      final s = SandboxService();
      final mounts = await s.listMounts();
      expect(mounts.length, 2);
      expect(mounts[0].prefix, '@workspace');
      expect(mounts[0].backend, SandboxMountBackend.rootfsRelative);
      expect(mounts[1].readOnly, isTrue);
      expect(mounts[1].bindTo, '/opt/libs');
    });
  });

  group('命名路径约定（模型侧可迁移性）', () {
    test('Dart 侧只传 @name，绝不把物理路径拼进去', () async {
      final commands = <String>[];
      mockSandbox((call) async {
        if (call.method == 'execute') {
          commands.add(((call.arguments as Map)['command'] as String));
        } else if (call.method == 'writeFile') {
          commands.add(((call.arguments as Map)['path'] as String));
        }
        return <String, Object?>{'ok': true, 'id': 'x'};
      });
      final s = SandboxService();
      await s.execute('cat @workspace/a.txt');
      await s.writeFile('@workspace/a.txt', 'hi');

      for (final c in commands) {
        expect(c, contains('@workspace'));
        // 典型物理路径前缀绝不能出现在 Dart 侧构造的字符串里
        expect(c, isNot(contains('/data/data/')));
        expect(c, isNot(contains('/data/user/')));
        expect(c, isNot(contains('rootfs/')));
      }
    });
  });
}
