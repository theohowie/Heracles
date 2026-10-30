// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **输入框主按钮三态**的回归测试（2026-10-29 用户报「不可以排队发送」）。
//
// 规格（`input_bar.dart` 的 `_SendButton` 注释）：
//   · 忙 + 输入框**有**内容 → **发送**（这条会排队/插话，不是停止）
//   · 忙 + 无内容 + 当前会话在跑 → **停止**
//   · 忙 + 无内容 + 别的会话在跑 → **沙漏**
//   · 空闲 → 发送
//
// ⚠️ 断言必须**打在按钮本身**（按图标定位并点它），
//    不能用 `find.byType(InkWell).last` —— 那种写法会点到别的可点区域，
//    "什么都没发生"也能让测试看起来跑过了（教训：断言不得测错对象）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';
import 'package:heracles/widgets/input_bar.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        home: Scaffold(
          body: HueScope(hue: Hue.darkHue, child: child),
        ),
      );

  testWidgets('★★ 忙时有文字 ⇒ 按钮是「发送」，点它走 onSend（排队）而不是 onStop',
      (tester) async {
    final sent = <String>[];
    var stopped = 0;
    final ctrl = TextEditingController();

    await tester.pumpWidget(wrap(InputBar(
      onSend: sent.add,
      onStop: () => stopped++,
      busy: true,
      stopLabel: true,
      inputController: ctrl,
    )));
    await tester.pump(const Duration(milliseconds: 300));

    // 基线：忙 + 空输入 ⇒ 停止图标
    expect(find.byIcon(AppIcons.stop), findsOneWidget,
        reason: '忙 + 空输入应当显示停止');

    // 输入文字（直接给 controller 赋值：无头环境 enterText 要不到焦点）
    ctrl.text = '顺便再跑一下 ls';
    await tester.pump(const Duration(milliseconds: 200));

    // 关键断言：图标必须变回发送
    expect(find.byIcon(AppIcons.send), findsOneWidget,
        reason: '★★ 有内容后必须变回发送图标 —— 否则用户点下去会变成"停止运行"');
    expect(find.byIcon(AppIcons.stop), findsNothing);

    // 点**发送图标本身**
    await tester.tap(find.byIcon(AppIcons.send));
    await tester.pump(const Duration(milliseconds: 200));

    expect(sent, ['顺便再跑一下 ls'],
        reason: '★ 忙时点发送应当把文本交出去排队');
    expect(stopped, 0, reason: '★★ 不许把"排队发送"变成"停止运行"');
  });

  testWidgets('★ 忙 + 空输入 ⇒ 点按钮是停止（不能被上一条改坏）', (tester) async {
    final sent = <String>[];
    var stopped = 0;

    await tester.pumpWidget(wrap(InputBar(
      onSend: sent.add,
      onStop: () => stopped++,
      busy: true,
      stopLabel: true,
    )));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byIcon(AppIcons.stop));
    await tester.pump(const Duration(milliseconds: 200));

    expect(stopped, 1);
    expect(sent, isEmpty);
  });

  testWidgets('★★ 排队行有「编辑」入口，点它交出该条下标（2026-10-30）',
      (tester) async {
    final edited = <int>[];
    final sentNow = <int>[];

    await tester.pumpWidget(wrap(InputBar(
      onSend: (_) {},
      queuedTexts: const ['排队原文'],
      onQueuedEdit: edited.add,
      onQueuedSendNow: sentNow.add,
    )));
    await tester.pump(const Duration(milliseconds: 300));

    // 排队行必须能看到「编辑」按钮（旧实现只有 置顶/删除/立即发送）
    expect(find.byTooltip('编辑'), findsOneWidget,
        reason: '正在排队的消息必须能就地编辑');
    await tester.tap(find.byTooltip('编辑'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(edited, [0], reason: '点第 1 条必须交出下标 0');
    expect(sentNow, isEmpty, reason: '编辑 ≠ 立即发送');
  });
}
