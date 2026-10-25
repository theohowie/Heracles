import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/input_bar.dart';

/// **输入行窄屏溢出回归**（2026-10-25 真机实测）。
///
/// ## 现象
///
/// 真机（393dp 宽）输入行右侧出现 `RIGHT OVERFLOWED BY 8.0 PIXELS`
/// 黄黑条：模型名胶囊（名字上限 130 + 档位 + 箭头）加上 ＋、盾牌、
/// 发送键后总宽超过可用宽度，`Row` 没有任何一环能收缩。
///
/// ## 修法与本测试的断言
///
/// 底行给模型选择区包 `Flexible`，第一枚胶囊（模型名）内部也可收缩
/// 走省略号，第二枚（思考档位）保持完整。本测试在 360dp / 320dp
/// 两档窄宽、超长模型名、最高档位下泵入输入框，断言**无任何异常**
/// （RenderFlex 溢出会以 FlutterError 形式被测试框架捕获）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(dark: false),
        builder: (context, inner) => HueScope(
          hue: Hue.forDark(false, 0xFFFF7A45),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)),
      );

  for (final width in [393.0, 360.0, 320.0]) {
    testWidgets('★ ${width.toInt()}dp 宽 + 超长模型名 + Max 档位 → 输入行不溢出',
        (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(InputBar(
        onSend: (_) {},
        reasoningLevel: ReasoningLevel.max,
        permission: PermissionMode.fullAccess,
        providerLabel: 'deepseek-v4.1-flash-pro-very-long-name',
      )));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: '输入行在 ${width.toInt()}dp 下不应有溢出/布局异常');
      // 模型胶囊在（单枚，卡内底行）：Text 的 data 是全名，
      // 视觉截断不影响 finder —— 以此证明胶囊真渲染了
      expect(
          find.text('deepseek-v4.1-flash-pro-very-long-name'), findsOneWidget);
    });
  }
}
