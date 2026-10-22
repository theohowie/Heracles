import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';
import 'tool_call_card.dart' show kFileWritingTools, estimatedDiffStatOf, changedFilesOf;

/// **逐字生成中的一个步骤** —— 思考与正文分开渲染。
///
/// ## 用户要的是什么（原话，不要软化）
///
/// > "AI 接收到任务后会先开始**思考**怎么完成，AI 的思考过程也是展示出来，
/// >  **一个字一个字出来**，不是等 AI 想完了再全部展示出来"
///
/// ## ★ 展开与收起（2026-10-13，用户三连反馈后重设计）
///
/// 用户原话：
/// > 「不管用户选择的工作步骤展示是何种等级，都是可以选择展开收起
/// >   思考过程和执行过程」「用户选了精简那不就是默认收起吗」
/// > 「收起状态下，流式输出也不是没有。参考 deepseek harness 的思考
/// >   的流式输出，在一行里面流式输出」
///
/// 落地：
/// - **任何档位都可展开/收起**（档位决定**默认状态**：精简=收起，
///   其余=展开；用户点击后以用户为准）
/// - **收起时流式不丢**：标题行右侧显示**一行流动的增量预览**
///   （DeepSeek harness 风格 —— 单行、省略号截断、持续刷新），
///   用户不展开也能看见"在动"
/// - 展开后才显示完整思考 + 正文（多行）
class StreamStepView extends StatefulWidget {
  const StreamStepView({super.key, required this.step, this.detail});

  final HStepStream step;

  /// 工作步骤展示档位 —— 只决定**默认**展开状态（精简=收起），
  /// 不锁死用户的选择。null = 展开（无档位上下文时保守显示全部）。
  final StepDetail? detail;

  /// **流式中的文本是否已进入"工具调用"形态**（2026-10-13）。
  ///
  /// 公开 static 供测试直调。前缀匹配而非 JSON 解析（流式文本不完整）：
  /// 工具调用永远以 `{"tool"` 开头（契约），前缀一到即判定，
  /// 之后不管流出多少内容都不再上屏。宽松前缀：chunk 拆开 `{"tool`
  /// 也认得出 —— 宁可早一拍掩蔽，不可晚一拍滚屏。
  static bool isStreamingToolCallStatic(String text) {
    final t = text.trimLeft();
    const full = '{"tool"';
    if (t.length >= full.length) return t.startsWith(full);
    return full.startsWith(t) && t.length >= 2;
  }

  @override
  State<StreamStepView> createState() => _StreamStepViewState();
}

class _StreamStepViewState extends State<StreamStepView> {
  /// null = 用户没点过 → 跟随档位的默认；非 null = 用户的选择优先
  bool? _userExpanded;

  bool get _expanded {
    if (_userExpanded != null) return _userExpanded!;
    final d = widget.detail;
    if (d == null) return true;
    // ★ 档位决定默认：精简=收起（只看"干了什么"），
    //   其余档=展开（标准及以上本来就是"要看过程"的选择）
    return d != StepDetail.minimal;
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final step = widget.step;
    final accent = step.isError
        ? HColors.errorOn(h.dark)
        : (step.finished ? h.textFaint : HColors.infoOn(h.dark));

    // ★ 收起状态（2026-10-13）：只有标题行 + 一行流式预览。
    //   用户原话：「收起状态下，流式输出也不是没有」——
    //   增量到达时标题行下方那一行会持续刷新（DeepSeek harness 风格），
    //   用户不展开也能看见"在动、在出字"。
    //   预览内容 = 最新的增量（思考优先于正文 —— 思考先发生）。
    //   ★ 工具调用形态时预览也掩蔽（与正文区同一条纪律：
    //     几 KB 的文件内容不能滚进预览行）
    final streaming = !step.finished;
    final toolStreaming = StreamStepView.isStreamingToolCallStatic(step.text);
    final preview = streaming
        ? (step.reasoning.isNotEmpty
            ? _tail(step.reasoning)
            : (toolStreaming ? '正在修改文件代码…' : _tail(step.text)))
        : '';

    return Container(
      margin: const EdgeInsets.only(bottom: HSpace.md),
      padding: const EdgeInsets.only(left: HSpace.md),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: h.border, width: 2.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 标题行：状态点 + 标题 + 耗时 + 展开箭头 ----
          //   整行可点（展开/收起）—— 44px 热区由内容高度补足，
          //   但为保险用 InkWell 包住整行
          InkWell(
            onTap: () => setState(() => _userExpanded = !_expanded),
            child: _header(h, accent, preview),
          ),
          if (_expanded) ...[
            // ---- 思考过程（较淡）----
            //
            // reasoning 为空 = 本次没有思考流（`enable_thinking=false`）——
            // **不画空区块**，也不写"（无思考）"：那会让用户以为思考丢了。
            //
            // ★ 层级语义（2026-10-13，用户纠正）：
            //   思考过程 = 模型的分析（到"我会创建一个完整的…游戏。"为止）
            //   工具调用 = 独立条目（**不在思考区块里**）——
            //   用户原话：「首先，这个是工具的调用，不是思考过程」
            if (step.reasoning.isNotEmpty) ...[
              const SizedBox(height: HSpace.sm),
              _reasoning(h),
            ],
            // ---- 正文（思考的结论 = 给用户看的话）----
            //
            // ★ 流式中的工具调用 = **独立子条目**（不在思考区，也不再
            //   出现在正文位置）—— 用户原话：「接下来就是输出展示给
            //   用户看的思考的结论和下一步干的事……然后是一个
            //   '正在创建文件并修改文件'。这个也是可以点击展开的，
            //   看代码怎么写了，写了多少」。
            //
            // 结构：
            //   ┃ 思考过程（…分析…待办…）
            //   ┃ 正文："接下来创建文件"（剥壳后的人话）
            //   ┃   ⏳ 正在修改文件代码…   ← 独立子条目，可展开看内容
            if (step.bodyCollapsed) ...[
              const SizedBox(height: HSpace.sm),
              Text(
                '回答见下方',
                style:
                    TextStyle(fontSize: 12, height: 1.5, color: h.textFaint),
              ),
            ] else ...[
              // 正文：流式中若已进入工具调用形态，正文位置由
              // 下面的工具子条目接管（协议要求正文与工具二选一）
              if (step.text.isNotEmpty &&
                  !StreamStepView.isStreamingToolCallStatic(step.text) &&
                  !_isFinishedToolCall(step)) ...[
                const SizedBox(height: HSpace.sm),
                _body(h),
              ],
              // ---- 工具调用子条目（独立缩进层级，可展开看内容）----
              if (StreamStepView.isStreamingToolCallStatic(step.text) ||
                  _isFinishedToolCall(step)) ...[
                const SizedBox(height: HSpace.sm),
                _ToolSubEntry(text: step.text, finished: step.finished),
              ],
            ],
            // 结束了但两个通道都空 —— 如实说明，而不是留一块空白
            if (step.finished && !step.hasBody) ...[
              const SizedBox(height: HSpace.sm),
              Text(
                step.isEmpty ? '本轮没有生成内容' : '本轮未返回内容',
                style:
                    TextStyle(fontSize: 12.5, height: 1.5, color: h.textFaint),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// 已结束的步骤，其正文剥壳后是工具调用（无 final 内容）？
  static bool _isFinishedToolCall(HStepStream step) {
    if (!step.finished) return false;
    final t = step.text.trim();
    if (!t.startsWith('{') || !t.endsWith('}')) return false;
    try {
      final j = jsonDecode(t);
      return j is Map && j.containsKey('tool');
    } catch (_) {
      return false;
    }
  }

  /// 取文本的**末尾若干字符**做单行预览 —— 流式时新字不断从尾部出现，
  /// 预览跟着滚动（正是 DeepSeek harness 的"一行流动"观感）。
  static String _tail(String s, [int max = 60]) {
    final t = s.replaceAll('\n', ' ').trim();
    if (t.length <= max) return t;
    return '…${t.substring(t.length - max)}';
  }

  /// 标题行：状态点 + 标题 + 耗时 + （收起时的单行流式预览）+ 展开箭头
  Widget _header(Hue h, Color accent, String preview) {
    final step = widget.step;
    return Row(
      children: [
        if (!step.finished)
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: accent),
          )
        else
          Icon(
            step.isError ? Icons.error_outline_rounded : Icons.check_rounded,
            size: 13,
            color: accent,
          ),
        const SizedBox(width: HSpace.sm),
        Flexible(
          child: Text(
            step.title.isEmpty ? '正在生成…' : step.title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: h.textDim,
              letterSpacing: 0.2,
            ),
          ),
        ),
        const SizedBox(width: HSpace.sm),
        if (step.durationMs != null && step.durationMs! > 0) ...[
          Text(
            '${step.durationMs}ms',
            style: TextStyle(
              fontFamily: kMonoFontFamily,
              fontFamilyFallback: kMonoFallback,
              fontSize: 10,
              color: h.textFaint,
            ),
          ),
          const SizedBox(width: HSpace.sm),
        ],
        // ---- ★ 收起时的单行流式预览（DeepSeek harness 风格）----
        //   Expanded 吃掉剩余宽度：预览长就往左截（tail），新字持续出现
        if (!_expanded && preview.isNotEmpty)
          Expanded(
            child: Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: h.textFaint,
              ),
            ),
          )
        else
          const Spacer(),
        // ---- 展开/收起箭头（所有档位都有 —— 用户原话："不管何种等级"）----
        Icon(
          _expanded
              ? Icons.keyboard_arrow_up_rounded
              : Icons.keyboard_arrow_down_rounded,
          size: 16,
          color: h.textFaint,
        ),
      ],
    );
  }

  /// **思考过程** —— 淡色 + 缩进 + 斜体。
  ///
  /// ⚠️ 不做 Markdown：思考内容里常出现 `*`、`#`、`` ` ``，
  /// 逐字过程中把它们渲染成格式会让文字**跳来跳去**。
  Widget _reasoning(Hue h) {
    return Padding(
      padding: const EdgeInsets.only(left: HSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.psychology_outlined, size: 12, color: h.textFaint),
              const SizedBox(width: HSpace.xs + 1),
              Text(
                '思考过程',
                style: TextStyle(
                  fontSize: 10.5,
                  color: h.textFaint,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: HSpace.xs),
          Text(
            widget.step.reasoning,
            // **只做轻量装饰，不做 Markdown**：思考是过程，不是成品
            style: TextStyle(
              fontSize: 12.5,
              height: 1.55,
              fontStyle: FontStyle.italic,
              color: h.textDim,
            ),
          ),
        ],
      ),
    );
  }

  /// **正文** —— 正常样式；运行中纯文本，结束后才格式化。
  Widget _body(Hue h) {
    final text =
        widget.step.finished ? _format(widget.step.text) : widget.step.text;
    return Text(
      text,
      style: TextStyle(
        fontSize: 14.5,
        height: 1.6,
        color: widget.step.isError ? HColors.errorOn(h.dark) : h.text,
      ),
    );
  }

  /// `step_ended` 之后的**轻量格式化**（只认换行与缩进）。
  ///
  /// ## 为什么不是完整 Markdown
  ///
  /// 一期刻意不引入 `flutter_markdown`：它是新依赖，
  /// 按 `AGENTS.md` 必须先进 `11-复用调研.md` 并写 ADR（另有任务在做）。
  /// 而这里要解决的核心问题很小 —— **逐字过程的重解析**，
  /// 用现有的纯文本渲染已经解决。所以本函数只做两件无风险的事：
  /// 把字面量 `\n` 还原成换行、把制表符换成两个空格。
  ///
  /// ⚠️ **不要**在这里加 Markdown 解析：那需要新依赖 + ADR，
  /// 而且会在没有视觉回归测试的情况下改动既有渲染。
  static String _format(String raw) =>
      raw.replaceAll(r'\n', '\n').replaceAll('\t', '  ');
}


/// **工具调用的子条目**（2026-10-13，用户纠正层级语义）。
///
/// ## 用户的结构要求（原话）
///
/// 「接下来就是输出展示给用户看的思考的结论和下一步干的事。
///   然后是一个'正在创建文件并修改文件'。
///   这个也是可以点击展开的，**看代码怎么写了，写了多少**」
///
/// 即：工具调用**不是思考过程的一部分**，是独立条目：
///
/// ```text
/// ┃ ↻ 正在生成
/// ┃   💭 思考过程（分析 + 待办）
/// ┃   正文："接下来创建文件"
/// ┃     ⏳ 正在修改文件代码…          ← 本组件（流式中）
/// ┃        （展开后：写入的文件内容预览/字数）
/// ```
///
/// ## 展开后显示什么
///
/// · 流式中：已写入的字符数（"已生成 N 字符"）—— 内容未完成，
///   展示半截 JSON 没有意义
/// · 已结束：解析 `{"tool":…}`，显示工具名 + 目标文件 + 内容字数；
///   内容本体不渲染（文件在工作区里，要看去工作区看 ——
///   与 DeepSeek harness 的"编辑 · xxx.dart +123 -56"同哲学：
///   步骤条给摘要，产物在文件树）
class _ToolSubEntry extends StatefulWidget {
  const _ToolSubEntry({required this.text, required this.finished});

  /// 步骤正文（原始流：流式中是不完整 JSON，结束后是完整协议）
  final String text;

  final bool finished;

  @override
  State<_ToolSubEntry> createState() => _ToolSubEntryState();
}

class _ToolSubEntryState extends State<_ToolSubEntry> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final meta = _meta();
    final change = _fileChange();
    return Padding(
      padding: const EdgeInsets.only(left: HSpace.md),
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: h.border, width: 2)),
        ),
        padding: const EdgeInsets.only(left: HSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  if (!widget.finished)
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.4, color: h.textFaint),
                    )
                  else
                    Icon(Icons.edit_note_rounded,
                        size: 13, color: h.textFaint),
                  const SizedBox(width: HSpace.sm),
                  Flexible(
                    child: Text(
                      meta.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: h.textDim),
                    ),
                  ),
                  // ★★ 文件改动摘要行（2026-10-21，BUG-4）★★
                  //
                  // 用户报的：「调用工具不透明，看不到改了什么代码」。
                  // 原来这一步只显示「已写入 a.txt」，**没有 +N −M** ——
                  // 用户无法一眼判断"这一改有多大"，必须点开卡片才知道。
                  // 这里在**标题行**就把「改了哪个文件、+N −M」摆出来，
                  // 与 DeepSeek harness / GitHub 的「编辑 · x.dart +12 −3」同一语义。
                  if (change != null) ...[
                    const SizedBox(width: HSpace.sm),
                    Text(
                      change.label,
                      style: TextStyle(
                        fontFamily: kMonoFontFamily,
                        fontFamilyFallback: kMonoFallback,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: HColors.successOn(h.dark),
                      ),
                    ),
                    const SizedBox(width: HSpace.xs),
                    Text(
                      change.removedLabel,
                      style: TextStyle(
                        fontFamily: kMonoFontFamily,
                        fontFamilyFallback: kMonoFallback,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: HColors.errorOn(h.dark),
                      ),
                    ),
                  ],
                  const SizedBox(width: HSpace.sm),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 15,
                    color: h.textFaint,
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: HSpace.xs),
              Text(
                meta.detail,
                style: TextStyle(
                    fontSize: 12, height: 1.5, fontFamily: kMonoFontFamily,
                    fontFamilyFallback: kMonoFallback,
                    color: h.textFaint),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// **文件改动摘要** —— 只对写类工具给值，其余返回 null（不摆空的东西）。
  ///
  /// 数据来源分两态（与 `tool_call_card.dart` 的 `diffStatOf` /
  /// `estimatedDiffStatOf` 同一套语义，但这里流式阶段只有**参数**可用，
  /// 没有工具结果）：
  ///
  /// · 流式中：参数还不完整（JSON 半截）⇒ 只报"已生成 N 字符"
  /// · 已结束：从完整参数里按 `patch` / `new_string` / `content` 估算
  ///
  /// ⚠️ 这是**估算**（流式阶段拿不到原文件，算不出真实删除量）。
  /// 真实数字以工具卡片（`ToolCallCard`）里从**结果**解析出的 `+N −M` 为准。
  ({String label, String removedLabel})? _fileChange() {
    if (!widget.finished) return null;
    final t = widget.text.trim();
    if (!t.startsWith('{')) return null;
    try {
      final j = jsonDecode(t);
      if (j is! Map || j['tool'] is! String) return null;
      final tool = j['tool'] as String;
      if (!kFileWritingTools.contains(tool)) return null;
      final rawArgs = j['args'];
      if (rawArgs is! Map) return null;
      final args = <String, String>{
        for (final e in rawArgs.entries)
          if (e.value is String) e.key as String: e.value as String,
      };
      final stat = estimatedDiffStatOf(args);
      if (!stat.hasChanges) return null;
      final files = changedFilesOf(args);
      // label 只放 `+N`，removedLabel 放 `−M` —— 两个 Text 颜色不同（绿/红）
      return (
        label: files.isEmpty ? '+${stat.added}' : '${files.first} +${stat.added}',
        removedLabel: '−${stat.removed}',
      );
    } catch (_) {
      return null;
    }
  }

  /// 从（可能不完整的）流式文本提取工具名 / 文件 / 字数。
  ({String label, String detail}) _meta() {
    final t = widget.text.trim();
    if (!widget.finished) {
      // 流式中：内容还在涨，只报字符数
      return (
        label: '正在修改文件代码…',
        detail: t.isEmpty ? '…' : '已生成 ${t.length} 字符（仍在写入）',
      );
    }
    // 已结束：解析完整 JSON
    try {
      final j = jsonDecode(t);
      if (j is Map && j['tool'] is String) {
        final tool = j['tool'] as String;
        final args = j['args'];
        String target = '';
        int contentLen = 0;
        if (args is Map) {
          target = (args['path'] as String?) ?? '';
          final c = args['content'];
          contentLen = c is String ? c.length : 0;
        }
        final detail = target.isEmpty
            ? '工具：$tool'
            : '工具：$tool → $target${contentLen > 0 ? '（$contentLen 字符）' : ''}';
        return (
          label: tool == 'write_file'
              ? (target.isEmpty ? '已写入文件' : '已写入 $target')
              : '已执行 $tool',
          detail: detail,
        );
      }
    } catch (_) {
      // 半截 JSON（工具调到一半被停止）—— 如实说明
      return (
        label: '已中断的工具调用',
        detail: '已生成 ${t.length} 字符（未完成）',
      );
    }
    return (label: '工具调用', detail: t);
  }
}