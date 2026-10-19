import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/usage_sidebar.dart';

/// **会话用量在真实界面里的接线测试**（2026-10-11，t13）。
///
/// ## 为什么单测 `SessionUsage` 之外还要这一层
///
/// `session_usage_test.dart` 证明的是**算法**对（null 不参与、加权、标 `~`）。
/// 但算法对 ≠ 界面真的用了它。这一层证明的是**接线**：
///
/// 1. 跑完一次运行后，标题栏指示器**真的**显示了数（而不是永远 `—`）
/// 2. `AgentTurn.cachedTokens == null` 的轮次**没被当成 0** 混进累计
/// 3. **切会话后显示的是另一个会话的账**（"当前会话"语义，不是全局）
/// 4. 切走期间跑完的那次，账仍记在**发起它的会话**头上（不少算）
///
/// ## 数据来源的坑（`docs/24` §7.1）
///
/// `.jsonl` 里没有各轮 token，所以**切回同一会话时不能从磁盘恢复** ——
/// 内存里的 Map 才是真相。下面第 3 条正好把这个语义钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const commandChannel = MethodChannel('heracles/command');
  const eventChannel = EventChannel('heracles/events');

  const workspaceMap = <String, dynamic>{
    'path': '/storage/emulated/0/proj',
    'name': 'proj',
    'treeUri': '',
    'writable': true,
  };

  const sessions = <Map<String, dynamic>>[
    {'id': 'sess-A', 'title': '会话 A', 'updatedAt': 2000},
    {'id': 'sess-B', 'title': '会话 B', 'updatedAt': 1000},
  ];

  late Map<String, List<Map<String, dynamic>>> disk;

  /// 每次 run 返回的轮次（可逐次改写，用来构造 null / 非 null 的混合）
  late List<Map<String, dynamic>> Function(int runIndex) turnsForRun;

  Completer<void>? gate;
  late int runCount;

  /// 造一条「轮次」记录（`AgentTurn.fromMap` 的形状）。
  ///
  /// ⚠️ 字段名必须与 `AgentTurn.fromMap` 一致：
  /// `cachedTokens` / `promptTokens` / `outputTokens` ——
  /// 我第一版写成 `cached`/`prompt`/`out`（那是**落盘**用的名字，
  /// 见 `MainActivity.persistTurns`），结果全被解析成 null，
  /// 测试"失败"得莫名其妙。**探针查到真相后改对了**。
  Map<String, dynamic> turn({
    int? cachedTokens,
    int promptTokens = 100,
    int outputTokens = 10,
    int wallMs = 1000,
    bool withTool = false,
  }) =>
      {
        'index': 1,
        'verdict': withTool ? '工具成功' : '给出最终回答',
        'tool': withTool ? 'write_file' : null,
        'args': withTool ? {'path': 'a.txt'} : null,
        'result': withTool ? '已写入' : null,
        'wallMs': wallMs,
        'cachedTokens': cachedTokens,
        'promptTokens': promptTokens,
        'outputTokens': outputTokens,
        'toolState': withTool ? 'succeeded' : null,
      };

  void installMocks() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'listWorkspaces':
          return [workspaceMap];
        case 'listSessions':
          return sessions;
        case 'loadMessages':
          final sid = (call.arguments as Map)['sessionId'] as String?;
          return disk[sid] ?? <Map<String, dynamic>>[];
        case 'usageInfo':
          // 冻结区 ~5200，上限 1000000 → 便于断言指示器显示占比
          return {'frozenTokens': 5200, 'contextLimit': 1000000};
        case 'runAgent':
          runCount++;
          final n = runCount;
          final req = (call.arguments as Map)['request'] as String? ?? '';
          final sid = ((call.arguments as Map)['sessionId'] as String?) ?? 'sess-A';

          (disk[sid] ??= []).add({'role': 'user', 'text': req, 'ts': 1});

          final g = gate;
          if (g != null) await g.future;

          final turns = turnsForRun(n);
          (disk[sid] ??= []).add({
            'role': 'assistant',
            'text': '【第 $n 次的回答】',
            'ts': 3,
          });

          return <String, dynamic>{
            'stopReason': '已给出最终回答',
            'finalText': '【第 $n 次的回答】',
            'sessionId': sid,
            'turns': turns,
          };
        default:
          return null;
      }
    });

    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {},
        onCancel: (arguments) {},
      ),
    );
  }

  Future<SettingsController> freshController() async {
    SharedPreferences.setMockInitialValues({});
    return SettingsController.load();
  }

  Widget wrapScreen(SettingsController c) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: ChatScreen(settings: c),
      );

  Future<void> settle(WidgetTester tester, {int times = 12}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> switchTo(WidgetTester tester, String title) async {
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await settle(tester);
    final inDrawer =
        find.descendant(of: find.byType(Drawer), matching: find.text(title));
    expect(inDrawer, findsOneWidget);
    await tester.tap(inDrawer);
    await settle(tester);
  }

  /// 读标题栏指示器里的数字（现在有**两个**：命中率 + 上下文占比）。
  ///
  /// 用「以 `%` 或 `—` 结尾」来筛 —— 图标与 `*` 都不是这类文本。
  List<String> indicatorValues(WidgetTester tester) {
    expect(find.byType(UsageIndicator), findsOneWidget,
        reason: '标题栏必须有常驻指示器');
    return tester
        .widgetList<Text>(find.descendant(
          of: find.byType(UsageIndicator),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .where((s) => s.endsWith('%') || s == '—')
        .toList();
  }

  setUp(() {
    disk = {};
    gate = null;
    runCount = 0;
    // 默认：每轮都上报缓存（90% 命中）
    turnsForRun = (_) =>
        [turn(cachedTokens: 900, promptTokens: 100, outputTokens: 10, wallMs: 1000)];
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  // ==================================================================

  testWidgets('★ 指示器常驻可见；跑完后显示真实的上下文占比', (tester) async {
    final c = await freshController();
    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    // 一开始还没跑过：冻结区未建立 → 占比 0% 而不是 "—"
    // （上限已知、已用 0 ⇒ 显示 0%）
    expect(find.byType(UsageIndicator), findsOneWidget);

    await send(tester, '你好');
    await tester.pump(const Duration(milliseconds: 400));

    // 跑了之后：冻结区 5200 + 对话文本 + 上限 1M ⇒ 占比很小但**有值**
    final values = indicatorValues(tester);
    expect(values.length, 2, reason: '命中率与上下文占比都要常驻');
    // 命中率 90%（本轮 cached 900 / prompt 100）
    expect(values.first, '90%');
  });

  testWidgets('★★ null 轮次不参与：指示器按已上报轮次算，且带 `*` 标注', (tester) async {
    final c = await freshController();
    installMocks();
    // 一次运行两轮：一轮上报 90%，一轮未上报
    turnsForRun = (_) => [
          turn(cachedTokens: 900, promptTokens: 100, outputTokens: 10, wallMs: 1000),
          turn(cachedTokens: null, promptTokens: 5000, outputTokens: 10, wallMs: 1000),
        ];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await send(tester, '你好');
    await tester.pump(const Duration(milliseconds: 400));

    // 打开右侧边栏看细节
    await tester.tap(find.byType(UsageIndicator));
    await settle(tester);

    // 命中率 = 900 / (900 + 100) = 90%（未上报的 5000 prompt **不进分母**）
    //
    // ⚠️ 限定在 `UsageSidebar` 内查找：标题栏指示器也显示命中率，
    //    不限定会命中两个（实测：`Found 2 widgets with text "90%"`）。
    expect(
      find.descendant(
          of: find.byType(UsageSidebar), matching: find.text('90%')),
      findsOneWidget,
      reason: '未上报轮次不得稀释命中率',
    );
    // ★ 必须标注分母
    expect(find.textContaining('1 轮未上报'), findsOneWidget);
    expect(find.textContaining('共 2 轮'), findsOneWidget);
    // 指示器上带 `*`
    expect(find.text('*'), findsWidgets);
  });

  testWidgets('★★ 全部未上报 → 边栏显示「不可用」，绝不显示 0%', (tester) async {
    final c = await freshController();
    installMocks();
    turnsForRun = (_) =>
        [turn(cachedTokens: null, promptTokens: 1000, outputTokens: 10, wallMs: 1000)];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await send(tester, '你好');
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byType(UsageIndicator));
    await settle(tester);

    // 限定在边栏内（标题栏那格显示 `—` 而不是「不可用」，两者措辞不同）
    expect(
      find.descendant(
          of: find.byType(UsageSidebar), matching: find.text('不可用')),
      findsOneWidget,
    );
    expect(find.text('0%'), findsNothing,
        reason: '把 null 显示成 0% 是契约 §3.4 明令禁止的');
  });

  testWidgets('★★ 切会话后显示的是**另一个会话**的账（当前会话语义，不是全局）',
      (tester) async {
    final c = await freshController();
    installMocks();
    disk['sess-B'] = [
      {'role': 'assistant', 'text': 'B 的历史', 'ts': 1},
    ];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    // A 发 3 条 → A 累计 3 轮
    await send(tester, 'A1');
    await tester.pump(const Duration(milliseconds: 300));
    await send(tester, 'A2');
    await tester.pump(const Duration(milliseconds: 300));
    await send(tester, 'A3');
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byType(UsageIndicator));
    await settle(tester);
    expect(find.text('3'), findsWidgets, reason: 'A 应当累计到 3 次运行');
    await tester.tap(find.byIcon(Icons.close_rounded));
    await settle(tester);

    // 切到 B：B 从没跑过 → 应该是**零**（不是接着显示 A 的 3）
    await switchTo(tester, '会话 B');
    await tester.tap(find.byType(UsageIndicator));
    await settle(tester);

    expect(find.text('不可用'), findsOneWidget,
        reason: 'B 没有任何运行 —— 命中率应显示不可用（而不是 A 的值）');
    expect(find.text('3'), findsNothing,
        reason: 'B 不该显示 A 的累计 —— 这是"当前会话"的统计');
  });

  testWidgets('★ 切走期间跑完的那次，账仍记在**发起它的会话**头上（不少算）',
      (tester) async {
    final c = await freshController();
    installMocks();
    disk['sess-B'] = [
      {'role': 'assistant', 'text': 'B 的历史', 'ts': 1},
    ];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    // A 发一条，card 住
    gate = Completer<void>();
    await send(tester, 'A1');
    expect(find.text('【第 1 次的回答】'), findsNothing, reason: '前提：还在跑');

    // 切到 B（A 仍在跑）
    await switchTo(tester, '会话 B');

    // 放行 → A 的结果不渲染进 B（t7 语义），但**账要记给 A**
    gate!.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));

    // 切回 A：应能看到 A 那一次的用量（说明记账没丢）
    await switchTo(tester, '会话 A');
    await tester.tap(find.byType(UsageIndicator));
    await settle(tester);

    expect(
      find.descendant(
          of: find.byType(UsageSidebar), matching: find.text('90%')),
      findsOneWidget,
      reason: '切走期间跑完的那次，用量必须记在 A 上 —— 不能随渲染守卫一起被丢掉',
    );
  });

  testWidgets('★ 不回归：B 的列表里不得出现 A 的结果（t7 语义保持）', (tester) async {
    final c = await freshController();
    installMocks();
    disk['sess-B'] = [
      {'role': 'assistant', 'text': 'B 的历史', 'ts': 1},
    ];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    gate = Completer<void>();
    await send(tester, 'A1');
    await switchTo(tester, '会话 B');
    gate!.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('【第 1 次的回答】'), findsNothing,
        reason: 'A 的结果不得渲染进 B');
    expect(find.text('B 的历史'), findsWidgets);
  });

  // ==================================================================
  // ★ 手势约定（docs/24 §4.3 + docs/21 §2.2）
  // ==================================================================

  testWidgets('★★ 右侧边栏：关掉「关闭态边缘滑动」，避免与系统返回抢手势',
      (tester) async {
    final c = await freshController();
    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);

    // ★ 核心：右侧**不挂**边缘打开手势。
    //
    // 理由（docs/24 §4.3）：Android 的返回手势**左右边缘都有**，
    // 而"右滑关闭"又是抽屉通用手势 —— 让右边缘同时承担两种含义必然打架。
    //
    // 注意这不影响"打开态右滑关闭"：Flutter `DrawerController` 只在
    // `_controller.isDismissed`（关闭态）分支才挂那个 GestureDetector，
    // 打开态用的是另一个常驻手势（见 `drawer.dart`）。
    // 所以**打开走按钮、关闭可右滑**，正是 docs/24 的建议。
    expect(scaffold.endDrawerEnableOpenDragGesture, isFalse,
        reason: '右侧边缘不能让抽屉抢手势 —— 那是系统返回区');

    // 左侧**保持** 200dp（docs/21 实测定的，不要顺手改动）
    expect(scaffold.drawerEnableOpenDragGesture, isTrue);
    expect(scaffold.drawerEdgeDragWidth, 200);

    // 右侧边栏确实挂在 Scaffold 上（而不只是一个未使用的组件）
    expect(scaffold.endDrawer, isNotNull,
        reason: 'endDrawer 必须真的挂在 Scaffold 上');
  });
}
