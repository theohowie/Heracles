import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/message_row.dart';
import 'package:heracles/widgets/tool_call_card.dart';

/// **H-1 回归测试**（2026-10-10，t8）—— 被拦截的调用不得被画成「成功」。
///
/// ## 被修的缺陷
///
/// 工具在一轮里有**三种**状态：成功 / 失败 / **被拦截（从未执行）**。
/// 但旧实现只用 `verdict` 里的中文字符串猜：
///
/// ```dart
/// bool get isFailure => verdict.contains('失败') ||
///                       verdict.contains('拒绝') || verdict.contains('循环');
/// ```
///
/// 而拦截类的 verdict 是 `"重复调用已拦截（第 2 次）"` 与
/// `"★ 检测到循环，强制停止"` —— **三词都不含** → `isFailure == false`
/// → 兜底路径插出一张 **`ToolStatus.success`（绿色）** 卡片。
///
/// 那条记录同时被落盘成 `ok: true`，所以**切会话/重启后依然是绿卡**。
///
/// 为什么比"失败"更糟：用户会以为**文件真的被改了**。
/// 而事实是那次调用**根本没执行**。
///
/// ## 本文件防的四件事
///
/// 1. 兜底路径对被拦截轮次**不得**插绿色成功卡（应画成「已拦截，未执行」）
/// 2. 落盘再读回，被拦截轮次**仍**是「被拦截」而不是成功
/// 3. 正常的成功/失败轮次**照旧**正确（守卫不能误伤）
/// 4. 旧数据（没有 `state` 字段）按 `ok` 回落 —— 不追溯、但不误报
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

  // ---------------------------------------------------------------- 纯模型层

  group('AgentTurn 三态解析', () {
    test('★ toolState=succeeded 才算成功', () {
      final t = AgentTurn.fromMap({
        'index': 1,
        'verdict': '工具成功',
        'tool': 'write_file',
        'toolState': 'succeeded',
      });
      expect(t.toolState, ToolState.succeeded);
      expect(t.toolSucceeded, isTrue);
      expect(t.toolExecuted, isTrue);
      expect(t.toolBlocked, isFalse);
    });

    test('★ toolState=failed 是执行过的失败（不是拦截）', () {
      final t = AgentTurn.fromMap({
        'index': 1,
        'verdict': '工具失败',
        'tool': 'write_file',
        'toolState': 'failed',
      });
      expect(t.toolState, ToolState.failed);
      expect(t.toolSucceeded, isFalse);
      // ★ 关键区分：失败**执行过**，拦截**没执行**
      expect(t.toolExecuted, isTrue);
      expect(t.toolBlocked, isFalse);
    });

    test('★★ toolState=blocked：既不是成功、也没执行过', () {
      final t = AgentTurn.fromMap({
        'index': 1,
        // 这正是 H-1 里那个"三词都不含"的 verdict
        'verdict': '重复调用已拦截（第 2 次）',
        'tool': 'write_file',
        'toolState': 'blocked',
      });
      expect(t.toolState, ToolState.blocked);
      expect(t.toolSucceeded, isFalse,
          reason: 'H-1：被拦截绝不能算成功（那会画出绿卡）');
      expect(t.toolExecuted, isFalse, reason: '被拦截 = 从未执行');
      expect(t.toolBlocked, isTrue);

      // 顺带钉住缺陷根因：光看 verdict 是判不出来的
      expect(t.isFailure, isFalse,
          reason: '这正说明为何不能用 isFailure 决定画不画绿卡');
    });

    test('未知 toolState 取值 → null（走回落，不猜成成功）', () {
      final t = AgentTurn.fromMap({
        'index': 1,
        'verdict': '将来新增的某种状态',
        'tool': 'x',
        'toolState': 'somethingNew',
      });
      expect(t.toolState, isNull);
    });

    test('旧数据（无 toolState）按 verdict 回落，且不误报成功', () {
      final legacyFail = AgentTurn.fromMap({
        'index': 1,
        'verdict': '工具失败',
        'tool': 'write_file',
      });
      expect(legacyFail.toolState, isNull);
      expect(legacyFail.toolSucceeded, isFalse, reason: '旧数据里的失败仍算失败');

      final legacyOk = AgentTurn.fromMap({
        'index': 1,
        'verdict': '工具成功',
        'tool': 'write_file',
      });
      expect(legacyOk.toolSucceeded, isTrue, reason: '旧数据里的成功仍是成功');
    });
  });

  // ---------------------------------------------------- 渲染层（兜底路径）

  group('被拦截轮次的渲染', () {
    Widget wrap(Widget child) => MaterialApp(
          theme: buildHeraclesTheme(),
          builder: (context, inner) => HueScope(
            hue: Hue.darkHue,
            child: inner ?? const SizedBox.shrink(),
          ),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        );

    testWidgets('★ HBlocked 渲染为「已拦截，未执行」，且**没有**绿色成功卡',
        (tester) async {
      await tester.pumpWidget(wrap(
        const MessageRow(
          message: HBlocked(
            id: 'b1',
            reason: '重复调用已拦截（第 2 次）',
            tool: 'write_file',
            index: 1,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('已拦截，未执行'), findsOneWidget);
      expect(find.textContaining('重复调用已拦截'), findsOneWidget);
      // ★ 不得出现工具卡片的"成功"状态词（那是绿色卡的标志）
      expect(find.text('成功'), findsNothing);
      expect(find.byType(ToolCallCard), findsNothing);
    });
  });

  // -------------------------------------------- 端到端：兜底路径 + 落盘读回

  /// 一个"被拦截"轮次的 turn（模拟 Kotlin 侧 toMap 的输出）
  Map<String, dynamic> blockedTurn() => {
        'index': 1,
        'verdict': '重复调用已拦截（第 2 次）',
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        // result 为空 —— 工具没执行，自然没有结果
        'result': '',
        'wallMs': 5,
        'cachedTokens': null,
        'promptTokens': 10,
        'outputTokens': 5,
        // ★ 结构化三态 —— 这是修复的关键
        'toolState': 'blocked',
      };

  List<Map<String, dynamic>> loadMessagesResult = [];

  /// 实时事件 sink —— `installMocks` 的 `pushDuringRun` 用它推事件
  MockStreamHandlerEventSink? sink;

  /// 侧边栏里要显示的会话（见各测试的设置）
  List<Map<String, dynamic>> sessionsOverride = [];

  /// `listSessions` 是否带 treeUri 之类都不影响 —— 只回这个列表
  void installMocks({
    required List<Map<String, dynamic>> turns,
    /// 在 `runAgent` **返回之前**推送的事件（模拟实时流）
    List<Map<String, dynamic>> pushDuringRun = const [],
  }) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'listWorkspaces':
          return [workspaceMap];
        case 'listSessions':
          return sessionsOverride;
        case 'loadMessages':
          return loadMessagesResult;
        case 'runAgent':
          // 先把事件推完（此时订阅还活着），再返回结果 ——
          // 这正是"实时路径先画、兜底路径后到"的次序
          for (final e in pushDuringRun) {
            sink?.success(e);
            await Future<void>.delayed(Duration.zero);
          }
          return <String, dynamic>{
            'stopReason': '检测到循环，已停止',
            'finalText': '',
            'sessionId': 'sess-A',
            'totalCachedTokens': 0,
            'totalPromptTokens': 0,
            'totalOutputTokens': 0,
            'steadyHitRate': null,
            'turns': turns,
          };
        default:
          return null;
      }
    });

    messenger.setMockStreamHandler(
      eventChannel,
      // ⚠️ 必须用块体：箭头体会把赋值结果当返回值，
      //    Flutter 会试图序列化它并抛 PlatformException。
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          sink = events;
        },
        onCancel: (arguments) {
          sink = null;
        },
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

  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
    loadMessagesResult = [];
    sessionsOverride = [];
    sink = null;
  });

  testWidgets('★★ H-1：被拦截轮次在兜底路径下**不得**出现绿色成功卡',
      (tester) async {
    final c = await freshController();
    // 只有一条被拦截的轮次，且**不推任何事件** —— 强制走兜底路径
    installMocks(turns: [blockedTurn()]);

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // ★★ 核心断言 1：**没有**绿色成功卡
    final cards = tester.widgetList<ToolCallCard>(find.byType(ToolCallCard));
    expect(cards.where((x) => x.call.status == ToolStatus.success), isEmpty,
        reason: 'H-1：被拦截（从未执行）却被画成了成功卡');

    // ★★ 核心断言 2：**也没有**失败卡（它不是失败，是"没执行"）
    expect(cards, isEmpty,
        reason: 'H-1：被拦截不该画成工具卡片，应当是 HBlocked');

    // ★★ 核心断言 3：应该显示为「已拦截，未执行」
    expect(find.text('已拦截，未执行'), findsOneWidget);
    expect(find.textContaining('重复调用已拦截'), findsOneWidget);
  });

  testWidgets('★ 正常的成功轮次照旧画成功卡（守卫不能误伤）', (tester) async {
    final c = await freshController();
    installMocks(turns: [
      {
        'index': 1,
        'verdict': '工具成功',
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        'result': '已写入 2 字节',
        'wallMs': 3,
        'cachedTokens': null,
        'promptTokens': 10,
        'outputTokens': 5,
        'toolState': 'succeeded',
      },
    ]);

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    final cards = tester.widgetList<ToolCallCard>(find.byType(ToolCallCard));
    expect(cards.length, 1);
    expect(cards.first.call.status, ToolStatus.success);
    expect(find.text('已拦截，未执行'), findsNothing);
  });

  testWidgets('★ 正常的失败轮次画失败卡（不是拦截）', (tester) async {
    final c = await freshController();
    installMocks(turns: [
      {
        'index': 1,
        'verdict': '工具失败',
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        'result': '失败：磁盘满',
        'wallMs': 3,
        'cachedTokens': null,
        'promptTokens': 10,
        'outputTokens': 5,
        'toolState': 'failed',
      },
    ]);

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    final cards = tester.widgetList<ToolCallCard>(find.byType(ToolCallCard));
    expect(cards.length, 1);
    expect(cards.first.call.status, ToolStatus.failure);
    // 失败**不该**被画成"已拦截"
    expect(find.text('已拦截，未执行'), findsNothing);
  });

  // -------------------------------------------------- 落盘 → 读回（round-trip）

  testWidgets('★★ H-1：落盘再读回，被拦截轮次仍是「被拦截」而非成功',
      (tester) async {
    final c = await freshController();

    // ★ 这是**真正的往返**：mock 出"磁盘里有什么"，
    //   然后走真实的 UI 路径（切会话 → loadMessages → _toMessages → 渲染），
    //   而不是直接把 HBlocked 塞进去（那样什么都没验证）。
    //
    // 磁盘形状 = SessionStore.jsonToMessage 的输出：
    //   · 新记录带 state=blocked
    //   · 兼容字段 ok=false（MainActivity 按 `ok = (state=="succeeded")` 写）
    //   · result 为空（工具没执行，自然没有结果）
    loadMessagesResult = [
      {'role': 'user', 'text': '写文件', 'ts': 1},
      {
        'role': 'tool',
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        'result': '',
        'state': 'blocked',
        'ok': false,
        // ★ 拦截原因也落盘（MainActivity 写 verdict）
        'reason': '重复调用已拦截（第 2 次）',
        'ts': 2,
      },
    ];

    installMocks(turns: []);
    // 让侧边栏里有一个可点的会话
    sessionsOverride = [
      {'id': 'sess-A', 'title': '会话 A', 'updatedAt': 2000},
    ];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    // 开抽屉 → 点会话 A → 触发 loadMessages → _toMessages → 渲染
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await settle(tester);
    expect(find.text('会话 A'), findsOneWidget,
        reason: '侧边栏应当列出会话 A —— 否则这步没真正走到读盘路径');
    await tester.tap(find.text('会话 A'));
    await settle(tester);

    // ★★ 读回后必须仍是「被拦截」，不能变成绿色成功卡
    expect(find.text('已拦截，未执行'), findsOneWidget,
        reason: 'H-1：落盘的 blocked 状态未被读回还原');
    // ★ 原因也要还原 —— 否则用户看到"被拦截"却不知为何
    expect(find.textContaining('重复调用已拦截'), findsOneWidget,
        reason: '拦截原因未落盘/未读回');
    final cards = tester.widgetList<ToolCallCard>(find.byType(ToolCallCard));
    expect(cards.where((x) => x.call.status == ToolStatus.success), isEmpty,
        reason: 'H-1：切会话/重启后又被画成了成功卡');
    expect(find.byType(ToolCallCard), findsNothing);
  });

  testWidgets('★★ N-1：同一会话连续两次运行、两次都被拦截 → 必须有 2 张拦截卡',
      (tester) async {
    final c = await freshController();
    // 全程不推事件 → 两次都走兜底路径
    installMocks(turns: [blockedTurn()]);

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    // ---- 第一次运行 ----
    await tester.enterText(find.byType(TextField).first, '第一次');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('已拦截，未执行'), findsOneWidget,
        reason: '第一次运行的拦截卡应当出现');

    // ---- 第二次运行（**同一会话**，`_messages` 不会被清空）----
    await tester.enterText(find.byType(TextField).first, '第二次');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // ★★ 核心断言：两次运行 → **两张**拦截卡
    //
    // N-1：t8 最初用「遍历整个 _messages」按 index+tool 去重，
    // 而 `AgentLoop` 每次运行的 turnIndex **都从 1 开始**、
    // 同一会话内 `_messages` 又不清空 → 第二次的卡被误判成"已画过" →
    // **静默吞掉**（实测 afterFirst=1 afterSecond=1，正确应为 1→2）。
    expect(find.text('已拦截，未执行'), findsNWidgets(2),
        reason: 'N-1：第二次运行的拦截卡被跨运行去重吞掉了');
  });

  testWidgets('★ N-1 的另一半：同轮次同工具但**参数不同** → 也必须各画一张',
      (tester) async {
    final c = await freshController();
    installMocks(turns: [
      blockedTurn(),
      {
        ...blockedTurn(),
        // 同 index(1)、同 tool(write_file)，但 args 不同
        'args': {'path': 'b.txt'},
      },
    ]);

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写两个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // ★ 只比 index+tool 会把第二条误判成重复 —— 所以 key 必须含 args
    expect(find.text('已拦截，未执行'), findsNWidgets(2),
        reason: 'N-1：只比 index+tool 会误合并参数不同的两次拦截');
  });

  testWidgets('★ N-2：实时 Blocked 事件 + 兜底路径同时存在时只画一张',
      (tester) async {
    final c = await freshController();

    // 同一次运行里：
    //   · 实时流推一条 Blocked（index=1 / write_file / path=a.txt）
    //   · run() 返回的 turns 里也有同一条 blocked
    // 两条路径都会尝试画 —— 但用户只该看到**一张**。
    installMocks(
      turns: [blockedTurn()],
      pushDuringRun: [
        {
          'type': 'blocked',
          'ts': 1,
          'index': 1,
          'tool': 'write_file',
          'args': {'path': 'a.txt'},
          'reason': '重复调用已拦截（第 2 次）',
        },
      ],
    );

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // 实时路径先画了；兜底路径见到同一个 key → 跳过
    expect(find.text('已拦截，未执行'), findsOneWidget,
        reason: 'N-2：同一拦截被实时与兜底两条路径各画了一张');
  });

  testWidgets('★ 旧数据（无 state 字段）读回按 ok 回落，不误报', (tester) async {
    final c = await freshController();

    // 旧记录：只有 ok，没有 state
    loadMessagesResult = [
      {
        'role': 'tool',
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        'result': '已写入 2 字节',
        'ok': true,
        'ts': 1,
      },
    ];
    installMocks(turns: []);
    sessionsOverride = [
      {'id': 'sess-A', 'title': '会话 A', 'updatedAt': 2000},
    ];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await settle(tester);
    await tester.tap(find.text('会话 A'));
    await settle(tester);

    // 旧数据的 ok:true 仍是成功（我们**刻意不追溯**）
    final cards = tester.widgetList<ToolCallCard>(find.byType(ToolCallCard));
    expect(cards.length, 1);
    expect(cards.first.call.status, ToolStatus.success);
    expect(find.text('已拦截，未执行'), findsNothing);
  });
}
