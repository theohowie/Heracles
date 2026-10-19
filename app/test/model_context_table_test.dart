import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/model_capabilities.dart';
import 'package:heracles/services/model_context_table.dart';

/// **上下文长度解析**的门禁（2026-10-14，第三版）。
///
/// ## 这个文件记录了一次真实的方法论纠错
///
/// | 版本 | 做法 | 用户的批评（原话） |
/// |---|---|---|
/// | 1 | 让用户手填 | 「1M 就是 1M，**不用自己选的**，你觉得这合理吗？」 |
/// | 2 | 我凭印象编内置表 | 「你确定你查的是对的？**deepseek-flash 是支持 1M 的**，还有 kimi k3，也是支持 1M 的，结果呢？」 |
///
/// 第二版**实测错了 2/25** —— 用基元律动公开 API 核实：
///
/// | 模型 | 我编的 | 服务端真实值（权威）|
/// |---|---|---|
/// | `deepseek-flash` | 128K ❌ | **1,000,000** |
/// | `kimi-k3` | 256K ❌ | **1,048,576** |
///
/// **结论**：内置表这条路方法上就不成立（中转站模型名是自家别名，
/// 任何快照表都会错）。**能问就不要猜。**
///
/// ## ⚠️ 2026-10-18（ADR-035 S4）：本地那条路已整体删除
///
/// 原先这里还有 3 条"本地模型用实测确定值（4096）"的用例 —— 本地后端已删，
/// `resolve()` 的 `isLocal` 参数与 `qwen3.5-4b` 表**一起删掉了**。
/// **删掉的不是"负例"，是"被测对象不存在了"**，所以不是覆盖退化。
void main() {
  group('上下文长度解析（服务端优先）', () {
    test('★★ 服务端上报值优先（1M 的模型必须报 1M）', () {
      expect(
        ModelContextTable.resolve(
          fromServer: 1000000,
          modelName: 'deepseek-flash',
          fallback: 128000,
        ),
        1000000,
        reason: '用户实测：服务端说 1M，而我第二版编成 128K —— 这就是 bug',
      );
      expect(
        ModelContextTable.resolve(
          fromServer: 1048576,
          modelName: 'kimi-k3',
          fallback: 128000,
        ),
        1048576,
        reason: '用户实测：kimi-k3 是 1M，我第二版编成 256K',
      );
    });

    test('★ 服务端没报时用兜底（**不假装知道**）', () {
      expect(
        ModelContextTable.resolve(
          fromServer: null,
          modelName: 'some-cloud-model',
          fallback: 128000,
        ),
        128000,
        reason: '拿不到就诚实兜底 —— UI 会标注"未从服务端获取"',
      );
    });

    test('★ 服务端给 0/负数视为未上报（0 会让 ratio 变成无穷大）', () {
      final r = ModelContextTable.resolve(
        fromServer: 0,
        modelName: 'x',
        fallback: 128000,
      );
      expect(r, 128000);
      expect(
        ModelContextTable.resolve(
          fromServer: -1,
          modelName: 'x',
          fallback: 128000,
        ),
        128000,
      );
    });

    // ★ 名称里不能出现"本地"字样后仍断言旧行为 —— 这里补一条
    //   "本地模型名今天也只是一串普通名字"的门禁，钉住"没有本地特判残留"。
    test('★★ 本地模型名不再有特殊待遇（本地后端已删除）', () {
      expect(
        ModelContextTable.resolve(
          fromServer: null,
          modelName: 'qwen3.5-4b',
          fallback: 128000,
        ),
        128000,
        reason: '本地那条 4096 查表已随 ADR-035 删除：'
            '同一个模型名今天必须走云端逻辑（服务端优先 / 诚实兜底）',
      );
      expect(
        ModelContextTable.resolve(
          fromServer: 1000000,
          modelName: 'qwen3.5-4b',
          fallback: 128000,
        ),
        1000000,
        reason: '不再有"本地不采用服务端值"那条分支',
      );
    });
  });

  group('ModelCapabilities 解析（字段名宽容）', () {
    test('★★ 认 OpenAI 标准的 context_length（OpenRouter 等）', () {
      final c = ModelCapabilities.fromJson({'id': 'x', 'context_length': 200000});
      expect(c.contextWindow, 200000);
      expect(c.hasAny, isTrue);
    });

    test('★★ 认基元律动的 contextWindow（实测端点）', () {
      final c = ModelCapabilities.fromJson({
        'id': 'deepseek-flash',
        'contextWindow': 1000000,
        'maxOutputTokens': 384000,
        'supportsTools': true,
        'supportsResponses': true,
        'supportsReasoning': true,
      });
      expect(c.contextWindow, 1000000);
      expect(c.maxOutputTokens, 384000);
      expect(c.supportsTools, isTrue);
      expect(c.supportsResponses, isTrue);
      expect(c.supportsReasoning, isTrue);
      // ★ 未提供的字段必须是 null（"未上报 ≠ false"），
      //   否则会把"服务端没说"误判成"不支持"
      expect(c.supportsVision, isNull);
    });

    test('★ 认 camelCase 与 snake_case 两种写法', () {
      expect(
        ModelCapabilities.fromJson({'context_window': 100}).contextWindow,
        100,
      );
      expect(
        ModelCapabilities.fromJson({'max_completion_tokens': 200})
            .maxOutputTokens,
        200,
      );
    });

    test('★ 什么都没给 → hasAny=false（不占用映射表）', () {
      final c = ModelCapabilities.fromJson({'id': 'x'});
      expect(c.hasAny, isFalse);
      expect(c.contextWindow, isNull);
    });

    test('★ 0/负数不是有效上下文（丢弃而不是当成上限）', () {
      expect(
        ModelCapabilities.fromJson({'context_length': 0}).contextWindow,
        isNull,
      );
      expect(
        ModelCapabilities.fromJson({'context_length': -1}).contextWindow,
        isNull,
      );
    });
  });
}
