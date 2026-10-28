import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/screens/sandbox_screen.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';

import 'support/secure_storage_mock.dart';

/// **沙箱设置页测试**（2026-10-28）：用 mock 的 `heracles/sandbox`
/// 通道驱动真页面 —— 状态/激活/挂载/通道/重置全链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('heracles/sandbox');
  var installed = false;
  final calls = <String>[];

  Map<String, Object?> statusMap() => {
        'ok': true,
        'installed': installed,
        'rootfsSummary':
            installed ? 'bundled-minimal (source=1, 9040693 B, snapshots=0)' : '',
        'prootReady': installed,
        'channels': [
          {'type': 0, 'name': '应用内执行', 'available': true, 'reason': '', 'risk': 0},
          {'type': 1, 'name': 'Shizuku', 'available': false, 'reason': '未连接', 'risk': 1},
        ],
      };

  setUp(() {
    installed = false;
    calls.clear();
    // ★ 必须装：SettingsController.load() 会 await 安全存储读取，
    //   该通道在测试里没 handler 时 Future 永不完成（不是抛异常），
    //   第 4 个测试会整份卡死。见 support/secure_storage_mock.dart。
    installSecureStorageMock();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'status' => statusMap(),
        'activate' => (installed = true, statusMap()).$2,
        'reset' => (installed = false, statusMap()).$2,
        'listMounts' => {
            'ok': true,
            'mounts': installed
                ? [
                    {
                      'name': 'workspace',
                      'backend': 1,
                      'readOnly': false,
                      'bindTo': '/workspace',
                      'description': '当前项目目录',
                    },
                    {
                      'name': 'libs',
                      'backend': 0,
                      'readOnly': true,
                      'bindTo': '',
                      'description': '内置库',
                    },
                  ]
                : <Object?>[],
          },
        _ => {'ok': true},
      };
    });
  });

  tearDown(() {
    removeSecureStorageMock();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget wrap(Widget home) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: home,
      );

  testWidgets('未激活：状态卡 + 激活按钮，挂载区是占位文案', (tester) async {
    await tester.pumpWidget(wrap(const SandboxScreen()));
    await tester.pump();
    expect(find.text('未激活'), findsOneWidget);
    expect(find.text('激活沙箱'), findsOneWidget);
    expect(find.textContaining('激活后显示'), findsOneWidget);
    expect(find.text('重置沙箱'), findsNothing);
  });

  testWidgets('点激活 → 通道 activate 被调 → 状态变已激活、挂载出现',
      (tester) async {
    await tester.pumpWidget(wrap(const SandboxScreen()));
    await tester.pump();
    await tester.tap(find.text('激活沙箱'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, contains('activate'));
    expect(find.text('已激活'), findsOneWidget);
    expect(find.text('@workspace'), findsOneWidget);
    expect(find.text('@libs'), findsOneWidget);
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('读写'), findsOneWidget);
    // 通道行
    expect(find.text('应用内执行'), findsOneWidget);
    expect(find.text('Shizuku'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    // 让「已激活」轻提示的 2.2 秒定时器走完，免得测试以 pending Timer 收尾
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('重置：确认抽屉 → reset 被调 → 回到未激活', (tester) async {
    installed = true;
    await tester.pumpWidget(wrap(const SandboxScreen()));
    await tester.pump();
    expect(find.text('已激活'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('重置沙箱'), 120);
    await tester.tap(find.text('重置沙箱'));
    await tester.pumpAndSettle();
    // 确认抽屉里的「重置」按钮
    await tester.tap(find.text('重置').last);
    await tester.pumpAndSettle();
    expect(calls, contains('reset'));
    expect(find.text('未激活'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('设置主页有沙箱入口且副行带状态', (tester) async {
    SharedPreferences.setMockInitialValues({});
    installed = true;
    final controller = await SettingsController.load();
    await tester.pumpWidget(wrap(SettingsScreen(controller: controller)));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('沙箱'), 120);
    expect(find.text('沙箱'), findsOneWidget);
    expect(find.textContaining('已激活'), findsWidgets);
  });
}
