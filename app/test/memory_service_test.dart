// Copyright (C) 2026 The Heracles Authors
//
// **ScopedMemoryService 的地址强校验 / 写队列 / 墓碑折叠 / compact**（2026-10-29）。
//
// ## 这个文件是 4 个记忆测试的公共夹具
//
// `memory_isolation_test.dart` / `memory_migration_test.dart` /
// `memory_eviction_test.dart` 都 `import 'memory_service_test.dart'` 复用
// [MemoryChannelFixture] / [MemoryTestEnv]（Dart 允许测试文件互相 import，
// 被 import 的 `main()` 不会被执行）—— 夹具只有一份，避免四份漂移。
//
// ## 通道 mock 的口径
//
// 照抄 `session_store_ensure_dirs_test.dart:16-102` 的**普通文件语义**：
// 父目录不存在就写失败（这样能真的证明服务自己 mkdir，而不是指望宿主接口
// 顺手建目录）。`memory.*` 是 global 作用域的内存替身（Kotlin 侧真实实现在
// task-2 落，这里只验 Dart 侧路由与形状）。
//
// ## 先红再绿的证据
//
// 本文件第一次运行（产品文件 `memory_service.dart` 还不存在）是**编译失败**：
// `Error: Couldn't resolve the package 'heracles' ... memory_service.dart` 等价错
// —— 即"红"。产品实现落盘后同一批断言转绿。

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/memory_service.dart';
import 'package:heracles_backend/heracles_backend.dart';

// ============================================================================
// 公共夹具 1：heracles/device 通道的内存文件系统 + memory.* 替身
// ============================================================================

/// 设备通道的内存替身（只实现记忆服务用到的方法）。
class MemoryChannelFixture {
  MemoryChannelFixture({Set<String>? dirs})
      : dirs = <String>{...(dirs ?? const <String>{'/'})};

  static const MethodChannel channel = MethodChannel('heracles/device');

  /// `path → 文本`。与真机一样，`fs.appendText` / `fs.writeText` 之外没有别的写入口。
  final Map<String, String> files = <String, String>{};

  /// 已存在的目录集合（普通文件语义：父目录不在就写失败）。
  final Set<String> dirs;

  /// `fs.mkdir` 的调用记录（断言"目录是应用自己建的"）。
  final List<String> mkdirCalls = <String>[];

  /// 所有通道方法名（断言"失败时没碰存储"）。
  final List<String> methodCalls = <String>[];

  /// global 作用域的内存替身（Kotlin `MemoryStore` 的 Dart 侧镜像）。
  final List<Map<String, Object?>> globalEntries = <Map<String, Object?>>[];

  /// 提议列表替身。
  final List<Map<String, Object?>> proposals = <Map<String, Object?>>[];

  /// 让指定方法回"未知方法"（模拟旧 APK，验回落路径）。
  final Set<String> unsupportedMethods = <String>{};

  /// 非 null ⇒ `memory.read` 返回这段原文（模拟旧 memory.md / 迁移前数据）。
  String? globalReadText;

  late final DeviceChannelClient client =
      DeviceChannelClient(channel: channel);

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  String? parentOf(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  void addDirTree(String path) {
    var cur = path;
    while (cur != '/' && dirs.add(cur)) {
      cur = parentOf(cur)!;
    }
  }

  String readFile(String path) => files[path] ?? '';

  void seedFile(String path, String text) {
    addDirTree(parentOf(path)!);
    files[path] = text;
  }

  void seedJsonl(String path, List<Map<String, Object?>> rows) {
    seedFile(path, '${rows.map(jsonEncode).join('\n')}\n');
  }

  /// 一个会话/工作区记忆文件里"能解析成 JSON 对象"的行（墓碑也在里面）。
  List<Map<String, dynamic>> linesOf(String path) {
    final out = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(readFile(path))) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final v = jsonDecode(t);
        if (v is Map) out.add(v.cast<String, dynamic>());
      } catch (_) {
        // 坏行不参与断言
      }
    }
    return out;
  }

  static Map<String, Object?> _ok([Map<String, Object?> extra = const {}]) =>
      <String, Object?>{'ok': true, ...extra};

  static Map<String, Object?> _fail(String error,
      [String? code]) {
    final out = <String, Object?>{'ok': false, 'error': error};
    if (code != null) out['code'] = code;
    return out;
  }

  Future<Object?> _handle(MethodCall call) async {
    methodCalls.add(call.method);
    if (unsupportedMethods.contains(call.method)) {
      return _fail('未知方法 ${call.method}');
    }
    final args =
        (call.arguments as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final path = args['path'] as String? ?? '';
    switch (call.method) {
      case 'fs.mkdir':
        mkdirCalls.add(path);
        addDirTree(path);
        return _ok();
      case 'fs.readText':
        if (!files.containsKey(path)) {
          return _fail('文件不存在：$path');
        }
        return _ok(<String, Object?>{'text': files[path], 'truncated': false});
      case 'fs.readTailLines':
        if (!files.containsKey(path)) {
          return _fail('文件不存在：$path');
        }
        final maxLines = (args['maxLines'] as num?)?.toInt() ?? 0;
        final lines = const LineSplitter().convert(files[path]!);
        final tail = maxLines > 0 && lines.length > maxLines
            ? lines.sublist(lines.length - maxLines)
            : lines;
        return _ok(<String, Object?>{'text': tail.join('\n'), 'truncated': false});
      case 'fs.writeText':
        final parent = parentOf(path);
        if (parent != null && !dirs.contains(parent)) {
          return _fail('父目录不存在：$parent');
        }
        files[path] = args['text'] as String? ?? '';
        return _ok();
      case 'fs.appendText':
        final parent = parentOf(path);
        if (parent != null && !dirs.contains(parent)) {
          return _fail('父目录不存在：$parent');
        }
        files[path] = '${files[path] ?? ''}${args['text'] as String? ?? ''}';
        return _ok();
      case 'fs.rename':
        final from = args['from'] as String? ?? '';
        final to = args['to'] as String? ?? '';
        if (!files.containsKey(from)) return _fail('文件不存在：$from');
        final parent = parentOf(to);
        if (parent != null && !dirs.contains(parent)) {
          return _fail('父目录不存在：$parent');
        }
        files[to] = files.remove(from)!;
        return _ok();
      case 'fs.delete':
        files.remove(path);
        return _ok();
      case 'fs.stat':
        return _ok(<String, Object?>{
          'exists': files.containsKey(path) || dirs.contains(path),
          'isDirectory': dirs.contains(path),
          'size': files[path]?.length ?? 0,
        });
      case 'memory.list':
        final includeExpired = args['includeExpired'] == true;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final shown = globalEntries.where((e) {
          if (includeExpired) return true;
          final exp = e['expiresAt'];
          return exp == null || (exp is num && exp.toInt() > nowMs);
        }).toList();
        return _ok(<String, Object?>{
          'entries': shown,
          'total': shown.length,
          'bytes': shown.fold<int>(0, (n, e) => n + jsonEncode(e).length),
        });
      case 'memory.read':
        final text = globalReadText ??
            globalEntries.map(jsonEncode).join('\n');
        return _ok(<String, Object?>{'text': text, 'bytes': text.length});
      case 'memory.userEdit':
        final action = args['action'] as String? ?? '';
        final text = args['text'] as String? ?? '';
        switch (action) {
          case 'add':
            final id = 'm-user-${globalEntries.length + 1}';
            globalEntries.add(<String, Object?>{
              'v': 1,
              'id': id,
              'scope': 'global',
              'kind': args['kind'] ?? 'other',
              'text': text,
              'source': 'user',
              'createdAt': 0,
            });
            return _ok(<String, Object?>{'id': id, 'bytes': text.length});
          case 'update':
            final id = args['id'] as String? ?? '';
            final i = globalEntries.indexWhere((e) => e['id'] == id);
            if (i < 0) return _fail('条目不存在：$id');
            globalEntries[i]['text'] = text;
            return _ok(<String, Object?>{'id': id});
          case 'delete':
            final ids = (args['ids'] as List?)?.map((e) => '$e').toSet() ?? {};
            final before = globalEntries.length;
            globalEntries.removeWhere((e) => ids.contains(e['id']));
            return _ok(<String, Object?>{'removed': before - globalEntries.length});
          case 'clear':
            globalEntries.clear();
            return _ok();
          default:
            return _fail('未知 action：$action');
        }
      case 'memory.propose':
        final id = 'mp-${proposals.length + 1}';
        proposals.add(<String, Object?>{
          'v': 1,
          'id': id,
          'scope': 'global',
          'kind': args['kind'] ?? 'other',
          'text': args['note'] ?? '',
          'source': 'agent',
          'createdAt': 0,
          'status': 'pending',
        });
        return _ok(<String, Object?>{'id': id});
      case 'memory.proposals':
        final status = args['status'] as String?;
        final shown = status == null
            ? proposals
            : proposals.where((p) => p['status'] == status).toList();
        return _ok(<String, Object?>{'entries': shown});
      case 'memory.resolveProposal':
        final id = args['id'] as String? ?? '';
        final action = args['action'] as String? ?? '';
        final i = proposals.indexWhere((p) => p['id'] == id);
        if (i < 0) return _fail('提议不存在：$id');
        if (action == 'promote') {
          proposals[i]['status'] = 'promoted';
          globalEntries.add(<String, Object?>{
            'v': 1,
            'id': 'm-promoted-$id',
            'scope': 'global',
            'kind': proposals[i]['kind'],
            'text': proposals[i]['text'],
            'source': 'promoted',
            'createdAt': 0,
          });
          return _ok(<String, Object?>{'entryId': 'm-promoted-$id'});
        }
        proposals[i]['status'] = 'rejected';
        return _ok();
      case 'memory.stats':
        return _ok(<String, Object?>{
          'entries': globalEntries.length,
          'bytes': globalEntries.fold<int>(0, (n, e) => n + jsonEncode(e).length),
          'limits': <String, Object?>{'storageSoftMaxBytes': 8 * 1024 * 1024},
        });
      case 'memory.append':
        // 与 task-2 的契约一致：全局只读，永久拒绝。
        return _fail('全局记忆只读：模型不能直接写入。', 'E_SCOPE_READONLY');
      default:
        return _fail('未知方法 ${call.method}');
    }
  }
}

// ============================================================================
// 公共夹具 2：按测试注入依赖的 ScopedMemoryService 环境
// ============================================================================

/// 一份可调的 [MemoryTestEnv]（workspace / session 登记表 + 时钟 + 预算）。
class MemoryTestEnv {
  MemoryTestEnv({Set<String>? workspaces}) {
    knownWorkspaces.addAll(workspaces ?? const <String>{'/ws'});
    service = buildService();
  }

  final MemoryChannelFixture fixture = MemoryChannelFixture();

  /// 工作区登记表（模拟 `AgentBridge.listWorkspaces`）。
  final Set<String> knownWorkspaces = <String>{};

  /// 会话登记表，key = `'$workspacePath|$sessionId'`。
  final Set<String> knownSessions = <String>{};

  MemoryStoreBudget budget = const MemoryStoreBudget();
  int now = 1700000000000;
  String Function(String workspacePath, String sessionId)? sessionPathFor;

  late ScopedMemoryService service;

  ScopedMemoryService buildService() => ScopedMemoryService(
        channel: fixture.client,
        budget: budget,
        nowMs: () => now,
        hasSession: (ws, sid) async => knownSessions.contains('$ws|$sid'),
        listWorkspaces: () async => knownWorkspaces.toSet(),
        sessionPathFor: sessionPathFor,
      );

  void rebuild() {
    service = buildService();
  }

  void registerSession(String sid, {String ws = '/ws'}) {
    knownWorkspaces.add(ws);
    knownSessions.add('$ws|$sid');
  }

  MemoryAddress sessionAddr(String sid, {String ws = '/ws'}) => MemoryAddress(
        scope: MemoryScope.session,
        sessionId: sid,
        workspacePath: ws,
      );

  MemoryAddress workspaceAddr({String ws = '/ws'}) =>
      MemoryAddress(scope: MemoryScope.workspace, workspacePath: ws);

  static const MemoryAddress globalAddr = MemoryAddress(scope: MemoryScope.global);

  static String sessionFile(String ws, String sid) =>
      '$ws/.heracles/memory/session/$sid.jsonl';

  static String workspaceFile(String ws) => '$ws/.heracles/memory/workspace.jsonl';
}

/// 断言"抛出了指定错误码的 [MemoryServiceError]"。
Matcher memoryError(String code) =>
    isA<MemoryServiceError>().having((e) => e.code, 'code', code);

// ============================================================================
// 测试
// ============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('地址强校验 8 步（fail-closed，绝不回落）', () {
    late MemoryTestEnv env;
    setUp(() {
      env = MemoryTestEnv();
      env.fixture.install();
    });
    tearDown(() => env.fixture.dispose());

    test('★★★ 第 1 步：scope 与字段必填关系不符 ⇒ E_SCOPE_MISMATCH', () async {
      final bad = <MemoryAddress>[
        const MemoryAddress(scope: MemoryScope.global, sessionId: 's1791611845161'),
        const MemoryAddress(scope: MemoryScope.global, workspacePath: '/ws'),
        const MemoryAddress(scope: MemoryScope.workspace),
        const MemoryAddress(
          scope: MemoryScope.session,
          workspacePath: '/ws',
        ),
      ];
      for (final addr in bad) {
        await expectLater(env.service.read(addr), throwsA(memoryError('E_SCOPE_MISMATCH')),
            reason: '地址 $addr 应在第 1 步被拒');
      }
      expect(env.fixture.methodCalls, isEmpty, reason: '校验不过时一次存储调用都不许发');
    });

    test('★★★ 第 2 步：sid 形状不合法 ⇒ E_SID_FORMAT（同时挡路径穿越）', () async {
      env.registerSession('s1791611845161');
      // 注意 `../evil` / `s1` / 超长数字都不合 `^s[0-9]{10,16}$`
      for (final sid in <String>[
        's1',
        'abc',
        's179161184516100000',
        '../evil',
        's1791611845161/../x',
      ]) {
        await expectLater(
          env.service.read(env.sessionAddr(sid)),
          throwsA(memoryError('E_SID_FORMAT')),
          reason: 'sid=`$sid` 必须被第 2 步挡下（绝不进路径拼接）',
        );
      }
      expect(env.fixture.methodCalls, isEmpty);
    });

    test('★★★ 第 3 步：会话不在 sessions.json ⇒ E_SID_UNKNOWN（不回落）', () async {
      const sid = 's1791611845161';
      await expectLater(
        env.service.read(env.sessionAddr(sid)),
        throwsA(memoryError('E_SID_UNKNOWN')),
      );
      expect(env.fixture.files, isEmpty, reason: '不存在的会话不许创建记忆文件');
    });

    test('★★★ 第 4 步：工作区未登记 / 非绝对路径 ⇒ E_WORKSPACE_UNKNOWN', () async {
      await expectLater(
        env.service.read(env.workspaceAddr(ws: '/not-registered')),
        throwsA(memoryError('E_WORKSPACE_UNKNOWN')),
      );
      await expectLater(
        env.service.read(env.workspaceAddr(ws: 'relative/path')),
        throwsA(memoryError('E_WORKSPACE_UNKNOWN')),
      );
      // session 作用域也要过工作区登记（记忆文件在工作区里）
      env.knownSessions.add('/nowhere|s1791611845161');
      await expectLater(
        env.service.read(env.sessionAddr('s1791611845161', ws: '/nowhere')),
        throwsA(memoryError('E_WORKSPACE_UNKNOWN')),
      );
    });

    test('★★★ 第 5 步：解析出的目标路径与规范路径不逐字相等 ⇒ E_PATH_MISMATCH', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      env.sessionPathFor = (ws, s) => '$ws/.heracles/memory/session/evil.jsonl';
      env.rebuild();

      await expectLater(
        env.service.append(env.sessionAddr(sid), '内容'),
        throwsA(memoryError('E_PATH_MISMATCH')),
      );
      expect(env.fixture.files, isEmpty);
    });

    test('★★★ 第 6 步：agent 写 global ⇒ E_SCOPE_READONLY（用户路径才可写）', () async {
      await expectLater(
        env.service.append(MemoryTestEnv.globalAddr, '模型想写全局'),
        throwsA(memoryError('E_SCOPE_READONLY')),
      );
      // 一个 memory.* 写调用都没发（不是"通道拒绝"，而是本地就挡住）
      expect(env.fixture.methodCalls.where((m) => m == 'memory.userEdit'), isEmpty);
      expect(env.fixture.globalEntries, isEmpty);
    });

    test('★★★ 第 7 步：单条正文超 8000 字符 ⇒ E_ENTRY_TOO_LONG，且一个字节都不写', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final longText = '长' * (ContractMemory.entryMaxChars + 1);

      await expectLater(
        env.service.append(env.sessionAddr(sid), longText),
        throwsA(memoryError('E_ENTRY_TOO_LONG')),
      );
      expect(env.fixture.files, isEmpty, reason: '绝不写半条');

      // 边界：正好 8000 字符是允许的
      final ok = await env.service.append(
        env.sessionAddr(sid),
        '短' * ContractMemory.entryMaxChars,
      );
      expect(ok.ok, isTrue);
    });

    test('★★★ 8 步全过才动手：session 记忆落在工作区，不进 App 私有 sessions/', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final out = await env.service.append(
        env.sessionAddr(sid),
        '这个项目用 Flutter',
        kind: 'preference',
      );
      expect(out.ok, isTrue);
      expect(out.id, startsWith('m'));

      final path = MemoryTestEnv.sessionFile('/ws', sid);
      expect(env.fixture.files.keys, contains(path),
          reason: '必须写 <工作区>/.heracles/memory/session/<sid>.jsonl');
      expect(env.fixture.mkdirCalls, contains('/ws/.heracles/memory'));
      expect(env.fixture.mkdirCalls, contains('/ws/.heracles/memory/session'));
      expect(env.fixture.files.keys.where((p) => p.contains('/.heracles/sessions/')),
          isEmpty,
          reason: '★ 记忆绝不写进 App 私有 sessions/ 或会话正文 .jsonl');

      final scan = await env.service.read(env.sessionAddr(sid));
      expect(scan.entries.length, 1);
      final e = scan.entries.single;
      expect(e.text, '这个项目用 Flutter');
      expect(e.scope, MemoryScope.session);
      expect(e.sid, sid);
      expect(e.source, 'agent');
      expect(e.kind, 'preference');
    });

    test('★★ "空"与"错"不同形：没有记忆 ⇒ 空列表（不抛、不回落）', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final scan = await env.service.read(env.sessionAddr(sid));
      expect(scan.entries, isEmpty);
      expect(scan.skippedForeign, 0);
    });

    test('★★ SEC4：疑似密钥/令牌拒写，且正文不落盘', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      await expectLater(
        env.service.append(env.sessionAddr(sid), 'key=sk-abcdefghijklmnop'),
        throwsA(memoryError('E_SECRET_REJECTED')),
      );
      expect(env.fixture.files, isEmpty);
    });
  });

  group('写队列 —— 覆盖整个「读→判→淘汰→追加」事务', () {
    late MemoryTestEnv env;
    setUp(() {
      env = MemoryTestEnv();
      env.fixture.install();
    });
    tearDown(() => env.fixture.dispose());

    test('★★★ 同一文件两个 append 并发：都落盘，不丢条、不互相覆盖', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final a = env.service.append(env.sessionAddr(sid), '第一条');
      final b = env.service.append(env.sessionAddr(sid), '第二条');
      await Future.wait<void>([a, b]);

      final scan = await env.service.read(env.sessionAddr(sid));
      expect(scan.entries.map((e) => e.text), containsAll(<String>['第一条', '第二条']));
      expect(scan.entries.length, 2);
      expect(env.fixture.linesOf(MemoryTestEnv.sessionFile('/ws', sid)).length, 2);
    });

    test('★★★ 并发 append + delete 由行序决定，不会整文件清空', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final first = await env.service.append(env.sessionAddr(sid), '要留下的');
      final f1 = env.service.append(env.sessionAddr(sid), '新加的');
      final f2 = env.service.delete(env.sessionAddr(sid), <String>[first.id!]);
      await Future.wait<void>([f1, f2]);

      final scan = await env.service.read(env.sessionAddr(sid));
      final texts = scan.entries.map((e) => e.text).toList();
      expect(texts, isNot(contains('要留下的')));
      expect(texts, contains('新加的'));
    });
  });

  group('墓碑折叠与 compact', () {
    late MemoryTestEnv env;
    setUp(() {
      env = MemoryTestEnv();
      env.fixture.install();
    });
    tearDown(() => env.fixture.dispose());

    test('★★★ del / clear 墓碑折叠后：被删条目不再返回（后写者胜）', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final a = await env.service.append(env.sessionAddr(sid), '甲');
      await env.service.append(env.sessionAddr(sid), '乙');
      await env.service.delete(env.sessionAddr(sid), <String>[a.id!]);
      expect(
        (await env.service.read(env.sessionAddr(sid)))
            .entries
            .map((e) => e.text),
        isNot(contains('甲')),
      );

      await env.service.clear(env.sessionAddr(sid));
      expect((await env.service.read(env.sessionAddr(sid))).entries, isEmpty);
      // 清空后的追加必须留下来（clear 只影响它之前的行）
      await env.service.append(env.sessionAddr(sid), '清空后');
      expect(
        (await env.service.read(env.sessionAddr(sid))).entries.single.text,
        '清空后',
      );
    });

    test('★★★ compact：存活正文一字不差、墓碑全部消失、tmp 不残留', () async {
      const sid = 's1791611845161';
      env.registerSession(sid);
      final path = MemoryTestEnv.sessionFile('/ws', sid);
      // 直接种一份"历史文件"（含墓碑 + 同 id 旧版本），不经过服务写入 ——
      // 否则自动 compact 会在写路径里先把墓碑清掉，测不到显式 compact。
      env.fixture.seedJsonl(path, <Map<String, Object?>>[
        <String, Object?>{'v': 1, 'id': 'm-a', 'scope': 'session', 'sid': sid, 'kind': 'other', 'text': '保留甲（旧版）', 'source': 'agent', 'createdAt': 1},
        <String, Object?>{'v': 1, 'id': 'm-b', 'scope': 'session', 'sid': sid, 'kind': 'other', 'text': '删除乙', 'source': 'agent', 'createdAt': 2},
        <String, Object?>{'v': 1, 'tomb': 'del', 'ids': <String>['m-b'], 'at': 3},
        <String, Object?>{'v': 1, 'id': 'm-a', 'scope': 'session', 'sid': sid, 'kind': 'other', 'text': '保留甲（新版）', 'source': 'agent', 'createdAt': 4},
        <String, Object?>{'v': 1, 'id': 'm-c', 'scope': 'session', 'sid': sid, 'kind': 'other', 'text': '保留丙', 'source': 'user', 'createdAt': 5},
      ]);
      expect(env.fixture.linesOf(path).where((j) => j.containsKey('tomb')), isNotEmpty,
          reason: 'compact 前墓碑应在文件里');

      final result = await env.service.compact(env.sessionAddr(sid));
      final rows = env.fixture.linesOf(path);
      expect(rows.where((j) => j.containsKey('tomb')), isEmpty,
          reason: 'compact 后墓碑必须消失');
      expect(env.fixture.files.keys.where((p) => p.endsWith('.tmp')), isEmpty);
      expect(result.beforeLines, 5);
      expect(result.afterLines, 2);
      expect(result.removed, 3);

      final scan = await env.service.read(env.sessionAddr(sid));
      expect(scan.entries.map((e) => e.text).toList(), <String>['保留甲（新版）', '保留丙'],
          reason: '同 id 后写者胜 + 正文一字不差（整条保留，绝不截断）');
    });
  });
}
