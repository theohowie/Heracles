import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/stream_step.dart';
import 'package:heracles/widgets/tool_call_card.dart';

/// **「调用工具不透明，看不到改了什么代码」的回归测试**（2026-10-21，BUG-4）。
///
/// ## 用户报的症状
///
/// > 「调用工具不透明，看不到改了什么代码」
///
/// ## 根因（两端各一半）
///
/// · **Kotlin 侧没问题**：`DiffReceipt.render(...)` 已经把 diff 放进工具结果
///   —— `@@ 第 N 行 @@` / `- 旧行` / `+ 新行`（`FileTools.DiffReceipt`）。
/// · **UI 侧把它截没了**：`ToolCallCard` 在标准档（默认档）用
///   `StepDetail.summaryChars`（80 字符）截结果 ⇒ 用户看到的只有
///   `@@ 第 3 行 @@…` 这一行。
///
/// ## 这组断言守什么
///
/// 1. 写类工具（`write_file` / `edit` / `apply_patch` / `delete_path` /
///    `move_path`）的卡片**默认折叠**但**入口可见**（`+N −M` + 「点击查看改动」）
/// 2. 点开后能看到**完整** diff（**不受** `summaryChars` 截断）
/// 3. 非写类工具（`read_file`）**不**出现改动区块（不是所有卡片都加噪音）
/// 4. `stream_step.dart` 的流式工具子条目也有「文件改动摘要」行
/// 5. `StepDetail.summaryChars` 的**默认值没被改**（这是全局设置，不许为这张卡片动）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 一段**真正超过 summaryChars(80)** 的 diff —— 用来证明"展开后看到的是全文"。
  ///
  /// 结构与 `DiffReceipt.render` 的真实输出一致：
  /// 首行 `@@ 第 N 行 @@`，删除行 `- `，新增行 `+ `。
  final longDiff = [
    '@@ 第 12 行 @@',
    '- final value = computeSomething();',
    '- // 旧的注释，比较长，足以越过 80 字符的截断线',
    '+ final value = computeSomethingElse();',
    '+ // 新的注释，同样比较长，足以越过 80 字符的截断线',
    '+ // 再补一行让 diff 明显超长',
  ].join('\n');

  HToolCall writeCall({String? result}) => HToolCall(
        id: 'w1',
        tool: 'write_file',
        args: const {'path': 'lib/main.dart', 'content': 'final x = 1;'},
        result: result,
        status: result == null ? ToolStatus.running : ToolStatus.success,
      );

  HToolCall editCall() => HToolCall(
        id: 'e1',
        tool: 'edit',
        args: const {
          'path': 'lib/agent.dart',
          'old_string': 'a\nb\nc',
          'new_string': 'a\nB\nC\nd',
        },
        result: longDiff,
        status: ToolStatus.success,
      );

  HToolCall readCall() => const HToolCall(
        id: 'r1',
        tool: 'read_file',
        args: {'path': 'lib/main.dart'},
        result: 'final x = 1;\n',
        status: ToolStatus.success,
      );

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: SingleChildScrollView(child: child),
        ),
      );

  // ============================================================
  // 1. 默认档（standard）就要有入口 —— 否则用户永远不知道能点
  // ============================================================

  testWidgets('★★ 默认档：写类工具卡片显示「点击查看改动」+ `+N −M` 统计',
      (tester) async {
    await tester.pumpWidget(wrap(ToolCallCard(call: writeCall(result: longDiff))));
    await tester.pump();

    // 入口提示**必须**在默认折叠状态下可见
    expect(
      find.text('点击查看改动'),
      findsOneWidget,
      reason: '默认折叠也要让用户看到"这里能点" —— 否则和"没有这个功能"没区别',
    );

    // `+N −M` 统计：这段 diff 有 3 个 `+ ` 行、2 个 `- ` 行
    expect(find.text('+3'), findsOneWidget, reason: '新增行数统计必须显示');
    expect(find.text('−2'), findsOneWidget, reason: '删除行数统计必须显示');

    // 文件名也要露出来（"改了哪个文件"是用户的第一个问题）。
    // ⚠️ `findsWidgets` 而不是 `findsOneWidget`：标准档下参数区也会回显 `path`，
    //   所以同一个文件名在卡片里出现两次（diff 头 + 参数区）—— 都是对的。
    expect(find.textContaining('lib/main.dart'), findsWidgets);

    // ★ 关键：**完整 diff 此时不该出现**（默认折叠）
    expect(
      find.textContaining('computeSomethingElse'),
      findsNothing,
      reason: '默认折叠 —— diff 有几十行，全展开会淹掉回答',
    );
  });

  testWidgets('★★ 点一下就能看到**完整** diff（不受 summaryChars 截断）',
      (tester) async {
    await tester.pumpWidget(wrap(ToolCallCard(call: writeCall(result: longDiff))));
    await tester.pump();

    // 确认 longDiff 真的超过 summaryChars（否则这条测试证明不了什么）
    expect(longDiff.length, greaterThan(StepDetail.summaryChars));

    await tester.tap(find.text('点击查看改动'));
    await tester.pumpAndSettle();

    // 展开后：整段 diff 按行渲染 ⇒ 首行/末行都在（不是被截成 80 字符）
    //
    // ⚠️ 用 `findsWidgets` 而不是 `findsOneWidget`：结果区（标准档）仍然显示
    //   被截断的那一份摘要 —— 那一份是"整个结果的摘要"，与这里的"完整改动"
    //   是两个不同的展示面（前者是既有行为，后者是本次新增的入口）。
    //   断言的关键是**完整 diff 的每一行都作为独立 Text 存在**（按行渲染，
    //   所以末尾那行不可能被 80 字符截掉）。
    expect(find.textContaining('computeSomethingElse'), findsWidgets,
        reason: '展开后必须看到新增行 —— 这是用户要的「改了什么代码」');
    expect(find.textContaining('再补一行让 diff 明显超长'), findsOneWidget,
        reason: '**末尾**的行也要在 —— 截断的话它最先消失');
    expect(find.textContaining('旧的注释'), findsWidgets,
        reason: '删除行同样要看得到');
    // ★ 逐行渲染的直接证据：单独一行 `+ // 再补一行…` 是一个独立 Text
    expect(
      find.text('+ // 再补一行让 diff 明显超长'),
      findsOneWidget,
      reason: '按行渲染 ⇒ 每一行是独立 Text（这才是"完整 diff"，不是一个被截断的块）',
    );

    // 入口文案变成「收起」
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('★ 再点一下能收起（不是单向展开）', (tester) async {
    await tester.pumpWidget(wrap(ToolCallCard(call: writeCall(result: longDiff))));
    await tester.pump();

    await tester.tap(find.text('点击查看改动'));
    await tester.pumpAndSettle();
    expect(find.textContaining('computeSomethingElse'), findsOneWidget);

    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.textContaining('再补一行让 diff 明显超长'), findsNothing,
        reason: '收起后 diff 正文必须消失，否则"收起"是假的');
    expect(find.text('点击查看改动'), findsOneWidget);
  });

  // ============================================================
  // 2. 各类写工具 / 非写工具的分流
  // ============================================================

  testWidgets('★★ `edit` 也有 diff 入口（BUG-4 最常撞的工具）', (tester) async {
    await tester.pumpWidget(wrap(ToolCallCard(call: editCall())));
    await tester.pump();

    // edit 的标题现在是"局部修改代码"（原先露 schema 名 `edit`）
    expect(find.text('局部修改代码'), findsOneWidget,
        reason: '`edit` 此前没登记人话名，卡片顶部露出的是给模型看的 schema 名');
    expect(find.text('点击查看改动'), findsOneWidget);
    expect(find.textContaining('lib/agent.dart'), findsWidgets);

    await tester.tap(find.text('点击查看改动'));
    await tester.pumpAndSettle();
    expect(find.textContaining('computeSomethingElse'), findsWidgets);
  });

  testWidgets('★★ 非写类工具（read_file）**不**出现改动区块（不许给所有卡片加噪音）',
      (tester) async {
    await tester.pumpWidget(wrap(ToolCallCard(call: readCall())));
    await tester.pump();

    expect(find.text('点击查看改动'), findsNothing);
    expect(find.byIcon(Icons.difference_outlined), findsNothing);
    // 但普通的结果渲染照旧
    expect(find.text('读取文件'), findsOneWidget);
  });

  testWidgets('★ 写类工具但拿不到 diff 内容时，不摆空区块', (tester) async {
    // 只有 path，没有 content / result（模拟调用被拦截、什么都没做）
    final bare = const HToolCall(
      id: 'b1',
      tool: 'write_file',
      args: {'path': 'a.txt'},
      result: null,
      status: ToolStatus.running,
    );
    await tester.pumpWidget(wrap(ToolCallCard(call: bare)));
    await tester.pump();

    // 参数里没有 content、结果也没有 ⇒ 没有可展示的改动
    expect(find.text('点击查看改动'), findsNothing);
  });

  // ============================================================
  // 3. 全局设置不许被动：summaryChars 默认值仍是 80
  // ============================================================

  test('★★ `StepDetail.summaryChars` 默认值没被改（那是全局设置，不许为这张卡片动）', () {
    expect(
      StepDetail.summaryChars,
      80,
      reason: 'BUG-4 的入口是**卡片内**的，不是靠改全局截断长度 —— '
          '改它会波及所有卡片（含非写类），也不是用户要的',
    );
  });

  // ============================================================
  // 4. diff 统计 / 文件名解析（纯函数层）
  // ============================================================

  group('DiffStat 解析', () {
    test('★ 从真实 DiffReceipt 输出里数出 +N −M', () {
      final stat = diffStatOf(longDiff);
      expect(stat.isDiff, isTrue);
      expect(stat.added, 3);
      expect(stat.removed, 2);
      expect(stat.label, '+3 −2');
    });

    test('★ 新建文件（DiffReceipt 的「（新建文件，共 N 行）」形态）只算新增', () {
      final stat = diffStatOf('（新建文件，共 3 行）\n+ a\n+ b\n+ c');
      expect(stat.isDiff, isTrue);
      expect(stat.added, 3);
      expect(stat.removed, 0);
    });

    test('★ 普通文本不会被误判成 diff（Markdown 列表的 `- ` 不算删除）', () {
      // 这条很重要：diffStatOf 只该喂**写类工具的结果**，而写类工具的结果
      // 可能**不是** diff（例如"失败：路径越界"）。没有 `@@` 锚 ⇒ 不能数。
      final stat = diffStatOf('- 一个 Markdown 列表项\n- 另一个列表项');
      expect(stat.isDiff, isFalse,
          reason: '没有 @@ 且没有「（新建文件/内容未变化）」⇒ 不能当成 diff');
      expect(stat.added, 0);
      expect(stat.removed, 0);
    });

    test('★ 空结果 / null 不产生统计', () {
      expect(diffStatOf(null).isDiff, isFalse);
      expect(diffStatOf('').isDiff, isFalse);
      expect(diffStatOf(null).hasChanges, isFalse);
    });

    test('★ 改动文件解析：写取 path，移动取 from → to', () {
      expect(changedFilesOf({'path': 'a.txt'}), ['a.txt']);
      expect(changedFilesOf({'from': 'a.txt', 'to': 'b.txt'}), ['a.txt → b.txt']);
      expect(changedFilesOf(const {}), isEmpty, reason: '拿不到就不编造文件名');
    });

    test('★ 流式阶段按参数估算（patch 优先、edit 看 old/new 行数）', () {
      final fromPatch = estimatedDiffStatOf({'patch': '- a\n- b\n+ c'});
      expect(fromPatch.added, 1);
      expect(fromPatch.removed, 2);

      final fromEdit = estimatedDiffStatOf({
        'old_string': 'a\nb',
        'new_string': 'a\nb\nc',
      });
      expect(fromEdit.added, 3);
      expect(fromEdit.removed, 2);
    });
  });

  // ============================================================
  // 5. 流式步骤条目的「文件改动摘要」行
  // ============================================================

  group('stream_step 文件改动摘要', () {
    HStepStream finishedToolStep(String rawJson) => HStepStream(
          id: 's1',
          stepId: 'turn-1',
          title: '第 1 轮',
          text: rawJson,
          finished: true,
          status: 'ok',
        );

    testWidgets('★★ 写类工具的步骤条目显示「文件 + +N −M」摘要',
        (tester) async {
      final raw = '{"tool":"write_file","args":{'
          '"path":"lib/main.dart","content":"a\\nb\\nc"}}';
      await tester.pumpWidget(
        wrap(StreamStepView(step: finishedToolStep(raw), detail: StepDetail.standard)),
      );
      await tester.pump();

      // 摘要行：文件名 + 新增行数（写入 3 行）
      expect(find.textContaining('lib/main.dart'), findsWidgets,
          reason: '步骤条目要让用户看到"改了哪个文件"');
      expect(find.textContaining('+3'), findsOneWidget,
          reason: '「+N」必须出现在标题行，不用点开');
      expect(find.textContaining('−0'), findsOneWidget);
    });

    testWidgets('★ 非写类工具的步骤条目**不**显示改动摘要（不制造噪音）',
        (tester) async {
      final raw = '{"tool":"read_file","args":{"path":"lib/main.dart"}}';
      await tester.pumpWidget(
        wrap(StreamStepView(step: finishedToolStep(raw), detail: StepDetail.standard)),
      );
      await tester.pump();

      expect(find.textContaining('+0'), findsNothing);
      expect(find.textContaining('−0'), findsNothing);
    });

    testWidgets('★ 写类工具但没有可识别参数时，不显示假统计', (tester) async {
      final raw = '{"tool":"write_file","args":{"path":"a.txt"}}';
      await tester.pumpWidget(
        wrap(StreamStepView(step: finishedToolStep(raw), detail: StepDetail.standard)),
      );
      await tester.pump();
      expect(find.textContaining('+0'), findsNothing);
    });
  });
}
