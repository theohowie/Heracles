import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/workspace.dart';
import 'package:heracles/screens/archived_sessions_screen.dart';
import 'package:heracles/theme/app_theme.dart';

/// **已归档对话页回归测试**（2026-10-27）。
///
/// 归档会话从抽屉搬来设置管理：跨工作区平铺、最近活动倒序。
/// 断言落在行为上：点 = 打开、长按抽屉里取消归档/删除后行消失、
/// 删除被调用方拒绝（确认取消）时行保留、空态有自救文案。
void main() {
  late List<(String, String)> opened;
  late List<(String, String)> unarchived;
  late bool deleteResult;

  setUp(() {
    opened = [];
    unarchived = [];
    deleteResult = true;
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      );

  final now = DateTime.now();
  List<(HWorkspace, HSession)> fixture() => [
        (
          const HWorkspace(id: 'w1', name: 'proj', path: '/p1'),
          HSession(
              id: 's1',
              title: '旧会话一',
              archived: true,
              lastActivity: now.subtract(const Duration(days: 2))),
        ),
        (
          const HWorkspace(id: 'w2', name: 'lab', path: '/p2'),
          HSession(
              id: 's2',
              title: '较新的归档',
              archived: true,
              lastActivity: now.subtract(const Duration(hours: 1))),
        ),
      ];

  Widget page(List<(HWorkspace, HSession)> items) => wrap(
        ArchivedSessionsScreen(
          items: items,
          onOpen: (wid, sid) => opened.add((wid, sid)),
          onUnarchive: (wid, sid) => unarchived.add((wid, sid)),
          onDelete: (wid, sid) async => deleteResult,
        ),
      );

  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('两条归档跨工作区显示，较新的排前面', (tester) async {
    await tester.pumpWidget(page(fixture()));
    await settle(tester);
    expect(find.text('旧会话一'), findsOneWidget);
    expect(find.text('较新的归档'), findsOneWidget);
    final newer = tester.getTopLeft(find.text('较新的归档')).dy;
    final older = tester.getTopLeft(find.text('旧会话一')).dy;
    expect(newer, lessThan(older), reason: '按最近活动倒序');
    expect(tester.takeException(), isNull);
  });

  testWidgets('点一条 = 打开（回调收到工作区与会话 id）', (tester) async {
    await tester.pumpWidget(page(fixture()));
    await settle(tester);
    await tester.tap(find.text('旧会话一'));
    await settle(tester);
    expect(opened, [('w1', 's1')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按 → 取消归档：回调触发且行消失', (tester) async {
    await tester.pumpWidget(page(fixture()));
    await settle(tester);
    await tester.longPress(find.text('旧会话一'));
    await settle(tester);
    expect(find.text('取消归档'), findsOneWidget);
    await tester.tap(find.text('取消归档'));
    await settle(tester);
    expect(unarchived, [('w1', 's1')]);
    expect(find.text('旧会话一'), findsNothing);
    expect(find.text('较新的归档'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按 → 删除成功行消失；确认被取消时行保留', (tester) async {
    await tester.pumpWidget(page(fixture()));
    await settle(tester);

    // 先取消一次（调用方确认没过 → 返回 false）
    deleteResult = false;
    await tester.longPress(find.text('旧会话一'));
    await settle(tester);
    await tester.tap(find.text('删除'));
    await settle(tester);
    expect(find.text('旧会话一'), findsOneWidget,
        reason: '没真删就不许把行撤掉');

    // 再删一次，这次成功
    deleteResult = true;
    await tester.longPress(find.text('旧会话一'));
    await settle(tester);
    await tester.tap(find.text('删除'));
    await settle(tester);
    expect(find.text('旧会话一'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('文件树分组：工作区组头 + 点「回档」直接取消归档', (tester) async {
    await tester.pumpWidget(page(fixture()));
    await settle(tester);
    // 组头：两个工作区名都以组头出现
    expect(find.text('proj'), findsOneWidget);
    expect(find.text('lab'), findsOneWidget);
    // 每行常驻回档按钮
    expect(find.text('回档'), findsNWidgets(2));
    await tester.tap(find.text('回档').first);
    await settle(tester);
    expect(unarchived.length, 1, reason: '点回档必须触发取消归档回调');
    expect(unarchived.single.$2, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('组头点按折叠/展开会话行', (tester) async {
    await tester.pumpWidget(page(fixture()));
    await settle(tester);
    await tester.tap(find.text('proj'));
    await settle(tester);
    expect(find.text('旧会话一'), findsNothing);
    expect(find.text('较新的归档'), findsOneWidget);
    await tester.tap(find.text('proj'));
    await settle(tester);
    expect(find.text('旧会话一'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空态：说明去哪归档', (tester) async {
    await tester.pumpWidget(page(const []));
    await settle(tester);
    expect(find.text('没有已归档的对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
