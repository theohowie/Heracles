/// **SendView（发送视图）** —— "这次请求实际发出去的是什么"。
///
/// ## 为什么要把它和 `state.history` 分开
///
/// 会话正文是**严格 append-only 的**（`.jsonl` 命中 90–99% 的前缀缓存，
/// 见 AGENTS.md 的硬约束）。压缩要做的从来不是"删掉历史"，而是
/// **换一个更小的投影去发**：
///
/// ```
/// state.history.messages  ← 真源（原始记录，不删、不重排）
///        ↓ 投影
/// SendView.messages       ← 这次真的发出去的那一份（老工具输出被换成占位符）
/// ```
///
/// 所以：
/// · `SendView.messages` 里的占位符是**副本**，`MicroCompactor` 绝不原地改对象；
/// · 被清掉的内容用 [clearedRefs] 记账（`id` + 原字符数），**可追溯、可恢复**；
/// · `/rewind` 这类"截断发送视图"的命令只改 SendView，**原始 JSONL 一个字都不动**
///   （用户 2026-11-06 拍板 Q5）。
///
/// ## `clearedRefs` 的键是什么
///
/// 工具结果用 `FunctionExecutionResult.id`（= 框架那次调用的 id，与会话里的
/// `call-…` 对得上，能指回原始记录）；媒体块没有 id，用
/// `media:<消息序号>:<块序号>` 这种确定性合成键（同一次压缩结果稳定，
/// 便于 UI 对账，不做哈希）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import 'token_estimation.dart';

/// 被清掉的块属于哪一类。
enum ClearedKind {
  /// 工具输出（历史里绝大多数是这类：整份文件内容、长日志）。
  toolResult,

  /// 媒体块（图片/视频）。
  media,
}

/// 一个"被清掉"的块的记账条目。
class ClearedRef {
  const ClearedRef({
    required this.id,
    required this.originalChars,
    required this.kind,
  });

  /// 工具结果 = `FunctionExecutionResult.id`；媒体块 = 合成键。
  final String id;

  /// 被清掉内容的**原始字符数**（不是 token）—— 追溯与"要不要恢复"的依据。
  final int originalChars;

  /// 类别。
  final ClearedKind kind;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'originalChars': originalChars,
        'kind': kind.name,
      };

  @override
  String toString() => 'ClearedRef(${kind.name}, $id, $originalChars 字符)';
}

/// 发送视图：这次请求真正发出去的消息 + 记账 + 规模。
class SendView {
  const SendView({
    required this.messages,
    this.clearedRefs = const <String, ClearedRef>{},
    required this.estTokens,
  });

  /// 这次要发出去的消息（可能是历史的副本，含占位符）。
  final List<LLMMessage> messages;

  /// 被清掉块的记账（键见 [ClearedRef.id] 的说明）。
  final Map<String, ClearedRef> clearedRefs;

  /// 该视图的估算 token（只算消息，不含 system/tools —— 那两块本就不在历史里）。
  final int estTokens;

  /// 用一组消息现算一个视图（不做任何清理）。
  factory SendView.of(
    List<LLMMessage> messages, {
    Map<String, ClearedRef> clearedRefs = const <String, ClearedRef>{},
  }) =>
      SendView(
        messages: messages,
        clearedRefs: clearedRefs,
        estTokens: estimateMessagesTokens(messages),
      );

  int get messageCount => messages.length;

  @override
  String toString() =>
      'SendView(${messages.length} 条 / 约 $estTokens token / 已清 ${clearedRefs.length} 块)';
}

/// **把发送视图截断到最近 [rounds] 轮**（原始历史不动）。
///
/// 语义与 `keepRecentTurns` 一致：一轮 = 一条 `UserMessage` 及其后面的
/// 工具往返/助手消息。切点会**向后调整到不拆批**的位置 —— 保留区若以一个
/// `FunctionExecutionResultMessage` 开头，说明它的"调用"被丢了（拆散调用与
/// 结果 = provider 直接 400）。
///
/// 三种边界（都不许抛）：
/// · `rounds <= 0` ⇒ 只保留最后一条消息（模型至少要知道这一轮发生了什么）；
/// · 历史里没有 UserMessage（纯工具链）⇒ 按条数保留末尾 `rounds × messagesPerTurn` 条；
/// · 轮数多于实际 ⇒ 原样返回（截断是"最多留 N 轮"，不是"补到 N 轮"）。
///
/// 另外一个边界：切点为了"不拆批"被一路前移到 0 ⇒ **原样返回全部消息**
/// （宁可多留，也不许留下一个有结果没请求的破历史 —— 那会直接 400）。
SendView truncateSendViewToRounds(
  List<LLMMessage> messages,
  int rounds, {
  Map<String, ClearedRef> clearedRefs = const <String, ClearedRef>{},
  int messagesPerRound = 4,
}) {
  if (messages.isEmpty) {
    return SendView(
      messages: const <LLMMessage>[],
      clearedRefs: clearedRefs,
      estTokens: 0,
    );
  }

  final starts = <int>[
    for (var i = 0; i < messages.length; i++)
      if (messages[i] is UserMessage) i,
  ];

  int cut;
  if (rounds <= 0) {
    cut = messages.length - 1;
  } else if (starts.isEmpty) {
    // 纯工具链（几乎没有 user）：按条数兜底，至少留一条
    final keep = rounds * messagesPerRound;
    cut = messages.length - keep;
  } else if (starts.length <= rounds) {
    cut = 0; // 轮数足够，不截断
  } else {
    cut = starts[starts.length - rounds];
  }

  if (cut < 0) cut = 0;
  if (cut > messages.length) cut = messages.length;

  // 切点落点若是工具结果 ⇒ 它的调用在切点之前，前移一格（多留一条，成对）
  while (cut > 0 && cut < messages.length) {
    final at = messages[cut];
    if (at is FunctionExecutionResultMessage) {
      cut--;
      continue;
    }
    break;
  }

  final kept = cut <= 0
      ? List<LLMMessage>.of(messages)
      : messages.sublist(cut);

  // 被截掉的部分若含"已记账的清理"，保留记账（追溯不因截断丢失信息）
  return SendView(
    messages: kept,
    clearedRefs: clearedRefs,
    estTokens: estimateMessagesTokens(kept),
  );
}
