import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/settings.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';
import 'package:heracles/widgets/bw_model_sheet.dart';

/// **模型抽屉必须标出「当前」**（2026-10-29 T2 第 6 条）。
///
/// 真因：输入框胶囊显示的是 `effectiveProvider`（`AppSettings.effectiveProvider`
/// 在用户没显式点选时会自动选中一个 —— 见 models/settings.dart:733-749），
/// 而抽屉的判据只有 `activeProviderId`（用户没点过 = null）⇒ 胶囊上有模型名，
/// 抽屉里却**一个「当前」都没有**，用户不知道"现在用的是哪个"。
///
/// 规格：抽屉按 `currentProviderId`（调用方传 `effectiveProvider?.id`，唯一口径）
/// 标「当前」，显式 `activeProviderId` 仍是 compat 输入；**不在抽屉里重算一套
/// 选择逻辑** —— 测试直接用 `AppSettings.effectiveProvider` 得出期望值，钉住
/// 「同一口径」。
void main() {
  ModelProviderConfig cfg(String id, String model, {String key = 'sk-test'}) =>
      ModelProviderConfig(
        id: id,
        name: id,
        baseUrl: 'https://api.example.com/v1',
        model: model,
        apiKey: key,
      );

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  Future<void> settle(WidgetTester tester, {int times = 25}) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> usePhoneSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 打开模型抽屉（与 input_bar 的 `_ModelSelector._open` 同一条调用链）。
  Future<void> openSheet(
    WidgetTester tester,
    AppSettings settings, {
    bool passCurrent = false,
  }) async {
    final current = settings.effectiveProvider?.id;
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: GestureDetector(
          onTap: () => showModelSheet(
            ctx,
            providers: settings.providers,
            activeProviderId: settings.activeProviderId,
            currentProviderId: passCurrent ? current : null,
            reasoningLevel: ReasoningLevel.auto,
          ),
          child: const Text('打开'),
        ),
      ),
    )));
    await tester.tap(find.text('打开'));
    await settle(tester, times: 10);
  }

  /// 「当前」徽标是否长在**指定模型那张卡**里（防"找得到就算过"的错对象断言）。
  Finder badgeInCard(String model) => find.descendant(
        of: find
            .ancestor(
                of: find.text(model), matching: find.byType(BwOptionCard))
            .first,
        matching: find.text('当前'),
      );

  testWidgets('★★ 单 provider + 从未显式选过（active=null）⇒ 仍有「当前」',
      (tester) async {
    await usePhoneSurface(tester);
    final s = AppSettings(providers: [cfg('p1', 'm-one')]);
    expect(s.activeProviderId, isNull, reason: '前提：用户没点过');
    expect(s.effectiveProvider?.id, 'p1', reason: '前提：自动选中了 p1');

    await openSheet(tester, s, passCurrent: true);

    expect(find.byType(BwOptionCard), findsOneWidget);
    expect(badgeInCard('m-one'), findsOneWidget,
        reason: '胶囊显示的 p1 在抽屉里必须带「当前」，否则用户不知道现用哪个');
    expect(find.text('当前'), findsOneWidget);
  });

  testWidgets('★★ 两个 provider + active=null ⇒ 徽标只落在 effectiveProvider 上',
      (tester) async {
    await usePhoneSurface(tester);
    final s = AppSettings(
      providers: [cfg('p1', 'm-one'), cfg('p2', 'm-two')],
    );
    expect(s.effectiveProvider?.id, 'p1', reason: '前提：自动顺序选中 p1');

    await openSheet(tester, s, passCurrent: true);

    expect(badgeInCard('m-one'), findsOneWidget);
    expect(badgeInCard('m-two'), findsNothing,
        reason: '「当前」是单选语义 —— 只能有一张卡带徽标');
    expect(find.text('当前'), findsOneWidget);
  });

  testWidgets('★★ 显式 active 优先：切到 p2 后徽标移到 p2', (tester) async {
    await usePhoneSurface(tester);
    final s = AppSettings(
      providers: [cfg('p1', 'm-one'), cfg('p2', 'm-two')],
      activeProviderId: 'p2',
    );
    expect(s.effectiveProvider?.id, 'p2', reason: '前提：显式选择最高优先');

    await openSheet(tester, s, passCurrent: true);

    expect(badgeInCard('m-two'), findsOneWidget);
    expect(badgeInCard('m-one'), findsNothing);
  });

  testWidgets('★ 兼容旧调用：显式 active 且不传 currentProviderId 也标「当前」',
      (tester) async {
    await usePhoneSurface(tester);
    await openSheet(
      tester,
      AppSettings(
        providers: [cfg('p1', 'm-one'), cfg('p2', 'm-two')],
        activeProviderId: 'p2',
      ),
    );

    expect(badgeInCard('m-two'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
  });
}
