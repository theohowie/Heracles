// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **命令卡片生产接线测试**（2026-10-29，P1 第 2 条）。
//
// ## 为什么必须测「聊天流」而不是只 pump 组件
//
// 2026-10-29 审计的根因不是卡片画得不对，而是**卡片根本没接进生产路径**：
// `message_row.dart` 的 `_toolLine` 把所有工具都画成 `PlainToolLine`，
// `ToolCallCard` 全仓只在测试里 `new` —— 14 条 spec 测试全绿，真机上却
// 永远看不到命令卡。所以这里的每个用例都从 **`MessageRow` 组成的
// 消息列表**（与 `chat_screen` 的列表同一入口）出发，而不是直接 pump
// `ToolCallCard`。只要接线被改回 `PlainToolLine`，这些用例必须变红。
//
// ## 覆盖哪些验收点
//
// · 命令工具 ⇒ `ToolCallCard`；非命令工具仍是 `PlainToolLine`（同一条流里）
// · 默认收起，点**整行**原地展开；展开后出现 SandBox/Shell、退出码、复制
// · 结果里的「【命令输出开始】」包裹标记 /「（执行面：…）」前缀不出现
// · 结果层 stderr 行红字 #F87171
// · 悬浮药丸：毛玻璃 BackdropFilter + rgba(28,28,30,.82)
// · 展开内容外不再套 Divider/Padding（卡片与消息流同宽；只有两层间一条分隔线）
// · 标题字号 14、行高 ≥ 44dp
// · 「复制」= 命令全文 + `cleanCommandOutput` 清洗后的结果

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_topbar.dart';
import 'package:heracles/widgets/message_row.dart';
import 'package:heracles/widgets/tool_call_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 规格色值（.docs/命令卡片要求-提示词.md 明确给定；深色值，浅色模式沿用
  // 同一结构的主题 token —— 这几处是规格点名要的固定值，见 PROTOCOL §2.6）。
  const specError = Color(0xFFF87171); // 结果层错误行红字
  const specRule = Color(0xFF232325); // 两层之间的 1px 分隔线
  const specPill = Color.fromRGBO(28, 28, 30, 0.82); // 悬浮药丸底色

  // 深色卡片底色（规格 #141415，与 Hue.darkHue.surface 一致）
  const specCardBg = Color(0xFF141415);

  /// 与 `chat_screen` 同构的聊天流：`MessageRow` 组成的列表。
  Widget stream(List<HMessage> messages) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: ListView(
            children: [
              for (final m in messages) MessageRow(message: m),
            ],
          ),
        ),
      );

  /// 一条命令工具调用（`run_shell_command`，执行面用事件字段给）。
  HToolCall shell({
    String command = 'echo hi',
    String? result = 'hi',
    ToolStatus status = ToolStatus.success,
    String surface = 'device',
    int? exitCode = 0,
  }) =>
      HToolCall(
        id: 'c1',
        tool: 'run_shell_command',
        args: {'command': command},
        result: result,
        status: status,
        surface: surface,
        exitCode: exitCode,
      );

  /// 点标题行展开（命令卡默认收起 —— 展开热区是**整行**）。
  ///
  /// 收起态整个 `ToolCallCard` 就是那 44dp 的标题行，点组件中心即点整行
  /// （与 `command_card_spec_test` 的展开手法一致）。
  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.byType(ToolCallCard));
    await tester.pump();
  }

  // ── 接线本身 ──────────────────────────────────────────────────────

  testWidgets('★ 聊天流里命令工具走 ToolCallCard，非命令工具仍是 PlainToolLine',
      (tester) async {
    await tester.pumpWidget(stream([
      shell(),
      const HToolCall(
        id: 'r1',
        tool: 'read_file',
        args: {'path': 'a.dart'},
        result: 'content',
        status: ToolStatus.success,
      ),
    ]));
    await tester.pump();

    // 命令工具：新命令卡（不再画成纯文字行）
    expect(find.byType(ToolCallCard), findsOneWidget,
        reason: '★ 生产路径必须渲染 ToolCallCard，不能只活在测试里');
    // 非命令工具：保持黑白改版后的纯文字行
    expect(find.byType(PlainToolLine), findsOneWidget,
        reason: '只有命令类工具用新卡；read_file 仍是纯文字行');
    // 非命令工具不出现命令卡内容
    expect(find.text('Shell'), findsNothing);
    expect(find.text('SandBox'), findsNothing);
    expect(find.textContaining('退出码'), findsNothing);
  });

  // ── 默认收起 / 整行展开 ───────────────────────────────────────────

  testWidgets('★★ 默认收起；点整行原地展开后出现 Shell、退出码、复制', (tester) async {
    await tester.pumpWidget(stream([
      shell(command: 'echo hi', result: 'hi', surface: 'device', exitCode: 0),
    ]));
    await tester.pump();

    // 收起态：只有标题行（只说在哪执行），卡内内容一律不渲染
    expect(find.text('在手机执行了命令'), findsOneWidget);
    expect(find.text('Shell'), findsNothing, reason: '默认收起，命令层不渲染');
    expect(find.text('复制'), findsNothing, reason: '默认收起，悬浮药丸不渲染');
    expect(find.byType(PlainToolLine), findsNothing,
        reason: '命令工具不许再退化成纯文字行');

    await expand(tester);

    // 展开态：执行面名、行号、命令、结果、退出码、复制全在
    expect(find.text('Shell'), findsOneWidget);
    expect(find.text('退出码 0'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.textContaining('echo hi'), findsOneWidget);
    expect(find.textContaining('hi'), findsWidgets);
  });

  testWidgets('★ 沙箱执行面：卡内标签是 SandBox（拼写严格）', (tester) async {
    await tester.pumpWidget(stream([
      shell(surface: 'sandbox', command: 'ls @workspace', result: 'app'),
    ]));
    await tester.pump();
    expect(find.text('在沙箱执行了命令'), findsOneWidget);
    await expand(tester);
    expect(find.text('SandBox'), findsOneWidget);
    expect(find.text('Shell'), findsNothing);
  });

  testWidgets('★ 执行中：展开后只有命令层 + 执行中行，没有退出码', (tester) async {
    await tester.pumpWidget(stream([
      shell(
        command: 'pm install -r app.apk',
        result: null,
        status: ToolStatus.running,
        // 执行中还没有退出码（结构化值也没有）
        exitCode: null,
      ),
    ]));
    await tester.pump();
    expect(find.text('正在手机执行命令'), findsOneWidget);
    expect(find.text('复制'), findsNothing, reason: '收起态不渲染药丸');
    await expand(tester);
    expect(find.textContaining('执行中…'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.textContaining('退出码'), findsNothing);
  });

  // ── 规格偏差（用户点名的 5 处 + 分隔线/字号）──────────────────────

  testWidgets('★★ 结果层不出现包裹标记/执行面前缀；错误行红字 #F87171',
      (tester) async {
    await tester.pumpWidget(stream([
      shell(
        result: '（执行面：device）【命令输出开始】\nok line\n[stderr]\nboom: bad\n【命令输出结束】',
      ),
    ]));
    await tester.pump();
    await expand(tester);

    // 清洗：给模型的边界标记与执行面前缀都不许露出来
    expect(find.textContaining('【命令输出开始】'), findsNothing);
    expect(find.textContaining('【命令输出结束】'), findsNothing);
    expect(find.textContaining('执行面：'), findsNothing);

    // 错误行（stderr 段）红字；普通结果行不是红字
    final errLine = tester.widget<Text>(find.text('boom: bad'));
    expect(errLine.style!.color, specError,
        reason: '结果层里的错误信息行必须用 #F87171');
    final okLine = tester.widget<Text>(find.text('ok line'));
    expect(okLine.style!.color, isNot(specError));
  });

  testWidgets('★★ 悬浮药丸：毛玻璃 BackdropFilter + rgba(28,28,30,.82)',
      (tester) async {
    await tester.pumpWidget(stream([shell(exitCode: 0)]));
    await tester.pump();
    await expand(tester);

    // 两个悬浮药丸：「退出码 N」chip + 「复制」按钮，**各自**带一层毛玻璃
    expect(
      find.descendant(
        of: find.byType(ToolCallCard),
        matching: find.byType(BackdropFilter),
      ),
      findsNWidgets(2),
      reason: '悬浮「退出码 + 复制」两个药丸都必须带毛玻璃',
    );
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == specPill),
      findsNWidgets(2),
      reason: '两个药丸底色都 = 规格 rgba(28,28,30,.82)',
    );
  });

  testWidgets('★★ 展开内容外不再套 Divider/Padding；两层间分隔线 #232325',
      (tester) async {
    await tester.pumpWidget(stream([shell()]));
    await tester.pump();
    await expand(tester);

    final dividers = tester
        .widgetList<Divider>(find.descendant(
          of: find.byType(ToolCallCard),
          matching: find.byType(Divider),
        ))
        .toList();
    expect(dividers, hasLength(1),
        reason: '只剩上下两层之间那一条；展开内容外不许再套一条 Divider');
    expect(dividers.single.color, specRule);

    // 卡片就是最外层：宽度 == 消息流宽度（旧 PSO 下被外层 Padding(16) 各缩 16）
    final cardBody = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).borderRadius ==
            BorderRadius.circular(20) &&
        (w.decoration as BoxDecoration).color == specCardBg);
    expect(cardBody, findsOneWidget);
    final flowWidth = tester.getSize(find.byType(ListView)).width;
    expect(tester.getSize(cardBody).width, flowWidth,
        reason: '卡片直接贴在对话流里、与标题行同宽，外层不许再有容器/Padding');
  });

  testWidgets('★ 标题行字号 14、行高 ≥ 44dp、可整行点开', (tester) async {
    await tester.pumpWidget(stream([shell()]));
    await tester.pump();
    final title = tester.widget<Text>(find.text('在手机执行了命令'));
    expect(title.style!.fontSize, 14);
    expect(tester.getSize(find.byType(ToolCallCard)).height,
        greaterThanOrEqualTo(kMinTapTarget));
  });

  // ── 复制 ─────────────────────────────────────────────────────────

  testWidgets('★★ 复制 = 命令全文 + cleanCommandOutput 清洗后的结果',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(stream([
      shell(
        command: 'echo hi',
        result: '（执行面：device）【命令输出开始】\nhello\n【命令输出结束】',
      ),
    ]));
    await tester.pump();
    await expand(tester);

    await tester.tap(find.text('复制'));
    await tester.pump();
    // 轻提示「已复制」：2.2s 后淡出（把计时器走完，避免 pending timer）
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));

    expect(copied, 'echo hi\nhello',
        reason: '复制的是清洗后的结果：不许带包裹标记/执行面前缀');
  });

  // ── 执行时间（规格硬禁止）────────────────────────────────────────

  testWidgets('★★ 结果尾注「（耗时 Nms）」不显示、也不进剪贴板', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(stream([
      shell(
        command: 'ls @workspace',
        // 真机 device 侧 `_composeText` 的尾注形状：空行 +「（耗时 Nms）」
        // （device_capabilities.dart:1428）。规格：不显示执行时间（任何位置都不许）。
        result: 'app\nlib\n\n（耗时 12ms）',
      ),
    ]));
    await tester.pump();
    await expand(tester);

    expect(find.textContaining('耗时'), findsNothing,
        reason: '★ 规格硬禁止：卡片任何位置都不许显示执行时间');
    expect(find.textContaining('ms'), findsNothing);
    expect(find.textContaining('app'), findsWidgets, reason: '结果正文仍要显示');

    await tester.tap(find.text('复制'));
    await tester.pump();
    // 轻提示计时器走完，避免 pending timer
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));

    expect(copied, 'ls @workspace\napp\nlib',
        reason: '复制沿用清洗后的结果：耗时尾注不能被粘进剪贴板');
  });

  // ── 档位 ─────────────────────────────────────────────────────────

  testWidgets('★ 命令卡默认收起与「工作步骤展示」档位无关（标准档也收起）',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildHeraclesTheme(),
      builder: (context, inner) => HueScope(
        hue: Hue.darkHue,
        child: inner ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: ListView(children: [
          MessageRow(message: shell(), stepDetail: StepDetail.fullyExpanded),
        ]),
      ),
    ));
    await tester.pump();
    expect(find.text('Shell'), findsNothing,
        reason: '规格：命令卡默认收起，点整行才展开');
    await expand(tester);
    expect(find.text('Shell'), findsOneWidget);
  });
}
