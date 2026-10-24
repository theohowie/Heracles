import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **M5 自动提炼 + H3/K2 自验证**（2026-10-25 接线门禁）。
///
/// M5：`RunOptions.autoExtract` 开启 ⇒ 任务收尾用一次摘要调用提炼事实、
/// 逐条写入长期记忆（`[auto] ` 前缀、source=模型提炼）；关闭 ⇒ 零调用。
///
/// H3/K2：`RunOptions.verifyCommand` 配置 ⇒ 文件写/编辑成功后**自动**经
/// shell 跑验证命令，输出附在工具结果里回给模型 —— 架构级闭环：
/// 模型看到 `[自动验证] 失败：…` 就知道要修，不靠提示词劝。
void main() {
  group('M5 —— 自动提炼', () {
    _Mem mem() => _Mem();

    HeraclesAgent agentWith(
      _TwoLineClient client,
      _Mem memory, {
      required bool autoExtract,
    }) =>
        HeraclesAgent(
          config: const BackendConfig(apiKey: 'k', modelName: 'm'),
          capabilities: Capabilities(memory: memory, workspace: _Ws()),
          client: client,
          options: RunOptions(maxTurns: 4, autoExtract: autoExtract),
        );

    test('★★★ autoExtract 开 ⇒ 收尾提炼并逐条入记忆（[auto] 前缀）', () async {
      final client = _TwoLineClient('用户想让项目跑起来；已写好 README。');
      final memory = mem();
      final agent = agentWith(client, memory, autoExtract: true);

      await for (final _ in agent.run('跑起来')) {}

      expect(memory.appended, hasLength(2), reason: '实际 ${memory.appended}');
      expect(memory.appended[0], startsWith('[auto] '));
    });

    test('★★ autoExtract 关（默认）⇒ 零提炼调用、零写入', () async {
      final client = _TwoLineClient('x');
      final memory = mem();
      final agent = agentWith(client, memory, autoExtract: false);

      await for (final _ in agent.run('跑')) {}

      expect(memory.appended, isEmpty, reason: '默认关闭：一次提炼调用都不该有');
    });
  });

  group('H3/K2 —— 自验证管线（verifyCommand）', () {
    test('★★★ 写文件成功 ⇒ 自动跑验证命令，输出附在工具结果', () async {
      final client = _TwoLineClient();
      final shell =
          _CountingShell(const CapabilitySuccess('编译通过，0 错误'));
      final ws = _Ws();
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: ws, shell: shell),
        client: client,
        options: RunOptions(
          maxTurns: 6,
          verifyCommand: 'dart analyze',
        ),
      );

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('写个文件')) {
        events.add(e);
      }

      expect(shell.commands, ['dart analyze'], reason: '写成功后自动验证');
      final finished = events.whereType<HeraclesToolFinished>().toList();
      final writeResult = finished
          .firstWhere((t) => t.toolName == 'write_file')
          .output;
      expect(writeResult, contains('[自动验证]'));
      expect(writeResult, contains('编译通过'));
    });

    test('★★ 验证失败也如实附上（模型看到失败才会修 —— 闭环的关键半边）',
        () async {
      final client = _TwoLineClient();
      final shell = _CountingShell(
        const CapabilityFailure('error: 语法错误'),
      );
      final ws = _Ws();
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: ws, shell: shell),
        client: client,
        options: RunOptions(maxTurns: 6, verifyCommand: 'dart analyze'),
      );

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('写')) {
        events.add(e);
      }

      final writeResult = events
          .whereType<HeraclesToolFinished>()
          .firstWhere((t) => t.toolName == 'write_file')
          .output;
      expect(writeResult, contains('失败'));
      expect(writeResult, contains('error: 语法错误'));
    });

    test('★ 未配置 verifyCommand ⇒ 不验证（旧行为）', () async {
      final client = _TwoLineClient();
      final shell = _CountingShell(const CapabilitySuccess('x'));
      final ws = _Ws();
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: ws, shell: shell),
        client: client,
      );
      await for (final _ in agent.run('写')) {}
      expect(shell.commands, isEmpty);
    });
  });
}

// ============================================================================
// 测试替身
// ============================================================================

/// 第 1 轮写文件，第 2 轮收尾；同时作为 M5 的摘要器（回两行"事实"）。
class _TwoLineClient implements LLMClient {
  _TwoLineClient([this.reply = '完成。']);
  String reply;
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
    calls++;
    if (calls == 1) {
      return ModelMessage(
        model: modelConfig.model,
        stopReason: 'tool_calls',
        functionCalls: [
          FunctionCall(
            id: 'w1',
            name: 'write_file',
            arguments: '{"path":"a.txt","content":"hello"}',
          ),
        ],
      );
    }
    // M5 摘要调用（或父代理收尾）回两行事实
    return ModelMessage(
      textOutput: '- 用户想让项目跑起来；已写好 README。\n- 偏好简洁回复。',
      model: modelConfig.model,
    );
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
    calls++;
    if (calls == 1) {
      return Stream<StreamingMessage>.fromIterable([
        StreamingMessage(
          modelMessage: ModelMessage(
            model: modelConfig.model,
            stopReason: 'tool_calls',
            functionCalls: [
              FunctionCall(
                id: 'w1',
                name: 'write_file',
                arguments: '{"path":"a.txt","content":"hello"}',
              ),
            ],
          ),
        ),
      ]);
    }
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(
        modelMessage: ModelMessage(
          textOutput: '- 用户想让项目跑起来；已写好 README。\n- 偏好简洁回复。',
          model: modelConfig.model,
          stopReason: 'stop',
        ),
      ),
    ]);
  }
}

class _Mem implements MemoryCapability {
  final appended = <String>[];

  @override
  Future<String> read() async => appended.join('\n');

  @override
  Future<CapabilityResult> append(String note) async {
    appended.add(note);
    return const CapabilitySuccess('saved');
  }
}

class _CountingShell implements ShellCapability {
  _CountingShell(this.result);
  final CapabilityResult result;
  final commands = <String>[];

  @override
  Future<CapabilityResult> run(String command,
      {Duration timeout = const Duration(minutes: 5),
      void Function(String chunk)? onOutput}) async {
    commands.add(command);
    return result;
  }
}

/// 最小内存工作区。
class _Ws implements WorkspaceCapability {
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
          {int offset = 1, int limit = 0}) async =>
      CapabilitySuccess(files[path] ?? '');

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
      const CapabilitySuccess('已删除');

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
