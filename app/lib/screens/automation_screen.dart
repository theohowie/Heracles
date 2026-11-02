// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 自动化任务页**（2026-11-02，对应 #4/T1）。
//
// 真实通道（`AgentBridge.saveAutomationTasks / loadAutomationTasks`）：
//   · 保存成功后**重新读回**再渲染（不许乐观假成功）；
//   · 失败显示原因；
//   · **语义红线（后端 §12）**：到点写"待执行"标记；App 没打开时只提醒，
//     下次打开/回到 App 时再执行 ⇒ 页面文案照这条写，不许写"到点自动执行"。
//   · **调度只支持固定间隔**：后端本轮只注册 interval 闹钟 ⇒ cron 入口**置灰**
//     且写明未实现（允许填 cron 会得到一条永远不跑的任务，静默忽略更糟）。
//
// load/save 可注入（测试用），默认走 AgentBridge。

import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/agent_bridge.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

class AutomationScreen extends StatefulWidget {
  const AutomationScreen({super.key, this.load, this.save});

  final Future<String> Function()? load;
  final Future<bool> Function(String tasksJson)? save;

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  late final AgentBridge _bridge = AgentBridge();
  late final Future<String> Function() _load =
      widget.load ?? () => _bridge.loadAutomationTasks();
  late final Future<bool> Function(String) _save =
      widget.save ?? (j) => _bridge.saveAutomationTasks(j);

  List<Map<String, dynamic>> _tasks = const <Map<String, dynamic>>[];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final raw = await _load();
      final decoded = raw.trim().isEmpty ? const <dynamic>[] : jsonDecode(raw);
      final list = <Map<String, dynamic>>[];
      if (decoded is List) {
        for (final e in decoded) {
          if (e is Map) list.add(e.cast<String, dynamic>());
        }
      }
      if (!mounted) return;
      setState(() {
        _tasks = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取自动化任务失败：$e';
      });
    }
  }

  Future<void> _addTask() async {
    final title = TextEditingController();
    final prompt = TextEditingController();
    final interval = TextEditingController(text: '60');
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final h = Hue.of(ctx);
        return AlertDialog(
          backgroundColor: h.surface,
          title: Text('新建自动化任务',
              style: TextStyle(fontSize: 16, color: h.text)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    key: const Key('automation-title'),
                    controller: title,
                    decoration: const InputDecoration(labelText: '标题')),
                TextField(
                    key: const Key('automation-prompt'),
                    controller: prompt,
                    decoration: const InputDecoration(labelText: '提示词')),
                TextField(
                    key: const Key('automation-interval'),
                    controller: interval,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '间隔（分钟）')),
                // ★ cron 入口：**置灰 + 写明未实现**（后端本轮只注册 interval 闹钟）。
                //   允许填 cron ⇒ 用户存下一条永远不会跑的任务；静默忽略更糟。
                //   所以这里既**不给填**，也**明说为什么**。
                Container(
                  key: const Key('automation-cron-disabled'),
                  margin: const EdgeInsets.only(top: 14),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: h.surfaceAlt,
                    borderRadius: BorderRadius.circular(HRadius.md),
                  ),
                  child: Row(
                    children: [
                      Icon(AppIcons.clock, size: 15, color: h.textFaint),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('按 cron 表达式',
                                style: TextStyle(
                                    fontSize: 12.5, color: h.textFaint)),
                            const SizedBox(height: 2),
                            Text('当前版本只支持固定间隔；cron 未实现',
                                key: const Key('automation-cron-note'),
                                style: TextStyle(
                                    fontSize: 11,
                                    height: 1.4,
                                    color: h.textFaint)),
                          ],
                        ),
                      ),
                      // 一眼看出不可用：禁用的开关（点不动、置灰）
                      const Switch(value: false, onChanged: null),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('保存')),
          ],
        );
      },
    );
    if (created != true) return;
    if (!mounted) return;
    final t = title.text.trim();
    final p = prompt.text.trim();
    final iv = int.tryParse(interval.text.trim()) ?? 0;
    if (t.isEmpty || p.isEmpty || iv <= 0) {
      setState(() => _error = '标题/提示词不能为空，间隔必须是正整数分钟');
      return;
    }
    final next = <Map<String, dynamic>>[
      ..._tasks,
      <String, dynamic>{
        'id': 'auto-${DateTime.now().millisecondsSinceEpoch}',
        'title': t,
        'prompt': p,
        'intervalMinutes': iv,
        'enabled': true,
      },
    ];
    await _persist(next);
  }

  Future<void> _persist(List<Map<String, dynamic>> next) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await _save(jsonEncode(next));
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _error = '保存失败：后端拒绝或通道不可用（未写入）';
        });
        return;
      }
      // 保存成功后**重新读回**再渲染（不乐观假成功）
      await _reload();
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '保存失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('自动化任务'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            key: const Key('automation-add'),
            icon: const Icon(Icons.add),
            onPressed: _busy ? null : _addTask,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
        children: [
          Text(
            '到点后在你下次打开/回到 App 时自动执行；App 没打开时只提醒。',
            key: const Key('automation-semantics'),
            style: TextStyle(fontSize: 11.5, height: 1.55, color: h.textFaint),
          ),
          const SizedBox(height: HSpace.md),
          if (_loading)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)))),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!,
                  key: const Key('automation-error'),
                  style: TextStyle(fontSize: 12, color: h.accent)),
            ),
          if (!_loading && _tasks.isEmpty && _error == null)
            Container(
              key: const Key('automation-empty'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: h.surfaceAlt,
                borderRadius: BorderRadius.circular(HRadius.xl),
              ),
              child: Text('还没有自动化任务。点右上角 + 新建一条（定时提醒）。',
                  style: TextStyle(
                      fontSize: 12, height: 1.5, color: h.textFaint)),
            ),
          for (final t in _tasks)
            ListTile(
              key: Key('automation-${t['id']}'),
              contentPadding: EdgeInsets.zero,
              title: Text((t['title'] as String?) ?? '未命名',
                  style: TextStyle(fontSize: 14, color: h.text)),
              subtitle: Text(
                '每 ${t['intervalMinutes'] ?? '?'} 分钟 · '
                '${(t['enabled'] as bool?) == true ? '已启用' : '已停用'}',
                style: TextStyle(fontSize: 11.5, color: h.textFaint),
              ),
            ),
        ],
      ),
    );
  }
}
