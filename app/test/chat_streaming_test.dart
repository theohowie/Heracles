import 'dart:async';

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
import 'package:heracles/theme/cupertino_kit.dart' show AppIcons;
import 'package:heracles/widgets/bw_topbar.dart' show PlainToolLine;
import 'package:heracles/widgets/message_row.dart';
import 'package:heracles/widgets/stream_step.dart';

import 'support/secure_storage_mock.dart';

/// **会话区实时渲染的测试**（2026-10-10 流式，t3）。
///
/// ## 它防的是什么
///
/// 用户的原话：
/// > "我发送消息，但是很长一段时间没有反应，
/// >  只有在回答完我的问题后才可以看到全部输出结果"
///
/// 修完之后**最怕的回归**是：事件流悄悄断了，界面又变回"跑完才显示"。
/// 那种回归不会报错、不会崩 —— 只是用户又开始干等。
///
/// ## ★★ mock 基建重接（2026-10-25，mock 回家第二批）
///
/// 旧夹具 mock 的是**已删除的传输**：`heracles/command` 的
/// `runAgent` / `listSessions` / `loadMessages` + `EventChannel('heracles/events')`
/// 的 `sink.success`。内核迁到进程内 Dart 后（见 `agent_bridge.dart` 顶部注释，
/// 2026-10-22）那条传输在 `app/lib` 里**零构造** ⇒ mock 永远不被调用、
/// 事件永远不出现 —— 表现就是这个文件**整份挂死**（本机实测：第 1 条用例
/// 10 分钟 `TimeoutException`，且**不是** `errno 10013`）。
///
/// 现在的形状（与生产同一条事件路径）：
/// · `AgentBridge.executorFactoryForTest` 注入 [_FakeExecutor] —— 它的
///   `run()` 返回本地流 + 可控 Future，事件经
///   `handle.events → AgentBridge.emitLocalEvent → UI`（生产同路）；
/// · 会话/消息走 `heracles/device` 的 `fs.*`（`SessionStore` 的真通道）；
/// · 工作区登记表仍在 `heracles/command`（登记表在 Kotlin，至今未变）。
///
/// **测试体与断言零改动**（除 finder 随 UI 改版换过，见下）。
///
/// ## ★ 顺手修掉的两类"过期 finder"（UI 改版，不是本文件要测的行为）
///
/// 1. 输入条已换成 `CupertinoTextField.borderless`（原型 01）⇒
///    `find.byType(TextField)` 找不到控件，改 `CupertinoTextField`；
/// 2. 回答操作行已 Cupertino 化 ⇒ `Icons.copy_rounded` 等 5 个 Material
///    finder 换成 `AppIcons.*`（**只换 finder，断言未动**）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 安全存储通道 mock（坑 36）：没有它，任何 `SettingsController.load()`
  //   的用例都会**永久挂死**（那个 await 的 Future 永不完成）。
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

  /// 推一条事件到 UI（等价旧 `sink.success`，事件形状仍按 Map 描述）。
  ///
  /// ⚠️ 声明必须在 [installMocks] **之前**：那个函数体内的闭包会引用它
  /// （Dart 的局部变量不能先引用后声明）。
  Future<void> Function(Map<String, dynamic>)? pushRef;

  /// 挂 mock 平台端：[onScript] 在假执行器 `run()` 被调用时执行 ——
  /// 用来**在结果返回前**推事件，从而证明"边跑边显示"而不是"跑完才显示"。
  ///
  /// [closeEvents]=false：run 收尾时**不关事件流** —— 只有那一条
  /// 「运行结束后订阅被取消」的用例需要它（否则关流本身就会触发
  /// `onCancel`，断言变成空话）。
  void installMocks({
    required Future<void> Function() onScript,
    bool closeEvents = true,
    void Function()? onEventsCancelled,
  }) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // ---- 工作区登记表（heracles/command —— 这条至今是 Kotlin 的）----
    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'listWorkspaces':
          return [workspaceMap];
        default:
          return null;
      }
    });

    // ---- 会话存储（heracles/device 的 fs.* —— SessionStore 的真通道）----
    //
    // 本文件不考察读写会话，只要求**通道活着且返回合法形状**：
    // 索引为空数组 ⇒ 侧边栏没有会话；消息为空 ⇒ 没有历史。
    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      final path = args['path'] as String? ?? '';
      switch (call.method) {
        case 'fs.stat':
          return <String, dynamic>{'ok': true, 'exists': false};
        case 'fs.readText':
          // 索引（空数组）/ 会话文件（空文本）都当"还没有内容"
          return <String, dynamic>{
            'ok': true,
            'text': path.endsWith('sessions.json') ? '[]' : '',
            'truncated': false,
          };
        case 'fs.readTailLines':
          return <String, dynamic>{'ok': true, 'lines': <String>[]};
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
        onScript: onScript,
        closeEvents: closeEvents,
        onEventsCancelled: onEventsCancelled,
        onReady: (push) => pushRef = push,
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
    messenger.setMockMethodCallHandler(deviceChannel, null);
    AgentBridge.executorFactoryForTest = null;
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
      // ★ 2026-10-25：HProgress 的转圈已 Cupertino 化（旧 Material
      //   `CircularProgressIndicator` ⇒ `CupertinoActivityIndicator`，
      //   见 message_row.dart 的 `_progress`）—— **只换 finder，断言未动**。
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
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
      // ★ 2026-10-25：图标随 Cupertino 化换过（旧 Material
      //   `Icons.copy_rounded` 等）—— **只换 finder，断言未动**。
      expect(find.byIcon(AppIcons.copy), findsOneWidget, reason: '复制');
      expect(find.byIcon(AppIcons.thumbUpOutline), findsOneWidget,
          reason: '点赞');
      expect(find.byIcon(AppIcons.thumbDownOutline), findsOneWidget,
          reason: '点踩');
      // ★ 2026-10-27：`AppIcons.branch` 已退役（frontend 12f5bfd 把它换成
      //   自绘的 `GitBranchIcon`(CustomPaint) —— 原 arrowshape_turn_up_right
      //   与分享箭头分不清）。**`find.byIcon` 对 CustomPaint 无效**，
      //   改用 Tooltip 文案定位：它是 `_act()` 唯一的可辨识标识，
      //   且与图标实现解耦（将来再换图标也不用改这条）。
      //   断言强度不变：仍是「这个按钮存在且唯一」。
      expect(find.byTooltip('新会话分支'), findsOneWidget,
          reason: '新会话分支');
      expect(find.byIcon(AppIcons.usage), findsOneWidget,
          reason: '本次用量');
      expect(find.text('14:32'), findsOneWidget, reason: '时间');

      // 点赞 / 点踩 / 分支都能回传
      await tester.tap(find.byIcon(AppIcons.thumbUpOutline));
      await tester.pump();
      expect(up, 1, reason: '点赞要回调');
      await tester.tap(find.byIcon(AppIcons.thumbDownOutline));
      await tester.pump();
      expect(down, 1, reason: '点踩要回调');
      await tester.tap(find.byTooltip('新会话分支'));
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

      // ★ 2026-10-25：把回执的计时器**放干净**再收尾 —— 否则 flutter_test
      //   会判 "A Timer is still pending even after the widget tree was
      //   disposed"（测试收尾问题，不是产品问题：回执已按设计弹出并断言过）。
      //   手法与 `session_guard_test.dart` 收尾 toast 时一致。
      await tester.pump(const Duration(seconds: 3));
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
            // ★ 2026-10-25 夹具修正：`promptTokens` 的语义已于 2026-10-23
            //   改成**整段**（含命中的那部分）—— `hitRate = cached / prompt`
            //   （见 `TurnMetrics.hitRate` 的说明）。要构造 90% 命中，
            //   prompt 必须是 1000（900 命中 + 100 未命中）；
            //   旧夹具的 `cached 90 / prompt 10` 今天会算出 **900%**，
            //   断言会"红得对"（不是产品坏了，是夹具还按旧公式写的）。
            metrics: const TurnMetrics(
              cachedTokens: 900,
              promptTokens: 1000,
              outputTokens: 12,
              wallMs: 1500,
            ),
          ),
        ),
      ));
      await tester.pump();

      // 展开前没有明细
      expect(find.textContaining('不含工具'), findsNothing);

      await tester.tap(find.byIcon(AppIcons.usage));
      await tester.pump();

      // ★ 2026-10-21（BUG-5）：耗时改成**秒级**并标注「模型 / 不含工具」。
      //   1500 ms → "1.5 秒"。毫秒对任务级耗时没有意义，且用户明确要求改秒。
      expect(find.textContaining('模型耗时（不含工具）：1.5 秒'), findsOneWidget,
          reason: '用量面板要显示本轮**模型**耗时（秒级，不含工具）');
      // ★ 2026-10-27（frontend dc55842 产品变更）：用量面板**不再显示命中率**
      //   （用户拍板：命中率只看顶栏累计，避免"单轮 94% vs 累计 96%"打架），
      //   改为显示**本轮总用量**（prompt + output，K/M 格式）。
      //   ⇒ 断言随口径搬移，但强度不减：仍然钉住"这一轮的 token 数真的是
      //     1000 + 12 = 1012 并渲染出来"，而不是只看有没有那行字。
      expect(find.textContaining('本轮用量：1K tokens'), findsOneWidget,
          reason: '本轮用量 = prompt 1000 + output 12 = 1012 → 1K（K/M 格式）');
      // 反向断言：命中率行**必须已经不存在**（防止将来又被加回来打架）
      expect(find.textContaining('本轮缓存命中'), findsNothing,
          reason: '命中率只归顶栏累计，面板里不许再出现单轮命中率');
    });

    // ★ 2026-10-27 改写（frontend dc55842 把命中率行从面板移除了）。
    //
    // 原用例测的是「cachedTokens == null 时不写 0%」—— 那个对象已经不存在：
    // 面板现在只显示**本轮总用量**（prompt + output），不再有命中率行。
    //
    // 但**原意必须保住**：「没数就是没数，不许编造一个 0」这条契约 §3.4 的
    // 纪律仍然适用，只是触发条件变成 `prompt + output == 0`。
    // 所以这里改成构造真正会走"未上报"分支的输入（两个数都是 0），
    // 并额外加一条反向断言：**不许出现 "0 tokens"**（那正是"编造 0"）。
    testWidgets('★★ 本轮用量为 0 时不写「0 tokens」（没数≠0，契约 §3.4）',
        (tester) async {
      final c = await freshController();
      await tester.pumpWidget(wrap(
        c,
        Scaffold(
          body: MessageRow(
            message: const HAssistantMessage(id: 'a3', text: '回答'),
            metrics: const TurnMetrics(
              cachedTokens: null, // 未上报
              promptTokens: 0,
              outputTokens: 0,
              wallMs: 200,
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(AppIcons.usage));
      await tester.pump();

      expect(find.textContaining('本轮用量：本次未上报'), findsOneWidget,
          reason: '总 token 为 0 时要如实说"未上报"');
      // ⚠️ 这条守住原意：不许编造一个 "0 tokens" 冒充有数据
      expect(find.textContaining('本轮用量：0 tokens'), findsNothing,
          reason: '没数就是没数 —— 写 0 tokens 是编造');
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
            // ★ 2026-10-25 夹具修正（同「本次用量」那条）：prompt 是**整段**，
            //   要 90% 命中就得是 900/1000（旧夹具 90/10 今天算 900%）。
            metrics: const TurnMetrics(
              cachedTokens: 900,
              promptTokens: 1000,
              outputTokens: 5,
              wallMs: 900,
            ),
          ),
        ),
      ));
      await tester.pump();

      // 旧版的胶囊文案形如「命中 90%」——用户要求跑完不要再显示
      // （单轮命中率只在"本次用量"展开里，且带「本轮」口径标签）。
      expect(find.textContaining('命中 90%'), findsNothing,
          reason: '2026-10-13：单轮命中率不再显示在消息外'
              '（会话平均命中率在半抽屉的「缓存命中」页）');
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

    // 假执行器：先推事件，再卡住不返回 ——
    // 这样"事件已经渲染出来"就**只能**是实时路径的功劳
    final gate = Completer<void>();

    installMocks(onScript: () async {
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

    // 发一条消息（输入条 = CupertinoTextField，原型 01 起）
    final field = find.byType(CupertinoTextField);
    expect(field, findsOneWidget);
    await tester.enterText(field.first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // ★ 此刻 run 仍被 gate 卡住，但界面已经有工具卡片了
    //
    // ★ 2026-10-25：卡片标题随工具面整改换过 —— 旧文案是
    //   `friendlyToolName` 的「正在修改文件代码」，今天运行中的标题来自
    //   `toolCallLabel`（`toolVerbs`）：「正在写入 <目标>」
    //   （见 tool_call_card.dart）。**只换文案 finder，断言（"不等 run 返回
    //   就必须画出来"）未动**。
    expect(find.text('正在写入 a.txt'), findsOneWidget,
        reason: 'ToolStarted 必须立刻渲染，不能等 run() 返回');

    // 放行，让 await 返回
    gate.complete();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('★ 实时画过的工具卡片不会被 run() 的兜底路径再插一次',
      (tester) async {
    final c = await freshController();

    installMocks(onScript: () async {
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

    await tester.enterText(find.byType(CupertinoTextField).first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // run() 的 turns 里也有同一个 write_file —— 但**只能有一张卡片**
    // ★ 2026-10-25：标题文案换成 `toolCallLabel` 的完成态「写入了 <目标>」
    //   （旧的是 friendlyToolName 的「修改文件代码」）；断言意图未动。
    expect(find.text('写入了 a.txt'), findsOneWidget,
        reason: '实时路径与兜底路径必须去重，不能出现两张同样的卡片');
    // ★ 2026-10-25：`find.text('已写入')`（工具结果正文）今天**默认看不见**，
    //   而且工具调用**不再用 `ToolCallCard` 渲染**了 —— 2026-10-24 黑白改版
    //   起是**纯文字行** `PlainToolLine`（`message_row._toolLine`），
    //   按「步骤详略」设置默认折叠 `detailLines`（结果在里面）。
    //   所以改成两条**等价且更精确**的断言：
    //   ① 那条（唯一的）工具行**拿着**实时结果（不只是"屏幕上出现了这三个字"）；
    //   ② 用户点开它就能看到结果 —— 折叠 ≠ 丢数据。
    final lines = tester
        .widgetList<PlainToolLine>(find.byType(PlainToolLine))
        .toList();
    expect(lines, hasLength(1),
        reason: '实时路径与兜底路径共用同一条工具行（去重）');
    expect(lines.single.detailLines, contains('已写入'),
        reason: '实时那条行必须带着 run() 的最终结果 —— 结果不能丢');

    await tester.tap(find.byType(PlainToolLine));
    await tester.pump();
    expect(find.textContaining('已写入'), findsWidgets,
        reason: '点开工具行必须能看到结果（折叠 ≠ 丢）');

    expect(find.text('最终回答内容'), findsOneWidget);
  });

  testWidgets('★ 事件流完全没起来时，run() 的兜底路径仍能补齐结果',
      (tester) async {
    final c = await freshController();

    // 一个事件都不推 —— 模拟事件流失效（生产里是"流丢了"）
    installMocks(onScript: () async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(CupertinoTextField).first, '写个文件');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // 结果不能丢 —— 这是"流式是增强、不是数据通路"的保障
    // ★ 2026-10-25：同上，标题文案换成完成态「写入了 <目标>」。
    expect(find.text('写入了 a.txt'), findsOneWidget);
    expect(find.text('最终回答内容'), findsOneWidget);
  });

  testWidgets('★ 运行结束后订阅被取消（不泄漏，且不影响后续）', (tester) async {
    final c = await freshController();

    // ★ 2026-10-25 等价物：旧断言读的是 EventChannel mock 的
    //   `onCancel`（`sink == null`）——事件流已不在平台上，等价判据是
    //   **假执行器的事件流订阅被摘掉**（`StreamController.broadcast` 的
    //   `onCancel`）。为此这条用例**不关流**：否则关流本身就会触发 onCancel，
    //   断言就成了空话（那正是在这里要避免的"假绿"）。
    var eventsCancelled = false;
    installMocks(
      onScript: () async {},
      closeEvents: false,
      onEventsCancelled: () => eventsCancelled = true,
    );

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    await tester.enterText(find.byType(CupertinoTextField).first, '你好');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    // run 结束后 finally 已取消订阅 —— 否则事件流一直持着 UI 的监听器
    expect(eventsCancelled, isTrue,
        reason: 'run 结束后必须取消事件订阅，否则流一直持有监听器（泄漏）');
  });

  testWidgets('Blocked 事件渲染为「已拦截，未执行」，不是工具失败',
      (tester) async {
    final c = await freshController();

    installMocks(onScript: () async {
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

    await tester.enterText(find.byType(CupertinoTextField).first, '写个文件');
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
    required this.onScript,
    required this.onReady,
    this.closeEvents = true,
    this.onEventsCancelled,
  });

  final Future<void> Function() onScript;
  final void Function(Future<void> Function(Map<String, dynamic>) push) onReady;

  /// run 收尾时是否关掉事件流（与生产同形）。唯一例外见
  /// 「运行结束后订阅被取消」那条用例。
  final bool closeEvents;

  /// 事件流订阅被取消时回调（等价旧 EventChannel mock 的 `onCancel`）。
  final void Function()? onEventsCancelled;

  @override
  Future<LocalRunHandle> run({
    required String request,
    String? sessionId,
    List<HAttachment> attachments = const [],
  }) async {
    final controller = StreamController<AgentEvent>.broadcast(
      onCancel: onEventsCancelled == null ? null : () => onEventsCancelled!(),
    );
    final done = Completer<AgentRunResult>();
    onReady((m) async {
      if (!controller.isClosed) controller.add(AgentEvent.fromMap(m));
      await Future<void>.delayed(Duration.zero);
    });

    // 脚本在句柄返回后的一拍再跑 —— 保证 AgentBridge 已挂上订阅
    //（广播流不缓冲，早推会丢）。
    unawaited(Future<void>(() async {
      await onScript();
      if (closeEvents && !controller.isClosed) {
        unawaited(controller.close());
      }
      if (!done.isCompleted) done.complete(_cannedResult());
    }));

    return LocalRunHandle(
      events: controller.stream,
      result: done.future,
      cancel: () async => true,
    );
  }

  /// 旧 Kotlin mock 的罐头返回值（形状对齐 AgentRunResult）。
  static AgentRunResult _cannedResult() => AgentRunResult(
        stopReason: '已给出最终回答',
        finalText: '最终回答内容',
        sessionId: 'sess-A',
        totalCachedTokens: 0,
        totalPromptTokens: 0,
        totalOutputTokens: 0,
        turns: [
          AgentTurn(
            index: 1,
            verdict: '工具成功',
            tool: 'write_file',
            args: const {'path': 'a.txt'},
            result: '已写入',
            wallMs: 3,
            cachedTokens: null,
            promptTokens: 10,
            outputTokens: 5,
            toolState: ToolState.succeeded,
          ),
          AgentTurn(
            index: 2,
            verdict: '最终回答',
            wallMs: 5,
            cachedTokens: null,
            promptTokens: 12,
            outputTokens: 6,
          ),
        ],
      );
}