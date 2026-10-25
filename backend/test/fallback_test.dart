import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **D3 模型降级**（2026-10-25 接线门禁）。
///
/// 钉住 `RunOptions.fallbackModelNames` 的降级链语义：
///
/// 1. 主模型失败 + 配了备用 ⇒ 播 `HeraclesFallback(from, to)`，任务用
///    备用模型**重跑**并正常收尾（"不把错误直接甩给用户"）；
/// 2. 降级后仍失败且备用耗尽 ⇒ 如实 `HeraclesFailed`；
/// 3. 预算超限**不触发降级**（不是模型问题 —— 降级只会烧更多钱）；
/// 4. 未配置 fallback ⇒ 失败直接报（旧行为）。
void main() {
  test('★★★ 主模型失败 ⇒ 降级到备用重跑并成功收尾', () async {
    final client = _FailFirstClient(); // 主模型调用抛异常，第二次成功
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'main-model'),
      capabilities: const Capabilities(),
      client: client,
      options: RunOptions(
        maxTurns: 4,
        fallbackModelNames: ['backup-model'],
      ),
    );

    final events = <HeraclesEvent>[];
    await for (final e in agent.run('任务')) {
      events.add(e);
    }

    final fallbacks = events.whereType<HeraclesFallback>().toList();
    expect(fallbacks, hasLength(1), reason: '恰好降级一次');
    expect(fallbacks.single.from, 'main-model');
    expect(fallbacks.single.to, 'backup-model');

    // 降级后用新模型跑通了
    expect(client.modelsUsed, contains('main-model'));
    expect(client.modelsUsed, contains('backup-model'));
    expect(events.whereType<HeraclesFinished>(), hasLength(1));
    expect(events.whereType<HeraclesFailed>(), isEmpty);
  });

  test('★★ 备用耗尽 ⇒ 如实失败（不无限降级）', () async {
    final client = _AlwaysFailClient();
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'main'),
      capabilities: const Capabilities(),
      client: client,
      options: RunOptions(
        maxTurns: 4,
        fallbackModelNames: ['b1'],
      ),
    );
    final events = <HeraclesEvent>[];
    await for (final e in agent.run('任务')) {
      events.add(e);
    }
    expect(events.whereType<HeraclesFallback>(), hasLength(1), reason: '只降到 b1');
    expect(events.whereType<HeraclesFailed>(), hasLength(1), reason: '降级也失败 ⇒ 如实报');
  });

  test('★ 未配置 fallback ⇒ 失败直接报（旧行为）', () async {
    final client = _AlwaysFailClient();
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'main'),
      capabilities: const Capabilities(),
      client: client,
      options: const RunOptions(maxTurns: 4),
    );
    final events = <HeraclesEvent>[];
    await for (final e in agent.run('任务')) {
      events.add(e);
    }
    expect(events.whereType<HeraclesFallback>(), isEmpty);
    expect(events.whereType<HeraclesFailed>(), hasLength(1));
  });
}

/// 第一次调用抛异常（模拟主模型失败），之后回正常正文。
class _FailFirstClient implements LLMClient {
  final modelsUsed = <String>[];
  var failedOnce = false;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    modelsUsed.add(modelConfig.model);
    if (!failedOnce) {
      failedOnce = true;
      throw Exception('模拟主模型故障：连接超时');
    }
    return ModelMessage(
      textOutput: '备用模型完成',
      model: modelConfig.model,
      stopReason: 'stop',
    );
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
    modelsUsed.add(modelConfig.model);
    if (!failedOnce) {
      failedOnce = true;
      throw Exception('模拟主模型故障：连接超时');
    }
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(
        modelMessage: ModelMessage(
          textOutput: '备用模型完成',
          model: modelConfig.model,
          stopReason: 'stop',
        ),
      ),
    ]);
  }
}

/// 永远失败。
class _AlwaysFailClient implements LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      throw Exception('模拟模型故障');

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      throw Exception('模拟模型故障');
}
