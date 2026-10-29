// Copyright (C) 2026 The Heracles Authors
//
// **改动统计的纯函数**（2026-10-29 从 `widgets/tool_call_card.dart` 下沉）。
//
// ============================================================================
// 为什么搬到 services 层
// ============================================================================
// `diffStatOf` / `estimatedDiffStatOf` / `changedFilesOf` 是**纯数据函数**
// （不碰 widget、不碰 Context、不碰渲染），但 `LocalAgentExecutor` 要用它们
// 做「文件改动摘要」的**记账**（数字来源是工具结果里的 diff，不是模型自报）。
//
// 之前 local_agent 直接 `import '../widgets/tool_call_card.dart'` ——
// 服务层反向依赖 UI 层，且前端重构 UI 文件时本侧会编译失败（2026-10-29
// 实际发生过：`tool_call_card.dart` 半截落盘导致这两个符号 undefined）。
// 现在函数住在这里：UI 与服务层都能 import，依赖方向是
// `widgets → services`（单向，无环）。
//
// ⚠️ UI 侧如果仍从 `tool_call_card.dart` 导入这些名字，那是 UI 线自己的
// 迁移；本文件不与 UI 文件互相 import。
library;

import 'dart:convert';

/// 把改动统计成 `+N −M`（2026-10-21，BUG-4）。
///
/// ## 数据从哪来
///
/// **Kotlin 侧已经算好了**：`DiffReceipt.render(...)` 的输出形如
///
/// ```text
/// @@ 第 4 行 @@
/// - 旧的一行
/// + 新的一行
/// ```
///
/// 这里不做真正的 diff 计算（那要拿到改前/改后全文，调用方没有；
/// 真做出来还可能与后端不一致）。只数行号前缀：
/// 以 `+ ` 开头的算新增，以 `- ` 开头的算删除。
///
/// ⚠️ 只对**写类工具的 result** 用。别拿它去数普通文本 ——
/// Markdown 列表里的 `- ` 会被误算成删除。
class DiffStat {
  const DiffStat({
    required this.added,
    required this.removed,
    required this.isDiff,
  });

  final int added;
  final int removed;

  /// 结果里到底有没有 diff 结构（没有 ⇒ 不显示"+0 −0"这种假统计）。
  final bool isDiff;

  bool get hasChanges => added > 0 || removed > 0;

  /// `+12 −3`（用真正的减号 U+2212，与 GitHub 口径一致）。
  String get label => '+$added −$removed';

  @override
  String toString() => 'DiffStat($label, isDiff=$isDiff)';
}

/// 从写类工具的**结果文本**里数 `+N −M`。
///
/// 先要求出现一个 **diff 锚**（`@@ 第 N 行 @@` / `（新建文件` /
/// `（内容未变化`）：任意 Markdown 列表都会带 `- `，没有锚就会把普通文本
/// 误算成删除。没有锚 ⇒ `isDiff = false`（宁可不显示，也不显示假数字）。
DiffStat diffStatOf(String? resultText) {
  if (resultText == null || resultText.isEmpty) {
    return const DiffStat(added: 0, removed: 0, isDiff: false);
  }
  final lines = const LineSplitter().convert(resultText);
  final anchored = lines.any(
    (l) =>
        l.startsWith('@@') ||
        l.startsWith('（新建文件') ||
        l.startsWith('（内容未变化'),
  );
  if (!anchored) return const DiffStat(added: 0, removed: 0, isDiff: false);

  var added = 0;
  var removed = 0;
  for (final line in lines) {
    if (line.startsWith('+ ') || line.startsWith('+\t')) {
      added++;
    } else if (line.startsWith('- ') || line.startsWith('-\t')) {
      removed++;
    }
  }
  return DiffStat(added: added, removed: removed, isDiff: true);
}

/// 这次调用**动了哪些文件**（用于「文件改动摘要」行）。
///
/// 按工具语义取参数：写/改取 `path`，移动取 `from`→`to`，删除取 `path`。
/// **拿不到就返回空列表**（不编造文件名 —— 那比不显示更糟）。
List<String> changedFilesOf(Map<String, String> args) {
  final from = (args['from'] ?? '').trim();
  final to = (args['to'] ?? '').trim();
  final path = (args['path'] ?? '').trim();
  if (from.isNotEmpty && to.isNotEmpty) return ['$from → $to'];
  if (path.isNotEmpty) return [path];
  if (to.isNotEmpty) return [to];
  return const [];
}

/// 写类工具这次**预计**新增/删除多少行（流式阶段用 —— 那时还没有 result）。
///
/// 依据按可靠性排序：
/// 1. `patch` / `diff`（`apply_patch`）—— 正文里自带 `+`/`-` 行前缀，最准
/// 2. `new_string` / `old_string`（`edit`）—— 两个片段的行数即增删量
/// 3. `content`（`write_file`）—— 只能数出"写入 N 行"，删除量未知（给 0）
///
/// ⚠️ 第 3 种是**下界不是真值**：整文件重写时真实删除量取决于原文件。
/// 最终数字以工具结果的 [diffStatOf] 为准。
DiffStat estimatedDiffStatOf(Map<String, String> args) {
  final patch = args['patch'] ?? args['diff'];
  if (patch != null && patch.isNotEmpty) {
    var a = 0;
    var d = 0;
    for (final line in const LineSplitter().convert(patch)) {
      if (line.startsWith('+') && !line.startsWith('+++')) a++;
      if (line.startsWith('-') && !line.startsWith('---')) d++;
    }
    return DiffStat(added: a, removed: d, isDiff: true);
  }
  final newString = args['new_string'];
  final oldString = args['old_string'];
  if (newString != null || oldString != null) {
    return DiffStat(
      added: newString == null || newString.isEmpty
          ? 0
          : const LineSplitter().convert(newString).length,
      removed: oldString == null || oldString.isEmpty
          ? 0
          : const LineSplitter().convert(oldString).length,
      isDiff: true,
    );
  }
  final content = args['content'];
  if (content != null && content.isNotEmpty) {
    return DiffStat(
      added: const LineSplitter().convert(content).length,
      removed: 0,
      isDiff: true,
    );
  }
  return const DiffStat(added: 0, removed: 0, isDiff: false);
}
