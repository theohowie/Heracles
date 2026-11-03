// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **侧边栏头部 ⊕「新建会话」的归属回归**（2026-11-03 用户实报 bug）。
//
// ## 用户原话
//
// > "侧边栏点击上方的 + 按钮，默认添加的不是我当前工作区的会话，而是其他
// > 工作区的会话，也不是默认工作区的。应该是：比如我目前在 AAA 工作区工作，
// > 点 + 就应该新建一个 AAA 的新会话；在 AAB 就新建 AAB 的。这个 + 按钮
// > 就是一个快捷添加新会话的方式而已。"
//
// ## 原来的实现错在哪
//
// `_header` 里写死 `onNewSession(workspaces.first.id)` —— **列表第一个**工作区，
// 与"用户当前在哪个工作区"毫无关系（列表顺序还会随视图选项/最近活动变化）。
// 用户在工作区 AAA 干活，点 + 却可能建到 AAB、甚至内置默认工作区里。
//
// ## 现在的规则（本文件逐条钉住）
//
// 1. 有当前工作区 ⇒ 就在那里建，**不看列表顺序**；
// 2. 没有当前工作区（无选中会话 / 会话所属工作区已移除）⇒ **弹选择抽屉让
//    用户自己选**，绝不回退到第一个/默认/任意一个；
// 3. 一个可用工作区都没有 ⇒ 退化到"加工作区"，**不**建会话。
//
// 断言都落在**行为**上（`onNewSession` 收到的 workspaceId 序列、是否弹出选择
// 抽屉），不落"某个 widget 存在"，这样重构时不会假绿。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/view_options.dart';
import 'package:heracles/models/workspace.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';
import 'package:heracles/widgets/bw_approval.dart';
import 'package:heracles/widgets/workspace_drawer.dart';

void main() {
  // ==================================================================
  // 0) 纯函数：「当前工作区」的唯一判据
  // ==================================================================

  /// 两个工作区：`AAA`（第一个）、`AAB`（第二个）。
  /// 刻意把"当前"放在**第二位** —— 若实现回退到 `first`，断言必红。
  const sessionsAaa = [HSession(id: 's-aaa', title: 'aaa 的会话')];
  const sessionsAab = [HSession(id: 's-aab', title: 'aab 的会话')];
  const twoWorkspaces = <HWorkspace>[
    HWorkspace(
      id: '/storage/emulated/0/AAA',
      name: 'AAA',
      path: '/storage/emulated/0/AAA',
      sessions: sessionsAaa,
    ),
    HWorkspace(
      id: '/storage/emulated/0/AAB',
      name: 'AAB',
      path: '/storage/emulated/0/AAB',
      sessions: sessionsAab,
    ),
  ];

  group('currentWorkspaceIdForSession —— 「当前工作区」只认选中会话的归属', () {
    test('★ 会话属于第二个工作区 → 返回第二个，而不是第一个', () {
      expect(
        currentWorkspaceIdForSession(twoWorkspaces, 's-aab'),
        '/storage/emulated/0/AAB',
        reason: '这就是用户报的 bug：在 AAB 工作就该建在 AAB',
      );
    });

    test('★ 没有选中会话 → null（不回退到第一个工作区）', () {
      expect(
        currentWorkspaceIdForSession(twoWorkspaces, null),
        isNull,
        reason: '不确定就必须返回 null，让上层去问用户 —— 不许猜',
      );
      expect(currentWorkspaceIdForSession(twoWorkspaces, ''), isNull,
          reason: '空字符串等同于未选中');
    });

    test('★ 会话所属工作区已被移除（id 找不到）→ null', () {
      expect(
        currentWorkspaceIdForSession(twoWorkspaces, 's-已删除'),
        isNull,
        reason: '会话 id 不在任何工作区里 —— 归属无从谈起，返回 null',
      );
    });

    test('空工作区列表 → null', () {
      expect(
        currentWorkspaceIdForSession(const <HWorkspace>[], 's-aaa'),
        isNull,
      );
    });
  });

  // ==================================================================
  // 1) 头部 ⊕ 的行为
  // ==================================================================

  late List<String> created;
  late int addCalls;

  setUp(() {
    created = <String>[];
    addCalls = 0;
  });

  void onAddWorkspace() => addCalls++;

  /// `HueScope` 必须挂载 —— 抽屉经 `Hue.of(context)` 取语义色。
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  Widget drawer({
    required List<HWorkspace> workspaces,
    String? activeWorkspaceId,
  }) =>
      wrap(WorkspaceDrawer(
        workspaces: workspaces,
        activeWorkspaceId: activeWorkspaceId,
        // 具名参数（不用 `_` / `__`）：本仓库 lint 开了
        // `unnecessary_underscores`，连续下划线会记一条 info。
        onSelectSession: (workspaceId, sessionId) {},
        onNewSession: (workspaceId) => created.add(workspaceId),
        onOpenSettings: () {},
        viewOptions: const ViewOptions(),
        onViewOptionsChanged: (options) {},
        searchQuery: '',
        onSearchChanged: (query) {},
        onAddWorkspace: onAddWorkspace,
      ));

  /// ★ 手机尺寸画布（390×844）：默认 800×600 太矮 —— 抽屉页头/导航行/工作区
  /// 分组装不下会 RenderFlex overflow，命中测试随之落空（见
  /// `workspace_drawer_add_menu_test.dart` 顶部同一段说明）。
  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// ★ 不用 `pumpAndSettle`：抽屉/抽屉壳里有常驻动画与弹簧吸附。
  /// 固定推虚拟时钟（与 `session_guard_test.dart` 的 `settle` 同一手法）。
  Future<void> settle(WidgetTester tester, {int times = 14}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 点头部 ⊕。
  ///
  /// 用图标定位：`AppIcons.add` 在**抽屉静止态只有一个**（另一个在"工作区
  /// 长按菜单"里，菜单没打开就不在树上）；⊕ 的 34×34 热区就是用户点的那个。
  /// 先断言"只有一个"—— 万一将来别处也放 `AppIcons.add`，这条会立刻提醒。
  Future<void> tapHeaderAdd(WidgetTester tester) async {
    final add = find.byIcon(AppIcons.add);
    expect(add, findsOneWidget,
        reason: '前提：静止态抽屉里 AppIcons.add 应当只有头部这一个');
    await tester.tap(add);
    await settle(tester);
  }

  /// 选择抽屉里的候选卡（限定在抽屉壳内 —— 抽屉背后也画着同名工作区分组）。
  Finder sheetCard(String text) => find.descendant(
        of: find.byType(BwSheetShell),
        matching: find.text(text),
      );

  // ---------------------------------------------------------------- 1) 有当前工作区

  /// **本次修复的核心**：当前工作区是列表里**第二个**，点 + 必须建在第二个。
  testWidgets('★ 有当前工作区（列表第二位）→ 点 + 就在它那里建，不用第一个',
      (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer(
      workspaces: twoWorkspaces,
      activeWorkspaceId: '/storage/emulated/0/AAB',
    ));
    await settle(tester);

    await tapHeaderAdd(tester);

    expect(created, ['/storage/emulated/0/AAB'],
        reason: '点 + 只能新建到当前工作区（AAB）—— 建到 AAA/第一个就是用户报的 bug');
    expect(find.text('在哪个工作区新建会话？'), findsNothing,
        reason: '归属明确时不该再问用户');
    expect(addCalls, 0, reason: '有可用工作区时不该走"加工作区"');
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------- 2) 没有当前工作区

  /// 没有选中会话 ⇒ **不许猜**：既不建，也不默认第一个；必须让用户选。
  testWidgets('★ 没有当前工作区 → 点 + 不建会话，弹选择抽屉；选了谁才建在谁那儿',
      (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer(
      workspaces: twoWorkspaces,
      // 关键：activeWorkspaceId 为 null —— 抽屉内不得自行挑一个
    ));
    await settle(tester);

    await tapHeaderAdd(tester);

    // ① 一行会话都不许建 —— 尤其不许默默建在第一个（AAA）
    expect(created, isEmpty,
        reason: '归属不确定时**绝不能**先建再问，也不能落到第一个/默认工作区');
    // ② 必须把选择权交给用户
    expect(find.text('在哪个工作区新建会话？'), findsOneWidget,
        reason: '没有当前工作区时必须弹选择抽屉让用户自己定归属');
    expect(find.text('当前没有选中的会话，所以不替你挑工作区'), findsOneWidget,
        reason: '要如实说明"为什么问你"，别让用户以为按钮坏了');
    // ③ 候选里两个工作区都在（未预选任何一个）
    expect(sheetCard('AAA'), findsOneWidget);
    expect(sheetCard('AAB'), findsOneWidget);

    // ④ 用户选 AAB（不是第一个）⇒ 只建在 AAB
    await tester.tap(sheetCard('AAB'));
    await settle(tester);

    expect(created, ['/storage/emulated/0/AAB'],
        reason: '用户点的是 AAB，就必须建在 AAB');
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------- 3) 当前工作区已不存在

  /// "工作区已删除"边界：宿主记着的工作区 id 已不在列表里 ⇒ 同样不许猜。
  testWidgets('★ 当前工作区已被移除（id 找不到）→ 点 + 不建，改弹选择抽屉',
      (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer(
      workspaces: twoWorkspaces,
      activeWorkspaceId: '/storage/emulated/0/已被移除',
    ));
    await settle(tester);

    await tapHeaderAdd(tester);

    expect(created, isEmpty, reason: '认不出的工作区绝不能兜底到第一个');
    expect(find.text('在哪个工作区新建会话？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// "工作区文件夹已失效"（`exists == false`，目录被用户删掉）⇒
  /// 不能往那里建会话（建了也写不进去），而且它**不该出现在候选里**。
  testWidgets('★ 当前工作区文件夹已失效 → 不建；失效项也不进候选',
      (tester) async {
    await usePhoneSurface(tester);
    const withGone = <HWorkspace>[
      HWorkspace(
        id: '/storage/emulated/0/GONE',
        name: 'GONE',
        path: '/storage/emulated/0/GONE',
        sessions: sessionsAaa,
        // 目录已被用户删掉
        exists: false,
      ),
      HWorkspace(
        id: '/storage/emulated/0/AAA',
        name: 'AAA',
        path: '/storage/emulated/0/AAA',
        sessions: sessionsAab,
      ),
    ];
    await tester.pumpWidget(drawer(
      workspaces: withGone,
      activeWorkspaceId: '/storage/emulated/0/GONE',
    ));
    await settle(tester);

    await tapHeaderAdd(tester);

    expect(created, isEmpty,
        reason: '失效工作区承接不了会话，不许硬建（也不许改投第一个）');
    expect(find.text('在哪个工作区新建会话？'), findsOneWidget);
    expect(sheetCard('AAA'), findsOneWidget, reason: '可用工作区要在候选里');
    expect(sheetCard('GONE'), findsNothing,
        reason: '失效工作区不能出现在候选里 —— 选了必然失败');
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------- 4) 一个工作区都没有

  /// 空态语义保持原样：没有工作区时 ⊕ = "先去加工作区"，**不**建会话
  /// （没有可归属的工作区，硬建就是造脏数据）。
  testWidgets('★ 没有任何工作区 → 点 + 走「加工作区」，不建会话', (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer(workspaces: const <HWorkspace>[]));
    await settle(tester);

    await tapHeaderAdd(tester);

    expect(addCalls, 1, reason: '空态点 + 应当引导去加工作区');
    expect(created, isEmpty, reason: '没有工作区时不可能建会话');
    expect(find.text('在哪个工作区新建会话？'), findsNothing,
        reason: '候选为空，弹空抽屉比不弹更糟');
    expect(tester.takeException(), isNull);
  });

  /// 全部工作区都失效 —— 与"一个都没有"同等处理，**不**把失效项当候选。
  testWidgets('★ 所有工作区都失效 → 点 + 走「加工作区」，不建会话',
      (tester) async {
    await usePhoneSurface(tester);
    const allGone = <HWorkspace>[
      HWorkspace(
        id: '/storage/emulated/0/GONE1',
        name: 'GONE1',
        path: '/storage/emulated/0/GONE1',
        sessions: sessionsAaa,
        exists: false,
      ),
    ];
    await tester.pumpWidget(drawer(workspaces: allGone));
    await settle(tester);

    await tapHeaderAdd(tester);

    expect(addCalls, 1);
    expect(created, isEmpty);
    expect(find.text('在哪个工作区新建会话？'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
