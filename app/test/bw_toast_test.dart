import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';

/// **毛玻璃轻提示回归测试**（2026-10-28，D 案落地时补）。
///
/// 钉住：点触发后胶囊带着文案出现（BackdropFilter 毛玻璃层在树上）、
/// 停留约 2.2 秒后自动淡出移除；带图标时图标与文案同现。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child, {bool dark = false}) => MaterialApp(
        theme: buildHeraclesTheme(dark: dark),
        builder: (context, inner) => HueScope(
          hue: dark ? Hue.darkHue : Hue.lightHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      );

  Widget host({IconData? icon}) => Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: GestureDetector(
              onTap: () => showIosToast(
                context,
                '语音识别还没接入，这个按钮先占位',
                icon: icon,
              ),
              child: const Text('触发'),
            ),
          ),
        ),
      );

  testWidgets('轻提示：出现 → 停留 → 自动消失', (tester) async {
    await tester.pumpWidget(wrap(host()));
    await tester.tap(find.text('触发'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('语音识别还没接入，这个按钮先占位'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    // 黄线回归钉：Overlay 里无 Material 祖先，文案样式必须显式
    // decoration.none，否则框架兜底样式会给文字垫黄色双下划线。
    final toastText =
        tester.widget<Text>(find.text('语音识别还没接入，这个按钮先占位'));
    expect(toastText.style?.decoration, TextDecoration.none);
    // 2.2 秒停留 + 0.2 秒淡出之后应被移除
    await tester.pump(const Duration(milliseconds: 2500));
    await tester.pumpAndSettle();
    expect(find.text('语音识别还没接入，这个按钮先占位'), findsNothing);
  });

  testWidgets('轻提示：带图标时图标同现（深色）', (tester) async {
    await tester.pumpWidget(wrap(host(icon: AppIcons.mic), dark: true));
    await tester.tap(find.text('触发'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(AppIcons.mic), findsOneWidget);
    expect(find.text('语音识别还没接入，这个按钮先占位'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2500));
    await tester.pumpAndSettle();
  });
}
