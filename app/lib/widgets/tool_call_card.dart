import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';

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
String friendlyToolName(String tool) => switch (tool) {
      'write_file' => '修改文件代码',
      'read_file' => '读取文件',
      'list_files' => '查看目录文件',
      // ★ 2026-10-19：补齐真实工具面（此前一大半露出 schema 名，用户看到的是
      //   `update_plan` / `run_shell_command` / `apply_patch` —— 那是给模型看的）
      'update_plan' => '更新任务计划',
      'apply_patch' => '局部修改代码',
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
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final detail = widget.stepDetail;
    final call = widget.call;

    final (color, icon) = switch (call.status) {
      ToolStatus.running => (HColors.infoOn(h.dark), Icons.autorenew_rounded),
      ToolStatus.success => (HColors.successOn(h.dark), Icons.check_rounded),
      ToolStatus.failure => (HColors.errorOn(h.dark), Icons.close_rounded),
    };
    final statusLabel = switch (call.status) {
      ToolStatus.running => '执行中',
      ToolStatus.success => '成功',
      ToolStatus.failure => '失败',
    };

    // 精简档**没有可展开的内容** —— 此时连箭头都不该画，
    // 否则用户点了没反应，会以为界面卡了。
    final hasBody = _hasBody(detail);

    return Container(
      margin: const EdgeInsets.only(bottom: HSpace.md),
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.md),
        border: Border.all(color: h.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- 头部：状态图标 + 工具名 + 状态词 + 折叠箭头 ----
          //
          // ★ 折叠热区 **≥44px**（`docs/25` §7 第 3 条：移动端触控目标）。
          //
          // 原来的内边距是 `vertical: 8+2=10`，行高约 20 —— 总高仅约 40px，
          // 比 Android 的 48dp 触控建议还小。这里用 `ConstrainedBox`
          // **把整条头部撑到 44**，而不是只把图标做大：用户点的是"整行"，
          // 热区必须跟着整行走（只放大箭头会让"看着能点"的地方点不到）。
          InkWell(
            onTap: hasBody ? () => setState(() => _expanded = !_expanded) : null,
            borderRadius: BorderRadius.circular(HRadius.md),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kMinTapTarget),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HSpace.md,
                  vertical: HSpace.sm + 2,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 15, color: color),
                    const SizedBox(width: HSpace.sm),
                    Flexible(
                      child: Text(
                        // ★ 人话标题（2026-10-13 用户要求）：
                        //   运行中 → 「正在修改文件代码」
                        //   已结束 → 「修改文件代码」
                        //   未登记的工具名 → 原样回显（不编中文）
                        call.status == ToolStatus.running
                            ? runningToolName(call.tool)
                            : friendlyToolName(call.tool),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: h.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: HSpace.sm),
                    // 状态词 —— 精简档只有"工具名 + 状态"，
                    // 所以状态必须**看得见**，不能只靠一个小图标的颜色
                    Text(
                      statusLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: color,
                        letterSpacing: 0.3,
                      ),
                    ),
                    // 参数数量在精简档也有用（一眼看出"这一步有多重"），
                    // 但不展开具体值
                    if (detail.statusOnly && call.args.isNotEmpty) ...[
                      const SizedBox(width: HSpace.xs),
                      Text(
                        '· ${call.args.length} 个参数',
                        style: TextStyle(fontSize: 10.5, color: h.textFaint),
                      ),
                    ],
                    const Spacer(),
                    if (hasBody)
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: h.textFaint,
                      ),
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
    if (!detail.showArgs) return false;
    return widget.call.args.isNotEmpty || widget.call.result != null;
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
            Icon(Icons.psychology_outlined, size: 12, color: h.textFaint),
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
