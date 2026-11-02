// Copyright (C) 2026 The Heracles Authors
//
// **MCP 探活的真连测试**（V0.4 F3，2026-11-02）。
//
// 纪律：**不用 mock HTTP 客户端**。这里用 `dart:io` 的 `HttpServer` 起一个真服务，
// 让 `probeMcpConnection` 走真实的 socket → 真实 JSON-RPC → 真实 SSE 解析。
// 为什么坚持真服务：
//  · 探活的价值全在"线路上到底发了什么、收到什么形状能认"；
//    mock 掉 Dio 就等于把被测的那一段替换成了我自己的假设，测试只证明我自洽；
//  · SSE 分帧、`Accept` 头、`Mcp-Session-Id` 回传这些**协议细节**只有真连接才暴露。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 假 MCP 服务器（真 socket）。
///
/// `mode` 决定它怎么回：
///  · `json` —— 普通 `application/json`（最常见的实现）；
///  · `sse` —— `text/event-stream`（Streamable HTTP 允许的另一种形状）；
///  · `status401` / `status500` —— HTTP 层失败；
///  · `malformed` —— 200 但 body 是坏 JSON；
///  · `rpcError` —— JSON-RPC 层 error（message 里故意夹一个带 token 的 URL）；
///  · `slow` —— 拖到客户端超时。
class _FakeMcp {
  _FakeMcp._(this._server, this.mode, this.tools, this.paged, this.delay);

  final HttpServer _server;
  final String mode;
  final List<String> tools;
  final bool paged;
  final Duration delay;

  /// 服务端收到的每一条请求（用来断言"该发的发了 / stdio 一条都没发"）。
  final List<_Seen> seen = <_Seen>[];

  String get url => 'http://127.0.0.1:${_server.port}/mcp';

  static Future<_FakeMcp> start({
    String mode = 'json',
    List<String> tools = const <String>['read_file', 'write_file', 'search'],
    bool paged = false,
    Duration delay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeMcp._(server, mode, tools, paged, delay);
    server.listen((req) async {
      final raw = await utf8.decoder.bind(req).join();
      Map<String, Object?>? body;
      if (raw.trim().isNotEmpty) {
        try {
          body = (jsonDecode(raw) as Map).cast<String, Object?>();
        } on FormatException {
          body = null;
        }
      }
      fake.seen.add(_Seen(
        method: '${body?['method'] ?? '?'}',
        accept: req.headers.value('accept') ?? '',
        sessionId: req.headers.value('mcp-session-id'),
        protocolVersion: req.headers.value('mcp-protocol-version'),
        body: body,
      ));

      if (delay > Duration.zero) await Future<void>.delayed(delay);

      if (mode == 'status401') {
        req.response.statusCode = 401;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"ok":false}');
        await req.response.close();
        return;
      }
      if (mode == 'status500') {
        req.response.statusCode = 500;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"ok":false}');
        await req.response.close();
        return;
      }
      if (mode == 'malformed') {
        req.response.headers.contentType = ContentType.json;
        // 截断的 JSON：真实事故里最常见的一种（代理把响应截了）。
        req.response.write('{"jsonrpc":"2.0","id":1,"result":');
        await req.response.close();
        return;
      }

      final method = body?['method'];
      // 通知：协议要求 202 且 body 为空。
      if (method == 'notifications/initialized') {
        req.response.statusCode = 202;
        await req.response.close();
        return;
      }

      Object? result;
      if (method == 'initialize') {
        result = <String, Object?>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, Object?>{
            'tools': <String, Object?>{},
          },
          'serverInfo': <String, Object?>{'name': 'fake-mcp', 'version': '1.0.0'},
        };
        // 只是**部分**服务器会给；给了就必须被回传（见 tools/list 的断言）。
        req.response.headers.set('Mcp-Session-Id', 'sess-abc');
      } else if (method == 'tools/list') {
        final params = body?['params'];
        final cursor = params is Map ? params['cursor'] : null;
        if (paged && cursor == null) {
          result = <String, Object?>{
            'tools': <Object?>[
              for (final n in tools.take(3)) _tool(n),
            ],
            'nextCursor': 'page-2',
          };
        } else if (paged) {
          result = <String, Object?>{
            'tools': <Object?>[
              for (final n in tools.skip(3)) _tool(n),
            ],
          };
        } else {
          result = <String, Object?>{
            'tools': <Object?>[for (final n in tools) _tool(n)],
          };
        }
      }

      final payload = mode == 'rpcError'
          ? <String, Object?>{
              'jsonrpc': '2.0',
              'id': body?['id'],
              'error': <String, Object?>{
                'code': -32001,
                'message':
                    'unauthorized: POST https://mcp.example.com/sse?token=SECRET-abc123 failed',
              },
            }
          : <String, Object?>{
              'jsonrpc': '2.0',
              'id': body?['id'],
              'result': result,
            };

      if (mode == 'sse') {
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        // 先发一条注释心跳（真实服务器常这么干），再发载荷 —— 解析器不能被心跳骗。
        req.response.write(': ping\n\n');
        req.response.write('event: message\n');
        req.response.write('data: ${jsonEncode(payload)}\n\n');
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(payload));
      }
      await req.response.close();
    });
    return fake;
  }

  static Map<String, Object?> _tool(String name) => <String, Object?>{
        'name': name,
        'description': 'fake tool $name',
        'inputSchema': <String, Object?>{'type': 'object'},
      };

  Future<void> close() => _server.close(force: true);
}

class _Seen {
  _Seen({
    required this.method,
    required this.accept,
    required this.sessionId,
    required this.protocolVersion,
    required this.body,
  });

  final String method;
  final String accept;
  final String? sessionId;
  final String? protocolVersion;
  final Map<String, Object?>? body;
}

McpServerConfig _http(String url, {String name = 'fs', Map<String, String>? env}) =>
    McpServerConfig(
      name: name,
      transport: ContractMcp.transportHttp,
      url: url,
      env: env ?? const <String, String>{},
    );

void main() {
  // --------------------------------------------------------------------------
  // ① 普通 JSON 响应
  // --------------------------------------------------------------------------

  test('① 普通 JSON：connected + 真实工具数，且真的走了 initialize→initialized→tools/list',
      () async {
    final fake = await _FakeMcp.start();
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(fake.url));

    expect(r.status, ContractMcp.statusConnected);
    expect(r.tools, 3, reason: '工具数只能来自 tools/list');
    expect(r.error, isNull);
    expect(r.serverName, 'fs');
    expect(r.latencyMs, greaterThanOrEqualTo(0));

    expect(fake.seen.map((s) => s.method).toList(),
        <String>['initialize', 'notifications/initialized', 'tools/list'],
        reason: '顺序就是协议要求的顺序：不发 initialized，很多服务器会拒 tools/list');
    // Accept 必须同时声明两种：只写 application/json 会被合规实现 406。
    expect(fake.seen.first.accept, contains('text/event-stream'));
    expect(fake.seen.first.accept, contains('application/json'));
    // initialize 的三件套必填字段。
    final params = (fake.seen.first.body!['params'] as Map).cast<String, Object?>();
    expect(params['protocolVersion'], kMcpProtocolVersion);
    expect(params['capabilities'], isA<Map>());
    expect((params['clientInfo'] as Map)['name'], 'Heracles');
    // 服务器给的会话 id 必须在后续请求里带回来。
    expect(fake.seen.last.sessionId, 'sess-abc');
  });

  // --------------------------------------------------------------------------
  // ② SSE 响应
  // --------------------------------------------------------------------------

  test('② SSE（text/event-stream）：同样 connected + 工具数（心跳注释不能骗过解析）',
      () async {
    final fake = await _FakeMcp.start(mode: 'sse');
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(fake.url));

    expect(r.status, ContractMcp.statusConnected);
    expect(r.tools, 3);
    expect(r.error, isNull);
  });

  // --------------------------------------------------------------------------
  // ③ HTTP 层失败
  // --------------------------------------------------------------------------

  test('③ 401 ⇒ failed，原因带状态码与"鉴权"，且不冒充连接成功', () async {
    final fake = await _FakeMcp.start(mode: 'status401');
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(fake.url));

    expect(r.status, ContractMcp.statusFailed);
    expect(r.tools, isNull, reason: '没连上就不能有工具数');
    expect(r.error, contains('401'));
    expect(r.error, contains('鉴权'));
  });

  test('③ 500 ⇒ failed，原因带状态码', () async {
    final fake = await _FakeMcp.start(mode: 'status500');
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(fake.url));

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, contains('500'));
    expect(r.tools, isNull);
  });

  // --------------------------------------------------------------------------
  // ④ 超时
  // --------------------------------------------------------------------------

  test('④ 服务器不回应 ⇒ failed + 超时文案（不挂在原地）', () async {
    final fake =
        await _FakeMcp.start(mode: 'slow', delay: const Duration(seconds: 3));
    addTearDown(fake.close);

    final r = await probeMcpConnection(
      _http(fake.url),
      timeout: const Duration(milliseconds: 200),
    );

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, contains('超时'));
    expect(r.tools, isNull);
  });

  // --------------------------------------------------------------------------
  // ⑤ stdio：不连、不发请求
  // --------------------------------------------------------------------------

  test('⑤ stdio ⇒ unsupported + 契约文案，且服务端收到 0 个请求', () async {
    final fake = await _FakeMcp.start();
    addTearDown(fake.close);

    final r = await probeMcpConnection(
      McpServerConfig(
        name: 'local',
        transport: ContractMcp.transportStdio,
        command: 'npx',
        // 故意给一个能连上的 url：如果实现"顺手试一下 http"，这里就会暴露。
        url: fake.url,
      ),
    );

    expect(r.status, ContractMcp.statusUnsupported);
    expect(r.error, ContractMcp.stdioUnsupportedMessage);
    expect(r.tools, isNull);
    expect(r.latencyMs, 0, reason: 'unsupported 没有发起连接，报耗时就是骗人');
    expect(fake.seen, isEmpty, reason: '手机端起不了 stdio，连都不要试');
  });

  // --------------------------------------------------------------------------
  // ⑥ 畸形响应
  // --------------------------------------------------------------------------

  test('⑥ 服务器回畸形 JSON ⇒ failed 且人话（不把 FormatException 甩给用户）', () async {
    final fake = await _FakeMcp.start(mode: 'malformed');
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(fake.url));

    expect(r.status, ContractMcp.statusFailed);
    expect(r.tools, isNull);
    expect(r.error, contains('无法解析'));
    expect(r.error, isNot(contains('FormatException')));
  });

  // --------------------------------------------------------------------------
  // ⑦ 脱敏：URL query / 服务器回显的秘密
  // --------------------------------------------------------------------------

  test('⑦ 连接失败时错误里只有 scheme+host+path，没有 ?token=', () async {
    // 先占一个端口再放掉：得到一个"确定没人监听"的本机端口。
    final probeSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probeSocket.port;
    await probeSocket.close();

    final r = await probeMcpConnection(
      _http('http://127.0.0.1:$deadPort/mcp?token=SECRET-abc123&api_key=k-999'),
      timeout: const Duration(seconds: 3),
    );

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, contains('127.0.0.1'), reason: 'host 要留着，否则没法排障');
    expect(r.error, isNot(contains('SECRET-abc123')));
    expect(r.error, isNot(contains('api_key')));
    expect(r.error, isNot(contains('token=')));
  });

  test('⑦ 服务器在 JSON-RPC error 里回显带 token 的 URL ⇒ 同样被脱敏', () async {
    final fake = await _FakeMcp.start(mode: 'rpcError');
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(fake.url));

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, contains('-32001'), reason: 'JSON-RPC 错误码要留给用户/排障');
    expect(r.error, contains('mcp.example.com'));
    expect(r.error, isNot(contains('SECRET-abc123')));
    expect(r.error, isNot(contains('token=')));
  });

  test('⑦ env 的值绝不出现在错误里（配置里带了看起来像秘密的值）', () async {
    final fake = await _FakeMcp.start(mode: 'status500');
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(
      fake.url,
      env: <String, String>{'SOME_NOTE': 'ENV-SECRET-VALUE-42'},
    ));

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, isNot(contains('ENV-SECRET-VALUE-42')));
  });

  // --------------------------------------------------------------------------
  // ⑧ 分页：少取一页就是虚报工具数
  // --------------------------------------------------------------------------

  test('⑧ tools/list 分页（nextCursor）⇒ 取全所有页再报数', () async {
    final fake = await _FakeMcp.start(
      tools: const <String>['a', 'b', 'c', 'd', 'e'],
      paged: true,
    );
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(fake.url));

    expect(r.status, ContractMcp.statusConnected);
    expect(r.tools, 5, reason: '两页 3+2，只算第一页会报 3');
    expect(fake.seen.where((s) => s.method == 'tools/list').length, 2);
  });

  test('⑧ 服务器确实没有工具 ⇒ connected + 0（如实，不改成 null 假装没连上）', () async {
    final fake = await _FakeMcp.start(tools: const <String>[]);
    addTearDown(fake.close);

    final r = await probeMcpConnection(_http(fake.url));

    expect(r.status, ContractMcp.statusConnected);
    expect(r.tools, 0);
  });

  // --------------------------------------------------------------------------
  // 配置层：不该发请求的就不发
  // --------------------------------------------------------------------------

  test('配置 http 但地址不是 http(s) ⇒ failed，且一个请求都没发', () async {
    final fake = await _FakeMcp.start();
    addTearDown(fake.close);

    final r = await probeMcpConnection(
      const McpServerConfig(name: 'x', transport: 'http', url: 'ftp://nope'),
    );

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, contains('http'));
    expect(fake.seen, isEmpty);
  });

  // --------------------------------------------------------------------------
  // 纯函数：脱敏
  // --------------------------------------------------------------------------

  test('redactMcpUrl 只留 scheme+host+port+path', () {
    expect(redactMcpUrl('https://u:p@h.example.com:8443/mcp?token=x#f'),
        'https://h.example.com:8443/mcp');
    expect(redactMcpUrl('https://h.example.com'), 'https://h.example.com');
    expect(redactMcpUrl('  '), '');
  });

  test('sanitizeMcpError 抹 Authorization / Bearer / URL query，并截断', () {
    final s = sanitizeMcpError(
      'GET https://h.example.com/mcp?token=SECRET-1 with Authorization: Bearer SECRET-1',
    );
    expect(s, contains('h.example.com'));
    expect(s, isNot(contains('SECRET-1')));
    expect(s, isNot(contains('token=')));
    expect(sanitizeMcpError('x' * 500).length, lessThanOrEqualTo(241));
  });
}
