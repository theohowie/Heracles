// Copyright (C) 2026 The Heracles Authors
//
// **B8 P0（2026-10-30）：计划终态落盘** —— `role:"plan"` 行只增
// `reachedGoal` / `closedReason`，收尾时追加一条**最终 plan 行**。
//
// ============================================================================
// 规格
// ============================================================================
// · 成功（计划全部 done/cancelled）⇒ 最终 plan 行 `reachedGoal:true`、无
//   `closedReason` 键；同时向 UI 发 `plan_closed{true, reason:null}`；
// · 取消 ⇒ `reachedGoal:false` + `closedReason:"用户停止"`；
// · 失败 ⇒ `reachedGoal:false` + `closedReason` 含"运行失败"；
// · 无计划 ⇒ **没有** plan 行、也**没有** plan_closed 事件；
// · 顺序：最终 plan 行在 assistant 行**之前**（与旧版"plan 行都在 assistant
//   之前"一致）；plan_closed 事件先于 finished/failed（backend 已测）。
// · 旧行（无这两个键）恢复时按 null，不炸。
library;

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

  /// 最后一次 plan 行。
  Map<String, dynamic>? get lastPlanRow {
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i]['role'] == 'plan') return rows[i];
    }
    return null;
  }

  int get lastPlanIndex => rows.lastIndexWhere((r) => r['role'] == 'plan');
  int get assistantIndex => rows.lastIndexWhere((r) => r['role'] == 'assistant');
}

class _FakeShell implements ShellCapability {
  _FakeShell({this.delay = Duration.zero});

  final Duration delay;
  final List<String> ran = <String>[];

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    ran.add(command);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return const CapabilitySuccess('ok',
        metadata: <String, dynamic>{'exitCode': 0});
  }
}

ModelMessage _tool(ModelConfig mc, String name, String args, int id) =>
    ModelMessage(
      model: mc.model,
      stopReason: 'tool_calls',
      functionCalls: [FunctionCall(id: 'c$id', name: name, arguments: args)],
    );

const _todosDone =
    '{"todos":[{"description":"步骤一","status":"completed"},'
    '{"description":"步骤二","status":"completed"}]}';
const _todosPending =
    '{"todos":[{"description":"步骤一","status":"pending"},'
    '{"description":"步骤二","status":"pending"}]}';

/// 成功：列"已完成"计划 → 最终回答。
class _SuccessClient implements LLMClient {
  int calls = 0;

  ModelMessage _r(ModelConfig mc) {
    final i = calls++;
    if (i == 0) return _tool(mc, 'write_todos', _todosDone, i);
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
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

/// 取消：列未完成计划 → 慢 shell（测试在它跑的时候 cancel）→ 收尾。
class _CancelClient implements LLMClient {
  int calls = 0;

  ModelMessage _r(ModelConfig mc) {
    final i = calls++;
    if (i == 0) return _tool(mc, 'write_todos', _todosPending, i);
    if (i == 1) {
      return _tool(mc, 'run_shell_command', '{"command":"slow"}', i);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
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

/// 失败：列计划 → 抛错。
class _FailClient implements LLMClient {
  int calls = 0;

  ModelMessage _r(ModelConfig mc) {
    final i = calls++;
    if (i == 0) return _tool(mc, 'write_todos', _todosPending, i);
    throw StateError('模拟失败');
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

/// 无计划：直接回答。
class _NoPlanClient implements LLMClient {
  @override
  Future<ModelMessage> generate(List<LLMMessage> messages,
          {List<Tool>? tools,
          ToolChoice? toolChoice,
          required ModelConfig modelConfig,
          bool? jsonOutput,
          dynamic cancelToken}) async =>
      ModelMessage(textOutput: '直接答。', model: modelConfig.model, stopReason: 'stop');

  @override
  Future<Stream<StreamingMessage>> stream(List<LLMMessage> messages,
          {List<Tool>? tools,
          ToolChoice? toolChoice,
          required ModelConfig modelConfig,
          bool? jsonOutput,
          dynamic cancelToken}) async =>
      Stream<StreamingMessage>.fromIterable([
        StreamingMessage(
            modelMessage: ModelMessage(
                textOutput: '直接答。',
                model: modelConfig.model,
                stopReason: 'stop')),
      ]);
}

// ============================================================================
// 公共装配
// ============================================================================

AppSettings _settings() => AppSettings(
      permission: PermissionMode.fullAccess,
      providers: [
        AppSettings.defaultProviders.first
            .copyWith(apiKey: 'k', enabled: true, isDefault: true),
      ],
    );

LocalAgentExecutor _executor({
  required _FakeSessionStore store,
  required LLMClient client,
  Capabilities caps = const Capabilities(),
}) =>
    LocalAgentExecutor(
      workspacePath: '/ws/fake',
      settings: _settings(),
      sessionStore: store,
      clientForTest: client,
      capabilitiesForTest: caps,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('★★★ 成功 ⇒ 最终 plan 行 reachedGoal=true（无 closedReason），且在 assistant 之前', () async {
    final store = _FakeSessionStore();
    final events = <AgentEvent>[];
    final handle = await _executor(store: store, client: _SuccessClient()).run(
      request: '任务',
      sessionId: _sid,
    );
    final sub = handle.events.listen(events.add);
    await handle.result;
    await sub.cancel();

    final plan = store.lastPlanRow;
    expect(plan, isNotNull, reason: '有计划就必须有 plan 行');
    expect(plan!['reachedGoal'], isTrue);
    expect(plan.containsKey('closedReason'), isFalse,
        reason: '达成时不该写 closedReason（null 语义 = 未写键）');
    expect(store.lastPlanIndex, lessThan(store.assistantIndex),
        reason: '★ 最终 plan 行在 assistant 行之前（与旧顺序一致）');

    // plan_closed 事件：恰一次、reachedGoal=true、reason=null
    final closed = events.where((e) => e.type == AgentEvent.kPlanClosed).toList();
    expect(closed, hasLength(1));
    expect(closed.single.reachedGoal, isTrue);
    expect(closed.single.planClosedReason, isNull);
    // 事件顺序：plan_closed 先于 finished（AgentEvent.kFinished）
    final iClosed = events.indexWhere((e) => e.type == AgentEvent.kPlanClosed);
    final iFinished =
        events.indexWhere((e) => e.type == AgentEvent.kFinished);
    expect(iFinished, greaterThanOrEqualTo(0));
    expect(iClosed, lessThan(iFinished));
  });

  test('★★★ 取消 ⇒ 最终 plan 行 reachedGoal=false + closedReason="用户停止"', () async {
    final store = _FakeSessionStore();
    final shell = _FakeShell(delay: const Duration(milliseconds: 300));
    final events = <AgentEvent>[];
    final handle = await _executor(
      store: store,
      client: _CancelClient(),
      caps: Capabilities(shell: shell),
    ).run(request: '任务', sessionId: _sid);
    final sub = handle.events.listen(events.add);
    // 等计划行落盘（说明已进入工具轮），再点停止。
    for (var i = 0; i < 200 && store.lastPlanRow == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(store.lastPlanRow, isNotNull, reason: '取消前应已有计划行');
    await handle.cancel();
    await handle.result;
    await sub.cancel();

    final plan = store.lastPlanRow;
    expect(plan!['reachedGoal'], isFalse);
    expect(plan['closedReason'], '用户停止',
        reason: '★ 取消的人话落盘（重开后会显示"已中断：用户停止"）');

    final closed = events.where((e) => e.type == AgentEvent.kPlanClosed).toList();
    expect(closed, hasLength(1));
    expect(closed.single.reachedGoal, isFalse);
    expect(closed.single.planClosedReason, '用户停止');
  });

  test('★★★ 失败 ⇒ 最终 plan 行 reachedGoal=false + closedReason 含"运行失败"', () async {
    final store = _FakeSessionStore();
    final handle = await _executor(store: store, client: _FailClient()).run(
      request: '任务',
      sessionId: _sid,
    );
    await handle.result;

    final plan = store.lastPlanRow;
    expect(plan, isNotNull);
    expect(plan!['reachedGoal'], isFalse);
    expect(plan['closedReason'], isA<String>());
    expect(plan['closedReason'], contains('运行失败'),
        reason: '★ 失败原因带统一人话前缀（不是裸异常/堆栈）');
  });

  test('★★ 无计划 ⇒ 不写 plan 行、不发 plan_closed 事件', () async {
    final store = _FakeSessionStore();
    final events = <AgentEvent>[];
    final handle = await _executor(store: store, client: _NoPlanClient()).run(
      request: '任务',
      sessionId: _sid,
    );
    final sub = handle.events.listen(events.add);
    await handle.result;
    await sub.cancel();

    expect(store.rows.where((r) => r['role'] == 'plan'), isEmpty);
    expect(events.where((e) => e.type == AgentEvent.kPlanClosed), isEmpty);
  });

  test('★★ 旧格式行（无 reachedGoal/closedReason）恢复按 null，不炸', () async {
    // 旧 jsonl 里的 plan 行只有 role/steps/ts —— 读方按 null（未知）处理。
    const oldRow = <String, dynamic>{
      'role': 'plan',
      'steps': [
        {'text': '旧步骤', 'status': 'pending'},
      ],
      'ts': 1,
    };
    final decoded =
        Map<String, dynamic>.from(oldRow); // 模拟从 JSONL 解出来的旧行
    expect(decoded['reachedGoal'] as bool?, isNull);
    expect(decoded['closedReason'] as String?, isNull);
    // 事件侧同理：缺键的 plan_closed 帧不炸、按 null
    final ev = AgentEvent.fromMap(<String, dynamic>{
      'type': AgentEvent.kPlanClosed,
      'ts': 1,
    });
    expect(ev.reachedGoal, isNull);
    expect(ev.planClosedReason, isNull);
  });
}
