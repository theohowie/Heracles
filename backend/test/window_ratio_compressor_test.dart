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
    test('★★★ 128K 窗口 ⇒ 阈值 96000（= 128000 × 0.75）', () {
      final c = compressor(modelWindowTokens: 128000);
      expect(c.triggerThreshold, 96000);
    });

    test('★★★ 换窗口阈值跟着变（自适应才是这个类存在的理由）', () {
      expect(compressor(modelWindowTokens: 200000).triggerThreshold, 150000);
      expect(compressor(modelWindowTokens: 8192).triggerThreshold, 6144);
    });

    test('★★ 阈值向下取整（不能浮点漏成 0.75 个 token）', () {
      // 1000 × 0.75 = 750
      expect(compressor(modelWindowTokens: 1000).triggerThreshold, 750);
      // 1001 × 0.75 = 750.75 ⇒ floor ⇒ 750
      expect(compressor(modelWindowTokens: 1001).triggerThreshold, 750);
    });

    test('★★ 默认参数来自契约常量（不是内联字面量）', () {
      final c = compressor();
      expect(c.compressAtRatio, 0.75);
      expect(c.keepRecentTurns, 6);
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
