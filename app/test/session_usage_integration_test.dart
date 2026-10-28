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
import 'package:heracles/widgets/bw_topbar.dart' show ContextRing;

import 'support/secure_storage_mock.dart';

/// **会话用量在真实界面里的接线测试**（2026-10-11，t13）。
///
/// ## 为什么单测 `SessionUsage` 之外还要这一层
///
/// `session_usage_test.dart` 证明的是**算法**对（null 不参与、加权、标 `~`）。
/// 但算法对 ≠ 界面真的用了它。这一层证明的是**接线**：
///
/// 1. 跑完一次运行后，顶栏指示器**真的**显示了数（而不是永远 `—`）
/// 2. `AgentTurn.cachedTokens == null` 的轮次**没被当成 0** 混进累计
/// 3. **切会话后显示的是另一个会话的账**（"当前会话"语义，不是全局）
/// 4. 切走期间跑完的那次，账仍记在**发起它的会话**头上（不少算）
///
/// ## ★★ 口径变更（2026-10-25，mock 回家第二批）—— 这个文件必须重钉
///
/// 本文件**不只是"mock 死了"**：它钉的 UI 也整个改版了。逐条对照：
///
/// | 旧（本文件原样写的） | 今天 |
/// |---|---|
/// | 顶栏 `UsageIndicator`（**两格文字**：命中率 + 上下文 %） | 顶栏 `ContextRing`（**圆环 + 只显示上下文 %**）—— `UsageIndicator` 只剩组件定义，`app/lib` 里**已无使用点** |
/// | 点指示器 → 右侧 `endDrawer`（`UsageSidebar`） | 点圆环 → **半抽屉** `showUsageSheet`（`bw_usage_sheet.dart`，两页：上下文占用 / 缓存命中） |
/// | 命中率一直在顶栏 | 命中率移到**半抽屉第 2 页**（"缓存命中（累计·加权）"） |
/// | `scaffold.endDrawer` 必须挂着 / `endDrawerEnableOpenDragGesture == false` | `Scaffold` **不再挂 endDrawer**（右侧边缘是系统返回区，详情改半抽屉） |
/// | 渠道：`runAgent` 返回的 map 上做 token 记账 + `usageInfo` 通道 | `AgentBridge.executorFactoryForTest` 注入假执行器（记账读它的 `turns`）；冻结区/上限由执行器的 `lastFrozenTokens` + provider 能力给出 |
///
/// 所以本文件的断言**逐条按新口径重钉**（不删意图），并在每处写明为什么。
///
/// ## 数据来源的坑（`docs/24` §7.1）
///
/// `.jsonl` 里没有各轮 token，所以**切回同一会话时不能从磁盘恢复** ——
/// 内存里的 Map 才是真相。下面第 3 条正好把这个语义钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 安全存储通道 mock（坑 36）：没有它本文件第一条用例就挂死。
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

  /// 上限的**权威值**：服务端上报 100K（`ModelCapability.contextWindow`）。
  /// 这样"上下文占比"是个可断言的小数字（冻结区 5200 ⇒ ≈5%），
  /// 也避免 ChatScreen 走"自动拉取能力"（真实 HTTP）。
  const contextWindow = 100000;

  /// 假执行器每次运行建立的**冻结区** size（旧 `usageInfo` 通道给的 5200）。
  const frozenTokens = 5200;

  late Map<String, List<Map<String, dynamic>>> disk;

  /// 每次 run 返回的轮次（可逐次改写，用来构造 null / 非 null 的混合）
  late List<Map<String, dynamic>> Function(int runIndex) turnsForRun;

  Completer<void>? gate;
  late int runCount;

  /// 造一条「轮次」记录（`AgentTurn.fromMap` 的形状）。
  ///
  /// ⚠️ 字段名必须与 `AgentTurn.fromMap` 一致：
  /// `cachedTokens` / `promptTokens` / `outputTokens` ——
  /// 我第一版写成 `cached`/`prompt`/`out`（那是**落盘**用的名字），
  /// 结果全被解析成 null，测试"失败"得莫名其妙。**探针查到真相后改对了**。
  /// ★ 2026-10-25 夹具修正：`promptTokens` 的语义已于 2026-10-23 改成
  ///   **整段**（含命中的那部分）—— `hitRate = cached / prompt`
  ///   （见 `SessionUsage.hitRate` / `TurnMetrics.hitRate` 的说明）。
  ///   所以默认值必须是 **1000**（900 命中 + 100 未命中）才能得到 90%；
  ///   旧夹具的 `promptTokens: 100` 今天会算出 **900%**（断言会红得对）。
  Map<String, dynamic> turn({
    int? cachedTokens,
    int promptTokens = 1000,
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
      final ex = _FakeExecutor(
        workspacePath: workspacePath,
        settings: settings,
        sessionStore: sessionStore,
        askGate: askGate,
        nextRunIndex: () => ++runCount,
        onScript: (n) async {
          final g = gate;
          if (g != null) await g.future;
        },
        buildResult: (n) => AgentRunResult(
          stopReason: '已给出最终回答',
          finalText: '【第 $n 次的回答】',
          sessionId: 'sess-A',
          totalCachedTokens: 0,
          totalPromptTokens: 0,
          totalOutputTokens: 0,
          turns: [for (final t in turnsForRun(n)) AgentTurn.fromMap(t)],
        ),
      );
      // ★ 冻结区（等价旧 `usageInfo` 通道返回的 frozenTokens）：
      //   `AgentBridge.run()` 在结果返回后读 `executor.lastFrozenTokens`。
      ex.lastFrozenTokens = frozenTokens;
      return ex;
    };
  }

  /// 造一个**已配置**的设置控制器 —— 不配 provider 时 `AgentBridge.run()`
  /// 会**就地抛错**（ADR-035 S4 有意为之），根本走不到假执行器。
  ///
  /// ★ 这里必须给出**服务端能力**（100K）：否则 `_refreshContextUsage`
  /// 会按"未从服务端获取"兜底，并顺带**发起一次真实 HTTP 拉取**
  /// （`_autoFetchCapabilities`）—— 测试里那是噪音。
  Future<SettingsController> freshController() async {
    SharedPreferences.setMockInitialValues({});
    final c = await SettingsController.load();
    await c.updateProvider(const ModelProviderConfig(
      id: 'deepseek-account',
      name: 'DeepSeek 账号',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      apiKey: 'sk-test',
      contextLength: contextWindow,
      modelCapabilities: {
        'deepseek-chat': ModelCapability(contextWindow: contextWindow),
      },
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

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(CupertinoTextField).first, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
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

  Future<void> switchTo(WidgetTester tester, String title) async {
    await openDrawer(tester);
    final inDrawer =
        find.descendant(of: find.byType(Drawer), matching: find.text(title));
    expect(inDrawer, findsOneWidget);
    await tester.tap(inDrawer);
    await settle(tester);
  }

  /// 顶栏圆环里的百分比文字（**上下文占用**；命中率已不在顶栏）。
  ///
  /// ★ 旧版本这里是"两个值：命中率 + 上下文占比"（`UsageIndicator` 的两格
  /// 文字）。今天顶栏只有一个数 —— 命中率进了半抽屉（见 [swipeToCachePage]）。
  String ringText(WidgetTester tester) {
    expect(find.byType(ContextRing), findsOneWidget,
        reason: '标题栏必须有常驻的上下文圆环');
    final texts = tester
        .widgetList<Text>(find.descendant(
          of: find.byType(ContextRing),
          matching: find.byType(Text),
        ))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    expect(texts, isNotEmpty, reason: '圆环中心必须有百分比文字');
    return texts.first;
  }

  /// 点顶栏圆环 → 打开用量半抽屉。
  ///
  /// ★ 口径变更：旧版是 `endDrawer`（右侧抽屉，`UsageSidebar`）；
  /// 2026-10-24 黑白改版起是 **modal 半抽屉**（`bw_usage_sheet.dart`）。
  Future<void> openUsageSheet(WidgetTester tester) async {
    expect(find.byType(ContextRing), findsOneWidget, reason: '顶栏必须有常驻的圆环（点它开详情）');
    await tester.tap(find.byType(ContextRing));
    await settle(tester);
    expect(find.byType(PageView), findsOneWidget,
        reason: '用量详情必须打得开（半抽屉里用 PageView 分两页）');
  }

  /// 关掉半抽屉（点上方遮罩）—— 之后才能继续开抽屉切会话。
  Future<void> closeUsageSheet(WidgetTester tester) async {
    // 半抽屉只占下方 62%，点左上角落到遮罩上；品牌图标在遮罩**之下**，
    // 所以这一下不会顺手把抽屉点开。
    await tester.tapAt(const Offset(30, 30));
    await settle(tester);
    expect(find.byType(PageView), findsNothing, reason: '前提：半抽屉已经关掉');
  }

  /// 半抽屉第 2 页 = **缓存命中**（第 1 页是上下文占用）。
  Future<void> swipeToCachePage(WidgetTester tester) async {
    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await settle(tester);
  }

  /// 限定在**半抽屉内**查找 —— 顶栏圆环也显示百分比，不限定会命中两个
  /// （旧版本限定的是 `UsageSidebar`，同一个理由）。
  Finder inSheet(Finder f) =>
      find.descendant(of: find.byType(PageView), matching: f);

  setUp(() {
    disk = {};
    gate = null;
    runCount = 0;
    // 默认：每轮都上报缓存（900 命中 / 1000 整段 = 90%）
    turnsForRun = (_) =>
        [turn(cachedTokens: 900, outputTokens: 10, wallMs: 1000)];
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
    AgentBridge.executorFactoryForTest = null;
  });

  // ==================================================================

  testWidgets('★ 圆环常驻可见；跑完后显示真实的上下文占比', (tester) async {
    final c = await freshController();
    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    // 一开始还没跑过：冻结区未建立 → 0%（上限已知 = 服务端上报 100K）
    expect(ringText(tester), '0%',
        reason: '还没跑过时占用是 0 —— 上限已知，所以不是 "—"');

    await send(tester, '你好');
    await tester.pump(const Duration(milliseconds: 400));

    // ★★ 核心：跑了之后圆环显示**真实的非零占用**
    //   （冻结区 5200 + 一句用户输入；上限 100K ⇒ ≈5%）
    final after = ringText(tester);
    expect(after, isNot('0%'),
        reason: '跑完一次运行后圆环必须反映真实占用 —— 永远 0% 说明记账没接上');
    final pct = double.parse(after.replaceAll('%', ''));
    expect(pct, inInclusiveRange(4, 8),
        reason: '≈ 5200+/100000 ≈ 5% —— 不许把一个随便的数画上去');

    // 详情页里必须能看到**冻结区**那块数（5200 → ~5.2K）
    await openUsageSheet(tester);
    expect(inSheet(find.text('冻结内容')), findsOneWidget,
        reason: '没跑过时画的是"冻结内容/对话内容"两行（旧图例）');
    expect(inSheet(find.textContaining('5.2K')), findsOneWidget,
        reason: '冻结区 5200 必须如实画出来（旧 usageInfo 通道给的同一个数）');
  });

  testWidgets('★★ null 轮次不参与：缓存页按已上报轮次算，且必须标注分母',
      (tester) async {
    final c = await freshController();
    installMocks();
    // 一次运行两轮：一轮上报 90%（900 / 1000 整段），一轮未上报
    turnsForRun = (_) => [
          turn(cachedTokens: 900, outputTokens: 10, wallMs: 1000),
          turn(cachedTokens: null, promptTokens: 5000, outputTokens: 10, wallMs: 1000),
        ];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await send(tester, '你好');
    await tester.pump(const Duration(milliseconds: 400));

    // 打开半抽屉 → 第 2 页（缓存命中）
    await openUsageSheet(tester);
    await swipeToCachePage(tester);

    // 命中率 = 900 / 1000 = 90%（prompt = **整段**；未上报那一轮的
    // 5000 prompt **不进分母**）
    expect(inSheet(find.text('90%')), findsOneWidget,
        reason: '未上报轮次不得稀释命中率');
    // ★ 必须标注分母
    expect(inSheet(find.textContaining('1 轮未上报')), findsOneWidget);
    expect(inSheet(find.textContaining('共 2 轮')), findsOneWidget);
    // ★ 口径变更：旧版这里还断言顶栏指示器带 `*`（"部分轮次未上报"的标记）。
    //   那个 `*` 长在**已退场的 `UsageIndicator` 文字指示器**上；今天的等价
    //   保证就是上面两条**分母标注**（明确写出"命中率只统计已上报的 N 轮"）
    //   —— 意图（不许把未上报当成 0 混进统计）一条没少，只是换了承载物。
  });

  testWidgets('★★ 全部未上报 → 缓存页显示「未上报」，绝不显示 0%', (tester) async {
    final c = await freshController();
    installMocks();
    turnsForRun = (_) =>
        [turn(cachedTokens: null, promptTokens: 1000, outputTokens: 10, wallMs: 1000)];

    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await send(tester, '你好');
    await tester.pump(const Duration(milliseconds: 400));

    await openUsageSheet(tester);
    await swipeToCachePage(tester);

    // ★ 口径变更：旧版边栏写「不可用」，今天半抽屉写「未上报」+ 一句解释
    //   （同一个契约 §3.4 的降级规则，只是文案不同）。
    expect(inSheet(find.text('未上报')), findsOneWidget);
    expect(inSheet(find.textContaining('不是 0%')), findsOneWidget,
        reason: '要如实说明"未上报"而不是画一个 0%');
    expect(inSheet(find.text('0%')), findsNothing,
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

    // A 发 3 条 → A 累计 3 轮（每轮 90%）
    await send(tester, 'A1');
    await tester.pump(const Duration(milliseconds: 300));
    await send(tester, 'A2');
    await tester.pump(const Duration(milliseconds: 300));
    await send(tester, 'A3');
    await tester.pump(const Duration(milliseconds: 300));

    // ---- A 的缓存页：有账（90%）----
    //
    // ★ 口径变更：旧版断言的是边栏"运行次数 = 3"（`UsageSidebar` 的
    //   会话统计段）。半抽屉两页里**没有**这一行，所以改成钉
    //   **这个会话自己的命中率** —— 它同样是"当前会话的账"的直接证据，
    //   而且下面切到 B 时能反过来证伪（B 拿不到 A 的数）。
    await openUsageSheet(tester);
    await swipeToCachePage(tester);
    expect(inSheet(find.text('90%')), findsOneWidget,
        reason: 'A 跑过 3 轮、每轮上报 90% ⇒ 累计加权 = 90%');
    await closeUsageSheet(tester);

    // ---- 切到 B：B 从没跑过 → 必须是"未上报"，绝不是 A 的 90% ----
    await switchTo(tester, '会话 B');
    await openUsageSheet(tester);
    await swipeToCachePage(tester);

    expect(inSheet(find.text('未上报')), findsOneWidget,
        reason: 'B 没有任何运行 —— 缓存命中必须显示"未上报"（而不是 A 的值）');
    expect(inSheet(find.text('90%')), findsNothing,
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
    await openUsageSheet(tester);
    await swipeToCachePage(tester);

    expect(inSheet(find.text('90%')), findsOneWidget,
        reason: '切走期间跑完的那次，用量必须记在 A 上 —— 不能随渲染守卫一起被丢掉');
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

  testWidgets('★★ 用量详情走半抽屉：右侧不挂抽屉、左侧仍保留 200dp 打开手势',
      (tester) async {
    final c = await freshController();
    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);

    // ★ 口径变更（2026-10-25）：用量详情已从"右侧 endDrawer"改成
    //   **半抽屉**（`showUsageSheet`）⇒ `Scaffold` 上**没有 endDrawer**。
    //   旧断言 `endDrawerEnableOpenDragGesture == false` 钉的是
    //   "别让右侧边缘抽屉抢系统返回手势" —— 今天这个开关**没有对象**
    //   （endDrawer 为 null ⇒ 右侧根本不建 DrawerController，
    //   手势无从挂起），所以等价判据是下一条：endDrawer 必须为 null。
    expect(scaffold.endDrawer, isNull,
        reason: '右侧边缘是系统返回区：不得再挂 endDrawer（详情已改半抽屉）');

    // 左侧**保持** 200dp（docs/21 实测定的，不要顺手改动）
    expect(scaffold.drawerEnableOpenDragGesture, isTrue);
    expect(scaffold.drawerEdgeDragWidth, 200);

    // ★ 真正要保护的东西：用量详情**打得开**，而且是半抽屉形态
    //   （旧断言用 `scaffold.endDrawer != null` 证明"详情还挂着"；
    //   今天的等价物 = 点圆环能弹出那个 PageView 半抽屉）。
    await openUsageSheet(tester);
    expect(inSheet(find.text('已用')), findsOneWidget,
        reason: '第 1 页是上下文占用（环图中心标注"已用"）');
  });
}

// ============================================================================
// 假执行器（2026-10-25 mock 基建重接）：走 AgentBridge.executorFactoryForTest
// —— 事件经 handle.events → emitLocalEvent → UI（生产同一条路径）。
// ============================================================================

/// 脚本化执行器：`run()` 立即返回句柄；[onScript] 在句柄返回后跑（本文件
/// 用它做 gate）；完成后以 [buildResult] 的罐头数据收尾。
///
/// ★ 它还负责**冻结区**：`AgentBridge.run()` 在结果返回后读
/// `executor.lastFrozenTokens` —— 生产里由真实执行器填，这里填 5200
/// （等价旧 `usageInfo` 通道返回的 frozenTokens）。
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