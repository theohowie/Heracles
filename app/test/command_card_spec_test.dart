// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **命令卡片规格验收测试**（2026-10-29 用户逐条给的规格）。
//
// 这个文件不是"随便测测"，它逐条对应规格里的可判定项：
//   · 标题只说要哪执行，不带命令内容；执行中/失败各有文案
//   · 卡内第一行有 SandBox / Shell 标签（拼写严格如此）
//   · 不出现「命令」「结果」标签行
//   · 退出码**只用结构化值**，拿不到就不显示（绝不编造 0）
//   · 结果里的「【命令输出开始】」包裹标记和「（执行面：xxx）」前缀要剥掉
//   · 执行中只有命令层 + 一行「执行中…」

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/tool_call_card.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        home: Scaffold(
          body: HueScope(
            hue: Hue.darkHue,
            child: SingleChildScrollView(child: child),
          ),
        ),
      );

  HToolCall call({
    ToolStatus status = ToolStatus.success,
    String? surface,
    int? exitCode,
    String? command,
    String? result,
  }) =>
      HToolCall(
        id: 't1',
        tool: 'run_shell_command',
        args: const {'command': 'echo hi'},
        status: status,
        surface: surface,
        exitCode: exitCode,
        command: command,
        result: result,
      );

  /// 展开卡片（点标题行）。
  /// 展开卡片。
  ///
  /// ⚠️ 不能用 `pumpAndSettle`：执行中状态有 `CircularProgressIndicator`
  /// 一直在转，永远不会 settle ⇒ 测试会以 timeout 失败（不是功能坏了）。
  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.byType(ToolCallCard));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  // ── 标题行 ────────────────────────────────────────────────────────

  group('标题行文案', () {
    testWidgets('★ 沙箱：只说「在沙箱执行了命令」，不带命令内容', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(surface: 'sandbox', exitCode: 0, command: 'echo hi'),
      )));
      await tester.pump();

      expect(find.text('在沙箱执行了命令'), findsOneWidget);
      // 规格：**标题**不带命令内容（命令全文只在卡里）。
      // 不能扫全树 —— 展开后命令层里本来就有命令全文。
      final title = tester.widget<Text>(find.text('在沙箱执行了命令'));
      expect(title.data!.contains('echo hi'), isFalse);
    });

    testWidgets('★ 手机：「在手机执行了命令」', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(surface: 'device', exitCode: 0),
      )));
      await tester.pump();
      expect(find.text('在手机执行了命令'), findsOneWidget);
    });

    testWidgets('★ 执行中：「正在沙箱执行命令」', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(status: ToolStatus.running, surface: 'sandbox'),
      )));
      await tester.pump();
      expect(find.text('正在沙箱执行命令'), findsOneWidget);
    });

    testWidgets('★ 失败：末尾加「（失败）」', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(
          status: ToolStatus.failure,
          surface: 'sandbox',
          exitCode: 127,
          result: '失败（这条路不通，不要重试）：command not found',
        ),
      )));
      await tester.pump();
      expect(find.text('在沙箱执行了命令（失败）'), findsOneWidget);
    });
  });

  // ── 卡片本体 ──────────────────────────────────────────────────────

  group('卡内结构', () {
    testWidgets('★ 第一行有 SandBox 标签（拼写严格）', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(surface: 'sandbox', exitCode: 0, command: 'echo hi'),
      )));
      await tester.pump();
      await expand(tester);
      expect(find.text('SandBox'), findsOneWidget);
    });

    testWidgets('★ 手机执行时标签是 Shell（不是 Android / 手机）', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(surface: 'device', exitCode: 0, command: 'echo hi'),
      )));
      await tester.pump();
      await expand(tester);
      expect(find.text('Shell'), findsOneWidget);
      expect(find.text('SandBox'), findsNothing);
    });

    testWidgets('★ 不出现「命令」「结果」标签行', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(
          surface: 'sandbox',
          exitCode: 0,
          command: 'echo hi',
          result: 'hi',
        ),
      )));
      await tester.pump();
      await expand(tester);
      expect(find.text('命令'), findsNothing);
      expect(find.text('结果'), findsNothing);
    });

    testWidgets('★ 不显示执行时间', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(surface: 'sandbox', exitCode: 0, result: 'hi'),
      )));
      await tester.pump();
      await expand(tester);
      // 任何 "ms"/"耗时"/"用时" 都不许出现
      expect(find.textContaining('ms'), findsNothing);
      expect(find.textContaining('耗时'), findsNothing);
      expect(find.textContaining('用时'), findsNothing);
    });
  });

  // ── 退出码 chip ───────────────────────────────────────────────────

  group('退出码 chip（结构化优先，不许编造）', () {
    testWidgets('★★ 有结构化 exitCode ⇒ 显示「退出码 3」', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(surface: 'sandbox', exitCode: 3, result: 'boom'),
      )));
      await tester.pump();
      await expand(tester);
      expect(find.text('退出码 3'), findsOneWidget);
    });

    testWidgets('★★★ 成功但**没有**结构化 exitCode ⇒ 不显示 chip（不许当 0）',
        (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        // status=success 但 exitCode=null：旧实现会编造成 0
        call: call(surface: 'sandbox', exitCode: null, result: 'hi'),
      )));
      await tester.pump();
      await expand(tester);

      expect(find.textContaining('退出码'), findsNothing,
          reason: '★ 成功≠退出码 0；拿不到结构化值就不显示，不许编造');
    });

    testWidgets('★ 结构化缺失时退而解析文本里的「命令退出码：N」', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(
          status: ToolStatus.failure,
          surface: 'sandbox',
          exitCode: null,
          result: '失败（这条路不通，不要重试）：boom\n（命令退出码：42）',
        ),
      )));
      await tester.pump();
      await expand(tester);
      expect(find.text('退出码 42'), findsOneWidget);
    });

    testWidgets('★ 执行中还没有退出码 ⇒ 只悬浮「复制」', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(status: ToolStatus.running, surface: 'sandbox'),
      )));
      await tester.pump();
      await expand(tester);
      expect(find.text('复制'), findsOneWidget);
      expect(find.textContaining('退出码'), findsNothing);
      expect(find.textContaining('执行中…'), findsOneWidget);
    });
  });

  // ── 文本清洗 ──────────────────────────────────────────────────────

  group('结果文本清洗', () {
    testWidgets('★★ 剥掉「【命令输出开始】/【命令输出结束】」包裹标记', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(
          surface: 'sandbox',
          exitCode: 0,
          result: '【命令输出开始】\nhello\n【命令输出结束】',
        ),
      )));
      await tester.pump();
      await expand(tester);

      expect(find.textContaining('【命令输出开始】'), findsNothing,
          reason: '包裹标记是给模型的边界，不该出现在卡片里');
      expect(find.textContaining('【命令输出结束】'), findsNothing);
      expect(find.textContaining('hello'), findsWidgets);
    });

    testWidgets('★★ 剥掉「（执行面：sandbox）」前缀', (tester) async {
      await tester.pumpWidget(wrap(ToolCallCard(
        call: call(
          status: ToolStatus.failure,
          surface: 'sandbox',
          exitCode: 127,
          result: '（执行面：sandbox）失败（这条路不通，不要重试）：command not found',
        ),
      )));
      await tester.pump();
      await expand(tester);
      expect(find.textContaining('执行面：'), findsNothing);
    });
  });
}
