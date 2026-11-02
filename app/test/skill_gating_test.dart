import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/skill_gating.dart';
import 'package:heracles_backend/heracles_backend.dart';

/// **技能启停运行时闸门** —— V0.4 F1 收口（2026-11-02）。
///
/// 这个文件锁的是一条**曾经完全不生效**的产品行为：用户在 Skills 页把技能关掉，
/// 模型照样在用。修它的方式是在 `LocalAgentExecutor._scanUserSkills()` 里按启用
/// 集合过滤，而过滤的判断抽成了 [filterEnabledSkills]（纯函数，能在这里钉死）。
///
/// 最关键的一条是 **`null` ⇒ 不筛**：读不到启停表（旧宿主 / 通道缺失 / 读失败）
/// 时必须放行。写错这一条，用户升级 App 后会觉得"我的技能全没了"。
void main() {
  SkillEntry entry(String name) =>
      SkillEntry(name: name, description: '', body: '正文-$name', source: 'user');

  group('filterEnabledSkills', () {
    test('★★★ enabledNames 为 null ⇒ 不筛（读不到启停表时不许把技能全杀掉）', () {
      final all = [entry('a'), entry('b')];
      final out = filterEnabledSkills(all, null);

      expect(out.length, 2);
      expect(out.map((e) => e.name), ['a', 'b']);
    });

    test('★★★ 空集合 ⇒ 全部过滤（用户确实把每个都关了，这是真实意图）', () {
      final all = [entry('a'), entry('b')];
      expect(filterEnabledSkills(all, const <String>{}), isEmpty);
    });

    test('★★ 只留启用的，且保持原顺序', () {
      final all = [entry('a'), entry('b'), entry('c')];
      final out = filterEnabledSkills(all, {'c', 'a'});

      expect(out.map((e) => e.name), ['a', 'c'], reason: '顺序必须跟原清单一致');
    });

    test('★ 名字精确匹配（不做大小写归一 —— 启停表就是按名字存的）', () {
      final all = [entry('VerifyLoop')];
      expect(filterEnabledSkills(all, {'verifyloop'}), isEmpty);
      expect(filterEnabledSkills(all, {'VerifyLoop'}).length, 1);
    });

    test('★ 与内置技能共用一张表（source 不参与判断）', () {
      final builtin = builtinSkillEntries();
      final only = filterEnabledSkills(builtin, {'verify-loop'});

      expect(only.length, 1);
      expect(only.single.name, 'verify-loop');
      expect(only.single.source, ContractSkills.sourceBuiltin);
    });

    test('★ 空输入 ⇒ 空输出（不抛）', () {
      expect(filterEnabledSkills(const <SkillEntry>[], null), isEmpty);
      expect(filterEnabledSkills(const <SkillEntry>[], {'a'}), isEmpty);
    });
  });
}
