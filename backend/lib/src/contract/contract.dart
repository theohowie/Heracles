/// **集中契约常量** —— 后端所有魔法数字的唯一来源。
///
/// ## 为什么必须有这个文件
///
/// 旧 Kotlin 后端有一条硬约束：「所有魔法数字必须定义在 `core/contract/Contract.kt`」。
/// 迁移到 Dart 时这条丢了 —— 数字散成字面量（`40` / `200` / `16384` / `0.80` /
/// `50000`…），改一处要全仓搜，而且**没有任何地方能看出某两个 `200` 是同一个约定
/// 还是碰巧相同**（`docs/DART-MIGRATION-AUDIT-2026-10-22.md` §4.3 把这条判为 ❌ 退）。
///
/// 这个文件把它收回来。**数值一个都不许改** —— 每个常量都注明来源与取舍，
/// 将来要调，改这里一处，并在这里写清为什么。
///
/// ## 用法
///
/// ```dart
/// import '../contract/contract.dart';
/// maxTurns... // ❌ 不要平铺
/// ContractAgent.maxTurns // ✅ 带命名空间，一眼看出属于哪一层
/// ```
///
/// ## 为什么是「顶层 class 前缀」而不是 `Contract.Agent.maxTurns`
///
/// 分组语义（`agent` / `model` / `compression` / …）必须留着 —— 平铺成
/// `Contract.maxTurns` 就等于放弃了「这个数属于哪一层」这条信息。
///
/// 但 **Dart 不允许类内嵌套类**（`class_in_class`），也不允许成员标
/// `abstract`（`abstract_class_member`）⇒ 旧写法 `Contract.Agent.maxTurns`
/// 直接编译不过，级联出 40+ 条 `undefined_getter`。
///
/// 现在的形状：`Contract` 前缀 + 分组名压成一个顶层类名
/// （`ContractAgent` / `ContractModel` / …）。命名空间语义没丢，
/// 只是从「两级点号」变成「一个前缀」，例如：
///
/// ```dart
/// ContractAgent.maxTurns        // 原来是 Contract.Agent.maxTurns
/// ContractWorkspace.lineNumberWidth
/// ```
///
/// 分组对应后端的分层：`agent`（编排）/ `model`（模型请求）/`compression`（上下文压缩）/
/// `tools`（工具默认值）/ `workspace`（文件能力）/ `shell`（命令能力）/`web`/`memory`。
library;

/// **Agent 编排层**（`HeraclesAgent` / `RunOptions`）。
abstract final class ContractAgent {
  /// 一次 run 最多多少轮 LLM 往返。
  ///
  /// 40 的来源：旧实现 20 轮经常不够（"读文件 → 改 → 再读"就要 6 轮），
  /// 而 60 轮以上基本可以断定模型在打转。40 是"够用且能兜住死循环"的折中。
  /// 真正的死循环还有 `DefaultLoopDetector` 兜底，这里只是最后一道闸。
  /// ⚠️ **2026-11-05 用户裁定：取消轮次上限**（原 40）。
  ///
  /// 原话：「最大轮次的意义在哪？赶紧给我取消了！」—— 40 轮对"写一整页 3D 场景
  /// HTML"这种任务根本不够（单轮输出上限装不下整页，必然几十轮反复编辑）。
  ///
  /// 现在给一个**实际不可达**的大数：轮次不再是"任务失败"的理由。
  /// 真正该停的两种情况另有护栏：
  /// · 模型反复发作完全相同的调用（loop detector）；
  /// · 连续多轮没有任何进展（no_progress）。
  static const int maxTurns = 1000000000;

  /// 一次 run 最多多少次工具调用（ADR-033 的"真预算"）。
  ///
  /// **这个值以前只是声明、从不读**（`RunOptions.maxToolCalls` 没人用），
  /// 预算退化成一纸空文。现在由 `_ToolBudgetHook` 真正执行。
  ///
  /// 200 的依据：一次真实的 APK 逆向任务在 120 次工具调用上下，
  /// 200 留 60% 余量；再多的调用次数意味着任务本身该被拆开。
  /// ⚠️ **2026-11-05 用户裁定：取消工具调用次数上限**（原 200）。
  /// 同上：次数不该成为"任务做不完"的理由；死循环由 loop detector 兜底。
  static const int maxToolCalls = 1000000;
}

/// **长任务续跑（V0.4，2026-11-02）** —— 续跑策略/预算/重试的数值唯一来源。
///
/// ## 为什么轮数与 token 是两个上限
///
/// 轮数限制的是"模型来回次数"，token 限制的是"花多少钱"。两者谁都可能先到：
/// 一次工具密集的任务可能 3 轮就烧掉几十万 token；一次纯推理任务可能轮数先到。
/// **谁先到停谁**，`RunStopReason` 如实记原因（不混成一个"超限"）。
abstract final class ContractRunContinue {
  /// 自动续跑默认最多几轮（`ContinuePolicy.auto`）。
  ///
  /// 3 的依据：产品要求"第 3 轮仍未完成就停下来问用户"，而不是无限自动续。
  static const int autoMaxRounds = 3;

  /// 一次 run 的 token 上限（默认 200 万）。
  ///
  /// 依据：长任务实测单轮 5–20 万 token；200 万 ≈ 10–40 轮的量级，
  /// 够覆盖一次真实长任务，又不至于让用户"睡一觉起来账单爆炸"。
  /// ⚠️ **2026-11-05 用户裁定：取消 token 预算**（原 200 万）。
  ///
  /// 原话：「难道一个会话就支持 2 百万 token？搞笑吗？我要跑一个几十亿 token 的
  /// 会话，那别活了呗」—— 对：这是**成本护栏**，不是能力上限，用户明确要无限制。
  ///
  /// `0` = **不限**（调用方必须把 0 当"不检查"，而不是"立刻超限"）。
  static const int runTokenLimit = 0;

  /// 网络/流式超时的最大重试次数（指数 backoff）。
  static const int maxNetworkRetries = 3;

  /// 重试基础间隔（毫秒）；第 n 次重试 = base * 2^(n-1)（上限 [retryMaxDelayMs]）。
  static const int retryBaseDelayMs = 2000;

  /// 重试间隔上限（毫秒），防止退避时间失控。
  static const int retryMaxDelayMs = 30000;

  /// **连续多少轮无进展就判 `no_progress`**。
  ///
  /// 2 的依据：1 轮无进展可能只是"读文件/探查"（正常），连续 2 轮完全相同
  /// 才说明模型在打转。
  static const int noProgressRounds = 2;

  /// 每轮 checkpoint 行的 role 名（`role:"run_checkpoint"`）。
  static const String checkpointRole = 'run_checkpoint';

  /// `ProgressSnapshot` 里测试输出最多保留多少字符（防大日志进 checkpoint）。
  static const int progressTestOutputMaxChars = 2000;

  /// **循环检测的"完全相同调用"阈值**（2026-11-04）。
  ///
  /// ## 为什么是 6，而不是框架默认的 5
  ///
  /// 框架 `DefaultLoopDetector` 的判据是"**最近 N 次调用的
  /// `工具名:参数JSON` 字节完全相同**"。真机上 5 次就会中止，而长任务里
  /// 模型偶尔会"同一处再补一刀"（例如先写、再补一处同样的占位符替换），
  /// 6 次留一点余量；真正的死循环仍会被它逮住（那是逐字相同的重复）。
  ///
  /// ⚠️ 真正误伤用户的那条路**不是**它，而是同一探测器里的
  /// "LLM 自我诊断"分支见 [ContractLoop] 的说明 —— 已在装配层关掉。
  static const int identicalCallThreshold = 6;
}

/// **循环检测（装配层口径）**。
abstract final class ContractLoop {
  /// 是否启用框架的「LLM 自我诊断循环」分支 —— **false**（2026-11-04 真机修）。
  ///
  /// ## 为什么关掉
  ///
  /// 框架 `DefaultLoopDetector` 除了"完全相同调用 ×N"，还有一条：跑到 30 轮后
  /// 每 10 轮用**同一个模型**问一次"你觉得它是不是在打转"，置信度 > 0.8 就中止。
  ///
  /// 真机 2026-11-04 10:14 就是这么被杀的：用户下发"做一个雨夜便利店街角 3D 场景"，
  /// 模型在**同一个 HTML 文件上反复增量编辑**（这本来就是大文件任务的正常形态，
  /// 因为单轮输出上限 16384 tokens 装不下整页），而自我诊断把它判成
  /// "反复修改同一文件 → 打转"，于是**在正常推进中被中止**。
  ///
  /// 两条理由说明它不该留着：
  /// 1. **没有独立信号**：判官是同一个模型、看到的还是同一段历史，
  ///    它的"停滞"判断和主循环的信息量一样，误判概率不低；
  /// 2. **已经有更硬的护栏**：完全相同调用 ×N（[ContractRunContinue.identicalCallThreshold]）、
  ///    轮次/工具/token 预算、以及"只思考不动手"门禁都会在有界步数内收尾。
  ///
  /// 代价（如实记账）：**"换着花样重复同一件错事"这种停滞不再被主动识别**，
  /// 只能靠预算/轮次上限兜底 —— 那是可接受的有界失败，比误杀正常任务好。
  static const bool enableSelfDiagnosedLoopCheck = false;
}

/// **模型请求层**（`BackendConfig` / `ModelConfig`）。
abstract final class ContractModel {
  /// 默认模型窗口（token）。决定压缩阈值。
  static const int defaultWindowTokens = 128000;

  /// 单轮输出上限。
  ///
  /// 16384 不是"模型能力上限"，而是**给思考 + 正文留的余量**。
  /// 旧实现用 4096，长补丁会被截断（用户报过"输出无法解析"）。
  static const int maxOutputTokens = 16384;

  /// **单次模型请求的墙钟上限（秒）** —— 2026-11-04 从框架默认 **300 s 提到 600 s**。
  ///
  /// ## 为什么必须比框架默认值大
  ///
  /// 框架 `OpenAIClient.timeout` 默认 300 s，且**同时**用作 `sendTimeout` 与
  /// `receiveTimeout`。对"边想边吐"的推理模型，`receiveTimeout` 量的是
  /// **相邻两次收到数据之间的间隔** —— 大上下文（读了整份 HTML/日志）时，
  /// 首个 chunk 之前的思考很容易顶到 5 分钟。
  ///
  /// 真机上就撞过：真机 2026-11-04 09:29 那条"网络连接失败"其实是
  /// Dio 的 `receiveTimeout`（消息里是 `connection took longer than 0:05:00`），
  /// 被 UI 的关键词表当成网络故障 —— 用户网络明明是好的。
  static const int requestTimeoutSeconds = 600;

  /// OpenAI 兼容协议的默认 base URL。
  static const String defaultBaseUrl = 'https://api.openai.com';
}

/// **上下文压缩层**（`WindowRatioCompressor`）。
abstract final class ContractCompression {
  /// 超过窗口的这个比例就触发压缩。
  ///
  /// ## 0.80 的来源：**用户明确要求"到 80% 必须先自动压缩"**
  ///
  /// 原话：「上下文压缩机制这个要做一下，如果上下文达到了 80% 必须先自动压缩，
  /// 然后继续任务，哪怕任务跑到了一半」。
  ///
  /// ## 为什么留 20% 而不是更多/更少
  ///
  /// 压缩发生在**每一轮循环的最开头、请求发出之前**（框架
  /// `stateful_agent.dart` 的 `while (true)` 里 `await compressor.compress(state)`）。
  /// 也就是说：**这一刻的估算值**决定压不压，而**紧接着这一轮**还要往里塞：
  ///
  /// - 本轮模型的**输出**（`maxOutputTokens` 上限 16384 = 128K 窗口的 12.5%）
  /// - 本轮可能要跑的工具，其**结果**也会进历史
  ///
  /// ⇒ 阈值若贴到 0.95，压缩"刚做完"就几乎没有余量给本轮输出，
  ///   下一轮一开始又立刻超阈值（频繁压缩、每轮都多花一次摘要调用），
  ///   或者更糟：还没等到下一轮，**本次请求直接撞窗口被拒**。
  ///
  /// 0.80 留出的 20%（128K 窗口 ⇒ 约 25.6K token）刚好覆盖
  /// "最大输出 16384 + 一轮工具结果"的量级。
  ///
  /// 宁可早压一点：压缩的代价是**摘要一次**（有损但保留要点），
  /// 撞窗口的代价是**这一轮直接失败**。
  static const double compressAtRatio = 0.85;

  /// **发送硬顶（2026-11-04 用户确认）** —— 任何一次请求都**不许**在这个比例之上发出。
  ///
  /// ## 为什么要这条（真机 120% 事故）
  ///
  /// 旧实现在 80% 做"强制重置"，但**重置后不检查**，而且一步之内（一个大工具结果）
  /// 就能把占用从 81% 顶到 120% —— 请求照样发了出去。用户明确要求：
  /// **"压不动就如实告诉用户，不许硬发"**。
  ///
  /// 所以：压完再量一次（按 `scale` 折算回真实 token），仍 ≥ 90% ⇒ **中止本轮并说明**
  /// （宁可这一轮明确失败，也不要发一个注定被服务端拒绝/被静默截断的请求）。
  ///
  /// 0.90 的来源：留 10% 给服务端行为差异（不同网关对超限的处理不一致：
  /// 有的 400，有的静默截断历史 —— 后者最坏，模型会"忘事"而用户毫不知情）。
  static const double sendCeilingRatio = 0.90;

  /// 保留最近多少**轮**原文（不被压缩）。
  ///
  /// 必须是"轮"而不是"条"：一轮可能包含 1 条用户消息 + 5 条工具往返，
  /// 按条保留会留下半轮，模型看到"工具结果但没有对应的请求"。
  static const int keepRecentTurns = 6;

  /// 一轮折算成多少条消息（喂给框架 `keepRecentMessageSize`）。
  static const int messagesPerTurn = 4;

  /// **【已作废】第一级（micro）阈值比例**（0.40）—— 2026-11-06 起不再触发压缩。
  ///
  /// 历史：到 40% 就做无 LLM 的轻清理（microcompact）。真机实测证明
  /// **每轮**在 40% 线上换占位符会让该点之后的前缀缓存全部失效，
  /// 命中率被压在 40%~48%（用户招牌指标要 80%+）。
  ///
  /// 现在的 micro 改在**压缩事件内一次性跑**（`ContractCompaction` + 流水线阶段 1），
  /// 低阈值触发被彻底删除。常量保留只为不破坏外部引用，**不要在新代码里读它**。
  static const double microRatio = 0.40;

  /// **【已作废】第二级（auto）阈值比例**（0.60）—— 单阈值 0.85 取代。
  ///
  /// 用户 2026-11-05 裁定：不引入 0.8/0.6 双阈值，压缩只在 0.85 发生一次。
  /// 保留常量只为不破坏外部引用。
  static const double autoRatio = 0.60;

  /// **【已作废】连续 micro 多少次后强制升级到摘要**（3）。
  ///
  /// 它存在的前提是"micro 每轮跑、会卡在 40%"——该前提已被删除
  /// （micro 只在压缩事件内跑一次）。保留常量只为不破坏外部引用。
  static const int microEscalateAfter = 3;

  // 现在的形状（2026-11-06）：
  //   占用 < compressAtRatio(0.85) × 窗口 ⇒ **零副作用**直接返回；
  //   ≥ 0.85 ⇒ 跑一次流水线：MicroCompact → SessionMemory → API 摘要
  //   → 确定性强制重置 → 90% 硬顶升级循环，每层后重估、达标即停。
  //   旋钮与默认值见 [ContractCompaction]。见 WindowRatioCompressor.compress。
}

/// **压缩流水线（阶段 1 MicroCompact / 阶段 2 Session Memory / 阶段 3 API 摘要）**
/// —— 2026-11-06 落地，`context/compaction/` 全部数值的唯一来源。
///
/// ## 为什么单开一组（而不是塞进 [ContractCompression]）
///
/// [ContractCompression] 那组是**旧的"三级阈值"**（micro 40% / auto 60% / full 80%），
/// 其中 micro 每轮在 40% 线上改写历史中段 —— 真机实测把缓存命中率压到 40%~48%
/// （用户核心指标是 80%+）。用户 2026-11-05 拍板：**只保留一条 0.85 触发线，
/// 到线跑一次流水线**。新流水线的旋钮与旧阈值不是一回事（旧的是"线"，
/// 新的是"分层策略"），混在一组里会让人以为它们互相推导。
///
/// ## 纪律
///
/// 本组所有值都有默认值且**都是产品行为**：改它会改变"什么时候压、压掉什么、
/// 压完模型还看得见什么"。改数值**不改结构**。
abstract final class ContractCompaction {
  // ---------------------------------------------------------------------
  // 触发与窗口
  // ---------------------------------------------------------------------

  /// 压缩配置里的默认上下文窗口（token）。
  ///
  /// 与 [ContractModel.defaultWindowTokens] 同一数：宿主传了真实窗口时以宿主为准
  /// （`WindowRatioCompressor` 会 `copyWith(contextWindow: modelWindowTokens)`）。
  /// 这里只作为 `CompactionConfig()` 无参构造的兜底，**不是**第二份真相。
  static const int contextWindow = ContractModel.defaultWindowTokens;

  /// **唯一触发线**：占用 ≥ 窗口 × 本比例 ⇒ 跑一次压缩流水线。
  ///
  /// 直接引用 [ContractCompression.compressAtRatio]（0.85）——
  /// 抄一份过来就会出现"改了一处、另一处没跟上"的经典漂移。
  static const double autoCompactThreshold = ContractCompression.compressAtRatio;

  /// **最近 `keepRecentTurns` 轮折算成多少条消息** = 保护窗（不许被摘要吞掉的原文）。
  ///
  /// 与 `ContractCompression.keepRecentTurns × messagesPerTurn` 同一口径：
  /// 一轮 ≈ 4 条（user / assistant+tool_call / tool_result / assistant）。
  static const int protectedRecentMessages =
      ContractCompression.keepRecentTurns *
          ContractCompression.messagesPerTurn;

  // ---------------------------------------------------------------------
  // 阶段 1：MicroCompact（本地、零 API）
  // ---------------------------------------------------------------------

  /// **保留最近多少条**白名单工具结果不清（更旧的才清）。
  ///
  /// 10 的依据：模型真正会回头用的通常是"刚读的那几个文件"；
  /// 再往前的工具输出只占 token，几乎不再被引用（要就重读）。
  static const int microKeepRecentToolResults = 10;

  /// **允许被清理的工具白名单**（按工具名**子串**匹配，见 `MicroCompactor`）。
  ///
  /// 为什么是子串而不是全名：
  /// · `shell` 在 `run_shell_command` **中间**（前缀匹配会漏掉它）；
  /// · 别名工具（`Read`/`Grep`…）执行层会转调正式工具，历史里落的是正式名，
  ///   但宿主/测试可能直接造别名消息 —— 子串匹配两头都能命中。
  ///
  /// 只有"可重放"的读取类工具在里面：清掉它们的输出，模型重跑一次即可取回；
  /// 写入类（`write_file`/`edit_file`）**不在**白名单 —— 那类结果里含
  /// "改了什么"的证据，清了就再也拿不回来（文件已经是新内容了）。
  static const List<String> microToolWhitelist = <String>[
    'read',
    'list',
    'find',
    'grep',
    'shell',
  ];

  /// 工具结果**短于这个字符数就不清**。
  ///
  /// 占位符本身约 33 字符，清一条 50 字符的结果纯属亏本：既没省 token，
  /// 又白丢信息（还要模型重跑一次工具）。200 是"值得清"的下限。
  static const int microMinChars = 200;

  /// 工具结果被清后替换成的占位符（**英文定稿，UI/测试逐字对齐**）。
  static const String clearedToolResultPlaceholder =
      '[Old tool result content cleared]';

  /// 媒体块（图片/视频）被清后替换成的占位符。
  static const String clearedMediaPlaceholder = '[media cleared]';

  /// 媒体块体量超过多少 token 才清（体量代理 = base64 字符数 / 4）。
  ///
  /// 2000 的依据：主流视觉模型一张常规图 ≈ 1–2K token，超过它的属于
  /// "大图/长视频"—— 老的那张几乎肯定不再被引用，留着只是白付钱。
  /// ⚠️ 体量代理会**高估**真实图像 token（base64 比像素维度线性），
  /// 所以这条线宁大勿小；它只用于"值不值得清"，不参与总量估算。
  static const int maxMediaBlockTokens = 2000;

  // ---------------------------------------------------------------------
  // 压缩后必须重载/保留的内容
  // ---------------------------------------------------------------------

  /// 项目指令文件名（仓库根，按序取第一个可读的）。
  ///
  /// 只认 `AGENTS.md`：用户 2026-11-06 拍板"复用仓库根 AGENTS.md 作为项目指令源，
  /// 不新造格式"。读不到就**跳过并记 note**（绝不假装有）。
  static const List<String> projectInstructionFiles = <String>['AGENTS.md'];

  /// 项目指令注入摘要视图时的字符上限。
  ///
  /// 8000 的依据：AGENTS.md 是"压缩后还要模型遵守的规则"，不是全文备份；
  /// 8000 字符 ≈ 2–8K token（中英混合），对 128K 窗口是 2%~6% 的固定开销。
  /// 超限**截断并明说**（用户要知道看的是节选）。
  static const int projectInstructionsMaxChars = 8000;

  /// 最近修改文件最多列出多少个（超出只列最近的几个）。
  static const int recentFilesMax = 5;

  /// 最近修改文件**估算超过这个 token 数就只给路径引用**，不给全文。
  ///
  /// 5000 的依据：摘要视图是"压缩后的摘要"，不是把文件再搬一遍；
  /// 5000 token 以上的文件注入全文等于没压缩。需要时模型自己 `read`。
  static const int largeFileTokenThreshold = 5000;

  /// 小于 [largeFileTokenThreshold] 的文件最多注入多少字符的节选。
  static const int recentFileExcerptMaxChars = 1200;

  // ---------------------------------------------------------------------
  // 阶段 2：Session Memory（纯本地、零 API）
  // ---------------------------------------------------------------------

  /// 是否默认开启 Session Memory（用户 2026-11-06 拍板：**默认开**）。
  ///
  /// 关掉它的唯一理由：宿主想强制每次都走模型摘要（贵，但更"聪明"）。
  static const bool sessionMemoryEnabled = true;

  /// 记忆超过这个毫秒数没更新就算 **stale**（不可用于渲染摘要视图）。
  ///
  /// 10 分钟的依据：长任务里 10 分钟内历史变动有限，本地规则抽出的
  /// goal/constraints/files 仍然成立；再久就可能与真实进展分叉 ——
  /// 那时宁可花一次 API 摘要，也不许把过时记忆当"当前状态"喂给模型。
  static const int sessionMemoryStaleMs = 10 * 60 * 1000;

  /// `goal` 字段最长字符数（超了截断 + 省略号）。
  static const int sessionMemoryGoalMaxChars = 240;

  /// 记忆**更新**的等待上限（毫秒）。
  ///
  /// 2000 的依据：本地规则是纯 CPU（微秒级）；这个超时只对"宿主注入的
  /// 异步更新器"有意义（例如要去读工作区文件）。超时 ⇒ 保留旧记忆并标 `stale`，
  /// **绝不阻塞任务**（用户 2026-11-06 拍板：更新失败/超时要降级，不许卡住）。
  static const int sessionMemoryUpdateTimeoutMs = 2000;  /// `constraints` / `done` / `decisions` / `openIssues` 单条最长字符数。
  static const int sessionMemoryItemMaxChars = 120;

  /// 硬约束最多抽多少条（用户显式约束必须置顶，多了会挤掉摘要正文）。
  static const int sessionMemoryConstraintsMax = 8;

  /// 已完成项最多抽多少条。
  static const int sessionMemoryDoneMax = 10;

  /// 关键决策最多抽多少条。
  static const int sessionMemoryDecisionsMax = 6;

  /// 未决问题/报错最多抽多少条。
  static const int sessionMemoryOpenIssuesMax = 5;

  /// 抽约束/决策时回看最近多少条 user 消息。
  ///
  /// 40 的依据：真机长会话里"这条不许动"这类话通常出现在最近几十条内；
  /// 再往回翻，用户可能已经改过主意（旧约束反而是负担）。
  static const int sessionMemoryScanRecentMessages = 40;

  // ---------------------------------------------------------------------
  // 阶段 3：API 结构化摘要（兜底）
  // ---------------------------------------------------------------------

  /// 喂给摘要模型的单条消息最多多少字符（防一条巨型消息撑爆摘要请求）。
  static const int summaryTranscriptMessageMaxChars = 1200;

  /// 喂给摘要模型的 transcript 总字符上限（再长就丢更早的，明说不是全文）。
  static const int summaryTranscriptTotalMaxChars = 40000;

  /// 用户 `/compact <focus>` 的 focus 文本最长字符数。
  static const int summaryFocusMaxChars = 400;

  // ---------------------------------------------------------------------
  // 确定性兜底（强制重置 / 90% 硬顶升级循环）
  // ---------------------------------------------------------------------

  /// 兜底裁剪的**升级目标比例**（压到窗口的 50% → 30% → 15%）。
  ///
  /// 为什么是这几个数：一次 `trimToFit` 通常只能清掉"大工具结果"，
  /// 若仍贴着 90% 硬顶，就继续收紧目标；三档走完仍动不了历史 ⇒
  /// 说明已到"压缩的物理下限"（只有一两条超大消息），此时**照常继续任务**
  /// （不许报错、不许停 —— 用户 2026-11-05 裁定）。
  static const List<double> ceilingEscalationRatios = <double>[0.50, 0.30, 0.15];

  /// 插入"本次清理说明"时预留的 token（选取切点时粗算）。
  static const int trimNoteAllowanceTokens = 200;

  /// 插入"强制移除说明"时预留的 token（选取切点时粗算）。
  static const int resetNoteAllowanceTokens = 120;

  // ---------------------------------------------------------------------
  // 开关与观测
  // ---------------------------------------------------------------------

  /// **渐进分层**（默认 `false`）：允许在**未到 0.85 线**时只跑阶段 1（micro）。
  ///
  /// ⚠️ 真机教训（不可重演）：这正是当年把缓存命中率压到 40%~48% 的形状 ——
  /// 每一轮都在历史中段换占位符 ⇒ 该点之后的 token 前缀全失效。
  /// 所以**默认关**；只有明确愿意用命中率换上下文余量的宿主才开。
  static const bool progressiveLayersEnabled = false;

  /// 是否记录压缩事件（`CompactionEvent` 留存 + `WindowRatioCompressor.events`）。
  ///
  /// 关掉只影响"留档与 UI 播报"，**不影响压缩行为本身**（压还是会压）。
  static const bool metricsEnabled = true;

  /// 事件留档最多保留多少条（环形丢弃最老的）。
  ///
  /// 50 的依据：一次长任务通常压缩几次到十几次；50 条足够复盘，
  /// 又不至于让内存里的审计列表无限长。
  static const int metricsMaxEvents = 50;

  // ---------------------------------------------------------------------
  // 估算器的权重（原先散在 window_ratio_compressor.dart 里的字面量）
  // ---------------------------------------------------------------------

  /// 一张图片在总量估算里的固定开销（token）。
  ///
  /// 为什么是固定值而不是 base64 长度：base64 比像素维度线性得多，
  /// 按它估会把 500 KB 的图算成 12 万 token（真实约 1.5K）⇒ 压缩会被
  /// 无意义地频繁触发。固定 800 是"宁可低估图片"的取舍（见 [maxMediaBlockTokens]
  /// 的说明：媒体清理用的是另一套体量代理）。
  static const int estimatedImageTokens = 800;

  /// 一条 `functionCall` 的固定开销（token，含 id/name/参数的 JSON 骨架）。
  static const int estimatedFunctionCallTokens = 30;

  /// 单条工具结果的固定开销（token，JSON 骨架）。
  static const int estimatedToolResultOverheadTokens = 10;

  /// 一条工具定义条目的固定开销（token，括号/逗号/schema 骨架）。
  static const int estimatedToolDefinitionOverheadTokens = 20;

  /// 无法识别的消息类型的兜底估算（token）。
  static const int estimatedUnknownMessageTokens = 50;
}

/// **工具默认值** —— 与 `agent/tools/*.dart` 里 JSON Schema 的 `default` 必须一致。
abstract final class ContractTools {
  /// `list_files` / `find_files` / `grep_files` 的默认结果上限。
  ///
  /// 200 的取舍：够看清一个中等项目的结构，又不至于把窗口灌满。
  /// 超限必须**如实标注被截断**，不能静默少给。
  static const int maxEntries = 200;

  /// `run_shell_command` 的默认超时（秒）。
  ///
  /// 300 = 5 分钟。构建类命令建议模型自己给 600 以上（工具描述里写了）。
  static const int shellTimeoutSeconds = 300;

  /// `web_fetch` 默认最多返回多少字符。
  static const int webMaxChars = 50000;
}

/// **工作区文件能力**（`LocalWorkspaceCapability`）。
abstract final class ContractWorkspace {
  /// `read` 输出的行号前缀宽度（`"   12| 内容"` 里的 5）。
  ///
  /// 5 位能覆盖 99999 行；固定宽度是为了让模型看到的文本**列对齐**，
  /// 也让 `edit` 的 oldText 更容易逐字符对上。
  static const int lineNumberWidth = 5;

  /// unified diff 的上下文行数（`@@ -a,b +c,d @@` 里的 b/d 通常 = 改动行 + 2×3）。
  ///
  /// 3 是 `diff -u` 的默认值，也是模型最常产出的形状。
  static const int diffContextLines = 3;

  /// 单次 `read` 允许的文件大小上限（5 MB）。
  ///
  /// 再大的文件读进内存既慢又没意义（模型也读不完）；超限要明确告知，
  /// 而不是悄悄截断。
  static const int maxReadFileBytes = 5 * 1024 * 1024;

  /// `grep` 单文件可读字节上限（1 MB）。
  ///
  /// 超过就跳过并在结果里计数 —— 正则扫一个 100 MB 的日志文件会把手机拖死。
  static const int grepPerFileBytes = 1024 * 1024;

  /// `find_files` / `grep_files` 最多访问多少个文件（防止遍历超大目录树）。
  static const int maxVisitedFiles = 20000;

  /// 二进制判定：前这么多字节里出现 NUL 就当二进制跳过。
  static const int binarySniffBytes = 8192;

  /// **工作区快照（文件树）注入的条目上限**（2026-10-24，F8 等价物）。
  ///
  /// 快照让模型开场就知道工作区长什么样，省掉"先列目录再干活"的摸索轮。
  /// 200 条与 `list_files` 默认上限同源：超过的靠 `find_files` 精查，
  /// 快照只负责"一眼看清骨架"。
  static const int snapshotMaxEntries = 200;

  /// **工作区宪法文件注入的字符上限**（2026-10-24，H4）。
  ///
  /// 宪法（AGENTS.md/CLAUDE.md/README）整段进 system prompt ⇒ 它的大小
  /// 等于**每轮固定开销**。20K 字符 ≈ 5K~20K token（中英混合），
  /// 对 128K 窗口是可接受的固定成本；更大的宪法就该精简了，而不是让
  /// 每一轮都背着它。超限**截断并明说**（不静默 —— 用户要知道看的是节选）。
  static const int constitutionMaxChars = 20000;
}

/// **会话历史读取**（`SessionStore.loadMessages`，T0-4 长会话 tail 兜底）。
///
/// ## 为什么单独一组常量
///
/// 会话 `.jsonl` 是 append-only，越聊越长。通道 `fs.readText` 有 **1 MB** 文本
/// 上限（Kotlin `DeviceFs.MAX_TEXT_BYTES`，超了只给**前** 1 MB 并置 `truncated`）。
/// `limit=0` 的语义是"加载全部" —— 在超长会话上它**做不到**，必须改读**文件尾部**，
/// 否则用户（和模型）看到的是**开头 1 MB**，最新消息反而丢了。
///
/// 这三个数都是**产品行为**（多少轮可见 / 什么算长会话），不是实现细节：
/// 改它们会改变"用户切会话时看到多少"。
abstract final class ContractSession {
  /// `limit=0` 遇到超长会话时，改读**最后多少行**（含本轮的"更早未加载"提示窗）。
  ///
  /// 2000 的依据：真实会话一轮 ≈ 3–5 行（user / assistant / step / tool），
  /// 2000 行 ≈ 最近 400–600 轮，覆盖"切会话继续聊"的全部现实需求；
  /// 再早的历史由 UI 的"加载更早"分页（`offset`）按需取，仍从磁盘拿。
  static const int tailLoadLines = 2000;

  /// 通道 `fs.readText` 单次可返回的**字节**上限（与 Kotlin
  /// `DeviceFs.MAX_TEXT_BYTES = 1_000_000` 同一数）。
  ///
  /// 文件超过它就一定被截断 ⇒ `limit=0` 直接走 tail，不白读 1 MB。
  static const int channelTextMaxBytes = 1000 * 1000;
}

/// **命令执行能力**（`ProcessShellCapability`）。
abstract final class ContractShell {
  /// 输出总量上限（1 MB）。
  ///
  /// 超了就标注截断，但**继续把流读完**（否则子进程写满管道会阻塞）。
  /// 不用 `readAllBytes()`：长命令的输出可能几 MB，全读进内存会 OOM。
  static const int maxOutputBytes = 1024 * 1024;

  /// 能力层默认超时（5 分钟，与 `ShellCapability.run` 的签名默认值一致）。
  static const int defaultTimeoutSeconds = 300;

  /// 超时后等待进程真正退出的宽限时间（毫秒）。
  static const int killGraceMs = 300;

  /// **超长输出落盘引用阈值**（字符，2026-10-24，C4）。
  ///
  /// shell / web 抓取的输出超过它就写进工作区 `.heracles/overflow/` 并返回
  /// "前 N 字符 + 完整内容路径引用" —— 截断（防窗口爆）与完整性（可取回）
  /// 两头都占。10 万字符 ≈ 2.5 万~10 万 token：直灌上下文必爆，
  /// 全丢又可能丢关键证据（报错原文）—— 落盘引用是两头都顾的形状。
  static const int overflowChars = 100000;

  /// 溢出文件的存放目录（工作区相对路径）。
  static const String overflowDir = '.heracles/overflow';
}

/// **网络抓取能力**（`DioWebFetchCapability`）。
abstract final class ContractWeb {
  /// 默认最多返回多少字符（与 `WebCapability.fetch` 的默认值一致）。
  static const int maxChars = 50000;

  /// 单次抓取超时（秒）。长文页面 30 秒足够，超时要明确回告。
  static const int timeoutSeconds = 30;

  /// 响应体最大下载字节数（5 MB）—— 防止抓到一个巨大文件把内存吃光。
  static const int maxResponseBytes = 5 * 1024 * 1024;
}

/// **长期记忆（三作用域记忆系统）** —— 2026-10-29 重设计后唯一的数值来源。
///
/// ## 为什么不再有 `maxBytes = 256 KB`
///
/// 旧实现把那一个数**同时**当成「写闸」与「每轮固定开销」，于是
/// 「用户能记多少事」和「每一轮付多少 token」被焊在同一个旋钮上
/// （旧注释自己承认："记忆会整段进 system prompt ⇒ 它的大小直接等于每轮固定开销"）。
/// 结果是两头都不成立：写满 256 KB ≈ 6–10 万 token，任何窗口都装不下；
/// 而条目一多又必须停写。**`maxBytes` 已删除**（有意破坏性变更，
/// 同步改了 `contract_test.dart` / `memory_injection_test.dart` 的旧断言）。
///
/// ## 两族常量，互不推导（不变量 I3）
///
/// | 族 | 回答的问题 | 花什么 | 消费方 |
/// |---|---|---|---|
/// | `storage*SoftMaxBytes` / `*EntriesSoftMax` | 能存多少 | 磁盘 | Kotlin `MemoryStore`、App `ScopedMemoryService` |
/// | `*InjectMaxChars` / `injectMaxEntriesPerScope` / `windowRatioCap` | 每轮最多注入多少 | 上下文窗口 | backend `memory_prompt.dart`（纯 Dart，可单测） |
///
/// ⚠️ **存储侧没有"到顶就拒写"的硬闸**：超软预算时按
/// 「过期 → 最旧 agent → 最旧 user」淘汰后再写，淘汰结果回报调用方
/// （不变量 I6：不静默丢条目）。拒写只发生在"单条超 [entryMaxChars]"
/// 或"淘汰后仍放不下"这两条兜底路径上。
///
/// ## 全部数值可调
///
/// 改数值不改结构；Kotlin / App / backend 三侧必须是**同一组数**
/// （INTERFACE.md §N12 记账，注释互指）。依据见各常量的 KDoc。
abstract final class ContractMemory {
  // ---------------------------------------------------------------------
  // 注入侧（每轮最多花多少上下文）
  // ---------------------------------------------------------------------

  /// 单条记忆正文的字符上限（8000）。**可调**。
  ///
  /// 依据：CJK 口径 ≈2–4K token —— 够写清一条项目约定（构建命令/目录习惯/
  /// 用户偏好）；再长就该用笔记文件（`write_file`），而不是塞进每轮注入的记忆。
  /// 消费方：backend `save_memory` / `propose_global_memory` 的长度门禁、
  /// Kotlin `MemoryStore` 的 `ENTRY_MAX_CHARS`、App `ScopedMemoryService`。
  static const int entryMaxChars = 8000;

  /// **global + workspace 两段共享的注入预算**（6000 字符/轮）。**可调**。
  ///
  /// 依据：CJK ≈4–6K token，约占 128K 窗口的 4–5%。两段都是"稳定段"
  /// （变化少），共享一个上限能保住前缀缓存；global 先占，workspace 吃剩余。
  /// 消费方：`memory_prompt.dart` 的 `renderMemoryContext`。
  static const int globalWorkspaceInjectMaxChars = 6000;

  /// **session 段的独立注入预算**（4000 字符/轮）。**可调**。
  ///
  /// 依据：会话私有记忆是草稿类、易变、生命周期短，4000 足够；
  /// 独立预算避免会话段把稳定段（global/workspace）挤掉。
  /// 必须 `< globalWorkspaceInjectMaxChars`（`contract_test.dart` 钉住该关系）。
  /// 消费方：`renderMemoryContext`。
  static const int sessionInjectMaxChars = 4000;

  /// 每个作用域最多注入多少条（40）。**可调**。
  ///
  /// 依据：防"很多极短条目"把段头与行前缀撑爆（每行前缀 ≈8 字符）；
  /// 也限制选择算法的循环次数。
  /// 消费方：`selectForInjection` 的 `maxEntries`。
  static const int injectMaxEntriesPerScope = 40;

  /// 每作用域参与排序的候选窗（64 KB）。**可调**。
  ///
  /// 依据：上千条全排序在手机上不现实；超出窗的条目**只存不注**
  /// （用户可在记忆页/检索里显式查）。
  /// 消费方：宿主读取层（读 JSONL 时最多取 64 KB）+
  /// `memory_prompt.dart` 的条数窗（`retrievalMaxCandidates`）。
  static const int injectCandidateMaxBytes = 64 * 1024;

  /// 注入预算的窗口自适应比例（5%）。**可调**。
  ///
  /// 依据：小窗口模型（8K/32K）下 6000 字符会把人设/工具定义挤出窗口，
  /// 必须按比例缩。实际预算 = `min(常量, floor(windowTokens * 本比例))`，
  /// 该 `min` **是真实现**（`memory_prompt.dart` 的 `injectBudgetChars`，有单测）。
  /// 消费方：`memory_prompt.dart`。
  static const double windowRatioCap = 0.05;

  /// 未命中关键词的条目压成的摘要长度（40 字符）。**可调**（沿用旧实现）。
  ///
  /// 依据：摘要只用来"提示存在这么一条"，40 字足够辨识；全文留给命中项与
  /// 记忆页。消费方：`selectForInjection` / `renderMemoryContext`。
  static const int summaryMaxChars = 40;

  /// 选择算法最多对多少条候选排序（200 条）。**可调**。
  ///
  /// 依据：排序成本上限；再多的条目也在 [injectCandidateMaxBytes] 窗口之外。
  /// 消费方：`memory_prompt.dart`。
  static const int retrievalMaxCandidates = 200;

  // ---------------------------------------------------------------------
  // 存储侧（能存多少；软预算 ⇒ 超限淘汰，不拒写）
  // ---------------------------------------------------------------------

  /// global 作用域的存储软预算（8 MB）。**可调**。
  ///
  /// 依据：磁盘便宜，但备份/清理成本要可控；手机场景人工可读的记忆
  /// 远小于这个量级。消费方：Kotlin `MemoryStore`、App 存储层。
  static const int storageGlobalSoftMaxBytes = 8 * 1024 * 1024;

  /// workspace 作用域的存储软预算（16 MB，**每个工作区**）。**可调**。
  ///
  /// 依据：工作区记忆跨会话共享、量比全局大；但工作区可能多个，
  /// 所以单工作区不宜再放大。消费方：App `ScopedMemoryService`。
  static const int storageWorkspaceSoftMaxBytes = 16 * 1024 * 1024;

  /// session 作用域的存储软预算（512 KB，**每个会话**）。**可调**。
  ///
  /// 依据：会话私有记忆生命周期随会话结束，512 KB 已远超人工可读量；
  /// 小预算让会话删除/清理成本可忽略。消费方：App `ScopedMemoryService`。
  static const int storageSessionSoftMaxBytes = 512 * 1024;

  /// 三作用域存储软预算**合计**（≈24.5 MB）。
  ///
  /// ⚠️ 实现说明：设计稿附录 A 写"合计 ≈32 MB"，但
  /// 8 + 16 + 0.5 = **24.5 MB** —— 本常量以三个具名常量之和为唯一真相
  /// （只是汇总，**不许单独调**；要改就改上面三个）。
  static const int storageSoftMaxBytes = storageGlobalSoftMaxBytes +
      storageWorkspaceSoftMaxBytes +
      storageSessionSoftMaxBytes;

  /// global / workspace 每个作用域的条目软上限（5000 条）。**可调**。
  ///
  /// 依据：手机场景下人工能读的记忆条目远小于此；超限按淘汰顺序清理。
  /// 消费方：Kotlin `MemoryStore`、App 存储层。
  static const int entriesSoftMax = 5000;

  /// session 作用域（**每会话**）条目软上限（300 条）。**可调**。
  ///
  /// 依据：会话私有记忆是短期草稿；300 条足够装下一次长任务的约定。
  /// 消费方：App 存储层。
  static const int sessionEntriesSoftMax = 300;
}

/// **内置 git**（`GitCapability` / `git_tools.dart`，2026-10-27）。
///
/// ## 为什么这些数要有契约
///
/// git 命令的默认值是**产品行为**（不是实现细节）：`log` 默认给几条、
/// `diff` 的上下文行数、提交信息多长算超限 —— 这些同时被三个地方消费
/// （工具描述、实现、测试），散成字面量必然漂移。
abstract final class ContractGit {
  /// `log` 默认返回多少条提交。
  ///
  /// 20 的依据：模型问"最近改了什么"时，20 条 ≈ 覆盖一两天的工作量；
  /// 再多会把工具结果撑成噪音（每条 ≈ 100 字符 ⇒ 20 条 ≈ 2K 字符）。
  static const int defaultLogLimit = 20;

  /// `log` 最多允许取多少条（模型显式要求时的上限）。
  ///
  /// 100 是「够做一次历史考察，又不至于把窗口灌满」的折中。
  /// 真正需要看更多历史的场合应该用 `git log --format` 之类的精查手段，
  /// 而不是一次拉全量（手机上下文窗口经不起）。
  static const int maxLogLimit = 100;

  /// 单次 `diff` 输出的字符上限（与 shell 的 overflow 阈值同量级）。
  ///
  /// 超过就截断并**明说**（"已截断，完整内容用 file 参数分批看"）——
  /// 静默截断会让模型以为改完了，那是假信息。
  static const int maxDiffChars = 100000;

  /// 提交信息长度上限（字符）。
  ///
  /// 72 是 git 社区公认的首行长度（`git log --oneline` 不折行）；
  /// 但**不强制**截断 —— 超了就在工具层提示模型"首行建议 ≤72"，
  /// 因为强行截断会破坏用户/模型表达的原意。
  static const int recommendedMessageChars = 72;

  /// 新仓库的默认分支名。
  ///
  /// `main` 而不是 `master`：GitHub 2020 起新仓库默认 `main`，
  /// 对齐它能少一次"推上去发现分支名对不上"的往返。
  static const String defaultBranch = 'main';

  /// 浅克隆的默认深度（`clone` 不显式给 depth 时）。
  ///
  /// `null` = 全量克隆（行为与 git 一致）。手机场景下大仓库全量克隆可能
  /// 几百 MB，但**默认改浅是有损的**（历史不全）——
  /// 这是产品决定：默认全量，让调用方（UI/模型）显式要浅克隆。
  static const int? defaultCloneDepth = null;

  /// 克隆时最多允许多少字节（粗估上限，超过就拒绝并明说）。
  ///
  /// 手机存储不是无限的。200 MB 是「常见项目够用、又不至于把用户手机塞满」
  /// 的折中；真需要更大仓库的用户可以显式放宽（将来若做设置项）。
  static const int maxCloneBytes = 200 * 1024 * 1024;
}

/// **SAF 目录选择器（`pickWorkspace`）的超时与兜底文案** —— 2026-11-02 T0 修复。
///
/// ## 为什么需要一组超时常量
///
/// `ACTION_OPEN_DOCUMENT_TREE` 把本 App 推到后台期间，Activity **可能被系统
/// 回收重建**（低内存、开发者选项「不保留活动」、部分 ROM 的激进回收）。
/// 一旦发生：
/// - Kotlin 侧 pending 回调若挂在 Activity 实例上 ⇒ 新实例没有收件人，结果被丢弃；
/// - Dart 侧那个 `await` **永远等不到回包** ⇒ 用户看到的是黑屏/无响应。
///
/// 所以 Dart 侧**必须**有超时：宁可给一句"被系统回收，请重试"，也不许永久挂起。
/// ## ★ 计时口径（2026-11-02 真机纠错，别再按"墙钟"理解）
///
/// [timeoutSeconds] 是 **App 在前台** 的等待上限，**不是**从发起调用开始的墙钟。
/// 系统选择器盖住我们时（App 进后台）**停表**。
///
/// 真机证据：用户在 DocumentsUI 里挑了 **70 秒**，结果正常返回
/// （logcat `onActivityResult res=-1 data=true`），但按墙钟 45 s 的旧实现
/// 早已判死 ⇒ UI 弹「选择结果已丢失」，而工作区其实登记成功了 —— **提示撒谎**。
/// 计时器不该把"用户在别人的界面里挑文件夹"算作"我们的界面在干等"。
///
/// - [timeoutSeconds] 45 s —— 前台干等 45 秒已经远超正常回包（本地通道，毫秒级），
///   只有"结果真的丢了"才会走到；后台不累计。
/// - [recoverTimeoutSeconds] 3 s —— 超时后的**结果回收**是本地通道调用
///   （不打网络），3 s 只为防通道本身卡死，不需要更久。
///
/// ⚠️ 口径：超时**不等于失败**。Kotlin 可能在我们超时之后才把结果交回来，
/// 因此超时后要先尝试 [recoverMethod] 取回已完成的 payload，
/// 取不到才报错 —— 否则会把"其实选成功了"误报成失败。
abstract final class ContractFolderPicker {
  /// Dart 侧等待 `pickWorkspace` 回包的上限（秒）。
  static const int timeoutSeconds = 45;

  /// 超时后回收已完成结果的上限（秒）。
  static const int recoverTimeoutSeconds = 3;

  /// 通道方法名：取回某个 requestId 已产生的结果（只增方法，旧实现无此方法时安全降级）。
  static const String recoverMethod = 'consumePickWorkspaceResult';

  /// 宿主 → Dart 的"工作区已新增"通知方法名（Activity 重建后靠它让新 UI 刷新）。
  static const String addedPushMethod = 'workspaceAdded';

  /// 超时且回收不到结果时给用户看的话。
  ///
  /// 措辞要求：说清**发生了什么**（系统把选择器回收了）+ **下一步**（重试），
  /// 不用"未知错误/操作失败"这类没有信息量的话。
  static const String timeoutMessage =
      '系统回收了文件夹选择器，选择结果已丢失。请重试一次（或改用「默认工作区」）。';
}

/// **Skills 扩展面**（V0.4 F1，2026-11-02；契约见 `docs/INTERFACE.md` §N16.1）。
///
/// ## 为什么方法名也进契约
///
/// Kotlin 宿主与 Dart 两侧都按字符串方法名对话 —— 名字写死在两处就会漂。
/// 这里做**唯一来源**：Dart 调通道时用常量，Kotlin 侧注释引用同一张表。
///
/// ## 为什么"已启用"存在宿主而不是 backend
///
/// backend 是纯函数式的编排层（无 IO、`dart test` 毫秒级）；启停状态是**用户偏好**，
/// 生命周期跟着安装而不是跟着会话 ⇒ 落 SharedPreferences（宿主）。
/// 但**开关的语义**（停用技能不注入系统提示）在 backend —— 见 `SkillRegistry.enabled`。
abstract final class ContractSkills {
  static const String channel = 'heracles/command';

  static const String listMethod = 'skillsList';
  static const String setEnabledMethod = 'skillsSetEnabled';
  static const String installMethod = 'skillsInstall';
  static const String removeMethod = 'skillsRemove';

  /// 来源枚举：内置（backend 导出）与用户（工作区 `SKILL.md`）。
  static const String sourceBuiltin = 'builtin';
  static const String sourceUser = 'user';

  /// 工作区内技能目录（相对工作区根）。
  static const String skillsDir = '.heracles/skills';

  /// 单个 `SKILL.md` 读取上限（512 KB）。
  ///
  /// 为什么有上限：技能正文会被注入系统提示，一个误放的巨大文件会直接吃光上下文，
  /// 而用户看不到原因。超限 ⇒ 明确报错（进 `errors`），不静默截断。
  static const int maxSkillFileBytes = 512 * 1024;

  /// 递归扫描深度上限。
  ///
  /// 4 层足够「分类目录/技能名/SKILL.md」的常见形态，又能防住符号链接造出的环。
  static const int maxScanDepth = 4;

  static const String errNoWorkspace = 'E_SKILLS_NO_WORKSPACE';
  static const String errSourceInvalid = 'E_SKILL_SOURCE_INVALID';
  static const String errSourceUnreachable = 'E_SKILL_SOURCE_UNREACHABLE';
  static const String errTooLarge = 'E_SKILL_TOO_LARGE';
  static const String errNotFound = 'E_SKILL_NOT_FOUND';
}

/// **MCP 扩展面**（V0.4 F3，2026-11-02；契约见 `docs/INTERFACE.md` §N16.2）。
abstract final class ContractMcp {
  static const String channel = 'heracles/command';

  static const String listMethod = 'mcpList';
  static const String saveMethod = 'mcpSave';
  static const String deleteMethod = 'mcpDelete';

  /// 传输方式（与 `McpServerConfig.transport` 同一词表）。
  static const String transportStdio = 'stdio';
  static const String transportHttp = 'http';

  /// 连接测试状态（**如实四态**，没有"大概连上了"）。
  static const String statusNotConfigured = 'not_configured';
  static const String statusUnsupported = 'unsupported';
  static const String statusFailed = 'failed';
  static const String statusConnected = 'connected';

  /// 手机端 stdio 不可用的原因文案（给用户看，不许含糊成"不支持"）。
  static const String stdioUnsupportedMessage =
      '手机端无法启动 stdio 子进程（没有可执行的命令行环境）；请改用 http 传输的 MCP 服务器。';

  static const String errSecretInEnv = 'E_MCP_SECRET_IN_ENV';
  static const String errInvalidConfig = 'E_MCP_CONFIG_INVALID';
}

/// **Automation 消费闭环**（V0.4 F2，2026-11-02；契约见 `docs/INTERFACE.md` §N16.3）。
abstract final class ContractAutomation {
  /// 每个任务保留的运行历史条数（与 `AutomationStore.recordRun(keep:)` 同一口径）。
  static const int historyKeep = 20;

  /// 幂等闸：距上次运行**不到间隔的这个比例**就判为重复触发。
  ///
  /// 0.5 = 一半间隔。为什么不是"完全相同时间戳"：AlarmManager 的
  /// `setInexactRepeating` 本来就有抖动，加上"启动 + 回前台"两次消费，
  /// 用时间戳精确比对根本挡不住重复；一半间隔既能挡住抖动与二次消费，
  /// 又不会误杀真的到了下一轮的任务。
  static const double dedupeRatio = 0.5;

  /// 历史里的失败原因最长保留字符数（防日志式膨胀）。
  static const int maxErrorChars = 500;
}

/// **搜索服务配置**（V0.4 F4，2026-11-02；契约见 `docs/INTERFACE.md` §N16.4）。
abstract final class ContractSearch {
  /// secure storage 的键名（不含工作区 —— 搜索服务是 App 级配置）。
  static const String endpointKey = 'heracles.search.endpoint';
  static const String apiKeyKey = 'heracles.search.api_key';

  /// **本版本是否支持把 Key 注入请求头**（2026-11-02 用户裁定：**不支持**）。
  ///
  /// 为什么做成常量而不是散在文案里：`DeviceWebCapability` 目前**没有自定义
  /// 请求头的位置**，存了 Key 也发不出去 —— 那就是"已保存却不生效"的半截功能。
  /// 裁定是"明确不支持"：保存 Key 直接拒绝、遗留 Key 读取时迁移清掉。
  /// 下一轮给能力层加 `headers` 缝后，把这个值翻成 `true` 并恢复 Key 的保存。
  static const bool keyHeaderSupported = false;

  static const String errKeyUnsupported = 'E_SEARCH_KEY_UNSUPPORTED';

  /// 带 Key 保存被拒时的人话（设置页直接上屏）。
  static const String keyUnsupportedMessage =
      '当前版本仅支持免鉴权搜索服务：API Key 不会被保存，也不会被使用。'
      '请改用免鉴权的搜索服务地址。';

  /// 掩码保留的尾部字符数（`sk-***abcd` 这种）。
  static const int maskVisibleTail = 4;

  /// 短于等于此长度的 Key **全掩**（否则掩码本身就把 Key 泄完了）。
  static const int maskFullBelow = 8;

  static const String errInvalidEndpoint = 'E_SEARCH_ENDPOINT_INVALID';
}

/// **BotGateway（V0.5 第一批 · QQ/OneBot 11）**（2026-11-03；契约见
/// `docs/INTERFACE.md` §N19）。
///
/// ## 设计红线（写死在契约里）
///
/// · **鉴权 fail-closed**：accessToken 必填，空 token 拒绝启动；token 走
///   secure storage（App 侧），**不进配置文件、不进日志**（日志一律脱敏）；
/// · **白名单 fail-closed**：空白名单 = 拒绝所有人；
/// · **群聊触发 fail-closed**：不知道 botQQ ⇒ 群聊一律不响应；
/// · **审批红线**：Bot 触发的一切危险操作走与 App 内完全相同的审批三态；
///   手机未确认 ⇒ 拒绝并写审计；
/// · 审计 JSONL **只记元数据**（textLen），正文与 token 永不入审计。
abstract final class ContractBot {
  // ---- 传输（v1 只有正向 WS；reverse 进配置但默认关） ----
  static const String transportForward = 'forward';
  static const String transportReverse = 'reverse';

  // ---- 连接器状态机（五态；迁移表见 §N19.2） ----
  static const String statusUnconfigured = 'unconfigured';
  static const String statusConnecting = 'connecting';
  static const String statusConnected = 'connected';
  static const String statusFailed = 'failed';
  static const String statusDisabled = 'disabled';

  // ---- 错误码 ----
  /// accessToken 缺失/空白 ⇒ 拒绝启动（fail-closed）。
  static const String errTokenRequired = 'E_BOT_TOKEN_REQUIRED';
  /// 发送者不在管理员白名单（空白名单 = 拒绝所有人）。
  static const String errNotAllowed = 'E_BOT_NOT_ALLOWED';
  /// 群聊需要 @/回复触发，但 botQQ 未知 ⇒ 不响应（fail-closed）。
  static const String errGroupTriggerUnknown = 'E_BOT_GROUP_TRIGGER_UNKNOWN';
  /// 出站限流命中（该条被丢弃，不排队）。
  static const String errRateLimited = 'E_BOT_RATE_LIMITED';
  /// 离线排队已满（该条被丢弃）。
  static const String errQueueFull = 'E_BOT_QUEUE_FULL';
  /// OneBot 侧发送失败（如 napcat 断开）。
  static const String errSendFailed = 'E_BOT_SEND_FAILED';

  // ---- 去重窗口（message_id） ----
  /// 同一 message_id 在窗口内只处理一次（NapCat 重连会重推事件）。
  static const int dedupeWindowMs = 5 * 60 * 1000;
  /// 去重表最大条目数（防长驻进程内存膨胀；超限先清最老）。
  static const int dedupeMaxEntries = 2000;

  // ---- 离线/灭屏排队 ----
  /// App 不可用时的入站排队上限；满 ⇒ 丢弃 + 审计 [errQueueFull]。
  static const int queueMax = 50;
  // ---- 出站限流（滑动窗口 60s） ----
  /// 每会话回复限流（条/分钟）；超限 ⇒ 丢弃 + 审计 [errRateLimited]。
  static const int ratePerSessionPerMinute = 10;
  /// 主动写限流（条/分钟，全局）；超限 ⇒ 丢弃 + 审计 [errRateLimited]。
  static const int proactivePerMinute = 3;

  // ---- 重连退避（指数：base * 2^n，封顶 max；连接成功即重置） ----
  static const int reconnectBaseMs = 2000;
  static const int reconnectMaxMs = 60000;

  // ---- 审计 ----
  /// 审计行里**不出现正文**；只记长度。超长元数据字段截断到这么多字符。
  static const int auditMaxChars = 300;

  // ---- 会话绑定（QQ 会话 ↔ Heracles 会话） ----
  /// 派生 id 前缀：`bot/qq-<chatType>-<peerId>`。**稳定且合法文件名字符**
  /// （重启可续），不做 hash —— 可读性即可运维性（审计里能认出是哪个会话）。
  static const String sessionPrefix = 'bot/qq';
}
