// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 后台保活引导卡**（2026-11-02，对应 #2/T0）：
// 只做状态与引导，不实现保活；必须写明「Android 不保证永不被杀」。
//
// 2026-11-02（F-B）：「未就绪」变成「可行动」——
//   · 未开启 ⇒ 必须有可点的「去授权」，且点击真的调通道（mock 断言调用数）；
//   · 已开启 ⇒ 不给按钮；
//   · autostartGuide 的路径**原样上屏**（契约：只引导，不自动跳转）；
//   · 通道不返回（MissingPluginException 被 bridge 收敛为 null）⇒
//     点了之后不许假成功 —— 明说「当前版本不支持」，不引导重试（见下方三态组）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/background_keepalive_card.dart';

const _cmdChannel = MethodChannel('heracles/command');

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  /// 通道 mock：记录 requestIgnoreBatteryOptimizations 的调用次数，
  /// autostartGuide 返回小米的引导路径（真实形状 {brand, path}）。
  void installChannelMock({required List<int> batteryCalls}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cmdChannel, (call) async {
      switch (call.method) {
        case 'requestIgnoreBatteryOptimizations':
          batteryCalls.add(1);
          return true;
        case 'autostartGuide':
          return {
            'brand': '小米',
            'path': '设置→应用设置→应用管理→本应用→自启动',
          };
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cmdChannel, null));
  }

  testWidgets('★★ 三行状态 + 出路 + 必须写明"不保证永不被杀"', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    expect(find.text('后台运行'), findsOneWidget);
    expect(find.text('前台服务'), findsOneWidget);
    expect(find.text('电池优化'), findsOneWidget);
    expect(find.text('自启动'), findsOneWidget);
    // 无接口 ⇒ 如实"未检测到"，不编"已开启"
    expect(find.textContaining('未检测到'), findsWidgets);
    // ★ F-B：未就绪 ≠ 没有出路 —— 必须有可点的「去授权」
    final action = find.byKey(const Key('background-battery-action'));
    expect(action, findsOneWidget,
        reason: '未开启时必须有可点的「去授权」—— 只写"未就绪"没有任何出路是本卡的老毛病');
    expect(tester.widget<TextButton>(action).onPressed, isNotNull,
        reason: '按钮必须可点（通道已落地）');
    // 打开自启动管理的兜底说明仍在（通道没返回时不编路径）
    expect(find.textContaining('MIUI：设置→应用设置'), findsOneWidget);
    expect(find.textContaining('Android 不保证永不被杀'), findsOneWidget,
        reason: '文案必须讲清系统仍可能停止后台任务');
  });

  testWidgets('★ 上次被系统停止 ⇒ 下次打开如实提示（不许假装还在跑）',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      BackgroundKeepaliveCard.prefsLastKilled: '今天 09:12',
      BackgroundKeepaliveCard.prefsBatteryIgnored: true,
    });
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background-last-killed')), findsOneWidget);
    expect(find.textContaining('上次任务在后台被系统停止'), findsOneWidget);
    expect(find.textContaining('已忽略'), findsOneWidget);
    // ★ F-B：已开启 ⇒ 不给按钮（再点一次只会重复拉系统页）
    expect(find.byKey(const Key('background-battery-action')), findsNothing,
        reason: '已忽略状态下不许再出现「去授权」—— 状态如实，按钮跟着状态走');
  });

  testWidgets('★★ 未就绪 + 点「去授权」⇒ 真的调了通道（mock 断言调用数）',
      (tester) async {
    final batteryCalls = <int>[];
    installChannelMock(batteryCalls: batteryCalls);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('background-battery-action')));
    await tester.pumpAndSettle();

    expect(batteryCalls, hasLength(1),
        reason: '点「去授权」必须调用 requestIgnoreBatteryOptimizations —— '
            '按钮只画不调就是又一个假入口');
  });

  testWidgets('★★ autostartGuide 的路径原样上屏（只引导，不自动跳转）',
      (tester) async {
    final batteryCalls = <int>[];
    installChannelMock(batteryCalls: batteryCalls);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    // {brand, path} 原样拼接上屏，一个字不许改（用户要照着找开关）
    expect(find.textContaining('小米：设置→应用设置→应用管理→本应用→自启动'),
        findsOneWidget,
        reason: 'autostartGuide 的引导路径必须原样展示 —— 改写/省略都会把用户带丢');
    // 兜底 OEM 说明不再出现（真实路径已拿到）
    expect(find.textContaining('EMUI：手机管家'), findsNothing);
  });

  testWidgets('★★ 通道不返回 ⇒ 点了不许假成功（明说"没有生效"）', (tester) async {
    // 不装 mock：MethodChannel 无 handler ⇒ invokeMethod 的 Future
    // 永不完成？—— 不。bridge 对 MissingPluginException/PlatformException
    // 都收敛为 false（agent_bridge.dart），所以这里直接断言 UI 行为：
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    // 无 handler 时 invokeMethod 永不完成（见 secure_storage_mock 的说明）
    // ⇒ bridge 的调用挂住 ⇒ 按钮保持「打开中…」锁定，绝不假成功。
    expect(find.textContaining('已忽略'), findsNothing,
        reason: '通道没通就显示"已忽略"是编状态');
    expect(find.textContaining('没有生效'), findsNothing,
        reason: '调用尚未返回时不得提前宣布失败');
    expect(find.byKey(const Key('background-battery-note')), findsNothing);
  });

  // ==========================================================================
  // ★★ 2026-11-02 二次裁定：三态不许混（MissingPluginException ≠ false）
  // ==========================================================================
  // 旧实现把 MissingPluginException 吞成 false ⇒ 旧宿主上用户点「去授权」
  // 会看到"没有生效，可再试"，于是反复重试一个**根本不存在的方法**。
  // 「环境不支持」与「这次没成功」是两种失败，给用户的话术必须不同。
  group('三态：null = 不支持 / false = 没生效 / true = 已确认', () {
    test('★★★ bridge：通道缺失（MissingPluginException）⇒ null，不是 false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cmdChannel, (call) async {
        if (call.method == 'requestIgnoreBatteryOptimizations') {
          throw MissingPluginException('旧宿主没有这条通道');
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cmdChannel, null));

      final r = await AgentBridge().requestIgnoreBatteryOptimizations();
      expect(r, isNull,
          reason: 'null = "当前版本不支持"；吞成 false 会引导用户无限重试');
    });

    test('★★ bridge：PlatformException ⇒ false（这次没成功，不是"不支持"）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cmdChannel, (call) async {
        if (call.method == 'requestIgnoreBatteryOptimizations') {
          throw PlatformException(code: 'unavailable', message: '系统拒绝');
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cmdChannel, null));

      final r = await AgentBridge().requestIgnoreBatteryOptimizations();
      expect(r, isFalse, reason: '调用失败 ≠ 环境不支持');
    });

    testWidgets('★★★ 通道缺失 ⇒ 明说"当前版本不支持"，不引导重试', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cmdChannel, (call) async {
        if (call.method == 'requestIgnoreBatteryOptimizations') {
          throw MissingPluginException('旧宿主没有这条通道');
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cmdChannel, null));
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('background-battery-action')));
      await tester.pumpAndSettle();

      expect(find.textContaining('当前版本不支持'), findsOneWidget,
          reason: '环境不支持必须直说，让用户放弃重试这条死路');
      expect(find.textContaining('可再试一次'), findsNothing,
          reason: '方法根本不存在，"可再试"是把用户往死路上引');
    });

    testWidgets('★★ 返回 false ⇒ "没有生效，可再试"（不是"不支持"）', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cmdChannel, (call) async {
        if (call.method == 'requestIgnoreBatteryOptimizations') {
          // 模拟"用户在授权页取消"：通道在，但这次没成功
          return false;
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_cmdChannel, null));
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('background-battery-action')));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有生效'), findsOneWidget);
      expect(find.textContaining('可再试一次'), findsOneWidget,
          reason: '通道在、只是这次没成功 ⇒ 应该鼓励再试');
      expect(find.textContaining('当前版本不支持'), findsNothing,
          reason: '明明有通道，说"不支持"是假信息');
    });
  });
}
