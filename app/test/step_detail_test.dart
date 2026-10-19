import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/message_row.dart';
import 'package:heracles/widgets/tool_call_card.dart';

/// **「工作步骤展示」四档分级的测试**（2026-10-10，t4）。
///
/// ## 它防的是什么
///
/// 用户明确要求"我要的是功能，不是界面"。而在 t4 之前，
/// `StepDetail` 是**空实现** —— 设置里能选四个（当时三个）档位，
/// 选了卡片**没有任何变化**。那正是"界面而非功能"。
///
/// 所以这里不止断言"能选"，而是断言**渲染密度真的有差异**：
/// 同一张工具卡片，不同档位下可见内容的**多少**不同。
///
/// 这比"属性值对了"强 —— 属性对了但渲染没读它，用户仍然看不到区别。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 一张"最大"的卡片：参数很长、结果很长、带模型原始输出。
  /// 用超长值是为了让"完整 vs 摘要"的差异必然可见。
  final longPath = 'src/${'deep/' * 12}file.dart';
  final longResult = 'x' * 400;
  final rawJson = '{"tool":"write_file","args":{"path":"$longPath"}}';

  HToolCall bigCall({String? raw}) => HToolCall(
        id: 't1',
        tool: 'write_file',
        args: {'path': longPath, 'content': 'hello'},
        result: longResult,
        status: ToolStatus.success,
        rawOutput: raw,
      );

  Widget wrap(StepDetail detail, HToolCall call) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolCallCard(call: call, stepDetail: detail),
          ),
        ),
      );

  /// 这张卡片当前渲染出的**文本总长度** —— 渲染密度的客观度量。
  int renderedTextLength(WidgetTester tester) {
    var total = 0;
    for (final w in tester.widgetList<Text>(find.byType(Text))) {
      total += (w.data ?? '').length;
    }
    return total;
  }

  // ==================================================================
  // 1. 四档都真实存在（含新加的「完全展开」）
  // ==================================================================

  group('StepDetail 四档', () {
    test('★ 四档齐全，顺序为 精简/标准/详细/完全展开', () {
      expect(StepDetail.values.length, 4);
      expect(
        StepDetail.values.map((e) => e.label).toList(),
        ['精简', '标准', '详细', '完全展开'],
      );
    });

    test('★ 新增「完全展开」不破坏旧值的解析（持久化兼容）', () async {
      // 旧版本只存过 minimal / standard / detailed
      for (final legacy in ['minimal', 'standard', 'detailed']) {
        SharedPreferences.setMockInitialValues({'stepDetail': legacy});
        final c = await SettingsController.load();
        expect(c.value.stepDetail.name, legacy,
            reason: '旧值 $legacy 必须仍能读回');
      }

      // 未来/未知的枚举名 → 回退到 standard，不能崩
      SharedPreferences.setMockInitialValues({'stepDetail': 'someFutureTier'});
      final c = await SettingsController.load();
      expect(c.value.stepDetail, StepDetail.standard,
          reason: '未知枚举名必须回退，不能让 App 起不来');
    });

    test('★ 默认档仍是「标准」（不静默改用户当前行为）', () async {
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();
      expect(c.value.stepDetail, StepDetail.standard);
      expect(const AppSettings().stepDetail, StepDetail.standard);
    });

    test('★ 四档的"显示什么"是严格递增的', () {
      // 参数：精简不给，其余都给
      expect(StepDetail.minimal.showArgs, isFalse);
      expect(StepDetail.standard.showArgs, isTrue);
      expect(StepDetail.detailed.showArgs, isTrue);
      expect(StepDetail.fullyExpanded.showArgs, isTrue);

      // 完整（不截断）：只有详细与完全展开
      expect(StepDetail.minimal.fullResult, isFalse);
      expect(StepDetail.standard.fullResult, isFalse);
      expect(StepDetail.detailed.fullResult, isTrue);
      expect(StepDetail.fullyExpanded.fullResult, isTrue);

      // 模型原始输出：只有完全展开
      expect(StepDetail.minimal.showRawOutput, isFalse);
      expect(StepDetail.standard.showRawOutput, isFalse);
      expect(StepDetail.detailed.showRawOutput, isFalse);
      expect(StepDetail.fullyExpanded.showRawOutput, isTrue);
    });

    test('★ 设置里四档都能被选中并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();
      for (final v in StepDetail.values) {
        await c.setStepDetail(v);
        final reloaded = await SettingsController.load();
        expect(reloaded.value.stepDetail, v, reason: '${v.label} 必须能存回');
      }
    });
  });

  // ==================================================================
  // 2. ★ 渲染密度真的有差异（核心：功能而非界面）
  // ==================================================================

  group('工具卡片分级渲染', () {
    testWidgets('★ 精简档：只有工具名 + 状态，没有参数与结果', (tester) async {
      await tester.pumpWidget(wrap(StepDetail.minimal, bigCall(raw: rawJson)));
      await tester.pump();

      expect(find.text('修改文件代码'), findsOneWidget);
      expect(find.text('成功'), findsOneWidget);
      // ★ 参数与结果都不显示
      expect(find.text('结果'), findsNothing);
      expect(find.textContaining('个参数'), findsOneWidget);
      // 长结果不应出现
      expect(find.text(longResult), findsNothing);
      // 原始输出也不该出现
      expect(find.text('模型原始输出'), findsNothing);
    });

    testWidgets('★ 标准档：参数与结果以摘要出现（长值被截断）', (tester) async {
      await tester.pumpWidget(wrap(StepDetail.standard, bigCall(raw: rawJson)));
      await tester.pump();

      expect(find.text('修改文件代码'), findsOneWidget);
      expect(find.text('结果'), findsOneWidget);
      // 完整的长结果**不该**出现
      expect(find.text(longResult), findsNothing);
      // 应有截断提示
      expect(find.textContaining('已截断'), findsOneWidget);
      // 标准档仍不显示模型原始输出
      expect(find.text('模型原始输出'), findsNothing);
    });

    testWidgets('★ 详细档：完整参数与完整结果', (tester) async {
      await tester.pumpWidget(wrap(StepDetail.detailed, bigCall(raw: rawJson)));
      await tester.pump();

      expect(find.text('结果'), findsOneWidget);
      // ★ 完整结果出现，且没有截断提示
      expect(find.text(longResult), findsOneWidget);
      expect(find.textContaining('已截断'), findsNothing);
      // 详细档仍**不**显示原始输出（那是完全展开的增量）
      expect(find.text('模型原始输出'), findsNothing);
    });

    testWidgets('★ 完全展开档：详细档的内容 + 模型原始输出', (tester) async {
      await tester.pumpWidget(
          wrap(StepDetail.fullyExpanded, bigCall(raw: rawJson)));
      await tester.pump();

      // 详细档有的它都有
      expect(find.text(longResult), findsOneWidget);
      // ★ 增量：模型原始输出
      expect(find.text('模型原始输出'), findsOneWidget);
      expect(find.text(rawJson), findsOneWidget);
    });

    testWidgets('★ 完全展开档拿不到 raw 时不显示「（无）」空块', (tester) async {
      await tester.pumpWidget(wrap(StepDetail.fullyExpanded, bigCall()));
      await tester.pump();

      // 不该出现标题（没内容就不摆标题，否则用户以为模型没输出）
      expect(find.text('模型原始输出'), findsNothing);
      // 但详细档该有的内容仍在
      expect(find.text(longResult), findsOneWidget);
    });

    testWidgets('★ 渲染密度严格递增（精简 < 标准 < 详细 < 完全展开）', (tester) async {
      final lengths = <StepDetail, int>{};

      for (final d in StepDetail.values) {
        await tester.pumpWidget(wrap(d, bigCall(raw: rawJson)));
        await tester.pump();
        lengths[d] = renderedTextLength(tester);
      }

      final minimal = lengths[StepDetail.minimal]!;
      final standard = lengths[StepDetail.standard]!;
      final detailed = lengths[StepDetail.detailed]!;
      final full = lengths[StepDetail.fullyExpanded]!;

      expect(minimal, lessThan(standard),
          reason: '标准档必须比精简档显示更多（$minimal vs $standard）');
      expect(standard, lessThan(detailed),
          reason: '详细档必须比标准档显示更多 —— 摘要 vs 完整（$standard vs $detailed）');
      expect(detailed, lessThan(full),
          reason: '完全展开必须比详细档多出模型原始输出（$detailed vs $full）');

      // 差异要**可见**，不是只差几个字符
      expect(detailed - standard, greaterThan(100),
          reason: '「摘要→完整」的差异必须一眼可见');
    });

    testWidgets('精简档没有可展开内容时，不画折叠箭头（避免点了没反应）',
        (tester) async {
      // 无参数、无结果的卡片
      final bare = HToolCall(
        id: 'b',
        tool: 'list_files',
        args: const {},
        status: ToolStatus.running,
      );
      await tester.pumpWidget(wrap(StepDetail.minimal, bare));
      await tester.pump();

      expect(find.text('正在查看目录文件'), findsOneWidget,
          reason: 'running 态的标题是「正在…」形态（2026-10-13 人话标题）');
      expect(find.text('执行中'), findsOneWidget);
      // 精简档没有 body → 不该有箭头
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
    });
  });

  // ==================================================================
  // 4. 设置页四档都能选（任务第 2 项）
  // ==================================================================

  group('设置页可操作性', () {
    testWidgets('★ 下拉里四个选项都能看到，且能选中「完全展开」', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = await SettingsController.load();

      await tester.pumpWidget(MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: SettingsScreen(controller: c),
      ));
      await tester.pumpAndSettle();

      // 进「通用设置」页
      await tester.tap(find.text('通用设置'));
      await tester.pumpAndSettle();

      // 当前显示的是默认档「标准」
      expect(find.text('标准'), findsOneWidget);

      // 打开下拉
      await tester.tap(find.text('标准'));
      await tester.pumpAndSettle();

      // ★ 四档都在菜单里（含新加的「完全展开」）
      for (final d in StepDetail.values) {
        expect(find.text(d.label), findsWidgets,
            reason: '${d.label} 必须出现在下拉里');
      }

      // 选中「完全展开」
      await tester.tap(find.text('完全展开').last);
      await tester.pumpAndSettle();

      expect(c.value.stepDetail, StepDetail.fullyExpanded);
    });
  });

  // ==================================================================
  // 3. MessageRow 把档位透传给卡片
  // ==================================================================

  group('档位透传', () {
    testWidgets('★ MessageRow 的 stepDetail 必须真的传到工具卡片', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: MessageRow(
            message: bigCall(raw: rawJson),
            stepDetail: StepDetail.fullyExpanded,
          ),
        ),
      ));
      await tester.pump();

      // 若透传断了，这里就看不到原始输出
      expect(find.text('模型原始输出'), findsOneWidget);
    });

    testWidgets('MessageRow 默认档 = 标准（不显示原始输出）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: MessageRow(message: bigCall(raw: rawJson))),
      ));
      await tester.pump();

      expect(find.text('模型原始输出'), findsNothing);
      expect(find.textContaining('已截断'), findsOneWidget);
    });
  });
}
