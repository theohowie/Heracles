// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 工具卡**（2026-11-02，对应 #5/T1）：web_search / read_document / notify_user。
//
// 只认结构化 `status`（成功/失败），不靠文本前缀猜；来源 URL、页数/表数、
// 通知送达状态都从真实结果/参数取，缺失就如实说明，不编造。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart' show HToolCall, ToolStatus;
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/tool_call_card.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildHeraclesTheme(),
      builder: (context, inner) => HueScope(
        hue: Hue.darkHue,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

HToolCall _call(
  String tool, {
  Map<String, String> args = const <String, String>{},
  String? result,
  ToolStatus status = ToolStatus.success,
}) =>
    HToolCall(id: 'c1', tool: tool, args: args, result: result, status: status);

void main() {
  testWidgets('★★ web_search 成功：标题人话 + 查询词 + 来源 URL', (tester) async {
    await tester.pumpWidget(_wrap(ToolCallCard(
      call: _call('web_search', args: const {'query': 'dart 泛型'}, result: '''
Dart 泛型入门
讲泛型的用法
来源：https://dart.dev/guides
来源：https://example.com/generics
'''),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('联网搜索'), findsWidgets,
        reason: 'web_search 必须有人话名，不许落到"正在执行 web_search"');
    expect(find.text('dart 泛型'), findsWidgets);
    expect(find.textContaining('dart.dev/guides'), findsWidgets);
    expect(find.textContaining('example.com/generics'), findsWidgets);
  });

  testWidgets('★★ web_search 失败：显示"未配置搜索服务"，不许编来源', (tester) async {
    await tester.pumpWidget(_wrap(ToolCallCard(
      call: _call('web_search',
          args: const {'query': 'x'},
          result: '未配置搜索服务：请先在设置里填写搜索 API',
          status: ToolStatus.failure),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('v04-web-search-failure')), findsOneWidget);
    expect(find.textContaining('未配置搜索服务'), findsWidgets);
    expect(find.byKey(const Key('v04-web-search-source')), findsNothing,
        reason: '失败时不许显示任何"来源"');
  });

  testWidgets('★★ read_document 成功：文件名/类型/页数', (tester) async {
    await tester.pumpWidget(_wrap(ToolCallCard(
      call: _call('read_document', args: const {'path': '/w/报告.docx'}, result: '''
文档：/w/报告.docx
页数：3
---
正文…
'''),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('读取了文档'), findsWidgets);
    expect(find.text('报告.docx'), findsOneWidget);
    expect(find.text('Word 文档'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('★ read_document 失败：显示原因，不假装解析成功', (tester) async {
    await tester.pumpWidget(_wrap(ToolCallCard(
      call: _call('read_document',
          args: const {'path': '/w/bad.docx'},
          result: '不是合法的 docx（文件已损坏）',
          status: ToolStatus.failure),
    )));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('v04-doc-failure')), findsOneWidget);
    expect(find.textContaining('不是合法的 docx'), findsWidgets);
  });

  testWidgets('★★ notify_user：成功=已发送；失败=未送达（没送达不能绿）', (tester) async {
    await tester.pumpWidget(_wrap(ToolCallCard(
      call: _call('notify_user',
          args: const {'title': '构建完成', 'body': 'APK 已生成'},
          result: '已发送通知'),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('发送通知'), findsWidgets);
    expect(find.byKey(const Key('v04-notify-sent')), findsOneWidget);
    expect(find.text('构建完成'), findsWidgets);

    await tester.pumpWidget(_wrap(ToolCallCard(
      call: _call('notify_user',
          args: const {'title': '构建完成'},
          result: '通知权限被拒绝',
          status: ToolStatus.failure),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('v04-notify-failure')), findsOneWidget);
    expect(find.textContaining('未送达'), findsOneWidget);
    expect(find.byKey(const Key('v04-notify-sent')), findsNothing);
  });

  testWidgets('★ 未知工具回退：人名不崩、进行中仍是"正在执行 x"', (tester) async {
    expect(friendlyToolName('mystery_tool'), 'mystery_tool');
    expect(runningToolName('mystery_tool'), contains('正在执行 mystery_tool'));
    await tester.pumpWidget(_wrap(ToolCallCard(
      call: _call('mystery_tool', result: 'ok'),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('mystery_tool'), findsWidgets);
  });
}
