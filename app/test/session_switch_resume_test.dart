import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/attachment.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/agent_bridge.dart'
    show AgentBridge, AgentEvent, AgentRunResult, AgentTurn;
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart' show AppIcons;

import 'support/secure_storage_mock.dart';

/// **「切会话后原会话不工作」的判定与回归测试**（2026-10-11，t11）。
///
/// ## 用户原话
///
/// > 「切换会话，原会话就不工作的 bug」
///
/// ## 先把 (a) 与 (b) 分开
///
/// **(a) 预期行为**：切走后，**先前那次运行的结果不再渲染到界面上**。
/// 这是 t7 的有意设计，正确 —— 数据不丢（已落盘，切回时读回）。
///
/// **(b) 真 bug**：切**回**原会话后，那次运行的结果**永远不出现** /
/// 界面看起来「卡住／不工作」。
///
/// 本文件先用测试**证伪或证实**各条路径，再谈修法。
///
/// ## 关键背景：磁盘什么时候才有内容
///
/// 真实的 `LocalAgentExecutor._drive` 顺序是：
///   1. 用户消息**先落盘**
///   2. 整个 agent 循环跑完 → 工具记录与助手回答**在最后一次性写盘**
///   3. `result` 完成
///
/// 所以**运行期间磁盘上只有用户那条消息**。中途切回原会话，
/// 从磁盘读回的就是「半截会话」。
///
/// ## ★★ mock 基建重接（2026-10-25，mock 回家第二批）
///
/// 旧夹具 mock 的是**已删除的传输**：`heracles/command` 的
/// `runAgent` / `listSessions` / `loadMessages` + `EventChannel`。
/// 内核迁到进程内 Dart 后那条传输在 `app/lib` 里**零构造** ⇒ mock 永不触发
/// ⇒ 本文件**整份挂死**（实测：第 1 条用例 10 分钟 `TimeoutException`，
/// 根因是没装 secure-storage mock，`SettingsController.load()` 永不完成）。
///
/// 现在的形状（与生产同一路径）：
/// · run 用 `AgentBridge.executorFactoryForTest` 注入 [_FakeExecutor]
///   （事件走 `handle.events → emitLocalEvent → UI`；本文件刻意不推事件，
///   只考察"兜底路径 + 切会话"）；
/// · 会话/消息走 `heracles/device` 的 `fs.*`（`SessionStore` 的真通道）；
/// · 工作区登记表仍在 `heracles/command`。
///
/// **断言与测试体零改动**（除 finder 随 UI 改版换过：抽屉入口 = 品牌图标、
/// 输入框 = `CupertinoTextField`、停止/等待图标 = `AppIcons.stop` /
/// `CupertinoIcons.hourglass`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 安全存储通道 mock（坑 36）—— 没有它本文件第一条用例就挂死。
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

  const sessions = <Map<String, dynamic>>[
    {'id': 'sess-A', 'title': '会话 A', 'updatedAt': 2000},
    {'id': 'sess-B', 'title': '会话 B', 'updatedAt': 1000},
  ];

  /// 模拟磁盘内容（按会话 id）—— `heracles/device` 的 `fs.readText` 读它。
  late Map<String, List<Map<String, dynamic>>> disk;

  /// 只 gate **第二次**运行 —— 第一次用它建立「已有会话 A」的前提
  Completer<void>? gate;

  late int runCount;

  /// 与 `AgentTurn.fromMap` 同形的一条「工具成功」轮次
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
          return <String, dynamic>{'ok': true, 'exists': false};
        case 'fs.readText':
          if (path.endsWith('sessions.json')) {
            return <String, dynamic>{
              'ok': true,
              'text': jsonEncode(sessions),
              'truncated': false,
            };
          }
          final sid = path.split('/').last.replaceAll('.jsonl', '');
          final rows = disk[sid] ?? const <Map<String, dynamic>>[];
          return <String, dynamic>{
            'ok': true,
            'text': rows.map((r) => jsonEncode(r)).join('\n'),
            'truncated': false,
          };
        case 'fs.readTailLines':
          final sid = path.split('/').last.replaceAll('.jsonl', '');
          final rows = disk[sid] ?? const <Map<String, dynamic>>[];
          return <String, dynamic>{
            'ok': true,
            'lines': [for (final r in rows) jsonEncode(r)],
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
        // 每次 run 一次序号（旧 mock 用 runAgent 被调的次数）
        nextRunIndex: () => ++runCount,
        onScript: (n) async {
          // ② 第二次运行被 gate 卡住 —— 模拟「还在跑」
          final g = gate;
          if (n >= 2 && g != null) {
            await g.future;
          }
        },
        // ③ 收尾：工具记录 + 助手回答（旧 `persistTurns` 的形状）
        buildResult: (n) => AgentRunResult(
          stopReason: '已给出最终回答',
          finalText: '【第 $n 次的回答】',
          sessionId: 'sess-A',
          totalCachedTokens: 0,
          totalPromptTokens: 0,
          totalOutputTokens: 0,
          turns: [AgentTurn.fromMap(toolTurn())],
        ),
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

  Future<void> settle(WidgetTester tester, {int times = 12}) async {
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

  /// 开抽屉 → 点某个会话标题。
  ///
  /// 用 `find.descendant(of: Drawer)` 限定范围：标题栏也会显示会话名，
  /// 不加限定会命中多个。
  Future<void> switchTo(WidgetTester tester, String title) async {
    await openDrawer(tester);
    final inDrawer =
        find.descendant(of: find.byType(Drawer), matching: find.text(title));
    expect(inDrawer, findsOneWidget, reason: '抽屉里应当能看到「$title」');
    await tester.tap(inDrawer);
    await settle(tester);
  }

  /// 发一条消息（输入条自原型 01 起是 `CupertinoTextField`）
  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(CupertinoTextField).first, text);
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

  /// 输入框是否可用（`CupertinoTextField.enabled` 是 `bool?`）
  bool inputEnabled(WidgetTester tester) =>
      tester.widget<CupertinoTextField>(find.byType(CupertinoTextField)).enabled !=
      false;

  setUp(() {
    disk = {};
    gate = null;
    runCount = 0;
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
    AgentBridge.executorFactoryForTest = null;
  });

  // ==================================================================
  // 前提：先用一次「不 gate」的运行把会话 A 建立起来
  // ==================================================================

  /// 发第一条消息 → 拿到会话 A → 结果显示、界面可见。
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
    //
    // ★ 2026-10-25：图标随 Cupertino 化换过（旧 Material
    //   `Icons.stop_rounded`）—— **只换 finder，断言未动**。
    expect(find.byIcon(AppIcons.stop), findsOneWidget,
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
    //
    // ★ 2026-10-25：`Icons.hourglass_top_rounded` ⇒ `CupertinoIcons.hourglass`
    //   （`input_bar.dart` 的三态发送键，只换 finder）。
    expect(find.byIcon(CupertinoIcons.hourglass), findsOneWidget,
        reason: 'A 在跑而用户在 B：发送键必须表达"等待"而非"停止" —— '
            '否则用户以为能停 B 的东西、或以为 B 卡住了');
    expect(find.byIcon(AppIcons.stop), findsNothing,
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

// ============================================================================
// 假执行器（2026-10-25 mock 基建重接）：走 AgentBridge.executorFactoryForTest
// —— 事件经 handle.events → emitLocalEvent → UI（生产同一条路径）。
// ============================================================================

/// 脚本化执行器：`run()` 立即返回句柄；[onScript] 在句柄返回后跑（本文件
/// 刻意为空 —— 只考察兜底路径），完成后以 [buildResult] 的罐头数据收尾。
///
/// [nextRunIndex] 给出"这是第几次运行"（旧 mock 是 `runAgent` 被调的次数），
/// 用来构造「【第 N 次的回答】」。
class _FakeExecutor extends LocalAgentExecutor {
  _FakeExecutor({
    required super.workspacePath,
    required super.settings,
    required super.sessionStore,
    super.askGate,
    required this.nextRunIndex,
    required this.onScript,
    required this.buildResult,
  });

  final int Function() nextRunIndex;
  final Future<void> Function(int runIndex) onScript;
  final AgentRunResult Function(int runIndex) buildResult;

  @override
  Future<LocalRunHandle> run({
    required String request,
    String? sessionId,
    List<HAttachment> attachments = const [],
  }) async {
    final n = nextRunIndex();
    final controller = StreamController<AgentEvent>.broadcast();
    final done = Completer<AgentRunResult>();

    unawaited(Future<void>(() async {
      await onScript(n);
      // 与生产同形：result 完成**之前**关流。
      if (!controller.isClosed) unawaited(controller.close());
      if (!done.isCompleted) done.complete(buildResult(n));
    }));

    return LocalRunHandle(
      events: controller.stream,
      result: done.future,
      cancel: () async => true,
    );
  }
}