/// **App ↔ backend 的接线层**（2026-10-22）。
///
/// ## 这一层解决什么问题
///
/// 重构前：`AgentBridge.run()` 走 MethodChannel `heracles/command` 的
/// `runAgent`，Kotlin 侧跑 `AgentLoop`，事件走 EventChannel `heracles/events`。
///
/// 重构后：**那 5 个 Kotlin 模块被删了**，`MainActivity` 里
/// `runAgent` / `listSessions` / `replyApproval` 这些 handler **全都不存在**
/// （只剩工作区登记、选择器、权限引导、健康读数）。也就是说：
/// 旧 `AgentBridge` 今天调用它们是**必然失败**的 —— 通道会回
/// `{"ok": false, "error": "未知方法：runAgent"}`。
///
/// 所以编排必须搬回来 —— 但这次是搬进 **Dart 进程内**（`backend/`），
/// 不再跨进程。这正好是这个仓库重构的本意：
///
/// ```
/// 旧：Flutter ──MethodChannel──> Kotlin(AgentLoop) ──> Kotlin(工具) ──> 设备
/// 新：Flutter ──直接调用──> Dart(HeraclesAgent) ──┐
///                  └──MethodChannel('heracles/device')──> 设备能力
/// ```
///
/// ## 为什么不重写 UI
///
/// `chat_screen.dart` 195 KB / 19 种事件、19 个 widget 测试文件 —— 那是
/// **已验证资产**。这一层的职责就是"让 backend 的事件长得跟旧 Kotlin 一样"，
/// 从而 UI **一行都不用改**。
///
/// ## 事件形状来自哪里
///
/// 以 `AgentEvent.fromMap`（UI 侧的唯一消费者）为准，逐字段对齐：
///
/// | UI 事件 | 何时发 | 关键字段 |
/// |---|---|---|
/// | `turn_started` | 每轮开始 | `index` |
/// | `step_started` | 每轮开始 | `stepId`=`turn-N`, `title`, `index` |
/// | `step_delta` | 正文增量 | `stepId`, `delta` |
/// | `step_ended` | 每轮结束 | `stepId`, `status`(ok/empty/error), `durationMs`, `summary` |
/// | `tool_started` | 模型请求工具后 | `tool`, `args`, `index` |
/// | `tool_finished` | 工具执行完 | `tool`, `result`, `ok`, `index`, `wallMs` |
/// | `plan_created` | 计划变化 | `planSteps`, `doneCount`, `activeIndex` |
/// | `finished` | 正常收尾 | `finalText`, `turnCount` |
/// | `failed` | 异常收尾 | `message` |
///
/// ## 与 `agent_runner.dart` 的关系
///
/// `agent_runner.dart` 是**纯翻译器**（无 IO、无状态持久化），本文件是
/// **驱动器**（建能力、建 agent、跑、落盘、回填结果）。分开是为了让翻译器
/// 能被单测覆盖，而驱动器只做"胶水"。
library;

import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart' show CancelToken;
import 'package:heracles_backend/heracles_backend.dart';

import '../models/attachment.dart';
import '../models/settings.dart';
import 'agent_bridge.dart'
    show AgentEvent, AgentRunResult, AgentTurn, ToolState;
import 'device_capabilities.dart';
import 'diff_stats.dart';
import 'global_memory.dart' show runMemoryMigrationOnce;
import 'image_input.dart';
import 'memory_service.dart';
import 'session_store.dart';

/// **执行面 → 历史命令卡口径**（D6，2026-10-29）。**纯函数**，便于单测。
///
/// backend 的 wire 是 `sandbox` / `device`（`HeraclesToolRequested.surface`、
/// shell 工具 metadata 的 `surface`）；落盘契约（`docs/接口.md` §7.2 D6）用
/// `sandbox` / `mobileShell` / `unknown`。映射规则只此一处：
///
/// · `sandbox` ⇒ `sandbox`（沙箱里跑）
/// · `device` ⇒ `mobileShell`（手机 shell 里跑）
/// · 其它/缺失 ⇒ `unknown`（**不猜** —— 猜错会让用户以为命令没碰手机）
///
/// [finishedWire]（完成时能力层回报的真实执行面）优先于
/// [requestedWire]（请求时 `decideSurface` 的预判）——两者不一致时听真实的。
String toolRowSurfaceOf({String? finishedWire, String? requestedWire}) {
  final wire = finishedWire ?? requestedWire;
  return switch (wire) {
    'sandbox' => 'sandbox',
    'device' => 'mobileShell',
    // 已按落盘口径的情况下原样接住（幂等）
    'mobileShell' => 'mobileShell',
    _ => 'unknown',
  };
}

/// **构造落盘的 `step` 行**（2026-10-29 JSONL 记账）—— **纯函数**。
///
/// ## usage 三字段的规则（`docs/接口.md` §7.2）
///
/// · `prompt` / `out`：仅当**本轮真的见到 usage**（`usageSeen`）时写；
/// · `cached`：**null 不写键** —— 不写假 0。
///
/// 为什么"没上报"必须区别于 0：provider 不上报缓存字段时，UI 的命中率
/// 要显示"不可用"而不是 0%（`cache_accounting` 的口径纪律）。落盘同理：
/// 写成 0 会让历史回放把"没数据"画成"一次都没命中"。
///
/// 其它字段与旧 `step` 行**逐字一致**（只增 usage 三键）。
Map<String, dynamic> buildStepRow({
  required String stepId,
  required String title,
  required int turn,
  required String think,
  required String text,
  required String stage,
  required int ms,
  required int ts,
  required bool usageSeen,
  required int prompt,
  int? cached,
  required int output,
}) =>
    <String, dynamic>{
      'role': 'step',
      'stepId': stepId,
      'title': title,
      'i': turn,
      'think': think,
      'text': text,
      'stage': stage,
      'ms': ms,
      if (usageSeen) 'prompt': prompt,
      if (usageSeen && cached != null) 'cached': cached,
      if (usageSeen) 'out': output,
      'ts': ts,
    };

/// **构造落盘的 `tool` 行**（D6，2026-10-29）—— **纯函数**，落盘与单测共用。
///
/// ## 只增三字段（旧形状一个都不改）
///
/// | 字段 | 规则 |
/// |---|---|
/// | `surface` | `sandbox` / `mobileShell` / `unknown`；优先完成时 metadata，回落请求时预判，都取不到 ⇒ `unknown`（不猜） |
/// | `exitCode` | **只有真实拿到退出码才写键**；缺失不写（不写假 0），负数哨兵（-1=未知/超时）不写 |
/// | `command` | 实际执行的命令（请求时 `callArgs['command']`，与实时链路同一字符串）；非 shell 工具没有就省略 |
///
/// ## 为什么 `exitCode` 宁缺勿假
///
/// 历史卡片用退出码判断"成功/失败"。缺失写成 0 会把"没拿到"伪装成"成功"
/// —— 那正是审计里记过的"假信息比失败更糟"。所以取不到就不写键，读方按
/// `containsKey` 区分"未知"与"真实 0"。
Map<String, dynamic> buildToolRow({
  required String tool,
  required Map<String, dynamic> args,
  required String result,
  required bool isError,
  String? id,
  Map<String, dynamic>? metadata,
  String? requestedSurface,
  String? requestedCommand,
  required int ts,
}) {
  final exitCode = metadata?['exitCode'];
  final rawCommand = requestedCommand ??
      (args['command'] is String ? args['command'] as String : null);
  return <String, dynamic>{
    'role': 'tool',
    // ★ 调用 id（2026-10-24）：与发起时的 `tool_call` 行配对，
    //   历史回填才能重建工具往返（无 id 时省略，回填跳过该行）。
    if (id != null && id.isNotEmpty) 'id': id,
    'tool': tool,
    'args': args,
    'result': result,
    'state': isError ? 'failed' : 'succeeded',
    'ok': !isError,
    // ★ D6：执行面（真实优先，取不到 unknown，不猜）
    'surface': toolRowSurfaceOf(
      finishedWire: metadata?['surface'] as String?,
      requestedWire: requestedSurface,
    ),
    // ★ D6：退出码只在真实拿到时写（负数 = "未知/超时"哨兵，不写）
    if (exitCode is num && exitCode >= 0) 'exitCode': exitCode.toInt(),
    // ★ D6：实际命令（非 shell 工具没有该字段）
    if (rawCommand != null && rawCommand.trim().isNotEmpty) 'command': rawCommand,
    'ts': ts,
  };
}

/// 一次 run 的句柄。
class LocalRunHandle {
  LocalRunHandle({
    required this.events,
    required this.result,
    required this.cancel,
    this.enqueueSteer = _rejectSteer,
  });

  final Stream<AgentEvent> events;
  final Future<AgentRunResult> result;
  final Future<bool> Function() cancel;

  /// **插队发送入队**（P0，2026-10-30）：`accepted`/`added` 语义见
  /// `LocalAgentExecutor.steerEnqueue`。默认**拒绝** —— 假执行器（测试替身）
  /// 或未接插队的宿主调 `interruptRun` 会如实返回 false，调用方走正常发送。
  final ({bool accepted, bool added}) Function(String text) enqueueSteer;

  static ({bool accepted, bool added}) _rejectSteer(String text) =>
      (accepted: false, added: false);
}

/// **App 侧的提问门禁**（`AskGate` 实现，2026-10-23 修「提问现在不可用」）。
///
/// ## 这条链路原来断在哪（三处，缺一处 ask_user 就是死工具）
///
/// 1. `AgentBridge.run()` 构造 `LocalAgentExecutor` 时**没传 `askGate`**
///    ⇒ backend 的 `ask_user` 工具 `isAvailable: () => askGate != null` 为 false
///    ⇒ 工具直接告诉模型"当前环境不支持询问用户"。
/// 2. 全仓**没有任何 `AskGate` 实现** ⇒ 就算传了也没东西可传。
/// 3. `AgentBridge.replyAsk()` 还在打**已删除的旧 Kotlin 通道**
///    ⇒ 回答永远回不到挂起的工具。
///
/// 本类补第 2 处；第 1、3 处分别在 `AgentBridge.run()` / `AgentBridge.replyAsk()`。
///
/// ## 职责
///
/// · `askUser(...)`：把 backend 的 `AskQuestion` 翻成 UI 认识的形状、
///   发一个 `ask_user` 事件、**挂起**等用户作答（带超时兜底）
/// · `replyAsk(...)`：UI 提交答案时**完成挂起**（不再跨进程）
/// · `abort()`：用户点「停止」时把挂起解掉 —— 否则工具要白等满 10 分钟
///
/// ## 为什么必须"挂起"而不是发完事件就返回
///
/// `ask_user` 的工具语义是"暂停等回答，拿到回答后继续"（见 backend
/// `interaction_tools.dart` 的 A 方案）。发完事件就返回等于**编造答案**；
/// 返回 null 才是"用户没答"，backend 会如实告诉模型并让它自行决策。
class LocalAskGate implements AskGate {
  /// [approvalTimeout] / [answerTimeout] 可注入（默认 = 契约值）。
  ///
  /// 为什么做成实例字段：JSONL 记账的"审批超时/提问超时"分支必须被测试覆盖，
  /// 而等 5/10 分钟不是测试该付的代价（生产仍用默认值，行为不变）。
  LocalAskGate({
    this.approvalTimeout = defaultApprovalTimeout,
    this.answerTimeout = defaultAnswerTimeout,
  });

  /// 本 run 的事件出口 —— 由 [LocalAgentExecutor] 在 run 开始时用
  /// `controller.add` 接上（事件流在那边才创建得出）。
  void Function(AgentEvent)? _emit;

  /// 非 null = 此刻有题目在等用户回答。值类型可空：取消/超时用 `null` 完成。
  Completer<Map<String, List<String>>?>? _pending;

  // ==========================================================================
  // 审批（2026-10-24 接线 —— 与 backend `_ApprovalHook` 配对）
  // ==========================================================================

  /// 非 null = 此刻有一个审批在等用户决定。
  Completer<bool>? _pendingApproval;

  /// 挂起审批的 callId（N1：答复按 callId 配对）与工具名（always 记账）。
  String? _pendingApprovalCallId;
  String? _pendingApprovalTool;

  /// 审批等待上限（N1 契约：5 分钟；超时按 deny 处理并发 blocked）。
  /// 提问（ask_user）仍用 [answerTimeout] 10 分钟 —— 两个超时各自独立。
  static const defaultApprovalTimeout = Duration(minutes: 5);
  Duration approvalTimeout = defaultApprovalTimeout;

  /// ==========================================================================
  /// **决策日志缓冲**（2026-10-29，`role:"approval"` / `role:"ask"` 落盘）
  /// ==========================================================================
  ///
  /// ## 纪律：**gate 只 push，不写盘**
  ///
  /// 写盘（`sessionStore.appendMessage`）是异步 IO，而 gate 正处在
  /// "审批/提问挂起"的链路上 —— 在 gate 里 await append 会：
  /// · 把审批决定拖到写盘之后（用户点了允许，工具却迟迟不跑）；
  /// · 与 `_drive` 的写操作并发 ⇒ 撞上 `appendMessage` 的并发闸（被拒绝）；
  /// · 写失败还会污染"决定是否已生效"的语义（决定已生效，只是没记上）。
  ///
  /// ⇒ gate 只把"决策已发生"push 进这里，**`_drive` 是唯一写者**：
  /// 每个事件处理**之前** drain 一次 + `finally` 兜底（见 `_drive`）。
  final List<Map<String, dynamic>> _journal = <Map<String, dynamic>>[];

  /// 取走并清空决策日志（`_drive` 专用）。返回顺序 = 决策发生顺序。
  List<Map<String, dynamic>> takeJournal() {
    if (_journal.isEmpty) return const <Map<String, dynamic>>[];
    final out = List<Map<String, dynamic>>.from(_journal);
    _journal.clear();
    return out;
  }

  /// 只供排障/测试：当前缓冲条数。
  int get journalLength => _journal.length;

  /// 是否有提问/审批正挂着（测试轮询用；生产不需要）。
  bool get hasPendingAsk => _pending != null && !_pending!.isCompleted;
  bool get hasPendingApproval =>
      _pendingApproval != null && !_pendingApproval!.isCompleted;
  String? get pendingApprovalCallId => _pendingApprovalCallId;

  /// push 一条 approval 决策（**每条决定只 push 一次**；调用点各自唯一）。
  void _pushApproval({
    required String callId,
    required String tool,
    required String decision,
    required String outcome,
  }) {
    _journal.add(<String, dynamic>{
      'role': 'approval',
      'callId': callId,
      'tool': tool,
      // 落盘口径统一为 once/always/deny（旧值 allow/allow_always 已在
      // [replyApproval] 归一化）。
      'decision': decision,
      'outcome': outcome,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// **「始终允许」名单** —— 本 run 内生效的累计集合。
  ///
  /// 种子来自持久化存储（`AgentBridge` 在 run 开始时 `seedAllowed` 注入，
  /// 数据源是 `SharedPreferences`，跨启动有效）；用户点「本会话始终允许」
  /// 后通过 [onAlwaysAllow] 回调交给桥接层持久化，同时立刻加进本集合
  /// —— 同一 run 里的后续调用不再问。
  final Set<String> _allowed = {};

  /// 用户点了「本会话始终允许」时的持久化回调（桥接层注入）。
  void Function(String toolName)? onAlwaysAllow;

  /// 用户**点停止**后置位：之后到达的提问/审批一律按"没答案/拒绝"处理。
  bool _aborted = false;

  /// 等用户回答的**上限**（默认 **5 分钟 / 300s**；测试可注入更短值）。
  ///
  /// 为什么是 5 分钟（2026-10-30 从 10 分钟收窄到 300s，P0）：
  /// · 提问挂起时**整个 run 都在等**（工具不返回、轮次不推进）—— 10 分钟太长，
  ///   用户离开一下就以为"卡死"；
  /// · 与**审批**超时对齐（审批也是 5 分钟，N1 契约）—— 两个交互超时同口径，
  ///   UI 说明不用分两套。
  ///
  /// 超时后仍按"未回答"返回 null（backend 如实告诉模型，**绝不编答案**），
  /// 并发一条 `ask_closed{outcome:"timeout"}` 让 UI 把气泡收掉（只增事件）。
  static const defaultAnswerTimeout = Duration(minutes: 5);
  Duration answerTimeout;

  /// **提问已关闭**事件（P0，2026-10-30；只增）。
  ///
  /// `outcome` ∈ `timeout`（300s 未回答）/ `aborted`（用户停止/取消解挂）。
  /// 用户**正常提交/跳过**走 [replyAsk]，**不发**这个事件（UI 自己已经收掉）。
  /// 为什么需要：没有它，超时/停止后 UI 的提问气泡只能靠"下一轮事件"顺带
  /// 清掉 —— 任务恰好在那时结束的话，气泡会**永远留在界面上**。
  void _pushAskClosed(String outcome) {
    final emit = _emit;
    if (emit == null) return;
    emit(AgentEvent(
      type: AgentEvent.kAskClosed,
      ts: DateTime.now().millisecondsSinceEpoch,
      outcome: outcome,
    ));
  }

  /// 把本 run 的事件出口接上（每个 run 一个 gate 实例，只接一次）。
  void attach(void Function(AgentEvent) emit) => _emit = emit;

  /// 注入持久化的「始终允许」名单（run 开始时由桥接层调用）。
  void seedAllowed(Iterable<String> tools) => _allowed.addAll(tools);

  /// 用户**点停止**时调用：让挂起的提问/审批立刻收场。
  void abort() {
    _aborted = true;
    final c = _pending;
    if (c != null && !c.isCompleted) {
      _pending = null;
      c.complete(null);
      // ★ P0（2026-10-30）：用户停止解挂的提问 ⇒ 发一次 ask_closed{aborted}。
      //   （正常提交走 replyAsk，不发；超时走 onTimeout，不发这条。）
      _pushAskClosed('aborted');
    }
    final a = _pendingApproval;
    if (a != null && !a.isCompleted) {
      // 取消也是一次"审批决定"（deny / cancelled）—— 记账一次，供历史回放
      // 解释"为什么这次工具没跑"。
      _pushApproval(
        callId: _pendingApprovalCallId ?? '',
        tool: _pendingApprovalTool ?? '',
        decision: 'deny',
        outcome: 'cancelled',
      );
      _pendingApproval = null;
      a.complete(false);
    }
  }

  /// 问用户（挂起直到回答 / 超时 / 取消）。
  ///
  /// 返回渲染好的人话文本（喂回模型）；`null` = 没有答案（超时/取消），
  /// backend 会如实告诉模型"用户没有回答"，**绝不编造**。
  @override
  Future<String?> askUser(List<AskQuestion> questions) async {
    // 已有提问挂着：backend 是串行的，正常不会发生。不覆盖，如实返回"没答案"。
    if (_pending != null) return null;
    // 没有 UI 出口（直接跑 executor 的测试/CLI 场景）：如实返回 null（问不了），
    // 而不是挂 10 分钟。
    if (_emit == null) return null;
    // 用户已点停止：不能再弹窗问问题。
    if (_aborted) return null;

    final c = Completer<Map<String, List<String>>?>();
    _pending = c;

    _emit!(AgentEvent(
      type: AgentEvent.kAskUser,
      ts: DateTime.now().millisecondsSinceEpoch,
      // 降级文案（UI 只在 questions 解析失败时用）；这里给题干，便于排障。
      message: questions.map((q) => q.question).join('\n'),
      // ★ 字段名必须与 `chat_screen._showAskDialog` 实际读取的一致：
      //   `id` / `question` / `multi` / `options[] {label, description}`
      questions: [
        for (final q in questions)
          <String, dynamic>{
            'id': q.id,
            'question': q.question,
            'multi': q.multi,
            'options': [
              for (final o in q.options)
                <String, dynamic>{
                  'label': o.label,
                  'description': o.description ?? '',
                },
            ],
          },
      ],
    ));

    Map<String, List<String>>? answers;
    try {
      answers = await c.future.timeout(
        answerTimeout,
        // 超时 = 未回答（返回 null），不是异常 —— backend 的 null 分支就是
        // "用户没答，请自行合理决定并说明假设"。
        onTimeout: () {
          _pending = null;
          // ★ P0（2026-10-30）：超时仍返回 null（不编答案），并发一次
          //   ask_closed{timeout} 让 UI 收掉气泡（只增事件；正常提交不发）。
          _pushAskClosed('timeout');
          // ignore: avoid_print
          print('[heracles][ask] 提问超时（${answerTimeout.inMinutes} 分钟）未回答');
          return null;
        },
      );
    } finally {
      if (identical(_pending, c)) _pending = null;
    }
    // ★ 2026-10-29（JSONL 记账）：提问结果也落一行（answered / timeout /
    //   cancelled 三态）。gate 只 push，`_drive` 是唯一写者。
    _journal.add(<String, dynamic>{
      'role': 'ask',
      'questions': [
        for (final q in questions)
          <String, dynamic>{
            'id': q.id,
            'question': q.question,
            'multi': q.multi,
            'options': [for (final o in q.options) o.label],
          },
      ],
      // 未答时写空对象（不写 null：`_normalizeEntry` 会去掉 null 键，
      // 读方还得再判断"键缺了"和"没答案"两种状态）。
      'answers': answers ?? const <String, List<String>>{},
      'outcome': answers != null
          ? 'answered'
          : (_aborted ? 'cancelled' : 'timeout'),
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    if (answers == null) return null;
    return _formatAnswers(questions, answers);
  }

  /// UI 提交答案（题目 id → 选中的 label / 自填原文）。
  ///
  /// 返回 `true` = 确实交到了一个正在等待的提问；
  /// `false` = 没有活动提问（run 已结束 / 已超时 / 已取消）——
  /// **如实告知，不静默成功**。
  Future<bool> replyAsk(Map<String, List<String>> answers) async {
    final c = _pending;
    if (c == null || c.isCompleted) return false;
    _pending = null;
    c.complete(Map<String, List<String>>.from(answers));
    return true;
  }

  /// 把答案渲染成给模型看的**人话**：每题一行 `问题 → 回答`。
  ///
  /// · 未回答的题写「未回答」——**绝不编答案**
  /// · 空串/重复项过滤（UI 可能回传空自填框）
  String _formatAnswers(
    List<AskQuestion> questions,
    Map<String, List<String>> answers,
  ) {
    final buf = StringBuffer();
    for (final q in questions) {
      final picked = <String>[];
      for (final raw in answers[q.id] ?? const <String>[]) {
        final t = raw.trim();
        if (t.isNotEmpty && !picked.contains(t)) picked.add(t);
      }
      buf.writeln('${q.question} → ${picked.isEmpty ? '未回答' : picked.join('、')}');
    }
    return buf.toString().trimRight();
  }

  // ==========================================================================
  // 审批实现（2026-10-24 接线）
  //
  // 链路：backend `_ApprovalHook`（工具执行前）→ 本方法 → `kApprovalRequest`
  // 事件 → `chat_screen._showApprovalDialog`（已存在的 UI，字段 tool/args/reason）
  // → `AgentBridge.replyApproval(decision)` → [replyApproval] → 完成挂起。
  // ========================================================================

  /// 请求用户批准一次工具调用。
  ///
  /// ## 三个提前返回（都不弹窗）
  ///
  /// · **白名单命中** ⇒ 直接放行（`true`）—— 持久名单 + 本 run 内的
  ///   「始终允许」都在 [_allowed] 里，后端不感知白名单，只管"要批谁"。
  /// · **没有 UI 出口** ⇒ 拒绝（`false`，fail-closed）—— 测试/无头场景问不了人。
  /// · **已 abort**（用户点过停止）⇒ 拒绝 —— 不能在用户叫停之后还弹窗。
  ///
  /// ## 并发排队
  ///
  /// 框架可能 `Future.wait` **并行**执行一批工具调用，其中多个都需要审批。
  /// 同一时刻只能有一个弹窗 ⇒ 后到者**排队**等前一个决定完成再问
  /// （不能直接拒绝 —— 那是替用户做决定）。用户点停止时 [abort] 会
  /// 解掉挂起者，排队者看到 [_aborted] 后也按拒绝收场。
  ///
  /// ## 事件形状（N1）
  ///
  /// 发 `approval_required`：callId/tool/args/risk(=reason)/workspaceInside。
  /// **超时（5 分钟）= deny + 发 blocked 事件**（契约明确要求超时可见）。
  @override
  Future<bool> requestApproval({
    required String callId,
    required String toolName,
    required Map<String, String> args,
    required String risk,
    required String detail,
    required bool workspaceInside,
  }) async {
    // 白名单命中 ⇒ 自动放行（不是用户这次点的，但确实是一次决策）：
    // 落盘记 `always` / `auto_allowed`，历史回放能解释"为什么没弹窗"。
    if (_allowed.contains(toolName)) {
      _pushApproval(
        callId: callId,
        tool: toolName,
        decision: 'always',
        outcome: 'auto_allowed',
      );
      return true;
    }
    if (_emit == null) {
      // 没有 UI 出口 ⇒ fail-closed 拒绝；这也是一次决策，记账。
      _pushApproval(
        callId: callId,
        tool: toolName,
        decision: 'deny',
        outcome: 'denied',
      );
      return false;
    }
    if (_aborted) {
      _pushApproval(
        callId: callId,
        tool: toolName,
        decision: 'deny',
        outcome: 'cancelled',
      );
      return false;
    }

    // 等待已在挂起的审批结束（并行批次串行化）。
    while (_pendingApproval != null) {
      await _pendingApproval!.future;
      if (_aborted) {
        _pushApproval(
          callId: callId,
          tool: toolName,
          decision: 'deny',
          outcome: 'cancelled',
        );
        return false;
      }
    }

    final c = Completer<bool>();
    _pendingApproval = c;
    _pendingApprovalCallId = callId;
    _pendingApprovalTool = toolName;

    _emit!(AgentEvent(
      type: AgentEvent.kApprovalRequired,
      ts: DateTime.now().millisecondsSinceEpoch,
      callId: callId,
      tool: toolName,
      // UI 弹窗展示完整参数（审批的意义就是"看清楚再点允许"，不截断）
      args: args,
      reason: risk,
      message: detail,
      workspaceInside: workspaceInside,
    ));

    try {
      return await c.future.timeout(
        approvalTimeout,
        onTimeout: () {
          // N1：超时按 deny 处理，**并发 blocked 事件**（用户要知道
          // 弹窗为什么"自己没了"）—— fail-closed，绝不默认放行。
          _pushApproval(
            callId: callId,
            tool: toolName,
            decision: 'deny',
            outcome: 'timeout',
          );
          _emit!(AgentEvent(
            type: AgentEvent.kBlocked,
            ts: DateTime.now().millisecondsSinceEpoch,
            tool: toolName,
            reason: '审批超时（${approvalTimeout.inMinutes} 分钟）未决定，'
                '按拒绝处理（fail-closed）。',
          ));
          // ignore: avoid_print
          print('[heracles][approval] 审批超时未决定，按拒绝处理');
          return false;
        },
      );
    } finally {
      if (identical(_pendingApproval, c)) {
        _pendingApproval = null;
        _pendingApprovalCallId = null;
        _pendingApprovalTool = null;
      }
    }
  }

  /// UI 提交审批决定（N1 结构化：callId + decision）。
  ///
  /// · `decision` ∈ `deny` / `once`（允许一次）/ `always`（本会话始终允许，
  ///   回调持久化）；其它值/点外面 = 拒绝（安全默认）。
  /// · **callId 配对**：与挂起请求的 callId 不一致 ⇒ 如实返回 false
  ///   （迟到的旧答复不打进新请求）。
  /// · 返回 `true` = 确实交到了一个正在等待的审批；`false` = 没有挂起的
  ///   审批或 callId 不匹配 —— **如实告知，不静默成功**。
  Future<bool> replyApproval({
    required String callId,
    required String decision,
  }) async {
    final c = _pendingApproval;
    if (c == null || c.isCompleted) return false;
    if (callId != _pendingApprovalCallId) return false;
    _pendingApproval = null;
    final tool = _pendingApprovalTool;
    _pendingApprovalTool = null;
    _pendingApprovalCallId = null;
    // 兼容旧口径：`allow`/`allow_always` 仍接受，**落盘统一 once/always/deny**
    // （INTERFACE §6：旧值接受但落盘归一）。
    final normalized = (decision == 'allow' || decision == 'once')
        ? 'once'
        : (decision == 'allow_always' || decision == 'always')
            ? 'always'
            : 'deny';
    // 每条决定**只 push 一次**（本方法在 completer 完成前就清空了挂起字段，
    // 重复调用会在上面 `c == null` 处提前返回）。
    _pushApproval(
      callId: callId,
      tool: tool ?? '',
      decision: normalized,
      outcome: normalized == 'deny' ? 'denied' : 'allowed',
    );
    switch (normalized) {
      case 'once':
        c.complete(true);
      case 'always':
        // 先记账再放行：同一 run 里后续同工具调用直接放行（[requestApproval]
        // 的白名单检查），持久化通过回调交给桥接层（SharedPreferences）。
        if (tool != null) {
          _allowed.add(tool);
          onAlwaysAllow?.call(tool);
        }
        c.complete(true);
      default:
        // 'deny' / 点外面 / 未知值 —— 一律拒绝（安全默认）。
        c.complete(false);
    }
    return true;
  }
}

/// **进程内 agent 执行器**。
///
/// 生命周期：一次 run 一个实例（内部持有 `HeraclesAgent` 与取消状态）。
class LocalAgentExecutor {
  LocalAgentExecutor({
    required this.workspacePath,
    required this.settings,
    required this.sessionStore,
    this.askGate,
    this.clientForTest,
    this.capabilitiesForTest,
  });

  final String workspacePath;
  final AppSettings settings;
  final SessionStore sessionStore;

  /// 提问/审批门禁（UI 注入）。`null` = 当前环境不能问用户。
  final AskGate? askGate;

  /// **测试缝：假 LLM client**（类型 `dynamic` ⇒ app 不直接依赖
  /// `dart_agent_core`；生产为 `null`，走真实 provider 配置）。
  ///
  /// 存在的理由：JSONL 记账（step usage / approval / ask / 单写者 drain）
  /// 是 `_drive` 内部行为，只有真跑一次 run 才能端到端断言顺序与数值。
  final dynamic clientForTest;

  /// **测试缝：整套能力**（`null` ⇒ 按 `buildDeviceCapabilities` 组装）。
  /// 让 `_drive` 的端到端测试不必 mock MethodChannel。
  final Capabilities? capabilitiesForTest;

  // ==========================================================================
  // 插队发送队列（P0，2026-10-30）
  // ==========================================================================

  /// 队列上限（超过就**拒绝**第 5 条，不丢最旧 —— 见 [steerEnqueue]）。
  static const int steerQueueMax = 4;

  /// 待注入的插话（**只在本 run 内有效**；run 收尾清空）。
  ///
  /// ## 为什么是同步 `ListQueue` 而不是 Stream/锁
  ///
  /// Dart 是单 isolate 事件循环：`enqueueSteer`（UI 线程调）与 `takeSteer`
  /// （`_drive` 的 hook 回调）都跑在同一 isolate，同步读改写之间**没有
  /// await 缝隙** ⇒ 天然原子。真正要防的是"跨 run 串台"，靠"每 run 一个
  /// executor 实例"隔离（run 收尾清空）。
  final ListQueue<String> _steerQueue = ListQueue<String>();

  /// 插话入队的完整结果（内部/桥接用）。
  ///
  /// · `accepted`：本次调用被接受（新增 **或** 重复 —— 重复视为已接受，不再
  ///   多渲染一条用户消息）；
  /// · `added`：真的新增了一条（只有新增才该发 `interrupted` 事件给 UI）。
  ({bool accepted, bool added}) steerEnqueue(String text) {
    final t = text.trim();
    if (t.isEmpty) return (accepted: false, added: false);
    // 去重：同一句重复插话只保留一条，避免模型看到两遍。
    if (_steerQueue.contains(t)) return (accepted: true, added: false);
    if (_steerQueue.length >= steerQueueMax) {
      // 满了 ⇒ **拒绝**（返回 false，调用方走正常发送，消息不会丢）。
      return (accepted: false, added: false);
    }
    _steerQueue.add(t);
    return (accepted: true, added: true);
  }

  /// 插话入队（对外布尔口径）：`true` = 已接受。
  bool enqueueSteer(String text) => steerEnqueue(text).accepted;

  /// backend `_SteerHook` 的取件回调：每次轮结束取一条，空 ⇒ `null`。
  String? takeSteer() => _steerQueue.isEmpty ? null : _steerQueue.removeFirst();

  /// 清空队列（run 收尾/取消/失败）。
  void clearSteer() => _steerQueue.clear();

  /// 取走**全部**剩余插话（run 收尾时用于"未消费项不得静默丢"的提示）。
  List<String> takeAllSteer() {
    if (_steerQueue.isEmpty) return const <String>[];
    final list = _steerQueue.toList(growable: false);
    _steerQueue.clear();
    return list;
  }

  /// 当前队列长度（测试/排障用）。
  int get steerQueueLength => _steerQueue.length;

  /// 当前在跑的取消令牌（`null` = 没有 run 在跑）。
  ///
  /// ## 为什么取消要「令牌 + 标志」两件
  ///
  /// `CancelToken.cancel()` 只让**框架**停下来；我们的 `_drive` 还需要知道
  /// "这是用户主动取消的"（而不是框架判定循环），才能给出正确措辞
  /// （"任务已取消"而不是"检测到循环"）。
  ///
  /// ## 2026-10-24：令牌**真的接上了**
  ///
  /// 之前这里只有一个从未被任何代码 await 的 `_interruptSignal` ——
  /// `agent.run(...)` 不传 `cancelToken` ⇒ 点"停止"只是置标志位，
  /// LLM 流与工具执行**照常跑完**（假取消）。现在令牌传进
  /// `HeraclesAgent.run(cancelToken:)`：框架在轮次边界检查它、
  /// dio 收到 cancel 会**立刻掐断**在途的流式请求 —— 真中断。
  bool _cancelled = false;

  /// 跑一轮。
  ///
  /// 返回的 `events` 是**广播流**（UI 与调试面板可同时听）。
  ///
  /// ## `attachments`（2026-10-23 补）
  ///
  /// 图片附件在这里被真正接上：先按**模型是否支持视觉**判断，再压缩编码成
  /// `ImagePart`，最后作为 `UserMessage` 的额外内容块传给后端。
  /// 之前这条链路在 `AgentBridge → executor → agent` 三处逐段断掉，
  /// 导致"模型明明能识图，App 里却完全看不到图"。
  Future<LocalRunHandle> run({
    required String request,
    String? sessionId,
    List<HAttachment> attachments = const [],
  }) async {
    final controller = StreamController<AgentEvent>.broadcast();

    // ★ 真取消的令牌（2026-10-24）：创建于 run 开始、传进 agent.run，
    //   cancel() 时框架在轮次边界停下 + dio 掐断在途流式请求。
    final cancelToken = CancelToken();

    // ★★ 2026-10-23（修「提问不可用」）：把本 run 的事件出口接到提问门禁上。
    //
    // 为什么必须在这里接：`AskGate` 由桥接层创建（它要持有它才能把用户的
    // 回答交回来），但**事件流是执行器在 run 里才建出来的** —— 门禁没有
    // `controller.add` 就发不出 `ask_user` 事件 ⇒ 弹窗永远不会出现。
    //
    // `attach` 不是必须的（测试/CLI 直接跑 executor 时没有 UI）：那种情况
    // `askUser` 会如实返回 null（"问不了"），不会挂 10 分钟。
    final gate = askGate;
    if (gate is LocalAskGate) gate.attach(controller.add);

    // ---- 会话 id **先解析**（2026-10-29：三作用域记忆的前置条件）----
    //
    // 设计稿 §3.5.3 第 1 步：sid 必须在 `HeraclesAgent` 构造**之前**拿到。
    // 会话私有记忆按 `(workspacePath, sid)` 寻址；旧顺序是反的（agent 构造在前、
    // sid 在 `_drive` 里才解析）⇒ 构造时根本拿不到会话作用域。
    //
    // 语义与旧 `_drive` 内联逻辑一致：没有 sid ⇒ 新建；有 sid ⇒ touch。
    final sid = await _resolveSessionId(sessionId, request);

    // ---- 三作用域记忆服务（唯一的寻址/墓碑/淘汰/写队列实现）----
    //
    // 只注入「会话是否存在」这一个回调（第 3 步强校验用）：服务层不 import
    // SessionStore（避免与 App 服务层互相依赖），而这里本来就持有 sessionStore。
    final memoryService = ScopedMemoryService(
      hasSession: (ws, sid) {
        final sameWorkspace = ScopedMemoryService.normalizeWorkspacePath(ws) ==
            ScopedMemoryService.normalizeWorkspacePath(workspacePath);
        final store =
            sameWorkspace ? sessionStore : SessionStore(workspaceRoot: ws);
        return store.hasSession(sid);
      },
    );

    // ---- 能力组装（设备侧）----
    // ★ 沙箱执行面（2026-10-29）：**只有 App 内才注入**。
    //
    // 两个语义必须分清（backend 的路由靠它决定命令去哪跑）：
    //   · sandbox == null        ⇒ 「这个部署没有沙箱」⇒ 命令走手机 shell
    //   · sandbox 非 null 未就绪  ⇒ 「接了但没激活」  ⇒ **拒绝执行**
    //
    // App 内 Kotlin 桥已注册，所以注入；纯 Dart 测试 / CLI 走默认的 `false`。
    // 基础 rootfs 是内置的（离线、首次约 0.3 秒解包），不需要用户操作。
    //
    // ★ 记忆能力带**寻址**（2026-10-29）：workspace + 已解析的 sid。
    //   没有这个上下文，save_memory 就不知道写哪个作用域（旧实现写全局）。
    final caps = capabilitiesForTest ??
        buildDeviceCapabilities(
          workspaceRoot: workspacePath,
          includeSandbox: true,
          memorySessionId: sid,
          memoryService: memoryService,
        );

    // ---- 模型配置 ----
    final provider = settings.effectiveProvider!; // 调用方已校验非 null
    final config = BackendConfig(
      apiKey: provider.apiKey,
      modelName: provider.model,
      baseUrl: provider.baseUrl,
      // ★ 推理档位（2026-10-24 接线）：设置的 Off/Low/High/Max →
      //   provider 无关概念 → 框架 extra → OpenAI 轨的 reasoning_effort。
      //   auto 不下发（旧行为）；Anthropic/Responses 轨暂不生效（框架不读）。
      reasoningEffort: settings.reasoningLevel.reasoningEffort,
      provider: switch (provider.protocol) {
        ProviderProtocol.anthropic => BackendProvider.anthropic,
        ProviderProtocol.openaiResponses => BackendProvider.openAiResponses,
        ProviderProtocol.openaiChat => BackendProvider.openAiCompatible,
      },
      // ★ 单窗口上限走全 App 单一口径 [effectiveContextWindow]
      //   （逐模型能力优先 —— 2026-10-29 修总数跳变：此前这里
      //   只读单值 contextLength，常为 0 → 掉 128K 契约默认，
      //   而用量抽屉读逐模型能力 1M，两处互相覆盖来回跳）。
      //   未知 ⇒ 契约默认值（压缩需要一个数，别拿 4K 压 1M）。
      modelWindowTokens: provider.effectiveContextWindow > 0
          ? provider.effectiveContextWindow
          : ContractModel.defaultWindowTokens,
    );
    // N2：上限与来源（context_updated 帧载荷；与 ContextUsage 口径一致）。
    // 存实例字段 —— _drive 里发帧要用（executor 每次 run 新建，无跨 run 串扰）。
    effectiveWindow = provider.effectiveContextWindow > 0
        ? provider.effectiveContextWindow
        : ContractModel.defaultWindowTokens;
    effectiveWindowSource =
        provider.effectiveContextWindow > 0 ? '服务端上报' : '按契约默认值';

    // ---- 轮次上限 ----
    // `settings.maxTurns == 0` 的语义是"按后端自动"（UI 的 `kMaxTurnsOptions`）。
    final maxTurns = settings.maxTurns > 0 ? settings.maxTurns : ContractAgent.maxTurns;

    // ---- 长期记忆（三作用域，2026-10-29 重写）----
    //
    // ## 旧实现的两个问题
    //
    // 1. 只读一份 App 全局 `memory.md`（没有作用域概念 ⇒ 别的项目的记忆会串进来）；
    // 2. 读失败只能当"没有记忆"（`read() → ''`，"空"与"错"同形）。
    //
    // ## 现在的读取（设计稿 §3.5.3 第 2 步）
    //
    // **并发读三处**（global / workspace / session），各自 900 ms 超时：
    // 失败 ⇒ 该段为空，**不阻断运行**（记忆是锦上添花，不是主链路）；
    // 但 global 段受设置开关 `memoryGlobalEnabled` 控制（关掉不读也不注入，
    // 数据保留）。
    //
    // 读到的三段原样交给 backend（`RunOptions.memory`）—— 排序/预算/渲染
    // 全在 backend 纯 Dart（`memory_prompt.dart`，有 `dart test` 覆盖），
    // 宿主只负责"读好数据"，不拼字符串（那会让预算与冲突裁决无从实现）。
    //
    // ## 为什么必须在 `HeraclesAgent` 构造之前
    //
    // `RunOptions.memory` 是构造参数；构造完再读就来不及了（要重建 agent）。
    // ---- 迁移触发点（设计稿 §3.7.2 步骤 0，2026-10-29）----
    //
    // App 启动后、**首轮记忆读取之前** best-effort 调一次 `memory.migrate`：
    // 旧单文件 `<externalFilesDir>/heracles/memory.md` → `memory/global.jsonl`
    // （备份 + 幂等 + 不丢条目，全在 Kotlin 侧）。
    //
    // 三条纪律：
    // 1. **一次性**（`runMemoryMigrationOnce` 内有进程内 bool）—— 不该每轮打通道；
    // 2. **不阻断**：超时 3 秒即放弃（失败只 debugPrint，绝不让迁移冻住首轮）；
    // 3. 失败 ⇒ 旧文件原样保留，读取仍走旧格式兼容解析（`memory.read` 兼容）。
    try {
      await runMemoryMigrationOnce().timeout(const Duration(seconds: 3));
    } catch (_) {
      // 迁移是增强：失败/超时都不该影响本轮对话。
    }

    final memoryContext = await _readMemoryContext(
      service: memoryService,
      sessionId: sid,
    );

    // ---- 工作区宪法（H4，2026-10-24 接通）----
    //
    // ## 修之前为什么模型对工作区"零感知"
    //
    // system prompt 只有静态默认提示 + 长期记忆。工作区里有没有说明文件
    // （构建命令、目录结构、项目约定）模型完全不知道，只能自己 list_files
    // 摸索 —— system_prompt.dart 的 KDoc 记录的"列文件跑 22 轮"事故，
    // 根因就是开场没有工作区上下文，当时只用提示词（停止条件）压住了症状。
    //
    // ## 现在的规则
    //
    // 按 AGENTS.md → CLAUDE.md → README.md 的顺序找**第一个存在的**，
    // 整段注入 system prompt（`RunOptions.systemPrompts`，位于默认提示之后、
    // 长期记忆之前 —— 两段都是"字节稳定"的，缓存前缀不受影响）。
    // 三个都不存在 ⇒ 不注入任何东西（行为与以前完全一致）。
    //
    // ## 失败不阻断（与记忆同一条纪律）
    //
    // 宪法是增强，不是主链路：读不到（文件不存在 / SAF 失败 / 通道超时）
    // 就当"没有宪法"继续跑。900ms 超时与记忆读取同款 —— 这条通道在
    // 真机上挂过（local_agent.dart 顶部的记忆读取注释）。
    //
    // ## 大小上限（ContractWorkspace.constitutionMaxChars = 20000）
    //
    // 超限**截断并明说** —— 用户要知道模型看到的是节选，不能静默。
    String? constitutionNote;
    try {
      final ch = const DeviceChannelClient();
      for (final name in const ['AGENTS.md', 'CLAUDE.md', 'README.md']) {
        final raw = await ch
            .call('fs.readText', <String, Object?>{
              'path': name,
              'offsetLine': 1,
              'maxLines': 0,
            })
            .timeout(const Duration(milliseconds: 900));
        if (errorOf(raw) != null) continue; // 不存在/读不了 ⇒ 试下一个
        final text = ((raw['text'] as String?) ?? '').trim();
        if (text.isEmpty) continue;
        final cap = ContractWorkspace.constitutionMaxChars;
        final body = text.length <= cap
            ? text
            : '${text.substring(0, cap)}\n\n……（原文共 ${text.length} 字符，'
                '已截断到前 $cap 字符）';
        constitutionNote = '## 工作区说明（来自 `$name`，项目自己的约定）\n\n'
            '$body\n\n'
            '（以上是项目在工作区里写的说明：构建命令、目录结构、约束等。'
            '若与用户当前指令冲突，以用户当前指令为准。）';
        break;
      }
    } catch (_) {
      // 保持 null（当作没有宪法）。
    }

    // ---- 工作区快照（F8 等价物，2026-10-24 接通）----
    //
    // ## 修的是什么
    //
    // 模型开场对工作区结构零感知（宪法是"人写的说明"，不是"目录长什么样"）
    // ⇒ 只能自己 list_files 摸索 —— system_prompt.dart 记录的"列文件跑 22 轮"
    // 事故的另一半根因。快照 = 一次 fs.list（递归、上限见契约）摊平成相对路径
    // 清单，随 system prompt 进场。
    //
    // ## 取舍
    //
    // · 跳过 .heracles/（会话存储目录，纯噪音）；
    // · 超限（截断）**如实标注**，模型要精查用 find_files；
    // · 内容随工作区变化 ⇒ 那一轮前缀重建（与宪法/记忆同一性质的税，记账不掩盖）。
    String? snapshotNote;
    // R2：词法检索注入（相关片段 + 出处）—— 建在快照之后
    String? ragNote;
    try {
      final raw = await const DeviceChannelClient()
          .call('fs.list', <String, Object?>{
            'path': workspacePath,
            'recursive': true,
            'maxEntries': ContractWorkspace.snapshotMaxEntries,
          })
          .timeout(const Duration(milliseconds: 1200));
      if (errorOf(raw) == null && (raw['entries'] is List)) {
        final lines = <String>[];
        for (final item in raw['entries'] as List) {
          if (item is! Map) continue;
          var p = (item['path'] ?? '').toString().replaceAll('\\', '/');
          final prefix = workspacePath.replaceAll('\\', '/');
          if (p.startsWith('$prefix/')) p = p.substring(prefix.length + 1);
          if (p.startsWith('./')) p = p.substring(2);
          if (p.isEmpty || p == '.') continue;
          if (p == '.heracles' || p.startsWith('.heracles/')) continue;
          final isDir = item['isDir'] == true;
          lines.add(isDir ? '$p/' : p);
        }
        if (lines.isNotEmpty) {
          final truncated = raw['truncated'] == true;
          snapshotNote = '## 工作区文件树（相对路径，共 ${lines.length} 项'
              '${truncated ? '，已截断' : ''})'
              '\n${lines.join('\n')}\n'
              '${truncated ? '（条目超过上限，未全部列出）' : ''}';

          // ★ R1-R3（2026-10-25，词法口径）：用快照清单建索引 + 按任务检索
          //   相关片段（正文命中 + 文件名加权）。预算硬上限，失败静默。
          try {
            final wsCaps = buildDeviceCapabilities(workspaceRoot: workspacePath);
            final idx = WorkspaceIndex();
            await idx.build(wsCaps.workspace!, lines)
                .timeout(const Duration(seconds: 3));
            final hits = idx.search(request, maxResults: 3);
            if (hits.isNotEmpty) {
              final buf = StringBuffer('## 工作区相关片段（词法检索，带出处）\n');
              for (final h in hits) {
                buf.writeln('- ${h.render()}');
              }
              ragNote = buf.toString().trimRight();
            }
          } catch (_) {
            // 静默：检索是增强
          }
        }
      }
    } catch (_) {
      // 保持 null（当作没有快照）。
    }

    // ---- 图片附件 → 多模态输入（2026-10-23 接通）----
    //
    // ## 修之前发生了什么
    //
    // 用户上传图片后，模型完全看不到 —— 因为附件在**三处**逐段被丢掉：
    //   `AgentBridge.run(attachments:)` ❌ 收了没用
    //   `LocalAgentExecutor.run()`        ❌ 参数表里根本没有附件
    //   `HeraclesAgent.run()`             ❌ 只收 String，首轮硬编码纯文本
    //
    // ## 两个必须做对的地方
    //
    // 1. **能力判断**（[modelSupportsVision]）：纯文本模型收到图片块会 400
    //    或**静默忽略**。后者更糟 —— 用户以为模型看过图。所以不支持时
    //    **不塞图**，并把这个事实明说给用户。
    // 2. **压缩**（[prepareImageParts]）：手机照片 base64 后 4–7 MB，
    //    不压缩基本等于把这一轮发废。
    List<ImageInput>? images;
    final imageNotes = <String>[];
    if (attachments.isNotEmpty) {
      final imageCount = attachments.where((a) => a.isImage).length;
      final support = visionSupportOf(provider.model);
      if (imageCount > 0 && support == VisionSupport.no) {
        // 只有**明确知道**是纯文本模型才拦；"未知"照发（见 VisionSupport 注释）
        imageNotes.add(
          '当前模型「${provider.model}」是纯文本模型，$imageCount 张图片没有发送。'
          '（可切换到支持视觉的模型后再发一次）',
        );
      } else if (imageCount > 0) {
        try {
          final prepared = await prepareImageParts(attachments);
          if (prepared.images.isNotEmpty) images = prepared.images;
          imageNotes.addAll(prepared.notes);
        } catch (e) {
          // 图片是**增强**，不是主链路：处理不了就明说，别拖垮整轮
          imageNotes.add('图片处理失败：${e.runtimeType}。本轮按纯文本发送。');
        }
      }
    }

    final agent = HeraclesAgent(
      config: config,
      capabilities: caps,
      options: RunOptions(
        maxTurns: maxTurns,
        maxToolCalls: ContractAgent.maxToolCalls,
        // ★ 三作用域记忆（2026-10-29）：结构化传入，排序/预算/渲染在 backend。
        //   非空即优先（即使三段都空也不回落旧 memoryNote —— 旧字段已 @Deprecated）。
        memory: memoryContext,
        // ★ 插队发送（P0，2026-10-30）：轮结束取一条插话 ⇒ backend `_SteerHook`
        //   注入成 UserMessage；不打断在途流/工具。队列在本实例（每 run 一个）。
        takeSteerMessage: takeSteer,
        // ★ 工作区宪法（H4，2026-10-24）：注入 system prompt
        //  （默认提示之后、长期记忆之前 —— 两段稳定字节之间的新段，
        //   只有宪法内容本身变化时才动前缀）。
        systemPrompts: [
          ?constitutionNote,
          ?snapshotNote,
          ?ragNote,
        ],
        // ★ 审批档位（2026-10-24 接线）：从设置显式映射。
        //   backend 库默认 fullAccess（不拦，库没有 UI 可问）；
        //   App 是有 UI 的宿主，**必须**把用户选的档位传下去 ——
        //   拦截在 backend 的 `_ApprovalHook`，"问谁"在 [LocalAskGate]。
        // ★ 子代理（H6，2026-10-24）：App 显式开启 —— 探索/核对类子任务
        //   在干净上下文里跑，主上下文只收结论。
        enableSubAgents: true,
        // ★ 内置技能（S1/S2，2026-10-24）：目录常驻（每条一行），
        //   模型按任务用 activate_skills 按需加载全文。
        enableSkills: true,
        approvalMode: switch (settings.permission) {
          PermissionMode.manual => ApprovalMode.manual,
          PermissionMode.workspaceAuto => ApprovalMode.workspaceAuto,
          PermissionMode.fullAccess => ApprovalMode.fullAccess,
        },
      ),
      askGate: gate,
      client: clientForTest, // 测试缝（生产 null ⇒ 用 config 建真实 client）
    );

    final tr = _Translator(controller.add);

    // ---- 真正驱动（不 await，让 events 先被订阅）----
    final done = _drive(
      agent,
      tr,
      request,
      sid, // 2026-10-29：sid 已在构造前解析（记忆寻址的前置条件）
      controller,
      images: images,
      imageNotes: imageNotes,
      attachments: attachments,
      cancelToken: cancelToken,
    );

    return LocalRunHandle(
      events: controller.stream,
      result: done,
      // 插队发送：桥接层 `interruptRun` 用它把用户插话放进本轮队列。
      enqueueSteer: steerEnqueue,
      cancel: () async {
        if (_cancelled) return false;
        // 标记"这是用户取消"，让收尾措辞正确
        _cancelled = true;
        // ★ 2026-10-23：若此刻正在等用户回答/审批，先把它解掉 ——
        //   否则 backend 的 `ask_user` / 审批挂起会白等满 10 分钟，用户以为
        //   「停止」没生效。解掉后工具拿到 null/false（= 未回答/拒绝），如实收场。
        if (gate is LocalAskGate) gate.abort();
        // ★ 2026-10-24：**真取消** —— 令牌传进了 agent.run：
        //   dio 掐断在途的流式请求，框架在轮次/工具边界停下。
        //   （此前这里只置标志位，LLM 流与工具照常跑完 —— 假取消。）
        cancelToken.cancel('用户取消');
        return true;
      },
    );
  }

  /// 本轮**送给模型**的请求文本：用户原话 + 附件提示（如果有）。
  ///
  /// ## 为什么提示只加在这里，不加进 `request` 本身
  ///
  /// `request` 同时是**落盘的用户消息**（会话 `.jsonl` 的 `role:"user"` 行，
  /// 也是界面上那个气泡）。把"图片被跳过"这类系统提示写进去，用户会看到
  /// 自己的话被改写了 —— 那是绝对不能做的。
  ///
  /// 所以：**模型看到的是"原话 + 提示"，会话里存的是原话**。
  /// 提示用方括号独立成段，并明确写出"不要复述这段元信息"，
  /// 避免模型把它当成用户问题的一部分来回答。
  /// 解析/创建本轮会话 id（2026-10-29：**必须在 agent 构造之前**调用）。
  ///
  /// 以前这段逻辑在 `_drive` 里（agent 构造之后）—— 会话私有记忆按
  /// `(workspacePath, sid)` 寻址，构造后再解析就来不及了。
  ///
  /// 语义与旧内联逻辑一致：无 sid ⇒ 新建（标题取本轮请求）；有 sid ⇒ touch
  /// （刷新 `updatedAt`，让会话列表按"最后活动时间"排序）。
  Future<String> _resolveSessionId(String? sessionId, String request) async {
    final existing = sessionId?.trim() ?? '';
    if (existing.isEmpty) {
      return sessionStore.createSession(_titleOf(request));
    }
    await sessionStore.touchSession(existing);
    return existing;
  }

  /// **并发读三作用域记忆**（设计稿 §3.5.3 第 2 步）。
  ///
  /// ## 三条纪律
  ///
  /// 1. **并发**：三段互不依赖，串行会让首字延迟翻三倍；
  /// 2. **各自 900 ms 超时**：真机实测过通道调用"永不返回"会导致整个 run
  ///    一个事件都发不出来（旧 `memoryNote` 注释记的冻死事故）—— 记忆是
  ///    锦上添花，**绝不能冻住主链路**；超时/失败 ⇒ 该段为空；
  /// 3. **global 受设置开关控制**：`memoryGlobalEnabled == false` ⇒ 不读也不
  ///    注入（数据保留；存储与注入解耦）。
  ///
  /// 读到的是结构化三段（[ScopedMemoryEntry] → backend [MemoryRecord]）：
  /// 排序/预算/冲突裁决全在 backend，宿主编排层**不拼字符串**。
  ///
  /// ⚠️ `settings.memoryPooling` 当前只持久化、**未接线**（默认 false，
  /// 开启不改变行为；池化需要按 `(scope,scopeId)` 的强校验缓存，留给后续）。
  Future<MemoryContext> _readMemoryContext({
    required ScopedMemoryService service,
    required String sessionId,
    int timeoutMs = 900,
  }) {
    final ws = ScopedMemoryService.normalizeWorkspacePath(workspacePath) ??
        workspacePath;
    return _buildMemoryContext(
      (scope, sid) async {
        final r = await service.read(MemoryAddress(
          scope: scope,
          sessionId: scope == MemoryScope.session ? sid : null,
          workspacePath: scope == MemoryScope.global ? null : ws,
        ));
        return r.entries;
      },
      sessionId: sessionId,
      timeoutMs: timeoutMs,
    );
  }

  /// **测试缝**：不碰通道地构造三作用域记忆上下文（端到端探针用）。
  ///
  /// 生产路径 [run] 用 [_readMemoryContext]（读真的 service）；探针用这个
  /// 注入假读取函数，验证的正是本类的编排逻辑：三 scope 并发、各自超时、
  /// global 开关、`ScopedMemoryEntry → MemoryRecord` 转换。**不复制任何
  /// 业务规则**（排序/预算/渲染仍在 backend）。
  Future<MemoryContext> memoryContextForTest({
    required Future<List<ScopedMemoryEntry>> Function(
            MemoryScope scope, String? sid)
        read,
    required String sessionId,
    int timeoutMs = 900,
  }) =>
      _buildMemoryContext(read, sessionId: sessionId, timeoutMs: timeoutMs);

  Future<MemoryContext> _buildMemoryContext(
    Future<List<ScopedMemoryEntry>> Function(MemoryScope scope, String? sid) read, {
    required String sessionId,
    int timeoutMs = 900,
  }) async {
    final globalEnabled = settings.memoryGlobalEnabled;

    Future<List<ScopedMemoryEntry>> readOne(
      MemoryScope scope, {
      String? sid,
    }) async {
      try {
        return await read(scope, sid).timeout(Duration(milliseconds: timeoutMs));
      } catch (_) {
        // 该段为空，不阻断（错误排障靠 service 自己的日志；不打印正文）。
        return const <ScopedMemoryEntry>[];
      }
    }

    final results = await Future.wait(<Future<List<ScopedMemoryEntry>>>[
      if (globalEnabled)
        readOne(MemoryScope.global)
      else
        Future<List<ScopedMemoryEntry>>.value(const <ScopedMemoryEntry>[]),
      readOne(MemoryScope.workspace),
      readOne(MemoryScope.session, sid: sessionId),
    ]);

    List<MemoryRecord> recordsOf(List<ScopedMemoryEntry> list) =>
        list.map((e) => e.toRecord()).toList(growable: false);

    return MemoryContext(
      global: recordsOf(results[0]),
      workspace: recordsOf(results[1]),
      session: recordsOf(results[2]),
      globalEnabled: globalEnabled,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// **把 gate 缓冲的决策日志落盘**（2026-10-29；`_drive` 是唯一写者）。
  ///
  /// 只在 [gate] 是 [LocalAskGate] 时生效（其它 `AskGate` 实现没有缓冲协议）。
  /// 每条单独 try/catch：一条写失败不能拖垮后面的决策记账，更不能让 run 失败
  /// —— 决定已经生效（工具已放行/已拒绝），记账是**事后事实**，不是前置条件。
  Future<void> _drainDecisionJournal(AskGate? gate, String sid) async {
    if (gate is! LocalAskGate) return;
    final rows = gate.takeJournal();
    for (final row in rows) {
      try {
        await sessionStore.appendMessage(sid, row);
      } catch (_) {
        // 静默：见方法注释。
      }
    }
  }

  String _requestForModel(String request, List<String> imageNotes) {
    if (imageNotes.isEmpty) return request;
    final buf = StringBuffer()
      ..writeln(request)
      ..writeln()
      ..writeln('[附件处理提示（系统生成，请在回答里如实告知用户，不要复述本段原文）]');
    for (final n in imageNotes) {
      buf.writeln('· $n');
    }
    return buf.toString();
  }

  /// 执行体：把 `HeraclesAgent.run()` 的事件逐条翻译并落盘。
  Future<AgentRunResult> _drive(
    HeraclesAgent agent,
    _Translator tr,
    String request,
    String sid,
    StreamController<AgentEvent> controller, {
    List<ImageInput>? images,
    List<String> imageNotes = const [],
    List<HAttachment> attachments = const [],
    CancelToken? cancelToken,
  }) async {
    final sw = Stopwatch()..start();

    // 会话 id 已在 `run()` 里解析（2026-10-29：记忆寻址的前置条件）——
    // 这里不再创建/touch，避免"构造前解析一次、这里又建一次"的双写。

    // ---- 跨轮记忆：读会话历史（2026-10-23 修）----
    //
    // ★★ **必须在下面"用户消息落盘"之前读** ★★
    //
    // 落盘之后读，就会读到本轮刚写进去的那条 user 行 ⇒ 模型看到
    // **同一条用户消息出现两遍**（历史里一遍 + 本轮 request 一遍）。
    // 顺序就是正确性，所以这两步紧邻、且读在前。
    //
    // ## 修之前为什么"模型记不住上一轮"
    //
    // 每次 run 都 `new HeraclesAgent(...)`，而它的 `_state` 是 `??=`
    // 初始化 ⇒ 每个实例都从**空历史**开始。加上这里从来没读过会话文件，
    // 模型看不到上一轮的 user/assistant —— 表现是"它忘了刚才在聊什么"，
    // 顺带让前缀缓存几乎全不命中（真机 1%）。
    //
    // ## 读失败怎么办
    //
    // **不阻断运行**：历史读不到只意味着"这轮没有记忆"，任务本身还能做。
    // 所以当空历史处理 —— 最差退化回旧行为（不会崩、不会假装有记忆）。
    // （`SessionStore.loadMessages` 自身把人话原因放进返回值、不抛；
    //   这里兜的是意料之外的异常。）
    //
    // ## 为什么用 `var` 不写显式类型
    //
    // `LLMMessage` 属于 `dart_agent_core`，而那个包在 `app/pubspec.yaml` 里
    // 只是**传递依赖**（app 只依赖 `heracles_backend`）。写显式类型就得
    // `import 'package:dart_agent_core/...'` ⇒ 触发
    // `depend_on_referenced_packages`，并把"谁的依赖谁负责"这条边界糊掉。
    // 让编译器从 `sessionRowsToHistory` 的返回值推导即可。
    var history = sessionRowsToHistory(const <Map<String, dynamic>>[]);
    try {
      // ★ 2026-10-23：与记忆读同一类风险 —— **必须带超时**。
      // 这条走 `fs.readTailLines`（本轮新增的通道方法），真机上若它不返回，
      // run 同样会永远停在起点（用户只看到自己的气泡，没有任何反应）。
      // 历史读不到 ⇒ 空历史继续跑（最差退化成"这轮没有跨轮记忆"）。
      final rows = await sessionStore
          .loadMessages(sid)
          .timeout(const Duration(milliseconds: 1800));
      // `dropLastUserIfMatches`：双保险。
      //
      // 正常路径下这里读的是**落盘之前**的文件，所以末尾不会有本轮那条。
      // 但有两种情况会让它出现：
      //   · 重试/重入（同一个 sessionId 的上一轮刚好写过同样的请求）
      //   · 将来把"读"挪到别处、顺序被人改错
      // 一旦出现，模型就会看到同一条用户消息两遍。
      // 这里顺手挡掉 —— 代价是"用户真的重复问同一句"时那一轮的历史里
      // 会少一条重复项，但本轮请求本身还在，语义不丢。
      history = sessionRowsToHistory(
        rows,
        dropLastUserIfMatches: request,
      );
    } catch (_) {
      // 保持空历史。
    }

    // 用户消息先落盘（与旧 Kotlin 的顺序一致：用户消息先于一切）
    // ★ 附件结构化落盘（2026-10-29）：path/name/kind —— 读回时
    //   气泡能把图片渲染成图。只增字段，老版本读到会原样保留
    //   （_normalizeEntry 未知键透传），不破坏兼容。
    await sessionStore.appendMessage(sid, {
      'role': 'user',
      'text': request,
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map((a) => <String, dynamic>{
                  'path': a.path,
                  'name': a.name,
                  'kind': a.kind.name,
                })
            .toList(),
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    tr.sessionId = sid;

    /// 待配对的工具调用：`工具名 → [(参数, 发起时轮次), …]`（桶内 FIFO）。
    ///
    /// ## 为什么必须带上"发起时轮次"
    ///
    /// UI 用 `_toolKey(index, tool, args)` 配对 start/finish。框架是
    /// **发起工具 → 进下一轮 → 工具才回结果**，等结果回来时翻译器的
    /// `_turn` 已经变了 ⇒ 若不记住发起时的轮次，卡片会永远停在"执行中"
    /// （真机复现：`正在查看目录文件 执行中`，而落盘日志是 `succeeded`）。
    ///
    /// ## 为什么按"工具名分桶 + 桶内 FIFO"
    ///
    /// 框架可能 `Future.wait` **并行**跑同名工具（例如同时读两个文件），
    /// 按名字存单个值会互相覆盖（旧实现"耗时按名字配对"就是这个形状的 bug）。
    /// 2026-10-29（D6）：桶里额外记 `surface`/`command`（工具**请求时**的
    /// 执行面预判与实际命令）—— 完成事件只带 metadata，命令要从发起时留存，
    /// 否则历史命令卡只能拿到 args（回放时还得再猜一次）。
    final pendingArgs = <
        String,
        List<
            ({
              Map<String, dynamic> args,
              String id,
              int turn,
              String? surface,
              String? command,
            })>>{};

    var failed = false;
    var cancelled = false;
    var finalText = '';

    /// 本轮**总轮数**（`HeraclesFinished.turns`）—— 会话用量汇总用。
    ///
    /// `null` = run 没有正常收尾（取消/异常），此时退化为 `tr.currentTurn`。
    int? finishedTurns;

    // ---- 计划终态（B8 P0，2026-10-30）----
    //
    // `HeraclesPlanClosed` 只在**本轮有过计划**时才会来（backend 保证）。
    // 到达时：①翻译成 `AgentEvent.kPlanClosed` 给 UI；②把终态先存下来，
    // 收尾时在 assistant 行**之前**追加一条**最终 plan 行**（带 reachedGoal/
    // closedReason），让"重开会话"也能看出计划是达成还是被打断。
    //
    // 单写者：这里只在 `_drive` 的事件循环/收尾区写，`appendMessage` 逐条 await
    // —— 并发闸语义不变（与既有 plan 行/step 行同一串行链）。
    List<Map<String, dynamic>> lastPlanSteps = const <Map<String, dynamic>>[];
    bool? planClosedReachedGoal;
    String? planClosedReason;

    /// plan 行 JSON 形状（与既有 role:"plan" 行一致；只增两个终态字段）。
    ///
    /// 旧行没有 `reachedGoal`/`closedReason` ⇒ 读方按 null（未知）处理，
    /// 不需要重写历史文件（append-only 纪律）。
    Map<String, dynamic> planRow({
      required List<Map<String, dynamic>> steps,
      bool? reachedGoal,
      String? closedReason,
    }) =>
        <String, dynamic>{
          'role': 'plan',
          'steps': steps,
          'ts': DateTime.now().millisecondsSinceEpoch,
          // ★ 只增字段：已知终态才写键（旧行/未收尾行没有 = null）。
          'reachedGoal': ?reachedGoal,
          if (closedReason != null && closedReason.isNotEmpty)
            'closedReason': closedReason,
        };

    // ★ 变更聚合（2026-10-22，用户要求对齐参考界面的"已编辑 N 个文件"卡片）
    //
    // 数字来源是**工具结果里的 diff**（`diffStatOf`），不是模型自报 ——
    // 自报会撒谎，diff 不会。写类工具按**相对路径**聚合（同一文件改两次
    // 合并成一行，增删相加）。
    final changes = <String, ({int added, int removed})>{};
    const writeTools = {
      'write_file', 'edit', 'apply_patch', 'mkdir',
      'delete_path', 'move_path', 'copy_path',
    };

    try {
      // ★ 跨轮记忆在这里生效：`history` 成为 state 的开头，
      //   本轮 `request` 由框架追加在其**之后**（append-only，前缀缓存靠它）。
      //
      // ★ 图片与附件提示：`images` 进 `UserMessage` 的多模态内容块；
      //   `imageNotes` **只加给模型这一轮**（提示它"有图没发出去/被跳过"），
      //   不写进会话文件 —— 用户气泡必须保持他自己打的原话。
      await for (final ev in agent.run(
        _requestForModel(request, imageNotes),
        history: history,
        images: images,
        cancelToken: cancelToken,
      )) {
        // ★ 2026-10-29（JSONL 记账）：**每个事件处理之前** drain 一次。
        //
        // `LocalAskGate` 只把审批/提问决策 push 进缓冲（gate 内绝不 await
        // append —— 那会拖慢决定生效、还会撞 appendMessage 的并发闸）；
        // `_drive` 是**唯一写者**：在这里落盘，能保证
        // · approval 行排在它对应的 tool 行**之前**（决策先于执行结果）；
        // · ask 行与工具行/步骤行保持事件到达顺序。
        await _drainDecisionJournal(askGate, sid);
        switch (ev) {
          case HeraclesThoughtDelta(:final delta):
            tr.thought(delta);
          case HeraclesTextDelta(:final delta):
            tr.text(delta);
          case HeraclesRetrying(:final reason):
            tr.retrying(reason);
          case HeraclesTurnUsage(
              :final promptTokens,
              :final outputTokens,
              :final cachedTokens,
            ):
            // 逐轮用量（provider 真实上报）—— 顶栏命中率 / 侧栏 / 本次用量的数据源
            tr.usage(
              prompt: promptTokens,
              output: outputTokens,
              cached: cachedTokens,
            );
            // ★ N2（2026-10-24）：每轮随用量发一帧分项统计（环图数据源）。
            //   估算与压缩器同源（口径稳定）；limit = 用户配置的窗口。
            try {
              tr.contextUpdated(
                agent.contextBreakdown(),
                limit: effectiveWindow,
                limitSource: effectiveWindowSource,
              );
            } catch (_) {
              // 构不成统计（还没跑过/异常）就不发 —— 前端沿用上一帧。
            }
          case HeraclesToolRequested(
              :final toolName,
              :final arguments,
              :final id,
              :final surface,
              :final command,
            ):
            tr.toolRequested(toolName, arguments, surface: surface, command: command);
            (pendingArgs[toolName] ??= <
                ({
                  Map<String, dynamic> args,
                  String id,
                  int turn,
                  String? surface,
                  String? command,
                })>[])
                .add((
              args: arguments,
              turn: tr.currentTurn,
              id: id,
              surface: surface,
              command: command,
            ));
            // ★ 工具调用行落盘（2026-10-24）：发起时写 `tool_call` 行、
            //   带框架调用 id —— 历史回填靠它与结果行配对，重建
            //   ModelMessage(functionCalls) + FunctionExecutionResultMessage
            //   （session_history.dart 取舍①）。id 为空（provider 没给）
            //   就不写：回填对它退回旧行为（跳过），不会产生半批。
            if (id.isNotEmpty) {
              await sessionStore.appendMessage(sid, {
                'role': 'tool_call',
                'id': id,
                'tool': toolName,
                'args': arguments,
                'ts': DateTime.now().millisecondsSinceEpoch,
              });
            }
          case HeraclesToolFinished(
              :final toolName,
              :final isError,
              :final output,
              :final durationMs,
              :final metadata,
              :final id,
            ):
            final bucket = pendingArgs[toolName];
            final pending = (bucket != null && bucket.isNotEmpty)
                ? bucket.removeAt(0)
                : null;
            final args = pending?.args ?? const <String, dynamic>{};
            tr.toolFinished(
              toolName,
              args,
              isError,
              output,
              durationMs,
              turn: pending?.turn,
              metadata: metadata,
            );
            // 本轮用量 + 工具信息齐了 ⇒ 结清成一条 AgentTurn
            tr.settleTurn();
            // 写类工具且成功 ⇒ 计入变更报告（失败不计：什么都没改）
            if (!isError && writeTools.contains(toolName)) {
              // ★ 与工具卡片同一套取数逻辑（`_stat`）：
              //   结果里有 diff 就用 diff（权威），没有才退回按参数估算
              //   （`content` 的行数 / `new_string`-`old_string`）。
              //   真机教训：只用 `diffStatOf(output)` 时 write_file 的
              //   结果没有 diff 正文 ⇒ 卡片算出 +0 −0（假数字）。
              final strArgs = args.map((k, v) => MapEntry(k, v.toString()));
              final fromResult = diffStatOf(output);
              final stat = fromResult.isDiff ? fromResult : estimatedDiffStatOf(strArgs);
              for (final f in changedFilesOf(strArgs)) {
                final prev = changes[f];
                changes[f] = (
                  added: (prev?.added ?? 0) + stat.added,
                  removed: (prev?.removed ?? 0) + stat.removed,
                );
              }
            }
            // ★ D6（2026-10-29，用户拍板）：历史命令卡要**真实**执行面/退出码/
            //   命令。只增字段、不写假数据 —— 具体规则见 [buildToolRow]。
            await sessionStore.appendMessage(
              sid,
              buildToolRow(
                tool: toolName,
                args: args,
                result: output,
                isError: isError,
                id: id,
                metadata: metadata,
                requestedSurface: pending?.surface,
                requestedCommand: pending?.command,
                ts: DateTime.now().millisecondsSinceEpoch,
              ),
            );
          case HeraclesFallback(:final from, :final to, :final reason):
            tr.fallbackNotice(from, to, reason);
          case HeraclesBudgetWarning(:final used, :final limit):
            tr.budgetWarning(used, limit);
          case HeraclesPlanUpdated(:final steps):
            tr.planUpdated(steps);
            // ★ 计划落盘（M2，2026-10-24）：每次变化追加一行 plan ——
            //   回填取最后一行恢复（模型侧），UI 重载也读它（清单恢复）。
            //   append-only：旧计划行保留（历史里能看到计划怎么演化的）。
            //
            // ★ B8 P0（2026-10-30）：缓存最新 steps；若终态已经先到（正常不会，
            //   防御性处理）就把终态字段一起带上。
            final stepJson = [
              for (final s in steps)
                {'text': s.text, 'status': s.status.name},
            ];
            lastPlanSteps = stepJson;
            await sessionStore.appendMessage(
              sid,
              planRow(
                steps: stepJson,
                reachedGoal: planClosedReachedGoal,
                closedReason: planClosedReason,
              ),
            );
          case HeraclesPlanClosed(:final reachedGoal, :final reason):
            // ★ B8 P0：计划终态（只在有计划时收到；先于 finished/failed）。
            //   ① 给 UI 发 kPlanClosed；② 存下来，收尾时写最终 plan 行。
            planClosedReachedGoal = reachedGoal;
            planClosedReason = reason;
            tr.planClosed(reachedGoal: reachedGoal, reason: reason);
          case HeraclesContextCompressed(
              :final beforeMessages,
              :final afterMessages,
              :final beforeTokens,
              :final afterTokens,
            ):
            // ★ 上下文自动压缩（2026-10-23）——
            //   可能出现在 run **中间**（框架每轮循环开头检查），
            //   所以按到达顺序插进对话流，不是等结束再报。
            tr.contextCompressed(
              beforeMessages: beforeMessages,
              afterMessages: afterMessages,
              beforeTokens: beforeTokens,
              afterTokens: afterTokens,
            );
          case HeraclesFinished(finalText: final ft, turns: final turnCount):
            finalText = ft;
            finishedTurns = turnCount;
            tr.endStep(status: ft.trim().isEmpty ? 'empty' : 'ok');
            tr.settleTurn(); // 最终回答轮（无工具）也要记账
            tr.finished(ft, turnCount, sw.elapsedMilliseconds);
          case HeraclesFailed(:final reason):
            failed = true;
            tr.endStep(status: 'error');
            tr.settleTurn();
            tr.failed(reason);
        }

        // ★ 步骤落盘（2026-10-22）：`endStep` 会把这一轮的步骤暂存起来，
        // 这里按**事件发生的顺序**取走并追加到 `.jsonl`。
        //
        // 为什么放在 switch 之后而不是 endStep 里直接写：
        // 翻译器不做 IO；而且这样能保证**同一顺序**（步骤 → 之后的工具行），
        // 重开会话时回放顺序与实时一致。
        final stepRec = tr.takeStepRecord();
        if (stepRec != null) {
          await sessionStore.appendMessage(sid, stepRec);
        }
      }
    } catch (e) {
      failed = true;
      tr.endStep(status: 'error');
      tr.failed(_humanize(e));
      final stepRec = tr.takeStepRecord();
      if (stepRec != null) {
        await sessionStore.appendMessage(sid, stepRec);
      }
      // finally 兜底之前先记一次：异常路径也可能有排队未写的决策
      await _drainDecisionJournal(askGate, sid);
    } finally {
      sw.stop();
      // ★ 2026-10-29（JSONL 记账）：**finally 兜底 drain** ——
      //   正常路径每个事件前已经写过；这里保证"最后一条决策"不会因为
      //   run 提前结束（异常/取消/最后一个事件就是决策）而丢。
      try {
        await _drainDecisionJournal(askGate, sid);
      } catch (_) {
        // 收尾记账失败不该把一次已经成功的 run 变成失败。
      }
      // ★ P0 插队发送（2026-10-30）：**run 收尾清队列，但未消费项不静默丢**。
      //
      // 取舍（二选一，选了"② 失败提示"）：executor 是**每 run 一个实例**，
      // "留到同一会话下一次 run 继续注入"需要把队列提升到桥接层并跨 run
      // 存活（还要处理删会话/切工作区的清理）——本轮不做。改为：收尾前把
      // 剩余插话**汇总成一条 `interrupted` 提示**（文案带"未送达/请重新发送"
      // 前缀，与用户原话不同 ⇒ 不会被误认成"已送达那条"而重复渲染）。
      try {
        final leftovers = takeAllSteer();
        if (leftovers.isNotEmpty) tr.steerDropped(leftovers);
      } catch (_) {
        // 提示事件发不出去也不能让 run 失败（丢失事实已在文案层尽力）。
      }
      if (_cancelled && !failed) {
        cancelled = true;
        tr.failed('任务已取消。');
      }
      // ★ 2026-10-22 真机修复：**这里不能关流** ——
      //   变更报告（`kChanges`）要在流关闭**之前**发，
      //   否则 `controller.add` 抛 `Bad state: Cannot add new events
      //   after calling close`，整次 run 被标成"运行失败"（真机复现过）。
      //   关流挪到下面收尾动作全部做完之后。
    }

    // ---- 变更报告（2026-10-22 用户指正位置：总结**下面**、操作行**上面**）----
    //
    // 之前发独立的 `kChanges` 事件 + 独立 `role:"changes"` 行 ⇒ 卡片渲染在
    // 助手消息**上面**（事件比 run 返回的 finalText 早到）。
    // 现在**挂到助手消息上**：
    // · 实时：`AgentRunResult.changeFiles`，chat_screen 插最终回答时带上；
    // · 落盘：写进 assistant 行的 `changes` 字段（重开顺序天然正确）。
    final changeFiles = [
      for (final e in changes.entries)
        {'path': e.key, 'added': e.value.added, 'removed': e.value.removed},
    ];

    // 关流：**绝不 await**（消费端可能已走，await 会挂住）
    unawaited(controller.close());

    // ---- 计划最终行（B8 P0，2026-10-30）----
    //
    // **位置钉死**（与既有收尾顺序对齐，别挪）：在 try/finally 全部收尾之后、
    // assistant 行**之前**。历史回放顺序 = `plan 演化行 → … → 最终计划行 →
    // assistant 回答`，与旧版"plan 行都在 assistant 之前"一致；
    // 只**追加**一行，绝不重写历史文件（append-only 纪律不变）。
    //
    // 只在收到 `plan_closed`（= 本轮确实有计划）时才写 —— 无计划不产生空行。
    if (planClosedReachedGoal != null && lastPlanSteps.isNotEmpty) {
      await sessionStore.appendMessage(
        sid,
        planRow(
          steps: lastPlanSteps,
          reachedGoal: planClosedReachedGoal,
          closedReason: planClosedReason,
        ),
      );
    }

    // ---- 会话用量汇总行（T1-5，2026-10-31）----
    //
    // **只在有 turn 的 run 写**（空 run 不留空壳）；位置钉死在 assistant 行
    // **之前** —— 保持"会话文件最后一行是 assistant 回答"这个既有不变量
    // （`jsonl_accounting_test` 钉过它），汇总行放在回答前一步。
    // 口径 = **本会话累计**（读上一条汇总再累加，跨 run/重启不丢；旧文件
    // 没有该行 ⇒ 从 0 起，不假装有）。单写者：`_drive` 收尾串行调用。
    await _appendSessionUsage(
      sid: sid,
      tr: tr,
      runTurns: finishedTurns ?? tr.currentTurn,
    );

    // ---- 最终结果落盘（助手回答）----
    //
    // ★ 2026-10-22：`prompt/out/cached` 从**恒 0** 改为真实上报值
    //   （最后一轮的用量 —— 旧 Kotlin 就是这个口径）。
    if (finalText.isNotEmpty) {
      final last = tr.turnRecords.isNotEmpty ? tr.turnRecords.last : null;
      await sessionStore.appendMessage(sid, {
        'role': 'assistant',
        'text': finalText,
        'cached': last?.cachedTokens,
        'prompt': last?.promptTokens ?? 0,
        'out': last?.outputTokens ?? 0,
        'ms': sw.elapsedMilliseconds,
        if (changeFiles.isNotEmpty) 'changes': changeFiles,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    } else if (changeFiles.isNotEmpty) {
      // 没有最终回答（失败/取消）但确实动了文件 ⇒ 单独落一条，账不能丢。
      await sessionStore.appendMessage(sid, {
        'role': 'changes',
        'files': changeFiles,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    }


    // ---- 组装 AgentRunResult（UI 的权威结果）----
    //
    // 2026-10-22：`turns` 与三个 token 总数、稳态命中率**全部换成真实记账**
    // （此前 turns 恒空、token 恒 0 —— 顶栏与侧栏"不可用"的根因）。
    lastFrozenTokens = tr.firstTurnPrompt;
    // ★ C5（2026-10-24）：上下文构成 —— 侧栏"构成"三行的数据源（估算）。
    try {
      lastBreakdown = agent.contextBreakdown();
    } catch (_) {
      lastBreakdown = const <String, int>{};
    }
    return AgentRunResult(
      stopReason: cancelled
          ? '已取消'
          : failed
              ? '运行失败'
              : '已给出最终回答',
      finalText: finalText,
      turns: tr.turnRecords,
      totalCachedTokens: tr.totalCached,
      totalPromptTokens: tr.totalPrompt,
      totalOutputTokens: tr.totalOutput,
      steadyHitRate: tr.steadyHitRate,
      changeFiles: changeFiles.isNotEmpty ? changeFiles : null,
      taskWallMs: sw.elapsedMilliseconds,
      sessionId: sid,
      cancelled: cancelled,
    );
  }

  /// 上一次 run 的**冻结区** token（= 首轮 promptTokens，provider 真实上报）。
  /// `-1` = 还没跑过 / 没有用量。`AgentBridge` 在 run 结束后读走它，
  /// 供顶栏"上下文占用"与侧栏"系统提示与工具定义"使用。
  int lastFrozenTokens = -1;

  /// 上一次 run 的**上下文构成**（C5，2026-10-24）：system / tools / history
  /// 三块的估算 token。空 map = 还没跑过或拿不到 —— UI 显示两行旧图例。
  Map<String, int> lastBreakdown = const <String, int>{};

  /// N2：窗口上限与来源（context_updated 帧载荷；run 开始时由 run() 填）。
  int effectiveWindow = 0;
  String effectiveWindowSource = '';

  /// 从用户请求里取一个会话标题（取首行、截断）。
  String _titleOf(String request) {
    final firstLine = request.split('\n').first.trim();
    if (firstLine.isEmpty) return '新会话';
    return firstLine.length <= 24 ? firstLine : '${firstLine.substring(0, 24)}…';
  }

  String _humanize(Object e) {
    final s = e.toString();
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  /// **追加会话用量汇总行**（T1-5，2026-10-31；只增行类型）。
  ///
  /// ## 口径：**本会话累计**
  ///
  /// 每次 run 收尾读会话文件里**最后一条** `role:"session_usage"` 行（上一次
  /// 累计），把本场 run 的数加上去再写一行 —— 跨 run、跨重启都不丢；
  /// 旧文件没有该行 ⇒ 从 0 起（不假装有历史、也不重写旧行）。
  ///
  /// ## 字段语义
  ///
  /// · `runs`：累计 run 场数（含失败的——失败 run 也消耗了模型调用）；
  /// · `turns`：累计**总轮数**（`HeraclesFinished.turns`；取消/异常退化为
  ///   本轮实际开始的轮数）；
  /// · `reportedTurns`：累计**拿到 usage 的轮数**（与 assistant 行同源）；
  /// · `unreportedTurns`：累计"有轮次但 provider 没上报 usage"的轮数
  ///   （= turns - reportedTurns，用来解释"顶栏用量为什么偏小"）；
  /// · `prompt` / `out` / `cached`：累计 token。`cached` 只在**至少上报过
  ///   一次**缓存字段时才写 —— 从没上报过就**不写键**（不写假 0，
  ///   前端显示"不可用"）。
  /// · `steadyHitRate`：**最近一场能算出的**稳态命中率（跨 run 不重算 token
  ///   加权——那会变成另一个口径）；没有 ⇒ 不写键（null）。
  /// · `ts`：写入时间。
  ///
  /// ## 为什么只在 `runTurns > 0` 时写
  ///
  /// 空 run（还没开始就失败/被取消）没有用量可记 —— 写一行全 0 的汇总会
  /// 让"会话用量"看起来比实际更差，且让 runs 虚高。
  Future<void> _appendSessionUsage({
    required String sid,
    required _Translator tr,
    required int runTurns,
  }) async {
    if (runTurns <= 0) return;

    // 读上一次累计（读不到 ⇒ 从 0 起，不阻断收尾）。
    var prev = _UsageAccum.zero;
    try {
      final rows = await sessionStore.loadMessages(sid, limit: 0);
      for (var i = rows.length - 1; i >= 0; i--) {
        if (rows[i]['role'] == 'session_usage') {
          prev = _UsageAccum.fromRow(rows[i]);
          break;
        }
      }
    } catch (_) {
      // 读失败（通道异常/超大文件）⇒ 按首次累计；宁可少累计也不阻断 run。
    }

    final reported = tr.turnRecords.length;
    final unreported = runTurns > reported ? runTurns - reported : 0;
    final cachedReported = prev.cachedReported || tr.anyCachedReported;
    final rate = tr.steadyHitRate ?? prev.steadyHitRate;

    await sessionStore.appendMessage(sid, <String, dynamic>{
      'role': 'session_usage',
      'runs': prev.runs + 1,
      'turns': prev.turns + runTurns,
      'reportedTurns': prev.reportedTurns + reported,
      'unreportedTurns': prev.unreportedTurns + unreported,
      'prompt': prev.prompt + tr.totalPrompt,
      'out': prev.out + tr.totalOutput,
      // 只增字段：从没上报过缓存 ⇒ 不写键（不写假 0）。
      if (cachedReported) 'cached': prev.cached + tr.totalCached,
      // null 不写键（前端显示"不可用"，不是 0%）
      'steadyHitRate': ?rate,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }
}

/// **会话用量累计**（读 `role:"session_usage"` 行用）—— 纯数据。
///
/// 只包含汇总行里的已知键；缺键/坏值一律按 0（旧文件/手工改过的行不该让
/// 收尾崩掉）。`cachedReported` 记"这一行有没有 cached 键"。
class _UsageAccum {
  const _UsageAccum({
    required this.runs,
    required this.turns,
    required this.reportedTurns,
    required this.unreportedTurns,
    required this.prompt,
    required this.out,
    required this.cached,
    required this.cachedReported,
    required this.steadyHitRate,
  });

  static const zero = _UsageAccum(
    runs: 0,
    turns: 0,
    reportedTurns: 0,
    unreportedTurns: 0,
    prompt: 0,
    out: 0,
    cached: 0,
    cachedReported: false,
    steadyHitRate: null,
  );

  final int runs;
  final int turns;
  final int reportedTurns;
  final int unreportedTurns;
  final int prompt;
  final int out;
  final int cached;
  final bool cachedReported;
  final double? steadyHitRate;

  static int _intOf(Object? v) => v is num ? v.toInt() : 0;

  factory _UsageAccum.fromRow(Map<String, dynamic> row) => _UsageAccum(
        runs: _intOf(row['runs']),
        turns: _intOf(row['turns']),
        reportedTurns: _intOf(row['reportedTurns']),
        unreportedTurns: _intOf(row['unreportedTurns']),
        prompt: _intOf(row['prompt']),
        out: _intOf(row['out']),
        cached: _intOf(row['cached']),
        cachedReported: row.containsKey('cached'),
        steadyHitRate:
            row['steadyHitRate'] is num ? (row['steadyHitRate'] as num).toDouble() : null,
      );
}

/// `HeraclesEvent` → UI `AgentEvent` 的翻译器（带轮次/步骤状态）。
class _Translator {
  _Translator(this._sink);

  final void Function(AgentEvent) _sink;

  String? sessionId;

  int _turn = 0;
  final StringBuffer _text = StringBuffer();

  /// 本轮**思考**累积（与 [_text] 严格分离）。
  ///
  /// 分开存的两条理由：
  /// 1. 最终回答只认正文 —— 思考混进去就是"把推理当答案"的历史事故；
  /// 2. `step_ended` 的摘要要在"只有思考、没有正文"时退到思考，
  ///    否则「思考」行展开是空的。
  final StringBuffer _reasoning = StringBuffer();
  final Stopwatch _clock = Stopwatch();
  final List<_ToolRecord> _toolLog = [];

  // ==========================================================================
  // 逐轮用量记账（2026-10-22 补 —— 迁移时旧 Kotlin `TurnRecord` 的账没搬过来，
  // 导致顶栏命中率 `— 0%`、右侧边栏"不可用"、本次用量全 0）
  // ==========================================================================

  /// 本轮 provider 上报的用量（`HeraclesTurnUsage` 到达时填，`endStep`/工具结束时结清）。
  int _curPrompt = 0;
  int _curOutput = 0;
  int? _curCached; // null = 未上报（不得当 0，契约 §3.4）
  bool _curUsageSeen = false;

  /// 本轮的工具（旧 `TurnRecord` 一轮记一个工具；并行批次里记第一个完成的）。
  String? _curTool;
  Map<String, String>? _curToolArgs;
  String? _curToolResult;
  bool? _curToolOk;

  /// 逐轮记录 —— `AgentRunResult.turns` 的数据源（用量面板/步骤回放都读它）。
  final List<AgentTurn> turnRecords = [];

  /// **正文平滑器** —— 把大块 delta 切成 ≤4 字小片、按固定节拍发出。
  ///
  /// 与 [_sink] 绑在一起构造（见构造函数）：它是这条链路上唯一的出口，
  /// 平滑器只是"改变节奏"，不改变内容。
  late final _TextSmoother _smoother =
      _TextSmoother(_emitTextDelta);

  int totalPrompt = 0;
  int totalOutput = 0;
  int totalCached = 0;

  /// provider 是否**至少上报过一次**缓存字段 —— 一次都没有 ⇒ 命中率显示"不可用"。
  bool anyCachedReported = false;

  /// 每轮命中率（只收上报了缓存的轮）。
  final List<double> _hitRates = [];

  /// 冻结区估算 = **首轮** promptTokens（provider 真实上报，非估算器）。
  int firstTurnPrompt = -1;

  /// 收一帧逐轮用量。
  void usage({required int prompt, required int output, int? cached}) {
    _curPrompt = prompt;
    _curOutput = output;
    _curCached = cached;
    _curUsageSeen = true;
    totalPrompt += prompt;
    totalOutput += output;
    if (_hitRates.isEmpty && firstTurnPrompt < 0) firstTurnPrompt = prompt;
    if (cached != null) {
      anyCachedReported = true;
      totalCached += cached;
      if (prompt > 0) _hitRates.add(cached / prompt);
    }
  }

  /// 结清本轮，产出一条 `AgentTurn`。
  ///
  /// 时机有两处：**工具结束时**（本轮带工具）与 **run 收尾时**（最终回答轮）。
  /// 谁先看到 `_curUsageSeen` 谁结清，结完置 false ⇒ 一轮只记一条。
  void settleTurn({int? wallMs}) {
    if (!_curUsageSeen) return;
    _curUsageSeen = false;
    turnRecords.add(AgentTurn(
      index: _turn,
      verdict: _curTool == null
          ? (_curText.isEmpty ? '本轮无输出' : '给出回答')
          : (_curToolOk == true ? '工具成功' : '工具失败'),
      tool: _curTool,
      args: _curToolArgs,
      result: _curToolResult,
      wallMs: wallMs ?? _clock.elapsedMilliseconds,
      cachedTokens: _curCached,
      promptTokens: _curPrompt,
      outputTokens: _curOutput,
      toolState: _curTool == null
          ? ToolState.none
          : (_curToolOk == true ? ToolState.succeeded : ToolState.failed),
    ));
    _curTool = null;
    _curToolArgs = null;
    _curToolResult = null;
    _curToolOk = null;
  }

  /// **稳态命中率** = 跳过首轮冷启动后、各轮命中率的**轮次平均**。
  ///
  /// ⚠️ 口径纪律（`实测-L1缓存复测` 记过）：这与"累计·token 加权"是两个数，
  /// 不能混称"命中率"。未上报缓存 ⇒ null（UI 显示"不可用"，不是 0%）。
  double? get steadyHitRate {
    if (!anyCachedReported || _hitRates.length < 2) return null;
    final steady = _hitRates.sublist(1);
    return steady.reduce((a, b) => a + b) / steady.length;
  }

  /// 本轮正文快照（settleTurn 判"本轮无输出"用）。
  String get _curText => _text.toString();


  /// 本轮步骤的标题（`分析需求` / `本轮输出`）—— 落盘时一起写上。
  String _title = '';

  /// 本轮是否已经"说过话"（有正文/思考，或已补过一句摘要）。
  ///
  /// 用来保证**一轮最多一行摘要**：框架会把并行工具调用一次性发来，
  /// 若每个都补一句，界面上一轮冒出好几行重复。
  bool _turnSealed = false;

  String get _stepId => 'turn-$_turn';

  /// 当前轮次（1 起）。给驱动器记录"工具是在哪一轮发起的"用 ——
  /// 框架发起工具后会进入下一轮，工具结果回来时轮次已经变了（见 `toolFinished`）。
  int get currentTurn => _turn;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  void _beginIfNeeded({bool reasoning = false}) {
    if (_clock.isRunning) return;
    // ★ 开新一轮之前，先把上一轮还在队列里的正文片发完。
    //
    // 下面是 `_text.clear()` —— 累积缓冲要清空。若队列里还留着上一轮的片，
    // 它们会带**新一轮的 stepId** 发出去（因为 `_emitTextDelta` 读 `_stepId`）
    // ⇒ UI 把上一轮的文字挂到新一行上，且旧行永远缺结尾。
    _flushText();
    _turn++;
    _turnSealed = false; // 新一轮：还没说过话
    _text.clear();
    _reasoning.clear();
    _clock
      ..reset()
      ..start();

    // ★ 2026-10-22 用户要求：**去掉「正在生成…（第 N 轮）」那一行**。
    //
    // 原来这里会先发 `kTurnStarted`，UI 把它画成一条「正在生成…」进度行 ——
    // 用户原话：「这个正在生成...怎么...改一下行吗？不要这个，你直接思考，
    // 跟工具调用一样」。
    //
    // 所以：
    // · **不再发 `kTurnStarted`**（那条进度行彻底消失）
    // · 只发 `kStepStarted`，标题按**先到的那条通道**定：
    //   先来思考 ⇒ 「分析需求」（用户原话：**思考也是一个工具，
    //   只不过叫"分析需求"** —— 所以它和工具行同一形状、同一层级）；
    //   直接出正文 ⇒ 「本轮输出」
    // 本轮步骤的标题（落盘用 —— UI 靠它区分「分析需求」与「本轮输出」）
    _title = reasoning ? '分析需求' : '本轮输出';
    _sink(AgentEvent(
      type: AgentEvent.kStepStarted,
      ts: _now,
      stepId: _stepId,
      title: _title,
      index: _turn,
    ));
  }

  /// 思考增量（与正文**严格分离**，见 backend `HeraclesThoughtDelta` 的 KDoc）。
  void thought(String delta) {
    if (delta.isEmpty) return;
    _beginIfNeeded(reasoning: true);
    _reasoning.write(delta);
    _sink(AgentEvent(
      type: AgentEvent.kReasoningDelta,
      ts: _now,
      stepId: _stepId,
      delta: delta,
      index: _turn,
    ));
  }

  /// 正文增量 —— **先落平滑器，再由它按小片 `_sink` 出去**。
  ///
  /// ## 为什么要平滑（2026-10-23 用户报的现象）
  ///
  /// 用户原话：「流式输出不丝滑，总是一段一段出来」「吓死个人」。
  ///
  /// 根因不在 UI，也不在我们这条链路：`dart_agent_core` 的
  /// `OpenAIResponseTransformer` 每收到一个 SSE `delta.content` 就 yield 一条
  /// `ModelMessage`，而**上游 provider 本身会攒包**（中转站尤其明显）——
  /// 实测一次能给到几十上百个字符。我们只是原样转发 ⇒ UI 一次 append 一大块，
  /// 看起来就是"啪一下冒出一整段"。
  ///
  /// 下游再想让它"丝滑"只有一条路：**在这里把大块切成小片、按固定节拍发**。
  ///
  /// ## 落在翻译器层而不是 UI 层
  ///
  /// UI 是已验证资产（19 个 widget 测试），且它只认 `delta` 这个字段 ——
  /// 切成几片对它是透明的。放在翻译器还能保证**同一套节拍**对所有消费方一致
  /// （实时流、调试面板）。
  ///
  /// ## 为什么 [_text]（累积缓冲）仍然**同步**写
  ///
  /// 它喂的是 `step_ended.summary` 与 `settleTurn` 的"本轮无输出"判定。
  /// 若也异步化，收尾时可能读到半句 —— 摘要就会缺尾。
  /// ⇒ 累积同步、只把"播出去"这一步切片。
  void text(String delta) {
    if (delta.isEmpty) return;
    _beginIfNeeded();
    _text.write(delta);
    _smoother.add(delta);
  }

  /// 把待发的正文片立刻全部发出（收尾/换轮/切通道前必调）。
  void _flushText() => _smoother.flush();

  void _emitTextDelta(String piece) {
    _sink(AgentEvent(
      type: AgentEvent.kStepDelta,
      ts: _now,
      stepId: _stepId,
      delta: piece,
      index: _turn,
    ));
  }

  void toolRequested(
    String toolName,
    Map<String, dynamic> args, {
    String? surface,
    String? command,
  }) {
    // ★ 2026-10-22 用户要求：**模型一句话不说的纯工具轮次也要有一行摘要**
    //
    // 用户原话：「肯定要啊，可以多说两句，但不要太多，**以第一人称说**，
    // 显得自己在思考」。
    //
    // 提示词已经要求"动手前先说一句"，但模型（尤其快模型）经常直接调工具。
    // ⇒ 这里做**本地兜底**：这一轮没有任何正文/思考时，用第一人称补一句短的，
    //   让界面永远不会出现"闷头连续调工具、一句话没有"的观感。
    //
    // ## 一轮只补一次
    //
    // 框架会把并行的多个工具调用**一次性**发过来。若每个都补一句，
    // 一轮里会冒出好几行重复摘要 ⇒ 用 `_turnSealed` 保证"一轮最多一行"。
    if (_clock.isRunning) {
      endStep(status: 'ok');
    } else if (!_turnSealed) {
      _beginIfNeeded();
      text(_narrateFor(toolName, args));
      endStep(status: 'ok');
    }

    _sink(AgentEvent(
      type: AgentEvent.kToolStarted,
      ts: _now,
      index: _turn,
      tool: toolName,
      args: args.map((k, v) => MapEntry(k.toString(), v.toString())),
      // ★ 2026-10-29：执行面 + 命令全文（不截断）。
      //   前端据此把卡片标题写成「在沙箱 / 在手机执行了命令」，
      //   并在命令层完整显示命令（长行横向滑，不换行）。
      surface: surface,
      command: command,
    ));
  }

  /// 为"一句话没说的工具轮次"生成一句**第一人称**短摘要。
  ///
  /// 原则：
  /// · **第一人称**（"我先看看…"）—— 让用户感觉是模型在思考，而不是系统日志
  /// · **短**（一句，最多带一个短路径）—— 用户明确说"不要太多"
  /// · **不编造**：只根据工具名与参数说话，不猜它为什么这么做
  /// · 参数里的路径只保留**末尾一段**，避免长路径把一行撑爆
  String _narrateFor(String toolName, Map<String, dynamic> args) {
    final rawPath = (args['path'] ?? args['file'] ?? args['projectDir'] ?? '')
        .toString()
        .trim();
    final name = rawPath.isEmpty
        ? ''
        : ' `${rawPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? rawPath}`';
    return switch (toolName) {
      'list_files' => '我先看看工作区里有什么$name。',
      'find_files' => '我先找一下符合条件的文件$name。',
      'grep_files' => '我先搜一下关键词，定位到具体位置。',
      'read_file' => '我读一下$name 的内容，确认清楚再动手。',
      'write_file' => '我把内容写进$name。',
      'edit' => '我把$name 里对应的那几行改掉。',
      'apply_patch' => '我按补丁把$name 改好。',
      'mkdir' => '我先把目录建出来$name。',
      'delete_path' => '我把$name 删掉。',
      'move_path' => '我把$name 挪到新位置。',
      'copy_path' => '我把$name 复制一份。',
      'run_shell_command' => '我跑一条命令确认一下。',
      'web_fetch' => '我抓一下这个网页看内容。',
      'check_device_state' => '我先看下设备电量与温度。',
      'write_todos' => '我先把待办列出来，理一下步骤。',
      'ask_user' => '我需要先跟你确认一件事。',
      'save_memory' => '我把这条记到长期记忆里。',
      'build_apk' => '我试着把 APK 构建出来。',
      'apk_decompile' => '我先把 APK 解开来看看。',
      _ => '我调用 `$toolName` 处理这一步。',
    };
  }

  void toolFinished(
    String toolName,
    Map<String, dynamic> args,
    bool isError,
    String output,
    int durationMs, {
    int? turn,
    Map<String, dynamic>? metadata,
  }) {
    _toolLog.add(_ToolRecord(toolName, output, isError, durationMs));
    // 本轮的工具信息（settleTurn 写进 AgentTurn —— 用量面板的步骤回放读它）
    _curTool = toolName;
    _curToolArgs = args.map((k, v) => MapEntry(k.toString(), v.toString()));
    _curToolResult = output;
    _curToolOk = !isError;

    // ★ 2026-10-29：工具说"需要先激活能力"（T2 编译环境）⇒ 额外发一帧
    //   `activation_required`，让界面能弹一张引导卡。
    //
    //   为什么单独发一帧、而不是让 UI 从结果文本里猜：
    //   ① 文本是给模型看的（可能被压缩/改写）；事件才是给 UI 的稳定契约；
    //   ② UI 要结构化字段（体积、能力 id）才能画「约 415 MB」和按钮。
    if (metadata?['needsActivation'] == true) {
      _sink(AgentEvent(
        type: AgentEvent.kActivationRequired,
        ts: _now,
        index: turn ?? _turn,
        tool: toolName,
        activationCapability: metadata!['capability'] as String?,
        activationBytes: (metadata['downloadBytes'] as num?)?.toInt() ?? 0,
        activationSummary: metadata['summary'] as String?,
        activationBenefit: metadata['benefit'] as String?,
      ));
    }

    _sink(AgentEvent(
      type: AgentEvent.kToolFinished,
      ts: _now,
      // ★ 用**工具发起时那一轮**的序号，不是"现在"那一轮。
      //
      // ## 踩到的 bug（真机：工具行永远「执行中」）
      //
      // UI 用 `_toolKey(index, tool, args)` 把 `tool_started` 与
      // `tool_finished` 配对。而框架是**先发起工具、再进入下一轮**，
      // 等 `tool_finished` 回来时翻译器的 `_turn` 可能已经 +1 ⇒
      // 两次的 index 不同 ⇒ key 对不上 ⇒ 卡片永远停在"执行中"
      // （真机截图：`正在查看目录文件 执行中`，而后端 `.jsonl` 里
      //   那条工具明明是 `state=succeeded`）。
      //
      // ⇒ 由调用方（`_drive`）把发起时的轮次带回来。
      index: turn ?? _turn,
      tool: toolName,
      // `args` 必须带上：UI 的 key **包含参数**（细节见下面 KDoc）
      args: args.map((k, v) => MapEntry(k.toString(), v.toString())),
      result: output,
      ok: !isError,
      wallMs: durationMs,
      // ★ 2026-10-29：结构化结果字段（前端命令卡右上角要显示退出码，
      //   截断时必须如实标注）。手机 shell 与沙箱走**同一套字段**。
      surface: metadata?['surface'] as String?,
      exitCode: (metadata?['exitCode'] as num?)?.toInt(),
      truncated: (metadata?['truncated'] as bool?) ?? false,
      command: metadata?['command'] as String?,
    ));
  }

  /// **模型降级通知**（D3，2026-10-25）—— 复用 kBlocked 卡片。
  void fallbackNotice(String from, String to, String reason) {
    _sink(AgentEvent(
      type: AgentEvent.kBlocked,
      ts: _now,
      tool: 'model_fallback',
      reason: '模型 $from 失败，已自动切换到 $to 继续任务。'
          '（原因：$reason）',
    ));
  }

  /// **预算预警**（E5，2026-10-24）—— 复用 `kBlocked` 卡片形状。
  ///
  /// 为什么复用它：这是"系统级提示"的既有展示位（带 reason 的醒目卡片），
  /// 预算预警在语义上就是"系统要拦在你前面说话"。每档只播一次
  /// （75% / 90%），`_drawnBlockedKeys` 的 per-run 去重天然兜底。
  void budgetWarning(int used, int limit) {
    _sink(AgentEvent(
      type: AgentEvent.kBlocked,
      ts: _now,
      tool: 'budget_warning',
      reason: '⚠️ 工具调用预算已用 $used/$limit 次 —— 接近熔断线，'
          '任务可能做不完。可以点停止把需求拆小，或让它先收尾汇报。',
    ));
  }

  void planUpdated(List<HeraclesPlanStep> steps) {
    // ★ N4（2026-10-24）：改发 plan_updated **完整帧**（前端只读最后一帧，
    //   不做增量拼接）。planSteps/doneCount/activeIndex 兼容保留。
    final done = steps.where((s) => s.status == HeraclesPlanStatus.done).length;
    final active = steps.indexWhere((s) => s.status == HeraclesPlanStatus.active);
    _sink(AgentEvent(
      type: AgentEvent.kPlanUpdated,
      ts: _now,
      planSteps: steps.map((s) => s.text).toList(),
      doneCount: done,
      activeIndex: active,
      planStepsDetailed: [
        for (var i = 0; i < steps.length; i++)
          {
            'id': 's${i + 1}',
            'title': steps[i].text,
            'status': steps[i].status.name,
          },
      ],
    ));
  }

  /// **计划终态帧**（B8 P0，2026-10-30）—— 与 backend `HeraclesPlanClosed` 一一对应。
  ///
  /// `AgentEvent.fromMap` 读的是 map 键 `reachedGoal` / `reason`；本类字段是
  /// `reachedGoal` / `planClosedReason`（字段名与 fromMap 对齐，见 agent_bridge）。
  void planClosed({required bool reachedGoal, String? reason}) {
    _sink(AgentEvent(
      type: AgentEvent.kPlanClosed,
      ts: _now,
      reachedGoal: reachedGoal,
      planClosedReason: reason,
    ));
  }

  /// **插话未送达的失败提示**（P0，2026-10-30）—— 未消费项**不得静默丢**。
  ///
  /// ## 为什么用 `kInterrupted` + 前缀文案
  ///
  /// UI 对 `kInterrupted` 的既有渲染是"用户在跑动中补的一条消息"（`e.message`
  /// 进用户气泡）。run 已经收尾时队列里还剩的插话，不能悄悄清掉 —— 用同一
  /// 事件类型发一条**带前缀的系统提示**，用户看得见"哪句没送到"，且文本与
  /// 他原话**不同**（前缀 + "请重新发送"），不会被误认为已送达的那条
  /// （避免重复渲染同一句话）。
  void steerDropped(List<String> texts) {
    if (texts.isEmpty) return;
    _sink(AgentEvent(
      type: AgentEvent.kInterrupted,
      ts: _now,
      message: '（插话未送达：本轮已结束，未发送 —— 请重新发送：'
          '${texts.join("；")}）',
    ));
  }

  /// **context_updated 帧**（N2）—— 分项统计 + 上限（环图数据源）。
  void contextUpdated(
    Map<String, int> breakdown, {
    required int limit,
    required String limitSource,
  }) {
    _sink(AgentEvent(
      type: AgentEvent.kContextUpdated,
      ts: _now,
      breakdown: breakdown,
      limit: limit,
      limitSource: limitSource,
    ));
  }

  /// **上下文已自动压缩** —— 翻成 UI 的 `context_compressed` 事件。
  ///
  /// ## 为什么要播（而不是只记日志）
  ///
  /// 压缩是**有损**的：老消息被摘要成一段 XML，细节丢了。用户看不到它发生过，
  /// 就只会觉得"模型突然忘了前面说的事"。播出来他才知道是压缩导致的，
  /// 而不是模型变笨了。
  ///
  /// ## 为什么**不**跟步骤/轮次绑定
  ///
  /// 它不是一个"轮"，而是发生在两轮**之间**的一次维护动作（框架在每轮循环
  /// 开头检查）。所以：
  /// · 不调 `_beginIfNeeded`（那会凭空开一轮、还会把 `_text` 清掉）
  /// · 不带 `stepId` / `index`（不属于任何一轮，带了反而误导）
  /// · 直接 `_sink`，按到达顺序插进事件流
  ///
  /// ⚠️ **不要在这里 `endStep`**：压缩发生在模型调用**之前**，
  /// 此刻本轮还没有任何正文，强制收尾会把"本轮输出"封成一个空步骤。
  void contextCompressed({
    required int beforeMessages,
    required int afterMessages,
    required int beforeTokens,
    required int afterTokens,
  }) {
    _sink(AgentEvent(
      type: AgentEvent.kContextCompressed,
      ts: _now,
      beforeMessages: beforeMessages,
      afterMessages: afterMessages,
      beforeTokens: beforeTokens,
      afterTokens: afterTokens,
    ));
  }

  void retrying(String reason) {
    // UI 没有"重试"事件种类。不发 —— 重试是瞬态，成功则无需告知，
    // 失败会由 `failed` 兜底。留个探针供排障（不播到 UI）。
    lastRetryReason = reason;
  }

  String? lastRetryReason;

  void endStep({required String status}) {
    // ★ 先把还在队列里的正文片**立刻发完**，再发「本轮结束」。
    //
    // 顺序反了会怎样：UI 先收到 `step_ended`（把这一行封口），再收到
    // 最后几个 `step_delta` —— 那几片要么被挂到下一轮、要么直接丢掉。
    // 也就是说**末尾几个字会消失**，这是用户报告"回答少了结尾"那类现象之一。
    _flushText();
    if (!_clock.isRunning) return;
    _clock.stop();
    // 本轮"说过话了" ⇒ 后续同一批的并行工具调用不再补摘要
    _turnSealed = true;
    // 摘要优先用正文；只有思考没有正文时退到思考 ——
    // 否则「思考」行展开后是空的，用户以为没内容。
    final summary = _text.isNotEmpty
        ? _text.toString()
        : (_reasoning.isEmpty ? null : _reasoning.toString());
    _sink(AgentEvent(
      type: AgentEvent.kStepEnded,
      ts: _now,
      stepId: _stepId,
      status: status,
      durationMs: _clock.elapsedMilliseconds,
      summary: summary,
      index: _turn,
    ));

    // ★ 2026-10-22：**步骤必须落盘**，否则"正文汇报"只在实时流里活着。
    //
    // ## 用户报的现象
    //
    // > 「我现在看你测试的那个会话，还是没有正文汇报」
    //
    // 他看的是**从磁盘重开的会话**。而我一直没写 `role:"step"` 行 ⇒
    // 重开后只剩用户消息 + 工具行 + 最终回答，中间那些
    // 「我先看看工作区…」「我看到根目录是空的…」全没了。
    //
    // UI 侧 `chat_screen._toMessages` **早就支持**这种行
    // （字段：`stepId/title/i/think/text/stage/ms/truncated`），
    // 缺的只是生产端把它们写出来。
    //
    // 交给驱动器 `takeStepRecord()` 取走并按顺序 append
    // —— 不在这里直接写，是因为翻译器不做 IO。
    //
    // ★ 2026-10-29（JSONL 记账）：补本轮 usage（`prompt/cached/out`）。
    //   规则见 [buildStepRow]：仅本轮真的见到 usage 才写；`cached` 为 null
    //   **不写键**（不写假 0 —— "没上报"与"命中 0"是两件事）。
    _stepRecord = buildStepRow(
      stepId: _stepId,
      title: _title,
      turn: _turn,
      think: _reasoning.toString(),
      text: _text.toString(),
      stage: status,
      ms: _clock.elapsedMilliseconds,
      ts: _now,
      usageSeen: _curUsageSeen,
      prompt: _curPrompt,
      cached: _curCached,
      output: _curOutput,
    );
  }

  /// 待落盘的步骤记录（由驱动器取走后 append）。取走即清空。
  Map<String, dynamic>? _stepRecord;

  Map<String, dynamic>? takeStepRecord() {
    final r = _stepRecord;
    _stepRecord = null;
    return r;
  }

  void finished(String finalText, int turns, int wallMs) {
    // 同上：收尾事件之前必须把正文发完，否则最后几片会跟在 `finished` 后面。
    _flushText();
    _sink(AgentEvent(
      type: AgentEvent.kFinished,
      ts: _now,
      index: _turn,
      finalText: finalText,
      turnCount: turns,
      wallMs: wallMs,
    ));
  }

  void failed(String message) {
    // 失败也要先把正文发完：`_reportRunFailure` 之后这条 run 就结束了，
    // 留在队列里的片永远没有出口（且其中可能有**已经生成好的正文**）。
    _flushText();
    _sink(AgentEvent(type: AgentEvent.kFailed, ts: _now, index: _turn, message: message));
  }
}

class _ToolRecord {
  _ToolRecord(this.tool, this.result, this.isError, this.durationMs);
  final String tool;
  final String result;
  final bool isError;
  final int durationMs;
}

/// **正文平滑器** —— 把"一大块正文"摊成"一小片一小片到"。
///
/// ## 它解决的问题
///
/// 上游 provider（尤其 OpenAI 兼容中转站）会把多个 SSE `delta.content`
/// 攒成一个包再发。框架 `OpenAIResponseTransformer` 原样 yield ⇒ 我们
/// 一把 `_sink` 出去几十上百字 ⇒ UI 看起来"啪一下冒出一整段"。
///
/// 这里做的是**只改节奏、不改内容**：切成 ≤ [_chunkSize] 字的小片，
/// 片间 [_intervalMs] 毫秒。
///
/// ## 三条硬保证（都有对应测试）
///
/// 1. **逐字节一致**：所有片按序拼起来必须与原 delta 完全相同。
///    切分按 **rune**（不是 code unit）—— 否则中文/emoji 会被从代理对
///    中间切开，拼回来是乱码。这是本类最容易写错的一处。
/// 2. **单泵顺序**：只有一个异步泵在跑，队列 FIFO。
///    ❌ 绝不为每片起一个 `Future.delayed` —— 它们会并发、乱序、还会让
///    "_text 累积" 与实际显示顺序不一致。
/// 3. **收尾不卡**：[flush] 立刻把剩余片同步发完并停泵。
///    run 结束时**不许**还有 pending 的定时器拖着收尾（用户会看到
///    "任务已完成，但字还在往外蹦"）。
///
/// ## 为什么最后一帧就 flush 而不是等节拍
///
/// 稳态下让节拍器跑是对的（看起来丝滑）；但**一旦没有新数据要来了**，
/// 再按 15ms 一片地磨，就是把"已完成的回答"人为拖慢。所以：
/// 队列只剩最后一片时立即发；显式 [flush] 时全发。
class _TextSmoother {
  _TextSmoother(this._emit);

  /// 真正往 `_sink` 写事件的回调。
  final void Function(String piece) _emit;

  /// 每片最多几个 **rune**（不是 code unit）。
  ///
  /// 4 的取舍：中文一秒 60 帧、15ms 一拍 ⇒ 约每秒 66 片 × 4 字 ≈ 265 字/秒，
  /// 比模型出字快，肉眼是"连续出字"而不是"跳段"。再大就又能看出块感。
  static const int _chunkSize = 4;

  /// 片间隔（毫秒）。15ms ≈ 每秒 66 片，接近 60fps 的观感。
  static const int _intervalMs = 15;

  /// 待发小片（FIFO）。
  final List<String> _queue = [];
  bool _pumping = false;
  bool _disposed = false;

  /// 收一段正文。空串忽略；短于一片的直接进队（不做无意义切分）。
  void add(String delta) {
    if (delta.isEmpty || _disposed) return;
    _enqueueRunes(delta);
    if (!_pumping) {
      _pumping = true;
      // 不 await：调用方（框架的事件回调）是同步上下文，
      // 我们只负责把"泵"踢起来，节奏由它自己走。
      unawaited(_pump());
    }
  }

  /// 按 rune 切分入队。
  ///
  /// ⚠️ **必须用 rune**：`String.substring` 按 code unit 切会把
  /// emoji（代理对）与部分生僻汉字切成两半，拼回来就是乱码 U+FFFD。
  void _enqueueRunes(String s) {
    final runes = s.runes.toList(growable: false);
    for (var i = 0; i < runes.length; i += _chunkSize) {
      final end = (i + _chunkSize < runes.length) ? i + _chunkSize : runes.length;
      _queue.add(String.fromCharCodes(runes, i, end));
    }
  }

  /// 单泵：按节拍把队列里的片一片片发出去。
  Future<void> _pump() async {
    try {
      while (_queue.isNotEmpty && !_disposed) {
        // 已经是最后一片 ⇒ 立刻发，不为它再等一个节拍
        // （否则收尾会平白多拖 15ms，且 flush 前的最后一片会"卡一下"）。
        if (_queue.length > 1) {
          await Future<void>.delayed(const Duration(milliseconds: _intervalMs));
          if (_disposed) return;
        }
        if (_queue.isEmpty) return;
        final piece = _queue.removeAt(0);
        _emitPiece(piece);
      }
    } finally {
      _pumping = false;
    }
  }

  void _emitPiece(String piece) {
    try {
      _emit(piece);
    } catch (_) {
      // 出口抛异常（如事件流已关）⇒ 丢掉这一片，**不让泵挂死**。
      // 绝不能因为一片发不出去就让后续所有片都堵在队列里。
    }
  }

  /// **立刻发完剩余片**并停泵。收尾（`endStep` / `finished` / 失败）必调。
  ///
  /// 同步发完是有意的：调用方紧接着就要发 `step_ended` / `finished`，
  /// 若这里留异步尾巴，UI 会先收到"本轮结束"再收到"最后几个字" ——
  /// 顺序颠倒，正文就丢在步骤后面了。
  void flush() {
    while (_queue.isNotEmpty) {
      _emitPiece(_queue.removeAt(0));
    }
  }

  /// 永久停用（run 结束后不再接受新内容）。
  void dispose() {
    flush();
    _disposed = true;
  }

  /// 队列里还有多少片（测试用）。
  int get pendingPieces => _queue.length;
}
