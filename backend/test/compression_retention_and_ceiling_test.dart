// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **压缩的"保留什么"与"不许硬发"** 回归闸（2026-11-04，用户确认的第 3/4 条改法）。
//
// ## 背景（用户质问）
//
// 「120% 的上下文占用？难道不是到 90% 就要自己压缩吗？压缩就是保留上下文里
//  最关键的信息」—— 用户随后批准了两条改法：
//
// 1. **摘要按结构化保留清单做**（对齐 Anthropic compaction 实践：
//    保留架构决策 / 未解决 bug / 实现细节，丢弃冗余工具输出）；
// 2. **发送硬顶 90%**：压不下来就不许发，宁可这一轮明确失败 ——
//    因为有的网关会**静默截断历史**，模型"莫名失忆"比报错更坏。
//
// ## 本文件锁住的契约
//
// | # | 契约 | 抓的缺陷 |
// |---|---|---|
// | ① | 摘要请求里必须包含"保留清单"提示词 | 退化成自由要点，漏掉用户硬约束 |
// | ② | 摘要结果落地成**结构化笔记**并插在历史最前 | 压缩后模型不知道自己被压缩过 |
// | ③ | 摘要失败 ⇒ 回退到确定性重置（不许什么都不做） | "摘要静默失败 = 未压缩" |
// | ④ | 压完仍 ≥ 90% ⇒ **抛可见异常**（不许把注定超限的请求发出去） | 120% 硬发、被网关静默截断 |
library;

import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 记录收到的 messages、回一段**带六个标签**的结构化摘要。
class _StructuredClient implements LLMClient {
  final List<List<LLMMessage>> seen = [];

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    seen.add(List.of(messages));
    return ModelMessage(
      model: modelConfig.model,
      stopReason: 'stop',
      textOutput: '<goal>做雨夜便利店街角</goal>'
          '<constraints>不要动 chatgpt6-luna-index.html</constraints>'
          '<decisions>用单文件 HTML + CSS 3D</decisions>'
          '<files>deepseek-v41-flash-index.html（已写入初稿）</files>'
          '<open_issues>灯泡过曝，未解决</open_issues>'
          '<plan>下一步调暗环境光</plan>',
    );
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async =>
      const Stream<StreamingMessage>.empty();
}

/// 摘要一定失败（返回空）。
class _FailingSummaryClient implements LLMClient {
  int calls = 0;
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    calls++;
    return ModelMessage(model: modelConfig.model, stopReason: 'stop', textOutput: '');
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async =>
      const Stream<StreamingMessage>.empty();
}

/// 造一段长对话（每条 90 个汉字 ≈ 90 token）。
List<LLMMessage> _manyTurns(int n) =>
    [for (var i = 0; i < n; i++) UserMessage.text('字' * 90)];

/// 造一个压缩器。
///
/// ⚠️ **默认关掉 Session Memory**（2026-11-06）：本文件的用例锁的都是
/// **API 结构化摘要**那条路径（保留清单 / 快照落地 / 失败回退）。
/// 阶段 2（本地记忆）默认开启时会把这类纯文本历史直接收进摘要视图、
/// **零 API** 搞定 —— 那是设计意图（省钱），但会让这里的"摘要请求"断言空转。
/// 所以显式关掉，让用例继续测它本来要测的那条路。
WindowRatioCompressor _c(LLMClient client,
        {int window = 10000,
        void Function(int, int, int, int)? onCompressed,
        bool sessionMemory = false}) =>
    WindowRatioCompressor(
      client: client,
      modelConfig: ModelConfig(model: 'stub'),
      modelWindowTokens: window,
      compactionConfig: CompactionConfig(sessionMemoryEnabled: sessionMemory),
      onCompressed: onCompressed,
    );

void main() {
  test('① 摘要请求带着"保留清单"提示词（不是自由发挥）', () async {
    final client = _StructuredClient();
    final state = AgentState(
      sessionId: 's1',
      history: AgentMessageHistory(messages: _manyTurns(96)), // ≈8640 ≥ 8500
    );

    await _c(client).compress(state);

    expect(client.seen, isNotEmpty, reason: '该压的时候必须真的发出摘要请求');
    final systemPrompt = (client.seen.first.first as SystemMessage).content;
    for (final must in ['goal', 'constraints', 'decisions', 'files', 'open_issues', 'plan']) {
      expect(systemPrompt, contains(must),
          reason: '★ 保留清单缺了 $must —— 模型会漏掉这类关键信息');
    }
  });

  test('② 摘要结果落成结构化笔记，且插在历史最前 + 保留最近几轮原文', () async {
    final client = _StructuredClient();
    final state = AgentState(
      sessionId: 's2',
      history: AgentMessageHistory(messages: _manyTurns(96)),
    );

    await _c(client).compress(state);

    final first = state.history.messages.first as UserMessage;
    final note = (first.contents.first as TextPart).text;
    expect(note, contains('[上下文压缩快照]'));
    expect(note, contains('不要动 chatgpt6-luna-index.html'),
        reason: '★ 用户硬约束必须在摘要里活下来');
    expect(note, contains('deepseek-v41-flash-index.html'));
    expect(state.history.messages.length, lessThan(96),
        reason: '压缩后必须真的变短');
    expect(state.history.messages.last, isA<UserMessage>(),
        reason: '最近轮次保留原文');
  });

  test('③ 摘要失败 ⇒ 回退确定性重置（不许什么都不做）', () async {
    final client = _FailingSummaryClient();
    var notified = 0;
    final state = AgentState(
      sessionId: 's3',
      history: AgentMessageHistory(messages: _manyTurns(96)),
    );

    await _c(client, onCompressed: (_, __, ___, ____) => notified++).compress(state);

    expect(client.calls, greaterThan(0), reason: '摘要请求发过（只是返回空）');
    expect(state.history.messages.length, lessThan(96),
        reason: '★ 摘要失败也必须靠第三级重置把历史压下来');
    final note = (state.history.messages.first as UserMessage).contents.first as TextPart;
    expect(note.text, contains('[系统维护]'),
        reason: '走的是"强制移除"这条路，要如实说，不许假装摘要成功');
    expect(notified, greaterThanOrEqualTo(1));
  });

  // ---- ④ 到 90% 不许报错、不许停：继续压，压到下限就照常继续（2026-11-05 用户裁定）----
  test('④ 压不下来时**不抛错**，而是继续把历史压到物理下限', () async {
    final client = _FailingSummaryClient();
    final state = AgentState(
      sessionId: 's4',
      history: AgentMessageHistory(messages: [
        UserMessage.text('前面的对话' * 500),
        UserMessage.text('字' * 40000), // 单条巨大：截断后仍超 90%
      ]),
    );
    final before = state.history.messages.length;
    var notified = 0;

    // ★ 关键：不能抛（抛 = 这一轮白跑，用户明确要求"压完接着干"）
    await _c(client, window: 10000,
            onCompressed: (_, __, ___, ____) => notified++)
        .compress(state);

    expect(notified, greaterThanOrEqualTo(1),
        reason: '必须真的动手压缩，而不是什么都不做');
    expect(state.history.messages.length, lessThanOrEqualTo(before),
        reason: '压缩只会让历史更短/更小，不许反而变长');
    // 巨量用户消息应被截断（保留头部 + 明确说明）
    final joined = state.history.messages
        .whereType<UserMessage>()
        .map((m) => (m.contents.first as TextPart).text)
        .join('\n');
    expect(joined, contains('已截断'),
        reason: '单条超长必须截断并写明原长度，而不是整轮失败');
  });
  // ---- ⑥ 单阈值 + 一次性：**同一份历史重复压缩不许反复改写** ----
  //
  // 这条替换了旧的"连续 3 次 micro 后强制升级"用例 —— 那个行为（micro 每轮跑、
  // 卡在 40% 线上）已被用户删除：真机实测它把缓存命中率压到 40%~48%。
  // 新契约：**压过一次之后，占用必须真的降下来；再调用 compress 什么都不做**
  //（否则每轮改写历史前缀 = 缓存灾难）。
  test('⑥ 压过一次后占用真降；同一份历史再调 compress 不许再改（缓存保护）', () async {
    final client = _StructuredClient();
    final c = _c(client, window: 10000); // 触发线 8500

    // 96 条 × 90 token ≈ 8640 ≥ 8500 ⇒ 必触发
    final state = AgentState(
      sessionId: 's6',
      history: AgentMessageHistory(messages: _manyTurns(96)),
    );

    await c.compress(state);

    final afterFirst = c.estimateUsage(state);
    expect(afterFirst, lessThan(8500),
        reason: '★ 压过之后必须真的低于触发线（否则下一轮立刻又压，缓存白丢）');
    expect(client.seen, isNotEmpty, reason: '该走 API 摘要的时候要走');
    final messagesAfterFirst = List<LLMMessage>.of(state.history.messages);

    // 再调 3 次：历史必须**一个字节都不变**，且不许再发一次摘要请求
    final callsAfterFirst = client.seen.length;
    for (var round = 0; round < 3; round++) {
      await c.compress(state);
    }

    expect(state.history.messages.length, messagesAfterFirst.length,
        reason: '★★ 已经低于触发线 ⇒ 后续 compress 必须零副作用');
    for (var i = 0; i < messagesAfterFirst.length; i++) {
      expect(
        WindowRatioCompressor.estimateMessageTokens(state.history.messages[i]),
        WindowRatioCompressor.estimateMessageTokens(messagesAfterFirst[i]),
        reason: '★★ 第 $i 条被改写了 —— 前缀缓存会全废',
      );
    }
    expect(client.seen.length, callsAfterFirst,
        reason: '★★ 低于触发线时一次摘要调用都不许再发（花钱 + 改写历史）');
  });
  // ---- ⑤ 分项与总量必须对得上（用户："这个环形图不是真实占比"）----
  group('⑤ 分项按真实总量等比放大', () {
    test('放大后各分项之和精确等于真实总量', () {
      final parts = <String, int>{
        'system': 2700,
        'toolDefs': 10600,
        'toolResults': 4700,
        'reasoning': 0,
        'assistant': 1800,
        'user': 25,
        'summary': 0,
      }; // 合计 19825（真机 11:35 那屏）
      final scaled = WindowRatioCompressor.scaleToRealTotal(parts, 104000);

      expect(scaled.values.fold<int>(0, (a, b) => a + b), 104000,
          reason: '★ 屏幕上"分项加起来"必须等于总量，否则用户只会认为数字是假的');
      expect(scaled.keys.toSet(), parts.keys.toSet(), reason: '键不许变（UI 只认固定键）');
      expect(scaled['toolDefs']!, greaterThan(parts['toolDefs']!),
          reason: '放大是等比放大 —— 原先占比大的仍然大');
    });

    test('没有真实值 / 空 map 时原样返回（不猜、不缩放）', () {
      final parts = <String, int>{'system': 100};
      expect(WindowRatioCompressor.scaleToRealTotal(parts, 0), parts);
      expect(WindowRatioCompressor.scaleToRealTotal(const {}, 1000), isEmpty);
    });
  });
}
