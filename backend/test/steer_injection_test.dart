// Copyright (C) 2026 The Heracles Authors
//
// **P0 插队发送（2026-10-30）：`RunOptions.takeSteerMessage` + `_SteerHook`**。
//
// 语义（不许混淆"停止"）：
// · 用户在一轮跑着时插一句 ⇒ **不打断在途流/工具**；
// · 只在**当前轮完整结束之后**、下一轮开始之前，把这句话作为一条
//   `UserMessage` 注入历史；模型下一轮自己看到；
// · 每次轮结束只取一条；空/空白 = 无插话（正常收尾）；
// · 没传回调 = 不装 hook，行为与加字段之前完全一致。
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  HeraclesAgent agentWith(
    LLMClient c, {
    String? Function()? takeSteer,
  }) =>
      HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: _FakeWs()),
        client: c,
        options: RunOptions(
          maxTurns: 10,
          maxToolCalls: 20,
          takeSteerMessage: takeSteer,
        ),
      );

  Future<List<HeraclesEvent>> runAll(HeraclesAgent agent) async {
    final events = <HeraclesEvent>[];
    await for (final e in agent.run('原任务')) {
      events.add(e);
    }
    return events;
  }

  /// 从一次 model 调用的 messages 里取所有**用户正文**（按顺序）。
  List<String> userTexts(List<LLMMessage> messages) => [
        for (final m in messages)
          if (m is UserMessage) m.contents.whereType<TextPart>().map((p) => p.text).join(),
      ];

  test('★★★ 插话在**下一轮**可见，且排在工具结果之后（不打断本轮）', () async {
    final c = _ToolThenAnswerClient();
    final events = await runAll(agentWith(
      c,
      // 模拟"用户在第一轮跑着时补了一句"：第一次取件返回它，之后为空。
      takeSteer: () => c.steerTaken ? null : (c.steerTaken = true, '改用 B 方案').$2,
    ));

    expect(c.messages, hasLength(3),
        reason: '★ 插话 = 多跑一轮（不是取消）：初始 → 工具轮 → 注入后新轮');
    final last = c.messages.last;
    // 注入顺序：第一轮的工具结果 → 用户插话（都在最后这次请求的历史里）
    final iResult = last.indexWhere((m) => m is FunctionExecutionResultMessage);
    final iSteer = last.indexWhere(
        (m) => m is UserMessage && userTexts([m]).join().contains('改用 B 方案'));
    expect(iResult, greaterThanOrEqualTo(0), reason: '第一轮工具结果必须已在历史里');
    expect(iSteer, greaterThan(iResult),
        reason: '★ 插话发生在轮完整结束之后（工具结果之后），不是打断在途轮');
    expect(events.whereType<HeraclesFinished>(), hasLength(1));
  });

  test('★★★ 连续两条插话：按顺序注入（一轮一条）', () async {
    final c = _ToolThenAnswerClient();
    final pending = <String>['先用 A', '再用 B'];
    final events = await runAll(agentWith(
      c,
      takeSteer: () => pending.isEmpty ? null : pending.removeAt(0),
    ));

    // turn1(tool) → 注入"先用 A" → turn2(answer) → 注入"再用 B" → turn3
    expect(c.messages, hasLength(4));
    final last = c.messages.last;
    final texts = userTexts(last);
    final a = texts.indexWhere((t) => t.contains('先用 A'));
    final b = texts.indexWhere((t) => t.contains('再用 B'));
    expect(a, greaterThanOrEqualTo(0));
    expect(b, greaterThan(a), reason: '★ 两条插话按用户发送顺序进入历史');
    expect(pending, isEmpty, reason: '每条插话恰好被消费一次');
    expect(events.whereType<HeraclesFinished>(), hasLength(1));
  });

  test('★★ 空串 / 纯空白插话 ⇒ 不注入、正常一轮结束', () async {
    final c = _ToolThenAnswerClient();
    final events = await runAll(agentWith(c, takeSteer: () => '   '));
    expect(c.messages, hasLength(2), reason: '第一轮工具 + 一次回答；空白不产生额外轮');
    expect(events.whereType<HeraclesFinished>(), hasLength(1),
        reason: '空白插话不阻止正常收尾');
    // 历史里没有任何空白用户消息（空白被 trim 后按"无插话"处理）
    for (final m in c.messages) {
      for (final t in userTexts(m)) {
        expect(t.trim(), isNotEmpty);
      }
    }
  });

  test('★★ 不传回调（null）⇒ 不装 hook，行为与以前完全一致', () async {
    final c = _ToolThenAnswerClient();
    final events = await runAll(agentWith(c)); // takeSteer: null
    expect(c.messages, hasLength(2));
    expect(events.whereType<HeraclesFinished>(), hasLength(1));
  });

  test('★★ 每次轮结束只取一条：回调第二次返回 null ⇒ 只注入一次', () async {
    final c = _ToolThenAnswerClient();
    var calls = 0;
    final events = await runAll(agentWith(
      c,
      takeSteer: () {
        calls++;
        return calls == 1 ? '只插一次' : null;
      },
    ));
    expect(c.messages, hasLength(3), reason: '一次注入 = 只多跑一轮');
    expect(events.whereType<HeraclesFinished>(), hasLength(1));
    var injected = 0;
    for (final m in c.messages) {
      for (final t in userTexts(m)) {
        if (t.contains('只插一次')) injected++;
      }
    }
    expect(injected, 1, reason: '★ 同一句不许重复注入');
  });
}

// ============================================================================
// 测试替身
// ============================================================================

class _FakeWs implements WorkspaceCapability {
  final files = <String, String>{};

  @override
  Future<CapabilityResult> write(String path, String content) async {
    files[path] = content;
    return CapabilitySuccess('已写入 $path');
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<CapabilityResult> read(String path,
          {int offset = 1, int limit = 0}) async =>
      CapabilitySuccess(files[path] ?? '');

  @override
  Future<CapabilityResult> edit(
          String path, String oldText, String newText) async =>
      const CapabilitySuccess('已替换');
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilitySuccess('已应用');
  @override
  Future<CapabilityResult> delete(String path,
          {bool recursive = false}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> list(String path,
          {bool recursive = false, int maxEntries = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> mkdir(String path) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> findFiles(String pattern,
          {int maxResults = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> grepFiles(String pattern,
          {String pathFilter = '', int maxResults = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> move(String from, String to) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> copy(String from, String to) async =>
      const CapabilitySuccess('');
}

/// 第 1 轮调 `write_file`（制造"轮完整结束"），之后给最终回答。
///
/// 真实 UI 里插话发生在这一轮**跑着的时候**；测试用"取件闭包"在同一时点
/// 交出文本（确定性，不依赖线程时序）。
class _ToolThenAnswerClient implements LLMClient {
  final messages = <List<LLMMessage>>[];
  bool steerTaken = false;
  int _calls = 0;

  ModelMessage _r(ModelConfig mc) {
    final i = _calls++;
    if (i == 0) {
      return ModelMessage(
        model: mc.model,
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(
            id: 'c1',
            name: 'write_file',
            arguments: '{"path":"a.txt","content":"x"}',
          ),
        ],
      );
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return _r(modelConfig);
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return Stream<StreamingMessage>.fromIterable(
        [StreamingMessage(modelMessage: _r(modelConfig))]);
  }
}
