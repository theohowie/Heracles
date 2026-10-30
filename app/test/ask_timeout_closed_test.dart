// Copyright (C) 2026 The Heracles Authors
//
// **P0（2026-10-30）：ask 超时 300s + `ask_closed` 事件**。
//
// ============================================================================
// 规格
// ============================================================================
// · `defaultAnswerTimeout` = **5 分钟（300s）**（原 10 分钟；与审批超时同口径）；
// · 超时仍按"未回答"返回 null（backend 如实告诉模型，**绝不编答案**），
//   并发一条 `AgentEvent.kAskClosed{outcome:"timeout"}`；
// · 用户停止/取消解挂 ⇒ `{outcome:"aborted"}`；
// · 用户**正常提交/跳过**（`replyAsk`）⇒ **不发**该事件；
// · 同一提问只发**一次**（超时/取消互斥，不重复）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/agent_bridge.dart' show AgentEvent;
import 'package:heracles/services/local_agent.dart';
import 'package:heracles_backend/heracles_backend.dart';

const _questions = [
  AskQuestion(id: 'q1', question: '选哪个方案？', multi: false, options: []),
];

List<AgentEvent> askClosed(List<AgentEvent> events) =>
    events.where((e) => e.type == AgentEvent.kAskClosed).toList();

void main() {
  test('★★★ defaultAnswerTimeout = 5 分钟（300s）', () {
    expect(LocalAskGate.defaultAnswerTimeout, const Duration(minutes: 5));
    expect(LocalAskGate.defaultAnswerTimeout.inSeconds, 300);
    // 审批超时保持独立 5 分钟（未被本次改动波及）
    expect(LocalAskGate.defaultApprovalTimeout, const Duration(minutes: 5));
  });

  test('★★★ 不到超时不判：200ms 超时，50ms 时仍挂着且无事件；到点 null+一次 timeout',
      () async {
    final events = <AgentEvent>[];
    final gate = LocalAskGate(answerTimeout: const Duration(milliseconds: 200))
      ..attach(events.add);

    final fut = gate.askUser(_questions);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(gate.hasPendingAsk, isTrue, reason: '还没到超时点，不能提前判"未回答"');
    expect(askClosed(events), isEmpty, reason: '★ 不到点不许发 ask_closed');

    final answer = await fut;
    expect(answer, isNull, reason: '★ 超时 = 未回答（绝不编答案）');
    final closed = askClosed(events);
    expect(closed, hasLength(1), reason: '★ 超时恰好发一次 ask_closed');
    expect(closed.single.outcome, 'timeout');
    expect(gate.hasPendingAsk, isFalse);
  });

  test('★★★ 用户停止（abort）解挂 ⇒ null + 一次 aborted', () async {
    final events = <AgentEvent>[];
    final gate = LocalAskGate()..attach(events.add);

    final fut = gate.askUser(_questions);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(gate.hasPendingAsk, isTrue);
    gate.abort();

    expect(await fut, isNull, reason: '取消 = 没答案（不编造）');
    final closed = askClosed(events);
    expect(closed, hasLength(1));
    expect(closed.single.outcome, 'aborted');
    expect(gate.hasPendingAsk, isFalse);

    // 再 abort 一次：不许多发（同一提问只关一次）
    gate.abort();
    expect(askClosed(events), hasLength(1), reason: '★ 只发一次');
  });

  test('★★★ 正常提交（replyAsk）⇒ **不发** ask_closed', () async {
    final events = <AgentEvent>[];
    final gate = LocalAskGate()..attach(events.add);

    final fut = gate.askUser(_questions);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(gate.hasPendingAsk, isTrue);
    expect(await gate.replyAsk({'q1': ['方案 A']}), isTrue);
    final answer = await fut;
    expect(answer, contains('方案 A'));
    expect(askClosed(events), isEmpty,
        reason: '★ 正常提交由 UI 自己收气泡，不发 ask_closed');
  });

  test('★★ 事件已登记：fromMap 认识 ask_closed 且读到 outcome', () {
    final ev = AgentEvent.fromMap(<String, dynamic>{
      'type': 'ask_closed',
      'ts': 1,
      'outcome': 'timeout',
    });
    expect(ev.type, AgentEvent.kAskClosed);
    expect(ev.isKnown, isTrue, reason: '★ 必须进 _knownTypes（老读者忽略未知事件）');
    expect(ev.outcome, 'timeout');
    // 缺 outcome 的老帧：按 null，不猜
    final old = AgentEvent.fromMap(<String, dynamic>{
      'type': 'ask_closed',
      'ts': 1,
    });
    expect(old.outcome, isNull);
  });

  test('★★ 没 UI 出口 / 已 aborted ⇒ 不弹窗也不发事件（既有语义不变）', () async {
    final noUi = LocalAskGate(); // 未 attach
    expect(await noUi.askUser(_questions), isNull);

    final events = <AgentEvent>[];
    final aborted = LocalAskGate()..attach(events.add);
    aborted.abort();
    expect(await aborted.askUser(_questions), isNull);
    expect(askClosed(events), isEmpty,
        reason: '根本没弹过窗，就没有"关闭"可发');
  });
}
