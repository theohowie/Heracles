import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/stream_step.dart';

import 'support/secure_storage_mock.dart';

/// **「切会话后已生成的工作步骤消失」回归测试**（2026-10-12，S5）。
///
/// ## 用户报的 bug（照录）
///
/// > "我从会话1切换会话2，前面几轮输出的工作步骤不见了，
/// >  现在不会暂停了，但是它已经生成的步骤会消失"
///
/// ## 根因
///
/// `HStepStream`（逐字思考/正文）**当时根本不落盘** ——
/// `models/message.dart` 里还写着"刻意不持久化，这是设计不是 bug"。
///
/// 切会话 → `_messages.clear()` → `_loadMessages` → 磁盘上没有过程记录
/// ⇒ **步骤全消失**。
///
/// ## 本文件防什么
///
/// 1. **往返**：磁盘上有 `{"role":"step"}` → 走真实 UI 路径读回 →
///    必须还原成步骤卡片，**思考与正文都要在**（且**分得开**）。
/// 2. **变异**：把"读回时还原步骤"那一段去掉，本文件必须失败
///    （见文件末尾 `_toMessages` 的行为说明与 README 的变异步骤）。
/// 3. **旧读取方**：不认识的 role 必须被忽略，不能让整条会话读不出来。
/// 4. **不静默丢信息**：截断过的步骤必须**如实显示**被截断。
///
/// ## ★★ mock 基建重接（2026-10-25，mock 回家第二批）
///
/// 旧夹具在 `heracles/command` 上 mock `loadMessages` / `listSessions`
/// （**内核迁移后已删除**：`AgentBridge.loadMessages` 现在走 Dart
/// `SessionStore` ⇒ `heracles/device` 的 `fs.*`）+ 一条 `EventChannel`
/// （已删除）。⇒ 旧夹具下"读回"**永远拿到空数组**：本文件的核心断言
/// （步骤卡片必须还原）会红，而"未知 role 被忽略"那类反而**空跑变绿**。
///
/// 现在按真通道给数据：`<ws>/.heracles/sessions.json`（索引）与
/// `<ws>/.heracles/sessions/<sid>.jsonl`（消息行）—— 形状与真机逐字节同源
/// （`SessionStore` 就是往这两个路径 `fs.readText` / `fs.writeText` 的）。
///
/// **断言与测试体零改动**（除抽屉入口 finder：☰ 已换成品牌图标，按 asset 名定位）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 安全存储通道 mock（坑 36）：没有它，第一条用例（`freshController()`）
  //   的 `SettingsController.load()` 会**永久挂死**（原始状态实测：10 分钟超时）。
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

  /// 磁盘内容（按会话 id）—— 由各用例直接摆出"磁盘上有什么"
  late Map<String, List<Map<String, dynamic>>> disk;

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

    // 事件通道 mock 已随内核迁移退场（`heracles/events` 在 app/lib 里
    // **零构造**）—— 留着反而误导后来人。
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

  /// 开抽屉（顶栏左侧**品牌图标**，原型 01）→ 点会话 A →
  /// 触发 `loadMessages` → `_toMessages` → 渲染
  Future<void> openSessionA(WidgetTester tester) async {
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
    final inDrawer = find.descendant(
        of: find.byType(Drawer), matching: find.text('会话 A'));
    expect(inDrawer, findsOneWidget, reason: '抽屉里应当能看到「会话 A」');
    await tester.tap(inDrawer);
    await settle(tester);
  }

  /// 把正文列表滚到底 —— `ListView.builder` 是**惰性构建**，
  /// 视口外的条目根本不创建（不滚就断言 findsNothing 是**测试的假失败**）。
  Future<void> scrollToBottomOfList(WidgetTester tester) async {
    final list = find.byType(Scrollable);
    if (list.evaluate().isEmpty) return;
    await tester.drag(list.first, const Offset(0, -600));
    await tester.pump();
    await tester.drag(list.first, const Offset(0, -600));
    await settle(tester);
  }

  setUp(() {
    disk = {};
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
  });

  // ==================================================================
  // ★★ 核心：写一个含过程态的会话 → 读回 → 断言步骤完整还原
  // ==================================================================

  /// 磁盘上一条 `step` 行 —— 形状必须与 `SessionStore` 的
  /// `"step"` 分支 / `chat_screen._toMessages` 的 `case 'step'` **逐字段一致**。
  Map<String, dynamic> stepRow({
    int index = 1,
    String stepId = 'turn-1',
    String think = '',
    String text = '',
    String stage = 'ok',
    int ms = 1200,
    bool truncated = false,
  }) =>
      {
        'role': 'step',
        'i': index,
        'stepId': stepId,
        'title': '第 $index 轮',
        'think': think,
        'text': text,
        'stage': stage,
        'ms': ms,
        if (truncated) 'truncated': true,
        'ts': 100,
      };

  testWidgets('★★ S5：含过程态的会话读回后，步骤必须完整还原（含思考与正文）',
      (tester) async {
    final c = await freshController();

    // ---- 磁盘：真实的一轮过程（思考 + 正文），形状与落盘一致 ----
    const think =
        '用户想让我创建一个文件。我应该先看看目录里有什么，再动手写。';
    const body = '{"tool":"write_file","args":{"path":"a.txt"}}';
    disk['sess-A'] = [
      {'role': 'user', 'text': '写个文件', 'ts': 1},
      stepRow(index: 1, stepId: 'turn-1', think: think, text: body),
      {
        'role': 'tool',
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        'result': '已写入 2 字节',
        'state': 'succeeded',
        'ok': true,
        'ts': 2,
      },
      {'role': 'assistant', 'text': '写好了', 'prompt': 10, 'out': 5, 'ms': 3, 'ts': 3},
    ];

    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await openSessionA(tester);
    await scrollToBottomOfList(tester);

    // ---- ★★ 核心断言 1：步骤卡片被还原出来了 ----
    final steps = tester.widgetList<StreamStepView>(find.byType(StreamStepView));
    expect(steps, isNotEmpty,
        reason: 'S5：磁盘上有 step 记录，但界面上一张步骤卡片都没有 —— '
            '这就是用户报的「切会话后步骤消失」');

    final step = steps.first.step;

    // ---- ★★ 核心断言 2：**思考**还原了（这是用户最想要的那部分）----
    expect(step.reasoning, contains('我应该先看看目录里有什么'),
        reason: 'S5：思考全文必须先落盘再读回 —— 少了它用户就看不到 AI 在想什么');

    // ---- ★★ 核心断言 3：**正文**还原了 ----
    expect(step.text, contains('write_file'),
        reason: 'S5：过程正文（模型原话）必须原样还原');

    // ---- ★★ 核心断言 4：思考与正文**分得开**（两条轨，不是一锅粥）----
    expect(step.reasoning.contains('write_file'), isFalse,
        reason: '思考里不该混进正文 —— 粘在一起用户就分不清"想什么"与"答什么"');

    // ---- 断言 5：读回来的步骤**不是**"正在生成"状态 ----
    expect(step.finished, isTrue,
        reason: '读回来的步骤已经结束；画成转圈会让用户以为它还在跑');
    expect(step.streaming, isFalse);

    // ---- 断言 6：轮次与状态也在 ----
    expect(step.index, 1);
    expect(step.parsedStage, StepStage.ok);

    // ---- 断言 7：原有的工具卡片与回答**一条都没少** ----
    expect(find.text('已写入 2 字节'), findsWidgets,
        reason: '加过程态不能挤掉既有记录');
    expect(find.text('写好了'), findsWidgets);
  });

  testWidgets('★★ S5：思考与正文在界面上**分块渲染**（不是同一段文字）',
      (tester) async {
    final c = await freshController();
    disk['sess-A'] = [
      {'role': 'user', 'text': '写个文件', 'ts': 1},
      stepRow(
        index: 1,
        think: '先想一想再动手',
        text: '{"final":"好了"}',
      ),
    ];
    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await openSessionA(tester);
    await scrollToBottomOfList(tester);

    final s = tester
        .widgetList<StreamStepView>(find.byType(StreamStepView))
        .first
        .step;
    // 两段文本都能在界面上找到，且是**两条不同的 Text**
    expect(find.textContaining('先想一想再动手'), findsWidgets,
        reason: '思考必须显示出来');
    expect(find.textContaining('好了'), findsWidgets);
    // ★ 不是同一个字符串（粘一起就分不开了）
    expect(s.reasoning, isNot(equals(s.text)));
  });

  // ==================================================================
  // 旧读取方：不认识的 role 必须被忽略，不能让整条会话读不出来
  // ==================================================================

  testWidgets('★ 未知 role 被忽略，其余消息照常读回（不崩、不静默丢）',
      (tester) async {
    final c = await freshController();
    disk['sess-A'] = [
      {'role': 'user', 'text': '你好', 'ts': 1},
      // 将来某个版本新增的 role —— 旧 App 必须能忽略它
      {'role': 'future_thing', 'text': '我不认识的记录', 'ts': 2},
      {'role': 'assistant', 'text': '我认得这条', 'prompt': 1, 'out': 1, 'ms': 1, 'ts': 3},
    ];

    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await openSessionA(tester);
    await scrollToBottomOfList(tester);

    // 认得的两条都在
    expect(find.text('你好'), findsWidgets);
    expect(find.text('我认得这条'), findsWidgets,
        reason: '未知 role 不得让整条会话读不出来 —— 那会是"记录全没了"');
  });

  // ==================================================================
  // 不静默丢信息：截断必须**看得见**
  // ==================================================================

  testWidgets('★ 被截断过的步骤会如实标注（不假装完整）', (tester) async {
    final c = await freshController();
    disk['sess-A'] = [
      stepRow(
        index: 1,
        think: 'A' * 20,
        text: 'B' * 20,
        truncated: true,
      ),
    ];

    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await openSessionA(tester);
    await scrollToBottomOfList(tester);

    final step = tester
        .widgetList<StreamStepView>(find.byType(StreamStepView))
        .first
        .step;
    expect(step.truncated, isTrue,
        reason: '落盘上限截断过就必须标记 —— 静默截断会让用户以为模型只说了这么多');
  });

  // ==================================================================
  // 三态不混淆：empty / error 与 ok 不同
  // ==================================================================

  testWidgets('★ 步骤三态被区分：empty ≠ ok ≠ error 缺失（不是布尔）',
      (tester) async {
    final c = await freshController();
    disk['sess-A'] = [
      stepRow(index: 1, stepId: 'turn-1', text: '', stage: 'empty'),
      stepRow(index: 2, stepId: 'turn-2', text: '出错了', stage: 'error'),
    ];

    installMocks();
    await tester.pumpWidget(wrapScreen(c));
    await settle(tester);
    await openSessionA(tester);
    await scrollToBottomOfList(tester);

    final stages = tester
        .widgetList<StreamStepView>(find.byType(StreamStepView))
        .map((w) => w.step.parsedStage)
        .toList();
    expect(stages, contains(StepStage.empty));
    expect(stages, contains(StepStage.error),
        reason: '"生成成功但内容为空"与"出错"对用户是不同的事，不能都画成失败');
  });

  // ==================================================================
  // 解析容错（纯模型层，不起 widget）
  // ==================================================================

  group('StepStage 容错解析', () {
    test('★ 三个已知状态各自解析正确', () {
      expect(StepStage.parse('running'), StepStage.running);
      expect(StepStage.parse('ok'), StepStage.ok);
      expect(StepStage.parse('empty'), StepStage.empty);
      expect(StepStage.parse('error'), StepStage.error);
    });

    test('★ 未知/缺失 → ok（旧数据必须还能显示出来，不能整条丢掉）', () {
      expect(StepStage.parse(null), StepStage.ok);
      expect(StepStage.parse(''), StepStage.ok);
      expect(StepStage.parse('someFutureStage'), StepStage.ok,
          reason: '返回 null 会让调用方干脆不画 = 把用户数据丢了');
    });

    test('★ wire 与 name 一致（跨进程契约不能漂移）', () {
      for (final s in StepStage.values) {
        expect(s.wire, s.name);
        expect(StepStage.parse(s.wire), s);
      }
    });
  });

  group('HStepStream 读回语义', () {
    test('★ 读回的步骤不是"正在生成"（不能永远转圈）', () {
      const s = HStepStream(id: 'x', stepId: 'turn-1', finished: true);
      expect(s.streaming, isFalse,
          reason: '读回来的步骤已结束；画成转圈会让用户以为它还在跑');
    });

    test('★ 未结束的步骤是 streaming', () {
      const s = HStepStream(id: 'x', stepId: 'turn-1');
      expect(s.streaming, isTrue);
      expect(s.finished, isFalse);
    });

    test('★ shortStepId 只影响显示，不承担唯一性', () {
      expect(const HStepStream(id: 'x', stepId: 'turn-3').shortStepId, '#3');
      // 没有连字符时原样返回（不是崩溃、也不是空串）
      expect(const HStepStream(id: 'x', stepId: 'abc').shortStepId, 'abc');
    });
  });
}