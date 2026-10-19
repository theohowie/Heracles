import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';

/// **「切会话后原会话不工作」的判定与回归测试**（2026-10-11，t11）。
///
/// ## 用户原话
///
/// > 「切换会话，原会话就不工作的 bug」
///
/// ## 先把 (a) 与 (b) 分开
///
/// **(a) 预期行为**：切走后，**先前那次运行的结果不再渲染到界面上**。
/// 这是 t7 的有意设计，正确 —— 数据不丢（Kotlin 已落盘，切回时读回）。
///
/// **(b) 真 bug**：切**回**原会话后，那次运行的结果**永远不出现** /
/// 界面看起来「卡住／不工作」。
///
/// 本文件先用测试**证伪或证实**各条路径，再谈修法。
///
/// ## 关键背景：磁盘什么时候才有内容
///
/// `MainActivity.handleRunAgent` 的顺序是：
///   1. 用户消息**先落盘**
///   2. `bridge.run(...)` —— 整个 agent 循环跑完才返回
///   3. `persistTurns(...)` —— **工具记录与助手回答在最后一次性写盘**
///   4. `result.success(map)`
///
/// 所以**运行期间磁盘上只有用户那条消息**。中途切回原会话，
/// 从磁盘读回的就是「半截会话」。
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

  /// 模拟磁盘内容（按会话 id）
  late Map<String, List<Map<String, dynamic>>> disk;

  /// 只 gate **第二次**运行 —— 第一次用它建立「已有会话 A」的前提
  Completer<void>? gate;

  late int runCount;

  /// 与 Kotlin 侧 toMap 同形的一条「工具成功」轮次
  Map<String, dynamic> toolTurn() => {
        'index': 1,
        'verdict': '工具成功',
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        'result': '已写入',
        'wallMs': 3,
        'cachedTokens': null,
        'promptTokens': 10,
        'outputTokens': 5,
        'toolState': 'succeeded',
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
        case 'runAgent':
          runCount++;
          final n = runCount;
          final req = (call.arguments as Map)['request'] as String? ?? '';
          final sid = ((call.arguments as Map)['sessionId'] as String?) ?? 'sess-A';

          // ① 用户消息先落盘（与 Kotlin 一致）
          (disk[sid] ??= []).add(
            {'role': 'user', 'text': req, 'ts': 1},
          );

          // ② 第二次运行被 gate 卡住 —— 模拟「还在跑」
          final g = gate;
          if (n >= 2 && g != null) {
            await g.future;
          }

          // ③ persistTurns：工具记录 + 助手回答，**在最后一次性写盘**
          (disk[sid] ??= []).add({
            'role': 'tool',
            'tool': 'write_file',
            'args': {'path': 'a.txt'},
            'result': '已写入',
            'state': 'succeeded',
            'ok': true,
            'ts': 2,
          });
          (disk[sid] ??= []).add({
            'role': 'assistant',
            'text': '【第 $n 次的回答】',
            'cached': null,
            'prompt': 10,
            'out': 5,
            'ms': 3,
            'ts': 3,
          });

          // ④ 返回结果
          return <String, dynamic>{
            'stopReason': '已给出最终回答',
            'finalText': '【第 $n 次的回答】',
            'sessionId': sid,
            'totalCachedTokens': 0,
            'totalPromptTokens': 0,
            'totalOutputTokens': 0,
            'steadyHitRate': null,
            'turns': [toolTurn()],
          };
        default:
          return null;
      }
    });

    messenger.setMockStreamHandler(
      eventChannel,
      // 本文件刻意**不推任何事件**：要单独考察「兜底路径 + 切会话」。
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

  /// 开抽屉 → 点某个会话标题。
  ///
  /// 用 `find.descendant(of: Drawer)` 限定范围：标题栏也会显示会话名，
  /// 不加限定会命中多个。
  Future<void> switchTo(WidgetTester tester, String title) async {
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await settle(tester);
    final inDrawer =
        find.descendant(of: find.byType(Drawer), matching: find.text(title));
    expect(inDrawer, findsOneWidget, reason: '抽屉里应当能看到「$title」');
    await tester.tap(inDrawer);
    await settle(tester);
  }

  /// 发一条消息
  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).first, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 把正文列表滚到底 —— **惰性构建**的 ListView 不会创建视口外的条目。
  ///
  /// 不加这一步，断言"最新的那条消息可见"会**假失败**：
  /// 消息确实在 `_messages` 里，只是没被构建。
  /// （排查时用探针确认过模型里有 6 条，屏幕上只渲染到第 4 条。）
  Future<void> scrollToBottomOfList(WidgetTester tester) async {
    final list = find.byType(Scrollable);
    if (list.evaluate().isEmpty) return;
    await tester.drag(list.first, const Offset(0, -600));
    await tester.pump();
    await tester.drag(list.first, const Offset(0, -600));
    await settle(tester);
  }

  /// 输入框是否可用
  bool inputEnabled(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).enabled != false;

  setUp(() {
    disk = {};
    gate = null;
    runCount = 0;
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  // ==================================================================
  // 前提：先用一次「不 gate」的运行把会话 A 建立起来
  // ==================================================================

  /// 发第一条消息 → 自动建会话 A → 结果落盘、界面显示。
  Future<void> establishSessionA(WidgetTester tester, SettingsController c) async {
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await send(tester, '第一条');
    await scrollToBottomOfList(tester);
    expect(find.text('【第 1 次的回答】'), findsWidgets,
        reason: '前提：第一次运行应当正常显示');
  }

  // ==================================================================
  // ★★ B1：切走再切回，原会话的结果必须出现
  // ==================================================================

  testWidgets('★★ B1：切到 B 再切回 A，A 的结果仍必须出现（不能永久丢失）',
      (tester) async {
    final c = await freshController();
    installMocks();
    await establishSessionA(tester, c);

    // 第二次运行：gate 卡住
    gate = Completer<void>();
    await send(tester, '第二条');

    // 此刻 A 还在跑
    expect(find.text('【第 2 次的回答】'), findsNothing,
        reason: '前提：第二次运行还没完成');

    // ---- 用户切到 B，再切回 A ----
    await switchTo(tester, '会话 B');
    await switchTo(tester, '会话 A');

    // 切回来时磁盘只有 user(第一条)+tool+asst1+user(第二条)
    // （第二次运行还没写盘）—— 所以第 2 次的回答此刻必然还不存在
    expect(find.text('【第 2 次的回答】'), findsNothing);

    // ---- 放行：第二次运行完成 ----
    gate!.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 600));

    // ★★ 核心断言：用户此刻正看着 A，A 的运行结果**必须**出现在列表里
    //
    // ⚠️ 必须先滚到底：正文是 `ListView.builder`（**惰性构建**），
    // 视口外的条目**根本不会创建**。第二次运行后列表已有 6 条消息，
    // 最新的那条在视口外 —— 不滚就断言 `findsNothing`，
    // 那是**测试的假失败**，不是产品缺陷（我用探针确认过：
    // 模型里确实有「第 2 次的回答」）。
    //
    // 这也正是真实用户会做的动作：新内容在底部，得往下滚才看得到。
    await scrollToBottomOfList(tester);

    expect(find.text('【第 2 次的回答】'), findsWidgets,
        reason: 'B1：切走再切回后，原会话的结果被永久丢弃 —— '
            '用户看到的就是「原会话不工作了」');
  });

  testWidgets('★ B1：切回仍在运行的会话时，必须有「正在运行」提示（不能静默半截）',
      (tester) async {
    final c = await freshController();
    installMocks();
    await establishSessionA(tester, c);

    gate = Completer<void>();
    await send(tester, '第二条');

    await switchTo(tester, '会话 B');
    await switchTo(tester, '会话 A');

    // ★ 回到 A 时它仍在跑 —— 界面必须能读懂"它还在跑"
    //
    // 2026-10-13：顶部横幅已移除，改由**发送键图标**承载语义。
    // 回到正在跑的 A → 发送键是**停止**（用户知道这里在跑、能停）。
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget,
        reason: '切回一个正在运行的会话，却读不出"它还在跑" —— '
            '用户看到半截会话会以为它坏了');

    gate!.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 600));
  });

  // ==================================================================
  // ★ B2：A 在跑时切到 B —— 必须给出诚实的说明，而不是静默禁用输入
  // ==================================================================

  testWidgets('★ B2：A 在跑时切到 B，必须解释为什么不能发消息（不静默禁用）',
      (tester) async {
    final c = await freshController();
    installMocks();
    disk['sess-B'] = [
      {'role': 'assistant', 'text': 'B 原本的内容', 'ts': 1},
    ];
    await establishSessionA(tester, c);

    gate = Completer<void>();
    await send(tester, '第二条');

    await switchTo(tester, '会话 B');

    // ★ 2026-10-13 改：A 在跑时切到 B，B 的输入框**仍可用**（排队发送）
    //
    // 用户原话：「排队发送，当会话有在工作时，点不了输入框发送消息」。
    // `BusySendBehavior.queue` 是默认值 —— 忙时输入框保持可用，
    // 消息进队列，当前运行结束后自动发出。
    //
    // **但这不产生并行**：队列最多一条，且只在 `_busy == false`
    // 之后才发（见 `_drainQueue`）—— 单 sink 的结构性约束依然成立。
    expect(inputEnabled(tester), isTrue,
        reason: '排队发送模式下切到 B 仍应能输入 —— '
            '禁用输入正是用户报的问题');

    // ★ 但仍必须能读懂"A 在别处跑"（t14 的核心要求，2026-10-13 换承载）
    //
    // 在 B 看到的应该是**沙漏**（"不是这里在跑，是在等"），
    // **绝不能是停止图标** —— 那会让用户以为能停 B 的东西。
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget,
        reason: 'A 在跑而用户在 B：发送键必须表达"等待"而非"停止" —— '
            '否则用户以为能停 B 的东西、或以为 B 卡住了');
    expect(find.byIcon(Icons.stop_rounded), findsNothing,
        reason: 'B 上没有运行，不该出现停止语义');

    // 且 B 自己的内容仍在（没被 A 的进度污染）
    expect(find.text('B 原本的内容'), findsOneWidget);

    gate!.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 600));
  });

  // ==================================================================
  // 不回归：B 的列表不得被 A 的结果污染（t7 语义必须保持）
  // ==================================================================

  testWidgets('★ 不回归：切到 B 后，A 的结果仍不得串进 B', (tester) async {
    final c = await freshController();
    installMocks();
    // B 有自己的历史
    disk['sess-B'] = [
      {'role': 'assistant', 'text': 'B 原本的内容', 'ts': 1},
    ];
    await establishSessionA(tester, c);

    gate = Completer<void>();
    await send(tester, '第二条');
    await switchTo(tester, '会话 B');

    gate!.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('【第 2 次的回答】'), findsNothing,
        reason: 't7 语义：A 的结果不得渲染进 B');
    expect(find.text('B 原本的内容'), findsOneWidget,
        reason: 'B 自己的内容不该被覆盖');
  });
}
