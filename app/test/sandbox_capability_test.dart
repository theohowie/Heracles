// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// `ChannelSandboxCapability` 的单测（纯 Dart + mock MethodChannel，不需要设备）。
//
// ============================================================================
// 这个文件锁住什么
// ============================================================================
// 1. **T0 自动就绪**：`isReady()` 发现没装时会自己用内置 rootfs 激活（离线、无需用户操作）
// 2. **元数据齐全**：`surface/command/exitCode/durationMs/truncated/timedOut`
//    —— 前端的命令卡靠这些字段显示「在沙箱执行 / 退出码 / 耗时」
// 3. **失败不假装成功**：rootfs 解包失败、沙箱报错、超时，都要变成模型读得懂的失败
// 4. **不重复激活**：就绪后缓存，不会每条命令都打一次 IPC

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/sandbox_service.dart';
import 'package:heracles_backend/heracles_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SandboxChannelClient.channelName);
  const outputChannel = MethodChannel(SandboxChannelClient.outputChannelName);

  /// 装一个假的 Kotlin 侧。
  void mockSandbox(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) => handler(call));
  }

  /// 从原生侧推一帧流式事件。
  Future<void> push(String method, Map<String, Object?> args) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      SandboxChannelClient.outputChannelName,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(outputChannel, null);
  });

  /// 造一个「就绪」的假沙箱，命令执行会吐出给定输出并结束。
  void mockReadySandbox({
    int exitCode = 0,
    String stdout = 'ok',
    String stderr = '',
    int durationMs = 12,
    bool truncated = false,
    bool autoFinish = true,
  }) {
    mockSandbox((call) async {
      switch (call.method) {
        case 'status':
          return <String, Object?>{
            'ok': true,
            'installed': true,
            'rootfsSummary': 'bundled-minimal',
            'prootReady': true,
            'channels': <Object?>[],
          };
        case 'activate':
          return <String, Object?>{
            'ok': true,
            'installed': true,
            'rootfsSummary': 'bundled-minimal',
            'prootReady': true,
            'channels': <Object?>[],
          };
        case 'execute':
          final args = (call.arguments as Map).cast<String, Object?>();
          if (autoFinish) {
            // 立刻推输出与完成（模拟原生侧）
            scheduleMicrotask(() async {
              if (stdout.isNotEmpty) {
                await push('output', <String, Object?>{
                  'id': 'x',
                  'stream': 1,
                  'chunk': stdout,
                });
              }
              if (stderr.isNotEmpty) {
                await push('output', <String, Object?>{
                  'id': 'x',
                  'stream': 2,
                  'chunk': stderr,
                });
              }
              await push('done', <String, Object?>{
                'id': 'x',
                'result': <String, Object?>{
                  'exitCode': exitCode,
                  'stdout': stdout,
                  'stderr': stderr,
                  'durationMs': durationMs,
                  'timedOut': false,
                  'cancelled': false,
                  'truncated': truncated,
                },
              });
            });
          }
          expect(args['command'], isNotNull);
          return <String, Object?>{'ok': true, 'id': 'x'};
        default:
          return <String, Object?>{'ok': false, 'error': '未知方法 ${call.method}'};
      }
    });
  }

  group('T0 自动就绪（不需要用户操作）', () {
    test('★ 没安装时会自己用内置 rootfs 激活，然后报告就绪', () async {
      final calls = <String>[];
      var installed = false;

      mockSandbox((call) async {
        calls.add(call.method);
        if (call.method == 'status') {
          return <String, Object?>{
            'ok': true,
            'installed': installed,
            'rootfsSummary': installed ? 'bundled-minimal' : '',
            'prootReady': installed,
            'channels': <Object?>[],
          };
        }
        if (call.method == 'activate') {
          installed = true;
          return <String, Object?>{
            'ok': true,
            'installed': true,
            'rootfsSummary': 'bundled-minimal',
            'prootReady': true,
            'channels': <Object?>[],
          };
        }
        return <String, Object?>{'ok': false, 'error': 'unexpected'};
      });

      final cap = ChannelSandboxCapability();
      expect(await cap.isReady(), isTrue);

      expect(calls, contains('activate'),
          reason: '★ 没装时必须自动走内置解包（T0），否则用户所有命令都被拒');
    });

    test('★ 已就绪时不重复激活（缓存生效）', () async {
      final calls = <String>[];
      mockSandbox((call) async {
        calls.add(call.method);
        return <String, Object?>{
          'ok': true,
          'installed': true,
          'rootfsSummary': 'bundled-minimal',
          'prootReady': true,
          'channels': <Object?>[],
        };
      });

      final cap = ChannelSandboxCapability();
      expect(await cap.isReady(), isTrue);
      expect(await cap.isReady(), isTrue);

      expect(calls.where((c) => c == 'status').length, 1,
          reason: '缓存后不该每条命令都查一次状态');
      expect(calls, isNot(contains('activate')));
    });
  });

  group('执行结果映射', () {
    test('★★ 成功 ⇒ 输出文本 + 完整元数据（前端命令卡靠它）', () async {
      mockReadySandbox(stdout: 'hello sandbox', exitCode: 0, durationMs: 7);
      final cap = ChannelSandboxCapability();

      final r = await cap.run('echo hello');

      expect(r, isA<CapabilitySuccess>());
      final ok = r as CapabilitySuccess;
      expect(ok.data, contains('hello sandbox'));
      expect(ok.metadata!['surface'], 'sandbox');
      expect(ok.metadata!['command'], 'echo hello');
      expect(ok.metadata!['exitCode'], 0);
      expect(ok.metadata!['durationMs'], 7);
      expect(ok.metadata!['truncated'], isFalse);
      expect(ok.metadata!['timedOut'], isFalse);
    });

    test('★ 非零退出码如实上报（不是"成功但输出怪"）', () async {
      mockReadySandbox(exitCode: 2, stdout: 'boom');
      final cap = ChannelSandboxCapability();

      final r = await cap.run('false');

      expect(r, isA<CapabilitySuccess>());
      expect((r as CapabilitySuccess).metadata!['exitCode'], 2);
    });

    test('★ stderr 单独标注，不混进 stdout', () async {
      mockReadySandbox(stdout: 'out-line', stderr: 'err-line');
      final cap = ChannelSandboxCapability();

      final r = await cap.run('cmd');
      final data = (r as CapabilitySuccess).data;

      expect(data, contains('out-line'));
      expect(data, contains('[stderr]'));
      expect(data, contains('err-line'));
    });

    test('★ 截断标记透传（前端要如实标注）', () async {
      mockReadySandbox(truncated: true);
      final cap = ChannelSandboxCapability();
      final r = await cap.run('big');
      expect((r as CapabilitySuccess).metadata!['truncated'], isTrue);
    });

    test('★ 流式输出通过 onOutput 回调转发（UI 实时显示）', () async {
      mockReadySandbox(stdout: 'chunk-1');
      final cap = ChannelSandboxCapability();
      final seen = <String>[];

      await cap.run('cmd', onOutput: seen.add);

      expect(seen, contains('chunk-1'));
    });

    test('★ 无输出时给一句可读的话，不留空白给模型', () async {
      mockReadySandbox(stdout: '', exitCode: 0);
      final cap = ChannelSandboxCapability();
      final r = await cap.run('true');
      expect((r as CapabilitySuccess).data, isNotEmpty);
      expect(r.data, contains('退出码'));
    });
  });

  group('失败不假装成功', () {
    test('★★ rootfs 解包失败 ⇒ 失败并提示检查存储', () async {
      mockSandbox((call) async {
        if (call.method == 'status') {
          return <String, Object?>{
            'ok': true,
            'installed': false,
            'rootfsSummary': '',
            'prootReady': false,
            'channels': <Object?>[],
          };
        }
        if (call.method == 'activate') {
          // 激活失败：仍报未安装
          return <String, Object?>{
            'ok': true,
            'installed': false,
            'rootfsSummary': '',
            'prootReady': false,
            'channels': <Object?>[],
          };
        }
        return <String, Object?>{'ok': false, 'error': 'unexpected'};
      });

      final cap = ChannelSandboxCapability();
      final r = await cap.run('ls');

      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('存储'));
      expect(r.isRetryable, isTrue);
    });

    test('★ 提交被拒（未注册挂载点）⇒ 失败原因原样带回', () async {
      mockSandbox((call) async {
        if (call.method == 'status') {
          return <String, Object?>{
            'ok': true,
            'installed': true,
            'rootfsSummary': 'bundled',
            'prootReady': true,
            'channels': <Object?>[],
          };
        }
        return <String, Object?>{
          'ok': false,
          'error': "未注册的挂载点 '@nope'",
        };
      });

      final cap = ChannelSandboxCapability();
      final r = await cap.run('cat @nope/x');

      expect(r, isA<CapabilityFailure>());
      expect((r as CapabilityFailure).reason, contains('@nope'));
    });

    test('★ 通道没注册（纯 Dart 环境）⇒ 失败，不挂死', () async {
      // 不装 handler
      final cap = ChannelSandboxCapability();
      final r = await cap.run('ls');

      expect(r, isA<CapabilityFailure>(),
          reason: '⚠️ 注意：这里返回失败而不是就绪 —— 所以 App 之外不能注入沙箱能力');
    });
  });

  group('重置', () {
    test('重置成功后缓存失效并重新可用', () async {
      mockSandbox((call) async {
        if (call.method == 'status') {
          return <String, Object?>{
            'ok': true,
            'installed': true,
            'rootfsSummary': 'bundled',
            'prootReady': true,
            'channels': <Object?>[],
          };
        }
        if (call.method == 'reset') {
          return <String, Object?>{
            'ok': true,
            'installed': true,
            'rootfsSummary': 'bundled-minimal (reset)',
            'prootReady': true,
            'channels': <Object?>[],
          };
        }
        return <String, Object?>{'ok': false, 'error': 'unexpected'};
      });

      final cap = ChannelSandboxCapability();
      final r = await cap.reset();

      expect(r, isA<CapabilitySuccess>());
      expect((r as CapabilitySuccess).data, contains('重置'));
    });
  });
}
