import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **Skill 层 e2e**（2026-10-24 接线门禁，S1/S2/S3）。
///
/// 钉住三件事：
///
/// 1. `enableSkills: true` ⇒ 系统提示里有**技能目录**（渐进披露：平时只有
///    一行一条的摘要，全文靠 activate_skills 按需加载）+ `activate_skills` /
///    `deactivate_skills` 工具进工具面；
/// 2. 目录列出的就是 [builtinSkills] 的三条（S1：重复流程已沉淀）；
/// 3. 默认关闭 ⇒ 目录与工具都不在（旧行为不变）。
void main() {
  test('★★★ 开启：目录进 system，activate_skills 进工具面', () async {
    final client = _TextClient('完成。');
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'm'),
      capabilities: const Capabilities(),
      client: client,
      options: RunOptions(maxTurns: 4, enableSkills: true),
    );
    await for (final _ in agent.run('问题')) {}

    // ① 工具面里有 activate_skills / deactivate_skills（框架注入）
    final tools = agent.state!.toolsHistory.last.tools.map((t) => t['name']);
    expect(tools, contains('activate_skills'));
    expect(tools, contains('deactivate_skills'));

    // ② system 提示里有技能目录：三条内置技能的名字都在
    final sys = client.messages.first.whereType<SystemMessage>().single;
    expect(sys.content, contains('verify-loop'));
    expect(sys.content, contains('root-cause-first'));
    expect(sys.content, contains('small-steps'));

    // ③ 目录是"渐进披露"形态：只有摘要，不含全文关键词
    //    （verify-loop 的全文里有"工作流"，目录里不该有 —— 全文要激活才加载）
    expect(sys.content, isNot(contains('连续 3 次修复仍失败')));
  });

  test('★ 默认关闭：目录与工具都不在（旧行为不变）', () async {
    final client = _TextClient('完成。');
    final agent = HeraclesAgent(
      config: const BackendConfig(apiKey: 'k', modelName: 'm'),
      capabilities: const Capabilities(),
      client: client,
    );
    await for (final _ in agent.run('问题')) {}

    final tools = agent.state!.toolsHistory.last.tools.map((t) => t['name']);
    expect(tools, isNot(contains('activate_skills')));
    final sys = client.messages.first.whereType<SystemMessage>().single;
    expect(sys.content, isNot(contains('verify-loop')));
  });

  test('★ 内置技能清单：3 条，名字与触发描述齐全（S1 的沉淀清单）', () {
    final skills = builtinSkills();
    expect(skills.map((s) => s.name).toList(),
        ['verify-loop', 'root-cause-first', 'small-steps']);
    for (final s in skills) {
      expect(s.description, isNotEmpty);
      expect(s.systemPrompt.length, greaterThan(100),
          reason: '${s.name} 的全文要够用（工作流+红线），不是一句话占位');
      expect(s.forceActivate, isFalse,
          reason: '刻意不强制激活 —— 强塞全文就是回到教练式 system prompt 的老路');
    }
  });
}

/// 回固定正文的 client，记录每次收到的 messages。
class _TextClient implements LLMClient {
  _TextClient(this.reply);

  final String reply;
  final List<List<LLMMessage>> messages = [];

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
    return ModelMessage(textOutput: reply, model: modelConfig.model);
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
      StreamingMessage(
        modelMessage: ModelMessage(textOutput: reply, model: modelConfig.model),
      ),
    ]);
  }
}
