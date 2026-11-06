/// **token 估算器（压缩流水线专用，纯函数）** —— 2026-11-06 抽出。
///
/// ## 为什么从 `WindowRatioCompressor` 里抽出来
///
/// 压缩流水线（`compaction/`）里的每一层都要量"这条消息多大"：
/// micro 判断值不值得清、SessionMemory 判断能省多少、摘要视图判断是否真的变小。
/// 如果它们反过来 import `window_ratio_compressor.dart`，就和压缩器形成
/// **循环 import**（压缩器又 import 流水线）。抽成独立的纯函数文件后：
///
/// · 流水线 → 估算器（单向）
/// · 压缩器 → 流水线 + 估算器（单向）
///
/// ## 口径（与旧实现**逐字节一致**，不许改）
///
/// - **CJK ≈ 1 字 / 1 token**（中文、日文假名、韩文、全角标点）；
/// - **ASCII ≈ 4 字符 / 1 token**（向上取整）；
/// - 图片、functionCall、工具结果/定义条目、未知消息的固定开销
///   全部来自 `ContractCompaction.estimated*`（数值一处改、处处生效）。
///
/// ⚠️ 这套估算与 provider 真值差 2.4~2.7 倍（真机实测），所以
/// **决策口径**必须是 `max(真值, 估算)` 与 `估算 × bias` 投影，
/// 单看估算会"永远到不了线"。见 `WindowRatioCompressor._decisionUsage`。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../contract/contract.dart';

/// 估算一段文本的 token（CJK 1 字/token，ASCII 4 字符/token）。
int estimateTextTokens(String text) {
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

/// 估算一组用户内容块（文本 + 图片）的 token。
int estimateContentPartsTokens(List<UserContentPart> parts) {
  var n = 0;
  for (final p in parts) {
    if (p is TextPart) n += estimateTextTokens(p.text);
    if (p is ImagePart) n += ContractCompaction.estimatedImageTokens;
  }
  return n;
}

/// 估算单条消息的 token。
int estimateMessageTokensOf(LLMMessage m) {
  return switch (m) {
    SystemMessage(:final content) => estimateTextTokens(content),
    // ⚠️ UserMessage 的字段是 `contents`（List<UserContentPart>），不是 `content`
    UserMessage(:final contents) => estimateContentPartsTokens(contents),
    ModelMessage(:final textOutput, :final functionCalls) =>
      estimateTextTokens(textOutput ?? '') +
          functionCalls.length * ContractCompaction.estimatedFunctionCallTokens,
    // ⚠️ FunctionExecutionResult.content 也是 List<UserContentPart>
    FunctionExecutionResultMessage(:final results) => results.fold<int>(
        0,
        (s, r) =>
            s +
            estimateContentPartsTokens(r.content) +
            ContractCompaction.estimatedToolResultOverheadTokens,
      ),
    _ => ContractCompaction.estimatedUnknownMessageTokens,
  };
}

/// 估算一串消息的 token 合计。
int estimateMessagesTokens(List<LLMMessage> messages) {
  var total = 0;
  for (final m in messages) {
    total += estimateMessageTokensOf(m);
  }
  return total;
}

/// **媒体块的体量代理（token）** —— base64 字符数 / 4。
///
/// ## 为什么它和 [estimateMessageTokensOf] 里的图片口径不一样
///
/// 两个问题不同：
/// · **总量估算**（图片 800 固定）问"这次请求大概多大" —— 图片 token 由像素
///   决定，与我们能看到的 base64 长度无关；按 base64 估会把大图算成十几万 token，
///   让压缩被无意义地频繁触发；
/// · **值不值得清**（本函数）问"这一块是不是大到该丢" —— 这里 base64 长度
///   是个**单调**的体量信号（图越大 base64 越长），拿它跟
///   `ContractCompaction.maxMediaBlockTokens` 比是合理的近似，而且**只会高估**
///   （不会把该清的漏掉）。
///
/// 结论：本函数**不参与**总量估算，只服务 `MicroCompactor` 的媒体清理判断。
int estimateMediaBlockTokens(int base64Chars) {
  if (base64Chars <= 0) return 0;
  return (base64Chars / 4).ceil();
}

/// 截断文本到 [max] 字符（超限加省略号；不改内容语义）。
String clipText(String text, int max) {
  if (max <= 0) return '';
  if (text.length <= max) return text;
  return '${text.substring(0, max)}…';
}

/// 把一段文本压成单行（摘要/占位用，去掉换行与控制空白）。
String flattenText(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

bool _isCjk(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0x3040 && r <= 0x30FF) ||
    (r >= 0xAC00 && r <= 0xD7AF) ||
    (r >= 0x3000 && r <= 0x303F) ||
    (r >= 0xFF00 && r <= 0xFFEF);
