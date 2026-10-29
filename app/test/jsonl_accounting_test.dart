// Copyright (C) 2026 The Heracles Authors
//
// **JSONL 记账**（task-6 / `docs/接口.md` §7.2，2026-10-29）：
//
// 1. `role:"step"` 行补 `prompt/cached/out`（仅本轮见到 usage；`cached` 为 null
//    **不写键**，不写假 0）；
// 2. 新增 `role:"approval"` / `role:"ask"` 结果行；
// 3. **顺序**：approval 行必须在该次调用对应的 `tool` 行之前；
// 4. 写入纪律：`LocalAskGate` 只 push 缓冲，`_drive` 是唯一写者
//    （每个事件处理之前 drain + finally 兜底；gate 内绝不 await append）；
// 5. 并发闸（`appendMessage` 并发拒绝）保持不变；旧文件缺这些行照常解析。
library;

// ignore: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/services/agent_bridge.dart' show AgentEvent;
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/session_store.dart';
import 'package:heracles_backend/heracles_backend.dart';

const String _sid = 's1791611845161';

// ============================================================================
// 测试替身
// ============================================================================

/// 脚本 client：第 1 轮问用户 → 第 2 轮跑 shell → 第 3 轮给最终回答。
///
/// 每轮都带 usage（第 1/3 轮 `cachedToken: 0` 且无 originalUsage ⇒ backend
/// 视为"未上报" ⇒ cachedTokens=null），用来钉"cached 为 null 不写键"。
class _ScriptedClient implements LLMClient {
  int calls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      _reply(modelConfig);

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      Stream<StreamingMessage>.fromIterable([
        StreamingMessage(modelMessage: _reply(modelConfig)),
      ]);

  ModelMessage _reply(ModelConfig mc) {
    calls++;
    switch (calls) {
      case 1:
        return ModelMessage(
          model: mc.model,
          stopReason: 'tool_calls',
          usage: ModelUsage(
            promptTokens: 100,
            completionTokens: 5,
            totalTokens: 105,
            cachedToken: 40,
          ),
          functionCalls: [
            FunctionCall(
              id: 'a1',
              name: 'ask_user',
              arguments: jsonEncode({
                'questions': [
                  {
                    'question': '选哪个？',
                    'options': ['A', 'B'],
                  },
                ],
              }),
            ),
          ],
        );
      case 2:
        return ModelMessage(
          model: mc.model,
          stopReason: 'tool_calls',
          usage: ModelUsage(
            promptTokens: 200,
            completionTokens: 6,
            totalTokens: 206,
            cachedToken: 40,
          ),
          functionCalls: [
            FunctionCall(
              id: 'c1',
              name: 'run_shell_command',
              arguments: jsonEncode({'command': 'echo hi'}),
            ),
          ],
        );
      default:
        return ModelMessage(
          textOutput: '完成。',
          model: mc.model,
          stopReason: 'stop',
          usage: ModelUsage(
            promptTokens: 300,
            completionTokens: 7,
            totalTokens: 307,
          ),
        );
    }
  }
}

class _FakeShell implements ShellCapability {
  final List<String> ran = [];

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    ran.add(command);
    return const CapabilitySuccess(
      '【命令输出开始】\nhi\n【命令输出结束】',
      metadata: {'exitCode': 0, 'timedOut': false},
    );
  }
}

/// 内存版会话存储：`_drive` 的所有落盘都记进 [rows]（顺序 = 写入顺序）。
class _FakeSessionStore extends SessionStore {
  _FakeSessionStore() : super(workspaceRoot: '/ws/fake');

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
      const <Map<String, dynamic>>[];

  @override
  Future<bool> appendMessage(
    String sessionId,
    Map<String, dynamic> message,
  ) async {
    rows.add(Map<String, dynamic>.from(message));
    return true;
  }
}

LocalAgentExecutor _executor({
  required _FakeSessionStore store,
  required _ScriptedClient client,
  required LocalAskGate gate,
}) =>
    LocalAgentExecutor(
      workspacePath: '/ws/fake',
      settings: AppSettings(
        permission: PermissionMode.manual,
        providers: [
          AppSettings.defaultProviders.first
              .copyWith(apiKey: 'test-key', enabled: true, isDefault: true),
        ],
      ),
      sessionStore: store,
      askGate: gate,
      clientForTest: client,
      capabilitiesForTest: Capabilities(shell: _FakeShell()),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // ① step 行 usage（纯函数）
  // ---------------------------------------------------------------------------
  group('step 行 usage 字段', () {
    Map<String, dynamic> step({
      required bool seen,
      int? cached,
    }) =>
        buildStepRow(
          stepId: 'turn-1',
          title: '本轮输出',
          turn: 1,
          think: '',
          text: 'hi',
          stage: 'ok',
          ms: 12,
          ts: 100,
          usageSeen: seen,
          prompt: 100,
          cached: cached,
          output: 5,
        );

    test('① 见到 usage ⇒ prompt/cached/out 三键齐；旧形状不变', () {
      final row = step(seen: true, cached: 40);
      expect(row['prompt'], 100);
      expect(row['cached'], 40);
      expect(row['out'], 5);
      expect(row['role'], 'step');
      expect(row['stepId'], 'turn-1');
      expect(row['i'], 1);
      expect(row['stage'], 'ok');
      expect(row['ts'], 100);
    });

    test('② cached 为 null ⇒ **不写 cached 键**（不写假 0）', () {
      final row = step(seen: true, cached: null);
      expect(row.containsKey('cached'), isFalse,
          reason: '★ 没上报缓存 ≠ 命中 0；写 0 会让历史回放把"没数据"画成"一次没命中"');
      expect(row['prompt'], 100);
      expect(row['out'], 5);
    });

    test('③ 没见过 usage ⇒ 三个键都不写（不凭空造数）', () {
      final row = step(seen: false, cached: 40);
      expect(row.containsKey('prompt'), isFalse);
      expect(row.containsKey('cached'), isFalse);
      expect(row.containsKey('out'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // ② LocalAskGate：只 push 缓冲（审批五路径 + 提问三态 + 不重复）
  // ---------------------------------------------------------------------------
  group('LocalAskGate 决策缓冲', () {
    LocalAskGate gateWith(List<AgentEvent> events, {int timeoutMs = 5000}) {
      final gate = LocalAskGate(
        approvalTimeout: Duration(milliseconds: timeoutMs),
        answerTimeout: Duration(milliseconds: timeoutMs),
      );
      gate.attach(events.add);
      return gate;
    }

    Future<Map<String, dynamic>> oneRow(LocalAskGate gate) async {
      final rows = gate.takeJournal();
      expect(rows, hasLength(1), reason: '每条决定只能 push 一次');
      return rows.single;
    }

    Future<bool> askApproval(
      LocalAskGate gate, {
      String callId = 'c1',
      String tool = 'run_shell_command',
    }) =>
        gate.requestApproval(
          callId: callId,
          toolName: tool,
          args: const {'command': 'echo hi'},
          risk: '在沙箱中执行任意 shell 命令',
          detail: 'echo hi',
          workspaceInside: false,
        );

    test('① 白名单命中 ⇒ 自动放行，记 always/auto_allowed', () async {
      final gate = gateWith(<AgentEvent>[])..seedAllowed(['run_shell_command']);
      expect(await askApproval(gate), isTrue);
      final row = await oneRow(gate);
      expect(row['role'], 'approval');
      expect(row['decision'], 'always');
      expect(row['outcome'], 'auto_allowed');
      expect(row['tool'], 'run_shell_command');
      expect(row['callId'], 'c1');
      expect(row['ts'], isA<int>());
    });

    test('② once ⇒ allowed；③ always ⇒ allowed 且写入白名单', () async {
      final gate = gateWith(<AgentEvent>[]);
      final fOnce = askApproval(gate);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await gate.replyApproval(callId: 'c1', decision: 'once'), isTrue);
      expect(await fOnce, isTrue);
      expect((await oneRow(gate))['decision'], 'once');

      final fAlways = askApproval(gate, callId: 'c2');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(
          await gate.replyApproval(callId: 'c2', decision: 'always'), isTrue);
      expect(await fAlways, isTrue);
      final row = await oneRow(gate);
      expect(row['decision'], 'always');
      expect(row['outcome'], 'allowed');

      // 后续同工具调用自动放行（白名单生效）
      expect(await askApproval(gate, callId: 'c3'), isTrue);
      expect((await oneRow(gate))['outcome'], 'auto_allowed');
    });

    test('③b deny ⇒ denied；④ 超时 ⇒ timeout（fail-closed）', () async {
      final gate = gateWith(<AgentEvent>[]);
      final fDeny = askApproval(gate, callId: 'd1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await gate.replyApproval(callId: 'd1', decision: 'deny'), isTrue);
      expect(await fDeny, isFalse);
      final denyRow = await oneRow(gate);
      expect(denyRow['decision'], 'deny');
      expect(denyRow['outcome'], 'denied');

      final short = gateWith(<AgentEvent>[], timeoutMs: 30);
      expect(await askApproval(short, callId: 't1'), isFalse);
      final timeoutRow = await oneRow(short);
      expect(timeoutRow['decision'], 'deny');
      expect(timeoutRow['outcome'], 'timeout');
    });

    test('⑤ 取消（abort）⇒ cancelled；无 UI ⇒ denied（fail-closed）', () async {
      final gate = gateWith(<AgentEvent>[]);
      final fCancel = askApproval(gate, callId: 'x1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      gate.abort();
      expect(await fCancel, isFalse);
      final cancelRow = await oneRow(gate);
      expect(cancelRow['decision'], 'deny');
      expect(cancelRow['outcome'], 'cancelled');

      final noUi = LocalAskGate(); // 没 attach ⇒ 没 UI 出口
      expect(await askApproval(noUi, callId: 'n1'), isFalse);
      final noUiRow = await oneRow(noUi);
      expect(noUiRow['outcome'], 'denied',
          reason: '没 UI 也必须记账（fail-closed 的拒绝是一次真实决策）');
    });

    test('⑥ 旧口径 allow / allow_always 归一成 once / always', () async {
      final gate = gateWith(<AgentEvent>[]);
      final f = askApproval(gate, callId: 'o1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await gate.replyApproval(callId: 'o1', decision: 'allow'), isTrue);
      expect(await f, isTrue);
      expect((await oneRow(gate))['decision'], 'once',
          reason: '落盘统一 once/always/deny（INTERFACE §6）');

      final f2 = askApproval(gate, callId: 'o2');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await gate.replyApproval(callId: 'o2', decision: 'allow_always'),
          isTrue);
      expect(await f2, isTrue);
      expect((await oneRow(gate))['decision'], 'always');
    });

    test('⑦ 提问三态：answered / timeout / cancelled', () async {
      const questions = [
        AskQuestion(id: 'q1', question: '选哪个？', multi: false, options: []),
      ];

      final gate = gateWith(<AgentEvent>[]);
      final fAsked = gate.askUser(questions);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(gate.hasPendingAsk, isTrue);
      expect(await gate.replyAsk({'q1': ['A']}), isTrue);
      expect(await fAsked, contains('A'));
      final answered = await oneRow(gate);
      expect(answered['role'], 'ask');
      expect(answered['outcome'], 'answered');
      expect((answered['answers'] as Map)['q1'], ['A']);

      final timedOut =
          gateWith(<AgentEvent>[], timeoutMs: 30);
      expect(await timedOut.askUser(questions), isNull);
      final timeoutRow = await oneRow(timedOut);
      expect(timeoutRow['outcome'], 'timeout');
      expect(timeoutRow['answers'], isEmpty);

      final cancelled = gateWith(<AgentEvent>[]);
      final fCancel = cancelled.askUser(questions);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cancelled.abort();
      expect(await fCancel, isNull);
      expect((await oneRow(cancelled))['outcome'], 'cancelled');
    });
  });

  // ---------------------------------------------------------------------------
  // ③ _drive 端到端：3 轮 + 提问 + 审批 ⇒ 行顺序与数值
  // ---------------------------------------------------------------------------
  test('★★★ 3 轮 run（问用户→跑 shell→最终回答）：step usage / ask / approval 顺序', () async {
    final store = _FakeSessionStore();
    final gate = LocalAskGate();
    final client = _ScriptedClient();
    final executor = _executor(store: store, client: client, gate: gate);

    final handle = await executor.run(request: '帮我选一个再跑个命令', sessionId: _sid);

    var done = false;
    // 驱动器：看到挂起就自动作答（模拟 UI 点按），直到 run 结束。
    final watcher = () async {
      while (!done) {
        if (gate.hasPendingAsk) {
          await gate.replyAsk({'q1': ['A']});
        }
        if (gate.hasPendingApproval) {
          final id = gate.pendingApprovalCallId;
          if (id != null) {
            await gate.replyApproval(callId: id, decision: 'once');
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }();

    final result = await handle.result;
    done = true;
    await watcher;

    final stepRows = store.rows.where((r) => r['role'] == 'step').toList();
    // 轮 1（问用户）与轮 3（最终回答）有正文步骤 ⇒ 2 行 step；
    // 轮 2（纯 shell 调用、模型一句话没说）走本地补摘要逻辑，不必有 step 行。
    expect(stepRows, hasLength(2),
        reason: '有正文的轮次必须落 step 行（旧行为不变）');
    for (final row in stepRows) {
      expect(row.containsKey('prompt'), isTrue,
          reason: '★ 每轮都见到 usage ⇒ step 行必须带 prompt');
      expect(row.containsKey('out'), isTrue);
    }
    // cached 只有第 1 轮报了（40）；第 3 轮没上报 ⇒ 不写键
    final withCached =
        stepRows.where((r) => r.containsKey('cached')).toList();
    expect(withCached, hasLength(1));
    expect(withCached.single['cached'], 40);

    // step usage 与 turnRecords 数值一致（同源，不许各算各的）
    for (final row in stepRows) {
      final prompt = row['prompt'] as int;
      final out = row['out'] as int;
      final matched = result.turns.where(
          (t) => t.promptTokens == prompt && t.outputTokens == out);
      expect(matched, isNotEmpty,
          reason: '★ step 行 usage($prompt/$out) 必须与某条 AgentTurn 完全相等');
      expect(row['cached'], matched.first.cachedTokens,
          reason: 'cached 键只在有值时出现，且必须等于 turnRecord 的值');
    }

    // 提问行
    final askRows = store.rows.where((r) => r['role'] == 'ask').toList();
    expect(askRows, hasLength(1));
    expect(askRows.single['outcome'], 'answered');
    expect((askRows.single['answers'] as Map)['q1'], ['A']);

    // 审批行：once/allowed，且**必须在该次调用的 tool 行之前**
    final approvalRows =
        store.rows.where((r) => r['role'] == 'approval').toList();
    expect(approvalRows, hasLength(1));
    expect(approvalRows.single['decision'], 'once');
    expect(approvalRows.single['outcome'], 'allowed');
    expect(approvalRows.single['tool'], 'run_shell_command');

    final approvalIndex = store.rows.indexOf(approvalRows.single);
    final shellToolIndex = store.rows.indexWhere(
        (r) => r['role'] == 'tool' && r['tool'] == 'run_shell_command');
    expect(shellToolIndex, greaterThanOrEqualTo(0));
    expect(approvalIndex, lessThan(shellToolIndex),
        reason: '★ 决策先于执行结果：approval 行必须在对应 tool 行之前');

    // 旧形状仍在
    expect(store.rows.first['role'], 'user');
    expect(store.rows.last['role'], 'assistant');
  });

  // ---------------------------------------------------------------------------
  // ④ 并发闸不变：同会话并发 append 仍被拒绝
  // ---------------------------------------------------------------------------
  test('★★ 同一会话并发 appendMessage 仍被拒绝（并发闸不变）', () async {
    final store = SessionStore(workspaceRoot: '/ws/none');
    // 第一次调用同步置 _appending=true 后挂起在通道调用上；
    // 第二次在它返回前进来 ⇒ 必须如实失败。
    final first = store.appendMessage(_sid, {'role': 'user', 'text': 'a'});
    final second = await store.appendMessage(_sid, {'role': 'user', 'text': 'b'});
    expect(second, isFalse);
    expect(store.lastError, contains('并发'));
    await first; // 收尾（无通道实现 ⇒ 会走失败路径，但不应抛）
  });
}
