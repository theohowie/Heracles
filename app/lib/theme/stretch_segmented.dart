import 'package:flutter/material.dart';

/// **弹性分段选择条**（2026-10-26，用户按 TRAE 参考图定）:
///
/// 两种切换都有流体感，但**选中块永远约一格宽**：
/// - **点选**：选中块滑向目标，中途朝运动方向轻轻拉长一点
///   （最多 +0.35 格，sin 形包络，起落都回到一格）；
/// - **按住拖动**：块跟手指走（按格中心对齐），拖得越远拉伸
///   越明显但封顶 +0.3 格；松手吸附到最近的格并提交。
///
/// ★ 旧版（同日早先）是「一缘锚定、另一缘跟手」的跨度模型，拖
/// 远了块会拉成三四格宽 —— 用户实报「怎么可以变这么长？拉长
/// 一点点就好了」。现版改为「位置 + 凸起」模型：位置连续移动，
/// 宽度 = 1 格 + 有上限的凸起，方向朝运动方向。
///
/// 禁用档（如协议不支持的思考档位）：字色变淡，点选不响应、
/// 拖动不吸附、预览不点亮。
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
    this.disabled = const {},
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

  /// 不可用的档位下标：渲染变淡，且点选/拖动都不能落上去。
  final Set<int> disabled;

  @override
  State<StretchSegmented> createState() => _StretchSegmentedState();
}

class _StretchSegmentedState extends State<StretchSegmented>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  /// 块的左缘位置（格单位，可为分数）；静止时 == selected。
  late double _pos;

  /// 宽度凸起（格单位，0 = 正好一格）。
  double _bulge = 0;

  /// 凸起朝向：+1 向右长，-1 向左长（与运动方向一致）。
  double _dir = 1;

  // 飞行（点选/吸附）参数
  double _flyFrom = 0;
  double _flyDest = 0;

  // 拖动态
  double _segW = 0;
  bool _dragging = false;
  int _dragAnchor = 0;

  @override
  void initState() {
    super.initState();
    _pos = widget.selected.toDouble();
    _flyFrom = _flyDest = _pos;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    )..addListener(() {
        final t = Curves.easeOutCubic.transform(_ctrl.value);
        setState(() {
          _pos = _flyFrom + (_flyDest - _flyFrom) * t;
          // 凸起包络：中途最长，两头归零
          _bulge = (1 - (2 * _ctrl.value - 1).abs()) * 0.35;
        });
      });
  }

  @override
  void didUpdateWidget(StretchSegmented old) {
    super.didUpdateWidget(old);
    if (widget.selected != old.selected) _flyTo(widget.selected);
  }

  void _flyTo(int target) {
    _flyFrom = _pos;
    _flyDest = target.toDouble();
    if (_flyDest != _flyFrom) _dir = _flyDest > _flyFrom ? 1 : -1;
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
    _dragAnchor = widget.selected;
    _dragUpdate(d.localPosition.dx);
  }

  void _dragUpdate(double x) {
    if (_segW <= 0) return;
    final n = widget.labels.length;
    // 块心跟手指：左缘 = 手指格位 − 0.5，夹在 [0, n−1]
    final p = (x / _segW - 0.5).clamp(0.0, (n - 1).toDouble());
    setState(() {
      if (p != _pos) _dir = p > _pos ? 1 : -1;
      _pos = p;
      // 拉伸随拖离锚点的距离长，封顶 0.3 格
      _bulge = ((_pos - _dragAnchor).abs() * 0.18).clamp(0.0, 0.30);
    });
  }

  void _dragEnd() {
    // ★ 纯点击时拖动识别器被竞技场取消也会回调 cancel —— 没真正
    // 开始过拖动就直接忽略，否则会拿残值误报一个档位（实测：
    // 点已选档会多出一次 index 0 的回调）。
    if (!_dragging) return;
    _dragging = false;
    final target = _pos.round().clamp(0, widget.labels.length - 1);
    if (target != widget.selected && !widget.disabled.contains(target)) {
      widget.onSelected(target); // 父级改 selected → didUpdateWidget 吸附
    } else {
      _flyTo(widget.selected); // 禁用档或原地：弹回当前档
    }
  }

  @override
  Widget build(BuildContext context) {
    // 预览点亮：拖动时亮块正覆盖的格（禁用格不亮，仍亮当前档）
    var effective = widget.selected;
    if (_dragging) {
      final t = _pos.round().clamp(0, widget.labels.length - 1);
      if (!widget.disabled.contains(t)) effective = t;
    }
    // 块的实际矩形：向左长时左缘要再往左让出凸起
    final leftSegs = _dir < 0 ? _pos - _bulge : _pos;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: widget.trackColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          _segW = c.maxWidth / widget.labels.length;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final i = _indexAt(d.localPosition.dx);
              if (widget.disabled.contains(i)) return;
              if (i != widget.selected) widget.onSelected(i);
            },
            onHorizontalDragStart: _dragStart,
            onHorizontalDragUpdate: (d) => _dragUpdate(d.localPosition.dx),
            onHorizontalDragEnd: (_) => _dragEnd(),
            onHorizontalDragCancel: _dragEnd,
            // ★ 边界硬裁剪（2026-10-26 用户令「滑块到了边界就不能
            // 超出去」）：同心圆角只是算术保证，真机上旧实现照样
            // 鼓出过。轨道内层套 ClipRRect（半径 = 轨 14 − 内衬 4
            // = 10，与滑块角重合）——滑块在飞行/凸起/拖拽任何一帧
            // 画出内界，都会被裁掉，这是结构保证，不靠半径算对。
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
              children: [
                Positioned(
                  left: leftSegs * _segW,
                  width: (1 + _bulge) * _segW,
                  top: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: widget.blockColor,
                      borderRadius: BorderRadius.circular(10),
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
                              color: widget.disabled.contains(i)
                                  ? widget.labelColor
                                      .withValues(alpha: 0.35)
                                  : (i == effective
                                      ? widget.selectedLabelColor
                                      : widget.labelColor),
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
            ),
          );
        },
      ),
    );
  }
}
