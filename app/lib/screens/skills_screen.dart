// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 技能页**（2026-11-02，对应 #4/T1）。
//
// 2026-11-03 重做（用户裁定）：删掉「技能接口未接通」降级页，接真数据 ——
// F1 的 `SkillsService` 已就绪（内置技能导出 + 用户技能扫描 + 启停表）：
// · 列表 = 内置 + 用户技能（name / description / enabled / source 全真实）；
// · 启停 = `ElasticSwitch` 调 `setSkillEnabled`，**结果以重读为准**（不乐观置位）；
// · `snap.errors`（非法 SKILL.md）**必须显示**（后端移交清单 §12 原话）；
// · 安装/卸载通道还没有 ⇒ **不画假按钮**，放「下一批」说明；
// · 通道异常 ⇒ 降级文案如实（skillGating 的 gating 口径），不许编列表。
//
// 能力边界照旧如实：技能只影响"模型看到什么说明"，不绕过工具审批门禁。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/skills_service.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/elastic_switch.dart';

class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key, this.service});

  /// 技能通道（F1 已就绪）。测试可注入替身；默认走真通道。
  final SkillsService? service;

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  late final SkillsService _service = widget.service ?? SkillsService();

  SkillsSnapshot? _snap;
  String? _fatal; // 整次调用抛异常（环境坏）⇒ 降级说明
  bool _loading = true;

  /// 正在启停的技能名（ElasticSwitch 禁用防连点；结果以重读为准）。
  final Set<String> _toggling = <String>{};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final snap = await _service.listSkills();
      if (!mounted) return;
      setState(() {
        _snap = snap;
        _fatal = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fatal = e.toString();
        _snap = null;
        _loading = false;
      });
    }
  }

  /// 启停：调通道，**完成后整表重读**（不乐观置位 —— 后端说了算）。
  Future<void> _toggle(SkillView skill, bool enabled) async {
    if (_toggling.contains(skill.name)) return;
    setState(() => _toggling.add(skill.name));
    try {
      final r = await _service.setSkillEnabled(skill.name, enabled);
      if (!mounted) return;
      if (!r.ok) {
        showIosToast(context, '没有生效：${r.error ?? '未知原因'}');
      }
    } catch (e) {
      if (!mounted) return;
      showIosToast(context, '没有生效：$e');
    } finally {
      if (mounted) setState(() => _toggling.remove(skill.name));
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final snap = _snap;
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('技能'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? Center(child: CupertinoActivityIndicator(color: h.accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
              children: [
                // ---- 整次调用异常 ⇒ 降级如实（不许编列表） ----
                if (_fatal != null)
                  Container(
                    key: const Key('skills-unavailable'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: h.surfaceAlt,
                      borderRadius: BorderRadius.circular(HRadius.xl),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('技能通道不可用',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: h.text)),
                        const SizedBox(height: 6),
                        Text(
                          '技能列表这次没有读出来（$_fatal）。'
                          '这里如实说明，不显示假清单。',
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.55,
                              color: h.textFaint),
                        ),
                      ],
                    ),
                  )
                else if (snap != null && !snap.ok)
                  Container(
                    key: const Key('skills-unavailable'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: h.surfaceAlt,
                      borderRadius: BorderRadius.circular(HRadius.xl),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('技能列表读取失败',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: h.text)),
                        const SizedBox(height: 6),
                        Text(
                          snap.error ?? '未知原因（宿主未说明）',
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.55,
                              color: h.textFaint),
                        ),
                      ],
                    ),
                  )
                else if (snap != null) ...[
                  // ---- 内置技能 ----
                  _groupLabel(h, '内置技能（${snap.builtin.length}）'),
                  for (final s in snap.builtin)
                    _skillRow(h, s, key: Key('skills-row-${s.name}')),
                  // ---- 用户技能 ----
                  _groupLabel(h, '用户技能（${snap.user.length}）'),
                  if (snap.user.isEmpty)
                    Text(
                      '还没有用户技能。把技能放在工作区的 '
                      '`.heracles/skills/<名字>/SKILL.md`，重启任务后出现在这里。',
                      style: TextStyle(
                          fontSize: 12, height: 1.6, color: h.textFaint),
                    )
                  else
                    for (final s in snap.user)
                      _skillRow(h, s, key: Key('skills-row-${s.name}')),
                  // ---- snap.errors：非法 SKILL.md 必须显示（§12） ----
                  if (snap.errors.isNotEmpty) ...[
                    _groupLabel(h, '扫描问题（这些技能没有生效）'),
                    for (final e in snap.errors)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          e,
                          key: const Key('skills-errors'),
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: h.accent),
                        ),
                      ),
                  ],
                ],
                const SizedBox(height: HSpace.md),
                // ---- 安装/卸载：通道还没有 ⇒ 不画假按钮，放「下一批」 ----
                Text('安装 / 卸载（下一批）',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: h.textDim)),
                const SizedBox(height: 6),
                Text(
                  '当前版本还不能从 App 里安装/卸载技能包：'
                  '内置技能随版本发行，用户技能靠把目录放进 `.heracles/skills/`。'
                  '通道落地后这里会给出安装入口。',
                  style: TextStyle(fontSize: 12, height: 1.6, color: h.textFaint),
                ),
                const SizedBox(height: HSpace.md),
                // ---- 权限说明（照旧如实） ----
                Text('权限说明',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: h.textDim)),
                const SizedBox(height: 6),
                Text(
                  '技能只影响"模型看到什么说明"，不绕过工具审批门禁：'
                  '技能里要求的命令/写文件仍走同一套 Allow / NeedsApproval / Deny 判定。',
                  style:
                      TextStyle(fontSize: 12, height: 1.6, color: h.textFaint),
                ),
              ],
            ),
    );
  }

  Widget _groupLabel(Hue h, String text) => Padding(
        padding: const EdgeInsets.only(top: HSpace.sm, bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: h.textDim)),
      );

  /// 技能行：name + description（description 空要写"无说明"，不留空行）
  /// + source 标签 + 启停 ElasticSwitch（禁用中 = 该行正在落盘）。
  Widget _skillRow(Hue h, SkillView s, {Key? key}) => Container(
        key: key,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: h.surfaceAlt,
          borderRadius: BorderRadius.circular(HRadius.md),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(s.name,
                            style: TextStyle(
                                fontSize: 14, color: h.text)),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        s.source == 'builtin' ? '内置' : '用户',
                        style: TextStyle(
                            fontSize: 11, color: h.textFaint),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.description.isEmpty ? '（无说明）' : s.description,
                    style: TextStyle(
                        fontSize: 12, height: 1.45, color: h.textFaint),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElasticSwitch(
              key: Key('skills-switch-${s.name}'),
              value: s.enabled,
              onChanged: _toggling.contains(s.name)
                  ? null
                  : (v) => _toggle(s, v),
            ),
          ],
        ),
      );
}
