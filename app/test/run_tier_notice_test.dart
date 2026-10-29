// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **运行中切档提示**（2026-10-29 第 5 条 P1）。
//
// ## 为什么要提示
//
// 权限档位在 **run 开始那一刻**就被快照进执行器
// （`services/local_agent.dart` 的档位快照）。运行中把档位从「手动审批」
// 改成「完全访问」，这一轮**仍然按旧档位走** —— 不告诉用户，用户会觉得
// "我明明开了完全访问，怎么还在问我"（假信息）。
//
// ## 契约（本文件逐条钉住）
//
// 1. 档位**真的变了** + 当前会话**确有 run 在跑** ⇒ 提示条出现，文案是
//    「本轮已开始，新档位从下次运行生效」（**不许**说"已生效"）；
// 2. 没在跑 ⇒ 不提示（那时是立即生效）；
// 3. 重复选同一档 ⇒ 不提示；
// 4. 提示条可关闭（点 ✕）；
// 5. 「完全访问」的二次确认**取消** ⇒ `onPicked` 不触发 ⇒ 档位没变 ⇒ 不提示；
//    确认完成后才 `onPicked`（顺序即"确认生效后才提示"）。
//
// ⚠️ ChatScreen 级的端到端用例（真起一轮 run 再切档）暂时跑不了：
//    隔离工作树里**他人**的 `lib/screens/jev_settings_screen.dart` 中间态
//    引用了 WT 内不存在的 `services/jev_service.dart` 新 API，任何
//    导入 chat_screen 的测试都无法编译（不是本项的代码问题）。
//    所以这里钉的是**可独立验证的三段**：判定函数 / 提示条渲染 /
//    档位确认流程 —— 接线部分（chat_screen 的 5 行）由 Lead 在门禁与
//    真机上复核，路径见交付报告。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';
import 'package:heracles/widgets/input_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(dark: false),
        builder: (context, inner) => HueScope(
          hue: Hue.forDark(false, 0xFFFF7A45),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: child),
        ),
      );

  Future<void> settle(WidgetTester tester, {int times = 12}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // ==================================================================
  // 1) 判定函数（"什么时候该提示"的单一真相）
  // ==================================================================

  group('shouldShowRunTierNotice', () {
    test('★ run 在跑 + 档位真的变了 ⇒ 提示', () {
      expect(
        shouldShowRunTierNotice(
          from: PermissionMode.manual,
          to: PermissionMode.workspaceAuto,
          runInFlight: true,
        ),
        isTrue,
      );
      expect(
        shouldShowRunTierNotice(
          from: PermissionMode.workspaceAuto,
          to: PermissionMode.fullAccess,
          runInFlight: true,
        ),
        isTrue,
        reason: '切「完全访问」（已过二次确认）也要提示 —— 本轮仍是旧档位',
      );
    });

    test('★★ 没在跑 ⇒ 不提示（那时是立即生效，提示反而是假信息）', () {
      expect(
        shouldShowRunTierNotice(
          from: PermissionMode.manual,
          to: PermissionMode.fullAccess,
          runInFlight: false,
        ),
        isFalse,
      );
    });

    test('★ 重复选同一档 ⇒ 不提示', () {
      for (final m in PermissionMode.values) {
        expect(
          shouldShowRunTierNotice(from: m, to: m, runInFlight: true),
          isFalse,
          reason: '选的是当前档位 ⇒ 什么都没变，别打扰用户',
        );
      }
    });
  });

  // ==================================================================
  // 2) 提示条渲染 + 可关闭
  // ==================================================================

  testWidgets('★★ 传入提示 ⇒ 输入卡上方出现提示条（文案不说"已生效"）',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(InputBar(
      onSend: (_) {},
      runTierNotice: kRunTierNoticeText,
      onDismissRunTierNotice: () {},
    )));
    await settle(tester);

    expect(find.text(kRunTierNoticeText), findsOneWidget,
        reason: '运行中切档必须给出"下次运行生效"的提示');
    expect(find.textContaining('已生效'), findsNothing,
        reason: '⚠️ 用户明确要求：文案不许说"已生效"（这一轮用的还是旧档位）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('★★ 点 ✕ ⇒ 提示条关闭（回调触发）', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    var dismissed = 0;
    await tester.pumpWidget(wrap(InputBar(
      onSend: (_) {},
      runTierNotice: kRunTierNoticeText,
      onDismissRunTierNotice: () => dismissed++,
    )));
    await settle(tester);

    await tester.tap(find.byIcon(CupertinoIcons.xmark));
    await settle(tester);

    expect(dismissed, 1, reason: '✕ 必须真的能关掉提示（用户要可关闭）');
  });

  testWidgets('★ 没传提示 ⇒ 不渲染提示条（没在跑的常态）', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(InputBar(onSend: (_) {})));
    await settle(tester);

    expect(find.text(kRunTierNoticeText), findsNothing);
    expect(find.byIcon(CupertinoIcons.info_circle), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ==================================================================
  // 3) 档位确认流程：取消完全访问的二次确认 ⇒ 档位没变（⇒ 不会有提示）
  // ==================================================================

  testWidgets('★★★ 切「完全访问」取消二次确认 ⇒ onPicked 不触发（档位未变）',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final picked = <PermissionMode>[];
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: TextButton(
          onPressed: () => showApprovalModeSheet(
            ctx,
            current: PermissionMode.manual,
            onPicked: picked.add,
          ),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await settle(tester);

    // 点「完全访问」→ 叠出风险确认
    await tester.tap(find.text('完全访问'));
    await settle(tester);
    expect(find.text('开启完全访问？'), findsOneWidget, reason: '前置：二次确认已叠出');

    // 取消 ⇒ 什么都不改
    await tester.tap(find.text('取消'));
    await settle(tester);

    expect(picked, isEmpty,
        reason: '取消确认 ⇒ 档位没变 ⇒ 调用方不会 setPermission ⇒ 也就不会有切档提示');
    expect(find.text('审批模式'), findsOneWidget,
        reason: '取消后应回到模式列表（不是把用户丢回页面）');
  });

  testWidgets('★★ 勾选 + 确认选择 ⇒ onPicked(fullAccess) 只在确认完成后触发',
      (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final picked = <PermissionMode>[];
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: TextButton(
          onPressed: () => showApprovalModeSheet(
            ctx,
            current: PermissionMode.manual,
            onPicked: picked.add,
          ),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await settle(tester);

    await tester.tap(find.text('完全访问'));
    await settle(tester);
    expect(picked, isEmpty, reason: '前置：还没确认就不许回调（确认前不生效）');

    await tester.tap(find.text('我已知晓以上风险'));
    await settle(tester);
    await tester.tap(find.text('确认选择'));
    await settle(tester, times: 20);

    expect(picked, [PermissionMode.fullAccess],
        reason: '确认完成后才回调 —— 这正是"确认生效后才提示"的顺序保证');
  });
}
