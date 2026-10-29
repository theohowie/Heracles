/// **JEV 决策引擎的数据模型**（2026-10-27 用户定）。
///
/// ## 这是什么
///
/// 「决策模型」（System One Models）是 2026 年 9 月 Jev（TypeSafe AI）
/// 带火的新品类：不生成文字，只对一个状态回答类型化问题
/// （是非 `noul` / 选择 `choice` / 打分 `score`），一次前向给出
/// **校准过的概率**。Heracles 的决策模式只用是非题：把用户的问题
/// 原文作状态、问「是否推荐这样做」，概率 ≥ 0.5 亮绿灯「推荐」，
/// 否则红灯「不推荐」。
///
/// ## 三个来源（用户定）
///
/// · **云端** —— 任意 `/v1/systemone` 兼容服务（Jev 官方、
///   StartLux 云端、自建 startlux-decide），配置里填地址与密钥；
/// · **本地 0.8B / 本地 2B** —— 国产开源 **StartLux-Decision**
///   （原点星辉，GGUF 权重，接口与 Jev 兼容、公开评测反超 Jev）。
///   Jev 本尊闭源、没有权重可下载，能下到手机上的就是这一家。
///
/// ⚠️ 权重许可为 **CC BY-NC 4.0**（非商业可用、商用需另行授权）——
/// App 不随包分发权重、只提供下载入口，界面上如实标注。
library;

/// 决策来源。**持久化用 `name`，只许往后加、不许改名/重排**
/// （与全仓枚举落盘铁律一致）。
enum JevSource {
  cloud('云端'),
  local08('本地 0.8B'),
  local2b('本地 2B');

  const JevSource(this.label);
  final String label;

  /// 顶栏状态行的短标签（宽度有限）。
  String get shortLabel => switch (this) {
    JevSource.cloud => '云端',
    JevSource.local08 => '本地 0.8B',
    JevSource.local2b => '本地 2B',
  };

  static JevSource parse(String? name) =>
      values.firstWhere((e) => e.name == name, orElse: () => JevSource.cloud);
}

/// 理由的来源 —— 决策模型本身**不写文字理由**，界面必须如实区分。
enum JevReasonSource {
  /// 没有理由（只显示概率分布）。
  none(''),

  /// 云端 AutoThink 模型在不确定时生成的思考（`return_thought`）。
  modelThought('理由来自决策模型的思考'),

  /// 由当前对话模型补写的一两句。
  llm('理由由对话模型补写');

  const JevReasonSource(this.caption);
  final String caption;

  static JevReasonSource parse(String? name) => values.firstWhere(
    (e) => e.name == name,
    orElse: () => JevReasonSource.none,
  );
}

/// JEV 云端预置（2026-10-29，用户实际接入的平台 = 基元律动
/// Token Rhythm，其接口文档定版）：默认端点与固定模型 ID。
/// 用户在配置页只需粘贴平台密钥（sk_ 开头）即可用；端点与
/// 模型仍可改（自建/其它兼容服务）。
const String kJevDefaultBaseUrl = 'https://tokenrhythm.studio/v1/decision';
const String kJevDefaultModel = 'NeoHorse-Jev-4B';

/// JEV 配置（落盘 SharedPreferences；**API 密钥不进这里**，
/// 走 SecureKeyStore，见 jev_service.dart）。
class JevConfig {
  const JevConfig({
    this.source = JevSource.cloud,
    this.cloudBaseUrl = kJevDefaultBaseUrl,
    this.cloudModel = kJevDefaultModel,
    this.reasonEnabled = true,
  });

  final JevSource source;

  /// 云端接口地址（预置基元律动推荐端点 `/v1/decision`；
  /// 也可填到 `/v1`，客户端会补 `/decision`）。
  final String cloudBaseUrl;

  /// 云端模型名（基元律动平台固定 `NeoHorse-Jev-4B`）。
  final String cloudModel;

  /// 决策出来后是否让对话模型补写理由。
  final bool reasonEnabled;

  bool get cloudReady => cloudBaseUrl.trim().isNotEmpty;

  JevConfig copyWith({
    JevSource? source,
    String? cloudBaseUrl,
    String? cloudModel,
    bool? reasonEnabled,
  }) => JevConfig(
    source: source ?? this.source,
    cloudBaseUrl: cloudBaseUrl ?? this.cloudBaseUrl,
    cloudModel: cloudModel ?? this.cloudModel,
    reasonEnabled: reasonEnabled ?? this.reasonEnabled,
  );

  Map<String, Object?> toJson() => {
    'source': source.name,
    'cloudBaseUrl': cloudBaseUrl,
    'cloudModel': cloudModel,
    'reasonEnabled': reasonEnabled,
  };

  factory JevConfig.fromJson(Map<String, dynamic> j) => JevConfig(
    source: JevSource.parse(j['source'] as String?),
    // 存量空值（预置上线前保存过空配置）回落到预置端点/模型，
    // 免得老用户卡在「有配置但地址是空的」。真正停用云端靠
    // 清空密钥（decide 时会拦），不靠清空地址。
    cloudBaseUrl: _orDefault(j['cloudBaseUrl'] as String?, kJevDefaultBaseUrl),
    cloudModel: _orDefault(j['cloudModel'] as String?, kJevDefaultModel),
    reasonEnabled: j['reasonEnabled'] as bool? ?? true,
  );

  static String _orDefault(String? v, String fallback) =>
      (v == null || v.trim().isEmpty) ? fallback : v;
}

/// 一条决策记录（问答历史落盘用）。
class JevDecision {
  const JevDecision({
    required this.id,
    required this.question,
    required this.yesProb,
    required this.engineLabel,
    required this.elapsedMs,
    required this.createdAt,
    this.reason,
    this.reasonSource = JevReasonSource.none,
  });

  final String id;

  /// 用户的原始问题。
  final String question;

  /// 决策模型给出的「是」的概率（0–1）。
  final double yesProb;

  /// 出结论的引擎（如 `本地 2B` / `云端 · 27B AutoThink`）。
  final String engineLabel;

  /// 决策耗时（毫秒，不含理由生成）。
  final int elapsedMs;

  final DateTime createdAt;

  /// 理由文本（可空 —— 决策模型不产文字，理由是可选的补写）。
  final String? reason;
  final JevReasonSource reasonSource;

  bool get recommended => yesProb >= 0.5;

  /// 置信度 = 指向结论那一侧的概率。
  double get confidence => recommended ? yesProb : 1 - yesProb;

  Map<String, Object?> toJson() => {
    'id': id,
    'question': question,
    'yesProb': yesProb,
    'engineLabel': engineLabel,
    'elapsedMs': elapsedMs,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'reason': reason,
    'reasonSource': reasonSource.name,
  };

  factory JevDecision.fromJson(Map<String, dynamic> j) => JevDecision(
    id: j['id'] as String? ?? '',
    question: j['question'] as String? ?? '',
    yesProb: (j['yesProb'] as num?)?.toDouble() ?? 0,
    engineLabel: j['engineLabel'] as String? ?? '',
    elapsedMs: (j['elapsedMs'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (j['createdAt'] as num?)?.toInt() ?? 0,
    ),
    reason: j['reason'] as String?,
    reasonSource: JevReasonSource.parse(j['reasonSource'] as String?),
  );
}

/// 宿主回报的本机画像（`deviceProfile` 通道，见 agent_bridge.dart）。
class JevDeviceProfile {
  const JevDeviceProfile({
    required this.model,
    required this.totalRamMb,
    required this.freeStorageMb,
    required this.appFilesDir,
  });

  /// 机型（如 `23013RK75C` —— 营销名宿主拿不到，如实显示型号）。
  final String model;
  final int totalRamMb;
  final int freeStorageMb;

  /// App 私有目录 —— 本地模型文件存放根目录的锚点。
  final String appFilesDir;

  double get totalRamGb => totalRamMb / 1024;
  double get freeStorageGb => freeStorageMb / 1024;

  factory JevDeviceProfile.fromMap(Map<dynamic, dynamic> m) => JevDeviceProfile(
    model: m['model'] as String? ?? '未知机型',
    totalRamMb: (m['totalRamMb'] as num?)?.toInt() ?? 0,
    freeStorageMb: (m['freeStorageMb'] as num?)?.toInt() ?? 0,
    appFilesDir: m['appFilesDir'] as String? ?? '',
  );
}

/// 本机检测的推荐档位。
enum JevTier { local2b, local08, cloudOnly }

class JevRecommendation {
  const JevRecommendation({
    required this.tier,
    required this.headline,
    required this.detail,
  });

  final JevTier tier;

  /// 一句话结论（如「最优方案：本地 2B」）。
  final String headline;

  /// 依据说明（内存/存储数字与门槛）。
  final String detail;

  JevSource? get source => switch (tier) {
    JevTier.local2b => JevSource.local2b,
    JevTier.local08 => JevSource.local08,
    JevTier.cloudOnly => null,
  };
}

/// **本机选型规则**（2026-10-27 定，数字来自权重实测大小）：
///
/// · 2B Q8_0 权重 2.01 GB，运行时（权重＋KV＋开销）约需 3 GB ——
///   内存 ≥ 6 GB 且可用存储 ≥ 3.2 GB 才推 2B；
/// · 0.8B Q4_K_M 权重 0.53 GB，运行时约 1 GB —— 内存 ≥ 3.5 GB
///   （4 GB 机型系统上报常为 3.6–3.8 GB）且存储 ≥ 1.2 GB 推 0.8B；
/// · 都不满足 → 本地不支持，走云端。
JevRecommendation recommendJev(JevDeviceProfile p) {
  final ramGb = p.totalRamGb;
  final freeGb = p.freeStorageGb;
  if (p.totalRamMb >= 6144 && p.freeStorageMb >= 3277) {
    return JevRecommendation(
      tier: JevTier.local2b,
      headline: '最优方案：本地 2B',
      detail:
          '运行内存 ${ramGb.toStringAsFixed(0)} GB、可用存储 '
          '${freeGb.toStringAsFixed(0)} GB，都够 2B（Q8 权重 2.0 GB）；'
          '决策质量明显好于 0.8B。',
    );
  }
  if (p.totalRamMb >= 3584 && p.freeStorageMb >= 1229) {
    return JevRecommendation(
      tier: JevTier.local08,
      headline: '最优方案：本地 0.8B',
      detail:
          '运行内存 ${ramGb.toStringAsFixed(1)} GB 跑不动 2B，'
          '但够 0.8B（Q4 权重约 0.5 GB）；要更强的决策可以走云端。',
    );
  }
  return JevRecommendation(
    tier: JevTier.cloudOnly,
    headline: '本机不支持本地模型，建议云端',
    detail:
        '运行内存 ${ramGb.toStringAsFixed(1)} GB 或可用存储 '
        '${freeGb.toStringAsFixed(1)} GB 不足（本地最低 0.8B 需约 '
        '3.5 GB 内存与 1.2 GB 存储），云端不受本机配置限制。',
  );
}

/// 一个可下载的本地模型规格。
class JevModelSpec {
  const JevModelSpec({
    required this.source,
    required this.displayName,
    required this.quantLabel,
    required this.sizeLabel,
    required this.approxBytes,
    required this.ggufRepo,
    required this.ggufFile,
    required this.configRepo,
    required this.dirName,
  });

  final JevSource source;
  final String displayName;
  final String quantLabel;
  final String sizeLabel;
  final int approxBytes;

  /// GGUF 权重仓库与文件名（Hugging Face，已逐一核实存在）。
  final String ggufRepo;
  final String ggufFile;

  /// BF16 仓库 —— 本地引擎还需要它的 tokenizer 与
  /// `decision_config.json`（GGUF 本身不带读出配置）。
  final String configRepo;

  /// 在 `jev_models/` 下的子目录名。
  final String dirName;
}

/// 本地两档的下载规格（文件大小为 Hugging Face 仓库实测值）。
const kJevModelSpecs = <JevModelSpec>[
  JevModelSpec(
    source: JevSource.local08,
    displayName: 'StartLux-Decision 0.8B',
    quantLabel: 'Q4_K_M 量化',
    sizeLabel: '约 0.5 GB',
    approxBytes: 530000000,
    ggufRepo: 'startlux-models/StartLux-Decision-v1.1-0.8B-Instant-GGUF',
    ggufFile: 'StartLux-Decision-v1.1-0.8B-Instant-Q4_K_M.gguf',
    configRepo: 'startlux-models/StartLux-Decision-v1.1-0.8B-Instant',
    dirName: '0.8b',
  ),
  JevModelSpec(
    source: JevSource.local2b,
    displayName: 'StartLux-Decision 2B',
    quantLabel: 'Q8_0 量化',
    sizeLabel: '2.0 GB',
    approxBytes: 2010000000,
    ggufRepo: 'startlux-models/StartLux-Decision-v1.1-2B-Instant-GGUF',
    ggufFile: 'StartLux-Decision-v1.1-2B-Instant-Q8_0.gguf',
    configRepo: 'startlux-models/StartLux-Decision-v1.1-2B-Instant',
    dirName: '2b',
  ),
];

JevModelSpec? jevSpecFor(JevSource source) {
  for (final s in kJevModelSpecs) {
    if (s.source == source) return s;
  }
  return null;
}
