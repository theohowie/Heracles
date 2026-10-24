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

/// **长期记忆能力**（`FileMemoryCapability`）。
abstract final class ContractMemory {
  /// 记忆文件大小上限（256 KB）。
  ///
  /// 记忆会整段进 system prompt ⇒ 它的大小直接等于每轮固定开销。
  static const int maxBytes = 256 * 1024;
}
