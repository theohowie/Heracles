import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/services/agent_bridge.dart';

/// **事件词表 + 事件传输的契约测试**（2026-10-10 流式；2026-10-25 换传输）。
///
/// ## ★★ 口径变更（2026-10-25，mock 回家第二批）—— 读这个文件前必须先看
///
/// 本文件原名叫「事件通道的契约测试」，mock 的是 **Kotlin 时代的
/// `EventChannel('heracles/events')`**（`setMockStreamHandler` + `sink.success`）。
/// 那条传输**已于 2026-10-22 删除**（见 `agent_bridge.dart` 顶部注释）：
/// Kotlin 侧 handler 随 `AgentBridge.kt` 一起消失，事件改由**同一进程内**的
/// `HeraclesAgent` 产出，走：
///
/// ```
/// LocalAgentExecutor.handle.events
///   → AgentBridge.emitLocalEvent          （run() 的事件泵）
///   → _localEvents（静态广播流）
///   → AgentBridge.events → chat_screen 的订阅
/// ```
///
/// 于是原文件里的两条断言**今天不成立/无意义**，各自被等价替换：
///
/// | 旧断言 | 今天的状态 | 换成了什么 |
/// |---|---|---|
/// | 「EventChannel 推送能到达 Dart 的 listen」 | **不可能通过**（通道已删，`attach()` 的 `onListen` 永不被调用 ⇒ 变红） | 「`emitLocalEvent` → `AgentBridge.events` 全序到达」——钉**新传输**的唯一入口 |
/// | 「通道名必须是 `heracles/events`（与 Kotlin 逐字符一致）」 | **重言式**（常量与自己比；今天没有任何生产代码读那个名字） | 「多实例共享同一条广播流」+「没订阅就收不到（不缓冲）」+「取消后不再投递」——都是真性质 |
///
/// ⚠️ 通道名那条**不再断言"没有 EventChannel"**：`app/lib` 里对它零构造，
/// 断言"某个私有实现不存在"既脆又测不到东西。真正的回归保护是
/// **UI 订阅的就是这条进程内流** —— 那由 `chat_streaming_test` /
/// `blocked_tool_state_test` / `stream_render_test` 里"事件到达 → 界面立刻变化"
/// 的端到端断言承担（它们走 `executorFactoryForTest` → `emitLocalEvent`）。
///
/// ## fromMap 那一段今天保护什么（如实说明，不粉饰）
///
/// `AgentEvent.fromMap` 是**序列化适配器**（Map 形状 → UI 认识的字段）。
/// ⚠️ **它今天没有任何生产调用者**：生产直接 `AgentEvent(...)` 构造
/// （见 `local_agent.dart` 的 `_Translator`）。所以这一段钉的是**词表本身**：
/// 字段名与三个"沉默陷阱"的 null 语义（`blocked.tool` 可为 null、
/// `ok` 只在 `tool_finished` 存在、`cachedTokens` 未上报 = null 而不是 0）。
/// 它同时是 translator 字段对齐的依据（`local_agent.dart` 的 KDoc 明写
/// 「以 `AgentEvent.fromMap` 为准，逐字段对齐」）——**保留而不删**，
/// 因为将来若把事件重新序列化（跨 isolate / 落盘回放）它就是唯一入口。
/// ⚠️ 但**不许**把它读成"事件传输有测试保护"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 一次完整工具调用的 6 条事件 —— 与旧 EventChannel mock 的类型与顺序逐条对应，
  /// 只是**构造方式**从"平台端推 Map"换成"进程内构造"（生产同形）。
  const fullSequence = <AgentEvent>[
    AgentEvent(type: AgentEvent.kTurnStarted, ts: 1, index: 1),
    AgentEvent(
      type: AgentEvent.kModelOutput,
      ts: 2,
      index: 1,
      raw: '{"tool":"write_file"}',
      wallMs: 12,
    ),
    AgentEvent(
      type: AgentEvent.kToolStarted,
      ts: 3,
      index: 1,
      tool: 'write_file',
      args: {'path': 'a.txt', 'content': 'hi'},
    ),
    AgentEvent(
      type: AgentEvent.kToolFinished,
      ts: 4,
      index: 1,
      tool: 'write_file',
      result: '已写入',
      ok: true,
      wallMs: 3,
    ),
    AgentEvent(type: AgentEvent.kTurnStarted, ts: 5, index: 2),
    AgentEvent(
      type: AgentEvent.kFinished,
      ts: 6,
      finalText: 'done',
      turnCount: 2,
    ),
  ];

  // ==================================================================
  // A. 事件**词表**（fromMap —— 见文件头：今天无生产调用者，钉的是字段语义）
  // ==================================================================

  // ---------------------------------------------------------- 类型判别

  test('7 种事件类型都能解析，且 isKnown 为 true', () {
    final samples = <Map<String, dynamic>>[
      {'type': 'turn_started', 'ts': 1, 'index': 1},
      {'type': 'model_output', 'ts': 2, 'index': 1, 'raw': '{}', 'wallMs': 5},
      {'type': 'tool_started', 'ts': 3, 'index': 1, 'tool': 'write_file'},
      {
        'type': 'tool_finished',
        'ts': 4,
        'index': 1,
        'tool': 'write_file',
        'ok': true,
      },
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
    expect(
        AgentEvent.fromMap({'type': 'finished', 'ts': 1}).isTerminal, isTrue);
    expect(AgentEvent.fromMap({'type': 'failed', 'ts': 1}).isTerminal, isTrue);
    // ★ 这两个是"运行中"的关键节点，绝不能当成结束 —— 否则 UI 会提前收起转圈
    expect(AgentEvent.fromMap({'type': 'turn_started', 'ts': 1}).isTerminal,
        isFalse);
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
    final started =
        AgentEvent.fromMap({'type': 'tool_started', 'ts': 1, 'tool': 'x'});
    expect(started.ok, isNull, reason: 'tool_started 没有 ok 概念');

    final failed = AgentEvent.fromMap({
      'type': 'tool_finished',
      'ts': 1,
      'tool': 'x',
      'ok': false,
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
        'cachedTokens': null, // provider 未上报
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

  // ==================================================================
  // B. 事件**传输**（进程内广播流；旧 EventChannel 那条的等价物）
  // ==================================================================

  test('★★ emitLocalEvent → AgentBridge.events 是 UI 的事件通路，且顺序逐条不丢',
      () async {
    final received = <AgentEvent>[];
    final sub = AgentBridge().events.listen(received.add);
    addTearDown(sub.cancel);

    // ★ 刻意**不装任何平台通道 handler**：这条路上不该有平台端。
    //   若有人把 `events` 改回 `EventChannel(...).receiveBroadcastStream()`，
    //   下面的事件一条都到不了 ⇒ 本用例变红。
    for (final e in fullSequence) {
      AgentBridge.emitLocalEvent(e);
    }
    // 广播流默认异步投递（`StreamController.broadcast()` 的 sync=false）
    await Future<void>.delayed(Duration.zero);

    expect(
      received.map((e) => e.type).toList(),
      [
        'turn_started',
        'model_output',
        'tool_started',
        'tool_finished',
        'turn_started',
        'finished',
      ],
      reason: '顺序就是"边跑边显示"的全部含义，一条都不能丢/不能换位',
    );

    // 顺序与内容抽查（原来钉在旧 EventChannel mock 上的那几条）
    expect(received[2].args, {'path': 'a.txt', 'content': 'hi'});
    expect(received[3].ok, isTrue);
    expect(received[3].result, '已写入');
    expect(received.last.isTerminal, isTrue);
  });

  test('★★ 多实例共享同一条广播流（UI 订阅的实例 ≠ 真正在跑的实例时事件全丢）',
      () async {
    // ★ 为什么必须钉这条：`_localEvents` 是**静态**的，而 `AgentBridge`
    //   在生产里会被多处置新（`chat_screen` 一个、`run()` 一个……）。
    //   若它退回成实例字段，UI 订阅的流与 `emitLocalEvent` 推的流就不是同一条
    //   ⇒ 界面永远停在"正在生成…"，且**不报任何错**。
    final ui = AgentBridge();
    final runner = AgentBridge();
    final gotUi = <AgentEvent>[];
    final gotOther = <AgentEvent>[];

    final s1 = ui.events.listen(gotUi.add);
    final s2 = runner.events.listen(gotOther.add);
    addTearDown(s1.cancel);
    addTearDown(s2.cancel);

    AgentBridge.emitLocalEvent(
      const AgentEvent(type: AgentEvent.kTurnStarted, ts: 1, index: 1),
    );
    await Future<void>.delayed(Duration.zero);

    expect(gotUi.length, 1, reason: 'UI 的订阅必须收到 run 推的事件');
    expect(gotOther.length, 1,
        reason: '广播流：多个订阅者都要收到（会话区 + 将来的调试面板）');
  });

  test('★ 没有订阅者时推的事件被丢弃（广播流不缓冲 —— UI 必须在 run 之前订阅）',
      () async {
    // ★ 这条不是洁癖：`chat_screen._runAgent` 先 `_startLive()`（订阅）
    //   再 `await _bridge.run(...)`，就是靠这个性质。若流会缓冲，
    //   "订阅晚一拍就丢事件" 这个真问题会被掩盖，而不是被这条测试暴露。
    AgentBridge.emitLocalEvent(
      const AgentEvent(type: AgentEvent.kTurnStarted, ts: 1, index: 1),
    );

    final late = <AgentEvent>[];
    final sub = AgentBridge().events.listen(late.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);

    expect(late, isEmpty,
        reason: '广播流不缓冲：订阅之前推的事件收不到（这正是 UI 先订阅的原因）');
  });

  test('★ 取消订阅后再推事件不崩溃、也不再投递（页面销毁后的迟到事件）', () async {
    final received = <AgentEvent>[];
    final sub = AgentBridge().events.listen(received.add);

    AgentBridge.emitLocalEvent(
      const AgentEvent(type: AgentEvent.kTurnStarted, ts: 1, index: 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(received.length, 1);

    await sub.cancel();
    // 生产里"迟到事件"来自广播流的异步投递窗口 —— 不该让测试崩，
    // 也不该再改已经切走的界面。
    AgentBridge.emitLocalEvent(const AgentEvent(
        type: AgentEvent.kFinished, ts: 2, finalText: 'x', turnCount: 1));
    await Future<void>.delayed(Duration.zero);

    expect(received.length, 1,
        reason: '取消之后不该再收到事件 —— 否则切会话后旧事件还在改界面（t7 语义）');
  });
}