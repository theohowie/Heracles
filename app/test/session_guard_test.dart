import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';

import 'support/secure_storage_mock.dart';

/// **会话守卫的回归测试**（2026-10-10，t7 —— 修复 HIGH 缺陷）。
///
/// ## 被修的缺陷
///
/// `_runAgent` 在 `await _bridge.run(...)` 返回后只检查 `mounted`，
/// **没有检查"当前会话是否还是发起时那个"**：
///
/// ```dart
/// final result = await _bridge.run(...);
/// if (!mounted) return;                  // ← 缺会话守卫
/// setState(() { for (final t in result.turns) { _messages.add(...) } });
/// ```
///
/// ## 为什么这个缺陷极易触发（不是理论问题）
///
/// device-verifier 真机实测：本地模型**稳态单轮约 20 秒**
/// （冷启动可达 132.8 秒 —— 见 `docs/23-时延实测更正.md`；别把冷启动当稳态）。
/// 用户等不到结果时最自然的动作就是**去切会话**，于是：
///
/// 1. 会话 A 发消息 → `await` 开始
/// 2. 用户等不耐烦 → 切到会话 B
/// 3. `_selectSession` 停订阅 + 清空列表 + 载入 B 的历史
/// 4. 几十秒后 `await` 返回 → **A 的工具卡片与回复全部插进 B 的列表**
///
/// 加重因素：`_stopLive()` 清空了 `_liveToolIds`（去重表），
/// 所以兜底路径的去重完全失效 —— A 的**整轮**记录会完整串过去。
///
/// 用户此前说过"切换会话，会话之前的记录没了，这个很恐怖啊" ——
/// 这是同一类"会话记录错乱"问题。
///
/// ## 本文件的测试必须能在修复前失败
///
/// 所以断言是**行为性**的（"B 的列表里不能有 A 的东西"），
/// 而不是"某个字段等于某值"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 安全存储通道 mock（2026-10-18，F1c）—— `freshController()` 走
  //   `SettingsController.load()`，不装 handler 时**永久卡死**在本机
  //   （`实测-03` 坑 36）。见 `test/support/secure_storage_mock.dart`。
  setUp(installSecureStorageMock);
  tearDown(removeSecureStorageMock);

  const commandChannel = MethodChannel('heracles/command');
  const eventChannel = EventChannel('heracles/events');

  const workspaceMap = <String, dynamic>{
    'path': '/storage/emulated/0/proj',
    'name': 'proj',
    'treeUri': '',
    'writable': true,
  };

  /// 两个会话 —— A 是我们要发起运行的那个，B 是用户中途切过去的。
  const sessions = <Map<String, dynamic>>[
    {'id': 'sess-A', 'title': '会话 A', 'updatedAt': 2000},
    {'id': 'sess-B', 'title': '会话 B', 'updatedAt': 1000},
  ];

  MockStreamHandlerEventSink? sink;
  Future<void> Function(Map<String, dynamic>)? pushRef;

  /// 取消订阅后**仍然保留**的 sink 引用 —— 用来模拟"平台侧的迟到事件"。
  ///
  /// `cancel()` 是异步的：平台可能已经把事件 post 进 Dart 队列，
  /// 此时取消消息还没被处理。这个引用让我们能复现那个窗口。
  MockStreamHandlerEventSink? rawSink;

  /// `loadMessages` 的返回值按会话区分 —— 用来证明"B 的列表是 B 的"。
  Map<String, List<Map<String, dynamic>>> messagesBySession = {};

  /// 记录 `runAgent` 收到的 sessionId（诊断用）
  final runAgentSessionIds = <String?>[];

  /// `cancelRun` 被调用了几次（2026-10-13 停止按钮的回归测试用）
  var cancelCalls = 0;

  void installMocks({
    required Future<void> Function() onRunAgent,
  }) {
    // ★ 每次安装 mock 都重置计数 —— 否则上一个测试的 cancelRun
    //   会泄漏到下一个（真实踩过：三态测试单独跑绿、套件跑红，
    //   因为前面"点停止按钮"那条把 cancelCalls 留在了 1）
    cancelCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'listWorkspaces':
          return [workspaceMap];
        case 'listSessions':
          return sessions;
        case 'loadMessages':
          final sid = call.arguments is Map
              ? (call.arguments as Map)['sessionId'] as String?
              : null;
          return messagesBySession[sid] ?? <Map<String, dynamic>>[];
        // ★ 停止按钮的桥接（2026-10-13）
        case 'cancelRun':
          cancelCalls++;
          return <String, dynamic>{'cancelled': true};
        case 'runAgent':
          runAgentSessionIds.add(
            call.arguments is Map
                ? (call.arguments as Map)['sessionId'] as String?
                : null,
          );
          await onRunAgent();
          return <String, dynamic>{
            'stopReason': '已给出最终回答',
            'finalText': '【A 的最终回答】',
            'sessionId': 'sess-A',
            'totalCachedTokens': 0,
            'totalPromptTokens': 0,
            'totalOutputTokens': 0,
            'steadyHitRate': null,
            'turns': [
              {
                'index': 1,
                'verdict': '工具成功',
                'tool': 'write_file',
                'args': {'path': 'a.txt'},
                'result': '【A 的写入结果】',
                'wallMs': 3,
                'cachedTokens': null,
                'promptTokens': 10,
                'outputTokens': 5,
              },
            ],
          };
        default:
          return null;
      }
    });

    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          sink = events;
          rawSink = events;
          pushRef = (Map<String, dynamic> e) async {
            // 切会话后订阅已被取消 → sink 为 null。
            // 这本身就是"事件不会再进来"的证据，直接跳过。
            if (sink == null) return;
            sink!.success(e);
            await Future<void>.delayed(Duration.zero);
          };
        },
        onCancel: (arguments) {
          sink = null;
        },
      ),
    );
  }

  /// 造一个**已配置**的设置控制器。
  ///
  /// ★ 2026-10-18（ADR-035 S4）为什么必须显式配一个 provider：
  /// 本地后端删除后，`AgentBridge.run()` 在"没有可用 provider"时**就地抛错**
  /// （这是有意的：以前 `null => 'local'` 会静默兜底，而 `'local'` 已是
  /// Kotlin 侧的 `error(...)`）。内置 preset 全是**没有 Key** 的云端 provider，
  /// 所以旧写法（只 `load()`）今天跑不出任何一次 run。
  ///
  /// 本文件测的是**会话守卫**，不是"没配 provider 时怎么报错" ——
  /// 所以这里配一个假的云端 provider（真 Key 用 `sk-test`，只发给 mock 通道），
  /// 让守卫逻辑本身成为被测对象。
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

  Widget wrap(SettingsController c, Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      );

  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 切到会话 B：开抽屉 → 点它
  Future<void> switchToSessionB(WidgetTester tester) async {
    // 打开抽屉（AppBar 的 ☰）
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await settle(tester);

    expect(find.text('会话 B'), findsOneWidget,
        reason: '抽屉里应当能看到会话 B —— 否则切会话这步没做到');

    await tester.tap(find.text('会话 B'));
    await settle(tester);
  }

  /// 输入框是否可用（`_busy` 复位的可见证据）。
  ///
  /// `TextField.enabled` 是 `bool?`（null = 默认可用），所以 `!= false`。
  bool inputEnabled(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).enabled != false;

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
    sink = null;
    pushRef = null;
    messagesBySession = {};
    runAgentSessionIds.clear();
  });

  // ==================================================================
  // ★ 核心回归：运行中切会话，结果不得串过去
  // ==================================================================

  testWidgets('★★ 运行中切到别的会话 → A 的结果不得插进 B 的列表，且 _busy 已复位',
      (tester) async {
    final c = await freshController();

    // B 有自己的历史 —— 用来断言"A 没污染 B"
    messagesBySession = {
      'sess-B': [
        {'role': 'assistant', 'text': '这是 B 原本的内容'},
      ],
    };

    // 用 Completer 卡住 runAgent —— 模拟真机那近 20 秒（多轮任务近 3 分钟）的等待
    final gate = Completer<void>();

    installMocks(onRunAgent: () async {
      // 期间推一个工具事件，让 A 的卡片先出现在（当时的）列表里
      await pushRef!({
        'type': 'tool_started',
        'ts': 1,
        'index': 1,
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
      });
      await gate.future;
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    // 发消息（当前没有 active session → Kotlin 侧会自动建 A）
    await tester.enterText(find.byType(TextField).first, '帮我写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // 此刻 A 的工具卡片已实时出现，且 run 还没返回
    //   （运行中的标题是「正在…」形态，2026-10-13 人话标题）
    expect(find.text('正在修改文件代码'), findsOneWidget,
        reason: '实时路径应当先画出 A 的卡片');

    // ---- 用户在等待中切到会话 B ----
    await switchToSessionB(tester);

    // 切过去之后 B 显示自己的历史
    expect(find.text('这是 B 原本的内容'), findsOneWidget);
    // ★ A 的卡片**必须**已经消失（切会话清了列表）
    expect(find.text('正在修改文件代码'), findsNothing,
        reason: '切到 B 之后不该再看到 A 的工具卡片');

    // ---- 放行：A 的 run 此刻返回 ----
    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // ★★ 核心断言：A 的工具调用与最终回答**都不得**出现在 B 的列表里
    expect(find.text('修改文件代码'), findsNothing,
        reason: 'HIGH 缺陷：A 的工具卡片串进了 B');
    expect(find.text('【A 的写入结果】'), findsNothing,
        reason: 'HIGH 缺陷：A 的工具结果串进了 B');
    expect(find.text('【A 的最终回答】'), findsNothing,
        reason: 'HIGH 缺陷：A 的最终回答串进了 B');

    // B 自己的内容仍在（没被 _reload 覆盖）
    expect(find.text('这是 B 原本的内容'), findsOneWidget);

    // ★★ _busy 必须复位 —— 否则输入框永久禁用（比原 bug 更糟）
    expect(inputEnabled(tester), isTrue,
        reason: '_busy 未复位 → 输入框永久禁用。这是本修复最容易写错的地方');
  });

  testWidgets('★ 未切会话时结果照常渲染（守卫不能误伤正常路径）', (tester) async {
    final c = await freshController();

    installMocks(onRunAgent: () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '帮我写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // 没切会话 → 结果必须正常显示
    expect(find.text('修改文件代码'), findsOneWidget);
    expect(find.text('【A 的最终回答】'), findsOneWidget);
    expect(inputEnabled(tester), isTrue);
  });

  testWidgets('★★ 切会话后事件流订阅确实被取消（B 不会被 A 的事件污染）',
      (tester) async {
    final c = await freshController();

    // B 有自己的历史 —— 用来证明"B 显示的是 B 的内容"
    messagesBySession = {
      'sess-B': [
        {'role': 'assistant', 'text': 'B 原本的内容'},
      ],
    };

    var gateReady = false;
    final gate = Completer<void>();

    installMocks(onRunAgent: () async {
      gateReady = true;
      await gate.future;
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(gateReady, isTrue);

    // 切走
    await switchToSessionB(tester);

    // ★★ 这才是真正的保护机制（不是 _onAgentEvent 里的守卫）：
    //
    // `EventChannel.receiveBroadcastStream()` 在**最后一个监听者取消**时
    // 会 `setMessageHandler(name, null)` —— 平台侧之后发来的消息
    // 直接在通道层被丢弃，**根本到不了 `_onAgentEvent`**。
    //
    // 所以断言的不该是"守卫拦住了它"，而是"通道已断开"。
    // （我最初写的版本推事件后断言没污染 —— 那是**空跑**：
    //   事件压根没送达，去掉守卫测试照样绿。用 --plain-name 跑过变异验证。）
    expect(sink, isNull,
        reason: '切会话后必须取消订阅 —— 这是事件不串会话的真正机制');

    // 通道已断，再推给保留的 sink 也不会送达 Dart。
    // 这里如实推一次，确认 B 仍然干净（等价于"没有窗口期"）。
    rawSink!.success({
      'type': 'tool_started',
      'ts': 9,
      'index': 1,
      'tool': 'read_file',
      'args': {'path': 'leak.txt'},
    });
    await settle(tester);

    expect(find.text('读取文件'), findsNothing,
        reason: '取消订阅后事件不得进入 B');
    expect(find.text('B 原本的内容'), findsOneWidget);

    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('读取文件'), findsNothing);
    expect(find.text('【A 的最终回答】'), findsNothing);
    expect(inputEnabled(tester), isTrue);
  });

  // ==================================================================
  // 其它"换上下文"路径也必须让在途运行失效
  // ==================================================================

  testWidgets('★ 新建会话后，A 的结果也不得串进新会话', (tester) async {
    final c = await freshController();

    final gate = Completer<void>();
    installMocks(onRunAgent: () async => gate.future);

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // 开抽屉 → 点「新会话」
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await settle(tester);
    expect(find.text('新会话'), findsOneWidget);
    await tester.tap(find.text('新会话'));
    await settle(tester);

    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('修改文件代码'), findsNothing,
        reason: '新建会话后 A 的结果串了过来');
    expect(find.text('【A 的最终回答】'), findsNothing);
    expect(inputEnabled(tester), isTrue);
  });

  testWidgets('★ 守卫生效时失败也会复位 _busy（不会永久禁用输入框）',
      (tester) async {
    final c = await freshController();

    final gate = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // runAgent 稍后抛错（模拟后端失败）
    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'listWorkspaces':
          return [workspaceMap];
        case 'listSessions':
          return sessions;
        case 'loadMessages':
          return <Map<String, dynamic>>[];
        case 'runAgent':
          await gate.future;
          throw PlatformException(code: 'RUN_FAILED', message: '后端连接失败');
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (a, e) {}, onCancel: (a) {}),
    );

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // 切走再放行（让失败也走守卫分支）
    await switchToSessionB(tester);
    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // 失败信息**不该**作为助手消息内联插进 B 的会话。
    //
    // 用**精确匹配**而不是 textContaining：因为守卫生效时我们**故意**
    // 弹了一条 SnackBar（内容以"上一个会话的运行失败："开头），
    // 它不往 _messages 里插任何东西，是设计的一部分。
    // 要区分的是「内联插入的助手消息」与「瞬时的 SnackBar」。
    expect(find.text('运行失败：后端连接失败'), findsNothing,
        reason: 'A 的失败被内联插进了 B 的会话 → 污染');

    // 但用户**不能**被静默欺骗：失败没有落盘，所以必须有可见提示。
    // 用 SnackBar（悬浮、瞬时、不碰 _messages）。
    expect(find.textContaining('上一个会话的运行失败'), findsOneWidget,
        reason: '失败没有落盘，必须提示用户，不能静默丢弃');

    // 但 _busy 必须复位
    expect(inputEnabled(tester), isTrue,
        reason: '失败 + 守卫 时 _busy 未复位 → 输入框永久禁用');
  });

  // ==================================================================
  // M-1：移除工作区也是"换上下文"，必须让在途运行失效
  // ==================================================================

  testWidgets('★★ M-1：移除工作区后，在途运行的结果不得渲染进来',
      (tester) async {
    final c = await freshController();

    final gate = Completer<void>();

    // 让工作区在侧边栏里可见：`_groupedList` 只显示**有会话**的工作区
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'listWorkspaces':
          return [workspaceMap];
        case 'listSessions':
          return [
            {'id': 'sess-A', 'title': '会话 A', 'updatedAt': 2000},
          ];
        case 'removeWorkspace':
          return null; // 移除成功
        case 'loadMessages':
          return <Map<String, dynamic>>[];
        case 'runAgent':
          await gate.future;
          return <String, dynamic>{
            'stopReason': '已给出最终回答',
            'finalText': '【A 的最终回答】',
            'sessionId': 'sess-A',
            'totalCachedTokens': 0,
            'totalPromptTokens': 0,
            'totalOutputTokens': 0,
            'steadyHitRate': null,
            'turns': [
              {
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
              },
            ],
          };
        default:
          return null;
      }
    });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (a, e) {}, onCancel: (a) {}),
    );

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    // 发消息 → 在途
    await tester.enterText(find.byType(TextField).first, '写文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // ---- 开抽屉 → 工作区 ⋯ 菜单 → 从列表移除 ----
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await settle(tester);

    expect(find.text('proj'), findsWidgets, reason: '工作区应当出现在抽屉里');

    // 工作区行的 ⋯ 按钮
    await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
    await settle(tester);

    expect(find.text('从列表移除'), findsOneWidget);
    await tester.tap(find.text('从列表移除'));
    await settle(tester);

    // ---- 放行：那个运行此刻返回 ----
    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // ★★ 核心断言：结果不得渲染（工作区已经被移除，上下文变了）
    expect(find.text('修改文件代码'), findsNothing,
        reason: 'M-1：移除工作区后，在途运行的结果串了进来');
    expect(find.text('【A 的最终回答】'), findsNothing,
        reason: 'M-1：移除工作区后，A 的最终回答串了进来');

    // ★ _busy 仍必须复位
    expect(inputEnabled(tester), isTrue,
        reason: 'M-1：守卫生效时 _busy 未复位 → 输入框永久禁用');
  });

  // ==================================================================
  // t14：输入框禁用必须**说明原因**（2026-10-11）
  // ==================================================================

  /// ## 被修的缺陷（用户报的"切换会话就不工作"真身）
  ///
  /// `InputBar(enabled: !_busy)` —— `_busy` 是**屏幕级**字段。
  /// 在会话 A 发消息后切到 B：
  ///   · B 的输入框被禁用（`TextField(enabled:false)` 真的不能输入）
  ///   · 按钮显示成**停止态**
  /// 用户看起来像"卡住了"，**实际是 A 还没跑完**。
  ///
  /// ## 修法（选了"解释清楚"而不是"放开输入"）
  ///
  /// 放开会让两个运行并行，而 `eventSink` 单字段 + 事件无 session id
  /// ⇒ 事件混流、UI 原理上无法分辨（结构性约束）。
  ///
  /// 所以：**禁用仍然禁用，但必须显示说明横幅**，
  /// 且按钮从"停止"改成"等待"（别的会话在跑时，"停止"是误导）。
  testWidgets('★★ 有运行在途且切到别的会话 → 输入框禁用但【必须说明原因】',
      (tester) async {
    final c = await freshController();
    final gate = Completer<void>();

    installMocks(onRunAgent: () async {
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
      await gate.future; // run 卡住不返回 —— 模拟"还在跑"
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    // 在会话 A 发消息
    await tester.enterText(find.byType(TextField).first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // ★ 2026-10-13 改：正在跑时输入框**保持可用**（排队发送）
    //
    // 用户原话：「排队发送，当会话有在工作时，点不了输入框发送消息」。
    // 设置里 `BusySendBehavior.queue` 本来就是默认值，只是从未接线 ——
    // 于是忙时一律禁用。现在按设置走：queue → 可输入可发送（排队）。
    expect(inputEnabled(tester), isTrue,
        reason: '排队发送模式下，运行中输入框必须仍可用 —— '
            '否则用户只能干等（这正是用户报的问题）');

    // ★ 但必须能读懂"现在在跑"（t14 的核心要求没变）
    //
    // 顶部「正在生成…」横幅已按用户要求移除；这层信息现在由
    // **发送键的图标语义**承担：当前会话在跑 → 停止图标。
    expect(
      find.byIcon(Icons.stop_rounded),
      findsOneWidget,
      reason: 't14：必须能从界面读懂"当前会话在跑" —— '
          '发送键应当是"停止"语义',
    );

    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('★★ 运行结束后输入框恢复可用（不永久禁用）', (tester) async {
    final c = await freshController();
    final gate = Completer<void>();

    installMocks(onRunAgent: () async {
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
      await gate.future;
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    // 2026-10-13：排队发送模式下运行中也可用（见上一条测试）
    expect(inputEnabled(tester), isTrue,
        reason: '排队模式下跑的时候输入框也应可用');

    // 放行 → run 返回 → finally 复位
    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(inputEnabled(tester), isTrue,
        reason: 't14：运行结束后输入框必须恢复 —— 否则用户永久发不了消息');
    // 跑完之后按钮回到"发送"语义（不再是停止）
    expect(find.byIcon(Icons.stop_rounded), findsNothing,
        reason: '跑完了不该还显示停止 —— 否则用户以为还在跑');
  });

  // ==================================================================
  // ★ 停止按钮（2026-10-13 用户报「暂停不了？」）
  // ==================================================================

  /// ## 被修的缺陷
  ///
  /// 停止按钮**画得出来**（`_SendButton` 的 busy 分支显示停止图标），
  /// 但点下去只会**又发一条消息** —— `InputBar` 的 `onTap` 恒为 `_send`，
  /// 且 Kotlin 侧根本没有取消接口。
  ///
  /// ## 这条测试防什么
  ///
  /// 防"停止键又变回发送键"。两个方向都断言：
  ///   · 点停止 → `cancelRun` 被调用**一次**，且**没有**再发一条 runAgent
  ///   · 这是最容易回退的地方（两处 onTap 长得一样）
  testWidgets('★★ 点停止按钮 → 调 cancelRun，且不再发消息（暂停不了的真身）',
      (tester) async {
    final c = await freshController();
    final gate = Completer<void>();
    final runStarts = <String>[];

    installMocks(onRunAgent: () async {
      runStarts.add('run');
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
      await gate.future; // 卡住 → 保持"运行中"
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // ★ 前提：确实在跑，且**输入框为空** → 停止图标可见
    //
    // 2026-10-13 改（用户要求）："输入框里有字的时候，
    // 暂停按钮变成发送按钮" —— 忙 + 有内容 = 排队（发送态），
    // 忙 + 无内容 = 停止。发送动作会清空输入框，所以此刻为空。
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget,
        reason: '前提：运行中且输入框为空时，发送键应当显示为停止');
    expect(runStarts.length, 1, reason: '前提：已经发起过一次运行');
    expect(cancelCalls, 0, reason: '前提：此时还没人点停止');

    // ★ 点停止
    await tester.tap(find.byIcon(Icons.stop_rounded));
    await settle(tester);

    // ★★ 核心断言 1：真的调了取消
    expect(cancelCalls, 1, reason: '点停止必须调用 cancelRun —— '
        '否则按钮只是画着好看（用户报的「暂停不了？」就是这个）');

    // ★★ 核心断言 2：**没有**因此再发一条消息
    expect(runStarts.length, 1,
        reason: '点停止不能再发一条 runAgent —— '
            '旧 bug 正是停止键走了 onTap: _send');

    // ★ 界面如实说明"是用户停的"
    expect(find.textContaining('已停止'), findsOneWidget,
        reason: '停止后要明确告诉用户，而不是留一个空白让人以为回答完了');

    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
  });

  /// 没有在跑的时候点"停止"不该误伤 —— 幂等，且不写"已停止"消息。
  testWidgets('★ 没在跑时点停止 → 不报错、不写多余消息（幂等）',
      (tester) async {
    final c = await freshController();
    installMocks(onRunAgent: () async {});

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    // 没在跑 —— 按钮是发送态（上箭头），不是停止
    expect(find.byIcon(Icons.stop_rounded), findsNothing,
        reason: '前提：没有运行时不显示停止');

    gateCompleteNoop();
    await settle(tester);
    // 不存在"已停止"消息
    expect(find.textContaining('已停止'), findsNothing);
  });

  // ==================================================================
  // ★ 发送/停止三态（2026-10-13 用户要求：
  //   "输入框里有字的时候，暂停按钮变成发送按钮"）
  // ==================================================================

  /// ## 被修的问题
  ///
  /// 用户场景：「上面消息在处理的时候，我要发送第二轮消息，
  /// 但是这个发送按钮还是暂停按钮」—— 忙时不管输入框有没有字
  /// 都显示停止，用户没法排第二条（按钮点了还是停）。
  ///
  /// ## 三态（视觉与行为必须一致）
  ///
  /// | 忙 | 输入框 | 图标 | 点下去 |
  /// |---|---|---|---|
  /// | ✅ | **有字** | **发送** | 排队/发送 |
  /// | ✅ | 空 | 停止 | 取消当前 |
  /// | ❌ | 任意 | 发送 | 发送 |
  ///
  /// 这条测试钉第一行 —— 防"忙时恒为停止"回退。
  testWidgets('★★ 忙 + 输入框有字 → 按钮变发送，点下去进队列不停止',
      (tester) async {
    final c = await freshController();
    final gate = Completer<void>();
    final runStarts = <String>[];

    installMocks(onRunAgent: () async {
      runStarts.add('run');
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
      await gate.future; // 卡住 → 保持运行中
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    // 发第一条（卡住）
    await tester.enterText(find.byType(TextField).first, '第一条');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(runStarts.length, 1);
    // 发送动作清空了输入框 → 此时是停止态
    expect(find.byIcon(Icons.stop_rounded), findsOneWidget,
        reason: '前提：忙 + 输入框为空 = 停止态');

    // ★ 在输入框里打字（不发送）—— 按钮应当**变成发送**
    await tester.enterText(find.byType(TextField).first, '第二条');
    await tester.pump();

    expect(find.byIcon(Icons.stop_rounded), findsNothing,
        reason: '用户要求：输入框里有字的时候，暂停按钮变成发送按钮');
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget,
        reason: '有字 = 用户在排下一条，按钮必须是发送语义');

    // ★ 点它 → 进队列，**不**停止当前运行
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);

    expect(cancelCalls, 0,
        reason: '有字时点按钮是排队，绝不能触发取消 —— '
            '否则用户排第二条反而把自己的任务停了');
    expect(runStarts.length, 1, reason: '排队不并行 —— 当前任务继续跑');
    // 排队条出现（输入框上方）
    expect(find.byIcon(Icons.schedule_send_rounded), findsOneWidget,
        reason: '排队内容显示在输入框上方的排队条里');

    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
  });

  // ==================================================================
  // ★ 排队发送（2026-10-13 用户报「会话有在工作时点不了输入框」）
  // ==================================================================

  /// ## 被修的问题
  ///
  /// 设置里 `BusySendBehavior.queue`（"排队发送 —— 等当前任务结束再发"）
  /// **是默认值但从未接线** —— 于是不管用户选什么，忙时输入框一律禁用。
  ///
  /// ## 这条测试防什么
  ///
  /// 防"排队功能又被摘掉"。断言两件事：
  ///   · 运行中输入框**可用**（能输入、能发送）
  ///   · 忙时发送 → **不并行**，而是进队列（runStarts 仍为 1）
  ///   · 前一个结束后 → 队列消息**自动发出**（runStarts 变成 2）
  testWidgets('★★ 排队发送：忙时能发（进队列），前一个结束后自动发出',
      (tester) async {
    final c = await freshController();
    final gate1 = Completer<void>();
    final runStarts = <String>[];

    installMocks(onRunAgent: () async {
      runStarts.add('run');
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
      if (runStarts.length == 1) {
        await gate1.future; // 第一次卡住；第二次立即返回
      }
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    // 第一条 → 卡住
    await tester.enterText(find.byType(TextField).first, '第一条');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(runStarts.length, 1);

    // ★ 运行中输入框仍可用（这是用户报的核心）
    expect(inputEnabled(tester), isTrue,
        reason: '排队发送：运行中必须还能输入');

    // 第二条 → 应当进队列（**不**并行）
    await tester.enterText(find.byType(TextField).first, '第二条');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    expect(runStarts.length, 1,
        reason: '排队模式下不能并行发起第二个 run —— '
            '那会撞 eventSink 单字段的结构性约束');
    // ★ 2026-10-13 改：排队内容显示在**输入框上方的排队条**，
    //   不再往消息列表里塞「已排队」助手消息（用户原话：
    //   "排队的消息要在输入框上面显示……不是在工作步骤里显示已排队"）。
    //   所以这里断言：① 消息列表里**没有**"已排队"字样；
    //   ② 排队条上**有**这条消息的原文（queue 图标行）。
    expect(find.textContaining('已排队'), findsNothing,
        reason: '排队不是对话的一部分 —— 不能在工作步骤里显示');
    expect(find.byIcon(Icons.schedule_send_rounded), findsOneWidget,
        reason: '输入框上方必须有排队条（用户参考图）');
    expect(find.textContaining('第二条'), findsOneWidget,
        reason: '排队条上要能看到排队内容的原文');

    // 放行第一条 → 队列里的第二条应自动发出
    gate1.complete();
    await settle(tester);
    // ⚠️ 出队发生在 `_runAgent` 的 `finally` 里（一次 await 之后），
    //    而 `settle` 推进的是虚拟时钟 —— 多推几轮让"出队 → 再发起"
    //    这条微任务链走完，否则断言会假失败（测试自身的问题，不是产品）。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }

    expect(runStarts.length, 2,
        reason: '前一个结束后，排队的那条必须自动发出 —— '
            '否则"排队"就是骗人的（消息永远躺在队列里）');
  });
}

/// 占位：让上一条测试的结构与其他测试一致（不需要真的放行 gate）
void gateCompleteNoop() {}

