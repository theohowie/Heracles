/// **记忆工具门禁**（2026-10-29 三作用域重设计）。
///
/// ## 每个用例抓什么缺陷（设计稿 §五测试表 6 条）
///
/// | # | 用例 | 抓的缺陷 |
/// |---|---|---|
/// | ① | `save_memory` 默认写 session | 默认写错作用域（写成全局会污染所有会话） |
/// | ② | `scope: workspace` 走 workspace | 参数被吞/映射错作用域 |
/// | ③ | `scope: global` 被拒并指路 | agent 直写全局（不变量 I4） |
/// | ④ | `propose_global_memory` 调 `proposeGlobal` | 新工具没接线 / 调错方法 |
/// | ⑤ | SEC4 仍拒密钥 | 新增写入路径绕过密钥闸（不变量 I8） |
/// | ⑥ | 工具总数 = 33 | 新增工具忘登记（工具面与文档/测试漂移） |
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

import 'support/tool_result.dart';

/// 记录调用的记忆能力替身（`extends`：继承新增作用域方法的默认实现，
/// 但这里覆盖成可观测的记账版本）。
class _RecordingMemory extends MemoryCapability {
  final List<({MemoryScope scope, String note, String kind})> appends = [];
  final List<({String note, String kind})> proposals = [];

  @override
  Future<String> read() async => '';

  @override
  Future<CapabilityResult> append(String note) async {
    appends.add((scope: defaultWriteScope, note: note, kind: 'other'));
    return const CapabilitySuccess('saved(legacy)');
  }

  @override
  Future<CapabilityResult> appendScoped(
    MemoryScope scope,
    String note, {
    String kind = 'other',
  }) async {
    if (scope == MemoryScope.global) {
      return const CapabilityFailure('全局记忆只读', isRetryable: false);
    }
    appends.add((scope: scope, note: note, kind: kind));
    return CapabilitySuccess('已写入 ${scope.wireName}');
  }

  @override
  Future<CapabilityResult> proposeGlobal(
    String note, {
    String kind = 'other',
  }) async {
    proposals.add((note: note, kind: kind));
    return const CapabilitySuccess('已记录为候选，等待用户在记忆页确认');
  }
}

/// 老宿主替身：**只实现 read/append**（升级前的全部实现面）。
///
/// 用来钉"新增的四个方法都有默认实现、老宿主不改也能编译并退化"。
class _LegacyMemory extends MemoryCapability {
  final appended = <String>[];

  @override
  Future<String> read() async => 'legacy-raw';

  @override
  Future<CapabilityResult> append(String note) async {
    appended.add(note);
    return const CapabilitySuccess('saved');
  }
}

void main() {
  late _RecordingMemory memory;
  late List<Tool> tools;

  setUp(() {
    memory = _RecordingMemory();
    final caps = Capabilities(memory: memory);
    tools = buildInteractionTools(
      ToolFactory(caps),
      askGate: null,
      caps: caps,
    );
  });

  Future<dynamic> call(String name, Map<String, dynamic> args) =>
      tools.firstWhere((t) => t.name == name).executable!(args);

  test('① save_memory 默认写 session（不写全局：写错会污染所有会话）', () async {
    final r = textOf(await call('save_memory', {'note': '这个项目用 Flutter 构建'}));

    expect(r, contains('session'), reason: '结果里应说明写到哪个作用域');
    expect(memory.appends, hasLength(1));
    expect(memory.appends.single.scope, MemoryScope.session,
        reason: '★ 默认作用域必须是 session —— 旧行为直接写全局是本次要消灭的缺陷');
    expect(memory.appends.single.note, '这个项目用 Flutter 构建');
  });

  test('② scope=workspace ⇒ 走 workspace（参数不能被吞）', () async {
    final r = textOf(await call('save_memory', {
      'note': '本仓库的构建命令是 flutter build apk',
      'scope': 'workspace',
    }));

    expect(r, contains('workspace'));
    expect(memory.appends.single.scope, MemoryScope.workspace,
        reason: '★ 模型显式给 workspace 时必须真的写 workspace');
  });

  test('③ scope=global ⇒ 明确拒绝并指路 propose_global_memory（不静默纠正）', () async {
    final r = textOf(await call('save_memory', {
      'note': '用户偏好简体中文回答',
      'scope': 'global',
    }));

    expect(r, contains('全局记忆只读'),
        reason: '★ agent 直写全局必须被拒（不变量 I4）');
    expect(r, contains('propose_global_memory'),
        reason: '★ 拒绝必须给出替代路径，否则模型会反复重试');
    expect(memory.appends, isEmpty,
        reason: '★ 被拒就一条都不能写 —— 静默纠正成 session 也是错（用户意图被改写）');
  });

  test('④ propose_global_memory 调 proposeGlobal（且带 kind）', () async {
    final r = textOf(await call('propose_global_memory', {
      'note': '用户希望回答尽量简短',
      'kind': 'preference',
    }));

    expect(memory.proposals, hasLength(1));
    expect(memory.proposals.single.note, '用户希望回答尽量简短');
    expect(memory.proposals.single.kind, 'preference');
    expect(r, contains('候选'),
        reason: '结果必须说清"这只是候选、要用户确认"，不能让模型以为已生效');
    expect(memory.appends, isEmpty, reason: '提议不是直接写');
  });

  test('⑤ SEC4：save_memory / propose_global_memory 都拒疑似密钥', () async {
    // 形如 sk-xxxx… 的字符串（SEC4 正则要求 sk- 后 ≥10 位）
    const secret = '把 sk-abcdefghijklmnop 记下来';

    final r1 = textOf(await call('save_memory', {'note': secret}));
    expect(r1, contains('密钥'), reason: '★ 记忆是明文且进 system，绝不能收凭据');
    expect(memory.appends, isEmpty);

    final r2 = textOf(await call('propose_global_memory', {'note': secret}));
    expect(r2, contains('密钥'),
        reason: '★ 新增的写入路径也必须过同一道 SEC4（不变量 I8）');
    expect(memory.proposals, isEmpty);
  });

  test('⑥ 工具总数 = 33（32 + propose_global_memory；忘登记就红）', () {
    // 用"无能力"的 Capabilities 数工具数：按纪律"缺能力也让工具可见"
    // （tool_factory.dart 的 KDoc），所以这里不需要任何真实现。
    const caps = Capabilities();
    final f = ToolFactory(caps);
    final all = <Tool>[
      ...buildFileTools(f, caps),
      ...buildShellTools(f, caps),
      ...buildFileManageTools(f, caps),
      ...buildInfoTools(f, caps),
      ...buildApkTools(f, caps),
      ...buildInteractionTools(f, askGate: null, caps: caps),
      ...buildGitTools(f, caps),
    ];

    expect(all.length, 33,
        reason: '实际：${all.map((t) => t.name).join(", ")}');
    final interaction =
        all.where((t) => t.name == 'save_memory' || t.name == 'propose_global_memory');
    expect(interaction.length, 2,
        reason: '交互类里的记忆工具是 save_memory + propose_global_memory');

    // 两个工具的 schema 必须声明关键参数（模型据此填参）
    final save = all.firstWhere((t) => t.name == 'save_memory');
    final saveProps = (save.parameters['properties'] as Map).cast<String, dynamic>();
    expect(saveProps.containsKey('scope'), isTrue,
        reason: 'save_memory 必须向模型暴露 scope 参数');
    final scopes = ((saveProps['scope'] as Map)['enum'] as List).cast<String>();
    expect(scopes, ['session', 'workspace'],
        reason: '★ global 不许出现在可选值里（不变量 I4）');

    final propose = all.firstWhere((t) => t.name == 'propose_global_memory');
    final proposeProps =
        (propose.parameters['properties'] as Map).cast<String, dynamic>();
    expect(proposeProps.containsKey('note'), isTrue);
  });

  test('⑦ 老宿主（只实现 read/append）默认实现：能编译能退化，但 global 写入默认被拒', () async {
    final legacy = _LegacyMemory();

    expect(legacy.defaultWriteScope, MemoryScope.session,
        reason: '默认写作用域是 session（写错影响最小）');

    final ok = await legacy.appendScoped(MemoryScope.session, '一条约定');
    expect(ok, isA<CapabilitySuccess>(),
        reason: '老宿主没有作用域存储 ⇒ 默认实现退化到 append，不报错');
    expect(legacy.appended, ['一条约定']);

    final denied = await legacy.appendScoped(MemoryScope.global, '全局约定');
    expect(denied, isA<CapabilityFailure>(),
        reason: '★ 默认实现对 global 必须 fail-closed（不变量 I4 的纵深防御：'
            '即使工具层漏判也写不进全局）');
    expect((denied as CapabilityFailure).reason, contains('全局记忆只读'));
    expect(legacy.appended, hasLength(1), reason: '被拒的那条一条都不能写');

    expect(await legacy.readScope(MemoryScope.workspace), 'legacy-raw',
        reason: '读作用域也退化到 read（老宿主只有一份存储）');

    final proposal = await legacy.proposeGlobal('用户偏好简洁');
    expect(proposal, isA<CapabilityFailure>(),
        reason: '老宿主没有提议存储 ⇒ 必须明确失败，绝不假装"已记录"');
  });
}
