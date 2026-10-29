import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/widgets/bw_approval.dart';
import 'package:heracles/theme/app_theme.dart';

/// 回归钉（2026-10-27 真机 bug「Agent 询问是否执行，抽屉整片空白」）：
///
/// 旧版审批抽屉的两步横滑用 LayoutBuilder + OverflowBox 实现，
/// OverflowBox 在滚动视图里拿到无界高 → 布局断言失败 →
/// release 下整片内容不渲染，只剩空抽屉（用户连要批什么都看不见，
/// 审批只能等 5 分钟超时按拒绝）。本测试真泵出抽屉：
/// 内容必须可见、全程零异常、分步确认流要走得通。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(dark: false),
        builder: (context, inner) => HueScope(
          hue: Hue.forDark(false, 0xFFFF7A45),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: TextButton(
          onPressed: () => showApprovalRequestSheet(
            ctx,
            tool: 'run_shell_command',
            argsPreview: 'command: mkdir approval-test',
            risk: '在工作区外执行命令',
            allowStop: true,
          ),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('审批抽屉内容可见且零异常', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await openSheet(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('需要你的批准'), findsOneWidget);
    expect(find.text('允许一次'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('始终允许'), findsOneWidget);
    expect(find.textContaining('mkdir approval-test'), findsOneWidget);
  });

  testWidgets('点「始终允许」滑到二次确认，返回可回第一步', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 851 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await openSheet(tester);
    await tester.tap(find.text('始终允许'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('确认始终允许'), findsOneWidget);
    // ★ 2026-10-29（第 10 条 P3）：第二步文案必须写明**范围**与**可撤销**。
    //   「始终允许」= 之后**不论参数**都会直接执行 —— 旧文案只说
    //   「之后再调用这个工具」，用户容易以为只记住这次的参数。
    expect(find.textContaining('不论参数'), findsOneWidget,
        reason: '始终允许是对**所有参数**生效，文案必须写清「不论参数」');
    expect(find.textContaining('撤销'), findsOneWidget,
        reason: '长期授权必须告诉用户还能撤销（在设置里）');
    await tester.tap(find.text('返回'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('允许一次'), findsOneWidget);
  });
}
