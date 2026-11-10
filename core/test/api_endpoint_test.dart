// 2026-11-10：Anthropic / Responses 两轨 URL 拼接（用户实测 404）回归锁。
//
// 背景：用户填的 baseUrl 常自带 `/v1`（App 默认值就是
// `https://api.deepseek.com/v1`），而 Anthropic 轨旧代码**无条件**拼
// `/v1/messages` ⇒ `…/v1/v1/messages` ⇒ 404；Responses 轨旧代码**完全不补**
// `/v1` ⇒ 官方地址变 `/responses` ⇒ 也 404。
//
// 这个文件只锁一件事：**拼出来的 URL 长什么样**。
// ⚠️ 它**不**证明协议可用 —— 真 Key 端到端验证至今仍是零次。
import 'dart:async';
import 'dart:convert';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dart_agent_core/src/llm/api_endpoint.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

/// 记录每次请求的 URI，并统一回 400（不触发重试：只有 429/5xx 才重试）。
class _UriCaptureAdapter implements HttpClientAdapter {
  final List<Uri> uris = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uris.add(options.uri);
    return ResponseBody.fromString(
      jsonEncode({'error': 'deliberate 400 for uri capture'}),
      400,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('joinApiPath — Anthropic messages', () {
    test('官方地址（不带版本段）补 /v1', () {
      expect(
        joinApiPath('https://api.anthropic.com', 'messages'),
        'https://api.anthropic.com/v1/messages',
      );
    });

    test('中转站路径前缀（…/anthropic）补 /v1', () {
      expect(
        joinApiPath('https://relay.example.com/anthropic', 'messages'),
        'https://relay.example.com/anthropic/v1/messages',
      );
    });

    test('★★ baseUrl 已带 /v1 ⇒ 绝不出现 v1/v1', () {
      final url = joinApiPath('https://relay.example.com/v1', 'messages');
      expect(url, 'https://relay.example.com/v1/messages');
      expect(url.contains('/v1/v1'), isFalse);
    });

    test('★ baseUrl 带 /v1 且尾斜杠 ⇒ 落在 /v1/messages（不许 v1// 也不许 v1/v1）', () {
      final url = joinApiPath('https://relay.example.com/v1/', 'messages');
      expect(url, 'https://relay.example.com/v1/messages');
      expect(url.contains('/v1/v1'), isFalse);
      // 只看 path 段：scheme 后面的 `//` 是正常的，不能拿整串比
      expect(Uri.parse(url).path.contains('//'), isFalse);
    });

    test('App 默认的 DeepSeek baseUrl（自带 /v1）不被二次加版本', () {
      expect(
        joinApiPath('https://api.deepseek.com/v1', 'messages'),
        'https://api.deepseek.com/v1/messages',
      );
    });

    test('v1beta / v1alpha 原样接续，不补 /v1', () {
      expect(
        joinApiPath('https://generativelanguage.googleapis.com/v1beta', 'models'),
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
      expect(
        joinApiPath('https://example.com/v1alpha/', 'messages'),
        'https://example.com/v1alpha/messages',
      );
    });

    test('多个尾斜杠 / 路径前导斜杠都被规整', () {
      expect(
        joinApiPath('https://relay.example.com/v1//', '/messages'),
        'https://relay.example.com/v1/messages',
      );
    });
  });

  group('joinApiPath — Responses', () {
    test('官方地址（不带版本段）补 /v1', () {
      expect(
        joinApiPath('https://api.openai.com', 'responses'),
        'https://api.openai.com/v1/responses',
      );
    });

    test('baseUrl 已带 /v1 ⇒ 仍是 /v1/responses（不许 v1/v1）', () {
      final url = joinApiPath('https://api.openai.com/v1', 'responses');
      expect(url, 'https://api.openai.com/v1/responses');
      expect(url.contains('/v1/v1'), isFalse);
    });

    test('responses/<id>（checkResponseId）同样成立', () {
      expect(
        joinApiPath('https://api.openai.com', 'responses/resp_ok'),
        'https://api.openai.com/v1/responses/resp_ok',
      );
      final withV1 = joinApiPath(
        'https://api.openai.com/v1',
        'responses/resp_ok',
      );
      expect(withV1, 'https://api.openai.com/v1/responses/resp_ok');
      expect(withV1.contains('/v1/v1'), isFalse);
    });

    test('中转站带路径前缀 + 尾斜杠', () {
      expect(
        joinApiPath('https://relay.example.com/openai/v1/', 'responses'),
        'https://relay.example.com/openai/v1/responses',
      );
    });
  });

  // ★ 下面这组是"接线锁"：helper 写对了但客户端没调用它，上面全绿也没意义。
  group('客户端真的用上了 joinApiPath（接线验证）', () {
    test('ClaudeClient.generate：baseUrl 自带 /v1 ⇒ 请求 /v1/messages', () async {
      final adapter = _UriCaptureAdapter();
      final client = ClaudeClient(
        apiKey: 'test-key',
        baseUrl: 'https://relay.example.com/v1',
        client: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.generate(
          [UserMessage.text('hi')],
          modelConfig: ModelConfig(model: 'claude-test'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(adapter.uris, hasLength(1));
      expect(adapter.uris.single.path, '/v1/messages');
      expect(adapter.uris.single.toString(), isNot(contains('/v1/v1')));
    });

    test('ClaudeClient.stream：同样不拼出 v1/v1', () async {
      final adapter = _UriCaptureAdapter();
      final client = ClaudeClient(
        apiKey: 'test-key',
        baseUrl: 'https://api.deepseek.com/v1',
        client: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.stream(
          [UserMessage.text('hi')],
          modelConfig: ModelConfig(model: 'claude-test'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(adapter.uris.single.path, '/v1/messages');
    });

    test('ResponsesClient.generate：官方 baseUrl ⇒ 请求 /v1/responses', () async {
      final adapter = _UriCaptureAdapter();
      final client = ResponsesClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.generate(
          [UserMessage.text('hi')],
          modelConfig: ModelConfig(model: 'gpt-test'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(adapter.uris.single.path, '/v1/responses');
    });

    test('ResponsesClient.checkResponseId：官方 baseUrl ⇒ /v1/responses/<id>', () async {
      final adapter = _UriCaptureAdapter();
      final client = ResponsesClient(
        apiKey: 'test-key',
        client: Dio()..httpClientAdapter = adapter,
      );

      final ok = await client.checkResponseId('resp_ok');

      expect(ok, isFalse); // 我们回的是 400
      expect(adapter.uris.single.path, '/v1/responses/resp_ok');
    });

    test('ResponsesClient.generate：baseUrl 自带 /v1 ⇒ 不重复', () async {
      final adapter = _UriCaptureAdapter();
      final client = ResponsesClient(
        apiKey: 'test-key',
        baseUrl: 'https://relay.example.com/v1',
        client: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.generate(
          [UserMessage.text('hi')],
          modelConfig: ModelConfig(model: 'gpt-test'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(adapter.uris.single.path, '/v1/responses');
      expect(adapter.uris.single.toString(), isNot(contains('/v1/v1')));
    });
  });

  // Chat Completions 轨（openai_client）同病根：手填不带 /v1 的地址曾打 404。
  group('OpenAIClient 也用上了 joinApiPath（接线验证）', () {
    test('官方 baseUrl（不带 /v1）⇒ 请求 /v1/chat/completions', () async {
      final adapter = _UriCaptureAdapter();
      final client = OpenAIClient(
        apiKey: 'test-key',
        baseUrl: 'https://api.openai.com',
        client: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.generate(
          [UserMessage.text('hi')],
          modelConfig: ModelConfig(model: 'gpt-test'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(adapter.uris.single.path, '/v1/chat/completions');
    });

    test('App 默认的 deepseek baseUrl（自带 /v1）⇒ URL 与旧行为完全一致', () async {
      final adapter = _UriCaptureAdapter();
      final client = OpenAIClient(
        apiKey: 'test-key',
        baseUrl: 'https://api.deepseek.com/v1',
        client: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.generate(
          [UserMessage.text('hi')],
          modelConfig: ModelConfig(model: 'gpt-test'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(adapter.uris.single.path, '/v1/chat/completions');
      expect(adapter.uris.single.toString(), isNot(contains('/v1/v1')));
    });

    test('中转站路径前缀（…/openai）⇒ /openai/v1/chat/completions', () async {
      final adapter = _UriCaptureAdapter();
      final client = OpenAIClient(
        apiKey: 'test-key',
        baseUrl: 'https://relay.example.com/openai',
        client: Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.generate(
          [UserMessage.text('hi')],
          modelConfig: ModelConfig(model: 'gpt-test'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(adapter.uris.single.path, '/openai/v1/chat/completions');
    });

    test('stream 同样不拼出 v1/v1', () async {
      final adapter = _UriCaptureAdapter();
      final client = OpenAIClient(
        apiKey: 'test-key',
        baseUrl: 'https://api.deepseek.com/v1/',
        client: Dio()..httpClientAdapter = adapter,
      );

      // stream 轨不抛同步异常：错误经 stream 出来，所以断言流到错误为止
      final stream = await client.stream(
        [UserMessage.text('hi')],
        modelConfig: ModelConfig(model: 'gpt-test'),
      );
      await expectLater(stream.toList(), throwsA(isA<Exception>()));

      expect(adapter.uris.single.path, '/v1/chat/completions');
    });
  });
}
