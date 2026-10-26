import 'package:flutter/material.dart';

/// **弹性微缩按压反馈**（2026-10-26，用户定：所有点击式按钮都要）：
///
/// 按压瞬间缩到 0.96 并伴随顶部内阴影微微加深，松手时轻微冲过头
/// 再回弹（easeOutBack），按起来扎实有触感。
///
/// 只用 Listener 观察指针、**不注册手势识别器** —— 子级自己的
/// onTap / InkWell / CupertinoButton 行为完全不受影响，哪里需要
/// 套哪里。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.borderRadius,
    this.enabled = true,
  });

  final Widget child;

  /// 给内阴影罩层用的圆角（与子级外形一致）；null = 不加罩层
  final BorderRadius? borderRadius;
  final bool enabled;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _set(bool v) {
    if (widget.enabled && _pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: Duration(milliseconds: _pressed ? 90 : 280),
        curve: _pressed ? Curves.easeOut : Curves.easeOutBack,
        child: widget.borderRadius == null
            ? widget.child
            : Stack(
                children: [
                  widget.child,
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        decoration: BoxDecoration(
                          borderRadius: widget.borderRadius,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.center,
                            colors: [
                              Colors.black
                                  .withValues(alpha: _pressed ? 0.10 : 0.0),
                              Colors.transparent,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
