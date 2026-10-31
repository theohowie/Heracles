// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **T2-6 端到端：用户从未显式选过 provider 时，模型抽屉仍要标「当前」**。
//
// 真因链（跨两个文件）：
//   · 输入框胶囊显示 `providerLabel: provider?.model`，provider =
//     `AppSettings.effectiveProvider`（active=null 时自动选中第一个）；
//   · 模型抽屉判据是 `currentProviderId ?? activeProviderId`，
//     调用点若不把 effective id 传下去，抽屉里「当前」一个都没有。
// ⇒ 本文件从 **ChatScreen**（真实调用点）点胶囊打开抽屉，钉这条链路；
//   抽屉自身的单元行为由 `model_sheet_current_test.dart` 覆盖。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/agent_bridge.dart' show AgentBridge;
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart' show BwOptionCard;

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
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
    AgentBridge.executorFactoryForTest = null;
  });

  /// 单 provider、**从不设置 activeProviderId** ⇒ effective 自动选中它。
  Future<SettingsController> freshController() async {
    SharedPreferences.setMockInitialValues({});
    final c = await SettingsController.load();
    await c.updateProvider(const ModelProviderConfig(
      id: 'deepseek-account',
      name: '唯一模型',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'm-one',
      apiKey: 'sk-test',
    ));
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

  Future<void> settle(WidgetTester tester, {int times = 14}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('★★ active=null + 单 provider ⇒ 聊天页点胶囊，抽屉里有「当前」',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installMocks();
    final c = await freshController();
    expect(c.value.activeProviderId, isNull, reason: '前置：用户从未显式点选');
    expect(c.value.effectiveProvider?.id, 'deepseek-account', reason: '前置：effective 自动选中默认 provider');

    await tester.pumpWidget(wrap(c, ChatScreen(settings: c)));
    await settle(tester);

    // 胶囊显示的是 effective 的模型名（不是空）
    expect(find.text('m-one'), findsOneWidget,
        reason: '前置：输入框胶囊显示当前模型');
    await tester.tap(find.text('m-one'));
    await settle(tester, times: 20);

    // 抽屉里必须标出「当前」—— 否则用户不知道正在用哪个
    expect(find.text('当前'), findsOneWidget,
        reason: 'T2-6：胶囊有模型名，抽屉里就必须有『当前』（调用点要传 effectiveProvider?.id）');
    // 且徽标必须挂在 p1 那张卡上（不是随便一处文案）
    expect(
      find.descendant(
        of: find.ancestor(
            of: find.text('m-one'), matching: find.byType(BwOptionCard)).last,
        matching: find.text('当前'),
      ),
      findsOneWidget,
      reason: '「当前」必须长在当前 provider 的卡片里',
    );
  });
}
