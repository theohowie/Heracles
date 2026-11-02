// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 技能页**（2026-11-02，对应 #4/T1）。
//
// 真实能力边界（不许假装更多）：
// · 后端有 `SkillEntry / SkillRegistry`（`backend/lib/src/agent/v4_extensions.dart`），
//   用户技能由 `LocalAgentExecutor._scanUserSkills` 扫描工作区
//   `.heracles/skills/**/SKILL.md` 后注入；
// · **App 侧没有 skills 通道方法** ⇒ 本页只能展示「来源与规则说明 + 降级」，
//   不画启用/停用假开关，不编造技能清单。

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

class SkillsScreen extends StatelessWidget {
  const SkillsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('技能'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
        children: [
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
                Text('技能接口未接通',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: h.text)),
                const SizedBox(height: 6),
                Text(
                  '当前版本没有技能列表通道：技能由后端按工作区注入（内置技能 + 用户技能），'
                  'App 侧还不能列出/启用/停用/安装。这里如实说明，不显示假开关。',
                  style: TextStyle(
                      fontSize: 12, height: 1.55, color: h.textFaint),
                ),
              ],
            ),
          ),
          const SizedBox(height: HSpace.md),
          Text('用户技能目录与扫描规则',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: h.textDim)),
          const SizedBox(height: 6),
          Text(
            '把技能放在工作区的 `.heracles/skills/<名字>/SKILL.md`。'
            '启动任务时后端会扫描该目录，把技能说明注入到本轮上下文。'
            'SKILL.md 需要 `---` 头（name / description）＋正文。',
            style: TextStyle(fontSize: 12, height: 1.6, color: h.textFaint),
          ),
          const SizedBox(height: HSpace.md),
          Text('权限说明',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: h.textDim)),
          const SizedBox(height: 6),
          Text(
            '技能只影响"模型看到什么说明"，不绕过工具审批门禁：'
            '技能里要求的命令/写文件仍走同一套 Allow / NeedsApproval / Deny 判定。',
            style: TextStyle(fontSize: 12, height: 1.6, color: h.textFaint),
          ),
        ],
      ),
    );
  }
}
