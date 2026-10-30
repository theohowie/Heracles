// Copyright (C) 2026 The Heracles Authors
//
// **B4（2026-10-30）沙箱优先 —— 执行层测试（经过 `run_shell_command` 工具）**。
//
// 决策层（`decideSurface`）在 `sandbox_surface_matrix_test.dart` 里钉过了；
// 这里钉**真正执行的分支**，因为"规则对但执行分支偷偷回落"才是最难排查的事故：
//
// | 场景 | 必须发生 | 绝不允许发生 |
// |---|---|---|
// | 沙箱已就绪 + 普通/构建命令 | `sandbox.run` 被调用，metadata.surface=sandbox | 调用手机 shell |
// | 已就绪 + `pm` | `shell.run` 被调用，metadata.surface=device | 在沙箱里跑（会失败） |
// | 已就绪 + 真实设备路径 | `shell.run`，reason 指向路径 | 在沙箱里静默读错 |
// | **沙箱未就绪** | 返回**明确错误**（提示激活），**两侧都不跑** | ★ 回落 `shell.run` |
// | 沙箱能力没接入 | 走手机 shell（旧行为，CLI/旧 App 兼容） | 让所有命令失败 |
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

import 'support/tool_result.dart';

/// 假沙箱：记录被调用的命令；`ready` 可配置。
class _FakeSandbox implements SandboxCapability {
  _FakeSandbox({this.ready = true});

  bool ready;
  final List<String> ran = <String>[];

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    ran.add(command);
    return CapabilitySuccess(
      'sandbox-output($command)',
      metadata: <String, dynamic>{'exitCode': 0, 'timedOut': false},
    );
  }

  @override
  Future<CapabilityResult> reset({String snapshot = ''}) async =>
      const CapabilitySuccess('reset');
}

/// 假手机 shell：记录被调用的命令。
class _FakeShell implements ShellCapability {
  final List<String> ran = <String>[];

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    ran.add(command);
    return CapabilitySuccess(
      'device-output($command)',
      metadata: <String, dynamic>{'exitCode': 0, 'timedOut': false},
    );
  }
}

void main() {
  Tool shellTool({_FakeSandbox? sandbox, _FakeShell? shell}) {
    final caps = Capabilities(sandbox: sandbox, shell: shell);
    return buildShellTools(ToolFactory(caps), caps)
        .firstWhere((t) => t.name == 'run_shell_command');
  }

  test('★★★ 沙箱就绪 + 普通命令 ⇒ sandbox.run；手机 shell 一次都不能被调', () async {
    final sandbox = _FakeSandbox();
    final shell = _FakeShell();
    final tool = shellTool(sandbox: sandbox, shell: shell);

    final r = await tool.executable!({'command': 'ls -la'});

    expect(textOf(r), contains('sandbox-output(ls -la)'));
    final meta = metadataOf(r)!;
    expect(meta['surface'], 'sandbox');
    expect(meta['surfaceReason'], contains('默认走沙箱'));
    expect(sandbox.ran, ['ls -la']);
    expect(shell.ran, isEmpty, reason: '★ 默认面是沙箱，不许悄悄跑手机');
  });

  test('★★★ 沙箱就绪 + 构建类命令 ⇒ 仍在沙箱（T2：构建优先沙箱）', () async {
    final sandbox = _FakeSandbox();
    final shell = _FakeShell();
    final tool = shellTool(sandbox: sandbox, shell: shell);

    final r = await tool.executable!({'command': './gradlew assembleDebug'});

    expect(textOf(r), contains('sandbox-output'));
    expect(metadataOf(r)!['surface'], 'sandbox');
    expect(sandbox.ran, ['./gradlew assembleDebug']);
    expect(shell.ran, isEmpty);
  });

  test('★★★ 沙箱就绪 + @挂载点 ⇒ sandbox（@ 引用的命令不许去手机）', () async {
    final sandbox = _FakeSandbox();
    final shell = _FakeShell();
    final tool = shellTool(sandbox: sandbox, shell: shell);

    final r = await tool.executable!({'command': 'cat @workspace/dist/a.txt'});

    expect(metadataOf(r)!['surface'], 'sandbox');
    expect(sandbox.ran.single, 'cat @workspace/dist/a.txt');
    expect(shell.ran, isEmpty);
  });

  test('★★★ 沙箱就绪 + 真实设备路径 ⇒ 手机 shell，reason 指向命中的路径', () async {
    final sandbox = _FakeSandbox();
    final shell = _FakeShell();
    final tool = shellTool(sandbox: sandbox, shell: shell);

    final r = await tool.executable!({'command': 'cp a.txt /sdcard/Download/a.txt'});

    expect(textOf(r), contains('device-output'));
    final meta = metadataOf(r)!;
    expect(meta['surface'], 'device');
    expect(meta['surfaceReason'], contains('真实设备路径'));
    expect(meta['surfaceReason'], contains('/sdcard/Download'));
    expect(shell.ran.single, 'cp a.txt /sdcard/Download/a.txt');
    expect(sandbox.ran, isEmpty, reason: '★ 设备路径在沙箱里会静默读错/写错');
  });

  test('★★★ 沙箱就绪 + pm 命令 ⇒ 手机 shell，reason 说清"要动 Android 本身"', () async {
    final sandbox = _FakeSandbox();
    final shell = _FakeShell();
    final tool = shellTool(sandbox: sandbox, shell: shell);

    final r = await tool.executable!({'command': 'pm list packages'});

    final meta = metadataOf(r)!;
    expect(meta['surface'], 'device');
    expect(meta['surfaceReason'], contains('Android'));
    expect(meta['surfaceReason'], contains('包管理'));
    expect(shell.ran.single, 'pm list packages');
    expect(sandbox.ran, isEmpty);
  });

  test('★★★ 沙箱未就绪 + 普通命令 ⇒ 明确报错，**两侧都不跑**（不可静默回落）', () async {
    final sandbox = _FakeSandbox(ready: false);
    final shell = _FakeShell();
    final tool = shellTool(sandbox: sandbox, shell: shell);

    final r = await tool.executable!({'command': 'ls -la'});

    final t = textOf(r);
    expect(t, contains('沙箱还没激活'),
        reason: '★ 必须让模型/用户看到"去激活沙箱"，而不是"命令跑完了"');
    expect(t, contains('设置'), reason: '要给出可执行的下一步（设置里激活）');
    expect(shell.ran, isEmpty,
        reason: '★★ 未就绪绝不回落手机 shell —— 那会在用户不知情下动真实系统');
    expect(sandbox.ran, isEmpty, reason: '没就绪当然也不能真的在沙箱里跑');
    expect(metadataOf(r), isNull, reason: '这是拒绝执行，不是"执行完成"（不该带 surface metadata）');
  });

  test('★★★ 沙箱未就绪 + 设备命令(pm) ⇒ 同样明确报错（当前产品语义：整面拒绝）', () async {
    // 这是**有意的**产品语义：沙箱未就绪时所有 run_shell_command 都拒绝，
    // 让用户先激活沙箱；"pm 本来就在手机上跑"的便利不值得引入
    // "有时回落、有时不回落"这种不可预测行为。若产品后续要放行设备命令，
    // 应显式改 decideSurface 的顺序并同步本测试。
    final sandbox = _FakeSandbox(ready: false);
    final shell = _FakeShell();
    final tool = shellTool(sandbox: sandbox, shell: shell);

    final r = await tool.executable!({'command': 'pm list packages'});

    expect(textOf(r), contains('沙箱还没激活'));
    expect(shell.ran, isEmpty);
    expect(sandbox.ran, isEmpty);
  });

  test('★★ 沙箱能力根本没接入 ⇒ 走手机 shell（旧行为兼容：CLI/旧 App）', () async {
    final shell = _FakeShell();
    final tool = shellTool(sandbox: null, shell: shell);

    final r = await tool.executable!({'command': 'ls -la'});

    expect(textOf(r), contains('device-output'));
    expect(metadataOf(r)!['surface'], 'device');
    expect(shell.ran, ['ls -la']);
  });

  test('★★ 两侧都没有 ⇒ 工具可见但调用即失败（不是"跑空命令"）', () async {
    final caps = const Capabilities();
    final tool = buildShellTools(ToolFactory(caps), caps)
        .firstWhere((t) => t.name == 'run_shell_command');
    final r = await tool.executable!({'command': 'ls'});
    expect(textOf(r), contains('既没有手机 shell 也没有沙箱'));
  });
}
