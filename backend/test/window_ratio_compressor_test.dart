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
    test('★★★ 128K 窗口 ⇒ 阈值 108800（= 128000 × 0.85）', () {
      final c = compressor(modelWindowTokens: 128000);
      expect(c.triggerThreshold, 108800);
    });

    test('★★★ 85% 是现任强制线的比例（2026-11-04 用户确认从 0.80 上调）', () {
      // 用户在真机 120% 事故后确认：摘要 60% / 强制重置 85% / 发送硬顶 90%。
      expect(ContractCompression.compressAtRatio, 0.85);
      expect(ContractCompression.sendCeilingRatio, 0.90);
    });

    test('★★★ 换窗口阈值跟着变（自适应才是这个类存在的理由）', () {
      expect(compressor(modelWindowTokens: 200000).triggerThreshold, 170000);
      expect(compressor(modelWindowTokens: 8192).triggerThreshold, 6963,
          reason: '8192 × 0.85 = 6963.2 ⇒ floor 6963');
    });

    test('★★ 阈值向下取整（不能浮点漏成 0.85 个 token）', () {
      // 10000 × 0.85 = 8500（整数）
      expect(compressor(modelWindowTokens: 10000).triggerThreshold, 8500);
      // 10001 × 0.85 = 8500.85 ⇒ floor ⇒ 8500
      expect(compressor(modelWindowTokens: 10001).triggerThreshold, 8500);
      // 10005 × 0.85 = 8504.25 ⇒ floor ⇒ 8504
      expect(compressor(modelWindowTokens: 10005).triggerThreshold, 8504);
    });

    test('★★ 默认参数来自契约常量（不是内联字面量）', () {
      final c = compressor();
      expect(c.compressAtRatio, ContractCompression.compressAtRatio);
      expect(c.compressAtRatio, 0.85);
      expect(c.keepRecentTurns, 6);
    });
  });

  group('窗口 10000 的边界：micro 线 4000 / 强制线 8500', () {
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

    test('★★★ 3999 token < micro 线 4000 ⇒ 既不清理也不摘要（一次都不调）', () async {
      final client = _RecordingClient();
      var compressed = 0;
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
        onCompressed: (_, __, ___, ____) => compressed++,
      );

      final state = stateWithTokens(3999);
      final usage = c.estimateUsage(state);
      // 正好 3999（汉字 1:1，没有 ceil 误差）
      expect(usage, 3999, reason: '构造必须精确：实际 $usage');
      expect(usage, lessThan((10000 * ContractCompression.microRatio).floor()));

      final before = client.calls;
      await c.compress(state);

      expect(compressed, 0, reason: '没到阈值不许触发压缩事件');
      expect(client.calls, before, reason: '没到阈值连摘要请求都不该发');    });

    test('★★★ 8500 token = 阈值 ⇒ 放行到摘要', () async {
      final client = _RecordingClient();
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );

      final state = stateWithTokens(8500);
      final usage = c.estimateUsage(state);
      expect(usage, 8500, reason: '构造必须精确：实际 $usage');
      expect(c.triggerThreshold, 8500);
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
  // 单阈值 + 一次性流水线（2026-11-06）
  //
  // ⚠️ 本组**替换**了旧的"micro 在 40% 触发"用例：那个行为已被用户删除
  //（真机实测：每轮在 40% 线上改写历史中段 ⇒ 缓存命中率只有 40%~48%）。
  // 现在的契约是"**不到 0.85 线一个字节都不动**；到线才在同一个压缩事件里
  // 跑一次 micro"。断言比旧版更严：旧版只能证明"40% 会动"，新版同时证明
  // "**40%~85% 之间绝不动**"（这才是缓存命中的命门）。
  // ==========================================================================
  group('单阈值 —— 85% 以下零副作用，到线才在事件内跑一次 micro', () {
    /// 造一个"估算落在 [8500 以上] 且中段有一条大工具结果"的 state。
    ///
    /// 33 条消息 > 保护窗 24 ⇒ 大结果（index 1）在保护窗外，micro 才碰得到。
    AgentState stateWithOldBigResult({int fillerTokens = 150}) => AgentState(
          sessionId: 's-micro-once',
          history: AgentMessageHistory(messages: [
            UserMessage.text('读文件'), // 3 token
            FunctionExecutionResultMessage(results: [
              FunctionExecutionResult(
                id: 'call-1',
                name: 'read_file',
                isError: false,
                arguments: '{"path":"a.txt"}',
                content: [TextPart('内' * 4500)], // 4500 token
              ),
            ]),
            for (var i = 0; i < 31; i++) UserMessage.text('字' * fillerTokens),
          ]),
        );

    test('★★★ 40%~85% 之间 ⇒ 历史与字节完全不变、零 LLM 调用、不播事件', () async {
      final client = _RecordingClient();
      var notified = 0;
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000, // 触发线 = 8500
        onCompressed: (_, __, ___, ____) => notified++,
      );
      // 3 + 4509 + 31×50 ≈ 6062 个汉字 ⇒ ≈6062 token（> 40% 线 4000，< 85% 线 8500）
      final state = stateWithOldBigResult(fillerTokens: 50);
      final before = c.estimateUsage(state);
      expect(before, greaterThan((10000 * 0.40).floor()),
          reason: '构造必须超过旧的 40% 线 —— 否则证明不了"不开小差"');
      expect(before, lessThan((10000 * 0.85).floor()),
          reason: '构造必须低于触发线，实际 $before');
      final beforeMessages = List<LLMMessage>.of(state.history.messages);
      final beforeBytes = beforeMessages
          .map((m) => WindowRatioCompressor.estimateMessageTokens(m))
          .toList();

      await c.compress(state);

      expect(client.calls, 0, reason: '★ 没到线一次模型调用都不许发出');
      expect(notified, 0, reason: '★ 没到线不许播"压缩了"');
      expect(state.history.messages.length, beforeMessages.length,
          reason: '★★ 条数必须一条不差');
      expect(
        state.history.messages
            .map((m) => WindowRatioCompressor.estimateMessageTokens(m))
            .toList(),
        beforeBytes,
        reason: '★★ 逐条 token 必须一模一样 —— 否则前缀缓存这一轮全废',
      );
      expect(c.lastCompaction, isNull, reason: '没压缩就不该有事件');
    });

    test('★★★ 到线 ⇒ micro 在同一事件内跑一次：只清"较旧"的，保留最近 10 条', () async {
      final client = _RecordingClient();
      var notified = 0;
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
        onCompressed: (_, __, ___, ____) => notified++,
      );

      // 20 条白名单工具结果（各 400 token）+ 25 条填充消息 = 65 条：
      // · 65 - 24（保护窗）= 41 ⇒ 工具结果在索引 2..40，全部落在保护窗外；
      // · 保留最近 `microKeepRecentToolResults`(10) 条 ⇒ 最旧 10 条被清；
      // · 估算 ≈ 8000 + 1000 ≈ 9000 ≥ 8500（到线），清完 ≈ 5100（达标即停）。
      final results = <FunctionExecutionResult>[
        for (var i = 0; i < 20; i++)
          FunctionExecutionResult(
            id: 'call-$i',
            name: 'read_file',
            isError: false,
            arguments: '{"path":"f$i.txt"}',
            content: <UserContentPart>[TextPart('内' * 400)],
          ),
      ];
      final msgs = <LLMMessage>[UserMessage.text('开始')];
      for (final r in results) {
        msgs
          ..add(ModelMessage(model: 'm', functionCalls: [
            FunctionCall(id: r.id, name: r.name, arguments: r.arguments),
          ]))
          ..add(FunctionExecutionResultMessage(results: [r]));
      }
      for (var i = 0; i < 25; i++) {
        msgs.add(UserMessage.text('字' * 40));
      }
      final state =
          AgentState(sessionId: 's-micro-once', history: AgentMessageHistory(messages: msgs));

      final before = c.estimateUsage(state);
      expect(before, greaterThanOrEqualTo(c.triggerThreshold),
          reason: '构造必须到线，实际 $before');

      await c.compress(state);

      expect(client.calls, 0, reason: '★ micro 是确定性的，一次 LLM 都不该调');
      expect(notified, 1, reason: '确有清理 ⇒ 播一次事件');
      expect(c.lastCompaction?.layersRun, <CompactionLayer>[CompactionLayer.micro],
          reason: '只跑阶段 1 就达标（剩下的层不该再动历史）');

      final kept = state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .toList();
      expect(kept, hasLength(20), reason: 'micro 不删消息，只换内容');
      for (var i = 0; i < 10; i++) {
        final text = kept[i].results.single.content
            .whereType<TextPart>()
            .map((p) => p.text)
            .join();
        expect(text, ContractCompaction.clearedToolResultPlaceholder,
            reason: '第 $i 条是最旧的 10 条之一，必须被清');
      }
      for (var i = 10; i < 20; i++) {
        final text = kept[i].results.single.content
            .whereType<TextPart>()
            .map((p) => p.text)
            .join();
        expect(text, '内' * 400,
            reason: '第 $i 条属于"最近 10 条"，必须原样保留（模型马上要用）');
      }
      // 记账：能指回原 id 与原字符数（可追溯，原始内容没被删）
      expect(c.clearedRefs.length, 10);
      expect(c.clearedRefs['call-0']?.originalChars, 400);
      expect(c.clearedRefs['call-0']?.kind, ClearedKind.toolResult);
      expect(c.clearedRefs.containsKey('call-19'), isFalse,
          reason: '最近的那条不该有清理记录');
      expect(c.estimateUsage(state), lessThan(before), reason: 'token 必须真的降了');
      expect(c.estimateUsage(state), lessThan(c.triggerThreshold),
          reason: '压完必须低于触发线 —— 否则下一轮立刻又压');
    });

    test('★★ 保护窗内的工具结果绝不清理（模型马上要用）', () async {
      final client = _RecordingClient();
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
      );
      // ⚠️ 窗内必须有 **> microKeepRecentToolResults(10)** 条白名单工具结果，
      //   否则"保留最近 10 条"会替保护窗兜住，这条断言就测不到保护窗本身。
      //   这里 12 条工具结果全在最近 24 条里 ⇒ 一条都不许动。
      final state = AgentState(
        sessionId: 's-tail',
        history: AgentMessageHistory(messages: [
          for (var i = 0; i < 20; i++) UserMessage.text('字' * 300),
          for (var i = 0; i < 12; i++)
            FunctionExecutionResultMessage(results: [
              FunctionExecutionResult(
                id: 'call-$i',
                name: 'read_file',
                isError: false,
                arguments: '{}',
                content: <UserContentPart>[TextPart('内' * 400)],
              ),
            ]),
        ]),
      );
      final before = c.estimateUsage(state);
      expect(before, greaterThanOrEqualTo(8500), reason: '前提：到线');

      await c.compress(state);

      final results = state.history.messages
          .whereType<FunctionExecutionResultMessage>()
          .toList();
      expect(results, hasLength(12));
      for (final m in results) {
        expect(_partsTextOfOwner(m), '内' * 400,
            reason: '★ 保护窗内的工具结果不许清（12 条全都得原样）');
      }
      expect(c.clearedRefs, isEmpty, reason: '保护窗内的东西不该有任何清理记录');
    });
  });

  group('兜底 —— 阶段 2 不可用时的确定性强制重置', () {
    test('★★★ 摘要静默失败 + 估算 ≥85% ⇒ 整批丢弃老轮次 + 插如实说明', () async {
      // ★ 这段测的是"**摘要失败**时兜底仍成立"。
      //   2026-11-06 起必须显式关掉 Session Memory：否则阶段 2（纯本地规则）
      //   就能把这 96 条用户消息收进摘要视图，压根不会调模型 ——
      //   那是设计意图（省钱），但会让本用例测不到兜底路径。
      final client = _EmptySummaryClient();
      var notified = 0;
      final c = WindowRatioCompressor(
        client: client,
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
        compactionConfig: const CompactionConfig(sessionMemoryEnabled: false),
        onCompressed: (_, __, ___, ____) => notified++,
      );
      // 96 批 × 90 token ≈ 8640 ≥ 8500（触发线 0.85）。
      // 摘要失败 ⇒ 只能靠确定性兜底。
      final state = AgentState(
        sessionId: 's-full',
        history: AgentMessageHistory(
          messages: [
            for (var i = 0; i < 96; i++) UserMessage.text('字' * 90),
          ],
        ),
      );

      await c.compress(state);

      expect(client.calls, greaterThan(0), reason: '确实发起过摘要调用（只是返回空）');
      expect(state.history.messages.length, 7,
          reason: '说明 1 条 + 最近 6 批');
      final note = state.history.messages.first as UserMessage;
      expect(_text(note), contains('[系统维护]'));
      expect(_text(note), contains('90'),
          reason: '如实报丢弃条数，绝不假装"已摘要"');
      expect(c.estimateUsage(state), lessThan(8500),
          reason: '★ 重置后必须低于触发线 —— 这就是"必压缩"的兜底');
      expect(notified, greaterThanOrEqualTo(1), reason: '兜底生效必须播报');
      expect(c.lastCompaction?.failureReason, isNotNull,
          reason: '摘要失败必须在事件里留原因（不许静默）');
    });

    test('★★ 无 user 边界的历史也能重置（切点不拆工具批）', () async {
      // 纯 assistant 历史（长工具链）+ 摘要失败 ⇒ 走 _forceReset 的
      // "没有批次边界"分支：按条数找切点，再调整到不拆调用/结果。
      final c = WindowRatioCompressor(
        client: _EmptySummaryClient(),
        modelConfig: ModelConfig(model: 'stub'),
        modelWindowTokens: 10000,
        compactionConfig: const CompactionConfig(sessionMemoryEnabled: false),
      );
      // 66 号位置放一对调用+结果
      final msgs = <LLMMessage>[
        for (var i = 0; i < 96; i++)
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
      expect(c.estimateUsage(state), lessThan(8500),
          reason: '重置后必须低于触发线');
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
      // ★ 2026-11-05 新口径（用户指定按"系统提示词/工具定义/用户消息/注入内容/
      //   技能注入/工具结果/助手消息"拆）：七类必须是主角，旧键只作兼容别名。
      expect(b.keys, containsAll([
        'systemPrompt', 'toolDefs', 'user', 'injected', 'skills',
        'toolResults', 'assistant',
      ]));
      // ★ 2026-11-05：**旧别名 system 已删除**（它会被前端合并成「其他」⇒ 重复计数）
      expect(b.containsKey('system'), isFalse,
          reason: 'system 别名会让屏上出现「系统提示词 + 其他」两份，必须不发');
      expect(b.keys, containsAll(['reasoning', 'summary']));

      expect(b['systemPrompt']!, greaterThan(0), reason: '人设与环境必有');
      expect(b['toolDefs']!, greaterThan(0),
          reason: '发过请求就有工具面快照（常驻开销）');
      expect(b['user']!, greaterThan(0), reason: '本轮请求在历史里');
      // 技能注入：本用例没开技能 ⇒ 0（不许凭空编一个数）
      expect(b['skills'], 0);

      // ① 七类互斥：systemPrompt 只含基础人设，不含注入/技能
      expect(b['systemPrompt']!, lessThan(
          WindowRatioCompressor.estimateText(defaultSystemPrompt(const Capabilities())) + 500),
          reason: 'systemPrompt 若把注入/技能也算进来就是重复计数');

      // ② 七类之和 == 旧口径总账（同一套估算器，±0）
      final seven = b['systemPrompt']! +
          b['toolDefs']! +
          b['user']! +
          b['injected']! +
          b['skills']! +
          b['toolResults']! +
          b['assistant']!;
      expect(seven,
          WindowRatioCompressor.estimateMessagesUsage(agent.state!) +
              WindowRatioCompressor.estimateToolDefinitions(agent.state!) +
              b['systemPrompt']! +
              b['injected']! +
              b['skills']!,
          reason: '七类之和必须对得上总账（拆细≠重复计数）');
    });
  });
}

/// 取 UserMessage 的文本（断言用）。
String _text(UserMessage m) =>
    m.contents.whereType<TextPart>().map((p) => p.text).join();

/// 取单条工具结果消息的文本（断言用）。
String _partsTextOfOwner(FunctionExecutionResultMessage m) =>
    m.results.single.content.whereType<TextPart>().map((p) => p.text).join();

/// **摘要一律失败**的 client（返回空文本 ⇒ 结构化摘要判为"没做成"）。
///
/// 用途：证明第三级"强制重置"在**摘要失败**时仍然兜底。
class _EmptySummaryClient extends _RecordingClient {
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
    return ModelMessage(textOutput: '', model: modelConfig.model);
  }
}

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
