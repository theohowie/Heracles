// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **P0：排队项「插队」两分支必须有可见反馈**（2026-10-30）。
//
// 旧行为（真因，记录在 `.docs/前端P0未完成-2026-10-30.md` A3）：
// `_sendQueuedNow` 调 `interruptRun`，返回 false 时只 `_queue.insert(0, item)`
// —— 没有任何提示，用户看到的就是"点了 ↑ 没反应"；accepted=true 时也**没有**
// "已插队"的交代（用户以为插话立刻执行了，其实要等本轮结束）。
//
// 后端 `8e6d496` 起 `interruptRun` 真生效（accepted/added），本文件用
// **生产同一条路径**钉住两个分支：
//   · accepted=true  ⇒ Toast「已插队，模型将在本轮结束时看到」+ 队列移除
//                      + `interrupted` 事件把它渲染成用户消息；
//   · accepted=false ⇒ Toast「插话未成功（队列已满或任务刚结束），已保留在排队」
//                      + 该条**仍在队列**（绝不静默丢/静默重排队）。

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
  var steerAccepted = true;

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
      return _FakeExecutor(
        workspacePath: workspacePath,
        settings: settings,
        sessionStore: sessionStore,
        askGate: askGate,
        steerAccepted: () => steerAccepted,
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

  /// 长任务：发一条消息后 run **保持存活**，直到测试 complete [hold]。
  late Completer<void> hold;
  void scriptLongRun() {
    scripts.add(() async {
      await pushRef!(AgentEvent(type: AgentEvent.kTurnStarted, ts: 1, index: 1));
      await hold.future;
    });
  }

  Future<void> pumpChat(WidgetTester tester) async {
    hold = Completer<void>();
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

  /// 队列行的 ↑（立即发送 / 插队）
  final upButton = find.byTooltip('立即发送（打断当前任务）');

  testWidgets('★★ accepted=true ⇒ 「已插队」提示 + 队列移除 + 渲染成用户消息',
      (tester) async {
    steerAccepted = true;
    scriptLongRun();
    await pumpChat(tester);
    await send(tester, '跑一个长任务');
    await settle(tester); // run 存活，_busy=true

    await send(tester, '插队内容ABC');
    expect(upButton, findsOneWidget, reason: '忙时发送应进入排队（前置）');
    expect(steerAccepted, isTrue);

    await tester.tap(upButton);
    await settle(tester, times: 16);

    expect(find.text('已插队，模型将在本轮结束时看到'), findsOneWidget,
        reason: 'accepted=true 必须告诉用户"本轮结束才生效"，不能静默');
    // 队列移除 + interrupted 事件把它渲染成用户消息
    expect(find.text('插队内容ABC'), findsWidgets,
        reason: '插队文本应作为用户消息出现在会话里');
    expect(upButton, findsNothing, reason: '队列里那条必须被移走');

    hold.complete();
    await settle(tester, times: 45); // 排空 toast 计时器
  });

  testWidgets('★★ 排队行「编辑」⇒ 原地改文本，队列位置/附件不变、不发送',
      (tester) async {
    steerAccepted = true;
    scriptLongRun();
    await pumpChat(tester);
    await send(tester, '跑一个长任务');
    await settle(tester);

    await send(tester, '排队原文ABC');
    // 先把「已排队…」的 toast 计时走完 —— 它是一层 absorb-pointer 覆盖，
    // 否则点排队行会被它吃掉（真机 2.2s 后同样消失）。
    await settle(tester, times: 45);
    expect(upButton, findsOneWidget, reason: '前置：已在排队');

    // 点排队行的「编辑」
    expect(find.byTooltip('编辑'), findsOneWidget,
        reason: '排队行必须有编辑入口（旧实现只有管理面板里能点）');
    await tester.tap(find.byTooltip('编辑'));
    await settle(tester, times: 10);

    expect(find.text('编辑排队消息'), findsOneWidget, reason: '编辑抽屉已打开');
    await tester.enterText(
        find.byType(CupertinoTextField).last, '改过的排队内容XYZ');
    await settle(tester, times: 4);
    await tester.tap(find.text('保存'));
    await settle(tester, times: 10);

    // 队列里换成新文案；旧的消失；仍在排队（没有被发出去）
    expect(find.text('改过的排队内容XYZ'), findsOneWidget,
        reason: '保存后队列行必须显示新文本');
    expect(find.text('排队原文ABC'), findsNothing);
    expect(upButton, findsOneWidget, reason: '编辑不改变"还在排队"这件事');

    hold.complete();
    await settle(tester, times: 45);
  });

  testWidgets('★★ accepted=false ⇒ 明确提示 + 该条仍在排队（不许静默）',
      (tester) async {
    steerAccepted = false;
    scriptLongRun();
    await pumpChat(tester);
    await send(tester, '跑一个长任务');
    await settle(tester);

    await send(tester, '插队内容XYZ');
    expect(upButton, findsOneWidget, reason: '前置：已在排队');

    await tester.tap(upButton);
    await settle(tester, times: 16);

    expect(
      find.text('插话未成功（队列已满或任务刚结束），已保留在排队'),
      findsOneWidget,
      reason: 'accepted=false 必须给明确反馈，旧实现只是静默重排队',
    );
    expect(upButton, findsOneWidget,
        reason: '被拒后必须保留在排队（不丢消息）');

    hold.complete();
    await settle(tester, times: 45);
  });
}

class _FakeExecutor extends LocalAgentExecutor {
  _FakeExecutor({
    required super.workspacePath,
    required super.settings,
    required super.sessionStore,
    required super.askGate,
    required this.steerAccepted,
    required this.nextScript,
    required this.onReady,
  });

  final bool Function() steerAccepted;
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
      // 生产同语义：接受 ⇒ (accepted:true, added:true)（AgentBridge 收到后自己发 interrupted）
      enqueueSteer: (text) => steerAccepted()
          ? (accepted: true, added: true)
          : (accepted: false, added: false),
    );
  }
}
