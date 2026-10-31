import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/screens/sandbox_screen.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';

import 'support/secure_storage_mock.dart';

/// **沙箱设置页测试**（2026-10-28）：用 mock 的 `heracles/sandbox`
/// 通道驱动真页面 —— 状态/激活/挂载/通道/重置全链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('heracles/sandbox');
  var installed = false;
  /// T2 编译环境是否已装（2026-10-29 新增）
  var suiteReady = false;
  final calls = <String>[];

  Map<String, Object?> statusMap() => {
        'ok': true,
        'installed': installed,
        'rootfsSummary':
            installed ? 'bundled-minimal (source=1, 9040693 B, snapshots=0)' : '',
        'prootReady': installed,
        'channels': [
          {'type': 0, 'name': '普通 App', 'available': true, 'reason': '', 'risk': 0},
          // 原因用真机实测的整句长文（2026-10-28 截图）：短数据测不出溢出，
          // 通道行曾经就因为这句长原因把通道名挤成竖排单字。
          {
            'type': 1,
            'name': 'Shizuku',
            'available': false,
            'reason': 'Shizuku 未授权本应用：到权限步骤申请 Shizuku 授权',
            'risk': 1,
          },
          {
            'type': 2,
            'name': 'Root',
            'available': false,
            'reason': '设备没有 su：需解锁 bootloader 并刷入 Magisk / KernelSU 后再试',
            'risk': 2,
          },
        ],
      };

  setUp(() {
    installed = false;
    calls.clear();
    // ★ 必须装：SettingsController.load() 会 await 安全存储读取，
    //   该通道在测试里没 handler 时 Future 永不完成（不是抛异常），
    //   第 4 个测试会整份卡死。见 support/secure_storage_mock.dart。
    installSecureStorageMock();    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
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
          // ---- T2 编译环境（2026-10-29）----
          "buildSuiteStatus" => {
              "ok": true,
              "ready": suiteReady,
              "version": suiteReady ? "t2-2026-10-29" : "",
              "installDir": "/data/x/opt/t2",
              "parts": {
                "jdk": suiteReady,
                "gradle": suiteReady,
                "androidJar": suiteReady,
              },
            },
          "activateBuildSuite" => (suiteReady = true, {
                  "ok": true,
                  "message": "编译环境已就绪",
                  "alreadyReady": false,
                  "ready": true,
                })
              .$2,
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

  /// 按真机宽度（393dp）跑：默认 800 宽测不出窄屏溢出
  /// （通道行 2026-10-28 就是在真机上才翻的车）。
  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

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
    usePhoneSurface(tester);
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
    // 通道行：名字完整、状态词在，长原因独占一行（不溢出才找得到整句）
    expect(find.text('普通 App'), findsOneWidget);
    expect(find.text('Shizuku'), findsOneWidget);
    expect(find.text('Root'), findsOneWidget);
    expect(find.text('不可用'), findsWidgets);
    expect(find.textContaining('未授权本应用'), findsOneWidget);
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

  testWidgets('★★ 重置确认抽屉：只有壳自带的一只抓手（不自绘）', (tester) async {
    installed = true;
    await tester.pumpWidget(wrap(const SandboxScreen()));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('重置沙箱'), 120);
    await tester.tap(find.text('重置沙箱'));
    await tester.pumpAndSettle();
    expect(find.text('重置沙箱？'), findsOneWidget);
    // T2-4：抽屉统一（共享壳 + 共享抓手），本页不许再自绘抓手
    expect(find.byType(BwSheetShell), findsOneWidget);
    expect(tester.widget<BwSheetShell>(find.byType(BwSheetShell)).showHandle,
        isTrue);
    expect(find.byType(BwSheetHandle), findsOneWidget);
    final bars = tester
        .widgetList(find.byWidgetPredicate((w) {
          if (w is! Container) return false;
          final c = w.constraints;
          return c != null &&
              c.minWidth == 36 &&
              c.maxWidth == 36 &&
              c.minHeight == 4 &&
              c.maxHeight == 4;
        }))
        .length;
    expect(bars, 1, reason: '沙箱抽屉里出现 $bars 条 36×4 抓手（应只有共享那一只）');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
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

  // ==========================================================================
  // T2 编译环境（2026-10-29）—— 真机 bug：整行点击无响应，改成明确的按钮
  // ==========================================================================
  group("T2 编译环境", () {
    testWidgets("★ 未安装时有「下载」真按钮（不再依赖整行手势）", (tester) async {
      installed = true;
      usePhoneSurface(tester);
      await tester.pumpWidget(wrap(const SandboxScreen()));
      await tester.pump();

      expect(find.text("编译环境 · 未安装"), findsOneWidget);
      // 关键：必须能找到一个**按钮**，而不是靠点整行
      expect(find.widgetWithText(FilledButton, "下载"), findsOneWidget,
          reason: "真机整行 tap 不响应，必须给明确按钮");
      // 缺哪项要说清（不能只写"未安装"）
      expect(find.textContaining("缺 JDK 17"), findsOneWidget);
    });

    testWidgets("★★ 点「下载」→ 弹确认抽屉（写清体积）", (tester) async {
      installed = true;
      usePhoneSurface(tester);
      await tester.pumpWidget(wrap(const SandboxScreen()));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, "下载"));
      await tester.pumpAndSettle();

      expect(find.text("下载编译环境？"), findsOneWidget);
      expect(find.textContaining("415 MB"), findsWidgets,
          reason: "415 MB 必须如实写出来，不能让用户不知情花流量");
      expect(find.textContaining("续传"), findsOneWidget);
    });

    testWidgets("★★★ 确认 → 真的调用 activateBuildSuite，状态变已就绪",
        (tester) async {
      installed = true;
      usePhoneSurface(tester);
      await tester.pumpWidget(wrap(const SandboxScreen()));
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, "下载"));
      await tester.pumpAndSettle();
      // 抽屉里的确认按钮（与卡片按钮同文案，取最后一个）
      await tester.tap(find.text("下载").last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls, contains("activateBuildSuite"), reason: "必须真的下发激活");
      await tester.pumpAndSettle();
      expect(find.text("编译环境 · 已就绪"), findsOneWidget);
      expect(find.widgetWithText(FilledButton, "下载"), findsNothing,
          reason: "已就绪后不该再显示下载按钮");
        // 让轻提示的 2.2s 定时器走完，否则测试以 pending Timer 收尾
        await tester.pump(const Duration(seconds: 3));
    });
  });
}
