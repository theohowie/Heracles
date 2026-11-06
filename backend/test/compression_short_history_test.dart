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
// ## 病根（旧三级压缩同时静默早退；2026-11-06 已被单阈值流水线取代）
//
// 旧 `WindowRatioCompressor` 的三级都拿"**最近 keepRecentTurns(6) 轮 ≈ 24 条**"
// 当保护窗：
// · micro：只清保护窗**之外**的老工具结果 ⇒ 全部在窗内 ⇒ 无可清 ⇒ 静默返回 0；
// · auto：LLM 摘要（框架 delegate 有多个静默早退分支）；
// · full（强制重置）：`if (msgs.length <= keepMessages) return 0;`
//   ⇒ **条数少就整段放弃**。
//
// 于是「一次 read_file 把整份大文件塞进历史」这种**少量消息、巨量内容**的形状，
// 恰好落在三级的空档里：**明明已经超窗口，三个级别都不动**。
//
// 现在的流水线也有一模一样的三道门（micro 的保护窗 / 阶段 2/3 的"保护窗
// 内全部保留" / 强制重置的条数闸），所以**这个回归闸必须继续存在**：
// 它的解法是流水线最后那一层"按 token 兜底裁剪"（目标从触发线起收紧，
// 直到动不了为止）。
//
// ## 本文件锁住的契约
//
// 1. 只要估算**真的超过触发线（0.85）**，`compress()` 就必须让占用降下来 ——
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

/// 一串 ASCII 字符（4 字符 ≈ 1 token，方便算"多少 token"）。
String _ascii(int chars) => 'x' * chars;

void main() {
  // 真机上报的窗口量级（用户那条会话环图 ~100%，组件合计 ~31K）
  const window = 32768;
  final fullLine = (window * 0.85).floor(); // 27852（单阈值 0.85）

  WindowRatioCompressor buildCompressor({
    void Function(int, int, int, int)? onCompressed,
  }) =>
      WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub-model'),
        modelWindowTokens: window,
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

  // ---- ⑤ 真机 11:35 的形状：字符估算低估 5 倍，但服务端真值已过线 ----
  //
  // 用户截图：分项合计 ~20K，总量却是 **~104.0K / 128.0K（81%）**。
  // 压缩器若只看字符估算（20K），离触发线十万八千里 ⇒ 永不压缩。
  //
  // ⚠️ 2026-11-06 口径变更：用户拍板**单阈值 0.85**（不再有 0.80 的双阈值），
  //    所以这条用例把"真值"从 104K（81%）改成 **110K（85.9%）** ——
  //    行为契约不变（真值过线就得压），只是线本身从 80% 上移到了 85%。
  test('⑤ 服务端真值过 0.85 线时，即使字符估算很低也必须压', () async {
    final calls = <List<int>>[];
    final c = WindowRatioCompressor(
      client: _SilentClient(),
      modelConfig: ModelConfig(model: 'stub-model'),
      modelWindowTokens: 128000,
      onCompressed: (bm, am, bt, at) => calls.add([bm, am, bt, at]),
    );

    final state = AgentState(
      sessionId: 's-real-usage',
      history: AgentMessageHistory(messages: [
        UserMessage.text('把光调暗一点'),
        ModelMessage(
          model: 'm',
          stopReason: 'tool_calls',
          functionCalls: [
            FunctionCall(id: 'r1', name: 'read_file', arguments: '{"path":"a.html"}'),
          ],
        ),
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'r1',
              name: 'read_file',
              isError: false,
              arguments: '{"path":"a.html"}',
              content: [TextPart(_ascii(60000))], // 估算 ≈ 15K，真值远不止
            ),
          ],
        ),
        ModelMessage(model: 'm', stopReason: 'stop', textOutput: '看过页面了。'),
      ]),
    );
    // 服务端真实上报：这一轮输入 110K tokens（85.9% of 128K ⇒ 已过 0.85 线）
    state.usages.add(ModelUsage(promptTokens: 110000, completionTokens: 800));

    final est = c.estimateUsage(state);
    expect(est, lessThan(c.triggerThreshold),
        reason: '前提：字符估算**低于**触发线（这正是真机低估的形态）');

    await c.compress(state);

    expect(calls, isNotEmpty,
        reason: '★ 真机缺陷：只看字符估算 ⇒ 真值 110K/128K 也不会压，'
            '上下文一路涨到 100%+ 才崩');
  });
}
