import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **A1 MCP 接入**（2026-10-25 接线门禁）。
///
/// 钉住 `RunOptions.mcpServers` 的接线语义（不要求真的起 MCP 服务器 ——
/// 单测里验证的是**我们的接线层**，协议握手归框架的测试）：
///
/// 1. 配了不可达的 MCP 服务器 ⇒ **run 照常完成**（MCP 是增强不是主链路，
///    连接失败只跳过该服务器）；
/// 2. 未配置（默认）⇒ 行为与以前完全一致；
/// 3. 配置形状：name/url（HTTP）与 name/command/args（stdio）都合法。
void main() {
  test('★★★ 配了不可达的 MCP 服务器 ⇒ run 照常完成（不炸主链路）', () async {
    final client = _OkClient();
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'm'),
      capabilities: const Capabilities(),
      client: client,
      options: RunOptions(
        maxTurns: 4,
        mcpServers: [
          {'name': 'unreachable', 'url': 'http://127.0.0.1:1/mcp'},
        ],
      ),
    );

    final events = <HeraclesEvent>[];
    await for (final e in agent.run('任务')) {
      events.add(e);
    }

    // MCP 连接失败被跳过，任务正常收尾
    expect(events.whereType<HeraclesFinished>(), hasLength(1),
        reason: 'MCP 是增强不是主链路 —— 连不上也绝不能炸 run');
    expect(events.whereType<HeraclesFailed>(), isEmpty);
  });

  test('★ 未配置 MCP（默认）⇒ 旧行为不变', () async {
    final client = _OkClient();
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'm'),
      capabilities: const Capabilities(),
      client: client,
      options: const RunOptions(maxTurns: 4),
    );
    final events = <HeraclesEvent>[];
    await for (final e in agent.run('任务')) {
      events.add(e);
    }
    expect(events.whereType<HeraclesFinished>(), hasLength(1));
  });

  test('★ stdio 形状配置（command/args）也合法且不炸', () async {
    final client = _OkClient();
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'm'),
      capabilities: const Capabilities(),
      client: client,
      options: RunOptions(
        maxTurns: 4,
        mcpServers: [
          {
            'name': 'local-stdio',
            'command': 'definitely-not-exist-binary',
            'args': ['--flag'],
          },
        ],
      ),
    );
    final events = <HeraclesEvent>[];
    await for (final e in agent.run('任务')) {
      events.add(e);
    }
    expect(events.whereType<HeraclesFinished>(), hasLength(1),
        reason: 'stdio 服务器起不来同样只跳过');
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
          textOutput: 'ok', model: modelConfig.model, stopReason: 'stop');

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
              textOutput: 'ok', model: modelConfig.model, stopReason: 'stop'),
        ),
      ]);
}
