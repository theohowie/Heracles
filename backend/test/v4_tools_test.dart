// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 新工具 + 别名映射测试（T1-4）**。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | 无 Web 能力 ⇒ web_search 一调用就失败、明说"不支持" | 工具静默消失/假结果 |
// | ② | 有能力但未配置搜索 ⇒ 明确"未配置"，不编结果 | 编造搜索结果 |
// | ③ | 有搜索能力 ⇒ 结果带来源 URL | 无来源（无法核对） |
// | ④ | notify_user 权限失败 ⇒ 如实失败（不假装成功） | 假成功（用户等不到通知） |
// | ⑤ | 别名解析：正式名/别名/未知（不猜） | 猜错工具（静默执行错东西） |
// | ⑥ | 别名只增：旧正式名仍全部可解析 | 把正式名改成别名（破坏旧会话） |
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

class _UnconfiguredSearch extends WebCapability {
  @override
  Future<CapabilityResult> fetch(String url, {int maxChars = 50000}) async =>
      const CapabilitySuccess('page');
  @override
  Future<CapabilityResult> search(String query, {int limit = 5}) async =>
      const CapabilityFailure('未配置搜索服务（宿主未提供 web_search 能力）');
}

class _WorkingSearch extends WebCapability {
  @override
  Future<CapabilityResult> fetch(String url, {int maxChars = 50000}) async =>
      const CapabilitySuccess('page');
  @override
  Future<CapabilityResult> search(String query, {int limit = 5}) async =>
      const CapabilitySuccess(
        '1. Dart 官方文档\n   摘要…\n   来源：https://dart.dev/guides\n'
        '2. 另一条\n   来源：https://example.com/a',
      );
}

class _DeniedNotify implements NotificationCapability {
  @override
  Future<CapabilityResult> notify(String title, String body, {String? id}) async =>
      const CapabilityFailure('通知权限被拒绝（请在系统设置里允许通知）');
}

class _OkNotify implements NotificationCapability {
  @override
  Future<CapabilityResult> notify(String title, String body, {String? id}) async =>
      const CapabilitySuccess('已发送通知');
}

String _text(AgentToolResult r) {
  final parts = r.contents ??
      (r.content == null ? const <UserContentPart>[] : <UserContentPart>[r.content!]);
  return parts.map((p) => p is TextPart ? p.text : p.toString()).join('\n');
}

bool _failed(AgentToolResult r) {
  final t = _text(r);
  return t.startsWith('未执行：') || t.startsWith('失败（');
}
Tool _tool(List<Tool> tools, String name) =>
    tools.firstWhere((t) => t.name == name);

/// 取 AgentToolResult 里给模型看的文本（工具层失败用文本前缀表示）。
String _textOfToolResult(dynamic r) {
  if (r is AgentToolResult) {
    final parts = r.contents ??
        (r.content == null ? const <UserContentPart>[] : <UserContentPart>[r.content!]);
    return parts.map((p) => p is TextPart ? p.text : p.toString()).join('\n');
  }
  return r.toString();
}

void main() {
  group('web_search', () {
    test('① 无 Web 能力 ⇒ 工具仍在列表但一调用就失败（明说不支持）', () async {
      final tools = buildV4Tools(const ToolFactory(Capabilities()), const Capabilities());
      final r = await _tool(tools, 'web_search').executable!(const <String, dynamic>{'query': 'dart'});
      expect(_failed(r), isTrue);
      expect(_text(r), contains('不支持'));
    });

    test('② 能力未配置搜索 ⇒ 明确"未配置"，不编结果', () async {
      final caps = Capabilities(web: _UnconfiguredSearch());
      final tools = buildV4Tools(ToolFactory(caps), caps);
      final r = await _tool(tools, 'web_search')
          .executable!(const <String, dynamic>{'query': 'dart'});
      expect(_failed(r), isTrue);
      expect(_text(r), contains('未配置搜索服务'));
      expect(_text(r).contains('来源'), isFalse, reason: '★ 未配置时不许编造结果');
    });

    test('③ 有搜索能力 ⇒ 结果带来源 URL', () async {
      final caps = Capabilities(web: _WorkingSearch());
      final tools = buildV4Tools(ToolFactory(caps), caps);
      final r = await _tool(tools, 'web_search')
          .executable!(const <String, dynamic>{'query': 'dart', 'limit': 3});
      expect(_failed(r), isFalse);
      expect(_text(r), contains('https://'));
    });

    test('③b 空关键词 ⇒ 直接失败（不浪费一次网络往返）', () async {
      final caps = Capabilities(web: _WorkingSearch());
      final tools = buildV4Tools(ToolFactory(caps), caps);
      final r = await _tool(tools, 'web_search')
          .executable!(const <String, dynamic>{'query': '   '});
      expect(_failed(r), isTrue);
      expect(_text(r), contains('不能为空'));
    });
  });

  group('notify_user', () {
    test('④ 权限被拒 ⇒ 如实失败（不假装发送成功）', () async {
      final caps = Capabilities(notification: _DeniedNotify());
      final tools = buildV4Tools(ToolFactory(caps), caps);
      final r = await _tool(tools, 'notify_user')
          .executable!(const <String, dynamic>{'title': '完成', 'body': '任务跑完了'});
      expect(_failed(r), isTrue);
      expect(_text(r), contains('权限'));
    });

    test('④b 成功 ⇒ 明确成功', () async {
      final caps = Capabilities(notification: _OkNotify());
      final tools = buildV4Tools(ToolFactory(caps), caps);
      final r = await _tool(tools, 'notify_user')
          .executable!(const <String, dynamic>{'title': '完成', 'body': '好了'});
      expect(_failed(r), isFalse);
    });

    test('④c 无通知能力 ⇒ 工具不可用且调用即失败', () async {
      final tools = buildV4Tools(const ToolFactory(Capabilities()), const Capabilities());
      final r = await _tool(tools, 'notify_user').executable!(const <String, dynamic>{'title': 't', 'body': 'b'});
      expect(_failed(r), isTrue);
    });
  });

  group('别名映射', () {
    test('⑤ 正式名 / 已知别名 / 未知（不猜）', () {
      expect(resolveToolName('read_file'), 'read_file');
      expect(resolveToolName('Read'), 'read_file');
      expect(resolveToolName('Grep'), 'grep_files');
      expect(resolveToolName('Exec'), 'run_shell_command');
      expect(resolveToolName('WebSearch'), 'web_search');
      expect(resolveToolName('这不是工具'), isNull, reason: '★ 未知必须 null，不许猜');
      expect(resolveToolName(''), isNull);
    });

    test('⑥ 别名只增：每个正式名仍能解析到自己', () {
      for (final canonical in toolAliases.keys) {
        expect(resolveToolName(canonical), canonical,
            reason: '★ 正式名不许被改成别名（会破坏旧会话/旧测试）');
      }
      // 别名集合里不应出现正式名（否则映射自指）
      for (final aliases in toolAliases.values) {
        for (final a in aliases) {
          expect(toolAliases.containsKey(a), isFalse,
              reason: '别名 $a 与正式名冲突');
        }
      }
    });

    test('⑦ 执行层：别名作为独立 Tool 注册且能真正转调正式工具', () async {
      final caps = Capabilities(web: _WorkingSearch());
      final base = buildV4Tools(ToolFactory(caps), caps);
      final all = [...base, ...buildAliasTools(base)];
      // 正式名仍在
      expect(all.any((t) => t.name == 'web_search'), isTrue);
      // 别名已注册（框架按 name 精确匹配，光有解析函数不够）
      final alias = all.firstWhere((t) => t.name == 'WebSearch');
      expect(alias.description, _tool(base, 'web_search').description,
          reason: '别名应复制正式工具的描述/schema');
      // 别名能真正跑（转调正式工具的执行体）
      final r = await alias.executable!(const <String, dynamic>{'query': 'dart'});
      final text = _textOfToolResult(r);
      expect(text, contains('https://'), reason: '转调后结果与正式工具一致');
    });

    test('⑦b 未存在的正式工具不生成别名（不凭空造工具）', () {
      // 只有 web_search 的极小工具集 ⇒ 不应出现 Read/Grep 等别名
      final caps = Capabilities(web: _WorkingSearch());
      final base = buildV4Tools(ToolFactory(caps), caps);
      final all = [...base, ...buildAliasTools(base)];
      expect(all.any((t) => t.name == 'Read'), isFalse,
          reason: '★ 没有 read_file 时不许造 Read 别名');
      expect(all.any((t) => t.name == 'Grep'), isFalse);
    });
  });
}
