/// **SessionMemory（会话记忆）** —— 阶段 2：**纯本地、零 API** 的压缩摘要来源。
///
/// ## 为什么要有它（而不是每次都让模型摘要）
///
/// 压缩的兜底一直是"调一次模型，让它写结构化摘要"。代价有三条：
/// 1. **钱与延迟**：压缩发生在轮次开头、请求之前，用户能直接感觉到慢；
/// 2. **失败风险**：网络抖动 / 摘要返回空 ⇒ 只能退化到"强制丢弃"（信息真丢）；
/// 3. **不可复现**：同一段历史两次摘要内容不同，排障时对不上。
///
/// 而压缩真正必须保住的那几样 —— **目标、用户显式约束、改过哪些文件、
/// 卡在哪、下一步** —— 绝大部分在历史里是**结构化可读**的：
/// user 消息里的"不要动 X"、`write_file` 调用的 path 参数、`isError` 的工具结果、
/// 计划步骤状态。这些用**本地规则**抽出来就能当摘要视图用，零成本、零延迟、
/// 完全确定。
///
/// 所以策略是：**默认先用本地记忆（够用就不调模型）**，记忆不可用/过时或
/// 用户显式给了 focus 时才升级到 API 摘要（阶段 3）。
///
/// ## `stale` 是什么意思（失败降级）
///
/// 记忆更新失败（规则抛错、宿主回传超时）或**太久没更新**时，把它标成
/// `stale = true` 并**保留旧内容**：
/// · 不阻塞任务（压缩继续往下走，找阶段 3/兜底）；
/// · 也不假装它是最新的（`stale` 的记忆**不许**拿来渲染摘要视图 ——
///   把过时状态喂给模型比多花一次 API 更糟：模型会照着旧计划干活）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../contract/contract.dart';
import 'compaction_config.dart';
import 'message_scan.dart';
import 'token_estimation.dart';

/// 会话记忆：压缩时可**零 API** 渲染成摘要视图的那一份状态。
class SessionMemory {
  const SessionMemory({
    this.goal = '',
    this.constraints = const <String>[],
    this.done = const <String>[],
    this.decisions = const <String>[],
    this.files = const <String>[],
    this.openIssues = const <String>[],
    this.nextStep = '',
    this.updatedAtMs = 0,
    this.stale = false,
  });

  /// 任务目标（用户原话，截断到 [ContractCompaction.sessionMemoryGoalMaxChars]）。
  final String goal;

  /// 用户显式硬约束（"不要动 b.txt" 这类，必须置顶进摘要视图）。
  final List<String> constraints;

  /// 已完成项（计划里的已完成步骤 + 成功的写类工具调用）。
  final List<String> done;

  /// 关键决策（助手正文里"采用/决定/方案"那几行）。
  final List<String> decisions;

  /// 已修改/创建的文件路径（最近在前）。
  final List<String> files;

  /// 未决问题/报错（失败的工具结果的如实摘录）。
  final List<String> openIssues;

  /// 下一步（计划里第一个未完成步骤）。
  final String nextStep;

  /// 上次更新时间（毫秒时间戳）。
  final int updatedAtMs;

  /// 是否已过时（见库 KDoc 的「失败降级」）。
  final bool stale;

  /// 有没有任何可用的内容。
  bool get isEmpty =>
      goal.isEmpty &&
      constraints.isEmpty &&
      done.isEmpty &&
      decisions.isEmpty &&
      files.isEmpty &&
      openIssues.isEmpty &&
      nextStep.isEmpty;

  /// 是否**可以**用来渲染摘要视图（没过时 + 非空）。
  ///
  /// [maxAgeMs] 默认 [ContractCompaction.sessionMemoryStaleMs]：
  /// 太久没更新 ⇒ 与真实进展分叉的风险大于"省一次 API"。
  bool isUsableAt(int nowMs, {int? maxAgeMs}) {
    if (stale || isEmpty) return false;
    final age = nowMs - updatedAtMs;
    final limit = maxAgeMs ?? ContractCompaction.sessionMemoryStaleMs;
    // updatedAtMs == 0（宿主手造的、没打时间戳）⇒ 只按 stale/empty 判断
    if (updatedAtMs <= 0) return true;
    return age <= limit;
  }

  /// 打上 stale 标记（**保留旧内容**，绝不清空）。
  SessionMemory markStale() => SessionMemory(
        goal: goal,
        constraints: constraints,
        done: done,
        decisions: decisions,
        files: files,
        openIssues: openIssues,
        nextStep: nextStep,
        updatedAtMs: updatedAtMs,
        stale: true,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'goal': goal,
        'constraints': constraints,
        'done': done,
        'decisions': decisions,
        'files': files,
        'openIssues': openIssues,
        'nextStep': nextStep,
        'updatedAtMs': updatedAtMs,
        'stale': stale,
      };

  /// 从 JSON 还原（宿主持久化用）。**字段缺失/类型不对一律退化成空**，绝不抛：
  /// 记忆是增强，读坏了不该让整个 run 崩。
  factory SessionMemory.fromJson(Map<String, dynamic> json) {
    List<String> listOf(Object? v) => <String>[
          if (v is List)
            for (final e in v)
              if (e is String && e.trim().isNotEmpty) e,
        ];
    return SessionMemory(
      goal: json['goal'] is String ? json['goal'] as String : '',
      constraints: listOf(json['constraints']),
      done: listOf(json['done']),
      decisions: listOf(json['decisions']),
      files: listOf(json['files']),
      openIssues: listOf(json['openIssues']),
      nextStep: json['nextStep'] is String ? json['nextStep'] as String : '',
      updatedAtMs: json['updatedAtMs'] is int
          ? json['updatedAtMs'] as int
          : (json['updatedAtMs'] is num
              ? (json['updatedAtMs'] as num).toInt()
              : 0),
      stale: json['stale'] == true,
    );
  }

  @override
  String toString() => 'SessionMemory(goal=$goal, '
      '约束${constraints.length}项, 完成${done.length}项, '
      '文件${files.length}个, 未决${openIssues.length}项'
      '${stale ? ', STALE' : ''})';
}

/// **会话记忆的本地生成器** —— 纯规则，不碰网络、不碰磁盘。
///
/// ## 增量更新的语义
///
/// 每次压缩事件发生时，从**当前历史**重新抽一遍（历史本来就是完整真相），
/// 并把 [SessionMemory.updatedAtMs] 更新为"现在"。抽不出来的字段
/// **沿用上一份记忆**（`previous`）—— 这是"增量"的落地方式：
/// 模型刚清掉的老消息里可能才有那个目标描述，重新抽会抽空，沿用旧值才不丢。
class SessionMemoryBuilder {
  const SessionMemoryBuilder({this.config = const CompactionConfig()});

  final CompactionConfig config;

  /// 从历史抽一份记忆。
  ///
  /// [plan] 非空时用计划步骤算 done/nextStep（计划是模型自己写的，比正文可靠）。
  /// [previous] 非空时，**抽不到**的字段沿用它（增量语义）。
  /// [nowMs] 可注入（测试用固定时钟，避免 flaky）。
  SessionMemory build(
    List<LLMMessage> messages, {
    PlanState? plan,
    SessionMemory? previous,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final userTexts = _userTexts(messages);
    final recentUser = userTexts.length >
            ContractCompaction.sessionMemoryScanRecentMessages
        ? userTexts.sublist(
            userTexts.length - ContractCompaction.sessionMemoryScanRecentMessages)
        : userTexts;

    // 约束的扫描范围 = **第一条**（任务消息）+ 最近 N 条。
    //
    // 为什么必须把第一条单独加回来：长会话里"不要动 app.html"这类硬约束
    // 往往写在**开头那句任务**里，而它早就落到"最近 40 条"之外了。
    // 只扫最近 N 条 = 长会话中后期一压缩，最重要的约束就消失 ⇒ 模型去改
    // 用户明令禁止的文件。这条是真机踩过的坑，别简化掉。
    final scanUser = <String>[
      if (userTexts.isNotEmpty && !recentUser.contains(userTexts.first))
        userTexts.first,
      ...recentUser,
    ];

    final goal = _goal(userTexts, previous);
    final constraints = _constraints(scanUser);
    final files = _filePaths(messages);
    final done = _done(messages, plan);
    final decisions = _decisions(messages);
    final openIssues = _openIssues(messages);
    final nextStep = _nextStep(plan, previous);

    return SessionMemory(
      goal: goal,
      constraints: constraints.isEmpty && previous != null
          ? previous.constraints
          : constraints,
      done: done.isEmpty && previous != null ? previous.done : done,
      decisions: decisions.isEmpty && previous != null
          ? previous.decisions
          : decisions,
      files: files.isEmpty && previous != null ? previous.files : files,
      openIssues: openIssues,
      nextStep: nextStep,
      updatedAtMs: now,
    );
  }

  // ---------------------------------------------------------------------
  // 各字段的抽取规则（每条都有 why，别随手改）
  // ---------------------------------------------------------------------

  /// 取 user 消息正文（**排除我们自己插的维护/快照说明**）。
  List<String> _userTexts(List<LLMMessage> messages) {
    final out = <String>[];
    for (final m in messages) {
      if (m is! UserMessage) continue;
      final text = partsText(m.contents);
      if (text.trim().isEmpty) continue;
      if (_isSystemNote(text)) continue;
      out.add(text);
    }
    return out;
  }

  /// 目标：**第一条**真正的用户请求（任务是在一开始下的）。
  ///
  /// 为什么不取最后一条：最后一条可能是"继续"、"再快点"这类追问，
  /// 拿它当 goal 会让模型以为任务变了。旧记忆里有 goal 且这次抽不到 ⇒ 沿用。
  String _goal(List<String> userTexts, SessionMemory? previous) {
    for (final t in userTexts) {
      final first = flattenText(t);
      if (first.length < 2) continue;
      return clipText(first, ContractCompaction.sessionMemoryGoalMaxChars);
    }
    return previous?.goal ?? '';
  }

  /// 硬约束：最近 user 消息里**像约束**的句子。
  ///
  /// 关键词表是**中英双语**的祈使/禁止词。宁可多收一点（约束漏掉会被
  /// 模型当成"没说过"而去违反），也不许漏 —— 所以按句子切，不按整条消息切。
  List<String> _constraints(List<String> recentUser) {
    const markers = <String>[
      '不要',
      '不许',
      '不准',
      '不能',
      '必须',
      '只能',
      '禁止',
      '严禁',
      '切记',
      '一定',
      '别动',
      '无需',
      'must',
      'do not',
      "don't",
      'never',
      'only',
      'required',
    ];
    final out = <String>[];
    final seen = <String>{};
    for (final msg in recentUser.reversed) {
      for (final sentence in _sentences(msg)) {
        final lower = sentence.toLowerCase();
        if (!markers.any(lower.contains)) continue;
        final line = clipText(flattenText(sentence),
            ContractCompaction.sessionMemoryItemMaxChars);
        if (line.length < 3) continue;
        if (seen.add(line)) out.add(line);
        if (out.length >= ContractCompaction.sessionMemoryConstraintsMax) {
          return out;
        }
      }
    }
    return out;
  }

  /// 已修改/创建的文件：从写类工具的调用参数里拿路径（**最近在前**）。
  List<String> _filePaths(List<LLMMessage> messages) {
    final out = <String>[];
    final seen = <String>{};
    for (final m in messages.reversed) {
      if (m is! ModelMessage) continue;
      for (final call in m.functionCalls.reversed) {
        if (!isWriteToolName(call.name)) continue;
        final path = extractToolPath(call.arguments);
        if (path == null || path.isEmpty) continue;
        if (seen.add(path)) out.add(path);
        if (out.length >= config.recentFilesMax) return out;
      }
    }
    return out;
  }

  /// 已完成：计划里 `completed/cancelled` 的步骤 + 成功的写类调用。
  ///
  /// 为什么不取助手正文：助手每轮都说话，正文里"已完成"极难判定；
  /// 而**工具调用成功**与**计划状态**都是结构化事实，不会撒谎。
  List<String> _done(List<LLMMessage> messages, PlanState? plan) {
    final out = <String>[];
    if (plan != null) {
      for (final s in plan.steps) {
        if (s.status == StepStatus.completed ||
            s.status == StepStatus.cancelled) {
          out.add(clipText(flattenText(s.description),
              ContractCompaction.sessionMemoryItemMaxChars));
        }
        if (out.length >= ContractCompaction.sessionMemoryDoneMax) return out;
      }
    }
    // 写类工具成功 ⇒ 一个可验证的"做完了什么"
    for (final m in messages.reversed) {
      if (m is! FunctionExecutionResultMessage) continue;
      for (final r in m.results.reversed) {
        if (r.isError || !isWriteToolName(r.name)) continue;
        final path = extractToolPath(r.arguments);
        final item = clipText(
          '${writeVerbOf(r.name)} ${path ?? '（路径未知）'}',
          ContractCompaction.sessionMemoryItemMaxChars,
        );
        if (!out.contains(item)) out.add(item);
        if (out.length >= ContractCompaction.sessionMemoryDoneMax) return out;
      }
    }
    return out;
  }

  /// 关键决策：助手正文里带"决策味"的那几行（最近在前）。
  List<String> _decisions(List<LLMMessage> messages) {
    const markers = <String>[
      '决定',
      '采用',
      '方案',
      '选择',
      '因为',
      'decided',
      'chose',
      'approach',
      'trade-off',
      'tradeoff',
    ];
    final out = <String>[];
    final seen = <String>{};
    for (final m in messages.reversed) {
      if (m is! ModelMessage) continue;
      final text = m.textOutput ?? '';
      if (text.trim().isEmpty) continue;
      for (final sentence in _sentences(text)) {
        final lower = sentence.toLowerCase();
        if (!markers.any(lower.contains)) continue;
        final line =
            clipText(flattenText(sentence), ContractCompaction.sessionMemoryItemMaxChars);
        if (line.length < 4) continue;
        if (seen.add(line)) out.add(line);
        if (out.length >= ContractCompaction.sessionMemoryDecisionsMax) {
          return out;
        }
      }
    }
    return out;
  }

  /// 未决问题：**失败的工具结果**（`isError`）—— 最可靠的"卡点"信号。
  List<String> _openIssues(List<LLMMessage> messages) {
    final out = <String>[];
    for (final m in messages.reversed) {
      if (m is! FunctionExecutionResultMessage) continue;
      for (final r in m.results) {
        if (!r.isError) continue;
        final why = clipText(
          flattenText(partsText(r.content)),
          ContractCompaction.sessionMemoryItemMaxChars,
        );
        out.add('工具 ${r.name} 失败：$why');
        if (out.length >= ContractCompaction.sessionMemoryOpenIssuesMax) {
          return out;
        }
      }
    }
    return out;
  }

  /// 下一步：计划里第一个未完成步骤（`in_progress` 优先）。
  String _nextStep(PlanState? plan, SessionMemory? previous) {
    if (plan == null) return previous?.nextStep ?? '';
    PlanStep? pending;
    for (final s in plan.steps) {
      if (s.status == StepStatus.inProgress) {
        return clipText(flattenText(s.description),
            ContractCompaction.sessionMemoryItemMaxChars);
      }
      if (s.status == StepStatus.pending && pending == null) pending = s;
    }
    if (pending != null) {
      return clipText(flattenText(pending.description),
          ContractCompaction.sessionMemoryItemMaxChars);
    }
    return '';
  }

  // ---------------------------------------------------------------------
  // 小工具
  // ---------------------------------------------------------------------

  /// 我们自己插入的"维护说明/压缩快照"**不是**用户约束来源。
  ///
  /// 如果不排除它们，压缩一次之后下一轮就会把
  /// "[系统维护] 上下文窗口吃紧…" 当成用户说过的话抽成约束 —— 越压越脏。
  static bool _isSystemNote(String text) {
    final head = text.trimLeft();
    return head.startsWith('[系统维护]') ||
        head.startsWith('[上下文压缩快照]');
  }

  /// 按句切（中文句号/问号/感叹号/分号/换行 + 英文 `. `）。
  ///
  /// 切句而不是整条，是为了让"约束"不被同一句里的废话淹没，
  /// 也不至于把整段长文当一条约束。
  ///
  /// ⚠️ **不要**按裸 `.` 切：`不要动 b.txt。` 会被切成 `不要动 b` + `txt`，
  /// 约束内容和文件名同时废掉。英文按 `. `（点+空白）切即可，且不用
  /// 后行断言（不同平台正则实现细节不同，没必要冒险）。
  static List<String> _sentences(String text) => text
      .split(RegExp(r'[。！？；;\n\r]+|\.\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}
