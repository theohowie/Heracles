import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

// ============================================================================
// 共享：步骤行的统一左侧几何（2026-10-23）
// ============================================================================

/// **步骤行的统一左侧几何**（用户报：「分析请求没和其他工具调用对齐」）。
///
/// ## 为什么要集中定义
///
/// 「分析请求」行（`stream_step.dart`）与工具调用行（本文件）是同一列里的
/// 两条日志，用户会**横向扫视**它们。此前两行各写各的几何，结果对不齐：
///
/// | 项 | 分析行（改前） | 工具行（改前） |
/// |---|---|---|
/// | 水平内边距 | 0 | `HSpace.sm`（8） |
/// | 左侧箭头 | 18 | 18 |
/// | 箭头后间距 | `HSpace.xs`（4） | `HSpace.xs`（4） |
/// | 状态图标 | 12（转圈）/ 14 | 14 |
/// | 图标后间距 | `HSpace.sm`（8） | **6** |
///
/// ⇒ 左起箭头差 8px、标题文字起点差 14px，一屏里两列日志左边缘参差，
/// 看着像渲染错。现在两个组件都从这里取值 —— **只有一套几何**，
/// 改一处两行一起变，不会再出现"各自微调后又不齐"。
///
/// ⚠️ 改这组值之前先确认**两处都跟着变**：这里是唯一真相源。
// ★ 展开箭头已退役（2026-10-26 用户令：所有工具行的展开箭头都
// 去掉、包括合并行的 > 与步骤行的 ∨，且全部行左侧对齐）。箭头槽
// 归零后，所有引用这两个常量的对齐点（分析行占位、展开明细缩进）
// 自动跟随左移，状态图标成一列 —— 行仍可点按展开明细，只是不画
// 箭头。常量保留是为让那套共享几何继续成立，不要删。
const double kStepRowArrowSize = 0.0;
const double kStepRowArrowGap = 0.0;
const double kStepRowStatusSize = 14.0;
const double kStepRowStatusGap = 6.0;
const double kStepRowHPad = HSpace.sm;
const double kStepRowVPad = HSpace.xs;

/// **工具名 → 人话**（2026-10-13，用户要求）。
///
/// ## 为什么需要
///
/// 用户原话：「生成的代码片段是直接展示到工作步骤里了，应该是
/// 直接显示：**正在修改文件代码**」。
///
/// 卡片标题原来直接渲 `call.tool`（`write_file` / `list_files`）——
/// 那是**给模型看的 schema 名**，不是给人看的。
/// 用户看到的应该是一句能读的动作描述。
///
/// ## 取名规则
///
/// 用**动词 + 对象**的中文短语，与 `FileTools.kt` 的 `description`
/// 语义一致（那里是给模型的正式描述，这里是给用户的短语）。
/// 未登记的工具名**原样回显** —— 宁可露出 schema 名，
/// 也不要编一个可能不准的中文说法（诚实优先）。
/// **工具行的显示名**：`动词 + 目标`（2026-10-22，对齐用户给的参考界面）。
///
/// 工具动词表 —— **唯一真相源**（2026-10-23 抽出）。
///
/// ## 三个字段各用在哪（别混）
///
/// | 字段 | 用途 | 例 |
/// |---|---|---|
/// | `run` / `done` | **单行标题**的动词（后面还会接目标路径/命令） | `读取了` + `app/lib/x.dart` |
/// | `summary` | **折叠行**的独立短语（不接目标） | `读取了文件` |
///
/// ⚠️ 为什么不共用一个字段：单行是「动词 + 目标」，折叠是「一句完整的话」。
/// 单行若写成 `读取了文件 app/lib/x.dart` 就重复啰嗦；折叠若只写 `读取了`
/// 就是半句话。**抽表时差点把已验收的单行措辞改坏**，所以这里显式分开。
({String run, String done, String summary}) toolVerbs(String tool) =>
    switch (tool) {
      'read_file' => (run: '正在读取', done: '读取了', summary: '读取了文件'),
      'list_files' => (
          run: '正在查看目录',
          done: '查看了目录',
          summary: '查看了目录'
        ),
      'find_files' => (run: '正在查找', done: '查找了', summary: '查找了文件'),
      'grep_files' => (run: '正在搜索', done: '搜索了', summary: '搜索了内容'),
      'write_file' => (run: '正在写入', done: '写入了', summary: '写入了文件'),
      'edit' => (run: '正在编辑', done: '编辑了', summary: '编辑了文件'),
      'apply_patch' => (
          run: '正在按补丁修改',
          done: '按补丁修改了',
          summary: '按补丁修改了文件'
        ),
      'mkdir' => (run: '正在创建目录', done: '创建了目录', summary: '创建了目录'),
      'delete_path' => (run: '正在删除', done: '删除了', summary: '删除了文件'),
      'move_path' => (run: '正在移动', done: '移动了', summary: '移动了文件'),
      'copy_path' => (run: '正在复制', done: '复制了', summary: '复制了文件'),
      'run_shell_command' => (
          run: '正在执行命令',
          done: '执行了命令',
          summary: '执行了命令'
        ),
      'web_fetch' => (run: '正在抓取网页', done: '抓取了网页', summary: '抓取了网页'),
      'check_device_state' => (
          run: '正在读取设备状态',
          done: '读取了设备状态',
          summary: '读取了设备状态'
        ),
      'write_todos' => (run: '正在更新待办', done: '更新了待办', summary: '更新了待办'),
      'ask_user' => (run: '正在向你提问', done: '向你提了问', summary: '向你提了问'),
      'save_memory' => (run: '正在记录', done: '记录了', summary: '记录了要点'),
      'build_apk' => (run: '正在构建 APK', done: '构建了 APK', summary: '构建了 APK'),
      'apk_decompile' => (
          run: '正在反编译',
          done: '反编译了',
          summary: '反编译了 APK'
        ),
      'apk_recompile' => (run: '正在重打包', done: '重打包了', summary: '重打包了 APK'),
      'apk_sign' => (run: '正在签名', done: '签名了', summary: '签名了 APK'),
      'install_apk' => (run: '正在安装', done: '安装了', summary: '安装了 APK'),
      // 前向兼容：图片读取工具（旧 Kotlin 层有 `view_image`，当前 backend 没有）。
      // 留着是为了"工具面回补"那天折叠行能直接说人话，而不是"调用了 view_image"。
      'view_image' => (run: '正在读取图片', done: '读取了图片', summary: '读取了图片'),
      _ => (run: '正在调用 $tool', done: '调用了 $tool', summary: '调用了 $tool'),
    };

/// 一组**连续**工具调用压成一句话（折叠行的标题）。
///
/// ## 用户要求（原话）
///
/// > 「调用工具太多了，我往下翻全是调用工具，导致观感不好，所以要你做一个折叠。
/// >   就是默认是图片这样合并」
///
/// 参考形态：`>_ 执行了命令并已读取图片` —— 即**只讲做了什么**，
/// 不复述每个调用的路径/参数（那些展开后看）。
///
/// ## 归纳规则
///
/// · 按**首次出现顺序**取动词并去重（同一类只留一个，否则"读取了文件并读取了文件"）
/// · 1 类 ⇒ `读取了文件`
/// · 2 类 ⇒ `执行了命令并读取了图片`
/// · ≥3 类 ⇒ `执行了命令、查看了目录 等 5 项`（用**调用次数**收尾，不是类别数）
String toolGroupSummary(List<String> tools) {
  if (tools.isEmpty) return '没有工具调用';
  final phrases = <String>[];
  for (final t in tools) {
    final s = toolVerbs(t).summary;
    if (!phrases.contains(s)) phrases.add(s);
  }
  if (phrases.length == 1) return phrases.first;
  if (phrases.length == 2) return '${phrases[0]}并${phrases[1]}';
  return '${phrases[0]}、${phrases[1]} 等 ${tools.length} 项';
}

/// **一组连续工具调用的折叠行**（2026-10-23，用户要求"默认合并"）。
///
/// ## 长什么样
///
/// ```
/// ›  >_ 执行了命令并读取了图片                        3
/// ```
/// 左侧箭头可点（展开 ⇒ 逐条显示原来的工具行），中间 `>_` 图标 + 一句话摘要，
/// 右侧是**调用次数**（一眼知道合并了几条）。
///
/// ## 为什么单独一个 widget 而不是塞进 `ToolCallCard`
///
/// `ToolCallCard` 是**单条**调用的卡片（含参数/结果/展开正文）。折叠行只讲
/// "这一组做了什么"，两者数据形状不同；塞在一起会让那个已经有 900 行的
/// 组件再长一段条件分支，而它已经承担了 diff 统计/三态/复制按钮等职责。
///
/// ## 几何
///
/// 一律走 `kStepRow*`（与「分析/思考」行、单条工具行**同一套常量**）——
/// 用户此前专门报过"没和其他工具调用对齐"，对齐不能因为多一种行就破。
class ToolGroupRow extends StatelessWidget {
  const ToolGroupRow({
    super.key,
    required this.tools,
    required this.expanded,
    required this.onToggle,
    this.failed = false,
  });

  /// 这一组里每个调用的工具名（顺序 = 实际发生顺序）。
  final List<String> tools;

  /// 是否已展开。
  final bool expanded;

  final VoidCallback onToggle;

  /// 组里**只要有一条失败**就该传 true（由调用方判定，见 `chat_screen`）。
  ///
  /// 为什么由调用方给而不是在这里 `any`：这里只有工具名，没有状态；
  /// 名子里推不出成败（同一工具可能这次成、下次败）。
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final summary = toolGroupSummary(tools);
    final tone = failed ? HColors.errorOn(h.dark) : h.text;

    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(HRadius.sm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTapTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kStepRowHPad,
            vertical: kStepRowVPad,
          ),
          child: Row(
            children: [
              Icon(
                AppIcons.terminal,
                size: kStepRowStatusSize,
                color: failed ? tone : h.textDim,
              ),
              const SizedBox(width: kStepRowStatusGap),
              Flexible(
                child: Text(
                  failed ? '$summary（含失败）' : summary,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: tone,
                  ),
                ),
              ),
              const SizedBox(width: HSpace.xs),
              // 次数徽标：一眼看出"这几条被合并了"
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: h.surfaceAlt,
                  borderRadius: BorderRadius.circular(HRadius.pill),
                  border: Border.all(color: h.border),
                ),
                child: Text(
                  '${tools.length}',
                  style: TextStyle(
                    fontFamily: kMonoFontFamily,
                    fontFamilyFallback: kMonoFallback,
                    fontSize: 11,
                    color: h.textDim,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
/// ```
/// >_ 运行命令 · Find prompt insertion point
///    读取 app/lib/widgets/stream_step.dart
///    编辑 app/lib/widgets/stream_step.dart 1KB +8 −1
/// ```
/// 即：**动词**（运行/读取/编辑）+ **目标**（命令摘要/路径），而不是
/// 我们原来的「人话名词 + 成功 + N 个参数」（`查看目录文件 成功 · 1 个参数`）。
///
/// ## 为什么要改
///
/// 用户原话：「你看到我的工具调用是怎么写的展示嘛？你不要忽视这个啊」。
/// 原来的写法把"做了什么"藏在参数个数后面 —— 一屏十行全是
/// 「执行命令 成功 · 1 个参数」，看不出到底对**哪个文件**做了什么。
///
/// ## 状态怎么表达
///
/// 用**动词时态**而不是一个"成功"字样（参考界面就是这样）：
/// 运行中 → `正在读取 …`；结束后 → `读取了 …`；失败 → 末尾补 `失败`。
String toolCallLabel(String tool, Map<String, String> args,
    {required bool running, required bool failed}) {
  final v = toolVerbs(tool);
  final verb = running ? v.run : v.done;

  // 目标：优先路径，其次命令/描述/模式
  final raw = (args['path'] ??
          args['command'] ??
          args['description'] ??
          args['pattern'] ??
          args['from'] ??
          args['projectDir'] ??
          '')
      .toString()
      .trim();
  var target = raw.replaceAll('\n', ' ');
  if (target.length > 48) target = '${target.substring(0, 48)}…';

  final head = target.isEmpty ? verb : '$verb $target';
  return failed ? '$head（失败）' : head;
}

String friendlyToolName(String tool) => switch (tool) {
      'write_file' => '修改文件代码',
      'read_file' => '读取文件',
      'list_files' => '查看目录文件',
      // ★ 2026-10-19：补齐真实工具面（此前一大半露出 schema 名，用户看到的是
      //   `update_plan` / `run_shell_command` / `apply_patch` —— 那是给模型看的）
      'update_plan' => '更新任务计划',
      'apply_patch' => '局部修改代码',
      // ★ 2026-10-21（BUG-4）：`edit` / `restore_path` 此前**没登记**
      //   ⇒ 卡片顶部露出的是 schema 名 `edit` / `restore_path`（给模型看的）。
      //   它们都是写类工具，必须和 `apply_patch` 同一档人话。
      'edit' => '局部修改代码',
      'restore_path' => '恢复文件到快照',
      'find_files' => '查找文件',
      'grep_files' => '搜索代码',
      'run_shell_command' => '执行命令',
      'mkdir' => '创建目录',
      'save_memory' => '记住项目信息',
      'ask_user' => '向你提问',
      'delete_path' => '删除文件',
      'move_path' => '移动文件',
      'copy_path' => '复制文件',
      'search_tools' => '查找可用工具',
      'scaffold_android' => '生成 Android 工程',
      'build_apk' => '构建 APK',
      'apk_decompile' => '反编译 APK',
      'apk_recompile' => '重打包 APK',
      'apk_sign' => '签名 APK',
      'd8_convert' => '转换 DEX',
      'unzip_file' => '解压',
      'zip_file' => '压缩',
      // 阶段二可能出现的工具，先备好说法
      'run_command' => '执行命令',
      'delete_file' => '删除文件',
      'search' => '搜索内容',
      _ => tool,
    };

/// 工具调用的**进行中**说法（决定卡片标题用"正在…"还是完成态）。
String runningToolName(String tool) => switch (tool) {
      'write_file' => '正在修改文件代码',
      'read_file' => '正在读取文件',
      'list_files' => '正在查看目录文件',
      'update_plan' => '正在更新任务计划',
      'apply_patch' => '正在局部修改代码',
      'edit' => '正在局部修改代码',
      'restore_path' => '正在恢复文件',
      'find_files' => '正在查找文件',
      'grep_files' => '正在搜索代码',
      'run_shell_command' => '正在执行命令',
      'mkdir' => '正在创建目录',
      'save_memory' => '正在记录项目信息',
      'ask_user' => '正在向你提问',
      'delete_path' => '正在删除文件',
      'move_path' => '正在移动文件',
      'copy_path' => '正在复制文件',
      'search_tools' => '正在查找可用工具',
      'scaffold_android' => '正在生成 Android 工程',
      'build_apk' => '正在构建 APK',
      'apk_decompile' => '正在反编译 APK',
      'apk_recompile' => '正在重打包 APK',
      'apk_sign' => '正在签名 APK',
      'd8_convert' => '正在转换 DEX',
      'unzip_file' => '正在解压',
      'zip_file' => '正在压缩',
      'run_command' => '正在执行命令',
      'delete_file' => '正在删除文件',
      'search' => '正在搜索内容',
      _ => '正在执行 $tool',
    };

/// **会改文件系统的工具** —— 这些工具的卡片**必须**给「完整改动」入口
/// （2026-10-21，BUG-4）。
///
/// ## 为什么需要这个集合
///
/// 用户原话：「调用工具不透明，看不到改了什么代码」。
///
/// Kotlin 侧的写类工具（`write_file` / `edit` / `apply_patch` …）在**结果里**
/// 已经带了 `DiffReceipt` 渲染的 diff（`FileTools.DiffReceipt`：
/// `@@ 第 N 行 @@` + `- 旧行` / `+ 新行`），但**卡片只显示摘要** ——
/// 标准档把结果截到 80 字符，用户看到的就只剩一行 `@@ 第 3 行 @@…`。
///
/// 所以这里给写类工具单独开一个**默认折叠、一点就开**的「改动详情」区块，
/// 里面渲染**完整** diff（不受档位截断）+ 等宽字体 + `+N −M` 统计。
/// **不动 `StepDetail.summaryChars`** —— 那是全局设置，改它会波及所有卡片。
const Set<String> kFileWritingTools = {
  'write_file',
  'edit',
  'apply_patch',
  'delete_path',
  'move_path',
  'copy_path',
  'restore_path',
};

/// 这次调用是否"会改文件"（决定要不要给 diff 入口）。
bool isFileWritingTool(String tool) => kFileWritingTools.contains(tool);

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
/// 界面上**不再做一次真正的 diff 计算**（那要拿到改前/改后全文，UI 没有；
/// 真做出来还可能与后端不一致）。这里只是**数行号前缀**：
/// 以 `+ ` 开头的算新增，以 `- ` 开头的算删除。
///
/// ⚠️ 只对**写类工具的 result** 用（`call.result`）。别拿它去数普通文本 ——
/// Markdown 列表里的 `- ` 会被误算成删除。
class DiffStat {
  const DiffStat({required this.added, required this.removed, required this.isDiff});

  final int added;
  final int removed;

  /// 结果里到底有没有 diff 结构（没有 ⇒ 不显示"+0 −0"这种假统计）。
  final bool isDiff;

  bool get hasChanges => added > 0 || removed > 0;

  /// `+12 −3`（用真正的减号 U+2212，不是连字符 —— 与 GitHub / DeepSeek harness 一致）。
  String get label => '+$added −$removed';

  @override
  String toString() => 'DiffStat($label, isDiff=$isDiff)';
}

/// 从写类工具的**结果文本**里数 `+N −M`。
///
/// ## 为什么必须有"锚"
///
/// 只按 `+ ` / `- ` 前缀数行是**不可靠**的：任意 Markdown 列表（`- 某一项`）
/// 都会被误算成"删了一行"。所以先要求出现一个 **diff 锚**：
/// `@@ 第 N 行 @@`（改内容）或 `（新建文件` / `（内容未变化）`（`DiffReceipt`
/// 的另两种形态）。没有锚 ⇒ `isDiff = false`，卡片**不显示**统计
/// （宁可不显示，也不显示一个假数字）。
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
/// 1. `patch` / `diff`（`apply_patch`）—— 正文里**自带** `+`/`-` 行前缀，最准
/// 2. `new_string` / `old_string`（`edit`）—— 两个片段的行数即增删量
/// 3. `content`（`write_file`）—— 只能数出"写入 N 行"，删除量未知（给 0）
///
/// ⚠️ 第 3 种是**下界不是真值**：整文件重写时真实删除量取决于原文件。
/// 所以流式摘要只是"让人看见改了哪、大概多少"，最终数字以工具结果的
/// [diffStatOf] 为准。
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
      added: newString == null || newString.isEmpty ? 0 : const LineSplitter().convert(newString).length,
      removed: oldString == null || oldString.isEmpty ? 0 : const LineSplitter().convert(oldString).length,
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


/// 工具调用卡片 —— 可折叠，按「工作步骤展示」档位分级渲染。
///
/// 设计意图（ADR-014）：**过程可见但可收起**。
/// coding agent 的每一步都要能追溯，但不能淹没回答。
///
/// ## 四档分级（2026-10-10 落地，见 `StepDetail`）
///
/// | 档位 | 工具名+状态 | 参数 | 结果 | 模型原始输出 |
/// |---|---|---|---|---|
/// | 精简 | ✅ | ❌ | ❌ | ❌ |
/// | 标准 | ✅ | 摘要 | 摘要 | ❌ |
/// | 详细 | ✅ | 完整 | 完整 | ❌ |
/// | 完全展开 | ✅ | 完整 | 完整 | ✅ |
///
/// ## 为什么分级逻辑集中在这里
///
/// 之前 `stepDetail` 是**空实现** —— 设置里能选，选了没有任何变化。
/// 用户要的是「功能，不是界面」，所以这一档必须真的改变渲染密度。
///
/// 所有 `StepDetail.xxx` 的判断都收在本文件内，不让调用方各自 switch ——
/// 否则以后加档位一定会漏改某处。
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({
    super.key,
    required this.call,
    this.stepDetail = StepDetail.standard,
  });

  final HToolCall call;

  /// 工作步骤展示档位。默认「标准」—— 与 `AppSettings` 的默认值一致，
  /// 保证单独使用本组件时（测试、预览）可见行为与正式默认档相同。
  final StepDetail stepDetail;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  /// 是否展开明细。
  ///
  /// ## ★ 2026-10-22：默认值随档位走（真机截图驱动的改版）
  ///
  /// 用户原话：「我不要调用工具是一个卡片的形式……可以点击展开……」
  /// 真机截图里他处在**精简档**，而旧实现在精简档下 `_hasBody == false`
  /// ⇒ **连箭头都不画、点了没反应** ⇒ 用户以为"工具不可查看细节"。
  ///
  /// 现在的语义：
  /// · **精简档** ⇒ 默认**折叠**成一行（清单紧凑），**但可以点开看明细**
  /// · 其余档位 ⇒ 默认展开（信息本来就该看到）
  ///
  /// 为什么用 `late` 而不是在 `build` 里改状态：`build` 里改 state 会触发布局期
  /// setState（Flutter 会警告）。初始化只发生一次，正是我们要的"默认值"。
  late bool _expanded = widget.stepDetail.showArgs;

  /// **改动详情**是否展开（2026-10-21，BUG-4）。
  ///
  /// 独立于 [_expanded]：卡片整体展开 ≠ 要看 diff。
  /// diff 可能几十行，默认收起才不会把一屏塞满 ——
  /// 但**入口必须永远看得见**（"点击查看改动" + `+N −M`）。
  bool _diffExpanded = false;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final detail = widget.stepDetail;
    final call = widget.call;

    final (color, icon) = switch (call.status) {
      ToolStatus.running => (HColors.infoOn(h.dark), AppIcons.refresh),
      ToolStatus.success => (HColors.successOn(h.dark), AppIcons.check),
      ToolStatus.failure => (HColors.errorOn(h.dark), AppIcons.close),
    };
    // 状态词已并入标题（`正在读取…` / `读取了…` / `…（失败）`）——
    // 参考界面就不单独摆一个"成功"字样，靠动词时态与图标颜色表达。

    // 精简档**没有可展开的内容** —— 此时连箭头都不该画，
    // 否则用户点了没反应，会以为界面卡了。
    final hasBody = _hasBody(detail);

    // ★ 2026-10-22：从「卡片」改成「日志行」（真机截图 + 用户明确要求）
    //
    // 用户原话：「我不要调用工具是一个卡片的形式……然后可以点击展开成图二」。
    // 旧样子是一个**带边框+底色的圆角卡片**，占一屏好几张卡；
    // 现在：
    // · **折叠态**：无边框、无底色 —— 就是一行紧凑日志（左侧箭头是"可点开"的线索）
    // · **展开态**：才给一点底色把人车入库，看得清"这块属于这次调用"
    //
    // 热区仍 ≥ [kMinTapTarget]（docs/25 §7 第 3 条）—— 用户点的是**整行**。
    // ★ 失败的调用不显示 diff 统计：失败 = 什么都没改成，按参数估算出的
    //   +/- 是假数字（实测-14 §4 瑕疵 1：edit 失败的卡显示 +2/+1/−1）。
    final diffStat =
        isFileWritingTool(call.tool) && call.status != ToolStatus.failure
            ? _stat(call)
            : null;

    return Container(
      margin: const EdgeInsets.only(bottom: HSpace.xs),
      decoration: _expanded && hasBody
          ? BoxDecoration(
              color: h.surfaceAlt,
              borderRadius: BorderRadius.circular(HRadius.sm),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- 头部：折叠箭头 + 状态图标 + 工具名 + 状态词 + 元信息 ----
          InkWell(
            onTap: hasBody ? () => setState(() => _expanded = !_expanded) : null,
            borderRadius: BorderRadius.circular(HRadius.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kMinTapTarget),
              child: Padding(
                // ★ 步骤行几何**只从 `kStepRow*` 取**（2026-10-23）：
                //   「分析请求」行（`stream_step.dart`）渲染同一个常量集，
                //   两行才能逐像素对齐（用户报「没和其他工具调用对齐」）。
                padding: const EdgeInsets.symmetric(
                  horizontal: kStepRowHPad,
                  vertical: kStepRowVPad,
                ),
                child: Row(
                  children: [
                    // （展开箭头已退役，见 kStepRowArrowSize 注释：
                    // 状态图标直接顶到左列，全行左对齐）
                    Icon(icon, size: kStepRowStatusSize, color: color),
                    const SizedBox(width: kStepRowStatusGap),
                    Flexible(
                      child: Text(
                        // ★ 2026-10-22：`动词 + 目标`（对齐参考界面）
                        //   `读取 app/lib/services/local_agent.dart`
                        //   `执行了命令 echo hi > c.txt`
                        //   失败时末尾带「（失败）」—— 不再单列一个"成功"字样占宽。
                        toolCallLabel(
                          call.tool,
                          call.args,
                          running: call.status == ToolStatus.running,
                          failed: call.status == ToolStatus.failure,
                        ),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          // ★ 2026-10-22：工具行字号**小于正文**（12 vs 15），
                          //   让"模型说的话"与"工具日志"一眼分开。
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: call.status == ToolStatus.failure
                              ? HColors.errorOn(h.dark)
                              : h.text,
                        ),
                      ),
                    ),
                    // 参数数量退成弱提示（目标已经写进标题了，这里只是"还有几个参数"）
                    if (call.args.length > 1) ...[
                      const SizedBox(width: HSpace.xs),
                      Text(
                        '+${call.args.length - 1}',
                        style: TextStyle(fontSize: 10, color: h.textFaint),
                      ),
                    ],
                    // 改动统计：`+N −M` 折叠态也看得见（BUG-4 的"入口永远可见"）
                    if (diffStat != null && diffStat.isDiff) ...[
                      const SizedBox(width: HSpace.xs),
                      Text(
                        '+${diffStat.added}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: HColors.successOn(h.dark),
                        ),
                      ),
                      Text(
                        ' −${diffStat.removed}',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: HColors.errorOn(h.dark),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          if (hasBody && _expanded) ...[
            Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(HSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ---- 文件改动详情（2026-10-21，BUG-4）----
                  //
                  // 放在参数**之前**：用户最想看的是"改了什么代码"，
                  // 而不是"调用时传了哪几个参数名"。
                  if (isFileWritingTool(call.tool)) _diffSection(h, call),

                  // ---- 参数 ----
                  if (detail.showArgs)
                    ...call.args.entries.map(
                      (e) => Padding(
                        padding: const EdgeInsets.only(bottom: HSpace.xs),
                        child: _kv(
                          h,
                          e.key,
                          _clip(e.value, detail),
                          // 被截断时给个视觉提示，否则用户以为文件就这么短
                          truncated: _isTruncated(e.value, detail),
                        ),
                      ),
                    ),

                  // ---- 结果 ----
                  if (call.result != null) ...[
                    const SizedBox(height: HSpace.sm),
                    Row(
                      children: [
                        Text(
                          '结果',
                          style: TextStyle(
                            fontSize: 11,
                            color: h.textFaint,
                            letterSpacing: 0.4,
                          ),
                        ),
                        if (_isTruncated(call.result!, detail)) ...[
                          const SizedBox(width: HSpace.xs),
                          Text(
                            '（已截断，共 ${call.result!.length} 字符）',
                            style: TextStyle(fontSize: 10, color: h.textFaint),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: HSpace.xs),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(HSpace.sm),
                      decoration: BoxDecoration(
                        color: h.bg,
                        borderRadius: BorderRadius.circular(HRadius.sm),
                      ),
                      child: Text(
                        _clip(call.result!, detail),
                        style: TextStyle(
                          fontFamily: kMonoFontFamily,
                          fontFamilyFallback: kMonoFallback,
                          fontSize: 12,
                          height: 1.5,
                          color: call.status == ToolStatus.failure
                              ? HColors.errorOn(h.dark)
                              : h.textDim,
                        ),
                      ),
                    ),
                  ],

                  // ---- 模型原始输出（仅「完全展开」）----
                  if (detail.showRawOutput) _rawOutput(h, call.rawOutput),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 当前档位下这张卡片是否有可展开的内容。
  ///
  /// **必须与 build 里实际渲染的东西一致** —— 否则会出现"有箭头但展开是空的"。
  bool _hasBody(StepDetail detail) {
    // ★ 2026-10-22：不再因为"精简档"就整条不可展开。
    //
    // 旧实现第一行是 `if (!detail.showArgs) return false;` —— 精简档下
    // 连箭头都不画。用户真机截图正是精简档，于是**以为工具调用查不了细节**。
    // 现在的分工：
    // · `showArgs` 只决定**默认是否展开**（见 `_expanded` 的 late 初始化）
    // · "能不能展开" 只看**有没有东西可展开**
    return widget.call.args.isNotEmpty ||
        widget.call.result != null ||
        (detail.showRawOutput && widget.call.rawOutput != null) ||
        (isFileWritingTool(widget.call.tool) && _diffText(widget.call).isNotEmpty);
  }

  // ============================================================
  // ★★ 文件改动详情（2026-10-21，BUG-4）★★
  //
  // ## 用户报的症状
  //
  // > 「调用工具不透明，看不到改了什么代码」
  //
  // ## 根因（两端各一半）
  //
  // · **Kotlin 侧没问题**：`DiffReceipt.render(...)` 已经把 diff 放进工具结果
  //   （`FileTools.DiffReceipt` → `@@ 第 N 行 @@` / `- 旧行` / `+ 新行`）。
  // · **UI 侧把它截没了**：标准档用 `StepDetail.summaryChars`（80）截结果，
  //   一整段 diff 到用户眼前只剩一行 `@@ 第 3 行 @@…`。
  //
  // ## 修法边界（**不许**动 summaryChars）
  //
  // `summaryChars` 是**全局设置**，改它会波及所有卡片（包括非写类）。
  // 所以这里只给写类工具开一个**自己的**入口：
  //   · 默认**折叠**（diff 几十行，全展开会淹掉回答）
  //   · 折叠态就显示 `+N −M` 统计与「点击查看改动」——**入口永远可见**
  //   · 展开后渲染**完整** diff（不受档位截断） + 等宽字体 + 行级配色
  // ============================================================

  /// 这次的统计：优先用**工具结果**里的真 diff（权威），
  /// 拿不到才用参数估算（流式阶段 / 结果还没到）。
  DiffStat _stat(HToolCall call) {
    final fromResult = diffStatOf(call.result);
    if (fromResult.isDiff) return fromResult;
    return estimatedDiffStatOf(call.args);
  }

  /// 展开后要显示的**完整**改动文本。
  ///
  /// 优先用结果的 diff（Kotlin 算好的、与实际写入一致）；
  /// 没有就退回参数里的 `patch` / `new_string` / `content`。
  String _diffText(HToolCall call) {
    final r = call.result;
    if (r != null && diffStatOf(r).isDiff) return r;
    final args = call.args;
    for (final key in const ['patch', 'diff', 'new_string', 'content']) {
      final v = args[key];
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  Widget _diffSection(Hue h, HToolCall call) {
    // 失败 ⇒ 整个 diff 区块不渲染（连参数原文也不当 diff 展示）
    if (call.status == ToolStatus.failure) return const SizedBox.shrink();
    final stat = _stat(call);
    final text = _diffText(call);
    final files = changedFilesOf(call.args);
    // 没有任何改动线索 ⇒ 不摆一个空区块。
    //
    // 判据是**有没有可看的正文**（text），而不是"参数里有没有 path"：
    // 只有 path 的调用（被拦截 / 还没开始）没有任何"改了什么"可展示，
    // 这时给一个「点击查看改动」是**假入口** —— 点开是空的，比不显示更糟。
    if (text.isEmpty) {
      return const SizedBox.shrink();
    }

    final addedColor = HColors.successOn(h.dark);
    final removedColor = HColors.errorOn(h.dark);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 折叠头：文件名 + `+N −M` + 「点击查看改动」----
        //
        // 热区 ≥44px（与卡片头部同一纪律：移动端触控目标）
        InkWell(
          onTap: () => setState(() => _diffExpanded = !_diffExpanded),
          borderRadius: BorderRadius.circular(HRadius.sm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinTapTarget),
            child: Row(
              children: [
                Icon(AppIcons.file, size: 14, color: h.textFaint),
                const SizedBox(width: HSpace.xs + 1),
                Flexible(
                  child: Text(
                    files.isEmpty ? '文件改动' : files.join('、'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: kMonoFontFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 11.5,
                      color: h.textDim,
                    ),
                  ),
                ),
                const SizedBox(width: HSpace.sm),
                // ---- `+N −M` 统计（等宽，绿/红）----
                if (stat.hasChanges) ...[
                  Text(
                    '+${stat.added}',
                    style: TextStyle(
                      fontFamily: kMonoFontFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: addedColor,
                    ),
                  ),
                  const SizedBox(width: HSpace.xs),
                  Text(
                    '−${stat.removed}',
                    style: TextStyle(
                      fontFamily: kMonoFontFamily,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: removedColor,
                    ),
                  ),
                  const SizedBox(width: HSpace.sm),
                ],
                // ---- 入口提示（用户要的就是"知道哪能点"）----
                Text(
                  _diffExpanded ? '收起' : '点击查看改动',
                  style: TextStyle(fontSize: 10.5, color: h.textFaint),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),

        // ---- 展开后的完整 diff ----
        if (_diffExpanded && text.isNotEmpty) ...[
          const SizedBox(height: HSpace.xs),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(HSpace.sm),
            decoration: BoxDecoration(
              color: h.bg,
              borderRadius: BorderRadius.circular(HRadius.sm),
              border: Border.all(color: h.border),
            ),
            // 完整 diff 可能很长 —— 内部滚动 + 限高，避免把整页撑爆
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in const LineSplitter().convert(text))
                      Text(
                        line.isEmpty ? ' ' : line,
                        style: TextStyle(
                          fontFamily: kMonoFontFamily,
                          fontFamilyFallback: kMonoFallback,
                          fontSize: 11.5,
                          height: 1.45,
                          // 行级配色：`+` 绿、`-` 红、`@@` 淡、上下文默认
                          color: line.startsWith('+') && !line.startsWith('+++')
                              ? addedColor
                              : line.startsWith('-') && !line.startsWith('---')
                                  ? removedColor
                                  : line.startsWith('@@')
                                      ? h.textFaint
                                      : h.textDim,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: HSpace.sm),
      ],
    );
  }

  /// 按档位截断。
  ///
  /// 精简档走不到这里（不显示参数/结果）；标准档截断；详细与完全展开不截断。
  String _clip(String v, StepDetail detail) {
    if (detail.fullResult) return v;
    final limit = StepDetail.summaryChars;
    if (v.length <= limit) return v;
    return '${v.substring(0, limit)}…';
  }

  bool _isTruncated(String v, StepDetail detail) =>
      !detail.fullResult && v.length > StepDetail.summaryChars;

  /// 模型原始输出 —— 「完全展开」档位的增量。
  ///
  /// 拿不到就**不显示**（兜底路径没有 raw），而不是显示"（无）"——
  /// 那会让用户以为模型这次没输出任何东西。
  Widget _rawOutput(Hue h, String? raw) {
    if (raw == null || raw.trim().isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: HSpace.sm),
        Row(
          children: [
            Icon(AppIcons.think, size: 13, color: h.textFaint),
            const SizedBox(width: HSpace.xs + 1),
            Text(
              '模型原始输出',
              style: TextStyle(
                fontSize: 11,
                color: h.textFaint,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: HSpace.xs),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(HSpace.sm),
          decoration: BoxDecoration(
            color: h.bg,
            borderRadius: BorderRadius.circular(HRadius.sm),
            border: Border.all(color: h.border),
          ),
          child: Text(
            raw,
            style: TextStyle(
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFallback,
              fontSize: 11.5,
              height: 1.5,
              color: h.textFaint,
            ),
          ),
        ),
      ],
    );
  }

  Widget _kv(Hue h, String k, String v, {bool truncated = false}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              k,
              style: TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12,
                color: h.textFaint,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12,
                height: 1.5,
                color: truncated ? h.textFaint : h.textDim,
              ),
            ),
          ),
        ],
      );
}

// ============================================================================
// 共享：轻量 Markdown 渲染（最终回答 / 步骤正文汇报共用）
// ============================================================================

/// **轻量 Markdown 渲染**（2026-10-13 落地；2026-10-23 从 `message_row.dart`
/// 迁到本文件，供**最终回答**与**步骤正文汇报**共用 —— 用户报
/// 「正文汇报不渲染 md」）。
///
/// ## 为什么放在 `tool_call_card.dart`（而不是留在 `message_row.dart`）
///
/// 用户要求正文汇报复用这套渲染器。但 `message_row.dart` **已经**
/// `import 'stream_step.dart'`（要渲染 `StreamStepView`）—— 若把本类留在
/// `message_row.dart`、再让 `stream_step.dart` 反向 import 它，两个文件就成了
/// **循环依赖**。而这两个文件**都已经** import 本文件 ⇒ 把共享件放在这里，
/// import 图仍是 DAG（单向，无环）：
///
/// ```text
/// message_row ──┬──> tool_call_card  （本文件：MarkdownLite + 步骤行几何）
/// stream_step ──┘
/// ```
///
/// 本文件本来就是跨组件共享的低层件（`toolCallLabel` / `friendlyToolName` /
/// `diffStatOf` / `changedFilesOf` 都被别的组件用着），共享渲染器放这里不新增
/// 任何 import 边。
///
/// ## 覆盖的语法（回答里实际出现的）
///
/// | 语法 | 渲染 |
/// |---|---|
/// | `## 标题` / `### 标题` | 加粗、比正文大一号 |
/// | `**粗体**` | 粗体 span |
/// | `` `code` `` | 等宽字体 span（强调色） |
/// | `- 列表` / `* 列表` | 保留 `·` 前缀的列表行 |
/// | 围栏代码块 | 等宽 + 底色 + 横向滚动 |
/// | GFM 表格（表头 + `\|---\|`） | 真 `Table`（按比例分配列宽） |
/// | `---` / `> 引用` | 分隔线 / 左侧竖线引用 |
///
/// ## 字号：各级一律由 [fontSize] 派生（2026-10-23）
///
/// 2026-10-23 曾按「总结字体还是小」把最终回答基准抬到 16，与步骤正文的
/// 15 分成两层；**2026-10-25 晚用户纠正：字号必须统一**（同一段对话里
/// 一会儿大一会儿小是硬伤，层级靠字重/颜色，不靠字号）⇒ 基准统一 **15**，
/// 与 HTxt.body、步骤正文汇报、用户消息完全一致。但只改基准不够：
/// 标题原来写死 15.5/16.5/17.5，基准调到 16 之后 `###`（15.5）反而**比正文小**。
/// 现在各级相对 [fontSize] 计算：
///
/// | 级 | 字号 |
/// |---|---|
/// | 正文 / 列表 / 引用 | `fontSize` |
/// | `###` / `##` / `#` | `+0.5` / `+1.5` / `+2.5` |
/// | 行内代码 | `-1.5` |
/// | 围栏代码块 | `-2.5` |
/// | 表格单元格 | `-3` |
///
/// 即：**段落级文本不会比正文小**；只有代码与表格（非段落，且窄屏上必须压缩
/// 密度）略小。
///
/// ## 设计取舍
///
/// · **不引依赖**（`AGENTS.md`：新依赖要 ADR —— 现有语法面窄，受控渲染器
///   覆盖即可；将来语法需求超出再走调研流程）
/// · 样式全部取自 [Hue] —— 深浅两色自动适配
/// · 行内**没有**标记时返回普通 `Text` 而不是 `RichText`：既是渲染捷径，
///   也保证 `find.text(...)` 这类测试查找器对无标记文本仍然有效
class MarkdownLite extends StatelessWidget {
  const MarkdownLite({
    super.key,
    required this.text,
    this.fontSize = 15,
    this.color,
  });

  final String text;

  /// 正文基准字号 —— 标题/列表/引用/代码/表格的字号都由它派生（见类注释）。
  ///
  /// · 最终回答与步骤正文汇报：统一 15（2026-10-25 晚用户定字号统一）
  final double fontSize;

  /// 正文墨色；`null` = 跟随主题（[Hue.text]）。错误态正文传错误色。
  final Color? color;

  /// 正文 / 标题 / 列表的墨色（[color] 优先）。
  Color _ink(Hue h) => color ?? h.text;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final lines = text.split('\n');
    final spans = <Widget>[];

    // ★ 2026-10-22：从"纯逐行"升级为**块级扫描**。
    //
    // 用户截图里模型输出了一张 Markdown 表格，界面把它**原样**画成
    // `| id | title | updatedAt |` —— 用户看到一堆竖线。旧实现是"一行一
    // Widget"，**结构上不可能**认出跨行的表格/代码块。现在识别：
    // 围栏代码块 / GFM 表格 / 分隔线 / 引用，其余交给逐行渲染。
    //
    // ⚠️ 表格必须有**分隔行**才认：否则 `a | b` 这种普通含竖线的句子会被
    //    误判成表格（宁可少认，不要错渲染）。
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final t = line.trimLeft();

      // ---- 围栏代码块 ----
      if (t.startsWith('```')) {
        final buf = StringBuffer();
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          if (buf.isNotEmpty) buf.write('\n');
          buf.write(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // 吃掉收尾的 ```
        spans.add(_codeBlock(h, buf.toString()));
        continue;
      }

      // ---- 表格（GFM：表头 + 分隔行 + 若干数据行）----
      if (t.startsWith('|') &&
          i + 1 < lines.length &&
          _isTableSeparator(lines[i + 1])) {
        final rows = <List<String>>[_splitRow(lines[i])];
        i += 2; // 跳过表头与分隔行
        while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
          rows.add(_splitRow(lines[i]));
          i++;
        }
        spans.add(_table(h, rows));
        continue;
      }

      // ---- 分隔线 ----
      if (t == '---' || t == '***' || t == '___') {
        spans.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: HSpace.sm),
          child: Divider(height: 1, color: h.border),
        ));
        i++;
        continue;
      }

      // ---- 引用 ----
      if (t.startsWith('> ')) {
        spans.add(_quote(h, t.substring(2)));
        i++;
        continue;
      }

      spans.add(_line(h, line));
      i++;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: spans,
    );
  }

  // ============================================================
  // 表格
  // ============================================================

  /// 是否是 `|---|:--:|---|` 这种分隔行（GFM 表格的判定锚点）。
  bool _isTableSeparator(String line) {
    final t = line.trim();
    if (!t.startsWith('|')) return false;
    final cells = _splitRow(t);
    if (cells.isEmpty) return false;
    return cells.every((c) => RegExp(r'^:?-{1,}:?$').hasMatch(c.trim()));
  }

  /// 把 `| a | b |` 拆成 `['a', 'b']`（去掉首尾空段）。
  List<String> _splitRow(String line) {
    var t = line.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    return t.split('|').map((e) => e.trim()).toList();
  }

  /// 渲染成真正的 `Table`（不是等宽文本对齐 —— 手机上长值必然错位）。
  ///
  /// 列宽用 [FlexColumnWidth]：撑满可用宽度、**按比例**分配，
  /// 单元格内文本自动换行。手机窄屏下 5 列表格会显得挤，
  /// 但这比"原样吐竖线"和"横向滚动的死宽表格"都更可读。
  Widget _table(Hue h, List<List<String>> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final header = rows.first;
    final body = rows.skip(1).toList();
    final cols = header.length;
    // 表格是"高密度信息"，比正文小 3 号（跟着基准字号一起缩放）
    final cellSize = fontSize - 3;

    TableRow buildRow(List<String> cells, {required bool head}) => TableRow(
          decoration: head ? BoxDecoration(color: h.surfaceAlt) : null,
          children: [
            for (var c = 0; c < cols; c++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                child: _rich(
                  h,
                  c < cells.length ? cells[c] : '',
                  size: cellSize,
                  bold: head,
                  lineHeight: 1.35,
                ),
              ),
          ],
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HSpace.sm),
      child: Table(
        border: TableBorder.all(color: h.border, width: 0.6),
        defaultColumnWidth: const FlexColumnWidth(),
        children: [
          buildRow(header, head: true),
          for (final r in body) buildRow(r, head: false),
        ],
      ),
    );
  }

  // ============================================================
  // 代码块 / 引用
  // ============================================================

  Widget _codeBlock(Hue h, String code) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: HSpace.xs),
      padding: const EdgeInsets.all(HSpace.sm),
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.sm),
        border: Border.all(color: h.border),
      ),
      // 代码不换行（换行会破坏缩进语义）⇒ 允许横向滚动
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          code,
          style: TextStyle(
            fontFamily: kMonoFontFamily,
            fontFamilyFallback: kMonoFallback,
            fontSize: fontSize - 2.5,
            height: 1.5,
            color: h.textDim,
          ),
        ),
      ),
    );
  }

  /// 引用（`> `）—— 左侧竖线 + 与正文同号字（只靠淡色与缩进降层级）。
  ///
  /// 字号**不再比正文小**：2026-10-23 之前是 14.5（正文 15），
  /// 基准提到 16 后若继续按老值走，引用会显得像"脚注"。
  Widget _quote(Hue h, String text) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: HSpace.xs),
      padding: const EdgeInsets.only(left: HSpace.sm),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: h.border, width: 3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          height: 1.6,
          color: h.textDim,
        ),
      ),
    );
  }

  // ============================================================
  // 逐行渲染（标题 / 列表 / 段落 / 空行）
  // ============================================================

  Widget _line(Hue h, String line) {
    final t = line.trimLeft();

    // ---- 标题 # / ## / ### ----
    // ★ 字号相对基准：### 必须**比正文大**（旧值写死 15.5，基准 16 时更小）
    if (t.startsWith('### ')) {
      return _heading(h, t.substring(4), fontSize + 0.5);
    }
    if (t.startsWith('## ')) {
      return _heading(h, t.substring(3), fontSize + 1.5);
    }
    if (t.startsWith('# ')) {
      return _heading(h, t.substring(2), fontSize + 2.5);
    }

    // ---- 无序列表 ----
    if (t.startsWith('- ') || t.startsWith('* ')) {
      return Padding(
        padding: const EdgeInsets.only(left: HSpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '·  ',
              style: TextStyle(
                fontSize: fontSize,
                height: 1.6,
                color: _ink(h),
              ),
            ),
            Expanded(child: _rich(h, t.substring(2))),
          ],
        ),
      );
    }

    // ---- 空行：保留间距（列表/段落分隔）----
    if (t.isEmpty) {
      return const SizedBox(height: HSpace.sm);
    }

    // ---- 普通段落 ----
    return _rich(h, line);
  }

  Widget _heading(Hue h, String text, double size) {
    return Padding(
      padding: const EdgeInsets.only(top: HSpace.xs),
      child: Text(
        text,
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w700,
          height: 1.5,
          color: _ink(h),
        ),
      ),
    );
  }

  /// 行内解析：`**粗体**` 与 `` `code` `` → 样式化 TextSpan。
  ///
  /// [size] 为 null 时用基准 [fontSize]（表格单元格会显式传更小的值）。
  Widget _rich(
    Hue h,
    String line, {
    double? size,
    bool bold = false,
    double lineHeight = 1.6,
  }) {
    final fs = size ?? fontSize;
    final base = TextStyle(
      fontSize: fs,
      height: lineHeight,
      color: _ink(h),
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );
    // ★ 无标记 ⇒ 普通 Text（渲染捷径 + 保住 find.text 类测试查找器）
    if (!line.contains('**') && !line.contains('`')) {
      return Text(line, style: base);
    }
    final spans = <TextSpan>[];
    var rest = line;
    while (rest.isNotEmpty) {
      // **粗体**
      final b = rest.indexOf('**');
      if (b >= 0) {
        final e = rest.indexOf('**', b + 2);
        if (e > b) {
          if (b > 0) spans.add(TextSpan(text: rest.substring(0, b), style: base));
          spans.add(TextSpan(
            text: rest.substring(b + 2, e),
            style: base.copyWith(fontWeight: FontWeight.w700),
          ));
          rest = rest.substring(e + 2);
          continue;
        }
      }
      // `code`
      final c = rest.indexOf('`');
      if (c >= 0) {
        final e = rest.indexOf('`', c + 1);
        if (e > c) {
          if (c > 0) spans.add(TextSpan(text: rest.substring(0, c), style: base));
          spans.add(TextSpan(
            text: rest.substring(c + 1, e),
            style: base.copyWith(
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFallback,
              fontSize: fs - 1.5,
              color: h.accent,
            ),
          ));
          rest = rest.substring(e + 1);
          continue;
        }
      }
      spans.add(TextSpan(text: rest, style: base));
      break;
    }
    return RichText(
      text: TextSpan(children: spans, style: base),
    );
  }
}
