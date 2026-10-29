/// **记忆注入的渲染与选择**（2026-10-29 三作用域重设计）—— backend 纯 Dart。
///
/// ## 这个文件是记忆"进 prompt"的唯一真相
///
/// 旧实现只有 `interaction_tools.dart` 里的 `renderMemory(raw)`：一段标题 + 原文
/// + 一句约束，**整段全量注入**，没有分层、没有预算、没有来源标注。
/// 现在渲染与检索都在这里（`renderMemory` 保留但转调本文件的单段模式，
/// 见 [renderMemorySingleScope] —— 不许出现第二份格式定义）。
///
/// ## 注入顺序 = 优先级倒序（不变量）
///
/// ```
/// [默认系统提示]                         ← 字节稳定
/// [宿主追加 systemPrompts：宪法/快照/RAG] ← 字节稳定
/// ## 全局记忆（用户维护，只读；可能过时）  ← 稳定段，先占 6000 共享预算
/// ## 工作区记忆（本工作区共享）            ← 稳定段，吃 global 剩余预算
/// ## 会话私有记忆（本会话，优先级最高）    ← 易变段，独立 4000 预算，放最后
/// （另有 N 条未注入，可在记忆页查看）      ← 只在真的裁掉了条目时出现
/// [一句跨层冲突规则]                       ← 全篇只出现一次，且在最末
/// ```
///
/// **为什么 session 最后**：`composeSystemMessage()` 把片段 join 成一条 system，
/// 最易变的内容放尾部 ⇒ 前面人设/宪法/全局/工作区字节不变，缓存失效只发生在尾部。
/// **为什么冲突规则放最末**：它是对"上面这些记忆怎么用"的元指令，放尾部最贴近
/// 实际使用点，也保证只出现一次（重复会白占字节且互相矛盾）。
///
/// ## 预算（存储预算 ≠ 注入预算，不变量 I3）
///
/// · global + workspace **共享** `ContractMemory.globalWorkspaceInjectMaxChars`，
///   global 先占，workspace 吃剩余（workspace 段整体放不下 ⇒ 不输出段头）；
/// · session 独立 `ContractMemory.sessionInjectMaxChars`；
/// · 两者都再取 `min(常量, floor(windowTokens × windowRatioCap))`（[injectBudgetChars]）；
/// · 每 scope 最多 `injectMaxEntriesPerScope` 条（先到者生效）；
/// · **条目整条取舍，绝不从中间截断**（截断会让模型读到半句约定）；
/// · 裁掉的条数用一行尾注如实声明（不变量 I6：不静默丢条目）。
///
/// ## 检索（含一条**被删除的旧行为**）
///
/// 旧 `composeRetrieval` 在"无任何关键词命中"时**回落成全量返回** —— 那会把
/// 大记忆整段灌进上下文（设计稿 §2.1 的爆窗口路径）。本实现**没有这个回落**：
/// 无命中就按 `user/promoted 优先 → createdAt 降序` 排序，取到预算为止；
/// 未命中项压成 `summaryMaxChars` 字摘要（保留"存在这么一条"的提示）。
library;

import '../context/memory_context.dart';
import '../contract/contract.dart';

/// 记忆注入的顺序（= 优先级从低到高）。**改顺序就改这里，别散在代码里**。
const List<MemoryScope> memoryInjectionOrder = <MemoryScope>[
  MemoryScope.global,
  MemoryScope.workspace,
  MemoryScope.session,
];

/// 全局段标题（固定文案；测试与 UI 都引用它，避免第二份真相）。
const String globalMemorySectionTitle = '## 全局记忆（用户维护，只读；可能过时）';

/// 工作区段标题。
const String workspaceMemorySectionTitle = '## 工作区记忆（本工作区共享）';

/// 会话私有段标题。
const String sessionMemorySectionTitle = '## 会话私有记忆（本会话，优先级最高）';

/// **跨层冲突规则**（全篇只出现一次，且必须是最后一行）。
///
/// 只交代模型自己无法从环境推断的两件事：要不要复述、冲突听谁的；
/// 不写成手册（与 `system_prompt.dart` 的"给事实，不给教练"一致）。
const String memoryConflictRule =
    '记忆是**事实沉淀**，不用复述给用户看，只在需要时使用；'
    '若与当前对话冲突，**以当前对话为准**；'
    '记忆之间冲突时，以更靠近当前会话的层为准（**会话私有 > 工作区 > 全局**）。';

/// 超预算时那行尾注的前缀（`（另有 N 条未注入，可在记忆页查看）`）。
const String memoryOmittedHintPrefix = '（另有 ';

/// 段标题（按作用域取）。
String memorySectionTitle(MemoryScope scope) => switch (scope) {
      MemoryScope.global => globalMemorySectionTitle,
      MemoryScope.workspace => workspaceMemorySectionTitle,
      MemoryScope.session => sessionMemorySectionTitle,
    };

/// 来源标注（段内每条前面那个 `[x]`）。
///
/// 模型需要知道"这条是谁写的"：用户手写的可信度高于模型自己记的
/// （设计稿 §3.5.1 的"来源标注"）。未知来源**原样标注**，不猜。
String memorySourceLabel(String source) => switch (source) {
      MemoryRecord.sourceUser => '用户',
      MemoryRecord.sourceAgent => '模型',
      MemoryRecord.sourceLegacy => '旧格式',
      MemoryRecord.sourcePromoted => '已确认',
      _ => source,
    };

/// **真实现的窗口自适应 min**（设计稿 §3.4.2 最后一行：不能只写注释）。
///
/// `min(capChars, floor(windowTokens × windowRatioCap))`：
/// 小窗口模型（8K/32K）按 5% 自动缩，避免记忆把人设/工具定义挤出窗口；
/// 大窗口（128K）下常量生效。
///
/// [windowTokens] `<= 0`（宿主拿不到窗口信息）⇒ **退回常量上限**：
/// 信息的缺失不该反过来把记忆全丢掉。
int injectBudgetChars({required int capChars, required int windowTokens}) {
  if (windowTokens <= 0) return capChars;
  final byWindow = (windowTokens * ContractMemory.windowRatioCap).floor();
  return byWindow < capChars ? byWindow : capChars;
}

/// **分词**（ASCII 词 ≥2 字符 + CJK 二元组），沿用旧 `composeRetrieval` 口径。
///
/// 为什么这么粗：手机端要的是"够用的相关性"，不是检索引擎；英文标识符
/// （`flutter build apk`）与中文双字词（`构建`）已经能覆盖项目约定类记忆。
/// 宿主做 `memory.search` 时应**复用本函数**（同一口径，避免两套打分）。
Set<String> memoryKeywords(String task) {
  final keywords = <String>{};
  for (final m in RegExp(r'[A-Za-z0-9_]{2,}').allMatches(task)) {
    keywords.add(m.group(0)!.toLowerCase());
  }
  // CJK 统一表意文字（U+4E00–U+9FFF）：取相邻两字成词。
  for (final m in RegExp(r'[\u4e00-\u9fff]{2}').allMatches(task)) {
    keywords.add(m.group(0)!);
  }
  return keywords;
}

/// 关键词相关性得分 = 各关键词在正文里出现的**次数**之和（大小写不敏感）。
///
/// 与旧实现同口径；不引入 TF-IDF 之类需要全局统计的东西 —— 记忆条目数
/// 本来就被候选窗限制在 200 条内，重排成本不值得。
int memoryRelevanceScore(String text, Set<String> keywords) {
  if (keywords.isEmpty) return 0;
  final lower = text.toLowerCase();
  var score = 0;
  for (final k in keywords) {
    var idx = lower.indexOf(k);
    while (idx >= 0) {
      score++;
      idx = lower.indexOf(k, idx + k.length);
    }
  }
  return score;
}

/// 把一条长正文压成摘要（`summaryMaxChars` 字符 + `…`）。
String summarizeMemoryText(String text) {
  final max = ContractMemory.summaryMaxChars;
  return text.length <= max ? text : '${text.substring(0, max)}…';
}

/// 一个候选（记录 + 相关性得分）。
class _Pick {
  const _Pick(this.record, this.score);
  final MemoryRecord record;
  final int score;
}

/// 一次段内选择的结算。
class _Selection {
  const _Selection({
    required this.picked,
    required this.omitted,
    required this.totalCost,
  });

  final List<_Pick> picked;

  /// 因为"超预算 / 超条数 / 空正文 / 候选窗外"被裁掉的条数。
  final int omitted;

  /// 实际占用的字符数（含段头；**不含最后一行之后的换行**，
  /// 与 [_renderSection] 产出的字符串长度逐字符相等）；没选中条目时为 0。
  final int totalCost;
}

/// 未过期且正文非空的条目（不变量：过期条目**不参与**注入、也不算"未注入"）。
List<MemoryRecord> _aliveAndNotBlank(
  List<MemoryRecord> entries,
  int nowMs,
) =>
    entries
        .where((e) => !e.isExpiredAt(nowMs) && e.text.trim().isNotEmpty)
        .toList();

/// 候选窗外被挡掉的条数（`retrievalMaxCandidates`）。
///
/// 宿主读取层已有 64 KB 窗口（`injectCandidateMaxBytes`）；这里是后端侧的
/// **第二道条数上限**，保证排序成本封顶。
int _windowDropped(List<MemoryRecord> alive) {
  final max = ContractMemory.retrievalMaxCandidates;
  return alive.length > max ? alive.length - max : 0;
}

/// 排序：**用户已确认优先 → 关键词得分降序 → createdAt 降序**。
///
/// 「用户已确认」= `source == user || source == promoted`（设计稿 §3.5.2 第 3 步）。
/// 用户写的东西比模型自己记的可信 —— 这是"显式优先"在注入层的表达。
List<_Pick> _rankForInjection(
  List<MemoryRecord> alive,
  Set<String> keywords,
) {
  final max = ContractMemory.retrievalMaxCandidates;
  // 文件是追加序（旧→新）：候选窗保留**最新**的一段。
  final window =
      alive.length > max ? alive.sublist(alive.length - max) : alive;
  final picks = <_Pick>[
    for (final e in window) _Pick(e, memoryRelevanceScore(e.text, keywords)),
  ];
  picks.sort((a, b) {
    final aUser = a.record.isUserConfirmed;
    final bUser = b.record.isUserConfirmed;
    if (aUser != bUser) return aUser ? -1 : 1;
    if (a.score != b.score) return b.score.compareTo(a.score);
    return b.record.createdAt.compareTo(a.record.createdAt);
  });
  return picks;
}

/// 渲染一条（整条，绝不截断；未命中关键词的压成摘要）。
String _lineFor(_Pick pick) {
  final body = pick.score > 0
      ? pick.record.text
      : summarizeMemoryText(pick.record.text);
  return '- [${memorySourceLabel(pick.record.source)}] $body';
}

/// 段内选择：按排序依次放，**整条取舍**，先到 `budgetChars` / `maxEntries` 为止。
///
/// 放不下当前条目就**跳过它继续看后面的**（后面的更短就可能放得下）——
/// 这仍然是"按排序取到预算为止"，比"遇到第一条放不下就整体停"多利用一点预算。
///
/// [headerChars] = 段标题字符 + 1 个换行（只有"本段第一条被选中"时才计入）。
/// 预算口径 = **最终渲染出来的字符串长度**（含段头、含行间换行、不含尾部换行），
/// 所以"正好 6000"能被精确判定（见 `memory_prompt_test.dart` ③）。
_Selection _selectSection(
  List<_Pick> ranked, {
  required int budgetChars,
  required int maxEntries,
  required int headerChars,
}) {
  final picked = <_Pick>[];
  var omitted = 0;
  var cost = 0; // 已占用（含段头）；没有选中条目时恒 0
  for (final p in ranked) {
    if (picked.length >= maxEntries) {
      omitted++;
      continue;
    }
    final line = _lineFor(p);
    // 第一条：段头 + 换行 + 行；后续：行间换行 + 行。
    final addCost = picked.isEmpty ? headerChars + line.length : 1 + line.length;
    if (cost + addCost > budgetChars) {
      omitted++;
      continue;
    }
    picked.add(p);
    cost += addCost;
  }
  return _Selection(picked: picked, omitted: omitted, totalCost: cost);
}

String _renderSection(String title, List<_Pick> picked) =>
    '$title\n${picked.map(_lineFor).join('\n')}';

/// **渲染三作用域记忆**（`RunOptions.memory` 的唯一渲染入口）。
///
/// 返回 `''` 表示"没有任何记忆可注入"（**不产生空标题**）：
/// 所有段都空、全部过期、或预算连一条都放不下 —— 这三种情况都不该往 system
/// 里加一个只讲"另有 N 条未注入"的空壳（那只会白占前缀字节）。
/// 真有条目被裁掉、同时又有条目注入时，才输出"另有 N 条未注入"尾注。
///
/// [task] 当前用户请求（用于关键词检索）；[windowTokens] 模型窗口
/// （`BackendConfig.modelWindowTokens`），用于预算自适应。
String renderMemoryContext(
  MemoryContext ctx, {
  required String task,
  required int windowTokens,
}) {
  final keywords = memoryKeywords(task);
  final nowMs = ctx.nowMilliseconds();

  final sharedBudget = injectBudgetChars(
    capChars: ContractMemory.globalWorkspaceInjectMaxChars,
    windowTokens: windowTokens,
  );
  final sessionBudget = injectBudgetChars(
    capChars: ContractMemory.sessionInjectMaxChars,
    windowTokens: windowTokens,
  );

  final parts = <String>[];
  var injected = 0;
  var omitted = 0;
  var sharedLeft = sharedBudget;

  // 顺序的唯一真相：`memoryInjectionOrder`（顺序错 ⇒ 易变段挤到前面、缓存全废）。
  // 最后一段（session）吃独立预算；前面的段共享 global+workspace 预算。
  final lastScope = memoryInjectionOrder.last;
  final sharedScopes = memoryInjectionOrder.sublist(0, memoryInjectionOrder.length - 1);

  for (final scope in sharedScopes) {
    final alive = _aliveAndNotBlank(ctx.entriesOf(scope), nowMs);
    // 过期/空正文**不算"未注入"**（它们本就不该出现在任何清单里）；
    // 只有"候选窗裁掉"与"预算/条数裁掉"才如实计数（不变量 I6）。
    omitted += _windowDropped(alive);
    final ranked = _rankForInjection(alive, keywords);

    final title = memorySectionTitle(scope);
    final selection = _selectSection(
      ranked,
      budgetChars: sharedLeft,
      maxEntries: ContractMemory.injectMaxEntriesPerScope,
      headerChars: title.length + 1,
    );
    omitted += selection.omitted;
    if (selection.picked.isNotEmpty) {
      parts.add(_renderSection(title, selection.picked));
      injected += selection.picked.length;
      sharedLeft -= selection.totalCost;
    }
  }

  final sessionTitle = memorySectionTitle(lastScope);
  final aliveSession = _aliveAndNotBlank(ctx.entriesOf(lastScope), nowMs);
  omitted += _windowDropped(aliveSession);
  final sessionSelection = _selectSection(
    _rankForInjection(aliveSession, keywords),
    budgetChars: sessionBudget,
    maxEntries: ContractMemory.injectMaxEntriesPerScope,
    headerChars: sessionTitle.length + 1,
  );
  omitted += sessionSelection.omitted;
  if (sessionSelection.picked.isNotEmpty) {
    parts.add(_renderSection(sessionTitle, sessionSelection.picked));
    injected += sessionSelection.picked.length;
  }

  if (injected == 0) return '';

  if (omitted > 0) {
    parts.add('$memoryOmittedHintPrefix$omitted 条未注入，可在记忆页查看）');
  }
  parts.add(memoryConflictRule);
  return parts.join('\n\n');
}

/// **按预算从一组条目里挑出要注入的那些**（公开纯函数，供测试/宿主演算）。
///
/// 规则与 [renderMemoryContext] 段内完全一致（排序 → 整条取舍 → 预算/条数额），
/// 差别只在**预算口径**：这里不涉及段头，所以 `budgetChars` 只算选中条目的
/// 行成本（`'\n'.join(lines)` 的字符数）；渲染器会把段头也算进同一预算
/// （更保守，不会溢出）。
///
/// 返回顺序即注入顺序；未命中关键词的也在列表里（渲染时会压成摘要）。
List<MemoryRecord> selectForInjection(
  List<MemoryRecord> entries,
  String task, {
  required int budgetChars,
  required int maxEntries,
}) {
  // 过期判定用系统时钟（本函数不接收 nowMs —— 公开签名见设计稿 §3.5.2）。
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final alive = _aliveAndNotBlank(entries, nowMs);
  final selection = _selectSection(
    _rankForInjection(alive, memoryKeywords(task)),
    budgetChars: budgetChars,
    maxEntries: maxEntries,
    headerChars: 0,
  );
  return [for (final p in selection.picked) p.record];
}

// ============================================================================
// 旧路径：单段记忆（`RunOptions.memoryNote`，兼容保留）
// ============================================================================

/// 旧单段记忆的标题（**别改**：`memory_injection_test` 与既有会话缓存依赖它）。
const String _legacyMemoryTitle = '## 长期记忆（跨会话沉淀，越早越旧）';

/// 旧单段记忆的尾注（**别改**：文案与旧版逐字一致）。
const String _legacyMemoryTail =
    '记忆是**事实沉淀**，不用复述给用户看，只在需要时使用；'
    '若与当前对话冲突，**以当前对话为准**。';

/// **旧 `memoryNote` 路径的渲染**（`renderMemory` 的实现体，唯一一份格式）。
///
/// 输出与旧版**逐字节一致**（`'\n\n## 长期记忆…\n$raw\n\n<尾注>'`）：
/// 这条路径的行为不许变 —— 新宿主用 `RunOptions.memory`，老宿主/CLI 用
/// `memoryNote`，两者都不传时行为与历史完全一致。
String renderMemorySingleScope(String raw) {
  if (raw.trim().isEmpty) return '';
  return '\n\n$_legacyMemoryTitle\n$raw\n\n$_legacyMemoryTail';
}
