// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **「只思考、不动手」的沉默收尾回归闸（2026-11-04）**。
//
// ## 真机现场（用户 2026-11-03 22:29 截图）
//
// 下发一条完整任务（做一个 3D 小场景页面）后，每一轮都只显示
// `分析完成` / `查看了目录` / `思考完成`，**没有任何正文、没有写文件**，
// 然后这一轮就结束了 —— 用户必须反复手打「继续」，任务永远做不完。
//
// ## 病根（框架层）
//
// `core/lib/src/agent/stateful_agent.dart`：
// · `_ModelMessageAccumulator.isEmptyResponse` 把「只有 thought」判成**真实一轮**
//   （注释写着"Thought-only … are still a real model turn"）；
// · 于是空响应重试**不会触发**（它只拦 thought 也为空的情况）；
// · 主循环看到 `functionCalls.isEmpty` ⇒ `break` ⇒ 整轮 run 正常结束。
//
// 结果：**没有正文、没有工具调用、没有错误**，UI 上什么都不显示 ——
// 用户看到的是"它想了一下就停了"，这是最坏的一种失败：不是报错，而是沉默。
//
// ## 本文件锁住的契约
//
// 1. 一轮只有思考（无正文、无工具调用）时，**绝不允许静默收尾**：
//    要么自动续跑并最终给出正文/工具调用，要么以 `HeraclesFailed` 明确收尾；
// 2. 连续多轮只有思考时，**必须**失败收尾，且理由能让人看懂
//    （不是"任务异常：unknown"这种没法排查的话）；
// 3. 正常的「正文收尾」不受影响（不许为了修这个把正常结束也变成失败）。
library;

import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 一次预设回应：正文 / 只有思考 / 工具调用。
class _Turn {
  const _Turn.text(this.text) : thought = null, toolName = null;
  const _Turn.thoughtOnly(this.thought) : text = null, toolName = null;
  const _Turn.tool(this.toolName) : text = null, thought = null;

  final String? text;
  final String? thought;
  final String? toolName;
}

/// 按脚本回应的假 client（不发任何网络请求）。
class _Client implements LLMClient {
  _Client(this.script);

  final List<_Turn> script;
  int calls = 0;

  _Turn _next() => calls <= script.length
      ? script[calls - 1]
      : const _Turn.text('（脚本已用尽）');

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async =>
      _build();

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final msg = _build();
    return Stream<StreamingMessage>.fromIterable([
      // 思考分两片吐（真机就是流式）
      if ((msg.thought ?? '').isNotEmpty)
        StreamingMessage(
          modelMessage: ModelMessage(model: 'm', thought: '${msg.thought}…'),
        ),
      StreamingMessage(modelMessage: msg),
    ]);
  }

  ModelMessage _build() {
    calls++;
    final t = _next();
    if (t.toolName != null) {
      return ModelMessage(
        model: 'm',
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(
            id: 'call-$calls',
            name: t.toolName!,
            arguments: '{}',
          ),
        ],
      );
    }
    // ★ 关键：只有 thought，没有 textOutput、没有 functionCalls
    return ModelMessage(
      model: 'm',
      stopReason: 'stop',
      thought: t.thought,
      textOutput: t.text,
    );
  }
}

class _Ws extends WorkspaceCapability {
  @override
  Future<CapabilityResult> list(String path, {bool recursive = false, int maxEntries = 200}) async =>
      const CapabilitySuccess('a.txt');
  @override
  Future<CapabilityResult> read(String path, {int offset = 1, int limit = 0}) async =>
      const CapabilitySuccess('内容');
  @override
  Future<CapabilityResult> write(String path, String content) async =>
      const CapabilitySuccess('已写入');
  @override
  Future<CapabilityResult> edit(String path, String oldText, String newText) async =>
      const CapabilitySuccess('已替换');
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilityFailure('未覆盖');
  @override
  Future<CapabilityResult> mkdir(String path) async => const CapabilitySuccess('已创建');
  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async =>
      const CapabilitySuccess('已删除');
  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<CapabilityResult> findFiles(String pattern, {int maxResults = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> grepFiles(String pattern, {String pathFilter = '', int maxResults = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> move(String from, String to) async => const CapabilitySuccess('已移动');
  @override
  Future<CapabilityResult> copy(String from, String to) async => const CapabilitySuccess('已复制');
}

HeraclesAgent _agent(LLMClient client) => HeraclesAgent(
      config: const BackendConfig(
        apiKey: 'test-not-used',
        modelName: 'test-model',
        baseUrl: 'http://127.0.0.1:1',
      ),
      capabilities: Capabilities(workspace: _Ws()),
      options: const RunOptions(maxTurns: 8, maxToolCalls: 20),
      client: client,
    );

Future<List<HeraclesEvent>> _collect(Stream<HeraclesEvent> s) => s
    .timeout(const Duration(seconds: 10))
    .toList();

void main() {
  test('① 只有思考的一轮不许静默收尾（必须续跑出正文或明确失败）', () async {
    // 第 1 轮只有思考；第 2 轮给正文（模拟"被续跑推着干完了"）
    final client = _Client([
      const _Turn.thoughtOnly('我先分析一下这个任务…'),
      const _Turn.text('已经完成：写入了 index.html'),
    ]);

    final events = await _collect(_agent(client).run('做个页面'));
    final finished = events.whereType<HeraclesFinished>();
    final failed = events.whereType<HeraclesFailed>();

    expect(finished.length + failed.length, 1, reason: '必须有且只有一个终态事件');
    if (finished.isNotEmpty) {
      expect(
        finished.single.finalText.trim(),
        isNotEmpty,
        reason: '★ 静默收尾：用户只看到"思考完成"，没有任何输出 —— 这就是真机现场',
      );
      expect(client.calls, greaterThanOrEqualTo(2),
          reason: '只有思考的那一轮必须被推着继续跑，而不是直接结束');
    } else {
      expect(failed.single.reason.trim(), isNotEmpty, reason: '失败也要给人话');
    }
  });

  test('② 连续多轮只有思考 ⇒ 明确失败，理由看得懂', () async {
    final client = _Client([
      const _Turn.thoughtOnly('想'),
      const _Turn.thoughtOnly('再想'),
      const _Turn.thoughtOnly('还想'),
      const _Turn.thoughtOnly('一直想'),
    ]);

    final events = await _collect(_agent(client).run('做个页面'));
    final failed = events.whereType<HeraclesFailed>();

    expect(failed, isNotEmpty,
        reason: '★ 模型一直只思考不动手时，必须以可见的失败收尾，不许沉默停下');
    final reason = failed.single.reason;
    expect(
      reason,
      anyOf(contains('思考'), contains('正文'), contains('工具调用')),
      reason: '理由必须说清"模型只输出思考、没有动手"，而不是含糊的未知错误；实际=$reason',
    );
  });

  test('③ 正常正文收尾不受影响（不许把正常结束改成失败）', () async {
    final client = _Client([const _Turn.text('好了，已经完成。')]);

    final events = await _collect(_agent(client).run('随便聊聊'));
    expect(events.whereType<HeraclesFailed>(), isEmpty);
    expect(events.whereType<HeraclesFinished>().single.finalText, contains('已经完成'));
    expect(client.calls, 1, reason: '正常一轮就结束，不该被无故续跑');
  });

  test('④ 工具调用轮不受影响（工具往返照旧）', () async {
    final client = _Client([
      const _Turn.tool('list_files'),
      const _Turn.text('目录里有 a.txt'),
    ]);

    final events = await _collect(_agent(client).run('看看目录'));
    expect(events.whereType<HeraclesFailed>(), isEmpty);
    expect(events.whereType<HeraclesFinished>().single.finalText, contains('a.txt'));
  });
}
