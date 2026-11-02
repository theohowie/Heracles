// Copyright (C) 2026 The Heracles Authors
//
// **MCP 服务层测试**（V0.4 F3；契约见 `docs/INTERFACE.md` §N16.2）。
//
// 测试走生产真实路径：用 `setMockMethodCallHandler` 伪造宿主的
// `heracles/command` 通道（与 `about_links_test.dart` 同一手法），
// 不引入只给测试用的假 `McpService` —— 否则"测试绿的缝和线上不是一条路"。
//
// 覆盖七组硬性纪律：
//   ① CRUD 走通道且形状正确；
//   ② 非法配置在**本地**被拦下（handler 一次都不该被调用）；
//   ③ 密钥进 env 一律拒绝（含小写 `api_key`、`token` 变体）；
//   ④ 连接失败**如实**（failed + 原因非空，且不造假 tools 数）；
//   ⑤ stdio ⇒ unsupported，且**没有发起连接**；
//   ⑥ 脱敏：错误消息里不出现密钥值与 URL 的 query 段；
//   ⑦ MissingPluginException（旧宿主没有 MCP 能力）⇒ 如实降级，不崩。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles_backend/heracles_backend.dart'
    show ContractMcp, McpServerConfig;

import 'package:heracles/services/mcp_service.dart';

/// 临时允许**真实** HTTP。
///
/// `flutter_test` 会把 `HttpClient` 换成"任何请求都回 400"的假实现
/// （防止测试意外联网）。本文件有两条用例确实要连本机 socket
/// （证明"默认构造真的接上了 backend 探活"），必须先在当前 zone 关掉它。
/// ⚠️ 不关的话失败信息会是 `服务器返回 HTTP 400（未知 Content-Type）`，
/// 看着像服务端问题，其实是测试框架在拦。
void allowRealHttp() {
  final previous = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = previous);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ContractMcp.channel);

  /// 宿主收到的每一次调用（用来断言"该调的调了 / 不该调的一次都没调"）。
  late List<MethodCall> calls;

  /// 伪造宿主：`respond` 返回的 Map 就是通道返回值。
  void mockHost(Object? Function(MethodCall call) respond) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return respond(call);
    });
  }

  /// 一个合法的 http 配置（各用例按需改字段）。
  McpServerConfig httpCfg({
    String name = 'fs',
    String url = 'https://mcp.example.com/sse',
    Map<String, String> env = const <String, String>{},
    bool enabled = true,
  }) =>
      McpServerConfig(
        name: name,
        transport: ContractMcp.transportHttp,
        url: url,
        env: env,
        enabled: enabled,
      );

  setUp(() {
    calls = <MethodCall>[];
  });

  tearDown(() {
    // 清理：不清理会污染同进程里的其它测试（mock handler 是全局的）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // ==========================================================================
  // ① CRUD：走通道，形状正确
  // ==========================================================================

  test('① listServers 调 mcpList，并把 7 个字段原样解析', () async {
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'fs',
              'transport': 'http',
              'command': '',
              'url': 'https://mcp.example.com/sse?x=1',
              'args': <String>['--flag'],
              'env': <String, String>{'PLAIN': 'v'},
              'enabled': false,
            },
          ],
        });

    final list = await McpService().listServers();

    expect(calls.single.method, ContractMcp.listMethod);
    expect(calls.single.arguments, isNull, reason: 'mcpList 没有入参');
    expect(list, hasLength(1));
    final s = list.single;
    expect(s.name, 'fs');
    expect(s.transport, ContractMcp.transportHttp);
    expect(s.url, 'https://mcp.example.com/sse?x=1',
        reason: '读回来的配置要原样保留（不改写宿主数据）');
    expect(s.args, <String>['--flag']);
    expect(s.env, <String, String>{'PLAIN': 'v'});
    expect(s.enabled, isFalse);
  });

  test('① listServers：空数组是合法空（"确实没配置"）', () async {
    mockHost((call) => <String, Object?>{'ok': true, 'servers': <Object?>[]});
    expect(await McpService().listServers(), isEmpty);
  });

  test('① listServers：宿主说 ok:false ⇒ 抛错说清，不回落成空列表', () async {
    mockHost((call) => <String, Object?>{
          'ok': false,
          'code': 'E_MCP_STORE_BROKEN',
          'error': '配置存储读不出来',
        });

    await expectLater(
      McpService().listServers(),
      throwsA(isA<McpServiceError>()
          .having((e) => e.code, 'code', 'E_MCP_STORE_BROKEN')
          .having((e) => e.message, 'message', contains('配置存储读不出来'))),
      reason: '空列表与"没配置"同形，读失败必须抛，不能假装没有服务器',
    );
  });

  test('① listServers：缺 servers 键 ⇒ 报形状错，不当成空列表', () async {
    mockHost((call) => <String, Object?>{'ok': true});
    await expectLater(
      McpService().listServers(),
      throwsA(isA<McpServiceError>()
          .having((e) => e.code, 'code', McpErrorCode.badResponse)),
    );
  });

  test('① saveServer 调 mcpSave，server 形状含 7 个键', () async {
    mockHost((call) => <String, Object?>{'ok': true});

    final r = await McpService().saveServer(httpCfg(name: 'fs', enabled: true));

    expect(r.ok, isTrue);
    expect(calls.single.method, ContractMcp.saveMethod);
    final args = (calls.single.arguments as Map).cast<String, Object?>();
    final server = (args['server'] as Map).cast<String, Object?>();
    expect(server.keys.toSet(), <String>{
      'name', 'transport', 'command', 'url', 'args', 'env', 'enabled',
    });
    expect(server['name'], 'fs');
    expect(server['transport'], ContractMcp.transportHttp);
    expect(server['enabled'], isTrue);
  });

  test('① saveServer：宿主 ok:false ⇒ 原样带回 code 与人话', () async {
    mockHost((call) => <String, Object?>{
          'ok': false,
          'code': ContractMcp.errInvalidConfig,
          'error': '宿主二次校验拒绝',
        });

    final r = await McpService().saveServer(httpCfg());

    expect(r.ok, isFalse);
    expect(r.code, ContractMcp.errInvalidConfig);
    expect(r.error, contains('宿主二次校验拒绝'));
  });

  test('① deleteServer 调 mcpDelete，deleted 如实透传', () async {
    mockHost((call) => <String, Object?>{'ok': true, 'deleted': false});

    final r = await McpService().deleteServer('fs');

    expect(calls.single.method, ContractMcp.deleteMethod);
    expect((calls.single.arguments as Map)['name'], 'fs');
    expect(r.ok, isTrue);
    expect(r.deleted, isFalse, reason: '宿主说没有这条就如实回 false，不谎报删掉了');
  });

  // ==========================================================================
  // ② 非法配置：**本地**拦下，一个通道方法都不调
  // ==========================================================================

  test('② 非法配置（ftp url）⇒ 本地拒绝，通道一次都没被调用', () async {
    mockHost((call) => <String, Object?>{'ok': true});

    final r = await McpService().saveServer(httpCfg(url: 'ftp://mcp.example.com'));

    expect(r.ok, isFalse);
    expect(r.code, ContractMcp.errInvalidConfig);
    expect(r.error, isNotEmpty);
    expect(calls, isEmpty, reason: '第一道闸必须在本地（validateMcpServer），不能靠宿主兜');
  });

  test('② 空 name / stdio 缺 command 同样本地拒绝', () async {
    mockHost((call) => <String, Object?>{'ok': true});

    final empty1 = await McpService().saveServer(httpCfg(name: '   '));
    final empty2 = await McpService().saveServer(
      const McpServerConfig(name: 'x', transport: ContractMcp.transportStdio),
    );

    expect(empty1.ok, isFalse);
    expect(empty2.ok, isFalse);
    expect(empty1.code, ContractMcp.errInvalidConfig);
    expect(calls, isEmpty);
  });

  // ==========================================================================
  // ③ 密钥进 env：一律拒绝（大小写无关 / 键名含关键字）
  // ==========================================================================

  for (final key in <String>[
    'API_KEY',
    'api_key',
    'Token',
    'GITHUB_TOKEN',
    'client_secret',
    'DB_PASSWORD',
  ]) {
    test('③ env 出现 $key ⇒ 拒绝（E_MCP_SECRET_IN_ENV）且不调通道', () async {
      mockHost((call) => <String, Object?>{'ok': true});

      final r = await McpService().saveServer(httpCfg(
        env: <String, String>{key: 'sk-live-0123456789'},
      ));

      expect(r.ok, isFalse);
      expect(r.code, ContractMcp.errSecretInEnv);
      expect(r.error, contains(key), reason: '要告诉用户是哪一个键名有问题');
      expect(r.error, isNot(contains('sk-live-0123456789')),
          reason: '错误消息里绝不能回显密钥值');
      expect(calls, isEmpty, reason: '密钥配置根本不该离开本机');
    });
  }

  // ==========================================================================
  // ④ 连接失败如实 / ⑤ stdio 不连
  // ==========================================================================

  test('④ 服务名不存在 ⇒ not_configured', () async {
    mockHost((call) => <String, Object?>{'ok': true, 'servers': <Object?>[]});

    final r = await McpService().testConnection('nope');

    expect(r.status, ContractMcp.statusNotConfigured);
    expect(r.tools, isNull);
    expect(r.error, isNotEmpty);
  });

  test('④ 显式关闭探活（withoutProbe）⇒ failed + 明确原因，绝不假报已连接', () async {
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'fs',
              'transport': 'http',
              'url': 'https://mcp.example.com/sse',
            },
          ],
        });

    final r = await McpService.withoutProbe().testConnection('fs');

    expect(r.status, ContractMcp.statusFailed);
    expect(r.tools, isNull, reason: '没有真连上就不能有工具数');
    expect(r.error, contains('未接入'));
  });

  test('④ 生产默认 = 真探活：会真的去连（失败原因必须来自网络层，不是"未接入"）',
      () async {
    allowRealHttp();
    // 用 1 号端口（几乎不可能有服务）：这一条**不需要**起服务端 ——
    // 本文件的职责是证明"默认构造成了真探活"，真实握手/SSE 由 backend
    // `mcp_probe_test.dart` 对着本地 HttpServer 覆盖（那边能 bind，见报告）。
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'fs',
              'transport': 'http',
              'url': 'http://127.0.0.1:1/mcp',
            },
          ],
        });

    final r = await McpService(
      probeTimeout: const Duration(seconds: 3),
    ).testConnection('fs');

    expect(r.status, ContractMcp.statusFailed);
    expect(r.tools, isNull, reason: '连不上就不能有工具数');
    expect(r.error, isNotNull);
    expect(r.error, isNot(contains('未接入')), reason: '默认构造成该真的去连');
    expect(r.error, contains('连接'), reason: '要给出真实网络层的失败原因');
    expect(r.error, contains('127.0.0.1'), reason: 'host 要留着排障');
  });

  test('④ connector 报告失败 ⇒ failed + 原因非空（不吞原因）', () async {
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'fs',
              'transport': 'http',
              'url': 'https://mcp.example.com/sse',
            },
          ],
        });

    final r = await McpService(
      connector: (cfg) async => McpConnectorOutcome.failed('HTTP 401：鉴权失败'),
    ).testConnection('fs');

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, contains('401'));
    expect(r.tools, isNull);
  });

  test('④ connector 成功但没给工具数 ⇒ 判 failed（不接受"大概连上了"）', () async {
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'fs',
              'transport': 'http',
              'url': 'https://mcp.example.com/sse',
            },
          ],
        });

    final r = await McpService(
      connector: (cfg) async => const McpConnectorOutcome(ok: true),
    ).testConnection('fs');

    expect(r.status, ContractMcp.statusFailed);
    expect(r.tools, isNull);
  });

  test('④ connector 抛异常 ⇒ failed，不把异常漏给 UI', () async {
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'fs',
              'transport': 'http',
              'url': 'https://mcp.example.com/sse',
            },
          ],
        });

    final r = await McpService(
      connector: (cfg) async => throw StateError('socket closed'),
    ).testConnection('fs');

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, contains('socket closed'));
    expect(r.tools, isNull);
  });

  test('④ connector 成功 ⇒ connected + 真实工具数', () async {
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'fs',
              'transport': 'http',
              'url': 'https://mcp.example.com/sse',
            },
          ],
        });

    final r = await McpService(
      connector: (cfg) async => McpConnectorOutcome.connected(3),
    ).testConnection('fs');

    expect(r.status, ContractMcp.statusConnected);
    expect(r.tools, 3);
    expect(r.error, isNull);
    expect(r.latencyMs, greaterThanOrEqualTo(0));
  });

  test('⑤ stdio ⇒ unsupported + 人话，且**没有发起连接**', () async {
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'local',
              'transport': 'stdio',
              'command': 'npx',
              'args': <String>['-y', 'server'],
            },
          ],
        });

    var connectorCalls = 0;
    final r = await McpService(
      connector: (cfg) async {
        connectorCalls++;
        return McpConnectorOutcome.connected(1);
      },
    ).testConnection('local');

    expect(r.status, ContractMcp.statusUnsupported);
    expect(r.error, ContractMcp.stdioUnsupportedMessage);
    expect(r.tools, isNull);
    expect(connectorCalls, 0, reason: '手机端起不了 stdio 子进程，连都不要试');
  });

  // ==========================================================================
  // ⑥ 脱敏：URL 只留 scheme+host+path，不出现 query / userinfo / 密钥
  // ==========================================================================

  test('⑥ redactUrl 去掉 query / fragment / userinfo，保留 scheme+host+path', () {
    expect(
      McpService.redactUrl(
          'https://user:pw@mcp.example.com:8443/sse?api_key=sk-live-9#frag'),
      'https://mcp.example.com:8443/sse',
    );
    expect(McpService.redactUrl('https://mcp.example.com'), 'https://mcp.example.com');
    expect(McpService.redactUrl('   '), '');
  });

  test('⑥ 连接异常里的 query 段与 Authorization 头不落到 error 里', () async {
    mockHost((call) => <String, Object?>{
          'ok': true,
          'servers': <Object?>[
            <String, Object?>{
              'name': 'fs',
              'transport': 'http',
              'url': 'https://mcp.example.com/sse?api_key=sk-live-777',
            },
          ],
        });

    final r = await McpService(
      connector: (cfg) async => throw StateError(
        'connect failed: GET https://mcp.example.com/sse?api_key=sk-live-777 '
        'with Authorization: Bearer sk-live-777 -> 403',
      ),
    ).testConnection('fs');

    expect(r.status, ContractMcp.statusFailed);
    expect(r.error, contains('mcp.example.com'),
        reason: '要留下能排障的 host，但不能留下秘密');
    expect(r.error, isNot(contains('sk-live-777')));
    expect(r.error, isNot(contains('api_key')));
    expect(r.error, isNot(contains('Bearer')));
  });

  test('⑥ describe() 只给 name/transport/脱敏 URL，不含 env 值', () {
    final d = McpService.describe(
      const McpServerConfig(
        name: 'fs',
        transport: ContractMcp.transportHttp,
        url: 'https://mcp.example.com/sse?api_key=sk-live-777',
        env: <String, String>{'PLAIN': 'top-secret-value'},
      ),
    );

    expect(d, contains('fs'));
    expect(d, isNot(contains('sk-live-777')));
    expect(d, isNot(contains('api_key')));
    expect(d, isNot(contains('top-secret-value')));
  });

  // ==========================================================================
  // ⑦ 旧宿主（没有 MCP 能力）：如实降级，不崩、不假装"没配置"
  // ==========================================================================

  test('⑦ 没有通道实现（MissingPluginException）⇒ listServers 报"客户端不支持"', () async {
    // 不注册 mock handler：测试环境里等价于"平台侧没有这个方法"。
    await expectLater(
      McpService().listServers(),
      throwsA(isA<McpServiceError>()
          .having((e) => e.code, 'code', McpErrorCode.hostUnsupported)
          .having((e) => e.hostUnsupported, 'hostUnsupported', isTrue)
          .having((e) => e.message, 'message', contains('MCP'))),
      reason: '旧宿主没有 mcpList ⇒ 必须区别于"确实没配置服务器"',
    );
  });

  test('⑦ 没有通道实现 ⇒ save/delete 返回 ok:false + hostUnsupported，不抛给 UI', () async {
    final save = await McpService().saveServer(httpCfg());
    final del = await McpService().deleteServer('fs');

    expect(save.ok, isFalse);
    expect(save.code, McpErrorCode.hostUnsupported);
    expect(del.ok, isFalse);
    expect(del.deleted, isFalse);
    expect(del.code, McpErrorCode.hostUnsupported);
  });
}
