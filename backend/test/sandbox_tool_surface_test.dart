// Copyright (C) 2026 The Heracles Authors
//
// **工具层**执行面分派的测试（`run_shell_command` 到底把命令交给谁）。
//
// ============================================================================
// 这个文件锁住一个差点打断主功能的回归（2026-10-29）
// ============================================================================
// 路由改成「沙箱未就绪 ⇒ 拒绝执行」之后，如果 `Capabilities.sandbox == null`
// （宿主**没接沙箱**，例如 CLI / 测试 / 还没接沙箱的 App）也走这条分支，
// 那么**所有 shell 命令都失败** —— 连 `ls` 都跑不了。当时的 App 正是没注入。
//
// 三种情况必须分清：
//   · sandbox == null           → 走手机 shell（旧行为，不能打断）
//   · sandbox 非 null 但未就绪   → 拒绝 + 提示激活（不回落手机）
//   · sandbox 非 null 且就绪     → 按路由表（普通命令进沙箱）

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

import 'support/tool_result.dart';

/// 记录收到的命令，返回可辨认的输出。
class _RecordingShell implements ShellCapability {
  final List<String> ran = [];

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    ran.add(command);
    return const CapabilitySuccess('device-ran',
        metadata: {'exitCode': 0, 'truncated': false, 'timedOut': false});
  }
}

class _RecordingSandbox implements SandboxCapability {
  _RecordingSandbox({required this.ready});

  final bool ready;
  final List<String> ran = [];

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    ran.add(command);
    return const CapabilitySuccess('sandbox-ran',
        metadata: {'exitCode': 0, 'truncated': false, 'timedOut': false});
  }

  @override
  Future<CapabilityResult> reset({String snapshot = ''}) async =>
      const CapabilitySuccess('reset-ok');
}

void main() {
  Future<String> runCommand(Capabilities caps, String command) async {
    final tools = buildShellTools(ToolFactory(caps), caps);
    final tool = tools.firstWhere((t) => t.name == 'run_shell_command');
    final out = await tool.executable!(<String, dynamic>{'command': command});
    return textOf(out);
  }

  group('宿主没接沙箱（sandbox == null）—— 必须走手机，不能拒绝', () {
    test('★ 普通命令照旧在手机 shell 执行（这是主功能，不能打断）', () async {
      final shell = _RecordingShell();
      final out = await runCommand(Capabilities(shell: shell), 'ls -la');

      expect(shell.ran, ['ls -la'], reason: '必须真的在手机 shell 上跑');
      expect(out, contains('device-ran'));
      expect(out, isNot(contains('激活')),
          reason: '没有沙箱能力的宿主不该被要求激活沙箱');
    });

    test('★ 连 Android 命令也走手机（本来就只有手机可选）', () async {
      final shell = _RecordingShell();
      await runCommand(Capabilities(shell: shell), 'pm list packages');
      expect(shell.ran, ['pm list packages']);
    });
  });

  group('接了沙箱但未就绪 —— 拒绝执行，不回落手机', () {
    test('★★★ 普通命令被拒绝，手机 shell 一次都没跑', () async {
      final shell = _RecordingShell();
      final sandbox = _RecordingSandbox(ready: false);
      final out = await runCommand(
        Capabilities(shell: shell, sandbox: sandbox),
        'ls -la',
      );

      expect(sandbox.ran, isEmpty, reason: '沙箱未就绪，不该跑');
      expect(shell.ran, isEmpty,
          reason: '★ 绝不回落手机 —— 那会让 agent 在用户不知情下动真实系统');
      expect(out, contains('激活'), reason: '要告诉用户去激活');
    });

    test('★ Android 命令同样被拒绝（不是"手机命令就放行"）', () async {
      final shell = _RecordingShell();
      final sandbox = _RecordingSandbox(ready: false);
      final out = await runCommand(
        Capabilities(shell: shell, sandbox: sandbox),
        'pm list packages',
      );
      // 说明：沙箱未就绪时整条链路停住，不因为命令是 Android 类就放行 ——
      // 保持一致的可预期性（先激活，再谈执行面）。
      expect(out, contains('激活'));
      expect(sandbox.ran, isEmpty);
    });
  });

  group('沙箱就绪 —— 按路由表分派', () {
    test('★★ 普通命令进沙箱，手机 shell 不跑', () async {
      final shell = _RecordingShell();
      final sandbox = _RecordingSandbox(ready: true);
      final out = await runCommand(
        Capabilities(shell: shell, sandbox: sandbox),
        'make -j4',
      );

      expect(sandbox.ran, ['make -j4']);
      expect(shell.ran, isEmpty);
      expect(out, contains('sandbox-ran'));
    });

    test('★★ Android 命令仍进手机（沙箱里没有 pm/am）', () async {
      final shell = _RecordingShell();
      final sandbox = _RecordingSandbox(ready: true);
      await runCommand(
        Capabilities(shell: shell, sandbox: sandbox),
        'pm list packages',
      );

      expect(shell.ran, ['pm list packages']);
      expect(sandbox.ran, isEmpty);
    });

    test('★ 引用 @挂载点 的命令进沙箱', () async {
      final shell = _RecordingShell();
      final sandbox = _RecordingSandbox(ready: true);
      await runCommand(
        Capabilities(shell: shell, sandbox: sandbox),
        'cat @workspace/a.txt',
      );
      expect(sandbox.ran, ['cat @workspace/a.txt']);
      expect(shell.ran, isEmpty);
    });
  });

  group('安全闸在两个执行面都生效', () {
    test('★ kill 命令被拒，哪个面都没跑', () async {
      final shell = _RecordingShell();
      final sandbox = _RecordingSandbox(ready: true);
      final out = await runCommand(
        Capabilities(shell: shell, sandbox: sandbox),
        'kill 1234',
      );
      expect(sandbox.ran, isEmpty);
      expect(shell.ran, isEmpty);
      expect(out, contains('禁止'));
    });
  });
}