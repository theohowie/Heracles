// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 技能 / MCP / 自动化 三页**（2026-11-02，对应 #4/T1）。
//
// 钉住：接口未接通时如实降级、不假保存、不假数据；
// 自动化：保存后**重新读回**再渲染（不乐观假成功）；文案不得写"到点自动执行"。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    // 语义红线文案
    expect(find.textContaining('不会自动运行 agent'), findsOneWidget);
    expect(find.textContaining('到点自动执行'), findsNothing);

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
}
