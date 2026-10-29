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
import '../../contract/contract.dart';
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
///
/// ## 执行面路由（2026-10-28，产品定调）
///
/// **一条命令在哪跑，由后端按固定规则决定，模型无从选择：**
/// - 默认 → 沙箱（PRoot rootfs）
/// - 命中「需要动 Android 本身」的规则 → 手机 shell
///
/// 规则表在 [decideSurface]（`sandbox_capability.dart`），
/// 工具**不暴露** `surface` 参数 —— 让模型自己选就等于让它自由发挥。
List<Tool> buildShellTools(ToolFactory f, Capabilities caps) {
  final shell = caps.shell;
  final ws = caps.workspace;
  final sandbox = caps.sandbox;
  return [
    f.build(
      name: 'run_shell_command',
      // ★ 2026-10-29 P1-③：description 只说**事实**，不许说反话。
      //
      // 旧文案「你可以在工作区里执行 shell 命令」「相对路径以工作区为基准」是错的：
      // guest cwd 恒为沙箱 `/workspace`（ProotEngine.kt:931 / SandboxBridge.kt:366），
      // 模型信了旧文案就用 pwd/ls/find 探测用户工作区，必然扑空（实测白烧 3 轮）。
      // 这里只改文案；执行逻辑/路由/审批一行不动。
      description: '执行一条 shell 命令，返回标准输出与错误输出。'
          '返回：合并的 stdout/stderr 文本 + 退出码；超时附超时说明。'
          '适合跑构建、测试、git、文件操作等。'
          '⚠️ shell **不在用户工作区里跑**：默认在**沙箱**（Alpine Linux / ash）里执行，'
          '沙箱里的 `/workspace` 是沙箱自己的目录，**沙箱与用户工作区是两套文件系统**'
          '（一边写的文件，另一边看不到）。'
          '涉及 Android 本身的命令（pm/am/dumpsys/截图/改系统设置/装包等）会自动改在'
          '**手机 shell**（Android mksh）上执行 —— **命令实际在哪跑由系统决定，'
          '你不要也没有办法自己指定**。'
          '可用 `@name/...` 引用沙箱内的命名挂载点（如 @workspace/dist）—— '
          '注意 `@workspace` 是沙箱内的挂载名，**不是用户工作区**。'
          '⚠️ 要读写/查找/统计**用户工作区**的文件，用 read_file / list_files / find_files / '
          'grep_files 这些文件工具；**不要用 shell 的 pwd/ls/find/wc 去探测用户工作区**（会扑空）。'
          '⚠️ 命令是非交互的：不要用需要输入的命令（如 vim、交互式 git rebase）。',
      parameters: {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': '要执行的命令。路径是**执行面自己的**文件系统路径，不是用户工作区路径：'
                '沙箱内的相对路径以沙箱的 `/workspace` 为基准（那是沙箱目录，**不是用户工作区**）；'
                '可用 `@name/...` 引用沙箱里的命名挂载点（如 @workspace/dist）—— '
                '`@workspace` 是沙箱内的挂载名，**不是用户工作区**。',
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
      // 手机 shell 和沙箱至少要有一个 —— 两个都没有才算不可用
      isAvailable: () => shell != null || sandbox != null,
      unavailableReason: '当前环境既没有手机 shell 也没有沙箱执行面',
      run: (args) async {
        final command = requireString(args, 'command');

        // ★ 安全闸：先查，再执行（不管在哪个执行面，这条都不变）
        final violation = checkCommandSafety(command);
        if (violation != null) {
          return CapabilityFailure(violation, isRetryable: false);
        }

        final timeoutSec = optionalInt(args, 'timeout_seconds') ?? 300;
        final timeout = Duration(seconds: timeoutSec);

        // ---- 决定执行面（**唯一入口**，规则见 decideSurface 的 KDoc）----
        //
        // ★ 三种情况必须分清（2026-10-29）：
        //
        // | `sandbox` 能力 | 就绪 | 语义 | 行为 |
        // |---|---|---|---|
        // | `null`（宿主**没接沙箱**） | — | 这个部署没有沙箱 | **走手机 shell**（保持旧行为） |
        // | 非 null | false | 接了但**没激活** | **拒绝执行** + 提示激活（不回落手机） |
        // | 非 null | true | 正常 | 按路由表决定沙箱/手机 |
        //
        // ⚠️ 第一行很关键：`Capabilities.sandbox == null` 表示"这个宿主根本没接沙箱"
        //   （CLI、测试、还没接沙箱的 App 版本）。把这种情况也当成"未激活"会让
        //   **所有 shell 命令都失败** —— 连 `ls` 都跑不了，直接打断主功能。
        final sandboxAttached = sandbox != null;
        final sandboxReady = sandboxAttached ? await _safeIsReady(sandbox) : false;
        final decision = sandboxAttached
            ? decideSurface(command, sandboxReady: sandboxReady)
            : const SurfaceDecision(
                ExecutionSurface.device,
                '本宿主没有接入沙箱能力 —— 命令在手机 shell 上执行',
                matchedRule: 'no-sandbox-capability',
              );

        // ★ 沙箱**接了但没就绪** ⇒ 拒绝执行（用户裁定：不静默回落手机）。
        if (decision.matchedRule == 'sandbox-not-ready') {
          return CapabilityFailure(
            '这条命令需要在沙箱里执行，但沙箱还没激活。\n'
                '请在设置里激活沙箱（内置基础环境约 9 MB，无需下载）；\n'
                '激活后重试本命令。'
                '${command.contains('@') ? "（命令里的 @挂载点 也依赖沙箱）" : ""}',
            isRetryable: true,
          );
        }

        final startedAt = DateTime.now();
        final CapabilityResult r;
        if (decision.surface == ExecutionSurface.sandbox) {
          r = await sandbox!.run(command, timeout: timeout);
        } else {
          if (shell == null) {
            return CapabilityFailure(
              '这条命令需要手机 shell（原因：${decision.reason}），'
              '但当前环境没有手机 shell 能力 —— 换个方式，或让用户在手机上处理。',
              isRetryable: false,
            );
          }
          r = await shell.run(command, timeout: timeout);
        }
        final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;

        if (r is! CapabilitySuccess) {
          // 失败也带上执行面，前端才知道卡片该写「在沙箱/在手机」
          return CapabilityFailure(
            '（执行面：${decision.surface.wire}）${(r as CapabilityFailure).reason}',
            isRetryable: r.isRetryable,
          );
        }

        // ★ C4（2026-10-24）：超长输出**落盘引用** —— 截断防窗口爆、
        //   完整内容存工作区可取回（read_file 分段读），两头都顾。
        var data = r.data;
        var truncated = (r.metadata?['truncated'] as bool?) ?? false;
        if (data.length > ContractShell.overflowChars && ws != null) {
          final rel = '${ContractShell.overflowDir}/'
              'shell-${DateTime.now().millisecondsSinceEpoch}.txt';
          await ws.mkdir(ContractShell.overflowDir);
          await ws.write(rel, data);
          data = '${data.substring(0, ContractShell.overflowChars)}'
              '\n\n⚠️ 输出共 ${data.length} 字符，已截断。'
              '完整输出已存到工作区 `$rel`，需要后续段用 read_file 读。';
          truncated = true;
        }

        // ★ SEC1（2026-10-24）：命令输出是"外部内容" —— 无条件包裹。
        //   工作区里 cat 到的不可信文件、curl 到的网页都可能夹带指令。
        return CapabilitySuccess(
          '【命令输出开始】\n$data\n【命令输出结束】',
          // ★ 结构化元数据 ⇒ 经 ToolFactory.onExecMeta 送到 UI。
          //   手机 shell 与沙箱**字段一致**，前端用同一套渲染（前端 2026-10-28 要求）。
          metadata: {
            'surface': decision.surface.wire,
            'surfaceReason': decision.reason,
            'command': command,
            // ★ D6（2026-10-29）：**只在能力层真的返回退出码时写这个键**。
            //   旧实现 `(...) ?? 0` 会把"没拿到"伪装成"成功退出" ——
            //   历史命令卡据此显示成功，是假信息（审计记过的那一类）。
            //   取不到就不带该键，读方按"未知"处理。
            if (r.metadata?['exitCode'] is int)
              'exitCode': r.metadata!['exitCode'] as int,
            'durationMs': elapsedMs,
            'truncated': truncated,
            'timedOut': (r.metadata?['timedOut'] as bool?) ?? false,
          },
        );
      },
    ),
  ];
}

/// 问沙箱是否就绪；**任何异常都当"未就绪"**（不能因为探测失败就崩掉工具）。
Future<bool> _safeIsReady(SandboxCapability sandbox) async {
  try {
    return await sandbox.isReady();
  } catch (_) {
    return false;
  }
}
