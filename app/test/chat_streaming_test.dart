import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/message_row.dart';
import 'package:heracles/widgets/stream_step.dart';

/// **会话区实时渲染的测试**（2026-10-10 流式，t3）。
///
/// ## 它防的是什么
///
/// 用户的原话：
/// > "我发送消息，但是很长一段时间没有反应，
/// >  只有在回答完我的问题后才可以看到全部输出结果"
///
/// 修完之后**最怕的回归**是：事件通道悄悄断了，界面又变回"跑完才显示"。
/// 那种回归不会报错、不会崩 —— 只是用户又开始干等。
/// 所以这里用 mock 平台通道，把"事件到达 → 界面立刻变化"这条链路钉死：
/// 推送 `ToolStarted` 之后**在 run 还没返回时**就断言卡片已经出现。
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

  /// 挂 mock 平台端。
  ///
  /// [runAgentPushes] 在 `runAgent` 被调用时执行 —— 用来**在 await 返回前**
  /// 推事件，从而证明"边跑边显示"而不是"跑完才显示"。
  Future<void> Function(Map<String, dynamic>)? pushRef;

  MockStreamHandlerEventSink? sink;

  void installMocks({
    required Future<void> Function() onRunAgent,
  }) {
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
        case 'runAgent':
          await onRunAgent();
          return <String, dynamic>{
            'stopReason': '已给出最终回答',
            'finalText': '最终回答内容',
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
              },
              {
                'index': 2,
                'verdict': '最终回答',
                'tool': null,
                'args': null,
                'result': null,
                'wallMs': 5,
                'cachedTokens': null,
                'promptTokens': 12,
                'outputTokens': 6,
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
          pushRef = (Map<String, dynamic> e) async {
            sink!.success(e);
            // 让事件穿过 messenger 到达 Dart 的 listen
            await Future<void>.delayed(Duration.zero);
          };
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

  Widget wrap(SettingsController c, Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      );

  /// 反复 pump，等异步桥接往返完成（不用 pumpAndSettle：
  /// busy 态的转圈动画会让它永远不 settle）
  Future<void> settle(WidgetTester tester, {int times = 8}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
    sink = null;
    pushRef = null;
  });

  // ==================================================================
  // 1. 三个新消息类型的渲染（纯 widget，不依赖通道）
  // ==================================================================

  group('新消息类型渲染', () {
    testWidgets('HProgress 显示「正在生成…」', (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HProgress(id: 'p1', label: '正在生成…（第 2 轮）'),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('正在生成…（第 2 轮）'), findsOneWidget);
      // 转圈指示 —— 让用户知道"在动"，不是卡死
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('★ HBlocked 显示「已拦截，未执行」而不是工具失败', (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HBlocked(
              id: 'b1',
              reason: '校验失败：出现未知参数：bogus',
              tool: 'write_file',
              index: 1,
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('已拦截，未执行'), findsOneWidget);
      expect(find.text('修改文件代码'), findsOneWidget);
      expect(find.textContaining('校验失败'), findsOneWidget);
      // ★ 关键：**不能**出现"失败"字样 —— 那会误导用户以为工具坏了
      expect(find.textContaining('工具失败'), findsNothing);
    });

    testWidgets('★ HBlocked 的 tool 为 null 时不崩溃（Unparseable 分支）',
        (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HBlocked(
              id: 'b2',
              reason: '输出无法解析：不是合法 JSON',
              // tool 为 null —— 连调用都没解析出来
            ),
          ),
        ),
      ));
      await tester.pump();

      // ★ 2026-10-13 改：`tool == null` **不是拦截**（没有工具被挡下），
      //   而是模型输出格式不对 —— 文案必须与真拦截分开，
      //   否则用户以为有个工具被安全机制拦了（语义错误）。
      expect(find.text('输出无法解析'), findsOneWidget,
          reason: 'tool==null = 格式错误，不是"拦截"');
      expect(find.text('已拦截，未执行'), findsNothing,
          reason: '这里没有任何东西被拦截，不能借用拦截的文案');
      expect(find.textContaining('格式不对'), findsOneWidget,
          reason: '要给人话解释（系统做了什么），不是解析器的技术细节');
      // 不该画出一张空的工具卡片
      expect(find.text('修改文件代码'), findsNothing);
    });

    testWidgets('HRawOutput 显示模型原始输出', (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HRawOutput(
              id: 'r1',
              index: 1,
              raw: '{"tool":"write_file","args":{"path":"a.txt"}}',
              wallMs: 1234,
            ),
          ),
        ),
      ));
      await tester.pump();

      // ⚠️ 2026-10-12（S5）改：原先断言 `find.text('模型原始输出')`
      //    + `find.textContaining('第 1 轮')`。而**工具调用卡片自身**
      //    在「完全展开」档也有一个「模型原始输出」标题（见
      //    `tool_call_card.dart`），并且本次给工具卡片加了「第 1 轮」
      //    的位置标签（流式步骤卡需要标出"这是第几轮"）。
      //
      //    ⇒ 只要正文里出现**这个组合**（= 原始输出体 + 轮次前缀），
      //      本用例的意图（"原话被原样渲染出来"）就成立，
      //      且不会因为别处多一个同名标题而假失败。
      expect(
        find.textContaining('{"tool":"write_file","args":{"path":"a.txt"}}'),
        findsOneWidget,
      );
      expect(find.textContaining('第 1 轮'), findsOneWidget);
    });
  });

  // ==================================================================
  // ★ 回答末尾的操作行（2026-10-13 用户要求）
  //   复制 · 点赞 · 点踩 · 新会话分支 · 本次用量 · 时间
  // ==================================================================

  group('★ 回答末尾操作行', () {
    testWidgets('★★ 助手回答下方有操作行（复制/赞/踩/分支/用量/时间）',
        (tester) async {
      final c = await freshController();
      var up = 0, down = 0, branch = 0;
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HAssistantMessage(id: 'a1', text: '这是回答'),
            timestamp: DateTime(2026, 10, 13, 14, 32),
            onFeedback: (f) {
              if (f == AnswerFeedback.up) up++;
              if (f == AnswerFeedback.down) down++;
            },
            onBranch: () => branch++,
            metrics: const TurnMetrics(
              cachedTokens: 90,
              promptTokens: 10,
              outputTokens: 12,
              wallMs: 1500,
            ),
          ),
        ),
      ));
      await tester.pump();

      // 六个元素都在（时间用文本，其余用图标）
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget, reason: '复制');
      expect(find.byIcon(Icons.thumb_up_alt_outlined), findsOneWidget,
          reason: '点赞');
      expect(find.byIcon(Icons.thumb_down_alt_outlined), findsOneWidget,
          reason: '点踩');
      expect(find.byIcon(Icons.call_split_rounded), findsOneWidget,
          reason: '新会话分支');
      expect(find.byIcon(Icons.data_usage_rounded), findsOneWidget,
          reason: '本次用量');
      expect(find.text('14:32'), findsOneWidget, reason: '时间');

      // 点赞 / 点踩 / 分支都能回传
      await tester.tap(find.byIcon(Icons.thumb_up_alt_outlined));
      await tester.pump();
      expect(up, 1, reason: '点赞要回调');
      await tester.tap(find.byIcon(Icons.thumb_down_alt_outlined));
      await tester.pump();
      expect(down, 1, reason: '点踩要回调');
      await tester.tap(find.byIcon(Icons.call_split_rounded));
      await tester.pump();
      expect(branch, 1, reason: '分支要回调');
    });

    // ==================================================================
    // ★ 长按用户消息：复制 / 编辑重发（2026-10-13，DeepSeek 移动端同款）
    // ==================================================================

    testWidgets('★★ 长按用户消息 → 菜单（复制/编辑重发）→ 复制回执',
        (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HUserMessage(id: 'u1', text: '帮我创建登录页'),
          ),
        ),
      ));
      await tester.pump();

      // 长按 → 底部菜单弹出
      await tester.longPress(find.text('帮我创建登录页'));
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget,
          reason: '长按消息必须能复制 —— DeepSeek 移动端同款');
      expect(find.text('编辑重发'), findsNothing,
          reason: '没传 onEdit 回调时不显示编辑（上层决定开放程度）');

      // 点复制 → 回执
      await tester.tap(find.text('复制'));
      // ⚠️ 只 pump 两帧：SnackBar 显示 1 秒，`pumpAndSettle` 会把
      //    它的计时器推到结束 → 回执已消失，断言必然假失败。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('已复制'), findsOneWidget,
          reason: '复制是"看不见结果"的操作，必须有回执');
    });

    testWidgets('★★ 长按 → 编辑重发 → onEdit 回传原文', (tester) async {
      final c = await freshController();
      String? edited;
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HUserMessage(id: 'u2', text: '帮我创建登录页'),
            onEdit: (t) => edited = t,
          ),
        ),
      ));
      await tester.pump();

      await tester.longPress(find.text('帮我创建登录页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑重发'));
      await tester.pumpAndSettle();

      expect(edited, '帮我创建登录页',
          reason: '编辑重发 = 原文放回输入框（上层写控制器），'
              '用户改完自己点发送 —— 不做历史改写（append-only）');
    });

    testWidgets('★ 点「本次用量」展开这一轮的 token/耗时明细', (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HAssistantMessage(id: 'a2', text: '回答'),
            metrics: const TurnMetrics(
              cachedTokens: 90,
              promptTokens: 10,
              outputTokens: 12,
              wallMs: 1500,
            ),
          ),
        ),
      ));
      await tester.pump();

      // 展开前没有明细
      expect(find.textContaining('耗时：1500 ms'), findsNothing);

      await tester.tap(find.byIcon(Icons.data_usage_rounded));
      await tester.pump();

      expect(find.textContaining('耗时：1500 ms'), findsOneWidget,
          reason: '用量面板要显示本轮耗时');
      expect(find.textContaining('缓存命中：90%'), findsOneWidget,
          reason: '本轮命中率 = 90/(90+10)');
    });

    testWidgets('★★ 未上报缓存时不写 0%（null ≠ 0，契约 §3.4）', (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HAssistantMessage(id: 'a3', text: '回答'),
            metrics: const TurnMetrics(
              cachedTokens: null, // 未上报
              promptTokens: 100,
              outputTokens: 5,
              wallMs: 200,
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.data_usage_rounded));
      await tester.pump();

      expect(find.textContaining('本次未上报'), findsOneWidget,
          reason: '未上报要如实说"未上报"');
      expect(find.textContaining('0%'), findsNothing,
          reason: 'null 不是 0 —— 写 0% 会让用户以为缓存坏了');
    });

    testWidgets('★★ 单轮『命中 xx%』胶囊已移除（会话平均看右上角）',
        (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HAssistantMessage(id: 'a4', text: '回答'),
            metrics: const TurnMetrics(
              cachedTokens: 90,
              promptTokens: 10,
              outputTokens: 5,
              wallMs: 900,
            ),
          ),
        ),
      ));
      await tester.pump();

      // 旧版的胶囊文案形如「命中 90%」——用户要求跑完不要再显示
      expect(find.textContaining('命中 90%'), findsNothing,
          reason: '2026-10-13：单轮命中率不再显示，'
              '会话平均命中率看标题栏指示器');
    });
  });

  // ==================================================================
  // 2. 浅色 / 深色下都必须可读（不能用硬编码颜色）
  // ==================================================================

  group('主题适配', () {
    for (final dark in [true, false]) {
      testWidgets('HBlocked 在 ${dark ? '深色' : '浅色'} 下渲染正常', (tester) async {
        final hue = Hue.forDark(dark, 0xFFFF7A45);
        await tester.pumpWidget(MaterialApp(
          theme: buildHeraclesTheme(dark: dark),
          builder: (context, inner) => HueScope(
            hue: hue,
            child: inner ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: MessageRow(
              // ★ 明确带上 tool（真拦截 = 有工具被挡下）——
              //   tool==null 走的是"格式错误"文案（见上方那条测试）
              message: const HBlocked(
                  id: 'b', reason: '重复调用已拦截', tool: 'write_file'),
            ),
          ),
        ));
        await tester.pump();

        expect(find.text('已拦截，未执行'), findsOneWidget);
        // 文案颜色必须来自语义色，而不是写死的色值
        final warn = HColors.warnOn(dark);
        final textWidget = tester.widget<Text>(find.text('已拦截，未执行'));
        expect(textWidget.style?.color, warn);
      });
    }
  });

  // ==================================================================
  // 3. ★ 端到端：事件在 run() 返回【之前】就渲染出来
  // ==================================================================

  testWidgets('★ ToolStarted 到达时立刻出现 pending 卡片（不等 run 返回）',
      (tester) async {
    final c = await freshController();

    // runAgent 被调用后：先推事件，再卡住不返回 ——
    // 这样"事件已经渲染出来"就**只能**是实时路径的功劳
    final gate = Completer<void>();

    installMocks(onRunAgent: () async {
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
      await pushRef!({
        'type': 'tool_started',
        'ts': 2,
        'index': 1,
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
      });
      // run 还没返回
      await gate.future;
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    // 发一条消息
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    await tester.enterText(field.first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // ★ 此刻 runAgent 仍被 gate 卡住，但界面已经有工具卡片了
    //   运行中的标题是「正在…」形态（2026-10-13 人话标题）
    expect(find.text('正在修改文件代码'), findsOneWidget,
        reason: 'ToolStarted 必须立刻渲染，不能等 run() 返回');

    // 放行，让 await 返回
    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('★ 实时画过的工具卡片不会被 run() 的兜底路径再插一次',
      (tester) async {
    final c = await freshController();

    installMocks(onRunAgent: () async {
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
      await pushRef!({
        'type': 'tool_started',
        'ts': 2,
        'index': 1,
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
      });
      await pushRef!({
        'type': 'tool_finished',
        'ts': 3,
        'index': 1,
        'tool': 'write_file',
        'args': {'path': 'a.txt'},
        'result': '已写入',
        'ok': true,
        'wallMs': 3,
      });
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // run() 的 turns 里也有同一个 write_file —— 但**只能有一张卡片**
    expect(find.text('修改文件代码'), findsOneWidget,
        reason: '实时路径与兜底路径必须去重，不能出现两张同样的卡片');
    expect(find.text('已写入'), findsWidgets);
    expect(find.text('最终回答内容'), findsOneWidget);
  });

  testWidgets('★ 事件流完全没起来时，run() 的兜底路径仍能补齐结果',
      (tester) async {
    final c = await freshController();

    // 一个事件都不推 —— 模拟 EventChannel 失效
    installMocks(onRunAgent: () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // 结果不能丢 —— 这是"流式是增强、不是数据通路"的保障
    expect(find.text('修改文件代码'), findsOneWidget);
    expect(find.text('最终回答内容'), findsOneWidget);
  });

  testWidgets('★ 运行结束后订阅被取消（不泄漏，且不影响后续）', (tester) async {
    final c = await freshController();

    installMocks(onRunAgent: () async {
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '你好');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // 运行结束后 _stopLive / finally 已取消订阅 —— mock 侧的 onCancel 被调用
    expect(sink, isNull, reason: 'run 结束后必须取消订阅，否则平台侧一直持有 sink');
  });

  testWidgets('Blocked 事件渲染为「已拦截，未执行」，不是工具失败', (tester) async {
    final c = await freshController();

    installMocks(onRunAgent: () async {
      await pushRef!({'type': 'turn_started', 'ts': 1, 'index': 1});
      await pushRef!({
        'type': 'blocked',
        'ts': 2,
        'index': 1,
        'reason': '校验失败：出现未知参数：bogus',
        'tool': 'write_file',
      });
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('已拦截，未执行'), findsOneWidget);
    expect(find.textContaining('未知参数'), findsOneWidget);
  });

  // ==================================================================
  // ★ 协议剥壳 stripProtocolShell（2026-10-13，用户截图暴露的渲染缺陷）
  //
  // 用户的问题（原话）：「我想知道工作步骤里面，{}里面的输出是
  // 表示什么，是任务过程还是模型思考过程，如果把思考过程收起，
  // 这个是应该给用户看还是不应该」
  //
  // 答案：`{}` 是**模型的输出协议**（`{"final":…}` / `{"tool":…}`），
  // 给 AgentLoop 解析用的 —— **不应该给用户看**。流式期间裸渲染
  // 是设计（要逐字快），但 StepEnded 后必须剥壳。
  // ==================================================================

  group('★ 协议剥壳 stripProtocolShell', () {
    test('★★ {"final":"X"} → X（剥掉协议外壳）', () {
      expect(
        stripProtocolShell('{"final":"我是 Heracles"}'),
        '我是 Heracles',
        reason: '用户该看到的是回答内容，不是 JSON 包装',
      );
    });

    test('★ {"tool":…} → 空串（工具调用有自己的卡片，正文区不重复）', () {
      expect(
        stripProtocolShell('{"tool":"write_file","args":{"path":"a.txt"}}'),
        '',
        reason: '工具调用的展示由 ToolStarted/ToolFinished 卡片负责',
      );
    });

    test('★ 纯文本（非 JSON）→ 原样（本来就是人话）', () {
      expect(stripProtocolShell('正在分析项目结构'), '正在分析项目结构');
    });

    test('★★ 非法 JSON（截断的半截输出）→ 原文（剥壳失败不丢内容）', () {
      final broken = '{"final":"我是 Heracles';
      expect(
        stripProtocolShell(broken),
        broken,
        reason: '诚实优先：看到原始协议好过看到空白 —— 内容绝不能丢',
      );
    });

    test('★ 未知协议形态 → 原文（不猜）', () {
      final unknown = '{"something":"else"}';
      expect(stripProtocolShell(unknown), unknown);
    });

    test('★ final 内容含引号/花括号 → 原样保留（JSON 解析健壮性）', () {
      expect(
        stripProtocolShell('{"final":"他说:\\"用 {} 包裹\\""}'),
        '他说:"用 {} 包裹"',
      );
    });
  });

  // ==================================================================
  // ★ 流式中工具调用的掩蔽（2026-10-13，用户截图暴露）
  //
  // 用户原话：「生成的代码片段是直接展示到工作步骤里了，
  // 应该是直接显示：正在修改文件代码」——
  // 模型输出 {"tool":"write_file","args":{"content":"<!DOCTYPE html>…
  // 时，几千字符的文件内容原样滚屏。
  // ==================================================================

  group('★ 流式工具调用掩蔽 _isStreamingToolCall', () {
    test('★★ {"tool" 开头 = 工具调用形态', () {
      expect(
        StreamStepView.isStreamingToolCallStatic(
            '{"tool":"write_file","args":{"content":"<!DOCTYPE html>'
            '${'x' * 500}'),
        isTrue,
        reason: '一旦认出是工具调用，后续文件内容全部掩蔽');
    });

    test('★ 宽松前缀：chunk 拆开 {"tool 也认得出', () {
      for (final partial in ['{"', '{"t', '{"to', '{"too', '{"tool', '{"tool"']) {
        expect(
          StreamStepView.isStreamingToolCallStatic(partial),
          isTrue,
          reason: 'chunk 边界可能拆开前缀 —— 宁可早一拍掩蔽，不可晚一拍滚屏',
        );
      }
    });

    test('★ 正常正文/回答不误伤', () {
      expect(StreamStepView.isStreamingToolCallStatic(''), isFalse);
      expect(StreamStepView.isStreamingToolCallStatic('{'), isFalse,
          reason: '单字符 { 还看不出形态 —— 不掩蔽');
      expect(
        StreamStepView.isStreamingToolCallStatic('正在分析项目结构'),
        isFalse,
      );
      expect(
        StreamStepView.isStreamingToolCallStatic('{"final":"回答"}'),
        isFalse,
        reason: 'final 是回答，正常渲染');
    });
  });
}
