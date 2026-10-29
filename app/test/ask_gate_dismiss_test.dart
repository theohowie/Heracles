// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **提问弹层（ask_user）「防误关」验收**（2026-10-29 第 4 条 P1 的后半）。
//
// ## 用户报的症状
//
// > 「提问弹层点一下外面就没了，然后就按"全部未回答"继续跑 ——
// >  我只是想把键盘收起来 / 不小心碰了一下。」
//
// ## 旧实现的洞（已核实）
//
// · 提问抽屉 `isDismissible: true` ⇒ **点遮罩**直接关 ⇒ 调用方拿到 null
//   ⇒ `replyAsk(const {})` ⇒ 全部未回答（模型以为用户拒答）；
// · **系统返回键**同样能关，且和「跳过」一样**没有任何确认**。
//
// ## 修完后的契约（本文件逐条钉住）
//
// 1. 点遮罩 ⇒ 弹层**仍在**（要关只能按钮或返回键 + 确认）；
// 2. 系统返回键 ⇒ 二次确认「放弃回答？」；确认后回传 null（= 全部未回答）
//    并轻提示「已按未回答处理」；取消 ⇒ 留在原地；
// 3. 「跳过」仍是**明确动作**：回传已答部分（这条语义不许被防误关改坏）；
// 4. 「其他…」自填拉键盘时：弹层不许消失、不许溢出（键盘重排）。
//
// 弹层本体 `showAskGateSheet` 于 2026-10-29 从 chat_screen 抽到 bw_approval.dart
// （原先内联在 300KB 聊天页里，触发它要跑通一整轮 run，无法做 widget 测试）。
// 抽离 **不改变**任何行为 —— 本文件的红/绿即在那次抽离之后采集。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(dark: false),
        builder: (context, inner) => HueScope(
          hue: Hue.forDark(false, 0xFFFF7A45),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  Future<void> settle(WidgetTester tester, {int times = 16}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  List<Map<String, dynamic>> questions() => <Map<String, dynamic>>[
        {
          'id': 'q1',
          'question': '要选哪个方案？',
          'multi': false,
          'options': [
            {'label': '方案 A', 'description': '快'},
            {'label': '方案 B', 'description': '稳'},
          ],
        },
        {
          'id': 'q2',
          'question': '是否继续？',
          'multi': true,
          'options': [
            {'label': '继续'},
          ],
        },
      ];

  /// 打开提问抽屉，返回"调用方最终拿到的答案"读取器。
  Future<Map<String, List<String>>? Function()> openSheet(
      WidgetTester tester) async {
    Map<String, List<String>>? result;
    var returned = false;
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: TextButton(
          onPressed: () async {
            result = await showAskGateSheet(ctx, questions: questions());
            returned = true;
          },
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text('模型需要你的回答'), findsOneWidget,
        reason: '前置：提问抽屉已弹出');
    return () {
      expect(returned, isTrue, reason: '前置：调用方的 await 必须已经收尾');
      return result;
    };
  }

  testWidgets('★★★ 点遮罩 ⇒ 提问弹层仍在（不许静默"全部未回答"）', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await openSheet(tester);

    // 点弹层外的上方区域（遮罩）
    await tester.tapAt(const Offset(196, 40));
    await settle(tester);

    expect(find.text('模型需要你的回答'), findsOneWidget,
        reason: '提问必须由「提交 / 跳过 / 明确放弃」收尾 —— '
            '碰一下遮罩就把整题判成未回答，是用户在真机上最容易被坑的一步');
    expect(find.textContaining('放弃回答'), findsNothing,
        reason: '点遮罩不该触发"放弃确认"（它应当完全不生效）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('★★★ 系统返回键 ⇒ 二次确认「放弃回答？」，弹层不直接关',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await openSheet(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);

    expect(find.text('模型需要你的回答'), findsOneWidget,
        reason: '返回键不许把提问弹层直接关掉（关掉 = 全部未回答）');
    expect(find.text('放弃回答？'), findsOneWidget,
        reason: '必须让用户明确知道"关掉 = 这些题按未回答处理"');
    expect(tester.takeException(), isNull);
  });

  testWidgets('★★ 确认放弃 ⇒ 回传 null + 轻提示「已按未回答处理」', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final resultOf = await openSheet(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);

    await tester.tap(find.text('放弃回答'));
    await settle(tester);

    expect(find.text('模型需要你的回答'), findsNothing, reason: '确认放弃后弹层关闭');
    expect(resultOf(), isNull,
        reason: 'null = 调用方按"全部未回答"回传 —— 绝不编答案');
    expect(find.text('已按未回答处理'), findsOneWidget,
        reason: '关闭后要给用户一句交代（不能静默）');

    // 轻提示 2.2s 后淡出 —— 把定时器走完，否则测试结束时报 pending timer
    await settle(tester, times: 60);
  });

  testWidgets('★★ 取消放弃 ⇒ 弹层仍在，题目原样', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await openSheet(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);

    await tester.tap(find.text('继续回答'));
    await settle(tester);

    expect(find.text('模型需要你的回答'), findsOneWidget);
    expect(find.text('要选哪个方案？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('★★ 「跳过」仍是明确动作：回传已答部分（不许被防误关改坏）',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final resultOf = await openSheet(tester);

    // 第 1 题选一个选项（单选 ⇒ 自动跳第 2 题）
    await tester.tap(find.text('方案 B'));
    await settle(tester);
    expect(find.text('是否继续？'), findsOneWidget, reason: '单选应自动跳下一题');

    await tester.tap(find.text('跳过'));
    await settle(tester);

    final r = resultOf();
    expect(r, isNotNull, reason: '跳过是明确动作 ⇒ 不能返回 null');
    expect(r!['q1'], ['方案 B'], reason: '已答的题必须如实回传，别浪费用户的选择');
    expect(r.containsKey('q2'), isFalse, reason: '没答的题不进 map（= 未回答）');
  });

  testWidgets('★★ 「其他…」自填拉键盘：弹层不消失、不溢出（键盘重排）',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await openSheet(tester);

    await tester.tap(find.text('其他…'));
    await settle(tester);
    expect(find.text('在这里填写你的回答…'), findsOneWidget);

    // 键盘弹起（真机上 viewInsets.bottom ≈ 300pt）
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 3);
    addTearDown(tester.view.resetViewInsets);
    await settle(tester);

    expect(find.text('模型需要你的回答'), findsOneWidget,
        reason: '键盘重排不许把弹层顶没');
    expect(find.text('在这里填写你的回答…'), findsOneWidget,
        reason: '自填框必须仍可见（否则用户没法输入）');
    expect(tester.takeException(), isNull,
        reason: '键盘弹起后布局溢出会抛 RenderFlex overflow');
  });
}
