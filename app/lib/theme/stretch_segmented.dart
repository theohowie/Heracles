import 'package:flutter/material.dart';

/// **弹性分段选择条**（2026-10-26，用户按 TRAE 参考图定）：
///
/// 两种切换都有流体感：
/// - **点选**：选中块先沿切换方向拉长（朝向目标的边先走）、滑到
///   目标、再把另一条边收回——像一块果冻被拽过去。
/// - **按住拖动**（用户后续要求）：抓住选中块左右拖，块的边缘
///   实时追随手指拉伸/收缩，拖到哪个档位那个档位的字先亮起来
///   预览，松手就吸附到该档位并提交。
///
/// 实现：选中块左右缘以「段」为单位记位（_a/_b，可为分数）。
/// 点选动画时领边走 Interval(0–0.55)、跟边走 Interval(0.35–1)
/// 错峰成拉伸；拖动时以按下瞬间的档位跨度为锚，朝向手指的那条
/// 边直接跟手指走。松手由父级改 selected 触发 _animateTo 从
/// 当前分数位置平滑吸附，中途改选不跳变。
///
/// 通用设置的分段胶囊与模型抽屉的 _SegBar 共用这一份实现，
/// 只换皮（黑块 / 白块＋投影）。
class StretchSegmented extends StatefulWidget {
  const StretchSegmented({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    required this.trackColor,
    required this.blockColor,
    required this.selectedLabelColor,
    required this.labelColor,
    this.blockShadow,
    this.fontSize = 13.5,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final Color trackColor;
  final Color blockColor;
  final Color selectedLabelColor;
  final Color labelColor;
  final List<BoxShadow>? blockShadow;
  final double fontSize;

  @override
  State<StretchSegmented> createState() => _StretchSegmentedState();
}

class _StretchSegmentedState extends State<StretchSegmented>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late double _a;
  late double _b;
  Tween<double> _aTween = Tween(begin: 0, end: 0);
  Tween<double> _bTween = Tween(begin: 0, end: 0);
  Interval _aCurve = const Interval(0, 1);
  Interval _bCurve = const Interval(0, 1);

  // 拖动态：锚 = 按下瞬间的跨度；_segW 由 LayoutBuilder 回填
  double _segW = 0;
  double _anchorA = 0;
  double _anchorB = 0;
  double _lastX = 0;
  int? _dragTarget;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _a = _b = widget.selected.toDouble();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    )..addListener(() {
        setState(() {
          _a = _aTween.evaluate(CurvedAnimation(parent: _ctrl, curve: _aCurve));
          _b = _bTween.evaluate(CurvedAnimation(parent: _ctrl, curve: _bCurve));
        });
      });
  }

  @override
  void didUpdateWidget(StretchSegmented old) {
    super.didUpdateWidget(old);
    if (widget.selected != old.selected) _animateTo(widget.selected);
  }

  void _animateTo(int target) {
    final t = target.toDouble();
    _aTween = Tween(begin: _a, end: t);
    _bTween = Tween(begin: _b, end: t);
    if (t > _b) {
      _bCurve = const Interval(0, 0.55, curve: Curves.easeOutCubic);
      _aCurve = const Interval(0.35, 1, curve: Curves.easeOutCubic);
    } else if (t < _a) {
      _aCurve = const Interval(0, 0.55, curve: Curves.easeOutCubic);
      _bCurve = const Interval(0.35, 1, curve: Curves.easeOutCubic);
    } else {
      _aCurve = const Interval(0, 1, curve: Curves.easeOutCubic);
      _bCurve = const Interval(0, 1, curve: Curves.easeOutCubic);
    }
    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int _indexAt(double x) {
    if (_segW <= 0) return widget.selected;
    return (x / _segW).floor().clamp(0, widget.labels.length - 1);
  }

  void _dragStart(DragStartDetails d) {
    _dragging = true;
    _ctrl.stop();
    _anchorA = _a;
    _anchorB = _b;
    _lastX = d.localPosition.dx;
    _dragTarget = _indexAt(d.localPosition.dx);
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (_segW <= 0) return;
    _lastX = d.localPosition.dx;
    final n = widget.labels.length;
    // 手指位置换算成缘坐标：左缘 = x/segW，右缘 = x/segW − 1
    final leftEdge = (_lastX / _segW).clamp(0.0, n.toDouble());
    final rightEdge = (_lastX / _segW - 1).clamp(-1.0, (n - 1).toDouble());
    setState(() {
      if (rightEdge >= _anchorB) {
        _a = _anchorA;
        _b = rightEdge;
      } else if (leftEdge <= _anchorA) {
        _a = leftEdge;
        _b = _anchorB;
      } else {
        _a = _anchorA;
        _b = _anchorB;
      }
      _dragTarget = _indexAt(_lastX);
    });
  }

  void _dragEnd() {
    // ★ 纯点击时拖动识别器被竞技场取消也会回调 cancel —— 没真正
    // 开始过拖动就直接忽略，否则会拿 _lastX 的残值误报一个档位
    // （实测：点已选档会多出一次 index 0 的回调）。
    if (!_dragging) return;
    _dragging = false;
    final target = _indexAt(_lastX);
    setState(() => _dragTarget = null);
    if (target != widget.selected) {
      widget.onSelected(target); // 父级改 selected → didUpdateWidget 吸附
    } else {
      _animateTo(target); // 同档位：从拉伸状态弹回原位
    }
  }

  @override
  Widget build(BuildContext context) {
    final effective = _dragTarget ?? widget.selected;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: widget.trackColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          _segW = c.maxWidth / widget.labels.length;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final i = _indexAt(d.localPosition.dx);
              if (i != widget.selected) widget.onSelected(i);
            },
            onHorizontalDragStart: _dragStart,
            onHorizontalDragUpdate: _dragUpdate,
            onHorizontalDragEnd: (_) => _dragEnd(),
            onHorizontalDragCancel: _dragEnd,
            child: Stack(
              children: [
                Positioned(
                  left: _a * _segW,
                  width: (_b - _a + 1) * _segW,
                  top: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.blockColor,
                      borderRadius: BorderRadius.circular(9),
                      boxShadow: widget.blockShadow,
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < widget.labels.length; i++)
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 7),
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 120),
                            style: TextStyle(
                              fontSize: widget.fontSize,
                              fontWeight: i == effective
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: i == effective
                                  ? widget.selectedLabelColor
                                  : widget.labelColor,
                            ),
                            child: Text(
                              widget.labels[i],
                              textAlign: TextAlign.center,
                              maxLines: 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
