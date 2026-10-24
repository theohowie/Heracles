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
/// ### ① **只回填 user / assistant 的纯文本，不喂 tool 行**
///
/// 工具结果（`role:"tool"`）在框架里的角色是
/// `FunctionExecutionResultMessage`，它**必须**紧跟在带
/// `functionCalls` 的 `ModelMessage` 后面配对出现。而我们的 `.jsonl` 里
/// 工具行是**独立一行**、且它对应的 `ModelMessage.functionCalls`
/// **没有被落盘**（App 只存了工具结果，没存"模型请求了哪个调用 id"）。
///
/// ⇒ 硬把一个 `FunctionExecutionResultMessage` 塞进历史，就是**没有配对的
///   tool 结果**。OpenAI 系会直接 400（`tool_call_id` 找不到对应的
///   `tool_calls`），Anthropic 系会 400（`tool_use` / `tool_result` 不配对）。
///
/// **代价（必须说清，不许淡化）**：模型回看历史时**看不到上一轮工具的输出**。
/// 它知道"我说过要读那个文件"，但不知道"读到了什么"。这是"能跑"与
/// "全能"之间的取舍 —— 我们选能跑，并在系统提示里让模型必要时重新读一次。
/// 要真正补齐，得让 App 落盘 `ModelMessage.functionCalls`（改会话格式），
/// 那是另一个改动。
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
/// 返回的列表**只含** `UserMessage` / `ModelMessage`，且已被裁到
/// 最近 [maxMessages] 条。
///
/// ## 为什么按"轮"裁剪可能切断半轮
///
/// 直接按条数裁确实可能留下"一条 assistant 却没有对应的 user"。
/// 但那**不会让请求失败**（OpenAI 与 Anthropic 都接受以 assistant 开头的
/// 历史；后者还用它做 prefill）。真正会失败的是**不配对的 tool 结果**，
/// 而那种行我们压根没转 —— 所以这里不需要更复杂的"按轮对齐"逻辑。
/// 宁可少一条，也不为了"整齐"去猜。
List<LLMMessage> sessionRowsToHistory(
  List<Map<String, dynamic>> rows, {
  int maxMessages = kHistoryMaxMessages,
  String? dropLastUserIfMatches,
}) {
  final out = <LLMMessage>[];

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

      // `tool` / `step` / `changes` / `system` 一律跳过：
      // tool ⇒ 见文件头「取舍①」（缺配对会 400）；
      // step ⇒ 是我们 UI 的展示行，不是对话内容（含"我先看看目录…"这类
      //   本地生成的摘要，回放给模型纯属噪音且会污染缓存前缀）；
      // changes ⇒ UI 汇总卡片；
      // system ⇒ 存储读失败时的提示行，不是模型说的话。
      default:
        continue;
    }
  }

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
    return out.sublist(out.length - maxMessages);
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
