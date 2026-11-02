import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';

import 'support/secure_storage_mock.dart';

/// **选择器「没回包」时必须给出可操作的提示**（2026-11-02 · T0 SAF 黑屏）。
///
/// ## 这条用例锁的是"最坏情况的下限"
///
/// 用户报的现象是「选好文件夹返回 ⇒ 黑屏」。修完之后理想路径是：结果被
/// 进程级登记表救回来。但如果**救不回来**（进程真的被杀 / 系统没回结果），
/// 界面**绝不允许**停在一个等不到的东西上 —— 下限必须是：
///
/// ```
/// 明确的中文提示 + 两个能点的下一步（重试 / 改用默认工作区）
/// ```
///
/// 所以这里让通道**永远不回包**（`Completer().future`），推到超时之后，
/// 断言：
/// 1. 出现了「没能收到选择结果」这个标题（而不是一行红字或空白）；
/// 2. 两条出路都在，且**真的能点**；
/// 3. 点「重试」会**再次**发起 `pickWorkspace`（不是画了个假按钮）。
///
/// ⚠️ 时间推进用 `tester.pump(Duration)`：`pickWorkspace` 的超时是
/// `Future.timeout`（真 Timer），而 widget 测试跑在 fake-async zone 里，
/// 虚拟时钟一推就到，**不需要真等 45 秒**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installSecureStorageMock);
  tearDown(removeSecureStorageMock);

  const commandChannel = MethodChannel('heracles/command');
  const deviceChannel = MethodChannel('heracles/device');

  /// 被调用过的通道方法名（按顺序）—— 用来证明"重试"确实重发了请求。
  late List<String> calls;

  /// `pickWorkspace` 的行为：默认"永不回包"（模拟 Activity 被回收）。
  late Future<Object?>? Function() onPickWorkspace;

  void installMocks() {
    calls = <String>[];
    onPickWorkspace = () => Completer<Object?>().future;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'pickWorkspace':
          return await onPickWorkspace();
        case 'consumePickWorkspaceResult':
          // 宿主那边也没有结果 ⇒ 超时后走"明确报错 + 可重试"
          return null;
        case 'listWorkspaces':
          return <Map<String, dynamic>>[];
        case 'consumePendingOpen':
          return null;
        case 'processKilled':
          return <String, dynamic>{'ok': true, 'killed': false};
        default:
          return null;
      }
    });

    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      switch (call.method) {
        case 'fs.stat':
          return <String, dynamic>{'ok': true, 'exists': false};
        case 'fs.readText':
          return <String, dynamic>{'ok': true, 'text': '[]', 'truncated': false};
        default:
          return <String, dynamic>{'ok': true};
      }
    });
  }

  Future<SettingsController> freshController() async {
    SharedPreferences.setMockInitialValues({});
    return SettingsController.load();
  }

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      );

  /// ★ 不用 `pumpAndSettle`：ChatScreen 有常驻动画（loading 圈），会一直等下去。
  Future<void> settle(WidgetTester tester, {int times = 12}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(520, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Finder drawerAddButton() => find.byWidgetPredicate(
        (w) =>
            w is Icon &&
            w.icon == CupertinoIcons.folder_badge_plus &&
            w.size == 18,
        description: '抽屉头部的 ⊕ 菜单按钮（size 18）',
      );

  /// 走用户真实路径：开抽屉 → ⊕ → 「选择文件夹」。
  ///
  /// ⚠️ 抽屉用 `ScaffoldState.openDrawer()` 打开，**不点顶栏品牌图标**：
  /// 那个图标的命中矩形会随顶栏改版变化（真机上点得到，测试画布上常常
  /// "点到了但没反应"），而这里要测的是"选择文件夹"之后的那条链路，
  /// 不该被"开抽屉"这一步的脆弱性拖累。
  Future<void> tapPickFolder(WidgetTester tester) async {
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await settle(tester);

    // ⚠️ 同一个图标在抽屉里出现**两次**：size 18 = 头部 ⊕ 菜单按钮（可点）；
    //    size 35 = 空态的装饰（不可点）。裸 byIcon 会 ambiguous，按 size 定位。
    final add = drawerAddButton();
    expect(add, findsOneWidget,
        reason: '前提：抽屉头部要有 ⊕ 菜单按钮 —— 找不到说明抽屉没打开或入口又改了');
    await tester.tap(add);
    await settle(tester);

    // ⊕ 菜单弹出时，空态里那个同名按钮 + 菜单项会同时存在（共 3 个 Text，
    // 含过渡帧的重影）⇒ 取最后一个（菜单项在最上层）。真假由后面的
    // "pickWorkspace 被调用了一次" 断言兜住：点错了就不会有这次调用。
    final item = find.text('选择文件夹');
    expect(item, findsWidgets,
        reason: '前提：⊕ 菜单里必须有「选择文件夹」—— 否则后面点了个寂寞');
    await tester.tap(item.last);
    // 抽屉 pop（一次 pump）+ 让出 260ms（_pickWorkspace 里的真实等待）
    await tester.pump(const Duration(milliseconds: 400));
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockMethodCallHandler(deviceChannel, null);
  });

  testWidgets('★★ 宿主永不回包 ⇒ 超时后给出「没能收到选择结果」+ 可点重试', (tester) async {
    installMocks();
    await usePhoneSurface(tester);
    final settings = await freshController();

    await tester.pumpWidget(wrap(ChatScreen(settings: settings)));
    await settle(tester);

    await tapPickFolder(tester);
    // 前提：请求确实发出去了（防"根本没调用通道，后面全在空跑"）
    expect(calls.where((c) => c == 'pickWorkspace').length, 1,
        reason: '点「选择文件夹」必须真的发起一次 pickWorkspace');

    // ★ 推进虚拟时钟跨过超时（契约 45s），让 Future.timeout 真正触发
    await tester.pump(const Duration(seconds: 46));
    await settle(tester);

    // 1) 有明确标题 —— 不是一行红字、不是空白
    expect(find.text('没能收到选择结果'), findsOneWidget,
        reason: '超时后必须弹出可操作的失败提示，而不是静默/黑屏');

    // 2) 两条出路都在
    expect(find.text('重试选择文件夹'), findsOneWidget);
    expect(find.text('使用「默认工作区」'), findsOneWidget);

    // 3) 「重试」是真的能重发请求（不是画着好看的按钮）
    final before = calls.where((c) => c == 'pickWorkspace').length;
    await tester.tap(find.text('重试选择文件夹'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final after = calls.where((c) => c == 'pickWorkspace').length;
    expect(after, before + 1,
        reason: '点「重试」必须再发起一次 pickWorkspace —— 否则等于把用户关在死路上');

    // ★ 收尾：重试那次也会挂一个 45s 的 `Future.timeout` 定时器。
    //   不把它推完，测试框架会报 "A Timer is still pending after the widget
    //   tree was disposed"（这不是产品缺陷，是测试自己没收干净）。
    await tester.pump(const Duration(seconds: 46));
    await settle(tester);
  });

  testWidgets('桥接直接抛异常（插件没就绪）⇒ 同样给可操作提示，不是一行红字', (tester) async {
    installMocks();
    // 换掉默认的"永不回包"：这次让通道抛 PlatformException
    onPickWorkspace = () async => throw PlatformException(code: 'boom', message: '桥接未就绪');
    await usePhoneSurface(tester);
    final settings = await freshController();

    await tester.pumpWidget(wrap(ChatScreen(settings: settings)));
    await settle(tester);

    await tapPickFolder(tester);
    await settle(tester);

    expect(find.text('没能收到选择结果'), findsOneWidget);
    expect(find.text('重试选择文件夹'), findsOneWidget);
  });
}
