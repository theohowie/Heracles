import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **P4 完成门禁**（2026-10-25 接线门禁）。
///
/// P4：`RunOptions.verifyGateCompletion`（与 verifyCommand 配套）——
/// 本轮发生过文件写/编辑且最后一次自动验证**失败**时，收尾被
/// `onTurnCompletion` 拒绝（continueRun 注入继续消息），模型必须回到
/// 修复循环 —— "带病收尾"被架构拦下；验证通过后正常收尾。
void main() {
  group('P4 —— verifyGateCompletion 完成门禁', () {
    test('★★★ 验证失败 ⇒ 收尾被拒注入继续消息；修好 ⇒ 正常收尾', () async {
      // 脚本：call1 写坏文件（验证失败）→ call2 收尾被门禁拒 →
      // call3 写好文件（验证通过）→ call4 收尾放行。
      final client = _SeqClient4();
      final shell = _SeqShell([
        const CapabilityFailure('error: 语法错误'),
        const CapabilitySuccess('编译通过'),
      ]);
      final ws = _Ws();
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: ws, shell: shell),
        client: client,
        options: RunOptions(
          maxTurns: 12,
          verifyCommand: 'dart analyze',
          verifyGateCompletion: true,
        ),
      );

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('写个文件')) {
        events.add(e);
      }

      // 验证命令跑了两次（第一次失败、修复后第二次通过）
      expect(shell.commands, hasLength(2));
      // 门禁注入的继续消息进了模型上下文（call3 的请求里）
      final call3 = client.messages[2];
      final userTexts = call3
          .whereType<UserMessage>()
          .map((m) => m.contents.whereType<TextPart>().map((p) => p.text).join())
          .join();
      expect(userTexts, contains('[自动验证未通过]'),
          reason: '门禁拒绝时注入继续消息 —— 模型被推回修复循环');
      // 最终正常收尾
      expect(events.whereType<HeraclesFinished>(), hasLength(1));
    });

    test('★ 未开启门禁 ⇒ 验证失败也放行收尾（旧行为）', () async {
      final client = _SeqClient4();
      final shell = _SeqShell([
        const CapabilityFailure('error: 语法错误'),
      ]);
      final ws = _Ws();
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: Capabilities(workspace: ws, shell: shell),
        client: client,
        options: RunOptions(maxTurns: 8, verifyCommand: 'dart analyze'),
      );
      final events = <HeraclesEvent>[];
      await for (final e in agent.run('写个文件')) {
        events.add(e);
      }
      expect(events.whereType<HeraclesFinished>(), hasLength(1));
      expect(shell.commands, hasLength(1), reason: '没有门禁：只验证这一次');
    });
  });
}

/// 按调用序号回脚本的 client（P4）：写 → 收尾 → 写 → 收尾。
class _SeqClient4 implements LLMClient {
  _SeqClient4();
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
    return _reply(modelConfig);
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
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(modelMessage: _reply(modelConfig)),
    ]);
  }

  ModelMessage _reply(ModelConfig mc) {
    final i = calls;
    calls++;
    final isWrite = i == 0 || i == 2;
    final args = isWrite
        ? (i == 0
            ? '{"path":"a.txt","content":"broken"}'
            : '{"path":"a.txt","content":"fixed"}')
        : '';
    return ModelMessage(
      model: mc.model,
      stopReason: isWrite ? 'tool_calls' : 'stop',
      functionCalls: isWrite
          ? <FunctionCall>[
              FunctionCall(id: 'w$i', name: 'write_file', arguments: args),
            ]
          : <FunctionCall>[],
      textOutput: isWrite ? null : '我认为已经完成。',
    );
  }
}

/// 按调用序号回验证结果的 shell（P4）。
class _SeqShell implements ShellCapability {
  _SeqShell(this.results);
  final List<CapabilityResult> results;
  final commands = <String>[];
  int calls = 0;

  @override
  Future<CapabilityResult> run(String command,
      {Duration timeout = const Duration(minutes: 5),
      void Function(String chunk)? onOutput}) async {
    commands.add(command);
    final i = calls;
    calls++;
    return results[i < results.length ? i : results.length - 1];
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
