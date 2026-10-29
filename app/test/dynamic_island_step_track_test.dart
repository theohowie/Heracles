// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **收起态「步骤数字轨道」的规格验收**（2026-10-29 用户重定义灵动岛收起样式）。
//
// 用户原话：
//   「我现在想在收起的状态上，上面做好 1，2，3，4……最后一步。
//    当进行第一步的时候，1 数字变大，且变为黄色，做完了第一步，1 就变成绿色，
//    随之 2 变大且变成黄色，以此类推。数字和数字之间有 -> 来连接。
//    如果溢出了，那就有自动滚动的效果……把 1 向左移出灵动岛隐藏
//    （不能出现在灵动岛外面），然后把 5 展示出来。」
//
// 这个文件逐条钉住：数字都在 / 箭头连接 / 当前步变大变黄 / 已完成绿 /
// 未到暗灰 / 溢出后自动滚动 / **滚出的数字不会画到岛外**。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_topbar.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        home: Scaffold(body: Center(child: HueScope(hue: Hue.darkHue, child: child))),
      );

  Widget island({
    required bool collapsed,
    int steps = 5,
    int doneCount = 0,
    int activeIndex = 0,
  }) =>
      DynamicIsland(
        steps: List<String>.generate(steps, (i) => '步骤 ${i + 1}'),
        doneCount: doneCount,
        activeIndex: activeIndex,
        cancelledIndices: const <int>{},
        collapsed: collapsed,
        onToggle: () {},
      );

  /// 取某个数字文本的样式（先确认唯一）。
  TextStyle styleOf(WidgetTester tester, String text) {
    final t = tester.widget<Text>(find.text(text));
    return t.style!;
  }

  testWidgets('★★ 收起态铺出 1..N 的数字，且用 → 连接', (tester) async {
    await tester.pumpWidget(wrap(island(collapsed: true, steps: 5, activeIndex: 0)));
    await tester.pump(const Duration(milliseconds: 400));

    // ⚠️ ListView.builder 只构建**可见**项 ⇒ 不能要求 1..5 全在树上。
    //    视口约放 4 步，所以要求"可见数字 ≥ 3 且箭头 ≥ 2"。
    var visibleNumbers = 0;
    for (var i = 1; i <= 5; i++) {
      if (find.text('$i').evaluate().isNotEmpty) visibleNumbers++;
    }
    expect(visibleNumbers, greaterThanOrEqualTo(3),
        reason: '收起态要铺出连续的数字，不能只剩一个"几分之几"');
    expect(find.text('→'), findsAtLeastNWidgets(2), reason: '数字之间要有 → 连接');
  });

  testWidgets('★★ 当前步变大 + 变黄；已完成的变绿；未到的暗灰', (tester) async {
    await tester.pumpWidget(wrap(island(
      collapsed: true,
      steps: 5,
      doneCount: 2, // 1、2 已完成
      activeIndex: 2, // 第 3 步进行中
    )));
    await tester.pump(const Duration(milliseconds: 400));

    final done1 = styleOf(tester, '1');
    final done2 = styleOf(tester, '2');
    final active = styleOf(tester, '3');
    final todo4 = styleOf(tester, '4');

    // 已完成 = 绿
    expect(done1.color, const Color(0xFF22C55E), reason: '第 1 步做完了应变绿');
    expect(done2.color, const Color(0xFF22C55E), reason: '第 2 步做完了应变绿');

    // 当前 = 黄 + 变大
    expect(active.color, const Color(0xFFF59E0B), reason: '当前步应是黄色');
    expect(active.fontSize, greaterThan(done1.fontSize!),
        reason: '当前步数字必须**变大**');

    // 未到 = 不是绿也不是黄
    expect(todo4.color, isNot(const Color(0xFF22C55E)));
    expect(todo4.color, isNot(const Color(0xFFF59E0B)));
  });

  testWidgets('★★★ 步骤数超出视口 ⇒ 自动滚动，且滚出的数字不出岛', (tester) async {
    const steps = 12; // 远超"只放得下 4 个"
    await tester.pumpWidget(wrap(island(
      collapsed: true,
      steps: steps,
      doneCount: 10,
      activeIndex: 10, // 走在靠后的步骤 ⇒ 必须滚过去
    )));
    await tester.pump(const Duration(milliseconds: 600));

    // ① 当前步可见
    expect(find.text('11'), findsOneWidget, reason: '当前步必须被滚到可见位置');

    // ② 岛的整体位置与宽度
    final islandRect = tester.getRect(find.byType(DynamicIsland));

    // ③ **任何可见数字都不得越出岛边界**（用户："不能出现在灵动岛外面"）
    for (var i = 1; i <= steps; i++) {
      final f = find.text('$i');
      if (f.evaluate().isEmpty) continue; // 已被滚出并回收
      final r = tester.getRect(f);
      expect(r.left, greaterThanOrEqualTo(islandRect.left - 0.5),
          reason: '数字 $i 画到了岛左边外面');
      expect(r.right, lessThanOrEqualTo(islandRect.right + 0.5),
          reason: '数字 $i 画到了岛右边外面');
    }

    // ④ 前面的步骤已被滚走（1 要么消失、要么在视口左侧之外）
    final first = find.text('1');
    if (first.evaluate().isNotEmpty) {
      final r = tester.getRect(first);
      expect(r.right, lessThanOrEqualTo(islandRect.left + 60),
          reason: '走到第 11 步时，第 1 步应已滚出视口左侧');
    }
  });

  testWidgets('★ 展开态不受影响（仍是步骤全文列表）', (tester) async {
    await tester.pumpWidget(wrap(island(collapsed: false, steps: 3, doneCount: 1)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('步骤 1'), findsWidgets);
    expect(find.text('步骤 3'), findsOneWidget);
  });
}
