// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 用户技能注入测试**（T1-5 宿主接线）。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | `SkillEntry.toFrameworkSkill()` 名字/描述/正文映射正确 | 用户技能注入后内容丢失 |
// | ② | `RunOptions.userSkills` 默认空（旧行为不变） | 默认多出技能（前缀变化） |
// | ③ | 停用的技能不该被注入（只注入 enabled） | 停用的技能仍在生效 |
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  test('① toFrameworkSkill 映射 name/description/正文', () {
    const e = SkillEntry(
      name: 'my-skill',
      description: '一句话说明',
      body: '正文：什么时候用、怎么做。',
      source: 'user',
    );
    final s = e.toFrameworkSkill();
    expect(s.name, 'my-skill');
    expect(s.description, '一句话说明');
    expect(s.systemPrompt, contains('正文'));
  });

  test('② RunOptions.userSkills 默认空（旧行为不变）', () {
    const o = RunOptions();
    expect(o.userSkills, isEmpty);
    expect(o.enableSkills, isFalse, reason: '库默认不开技能 ⇒ 空列表也不影响');
  });

  test('③ 只注入已启用技能（停用的不生效）', () {
    final reg = SkillRegistry([
      const SkillEntry(
          name: 'on', description: 'd', body: 'b', source: 'user', enabled: true),
      const SkillEntry(
          name: 'off', description: 'd', body: 'b', source: 'user', enabled: false),
    ]);
    final enabled = reg.enabled.map((e) => e.toFrameworkSkill()).toList();
    expect(enabled.map((s) => s.name), contains('on'));
    expect(enabled.map((s) => s.name), isNot(contains('off')),
        reason: '★ 停用的技能不该被注入');
  });
}
