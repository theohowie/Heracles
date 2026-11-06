// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **压缩后必须重载/保留的东西**（2026-11-06）：
// 项目指令（AGENTS.md）、最近修改的文件、以及"system prompt 与工具定义不受影响"。
//
// ## 本文件锁住的契约
//
// | # | 契约 | 抓的缺陷 |
// |---|---|---|
// | ① | 压缩**绝不动** system prompt 与工具定义（它们在历史之外） | 压缩把工具面改坏 ⇒ 模型看到不存在的工具、或丢掉工具能力 |
// | ② | AGENTS.md 被**重新注入**摘要视图（前 N 字符，截断要说明） | 压缩后模型忘了项目规则 ⇒ 违反约定（改错目录、用错构建命令） |
// | ③ | 最近修改的文件：小的给节选，**> 5000 token 的只给路径** | 把整份大文件又搬回摘要里 = 刚压完又填满 |
// | ④ | 读不到就**跳过并记 note**，绝不假装读过 | "摘要里有项目指令"的假象 ⇒ 模型以为看过规则 |
library;

import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 只统计调用次数、永远返回空摘要的 client（本文件不需要走 API）。
class _SilentClient implements LLMClient {
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

/// 造一条"写了一个文件"的轮次。
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

/// 造一个到线（window 10000 ⇒ 8500）的历史。
///
/// [fillerCount] / [fillerChars] 可调：注入 8000 字符项目指令的用例需要更大的
/// 原始历史，否则"摘要视图（含项目指令）"可能并不比原历史小 ——
/// 那时流水线会**拒绝**落地（纪律：插了反而更大就回滚）。
List<LLMMessage> _history({int fillerCount = 40, int fillerChars = 210}) =>
    <LLMMessage>[
      UserMessage.text('按项目规则把页面改成暗色主题'),
      ..._writeTurn('big.html'),
      ..._writeTurn('small.html'),
      for (var i = 0; i < fillerCount; i++)
        UserMessage.text('继续第 $i 步：调整配色与间距。${'字' * fillerChars}'),
    ];

String _noteText(AgentState state) => state.history.messages
    .whereType<UserMessage>()
    .map((m) => m.contents.whereType<TextPart>().map((p) => p.text).join())
    .join('\n');

void main() {
  const window = 10000;

  group('① 压缩绝不动 system prompt 与工具定义', () {
    test('★★ toolsHistory 逐字不变（同一实例、同一 JSON）', () async {
      final c = WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
      );
      final toolJson = <String, dynamic>{
        'name': 'read_file',
        'description': '读文件，返回带行号的内容。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
        },
      };
      final toolsHistory = <ToolsHistoryItem>[
        ToolsHistoryItem(tools: [toolJson], validFromMessageIndex: 0),
      ];
      final state = AgentState(
        sessionId: 's-tools',
        history: AgentMessageHistory(messages: _history()),
        toolsHistory: toolsHistory,
      );
      // SystemMessage 也在历史里（框架会把 system 段塞进请求最前）
      state.history.messages.insert(0, SystemMessage('你是 Heracles 智能体。'));

      final toolsBefore = WindowRatioCompressor.estimateToolDefinitions(state);
      final before = c.estimateUsage(state);
      expect(before, greaterThanOrEqualTo(c.triggerThreshold), reason: '前提：到线');

      await c.compress(state);

      expect(c.lastCompaction, isNotNull, reason: '前提：确实压缩过');
      expect(state.toolsHistory, same(toolsHistory),
          reason: '★★ 工具定义快照不许被压缩替换（换实例 = 工具面对账全乱）');
      expect(state.toolsHistory.single.tools.single, same(toolJson),
          reason: '★★ 连里面的 JSON 都不许被改写');
      expect(WindowRatioCompressor.estimateToolDefinitions(state), toolsBefore,
          reason: '工具定义占的 token 一个都不许变');
    });

    test('★★ 真实 HeraclesAgent：压缩过一轮后 systemPrompt 估算不变', () async {
      final caps = const Capabilities();
      final agent = HeraclesAgent(
        config: const BackendConfig(
          apiKey: 'k',
          modelName: 'm',
          modelWindowTokens: 20000,
        ),
        capabilities: caps,
        client: _ScriptedToolClient(),
        options: const RunOptions(maxTurns: 40, maxToolCalls: 50),
      );

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('做一个长任务')) {
        events.add(e);
      }

      expect(events.whereType<HeraclesContextCompressed>(), isNotEmpty,
          reason: '前提：这个 run 里真的压缩过（否则测不到"压缩后 system 还在不在"）');

      final b = agent.contextBreakdown();
      // 本 run 的脚本 client 从不上报 usage ⇒ 分项不会被等比放大，可以直接比
      expect(b['systemPrompt'], WindowRatioCompressor.estimateText(defaultSystemPrompt(caps)),
          reason: '★★ 系统提示词逐字未变 —— 压缩只动历史，不动人设与环境');
      expect(b['injected'], 0, reason: '没传额外提示/记忆 ⇒ 注入段为 0');
      expect(b['toolDefs'], greaterThan(0),
          reason: '工具定义仍在（压缩不会把工具面清空）');
      expect(agent.state!.toolsHistory, isNotEmpty);
    });
  });

  group('② 项目指令（AGENTS.md）被重新注入', () {
    late Directory tempDir;
    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('heracles-compaction-');
    });
    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('★★★ AGENTS.md 内容出现在摘要视图顶部（含截断说明）', () async {
      final agentsFile = File('${tempDir.path}/AGENTS.md');
      // 超过契约上限 ⇒ 必须截断并明说
      await agentsFile.writeAsString(
          '# 项目规则\n${'约定：不要动 app.html。${'字' * 40}\n' * 400}');
      final raw = await agentsFile.readAsString();
      expect(raw.length,
          greaterThan(ContractCompaction.projectInstructionsMaxChars));

      final c = WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub'),
        // 这个用例用**更大的窗口**（40K）：8000 字符的项目指令 + 保护窗内原文
        // 必须在一条 10K 窗口里塞不下（那是"窗口本身填太小"的配置错误，
        // 不是压缩的锅）。40K 是"小模型 + 8000 字符 AGENTS.md"的现实组合。
        modelWindowTokens: 40000,
        readProjectFile: (name) async =>
            File('${tempDir.path}/$name').existsSync()
                ? File('${tempDir.path}/$name').readAsString()
                : null,
      );
      final state = AgentState(
        sessionId: 's-agents',
        // 原始历史要够大（≈34.8K token，过 40K×0.85=34K 线），
        // 否则"摘要视图 + 8000 字符项目指令"可能并不比原历史小 ——
        // 那会被流水线的"必须真的省"纪律拒掉。
        history: AgentMessageHistory(
            messages: _history(fillerCount: 110, fillerChars: 300)),
      );

      await c.compress(state);

      final note = _noteText(state);
      expect(note, contains('【项目指令（AGENTS.md'),
          reason: '★ 项目指令必须被重新注入（压缩后模型要继续遵守）');
      expect(note, contains('约定：不要动 app.html。'),
          reason: '★ 规则正文必须在');
      expect(note, contains('节选'),
          reason: '超上限被截断时必须明说（不许让模型以为看到了全文）');
      expect(note, contains('[上下文压缩快照]'), reason: '这条路走的是阶段 2（零 API）');
    });

    test('★★ AGENTS.md 读不到 ⇒ 跳过并记 note，绝不假装读过', () async {
      final c = WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        readProjectFile: (name) async => null, // 读不到
      );
      final state = AgentState(
        sessionId: 's-noagents',
        history: AgentMessageHistory(messages: _history()),
      );

      await c.compress(state);

      final note = _noteText(state);
      expect(note, contains('项目指令未重载'),
          reason: '★ 读不到要如实说（note 会进摘要视图）');
      expect(note, isNot(contains('【项目指令')), reason: '不许伪造一个项目指令段');
      expect(c.lastCompaction!.injectedBlocks, greaterThan(0));
    });

    test('★★ 没注入读取器 ⇒ 同样记 note（backend 不碰 IO）', () async {
      final c = WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
      );
      final state = AgentState(
        sessionId: 's-noreader',
        history: AgentMessageHistory(messages: _history()),
      );

      await c.compress(state);

      expect(_noteText(state), contains('项目指令未重载'));
    });
  });

  group('③ 最近修改的文件：小的给节选，大的只给路径', () {
    test('★★★ > largeFileTokenThreshold 只给路径引用', () async {
      final bigContent = 'x' * 30000; // 30000/4 = 7500 token > 5000
      final smallContent = 'y' * 400; // 100 token
      final c = WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        readRecentFile: (path) async =>
            path == 'big.html' ? bigContent : smallContent,
      );
      final state = AgentState(
        sessionId: 's-files',
        history: AgentMessageHistory(messages: _history()),
      );

      await c.compress(state);

      final note = _noteText(state);
      expect(note, contains('【最近修改的文件'), reason: '必须列出改过的文件');
      expect(note, contains('big.html'));
      expect(note, contains('全文未注入'),
          reason: '★★ 大文件只给路径 + 明确说"需要请重新读取"');
      expect(note, isNot(contains('x' * 200)),
          reason: '★★ 大文件正文绝不许被搬回摘要（等于没压缩）');
      expect(note, contains('small.html'));
      expect(note, contains('y' * 100),
          reason: '小的给节选（有上下文价值，也不占多少 token）');
    });

    test('★★ 读不到文件内容 ⇒ 只列路径，不编造内容', () async {
      final c = WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        readRecentFile: (path) async => null,
      );
      final state = AgentState(
        sessionId: 's-files2',
        history: AgentMessageHistory(messages: _history()),
      );

      await c.compress(state);

      final note = _noteText(state);
      expect(note, contains('big.html'));
      expect(note, contains('未读取到内容'), reason: '★ 如实说"没读到"');
    });

    test('★★ 最近文件最多列 recentFilesMax 个（多的不列）', () async {
      final paths = <String>[
        for (var i = 0; i < 8; i++) 'f$i.html',
      ];
      final c = WindowRatioCompressor(
        client: _SilentClient(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: window,
        readRecentFile: (path) async => 'y' * 40,
      );
      final state = AgentState(
        sessionId: 's-many',
        history: AgentMessageHistory(messages: <LLMMessage>[
          UserMessage.text('按项目规则改一批文件'),
          for (final p in paths) ..._writeTurn(p),
          for (var i = 0; i < 40; i++)
            UserMessage.text('继续第 $i 步：调整配色与间距。${'字' * 210}'),
        ]),
      );

      await c.compress(state);

      final listed = paths
          .where((p) => _noteText(state).contains('- $p'))
          .toList();
      expect(listed.length, lessThanOrEqualTo(ContractCompaction.recentFilesMax),
          reason: '★ 最多 recentFilesMax 个（列表太长会挤掉摘要正文）');
      expect(listed, contains('f7.html'), reason: '最近的那个必须在');
    });
  });
}

/// 脚本化 client：前 N 轮请求工具（把历史拉长），最后给正文。
///
/// 与 `compression_e2e_test.dart` 的写法同源：不带 `functionCalls` 且
/// `stopReason=stop` 会被框架当成"最终回答"，run 立刻收尾 ——
/// 那样历史永远长不起来，压缩一次都不会发生。
class _ScriptedToolClient implements LLMClient {
  int calls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async =>
      _reply(modelConfig);

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async =>
      Stream<StreamingMessage>.fromIterable([
        StreamingMessage(modelMessage: _reply(modelConfig)),
      ]);

  ModelMessage _reply(ModelConfig modelConfig) {
    calls++;
    if (calls <= 30) {
      return ModelMessage(
        model: modelConfig.model,
        stopReason: 'tool_calls',
        // 每轮正文撑大历史（估算按历史文本算，不看 usage）
        textOutput: '这是一段很长的正文内容用来把上下文撑大。' * 40,
        functionCalls: [
          FunctionCall(
            id: 'call-$calls',
            name: 'list_files',
            // 参数每轮不同，否则会被 loop detector 判成打转
            arguments: '{"path":"probe-dir-$calls"}',
          ),
        ],
      );
    }
    return ModelMessage(
      model: modelConfig.model,
      stopReason: 'stop',
      textOutput: '长任务完成。',
    );
  }
}
