import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **P1 计划门禁 / P3 反思注入 / SEC5 门面**（2026-10-25 接线门禁）。
///
/// P1：`RunOptions.requirePlan` —— 第一份计划（write_todos）之前，
/// 执行类工具全拒（读类放行）；计划存在后永久放行。
/// （框架 must 与 auto 行为一致 —— 这是自研的架构强制。）
///
/// P3：`RunOptions.reflectOnFailures = N` —— 连续 N 次工具失败注入
/// 反思指令（injectedMessages），成功即重置。
///
/// SEC5：`Guardrails` 门面 —— 输入侧静态校验的统一入口 + 防线清单。
void main() {
  group('P1 —— requirePlan 计划门禁', () {
    /// 脚本：call1 先 write_file（应被拒）→ call2 write_todos（放行，
    /// 产生计划）→ call3 再 write_file（放行）→ call4 收尾。
    _PlanScriptClient client() => _PlanScriptClient();

    HeraclesAgent agentWith(LLMClient c, {required bool requirePlan}) =>
        HeraclesAgent(
          config: const BackendConfig(apiKey: 'k', modelName: 'm'),
          capabilities: Capabilities(workspace: _PlanWs()),
          client: c,
          options: RunOptions(
            maxTurns: 10,
            enablePlan: true,
            requirePlan: requirePlan,
          ),
        );

    test('★★★ 开启：计划前的写操作被拒（指路 write_todos），'
        '列完计划后放行', () async {
      final c = client();
      final agent = agentWith(c, requirePlan: true);
      final events = <HeraclesEvent>[];
      await for (final e in agent.run('任务')) {
        events.add(e);
      }

      // call1 的 write_file 被拒（isError=true，原因含 write_todos）
      final w1 = events
          .whereType<HeraclesToolFinished>()
          .where((t) => t.toolName == 'write_file')
          .toList();
      expect(w1, isNotEmpty);
      expect(w1.first.isError, isTrue, reason: '计划前的写必须被拒');
      expect(w1.first.output, contains('write_todos'));

      // write_todos 放行了（计划产生）—— 最终收尾存在
      expect(events.whereType<HeraclesFinished>(), hasLength(1));
    });

    test('★★ 计划前的读操作放行（先看清楚再计划）', () async {
      // 脚本：call1 read_file（放行）→ call2 write_todos → call3 收尾
      final c = _ReadFirstClient();
      final ws = _PlanWs()..files['a.txt'] = '内容';
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: ws),
        client: c,
        options: RunOptions(
          maxTurns: 10,
          enablePlan: true,
          requirePlan: true,
        ),
      );
      final events = <HeraclesEvent>[];
      await for (final e in agent.run('任务')) {
        events.add(e);
      }
      final r1 = events
          .whereType<HeraclesToolFinished>()
          .firstWhere((t) => t.toolName == 'read_file');
      expect(r1.isError, isFalse, reason: '读类工具在计划前也放行');
    });

    test('★ 关闭（默认）：无计划直接写不拦（旧行为）', () async {
      final c = client();
      final agent = agentWith(c, requirePlan: false);
      final events = <HeraclesEvent>[];
      await for (final e in agent.run('任务')) {
        events.add(e);
      }
      final w1 = events
          .whereType<HeraclesToolFinished>()
          .where((t) => t.toolName == 'write_file')
          .first;
      expect(w1.isError, isFalse, reason: '默认不强制计划');
    });
  });

  group('P3 —— reflectOnFailures 反思注入', () {
    test('★★★ 连续 2 次失败 ⇒ 下一轮上下文含反思指令（成功重置）', () async {
      // 脚本：fail → fail →（反思注入，模型看到）→ ok → 收尾
      final c = _FailFailOkClient();
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: _PlanWs()),
        client: c,
        options: RunOptions(maxTurns: 10, reflectOnFailures: 2),
      );
      final events = <HeraclesEvent>[];
      await for (final e in agent.run('任务')) {
        events.add(e);
      }

      // 第 3 次调用的请求里应含反思指令
      final call3 = c.messages[2];
      final userTexts = call3
          .whereType<UserMessage>()
          .map((m) => m.contents.whereType<TextPart>().map((p) => p.text).join())
          .join();
      expect(userTexts, contains('[反思指令]'),
          reason: '连续失败后架构注入反思');
      expect(userTexts, contains('根因'));
      expect(events.whereType<HeraclesFinished>(), hasLength(1));
    });

    test('★ 阈值 0（默认）：失败不注入（旧行为）', () async {
      final c = _FailFailOkClient();
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: _PlanWs()),
        client: c,
        options: const RunOptions(maxTurns: 10),
      );
      await for (final _ in agent.run('任务')) {}
      final call3 = c.messages[2];
      final userTexts = call3
          .whereType<UserMessage>()
          .map((m) => m.contents.whereType<TextPart>().map((p) => p.text).join())
          .join();
      expect(userTexts, isNot(contains('反思指令')));
    });
  });

  group('SEC5 —— Guardrails 统一门面', () {
    test('★★★ 静态校验三件套：禁令/密钥/路径', () {
      expect(Guardrails.commandSafety('kill 123'), isNotNull);
      expect(Guardrails.commandSafety('git status'), isNull);

      expect(Guardrails.looksLikeSecret('sk-abc123def456ghi789'), isTrue);
      expect(Guardrails.looksLikeSecret('正常文本'), isFalse);

      expect(Guardrails.pathLooksOutside('/etc/passwd'), isNotNull,
          reason: '绝对路径');
      expect(Guardrails.pathLooksOutside('a/../../x'), isNotNull,
          reason: '显式穿越');
      expect(Guardrails.pathLooksOutside('src/main.dart'), isNull);
    });

    test('★ 防线清单完整（10 层）且自描述', () {
      expect(Guardrails.layers.length, 10,
          reason: '每条防线登记在册 —— 漏一层就是看不见的层');
      for (final (name, where, what) in Guardrails.layers) {
        expect(name, isNotEmpty);
        expect(where, anyOf(contains('层'), contains('hook'), contains('工具'), contains('工厂'), contains('App')));
        expect(what, isNotEmpty);
      }
    });
  });
}

// ============================================================================
// 测试替身
// ============================================================================

class _PlanWs implements WorkspaceCapability {
  final files = <String, String>{};

  @override
  Future<CapabilityResult> write(String path, String content) async {
    files[path] = content;
    return CapabilitySuccess('已写入 $path');
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<CapabilityResult> read(String path,
      {int offset = 1, int limit = 0}) async {
    if (!files.containsKey(path)) {
      return const CapabilityFailure('文件不存在', isRetryable: true);
    }
    return CapabilitySuccess(files[path]!);
  }

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

/// P1 脚本：write_file → write_todos → write_file → 收尾。
class _PlanScriptClient implements LLMClient {
  final messages = <List<LLMMessage>>[];
  int calls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return _r(modelConfig);
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return Stream<StreamingMessage>.fromIterable(
        [StreamingMessage(modelMessage: _r(modelConfig))]);
  }

  ModelMessage _r(ModelConfig mc) {
    final i = calls++;
    switch (i) {
      case 0:
        return _tool(mc, 'write_file',
            '{"path":"a.txt","content":"x"}');
      case 1:
        return _tool(mc, 'write_todos',
            '{"todos":[{"description":"步骤一","status":"pending"}]}');
      case 2:
        return _tool(mc, 'write_file',
            '{"path":"a.txt","content":"y"}');
      default:
        return ModelMessage(
            textOutput: '完成', model: mc.model, stopReason: 'stop');
    }
  }

  var _id = 0;
  ModelMessage _tool(ModelConfig mc, String name, String args) => ModelMessage(
        model: mc.model,
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(id: 'c${_id++}', name: name, arguments: args),
        ],
      );
}

/// P1 读先行脚本：read_file → write_todos → 收尾。
class _ReadFirstClient implements LLMClient {
  final messages = <List<LLMMessage>>[];
  int calls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return _r(modelConfig);
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return Stream<StreamingMessage>.fromIterable(
        [StreamingMessage(modelMessage: _r(modelConfig))]);
  }

  ModelMessage _r(ModelConfig mc) {
    final i = calls++;
    switch (i) {
      case 0:
        return ModelMessage(
          model: mc.model,
          stopReason: 'tool_calls',
          functionCalls: [
            FunctionCall(id: 'r$i', name: 'read_file', arguments: '{"path":"a.txt"}'),
          ],
        );
      case 1:
        return ModelMessage(
          model: mc.model,
          stopReason: 'tool_calls',
          functionCalls: [
            FunctionCall(
                id: 't$i',
                name: 'write_todos',
                arguments: '{"todos":[{"description":"s","status":"pending"}]}'),
          ],
        );
      default:
        return ModelMessage(
            textOutput: '完成', model: mc.model, stopReason: 'stop');
    }
  }
}

/// P3 脚本：read×2 失败 → read 成功 → 收尾。
/// （用 read_file 失败：文件 a.txt 不存在 → 能力层失败）
class _FailFailOkClient implements LLMClient {
  final messages = <List<LLMMessage>>[];
  int calls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return _r(modelConfig);
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    dynamic cancelToken,
  }) async {
    this.messages.add(List<LLMMessage>.of(messages));
    return Stream<StreamingMessage>.fromIterable(
        [StreamingMessage(modelMessage: _r(modelConfig))]);
  }

  ModelMessage _r(ModelConfig mc) {
    final i = calls++;
    if (i <= 2) {
      return ModelMessage(
        model: mc.model,
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(id: 'f$i', name: 'read_file', arguments: '{"path":"nope-$i.txt"}'),
        ],
      );
    }
    return ModelMessage(
        textOutput: 'done', model: mc.model, stopReason: 'stop');
  }
}
