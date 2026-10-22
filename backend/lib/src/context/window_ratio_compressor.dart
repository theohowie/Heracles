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
  /// 0.75 的取舍：
  /// - 太低（如 0.5）⇒ 频繁压缩，丢细节，且多花摘要调用
  /// - 太高（如 0.95）⇒ 可能在压缩前就撞窗口，请求被拒
  final double compressAtRatio;

  /// 保留最近多少**轮**原文（不被压缩）。
  ///
  /// 必须是"轮"而不是"条"：一轮可能包含 1 条用户消息 + 5 条工具往返，
  /// 按条保留会留下半轮，模型看到"工具结果但没有对应的请求"。
  final int keepRecentTurns;

  /// 实际干活的压缩器（由框架提供）。
  ///
  /// ## 为什么用组合而不是继承
  ///
  /// 框架的 `LLMBasedContextCompressor` 已经写好了摘要 prompt（XML 快照格式，
  /// 含 overall_goal / key_knowledge / file_system_state / recent_actions）。
  /// **那套 prompt 是经过调优的，重写一个不会更好。**
  ///
  /// 我们只在**触发决策**和**保留多少**上做差异化，摘要本身交给它。
  late final ContextCompressor delegate =
      _delegateImpl ??
      LLMBasedContextCompressor(
        client: client,
        modelConfig: modelConfig,
        totalTokenThreshold: triggerThreshold,
        keepRecentMessageSize: keepRecentTurns * ContractCompression.messagesPerTurn,
      );

  final ContextCompressor? _delegateImpl;

  /// 触发压缩的 token 阈值。
  int get triggerThreshold => (modelWindowTokens * compressAtRatio).floor();

  /// 对外暴露的估算入口 —— **只为可测**（生产里由 [compress] 自己调）。
  ///
  /// 为什么要有它：审计 §3.1 那条 `toolsHistory` 崩溃之所以能藏在
  /// "44/44 全绿"后面，是因为估算函数是私有的、测试根本碰不到它。
  /// 把估算暴露出来，测试就能直接钉住"带 toolsHistory 的 state 不抛且 > 0"。
  /// 它**不改变任何行为**：`compress` 走的还是同一个 `_estimateUsage`。
  int estimateUsage(AgentState state) => _estimateUsage(state);

  @override
  Future compress(AgentState state) async {
    final usage = _estimateUsage(state);
    if (usage < triggerThreshold) {
      // 没到阈值 ⇒ **什么都不做**。这是与"默认压缩"策略的关键差异：
      // 装得下就全装，不因为"轮数多"而压缩。
      return;
    }
    await delegate.compress(state);
  }

  /// 粗估当前历史占多少 token。
  ///
  /// 为什么要自己估：框架的 `ModelUsage` 只反映**上一次请求**的用量，
  /// 而压缩决策要看**当前累积**的历史（包括还没发出去的工具结果）。
  int _estimateUsage(AgentState state) {
    var total = 0;
    for (final m in state.history.messages) {
      total += _estimateMessage(m);
    }
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
      total += _estimateTokens(_toolField(t, 'description'));
      total += _estimateTokens(_toolField(t, 'name'));
      total += 20; // 工具条目的固定 JSON 开销（括号、逗号、schema 骨架）
    }
    return total;
  }

  /// 取最后一次记录的工具定义快照。
  ///
  /// 空列表时返回 `const []`，**不抛** —— 压缩器不该因为"还没发过请求"而崩。
  List<Map<String, dynamic>> _lastToolJsons(AgentState state) {
    if (state.toolsHistory.isEmpty) return const [];
    return state.toolsHistory.last.tools;
  }

  /// 从工具 JSON 里安全取一个字符串字段。
  ///
  /// 用 `_toolField` 而不是 `t['name'] as String` 的理由：历史里的形状由**框架**
  /// 决定，将来它加/改字段时，这里应该退化成"少算一点 token"，而不是抛类型错。
  String _toolField(Map<String, dynamic> toolJson, String key) {
    final v = toolJson[key];
    return v is String ? v : '';
  }

  int _estimateMessage(LLMMessage m) {
    return switch (m) {
      SystemMessage(:final content) => _estimateTokens(content),
      // ⚠️ UserMessage 的字段是 `contents`（List<UserContentPart>），不是 `content`
      UserMessage(:final contents) => _estimateContentParts(contents),
      ModelMessage(:final textOutput, :final functionCalls) =>
        _estimateTokens(textOutput ?? '') + functionCalls.length * 30,
      // ⚠️ FunctionExecutionResult.content 也是 List<UserContentPart>
      FunctionExecutionResultMessage(:final results) => results.fold<int>(
          0,
          (s, r) => s + _estimateContentParts(r.content) + 10,
        ),
      _ => 50,
    };
  }

  int _estimateContentParts(List<UserContentPart> parts) {
    var n = 0;
    for (final p in parts) {
      if (p is TextPart) n += _estimateTokens(p.text);
      if (p is ImagePart) n += 800; // 图片按固定开销估
    }
    return n;
  }

  /// 文本 token 估算：CJK ≈ 1 字/token，ASCII ≈ 4 字符/token。
  ///
  /// 旧 Kotlin 实现用「字符数 / 4」统一估，`实测-08` 记录**中文场景高估 40%**
  /// ⇒ "明明装得下却提前压缩"，白丢上下文。
  int _estimateTokens(String text) {
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

  bool _isCjk(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) ||
      (r >= 0x3400 && r <= 0x4DBF) ||
      (r >= 0x3040 && r <= 0x30FF) ||
      (r >= 0xAC00 && r <= 0xD7AF) ||
      (r >= 0x3000 && r <= 0x303F) ||
      (r >= 0xFF00 && r <= 0xFFEF);
}
