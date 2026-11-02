// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 新增工具（T1-4，2026-11-02）**：`web_search` / `notify_user`。
//
// ## 两条铁律（与其它工具一致）
//
// 1. **能力缺失 ⇒ 一调用就失败并明说原因**，不返回假结果；
// 2. **不绕过门禁**：危险等级/审批/预算都由 ToolFactory 与既有 hook 统一管，
//    这里只声明参数与执行体。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../capability/capabilities.dart';
import '../../tools/tool_factory.dart';

/// 构建 V0.4 新增工具。
List<Tool> buildV4Tools(ToolFactory f, Capabilities caps) {
  final web = caps.web;
  final notification = caps.notification;

  return [
    // -------------------------------------------------------------- 联网搜索
    f.build(
      name: 'web_search',
      description: '联网搜索（返回标题 + 摘要 + 来源 URL）。'
          '适合查最新信息、确认版本/文档。**结果必须带来源**；'
          '若宿主未配置搜索服务，会明确报错而不是编造结果。',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '搜索关键词（自然语言或精确术语都可以）。',
          },
          'limit': {
            'type': 'integer',
            'description': '最多返回几条结果，默认 5，上限 10。',
            'default': 5,
          },
        },
        'required': ['query'],
      },
      isAvailable: () => web != null,
      unavailableReason: '当前环境不支持联网搜索',
      run: (args) async {
        final query = requireString(args, 'query').trim();
        if (query.isEmpty) {
          return const CapabilityFailure('搜索关键词不能为空。');
        }
        final limitRaw = args['limit'];
        final limit = limitRaw is int
            ? limitRaw.clamp(1, 10)
            : (limitRaw is num ? limitRaw.toInt().clamp(1, 10) : 5);
        // 能力层负责"未配置 ⇒ 明确失败 / 有结果 ⇒ 带来源"
        return web!.search(query, limit: limit);
      },
    ),

    // -------------------------------------------------------------- 本地通知
    f.build(
      name: 'notify_user',
      description: '给用户发一条本地通知（例如长任务完成、需要用户回来确认时）。'
          '权限被拒/无通知能力时会如实失败，不要假设已送达。',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': '通知标题（简短，一行）。',
          },
          'body': {
            'type': 'string',
            'description': '通知正文（一到两行，说清"发生了什么/要不要回来看看"）。',
          },
          'id': {
            'type': 'string',
            'description': '可选去重 id：同 id 会覆盖上一条通知。',
          },
        },
        'required': ['title', 'body'],
      },
      isAvailable: () => notification != null,
      unavailableReason: '当前环境不支持本地通知',
      run: (args) async {
        final title = requireString(args, 'title').trim();
        final body = requireString(args, 'body').trim();
        if (title.isEmpty || body.isEmpty) {
          return const CapabilityFailure('通知标题与正文都不能为空。');
        }
        final idRaw = args['id'];
        final id = idRaw is String && idRaw.trim().isNotEmpty ? idRaw.trim() : null;
        return notification!.notify(title, body, id: id);
      },
    ),
  ];
}
