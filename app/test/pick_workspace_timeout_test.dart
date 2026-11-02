import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles_backend/heracles_backend.dart' show ContractFolderPicker;

import 'package:heracles/services/agent_bridge.dart';

/// **`pickWorkspace` 的超时与结果回收**（2026-11-02 · T0 SAF 黑屏修复）。
///
/// ## 这些用例防的是什么
///
/// 用户报的现象：「侧边栏点选择文件夹 → 选好目录返回 → App 黑屏」。
/// 根因链条有两段，这里锁第二段（第一段在 Kotlin 的进程级登记表）：
///
/// 1. SAF 选择器在前台时 Activity 被系统回收 ⇒ 回包永远不来；
/// 2. 旧 Dart 实现**没有超时** ⇒ `await` 永久挂起 ⇒ 界面就那么卡着。
///
/// 所以断言的是：
/// - 每次调用都带 `requestId`（不带就没法证明/找回是"哪一次"的结果）；
/// - 永不回包时**必须**在契约时限内抛出人话错误，而不是挂死；
/// - 超时但结果**其实已经产出**时，要能取回来当成功用（否则用户白选一次，
///   还会看到一句假的"失败"）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('heracles/command');
  late List<MethodCall> calls;

  void mock(Future<Object?>? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls = [];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('★ 调用必须带 requestId —— 超时后靠它找回结果', () async {
    mock((call) async {
      if (call.method == 'pickWorkspace') {
        return <String, dynamic>{'id': '/w', 'name': 'w', 'path': '/w'};
      }
      return null;
    });

    final ws = await AgentBridge().pickWorkspace();

    expect(ws?['path'], '/w');
    final arg = calls.first.arguments as Map?;
    expect(arg, isNotNull);
    expect(arg!['requestId'], isA<String>());
    expect((arg['requestId'] as String).isNotEmpty, isTrue);
  });

  test('★★ 永不回包 ⇒ 超时抛人话错误，不许永久挂起', () async {
    // 模拟"Activity 被系统回收、回包永远不来"：返回一个永不完成的 Future。
    mock((call) {
      if (call.method == 'pickWorkspace') return Completer<Object?>().future;
      return Future<Object?>.value(null); // consumePickWorkspaceResult 也拿不到
    });

    final started = DateTime.now();
    await expectLater(
      AgentBridge().pickWorkspace(timeout: const Duration(milliseconds: 120)),
      throwsA(
        isA<AgentBridgeException>().having(
          (e) => e.message,
          'message',
          ContractFolderPicker.timeoutMessage,
        ),
      ),
    );
    // 兜底：确实在超时附近返回，而不是靠 30s 的测试框架超时"变成失败"
    expect(DateTime.now().difference(started).inSeconds, lessThan(10));
  });

  test('★★ 超时但结果已产出 ⇒ 取回来当成功，不误报失败', () async {
    mock((call) {
      if (call.method == 'pickWorkspace') return Completer<Object?>().future;
      if (call.method == ContractFolderPicker.recoverMethod) {
        return Future<Object?>.value(
          <String, dynamic>{'id': '/picked', 'name': 'picked', 'path': '/picked'},
        );
      }
      return Future<Object?>.value(null);
    });

    final ws = await AgentBridge()
        .pickWorkspace(timeout: const Duration(milliseconds: 120));

    expect(ws?['path'], '/picked');
    // 回收时也必须带上同一个 requestId，否则可能拿到别人的结果
    final pickArg =
        calls.firstWhere((c) => c.method == 'pickWorkspace').arguments as Map;
    final recArg = calls
        .firstWhere((c) => c.method == ContractFolderPicker.recoverMethod)
        .arguments as Map;
    expect(recArg['requestId'], pickArg['requestId']);
  });

  test('正常回包不走回收通道（别为了兜底把主路径拖慢）', () async {
    mock((call) async {
      if (call.method == 'pickWorkspace') {
        return <String, dynamic>{'id': '/fast', 'name': 'fast', 'path': '/fast'};
      }
      return null;
    });

    final ws = await AgentBridge().pickWorkspace();

    expect(ws?['path'], '/fast');
    expect(
      calls.any((c) => c.method == ContractFolderPicker.recoverMethod),
      isFalse,
    );
  });

  test('取消（宿主回 null）⇒ 回 null，不抛也不挂起', () async {
    mock((call) async {
      if (call.method == 'pickWorkspace') return null;
      return null;
    });

    expect(await AgentBridge().pickWorkspace(), isNull);
    expect(
      calls.any((c) => c.method == ContractFolderPicker.recoverMethod),
      isFalse,
      reason: '正常取消不该走"回收"那条路',
    );
  });

  test('★★ 后台（系统选择器盖住我们）不计时 —— 挑多久都不许误报失败', () async {
    // 真机证据：用户在选择器里待了 70 秒，结果**正常返回**（res=-1），
    // 但固定 45s 的 `Future.timeout` 早在半路判了死刑，UI 谎报"结果已丢失"。
    // 这里锁住修正后的口径：只有 App 在前台时才走表。
    mock((call) {
      if (call.method == 'pickWorkspace') return Completer<Object?>().future;
      return Future<Object?>.value(null);
    });

    final binding = TestWidgetsFlutterBinding.instance;
    // 进后台 = 选择器在前台
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

    var threw = false;
    final fut = AgentBridge()
        .pickWorkspace(timeout: const Duration(milliseconds: 120))
        .catchError((Object e) {
      threw = true;
      return <String, dynamic>{};
    });

    // 后台待了 400ms（> 120ms 的额度）：**不该**判超时
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(threw, isFalse,
        reason: '后台停表：用户还在系统选择器里挑，不能算我们干等');

    // 回到前台：重新开始走表
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(threw, isTrue,
        reason: '回到前台后必须恢复兜底 —— 否则真的丢了结果就永远挂着');

    await fut;
  });

  test('旧宿主（没有 consumePickWorkspaceResult）⇒ 降级成超时提示，不抛未捕获异常', () async {
    mock((call) {
      if (call.method == 'pickWorkspace') return Completer<Object?>().future;
      // 旧宿主：通道上根本没有这个方法 ⇒ MissingPluginException
      throw MissingPluginException('no such method');
    });

    await expectLater(
      AgentBridge().pickWorkspace(timeout: const Duration(milliseconds: 100)),
      throwsA(isA<AgentBridgeException>()),
    );
  });
}
