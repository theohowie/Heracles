// Copyright (C) 2026 The Heracles Authors
//
// **旧数据兼容 / 迁移解析**（2026-10-29）。
//
// 迁移动作本身在 Kotlin（`MemoryStore.migrate()`，task-2），这里测的是
// **App 侧的解析与兜底**：
//   · 旧 `memory.md`（`{"id":…}` JSON 行 + 无结构纯文本行）读进来不丢条目；
//   · 旧格式行的字段逐字段保留（kind/source/createdAt/expiresAt）；
//   · legacy 纯文本正文一字不差；
//   · **超长 legacy 正文不被 8000 字符写闸误杀**（写闸只管"新写"，
//     读/迁移路径必须容忍旧数据 —— 设计稿 §3.7.2 第 4 步）;
//   · 空文件 / 空白行 / 坏 JSON 行都能容忍（坏行降级成 legacy，不整段失败）。
//
// 夹具复用 `memory_service_test.dart`。

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/memory_service.dart';
import 'package:heracles_backend/heracles_backend.dart';

import 'memory_service_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('旧 memory.md 解析（JSON 行 + legacy 纯文本行）', () {
    test('★★★ JSON 行逐字段保留 + legacy 纯文本原文一字不差', () {
      const raw = ''
          '2026-10-20T12:00:00  {"id":"m1791612000000123","kind":"preference",'
          '"text":"这个项目用 Flutter","source":"user","createdAt":1791612000000,'
          '"expiresAt":1791620000000}\n'
          '构建走 flutter build apk\n'
          '{"id":"m2","kind":"background","text":"后端是纯 Dart 包",'
          '"source":"agent","createdAt":1791612100000}\n';

      final entries = ScopedMemoryService.parseLegacyGlobal(raw);
      expect(entries.length, 3, reason: '旧文件 3 条非空行 ⇒ 3 条记忆，一条都不许丢');

      final first = entries[0];
      expect(first.scope, MemoryScope.global);
      expect(first.id, 'm1791612000000123');
      expect(first.kind, 'preference');
      expect(first.text, '这个项目用 Flutter');
      expect(first.source, 'user');
      expect(first.createdAt, 1791612000000);
      expect(first.expiresAt, 1791620000000);

      final legacy = entries[1];
      expect(legacy.source, 'legacy', reason: '无结构纯文本行按 legacy 处理');
      expect(legacy.kind, 'other');
      expect(legacy.text, '构建走 flutter build apk',
          reason: '★ legacy 正文一字不差（不截断、不加前缀）');
      expect(legacy.createdAt, 0);

      final second = entries[2];
      expect(second.id, 'm2');
      expect(second.kind, 'background');
      expect(second.text, '后端是纯 Dart 包');
      expect(second.expiresAt, isNull);
    });

    test('★★★ 空文件 / 只有空白行 ⇒ 空列表（不是错误）', () {
      expect(ScopedMemoryService.parseLegacyGlobal(''), isEmpty);
      expect(ScopedMemoryService.parseLegacyGlobal('\n\n   \n\t\n'), isEmpty);
    });

    test('★★★ 坏 JSON 行降级为 legacy 纯文本，不拖垮其它行', () {
      const raw = ''
          '{"id":"m-good","kind":"other","text":"好的一行","source":"agent","createdAt":1}\n'
          '{不是合法JSON，只有半个大括号\n'
          '普通旧文本：用户手动写的约定\n';

      final entries = ScopedMemoryService.parseLegacyGlobal(raw);
      expect(entries.length, 3);
      expect(entries[0].id, 'm-good');
      expect(entries[0].text, '好的一行');
      expect(entries[1].source, 'legacy');
      expect(entries[1].text, '{不是合法JSON，只有半个大括号',
          reason: '坏 JSON 行原样保留为正文（宁可显示，也不丢内容）');
      expect(entries[2].text, '普通旧文本：用户手动写的约定');
    });

    test('★★★ legacy 超长正文（9000 字）读取不误杀：解析/读取路径不做 8000 写闸', () async {
      final long = '旧' * 9000;
      final entries = ScopedMemoryService.parseLegacyGlobal('$long\n');
      expect(entries.single.text.length, 9000, reason: '★ 读路径绝不截断旧数据');

      // 走 global 读取（memory.list 不可用 ⇒ 回落 memory.read）也不能被写闸影响
      final env = MemoryTestEnv();
      env.fixture.install();
      env.fixture.unsupportedMethods.add('memory.list');
      env.fixture.globalReadText = '$long\n';
      final scan = await env.service.read(MemoryTestEnv.globalAddr);
      expect(scan.entries.single.text.length, 9000);
      expect(scan.entries.single.source, 'legacy');
      env.fixture.dispose();
    });

    test('★★ 旧 APK（没有 memory.list）⇒ 回落 memory.read 的旧格式，不丢条目', () async {
      final env = MemoryTestEnv();
      env.fixture.install();
      env.fixture.unsupportedMethods.add('memory.list');
      env.fixture.globalReadText = ''
          '{"id":"m-old-1","kind":"habit","text":"用户习惯","source":"user","createdAt":7}\n'
          '一条纯文本旧记忆\n';
      final scan = await env.service.read(MemoryTestEnv.globalAddr);
      expect(scan.entries.length, 2);
      expect(scan.entries[0].text, '用户习惯');
      expect(scan.entries[0].scope, MemoryScope.global);
      expect(scan.entries[1].source, 'legacy');
      env.fixture.dispose();
    });
  });
}
