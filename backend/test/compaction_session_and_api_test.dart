// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **阶段 2（Session Memory，零 API）与阶段 3（API 结构化摘要）的回归闸**（2026-11-06）。
//
// ## 本文件锁住的契约
//
// | # | 契约 | 抓的缺陷 |
// |---|---|---|
// | ① | 记忆可用 ⇒ **零 API**，摘要视图里必须有 goal / constraints / files | "明明能白嫖还去调模型" = 每次压缩都花钱 + 慢 |
// | ② | 记忆 stale/关闭 ⇒ 走 API 摘要 | 把过时记忆喂给模型（照着旧计划干活） |
// | ③ | 摘要失败 ⇒ **原历史一条不差** + `failureReason` 非空 | "失败也插一条快照" = 假信息、真丢内容 |
// | ④ | 记忆更新失败/超时 ⇒ 保留旧记忆并置 `stale`，不阻塞任务 | 一次记忆更新失败把整轮 run 卡死 |
library;

import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 记录调用次数的 client（可定制返回文本）。
class _Client implements LLMClient {
  _Client({this.reply = '', this.throws = false});

  final String reply;
  final bool throws;
  int calls = 0;
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
    calls++;
    seen.add(List<LLMMessage>.of(messages));
    if (throws) throw StateError('simulated network failure');
    return ModelMessage(
      model: modelConfig.model,
      stopReason: 'stop',
      textOutput: reply,
      usage: ModelUsage(promptTokens: 1200, completionTokens: 300, totalTokens: 1500),
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

/// 一份带八个标签块的结构化摘要（模拟模型正常输出）。
const String _structuredReply = '<goal>把首页改成暗色主题</goal>'
    '<constraints>不要动 app.html</constraints>'
    '<done>已改好 index.html 的配色变量</done>'
    '<decisions>用 CSS 变量而不是硬编码颜色</decisions>'
    '<files>index.html（配色变量已改）</files>'
    '<errors>无</errors>'
    '<open_issues>侧边栏还没改</open_issues>'
    '<next_step>继续改侧边栏配色</next_step>';

/// 造一条"做过一次写文件"的完整轮次（user → 调用 → 结果）。
List<LLMMessage> _turn({
  required String userText,
  String path = 'index.html',
  bool isError = false,
}) =>
    <LLMMessage>[
      UserMessage.text(userText),
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
          isError: isError,
          arguments: '{"path":"$path"}',
          content: <UserContentPart>[
            TextPart(isError ? '权限不足：无法写入' : '写入成功'),
          ],
        ),
      ]),
    ];

/// 造一个"到线"的历史（window 10000 ⇒ 触发线 8500）。
///
/// 首条是任务与硬约束（goal/constraints 的来源），中间有一次写文件，
/// 末尾用长填充把总量撑过触发线。填充是 user 正文 ⇒ micro 清不动它
/// （micro 只清白名单工具输出），保证触发的层是阶段 2 而不是阶段 1。
List<LLMMessage> _longHistory() => <LLMMessage>[
      ..._turn(
        userText: '把首页改成暗色主题，不要动 app.html',
        path: 'index.html',
      ),
      // 40 × ~222 token ≈ 8880 ⇒ 总量到线（8500）。填充是 **user 正文**：
      // micro 只清白名单工具输出，清不动它 ⇒ 触发的必然是阶段 2/3。
      for (var i = 0; i < 40; i++)
        UserMessage.text('继续第 $i 步：调整配色变量与间距。${'字' * 210}'),
    ];

void main() {
  const window = 10000;
  final line = (window * ContractCompaction.autoCompactThreshold).floor();

  group('① 记忆可用 ⇒ 零 API（阶段 2）', () {
    test('★★★ client 一次都不调，摘要视图含 goal/constraints/files', () async {
      final client = _Client(reply: _structuredReply);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
      );
      final history = _longHistory();
      final state = AgentState(
        sessionId: 's-memory',
        history: AgentMessageHistory(messages: List<LLMMessage>.of(history)),
      );
      final before = c.estimateUsage(state);
      expect(before, greaterThanOrEqualTo(line), reason: '前提：必须到线，实际 $before');

      await c.compress(state);

      expect(client.calls, 0,
          reason: '★★ Session Memory 可用时必须零 API（省钱 + 省延迟 + 结果确定）');
      final event = c.lastCompaction!;
      expect(event.usedApi, isFalse);
      expect(event.layersRun, contains(CompactionLayer.sessionMemory));
      expect(event.layersRun, isNot(contains(CompactionLayer.apiSummary)));
      expect(event.afterTokens, lessThan(event.beforeTokens),
          reason: '压完必须真的小');

      final note = state.history.messages.first;
      expect(note, isA<UserMessage>());
      final text =
          (note as UserMessage).contents.whereType<TextPart>().map((p) => p.text).join();
      expect(text, contains('[上下文压缩快照]'));
      expect(text, contains('暗色主题'), reason: '★ goal 必须在（否则模型不知道要干什么）');
      expect(text, contains('不要动 app.html'),
          reason: '★★ 用户硬约束必须置顶 —— 漏了它会去改用户明令禁止的文件');
      expect(text, contains('index.html'), reason: '★ 相关文件必须在');
      // 约束段必须出现在头部（位置就是权重）
      final constraintIndex = text.indexOf('不要动 app.html');
      final filesIndex = text.indexOf('【相关文件与路径】');
      expect(constraintIndex, lessThan(filesIndex),
          reason: '硬约束必须排在摘要正文之前（第一眼能看到）');
      // 保留最近几轮原文（保护窗）
      expect(state.history.messages.length, greaterThan(1));
    });

    test('★★★ 记忆可用时不该出现"退化摘要"或伪造 content', () async {
      final client = _Client(reply: _structuredReply);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
      );
      final state = AgentState(
        sessionId: 's-memory2',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      await c.compress(state);

      final memory = c.lastSessionMemory;
      expect(memory, isNotNull);
      expect(memory!.goal, contains('暗色主题'));
      expect(memory.constraints, isNotEmpty);
      expect(memory.files, contains('index.html'));
      expect(memory.stale, isFalse);
    });
  });

  group('② 记忆不可用 ⇒ 走 API 摘要（阶段 3）', () {
    test('★★★ stale 记忆 ⇒ 必须调模型，且摘要落成快照', () async {
      final client = _Client(reply: _structuredReply);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        // 宿主回传的记忆已被标记 stale（上一次更新失败留下的）
        sessionMemoryProvider: (previous) async => SessionMemory(
          goal: '旧的过时目标',
          constraints: <String>['旧的过时约束'],
          updatedAtMs: 1,
          stale: true,
        ),
      );
      final state = AgentState(
        sessionId: 's-stale',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      await c.compress(state);

      expect(client.calls, greaterThan(0), reason: '★ stale 记忆不许拿来渲染视图');
      final event = c.lastCompaction!;
      expect(event.usedApi, isTrue);
      expect(event.layersRun, contains(CompactionLayer.apiSummary));
      expect(event.apiTokens, greaterThan(0), reason: '摘要调用的成本要如实记账');
      final text = (state.history.messages.first as UserMessage)
          .contents
          .whereType<TextPart>()
          .map((p) => p.text)
          .join();
      expect(text, contains('不要动 app.html'),
          reason: '模型摘要里的硬约束也要置顶进快照');
      expect(text, contains('侧边栏'), reason: '模型摘要的未决问题要落地');
      expect(text, isNot(contains('旧的过时约束')),
          reason: '★★ 过时记忆的内容绝不许出现在快照里（会误导模型）');
    });

    test('★★ 记忆"太久没更新"（时间维度 stale）⇒ 同样走 API', () async {
      final client = _Client(reply: _structuredReply);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        sessionMemoryProvider: (previous) async =>
            const SessionMemory(goal: '一小时前的目标', updatedAtMs: 1),
      );
      final state = AgentState(
        sessionId: 's-old-memory',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      await c.compress(state);

      expect(client.calls, greaterThan(0),
          reason: '★ 记忆超过 sessionMemoryStaleMs 未更新 ⇒ 按 stale 处理');
      expect(c.lastCompaction!.layersRun, contains(CompactionLayer.apiSummary));
    });

    test('★★ 关闭 Session Memory ⇒ 直接走 API', () async {
      final client = _Client(reply: _structuredReply);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        compactionConfig: const CompactionConfig(sessionMemoryEnabled: false),
      );
      final state = AgentState(
        sessionId: 's-off',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      await c.compress(state);

      expect(client.calls, greaterThan(0));
      expect(c.lastCompaction!.layersRun, contains(CompactionLayer.apiSummary));
    });

    test('★★ 用户给了 focus ⇒ 即使记忆可用也强制走模型', () async {
      final client = _Client(reply: _structuredReply);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
      );
      final state = AgentState(
        sessionId: 's-focus',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      await c.compactNow(state, focus: '只保留配色相关的结论');

      expect(client.calls, greaterThan(0));
      // focus 必须出现在摘要请求里（否则模型不知道往哪压）
      final systemPrompt = (client.seen.first.first as SystemMessage).content;
      expect(systemPrompt, contains('只保留配色相关的结论'));
    });
  });

  group('③ 摘要失败 ⇒ 历史不变 + 原因非空', () {
    test('★★★ 阶段 3 单独跑且失败：原历史一条不差', () async {
      final client = _Client(throws: true);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        compactionConfig: const CompactionConfig(sessionMemoryEnabled: false),
      );
      final history = _longHistory();
      final state = AgentState(
        sessionId: 's-fail',
        history: AgentMessageHistory(messages: List<LLMMessage>.of(history)),
      );

      final result = await CompactionPipeline(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        fallback: c,
        config: const CompactionConfig(
          contextWindow: window,
          sessionMemoryEnabled: false,
        ),
      ).apiSummaryOnly(state);

      expect(result.ok, isFalse);
      expect(result.usedApi, isTrue, reason: '发起了调用就算花了钱，失败也要记账');
      expect(result.failureReason, isNotNull);
      expect(result.failureReason!.isNotEmpty, isTrue);
      expect(state.history.messages.length, history.length,
          reason: '★★ 摘要在失败路径上一条消息都不许动');
      for (var i = 0; i < history.length; i++) {
        expect(state.history.messages[i], same(history[i]),
            reason: '第 $i 条被替换了 —— 失败就不许改历史');
      }
    });

    test('★★★ 全流水线里摘要失败：不伪造快照，兜底如实说明', () async {
      final client = _Client(throws: true);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        compactionConfig: const CompactionConfig(sessionMemoryEnabled: false),
      );
      final state = AgentState(
        sessionId: 's-fail2',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      await c.compress(state);

      final event = c.lastCompaction!;
      expect(event.failureReason, isNotNull, reason: '★ 失败必须留原因（不许静默）');
      expect(event.failureReason, isNot(contains('Exception')),
          reason: '原因用人话，不带堆栈/异常类名以外的实现细节');
      final joined = state.history.messages
          .whereType<UserMessage>()
          .map((m) => m.contents.whereType<TextPart>().map((p) => p.text).join())
          .join('\n');
      expect(joined, isNot(contains('[上下文压缩快照]')),
          reason: '★★ 摘要失败时绝不许插一条"看起来成功"的快照');
      expect(joined, contains('[系统维护]'),
          reason: '必须如实告诉模型/用户"内容是被清掉的，没进摘要"');
    });

    test('★★ 摘要返回空 ⇒ 同样算失败（不许把空摘要当成功）', () async {
      final client = _Client(reply: '   ');
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        compactionConfig: const CompactionConfig(sessionMemoryEnabled: false),
      );
      final state = AgentState(
        sessionId: 's-empty',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      await c.compress(state);

      expect(c.lastCompaction!.failureReason, isNotNull);
      final joined = state.history.messages
          .whereType<UserMessage>()
          .map((m) => m.contents.whereType<TextPart>().map((p) => p.text).join())
          .join('\n');
      expect(joined, isNot(contains('[上下文压缩快照]')));
    });
  });

  group('④ 记忆更新失败/超时 ⇒ 保留旧记忆 + stale，不阻塞', () {
    test('★★★ 更新器抛错 ⇒ 标 stale、任务继续（压缩照做）', () async {
      final client = _Client(reply: _structuredReply);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        sessionMemoryProvider: (previous) async =>
            throw StateError('memory update failed'),
      );
      final state = AgentState(
        sessionId: 's-memfail',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      await c.compress(state);

      expect(c.lastSessionMemory?.stale, isTrue,
          reason: '★ 更新失败要标记 stale（保留旧内容，不假装最新）');
      expect(c.lastCompaction?.failureReason, isNull,
          reason: '记忆更新失败不该让整次压缩算失败');
      expect(client.calls, greaterThan(0),
          reason: 'stale 记忆不能渲染视图 ⇒ 应当降级到 API 摘要');
    });

    test('★★ 更新器超时 ⇒ 同上（`sessionMemoryUpdateTimeoutMs` 生效）', () async {
      final client = _Client(reply: _structuredReply);
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        sessionMemoryProvider: (previous) =>
            Completer<SessionMemory>().future, // 永不完成
      );
      final state = AgentState(
        sessionId: 's-memtimeout',
        history: AgentMessageHistory(messages: _longHistory()),
      );

      final started = DateTime.now();
      await c.compress(state);
      final elapsed = DateTime.now().difference(started).inMilliseconds;

      expect(c.lastSessionMemory?.stale, isTrue);
      expect(elapsed,
          greaterThanOrEqualTo(ContractCompaction.sessionMemoryUpdateTimeoutMs - 200),
          reason: '必须在契约超时之后才放弃（不许提前判死）');
      expect(elapsed,
          lessThan(ContractCompaction.sessionMemoryUpdateTimeoutMs + 3000),
          reason: '★ 不许无限等 —— 用户明确要求"不阻塞任务"');
    });
  });

  group('⑤ SessionMemory 本地抽取规则（纯规则，零 IO）', () {
    test('★★ 约束/文件/未决问题都从结构化事实抽出来', () {
      final messages = <LLMMessage>[
        UserMessage.text('把首页改成暗色主题。不要动 app.html。所有改动必须在 src/ 目录内。'),
        ..._turn(userText: '先改 index.html', path: 'index.html'),
        ..._turn(userText: '试试改这个', path: 'locked.txt', isError: true),
      ];

      final memory = SessionMemoryBuilder().build(messages, nowMs: 1000);

      expect(memory.goal, contains('暗色主题'));
      expect(memory.constraints.any((c) => c.contains('不要动 app.html')), isTrue);
      expect(memory.constraints.any((c) => c.contains('必须在 src/')), isTrue,
          reason: '路径范围规则也属于硬约束');
      expect(memory.files, contains('index.html'));
      expect(memory.files, contains('locked.txt'));
      expect(memory.openIssues, isNotEmpty);
      expect(memory.openIssues.first, contains('write_file'));
      expect(memory.updatedAtMs, 1000);
      expect(memory.stale, isFalse);
    });

    test('★★ 我们插的维护说明不算"用户约束"（否则越压越脏）', () {
      final messages = <LLMMessage>[
        UserMessage.text('[系统维护] 更早的 30 条消息因上下文窗口吃紧被强制移除。'),
        UserMessage.text('把按钮改大'),
        ..._turn(userText: '改 index.html'),
      ];

      final memory = SessionMemoryBuilder().build(messages, nowMs: 1);

      expect(memory.constraints, isEmpty,
          reason: '★ 我们自己的维护说明被当成用户约束 ⇒ 下一轮模型会去遵守它');
      expect(memory.goal, '把按钮改大',
          reason: 'goal 要取第一条**真正的**用户请求（跳过维护说明）');
    });

    test('★★ stale 判定：过旧 ⇒ 不可用；stale 标记 ⇒ 不可用', () {
      const fresh = SessionMemory(goal: 'g', updatedAtMs: 1000);
      expect(fresh.isUsableAt(1000), isTrue);
      expect(fresh.isUsableAt(1000 + ContractCompaction.sessionMemoryStaleMs), isTrue);
      expect(fresh.isUsableAt(1000 + ContractCompaction.sessionMemoryStaleMs + 1),
          isFalse);
      expect(fresh.markStale().isUsableAt(1000), isFalse);
      expect(const SessionMemory().isUsableAt(1000), isFalse, reason: '空记忆不可用');
    });

    test('★★ JSON 往返：脏字段退化成空，不抛', () {
      final memory = SessionMemory.fromJson(<String, dynamic>{
        'goal': 42, // 类型错
        'constraints': <Object?>['a', 3, ''],
        'updatedAtMs': 'oops',
        'stale': 'yes',
      });
      expect(memory.goal, '');
      expect(memory.constraints, <String>['a']);
      expect(memory.updatedAtMs, 0);
      expect(memory.stale, isFalse);
      expect(SessionMemory.fromJson(memory.toJson()).goal, '');
    });
  });
}
