import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **H6 子代理 e2e**（2026-10-24 接线门禁）。
///
/// 钉住 `_workerSubAgent`（`heracles_agent.dart`）的隔离语义：
///
/// 1. `enableSubAgents: true` ⇒ 框架自动追加 `delegate_task` 工具；
/// 2. worker 的**最终结论**作为工具结果回到主线程（主上下文只收结论）；
/// 3. worker 是**干净上下文**：它唯一一次调用里只有任务描述，看不到主对话；
/// 4. worker 的**过程事件被隔离**：它的用量走独立事件总线，就地丢弃，
///    不污染主线程的用量记账与 UI；
/// 5. 默认关闭：不开 `enableSubAgents` 时工具面没有 delegate_task（旧行为）。
///
/// ## 为什么这是 H6 的判定核心
///
/// 教材的 H6 = "子任务有独立上下文，互不污染；主上下文只收结论"。
/// 断言 ②③④ 合起来恰好就是这条标准的三半。
void main() {
  test('★★★ 派生 → worker 干净上下文执行 → 结论回主线程 → 过程事件隔离',
      () async {
    final client = _SeqClient([
      null, // call1（主线程）：请求 delegate_task
      'worker-result', // call2（worker）：worker 的最终回答
      '完成：worker-result', // call3（主线程）：父代理收尾
    ]);
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'm'),
      capabilities: const Capabilities(),
      client: client,
      options: RunOptions(maxTurns: 8, maxToolCalls: 50, enableSubAgents: true),
    );

    final events = <HeraclesEvent>[];
    await for (final e in agent.run('派个带子任务内容：子任务内容')) {
      events.add(e);
    }

    // ① delegate_task 进了工具面（框架在 subAgents 非空时自动追加）
    final tools = agent.state!.toolsHistory.last.tools;
    expect(tools.any((t) => t['name'] == 'delegate_task'), isTrue);

    // ② worker 的结论作为工具结果回到主线程（第 3 次调用的请求里）
    final third = client.messages[2];
    final results = third.whereType<FunctionExecutionResultMessage>().toList();
    expect(results, isNotEmpty, reason: '父代理的下一轮必须带着 worker 的结果');
    final resultText = results.last.results
        .expand((r) => r.content.whereType<TextPart>())
        .map((p) => p.text)
        .join();
    expect(resultText, contains('worker-result'));

    // ③ 最终回答来自父代理收尾
    expect(
      events.whereType<HeraclesFinished>().single.finalText,
      contains('完成'),
    );

    // ④ ★ 用量隔离：主事件流只有父线程的两轮用量（call1/call3）；
    //    worker 的那轮（call2）进了独立事件总线，就地丢弃。
    expect(events.whereType<HeraclesTurnUsage>().length, 2,
        reason: '实际：${events.whereType<HeraclesTurnUsage>().length}');

    // ⑤ ★ 上下文隔离：worker 唯一一次调用里只有"任务描述"这一条
    //    user 消息 —— 看不到主对话的"派个带子任务内容"。
    final workerMsgs = client.messages[1];
    final users = workerMsgs.whereType<UserMessage>().toList();
    expect(users, hasLength(1),
        reason: '实际：${users.map(_userText).join(" | ")}');
    expect(_userText(users.single), contains('子任务内容'));
    expect(_userText(users.single), isNot(contains('派个')),
        reason: 'worker 不该看到主线程的原话');
  });

  test('★ 默认关闭：工具面没有 delegate_task（旧行为不变）', () async {
    final client = _SeqClient(['完成。']);
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'm'),
      capabilities: const Capabilities(),
      client: client,
    );
    await for (final _ in agent.run('问题')) {}
    final tools = agent.state!.toolsHistory.last.tools;
    expect(tools.any((t) => t['name'] == 'delegate_task'), isFalse);
  });
}

/// 取 user 消息的纯文本（断言用）。
String _userText(UserMessage m) =>
    m.contents.whereType<TextPart>().map((p) => p.text).join();

/// 按调用序号回脚本的 client：第 0 次发 delegate_task 调用，其余回纯文本。
/// 记录每次收到的 messages（隔离断言用）。
class _SeqClient implements LLMClient {
  _SeqClient(this.texts);

  /// null = 该次调用发 delegate_task；字符串 = 该次回的正文。
  final List<String?> texts;
  final List<List<LLMMessage>> messages = [];
  int calls = 0;

  static final _usage = ModelUsage(
    promptTokens: 100,
    completionTokens: 10,
    totalTokens: 110,
  );

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
    if (i < texts.length && texts[i] == null) {
      return ModelMessage(
        model: mc.model,
        stopReason: 'tool_calls',
        usage: _usage,
        functionCalls: [
          FunctionCall(
            id: 'd1',
            name: 'delegate_task',
            arguments:
                '{"assignee":"worker","task_description":"子任务内容：数一数 README 里有几行。"}',
          ),
        ],
      );
    }
    return ModelMessage(
      textOutput: i < texts.length ? texts[i]! : '兜底',
      model: mc.model,
      stopReason: 'stop',
      usage: _usage,
    );
  }
}
