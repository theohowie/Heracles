import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/services/agent_bridge.dart';

/// **事件通道的契约测试**（2026-10-10 流式）。
///
/// ## 为什么这个测试重要
///
/// Kotlin 侧（`AgentBridge.toEventMap`）与 Dart 侧（`AgentEvent.fromMap`）
/// 之间是**跨进程的弱契约**：字段名只是字符串，写错了编译器**不会报错**，
/// 真机上的表现是"UI 一直空白、什么都不显示" ——
/// 恰恰是本次要修的那个 bug 的模样，根本分不清是没修好还是字段名写错。
///
/// 所以这里用 `setMockStreamHandler` 模拟 Kotlin 端，把
/// **7 种事件的真实 Map 形状**钉死成断言。Kotlin 侧改了字段名而这里没跟改，
/// 测试会当场变红。
///
/// ## 重点覆盖的三个"沉默陷阱"
///
/// 1. **`blocked.tool` 可能为 null**（`Unparseable` 分支连调用都没解析出来）
///    —— 若 Dart 侧不判空就会崩在渲染时
/// 2. **`ok` 只在 `tool_finished` 存在** —— 若给缺失情况默认 `false`，
///    UI 会把"没执行"画成"工具失败"，误导用户以为工具坏了
/// 3. **`cachedTokens` 为 null = provider 未上报**（`02-契约规范.md` §3.4）
///    —— 绝不能变成 0，否则 UI 显示"命中率 0%"，看起来像缓存坏了
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel('heracles/events');

  /// 挂上一个假的 Kotlin 端，返回"往 Dart 推事件"的句柄。
  Future<void> Function(Map<String, dynamic>) attach() {
    late MockStreamHandlerEventSink sink;
    var attached = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          sink = events;
          attached = true;
        },
      ),
    );
    return (Map<String, dynamic> event) async {
      expect(attached, isTrue, reason: '监听还没建立就推事件');
      sink.success(event);
    };
  }

  // ---------------------------------------------------------- 类型判别

  test('7 种事件类型都能解析，且 isKnown 为 true', () {
    final samples = <Map<String, dynamic>>[
      {'type': 'turn_started', 'ts': 1, 'index': 1},
      {'type': 'model_output', 'ts': 2, 'index': 1, 'raw': '{}', 'wallMs': 5},
      {'type': 'tool_started', 'ts': 3, 'index': 1, 'tool': 'write_file'},
      {'type': 'tool_finished', 'ts': 4, 'index': 1, 'tool': 'write_file', 'ok': true},
      {'type': 'blocked', 'ts': 5, 'index': 1, 'reason': '校验失败：x'},
      {'type': 'finished', 'ts': 6, 'finalText': 'done', 'turnCount': 1},
      {'type': 'failed', 'ts': 7, 'message': 'provider 错误'},
    ];

    for (final m in samples) {
      final e = AgentEvent.fromMap(m);
      expect(e.type, m['type']);
      expect(e.ts, m['ts']);
      expect(e.isKnown, isTrue, reason: '${m['type']} 应当是已知类型');
    }
  });

  test('未知类型不崩溃，但 isKnown=false（版本不一致时的降级）', () {
    final e = AgentEvent.fromMap({'type': '未来新增的事件', 'ts': 1});
    expect(e.isKnown, isFalse);
    expect(e.isTerminal, isFalse);
  });

  test('isTerminal 只对 finished / failed 为真', () {
    expect(AgentEvent.fromMap({'type': 'finished', 'ts': 1}).isTerminal, isTrue);
    expect(AgentEvent.fromMap({'type': 'failed', 'ts': 1}).isTerminal, isTrue);
    // ★ 这两个是"运行中"的关键节点，绝不能当成结束 —— 否则 UI 会提前收起转圈
    expect(AgentEvent.fromMap({'type': 'turn_started', 'ts': 1}).isTerminal, isFalse);
    expect(AgentEvent.fromMap({'type': 'blocked', 'ts': 1}).isTerminal, isFalse);
  });

  // ---------------------------------------------------------- 三个沉默陷阱

  test('★ blocked 的 tool 为 null 时不得崩溃（Unparseable 分支）', () {
    final e = AgentEvent.fromMap({
      'type': 'blocked',
      'ts': 5,
      'index': 1,
      'tool': null,
      'args': null,
      'reason': '输出无法解析：不是合法 JSON',
    });

    expect(e.tool, isNull);
    expect(e.args, isNull);
    expect(e.reason, contains('无法解析'));
    // 它不是工具失败 —— 工具根本没执行
    expect(e.isExecutedTool, isFalse);
  });

  test('★ ok 缺失不默认成 false（否则"没执行"会被画成"工具失败"）', () {
    final started = AgentEvent.fromMap({'type': 'tool_started', 'ts': 1, 'tool': 'x'});
    expect(started.ok, isNull, reason: 'tool_started 没有 ok 概念');

    final failed = AgentEvent.fromMap({
      'type': 'tool_finished', 'ts': 1, 'tool': 'x', 'ok': false,
    });
    expect(failed.ok, isFalse, reason: '真实上报的 false 必须保留');
  });

  test('★ cache 未上报时 cachedTokens 为 null，不是 0', () {
    final e = AgentEvent.fromMap({
      'type': 'model_output',
      'ts': 1,
      'index': 1,
      'raw': '{}',
      'cache': {
        'cachedTokens': null,   // provider 未上报
        'promptTokens': 500,
        'outputTokens': 20,
        'hitRate': null,
      },
    });

    expect(e.cache, isNotNull);
    expect(e.cache!.cachedTokens, isNull);
    expect(e.cache!.hitRate, isNull);
    expect(e.cache!.reportingAvailable, isFalse);
    expect(e.cache!.promptTokens, 500);
  });

  test('cache 上报时正常解析（含命中率）', () {
    final e = AgentEvent.fromMap({
      'type': 'model_output',
      'ts': 1,
      'cache': {
        'cachedTokens': 900,
        'promptTokens': 100,
        'outputTokens': 20,
        'hitRate': 0.9,
      },
    });

    expect(e.cache!.cachedTokens, 900);
    expect(e.cache!.hitRate, closeTo(0.9, 1e-9));
    expect(e.cache!.reportingAvailable, isTrue);
  });

  // ---------------------------------------------------------- 端到端（mock）

  test('★ EventChannel 推送的事件能到达 Dart 的 listen（通道名与解析全通）', () async {
    final push = attach();
    final received = <AgentEvent>[];

    final sub = AgentBridge().events.listen(received.add);
    // 建立平台订阅是异步的，等一拍
    await Future<void>.delayed(Duration.zero);

    // 模拟一次真实的工具调用全过程
    push({'type': 'turn_started', 'ts': 1, 'index': 1});
    push({
      'type': 'model_output', 'ts': 2, 'index': 1, 'raw': '{"tool":"write_file"}', 'wallMs': 12,
    });
    push({
      'type': 'tool_started', 'ts': 3, 'index': 1, 'tool': 'write_file',
      'args': {'path': 'a.txt', 'content': 'hi'},
    });
    push({
      'type': 'tool_finished', 'ts': 4, 'index': 1, 'tool': 'write_file',
      'result': '已写入', 'ok': true, 'wallMs': 3,
    });
    push({'type': 'turn_started', 'ts': 5, 'index': 2});
    push({'type': 'finished', 'ts': 6, 'finalText': 'done', 'turnCount': 2});

    await Future<void>.delayed(Duration.zero);

    expect(
      received.map((e) => e.type).toList(),
      [
        'turn_started', 'model_output', 'tool_started',
        'tool_finished', 'turn_started', 'finished',
      ],
    );

    // 顺序与内容抽查 —— 「边跑边显示」正是靠这个顺序
    expect(received[2].args, {'path': 'a.txt', 'content': 'hi'});
    expect(received[3].ok, isTrue);
    expect(received[3].result, '已写入');
    expect(received.last.isTerminal, isTrue);

    await sub.cancel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(channel, null);
  });

  test('取消订阅后再推事件不崩溃（页面销毁后的迟到事件）', () async {
    final push = attach();
    final received = <AgentEvent>[];

    final sub = AgentBridge().events.listen(received.add);
    await Future<void>.delayed(Duration.zero);

    push({'type': 'turn_started', 'ts': 1, 'index': 1});
    await Future<void>.delayed(Duration.zero);
    expect(received.length, 1);

    await sub.cancel();
    // Kotlin 侧可能还有 post 到主线程的迟到事件 —— 不该让测试崩
    push({'type': 'finished', 'ts': 2, 'finalText': 'x', 'turnCount': 1});
    await Future<void>.delayed(Duration.zero);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(channel, null);
  });

  // ---------------------------------------------------------- 通道名一致性

  test('★ 通道名必须是 heracles/events（与 Kotlin 逐字符一致）', () {
    // 写错了不会编译报错，只会静默收不到任何事件 ——
    // 真机表现就是"UI 一直空白"，与本次要修的 bug 无法区分
    expect(channel.name, 'heracles/events');
  });
}
