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
        curve: _kFluidCurve,
        alignment: Alignment.topCenter,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 520),
          curve: _kFluidCurve,
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
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
                  if (!widget.collapsed) ...[
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
        Text(
          '$label $valueText',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: color,
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
          Row(
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
