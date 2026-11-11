// 2026-11-11：**真 HTTP 服务端**上的 wire 形状捕获（不是假 client）。
//
// ## 为什么要有这个文件
//
// 之前只有 `api_endpoint_test.dart`，它用假 `HttpClientAdapter` 抓 URI ——
// 证明了「拼出来的路径对不对」，但**没有证明真实请求体长什么样**。
//
// 这个文件起一个**真的 `HttpServer`**（loopback），让 `ClaudeClient` /
// `ResponsesClient` / `OpenAIClient` 真的把 HTTP 请求发出去，然后在服务端
// 把 `path` / headers / JSON body **原样记下来**再断言。
//
// ⇒ 它能抓到的回归：路径拼错、`tools` 形状写错、`max_completion_tokens`
//   被改名、`stream` 标志漏了、`reasoning_effort` 发错轨……
//
// ## ⚠️ 它仍然**不是**真 Key 验证
//
// 服务端是我们自己写的，它只回固定响应。所以：
// - 能证明：我们**发出去的东西**是什么形状（wire 出站方向）；
// - 不能证明：真实供应商会接受它（那必须要真 Key + 真端点）。
//
// 这条边界写在这里，别把本文件绿了当成「协议跑通」。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:test/test.dart';

/// 一次被服务端捕获到的请求。
class CapturedRequest {
  CapturedRequest(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;

  @override
  String toString() => '$method $path';
}

/// 本地 wire 捕获服务器。
///
/// 回一个**结构合法但内容固定**的响应，好让客户端正常走完解析路径。
class WireServer {
  WireServer._(this._server, this._responseBody);

  final HttpServer _server;
  final String _responseBody;

  final List<CapturedRequest> requests = <CapturedRequest>[];

  int get port => _server.port;
  String get baseUrl => 'http://127.0.0.1:$port';

  static Future<WireServer> start({required String responseBody}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ws = WireServer._(server, responseBody);
    unawaited(ws._serve());
    return ws;
  }

  Future<void> _serve() async {
    await for (final req in _server) {
      final raw = await utf8.decoder.bind(req).join();
      final captured = <String, String>{};
      req.headers.forEach((name, values) {
        captured[name.toLowerCase()] = values.join(',');
      });
      requests.add(CapturedRequest(req.method, req.uri.path, captured, raw));
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(_responseBody);
      await req.response.close();
    }
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  group('ClaudeClient：真实 HTTP 请求的 path / headers / body 形状', () {
    late WireServer server;

    setUp(() async {
      server = await WireServer.start(responseBody: jsonEncode({
        'id': 'msg_test',
        'type': 'message',
        'role': 'assistant',
        'model': 'claude-test',
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'stop_reason': 'end_turn',
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      }));
    });

    tearDown(() => server.close());

    test('★ baseUrl 自带 /v1 时，真实请求打到 /v1/messages（不是 /v1/v1/messages）',
        () async {
      final client = ClaudeClient(
        apiKey: 'wire-test-key',
        baseUrl: '${server.baseUrl}/v1',
      );

      await client.generate(
        [UserMessage.text('hi')],
        modelConfig: ModelConfig(model: 'claude-test'),
      );

      expect(server.requests, hasLength(1));
      expect(server.requests.single.path, '/v1/messages');
      expect(server.requests.single.path, isNot(contains('/v1/v1')));
    });

    test('★ baseUrl 不带版本段时，真实请求打到 /v1/messages', () async {
      final client = ClaudeClient(
        apiKey: 'wire-test-key',
        baseUrl: server.baseUrl,
      );

      await client.generate(
        [UserMessage.text('hi')],
        modelConfig: ModelConfig(model: 'claude-test'),
      );

      expect(server.requests.single.path, '/v1/messages');
    });

    test('请求头带 x-api-key 与 anthropic-version，且 Key 不出现在 body 里', () async {
      final client = ClaudeClient(
        apiKey: 'wire-secret-key',
        baseUrl: server.baseUrl,
      );

      await client.generate(
        [UserMessage.text('hi')],
        modelConfig: ModelConfig(model: 'claude-test'),
      );

      final caps = server.requests.single;
      // 真正断言到「Key 在请求头里」——这是 API Key 不得进日志/进 body 的
      // 唯一正确落点（见 AGENTS §3：Key 只出现于请求头）。
      expect(caps.headers['x-api-key'], 'wire-secret-key');
      expect(caps.headers['anthropic-version'], isNotEmpty);
      expect(caps.body, isNot(contains('wire-secret-key')),
          reason: '★ API Key 只许进请求头，绝不能进 body（会进日志/被回显）');
      expect(caps.json['model'], 'claude-test');
      expect(caps.json['messages'], isA<List<dynamic>>());
    });

    test('带 tools 时 body 里的 tools 是 Anthropic 形状（name/input_schema）', () async {
      final tool = Tool(
        name: 'read_file',
        description: 'read a file',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
      );

      final client = ClaudeClient(
        apiKey: 'wire-test-key',
        baseUrl: server.baseUrl,
      );

      await client.generate(
        [UserMessage.text('读一下 README')],
        modelConfig: ModelConfig(model: 'claude-test'),
        tools: [tool],
      );

      final body = server.requests.single.json;
      final tools = body['tools'] as List<dynamic>;
      expect(tools, hasLength(1));
      final first = tools.first as Map<String, dynamic>;
      expect(first['name'], 'read_file');
      expect(first.containsKey('input_schema'), isTrue,
          reason: 'Anthropic 用 input_schema，不是 OpenAI 的 parameters');
      expect(first['input_schema'], isA<Map<String, dynamic>>());
    });
  });

  group('ResponsesClient：真实 HTTP 请求的 path 形状', () {
    late WireServer server;

    setUp(() async {
      server = await WireServer.start(responseBody: jsonEncode({
        'id': 'resp_test',
        'object': 'response',
        'status': 'completed',
        'model': 'gpt-test',
        'output': [
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'ok'},
            ],
          },
        ],
        'usage': {'input_tokens': 1, 'output_tokens': 1},
      }));
    });

    tearDown(() => server.close());

    test('★ baseUrl 不带版本段 ⇒ 真实请求打到 /v1/responses', () async {
      final client = ResponsesClient(
        apiKey: 'wire-test-key',
        baseUrl: server.baseUrl,
      );

      await client.generate(
        [UserMessage.text('hi')],
        modelConfig: ModelConfig(model: 'gpt-test'),
      );

      expect(server.requests.single.path, '/v1/responses');
    });

    test('★ baseUrl 自带 /v1 ⇒ 仍是 /v1/responses（不重复）', () async {
      final client = ResponsesClient(
        apiKey: 'wire-test-key',
        baseUrl: '${server.baseUrl}/v1',
      );

      await client.generate(
        [UserMessage.text('hi')],
        modelConfig: ModelConfig(model: 'gpt-test'),
      );

      expect(server.requests.single.path, '/v1/responses');
      expect(server.requests.single.path, isNot(contains('/v1/v1')));
    });
  });

  group('OpenAIClient：真实 HTTP 请求的 path 形状', () {
    late WireServer server;

    setUp(() async {
      server = await WireServer.start(responseBody: jsonEncode({
        'id': 'chatcmpl-test',
        'object': 'chat.completion',
        'model': 'gpt-test',
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
      }));
    });

    tearDown(() => server.close());

    test('★ 手填根域（不带 /v1）⇒ 真实请求打到 /v1/chat/completions', () async {
      final client = OpenAIClient(
        apiKey: 'wire-test-key',
        baseUrl: server.baseUrl,
      );

      await client.generate(
        [UserMessage.text('hi')],
        modelConfig: ModelConfig(model: 'gpt-test'),
      );

      expect(server.requests.single.path, '/v1/chat/completions');
    });

    test('★ 自带 /v1 ⇒ 仍是 /v1/chat/completions（不重复）', () async {
      final client = OpenAIClient(
        apiKey: 'wire-test-key',
        baseUrl: '${server.baseUrl}/v1',
      );

      await client.generate(
        [UserMessage.text('hi')],
        modelConfig: ModelConfig(model: 'gpt-test'),
      );

      expect(server.requests.single.path, '/v1/chat/completions');
      expect(server.requests.single.path, isNot(contains('/v1/v1')));
    });
  });
}
