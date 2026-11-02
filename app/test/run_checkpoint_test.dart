// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 长任务续跑：checkpoint 落盘 + 续跑不伪造用户消息 + 恢复读取**。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | 一次正常 run ⇒ 追加 `role:"run_checkpoint"` 行（字段齐全） | checkpoint 没落盘 ⇒ 进程被杀后无从恢复 |
// | ② | checkpoint 在 assistant 行**之前** | 重放顺序错（先回答后进度） |
// | ③ | 用户只发一次消息 ⇒ 只有一条 user 行（续跑不伪造） | 伪造用户消息（历史被污染/回放骗人） |
// | ④ | `lastCheckpointForTest` 取**最后一条**；旧文件无 ⇒ 空 | 恢复读到旧进度 / 空文件崩 |
// | ⑤ | 续跑说明走 system 提示（不是 user 文本） | 把系统说明当用户说的话 |
library;

// ignore: depend_on_referenced_packages
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/session_store.dart';
import 'package:heracles_backend/heracles_backend.dart';

const String _sid = 's1793000000000';

AppSettings _settings() => AppSettings(
      permission: PermissionMode.fullAccess,
      providers: [
        AppSettings.defaultProviders.first
            .copyWith(apiKey: 'k', enabled: true, isDefault: true),
      ],
    );

class _OneTurnClient implements LLMClient {
  ModelMessage _r(ModelConfig mc) => ModelMessage(
        model: mc.model,
        stopReason: 'stop',
        textOutput: '完成。',
        usage: ModelUsage(
          promptTokens: 100,
          completionTokens: 10,
          totalTokens: 110,
          cachedToken: 0,
          originalUsage: <String, dynamic>{
            'prompt_tokens': 100,
            'completion_tokens': 10,
            'total_tokens': 110,
          },
        ),
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

class _Ws extends WorkspaceCapability {
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
  Future<CapabilityResult> edit(String path, String oldText, String newText) async =>
      const CapabilitySuccess('已替换');
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async =>
      const CapabilitySuccess('已应用');
  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> list(String path,
          {bool recursive = false, int maxEntries = 200}) async =>
      const CapabilitySuccess('');
  @override
  Future<CapabilityResult> mkdir(String path) async => const CapabilitySuccess('');
  @override
  Future<CapabilityResult> findFiles(String pattern, {int maxResults = 200}) async =>
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

  List<Map<String, dynamic>> get checkpoints =>
      rows.where((r) => r['role'] == ContractRunContinue.checkpointRole).toList();
  List<Map<String, dynamic>> get userRows =>
      rows.where((r) => r['role'] == 'user').toList();
}

LocalAgentExecutor _exec({required _FakeStore store, required LLMClient client}) =>
    LocalAgentExecutor(
      workspacePath: '/ws/fake',
      settings: _settings(),
      sessionStore: store,
      clientForTest: client,
      capabilitiesForTest: Capabilities(workspace: _Ws()),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('① 正常 run ⇒ 追加 run_checkpoint 行（字段齐全，值不编）', () async {
    final store = _FakeStore();
    await _exec(store: store, client: _OneTurnClient())
        .run(request: '做个任务', sessionId: _sid)
        .then((h) => h.result);

    expect(store.checkpoints, hasLength(1), reason: '每轮结束写一条 checkpoint');
    final cp = store.checkpoints.single;
    expect(cp['sessionId'], _sid);
    expect(cp['round'], isA<int>());
    expect(cp['round'], greaterThanOrEqualTo(1));
    expect(cp['toolCalls'], isA<int>());
    expect(cp['tokens'], isA<int>());
    expect(cp['tokens'], greaterThan(0));
    expect(cp['lastMessage'], isA<String>());
    expect(cp['ts'], isA<int>());
    expect(cp['progressSnapshot'], isA<Map>());
  });

  test('② checkpoint 在 assistant 行之前（重放顺序）', () async {
    final store = _FakeStore();
    await _exec(store: store, client: _OneTurnClient())
        .run(request: '做个任务', sessionId: _sid)
        .then((h) => h.result);
    final cpIdx = store.rows.indexWhere(
        (r) => r['role'] == ContractRunContinue.checkpointRole);
    final asstIdx = store.rows.indexWhere((r) => r['role'] == 'assistant');
    expect(cpIdx, greaterThanOrEqualTo(0));
    expect(asstIdx, greaterThan(cpIdx),
        reason: '★ checkpoint 必须在 assistant 之前（先进度、后回答）');
  });

  test('③ 用户只发一次消息 ⇒ 只有一条 user 行（续跑不伪造）', () async {
    final store = _FakeStore();
    await _exec(store: store, client: _OneTurnClient())
        .run(request: '做个任务', sessionId: _sid)
        .then((h) => h.result);
    expect(store.userRows, hasLength(1),
        reason: '★ 续跑/自动续跑不得额外写 user 行（否则历史被伪造）');
    expect(store.userRows.single['text'], '做个任务');
  });

  test('④ 恢复：读最后一条 checkpoint；无 checkpoint ⇒ 空 Map', () async {
    final store = _FakeStore();
    store.rows.addAll([
      {'role': 'user', 'text': '旧', 'ts': 1},
      {'role': 'assistant', 'text': '旧答', 'ts': 2},
    ]);
    final cp = await _exec(store: store, client: _OneTurnClient())
        .lastCheckpointForTest(_sid);
    expect(cp, isEmpty, reason: '旧文件没有 checkpoint ⇒ 空（行为与无恢复功能一致）');

    store.rows.addAll([
      {'role': ContractRunContinue.checkpointRole, 'round': 1, 'ts': 3},
      {'role': ContractRunContinue.checkpointRole, 'round': 2, 'ts': 4},
    ]);
    final last = await _exec(store: store, client: _OneTurnClient())
        .lastCheckpointForTest(_sid);
    expect(last['round'], 2, reason: '★ 必须取最后一条（否则恢复到旧进度）');
  });

  test('⑤ 续跑说明走 system 提示（不是 user 文本）', () {
    final note = LocalAgentExecutor.continuationNoteForTest(2);
    expect(note, contains('自动续跑第 2 轮'));
    expect(note, contains('不要重复已完成的工作'));
  });
}
