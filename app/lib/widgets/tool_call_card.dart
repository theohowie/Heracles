import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

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
/// 参考界面里工具行长这样：
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
  final (run, done) = switch (tool) {
    'read_file' => ('正在读取', '读取了'),
    'list_files' => ('正在查看目录', '查看了目录'),
    'find_files' => ('正在查找', '查找了'),
    'grep_files' => ('正在搜索', '搜索了'),
    'write_file' => ('正在写入', '写入了'),
    'edit' => ('正在编辑', '编辑了'),
    'apply_patch' => ('正在按补丁修改', '按补丁修改了'),
    'mkdir' => ('正在创建目录', '创建了目录'),
    'delete_path' => ('正在删除', '删除了'),
    'move_path' => ('正在移动', '移动了'),
    'copy_path' => ('正在复制', '复制了'),
    'run_shell_command' => ('正在执行命令', '执行了命令'),
    'web_fetch' => ('正在抓取网页', '抓取了网页'),
    'check_device_state' => ('正在读取设备状态', '读取了设备状态'),
    'write_todos' => ('正在更新待办', '更新了待办'),
    'ask_user' => ('正在向你提问', '向你提了问'),
    'save_memory' => ('正在记录', '记录了'),
    'build_apk' => ('正在构建 APK', '构建了 APK'),
    'apk_decompile' => ('正在反编译', '反编译了'),
    _ => ('正在调用 $tool', '调用了 $tool'),
  };
  final verb = running ? run : done;

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
    final diffStat = isFileWritingTool(call.tool) ? _stat(call) : null;

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
                padding: const EdgeInsets.symmetric(
                  horizontal: HSpace.sm,
                  vertical: HSpace.xs,
                ),
                child: Row(
                  children: [
                    // ★ 左侧箭头（用户要的那个"能展开"的样子）
                    //
                    // 没有可展开内容时**仍然占位** —— 否则同一列的对齐会跳，
                    // 一屏工具行左右参差，看着像渲染错。
                    if (hasBody)
                      Icon(
                        _expanded
                            ? AppIcons.chevronDown
                            : AppIcons.chevronRight,
                        size: 18,
                        color: h.textFaint,
                      )
                    else
                      const SizedBox(width: 18),
                    const SizedBox(width: HSpace.xs),
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 6),
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
                Icon(
                  _diffExpanded
                      ? AppIcons.chevronUp
                      : AppIcons.chevronDown,
                  size: 17,
                  color: h.textFaint,
                ),
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
