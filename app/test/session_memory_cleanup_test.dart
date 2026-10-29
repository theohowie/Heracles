// Copyright (C) 2026 The Heracles Authors
//
// **会话删除 ⇒ 私有记忆清理 + 记忆设置项**（2026-10-29，P1-①c-2b）。
//
// 钉住三件事（设计稿 §3.1 §3.2、INTERFACE §N12.2 §N12.9）：
//   1. 会话私有记忆放 `<工作区>/.heracles/memory/session/<sid>.jsonl`，
//      **删会话必须一起删**（否则用户以为删了、磁盘上还躺着）；
//   2. `sessions.json` 缺失 / 非法 sid 一律 fail-closed（`hasSession` 只认真源，
//      非法形状直接 false，**绝不拿它拼路径** —— 防目录穿越）；
//   3. `memoryGlobalEnabled` 默认 true、`memoryPooling` 默认 false；旧数据
//      （SharedPreferences 里没有这两个键）必须落到默认值，不能当 false。
//
// 通道 mock 照抄 `session_store_ensure_dirs_test.dart:16-102` 的**普通文件语义**
// （父目录不存在就写失败）—— 这样"应用自己建目录"是真的被证明过的。

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/models/settings.dart' show AppSettings;
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/session_store.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/secure_storage_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('heracles/device');
  final files = <String, String>{};
  final dirs = <String>{'/'};
  final mkdirCalls = <String>[];

  String parentOf(String p) {
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  void addDirTree(String path) {
    var cur = path;
    while (cur != '/' && dirs.add(cur)) {
      cur = parentOf(cur);
    }
  }

  Map<String, Object?> ok([Map<String, Object?> extra = const {}]) =>
      <String, Object?>{'ok': true, ...extra};

  Map<String, Object?> fail(String error) =>
      <String, Object?>{'ok': false, 'error': error};

  Future<Object?> handle(MethodCall call) async {
    final args =
        (call.arguments as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final path = args['path'] as String? ?? '';
    switch (call.method) {
      case 'fs.mkdir':
        mkdirCalls.add(path);
        addDirTree(path);
        return ok();
      case 'fs.readText':
        if (!files.containsKey(path)) return fail('文件不存在：$path');
        return ok(<String, Object?>{'text': files[path], 'truncated': false});
      case 'fs.readTailLines':
        if (!files.containsKey(path)) return fail('文件不存在：$path');
        return ok(<String, Object?>{'text': files[path], 'truncated': false});
      case 'fs.writeText':
        final parent = parentOf(path);
        if (!dirs.contains(parent)) {
          return fail('父目录不存在：$parent');
        }
        files[path] = args['text'] as String? ?? '';
        return ok();
      case 'fs.appendText':
        final parent = parentOf(path);
        if (!dirs.contains(parent)) {
          return fail('父目录不存在：$parent');
        }
        files[path] = '${files[path] ?? ''}${args['text'] as String? ?? ''}';
        return ok();
      case 'fs.stat':
        return ok(<String, Object?>{
          'exists': files.containsKey(path) || dirs.contains(path),
          'isDirectory': dirs.contains(path),
          'size': files[path]?.length ?? 0,
        });
      case 'fs.delete':
        files.remove(path);
        return ok();
      default:
        return fail('未知方法 ${call.method}');
    }
  }

  void seed(String path, String text) {
    addDirTree(parentOf(path));
    files[path] = text;
  }

  Map<String, Object?> sessionRow(String id, {String title = '会话'}) =>
      <String, Object?>{
        'id': id,
        'title': title,
        'updatedAt': 1,
        'starred': false,
        'archived': false,
      };

  void seedSessions(List<Map<String, Object?>> rows) =>
      seed('/ws/.heracles/sessions.json', jsonEncode(rows));

  Map<String, Object?> memoryEntry(String sid, String text) => <String, Object?>{
        'v': 1,
        'id': 'm-1',
        'scope': 'session',
        'sid': sid,
        'kind': 'other',
        'text': text,
        'source': 'agent',
        'createdAt': 1,
      };

  String sessionMemoryFile(String sid) =>
      '/ws/.heracles/memory/session/$sid.jsonl';

  late DeviceChannelClient client;
  late SessionStore store;

  setUp(() {
    files.clear();
    dirs
      ..clear()
      ..addAll({'/', '/ws'});
    mkdirCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handle);
    client = DeviceChannelClient(channel: channel);
    store = SessionStore(workspaceRoot: '/ws', channel: client);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('会话是否存在（记忆寻址第 3 步的锚点）', () {
    test('★★★ hasSession：只认 sessions.json；不存在 / 非法 id 一律 false', () async {
      const a = 's1791611845161';
      const b = 's1791611897233';
      // ★ `_newId()` 撞号兜底生成的**合法** id（宽松闸必须放行）
      const fallback = 's1793-abcde';

      // 新工作区：索引还不存在 ⇒ false（不是错误、也不猜）
      expect(await store.hasSession(a), isFalse,
          reason: '索引不存在 ⇒ 会话不存在（fail-closed）');

      seedSessions(<Map<String, Object?>>[
        sessionRow(a),
        sessionRow(b),
        sessionRow(fallback),
        // 索引被污染：万一真混进这种 id，也绝不能认
        sessionRow('../evil'),
      ]);
      expect(await store.hasSession(a), isTrue);
      expect(await store.hasSession(b), isTrue);
      expect(await store.hasSession(fallback), isTrue,
          reason: '★ 库内合法兜底 id 必须放行（严格数字正则的误伤面）');
      expect(await store.hasSession('s1791611999999'), isFalse);
      expect(await store.hasSession(''), isFalse);
      expect(await store.hasSession('../evil'), isFalse,
          reason: '★ 含 .. 的 id 即使躺在索引里也 false（fail-closed，不认脏 id）');
      expect(await store.hasSession('a/b'), isFalse);
    });
  });

  group('删会话 ⇒ 私有记忆一起删', () {
    test('★★★ deleteSession：记忆文件 + 消息文件 + sessions.json + memory/index.json 一起清',
        () async {
      const a = 's1791611845161';
      const b = 's1791611897233';
      seedSessions(<Map<String, Object?>>[sessionRow(a), sessionRow(b)]);
      seed('/ws/.heracles/sessions/$a.jsonl', '{"role":"user","text":"A","ts":1}\n');
      seed('/ws/.heracles/sessions/$b.jsonl', '{"role":"user","text":"B","ts":1}\n');
      seed(sessionMemoryFile(a), '${jsonEncode(memoryEntry(a, 'A 的私房约定'))}\n');
      seed(sessionMemoryFile(b), '${jsonEncode(memoryEntry(b, 'B 的私房约定'))}\n');
      seed(
        '/ws/.heracles/memory/index.json',
        jsonEncode(<String, Object?>{
          'v': 1,
          'scope': 'workspace',
          'sessions': <String, Object?>{
            a: <String, Object?>{'entries': 1},
            b: <String, Object?>{'entries': 1},
          },
        }),
      );

      final ok = await store.deleteSession(a);
      expect(ok, isTrue);
      expect(store.lastError, isNull,
          reason: '清理失败原因：${store.lastError}');

      // ★ 用户以为删掉的会话，私有记忆也必须不在磁盘上
      expect(files.containsKey(sessionMemoryFile(a)), isFalse,
          reason: '会话私有记忆没删 = 隐私与"删干净"双输');
      expect(files.containsKey('/ws/.heracles/sessions/$a.jsonl'), isFalse);
      expect(files.containsKey('/ws/.heracles/memory/session/$b.jsonl'), isTrue,
          reason: '别的会话记忆绝不能被连带删掉');

      final sessionIds = (jsonDecode(files['/ws/.heracles/sessions.json']!) as List)
          .map((e) => (e as Map)['id'])
          .toList();
      expect(sessionIds, <Object?>[b], reason: 'sessions.json 只摘掉被删会话');

      final index = jsonDecode(files['/ws/.heracles/memory/index.json']!)
          as Map<String, dynamic>;
      final indexSessions = index['sessions'] as Map<String, dynamic>;
      expect(indexSessions.containsKey(a), isFalse,
          reason: '派生索引的 sessions 子表要同步（可重建，但不能留脏条目）');
      expect(indexSessions.containsKey(b), isTrue);
      expect(index['scope'], 'workspace', reason: '派生索引其它字段不许被顺手改掉');
    });

    test('★★ deleteSession 不存在的会话 ⇒ false，不炸、不误删任何记忆文件', () async {
      const a = 's1791611845161';
      seedSessions(<Map<String, Object?>>[sessionRow(a)]);
      seed(sessionMemoryFile(a), '${jsonEncode(memoryEntry(a, 'A 的记忆'))}\n');
      final before = Map<String, String>.from(files);

      final ok = await store.deleteSession('s1791611999999');
      expect(ok, isFalse);
      expect(store.lastError, contains('不存在'));
      expect(files, equals(before), reason: '不存在的会话不许触发任何删除副作用');
    });

    test('★★ deleteSession：memory 目录/文件都不存在 ⇒ 照常删成功（容错，不炸）', () async {
      const a = 's1791611845161';
      seedSessions(<Map<String, Object?>>[sessionRow(a)]);
      // 故意不建 memory/、不建 session 记忆文件、不建消息文件、不建 index.json

      final ok = await store.deleteSession(a);
      expect(ok, isTrue, reason: '清理失败原因：${store.lastError}');
      expect(store.lastError, isNull,
          reason: '"记忆文件不存在" 是正常态（这个会话本来没记过事），不是错误');
      final ids = (jsonDecode(files['/ws/.heracles/sessions.json']!) as List)
          .map((e) => (e as Map)['id']);
      expect(ids, isEmpty);
    });
  });

  group('目录由应用自己预建', () {
    test('★★★ _ensureStorageDirs：建 .heracles/memory 与 memory/session', () async {
      await store.createSession('测试会话');
      expect(mkdirCalls, contains('/ws/.heracles'));
      expect(mkdirCalls, contains('/ws/.heracles/sessions'));
      expect(mkdirCalls, contains('/ws/.heracles/memory'),
          reason: '不预建的话第一次写记忆会依赖宿主顺手建父目录（会静默失败）');
      expect(mkdirCalls, contains('/ws/.heracles/memory/session'));
      expect(dirs, contains('/ws/.heracles/memory'));
      expect(dirs, contains('/ws/.heracles/memory/session'));
    });
  });

  group('记忆设置项（INTERFACE §N12.9）', () {
    setUp(installSecureStorageMock);

    test('★★★ 默认值 & 旧数据兼容：缺键 ⇒ global 开、池化关', () async {
      // ① 模型默认值（新装 / 直接构造）
      expect(const AppSettings().memoryGlobalEnabled, isTrue);
      expect(const AppSettings().memoryPooling, isFalse);

      // ② 旧数据（SharedPreferences 里没有这两个键）⇒ 落到默认值
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final c = await SettingsController.load();
      expect(c.value.memoryGlobalEnabled, isTrue,
          reason: '旧数据没有该键 ⇒ 默认开（保住"换会话不失忆"的旧行为）');
      expect(c.value.memoryPooling, isFalse,
          reason: '池化默认关（默认安全，防串台）');
    });

    test('★★★ 写入后持久化、重载仍生效（键名与 INTERFACE 一致）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final c = await SettingsController.load();
      await c.setMemoryGlobalEnabled(false);
      await c.setMemoryPooling(true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('memoryGlobalEnabled'), isFalse);
      expect(prefs.getBool('memoryPooling'), isTrue);

      final reloaded = await SettingsController.load();
      expect(reloaded.value.memoryGlobalEnabled, isFalse);
      expect(reloaded.value.memoryPooling, isTrue);
    });
  });

  group('防目录穿越（宽松闸：只拦会改变路径语义的 id）', () {
    test('★★★ 合法兜底 id 不误伤：s1793-abcde 能正常拼出消息/记忆路径', () async {
      const fallback = 's1793-abcde';
      expect(store.messagesPath(fallback),
          '/ws/.heracles/sessions/$fallback.jsonl',
          reason: '★ 严格数字正则会误伤 _newId() 的撞号兜底 id');
      expect(store.sessionMemoryPath(fallback),
          '/ws/.heracles/memory/session/$fallback.jsonl');
      // 兜底 id 的会话能正常落消息、删会话时也能被认出（不炸）
      seedSessions(<Map<String, Object?>>[sessionRow(fallback)]);
      seed(store.messagesPath(fallback), '{"role":"user","text":"x","ts":1}\n');
      seed(store.sessionMemoryPath(fallback),
          '${jsonEncode(memoryEntry(fallback, '兜底 id 的记忆'))}\n');
      expect(await store.hasSession(fallback), isTrue);
      expect(await store.deleteSession(fallback), isTrue);
      expect(files.containsKey(store.sessionMemoryPath(fallback)), isFalse);
    });

    test('★★★ 非法 id 拒绝拼路径（空串 / 含 / 含 \\ 含 .. / NUL / 绝对路径）', () {
      final bad = <String>[
        '',
        '   ',
        '../evil',
        'a/b',
        'a\\b',
        's1791611845161/../x',
        '/abs/evil',
        'x\u0000y',
      ];
      for (final id in bad) {
        expect(() => store.messagesPath(id), throwsArgumentError,
            reason: 'messagesPath 必须拒绝 id=`$id`');
        expect(() => store.sessionMemoryPath(id), throwsArgumentError,
            reason: 'sessionMemoryPath 必须拒绝 id=`$id`');
      }
    });

    test('★★★ deleteSession 遇非法 id：不删任何文件，只记错误', () async {
      const a = 's1791611845161';
      seedSessions(<Map<String, Object?>>[sessionRow(a), sessionRow('../evil')]);
      // 两个会话都有消息/记忆文件；另有一个"如果穿越成功就会被删"的文件
      seed('/ws/.heracles/sessions/$a.jsonl', '{"role":"user","text":"A","ts":1}\n');
      seed(sessionMemoryFile(a), '${jsonEncode(memoryEntry(a, 'A 的记忆'))}\n');
      seed('/ws/.heracles/memory/evil.jsonl', '不该被删的文件\n');
      // 如果 messagesPath 穿越成功，'/ws/.heracles/sessions/../evil.jsonl'
      // 在真机上会解析成 '/ws/.heracles/evil.jsonl' —— 这里也埋一份
      seed('/ws/.heracles/evil.jsonl', '不该被删的文件 2\n');
      // mock 按"逐字路径"工作；把裸拼出来的那条路径也埋上，模拟真机解析后
      // 会命中的文件 —— 这样"闸失效 ⇒ 删到目录外"能被抓住，而不是被 mock 放过。
      seed('/ws/.heracles/sessions/../evil.jsonl', '不该被删的文件 3\n');

      final ok = await store.deleteSession('../evil');
      expect(ok, isTrue, reason: '坏会话仍可从索引移除（否则 UI 永远卡着它）');
      expect(store.lastError, contains('非法'),
          reason: '必须如实记"id 非法、文件未删"，不能静默');
      // ★ 一个文件都不许少（除了被删会话自己的 index 行）
      expect(files.containsKey('/ws/.heracles/memory/evil.jsonl'), isTrue);
      expect(files.containsKey('/ws/.heracles/evil.jsonl'), isTrue);
      expect(files.containsKey('/ws/.heracles/sessions/../evil.jsonl'), isTrue,
          reason: '★ 穿越路径上的文件绝不能被删（真机上它就是会话目录外的文件）');
      expect(files.containsKey('/ws/.heracles/sessions/$a.jsonl'), isTrue);
      expect(files.containsKey(sessionMemoryFile(a)), isTrue);
      final ids = (jsonDecode(files['/ws/.heracles/sessions.json']!) as List)
          .map((e) => (e as Map)['id']);
      expect(ids, <Object?>[a], reason: '只摘掉坏 id 那一行');
    });
  });
}
