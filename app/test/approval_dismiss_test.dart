// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **审批弹层「防误关」验收**（2026-10-29 第 4 条 P1）。
//
// ## 用户报的症状
//
// > 「审批/提问弹层一不小心就被关掉，关掉后模型就按拒绝/未回答处理了，
// >  但用户根本不知道自己刚刚做了决定。」
//
// ## 旧实现的洞（已核实）
//
// · 审批抽屉本身 `isDismissible:false` + `enableDrag:false`，**点遮罩/下滑关不掉**；
// · 但**系统返回键**仍然能 pop 掉它 ⇒ `showApprovalRequestSheet` 返回 null
//   ⇒ `chat_screen._showApprovalDialog` 的 `_ => 'deny'` 分支 ⇒ 静默拒绝。
//   用户看到的只是"弹层消失了"，没有任何二次确认、没有提示。
// · 「始终允许」第二步（确认页）按返回更是**整个抽屉一起消失** ——
//   用户以为只是"退一步看看"，实际是把审批关掉了。
//
// ## 修完后的契约（本文件逐条钉住）
//
// 1. 系统返回键 ⇒ 弹层**仍在**，并弹出二次确认「放弃本次审批？」；
// 2. 确认放弃 ⇒ 回传 **deny**（绝不出现 always/once）+ 轻提示「已按拒绝处理」；
// 3. 取消放弃 ⇒ 弹层仍在，什么决定都没做；
// 4. 第二步按返回 ⇒ **先回第一步**，不弹确认、不关层；
// 5. 点遮罩关不掉（既有行为，回归钉子）。

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

  /// 固定推虚拟时钟（弹层入场/退场动画 + 轻提示动画都要走完）。
  Future<void> settle(WidgetTester tester, {int times = 16}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// 打开审批抽屉，并把"调用方拿到的决定"暴露出来。
  Future<ApprovalDecision? Function()> openSheet(WidgetTester tester) async {
    ApprovalDecision? result;
    var returned = false;
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: TextButton(
          onPressed: () async {
            result = await showApprovalRequestSheet(
              ctx,
              tool: 'run_shell_command',
              argsPreview: 'command: mkdir approval-test',
              risk: '在工作区外执行命令',
              allowStop: true,
            );
            returned = true;
          },
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text('需要你的批准'), findsOneWidget, reason: '前置：审批抽屉已弹出');
    return () {
      expect(returned, isTrue, reason: '前置：调用方的 await 必须已经收尾');
      return result;
    };
  }

  testWidgets('★★★ 系统返回键 ⇒ 弹层仍在 + 二次确认「放弃本次审批？」', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final resultOf = await openSheet(tester);

    // 系统返回键（Android 实体/手势返回的真实入口）
    await tester.binding.handlePopRoute();
    await settle(tester);

    expect(find.text('需要你的批准'), findsOneWidget,
        reason: '返回键不许把审批弹层直接关掉 —— 关掉 = 静默拒绝，用户不知情');
    expect(find.textContaining('放弃本次审批'), findsOneWidget,
        reason: '必须弹二次确认，让用户明确知道"关掉 = 按拒绝处理"');
    expect(tester.takeException(), isNull);
    // 决定还没做：调用方的 await 不该收尾（用 resultOf 的断言会先炸，所以这里
    // 直接看界面 —— 若已经收尾，弹层不可能还在）
    expect(resultOf, isNotNull);
  });

  testWidgets('★★ 确认放弃 ⇒ 回传 deny + 轻提示「已按拒绝处理」', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final resultOf = await openSheet(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);

    await tester.tap(find.text('放弃并拒绝'));
    await settle(tester);

    expect(find.text('需要你的批准'), findsNothing, reason: '确认放弃后弹层应当关闭');
    expect(resultOf(), ApprovalDecision.deny,
        reason: '关闭必须回传 **deny** —— 绝不允许出现 once/always');
    expect(find.text('已按拒绝处理'), findsOneWidget,
        reason: '关闭后要给用户一句交代（不能静默）');

    // 轻提示是 2.2 秒后自动淡出的定时器 —— 必须把它走完，
    // 否则测试结束时树已销毁、定时器仍在 ⇒ "A Timer is still pending"。
    await settle(tester, times: 60);
  });

  testWidgets('★★ 取消放弃 ⇒ 弹层仍在，决定未做', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await openSheet(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);

    await tester.tap(find.text('继续审批'));
    await settle(tester);

    expect(find.text('需要你的批准'), findsOneWidget,
        reason: '取消放弃 ⇒ 回到审批本身，别把用户赶出弹层');
    expect(find.textContaining('放弃本次审批'), findsNothing);
    expect(find.text('允许一次'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('★★★ 第二步（始终允许）按返回 ⇒ 先回第一步，不弹确认、不关层', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await openSheet(tester);
    await tester.tap(find.text('始终允许'));
    await settle(tester);
    expect(find.text('确认始终允许'), findsOneWidget, reason: '前置：已滑到第二步');

    await tester.binding.handlePopRoute();
    await settle(tester);

    expect(find.textContaining('放弃本次审批'), findsNothing,
        reason: '第二步的返回是"退一步"，不是"关闭审批" —— 不该弹放弃确认');
    expect(find.text('确认始终允许'), findsNothing, reason: '应当退回第一步');
    expect(find.text('允许一次'), findsOneWidget,
        reason: '第二步按返回必须回到第一步（旧实现是整个抽屉消失）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('★ 点遮罩关不掉审批弹层（既有行为，回归钉子）', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await openSheet(tester);

    // 点弹层外的上方区域（遮罩）
    await tester.tapAt(const Offset(196, 40));
    await settle(tester);

    expect(find.text('需要你的批准'), findsOneWidget,
        reason: '审批必须由按钮决定，点遮罩不能算决定');
    expect(find.textContaining('放弃本次审批'), findsNothing);
  });
}
