/// **摘要视图渲染** —— 阶段 2（SessionMemory）与阶段 3（API 摘要）**共用**的落地形状。
///
/// ## 为什么两阶段必须共用一套渲染
///
/// 如果本地记忆渲染一种格式、模型摘要渲染另一种，就会出现两类回归：
/// 1. 模型看到两种"压缩快照"，行为不一致（一处有约束、一处没有）；
/// 2. 前端/测试要认两种格式，改一处漏一处。
///
/// 所以格式只在这里定义一次：**顶部是"必须继续遵守的规则"（用户显式约束置顶），
/// 然后是项目指令 → 最近文件 → 目标/已完成/决策/错误/下一步**。
///
/// ## 为什么"用户约束"必须置顶（而不是跟在摘要正文后面）
///
/// 真机踩过的坑：用户说过"文件写入 A，不要动 B"，摘要把它埋在第三段 =
/// 模型没注意、去改了 B，而用户完全不知道是压缩丢的。
/// 位置就是权重 —— 硬约束必须出现在模型第一眼看到的地方。
library;

import 'compaction_config.dart';
import 'reload_context.dart';
import 'session_memory.dart';
import 'structured_summarizer.dart';

/// 摘要视图的来源（写进视图里，便于排障与"这条摘要是不是调过模型"的追问）。
enum SummarySource {
  /// 阶段 2：本地会话记忆（**零 API**）。
  sessionMemory,

  /// 阶段 3：模型结构化摘要（失败时不会走到这里）。
  apiSummary,
}

/// 把"要保留下来的东西"渲染成一条可以插进历史最前面的快照消息。
class SummaryViewBuilder {
  const SummaryViewBuilder({this.config = const CompactionConfig()});

  final CompactionConfig config;

  /// 摘要快照的**固定前缀**（测试/前端逐字依赖，别改）。
  static const String notePrefix = '[上下文压缩快照]';

  /// 渲染。
  ///
  /// [memory] 与 [api] 二选一（按 [source]）；两者都空 ⇒ 返回空串，
  /// 调用方据此判定"这一层没做成"（**绝不插一条空快照**）。
  String build({
    required SummarySource source,
    required ReloadedContext reloaded,
    SessionMemory? memory,
    ApiSummary? api,
    List<String> extraNotes = const <String>[],
  }) {
    final constraints = <String>[
      if (memory != null) ...memory.constraints,
      if (api != null) ...api.constraints,
    ];

    final goal = _firstNonEmpty(<String>[
      if (memory != null) memory.goal,
      if (api != null) api.goal,
    ]);
    final done = <String>[
      if (memory != null) ...memory.done,
      if (api != null) ...api.done,
    ];
    final decisions = <String>[
      if (memory != null) ...memory.decisions,
      if (api != null) ...api.decisions,
    ];
    final files = <String>[
      if (memory != null) ...memory.files,
      if (api != null) ...api.files,
    ];
    final errors = <String>[
      if (memory != null) ...memory.openIssues,
      if (api != null) ...api.errors,
    ];
    final openIssues = <String>[
      if (memory != null) ...memory.openIssues,
      if (api != null) ...api.openIssues,
    ];
    final nextStep = _firstNonEmpty(<String>[
      if (memory != null) memory.nextStep,
      if (api != null) api.nextStep,
    ]);

    // 一条内容都没有 ⇒ 这条快照没有信息量，宁可让调用方走下一层
    final hasContent = goal.isNotEmpty ||
        constraints.isNotEmpty ||
        done.isNotEmpty ||
        decisions.isNotEmpty ||
        files.isNotEmpty ||
        errors.isNotEmpty ||
        openIssues.isNotEmpty ||
        nextStep.isNotEmpty;
    if (!hasContent) return '';

    final b = StringBuffer()
      ..writeln('$notePrefix 以下是更早对话的摘要（原文已移除，可按需重新取证）：')
      ..writeln('（来源：${source == SummarySource.sessionMemory ? '本地会话记忆，未调用模型' : '模型结构化摘要'}）');

    if (constraints.isNotEmpty) {
      b.writeln('【必须继续遵守的用户约束（置顶）】');
      for (final c in constraints) {
        b.writeln('- $c');
      }
      b.writeln('（安全规则与路径范围规则以下方"项目指令"与工作区实际约定为准；'
          '本视图不替代它们。）');
    }

    final ins = reloaded.instructions;
    if (ins != null) {
      final tail = ins.truncated
          ? '，节选 ${ins.content.length}/${ins.originalChars} 字符'
          : '';
      b
        ..writeln('【项目指令（${ins.source}$tail）】')
        ..writeln(ins.content);
    }

    if (reloaded.recentFiles.isNotEmpty) {
      b.writeln('【最近修改的文件（≤${config.recentFilesMax}）】');
      for (final f in reloaded.recentFiles) {
        b.writeln(f.render());
      }
    }

    if (goal.isNotEmpty) {
      b
        ..writeln('【任务目标】')
        ..writeln(goal);
    }
    if (done.isNotEmpty) {
      b.writeln('【已完成】');
      for (final d in done) {
        b.writeln('- $d');
      }
    }
    if (decisions.isNotEmpty) {
      b.writeln('【关键决策】');
      for (final d in decisions) {
        b.writeln('- $d');
      }
    }
    if (files.isNotEmpty) {
      b.writeln('【相关文件与路径】');
      for (final f in files) {
        b.writeln('- $f');
      }
    }
    if (errors.isNotEmpty) {
      b.writeln('【错误与修复】');
      for (final e in errors) {
        b.writeln('- $e');
      }
    }
    if (openIssues.isNotEmpty) {
      b.writeln('【未决问题】');
      for (final o in openIssues) {
        b.writeln('- $o');
      }
    }
    if (nextStep.isNotEmpty) {
      b
        ..writeln('【下一步】')
        ..writeln(nextStep);
    }
    for (final n in extraNotes) {
      b.writeln('（$n）');
    }

    // 最后这两句是"不许骗模型"的护栏：它必须知道自己在看摘要，
    // 也必须知道发生冲突时以文件为准（否则会照着旧摘要"凭记忆"改代码）。
    b
      ..writeln('[说明] 上面的工具原始输出已被清理；需要细节请重新执行相应工具读取。')
      ..writeln('如果摘要与你的记忆有冲突，**以工作区文件的实际内容为准**。');
    return b.toString().trimRight();
  }

  static String _firstNonEmpty(List<String> values) {
    for (final v in values) {
      if (v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }
}
