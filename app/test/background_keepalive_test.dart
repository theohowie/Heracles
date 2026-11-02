// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 后台保活引导卡**（2026-11-02，对应 #2/T0）：
// 只做状态与引导，不实现保活；必须写明「Android 不保证永不被杀」。
//
// 2026-11-02 第三版（行样式与权限页统一 + 四行各有出路）：
//   · 每行至少一种出路（按钮 / 复制 / 路径文案）—— 死行必须红；
//   · 电池优化三态：已开启（胶囊）/ 去授权 / 通道不可用（当前版本不支持）；
//   · popup / 锁屏两行在 oemGuide 落地前**整行隐藏，不画死行**；
//   · autostartGuide 路径原样上屏 + 复制到剪贴板（toast），不自动跳转。

import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/background_keepalive_card.dart';

const _cmdChannel = MethodChannel('heracles/command');
const _xiaomiAutostart = '小米：设置→应用设置→应用管理→本应用→自启动';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  /// 通道 mock：processKilled 应答（通道探针）、autostartGuide 返回小米
  /// 路径（真实形状 {brand, path}）、requestIgnoreBatteryOptimizations 记数。
  void installChannelMock({
    required List<int> batteryCalls,
    Object? processKilledResult,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cmdChannel, (call) async {
      switch (call.method) {
        case 'processKilled':
          if (processKilledResult is Exception) throw processKilledResult;
          return processKilledResult ?? {'killed': false, 'killedAt': 0};
        case 'requestIgnoreBatteryOptimizations':
          batteryCalls.add(1);
          return true;
        // ★ 2026-11-02：autostartGuide 已改为 oemGuide('autostart') 的薄封装
        //   （契约 §N18.2，只增）—— mock 跟着通道走，断言本身不变
        case 'autostartGuide':
        case 'oemGuide':
          return {
            'ok': true,
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

  /// toast 用 `Future.delayed(2200ms)` 自收（cupertino_kit）——
  /// 测试末尾把计时器走完，否则 teardown 报 Timer is still pending。
  Future<void> drainToast(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 2400));
  }

  /// 剪贴板捕获：`Clipboard.getData` 在测试里没有默认 handler
  /// ⇒ Future 永不完成（坑 36 同族）—— 所以在 `flutter/platform`
  /// 通道层截住 `Clipboard.setData`，把文本记下来供断言。
  /// ⚠️ 该通道是 `JSONMethodCodec`：arguments 是 JSON **字符串**，要先解码。
  ValueNotifier<String?> installClipboardCapture() {
    final captured = ValueNotifier<String?>(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments;
        if (args is Map) {
          captured.value = args['text'] as String?;
        } else if (args is String) {
          captured.value = (jsonDecode(args) as Map)['text'] as String?;
        }
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    return captured;
  }

  testWidgets('★★ 四行各有出路：说明层 / 去授权 / 复制，行样式同权限页规格',
      (tester) async {
    final batteryCalls = <int>[];
    installChannelMock(batteryCalls: batteryCalls);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    // ★ 样式规格：三行（前台服务/电池优化/自启动）全部用同一行组件
    //   （popup/锁屏两行未落地 ⇒ 隐藏，不画死行）
    expect(find.byType(KeepaliveRow), findsNWidgets(3),
        reason: '三行必须复用同一行规格组件 —— 不许发明第二套行样式');
    expect(find.text('前台服务'), findsOneWidget);
    expect(find.text('忽略电池优化'), findsOneWidget);
    expect(find.text('自启动'), findsOneWidget);

    // ---- 出路 1：前台服务「查看说明」→ 弹说明层（不是死文案） ----
    await tester.tap(find.byKey(const Key('keepalive-fg-explain')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keepalive-fg-explain-sheet')), findsOneWidget,
        reason: '「查看说明」必须真的弹出解释层 —— 只放死文案就是死行');
    expect(find.textContaining('前台服务'), findsWidgets);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    // ---- 出路 2：电池优化「去授权」可点且真的调通道 ----
    final action = find.byKey(const Key('background-battery-action'));
    expect(action, findsOneWidget);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(batteryCalls, hasLength(1),
        reason: '点「去授权」必须调用 requestIgnoreBatteryOptimizations');

    // ---- 出路 3：自启动「复制」→ 剪贴板 == 路径原样 + toast ----
    final clipText = installClipboardCapture();
    await tester.tap(find.byKey(const Key('keepalive-autostart-copy')));
    await tester.pumpAndSettle();
    expect(clipText.value, _xiaomiAutostart,
        reason: '复制进剪贴板的必须是 autostartGuide 的路径原样（用户要照着找开关）');
    expect(find.textContaining('已复制自启动路径'), findsOneWidget,
        reason: '复制后必须有 toast 确认 —— 静默复制等于没反馈');
    await drainToast(tester);

    // 路径原样上屏
    expect(find.textContaining(_xiaomiAutostart), findsOneWidget);
    // 底线文案
    expect(find.textContaining('Android 不保证永不被杀'), findsOneWidget,
        reason: '文案必须讲清系统仍可能停止后台任务');
  });

  testWidgets('★ 电池优化已开启 ⇒ 状态胶囊，不给按钮', (tester) async {
    installChannelMock(batteryCalls: <int>[]);
    SharedPreferences.setMockInitialValues(<String, Object>{
      BackgroundKeepaliveCard.prefsBatteryIgnored: true,
      BackgroundKeepaliveCard.prefsLastKilled: '今天 09:12',
    });
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    expect(find.text('已开启'), findsOneWidget,
        reason: '已开启要明确显示状态');
    expect(find.byKey(const Key('background-battery-action')), findsNothing,
        reason: '已开启不许再出现「去授权」—— 状态如实，按钮跟着状态走');
    expect(find.byKey(const Key('background-last-killed')), findsOneWidget);
    expect(find.textContaining('上次任务在后台被系统停止'), findsOneWidget);
  });

  testWidgets('★★ 通道缺失（null）⇒ 「当前版本不支持」，不引导重试',
      (tester) async {
    // 后端三态（2026-11-02 二次裁定）：requestIgnore 返回 null = 旧宿主
    // 没有这条通道。mock 里让它返回 null，用户点了「去授权」之后：
    // 胶囊换成「当前版本不支持」，话术里**不许出现"可再试"**（试多少次都一样）。
    var batteryCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cmdChannel, (call) async {
      switch (call.method) {
        case 'processKilled':
          return {'killed': false, 'killedAt': 0};
        case 'requestIgnoreBatteryOptimizations':
          batteryCalls++;
          // ⚠️ 必须在 handler 里**抛**：mock 返回 null 会被当成"未处理"
          //   而挂起（坑 36），不会变成 MissingPluginException。
          throw MissingPluginException('no handler'); // 通道缺失
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
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    // 先有按钮（没点之前不知道通道缺不缺）
    expect(find.byKey(const Key('background-battery-action')), findsOneWidget);
    await tester.tap(find.byKey(const Key('background-battery-action')));
    await tester.pumpAndSettle();
    expect(batteryCalls, 1);

    expect(
        find.byKey(const Key('keepalive-battery-unsupported')), findsOneWidget,
        reason: '通道缺失必须换成「当前版本不支持」—— 不许让用户反复白点');
    expect(find.text('当前版本不支持'), findsOneWidget);
    expect(find.textContaining('不引导重试') , findsNothing); // 文案里没有这三个字也行，钉话术：
    expect(find.textContaining('可再试'), findsNothing,
        reason: '通道缺失与"没生效"必须区分 —— 缺失态不许引导重试');
    expect(find.textContaining('可在系统设置里手动配置'), findsOneWidget,
        reason: '要给用户留出出路：后台保活仍可手动配置');
  });

  testWidgets('★ popup / 锁屏两行在 oemGuide 落地前整行隐藏（不画死行）',
      (tester) async {
    installChannelMock(batteryCalls: <int>[]);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(wrap(const BackgroundKeepaliveCard()));
    await tester.pumpAndSettle();

    expect(find.text('后台弹出界面'), findsNothing,
        reason: 'oemGuide(backgroundPopup) 未落地 ⇒ 整行隐藏 —— 画出来就是死行');
    expect(find.text('锁屏显示'), findsNothing,
        reason: 'oemGuide(lockScreenShow) 未落地 ⇒ 整行隐藏');
  });
}
