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

  // ---------------------------------------------------------------------------
  // 2026-10-29：结构化三作用域（RunOptions.memory）—— 新路径的端到端门禁
  // ---------------------------------------------------------------------------
  MemoryRecord mem(String text, MemoryScope scope) => MemoryRecord(
        id: 'm-${scope.wireName}',
        scope: scope,
        kind: 'other',
        text: text,
        source: MemoryRecord.sourceAgent,
        createdAt: 1,
      );

  HeraclesAgent agentWithMemory(
    LLMClient client, {
    required MemoryContext memory,
    String? memoryNote,
  }) =>
      HeraclesAgent(
        config: const BackendConfig(apiKey: 'k', modelName: 'm'),
        capabilities: const Capabilities(),
        client: client,
        options: RunOptions(memory: memory, memoryNote: memoryNote),
      );

  group('RunOptions.memory（三作用域）⇒ system prompt', () {
    test('★★★ 非空 ⇒ 三段记忆按 global→workspace→session 进 system', () async {
      final client = _ScriptedClient(reply: '好');
      final memory = MemoryContext(
        global: [mem('全局：这个项目用 Flutter', MemoryScope.global)],
        workspace: [mem('工作区：构建走 flutter build apk', MemoryScope.workspace)],
        session: [mem('会话：本轮先跑测试再改代码', MemoryScope.session)],
      );

      await runToEnd(agentWithMemory(client, memory: memory), '帮我构建');

      final sys = systemTextOf(client);
      expect(sys, contains(globalMemorySectionTitle),
          reason: '★ 新路径必须真的接到 _buildSystemPrompts（否则记忆仍然"只写不读"）');
      expect(sys, contains(workspaceMemorySectionTitle));
      expect(sys, contains(sessionMemorySectionTitle));
      expect(sys, contains('这个项目用 Flutter'));
      expect(sys, contains('构建走 flutter build apk'));
      expect(sys, contains('本轮先跑测试再改代码'));

      final iGlobal = sys.indexOf(globalMemorySectionTitle);
      final iWorkspace = sys.indexOf(workspaceMemorySectionTitle);
      final iSession = sys.indexOf(sessionMemorySectionTitle);
      final iDefault = sys.indexOf('你是 Heracles');
      expect(iDefault, greaterThanOrEqualTo(0));
      expect(iGlobal, greaterThan(iDefault), reason: '记忆必须在默认人设之后（缓存尾部）');
      expect(iWorkspace, greaterThan(iGlobal));
      expect(iSession, greaterThan(iWorkspace), reason: '★ session 最后 = 最易变段在尾部');
    });

    test('★★★ memory 非空 ⇒ memoryNote 被忽略（字段非空优先，不回落旧格式）', () async {
      final client = _ScriptedClient(reply: '好');
      final memory = MemoryContext(
        global: [mem('新的全局条目', MemoryScope.global)],
      );

      await runToEnd(
        agentWithMemory(
          client,
          memory: memory,
          memoryNote: '- 旧的一整段记忆（不该出现）',
        ),
        '问',
      );

      final sys = systemTextOf(client);
      expect(sys, contains('新的全局条目'));
      expect(sys, isNot(contains('## 长期记忆')),
          reason: '★ memory 非空时旧单段渲染必须完全让位，否则同一轮出现两份记忆格式');
      expect(sys, isNot(contains('旧的一整段记忆')));
    });

    test('★★ 两者都不传 ⇒ 无任何记忆段（行为与加字段之前一致）', () async {
      final client = _ScriptedClient(reply: '好');
      await runToEnd(agentWith(client, memoryNote: null), '帮我构建');

      final sys = systemTextOf(client);
      for (final title in [
        globalMemorySectionTitle,
        workspaceMemorySectionTitle,
        sessionMemorySectionTitle,
        '## 长期记忆',
      ]) {
        expect(sys, isNot(contains(title)), reason: '不传记忆不该凭空冒出「$title」');
      }
      expect(sys, contains('你是 Heracles'));
    });

    test('★★★ contextBreakdown 的 system 自动包含新记忆段', () async {
      final memory = MemoryContext(
        global: [mem('全局记忆：${'很长的约定' * 40}', MemoryScope.global)],
      );
      final withMemory = _ScriptedClient(reply: '好');
      final without = _ScriptedClient(reply: '好');

      final agentA = agentWithMemory(withMemory, memory: memory);
      await runToEnd(agentA, '问');
      final sysWith = agentA.contextBreakdown()['system']!;

      final agentB = agentWith(without, memoryNote: null);
      await runToEnd(agentB, '问');
      final sysWithout = agentB.contextBreakdown()['system']!;

      expect(sysWith, greaterThan(sysWithout),
          reason: '★ 记忆段是从 _buildSystemPrompts 产出的同一批片段 —— '
              'system 估算必须自动把它算进去（不许漏账）');
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

  group('常量一致性（2026-10-29 重设计后：不再有 256 KB 写闸）', () {
    // ⚠️ **旧断言为什么不再成立**：
    //
    // 旧断言 `ContractMemory.maxBytes == 256*1024` 钉的是"三处同一个写闸数"
    // （backend 契约 / Kotlin `MAX_BYTES` / App `GlobalMemory.maxBytes`）。
    // 重设计**删除了 maxBytes**：存储上限变成"按作用域的软预算 + 超限淘汰"，
    // 且存储与注入预算彻底分家（设计稿 §3.4）。那个数已无对象，断言它只会
    // 挡住正确结构 —— 所以改为断言**新契约的对外承诺**：存在分 scope 的软预算、
    // 且存在可被 min 截住的注入预算常量。
    //
    // ⚠️ 局限（如实记录）：这条仍只能钉 backend 这一处；Kotlin/App 两侧的
    //    同源一致性靠 INTERFACE.md §N12 + 人工核对。

    test('★★★ 存储软预算按作用域存在，且合计 = 三者之和', () {
      expect(ContractMemory.storageGlobalSoftMaxBytes, 8 * 1024 * 1024);
      expect(ContractMemory.storageWorkspaceSoftMaxBytes, 16 * 1024 * 1024);
      expect(ContractMemory.storageSessionSoftMaxBytes, 512 * 1024);
      expect(
        ContractMemory.storageSoftMaxBytes,
        ContractMemory.storageGlobalSoftMaxBytes +
            ContractMemory.storageWorkspaceSoftMaxBytes +
            ContractMemory.storageSessionSoftMaxBytes,
      );
    });

    test('★★★ 注入预算两段：session 独立且小于 global+workspace', () {
      expect(ContractMemory.globalWorkspaceInjectMaxChars, 6000);
      expect(ContractMemory.sessionInjectMaxChars, 4000);
      expect(ContractMemory.sessionInjectMaxChars,
          lessThan(ContractMemory.globalWorkspaceInjectMaxChars));
      expect(ContractMemory.windowRatioCap, 0.05);
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
