import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/message.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/stream_step.dart';

/// **思考块测试**（2026-10-28，用户拍板的新形态）：
/// 无卡片、点「思考」开关、限高内滚不标注、流式默认展开/结束默认收起。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget wrap(HStepStream step) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: SingleChildScrollView(child: StreamStepView(step: step)),
        ),
      );

  final longReasoning = List.generate(30, (i) => '第 ${i + 1} 条推理').join('\n');

  HStepStream step({required bool finished, String reasoning = ''}) =>
      HStepStream(
        id: 's1',
        stepId: 'turn-2',
        title: '',
        reasoning: reasoning,
        text: '',
        finished: finished,
      );

  testWidgets('结束的思考默认收起：只有「思考」开关，正文不出现', (tester) async {
    await tester.pumpWidget(wrap(step(finished: true, reasoning: longReasoning)));
    expect(find.text('思考'), findsOneWidget);
    expect(find.textContaining('第 1 条推理'), findsNothing);
    // 旧标签退役
    expect(find.text('思考过程'), findsNothing);
  });

  testWidgets('点「思考」展开，再点收起；展开区限高 240 内滚', (tester) async {
    await tester.pumpWidget(wrap(step(finished: true, reasoning: longReasoning)));
    await tester.tap(find.text('思考'));
    await tester.pump();
    expect(find.textContaining('第 1 条推理'), findsOneWidget);
    final caps = tester
        .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
        .map((b) => b.constraints.maxHeight)
        .toList();
    expect(caps, contains(240.0));
    await tester.tap(find.text('思考'));
    await tester.pump();
    expect(find.textContaining('第 1 条推理'), findsNothing);
  });

  testWidgets('流式中的思考默认展开（逐字可见）', (tester) async {
    await tester.pumpWidget(wrap(step(finished: false, reasoning: '正在想第一步')));
    expect(find.textContaining('正在想第一步'), findsOneWidget);
  });
}
