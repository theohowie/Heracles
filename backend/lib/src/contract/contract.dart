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
  static const int maxTurns = 40;

  /// 一次 run 最多多少次工具调用（ADR-033 的"真预算"）。
  ///
  /// **这个值以前只是声明、从不读**（`RunOptions.maxToolCalls` 没人用），
  /// 预算退化成一纸空文。现在由 `_ToolBudgetHook` 真正执行。
  ///
  /// 200 的依据：一次真实的 APK 逆向任务在 120 次工具调用上下，
  /// 200 留 60% 余量；再多的调用次数意味着任务本身该被拆开。
  static const int maxToolCalls = 200;
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
  static const double compressAtRatio = 0.80;

  /// 保留最近多少**轮**原文（不被压缩）。
  ///
  /// 必须是"轮"而不是"条"：一轮可能包含 1 条用户消息 + 5 条工具往返，
  /// 按条保留会留下半轮，模型看到"工具结果但没有对应的请求"。
  static const int keepRecentTurns = 6;

  /// 一轮折算成多少条消息（喂给框架 `keepRecentMessageSize`）。
  static const int messagesPerTurn = 4;

  /// **第一级（micro）阈值比例** —— 2026-10-24 引入，对齐 Claude Code 的三级压缩。
  ///
  /// 到 40% 就做**无 LLM 的轻清理**（microcompact）：把保护窗之外的
  /// 老工具结果替换成占位符。理由：老工具输出（整个文件内容、长日志）
  /// 是上下文里最大的死重，而模型几乎从不回头用它 —— 真要用了重新
  /// `read_file` 一次即可。**不动任何 user/assistant 正文**，信息零损失。
  static const double microRatio = 0.40;

  /// **第二级（auto）阈值比例** —— LLM 摘要压缩在这一档启动。
  ///
  /// 60% 时窗口还剩 40%，够摘要调用本身 + 后续若干轮使用；
  /// 60% 才开始摘要（而不是等 80%）意味着"到 80%"时通常已经压过一轮，
  /// 第三级大概率不需要出场。
  static const double autoRatio = 0.60;

  // compressAtRatio（0.80）= **第三级**阈值，含义升级：
  // 用户"到 80% 必须压缩"的承诺不变，但现在由**确定性的强制重置**
  // （_forceReset，不依赖 LLM）兜底 —— 即使摘要调用失败/静默早退，
  // 80% 这条线也**一定**有动作。见 WindowRatioCompressor.compress。
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
