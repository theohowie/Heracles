// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 T1-5 扩展面测试**：SKILL.md 解析 / MCP 配置校验 / Automation 存储。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | SKILL.md 正常解析；缺 front-matter/缺 name/正文空 ⇒ 明确错误 | 静默吞掉坏技能 |
// | ② | 扫描批量：成功的加入、失败逐条报告（不整体失败） | 一条坏文件导致全盘失败 |
// | ③ | 启停/卸载：未知技能返回 false（不静默成功） | 假成功 |
// | ④ | MCP 校验：transport/command/url 非法、密钥进 env ⇒ 拒绝 | 非法配置拖到连接时才炸 |
// | ⑤ | MCP CRUD：upsert 失败不写入；删除/启停未知 ⇒ false | 假写入 |
// | ⑥ | Automation 校验：interval/cron 必填；schedulerImplemented=false（不假调度） | 假装定时任务在跑 |
// | ⑦ | 运行历史只留最近 N 条；只记真实结果 | 无限增长/预填成功 |
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  group('SKILL.md 解析', () {
    test('① 正常解析（name/description/正文）', () {
      const md = '''
---
name: my-skill
description: 一句话说明
---
正文内容：什么时候用、怎么做。
''';
      final r = parseSkillMd(md);
      expect(r.ok, isTrue);
      expect(r.skill!.name, 'my-skill');
      expect(r.skill!.description, '一句话说明');
      expect(r.skill!.body, contains('正文内容'));
    });

    test('①b 缺 front-matter / 缺 name / 正文空 ⇒ 明确错误（不静默）', () {
      expect(parseSkillMd('# 标题\n没有 front-matter').error, contains('front-matter'));
      expect(parseSkillMd('---\ndescription: x\n---\n正文').error, contains('name'));
      expect(parseSkillMd('---\nname: x\n---\n   ').error, contains('正文为空'));
      expect(parseSkillMd('---\nname: x\n').error, contains('未闭合'));
    });
  });

  group('SkillRegistry', () {
    test('② 批量扫描：成功加入、失败逐条报告', () {
      final reg = SkillRegistry();
      final res = reg.scan({
        'good/SKILL.md': '---\nname: good\ndescription: ok\n---\n正文',
        'bad/SKILL.md': '没有 front-matter',
      });
      expect(res.added, hasLength(1));
      expect(res.added.single.name, 'good');
      expect(res.errors, hasLength(1));
      expect(res.errors.single, contains('bad/SKILL.md'));
      expect(reg.byName('good'), isNotNull);
    });

    test('③ 启停/卸载：未知 ⇒ false（不静默成功）', () {
      final reg = SkillRegistry([
        const SkillEntry(name: 'a', description: '', body: 'b', source: 'user'),
      ]);
      expect(reg.setEnabled('a', false), isTrue);
      expect(reg.enabled, isEmpty);
      expect(reg.setEnabled('nope', true), isFalse);
      expect(reg.remove('a'), isTrue);
      expect(reg.remove('a'), isFalse);
    });
  });

  group('MCP', () {
    test('④ 校验：非法 transport/command/url、密钥进 env 都拒绝', () {
      expect(
        validateMcpServer(const McpServerConfig(name: 'x', transport: 'ws')),
        contains('stdio 或 http'),
      );
      expect(
        validateMcpServer(const McpServerConfig(name: 'x', transport: 'stdio')),
        contains('command'),
      );
      expect(
        validateMcpServer(const McpServerConfig(name: 'x', transport: 'http', url: 'ftp://a')),
        contains('http://'),
      );
      expect(
        validateMcpServer(const McpServerConfig(
          name: 'x',
          transport: 'stdio',
          command: 'node',
          env: {'API_KEY': 'sk-xxx'},
        )),
        contains('不要把密钥写进'),
        reason: '★ 密钥不得进 MCP 环境变量',
      );
      expect(
        validateMcpServer(const McpServerConfig(name: '', transport: 'stdio', command: 'node')),
        contains('name'),
      );
      // 合法配置
      expect(
        validateMcpServer(const McpServerConfig(
          name: 'ok',
          transport: 'stdio',
          command: 'npx',
          args: ['-y', 'server'],
        )),
        isNull,
      );
    });

    test('⑤ CRUD：upsert 失败不写入；未知删除/启停 ⇒ false', () {
      final store = McpConfigStore();
      expect(store.upsert(const McpServerConfig(name: 'bad', transport: 'ws')), isNotNull);
      expect(store.all, isEmpty, reason: '★ 非法配置不许写入');
      expect(
        store.upsert(const McpServerConfig(name: 'ok', transport: 'http', url: 'https://a')),
        isNull,
      );
      expect(store.all, hasLength(1));
      expect(store.setEnabled('ok', false), isTrue);
      expect(store.remove('nope'), isFalse);
    });
  });

  group('Automation', () {
    test('⑥ 校验：interval/cron 必填；调度器未实现（不假调度）', () {
      expect(
        validateAutomationTask(const AutomationTask(
            id: 'a', title: 't', prompt: 'p', schedule: 'interval')),
        contains('intervalMinutes'),
      );
      expect(
        validateAutomationTask(const AutomationTask(
            id: 'a', title: 't', prompt: 'p', schedule: 'cron')),
        contains('cron'),
      );
      expect(
        validateAutomationTask(const AutomationTask(
            id: 'a', title: 't', prompt: ' ', schedule: 'interval', intervalMinutes: 5)),
        contains('prompt'),
      );
      expect(
        validateAutomationTask(const AutomationTask(
            id: 'a', title: 't', prompt: 'p', schedule: 'interval', intervalMinutes: 5)),
        isNull,
      );
      // ★ 2026-11-02：调度器已用 AlarmManager 实现（真实周期触发）；
      //   但**执行**仍需要 App 在前台 —— 两条都必须如实标注，不许说成"后台自动跑完"。
      expect(AutomationStore.schedulerImplemented, isTrue);
      expect(AutomationStore.executionRequiresAppForeground, isTrue,
          reason: '★ 到点只发通知+写 pending，真正 run 要 App 打开后发起');
    });

    test('⑦ 运行历史只留最近 N 条，只记真实结果', () {
      final store = AutomationStore([
        const AutomationTask(
            id: 'a', title: 't', prompt: 'p', schedule: 'interval', intervalMinutes: 5),
      ]);
      for (var i = 0; i < 25; i++) {
        store.recordRun('a', AutomationRun(ts: i, ok: i % 2 == 0));
      }
      final t = store.all.single;
      expect(t.runHistory, hasLength(20), reason: '只留最近 20 条');
      expect(t.runHistory.last.ts, 24);
      expect(t.runHistory.last.ok, isTrue, reason: '记录的是真实结果，不是预填');
      expect(store.recordRun('nope', const AutomationRun(ts: 1, ok: true)), isFalse);
    });
  });
}
