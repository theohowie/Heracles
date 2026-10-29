/// 应用设置 —— **每一项都要真的起作用**，不是装饰。
///
/// 用户明确要求"我要的是功能，不是界面"。因此每个字段都必须
/// 有明确的**行为落点**，见各字段注释。
library;

/// 权限模式 —— 对应 `00-需求文档.md` §2.13.2 的三档。
///
/// **行为落点**：工具执行前的判定。危险操作是否需要用户确认。
enum PermissionMode {
  /// 手动审批：每个会修改状态的操作都要确认
  manual('手动审批', '每次修改都要你确认'),

  /// 自动审批：工作区内自动放行，越界仍要确认
  workspaceAuto('工作区内修改', '工作区内的改动自动执行，越界仍会询问'),

  /// 完全访问：不再询问
  ///
  /// **需要 Shizuku 或 root** —— 否则应用沙箱根本拿不到那些权限。
  fullAccess('完全访问', '不再询问。需要 Shizuku 或 root 才能真正生效');

  const PermissionMode(this.label, this.description);

  final String label;
  final String description;

  /// 该档位是否要求 Shizuku / root 才能成立
  bool get requiresElevation => this == PermissionMode.fullAccess;
}

/// 界面语言
enum AppLanguage {
  zh('中文'),
  en('English');

  const AppLanguage(this.label);
  final String label;
}

/// 外观
enum AppAppearance {
  light('浅色'),
  dark('深色'),
  system('跟随系统');

  const AppAppearance(this.label);
  final String label;
}

/// 主题风格（2026-10-24，用户拍板：外观页用主题选择代替强调色选择）。
///
/// 只改颜色与背景，不改布局结构。默认黑白；柔雾是 2026-10-23 定过的
/// 方向；极光、活力来自概念图里的两套配色。
enum AppThemeStyle {
  bw('黑白', '默认：只用黑、白、灰'),
  mist('柔雾', '奶油底 + 淡紫 + 薄荷'),
  aurora('极光', '深色底 + 紫青极光'),
  vitality('活力', '暖底 + 珊瑚橙');

  const AppThemeStyle(this.label, this.description);
  final String label;
  final String description;
}

/// 工作步骤展示详细度 —— 用户设置截图里的四档。
///
/// **行为落点**：工具调用卡片（`widgets/tool_call_card.dart`）的渲染密度，
/// 以及「模型原始输出」是否显示。直接影响一屏能看到多少信息。
///
/// ## 四档是**严格递增**的
///
/// | 档位 | 工具名+状态 | 参数 | 结果 | 模型原始输出 |
/// |---|---|---|---|---|
/// | 精简 | ✅ | ❌ | ❌ | ❌ |
/// | 标准 | ✅ | 摘要 | 摘要 | ❌ |
/// | 详细 | ✅ | 完整 | 完整 | ❌ |
/// | 完全展开 | ✅ | 完整 | 完整 | ✅ |
///
/// 用 [showArgs] / [fullResult] / [showRawOutput] 表达，**不要**在渲染处
/// 散落 `== StepDetail.xxx` 判断 —— 否则加档位时会漏改一处。
///
/// ## 枚举顺序不能改
///
/// 顺序 = 界面上从上到下的顺序（`_PickerRow` 直接遍历 `values`）。
/// 新档位只能**追加**在末尾。
///
/// ## 持久化兼容性
///
/// 按 `name` 存字符串，读回时 `SettingsController._enumOf` 有兜底：
/// 认不出的名字 → 回退到 `standard`。所以加档位**不会**让旧数据解析失败
/// （老版本读到 `fullyExpanded` 只是回退，不会崩）。
enum StepDetail {
  minimal('精简', '只显示工具名与状态'),
  standard('标准', '显示工具名、参数摘要与结果'),
  detailed('详细', '显示完整参数与完整结果'),
  fullyExpanded('完全展开', '显示模型原始输出与完整过程');

  const StepDetail(this.label, this.description);
  final String label;
  final String description;

  /// 是否显示参数（精简档只看"干了什么"，不看"用什么参数"）
  bool get showArgs => this != StepDetail.minimal;

  /// 是否显示**完整**（不截断）的参数与结果。
  ///
  /// 详细与完全展开都是完整 —— 后者的增量是模型原始输出，不是更长的正文。
  bool get fullResult =>
      this == StepDetail.detailed || this == StepDetail.fullyExpanded;

  /// 是否显示**模型原始输出**（`AgentEvent.ModelOutput` 的 `raw`）。
  ///
  /// 只有「完全展开」档位显示 —— 那是 JSON 原话，对日常使用是噪音，
  /// 排查问题时才是关键证据（`实测-05`：模型行为不可假设，只能观测）。
  bool get showRawOutput => this == StepDetail.fullyExpanded;

  /// 最简档：**只有工具名 + 状态**，连参数值都不给。
  ///
  /// 等价于 `!showArgs`，但单列一个 getter 是为了让卡片里的
  /// "精简档显示参数个数"那处判断读起来是意图而不是取反。
  bool get statusOnly => !showArgs;

  /// 参数/结果的**摘要**截断长度（非完整档用）。
  static const summaryChars = 80;
}

/// 智能体运行时的发送行为
///
/// **行为落点**：`InputBar` 在 busy 状态下按下发送时的处理。
enum BusySendBehavior {
  queue('排队发送', '等当前任务结束再发'),
  interrupt('立即中断并发送', '停止当前任务，改为执行新指令');

  const BusySendBehavior(this.label, this.description);
  final String label;
  final String description;
}

/// **推理等级**（2026-10-12，S4/S5）—— 与 Kotlin 侧 `ReasoningLevel` 五档对应。
///
/// ## 行为落点（**每一档都真的改变后端行为**，不是装饰）
///
/// | 档位 | 后端 | 效果 |
/// |---|---|---|
/// | [auto] | 本地 | **关思考**（与改造前完全一致，快） |
/// | [auto] | 云端 | 不下发 `reasoning_effort`，由服务端默认 |
/// | [off] | 两处 | 显式关思考 |
/// | [low] / [high] / [max] | 本地 | **只有开/关两态** —— 三档都映射成 `enable_thinking=true` |
/// | [low] / [high] / [max] | 云端 | `reasoning_effort` = `low`/`high`/`max` |
///
/// ⚠️ **平台差异必须如实告知**：本地 `llama-server` 只有一个开关，
/// `reasoning_effort` 被**静默忽略**（S1 实测）。所以本地选 Low 与 Max
/// 效果相同 —— UI 不能假装它们不同（`docs/25` §10.3）。
///
/// ## 为什么枚举顺序是 Auto → Off → Low → High → Max
///
/// = 界面上从上到下的顺序（`_PickerRow` 直接遍历 `values`）。
/// 用户已决策：**`Default` 改名 `Auto`**，五档、不做「WB CN」。
///
/// ## 持久化兼容性
///
/// 按 `name` 存字符串，读回时 `SettingsController` 有兜底（认不出 → `auto`）。
/// 所以**加档位不会让旧数据解析失败**。
enum ReasoningLevel {
  auto('Auto', '由模型自行决定'),
  off('Off', '不用思考，直接回答'),
  low('Low', '少量思考'),
  high('High', '较多思考'),
  max('Max', '尽可能深地思考');

  const ReasoningLevel(this.label, this.description);
  final String label;
  final String description;

  /// 跨进程（MethodChannel）用的字符串 —— **必须与 Kotlin 侧
  /// `ReasoningLevel.name.lowercase()` 逐字符一致**，否则静默回落到 AUTO。
  String get wire => name;

  /// 该档是否**要求模型进行思考**（本地映射成 `enable_thinking=true`）。
  ///
  /// `auto` 不算 —— 它的语义是"不表态"，由后端默认决定。
  bool get wantsThinking =>
      this == ReasoningLevel.low ||
      this == ReasoningLevel.high ||
      this == ReasoningLevel.max;

  /// 云端要下发的 `reasoning_effort`；`null` = 不下发该字段。
  ///
  /// ⚠️ 本地后端**必须**得到 `null` —— `llama-server` 会静默忽略它，
  /// 下发只会让"我们以为在分档"这种错觉留在代码里。
  String? get reasoningEffort => switch (this) {
        ReasoningLevel.low => 'low',
        ReasoningLevel.high => 'high',
        ReasoningLevel.max => 'max',
        _ => null,
      };

  static ReasoningLevel parse(String? raw) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return ReasoningLevel.auto;
  }
}

/// **最大轮次的可选档位**（2026-10-18，`docs/27` P0-1 / ADR-033）。
///
/// ## 为什么必须有这一档"自动"
///
/// `0` = **跟随当前后端**（本地 8 / 云端 40，Kotlin 侧 `Contract.Budget`）。
/// 这是**默认值** —— 与改造前"所有人都是 8 轮"相比，用户什么都不做时
/// 云端就能跑满 40 轮，正是这个缺陷（真机上云端也被卡在 8 轮）的修复。
///
/// ## 为什么上限只到 80
///
/// 轮次是**单次任务的成本上限**：每多一轮就是一次完整的
/// 请求（云端真金白银 + 更长的等待）。80 已经比云端默认 40 翻倍，
/// 再往上没有实际场景，只会让"手滑选错"的代价更大。
///
/// 定义在这里而不是 UI 里：Kotlin 侧 `Contract.Budget` 是数字的权威，
/// Dart 这份是**用户能选的档位**，两边都不该散落魔法数。
const List<int> kMaxTurnsOptions = [0, 8, 16, 40, 80];

/// 一个模型提供商的配置 —— FR-11。
///
/// **单个模型的能力快照**（2026-10-14，持久化用紧凑形态）。
///
/// ## 为什么要紧凑
///
/// 中转站一个 Key 下有 25+ 个模型，每个 8 个字段 —— 完整 JSON 会让
/// SharedPreferences 里的 provider 配置膨胀到几十 KB。
/// 这些字段的用途很固定（算上下文占用、决定输出预算），
/// 所以用短键名 + 只存真正要用的。
///
/// ## 数据来源
///
/// **服务端**（`/v1/models` 的 `context_length`，或中转站专有端点的
/// `contextWindow`）。**绝不内置猜测** —— 用户实测抓到我编的表错了 2/25。
class ModelCapability {
  const ModelCapability({
    required this.contextWindow,
    this.maxOutputTokens,
    this.supportsTools,
    this.supportsReasoning,
    this.reasoningLevelsEffective = false,
  });

  /// 上下文长度（token）—— 服务端权威值。`0` = 服务端未上报。
  final int contextWindow;

  /// 单次输出上限（token）—— 服务端权威值。
  final int? maxOutputTokens;

  final bool? supportsTools;
  final bool? supportsReasoning;

  /// 思考档位是否真生效（创建时按 provider 协议自动填，见
  /// [ProviderProtocol.reasoningLevelsEffective]）。旧数据没有
  /// 这个键 ⇒ 读回默认 false（宁可少显示，不假装有区别）。
  final bool reasoningLevelsEffective;

  bool get hasContext => contextWindow > 0;

  /// 紧凑序列化（见类注释说明）。
  Map<String, dynamic> toJson() => {
        'ctx': contextWindow,
        if (maxOutputTokens != null) 'maxOut': maxOutputTokens,
        if (supportsTools != null) 'tools': supportsTools,
        if (supportsReasoning != null) 'reason': supportsReasoning,
        if (reasoningLevelsEffective) 'rLv': true,
      };

  factory ModelCapability.fromJson(Map<String, dynamic> j) => ModelCapability(
        contextWindow: (j['ctx'] as num?)?.toInt() ?? 0,
        maxOutputTokens: (j['maxOut'] as num?)?.toInt(),
        supportsTools: j['tools'] as bool?,
        supportsReasoning: j['reason'] as bool?,
        reasoningLevelsEffective: j['rLv'] as bool? ?? false,
      );
}

/// **API Key 的安全存储哨兵**（2026-10-14，FR-11.7）。
/// ## 它解决什么
///
/// 用户原话：「下面的 API Key 还是明文存储，修复，这个测试也不能这样明文吧？」
/// —— Key 之前随 provider JSON 明文写进 SharedPreferences
/// （`/data/data/…/shared_prefs/FlutterSharedPreferences.xml`，
/// root 或 adb backup 可直接读出）。
///
/// ## 方案：分离存储
///
/// | 内容 | 存储 | 为什么 |
/// |---|---|---|
/// | provider 配置（URL/模型/目录…） | SharedPreferences | 非敏感，调试友好 |
/// | **apiKey** | flutter_secure_storage | 底层 Android Keystore，硬件级加密 |
///
/// SharedPreferences 里只留 [kSecureSentinel]：既标记"Key 在安全存储里"，
/// 又不泄漏任何内容，同时保住 `isConfigured`（`apiKey.isNotEmpty`）
/// 的语义 —— 用空串会让已配置的 provider 从模型列表里消失。
///
/// ## 常量放这里而不是 controller 里
///
/// [ModelProviderConfig.toJson] 需要它做**出口脱敏**，
/// 而 controller 依赖 models（反向依赖会形成循环 import）。
const String kSecureSentinel = '__secure__';

/// **API 协议**（2026-10-14，用户要求真实支持三协议，不假装）。
///
/// 三种都**真实实现**（有对应的 Kotlin provider 类）：
/// | 值 | Kotlin provider | 端点 |
/// |---|---|---|
/// | [openaiChat] | OpenAiCompatProvider | /v1/chat/completions |
/// | [anthropic] | AnthropicProvider | /v1/messages（x-api-key + version 头）|
/// | [openaiResponses] | OpenAiResponsesProvider | /v1/responses |
enum ProviderProtocol {
  openaiChat('OpenAI Chat Completions'),
  anthropic('Anthropic Messages'),
  openaiResponses('OpenAI Responses');

  const ProviderProtocol(this.label);
  final String label;

  /// 该协议下思考**档位**是否真生效（后端如实标注，2026-10-25）：
  /// 只有 OpenAI Chat 轨把 `reasoning_effort` 真正下发并生效；
  /// Anthropic / Responses 轨的 client 不读这个通道 —— 那两轨只有
  /// 开/关两态，前端据此只显示两态，不假装五档有区别。
  bool get reasoningLevelsEffective =>
      this == ProviderProtocol.openaiChat;

  static ProviderProtocol parse(String? s) => ProviderProtocol.values.firstWhere(
        (v) => v.name == s,
        orElse: () => ProviderProtocol.openaiChat,
      );

  /// AgentBridge 的 `backend` 参数值（Kotlin 侧按它分派 provider）
  String get wire => switch (this) {
        ProviderProtocol.openaiChat => 'cloud',
        ProviderProtocol.anthropic => 'anthropic',
        ProviderProtocol.openaiResponses => 'responses',
      };
}

/// **行为落点**：`ProviderManager` 的后端切换。
class ModelProviderConfig {
  const ModelProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
    this.enabled = false,
    this.isDefault = false,
    this.isOfficialAccount = false,
    this.modelCatalog = const [],
    this.protocol = ProviderProtocol.openaiChat,
    this.contextLength = 0,
    this.modelCapabilities = const {},
  });

  final String id;
  final String name;
  final String baseUrl;
  final String model;

  /// ⚠️ 演示态：真实实现必须走 **Android Keystore**（FR-11.7），
  /// 不得明文落盘。见 `09-决策记录.md` ADR-015。
  final String apiKey;

  /// 是否已配置好（有 Key）—— 未配置的不能选中
  final bool enabled;

  final bool isDefault;

  /// 「DeepSeek 账号」这类平台账号（与自建 Key 区分）
  final bool isOfficialAccount;

  /// **模型目录**（2026-10-14，接入第三方 API 服务）。
  ///
  /// 通过 `GET /v1/models` 拉取 + 用户手填的**可用模型清单**。
  ///
  /// ## 为什么是目录而不是单值
  ///
  /// 聚合服务（基元律动等）一个 Key 下有几十个模型 ——
  /// 目录让用户打勾常备几个，切换模型时**不用再拉**；
  /// 目录外 ID 仍可手填直发（参考图明确说明）。
  ///
  /// 持久化跟随 provider 一起存（`toJson`/`fromJson`）。
  final List<String> modelCatalog;

  /// **API 协议**（2026-10-14，用户要求真实支持三协议）。
  ///
  /// 参考图的下拉三项。决定 AgentBridge 用哪个 provider：
  /// | 值 | provider | 端点 |
  /// |---|---|---|
  /// | [ProviderProtocol.openaiChat] | OpenAiCompatProvider | /v1/chat/completions |
  /// | [ProviderProtocol.anthropic] | AnthropicProvider | /v1/messages |
  /// | [ProviderProtocol.openaiResponses] | OpenAiResponsesProvider | /v1/responses |
  final ProviderProtocol protocol;

  /// **上下文长度上限**（token，2026-10-14 用户反馈新增）。
  ///
  /// ## 为什么必须可配
  ///
  /// 用户实测：基元律动的 `deepseek-v4-flash-0731` 是 **1M 上下文**，
  /// 而 App 用了一个**猜的** 128K —— 后果不只是进度条失真：
  /// 压缩阈值（0.8）会按 128K 计算 → **过早压缩会话** →
  /// 丢掉真实上下文 + 损害缓存命中（铁律 1）。
  ///
  /// ## 为什么不让 App 自己猜
  ///
  /// 模型真实上限**只有服务端知道**（各家 4K~1M 不等，同一家不同模型也不同）。
  /// `GET /v1/models` **不保证**返回这个字段。所以：
  /// · 拉到就用（[AgentBridge.lastFetchedContextLength]）
  /// · 拉不到就让用户填 —— 猜一个数一定有错
  ///
  /// `0` = 未设置 → 回落到按后端类型的默认值
  ///（本地 4096 / 云端 128K）。
  final int contextLength;

  /// **模型能力缓存**（2026-10-14，第三版修复）。
  ///
  /// `模型 id → 能力`（上下文长度、输出上限、是否支持工具/思考…）。
  ///
  /// ## 为什么必须持久化（而不是放内存）
  ///
  /// 第二版把它放在 `AgentBridge` 的**内存字段**里 —— 后果：
  /// · App 重启 → 缓存丢失 → 上下文长度退回兜底值
  /// · 且只在用户点「获取可用模型」时才拉 → 不点就永远是兜底
  ///
  /// 用户实测截图显示的正是这个：`⚠️ 未从服务端获取，按保守值估算`。
  ///
  /// ## 为什么放在 provider 配置里
  ///
  /// 能力是**该 provider 下各模型**的属性，与 baseUrl 同生命周期 ——
  /// 换 provider 就该换一份能力表。
  final Map<String, ModelCapability> modelCapabilities;

  bool get isConfigured => apiKey.isNotEmpty;

  /// **当前模型的上下文窗口 —— 全 App 单一口径**（2026-10-29）。
  ///
  /// 此前有三处各算各的：后端帧用 [contextLength]（单值字段，
  /// 常为 0 → 掉进 128K 契约默认）、用量抽屉用 [modelCapabilities]
  /// 的逐模型值（1M）—— 同一会话里总数在 128K ↔ 1M 之间来回
  /// 跳（用户对图抓到）。现在统一走这里：
  ///
  /// 1. 逐模型能力（服务端上报，权威）[modelCapabilities]
  /// 2. provider 级 [contextLength]（拉目录/手填时写下的单值）
  /// 3. 都没有 → `0`（未知；调用方决定兜底，别处不许再自创口径）
  int get effectiveContextWindow {
    final cap = modelCapabilities[model]?.contextWindow ?? 0;
    if (cap > 0) return cap;
    if (contextLength > 0) return contextLength;
    return 0;
  }

  ModelProviderConfig copyWith({
    String? name,
    String? baseUrl,
    String? model,
    String? apiKey,
    bool? enabled,
    bool? isDefault,
    List<String>? modelCatalog,
    ProviderProtocol? protocol,
    int? contextLength,
    Map<String, ModelCapability>? modelCapabilities,
  }) =>
      ModelProviderConfig(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
        enabled: enabled ?? this.enabled,
        isDefault: isDefault ?? this.isDefault,
        isOfficialAccount: isOfficialAccount,
        modelCatalog: modelCatalog ?? this.modelCatalog,
        protocol: protocol ?? this.protocol,
        contextLength: contextLength ?? this.contextLength,
        modelCapabilities: modelCapabilities ?? this.modelCapabilities,
      );

  /// 序列化（持久化用）
  ///
  /// ## ★ apiKey 一律写成哨兵（2026-10-14，FR-11.7 的关键保险）
  ///
  /// 真 Key 只存在 `flutter_secure_storage`（Android Keystore）。
  /// **出口处强制脱敏** —— 因为序列化有多个调用点
  /// （updateProvider / addProvider / setProviderModel …），
  /// 靠"每个调用点记得先替换"迟早会漏一处，那就是明文落盘。
  ///
  /// 放在唯一的 toJson 出口 = **结构性保证**，不依赖调用者纪律。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        // ★ 绝不明文落盘：有 Key 就写哨兵，没 Key 就空串
        'apiKey': apiKey.isEmpty ? '' : kSecureSentinel,
        'enabled': enabled,
        'isDefault': isDefault,
        'isOfficialAccount': isOfficialAccount,
        'modelCatalog': modelCatalog,
        'protocol': protocol.name,
        'contextLength': contextLength,
        'modelCapabilities': {
          for (final e in modelCapabilities.entries) e.key: e.value.toJson(),
        },
      };

  factory ModelProviderConfig.fromJson(Map<String, dynamic> j) => ModelProviderConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        baseUrl: j['baseUrl'] as String? ?? '',
        model: j['model'] as String? ?? '',
        apiKey: j['apiKey'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? false,
        isDefault: j['isDefault'] as bool? ?? false,
        isOfficialAccount: j['isOfficialAccount'] as bool? ?? false,
        protocol: ProviderProtocol.parse(j['protocol'] as String?),
        contextLength: (j['contextLength'] as num?)?.toInt() ?? 0,
        modelCapabilities: (j['modelCapabilities'] as Map?)?.map(
              (k, v) => MapEntry(
                k as String,
                ModelCapability.fromJson(
                    (v as Map).cast<String, dynamic>()),
              ),
            ) ??
            const {},
        modelCatalog: (j['modelCatalog'] as List?)
                ?.whereType<String>()
                .toList() ??
            const [],
      );
}

/// 强调色预设（对应参考图的色板）
class AccentPreset {
  const AccentPreset(this.name, this.hex);
  final String name;
  final int hex;
}

const kAccentPresets = <AccentPreset>[
  AccentPreset('橙', 0xFFFF7A45),
  AccentPreset('蓝', 0xFF3B82F6),
  AccentPreset('绿', 0xFF22C55E),
  AccentPreset('青', 0xFF06B6D4),
  AccentPreset('紫', 0xFF8B5CF6),
  AccentPreset('粉', 0xFFEC4899),
  AccentPreset('红', 0xFFEF4444),
  AccentPreset('黄', 0xFFEAB308),
];

/// 全部设置。
class AppSettings {
  const AppSettings({
    this.permission = PermissionMode.workspaceAuto,
    this.language = AppLanguage.zh,
    this.appearance = AppAppearance.system,
    this.themeStyle = AppThemeStyle.bw,
    this.fontSize = 15,
    this.stepDetail = StepDetail.standard,
    this.reasoningLevel = ReasoningLevel.auto,
    this.busySend = BusySendBehavior.queue,
    this.accentHex = 0xFFFF7A45,
    this.glassEffect = true,
    this.maxTurns = 0,
    this.memoryGlobalEnabled = true,
    this.memoryPooling = false,
    this.providers = defaultProviders,
    this.activeProviderId,
  });

  final PermissionMode permission;
  final AppLanguage language;
  final AppAppearance appearance;

  /// 主题风格（颜色与背景；默认黑白）
  final AppThemeStyle themeStyle;

  /// 会话内容字号（12–20）
  final double fontSize;

  final StepDetail stepDetail;

  /// **推理等级**（2026-10-12，S4/S5）—— 输入框上方那个开关的值。
  ///
  /// 默认 [ReasoningLevel.auto]：**与改造前行为完全一致**
  /// （本地 auto = `enable_thinking=false`，不改变任何现有用户的时间与成本）。
  /// 打开思考**必须**是用户的显式动作 —— 见 `docs/25` §10.2。
  final ReasoningLevel reasoningLevel;

  final BusySendBehavior busySend;
  final int accentHex;
  final bool glassEffect;

  /// **单次任务的最大轮次**（2026-10-18，`docs/27` P0-1 / ADR-033）。
  ///
  /// ## 修的是什么
  ///
  /// 最大轮次此前**硬编码 8**（`AgentLoop.kt` + `AgentBridge.kt`），
  /// `MainActivity` 从不接收这个参数 —— 于是**云端模型也只在 8 轮内跑**，
  /// 一个需要十几步的构建任务会被无理由截断。
  ///
  /// ## 取值
  ///
  /// `0` = **自动跟随当前后端**（本地 8 / 云端 40，Kotlin `Contract.Budget`）。
  /// 其余值来自 [kMaxTurnsOptions]。
  ///
  /// ## 为什么用 int 而不是 enum
  ///
  /// 它跨进程传给 Kotlin 时**就是一个数字**（`maxTurns`），
  /// 用 enum 还要多一层 `wire` 映射；而档位集合由 [kMaxTurnsOptions] 钉住，
  /// 不需要枚举的类型安全。读回时的**容错**（脏值 → 0）在
  /// `SettingsController` 里做。
  final int maxTurns;

  /// **全局记忆开关**（2026-10-29，三作用域重设计；默认 `true`）。
  ///
  /// 关掉 ⇒ 宿主**不读** global 段（也不注入），但**数据保留**
  /// （Kotlin/存储层不需要知道这个开关 —— 存储与注入解耦）。
  /// 键名 `memoryGlobalEnabled`（INTERFACE §N12.9）。
  final bool memoryGlobalEnabled;

  /// **记忆解析池化**（2026-10-29；默认 `false`）。
  ///
  /// 开池化时只缓存**解析结果**（不缓存写事务），实例 key 必须是
  /// `(scope, scopeId)` 二元组并在每次取用前重新校验（防串台）。
  /// 默认关 = 与旧行为一致；当前 P1-①c-2 只落设置项，池化实现留给后续
  /// （开启也不会改变行为，如实记账）。
  final bool memoryPooling;

  final List<ModelProviderConfig> providers;

  ModelProviderConfig? get defaultProvider {
    for (final p in providers) {
      if (p.isDefault) return p;
    }
    return null;
  }

  /// **判断一个提供商是不是"自建/本地"后端**（2026-10-14 修复）。
  ///
  /// ## 为什么这条判定必须修
  ///
  /// 用户实测：把 Base URL 配成 `http://192.168.1.10:8090/v1`
  /// （**局域网里的 llama.cpp**）—— 旧实现只认 `127.0.0.1` 与
  /// `localhost`，于是被判成 **cloud**，请求里**不带**
  /// `chat_template_kwargs.enable_thinking=false`。
  ///
  /// 后果不是"慢一点"，而是**完全不可用**（`docs/25` §12.1 实测）：
  /// Qwen3.5 的思考会把 `max_tokens` 全部吃光 → `content` 为空
  /// → 解析失败 → 重试 → 再吃光 → **死循环 4 轮，每轮 100+ 秒**，
  /// 界面上一串「输出无法解析：不是合法 JSON / 输出为空」。
  ///
  /// ## 判据（按可靠性排序）
  ///
  /// 1. 回环地址
  /// 2. **私有网段 IP**（RFC1918 + link-local）—— 局域网自建后端的
  ///    典型形态；不能只认回环，否则"电脑上的 llama.cpp"永远命中不了
  ///
  /// ⚠️ 私有网段是**启发式**：公网域名/公网 IP 一律不算。
  ///
  /// ## 2026-10-18（ADR-035 S4）：它**不再是"后端类型"判据**
  ///
  /// ★ **语义已收窄**：本方法现在只回答"这个请求地址是不是回环/局域网"，
  /// 用于两个 UI 判定：**允许不填 Key**、自动选择时优先跳过没 Key 的云端。
  /// 它**不再等于"走哪个后端"** —— 自建端点今天同样走 `openaiChat` 云端分支。
  ///
  /// ## 2026-10-19：显式开关已删除
  ///
  /// 原来用户可以在设置页勾"自建 / 本地后端"，但本地后端删除后那个开关
  /// 只剩"我这条不要 Key"这一层含义，而它的说明文案（"按本地 llama.cpp
  /// 方式请求（关闭思考）"）已经是假话 ⇒ **开关与 `isSelfHosted` 字段一起删掉**。
  /// 局域网/回环仍由下面两条自动识别，不需要用户勾。
  static bool isLocalConfig(ModelProviderConfig p) {
    final url = p.baseUrl.toLowerCase();
    if (url.contains('127.0.0.1') || url.contains('localhost')) return true;
    if (url.contains('0.0.0.0')) return true;
    return _isPrivateHost(url);
  }

  /// 从 URL 里取 host，判断是否落在私有网段（RFC1918 + link-local）。
  ///
  /// 覆盖：
  /// - `10.x.x.x`
  /// - `172.16.x.x` – `172.31.x.x`
  /// - `192.168.x.x`
  /// - `169.254.x.x`（link-local，热点直连常见）
  static bool _isPrivateHost(String url) {
    final m = RegExp(r'^[a-z]+://([^/:]+)').firstMatch(url);
    final host = m?.group(1);
    if (host == null) return false;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final s in parts) {
      final v = int.tryParse(s);
      if (v == null || v < 0 || v > 255) return false;
      octets.add(v);
    }
    final a = octets[0], b = octets[1];
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  /// **用户主动选中的后端**（2026-10-12）——
  /// 输入框模型选择框点选后记录 id，`effectiveProvider` 优先返回它。
  ///
  /// null = 用户没选过 → 走原有自动选择顺序（新用户首次体验不变）。
  final String? activeProviderId;

  /// **运行时真正该用的后端**（2026-10-10 新增）。
  ///
  /// 为什么不直接用 [defaultProvider]：
  ///
  /// 实测踩到 —— 默认提供商曾是 `DeepSeek 账号`（需要 Key），
  /// 而首次安装时 Key 必然为空，于是每次运行都报
  /// 「无法连接 cloud 后端（apiKey 为空）」。
  /// **让新用户第一次运行就撞上"没有 Key"是最差的首次体验。**
  ///
  /// 选择顺序：
  /// 0. **用户主动选中的**（输入框模型选择框点选）—— 最高优先
  /// 1. 已配置的默认提供商（用户明确选过且填了 Key）
  /// 2. 任何**已配置**的非官方账号提供商
  /// 3. **本地模型**（手机上 llama-server 一起就能用，不需要 Key）
  /// 4. 兜底：默认提供商，或第一个
  ModelProviderConfig? get effectiveProvider {
    // 0. 用户主动选中的优先 —— 选中后不被自动逻辑覆盖
    if (activeProviderId != null) {
      for (final p in providers) {
        if (p.id == activeProviderId) return p;
      }
    }
    final d = defaultProvider;
    if (d != null && d.isConfigured) return d;

    for (final p in providers) {
      if (p.isConfigured && !p.isOfficialAccount) return p;
    }
    for (final p in providers) {
      if (isLocalConfig(p)) return p;
    }
    return d ?? (providers.isNotEmpty ? providers.first : null);
  }

  /// **至少有一个"真能发出去"的模型配置**（2026-10-19 首启引导）。
  ///
  /// 判据与 `AgentBridge` 发请求前的校验同源：
  /// `effectiveProvider` 存在 + `baseUrl` 非空 + 云端还要 `apiKey` 非空
  /// （回环/局域网端点允许不填 Key）。
  ///
  /// 为什么不在 UI 里各写一份：两处判据一旦漂移，会出现
  /// "界面说没配好、发送却成功"（或反之）这种最难解释的状态。
  bool get hasUsableProvider {
    final p = effectiveProvider;
    if (p == null) return false;
    if (p.baseUrl.trim().isEmpty) return false;
    if (!isLocalConfig(p) && p.apiKey.trim().isEmpty) return false;
    return true;
  }

  AppSettings copyWith({
    PermissionMode? permission,
    AppLanguage? language,
    AppAppearance? appearance,
    AppThemeStyle? themeStyle,
    double? fontSize,
    StepDetail? stepDetail,
    ReasoningLevel? reasoningLevel,
    BusySendBehavior? busySend,
    int? accentHex,
    bool? glassEffect,
    int? maxTurns,
    bool? memoryGlobalEnabled,
    bool? memoryPooling,
    List<ModelProviderConfig>? providers,
    String? activeProviderId,
  }) =>
      AppSettings(
        permission: permission ?? this.permission,
        language: language ?? this.language,
        appearance: appearance ?? this.appearance,
        themeStyle: themeStyle ?? this.themeStyle,
        fontSize: fontSize ?? this.fontSize,
        stepDetail: stepDetail ?? this.stepDetail,
        reasoningLevel: reasoningLevel ?? this.reasoningLevel,
        busySend: busySend ?? this.busySend,
        accentHex: accentHex ?? this.accentHex,
        glassEffect: glassEffect ?? this.glassEffect,
        maxTurns: maxTurns ?? this.maxTurns,
        memoryGlobalEnabled:
            memoryGlobalEnabled ?? this.memoryGlobalEnabled,
        memoryPooling: memoryPooling ?? this.memoryPooling,
        providers: providers ?? this.providers,
        // ★ 显式传 null = 清除选中（回自动选择）；不传 = 保持原值
        activeProviderId:
            activeProviderId ?? this.activeProviderId,
      );

  /// 默认提供商列表（对应参考图的模型页）
  static const defaultProviders = <ModelProviderConfig>[
    ModelProviderConfig(
      id: 'deepseek-account',
      name: 'DeepSeek 账号',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      isOfficialAccount: true,
    ),
    ModelProviderConfig(
      id: 'dashscope',
      name: '通义千问 (DashScope)',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      model: 'qwen3.8-flash',
    ),
    // ⚠️ 内置「本地模型 (llama.cpp)」preset 已于 2026-10-18 **删除**
    //   （`ADR-035` 彻底删除本地后端）。它原本承担"首次安装零配置可用"
    //   的角色，删掉之后**新用户必须先配一个云端 provider 的 Key** ——
    //   这个取舍是有意的：`AgentBridge` 的 provider 分派里本地分支已被
    //   `error(...)` 取代，留着 preset 只会让用户选中一个**必抛异常**的后端。
    //
    //   ⚠️ 遗留：`enabled` / `isDefault` 两个字段现在**没有任何 preset 用到**
    //   （本地那条是唯一的使用者）。字段本身保留（旧数据里可能还带着），
    //   但**不要再加新的内置 preset 去用它们**而不重新想清楚默认选谁。
  ];
}
