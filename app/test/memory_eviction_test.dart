// Copyright (C) 2026 The Heracles Authors
//
// **存储软预算与淘汰顺序**（2026-10-29）。
//
// 设计稿 §3.4.1：超软预算**淘汰**（不是拒写），顺序是确定性的：
//   ① 过期 → ② 最旧 `source=agent` → ③ 最旧 `user/promoted/legacy` → ④ 仍放不下才拒写。
// 淘汰必须**回报 `evicted:[id…]`**（不变量 I6：不静默丢条目）。
//
// 这里用 `entriesSoftMax` 驱动淘汰（确定性、不用造几 MB 数据），
// 用"1 条都放不下"的字节预算驱动兜底拒写。
//
// 夹具复用 `memory_service_test.dart`。

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/memory_service.dart';

import 'memory_service_test.dart';

/// 造一条 workspace 记忆行（直接种进 JSONL，模拟"历史数据"）。
Map<String, Object?> _row({
  required String id,
  required String text,
  String source = 'agent',
  int createdAt = 1,
  int? expiresAt,
}) =>
    <String, Object?>{
      'v': 1,
      'id': id,
      'scope': 'workspace',
      'kind': 'other',
      'text': text,
      'source': source,
      'createdAt': createdAt,
      'expiresAt': expiresAt,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryTestEnv env;
  const ws = '/ws';

  setUp(() {
    env = MemoryTestEnv();
    env.fixture.install();
  });
  tearDown(() => env.fixture.dispose());

  test('★★★ ① 先淘汰过期条目（过期是"最先该走"的）', () async {
    env.budget = const MemoryStoreBudget(workspaceEntriesSoftMax: 3);
    env.rebuild();
    // now = 1700000000000；expired 的 expiresAt 早于 now
    env.fixture.seedJsonl(MemoryTestEnv.workspaceFile(ws), <Map<String, Object?>>[
      _row(id: 'm-expired', text: '过期的', source: 'agent', createdAt: 10, expiresAt: 1),
      _row(id: 'm-agent-old', text: '旧 agent', source: 'agent', createdAt: 100),
      _row(id: 'm-user-old', text: '旧 user', source: 'user', createdAt: 5),
    ]);

    final out = await env.service.append(env.workspaceAddr(), '新条目');
    expect(out.ok, isTrue);
    expect(out.evicted, contains('m-expired'), reason: '过期条目必须先被淘汰');
    expect(out.evicted, isNot(contains('m-user-old')),
        reason: '腾一个位置就够，user 不该被动');

    final scan = await env.service.read(env.workspaceAddr());
    expect(scan.entries.map((e) => e.text), containsAll(<String>['旧 agent', '旧 user', '新条目']));
    expect(scan.entries.map((e) => e.text), isNot(contains('过期的')));
  });

  test('★★★ ② 过期之后先淘汰最旧 agent；user 再旧也留着', () async {
    env.budget = const MemoryStoreBudget(workspaceEntriesSoftMax: 3);
    env.rebuild();
    env.fixture.seedJsonl(MemoryTestEnv.workspaceFile(ws), <Map<String, Object?>>[
      // user 是最旧的一条（createdAt=1），但淘汰顺序里 agent 先走
      _row(id: 'm-user-old', text: '旧 user', source: 'user', createdAt: 1),
      _row(id: 'm-agent-100', text: 'agent 100', source: 'agent', createdAt: 100),
      _row(id: 'm-agent-200', text: 'agent 200', source: 'agent', createdAt: 200),
    ]);

    final out = await env.service.append(env.workspaceAddr(), '新条目');
    expect(out.evicted, <String>['m-agent-100'],
        reason: '★ 淘汰顺序：最旧 agent 先于更旧的 user');

    final texts = (await env.service.read(env.workspaceAddr()))
        .entries
        .map((e) => e.text)
        .toSet();
    expect(texts, containsAll(<String>['旧 user', 'agent 200', '新条目']));
    expect(texts, isNot(contains('agent 100')));
  });

  test('★★★ ③ 只剩 user/promoted/legacy 时：最旧的那条才动', () async {
    env.budget = const MemoryStoreBudget(workspaceEntriesSoftMax: 2);
    env.rebuild();
    env.fixture.seedJsonl(MemoryTestEnv.workspaceFile(ws), <Map<String, Object?>>[
      _row(id: 'm-user-1', text: 'user 最旧', source: 'user', createdAt: 1),
      _row(id: 'm-promoted-2', text: 'promoted 较新', source: 'promoted', createdAt: 2),
    ]);

    final out = await env.service.append(env.workspaceAddr(), '新条目');
    expect(out.evicted, <String>['m-user-1'],
        reason: '只剩保序层时，最旧的（user）先走；它仍排在最后才动');

    final texts = (await env.service.read(env.workspaceAddr()))
        .entries
        .map((e) => e.text)
        .toSet();
    expect(texts, containsAll(<String>['promoted 较新', '新条目']));
  });

  test('★★★ ④ 淘汰后仍放不下 ⇒ E_ENTRY_TOO_LONG 拒写，文件逐字节不变', () async {
    env.budget = const MemoryStoreBudget(workspaceStorageSoftMaxBytes: 200);
    env.rebuild();
    final path = MemoryTestEnv.workspaceFile(ws);
    env.fixture.seedJsonl(path, <Map<String, Object?>>[
      _row(id: 'm-keep', text: '已有条目', source: 'user', createdAt: 1),
    ]);
    final before = env.fixture.readFile(path);

    final long = '放' * 400; // 单条行 JSON 远超 200 字节预算
    await expectLater(
      env.service.append(env.workspaceAddr(), long),
      throwsA(memoryError('E_ENTRY_TOO_LONG')),
    );
    expect(env.fixture.readFile(path), before,
        reason: '★ 拒写时不许留下墓碑/半条 —— 文件必须逐字节不变');
    // 也不许"清掉旧条目再失败"
    expect((await env.service.read(env.workspaceAddr())).entries.single.text, '已有条目');
  });

  test('★★ 回收后的条目数对得上（不静默丢条、也不假报成功）', () async {
    env.budget = const MemoryStoreBudget(workspaceEntriesSoftMax: 2);
    env.rebuild();
    final path = MemoryTestEnv.workspaceFile(ws);
    env.fixture.seedJsonl(path, <Map<String, Object?>>[
      _row(id: 'm-1', text: '一', source: 'agent', createdAt: 1),
      _row(id: 'm-2', text: '二', source: 'agent', createdAt: 2),
    ]);

    final out = await env.service.append(env.workspaceAddr(), '三');
    expect(out.evicted, hasLength(1));
    final scan = await env.service.read(env.workspaceAddr());
    expect(scan.entries.length, 2, reason: 'entriesSoftMax=2 ⇒ 回收后正好 2 条');
    expect(scan.entries.map((e) => e.text), containsAll(<String>['二', '三']));
  });
}
