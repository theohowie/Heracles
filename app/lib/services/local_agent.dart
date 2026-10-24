/// **App ↔ backend 的接线层**（2026-10-22）。
///
/// ## 这一层解决什么问题
///
/// 重构前：`AgentBridge.run()` 走 MethodChannel `heracles/command` 的
/// `runAgent`，Kotlin 侧跑 `AgentLoop`，事件走 EventChannel `heracles/events`。
///
/// 重构后：**那 5 个 Kotlin 模块被删了**，`MainActivity` 里
/// `runAgent` / `listSessions` / `replyApproval` 这些 handler **全都不存在**
/// （只剩工作区登记、选择器、权限引导、健康读数）。也就是说：
/// 旧 `AgentBridge` 今天调用它们是**必然失败**的 —— 通道会回
/// `{"ok": false, "error": "未知方法：runAgent"}`。
///
/// 所以编排必须搬回来 —— 但这次是搬进 **Dart 进程内**（`backend/`），
/// 不再跨进程。这正好是这个仓库重构的本意：
///
/// ```
/// 旧：Flutter ──MethodChannel──> Kotlin(AgentLoop) ──> Kotlin(工具) ──> 设备
/// 新：Flutter ──直接调用──> Dart(HeraclesAgent) ──┐
///                  └──MethodChannel('heracles/device')──> 设备能力
/// ```
///
/// ## 为什么不重写 UI
///
/// `chat_screen.dart` 195 KB / 19 种事件、19 个 widget 测试文件 —— 那是
/// **已验证资产**。这一层的职责就是"让 backend 的事件长得跟旧 Kotlin 一样"，
/// 从而 UI **一行都不用改**。
///
/// ## 事件形状来自哪里
///
/// 以 `AgentEvent.fromMap`（UI 侧的唯一消费者）为准，逐字段对齐：
///
/// | UI 事件 | 何时发 | 关键字段 |
/// |---|---|---|
/// | `turn_started` | 每轮开始 | `index` |
/// | `step_started` | 每轮开始 | `stepId`=`turn-N`, `title`, `index` |
/// | `step_delta` | 正文增量 | `stepId`, `delta` |
/// | `step_ended` | 每轮结束 | `stepId`, `status`(ok/empty/error), `durationMs`, `summary` |
/// | `tool_started` | 模型请求工具后 | `tool`, `args`, `index` |
/// | `tool_finished` | 工具执行完 | `tool`, `result`, `ok`, `index`, `wallMs` |
/// | `plan_created` | 计划变化 | `planSteps`, `doneCount`, `activeIndex` |
/// | `finished` | 正常收尾 | `finalText`, `turnCount` |
/// | `failed` | 异常收尾 | `message` |
///
/// ## 与 `agent_runner.dart` 的关系
///
/// `agent_runner.dart` 是**纯翻译器**（无 IO、无状态持久化），本文件是
/// **驱动器**（建能力、建 agent、跑、落盘、回填结果）。分开是为了让翻译器
/// 能被单测覆盖，而驱动器只做"胶水"。
library;

import 'dart:async';

import 'package:heracles_backend/heracles_backend.dart';

import '../models/attachment.dart';
import '../models/settings.dart';
import '../widgets/tool_call_card.dart'
    show diffStatOf, estimatedDiffStatOf, changedFilesOf;
import 'agent_bridge.dart'
    show AgentEvent, AgentRunResult, AgentTurn, ToolState;
import 'device_capabilities.dart';
import 'global_memory.dart';
import 'image_input.dart';
import 'session_store.dart';

/// 一次 run 的句柄。
class LocalRunHandle {
  LocalRunHandle({
    required this.events,
    required this.result,
    required this.cancel,
  });

  final Stream<AgentEvent> events;
  final Future<AgentRunResult> result;
  final Future<bool> Function() cancel;
}

/// **App 侧的提问门禁**（`AskGate` 实现，2026-10-23 修「提问现在不可用」）。
///
/// ## 这条链路原来断在哪（三处，缺一处 ask_user 就是死工具）
///
/// 1. `AgentBridge.run()` 构造 `LocalAgentExecutor` 时**没传 `askGate`**
///    ⇒ backend 的 `ask_user` 工具 `isAvailable: () => askGate != null` 为 false
///    ⇒ 工具直接告诉模型"当前环境不支持询问用户"。
/// 2. 全仓**没有任何 `AskGate` 实现** ⇒ 就算传了也没东西可传。
/// 3. `AgentBridge.replyAsk()` 还在打**已删除的旧 Kotlin 通道**
///    ⇒ 回答永远回不到挂起的工具。
///
/// 本类补第 2 处；第 1、3 处分别在 `AgentBridge.run()` / `AgentBridge.replyAsk()`。
///
/// ## 职责
///
/// · `askUser(...)`：把 backend 的 `AskQuestion` 翻成 UI 认识的形状、
///   发一个 `ask_user` 事件、**挂起**等用户作答（带超时兜底）
/// · `replyAsk(...)`：UI 提交答案时**完成挂起**（不再跨进程）
/// · `abort()`：用户点「停止」时把挂起解掉 —— 否则工具要白等满 10 分钟
///
/// ## 为什么必须"挂起"而不是发完事件就返回
///
/// `ask_user` 的工具语义是"暂停等回答，拿到回答后继续"（见 backend
/// `interaction_tools.dart` 的 A 方案）。发完事件就返回等于**编造答案**；
/// 返回 null 才是"用户没答"，backend 会如实告诉模型并让它自行决策。
class LocalAskGate implements AskGate {
  /// 本 run 的事件出口 —— 由 [LocalAgentExecutor] 在 run 开始时用
  /// `controller.add` 接上（事件流在那边才创建得出）。
  void Function(AgentEvent)? _emit;

  /// 非 null = 此刻有题目在等用户回答。值类型可空：取消/超时用 `null` 完成。
  Completer<Map<String, List<String>>?>? _pending;

  /// 等用户回答的**上限**。
  ///
  /// 10 分钟：用户可能在处理别的事、切走了、或锁屏。不能永远挂住整个 run ——
  /// 超时后按"未回答"返回 null，由 backend 如实告诉模型并继续（绝不编答案）。
  static const answerTimeout = Duration(minutes: 10);

  /// 把本 run 的事件出口接上（每个 run 一个 gate 实例，只接一次）。
  void attach(void Function(AgentEvent) emit) => _emit = emit;

  /// 用户**点停止**时调用：让挂起的提问立刻以"未回答"收场。
  void abort() {
    final c = _pending;
    if (c != null && !c.isCompleted) {
      _pending = null;
      c.complete(null);
    }
  }

  /// 问用户（挂起直到回答 / 超时 / 取消）。
  ///
  /// 返回渲染好的人话文本（喂回模型）；`null` = 没有答案（超时/取消），
  /// backend 会如实告诉模型"用户没有回答"，**绝不编造**。
  @override
  Future<String?> askUser(List<AskQuestion> questions) async {
    // 已有提问挂着：backend 是串行的，正常不会发生。不覆盖，如实返回"没答案"。
    if (_pending != null) return null;
    // 没有 UI 出口（直接跑 executor 的测试/CLI 场景）：如实返回 null（问不了），
    // 而不是挂 10 分钟。
    if (_emit == null) return null;

    final c = Completer<Map<String, List<String>>?>();
    _pending = c;

    _emit!(AgentEvent(
      type: AgentEvent.kAskUser,
      ts: DateTime.now().millisecondsSinceEpoch,
      // 降级文案（UI 只在 questions 解析失败时用）；这里给题干，便于排障。
      message: questions.map((q) => q.question).join('\n'),
      // ★ 字段名必须与 `chat_screen._showAskDialog` 实际读取的一致：
      //   `id` / `question` / `multi` / `options[] {label, description}`
      questions: [
        for (final q in questions)
          <String, dynamic>{
            'id': q.id,
            'question': q.question,
            'multi': q.multi,
            'options': [
              for (final o in q.options)
                <String, dynamic>{
                  'label': o.label,
                  'description': o.description ?? '',
                },
            ],
          },
      ],
    ));

    Map<String, List<String>>? answers;
    try {
      answers = await c.future.timeout(
        answerTimeout,
        // 超时 = 未回答（返回 null），不是异常 —— backend 的 null 分支就是
        // "用户没答，请自行合理决定并说明假设"。
        onTimeout: () {
          _pending = null;
          // ignore: avoid_print
          print('[heracles][ask] 提问超时（${answerTimeout.inMinutes} 分钟）未回答');
          return null;
        },
      );
    } finally {
      if (identical(_pending, c)) _pending = null;
    }
    if (answers == null) return null;
    return _formatAnswers(questions, answers);
  }

  /// UI 提交答案（题目 id → 选中的 label / 自填原文）。
  ///
  /// 返回 `true` = 确实交到了一个正在等待的提问；
  /// `false` = 没有活动提问（run 已结束 / 已超时 / 已取消）——
  /// **如实告知，不静默成功**。
  Future<bool> replyAsk(Map<String, List<String>> answers) async {
    final c = _pending;
    if (c == null || c.isCompleted) return false;
    _pending = null;
    c.complete(Map<String, List<String>>.from(answers));
    return true;
  }

  /// 把答案渲染成给模型看的**人话**：每题一行 `问题 → 回答`。
  ///
  /// · 未回答的题写「未回答」——**绝不编答案**
  /// · 空串/重复项过滤（UI 可能回传空自填框）
  String _formatAnswers(
    List<AskQuestion> questions,
    Map<String, List<String>> answers,
  ) {
    final buf = StringBuffer();
    for (final q in questions) {
      final picked = <String>[];
      for (final raw in answers[q.id] ?? const <String>[]) {
        final t = raw.trim();
        if (t.isNotEmpty && !picked.contains(t)) picked.add(t);
      }
      buf.writeln('${q.question} → ${picked.isEmpty ? '未回答' : picked.join('、')}');
    }
    return buf.toString().trimRight();
  }

  /// 审批门禁（backend `AskGate` 接口的一部分，本任务不涉及）。
  ///
  /// ⚠️ 今天 backend **没有任何工具调用它**（全仓只有接口声明处 + 0 调用）——
  /// 危险工具的审批走的是另一条链路（工具返回 `CapabilityNeedsApproval`
  /// → 事件 `approval_request` → `AgentBridge.replyApproval`）。
  /// 这里实现成**保守拒绝**：万一将来有人接上这个接口却忘了实现，
  /// 宁可拒绝也不能静默放行。
  @override
  Future<bool> requestApproval(String toolName, String detail) async => false;
}

/// **进程内 agent 执行器**。
///
/// 生命周期：一次 run 一个实例（内部持有 `HeraclesAgent` 与取消状态）。
class LocalAgentExecutor {
  LocalAgentExecutor({
    required this.workspacePath,
    required this.settings,
    required this.sessionStore,
    this.askGate,
  });

  final String workspacePath;
  final AppSettings settings;
  final SessionStore sessionStore;

  /// 提问/审批门禁（UI 注入）。`null` = 当前环境不能问用户。
  final AskGate? askGate;

  /// 当前在跑的取消令牌（`null` = 没有 run 在跑）。
  ///
  /// ## 为什么取消要「令牌 + 标志」两件
  ///
  /// `CancelToken.cancel()` 只让**框架**停下来；我们的 `_drive` 还需要知道
  /// "这是用户主动取消的"（而不是框架判定循环），才能给出正确措辞
  /// （"任务已取消"而不是"检测到循环"）。
  bool _cancelled = false;
  Completer<void>? _interruptSignal;

  /// 跑一轮。
  ///
  /// 返回的 `events` 是**广播流**（UI 与调试面板可同时听）。
  ///
  /// ## `attachments`（2026-10-23 补）
  ///
  /// 图片附件在这里被真正接上：先按**模型是否支持视觉**判断，再压缩编码成
  /// `ImagePart`，最后作为 `UserMessage` 的额外内容块传给后端。
  /// 之前这条链路在 `AgentBridge → executor → agent` 三处逐段断掉，
  /// 导致"模型明明能识图，App 里却完全看不到图"。
  Future<LocalRunHandle> run({
    required String request,
    String? sessionId,
    List<HAttachment> attachments = const [],
  }) async {
    final controller = StreamController<AgentEvent>.broadcast();

    // ★★ 2026-10-23（修「提问不可用」）：把本 run 的事件出口接到提问门禁上。
    //
    // 为什么必须在这里接：`AskGate` 由桥接层创建（它要持有它才能把用户的
    // 回答交回来），但**事件流是执行器在 run 里才建出来的** —— 门禁没有
    // `controller.add` 就发不出 `ask_user` 事件 ⇒ 弹窗永远不会出现。
    //
    // `attach` 不是必须的（测试/CLI 直接跑 executor 时没有 UI）：那种情况
    // `askUser` 会如实返回 null（"问不了"），不会挂 10 分钟。
    final gate = askGate;
    if (gate is LocalAskGate) gate.attach(controller.add);

    // ---- 能力组装（设备侧）----
    final caps = buildDeviceCapabilities(workspaceRoot: workspacePath);

    // ---- 模型配置 ----
    final provider = settings.effectiveProvider!; // 调用方已校验非 null
    final config = BackendConfig(
      apiKey: provider.apiKey,
      modelName: provider.model,
      baseUrl: provider.baseUrl,
      provider: switch (provider.protocol) {
        ProviderProtocol.anthropic => BackendProvider.anthropic,
        ProviderProtocol.openaiResponses => BackendProvider.openAiResponses,
        ProviderProtocol.openaiChat => BackendProvider.openAiCompatible,
      },
      // ★ 单窗口上限取用户配置的模型上下文（`fetchModels` 从服务端读到的，
      //   不是猜的）。`0`/未知 ⇒ 用契约默认值，别拿 4K 去压缩 1M 模型。
      modelWindowTokens: provider.contextLength > 0
          ? provider.contextLength
          : ContractModel.defaultWindowTokens,
    );

    // ---- 轮次上限 ----
    // `settings.maxTurns == 0` 的语义是"按后端自动"（UI 的 `kMaxTurnsOptions`）。
    final maxTurns = settings.maxTurns > 0 ? settings.maxTurns : ContractAgent.maxTurns;

    // ---- 长期记忆（2026-10-23 接通）----
    //
    // ## 修之前为什么"换会话必失忆"
    //
    // 记忆原来只有写、没有读：
    //   · 写：`save_memory` 工具 → `MemoryCapability.append` → 通道 `memory.append` ✅
    //   · 读：`renderMemory()` **全仓 0 处调用** ❌
    //
    // ⇒ 模型能把约定记进去，但**任何一次 run 都不会把记忆读进上下文**。
    // 用户感知就是"它明明记住过，换个会话又忘了"。
    //
    // ## 必须在 `HeraclesAgent` 构造**之前**读
    //
    // 因为记忆是通过 `RunOptions.memoryNote` 传进去的，而 `RunOptions` 是
    // 构造参数 —— 构造完再读就来不及了（要重建 agent，白做一遍工作）。
    //
    // ## 读失败 / 没有记忆 ⇒ null（不阻断运行）
    //
    // 记忆是锦上添花，不是主链路。读不到就当"没有记忆"继续跑 ——
    // 最差退化成"这轮没有记忆"，而不是让用户看到"运行失败"。
    // `GlobalMemory.read()` 本身永不抛（通道契约：失败是 `{ok:false,error}`），
    // 这里再兜一层是防"意料之外的异常"。
    //
    // 用 `readResult()` 而不是 `read()`：需要区分"没有记忆"（正常）与
    // "读不出来"（异常）。前者注入空段毫无意义，后者应该让排障能看见。
    String? memoryNote;
    try {
      // ★ 2026-10-23 真机回归修复：**这条 await 必须带超时**。
      //
      // 真机实测（09:50 复测）：这条通道调用**不返回**（不是抛错，是永远挂着），
      // 而它挡在 `HeraclesAgent` 构造之前 ⇒ 整个 run 一个事件都发不出来：
      // 界面上只剩用户气泡、顶栏用量 `— 0%`、没有分析行也没有工具行 ——
      // 看起来就是"卡死不动"。
      //
      // 记忆是锦上添花，**绝不能让它把主链路冻住**：
      // 超时 ⇒ TimeoutException ⇒ 走下面 catch ⇒ memoryNote = null ⇒ 正常运行。
      // 900ms 是本地文件读取的宽容上限（正常是微秒级）。
      final mem = await const GlobalMemory()
          .readResult()
          .timeout(const Duration(milliseconds: 900));
      if (mem.error == null && !mem.isEmpty) {
        memoryNote = mem.text;
      }
    } catch (_) {
      // 保持 null（当作没有记忆）。
    }

    // ---- 图片附件 → 多模态输入（2026-10-23 接通）----
    //
    // ## 修之前发生了什么
    //
    // 用户上传图片后，模型完全看不到 —— 因为附件在**三处**逐段被丢掉：
    //   `AgentBridge.run(attachments:)` ❌ 收了没用
    //   `LocalAgentExecutor.run()`        ❌ 参数表里根本没有附件
    //   `HeraclesAgent.run()`             ❌ 只收 String，首轮硬编码纯文本
    //
    // ## 两个必须做对的地方
    //
    // 1. **能力判断**（[modelSupportsVision]）：纯文本模型收到图片块会 400
    //    或**静默忽略**。后者更糟 —— 用户以为模型看过图。所以不支持时
    //    **不塞图**，并把这个事实明说给用户。
    // 2. **压缩**（[prepareImageParts]）：手机照片 base64 后 4–7 MB，
    //    不压缩基本等于把这一轮发废。
    List<ImageInput>? images;
    final imageNotes = <String>[];
    if (attachments.isNotEmpty) {
      final imageCount = attachments.where((a) => a.isImage).length;
      final support = visionSupportOf(provider.model);
      if (imageCount > 0 && support == VisionSupport.no) {
        // 只有**明确知道**是纯文本模型才拦；"未知"照发（见 VisionSupport 注释）
        imageNotes.add(
          '当前模型「${provider.model}」是纯文本模型，$imageCount 张图片没有发送。'
          '（可切换到支持视觉的模型后再发一次）',
        );
      } else if (imageCount > 0) {
        try {
          final prepared = await prepareImageParts(attachments);
          if (prepared.images.isNotEmpty) images = prepared.images;
          imageNotes.addAll(prepared.notes);
        } catch (e) {
          // 图片是**增强**，不是主链路：处理不了就明说，别拖垮整轮
          imageNotes.add('图片处理失败：${e.runtimeType}。本轮按纯文本发送。');
        }
      }
    }

    final agent = HeraclesAgent(
      config: config,
      capabilities: caps,
      options: RunOptions(
        maxTurns: maxTurns,
        maxToolCalls: ContractAgent.maxToolCalls,
        memoryNote: memoryNote,
      ),
      askGate: gate,
    );

    final tr = _Translator(controller.add);

    // ---- 真正驱动（不 await，让 events 先被订阅）----
    final done = _drive(
      agent,
      tr,
      request,
      sessionId,
      controller,
      images: images,
      imageNotes: imageNotes,
    );

    return LocalRunHandle(
      events: controller.stream,
      result: done,
      cancel: () async {
        if (_cancelled) return false;
        // 标记"这是用户取消"，让收尾措辞正确
        _cancelled = true;
        // ★ 2026-10-23：若此刻正在等用户回答，先把它解掉 ——
        //   否则 backend 的 `ask_user` 工具会白等满 10 分钟，用户以为
        //   「停止」没生效。解掉后工具拿到 null（= 未回答），如实收场。
        if (gate is LocalAskGate) gate.abort();
        _interruptSignal?.complete();
        return true;
      },
    );
  }

  /// 本轮**送给模型**的请求文本：用户原话 + 附件提示（如果有）。
  ///
  /// ## 为什么提示只加在这里，不加进 `request` 本身
  ///
  /// `request` 同时是**落盘的用户消息**（会话 `.jsonl` 的 `role:"user"` 行，
  /// 也是界面上那个气泡）。把"图片被跳过"这类系统提示写进去，用户会看到
  /// 自己的话被改写了 —— 那是绝对不能做的。
  ///
  /// 所以：**模型看到的是"原话 + 提示"，会话里存的是原话**。
  /// 提示用方括号独立成段，并明确写出"不要复述这段元信息"，
  /// 避免模型把它当成用户问题的一部分来回答。
  String _requestForModel(String request, List<String> imageNotes) {
    if (imageNotes.isEmpty) return request;
    final buf = StringBuffer()
      ..writeln(request)
      ..writeln()
      ..writeln('[附件处理提示（系统生成，请在回答里如实告知用户，不要复述本段原文）]');
    for (final n in imageNotes) {
      buf.writeln('· $n');
    }
    return buf.toString();
  }

  /// 执行体：把 `HeraclesAgent.run()` 的事件逐条翻译并落盘。
  Future<AgentRunResult> _drive(
    HeraclesAgent agent,
    _Translator tr,
    String request,
    String? sessionId,
    StreamController<AgentEvent> controller, {
    List<ImageInput>? images,
    List<String> imageNotes = const [],
  }) async {
    final sw = Stopwatch()..start();

    // ---- 会话：没有就新建（"在工作区里直接发消息"的行为）----
    var sid = sessionId;
    if (sid == null || sid.isEmpty) {
      sid = await sessionStore.createSession(_titleOf(request));
    } else {
      await sessionStore.touchSession(sid);
    }

    // ---- 跨轮记忆：读会话历史（2026-10-23 修）----
    //
    // ★★ **必须在下面"用户消息落盘"之前读** ★★
    //
    // 落盘之后读，就会读到本轮刚写进去的那条 user 行 ⇒ 模型看到
    // **同一条用户消息出现两遍**（历史里一遍 + 本轮 request 一遍）。
    // 顺序就是正确性，所以这两步紧邻、且读在前。
    //
    // ## 修之前为什么"模型记不住上一轮"
    //
    // 每次 run 都 `new HeraclesAgent(...)`，而它的 `_state` 是 `??=`
    // 初始化 ⇒ 每个实例都从**空历史**开始。加上这里从来没读过会话文件，
    // 模型看不到上一轮的 user/assistant —— 表现是"它忘了刚才在聊什么"，
    // 顺带让前缀缓存几乎全不命中（真机 1%）。
    //
    // ## 读失败怎么办
    //
    // **不阻断运行**：历史读不到只意味着"这轮没有记忆"，任务本身还能做。
    // 所以当空历史处理 —— 最差退化回旧行为（不会崩、不会假装有记忆）。
    // （`SessionStore.loadMessages` 自身把人话原因放进返回值、不抛；
    //   这里兜的是意料之外的异常。）
    //
    // ## 为什么用 `var` 不写显式类型
    //
    // `LLMMessage` 属于 `dart_agent_core`，而那个包在 `app/pubspec.yaml` 里
    // 只是**传递依赖**（app 只依赖 `heracles_backend`）。写显式类型就得
    // `import 'package:dart_agent_core/...'` ⇒ 触发
    // `depend_on_referenced_packages`，并把"谁的依赖谁负责"这条边界糊掉。
    // 让编译器从 `sessionRowsToHistory` 的返回值推导即可。
    var history = sessionRowsToHistory(const <Map<String, dynamic>>[]);
    try {
      // ★ 2026-10-23：与记忆读同一类风险 —— **必须带超时**。
      // 这条走 `fs.readTailLines`（本轮新增的通道方法），真机上若它不返回，
      // run 同样会永远停在起点（用户只看到自己的气泡，没有任何反应）。
      // 历史读不到 ⇒ 空历史继续跑（最差退化成"这轮没有跨轮记忆"）。
      final rows = await sessionStore
          .loadMessages(sid)
          .timeout(const Duration(milliseconds: 1800));
      // `dropLastUserIfMatches`：双保险。
      //
      // 正常路径下这里读的是**落盘之前**的文件，所以末尾不会有本轮那条。
      // 但有两种情况会让它出现：
      //   · 重试/重入（同一个 sessionId 的上一轮刚好写过同样的请求）
      //   · 将来把"读"挪到别处、顺序被人改错
      // 一旦出现，模型就会看到同一条用户消息两遍。
      // 这里顺手挡掉 —— 代价是"用户真的重复问同一句"时那一轮的历史里
      // 会少一条重复项，但本轮请求本身还在，语义不丢。
      history = sessionRowsToHistory(
        rows,
        dropLastUserIfMatches: request,
      );
    } catch (_) {
      // 保持空历史。
    }

    // 用户消息先落盘（与旧 Kotlin 的顺序一致：用户消息先于一切）
    await sessionStore.appendMessage(sid, {
      'role': 'user',
      'text': request,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    tr.sessionId = sid;

    /// 待配对的工具调用：`工具名 → [(参数, 发起时轮次), …]`（桶内 FIFO）。
    ///
    /// ## 为什么必须带上"发起时轮次"
    ///
    /// UI 用 `_toolKey(index, tool, args)` 配对 start/finish。框架是
    /// **发起工具 → 进下一轮 → 工具才回结果**，等结果回来时翻译器的
    /// `_turn` 已经变了 ⇒ 若不记住发起时的轮次，卡片会永远停在"执行中"
    /// （真机复现：`正在查看目录文件 执行中`，而落盘日志是 `succeeded`）。
    ///
    /// ## 为什么按"工具名分桶 + 桶内 FIFO"
    ///
    /// 框架可能 `Future.wait` **并行**跑同名工具（例如同时读两个文件），
    /// 按名字存单个值会互相覆盖（旧实现"耗时按名字配对"就是这个形状的 bug）。
    final pendingArgs =
        <String, List<({Map<String, dynamic> args, int turn})>>{};

    var failed = false;
    var cancelled = false;
    var finalText = '';

    // ★ 变更聚合（2026-10-22，用户要求对齐参考界面的"已编辑 N 个文件"卡片）
    //
    // 数字来源是**工具结果里的 diff**（`diffStatOf`），不是模型自报 ——
    // 自报会撒谎，diff 不会。写类工具按**相对路径**聚合（同一文件改两次
    // 合并成一行，增删相加）。
    final changes = <String, ({int added, int removed})>{};
    const writeTools = {
      'write_file', 'edit', 'apply_patch', 'mkdir',
      'delete_path', 'move_path', 'copy_path',
    };

    try {
      // ★ 跨轮记忆在这里生效：`history` 成为 state 的开头，
      //   本轮 `request` 由框架追加在其**之后**（append-only，前缀缓存靠它）。
      //
      // ★ 图片与附件提示：`images` 进 `UserMessage` 的多模态内容块；
      //   `imageNotes` **只加给模型这一轮**（提示它"有图没发出去/被跳过"），
      //   不写进会话文件 —— 用户气泡必须保持他自己打的原话。
      await for (final ev in agent.run(
        _requestForModel(request, imageNotes),
        history: history,
        images: images,
      )) {
        switch (ev) {
          case HeraclesThoughtDelta(:final delta):
            tr.thought(delta);
          case HeraclesTextDelta(:final delta):
            tr.text(delta);
          case HeraclesRetrying(:final reason):
            tr.retrying(reason);
          case HeraclesTurnUsage(
              :final promptTokens,
              :final outputTokens,
              :final cachedTokens,
            ):
            // 逐轮用量（provider 真实上报）—— 顶栏命中率 / 侧栏 / 本次用量的数据源
            tr.usage(
              prompt: promptTokens,
              output: outputTokens,
              cached: cachedTokens,
            );
          case HeraclesToolRequested(:final toolName, :final arguments):
            tr.toolRequested(toolName, arguments);
            (pendingArgs[toolName] ??=
                    <({Map<String, dynamic> args, int turn})>[])
                .add((args: arguments, turn: tr.currentTurn));
          case HeraclesToolFinished(
              :final toolName,
              :final isError,
              :final output,
              :final durationMs,
            ):
            final bucket = pendingArgs[toolName];
            final pending = (bucket != null && bucket.isNotEmpty)
                ? bucket.removeAt(0)
                : null;
            final args = pending?.args ?? const <String, dynamic>{};
            tr.toolFinished(
              toolName,
              args,
              isError,
              output,
              durationMs,
              turn: pending?.turn,
            );
            // 本轮用量 + 工具信息齐了 ⇒ 结清成一条 AgentTurn
            tr.settleTurn();
            // 写类工具且成功 ⇒ 计入变更报告（失败不计：什么都没改）
            if (!isError && writeTools.contains(toolName)) {
              // ★ 与工具卡片同一套取数逻辑（`_stat`）：
              //   结果里有 diff 就用 diff（权威），没有才退回按参数估算
              //   （`content` 的行数 / `new_string`-`old_string`）。
              //   真机教训：只用 `diffStatOf(output)` 时 write_file 的
              //   结果没有 diff 正文 ⇒ 卡片算出 +0 −0（假数字）。
              final strArgs = args.map((k, v) => MapEntry(k, v.toString()));
              final fromResult = diffStatOf(output);
              final stat = fromResult.isDiff ? fromResult : estimatedDiffStatOf(strArgs);
              for (final f in changedFilesOf(strArgs)) {
                final prev = changes[f];
                changes[f] = (
                  added: (prev?.added ?? 0) + stat.added,
                  removed: (prev?.removed ?? 0) + stat.removed,
                );
              }
            }
            await sessionStore.appendMessage(sid, {
              'role': 'tool',
              'tool': toolName,
              'args': args,
              'result': output,
              'state': isError ? 'failed' : 'succeeded',
              'ok': !isError,
              'ts': DateTime.now().millisecondsSinceEpoch,
            });
          case HeraclesPlanUpdated(:final steps):
            tr.planUpdated(steps);
          case HeraclesContextCompressed(
              :final beforeMessages,
              :final afterMessages,
              :final beforeTokens,
              :final afterTokens,
            ):
            // ★ 上下文自动压缩（2026-10-23）——
            //   可能出现在 run **中间**（框架每轮循环开头检查），
            //   所以按到达顺序插进对话流，不是等结束再报。
            tr.contextCompressed(
              beforeMessages: beforeMessages,
              afterMessages: afterMessages,
              beforeTokens: beforeTokens,
              afterTokens: afterTokens,
            );
          case HeraclesFinished(finalText: final ft, turns: final turnCount):
            finalText = ft;
            tr.endStep(status: ft.trim().isEmpty ? 'empty' : 'ok');
            tr.settleTurn(); // 最终回答轮（无工具）也要记账
            tr.finished(ft, turnCount, sw.elapsedMilliseconds);
          case HeraclesFailed(:final reason):
            failed = true;
            tr.endStep(status: 'error');
            tr.settleTurn();
            tr.failed(reason);
        }

        // ★ 步骤落盘（2026-10-22）：`endStep` 会把这一轮的步骤暂存起来，
        // 这里按**事件发生的顺序**取走并追加到 `.jsonl`。
        //
        // 为什么放在 switch 之后而不是 endStep 里直接写：
        // 翻译器不做 IO；而且这样能保证**同一顺序**（步骤 → 之后的工具行），
        // 重开会话时回放顺序与实时一致。
        final stepRec = tr.takeStepRecord();
        if (stepRec != null) {
          await sessionStore.appendMessage(sid, stepRec);
        }
      }
    } catch (e) {
      failed = true;
      tr.endStep(status: 'error');
      tr.failed(_humanize(e));
      final stepRec = tr.takeStepRecord();
      if (stepRec != null) {
        await sessionStore.appendMessage(sid, stepRec);
      }
    } finally {
      sw.stop();
      if (_cancelled && !failed) {
        cancelled = true;
        tr.failed('任务已取消。');
      }
      // ★ 2026-10-22 真机修复：**这里不能关流** ——
      //   变更报告（`kChanges`）要在流关闭**之前**发，
      //   否则 `controller.add` 抛 `Bad state: Cannot add new events
      //   after calling close`，整次 run 被标成"运行失败"（真机复现过）。
      //   关流挪到下面收尾动作全部做完之后。
    }

    // ---- 变更报告（2026-10-22 用户指正位置：总结**下面**、操作行**上面**）----
    //
    // 之前发独立的 `kChanges` 事件 + 独立 `role:"changes"` 行 ⇒ 卡片渲染在
    // 助手消息**上面**（事件比 run 返回的 finalText 早到）。
    // 现在**挂到助手消息上**：
    // · 实时：`AgentRunResult.changeFiles`，chat_screen 插最终回答时带上；
    // · 落盘：写进 assistant 行的 `changes` 字段（重开顺序天然正确）。
    final changeFiles = [
      for (final e in changes.entries)
        {'path': e.key, 'added': e.value.added, 'removed': e.value.removed},
    ];

    // 关流：**绝不 await**（消费端可能已走，await 会挂住）
    unawaited(controller.close());

    // ---- 最终结果落盘（助手回答）----
    //
    // ★ 2026-10-22：`prompt/out/cached` 从**恒 0** 改为真实上报值
    //   （最后一轮的用量 —— 旧 Kotlin 就是这个口径）。
    if (finalText.isNotEmpty) {
      final last = tr.turnRecords.isNotEmpty ? tr.turnRecords.last : null;
      await sessionStore.appendMessage(sid, {
        'role': 'assistant',
        'text': finalText,
        'cached': last?.cachedTokens,
        'prompt': last?.promptTokens ?? 0,
        'out': last?.outputTokens ?? 0,
        'ms': sw.elapsedMilliseconds,
        if (changeFiles.isNotEmpty) 'changes': changeFiles,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    } else if (changeFiles.isNotEmpty) {
      // 没有最终回答（失败/取消）但确实动了文件 ⇒ 单独落一条，账不能丢。
      await sessionStore.appendMessage(sid, {
        'role': 'changes',
        'files': changeFiles,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    }

    // ---- 组装 AgentRunResult（UI 的权威结果）----
    //
    // 2026-10-22：`turns` 与三个 token 总数、稳态命中率**全部换成真实记账**
    // （此前 turns 恒空、token 恒 0 —— 顶栏与侧栏"不可用"的根因）。
    lastFrozenTokens = tr.firstTurnPrompt;
    return AgentRunResult(
      stopReason: cancelled
          ? '已取消'
          : failed
              ? '运行失败'
              : '已给出最终回答',
      finalText: finalText,
      turns: tr.turnRecords,
      totalCachedTokens: tr.totalCached,
      totalPromptTokens: tr.totalPrompt,
      totalOutputTokens: tr.totalOutput,
      steadyHitRate: tr.steadyHitRate,
      changeFiles: changeFiles.isNotEmpty ? changeFiles : null,
      taskWallMs: sw.elapsedMilliseconds,
      sessionId: sid,
      cancelled: cancelled,
    );
  }

  /// 上一次 run 的**冻结区** token（= 首轮 promptTokens，provider 真实上报）。
  /// `-1` = 还没跑过 / 没有用量。`AgentBridge` 在 run 结束后读走它，
  /// 供顶栏"上下文占用"与侧栏"系统提示与工具定义"使用。
  int lastFrozenTokens = -1;

  /// 从用户请求里取一个会话标题（取首行、截断）。
  String _titleOf(String request) {
    final firstLine = request.split('\n').first.trim();
    if (firstLine.isEmpty) return '新会话';
    return firstLine.length <= 24 ? firstLine : '${firstLine.substring(0, 24)}…';
  }

  String _humanize(Object e) {
    final s = e.toString();
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }
}

/// `HeraclesEvent` → UI `AgentEvent` 的翻译器（带轮次/步骤状态）。
class _Translator {
  _Translator(this._sink);

  final void Function(AgentEvent) _sink;

  String? sessionId;

  int _turn = 0;
  final StringBuffer _text = StringBuffer();

  /// 本轮**思考**累积（与 [_text] 严格分离）。
  ///
  /// 分开存的两条理由：
  /// 1. 最终回答只认正文 —— 思考混进去就是"把推理当答案"的历史事故；
  /// 2. `step_ended` 的摘要要在"只有思考、没有正文"时退到思考，
  ///    否则「思考」行展开是空的。
  final StringBuffer _reasoning = StringBuffer();
  final Stopwatch _clock = Stopwatch();
  final List<_ToolRecord> _toolLog = [];

  // ==========================================================================
  // 逐轮用量记账（2026-10-22 补 —— 迁移时旧 Kotlin `TurnRecord` 的账没搬过来，
  // 导致顶栏命中率 `— 0%`、右侧边栏"不可用"、本次用量全 0）
  // ==========================================================================

  /// 本轮 provider 上报的用量（`HeraclesTurnUsage` 到达时填，`endStep`/工具结束时结清）。
  int _curPrompt = 0;
  int _curOutput = 0;
  int? _curCached; // null = 未上报（不得当 0，契约 §3.4）
  bool _curUsageSeen = false;

  /// 本轮的工具（旧 `TurnRecord` 一轮记一个工具；并行批次里记第一个完成的）。
  String? _curTool;
  Map<String, String>? _curToolArgs;
  String? _curToolResult;
  bool? _curToolOk;

  /// 逐轮记录 —— `AgentRunResult.turns` 的数据源（用量面板/步骤回放都读它）。
  final List<AgentTurn> turnRecords = [];

  /// **正文平滑器** —— 把大块 delta 切成 ≤4 字小片、按固定节拍发出。
  ///
  /// 与 [_sink] 绑在一起构造（见构造函数）：它是这条链路上唯一的出口，
  /// 平滑器只是"改变节奏"，不改变内容。
  late final _TextSmoother _smoother =
      _TextSmoother(_emitTextDelta);

  int totalPrompt = 0;
  int totalOutput = 0;
  int totalCached = 0;

  /// provider 是否**至少上报过一次**缓存字段 —— 一次都没有 ⇒ 命中率显示"不可用"。
  bool anyCachedReported = false;

  /// 每轮命中率（只收上报了缓存的轮）。
  final List<double> _hitRates = [];

  /// 冻结区估算 = **首轮** promptTokens（provider 真实上报，非估算器）。
  int firstTurnPrompt = -1;

  /// 收一帧逐轮用量。
  void usage({required int prompt, required int output, int? cached}) {
    _curPrompt = prompt;
    _curOutput = output;
    _curCached = cached;
    _curUsageSeen = true;
    totalPrompt += prompt;
    totalOutput += output;
    if (_hitRates.isEmpty && firstTurnPrompt < 0) firstTurnPrompt = prompt;
    if (cached != null) {
      anyCachedReported = true;
      totalCached += cached;
      if (prompt > 0) _hitRates.add(cached / prompt);
    }
  }

  /// 结清本轮，产出一条 `AgentTurn`。
  ///
  /// 时机有两处：**工具结束时**（本轮带工具）与 **run 收尾时**（最终回答轮）。
  /// 谁先看到 `_curUsageSeen` 谁结清，结完置 false ⇒ 一轮只记一条。
  void settleTurn({int? wallMs}) {
    if (!_curUsageSeen) return;
    _curUsageSeen = false;
    turnRecords.add(AgentTurn(
      index: _turn,
      verdict: _curTool == null
          ? (_curText.isEmpty ? '本轮无输出' : '给出回答')
          : (_curToolOk == true ? '工具成功' : '工具失败'),
      tool: _curTool,
      args: _curToolArgs,
      result: _curToolResult,
      wallMs: wallMs ?? _clock.elapsedMilliseconds,
      cachedTokens: _curCached,
      promptTokens: _curPrompt,
      outputTokens: _curOutput,
      toolState: _curTool == null
          ? ToolState.none
          : (_curToolOk == true ? ToolState.succeeded : ToolState.failed),
    ));
    _curTool = null;
    _curToolArgs = null;
    _curToolResult = null;
    _curToolOk = null;
  }

  /// **稳态命中率** = 跳过首轮冷启动后、各轮命中率的**轮次平均**。
  ///
  /// ⚠️ 口径纪律（`实测-L1缓存复测` 记过）：这与"累计·token 加权"是两个数，
  /// 不能混称"命中率"。未上报缓存 ⇒ null（UI 显示"不可用"，不是 0%）。
  double? get steadyHitRate {
    if (!anyCachedReported || _hitRates.length < 2) return null;
    final steady = _hitRates.sublist(1);
    return steady.reduce((a, b) => a + b) / steady.length;
  }

  /// 本轮正文快照（settleTurn 判"本轮无输出"用）。
  String get _curText => _text.toString();


  /// 本轮步骤的标题（`分析需求` / `本轮输出`）—— 落盘时一起写上。
  String _title = '';

  /// 本轮是否已经"说过话"（有正文/思考，或已补过一句摘要）。
  ///
  /// 用来保证**一轮最多一行摘要**：框架会把并行工具调用一次性发来，
  /// 若每个都补一句，界面上一轮冒出好几行重复。
  bool _turnSealed = false;

  String get _stepId => 'turn-$_turn';

  /// 当前轮次（1 起）。给驱动器记录"工具是在哪一轮发起的"用 ——
  /// 框架发起工具后会进入下一轮，工具结果回来时轮次已经变了（见 `toolFinished`）。
  int get currentTurn => _turn;

  int get _now => DateTime.now().millisecondsSinceEpoch;

  void _beginIfNeeded({bool reasoning = false}) {
    if (_clock.isRunning) return;
    // ★ 开新一轮之前，先把上一轮还在队列里的正文片发完。
    //
    // 下面是 `_text.clear()` —— 累积缓冲要清空。若队列里还留着上一轮的片，
    // 它们会带**新一轮的 stepId** 发出去（因为 `_emitTextDelta` 读 `_stepId`）
    // ⇒ UI 把上一轮的文字挂到新一行上，且旧行永远缺结尾。
    _flushText();
    _turn++;
    _turnSealed = false; // 新一轮：还没说过话
    _text.clear();
    _reasoning.clear();
    _clock
      ..reset()
      ..start();

    // ★ 2026-10-22 用户要求：**去掉「正在生成…（第 N 轮）」那一行**。
    //
    // 原来这里会先发 `kTurnStarted`，UI 把它画成一条「正在生成…」进度行 ——
    // 用户原话：「这个正在生成...怎么...改一下行吗？不要这个，你直接思考，
    // 跟工具调用一样」。
    //
    // 所以：
    // · **不再发 `kTurnStarted`**（那条进度行彻底消失）
    // · 只发 `kStepStarted`，标题按**先到的那条通道**定：
    //   先来思考 ⇒ 「分析需求」（用户原话：**思考也是一个工具，
    //   只不过叫"分析需求"** —— 所以它和工具行同一形状、同一层级）；
    //   直接出正文 ⇒ 「本轮输出」
    // 本轮步骤的标题（落盘用 —— UI 靠它区分「分析需求」与「本轮输出」）
    _title = reasoning ? '分析需求' : '本轮输出';
    _sink(AgentEvent(
      type: AgentEvent.kStepStarted,
      ts: _now,
      stepId: _stepId,
      title: _title,
      index: _turn,
    ));
  }

  /// 思考增量（与正文**严格分离**，见 backend `HeraclesThoughtDelta` 的 KDoc）。
  void thought(String delta) {
    if (delta.isEmpty) return;
    _beginIfNeeded(reasoning: true);
    _reasoning.write(delta);
    _sink(AgentEvent(
      type: AgentEvent.kReasoningDelta,
      ts: _now,
      stepId: _stepId,
      delta: delta,
      index: _turn,
    ));
  }

  /// 正文增量 —— **先落平滑器，再由它按小片 `_sink` 出去**。
  ///
  /// ## 为什么要平滑（2026-10-23 用户报的现象）
  ///
  /// 用户原话：「流式输出不丝滑，总是一段一段出来」「吓死个人」。
  ///
  /// 根因不在 UI，也不在我们这条链路：`dart_agent_core` 的
  /// `OpenAIResponseTransformer` 每收到一个 SSE `delta.content` 就 yield 一条
  /// `ModelMessage`，而**上游 provider 本身会攒包**（中转站尤其明显）——
  /// 实测一次能给到几十上百个字符。我们只是原样转发 ⇒ UI 一次 append 一大块，
  /// 看起来就是"啪一下冒出一整段"。
  ///
  /// 下游再想让它"丝滑"只有一条路：**在这里把大块切成小片、按固定节拍发**。
  ///
  /// ## 落在翻译器层而不是 UI 层
  ///
  /// UI 是已验证资产（19 个 widget 测试），且它只认 `delta` 这个字段 ——
  /// 切成几片对它是透明的。放在翻译器还能保证**同一套节拍**对所有消费方一致
  /// （实时流、调试面板）。
  ///
  /// ## 为什么 [_text]（累积缓冲）仍然**同步**写
  ///
  /// 它喂的是 `step_ended.summary` 与 `settleTurn` 的"本轮无输出"判定。
  /// 若也异步化，收尾时可能读到半句 —— 摘要就会缺尾。
  /// ⇒ 累积同步、只把"播出去"这一步切片。
  void text(String delta) {
    if (delta.isEmpty) return;
    _beginIfNeeded();
    _text.write(delta);
    _smoother.add(delta);
  }

  /// 把待发的正文片立刻全部发出（收尾/换轮/切通道前必调）。
  void _flushText() => _smoother.flush();

  void _emitTextDelta(String piece) {
    _sink(AgentEvent(
      type: AgentEvent.kStepDelta,
      ts: _now,
      stepId: _stepId,
      delta: piece,
      index: _turn,
    ));
  }

  void toolRequested(String toolName, Map<String, dynamic> args) {
    // ★ 2026-10-22 用户要求：**模型一句话不说的纯工具轮次也要有一行摘要**
    //
    // 用户原话：「肯定要啊，可以多说两句，但不要太多，**以第一人称说**，
    // 显得自己在思考」。
    //
    // 提示词已经要求"动手前先说一句"，但模型（尤其快模型）经常直接调工具。
    // ⇒ 这里做**本地兜底**：这一轮没有任何正文/思考时，用第一人称补一句短的，
    //   让界面永远不会出现"闷头连续调工具、一句话没有"的观感。
    //
    // ## 一轮只补一次
    //
    // 框架会把并行的多个工具调用**一次性**发过来。若每个都补一句，
    // 一轮里会冒出好几行重复摘要 ⇒ 用 `_turnSealed` 保证"一轮最多一行"。
    if (_clock.isRunning) {
      endStep(status: 'ok');
    } else if (!_turnSealed) {
      _beginIfNeeded();
      text(_narrateFor(toolName, args));
      endStep(status: 'ok');
    }

    _sink(AgentEvent(
      type: AgentEvent.kToolStarted,
      ts: _now,
      index: _turn,
      tool: toolName,
      args: args.map((k, v) => MapEntry(k.toString(), v.toString())),
    ));
  }

  /// 为"一句话没说的工具轮次"生成一句**第一人称**短摘要。
  ///
  /// 原则：
  /// · **第一人称**（"我先看看…"）—— 让用户感觉是模型在思考，而不是系统日志
  /// · **短**（一句，最多带一个短路径）—— 用户明确说"不要太多"
  /// · **不编造**：只根据工具名与参数说话，不猜它为什么这么做
  /// · 参数里的路径只保留**末尾一段**，避免长路径把一行撑爆
  String _narrateFor(String toolName, Map<String, dynamic> args) {
    final rawPath = (args['path'] ?? args['file'] ?? args['projectDir'] ?? '')
        .toString()
        .trim();
    final name = rawPath.isEmpty
        ? ''
        : ' `${rawPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? rawPath}`';
    return switch (toolName) {
      'list_files' => '我先看看工作区里有什么$name。',
      'find_files' => '我先找一下符合条件的文件$name。',
      'grep_files' => '我先搜一下关键词，定位到具体位置。',
      'read_file' => '我读一下$name 的内容，确认清楚再动手。',
      'write_file' => '我把内容写进$name。',
      'edit' => '我把$name 里对应的那几行改掉。',
      'apply_patch' => '我按补丁把$name 改好。',
      'mkdir' => '我先把目录建出来$name。',
      'delete_path' => '我把$name 删掉。',
      'move_path' => '我把$name 挪到新位置。',
      'copy_path' => '我把$name 复制一份。',
      'run_shell_command' => '我跑一条命令确认一下。',
      'web_fetch' => '我抓一下这个网页看内容。',
      'check_device_state' => '我先看下设备电量与温度。',
      'write_todos' => '我先把待办列出来，理一下步骤。',
      'ask_user' => '我需要先跟你确认一件事。',
      'save_memory' => '我把这条记到长期记忆里。',
      'build_apk' => '我试着把 APK 构建出来。',
      'apk_decompile' => '我先把 APK 解开来看看。',
      _ => '我调用 `$toolName` 处理这一步。',
    };
  }

  void toolFinished(
    String toolName,
    Map<String, dynamic> args,
    bool isError,
    String output,
    int durationMs, {
    int? turn,
  }) {
    _toolLog.add(_ToolRecord(toolName, output, isError, durationMs));
    // 本轮的工具信息（settleTurn 写进 AgentTurn —— 用量面板的步骤回放读它）
    _curTool = toolName;
    _curToolArgs = args.map((k, v) => MapEntry(k.toString(), v.toString()));
    _curToolResult = output;
    _curToolOk = !isError;
    _sink(AgentEvent(
      type: AgentEvent.kToolFinished,
      ts: _now,
      // ★ 用**工具发起时那一轮**的序号，不是"现在"那一轮。
      //
      // ## 踩到的 bug（真机：工具行永远「执行中」）
      //
      // UI 用 `_toolKey(index, tool, args)` 把 `tool_started` 与
      // `tool_finished` 配对。而框架是**先发起工具、再进入下一轮**，
      // 等 `tool_finished` 回来时翻译器的 `_turn` 可能已经 +1 ⇒
      // 两次的 index 不同 ⇒ key 对不上 ⇒ 卡片永远停在"执行中"
      // （真机截图：`正在查看目录文件 执行中`，而后端 `.jsonl` 里
      //   那条工具明明是 `state=succeeded`）。
      //
      // ⇒ 由调用方（`_drive`）把发起时的轮次带回来。
      index: turn ?? _turn,
      tool: toolName,
      // `args` 必须带上：UI 的 key **包含参数**（细节见下面 KDoc）
      args: args.map((k, v) => MapEntry(k.toString(), v.toString())),
      result: output,
      ok: !isError,
      wallMs: durationMs,
    ));
  }

  void planUpdated(List<HeraclesPlanStep> steps) {
    final done = steps.where((s) => s.status == HeraclesPlanStatus.done).length;
    final active = steps.indexWhere((s) => s.status == HeraclesPlanStatus.active);
    _sink(AgentEvent(
      type: AgentEvent.kPlanCreated,
      ts: _now,
      planSteps: steps.map((s) => s.text).toList(),
      doneCount: done,
      activeIndex: active,
    ));
  }

  /// **上下文已自动压缩** —— 翻成 UI 的 `context_compressed` 事件。
  ///
  /// ## 为什么要播（而不是只记日志）
  ///
  /// 压缩是**有损**的：老消息被摘要成一段 XML，细节丢了。用户看不到它发生过，
  /// 就只会觉得"模型突然忘了前面说的事"。播出来他才知道是压缩导致的，
  /// 而不是模型变笨了。
  ///
  /// ## 为什么**不**跟步骤/轮次绑定
  ///
  /// 它不是一个"轮"，而是发生在两轮**之间**的一次维护动作（框架在每轮循环
  /// 开头检查）。所以：
  /// · 不调 `_beginIfNeeded`（那会凭空开一轮、还会把 `_text` 清掉）
  /// · 不带 `stepId` / `index`（不属于任何一轮，带了反而误导）
  /// · 直接 `_sink`，按到达顺序插进事件流
  ///
  /// ⚠️ **不要在这里 `endStep`**：压缩发生在模型调用**之前**，
  /// 此刻本轮还没有任何正文，强制收尾会把"本轮输出"封成一个空步骤。
  void contextCompressed({
    required int beforeMessages,
    required int afterMessages,
    required int beforeTokens,
    required int afterTokens,
  }) {
    _sink(AgentEvent(
      type: AgentEvent.kContextCompressed,
      ts: _now,
      beforeMessages: beforeMessages,
      afterMessages: afterMessages,
      beforeTokens: beforeTokens,
      afterTokens: afterTokens,
    ));
  }

  void retrying(String reason) {
    // UI 没有"重试"事件种类。不发 —— 重试是瞬态，成功则无需告知，
    // 失败会由 `failed` 兜底。留个探针供排障（不播到 UI）。
    lastRetryReason = reason;
  }

  String? lastRetryReason;

  void endStep({required String status}) {
    // ★ 先把还在队列里的正文片**立刻发完**，再发「本轮结束」。
    //
    // 顺序反了会怎样：UI 先收到 `step_ended`（把这一行封口），再收到
    // 最后几个 `step_delta` —— 那几片要么被挂到下一轮、要么直接丢掉。
    // 也就是说**末尾几个字会消失**，这是用户报告"回答少了结尾"那类现象之一。
    _flushText();
    if (!_clock.isRunning) return;
    _clock.stop();
    // 本轮"说过话了" ⇒ 后续同一批的并行工具调用不再补摘要
    _turnSealed = true;
    // 摘要优先用正文；只有思考没有正文时退到思考 ——
    // 否则「思考」行展开后是空的，用户以为没内容。
    final summary = _text.isNotEmpty
        ? _text.toString()
        : (_reasoning.isEmpty ? null : _reasoning.toString());
    _sink(AgentEvent(
      type: AgentEvent.kStepEnded,
      ts: _now,
      stepId: _stepId,
      status: status,
      durationMs: _clock.elapsedMilliseconds,
      summary: summary,
      index: _turn,
    ));

    // ★ 2026-10-22：**步骤必须落盘**，否则"正文汇报"只在实时流里活着。
    //
    // ## 用户报的现象
    //
    // > 「我现在看你测试的那个会话，还是没有正文汇报」
    //
    // 他看的是**从磁盘重开的会话**。而我一直没写 `role:"step"` 行 ⇒
    // 重开后只剩用户消息 + 工具行 + 最终回答，中间那些
    // 「我先看看工作区…」「我看到根目录是空的…」全没了。
    //
    // UI 侧 `chat_screen._toMessages` **早就支持**这种行
    // （字段：`stepId/title/i/think/text/stage/ms/truncated`），
    // 缺的只是生产端把它们写出来。
    //
    // 交给驱动器 `takeStepRecord()` 取走并按顺序 append
    // —— 不在这里直接写，是因为翻译器不做 IO。
    _stepRecord = <String, dynamic>{
      'role': 'step',
      'stepId': _stepId,
      'title': _title,
      'i': _turn,
      'think': _reasoning.toString(),
      'text': _text.toString(),
      'stage': status,
      'ms': _clock.elapsedMilliseconds,
      'ts': _now,
    };
  }

  /// 待落盘的步骤记录（由驱动器取走后 append）。取走即清空。
  Map<String, dynamic>? _stepRecord;

  Map<String, dynamic>? takeStepRecord() {
    final r = _stepRecord;
    _stepRecord = null;
    return r;
  }

  void finished(String finalText, int turns, int wallMs) {
    // 同上：收尾事件之前必须把正文发完，否则最后几片会跟在 `finished` 后面。
    _flushText();
    _sink(AgentEvent(
      type: AgentEvent.kFinished,
      ts: _now,
      index: _turn,
      finalText: finalText,
      turnCount: turns,
      wallMs: wallMs,
    ));
  }

  void failed(String message) {
    // 失败也要先把正文发完：`_reportRunFailure` 之后这条 run 就结束了，
    // 留在队列里的片永远没有出口（且其中可能有**已经生成好的正文**）。
    _flushText();
    _sink(AgentEvent(type: AgentEvent.kFailed, ts: _now, index: _turn, message: message));
  }
}

class _ToolRecord {
  _ToolRecord(this.tool, this.result, this.isError, this.durationMs);
  final String tool;
  final String result;
  final bool isError;
  final int durationMs;
}

/// **正文平滑器** —— 把"一大块正文"摊成"一小片一小片到"。
///
/// ## 它解决的问题
///
/// 上游 provider（尤其 OpenAI 兼容中转站）会把多个 SSE `delta.content`
/// 攒成一个包再发。框架 `OpenAIResponseTransformer` 原样 yield ⇒ 我们
/// 一把 `_sink` 出去几十上百字 ⇒ UI 看起来"啪一下冒出一整段"。
///
/// 这里做的是**只改节奏、不改内容**：切成 ≤ [_chunkSize] 字的小片，
/// 片间 [_intervalMs] 毫秒。
///
/// ## 三条硬保证（都有对应测试）
///
/// 1. **逐字节一致**：所有片按序拼起来必须与原 delta 完全相同。
///    切分按 **rune**（不是 code unit）—— 否则中文/emoji 会被从代理对
///    中间切开，拼回来是乱码。这是本类最容易写错的一处。
/// 2. **单泵顺序**：只有一个异步泵在跑，队列 FIFO。
///    ❌ 绝不为每片起一个 `Future.delayed` —— 它们会并发、乱序、还会让
///    "_text 累积" 与实际显示顺序不一致。
/// 3. **收尾不卡**：[flush] 立刻把剩余片同步发完并停泵。
///    run 结束时**不许**还有 pending 的定时器拖着收尾（用户会看到
///    "任务已完成，但字还在往外蹦"）。
///
/// ## 为什么最后一帧就 flush 而不是等节拍
///
/// 稳态下让节拍器跑是对的（看起来丝滑）；但**一旦没有新数据要来了**，
/// 再按 15ms 一片地磨，就是把"已完成的回答"人为拖慢。所以：
/// 队列只剩最后一片时立即发；显式 [flush] 时全发。
class _TextSmoother {
  _TextSmoother(this._emit);

  /// 真正往 `_sink` 写事件的回调。
  final void Function(String piece) _emit;

  /// 每片最多几个 **rune**（不是 code unit）。
  ///
  /// 4 的取舍：中文一秒 60 帧、15ms 一拍 ⇒ 约每秒 66 片 × 4 字 ≈ 265 字/秒，
  /// 比模型出字快，肉眼是"连续出字"而不是"跳段"。再大就又能看出块感。
  static const int _chunkSize = 4;

  /// 片间隔（毫秒）。15ms ≈ 每秒 66 片，接近 60fps 的观感。
  static const int _intervalMs = 15;

  /// 待发小片（FIFO）。
  final List<String> _queue = [];
  bool _pumping = false;
  bool _disposed = false;

  /// 收一段正文。空串忽略；短于一片的直接进队（不做无意义切分）。
  void add(String delta) {
    if (delta.isEmpty || _disposed) return;
    _enqueueRunes(delta);
    if (!_pumping) {
      _pumping = true;
      // 不 await：调用方（框架的事件回调）是同步上下文，
      // 我们只负责把"泵"踢起来，节奏由它自己走。
      unawaited(_pump());
    }
  }

  /// 按 rune 切分入队。
  ///
  /// ⚠️ **必须用 rune**：`String.substring` 按 code unit 切会把
  /// emoji（代理对）与部分生僻汉字切成两半，拼回来就是乱码 U+FFFD。
  void _enqueueRunes(String s) {
    final runes = s.runes.toList(growable: false);
    for (var i = 0; i < runes.length; i += _chunkSize) {
      final end = (i + _chunkSize < runes.length) ? i + _chunkSize : runes.length;
      _queue.add(String.fromCharCodes(runes, i, end));
    }
  }

  /// 单泵：按节拍把队列里的片一片片发出去。
  Future<void> _pump() async {
    try {
      while (_queue.isNotEmpty && !_disposed) {
        // 已经是最后一片 ⇒ 立刻发，不为它再等一个节拍
        // （否则收尾会平白多拖 15ms，且 flush 前的最后一片会"卡一下"）。
        if (_queue.length > 1) {
          await Future<void>.delayed(const Duration(milliseconds: _intervalMs));
          if (_disposed) return;
        }
        if (_queue.isEmpty) return;
        final piece = _queue.removeAt(0);
        _emitPiece(piece);
      }
    } finally {
      _pumping = false;
    }
  }

  void _emitPiece(String piece) {
    try {
      _emit(piece);
    } catch (_) {
      // 出口抛异常（如事件流已关）⇒ 丢掉这一片，**不让泵挂死**。
      // 绝不能因为一片发不出去就让后续所有片都堵在队列里。
    }
  }

  /// **立刻发完剩余片**并停泵。收尾（`endStep` / `finished` / 失败）必调。
  ///
  /// 同步发完是有意的：调用方紧接着就要发 `step_ended` / `finished`，
  /// 若这里留异步尾巴，UI 会先收到"本轮结束"再收到"最后几个字" ——
  /// 顺序颠倒，正文就丢在步骤后面了。
  void flush() {
    while (_queue.isNotEmpty) {
      _emitPiece(_queue.removeAt(0));
    }
  }

  /// 永久停用（run 结束后不再接受新内容）。
  void dispose() {
    flush();
    _disposed = true;
  }

  /// 队列里还有多少片（测试用）。
  int get pendingPieces => _queue.length;
}
