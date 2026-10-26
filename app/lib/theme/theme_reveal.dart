import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// **深浅切换圆形扩散**（2026-10-26，用户定）：
///
/// 点深色模式后，新配色以点击点为圆心一圈扩散铺满全屏；切回浅色
/// 时沿原路收回（旧配色缩回点击点）。实现是经典的快照圆揭：
/// 先把当前界面截一张图 → 底层瞬间换上新主题 → 旧图盖在最上层，
/// 用一个圆把旧图「挖洞」（扩散）或「只留圆内」（收回），圆的
/// 半径动画走完后撤掉旧图。截不到图（测试环境等）时直接切换。
class ThemeReveal {
  ThemeReveal._();

  static final instance = ThemeReveal._();

  /// 包住整个 App 内容的截图边界（ThemeRevealHost 持有）
  final boundaryKey = GlobalKey();

  Future<void> Function(Offset center, VoidCallback apply, bool toDark)?
      _handler;

  void registerHandler(
      Future<void> Function(Offset center, VoidCallback apply, bool toDark)
          handler) {
    _handler = handler;
  }

  /// [center] = 点击位置（全局坐标）；[apply] = 真正切换设置的动作；
  /// [toDark] = 目标是否为深色（决定扩散还是收回）。
  Future<void> reveal(Offset center, VoidCallback apply,
      {required bool toDark}) async {
    final h = _handler;
    if (h == null) {
      apply();
      return;
    }
    await h(center, apply, toDark);
  }
}

class ThemeRevealHost extends StatefulWidget {
  const ThemeRevealHost({super.key, required this.child});

  final Widget child;

  @override
  State<ThemeRevealHost> createState() => _ThemeRevealHostState();
}

class _ThemeRevealHostState extends State<ThemeRevealHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 680),
  );

  ui.Image? _img;
  Offset _center = Offset.zero;
  Size _size = Size.zero;
  double _maxR = 0;
  bool _toDark = true;

  @override
  void initState() {
    super.initState();
    ThemeReveal.instance.registerHandler(_run);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _img?.dispose();
    super.dispose();
  }

  Future<void> _run(Offset center, VoidCallback apply, bool toDark) async {
    final ctx = ThemeReveal.instance.boundaryKey.currentContext;
    final ro = ctx?.findRenderObject();
    ui.Image? img;
    if (ro is RenderRepaintBoundary) {
      try {
        final dpr = View.of(ctx!).devicePixelRatio;
        img = await ro.toImage(pixelRatio: dpr);
      } catch (_) {
        img = null;
      }
    }
    if (img == null || ro is! RenderRepaintBoundary) {
      img?.dispose();
      apply();
      return;
    }
    apply(); // 底层先换上新主题，旧图随后盖上做圆揭
    if (!mounted) {
      img.dispose();
      return;
    }
    final size = ro.size;
    final corners = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ];
    setState(() {
      _img?.dispose();
      _img = img;
      _center = center;
      _size = size;
      _toDark = toDark;
      _maxR = corners.map((c) => (c - center).distance).reduce(math.max);
    });
    await _ctrl.forward(from: 0);
    if (mounted) {
      setState(() => _img = null);
    }
    img.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RepaintBoundary(
          key: ThemeReveal.instance.boundaryKey,
          child: widget.child,
        ),
        if (_img != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) {
                  final t = Curves.easeInOutCubic.transform(_ctrl.value);
                  // 扩散：洞半径 0→maxR；收回：圆半径 maxR→0
                  final r = _toDark ? _maxR * t : _maxR * (1 - t);
                  return CustomPaint(
                    painter: _RevealPainter(
                      image: _img!,
                      center: _center,
                      radius: r,
                      size: _size,
                      expand: _toDark,
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _RevealPainter extends CustomPainter {
  _RevealPainter({
    required this.image,
    required this.center,
    required this.radius,
    required this.size,
    required this.expand,
  });

  final ui.Image image;
  final Offset center;
  final double radius;
  final Size size;

  /// true = 旧图挖洞（新主题从洞里扩散）；false = 旧图只留在圆内
  final bool expand;

  @override
  void paint(Canvas canvas, Size _) {
    final rect = Offset.zero & size;
    final circle = Path()
      ..addOval(Rect.fromCircle(center: center, radius: math.max(radius, 0.1)));
    final Path clip;
    if (expand) {
      clip = Path.combine(
        PathOperation.difference,
        Path()..addRect(rect),
        circle,
      );
    } else {
      clip = circle;
    }
    canvas.save();
    canvas.clipPath(clip);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint(),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RevealPainter old) =>
      old.image != image || old.radius != radius || old.expand != expand;
}
