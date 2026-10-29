import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/tool_call_card.dart';

/// **命令卡（双层）测试**（2026-10-28，用户逐版对 HTML 预览拍板）。
///
/// 防的是「设计定了、代码没跟上」：双层/悬浮退出码/行号/6:4 限高/
/// 执行中无结果层，每一条都在这里钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(HToolCall call) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolCallCard(call: call, stepDetail: StepDetail.standard),
          ),
        ),
      );

  HToolCall shell({
    String command = 'echo hi',
    String? result = 'hi',
    ToolStatus status = ToolStatus.success,
    int? exitCode,
    Map<String, String>? extraArgs,
  }) =>
      HToolCall(
        id: 'c1',
        tool: 'run_shell_command',
        args: {'command': command, ...?extraArgs},
        result: result,
        status: status,
        exitCode: exitCode,
      );

  /// 展开命令卡（2026-10-29 规格：命令卡**默认收起**，点标题行原地展开）。
  ///
  /// 收起态整个 `ToolCallCard` 就是那 44dp 标题行 ⇒ 点组件中心等于点整行。
  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.byType(ToolCallCard));
    await tester.pump();
  }

  test('执行面判定：shell 工具→Shell，sandbox 标记→SandBox，非命令工具→null',
      () {
    expect(commandSurfaceOf(shell()), CommandSurface.shell);
    expect(commandSurfaceOf(shell(extraArgs: {'surface': 'sandbox'})),
        CommandSurface.sandbox);
    expect(
        commandSurfaceOf(const HToolCall(
            id: 'x', tool: 'run_sandbox_command', args: {'command': 'ls'})),
        CommandSurface.sandbox);
    expect(
        commandSurfaceOf(const HToolCall(
            id: 'x', tool: 'read_file', args: {'path': 'a.dart'})),
        isNull);
  });

  test('退出码判定：结构化优先，失败解析后端附文，拿不到=null（不编造 0）', () {
    // ★ 规格变更（2026-10-29）：旧断言 `成功 ⇒ 0` 是错的 ——
    //   「工具调用成功」≠「命令退出码 0」（grep 无匹配 / javac 失败都是
    //   工具成功但命令非 0）。现在只认后端 metadata 的结构化 exitCode。
    expect(commandExitCodeOf(shell(exitCode: 0)), 0);
    expect(commandExitCodeOf(shell()), isNull,
        reason: '没有结构化退出码就不许编造 0');
    expect(
        commandExitCodeOf(shell(
          result: 'boom（命令退出码：13 —— 命令执行了，但没有成功返回。）',
          status: ToolStatus.failure,
        )),
        13);
    expect(
        commandExitCodeOf(shell(result: 'boom', status: ToolStatus.failure)),
        isNull);
    expect(
        commandExitCodeOf(shell(result: null, status: ToolStatus.running)),
        isNull);
  });

  testWidgets('成功卡：标题行说在哪执行，卡内 Shell+行号+结果层+悬浮退出码 0',
      (tester) async {
    await tester.pumpWidget(wrap(shell(
      command: 'cd @workspace && \\\n./gradlew assembleRelease && \\\necho DONE',
      result: 'BUILD SUCCESSFUL\nDONE',
      // ★ 规格变更（2026-10-29）：退出码只认后端结构化值 —— 这里显式给 0；
      //   不给就**不显示 chip**（spec 测试已钉「不许编造」）。
      exitCode: 0,
    )));
    expect(find.text('在手机执行了命令'), findsOneWidget);
    // ★ 规格变更（2026-10-29）：命令卡默认收起，先点标题行展开
    await expand(tester);
    // 第一行执行面名 + 后续行号
    expect(find.text('Shell'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // 结果层 + 悬浮件
    expect(find.textContaining('BUILD SUCCESSFUL'), findsOneWidget);
    expect(find.text('退出码 0'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    // 不出现旧形态的标签与时间
    expect(find.text('结果'), findsNothing);
    // 6:4 限高钉死
    final caps = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .map((b) => b.constraints.maxHeight)
        .toList();
    expect(caps, contains(kCommandLayerMaxHeight));
    expect(caps, contains(kResultLayerMaxHeight));
  });

  testWidgets('执行中：只有命令层 + 执行中行，没有结果层、没有退出码',
      (tester) async {
    await tester.pumpWidget(wrap(shell(
      command: 'pm install -r app.apk',
      result: null,
      status: ToolStatus.running,
    )));
    expect(find.text('正在手机执行命令'), findsOneWidget);
    await expand(tester);
    expect(find.textContaining('执行中…'), findsOneWidget);
    expect(find.textContaining('退出码'), findsNothing);
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('失败卡：红色退出码 chip 解析自结果附文', (tester) async {
    await tester.pumpWidget(wrap(shell(
      command: 'cp a.apk @libs/',
      result: '只读挂载（命令退出码：13 —— 命令执行了，但没有成功返回。）',
      status: ToolStatus.failure,
    )));
    expect(find.text('在手机执行了命令（失败）'), findsOneWidget);
    await expand(tester);
    expect(find.text('退出码 13'), findsOneWidget);
  });

  testWidgets('沙箱标记：标题行与卡内名字都切到 SandBox', (tester) async {
    await tester.pumpWidget(wrap(shell(
      command: 'ls @workspace',
      result: 'app',
      extraArgs: {'surface': 'sandbox'},
    )));
    expect(find.text('在沙箱执行了命令'), findsOneWidget);
    await expand(tester);
    expect(find.text('SandBox'), findsOneWidget);
  });

  testWidgets('长行不换行：两层都有横向滚动', (tester) async {
    await tester.pumpWidget(wrap(shell(
      command: 'echo ${'x' * 120}',
      result: 'y' * 120,
    )));
    await expand(tester);
    final horizontals = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((s) => s.scrollDirection == Axis.horizontal)
        .length;
    expect(horizontals, greaterThanOrEqualTo(2));
  });

  testWidgets('非命令工具保持旧卡形态（不出现命令卡）', (tester) async {
    await tester.pumpWidget(wrap(const HToolCall(
      id: 'r1',
      tool: 'read_file',
      args: {'path': 'a.dart'},
      result: 'content',
      status: ToolStatus.success,
    )));
    expect(find.text('Shell'), findsNothing);
    expect(find.text('SandBox'), findsNothing);
    expect(find.textContaining('退出码'), findsNothing);
  });
}
