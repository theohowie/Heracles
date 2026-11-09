// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **流水线门禁**（2026-11-06）：零副作用、重入防护、事件记账、命令层接口。
//
// ## 本文件锁住的契约
//
// | # | 契约 | 抓的缺陷 |
// |---|---|---|
// | ① | 占用 < 0.85×窗口 ⇒ **完全无副作用**（历史条数/字节不变、零 API、无事件） | 每轮小修小补 ⇒ 前缀缓存全废（真机命中率只有 40%~48%） |
// | ② | 重入（并发/递归调用）⇒ 第二次直接返回，绝不并发改历史 | 两份压缩同时改 `messages` ⇒ 丢消息、配对被打散 |
// | ③ | 事件记账自洽（before/after、kept/dropped、layers、usedApi） | "压了 40 条 → 40 条"这种假事件；或钱花了却不记账 |
// | ④ | 命令层接口：`compactNow({focus})` 不看阈值；`sendViewTruncatedTo` 不改历史 | UI/CLI 没法手动压、没法回退 |
// | ⑤ | 兜底裁剪**不许吃掉刚生成的摘要快照** | 压完两次，快照被第二次裁掉 ⇒ 模型什么都没得到 |
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 记录调用次数、返回空摘要的 client（"摘要永远失败"的极端情况）。
class _Recorder implements LLMClient {
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

/// 一条"写过文件"的轮次。
List<LLMMessage> _writeTurn(String path) => <LLMMessage>[
      ModelMessage(
        model: 'm',
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(id: 'call-$path', name: 'write_file', arguments: '{"path":"$path"}'),
        ],
      ),
      FunctionExecutionResultMessage(results: [
        FunctionExecutionResult(
          id: 'call-$path',
          name: 'write_file',
          isError: false,
          arguments: '{"path":"$path"}',
          content: <UserContentPart>[TextPart('ok')],
        ),
      ]),
    ];

/// 造历史：首条任务 + 一次写文件 + [filler] 条长填充。
List<LLMMessage> _history({int filler = 40, int fillerChars = 210}) => <LLMMessage>[
      UserMessage.text('把首页改成暗色主题，不要动 app.html'),
      ..._writeTurn('index.html'),
      for (var i = 0; i < filler; i++)
        UserMessage.text('继续第 $i 步：调整配色与间距。${'字' * fillerChars}'),
    ];

List<String> _userTexts(AgentState state) => <String>[
      for (final m in state.history.messages)
        if (m is UserMessage)
          m.contents.whereType<TextPart>().map((p) => p.text).join(),
    ];

void main() {
  group('① 低于触发线 ⇒ 完全无副作用', () {
    test('★★★ 条数/逐条 token 不变、零 API、无事件、记忆都没构建', () async {
      final client = _Recorder();
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 100000, // 触发线 85000，本历史约 8.8K ⇒ 远低于
      );
      final state = AgentState(
        sessionId: 's-low',
        history: AgentMessageHistory(messages: _history()),
      );
      final beforeUsage = c.estimateUsage(state);
      final beforeMessages = List<LLMMessage>.of(state.history.messages);
      final beforePerMessage = beforeMessages
          .map(WindowRatioCompressor.estimateMessageTokens)
          .toList();
      expect(beforeUsage, lessThan(c.triggerThreshold), reason: '前提：没到线');

      await c.compress(state);

      expect(client.calls, 0, reason: '★ 零 API');
      expect(c.lastCompaction, isNull, reason: '没压缩就不该有事件（usedApi=false）');
      expect(c.events, isEmpty);
      expect(c.lastSessionMemory, isNull,
          reason: '★ 连记忆都不该构建 —— 零副作用是做到底，不是"少做一点"');
      expect(state.history.messages.length, beforeMessages.length);
      expect(
        state.history.messages.map(WindowRatioCompressor.estimateMessageTokens).toList(),
        beforePerMessage,
        reason: '★★ 逐条 token 必须一模一样（任何改写都会让缓存前缀失效）',
      );
      for (var i = 0; i < beforeMessages.length; i++) {
        expect(state.history.messages[i], same(beforeMessages[i]),
            reason: '第 $i 条被换成了新对象 —— 未到线不许动历史');
      }
    });

    test('★★ 渐进开关（默认关）打开后才允许低阈值只跑 micro', () async {
      final state = AgentState(
        sessionId: 's-progressive',
        history: AgentMessageHistory(messages: <LLMMessage>[
          UserMessage.text('读文件'),
          for (var i = 0; i < 12; i++)
            FunctionExecutionResultMessage(results: [
              FunctionExecutionResult(
                id: 'read-$i',
                name: 'read_file',
                isError: false,
                arguments: '{}',
                content: <UserContentPart>[TextPart('内' * 400)],
              ),
            ]),
          for (var i = 0; i < 30; i++) UserMessage.text('字' * 40),
        ]),
      );

      // 默认（关）：什么都不做
      final off = WindowRatioCompressor(
        client: _Recorder(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 100000,
      );
      final offState = AgentState(
        sessionId: state.sessionId,
        history: AgentMessageHistory(messages: List<LLMMessage>.of(state.history.messages)),
      );
      await off.compress(offState);
      expect(off.lastCompaction, isNull);
      expect(
        offState.history.messages
            .whereType<FunctionExecutionResultMessage>()
            .every((m) => m.results.every((r) =>
                (r.content.first as TextPart).text !=
                ContractCompaction.clearedToolResultPlaceholder)),
        isTrue,
      );

      // 打开：低阈值也跑 micro（⚠️ 会砸缓存，契约里写明"默认关"的理由）
      final on = WindowRatioCompressor(
        client: _Recorder(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 100000,
        compactionConfig: const CompactionConfig(progressiveLayersEnabled: true),
      );
      await on.compress(state);
      expect(on.lastCompaction?.trigger, CompactionTrigger.progressive);
      expect(on.lastCompaction?.usedApi, isFalse);
      expect(
        state.history.messages
            .whereType<FunctionExecutionResultMessage>()
            .any((m) => m.results.any((r) =>
                (r.content.first as TextPart).text ==
                ContractCompaction.clearedToolResultPlaceholder)),
        isTrue,
        reason: '渐进模式只做 micro（清老工具输出）',
      );
    });
  });

  group('② 重入防护', () {
    test('★★★ 并发两次 compress ⇒ 只跑一次，历史不被重复改写', () async {
      final client = _Recorder();
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );
      final state = AgentState(
        sessionId: 's-reentry',
        history: AgentMessageHistory(messages: _history()),
      );

      await Future.wait(<Future<void>>[
        c.compress(state),
        c.compress(state),
      ]);

      final notes = _userTexts(state)
          .where((t) => t.startsWith('[上下文压缩快照]'))
          .toList();
      expect(notes, hasLength(1),
          reason: '★★ 重入必须无效果（否则会插两条快照、把历史切乱）');
      expect(c.events, hasLength(1), reason: '只该有一次事件的记账');
    });
  });

  group('③ 事件记账自洽', () {
    test('★★★ 事件字段与历史变化对得上（记账不许自相矛盾）', () async {
      final c = WindowRatioCompressor(
        client: _Recorder(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );
      final history = _history();
      final state = AgentState(
        sessionId: 's-event',
        history: AgentMessageHistory(messages: List<LLMMessage>.of(history)),
      );

      await c.compress(state);

      final event = c.lastCompaction!;
      expect(event.trigger, CompactionTrigger.threshold);
      expect(event.beforeTokens, greaterThanOrEqualTo(c.triggerThreshold));
      expect(event.afterTokens, lessThan(event.beforeTokens));
      expect(event.savedTokens, greaterThan(0));
      expect(event.layersRun, isNotEmpty);
      expect(event.usedApi, isFalse, reason: '这条路是本地记忆，不该花 API 钱');
      expect(event.keptNotes + event.droppedNotes,
          greaterThanOrEqualTo(event.keptNotes));
      expect(event.keptNotes, greaterThan(0), reason: '保护窗内的原文要留着');
      expect(event.droppedNotes,
          history.length - event.keptNotes,
          reason: '★ 丢弃条数必须等于"原条数 - 保留条数"（不许瞎报）');
      expect(event.elapsedMs, greaterThanOrEqualTo(0));
      // toJson 能序列化（UI/日志要用）
      final json = event.toJson();
      expect(json['layers'], isA<List<Object?>>());
      expect(json['trigger'], 'threshold');
      // 留档
      expect(c.events.single, same(event));
    });

    test('★★ metricsEnabled=false ⇒ 不留档但压缩照做', () async {
      final c = WindowRatioCompressor(
        client: _Recorder(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
        compactionConfig: const CompactionConfig(metricsEnabled: false),
      );
      final state = AgentState(
        sessionId: 's-nometrics',
        history: AgentMessageHistory(messages: _history()),
      );

      await c.compress(state);

      expect(c.lastCompaction, isNotNull, reason: '事件本身还是要返回（命令层要看）');
      expect(c.events, isEmpty, reason: '关掉留档 ⇒ 不占内存');
      expect(c.estimateUsage(state), lessThan(c.triggerThreshold),
          reason: '★ 关掉 metrics 不许影响压缩行为');
    });
  });

  group('④ 命令层接口', () {
    test('★★★ compactNow 不看阈值：低占用也能手动压', () async {
      final c = WindowRatioCompressor(
        client: _Recorder(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 100000, // 触发线 85000 ⇒ 正常永远不会触发
      );
      final state = AgentState(
        sessionId: 's-manual',
        history: AgentMessageHistory(messages: _history()),
      );
      final before = c.estimateUsage(state);
      expect(before, lessThan(c.triggerThreshold), reason: '前提：自动路径不会压');

      final event = await c.compactNow(state);

      expect(event.trigger, CompactionTrigger.manual);
      expect(event.layersRun, isNotEmpty, reason: '★ 用户要求压就得压');
      expect(c.estimateUsage(state), lessThan(before));
    });

    test('★★ sendViewTruncatedTo / buildSendView：只改视图不改历史', () {
      final c = WindowRatioCompressor(
        client: _Recorder(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );
      final state = AgentState(
        sessionId: 's-view',
        history: AgentMessageHistory(messages: _history()),
      );
      final before = state.history.messages.length;

      final full = c.buildSendView(state);
      final truncated = c.sendViewTruncatedTo(state, 2);

      expect(full.messages.length, before);
      expect(full.estTokens, greaterThan(0));
      expect(truncated.messages.length, lessThan(full.messages.length));
      expect(truncated.estTokens, lessThan(full.estTokens));
      expect(state.history.messages.length, before,
          reason: '★★ /rewind 只截发送视图，原始历史一个字都不动');
    });

    test('★★ HeraclesAgent 暴露同名接口（命令层直接用）', () async {
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: const Capabilities(),
        client: _Recorder(),
      );
      // 还没跑过 ⇒ 有状态但历史为空：不许抛
      final event = await agent.compactNow();
      expect(event.trigger, CompactionTrigger.manual);
      expect(event.layersRun, isEmpty);
      expect(event.failureReason, isNotNull,
          reason: '没东西可压要如实说原因（不许假装压过）');
      expect(agent.sendViewTruncatedTo(1).messages, isEmpty);
      expect(agent.buildSendView().messages, isEmpty);
    });
  });

  group('⑤ 兜底裁剪不许吃掉刚生成的摘要快照', () {
    test('★★★ 记忆视图落地后仍超线 ⇒ 兜底保留快照、说明排在它后面', () async {
      final c = WindowRatioCompressor(
        client: _Recorder(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );
      // 保护窗内原文本身很大（24 条 × 518 token ≈ 12.4K），所以"记忆视图"
      // 落地后依然超线 ⇒ 会走到兜底裁剪。快照必须活下来。
      final state = AgentState(
        sessionId: 's-note-keep',
        history: AgentMessageHistory(
          messages: _history(filler: 40, fillerChars: 500),
        ),
      );

      await c.compress(state);

      final texts = _userTexts(state);
      final snapshotIndex =
          texts.indexWhere((t) => t.startsWith('[上下文压缩快照]'));
      expect(snapshotIndex, 0,
          reason: '★★ 摘要快照必须还在，而且是第一条');
      final maintenanceIndex =
          texts.indexWhere((t) => t.startsWith('[系统维护]'), 1);
      expect(maintenanceIndex, greaterThan(0),
          reason: '兜底的如实说明要排在快照之后（不许顶掉快照）');
      expect(c.lastCompaction!.layersRun,
          containsAll(<CompactionLayer>[
            CompactionLayer.sessionMemory,
            CompactionLayer.forceReset,
          ]));
      expect(c.estimateUsage(state), lessThan(c.triggerThreshold),
          reason: '走了兜底就必须真的压到线下');
    });
  });
  test('knownPromptTokens: 新一轮 usages 为空时也要能触发压缩', () async {
    // 真机 2026-11-06：上下文 122%、压缩从不触发 —— 新一轮开始时
    // `state.usages` 为空，决策退回字符估算（低估 2.5~3.5 倍）。
    // 宿主把上次真实 prompt tokens 带进来，这里验证它真的参与决策。
    final client = _Recorder();
    final c = WindowRatioCompressor(
      client: client,
      modelConfig: ModelConfig(model: 'stub'),
      modelWindowTokens: 1000,
      compactionConfig: const CompactionConfig(
        autoCompactThreshold: 0.85,
        sessionMemoryEnabled: false,
        knownPromptTokens: 900, // 90% —— 已过线，但字符估算远低于线
      ),
    );
    final state = AgentState(
      sessionId: 's-known',
      history: AgentMessageHistory(messages: [UserMessage.text('hi')]),
    );

    expect(c.estimateUsage(state), lessThan(850),
        reason: '前提：字符估算本身远低于触发线（否则用例没意义）');

    await c.compress(state);

    expect(c.lastCompaction, isNotNull,
        reason: '★ 只有 knownPromptTokens 参与决策，这次压缩才可能发生');
  });
}
