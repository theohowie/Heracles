import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/view_options.dart';
import 'package:heracles/models/workspace.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/workspace_drawer.dart';

/// **会话多选（批量归档 / 删除）回归测试**（2026-10-27，v2 交互）。
///
/// ## 交互口径（用户定）
///
/// · 顶栏勾选方块进多选；行首勾选圈点选；**没有底部常驻操作条** ——
///   选完**长按**任意一条，在上拉抽屉里选「归档 / 删除」
///   （沿用全 App 长按出抽屉的习惯）。
/// · **已归档的会话不能多选**（点不动、无勾选圈、全选也跳过）——
///   归档会话后续归「设置 · 已归档对话」管理，抽屉里不再给批量取消归档。
/// · 长按的那条若还没勾上，自动勾上再开抽屉。
void main() {
  late List<(String, String)> deleted;
  late List<(List<(String, String)>, bool)> archived;
  late int selectCalls;

  setUp(() {
    deleted = [];
    archived = [];
    selectCalls = 0;
  });

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  const ws = HWorkspace(
    id: 'w1',
    name: 'proj',
    path: '/storage/emulated/0/proj',
    expanded: true,
    sessions: [
      HSession(id: 's1', title: '会话一'),
      HSession(id: 's2', title: '会话二'),
      HSession(id: 's3', title: '会话三', archived: true),
    ],
  );

  Widget drawer({bool withBatch = true}) => wrap(WorkspaceDrawer(
        workspaces: const [ws],
        onSelectSession: (workspaceId, sessionId) => selectCalls++,
        onNewSession: (workspaceId) {},
        onOpenSettings: () {},
        // 显示全部（含已归档），否则 s3 被默认筛选藏起来、测不到"不能选"
        viewOptions: const ViewOptions(filter: SessionFilter.all),
        onViewOptionsChanged: (options) {},
        searchQuery: '',
        onSearchChanged: (query) {},
        onBatchArchiveSessions:
            withBatch ? (items, archive) => archived.add((items, archive)) : null,
        onBatchDeleteSessions: withBatch ? (items) => deleted = items : null,
      ));

  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> enterSelect(WidgetTester tester) async {
    await tester.tap(find.byIcon(CupertinoIcons.checkmark_square));
    await settle(tester);
  }

  testWidgets('没接批量回调 → 多选入口不出现', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer(withBatch: false));
    await settle(tester);
    expect(find.byIcon(CupertinoIcons.checkmark_square), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('选两条（已归档点不动）→ 长按出抽屉 → 删除一次收齐', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer());
    await settle(tester);

    await enterSelect(tester);
    expect(find.text('已选 0 个'), findsOneWidget);
    // 没有底部常驻操作条：长按之前不该见到「删除」
    expect(find.text('删除'), findsNothing);

    // 已归档的点不动
    await tester.tap(find.text('会话三'));
    await settle(tester);
    expect(find.text('已选 0 个'), findsOneWidget);

    await tester.tap(find.text('会话一'));
    await settle(tester);
    await tester.tap(find.text('会话二'));
    await settle(tester);
    expect(find.text('已选 2 个'), findsOneWidget);
    expect(selectCalls, 0);

    // 长按 → 上拉抽屉
    await tester.longPress(find.text('会话一'));
    await settle(tester);
    expect(find.text('已选 2 个会话'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await settle(tester);
    expect(deleted.toSet(), {('w1', 's1'), ('w1', 's2')});
    expect(find.text('已选 2 个'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全选跳过已归档 → 长按 → 归档回调 archive=true', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer());
    await settle(tester);

    await enterSelect(tester);
    await tester.tap(find.text('全选'));
    await settle(tester);
    expect(find.text('已选 2 个'), findsOneWidget,
        reason: '全选只数未归档的两条');

    await tester.longPress(find.text('会话二'));
    await settle(tester);
    await tester.tap(find.text('归档'));
    await settle(tester);
    expect(archived, hasLength(1));
    expect(archived.single.$2, isTrue);
    expect(archived.single.$1.toSet(), {('w1', 's1'), ('w1', 's2')});
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按未勾选的 → 自动勾上再开抽屉', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer());
    await settle(tester);

    await enterSelect(tester);
    await tester.longPress(find.text('会话一'));
    await settle(tester);
    expect(find.text('已选 1 个会话'), findsOneWidget);

    await tester.tap(find.text('归档'));
    await settle(tester);
    expect(archived, hasLength(1));
    expect(archived.single.$1, [('w1', 's1')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消 → 清零退出，行点按恢复打开会话', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer());
    await settle(tester);

    await enterSelect(tester);
    await tester.tap(find.text('会话一'));
    await settle(tester);
    expect(find.text('已选 1 个'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.text('已选 1 个'), findsNothing);

    await tester.tap(find.text('会话一'));
    await settle(tester);
    expect(selectCalls, 1);
    expect(tester.takeException(), isNull);
  });
}
