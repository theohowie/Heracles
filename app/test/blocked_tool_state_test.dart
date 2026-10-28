import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/attachment.dart';
import 'package:heracles/models/message.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/agent_bridge.dart'
    show AgentBridge, AgentEvent, AgentRunResult, AgentTurn, ToolState;
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_topbar.dart' show PlainToolLine;
import 'package:heracles/widgets/message_row.dart';

import 'support/secure_storage_mock.dart';

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
///
/// ## ★★ mock 基建重接（2026-10-25，mock 回家第二批）
///
/// 旧夹具 mock 的是**已删除的传输**（`heracles/command` 的
/// `runAgent` / `listSessions` / `loadMessages` + `EventChannel`）。
/// 本文件是**空跑变绿风险最高**的一个：多数断言是 `findsNothing`
/// （"不得出现绿卡"），mock 死掉后它们**照样绿** —— 变的只是"什么都没测"。
/// 现在按真通道重接：
///
/// | 旧 shape | 今天 |
/// |---|---|
/// | `runAgent` + `sink.success` | `AgentBridge.executorFactoryForTest` 注入
///   [_FakeExecutor]；事件走 `handle.events → emitLocalEvent → UI`（生产同路） |
/// | `listSessions` / `loadMessages`（command 通道） | `heracles/device` 的
///   `fs.*`（`SessionStore` 的真通道：`sessions.json` + `<sid>.jsonl`） |
/// | `EventChannel` | 已删除，零构造（不再 mock） |
///
/// **断言与测试体零改动**（除 finder 随 UI 改版换过：抽屉入口改成品牌图标、
/// 输入框改成 `CupertinoTextField`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 安全存储通道 mock（坑 36）：没有它，任何 `SettingsController.load()`
  //   的用例都会**永久挂死**（原始状态实测：本文件第 7 条用例 10 分钟超时）。
  setUp(installSecureStorageMock);
  tearDown(removeSecureStorageMock);

  const commandChannel = MethodChannel('heracles/command');
  const deviceChannel = MethodChannel('heracles/device');

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
      // ★ 口径变更（2026-10-25）：工具调用**不再用 `ToolCallCard` 渲染**
      //   —— 2026-10-24 黑白改版起是**纯文字行** `PlainToolLine`
      //   （见 `message_row._toolLine`）。H-1 要钉的语义**一个字没变**：
      //   被拦截 ≠ 一次成功的工具调用。今天的"成功"可见标志是那行
      //   **完成态动词**摘要（`写入了 …`）—— 被拦截必须两样都没有。
      expect(find.byType(PlainToolLine), findsNothing,
          reason: '被拦截不该画成工具行');
      expect(find.textContaining('写入了'), findsNothing,
          reason: 'H-1 的"绿卡"今天 = 完成态动词的工具行；被拦截绝不能有');
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

  /// `sessions.json` 的内容（侧边栏要显示的会话，见各测试的设置）
  List<Map<String, dynamic>> sessionsOverride = [];

  /// `<sid>.jsonl` 的内容（"磁盘上有什么"）—— 与旧 `loadMessages` 的返回值同形状，
  /// 只是**换到真通道**上（`heracles/device` 的 `fs.readText`）。
  List<Map<String, dynamic>> diskMessages = [];

  /// 推一条事件到 UI（等价旧 `pushRef`；事件形状仍按 Map 描述）。
  Future<void> Function(Map<String, dynamic>)? pushRef;

  void installMocks({
    required List<Map<String, dynamic>> turns,

    /// 在假执行器收尾**之前**推送的事件（模拟实时流）
    List<Map<String, dynamic>> pushDuringRun = const [],
  }) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // ---- 工作区登记表（heracles/command —— 这条至今是 Kotlin 的）----
    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      if (call.method == 'listWorkspaces') return [workspaceMap];
      return null;
    });

    // ---- 会话存储（heracles/device 的 fs.* —— SessionStore 的真通道）----
    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      final path = args['path'] as String? ?? '';
      switch (call.method) {
        case 'fs.stat':
          // 新会话 id 探测：永不撞
          return <String, dynamic>{'ok': true, 'exists': false};
        case 'fs.readText':
          if (path.endsWith('sessions.json')) {
            return <String, dynamic>{
              'ok': true,
              'text': jsonEncode(sessionsOverride),
              'truncated': false,
            };
          }
          return <String, dynamic>{
            'ok': true,
            'text': diskMessages.map((r) => jsonEncode(r)).join('\n'),
            'truncated': false,
          };
        case 'fs.readTailLines':
          return <String, dynamic>{
            'ok': true,
            'lines': [for (final r in diskMessages) jsonEncode(r)],
          };
        case 'fs.appendText':
        case 'fs.writeText':
        case 'fs.mkdir':
        case 'fs.delete':
          return <String, dynamic>{'ok': true};
        default:
          return <String, dynamic>{
            'ok': false,
            'error': '测试 mock：未知方法 ${call.method}',
          };
      }
    });

    // ---- run 注入（executorFactoryForTest —— 生产同路）----
    AgentBridge.executorFactoryForTest =
        ({required workspacePath, required settings, required sessionStore, askGate}) {
      return _FakeExecutor(
        workspacePath: workspacePath,
        settings: settings,
        sessionStore: sessionStore,
        askGate: askGate,
        turns: turns,
        onReady: (push) => pushRef = push,
        onScript: () async {
          // 先把事件推完（此时订阅还活着），再返回结果 ——
          // 这正是"实时路径先画、兜底路径后到"的次序
          for (final e in pushDuringRun) {
            await pushRef!(e);
          }
        },
      );
    };
  }

  /// 造一个**已配置**的设置控制器 —— 不配 provider 时 `AgentBridge.run()`
  /// 会**就地抛错**（ADR-035 S4 有意为之），根本走不到假执行器。
  Future<SettingsController> freshController() async {
    SharedPreferences.setMockInitialValues({});
    final c = await SettingsController.load();
    await c.updateProvider(const ModelProviderConfig(
      id: 'deepseek-account',
      name: 'DeepSeek 账号',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      apiKey: 'sk-test',
    ));
    await c.setActiveProvider('deepseek-account');
    return c;
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

  /// **打开抽屉**：原型 01（2026-10-25）之后顶栏左侧是**品牌图标**
  /// （点它开抽屉），按 **asset 名**定位 —— 见 `session_guard_test.dart`。
  Future<void> openDrawer(WidgetTester tester) async {
    final opener = find.byWidgetPredicate(
      (w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName.contains('app_icon_source'),
      description: '顶栏左侧品牌图标（打开抽屉）',
    );
    expect(opener, findsOneWidget,
        reason: '顶栏左侧必须有品牌图标（点它开抽屉）—— 找不到说明顶栏又改了');
    await tester.tap(opener);
    await settle(tester);
  }

  /// 开抽屉 → 点会话（限定在 Drawer 内，避开顶栏同名的 ActiveSession 标题）。
  Future<void> openSession(WidgetTester tester, String title) async {
    await openDrawer(tester);
    final inDrawer =
        find.descendant(of: find.byType(Drawer), matching: find.text(title));
    expect(inDrawer, findsOneWidget,
        reason: '侧边栏应当列出「$title」—— 否则这步没真正走到读盘路径');
    await tester.tap(inDrawer);
    await settle(tester);
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
    AgentBridge.executorFactoryForTest = null;
    sessionsOverride = [];
    diskMessages = [];
    pushRef = null;
  });

  testWidgets('★★ H-1：被拦截轮次在兜底路径下**不得**出现绿色成功卡',
      (tester) async {
    final c = await freshController();
    // 只有一条被拦截的轮次，且**不推任何事件** —— 强制走兜底路径
    installMocks(turns: [blockedTurn()]);

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    await tester.enterText(find.byType(CupertinoTextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // ★★ 核心断言 1+2（口径变更 2026-10-25，见上）：被拦截轮次
    //   **一条工具行都不该有** —— 既不是成功（`写入了 …`）也不是失败
    //   （`…（失败）`），而应当是一条 HBlocked。
    //   旧版本这里查的是 `ToolCallCard` 的 `call.status`；今天工具行是
    //   `PlainToolLine`，状态只能从**摘要动词**读（且它是公开字段，可直接断言）。
    final lines = tester.widgetList<PlainToolLine>(find.byType(PlainToolLine));
    expect(lines, isEmpty,
        reason: 'H-1：被拦截不该画成工具行（更不该画成成功行），应当是 HBlocked');
    expect(find.textContaining('写入了'), findsNothing,
        reason: 'H-1：被拦截（从未执行）却被画成了成功态工具行');

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

    await tester.enterText(find.byType(CupertinoTextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    final lines =
        tester.widgetList<PlainToolLine>(find.byType(PlainToolLine)).toList();
    expect(lines.length, 1);
    expect(lines.single.summary, '写入了 a.txt',
        reason: '成功轮次 = 完成态动词（今天"成功"的可见标志）');
    expect(lines.single.summary, isNot(contains('失败')));
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

    await tester.enterText(find.byType(CupertinoTextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    final lines =
        tester.widgetList<PlainToolLine>(find.byType(PlainToolLine)).toList();
    expect(lines.length, 1);
    expect(lines.single.summary, '写入了 a.txt（失败）',
        reason: '失败轮次必须带「（失败）」—— 不能被画成成功态');
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
    // ★ 2026-10-25：这条路径的判据从"command 通道的 loadMessages"换成
    //   **设备通道上 `<sid>.jsonl` 的真实内容**（`SessionStore` 走 `fs.readText`）
    //   —— 比旧夹具更接近事实（旧夹具 mock 的通道已删除，永远返回空）。
    //
    // 磁盘形状 = SessionStore 的输出：
    //   · 新记录带 state=blocked
    //   · 兼容字段 ok=false
    //   · result 为空（工具没执行，自然没有结果）
    //   · 拦截原因落盘（写 verdict）
    diskMessages = [
      {'role': 'user', 'text': '写文件', 'ts': 1},
      {
        'role': 'tool',
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        'result': '',
        'state': 'blocked',
        'ok': false,
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
    await openSession(tester, '会话 A');

    // ★★ 读回后必须仍是「被拦截」，不能变成绿色成功卡
    expect(find.text('已拦截，未执行'), findsOneWidget,
        reason: 'H-1：落盘的 blocked 状态未被读回还原');
    // ★ 原因也要还原 —— 否则用户看到"被拦截"却不知为何
    expect(find.textContaining('重复调用已拦截'), findsOneWidget,
        reason: '拦截原因未落盘/未读回');
    expect(find.byType(PlainToolLine), findsNothing,
        reason: 'H-1：切会话/重启后又被画成了工具行（= 成功态）');
    expect(find.textContaining('写入了'), findsNothing,
        reason: 'H-1：落盘的 blocked 状态被读成了成功态');
  });

  testWidgets('★★ N-1：同一会话连续两次运行、两次都被拦截 → 必须有 2 张拦截卡',
      (tester) async {
    final c = await freshController();
    // 全程不推事件 → 两次都走兜底路径
    installMocks(turns: [blockedTurn()]);

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    // ---- 第一次运行 ----
    await tester.enterText(find.byType(CupertinoTextField).first, '第一次');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('已拦截，未执行'), findsOneWidget,
        reason: '第一次运行的拦截卡应当出现');

    // ---- 第二次运行（**同一会话**，`_messages` 不会被清空）----
    await tester.enterText(find.byType(CupertinoTextField).first, '第二次');
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

    await tester.enterText(find.byType(CupertinoTextField).first, '写两个文件');
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

    await tester.enterText(find.byType(CupertinoTextField).first, '写文件');
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
    diskMessages = [
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
    await openSession(tester, '会话 A');

    // 旧数据的 ok:true 仍是成功（我们**刻意不追溯**）
    // ★ 口径变更：同上 —— 成功今天的可见标志是完成态动词的 `PlainToolLine`。
    final lines =
        tester.widgetList<PlainToolLine>(find.byType(PlainToolLine)).toList();
    expect(lines.length, 1);
    expect(lines.single.summary, '写入了 a.txt',
        reason: '旧数据 ok:true ⇒ 完成态（成功）');
    expect(find.text('已拦截，未执行'), findsNothing);
  });
}

// ============================================================================
// 假执行器（2026-10-25 mock 基建重接）：走 AgentBridge.executorFactoryForTest
// —— 事件经 handle.events → emitLocalEvent → UI（生产同一条路径）。
// ============================================================================

/// 脚本化执行器：`run()` 立即返回句柄；事件由测试经 [onReady] 给的推送函数
/// 注入；结果在脚本（[onScript]）完成后以旧 mock 的同一份罐头数据收尾。
class _FakeExecutor extends LocalAgentExecutor {
  _FakeExecutor({
    required super.workspacePath,
    required super.settings,
    required super.sessionStore,
    super.askGate,
    required this.turns,
    required this.onScript,
    required this.onReady,
  });

  /// run 返回的轮次（**Map 形状 = 旧 Kotlin `toMap` 的输出**，
  /// 经 `AgentTurn.fromMap` 解析 —— 顺带把解析路径也真的用上）。
  final List<Map<String, dynamic>> turns;

  final Future<void> Function() onScript;
  final void Function(Future<void> Function(Map<String, dynamic>) push) onReady;

  @override
  Future<LocalRunHandle> run({
    required String request,
    String? sessionId,
    List<HAttachment> attachments = const [],
  }) async {
    final controller = StreamController<AgentEvent>.broadcast();
    final done = Completer<AgentRunResult>();
    onReady((m) async {
      if (!controller.isClosed) controller.add(AgentEvent.fromMap(m));
      await Future<void>.delayed(Duration.zero);
    });

    // 脚本在句柄返回后的一拍再跑 —— 保证 AgentBridge 已挂上订阅
    //（广播流不缓冲，早推会丢）。
    unawaited(Future<void>(() async {
      await onScript();
      // 与生产同形：`LocalAgentExecutor` 在 result 完成**之前**关流。
      if (!controller.isClosed) unawaited(controller.close());
      if (!done.isCompleted) done.complete(_cannedResult());
    }));

    return LocalRunHandle(
      events: controller.stream,
      result: done.future,
      cancel: () async => true,
    );
  }

  /// 旧 Kotlin mock 的罐头返回值（形状对齐 AgentRunResult）。
  AgentRunResult _cannedResult() => AgentRunResult(
        stopReason: '检测到循环，已停止',
        finalText: '',
        sessionId: 'sess-A',
        totalCachedTokens: 0,
        totalPromptTokens: 0,
        totalOutputTokens: 0,
        turns: [for (final t in turns) AgentTurn.fromMap(t)],
      );
}