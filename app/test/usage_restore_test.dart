// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **T1-4（2026-10-31）：用量汇总恢复** —— 缓存命中率跨会话 / 重启保留。
//
// 用户报的现象：切会话或杀进程重开后，顶栏命中率变回「—」、用量抽屉全是空。
// 根因：`_usageBySession` 只在 run 收尾时写内存；重放历史时 `role:"usage"`
// 记账行被直接跳过（老实现），也没有读新的 `role:"session_usage"` 汇总行。
//
// 本文件钉住（两条路径分开测）：
//   A. 纯函数 `sessionUsageFromRows`：汇总行优先 / 旧行降级累计 / 无数据为 null
//      / `cached` 缺省 = 未上报（不是 0%）/ 汇总行与旧行**绝不重复累加**；
//   B. ChatScreen 真实路径（drawer 打开会话 → `_selectSession` → 顶栏）：
//      两会话各自命中率、切回仍对、重建 ChatScreen（模拟杀进程）仍显示、
//      旧会话无汇总行时用 assistant/usage 行降级、无数据仍「—」。
//
// 数据形状以 `app/lib/services/local_agent.dart` 的 `_appendSessionUsage`
// 为准：`{role:"session_usage", runs, turns, reportedTurns, unreportedTurns,
// cached?, prompt, out, steadyHitRate?, ts}`（cached/steadyHitRate 缺省不写键）。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/agent_bridge.dart' show AgentBridge;
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart' show AppIcons;
import 'package:heracles/widgets/bw_approval.dart' show BwOptionCard, BwSheetShell;
import 'package:heracles/widgets/bw_topbar.dart' show TopMetricLine;
import 'package:heracles/widgets/workspace_drawer.dart';

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

  /// 每个用例自己填：`sessions.json` 的内容（侧边栏的会话行）。
  final sessions = <Map<String, dynamic>>[];

  /// 会话 id → 落盘的 JSONL 行（与生产 SessionStore 读到的原文同形）。
  final messagesBySession = <String, List<Map<String, dynamic>>>{};

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
          // 新会话 id 探测（永不撞）+ 小文件（不触发尾部读取）
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
          final rows = messagesBySession[sid] ?? const <Map<String, dynamic>>[];
          return <String, dynamic>{
            'ok': true,
            'text': rows.map(jsonEncode).join('\n'),
            'truncated': false,
          };
        case 'fs.readTailLines':
          final sid = path.split('/').last.replaceAll('.jsonl', '');
          final rows = messagesBySession[sid] ?? const <Map<String, dynamic>>[];
          return <String, dynamic>{
            'ok': true,
            'lines': <String>[for (final r in rows) jsonEncode(r)],
          };
        case 'fs.appendText':
        case 'fs.writeText':
        case 'fs.mkdir':
        case 'fs.delete':
          return <String, dynamic>{'ok': true};
        default:
          return <String, dynamic>{'ok': true};
      }
    });
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
    AgentBridge.executorFactoryForTest = null;
    sessions.clear();
    messagesBySession.clear();
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
      // T1-1：顶栏上下文环要有上限才能画百分比；测试里给服务端权威值。
      modelCapabilities: {
        'deepseek-chat': ModelCapability(contextWindow: 1000000),
      },
    ));
    await c.setActiveProvider('deepseek-account');
    return c;
  }

  Widget wrap(Widget child) => MaterialApp(
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

  /// 500dp 宽：避开本文件不该管的「390dp 输入条 Row 溢出」口径差异。
  Future<void> pumpChat(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installMocks();
    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);
  }

  /// 打开抽屉（`ScaffoldState.openDrawer` —— 与顶栏/边缘手势同一个抽屉）。
  Future<void> openDrawer(WidgetTester tester) async {
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    scaffold.openDrawer();
    await settle(tester);
  }

  /// 抽屉里点一个会话（**锚定在 WorkspaceDrawer 内**：打开一个会话后顶栏
  /// 标题会显示同一个名字，全局 `find.text` 会命中两处）。
  Future<void> openSession(WidgetTester tester, String title) async {
    await openDrawer(tester);
    final row = find.descendant(
      of: find.byType(WorkspaceDrawer),
      matching: find.text(title),
    );
    expect(row, findsOneWidget, reason: '抽屉里应有会话「$title」');
    await tester.tap(row);
    await settle(tester);
  }

  Map<String, dynamic> sessionRow(String id, String title, int updatedAt) =>
      <String, dynamic>{'id': id, 'title': title, 'updatedAt': updatedAt};

  // ==========================================================================
  // A. 纯函数：`sessionUsageFromRows` 的映射规则
  // ==========================================================================

  group('A. sessionUsageFromRows（JSONL 行 → SessionUsage）', () {
    Map<String, dynamic> summary({
      int runs = 2,
      int turns = 4,
      int reportedTurns = 4,
      int unreportedTurns = 0,
      int? cached,
      int prompt = 1000,
      int out = 200,
      double? steadyHitRate,
    }) =>
        <String, dynamic>{
          'role': 'session_usage',
          'runs': runs,
          'turns': turns,
          'reportedTurns': reportedTurns,
          'unreportedTurns': unreportedTurns,
          // 缺省不写键（生产口径：从没上报过缓存就不写假 0）
          'cached': ?cached,
          'prompt': prompt,
          'out': out,
          'steadyHitRate': ?steadyHitRate,
          'ts': 3,
        };

    test('a) 汇总行 → 命中率 = cached/prompt，稳态原样透传', () {
      final u = sessionUsageFromRows(<Map<String, dynamic>>[
        {'role': 'user', 'text': 'hi', 'ts': 1},
        summary(cached: 900, steadyHitRate: 0.75),
      ]);
      expect(u, isNotNull);
      expect(u!.runs, 2);
      expect(u.turns, 4);
      expect(u.reportedTurns, 4);
      expect(u.cachedTokens, 900);
      expect(u.reportedPromptTokens, 1000);
      expect(u.totalInputTokens, 1000);
      expect(u.outputTokens, 200);
      expect(u.hitRate, closeTo(0.9, 1e-9));
      expect(u.steadyHitRate, 0.75);
      // 汇总行没有的字段不许编：模型用时/任务耗时保持 0（UI 显示「—」）
      expect(u.wallMs, 0);
      expect(u.taskWallMs, 0);
    });

    test('b) cached 缺省 = 未上报 ⇒ hitRate 为 null（不是 0%）', () {
      final u = sessionUsageFromRows(<Map<String, dynamic>>[summary()]);
      expect(u, isNotNull);
      expect(u!.hasCacheData, isFalse,
          reason: '从没上报过缓存 ⇒ 不能画 0%');
      expect(u.hitRate, isNull);
      expect(u.cachedTokens, 0);
      expect(u.reportedTurns, 0);
      expect(u.unreportedTurns, 4, reason: '输入仍然可见（未上报桶）');
      expect(u.totalInputTokens, 1000, reason: 'prompt 是真实上报的输入量');
      expect(u.steadyHitRate, isNull);
    });

    test('c) 汇总行 + 同批 assistant 行 ⇒ 只认汇总（绝不重复累加）', () {
      final u = sessionUsageFromRows(<Map<String, dynamic>>[
        // 旧累计行：若被叠加，命中率会变成 (900+400)/(1000+1000) = 65%
        {'role': 'assistant', 'text': 'ok', 'cached': 400, 'prompt': 1000, 'out': 50, 'ts': 2},
        summary(cached: 900),
      ]);
      expect(u!.cachedTokens, 900, reason: '只有汇总行的 900');
      expect(u.reportedPromptTokens, 1000, reason: '只有汇总行的 1000');
      expect(u.hitRate, closeTo(0.9, 1e-9),
          reason: '出现汇总行就不得再叠加 assistant 行（重复计数）');
    });

    test('d) 旧会话没有汇总行 ⇒ assistant/usage 行降级累计（不重复）', () {
      final u = sessionUsageFromRows(<Map<String, dynamic>>[
        {'role': 'user', 'text': 'q1', 'ts': 1},
        {'role': 'assistant', 'text': 'a1', 'cached': 250, 'prompt': 1000, 'out': 10, 'ts': 2},
        {'role': 'user', 'text': 'q2', 'ts': 3},
        // 失败 run 的记账行：只有 prompt/out，没有 cached ⇒ 未上报桶
        {'role': 'usage', 'prompt': 500, 'out': 5, 'ts': 4},
      ]);
      expect(u, isNotNull);
      expect(u!.cachedTokens, 250);
      expect(u.reportedPromptTokens, 1000);
      expect(u.unreportedTurns, 1, reason: '失败 run 那行没上报缓存');
      expect(u.unreportedPromptTokens, 500);
      expect(u.turns, 2, reason: '旧数据按"一行 ≈ 一次 run"近似');
      expect(u.runs, 2);
      expect(u.hitRate, closeTo(0.25, 1e-9),
          reason: '分母只含已上报轮次（1000），未上报不受稀释');
    });

    test('e) 没有任何用量行 ⇒ null（UI「—」，不编 0）', () {
      expect(
        sessionUsageFromRows(<Map<String, dynamic>>[
          {'role': 'user', 'text': 'hi', 'ts': 1},
          {'role': 'assistant', 'text': 'ok', 'ts': 2},
        ]),
        isNull,
      );
      expect(sessionUsageFromRows(const <Map<String, dynamic>>[]), isNull);
    });

    test('f) 汇总行 cached 显式 null ⇒ 仍按"未上报"（不是 0）', () {
      final u = sessionUsageFromRows(<Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'session_usage',
          'runs': 1,
          'turns': 1,
          'reportedTurns': 1,
          'unreportedTurns': 0,
          'cached': null,
          'prompt': 700,
          'out': 70,
          'ts': 2,
        },
      ]);
      expect(u!.hitRate, isNull);
      expect(u.outputTokens, 70);
    });
  });

  // ==========================================================================
  // B. ChatScreen 真实路径（drawer → `_selectSession` → 顶栏）
  // ==========================================================================

  group('B. 打开/切换会话时恢复用量（ChatScreen）', () {
    void seedTwoSessions() {
      sessions.addAll([
        sessionRow('sess-A', '会话 A', 2000),
        sessionRow('sess-B', '会话 B', 1000),
      ]);
      // A：附件汇总行 + 旧累计行（证明不重复叠加：否则 65% 而不是 90%）
      messagesBySession['sess-A'] = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'text': 'hi', 'ts': 1},
        <String, dynamic>{
          'role': 'assistant',
          'text': 'ok',
          'cached': 400,
          'prompt': 1000,
          'out': 50,
          'ts': 2,
        },
        <String, dynamic>{
          'role': 'session_usage',
          'runs': 2,
          'turns': 4,
          'reportedTurns': 4,
          'unreportedTurns': 0,
          'cached': 900,
          'prompt': 1000,
          'out': 200,
          'steadyHitRate': 0.8,
          'ts': 3,
        },
      ];
      messagesBySession['sess-B'] = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'text': 'yo', 'ts': 1},
        <String, dynamic>{
          'role': 'session_usage',
          'runs': 1,
          'turns': 2,
          'reportedTurns': 2,
          'unreportedTurns': 0,
          'cached': 400,
          'prompt': 1000,
          'out': 20,
          'ts': 2,
        },
      ];
    }

    testWidgets('a) 两会话各有汇总 ⇒ 切换命中率正确、切回不丢', (tester) async {
      seedTwoSessions();
      await pumpChat(tester);

      // 前置：没打开会话前没有数据 ⇒ 「—」
      expect(find.text('命中 —'), findsOneWidget,
          reason: '没打开会话时不应有编造的命中率');

      await openSession(tester, '会话 A');
      expect(find.text('命中 90%'), findsOneWidget,
          reason: 'A 的汇总行 900/1000 ⇒ 90%（出现旧行也不许叠加成 65%）');

      await openSession(tester, '会话 B');
      expect(find.text('命中 40%'), findsOneWidget,
          reason: '切会话 = 换另一本账（B 的汇总行 400/1000）');

      await openSession(tester, '会话 A');
      expect(find.text('命中 90%'), findsOneWidget,
          reason: '切回 A 仍是 A 的累计账');
    });

    testWidgets('d) 打开会话后上下文环立即有数（T1-1，不许等用量抽屉）',
        (tester) async {
      seedTwoSessions();
      await pumpChat(tester);
      await openSession(tester, '会话 A');

      final ctx = tester
          .widgetList<TopMetricLine>(find.byType(TopMetricLine))
          .firstWhere((line) => line.label == '上下文');
      expect(ctx.valueText, isNot('—'),
          reason: '打开会话后顶栏上下文必须已有占用率（旧实现要打开用量抽屉才刷新）');
      expect(ctx.valueText, endsWith('%'),
          reason: '有上限且会话有内容 ⇒ 应显示百分比');
    });

    testWidgets('b) 重建 ChatScreen（模拟杀进程重开）⇒ 仍显示汇总命中率',
        (tester) async {
      seedTwoSessions();
      await pumpChat(tester);
      await openSession(tester, '会话 A');
      expect(find.text('命中 90%'), findsOneWidget);

      // 丢弃整棵树 = 内存里的 `_usageBySession` 全没；再建一个全新 ChatScreen。
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester, times: 3);

      final c2 = await freshController();
      await tester.pumpWidget(wrap(ChatScreen(settings: c2)));
      await settle(tester);
      expect(find.text('命中 —'), findsOneWidget,
          reason: '前提：新进程内存里没有旧用量');

      await openSession(tester, '会话 A');
      expect(find.text('命中 90%'), findsOneWidget,
          reason: '重启后仍必须从落盘汇总行恢复（跨重启保留）');
    });

    testWidgets('c) 旧会话无汇总行 ⇒ assistant/usage 行降级累计', (tester) async {
      sessions.addAll([
        sessionRow('sess-C', '会话 C', 1000),
        sessionRow('sess-D', '会话 D', 900),
      ]);
      messagesBySession['sess-C'] = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'text': 'q', 'ts': 1},
        <String, dynamic>{
          'role': 'assistant',
          'text': 'a',
          'cached': 250,
          'prompt': 1000,
          'out': 10,
          'ts': 2,
        },
        <String, dynamic>{'role': 'usage', 'prompt': 500, 'out': 5, 'ts': 3},
      ];
      // D：只有对话、没有任何用量字段 ⇒ 必须显示「—」
      messagesBySession['sess-D'] = <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'text': 'hi', 'ts': 1},
        <String, dynamic>{'role': 'assistant', 'text': 'ok', 'ts': 2},
      ];
      await pumpChat(tester);

      await openSession(tester, '会话 C');
      expect(find.text('命中 25%'), findsOneWidget,
          reason: '250/1000 —— 旧行的 cached/prompt 也要能恢复');

      await openSession(tester, '会话 D');
      expect(find.text('命中 —'), findsOneWidget,
          reason: '真的没有用量数据 ⇒ 「—」，不许编 0%');
    });
  });

  // ==========================================================================
  // C. T2-6 调用点（同属 task-10 的"顺带 2 行"）：模型目录二级弹层的「当前」
  // ==========================================================================
  //
  // 判据必须与设置页/输入框胶囊**同一口径**（`effectiveProvider`）：
  // 用户没显式点过 provider 时 `activeProviderId` 是 null，但胶囊上已经有模型名
  // （自动选中）⇒ 旧判据 `p.id == activeProviderId` 永远 false，目录里一条 ✓ 都没有。
  group('C. 模型目录「当前」判据用 effectiveProvider 兜底', () {
    testWidgets('a) activeProviderId=null ⇒ 目录里的当前模型仍带 ✓', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      installMocks();
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();
      // 新增一个"中转站"服务商（带模型目录）；不调用 setActiveProvider
      // ⇒ activeProviderId 保持 null（= 用户从没显式点过 provider）。
      await c.addProvider(const ModelProviderConfig(
        id: 'p-one',
        name: '中转站',
        baseUrl: 'https://api.example.com/v1',
        model: 'm-one',
        apiKey: 'sk-test',
        modelCatalog: ['m-one', 'm-two'],
      ));
      // 前提：用户从未显式点过 provider ⇒ activeProviderId 仍为 null
      expect(c.value.activeProviderId, isNull);
      expect(c.value.effectiveProvider?.id, 'p-one');

      await tester.pumpWidget(wrap(ChatScreen(settings: c)));
      await settle(tester);

      // 点输入框的模型胶囊 → 模型抽屉（与生产同一调用链）
      await tester.tap(find.text('m-one').first);
      await settle(tester, times: 20);
      final inCard = find.descendant(
        of: find.byType(BwOptionCard),
        matching: find.text('m-one'),
      );
      expect(inCard, findsOneWidget, reason: '模型抽屉里应有该 provider 的卡片');
      await tester.tap(find.ancestor(
        of: inCard,
        matching: find.byType(BwOptionCard),
      ));
      await settle(tester, times: 25);

      // 目录弹层（chat_screen._pickFromCatalog）：当前模型必须有 ✓
      final sheet = find.byType(BwSheetShell);
      expect(sheet, findsOneWidget, reason: '点带目录的 provider 应进目录二级弹层');
      final check = find.descendant(
        of: sheet,
        matching: find.byIcon(AppIcons.check),
      );
      expect(check, findsOneWidget,
          reason: '没显式点过 provider 时，目录里也要标出当前模型（effective 兜底）');
    });
  });
}
