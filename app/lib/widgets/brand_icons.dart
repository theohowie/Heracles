import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// **品牌 / 专用图标**（Cupertino 字库里没有、又不能将就的两个）。
///
/// ## GitHub 猫（2026-10-27 用户指定）
/// 输入条「连接 Github」原来用的是通用链接图标，用户点名要
/// GitHub 的猫猫（Octocat）官方标记 —— simple-icons 的标准路径，
/// 单色填充，颜色由调用方给（跟随文字色）。
class GitHubIcon extends StatelessWidget {
  const GitHubIcon({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  static const _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"/></svg>''';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      _svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

/// **git 分支图标**（2026-10-27 用户报：原来的 arrow_branch 与
/// 分享/分支箭头长得一模一样，分不清）。
///
/// 画的是 git-branch 的标准象形：左列上下两个节点 + 右上一个节点，
/// 竖线连左列、弧线从右上节点弯到左下节点（Lucide git-branch 几何，
/// 24 网格描边风）。与任何箭头形图标都不会混。
class GitBranchIcon extends StatelessWidget {
  const GitBranchIcon({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _GitBranchPainter(color),
    );
  }
}

class _GitBranchPainter extends CustomPainter {
  const _GitBranchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Offset p(double x, double y) => Offset(x * k, y * k);

    // 竖线：左列两节点之间
    canvas.drawLine(p(6, 9), p(6, 15), paint);
    // 弧线：右上节点 (18,6) 底部弯到左下节点 (6,18) 右侧
    // —— 圆心 (9,9)、半径 9 的四分之一圆弧
    canvas.drawArc(
      Rect.fromCircle(center: p(9, 9), radius: 9 * k),
      0,
      3.141592653589793 / 2,
      false,
      paint,
    );
    // 三个节点（描边圆）
    for (final c in [p(6, 6), p(6, 18), p(18, 6)]) {
      canvas.drawCircle(c, 3 * k, paint);
    }
  }

  @override
  bool shouldRepaint(_GitBranchPainter oldDelegate) =>
      oldDelegate.color != color;
}
