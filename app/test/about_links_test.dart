import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:heracles/screens/oss_licenses_screen.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/theme/app_theme.dart';

/// **关于页 = 真跳转 / 真页面**（2026-10-29 T1 第 5 条）。
///
/// 旧行为（本文件先红证明）：
/// - 「GitHub 仓库」「问题反馈」只把链接写剪贴板 + Toast「链接已复制」；
/// - 「开源许可证」是不可点的一行（点不动，也没有应用内许可页）。
///
/// 新规格：
/// - 两个外链走 `launchUrl(..., mode: LaunchMode.externalApplication)`
///   （系统浏览器打开，**不是**应用内 webview、也**不是**只复制）；
/// - 「开源许可证」push 应用内 `OssLicensesScreen`；
/// - 打开失败（返回 false 或平台异常）Toast「无法打开浏览器」，
///   **不谎报成功**、也不再声称"已复制"。
///
/// 测试走**生产真实路径**：mock `plugins.flutter.io/url_launcher` 通道
/// （生产 `launchUrl` → `MethodChannelUrlLauncher.launch` 的必经之路），
/// 不引入只给测试用的假实现，避免"测试绿的缝和线上不是一条路"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');

  /// 记录到的外跳（`launch` 方法的入参）。
  late List<Map<String, Object?>> launches;
  /// 记录到的剪贴板写入（旧行为会写）。
  late List<Object?> clipboardWrites;
  /// 平台侧是否成功打开浏览器。
  late bool launchResult;
  /// 平台侧是否抛异常（模拟无可用浏览器/ActivityNotFound）。
  late bool launchThrows;

  setUp(() {
    launches = <Map<String, Object?>>[];
    clipboardWrites = <Object?>[];
    launchResult = true;
    launchThrows = false;
    PackageInfo.setMockInitialValues(
      appName: 'Heracles',
      packageName: 'com.theohowie.heracles',
      version: '0.3.2',
      buildNumber: '6',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, (call) async {
      if (call.method == 'launch') {
        launches.add((call.arguments as Map).cast<String, Object?>());
        if (launchThrows) {
          throw PlatformException(
            code: 'ACTIVITY_NOT_FOUND',
            message: 'No Activity found to handle Intent',
          );
        }
        return launchResult;
      }
      // canLaunch 等其它方法：给个可用
      if (call.method == 'canLaunch') return true;
      return null;
    });
    // 剪贴板也 mock 掉：旧实现会 `Clipboard.setData`，不 mock 的话那条
    // Future 会以 MissingPluginException 收尾，把"行为断言"淹没成噪音。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardWrites.add(call.arguments);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget wrap(Widget home) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: home,
      );

  /// 按真机宽度（393dp）起关于页。
  Future<void> pumpAbout(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(const AboutPage()));
    await tester.pump();
  }

  /// 先滚到可见再返回（ListView 会先在缓存区把它构建出来，但可能仍在视口外）。
  Future<void> scrollToRow(WidgetTester tester, String title) async {
    final row = find.text(title);
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable),
    );
    await tester.ensureVisible(row);
    await tester.pump();
  }

  /// 滚到「开源与反馈」里的某一行再点。
  Future<void> tapRow(WidgetTester tester, String title) async {
    await scrollToRow(tester, title);
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 外链必须是「系统浏览器」语义：不是应用内 webview，也不是
  /// universal-links-only 静默探测。
  void expectExternalBrowser(Map<String, Object?> args) {
    expect(args['useWebView'], isFalse,
        reason: '外链必须在系统浏览器打开（旧式 platformDefault 对 http(s) 会走应用内 webview）');
    expect(args['universalLinksOnly'], isFalse,
        reason: '不是 externalNonBrowserApplication（universal links only）');
  }

  testWidgets('★ 点「GitHub 仓库」→ 系统浏览器打开仓库地址（不再是「链接已复制」）',
      (tester) async {
    await pumpAbout(tester);
    await tapRow(tester, 'GitHub 仓库');

    expect(launches, hasLength(1), reason: '点一次必须真的外跳一次');
    expect(launches.single['url'], 'https://github.com/theohowie/Heracles');
    expectExternalBrowser(launches.single);
    expect(clipboardWrites, isEmpty, reason: '新行为是跳转，不再往剪贴板塞链接');
    expect(find.text('链接已复制'), findsNothing);
  });

  testWidgets('★ 点「问题反馈」→ 系统浏览器打开 issues 地址', (tester) async {
    await pumpAbout(tester);
    await tapRow(tester, '问题反馈');

    expect(launches, hasLength(1));
    expect(launches.single['url'],
        'https://github.com/theohowie/Heracles/issues');
    expectExternalBrowser(launches.single);
    expect(clipboardWrites, isEmpty);
    expect(find.text('链接已复制'), findsNothing);
  });

  testWidgets('★★ 点「开源许可证」→ 应用内完整许可页（不是外跳、不是复制）',
      (tester) async {
    await pumpAbout(tester);
    await scrollToRow(tester, '开源许可证');
    await tester.tap(find.text('开源许可证'));
    await tester.pumpAndSettle();

    expect(find.byType(OssLicensesScreen), findsOneWidget,
        reason: '必须在应用内打开完整许可列表');
    expect(launches, isEmpty, reason: '许可证不走浏览器');
    expect(clipboardWrites, isEmpty);
  });

  testWidgets('★★ 浏览器打不开（平台返回 false）⇒ Toast「无法打开浏览器」，不谎报成功',
      (tester) async {
    launchResult = false;
    await pumpAbout(tester);
    await tapRow(tester, 'GitHub 仓库');
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('无法打开浏览器'), findsOneWidget,
        reason: '打开失败必须如实说，不能让用户以为已经打开了');
    expect(find.text('链接已复制'), findsNothing,
        reason: '失败时更不能骗用户"已复制"');
    // 让 Toast 的 2.2s 定时器走完，避免 pending Timer 收尾
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('★★ 平台抛异常（无 Activity 处理）也走失败 Toast', (tester) async {
    launchThrows = true;
    await pumpAbout(tester);
    await tapRow(tester, '问题反馈');
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('无法打开浏览器'), findsOneWidget,
        reason: '平台异常不能让点击静默失败（用户点了没反应 = 最差体验）');
    await tester.pump(const Duration(seconds: 3));
  });

  // -------------------------------------------------------------------------
  // 注入缝（生产默认真跳转；注入只为断言**精确的 LaunchMode 与 URL**）
  // -------------------------------------------------------------------------

  testWidgets('★ 注入 opener：两条外链都以 externalApplication 打开各自地址',
      (tester) async {
    final opened = <(Uri, LaunchMode)>[];
    await tester.pumpWidget(wrap(AboutPage(
      urlOpener: (url, mode) async {
        opened.add((url, mode));
        return true;
      },
    )));
    await tester.pump();
    await tapRow(tester, 'GitHub 仓库');
    await tapRow(tester, '问题反馈');

    expect(opened.map((e) => e.$1.toString()).toList(), <String>[
      'https://github.com/theohowie/Heracles',
      'https://github.com/theohowie/Heracles/issues',
    ]);
    expect(opened.map((e) => e.$2).toList(),
        everyElement(LaunchMode.externalApplication),
        reason: '必须显式要求系统浏览器，不能吃平台默认（http(s) 会落应用内 webview）');
    // 注入实现运行时，真实插件通道根本不该被碰
    expect(launches, isEmpty);
    expect(clipboardWrites, isEmpty);
  });

  testWidgets('★★ 注入 opener 抛异常 ⇒ 仍是失败 Toast，不静默', (tester) async {
    await tester.pumpWidget(wrap(AboutPage(
      urlOpener: (url, mode) async => throw StateError('boom'),
    )));
    await tester.pump();
    await tapRow(tester, 'GitHub 仓库');
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('无法打开浏览器'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
