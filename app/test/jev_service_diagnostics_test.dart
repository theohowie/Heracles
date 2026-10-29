import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/services/jev_service.dart';

/// **JEV 云端服务层：可诊断化回归测试**（task-5，2026-10-29）。
///
/// 覆盖任务书 item 1–6：
/// · decide 返回 `JevDecisionResult` + `JevDiagnostics`
///   （resolvedEndpoint/httpStatus/serverCode/serverMessage/traceId/
///   rawBody≤2KB/elapsedMs/modelCorrected/hint）；
/// · 只在 HTTP 422 重试一次，且两次题键都**仍叫 `recommend`**
///   （不照抄平台文档示例的 `stop` —— 否则 200 也会误判「没给 noul」）；
/// · 401/403/413/429 不重试 + 人话；
/// · 模型不是 `NeoHorse-Jev-4B` ⇒ 强制纠正并标 `modelCorrected`；
/// · endpointFor 五分支 + 裸域名显式 hint；模型目录可读时 422 的 hint；
/// · API Key 只进请求头：error message / 异常 / 栈 / rawBody / 诊断
///   toString 里都不得出现（只允许脱敏 URL：scheme+host+path）。
///
/// HTTP 层用 Dio 自带的 `HttpClientAdapter` 接口做假适配器 —— 项目里
/// 没有现成 http mock 依赖（已 grep 全仓：无 http_mock_adapter /
/// MockClient / HttpOverrides），故**不新增依赖**，只用 dio 自己的
/// 扩展点（`dio.httpClientAdapter = ...`）。
const String _testKey = 'sk-test-SECRET-12345';
const String _base = 'https://tokenrhythm.studio/v1/decision';

typedef _Handler = FutureOr<ResponseBody> Function(RequestOptions options);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final _Handler handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

Dio _dio(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(responseType: ResponseType.json));
  dio.httpClientAdapter = adapter;
  return dio;
}

ResponseBody _jsonBody(Object? body, int status) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    'content-type': ['application/json'],
  },
);

ResponseBody _textBody(String text, int status) => ResponseBody.fromString(
  text,
  status,
  headers: {
    'content-type': ['text/plain'],
  },
);

Map<String, Object?> _decisionBody({
  double noul = 0.82,
  String? thought,
  String model = kJevDefaultModel,
  String? traceId,
}) {
  final answer = <String, Object?>{'type': 'noul', 'noul': noul};
  if (thought != null) answer['thought'] = thought;
  final body = <String, Object?>{
    'model': model,
    'answers': {'recommend': answer},
  };
  if (traceId != null) body['traceId'] = traceId;
  return body;
}

/// 断言「一定抛 JevException」并取回它（解析 diagnostics 用）。
Future<JevException> _catchJev(Future<void> Function() body) async {
  try {
    await body();
  } on JevException catch (e) {
    return e;
  }
  fail('预期抛 JevException，但没有抛');
}

Future<JevException> _decideExpectError(_FakeAdapter adapter) => _catchJev(
  () => JevCloudClient.decide(
    baseUrl: _base,
    apiKey: _testKey,
    model: kJevDefaultModel,
    question: '要不要合并？',
    client: _dio(adapter),
  ),
);

void main() {
  group('endpointFor 五分支 + 裸域名 hint（item 3）', () {
    test('① 完整 /decision 原样使用（explicit、无 hint）', () {
      final r = JevCloudClient.resolveEndpoint(
        'https://tokenrhythm.studio/v1/decision',
      );
      expect(r.url, 'https://tokenrhythm.studio/v1/decision');
      expect(r.explicit, isTrue);
      expect(r.hint, isNull);
    });

    test('② /decisions 原样使用', () {
      final r = JevCloudClient.resolveEndpoint('https://b.example/v1/decisions');
      expect(r.url, 'https://b.example/v1/decisions');
      expect(r.explicit, isTrue);
    });

    test('③ /systemone 兼容端点原样使用', () {
      final r = JevCloudClient.resolveEndpoint('https://b.example/v1/systemone');
      expect(r.url, 'https://b.example/v1/systemone');
      expect(r.explicit, isTrue);
    });

    test('④ 填到 /v1 → 补 /decision，hint 说明「已按 /v1/decision 请求」'
        '（用户实测可用的填法）', () {
      final r = JevCloudClient.resolveEndpoint('https://tokenrhythm.studio/v1');
      expect(r.url, 'https://tokenrhythm.studio/v1/decision');
      expect(r.explicit, isFalse);
      expect(r.hint, isNotNull);
      expect(r.hint, contains('/v1/decision'));
      expect(r.hint, contains('NeoHorse-Jev-4B'));
    });

    test('⑤ 裸域名 → 按 /v1/decision 请求（不再静默补 /systemone），hint 建议填 /v1',
        () {
      final r = JevCloudClient.resolveEndpoint('https://tokenrhythm.studio');
      expect(r.url, 'https://tokenrhythm.studio/v1/decision');
      expect(r.explicit, isFalse);
      expect(r.hint, isNotNull);
      expect(r.hint, contains('/v1'));
      expect(r.hint, contains('NeoHorse-Jev-4B'));
      expect(r.hint, isNot(contains('/systemone')));
      // 旧口径 endpointFor 与服务层一致（不破坏旧调用点）
      expect(JevCloudClient.endpointFor('https://tokenrhythm.studio'), r.url);
    });

    test('其它路径前缀：保留前缀补 /decision（含 /api/v1 形态）', () {
      final plain = JevCloudClient.resolveEndpoint('https://x.example/api');
      expect(plain.url, 'https://x.example/api/decision');
      expect(plain.explicit, isFalse);
      expect(plain.hint, contains('/api'));

      final withV1 = JevCloudClient.resolveEndpoint('https://x.example/api/v1');
      expect(withV1.url, 'https://x.example/api/v1/decision');
      expect(withV1.explicit, isFalse);
      expect(withV1.hint, contains('/api/v1'));
    });

    test('模型目录：裸域名/到 /v1/完整端点都归一到 /v1/models（item 3）', () {
      expect(
        JevCloudClient.modelsUrlFor('https://tokenrhythm.studio'),
        'https://tokenrhythm.studio/v1/models',
      );
      expect(
        JevCloudClient.modelsUrlFor('https://tokenrhythm.studio/v1'),
        'https://tokenrhythm.studio/v1/models',
      );
      expect(
        JevCloudClient.modelsUrlFor('https://tokenrhythm.studio/v1/decision'),
        'https://tokenrhythm.studio/v1/models',
      );
      expect(
        JevCloudClient.modelsUrlFor('https://x.example/api/v1'),
        'https://x.example/api/v1/models',
      );
    });

    test('尾部斜杠归一化；空地址给出可读 hint', () {
      expect(
        JevCloudClient.resolveEndpoint('https://x.example/v1/').url,
        'https://x.example/v1/decision',
      );
      final empty = JevCloudClient.resolveEndpoint('   ');
      expect(empty.url, '');
      expect(empty.hint, isNotNull);
      expect(JevCloudClient.modelsUrlFor('   '), '');
    });
  });

  group('decide 成功：可诊断对象（item 1）', () {
    test('200 → 旧 getter 兼容 + diagnostics 全字段', () async {
      final adapter = _FakeAdapter(
        (o) => _jsonBody(
          _decisionBody(
            noul: 0.82,
            thought: '  先验证再合并  ',
            traceId: 'tr-ok',
          ),
          200,
        ),
      );
      final r = await JevCloudClient.decide(
        baseUrl: _base,
        apiKey: _testKey,
        model: kJevDefaultModel,
        question: '要不要合并？',
        client: _dio(adapter),
      );
      // 旧调用点的三个 getter（JevController.ask / 设置页测试连接）
      expect(r.yesProb, closeTo(0.82, 1e-9));
      expect(r.thought, '先验证再合并');
      expect(r.model, 'NeoHorse-Jev-4B');
      expect(r.recommended, isTrue);

      final d = r.diagnostics;
      expect(d.resolvedEndpoint, 'https://tokenrhythm.studio/v1/decision');
      expect(d.httpStatus, 200);
      expect(d.ok, isTrue);
      expect(d.serverCode, isNull);
      expect(d.serverMessage, isNull);
      expect(d.traceId, 'tr-ok');
      expect(d.rawBody, contains('"noul"'));
      expect(d.elapsedMs, greaterThanOrEqualTo(0));
      expect(d.modelCorrected, isFalse);
      expect(d.hint, isNull);
      expect(d.attempts, 1);
      expect(d.retriedAfter422, isFalse);
      // INTERFACE §N11 点名的字段一个不少
      expect(
        d.toJson().keys,
        containsAll([
          'resolvedEndpoint',
          'httpStatus',
          'serverCode',
          'serverMessage',
          'traceId',
          'rawBody',
          'elapsedMs',
          'modelCorrected',
          'hint',
        ]),
      );

      // 报文：模型固定 ID、题键 recommend、没有 stop、Key 只在请求头
      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.headers['Authorization'], 'Bearer $_testKey');
      final body = req.data as Map;
      expect(body['model'], kJevDefaultModel);
      expect(body['state'], '要不要合并？');
      expect((body['questions'] as Map).keys.toList(), ['recommend']);
      expect(
        ((body['questions'] as Map)['recommend'] as Map)['type'],
        'noul',
      );
    });

    test('模型不是固定 ID → 强制纠正 + modelCorrected=true + hint（item 3）',
        () async {
      final adapter = _FakeAdapter((o) => _jsonBody(_decisionBody(), 200));
      final r = await JevCloudClient.decide(
        baseUrl: _base,
        apiKey: _testKey,
        model: 'gpt-4o',
        question: '要不要合并？',
        client: _dio(adapter),
      );
      expect((adapter.requests.single.data as Map)['model'], kJevDefaultModel);
      expect(r.diagnostics.modelCorrected, isTrue);
      expect(r.diagnostics.hint, contains('固定模型 ID'));
    });

    test('模型为空同样被纠正（旧行为的安全升级）', () async {
      final adapter = _FakeAdapter((o) => _jsonBody(_decisionBody(), 200));
      final r = await JevCloudClient.decide(
        baseUrl: _base,
        apiKey: _testKey,
        model: '   ',
        question: '要不要合并？',
        client: _dio(adapter),
      );
      expect((adapter.requests.single.data as Map)['model'], kJevDefaultModel);
      expect(r.diagnostics.modelCorrected, isTrue);
    });

    test('大小写/空格差异也算填错 → 强制规范 ID + modelCorrected=true',
        () async {
      final adapter = _FakeAdapter((o) => _jsonBody(_decisionBody(), 200));
      final r = await JevCloudClient.decide(
        baseUrl: _base,
        apiKey: _testKey,
        model: '  neohorse-jev-4b  ',
        question: '要不要合并？',
        client: _dio(adapter),
      );
      expect((adapter.requests.single.data as Map)['model'], 'NeoHorse-Jev-4B');
      expect(r.diagnostics.modelCorrected, isTrue);
    });
  });

  group('422 重试一次，题键仍叫 recommend（item 2）', () {
    test('首次 422 → 第二次 200：成功、标记重试、题键始终 recommend',
        () async {
      var calls = 0;
      final adapter = _FakeAdapter((o) {
        calls += 1;
        if (calls == 1) {
          return _jsonBody(
            {'code': 'invalid_request', 'message': '参数不对', 'traceId': 't-1'},
            422,
          );
        }
        return _jsonBody(_decisionBody(noul: 0.7), 200);
      });
      final r = await JevCloudClient.decide(
        baseUrl: _base,
        apiKey: _testKey,
        model: kJevDefaultModel,
        question: '要不要合并？',
        client: _dio(adapter),
      );
      expect(r.yesProb, closeTo(0.7, 1e-9));
      expect(adapter.requests, hasLength(2));
      expect(r.diagnostics.attempts, 2);
      expect(r.diagnostics.retriedAfter422, isTrue);
      expect(r.diagnostics.httpStatus, 200);
      expect(r.diagnostics.hint, contains('重试成功'));

      for (final req in adapter.requests) {
        final q = (req.data as Map)['questions'] as Map;
        expect(q.keys.toList(), ['recommend'],
            reason: '重试也不许改用文档示例的 stop 键');
        expect((q['recommend'] as Map)['type'], 'noul');
      }
      // 重试只精简 instructions，题键不变
      final retryQ =
          (adapter.requests[1].data as Map)['questions'] as Map;
      expect((retryQ['recommend'] as Map).containsKey('instructions'), isFalse);
      expect(
        ((adapter.requests[0].data as Map)['questions'] as Map)['recommend'],
        containsPair('instructions', '推荐用户这样做吗？'),
      );
    });

    test('422 重试不受地址归一化影响：/v1 base → 两次都打 /v1/decision',
        () async {
      var calls = 0;
      final adapter = _FakeAdapter((o) {
        calls += 1;
        return calls == 1
            ? _jsonBody({'code': 'invalid_request'}, 422)
            : _jsonBody(_decisionBody(), 200);
      });
      final r = await JevCloudClient.decide(
        baseUrl: 'https://tokenrhythm.studio/v1',
        apiKey: _testKey,
        model: kJevDefaultModel,
        question: '要不要合并？',
        client: _dio(adapter),
      );
      expect(adapter.requests, hasLength(2));
      for (final req in adapter.requests) {
        expect(req.uri.toString(), 'https://tokenrhythm.studio/v1/decision');
        expect((req.data as Map)['questions'].keys.toList(), ['recommend']);
      }
      expect(
        r.diagnostics.resolvedEndpoint,
        'https://tokenrhythm.studio/v1/decision',
      );
      expect(r.diagnostics.retriedAfter422, isTrue);
      expect(r.diagnostics.hint, contains('重试成功'));
    });

    test('422 重试不受地址归一化影响：裸域名 → 两次都打 /v1/decision',
        () async {
      var calls = 0;
      final adapter = _FakeAdapter((o) {
        calls += 1;
        return calls == 1
            ? _jsonBody({'code': 'invalid_request'}, 422)
            : _jsonBody(_decisionBody(), 200);
      });
      final r = await JevCloudClient.decide(
        baseUrl: 'https://tokenrhythm.studio',
        apiKey: _testKey,
        model: kJevDefaultModel,
        question: '要不要合并？',
        client: _dio(adapter),
      );
      expect(adapter.requests, hasLength(2));
      for (final req in adapter.requests) {
        expect(req.uri.toString(), 'https://tokenrhythm.studio/v1/decision');
        expect((req.data as Map)['questions'].keys.toList(), ['recommend']);
      }
      expect(r.diagnostics.retriedAfter422, isTrue);
      expect(r.diagnostics.hint, contains('重试成功'));
    });

    test('两次都 422（带 body）→ 抛异常，诊断留 code/traceId/重试次数',
        () async {
      final adapter = _FakeAdapter(
        (o) => _jsonBody(
          {'code': 'invalid_request', 'message': '题数/体积不对', 'traceId': 't-422'},
          422,
        ),
      );
      final e = await _decideExpectError(adapter);
      expect(adapter.requests, hasLength(2));
      final d = e.diagnostics!;
      expect(d.httpStatus, 422);
      expect(d.serverCode, 'invalid_request');
      expect(d.serverMessage, '题数/体积不对');
      expect(d.traceId, 't-422');
      expect(d.attempts, 2);
      expect(d.retriedAfter422, isTrue);
      expect(d.hint, contains('重试一次'));
      expect(e.message, contains('题数/体积不对'));
      expect(e.message, contains('422'));
    });

    test('422 无 body → 仍重试一次；诊断字段为空但可读', () async {
      final adapter = _FakeAdapter((o) => _textBody('', 422));
      final e = await _decideExpectError(adapter);
      expect(adapter.requests, hasLength(2));
      final d = e.diagnostics!;
      expect(d.httpStatus, 422);
      expect(d.serverCode, isNull);
      expect(d.serverMessage, isNull);
      expect(d.rawBody, '');
      expect(d.attempts, 2);
      expect(e.message, contains('422'));
      expect(e.message, contains('NeoHorse-Jev-4B'));
    });
  });

  group('401/403/413/429：不重试 + 人话（item 4）', () {
    for (final status in [401, 403, 413, 429]) {
      test('$status 只发一次请求，诊断带 status/code/traceId', () async {
        final adapter = _FakeAdapter(
          (o) => _jsonBody(
            {
              'code': 'e$status',
              'message': '平台原因 $status',
              'traceId': 't$status',
            },
            status,
          ),
        );
        final e = await _decideExpectError(adapter);
        expect(adapter.requests, hasLength(1), reason: '非 422 不许重试');
        final d = e.diagnostics!;
        expect(d.httpStatus, status);
        expect(d.serverCode, 'e$status');
        expect(d.serverMessage, '平台原因 $status');
        expect(d.traceId, 't$status');
        expect(d.attempts, 1);
        expect(d.retriedAfter422, isFalse);
        expect(e.message, contains('平台原因 $status'));
      });
    }

    test('401 无 body → 人话点出密钥问题', () async {
      final e = await _decideExpectError(_FakeAdapter((o) => _textBody('', 401)));
      expect(e.message, contains('密钥'));
      expect(e.diagnostics!.httpStatus, 401);
    });

    test('403 无 body → 人话点出权限/灰度', () async {
      final e = await _decideExpectError(_FakeAdapter((o) => _textBody('', 403)));
      expect(e.message, contains('权限'));
    });

    test('413 无 body → 人话点出 1MiB 体积限制', () async {
      final e = await _decideExpectError(_FakeAdapter((o) => _textBody('', 413)));
      expect(e.message, contains('1MiB'));
      expect(e.message, contains('413'));
    });

    test('429 无 body → 人话点出限流', () async {
      final e = await _decideExpectError(_FakeAdapter((o) => _textBody('', 429)));
      expect(e.message, contains('限流'));
    });

    test('500 不重试（重试只给 422）', () async {
      final adapter = _FakeAdapter(
        (o) => _jsonBody({'code': 'server_error'}, 500),
      );
      final e = await _decideExpectError(adapter);
      expect(adapter.requests, hasLength(1));
      expect(e.diagnostics!.httpStatus, 500);
      expect(e.diagnostics!.serverCode, 'server_error');
    });
  });

  group('422 hint：模型目录可读（item 5）', () {
    setUp(JevCloudClient.resetModelsCatalogProbe);

    test('先「获取模型」成功 → decide 422 的 hint 说鉴权通过、目录可读',
        () async {
      final modelsAdapter = _FakeAdapter(
        (o) => _jsonBody({
          'data': [
            {'id': 'NeoHorse-Jev-4B'},
            {'id': 'NeoHorse-Jev-4B'},
            {'id': 'chat-model'},
          ],
        }, 200),
      );
      final models = await JevCloudClient.fetchModels(
        baseUrl: _base,
        apiKey: _testKey,
        client: _dio(modelsAdapter),
      );
      expect(models, ['NeoHorse-Jev-4B', 'chat-model']);
      expect(
        modelsAdapter.requests.single.uri.toString(),
        'https://tokenrhythm.studio/v1/models',
      );

      final decideAdapter = _FakeAdapter(
        (o) => _jsonBody(
          {'code': 'upstream', 'message': '上游超时', 'traceId': 't-up'},
          422,
        ),
      );
      final e = await _decideExpectError(decideAdapter);
      expect(e.diagnostics!.modelsCatalogReadable, isTrue);
      expect(
        e.diagnostics!.hint,
        contains('鉴权通过、模型目录可读，422 多半是模型权限/参数/上游限制'),
      );
    });

    test('没读过目录 → 422 hint 不提「鉴权通过」', () async {
      final e = await _decideExpectError(
        _FakeAdapter((o) => _textBody('', 422)),
      );
      expect(e.diagnostics!.modelsCatalogReadable, isFalse);
      expect(e.diagnostics!.hint, isNot(contains('鉴权通过')));
      expect(e.diagnostics!.hint, contains('1–16'));
    });

    test('目录读取失败（401）→ 不标记可读', () async {
      final modelsAdapter = _FakeAdapter(
        (o) => _jsonBody({'code': 'unauthorized'}, 401),
      );
      await _catchJev(
        () => JevCloudClient.fetchModels(
          baseUrl: _base,
          apiKey: _testKey,
          client: _dio(modelsAdapter),
        ),
      );
      final e = await _decideExpectError(
        _FakeAdapter((o) => _textBody('', 422)),
      );
      expect(e.diagnostics!.modelsCatalogReadable, isFalse);
      expect(e.diagnostics!.hint, isNot(contains('鉴权通过')));
    });

    test('显式 modelsCatalogReadable=true 也能触发该 hint', () async {
      final adapter = _FakeAdapter((o) => _textBody('', 422));
      final e = await _catchJev(
        () => JevCloudClient.decide(
          baseUrl: _base,
          apiKey: _testKey,
          model: kJevDefaultModel,
          question: '要不要合并？',
          client: _dio(adapter),
          modelsCatalogReadable: true,
        ),
      );
      expect(
        e.diagnostics!.hint,
        contains('鉴权通过、模型目录可读，422 多半是模型权限/参数/上游限制'),
      );
    });
  });

  group('API Key 只进请求头（item 4）', () {
    test('body 回显 Key → serverMessage/rawBody/异常/栈全脱敏', () async {
      final adapter = _FakeAdapter(
        (o) => _jsonBody(
          {
            'code': 'unauthorized',
            'message': 'invalid key $_testKey',
            'traceId': 'tr-9',
          },
          401,
        ),
      );
      try {
        await JevCloudClient.decide(
          baseUrl: _base,
          apiKey: _testKey,
          model: kJevDefaultModel,
          question: '要不要合并？',
          client: _dio(adapter),
        );
        fail('预期抛 JevException');
      } on JevException catch (e, st) {
        final d = e.diagnostics!;
        expect(d.serverMessage, isNot(contains(_testKey)));
        expect(d.serverMessage, contains('sk_***'));
        expect(d.rawBody, isNot(contains(_testKey)));
        expect(d.rawBody, contains('sk_***'));
        expect(d.toString(), isNot(contains(_testKey)));
        expect(e.message, isNot(contains(_testKey)));
        expect(e.toString(), isNot(contains(_testKey)));
        expect(st.toString(), isNot(contains(_testKey)));
        // 只有请求头允许出现真 Key
        expect(
          adapter.requests.single.headers['Authorization'],
          'Bearer $_testKey',
        );
      }
    });

    test('URL query 里的 Key 既不进请求 URL 也不进 resolvedEndpoint/hint',
        () async {
      final adapter = _FakeAdapter((o) => _jsonBody(_decisionBody(), 200));
      final r = await JevCloudClient.decide(
        baseUrl: 'https://tokenrhythm.studio/v1/decision?api_key=$_testKey',
        apiKey: _testKey,
        model: kJevDefaultModel,
        question: '要不要合并？',
        client: _dio(adapter),
      );
      // query 在归一化时被丢弃：请求 URL 本身也不带 Key
      expect(
        adapter.requests.single.uri.toString(),
        'https://tokenrhythm.studio/v1/decision',
      );
      expect(
        r.diagnostics.resolvedEndpoint,
        'https://tokenrhythm.studio/v1/decision',
      );
      expect(r.diagnostics.resolvedEndpoint, isNot(contains(_testKey)));
      expect(r.diagnostics.hint, isNotNull);
      expect(r.diagnostics.hint, contains('query/fragment'));
      expect(r.diagnostics.hint, isNot(contains(_testKey)));
      expect(r.diagnostics.toString(), isNot(contains(_testKey)));
    });

    test('rawBody 截到 ≤2KB 且按 UTF-8 边界截断', () async {
      final adapter = _FakeAdapter(
        (o) => _jsonBody({
          'code': 'too_long',
          'message': '超长' * 1200,
        }, 422),
      );
      final e = await _decideExpectError(adapter);
      final raw = e.diagnostics!.rawBody;
      expect(utf8.encode(raw).length,
          lessThanOrEqualTo(JevCloudClient.rawBodyLimit));
      expect(raw, endsWith('…'));
      expect(utf8.decode(utf8.encode(raw)), raw, reason: '不许截出半个汉字');
    });

    test('无 Key 时本地拦截、不发请求、Key 不参与任何拼装', () async {
      final adapter = _FakeAdapter((o) => fail('无 Key 不许发请求'));
      final e = await _catchJev(
        () => JevCloudClient.decide(
          baseUrl: _base,
          apiKey: '   ',
          model: kJevDefaultModel,
          question: '要不要合并？',
          client: _dio(adapter),
        ),
      );
      expect(adapter.requests, isEmpty);
      expect(e.diagnostics, isNull);
      expect(e.message, contains('API 密钥'));
    });
  });

  group('data 错误同样可诊断（item 4）', () {
    test('200 但不是 JSON 对象 → 报「无法理解」并留 rawBody/hint', () async {
      final e = await _decideExpectError(
        _FakeAdapter((o) => _textBody('not json', 200)),
      );
      expect(e.message, contains('无法理解'));
      expect(e.diagnostics!.httpStatus, 200);
      expect(e.diagnostics!.rawBody, 'not json');
      expect(e.diagnostics!.hint, contains('rawBody'));
    });

    test('200 只给 stop 键（文档陷阱）→ 报没给 noul 且 hint 点出陷阱',
        () async {
      final adapter = _FakeAdapter(
        (o) => _jsonBody({
          'answers': {
            'stop': {'type': 'noul', 'noul': 0.9},
          },
        }, 200),
      );
      final e = await _decideExpectError(adapter);
      expect(e.message, contains('没有给出是非判断'));
      expect(e.diagnostics!.hint, contains('recommend'));
      expect(e.diagnostics!.hint, contains('stop'));
    });

    test('200 缺 answers 字段 → 报错并带诊断', () async {
      final e = await _decideExpectError(
        _FakeAdapter((o) => _jsonBody({'model': kJevDefaultModel}, 200)),
      );
      expect(e.message, contains('answers'));
      expect(e.diagnostics!.httpStatus, 200);
    });

    test('noul 超出 0–1 → clamp（旧行为不变）', () async {
      final adapter = _FakeAdapter(
        (o) => _jsonBody(_decisionBody(noul: 1.7), 200),
      );
      final r = await JevCloudClient.decide(
        baseUrl: _base,
        apiKey: _testKey,
        model: kJevDefaultModel,
        question: '要不要合并？',
        client: _dio(adapter),
      );
      expect(r.yesProb, 1.0);
    });
  });

  group('传输层错误', () {
    test('连接超时 → 人话超时、httpStatus=null、不泄 Key', () async {
      final adapter = _FakeAdapter(
        (o) => throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionTimeout,
          message: 'timeout https://x.example/?key=$_testKey',
          error: 'connect failed $_testKey',
        ),
      );
      final e = await _decideExpectError(adapter);
      expect(e.message, contains('超时'));
      expect(e.diagnostics!.httpStatus, isNull);
      expect(e.diagnostics!.transportError, 'connectionTimeout');
      expect(e.message, isNot(contains(_testKey)));
      expect(e.diagnostics!.toString(), isNot(contains(_testKey)));
    });

    test('连接失败 → 人话连不上', () async {
      final e = await _decideExpectError(
        _FakeAdapter(
          (o) => throw DioException(
            requestOptions: o,
            type: DioExceptionType.connectionError,
          ),
        ),
      );
      expect(e.message, contains('连不上'));
      expect(e.diagnostics!.transportError, 'connectionError');
    });
  });

  group('fetchModels 可诊断（与 decide 同口径）', () {
    test('401 → 抛异常带 diagnostics（不重试、Key 不外泄）', () async {
      final adapter = _FakeAdapter(
        (o) => _jsonBody(
          {'code': 'unauthorized', 'message': 'bad key $_testKey'},
          401,
        ),
      );
      final e = await _catchJev(
        () => JevCloudClient.fetchModels(
          baseUrl: _base,
          apiKey: _testKey,
          client: _dio(adapter),
        ),
      );
      expect(adapter.requests, hasLength(1));
      expect(e.diagnostics!.httpStatus, 401);
      expect(e.diagnostics!.resolvedEndpoint,
          'https://tokenrhythm.studio/v1/models');
      expect(e.message, isNot(contains(_testKey)));
      expect(e.diagnostics!.rawBody, isNot(contains(_testKey)));
    });

    test('空目录 → 报错且 hint 指向 /v1/models', () async {
      final e = await _catchJev(
        () => JevCloudClient.fetchModels(
          baseUrl: _base,
          apiKey: _testKey,
          client: _dio(_FakeAdapter((o) => _jsonBody({'data': []}, 200))),
        ),
      );
      expect(e.message, contains('模型目录是空的'));
      expect(e.diagnostics!.httpStatus, 200);
      expect(e.diagnostics!.hint, contains('/v1/models'));
    });
  });
}
