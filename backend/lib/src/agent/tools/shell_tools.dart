/// **命令执行类工具**。
///
/// ## 安全边界在哪
///
/// 这个工具**不做**命令过滤 —— 过滤属于能力层（`ShellCapability` 的实现），
/// 因为它要按**设备实际能力**判断（是否有 root/shizuku、是否在 SAF 工作区）。
///
/// 但有一条**必须在这里挡住**：`kill` / `force-stop` 这类"动别人应用"的命令，
/// 证据是 2026-10-09 的真实事故（误杀了用户的监控 App）。
/// 后端作为最后一道闸，**明知故犯地放行是不可接受的**。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../tools/tool_factory.dart';

/// 明确禁止的命令模式。
///
/// ## 为什么放在后端而不是只放能力层
///
/// 能力层可能被替换（CLI / App / 未来别的东西）。**"不许杀用户应用"是产品级
/// 约束，不是某个实现的细节** ⇒ 必须由后端自己守最后一道。
///
/// 误伤的代价远大于误拦：误拦用户会看到一条明确的"这个命令被禁止"，
/// 误伤用户会丢掉正在运行的东西。所以宁可**宽一点地拦**。
const _forbiddenCommandPatterns = <String, String>{
  r'\bkill\b': 'kill',
  r'\bkillall\b': 'killall',
  r'\bforce-stop\b': 'force-stop',
  r'\bpm\s+disable\b': 'pm disable',
  r'\bam\s+force-stop\b': 'am force-stop',
};

/// 检查命令是否命中禁止模式。返回原因或 `null`。
String? checkCommandSafety(String command) {
  final lower = command.toLowerCase();
  for (final entry in _forbiddenCommandPatterns.entries) {
    if (RegExp(entry.key).hasMatch(lower)) {
      return '命令包含 `${entry.value}` —— 禁止终止/禁用用户设备上的其它应用。'
          '（设备是用户的，不是测试沙箱。2026-10-09 曾误杀用户的监控 App。）'
          '如果确实需要腾内存，只能停本应用自己启动的进程，或请用户手动处理。';
    }
  }
  return null;
}

/// 构建 shell 工具。
List<Tool> buildShellTools(ToolFactory f, Capabilities caps) {
  final shell = caps.shell;
  return [
    f.build(
      name: 'run_shell_command',
      description: '在工作区里执行一条 shell 命令，返回标准输出与错误输出。'
          '适合跑构建、测试、git、文件操作等。'
          '⚠️ 命令是非交互的：不要用需要输入的命令（如 vim、交互式 git rebase）。'
          '⚠️ 输出较长时会被完整返回，注意不要打印超大文件。',
      parameters: {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': '要执行的命令。相对路径以工作区为基准。',
          },
          'timeout_seconds': {
            'type': 'integer',
            'description': '超时秒数，默认 300。构建类命令建议给 600 以上。',
            'default': 300,
            'minimum': 1,
            'maximum': 7200,
          },
        },
        'required': ['command'],
      },
      isAvailable: () => shell != null,
      unavailableReason: '当前环境不支持 shell 执行',
      run: (args) async {
        final command = requireString(args, 'command');

        // ★ 安全闸：先查，再执行
        final violation = checkCommandSafety(command);
        if (violation != null) {
          return CapabilityFailure(violation, isRetryable: false);
        }

        final timeoutSec = optionalInt(args, 'timeout_seconds') ?? 300;
        return shell!.run(
          command,
          timeout: Duration(seconds: timeoutSec),
        );
      },
    ),
  ];
}
