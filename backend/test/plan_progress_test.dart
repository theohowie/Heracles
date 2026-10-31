// Copyright (C) 2026 The Heracles Authors
//
// **T0-1（2026-10-31）：计划自动推进 `_PlanProgressHook`**。
//
// 规格（钉死）：
// · 有 inProgress ⇒ 成功执行类工具后标 completed，再把下一个 pending 标
//   inProgress（一帧 `HeraclesPlanUpdated` / 一步）；
// · 没有 inProgress ⇒ 只把第一个 pending 标 inProgress，**本步不标 done**；
// · 非执行类（write_todos/ask_user/save_memory/activate_skills/纯读…）成功
//   **不推进**；
// · 失败的调用**绝不推进、不得标 done**；
// · **每步只自动推进一次**；模型 `write_todos` 覆盖优先并重置自动记账；
// · plan_closed 语义不变（既有 plan_closed 测试仍绿）。
library;

// ignore: depend_on_referenced_packages
import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  HeraclesAgent agentWith(
    LLMClient c, {
    int maxTurns = 30,
    Capabilities? caps,
  }) =>
      HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: caps ?? Capabilities(workspace: _Ws()),
        client: c,
        options: RunOptions(
          maxTurns: maxTurns,
          maxToolCalls: 50,
          enablePlan: true,
        ),
      );

  Future<List<HeraclesEvent>> runAll(HeraclesAgent a) async {
    final events = <HeraclesEvent>[];
    await for (final e in a.run('任务')) {
      events.add(e);
    }
    return events;
  }

  List<HeraclesPlanUpdated> frames(List<HeraclesEvent> events) =>
      events.whereType<HeraclesPlanUpdated>().toList();

  int doneOf(HeraclesPlanUpdated f) =>
      f.steps.where((s) => s.status == HeraclesPlanStatus.done).length;

  group('自动推进', () {
    test('★★★ 7 步（第 1 步 in_progress）+ 6 次成功工具 ⇒ 初始 1 帧 + 自动 6 帧，done 递增',
        () async {
      final events = await runAll(agentWith(_SevenStepsClient()));

      final fs = frames(events);
      expect(fs, hasLength(7),
          reason: '★ 初始 write_todos 1 帧 + 每次成功工具各 1 帧（6 次）');
      final auto = fs.skip(1).toList();
      expect(auto, hasLength(6));
      // doneCount 递增：1..6
      for (var i = 0; i < 6; i++) {
        expect(doneOf(auto[i]), i + 1,
            reason: '第 ${i + 1} 次成功工具后应为 ${i + 1} 步 done');
      }
      // 每个自动帧恰好一步 active（下一个待办）
      for (final f in auto) {
        expect(f.steps.where((s) => s.status == HeraclesPlanStatus.active),
            hasLength(1));
      }
      expect(doneOf(fs.last), 6);
      expect(fs.last.steps.where((s) => s.status == HeraclesPlanStatus.active),
          hasLength(1), reason: '最后停在最后一步 in_progress');
    });

    test('★★★ 非执行类工具（纯读）成功 **不推进**（不产生自动帧）', () async {
      final events = await runAll(agentWith(_ReadThenWorkClient()));
      final fs = frames(events);
      expect(fs, hasLength(2),
          reason: '初始 1 帧 + 只有 write_file 那 1 帧；read_file 不推进');
      expect(doneOf(fs.last), 1);
    });

    test('★★★ 失败的工具 **不推进、不标 done**', () async {
      final events = await runAll(agentWith(
        _FailThenAnswerClient(),
        caps: Capabilities(workspace: _Ws(failWrite: true)),
      ));
      final fs = frames(events);
      expect(fs, hasLength(1), reason: '★ 失败调用不得产生自动帧');
      expect(fs.single.steps.where((s) => s.status == HeraclesPlanStatus.done),
          isEmpty, reason: '★ 失败步骤绝不能被画成 done');
      expect(
          fs.single.steps.where((s) => s.status == HeraclesPlanStatus.active),
          hasLength(1),
          reason: '原 in_progress 保持');
    });

    test('★★★ 模型覆盖优先：write_todos 后自动记账重置，可再次推进',
        () async {
      final events = await runAll(agentWith(_OverrideClient()));
      final fs = frames(events);
      // 初始 → 自动(step1 done/step2 active) → 模型覆盖(step1 active 重来) → 自动(step1 done)
      expect(fs, hasLength(4));
      expect(doneOf(fs[1]), 1);
      // 模型覆盖帧：模型给的是 step1 in_progress / 其余 pending
      expect(doneOf(fs[2]), 0);
      expect(fs[3].steps.first.status, HeraclesPlanStatus.done,
          reason: '★ 记账已重置 ⇒ 模型改回 in_progress 的步仍能被自动完成');
    });

    test('★★★ 每步只自动推进一次：2 步计划 + 2 次成功工具 ⇒ 恰 2 个自动帧',
        () async {
      final events = await runAll(agentWith(_TwoStepsClient()));
      final fs = frames(events);
      expect(fs, hasLength(3), reason: '初始 1 + 自动 2');
      expect(doneOf(fs[1]), 1);
      expect(doneOf(fs[2]), 2);
      for (var i = 1; i < fs.length; i++) {
        expect(doneOf(fs[i]), greaterThan(doneOf(fs[i - 1])),
            reason: '每帧只多画一步 done（不许一次连推两步）');
      }
    });

    test('★★★ 全部 pending（无 in_progress）：首次成功工具只标 active，不标 done',
        () async {
      final events = await runAll(agentWith(_AllPendingClient()));
      final fs = frames(events);
      expect(fs, hasLength(2), reason: '初始 1 + 首次工具"开始第一步"1');
      expect(doneOf(fs.last), 0, reason: '★ 本步不标 done');
      expect(fs.last.steps.first.status, HeraclesPlanStatus.active);
    });

    test('★★ 无计划 ⇒ 一次自动帧都不发', () async {
      final events = await runAll(agentWith(_NoPlanClient()));
      expect(frames(events), isEmpty);
      expect(events.whereType<HeraclesFinished>(), hasLength(1));
    });
  });
}

// ============================================================================
// 测试替身
// ============================================================================

class _Ws implements WorkspaceCapability {
  _Ws({this.failWrite = false});
  final bool failWrite;
  final files = <String, String>{};

  @override
  Future<CapabilityResult> write(String path, String content) async {
    if (failWrite) return const CapabilityFailure('磁盘写失败', isRetryable: false);
    files[path] = content;
    return CapabilitySuccess('已写入 $path');
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);
  @override
  Future<CapabilityResult> read(String path,
          {int offset = 1, int limit = 0}) async =>
      CapabilitySuccess(files[path] ?? 'ok');
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

ModelMessage _tool(ModelConfig mc, String name, String args, int id) =>
    ModelMessage(
      model: mc.model,
      stopReason: 'tool_calls',
      functionCalls: [FunctionCall(id: 'c$id', name: name, arguments: args)],
    );

String _todos(List<(String, String)> items) {
  final parts = [
    for (final (desc, st) in items)
      '{"description":"$desc","status":"$st"}',
  ];
  return '{"todos":[${parts.join(',')}]}';
}

/// 7 步（第 1 步 in_progress）+ 6 次成功 write_file + 收尾。
class _SevenStepsClient extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call) {
    if (call == 0) {
      return _tool(
          mc,
          'write_todos',
          _todos([
            ('步骤一', 'in_progress'),
            ('步骤二', 'pending'),
            ('步骤三', 'pending'),
            ('步骤四', 'pending'),
            ('步骤五', 'pending'),
            ('步骤六', 'pending'),
            ('步骤七', 'pending'),
          ]),
          0);
    }
    if (call <= 6) {
      return _tool(mc, 'write_file', '{"path":"f$call.txt","content":"x"}', call);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 2 步计划 → 成功 read_file（不推进）→ 成功 write_file（推进 1 次）→ 收尾。
class _ReadThenWorkClient extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call) {
    if (call == 0) {
      return _tool(mc, 'write_todos',
          _todos([('步骤一', 'in_progress'), ('步骤二', 'pending')]), 0);
    }
    if (call == 1) {
      return _tool(mc, 'read_file', '{"path":"a.txt"}', 1);
    }
    if (call == 2) {
      return _tool(mc, 'write_file', '{"path":"f.txt","content":"x"}', 2);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 2 步计划 → **失败** write_file → 收尾。
class _FailThenAnswerClient extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call) {
    if (call == 0) {
      return _tool(mc, 'write_todos',
          _todos([('步骤一', 'in_progress'), ('步骤二', 'pending')]), 0);
    }
    if (call == 1) {
      return _tool(mc, 'write_file', '{"path":"f.txt","content":"x"}', 1);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 3 步 → 成功工具（自动推进）→ 模型覆盖回 step1 in_progress → 成功工具（再次推进）。
class _OverrideClient extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call) {
    if (call == 0) {
      return _tool(
          mc,
          'write_todos',
          _todos([
            ('步骤一', 'in_progress'),
            ('步骤二', 'pending'),
            ('步骤三', 'pending'),
          ]),
          0);
    }
    if (call == 1) {
      return _tool(mc, 'write_file', '{"path":"f1.txt","content":"x"}', 1);
    }
    if (call == 2) {
      // 模型主动覆盖：把第一步改回 in_progress（"重来"）—— 记账必须重置。
      return _tool(
          mc,
          'write_todos',
          _todos([
            ('步骤一', 'in_progress'),
            ('步骤二', 'pending'),
            ('步骤三', 'pending'),
          ]),
          2);
    }
    if (call == 3) {
      return _tool(mc, 'write_file', '{"path":"f2.txt","content":"x"}', 3);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 2 步（第 1 步 in_progress）+ 2 次成功工具。
class _TwoStepsClient extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call) {
    if (call == 0) {
      return _tool(mc, 'write_todos',
          _todos([('步骤一', 'in_progress'), ('步骤二', 'pending')]), 0);
    }
    if (call == 1) {
      return _tool(mc, 'write_file', '{"path":"f1.txt","content":"x"}', 1);
    }
    if (call == 2) {
      return _tool(mc, 'write_file', '{"path":"f2.txt","content":"x"}', 2);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 2 步全是 pending ⇒ 首次成功工具只标 active。
class _AllPendingClient extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call) {
    if (call == 0) {
      return _tool(mc, 'write_todos',
          _todos([('步骤一', 'pending'), ('步骤二', 'pending')]), 0);
    }
    if (call == 1) {
      return _tool(mc, 'write_file', '{"path":"f.txt","content":"x"}', 1);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 无计划：直接调工具 + 回答。
class _NoPlanClient extends _BaseClient {
  @override
  ModelMessage reply(ModelConfig mc, int call) {
    if (call == 0) {
      return _tool(mc, 'write_file', '{"path":"f.txt","content":"x"}', 0);
    }
    return ModelMessage(textOutput: '完成。', model: mc.model, stopReason: 'stop');
  }
}

/// 公共：按调用序号返回模型消息。
abstract class _BaseClient implements LLMClient {
  int _calls = 0;

  ModelMessage reply(ModelConfig mc, int call);

  ModelMessage _next(ModelConfig mc) => reply(mc, _calls++);

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async =>
      _next(modelConfig);

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
          [StreamingMessage(modelMessage: _next(modelConfig))]);
}
