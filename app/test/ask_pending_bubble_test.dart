// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **P0：提问面板"点掉 ≠ 未回答"**（2026-10-30）。
//
// 旧行为（真因）：
// · `chat_screen._showAskDialog` 拿到 null 立刻 `replyAsk(const {})`
//   ⇒ 用户只是收起面板，模型却被告知"全部未回答"；
// · `bw_approval.showAskGateSheet` 的选中项 / 「其他…」自填都是弹层局部
//   状态 ⇒ 一关就销毁，重新打开全丢。
//
// 新契约：
// 1) 收起 ⇒ **不 replyAsk**，`_PendingAsk` 保留草稿，输入卡上方出现常驻气泡；
// 2) 点气泡 ⇒ 原样恢复（选中项 + 自填原文 + 当前页）；
// 3) 提交/跳过 ⇒ replyAsk 完整答案，气泡消失；
// 4) 后端 `ask_closed{timeout|aborted}` ⇒ 只清气泡，**前端绝不替后端提交**。
//
// 本文件用**生产同一条路径**（executorFactoryForTest → handle.events →
// emitLocalEvent → ChatScreen）+ 真实 `LocalAskGate.askUser` 驱动。

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/agent_bridge.dart'
    show AgentBridge, AgentEvent, AgentRunResult;
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles_backend/heracles_backend.dart'
    show AskQuestion, AskOption;

import 'support/secure_storage_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  Future<void> Function(AgentEvent)? pushRef;
  final scripts = <Future<void> Function()>[];
  late LocalAskGate gate;
  String? askResultText;

  void installMocks() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      if (call.method == 'listWorkspaces') return [workspaceMap];
      return null;
    });
    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      final path = args['path'] as String? ?? '';
      switch (call.method) {
        case 'fs.stat':
          return <String, dynamic>{'ok': true, 'exists': false};
        case 'fs.readText':
          return <String, dynamic>{
            'ok': true,
            'text': path.endsWith('sessions.json') ? '[]' : '',
            'truncated': false,
          };
        case 'fs.readTailLines':
          return <String, dynamic>{'ok': true, 'lines': <String>[]};
        default:
          return <String, dynamic>{'ok': true};
      }
    });
    AgentBridge.executorFactoryForTest =
        ({required workspacePath, required settings, required sessionStore, askGate}) {
      gate = askGate! as LocalAskGate;
      return _FakeExecutor(
        workspacePath: workspacePath,
        settings: settings,
        sessionStore: sessionStore,
        askGate: askGate,
        nextScript: () => scripts.isNotEmpty ? scripts.removeAt(0) : () async {},
        onReady: (push) => pushRef = push,
      );
    };
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
    AgentBridge.executorFactoryForTest = null;
    pushRef = null;
    scripts.clear();
    askResultText = null;
  });

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

  Future<void> settle(WidgetTester tester, {int times = 12}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installMocks();
    final c = await freshController();
    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);
  }

  Future<void> sendMessage(WidgetTester tester) async {
    await tester.enterText(find.byType(CupertinoTextField).first, '执行任务');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, times: 14);
  }

  /// 让假执行器在第 1 轮里发一个真实 ask（gate.askUser = 生产同一入口），
  /// 并挂住等回答；结果文本由 [askResultText] 收集。
  void scriptAsk(List<AskQuestion> questions) {
    scripts.add(() async {
      gate.attach((e) => unawaited(pushRef!(e)));
      await pushRef!(
          AgentEvent(type: AgentEvent.kTurnStarted, ts: 1, index: 1));
      askResultText = await gate.askUser(questions);
    });
  }

  List<AskQuestion> twoQuestions() => const [
        AskQuestion(
          id: 'q1',
          question: '要选哪个方案？',
          options: [AskOption('方案 A'), AskOption('方案 B')],
        ),
        AskQuestion(
          id: 'q2',
          question: '还要补充吗？',
          multi: true,
          options: [AskOption('继续')],
        ),
      ];

  testWidgets('★★★ 收起不提交 + 常驻气泡 + 重开草稿不丢 + 提交回传完整答案',
      (tester) async {
    scriptAsk(twoQuestions());
    await pumpChat(tester);
    await sendMessage(tester);
    expect(find.text('模型需要你的回答'), findsOneWidget, reason: '前置：提问面板已弹出');

    // 答第 1 题（单选 ⇒ 自动跳第 2 题）
    await tester.tap(find.text('方案 B'));
    await settle(tester);
    expect(find.text('还要补充吗？'), findsOneWidget, reason: '前置：已跳到第 2 题');
    // 第 2 题选「其他…」并填字
    await tester.tap(find.text('其他…'));
    await settle(tester);
    await tester.enterText(
        find.byType(CupertinoTextField).last, '补充说明XYZ');
    await settle(tester);

    // 收起（返回键 → 二次确认 → 收起问题）
    await tester.binding.handlePopRoute();
    await settle(tester);
    await tester.tap(find.text('收起问题'));
    await settle(tester);

    // ① 不许提交：旧实现这里已经 replyAsk({}) ⇒ gate 不再挂起
    expect(gate.hasPendingAsk, isTrue,
        reason: '收起只是"暂时不看"，不许把"未回答"提交给模型');
    // ② 输入卡上方出现常驻气泡
    expect(find.text('等待您的回答'), findsOneWidget,
        reason: '收起后必须留下可见的入口，不能静默');
    expect(find.text('5 分钟内有效'), findsOneWidget);
    expect(askResultText, isNull, reason: '前置：ask 还挂着，没有结果');

    // ③ 点气泡 ⇒ 原样恢复（自填原文还在）
    await tester.tap(find.text('回答'));
    await settle(tester, times: 16);
    expect(find.text('模型需要你的回答'), findsOneWidget);
    expect(find.text('补充说明XYZ'), findsOneWidget,
        reason: '重新打开时「其他…」里打的字必须还在');

    // ④ 提交 ⇒ 完整答案（选中项 + 自填原文）回传
    await tester.tap(find.text('提交'));
    await settle(tester, times: 16);
    expect(askResultText, isNotNull, reason: '提交后 ask 必须解挂');
    expect(askResultText, contains('方案 B'));
    expect(askResultText, contains('补充说明XYZ'));
    expect(find.text('等待您的回答'), findsNothing, reason: '提交后气泡消失');
    expect(gate.hasPendingAsk, isFalse);
  });

  testWidgets('★★ 后端 ask_closed(timeout) ⇒ 气泡消失，且前端不提交假答案',
      (tester) async {
    scriptAsk(const [
      AskQuestion(id: 'q1', question: '继续吗？', options: [AskOption('继续')]),
    ]);
    await pumpChat(tester);
    await sendMessage(tester);
    expect(find.text('模型需要你的回答'), findsOneWidget);

    // 先收起，让气泡出现
    await tester.binding.handlePopRoute();
    await settle(tester);
    await tester.tap(find.text('收起问题'));
    await settle(tester);
    expect(find.text('等待您的回答'), findsOneWidget);

    // 后端判超时（契约：ask_closed{outcome: timeout}）
    AgentBridge.emitLocalEvent(
        AgentEvent(type: AgentEvent.kAskClosed, ts: 2, outcome: 'timeout'));
    await settle(tester, times: 8);

    expect(find.text('等待您的回答'), findsNothing,
        reason: '后端说提问结束了 ⇒ 气泡必须消失');
    expect(find.text('等待超时，已按「未回答」继续'), findsOneWidget,
        reason: '超时要有交代，但**不是**前端提交的"未回答"');
    expect(gate.hasPendingAsk, isTrue,
        reason: '前端不许替后端提交"未回答"—— 语义归后端');

    // 清理：模拟后端按未回答收尾（生产里由 gate 超时分支完成）
    await gate.replyAsk(const {});
    // 排空毛玻璃 toast 的 2.2s 停留计时器，否则测试结束会报 pending timer
    await settle(tester, times: 45);
    await settle(tester);
  });
}

class _FakeExecutor extends LocalAgentExecutor {
  _FakeExecutor({
    required super.workspacePath,
    required super.settings,
    required super.sessionStore,
    required super.askGate,
    required this.nextScript,
    required this.onReady,
  });

  final Future<void> Function() Function() nextScript;
  final void Function(Future<void> Function(AgentEvent)) onReady;

  @override
  Future<LocalRunHandle> run({
    required String request,
    String? sessionId,
    List<dynamic> attachments = const [],
  }) async {
    final controller = StreamController<AgentEvent>.broadcast();
    final done = Completer<AgentRunResult>();
    onReady((e) async {
      if (!controller.isClosed) controller.add(e);
      await Future<void>.delayed(Duration.zero);
    });
    unawaited(Future<void>.delayed(const Duration(milliseconds: 20), () async {
      final script = nextScript();
      await script();
      if (!controller.isClosed) unawaited(controller.close());
      if (!done.isCompleted) {
        done.complete(const AgentRunResult(
          stopReason: '已给出最终回答',
          finalText: '最终回答内容',
          turns: [],
          totalCachedTokens: 0,
          totalPromptTokens: 0,
          totalOutputTokens: 0,
          sessionId: 'sess-A',
        ));
      }
    }));
    return LocalRunHandle(
      events: controller.stream,
      result: done.future,
      cancel: () async => true,
    );
  }
}
