import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **跨轮记忆 e2e 门禁** —— 证明历史**真的进了请求**。
///
/// ## 这条测试为什么必须有
///
/// 2026-10-23 之前，模型"记不住上一轮"：每次 run 都 `new HeraclesAgent(...)`，
/// 而 `_state` 是 `??=` 初始化的 ⇒ 每个实例都从空历史开始；App 侧也从来没
/// 读过会话文件。用户问"刚才那个文件叫什么"，模型答不上来。
///
/// 这种 bug **不会崩、不会抛、analyze 也全绿** —— 它只表现为"模型有点笨"。
/// 所以必须有断言：**拿真实 `HeraclesAgent.run()` 跑一遍，看 client 收到了什么**。
///
/// ## 为什么用"脚本化 client"而不是 mock 库
///
/// 我们要断言的**不是"某方法被调了几次"**，而是**"请求体里到底有哪些消息、
/// 顺序如何"**。这只能靠一个把 `messages` 原样记下来的替身。
/// 它零依赖、零联网，且能顺带断言"第二次请求里历史在前、本轮在后"。
void main() {
  /// 造一个能注入的 client 替身（`HeraclesAgent` 支持 `client:` 注入）。
  _ScriptedClient clientThatSays(String reply) =>
      _ScriptedClient(reply: reply);

  /// 造一个 agent（不需要任何设备能力 —— 这些测试只碰消息组装）。
  HeraclesAgent agentWith(LLMClient client) => HeraclesAgent(
        config: const BackendConfig(apiKey: 'test-key', modelName: 'test-model'),
        capabilities: const Capabilities(),
        client: client,
      );

  /// 把一次 run 跑到结束（消费掉事件流）。
  Future<void> runToEnd(HeraclesAgent agent, String request,
      {List<LLMMessage>? history}) async {
    await agent.run(request, history: history).drain<void>();
  }

  /// 取 client 第 [index] 次收到的 messages（`index` 0 起）。
  List<LLMMessage> messagesOfCall(_ScriptedClient c, int index) {
    expect(c.calls.length, greaterThan(index),
        reason: 'client 只被调了 ${c.calls.length} 次，没有第 ${index + 1} 次');
    return c.calls[index];
  }

  group('history 参数 —— 跨轮记忆真的进请求了', () {
    test('★★★ 不传 history ⇒ 请求里只有本轮那条 user 消息（向后兼容）', () async {
      final client = clientThatSays('第一轮回答');
      final agent = agentWith(client);

      await runToEnd(agent, '第一轮请求');

      final msgs = messagesOfCall(client, 0);
      final userMsgs = msgs.whereType<UserMessage>().toList();
      expect(userMsgs, hasLength(1),
          reason: '不带 history 时必须只有 1 条用户消息（旧行为不变），'
              '实际：${msgs.map(_textOfAny).join(" | ")}');
      expect(_textOfAny(userMsgs.single), '第一轮请求');
      // 只有 system + 本轮 user 两条（没有凭空多出的历史）
      expect(msgs, hasLength(2));
    });

    test('★★★ 传 history ⇒ 第二轮请求里**包含**第一轮的 user 与 assistant', () async {
      final client = clientThatSays('第二轮回答');
      final agent = agentWith(client);

      final history = <LLMMessage>[
        UserMessage.text('第一轮请求'),
        ModelMessage(textOutput: '第一轮回答', model: 'history'),
      ];

      await runToEnd(agent, '第二轮请求', history: history);

      final msgs = messagesOfCall(client, 0);
      final texts = msgs.map(_textOfAny).toList();

      expect(texts, contains('第一轮请求'), reason: '必须能看到第一轮的用户消息');
      expect(texts, contains('第一轮回答'), reason: '必须能看到第一轮的回答');
      expect(texts, contains('第二轮请求'), reason: '本轮请求也要在');
    });

    test('★★★ 顺序：历史在前、本轮在后（append-only，前缀缓存靠它）', () async {
      final client = clientThatSays('第二轮回答');
      final agent = agentWith(client);

      await runToEnd(agent, '第二轮请求', history: <LLMMessage>[
        UserMessage.text('A-用户一'),
        ModelMessage(textOutput: 'A-回答一', model: 'history'),
        UserMessage.text('A-用户二'),
        ModelMessage(textOutput: 'A-回答二', model: 'history'),
      ]);

      final texts = messagesOfCall(client, 0).map(_textOfAny).toList();

      // 两条历史 user/assistant 必须按原顺序排在本轮之前
      final i1 = texts.indexOf('A-用户一');
      final i2 = texts.indexOf('A-回答一');
      final i3 = texts.indexOf('A-用户二');
      final i4 = texts.indexOf('A-回答二');
      final iCur = texts.indexOf('第二轮请求');

      expect(i1, greaterThanOrEqualTo(0));
      expect(i2, greaterThan(i1), reason: '回答一必须在用户一之后');
      expect(i3, greaterThan(i2), reason: '用户二必须在回答一之后');
      expect(i4, greaterThan(i3));
      expect(iCur, greaterThan(i4),
          reason: '★ 本轮请求必须排在**所有历史之后** —— 这决定缓存前缀能不能复用');
    });

    test('★★ 空 history 与不传等价（不许因为空列表就出错）', () async {
      final client = clientThatSays('回答');
      final agent = agentWith(client);

      await runToEnd(agent, '请求', history: const <LLMMessage>[]);

      final userMsgs = messagesOfCall(client, 0).whereType<UserMessage>().toList();
      expect(userMsgs, hasLength(1));
    });

    test('★★ 第二轮请求的组成 = 1 条 system + 历史 + 本轮（不多不少）', () async {
      final client = clientThatSays('回答');
      final agent = agentWith(client);

      await runToEnd(agent, '本轮', history: <LLMMessage>[
        UserMessage.text('h1'),
        ModelMessage(textOutput: 'h2', model: 'history'),
        UserMessage.text('h3'),
      ]);

      final msgs = messagesOfCall(client, 0);

      // 实测组成（2026-10-23 用探针打出来的真实形状）：
      //   [0] SYSTEM（框架 `composeSystemMessage()` 拼的：
      //             我们的默认提示 + sub-agent 说明 + general principles）
      //   [1] USER h1
      //   [2] ASSISTANT h2
      //   [3] USER h3
      //   [4] USER 本轮
      //
      // 断言"system 在最前"很重要：它是**缓存前缀的最开头**。它若不在第 0 位，
      // 整条前缀缓存就废了。
      expect(msgs, hasLength(5),
          reason: '实际组成：${msgs.map((m) => "${m.runtimeType}(${_textOfAny(m)})").join(" | ")}');
      expect(msgs.first, isA<SystemMessage>(),
          reason: 'system prompt 必须在第 0 位（缓存前缀的开头）');
      expect(msgs.whereType<SystemMessage>(), hasLength(1),
          reason: '只许有一条 system');
      expect(msgs.whereType<UserMessage>(), hasLength(3), reason: 'h1 + h3 + 本轮');
      expect(msgs.whereType<ModelMessage>(), hasLength(1), reason: 'h2');
      // 最后一条必须是本轮请求
      expect(_textOfAny(msgs.last), '本轮');
    });
  });

  group('_lastText 不许把上一轮的回答当本轮答案（假信息）', () {
    test('★★★ 本轮失败时，finalText 不能是历史里上轮的回答', () async {
      // 这个 client 直接抛 —— 模拟本轮模型调用失败。
      final client = _ThrowingClient();
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: const Capabilities(),
        client: client,
      );

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('本轮会失败', history: <LLMMessage>[
        UserMessage.text('上轮请求'),
        ModelMessage(textOutput: '上轮的回答：文件叫 a.txt', model: 'history'),
      ])) {
        events.add(e);
      }

      // 要么失败、要么完成（框架可能重试后放弃），但**绝不许**把上轮回答当本轮答案。
      final finished = events.whereType<HeraclesFinished>();
      for (final f in finished) {
        expect(f.finalText, isNot(contains('上轮的回答')),
            reason: '★ 本轮失败却播了上轮的回答 = 假信息，比崩溃更糟');
      }
    });
  });

  group('sessionRowsToHistory —— 会话行 → 框架消息', () {
    test('★★★ 只收 user / assistant 的纯文本，跳过 tool / step / changes', () {
      final h = sessionRowsToHistory([
        {'role': 'user', 'text': '读一下 a.txt'},
        {'role': 'assistant', 'text': '我读一下 a.txt 的内容。'},
        // 工具行：缺 `functionCalls` 配对，喂进去会 400
        {
          'role': 'tool',
          'tool': 'read_file',
          'args': {'path': 'a.txt'},
          'result': '1| hello',
          'state': 'succeeded',
          'ok': true,
        },
        {'role': 'assistant', 'text': '文件内容是 hello。'},
        // UI 展示行
        {'role': 'step', 'stepId': 'turn-1', 'title': '分析需求', 'text': '我先看看。'},
        {'role': 'changes', 'files': []},
      ]);

      expect(h, hasLength(3), reason: '实际：${h.map(_textOfAny).join(" | ")}');
      expect(h.whereType<UserMessage>(), hasLength(1));
      expect(h.whereType<ModelMessage>(), hasLength(2));
      expect(h.map(_textOfAny).toList(),
          ['读一下 a.txt', '我读一下 a.txt 的内容。', '文件内容是 hello。']);
    });

    test('★★★ 空文本的 user / assistant 被跳过（纯附件轮、失败轮）', () {
      final h = sessionRowsToHistory([
        {'role': 'user', 'text': ''},
        {'role': 'assistant', 'text': ''},
        {'role': 'user', 'text': '有内容的'},
      ]);
      expect(h, hasLength(1));
      expect(_textOfAny(h.single), '有内容的');
    });

    test('★★ dropLastUserIfMatches ⇒ 排除本轮刚落盘的那条', () {
      final rows = <Map<String, dynamic>>[
        {'role': 'user', 'text': '上一轮'},
        {'role': 'assistant', 'text': '上一轮回答'},
        {'role': 'user', 'text': '本轮请求'},
      ];

      // 不排除 ⇒ 3 条（含本轮的）
      expect(sessionRowsToHistory(rows), hasLength(3));

      // 排除 ⇒ 2 条
      final h = sessionRowsToHistory(rows, dropLastUserIfMatches: '本轮请求');
      expect(h, hasLength(2));
      expect(h.map(_textOfAny).toList(), ['上一轮', '上一轮回答']);
    });

    test('★★ dropLastUserIfMatches 只匹配**尾部**那条（不误删更早的同样文本）', () {
      final rows = <Map<String, dynamic>>[
        {'role': 'user', 'text': '再试试'}, // 更早的真实重复
        {'role': 'assistant', 'text': '好'},
        {'role': 'user', 'text': '别的话'},
      ];

      // 末尾是"别的话"，不是"再试试" ⇒ 不该删任何东西
      final h = sessionRowsToHistory(rows, dropLastUserIfMatches: '再试试');
      expect(h, hasLength(3), reason: '用户真的重复问同一句时，那是历史不是重复');
    });

    test('★★ 超过 maxMessages ⇒ 只留最近的那几条', () {
      final rows = <Map<String, dynamic>>[
        for (var i = 0; i < 100; i++)
          {'role': i.isEven ? 'user' : 'assistant', 'text': 'm$i'},
      ];

      final h = sessionRowsToHistory(rows, maxMessages: 40);
      expect(h, hasLength(40));
      expect(_textOfAny(h.first), 'm60', reason: '留下的是最近 40 条');
      expect(_textOfAny(h.last), 'm99');
    });

    test('★ 默认上限就是 kHistoryMaxMessages（40）', () {
      final rows = <Map<String, dynamic>>[
        for (var i = 0; i < 200; i++) {'role': 'user', 'text': 'm$i'},
      ];
      expect(sessionRowsToHistory(rows), hasLength(kHistoryMaxMessages));
      expect(kHistoryMaxMessages, 40);
    });

    test('★★ 坏行 / 未知 role 不抛（存储里可能有 UI 字段）', () {
      final h = sessionRowsToHistory([
        {'role': 'system', 'text': '无法读取会话记录：xxx'},
        {'role': 'weird-role', 'text': 'x'},
        {'text': '没有 role 字段'},
        {'role': 'user'}, // 没有 text
        {'role': 'user', 'text': 'good'},
      ]);
      expect(h, hasLength(1));
      expect(_textOfAny(h.single), 'good');
    });

    test('★ 历史里的 assistant 不带 thought（重放推理会污染事实判断）', () {
      final h = sessionRowsToHistory([
        {'role': 'assistant', 'text': '正文', 'think': '这是思考，不该重放'},
      ]);
      final m = h.single as ModelMessage;
      expect(m.textOutput, '正文');
      expect(m.thought, isNull, reason: 'thought 不许回填');
    });
  });
}

/// 取任意消息的正文（断言用）。
String _textOfAny(LLMMessage m) {
  if (m is SystemMessage) return m.content;
  if (m is UserMessage) return _textOf(m);
  if (m is ModelMessage) return m.textOutput ?? '';
  if (m is FunctionExecutionResultMessage) {
    return m.results
        .map((r) => r.content.map((p) => p is TextPart ? p.text : '').join())
        .join();
  }
  return '';
}

String _textOf(UserMessage m) {
  final buf = StringBuffer();
  for (final p in m.contents) {
    if (p is TextPart) buf.write(p.text);
  }
  return buf.toString();
}

/// **脚本化 client** —— 把每次收到的 `messages` 原样记下来，返回固定回答。
///
/// 它**绝不联网**（没有 dio、没有 baseUrl），所以测试是毫秒级、可离线跑。
class _ScriptedClient implements LLMClient {
  _ScriptedClient({required this.reply});

  /// 每次被调用时要回给框架的正文。
  final String reply;

  /// 每次调用收到的 messages（下标 = 第几次调用）。
  final List<List<LLMMessage>> calls = [];

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    // `dynamic` 而不是 `CancelToken?`：`CancelToken` 来自 `dio`，
    // 不在 `dart_agent_core` 的导出里。库里其它 client 替身也这么写。
    dynamic cancelToken,
  }) async {
    calls.add(List<LLMMessage>.of(messages));
    return ModelMessage(
      textOutput: reply,
      model: modelConfig.model,
      stopReason: 'stop',
    );
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    // `dynamic` 而不是 `CancelToken?`：`CancelToken` 来自 `dio`，
    // 不在 `dart_agent_core` 的导出里。库里其它 client 替身也这么写。
    dynamic cancelToken,
  }) async {
    calls.add(List<LLMMessage>.of(messages));
    // 作为一条完整的 chunk 吐出去 —— 内容与 generate 一致，
    // 但走的是流式通道（框架默认 `useStream = true`）。
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(
        modelMessage: ModelMessage(
          textOutput: reply,
          model: modelConfig.model,
          stopReason: 'stop',
        ),
      ),
    ]);
  }
}

/// 每次都抛的 client —— 用来验证"本轮失败时不许播上轮答案"。
class _ThrowingClient implements LLMClient {
  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    // `dynamic` 而不是 `CancelToken?`：`CancelToken` 来自 `dio`，
    // 不在 `dart_agent_core` 的导出里。库里其它 client 替身也这么写。
    dynamic cancelToken,
  }) async {
    throw Exception('模拟本轮模型调用失败');
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    // `dynamic` 而不是 `CancelToken?`：`CancelToken` 来自 `dio`，
    // 不在 `dart_agent_core` 的导出里。库里其它 client 替身也这么写。
    dynamic cancelToken,
  }) async {
    throw Exception('模拟本轮模型调用失败');
  }
}
