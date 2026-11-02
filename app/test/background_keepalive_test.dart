// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 后台保活引导卡**（2026-11-02，对应 #2/T0）：
// 只做状态与引导，不实现保活；必须写明「Android 不保证永不被杀」。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/background_keepalive_card.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('★★ 三行状态 + 三入口 + 必须写明"不保证永不被杀"', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    expect(find.text('后台运行'), findsOneWidget);
    expect(find.text('前台服务'), findsOneWidget);
    expect(find.text('电池优化'), findsOneWidget);
    expect(find.text('自启动'), findsOneWidget);
    // 无接口 ⇒ 如实"未检测到"，不编"已开启"
    expect(find.textContaining('未检测到'), findsWidgets);
    expect(find.text('申请忽略电池优化'), findsOneWidget);
    expect(find.text('打开本应用电池设置'), findsOneWidget);
    expect(find.text('打开自启动管理'), findsOneWidget);
    expect(find.textContaining('Android 不保证永不被杀'), findsOneWidget,
        reason: '文案必须讲清系统仍可能停止后台任务');
  });

  testWidgets('★ 上次被系统停止 ⇒ 下次打开如实提示（不许假装还在跑）',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      BackgroundKeepaliveCard.prefsLastKilled: '今天 09:12',
      BackgroundKeepaliveCard.prefsBatteryIgnored: true,
    });
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background-last-killed')), findsOneWidget);
    expect(find.textContaining('上次任务在后台被系统停止'), findsOneWidget);
    expect(find.textContaining('已忽略'), findsOneWidget);
  });
}
