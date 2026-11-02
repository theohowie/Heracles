// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 长任务续跑 UI**（2026-11-02，对应 #1）—— fake `run_stopped` 各 reason。
//
// 后端事件字段当前未进 `AgentEvent` ⇒ 走 `RunStopInfo.fromEvent` 契约适配
// （`raw` JSON / `args`）。本文件钉住：各 reason 的人话、canContinue 禁用、
// token 已用/上限、无进展不等于网络失败、缺字段降级「原因未知」。

import 'dart:async';
import 'dart:convert';

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
import 'package:heracles/widgets/run_stop_banner.dart';

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
  late Completer<void> hold;

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
          return <String, dynamic>{'ok': true, 'text': '', 'truncated': false};
        default:
          return <String, dynamic>{'ok': true};
      }
    });
    AgentBridge.executorFactoryForTest =
        ({required workspacePath, required settings, required sessionStore, askGate}) {
      return _FakeExecutor(
        workspacePath: workspacePath,
        settings: settings,
        sessionStore: sessionStore,
        askGate: askGate,
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
    _FakeExecutor.failureReasonForTest = null;
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
    hold = Completer<void>();
    _holdCompleter = hold;
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installMocks();
    final c = await freshController();
    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(CupertinoTextField).first, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, times: 14);
  }

  AgentEvent runStopped(Map<String, dynamic> payload) => AgentEvent(
        type: RunStopInfo.kRunStoppedEvent,
        ts: 1,
        raw: jsonEncode(payload),
      );

  testWidgets('★★ 各 reason 渲染人话 + token 已用/上限（fake run_stopped）',
      (tester) async {
    await pumpChat(tester);
    await send(tester, '跑个长任务');

    pushRef!(runStopped({
      'reason': 'max_rounds',
      'round': 5,
      'maxRounds': 5,
      'tokensSpent': 1200,
      'tokensLimit': 4000,
      'canContinue': true,
    }));
    await settle(tester);

    expect(find.textContaining('任务被中断：轮次用尽'), findsOneWidget);
    expect(find.textContaining('第 5 / 5 轮'), findsOneWidget);
    expect(find.textContaining('已用 1200 / 上限 4000'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);

    hold.complete();
    await settle(tester, times: 20);
  });

  testWidgets('★★ no_progress 显示"连续两轮没有文件/测试/错误变化"，不许写成网络失败',
      (tester) async {
    await pumpChat(tester);
    await send(tester, '跑个长任务');

    pushRef!(runStopped({
      'reason': 'no_progress',
      'canContinue': false,
      'changedFiles': ['lib/a.dart', 'test/b_test.dart'],
    }));
    await settle(tester);

    expect(find.textContaining('连续两轮没有文件/测试/错误变化'), findsOneWidget);
    expect(find.textContaining('网络中断'), findsNothing,
        reason: '无进展 ≠ 网络失败');
    expect(find.textContaining('lib/a.dart'), findsOneWidget,
        reason: '要给出已改文件摘要');
    // canContinue=false ⇒ 继续按钮禁用 + 说明
    expect(find.textContaining('该中断不支持续跑'), findsOneWidget);

    hold.complete();
    await settle(tester, times: 20);
  });

  testWidgets('★★ 缺字段/未知 reason ⇒ 降级「原因未知」且不许编数', (tester) async {
    await pumpChat(tester);
    await send(tester, '跑个长任务');

    pushRef!(const AgentEvent(type: RunStopInfo.kRunStoppedEvent, ts: 1));
    await settle(tester);

    expect(find.textContaining('任务被中断：原因未知'), findsOneWidget);
    expect(find.textContaining('后端未上报能否续跑'), findsOneWidget);
    expect(find.textContaining('已用'), findsNothing, reason: '没有数据不许编');

    hold.complete();
    await settle(tester, times: 20);
  });

  testWidgets('★ network / user_cancel 两种原因各有人话', (tester) async {
    await pumpChat(tester);
    await send(tester, '跑个长任务');

    pushRef!(runStopped({'reason': 'network', 'canContinue': true}));
    await settle(tester);
    expect(find.textContaining('任务被中断：网络中断'), findsOneWidget);

    pushRef!(runStopped({'reason': 'user_cancel', 'canContinue': true}));
    await settle(tester);
    expect(find.textContaining('任务被中断：你取消了任务'), findsOneWidget);

    hold.complete();
    await settle(tester, times: 20);
  });

  testWidgets('★★ 非用户中断：400 上下文超限必须显示人话原因（T0）',
      (tester) async {
    _FakeExecutor.failureReasonForTest =
        '400: {"message":"workbuddy 上游失败：请求被上游拒绝 '
        '(code 11115) prompt is too long (upstream code 11115) '
        'CONTEXT_WINDOW_EXCEEDED","type":"client","code":"client"}';
    await pumpChat(tester);
    await send(tester, '跑个长任务');

    hold.complete();
    await settle(tester, times: 25);

    expect(find.textContaining('上下文超出模型窗口'), findsWidgets,
        reason: '原始 400 JSON 必须翻译成人话，且不能被吞掉');
    expect(find.textContaining('运行失败：'), findsOneWidget,
        reason: '非用户主动中断必须在会话流留下失败原因');
    expect(find.textContaining('CONTEXT_WINDOW_EXCEEDED'), findsNothing,
        reason: '不要把原始 JSON 直接糊到用户脸上');
  });
}

class _FakeExecutor extends LocalAgentExecutor {
  _FakeExecutor({
    required super.workspacePath,
    required super.settings,
    required super.sessionStore,
    required super.askGate,
    required this.onReady,
  });

  final void Function(Future<void> Function(AgentEvent)) onReady;

  /// 测试注入：本次 fake run 的失败原因（T0 用例用）。
  static String? failureReasonForTest;

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
    // run 保持存活直到测试结束（hold 在 main 里 complete）
    unawaited(Future<void>.delayed(const Duration(milliseconds: 20), () async {
      await _holdFuture();
      if (!controller.isClosed) unawaited(controller.close());
      if (!done.isCompleted) {
        done.complete(AgentRunResult(
          stopReason: '已停止',
          finalText: '已停止',
          turns: [],
          totalCachedTokens: 0,
          totalPromptTokens: 0,
          totalOutputTokens: 0,
          failureReason: _FakeExecutor.failureReasonForTest,
        ));
      }
    }));
    return LocalRunHandle(
      events: controller.stream,
      result: done.future,
      cancel: () async => true,
    );
  }

  static Future<void> _holdFuture() => _holdCompleter!.future;
}

Completer<void>? _holdCompleter;
