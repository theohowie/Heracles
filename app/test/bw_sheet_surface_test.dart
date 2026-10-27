import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/widgets/bw_approval.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/theme/app_theme.dart';

/// 回归钉（2026-10-27 真机 bug「上拉抽屉就字动」）：
///
/// 旧版抽屉的可见表面由 showModalBottomSheet 的 backgroundColor 画，
/// 不在 BwSheetShell 的 Transform 里 —— 拖拽时只有内容在动、白卡不动，
/// 标题飘出卡外。修复后表面（Container）进了 Transform：
/// 本测试拖住抽屉不放，断言**标题与表面的位移量相等**（一起动）。
void main() {
  testWidgets('抽屉拖拽时标题与表面一起动（位移相等）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildHeraclesTheme(dark: false),
      builder: (context, inner) => HueScope(
        hue: Hue.forDark(false, 0xFFFF7A45),
        child: inner ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () => showApprovalModeSheet(
                ctx,
                current: PermissionMode.manual,
                onPicked: (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    // 入场：modal 自带滑入 + 壳的弹簧，逐帧推进到静止
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('审批模式'), findsOneWidget);

    // 表面 = BwSheetShell 内最外层的带装饰 Container（其余匹配是卡片等子孙）
    final surfaceFinder = find
        .descendant(
          of: find.byType(BwSheetShell),
          matching: find.byWidgetPredicate(
            (w) => w is Container && w.decoration is BoxDecoration,
          ),
        )
        .first;
    expect(surfaceFinder, findsOneWidget);

    final titleBefore = tester.getTopLeft(find.text('审批模式'));
    final surfaceBefore = tester.getTopLeft(surfaceFinder);

    // 在抽屉上按下并下拖 70px、不松手（停在位移状态）
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('审批模式')),
    );
    for (var i = 0; i < 7; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }

    final titleDelta =
        tester.getTopLeft(find.text('审批模式')).dy - titleBefore.dy;
    final surfaceDelta = tester.getTopLeft(surfaceFinder).dy - surfaceBefore.dy;

    expect(titleDelta, greaterThan(30), reason: '标题应随拖拽下移');
    expect(surfaceDelta, closeTo(titleDelta, 0.5),
        reason: '表面必须与标题同位移（一起动），旧版表面位移为 0');

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
  });
}
