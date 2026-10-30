// Copyright (C) 2026 The Heracles Authors
//
// **B8 P0（2026-10-30）：`HeraclesPlanClosed` 终态事件**。
//
// 规格：只在**本轮出现过计划**时发，且**只发一次**：
// · 成功（finished 且计划步骤全部 done/cancelled）⇒ `reachedGoal=true, reason=null`；
// · 取消 ⇒ `{false, "用户停止"}`；
// · 失败/中断 ⇒ `{false, 人话}`（不得带堆栈/内部 id）；
// · 无计划 ⇒ 不发；
// · 顺序：**先于** `HeraclesFinished` / `HeraclesFailed`。
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  HeraclesAgent agentWith(
    LLMClient c, {
    int maxToolCalls = 50,
    int maxTurns = 10,
    Capabilities caps = const Capabilities(),
  }) =>
      HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: caps,
        client: c,
        options: RunOptions(
          maxTurns: maxTurns,
          maxToolCalls: maxToolCalls,
          enablePlan: true,
        ),
      );

  Future<List<HeraclesEvent>> runAll(
    HeraclesAgent agent, {
    CancelToken? cancelToken,
  }) async {
    final events = <HeraclesEvent>[];
    await for (final e in agent.run('任务', cancelToken: cancelToken)) {
      events.add(e);
    }
    return events;
  }

  test('★★★ 成功且计划全部完成 ⇒ plan_closed{reachedGoal:true, reason:null}（先于 finished、只一次）',
      () async {
    final events = await runAll(agentWith(_PlanDoneThenAnswer()));

    final closed = events.whereType<HeraclesPlanClosed>().toList();
    expect(closed, hasLength(1), reason: '★ 只发一次（三处收尾共用一个 helper）');
    expect(closed.single.reachedGoal, isTrue);
    expect(closed.single.reason, isNull,
        reason: '达成时 reason 必须是 null（不是空串、不是"完成"）');

    final iClosed = events.indexOf(closed.single);
    final iFinished =
        events.indexWhere((e) => e is HeraclesFinished);
    expect(iFinished, greaterThanOrEqualTo(0));
    expect(iClosed, lessThan(iFinished),
        reason: '★ 计划终态先于 run 终态（宿主先封计划再发回答）');
  });

  test('★★★ 用户取消 ⇒ {reachedGoal:false, "用户停止"}（人话，无堆栈）', () async {
    // 真实取消路径：工具执行期间用户点停止 ⇒ 框架在轮次边界抛
    // `AgentException(cancelled)`（backend 靠这个 code 说"用户停止"）。
    // 用"慢工具 + 50ms 后取消令牌"确定性构造（不依赖网络/真机）。
    final token = CancelToken();
    final slow = _SlowShell()..token = token;
    final events = await runAll(
      agentWith(
        _PlanThenSlowShell(slow),
        caps: Capabilities(shell: slow),
      ),
      cancelToken: token,
    );

    final closed = events.whereType<HeraclesPlanClosed>().toList();
    expect(closed, hasLength(1));
    expect(closed.single.reachedGoal, isFalse);
    expect(closed.single.reason, '用户停止',
        reason: '★ 取消的人话就是"用户停止"（不是异常类名/堆栈）');
    final iClosed = events.indexOf(closed.single);
    final iFailed = events.indexWhere((e) => e is HeraclesFailed);
    expect(iFailed, greaterThanOrEqualTo(0));
    expect(iClosed, lessThan(iFailed), reason: '★ 先封计划，再报失败');
    expect(events.whereType<HeraclesFailed>().single.reason, contains('取消'));
  });

  test('★★★ 失败 ⇒ {reachedGoal:false, 人话}（`运行失败：…` 前缀）', () async {
    final events = await runAll(agentWith(_PlanThenThrow()));

    final closed = events.whereType<HeraclesPlanClosed>().toList();
    expect(closed, hasLength(1));
    expect(closed.single.reachedGoal, isFalse);
    final reason = closed.single.reason;
    expect(reason, isNotNull);
    expect(reason!.trim(), isNotEmpty);
    expect(reason, contains('运行失败'),
        reason: '★ 失败原因要带统一人话前缀（不是裸异常文本）');
    // 不得出现堆栈/内部对象的默认字符串
    expect(reason, isNot(contains('Instance of')));
    expect(reason, isNot(contains('#0 ')));
  });

  test('★★★ 无计划 ⇒ **不发** plan_closed（宿主据此区分"无计划"）', () async {
    final events = await runAll(agentWith(_NoPlan()));
    expect(events.whereType<HeraclesPlanClosed>(), isEmpty);
    expect(events.whereType<HeraclesFinished>(), hasLength(1));
  });

  test('★★ 预算熔断（失败路径的一种）⇒ {false, 人话含"中断"}', () async {
    final events =
        await runAll(agentWith(_PlanThenToolsForever(), maxToolCalls: 1));

    final closed = events.whereType<HeraclesPlanClosed>().toList();
    expect(closed, hasLength(1));
    expect(closed.single.reachedGoal, isFalse);
    expect(closed.single.reason, contains('中断'),
        reason: '熔断不是模型失败 —— 人话说"被中断"比"运行失败"更准确');
  });
}

// ============================================================================
// 脚本 client
// ============================================================================

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

/// 成功：先列**已完成**计划，再给最终回答。
class _PlanDoneThenAnswer extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call, dynamic cancelToken) {
    if (call == 0) return _tool(mc, 'write_todos', _todosDone, call);
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 取消：先列未完成计划，然后调"慢工具"；工具执行期间取消令牌
/// （真实 UI 点停止的形状：框架在轮次边界抛 `AgentException(cancelled)`）。
class _PlanThenSlowShell extends _BaseClient {
  _PlanThenSlowShell(this.shell);
  final _SlowShell shell;

  @override
  ModelMessage reply(ModelConfig mc, int call, dynamic cancelToken) {
    if (call == 0) return _tool(mc, 'write_todos', _todosPending, call);
    if (call == 1) {
      return _tool(mc, 'run_shell_command', '{"command":"slow"}', call);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 慢工具：执行 200ms；开始后 50ms 取消令牌（模拟用户点停止）。
class _SlowShell implements ShellCapability {
  CancelToken? token;

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    Future<void>.delayed(const Duration(milliseconds: 50), () {
      token?.cancel('用户取消');
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return const CapabilitySuccess('slow-ok',
        metadata: <String, dynamic>{'exitCode': 0});
  }
}

/// 失败：先列计划，然后抛错。
class _PlanThenThrow extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call, dynamic cancelToken) {
    if (call == 0) return _tool(mc, 'write_todos', _todosPending, call);
    throw StateError('模拟模型调用失败');
  }
}

/// 无计划：直接回答。
class _NoPlan extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call, dynamic cancelToken) =>
      ModelMessage(textOutput: '直接答。', model: mc.model, stopReason: 'stop');
}

/// 预算熔断：列计划后不断发起工具调用（每次 id/参数不同，绕开循环检测）。
class _PlanThenToolsForever extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call, dynamic cancelToken) {
    if (call == 0) return _tool(mc, 'write_todos', _todosPending, call);
    return _tool(mc, 'run_shell_command', '{"command":"echo $call"}', call);
  }
}

/// 公共：记录调用次数并转发 [reply]。
abstract class _BaseClient implements LLMClient {
  int _calls = 0;

  ModelMessage reply(ModelConfig mc, int call, dynamic cancelToken);

  ModelMessage _next(ModelConfig mc, dynamic cancelToken) =>
      reply(mc, _calls++, cancelToken);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      _next(modelConfig, cancelToken);

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      Stream<StreamingMessage>.fromIterable(
          [StreamingMessage(modelMessage: _next(modelConfig, cancelToken))]);
}
