/// **模型能力画像**（2026-10-14，用户批评后重做）。
///
/// ## 为什么需要它（用户的两次批评）
///
/// 1. 「上下文长度是1M就是1M，**不用自己选的**」
/// 2. 「你确定你查的是对的？我记得 deepseek-flash 是支持 1M 的，
///    还有 kimi k3 也是 1M，结果呢？」
///
/// **两次都对。** 第一版我让用户手填（把架构问题推给用户），
/// 第二版我用了一张"凭印象编的"内置表 —— 25 个模型里 2 个错：
///
/// | 模型 | 我编的 | 服务端真实值 |
/// |---|---|---|
/// | `deepseek-flash` | 128K ❌ | **1,000,000** |
/// | `kimi-k3` | 256K ❌ | **1,048,576** |
///
/// ## 唯一可靠的来源：问服务端
///
/// 中转站的模型名是**它自己起的别名**（`deepseek-flash` 不等于官方
/// `deepseek-chat`），同一个名字在不同中转站的能力**可能不同**。
/// 所以任何"内置表"都只是猜 —— 必须问服务端。
///
/// 实测（2026-10-14）：基元律动的公开 API `GET /api/models` 返回
/// **完整能力画像**（29 个模型），字段包括：
///
/// | 字段 | 用途 |
/// |---|---|
/// | `contextWindow` | **上下文长度**（本类的主目标）|
/// | `maxOutputTokens` | 输出预算上限 |
/// | `supportsTools` | 能否用工具协议 |
/// | `supportsResponses` | **是否支持 OpenAI Responses 协议** |
/// | `supportsReasoning` / `reasoningMode` | 思考能力与模式 |
/// | `supportsVision` / `modalities` | 多模态 |
/// | `inputPrice` / `outputPrice` | 成本 |
///
/// ## 设计原则：字段名宽容，来源不写死
///
/// 各家字段名不同（OpenAI 标准叫 `context_length`，基元律动叫
/// `contextWindow`）—— 所以[fromJson] **同时认多种写法**，
/// 而不是为某一家写死一条路径。
class ModelCapabilities {
  const ModelCapabilities({
    this.contextWindow,
    this.maxOutputTokens,
    this.supportsTools,
    this.supportsResponses,
    this.supportsReasoning,
    this.supportsVision,
    this.inputPrice,
    this.outputPrice,
    this.currency,
  });

  /// **上下文长度**（token）—— 服务端权威值。`null` = 服务端没报。
  final int? contextWindow;

  /// 单次输出上限（token）—— 服务端权威值。
  final int? maxOutputTokens;

  final bool? supportsTools;
  final bool? supportsResponses;
  final bool? supportsReasoning;
  final bool? supportsVision;
  final double? inputPrice;
  final double? outputPrice;
  final String? currency;

  /// 是否读到了任何有用的东西（用于决定要不要存进映射表）。
  bool get hasAny =>
      contextWindow != null ||
      maxOutputTokens != null ||
      supportsTools != null;

  /// 从服务端返回的模型项解析。
  ///
  /// ## 字段名宽容（刻意）
  ///
  /// | 语义 | 认的写法 |
  /// |---|---|
  /// | 上下文长度 | `context_length`（OpenAI 标准）/ `contextWindow`（基元律动）/ `context_window` / `max_context_length` |
  /// | 输出上限 | `max_output_tokens` / `maxOutputTokens` / `max_completion_tokens` |
  ///
  /// 多认几种写法**没有代价**（都不认识时返回 null，由调用方兜底），
  /// 但少认一种就会退回"猜"—— 而那正是这次被用户抓到的问题。
  factory ModelCapabilities.fromJson(Map<dynamic, dynamic> j) {
    int? asInt(List<String> keys) {
      for (final k in keys) {
        final v = j[k];
        if (v is num && v > 0) return v.toInt();
      }
      return null;
    }

    bool? asBool(List<String> keys) {
      for (final k in keys) {
        final v = j[k];
        if (v is bool) return v;
      }
      return null;
    }

    double? asDouble(String k) {
      final v = j[k];
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    return ModelCapabilities(
      contextWindow: asInt(const [
        'context_length', // OpenAI 标准 / OpenRouter
        'contextWindow', // 基元律动
        'context_window',
        'max_context_length',
        'maxContextTokens',
      ]),
      maxOutputTokens: asInt(const [
        'max_output_tokens',
        'maxOutputTokens',
        'max_completion_tokens',
        'maxOutputLength',
      ]),
      supportsTools: asBool(const ['supportsTools', 'supports_tools']),
      supportsResponses:
          asBool(const ['supportsResponses', 'supports_responses']),
      supportsReasoning:
          asBool(const ['supportsReasoning', 'supports_reasoning']),
      supportsVision: asBool(const ['supportsVision', 'supports_vision']),
      inputPrice: asDouble('inputPrice'),
      outputPrice: asDouble('outputPrice'),
      currency: j['currency'] as String?,
    );
  }
}
