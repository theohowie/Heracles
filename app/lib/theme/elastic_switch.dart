import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 弹性开关（2026-10-25 晚用户定：全应用的开关都用这种弹性款）。
///
/// 形态：50×30 轨道 + 26 圆钮。切换时圆钮沿运动方向**拉长成果冻**
/// （宽度最多 +38%，中程最胖）、末端带一点回弹再落位；轨道色随
/// 进度在关（灰）与开（正文黑）之间渐变。支持点按与横向拖动
/// （拖过中点即翻转）。新开关一律用它，不要再用 CupertinoSwitch。
class ElasticSwitch extends StatefulWidget {
  const ElasticSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.optimistic = true,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// **是否乐观预演**（2026-10-29 新增，默认 true = 原有行为）。
  ///
  /// true：点按/拖动结束立刻把圆钮动画到目标位置，再回调 onChanged ——
  /// 适合"本地状态说了算"的开关（设置项、抽屉选项）。
  ///
  /// false：**只回调、不动画**，视觉等父级 `value` 变化后在
  /// `didUpdateWidget` 里对齐 —— 适合"真实值只能查询确认"的开关
  /// （设备权限页）。否则会出现权限页的假状态：App 根本无权撤销
  /// 运行时权限，预演出来的"已关"会一直骗用户到页面重建
  /// （2026-10-29 用户反馈：关麦克风后开关显示关，实际没关）。
  final bool optimistic;

  @override
  State<ElasticSwitch> createState() => _ElasticSwitchState();
}

class _ElasticSwitchState extends State<ElasticSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );

  /// 动画的起止位置（0 = 关，1 = 开）
  double _from = 0;
  double _to = 0;

  /// 拖动中的即时位置（非 null = 正在拖）
  double? _dragPos;

  @override
  void initState() {
    super.initState();
    _from = _to = widget.value ? 1 : 0;
    _c.value = 1;
  }

  @override
  void didUpdateWidget(ElasticSwitch old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _animateTo(widget.value ? 1 : 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double get _pos {
    if (_dragPos != null) return _dragPos!;
    final t = Curves.easeOutCubic.transform(_c.value);
    return _from + (_to - _from) * t;
  }

  /// 果冻拉伸量：动画中程最胖（sin 峰），静止为 0
  double get _stretch {
    if (_dragPos != null || !_c.isAnimating) return 0;
    return 0.38 * (1 - (2 * _c.value - 1).abs()).clamp(0.0, 1.0) *
        (1 - _c.value * 0.15);
  }

  void _animateTo(double target) {
    _from = _pos;
    _to = target;
    _c.forward(from: 0);
  }

  void _toggle() {
    final target = widget.value ? 0.0 : 1.0;
    // 非乐观：不预演动画（视觉只跟父级真值走），但仍如实回调用户意图
    if (widget.optimistic) _animateTo(target);
    widget.onChanged?.call(target == 1);
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final enabled = widget.onChanged != null;
    return Semantics(
      toggled: widget.value,
      button: true,
      enabled: enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? _toggle : null,
        onHorizontalDragStart: enabled
            ? (_) {
                _c.stop();
                _dragPos = _pos;
              }
            : null,
        onHorizontalDragUpdate: enabled
            ? (d) {
                setState(() {
                  _dragPos = ((_dragPos ?? _pos) + d.delta.dx / 20)
                      .clamp(0.0, 1.0);
                });
              }
            : null,
        onHorizontalDragEnd: enabled
            ? (_) {
                final pos = _dragPos ?? _pos;
                _dragPos = null;
                final target = pos > 0.5 ? 1.0 : 0.0;
                if (widget.optimistic) {
                  _animateTo(target);
                } else {
                  // 非乐观：松开就落回父级真实值（不预演）；真值变了
                  // 由 didUpdateWidget 负责动画过去。
                  setState(() {});
                }
                if ((target == 1) != widget.value) {
                  widget.onChanged?.call(target == 1);
                }
              }
            : null,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final pos = _pos;
            final track = Color.lerp(h.surface, h.text, pos)!;
            final knobW = 26 * (1 + _stretch);
            final cx = 15 + 20 * pos; // 圆钮中心：15（关）→ 35（开）
            return Opacity(
              opacity: enabled ? 1 : 0.45,
              child: SizedBox(
                width: 50,
                height: 30,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: track,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    Positioned(
                      left: cx - knobW / 2,
                      top: 2,
                      child: Container(
                        width: knobW,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Color.lerp(h.surfaceAlt, h.bg, pos),
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.22),
                              blurRadius: 5,
                              offset: const Offset(0, 1.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
