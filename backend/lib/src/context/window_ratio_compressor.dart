/// **上下文压缩** —— 实现 `dart_agent_core` 的 [ContextCompressor] 接口。
///
/// ## 为什么是"实现接口"而不是"自己造一套预算管理"
///
/// `dart_agent_core` 已经在 `StatefulAgent` 的循环里留了压缩时机：
///
/// ```
/// [1] 压缩上下文（可选）：如果挂了 ContextCompressor 且超阈值，
///     老消息被压成 episodic memory，然后才发请求
/// ```
///
/// ⇒ **压缩时机由框架控制**，我们只负责"怎么压"。这比自己算预算再塞消息
/// 简单得多，也不会和框架的 token 统计打架。
///
/// ## 与框架自带 `LLMBasedContextCompressor` 的差异
///
/// 框架那个是通用实现（压成 XML 快照 + `keepRecentMessageSize = 10`）。
/// 我们只需要在**一件事**上不同：
///
/// | | 框架默认 | 本实现 |
/// |---|---|---|
/// | 触发阈值 | `totalTokenThreshold`（构造时定死） | 按**模型窗口比例**算（128K 模型和 1M 模型自适应） |
/// | 保留最近 | 固定条数 | 按**轮**保留（一轮 = 用户请求 + 若干工具往返） |
/// | 工具观察 | 参与压缩 | **参与压缩，但绝不单独截断**（见 [preserveToolOutputs]） |
///
/// ## 「不截断工具观察」是什么意思
///
/// 两条不同的操作，很容易混淆：
///
/// - **截断**（truncate）：一条工具输出 5000 行 → 只留前 500 字符。**残害信息**。
/// - **压缩**（compress）：把 20 轮历史摘要成一段。**有损但保留要点**。
///
/// 旧 Kotlin 实现在**截断**上犯过错（`ToolValidator` 按参数名限 500 字符），
/// 那是我这次必须避免的。压缩是允许的（窗口真要溢出时没有别的办法），
/// 但**压缩必须保住完整的工具结论**，不能"这条输出太长所以丢掉"。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../contract/contract.dart';

/// 按模型窗口比例触发的压缩器。
class WindowRatioCompressor implements ContextCompressor {
  WindowRatioCompressor({
    required this.client,
    required this.modelConfig,
    required this.modelWindowTokens,
    this.compressAtRatio = ContractCompression.compressAtRatio,
    this.keepRecentTurns = ContractCompression.keepRecentTurns,
    ContextCompressor? delegateImpl,
    this.onCompressed,
  }) : _delegateImpl = delegateImpl; // ignore: prefer_initializing_formals

  /// 用来做摘要的 client。
  ///
  /// ⚠️ **建议传小模型**：摘要不需要强推理，用便宜模型能省很多钱。
  /// （Operit 给 chat/memory/summarization 分别配模型就是这个思路。）
  final LLMClient client;

  /// 摘要用的模型配置。可以比主模型便宜。
  final ModelConfig modelConfig;

  /// 主模型的上下文窗口（token）。
  final int modelWindowTokens;

  /// 超过窗口的这个比例就触发压缩。
  ///
  /// 数值与取舍**只有一份真相**，在 `ContractCompression.compressAtRatio`
  /// （0.80，用户要求 80%）。这里故意不重复写那个数字 ——
  /// 抄一份过来就会出现"改了一处、另一处没跟上"的经典漂移。
  final double compressAtRatio;

  /// 保留最近多少**轮**原文（不被压缩）。
  ///
  /// 必须是"轮"而不是"条"：一轮可能包含 1 条用户消息 + 5 条工具往返，
  /// 按条保留会留下半轮，模型看到"工具结果但没有对应的请求"。
  final int keepRecentTurns;

  /// 实际干活的压缩器**按需构建**（第二级用；见 [_delegateFor]）。
  ///
  /// ## 为什么用组合而不是继承
  ///
  /// 框架的 `LLMBasedContextCompressor` 已经写好了摘要 prompt（XML 快照格式，
  /// 含 overall_goal / key_knowledge / file_system_state / recent_actions）。
  /// **那套 prompt 是经过调优的，重写一个不会更好。**
  ///
  /// 我们只在**触发决策**和**保留多少**上做差异化，摘要本身交给它。
  final ContextCompressor? _delegateImpl;

  /// **micro 换占位符的最小长度**（字符）。
  ///
  /// 小于这个数的工具结果不值得换：占位符本身就 40+ 字符，小结果换了
  /// 几乎不省 token，却让那次改写白付一次"缓存前缀失效"。
  static const int microMinChars = 200;

  /// **压缩真的发生之后**的回调（给 UI 播报用）。
  ///
  /// ## 触发条件（严格）
  ///
  /// 只有**真的动了历史**才调（各级自己保证）：
  /// 1. micro：确有占位符替换（token 真的省了）—— 条数**不变**，token 变小；
  /// 2. auto：delegate 跑完且历史有变化；
  /// 3. full：确有整批丢弃。
  /// 静默早退（delegate 什么都没做 / 没有可清的）⇒ **不播**，用户不该
  /// 收到"压缩了 40 条 → 40 条"这种无意义事件。
  ///
  /// 第 3 条是必须的：框架的 `LLMBasedContextCompressor.compress` 内部有**多个
  /// 静默早退分支**（`usages` 为空 / 消息条数不够 / 摘要正文为空 /
  /// 摘要 XML 解析失败被 catch 掉），那些情况下它**什么都没改**。
  /// 若不加这一条，UI 会收到"压缩了 40 条 → 40 条"这种无意义事件，
  /// 用户以为压缩坏了。
  ///
  /// ## 为什么参数是"前后快照"而不是只报一个数
  ///
  /// 用户要能看见"省了多少"。只报 after 的话，UI 得自己记住 before，
  /// 那是把状态散到界面层 —— 压不压缩只有这里知道，前后值必须一起交出去。
  final void Function(
    int beforeMessages,
    int afterMessages,
    int beforeTokens,
    int afterTokens,
  )? onCompressed;

  /// 触发压缩的 token 阈值（= 第三级强制线，保留给旧调用方与测试）。
  int get triggerThreshold => (modelWindowTokens * compressAtRatio).floor();

  /// 对外暴露的估算入口 —— **只为可测**（生产里由 [compress] 自己调）。
  ///
  /// 为什么要有它：审计 §3.1 那条 `toolsHistory` 崩溃之所以能藏在
  /// "44/44 全绿"后面，是因为估算函数是私有的、测试根本碰不到它。
  /// 把估算暴露出来，测试就能直接钉住"带 toolsHistory 的 state 不抛且 > 0"。
  /// 它**不改变任何行为**：`compress` 走的还是同一个 `_estimateUsage`。
  int estimateUsage(AgentState state) => _estimateUsage(state);

  /// **三级压缩**（2026-10-24 起，对齐 Claude Code 的 micro/auto/full）。
  ///
  /// ## 为什么要分级（而不是原来的一级 80%）
  ///
  /// 压缩是**有损**的，能保留就保留、逐级压缩 —— 这是 Claude Code
  /// （microcompact 40% / autocompact 60% / full 80%）验证过的形状。
  /// 一级方案的两个真实代价：
  ///
  /// 1. 40%→80% 之间上下文带着大量**已死工具输出**跑（老文件内容、长日志
  ///    —— 模型几乎从不回头用它们，但每轮都原样付一遍 token）；
  /// 2. 到 80% 一压就是大手术，信息损失集中发生；且摘要走 LLM，
  ///    **它可能静默失败**（框架 delegate 有一堆早退分支）——
  ///    一级方案失败后没有升级手段，下一轮直接撞窗。
  ///
  /// ## 三级各自的职责
  ///
  /// | 级 | 触发 | 手段 | LLM | 信息损失 |
  /// |---|---|---|---|---|
  /// | micro | ≥40% 且 <60% | 保护窗外的**老工具结果**换占位符（正文一字不动） | 否 | 仅工具原始输出（要就重读） |
  /// | auto | ≥60% | 框架 LLM 摘要（保最近 [keepRecentTurns] 轮） | 是 | 有损，但保留要点 |
  /// | full（强制） | 摘要后仍 ≥80% | **确定性强制重置**：整批丢弃老轮次 + 插一条说明 | 否 | 大，但**保证窗口不撞死** |
  ///
  /// 用户"到 80% 必须压缩然后继续任务"的承诺由第三级**兜底成立**：
  /// 它不依赖任何 LLM 调用成功，没有可静默早退的分支。
  @override
  Future compress(AgentState state) async {
    final window = modelWindowTokens;
    final usage = _decisionUsage(state, window: window);
    final fullLine = (window * compressAtRatio).floor();
    final autoLine = (window * ContractCompression.autoRatio).floor();
    final microLine = (window * ContractCompression.microRatio).floor();

    /// **估算偏差**：真实上报 / 字符估算。用于把"要腾多少真实 token"
    /// 折算成"估算上要腾多少"，以及压完后把估算折回真实值。
    final estAtStart = _estimateUsage(state);
    final bias = (usage > 0 && estAtStart > 0) ? usage / estAtStart : 1.0;

    // ---- 没到第一级 ⇒ 什么都不做（装得下就全装）----
    if (usage < microLine) return;

    // ★ 2026-11-05 排障：压缩到底有没有被触发、用的是哪套口径。
    //   只在"到了 micro 线以上"时打一行，避免每轮刷屏；debug 包看 logcat。
    //   （真机上用户报「60% 却没看到压缩」，这一行能直接给出答案：
    //    是 usage 没到线、还是到了线但各级都没动历史。）
    // ignore: avoid_print
    print('[compress] usage=$usage est=$estAtStart bias=${bias.toStringAsFixed(2)} '
        'window=$window micro=$microLine auto=$autoLine full=$fullLine '
        'msgs=${state.history.messages.length}');

    // ---- 第一级：micro（≥40% 且 <60%）----
    if (usage < autoLine) {
      final beforeMessages = state.history.messages.length;
      final beforeTokens = usage;
      final freed = _microCompact(state);
      // 没有可清的（老消息里没有大工具结果）⇒ 不播事件，也不算压缩过。
      if (freed <= 0) return;
      onCompressed?.call(
        beforeMessages,
        state.history.messages.length, // 条数不变 —— 换的是内容，不是删消息
        beforeTokens,
        _estimateUsage(state),
      );
      return;
    }

    // ---- 第二级：auto（≥60%，LLM 摘要）----
    //
    // 2026-11-04：优先用**结构化摘要**（保留清单见 `_structuredSummaryPrompt`），
    // 它失败/返回空才退回框架 delegate —— delegate 有一堆静默早退分支，
    // 单靠它会"什么都没做却不报错"。
    final beforeMessages = state.history.messages.length;
    final beforeTokens = usage;
    final structuredOk =
        await _structuredSummarize(state, keepRecentTurns * ContractCompression.messagesPerTurn);
    if (!structuredOk) {
      await _delegateFor(keepRecentTurns * ContractCompression.messagesPerTurn)
          .compress(state);
    }
    var afterTokens = _estimateUsage(state);
    final afterMessages = state.history.messages.length;
    final summarized = afterMessages < beforeMessages || afterTokens < beforeTokens;

    if (summarized) {
      onCompressed?.call(beforeMessages, afterMessages, beforeTokens, afterTokens);
    }

    // ---- 第三级：full（强制重置，确定性）----
    // 触发条件：**真实占用**仍在强制线上 —— 不管第二级是失败、静默早退、
    // 还是压了但不够。下一轮还有输出与工具结果要进来，80% 这条线不能赌。
    //
    // ⚠️ 这里用 `usage`（决策口径：真值与估算取大）而不是 `afterTokens`（低估的字符估算）：
    // 真机 11:35 那次就是"真值 104K / 估算 20K"，按估算判断永远到不了线。
    var acted = summarized;
    // 2026-11-04：**先看摘要有没有把占用压到强制线以下** —— 压下来了就别再重置，
    // 否则会把刚生成的结构化摘要连同老消息一起丢掉（真机用例 ② 逮到过）。
    if (usage >= fullLine && _estimateUsage(state) >= fullLine) {
      final b2m = state.history.messages.length;
      final b2t = afterTokens;
      final dropped = _forceReset(state);
      if (dropped > 0) {
        acted = true;
        onCompressed?.call(b2m, state.history.messages.length, b2t,
            _estimateUsage(state));
      }
    }

    // ---- 第四级（兜底，2026-11-04 真机修）：按 **token** 真降压 ----
    // ## 为什么必须有这一级
    //
    // 上面三级都拿"最近 keepRecentTurns(6) 轮 ≈ 24 条"当保护窗，于是
    // **「消息很少、单条内容巨大」**（一次 read_file 把整份大文件读进历史）
    // 会同时落进三级的空档：
    // · micro：大工具结果在保护窗**内** ⇒ 无可清 ⇒ 返回 0；
    // · auto：框架摘要可能静默早退（无可摘 / 无 usage）；
    // · full：`if (msgs.length <= keepMessages) return 0;` ⇒ 条数少就整段放弃。
    //
    // 真机现场（用户 2026-11-04 10:19）：上下文 102% 却**一处都没动**，
    // 用户判断"压缩机制是坏的"—— 是对的（回归闸见
    // `test/compression_short_history_test.dart`）。
    //
    // ## 目标怎么定（关键）
    //
    // 决策用的是"真值 104K"，而裁剪时只能用**字符估算**（20K）来量。
    // 两个口径差 5 倍，直接把 fullLine 当裁剪目标会"清不动就停"。
    // 所以按 **scale = 真值 / 估算** 把"要腾出来的真实 token 数"折算成估算单位：
    //   要压到 autoLine(60%) ⇒ 需要腾出 (usage - autoLine) 真实 token
    //                        ⇒ 估算上要腾出 (usage - autoLine) / scale
    // 只在"前面几级都没真正动过历史"时才兜底 —— 否则会把刚重置好的历史再砍一刀
    // （第三级的设计承诺是"压到强制线以下"，不是"压到 60%"）。
    if (usage >= fullLine && (!acted || _estimateUsage(state) >= fullLine)) {
      final estNow = _estimateUsage(state);
      final scale = bias;
      final wantReal = (window * ContractCompression.autoRatio).floor();
      var needReal = usage - wantReal;
      if (needReal <= 0) needReal = usage - ((fullLine * 0.9).floor());
      if (needReal < 0) needReal = 0;
      final needEst = (needReal / (scale <= 0 ? 1.0 : scale)).ceil();
      final targetEstimate = estNow - needEst < 1 ? 1 : estNow - needEst;

      final b3m = state.history.messages.length;
      final b3t = estNow;
      final trimmed = _trimToFit(state, targetEstimateTokens: targetEstimate);
      if (trimmed) {
        onCompressed?.call(b3m, state.history.messages.length, b3t,
            _estimateUsage(state));
      }
    }

    // ---- 第五级：发送硬顶 → **继续压，不许停、不许报错**（2026-11-05 用户裁定）----
    //
    // 用户原话：「90% 到达这个阈值，就是先压缩，不能报错，不能停下，就是调用
    // 压缩工具，压缩完了再继续任务」。
    //
    // 所以这一级**不再是"抛错闸"**，而是"再压一轮"的**升级循环**：
    // 每轮把目标收紧（50% → 30% → 15% 窗口），用 `_trimToFit` 继续清；
    // 哪一轮已经动不了历史（没有可清/可丢/可截的）就说明这是**压缩的物理下限**，
    // 此时**照常继续任务**（不再抛错），只把"压到多少了"如实播报。
    //
    // 为什么不抛错：抛错 = 这一轮白跑，而用户要的是"压完接着干"。
    // 为什么不怕超限：缓存前缀/上下文都是我们自己的，压到下限后若仍超窗口，
    // 那是**窗口设置本身错了**（或上游给的上限比设置小）——那种情况在设置页
    // 把"上下文窗口"填对即可；代码不该替用户做"停任务"这个决定。
    final reported = _lastPromptTokens(state);
    final reportedTrustworthy = reported > 0 && reported <= window;
    final biasForCeiling = reportedTrustworthy ? bias : 1.0;
    final ceiling = (window * ContractCompression.sendCeilingRatio).floor();

    int approxReal() {
      final est = _estimateUsage(state);
      return (est * (biasForCeiling < 1 ? 1.0 : biasForCeiling)).round();
    }

    // 升级目标：50% → 30% → 15%（估算口径 = 真实目标 / bias）
    for (final ratio in const <double>[0.50, 0.30, 0.15]) {
      if (approxReal() < ceiling) break;
      final targetReal = (window * ratio).floor();
      final targetEstimate =
          (targetReal / (biasForCeiling < 1 ? 1.0 : biasForCeiling)).floor();
      final bm = state.history.messages.length;
      final bt = _estimateUsage(state);
      final acted2 = _trimToFit(
        state,
        targetEstimateTokens: targetEstimate < 1 ? 1 : targetEstimate,
      );
      if (!acted2) break; // 已经压到物理下限
      onCompressed?.call(bm, state.history.messages.length, bt,
          _estimateUsage(state));
    }
  }

  /// **第四级兜底：把占用真的降到 [budget] 以下**（确定性，不依赖 LLM）。
  ///
  /// 三招按代价从低到高依次做，够用就停：
  ///
  /// 1. **老的/大的工具结果换占位符**（此时保护窗让路 —— 已经超线了，
  ///    留住"窗口被撑爆"比留住一份能重读的工具输出更糟）；
  /// 2. **按 token 丢更早的消息**（`_adjustCut` 保证不拆"调用↔结果"配对），
  ///    且**永远保留最后一条**（模型要知道当前这轮发生了什么）；
  /// 3. 单条就超（极少见）⇒ 对**最大的一条**文本做截断，保留头部并写明已截断。
  ///
  /// 返回是否真的动过历史（动过才播 `context_compressed`）。
  ///
  /// [targetEstimateTokens] 是**估算口径**的目标（不是真实 token）——
  /// 调用方已按 `scale = 真值/估算` 折算过（见 `compress` 第四级）。
  bool _trimToFit(AgentState state, {required int targetEstimateTokens}) {
    // 说明消息本身要占位，先扣掉
    final target = (targetEstimateTokens - _trimNoteAllowance) < 1
        ? 1
        : targetEstimateTokens - _trimNoteAllowance;
    var acted = false;
    final details = <String>[];

    // ---- 第 1 招：大工具结果 → 占位符（旧→新，够用就停）----
    final msgs = state.history.messages;
    for (var i = 0; i < msgs.length; i++) {
      if (_estimateUsage(state) < target) break;
      final m = msgs[i];
      if (m is! FunctionExecutionResultMessage) continue;
      final replaced = _replaceBigResults(m, minChars: microMinChars);
      if (replaced == null) continue;
      msgs[i] = replaced;
      acted = true;
      details.add('清理了少量老工具输出');
    }

    // ---- 第 2 招：按 token 丢更早的消息（保留最后一条）----
    if (_estimateUsage(state) >= target && state.history.messages.length > 1) {
      final list = state.history.messages;
      var chosen = -1;
      for (var k = 1; k < list.length; k++) {
        if (_estimateRange(list, k) + _trimNoteAllowance <= target) {
          chosen = k;
          break;
        }
      }
      // 没有任何后缀装得下 ⇒ 只保最后一条（它仍可能超，交给第 3 招）
      var cut = chosen >= 0 ? chosen : list.length - 1;
      cut = _adjustCut(list, cut);
      if (cut <= 0) cut = 1;
      if (cut < list.length) {
        final removed = cut;
        state.history.messages = list.sublist(cut);
        acted = true;
        details.add('移除了更早的 $removed 条消息');
      }
    }

    // ---- 第 3 招：单条仍超 ⇒ 截断最大那条的文本 ----
    if (_estimateUsage(state) >= target) {
      final truncated = _truncateLargestMessage(state, target);
      if (truncated != null) {
        acted = true;
        details.add('截断了 1 条超长内容（原 $truncated 字符，需要请重新读取）');
      }
    }

    if (!acted) return false;

    // ---- 如实说明（头部插入，不改变"最后一条"）----
    state.history.messages = <LLMMessage>[
      UserMessage.text(
        '[系统维护] 上下文窗口吃紧，已自动腾出空间：${details.join('；')}。'
        '这些内容**没有**进摘要（摘要本轮未成功），如需依据请重新读取相应文件；'
        '继续任务时请如实告知用户上下文被清理过。',
      ),
      ...state.history.messages,
    ];
    return true;
  }

  /// 说明消息的 token 预留（约 120 个汉字量级）。
  static const int _trimNoteAllowance = 200;

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
  /// 只截 `FunctionExecutionResultMessage` 与 `UserMessage` 的文本：
  /// `ModelMessage` 里可能带 functionCalls，重建成本与风险都更高（且它通常不大）。
  int? _truncateLargestMessage(AgentState state, int target) {
    final msgs = state.history.messages;
    var bestIndex = -1;
    var bestTokens = 0;
    for (var i = 0; i < msgs.length; i++) {
      final t = estimateMessageTokens(msgs[i]);
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
    //   以前只截工具结果与用户消息 ⇒ 这种情况"无计可施"直接撞发送硬顶（e2e 抓到）。
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

  /// 按需要的保留量建 delegate（第二级用；框架实现，KDoc 见字段声明）。
  ContextCompressor _delegateFor(int keepMessageSize) =>
      _delegateImpl ??
      LLMBasedContextCompressor(
        client: client,
        modelConfig: modelConfig,
        // 阈值给 1 ⇒ 只要我们这层决定"该摘要了"，框架层就别再拦
        //（它自己的早退条件见 WindowRatioCompressor 原 KDoc；
        //  usages 为空时它仍会静默跳过 —— 那由第三级兜底）。
        totalTokenThreshold: 1,
        keepRecentMessageSize: keepMessageSize,
      );

  /// **结构化摘要（2026-11-04，对齐 Anthropic compaction 的保留清单）**。
  ///
  /// ## 为什么不用框架的自由摘要
  ///
  /// 框架 `LLMBasedContextCompressor` 让模型自由写"要点"，实测有两个问题：
  /// ① 它会**静默早退**（usages 为空 / 摘要为空 / XML 解析失败都 catch 掉）；
  /// ② 保留什么都由模型临场决定 —— 容易漏掉"用户明确禁止动某个文件"这类硬约束。
  ///
  /// Anthropic 在 [Effective context engineering]（compaction 一节）明确说：
  /// 保留**架构决策、未解决的 bug、实现细节**，丢弃**冗余工具输出**，
  /// 并要求"先最大化 recall，再收紧 precision"。LLMLingua / RECOMP 那类
  /// "压缩到 6%~5%" 是给**检索文档**用的，不适用于对话状态 —— 所以这里按
  /// "结构化字段一个都不能少"来做，而不是追求极限压缩率。
  ///
  /// 返回 true = 真的替换了历史；false = 没做（调用方走 delegate 或强制重置）。
  Future<bool> _structuredSummarize(AgentState state, int keepMessages) async {
    final msgs = state.history.messages;
    if (msgs.length <= keepMessages) return false;

    var cut = msgs.length - keepMessages;
    cut = _adjustCut(msgs, cut);
    if (cut <= 0 || cut >= msgs.length) return false;

    final head = msgs.sublist(0, cut);
    final tail = msgs.sublist(cut);
    final transcript = StringBuffer();
    for (final m in head) {
      final text = switch (m) {
        UserMessage() => '[用户] ${_contentText(m.contents)}',
        ModelMessage() =>
          '[助手] ${(m.textOutput ?? '').trim()}'
              '${m.functionCalls.isEmpty ? '' : '（调用：${m.functionCalls.map((c) => c.name).join(',')}）'}',
        FunctionExecutionResultMessage() =>
          '[工具结果] ${m.results.map((r) => _clipText(_contentText(r.content), 400)).join(' | ')}',
        SystemMessage() => '[系统] ${_clipText(m.content, 400)}',
        _ => '',
      };
      if (text.trim().isEmpty) continue;
      transcript.writeln(_clipText(text, 1200));
    }

    String out;
    try {
      final resp = await client.generate(
        [
          SystemMessage(_structuredSummaryPrompt),
          UserMessage.text(transcript.toString()),
        ],
        modelConfig: modelConfig,
      );
      out = (resp.textOutput ?? '').trim();
    } catch (_) {
      return false; // 网络/超时 ⇒ 交给上层 fallback
    }
    if (out.isEmpty) return false;

    final note = UserMessage.text(
      '[上下文压缩快照] 以下是更早对话的结构化摘要（原文已移除，可按需重新取证）：\n'
      '$out\n'
      '[说明] 上面的工具原始输出已被清理；需要细节请重新执行相应工具读取。'
      '如果摘要与你的记忆有冲突，**以工作区文件的实际内容为准**。',
    );
    state.history.messages = <LLMMessage>[note, ...tail];
    return true;
  }

  /// 结构化摘要的**保留清单**（一个字段都不许省）。
  ///
  /// 依据（见方法 KDoc）：Anthropic compaction 实践 + 真机踩过的坑 ——
  /// 用户明确说过"文件写入 A，不要动 B"，这种硬约束一旦被摘要漏掉，
  /// 模型就会去改 B，而用户完全不知道是压缩丢的。
  static const String _structuredSummaryPrompt = '''
你是上下文压缩器。把给出的对话历史压缩成结构化笔记，供同一个 agent 继续任务。

【必须保留（一个都不能少）】
1. goal：用户的任务目标（用用户自己的措辞概括）
2. constraints：用户明确提出的硬约束与偏好（例如"文件写入 A，不要动 B"、"不要改权限"）
3. decisions：已经做出的技术决策，以及**为什么**这么选
4. files：已创建/修改的文件路径，以及每个文件改了什么要点
5. open_issues：尚未解决的报错（保留关键报错原文一行）、失败的尝试及原因
6. plan：当前进度 —— 哪些步骤已完成、下一步该做什么

【可以丢弃】
- 完整的工具原始输出（整份文件内容、长日志）—— 需要时可重新读取
- 重复内容、寒暄、与目标无关的旁枝

【输出格式】只输出下面六个标签块，不要任何额外解释：
<goal>…</goal>
<constraints>…</constraints>
<decisions>…</decisions>
<files>…</files>
<open_issues>…</open_issues>
<plan>…</plan>
''';

  /// 截断一段文本（摘要输入用，防止源文本本身把摘要请求撑爆）。
  static String _clipText(String text, int max) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= max ? one : '${one.substring(0, max)}…';
  }

  /// **第一级：micro** —— 把保护窗之外的老工具结果换成占位符。
  ///
  /// ## 规则
  ///
  /// · 只动 `FunctionExecutionResultMessage`（工具输出），**绝不**动
  ///   user/assistant 正文 —— 那是决策与结论，丢了才是真损失；
  /// · 只动保护窗（最近 [keepRecentTurns] 轮折算条数）**之外**的；
  /// · 只换**大的**（≥ [microMinChars]）：小结果占不了几个 token，
  ///   换它纯属折腾（改写本身也让缓存前缀失效一次，得不偿失）；
  /// · 占位符写明"原 N 字符 + 需要就重跑" —— 模型有明确的恢复路径，
  ///   而不是面对一个莫名的空洞。
  ///
  /// 返回省下的**估算 token**（0 = 什么都没换）。
  int _microCompact(AgentState state) {
    final msgs = state.history.messages;
    final protectedTail =
        keepRecentTurns * ContractCompression.messagesPerTurn;
    if (msgs.length <= protectedTail) return 0;
    final cutoff = msgs.length - protectedTail;

    var freed = 0;
    for (var i = 0; i < cutoff; i++) {
      final m = msgs[i];
      if (m is! FunctionExecutionResultMessage) continue;
      var replacedAny = false;
      final newResults = <FunctionExecutionResult>[];
      for (final r in m.results) {
        final text = _contentText(r.content);
        if (text.length < microMinChars) {
          newResults.add(r); // 小结果原样保留
          continue;
        }
        final placeholder = '[工具结果已清理（microcompact）：原 ${text.length} 字符。'
            '如仍需要该信息，请重新执行相应工具获取。]';
        freed += estimateText(text) - estimateText(placeholder);
        newResults.add(FunctionExecutionResult(
          id: r.id,
          name: r.name,
          isError: r.isError,
          arguments: r.arguments,
          content: [TextPart(placeholder)],
          timestamp: r.timestamp,
        ));
        replacedAny = true;
      }
      if (replacedAny) {
        msgs[i] = FunctionExecutionResultMessage(
          results: newResults,
          timestamp: m.timestamp,
        );
      }
    }
    return freed;
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
  /// 找最早能满足"保留区 < 强制线"的切点，一次丢够
  /// （保留区仍受 [keepRecentTurns] 批的**上限**约束 —— 丢再多也不少于它，
  /// 除非连它都到不了线，那就只保最后一批）。
  ///
  /// ## 没有批次边界怎么办
  ///
  /// 历史可能几乎全是 assistant（长工具链，user 很少）—— 此时按条数
  /// 找切点，再把切点**调整到不拆批**的位置（见 [_adjustCut]）。
  ///
  /// ## 丢弃的内容去哪了
  ///
  /// 没去哪 —— 这一级是"未及摘要的强制清场"（第二级失败/不够才会走到这里）。
  /// 头部插一条**如实**的说明：多少条被移除、未摘要、需要就重新取证。
  /// 绝不假装"已经总结过了"。
  ///
  /// 返回丢弃的条数（0 = 没有可丢的）。
  int _forceReset(AgentState state) {
    final msgs = state.history.messages;
    final keepMessages = keepRecentTurns * ContractCompression.messagesPerTurn;
    if (msgs.length <= keepMessages) return 0;

    final fullLine = (modelWindowTokens * compressAtRatio).floor();
    final starts = <int>[
      for (var i = 0; i < msgs.length; i++)
        if (msgs[i] is UserMessage) i,
    ];

    int cut;
    if (starts.length >= 2) {
      // 从"最多保 keepRecentTurns 批"的切点起，往更早找（丢更多），
      // 找第一个"保留后缀 + 说明消息 < 强制线"的切点。
      final earliest = starts.length - keepRecentTurns;
      var chosen = earliest > 0 ? earliest : 1;
      if (chosen < 1) chosen = 1;
      for (var k = chosen; k < starts.length; k++) {
        final suffix = _estimateRange(msgs, starts[k]);
        if (suffix + _resetNoteTokenAllowance < fullLine) {
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
    if (cut <= 0) return 0;

    final note = UserMessage.text(
      '[系统维护] 更早的 $cut 条消息因上下文窗口吃紧被强制移除'
      '（摘要未成功，这些内容未保存）。'
      '如需更早的信息，请依据工作区文件重新取证，并如实告知用户上下文被清理过。',
    );
    state.history.messages = <LLMMessage>[note, ...msgs.sublist(cut)];
    return cut;
  }

  /// 重置说明消息自身的 token 预留（选取切点时粗算，文本 ~90 个字符）。
  static const int _resetNoteTokenAllowance = 120;

  /// 估算 `msgs[from..]` 的 token（批次后缀估算，选切点用）。
  int _estimateRange(List<LLMMessage> msgs, int from) {
    var total = 0;
    for (var i = from; i < msgs.length; i++) {
      total += estimateMessageTokens(msgs[i]);
    }
    return total;
  }

  /// 把按条数算出的切点调整到**不拆批**的位置。
  ///
  /// 规则：切点落点的第一条消息若是
  /// · `FunctionExecutionResultMessage` ⇒ 它的配对调用在前面 ⇒ 切点**前移**（多留）；
  /// · 带调用的 `ModelMessage` 且其结果不在保留区 ⇒ 切点**后移**（少留，连调用一起丢）。
  /// 有界循环（最多走一遍消息列表），绝不死循环。
  int _adjustCut(List<LLMMessage> msgs, int raw) {
    var cut = raw.clamp(0, msgs.length);
    for (var guard = 0; guard < msgs.length + 1; guard++) {
      if (cut >= msgs.length || cut <= 0) return cut;
      final m = msgs[cut];
      if (m is FunctionExecutionResultMessage) {
        cut--;
        continue;
      }
      if (m is ModelMessage && m.functionCalls.isNotEmpty) {
        // 调用留在保留区开头：看下一条是不是它的结果
        final next = cut + 1 < msgs.length ? msgs[cut + 1] : null;
        if (next is FunctionExecutionResultMessage) {
          return cut; // 成对保留，合法
        }
        cut++; // 结果已被丢掉 ⇒ 连调用一起丢
        continue;
      }
      return cut;
    }
    return cut;
  }

  /// 拼接结果内容里的纯文本（micro 占位计算用）。
  String _contentText(List<UserContentPart> parts) {
    final buf = StringBuffer();
    for (final p in parts) {
      if (p is TextPart) buf.write(p.text);
    }
    return buf.toString();
  }

  /// **把分项估算按"真实总量"等比放大**（2026-11-04，用户要求环图别自相矛盾）。
  ///
  /// ## 为什么需要
  ///
  /// 真机截图里同一屏出现两个口径：分项合计 ~20K，总量却是 `~104.0K / 128.0K`。
  /// 总量是服务端真值（对），分项是字符估算（低估约 5 倍）。两个数并排，
  /// 用户只会得出一个结论：**"这软件在骗我"**。
  ///
  /// 这里把分项按 `真实总量 / 估算合计` 等比放大，并**把舍入误差补到最大的一项**，
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

  /// **粗估**当前历史占多少 token。
  ///
  /// 为什么要自己估：框架的 `ModelUsage` 只反映**上一次请求**的用量，
  /// 而压缩决策要看**当前累积**的历史（包括还没发出去的工具结果）。
  int _estimateUsage(AgentState state) =>
      estimateMessagesUsage(state) + estimateToolDefinitions(state);

  /// **决策用的占用**：取"估算"与"服务端真实上报"两者的**较大值**。
  ///
  /// ## 为什么必须掺进真值（2026-11-04 真机修）
  ///
  /// 真机现场（用户 11:35 截图）：用量抽屉里分项合计只有 ~20K
  /// （系统 2.7K + 工具定义 10.6K + 工具结果 4.7K + 助手 1.8K），
  /// 但同一屏的总量写着 **~104.0K / 128.0K（81%）** —— 那是 provider 真实上报的
  /// `promptTokens`。**我们的字符估算低估了约 5 倍**（工具 JSON、代码、结构化文本
  /// 的 `字符/4` 系数明显不够），于是：
  ///
  /// · 抽屉显示 104K（真值）；
  /// · 压缩器按 **20K** 判断 ⇒ 离 80% 线（102.4K）差得远 ⇒ **永不压缩**；
  /// · 真实上下文一路涨到 100%+ ⇒ 用户看到"溢出却不压"。
  ///
  /// 取 `max(真值, 估算)` 的理由：
  /// · 真值是**服务端数的**，做窗口判断必须以它为准（估算再准也只是估算）；
  /// · 估算覆盖"上一次请求之后新追加的消息"（真值还没反映它们）；
  /// · 取大值 = **宁可早压**（压早了只是多一次摘要；压晚了直接撞窗失败）。
  int _decisionUsage(AgentState state, {int? window}) {
    final est = _estimateUsage(state);
    var real = _lastPromptTokens(state);
    // ★ 2026-11-04：上报值**超过窗口** ⇒ 不可信（真实请求不可能发出去），
    //   按窗口封顶。否则一个撒谎/错位的 usage 就能把决策推到"永远超线"，
    //   进而触发发送硬顶、把好好的任务判死（e2e 用例当场逮到：999999 vs 20K 窗口）。
    if (window != null && window > 0 && real > window) real = window;
    return real > est ? real : est;
  }

  /// 上一次请求服务端上报的**输入** token（没有则 0）。
  int _lastPromptTokens(AgentState state) {
    if (state.usages.isEmpty) return 0;
    final u = state.usages.last;
    return u.promptTokens > 0 ? u.promptTokens : 0;
  }

  /// 估算**历史消息**部分的 token（2026-10-24，C5 构成统计；静态，无需实例）。
  static int estimateMessagesUsage(AgentState state) {
    var total = 0;
    for (final m in state.history.messages) {
      total += estimateMessageTokens(m);
    }
    return total;
  }

  /// 估算**工具定义**的 token（最后一次工具面快照；静态）。
  ///
  /// 工具定义也占输入 token，且是常驻开销 —— 构成统计要把它们单列。
  static int estimateToolDefinitions(AgentState state) {
    var total = 0;
    // 工具定义也占输入 token，且是常驻开销。
    //
    // ⚠️ **必须按 Map 键取值**：`ToolsHistoryItem.tools` 的类型是
    // `List<Map<String, dynamic>>`（框架 `stateful_agent.dart` 里
    // `request.tools.map((t) => t.toJson()).toList()` 写入的），
    // 元素是 `Tool.toJson()` 的产物 ⇒ 键名固定为
    // `name` / `description` / `parameters` / `namedParameters` / `parameterMode`。
    //
    // 旧写法 `t.description` / `t.name` 是在 `dynamic` 上跑 ——
    // 静态检查看不见，运行时直接
    // `NoSuchMethodError: Class '_Map<String, dynamic>' has no instance getter 'description'`。
    // 这就是 `dart analyze` 报 "No issues found!" 却一压缩就崩的那条（审计 §3.1）。
    for (final t in _lastToolJsons(state)) {
      total += estimateText(_toolField(t, 'description'));
      total += estimateText(_toolField(t, 'name'));
      total += 20; // 工具条目的固定 JSON 开销（括号、逗号、schema 骨架）
    }
    return total;
  }

  /// 取最后一次记录的工具定义快照。
  ///
  /// 空列表时返回 `const []`，**不抛** —— 压缩器不该因为"还没发过请求"而崩。
  static List<Map<String, dynamic>> _lastToolJsons(AgentState state) {
    if (state.toolsHistory.isEmpty) return const [];
    return state.toolsHistory.last.tools;
  }

  /// 从工具 JSON 里安全取一个字符串字段。
  ///
  /// 用 `_toolField` 而不是 `t['name'] as String` 的理由：历史里的形状由**框架**
  /// 决定，将来它加/改字段时，这里应该退化成"少算一点 token"，而不是抛类型错。
  static String _toolField(Map<String, dynamic> toolJson, String key) {
    final v = toolJson[key];
    return v is String ? v : '';
  }

  /// 估算文本 token（静态）：CJK ≈ 1 字/token，ASCII ≈ 4 字符/token。
  ///
  /// 旧 Kotlin 实现用「字符数 / 4」统一估，`实测-08` 记录**中文场景高估 40%**
  /// ⇒ "明明装得下却提前压缩"，白丢上下文。
  static int estimateText(String text) {
    if (text.isEmpty) return 0;
    var cjk = 0;
    var other = 0;
    for (final r in text.runes) {
      if (_isCjk(r)) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + (other / 4).ceil();
  }

  /// 估算单条消息 token（静态，构成统计共用）。
  static int estimateMessageTokens(LLMMessage m) {
    return switch (m) {
      SystemMessage(:final content) => estimateText(content),
      // ⚠️ UserMessage 的字段是 `contents`（List<UserContentPart>），不是 `content`
      UserMessage(:final contents) => _estimateContentParts(contents),
      ModelMessage(:final textOutput, :final functionCalls) =>
        estimateText(textOutput ?? '') + functionCalls.length * 30,
      // ⚠️ FunctionExecutionResult.content 也是 List<UserContentPart>
      FunctionExecutionResultMessage(:final results) => results.fold<int>(
          0,
          (s, r) => s + _estimateContentParts(r.content) + 10,
        ),
      _ => 50,
    };
  }

  static int _estimateContentParts(List<UserContentPart> parts) {
    var n = 0;
    for (final p in parts) {
      if (p is TextPart) n += estimateText(p.text);
      if (p is ImagePart) n += 800; // 图片按固定开销估
    }
    return n;
  }

  static bool _isCjk(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) ||
      (r >= 0x3400 && r <= 0x4DBF) ||
      (r >= 0x3040 && r <= 0x30FF) ||
      (r >= 0xAC00 && r <= 0xD7AF) ||
      (r >= 0x3000 && r <= 0x303F) ||
      (r >= 0xFF00 && r <= 0xFFEF);
}
