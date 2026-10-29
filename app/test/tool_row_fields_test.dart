// Copyright (C) 2026 The Heracles Authors
//
// **历史命令卡字段（D6，2026-10-29 用户拍板）**：落盘 `tool` 行**只增**
// `surface` / `exitCode` / `command`，且**不写假数据**。
//
// ============================================================================
// 规格（`docs/接口.md` §7.2 D6 行 / `docs/INTERFACE.md` §6）
// ============================================================================
// · `surface`：真实执行面 —— `sandbox` / `mobileShell` / `unknown`
//   （取不到就 unknown，**不许猜**；来源是 backend `decideSurface` 的判定，
//   wire 是 `sandbox`/`device`，落盘口径映射成 `mobileShell`）；
// · `exitCode`：int，**仅在真实拿到退出码时写键**；取不到不写（不写假 0，
//   也不写 -1 哨兵）；
// · `command`：实际执行的命令字符串（与实时链路一致；非 shell 工具没有就省略）。
//
// 旧文件缺这三个键照常解析；未知键仍原样保留。
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/device_capabilities.dart';
import 'package:heracles/services/local_agent.dart';
import 'package:heracles/services/session_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tool 行三字段（纯函数构造）', () {
    test('① 沙箱命令 ⇒ surface=sandbox + 真实 command + 真实 exitCode', () {
      final row = buildToolRow(
        tool: 'run_shell_command',
        args: {'command': 'flutter build apk --debug'},
        result: '【命令输出开始】\nok\n【命令输出结束】',
        isError: false,
        id: 'call-1',
        metadata: {'surface': 'sandbox', 'exitCode': 0},
        requestedSurface: 'sandbox',
        requestedCommand: 'flutter build apk --debug',
        ts: 100,
      );

      expect(row['role'], 'tool');
      expect(row['surface'], 'sandbox',
          reason: '★ 沙箱命令必须标 sandbox（历史卡片据此显示"在沙箱执行"）');
      expect(row['command'], 'flutter build apk --debug',
          reason: '★ command 是**实际执行的命令**（不是模型口述/摘要）');
      expect(row['exitCode'], 0,
          reason: '真实退出码 0 要写（0 本身不假；假的是"缺值与 0 同形"）');
      // 旧形状一个都不能少（只增字段）
      expect(row['tool'], 'run_shell_command');
      expect(row['ok'], isTrue);
      expect(row['state'], 'succeeded');
      expect(row['result'], contains('命令输出开始'));
      expect(row['ts'], 100);
    });

    test('② 手机 shell 命令 ⇒ surface=mobileShell（不是 sandbox）', () {
      final row = buildToolRow(
        tool: 'run_shell_command',
        args: {'command': 'am force-stop com.example'},
        result: '【命令输出开始】\n(被禁令拦截)\n【命令输出结束】',
        isError: true,
        metadata: {'surface': 'device', 'exitCode': 3},
        requestedSurface: 'device',
        requestedCommand: 'am force-stop com.example',
        ts: 101,
      );

      expect(row['surface'], 'mobileShell',
          reason: '★ backend wire `device` = 手机 shell；落盘口径是 mobileShell。'
              '写死 sandbox 会让用户以为命令没碰手机');
      expect(row['exitCode'], 3);
      expect(row['command'], 'am force-stop com.example');
    });

    test('③ 取不到 exitCode ⇒ **不写该键**（不是 0，也不是 -1 哨兵）', () {
      final missing = buildToolRow(
        tool: 'run_shell_command',
        args: {'command': 'echo hi'},
        result: 'ok',
        isError: false,
        metadata: {'surface': 'sandbox'},
        ts: 102,
      );
      expect(missing.containsKey('exitCode'), isFalse,
          reason: '★ 没拿到退出码就不许写键 —— 写 0 会让历史卡片显示"成功"');

      final sentinel = buildToolRow(
        tool: 'run_shell_command',
        args: {'command': 'echo hi'},
        result: 'ok',
        isError: false,
        metadata: {'surface': 'sandbox', 'exitCode': -1},
        ts: 103,
      );
      expect(sentinel.containsKey('exitCode'), isFalse,
          reason: '★ -1 是"未知"哨兵（沙箱超时等），不是真实退出码 ⇒ 不写键');
    });

    test('③b 非 shell 工具：surface=unknown、无 command、无 exitCode（不猜）', () {
      final row = buildToolRow(
        tool: 'read_file',
        args: {'path': 'a.txt'},
        result: 'hello',
        isError: false,
        ts: 104,
      );
      expect(row['surface'], 'unknown',
          reason: '★ 文件工具没有执行面概念 ⇒ unknown（不许默认 sandbox）');
      expect(row.containsKey('command'), isFalse);
      expect(row.containsKey('exitCode'), isFalse);
    });

    test('③c 请求时预判有、完成时 metadata 缺 ⇒ 用预判（仍优先真实 metadata）', () {
      final fallback = buildToolRow(
        tool: 'run_shell_command',
        args: {'command': 'ls'},
        result: 'ok',
        isError: false,
        requestedSurface: 'device',
        ts: 105,
      );
      expect(fallback['surface'], 'mobileShell',
          reason: '完成事件没给 metadata 时回落到请求时的 decideSurface 预判');

      final authoritative = buildToolRow(
        tool: 'run_shell_command',
        args: {'command': 'ls'},
        result: 'ok',
        isError: false,
        metadata: {'surface': 'sandbox'},
        requestedSurface: 'device',
        ts: 106,
      );
      expect(authoritative['surface'], 'sandbox',
          reason: '★ 完成时真实执行面优先于请求时预判（不许前后不一致）');
    });
  });

  // ---------------------------------------------------------------------------
  // 落盘类型表：只增三键；旧文件缺键照常解析；未知键保留
  // ---------------------------------------------------------------------------
  group('session_store 落盘类型表（只增三键）', () {
    const channel = MethodChannel('heracles/device');
    final files = <String, String>{};
    final dirs = <String>{'/', '/ws', '/ws/.heracles', '/ws/.heracles/sessions'};

    String parentOf(String p) {
      final i = p.lastIndexOf('/');
      return i <= 0 ? '/' : p.substring(0, i);
    }

    setUp(() {
      files.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final args = (call.arguments as Map?)?.cast<String, Object?>() ??
            const <String, Object?>{};
        final path = args['path'] as String? ?? '';
        switch (call.method) {
          case 'fs.mkdir':
            dirs.add(path);
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
          default:
            return <String, Object?>{'ok': false, 'error': '未知方法 ${call.method}'};
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('④ 旧 jsonl 没有新键 ⇒ 照常解析（不崩、不编造）', () async {
      const sid = 's1791611845161';
      files['/ws/.heracles/sessions/$sid.jsonl'] = jsonEncode({
        'role': 'tool',
        'tool': 'run_shell_command',
        'result': 'old row',
        'ok': true,
        'ts': 1,
      });

      final store = SessionStore(
        workspaceRoot: '/ws',
        channel: DeviceChannelClient(channel: channel),
      );
      final rows = await store.loadMessages(sid);
      expect(rows, hasLength(1));
      expect(rows.single['tool'], 'run_shell_command');
      expect(rows.single.containsKey('surface'), isFalse,
          reason: '★ 旧行缺新键就保持缺失（读方按 unknown 处理），不许编造');
      expect(rows.single.containsKey('exitCode'), isFalse);
      expect(rows.single.containsKey('command'), isFalse);
    });

    test('⑤ 新键按类型规整（exitCode=int / surface,command=String），未知键保留', () async {
      final store = SessionStore(
        workspaceRoot: '/ws',
        channel: DeviceChannelClient(channel: channel),
      );
      final id = await store.createSession('t');
      final ok = await store.appendMessage(id, {
        'role': 'tool',
        'tool': 'run_shell_command',
        'result': 'ok',
        'ok': true,
        // 故意给"字符串数字"：类型表必须把它规整成 int（与 cached/prompt 同纪律）
        'exitCode': '3',
        'surface': 'mobileShell',
        'command': 'ls -la',
        // 未知键：长期数据，旧版本也要带着它
        'future_key': <String, Object?>{'x': 1},
        'ts': 2,
      });
      expect(ok, isTrue, reason: '落盘失败原因：${store.lastError}');

      final raw = files['/ws/.heracles/sessions/$id.jsonl']!;
      final line = const LineSplitter()
          .convert(raw)
          .firstWhere((l) => l.trim().isNotEmpty);
      final decoded = jsonDecode(line) as Map<String, dynamic>;
      expect(decoded['exitCode'], 3, reason: 'exitCode 必须在 int 类型表里');
      expect(decoded['surface'], 'mobileShell');
      expect(decoded['command'], 'ls -la');
      expect(decoded['future_key'], {'x': 1}, reason: '未知键原样保留');
    });
  });
}
