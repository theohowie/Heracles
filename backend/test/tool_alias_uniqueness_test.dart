// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **工具名唯一性测试（2026-11-03）** —— 真机 400 `Tool names must be unique` 的回归闸。
//
// ## 病根
//
// OpenAI 兼容端点要求 `body.tools[].function.name` **唯一**：
// `core/lib/src/llm/openai_client.dart:402` 把每个 `Tool` **一对一**写进 `body['tools']`，
// 不做任何去重 ⇒ 我们的工具列表里只要有两个同名 `Tool`，整轮请求直接 400，
// 用户看到的是一轮"什么都没做就失败"。
//
// 别名功能（`tool_aliases.dart`）给**每个已存在的正式工具**生成独立别名 Tool
// （框架按 `Tool.name` 精确匹配，光有解析函数不够）。于是两个正式工具一旦
// **共用同一个别名**（实测：`grep_files` 与 `web_search` 都写了 `Search`），
// 就会生成两个同名 Tool ⇒ 命中上面那条 400。
//
// ## 这两条断言为什么必须存在
//
// · 第 1 条锁**数据**：别名值全局唯一（新增正式工具时最容易撞名）；
// · 第 2 条锁**产物**：`buildAliasTools` 的输出与 base 合并后整体无重名
//   （即使将来数据表写错，执行层也不许把重名工具交给模型）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 构造一个最小可用 Tool（只为"名字与 schema 复制"这条路径服务）。
Tool _dummy(String name) => Tool(
      name: name,
      description: 'dummy $name',
      parameters: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
      executable: (dynamic args) async => 'ok',
    );

void main() {
  test('① 别名值全局唯一：同一别名不许指向两个正式工具', () {
    final owner = <String, String>{};
    final dups = <String>[];
    for (final e in toolAliases.entries) {
      for (final a in e.value) {
        final prev = owner[a];
        if (prev != null && prev != e.key) dups.add('$a（$prev 与 ${e.key} 共用）');
        owner[a] = e.key;
      }
    }
    expect(
      dups,
      isEmpty,
      reason: '共用别名会生成同名 Tool ⇒ OpenAI 400 `Tool names must be unique`；'
          '冲突项：${dups.join('、')}',
    );
  });

  test('② 注册后的工具名集合无重复（base + 别名）', () {
    // 取真机上真实共存的两个正式工具：它们曾经共用 `Search`。
    final base = [_dummy('grep_files'), _dummy('web_search')];
    final all = [...base, ...buildAliasTools(base)];

    final names = all.map((t) => t.name).toList();
    final dupNames = <String>{
      for (final n in names)
        if (names.where((x) => x == n).length > 1) n,
    };

    expect(
      dupNames,
      isEmpty,
      reason: '重复工具名会被 openai_client 原样写进 body.tools ⇒ 400；'
          '重复项：${dupNames.join('、')}',
    );
  });

  test('③ 别名仍然可用：唯一化之后每个别名都还能解析并转调', () async {
    final base = [_dummy('grep_files'), _dummy('web_search')];
    final all = [...base, ...buildAliasTools(base)];

    // base 里的两个正式名都还在
    expect(all.any((t) => t.name == 'grep_files'), isTrue);
    expect(all.any((t) => t.name == 'web_search'), isTrue);

    // 无歧义的别名照旧生成，且能真正跑（转调正式工具执行体）
    final grepAlias = all.where((t) => t.name == 'Grep');
    expect(grepAlias, hasLength(1));
    final result = await (grepAlias.single.executable! as Function)(
      const <String, dynamic>{'pattern': 'x'},
    );
    expect(result, 'ok');

    // 解析函数与注册结果一致：别名只指向一个正式名
    expect(resolveToolName('Grep'), 'grep_files');
    expect(resolveToolName('WebSearch'), 'web_search');
  });
}
