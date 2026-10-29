import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';


/// 黑白界面的顶部组件：灵动岛、上下文圆环、纯文字工具行。
///
/// 视觉约定（2026-10-24 用户拍板）：
/// - 配色只用黑、白、灰；动效用弹簧/缓动曲线，不用彩色高亮；
/// - 图标全部填充式；字号走 [HTxt] 统一字阶。

/// 任务计划灵动岛。
///
/// 收起 = 一颗小黑胶囊（呼吸圆点 + 当前步骤 + 进度），点按展开；
/// 展开 = 同一胶囊纵向展开为计划面板（AnimatedSize，300ms easeOutCubic），
/// 再点收回。状态由父级持有（与 `PlanChecklist` 同一套数据）。
/// 灵动岛形变曲线（2026-10-26，用户要水滴式流体感）：控制点 y
/// 越过 1 产生约 5% 的尺寸过冲——胶囊展开像被轻轻撑开再稳住，
/// 高阻尼、不弹跳。展开/收起与圆角变化共用这一条曲线才同步。
const _kFluidCurve = Cubic(0.22, 1.18, 0.36, 1.0);

/// **钳制版**流体曲线（2026-10-29 真机崩溃后加）。
///
/// ## 为什么要它（红屏复现）
///
/// 用户点开待办再收起时弹红屏：
///
/// ```
/// BoxConstraints has a negative minimum width.
/// The offending constraints were:
/// BoxConstraints(-0.7<=w<=280.0, 0.0<=h<=Infinity; NOT NORMALIZED)
/// ```
///
/// 根因：`_kFluidCurve` 的 y1=1.18 会**过冲到 1 以上**，而
/// `AnimatedContainer` 会给 `constraints` 做 `BoxConstraints.lerp`。
/// 收起时 `minWidth: 168 → 0`，在 t≈1.004 处插值出 `168 + (0-168)×1.004 ≈ -0.7`
/// ⇒ 负 minWidth ⇒ 断言崩溃。`-0.7` 这个数字正好对得上过冲量。
///
/// 修法两层：
/// 1. **`constraints` 里不再放 `minWidth`**（只留 `maxWidth`），从根上避免
///    "会过冲的量" 参与 lerp；
/// 2. 尺寸类动画（`AnimatedSize`）用这条**钳制到 [0,1]** 的曲线 ——
///    视觉上的过冲只保留在圆角这类不会产生非法值的地方。
///
/// 圆角/内边距仍用原始 `_kFluidCurve`，流体手感不变。
class _ClampedFluidCurve extends Curve {
  const _ClampedFluidCurve();

  @override
  double transformInternal(double t) => _kFluidCurve.transform(t).clamp(0.0, 1.0);
}

const _kFluidSizeCurve = _ClampedFluidCurve();

class DynamicIsland extends StatefulWidget {
  const DynamicIsland({
    super.key,
    required this.steps,
    required this.doneCount,
    required this.activeIndex,
    required this.collapsed,
    required this.onToggle,
    this.reachedGoal,
    this.closedReason,
    this.cancelledIndices = const {},
    this.onAdjust,
  });

  final List<String> steps;
  final int doneCount;
  final int activeIndex;
  final bool collapsed;
  final VoidCallback onToggle;
  final bool? reachedGoal;
  final String? closedReason;

  /// 已取消步骤的下标（plan_updated 的 cancelled 状态）；渲染为删除线。
  final Set<int> cancelledIndices;

  /// 「调整计划」回调（后端推荐路径：预填一条用户消息让模型改计划，
  /// 不新增编辑 API）。为 null 时不显示调整入口。
  final VoidCallback? onAdjust;

  @override
  State<DynamicIsland> createState() => _DynamicIslandState();
}

class _DynamicIslandState extends State<DynamicIsland>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String get _current {
    if (widget.steps.isEmpty) return '';
    if (widget.activeIndex >= 0 && widget.activeIndex < widget.steps.length) {
      return widget.steps[widget.activeIndex];
    }
    return widget.steps.last;
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final bg = h.text;
    final fg = h.dark ? const Color(0xFF0A0A0B) : Colors.white;
    final dim = fg.withValues(alpha: 0.55);
    return GestureDetector(
      onTap: widget.onToggle,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 520),
        // ★ 钳制曲线：尺寸过冲到负值会直接崩（见 _ClampedFluidCurve 注释）
        curve: _kFluidSizeCurve,
        alignment: Alignment.topCenter,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 520),
          curve: _kFluidCurve,
          // 收起形态（2026-10-29 用户对图定）：此前宽度全靠内容
          // 撑（只有「● 5/5」时短短一截，不好看）—— 给 168 的
          // 最小宽度拉长，同时纵向内边距压到 6 让胶囊更扁，
          // 不靠增高占地方。展开形态维持原尺寸。
          //
          // ⚠️ **minWidth 不许放这里**：它会参与 BoxConstraints.lerp，
          //   而过冲曲线会把 168→0 的插值推成负数（真机 -0.7 直接红屏）。
          //   最小宽度改由内层 ConstrainedBox 提供（见下方 child）。
          constraints: const BoxConstraints(maxWidth: 280),
          padding: EdgeInsets.symmetric(
            horizontal: 13,
            vertical: widget.collapsed ? 6 : 9,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(widget.collapsed ? 999 : 24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          // ★ 收起态的 168 最小宽度放在**这里**（不参与 BoxConstraints.lerp）：
          //   外层的 AnimatedSize 仍会把尺寸变化做平滑过渡，
          //   但不会再出现"插值出负 minWidth"的崩溃（2026-10-29 真机）。
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: widget.collapsed ? 168 : 0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, _) => Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: fg,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: fg.withValues(alpha: 0.35 * (1 - _pulse.value)),
                            blurRadius: 6 * _pulse.value,
                            spreadRadius: 2 * _pulse.value,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  // ★ 收起态 = **步骤数字轨道**（2026-10-29 用户重定义）。
                  //
                  // 用户原话：「收起来了，这么长的灵动岛就一个几分之几，
                  // 然后其他的全是黑色，很丑好吗，那我要灵动岛干什么呢？」
                  //
                  // 旧的收起态只写「2/5」⇒ 168dp 的胶囊里大半是空黑底。
                  // 现在把 1→2→3→…→N 铺在收起态里：
                  //   · 当前步：**变大 + 黄色**    · 已完成：**绿色**    · 未到：暗灰
                  //   · 放不下时**自动横向滚动**；滚出视口的部分由 ListView 自己裁切，
                  //     数字绝不会画到胶囊外面（用户明确要求）。
                  if (widget.collapsed)
                    _StepTrack(
                      steps: widget.steps.length,
                      doneCount: widget.doneCount,
                      activeIndex: widget.activeIndex,
                      cancelled: widget.cancelledIndices,
                      color: fg,
                      dim: dim,
                    )
                  else ...[
                    Flexible(
                      child: Text(
                        _current,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: fg,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${widget.doneCount}/${widget.steps.length}',
                      style: TextStyle(fontSize: 11, color: dim),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.keyboard_arrow_up, size: 14, color: dim),
                  ],
                ],
              ),
              if (!widget.collapsed) ...[
                const SizedBox(height: 8),
                for (var i = 0; i < widget.steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Row(
                      children: [
                        _StepDot(
                          state: widget.cancelledIndices.contains(i)
                              ? _StepState.cancelled
                              : i < widget.doneCount
                                  ? _StepState.done
                                  : i == widget.activeIndex
                                      ? _StepState.active
                                      : _StepState.todo,
                          fg: fg,
                          bg: bg,
                          dim: dim,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.steps[i],
                            style: TextStyle(
                              fontSize: 13,
                              decoration: widget.cancelledIndices.contains(i)
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: widget.cancelledIndices.contains(i)
                                  ? dim
                                  : i < widget.doneCount ||
                                          i == widget.activeIndex
                                      ? fg
                                      : dim,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (widget.onAdjust != null) ...[
                  const SizedBox(height: 10),
                  GestureDetector(
                    onTap: widget.onAdjust,
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit_outlined, size: 13, color: dim),
                        const SizedBox(width: 5),
                        Text(
                          '调整计划',
                          style: TextStyle(fontSize: 12.5, color: dim),
                        ),
                      ],
                    ),
                  ),
                ],
                if (widget.reachedGoal == false && widget.closedReason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      widget.closedReason!,
                      style: TextStyle(fontSize: 12, color: dim),
                    ),
                  ),
              ],
            ],
          ),
          ),
        ),
      ),
    );
  }
}

enum _StepState { done, active, todo, cancelled }

class _StepDot extends StatelessWidget {
  const _StepDot({
    required this.state,
    required this.fg,
    required this.bg,
    required this.dim,
  });

  final _StepState state;
  final Color fg;
  final Color bg;
  final Color dim;

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case _StepState.done:
        return Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          child: Icon(Icons.check, size: 10, color: bg),
        );
      case _StepState.active:
        return Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            border: Border.all(color: fg, width: 2),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
          ),
        );
      case _StepState.todo:
        return Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            border: Border.all(color: dim, width: 2),
            shape: BoxShape.circle,
          ),
        );
      case _StepState.cancelled:
        return Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            border: Border.all(color: dim, width: 2),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.close, size: 10, color: dim),
        );
    }
  }
}

/// 上下文占用圆环（顶栏右上角）。
///
/// 环的弧长 = 已用 / 上限；环心是百分比。点按打开用量抽屉。
/// 上限未知（ratio == null）时只画灰环、环心显示「—」，不画假进度。
class ContextRing extends StatelessWidget {
  const ContextRing({
    super.key,
    required this.usedTokens,
    required this.limitTokens,
    this.onTap,
  });

  final int usedTokens;
  final int limitTokens;
  final VoidCallback? onTap;

  double? get ratio {
    if (limitTokens <= 0) return null;
    return usedTokens / limitTokens;
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final r = ratio;
    final pct = r == null ? '—' : '${(r * 100).round()}%';
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 38,
        height: 38,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size(38, 38),
              painter: _RingPainter(
                ratio: r,
                track: h.border,
                arc: h.text,
              ),
            ),
            Text(
              pct,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: h.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.ratio,
    required this.track,
    required this.arc,
    this.strokeWidth = 3,
  });

  final double? ratio;
  final Color track;
  final Color arc;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - strokeWidth / 2;
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, trackPaint);
    final r = ratio;
    if (r != null && r > 0) {
      final arcPaint = Paint()
        ..color = arc
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        (r.clamp(0.0, 1.0)) * 2 * math.pi,
        false,
        arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.ratio != ratio ||
      old.track != track ||
      old.arc != arc ||
      old.strokeWidth != strokeWidth;
}

/// 顶栏指标的状态色（2026-10-25 晚用户定档位）：
///
/// - **上下文占用率**：≤50% 绿、50–80% 黄、>80% 红（越满越危险）；
/// - **缓存命中率**：反过来 —— <60% 红、60–80% 黄、>80% 绿（越高越好）。
Color usageStatusColor(Hue h, double ratio) {
  if (ratio > 0.80) return HColors.errorOn(h.dark);
  if (ratio > 0.50) return HColors.warnOn(h.dark);
  return HColors.successOn(h.dark);
}

/// 缓存命中率状态色（档位与上下文相反，见 [usageStatusColor]）。
Color hitStatusColor(Hue h, double rate) {
  if (rate > 0.80) return HColors.successOn(h.dark);
  if (rate >= 0.60) return HColors.warnOn(h.dark);
  return HColors.errorOn(h.dark);
}

/// 顶栏右列的一行指标：小圆环 + 「标签 百分比」，圆环与文字同色
/// （状态色由调用方按 [usageStatusColor] / [hitStatusColor] 算好）。
/// ratio 为 null（上限未知 / 未上报）时只画浅灰环、文字由调用方给「—」。
class TopMetricLine extends StatelessWidget {
  const TopMetricLine({
    super.key,
    required this.label,
    required this.valueText,
    required this.ratio,
    required this.color,
  });

  final String label;
  final String valueText;
  final double? ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(15, 15),
          painter: _RingPainter(
            ratio: ratio,
            track: color.withValues(alpha: 0.22),
            arc: color,
            strokeWidth: 2.5,
          ),
        ),
        const SizedBox(width: 5),
        // ★ 2026-10-29 修溢出：以前这里是裸 `Text`（无 Flexible、无省略），
        //   而右列只有 108dp 宽 —— 「状态 待填密钥」这类文案把 Row 撑出去，
        //   真机决策页右上角出现「RIGHT OVERFLOWED」黄黑条。
        //   现在：可伸缩 + 单行省略，永不越界。
        Flexible(
          child: Text(
            '$label $valueText',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// 纯文字工具行（无容器包裹），自带展开/收起状态。
///
/// 一行 = 填充图标 + 一句话摘要 + 展开箭头；明细是缩进的纯文字，
/// 用 AnimatedSize 展开/收起。摘要由调用方按 StepDetail 档位生成。
class PlainToolLine extends StatefulWidget {
  const PlainToolLine({
    super.key,
    required this.icon,
    required this.summary,
    this.detailLines = const [],
    this.initialExpanded = false,
  });

  final IconData icon;
  final String summary;
  final List<String> detailLines;
  final bool initialExpanded;

  @override
  State<PlainToolLine> createState() => _PlainToolLineState();
}

class _PlainToolLineState extends State<PlainToolLine> {
  late bool _expanded = widget.initialExpanded;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final detailLines = widget.detailLines;
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ★ 与步骤行/工具卡同一只盒子（2026-10-26 用户报「上下
          // 间距不一样」）：步骤标题行是 minHeight 44 + 纵向 4 的
          // 盒子，文字在盒里垂直居中；本行原先是裸 Row（约 20 高、
          // 无内边距），夹在 44 高的步骤行之间，行与行的间距就
          // 一会儿紧一会儿松。套上同规格盒子后全流一个节奏。
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinTapTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: HSpace.xs),
              child: Row(
            children: [
              Icon(widget.icon, size: 15, color: h.text),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: h.text,
                  ),
                ),
              ),
              // （行尾展开箭头已退役 —— 2026-10-26 用户令）
            ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: _expanded && detailLines.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(top: 5, left: 23),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: detailLines
                          .map(
                            (l) => Text(
                              l,
                              style: TextStyle(
                                fontSize: 12.5,
                                height: 1.8,
                                color: h.textDim,
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// **收起态步骤轨道**（2026-10-29 用户重定义）。
///
/// ## 用户要的效果（原话）
///
/// > 「我现在想在收起的状态上，上面做好 1，2，3，4……最后一步。
/// >  当进行第一步的时候，1 数字变大，且变为黄色，做完了第一步，1 就变成绿色，
/// >  随之 2 变大且变成黄色，以此类推。数字和数字之间有 -> 来连接。
/// >  如果溢出了，那就有自动滚动的效果…… 把 1 向左移出灵动岛隐藏
/// >  （不能出现在灵动岛外面），然后把 5 展示出来。」
///
/// ## 为什么用固定步宽（[kStepSlotExtent]）
///
/// 自动滚动要算"当前步应该滚到哪"。若每项宽度随字号/位数变化，就得先布局再测量，
/// 会闪一帧。固定步宽让偏移量可以直接算：`active * extent - 居中修正`，
/// 配合 `animateTo` 就是丝滑滑动。
///
/// ## 裁切
///
/// `ListView` 默认 `clipBehavior: Clip.hardEdge` ⇒ 滚出视口的数字**不会**画到胶囊外。
class _StepTrack extends StatefulWidget {
  const _StepTrack({
    required this.steps,
    required this.doneCount,
    required this.activeIndex,
    required this.cancelled,
    required this.color,
    required this.dim,
  });

  final int steps;
  final int doneCount;
  final int activeIndex;
  final Set<int> cancelled;
  final Color color;
  final Color dim;

  @override
  State<_StepTrack> createState() => _StepTrackState();
}

/// 每一步占的宽度（含箭头）。
const double kStepSlotExtent = 36;

/// 收起态轨道视口宽度：约 4.4 步 ⇒ 用户说的"只可以放下 4 个数字"。
///
/// ★ **不要为了给右侧 done/total 腾地方而缩窄它**（2026-10-29 第 1 条）：
///   视口缩到 3.x 步后，"未开始"时连 1..4 都看不全，违背用户
///   「收起态上铺出 1，2，3，4」的要求。收起胶囊宽度由内容自适应
///   （`maxWidth: 280` 的余量足够放下 `0/7`、`10/12` 这种计数）。
const double kStepTrackWidth = 144;

/// 当前步：黄色；已完成：绿色。
const _kActiveYellow = Color(0xFFF59E0B);
const _kDoneGreen = Color(0xFF22C55E);

class _StepTrackState extends State<_StepTrack> {
  final _ctrl = ScrollController();

  /// 最近一次**有 active 步**时的下标（-1 = 还没有过）。
  ///
  /// 生产帧（`chat_screen.dart`）的 activeIndex 是 `indexWhere(status=='active')`：
  /// 做完最后一步 / `plan_closed` / 剩余步骤全被取消时都是 **-1**。
  /// 旧实现拿 -1 硬算偏移：`-1*36 - 54 = -90` ⇒ clamp 到 0 ⇒ **轨道弹回最左**，
  /// 7 步计划收起来永远只看到 1→2→3→4（用户报的现象）。
  /// 现在 -1 只表示"没有当前步"，怎么滚由 doneCount 决定（见 [_scrollToActive]）。
  int _lastActive = -1;

  @override
  void initState() {
    super.initState();
    _captureActive();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToActive(animate: false));
  }

  @override
  void didUpdateWidget(_StepTrack old) {
    super.didUpdateWidget(old);
    if (old.activeIndex != widget.activeIndex ||
        old.steps != widget.steps ||
        // doneCount 也要跟：完成态可能在 activeIndex 一直是 -1 的情况下到来
        old.doneCount != widget.doneCount) {
      _captureActive();
      _scrollToActive(animate: true);
    }
  }

  void _captureActive() {
    final a = widget.activeIndex;
    if (a >= 0 && a < widget.steps) _lastActive = a;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 把轨道滚到该去的位置（首尾自动夹紧，不会滚过头）。
  ///
  /// - 有 active 步 ⇒ 滚到视口**中间**；
  /// - **全部完成**（没有 active 步，doneCount 已满）⇒ 滚到**末尾**，最后一步可见；
  /// - **未开始**（doneCount == 0）⇒ 停在最左；
  /// - 其余中间态 ⇒ 回到 [_lastActive] 的位置，**绝不弹回最左**。
  ///
  /// 视口宽度用 `position.viewportDimension`（**实测值**）而不是
  /// [kStepTrackWidth] 常量：这样以后若为放总数缩窄视口，居中偏移也跟着对
  /// （写死常量时套 LayoutBuilder 才是空操作）。
  void _scrollToActive({required bool animate}) {
    if (!_ctrl.hasClients) return;
    final max = _ctrl.position.maxScrollExtent;
    final viewport = _ctrl.position.viewportDimension;
    final active = widget.activeIndex;
    double center(int index) =>
        (index * kStepSlotExtent - (viewport - kStepSlotExtent) / 2)
            .clamp(0.0, max);

    final double target;
    if (active >= 0 && active < widget.steps) {
      target = center(active);
    } else if (widget.steps > 0 && widget.doneCount >= widget.steps) {
      target = max; // 完成态：没有 active 步 ⇒ 看到最后一步
    } else if (widget.doneCount <= 0) {
      target = 0; // 未开始：停在最左
    } else if (_lastActive >= 0) {
      target = center(_lastActive); // 中间态：保留上次位置
    } else {
      return; // 中间态且从未有过 active 步 ⇒ 保持当前偏移，别动
    }

    if (animate) {
      _ctrl.animateTo(target,
          duration: const Duration(milliseconds: 320), curve: _kFluidSizeCurve);
    } else {
      _ctrl.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ★ 收起态 = [数字轨道][固定 done/total]（2026-10-29 第 1 条）。
    //   轨道只放得下 4 个数字，用户在收起态还得能一眼看出"做完几步/共几步"；
    //   全部做完时按既有绿色约定（#22C55E）变绿 —— 这时轨道已滚到末尾。
    //   ⚠️ 计数器放在**轨道视口之外**：视口仍是 [kStepTrackWidth] = 4 步，
    //      "未开始"时 1..4 才能完整可见（见 kStepTrackWidth 注释）。
    final Widget track = SizedBox(
      width: kStepTrackWidth,
      height: 24,
      child: ListView.builder(
        controller: _ctrl,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(), // 只自动滚，不许用户拖
        itemExtent: kStepSlotExtent,
        itemCount: widget.steps,
        itemBuilder: (context, i) {
          final isActive = i == widget.activeIndex;
          final isDone = i < widget.doneCount;
          final isCancelled = widget.cancelled.contains(i);
          final color = isCancelled
              ? widget.dim
              : isActive
                  ? _kActiveYellow
                  : isDone
                      ? _kDoneGreen
                      : widget.dim.withValues(alpha: 0.45);
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 数字：当前步**变大**（15 vs 12），其余保持小号，避免整行跳动
              Text(
                '${i + 1}',
                style: TextStyle(
                  // ★ 两位数步号（≥10 步）自动缩字号：否则 1 格放不下，会 RenderFlex 溢出（真机 6.3px）
                  fontSize: isActive
                      ? (widget.steps >= 10 ? 12.5 : 14)
                      : (widget.steps >= 10 ? 9.5 : 11),
                  fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                  color: color,
                  height: 1.0,
                  decoration: isCancelled ? TextDecoration.lineThrough : null,
                ),
              ),
              // 步骤之间用 → 连接（最后一个不加）
              if (i != widget.steps - 1)
                Padding(
                  padding: const EdgeInsets.only(left: 1),
                  child: Text(
                    '→',
                    style: TextStyle(
                      fontSize: widget.steps >= 10 ? 7.5 : 8.5,
                      color: widget.dim.withValues(alpha: 0.5),
                      height: 1.0,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        track,
        const SizedBox(width: 5),
        Text(
          '${widget.doneCount}/${widget.steps}',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            // 等宽数字：done/total 逐位跳变时整行不抖
            fontFeatures: const [FontFeature.tabularFigures()],
            color: widget.doneCount >= widget.steps ? _kDoneGreen : widget.dim,
          ),
        ),
      ],
    );
  }
}

