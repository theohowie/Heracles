/// **压缩流水线配置** —— 全部字段有默认值，默认值**唯一来源**是
/// `ContractCompaction`（`contract.dart`）。
///
/// ## 为什么要有这个类（而不是把参数一路往构造函数里塞）
///
/// 三个阶段 + 两个兜底层一共十几个旋钮（保留几条工具结果、媒体阈值、
/// 重载几个文件、记忆是否开…）。如果它们散成 `WindowRatioCompressor` 的
/// 命名参数，宿主（App/CLI）想"只改一个"就必须抄其余全部默认值 ——
/// 那就成了第二份真相。集中成一个值对象后：
///
/// · 宿主只传想改的那几项（`copyWith`）；
/// · 单测可以精确造出"只有媒体阈值不同"的场景；
/// · 契约测试只需盯 `ContractCompaction` 一处。
library;

import '../../contract/contract.dart';

/// 压缩流水线的旋钮集合（不可变）。
class CompactionConfig {
  const CompactionConfig({
    this.contextWindow = ContractCompaction.contextWindow,
    this.autoCompactThreshold = ContractCompaction.autoCompactThreshold,
    this.microKeepRecentToolResults =
        ContractCompaction.microKeepRecentToolResults,
    this.microToolWhitelist = ContractCompaction.microToolWhitelist,
    this.maxMediaBlockTokens = ContractCompaction.maxMediaBlockTokens,
    this.recentFilesMax = ContractCompaction.recentFilesMax,
    this.largeFileTokenThreshold = ContractCompaction.largeFileTokenThreshold,
    this.sessionMemoryEnabled = ContractCompaction.sessionMemoryEnabled,
    this.progressiveLayersEnabled = ContractCompaction.progressiveLayersEnabled,
    this.metricsEnabled = ContractCompaction.metricsEnabled,
    this.knownPromptTokens = 0,
  });

  /// 上下文窗口（token）。压缩线 = `contextWindow × autoCompactThreshold`。
  final int contextWindow;

  /// **唯一触发线**（0.85）。≥ 它才跑流水线；低于它**零副作用**。
  final double autoCompactThreshold;

  /// 保留最近多少条白名单工具结果不清（更旧的才清）。
  final int microKeepRecentToolResults;

  /// 可清理的工具名白名单（子串匹配）。
  final List<String> microToolWhitelist;

  /// 媒体块超过多少 token（体量代理）就清成 `[media cleared]`。
  final int maxMediaBlockTokens;

  /// 最近修改文件最多列几个。
  final int recentFilesMax;

  /// 文件估算超过多少 token 就只给路径（不给全文）。
  final int largeFileTokenThreshold;

  /// 是否启用阶段 2（Session Memory，零 API）。
  final bool sessionMemoryEnabled;

  /// 允许"未到线也跑 micro"的渐进开关（**默认关**，见契约 KDoc 的真机教训）。
  final bool progressiveLayersEnabled;

  /// 是否留存压缩事件（不影响压缩行为本身）。
  final bool metricsEnabled;

  /// **宿主带来的"上一次真实输入 token"**（0 = 不知道）。
  ///
  /// 为什么必须有：新一轮开始时框架的 `state.usages` 是**空的**，
  /// 压缩决策只能退回字符估算（实测低估 2.5~3.5 倍）⇒ 真机出现
  /// "上下文已经 122%、压缩却从不触发"。宿主把上次真值（持久化过）带进来，
  /// 决策才看得见现实。
  final int knownPromptTokens;

  /// 触发线（token）：`floor(contextWindow × autoCompactThreshold)`。
  int get autoCompactLine =>
      (contextWindow * autoCompactThreshold).floor();

  /// 保护窗条数 = 最近 `keepRecentTurns` 轮折算的消息条数。
  int get protectedRecentMessages => ContractCompaction.protectedRecentMessages;

  /// 只改其中几项（其余保持）。
  CompactionConfig copyWith({
    int? contextWindow,
    double? autoCompactThreshold,
    int? microKeepRecentToolResults,
    List<String>? microToolWhitelist,
    int? maxMediaBlockTokens,
    int? recentFilesMax,
    int? largeFileTokenThreshold,
    bool? sessionMemoryEnabled,
    bool? progressiveLayersEnabled,
    bool? metricsEnabled,
    int? knownPromptTokens,
  }) {
    return CompactionConfig(
      contextWindow: contextWindow ?? this.contextWindow,
      autoCompactThreshold:
          autoCompactThreshold ?? this.autoCompactThreshold,
      microKeepRecentToolResults:
          microKeepRecentToolResults ?? this.microKeepRecentToolResults,
      microToolWhitelist: microToolWhitelist ?? this.microToolWhitelist,
      maxMediaBlockTokens: maxMediaBlockTokens ?? this.maxMediaBlockTokens,
      recentFilesMax: recentFilesMax ?? this.recentFilesMax,
      largeFileTokenThreshold:
          largeFileTokenThreshold ?? this.largeFileTokenThreshold,
      sessionMemoryEnabled: sessionMemoryEnabled ?? this.sessionMemoryEnabled,
      progressiveLayersEnabled:
          progressiveLayersEnabled ?? this.progressiveLayersEnabled,
      metricsEnabled: metricsEnabled ?? this.metricsEnabled,
      knownPromptTokens: knownPromptTokens ?? this.knownPromptTokens,
    );
  }

  /// 工具名是否在白名单里（**子串**匹配，理由见契约 KDoc）。
  bool isMicroToolWhitelisted(String toolName) {
    final name = toolName.toLowerCase();
    for (final p in microToolWhitelist) {
      if (name.contains(p.toLowerCase())) return true;
    }
    return false;
  }
}
