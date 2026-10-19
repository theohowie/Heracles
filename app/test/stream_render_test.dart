import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/stream_step.dart';

/// **逐字渲染（S3）的测试** —— 思考与正文两条轨 + buffer/16ms flush。
///
/// ## 这一组测试防的是什么
///
/// 用户的原话：
/// > "AI 接收到任务后会先开始**思考**怎么完成，AI 的思考过程也是展示出来，
/// >  **一个字一个字出来**，不是等 AI 想完了再全部展示出来"
///
/// 最怕的回归有三条，每一条都不会报错、不会崩，只是用户又开始不满意：
///
/// 1. **未知事件类型把 App 搞崩** —— Kotlin 侧（S2）已经在发 4 类 token 级
///    事件，Dart 侧若没有降级分支，用户一发消息就是闪退。
/// 2. **思考与正文粘成一条** —— 粘了就再也分不开，用户分不清哪句是结论。
/// 3. **每个 token 都 setState** —— 满载时每秒 250 次重建，逐字变卡顿。
///
/// ## 关于时钟：为什么不用 `await Future.delayed`
///
/// `tester.pump()` 推进的是**虚拟**时钟，而 `Future.delayed` 等的是
/// **真实**时间。两者混用会让测试在 `await` 上挂死（`pump` 不会让
/// 真实 timer 前进）。所以本文件**只用 `tester.pump(Duration)`** 驱动，
/// 事件的到达也由 pump 带过去 —— 见 [push] 的说明。
///
/// ⚠️ 同理不用 `pumpAndSettle`：16ms 周期定时器让 settle 条件永不成立，
/// 它会一直转到超时。
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

  MockStreamHandlerEventSink? sink;
  Completer<void>? gate;

  /// **发送**一帧事件到平台端（不等待它到达 Dart）。
  ///
  /// ⚠️ 刻意**不** `await Future.delayed(Duration.zero)`：
  /// 那是真实异步，而 `tester.pump` 只推进虚拟时钟 —— 混用会让测试
  /// 在 `await` 上挂死（`pump` 不会让真实 timer 前进）。
  /// 事件到达由随后的 `tester.pump()` 驱动。
  void push(Map<String, dynamic> e) => sink!.success(e);

  void installMocks() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'listWorkspaces':
          return [workspaceMap];
        case 'listSessions':
          return <Map<String, dynamic>>[];
        case 'loadMessages':
          return <Map<String, dynamic>>[];
        case 'createSession':
          return 'sess-new';
        case 'runAgent':
          final g = gate;
          if (g != null) await g.future;
          return <String, dynamic>{
            'stopReason': '已给出最终回答',
            'finalText': '',
            'totalCachedTokens': 0,
            'totalPromptTokens': 0,
            'totalOutputTokens': 0,
            'steadyHitRate': null,
            'turns': <Map<String, dynamic>>[],
          };
        default:
          return null;
      }
    });

    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          // ⚠️ **按字段逐个拷一份 `Map<String, dynamic>`** ——
          // 直接把闭包参数 `events` 存进顶层变量会让它被**提升为泛型**
          // （`MockStreamHandlerEventSink<dynamic>`），于是编码器
          // 认不出它、抛 "Invalid argument: Instance of ..."。
          // 局部变量 + 赋值给 `late` 字段则保留具体实例类型。
          late MockStreamHandlerEventSink s;
          s = events;
          sink = s;
        },
        onCancel: (arguments) => sink = null,
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

  /// 推进虚拟时钟。
  ///
  /// **每次 pump 至少 20ms**：16ms 帧窗口 + 一点余量。
  /// 用比窗口更小的步长会把"同一帧内的多次增量"拆成多帧 ——
  /// 那样量到的就不是缓冲了。
  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 起一个被 gate 卡住的运行（`run()` 不返回，事件照收）。
  Future<void> startRun(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, '做个任务');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
  }

  /// 逐字步骤**自己**有没有在转圈。
  ///
  /// ⚠️ 不能直接 `find.byType(CircularProgressIndicator)` ——
  /// 运行被 gate 卡住时，界面顶部的「正在生成…」横幅**自己也有一个转圈**，
  /// 那是另一个 UI 元素。不加限定会得到假失败（"还有转圈"），
  /// 而被测的其实是那条步骤。
  ///
  /// 用 `StreamStepView`（逐字步骤的 widget）作限定范围。
  Finder stepSpinner() => find.descendant(
        of: find.byType(StreamStepView),
        matching: find.byType(CircularProgressIndicator),
      );

  setUp(() {
    gate = Completer<void>();
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
    sink = null;
    gate = null;
  });

  /// 释放被 gate 卡住的运行，让测试干净收尾。
  Future<void> release(WidgetTester tester) async {
    gate?.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
  }

  // ==================================================================
  // 0. ★★ 最高优先级：未知事件类型**不能崩**（S2 交接的第一条要求）
  //
  // 为什么它排在渲染之前：Kotlin 侧已经在发 4 类新事件。
  // 若解析路径会抛，用户一发消息直接闪退 —— 那比"看不到逐字"严重得多。
  // ==================================================================

  group('★ 未知事件的降级', () {
    test('fromMap 对完全陌生的类型不抛，且 isKnown=false', () {
      final e = AgentEvent.fromMap({
        'type': 'some_future_event_v99',
        'ts': 1,
        'stepId': 'turn-1',
        'delta': 'x',
      });
      expect(e.type, 'some_future_event_v99');
      expect(e.isKnown, isFalse);
      expect(e.isTerminal, isFalse);
    });

    test('★ token 级字段缺失时全是 null —— 不伪造空串', () {
      // 老 Kotlin 不发这些字段：空串会被 UI 当成"真的吐了个空字"
      final e = AgentEvent.fromMap({'type': 'step_delta', 'ts': 1});
      expect(e.stepId, isNull);
      expect(e.delta, isNull);
      expect(e.status, isNull);
      expect(e.summary, isNull);
      expect(e.durationMs, isNull);
    });

    test('4 类 token 级事件都算 isKnown', () {
      for (final t in [
        'step_started',
        'reasoning_delta',
        'step_delta',
        'step_ended',
      ]) {
        expect(AgentEvent.fromMap({'type': t, 'ts': 1}).isKnown, isTrue,
            reason: '$t 必须被 Dart 认识');
      }
    });

    testWidgets('★★ 推送完全未知的事件类型 → App 不崩，且已有界面不受影响',
        (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      // 先来一条真实事件，建立一个"有东西"的基线
      push({
        'type': 'step_started',
        'ts': 1,
        'stepId': 'turn-1',
        'title': '正在生成第 1 轮',
        'index': 1,
      });
      await settle(tester);
      expect(find.text('正在生成第 1 轮'), findsOneWidget);

      // ★★ 未来的事件类型（Dart 完全不认识）★★
      push({'type': 'totally_unknown_event', 'ts': 2, 'whatever': 1});
      await settle(tester);

      // 不崩 + 已渲染的内容还在
      expect(tester.takeException(), isNull,
          reason: '未知事件类型必须降级忽略，不能抛 —— 否则用户一发消息就闪退');
      expect(find.text('正在生成第 1 轮'), findsOneWidget,
          reason: '未知事件不该冲掉已经渲染出来的步骤');

      // 未知事件之后仍能正常继续收事件（没把订阅搞死）
      push({
        'type': 'step_delta',
        'ts': 3,
        'stepId': 'turn-1',
        'delta': '还能继续',
      });
      await settle(tester);
      expect(find.textContaining('还能继续'), findsOneWidget,
          reason: '未知事件之后事件流必须仍然可用');

      expect(tester.takeException(), isNull);
      await release(tester);
    });
  });

  // ==================================================================
  // 1. ★★ 逐字累积 + buffer/16ms flush
  // ==================================================================

  group('★ 逐字累积与 buffer flush', () {
    testWidgets('★★ 多个 delta 在一次帧窗口内累积，且一个字都不丢', (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started',
        'ts': 0,
        'stepId': 'turn-1',
        'title': '正在生成第 1 轮',
        'index': 1,
      });
      await settle(tester);

      // 连推 5 个增量 —— **不 pump**，让它们全落进缓冲
      for (final ch in ['我', '需', '要', '先', '看']) {
        push({'type': 'step_delta', 'ts': 1, 'stepId': 'turn-1', 'delta': ch});
      }
      // 只把事件送到 Dart（一帧的时间），够它们进缓冲
      await tester.pump(const Duration(milliseconds: 1));

      // 此刻界面**还没**更新（缓冲尚未 flush）——
      // 这正是"不要每个 token 都 setState"的可见证据。
      //
      // ⚠️ 这一条断言就是**变异测试的靶子**：把 buffer 去掉
      // （每个 delta 直接 setState）之后，这里会立刻 findsOneWidget。
      expect(find.textContaining('我需要先看'), findsNothing,
          reason: 'delta 到达后到下一次 flush 之前，界面不该重建 —— '
              '否则每个 token 都重建一次（满载时每秒 250 次）');

      // 推进一帧
      await tester.pump(const Duration(milliseconds: 20));

      // 一帧之后，五个字**全部**到齐（不丢字）
      expect(find.text('我需要先看'), findsOneWidget);

      // 再推一批，确认是持续逐字而不是一次性的
      push({'type': 'step_delta', 'ts': 2, 'stepId': 'turn-1', 'delta': '文件'});
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('我需要先看文件'), findsOneWidget);

      expect(tester.takeException(), isNull);
      await release(tester);
    });

    testWidgets('★★ 思考与正文是两条轨：分别累积，绝不互相污染', (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started',
        'ts': 0,
        'stepId': 'turn-1',
        'title': '正在生成第 1 轮',
        'index': 1,
      });
      await settle(tester);

      // 交替推两条轨的增量（真实情况下它们就是交织到达的）
      push({
        'type': 'reasoning_delta', 'ts': 1, 'stepId': 'turn-1', 'delta': '让我想想',
      });
      push({
        'type': 'step_delta', 'ts': 2, 'stepId': 'turn-1', 'delta': '答案是',
      });
      push({
        'type': 'reasoning_delta', 'ts': 3, 'stepId': 'turn-1', 'delta': '好像要算一下',
      });
      push({
        'type': 'step_delta', 'ts': 4, 'stepId': 'turn-1', 'delta': '四十二',
      });
      await settle(tester);

      // ★ 两条轨各自完整（顺序也保持）
      expect(find.text('让我想想好像要算一下'), findsOneWidget,
          reason: '思考轨必须自己累积成一条完整的思考，不能被正文打断');
      expect(find.text('答案是四十二'), findsOneWidget,
          reason: '正文轨必须自己累积，不能被思考的字插进来');

      // ★★ 关键：**不得**出现串轨的字符串 ★★
      // 串轨是这类实现最典型的 bug：一个 buffer 走天下，
      // 用户看到"思考里混着答案、答案里混着思考"，且**再也分不开**。
      //
      // 同样，这几条也是**变异测试的靶子**：把两条轨合成一个 buffer 后，
      // 下面任何一条都会红。
      expect(find.textContaining('让我想想答案是'), findsNothing,
          reason: '★ 串轨：思考轨里混进了正文');
      expect(find.textContaining('答案是让我想想'), findsNothing,
          reason: '★ 串轨：正文轨里混进了思考');
      expect(find.text('让我想想好像要算一下答案是四十二'), findsNothing,
          reason: '★ 两条轨被拼成了一行 —— 用户再也分不清哪句是思考');

      expect(tester.takeException(), isNull);
      await release(tester);
    });

    testWidgets('★ 逐字到达的中间态是真递增的（不是等结束才出现）', (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started', 'ts': 0, 'stepId': 'turn-1', 'index': 1,
      });
      await settle(tester);

      push({
        'type': 'step_delta', 'ts': 1, 'stepId': 'turn-1', 'delta': '第一段',
      });
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('第一段'), findsOneWidget);

      push({
        'type': 'step_delta', 'ts': 2, 'stepId': 'turn-1', 'delta': '第二段',
      });
      await tester.pump(const Duration(milliseconds: 20));
      // 累积（不是替换）—— 前半段必须还在
      expect(find.text('第一段第二段'), findsOneWidget,
          reason: 'delta 是【增量】，UI 必须累加；替换会让用户只看到最后一小段');

      await release(tester);
    });

    testWidgets('★ step_ended 用最终文本收口，并停止「逐字中」状态', (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started', 'ts': 0, 'stepId': 'turn-1', 'index': 1,
      });
      push({
        'type': 'step_delta', 'ts': 1, 'stepId': 'turn-1', 'delta': '草稿',
      });
      await settle(tester);
      expect(find.text('草稿'), findsOneWidget);

      push({
        'type': 'step_ended',
        'ts': 2,
        'stepId': 'turn-1',
        'status': 'ok',
        'durationMs': 1234,
        'summary': '最终整理好的文本',
        'index': 1,
      });
      await settle(tester);

      expect(find.text('最终整理好的文本'), findsOneWidget);
      expect(find.text('1234ms'), findsOneWidget);
      // 结束之后**这条步骤**不该还在转圈
      expect(stepSpinner(), findsNothing,
          reason: 'step_ended 之后必须停掉「生成中」，否则用户以为还在跑');

      await release(tester);
    });

    testWidgets('★ summary 比逐字累积短时不得吞掉已显示的字', (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started', 'ts': 0, 'stepId': 'turn-1', 'index': 1,
      });
      push({
        'type': 'step_delta', 'ts': 1, 'stepId': 'turn-1', 'delta': '前半',
      });
      await tester.pump(const Duration(milliseconds: 20));

      // 最后一段塞进缓冲后**立刻**来 step_ended（不等下一帧）——
      // 这是真机上完全可能的时序
      push({
        'type': 'step_delta', 'ts': 2, 'stepId': 'turn-1', 'delta': '后半',
      });
      push({
        'type': 'step_ended',
        'ts': 3,
        'stepId': 'turn-1',
        'status': 'ok',
        'durationMs': 10,
        // summary 比累积更短 —— 模拟被截断（思考吃光预算，见 docs/25 §13.3）
        'summary': '前半',
        'index': 1,
      });
      await settle(tester);

      // 缓冲必须先 flush（否则末尾的「后半」永远丢）
      expect(find.text('前半后半'), findsOneWidget,
          reason: 'step_ended 前必须先 flush 缓冲，且 summary 更短时不得退步 —— '
              '用户会看到内容凭空变少');
      await release(tester);
    });

    testWidgets('★ 事件流断掉时缺失的 step_ended 会被兜底收口', (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started', 'ts': 0, 'stepId': 'turn-1', 'index': 1,
      });
      push({
        'type': 'step_delta', 'ts': 1, 'stepId': 'turn-1', 'delta': '生成到一半',
      });
      await settle(tester);
      expect(find.text('生成到一半'), findsOneWidget);

      // finished 到了但 step_ended 丢了（流断了）
      push({'type': 'finished', 'ts': 2, 'finalText': '', 'turnCount': 1});
      await settle(tester);

      expect(stepSpinner(), findsNothing,
          reason: '运行结束后不得留下永远转圈的步骤 —— 用户会以为它还在跑');
      expect(find.text('生成到一半'), findsOneWidget,
          reason: '收口不得丢掉已经生成的文本');
      await release(tester);
    });
  });

  // ==================================================================
  // 2. ★ 自动滚动可打断（`docs/25` §5.3 第 3 条）
  // ==================================================================

  group('★ 自动滚动可打断', () {
    testWidgets('★ 用户上滑后暂停自动滚动，并出现「有新内容」按钮', (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started', 'ts': 0, 'stepId': 'turn-1', 'index': 1,
      });
      // 堆足够多的内容，让列表真的能滚起来（惰性构建：要有东西可滚）
      for (var i = 0; i < 80; i++) {
        push({
          'type': 'step_delta',
          'ts': i,
          'stepId': 'turn-1',
          'delta': '第 $i 行内容\n',
        });
      }
      await settle(tester);

      // 用户手动上滑 = 想看上面的东西
      final scrollable = find.byType(Scrollable).first;
      await tester.drag(scrollable, const Offset(0, 240));
      await settle(tester);

      // 上滑之后**再来**新内容 —— 此时应当出现提示按钮
      push({
        'type': 'step_delta', 'ts': 99, 'stepId': 'turn-1', 'delta': '新来的一段\n',
      });
      await settle(tester);

      // ★ 2026-10-13：按钮改成**只有图标的小圆圈**（用户要求
      //   「有新内容占的空间太大了，应该变成一个小圆圈按钮」）——
      //   所以按 icon 找，不再按文字找。
      final newContent = find.byIcon(Icons.arrow_downward_rounded);
      expect(newContent, findsOneWidget,
          reason: '用户上滑后仍源源不断来字，没有提示他会以为内容丢了');

      // 点它 → 回到跟随状态，提示消失
      await tester.tap(newContent);
      await settle(tester);
      expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing,
          reason: '回到底部后提示必须消失 —— 否则用户以为又漏看了什么');

      await release(tester);
    });

    testWidgets('★ 没有上滑时不该出现「有新内容」按钮（不制造假提示）',
        (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started', 'ts': 0, 'stepId': 'turn-1', 'index': 1,
      });
      for (var i = 0; i < 6; i++) {
        push({
          'type': 'step_delta', 'ts': i, 'stepId': 'turn-1', 'delta': '内容$i\n',
        });
      }
      await settle(tester);

      expect(find.text('有新内容'), findsNothing,
          reason: '视口一直跟着底部时显示「有新内容」只会让人以为漏看了东西');
      await release(tester);
    });
  });

  // ==================================================================
  // 3. 清理：Timer 不泄漏
  // ==================================================================

  group('★ 生命周期', () {
    testWidgets('★★ dispose 之后 16ms 定时器必须已取消（不能对着死 State 跑）',
        (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started', 'ts': 0, 'stepId': 'turn-1', 'index': 1,
      });
      push({
        'type': 'step_delta', 'ts': 1, 'stepId': 'turn-1', 'delta': 'abc',
      });
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('abc'), findsOneWidget);

      // 前提：定时器此刻**确实活着**（否则下面的断言是空话）
      final state = tester.state<State<ChatScreen>>(find.byType(ChatScreen));
      expect(
        (state as dynamic).hasFlushTimer,
        isTrue,
        reason: '前提：逐字进行中，16ms 帧定时器应当在跑',
      );

      // 把页面换掉 = dispose
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await settle(tester);

      // ★★ 核心断言：定时器**已经取消** ★★
      //
      // ## 为什么必须直接看计时器状态，而不是"看有没有异常"
      //
      // 我先写的是"dispose 后 takeException 应为 null" —— 那条**测不出泄漏**：
      // 定时器还在，但缓冲已经空了，`_flushDeltas` 第一行就 return，
      // 于是既不 setState 也不抛异常。测试全绿，代码却在泄漏。
      // （这正是"绿测试保护不了错误代码"的典型：断言要盯着真实机制。）
      //
      // `Timer.periodic` 的问题在于它**不受 widget 生命周期管理**：
      // 不取消的话，离开页面后它每 16ms 还在跑，闭包持有 State ⇒
      // 整个 State 树无法回收。
      expect(
        (state as dynamic).hasFlushTimer,
        isFalse,
        reason: 'dispose 后 16ms 定时器仍在活动 —— 必须在 dispose 里 '
            '_flushTimer?.cancel()，否则每 16ms 泄漏一次回调',
      );

      // 再推进一大段时间：残留定时器还会继续触发
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);

      gate?.complete();
    });

    testWidgets('★ 切会话后缓冲被清空（旧会话的字不得并进新会话）',
        (tester) async {
      final c = await freshController();
      installMocks();
      await tester.pumpWidget(wrapScreen(c));
      await settle(tester);
      await startRun(tester);

      push({
        'type': 'step_started', 'ts': 0, 'stepId': 'turn-1', 'index': 1,
      });
      // ★ 只推到缓冲里，**不给它 flush 的机会** —— 模拟"用户恰好在
      //   一次帧窗口中间切走"
      push({
        'type': 'step_delta', 'ts': 1, 'stepId': 'turn-1', 'delta': '旧会话残留',
      });

      // 换上下文（新建会话路径 —— 它会调 _switchContext）
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await settle(tester);
      await tester.tap(find.text('新会话').first);
      await settle(tester);

      // 现在再推进时钟：残留的缓冲若没被清，会被 flush 出来
      await settle(tester);
      expect(find.textContaining('旧会话残留'), findsNothing,
          reason: '切会话后旧缓冲必须清掉 —— 否则上一个会话的字会串进新会话');

      await release(tester);
    });
  });
}
