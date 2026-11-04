// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **"消息条数少、单条内容巨大"时压缩静默失效** 的回归闸（2026-11-04）。
//
// ## 真机现场（用户 2026-11-04 10:19 截图）
//
// 顶栏环图显示「上下文 102%」（红），用量抽屉也是 100% 已用，但**从来没有出现
// 压缩事件**，任务继续往窗口里塞东西。用户判断「上下文压缩机制是坏的」——
// 方向对了。
//
// ## 病根（三级压缩同时静默早退）
//
// `WindowRatioCompressor` 的三级都拿"**最近 keepRecentTurns(6) 轮 ≈ 24 条**"
// 当保护窗：
// · micro：只清保护窗**之外**的老工具结果 ⇒ 全部在窗内 ⇒ 无可清 ⇒ 静默返回 0；
// · auto：LLM 摘要（框架 delegate 有多个静默早退分支）；
// · full（强制重置）：`if (msgs.length <= keepMessages) return 0;`
//   ⇒ **条数少就整段放弃**。
//
// 于是「一次 read_file 把整份大文件塞进历史」这种**少量消息、巨量内容**的形状，
// 恰好落在三级的空档里：**明明已经超窗口，三个级别都不动**。
//
// ## 本文件锁住的契约
//
// 1. 只要估算**真的超过强制线**，`compress()` 就必须让占用降下来 ——
//    不许因为"消息条数不够多"而整段放弃；
// 2. 降下来之后仍要**如实说明**（插一条系统维护消息，讲清哪些内容被清）；
// 3. 不许把**最近一条**消息删掉（模型需要看到当前这轮发生了什么）。
library;

import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 记录调用、什么都不做的 client（这些用例不该发网络请求）。
class _SilentClient implements LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async =>
      ModelMessage(model: 'stub', stopReason: 'stop', textOutput: '');

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

/// 一个"什么都没做"的 delegate —— 模拟框架摘要在真机上静默早退。
class _NoOpDelegate implements ContextCompressor {
  @override
  Future<void> compress(AgentState state) async {}
}

String _ascii(int chars) => 'x' * chars;

void main() {
  // 真机上报的窗口量级（用户那条会话环图 ~100%，组件合计 ~31K）
  const window = 32768;
  final fullLine = (window * 0.80).floor(); // 26214

  WindowRatioCompressor buildCompressor({
    void Function(int, int, int, int)? onCompressed,
  }) =>
      WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub-model'),
        modelWindowTokens: window,
        delegateImpl: _NoOpDelegate(),
        onCompressed: onCompressed,
      );

  /// **真机的形状**：消息很少（远少于 24 条保护窗），但一条工具结果极大。
  AgentState fatShortHistory() => AgentState(
        sessionId: 's-fat',
        history: AgentMessageHistory(messages: [
          UserMessage.text('做一个雨夜便利店街角 3D 场景的 HTML'),
          ModelMessage(
            model: 'm',
            stopReason: 'tool_calls',
            functionCalls: [
              FunctionCall(
                id: 'c1',
                name: 'read_file',
                arguments: '{"path":"a.html"}',
              ),
            ],
          ),
          FunctionExecutionResultMessage(
            results: [
              FunctionExecutionResult(
                id: 'c1',
                name: 'read_file',
                isError: false,
                arguments: '{"path":"a.html"}',
                content: [TextPart(_ascii(200000))], // 约 50K tokens
              ),
            ],
          ),
          ModelMessage(model: 'm', stopReason: 'stop', textOutput: '已读取。'),
        ]),
      );

  test('① 少量消息 + 巨量工具结果 ⇒ 超强制线时必须真的压下来', () async {
    final c = buildCompressor();
    final state = fatShortHistory();

    final before = c.estimateUsage(state);
    expect(before, greaterThan(fullLine),
        reason: '前提：这条历史的估算必须真的超过强制线（否则用例没意义）');

    await c.compress(state);

    final after = c.estimateUsage(state);
    expect(after, lessThan(fullLine),
        reason: '★ 真机缺陷：条数只有 4 条（< 24 条保护窗），三级压缩全部静默早退，'
            '上下文 102% 却一处都没动');
  });

  test('② 压缩发生后要如实播报（不许静默处理掉用户的内容）', () async {
    final calls = <List<int>>[];
    final c = buildCompressor(
      onCompressed: (bm, am, bt, at) => calls.add([bm, am, bt, at]),
    );
    final state = fatShortHistory();

    await c.compress(state);

    expect(calls, isNotEmpty, reason: '真的动了历史就必须播 context_compressed');
    expect(calls.first[2], greaterThan(calls.first[3]),
        reason: '播报里的 before > after（token 真的降了）');
  });

  test('③ 最近一条消息不许被删（模型要知道这一轮发生了什么）', () async {
    final c = buildCompressor();
    final state = fatShortHistory();
    final lastBefore = state.history.messages.last;

    await c.compress(state);

    expect(state.history.messages, isNotEmpty);
    expect(
      state.history.messages.last,
      same(lastBefore),
      reason: '★ 压缩可以清老内容，但不能把"当前这轮"也从模型眼前抹掉',
    );
  });

  test('④ 装得下时不许乱动（小于 micro 线就全装）', () async {
    final c = buildCompressor();
    final state = AgentState(
      sessionId: 's-small',
      history: AgentMessageHistory(messages: [
        UserMessage.text('你好'),
        ModelMessage(model: 'm', stopReason: 'stop', textOutput: '你好，需要我做什么？'),
      ]),
    );
    final before = state.history.messages.length;

    await c.compress(state);

    expect(state.history.messages.length, before);
  });
}
