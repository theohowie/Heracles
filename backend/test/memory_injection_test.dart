import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// **长期记忆注入门禁** —— 证明记忆**真的进了 system prompt**。
///
/// ## 为什么这条测试必须有
///
/// 2026-10-23 之前，记忆只有"写"没有"读"：
///
/// | 方向 | 状态 |
/// |---|---|
/// | 写 | `save_memory` → `MemoryCapability.append` → 通道 ✅ |
/// | 读 | `renderMemory()` **全仓 0 处调用** ❌ |
///
/// 这种 bug **不会崩、不会抛、`dart analyze` 也全绿** —— 它只表现为
/// "模型记不住东西，换个会话就失忆"。所以必须有断言：
/// **拿真实 `HeraclesAgent.run()` 跑一遍，看 system 消息里到底有没有记忆原文**。
///
/// ## 为什么断言"在 system 里"而不是"在任意消息里"
///
/// 记忆的语义是**每轮固定的背景事实**，必须进 system —— 若它漏进 user
/// 消息，一来会被当成用户说的话（模型会回应用户"说过"这句话），
/// 二来会挡在历史消息之前破坏 append-only 前缀。
void main() {
  /// 从 client 收到的 messages 里把**所有 system 正文拼起来**。
  ///
  /// 用拼接而不是"取第一条"：框架的 `composeSystemMessage()` 会把
  /// 多个 `SystemPromptPart` `join('\n\n')` 成一条，但**将来可能变**。
  /// 断言"这些文字出现在 system 通道里"比断言"它正好在第 0 条的第 N 个字"
  /// 更稳，也更能表达我们真正关心的事。
  String systemTextOf(_ScriptedClient c, [int index = 0]) {
    return c.calls[index]
        .whereType<SystemMessage>()
        .map((m) => m.content)
        .join('\n\n');
  }

  HeraclesAgent agentWith(LLMClient client, {String? memoryNote}) =>
      HeraclesAgent(
        config: const BackendConfig(apiKey: 'test-key', modelName: 'test-model'),
        capabilities: const Capabilities(),
        client: client,
        options: RunOptions(memoryNote: memoryNote),
      );

  Future<void> runToEnd(HeraclesAgent agent, String request) async {
    await agent.run(request).drain<void>();
  }

  group('memoryNote 注入 system prompt', () {
    test('★★★ 非空 ⇒ system 消息里**包含**记忆原文', () async {
      final client = _ScriptedClient(reply: '好');
      // 一条很具体的项目约定 —— 断言原文出现，而不是断言"某句话出现"
      const note = '- 2026-10-20 — 这个项目用 Flutter，构建走 flutter build apk';

      await runToEnd(agentWith(client, memoryNote: note), '帮我构建');

      final sys = systemTextOf(client);
      expect(sys, contains('这个项目用 Flutter，构建走 flutter build apk'),
          reason: '★ 记忆原文必须出现在 system 里，否则"只写不读"的 bug 没修好');
    });

    test('★★★ 非空 ⇒ system 里有那段标题与行为约束', () async {
      final client = _ScriptedClient(reply: '好');
      await runToEnd(
        agentWith(client, memoryNote: '- 约定一'),
        '随便问点什么',
      );

      final sys = systemTextOf(client);
      expect(sys, contains('## 长期记忆'),
          reason: '要有段落标题，模型才知道这段是"记忆"而不是"用户说的"');
      expect(sys, contains('越早越旧'),
          reason: '要让模型知道记忆有新旧，旧的可能已过时');
      expect(sys, contains('以当前对话为准'),
          reason: '★ 冲突裁决必须写明 —— 否则模型会盲信过时记忆');
    });

    test('★★★ 为 null ⇒ system 里**不含**该段（向后兼容）', () async {
      final client = _ScriptedClient(reply: '好');

      await runToEnd(agentWith(client, memoryNote: null), '帮我构建');

      final sys = systemTextOf(client);
      expect(sys, isNot(contains('## 长期记忆')),
          reason: '不传记忆时不该凭空冒出这一段');
      expect(sys, isNot(contains('越早越旧')));
      // 但基本人设还在（不许因为没记忆就把提示词搞没了）
      expect(sys, contains('你是 Heracles'));
      expect(sys, contains('设备与环境'));
    });

    test('★★★ 记忆很长（10KB）⇒ 仍能正常发，不崩、不截断', () async {
      final client = _ScriptedClient(reply: '好');
      // 造一份 10KB 的记忆（约 500 条中文约定）
      final note = List.generate(
        500,
        (i) => '- 2026-10-2${i % 10} — 第 $i 条项目约定：某个具体的事情要这么做',
      ).join('\n');
      expect(note.length, greaterThan(10 * 1024),
          reason: '测试数据本身要够长（>10KB）');

      await runToEnd(agentWith(client, memoryNote: note), '读一下记忆');

      final sys = systemTextOf(client);
      // ★ 关键：全文都在，**没有被悄悄截断**
      //    （截断会让模型读到半句约定，比没有更危险）
      expect(sys, contains('第 499 条项目约定'),
          reason: '大记忆不许被静默截断 —— 尾巴也要在');
      expect(sys, contains('第 0 条项目约定'));
      expect(sys.length, greaterThan(note.length),
          reason: 'system 长度至少要装得下记忆全文');
    });

    test('★★ 纯空白记忆 ⇒ 不注入（不产生空段落浪费前缀字节）', () async {
      final client = _ScriptedClient(reply: '好');

      await runToEnd(agentWith(client, memoryNote: '   \n\n\t  '), '问个事');

      final sys = systemTextOf(client);
      expect(sys, isNot(contains('## 长期记忆')),
          reason: '全空白记忆注入一个空段落只会改变缓存前缀、不带信息');
    });

    test('★★ 记忆注入在默认提示**之后**（默认提示字节不变，缓存前缀损失最小）', () async {
      final client = _ScriptedClient(reply: '好');
      await runToEnd(agentWith(client, memoryNote: '- 某条约定'), '问');

      final sys = systemTextOf(client);
      final idxDefault = sys.indexOf('你是 Heracles');
      final idxMemory = sys.indexOf('## 长期记忆');
      expect(idxDefault, greaterThanOrEqualTo(0));
      expect(idxMemory, greaterThan(idxDefault),
          reason: '★ 记忆必须在人设**之后**：这样人设那段字节不变，'
              '记忆变化只影响尾部（前缀缓存按最长公共前缀匹配）');
    });

    test('★★ memoryNote 与 systemPrompts 共存，顺序是 默认 → 追加 → 记忆', () async {
      final client = _ScriptedClient(reply: '好');
      final agent = HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: const Capabilities(),
        client: client,
        options: const RunOptions(
          systemPrompts: ['## 宿主的额外提示\n这是宿主加的。'],
          memoryNote: '- 记忆条目',
        ),
      );

      await runToEnd(agent, '问');

      final sys = systemTextOf(client);
      final iDefault = sys.indexOf('你是 Heracles');
      final iExtra = sys.indexOf('宿主的额外提示');
      final iMemory = sys.indexOf('## 长期记忆');
      expect(iDefault, greaterThanOrEqualTo(0));
      expect(iExtra, greaterThan(iDefault), reason: '宿主追加在默认之后');
      expect(iMemory, greaterThan(iExtra), reason: '记忆在最后');
    });
  });

  group('renderMemory —— 渲染格式本身', () {
    test('★★ 空串 / 空白 ⇒ 空串（调用方据此判断"不用注入"）', () {
      expect(renderMemory(''), '');
      expect(renderMemory('   \n\t '), '');
    });

    test('★★ 有内容 ⇒ 带标题 + 行为约束，且原文一字不改', () {
      final out = renderMemory('- 第 1 条\n- 第 2 条');
      expect(out, contains('## 长期记忆'));
      expect(out, contains('- 第 1 条\n- 第 2 条'),
          reason: '原文必须原样保留，不许加工');
      expect(out, contains('不用复述'), reason: '要约束"别背笔记给用户听"');
      expect(out, contains('以当前对话为准'), reason: '要给出冲突裁决规则');
    });
  });

  group('常量一致性（三处必须是同一个数）', () {
    test('★★★ 记忆上限：backend 契约 = 256 KB', () {
      // Kotlin 侧 `MemoryStore.MAX_BYTES` 也是 256*1024。
      // App 侧 `GlobalMemory.maxBytes` 同样是 256*1024。
      // 三处必须一致：不一致会导致"App 以为能写、Kotlin 拒绝"（或反过来）。
      //
      // ⚠️ 这条测试只能钉住 backend 这一处（它跑在 backend 包里，
      //    看不到 App 与 Kotlin）。另两处的一致性靠代码注释 + 人工核对，
      //    这是如实的局限，不是遗漏。
      expect(ContractMemory.maxBytes, 256 * 1024);
      expect(ContractMemory.maxBytes, 262144);
    });
  });
}

/// **脚本化 client** —— 记下每次收到的 messages，返回固定回答。零联网。
class _ScriptedClient implements LLMClient {
  _ScriptedClient({required this.reply});

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
    dynamic cancelToken,
  }) async {
    calls.add(List<LLMMessage>.of(messages));
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
