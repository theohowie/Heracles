import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/session_store.dart';

/// 回归钉（2026-10-27 真机 bug「重进会话记录全没了、工作区里
/// 根本没有 .heracles 目录」）：
///
/// 会话存储链此前没有任何一处建目录，全靠宿主写文件时顺手建父目录。
/// 本测试的通道 mock 按**普通文件写的真实语义**：父目录不存在
/// 就写失败。断言 SessionStore 自己先建 `.heracles/sessions`
/// 再写，会话往返完整成立 —— 目录是应用自己的结构，
/// 本来就该应用建，不能指望用户或宿主。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('heracles/device');
  final files = <String, String>{};
  final dirs = <String>{'/', '/ws'};
  final mkdirCalls = <String>[];

  String parentOf(String p) {
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  setUp(() {
    files.clear();
    dirs
      ..clear()
      ..addAll({'/', '/ws'});
    mkdirCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ??
          const <String, Object?>{};
      final path = args['path'] as String? ?? '';
      switch (call.method) {
        case 'fs.mkdir':
          mkdirCalls.add(path);
          var cur = path;
          while (cur != '/' && dirs.add(cur)) {
            cur = parentOf(cur);
          }
          return <String, Object?>{'ok': true};
        case 'fs.readText':
          if (!files.containsKey(path)) {
            return <String, Object?>{'ok': false, 'error': '文件不存在：$path'};
          }
          return <String, Object?>{
            'ok': true,
            'text': files[path],
            'truncated': false,
          };
        case 'fs.readTailLines':
          if (!files.containsKey(path)) {
            return <String, Object?>{'ok': false, 'error': '文件不存在：$path'};
          }
          final maxLines = (args['maxLines'] as num?)?.toInt() ?? 0;
          final lines = const LineSplitter().convert(files[path]!);
          final tail = maxLines > 0 && lines.length > maxLines
              ? lines.sublist(lines.length - maxLines)
              : lines;
          return <String, Object?>{
            'ok': true,
            'text': tail.join('\n'),
            'truncated': false,
          };
        case 'fs.writeText':
          if (!dirs.contains(parentOf(path))) {
            return <String, Object?>{
              'ok': false,
              'error': '父目录不存在：${parentOf(path)}',
            };
          }
          files[path] = args['text'] as String? ?? '';
          return <String, Object?>{'ok': true};
        case 'fs.appendText':
          if (!files.containsKey(path)) {
            return <String, Object?>{'ok': false, 'error': '文件不存在：$path'};
          }
          files[path] = files[path]! + (args['text'] as String? ?? '');
          return <String, Object?>{'ok': true};
        case 'fs.stat':
          return <String, Object?>{
            'ok': true,
            'exists': files.containsKey(path) || dirs.contains(path),
            'isDirectory': dirs.contains(path),
            'size': (files[path] ?? '').length,
          };
        case 'fs.delete':
          files.remove(path);
          return <String, Object?>{'ok': true};
        default:
          return <String, Object?>{
            'ok': false,
            'error': '未知方法 ${call.method}',
          };
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('父目录不存在时：应用自己建 .heracles/sessions 并完成往返', () async {
    final client = DeviceChannelClient(channel: channel);
    final store = SessionStore(workspaceRoot: '/ws', channel: client);
    final id = await store.createSession('测试会话');
    expect(await store.appendMessage(id, {'role': 'user', 'text': '你好', 'ts': 1}),
        isTrue,
        reason: '落盘失败原因：${store.lastError}');
    expect(
        await store.appendMessage(
            id, {'role': 'assistant', 'text': '你好，有什么可以帮你', 'ts': 2}),
        isTrue,
        reason: '落盘失败原因：${store.lastError}');

    // 目录是应用自己建的（不是宿主顺手、更不是用户手建）
    expect(mkdirCalls, contains('/ws/.heracles/sessions'));
    expect(files.keys, contains('/ws/.heracles/sessions.json'));
    expect(files.keys, contains('/ws/.heracles/sessions/$id.jsonl'));

    // 全新实例（模拟重进会话）：索引与记录都读得回来
    final store2 = SessionStore(workspaceRoot: '/ws', channel: client);
    final metas = await store2.listSessions();
    expect(metas.map((m) => m.id), contains(id));
    final rows = await store2.loadMessages(id);
    expect(rows.length, 2);
    expect(rows[0]['text'], '你好');
    expect(rows[1]['text'], '你好，有什么可以帮你');
  });
}
