// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **B3（P1）：JEV 理由补写默认关闭 / 旧存档不复活**（2026-10-30）。
//
// 规格（task-17）：
//   · `JevConfig.reasonEnabled` 默认 false；`fromJson` **忽略旧值**强制 false；
//   · `JevController.ask` **不再调用 `JevReasoner`**（零调用由
//     `JevReasoner.debugInvocations` 钉住）；
//   · 决策的 reason 只可能来自决策模型自己的 `thought`，否则为空；
//   · 旧存档（存着 `reasonEnabled:true` / 带旧理由的记录）不得复活行为、
//     也不得被改写理由。
//
// HTTP 用 Dio 假适配器注入（`JevController.ask(client:)`），不真连网。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/services/jev_service.dart';
import 'package:heracles/services/settings_controller.dart';

import 'support/secure_storage_mock.dart';

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

Map<String, Object?> _decisionBody({double noul = 0.9, String? thought}) {
  final answer = <String, Object?>{'type': 'noul', 'noul': noul};
  if (thought != null) answer['thought'] = thought;
  return {
    'model': 'NeoHorse-Jev-4B',
    'answers': {
      'recommend': answer,
    },
  };
}

ResponseBody _json(Object? body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    'content-type': ['application/json'],
  },
);

const String _testKey = 'sk-test-REASON-12345';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    installSecureStorageMock();
    SharedPreferences.setMockInitialValues({});
  });

  group('B3 配置：reasonEnabled 默认 false，旧存档忽略', () {
    test('默认配置理由关闭', () {
      expect(const JevConfig().reasonEnabled, isFalse);
      expect(
        const JevConfig(source: JevSource.cloud, reasonEnabled: false)
            .reasonEnabled,
        isFalse,
      );
    });

    test('fromJson 忽略旧存档里的 true（字段保留，行为不复活）', () {
      final old = JevConfig.fromJson(const {
        'source': 'cloud',
        'cloudBaseUrl': 'https://tokenrhythm.studio/v1',
        'cloudModel': 'NeoHorse-Jev-4B',
        'reasonEnabled': true,
      });
      expect(old.cloudBaseUrl, 'https://tokenrhythm.studio/v1');
      expect(old.cloudModel, 'NeoHorse-Jev-4B');
      expect(old.reasonEnabled, isFalse, reason: '旧存档的 true 必须被忽略');
    });

    test('toJson 落盘写 false（下次读回仍是关闭）', () {
      final json = const JevConfig(reasonEnabled: true).toJson();
      expect(json['reasonEnabled'], isFalse);
      expect(JevConfig.fromJson(json).reasonEnabled, isFalse);
    });
  });

  group('B3 ask()：JevReasoner 零调用', () {
    late AppSettings settings;

    setUp(() async {
      // 老配置：reasonEnabled=true + 云端地址/模型齐全 —— 旧实现会去补写理由
      await JevStore.saveConfig(
        const JevConfig(
          cloudBaseUrl: 'https://tokenrhythm.studio/v1',
          cloudModel: 'NeoHorse-Jev-4B',
          reasonEnabled: true,
        ),
      );
      await JevStore.writeCloudKey(_testKey);
      settings = (await SettingsController.load()).value;
    });

    setUp(() {
      final jev = JevController.shared();
      jev.config = const JevConfig();
      jev.history = const [];
      jev.busy = false;
      jev.lastError = null;
      jev.lastDiagnostics = null;
      JevReasoner.debugInvocations = 0;
    });

    test('旧 reasonEnabled=true 也不补写理由，reason 为空 + 零调用', () async {
      final adapter = _FakeAdapter((o) => _json(_decisionBody()));
      final jev = JevController.shared();
      final decision = await jev.ask(
        '要不要把功能合并进主分支？',
        settings,
        client: _dio(adapter),
      );
      expect(decision, isNotNull);
      expect(decision!.reason, isNull, reason: 'B3：不再由对话模型补写理由');
      expect(decision.reasonSource, JevReasonSource.none);
      expect(JevReasoner.debugInvocations, 0, reason: 'JevReasoner 必须零调用');
      // 云端决走了归一化后的 /v1/decision
      expect(
        adapter.requests.single.uri.toString(),
        'https://tokenrhythm.studio/v1/decision',
      );
    });

    test('决策模型自己的 thought 仍采用（不是补写，不调用 reasoner）', () async {
      final adapter = _FakeAdapter(
        (o) => _json(_decisionBody(noul: 0.8, thought: '  先验证再合并  ')),
      );
      final jev = JevController.shared();
      final decision = await jev.ask('要不要合并？', settings, client: _dio(adapter));
      expect(decision!.reason, '先验证再合并');
      expect(decision.reasonSource, JevReasonSource.modelThought);
      expect(JevReasoner.debugInvocations, 0);
    });

    test('旧存档里有旧理由：新决策不补写、旧记录不被改写', () async {
      // 旧存档：一条带理由的历史（当时 reasonEnabled=true 留下的）
      final oldDecision = JevDecision(
        id: 'j-old',
        question: '旧问题',
        yesProb: 0.22,
        engineLabel: '云端',
        elapsedMs: 500,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        reason: '旧理由：先合测试分支',
        reasonSource: JevReasonSource.llm,
      );
      await JevStore.saveHistory([oldDecision]);

      final jev = JevController.shared();
      jev.history = await JevStore.loadHistory();
      final adapter = _FakeAdapter((o) => _json(_decisionBody()));
      final fresh = await jev.ask('新问题', settings, client: _dio(adapter));
      expect(fresh!.reason, isNull);
      expect(JevReasoner.debugInvocations, 0);

      // 落盘检查：新记录 first、reason 为空；旧记录理由原样保留
      final persisted = await JevStore.loadHistory();
      expect(persisted, hasLength(2));
      expect(persisted.first.question, '新问题');
      expect(persisted.first.reason, isNull);
      expect(persisted.last.id, 'j-old');
      expect(persisted.last.reason, '旧理由：先合测试分支');
      expect(persisted.last.reasonSource, JevReasonSource.llm);
    });

    test('JevDecision.fromJson 旧记录理由原样读回（不删旧数据）', () {
      final back = JevDecision.fromJson(const {
        'id': 'j1',
        'question': 'q',
        'yesProb': 0.7,
        'engineLabel': '云端',
        'elapsedMs': 10,
        'createdAt': 5,
        'reason': '旧理由',
        'reasonSource': 'llm',
      });
      expect(back.reason, '旧理由');
      expect(back.reasonSource, JevReasonSource.llm);
    });
  });
}
