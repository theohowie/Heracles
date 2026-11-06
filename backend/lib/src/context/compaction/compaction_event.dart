/// **CompactionEvent（压缩事件）** —— 一次压缩到底做了什么、花了什么、失败了什么。
///
/// ## 为什么事件要这么细（而不是只报"压缩了 40 条 → 12 条"）
///
/// 用户对压缩的核心诉求是"**别骗我**"：
/// · 压了没压？（[changed]）
/// · 哪几层真的动了手、哪几层被跳过？（[layersRun]）
/// · 这次有没有花 API 钱？（[usedApi] / [apiTokens] / [elapsedMs]）
/// · 失败了吗？失败原因是什么？（[failureReason]）
///
/// 只报前后规模的话，UI 无法区分"本地清了几条工具输出"与"模型摘要成功"，
/// 更无法解释"为什么这轮慢了 8 秒"（摘要调用是网络往返）。
///
/// ## 字段口径（别猜，都写死在这里）
///
/// | 字段 | 口径 |
/// |---|---|
/// | `beforeTokens` / `afterTokens` | **决策口径**（`max(服务端真值, 字符估算)`），与"要不要压"同一把尺 |
/// | `keptNotes` | 压缩后**保留的原文消息条数**（保护窗内没被摘要吞掉的那些） |
/// | `droppedNotes` | 本次事件**丢弃/被替换掉的旧消息条数** |
/// | `injectedBlocks` | 摘要视图里**显式注入的保留块**数（项目指令/用户约束/最近文件/摘要正文…） |
/// | `apiTokens` | 摘要调用的 prompt+completion token（provider 上报；没上报就是 0，不编） |
library;

import 'send_view.dart';

/// 触发原因。
enum CompactionTrigger {
  /// 占用 ≥ `autoCompactThreshold × 窗口`（自动触发，生产唯一路径）。
  threshold,

  /// 用户显式要求（`/compact` 命令 → `compactNow`）。
  manual,

  /// 渐进模式（`progressiveLayersEnabled`）：未到线也跑了 micro（**默认关**）。
  progressive,
}

/// 流水线上的层（按执行顺序排列）。
enum CompactionLayer {
  /// 阶段 1：本地清老工具输出/大媒体块（零 API）。
  micro,

  /// 阶段 2：用本地 Session Memory 渲染摘要视图（零 API）。
  sessionMemory,

  /// 阶段 3：API 结构化摘要（仅当记忆不可用或用户给了 focus）。
  apiSummary,

  /// 兜底 A：确定性强制重置（整批丢弃老轮次，不依赖任何模型）。
  forceReset,

  /// 兜底 B：90% 硬顶升级循环（继续压到物理下限，不许报错、不许停）。
  ceilingTrim,
}

/// 一次压缩的完整记录。
class CompactionEvent {
  const CompactionEvent({
    required this.trigger,
    required this.layersRun,
    required this.beforeTokens,
    required this.afterTokens,
    required this.elapsedMs,
    required this.usedApi,
    required this.keptNotes,
    required this.droppedNotes,
    this.failureReason,
    this.apiTokens = 0,
    this.injectedBlocks = 0,
    this.clearedRefs = const <String, ClearedRef>{},
  });

  /// 触发原因（阈值 / 手动 / 渐进）。
  final CompactionTrigger trigger;

  /// 真正跑过并**改动过历史**的层（按执行顺序；空 = 什么都没动）。
  final List<CompactionLayer> layersRun;

  /// 压缩前占用（决策口径）。
  final int beforeTokens;

  /// 压缩后占用（决策口径）。
  final int afterTokens;

  /// 整个流水线耗时（毫秒）。含摘要调用的网络往返。
  final int elapsedMs;

  /// 这次是否**真的调用过模型**（阶段 3 或兜底里的模型调用）。
  ///
  /// ⚠️ 语义是"发起了调用"，不是"调用成功" —— 失败也是一次真实请求，
  /// 费用照付，必须如实记账（[failureReason] 里会说失败原因）。
  final bool usedApi;

  /// 保留的原文消息条数（保护窗内）。
  final int keptNotes;

  /// 丢弃/替换掉的旧消息条数。
  final int droppedNotes;

  /// 失败原因（人话，**不含 URL / Key / 堆栈**；成功路径为 null）。
  final String? failureReason;

  /// 摘要调用消耗的 token（provider 上报；未上报 = 0）。
  final int apiTokens;

  /// 摘要视图里显式注入的保留块数量。
  final int injectedBlocks;

  /// 本次事件里被清掉的块（工具输出/媒体）的记账。
  final Map<String, ClearedRef> clearedRefs;

  /// 这次是否真的动了历史。
  bool get changed => layersRun.isNotEmpty;

  /// 省下的 token（决策口径；负数表示反而变大了 —— 那不该发生）。
  int get savedTokens => beforeTokens - afterTokens;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'trigger': trigger.name,
        'layers': [for (final l in layersRun) l.name],
        'beforeTokens': beforeTokens,
        'afterTokens': afterTokens,
        'savedTokens': savedTokens,
        'elapsedMs': elapsedMs,
        'usedApi': usedApi,
        'apiTokens': apiTokens,
        'keptNotes': keptNotes,
        'droppedNotes': droppedNotes,
        'injectedBlocks': injectedBlocks,
        if (failureReason != null) 'failureReason': failureReason,
        'clearedRefs': [for (final r in clearedRefs.values) r.toJson()],
      };

  @override
  String toString() => 'CompactionEvent(${trigger.name}: '
      '${layersRun.map((l) => l.name).join('→')}, '
      '$beforeTokens→$afterTokens, ${elapsedMs}ms, '
      'api=${usedApi ? apiTokens : 'no'}, '
      'kept=$keptNotes/dropped=$droppedNotes'
      '${failureReason == null ? '' : ', 失败=$failureReason'})';
}
