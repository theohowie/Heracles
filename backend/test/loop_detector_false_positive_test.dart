// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **"循环检测误杀正常任务"的回归闸（2026-11-04）**。
//
// ## 真机事故（用户 2026-11-04 10:14 截图）
//
// 任务是"做一个雨夜便利店街角 3D 场景 HTML"。模型在**同一个文件上反复增量编辑**
// —— 这在单轮输出上限 16384 tokens 下是**正常形态**（整页装不进一次输出）——
// 却被判成循环并中止：会话里出现
// 「检测到循环：模型反复请求相同的操作。任务已停止，避免反复修改同一文件。」
//
// ## 病根
//
// 框架 `DefaultLoopDetector` 有两条路：
//   ① "`工具名:参数JSON` 字节完全相同 ×N"（阈值默认 5）；
//   ② **LLM 自我诊断**：跑到 30 轮后每 10 轮用**同一个模型**问"它是不是在打转"，
//      置信度 > 0.8 就中止。真机是死在 ② 上 —— 判官看到"编辑同一文件 N 次"
//      就认为停滞，而模型其实一直在推进。
//
// ## 修法（装配层，不改框架语义）
//
// 关掉 ②（`client/modelConfig` 传 null），① 的阈值 5→6。见 `ContractLoop`。
//
// ## 本文件锁住的契约
//
// 1. **长任务的"同一文件反复编辑"不许被判成循环**（哪怕判官会喊 loop）；
// 2. **真正的死循环仍然要被逮住**（参数完全相同的重复调用 ×6）；
// 3. 判官**根本不该被调用**（省一次模型请求，也避免它误判）。
library;

import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 假 client：
/// · 带 tools 的调用 = 主循环，按脚本回；
/// · **不带 tools 的调用 = 框架的"自我诊断"判官**，一律回"是循环、置信度 0.95"
///   （这样只要判官被调用，任务就会被杀 —— 正好用来证明它没被调用）。
class _JudgeTrapClient implements LLMClient {
  _JudgeTrapClient(this.script);

  final List<ModelMessage> script;
  int mainCalls = 0;
  int judgeCalls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    if (tools == null || tools.isEmpty) {
      judgeCalls++;
      return ModelMessage(
        model: 'm',
        stopReason: 'stop',
        textOutput: '{"is_loop": true, "reason": "反复修改同一文件", "confidence": 0.95}',
      );
    }
    return _turn();
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final msg = await generate(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
      cancelToken: cancelToken,
    );
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(modelMessage: msg),
    ]);
  }

  ModelMessage _turn() {
    final i = mainCalls++;
    if (i >= script.length) {
      return ModelMessage(
        model: 'm',
        stopReason: 'stop',
        textOutput: '页面已经写完，收工。',
      );
    }
    return script[i];
  }
}

class _Ws extends WorkspaceCapability {
  _Ws() : files = {'index.html': '占位内容'};
  final Map<String, String> files;

  @override
  Future<CapabilityResult> list(String path, {bool recursive = false, int maxEntries = 200}) async =>
      CapabilitySuccess(files.keys.join('\n'));
  @override
  Future<CapabilityResult> read(String path, {int offset = 1, int limit = 0}) async =>
      CapabilitySuccess(files[path] ?? '');
  @override
  Future<CapabilityResult> write(String path, String content) async {
    files[path] = content;
    return CapabilitySuccess('已写入 $path（${content.length} 字符）');
  }
  @override
  Future<CapabilityResult> edit(String path, String oldText, String newText) async {
    final v = files[path];
    if (v == null) return const CapabilityFailure('文件不存在');
    files[path] = v + newText;
    return const CapabilitySuccess('已替换 1 处');
  }
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilityFailure('未覆盖');
  @override
  Future<CapabilityResult> mkdir(String path) async => const CapabilitySuccess('已创建');
  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async =>
      const CapabilitySuccess('已删除');
  @override
  Future<bool> exists(String path) async => files.containsKey(path);
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

ModelMessage _edit(String path, String from, String to, {String? id}) => ModelMessage(
      model: 'm',
      stopReason: 'tool_calls',
      functionCalls: [
        FunctionCall(
          id: id ?? 'c-${from.hashCode}-${to.hashCode}',
          name: 'edit',
          arguments: '{"path":"$path","old_text":"$from","new_text":"$to"}',
        ),
      ],
    );

HeraclesAgent _agent(LLMClient client) => HeraclesAgent(
      config: const BackendConfig(
        apiKey: 'test-not-used',
        modelName: 'test-model',
        baseUrl: 'http://127.0.0.1:1',
      ),
      capabilities: Capabilities(workspace: _Ws()),
      // 轮次/工具预算放宽，确认"不是因为预算才停" —— 要让循环检测自己说话
      options: const RunOptions(maxTurns: 80, maxToolCalls: 200),
      client: client,
    );

Future<List<HeraclesEvent>> _collect(Stream<HeraclesEvent> s) =>
    s.timeout(const Duration(seconds: 20)).toList();

void main() {
  test('① 同一文件反复增量编辑（内容都不同）⇒ 不许判成循环，也要收尾', () async {
    // 第 1 轮先读（"先读再改"门禁要求），后面 33 轮都在同一文件上做**不同**的编辑
    final script = <ModelMessage>[
      ModelMessage(
        model: 'm',
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(
            id: 'read-1',
            name: 'read_file',
            arguments: '{"path":"index.html"}',
          ),
        ],
      ),
      for (var i = 0; i < 33; i++)
        _edit('index.html', 'PLACEHOLDER_$i', 'SECTION_$i'),
    ];
    final client = _JudgeTrapClient(script);

    final events = await _collect(_agent(client).run('做一个雨夜便利店街角 3D 场景'));
    final failed = events.whereType<HeraclesFailed>();

    expect(
      failed.where((f) => f.reason.contains('循环')),
      isEmpty,
      reason: '★ 这就是真机误杀：同一文件的连续增量编辑是正常推进，不是循环',
    );
    expect(events.whereType<HeraclesFinished>(), isNotEmpty,
        reason: '必须正常收尾（图三那样把活干完）');
    expect(client.judgeCalls, 0,
        reason: '★ 自我诊断分支必须关掉：判官一律回 loop/0.95，只要被调用就会误杀');
  });

  test('② 真正的死循环（参数逐字相同的调用 ×6）仍然要被逮住', () async {
    // 每次都是**完全相同**的参数 —— 这才是"同一操作反复失败还在重试"。
    // ⚠️ id 必须各不相同：探测器按 id 识别"流式更新的同一个调用"，
    //    同一个 id 会被当成一次调用的增量，永远攒不到阈值（这也是它正确的行为）。
    final client = _JudgeTrapClient([
      for (var i = 0; i < 10; i++)
        _edit('index.html', 'SAME_OLD', 'SAME_NEW', id: 'same-$i'),
    ]);

    final events = await _collect(_agent(client).run('死循环测试'));
    final failed = events.whereType<HeraclesFailed>();

    expect(failed, isNotEmpty, reason: '一模一样地重复 6 次，必须中止');
    expect(failed.single.reason, contains('循环'));
  });

  test('③ 判官不该被调用 ⇒ 省一次模型请求', () async {
    final client = _JudgeTrapClient([
      for (var i = 0; i < 35; i++) _edit('index.html', 'A$i', 'B$i'),
    ]);
    await _collect(_agent(client).run('长任务'));
    expect(client.judgeCalls, 0);
  });
}
