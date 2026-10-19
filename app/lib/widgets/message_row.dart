import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../models/message.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';
import 'stream_step.dart';
import 'tool_call_card.dart';

/// 消息行 —— 按类型分派到不同渲染。
class MessageRow extends StatelessWidget {
  const MessageRow({
    super.key,
    required this.message,
    this.metrics,
    this.stepDetail = StepDetail.standard,
    this.timestamp,
    this.feedback,
    this.onFeedback,
    this.onBranch,
    this.onEdit,
  });

  final HMessage message;

  /// 该轮的缓存指标（仅助手消息显示）
  final TurnMetrics? metrics;

  /// 工作步骤展示档位 —— 决定工具卡片与原始输出的显示密度
  final StepDetail stepDetail;

  /// 这条回答的时间（2026-10-13，操作行右侧显示）
  final DateTime? timestamp;

  /// 用户对这条回答的反馈：null = 没投过
  final AnswerFeedback? feedback;

  /// 用户点了赞/踩
  final ValueChanged<AnswerFeedback>? onFeedback;

  /// 用户点了「新会话分支」—— 以这条回答为起点开一个新会话
  final VoidCallback? onBranch;

  /// 用户点了「编辑重发」—— 把这条**用户消息**的文本放进输入框
  /// （2026-10-13，参考 DeepSeek 移动端：长按消息 → 编辑）
  final ValueChanged<String>? onEdit;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    // ⚠️ 这是对 sealed class 的**穷尽 switch** ——
    //    给 HMessage 新增子类时**必须**在这里补分支，否则编译不过。
    //    这是刻意的：新消息类型不可能被静默漏渲染。
    return switch (message) {
      // ★ 传 build context 给长按菜单（StatelessWidget 里
      //   `_showMessageMenu` 无法自取 —— 显式传，见该方法注释）
      HUserMessage(:final text) => _user(h, text, message.id, context),
      HAssistantMessage(:final text) => _assistant(h, text),
      HToolCall() =>
        ToolCallCard(call: message as HToolCall, stepDetail: stepDetail),
      HProgress(:final label) => _progress(h, label),
      HStepStream() => StreamStepView(
          step: message as HStepStream,
          // ★ 档位决定步骤的**默认**展开状态（精简=收起），
          //   用户点击后以用户为准（2026-10-13）
          detail: stepDetail,
        ),
      HBlocked() => _blocked(h, message as HBlocked),
      HRawOutput() => _rawOutput(h, message as HRawOutput),
    };
  }

  /// 用户消息：左侧强调色竖边 —— 与助手输出在视觉上明确区分
  ///
  /// ★ 长按交互（2026-10-13，参考 DeepSeek 移动端）：
  ///   · **所有消息**长按 = 复制（+ SnackBar 回执）
  ///   · **用户消息**长按额外有「编辑重发」—— 文本放回输入框，
  ///     用户改完自己点发送。**不做历史改写**：会话 append-only
  ///     （铁律 1），编辑重发 = 以这段内容为基础发一条新消息。
  Widget _user(Hue h, String text, String id, BuildContext context) {
    return GestureDetector(
      onLongPress: () => _showMessageMenu(context, h, text, id),
      child: Container(
        margin: const EdgeInsets.only(bottom: HSpace.lg),
        padding: const EdgeInsets.only(left: HSpace.md),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: h.accent, width: 2.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '你',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: h.accent,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: HSpace.xs),
            Text(
              text,
              style: TextStyle(
                fontSize: 15,
                height: 1.55,
                color: h.text,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// **长按消息的菜单**（2026-10-13，参考 DeepSeek 移动端）。
  ///
  /// · 所有用户消息：复制 + 编辑重发
  /// · 「编辑重发」= 文本放回输入框，用户改完自己点发送 ——
  ///   **不做历史改写**（会话 append-only，铁律 1），
  ///   与 DeepSeek 的"编辑后重新生成分支"相比少了自动回卷，
  ///   但语义诚实：发了什么就是什么，历史不被偷偷改掉。
  Future<void> _showMessageMenu(
      BuildContext context, Hue h, String text, String id) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: h.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: HSpace.sm),
            ListTile(
              leading:
                  Icon(Icons.copy_rounded, size: 20, color: h.textDim),
              title: const Text('复制', style: TextStyle(fontSize: 15)),
              onTap: () => Navigator.of(sheetCtx).pop('copy'),
            ),
            if (onEdit != null)
              ListTile(
                leading: Icon(Icons.edit_rounded, size: 20, color: h.textDim),
                title: const Text('编辑重发',
                    style: TextStyle(fontSize: 15)),
                subtitle: Text('把这条消息放回输入框修改后重新发送',
                    style: TextStyle(fontSize: 12, color: h.textFaint)),
                onTap: () => Navigator.of(sheetCtx).pop('edit'),
              ),
            const SizedBox(height: HSpace.sm),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    if (action == 'copy') {
      // ★ 不 await 剪贴板 —— 测试环境（无平台通道实现）里
      //   `Clipboard.setData` 的 Future 可能不完成，await 它会把
      //   回执一起吞掉。复制是本地操作，发后不管即可。
      unawaited(Clipboard.setData(ClipboardData(text: text)));
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('已复制'),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else if (action == 'edit') {
      onEdit?.call(text);
    }
  }

  /// 助手消息：无边框，靠间距与字体区分
  Widget _assistant(Hue h, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: HSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 13, color: h.textFaint),
              const SizedBox(width: HSpace.xs + 2),
              Text(
                'Heracles',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: h.textFaint,
                  letterSpacing: 0.6,
                ),
              ),
              // ★ 单轮的「命中 xx%」胶囊已移除（2026-10-13 用户要求）：
              //   「每次跑完一个任务，后面就不用显示命中缓存率了，
              //     右上角的命中缓存率是针对这个会话的平均命中缓存率」
              //   单轮数字是噪音；会话平均看右上角指示器即可。
              //   （`metrics` 仍保留 —— 答案末尾的「本次对话用量统计」
              //     要展示这一轮的 token/耗时明细。）
            ],
          ),
          const SizedBox(height: HSpace.sm),
          // ★ Markdown 轻量渲染（2026-10-13，用户截图暴露）：
          //   回答里的 `## 标题`、`**粗体**`、`- 列表` 此前原样显示
          //   星号与井号 —— 那是给渲染器的标记，不是给人读的。
          //
          // ## 为什么是自写轻量渲染器，而不是 flutter_markdown
          //
          // `AGENTS.md`：新依赖必须先进 `11-复用调研.md` 并写 ADR。
          // 而回答里实际出现的语法就几种（标题/粗体/列表/行内码），
          // 一个 ~百行的受控渲染器覆盖它们，不引依赖、样式完全跟
          // 主题走（`flutter_markdown` 的样式定制反而繁琐）。
          // 若将来语法需求超出覆盖面，再走依赖调研流程。
          _MarkdownLite(text: text),
          // ★ 回答末尾的操作行（2026-10-13 用户要求）：
          //   复制 · 点赞 · 点踩 · 新会话分支 · 用量统计 · 时间
          const SizedBox(height: HSpace.sm),
          _AnswerActions(
            h: h,
            text: text,
            metrics: metrics,
            onFeedback: onFeedback,
            onBranch: onBranch,
            feedback: feedback,
            timestamp: timestamp,
          ),
        ],
      ),
    );
  }

  /// **正在生成** —— 消除"发送后一片空白"的那一行。
  ///
  /// 用 [h.textDim] 而不是 [h.text]：它是**临时状态**，不该和最终回答
  /// 抢视觉重量。左侧竖线用 `h.border` 而非强调色 —— 强调色留给
  /// 用户自己的消息（见 [_user]），否则用户会分不清谁在说话。
  Widget _progress(Hue h, String label) {
    return Container(
      margin: const EdgeInsets.only(bottom: HSpace.md),
      padding: const EdgeInsets.only(left: HSpace.md),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: h.border, width: 2.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              color: h.textFaint,
            ),
          ),
          const SizedBox(width: HSpace.sm),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: h.textDim,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// **被拦截** —— 刻意**不用**错误色。
  ///
  /// 用 [HColors.warnOn]（琥珀）而不是 error（红）：
  /// 红字会让用户以为"出错了/文件坏了"，但实际上
  /// **什么都没执行**，agent 只是自己纠偏后继续跑。
  /// 这是架构层的保护动作，不是故障。
  Widget _blocked(Hue h, HBlocked b) {
    final color = HColors.warnOn(h.dark);
    return Container(
      margin: const EdgeInsets.only(bottom: HSpace.md),
      padding: const EdgeInsets.all(HSpace.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: h.dark ? 0.10 : 0.12),
        borderRadius: BorderRadius.circular(HRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                // ★ 两种语义不同的"没执行"，图标与文案都要分开
                //（2026-10-13 用户报：「总是显示已拦截，未执行，不是合法JSON」）
                b.tool == null
                    ? Icons.sync_problem_rounded
                    : Icons.shield_outlined,
                size: 15,
                color: color,
              ),
              const SizedBox(width: HSpace.sm),
              Text(
                // ★ 「已拦截，未执行」只适用于**真的被拦下**的调用
                //   （重复调用 / 校验不过 / 死循环）。
                //
                //   `tool == null` 时根本不是拦截 —— 是模型输出的
                //   **JSON 不合法**，系统什么都没执行、只是让它重试。
                //   把这种情况也叫"已拦截"，用户会以为有个工具
                //   被安全机制挡了（语义错误，不是措辞问题）。
                b.tool == null ? '输出无法解析' : '已拦截，未执行',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                  letterSpacing: 0.3,
                ),
              ),
              if (b.index != null) ...[
                const Spacer(),
                Text(
                  '第 ${b.index} 轮',
                  style: TextStyle(fontSize: 10.5, color: h.textFaint),
                ),
              ],
            ],
          ),
          const SizedBox(height: HSpace.xs + 2),
          // tool 可能为 null（Unparseable：连调用都没解析出来）——
          // 不能画成空工具卡片，那会让人以为有个工具被拦了
          if (b.tool != null) ...[
            Text(
              // ★ 人话工具名（2026-10-13 与工具卡片统一）：真拦截时
              //   写「修改文件代码」而不是 schema 名 `write_file`
              friendlyToolName(b.tool!),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: h.text,
              ),
            ),
            const SizedBox(height: HSpace.xs),
          ],
          Text(
            // ★ 解析失败时给**人话**解释（2026-10-13）：
            //   原始 reason 是解析器的技术细节（如
            //   "Expecting value: line 1 column 1"），直接摆给用户
            //   等于没解释。这里先说清"发生了什么 + 系统会怎么做"，
            //   技术细节降级到下一行（灰色小字）供排查。
            b.tool == null
                ? '模型这一步输出的格式不对，系统没有执行任何操作，'
                    '已让它按格式重试。'
                : b.reason,
            style: TextStyle(fontSize: 12, height: 1.5, color: h.textDim),
          ),
          if (b.tool == null) ...[
            const SizedBox(height: HSpace.xs),
            Text(
              b.reason,
              style: TextStyle(fontSize: 10.5, height: 1.4, color: h.textFaint),
            ),
          ],
        ],
      ),
    );
  }

  /// **模型原始输出**（「详细」档位专用）。
  ///
  /// 不等宽字体 + 等宽容器：模型原话是 JSON，等宽更易读。
  /// 用 [h.textFaint] 做标题、[h.textDim] 做正文 —— 它是**诊断信息**，
  /// 视觉层级必须低于最终回答。
  Widget _rawOutput(Hue h, HRawOutput o) {
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
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HSpace.md,
              vertical: HSpace.sm,
            ),
            child: Row(
              children: [
                Icon(Icons.notes_rounded, size: 13, color: h.textFaint),
                const SizedBox(width: HSpace.sm),
                Text(
                  '模型原始输出',
                  style: TextStyle(
                    fontSize: 11,
                    color: h.textFaint,
                    letterSpacing: 0.4,
                  ),
                ),
                const Spacer(),
                Text(
                  '第 ${o.index} 轮'
                  '${o.wallMs != null && o.wallMs! > 0 ? ' · ${o.wallMs}ms' : ''}',
                  style: TextStyle(fontSize: 10.5, color: h.textFaint),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: h.border),
          Padding(
            padding: const EdgeInsets.all(HSpace.md),
            child: Text(
              o.raw,
              style: TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12,
                height: 1.5,
                color: h.textDim,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// **用户对一条回答的反馈**（2026-10-13）。
///
/// 只存本地（不落盘、不上报）—— 发行版若要接云端评价体系，
/// 在 `ChatScreen` 的回调里加即可，UI 层不用改。
enum AnswerFeedback { up, down }

/// **回答末尾的操作行**（2026-10-13，用户要求）。
///
/// 用户原话：
/// > 「每次对话结束后，在回答问题的最后实现复制，点赞，点踩，
/// >   在新会话分支，本次对话用量统计，时间」
///
/// ## 布局
///
/// ```
/// ⧉ 复制   👍   👎   ⑂ 分支   ▦ 用量   · 14:32
/// ```
///
/// · 全部是**小尺寸图标按钮**（32×32 命中区，靠外边距补足）
/// · 「用量」点击展开本轮的 token / 耗时明细
/// · 时间在最右（`h.textFaint`，不抢视觉）
///
/// ## 为什么复制不用 Clipboard 直接调
///
/// 用了 —— `Clipboard.setData`。但要**给回执**（SnackBar）：
/// 复制是"看不见结果"的操作，没有反馈用户不知道成没成。
class _AnswerActions extends StatefulWidget {
  const _AnswerActions({
    required this.h,
    required this.text,
    required this.metrics,
    required this.feedback,
    required this.onFeedback,
    required this.onBranch,
    required this.timestamp,
  });

  final Hue h;
  final String text;
  final TurnMetrics? metrics;
  final AnswerFeedback? feedback;
  final ValueChanged<AnswerFeedback>? onFeedback;
  final VoidCallback? onBranch;
  final DateTime? timestamp;

  @override
  State<_AnswerActions> createState() => _AnswerActionsState();
}

class _AnswerActionsState extends State<_AnswerActions> {
  bool _showUsage = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('已复制'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _time() {
    final t = widget.timestamp;
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.h;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _act(Icons.copy_rounded, '复制', _copy, h),
            _feedbackBtn(Icons.thumb_up_alt_outlined,
                Icons.thumb_up_alt_rounded, '有帮助', AnswerFeedback.up, h),
            _feedbackBtn(Icons.thumb_down_alt_outlined,
                Icons.thumb_down_alt_rounded, '没帮助', AnswerFeedback.down, h),
            _act(Icons.call_split_rounded, '新会话分支',
                widget.onBranch == null ? null : () => widget.onBranch!(), h),
            if (widget.metrics != null)
              _act(Icons.data_usage_rounded, '本次用量', () {
                setState(() => _showUsage = !_showUsage);
              }, h, active: _showUsage),
            const Spacer(),
            if (_time().isNotEmpty)
              Text(
                _time(),
                style: TextStyle(fontSize: 10.5, color: h.textFaint),
              ),
          ],
        ),
        // ---- 本次对话用量统计（就地展开）----
        if (_showUsage && widget.metrics != null) ...[
          const SizedBox(height: HSpace.sm),
          _usagePanel(h, widget.metrics!),
        ],
      ],
    );
  }

  /// 一个小图标按钮。`onTap == null` 时不显示（上层没给回调就别画）。
  Widget _act(IconData icon, String tip, VoidCallback? onTap, Hue h,
      {bool active = false}) {
    if (onTap == null) return const SizedBox.shrink();
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HRadius.sm),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 15,
            color: active ? h.accent : h.textFaint,
          ),
        ),
      ),
    );
  }

  Widget _feedbackBtn(IconData off, IconData on, String tip,
      AnswerFeedback value, Hue h) {
    final selected = widget.feedback == value;
    if (widget.onFeedback == null) return const SizedBox.shrink();
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: () => widget.onFeedback!(value),
        borderRadius: BorderRadius.circular(HRadius.sm),
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            selected ? on : off,
            size: 15,
            // 点赞用成功色、点踩用错误色 —— 选中态必须一眼看出
            color: selected
                ? (value == AnswerFeedback.up
                    ? HColors.successOn(h.dark)
                    : HColors.errorOn(h.dark))
                : h.textFaint,
          ),
        ),
      ),
    );
  }

  /// 本轮用量明细 —— 数据来自 [TurnMetrics]（与右上角会话平均不同：
  /// 这里是**这一轮**的数字）。
  Widget _usagePanel(Hue h, TurnMetrics m) {
    final rate = m.hitRate;
    String row(String k, String v) => '$k：$v';
    final lines = <String>[
      if (rate != null) row('缓存命中', '${(rate * 100).round()}%'),
      // ⚠️ 未上报时**不写 0%** —— null 不是 0（契约 §3.4）
      if (rate == null) '缓存命中：本次未上报',
      row('耗时', '${m.wallMs} ms'),
      if (m.outputTokens > 0) row('输出', '${m.outputTokens} tokens'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: HSpace.md, vertical: HSpace.sm),
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.sm),
        border: Border.all(color: h.border),
      ),
      child: Text(
        lines.join('   ·   '),
        style: TextStyle(fontSize: 11, height: 1.4, color: h.textDim),
      ),
    );
  }
}


/// **轻量 Markdown 渲染**（2026-10-13，用户截图暴露星号/井号原样显示）。
///
/// ## 覆盖的语法（回答里实际出现的）
///
/// | 语法 | 渲染 |
/// |---|---|
/// | `## 标题` / `### 标题` | 加粗大一号（标题层级） |
/// | `**粗体**` | 粗体 span |
/// | `` `code` `` | 等宽字体 span（带底色） |
/// | `- 列表` / `* 列表` | 保留 `·` 前缀的列表行 |
/// | `1. 列表` | 保留原编号 |
///
/// ## 设计取舍
///
/// · **不引依赖**（AGENTS.md：新依赖要 ADR —— 现有语法面窄，
///   受控渲染器覆盖即可；将来语法需求超出再走调研流程）
/// · 样式全部取自 [Hue] —— 深浅两色自动适配
/// · 逐行解析（Markdown 的块结构按行划分足够，回答不是嵌套文档）
class _MarkdownLite extends StatelessWidget {
  const _MarkdownLite({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final lines = text.split('\n');
    final spans = <Widget>[];
    for (final line in lines) {
      spans.add(_line(context, h, line));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: spans,
    );
  }

  Widget _line(BuildContext context, Hue h, String line) {
    final t = line.trimLeft();

    // ---- 标题 ## / ### ----
    if (t.startsWith('### ')) {
      return _heading(h, t.substring(4), 15.5);
    }
    if (t.startsWith('## ')) {
      return _heading(h, t.substring(3), 16.5);
    }
    if (t.startsWith('# ')) {
      return _heading(h, t.substring(2), 17.5);
    }

    // ---- 无序列表 ----
    if (t.startsWith('- ') || t.startsWith('* ')) {
      return Padding(
        padding: const EdgeInsets.only(left: HSpace.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('·  ', style: TextStyle(fontSize: 15, height: 1.6, color: h.text)),
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
          color: h.text,
        ),
      ),
    );
  }

  /// 行内解析：`**粗体**` 与 `` `code` `` → 样式化 TextSpan。
  ///
  /// ★ 行内**没有**任何标记时返回普通 `Text` 而不是 `RichText` ——
  ///   既是渲染捷径，也保证 `find.text(...)` 这类测试查找器
  ///   对无标记回答仍然有效（2026-10-13 套件假失败的真实原因：
  ///   RichText 不创建 Text widget，纯文本断言全空）。
  Widget _rich(Hue h, String line) {
    final base = TextStyle(fontSize: 15, height: 1.6, color: h.text);
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
              fontSize: 13.5,
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