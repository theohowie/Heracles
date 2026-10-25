/// **会话历史 → 框架消息** —— 把 `.jsonl` 里的行翻译成 `LLMMessage` 列表。
///
/// ## 这个文件解决什么问题
///
/// 2026-10-23 之前，App 每次 run 都 `new HeraclesAgent(...)`，而
/// `HeraclesAgent._state` 是 `??=` 初始化的 ⇒ **每次都是空历史**。
/// 后果有两个，都不是小事：
///
/// 1. **模型记不住上一轮** —— 用户问"刚才那个文件叫什么"，它答不上来。
///    这是"多轮对话根本没接上"，不是语气问题。
/// 2. **前缀缓存几乎全不命中**（真机只有 1%）—— 每条请求的前缀都不同。
///
/// 修法是：宿主（App）从会话文件读出历史，翻译成本文件的产物，传给
/// `HeraclesAgent.run(history: ...)`。
///
/// ## 为什么放在 backend 而不是 App 侧
///
/// 两个理由：
///
/// 1. **可单测**：这个仓库的 `backend/` 是纯 Dart 包，`dart test` 毫秒级就能
///    验证"哪些行该进历史"。放在 App 侧就只能靠 widget 测试，而本机
///    `flutter test` 跑不完（环境坑 11/23）。
/// 2. **不许 App 直接 import 框架类型**：`dart_agent_core` 在 `app/pubspec.yaml`
///    里只是**传递依赖**，直接 import 会被 `depend_on_referenced_packages`
///    判为违规（而且"谁的依赖谁负责"这条边界会糊掉）。所以 `LLMMessage` /
///    `ModelMessage` 由 backend 构造，App 只递原始 Map。
///
/// ## 三条取舍（都不是随便定的）
///
/// ### ① **tool 行按"调用 id"配对回填（2026-10-24 起）**
///
/// 原来的取舍是"只回填 user/assistant 纯文本，tool 行一律跳过"—— 根因是
/// `.jsonl` 里**没有**"模型请求了哪个调用 id"，硬塞 `FunctionExecutionResultMessage`
/// 就是**无配对的 tool 结果**，OpenAI/Anthropic 两家都会 400。
/// 那个代价（模型看不到上一轮工具的输出）在真机上反复疼过：隔天续会话，
/// 模型把昨天已经跑过的构建/搜索**原样重跑一遍**。
///
/// 现在会话格式补了两种行（App 侧 `_drive` 落盘）：
///
/// ```jsonl
/// {"role":"tool_call","id":"c1","tool":"read_file","args":{...}}   ← 发起时写
/// {"role":"tool","id":"c1","tool":"read_file","result":"...",...}  ← 结束时写（旧格式无 id）
/// ```
///
/// 翻译规则：`tool_call` 行 → 暂存一个 `FunctionCall`；`tool` 行带 `id` →
/// 凑成 `FunctionExecutionResult`。**一个批次的所有调用都有结果时**才
/// 一起发出 `ModelMessage(functionCalls)` + `FunctionExecutionResultMessage`
/// —— 框架与两家 wire 都要求严格配对，宁可不发也不发半个批次。
///
/// 兼容性：旧会话（无 `tool_call` 行 / `tool` 行无 `id`）自然落回旧行为
/// （跳过）；尾部"只有调用、没有结果"的残批（进程被杀）整体丢弃。
///
/// ### ①′ **裁剪不许切断配对**
///
/// 按条数裁到最近 N 条后做一次清理：开头孤立的结果消息、结尾孤立带调用的
/// assistant 消息都丢掉 —— 半个批次比少一个批次更危险（400）。
///
/// ### ② **assistant 消息用 `ModelMessage(textOutput:)`，不碰 `thought`**
///
/// 结构化的 `ModelMessage` 才能被框架正确回放到三条 wire。
/// `thought` 一律不带：它是推理过程，重放会让模型把自己上一轮的推理
/// 当成事实依据（而且部分 provider 不允许回传 reasoning 内容）。
///
/// ### ③ **必须由调用方排除"本轮刚写进去的 user 行"**
///
/// App 的顺序是"先把用户消息落盘，再跑"。所以读历史时会读到自己。
/// 若不排除，模型会看到**同一条用户消息出现两遍**（历史里一遍 + 本轮请求一遍）。
/// 本文件不管这件事（它不知道哪条是本轮），责任在调用方 —— 见
/// [_HistoryLimits] 之上的 `fromSessionRows` 的 `dropLastUserIfMatches` 参数。
library;

import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';

/// 回填历史的默认上限：**最近 40 条消息**。
///
/// ## 为什么要有上限
///
/// 历史是**每轮固定开销**：40 条对话（假设平均 200 字）≈ 8K token，
/// 每轮都要发一遍。长会话跑到 200 条就是 40K token 的固定前缀 ——
/// 又贵又慢，而且大部分是"很久以前、与当前任务无关"的内容。
///
/// ## 为什么是 40 而不是别的数
///
/// - 20 条（≈10 轮）：常见任务（"改这个文件"→"再改那个"）够用，
///   但排查类任务（"刚才那个报错"）容易丢上下文；
/// - 100 条：把 `ContractModel.defaultWindowTokens`（128K）的 1/5 花在
///   历史上有余，但对小窗口模型（8K/32K）直接爆；
/// - **40** 是折中：≈20 轮对话，覆盖"同一个任务里来回几次"的真实场景，
///   且 8K token 在 128K 窗口里只占 6%。
///
/// ⚠️ 这是**软上限**：从尾部往前数够 40 条就停。更早的内容由
/// `WindowRatioCompressor` 在窗口真吃紧时摘要（那是另一套机制）。
const int kHistoryMaxMessages = 40;

/// 把会话文件的行翻译成框架消息。
///
/// [rows] 是 `.jsonl` 逐行解出来的 Map（`SessionStore.loadMessages` 的产物）。
/// 顺序必须是**时间正序**（存储本身就是 append-only，所以原样用即可）。
///
/// [dropLastUserIfMatches]：若**最后一条**可用 user 行的文本等于这个值，
/// 就把它丢掉。用于排除"本轮刚落盘的那条 user 消息"。
/// 传 `null` 表示不做这件事（纯读历史场景）。
///
/// 返回的列表含 `UserMessage` / `ModelMessage` / `FunctionExecutionResultMessage`
/// （最后一类必须与前面的 assistant 调用**成对**出现），且已被裁到
/// 最近 [maxMessages] 条、并清理过被裁断的半批（见文件头「取舍①′」）。
List<LLMMessage> sessionRowsToHistory(
  List<Map<String, dynamic>> rows, {
  int maxMessages = kHistoryMaxMessages,
  String? dropLastUserIfMatches,
}) {
  final out = <LLMMessage>[];

  // ---- tool 批次的暂存（见文件头「取舍①」）----
  //
  // 一个批次 = 一次 functionCallRequest 事件的全部调用（并行批）。
  // `calls` 攒"发起"，`results` 攒"结果"；**全部凑齐才发出**一对消息。
  // 结果可能乱序完成（框架 Future.wait），所以按 id 匹配而不是按顺序。
  final pendingCalls = <String, FunctionCall>{};
  final pendingResults = <String, FunctionExecutionResult>{};

  // 计划恢复（M2，2026-10-24）：记住**最后一次**计划的可读渲染，
  // 在回填结果的末尾以一条 user 消息进场 —— 模型隔天续会话能看到
  // "此前计划到哪了"。（渲染成文本而不是重建框架 PlanState：
  // write_todos 每次都是全量更新，模型读到文本就够了。）
  String? lastPlanText;

  void flushToolBatchIfComplete() {
    if (pendingCalls.isEmpty) return;
    if (pendingResults.length < pendingCalls.length) return;
    out.add(ModelMessage(
      model: 'history',
      functionCalls: pendingCalls.values.toList(),
    ));
    out.add(FunctionExecutionResultMessage(
      results: pendingCalls.keys.map((id) => pendingResults[id]!).toList(),
    ));
    pendingCalls.clear();
    pendingResults.clear();
  }

  for (final row in rows) {
    final role = (row['role'] as String?) ?? '';
    // `text` 可能是 null（工具行没有 text，只有 result）
    final text = (row['text'] as String?) ?? '';

    switch (role) {
      case 'user':
        // 空文本的用户消息没有信息量，而且会让 assistant 的"上一条"错位 ⇒ 跳过。
        // （纯附件消息就是这种情况：App 只传了附件名，正文为空。）
        if (text.trim().isEmpty) continue;
        out.add(UserMessage.text(text));

      case 'assistant':
        // 空回答（失败/取消那轮）同理跳过 —— 重放一条空 assistant
        // 会让模型以为"我上一轮什么都没说"，反而更迷惑。
        if (text.trim().isEmpty) continue;
        // `model` 只是元数据，回放时不被任何 wire 读取（openai 轨只取
        // `textOutput`；claude 轨在 `contentBlocks` 为空时走
        // `_buildAssistantContent`，同样只取正文）。这里填一个明确的
        // 占位名而不是空串，便于排障时看出"这条来自历史回填"。
        out.add(ModelMessage(
          textOutput: text,
          model: 'history',
        ));

      case 'plan':
        // 计划行（M2，2026-10-24）：App 每次计划变化追加一行，取最后一条。
        final planSteps = row['steps'];
        if (planSteps is! List || planSteps.isEmpty) continue;
        final pbuf = StringBuffer();
        var count = 0;
        for (final s in planSteps) {
          if (s is! Map) continue;
          final t = ((s['text'] as String?) ?? '').trim();
          if (t.isEmpty) continue;
          count++;
          final tag = switch ((s['status'] as String?) ?? 'pending') {
            'done' => '已完成',
            'active' => '进行中',
            'cancelled' => '已取消',
            _ => '待办',
          };
          pbuf.writeln('$count. [$tag] $t');
        }
        if (count > 0) {
          lastPlanText = '此前的任务计划（可用 write_todos 继续更新）：'
              '\n${pbuf.toString().trimRight()}';
        }

      case 'compact':
        // /compact 标记（2026-10-24）：**丢弃此前的一切**，只带摘要进场。
        //
        // 这就是手动压缩的语义 —— 与 Claude Code /compact 的"完全重置"
        // 同义，但在 append-only 会话文件上实现：原始行一字未动，
        // 只是回填历史时不再看它们。摘要为空的标记行（异常产物）忽略。
        final summary = ((row['summary'] as String?) ?? '').trim();
        if (summary.isEmpty) continue;
        out.clear();
        pendingCalls.clear();
        pendingResults.clear();
        out.add(UserMessage.text(
          '[会话已压缩（/compact）] 以下是更早对话的要点摘要，'
          '原始细节已按用户要求丢弃：\n$summary',
        ));

      case 'tool_call':
        // 模型发起的工具调用（2026-10-24 新行格式）→ 暂存，等结果凑齐。
        final id = (row['id'] as String?) ?? '';
        final tool = (row['tool'] as String?) ?? '';
        if (id.isEmpty || tool.isEmpty) continue;
        final args = row['args'];
        pendingCalls[id] = FunctionCall(
          id: id,
          name: tool,
          arguments: args is Map ? jsonEncode(args) : '{}',
        );

      case 'tool':
        // 工具结果：带 `id` 才能配对（旧格式无 id ⇒ 跳过，保持旧行为）。
        final id = (row['id'] as String?) ?? '';
        if (id.isEmpty || !pendingCalls.containsKey(id)) continue;
        final tool = (row['tool'] as String?) ?? '';
        final result = (row['result'] as String?) ?? '';
        final ok = row['ok'];
        pendingResults[id] = FunctionExecutionResult(
          id: id,
          name: tool,
          isError: ok is bool ? !ok : false,
          arguments: '',
          content: [TextPart(result)],
        );
        flushToolBatchIfComplete();

      // `step` / `changes` / `system` 一律跳过：
      // step ⇒ 是我们 UI 的展示行，不是对话内容（含"我先看看目录…"这类
      //   本地生成的摘要，回放给模型纯属噪音且会污染缓存前缀）；
      // changes ⇒ UI 汇总卡片；
      // system ⇒ 存储读失败时的提示行，不是模型说的话。
      default:
        continue;
    }
  }
  // 尾部残批（只有调用、没有结果 —— 进程被杀）整体丢弃：发不出去。
  pendingCalls.clear();
  pendingResults.clear();

  // ---- 排除"本轮刚写进去的 user 行" ----
  //
  // 只检查**尾部**：App 的顺序决定了本轮那条必然在最后。
  // 不扫全表 —— 用户完全可能重复问同一句话（"再试试"），
  // 那属于真实历史，不该被当成"本轮的重复"删掉。
  if (dropLastUserIfMatches != null &&
      out.isNotEmpty &&
      out.last is UserMessage) {
    final last = out.last as UserMessage;
    if (_textOf(last) == dropLastUserIfMatches) {
      out.removeLast();
    }
  }

  // ---- 裁到最近 maxMessages 条 ----
  if (maxMessages > 0 && out.length > maxMessages) {
    out.removeRange(0, out.length - maxMessages);
  }

  // ---- 裁剪后清理半批（见文件头「取舍①′」）----
  //
  // 开头孤立的结果消息（配对的 assistant 被裁掉）⇒ 丢，否则 400；
  // 结尾孤立的带调用 assistant（结果被裁掉）⇒ 丢，同理。
  while (out.isNotEmpty && out.first is FunctionExecutionResultMessage) {
    out.removeAt(0);
  }
  while (out.isNotEmpty &&
      out.last is ModelMessage &&
      (out.last as ModelMessage).functionCalls.isNotEmpty) {
    out.removeLast();
  }

  // ---- 计划恢复（M2）：放**最后** —— 它是最新状态，且必须在
  //      dropLastUserIfMatches 之后（否则会挡住"本轮请求去重"的判定）。
  if (lastPlanText != null) {
    out.add(UserMessage.text('[恢复会话] $lastPlanText'));
  }
  return out;
}

/// 取 `UserMessage` 的单段文本（回填出来的必然只有一段 `TextPart`）。
String _textOf(UserMessage m) {
  if (m.contents.length == 1 && m.contents.first is TextPart) {
    return (m.contents.first as TextPart).text;
  }
  final buf = StringBuffer();
  for (final p in m.contents) {
    if (p is TextPart) buf.write(p.text);
  }
  return buf.toString();
}
