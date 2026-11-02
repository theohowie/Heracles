// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 技能 / MCP / 自动化 三页**（2026-11-02，对应 #4/T1）。
//
// 钉住：接口未接通时如实降级、不假保存、不假数据；
// 自动化：保存后**重新读回**再渲染（不乐观假成功）；文案不得写"到点自动执行"。

import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/view_options.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/widgets/workspace_drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/secure_storage_mock.dart';
import 'package:heracles/screens/automation_screen.dart';
import 'package:heracles/screens/mcp_screen.dart';
import 'package:heracles/screens/skills_screen.dart';
import 'package:heracles/theme/app_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildHeraclesTheme(),
      builder: (context, inner) => HueScope(
        hue: Hue.darkHue,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: child,
    );

void main() {
  testWidgets('★ 技能页：接口未接通如实说明 + 用户技能目录/权限规则', (tester) async {
    await tester.pumpWidget(_wrap(const SkillsScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('skills-unavailable')), findsOneWidget);
    expect(find.textContaining('技能接口未接通'), findsOneWidget);
    expect(find.textContaining('.heracles/skills'), findsOneWidget);
    expect(find.textContaining('不绕过工具审批门禁'), findsOneWidget);
    // 不许出现假开关
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('★★ MCP：提交必须明确失败，不许假保存成功', (tester) async {
    await tester.pumpWidget(_wrap(const McpScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mcp-empty')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('mcp-name')), 'demo');
    await tester.ensureVisible(find.byKey(const Key('mcp-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mcp-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mcp-submit-error')), findsOneWidget);
    expect(find.textContaining('未保存'), findsOneWidget);
    expect(find.textContaining('已保存'), findsNothing,
        reason: '没有通道时绝不允许显示保存成功');
    // 校验规则必须写清"密钥不许进 env"
    expect(find.textContaining('密钥不许放进 env'), findsOneWidget);
  });

  testWidgets('★★ 自动化：保存后重新读回再渲染（不乐观假成功）', (tester) async {
    var stored = '[]';
    var saveCalls = 0;
    await tester.pumpWidget(_wrap(AutomationScreen(
      load: () async => stored,
      save: (json) async {
        saveCalls++;
        stored = json; // 模拟后端写入
        return true;
      },
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('automation-empty')), findsOneWidget);
    // 语义红线文案（后端 §12，2026-11-02 改口径）：
    //   到点写"待执行"标记；App 没打开时只提醒，下次打开/回到 App 时执行。
    expect(find.textContaining('到点后在你下次打开/回到 App 时自动执行'),
        findsOneWidget,
        reason: '文案必须照后端 §12 写清"下次打开/回到 App 才执行"');
    expect(find.textContaining('App 没打开时只提醒'), findsOneWidget,
        reason: '必须说清 App 没打开时只提醒 —— 否则用户以为后台会自动跑');
    expect(find.textContaining('到点自动执行'), findsNothing,
        reason: '不许承诺"到点自动执行"（没有任何后台自动跑的路径）');

    await tester.tap(find.byKey(const Key('automation-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('automation-title')), '喝水');
    await tester.enterText(find.byKey(const Key('automation-prompt')), '提醒喝水');
    await tester.enterText(find.byKey(const Key('automation-interval')), '30');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saveCalls, 1);
    // 读回后渲染：标题来自 stored（不是本地乐观插入）
    expect(find.text('喝水'), findsOneWidget);
    expect(find.textContaining('每 30 分钟'), findsOneWidget);
    final decoded = jsonDecode(stored) as List;
    expect(decoded.length, 1);
  });

  testWidgets('★★ 自动化：cron 入口置灰 + 明说未实现（不许静默忽略）', (tester) async {
    await tester.pumpWidget(_wrap(AutomationScreen(
      load: () async => '[]',
      save: (_) async => true,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('automation-add')));
    await tester.pumpAndSettle();

    // ① 入口在：用户要能看见"有 cron 这回事"，而不是被悄悄抹掉
    expect(find.byKey(const Key('automation-cron-disabled')), findsOneWidget,
        reason: 'cron 入口不许静默消失 —— 要置灰并说明，而不是藏起来');

    // ② 明说未实现（原话要能读出来）
    expect(find.textContaining('当前版本只支持固定间隔；cron 未实现'), findsOneWidget,
        reason: '必须写明"只支持固定间隔、cron 未实现"');
    expect(find.textContaining('按 cron 表达式'), findsOneWidget);

    // ③ 真的不可用：开关 onChanged == null（点不动）且恒为关
    final sw = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const Key('automation-cron-disabled')),
        matching: find.byType(Switch),
      ),
    );
    expect(sw.onChanged, isNull,
        reason: 'cron 必须真的不可用 —— 能打开却没有调度实现，'
            '等于给用户一条永远不跑的任务');
    expect(sw.value, isFalse, reason: 'cron 不允许处于"已启用"状态');

    // ④ 没有可填 cron 的输入框：只有 标题/提示词/间隔 三个。
    //    这条防"以后有人顺手把 cron 输入加回来"。
    expect(find.byType(TextField), findsNWidgets(3),
        reason: '对话框只应有 标题/提示词/间隔 三个输入；'
            '多一个就意味着 cron 又被放开了');
  });

  testWidgets('★★ 自动化：保存失败 ⇒ 显示原因且列表不新增（不假成功）', (tester) async {
    await tester.pumpWidget(_wrap(AutomationScreen(
      load: () async => '[]',
      save: (_) async => false,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('automation-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('automation-title')), '失败任务');
    await tester.enterText(find.byKey(const Key('automation-prompt')), 'x');
    await tester.enterText(find.byKey(const Key('automation-interval')), '10');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('automation-error')), findsOneWidget);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.text('失败任务'), findsNothing, reason: '保存失败不许把任务插进列表');
  });

testWidgets('★★ 抽屉：三行按序出现（自动化 → Skill → MCP），点击各自回调', (tester) async {
  var openAutomation = 0, openSkills = 0, openMcp = 0;
  await tester.pumpWidget(_wrap(_drawer(
    onAutomation: () => openAutomation++,
    onSkills: () => openSkills++,
    onMcp: () => openMcp++,
  )));
  await _settleDrawer(tester);

  // Key 精确定位（不用 .first）
  final automationRow = find.byKey(const Key('drawer-nav-automation'));
  final skillsRow = find.byKey(const Key('drawer-nav-skills'));
  final mcpRow = find.byKey(const Key('drawer-nav-mcp'));
  expect(automationRow, findsOneWidget);
  expect(skillsRow, findsOneWidget);
  expect(mcpRow, findsOneWidget);

  // Key 在、文字也必须对（防 Key 挂在错误的行上）
  expect(find.descendant(of: automationRow, matching: find.text('自动化任务')),
      findsOneWidget);
  expect(find.descendant(of: skillsRow, matching: find.text('Skill')),
      findsOneWidget);
  expect(find.descendant(of: mcpRow, matching: find.text('MCP 服务器')),
      findsOneWidget);

  // 顺序：Y 坐标递增 —— 自动化任务 → Skill → MCP 服务器
  final yAutomation = tester.getTopLeft(automationRow).dy;
  final ySkills = tester.getTopLeft(skillsRow).dy;
  final yMcp = tester.getTopLeft(mcpRow).dy;
  expect(yAutomation, lessThan(ySkills),
      reason: '顺序（用户定）：自动化任务 在 Skill 之上');
  expect(ySkills, lessThan(yMcp),
      reason: '顺序（用户定）：Skill 在 MCP 服务器之上');

  // 位置：必须在 _header 之后、_SectionHeader（搜索/添加行）之前 ——
  // 用「工作区」分区标签当锚（它属于 _SectionHeader，必须排在三行之下）
  final sectionLabel = find.text('工作区');
  expect(sectionLabel, findsOneWidget,
      reason: '找不到分区标签 —— _SectionHeader 的结构变了，位置断言要跟着改');
  expect(yMcp, lessThan(tester.getTopLeft(sectionLabel).dy),
      reason: '三行必须插在 _header 之后、_SectionHeader 之前（用户指定的原位）');

  // 点击 → 各自回调（三行互不串扰）
  await tester.tap(automationRow);
  await _settleDrawer(tester);
  await tester.tap(skillsRow);
  await _settleDrawer(tester);
  await tester.tap(mcpRow);
  await _settleDrawer(tester);
  expect(openAutomation, 1, reason: '自动化行必须触发 onOpenAutomation');
  expect(openSkills, 1, reason: 'Skill 行必须触发 onOpenSkills');
  expect(openMcp, 1, reason: 'MCP 行必须触发 onOpenMcp');
});

testWidgets('★★ 抽屉：多选模式下三行不可见（与工作区区块行为一致）', (tester) async {
  await tester.pumpWidget(_wrap(_drawer(
    onAutomation: () {},
    onSkills: () {},
    onMcp: () {},
    // 多选模式要 batch 回调已接线才开得起来（batchWired）
    onBatchDelete: (_) {},
  )));
  await _settleDrawer(tester);

  // 三行先在
  expect(find.byKey(const Key('drawer-nav-automation')), findsOneWidget);

  // 进多选：点 _SectionHeader 的选择按钮（checkmark_square）
  await tester.tap(find.byIcon(CupertinoIcons.checkmark_square));
  await _settleDrawer(tester);

  // 三行隐藏
  expect(find.byKey(const Key('drawer-nav-automation')), findsNothing,
      reason: '多选模式下导航行必须隐藏 —— 与工作区区块行为一致');
  expect(find.byKey(const Key('drawer-nav-skills')), findsNothing);
  expect(find.byKey(const Key('drawer-nav-mcp')), findsNothing);
});

testWidgets('★ 设置页不再有 技能/MCP/自动化 三行（入口移到抽屉，单一入口）',
    (tester) async {
  installSecureStorageMock();
  SharedPreferences.setMockInitialValues({});
  final controller = await SettingsController.load();
  await tester.pumpWidget(_wrap(SettingsScreen(controller: controller)));
  await _settleDrawer(tester);

  expect(find.text('技能'), findsNothing,
      reason: '技能入口已移到抽屉 —— 设置页不许再有（两处维护必漂移）');
  expect(find.text('MCP 服务器'), findsNothing,
      reason: 'MCP 入口已移到抽屉');
  expect(find.text('自动化任务'), findsNothing,
      reason: '自动化入口已移到抽屉');
  // 沙箱行不动（用户明确保留）
  expect(find.text('沙箱'), findsOneWidget,
      reason: '沙箱入口必须留在设置页 —— 用户令"沙箱行不动"');
});
}

WorkspaceDrawer _drawer({
  VoidCallback? onAutomation,
  VoidCallback? onSkills,
  VoidCallback? onMcp,
  void Function(List<(String, String)> items)? onBatchDelete,
}) =>
    WorkspaceDrawer(
      workspaces: const [],
      onSelectSession: (_, _) {},
      onNewSession: (_) {},
      onOpenSettings: () {},
      viewOptions: const ViewOptions(),
      onViewOptionsChanged: (_) {},
      searchQuery: '',
      onSearchChanged: (_) {},
      onOpenAutomation: onAutomation,
      onOpenSkills: onSkills,
      onOpenMcp: onMcp,
      onBatchDeleteSessions: onBatchDelete,
    );


/// ★ 不用 `pumpAndSettle`：抽屉里有常驻动画（loading 态的转圈）会超时
///   （`workspace_drawer_add_menu_test.dart` 同款手法 —— 固定推虚拟时钟）。
Future<void> _settleDrawer(WidgetTester tester, {int times = 10}) async {
  for (var i = 0; i < times; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
