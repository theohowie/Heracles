// Copyright (C) 2026 The Heracles Authors
//
// **T1-5（2026-10-31）：会话用量持久化 `role:"session_usage"` 汇总行**。
//
// 口径：**本会话累计**（读最后一行汇总再累加，跨 run/重启不丢；旧文件没有
// 该行 ⇒ 从 0 起，不假装有）。字段：
// `{role, runs, turns, reportedTurns, unreportedTurns, cached?, prompt, out,
//   steadyHitRate?, ts}`
// · `cached` 只在**至少一次上报过**缓存时写（从没上报 ⇒ 不写键，不写假 0）；
// · `steadyHitRate` = 最近一场能算出的稳态命中率（null 不写键）；
// · **只在有 turn 时写**（空 run 不写）；
// · 只追加、不改旧行（append-only）。
library;

// ignore: depend_on_referenced_packages
import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/session_store.dart';
import 'package:heracles_backend/heracles_backend.dart';

const String _sid = 's1791611845161';

AppSettings _settings() => AppSettings(
      permission: PermissionMode.fullAccess,
      providers: [
        AppSettings.defaultProviders.first
            .copyWith(apiKey: 'k', enabled: true, isDefault: true),
      ],
    );

/// 带用量的假 client：每个 model 调用返回一条消息（1 轮 run）。
class _FinalClient implements LLMClient {
  _FinalClient({required this.usage});
  final ModelUsage Function() usage;

  ModelMessage _r(ModelConfig mc) => ModelMessage(
        model: mc.model,
        stopReason: 'stop',
        textOutput: '完成。',
        usage: usage(),
      );

  @override
  Future<ModelMessage> generate(List<LLMMessage> messages,
          {List<Tool>? tools,
          ToolChoice? toolChoice,
          required ModelConfig modelConfig,
          bool? jsonOutput,
          dynamic cancelToken}) async =>
      _r(modelConfig);

  @override
  Future<Stream<StreamingMessage>> stream(List<LLMMessage> messages,
          {List<Tool>? tools,
          ToolChoice? toolChoice,
          required ModelConfig modelConfig,
          bool? jsonOutput,
          dynamic cancelToken}) async =>
      Stream<StreamingMessage>.fromIterable(
          [StreamingMessage(modelMessage: _r(modelConfig))]);
}

/// 2 轮 run：call0 工具（用量 u1）→ call1 最终回答（用量 u2）。
class _TwoTurnClient implements LLMClient {
  _TwoTurnClient(this.u1, this.u2);
  final ModelUsage u1;
  final ModelUsage u2;
  int calls = 0;

  ModelMessage _r(ModelConfig mc) {
    final i = calls++;
    if (i == 0) {
      return ModelMessage(
        model: mc.model,
        stopReason: 'tool_calls',
        usage: u1,
        functionCalls: [
          FunctionCall(
            id: 'c1',
            name: 'write_file',
            arguments: '{"path":"a.txt","content":"x"}',
          ),
        ],
      );
    }
    return ModelMessage(
        model: mc.model, stopReason: 'stop', textOutput: '完成。', usage: u2);
  }

  @override
  Future<ModelMessage> generate(List<LLMMessage> messages,
          {List<Tool>? tools,
          ToolChoice? toolChoice,
          required ModelConfig modelConfig,
          bool? jsonOutput,
          dynamic cancelToken}) async =>
      _r(modelConfig);

  @override
  Future<Stream<StreamingMessage>> stream(List<LLMMessage> messages,
          {List<Tool>? tools,
          ToolChoice? toolChoice,
          required ModelConfig modelConfig,
          bool? jsonOutput,
          dynamic cancelToken}) async =>
      Stream<StreamingMessage>.fromIterable(
          [StreamingMessage(modelMessage: _r(modelConfig))]);
}

/// 第一轮就抛错（空 run：没有任何 turn）。
class _ExplodeClient implements LLMClient {
  @override
  Future<ModelMessage> generate(List<LLMMessage> messages,
          {List<Tool>? tools,
          ToolChoice? toolChoice,
          required ModelConfig modelConfig,
          bool? jsonOutput,
          dynamic cancelToken}) async =>
      throw StateError('启动即失败');

  @override
  Future<Stream<StreamingMessage>> stream(List<LLMMessage> messages,
          {List<Tool>? tools,
          ToolChoice? toolChoice,
          required ModelConfig modelConfig,
          bool? jsonOutput,
          dynamic cancelToken}) async =>
      throw StateError('启动即失败');
}

class _Ws implements WorkspaceCapability {
  @override
  Future<CapabilityResult> write(String path, String content) async =>
      CapabilitySuccess('已写入 $path');
  @override
  Future<bool> exists(String path) async => true;
  @override
  Future<CapabilityResult> read(String path,
          {int offset = 1, int limit = 0}) async =>
      const CapabilitySuccess('x');
  @override
  Future<CapabilityResult> edit(
          String path, String oldText, String newText) async =>
      const CapabilitySuccess('已替换');
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilitySuccess('已应用');
  @override
  Future<CapabilityResult> delete(String path,
          {bool recursive = false}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> list(String path,
          {bool recursive = false, int maxEntries = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> mkdir(String path) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> findFiles(String pattern,
          {int maxResults = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> grepFiles(String pattern,
          {String pathFilter = '', int maxResults = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> move(String from, String to) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> copy(String from, String to) async =>
      const CapabilitySuccess('');
}

/// 内存会话文件：rows 在测试之间保留（模拟"重启后读同一个文件"）。
class _FakeStore extends SessionStore {
  _FakeStore() : super(workspaceRoot: '/ws/fake');
  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];

  @override
  Future<String> createSession(String title) async => _sid;
  @override
  Future<void> touchSession(String sessionId) async {}
  @override
  Future<List<Map<String, dynamic>>> loadMessages(
    String sessionId, {
    int limit = SessionStore.defaultRecentLimit,
    int offset = 0,
  }) async =>
      List<Map<String, dynamic>>.of(rows);
  @override
  Future<bool> appendMessage(
      String sessionId, Map<String, dynamic> message) async {
    rows.add(Map<String, dynamic>.from(message));
    return true;
  }

  List<Map<String, dynamic>> get usageRows =>
      rows.where((r) => r['role'] == 'session_usage').toList();
  Map<String, dynamic>? get lastUsage =>
      usageRows.isEmpty ? null : usageRows.last;
}

LocalAgentExecutor _exec({
  required _FakeStore store,
  required LLMClient client,
}) =>
    LocalAgentExecutor(
      workspacePath: '/ws/fake',
      settings: _settings(),
      sessionStore: store,
      clientForTest: client,
      capabilitiesForTest: Capabilities(workspace: _Ws()),
    );

ModelUsage _usage({required int prompt, required int cached, int out = 10}) =>
    ModelUsage(
      promptTokens: prompt,
      completionTokens: out,
      totalTokens: prompt + out,
      cachedToken: cached,
      originalUsage: <String, dynamic>{
        'prompt_tokens': prompt,
        'completion_tokens': out,
        'total_tokens': prompt + out,
        if (cached > 0) 'prompt_tokens_details': <String, dynamic>{'cached_tokens': cached},
      },
    );

/// 未上报缓存的用量（`cachedToken` 缺省 0 + originalUsage 无缓存字段）。
ModelUsage _usageNoCache({int prompt = 100, int out = 10}) => ModelUsage(
      promptTokens: prompt,
      completionTokens: out,
      totalTokens: prompt + out,
      cachedToken: 0,
      originalUsage: <String, dynamic>{
        'prompt_tokens': prompt,
        'completion_tokens': out,
        'total_tokens': prompt + out,
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('★★★ 同会话两场 run ⇒ 末行累计：runs/turns/tokens 递增、steadyHitRate 不写假 0', () async {
    final store = _FakeStore();

    // 第 1 场：1 轮，prompt 100 / cached 50 / out 10（单轮 ⇒ 稳态命中率无）
    await _exec(
      store: store,
      client: _FinalClient(usage: () => _usage(prompt: 100, cached: 50)),
    ).run(request: '第一场', sessionId: _sid).then((h) => h.result);
    var row = store.lastUsage!;
    expect(row['role'], 'session_usage');
    expect(row['runs'], 1);
    expect(row['turns'], 1);
    expect(row['reportedTurns'], 1);
    expect(row['unreportedTurns'], 0);
    expect(row['prompt'], 100);
    expect(row['out'], 10);
    expect(row['cached'], 50);
    expect(row.containsKey('steadyHitRate'), isFalse,
        reason: '★ 只有 1 轮 ⇒ 算不出稳态命中率，不写键（不是 0）');
    expect(row['ts'], isA<int>());

    // 第 2 场：1 轮，prompt 200 / cached 100 / out 20
    await _exec(
      store: store,
      client: _FinalClient(usage: () => _usage(prompt: 200, cached: 100, out: 20)),
    ).run(request: '第二场', sessionId: _sid).then((h) => h.result);
    row = store.lastUsage!;
    expect(store.usageRows, hasLength(2), reason: '每次 run 各追加一行（append-only）');
    expect(row['runs'], 2);
    expect(row['turns'], 2);
    expect(row['prompt'], 300);
    expect(row['out'], 30);
    expect(row['cached'], 150);
    // 旧行不被改写
    expect(store.usageRows.first['runs'], 1);
  });

  test('★★★ 重启后继续累计（新 executor 读同一会话文件的末行）', () async {
    final store = _FakeStore();
    for (var i = 0; i < 2; i++) {
      await _exec(
        store: store,
        client: _FinalClient(usage: () => _usage(prompt: 100, cached: 10)),
      ).run(request: '第$i场', sessionId: _sid).then((h) => h.result);
    }
    // 模拟"杀进程重开"：新建 executor（store 还是同一份文件）
    await _exec(
      store: store,
      client: _FinalClient(usage: () => _usage(prompt: 100, cached: 10)),
    ).run(request: '重开后', sessionId: _sid).then((h) => h.result);

    final row = store.lastUsage!;
    expect(row['runs'], 3);
    expect(row['turns'], 3);
    expect(row['prompt'], 300);
    expect(row['cached'], 30);
  });

  test('★★★ 旧文件没有汇总行 ⇒ 从 0 起（不假装有历史）', () async {
    final store = _FakeStore();
    // 旧格式内容：只有 user/assistant/step，没有任何 session_usage 行
    store.rows.addAll([
      {'role': 'user', 'text': '旧问题', 'ts': 1},
      {'role': 'assistant', 'text': '旧回答', 'prompt': 10, 'out': 2, 'ts': 2},
    ]);
    await _exec(
      store: store,
      client: _FinalClient(usage: () => _usage(prompt: 100, cached: 20)),
    ).run(request: '新任务', sessionId: _sid).then((h) => h.result);

    final row = store.lastUsage!;
    expect(row['runs'], 1, reason: '★ 旧行不计入（旧文件没有可信累计）');
    expect(row['turns'], 1);
    expect(row['prompt'], 100);
    expect(row['cached'], 20);
  });

  test('★★★ 空 run（没开始就失败）⇒ 不写汇总行', () async {
    final store = _FakeStore();
    await _exec(store: store, client: _ExplodeClient())
        .run(request: '空', sessionId: _sid)
        .then((h) => h.result);
    expect(store.usageRows, isEmpty, reason: '★ 没有 turn ⇒ 不写空壳汇总');
  });

  test('★★★ 从没上报缓存 ⇒ **不写 cached 键**（不写假 0）', () async {
    final store = _FakeStore();
    await _exec(
      store: store,
      client: _FinalClient(usage: _usageNoCache),
    ).run(request: '无缓存', sessionId: _sid).then((h) => h.result);

    final row = store.lastUsage!;
    expect(row.containsKey('cached'), isFalse,
        reason: '★ provider 从没上报缓存 ⇒ 不写键（前端显示"不可用"，不是 0）');
    expect(row['turns'], 1);
    expect(row['prompt'], 100);
  });

  test('★★★ steadyHitRate 口径：一场 2 轮 ⇒ 取跳过首轮后的平均（第 2 轮命中率）', () async {
    final store = _FakeStore();
    // 第 1 轮：cached 50/100 = 0.5（冷启动，跳过）；第 2 轮：cached 60/200 = 0.3
    await _exec(
      store: store,
      client: _TwoTurnClient(
        _usage(prompt: 100, cached: 50),
        _usage(prompt: 200, cached: 60),
      ),
    ).run(request: '两轮', sessionId: _sid).then((h) => h.result);

    final row = store.lastUsage!;
    expect(row['turns'], 2);
    expect(row['reportedTurns'], 2);
    expect(row['unreportedTurns'], 0);
    expect(row['steadyHitRate'], closeTo(0.3, 1e-9),
        reason: '★ 稳态口径 = 跳过首轮后的轮次平均（不是 token 加权、不是 0）');
  });

  test('★★ session_store 类型表只增：写入规整 int/double（宽容字符串）', () async {
    final channel = const MethodChannel('heracles/device');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final writes = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'fs.appendText') {
        final args = call.arguments is Map ? call.arguments as Map : const {};
        writes.add(args['text'] as String? ?? '');
        return <String, dynamic>{'ok': true};
      }
      return <String, dynamic>{'ok': true};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final store = SessionStore(workspaceRoot: '/ws/fake');
    // 宽容输入：数字/浮点都用**字符串**（旧数据/手工写过的样子）
    final ok = await store.appendMessage('s1700000000000', <String, dynamic>{
      'role': 'session_usage',
      'runs': '2',
      'turns': '3',
      'reportedTurns': '3',
      'unreportedTurns': '0',
      'cached': '10',
      'prompt': '100',
      'out': '20',
      'steadyHitRate': '0.5',
      'ts': '123',
    });
    expect(ok, isTrue, reason: '写通道可用 ⇒ 追加成功');
    expect(writes, isNotEmpty);
    final row = jsonDecode(writes.last.trim()) as Map<String, dynamic>;
    expect(row['runs'], 2);
    expect(row['turns'], 3);
    expect(row['reportedTurns'], 3);
    expect(row['unreportedTurns'], 0);
    expect(row['cached'], 10);
    expect(row['prompt'], 100);
    expect(row['out'], 20);
    expect(row['ts'], 123);
    expect(row['steadyHitRate'], isA<double>());
    expect(row['steadyHitRate'], 0.5);
  });
}
