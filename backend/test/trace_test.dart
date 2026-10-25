import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **E4 全链路 trace**（2026-10-25 接线门禁）—— 独立文件，
/// 不与 `window_ratio_compressor_test.dart` 共享生命周期（此前三次弄坏它）。
///
/// 钉住 `RunOptions.traceDir` 的 conversation.json 落盘：
/// 1. 非空 ⇒ 落盘且 messages 可回放（user 请求 + assistant 回复都在）；
/// 2. 为空（默认）⇒ 不落任何文件（App 默认关，排障时才开）。
void main() {
  group('E4 —— traceDir 落盘（conversation.json 全对话回放）', () {
    test('★★★ traceDir 非空 ⇒ conversation.json 落盘且 messages 可回放',
        () async {
      final tmp = await Directory.systemTemp.createTemp('heracles_trace_e4_');
      try {
        final agent = HeraclesAgent(
          config: const BackendConfig(apiKey: 'k', modelName: 'm'),
          capabilities: const Capabilities(),
          client: _OkClient(),
          options: RunOptions(maxTurns: 4, traceDir: tmp.path),
        );
        await agent.run('问一句').drain<void>();

        final files = tmp
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList();
        expect(files, hasLength(1),
            reason: '实际 ${files.map((f) => f.path)}');

        final data =
            jsonDecode(files.first.readAsStringSync()) as Map<String, dynamic>;
        expect(data['turns'], greaterThanOrEqualTo(1));
        final msgs = data['messages'] as List;
        expect(msgs.length, greaterThanOrEqualTo(2),
            reason: 'user 请求 + assistant 回复都在 —— 逐条 toJson 可回放');
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('★ traceDir 为空（默认）⇒ 不落任何文件', () async {
      final tmp = await Directory.systemTemp.createTemp('heracles_notrace_');
      try {
        final agent = HeraclesAgent(
          config: const BackendConfig(apiKey: 'k', modelName: 'm'),
          capabilities: const Capabilities(),
          client: _OkClient(),
          options: const RunOptions(maxTurns: 4),
        );
        await agent.run('问一句').drain<void>();
        expect(tmp.listSync(), isEmpty, reason: '默认关闭：一个文件都不该有');
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}

class _OkClient implements LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      ModelMessage(
        textOutput: 'ok',
        model: modelConfig.model,
        stopReason: 'stop',
      );

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      Stream<StreamingMessage>.fromIterable([
        StreamingMessage(
          modelMessage: ModelMessage(
            textOutput: 'ok',
            model: modelConfig.model,
            stopReason: 'stop',
          ),
        ),
      ]);
}
