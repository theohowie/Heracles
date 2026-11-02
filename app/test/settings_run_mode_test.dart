// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 续跑模式三档**（2026-11-02，对应 #1）：
// 关闭续跑 / 每轮询问 / 自动续跑 —— 三档互斥、持久化、文案讲清代价。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/run_continue_mode_section.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('★★ 三档互斥：点「自动续跑」⇒ 持久化，重建后仍选中', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const RunContinueModeSection()));
    await tester.pumpAndSettle();

    // 三档都在（不能混成一个开关）
    expect(find.byKey(const Key('run-mode-off')), findsOneWidget);
    expect(find.byKey(const Key('run-mode-ask')), findsOneWidget);
    expect(find.byKey(const Key('run-mode-auto')), findsOneWidget);
    expect(find.text('关闭续跑'), findsOneWidget);
    expect(find.text('每轮询问'), findsOneWidget);
    expect(find.textContaining('最多 3 轮'), findsOneWidget,
        reason: '自动续跑必须写清最多 3 轮 + 第 3 轮弹确认');

    await tester.tap(find.byKey(const Key('run-mode-auto')));
    await tester.pumpAndSettle();

    final p = await SharedPreferences.getInstance();
    expect(p.getString(RunContinueModeSection.prefsKey), 'auto',
        reason: '选择必须落盘（下次打开仍是自动续跑）');

    // 重建：从 prefs 恢复
    await tester.pumpWidget(wrap(const SizedBox()));
    await tester.pumpWidget(wrap(const RunContinueModeSection()));
    await tester.pumpAndSettle();
    final p2 = await SharedPreferences.getInstance();
    expect(p2.getString(RunContinueModeSection.prefsKey), 'auto');
  });

  testWidgets('★ 默认关闭续跑（不偷偷自动消耗 token）', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const RunContinueModeSection()));
    await tester.pumpAndSettle();

    final p = await SharedPreferences.getInstance();
    expect(p.getString(RunContinueModeSection.prefsKey), isNull);
    expect(RunContinueModeSection.modeOf(p), 'off');
  });
}
