/// **阶段 1：MicroCompact（本地清理，零 API）** —— 2026-11-06。
///
/// ## 它做的事，只有两件
///
/// 1. **较旧的白名单工具输出** → 换成 `[Old tool result content cleared]`；
/// 2. **较旧的、体量超过阈值的图片/视频块** → 换成 `[media cleared]`。
///
/// ## 为什么"较旧"才有资格被清（这条是真机教训的落点，别改）
///
/// 2026-11-05 真机：micro **每轮**在 40% 线上清理历史中段的老工具输出 ⇒
/// 那个点之后的 token 前缀全部失效 ⇒ **缓存命中率只有 40%~48%**
/// （用户招牌指标是 80%+）。结论有两层：
///
/// · **时机**：micro 只能在**压缩事件发生时跑一次**（用户拍板 Q1），
///   不是每轮 —— 时机由 `WindowRatioCompressor.compress` 保证；
/// · **范围**：即使是压缩事件内，也只能动"较旧的"那些 ——
///   刚读进来的文件内容模型马上要用，清了等于让它重读一遍（白烧一轮）。
///
/// 所以有两个保护：
/// · **保护窗**：最近 `ContractCompaction.protectedRecentMessages` 条消息里的东西**一律不动**；
/// · **近期配额**：最近 [CompactionConfig.microKeepRecentToolResults] 条白名单工具结果不动。
///
/// ## 原始内容去哪了
///
/// **哪都没去，也没删**。本类是**纯函数**：读入消息列表，产出新的
/// `SendView`（占位符是副本），入参对象一个字段都不改。
/// 被清掉的内容用 `ClearedRef(id, originalChars)` 记账 ——
/// `id` 就是那次工具调用的 id，能顺着会话 `.jsonl` 把原文捞回来。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../contract/contract.dart';
import 'compaction_config.dart';
import 'send_view.dart';
import 'token_estimation.dart';

/// 一次 micro 清理的结果。
class MicroResult {
  const MicroResult({
    required this.view,
    required this.freedTokens,
    required this.clearedToolResults,
    required this.clearedMedia,
  });

  /// 清理后的发送视图（原始消息对象未被修改）。
  final SendView view;

  /// 估算口径省下的 token（可能为 0）。
  final int freedTokens;

  /// 清掉的工具结果条数。
  final int clearedToolResults;

  /// 清掉的媒体块个数。
  final int clearedMedia;

  /// 是否真的动过。
  bool get changed => clearedToolResults > 0 || clearedMedia > 0;
}

/// 微型压缩器（阶段 1）。
class MicroCompactor {
  const MicroCompactor({this.config = const CompactionConfig()});

  final CompactionConfig config;

  /// 对一条消息列表做一次清理，返回新的发送视图。
  ///
  /// **绝不修改** [messages] 里的任何对象，也不修改列表本身。
  MicroResult compact(List<LLMMessage> messages) {
    final protectedFrom = _protectedFrom(messages);
    final cleared = <String, ClearedRef>{};
    var freed = 0;
    var clearedTools = 0;
    var clearedMedia = 0;

    // ---- 第 1 遍：白名单工具结果（先定"哪些有资格"，再留最近 N 条）----
    //
    // 两步是必须的：资格判断（白名单 + 够长）与实际"最近 N 条"是两件事。
    // 先把有资格的列出来，最后 N 条保留、前面的清 —— 这样"最近 10 条工具结果"
    // 的口径与工具种类无关（不会因为中间夹了几个非白名单工具而数错）。
    final candidates = <_ToolCandidate>[];
    for (var i = 0; i < protectedFrom; i++) {
      final m = messages[i];
      if (m is! FunctionExecutionResultMessage) continue;
      for (var j = 0; j < m.results.length; j++) {
        final r = m.results[j];
        if (!config.isMicroToolWhitelisted(r.name)) continue;
        final text = _partsText(r.content);
        if (text.length < ContractCompaction.microMinChars) continue;
        candidates.add(_ToolCandidate(messageIndex: i, resultIndex: j));
      }
    }
    final clearable = candidates.length > config.microKeepRecentToolResults
        ? candidates.sublist(
            0, candidates.length - config.microKeepRecentToolResults)
        : const <_ToolCandidate>[];
    final clearToolSet = <String>{
      for (final c in clearable) '${c.messageIndex}:${c.resultIndex}',
    };

    // ---- 逐条消息重建（复制，不原地改）----
    final out = <LLMMessage>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final inProtectedWindow = i >= protectedFrom;

      if (m is FunctionExecutionResultMessage) {
        var touched = false;
        final results = <FunctionExecutionResult>[];
        for (var j = 0; j < m.results.length; j++) {
          final r = m.results[j];
          if (!clearToolSet.contains('$i:$j')) {
            results.add(r);
            continue;
          }
          final text = _partsText(r.content);
          final placeholder = ContractCompaction.clearedToolResultPlaceholder;
          final saved = estimateTextTokens(text) - estimateTextTokens(placeholder);
          // 理论上前面的 microMinChars 已经保证为正；这里再挡一次
          // （CJK/ASCII 混合时理论上仍可能为 0），绝不做"清了反而更大"的操作。
          if (saved <= 0) {
            results.add(r);
            continue;
          }
          freed += saved;
          clearedTools++;
          cleared[r.id] = ClearedRef(
            id: r.id,
            originalChars: text.length,
            kind: ClearedKind.toolResult,
          );
          results.add(FunctionExecutionResult(
            id: r.id,
            name: r.name,
            isError: r.isError,
            arguments: r.arguments,
            content: <UserContentPart>[TextPart(placeholder)],
            timestamp: r.timestamp,
          ));
          touched = true;
        }
        out.add(touched
            ? FunctionExecutionResultMessage(
                results: results,
                timestamp: m.timestamp,
              )
            : m);
        continue;
      }

      if (inProtectedWindow) {
        out.add(m);
        continue;
      }

      // ---- 媒体块：超阈值的旧图片/视频 ----
      if (m is ModelMessage) {
        final keptImages = <ModelImagePart>[];
        var mediaTouched = false;
        for (var k = 0; k < m.imageOutputs.length; k++) {
          final img = m.imageOutputs[k];
          if (estimateMediaBlockTokens(img.base64Data.length) >
              config.maxMediaBlockTokens) {
            freed += ContractCompaction.estimatedImageTokens;
            clearedMedia++;
            cleared[_mediaKey(i, k)] = ClearedRef(
              id: _mediaKey(i, k),
              originalChars: img.base64Data.length,
              kind: ClearedKind.media,
            );
            mediaTouched = true;
          } else {
            keptImages.add(img);
          }
        }
        final keptVideos = <ModelVideoPart>[];
        for (var k = 0; k < m.videoOutputs.length; k++) {
          final vid = m.videoOutputs[k];
          if (estimateMediaBlockTokens(vid.base64Data.length) >
              config.maxMediaBlockTokens) {
            freed += ContractCompaction.estimatedImageTokens;
            clearedMedia++;
            cleared[_mediaKey(i, m.imageOutputs.length + k)] = ClearedRef(
              id: _mediaKey(i, m.imageOutputs.length + k),
              originalChars: vid.base64Data.length,
              kind: ClearedKind.media,
            );
            mediaTouched = true;
          } else {
            keptVideos.add(vid);
          }
        }
        if (!mediaTouched) {
          out.add(m);
          continue;
        }
        out.add(ModelMessage(
          // ⚠️ 这里**只丢媒体块**，正文/思考/调用/用量/时间戳全部保留：
          //   模型已经说出来的话与它发起的调用是不能"被压缩"的（配对关系）。
          model: m.model,
          thought: m.thought,
          thoughtSignature: m.thoughtSignature,
          contentBlocks: m.contentBlocks,
          textOutput: m.textOutput == null
              ? ContractCompaction.clearedMediaPlaceholder
              : '${m.textOutput}\n${ContractCompaction.clearedMediaPlaceholder}',
          functionCalls: m.functionCalls,
          imageOutputs: keptImages,
          videoOutputs: keptVideos,
          audioOutputs: m.audioOutputs,
          usage: m.usage,
          metadata: m.metadata,
          stopReason: m.stopReason,
          responseId: m.responseId,
          timestamp: m.timestamp,
        ));
        continue;
      }

      if (m is UserMessage) {
        var mediaTouched = false;
        final parts = <UserContentPart>[];
        for (var k = 0; k < m.contents.length; k++) {
          final p = m.contents[k];
          final size = switch (p) {
            ImagePart(:final base64Data) => base64Data.length,
            VideoPart(:final base64Data) => base64Data.length,
            _ => -1,
          };
          if (size >= 0 && estimateMediaBlockTokens(size) > config.maxMediaBlockTokens) {
            freed += ContractCompaction.estimatedImageTokens;
            clearedMedia++;
            cleared[_mediaKey(i, k)] = ClearedRef(
              id: _mediaKey(i, k),
              originalChars: size,
              kind: ClearedKind.media,
            );
            parts.add(TextPart(ContractCompaction.clearedMediaPlaceholder));
            mediaTouched = true;
          } else {
            parts.add(p);
          }
        }
        out.add(mediaTouched
            ? UserMessage(parts, timestamp: m.timestamp, metadata: m.metadata)
            : m);
        continue;
      }

      out.add(m);
    }

    final view = SendView(
      messages: out,
      clearedRefs: cleared,
      estTokens: estimateMessagesTokens(out),
    );
    return MicroResult(
      view: view,
      freedTokens: freed,
      clearedToolResults: clearedTools,
      clearedMedia: clearedMedia,
    );
  }

  /// 保护窗起点（此前（不含）的消息才有资格被清）。
  ///
  /// 历史短于保护窗 ⇒ 返回 0 ⇒ **一条都不清**（"最近的东西"就是全部）。
  int _protectedFrom(List<LLMMessage> messages) {
    final from = messages.length - config.protectedRecentMessages;
    return from < 0 ? 0 : from;
  }

  /// 媒体块的合成键（媒体块没有 id）：`media:<消息序号>:<块序号>`。
  static String _mediaKey(int messageIndex, int partIndex) =>
      'media:$messageIndex:$partIndex';

  static String _partsText(List<UserContentPart> parts) {
    final buf = StringBuffer();
    for (final p in parts) {
      if (p is TextPart) buf.write(p.text);
    }
    return buf.toString();
  }
}

/// 一个"有资格被清"的工具结果的位置。
class _ToolCandidate {
  const _ToolCandidate({required this.messageIndex, required this.resultIndex});

  final int messageIndex;
  final int resultIndex;
}
