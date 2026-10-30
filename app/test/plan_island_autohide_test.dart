// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **灵动岛自动消失（2026-10-30 P0）**：任务完成后不许常驻。
//
// 用户实测：7 步任务跑完，点到「完成」后灵动岛一直挂在屏幕上（收起/展开都在），
// 直到下一轮或切会话才变。根因：显示条件只有「有计划」，完成/中断事件
// 只改状态、**从不清空**；历史会话还会把 JSONL 里的已完成计划读回来。
//
// 本文件钉住（生产同一条事件路径：executorFactoryForTest → handle.events
// → AgentBridge.emitLocalEvent → ChatScreen）：
//   a) 7 步全完成 + kPlanClosed(reachedGoal:true) ⇒ 4 秒后灵动岛消失
//   b) 4 秒内点一下 ⇒ 取消自动隐藏，之后仍在
//   c) 中断/失败 ⇒ 不隐藏，10 秒后只收起（原因不丢）
//   d) 发送新消息 ⇒ 上一轮已完成计划立即消失
//   e) 历史会话恢复：已完成计划不显示（shouldRestorePlanIsland 直测）
//   f) plan_updated 空帧 ⇒ 立即隐藏（契约语义，防回归）

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
import 'package:heracles/widgets/bw_topbar.dart' show DynamicIsland;

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

  /// 当前 run 的事件推送函数（假执行器注入，生产同路）。
  Future<void> Function(AgentEvent)? pushRef;

  /// 按顺序消费的脚本队列：每次 `run()` 取一个（用于第 d 条"新旧两轮"）。
  final scripts = <Future<void> Function()>[];

  void installMocks() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'listWorkspaces':
          return [workspaceMap];
        default:
          return null;
      }
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
        case 'fs.appendText':
        case 'fs.writeText':
        case 'fs.mkdir':
        case 'fs.delete':
          return <String, dynamic>{'ok': true};
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
        nextScript: () => scripts.isNotEmpty
            ? scripts.removeAt(0)
            : () async {}, // 没有脚本 = 空跑（用来验"新 run 不复活旧计划"）
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

  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 500dp 宽：避开本文件不该管的「390dp 输入条 Row 溢出（既有红）」。
  Future<void> pumpChat(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installMocks();
    final c = await freshController();
    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);
  }

  Future<void> sendMessage(WidgetTester tester) async {
    await tester.enterText(find.byType(CupertinoTextField).first, '把任务拆成 7 步并执行');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester, times: 14);
  }

  AgentEvent planCreated(int steps) => AgentEvent(
        type: AgentEvent.kPlanCreated,
        ts: DateTime.now().millisecondsSinceEpoch,
        planSteps: [for (var i = 0; i < steps; i++) '步骤 ${i + 1}'],
        doneCount: 0,
        activeIndex: 0,
      );

  AgentEvent planClosed({required bool reachedGoal, String? reason}) =>
      AgentEvent(
        type: AgentEvent.kPlanClosed,
        ts: DateTime.now().millisecondsSinceEpoch,
        reachedGoal: reachedGoal,
        planClosedReason: reason,
      );

  AgentEvent planUpdatedEmpty() => AgentEvent(
        type: AgentEvent.kPlanUpdated,
        ts: DateTime.now().millisecondsSinceEpoch,
        planStepsDetailed: const <Map<String, String>>[],
      );

  AgentEvent finished() => AgentEvent(
        type: AgentEvent.kFinished,
        ts: DateTime.now().millisecondsSinceEpoch,
      );

  AgentEvent failed(String message) => AgentEvent(
        type: AgentEvent.kFailed,
        ts: DateTime.now().millisecondsSinceEpoch,
        message: message,
      );

  // 等 4 秒 + 淡出动画走完。
  Future<void> waitAutoHide(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 60));
  }

  group('灵动岛自动消失', () {
    testWidgets('a) 7 步全完成 + plan_closed(true) ⇒ 4 秒后灵动岛消失（不许常驻）',
        (tester) async {
      scripts.add(() async {
        await pushRef!(planCreated(7));
        await pushRef!(planClosed(reachedGoal: true));
        await pushRef!(finished());
      });
      await pumpChat(tester);
      await sendMessage(tester);

      // 前置：消息真的发出去了、没有被"还没有工作区"早退挡住
      expect(find.textContaining('把任务拆成 7 步并执行'), findsWidgets,
          reason: '用户消息应已落进会话');
      expect(find.textContaining('还没有工作区'), findsNothing,
          reason: '不应被无工作区早退挡住');

      // 完成态先给用户看到（7/7 在岛上）
      expect(find.byType(DynamicIsland), findsOneWidget,
          reason: '完成瞬间必须先进完成态，不是直接消失');
      expect(find.textContaining('7/7'), findsWidgets,
          reason: '完成态应显示 7/7');

      await waitAutoHide(tester);
      expect(find.byType(DynamicIsland), findsNothing,
          reason: '任务完成后灵动岛必须自动消失，不许常驻（P0）');
    });

    testWidgets('b) 4 秒内点一下 ⇒ 取消自动隐藏，之后仍在', (tester) async {
      scripts.add(() async {
        await pushRef!(planCreated(7));
        await pushRef!(planClosed(reachedGoal: true));
        await pushRef!(finished());
      });
      await pumpChat(tester);
      await sendMessage(tester);
      expect(find.byType(DynamicIsland), findsOneWidget);

      // 用户点岛（想看计划）⇒ 取消自动隐藏
      await tester.tap(find.byType(DynamicIsland));
      await settle(tester, times: 3);
      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(DynamicIsland), findsOneWidget,
          reason: '用户点开查看后不许再自动消失（保持到下一轮/切会话）');
    });

    testWidgets('c) 中断（reachedGoal=false）⇒ 不隐藏，10 秒后只收起、原因不丢',
        (tester) async {
      scripts.add(() async {
        await pushRef!(planCreated(7));
        await pushRef!(planClosed(reachedGoal: false, reason: '轮次耗尽，任务中断'));
        await pushRef!(failed('轮次耗尽，任务中断'));
      });
      await pumpChat(tester);
      await sendMessage(tester);

      expect(find.byType(DynamicIsland), findsOneWidget,
          reason: '中断时不能立刻藏掉，用户要知道为什么停下');
      expect(find.textContaining('轮次耗尽，任务中断'), findsWidgets,
          reason: '中断原因必须可见');

      // 10 秒内不得清空
      await tester.pump(const Duration(seconds: 9));
      expect(find.byType(DynamicIsland), findsOneWidget,
          reason: '中断态不许自动清掉');
      // 10 秒后只收起成一行：岛仍在，原因还在（字段保留；收起态不画原因）
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 400)); // 等 AnimatedSize 收完
      expect(find.byType(DynamicIsland), findsOneWidget,
          reason: '10 秒后也只是收起成一行，不能清空');
      final island =
          tester.widget<DynamicIsland>(find.byType(DynamicIsland));
      expect(island.reachedGoal, isFalse,
          reason: '中断标记必须保留（不能画成完成）');
      expect(island.closedReason, '轮次耗尽，任务中断',
          reason: '自动收起后原因字段仍要保留');
      expect(island.collapsed, isTrue,
          reason: '10 秒后应自动收起成一行');
    });

    testWidgets('d) 发送新消息 ⇒ 上一轮已完成的计划立即消失', (tester) async {
      // 第一轮：完成（4 秒还没到就发新消息）
      scripts.add(() async {
        await pushRef!(planCreated(7));
        await pushRef!(planClosed(reachedGoal: true));
        await pushRef!(finished());
      });
      // 第二轮：空跑（不推计划），用来验证"旧计划不会盖住新任务"
      scripts.add(() async {});
      await pumpChat(tester);
      await sendMessage(tester);
      expect(find.byType(DynamicIsland), findsOneWidget);

      await sendMessage(tester);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(DynamicIsland), findsNothing,
          reason: '开始新一轮时必须先清掉上一轮已完成计划');
    });

    testWidgets('f) plan_updated 空帧 ⇒ 立即隐藏（契约语义，防回归）',
        (tester) async {
      scripts.add(() async {
        await pushRef!(planCreated(7));
        await pushRef!(planUpdatedEmpty());
        await pushRef!(finished());
      });
      await pumpChat(tester);
      await sendMessage(tester);
      expect(find.byType(DynamicIsland), findsNothing,
          reason: '后端 steps:[] = 无计划 ⇒ 立即收起');
    });
  });

  group('历史会话恢复：已完成计划不显示（真实 JSONL 行 + 纯函数）', () {
    Map<String, dynamic> planRow(
      List<String> statuses, {
      bool? reachedGoal,
      String? reason,
    }) =>
        <String, dynamic>{
          'role': 'plan',
          'ts': 1790000000000,
          'reachedGoal': reachedGoal,
          'closedReason': reason,
          'steps': [
            for (var i = 0; i < statuses.length; i++)
              {'text': '步骤 ${i + 1}', 'status': statuses[i]},
          ],
        };

    test('e) 已完成/全终态 ⇒ 不恢复;未完成/中断 ⇒ 恢复（含原因）', () {
      // 全部 done（上一轮跑完的历史行）
      expect(
        restoredPlanFromRow(planRow(List.filled(7, 'done'), reachedGoal: true)),
        isNull,
        reason: '已完成计划不许在历史会话里复活灵动岛',
      );
      // 全终态但老行没有 reachedGoal
      expect(
        restoredPlanFromRow(planRow(List.filled(7, 'done'))),
        isNull,
        reason: '全 done 的历史计划同样视为已完成',
      );
      // done + cancelled 混合也算终态
      expect(
        restoredPlanFromRow(
            planRow(['done', 'done', 'cancelled', 'skipped'])),
        isNull,
        reason: 'cancelled/skipped 也是终态',
      );
      // 中断：保留原因
      final interrupted = restoredPlanFromRow(planRow(
        ['done', 'done', 'done', 'active', 'pending', 'pending', 'pending'],
        reachedGoal: false,
        reason: '轮次耗尽，任务中断',
      ));
      expect(interrupted, isNotNull, reason: '中断计划要恢复显示');
      expect(interrupted!.done, 3);
      expect(interrupted.active, 3);
      expect(interrupted.reachedGoal, isFalse);
      expect(interrupted.closedReason, '轮次耗尽，任务中断');
      // 未完成且没有任何收尾标记 ⇒ 正常恢复
      final running =
          restoredPlanFromRow(planRow(['done', 'active', 'pending']));
      expect(running, isNotNull);
      expect(running!.active, 1);
      // 空计划 / 非 plan 行 ⇒ 不恢复
      expect(restoredPlanFromRow({'role': 'plan', 'steps': <dynamic>[]}), isNull);
      expect(restoredPlanFromRow({'role': 'user', 'text': 'hi'}), isNull);
    });

    test('e2) 规则函数本身：全终态 / reachedGoal 的判定', () {
      expect(
        shouldRestorePlanIsland(total: 7, terminal: 7, reachedGoal: true),
        isFalse,
        reason: '已完成计划不许在历史会话里复活灵动岛',
      );
      expect(
        shouldRestorePlanIsland(total: 7, terminal: 7, reachedGoal: null),
        isFalse,
        reason: '全 done/cancelled 的历史计划同样视为已完成',
      );
      expect(
        shouldRestorePlanIsland(total: 7, terminal: 3, reachedGoal: false),
        isTrue,
        reason: '中断的计划要恢复显示（用户要知道为什么停下）',
      );
      expect(
        shouldRestorePlanIsland(total: 7, terminal: 2, reachedGoal: null),
        isTrue,
        reason: '未完成计划正常恢复',
      );
      expect(
        shouldRestorePlanIsland(total: 0, terminal: 0, reachedGoal: null),
        isFalse,
        reason: '空计划不显示',
      );
    });
  });
}

// ============================================================================
// 假执行器：与 chat_streaming_test 同形状（生产同一条事件路径）
// ============================================================================

class _FakeExecutor extends LocalAgentExecutor {
  _FakeExecutor({
    required super.workspacePath,
    required super.settings,
    required super.sessionStore,
    super.askGate,
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

    // 脚本延后一拍（20ms 假时钟）开跑：保证 AgentBridge 已挂上 handle.events
    // 的转发订阅（broadcast 流不缓冲，早推会丢）。
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
