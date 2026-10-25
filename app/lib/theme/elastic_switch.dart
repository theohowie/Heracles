import 'package:flutter/material.dart';

import 'app_theme.dart';

/// 弹性开关（2026-10-25 晚用户定：全应用的开关都用这种弹性款）。
///
/// 形态：50×30 轨道 + 26 圆钮。切换时圆钮沿运动方向**拉长成果冻**
/// （宽度最多 +38%，中程最胖）、末端带一点回弹再落位；轨道色随
/// 进度在关（灰）与开（正文黑）之间渐变。支持点按与横向拖动
/// （拖过中点即翻转）。新开关一律用它，不要再用 CupertinoSwitch。
class ElasticSwitch extends StatefulWidget {
  const ElasticSwitch({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

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
    _animateTo(target);
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
                _animateTo(target);
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
