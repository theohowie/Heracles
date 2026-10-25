import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/view_options.dart';
import 'package:heracles/models/workspace.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/workspace_drawer.dart';

/// **两个"加工作区"入口的回归测试**（2026-10-17）。
///
/// ## 为什么要两个入口（而不是让一个兜底）
///
/// 编码层（构建 APK / 逆向）要求工作区**同时**能被 App 与 shell 写。
/// 真机实测（`测试机`，见 `docs/实测-12`）同时满足的只有
/// `Android/data/<pkg>/files/**` —— 而 SAF 选择器**选不到**那里
/// （Android 11+ 不允许浏览 `Android/data`）。
///
/// 于是 ⊕ 从"一个动作"变成**两项菜单**：
///   · **选择文件夹** —— 用户自己的项目（不一定可写 ⇒ 不一定能构建）
///   · **默认工作区** —— 内置的、App 与 shell 都能写的目录（能构建）
///
/// ## 这个文件防什么
///
/// 1. ⊕ 点开真有**两项**（防"又退回只有一个动作"—— 那正是本次要修的缺陷）
/// 2. 两项**各走各的回调，互不兜底**（防接线串了：点 A 却触发了 B）
/// 3. 空态（第一次进来、一个工作区都没有）**两个按钮都在** ——
///    空态正是解释"为什么有两种工作区"的最佳时机
/// 4. `onAddAppWorkspace == null` 时那次要按钮**必须不出现**
///    （防"回调没接线但按钮画出来了" —— 点了没反应，比没有按钮更糟）
///
/// 断言都落在**行为**上（回调是否被调用、按钮是否存在），
/// 而不是"某个 widget 类型存在"—— 后者在重构时会假绿。
void main() {
  // ---------------------------------------------------------------- 夹具

  late int folderCalls;
  late int appCalls;

  /// ★ 手机尺寸的测试画布 —— **不是**为了好看，是为了让空态真的可点。
  ///
  /// 默认测试画布是 800×600：宽到 `drawerWidth` 走 `340` 那一支，
  /// 而高度只有 600 —— 抽屉的页头/`新会话`/三个导航项/区块头/设置
  /// 占掉一大半后，空态那个 `Column`（图标 + 两行说明 + 两个按钮 +
  /// 一行小字）**装不下**，Flutter 会报 RenderFlex overflow 并把它
  /// 裁掉，于是按钮的命中测试落空（实测：`flutter test` 报
  /// "would not hit test on the specified widget" + overflow 146px）。
  ///
  /// 真机是竖屏手机（390×844 这个量级），空态本来就装得下。
  /// 所以这里把画布设成手机尺寸 —— 测试环境更接近生产，
  /// 断言才有意义（否则测的是"测试画布太矮"这件事）。
  setUp(() {
    folderCalls = 0;
    appCalls = 0;
  });

  /// 每个 testWidgets 开头调用 —— 把画布设成竖屏手机。
  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 两个回调**分开计数** —— 这样"点 A 触发了 B"这种接线错误一定会被抓住。
  void onFolder() => folderCalls++;
  void onApp() => appCalls++;

  /// `HueScope` 必须挂载 —— [WorkspaceDrawer] 通过 `Hue.of(context)` 读语义色。
  /// 生产环境由 `main.dart` 的 `MaterialApp.builder` 注入（与 widget_test.dart 一致）。
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
    VoidCallback? onAddWorkspace,
    VoidCallback? onAddAppWorkspace,
  }) =>
      wrap(WorkspaceDrawer(
        workspaces: workspaces,
        // 参数用具名而不是 `_` / `__`：本仓库 lint 开了
        // `unnecessary_underscores`，连续下划线会记一条 info（analyze 要求 0 issue）。
        onSelectSession: (workspaceId, sessionId) {},
        onNewSession: (workspaceId) {},
        onOpenSettings: () {},
        viewOptions: const ViewOptions(),
        onViewOptionsChanged: (options) {},
        searchQuery: '',
        onSearchChanged: (query) {},
        onAddWorkspace: onAddWorkspace,
        onAddAppWorkspace: onAddAppWorkspace,
      ));

  /// ★ 不用 `pumpAndSettle`：本仓库的 widget 里有常驻动画
  /// （`loading` 态的 `CircularProgressIndicator`），`pumpAndSettle` 会超时。
  /// 固定推虚拟时钟 —— 与 session_guard_test.dart 的 `settle` 同一手法。
  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 点开工作区区块头的 ⊕（`_AddWorkspaceMenu`，一个 PopupMenuButton）。
  ///
  /// 用**图标**定位而不是 `find.byTooltip('添加工作区')`：tooltip 要长按/悬浮
  /// 才可见，图标是用户真正点的那 36×36 热区。
  ///
  /// ★ 2026-10-25（过期 finder 修复）：Cupertino 改版后图标从 Material
  ///   `Icons.create_new_folder_outlined` 换成 `CupertinoIcons.folder_badge_plus`
  ///   —— 且抽屉里同款图标出现两次（`workspace_drawer.dart:874` size 18 =
  ///   本按钮；`:370` size 35 = 空态装饰）⇒ 必须按 size 定位。**只换 finder，
  ///   断言与测试体未动**。
  Future<void> openAddMenu(WidgetTester tester) async {
    await tester.tap(find.byWidgetPredicate(
      (w) =>
          w is Icon &&
          w.icon == CupertinoIcons.folder_badge_plus &&
          w.size == 18,
      description: '工作区区块头的 ⊕ 菜单按钮（size 18）',
    ));
    await settle(tester);
  }

  void expectNoException(WidgetTester tester) {
    expect(tester.takeException(), isNull);
  }

  // ==================================================================
  // 1) ⊕ 点开 → 两项都在
  // ==================================================================

  /// 这是本次改造的**核心**：⊕ 不再是"直接选文件夹"，而是一个明确的两项菜单。
  ///
  /// 防回退：如果哪天有人把 `_AddWorkspaceMenu` 改回单个动作按钮，
  /// 这条会失败 —— 而用户真正在意的是"我必须知道自己在选哪种工作区"。
  testWidgets('★ ⊕ 点开 → 「选择文件夹」与「默认工作区」两项都在',
      (tester) async {
    await tester.pumpWidget(drawer(
      // 非空：证明"两项菜单"不是空态专属
      workspaces: const [
        HWorkspace(id: 'w1', name: 'proj', path: '/storage/emulated/0/proj'),
      ],
      onAddWorkspace: onFolder,
      onAddAppWorkspace: onApp,
    ));
    await settle(tester);

    // 前提：菜单还没打开 —— 否则下面断言的是别处的文字
    expect(find.text('选择文件夹'), findsNothing);
    expect(find.text('默认工作区'), findsNothing);

    await openAddMenu(tester);

    expect(find.text('选择文件夹'), findsOneWidget,
        reason: '⊕ 菜单第一项必须是「选择文件夹」（用户自己的项目）');
    expect(find.text('默认工作区'), findsOneWidget,
        reason: '⊕ 菜单第二项必须是「默认工作区」（内置 · 可构建）');

    // 用户要求（2026-10-19）：菜单项**不再**带副标题 —— 下面这些小字必须消失
    expect(find.text('我自己的项目（可能不可写）'), findsNothing);
    expect(find.text('内置 · 可构建 APK'), findsNothing);
    expectNoException(tester);
  });

  // ==================================================================
  // 2) / 3) 两项各走各的回调
  // ==================================================================

  /// 防"接线串了"：点"选择文件夹"绝不能顺手触发"默认工作区"。
  ///
  /// 为什么这条重要：`_AddWorkspaceMenu` 的 `onSelected` 是一个
  /// `if (v == 'folder') … if (v == 'app') …` 分支 —— 写成
  /// 无 `else`、或复制粘贴漏改 value，都会让两个入口同时触发。
  /// 真机上表现为"点选文件夹，结果冒出个内置工作区"，很吓人。
  testWidgets('★ 点「选择文件夹」→ 只触发 onAddWorkspace，不触发 onAddAppWorkspace',
      (tester) async {
    await tester.pumpWidget(drawer(
      workspaces: const [
        HWorkspace(id: 'w1', name: 'proj', path: '/storage/emulated/0/proj'),
      ],
      onAddWorkspace: onFolder,
      onAddAppWorkspace: onApp,
    ));
    await settle(tester);
    await openAddMenu(tester);

    await tester.tap(find.text('选择文件夹'));
    await settle(tester);

    expect(folderCalls, 1, reason: '点「选择文件夹」必须触发 onAddWorkspace');
    expect(appCalls, 0,
        reason: '点「选择文件夹」绝不能触发 onAddAppWorkspace —— 两个入口互不兜底');
    expectNoException(tester);
  });

  testWidgets('★ 点「默认工作区」→ 只触发 onAddAppWorkspace，不触发 onAddWorkspace',
      (tester) async {
    await tester.pumpWidget(drawer(
      workspaces: const [
        HWorkspace(id: 'w1', name: 'proj', path: '/storage/emulated/0/proj'),
      ],
      onAddWorkspace: onFolder,
      onAddAppWorkspace: onApp,
    ));
    await settle(tester);
    await openAddMenu(tester);

    await tester.tap(find.text('默认工作区'));
    await settle(tester);

    expect(appCalls, 1, reason: '点「默认工作区」必须触发 onAddAppWorkspace');
    expect(folderCalls, 0,
        reason: '点「默认工作区」绝不能触发 onAddWorkspace —— 两个入口互不兜底');
    expectNoException(tester);
  });

  // ==================================================================
  // 4) 空态：两个按钮都在，各自走各自回调
  // ==================================================================

  /// 空态是用户**第一次**进来的地方 —— 正好是解释"为什么会有两种工作区"的
  /// 最佳时机，而不是等他选了 `/sdcard` 的项目、构建失败了才去猜。
  ///
  /// 这里直接遍历两种按钮的各一次点击 —— 因为它们在同一个
  /// `_empty()` 里、相邻几行，最容易在改动时被一起改错。
  testWidgets('★ 空态 → 「选择文件夹」与「使用默认工作区」都在，回调各归各',
      (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer(
      workspaces: const <HWorkspace>[],
      onAddWorkspace: onFolder,
      onAddAppWorkspace: onApp,
    ));
    await settle(tester);

    expect(find.text('还没有工作区'), findsOneWidget,
        reason: '前提：确实是空态（没有工作区）');

    // ---- ① 主按钮：选择文件夹 ----
    expect(find.text('选择文件夹'), findsOneWidget,
        reason: '空态主按钮必须是「选择文件夹」');
    expect(find.text('使用默认工作区'), findsOneWidget,
        reason: '空态唯一解释"能构建的工作区"的地方 —— 必须在');

    await tester.tap(find.text('选择文件夹'));
    await settle(tester);
    expect(folderCalls, 1, reason: '空态主按钮必须走 onAddWorkspace');
    expect(appCalls, 0, reason: '空态主按钮不该碰到默认工作区回调');

    // ---- ② 次要按钮：默认工作区 ----
    await tester.tap(find.text('使用默认工作区'));
    await settle(tester);
    expect(appCalls, 1, reason: '空态次要按钮必须走 onAddAppWorkspace');
    expect(folderCalls, 1,
        reason: '点次要按钮不该再多触发一次文件夹回调（仍然是 1 次）');

    // 两个按钮是**两个独立入口** —— 点完一个另一个不该消失
    expect(find.text('选择文件夹'), findsOneWidget);
    expect(find.text('使用默认工作区'), findsOneWidget);
    expectNoException(tester);
  });

  // ==================================================================
  // 5) onAddAppWorkspace == null → 次要按钮不出现
  // ==================================================================

  /// 防"按钮画出来了但点了没反应"。
  ///
  /// `_empty()` 里那次要入口是 `if (onAddAppWorkspace != null) …` 包着的 ——
  /// 一旦有人把 `onPressed` 改成 `onAddAppWorkspace?.call()` 却忘了守卫，
  /// 界面上就会出现一个**静默失效的按钮**（点了什么都不发生、也不报错），
  /// 这比没有按钮糟糕得多。所以这条断言的是"根本不渲染"。
  testWidgets('★ onAddAppWorkspace == null → 空态没有「使用默认工作区」',
      (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(drawer(
      workspaces: const <HWorkspace>[],
      onAddWorkspace: onFolder,
      // 刻意不传 —— 模拟"接线还没落地"的状态
    ));
    await settle(tester);

    expect(find.text('使用默认工作区'), findsNothing,
        reason: '回调为 null 时那次要按钮必须**不渲染** —— '
            '否则点了没反应，用户会以为界面坏了');

    // 主按钮不受影响（守卫是**只**针对次要入口的）
    expect(find.text('选择文件夹'), findsOneWidget);
    await tester.tap(find.text('选择文件夹'));
    await settle(tester);
    expect(folderCalls, 1, reason: '次要入口缺失不该影响主入口');
    expectNoException(tester);
  });

  /// 反向守卫：⊕ 菜单里的「选择文件夹」在 `onAddWorkspace == null` 时
  /// 仍然渲染（菜单项不是按回调有无裁剪的），点它只是 no-op。
  ///
  /// 钉这个是因为它与空态次要按钮的守卫策略**故意不同**：
  /// 菜单项是"用户可以点开看一眼有什么"，按钮是"承诺了就能用"。
  testWidgets('onAddWorkspace == null 时点菜单「选择文件夹」→ no-op 且不抛异常',
      (tester) async {
    await tester.pumpWidget(drawer(
      workspaces: const [
        HWorkspace(id: 'w1', name: 'proj', path: '/storage/emulated/0/proj'),
      ],
      onAddAppWorkspace: onApp,
    ));
    await settle(tester);
    await openAddMenu(tester);

    expect(find.text('选择文件夹'), findsOneWidget,
        reason: '菜单项照常渲染（用户可以点开看有哪些入口）');

    await tester.tap(find.text('选择文件夹'));
    await settle(tester);

    expect(folderCalls, 0);
    expect(appCalls, 0, reason: '点「选择文件夹」不该误触默认工作区');
    expectNoException(tester);
  });
}
