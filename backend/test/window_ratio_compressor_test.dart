import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **压缩器门禁** —— 尤其钉住 `toolsHistory` 那条"静态全绿、一压就崩"的 bug。
///
/// ## 它为什么会藏得住（审计 §3.1）
///
/// `ToolsHistoryItem.tools` 的类型是 `List<Map<String, dynamic>>`
/// （框架 `stateful_agent.dart` 里 `request.tools.map((t) => t.toJson())` 写入的）。
/// 旧代码在 `dynamic` 上写 `t.description` / `t.name` ——
/// **`dart analyze` 看不见 dynamic 上的成员**，所以报 "No issues found!"；
/// 真跑到压缩这一步直接
/// `NoSuchMethodError: Class '_Map<String, dynamic>' has no instance getter 'description'`。
///
/// 换句话说：**44/44 全绿那天，这条路径一次都没被跑过**。
/// 这个文件的存在意义就是让它永远有一个入口。
///
/// ## 修法（已落地）
///
/// `_estimateUsage` 只走 `_lastToolJsons()` + `_toolField()`：显式标注
/// `Map<String, dynamic>`，按**字符串键**取值，取不到就退化成 `''`
/// （少算一点 token，绝不抛）。`estimateUsage()` 是为此特意暴露的 `public` 入口。
void main() {
  /// 一个不联网的 client 替身 —— 这些测试只碰"估算"，不该发出任何请求。
  LLMClient stubClient() => _RecordingClient();

  WindowRatioCompressor compressor({
    int modelWindowTokens = 128000,
    LLMClient? client,
  }) =>
      WindowRatioCompressor(
        client: client ?? stubClient(),
        modelConfig: ModelConfig(model: 'stub-model'),
        modelWindowTokens: modelWindowTokens,
      );

  /// 造一个带 `toolsHistory` 的 state —— 形状**故意照抄框架写入的真实形状**：
  /// `Tool.toJson()` 的产物（`name` / `description` / `parameters` …）。
  AgentState stateWithTools(Map<String, dynamic> toolJson) => AgentState(
        sessionId: 's-test',
        history: AgentMessageHistory(
          messages: [UserMessage.text('读一下 a.txt')],
        ),
        toolsHistory: [
          ToolsHistoryItem(
            tools: [toolJson],
            validFromMessageIndex: 0,
          ),
        ],
      );

  group('toolsHistory —— 审计 §3.1 那条崩溃', () {
    test('★★★ 带 toolsHistory 的 state 不抛异常（这就是 NoSuchMethodError 那条）', () {
      final c = compressor();
      final state = stateWithTools({
        'name': 'read_file',
        'description': '读文件，返回带行号的内容。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
        },
      });

      // 旧实现走到这里就是 NoSuchMethodError: _Map has no instance getter 'description'
      expect(() => c.estimateUsage(state), returnsNormally);
    });

    test('★★★ 带 toolsHistory 的估算结果必须 > 0（工具定义是常驻开销）', () {
      final c = compressor();
      final state = stateWithTools({
        'name': 'read_file',
        'description': '读文件，返回带行号的内容。',
      });

      final usage = c.estimateUsage(state);
      expect(usage, greaterThan(0),
          reason: '工具定义占输入 token，估算不能把它当 0');
    });

    test('★★ 描述越长，估算越大（证明真的读了 description）', () {
      final c = compressor();
      final short = stateWithTools({'name': 'x', 'description': '短'});
      final long = stateWithTools({'name': 'x', 'description': '很长的描述' * 200});

      expect(c.estimateUsage(long), greaterThan(c.estimateUsage(short)));
    });

    test('★★ 缺 name / description 键 ⇒ 退化成少算，不抛', () {
      final c = compressor();
      final state = stateWithTools({
        'parameters': {'type': 'object'}, // 刻意没有 name / description
      });

      expect(() => c.estimateUsage(state), returnsNormally);
      // 只有"工具条目的固定 JSON 开销"那一份，仍然 > 0
      expect(c.estimateUsage(state), greaterThan(0));
    });

    test('★★ 字段类型不对（description 是 int）⇒ 不抛、当空串处理', () {
      final c = compressor();
      final state = stateWithTools({'name': 'x', 'description': 123});

      expect(() => c.estimateUsage(state), returnsNormally);
      expect(c.estimateUsage(state), greaterThan(0));
    });

    test('★★ toolsHistory 为空（还没发过请求）⇒ 不抛', () {
      final c = compressor();
      final state = AgentState(
        sessionId: 's-empty',
        history: AgentMessageHistory(messages: [UserMessage.text('hi')]),
      );

      expect(state.toolsHistory, isEmpty);
      expect(() => c.estimateUsage(state), returnsNormally);
      expect(c.estimateUsage(state), greaterThan(0),
          reason: '光那条用户消息也有 token');
    });

    test('★ 多条 toolsHistory 只算最后一条（= 当前在用的工具面）', () {
      final c = compressor();
      final oldOnly = AgentState(
        sessionId: 's-old',
        history: AgentMessageHistory(messages: [UserMessage.text('hi')]),
        toolsHistory: [
          ToolsHistoryItem(
            tools: [
              {'name': 'a', 'description': '旧工具面' * 300},
            ],
            validFromMessageIndex: 0,
          ),
        ],
      );
      final newest = AgentState(
        sessionId: 's-new',
        history: AgentMessageHistory(messages: [UserMessage.text('hi')]),
        toolsHistory: [
          ToolsHistoryItem(
            tools: [
              {'name': 'a', 'description': '旧工具面' * 300},
            ],
            validFromMessageIndex: 0,
          ),
          ToolsHistoryItem(
            tools: [
              {'name': 'b', 'description': '新'},
            ],
            validFromMessageIndex: 5,
          ),
        ],
      );

      expect(c.estimateUsage(newest), lessThan(c.estimateUsage(oldOnly)),
          reason: '只该看 .last —— 历史工具面的旧快照不该继续计入');
    });
  });

  group('触发阈值 —— 按模型窗口比例，不是写死的数', () {
    test('★★★ 128K 窗口 ⇒ 阈值 102400（= 128000 × 0.80）', () {
      final c = compressor(modelWindowTokens: 128000);
      expect(c.triggerThreshold, 102400);
    });

    test('★★★ 80% 是用户明确要求的比例（不是拍的）', () {
      // 用户原话：「如果上下文达到了 80% 必须先自动压缩，然后继续任务」。
      expect(ContractCompression.compressAtRatio, 0.80);
    });

    test('★★★ 换窗口阈值跟着变（自适应才是这个类存在的理由）', () {
      expect(compressor(modelWindowTokens: 200000).triggerThreshold, 160000);
      expect(compressor(modelWindowTokens: 8192).triggerThreshold, 6553,
          reason: '8192 × 0.8 = 6553.6 ⇒ floor 6553');
    });

    test('★★ 阈值向下取整（不能浮点漏成 0.8 个 token）', () {
      // 10000 × 0.8 = 8000（整数，无余数）
      expect(compressor(modelWindowTokens: 10000).triggerThreshold, 8000);
      // 10001 × 0.8 = 8000.8 ⇒ floor ⇒ 8000
      expect(compressor(modelWindowTokens: 10001).triggerThreshold, 8000);
      // 10005 × 0.8 = 8004.0（整数）
      expect(compressor(modelWindowTokens: 10005).triggerThreshold, 8004);
    });

    test('★★ 默认参数来自契约常量（不是内联字面量）', () {
      final c = compressor();
      expect(c.compressAtRatio, ContractCompression.compressAtRatio);
      expect(c.compressAtRatio, 0.80);
      expect(c.keepRecentTurns, 6);
    });
  });

  group('窗口 10000 的边界：7999 不压 / 8000 压', () {
    /// 造一个估算值恰好约等于 [tokens] token 的 state。
    ///
    /// ## 估算规则（`_estimateTokens`，别猜）
    ///
    /// - **CJK ≈ 1 字 / token**
    /// - **ASCII ≈ 4 字符 / token**（`ceil`)`
    ///
    /// ⇒ 想精确凑到 N token，用**中文**最直接：N 个汉字 = N token。
    ///
    /// ⚠️ 我第一版用 ASCII（'a'*N）凑，以为 1 字符=1 token —— 实际是
    /// 4 字符/token，8000 个字符只有 2000 token，断言当场就炸了。
    /// **这就是为什么边界测试必须真跑，不能"看起来对"**。
    AgentState stateWithTokens(int targetTokens) {
      final msgs = <LLMMessage>[];
      var remaining = targetTokens;
      while (remaining > 0) {
        // 每条最多 100 个汉字 ⇒ 100 token
        final n = remaining >= 100 ? 100 : remaining;
        msgs.add(UserMessage.text('字' * n));
        remaining -= n;
      }
      return AgentState(
        sessionId: 'probe',
        history: AgentMessageHistory(messages: msgs),
      );
    }

    test('★★★ 7999 token < 阈值 8000 ⇒ 不压（delegate 一次都不调）', () async {
      final client = _RecordingClient();
      var compressed = 0;
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
        onCompressed: (_, __, ___, ____) => compressed++,
      );

      final state = stateWithTokens(7999);
      final usage = c.estimateUsage(state);
      // 正好 7999（汉字 1:1，没有 ceil 误差）
      expect(usage, 7999, reason: '构造必须精确：实际 $usage');
      expect(usage, lessThan(8000));

      final before = client.calls;
      await c.compress(state);

      expect(compressed, 0, reason: '没到阈值不许触发压缩事件');
      expect(client.calls, before, reason: '没到阈值连摘要请求都不该发');    });

    test('★★★ 8000 token = 阈值 ⇒ 放行到 delegate', () async {
      final client = _RecordingClient();
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );

      final state = stateWithTokens(8000);
      final usage = c.estimateUsage(state);
      expect(usage, 8000, reason: '构造必须精确：实际 $usage');
      expect(c.triggerThreshold, 8000);
      expect(usage, greaterThanOrEqualTo(c.triggerThreshold));

      // 放行 ≠ 真的压缩：delegate 内部还有早退条件
      // （`usages` 为空、消息条数 ≤ keepRecentMessageSize 等）。
      // 这条只证明"我们这层在 8000 这个点放行"。
      // "真的压缩了 + 任务继续"由 `compression_e2e_test.dart` 证明。
      await c.compress(state);
    });
  });

  group('compress() —— 没到阈值就什么都不做', () {
    test('★★★ 历史很小 ⇒ 不触发压缩，不发任何请求', () async {
      final client = _RecordingClient();
      final c = compressor(modelWindowTokens: 128000, client: client);
      final state = AgentState(
        sessionId: 's-small',
        history: AgentMessageHistory(messages: [UserMessage.text('一句话')]),
      );

      await c.compress(state);

      expect(client.calls, 0, reason: '没到阈值 ⇒ 一次模型调用都不该发出');
      expect(state.history.episodicMemories, isEmpty);
    });

    test('★★ 大历史带 toolsHistory 也不抛（这条路径以前没人走过）', () async {
      final client = _RecordingClient();
      final c = compressor(modelWindowTokens: 8192, client: client);
      final state = AgentState(
        sessionId: 's-big',
        history: AgentMessageHistory(
          messages: [
            for (var i = 0; i < 60; i++) UserMessage.text('第 $i 条' * 40),
          ],
        ),
        toolsHistory: [
          ToolsHistoryItem(
            tools: [
              {
                'name': 'read_file',
                'description': '读文件' * 200,
                'parameters': {'type': 'object'},
              },
            ],
            validFromMessageIndex: 0,
          ),
        ],
      );

      // ⚠️ 这里只断言"不抛"：`LLMBasedContextCompressor.compress` 在
      // `state.usages.isEmpty` 时会自己早退（那是框架的行为，不是我们的）。
      // 也就是说这条测试**不证明摘要真的跑通了** —— 它只锁住"估算那一段
      // 不会因为 toolsHistory 而崩"。
      await expectLater(c.compress(state), completes);
      expect(state.toolsHistory, hasLength(1));
    });
  });

  // ==========================================================================
  // 三级压缩（2026-10-24）：micro(40%) / auto(60%) / full(80% 强制)
  // ==========================================================================
  group('三级 —— 第一级 micro（≥40% 且 <60%）：无 LLM 清理老工具结果', () {
    /// 造一个估算值落在 [4000, 6000) 的 state：一条大工具结果 + 30 条小消息。
    ///（消息总数 32 > 保护窗 24 ⇒ 大结果落在保护窗外，micro 才碰得到它。）
    AgentState stateForMicro({int resultChars = 4500}) => AgentState(
          sessionId: 's-micro',
          history: AgentMessageHistory(messages: [
            UserMessage.text('读文件' * 5), // 10 token
            FunctionExecutionResultMessage(results: [
              FunctionExecutionResult(
                id: 'c1',
                name: 'read_file',
                isError: false,
                arguments: '{"path":"a.txt"}',
                content: [TextPart('内' * resultChars)], // CJK 1 字 = 1 token
              ),
            ]),
            for (var i = 0; i < 30; i++) UserMessage.text('字' * 20),
          ]),
        );

    test('★★★ 老工具结果被换成占位符，正文一字不动，零 LLM 调用', () async {
      final client = _RecordingClient();
      var notified = 0;
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000, // micro 线 4000 / auto 线 6000
        onCompressed: (_, __, ___, ____) => notified++,
      );
      final state = stateForMicro();
      final before = c.estimateUsage(state);
      expect(before, inExclusiveRange(4000, 6000),
          reason: '构造必须落在 micro 区间，实际 $before');

      await c.compress(state);

      expect(client.calls, 0, reason: '★ micro 是确定性的，一次 LLM 都不该调');
      expect(notified, 1, reason: '确有清理 ⇒ 要播事件');
      final results = state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .single;
      final text = results.results.single.content
          .whereType<TextPart>()
          .map((p) => p.text)
          .join();
      expect(text, contains('microcompact'));
      expect(text, contains('4500'), reason: '占位符要如实报原大小');
      expect(c.estimateUsage(state), lessThan(before),
          reason: 'token 必须真的省下来了');
    });

    test('★★ 保护窗内的工具结果绝不清理；小结果也不清理', () async {
      final client = _RecordingClient();
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );
      // 大结果放最后一条（保护窗内）⇒ micro 无事可做
      final state = AgentState(
        sessionId: 's-tail',
        history: AgentMessageHistory(messages: [
          for (var i = 0; i < 31; i++) UserMessage.text('字' * 20),
          FunctionExecutionResultMessage(results: [
            FunctionExecutionResult(
              id: 'c1',
              name: 'read_file',
              isError: false,
              arguments: '{}',
              content: [TextPart('内' * 4500)],
            ),
          ]),
        ]),
      );
      final before = c.estimateUsage(state);
      await c.compress(state);
      expect(c.estimateUsage(state), before, reason: '保护窗内的不许动');
      expect(client.calls, 0);
    });

    test('★★ 40% 以下 ⇒ 什么都不做（能装下就全装）', () async {
      final client = _RecordingClient();
      var notified = 0;
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 100000,
        onCompressed: (_, __, ___, ____) => notified++,
      );
      final state = stateForMicro(); // 5110 token << 40000
      await c.compress(state);
      expect(notified, 0);
      expect(client.calls, 0);
    });
  });

  group('三级 —— 第三级 full（摘要失败/不够时，确定性强制重置）', () {
    test('★★★ 摘要静默失败 + 估算 ≥80% ⇒ 整批丢弃老轮次 + 插如实说明', () async {
      final client = _RecordingClient();
      var notified = 0;
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
        onCompressed: (_, __, ___, ____) => notified++,
      );
      // 90 批 × 90 token = 8100 ≥ 8000（强制线）。
      // 真框架 delegate 因 usages 为空会静默早退 ⇒ 只能靠第三级。
      final state = AgentState(
        sessionId: 's-full',
        history: AgentMessageHistory(
          messages: [
            for (var i = 0; i < 90; i++) UserMessage.text('字' * 90),
          ],
        ),
      );

      await c.compress(state);

      expect(state.history.messages.length, 7,
          reason: '说明 1 条 + 最近 6 批');
      final note = state.history.messages.first as UserMessage;
      expect(_text(note), contains('[系统维护]'));
      expect(_text(note), contains('84'),
          reason: '如实报丢弃条数，绝不假装"已摘要"');
      expect(c.estimateUsage(state), lessThan(8000),
          reason: '★ 重置后必须低于强制线 —— 这就是"80% 必压缩"的兜底');
      expect(notified, 1, reason: '第二级没生效不播；第三级生效播一次');
    });

    test('★★ 无 user 边界的历史也能重置（切点不拆工具批）', () async {
      final client = _RecordingClient();
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );
      // 纯 assistant 历史（长工具链）：66 号位置放一对调用+结果
      final msgs = <LLMMessage>[
        for (var i = 0; i < 90; i++)
          ModelMessage(textOutput: '字' * 90, model: 'm'),
      ];
      msgs[66] = ModelMessage(
        textOutput: '字' * 90,
        model: 'm',
        functionCalls: [FunctionCall(id: 'c1', name: 't', arguments: '{}')],
      );
      msgs[67] = FunctionExecutionResultMessage(results: [
        FunctionExecutionResult(
          id: 'c1',
          name: 't',
          isError: false,
          arguments: '{}',
          content: [TextPart('ok')],
        ),
      ]);
      final state = AgentState(
        sessionId: 's-nouser',
        history: AgentMessageHistory(messages: msgs),
      );

      await c.compress(state);

      final kept = state.history.messages;
      expect(kept.first, isA<UserMessage>(), reason: '说明被插到头部');
      // 保留区若以"带调用的 assistant"开头，其后必须紧跟它的结果（成对）
      final first = kept[1];
      if (first is ModelMessage && first.functionCalls.isNotEmpty) {
        expect(kept[2], isA<FunctionExecutionResultMessage>(),
            reason: '★ 切点不许拆散调用与结果 —— 拆散就是 400');
      }
      expect(c.estimateUsage(state), lessThan(8000));
    });
  });

  group('C5 —— 上下文构成估算（静态入口，2026-10-24）', () {
    test('★★ 消息与工具定义分开估，合计 = 总估算', () {
      final c = compressor(modelWindowTokens: 128000);
      final state = stateWithTools({'name': 'read_file', 'description': '读文件' * 50});
      final msgs = WindowRatioCompressor.estimateMessagesUsage(state);
      final tools = WindowRatioCompressor.estimateToolDefinitions(state);
      expect(msgs, greaterThan(0));
      expect(tools, greaterThan(0));
      expect(msgs + tools, c.estimateUsage(state), reason: '两块相加必须对得上总账');
    });

    test('★★ estimateText：CJK 1 字/token，ASCII 4 字符/token', () {
      expect(WindowRatioCompressor.estimateText('字' * 10), 10);
      expect(WindowRatioCompressor.estimateText('a' * 8), 2);
      expect(WindowRatioCompressor.estimateText(''), 0);
    });

    test('★★ HeraclesAgent.contextBreakdown()：跑一轮后 N2 七键齐全', () async {
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: const Capabilities(),
        client: _RecordingClient(),
      );
      await agent.run('问一句').drain<void>();
      final b = agent.contextBreakdown();
      // N2 契约：固定 7 键，只许新增不许改名
      expect(b.keys, containsAll([
        'system', 'toolDefs', 'toolResults', 'reasoning', 'assistant', 'user', 'summary',
      ]));
      expect(b['system']!, greaterThan(0), reason: 'system 提示必有');
      expect(b['user']!, greaterThan(0), reason: '本轮请求在历史里');
      expect(b['user']!, greaterThan(0), reason: '本轮请求在历史里');
      expect(b['toolDefs']!, greaterThan(0),
          reason: '发过请求就有工具面快照（21 个工具定义是常驻开销）');
      // Σ ≈ 旧三块口径（system + toolDefs + 消息）—— 口径没变，只是拆细了
      final total = b.values.reduce((a, c) => a + c);
      expect(total,
          WindowRatioCompressor.estimateMessagesUsage(agent.state!) +
              WindowRatioCompressor.estimateToolDefinitions(agent.state!) +
              b['system']!,
          reason: '七键之和必须对得上总账（±0，同一套估算器）');
    });
  });
}

/// 取 UserMessage 的文本（断言用）。
String _text(UserMessage m) =>
    m.contents.whereType<TextPart>().map((p) => p.text).join();

/// 记录调用次数的 client 替身 —— **绝不联网**。
///
/// 之所以要一个替身而不是 `null`：压缩器强制要求 `client`，
/// 而"没到阈值"这条本该**一次都不调用**。用替身顺手把这个断言也钉住。
class _RecordingClient implements LLMClient {
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
    return ModelMessage(
      textOutput: '<state_snapshot></state_snapshot>',
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
    return const Stream<StreamingMessage>.empty();
  }
}
