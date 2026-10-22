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

import 'package:heracles_backend/heracles_backend.dart';

import '../models/settings.dart';
import '../widgets/tool_call_card.dart'
    show diffStatOf, estimatedDiffStatOf, changedFilesOf;
import 'agent_bridge.dart'
    show AgentEvent, AgentRunResult, AgentTurn, ToolState;
import 'device_capabilities.dart';
import 'session_store.dart';

/// 一次 run 的句柄。
class LocalRunHandle {
  LocalRunHandle({
    required this.events,
    required this.result,
    required this.cancel,
  });

  final Stream<AgentEvent> events;
  final Future<AgentRunResult> result;
  final Future<bool> Function() cancel;
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
  });

  final String workspacePath;
  final AppSettings settings;
  final SessionStore sessionStore;

  /// 提问/审批门禁（UI 注入）。`null` = 当前环境不能问用户。
  final AskGate? askGate;

  /// 当前在跑的取消令牌（`null` = 没有 run 在跑）。
  ///
  /// ## 为什么取消要「令牌 + 标志」两件
  ///
  /// `CancelToken.cancel()` 只让**框架**停下来；我们的 `_drive` 还需要知道
  /// "这是用户主动取消的"（而不是框架判定循环），才能给出正确措辞
  /// （"任务已取消"而不是"检测到循环"）。
  bool _cancelled = false;
  Completer<void>? _interruptSignal;

  /// 跑一轮。
  ///
  /// 返回的 `events` 是**广播流**（UI 与调试面板可同时听）。
  Future<LocalRunHandle> run({required String request, String? sessionId}) async {
    final controller = StreamController<AgentEvent>.broadcast();

    // ---- 能力组装（设备侧）----
    final caps = buildDeviceCapabilities(workspaceRoot: workspacePath);

    // ---- 模型配置 ----
    final provider = settings.effectiveProvider!; // 调用方已校验非 null
    final config = BackendConfig(
      apiKey: provider.apiKey,
      modelName: provider.model,
      baseUrl: provider.baseUrl,
      provider: switch (provider.protocol) {
        ProviderProtocol.anthropic => BackendProvider.anthropic,
        ProviderProtocol.openaiResponses => BackendProvider.openAiResponses,
        ProviderProtocol.openaiChat => BackendProvider.openAiCompatible,
      },
      // ★ 单窗口上限取用户配置的模型上下文（`fetchModels` 从服务端读到的，
      //   不是猜的）。`0`/未知 ⇒ 用契约默认值，别拿 4K 去压缩 1M 模型。
      modelWindowTokens: provider.contextLength > 0
          ? provider.contextLength
          : ContractModel.defaultWindowTokens,
    );

    // ---- 轮次上限 ----
    // `settings.maxTurns == 0` 的语义是"按后端自动"（UI 的 `kMaxTurnsOptions`）。
    final maxTurns = settings.maxTurns > 0 ? settings.maxTurns : ContractAgent.maxTurns;

    final agent = HeraclesAgent(
      config: config,
      capabilities: caps,
      options: RunOptions(maxTurns: maxTurns, maxToolCalls: ContractAgent.maxToolCalls),
      askGate: askGate,
    );

    final tr = _Translator(controller.add);

    // ---- 真正驱动（不 await，让 events 先被订阅）----
    final done = _drive(agent, tr, request, sessionId, controller);

    return LocalRunHandle(
      events: controller.stream,
      result: done,
      cancel: () async {
        if (_cancelled) return false;
        // 标记"这是用户取消"，让收尾措辞正确
        _cancelled = true;
        _interruptSignal?.complete();
        return true;
      },
    );
  }

  /// 执行体：把 `HeraclesAgent.run()` 的事件逐条翻译并落盘。
  Future<AgentRunResult> _drive(
    HeraclesAgent agent,
    _Translator tr,
    String request,
    String? sessionId,
    StreamController<AgentEvent> controller,
  ) async {
    final sw = Stopwatch()..start();

    // ---- 会话：没有就新建（"在工作区里直接发消息"的行为）----
    var sid = sessionId;
    if (sid == null || sid.isEmpty) {
      sid = await sessionStore.createSession(_titleOf(request));
    } else {
      await sessionStore.touchSession(sid);
    }

    // 用户消息先落盘（与旧 Kotlin 的顺序一致：用户消息先于一切）
    await sessionStore.appendMessage(sid, {
      'role': 'user',
      'text': request,
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
    final pendingArgs =
        <String, List<({Map<String, dynamic> args, int turn})>>{};

    var failed = false;
    var cancelled = false;
    var finalText = '';

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
      await for (final ev in agent.run(request)) {
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
          case HeraclesToolRequested(:final toolName, :final arguments):
            tr.toolRequested(toolName, arguments);
            (pendingArgs[toolName] ??=
                    <({Map<String, dynamic> args, int turn})>[])
                .add((args: arguments, turn: tr.currentTurn));
          case HeraclesToolFinished(
              :final toolName,
              :final isError,
              :final output,
              :final durationMs,
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
            await sessionStore.appendMessage(sid, {
              'role': 'tool',
              'tool': toolName,
              'args': args,
              'result': output,
              'state': isError ? 'failed' : 'succeeded',
              'ok': !isError,
              'ts': DateTime.now().millisecondsSinceEpoch,
            });
          case HeraclesPlanUpdated(:final steps):
            tr.planUpdated(steps);
          case HeraclesFinished(finalText: final ft, turns: final turnCount):
            finalText = ft;
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
    } finally {
      sw.stop();
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

  void text(String delta) {
    if (delta.isEmpty) return;
    _beginIfNeeded();
    _text.write(delta);
    _sink(AgentEvent(
      type: AgentEvent.kStepDelta,
      ts: _now,
      stepId: _stepId,
      delta: delta,
      index: _turn,
    ));
  }

  void toolRequested(String toolName, Map<String, dynamic> args) {
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
  }) {
    _toolLog.add(_ToolRecord(toolName, output, isError, durationMs));
    // 本轮的工具信息（settleTurn 写进 AgentTurn —— 用量面板的步骤回放读它）
    _curTool = toolName;
    _curToolArgs = args.map((k, v) => MapEntry(k.toString(), v.toString()));
    _curToolResult = output;
    _curToolOk = !isError;
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
    ));
  }

  void planUpdated(List<HeraclesPlanStep> steps) {
    final done = steps.where((s) => s.status == HeraclesPlanStatus.done).length;
    final active = steps.indexWhere((s) => s.status == HeraclesPlanStatus.active);
    _sink(AgentEvent(
      type: AgentEvent.kPlanCreated,
      ts: _now,
      planSteps: steps.map((s) => s.text).toList(),
      doneCount: done,
      activeIndex: active,
    ));
  }

  void retrying(String reason) {
    // UI 没有"重试"事件种类。不发 —— 重试是瞬态，成功则无需告知，
    // 失败会由 `failed` 兜底。留个探针供排障（不播到 UI）。
    lastRetryReason = reason;
  }

  String? lastRetryReason;

  void endStep({required String status}) {
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
    _stepRecord = <String, dynamic>{
      'role': 'step',
      'stepId': _stepId,
      'title': _title,
      'i': _turn,
      'think': _reasoning.toString(),
      'text': _text.toString(),
      'stage': status,
      'ms': _clock.elapsedMilliseconds,
      'ts': _now,
    };
  }

  /// 待落盘的步骤记录（由驱动器取走后 append）。取走即清空。
  Map<String, dynamic>? _stepRecord;

  Map<String, dynamic>? takeStepRecord() {
    final r = _stepRecord;
    _stepRecord = null;
    return r;
  }

  void finished(String finalText, int turns, int wallMs) {
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
