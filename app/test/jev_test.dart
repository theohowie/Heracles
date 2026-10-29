import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/screens/jev_settings_screen.dart';
import 'package:heracles/screens/settings_screen.dart';
import 'package:heracles/services/jev_service.dart';
import 'package:heracles/services/settings_controller.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';
import 'package:heracles/widgets/decision_panel.dart';

import 'support/secure_storage_mock.dart';

/// **JEV 决策引擎回归测试**（2026-10-27）。
///
/// 覆盖：本机选型三档、配置/记录 JSON 往返、云端端点拼装、
/// 落盘往返、决策面板三态（空态/结果卡/历史提升）、配置页
/// 本机检测卡。云端真请求与本地推理不在此测（前者要真服务，
/// 后者引擎未接入、契约恒 null）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('本机选型推荐', () {
    test('K60 级（12GB/46GB）→ 本地 2B', () {
      const p = JevDeviceProfile(
        model: '23013RK75C',
        totalRamMb: 12288,
        freeStorageMb: 47104,
        appFilesDir: '/data/files',
      );
      final r = recommendJev(p);
      expect(r.tier, JevTier.local2b);
      expect(r.source, JevSource.local2b);
    });

    test('4GB 机型 → 本地 0.8B', () {
      const p = JevDeviceProfile(
        model: 'small',
        totalRamMb: 4096,
        freeStorageMb: 20000,
        appFilesDir: '/data/files',
      );
      expect(recommendJev(p).tier, JevTier.local08);
    });

    test('2GB 机型 → 只能云端', () {
      const p = JevDeviceProfile(
        model: 'tiny',
        totalRamMb: 2048,
        freeStorageMb: 20000,
        appFilesDir: '/data/files',
      );
      final r = recommendJev(p);
      expect(r.tier, JevTier.cloudOnly);
      expect(r.source, isNull);
    });

    test('内存够但存储不够 → 降档到 0.8B', () {
      const p = JevDeviceProfile(
        model: 'full',
        totalRamMb: 12288,
        freeStorageMb: 2000, // 不够 2B 的 3.2GB，够 0.8B 的 1.2GB
        appFilesDir: '/data/files',
      );
      expect(recommendJev(p).tier, JevTier.local08);
    });
  });

  group('模型往返', () {
    test('JevConfig JSON 往返 + 未知来源回退云端', () {
      const c = JevConfig(
        source: JevSource.local2b,
        cloudBaseUrl: 'https://x.example/v1',
        cloudModel: 'm1',
        reasonEnabled: false,
      );
      final back = JevConfig.fromJson(c.toJson());
      expect(back.source, JevSource.local2b);
      expect(back.cloudBaseUrl, 'https://x.example/v1');
      expect(back.cloudModel, 'm1');
      expect(back.reasonEnabled, isFalse);
      expect(JevConfig.fromJson(const {'source': 'nope'}).source,
          JevSource.cloud);
    });

    test('JevDecision 概率语义：0.22 → 不推荐、置信度 0.78', () {
      final d = JevDecision(
        id: 'j1',
        question: '要不要合并？',
        yesProb: 0.22,
        engineLabel: '本地 2B',
        elapsedMs: 400,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        reason: '理由文本',
        reasonSource: JevReasonSource.llm,
      );
      expect(d.recommended, isFalse);
      expect(d.confidence, closeTo(0.78, 1e-9));
      final back = JevDecision.fromJson(d.toJson());
      expect(back.question, '要不要合并？');
      expect(back.yesProb, 0.22);
      expect(back.reasonSource, JevReasonSource.llm);
    });

    test('JevStore 落盘往返（配置 + 历史）', () async {
      SharedPreferences.setMockInitialValues({});
      await JevStore.saveConfig(const JevConfig(
          source: JevSource.local08, cloudBaseUrl: 'https://a/v1'));
      final c = await JevStore.loadConfig();
      expect(c.source, JevSource.local08);
      expect(c.cloudBaseUrl, 'https://a/v1');

      await JevStore.saveHistory([
        JevDecision(
          id: 'j9',
          question: 'q',
          yesProb: 0.9,
          engineLabel: '云端',
          elapsedMs: 10,
          createdAt: DateTime.fromMillisecondsSinceEpoch(5),
        ),
      ]);
      final h = await JevStore.loadHistory();
      expect(h, hasLength(1));
      expect(h.first.id, 'j9');
    });
  });

  group('云端端点拼装', () {
    test('填到 /v1 → 补推荐端点 /decision（基元律动文档定版）', () {
      expect(JevCloudClient.endpointFor('https://x.example/v1'),
          'https://x.example/v1/decision');
      expect(JevCloudClient.endpointFor('https://x.example/v1/'),
          'https://x.example/v1/decision');
    });

    test('完整端点地址原样使用（/decision / /decisions / /systemone）', () {
      expect(JevCloudClient.endpointFor('https://b.example/v1/decisions'),
          'https://b.example/v1/decisions');
      expect(
          JevCloudClient.endpointFor('https://tokenrhythm.studio/v1/decision'),
          'https://tokenrhythm.studio/v1/decision');
      expect(JevCloudClient.endpointFor('https://b.example/v1/systemone'),
          'https://b.example/v1/systemone');
    });

    test('模型目录地址：决策端点去掉末段拼 /models', () {
      expect(
          JevCloudClient.modelsUrlFor('https://tokenrhythm.studio/v1/decision'),
          'https://tokenrhythm.studio/v1/models');
      expect(JevCloudClient.modelsUrlFor('https://x.example/v1'),
          'https://x.example/v1/models');
      expect(JevCloudClient.modelsUrlFor('https://x.example/v1/systemone'),
          'https://x.example/v1/models');
    });

    test('配置预置：默认端点与固定模型；存量空值回落预置', () {
      const c = JevConfig();
      expect(c.cloudBaseUrl, 'https://tokenrhythm.studio/v1/decision');
      expect(c.cloudModel, 'NeoHorse-Jev-4B');
      final back = JevConfig.fromJson(const {
        'source': 'cloud',
        'cloudBaseUrl': '',
        'cloudModel': '',
        'reasonEnabled': true,
      });
      expect(back.cloudBaseUrl, 'https://tokenrhythm.studio/v1/decision');
      expect(back.cloudModel, 'NeoHorse-Jev-4B');
    });
  });

  group('决策面板与配置页', () {
    late SettingsController settings;
    late JevController jev;
    late TextEditingController inputCtrl;

    Widget wrap(Widget child) => MaterialApp(
          theme: buildHeraclesTheme(),
          builder: (context, inner) => HueScope(
            hue: Hue.darkHue,
            child: inner ?? const SizedBox.shrink(),
          ),
          home: child,
        );

    JevDecision decision({
      required String id,
      required String q,
      required double yesProb,
      String? reason,
      JevReasonSource source = JevReasonSource.none,
    }) =>
        JevDecision(
          id: id,
          question: q,
          yesProb: yesProb,
          engineLabel: '本地 2B',
          elapsedMs: 400,
          createdAt: DateTime.now(),
          reason: reason,
          reasonSource: source,
        );

    setUp(() async {
      installSecureStorageMock();
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsController.load();
      jev = JevController.shared();
      jev.config = const JevConfig();
      jev.history = const [];
      jev.profile = null;
      jev.loaded = true;
      jev.busy = false;
      jev.lastError = null;
      inputCtrl = TextEditingController();
    });

    tearDown(() => inputCtrl.dispose());

    Widget panel() => DecisionPanel(
          jev: jev,
          settings: settings,
          inputController: inputCtrl,
          onOpenConfig: () {},
        );

    testWidgets('空态：大标题 + 示例胶囊 + 决策输入框', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      expect(find.textContaining('有什么拿不准的'), findsOneWidget);
      expect(find.text('今晚要不要熬夜把这个功能做完'), findsOneWidget);
      expect(find.text('说一件你拿不准的事…'), findsOneWidget);
      // 点示例胶囊 → 填进输入框
      await tester.tap(find.text('周末要不要去参加线下活动'));
      await tester.pump();
      expect(inputCtrl.text, '周末要不要去参加线下活动');
    });

    testWidgets('结果卡：不推荐 78% + 理由 + 来源标注', (tester) async {
      jev.history = [
        decision(
          id: 'j1',
          q: '今晚要不要把新功能合并进主分支',
          yesProb: 0.22,
          reason: '先合到测试分支验证，明晚再进主分支。',
          source: JevReasonSource.llm,
        ),
      ];
      await tester.pumpWidget(wrap(panel()));
      expect(find.text('今晚要不要把新功能合并进主分支'), findsOneWidget);
      expect(find.text('不推荐'), findsWidgets);
      expect(find.text('78%'), findsOneWidget);
      expect(find.text('推荐 22%'), findsOneWidget);
      expect(find.text('不推荐 78%'), findsOneWidget);
      expect(find.text('先合到测试分支验证，明晚再进主分支。'), findsOneWidget);
      expect(find.text('理由由对话模型补写'), findsOneWidget);
      // 只有一条历史时不出现历史区
      expect(find.text('决策历史'), findsNothing);
    });

    testWidgets('两条历史：旧记录在列表里，点它提升为大卡', (tester) async {
      jev.history = [
        decision(id: 'j2', q: '新问题：要不要去黑客松', yesProb: 0.93),
        decision(id: 'j1', q: '旧问题：要不要熬夜', yesProb: 0.22),
      ];
      await tester.pumpWidget(wrap(panel()));
      expect(find.text('决策历史'), findsOneWidget);
      expect(find.text('旧问题：要不要熬夜'), findsOneWidget);
      await tester.tap(find.text('旧问题：要不要熬夜'));
      await tester.pump();
      // 旧记录升为大卡（出现它的置信度），新记录退回列表
      expect(find.text('78%'), findsOneWidget);
      expect(find.text('新问题：要不要去黑客松'), findsOneWidget);
    });

    testWidgets('配置页：云端在前、来源选择已挪走；本地内容收进「本地配置」页',
        (tester) async {
      jev.profile = const JevDeviceProfile(
        model: '23013RK75C',
        totalRamMb: 12288,
        freeStorageMb: 47104,
        appFilesDir: '/data/user/0/files',
      );
      await tester.pumpWidget(wrap(JevSettingsScreen(jev: jev)));
      await tester.pump();
      expect(find.text('JEV 决策引擎'), findsOneWidget);
      // ★ 2026-10-28 重排：云端字段一进页就能看到（不用滚动），
      // 引擎来源分段选择已按用户要求挪到决策页的来源抽屉。
      expect(find.text('接口地址'), findsOneWidget);
      expect(find.text('引擎来源'), findsNothing);
      // ★ 2026-10-29：与提供商编辑页同款的获取模型 / 测试连接。
      expect(find.text('获取可用模型'), findsOneWidget);
      expect(find.text('测试连接'), findsOneWidget);
      // 本机检测与本地模型不在本页 —— 滚到「本地配置」入口点进去。
      await tester.scrollUntilVisible(find.text('本地配置'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('StartLux-Decision 2B'), findsNothing);
      await tester.tap(find.text('本地配置'));
      await tester.pumpAndSettle();
      expect(find.text('本机检测'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('23013RK75C'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('最优方案：本地 2B'), findsOneWidget);
      expect(find.text('按推荐切换到「本地 2B」'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('StartLux-Decision 0.8B'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('StartLux-Decision 0.8B'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('StartLux-Decision 2B'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('StartLux-Decision 2B'), findsOneWidget);
    });

    testWidgets('来源胶囊：云朵图标，点开抽屉切换来源', (tester) async {
      await tester.pumpWidget(wrap(panel()));
      // 云端来源配云朵图标（旧版恒天平，用户实报不对）。
      expect(find.byIcon(Icons.cloud), findsOneWidget);
      // 麦克风占位钮与工作模式同规格，在发送键左侧。
      expect(find.byIcon(AppIcons.mic), findsOneWidget);
      expect(find.byIcon(AppIcons.send), findsOneWidget);
      await tester.tap(find.text('云端'));
      await tester.pumpAndSettle();
      expect(find.text('引擎来源'), findsOneWidget);
      await tester.tap(find.text('本地 2B'));
      await tester.pumpAndSettle();
      expect(jev.config.source, JevSource.local2b);
      // 胶囊、图标与信息条都跟着新来源走。
      expect(find.text('本地 2B'), findsOneWidget);
      expect(find.byIcon(Icons.memory), findsOneWidget);
      expect(find.text('本地模型在本机出决策 · 不联网'), findsOneWidget);
    });

    testWidgets('模型页：JEV 与提供商并列，点编辑进编辑页', (tester) async {
      await tester.pumpWidget(wrap(ModelSettingsPage(controller: settings)));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('JEV 决策引擎'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('JEV 决策引擎'), findsOneWidget);
      // 地址已预置、测试环境无密钥 → 状态是「待填密钥」（2026-10-29 口径）
      expect(find.text('来源 云端 · 待填密钥'), findsOneWidget);
      // JEV 卡在提供商之后，「编辑」取最后一个即它自己的。
      await tester.tap(find.text('编辑').last);
      await tester.pumpAndSettle();
      expect(find.text('接口地址'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
    });
  });
}
