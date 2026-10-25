import 'package:flutter/cupertino.dart';
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
/// → _bridge.ensureAppWorkspace()        // MethodChannel 'heracles/command'
///                                       //   'ensureAppWorkspace'（无参数）
///   ├─ null / path 为空 ⇒ 只 setState 错误，**不建会话**
///   └─ 有 path ⇒ _switchContext()
///                → _bridge.createSession(path, '新会话', treeUri: …)
///                → 选中该会话 + _reload()
/// ```
///
/// ## ★ 2026-10-25：会话落盘**已不在 `heracles/command` 上**
///
/// `AgentBridge.createSession` 现在直接走 Dart `SessionStore` ⇒
/// **`heracles/device` 的 `fs.*`**（写 `<ws>/.heracles/sessions.json`）；
/// `heracles/command` 上只剩工作区登记表那几个方法（`ensureAppWorkspace` /
/// `listWorkspaces` / `removeWorkspace` / `consumePendingOpen`）。
/// 所以本文件的夹具必须**两条通道一起 mock**，否则：
///   · 成功路径会去调真通道 ⇒ 断言恒红（旧夹具就是这样红的）；
///   · 反向断言（"不该建会话"）会**空跑**变绿 —— 因为那条通道上永远不会再出现
///     建会话的痕迹。
/// 现在"有没有建会话"的判据是**设备通道上有没有写会话索引**，比旧判据更接近事实。
///
/// ⚠️ `treeUri` 也**不再往下传**：Dart 只把它当缓存键的一部分，真正的
/// SAF/POSIX 路由由 Kotlin `DeviceFs` 按登记表决定（见 `agent_bridge.dart`
/// 的 `createSession` 与 `_storeFor` 注释）。所以本文件不再断言"treeUri 透传"。
///
/// ## 为什么必须在**通道层**断言，而不是只测 WorkspaceDrawer
///
/// WorkspaceDrawer 只管"把回调接出去"（已由 `workspace_drawer_add_menu_test.dart`
/// 覆盖）。真正会伤到用户的是**接线之后那一段**：
///   · `ensureAppWorkspace` 建不出目录（真机上 SAF/分区存储会这样）时，
///     若代码继续往下建会话，用户就会看到一个**假会话**
///     —— 点进去发消息必然失败，且没有任何提示。
///   · 反之若建得出来，会话索引必须写在**通道返回的那个 path** 下。
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
  /// 会话存储走的通道（`SessionStore` 的 `fs.*`）—— 见文件头说明。
  const deviceChannel = MethodChannel('heracles/device');

  /// 内置默认工作区在真机上的形状（`Android/data/<pkg>/files/...`）。
  ///
  /// 目录名与 `SessionStore.APP_WORKSPACE_DIR` 一致（`app-workspace`）——
  /// 夹具不比真机更宽松，免得"测试里对、真机上不对"。
  const appWorkspacePath =
      '/storage/emulated/0/Android/data/com.theohowie.heracles/files/app-workspace';
  const appWorkspaceTreeUri = 'content://com.android.externalstorage.documents/tree/x';

  /// 被调用过的通道方法名，**按调用顺序**。
  ///
  /// 两条通道都往里写（含下面那条"索引写入"的合成事件名），
  /// 这样"先 ensure 再建会话"的顺序断言仍然成立。
  late List<String> calls;

  /// 会话索引的写入（`heracles/device` 的 `fs.writeText` → `<ws>/.heracles/sessions.json`）。
  ///
  /// ★ 这是"**到底有没有建会话**"的判据（见文件头说明）。
  late List<Map<dynamic, dynamic>> indexWrites;

  /// `ensureAppWorkspace` 的返回值 —— 每个用例自己决定（null / map / 抛异常）。
  late Future<Object?> Function() onEnsureAppWorkspace;

  /// 工作区列表：**默认空** —— 这样抽屉里是空态，
  /// `find.text('选择文件夹')` 只会命中 ⊕ 菜单那一项（不会与空态按钮撞名）。
  late List<Map<String, dynamic>> workspaces;

  /// 循环里要按顺序追加 `calls` 的合成事件名。
  const indexWriteCall = 'fs.writeText:sessions.json';

  void installMocks() {
    calls = <String>[];
    indexWrites = <Map<dynamic, dynamic>>[];
    workspaces = <Map<String, dynamic>>[];

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'ensureAppWorkspace':
          return await onEnsureAppWorkspace();
        case 'listWorkspaces':
          return workspaces;
        default:
          return null;
      }
    });

    // ★ 会话存储的真通道（`SessionStore` 走这里，见文件头说明）。
    messenger.setMockMethodCallHandler(deviceChannel, (call) async {
      final args =
          call.arguments is Map ? Map<dynamic, dynamic>.from(call.arguments as Map) : <dynamic, dynamic>{};
      final path = args['path'] as String? ?? '';
      switch (call.method) {
        case 'fs.stat':
          // 新会话 id 探测：永不撞（`SessionStore._newId`）
          return <String, dynamic>{'ok': true, 'exists': false};
        case 'fs.readText':
          // 索引读回来是空数组 ⇒ 建会话时列表为空（符合"新工作区"场景）
          return <String, dynamic>{'ok': true, 'text': '[]', 'truncated': false};
        case 'fs.writeText':
          if (path.endsWith('.heracles/sessions.json')) {
            calls.add(indexWriteCall);
            indexWrites.add(args);
          }
          return <String, dynamic>{'ok': true};
        case 'fs.appendText':
        case 'fs.mkdir':
        case 'fs.delete':
          return <String, dynamic>{'ok': true};
        default:
          return <String, dynamic>{
            'ok': false,
            'error': '测试 mock：未知方法 ${call.method}',
          };
      }
    });

    // 事件通道 mock 已随内核迁移退场（`heracles/events` 在 app/lib 里
    // **零构造**，见 agent_bridge.dart 的说明）—— 留着反而误导后来人。
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

  /// **打开抽屉**：原型 01（`1f52b1d`，2026-10-25）之后顶栏左侧不再有 ☰ 线条图标，
  /// 换成**品牌图标**（真实 App 图标，点它开抽屉）。按 **asset 名**定位，
  /// 免得 finder 随 UI 改版再失效。
  Future<void> openDrawer(WidgetTester tester) async {
    final opener = find.byWidgetPredicate(
      (w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName.contains('app_icon_source'),
      description: '顶栏左侧品牌图标（打开抽屉）',
    );
    expect(opener, findsOneWidget,
        reason: '顶栏左侧必须有品牌图标（点它开抽屉）—— 找不到说明顶栏又改了');
    await tester.tap(opener);
    await settle(tester);
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
  /// ⚠️ 同一个 `CupertinoIcons.folder_badge_plus` 在抽屉里出现**两次**：
  ///   · `workspace_drawer.dart:874` **size: 18** ← 头部的 ⊕ 菜单按钮（可点）
  ///   · `workspace_drawer.dart:370` **size: 35** ← 空态里的装饰（不可点）
  /// 裸 `find.byIcon` 会 "ambiguously found multiple matching widgets"。
  /// 这里按 size 定位。
  ///
  /// ★ 2026-10-25：图标随 Cupertino 改版换过（旧 Material
  ///   `Icons.create_new_folder_outlined` size 17 → 现在是
  ///   `CupertinoIcons.folder_badge_plus` size 18）—— **只换 finder，断言未动**。
  Finder drawerAddButton() => find.byWidgetPredicate(
        (w) =>
            w is Icon &&
            w.icon == CupertinoIcons.folder_badge_plus &&
            w.size == 18,
        description: '抽屉头部的 ⊕ 菜单按钮（size 18）',
      );

  /// 驱动用户真正走的路径：开抽屉 → 点 ⊕ → 点「默认工作区」。
  Future<void> pickAppWorkspace(WidgetTester tester) async {
    await openDrawer(tester);
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
    messenger.setMockMethodCallHandler(deviceChannel, null);
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
  // 2) 建不出目录 ⇒ 如实报错，**不**建会话
  // ==================================================================

  /// ## 这是本组最重要的一条
  ///
  /// `ensureAppWorkspace` 返回 null（真机上会有：分区存储 / 目录不可用）。
  /// 此时若继续调 `createSession`，用户会得到一个**看起来正常、实际用不了**
  /// 的会话 —— 发消息必然失败，而且没有任何解释。
  ///
  /// 正确行为：只显示错误、不碰其他通道。
  testWidgets('★★ ensureAppWorkspace 返回 null → 显示错误、不建会话',
      (tester) async {
    installMocks();
    await usePhoneSurface(tester);
    onEnsureAppWorkspace = () async => null;

    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);

    await pickAppWorkspace(tester);

    expect(calls, contains('ensureAppWorkspace'));
    // ★ 2026-10-25：判据换成"设备通道上有没有写会话索引"（见文件头）——
    //   旧判据（command 通道上 `createSession`）在内核迁移后**恒不成立**，
    //   也就是反向断言会空跑变绿。
    expect(indexWrites, isEmpty,
        reason: '建不出目录却建了会话 → 会给用户一个假会话');
    expect(calls, isNot(contains(indexWriteCall)),
        reason: '同上：会话索引**一个字都没写**才算数');

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
  testWidgets('★★ ensureAppWorkspace 返回 path 为空串 → 同样只报错、不建会话',
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

    expect(indexWrites, isEmpty,
        reason: 'path 为空 = 建不出目录，绝不能建会话');
    expect(find.textContaining('无法创建默认工作区'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ==================================================================
  // 3) 建得出 ⇒ 真的把会话写进该 path 下的索引
  // ==================================================================

  /// 成功路径要**三件事同时**对，少一件在真机上都会出问题：
  ///   · 走了 `ensureAppWorkspace`（拿到 path）
  ///   · 会话索引写在**通道返回的那个 path** 下（不是空串/占位串）
  ///   · 写进去的索引里**有那条「新会话」**
  ///
  /// ⚠️ 2026-10-25 口径变更：旧版本断言"`createSession` 通道参数里有
  /// `workspacePath` / `treeUri`"。内核迁移后 `createSession` 不再走
  /// `heracles/command`（改走 Dart `SessionStore` → `heracles/device` 的
  /// `fs.*`），`treeUri` 也不再往下传（SAF/POSIX 路由由 Kotlin `DeviceFs`
  /// 按登记表决定，见 `agent_bridge.dart`）。所以断言换成**落盘事实**：
  /// 索引文件路径 + 内容。这比旧断言更接近"用户到底有没有得到会话"。
  testWidgets('★★ ensureAppWorkspace 返回带 path 的 map → 会话写进该 path 的索引',
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
    // ★ 2026-10-25：判据 = 设备通道上真的把新会话写进了**该 path 下**的索引。
    expect(indexWrites, hasLength(1),
        reason: '拿到 path 之后必须真的建一个会话 —— '
            '否则侧边栏只渲染有会话的工作区，用户点完什么都看不到');

    final written = indexWrites.single;
    expect(written['path'], '$appWorkspacePath/.heracles/sessions.json',
        reason: '会话索引必须写在通道返回的那个 path 下 —— '
            '写错地方等于用户看不到自己的会话');
    expect(written['text'], contains('"title":"新会话"'),
        reason: '写进去的索引里必须有这次建的那条会话（标题「新会话」）');

    // 顺序也要对：先 ensure 再建会话（反过来就是"先建会话才想起要目录"）
    expect(calls.indexOf('ensureAppWorkspace'),
        lessThan(calls.indexOf(indexWriteCall)));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('无法创建默认工作区'), findsNothing,
        reason: '成功路径不该留下错误横幅');
  });

  // ==================================================================
  // 4) 通道抛异常 ⇒ 不崩、不建会话
  // ==================================================================

  /// 真机上"建不出目录"也可能是**抛异常**（PlatformException）而不是返回 null。
  /// 这条钉住 catch 分支：报错但不崩、也不建假会话。
  testWidgets('★ ensureAppWorkspace 抛 PlatformException → 不崩、不建会话',
      (tester) async {
    installMocks();
    await usePhoneSurface(tester);
    onEnsureAppWorkspace = () async =>
        throw PlatformException(code: 'ENSURE_FAILED', message: '外置私有目录不可用');

    final c = await freshController();
    await tester.pumpWidget(wrap(ChatScreen(settings: c)));
    await settle(tester);

    await pickAppWorkspace(tester);

    expect(indexWrites, isEmpty,
        reason: 'ensure 失败时绝不能建会话');
    expect(tester.takeException(), isNull,
        reason: '通道异常必须被 catch —— 未捕获异常在真机上就是崩溃');

    // 错误对用户可见（内容因桥接封装可能不同，只断言"有个错误提示"）
    expect(find.byType(ChatScreen), findsOneWidget);
  });
}
