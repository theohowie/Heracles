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

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';

import '../capability/capabilities.dart';
import '../contract/contract.dart';
import '../context/window_ratio_compressor.dart';
import '../prompt/system_prompt.dart';
import '../tools/tool_factory.dart';
import 'tools/apk_tools.dart';
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

/// 一次运行的配置。
class RunOptions {
  const RunOptions({
    this.maxTurns = ContractAgent.maxTurns,
    this.maxToolCalls = ContractAgent.maxToolCalls,
    this.enablePlan = true,
    this.systemPrompts = const [],
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
    return switch (_config.provider) {
      BackendProvider.openAiCompatible => OpenAIClient(
          apiKey: _config.apiKey,
          baseUrl: _config.baseUrl,
        ),
      BackendProvider.anthropic => ClaudeClient(
          apiKey: _config.apiKey,
          baseUrl: _config.baseUrl,
        ),
      BackendProvider.openAiResponses => ResponsesClient(
          apiKey: _config.apiKey,
          baseUrl: _config.baseUrl,
        ),
    };
  }

  ModelConfig _modelConfig({String? model}) => ModelConfig(
        model: model ?? _config.modelName,
        maxTokens: _config.maxOutputTokens,
        temperature: _config.temperature,
      );

  /// 构建全部工具（**21 个**）。
  ///
  /// 21 的来源：**各 builder 实际返回数之和**，不是估的 ——
  /// 断言见 `test/tools_completeness_test.dart`（"必须恰好 21 个"）：
  /// `buildFileTools` 8 + `buildShellTools` 1 + `buildFileManageTools` 3 +
  /// `buildInfoTools` 2 + `buildApkTools` 5 + `buildInteractionTools` 2 = 21。
  ///
  /// 旧注释写"18 个"（审计 §3.3 #1：注释没跟上工具面扩张），已更正。
  ///
  /// 分组顺序即日志阅读顺序：**高频基础 → 危险手段 → 长耗时 → 交互**。
  List<Tool> _buildTools() {
    final factory = ToolFactory(_caps);
    return [
      ...buildFileTools(factory, _caps),        // 8 个：读/写/编辑/补丁/列/建目录/找/搜
      ...buildShellTools(factory, _caps),       // 1 个：run_shell_command
      ...buildFileManageTools(factory, _caps),  // 3 个：删除/移动/复制（有破坏性）
      ...buildInfoTools(factory, _caps),        // 2 个：web_fetch / check_device_state
      ...buildApkTools(factory, _caps),         // 5 个：构建/反编译/重打包/签名/安装
      ...buildInteractionTools(factory,         // 2 个：ask_user / save_memory
          askGate: _askGate, caps: _caps),
    ];
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
  Stream<HeraclesEvent> run(
    String userRequest, {
    CancelToken? cancelToken,
  }) async* {
    final bridge = StreamController<HeraclesEvent>();

    // 驱动整个 run（它自己负责把事件写进 bridge，并在结束时 close）。
    final runner = _drive(userRequest, bridge, cancelToken: cancelToken);

    try {
      yield* bridge.stream;
    } finally {
      // 消费端提前取消时也要等生产者收尾，避免留下悬空的 run。
      await runner;
    }
  }

  /// 真正的执行体：框架循环 → 事件桥。
  Future<void> _drive(
    String userRequest,
    StreamController<HeraclesEvent> bridge, {
    CancelToken? cancelToken,
  }) async {
    final emit = _Emitter(bridge);
    final wallClock = Stopwatch()..start();
    var totalToolCalls = 0;
    var budgetReached = false;

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
      ));
    });
    controller.on<PlanChangedEvent>((e) {
      final plan = e.plan;
      emit(HeraclesPlanUpdated(
        steps: [
          for (final s in plan.steps)
            HeraclesPlanStep(s.description, _mapStatus(s.status)),
        ],
      ));
    });
    controller.on<AfterCallLLMEvent>((e) {
      // ★ 2026-10-22：**逐轮用量记账**（此前完全缺失 —— 旧 Kotlin 的
      // `TurnRecord.cachedTokens/promptTokens/outputTokens` 在迁移中丢了，
      // 导致 App 的用量面板/顶栏命中率/右侧边栏全部"不可用"）。
      //
      // 数据源是框架 `ModelMessage.usage`（provider 上报的原值）。
      // ⚠️ 缓存字段必须区分**"上报了 0"与"没上报"**（`02-契约规范` §3.4：
      // 未上报时 UI 必须显示"不可用"，**不得用 0 代替** —— 0 会被读成"缓存坏了"）。
      final u = e.response.usage;
      if (u == null) return;
      emit(HeraclesTurnUsage(
        promptTokens: u.promptTokens,
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
    final summarizerClient = _config.summarizerModel == null ? null : _buildClient();
    final compressor = WindowRatioCompressor(
      client: summarizerClient ?? client,
      modelConfig: _modelConfig(model: _config.summarizerModel),
      modelWindowTokens: _config.modelWindowTokens,
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
    );

    // ---- 组装 StatefulAgent ----
    _state ??= AgentState(sessionId: _newSessionId());
    final agent = StatefulAgent(
      name: 'heracles',
      client: client,
      modelConfig: _modelConfig(),
      state: _state!,
      systemPrompts: [
        defaultSystemPrompt(_caps),
        ..._options.systemPrompts,
      ],
      tools: _buildTools(),
      controller: controller,
      compressor: compressor,
      planMode: _options.enablePlan ? PlanMode.auto : PlanMode.none,
      maxTurns: _options.maxTurns,
      hooks: [budgetHook],
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
    );

    // ---- 跑 ----
    var finished = false;
    try {
      await for (final ev in agent.runStream(
        [UserMessage.text(userRequest)],
        cancelToken: cancelToken,
      )) {
        // 框架的 Stream 事件只用来补我们 Controller 覆盖不到的（如工具请求）
        if (ev.eventType == StreamingEventType.functionCallRequest) {
          final calls = ev.data as List<FunctionCall>;
          for (final c in calls) {
            pendingToolStart[c.id] = Stopwatch()..start();
            emit(HeraclesToolRequested(
              toolName: c.name,
              arguments: _safeParseArgs(c.arguments),
            ));
          }
        }
      }
      wallClock.stop();
      emit(HeraclesFinished(
        finalText: _lastText(agent),
        turns: _state!.totalLoopCount,
        totalToolCalls: totalToolCalls,
        wallClockMs: wallClock.elapsedMilliseconds,
      ));
      finished = true;
    } on AgentException catch (e) {
      wallClock.stop();
      // 预算超限是**预期内的正常终止**，必须说清"任务没做完"，
      // 而不是混进"检测到循环"那句里（那会让用户以为模型在打转）。
      emit(HeraclesFailed(
        budgetReached
            ? _budgetMessage(_options.maxToolCalls, totalToolCalls)
            : (frameworkError ?? _describeException(e)),
      ));
    } catch (e) {
      wallClock.stop();
      emit(HeraclesFailed(
        budgetReached
            ? _budgetMessage(_options.maxToolCalls, totalToolCalls)
            : (frameworkError ?? '运行出错：$e'),
      ));
    } finally {
      // 生产者自己收尾。**绝不 await close()** —— 消费端可能已经提前走了
      // （`yield*` 被取消），此时 `close()` 的 Future 不会有人等。
      // 不 await 就不会挂住任何人。
      unawaited(bridge.close());
      if (!finished) wallClock.stop();
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
  /// 返回 `null` = 这个 provider 压根没上报缓存字段 ⇒ UI 必须显示"不可用"，
  /// **不许显示 0%**（0% 会被读成"缓存坏了"，那是两种完全不同的事）。
  ///
  /// 兼容三家 wire 的字段名：
  /// · OpenAI Chat：`prompt_tokens_details.cached_tokens`
  /// · Anthropic：`cache_read_input_tokens`
  /// · Responses：`input_tokens_details.cached_tokens`
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
    // 框架已把值归一到 cachedToken —— 非 0 时信它；为 0 且上面都没命中字段 ⇒ 未上报
    return u.cachedToken > 0 ? u.cachedToken : null;
  }

  String _newSessionId() =>
      's${DateTime.now().microsecondsSinceEpoch}';

  /// 取最后一轮的正文当最终回答。
  ///
  /// ⚠️ **只取 ModelMessage 的 `textOutput`**，不碰 `thought` ——
  /// 旧实现有过"思考被当答案"的事故（用户看到一堆英文推理）。
  String _lastText(StatefulAgent agent) {
    final msgs = _state?.history.messages ?? const [];
    for (final m in msgs.reversed) {
      if (m is ModelMessage) {
        final t = m.textOutput;
        if (t != null && t.trim().isNotEmpty) return t;
      }
    }
    return '';
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
  _ToolBudgetHook({required this.maxToolCalls, required this.onExceeded});

  final int maxToolCalls;
  final void Function() onExceeded;

  int _count = 0;

  @override
  FutureOr<ToolCallHookResult> beforeToolCall(ToolCallHookContext context) {
    _count++;
    if (_count > maxToolCalls) {
      onExceeded();
      return ToolCallHookResult.abort(
        reason: '工具调用已达上限 $maxToolCalls',
      );
    }
    return ToolCallHookResult.proceed(context.call);
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
  const HeraclesToolRequested({required this.toolName, required this.arguments});
  final String toolName;
  final Map<String, dynamic> arguments;
}

final class HeraclesToolFinished extends HeraclesEvent {
  const HeraclesToolFinished({
    required this.toolName,
    required this.isError,
    required this.output,
    required this.durationMs,
    this.metadata,
  });
  final String toolName;
  final bool isError;
  final String output;
  final int durationMs;
  final Map<String, dynamic>? metadata;
}

final class HeraclesPlanUpdated extends HeraclesEvent {
  const HeraclesPlanUpdated({required this.steps});
  final List<HeraclesPlanStep> steps;
}

class HeraclesPlanStep {
  const HeraclesPlanStep(this.text, this.status);
  final String text;
  final HeraclesPlanStatus status;
}

enum HeraclesPlanStatus { pending, active, done, cancelled }

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
