/// 消息模型 —— UI 侧的数据结构。
///
/// **对应 Kotlin 侧的 `Turn`**，但只保留展示所需的字段。
/// 上下文的唯一来源是 Kotlin 侧（铁律 1），UI 只消费不构造。
library;

/// 后端类型 —— 与 Kotlin 侧 `ProviderKind` 对应。
enum BackendKind {
  /// 本地模型：开发测试用
  local,

  /// 云端 API：发行版主用法
  cloud,
}

/// 一轮对话中的消息。
sealed class HMessage {
  const HMessage();

  String get id;
}

/// 用户输入
class HUserMessage extends HMessage {
  const HUserMessage({required this.id, required this.text});

  @override
  final String id;
  final String text;
}

/// 助手最终回答
class HAssistantMessage extends HMessage {
  const HAssistantMessage({
    required this.id,
    required this.text,
    this.changes,
  });

  @override
  final String id;
  final String text;

  /// **变更报告**（2026-10-22，用户指正位置：总结正文**下面**、
  /// 复制/点赞操作行**上面**）。
  ///
  /// 之前做成独立一条 `HChanges` 消息 ⇒ 它排在助手消息**之前**
  /// （事件顺序上 `changes` 比 run 返回的 finalText 早到），
  /// 用户原话：「你这个变更报告位置放错了，放到总结的下面去，在复制按钮的上面」。
  /// ⇒ 改为**挂在助手消息上**，与操作行一起属于同一条回答的收尾区。
  final List<HChangeFile>? changes;
}

/// 一次改动的单个文件（变更报告卡片的一行）。
class HChangeFile {
  const HChangeFile({
    required this.path,
    required this.added,
    required this.removed,
  });

  /// **相对工作区**的路径（工具参数本来就是相对路径）。
  final String path;
  final int added;
  final int removed;

  Map<String, dynamic> toMap() =>
      <String, dynamic>{'path': path, 'added': added, 'removed': removed};

  /// 容错解析（`.jsonl` 是长期数据，字段坏了不能崩整条会话）。
  static HChangeFile? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final path = (raw['path'] as String?)?.trim();
    if (path == null || path.isEmpty) return null;
    return HChangeFile(
      path: path,
      added: (raw['added'] as num?)?.toInt() ?? 0,
      removed: (raw['removed'] as num?)?.toInt() ?? 0,
    );
  }
}

/// **变更报告**（2026-10-22，用户要求对齐参考界面的"已编辑 N 个文件"卡片）——
/// 一次 run 结束后，把所有写类工具按文件聚合成一张卡：
///
/// ```
/// </> 已编辑 4 个文件
///    +168 −31
///    app/lib/services/local_agent.dart        +58 −1
///    ...
/// ```
///
/// ## 为什么单独成一条消息（而不是塞进助手回答）
///
/// · 它是**结构化事实**（文件 + 行数），塞进正文会被 Markdown 渲染糊掉；
/// · 落盘为 `{"role":"changes",...}` 一行，重开会话能原样读回；
/// · 数字来源是**工具结果里的 diff**（`diffStatOf`），不是模型自报 ——
///   自报会撒谎，diff 不会。
class HChanges extends HMessage {
  const HChanges({required this.id, required this.files});

  @override
  final String id;
  final List<HChangeFile> files;

  int get totalAdded => files.fold(0, (s, f) => s + f.added);
  int get totalRemoved => files.fold(0, (s, f) => s + f.removed);
}

/// 工具调用 —— **coding agent 的核心展示单元**
class HToolCall extends HMessage {
  const HToolCall({
    required this.id,
    required this.tool,
    required this.args,
    this.result,
    this.status = ToolStatus.running,
    this.rawOutput,
  });

  @override
  final String id;
  final String tool;
  final Map<String, String> args;

  /// 执行结果；null 表示还在跑
  final String? result;
  final ToolStatus status;

  /// **导致这次调用的模型原始输出**（`AgentEvent.ModelOutput.raw`）。
  ///
  /// 只在「工作步骤展示 = 完全展开」档位显示（见 `StepDetail.showRawOutput`）。
  ///
  /// ## 为什么挂在卡片上而不是单独一条消息
  ///
  /// 原始输出是"模型为什么这么决定"的**直接证据**，它属于**这一次调用**。
  /// 单独成块会让用户的视线在"卡片"和"原话"之间来回跳，
  /// 而且一旦没有工具调用（例如最终回答轮）就无处归属。
  ///
  /// 实时事件流（t3）会在 `ToolStarted` 之前收到同一轮的 `ModelOutput`，
  /// 由 `chat_screen` 把它挂到这里。**兜底路径**（`run()` 返回值）拿不到
  /// 原始输出 —— 那时为 null，卡片少显示一段，不影响其它档位。
  final String? rawOutput;

  HToolCall copyWith({String? result, ToolStatus? status, String? rawOutput}) =>
      HToolCall(
        id: id,
        tool: tool,
        args: args,
        result: result ?? this.result,
        status: status ?? this.status,
        rawOutput: rawOutput ?? this.rawOutput,
      );
}

enum ToolStatus { running, success, failure }

/// **正在流式生成的步骤**（2026-10-12，`docs/25` §5.3）。
///
/// 对应 Kotlin 侧的 token 级事件：`step_started` / `reasoning_delta` /
/// `step_delta` / `step_ended`。
///
/// ## 为什么要有这个类型（用户的原话）
///
/// > "AI 接收到任务后会先开始**思考**怎么完成，AI 的思考过程也是展示出来，
/// >  **一个字一个字出来**，不是等 AI 想完了再全部展示出来"
///
/// 之前的粒度是**轮级**：模型整轮生成完才收到一个 `model_output`，
/// 界面只能"想完了再全部展示"。这个类承载的才是**逐字**的那一份。
///
/// ## 两个通道分开存（[reasoning] 与 [text]）
///
/// 后端给的是两个字段（`reasoning_content` 与 `content`），
/// UI 也要**分开渲染**（思考用淡色缩进、正文用正常样式）。
/// 粘成一个字符串就再也分不开了 —— 那正是 `docs/25` §2 记的错误一。
///
/// ## [finished] 决定了要不要重新格式化
///
/// 生成过程中正文是**未完成的 JSON 片段**（我们的协议要求模型输出
/// `{"final":"..."}`），此时按 JSON / Markdown 解析不仅白费算力，
/// 还会因为解析失败闪出乱码。所以运行中**只当纯文本逐字显示**，
/// `step_ended` 到达后（[finished] 为 true）才格式化
/// —— 见 `message_row.dart` 的 `_streamStep`。
class HStepStream extends HMessage {
  const HStepStream({
    required this.id,
    required this.stepId,
    this.title = '',
    this.index,
    this.reasoning = '',
    this.text = '',
    this.finished = false,
    this.status,
    this.durationMs,
    this.truncated = false,
    this.bodyCollapsed = false,
  });

  @override
  final String id;

  /// Kotlin 侧的步骤标识（`turn-3`）—— 增量按它归属
  final String stepId;

  /// 人可读标题（来自 `step_started`）
  final String title;

  /// 第几轮（1 起）；`null` = 后端没给（旧事件 / 兜底路径）
  ///
  /// ★ 2026-10-12（S5）新增：从 `.jsonl` **读回**的步骤需要它，
  /// 否则切会话后用户看到一串没有轮次归属的卡片。
  final int? index;

  /// **思考全文**（累积）。空 = 本次没有思考流
  /// （`enable_thinking=false` 时后端一个 `reasoning_content` 都不返回，
  /// 那时这里恒为空，UI 也就不该画空的思考区 —— 不得伪造内容）。
  final String reasoning;

  /// **正文全文**（累积）。
  final String text;

  /// `step_ended` 已到 —— 停止逐字状态，按最终文本格式化
  final bool finished;

  /// `step_ended` 的三态：`ok` / `empty` / `error`；未结束为 null
  final String? status;

  /// `step_ended` 的墙钟耗时
  final int? durationMs;

  /// 这条步骤**落盘时被截断过**（超上限，见 `SessionStore.stepTextLimit`）。
  ///
  /// ★ 2026-10-12（S5）新增。与"不静默丢信息"是同一条纪律：
  /// 截断是为了不把 `.jsonl` 撑爆（体积实测见 `docs/25` §14），
  /// 但**必须让用户看得见**"这里被截过"，否则他会以为模型只说了这么多。
  ///
  /// 只可能为 `true` 当这条步骤是**从磁盘读回来**的 —— 实时路径不截断。
  final bool truncated;

  /// **正文已折叠进标题行**（2026-10-13，用户反馈"观感不好"）。
  ///
  /// ## 什么时候为 true
  ///
  /// 该轮以最终回答结束、且步骤正文（剥壳后）与最终回答**相同**时 ——
  /// 最终回答马上会作为独立的助手消息出现在下方。此时步骤正文如果
  /// 再显示一遍，用户看到同一句话出现两次（用户原话："final 的内容
  /// 展示给用户看了，与真正发出来的又是一样的，观感不好"）。
  ///
  /// 折叠 ≠ 丢内容：展开（点标题行）仍可看到完整过程 ——
  /// 与 DeepSeek harness 的可折叠步骤条目一致。
  final bool bodyCollapsed;

  /// 生成失败（`status == 'error'`）—— UI 用错误色
  bool get isError => status == 'error';

  /// 跑完了但**内容为空** —— 与失败不同，不要混淆
  bool get isEmpty => status == 'empty';

  /// 当前是否仍在逐字生成中（决定了要不要做 Markdown 格式化）
  bool get streaming => !finished;

  /// 有没有任何可显示的内容。
  ///
  /// `step_started` 刚到时两个通道都还是空的 —— 此时 UI 显示标题 + 转圈，
  /// **不是**一块空白（否则用户以为界面坏了）。
  bool get hasBody => reasoning.isNotEmpty || text.isNotEmpty;

  /// 三态枚举视图（容错解析：未知/缺失 → `ok`）。
  ///
  /// 见 [StepStage.parse] 的说明：`status` 是**跨进程弱契约**里的字符串，
  /// 直接 `status == 'error'` 那种比法散在各处，将来加状态必漏改一处。
  StepStage get parsedStage => StepStage.parse(status);

  /// 步骤标识的**短形式** —— 显示在标题右侧（`turn-3` → `#3`）。
  ///
  /// 长 id 会把标题挤没；短形式只用来"对上号"，不承担唯一性。
  String get shortStepId {
    final dash = stepId.lastIndexOf('-');
    if (dash >= 0 && dash < stepId.length - 1) return '#${stepId.substring(dash + 1)}';
    return stepId;
  }

  HStepStream copyWith({
    String? title,
    int? index,
    String? reasoning,
    String? text,
    bool? finished,
    String? status,
    int? durationMs,
    bool? truncated,
    bool? bodyCollapsed,
  }) =>
      HStepStream(
        id: id,
        stepId: stepId,
        title: title ?? this.title,
        index: index ?? this.index,
        reasoning: reasoning ?? this.reasoning,
        text: text ?? this.text,
        finished: finished ?? this.finished,
        status: status ?? this.status,
        durationMs: durationMs ?? this.durationMs,
        truncated: truncated ?? this.truncated,
        bodyCollapsed: bodyCollapsed ?? this.bodyCollapsed,
      );
}

/// 步骤三态（**不是布尔**）。
///
/// 对应 `AgentEvent.StepEnded` 的 `status`：`ok` / `empty` / `error`。
/// 「跑完了但内容为空」与「出错」对用户是**不同的事**，粘成布尔就分不开。
///
/// 2026-10-12（S5）新增：从 `.jsonl` 读回时 `stage` 字段是**字符串**，
/// 需要一个集中、可容错的解析点（`.jsonl` 是长期数据，
/// 将来加了新状态，旧版本 App 读到时必须还能把步骤显示出来 ——
/// 返回 null 会让调用方干脆不画，等于把用户数据丢了）。
enum StepStage {
  running,
  ok,
  empty,
  error;

  static StepStage parse(String? raw) => switch (raw) {
        'running' => StepStage.running,
        'empty' => StepStage.empty,
        'error' => StepStage.error,
        _ => StepStage.ok,
      };

  /// 落盘/跨进程用的字符串形式（与 Kotlin 侧一致）
  String get wire => name;
}

// ---------------------------------------------------------------------------
// 实时事件产生的消息（2026-10-10 流式）
//
// 这几种是**过程性**消息 —— 由 `heracles/events` 的实时事件产生，
// 而不是等 `runAgent` 返回后才渲染。
//
// ⚠️⚠️ 【旧结论已推翻 —— 2026-10-12，S5】⚠️⚠️
//
// 这里曾经写着「刻意不持久化 —— 不要『修』它」，并给了三条理由。
// **那三条理由全都站不住**，因为用户的原始需求恰恰是**过程本身**：
//
// > "我从会话1切换会话2，前面几轮输出的**工作步骤不见了**……
// >  但是它**已经生成的步骤会消失**"
//
// ## 逐条对照（为什么旧判断是错的）
//
// 1. ~~「`HProgress` 只是等待提示，落盘会让历史塞满噪音」~~
//    → 对**瞬时占位**成立，对**步骤**不成立。两者被混为一谈了：
//      占位是"正在生成…"，步骤是"AI 当时想了什么、做了什么"。
//      **拆开处理**：`HProgress` 仍然不落盘（见下），
//      步骤走 `{"role":"step"}` 落盘。
// 2. ~~「`HBlocked` 一轮之内会被重试，落盘会看到一堆'已拦截'」~~
//    → 恰好相反：**被拦截是过程的一部分**。用户要看的就是"AI 试过什么、
//      为什么被拦"。只留成功的那次 = 把过程截断 —— 那正是用户投诉的东西。
// 3. ~~「`HRawOutput` 是排障证据、体积大，不该进会话」~~
//    → 体积是真问题，但"大"不等于"该丢"。正确做法是**按上限收敛并显式标记**
//      （见 `HStepStream.truncated`），而不是整类不记。
//
// ## ★ 现在的规则（S5 起，以 `.jsonl` 的 role 为准）
//
// | role | 落盘 | 理由 |
// |---|---|---|
// | `user` / `tool` / `assistant` | ✅ | 原有 |
// | **`step`** | ✅ | **本次新增**：思考 + 叙述 + 状态 —— 用户要的"工作步骤" |
// | `system` | ✅ | 读取出错的提示 |
//
// 只有 `HProgress`（「正在生成…」）**仍旧不落盘**：它一轮结束就被撤掉，
// 留下只会是"当时正在生成"的噪音。
//
// 会话记录 = 用户说了什么 **+ agent 过程中的每一步（含思考）** + 最后回答。
// ---------------------------------------------------------------------------

/// **正在生成** 占位（`TurnStarted` / `ModelOutput`）。
///
/// ## 为什么它必须存在
///
/// 用户的原话是：
/// > "我发送消息，但是很长一段时间没有反应"
///
/// 本地模型一轮要 5–20 秒。在那段时间里，如果界面上只有用户自己那条消息，
/// 用户完全无法区分"模型在思考"和"App 卡死了"。
/// 这一行就是用来消除那个空白的 —— 它是**本次修复的可见成果**。
///
/// ## ★ 它是**唯一**仍然不落盘的过程消息（2026-10-12，S5）
///
/// 别把它和步骤混为一谈：**步骤已经落盘**（`{"role":"step"}`，
/// 见 [HStepStream] 与 `SessionStore.appendStep`），
/// 所以切会话后用户看到的是"这一轮思考了什么、做了什么"，
/// 而不是一句无意义的"正在生成"。
class HProgress extends HMessage {
  const HProgress({required this.id, required this.label});

  @override
  final String id;

  /// 例如「正在生成…（第 1 轮）」
  final String label;
}

/// **被拦截**（`AgentEvent.Blocked`）。
///
/// ## 为什么单独一类，而不是复用 `HToolCall` 的 failure
///
/// 被拦截的调用**根本没有执行**（校验失败 / 循环检测 / 重复调用 /
/// 输出无法解析）。如果画成"工具失败"，用户会以为工具坏了、
/// 或者以为文件被改坏了 —— 那是**假信息**，比不显示更糟。
///
/// `tool` 可能为 null：`Unparseable` 分支连工具调用都没解析出来。
class HBlocked extends HMessage {
  const HBlocked({
    required this.id,
    required this.reason,
    this.tool,
    this.args,
    this.index,
  });

  @override
  final String id;

  /// 拦截原因（来自 Kotlin 侧，已是中文）
  final String reason;

  /// 被拦截的工具名；null = 连调用都没解析出来
  final String? tool;

  final Map<String, String>? args;
  final int? index;
}

/// **模型原始输出**（`AgentEvent.ModelOutput`）。
///
/// 只在「工作步骤展示 = 详细」档位下插入 —— 见
/// `06-UI界面设计.md` 的分级原则：默认档位不该被模型的原话淹没，
/// 但排查问题时又必须能看到它（`实测-05` 的教训：模型行为只能观测）。
class HRawOutput extends HMessage {
  const HRawOutput({
    required this.id,
    required this.index,
    required this.raw,
    this.wallMs,
  });

  @override
  final String id;

  final int index;
  final String raw;
  final int? wallMs;
}

/// 单轮缓存指标 —— 对应 Kotlin 侧 `CacheStats`。
///
/// **`cachedTokens` 为 null 表示 provider 未上报**，
/// UI 必须显示"不可用"而不是 0%（`02-契约规范.md` §3.4）。
class TurnMetrics {
  const TurnMetrics({
    required this.cachedTokens,
    required this.promptTokens,
    required this.outputTokens,
    required this.wallMs,
  });

  final int? cachedTokens;
  final int promptTokens;
  final int outputTokens;

  /// 本轮的**模型用时**（毫秒）—— `TurnRecord.wallMs`，只包住模型往返。
  ///
  /// ⚠️ **不含工具执行 / 审批等待 / 压缩**（那些发生在 generate 之外）。
  /// 所以它**不是**"这一轮花了多久" —— 想看任务总耗时用
  /// `SessionUsage.taskWallMs`（run 级真实墙钟）。UI 上必须标注「模型」。
  final int wallMs;

  /// **单轮**缓存命中率 —— **与累计命中率口径不同，两者不可互相替代**。
  ///
  /// ## 口径（2026-10-21，BUG-5）
  ///
  /// 本 getter = **这一轮**的 `cached / (cached + prompt)`。
  /// 它**不是**会话累计命中率：
  ///
  /// | 数 | 算法 | 展示位置 |
  /// |---|---|---|
  /// | 本 getter（单轮） | 本轮的 `cached / prompt` | 消息下方「本次用量」 |
  /// | `SessionUsage.hitRate`（累计·加权） | `Σcached / Σprompt`，**全部轮次** | 标题栏圆圈 + 侧栏主标题 |
  /// | `AgentRunResult.steadyHitRate`（稳态·轮次平均） | `turns.drop(1)` 各轮命中率的**平均** | 侧栏「稳态命中率」 |
  ///
  /// ## 曾经的事故（用户原话）
  ///
  /// > "会话标题右边的第一个圆圈显示缓存命中率 94%，但是下方的显示 96%"
  ///
  /// 这不是两个 bug，是**两个口径不同的数共用了同一个名字**。
  /// 现在三处各自带口径标签，不再都叫「缓存命中」。
  ///
  /// ## ★ 2026-10-23 修正：分母**不再加一次 cached**
  ///
  /// 旧公式是 `cached / (cached + prompt)` —— 那是**重复计数**：
  /// `prompt` 本身就是**整段**（已经包含命中部分）。
  ///
  /// 真机实测（设备 `e35e48c6`，中转站原始 usage）：
  /// ```
  /// prompt_tokens: 5468, prompt_tokens_details: {cached_tokens: 5376}
  /// ```
  /// 真实命中率 = 5376/5468 = **98.3%**；旧公式给 5376/(5376+5468) = **49.6%**，
  /// 于是顶栏长期显示 ~50%，用户报"命中缓存率太低了"。
  ///
  /// ⚠️ 前提：`promptTokens` 已被 backend 规范化成**整段**
  /// （Anthropic 的 `input_tokens` 不含命中，由 `_fullPromptTokens` 加回来）。
  double? get hitRate {
    final c = cachedTokens;
    if (c == null) return null;
    return promptTokens > 0 ? c / promptTokens : null;
  }
}
