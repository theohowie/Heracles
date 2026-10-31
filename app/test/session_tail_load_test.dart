// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **T0-4：长会话 >1MB 时 `limit=0` 的 tail 兜底**（2026-10-31）。
//
// ============================================================================
// 这个文件锁住什么（先红后绿 + 变异验证）
// ============================================================================
// 病根：`loadMessages(limit: 0)` 以前**死读** `fs.readText`。通道读文本有 1 MB
// 上限 ⇒ 超长会话只拿到**开头** 1 MB，用户切会话看到的是最老的记录，最新消息
// 反而没显示（只剩一句"超过 1MB"提示）。
//
// 现在 `limit=0` 的语义是"**尽量**加载全部"：
//   · ≤ 1 MB ⇒ 读全（hasEarlier=false）；
//   · > 1 MB（stat 或 readText.truncated 确认）⇒ `fs.readTailLines` 读最后
//     `ContractSession.tailLoadLines` 行，返回头插一条 `_synthetic: paging` 的
//     system 行（带 `hasEarlier` / `truncatedAtHead` 键，**只增字段**）；
//   · 旧宿主没有 readTailLines ⇒ 回落 readText 后**本地切尾**；若 readText 也被
//     1 MB 截断，lastError 必须明确"最新消息可能未显示"（绝不假装完整）。
//
// 夹具用 mock MethodChannel（`heracles/device`），模拟 POSIX 路由的三种能力：
// stat（大小）/ readText（可能截断）/ readTailLines（可能"未知方法"）。

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/session_store.dart';
import 'package:heracles_backend/heracles_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('heracles/device');
  const ws = '/ws';
  const sid = 's1791611845161';

  // 每行额外塞 400 字节 padding：让 3000 行 ≈ 1.4 MB，**真的**超过通道 1 MB
  //（否则 mock 的 "truncated:true" 与文本长度自相矛盾，测不出"只拿到前 1MB"）。
  String line(int i) => jsonEncode(<String, Object?>{
        'role': 'user',
        'text': 'm$i',
        'ts': i,
        'pad': 'x' * 400,
      });

  late List<String> fullLines;
  late int fileSize;
  late bool supportTail;
  late bool statSupported;
  late bool readTextTruncated;

  final readTextCalls = <Map<String, Object?>>[];
  final readTailCalls = <Map<String, Object?>>[];
  final statCalls = <Map<String, Object?>>[];

  /// 模拟 `fs.readText` 的 1 MB 上限：按**字节**累加到上限为止（与 Kotlin 同量级）。
  String headPortion(int limitBytes) {
    final buf = StringBuffer();
    var bytes = 0;
    for (final l in fullLines) {
      final add = utf8.encode('$l\n').length;
      if (bytes + add > limitBytes) break;
      buf.writeln(l);
      bytes += add;
    }
    return buf.toString();
  }

  void mockDevice() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args =
          (call.arguments as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
      switch (call.method) {
        case 'fs.stat':
          statCalls.add(Map<String, Object?>.from(args));
          if (!statSupported) {
            return <String, Object?>{'ok': false, 'error': '未知方法 fs.stat'};
          }
          return <String, Object?>{
            'ok': true,
            'exists': true,
            'isDir': false,
            'size': fileSize,
            'mtimeMs': 0,
          };
        case 'fs.readText':
          readTextCalls.add(Map<String, Object?>.from(args));
          if (fullLines.isEmpty && fileSize == 0) {
            return <String, Object?>{'ok': true, 'text': '', 'truncated': false};
          }
          if (readTextTruncated) {
            return <String, Object?>{
              'ok': true,
              'text': headPortion(ContractSession.channelTextMaxBytes),
              'truncated': true,
            };
          }
          return <String, Object?>{
            'ok': true,
            'text': fullLines.join('\n'),
            'truncated': false,
          };
        case 'fs.readTailLines':
          readTailCalls.add(Map<String, Object?>.from(args));
          if (!supportTail) {
            return <String, Object?>{
              'ok': false,
              'error': '未知方法：fs.readTailLines',
            };
          }
          final maxLines = (args['maxLines'] as num?)?.toInt() ?? 0;
          final want = maxLines <= 0 ? 400 : maxLines;
          final tail = fullLines.length > want
              ? fullLines.sublist(fullLines.length - want)
              : fullLines;
          return <String, Object?>{
            'ok': true,
            'text': tail.join('\n'),
            // 与 Kotlin 同语义：拿满 want 行 ⇒ "前面可能还有"。
            'truncated': tail.length >= want,
          };
        default:
          return <String, Object?>{'ok': false, 'error': '未知方法 ${call.method}'};
      }
    });
  }

  SessionStore newStore() => SessionStore(
        workspaceRoot: ws,
        channel: DeviceChannelClient(channel: channel),
      );

  setUp(() {
    fullLines = <String>[for (var i = 0; i < 3000; i++) line(i)];
    fileSize = 2 * 1024 * 1024; // 2 MB：超过通道 1 MB
    supportTail = true;
    statSupported = true;
    readTextTruncated = false;
    readTextCalls.clear();
    readTailCalls.clear();
    statCalls.clear();
    mockDevice();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('limit=0：超 1MB ⇒ 自动读尾部（不再只读前 1MB）', () {
    test('★★★ 2MB 假 JSONL ⇒ 返回最后 2000 行 + hasEarlier/truncatedAtHead', () async {
      final store = newStore();
      final rows = await store.loadMessages(sid);

      expect(readTailCalls, hasLength(1),
          reason: '★ 超长会话必须走 readTailLines');
      expect(readTextCalls, isEmpty,
          reason: '★ stat 已知超阈值时不该白读 1MB（更不该把它当完整历史）');
      expect(readTailCalls.single['maxLines'],
          ContractSession.tailLoadLines + 8,
          reason: '请求行数 = 2000 + 缓冲 8');

      expect(rows.first['role'], 'system');
      expect(rows.first['_synthetic'], 'paging');
      expect(rows.first['hasEarlier'], isTrue);
      expect(rows.first['truncatedAtHead'], isTrue);
      expect('${rows.first['text']}', contains('${ContractSession.tailLoadLines}'));

      final data = rows.where((r) => r['role'] == 'user').toList();
      expect(data, hasLength(ContractSession.tailLoadLines),
          reason: '★ 只返回最近 2000 条');
      expect(data.first['text'], 'm1000', reason: '★ 起点是"最后 2000 条"的第一条');
      expect(data.last['text'], 'm2999', reason: '★ 必须包含最新一条（旧 bug 会丢）');

      expect(store.lastLoadHasEarlier, isTrue);
      expect(store.lastLoadTruncatedAtHead, isTrue);
      expect(store.lastError, isNull, reason: 'tail 成功不是错误');
    });

    test('★★★ stat 不可用 + readText 被截断 ⇒ 仍自动改走 tail', () async {
      statSupported = false;
      readTextTruncated = true; // readText 只给前 1MB
      final store = newStore();
      final rows = await store.loadMessages(sid);

      expect(readTailCalls, hasLength(1),
          reason: '★ 发现 truncated 后必须改读尾部，不能把前 1MB 当完整历史');
      final data = rows.where((r) => r['role'] == 'user').toList();
      expect(data.last['text'], 'm2999');
      expect(store.lastLoadTruncatedAtHead, isTrue);
    });

    test('★★ 文件 ≤ 1MB ⇒ 读全，hasEarlier=false，不出现 paging 行', () async {
      fullLines = <String>[for (var i = 0; i < 50; i++) line(i)];
      fileSize = 5000;
      final store = newStore();
      final rows = await store.loadMessages(sid);

      expect(readTailCalls, isEmpty);
      expect(readTextCalls, hasLength(1));
      expect(rows, hasLength(50));
      expect(rows.first['role'], 'user');
      expect(store.lastLoadHasEarlier, isFalse);
      expect(store.lastLoadTruncatedAtHead, isFalse);
      expect(store.lastError, isNull);
    });

    test('★★ 空文件 / 不存在 ⇒ 空列表（不抛、不假装）', () async {
      fullLines = <String>[];
      fileSize = 0;
      final store = newStore();
      expect(await store.loadMessages(sid), isEmpty);
      expect(store.lastLoadHasEarlier, isFalse);
      expect(store.lastLoadTruncatedAtHead, isFalse);
    });
  });

  group('tail 路径的分页与坏行容错', () {
    test('★★★ limit=10 offset=0 / offset=5 窗口正确', () async {
      final store = newStore();

      final page0 = await store.loadMessages(sid, limit: 10);
      final data0 = page0.where((r) => r['role'] == 'user').toList();
      expect(data0.map((r) => r['text']).toList(),
          <String>[for (var i = 2990; i < 3000; i++) 'm$i']);

      final page1 = await store.loadMessages(sid, limit: 10, offset: 5);
      final data1 = page1.where((r) => r['role'] == 'user').toList();
      expect(data1.map((r) => r['text']).toList(),
          <String>[for (var i = 2985; i < 2995; i++) 'm$i'],
          reason: 'offset=5 ⇒ 往前再翻 5 条（仍是时间正序）');
    });

    test('★★ 坏行容错：tail 里夹坏 JSON ⇒ 跳过坏行，其余照常', () async {
      fullLines = <String>[
        ...fullLines,
        '{"role":"assistant","text":"半行坏数据"', // 不完整 JSON
        'garbage-line',
        '{"role":"assistant","text":"好行","ts":3002}',
      ];
      fileSize = 2 * 1024 * 1024;
      final store = newStore();
      final rows = await store.loadMessages(sid);
      final data = rows.where((r) => r['role'] == 'user' || r['role'] == 'assistant').toList();
      expect(data.last['text'], '好行');
      expect(data.length, lessThan(ContractSession.tailLoadLines + 2),
          reason: '坏行被跳过（不影响其它行）');
    });
  });

  group('旧宿主（无 fs.readTailLines）⇒ 回落且如实说', () {
    test('★★★ readText 能读全 ⇒ 本地切最后 N 行 + hasEarlier，lastError 明确', () async {
      supportTail = false;
      readTextTruncated = false; // 旧实现无 1MB 闸 ⇒ 拿到全文
      fileSize = 2 * 1024 * 1024;
      final store = newStore();
      final rows = await store.loadMessages(sid);

      final data = rows.where((r) => r['role'] == 'user').toList();
      expect(data, hasLength(ContractSession.tailLoadLines));
      expect(data.last['text'], 'm2999', reason: '本地切尾也要保留最新消息');
      expect(rows.first['hasEarlier'], isTrue);
      expect(rows.first['truncatedAtHead'], isNot(true),
          reason: '能读全时头部没丢，只是本地切尾');
      expect(store.lastLoadHasEarlier, isTrue);
      expect(store.lastLoadTruncatedAtHead, isFalse);
      expect(store.lastError, contains('不支持尾部读取'));
      expect(store.lastError, isNot(contains('最新消息可能未显示')));
    });

    test('★★★ 旧宿主 + readText 只给前 1MB ⇒ 明确"最新消息可能未显示"（不假装完整）',
        () async {
      supportTail = false;
      readTextTruncated = true;
      fileSize = 2 * 1024 * 1024;
      final store = newStore();
      final rows = await store.loadMessages(sid);

      expect(store.lastLoadTruncatedAtHead, isTrue);
      expect(store.lastError, contains('可能未显示'),
          reason: '★ 拿不到真尾部时必须如实说，不能把前 1MB 当完整历史');
      expect(rows.first['truncatedAtHead'], isTrue);
      expect('${rows.first['text']}', contains('最新消息可能未显示'));
      // 返回的是"前 1MB 的末尾"而不是最新消息 —— 这正是必须明确告警的原因
      expect(rows.where((r) => r['role'] == 'user').last['text'],
          isNot('m2999'));
    });
  });
}
