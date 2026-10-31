import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/screens/sandbox_screen.dart';
import 'package:heracles/services/sandbox_service.dart';
import 'package:heracles/theme/app_theme.dart';

/// **T2 编译环境 = 已安装状态可读 + 可卸载 + 卸载后重查真状态**
/// （2026-10-29 T2 第 7 条）。
///
/// 旧行为（本文件先红证明）：T2 卡片只有「已就绪 / 未安装」+ 下载按钮 ——
/// 装好之后用户看不到**占了多少、装在哪**，也**没有卸载入口**（只能整个
/// 重置沙箱，连 T0 都一起清）。
///
/// 新规格（后端线已补真字段，`sandbox_service.dart`
/// `SandboxBuildSuiteStatus.installDir/occupiedBytes` +
/// `resetBuildSuiteVerbose()`）：
/// - 已安装 ⇒「已安装 · 实际占用 N MB」+「安装位置 <路径>」+「卸载编译环境」；
/// - 卸载 ⇒ 二次确认写清会删 JDK 17 / Gradle / android.jar（含体积）→
///   `resetBuildSuite` → **重查** `buildSuiteStatus`（以磁盘真相为准）；
/// - 交接：残留 ⇒ 人话说「还剩多少 / 在哪」；仍就绪 ⇒ 「卸载未完成 + 原因」；
///   绝不把失败画成成功。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SandboxChannelClient.channelName);

  /// 造 T2 已安装时的真实量级：≈502 MB。
  const occupiedBytes = 526385152; // 502.0 MB
  const installDir =
      '/data/user/0/com.theohowie.heracles/files/sandbox/rootfs/opt/t2';

  late bool suiteReady;
  late int suiteOccupied;
  late Map<String, Object?> resetReply;
  /// reset 被调之后是否把「磁盘上的状态」改成 replies 描述的样子。
  late bool applyResetEffect;
  late List<String> calls;

  Map<String, Object?> statusMap() => <String, Object?>{
        'ok': true,
        'installed': true,
        'rootfsSummary': 'bundled-minimal (source=1, 9040693 B, snapshots=0)',
        'prootReady': true,
        'channels': [
          {'type': 0, 'name': '普通 App', 'available': true, 'reason': '', 'risk': 0},
        ],
      };

  Map<String, Object?> suiteMap() => <String, Object?>{
        'ok': true,
        'ready': suiteReady,
        'version': suiteReady ? 't2-2026-10-29' : '',
        'installDir': installDir,
        'occupiedBytes': suiteOccupied,
        'parts': {
          'jdk': suiteReady,
          'gradle': suiteReady,
          'androidJar': suiteReady,
        },
        'missing':
            suiteReady ? <String>[] : <String>['JDK 17（javac）', 'Gradle', 'android.jar'],
      };

  setUp(() {
    suiteReady = true;
    suiteOccupied = occupiedBytes;
    applyResetEffect = true;
    calls = <String>[];
    resetReply = <String, Object?>{
      'ok': true,
      'ready': false,
      'installDir': installDir,
      'removed': <String>['/opt/t2', '/usr/lib/jvm/java-17-openjdk'],
      'failed': <Object?>[],
      'freedBytes': occupiedBytes,
      'missing': <String>['JDK 17（javac）', 'Gradle', 'android.jar'],
      'message': '已卸载 T2 编译环境：释放 502.0 MB',
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'status':
          return statusMap();
        case 'listMounts':
          return <String, Object?>{'ok': true, 'mounts': <Object?>[]};
        case 'buildSuiteStatus':
          return suiteMap();
        case 'resetBuildSuite':
          if (applyResetEffect) {
            // 以磁盘真相为准：成功卸载后 ready 变 false、占用归零。
            suiteReady = resetReply['ready'] == true;
            suiteOccupied =
                (resetReply['residualBytes'] as num?)?.toInt() ?? 0;
          }
          return resetReply;
        default:
          return <String, Object?>{'ok': true};
      }
    });
  });

  tearDown(() {
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

  /// 真机宽度（393dp）：默认 800 宽测不出路径/长文案的溢出。
  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(const SandboxScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 断在「卸载编译环境」按钮（**必须是真按钮**：真机整卡手势曾点不动）。
  Finder uninstallButton() =>
      find.widgetWithText(OutlinedButton, '卸载编译环境');

  /// 路径展示带零宽空格（折行用），比对前先剥掉 —— 断言的仍是完整路径。
  Finder pathText() => find.byWidgetPredicate((w) =>
      w is Text && (w.data ?? '').replaceAll('\u200B', '') == installDir);

  testWidgets('★★ 已安装 ⇒ 显示 已安装 · 实际占用 · 安装位置 · 卸载入口',
      (tester) async {
    await pumpScreen(tester);

    expect(find.text('编译环境 · 已就绪'), findsOneWidget);
    expect(find.textContaining('502.0 MB'), findsOneWidget,
        reason: '实际占用要如实显示（后端给了 occupiedBytes，不许估）');
    expect(find.textContaining('已安装'), findsWidgets);
    expect(pathText(), findsOneWidget, reason: '装在哪必须能看见（排障第一问）');
    expect(uninstallButton(), findsOneWidget,
        reason: 'T2 要能单独卸载，不必整个重置沙箱');
    expect(find.textContaining('t2-2026-10-29'), findsOneWidget,
        reason: '版本标记也要显示（对照"需重新激活"的判断）');
  });

  testWidgets('★★ 点「卸载编译环境」⇒ 二次确认写清会删什么、占多少',
      (tester) async {
    await pumpScreen(tester);
    await tester.tap(uninstallButton());
    await tester.pumpAndSettle();

    expect(find.text('卸载编译环境？'), findsOneWidget);
    expect(find.textContaining('JDK 17'), findsWidgets,
        reason: '破坏性操作必须点名要删的东西');
    expect(find.textContaining('Gradle'), findsWidgets);
    expect(find.textContaining('android.jar'), findsWidgets);
    expect(find.textContaining('502.0 MB'), findsWidgets,
        reason: '顺带说清能释放多少');
    expect(calls, isNot(contains('resetBuildSuite')),
        reason: '还没确认就跑重置 = 误删');
  });

  testWidgets('★★★ 确认 ⇒ reset + 重查 buildSuiteStatus + 卡片回未安装 + 报释放量',
      (tester) async {
    await pumpScreen(tester);
    final statusCallsBefore =
        calls.where((c) => c == 'buildSuiteStatus').length;

    await tester.tap(uninstallButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('卸载').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls, contains('resetBuildSuite'), reason: '确认后必须真的下发卸载');
    expect(calls.where((c) => c == 'buildSuiteStatus').length,
        greaterThan(statusCallsBefore),
        reason: '卸载后必须**重查**状态，不能凭 reset 返回值就宣布成功');

    await tester.pumpAndSettle();
    expect(find.text('编译环境 · 未安装'), findsOneWidget,
        reason: '重查后卡片必须回到未安装');
    expect(find.widgetWithText(FilledButton, '下载'), findsOneWidget,
        reason: '未安装时才重新出现下载入口');
    expect(find.textContaining('已卸载'), findsOneWidget,
        reason: '成功要明确说卸载了');
    expect(find.textContaining('释放'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('★★★ 卸载后仍有残留 ⇒ 人话说剩多少/在哪，不谎报干净',
      (tester) async {
    resetReply = <String, Object?>{
      'ok': true,
      'ready': false,
      'installDir': installDir,
      'removed': <String>['/opt/t2'],
      'failed': <Object?>[],
      'freedBytes': 379802368, // 362.2 MB
      'residualBytes': 126582784, // 剩下的 120.7 MB
      'missing': <String>['JDK 17（javac）'],
      'message': '已卸载 T2 编译环境：释放 362.2 MB',
    };
    await pumpScreen(tester);

    await tester.tap(uninstallButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('卸载').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('残留'), findsOneWidget,
        reason: '有残留就不能说"卸载干净了"');
    expect(find.textContaining('120.7 MB'), findsOneWidget,
        reason: '残留多少要说具体数字');
    expect(find.textContaining('已卸载'), findsNothing,
        reason: '残留时不要用"已卸载"这种完成态措辞');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('★★★ 卸载失败（仍就绪 + 删除失败项）⇒ 人话原因，卡片不被打回未安装',
      (tester) async {
    applyResetEffect = false;
    resetReply = <String, Object?>{
      'ok': false,
      'ready': true,
      'installDir': installDir,
      'removed': <String>[],
      'failed': <Object?>[
        {'path': '/opt/t2', 'reason': '删除失败（路径仍存在）'},
      ],
      'freedBytes': 0,
      'missing': <String>[],
      'message': 'T2 卸载未完全成功：失败 1 项',
    };
    await pumpScreen(tester);

    await tester.tap(uninstallButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('卸载').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('卸载未完成'), findsOneWidget,
        reason: '失败必须如实说，不能画成成功');
    expect(find.textContaining('/opt/t2'), findsOneWidget,
        reason: '要指出是哪一项没删掉');
    expect(find.text('编译环境 · 已就绪'), findsOneWidget,
        reason: '仍就绪时卡片不能被打成未安装（那是假状态）');
    await tester.pump(const Duration(seconds: 3));
  });
}
