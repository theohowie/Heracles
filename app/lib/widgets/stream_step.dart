import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/settings.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
// ★ 共享件来自 `tool_call_card.dart`（**单向依赖**）：
//   · `MarkdownLite` —— 正文汇报复用最终回答那套渲染（用户：「正文汇报不渲染 md」）
//   · `kStepRowVPad` —— 步骤行与工具行共用的纵向内边距（左侧几何已于
//     2026-10-25 晚改为与 PlainToolLine 同槽：图标 15 + 间距 8）
//   ⚠️ 依赖方向只能是 stream_step → tool_call_card。`message_row.dart` 反过来
//      import 本文件（渲染 StreamStepView），所以本文件**绝不能** import
//      `message_row.dart`，否则成环。
import 'tool_call_card.dart'
    show
        MarkdownLite,
        changedFilesOf,
        estimatedDiffStatOf,
        kFileWritingTools,
        kStepRowVPad;

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

  /// 思考区自己的开关（2026-10-28，用户拍板）：思考不做卡片，
  /// 点「思考」两个字展开、再点一次收起。null = 没点过 →
  /// 流式中默认展开（看它逐字出），结束后默认收起。
  bool? _reasoningUserExpanded;

  final ScrollController _reasoningScroll = ScrollController();

  bool get _reasoningExpanded =>
      _reasoningUserExpanded ?? !widget.step.finished;

  @override
  void dispose() {
    _reasoningScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final step = widget.step;

    // ★ 收起状态（2026-10-13）：只有标题行 + 一行流式预览。
    //   用户原话：「收起状态下，流式输出也不是没有」——
    //   增量到达时那一行会持续刷新（DeepSeek harness 风格），
    //   用户不展开也能看见"在动、在出字"。
    //   预览内容 = 最新的增量（思考优先于正文 —— 思考先发生）。
    final streaming = !step.finished;
    final toolStreaming = StreamStepView.isStreamingToolCallStatic(step.text);
    final finishedToolCall = _isFinishedToolCall(step);
    // 标题行尾部箭头的显隐：有可展开内容（思考 / 工具子条目）才画
    final expandable =
        step.reasoning.isNotEmpty || toolStreaming || finishedToolCall;

    // ★★ 2026-10-23 用户报：「分析请求还没跑完呢，正文汇报就出来了」★★
    //
    // 根因：正文的渲染条件只看"有没有字"，不看 `finished` —— 思考还在流，
    // 正文一露头就整段铺到屏幕上，还跟着逐字重排。
    // 现在的纪律：
    //   · 流式中 ⇒ **只**有标题行里的单行预览（`preview`）
    //   · 结束后 ⇒ 才把正文（正文汇报）渲染出来
    //
    // 另：正文与思考**完全同一段文字**时也不显示（第 1 条「同类文本不要
    // 重复出现两遍」）—— 只做"完全相等"这种最保守的去重，
    // 见 `_duplicatesReasoning`（按子串去重会误删正文，不做）。
    final showBody = step.finished &&
        !step.bodyCollapsed &&
        step.text.isNotEmpty &&
        !toolStreaming &&
        !finishedToolCall &&
        !_duplicatesReasoning(step);

    // ★★ 2026-10-23 用户原话 ★★
    //
    // > 「如果分析完了，思考完了，就**不要显示后面的思考文字了**」
    //
    // 这是对 2026-10-22「结束也留一行预览」的**反向修订**：那行灰字只属于
    // **进行中**（证明"还在想 / 还在出字"）；这一轮一结束就不再挂 ——
    // 结束后的内容由正文汇报（`_body`）承担，同一个思考再留一条尾巴纯属残渣。
    //
    // ★ 另一条纪律不变：流式中的**协议信封原文**（`{"final":…` / `{"tool":…`）
    //   也不摆进预览行 —— 那是给 AgentLoop 解析的输出协议，用户在标签后面
    //   看到一截 JSON 尾巴只会困惑（正文区结束后会剥壳，见 `_finishStep`）。
    final envelope = streaming && step.text.trimLeft().startsWith('{');
    final preview = streaming
        ? (step.reasoning.isNotEmpty
            ? _tail(step.reasoning)
            : (toolStreaming
                ? '正在修改文件代码…'
                : (envelope ? '正在整理输出…' : _tail(step.text))))
        // 结束后**不再**留预览（上一条用户要求）—— 不是空字符串就是死代码
        : '';

    // 预览只在**进行中**出现（结束后 `preview` 恒为空）：
    // · 收起 ⇒ 一律显示（展开才有完整内容）
    // · 展开 ⇒ 仅当**没有思考**可看时显示（纯正文流式：给一行"在出字"的
    //   证据，否则正文按第 6 条要等结束才显示，屏幕上会一段空白）
    //   —— 有思考时展开区已经显示它，再在标题行复述一遍就是重复。
    final previewVisible = preview.isNotEmpty &&
        (!_expanded || step.reasoning.isEmpty);

    return Container(
      // ★ 2026-10-22 用户要求：**「分析需求」要和下面的工具行长得一样**。
      //
      // 旧样子是一条"带左侧竖线的引用块"（`border: left 2.5`），而工具行是
      // 无边框的紧凑日志行 ⇒ 两套视觉语言摆在一起很割裂（用户截图指出）。
      // 现在统一成与 `ToolCallCard` 同款：无边框、无缩进、同样的下边距。
      //
      // ★ 2026-10-23：连**水平内边距 / 箭头尺寸 / 图标间距**也统一到
      //   `tool_call_card.dart` 的 `kStepRow*` 常量 —— 用户报
      //   「分析请求没和其他工具调用对齐」，见 `_header`。
      margin: const EdgeInsets.only(bottom: HSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 标题行（只有"值得折叠"时才画）----
          //
          // ★ 2026-10-22 用户要求（真机截图对照 DSH）：
          //
          // > 「调用工具，然后就是输出，这个输出不是思考，是展示给用户看
          // >   做了什么，然后又干嘛干嘛」「现在软件要不就是一直调用工具、
          // >   不汇报，要么就是思考都没有」
          //
          // 也就是说：**汇报（正文）必须看得见**，不能被折叠在一条叫
          // 「正在生成…」的步骤行里 —— 那让人以为模型"闷头调工具"。
          //
          // 于是：
          // · **思考**（reasoning）⇒ 一条可折叠的「思考」行（默认收起）
          // · **正文**（text）    ⇒ 这一轮**结束后**直接显示（第 6 条）
          // · 没有思考、也没有工具子条目时，**连标题行都不画** ——
          //   直接就是一段模型说的话，和 DSH 的观感一致。
          if (_showHeader)
            InkWell(
              onTap: () => setState(() => _userExpanded = !_expanded),
              child: _header(h, preview, previewVisible, expandable),
            ),

          // ---- 思考：仅展开时显示（收起时只留标题行里的单行预览）----
          //
          // 这条纪律就是第 1 条：**思考原文只属于这一块**，正文区（`_body`）
          // 只画 `step.text` 通道，绝不把 `step.reasoning` 再拼进去 ——
          // 两个通道粘在一起就再也分不开，用户会看到同一段话出现两遍。
          if (_expanded && step.reasoning.isNotEmpty) ...[
            const SizedBox(height: HSpace.sm),
            _reasoning(h),
          ],

          // ---- 正文汇报：**这一轮结束后**才显示（第 6 条）----
          if (showBody) ...[
            const SizedBox(height: HSpace.sm),
            _body(h),
          ],

          // 正文与最终回答重复 ⇒ 收起来（`bodyCollapsed` 由 ChatScreen 在
          // 运行收尾时置位）。
          //
          // ★ 2026-10-22：**连"回答见下方"这句话也不画** —— 最终回答那一轮
          // 的标题行本就不画，再留一句提示就是纯残渣（真机截图里出现过一行
          // 孤零零的「回答见下方」）。用户要的是干净：这一轮直接消失，
          // 回答就在下面。

          // ---- 工具调用子条目（流式中的 JSON 信封）----
          if (_expanded && (toolStreaming || finishedToolCall)) ...[
            const SizedBox(height: HSpace.sm),
            _ToolSubEntry(text: step.text, finished: step.finished),
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
      ),
    );
  }

  /// 是否要画那条标题行（只有"有东西可折叠 / 有状态要报"时才画）。
  ///
  /// 纯文本的普通轮次**不画** —— 否则每条回答上面都顶一行
  /// 「输出完成」，像日志噪音。
  bool get _showHeader {
    final step = widget.step;
    // ★ 2026-10-23：流式期间**必须**有这一行。
    //
    // 正文已按用户要求改成"这一轮结束后才显示"（第 6 条），于是流式中
    // 唯一能表达"还在出字"的就是标题行里的单行预览。这里不画这一行，
    // 纯正文轮次在跑完之前会是一片空白 —— 正是 `docs/25` §5.3 要消灭的
    // 「发送后一片空白」。
    if (!step.finished && step.hasBody) return true;
    if (step.reasoning.isNotEmpty) return true; // 有思考 ⇒ 需要那条「思考」行
    if (_isFinishedToolCall(step)) return true;
    if (StreamStepView.isStreamingToolCallStatic(step.text)) return true;
    if (step.finished && !step.hasBody) return true; // 空轮次要报告
    // ★ 2026-10-22 用户要求：**最终回答那一轮的标题行要隐藏**。
    //
    // 那一轮的文字因 `bodyCollapsed`（与下方正式回答重复）被折叠，于是界面上
    // 只剩一行「输出完成」的"空标题"，像残渣。用户原话：「隐藏这个！」
    // ⇒ `bodyCollapsed` 时**连标题行一起不画**，正文由下方助手消息承担。
    if (step.bodyCollapsed) return false;
    return false;
  }

  /// 步骤行的时态文案 —— 用户原话（2026-10-23）：
  ///
  /// > 「每次思考完都要进行正文汇报，**第一次拿到用户给的任务，第一下叫
  /// >   分析**，后面就不是分析了，就是**思考**，你要注意这个点」
  ///
  /// 所以文案按**该步骤在本次运行里的轮次**分两类（**不再看 `title`** ——
  /// 以前每一轮只要是"先出思考"就都叫「分析」，那正是用户指出的错）：
  ///
  /// | 位置 | 进行中 | 已结束 |
  /// |---|---|---|
  /// | 第 1 轮（刚拿到任务的第一下） | `正在分析` | `分析完成` |
  /// | 第 2 轮及以后 | `正在思考` | `思考完成` |
  ///
  /// ## 判据：轮次序号从哪来（不新增协议字段）
  ///
  /// 见 [_stepOrdinal]：`.jsonl` 里存的 `i`（读回时落在 [HStepStream.index]）
  /// 与 `stepId`（`turn-3`）都是现成字段。**不能只看内存态** —— 重开旧会话
  /// 时也要能正确区分，否则历史里每一轮都会显示成「分析」。
  String _label(HStepStream step) {
    // 纯正文轮（这一轮**没有思考通道**，先出正文）：叫「分析」或「思考」
    // 都是假话，保留「输出」语义。判据用 title 只做这一种兜底 ——
    // `local_agent` 在"正文先到"时标的标题正是「本轮输出」。
    if (step.reasoning.isEmpty && step.title == '本轮输出') {
      return step.finished ? '输出完成' : '正在输出';
    }
    if (_stepOrdinal(step) == 1) {
      return step.finished ? '分析完成' : '正在分析';
    }
    return step.finished ? '思考完成' : '正在思考';
  }

  /// 该步骤在**本次运行**里的轮次序号（1 起）；判不出来返回 null。
  ///
  /// ## 为什么需要它（用户：「第一下叫分析，后面就是思考」）
  ///
  /// 「第几次」只能从**已经存在**的数据里读，不新增协议字段：
  ///
  /// 1. [HStepStream.index] —— 来自 `step_started` / `step_ended` 的 `index`；
  ///    `.jsonl` 里就是 `i`（`local_agent.endStep` 写的 `'i': _turn`），
  ///    `chat_screen._toMessages` 读回时放进 `index` ⇒ **历史会话也判得准**。
  /// 2. 退回解析 `stepId`（形如 `turn-3`）的尾号 —— 同一序号的另一种写法。
  ///
  /// ⚠️ 为什么必须有第 2 条：**实时路径**建 `HStepStream` 时并不填 `index`
  /// （`chat_screen._ensureStep` 只拿它拼兜底标题），所以实时步骤的 `index`
  /// 为 null，只有 `stepId` 可靠。分支新建会话时 `i` 又被写成字符串
  /// （`'i': old.index.toString()`），读回时 `as num?` 得 null ——
  /// 两种情况下都靠 `stepId` 兜住，**历史里不会退化成"全是思考"**。
  static int? _stepOrdinal(HStepStream step) {
    final i = step.index;
    if (i != null && i > 0) return i;
    final dash = step.stepId.lastIndexOf('-');
    if (dash >= 0 && dash < step.stepId.length - 1) {
      final n = int.tryParse(step.stepId.substring(dash + 1));
      if (n != null && n > 0) return n;
    }
    return null;
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

  /// 正文（`text` 通道）与思考（`reasoning` 通道）是不是**同一段文字**。
  ///
  /// 第 1 条的纪律是"同类文本不要重复出现两遍"。两个通道本来就是分开渲染的
  /// （见 build 的注释：正文只画 `step.text`）。这里只兜住一种真实见过的
  /// 病态情况：个别 provider 把最终结论**同时**写进 `reasoning_content` 与
  /// `content`，于是同一段话会显示两次。
  ///
  /// ## 为什么只认"完全相等"（trim 后）
  ///
  /// 按子串/包含关系去重会**误删正文**：模型在思考里提过某句话、再在正文里
  /// 原样收尾，是正常的推进过程（思考里出现过的词句不代表正文是重复内容）。
  /// 宁可多显示一段，也不吞掉模型真正说给你的话 —— 诚实优先。
  static bool _duplicatesReasoning(HStepStream step) {
    final t = step.text.trim();
    if (t.isEmpty) return false;
    return t == step.reasoning.trim();
  }

  /// 取文本的**末尾若干字符**做单行预览 —— 流式时新字不断从尾部出现，
  /// 预览跟着滚动（正是 DeepSeek harness 的"一行流动"观感）。
  ///
  /// ⚠️ 只服务**进行中**的预览。2026-10-23 删掉"结束后也留一行"之后，
  /// 原来那个 `max` 参数（结束态传 90）再没有调用方 —— 一起删掉，不留死参数。
  static String _tail(String s) {
    const max = 60;
    final t = s.replaceAll('\n', ' ').trim();
    if (t.length <= max) return t;
    return '…${t.substring(t.length - max)}';
  }

  /// 标题行：前置图标 + 文案 + （进行中的单行预览）+ 行尾展开箭头
  ///
  /// ## 与工具行对齐（2026-10-25 晚用户定版）
  ///
  /// 用户对着真机截图定：步骤行（分析 / 思考）要和工具行（执行了命令 /
  /// 向你提了问）**一个样** —— 前面是图标、不要左侧的 `>`、不要 ✓、
  /// 字号也要一样。此前本行是"`>` + 状态槽（✓/转圈）+ 12 号小字"，
  /// 工具行是"图标 + 13.5 号字"，摆在一起两套语言。现在：
  /// · 图标槽 15 + 间距 8 ⇒ 标签起点 23，与 `PlainToolLine` 逐像素一致
  /// · 标签 13.5 w600（同工具行摘要），颜色保持 textDim（它是状态叙述）
  /// · 展开箭头移到行尾（同工具行），无可展开内容不画
  ///
  /// ## 没有耗时了（2026-10-23 用户原话：「这个 xxxms 给我删了」）
  ///
  /// 原来的 `917ms` 属于**诊断信息**，删掉显示的同时把只服务它的代码
  /// 一起删了；`HStepStream.durationMs` 字段本身保留（落盘/其它界面在用）。
  Widget _header(
    Hue h,
    String preview,
    bool previewVisible,
    bool expandable,
  ) {
    final step = widget.step;
    // 纯正文轮（无思考通道）用文件图标，其余（分析 / 思考）用灯泡 ——
    // 与 _label 的「本轮输出」兜底判据一致
    final isOutput = step.reasoning.isEmpty && step.title == '本轮输出';
    return ConstrainedBox(
      // 热区与工具行同高（≥ kMinTapTarget，`docs/25` §7）：
      // 一整行都可点，展开/收起不用瞄准小箭头。
      constraints: const BoxConstraints(minHeight: kMinTapTarget),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: kStepRowVPad),
        child: Row(
          children: [
            // ★ 前置图标槽（2026-10-25 晚用户定）：不要左侧的 > 、不要 ✓ ——
            //   像工具行（PlainToolLine）一样，前面是一个图标且对齐：
            //   图标 15 + 间距 8 ⇒ 标签起点同为 23。
            //   进行中 = 转圈；出错 = 错误图标；其余 = 按类填充图标。
            SizedBox(
              width: 15,
              height: 15,
              child: step.finished
                  ? Icon(
                      step.isError
                          ? AppIcons.error
                          : (isOutput
                              ? AppIcons.file
                              : CupertinoIcons.lightbulb_fill),
                      size: 15,
                      color: step.isError
                          ? HColors.errorOn(h.dark)
                          : h.text,
                    )
                  : Center(
                      child: CupertinoActivityIndicator(
                        radius: 6,
                        color: h.text,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                // ★ 文案见 `_label`（第 1 轮「分析」/ 之后「思考」）
                // 字号与工具行摘要统一 13.5 w600（2026-10-25 晚用户定：
                // 步骤行与工具行同为一行式条目，不许两种字号）
                _label(step),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: h.textDim,
                ),
              ),
            ),
            const SizedBox(width: HSpace.sm),
            // ---- ★ 单行预览（**只在进行中**；DeepSeek harness 风格）----
            if (previewVisible)
              Expanded(
                child: Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: h.textFaint,
                  ),
                ),
              )
            else
              const Spacer(),
            // （行尾展开箭头已退役 —— 2026-10-26 用户令，行仍可点开）
          ],
        ),
      ),
    );
  }

  /// **思考过程** —— 淡色 + 缩进 + 斜体。
  ///
  /// ⚠️ 不做 Markdown：思考内容里常出现 `*`、`#`、`` ` ``，
  /// 逐字过程中把它们渲染成格式会让文字**跳来跳去**。
  Widget _reasoning(Hue h) {
    final expanded = _reasoningExpanded;
    // 流式中贴底跟随：用户没滚开时，新出的思考自动跟上；
    // 用户已经往上滚了就不抢（差值 >60 视为在回看）。
    if (expanded && !widget.step.finished) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_reasoningScroll.hasClients) return;
        final pos = _reasoningScroll.position;
        if (pos.maxScrollExtent - pos.pixels < 60) {
          _reasoningScroll.jumpTo(pos.maxScrollExtent);
        }
      });
    }
    return Padding(
      // 缩进到标题行标签起点（23），与工具行明细同一左线
      padding: const EdgeInsets.only(left: 23),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 开关就是「思考」两个字本身（用户拍板：无卡片、无收起按钮）
          GestureDetector(
            onTap: () =>
                setState(() => _reasoningUserExpanded = !expanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.think, size: 13, color: h.textFaint),
                  const SizedBox(width: HSpace.xs + 1),
                  Text(
                    '思考',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: h.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const SizedBox(height: HSpace.xs),
            // 限高内滚：上限不标注、不显示数字；手指在思考区
            // 滚思考，滚到头才带动会话（嵌套滚动竞技场天然如此）。
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: Scrollbar(
                controller: _reasoningScroll,
                thickness: 3,
                radius: const Radius.circular(2),
                child: SingleChildScrollView(
                  controller: _reasoningScroll,
                  child: Text(
                    widget.step.reasoning,
                    // **只做轻量装饰，不做 Markdown**：思考是过程，不是成品
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.55,
                      fontStyle: FontStyle.italic,
                      color: h.textDim,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// **正文汇报** —— 这一轮结束后才渲染（第 6 条），**复用最终回答的 Markdown**。
  ///
  /// ## 为什么复用 `MarkdownLite`（用户原话：「正文汇报不渲染 md」）
  ///
  /// 原来这里走自写的 `_format`（只还原 `\n` / 制表符），于是步骤正文里的
  /// `**粗体**`、`` `code` ``、`- 列表`、表格全部**原样吐标记**；而最终回答
  /// 有完整渲染 ⇒ 同一个人说的话，上下两层长得不一样。
  /// 现在两处共用 `tool_call_card.dart` 的 `MarkdownLite`（同一套实现，
  /// 不会再出现"改了一处、另一处漂移"）。
  ///
  /// ## 字号
  ///
  /// 基准 **15** —— 与最终回答**同一个数**（2026-10-25 晚用户定：
  /// 全对话正文字号统一，步骤正文与最终回答不许一大一小）。
  /// `MarkdownLite` 内部的标题/列表/代码/表格字号都从基准派生。
  Widget _body(Hue h) {
    return MarkdownLite(
      // 协议转义（字面量 `\n` / 制表符）先还原，再交给 Markdown 渲染
      text: _format(widget.step.text),
      fontSize: 15,
      // 错误态正文用错误色；正常态传 null ⇒ 跟随主题
      color: widget.step.isError ? HColors.errorOn(h.dark) : null,
    );
  }

  /// 渲染前的**协议转义还原**（只做两件无风险的事）：
  /// 把字面量 `\n` 还原成换行、把制表符换成两个空格。
  ///
  /// Markdown 结构（标题/粗体/列表/表格/代码块）交给共享的 [MarkdownLite] ——
  /// 与最终回答**同一套**实现。这里**不做** Markdown 解析：
  /// 一份实现两处用，才不会两边漂移。
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
      // 外 7 + 边框 2 + 内 14 ⇒ 文字起点 23，与标题行标签 / 工具行明细同线
      padding: const EdgeInsets.only(left: 7),
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: h.border, width: 2)),
        ),
        padding: const EdgeInsets.only(left: 14),
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
                      child: CupertinoActivityIndicator(
                          radius: 5, color: h.textFaint),
                    )
                  else
                    Icon(AppIcons.edit,
                        size: 14, color: h.textFaint),
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