/// **上下文压缩** —— 实现 `dart_agent_core` 的 [ContextCompressor] 接口。
///
/// ## 现在的形状（2026-11-06）：**单阈值 → 一次性流水线**
///
/// ```
/// 占用 < 85% × 窗口  ⇒ 直接返回（零副作用、零 token、零缓存损失）
/// 占用 ≥ 85% × 窗口  ⇒ A MicroCompact → B SessionMemory → C API 摘要
///                      → D 确定性强制重置 → E 90% 硬顶升级循环
/// ```
///
/// 每层之后重估占用，**达标即停**。旋钮全在 `ContractCompaction`。
///
/// ## 为什么不再是"三级阈值"（这条是真机教训，别再改回去）
///
/// 旧实现对齐 Claude Code 的三级压缩：micro 40% / auto 摘要 60% / full 80%。
/// 它在真机上有个致命副作用：
///
/// · micro 在 40% 线上**每轮**把历史中段的工具输出换成占位符 ⇒
///   该点之后的 token **前缀全部失效** ⇒ 前缀缓存命中率只有 **40%~48%**
///   （用户招牌指标要 80%+，这是他们最在意的数）；
/// · 而且上下文长期贴在 40% 线上、永远不升级，模型反复丢工具结果
///   （要么重读文件，要么凭记忆瞎改）。
///
/// 用户 2026-11-05 裁定：**只留一条 0.85 线，到线跑一次**。压完前缀重新稳定，
/// 下一次触发是"又长回来了"的真实信号，而不是"每轮都在小修小补"。
///
/// ⇒ 所以 micro 从"每轮的档位"变成**压缩事件内的第一步**（用户拍板 Q1）：
///   它依然有用（老工具输出是最大的死重），但**一生只跑一次/每事件**。
///
/// ## 与框架自带 `LLMBasedContextCompressor` 的关系
///
/// **不再使用**它（2026-11-06 删除 delegate 兜底）。理由：它有一堆静默早退
/// 分支（usages 为空 / 条数不够 / 摘要空 / XML 解析失败都 catch 掉），
/// 于是"压缩失败"和"压缩没触发"在外部看起来一模一样 —— 那是我们最不能接受的
/// 不确定性。现在摘要走我们自己的 `StructuredSummarizer`（失败必定带原因回来），
/// 兜底走确定性裁剪（不依赖任何模型）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../contract/contract.dart';
import 'compaction/compaction_config.dart';
import 'compaction/compaction_event.dart';
import 'compaction/compaction_pipeline.dart';
import 'compaction/message_scan.dart';
import 'compaction/micro_compactor.dart';
import 'compaction/reload_context.dart';
import 'compaction/send_view.dart';
import 'compaction/session_memory.dart';
import 'compaction/token_estimation.dart';

/// 按模型窗口比例触发的压缩器（**单阈值 + 一次性流水线**）。
class WindowRatioCompressor implements ContextCompressor, CompactionFallback {
  WindowRatioCompressor({
    required this.client,
    required this.modelConfig,
    required this.modelWindowTokens,
    this.compressAtRatio = ContractCompression.compressAtRatio,
    this.keepRecentTurns = ContractCompression.keepRecentTurns,
    this.onCompressed,
    this.enableMicro = true,
    this.summarizeAtRatio = ContractCompression.compressAtRatio,
    this.compactionConfig = const CompactionConfig(),
    this.readProjectFile,
    this.readRecentFile,
    this.sessionMemory,
    this.sessionMemoryProvider,
  });

  /// **唯一**的摘要/压缩触发线（比例）。
  ///
  /// 生产侧与契约都是 0.85（用户 2026-11-05 裁定：单阈值，不到线一个字节都不动）。
  /// 保留成构造参数只为单测能造"窗口极小 ⇒ 必触发"的场景。
  final double compressAtRatio;

  /// **【兼容保留】旧的双阈值参数** —— 2026-11-06 起**不再被读取**。
  ///
  /// 曾经表示"摘要单独一条线（60%）"。单阈值方案下它与 [compressAtRatio] 恒等，
  /// 留着只为不让外部调用方编译失败（App/CLI 曾显式传 0.85）。
  /// 新代码请用 [compressAtRatio] 或 `CompactionConfig.autoCompactThreshold`。
  final double summarizeAtRatio;

  /// 是否允许阶段 1（MicroCompact）在压缩事件内执行。
  ///
  /// **生产开启**（2026-11-06）：micro 现在只在压缩事件里跑一次，
  /// 不再每轮改写历史前缀 —— 当年关掉它的理由（砸缓存）已经不成立。
  /// 关掉 = 只靠 SessionMemory/API 摘要，老工具输出会跟着摘要一起被收走
  /// （信息损失更大，且摘要要读更多 token）。
  final bool enableMicro;

  /// 用来做摘要的 client。
  ///
  /// ⚠️ 建议传小模型：摘要不需要强推理，用便宜模型能省很多钱。
  final LLMClient client;

  /// 摘要用的模型配置。可以比主模型便宜。
  final ModelConfig modelConfig;

  /// 主模型的上下文窗口（token）。
  final int modelWindowTokens;

  /// 保留最近多少**轮**原文（不被压缩）。
  ///
  /// 必须是"轮"而不是"条"：一轮可能包含 1 条用户消息 + 5 条工具往返，
  /// 按条保留会留下半轮，模型看到"工具结果但没有对应的请求"。
  final int keepRecentTurns;

  /// 压缩流水线的全部旋钮（默认值来自 `ContractCompaction`）。
  final CompactionConfig compactionConfig;

  /// 项目指令读取器（宿主注入；AGENTS.md 的读取走这里）。
  final ProjectInstructionsReader? readProjectFile;

  /// 工作区文件读取器（宿主注入；用于"最近修改文件"重载）。
  final RecentFileReader? readRecentFile;

  /// 外部注入的会话记忆（上一轮/宿主持久化）。
  final SessionMemory? sessionMemory;

  /// 会话记忆的异步更新器（可选；不传就走本地规则）。
  final Future<SessionMemory> Function(SessionMemory? previous)?
      sessionMemoryProvider;

  /// **压缩真的发生之后**的回调（给 UI 播报用）。
  ///
  /// 只有**真的动了历史**才调 —— 静默早退（没到线 / 各层都没省下东西）
  /// 绝不播报：用户不该收到"压缩了 40 条 → 40 条"这种无意义事件。
  final void Function(
    int beforeMessages,
    int afterMessages,
    int beforeTokens,
    int afterTokens,
  )? onCompressed;

  /// 触发压缩的 token 阈值（= 0.85 线，保留给旧调用方与测试）。
  int get triggerThreshold => (modelWindowTokens * compressAtRatio).floor();

  /// 生效配置：把真实窗口与触发线灌进去（其余旋钮由宿主决定）。
  CompactionConfig get effectiveConfig => compactionConfig.copyWith(
        contextWindow: modelWindowTokens,
        autoCompactThreshold: compressAtRatio,
      );

  // ---------------------------------------------------------------------
  // 状态（不放 state 里：这些是"这次压缩"的记账，不是历史）
  // ---------------------------------------------------------------------

  /// **递归/并发防护**：压缩过程中再次被调用（框架重入、多轮并发）⇒ 直接返回。
  ///
  /// 为什么必须有：`compress()` 是 async 的，内部要 await 摘要调用（网络往返），
  /// 这段时间里框架理论上可能再次进入（异常路径/并发 run 复用同一实例）。
  /// 重入会同时改 `state.history.messages` ⇒ 破历史、丢消息，且缓存必然全废。
  bool _running = false;

  /// 本次压缩用的 bias（`决策占用 / 估算`）。压完真值会滞后一轮，
  /// 只能用这个系数把估算投影回真实量级（见 [projectedUsage]）。
  double _biasForRun = 1.0;

  /// 最近一次压缩事件（UI/命令层取用）。
  CompactionEvent? _lastEvent;

  /// 压缩事件留档（`metricsEnabled` 打开时才有；环形，最多
  /// `ContractCompaction.metricsMaxEvents` 条）。
  final List<CompactionEvent> _events = <CompactionEvent>[];

  /// 最近一次 micro 的清理记账（`buildSendView` 用）。
  Map<String, ClearedRef> _lastClearedRefs = const <String, ClearedRef>{};

  /// 最近一次压缩事件。
  CompactionEvent? get lastCompaction => _lastEvent;

  /// 事件留档（副本，外部改不动）。
  List<CompactionEvent> get events => List<CompactionEvent>.unmodifiable(_events);

  /// 最近一次 micro 清掉的块（可追溯原字符数）。
  Map<String, ClearedRef> get clearedRefs => _lastClearedRefs;

  /// 复用同一个 pipeline 实例会让"上一次的会话记忆"延续下来（增量语义）。
  late final CompactionPipeline _pipeline = CompactionPipeline(
    client: client,
    modelConfig: modelConfig,
    fallback: this,
    config: effectiveConfig,
    readProjectFile: readProjectFile,
    readRecentFile: readRecentFile,
    sessionMemory: sessionMemory,
    sessionMemoryProvider: sessionMemoryProvider,
  );

  /// 最近一次用来渲染视图的会话记忆（UI/命令层可见）。
  SessionMemory? get lastSessionMemory => _pipeline.lastSessionMemory;

  /// 对外暴露的估算入口 —— **只为可测**（生产里由 [compress] 自己调）。
  @override
  int estimateUsage(AgentState state) => _estimateUsage(state);

  /// **压缩入口**（框架每轮循环开头、发请求之前调用）。
  ///
  /// 两条铁律：
  /// 1. **不到 0.85 线：一个字节都不动**（零副作用 —— 缓存命中率靠这条活着）；
  /// 2. **重入直接返回**（见 [_running]）。
  @override
  Future compress(AgentState state) async {
    final window = modelWindowTokens;
    final cfg = effectiveConfig;
    final line = cfg.autoCompactLine;
    final usage = _decisionUsage(state, window: window);

    if (usage < line) {
      // ---- 未到线：默认**零副作用** ----
      //
      // `progressiveLayersEnabled` 是唯一的例外（默认关）：用户明确愿意
      // 用缓存命中率换上下文余量时，才允许低阈值下只跑 micro。
      // 真机教训写在 ContractCompaction.progressiveLayersEnabled 的 KDoc 里。
      if (cfg.progressiveLayersEnabled && enableMicro && !_running) {
        await _runProgressiveMicro(state);
      }
      return;
    }

    if (_running) return;
    _running = true;
    try {
      _prepareRun(state, window: window);
      final beforeMessages = state.history.messages.length;
      final event = await _pipeline.run(
        state,
        trigger: CompactionTrigger.threshold,
      );
      _afterRun(state, event, beforeMessages: beforeMessages, beforeTokens: usage);
    } finally {
      _running = false;
    }
  }

  /// **手动压缩**（`/compact` 命令、`compactNow({focus})`）。
  ///
  /// 与自动压缩的区别只有两点：
  /// 1. **不看阈值**（用户说了算，哪怕现在只用了 10%）；
  /// 2. [focus] 非空 ⇒ **强制走阶段 3**（"这次只保留 XX 相关"，本地规则听不懂）。
  ///
  /// 返回的事件无论是成功/失败都会带 `failureReason`，**绝不抛**：
  /// 命令层要能把它直接显示成一句人话。
  Future<CompactionEvent> compactNow(
    AgentState state, {
    String? focus,
  }) async {
    if (_running) {
      return CompactionEvent(
        trigger: CompactionTrigger.manual,
        layersRun: const <CompactionLayer>[],
        beforeTokens: _decisionUsage(state, window: modelWindowTokens),
        afterTokens: _decisionUsage(state, window: modelWindowTokens),
        elapsedMs: 0,
        usedApi: false,
        keptNotes: state.history.messages.length,
        droppedNotes: 0,
        failureReason: '上一次压缩仍在进行中，本次请求被忽略（不并发改历史）',
      );
    }
    _running = true;
    try {
      _prepareRun(state, window: modelWindowTokens);
      final beforeMessages = state.history.messages.length;
      final beforeTokens = _decisionUsage(state, window: modelWindowTokens);
      final event = await _pipeline.run(
        state,
        trigger: CompactionTrigger.manual,
        focus: focus,
      );
      _afterRun(
        state,
        event,
        beforeMessages: beforeMessages,
        beforeTokens: beforeTokens,
      );
      return event;
    } finally {
      _running = false;
    }
  }

  /// **当前发送视图**（只读投影；不改历史）。
  ///
  /// 命令层/UI 用：看"这次到底发出去什么"、清了几块、多大。
  SendView buildSendView(AgentState state) {
    final messages = List<LLMMessage>.of(state.history.messages);
    return SendView(
      messages: messages,
      clearedRefs: _lastClearedRefs,
      estTokens: estimateMessagesTokens(messages),
    );
  }

  /// **把发送视图截断到最近 [rounds] 轮**（`/rewind` 用）。
  ///
  /// ★ **原始历史一个字都不动**（用户拍板 Q5：截断只作用于发送视图，
  /// 会话 `.jsonl` 仍是一条不删的 append-only 记录）。
  /// 命令层拿到返回的 [SendView] 后，可以选择"下一次 run 用这份历史"。
  SendView sendViewTruncatedTo(AgentState state, int rounds) {
    final full = buildSendView(state);
    return truncateSendViewToRounds(
      full.messages,
      rounds,
      clearedRefs: full.clearedRefs,
      messagesPerRound: ContractCompression.messagesPerTurn,
    );
  }

  // ---------------------------------------------------------------------
  // CompactionFallback 的实现（D/E 两层用；口径与压缩决策同一套）
  // ---------------------------------------------------------------------

  @override
  int decisionUsage(AgentState state) =>
      _decisionUsage(state, window: modelWindowTokens);

  @override
  int projectedUsage(AgentState state) {
    final est = _estimateUsage(state);
    final bias = _biasForRun < 1.0 ? 1.0 : _biasForRun;
    return (est * bias).round();
  }

  @override
  int forceReset(AgentState state) => _forceReset(state);

  @override
  bool trimToFit(AgentState state, {required int targetEstimateTokens}) =>
      _trimToFit(state, targetEstimateTokens: targetEstimateTokens);

  // ---------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------

  /// 记下本次压缩的 bias 与真值封顶口径。
  void _prepareRun(AgentState state, {required int? window}) {
    final est = _estimateUsage(state);
    final decision = _decisionUsage(state, window: window);
    final bias = (decision > 0 && est > 0) ? decision / est : 1.0;
    _biasForRun = bias < 1.0 ? 1.0 : bias;
  }

  /// 压缩跑完之后的记账与播报。
  void _afterRun(
    AgentState state,
    CompactionEvent event, {
    required int beforeMessages,
    required int beforeTokens,
  }) {
    _lastEvent = event;
    _lastClearedRefs = event.clearedRefs;
    if (event.changed) {
      onCompressed?.call(
        beforeMessages,
        state.history.messages.length,
        beforeTokens,
        event.afterTokens,
      );
    }
    if (effectiveConfig.metricsEnabled) {
      _events.add(event);
      while (_events.length > ContractCompaction.metricsMaxEvents) {
        _events.removeAt(0);
      }
    }
  }

  /// **渐进模式下的 micro**（**默认关闭**的路径，见契约 KDoc 的真机教训）。
  ///
  /// 为什么保留它：某些宿主可能愿意"用缓存命中率换上下文余量"（例如
  /// 小窗口 + 超长任务）。默认关是产品决策 —— 别把它当推荐用法。
  Future<void> _runProgressiveMicro(AgentState state) async {
    final before = estimateMessagesTokens(state.history.messages);
    final micro = MicroCompactor(config: effectiveConfig)
        .compact(List<LLMMessage>.of(state.history.messages));
    if (!micro.changed) return;
    if (micro.view.estTokens >= before) return; // 没省 ⇒ 不动（不许越压越大）
    final beforeMessages = state.history.messages.length;
    state.history.messages = micro.view.messages;
    _lastClearedRefs = micro.view.clearedRefs;
    _lastEvent = CompactionEvent(
      trigger: CompactionTrigger.progressive,
      layersRun: const <CompactionLayer>[CompactionLayer.micro],
      beforeTokens: before,
      afterTokens: micro.view.estTokens,
      elapsedMs: 0,
      usedApi: false,
      keptNotes: state.history.messages.length,
      droppedNotes: 0,
      clearedRefs: micro.view.clearedRefs,
    );
    if (effectiveConfig.metricsEnabled) {
      _events.add(_lastEvent!);
      while (_events.length > ContractCompaction.metricsMaxEvents) {
        _events.removeAt(0);
      }
    }
    onCompressed?.call(
      beforeMessages,
      state.history.messages.length,
      before,
      micro.view.estTokens,
    );
  }

  /// **第三级：确定性强制重置** —— 整批丢弃老轮次，**丢到线以下为止**。
  ///
  /// ## 为什么是"整批"
  ///
  /// 一批 = 一条 user 消息及其后的全部工具往返。按批丢才能保证
  /// "调用与结果不拆散"（拆散就是 400）。
  ///
  /// ## 丢多少：不是"留 6 批"，而是"留到估算 < 强制线"
  ///
  /// 只保固定批数会出现**小碎步**：每轮丢一两条、token 几乎不降，
  /// 下一轮又触发 —— 每次都白插一条说明。正确做法是按**批次后缀估算**
  /// 找最早能满足"保留区 < 强制线"的切点，一次丢够。
  ///
  /// ## 丢弃的内容去哪了
  ///
  /// 没去哪 —— 这一级是"未及摘要的强制清场"（记忆/摘要都失败或不够才会走到这里）。
  /// 头部插一条**如实**的说明：多少条被移除、未摘要、需要就重新取证。
  /// 绝不假装"已经总结过了"。
  ///
  /// 返回丢弃的条数（0 = 没有可丢的）。
  int _forceReset(AgentState state) {
    final msgs = state.history.messages;
    final keepMessages =
        keepRecentTurns * ContractCompression.messagesPerTurn;
    if (msgs.length <= keepMessages) return 0;

    // ★ 摘要快照必须保住：它是刚刚花代价（本地规则或一次 API 调用）算出来的
    //   压缩结果。如果这里从 index 0 开始切，就会把快照本身丢掉 ——
    //   于是"压缩了两次、什么都没留下"（真机排障时抓过这种形态）。
    final head = <LLMMessage>[];
    var start = 0;
    if (msgs.isNotEmpty && _isCompactionNote(msgs[0])) {
      head.add(msgs[0]);
      start = 1;
    }

    final line = (modelWindowTokens * compressAtRatio).floor();
    final starts = <int>[
      for (var i = start; i < msgs.length; i++)
        if (msgs[i] is UserMessage) i,
    ];

    int cut;
    if (starts.length >= 2) {
      // 从"最多保 keepRecentTurns 批"的切点起，往更早找（丢更多），
      // 找第一个"保留后缀 + 说明消息 < 强制线"的切点。
      final earliest = starts.length - keepRecentTurns;
      var chosen = earliest > 0 ? earliest : 0;
      if (chosen < 0) chosen = 0;
      for (var k = chosen; k < starts.length; k++) {
        final suffix = _estimateRange(msgs, starts[k]);
        if (suffix + ContractCompaction.resetNoteAllowanceTokens < line) {
          chosen = k;
          break;
        }
        // 还压不进线 ⇒ 继续缩小保留区（k 增大 = 保留更少）
        chosen = k;
      }
      cut = starts[chosen];
    } else {
      cut = _adjustCut(msgs, msgs.length - keepMessages);
    }
    if (cut <= start) return 0;

    final note = UserMessage.text(
      '[系统维护] 更早的 ${cut - start} 条消息因上下文窗口吃紧被强制移除'
      '（摘要未成功，这些内容未保存）。'
      '如需更早的信息，请依据工作区文件重新取证，并如实告知用户上下文被清理过。',
    );
    state.history.messages = <LLMMessage>[
      ...head,
      note,
      ...msgs.sublist(cut),
    ];
    return cut - start;
  }

  /// 这条消息是不是我们自己插的**压缩快照**（阶段 2/3 的产物）。
  ///
  /// 兜底裁剪靠它识别"这段是花代价算出来的压缩结果，不许当老消息丢掉"。
  static bool _isCompactionNote(LLMMessage m) {
    if (m is! UserMessage) return false;
    for (final p in m.contents) {
      if (p is TextPart) {
        final t = p.text.trimLeft();
        if (t.startsWith('[上下文压缩快照]')) return true;
      }
    }
    return false;
  }

  /// **兜底裁剪：把占用真的降到 [targetEstimateTokens] 以下**（确定性，不依赖 LLM）。
  ///
  /// 三招按代价从低到高依次做，够用就停：
  ///
  /// 1. **老的/大的工具结果换占位符**（此时保护窗让路 —— 已经超线了，
  ///    留住"窗口被撑爆"比留住一份能重读的工具输出更糟）；
  /// 2. **按 token 丢更早的消息**（切点保证不拆"调用↔结果"配对），
  ///    且**永远保留最后一条**（模型要知道当前这轮发生了什么）；
  /// 3. 单条就超（极少见）⇒ 对**最大的一条**文本做截断，保留头部并写明已截断。
  ///
  /// 返回是否真的动过历史（动过才播 `context_compressed`）。
  bool _trimToFit(AgentState state, {required int targetEstimateTokens}) {
    // 说明消息本身要占位，先扣掉
    final target = (targetEstimateTokens -
                ContractCompaction.trimNoteAllowanceTokens) <
            1
        ? 1
        : targetEstimateTokens - ContractCompaction.trimNoteAllowanceTokens;
    var acted = false;
    final details = <String>[];

    // 摘要快照（若有）**不许被裁**：它是花钱/花规则算出来的压缩结果。
    // 与 `_forceReset` 同一条纪律（两处都要守，否则一处漏 = 快照被吃掉）。
    final start =
        (state.history.messages.isNotEmpty &&
                _isCompactionNote(state.history.messages.first))
            ? 1
            : 0;

    // ---- 第 1 招：大工具结果 → 占位符（旧→新，够用就停）----
    final msgs = state.history.messages;
    for (var i = start; i < msgs.length; i++) {
      if (_estimateUsage(state) < target) break;
      final m = msgs[i];
      if (m is! FunctionExecutionResultMessage) continue;
      final replaced = _replaceBigResults(
        m,
        minChars: ContractCompaction.microMinChars,
      );
      if (replaced == null) continue;
      msgs[i] = replaced;
      acted = true;
      details.add('清理了少量老工具输出');
    }

    // ---- 第 2 招：按 token 丢更早的消息（保留最后一条）----
    if (_estimateUsage(state) >= target && state.history.messages.length > 1) {
      final list = state.history.messages;
      var chosen = -1;
      for (var k = start + 1; k < list.length; k++) {
        if (_estimateRange(list, k) +
                ContractCompaction.trimNoteAllowanceTokens <=
            target) {
          chosen = k;
          break;
        }
      }
      // 没有任何后缀装得下 ⇒ 只保最后一条（它仍可能超，交给第 3 招）
      var cut = chosen >= 0 ? chosen : list.length - 1;
      cut = _adjustCut(list, cut);
      final lowest = start + 1;
      if (cut < lowest) cut = lowest;
      if (cut < list.length) {
        final removed = cut - start;
        state.history.messages = <LLMMessage>[
          ...list.sublist(0, start),
          ...list.sublist(cut),
        ];
        acted = true;
        details.add('移除了更早的 $removed 条消息');
      }
    }

    // ---- 第 3 招：单条仍超 ⇒ 截断最大那条的文本 ----
    if (_estimateUsage(state) >= target) {
      final truncated = _truncateLargestMessage(state, target, from: start);
      if (truncated != null) {
        acted = true;
        details.add('截断了 1 条超长内容（原 $truncated 字符，需要请重新读取）');
      }
    }

    if (!acted) return false;

    // ---- 如实说明（插在摘要快照之后，不改变"最后一条"）----
    final keep = state.history.messages;
    state.history.messages = <LLMMessage>[
      ...keep.sublist(0, start),
      UserMessage.text(
        '[系统维护] 上下文窗口吃紧，已自动腾出空间：${details.join('；')}。'
        '这些内容**没有**进摘要（摘要本轮未成功），如需依据请重新读取相应文件；'
        '继续任务时请如实告知用户上下文被清理过。',
      ),
      ...keep.sublist(start),
    ];
    return true;
  }

  /// 把一条工具结果里**较大的**输出换成占位符；没有可换的返回 null。
  FunctionExecutionResultMessage? _replaceBigResults(
    FunctionExecutionResultMessage m, {
    required int minChars,
  }) {
    var changed = false;
    final out = <FunctionExecutionResult>[];
    for (final r in m.results) {
      final text = _contentText(r.content);
      if (text.length < minChars) {
        out.add(r);
        continue;
      }
      final placeholder = '[工具结果已清理（窗口吃紧）：原 ${text.length} 字符。'
          '如仍需要该信息，请重新执行相应工具获取。]';
      out.add(FunctionExecutionResult(
        id: r.id,
        name: r.name,
        isError: r.isError,
        arguments: r.arguments,
        content: [TextPart(placeholder)],
        timestamp: r.timestamp,
      ));
      changed = true;
    }
    if (!changed) return null;
    return FunctionExecutionResultMessage(results: out);
  }

  /// 截断**最大一条**消息里的文本；返回被截掉的原字符数（null = 没做）。
  ///
  /// [from] 之前（不含）的消息**不许动** —— 那是压缩快照（`[上下文压缩快照]`），
  /// 是花代价算出来的结果，截掉它等于把压缩结果毁掉。
  ///
  /// 只截 `FunctionExecutionResultMessage` / `UserMessage` / `ModelMessage` 的文本：
  /// `SystemMessage` 不动（它是系统提示的一部分，动了等于改了人设）。
  int? _truncateLargestMessage(AgentState state, int target, {int from = 0}) {
    final msgs = state.history.messages;
    var bestIndex = -1;
    var bestTokens = 0;
    for (var i = from; i < msgs.length; i++) {
      final t = estimateMessageTokensOf(msgs[i]);
      if (t > bestTokens) {
        bestTokens = t;
        bestIndex = i;
      }
    }
    if (bestIndex < 0) return null;
    final m = msgs[bestIndex];

    if (m is FunctionExecutionResultMessage) {
      var droppedChars = 0;
      final out = <FunctionExecutionResult>[];
      for (final r in m.results) {
        final text = _contentText(r.content);
        final keep = text.length ~/ 4; // 只留头部四分之一
        final cutChars = text.length - keep;
        if (cutChars <= 0) {
          out.add(r);
          continue;
        }
        droppedChars += cutChars;
        out.add(FunctionExecutionResult(
          id: r.id,
          name: r.name,
          isError: r.isError,
          arguments: r.arguments,
          content: [
            TextPart('${text.substring(0, keep)}\n'
                '…[已截断：原 ${text.length} 字符，只保留前 $keep 字符。'
                '需要完整内容请重新执行相应工具]'),
          ],
          timestamp: r.timestamp,
        ));
      }
      if (droppedChars == 0) return null;
      msgs[bestIndex] = FunctionExecutionResultMessage(results: out);
      return droppedChars;
    }

    if (m is UserMessage) {
      final text = _contentText(m.contents);
      final keep = text.length ~/ 4;
      final cutChars = text.length - keep;
      if (cutChars <= 0) return null;
      msgs[bestIndex] = UserMessage.text(
        '${text.substring(0, keep)}\n…[已截断：原 ${text.length} 字符，只保留前 $keep 字符]',
      );
      return cutChars;
    }

    // ★ 2026-11-04：**助手正文**同样可能是最大的一条（模型在回复里贴了整段代码/HTML）。
    //   截断时**保留 functionCalls**：那是调用配对，丢了会造成"有结果没请求"。
    if (m is ModelMessage) {
      final text = m.textOutput ?? '';
      final keep = text.length ~/ 4;
      final cutChars = text.length - keep;
      if (cutChars <= 0) return null;
      msgs[bestIndex] = ModelMessage(
        model: m.model,
        textOutput: '${text.substring(0, keep)}\n'
            '…[已截断：原 ${text.length} 字符，只保留前 $keep 字符]',
        thought: m.thought,
        stopReason: m.stopReason,
        functionCalls: m.functionCalls,
        usage: m.usage,
      );
      return cutChars;
    }
    return null;
  }

  /// 估算 `msgs[from..]` 的 token（批次后缀估算，选切点用）。
  int _estimateRange(List<LLMMessage> msgs, int from) {
    var total = 0;
    for (var i = from; i < msgs.length; i++) {
      total += estimateMessageTokensOf(msgs[i]);
    }
    return total;
  }

  /// 把按条数算出的切点调整到**不拆批**的位置（唯一实现见 `message_scan.dart`）。
  int _adjustCut(List<LLMMessage> msgs, int raw) =>
      adjustCutToBatchBoundary(msgs, raw);

  /// 拼接结果内容里的纯文本（占位计算用）。
  String _contentText(List<UserContentPart> parts) => partsText(parts);

  /// **把分项估算按"真实总量"等比放大**（2026-11-04，用户要求环图别自相矛盾）。
  ///
  /// 真机截图里同一屏出现两个口径：分项合计 ~20K，总量却是 `~104.0K / 128.0K`。
  /// 这里按 `真实总量 / 估算合计` 等比放大，并**把舍入误差补到最大的一项**，
  /// 保证 `sum(结果) == 真实总量` —— 屏幕上加起来必须对得上。
  ///
  /// 入参为空/真实值不可用时**原样返回**（不猜、不缩放）。
  static Map<String, int> scaleToRealTotal(
    Map<String, int> parts,
    int realTotal,
  ) {
    if (parts.isEmpty || realTotal <= 0) return parts;
    final estTotal = parts.values.fold<int>(0, (a, b) => a + b);
    if (estTotal <= 0) return parts;
    final factor = realTotal / estTotal;
    final out = <String, int>{
      for (final e in parts.entries) e.key: (e.value * factor).round(),
    };
    // 舍入误差补到"最大的一项"，保证总和精确等于 realTotal
    final diff = realTotal - out.values.fold<int>(0, (a, b) => a + b);
    if (diff != 0) {
      final biggest = out.entries.reduce((a, b) => a.value >= b.value ? a : b);
      out[biggest.key] = (biggest.value + diff) < 0 ? 0 : biggest.value + diff;
    }
    return out;
  }

  /// **粗估**当前历史占多少 token（含 system 段与工具定义）。
  int _estimateUsage(AgentState state) =>
      estimateMessagesUsage(state) + estimateToolDefinitions(state);

  /// **决策用的占用**：取"估算"与"服务端真实上报"两者的**较大值**。
  ///
  /// 真机现场（2026-11-04 11:35）：分项合计 ~20K，但总量写着 104K/128K（81%），
  /// 那是 provider 上报的 `promptTokens`。我们的字符估算低估约 5 倍 ⇒
  /// 只看估算会"永远到不了线"。取大值 = **宁可早压**
  /// （压早了只是多跑一次流水线；压晚了直接撞窗失败）。
  int _decisionUsage(AgentState state, {int? window}) {
    final est = _estimateUsage(state);
    var real = _lastPromptTokens(state);
    // ★ 2026-11-06：新一轮开始时 `usages` 为空 ⇒ 用宿主带来的上次真值兜底。
    //   没有这一条，真机出现"上下文 122%、压缩从不触发"（真值不在 state 里）。
    if (real <= 0) real = effectiveConfig.knownPromptTokens;
    // 上报值**超过窗口** ⇒ 不可信（真实请求不可能发出去），按窗口封顶。
    if (window != null && window > 0 && real > window) real = window;
    return real > est ? real : est;
  }

  /// 上一次请求服务端上报的**输入** token（没有则 0）。
  int _lastPromptTokens(AgentState state) {
    if (state.usages.isEmpty) return 0;
    final u = state.usages.last;
    return u.promptTokens > 0 ? u.promptTokens : 0;
  }

  /// 估算**历史消息**部分的 token（静态；构成统计共用）。
  static int estimateMessagesUsage(AgentState state) =>
      estimateMessagesTokens(state.history.messages);

  /// 估算**工具定义**的 token（最后一次工具面快照；静态）。
  ///
  /// ⚠️ **必须按 Map 键取值**：`ToolsHistoryItem.tools` 的类型是
  /// `List<Map<String, dynamic>>`（框架写入的是 `Tool.toJson()` 的产物）。
  /// 旧代码在 `dynamic` 上写 `t.description` ⇒ `dart analyze` 全绿，
  /// 一压缩就 `NoSuchMethodError`（审计 §3.1）。
  static int estimateToolDefinitions(AgentState state) {
    var total = 0;
    for (final t in _lastToolJsons(state)) {
      total += estimateTextTokens(_toolField(t, 'description'));
      total += estimateTextTokens(_toolField(t, 'name'));
      total += ContractCompaction.estimatedToolDefinitionOverheadTokens;
    }
    return total;
  }

  /// 取最后一次记录的工具定义快照（空列表时返回 `const []`，**不抛**）。
  static List<Map<String, dynamic>> _lastToolJsons(AgentState state) {
    if (state.toolsHistory.isEmpty) return const [];
    return state.toolsHistory.last.tools;
  }

  /// 从工具 JSON 里安全取一个字符串字段（类型不对就退化成 ''）。
  static String _toolField(Map<String, dynamic> toolJson, String key) {
    final v = toolJson[key];
    return v is String ? v : '';
  }

  /// 估算文本 token（静态）：CJK ≈ 1 字/token，ASCII ≈ 4 字符/token。
  static int estimateText(String text) => estimateTextTokens(text);

  /// 估算单条消息 token（静态，构成统计共用）。
  static int estimateMessageTokens(LLMMessage m) => estimateMessageTokensOf(m);
}
