// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **第 3 条 P1：权限页弹性开关不得"假翻"**（2026-10-29 用户反馈）。
//
// 旧行为：ElasticSwitch 点按立即乐观动画；权限页 `_refresh` 重查后真实值没变
// （仍 granted / 仍 denied）⇒ didUpdateWidget 不回弹 ⇒ **假状态停到页面重建**。
// 叠加另一个事实：Android 不允许 App 自己撤销运行时权限，旧代码关麦克风时
// 直接拉 appSettings，界面却先翻成"关"——用户以为关掉了。
//
// 规格：
//   · 关闭 已授的 mic/camera/media/calendar ⇒ 打开应用详情页 + 解释"系统不允许 App 自行关闭权限"，
//     开关**保持真实状态**（不预演）；
//   · notifications 关闭仍走通知设置页（notificationsOff，不改 appSettings）；
//   · accessibility / overlay 只打开对应系统页；
//   · unknown 显示「检测中」并禁用（不给一个拨了也没反应的假开关）；
//   · automation 的「接口预留」pill 不变。
//
// 本文件钉住（channels 用 MethodChannel mock，不碰真机）：
//   ① 关麦克风：开关不假翻、拉起 appSettings、亮出原因文案
//   ② 关通知：拉起的是 notificationsOff（不是 appSettings）
//   ③ 未知状态：显示「检测中」且该行没有可拨开关
//   ④ 无障碍：点按拉起 accessibility 系统页（值不变也不假翻）

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/elastic_switch.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('heracles/command');
  late List<String> requested;
  late Map<String, String> perms;

  setUp(() {
    requested = <String>[];
    perms = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'devicePermission':
          return <String, dynamic>{
            'writeSecureSettings': false,
            'guidance': '',
            'shizuku': <String, dynamic>{},
          };
        case 'devicePermissions':
          return perms;
        case 'requestPermission':
          final kind = (call.arguments as Map)['kind'] as String;
          requested.add(kind);
          return <String, dynamic>{'ok': true};
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(wrap(const DevicePermissionPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }

  /// 权限行本身（名称 Text 的最近 Padding 祖先），再在其下找开关。
  Finder rowFor(String label) => find
      .ancestor(of: find.text(label), matching: find.byType(Padding))
      .first;

  Finder switchFor(String label) =>
      find.descendant(of: rowFor(label), matching: find.byType(ElasticSwitch));

  /// 弹性开关圆钮的 left（关 ≈ 2，开 ≈ 22）：用来识别"视觉上预演了没有"。
  double knobLeft(WidgetTester tester, Finder sw) => tester
      .widget<Positioned>(
        find
            .descendant(of: sw, matching: find.byType(Positioned))
            .last,
      )
      .left!;

  testWidgets('① 关已授麦克风：不假翻 + 拉起应用详情页 + 亮出原因', (tester) async {
    perms = {'microphone': 'granted'};
    await pumpPage(tester);

    final mic = switchFor('麦克风');
    expect(mic, findsOneWidget);
    expect(tester.widget<ElasticSwitch>(mic).value, isTrue,
        reason: '前置：真实状态是已授权');

    final knobOn = knobLeft(tester, mic);
    await tester.tap(mic);
    await tester.pump();
    // 800ms：走完"点按动画/700ms 延时重查"的窗口，但 Toast 还没到 2.2s 停留；
    // 这里同时检查视觉与解释文案（旧实现此刻旋钮已滑到"关"）。
    await tester.pump(const Duration(milliseconds: 800));

    // ① 真实值没变 ⇒ 开关必须还是"开"，不许预演成关（旧行为会翻成关）
    expect(tester.widget<ElasticSwitch>(mic).value, isTrue,
        reason: '权限页开关只跟真实查询值走');
    expect(knobLeft(tester, mic), knobOn,
        reason: '点按后旋钮动了 = 假状态预演（旧行为缺陷）');

    // ② 关闭只能去应用详情页手动撤
    expect(requested, contains('appSettings'));

    // ③ 必须有人话解释，不能默默什么都不发生
    expect(find.textContaining('系统不允许 App 自行关闭权限'), findsWidgets,
        reason: '用户点关必须被告知为什么关不掉、该去哪关');

    // 收尾：让 Toast 的 2.2s 停留计时走完，避免测试结束报 pending timer
    await tester.pump(const Duration(milliseconds: 2600));
    await tester.pump();
  });

  testWidgets('② 关通知：走通知设置页（notificationsOff），不改 appSettings', (tester) async {
    perms = {'notifications': 'granted'};
    await pumpPage(tester);

    final sw = switchFor('通知');
    expect(sw, findsOneWidget);
    await tester.tap(sw);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();

    expect(requested, contains('notificationsOff'),
        reason: '通知关闭只能在通知设置页操作');
    expect(requested, isNot(contains('appSettings')),
        reason: '通知不该被带去应用详情页（2026-10-27 用户定）');
    expect(tester.widget<ElasticSwitch>(sw).value, isTrue,
        reason: '真实值未变 ⇒ 不假翻');
  });

  testWidgets('③ 未知状态：显示「检测中」并禁用，不给假开关', (tester) async {
    // 只给 microphone，其余项在通道里没有数据 ⇒ unknown
    perms = {'microphone': 'granted'};
    await pumpPage(tester);

    expect(find.text('检测中'), findsWidgets,
        reason: 'unknown 必须如实显示"检测中"，不能画成关');
    expect(switchFor('日历'), findsNothing,
        reason: 'unknown 的行不许出现可拨开关（拨了也没反应 = 假开关）');

    // automation 的「接口预留」pill 不许改坏
    expect(find.text('接口预留'), findsOneWidget);
  });

  testWidgets('④ 无障碍：点按拉起 accessibility 系统页，值不变也不假翻', (tester) async {
    perms = {'accessibility': 'denied'};
    await pumpPage(tester);

    final sw = switchFor('无障碍服务');
    expect(sw, findsOneWidget);
    await tester.tap(sw);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();

    expect(requested, contains('accessibility'));
    expect(tester.widget<ElasticSwitch>(sw).value, isFalse,
        reason: '真实值仍是 denied ⇒ 开关保持关');
  });

  testWidgets('⑤ ElasticSwitch(optimistic:false)：只回调不预演，真值到了才动画',
      (tester) async {
    var value = false;
    Widget build() => wrap(ElasticSwitch(
          value: value,
          optimistic: false,
          onChanged: (v) => value = v,
        ));

    await tester.pumpWidget(build());
    final sw = find.byType(ElasticSwitch);
    final off = knobLeft(tester, sw);

    await tester.tap(sw);
    await tester.pump();
    expect(value, isTrue, reason: '用户意图必须如实回调');
    await tester.pump(const Duration(milliseconds: 600));
    expect(knobLeft(tester, sw), off,
        reason: '父级 value 还没变 ⇒ 视觉绝不能预报（否则就是假开关）');

    // 父级真值到位 ⇒ 这时候才动画过去
    await tester.pumpWidget(build());
    await tester.pump(const Duration(milliseconds: 600));
    expect(knobLeft(tester, sw), greaterThan(off),
        reason: '真值变化后必须动画对齐（不是干脆不显示变化）');
  });

  testWidgets('⑥ 默认 optimistic:true 保持原行为：点按立刻预演', (tester) async {
    await tester.pumpWidget(wrap(ElasticSwitch(
      value: false,
      onChanged: (_) {},
    )));
    final sw = find.byType(ElasticSwitch);
    final off = knobLeft(tester, sw);

    await tester.tap(sw);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(knobLeft(tester, sw), greaterThan(off),
        reason: '默认乐观开关（设置项/抽屉）行为不能被本次改动改变');
  });
}
