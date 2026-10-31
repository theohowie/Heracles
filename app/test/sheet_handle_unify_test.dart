// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **抽屉统一（T2-4，screens 侧）**（2026-10-31）：
//
// 用户定版：所有上拉抽屉的抓手只有 `BwSheetShell` 自带的那一只
// （`BwSheetHandle`，36×4 pill）；菜单类抽屉的行统一是边框卡
// （`BwActionCard`）。本文件钉住 settings / archived 两个屏幕的抽屉：
//   · 抽屉里**恰好一只**抓手，且除它之外没有自绘的 36×4 条；
//   · 菜单行是 `BwActionCard`（旧的裸 InkWell `_MenuRow` / `_providerMenuRow` 已迁走）；
//   · `showHandle` 没被关掉（关了就没抓手）。
//
// 源码级防回归在 `test/sheet_handle_guard_test.dart`（禁自绘抓手）。
// 沙箱页的确认抽屉断言在 `test/sandbox_screen_test.dart`（那里有通道 mock 夹具）。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/models/workspace.dart';
import 'package:heracles/screens/archived_sessions_screen.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';

import 'memory_scope_test.dart' show FakeMemorySource;
import 'support/secure_storage_mock.dart';

/// 自绘抓手 = 独立的 36×4 条（与 `BwSheetHandle` 内部那只同尺寸）。
final Finder _barFinder = find.byWidgetPredicate((w) {
  if (w is! Container) return false;
  final c = w.constraints;
  return c != null &&
      c.minWidth == 36 &&
      c.maxWidth == 36 &&
      c.minHeight == 4 &&
      c.maxHeight == 4;
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(Widget home) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: home,
      );

  Future<void> frames(WidgetTester tester, {int n = 14}) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> tallCanvas(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 抽屉里必须**恰好一只**抓手，且没有第二条自绘 36×4 条。
  void expectSingleShellHandle(WidgetTester tester, String where) {
    expect(find.byType(BwSheetShell), findsOneWidget,
        reason: '$where：抽屉必须走 BwSheetShell（统一表面/抓手/拖拽）');
    expect(tester.widget<BwSheetShell>(find.byType(BwSheetShell)).showHandle,
        isTrue,
        reason: '$where：不许 showHandle:false（关了就没抓手了）');
    expect(find.byType(BwSheetHandle), findsOneWidget,
        reason: '$where：抽屉必须有一只共享抓手');
    final bars = tester.widgetList(_barFinder).length;
    expect(bars, 1,
        reason: '$where：除共享抓手外还有 ${bars - 1} 条自绘抓手'
            '（双抓手是 2026-10-31 用户明确要修掉的旧形态）');
  }

  group('设置 · 记忆编辑抽屉', () {
    testWidgets('★★ 只有壳自带的那一只抓手（编辑页里自绘抓手已删）', (tester) async {
      await tallCanvas(tester);
      final src = FakeMemorySource()
        ..entries[MemoryScopeView.global]!.add(const MemoryScopeEntry(
          id: 'g1',
          kind: 'other',
          text: '一条记忆',
          source: 'user',
          createdAt: 1791612000000,
        ));
      await tester.pumpWidget(wrap(GlobalMemoryPage(
        source: src,
        sessionId: 's1791611845161',
      )));
      await frames(tester);

      await tester.tap(find.byKey(const ValueKey('memory_add_global')));
      await frames(tester);

      expect(find.text('添加记忆'), findsOneWidget, reason: '抽屉没打开');
      expectSingleShellHandle(tester, '记忆编辑抽屉');
    });
  });

  group('设置 · 提供商操作抽屉', () {
    testWidgets('★★ 长按提供商：菜单行是 BwActionCard + 单抓手', (tester) async {
      installSecureStorageMock();
      addTearDown(removeSecureStorageMock);
      const prov = ModelProviderConfig(
        id: 'p1',
        name: 'P1',
        baseUrl: 'https://x/v1',
        model: 'm',
      );
      SharedPreferences.setMockInitialValues({
        'providers': jsonEncode([prov.toJson()]),
      });
      final controller = await SettingsController.load();
      await tallCanvas(tester);

      await tester.pumpWidget(wrap(ModelSettingsPage(controller: controller)));
      await frames(tester);

      await tester.longPress(find.text('P1').first);
      await frames(tester);
      expect(find.text('编辑'), findsWidgets, reason: '长按没弹操作抽屉');

      expectSingleShellHandle(tester, '提供商操作抽屉');
      expect(find.byType(BwActionCard), findsNWidgets(2),
          reason: '「编辑」「删除」两行都要是 BwActionCard（旧的裸 InkWell 行已迁走）');
      for (final label in ['编辑', '删除']) {
        expect(
            find.descendant(
                of: find.byType(BwActionCard), matching: find.text(label)),
            findsOneWidget,
            reason: '「$label」必须收进 BwActionCard');
      }
    });
  });

  group('已归档 · 长按菜单', () {
    testWidgets('★★ 菜单行是 BwActionCard + 单抓手', (tester) async {
      await tallCanvas(tester);
      final now = DateTime.now();
      await tester.pumpWidget(wrap(ArchivedSessionsScreen(
        items: [
          (
            const HWorkspace(id: 'w1', name: 'proj', path: '/p1'),
            HSession(
                id: 's1',
                title: '旧会话一',
                archived: true,
                lastActivity: now.subtract(const Duration(days: 2))),
          ),
        ],
        onOpen: (_, _) {},
        onUnarchive: (_, _) {},
        onDelete: (_, _) async => true,
      )));
      await frames(tester);

      await tester.longPress(find.text('旧会话一'));
      await frames(tester);
      expect(find.text('取消归档'), findsOneWidget, reason: '长按没弹菜单');

      expectSingleShellHandle(tester, '已归档菜单');
      expect(find.byType(BwActionCard), findsNWidgets(3),
          reason: '打开 / 取消归档 / 删除 三行都要是 BwActionCard（旧 _MenuRow 已迁走）');
      for (final label in ['打开', '取消归档', '删除']) {
        expect(
            find.descendant(
                of: find.byType(BwActionCard), matching: find.text(label)),
            findsOneWidget,
            reason: '「$label」必须收进 BwActionCard');
      }
    });
  });
}
