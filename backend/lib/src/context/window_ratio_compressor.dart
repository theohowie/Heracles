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
    final usage = _estimateUsage(state);
    final fullLine = (window * compressAtRatio).floor();
    final autoLine = (window * ContractCompression.autoRatio).floor();
    final microLine = (window * ContractCompression.microRatio).floor();

    // ---- 没到第一级 ⇒ 什么都不做（装得下就全装）----
    if (usage < microLine) return;

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
    final beforeMessages = state.history.messages.length;
    final beforeTokens = usage;
    await _delegateFor(keepRecentTurns * ContractCompression.messagesPerTurn)
        .compress(state);
    var afterTokens = _estimateUsage(state);
    final afterMessages = state.history.messages.length;
    final summarized = afterMessages < beforeMessages || afterTokens < beforeTokens;

    if (summarized) {
      onCompressed?.call(beforeMessages, afterMessages, beforeTokens, afterTokens);
    }

    // ---- 第三级：full（强制重置，确定性）----
    // 触发条件：**现在**的估算仍在强制线上 —— 不管第二级是失败、静默早退、
    // 还是压了但不够。下一轮还有输出与工具结果要进来，80% 这条线不能赌。
    if (afterTokens >= fullLine) {
      final b2m = state.history.messages.length;
      final b2t = afterTokens;
      final dropped = _forceReset(state);
      if (dropped > 0) {
        onCompressed?.call(b2m, state.history.messages.length, b2t,
            _estimateUsage(state));
      }
    }
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

  /// 粗估当前历史占多少 token。
  ///
  /// 为什么要自己估：框架的 `ModelUsage` 只反映**上一次请求**的用量，
  /// 而压缩决策要看**当前累积**的历史（包括还没发出去的工具结果）。
  int _estimateUsage(AgentState state) =>
      estimateMessagesUsage(state) + estimateToolDefinitions(state);

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
