// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **灵动岛展开/收起崩溃的回归测试**（2026-10-29 真机红屏）。
//
// ## 崩的是什么
//
// 用户点开待办 → 再收起 → 弹红屏：
//
// ```
// BoxConstraints has a negative minimum width.
// The offending constraints were:
// BoxConstraints(-0.7<=w<=280.0, 0.0<=h<=Infinity; NOT NORMALIZED)
// ```
//
// 根因：`_kFluidCurve = Cubic(0.22, 1.18, 0.36, 1.0)` 的 y1=1.18 **会过冲**，
// 而 `AnimatedContainer` 会对 `constraints` 做 `BoxConstraints.lerp`。
// 收起时 `minWidth: 168 → 0`，在 t≈1.004 处插值出
// `168 + (0-168)×1.004 ≈ -0.7` ⇒ 负 minWidth ⇒ 断言崩溃。
//
// 修法：`constraints` 里不再放 `minWidth`（只留 maxWidth），
// 最小宽度下沉到内层 `ConstrainedBox`；尺寸动画用钳制曲线。
//
// ## 这个测试怎么抓
//
// 反复展开/收起并 `pump` 到动画中间帧（过冲发生在 t≈0.5~1.0 之间），
// 任何一帧抛出负约束异常都会被 Flutter 测试框架记为失败。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_topbar.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        home: Scaffold(
          body: HueScope(hue: Hue.darkHue, child: child),
        ),
      );

  // 待办面板：5 步，第 3 步执行中
  Widget island({
    required bool collapsed,
    required VoidCallback onToggle,
  }) =>
      DynamicIsland(
        steps: const ['探测环境', '构建 APK', '签名校验', '安装到设备', '写报告'],
        doneCount: 2,
        activeIndex: 2,
        cancelledIndices: const <int>{},
        collapsed: collapsed,
        onToggle: onToggle,
      );

  testWidgets('★★★ 展开→收起→再展开 不得出现负约束（真机红屏根因）',
      (tester) async {
    var collapsed = true;
    late StateSetter setOuter;

    await tester.pumpWidget(wrap(
      StatefulBuilder(builder: (context, setState) {
        setOuter = setState;
        return island(
          collapsed: collapsed,
          onToggle: () => setState(() => collapsed = !collapsed),
        );
      }),
    ));
    await tester.pump();

    // 连续三轮 展开/收起 —— 每一轮都把动画**逐帧**推完。
    // 过冲发生在曲线 t>1 的位置，只 pump 一帧会漏掉。
    for (var round = 1; round <= 3; round++) {
      for (final target in <bool>[false, true]) {
        setOuter(() => collapsed = target);
        // 520ms 动画，每 40ms 一帧 ⇒ 13 帧，覆盖过冲区间
        for (var i = 0; i < 14; i++) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(tester.takeException(), isNull,
            reason: '第 $round 轮、collapsed=$target 时抛异常了');
      }
    }
    // 收尾：确认最终形态正常
    // ⚠️ 不用 pumpAndSettle：呼吸点是常驻动画，永远不会 settle
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(DynamicIsland), findsOneWidget);
  });

  testWidgets('★ 收起态仍有 168 最小宽度（视觉要求：短药丸不能太短）',
      (tester) async {
    await tester.pumpWidget(wrap(island(collapsed: true, onToggle: () {})));
    await tester.pump(const Duration(milliseconds: 600));

    final size = tester.getSize(find.byType(DynamicIsland));
    expect(size.width, greaterThanOrEqualTo(168),
        reason: '收起态最小宽度 168（用户对图定的）不能因为修崩溃而丢掉');
  });

  testWidgets('★ 展开态不会超过 280 最大宽度', (tester) async {
    await tester.pumpWidget(wrap(island(collapsed: false, onToggle: () {})));
    await tester.pump(const Duration(milliseconds: 600));

    final size = tester.getSize(find.byType(DynamicIsland));
    expect(size.width, lessThanOrEqualTo(280 + 0.5),
        reason: '展开态上限 280');
  });
}
