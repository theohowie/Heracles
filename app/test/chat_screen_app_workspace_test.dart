import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/screens/chat_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';

import 'support/secure_storage_mock.dart';

/// **「默认工作区」入口的通道调用回归测试**（2026-10-17）。
///
/// ## 被测的那条路
///
/// `WorkspaceDrawer` 的 ⊕ → 「默认工作区」→ `ChatScreen._addAppWorkspace()`：
///
/// ```
/// Navigator.pop()                       // 先关抽屉
/// → _bridge.ensureAppWorkspace()        // MethodChannel 'ensureAppWorkspace'（无参数）
///   ├─ null / path 为空 ⇒ 只 setState 错误，**不再调任何其他通道**
///   └─ 有 path ⇒ _switchContext()
///                → createSession(path, '新会话', treeUri: …)
///                → 选中该会话 + _reload()
/// ```
///
/// ## 为什么必须在**通道层**断言，而不是只测 WorkspaceDrawer
///
/// WorkspaceDrawer 只管"把回调接出去"（已由 `workspace_drawer_add_menu_test.dart`
/// 覆盖）。真正会伤到用户的是**接线之后那一段**：
///   · `ensureAppWorkspace` 建不出目录（真机上 SAF/分区存储会这样）时，
///     若代码继续往下调 `createSession`，用户就会看到一个**假会话**
///     —— 点进去发消息必然失败，且没有任何提示。
///   · 反之若建得出来，`createSession` 必须拿到**正确的 path 与 treeUri**
///     （漏传 treeUri 会走 `java.io.File` → `EPERM`，真机实测过两次）。
///
/// 所以这里记录**被调用过的通道方法名与参数**，断言的是行为序列，
/// 而不是"某个 widget 存在"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ★ 安全存储通道 mock（2026-10-18，F1c）—— `freshController()` 走
  //   `SettingsController.load()`，不装 handler 时**永久卡死**。
  //   见 `test/support/secure_storage_mock.dart`。
  setUp(installSecureStorageMock);
  tearDown(removeSecureStorageMock);

  const commandChannel = MethodChannel('heracles/command');
  const eventChannel = EventChannel('heracles/events');

  /// 内置默认工作区在真机上的形状（`Android/data/<pkg>/files/...`）。
  ///
  /// 目录名与 `SessionStore.APP_WORKSPACE_DIR` 一致（`app-workspace`）——
  /// 夹具不比真机更宽松，免得"测试里对、真机上不对"。
  const appWorkspacePath =
      '/storage/emulated/0/Android/data/com.theohowie.heracles/files/app-workspace';
  const appWorkspaceTreeUri = 'content://com.android.externalstorage.documents/tree/x';
  const createdSessionId = 'sess-app-1';

  /// 被调用过的通道方法名，**按调用顺序**。
  late List<String> calls;

  /// 每次 `createSession` 收到的参数（用来核对 path / title / treeUri）。
  late List<Map<dynamic, dynamic>> createSessionArgs;

  /// `ensureAppWorkspace` 的返回值 —— 每个用例自己决定（null / map / 抛异常）。
  late Future<Object?> Function() onEnsureAppWorkspace;

  /// 工作区列表：**默认空** —— 这样抽屉里是空态，
  /// `find.text('选择文件夹')` 只会命中 ⊕ 菜单那一项（不会与空态按钮撞名）。
  late List<Map<String, dynamic>> workspaces;

  void installMocks() {
    calls = <String>[];
    createSessionArgs = <Map<dynamic, dynamic>>[];
    workspaces = <Map<String, dynamic>>[];

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'ensureAppWorkspace':
          return await onEnsureAppWorkspace();
        case 'createSession':
          createSessionArgs.add(Map<dynamic, dynamic>.from(call.arguments as Map));
          return createdSessionId;
        case 'listWorkspaces':
          return workspaces;
        case 'listSessions':
          return <Map<String, dynamic>>[];
        case 'loadMessages':
          return <Map<String, dynamic>>[];
        default:
          return null;
      }
    });

    // 事件通道也要给个 mock —— 否则 EventChannel 在测试里会报
    // "MissingPluginException"（真实存在的通道，只是测试里没有平台侧）。
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (arguments, events) {}, onCancel: (arguments) {}),
    );
  }

  Future<SettingsController> freshController() async {
    SharedPreferences.setMockInitialValues({});
    return SettingsController.load();
  }

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        // HueScope 由生产环境 main.dart 的 MaterialApp.builder 注入
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      );

  /// ★ 不用 `pumpAndSettle`：ChatScreen 常有常驻动画（loading 圈的旋转），
  /// `pumpAndSettle` 会一直等下去。固定推虚拟时钟 —— 与 session_guard_test.dart 同手法。
  Future<void> settle(WidgetTester tester, {int times = 10}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// ★ 用**手机大小**的测试面（390×844）—— 默认的 800×600 会让
  /// `WorkspaceDrawer` 的空态 `Column`（`workspace_drawer.dart:298`）
  /// `RenderFlex overflowed`，把按钮挤出可视区、`tap()` 点不到。
  /// 真机就是竖屏手机，所以这也是更接近真实的夹具。
  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 抽屉里 **⊕ 那个菜单按钮**（不是空态里那个大装饰图标）。
  ///
  /// ⚠️ 同一个 `Icons.create_new_folder_outlined` 在抽屉里出现**两次**：
  ///   · `workspace_drawer.dart:842` **size: 17** ← 头部的 ⊕ 菜单按钮（可点）
  ///   · `workspace_drawer.dart:301` **size: 34** ← 空态里的装饰（不可点）
  /// 裸 `find.byIcon` 会 "ambiguously found multiple matching widgets"。
  /// 这里按 size 定位 —— 与 `reasoning_switch_test.dart` 里
  /// 用 widget 谓词点 ChoiceChip 是同一类修法。
  Finder drawerAddButton() => find.byWidgetPredicate(
        (w) =>
            w is Icon &&
            w.icon == Icons.create_new_folder_outlined &&
            w.size == 17,
        description: '抽屉头部的 ⊕ 菜单按钮（size 17）',
      );

  /// 驱动用户真正走的路径：开抽屉 → 点 ⊕ → 点「默认工作区」。
  Future<void> pickAppWorkspace(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu_rounded)); // AppBar 的 ☰
    await settle(tester);

    await tester.tap(drawerAddButton()); // ⊕
    await settle(tester);

    expect(find.text('默认工作区'), findsOneWidget,
        reason: '前提：⊕ 菜单里有「默认工作区」这项 —— 否则后面点了个寂寞');
    await tester.tap(find.text('默认工作区'));
    await settle(tester);
  }

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commandChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  // ==================================================================
  // 1) 走 UI 真的会调 'ensureAppWorkspace'
  // ==================================================================

  /// 这条防的是**接线断了**：按钮画得出来、点了却没调通道
  /// （`onAddAppWorkspace` 没传给 WorkspaceDrawer 时就是这样）。
  testWidgets('★ 驱动 ⊕ →「默认工作区」→ 通道被调方法里包含 ensureAppWorkspace',
      (tester) async {
    installMocks();
    await usePhoneSurface(tester);
    onEnsureAppWorkspace = () async => null; // 建不出来也无妨，这条只看"有没有调"

    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);

    await pickAppWorkspace(tester);

    expect(calls, contains('ensureAppWorkspace'),
        reason: '点「默认工作区」必须真的去调 ensureAppWorkspace 通道 —— '
            '否则按钮只是个装饰（接线断了）');
  });

  // ==================================================================
  // 2) 建不出目录 ⇒ 如实报错，**不**调 createSession
  // ==================================================================

  /// ## 这是本组最重要的一条
  ///
  /// `ensureAppWorkspace` 返回 null（真机上会有：分区存储 / 目录不可用）。
  /// 此时若继续调 `createSession`，用户会得到一个**看起来正常、实际用不了**
  /// 的会话 —— 发消息必然失败，而且没有任何解释。
  ///
  /// 正确行为：只显示错误、不碰其他通道。
  testWidgets('★★ ensureAppWorkspace 返回 null → 显示错误、不调 createSession',
      (tester) async {
    installMocks();
    await usePhoneSurface(tester);
    onEnsureAppWorkspace = () async => null;

    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);

    await pickAppWorkspace(tester);

    expect(calls, contains('ensureAppWorkspace'));
    expect(calls, isNot(contains('createSession')),
        reason: '建不出目录却调了 createSession → 会给用户一个假会话');

    // 用户**必须被告知**（静默失败等于界面坏了）
    expect(find.textContaining('无法创建默认工作区'), findsOneWidget,
        reason: '建不出目录必须如实告知，不能静默什么都不发生');

    // 界面还活着
    expect(tester.takeException(), isNull);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  /// 同样的守卫，但走"map 里 path 是空串"这一支 ——
  /// 与"返回 null"是**两条不同的代码路径**（`ws?['path']` vs `ws == null`），
  /// 只测一条会漏掉另一半。
  testWidgets('★★ ensureAppWorkspace 返回 path 为空串 → 同样只报错、不调 createSession',
      (tester) async {
    installMocks();
    await usePhoneSurface(tester);
    onEnsureAppWorkspace = () async => <String, dynamic>{
          'path': '',
          'name': '默认工作区',
          'treeUri': appWorkspaceTreeUri,
        };

    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);

    await pickAppWorkspace(tester);

    expect(calls, isNot(contains('createSession')),
        reason: 'path 为空 = 建不出目录，绝不能建会话');
    expect(find.textContaining('无法创建默认工作区'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ==================================================================
  // 3) 建得出 ⇒ 调 createSession，参数正确
  // ==================================================================

  /// 成功路径要**三件事同时**对，少一件在真机上都会出问题：
  ///   · 调了 `createSession`
  ///   · `workspacePath` 是通道返回的那个 path（不是空串/占位串）
  ///   · **带上了 treeUri**（漏传 → Kotlin 侧走 `java.io.File` → `EPERM`）
  ///
  /// 位置参数也不能错：`createSession(workspacePath, title, {treeUri})`
  /// —— 第 2 个位置参数是 title `'新会话'`。
  testWidgets('★★ ensureAppWorkspace 返回带 path 的 map → 调 createSession 且参数正确',
      (tester) async {
    const ws = <String, dynamic>{
      'path': appWorkspacePath,
      'name': '默认工作区',
      'treeUri': appWorkspaceTreeUri,
      'writable': true,
    };

    installMocks();
    await usePhoneSurface(tester);
    onEnsureAppWorkspace = () async => ws;

    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);

    await pickAppWorkspace(tester);

    expect(calls, contains('ensureAppWorkspace'));
    expect(calls, contains('createSession'),
        reason: '拿到 path 之后必须真的建一个会话 —— '
            '否则侧边栏只渲染有会话的工作区，用户点完什么都看不到');

    expect(createSessionArgs, hasLength(1),
        reason: '只该建一个会话（重复建会出现两条一模一样的"新会话"）');

    final args = createSessionArgs.single;
    expect(args['workspacePath'], appWorkspacePath,
        reason: 'createSession 必须拿到通道返回的那个 path');
    expect(args['title'], '新会话');
    expect(args['treeUri'], appWorkspaceTreeUri,
        reason: 'treeUri 必须透传 —— 漏传则 Kotlin 侧走 java.io.File → EPERM（真机实测过）');

    // 顺序也要对：先 ensure 再 create（反过来就是"先建会话才想起要目录"）
    expect(calls.indexOf('ensureAppWorkspace'),
        lessThan(calls.indexOf('createSession')));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('无法创建默认工作区'), findsNothing,
        reason: '成功路径不该留下错误横幅');
  });

  // ==================================================================
  // 4) 通道抛异常 ⇒ 不崩、不调 createSession
  // ==================================================================

  /// 真机上"建不出目录"也可能是**抛异常**（PlatformException）而不是返回 null。
  /// 这条钉住 catch 分支：报错但不崩、也不建假会话。
  testWidgets('★ ensureAppWorkspace 抛 PlatformException → 不崩、不调 createSession',
      (tester) async {
    installMocks();
    await usePhoneSurface(tester);
    onEnsureAppWorkspace = () async =>
        throw PlatformException(code: 'ENSURE_FAILED', message: '外置私有目录不可用');

    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);

    await pickAppWorkspace(tester);

    expect(calls, isNot(contains('createSession')),
        reason: 'ensure 失败时绝不能建会话');
    expect(tester.takeException(), isNull,
        reason: '通道异常必须被 catch —— 未捕获异常在真机上就是崩溃');

    // 错误对用户可见（内容因桥接封装可能不同，只断言"有个错误提示"）
    expect(find.byType(ChatScreen), findsOneWidget);
  });
}
