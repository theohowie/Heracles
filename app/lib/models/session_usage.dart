/// 会话用量累计 —— `docs/24-用量与上下文展示.md` 的**一期**实现（数据已就绪的部分）。
///
/// ## 为什么单独一个文件
///
/// 累计逻辑有**三个容易写错的点**，集中在一处才守得住：
///
/// 1. `cachedTokens == null` **不是 0**（契约 `02-契约规范.md` §3.4）
/// 2. 分子分母必须来自**同一批**轮次（否则比率被稀释）
/// 3. 「切会话」要换的是**另一本账**，不是把同一本清零
///
/// ## ⚠️ 与 `docs/24` §4.1 的公式有一处**必要的偏离**
///
/// 该文写的是：
///
/// ```
/// 命中率 = Σ(已上报轮次的 cachedTokens) / Σ(已上报轮次的 promptTokens)   ← 会 >100%
/// ```
///
/// **这条是错的**，因为它把 `promptTokens` 当成了"总输入"。而 `:core` 的定义是
/// ## ★ 2026-10-23 口径修正（唯一现行口径）
///
/// > `promptTokens`：**整段输入**（含已命中部分 —— backend 已规范化）
/// > `hitRate = cachedTokens / promptTokens`
///
/// 旧式（`cached/(cached+prompt)`）来自 Kotlin 时代"`promptTokens`=仅未命中"
/// 的约定 —— 2026-10-23 起 promptTokens 语义变为整段后，旧式会把命中部分
/// **双重计入**（实测顶栏曾因此显示 ~50% 假低值，真机 98.3%）。
///
/// 所以这里按 **`:core`（权威）** 实现：
///
/// ```
/// 命中率 = Σcached / Σ(cached + prompt)     ← 仅统计已上报的轮次
/// ```
///
/// **这条偏离已在任务报告中明确说明**，不是静默改写。
library;

/// 一次会话（当前会话）的**累计**用量。
///
/// 不可变；用 [add] 叠加、[SessionUsage.empty] 作零元。这样累计过程是纯函数，
/// 好测（不必起 widget），也避免"边读边改"导致的半更新状态。
class SessionUsage {
  const SessionUsage({
    this.runs = 0,
    this.turns = 0,
    this.steps = 0,
    this.reportedTurns = 0,
    this.unreportedTurns = 0,
    this.cachedTokens = 0,
    this.reportedPromptTokens = 0,
    this.unreportedPromptTokens = 0,
    this.outputTokens = 0,
    this.wallMs = 0,
    this.taskWallMs = 0,
    this.steadyHitRate,
  });

  /// 零元 —— 新会话（或从未运行过的会话）就是它。
  static const empty = SessionUsage();

  /// 完成了几次运行（≈ 用户发了几条消息）
  final int runs;

  /// 总轮数（`AgentLoop` 的每一轮）
  final int turns;

  /// 工具调用步数（本轮请求了工具的次数，**含被拦截的**）
  final int steps;

  /// provider **上报了**缓存字段的轮数 —— [hitRate] 的分母基数
  final int reportedTurns;

  /// provider **未上报**的轮数 —— 这些轮的 `cachedTokens` 是 `null`
  final int unreportedTurns;

  /// Σ `cachedTokens`（**仅已上报轮次**）
  final int cachedTokens;

  /// Σ `promptTokens`（**仅已上报轮次**）—— 与 [cachedTokens] **配对**
  ///
  /// 必须只算已上报的轮次：若把未上报轮次的 prompt 也加进来，
  /// 命中率会被"没有缓存数据的输入"稀释，看起来像缓存变差了。
  final int reportedPromptTokens;

  /// Σ `promptTokens`（**仅未上报轮次**）—— 只用于展示"总输入量"
  final int unreportedPromptTokens;

  final int outputTokens;

  /// Σ **模型用时**（毫秒）—— 来自每轮的 `TurnRecord.wallMs`。
  ///
  /// ⚠️ 这个数**只含模型往返**（`provider.generate` / 流式收流），
  /// **不含工具执行、不含压缩、不含审批等待**（见 [taskWallMs]）。
  /// 用户曾把它当成"任务总耗时"质疑「才 5172ms 怎么可能」——
  /// 那个质疑是对的，所以 UI 必须把它标注成「模型用时（不含工具）」。
  final int wallMs;

  /// Σ **任务总耗时**（毫秒）—— 每次 run 从开始到结束的**真实墙钟**
  /// （含工具执行、审批/提问等待、上下文压缩）。
  ///
  /// ## 为什么要与 [wallMs] 分开（2026-10-21，BUG-5）
  ///
  /// 两者口径完全不同，却曾经被混成一个「耗时」：
  ///
  /// | 字段 | 来源 | 含什么 |
  /// |---|---|---|
  /// | [wallMs] | Σ `TurnRecord.wallMs` | **只有**模型往返 |
  /// | [taskWallMs] | Σ `AgentRunResult.taskWallMs` | 模型往返 + **工具执行** + 审批/提问等待 + 压缩 |
  ///
  /// 恒有 `taskWallMs >= wallMs`（前者是后者的超集）——
  /// 这条不变量由 `app/test/usage_metrics_test.dart` 钉住。
  ///
  /// `0` = 没有数据（旧版 Kotlin / 还没跑过）—— UI 显示 `—`，**不显示 0 秒**。
  final int taskWallMs;

  /// **最近一次运行**的稳态命中率（Kotlin `AgentRunResult.steadyHitRate`）。
  ///
  /// ## 为什么只保留"最近一次"而不是累加（2026-10-21，BUG-5）
  ///
  /// 它是**一次运行内**跳过首轮冷启动后的各轮命中率平均。
  /// 跨运行求平均需要每轮原始数据（这里只有聚合值），
  /// 硬凑会造出一个既不是加权也不是轮次平均的**第三种口径** —— 那是假信息。
  /// 所以如实只显示"最近一次 run"的稳态值，标签里写明「最近一次」。
  ///
  /// `null` = 没有数据（还没跑过 / 该 run 只有一轮，无稳态可言）。
  final double? steadyHitRate;

  /// 有没有"未上报"的轮次 —— UI 必须据此**标注**（`docs/24` §4.1）
  bool get hasUnreported => unreportedTurns > 0;

  /// 有没有任何可用的缓存数据。`false` 时 UI 显示「不可用」/「—」，
  /// **绝不可以显示 0%**（那会让人以为缓存坏了）。
  bool get hasCacheData => reportedTurns > 0;

  /// 总输入 token（**整段**，全部轮次）—— 展示"一共喂进去多少"。
  ///
  /// ## ★ 2026-10-23 修正：**不再把 cached 加一遍**
  ///
  /// 旧定义是 `cachedTokens + reportedPromptTokens + unreportedPromptTokens`，
  /// 前提是"`reportedPromptTokens` = 未命中部分"。但从 2026-10-23 起 backend
  /// 把 `promptTokens` **规范化成整段**（含命中），于是这个加法把命中的
  /// 16,128 算了两遍 ⇒ 侧栏显示 `Token 用量 33,157`，而真实只有 17,029。
  ///
  /// 用户正是**按侧栏这三个数自己算了一遍**才发现不对：
  /// 「未缓存输入 16690、缓存读取 16128 ⇒ 命中率 49%，怎么会显示 97%？」
  /// —— 他的算式没错，是**标签在撒谎**：那 16,690 是**整段输入**，
  /// 真正的未命中只有 `16,690 − 16,128 = 562`。
  ///
  /// 现在语义统一为：`promptTokens` = 整段（含缓存），`cachedTokens` ⊆ 它。
  int get totalInputTokens => reportedPromptTokens + unreportedPromptTokens;

  /// **未命中输入** = 整段输入 − 命中缓存。
  ///
  /// 这才是「未缓存输入」那个标签真正该显示的数（上面那 562）。
  /// 用 `clamp` 兜一下：若某家 provider 报了 `cached > prompt`（字段语义特殊），
  /// 宁可显示 0 也不要出负数 —— 负数会被读成"算错了"。
  int get uncachedInputTokens {
    final v = totalInputTokens - cachedTokens;
    return v > 0 ? v : 0;
  }

  /// **累计命中率**。`null` = 不可用（没有任何已上报的轮次）。
  ///
  /// 口径：`Σcached / Σprompt`（`prompt` = **整段**，含命中部分），
  /// 只统计已上报轮次。用**加权**（按 token 汇总）而不是"各轮命中率的平均"：
  /// 后者会让一个只有 10 token 的轮次与一个 5000 token 的轮次等权，
  /// 与用户对"整体省了多少"的直觉不符。
  ///
  /// ## ★ 2026-10-23 修正：分母**不再加一次 cached**
  ///
  /// 旧公式 `cached / (cached + prompt)` 是**重复计数** —— `prompt` 已经包含
  /// 命中的那部分。真机实测（设备 `e35e48c6`）：
  /// ```
  /// prompt_tokens: 5468, prompt_tokens_details: {cached_tokens: 5376}
  /// ```
  /// 真值 98.3%，旧公式 49.6% ⇒ 顶栏长期显示 ~50%，用户报"命中缓存率太低"。
  ///
  /// ⚠️ 前提：`reportedPromptTokens` 由 backend 规范化成**整段**
  /// （Anthropic 的 `input_tokens` 只含未命中部分，已在 `_fullPromptTokens` 加回）。
  double? get hitRate {
    if (!hasCacheData) return null;
    if (reportedPromptTokens <= 0) return null;
    return cachedTokens / reportedPromptTokens;
  }

  /// 输出速度（tok/s）—— 由 `Σoutput / ΣwallMs` 推出。
  ///
  /// `TurnRecord.wallMs` 量的是 `provider.generate` 的墙钟
  /// （`started` 在 generate 之前、`wallMs` 在 generate 之后计算），
  /// **不含**工具执行时间，所以这个速度是"模型出字速度"，语义正确。
  ///
  /// `null` = 没有可用的墙钟（避免除零得到 Infinity）。
  double? get outputTokensPerSecond {
    if (wallMs <= 0) return null;
    return outputTokens / (wallMs / 1000.0);
  }

  /// 只改 `runs`（其余保持不变）—— 供"逐轮累加后再记一次运行"。
  ///
  /// 为什么需要它：`ofTurn` 是**逐轮**的，它不知道"这次运行有几轮"；
  /// 而 `runs` 是**每次运行**加一。两者粒度不同，不能混在一个循环里。
  ///
  /// ## [taskWallMs] 为什么是**运行级**参数（2026-10-21，BUG-5）
  ///
  /// 任务总耗时只有 `AgentRunResult` 知道（一次 run 一个数），
  /// 而 `ofTurn` 是**逐轮**的 —— 拿不到它，也不该拿（逐轮分不到工具执行的时间）。
  /// 所以它跟着"一次运行 +1"的 [runs] 一起进账，而不是跟着轮次。
  ///
  /// 默认 `0` = 不累加（`ofTurn` 路径与既有调用方行为不变）。
  SessionUsage copyRuns(int r, {int taskWallMs = 0, double? steadyHitRate}) =>
      SessionUsage(
        runs: r,
        turns: turns,
        steps: steps,
        reportedTurns: reportedTurns,
        unreportedTurns: unreportedTurns,
        cachedTokens: cachedTokens,
        reportedPromptTokens: reportedPromptTokens,
        unreportedPromptTokens: unreportedPromptTokens,
        outputTokens: outputTokens,
        wallMs: wallMs,
        taskWallMs: this.taskWallMs + taskWallMs,
        // null = 这次没有新值 ⇒ **保持原值**（不是清空：切会话不该丢已知的稳态数）
        steadyHitRate: steadyHitRate ?? this.steadyHitRate,
      );

  /// 叠加另一次运行的统计。
  SessionUsage add(SessionUsage o) => SessionUsage(
        runs: runs + o.runs,
        turns: turns + o.turns,
        steps: steps + o.steps,
        reportedTurns: reportedTurns + o.reportedTurns,
        unreportedTurns: unreportedTurns + o.unreportedTurns,
        cachedTokens: cachedTokens + o.cachedTokens,
        reportedPromptTokens: reportedPromptTokens + o.reportedPromptTokens,
        unreportedPromptTokens:
            unreportedPromptTokens + o.unreportedPromptTokens,
        outputTokens: outputTokens + o.outputTokens,
        wallMs: wallMs + o.wallMs,
        taskWallMs: taskWallMs + o.taskWallMs,
        // 稳态命中率**不可相加**（它是比率）—— 取"有值的那一边"，
        // 两边都有值时以新叠加的 `o` 为准（它就是"最近一次 run"）。
        steadyHitRate: o.steadyHitRate ?? steadyHitRate,
      );

  /// 从**一轮**的原始指标构造（`cachedTokens == null` ⇒ 计入"未上报"）。
  ///
  /// 刻意收原始标量而不是 `AgentTurn`：避免 `models/` 依赖 `services/`
  /// （分层方向），调用方在 `agent_bridge.dart` 里做映射。
  factory SessionUsage.ofTurn({
    required int? cachedTokens,
    required int promptTokens,
    required int outputTokens,
    required int wallMs,
    bool requestedTool = false,
  }) {
    final unreported = cachedTokens == null;
    return SessionUsage(
      runs: 0,
      turns: 1,
      steps: requestedTool ? 1 : 0,
      reportedTurns: unreported ? 0 : 1,
      unreportedTurns: unreported ? 1 : 0,
      // 只有**已上报**的轮次才进命中率的分母/分子。
      //
      // ⚠️ 这里曾有两个错（2026-10-11 captain 修）：
      //   ① `cachedTokens ?? 0` —— 把"未上报"当成"命中 0"，
      //      会把命中率往下拉（实测 90% 被稀释成 25.7%）
      //   ② 未上报轮次的 `promptTokens` 混进 `reportedPromptTokens` ——
      //      稀释分母，同样拉低命中率
      //
      // 未上报轮次的数据记在 `unreportedPromptTokens`，
      // 只用于展示"总输入量"，**绝不参与命中率**（契约 §3.4）。
      cachedTokens: unreported ? 0 : cachedTokens,
      reportedPromptTokens: unreported ? 0 : promptTokens,
      unreportedPromptTokens: unreported ? promptTokens : 0,
      outputTokens: outputTokens,
      wallMs: wallMs,
    );
  }
}

/// **上下文窗口占用**（`docs/24` §2.3）。
///
/// ## 两个数的来源不同（必须如实说明）
///
/// | 分项 | 来源 | 精度 |
/// |---|---|---|
/// | 冻结区（系统提示词 + 工具定义） | Kotlin 侧 `AgentLoop.frozenPrefix.estimatedTokens` | **估算** |
/// | 对话消息 | Dart 侧对消息文本估算（与 `TextMath` 同系数） | **估算** |
///
/// 两者**都不是真实 tokenizer**，所以 UI 一律标 `~`
/// （`docs/24` §4.2；`TextMath` 曾 40% 高估，见 `docs/实测-08`）。
///
/// **不要把估算值当精确值展示** —— 会让用户以为能精确控制预算。
class ContextUsage {
  const ContextUsage({
    required this.frozenTokens,
    required this.conversationTokens,
    required this.limit,
    this.limitSource = '',
    this.breakdown,
  });

  /// 冻结区（系统提示词 + 工具定义）token —— 来自 Kotlin 侧估算
  final int frozenTokens;

  /// 对话消息 token —— Dart 侧估算
  final int conversationTokens;

  /// 上下文上限（**自动解析**：服务端上报 > 内置模型表 > 后端默认）
  final int limit;

  /// **上下文构成**（C5，2026-10-24）：system / tools / history 三块的
  /// **估算** token。null = 没有数据（还没跑过一次 run）—— 侧栏退回
  /// 两行旧图例（冻结区合计 / 对话），**不得显示 0**。
  final Map<String, int>? breakdown;

  /// 上限的**来源说明**（2026-10-14，诊断用）。
  ///
  /// 让用户知道这个数字**从哪来** —— 「服务端上报」/
  /// 「DeepSeek-V4 系列 1M」/「按后端默认值」。
  /// 上限算错会让压缩过早触发（丢上下文），所以来源必须可见。
  final String limitSource;

  int get used => frozenTokens + conversationTokens;

  /// 已用比例；`null` = 上限未知（不画进度条，而不是画个假的满格）
  double? get ratio {
    if (limit <= 0) return null;
    return used / limit;
  }

  /// 是否超出上限 —— 超了要明确示警，而不是把进度条画到 100% 就算完
  bool get overLimit => limit > 0 && used > limit;
}

/// 与 `:core` 的 `TextMath.estimateTokens` **同系数**的估算。
///
/// ## 为什么要在 Dart 里再实现一遍
///
/// 上下文分项里的"对话消息"长度只有 Dart 侧知道（就是屏幕上那些消息）。
/// 为它专门过一次 MethodChannel 不划算，而**系数必须与
/// `TextMath` 完全一致** —— 否则同一段文本在两个地方显示不同的 token 数，
/// 用户会认为其中一个是坏的。
///
/// 系数来源（`TextMath.kt` 的注释）：
/// - CJK ≈ 0.7 token / 字（Qwen 对中文压缩得比预期好）
/// - 其它 ≈ 1 token / 3.5 字符
///
/// ⚠️ **不可用于块对齐或计费** —— 只用于"粗判占用"（与 `TextMath` 的定位一致）。
int estimateTokens(String s) {
  var cjk = 0;
  var other = 0;
  for (final r in s.runes) {
    if (_isCjk(r)) {
      cjk++;
    } else {
      other++;
    }
  }
  // 与 Kotlin 的整数除法一致（都是向下取整）
  return (cjk * 7 ~/ 10) + (other * 2 + 6) ~/ 7;
}

bool _isCjk(int c) =>
    (c >= 0x4E00 && c <= 0x9FFF) || // CJK 统一表意
    (c >= 0x3400 && c <= 0x4DBF) || // 扩展 A
    (c >= 0x3000 && c <= 0x303F) || // CJK 标点
    (c >= 0xFF00 && c <= 0xFFEF); // 全角

/// 紧凑格式：`123` / `12.3K` / `1.2M`（参考图也是 `~516K` 这种写法）。
String formatTokensCompact(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

/// 精确格式，带千分位：`770,982,124`
String formatTokensFull(int n) {
  final s = n.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return n < 0 ? '-$buf' : buf.toString();
}
