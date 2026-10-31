// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **T0-2（2026-10-31）长会话分页的"可见部分"**：更早消息未加载 ⇒ 顶部横幅，
// 不再把 SessionStore 的合成分页提示画成一条「会话记录超过 1MB…」气泡。
//
// 背景（后端已落地，ADR/提交 66715bf）：
// `SessionStore.loadMessages(limit:0)` 在会话文件 > 通道 1MB 时**自动读尾部**
// （`ContractSession.tailLoadLines` 行），并在返回列表**头插**一条
// `{role:'system', _synthetic:'paging', hasEarlier:true, text:'…超过 1MB…'}`。
//
// 旧 chat_screen 的 `case 'system'` 会把它画成**assistant 气泡** —— 用户看到
// 一句"会话记录超过通道 1MB 上限…"像是模型说的话，既误导又不像入口。
//
// 本文件钉住（先红后绿）：
//   a) 大会话：不出现 1MB 文案气泡；顶部出现「更早消息未加载」横幅；
//      最新消息正常显示（不是最早的 1MB 内容）；
//   b) 切到普通小会话 ⇒ 横幅消失（状态跟着会话走，不残留）；
//   c) 真正的读取失败 system 行**仍然**要显示（别把错误也吞了）；
//   d) 点横幅 ⇒ Toast「加载更早消息需要后端分页接口（已移交）」（翻页未实现，
//      如实告知；等 `AgentBridge.loadMessages(limit/offset)` 落地再接）。

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

  const sessions = <Map<String, dynamic>>[
    {'id': 'sess-big', 'title': '会话大', 'updatedAt': 3000},
    {'id': 'sess-small', 'title': '会话小', 'updatedAt': 2000},
    {'id': 'sess-err', 'title': '会话坏', 'updatedAt': 1000},
  ];

  /// 大会话的虚拟文件（T0-2 真翻页用）：2400 行、每行一条消息。
  /// 初始 `limit:0` 只拿尾部 2000 行；两页后到顶。
  const totalBigLines = 2400;
  List<Map<String, dynamic>> bigLines() => <Map<String, dynamic>>[
        for (var i = 0; i < totalBigLines; i++)
          <String, dynamic>{
            'role': i.isEven ? 'user' : 'assistant',
            'text': 'L-$i',
            'ts': i + 1,
          },
      ];

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
      final isBig = path.endsWith('sess-big.jsonl');
      final isSmall = path.endsWith('sess-small.jsonl');
      final isErr = path.endsWith('sess-err.jsonl');
      switch (call.method) {
        case 'fs.stat':
          if (isBig) {
            // > ContractSession.channelTextMaxBytes(1MB) ⇒ SessionStore 走尾部读
            return <String, dynamic>{'ok': true, 'exists': true, 'size': 1500000};
          }
          if (isSmall) {
            return <String, dynamic>{'ok': true, 'exists': true, 'size': 900};
          }
          if (isErr) {
            return <String, dynamic>{'ok': true, 'exists': true, 'size': 500};
          }
          return <String, dynamic>{'ok': true, 'exists': false};
        case 'fs.readText':
          if (path.endsWith('sessions.json')) {
            return <String, dynamic>{
              'ok': true,
              'text': jsonEncode(sessions),
              'truncated': false,
            };
          }
          if (isErr) {
            // 真正的读失败 ⇒ SessionStore 返回一条**非分页**的 system 行
            return <String, dynamic>{'ok': false, 'error': '磁盘 I/O 错误'};
          }
          if (isSmall) {
            return <String, dynamic>{
              'ok': true,
              'text': [
                jsonEncode(<String, dynamic>{
                  'role': 'user',
                  'text': '小会话消息',
                  'ts': 1,
                }),
                jsonEncode(<String, dynamic>{
                  'role': 'assistant',
                  'text': '小会话回答',
                  'ts': 2,
                }),
              ].join('\n'),
              'truncated': false,
            };
          }
          // 大会话不该走全文读（stat 已报 >1MB）；万一走了也算"被截断"，
          // SessionStore 会因此改走 tail。
          return <String, dynamic>{
            'ok': true,
            'text': bigLines().map(jsonEncode).join('\n'),
            'truncated': true,
          };
        case 'fs.readTailLines':
          // Kotlin 契约：`fs.readTailLines` → `{ok, text, truncated}`。
          // 大会话按 `maxLines` 真窗口返回（翻页测试要靠它）。
          if (isBig) {
            final all = bigLines();
            final maxLines = (args['maxLines'] as num?)?.toInt() ?? 0;
            final want = maxLines <= 0 ? all.length : maxLines;
            final take = want < all.length ? want : all.length;
            final chunk = all.sublist(all.length - take);
            return <String, dynamic>{
              'ok': true,
              'text': chunk.map(jsonEncode).join('\n'),
              // `truncated == (tail.size >= want)` ⇒ "前面可能还有"
              'truncated': maxLines > 0 && take >= maxLines && maxLines < all.length,
            };
          }
          return <String, dynamic>{
            'ok': true,
            'text': '',
            'truncated': false,
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

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installMocks();
    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);
  }

  Future<void> openSession(WidgetTester tester, String title) async {
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    scaffold.openDrawer();
    await settle(tester);
    final row = find.descendant(
      of: find.byType(WorkspaceDrawer),
      matching: find.text(title),
    );
    expect(row, findsOneWidget, reason: '抽屉里应有会话「$title」');
    await tester.tap(row);
    await settle(tester);
  }

  group('T0-2 长会话分页可见部分（SessionStore 尾部读取 + 合成分页行）', () {
    testWidgets('a) 大会话：最新消息可见、无 1MB 气泡、顶部有「加载更早消息」',
        (tester) async {
      await pumpChat(tester);
      await openSession(tester, '会话大');

      // 最新内容必须显示（尾部读取的意义）——
      expect(find.textContaining('L-2399'), findsOneWidget,
          reason: '长会话要看到最新的消息，而不是最早的 1MB');

      // 合成分页行不许再画成气泡（旧行为把它的 text 当 assistant 气泡）
      expect(find.textContaining('1MB'), findsNothing,
          reason: '「会话记录超过通道 1MB…」这类文案不能再出现在对话流里');

      // 顶部要有可点入口
      expect(find.text('加载更早消息'), findsOneWidget,
          reason: '更早的消息没加载时，顶部必须给出加载入口');
    });

    testWidgets('b) 切到普通小会话 ⇒ 横幅消失（状态跟着会话走）', (tester) async {
      await pumpChat(tester);
      await openSession(tester, '会话大');
      expect(find.text('加载更早消息'), findsOneWidget);

      await openSession(tester, '会话小');
      expect(find.text('加载更早消息'), findsNothing,
          reason: '小会话没有"更早"，横幅不能残留');
      expect(find.textContaining('小会话消息'), findsOneWidget);
    });

    testWidgets('c) 真正的读取失败 system 行仍然显示（别把错误也吞了）',
        (tester) async {
      await pumpChat(tester);
      await openSession(tester, '会话坏');

      expect(find.textContaining('磁盘 I/O 错误'), findsOneWidget,
          reason: '读失败的提示必须显示，否则用户以为记录真的没了');
      expect(find.text('加载更早消息'), findsNothing,
          reason: '读失败 ≠ 还有更早的消息（不许误报分页入口）');
    });

    testWidgets('d) 点「加载更早消息」⇒ 真加载上一页，到底后入口消失', (tester) async {
      await pumpChat(tester);
      await openSession(tester, '会话大');

      final scrollable = find.byType(Scrollable).first;
      double extent() =>
          tester.state<ScrollableState>(scrollable).position.maxScrollExtent;
      final before = extent();

      // 2400 行；初始尾部 2000 行（L-400..L-2399）⇒ 第 1 页拿 201 行（L-199..L-399）
      await tester.tap(find.text('加载更早消息'));
      await settle(tester, times: 20);
      expect(find.text('加载更早消息'), findsOneWidget,
          reason: '第一页之后还有更早的（L-0..L-198），入口应保留');
      final afterFirst = extent();
      expect(afterFirst, greaterThan(before),
          reason: '点入口必须真的把上一页插进列表（列表总高度变大）');

      // 第 2 页拿剩下的 199 行 ⇒ 到顶，入口消失
      await tester.tap(find.text('加载更早消息'));
      await settle(tester, times: 20);
      expect(find.text('加载更早消息'), findsNothing,
          reason: '全部加载完（2400 行）后入口必须消失，不能永远显示');
      expect(extent(), greaterThan(afterFirst),
          reason: '第二页也要真的插进列表');

      // 视口保持：最新一条仍在屏幕上（插入上一页不许把用户甩走）
      expect(find.text('L-2399'), findsOneWidget,
          reason: '加载更早消息不能改变用户当前看的位置');
    });
  });
}
