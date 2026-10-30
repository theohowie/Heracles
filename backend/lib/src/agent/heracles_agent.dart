/// **任务编排入口** —— 把 `dart_agent_core` 的能力组装成一个可用的 Agent。
///
/// ## 这个类做的事：**组装**，不是**实现**
///
/// 所有"怎么跑"的逻辑都在框架里（`StatefulAgent` 的 think-act-observe 循环、
/// 工具调度、计划、循环检测、状态持久化）。这里只做四件事：
///
/// 1. 按 provider 配置建 `LLMClient`（或直接用注入进来的）
/// 2. 把 [Capabilities] 包成一组 `Tool`
/// 3. 给 `StatefulAgent` 传对参数（含压缩器、控制器、循环检测阈值、预算 hook）
/// 4. 把框架的 `StreamingEvent` 翻译成 [HeraclesEvent] 给 UI
///
/// ## 为什么事件要翻译
///
/// `StreamingEvent.data` 是 `dynamic`，UI 拿到无法安全 switch。
/// 翻译成 sealed class 之后，UI 的 `switch` 是**穷尽检查**的 ——
/// 将来加新事件，编译器会提醒每个 switch 补分支（旧实现靠人记）。
///
/// ## 事件桥为什么必须"产出与消费解耦"
///
/// 旧写法（审计 §3.2）：
///
/// ```dart
/// final bridge = StreamController<HeraclesEvent>();   // 非 broadcast
/// try { … bridge.add(…) … } finally { await bridge.close(); }  // ← 无监听者时永不完成
/// yield* bridge.stream;                               // ← 永远到不了
/// ```
///
/// `await bridge.close()` 在没有监听者时**永不完成**，而监听者是 `yield*`
/// 之后才挂上的 ⇒ 死锁：一个事件都播不出来，UI 一直转圈。
///
/// 现在的形状：**先把 run 跑起来（EventBus 回调往里写），再去 `yield*` 消费**，
/// 并且 **`close()` 绝不被 await**。桥自己缓冲未消费的事件，
/// 生产者与消费者谁先谁后都不影响正确性。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';

import '../capability/capabilities.dart';
import '../contract/contract.dart';
import '../context/memory_context.dart';
import '../context/window_ratio_compressor.dart';
import '../prompt/memory_prompt.dart';
import '../prompt/system_prompt.dart';
import '../prompt/builtin_skills.dart';
import '../tools/tool_factory.dart';
import 'multimodal.dart';
import 'tools/apk_tools.dart';
import 'tools/git_tools.dart';
import 'tools/file_manage_tools.dart';
import 'tools/file_tools.dart';
import 'tools/info_tools.dart';
import 'tools/interaction_tools.dart';
import 'tools/shell_tools.dart';

/// 模型配置（后端视角）。
class BackendConfig {
  const BackendConfig({
    required this.apiKey,
    required this.modelName,
    this.baseUrl = ContractModel.defaultBaseUrl,
    this.provider = BackendProvider.openAiCompatible,
    this.modelWindowTokens = ContractModel.defaultWindowTokens,
    this.maxOutputTokens = ContractModel.maxOutputTokens,
    this.temperature,
    this.summarizerModel,
    this.reasoningEffort,
  });

  final String apiKey;
  final String modelName;
  final String baseUrl;
  final BackendProvider provider;

  /// 模型窗口。决定压缩阈值。
  final int modelWindowTokens;

  /// 单轮输出上限。
  ///
  /// 16384 不是"模型能力上限"，而是**给思考 + 正文留的余量**。
  /// 旧实现用 4096，长补丁会被截断（用户报过"输出无法解析"）。
  final int maxOutputTokens;

  final double? temperature;

  /// **推理档位**（2026-10-24 接线；provider 无关概念，App 的
  /// `ReasoningLevel.reasoningEffort` 传入）。
  ///
  /// 翻译规则：经框架 `ModelConfig.extra['reasoning_effort']` 通道下发，
  /// OpenAI 兼容轨会翻成 wire 的 `reasoning_effort`；Anthropic / Responses
  /// 轨的 client 不读这个键 ⇒ 自然忽略（档位对那两轨暂不生效，如实记录）。
  /// `null` = 不下发（auto / off —— 旧行为）。
  final String? reasoningEffort;

  /// 摘要用的模型（留空 = 用主模型）。
  ///
  /// 建议配一个便宜模型：摘要不需要强推理，但每压缩一次都是一次完整调用。
  final String? summarizerModel;
}

enum BackendProvider {
  /// OpenAI Chat Completions 兼容（DeepSeek / Qwen / Kimi / 中转站…）
  openAiCompatible,

  /// Anthropic Messages
  anthropic,

  /// OpenAI Responses（增量发送，省 token）
  openAiResponses,
}

/// **审批档位**（2026-10-24 接线）—— 对应 App 设置里的三档权限模式。
///
/// 由宿主（App 的 `settings.permission`）显式传入 [RunOptions.approvalMode]；
/// 档位决定**哪些工具在执行前要过用户批准**（见 `_ApprovalHook` 的分类表）。
///
/// ## 三档语义（与 App 侧 `PermissionMode` 的文案逐字对应）
///
/// | 档位 | 语义 | 要批准的 |
/// |---|---|---|
/// | [manual] | 手动审批：每次修改都要确认 | 全部会改状态/有副作用的工具 |
/// | [workspaceAuto] | 工作区内修改自动 | 破坏性三件套 + shell + APK 全家 |
/// | [fullAccess] | 不再询问 | 无（旧行为） |
enum ApprovalMode {
  manual,
  workspaceAuto,
  fullAccess,
}

/// 一次运行的配置。
class RunOptions {
  const RunOptions({
    this.maxTurns = ContractAgent.maxTurns,
    this.maxToolCalls = ContractAgent.maxToolCalls,
    this.enablePlan = true,
    this.systemPrompts = const [],
    this.memory,
    this.memoryNote,
    this.approvalMode = ApprovalMode.fullAccess,
    this.enableSubAgents = false,
    this.enableSkills = false,

    /// **全链路 trace 目录**（E4，2026-10-24；默认 null = 不记录）。
    ///
    /// 设置后每轮模型调用的**原始请求与响应**（JSON）写入该目录
    /// （turn-N-req.json / turn-N-res.json）—— 这是“逐轮原始输入输出
    /// 可回放”的那一半（工具级 trace 已在会话 .jsonl）。CLI 用 --trace 开；
    /// App 默认关（文件量大，排障时才开）。
    this.traceDir,
    this.autoExtract = false,
    this.verifyCommand,
    this.planMode = PlanMode.auto,
    this.fallbackModelNames = const [],
    this.mcpServers = const [],
    this.requirePlan = false,
    this.reflectOnFailures = 0,
    this.verifyGateCompletion = false,
  });

  final int maxTurns;

  /// 一次 run 内最多多少次工具调用（ADR-033 的"真预算"）。
  ///
  /// ⚠️ 这个字段**曾经声明了从不读** ⇒ 预算是一纸空文。
  /// 现在由 [HeraclesAgent] 里的 `_ToolBudgetHook` 真正执行，超限即中止，
  /// 并在 [HeraclesFailed] 里如实回告「已达工具调用上限 N，任务未完成」。
  final int maxToolCalls;

  /// 是否启用计划工具（`write_todos`）。
  ///
  /// `PlanMode.auto` = 注入工具但**让模型自己决定用不用**。
  /// 不用 `PlanMode.must` —— 那是"教练式"提示，强模型不需要，弱模型也学不会。
  final bool enablePlan;

  /// 额外系统提示（追加在默认提示之后）。
  final List<String> systemPrompts;

  /// **结构化三作用域记忆**（2026-10-29 三作用域重设计；**非空时优先**）。
  ///
  /// 由宿主在每次 run 之前读好三处（global / workspace / session）并解析成
  /// [MemoryContext] 传进来（App 侧是 `ScopedMemoryService` + `LocalAgentExecutor`）。
  ///
  /// ## 为什么从 `memoryNote`（一段字符串）改成结构化
  ///
  /// 字符串拼接 = backend 无法做预算、排序与冲突裁决，只能信任宿主；
  /// 而宿主是 Flutter 层，验证强度只有 `flutter test`。结构化之后
  /// 选择/预算/渲染都在 backend 纯 Dart（`memory_prompt.dart`），
  /// 可以被 `dart test` 覆盖 —— 抗幻觉要由架构保证，不靠提示词。
  ///
  /// ## 注入规则（见 `_buildSystemPrompts`）
  ///
  /// · **本字段非空（含全段为空的对象）⇒ 走新渲染器，[memoryNote] 被忽略**；
  /// · 本字段为 `null` ⇒ 回落 `memoryNote`（旧行为，兼容）；
  /// · 两者都不传 ⇒ 行为与加记忆字段之前**完全一致**。
  ///
  /// ## 注入顺序与预算
  ///
  /// global → workspace → session（session 最后 = 最容易变，缓存损失最小），
  /// global+workspace 共享 `ContractMemory.globalWorkspaceInjectMaxChars`、
  /// session 独立 `sessionInjectMaxChars`，两者再按
  /// `min(常量, modelWindowTokens × windowRatioCap)` 自适应。
  /// 详见 `memory_prompt.dart`。
  final MemoryContext? memory;

  /// **长期记忆原文**（跨会话沉淀的项目知识与用户偏好）。
  ///
  /// ⚠️ `@Deprecated`（2026-10-29）：新宿主请用 [memory]（结构化三作用域）。
  /// 本字段**不删**（CLI / 既有测试 / 未升级的宿主仍在用），行为与旧版一致：
  /// `null` 或 trim 后为空 ⇒ 不注入。
  ///
  /// 由宿主（App 的 `GlobalMemory`）在每次 run 之前读好传进来。
  ///
  /// ## 为什么它是 `RunOptions` 的字段，而不是走 `systemPrompts`
  ///
  /// 两个理由：
  /// 1. **语义不同**：`systemPrompts` 是"宿主想追加的固定提示"（通常在一次
  ///    会话里不变）；记忆是**每轮都可能变**的数据。混在一起会让人以为它
  ///    也是静态的。
  /// 2. **注入位置有讲究**：记忆必须拼在默认提示**之后**（见
  ///    `_buildSystemPrompts`）—— 这样默认提示那一段字节不变，缓存前缀
  ///    只在记忆真的变化时才失效。
  ///
  /// ## 缓存代价（必须知道，别以为免费）
  ///
  /// 记忆是**进 system 消息**的 ⇒ 它一变，请求前缀就变。新路径下
  /// 只有 session 段是易变的，global/workspace 稳定段在前，缓存损失更小。
  @Deprecated('用 memory（MemoryContext）替代；本字段仅为兼容保留，不删')
  final String? memoryNote;

  /// **审批档位**（2026-10-24 接线）—— 决定哪些工具执行前要过用户批准。
  ///
  /// ## ⚠️ 库默认值是 [ApprovalMode.fullAccess]（不拦），这是有意的
  ///
  /// 库（backend 包）无法假设宿主有没有 UI：CLI、单测、脚本场景里
  /// 没有"用户"可问，若默认 `manual`，所有会改状态的工具会被
  /// fail-closed 拒掉 —— 既有测试与 CLI 全部变红。所以**库默认 = 旧行为**，
  /// 而把"必须传更严档位"的责任交给**有 UI 的宿主**：
  /// App 的 `LocalAgentExecutor` 恒从 `settings.permission` 显式映射，
  /// 不依赖这里的默认值。
  ///
  /// 实际的拦截由 [_ApprovalHook] 执行；"问谁"由宿主注入的
  /// `AskGate.requestApproval` 决定（白名单也在宿主侧）。
  final ApprovalMode approvalMode;

  /// **子代理**（2026-10-24 接线，H6）—— 开启后模型可以用 `delegate_task`
  /// 把子任务派给一个**干净上下文**的 worker，主上下文只收回最终结论。
  ///
  /// ## 为什么默认关
  ///
  /// 库默认 = 旧行为（21 个工具、无派生），与既有测试/CLI 兼容；
  /// 有 UI 的宿主显式开启（App 传 true）。
  ///
  /// ## 隔离语义（见 [_workerSubAgent]）
  ///
  /// · worker 是**全新 AgentState**（看不到主对话）—— 真隔离，不是 clone；
  /// · worker 的过程事件走**独立事件总线**，就地丢弃 —— 主线程的用量记账
  ///   与 UI 不被污染；
  /// · **hooks 继承**：审批 hook 与预算 hook 是同一个对象 ⇒ worker 的危险
  ///   操作照样弹窗、worker 的调用照样计入任务总预算（防止"派子代理绕过
  ///   预算"）；
  /// · worker 禁止再派生（`disableSubAgents`）—— 深度恒为 1。
  final bool enableSubAgents;

  /// **内置技能**（2026-10-24 接线，S1/S2/S3 的 Skill 层）。
  ///
  /// 开启后系统提示里有技能目录（一行一条），模型按任务用
  /// activate_skills 按需加载全文（渐进披露）—— 平时只花目录的成本。
  /// 库默认关（旧行为）；App 显式开启。清单见 [builtinSkills]。
  final bool enableSkills;

  /// 见 [RunOptions.traceDir] 的 KDoc（E4）。
  final String? traceDir;

  /// **自动提炼记忆**（M5，2026-10-25；默认 false）。
  ///
  /// 开启后任务收尾时用一次**摘要调用**从对话中提炼"值得跨会话保留的
  /// 事实"并写入长期记忆。代价 = 每 run 一次小模型调用 —— opt-in，
  /// 由宿主决定是否承担。失败静默（记忆是锦上添花）。
  final bool autoExtract;

  /// **自验证命令**（H3/K2，2026-10-25；默认 null = 不验证）。
  ///
  /// 设置后：文件写/编辑**成功**时自动经 shell 执行该命令，输出附在
  /// 工具结果里回给模型 —— 模型看到失败立刻修，形成 改→验→修 闭环
  /// （架构级自验证，不靠提示词劝）。无 shell 能力时静默跳过。
  final String? verifyCommand;

  /// **计划模式**（P1，2026-10-25；默认 [PlanMode.auto] = 旧行为）。
  ///
  /// `must` = 架构强制显式分解（框架教练式：模型必须先产出计划才能动工具）
  /// —— 供宿主对"复杂任务不许即兴跑"的场景显式开启；默认 auto 不强制。
  final PlanMode planMode;

  /// **计划前置门禁**（P1，2026-10-25；默认 false）。
  ///
  /// 框架的 `PlanMode.must` 与 auto 行为一致（核查过）—— 这个门禁是我们
  /// 自己的：开启后，模型在产出**第一份计划**（write_todos）之前，
  /// 一切执行类工具调用都被拒绝（读类工具与 ask_user 放行——先看清楚
  /// 再计划）。一旦计划存在，门禁永久放行（模型可自由更新计划）。
  /// "复杂任务不许即兴跑"的架构强制。
  final bool requirePlan;

  /// **连续失败反思**（P3，2026-10-25；默认 0 = 关）。
  ///
  /// 工具连续失败达到这个次数时，注入一条反思指令（"停下来分析根因、
  /// 换方法，不要原样重试"）—— 反思环节由架构触发，不靠模型自觉。
  /// 成功一次即重置计数。
  final int reflectOnFailures;

  /// **MCP 服务器配置**（A1，2026-10-25；默认空 = 不接）。
  ///
  /// 每项 = 一个 MCP 端点（stdio 命令或 HTTP/SSE URL）。非空时
  /// `HeraclesAgent.run` 前先 `McpManager.connectAll`（连不上单个跳过
  /// 并记日志，不炸 run），框架自动注入三层渐进披露：
  /// 目录（系统提示）→ mcp_list_tools 发现 → mcp_call_tool 执行。
  /// run 结束 disconnectAll（MCP 会话不跨 run 存活）。
  final List<Map<String, dynamic>> mcpServers;

  /// **降级模型链**（D3，2026-10-25；默认空 = 不降级）。
  ///
  /// 主模型连续失败（网络/限流/超时）且重试耗尽后，按序切换到
  /// 列表中的备用模型继续当前任务 —— "不把错误直接甩给用户"的落地。
  /// 每个降级发生时播 [HeraclesFallback] 事件（UI 可见"已降级到 X"）。
  ///
  /// ⚠️ 成本说明：备用模型用的是**同一个 provider 配置**（同 baseUrl/Key），
  /// 只是模型名不同 —— 不产生额外费用来源；切换后该 run 内继续用新模型。
  final List<String> fallbackModelNames;

  /// **完成门禁**（P4，2026-10-25；默认 false）。
  ///
  /// 与 [verifyCommand] 配套：本轮发生过文件写/编辑且最后一次自动验证
  /// **失败**时，拒绝任务收尾（onTurnCompletion continueRun），模型必须
  /// 回到修复循环 —— "带病收尾"被架构拦下。默认关（无 verifyCommand 无意义）。
  final bool verifyGateCompletion;
}

/// **组装好的 Agent**。
class HeraclesAgent {
  /// ## 为什么这里用「显式初始化列表」而不是 initializing formal
  ///
  /// `lints` 的 `prefer_initializing_formals` 建议写成 `this._config`，
  /// 但**命名参数不能以下划线开头**（Dart 直接报
  /// "Named parameters can't start with an underscore"）⇒
  /// 想用 `this._x` 就必须把字段改成公开的，那会把 [HeraclesAgent] 的
  /// 内部状态暴露成可变 API。这里选择保留私有字段 + 公开的命名参数，
  /// 逐条 ignore 这条规则（形状相同的误报，不是"懒得改"）。
  ///
  /// 注意只有 4 处真的会触发：`_caps = capabilities` 与
  /// `_injectedClient = client` 的参数名与字段名不同，本来就不该报。
  HeraclesAgent({
    required BackendConfig config,
    required Capabilities capabilities,
    RunOptions options = const RunOptions(),
    StateStorage? stateStorage,
    AskGate? askGate,
    LLMClient? client,
  })  : _config = config, // ignore: prefer_initializing_formals
        _caps = capabilities,
        _options = options, // ignore: prefer_initializing_formals
        _stateStorage = stateStorage, // ignore: prefer_initializing_formals
        _askGate = askGate, // ignore: prefer_initializing_formals
        _injectedClient = client;

  final BackendConfig _config;
  final Capabilities _caps;

  /// 本次 `run` 开始时探测到的沙箱就绪状态（2026-10-29）。
  ///
  /// 为什么缓存：事件回调是**同步路径**，不能在里面 `await` 探测。
  /// 每次 `run` 开头探一次就够 —— 一次运行期间沙箱不会突然装好/卸掉。
  /// `null` = 还没探测过（等价于"未就绪"）。
  bool? _sandboxReadyForRun;

  /// 提问门禁（UI 注入）。传 null 表示当前环境不能问用户。
  final AskGate? _askGate;
  final RunOptions _options;
  final StateStorage? _stateStorage;

  /// 注入的 LLM client（测试 / 回放用）。
  ///
  /// `null` = 按 [BackendConfig.provider] 现建一个。**这只是"给一个替身的机会"**，
  /// 不改变任何生产路径的语义：不传就完全走原来的建法。
  final LLMClient? _injectedClient;

  /// 当前状态（agent 循环的持久化载体）。
  ///
  /// 由框架维护：`history` / `plan` / `usages` / `metadata` 都在里面。
  /// **不要自己再存一份** —— 两份状态必然分叉。
  AgentState? _state;

  /// 当前状态（只读视图，给 CLI / 宿主看 turn 数与用量）。
  AgentState? get state => _state;

  /// 建 LLM client。
  LLMClient _buildClient() {
    final injected = _injectedClient;
    if (injected != null) return injected;
    return buildClientFor(_config);
  }

  /// 按 [BackendConfig] 建 client（静态：/compact 的摘要调用也用它）。
  static LLMClient buildClientFor(BackendConfig config) {
    return switch (config.provider) {
      BackendProvider.openAiCompatible => OpenAIClient(
          apiKey: config.apiKey,
          baseUrl: config.baseUrl,
        ),
      BackendProvider.anthropic => ClaudeClient(
          apiKey: config.apiKey,
          baseUrl: config.baseUrl,
        ),
      BackendProvider.openAiResponses => ResponsesClient(
          apiKey: config.apiKey,
          baseUrl: config.baseUrl,
        ),
    };
  }

  ModelConfig _modelConfig({String? model}) => ModelConfig(
        model: model ?? _config.modelName,
        maxTokens: _config.maxOutputTokens,
        temperature: _config.temperature,
        // 推理档位走框架的通用 extra 通道（见 BackendConfig.reasoningEffort）
        extra: _config.reasoningEffort == null
            ? null
            : <String, dynamic>{'reasoning_effort': _config.reasoningEffort},
      );

  /// **会话摘要**（/compact 用，2026-10-24）—— 一次性 LLM 调用，不进 agent 循环。
  ///
  /// ## 为什么是静态独立方法
  ///
  /// /compact 发生在**两次 run 之间**（用户在输入框敲 /compact）：
  /// 此刻没有 agent 实例、没有 state，只有会话文件里的文本。
  /// 摘要只需要"一段文本进、一段文本出"，走一次裸 `generate` 最省。
  ///
  /// ## 摘要什么（给摘要器的指令要点）
  ///
  /// 保留：用户目标与约束 / 改过的文件与内容 / 关键结论（文件名、行号、
  /// 报错原文、命令返回值）/ 未完成事项。丢弃：寒暄、过程叙述、重复。
  /// 这与压缩摘要的 [summaryEmphasis] 同一立场：**工具的具体结论不能丢**。
  ///
  /// 失败（网络/超时）向上抛，由宿主决定怎么告知 —— **绝不静默返回空**：
  /// 空摘要写进标记行 = 用户以为压了、实际全丢了。
  static Future<String> summarizeTranscript({
    required BackendConfig config,
    required String transcript,
    int maxChars = 4000,
    LLMClient? client,
  }) async {
    // `client` 注入点（测试替身用）；生产不传 ⇒ 按配置现建。
    final llm = client ?? buildClientFor(config);
    final system = '你是开发会话的摘要器。把用户给出的会话记录压缩成要点摘要，'
        '供智能体下次继续工作使用。\n'
        '必须保留：\n'
        '1. 用户的目标与约束；\n'
        '2. 已修改/创建的文件，各自改了什么；\n'
        '3. 关键结论（文件名、行号、报错原文、命令返回值）；\n'
        '4. 未完成事项与卡点。\n'
        '丢弃：寒暄、重复、与任务无关的过程叙述。\n'
        '直接输出摘要正文，不要开场白和标题，全文不超过 $maxChars 字符。';
    final msg = await llm.generate(
      [
        SystemMessage(system),
        UserMessage.text(transcript),
      ],
      modelConfig: ModelConfig(
        model: config.modelName,
        maxTokens: 2048,
        temperature: 0.2,
      ),
    );
    return (msg.textOutput ?? '').trim();
  }

  /// **自动提炼记忆**（M5，2026-10-25）—— 任务收尾时从对话中提炼事实。
  ///
  /// 每行一条事实（只收"跨会话有用"的：约定/偏好/踩坑），最多 [max] 条；
  /// 没有值得记的就返回空 —— **绝不硬凑**。解析容错：剥 '- ' 与序号前缀。
  static Future<List<String>> extractMemories({
    required BackendConfig config,
    required String transcript,
    LLMClient? client,
    int max = 3,
  }) async {
    final llm = client ?? buildClientFor(config);
    final msg = await llm.generate(
      [
        SystemMessage('你是记忆提炼器。从开发会话记录里提炼"值得跨会话保留的'
            '事实"（项目约定、用户偏好、踩过的坑），每行一条、以 "- " 开头，'
            '最多 $max 条。只收确定性结论，不收过程叙述；'
            '没有值得记的就输出空。不要输出任何其他内容。'),
        UserMessage.text(transcript),
      ],
      modelConfig: ModelConfig(model: config.modelName, maxTokens: 512),
    );
    final out = <String>[];
    for (var line in (msg.textOutput ?? '').split('\n')) {
      line = line.trim();
      if (line.startsWith('- ')) line = line.substring(2);
      line = line.replaceAll(RegExp(r'^\d+\.\s*'), '');
      if (line.length >= 6) out.add(line);
      if (out.length >= max) break;
    }
    return out;
  }

  /// 结构化笔记落盘（C3/M2）：每次压缩追加一节（时间戳 + 前后规模 +
  /// 保留段的要点摘录）。追加式 —— 笔记本身是任务的"黑匣子记录"。
  static Future<void> _appendNote(
    WorkspaceCapability? ws,
    String sessionId,
    int beforeMessages,
    int beforeTokens,
    int afterTokens,
  ) async {
    if (ws == null) return;
    try {
      const notesDir = '.heracles/notes';
      final path = '$notesDir/$sessionId.md';
      await ws.mkdir(notesDir);
      final existing = await ws.read(path);
      final header = existing is CapabilitySuccess &&
              existing.data.trim().isNotEmpty
          ? '\n\n---\n'
          : '# 任务笔记（自动沉淀：每次上下文压缩时追加）\n';
      final ts = DateTime.now().toIso8601String();
      final note = '$header'
          '## $ts（压缩：$beforeMessages 条 / $beforeTokens→$afterTokens token）\n'
          '--- 以下为压缩时的保留段要点（完整的中间结论在模型记忆里）：\n'
          '（此节为压缩事件记录；详细快照见模型 episodic memory）\n';
      await ws.write(path, existing is CapabilitySuccess ? existing.data : '');
      // read+write 全量覆盖式追加（能力层无 append 原语）—— 笔记量小，可接受
      await ws.write(
          path,
          (existing is CapabilitySuccess ? existing.data : '') + note);
    } catch (_) {
      // 静默：笔记失败不影响压缩主链路
    }
  }

  /// 读类工具清单（P1 门禁放行用）：只看不改的都算。
  static bool _isReadTool(String tool) => const {
        'read_file',
        'list_files',
        'find_files',
        'grep_files',
        'web_fetch',
        'check_device_state',
        'ask_user',
        'save_memory',
        'activate_skills',
        'deactivate_skills',
      }.contains(tool);

  /// **上下文构成**（C5，2026-10-24）—— 三块的**估算** token。
  ///
  /// ## 为什么是估算
  ///
  /// 此刻没有 provider 上报值；与压缩器同一套估算规则
  /// （CJK≈1字/token，ASCII≈4字符/token）。UI 必须标"估算"，
  /// 别让用户拿它跟"命中率"（provider 上报口径）对账。
  ///
  /// ## `system` 含什么
  ///
  /// 默认提示 + 宿主追加 + 工作区宪法/快照 + 长期记忆 —— 全部进 system 消息，
  /// 所以合成一块单列（再拆就要跨层穿透，不值得）。
  /// ## 键（INTERFACE.md N2，2026-10-24：固定 7 个，只许新增不许改名）
  ///
  /// · `system`：默认提示 + 宿主追加 + 宪法/快照 + 长期记忆（都进 system 消息）；
  /// · `toolDefs`：工具定义（toolsHistory 最后一次快照）；
  /// · `user` / `assistant` / `toolResults`：按历史消息类型拆分；
  /// · `reasoning`：恒 0 —— thought **不回放**（session_history 取舍②），
  ///   历史里没有推理内容可估；
  /// · `summary`：恒 0 —— 压缩快照在历史里是普通 ModelMessage，结构上
  ///   无法与 assistant 正文区分（框架不给标记），如实给 0 并入 assistant。
  ///
  /// ## 后两块为什么是 0 也要给
  ///
  /// N2：前端环图只认固定键名 —— 0 也是"这一类存在但当前为空"的如实
  /// 表达，比缺席（前端并入"其他"）更诚实。
  Map<String, int> contextBreakdown() {
    final st = _state;
    if (st == null) return const <String, int>{};
    var system = 0;
    for (final p in _buildSystemPrompts()) {
      system += WindowRatioCompressor.estimateText(p);
    }
    var user = 0;
    var assistant = 0;
    var toolResults = 0;
    for (final m in st.history.messages) {
      switch (m) {
        case UserMessage():
          user += WindowRatioCompressor.estimateMessageTokens(m);
        case ModelMessage():
          assistant += WindowRatioCompressor.estimateMessageTokens(m);
        case FunctionExecutionResultMessage():
          toolResults += WindowRatioCompressor.estimateMessageTokens(m);
        default:
          break;
      }
    }
    return <String, int>{
      'system': system,
      'toolDefs': WindowRatioCompressor.estimateToolDefinitions(st),
      'toolResults': toolResults,
      'reasoning': 0,
      'assistant': assistant,
      'user': user,
      'summary': 0,
    };
  }

  /// 构建全部工具（**33 个**）。
  ///
  /// 33 的来源：**各 builder 实际返回数之和**，不是估的 ——
  /// 断言见 `test/tools_completeness_test.dart`（"必须恰好 33 个"）：
  /// `buildFileTools` 8 + `buildShellTools` 1 + `buildFileManageTools` 3 +
  /// `buildInfoTools` 2 + `buildApkTools` 5 + `buildInteractionTools` 3 +
  /// `buildGitTools` 11 = 33。
  ///
  /// 历史：旧注释写"18 个"（审计 §3.3 #1）；2026-10-27 加 git 后 21 → 32；
  /// **2026-10-29 记忆三作用域重设计**加 `propose_global_memory` 后 32 → 33
  /// （`save_memory` 新增可选 `scope`，工具数不变）。
  ///
  /// ## git 工具为什么**无条件**列出（不是 caps.git != null 才加）
  ///
  /// 与 APK 五件套同一条纪律（见 `tool_factory.dart` 的 "缺能力也让工具可见"）：
  /// 不列出来 ⇒ 模型从历史里见过这些工具名、会凭记忆乱调 ⇒ 报"未知工具"，
  /// 比"明确说当前环境不支持"更难排查。
  ///
  /// ## 分组顺序即日志阅读顺序：**高频基础 → 危险手段 → 长耗时 → 交互 → 版本控制**
  List<Tool> _buildTools({Future<String> Function()? verify}) {
    final factory = ToolFactory(_caps);
    // ★ H3/K2（2026-10-25）：verifyCommand 配置后，写/编辑成功自动跑
    //   验证命令（经 shell 能力），输出附在工具结果里回给模型。
    // ★ "先读再改"记账（K1，2026-10-24）：与工具列表同生命周期 ——
    //   App 每次 run 新建 agent ⇒ 恰好 run 级；CLI/测试复用实例 ⇒ 会话级
    //   （从宽取向：读过的文件跨 run 仍算读过）。
    final tracker = EditReadTracker();
    return [
      ...buildFileTools(factory, _caps, tracker: tracker, verify: verify),        // 8 个：读/写/编辑/补丁/列/建目录/找/搜
      ...buildShellTools(factory, _caps),       // 1 个：run_shell_command
      ...buildFileManageTools(factory, _caps, tracker: tracker),  // 3 个：删除/移动/复制（有破坏性）
      ...buildInfoTools(factory, _caps),        // 2 个：web_fetch / check_device_state
      ...buildApkTools(factory, _caps),         // 5 个：构建/反编译/重打包/签名/安装
      ...buildInteractionTools(factory,         // 3 个：ask_user / save_memory / propose_global_memory
          askGate: _askGate, caps: _caps),
      ...buildGitTools(factory, _caps),         // 11 个：5 只读 + 4 改本地 + push + init
    ];
  }

  /// **组装 system prompts** —— 默认提示 → 宿主追加 → 长期记忆（三段记忆）。
  ///
  /// ## 顺序不能乱
  ///
  /// 1. `defaultSystemPrompt(_caps)` —— 人设与环境（**字节稳定**，除非能力变了）
  /// 2. `_options.systemPrompts` —— 宿主追加的固定提示
  /// 3. 长期记忆（**放在最后**）：
  ///    · [RunOptions.memory] 非空 ⇒ `renderMemoryContext`（global → workspace →
  ///      session，session 最后 = 最易变）；段内已含来源标注与冲突尾注；
  ///    · 否则回落 [RunOptions.memoryNote]（旧单段渲染，行为不变）。
  ///
  /// ## 为什么记忆必须放最后而不是最前
  ///
  /// 框架 `composeSystemMessage()` 会把这些片段 **`join('\n\n')` 成一条**
  /// SystemMessage，它位于整条请求的**最开头** —— 也就是缓存前缀的最前段。
  ///
  /// - 放最前 ⇒ 记忆一变，**后面所有人设与环境文字的前缀位置全部偏移**，
  ///   那一轮的缓存几乎全废；
  /// - 放最后 ⇒ 前面那两段字节**完全不变**，只有尾部这一段变。
  ///
  /// 前缀缓存的匹配是"最长公共前缀"，所以**把易变的部分尽量往后放**是
  /// 唯一能少付代价的做法。这也解释了为什么 `memoryNote` 没被塞进
  /// `defaultSystemPrompt()` 里。
  ///
  /// ## [task] 为什么是参数
  ///
  /// 记忆是**检索式注入**：按当前任务的关键词排序（见 `memory_prompt.dart`）。
  /// 同一份 [RunOptions.memory] 在不同任务下渲染结果可能不同（这是检索式注入
  /// 的固有代价：随任务变化的那一轮前缀缓存会重建）。`contextBreakdown()`
  /// 没有任务上下文 ⇒ 传空串（纯 `createdAt` 排序），只用于估算。
  List<String> _buildSystemPrompts({String task = ''}) {
    final prompts = <String>[
      defaultSystemPrompt(_caps),
      ..._options.systemPrompts,
    ];

    // trim 后再判空：模型/存储可能塞进纯空白，那种情况不该注入一个空段落
    // （空段落会白白改变前缀字节，却不带任何信息）。
    final memory = _options.memory;
    if (memory != null) {
      // ★ 2026-10-29 新路径：结构化三作用域。
      //   注意"非空优先"是**字段非空**优先 —— 即使三段都空也不回落 memoryNote，
      //   否则"宿主已升级、本轮恰好没记忆"会突然冒出旧格式的全局原文。
      final rendered = renderMemoryContext(
        memory,
        task: task,
        windowTokens: _config.modelWindowTokens,
      );
      if (rendered.trim().isNotEmpty) prompts.add(rendered);
    } else {
      // ignore: deprecated_member_use_from_same_package
      final note = _options.memoryNote;
      if (note != null && note.trim().isNotEmpty) {
        prompts.add(renderMemory(note));
      }
    }
    return prompts;
  }

  /// **跑一次完整任务**，边走边播事件。
  ///
  /// 返回的 Stream 在任务结束时关闭。取消用 `cancelToken`。
  ///
  /// ## 顺序（bug #2 的修法）
  ///
  /// 1. 建桥（`StreamController`，**不 await 它的 close**）
  /// 2. **先把 run 驱动起来**（`_drive` 是个不等待的 Future）
  /// 3. 再 `yield* bridge.stream` 消费 —— 此时监听者已挂上
  ///
  /// 第 2 步先于第 3 步是关键：即便 `_drive` 在第一个 await 前就同步写了几个
  /// 事件，`StreamController` 也会缓冲它们，等第 3 步订阅后按序吐出。
  /// ## [history]：**跨轮记忆的唯一入口**
  ///
  /// 不传 ⇒ 行为与以前完全一样（每次 run 都从空 state 开始）。
  /// 传了 ⇒ 这些消息会**原样成为 `state.history` 的开头**，本轮的用户请求
  /// 追加在它们**之后**（append-only，绝不重排 —— 前缀缓存靠它）。
  ///
  /// ### 为什么必须由调用方注入，而不是这里自己去读会话文件
  ///
  /// 后端是**纯 Dart 包，不碰存储**（`heracles_backend.dart` 的硬约束：
  /// 不 import Flutter / 不 import dart:ui，也不该知道 SAF 或 `.jsonl` 在哪）。
  /// 会话存储由宿主（App 的 `SessionStore` / 将来的 CLI）负责，
  /// 这里只接受"已经翻译好的框架消息"。
  ///
  /// ### 传进来的历史**不做校验、不做去重**
  ///
  /// 因为校验必然要猜（"这条 assistant 算不算数"），而猜错会静默改坏上下文。
  /// 责任边界很硬：**调用方保证 history 是干净的、按时间正序、且不含本轮请求**。
  /// 若把本轮请求也塞进来，模型会看到两遍同一条用户消息 —— 见
  /// `LocalAgentExecutor` 里"排除本轮刚写进去的 user 行"那段。
  Stream<HeraclesEvent> run(
    String userRequest, {
    List<LLMMessage>? history,
    /// **图片输入**（2026-10-23 补：此前这里只有 String，
    /// 附件在 App 侧就被丢掉了 —— 模型根本收不到图）。
    ///
    /// 用 [ImageInput]（base64 + mime）而不是框架的 `ImagePart`：
    /// 宿主不该依赖 `dart_agent_core`（见 `multimodal.dart` 的说明）。
    ///
    /// 调用方负责**能力判断**（模型不支持视觉时不要传，否则 provider 会 400
    /// 或静默忽略 —— 后者更糟，用户会以为模型看过图）。
    List<ImageInput>? images,
    CancelToken? cancelToken,
  }) async* {
    final bridge = StreamController<HeraclesEvent>();

    // ★ 2026-10-29：run 开始时探一次沙箱就绪状态（给工具卡标题用）。
    //   探测失败按"未就绪"处理 —— 事件层的提示宁可保守，也不要骗 UI 说在沙箱里跑。
    _sandboxReadyForRun = null;
    final sandbox = _caps.sandbox;
    if (sandbox != null) {
      try {
        _sandboxReadyForRun = await sandbox.isReady();
      } catch (_) {
        _sandboxReadyForRun = false;
      }
    }

    // 驱动整个 run（它自己负责把事件写进 bridge，并在结束时 close）。
    final runner = _drive(
      userRequest,
      bridge,
      history: history,
      images: images,
      cancelToken: cancelToken,
    );

    try {
      yield* bridge.stream;
    } finally {
      // 消费端提前取消时也要等生产者收尾，避免留下悬空的 run。
      await runner;
    }
  }

  /// 构造本轮的首条用户消息：**文本 + 可选图片**。
  ///
  /// ## 为什么单独抽出来
  ///
  /// 旧实现是 `[UserMessage.text(userRequest)]` —— 硬编码成**纯文本**，
  /// 于是无论 App 侧传了什么附件，模型都只看得到文字。
  /// 用户那句质问（"大模型都有识图，为什么给 agent 后就不能了？"）的
  /// 最后一环就在这行。
  ///
  /// ## 顺序
  ///
  /// `[TextPart(用户文字), ...图片]` —— 文字在前，图在后。
  /// 用户问"这张图里是什么"时，先读问题再看图，符合对话直觉；
  /// 反过来（图在前）部分模型会把图当成"历史附件"而忽略。
  ///
  /// ## 没有图片时
  ///
  /// 完全走老路径（`UserMessage.text`），**不改动既有行为**。
  List<LLMMessage> _firstMessage(
    String userRequest,
    List<ImageInput>? images,
  ) {
    if (images == null || images.isEmpty) {
      return [UserMessage.text(userRequest)];
    }
    return [
      UserMessage(<UserContentPart>[
        TextPart(userRequest),
        ...buildImageParts(images),
      ]),
    ];
  }

  /// 真正的执行体：框架循环 → 事件桥。
  Future<void> _drive(
    String userRequest,
    StreamController<HeraclesEvent> bridge, {
    List<LLMMessage>? history,
    List<ImageInput>? images,
    CancelToken? cancelToken,
  }) async {
    final emit = _Emitter(bridge);
    final wallClock = Stopwatch()..start();
    var totalToolCalls = 0;
    var budgetReached = false;

    /// **最新计划步骤**（B8 P0，2026-10-30）：`PlanChangedEvent` 处缓存。
    ///
    /// 终态收尾时据此判断"计划是否真的做完了"（全部 `done`/`cancelled`）。
    /// 空 = 本轮从来没有计划 ⇒ 终态**不发** `plan_closed`。
    var lastPlanSteps = const <HeraclesPlanStep>[];

    /// `plan_closed` 是否已经发过（三处收尾共用 **一个** helper ⇒ 只发一次）。
    ///
    /// 为什么要有这个闩：成功分支在 `try` 里发、失败分支在 `catch` 里发，
    /// 而框架"先抛异常再走 catch"的路径可能让收尾被走到多次（降级重跑也会
    /// 重新进 `try`）。没有闩就会重复播同一个终态，UI 会收到两条 plan_closed。
    var planClosedEmitted = false;

    /// **统一发计划终态**（B8 P0）：无计划不发，已有过不发。
    ///
    /// [reachedGoal] = 计划里每一步都 `done`/`cancelled`；
    /// [reason] 只在 `false` 时给人话（取消/失败/中断），**不带堆栈/内部 id**。
    void emitPlanClosed({required bool reachedGoal, String? reason}) {
      if (lastPlanSteps.isEmpty) return;
      if (planClosedEmitted) return;
      planClosedEmitted = true;
      emit(HeraclesPlanClosed(reachedGoal: reachedGoal, reason: reason));
    }

    /// **本轮模型最后一次给出的正文**（`AfterCallLLMEvent` 捕获）。
    ///
    /// `null` = 本轮模型一次正文都没出（纯工具调用轮 / 异常 / 预算耗尽）。
    ///
    /// ## 为什么这个值比"倒扫 history"可靠
    ///
    /// 它是**事件流里的真实输出**，不受历史被压缩改写的影响：
    /// - 压缩把 `state.history.messages` 截短 ⇒ 倒扫会越界变空；
    /// - 压缩往头部插 ack ⇒ 倒扫会把英文客套话当答案。
    ///
    /// 这两个坑都只在"压缩真的发生过"的 run 里现形，所以以前没被测出来。
    String? lastTurnText;

    /// 框架自己播报过的失败原因（`OnAgentExceptionEvent` / `OnAgentErrorEvent`）。
    ///
    /// 只用来**排障**与**兜底措辞**，不再直接播成 `HeraclesFailed` ——
    /// 否则同一条失败会播两遍（见下面两个 `controller.on<…>` 的注释）。
    String? frameworkError;
    final pendingToolStart = <String, Stopwatch>{};

    final client = _buildClient();
    final controller = AgentController();

    // ---- 把框架的 Controller 事件转成我们的 HeraclesEvent ----
    controller.on<LLMChunkEvent>((e) {
      // ⚠️ 字段是 `response`（ModelMessage），不是 `chunk`
      //
      // ★ 2026-10-22：思考（`thought`）现在**单独成一条事件** ★
      //
      // ## 为什么以前一个字都不取、现在取
      //
      // 以前的注释写着"旧实现有过'思考被当答案'的事故"。但那个事故的**真原因
      // 不是"取了 thought"，而是"把 thought 和正文混成一路"**。
      // ⇒ 正确做法是**分开取、分开播**，而不是干脆不取：
      //
      // · `HeraclesThoughtDelta` ⇒ UI 的「思考」行（默认折叠，想看点开）
      // · `HeraclesTextDelta`    ⇒ 正文（最终回答**只认它**）
      //
      // ⚠️ 纪律：这两条在 App 侧也必须保持分离，**永远不许合并**。
      final thought = e.response.thought;
      if (thought != null && thought.isNotEmpty) {
        emit(HeraclesThoughtDelta(thought));
      }
      final text = e.response.textOutput;
      if (text != null && text.isNotEmpty) {
        emit(HeraclesTextDelta(text));
      }
    });
    controller.on<LLMRetryingEvent>((e) {
      // ⚠️ 字段是 `reason`（String），不是 `error`
      emit(HeraclesRetrying(e.reason));
    });
    controller.on<AfterToolCallEvent>((e) {
      totalToolCalls++;
      // ⚠️ 耗时按 **call id** 配对，不按工具名 ——
      //    框架是 `Future.wait` 并行执行，同名调用的耗时按名字取必然错乱。
      final sw = pendingToolStart.remove(e.result.id);
      emit(HeraclesToolFinished(
        toolName: e.result.name,
        isError: e.result.isError,
        output: _flattenContent(e.result.content),
        durationMs: sw?.elapsedMilliseconds ?? 0,
        metadata: e.result.metadata,
        id: e.result.id,
      ));
    });
    controller.on<PlanChangedEvent>((e) {
      final plan = e.plan;
      final steps = [
        for (final s in plan.steps)
          HeraclesPlanStep(s.description, _mapStatus(s.status)),
      ];
      // B8 P0：缓存最新计划 —— 收尾时据此判定 reachedGoal。
      lastPlanSteps = steps;
      emit(HeraclesPlanUpdated(steps: steps));
    });
    controller.on<AfterCallLLMEvent>((e) {
      // ★★ 2026-10-23：**在这里捕获本轮正文**（比"结束时倒扫历史"可靠得多）★★
      //
      // ## 为什么必须改成捕获，而不是倒扫 `state.history`
      //
      // 旧实现是 run 结束时"从历史末尾倒着找第一条有正文的 ModelMessage"。
      // 上下文压缩一旦发生，这条就同时踩两个坑：
      //
      // 1. **历史被截短** ⇒ 越界守卫 `startIndex >= msgs.length` 直接返回空串
      //    ⇒ 压缩过的那一轮**最终回答变成空**（UI 上"模型答完了但没有回答"）。
      // 2. **框架会往保留段头部插一条 ack**：
      //    `ModelMessage(textOutput: "Got it. Thanks for the additional context!")`
      //    （`context_compressor.dart:175-178`）。倒扫会把这句**英文客套话
      //    当成最终回答显示给用户** —— 这正是本项目反复警告的"假信息"。
      //
      // ## 为什么 AfterCallLLMEvent 天然排除这两件事
      //
      // 它由框架的**主循环**在每次模型调用后 publish（`stateful_agent.dart:1173`）。
      // 而压缩器的摘要调用是 `LLMBasedContextCompressor` 内部直接
      // `client.generate(...)`，**不经过主循环、不 publish 这个事件** ⇒
      // 摘要调用与那条 ack 都不会被捕获。这是结构上的保证，不是靠字符串匹配。
      //
      // ## 为什么只保留"最后一条有正文的"
      //
      // 一轮里可能有多条 ModelMessage（先出工具调用、再出正文）。用户看到的
      // "最终回答"是**最后一条有正文的**那条。空正文的（纯工具调用轮）跳过。
      final text = e.response.textOutput;
      if (text != null && text.trim().isNotEmpty) {
        lastTurnText = text;
      }

      // ★ 2026-10-22：**逐轮用量记账**（此前完全缺失 —— 旧 Kotlin 的
      // `TurnRecord.cachedTokens/promptTokens/outputTokens` 在迁移中丢了，
      // 导致 App 的用量面板/顶栏命中率/右侧边栏全部"不可用"）。
      //
      // 数据源是框架 `ModelMessage.usage`（provider 上报的原值）。
      // ⚠️ 缓存字段必须区分**"上报了 0"与"没上报"**（`02-契约规范` §3.4：
      // 未上报时 UI 必须显示"不可用"，**不得用 0 代替** —— 0 会被读成"缓存坏了"）。
      final u = e.response.usage;
      if (u == null) return;
      // ★ 原始用量**只在 debug 构建**打一行（assert 在 release 被剥掉）。
      //
      // ## 为什么必须有这一行
      //
      // "命中缓存率"这个数的**唯一权威来源是服务端返回的 usage**。各家字段名
      // 不同（OpenAI 在 `prompt_tokens_details` 里、Anthropic 是
      // `cache_read_input_tokens`、**DeepSeek 是顶层的 `prompt_cache_hit_tokens`**），
      // 中转站还可能改字段。字段名猜错 ⇒ UI 永远显示一个假的低值，
      // 而**看代码是看不出来的**（代码只是"没匹配上"）。
      //
      // 所以：把原样 usage 打出来，按**实测字段**对齐，而不是按文档猜。
      // 用量里没有 API Key，打印是安全的。
      assert(() {
        // ignore: avoid_print
        print('[heracles][usage] ${u.originalUsage}');
        return true;
      }());
      emit(HeraclesTurnUsage(
        // ★ 口径统一（2026-10-23）：`promptTokens` 一律表示**整段 prompt**
        //   （**含**已命中的部分），命中率由消费方算 `cached / promptTokens`。
        //
        // ## 为什么必须在这里规范化（真机数据）
        //
        // 实测（设备 e35e48c6，中转站返回的原始 usage）：
        // ```
        // prompt_tokens: 5468, prompt_tokens_details: {cached_tokens: 5376}
        // ```
        // 即**真实命中率 98.3%**。但旧算法是 `cached / (cached + prompt)`，
        // 把"整段"和"其中的命中部分"**又加了一遍** ⇒ 5376/(5376+5468) = **49.6%**，
        // 顶栏长期显示 ~50%；用户因此报"命中缓存率太低了"。
        //
        // 这不是算错一个数：`prompt_tokens` 在 OpenAI/DeepSeek 系里是**整段**，
        // 而在 Anthropic 系里 `input_tokens` **只是未命中部分**（命中数在
        // `cache_read_input_tokens`）。两种语义混在一起用同一个公式，
        // 必然有一家是错的 ⇒ 规范化只能发生在**知道 wire 的地方**（这里）。
        promptTokens: _fullPromptTokens(u),
        outputTokens: u.completionTokens,
        cachedTokens: _cachedFrom(u),
      ));
    });
    controller.on<OnAgentExceptionEvent>((e) {
      // ⚠️ 字段是 `error`（Exception），不是 `exception`
      //
      // ★ **只在没有别的出口会说这件事时才发**（2026-10-22 修重复事件）★
      //
      // ## 踩到的 bug
      //
      // 框架在抛 `AgentException` 时**先发这个 controller 事件、再让
      // `runStream()` 抛出**。于是失败原因被播了两遍：
      //   ① 这里 → `HeraclesFailed("检测到循环…")`
      //   ② `_drive` 的 `on AgentException catch` → `HeraclesFailed(...)` 又一遍
      //
      // 后果不只是"日志多一行"：UI 侧 `kFailed` 会走 `_reportRunFailure`，
      // 那条路会**往会话里追加一条失败消息并弹红条** ⇒ 用户看到两个红条、
      // 会话里两条重复的失败记录。而 `HeraclesFailed` 是终态事件，
      // 出现在终态之后的第二条没有任何合法语义。
      //
      // ⇒ 这个事件退化成"**兜底通道**"：只在 `_drive` 的 catch **不会**覆盖
      //    的路径上没有意义（catch 一定会覆盖），所以它自己不再发事件。
      //    保留订阅是为了留下 `lastFrameworkError` 供排障，而不是为了播报。
      frameworkError ??= _describeException(e.error);
    });
    controller.on<OnAgentErrorEvent>((e) {
      // ⚠️ `error` 是 String（非 nullable）
      //
      // 同上：`runStream()` 会因为错误结束并把原因抛给我们，这里不重复播。
      frameworkError ??= e.error;
    });

    // ---- 压缩器 ----
    //
    // 摘要用小模型（如果配了）：省钱的常规手段。
    //
    // ## 压缩时机（框架控制，不是我们）
    //
    // 框架在**每一轮循环的最开头、请求发出之前**调 `compress(state)`
    // （`stateful_agent.dart` 的 `while (true)` 里）。
    // ⇒ "任务跑到一半也能压缩后继续"**天生成立**，不需要我们额外做什么。
    //
    // ## onCompressed：把"压缩真的发生了"播给 UI
    //
    // 压缩器与 `emit` 在同一个作用域（都在 `_drive` 里），所以直接闭包捕获。
    // 回调只在**历史真的变短**时触发（见 `WindowRatioCompressor.onCompressed`），
    // 所以这里不用再判断一次 —— 别在两处判同一件事，将来会分叉。
    final summarizerClient = _config.summarizerModel == null ? null : _buildClient();
    final compressor = WindowRatioCompressor(
      client: summarizerClient ?? client,
      modelConfig: _modelConfig(model: _config.summarizerModel),
      modelWindowTokens: _config.modelWindowTokens,
      onCompressed: (beforeMessages, afterMessages, beforeTokens, afterTokens) {
        emit(HeraclesContextCompressed(
          beforeMessages: beforeMessages,
          afterMessages: afterMessages,
          beforeTokens: beforeTokens,
          afterTokens: afterTokens,
        ));
        // ★ C3/M2（2026-10-25）：压缩发生 ⇒ 结构化快照同时沉淀为**可读笔记**。
        //   框架的 XML 快照只在 episodic memory 里（进程内）；这份笔记
        //   落到工作区 .heracles/notes/<会话>.md —— 长任务的中间结论
        //   （当前目标/已知事实/最近动作）与对话历史分离、跨重启可见。
        //   失败静默（笔记是增强）。
        _appendNote(_caps.workspace, _state!.sessionId, beforeMessages,
            beforeTokens, afterTokens);
      },
    );

    // ---- 工具调用预算（ADR-033 的"真预算"）----
    //
    // 数在 `beforeToolCall` 上：**模型每发起一次工具调用就算一次**，
    // 不论那一次最终成功还是失败 —— 预算是"模型挥霍了多少次机会"，
    // 不是"成功了几次"。超限时 `abort` 让框架抛 `AgentException`，
    // 由下面的 catch 统一翻译成一句人话。
    final budgetHook = _ToolBudgetHook(
      maxToolCalls: _options.maxToolCalls,
      onExceeded: () => budgetReached = true,
      // ★ 预警（E5，2026-10-24）：75%/90% 各播一次，让用户在熔断**前**
      //   就知道"快烧完了"，而不是等硬熔断才第一次听说。
      onWarning: (used, limit) =>
          emit(HeraclesBudgetWarning(used: used, limit: limit)),
    );

    // ---- 审批门禁（2026-10-24 接线）----
    //
    // 挂在同一个 `beforeToolCall` 上，排在预算之后：先算预算再谈批准 ——
    // 预算烧完直接终止，不为一个注定要被拦下的调用弹窗。
    // 注意被拒绝的调用**也计入预算**：它是模型的一次"挥霍"，
    // 否则"拒绝→模型换着花样重试"可以无限循环。
    final approvalHook = _ApprovalHook(
      mode: _options.approvalMode,
      gate: _askGate,
    );

    // ---- 组装 StatefulAgent ----
    //
    // ## 跨轮记忆（2026-10-23 修）
    //
    // ### 修之前为什么"模型记不住上一轮"
    //
    // `_state ??= AgentState(...)` 意味着：**只要这个 `HeraclesAgent` 实例是
    // 新建的，`_state` 就是 null ⇒ 从空历史开始**。而 App 侧每次 run 都
    // `new HeraclesAgent(...)`（`local_agent.dart`），于是每一轮都是全新会话 ——
    // 模型看不到上一轮的 user/assistant，表现就是"它忘了我们刚才在聊什么"。
    // 这同时也是缓存命中率只有 1% 的主因：**每条请求的前缀几乎全变**。
    //
    // ### 现在的规则（三条，别改）
    //
    // 1. **有 history 就以它为准**重建 state —— 即使 `_state` 已存在。
    //    理由：调用方（App）从会话文件读到的才是**唯一真相**；同一个
    //    `HeraclesAgent` 实例被复用时若沿用旧 `_state`，会与文件分叉
    //    （两边各自 append，越用越乱）。
    // 2. **没有 history 才退回 `_state ??=`** —— 保住"同一实例连续跑两轮"
    //    这个老行为（测试与 CLI 依赖它），**向后兼容**。
    // 3. history 是**原样**放进去的（`AgentMessageHistory(messages: history)`），
    //    不重排、不去重、不裁剪 —— 裁剪是调用方的事（它才知道哪些能丢）。
    //
    // ⚠️ `AgentMessageHistory` 的 `messages` 是**可变的 List**，且框架会继续
    //    往里 `add`（`state.history.messages.add(...)`）。所以这里传
    //    `List.of(history)` 而不是直接把调用方的 list 递进去 —— 否则框架
    //    会**往调用方那个列表里塞消息**，调用方复用它就会看到被污染的数据。
    if (history != null && history.isNotEmpty) {
      _state = AgentState(
        sessionId: _state?.sessionId ?? _newSessionId(),
        history: AgentMessageHistory(messages: List<LLMMessage>.of(history)),
      );
    } else {
      _state ??= AgentState(sessionId: _newSessionId());
    }
    // ★ H3/K2/P4（2026-10-25）：verifyCommand 配置后，写/编辑成功自动跑
    //   验证命令（经 shell 能力），输出附在工具结果里回给模型；
    //   lastVerifyFailed 与 P4 完成门禁 hook 共享。
    final shellForVerify = _caps.shell;
    final lastVerifyFailed = <bool>[];
    final Future<String> Function()? verify =
        (_options.verifyCommand != null && shellForVerify != null)
            ? () async {
                final r = await shellForVerify.run(
                  _options.verifyCommand!,
                  timeout: const Duration(minutes: 10),
                );
                final passed = r is CapabilitySuccess;
                lastVerifyFailed
                  ..clear()
                  ..add(!passed);
                return switch (r) {
                  CapabilitySuccess(:final data) =>
                    '通过。输出尾部：${data.length > 800 ? data.substring(data.length - 800) : data}',
                  CapabilityFailure(:final reason) => '失败：$reason',
                  _ => '通过（无输出）',
                };
              }
            : null;
    // ★ A1（2026-10-25）：MCP 服务器接线 —— 连接→框架三层渐进披露→
    //   run 结束断开（会话不跨 run）。单个服务器连不上只记日志（跳过），
    //   绝不炸 run —— MCP 是增强，不是主链路。
    final mcpManager = McpManager();
    var mcpConnected = false;
    if (_options.mcpServers.isNotEmpty) {
      try {
        final configs = <McpConnectionConfig>[
          for (final m in _options.mcpServers)
            McpConnectionConfig(
              serverName: (m['name'] as String?) ?? 'mcp',
              type: (m['url'] as String?) != null
                  ? McpTransportType.http
                  : McpTransportType.stdio,
              command: m['command'] as String?,
              args: (m['args'] as List?)?.cast<String>(),
              url: m['url'] as String?,
              headers: (m['headers'] as Map?)?.cast<String, String>(),
            ),
        ];
        await mcpManager.connectAll(configs);
        mcpConnected = mcpManager.hasServers;
      } catch (_) {
        // MCP 连接整体失败：当没配置继续跑
      }
    }
    var usedFallbackIdx = -1;
    var agent = StatefulAgent(
      name: 'heracles',
      client: client,
      modelConfig: _modelConfig(model: usedFallbackIdx < 0
          ? null
          : _options.fallbackModelNames[usedFallbackIdx]),
      state: _state!,
      systemPrompts: _buildSystemPrompts(),
      tools: _buildTools(verify: verify),
      controller: controller,
      compressor: compressor,
      planMode: _options.enablePlan ? PlanMode.auto : PlanMode.none,
      maxTurns: _options.maxTurns,
      hooks: [
        budgetHook,
        approvalHook,

        // ★ P4（2026-10-25）：完成门禁 —— 写过文件且最后一次验证失败时
        //   拒绝收尾，模型必须回到修复循环（"带病收尾"被架构拦下）。
        if (_options.verifyGateCompletion && verify != null)
          _VerifyGateHook(lastVerifyFailed: lastVerifyFailed),
        // ★ P1：计划前置门禁（自研——框架 must 与 auto 行为一致）
        if (_options.requirePlan)
          _PlanGateHook(isReadAllowed: _isReadTool),
        // ★ P3：连续失败反思注入
        if (_options.reflectOnFailures > 0)
          _ReflectionHook(threshold: _options.reflectOnFailures),
      ],
      // ★ 子代理（H6，2026-10-24）：开启后框架自动追加 `delegate_task`
      //   工具与系统提示（列出来源见 buildSubAgentSystemPrompt）。
      // ★ disableSubAgents 才是真正的开关（框架在 !disableSubAgents 时
      //   无条件追加 delegate_task，不看 subAgents 是否为空）。
      subAgents: _options.enableSubAgents ? [_workerSubAgent()] : null,
      // ★ 技能目录（S1/S2，2026-10-24）：非空时框架追加 activate/deactivate
      //   工具 + 目录系统提示（渐进披露）。
      skills: _options.enableSkills ? builtinSkills() : null,
      disableSubAgents: !_options.enableSubAgents,
      // 框架自带循环检测（相同调用重复 + 周期性 LLM 诊断）。
      // 旧实现只有"相同调用重复"且阈值 2；这里用框架默认（5），
      // 因为云端模型有自愈能力，2 太激进。
      loopDetector: DefaultLoopDetector(
        state: _state!,
        client: client,
        modelConfig: _modelConfig(),
      ),
      autoSaveStateFunc: _stateStorage == null
          ? null
          : (state) async => _stateStorage.save(state),
      mcpManager: mcpConnected ? mcpManager : null,
    );

    /// **本轮追加的起点** —— 之后 `_lastText` 只在这里之后找本轮的正文。
    ///
    /// 必须在 `runStream` **之前**取：它会往 `state.history` 里 append
    /// 本轮的用户消息与模型回答，取晚了下标就错。
    final turnStartIndex = _state!.history.messages.length;

    // ---- 跑（含 D3 降级重试：失败且还有备用模型 ⇒ 换模型重跑）----
    // ⚠️ 简化实现：降级发生在 run 级 —— agent 在 while 内重建
    //   （modelConfig 随降级变化），state 在外层存活（历史保留）。
    var finished = false;
    while (true) {
    try {
      await for (final ev in agent.runStream(
        _firstMessage(userRequest, images),
        cancelToken: cancelToken,
      )) {
        // 框架的 Stream 事件只用来补我们 Controller 覆盖不到的（如工具请求）
        if (ev.eventType == StreamingEventType.functionCallRequest) {
          final calls = ev.data as List<FunctionCall>;
          for (final c in calls) {
            pendingToolStart[c.id] = Stopwatch()..start();
            final callArgs = _safeParseArgs(c.arguments);
            emit(HeraclesToolRequested(
              toolName: c.name,
              arguments: callArgs,
              id: c.id,
              // ★ 2026-10-29：执行面在**请求这一刻**就告诉 UI。
              //   前端要在卡片标题上写「在沙箱 / 在手机执行了命令」，
              //   等执行完再标就晚了。用的是与真正执行**同一张规则表**
              //   （decideSurface），不会前后打架。
              surface: _surfaceHintFor(c.name, callArgs),
              command:
                  callArgs['command'] is String ? callArgs['command'] as String : null,
            ));
          }
        }
      }
      wallClock.stop();
      // ★ E4（2026-10-24）：traceDir 非空 ⇒ 全对话原始内容落盘
      //   （messages 逐条 toJson 可回放；工具级 trace 已在会话 .jsonl）。
      //   失败静默 —— 排障辅助绝不搞崩任务。App 恒传
      //   `<工作区>/.heracles/traces`；SAF 工作区写不进去也如实静默。
      if (_options.traceDir != null) {
        try {
          final d = Directory(_options.traceDir!);
          await d.create(recursive: true);
          await File(
                  '${d.path}${Platform.pathSeparator}'
                  'conversation-${DateTime.now().millisecondsSinceEpoch}.json')
              .writeAsString(jsonEncode({
            'sessionId': _state!.sessionId,
            'turns': _state!.totalLoopCount,
            'messages': [
              for (final m in _state!.history.messages) m.toJson(),
            ],
          }));
        } catch (_) {
          // 静默
        }
      }
      // ★ M5（2026-10-25）：autoExtract 开启 ⇒ 收尾提炼事实入长期记忆。
      //   失败静默（锦上添花不搞崩主链路）；无记忆能力跳过。
      if (_options.autoExtract && _caps.memory != null) {
        try {
          final transcript = StringBuffer();
          for (final m in _state!.history.messages) {
            final ut = switch (m) {
              UserMessage() => m.contents
                  .whereType<TextPart>()
                  .map((p) => p.text)
                  .join(),
              ModelMessage() => m.textOutput ?? '',
              FunctionExecutionResultMessage() => m.results
                  .expand((r) => r.content.whereType<TextPart>())
                  .map((p) => p.text)
                  .join('；'),
              _ => '',
            };
            if (ut.trim().isEmpty) continue;
            final who = switch (m) {
              UserMessage() => '用户',
              ModelMessage() => '助手',
              FunctionExecutionResultMessage() => '工具',
              _ => '',
            };
            transcript.writeln('$who：${ut.trim()}');
          }
          if (transcript.toString().trim().isNotEmpty) {
            final facts = await extractMemories(
              config: _config,
              transcript: transcript.toString(),
              client: _injectedClient,
            );
            for (final f in facts) {
              // 2026-10-29：走作用域化写入 —— 默认作用域由宿主能力决定
              // （新宿主 = session；老宿主 appendScoped 退化成 append，行为不变）。
              // **不再直写全局**：agent 自动写全局会污染所有会话。
              await _caps.memory!.appendScoped(
                _caps.memory!.defaultWriteScope,
                '[auto] $f',
              );
            }
          }
        } catch (_) {
          // 静默
        }
      }
      // ★ B8 P0（2026-10-30）：计划终态先于 run 终态播报。
      //   成功 = 计划里每一步都 done/cancelled；有计划的 run 才发（无计划
      //   由 helper 直接 return）。
      final allPlanStepsClosed = lastPlanSteps.every(
        (s) =>
            s.status == HeraclesPlanStatus.done ||
            s.status == HeraclesPlanStatus.cancelled,
      );
      emitPlanClosed(
        reachedGoal: allPlanStepsClosed,
        reason: allPlanStepsClosed ? null : '任务已结束，但计划里还有未完成的步骤',
      );
      emit(HeraclesFinished(
        finalText: _lastText(agent, turnStartIndex, captured: lastTurnText),
        turns: _state!.totalLoopCount,
        totalToolCalls: totalToolCalls,
        wallClockMs: wallClock.elapsedMilliseconds,
      ));
      finished = true;
    } on AgentException catch (e) {
      wallClock.stop();
      final reason =
          budgetReached ? _budgetMessage(_options.maxToolCalls, totalToolCalls)
                        : (frameworkError ?? _describeException(e));
      // ★ D3：预算超限/取消不降级（非模型问题）；其余失败且备用未耗尽 ⇒ 降级重跑
      final canFallback = !budgetReached &&
          usedFallbackIdx + 1 < _options.fallbackModelNames.length &&
          e.code != AgentExceptionCode.cancelled;
      if (canFallback) {
        final from = usedFallbackIdx < 0
            ? _config.modelName
            : _options.fallbackModelNames[usedFallbackIdx];
        usedFallbackIdx++;
        emit(HeraclesFallback(
            from: from, to: _options.fallbackModelNames[usedFallbackIdx], reason: reason));
        totalToolCalls = 0;
        budgetReached = false;
        frameworkError = null;
        lastTurnText = null;
        // 重建 agent（新 modelConfig）；state/Controller/事件桥不变
        agent = StatefulAgent(
          name: 'heracles',
          client: client,
          modelConfig: _modelConfig(
              model: _options.fallbackModelNames[usedFallbackIdx]),
          state: _state!,
          systemPrompts: _buildSystemPrompts(task: userRequest),
          tools: _buildTools(verify: verify),
          controller: controller,
          compressor: compressor,
          planMode: _options.enablePlan ? _options.planMode : PlanMode.none,
          maxTurns: _options.maxTurns,
          hooks: [
            budgetHook,
            approvalHook,
          ],
          loopDetector: DefaultLoopDetector(
            state: _state!,
            client: client,
            modelConfig: _modelConfig(
                model: _options.fallbackModelNames[usedFallbackIdx]),
          ),
          autoSaveStateFunc: _stateStorage == null
              ? null
              : (state) async => _stateStorage.save(state),
          mcpManager: mcpConnected ? mcpManager : null,
        );
        continue;
      }
      // ★ B8 P0：计划终态先于失败终态播报（人话原因，不带堆栈/内部 id）。
      emitPlanClosed(
        reachedGoal: false,
        reason: e.code == AgentExceptionCode.cancelled
            ? '用户停止'
            : (budgetReached ? '任务被中断：$reason' : '运行失败：$reason'),
      );
      emit(HeraclesFailed(reason));
    } catch (e) {
      wallClock.stop();
      final reason = budgetReached
          ? _budgetMessage(_options.maxToolCalls, totalToolCalls)
          : (frameworkError ?? '运行出错：$e');
      if (!budgetReached &&
          usedFallbackIdx + 1 < _options.fallbackModelNames.length) {
        final from = usedFallbackIdx < 0
            ? _config.modelName
            : _options.fallbackModelNames[usedFallbackIdx];
        usedFallbackIdx++;
        emit(HeraclesFallback(
            from: from, to: _options.fallbackModelNames[usedFallbackIdx], reason: reason));
        totalToolCalls = 0;
        budgetReached = false;
        frameworkError = null;
        lastTurnText = null;
        agent = StatefulAgent(
          name: 'heracles',
          client: client,
          modelConfig: _modelConfig(
              model: _options.fallbackModelNames[usedFallbackIdx]),
          state: _state!,
          systemPrompts: _buildSystemPrompts(task: userRequest),
          tools: _buildTools(verify: verify),
          controller: controller,
          compressor: compressor,
          planMode: _options.enablePlan ? _options.planMode : PlanMode.none,
          maxTurns: _options.maxTurns,
          hooks: [budgetHook, approvalHook],
          loopDetector: DefaultLoopDetector(
            state: _state!,
            client: client,
            modelConfig: _modelConfig(
                model: _options.fallbackModelNames[usedFallbackIdx]),
          ),
          autoSaveStateFunc: _stateStorage == null
              ? null
              : (state) async => _stateStorage.save(state),
          mcpManager: mcpConnected ? mcpManager : null,
        );
        continue;
      }
      // ★ B8 P0：通用异常收尾同样先播计划终态（同一个 helper 保证只发一次）。
      emitPlanClosed(
        reachedGoal: false,
        reason: budgetReached ? '任务被中断：$reason' : '运行失败：$reason',
      );
      emit(HeraclesFailed(reason));
    } finally {
      if (!finished) wallClock.stop();
    }
    // 生产者收尾（成功/失败终局）。**绝不 await close()** —— 消费端可能
    // 已提前走（`yield*` 被取消），不 await 就不会挂住任何人。
    unawaited(bridge.close());
    // A1：MCP 会话不跨 run 存活 —— 终局断开（降级重跑期间保持连接）
    if (mcpConnected) {
      try {
        await mcpManager.disconnectAll();
      } catch (_) {
        // 断开失败不影响已收尾的任务
      }
    }
    break; // while(true)：终局出口（continue = 降级重跑）
    }
  }

  /// 预算超限时回给用户/UI 的那句话。
  ///
  /// 三个要素缺一不可：**已到上限**（数字）/ **任务未完成** / **下一步怎么办**。
  /// 旧实现这里什么都不说（预算没接线），用户只看到"任务停下来了"。
  String _budgetMessage(int limit, int actual) =>
      '已达工具调用上限 $limit，任务未完成。'
      '（本次实际发起 $actual 次工具调用；上限是防止一次任务无限挥霍调用次数的硬预算，'
      'ADR-033。）请把需求拆成更小的步骤重试，或明确指出你希望我继续做哪一部分。';

  /// 从 `ModelUsage.originalUsage`（provider 原始 map）里取**真实上报**的缓存命中数。
  ///
  /// 把 provider 的 prompt token 数**规范化成"整段"**（含已命中的部分）。
  ///
  /// ## 两家的语义不同（这是必须规范化的原因）
  ///
  /// | wire | 字段 | 语义 |
  /// |---|---|---|
  /// | OpenAI / DeepSeek | `prompt_tokens` | **整段**（已含命中） |
  /// | Anthropic | `input_tokens` | **仅未命中部分**；命中在 `cache_read_input_tokens`，写入在 `cache_creation_input_tokens` |
  ///
  /// 若把两者当同一个数用，Anthropic 那条轨会把 prompt 少算一大截
  /// （命中率被高估、上下文占用被低估）。
  ///
  /// ⚠️ **Anthropic 分支未真机验证**（本机只有 OpenAI 兼容中转站的实测数据）。
  /// 规范化逻辑按 Anthropic 官方字段语义写，并留了 `creation` 那一项 ——
  /// 但**在拿到 Anthropic 真 Key 证据前，不要宣称这条轨正确**。
  static int _fullPromptTokens(ModelUsage u) {
    final o = u.originalUsage;
    if (o is! Map) return u.promptTokens;
    int pick(String k) => (o[k] as num?)?.toInt() ?? 0;
    // Anthropic 标志：出现 cache_read / cache_creation 即认为 input_tokens 不含缓存
    final hasAnthropicCache =
        o.containsKey('cache_read_input_tokens') ||
            o.containsKey('cache_creation_input_tokens');
    if (!hasAnthropicCache) return u.promptTokens;
    return u.promptTokens + pick('cache_read_input_tokens') + pick('cache_creation_input_tokens');
  }

  /// 返回 `null` = 这个 provider 压根没上报缓存字段 ⇒ UI 必须显示"不可用"，
  /// **不许显示 0%**（0% 会被读成"缓存坏了"，那是两种完全不同的事）。
  ///
  /// 兼容四家 wire 的字段名：
  /// · OpenAI Chat：`prompt_tokens_details.cached_tokens`
  /// · Anthropic：`cache_read_input_tokens`
  /// · Responses：`input_tokens_details.cached_tokens`
  /// · **DeepSeek：`prompt_cache_hit_tokens`（顶层，不在 details 里）**
  ///   —— 2026-10-23 补。此前漏了这一家，而用户的模型正是 DeepSeek 系
  ///   （经中转站），于是"命中缓存率"永远读不出真值（顶栏一直 1%）。
  static int? _cachedFrom(ModelUsage u) {
    final o = u.originalUsage;
    if (o is! Map) return u.cachedToken > 0 ? u.cachedToken : null;
    int? pick(Map m, String key) => (m[key] as num?)?.toInt();
    final details = o['prompt_tokens_details'] ?? o['input_tokens_details'];
    if (details is Map) {
      final v = pick(details, 'cached_tokens');
      if (v != null) return v;
    }
    final anth = pick(o, 'cache_read_input_tokens');
    if (anth != null) return anth;
    // DeepSeek 原生字段（顶层）：命中 / 未命中是一对，取命中那半
    final dsHit = pick(o, 'prompt_cache_hit_tokens');
    if (dsHit != null) return dsHit;
    // 框架已把值归一到 cachedToken —— 非 0 时信它；为 0 且上面都没命中字段 ⇒ 未上报
    return u.cachedToken > 0 ? u.cachedToken : null;
  }

  String _newSessionId() =>
      's${DateTime.now().microsecondsSinceEpoch}';

  /// 取**本轮**的正文当最终回答。
  ///
  /// ⚠️ **只取 `textOutput`**，不碰 `thought` ——
  /// 旧实现有过"思考被当答案"的事故（用户看到一堆英文推理）。
  ///
  /// ## 主路径：[captured]（`AfterCallLLMEvent` 捕获的本轮正文）
  ///
  /// 见 `_drive` 里 `lastTurnText` 的 KDoc。**这是唯一可靠的来源**，
  /// 因为它不依赖 `state.history` 的形状 —— 而上下文压缩会把历史**原地改写**。
  ///
  /// ## 兜底路径：倒扫历史（只在 captured 为空时）
  ///
  /// captured 为空 = 本轮模型一次正文都没出。这种情况下仍然尝试倒扫，
  /// 是为了兼容"正文进了历史但事件没被捕获"的理论可能（例如将来框架改了
  /// 事件时序）。但这条路**两个风险都在**，所以：
  ///
  /// 1. 用 [startIndex] 排除历史（否则会把**上一轮的回答**当本轮答案 ——
  ///    那条 bug 有测试锁着，不能弄红）；
  /// 2. **显式跳过框架的压缩 ack 文案**（否则会把一句英文客套话当答案）。
  ///
  /// ### 为什么第 1 条会被压缩击穿（这就是本轮要修的）
  ///
  /// `startIndex` 是"本轮开始前历史的长度"。压缩后
  /// `state.history.messages = messagesToKeep` ⇒ **长度可能比 `startIndex` 还短**
  /// ⇒ 旧守卫 `startIndex >= msgs.length` 直接返回空串
  /// ⇒ 压缩过的那一轮"答完了却没有回答"。主路径修掉了它，兜底路径至少
  /// 不再假装能读到东西（返回空串是**如实**的：确实没捕获到）。
  String _lastText(
    StatefulAgent agent,
    int startIndex, {
    String? captured,
  }) {
    // ---- 主路径 ----
    if (captured != null && captured.trim().isNotEmpty) {
      return captured;
    }

    // ---- 兜底路径 ----
    final msgs = _state?.history.messages ?? const [];
    // startIndex 可能大于实际长度（压缩截短之后就会）⇒ 什么都不取，
    // 绝不用越界下标去 sublist。
    if (startIndex >= msgs.length) return '';
    for (final m in msgs.skip(startIndex).toList().reversed) {
      if (m is ModelMessage) {
        final t = m.textOutput;
        if (t == null || t.trim().isEmpty) continue;
        // ★ 跳过框架的压缩 ack。它是 `LLMBasedContextCompressor` 为"接上"
        //   摘要快照而插入的一句模型口吻确认，**不是模型对本轮用户的回答**。
        //   把它当答案显示 = 用户看到一句莫名其妙的英文。
        if (_isCompressionAck(t)) continue;
        return t;
      }
    }
    return '';
  }

  /// 是不是框架压缩时插入的那句 ack 文案。
  ///
  /// 判据来自框架源码（`context_compressor.dart:175-178`）：
  /// `ModelMessage(textOutput: "Got it. Thanks for the additional context!")`。
  ///
  /// 用**包含**而不是全等：将来框架可能给这句话加个前缀/后缀，全等会漏。
  /// 判错的风险很低 —— 这不是模型会主动说的话，而且只有兜底路径会走到这里。
  static bool _isCompressionAck(String text) {
    const marker = 'Thanks for the additional context';
    return text.contains(marker);
  }

  Map<String, dynamic> _safeParseArgs(String raw) {
    // 框架已经解析过一遍；这里只在需要给 UI 看时再解析。
    // 解析失败不抛错 —— UI 显示原文即可，不影响执行。
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : {'_raw': raw};
    } catch (_) {
      return {'_raw': raw};
    }
  }

  /// **执行面预判**：给 UI 的工具卡标题用（`'sandbox'` / `'device'`）。
  ///
  /// ==========================================================================
  /// 为什么在这里算，而不是等执行完
  /// ==========================================================================
  /// 前端要求 `tool_started` 就带执行面 —— 用户看着卡片时就要知道
  /// 「这条命令是在沙箱里跑，还是要动我的手机」。等 `tool_finished` 才标，
  /// 那几秒里用户是瞎的。
  ///
  /// ## 规则来源是同一张表
  /// 用 [decideSurface]（`sandbox_capability.dart`），**不是**另写一套 if ——
  /// 两处规则一旦分叉，卡片会显示 A 而实际跑在 B，比不显示更糟。
  ///
  /// ## 沙箱是否就绪
  /// 只有 `run_shell_command` 需要这个提示。就绪状态在每次 `run` 开始时探测一次
  /// 并缓存（`_sandboxReadyForRun`）—— **不在事件回调里 await**（那是同步路径）。
  String? _surfaceHintFor(String toolName, Map<String, dynamic> args) {
    if (toolName != 'run_shell_command') return null;
    final command = args['command'];
    if (command is! String || command.trim().isEmpty) return null;

    final sandbox = _caps.sandbox;
    if (sandbox == null) {
      // 宿主没接沙箱 ⇒ 一定在手机上跑（与执行时一致）
      return ExecutionSurface.device.wire;
    }
    final ready = _sandboxReadyForRun ?? false;
    return decideSurface(command, sandboxReady: ready).surface.wire;
  }

  String _flattenContent(List<UserContentPart> parts) {
    final buf = StringBuffer();
    for (final p in parts) {
      if (p is TextPart) buf.write(p.text);
    }
    return buf.toString();
  }

  HeraclesPlanStatus _mapStatus(StepStatus s) => switch (s) {
        StepStatus.pending => HeraclesPlanStatus.pending,
        StepStatus.inProgress => HeraclesPlanStatus.active,
        StepStatus.completed => HeraclesPlanStatus.done,
        StepStatus.cancelled => HeraclesPlanStatus.cancelled,
      };

  String _describeException(Exception e) {
    if (e is AgentException) {
      return switch (e.code) {
        AgentExceptionCode.loopDetection =>
          '检测到循环：模型反复请求相同的操作。任务已停止，避免反复修改同一文件。'
              '如果确实需要继续，请把需求拆成更小的步骤重试。',
        AgentExceptionCode.cancelled => '任务已取消。',
        AgentExceptionCode.stopByController => '任务被停止规则拦截。',
        AgentExceptionCode.resumeFailed => '无法恢复上次中断的任务：${e.message}',
        AgentExceptionCode.unknown => '任务异常：${e.message}',
      };
    }
    return '任务异常：$e';
  }
  /// **worker 子代理工厂**（H6，2026-10-24）—— 干净上下文的执行者。
  ///
  /// ## 为什么是"干净 state"而不是框架的 clone
  ///
  /// 框架的 assignee='clone' 会把主对话历史拷进 worker 的情景记忆 ——
  /// 那是"带着记忆的分身"。H6 要的是**隔离**：探索/核对类子任务的全部
  /// 中间过程不进主上下文，主线程只收结论。所以注册一个命名 worker，
  /// 工厂里给**全新 AgentState** —— worker 看不到主对话，
  /// task_description 必须自包含（框架追加的 worker 协议提示已写明）。
  ///
  /// ## 三个刻意的决定
  ///
  /// 1. **独立事件总线**：worker 的思考/工具/用量事件进一个新
  ///    AgentController，没人订阅 ⇒ 就地丢弃。否则它们会混进主 run 的
  ///    事件流 —— 用量记账翻倍、UI 出现"来历不明"的工具卡片。
  /// 2. **hooks 照常继承**：审批与预算是任务级约束，不因派生而失效
  ///    （worker 的危险操作照样弹窗、调用照样计入总预算）。
  /// 3. **disableSubAgents: true + 收紧的 maxTurns(12)**：深度恒为 1，
  ///    worker 自身不失控。
  SubAgent _workerSubAgent() => SubAgent(
        name: 'worker',
        description: '通用工作者：在干净上下文里执行研究、探索、批量核对类子任务，'
            '只把最终结论带回来。task_description 必须自包含（worker 看不到主对话）。',
        agentFactory: (parent) {
          final workerState = AgentState(
            sessionId:
                '${parent.state.sessionId}_w${DateTime.now().microsecondsSinceEpoch}',
          );
          return StatefulAgent(
            name: '${parent.name}_worker',
            client: parent.client,
            modelConfig: parent.modelConfig,
            state: workerState,
            tools: parent.tools,
            systemPrompts: List.of(parent.systemPrompts),
            compressor: parent.compressor,
            loopDetector: DefaultLoopDetector(
              state: workerState,
              client: parent.client,
              modelConfig: parent.modelConfig,
            ),
            hooks: parent.hooks,
            // 独立事件总线：worker 的过程事件无人订阅 ⇒ 隔离（见上方注释 1）
            controller: AgentController(),
            isSubAgent: true,
            disableSubAgents: true,
            maxTurns: 12,
          );
        },
      );
}

/// 事件出口 —— 桥已关就丢弃，绝不往已关闭的 controller 里写。
///
/// `StreamController.add` 在已关闭时会抛 `StateError`；生产者在
/// "消费端提前取消"之后还会继续跑一小段，必须在这里挡住。
class _Emitter {
  _Emitter(this._bridge);
  final StreamController<HeraclesEvent> _bridge;

  void call(HeraclesEvent event) {
    if (_bridge.isClosed) return;
    _bridge.add(event);
  }
}

/// **工具调用预算 hook** —— 挂在框架的 `beforeToolCall` 上。
///
/// ## 为什么必须是 hook 而不是"在事件回调里数"
///
/// `AfterToolCallEvent` 是**工具执行完**才发的。在那里数意味着"第 201 次调用
/// 已经跑完了才知道超限"—— 预算要能**拦住**第 201 次，就得在执行前数。
///
/// `AgentHook.beforeToolCall` 是 `FutureOr` 且被 await ⇒ 返回 `abort` 会
/// 立刻抛 `AgentException(stopByController)`，框架不会执行那个工具。
class _ToolBudgetHook extends AgentHook {
  _ToolBudgetHook({
    required this.maxToolCalls,
    required this.onExceeded,
    this.onWarning,
  });

  final int maxToolCalls;
  final void Function() onExceeded;

  /// 预警回调（2026-10-24，E5）：75% / 90% 各播一次 —— 止损不该是
  /// 用户第一次听说预算的地方。`null` = 不预警（旧行为）。
  final void Function(int used, int limit)? onWarning;
  bool _warned75 = false;
  bool _warned90 = false;

  int _count = 0;

  @override
  FutureOr<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) {
    _count++;
    final warn = onWarning;
    if (warn != null) {
      if (!_warned90 && _count >= maxToolCalls * 0.90) {
        _warned90 = true;
        warn(_count, maxToolCalls);
      } else if (!_warned75 && _count >= maxToolCalls * 0.75) {
        _warned75 = true;
        warn(_count, maxToolCalls);
      }
    }
    if (_count > maxToolCalls) {
      onExceeded();
      return ToolCallHookResult.abort(
        reason: '工具调用已达上限 $maxToolCalls',
      );
    }
    return ToolCallHookResult.proceed(context.call);
  }
}

/// **计划前置门禁**（P1，2026-10-25）—— 框架 must 与 auto 行为一致，
/// 这个是我们自己的强制层。
///
/// 产出第一份计划（write_todos）之前：执行类工具全拒（拒绝信息指路
/// "先用 write_todos 列计划"）；读类工具（read/list/find/grep/web_fetch/
/// check_device_state）与 ask_user/save_memory 放行 —— 先看清楚再计划。
/// 计划存在后永久放行。
class _PlanGateHook extends AgentHook {
  _PlanGateHook({required this.isReadAllowed});

  /// 判定"读类工具"的回调（宿主注入，保持 hook 与工具清单解耦）。
  final bool Function(String tool) isReadAllowed;

  @override
  FutureOr<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) {
    final st = context.agent.state;
    final hasPlan = st.plan != null && st.plan!.steps.isNotEmpty;
    if (hasPlan) return ToolCallHookResult.proceed(context.call);

    final tool = context.call.name;
    if (tool == 'write_todos' || isReadAllowed(tool)) {
      return ToolCallHookResult.proceed(context.call);
    }
    return ToolCallHookResult.deny(content: [
      TextPart(
        '未执行：当前开启了"计划前置"模式 —— 动手之前必须先用 '
        '`write_todos` 把任务拆成清单（当前目标/步骤/顺序），'
        '然后按清单执行。你可以先用读取类工具了解情况，'
        '但改任何东西之前先列计划。',
      ),
    ]);
  }
}

/// **连续失败反思**（P3，2026-10-25）—— 反思环节由架构触发。
///
/// 连续失败达到阈值 ⇒ afterToolCall 注入反思指令（injectedMessages）：
/// "停下来分析根因、换方法，不要原样重试"。成功一次即重置。
/// 只在下一轮的上下文里出现一条 —— 轻量，不加额外 LLM 调用。
class _ReflectionHook extends AgentHook {
  _ReflectionHook({required this.threshold});
  final int threshold;
  int _consecutiveFailures = 0;

  @override
  Future<ToolResultHookResult> afterToolCall(ToolResultHookContext context) {
    if (context.result.isError) {
      _consecutiveFailures++;
      if (_consecutiveFailures >= threshold) {
        _consecutiveFailures = 0; // 触发一次即重置（不连环轰炸）
        return Future.value(ToolResultHookResult.proceed(
          injectedMessages: [
            UserMessage.text(
              '[反思指令] 你已连续 $threshold 次工具失败。停下来想清楚：'
              '(1) 逐条核对上面的失败原因，找出共同的根因；'
              '(2) 换一种不同的方法（不是原样重试）；'
              '(3) 如果这条路确实走不通，如实告诉用户卡在哪。',
            ),
          ],
        ));
      }
    } else {
      _consecutiveFailures = 0;
    }
    return Future.value(ToolResultHookResult.proceed());
  }
}

/// **完成门禁 hook**（P4，2026-10-25）—— "带病收尾"被架构拦下。
///
/// 本轮发生过文件写/编辑（= verify 跑过）且最后一次验证**失败**时，
/// onTurnCompletion 返回 continueRun：注入一条继续消息让模型回到
/// 修复循环。验证通过（或没写过文件）⇒ 正常收尾。
///
/// ## 为什么只拦"最后一次失败"
///
/// 模型可能修几次才过 —— 中间态失败不拦收尾，只有**最终态**/// 失败才说明任务带着问题结束。验证通过后标志被覆盖，正常放行。
class _VerifyGateHook extends AgentHook {
  _VerifyGateHook({required List<bool> lastVerifyFailed})
      : _lastVerifyFailed = lastVerifyFailed; // ignore: prefer_initializing_formals — 命名参数不能以下划线开头

  /// 共享的可变标志（与 verify 回调同源）：空 = 没验证过；[true] = 失败。
  final List<bool> _lastVerifyFailed;

  @override
  Future<TurnCompletionHookResult> onTurnCompletion(
    TurnCompletionHookContext context,
  ) async {
    if (_lastVerifyFailed.isNotEmpty && _lastVerifyFailed.first) {
      return TurnCompletionHookResult.continueWith([
        UserMessage.text(
          '[自动验证未通过] 刚才的验证命令失败了（见上方工具结果）。'
          '请修复问题后重新验证；确认通过后再给出最终回答。',
        ),
      ]);
    }
    return const TurnCompletionHookResult.accept();
  }
}

/// **审批门禁 hook**（2026-10-24 接线）—— 把 AGENTS.md 的
/// 「工具白名单 + 参数门禁三态（Allow/NeedsApproval/Deny）」重新变成架构保证。
///
/// ## 为什么必须是 hook 而不是"工具返回 NeedsApproval 再处理"
///
/// 旧思路是能力层返回 `CapabilityNeedsApproval`，翻译层把它变成一句文本提示
/// —— 那**不拦截任何东西**：模型收到"需要用户批准"这句提醒后照跑不误。
/// 拦截必须发生在**执行之前**，而框架唯一的执行前挂载点就是
/// `AgentHook.beforeToolCall`（被 await，返回 `deny` 可以用合成结果替代执行）。
///
/// ## 三个出口
///
/// · 不需要批准（档位放行 / 完全访问）⇒ `proceed`，工具正常执行；
/// · 需要批准且用户同意 ⇒ `proceed`；
/// · 需要批准但**拒绝 / 超时 / 无审批通道** ⇒ `deny` —— 模型收到的是
///   一条**合成失败结果**（"用户拒绝了…"），这一轮的循环照常继续，
///   模型可以换路，但**那个操作没有发生**。fail-closed：拿不到"允许"就当拒绝。
///
/// ## 为什么拒绝文案要劝"不要原样重试"
///
/// 不劝的话，模型的自然反应是再调一次（它会以为刚才是环境抖动）⇒
/// 用户被同一个弹窗连着轰炸。把"换路或询问"写进结果里，是在模型
/// 唯一必读的通道（工具结果）上给出路。
class _ApprovalHook extends AgentHook {
  _ApprovalHook({required this.mode, required this.gate});

  final ApprovalMode mode;
  final AskGate? gate;

  /// **会改工作区状态**的文件工具 —— `manual` 档要批；
  /// `workspaceAuto` 档放行（这正是该档位文案"工作区内修改自动执行"的含义）。
  static const _workspaceMutating = {'write_file', 'edit', 'apply_patch', 'mkdir'};

  /// **破坏性三件套** —— 删/移/复制都是不可逆或难逆的，任何非完全访问档都批。
  static const _destructive = {'delete_path', 'move_path', 'copy_path'};

  /// shell —— 能执行任意命令，是最大的权力面；硬禁令（kill 等）在工具层，
  /// 这里管的是"剩下的所有命令"要不要用户点头。
  static const _shell = {'run_shell_command'};

  /// APK 五件套 —— 构建写 staging、安装直接动设备，全部按高危算。
  static const _apk = {
    'build_apk', 'apk_decompile', 'apk_recompile', 'apk_sign', 'install_apk',
  };

  /// **只读工具白名单** —— 任何档位都不需要审批（它们不改任何状态）。
  ///
  /// ## ★ 这张表的存在方式，与上面四张表是反的（fail-closed 的关键）
  ///
  /// 改动之前这里没有白名单，判定是"**工具在不在危险表里**"：
  ///
  /// ```dart
  /// // ❌ 旧实现（fail-open）
  /// workspaceAuto => _destructive.contains(tool) || _shell.contains(tool) || ...
  /// ```
  ///
  /// 那意味着：**任何没有登记的新工具都默认"不用审批"**。
  /// 加 git 工具、MCP 工具、将来任何第三方工具时，它会**静默放行** ——
  /// 而 H1/SEC3 的立身之本是 **fail-closed**。
  ///
  /// 现在反过来：默认"要审批"，只有本白名单里的才放行。
  /// 新增工具时**忘了登记 ⇒ 变成"要审批"**（安全侧的默认），
  /// 而不是"静默放行"（危险侧的默认）。
  ///
  /// ## 三层安全：为什么这些可以免审批
  ///
  /// 1. **纯读**（read/list/find/grep/web_fetch/check_device_state）——
  ///    不写任何东西；`web_fetch` 有 SSRF 闸、结果的 SEC1 包裹在工具层。
  /// 2. **不改工作区**（ask_user / save_memory / write_todos / skills）——
  ///    `save_memory` 只往记忆文件追加（且有 SEC4 密钥闸），
  ///    `write_todos` 只改计划元数据，skills 的 activate/deactivate
  ///    只改"当前激活列表"。
  /// 3. **MCP 的只读子集**（list/read）—— `mcp_call_tool` **故意不放进来**：
  ///    它能调任意外部工具，是本表里最危险的一个，必须逐次审批。
  static const _readOnly = {
    // 文件读
    'read_file', 'list_files', 'find_files', 'grep_files',
    // 网络 / 设备读
    'web_fetch', 'check_device_state',
    // 交互 / 记忆 / 计划（不改工作区）
    'ask_user', 'save_memory', 'write_todos',
    'activate_skills', 'deactivate_skills',
    // MCP 只读
    'mcp_list_tools', 'mcp_list_resources', 'mcp_list_prompts',
    'mcp_read_resource', 'mcp_get_prompt',
    // git 只读（2026-10-27，Step 2）
    'git_status', 'git_log', 'git_diff', 'git_branches', 'git_show_commit',
  };

  /// 这个工具在当前档位下要不要批准。
  ///
  /// ## 三档语义（与 App 设置页文案逐字对应）
  ///
  /// | 档位 | 判定 |
  /// |---|---|
  /// | [fullAccess] | 全放行（用户的明确选择，含"我知道风险"）|
  /// | [workspaceAuto] | 白名单里的 + **工作区内修改**（`write_file` 等）放行；其余一律要批 |
  /// | [manual] | 只有白名单放行；**任何**会改状态的都要批 |
  ///
  /// ## 关键：未知工具 ⇒ 要审批（fail-closed）
  ///
  /// 见 [_readOnly] 的注释。这条是加 git/第三方工具时的安全网。
  bool needsApproval(String tool) => switch (mode) {
        ApprovalMode.fullAccess => false,
        ApprovalMode.workspaceAuto =>
          !_readOnly.contains(tool) && !_workspaceMutating.contains(tool),
        ApprovalMode.manual => !_readOnly.contains(tool),
      };

  @override
  Future<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) async {
    final tool = context.call.name;
    if (!needsApproval(tool)) {
      return ToolCallHookResult.proceed(context.call);
    }

    final g = gate;
    // fail-closed：有审批要求但没有审批通道（无 UI 的环境）⇒ 拒绝，并明说原因。
    if (g == null) {
      return ToolCallHookResult.deny(content: [
        TextPart(
          '未执行：`$tool` 在当前档位下需要用户批准，'
          '但这个环境没有可用的审批通道（无 UI）。按 fail-closed 原则拒绝执行；'
          '请改用不需要该操作的方式，或告诉用户无法继续的原因。',
        ),
      ]);
    }

    final args = _argsMapOf(context.call.arguments);
    final allowed = await g.requestApproval(
      callId: context.call.id,
      toolName: tool,
      args: args,
      risk: _riskOf(tool),
      detail: _summaryOf(tool, args),
      workspaceInside: _workspaceInside(tool),
    );
    if (allowed) {
      return ToolCallHookResult.proceed(context.call);
    }
    return ToolCallHookResult.deny(content: [
      TextPart(
        '未执行：用户拒绝了这次 `$tool` 调用（超时或关闭弹窗也按拒绝计）。'
        '**不要原样重试同一调用** —— 那只会再次弹窗打扰用户；'
        '请换一种不需要该操作的方式完成任务，或在最终回答里说明被拒后无法继续的部分。',
      ),
    ]);
  }

  /// 把模型给的原始参数 JSON 解析成字符串 map（弹窗展示用）。
  ///
  /// 解析失败不抛 —— 审批弹窗不能因为参数坏了而炸；给个 `_raw` 兜底，
  /// 用户至少能看到原始串。
  Map<String, String> _argsMapOf(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is Map) {
        return {
          for (final e in v.entries)
            e.key.toString(): e.value?.toString() ?? '',
        };
      }
    } catch (_) {
      // 落到下面的兜底
    }
    return {'_raw': raw};
  }

  /// 弹窗顶部的原因行（一句人话 + 参数短预览；完整参数由宿主弹窗展示）。
  String _summaryOf(String tool, Map<String, String> args) {
    if (args.isEmpty) return '模型请求执行 `$tool`。';
    final preview = args.entries
        .take(3)
        .map((e) => '${e.key}=${_clip(e.value, 120)}')
        .join('；');
    final more = args.length > 3 ? ' 等 ${args.length} 项参数' : '';
    return '模型请求执行 `$tool`（$preview$more）。';
  }

  String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  /// 一句话风险说明（INTERFACE.md N1 的 risk 字段；弹窗直接展示）。
  ///
  /// ## 为什么 git 要单独分组（2026-10-27，Step 2）
  ///
  /// git 的风险分布极不均匀：
  /// · `git_commit` 只是往本仓库写对象（可 reset 回来）；
  /// · `git_push` 是**把手机上的代码推到公网**，一次误推可能泄露密钥；
  /// · `git_checkout` 会**覆盖用户的文件**。
  ///
  /// 三者的危险程度差一个数量级，弹窗上必须让人一眼看出来是哪种。
  String _riskOf(String tool) {
    if (_shell.contains(tool)) {
      // 2026-10-29 事实句修正（Lead 反馈，与 system_prompt 的「两个执行面」对齐）：
      // 旧文案「在工作区里执行任意 shell 命令 —— 可能碰到工作区外的文件」是
      // **用户可见的错误事实**：agent 的命令默认在**沙箱**里跑（需要动 Android
      // 本身时才落手机 shell），沙箱与用户工作区是两套文件系统。
      return '在沙箱中执行任意 shell 命令 —— 沙箱与用户工作区是两套文件系统，'
          '命令读写的是沙箱内文件（需要动 Android 本身的命令会落到手机 shell）；'
          'kill/force-stop 类已被硬禁令拦截。';
    }
    if (_destructive.contains(tool)) {
      return '删除/移动/复制操作，不可逆或难逆 —— 删错数据找不回来。';
    }
    if (_apk.contains(tool)) {
      return '构建/逆向/安装 APK —— 写入沙箱外 staging、安装直接动设备。';
    }
    // ---- git（Step 2）----
    if (tool == 'git_push') {
      return '★ 把本地提交**推送到远程仓库** —— 代码会离开这台设备。'
          '推到公开仓库等于对外发布，推之前确认里面没有密钥。';
    }
    if (tool == 'git_clone') {
      return '从远程仓库克隆到本地 —— 会写入大量文件，占用存储。';
    }
    if (tool == 'git_pull' || tool == 'git_fetch') {
      return '从远程拉取更新 —— `pull` 会覆盖本地文件（只做快进，不自动合并）。';
    }
    if (tool == 'git_checkout') {
      return '切换分支 —— 会**覆盖工作区文件**。有未提交改动时会被拒绝。';
    }
    if (tool == 'git_commit' || tool == 'git_stage' || tool == 'git_unstage') {
      return '修改本地 git 仓库状态（暂存区 / 提交历史）—— 不碰工作区文件。';
    }
    if (tool == 'git_init') {
      return '在工作区里初始化一个 git 仓库（创建 `.git/` 目录）。';
    }
    return '会修改工作区内的文件（写/编辑/建目录）。';
  }

  /// 操作对象是否在工作区内（INTERFACE.md N1 的 workspaceInside 字段）。
  ///
  /// · 文件工具：路径按契约就是工作区相对路径 ⇒ 恒 true；
  /// · shell：静态判不了命令会碰哪里 ⇒ false（保守，让用户看到命令原文再批）；
  /// · APK：staging 在工作区外 ⇒ false；
  /// · git：`.git/` 在工作区内、`clone` 目标也在工作区内 ⇒ true；
  ///   **但推送是外发** ⇒ false（保守）。
  bool _workspaceInside(String tool) {
    if (tool == 'git_push') return false; // 外发代码，不在"工作区内"语义
    if (tool.startsWith('git_')) return true;
    return _workspaceMutating.contains(tool) || _destructive.contains(tool);
  }
}

/// 宽松 JSON 解析 —— 占位（实际用 dart:convert 的 jsonDecode）。
///
/// 保留这个函数名是为了明确：**解析失败不要抛给模型**，
/// 工具参数解析问题应该由 `dart_agent_core` 的 Tool 层统一处理。
Map<String, dynamic>? jsonDecodeLoose(String raw) => null;

// ============================================================================
// 对 UI 播报的事件（sealed，switch 是穷尽的）
// ============================================================================

sealed class HeraclesEvent {
  const HeraclesEvent();
}

/// **正文增量** —— 最终回答只认它。
final class HeraclesTextDelta extends HeraclesEvent {
  const HeraclesTextDelta(this.delta);
  final String delta;
}

/// **思考增量**（2026-10-22 新增）—— 与正文**严格分离**。
///
/// UI 把它渲染成一行可折叠的「思考」（与工具调用同一形状），
/// **绝不**混进最终回答。历史事故的根因是混在一起，不是"有思考"。
final class HeraclesThoughtDelta extends HeraclesEvent {
  const HeraclesThoughtDelta(this.delta);
  final String delta;
}

final class HeraclesRetrying extends HeraclesEvent {
  const HeraclesRetrying(this.reason);
  final String reason;
}

final class HeraclesToolRequested extends HeraclesEvent {
  const HeraclesToolRequested({
    required this.toolName,
    required this.arguments,
    this.id = '',
    this.surface,
    this.command,
  });
  final String toolName;
  final Map<String, dynamic> arguments;

  /// 这条命令会在哪个执行面跑：`'sandbox'` / `'device'`（2026-10-29）。
  ///
  /// UI 据此在卡片标题上写「在沙箱 / 在手机执行了命令」。
  /// `null` = 该工具不涉及执行面（读文件、git、web 等）。
  ///
  /// ⚠️ 这是**预判**：与真正执行时用同一张规则表（`decideSurface`）。
  /// 若执行时状态已变，以 `HeraclesToolFinished.metadata` 里的 `surface` 为准。
  final String? surface;

  /// 命令全文（**不截断**）—— 前端要完整显示，这里不做任何裁剪。
  final String? command;

  /// **框架的调用 id**（2026-10-24 新增）。
  ///
  /// 宿主落盘"tool_call 行"时带上它，历史回填才能把
  /// `ModelMessage(functionCalls)` 与 `FunctionExecutionResultMessage`
  /// **配对**重建 —— 没有它，工具历史永远回不了上下文（取舍①的根因）。
  /// 空串 = 该 provider 没给 id（此时宿主跳过落盘，回填退回旧行为）。
  final String id;
}

final class HeraclesToolFinished extends HeraclesEvent {
  const HeraclesToolFinished({
    required this.toolName,
    required this.isError,
    required this.output,
    required this.durationMs,
    this.metadata,
    this.id = '',
  });
  final String toolName;
  final bool isError;
  final String output;
  final int durationMs;
  final Map<String, dynamic>? metadata;

  /// **框架的调用 id**（2026-10-24 新增）—— 与 [HeraclesToolRequested.id]
  /// 配对，宿主据此把"结果行"落盘成可回填的形状（见 `session_history.dart`
  /// 取舍①）。空串 = provider 没给 id（旧行为）。
  final String id;
}

final class HeraclesPlanUpdated extends HeraclesEvent {
  const HeraclesPlanUpdated({required this.steps});
  final List<HeraclesPlanStep> steps;
}

/// **计划已收尾**（B8 P0，2026-10-30）—— 只在**本轮有过计划**时发。
///
/// ## 为什么需要独立事件（而不是塞进 finished/failed）
///
/// 用户重开会话时，历史里只有一串 `role:"plan"` 行（计划演化），不知道
/// "这份计划最后是达成还是被打断"。旧实现的结果是：中断的计划在灵动岛/
/// 计划卡上看起来像"还在进行中"，或者被误画成全绿勾。
///
/// ## 口径
///
/// · [reachedGoal] = `true`：run 正常结束 **且** 计划里每一步都
///   `done`/`cancelled`（取消的步骤算"有结论"）；此时 [reason] 为 `null`；
/// · [reachedGoal] = `false`：失败 / 用户取消 / 超时 / 预算或门禁熔断；
///   [reason] 是**人话**（"用户停止" / "运行失败：…" / "任务被中断：…"），
///   **不得**放堆栈或内部 id；
/// · 本轮从未出现计划 ⇒ **不发**这个事件（宿主据此区分"无计划"与"计划收尾"）。
///
/// ## 顺序
///
/// 与 run 终态（[HeraclesFinished]/[HeraclesFailed]）**同批、先于它们**发出，
/// 保证宿主先把计划封口、再发最终回答/失败原因（`local_agent` 有顺序测试）。
final class HeraclesPlanClosed extends HeraclesEvent {
  const HeraclesPlanClosed({required this.reachedGoal, this.reason});

  /// `true` = 计划达成；`false` = 中断（失败/取消/超时/熔断）。
  final bool reachedGoal;

  /// 未达成时的人话原因（达成时为 `null`）。
  final String? reason;
}

class HeraclesPlanStep {
  const HeraclesPlanStep(this.text, this.status);
  final String text;
  final HeraclesPlanStatus status;
}

enum HeraclesPlanStatus { pending, active, done, cancelled }

/// **上下文已压缩**（2026-10-23 新增）—— 让用户看得见"压缩真的发生了"。
///
/// ## 为什么必须播这个事件
///
/// 压缩是**有损**的：老消息被摘要成一段 XML 快照，细节丢了。在这之前，
/// 用户完全看不到它发生过 —— 表现只有两种，都很糟：
///
/// - 模型"突然忘了前面说过的事"（他以为模型变笨了）；
/// - 或者什么都没察觉，直到某天发现上下文被悄悄改写过。
///
/// 「上下文到 80% 自动压缩，然后继续任务」这个行为本身就是**要给用户看的**：
/// 他会看到"哦，它压缩了，所以刚才那段细节它可能不记得了"，而不是困惑。
///
/// ## 字段口径
///
/// - `beforeMessages` / `afterMessages`：**消息条数**。压缩后一般会**变小**，
///   但注意框架会往保留段头部**插入**一条摘要消息 + 一条确认（共 2 条），
///   所以条数不是"删掉多少"，而是**前后各自的真实值**。
/// - `beforeTokens` / `afterTokens`：按本压缩器的估算规则算出的 token 数
///   （**估算，不是 provider 上报值** —— 此刻还没有发请求）。
///   UI 上要说明这是估算，别让用户拿它跟顶栏的"命中率"比。
///
/// ⚠️ `afterTokens` **可能比 `beforeTokens` 大**（极少见但可能）：摘要文本
/// 本身也占 token，若被压掉的老消息很短、而摘要写得长，就会反弹。
/// 这不是 bug，如实报即可 —— 别在 UI 层假设"一定变少"。 
final class HeraclesContextCompressed extends HeraclesEvent {
  const HeraclesContextCompressed({
    required this.beforeMessages,
    required this.afterMessages,
    required this.beforeTokens,
    required this.afterTokens,
  });

  final int beforeMessages;
  final int afterMessages;
  final int beforeTokens;
  final int afterTokens;
}

/// **逐轮用量**（2026-10-22 补）—— provider 每完成一次真实请求上报一帧。
///
/// 这是"缓存命中率/上下文占用/本次用量"三个面板的**唯一数据源**。
/// 迁移时旧 Kotlin `TurnRecord` 的逐轮记账没有对应物，导致这些面板全部空转
/// （顶栏 `— 0%`、侧栏"不可用"）—— 不是 UI 坏了，是**没有数据**。
final class HeraclesTurnUsage extends HeraclesEvent {
  const HeraclesTurnUsage({
    required this.promptTokens,
    required this.outputTokens,
    this.cachedTokens,
  });

  final int promptTokens;
  final int outputTokens;

  /// `null` = provider **未上报**缓存字段 —— UI 显示"不可用"，不得当 0。
  final int? cachedTokens;
}

/// **模型降级发生**（D3，2026-10-25）—— 主模型失败后切到备用模型。
final class HeraclesFallback extends HeraclesEvent {
  const HeraclesFallback({required this.from, required this.to, required this.reason});
  final String from;
  final String to;
  final String reason;
}

/// **预算预警**（2026-10-24，E5）—— 工具调用预算用到 75% / 90% 时各播一次。
///
/// 为什么必须有：硬熔断是**止损**，不是**提醒**——用户在 200 次烧完之前
/// 对"快没了"一无所知。预警让"拆小任务 / 点停止"成为可做的决定。
final class HeraclesBudgetWarning extends HeraclesEvent {
  const HeraclesBudgetWarning({required this.used, required this.limit});
  final int used;
  final int limit;
}

final class HeraclesFinished extends HeraclesEvent {
  const HeraclesFinished({
    required this.finalText,
    required this.turns,
    required this.totalToolCalls,
    required this.wallClockMs,
  });
  final String finalText;
  final int turns;
  final int totalToolCalls;

  /// **真实墙钟**（含工具执行、审批等待），不是"模型往返累计"。
  final int wallClockMs;
}

final class HeraclesFailed extends HeraclesEvent {
  const HeraclesFailed(this.reason);
  final String reason;
}
