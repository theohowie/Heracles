import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **压缩 e2e 门禁** —— 证明"压缩后任务继续"，以及两个只在压缩时才现形的假信息 bug。
///
/// ## 这个文件为什么会存在
///
/// 上下文压缩是**唯一一类"平时完全看不出问题"的代码**：
///
/// - 不压缩时，所有路径都正常，`dart analyze` 全绿、测试全过；
/// - 一旦压缩真的发生，`state.history.messages` 被**原地改写**，
///   于是"结束时倒扫历史找最终回答"这类写法会同时踩两个坑：
///
/// 1. **历史被截短** ⇒ `turnStartIndex >= msgs.length` ⇒ 最终回答变**空**；
/// 2. **框架往头部插了 ack**（`"Got it. Thanks for the additional context!"`）
///    ⇒ 倒扫把它当成模型回答 ⇒ 用户看到一句莫名其妙的英文。
///
/// 这两个 bug 的共同点是：**只在压缩发生过的那一轮里出现**。
/// 所以必须有测试**真的把压缩跑起来**，而不是只测阈值算术。
///
/// ## 怎么让压缩真的发生（关键，别猜）
///
/// 框架 `LLMBasedContextCompressor.compress` 有**三重早退**：
/// 1. `state.usages.isEmpty` ⇒ 返回（必须有**已完成的模型调用**）
/// 2. `messages.length <= keepRecentMessageSize` ⇒ 返回（消息要够多）
/// 3. `usages.last.promptTokens < totalTokenThreshold` ⇒ 返回
///
/// ⇒ 测试必须：跑够多轮（让 usages 有值、消息足够多），
/// 且**真实 promptTokens 要过阈值**。
///
/// 而 `promptTokens` 是 provider 上报的 —— 我们的脚本 client 自己造。
/// 所以这里让脚本 client 在 `usage` 里**报一个大数**，从而稳定触发压缩。
void main() {
  /// 脚本化 client：按脚本逐轮返回，并记录每次收到的 messages。
  ///
  /// [reportedPromptTokens] 决定"假装 provider 报了多少 prompt token"，
  /// 这是**触发框架压缩的必要条件**（见文件头第 3 条早退）。
  _ScriptedClient scripted({
    String finalReply = '这是最终回答。',
    int reportedPromptTokens = 999999,
    int toolRounds = 30,
  }) =>
      _ScriptedClient(
        finalReply: finalReply,
        reportedPromptTokens: reportedPromptTokens,
        toolRounds: toolRounds,
      );

  /// 造一个 agent，窗口极小（让压缩容易触发）。
  HeraclesAgent agentWith(
    LLMClient client, {
    int windowTokens = 2000,
    int maxTurns = 12,
  }) =>
      HeraclesAgent(
        config: BackendConfig(
          apiKey: 'k',
          modelName: 'm',
          modelWindowTokens: windowTokens,
        ),
        capabilities: const Capabilities(),
        client: client,
        options: RunOptions(maxTurns: maxTurns, maxToolCalls: 50),
      );

  group('压缩真的发生', () {
    test('★★★ 多轮 + 大 usage ⇒ 触发压缩，并播 HeraclesContextCompressed', () async {
      // 40 轮回复（够多，保证消息数超过 keepRecentMessageSize=24）
      final client = scripted(finalReply: '这是一段足够长的正文内容。');
      final agent = agentWith(client, windowTokens: 2000, maxTurns: 40);

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('开始一个长任务')) {
        events.add(e);
      }

      final compressed = events.whereType<HeraclesContextCompressed>().toList();
      expect(compressed, isNotEmpty,
          reason: '★★★ 必须至少压缩过一次（否则本文件的其余断言都没意义）\n'
              '实际情况：跑了 ${client.calls} 次模型调用，'
              '最终消息数 ${agent.state?.history.messages.length}');

      final first = compressed.first;
      // 事件字段必须是压缩前后的**真实快照**，不是占位
      expect(first.beforeMessages, greaterThan(0));
      expect(first.afterMessages, greaterThan(0));
      expect(first.beforeTokens, greaterThan(0));
      // 压缩后条数必须真的变少（否则不该播这个事件）
      expect(first.afterMessages, lessThan(first.beforeMessages),
          reason: '播了事件就说明历史真的变短了（before=${first.beforeMessages}, '
              'after=${first.afterMessages}）');
    });
  });

  group('★★★ 压缩后任务继续（用户核心诉求）', () {
    test('★★★ 压缩发生后 run 仍正常结束（收到 HeraclesFinished）', () async {
      final client = scripted(finalReply: '继续工作。');
      final agent = agentWith(client, windowTokens: 2000, maxTurns: 40);

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('跑一个会被压缩的长任务')) {
        events.add(e);
      }

      // ① 压缩真的发生过
      expect(events.whereType<HeraclesContextCompressed>(), isNotEmpty,
          reason: '前提：必须压缩过');

      // ② run 正常结束（不是 HeraclesFailed）
      expect(events.whereType<HeraclesFailed>(), isEmpty,
          reason: '压缩不该让 run 失败');
      expect(events.whereType<HeraclesFinished>(), hasLength(1),
          reason: '★ 压缩后任务必须能继续跑完 —— 这正是用户要的"哪怕跑到一半"');
    });

    test('★★★ 最终回答是模型真实回复，**不是**压缩 ack 那句英文', () async {
      // 模型每轮都说这句明确的正文
      const realReply = '我已经把文件改好了，请查看。';
      final client = scripted(finalReply: realReply);
      final agent = agentWith(client, windowTokens: 2000, maxTurns: 40);

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('改一下文件')) {
        events.add(e);
      }

      expect(events.whereType<HeraclesContextCompressed>(), isNotEmpty,
          reason: '前提：必须压缩过（否则测不到这个 bug）');

      final finished = events.whereType<HeraclesFinished>().single;
      // ③ ★ 最终回答必须是真实回复
      expect(finished.finalText, realReply,
          reason: '★ 压缩后 finalText 必须是模型真实回答，实际：${finished.finalText}');
      // ④ ★★ 反向断言：绝不能是框架的 ack 文案
      expect(finished.finalText, isNot(contains('Thanks for the additional context')),
          reason: '★★ 这是框架压缩时插的 ack，把它当回答显示 = 假信息');
      expect(finished.finalText, isNot(contains('Got it')),
          reason: '同上');
      // 更不能是空的（那说明越界守卫把 answer 吃掉了）
      expect(finished.finalText.trim(), isNotEmpty,
          reason: '★★ 压缩后 finalText 变空 = 那个越界 bug 复发了');
    });
  });

  group('★★ 压缩后历史被截短时 finalText 仍正确（回归越界 bug）', () {
    test('★★★ 压缩使 messages 短于 turnStartIndex 时，finalText 依然正确', () async {
      const realReply = '这是本轮的正确答案。';
      final client = scripted(finalReply: realReply);
      final agent = agentWith(client, windowTokens: 2000, maxTurns: 40);

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('长任务')) {
        events.add(e);
      }

      final compressed = events.whereType<HeraclesContextCompressed>().toList();
      expect(compressed, isNotEmpty, reason: '前提：必须压缩过');

      final finished = events.whereType<HeraclesFinished>().single;

      // ## 这条断言为什么能证明越界 bug 被修好
      //
      // 旧实现：`_lastText(agent, turnStartIndex)` 在压缩后
      // `startIndex >= msgs.length` ⇒ 直接 `return ''`。
      // 而现在 finalText 有正确的正文 ⇒ 说明走的是**事件捕获**主路径，
      // 不依赖 `state.history` 的形状。
      expect(finished.finalText, realReply,
          reason: '★ 压缩后历史长度与 turnStartIndex 的关系已不可信，'
              '必须走 AfterCallLLMEvent 捕获路径');
      expect(finished.finalText.trim(), isNotEmpty);
    });

    test('★★ 压缩发生了不止一次也照样正确（反复截短）', () async {
      const realReply = '多次压缩后仍然正确。';
      final client = scripted(finalReply: realReply, toolRounds: 50);
      final agent = agentWith(client, windowTokens: 1500, maxTurns: 60);

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('很长很长的任务')) {
        events.add(e);
      }

      final compressed = events.whereType<HeraclesContextCompressed>().toList();
      expect(compressed.length, greaterThanOrEqualTo(1));

      final finished = events.whereType<HeraclesFinished>().single;
      expect(finished.finalText, realReply,
          reason: '压缩 ${compressed.length} 次后仍要给对答案');
    });
  });

  group('低于阈值不压缩（向后兼容）', () {
    test('★★★ usage 很小 ⇒ 不播压缩事件、delegate 不发摘要请求', () async {
      // reportedPromptTokens 远低于阈值 ⇒ 框架 delegate 自己就会早退
      final client = scripted(
        finalReply: '短回答',
        reportedPromptTokens: 10,
        toolRounds: 8,
      );
      // 窗口 128K，阈值 102400 ⇒ 10 token 差得远
      final agent = agentWith(client, windowTokens: 128000, maxTurns: 10);

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('短任务')) {
        events.add(e);
      }

      expect(events.whereType<HeraclesContextCompressed>(), isEmpty,
          reason: '没到 80% 不许压缩');
      expect(events.whereType<HeraclesFinished>(), hasLength(1));
    });

    test('★★ 单轮任务（消息不够多）不压缩', () async {
      final client = scripted(finalReply: '一次就答完', toolRounds: 0);
      final agent = agentWith(client, windowTokens: 2000, maxTurns: 3);

      final events = <HeraclesEvent>[];
      await for (final e in agent.run('简单问题')) {
        events.add(e);
      }

      expect(events.whereType<HeraclesContextCompressed>(), isEmpty);
    });
  });
}

/// 脚本化 client：前 N 轮**请求工具**（把任务拉长），最后一轮给正文。
///
/// ## 为什么必须"请求工具"才跑得动多轮（这是踩过的坑）
///
/// 我第一版让 client 每轮都只回纯文本 —— 结果**只跑了 1 轮就结束**：
/// 框架看到不带 `functionCalls` 且 `stopReason=stop` 的模型消息，就认定
/// "模型给出最终回答了"，run 立刻收尾。
///
/// ⇒ 消息数永远只有 2 条（user + assistant），`LLMBasedContextCompressor`
/// 的第 2 个早退条件（`messages.length <= keepRecentMessageSize`）恒成立，
/// **压缩一次都不可能发生**。
///
/// 正确做法（照抄 `agent_run_e2e_test.dart` 的已验证写法）：
/// 回 `functionCalls` + `stopReason: 'tool_calls'` ⇒ 框架执行工具、
/// 进下一轮 ⇒ 历史才长得起来。
///
/// ## [reportedPromptTokens] 为什么必须能造
///
/// 框架压缩的另一个条件是 `usages.last.promptTokens >= totalTokenThreshold`，
/// 而 `promptTokens` **只能由 provider（这个替身）上报**。
/// 不造大数就永远压不了 —— 这是"怎么让压缩真的发生"的关键。
class _ScriptedClient implements LLMClient {
  _ScriptedClient({
    required this.finalReply,
    required this.reportedPromptTokens,
    this.toolRounds = 30,
  });

  /// 最后一轮（不带工具）给出的正文 —— 也就是"最终回答"。
  final String finalReply;

  final int reportedPromptTokens;

  /// 前多少轮请求工具（把历史拉长到足以触发压缩）。
  final int toolRounds;

  /// 工具轮每轮附带的正文 —— **用来把上下文估算值撑过阈值**。
  ///
  /// 为什么不靠 `reportedPromptTokens` 撑：那个数只影响**框架 delegate** 的
  /// 判断（`usages.last.promptTokens < totalTokenThreshold` 早退），
  /// 而**我们这层**（`WindowRatioCompressor.compress` 的 `_estimateUsage`）
  /// 只看 `state.history` 里的真实文本。两层都要过，缺一不可。
  ///
  /// 40 次重复 ⇒ 约 800 个汉字 ≈ 800 token/轮，30 轮约 24K token，
  /// 足够越过 2000×0.8=1600 的阈值（实测稳定触发）。
  final String filler = '这是一段很长的正文内容用来把上下文撑大。' * 40;

  int calls = 0;

  /// 每次收到的 messages（排障用）。
  final List<int> messageCounts = [];

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
    messageCounts.add(messages.length);
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
    calls++;
    messageCounts.add(messages.length);
    return Stream<StreamingMessage>.fromIterable([
      StreamingMessage(modelMessage: _reply(modelConfig)),
    ]);
  }

  ModelMessage _reply(ModelConfig modelConfig) {
    final usage = ModelUsage(
      promptTokens: reportedPromptTokens,
      completionTokens: 10,
      totalTokens: reportedPromptTokens + 10,
    );

    // 前 toolRounds 轮：请求 list_files（安全、无副作用、一定成功）
    //
    // ⚠️⚠️ **参数必须每轮不同**，否则会被框架的 `DefaultLoopDetector` 判成
    // "模型反复请求相同的操作"并抛 `AgentException(loopDetection)` ——
    // run 直接失败（实测：同样的 `{"path":"."}` 只撑了 5 轮就被停）。
    //
    // 这是踩过的坑：我第一版每轮都发 `{"path":"."}`，测试里一个
    // `HeraclesFinished` 都收不到，全是 `HeraclesFailed("检测到循环")`。
    // 用 `sub-$n` 这种不存在的目录即可 —— `list_files` 失败也会把结果回填进
    // 历史（同样把消息数拉长），而我们要的只是"历史变长"。
    //
    // ⚠️⚠️ **每轮还要带一段长正文**（[filler]），否则估算值撑不到阈值：
    //
    // 我们的 `_estimateUsage` 只看 `state.history` 里的文本，而工具调用轮
    // 本身的正文很短（几乎只有参数）。实测：30 轮工具调用、不带 filler 时
    // 估算只有约 2000 token，永远到不了 2000×0.8=1600 之上的压缩窗口
    // （`keepRecentMessageSize=24` 也要求历史够长）。
    // 加 filler 后实测稳定触发（27->26 条，14038->14028 token）。
    if (calls <= toolRounds) {
      return ModelMessage(
        model: modelConfig.model,
        stopReason: 'tool_calls',
        usage: usage,
        textOutput: filler,
        functionCalls: [
          FunctionCall(
            id: 'call-$calls',
            name: 'list_files',
            arguments: '{"path":"probe-dir-$calls"}',
          ),
        ],
      );
    }

    // 之后：给正文 ⇒ 框架收尾
    return ModelMessage(
      textOutput: finalReply,
      model: modelConfig.model,
      stopReason: 'stop',
      usage: usage,
    );
  }
}
