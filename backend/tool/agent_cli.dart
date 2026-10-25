// **Headless CLI 入口**（2026-10-24，P2-9 —— "从交互工具变成自动化组件"）。
//
// ## 这是什么
//
// `agent_learning` 第 03 章（Claude Code 架构）的四个入口模式里，我们一直
// 只有 App 内嵌一条。这个文件补 **Headless**：无 UI、单任务、stdout 出结果
// —— CI/脚本/别的程序都能把 Heracles 当组件调。
//
// ## 用法
//
// ```bash
// cd backend
// dart run tool/agent_cli.dart \
//   --task "把 README 里的错别字改掉" \
//   --workspace /path/to/project \
//   --base-url https://xx/v1 --api-key sk-xx --model xxx \
//   [--max-turns 40] [--approval workspaceAuto] [--show-thinking]
// ```
// 环境变量等价：HERACLES_CLI_BASE_URL / HERACLES_CLI_API_KEY / HERACLES_CLI_MODEL。
//
// ## 无 UI 环境的审批语义（重要，别想当然）
//
// Headless **没有用户可问**：`askGate` 恒为 null ⇒ 后端的 `_ApprovalHook`
// 对需要批准的操作 **fail-closed 拒绝**（并明说"无审批通道"）。所以：
// · 默认 `--approval workspaceAuto`：工作区内读写自动放行（能干活），
//   shell/APK/删除类被拒（没有 UI 弹窗，拒绝信息里说清为什么）；
// · `--approval fullAccess`：全放行 —— **给自动化场景的明示选择**，
//   用它 = 你接受无人在场的全部副作用。
// 这正是 fail-closed 设计的价值：Headless 默认安全，能力靠显式提权。
//
// ## 退出码
//
// 0 = 任务给出最终回答；1 = 失败/被熔断/预算烧完；2 = 参数错误。
library;

import 'dart:io';

import 'package:heracles_backend/heracles_backend.dart';
import 'package:heracles_backend/src/capability/local_workspace_capability.dart';
import 'package:heracles_backend/src/capability/process_shell_capability.dart';

Future<void> main(List<String> args) async {
  String opt(String name, String env) {
    final i = args.indexOf('--$name');
    if (i >= 0 && i + 1 < args.length) return args[i + 1];
    return Platform.environment[env] ?? '';
  }

  // ---- 参数 ----
  final task = args.contains('--task') ? args[args.indexOf('--task') + 1] : '';
  final workspace = opt('workspace', 'HERACLES_CLI_WORKSPACE');
  final baseUrl = opt('base-url', 'HERACLES_CLI_BASE_URL');
  final apiKey = opt('api-key', 'HERACLES_CLI_API_KEY');
  final model = opt('model', 'HERACLES_CLI_MODEL');
  final maxTurns = args.contains('--max-turns')
      ? int.parse(args[args.indexOf('--max-turns') + 1])
      : ContractAgent.maxTurns;
  final approval = opt('approval', 'HERACLES_CLI_APPROVAL');
  final showThinking = args.contains('--show-thinking');
  final traceDir = args.contains('--trace')
      ? 'heracles-trace-${DateTime.now().millisecondsSinceEpoch}'
      : null;

  if (task.trim().isEmpty) {
    stderr.writeln('缺少 --task "任务描述"');
    exit(2);
  }
  if (workspace.isEmpty || !Directory(workspace).existsSync()) {
    stderr.writeln('缺少或无效的 --workspace（必须是已存在的目录）');
    exit(2);
  }
  if (baseUrl.isEmpty || apiKey.isEmpty || model.isEmpty) {
    stderr.writeln('缺少 --base-url / --api-key / --model'
        '（或环境变量 HERACLES_CLI_*）');
    exit(2);
  }

  final mode = switch (approval) {
    'manual' => ApprovalMode.manual,
    'fullAccess' => ApprovalMode.fullAccess,
    _ => ApprovalMode.workspaceAuto,
  };
  if (mode == ApprovalMode.fullAccess) {
    stderr.writeln('⚠️ --approval fullAccess：无人在场的全部副作用将被放行。');
  }

  // ---- 能力（POSIX 桌面形态；App 的 SAF/设备能力在这里不存在）----
  final root = Directory(workspace).absolute.path;
  final caps = Capabilities(
    workspace: LocalWorkspaceCapability(root),
    shell: ProcessShellCapability(root),
    memory: _FileMemory(root),
  );

  // ---- 跑（事件直接打 stdout —— Headless 的"展示层"就是终端）----
  final agent = HeraclesAgent(
    config: BackendConfig(
      apiKey: apiKey,
      modelName: model,
      baseUrl: baseUrl,
    ),
    capabilities: caps,
    options: RunOptions(
      maxTurns: maxTurns,
      maxToolCalls: ContractAgent.maxToolCalls,
      enableSubAgents: true,
      enableSkills: true,
      approvalMode: mode,
      // ★ E4：--trace 开启逐轮原始请求/响应落盘（排障/回放）
      traceDir: traceDir,
    ),
    // askGate 恒 null ⇒ 需要批准的操作 fail-closed 拒绝（见文件头）。
  );

  var exitCode = 0;
  await for (final ev in agent.run(task)) {
    switch (ev) {
      case HeraclesThoughtDelta(:final delta):
        if (showThinking) stdout.write(_dim(delta));
      case HeraclesTextDelta(:final delta):
        stdout.write(delta);
      case HeraclesToolRequested(:final toolName, :final arguments):
        stdout.writeln(_dim('→ $toolName ${_shortArgs(arguments)}'));
      case HeraclesToolFinished(
          :final toolName,
          :final isError,
          :final durationMs,
        ):
        stdout.writeln(_dim(isError
            ? '✗ $toolName（${durationMs}ms）'
            : '✓ $toolName（${durationMs}ms）'));
      case HeraclesPlanUpdated(:final steps):
        final done = steps.where((s) => s.status == HeraclesPlanStatus.done).length;
        stdout.writeln(_dim('计划 $done/${steps.length}：'
            '${steps.map((s) => s.text).join(" → ")}'));
      case HeraclesContextCompressed():
        stdout.writeln(_dim('（上下文已自动压缩）'));
      case HeraclesBudgetWarning(:final used, :final limit):
        stdout.writeln(_dim('（预算预警：已用 $used/$limit 次工具调用）'));
      case HeraclesRetrying(:final reason):
        stdout.writeln(_dim('（重试：$reason）'));
      case HeraclesFallback(:final from, :final to):
        stdout.writeln(_dim('（模型降级：$from → $to）'));
      case HeraclesTurnUsage():
        break; // Headless 不记账
      case HeraclesFinished(:final turns, :final wallClockMs):
        stdout.writeln();
        stdout.writeln(_dim('── 完成（$turns 轮，${wallClockMs}ms）──'));
        exitCode = 0;
      case HeraclesFailed(:final reason):
        stdout.writeln();
        stderr.writeln('── 失败 ──');
        stderr.writeln(reason);
        exitCode = 1;
    }
  }
  exit(exitCode);
}

String _dim(String s) => '\x1B[2m$s\x1B[0m';

String _shortArgs(Map<String, dynamic> args) {
  if (args.isEmpty) return '';
  final preview = args.entries
      .take(2)
      .map((e) => '${e.key}=${_clip(e.value.toString(), 60)}')
      .join(' ');
  return preview;
}

String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

/// 文件记忆（Headless 形态）：工作区 `.heracles/cli-memory.md`，
/// append-only + 256KB 上限 —— 与 App 的 GlobalMemory 同语义，存储换成本地文件。
class _FileMemory implements MemoryCapability {
  _FileMemory(this.root);

  final String root;

  File get _file => File('$root${Platform.pathSeparator}'
      '.heracles${Platform.pathSeparator}cli-memory.md');

  static const _maxBytes = 256 * 1024; // ContractMemory.maxBytes 同数

  @override
  Future<String> read() async {
    try {
      return await _file.readAsString();
    } catch (_) {
      return '';
    }
  }

  @override
  Future<CapabilityResult> append(String note) async {
    try {
      final f = _file;
      await f.parent.create(recursive: true);
      final exists = await f.exists();
      if (exists) {
        final len = await f.length();
        if (len + note.length > _maxBytes) {
          return CapabilityFailure(
              '记忆已达上限（$_maxBytes 字节），请先清理（删除该文件或精简内容）');
        }
      }
      final ts = DateTime.now().toIso8601String();
      await f.writeAsString('$ts  $note\n', mode: FileMode.append);
      return const CapabilitySuccess('已记住');
    } catch (e) {
      return CapabilityFailure('记忆写入失败：$e');
    }
  }
}

