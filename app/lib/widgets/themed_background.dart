import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 主题背景：底色 + 可选光晕。
///
/// `Hue.glowColors` 为空时就是一层纯色底（黑白、柔雾）；
/// 非空时在底色上画三处径向光斑（左上、右上、底部），颜色来自主题，
/// 位置固定、只改背景不改布局。`CustomPaint` 在子组件**后面**画，
/// 所以光斑永远在内容底下，不会盖住文字和按钮。
class ThemedBackground extends StatelessWidget {
  const ThemedBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Container(
      color: h.bg,
      child: CustomPaint(
        painter: _GlowPainter(colors: h.glowColors, dark: h.dark),
        child: child,
      ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter({required this.colors, required this.dark});

  final List<Color> colors;
  final bool dark;

  /// 三处光斑的固定位置：左上、右上、底部居中偏左
  static const _positions = [
    Alignment(-0.85, -0.9),
    Alignment(0.9, -0.55),
    Alignment(0.1, 1.05),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (colors.isEmpty) return;
    final radius = size.shortestSide * 0.62;
    for (var i = 0; i < colors.length; i++) {
      final center = _positions[i % _positions.length].alongSize(size);
      final color = colors[i];
      final gradient = RadialGradient(
        colors: [
          color.withValues(alpha: dark ? 0.30 : 0.45),
          color.withValues(alpha: 0),
        ],
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = gradient.createShader(
            Rect.fromCircle(center: center, radius: radius),
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.colors != colors || old.dark != dark;
}
