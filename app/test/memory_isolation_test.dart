// Copyright (C) 2026 The Heracles Authors
//
// **记忆隔离**（2026-10-29）：会话 A/B 互不可见、伪造 sid 不回落、
// 条目 sid 不符丢弃并计数、同 sid 两工作区独立、agent 写 global 被拒、
// 并发写不丢条、删会话清记忆文件。
//
// 夹具复用 `memory_service_test.dart`（见该文件头：测试文件互相 import 是
// 有意为之，夹具只留一份）。

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/memory_service.dart';

import 'memory_service_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('会话/工作区隔离', () {
    late MemoryTestEnv env;
    setUp(() {
      env = MemoryTestEnv();
      env.fixture.install();
    });
    tearDown(() => env.fixture.dispose());

    test('★★★ 会话 A 的记忆在会话 B 里看不到（不串台）', () async {
      const a = 's1791611845161';
      const b = 's1791611897233';
      env.registerSession(a);
      env.registerSession(b);

      await env.service.append(env.sessionAddr(a), 'A 的私房约定');
      await env.service.append(env.sessionAddr(b), 'B 的私房约定');

      final readA = await env.service.read(env.sessionAddr(a));
      final readB = await env.service.read(env.sessionAddr(b));
      expect(readA.entries.map((e) => e.text), <String>['A 的私房约定']);
      expect(readB.entries.map((e) => e.text), <String>['B 的私房约定']);
      // 两个文件，不是同一份
      expect(MemoryTestEnv.sessionFile('/ws', a),
          isNot(MemoryTestEnv.sessionFile('/ws', b)));
    });

    test('★★★ 伪造 sid（../x / s1 / 不存在）一律 fail-closed，绝不回落全局/工作区', () async {
      // 先在工作区里放一条真实记忆：如果回落，它会出现在结果里
      env.knownWorkspaces.add('/ws');
      env.fixture.seedJsonl(MemoryTestEnv.workspaceFile('/ws'), <Map<String, Object?>>[
        <String, Object?>{'v': 1, 'id': 'm1', 'scope': 'workspace', 'kind': 'other', 'text': '工作区记忆', 'source': 'agent', 'createdAt': 1},
      ]);

      await expectLater(env.service.read(env.sessionAddr('../x')),
          throwsA(memoryError('E_SID_FORMAT')));
      await expectLater(env.service.read(env.sessionAddr('s1')),
          throwsA(memoryError('E_SID_FORMAT')));
      await expectLater(env.service.read(env.sessionAddr('s1791611845161')),
          throwsA(memoryError('E_SID_UNKNOWN')));

      // 三次失败都没产生文件、也没读工作区文件
      expect(env.fixture.files.keys.where((p) => p.contains('/memory/session/')),
          isEmpty);
      expect(env.fixture.methodCalls.where((m) => m == 'fs.readText'), isEmpty,
          reason: '失败路径不许去读任何记忆文件（fail-closed，不是"读到空"）');
    });

    test('★★★ 条目里的 sid 与寻址不符 ⇒ 丢弃并计数（防文件被复制后串台）', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final path = MemoryTestEnv.sessionFile('/ws', sid);
      // 手工造一份"被复制过来的"文件：混入另一个会话的条目 + 自己的条目
      env.fixture.seedJsonl(path, <Map<String, Object?>>[
        <String, Object?>{'v': 1, 'id': 'm-foreign-1', 'scope': 'session', 'sid': 's1791611999999', 'kind': 'other', 'text': '别人的秘密', 'source': 'agent', 'createdAt': 1},
        <String, Object?>{'v': 1, 'id': 'm-own-1', 'scope': 'session', 'sid': sid, 'kind': 'other', 'text': '自己的', 'source': 'agent', 'createdAt': 2},
      ]);

      final scan = await env.service.read(env.sessionAddr(sid));
      expect(scan.entries.map((e) => e.text), <String>['自己的'],
          reason: '★ sid 不符的条目绝不许注入');
      expect(scan.skippedForeign, 1, reason: '丢弃必须计数（不静默）');
    });

    test('★★★ 同一个 sid 字符串在两个工作区里是两个独立视图', () async {
      const sid = 's1791611845161';
      env.registerSession(sid, ws: '/ws/a');
      env.registerSession(sid, ws: '/ws/b');

      await env.service.append(env.sessionAddr(sid, ws: '/ws/a'), 'A 工作区的记忆');
      await env.service.append(env.sessionAddr(sid, ws: '/ws/b'), 'B 工作区的记忆');

      final a = await env.service.read(env.sessionAddr(sid, ws: '/ws/a'));
      final b = await env.service.read(env.sessionAddr(sid, ws: '/ws/b'));
      expect(a.entries.single.text, 'A 工作区的记忆');
      expect(b.entries.single.text, 'B 工作区的记忆');
      expect(MemoryTestEnv.sessionFile('/ws/a', sid),
          isNot(MemoryTestEnv.sessionFile('/ws/b', sid)));
    });

    test('★★★ agent 写 global：E_SCOPE_READONLY（isolation 的核心不变量 I4）', () async {
      await expectLater(
        env.service.append(MemoryTestEnv.globalAddr, '模型想直接写全局'),
        throwsA(memoryError('E_SCOPE_READONLY')),
      );
      // 用户路径（memory.userEdit）不在本断言内 —— 那是 UI 才允许的
      expect(env.fixture.globalEntries, isEmpty);
    });

    test('★★★ 同 scope 并发写 10 条：一条都不丢（写队列）', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final futures = <Future<MemoryWriteOutcome>>[
        for (var i = 0; i < 10; i++)
          env.service.append(env.sessionAddr(sid), '并发条目 $i'),
      ];
      await Future.wait(futures);

      final scan = await env.service.read(env.sessionAddr(sid));
      expect(scan.entries.length, 10);
      expect(
        scan.entries.map((e) => e.text).toSet(),
        <String>{for (var i = 0; i < 10; i++) '并发条目 $i'},
      );
    });

    test('★★★ 删除会话时清理它的记忆文件：A 没了，B 还在（8b 的切入点）', () async {
      const a = 's1791611845161';
      const b = 's1791611897233';
      env.registerSession(a);
      env.registerSession(b);
      await env.service.append(env.sessionAddr(a), 'A 的记忆');
      await env.service.append(env.sessionAddr(b), 'B 的记忆');

      final ok = await env.service.deleteSessionFile('/ws', a);
      expect(ok, isTrue);
      expect(env.fixture.files.keys, isNot(contains(MemoryTestEnv.sessionFile('/ws', a))));
      expect(env.fixture.files.keys, contains(MemoryTestEnv.sessionFile('/ws', b)));
      // B 读得回来；A 读 = 空（文件已删）
      expect((await env.service.read(env.sessionAddr(b))).entries.single.text, 'B 的记忆');
      expect((await env.service.read(env.sessionAddr(a))).entries, isEmpty);
    });
  });
}
