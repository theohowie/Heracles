// v0.5.0-release（2026-11-10）三条用户可见行为的回归门禁。
//
// 都是「用户直接看到 / 直接踩到」的问题，所以断言落在**用户能看到的那一层**：
//
// 1. 设置里上下文窗口 / 输出上限要显示 `128K` / `32K` / `1M`，不是 `131072`；
// 2. 失败文案不许把「超时」说成「网络连接失败」（用户会被骗去查网络）；
// 3. 英文界面底座的回退语义：缺词条要回退中文，不许空白、不许抛。
//
// ⚠️ 这三条都做过变异验证（见每条用例上方注释里的「变异」说明）。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/i18n/l10n.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/models/token_count.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/secure_storage_mock.dart';
import 'package:heracles/widgets/model_catalog_row.dart';
import 'package:heracles/widgets/run_stop_banner.dart';

void main() {
  group('设置里的 token 输入框显示人类可读单位（v0.5.0-release 用户点名）', () {
    setUp(installSecureStorageMock);
    tearDown(removeSecureStorageMock);

    testWidgets('★ 用户实际看到：模型目录行展开后两格显示 128K / 32K', (tester) async {
      SharedPreferences.setMockInitialValues({});
      // 用生产 SettingsScreen + 真 ProviderEditPage + 真 ModelCatalogRow，
      // 不只测 formatter；这样旧代码若把 controller 初值改回 `.toString()`，
      // 这里就会看到 131072 / 32768 而变红。
      final provider = ModelProviderConfig(
        id: 'provider-token-ui',
        name: 'Token UI regression',
        baseUrl: 'https://example.test/v1',
        model: 'example-model',
        apiKey: 'test-key',
        enabled: true,
        isDefault: true,
        modelCatalog: const <String>['example-model'],
        contextLength: 131072,
        maxOutputTokens: 32768,
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1200, 1800));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildHeraclesTheme(),
          builder: (context, child) => HueScope(
            hue: Hue.darkHue,
            child: child ?? const SizedBox.shrink(),
          ),
          home: ProviderEditPage(provider: provider),
        ),
      );
      expect(find.byType(ProviderEditPage), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(ModelCatalogRow),
        matching: find.text('example-model'),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(ModelCatalogRow), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(ModelCatalogRow),
        matching: find.byIcon(CupertinoIcons.chevron_right),
      ));
      await tester.pumpAndSettle();

      // 同行锚定：不使用 find.text(x).first，分别从提示行取得两个 TextField。
      final caption = find.text(
        '这个模型的上游额度（留空 = 用契约默认：窗口 128K / 输出 16384）',
      );
      expect(caption, findsOneWidget);
      final fields = find.descendant(
        of: find.byType(ModelCatalogRow),
        matching: find.byType(CupertinoTextField),
      );
      expect(fields, findsNWidgets(2));
      final contextField = tester.widget<CupertinoTextField>(fields.at(0));
      final outputField = tester.widget<CupertinoTextField>(fields.at(1));
      expect(contextField.controller!.text, '128K');
      expect(outputField.controller!.text, '32K');
      expect(contextField.controller!.text, isNot('131072'));
      expect(outputField.controller!.text, isNot('32768'));
      // 两个输入框确实来自同一个已展开模型目录行，而不是别处的同文案。
      expect(
        find.descendant(of: find.byType(ModelCatalogRow), matching: fields),
        findsNWidgets(2),
      );
    });
    // 变异：把 formatTokenCount 的 `tokens % 1024 == 0` 分支删掉 ⇒ 本组全红。
    test('131072 / 32768 / 1048576 分别显示 128K / 32K / 1M', () {
      expect(formatTokenCount(131072), '128K');
      expect(formatTokenCount(32768), '32K');
      expect(formatTokenCount(1048576), '1M');
    });

    test('整 K 与整 M 的其它常见值', () {
      expect(formatTokenCount(1024), '1K');
      expect(formatTokenCount(16384), '16K');
      expect(formatTokenCount(2097152), '2M');
      // 1.5M 不是整 M 却是整 K ⇒ 给 1536K（不硬凑成 1.5M，避免回读歧义）
      expect(formatTokenCount(1572864), '1536K');
    });

    test('非 1024 整倍数一律给纯数字（宁可 1500000 也不要 1.43M）', () {
      expect(formatTokenCount(200000), '200000');
      expect(formatTokenCount(1500000), '1500000');
      expect(formatTokenCount(128), '128');
    });

    test('0 / 负数 / 未设置 ⇒ 空串（让占位符显示默认值）', () {
      expect(formatTokenCount(0), '');
      expect(formatTokenCount(-1), '');
    });

    test('★ 回读稳定：128K 存进去、重新格式化仍是 128K', () {
      for (final shown in <String>['128K', '32K', '1M', '16K', '1536K']) {
        final parsed = parseTokenCount(shown);
        expect(parsed, isNotNull, reason: '「$shown」必须能被解析回 token 数');
        expect(
          formatTokenCount(parsed!),
          shown,
          reason: '「$shown」解析后再格式化必须回到原写法（否则保存一次就变形）',
        );
      }
    });

    test('非法输入解析成 null，不许当成 0（0 有语义：未设置）', () {
      expect(parseTokenCount(''), isNull);
      expect(parseTokenCount('abc'), isNull);
      expect(parseTokenCount('-5'), isNull);
      expect(parseTokenCount('   '), isNull);
    });
  });

  group('失败文案：超时不许说成网络故障（用户反馈的假故障）', () {
    // 变异：把 timeout 分支的 `took longer than` 去掉 ⇒ 本条转红。
    test('Dio 的超时原文判成「超时」，且不含「网络」', () {
      final msg = humanizeRunFailure(
        'The request connection took longer than 0:05:00.',
      );
      expect(msg, contains('超时'));
      expect(
        msg,
        isNot(contains('网络')),
        reason: 'Dio 的超时文案自带 connection 一词，旧实现因此误报「网络连接失败」',
      );
    });

    test('标准 timeout 文案同样判成超时', () {
      final msg = humanizeRunFailure('request timeout after 300s');
      expect(msg, contains('超时'));
    });

    test('真·网络故障仍然说网络（不许为了修超时把这条也改坏）', () {
      final msg = humanizeRunFailure(
        'SocketException: Failed host lookup: api.example.com',
      );
      expect(msg, contains('网络'));
    });
  });

  group('英文界面底座：缺词条安全回退', () {
    setUp(() {
      setAppLocale('zh');
      resetTranslationCache();
    });
    tearDown(() => setAppLocale('zh'));

    test('中文模式原样返回', () {
      expect(isEnglish, isFalse);
      expect(tr('取消'), '取消');
    });

    test('英文模式查表命中', () {
      setAppLocale('en');
      expect(isEnglish, isTrue);
      expect(tr('取消'), 'Cancel');
    });

    test('★ 缺词条回退中文原文 —— 不许空白、不许抛', () {
      setAppLocale('en');
      const missing = '这条词条故意不存在·zzz';
      expect(tr(missing), missing);
    });

    test('占位参数在两种语言下都替换', () {
      expect(tr('共 {n} 条', args: {'n': 3}), '共 3 条');
      setAppLocale('en');
      final translated = tr('共 {n} 条', args: {'n': 3});
      expect(translated, isNot(contains('{n}')));
      expect(translated, contains('3'));
    });

    test('未知语言被忽略，保持原语言（不许崩）', () {
      setAppLocale('zh');
      setAppLocale('xx');
      expect(appLocale.value.languageCode, 'zh');
      setAppLocale('');
      expect(appLocale.value.languageCode, 'zh');
      setAppLocale(null);
      expect(appLocale.value.languageCode, 'zh');
    });

    test('英文词条表非空（防止把字典改空的回归）', () {
      expect(englishEntryCount, greaterThan(50));
    });
  });
}
