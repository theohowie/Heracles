// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 MCP 服务器页**（2026-11-02，对应 #4/T1）。
//
// 真实能力边界：后端有 `McpServerConfig / McpConfigStore / validateMcpServer`
// （拒绝密钥进 env），但 **App 侧没有 mcp 通道方法** ⇒ 本页只做：
// · 空态 + 表单骨架（name/transport/command/url/args/env/enabled）；
// · 提交时明确失败提示「接口未接通，未保存」，**不写入假配置**；
// · 把校验规则用人话写在页内（至少"密钥不许进 env"）。

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/elastic_switch.dart';
import '../theme/stretch_segmented.dart';

class McpScreen extends StatefulWidget {
  const McpScreen({super.key});

  @override
  State<McpScreen> createState() => _McpScreenState();
}

class _McpScreenState extends State<McpScreen> {
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _url = TextEditingController();
  String _transport = 'stdio';
  bool _enabled = true;
  String? _submitError;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    // 没有通道 ⇒ 明确失败；绝不显示"保存成功"
    setState(() {
      _submitError = 'MCP 接口未接通：本次没有保存（等后端通道落地后再启用）';
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('MCP 服务器'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
        children: [
          Container(
            key: const Key('mcp-empty'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: h.surfaceAlt,
              borderRadius: BorderRadius.circular(HRadius.xl),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('未配置',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: h.text)),
                const SizedBox(height: 6),
                Text('当前版本没有 MCP 通道：不能增删改服务器、也读不到连接状态。'
                    '下面只是表单骨架，提交会明确告诉你"未保存"。',
                    style: TextStyle(
                        fontSize: 12, height: 1.55, color: h.textFaint)),
              ],
            ),
          ),
          const SizedBox(height: HSpace.md),
          Text('校验规则（后端 validateMcpServer）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: h.textDim)),
          const SizedBox(height: 6),
          Text(
            '· 名字不能为空、不能重复；\n'
            '· transport 只支持 stdio / http；\n'
            '· stdio 必须有 command；http 必须有合法 url；\n'
            '· **密钥不许放进 env**（会拒绝保存，避免把 key 写进配置文件）；\n'
            '· 关闭的服务器不会出现在工具列表里。',
            style: TextStyle(fontSize: 12, height: 1.6, color: h.textFaint),
          ),
          const SizedBox(height: HSpace.md),
          TextField(
            key: const Key('mcp-name'),
            controller: _name,
            decoration: const InputDecoration(labelText: '名称'),
          ),
          const SizedBox(height: 8),
          // ★ 2026-11-03（§4.2）：离散 2–5 档互斥只有 StretchSegmented
          //   —— ChoiceChip 是第二套分档形态，撤。
          Text('传输方式', style: TextStyle(fontSize: 12, color: h.textDim)),
          const SizedBox(height: 6),
          StretchSegmented(
            key: const Key('mcp-transport'),
            labels: const ['stdio', 'http'],
            selected: _transport == 'stdio' ? 0 : 1,
            onSelected: (i) => setState(() => _transport = i == 0 ? 'stdio' : 'http'),
            trackColor: h.surface,
            blockColor: h.text,
            selectedLabelColor: h.bg,
            labelColor: h.textFaint,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('mcp-command'),
            controller: _command,
            decoration: const InputDecoration(labelText: 'command（stdio）'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('mcp-url'),
            controller: _url,
            decoration: const InputDecoration(labelText: 'url（http）'),
          ),
          const SizedBox(height: 8),
          // ★ 2026-11-03（§4.1）：开关只有 ElasticSwitch。
          Row(
            children: [
              const Expanded(child: Text('启用')),
              ElasticSwitch(
                key: const Key('mcp-enabled'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ],
          ),
          if (_submitError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _submitError!,
                key: const Key('mcp-submit-error'),
                style: TextStyle(fontSize: 12, color: h.accent),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('mcp-save'),
            onPressed: _submit,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
