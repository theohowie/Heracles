/// **缓存记账的口径测试**（2026-10-23）—— 用真机实测数字锁死公式。
///
/// ## 为什么必须有这个文件
///
/// 用户报过两次"命中缓存率太低了"。真机抓到原始 usage 后真相是：
///
/// ```
/// prompt_tokens: 5468, prompt_tokens_details: {cached_tokens: 5376}
/// ⇒ 真实命中率 98.3%
/// ```
///
/// 而当时 UI 显示 **~50%** —— 因为公式写成了 `cached / (cached + prompt)`，
/// 把"整段 prompt"和"其中的命中部分"**又加了一遍**。
///
/// **这个错在界面上很像"缓存坏了"**（低命中率），但缓存其实一直是好的。
/// 所以要用实测数字把公式钉住，避免以后有人"顺手改回去"。
///
/// 另外锁住一个**跨 wire 的语义差异**（这是同一个 bug 能藏住的原因）：
/// · OpenAI / DeepSeek：`prompt_tokens` **已含**命中部分
/// · Anthropic：`input_tokens` **不含**命中部分（命中在 `cache_read_input_tokens`）
///
/// ⇒ 规范化只能发生在**知道 wire 的地方**（backend），消费方一律 `cached / prompt`。
library;

import 'dart:async';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 假 client：按给定的 usage 返回一轮正文。
class _UsageClient implements LLMClient {
  _UsageClient(this.usage);

  final ModelUsage Function() usage;

  ModelMessage _build() => ModelMessage(
        model: 'test-model',
        stopReason: 'stop',
        textOutput: '好。',
        usage: usage(),
      );

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
  }) async =>
      Stream<StreamingMessage>.fromIterable([
        StreamingMessage(modelMessage: _build()),
      ]);
}

HeraclesAgent _agent(LLMClient client) => HeraclesAgent(
      config: const BackendConfig(
        apiKey: 'test-not-used',
        modelName: 'test-model',
        baseUrl: 'http://127.0.0.1:1',
      ),
      capabilities: const Capabilities(),
      options: const RunOptions(maxTurns: 4, maxToolCalls: 8),
      client: client,
    );

/// 跑一轮并取回**最后一条**用量事件。
Future<HeraclesTurnUsage> _usageOf(LLMClient client) async {
  HeraclesTurnUsage? got;
  await for (final e in _agent(client)
      .run('x')
      .timeout(const Duration(seconds: 10))) {
    if (e is HeraclesTurnUsage) got = e;
  }
  expect(got, isNotNull, reason: '必须播出用量事件（UI 靠它记账）');
  return got!;
}

void main() {
  group('缓存命中率口径（真机数字）', () {
    test('★★ OpenAI/DeepSeek：promptTokens 是整段，保持原值（不重复相加）', () async {
      // 真机实测值（设备 e35e48c6，中转站返回）
      final u = await _usageOf(_UsageClient(() => ModelUsage(
            promptTokens: 5468,
            completionTokens: 57,
            totalTokens: 5525,
            cachedToken: 5376,
            originalUsage: const {
              'prompt_tokens': 5468,
              'completion_tokens': 57,
              'total_tokens': 5525,
              'prompt_tokens_details': {'cached_tokens': 5376},
            },
          )));

      expect(u.promptTokens, 5468,
          reason: '★ 整段就是 5468；若变成 10844 就是把命中部分又加了一遍');
      expect(u.cachedTokens, 5376);

      // 真正的命中率（消费方公式：cached / prompt）
      final rate = u.cachedTokens! / u.promptTokens;
      expect(rate, closeTo(0.983, 0.001),
          reason: '真实命中率 98.3%；旧公式会给 49.6%');
      // 明确把"旧的错值"也断言出来，防止有人改回去
      final wrong = u.cachedTokens! / (u.cachedTokens! + u.promptTokens);
      expect(wrong, closeTo(0.496, 0.001),
          reason: '这就是用户看到的 ~50%：重复计数的产物');
    });

    test('★★ DeepSeek 顶层字段 prompt_cache_hit_tokens 也要认', () async {
      final u = await _usageOf(_UsageClient(() => ModelUsage(
            promptTokens: 5468,
            completionTokens: 57,
            cachedToken: 0, // 框架没归一化的情况
            originalUsage: const {
              'prompt_tokens': 5468,
              'prompt_cache_hit_tokens': 5376,
              'prompt_cache_miss_tokens': 92,
            },
          )));

      expect(u.cachedTokens, 5376,
          reason: 'DeepSeek 把命中数放在**顶层**，不在 prompt_tokens_details 里');
      expect(u.promptTokens, 5468);
    });

    test('★★ Anthropic：input_tokens 不含命中 ⇒ 必须加回来才成整段', () async {
      final u = await _usageOf(_UsageClient(() => ModelUsage(
            promptTokens: 92, // Anthropic 的 input_tokens = 仅未命中
            completionTokens: 57,
            cachedToken: 5376,
            originalUsage: const {
              'input_tokens': 92,
              'output_tokens': 57,
              'cache_read_input_tokens': 5376,
            },
          )));

      expect(u.cachedTokens, 5376);
      expect(u.promptTokens, 5468,
          reason: '★ 92 + 5376 = 5468（整段）；不加回来会把命中率算成 5843%');
    });

    test('未上报缓存字段 ⇒ cachedTokens 必须是 null（显示"不可用"，不是 0%）', () async {
      final u = await _usageOf(_UsageClient(() => ModelUsage(
            promptTokens: 1000,
            completionTokens: 10,
            originalUsage: const {
              'prompt_tokens': 1000,
              'completion_tokens': 10,
            },
          )));

      expect(u.cachedTokens, isNull,
          reason: '0% 会被读成"缓存坏了"；未上报必须与"命中 0"分开');
      expect(u.promptTokens, 1000);
    });
  });
}