import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **审批门禁 e2e**（2026-10-24 接线门禁）。
///
/// ## 这个文件钉住什么
///
/// AGENTS.md 的「工具白名单 + 参数门禁三态（Allow/NeedsApproval/Deny）」
/// 必须是**架构保证**，不是提示词建议。这条在 Kotlin 时代由
/// `CapabilityGate` 承担（随内核重构消失），现在的承担者是
/// `heracles_agent.dart` 的 `_ApprovalHook`（挂在框架 `beforeToolCall` 上）。
///
/// 逐条钉住：
///
/// 1. 档位放行 ⇒ **不问**直接执行（`fullAccess`；以及 `workspaceAuto` 下的
///    工作区写操作、`manual` 下的只读操作）；
/// 2. 档位要求批准 ⇒ **真的问**（gate 收到调用）且允许后**真的执行**；
/// 3. 用户拒绝 ⇒ 工具**没有执行**，模型收到的是"用户拒绝"的失败结果；
/// 4. 拿不到审批通道（无 UI）⇒ **fail-closed 拒绝**，而不是放行；
/// 5. 拒绝的调用也有 `HeraclesToolFinished(isError: true)` 事件 ——
///    UI 的工具卡片必须能收口，不能永远停在"执行中"。
///
/// ## 为什么用 `run_shell_command` 当主角
///
/// 它在 `manual` 与 `workspaceAuto` **两档都要批**，而 `ShellCapability`
/// 是最小的一个能力接口（一个方法）—— 伪造成本最低。
/// `manual` 档独有的"工作区写操作要批"用伪造 workspace 的 `write_file` 补一条。
void main() {
  _ScriptedClient scripted({
    String toolName = 'run_shell_command',
    String toolArgs = '{"command":"echo hi"}',
    int toolRounds = 1,
  }) =>
      _ScriptedClient(
        toolName: toolName,
        toolArgs: toolArgs,
        toolRounds: toolRounds,
      );

  HeraclesAgent agentWith(
    LLMClient client, {
    required ApprovalMode mode,
    AskGate? gate,
    Capabilities caps = const Capabilities(),
  }) =>
      HeraclesAgent(
        config: BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: caps,
        client: client,
        options: RunOptions(
          maxTurns: 6,
          maxToolCalls: 50,
          approvalMode: mode,
        ),
        askGate: gate,
      );

  group('档位放行', () {
    test('fullAccess：shell 不问直接执行', () async {
      final client = scripted();
      final shell = _FakeShell();
      final gate = _FakeGate(approve: false); // 若被问到即失败（不应被问）
      final agent = agentWith(
        client,
        mode: ApprovalMode.fullAccess,
        gate: gate,
        caps: Capabilities(shell: shell, sandbox: _FakeSandbox(shell)),
      );

      await for (final _ in agent.run('跑条命令')) {}

      expect(gate.asks, isEmpty, reason: '完全访问档不应触发任何审批');
      expect(shell.ran, hasLength(1), reason: '工具应该真的执行了');
    });

    test('manual：只读工具（list_files 不可用 ⇒ 未执行）不触发审批', () async {
      // 用一个"能力缺失"的工具验证放行路径：list_files 在没有 workspace 时
      // 调用即失败 —— 但**失败发生在审批之后**，所以若审批 hook 被错误地
      // 问到了，gate.asks 就非空。
      final client = scripted(toolName: 'list_files', toolArgs: '{}');
      final gate = _FakeGate(approve: false);
      final agent = agentWith(
        client,
        mode: ApprovalMode.manual,
        gate: gate,
        caps: const Capabilities(), // 无 workspace ⇒ list_files 不可用
      );

      await for (final _ in agent.run('列个目录')) {}

      expect(gate.asks, isEmpty,
          reason: '只读工具在 manual 档也不该被审批（否则读文件都要点头，没法用）');
    });
  });

  group('需要批准', () {
    test('workspaceAuto：shell 触发审批，允许 ⇒ 执行成功', () async {
      final client = scripted();
      final shell = _FakeShell();
      final gate = _FakeGate(approve: true);
      final agent = agentWith(
        client,
        mode: ApprovalMode.workspaceAuto,
        gate: gate,
        caps: Capabilities(shell: shell, sandbox: _FakeSandbox(shell)),
      );

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('跑条命令')) {
        events.add(e);
      }

      expect(gate.asks, ['run_shell_command'], reason: 'shell 在工作区自动档也要批');
      expect(shell.ran, hasLength(1), reason: '允许后必须真的执行');
      final finished = events.whereType<HeraclesToolFinished>().toList();
      expect(finished, hasLength(1));
      expect(finished.first.isError, isFalse);
    });

    test('manual：write_file 触发审批，允许 ⇒ 写入执行', () async {
      final client = scripted(
        toolName: 'write_file',
        toolArgs: '{"path":"a.txt","content":"hi"}',
      );
      final ws = _FakeWorkspace();
      final gate = _FakeGate(approve: true);
      final agent = agentWith(
        client,
        mode: ApprovalMode.manual,
        gate: gate,
        caps: Capabilities(workspace: ws),
      );

      await for (final _ in agent.run('写个文件')) {}

      expect(gate.asks, ['write_file'],
          reason: 'manual 档：工作区写操作要批（workspaceAuto 档放行，另有用例钉住）');
      expect(ws.wrote, ['a.txt'], reason: '允许后必须真的写入');
    });

    test('拒绝 ⇒ 工具没有执行，模型收到"用户拒绝"，事件 isError=true', () async {
      final client = scripted();
      final shell = _FakeShell();
      final gate = _FakeGate(approve: false);
      final agent = agentWith(
        client,
        mode: ApprovalMode.manual,
        gate: gate,
        caps: Capabilities(shell: shell, sandbox: _FakeSandbox(shell)),
      );

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('跑条命令')) {
        events.add(e);
      }

      expect(gate.asks, ['run_shell_command']);
      expect(shell.ran, isEmpty, reason: '★ 拒绝后工具绝不能执行 —— 这是门禁的全部意义');
      final finished = events.whereType<HeraclesToolFinished>().toList();
      expect(finished, hasLength(1),
          reason: '★ 被拒绝的调用也要有 tool_finished 事件 —— '
              '否则 UI 的工具卡片永远停在"执行中"');
      expect(finished.first.isError, isTrue);
      expect(finished.first.output, contains('用户拒绝'));
    });
  });

  group('fail-closed', () {
    test('需要批准但 gate 为 null（无 UI）⇒ 拒绝，不放行', () async {
      final client = scripted();
      final shell = _FakeShell();
      final agent = agentWith(
        client,
        mode: ApprovalMode.manual,
        gate: null, // ★ 无审批通道
        caps: Capabilities(shell: shell, sandbox: _FakeSandbox(shell)),
      );

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('跑条命令')) {
        events.add(e);
      }

      expect(shell.ran, isEmpty,
          reason: '★ 拿不到审批通道时必须拒绝（fail-closed），而不是静默放行');
      final finished = events.whereType<HeraclesToolFinished>().toList();
      expect(finished, hasLength(1));
      expect(finished.first.isError, isTrue);
      expect(finished.first.output, contains('fail-closed'));
    });

    // ==================================================================
    // ★ 2026-10-27（Step 2）：**未知工具必须默认要审批**（fail-closed）
    // ==================================================================
    //
    // ## 为什么这组测试是加 git 工具的前置条件
    //
    // 改动之前，判定逻辑是"工具在不在危险表里"：
    //
    // ```dart
    // // ❌ 旧：未知工具 ⇒ 不在表里 ⇒ 不需要审批 ⇒ 静默放行
    // workspaceAuto => _destructive.contains(tool) || _shell.contains(tool) || ...
    // ```
    //
    // 后果：新加的任何工具（git_push 推公网、mcp_call_tool 调任意外部工具）
    // 在 manual/workspaceAuto 档下**一声不响地执行**。
    //
    // 现在反过来：默认要审批，只有 `_readOnly` 白名单放行。
    group('★ 未知工具 ⇒ 默认要审批（fail-closed 白名单模式）', () {
      /// 用一个**不在任何表里**的工具名验证默认行为。
      /// 用 `_FakeShell` 的机制：只要 gate 被问了，就说明"要审批"。
      test('★ manual 档：未知工具必须先问（不是静默放行）', () async {
        final client = scripted(
          toolName: 'future_unknown_tool',
          toolArgs: '{}',
        );
        final gate = _FakeGate(approve: false);
        final agent = agentWith(
          client,
          mode: ApprovalMode.manual,
          gate: gate,
          caps: const Capabilities(),
        );

        await for (final _ in agent.run('调个未来才有的工具')) {}

        expect(gate.asks, hasLength(1),
            reason: '★ 未知工具在 manual 档必须触发审批 —— '
                '否则将来加 git_push / mcp_call_tool 会静默放行');
        expect(gate.asks.first, 'future_unknown_tool');
      });

      test('★ workspaceAuto 档：未知工具也必须先问', () async {
        final client = scripted(
          toolName: 'future_unknown_tool',
          toolArgs: '{}',
        );
        final gate = _FakeGate(approve: false);
        final agent = agentWith(
          client,
          mode: ApprovalMode.workspaceAuto,
          gate: gate,
          caps: const Capabilities(),
        );

        await for (final _ in agent.run('调个未来才有的工具')) {}

        expect(gate.asks, hasLength(1),
            reason: '★ workspaceAuto 只放行"工作区内修改"，未知工具不在其列');
      });

      test('★ fullAccess 档：未知工具不问（用户的明确选择）', () async {
        final client = scripted(
          toolName: 'future_unknown_tool',
          toolArgs: '{}',
        );
        final gate = _FakeGate(approve: false);
        final agent = agentWith(
          client,
          mode: ApprovalMode.fullAccess,
          gate: gate,
          caps: const Capabilities(),
        );

        await for (final _ in agent.run('调个未来才有的工具')) {}

        expect(gate.asks, isEmpty,
            reason: '完全访问档 = 用户已明确承担风险，不该再问');
      });

      test('★ 只读白名单：git 只读工具在 manual 档不触发审批', () async {
        // git_status 在 _readOnly 里 —— 但当前 Capabilities 没有 git 能力，
        // 所以工具"调用即失败"。**关键断言是 gate 没被问**：
        // 说明审批发生在"能力缺失"之前，且只读工具走了放行路径。
        final client = scripted(toolName: 'git_status', toolArgs: '{}');
        final gate = _FakeGate(approve: false);
        final agent = agentWith(
          client,
          mode: ApprovalMode.manual,
          gate: gate,
          caps: const Capabilities(), // 无 git ⇒ 工具不可用
        );

        await for (final _ in agent.run('看下仓库状态')) {}

        expect(gate.asks, isEmpty,
            reason: 'git_status 是只读的，任何档位都不该弹审批');
      });

      test('★ git_push 在 manual 档必须审批（最危险的一个）', () async {
        final client = scripted(toolName: 'git_push', toolArgs: '{}');
        final gate = _FakeGate(approve: false);
        final agent = agentWith(
          client,
          mode: ApprovalMode.manual,
          gate: gate,
          caps: const Capabilities(),
        );

        await for (final _ in agent.run('推上去')) {}

        expect(gate.asks, hasLength(1),
            reason: '★ git_push 把代码推到公网 —— manual 档必须问');
        expect(gate.risks.first, contains('推送'),
            reason: '弹窗风险说明要写明"推送到远程"');
      });
    });
  });

  group('E5 —— 预算提前预警（2026-10-24：止损不该是用户第一次听说预算）', () {
    test('★★ 用到 75% 播一次 HeraclesBudgetWarning', () async {
      // maxToolCalls=4 ⇒ 75% = 第 3 次调用时预警
      // （agentWith 写死了 maxToolCalls=50 —— 这里要 4，单独建）
      final client = scripted(toolRounds: 3);
      final a = HeraclesAgent(
        config: BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(shell: _FakeShell()),
        client: client,
        options: RunOptions(
          maxTurns: 10,
          maxToolCalls: 4,
          approvalMode: ApprovalMode.fullAccess,
        ),
      );

      final events = <HeraclesEvent>[];
      await for (final e in a.run('连跑三条命令')) {
        events.add(e);
      }

      final warnings = events.whereType<HeraclesBudgetWarning>().toList();
      expect(warnings, hasLength(1));
      expect(warnings.single.used, 3);
      expect(warnings.single.limit, 4);
    });

    test('★ 用量低于 75% 不播', () async {
      final client = scripted(toolRounds: 2);
      final a = HeraclesAgent(
        config: BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(shell: _FakeShell()),
        client: client,
        options: RunOptions(
          maxTurns: 10,
          maxToolCalls: 4,
          approvalMode: ApprovalMode.fullAccess,
        ),
      );

      final events = <HeraclesEvent>[];
      await for (final e in a.run('跑两条命令')) {
        events.add(e);
      }
      expect(events.whereType<HeraclesBudgetWarning>(), isEmpty);
    });
  });
}

// ============================================================================
// 测试替身
// ============================================================================

/// 脚本 client：第 1 轮请求一个工具，之后给最终回答。
class _ScriptedClient implements LLMClient {
  _ScriptedClient({
    this.toolName = 'run_shell_command',
    this.toolArgs = '{"command":"echo hi"}',
    this.toolRounds = 1,
  });

  final String toolName;
  final String toolArgs;

  /// 前 [toolRounds] 轮都请求工具（预算预警测试用）。
  /// ⚠️ 参数每轮不同 —— 否则被循环检测判死（compression_e2e 的老坑）。
  final int toolRounds;
  int calls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      _reply(modelConfig);

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      Stream<StreamingMessage>.fromIterable([StreamingMessage(modelMessage: _reply(modelConfig))]);

  ModelMessage _reply(ModelConfig mc) {
    calls++;
    if (calls <= toolRounds) {
      return ModelMessage(
        model: mc.model,
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(
            id: 'c$calls',
            name: toolName,
            // 每轮参数不同：既绕开循环检测，也让 shell 真的每次都跑
            arguments: calls == 1 ? toolArgs : '{"command":"echo r$calls"}',
          ),
        ],
      );
    }
    return ModelMessage(
      textOutput: '完成。',
      model: mc.model,
      stopReason: 'stop',
    );
  }
}

class _FakeShell implements ShellCapability {
  final List<String> ran = [];

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    ran.add(command);
    return const CapabilitySuccess('ran-ok');
  }
}

/// 最小伪造工作区：只有 [write] 有实现，其余方法不应被本文件用到。
class _FakeWorkspace implements WorkspaceCapability {
  final List<String> wrote = [];

  @override
  Future<CapabilityResult> write(String path, String content) async {
    wrote.add(path);
    return CapabilitySuccess('wrote:$path');
  }

  @override
  Future<CapabilityResult> list(String path,
          {bool recursive = false, int maxEntries = 200}) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> read(String path, {int offset = 1, int limit = 0}) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> edit(String path, String oldText, String newText) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> mkdir(String path) async => const CapabilitySuccess('');

  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async =>
      const CapabilitySuccess('');

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<CapabilityResult> findFiles(String pattern, {int maxResults = 200}) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> grepFiles(String pattern,
          {String pathFilter = '', int maxResults = 200}) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> move(String from, String to) async =>
      const CapabilitySuccess('');

  @override
  Future<CapabilityResult> copy(String from, String to) async =>
      const CapabilitySuccess('');
}

class _FakeGate implements AskGate {
  _FakeGate({required this.approve});

  final bool approve;
  final List<String> asks = [];

  /// 每次审批请求的 risk 文案（2026-10-27 加）。
  ///
  /// 为什么单独记：`asks` 只存工具名，而"弹窗上给人看的风险说明"
  /// 是另一条契约（INTERFACE.md N1 的 risk 字段）—— git_push 必须
  /// 写明"推送到远程"，否则用户不知道自己在批准什么。
  final List<String> risks = [];

  @override
  Future<String?> askUser(List<AskQuestion> questions) async => null;

  @override
  Future<bool> requestApproval({
    required String callId,
    required String toolName,
    required Map<String, String> args,
    required String risk,
    required String detail,
    required bool workspaceInside,
  }) async {
    asks.add(toolName);
    risks.add(risk);
    return approve;
  }
}

/// ★ 2026-10-29 路由改动后必须注入：`run_shell_command` 默认走沙箱，
/// 沙箱未就绪会**拒绝执行**。这个测试验的是**审批门禁**语义，
/// 不是路由 —— 所以注入一个"恒就绪"的假沙箱，让 shell 流程照旧走到。
class _FakeSandbox implements SandboxCapability {
  /// 把执行记到同一个 `ran` —— 这些测试断言的是「工具真的执行了」，
  /// 至于是沙箱还是手机 shell 执行的，与本测试无关（那是路由测试的事）。
  _FakeSandbox(this.shell);

  final _FakeShell shell;

  @override
  Future<bool> isReady() async => true;

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    shell.ran.add(command);
    return CapabilitySuccess(
      '【命令输出开始】\n(fake sandbox output)\n【命令输出结束】',
      metadata: {
        'surface': 'sandbox',
        'command': command,
        'exitCode': 0,
        'durationMs': 1,
        'truncated': false,
        'timedOut': false,
      },
    );
  }

  @override
  Future<CapabilityResult> reset({String snapshot = ''}) async =>
      CapabilitySuccess('重置完成');
}