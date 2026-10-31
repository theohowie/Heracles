// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **上拉抽屉统一抓手**（2026-10-31 用户定版，T2-4）。
//
// 规格：36×4、pill 圆角、`h.border`、顶部/底部间距统一，由 `BwSheetShell`
// 默认渲染（`showHandle: true`）。各抽屉**不许再自绘**抓手 ——
// 见 `test/sheet_handle_guard_test.dart`（源码级防回归）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  final hue = Hue.darkHue;

  testWidgets('★★ 壳默认渲染统一抓手：36×4、pill、h.border、只有一个', (tester) async {
    await tester.pumpWidget(wrap(BwSheetShell(
      onDismissRequest: () {},
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Text('内容'),
      ),
    )));
    await tester.pump();

    expect(find.byType(BwSheetHandle), findsOneWidget,
        reason: 'BwSheetShell 必须默认渲染统一抓手（否则各抽屉各画各的）');

    final box = tester.getSize(find.byType(BwSheetHandle).last);
    // 抓手本体是 36×4（外面那层 Padding 不计入尺寸断言）
    final handleContainer = find.descendant(
      of: find.byType(BwSheetHandle),
      matching: find.byType(Container),
    );
    expect(handleContainer, findsOneWidget);
    final size = tester.getSize(handleContainer);
    expect(size.width, BwSheetHandle.width, reason: '抓手宽必须 36');
    expect(size.height, BwSheetHandle.height, reason: '抓手高必须 4');
    expect(box.width, greaterThanOrEqualTo(36));

    final deco = tester.widget<Container>(handleContainer).decoration
        as BoxDecoration;
    expect(deco.color, hue.border, reason: '抓手颜色 = h.border');
    expect(deco.borderRadius, BorderRadius.circular(HRadius.pill),
        reason: 'pill 圆角');
  });

  testWidgets('★ showHandle:false ⇒ 不渲染抓手（仅极少数自带头部的抽屉）',
      (tester) async {
    await tester.pumpWidget(wrap(BwSheetShell(
      onDismissRequest: () {},
      showHandle: false,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Text('内容'),
      ),
    )));
    await tester.pump();

    expect(find.byType(BwSheetHandle), findsNothing);
  });
}
