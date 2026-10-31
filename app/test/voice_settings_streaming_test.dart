// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **语音设置页：两张模型卡 + 页顶总状态 + 真卸载/重装**（task-7 / T0-1，2026-10-31）。
//
// 规格（用户第 8 条 / T0-1）：
// · 「流式识别（内置 · 约 24 MB）」与「整段识别 SenseVoice（可选 · 231 MB）」
//   是**两套独立模型/两套状态**，各占一张卡；
// · 页顶总状态只回答"语音输入能不能用"：**不许因为 SenseVoice 没下载
//   就把整体判成"未下载/需重下"**（流式内置默认就绪即可用）；
// · 卸载/重装走 `VoiceModelController.deleteAllVoiceModels()` /
//   `installVoiceModels()`（真删目录 + 落盘标记，不是只删 SenseVoice）。
//
// 本文件钉住：
//   ① 流式已就绪 + SenseVoice 未下载 ⇒ 总状态「可用」，未下载只出现在
//      SenseVoice 那张卡里；两张卡都在；未下载时不显示「删除」
//   ② 两套都没准备 ⇒ 总状态是「需准备」，不是「未下载」
//   ③ 内置准备失败 ⇒ 卡片显示 bundledStreamingError 人话 + 总状态「需准备」，
//      点「重试」真的重新解压并恢复「已就绪」
//   ④ 卸载：确认后真删两个模型目录 + 总状态「已卸载」+ 出现「重新安装」
//   ⑤ 重新安装：清卸载标记 + 重新解压内置模型 ⇒ 恢复「语音输入可用」
//   ⑥ SenseVoice 已下载才显示「删除」
//   ⑦ 页面显示模型真实目录 + 卸载即删说明
//   ⑧ T1-2：总状态明说「可用（无需下载）」；SenseVoice 副标题「可选 ·
//      未下载不影响语音输入」；页面底部三段说明长文已删
//   ⑨ T1-2：AppBar「?」打开说明抽屉（BwSheetShell 统一抓手 + 标题 +
//      三段原文 + 可滚动），关闭后回原页
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/screens/voice_settings_screen.dart';
import 'package:heracles/services/voice_service.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final controller = VoiceModelController.shared();
  late Directory tmp;

  Future<void> seedSparse(String dirPath, String name, int bytes) async {
    await Directory(dirPath).create(recursive: true);
    final raf = await File('$dirPath/$name').open(mode: FileMode.write);
    await raf.truncate(bytes);
    await raf.close();
  }

  /// 内置 14M 流式模型「已就绪」：稀疏文件 + `.complete`（只校验存在+字节数）。
  Future<void> seedBundledReady() async {
    final dir = '${tmp.path}/voice_models/$kBundledStreamingDirName';
    await Directory(dir).create(recursive: true);
    for (final f in kBundledStreamingModelFiles) {
      await seedSparse(dir, f.name, f.bytes);
    }
    await File('$dir/.complete').writeAsString(kBundledStreamingMarker);
    // 按磁盘重算状态（生产由 `load()/refreshInstalled()` 做；这里磁盘已备好）。
    controller.refreshInstalled();
  }

  /// SenseVoice「已下载 + 引擎产物已备好」：稀疏文件（不写 231MB 真权重）。
  Future<void> seedSenseVoiceReady() async {
    final dir = '${tmp.path}/voice_models/sensevoice-small';
    await Directory(dir).create(recursive: true);
    for (final f in kVoiceModelFiles) {
      await seedSparse(dir, f.name, f.bytes);
    }
    // 引擎产物判定：补过 metadata 的模型必须比裸模型大。
    await seedSparse(
      dir,
      kVoiceSherpaModelName,
      kVoiceModelFiles.first.bytes + 11000,
    );
    await seedSparse(dir, kVoiceTokensTxtName, 100);
    await File('$dir/.complete').writeAsString('sensevoice-small-onnx');
    controller.refreshInstalled();
  }

  setUp(() async {
    // 卸载/重装要落盘 `heracles.voice.*` 标记（SharedPreferences）。
    // 不 mock 时 `getInstance()` 会永远不完成 ⇒ 动作卡在 await 上
    // （已知坑：插件没 mock 的 await 会挂死，try/catch 救不了）。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = await Directory.systemTemp.createTemp('voice_cards_');
    controller.profile = JevDeviceProfile(
      model: 'test',
      totalRamMb: 8192,
      freeStorageMb: 99999,
      appFilesDir: tmp.path,
    );
    controller.loaded = true;
    controller.installed = false;
    controller.engineReady = false;
    controller.preparing = false;
    controller.prepareError = null;
    controller.download = const VoiceDownloadState();
    controller.streamingInstalled = false;
    controller.bundledStreamingReady = false;
    controller.bundledStreamingError = null;
    controller.bundledStreamingProgress = null;
    controller.voiceUninstalled = false;
    controller.voiceEnabled = true;
    controller.lastFreedBytes = 0;
    controller.lastDeleteFailures = const <String>[];
    VoiceModelController.bundledModelFilesForTest = null;
    VoiceModelController.bundledAssetDirForTest = null;
    VoiceModelController.bundledAssetLoaderForTest = null;
  });

  tearDown(() async {
    VoiceModelController.bundledModelFilesForTest = null;
    VoiceModelController.bundledAssetDirForTest = null;
    VoiceModelController.bundledAssetLoaderForTest = null;
    controller.profile = null;
    controller.loaded = false;
    controller.installed = false;
    controller.engineReady = false;
    controller.preparing = false;
    controller.prepareError = null;
    controller.download = const VoiceDownloadState();
    controller.streamingInstalled = false;
    controller.bundledStreamingReady = false;
    controller.bundledStreamingError = null;
    controller.bundledStreamingProgress = null;
    controller.voiceUninstalled = false;
    controller.voiceEnabled = true;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      );

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(wrap(const VoiceSettingsScreen()));
    await tester.pump();
    await tester.pump();
  }

  /// 等真实异步（文件 IO/解压）完成：`runAsync` 让出真实事件循环，再 pump。
  Future<void> waitUntil(WidgetTester tester, bool Function() cond) async {
    final sw = Stopwatch()..start();
    while (!cond() && sw.elapsedMilliseconds < 5000) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  String textOf(WidgetTester tester, String key) {
    final t = tester.widget<Text>(find.byKey(Key(key)));
    return t.data ?? t.textSpan!.toPlainText();
  }

  Finder inCard(String key, Finder matching) => find.descendant(
        of: find.byKey(Key(key)),
        matching: matching,
      );

  testWidgets('① 流式已就绪 + SenseVoice 未下载 ⇒ 总状态「可用」，未下载只算 SenseVoice',
      (tester) async {
    await tester.runAsync(seedBundledReady);
    await pumpScreen(tester);

    final total = textOf(tester, 'voice-total-status');
    expect(total, contains('语音输入可用'),
        reason: '流式内置已就绪就是「语音输入可用」—— 不能被 SenseVoice 未下载拖成整体不可用');
    expect(total, contains('无需下载'),
        reason: 'T1-2：「无需下载」必须明说 —— 用户不该以为要下 231MB 才能用语音');
    expect(total, isNot(contains('未下载')), reason: '总状态不许出现「未下载」口径');
    expect(total, isNot(contains('不可用')));

    // 两张卡都在，且各说各的状态。
    expect(find.byKey(const Key('voice-streaming-card')), findsOneWidget);
    expect(find.byKey(const Key('voice-sensevoice-card')), findsOneWidget);
    expect(textOf(tester, 'voice-streaming-status'), contains('已就绪'));
    expect(inCard('voice-sensevoice-card', find.textContaining('ONNX 量化版')),
        findsOneWidget);

    // 未下载 ⇒ 不显示「删除」（删的是 SenseVoice，不是整体）。
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('② 两套都没准备 ⇒ 总状态「需准备」，不是「未下载」',
      (tester) async {
    await pumpScreen(tester);

    final total = textOf(tester, 'voice-total-status');
    expect(total, contains('语音输入需准备'),
        reason: '内置模型开箱即用、首次点麦克风才解压 —— 不该显示未下载/需重下');
    expect(total, isNot(contains('未下载')));
    expect(textOf(tester, 'voice-streaming-status'), contains('首次使用'));
  });

  testWidgets('③ 内置准备失败 ⇒ 卡片显示人话 + 总状态「需准备」+ 重试重新解压',
      (tester) async {
    controller.bundledStreamingError = '内置流式模型解压失败（尝试 2/2）：磁盘空间不足';
    var calls = 0;
    VoiceModelController.bundledModelFilesForTest = const <VoiceModelFile>[
      VoiceModelFile('encoder.onnx', 8),
      VoiceModelFile('decoder.onnx', 4),
    ];
    VoiceModelController.bundledAssetDirForTest = 'fake/assets';
    VoiceModelController.bundledAssetLoaderForTest = (String assetKey) async {
      calls++;
      return Uint8List(assetKey.endsWith('encoder.onnx') ? 8 : 4);
    };

    await pumpScreen(tester);
    expect(textOf(tester, 'voice-total-status'), contains('需准备'));
    expect(inCard('voice-streaming-card', find.textContaining('磁盘空间不足')),
        findsOneWidget,
        reason: '准备失败必须把 bundledStreamingError 的人话原因显示出来');
    expect(find.byKey(const Key('voice-streaming-retry')), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-streaming-retry')));
    await tester.pump();
    await waitUntil(tester, () => controller.bundledStreamingReady);
    await tester.pump();

    expect(calls, greaterThan(0), reason: '「重试」必须真的重新解压（不是只换个文案）');
    expect(textOf(tester, 'voice-streaming-status'), contains('已就绪'));
    expect(textOf(tester, 'voice-total-status'), contains('语音输入可用'));
    expect(find.byKey(const Key('voice-streaming-retry')), findsNothing);
  });

  testWidgets('④ 卸载：确认后真删两个模型目录 + 总状态「已卸载」+ 重新安装入口',
      (tester) async {
    await tester.runAsync(seedBundledReady);
    await tester.runAsync(seedSenseVoiceReady);
    await pumpScreen(tester);
    expect(textOf(tester, 'voice-total-status'), contains('语音输入可用'));
    expect(find.byKey(const Key('voice-uninstall')), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-uninstall')));
    await tester.pumpAndSettle();
    expect(find.text('卸载语音输入？'), findsOneWidget,
        reason: '卸载是破坏性操作，必须先确认');
    await tester.tap(find.text('确认卸载'));
    await tester.pump();
    await waitUntil(tester, () => controller.voiceUninstalled);
    await tester.pump();

    // 真删（不是只删 SenseVoice）。
    expect(
      Directory('${tmp.path}/voice_models/$kBundledStreamingDirName')
          .existsSync(),
      isFalse,
      reason: '内置流式模型目录必须一起删掉',
    );
    expect(
      Directory('${tmp.path}/voice_models/sensevoice-small').existsSync(),
      isFalse,
      reason: 'SenseVoice 目录也必须删掉',
    );
    expect(textOf(tester, 'voice-total-status'), contains('语音输入不可用（已卸载）'));
    expect(textOf(tester, 'voice-action-note'), contains('已释放'));
    expect(find.byKey(const Key('voice-install')), findsOneWidget);
    expect(find.byKey(const Key('voice-uninstall')), findsNothing);
  });

  testWidgets('⑤ 重新安装：清卸载标记 + 重新解压内置模型 ⇒ 恢复「语音输入可用」',
      (tester) async {
    // 「上次已卸载」是落盘状态 ⇒ 让 load() 读到的 prefs 也是已卸载。
    SharedPreferences.setMockInitialValues(<String, Object>{
      kVoiceUninstalledPrefsKey: true,
      kVoiceEnabledPrefsKey: false,
    });
    controller.voiceUninstalled = true;
    controller.voiceEnabled = false;
    var calls = 0;
    VoiceModelController.bundledModelFilesForTest = const <VoiceModelFile>[
      VoiceModelFile('encoder.onnx', 8),
    ];
    VoiceModelController.bundledAssetDirForTest = 'fake/assets';
    VoiceModelController.bundledAssetLoaderForTest = (String assetKey) async {
      calls++;
      return Uint8List(8);
    };

    await pumpScreen(tester);
    expect(textOf(tester, 'voice-total-status'), contains('语音输入不可用（已卸载）'));
    expect(find.byKey(const Key('voice-install')), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice-install')));
    await tester.pump();
    await waitUntil(
      tester,
      () => !controller.voiceUninstalled && controller.bundledStreamingReady,
    );
    await tester.pump();

    expect(calls, greaterThan(0), reason: '重新安装要真的解压内置模型');
    expect(controller.voiceUninstalled, isFalse);
    expect(textOf(tester, 'voice-total-status'), contains('语音输入可用'));
    expect(find.byKey(const Key('voice-uninstall')), findsOneWidget);
  });

  testWidgets('⑥ SenseVoice 已下载才显示「删除」', (tester) async {
    await tester.runAsync(seedBundledReady);
    await tester.runAsync(seedSenseVoiceReady);
    await pumpScreen(tester);

    expect(textOf(tester, 'voice-total-status'), contains('语音输入可用'));
    expect(inCard('voice-sensevoice-card', find.text('删除')), findsOneWidget);
    expect(textOf(tester, 'voice-streaming-status'), contains('已就绪'));
  });

  testWidgets('⑦ 页面显示模型真实目录 + 卸载即删说明（用户要能核对）',
      (tester) async {
    await tester.runAsync(seedBundledReady);
    await pumpScreen(tester);

    // 真实落盘目录 = profile.appFilesDir/voice_models（App 私有）
    final expectedDir = '${tmp.path}/voice_models';
    expect(find.byKey(const Key('voice-models-dir')), findsOneWidget,
        reason: '语音设置页必须能核对模型装在哪个目录');
    expect(find.textContaining(expectedDir), findsOneWidget,
        reason: '目录必须是真实路径（不是编的）: $expectedDir');
    expect(find.textContaining('卸载语音输入'), findsWidgets,
        reason: '要写清卸载会删掉这个目录下的两套模型');
  });

  // ------------------------------------------------ T1-2：无需下载 / 说明抽屉

  testWidgets('⑧ 总状态明说「可用（无需下载）」+ SenseVoice 副标题「可选 · 未下载不影响语音输入」',
      (tester) async {
    await tester.runAsync(seedBundledReady);
    await pumpScreen(tester);

    expect(textOf(tester, 'voice-total-status'), contains('语音输入可用（无需下载）'),
        reason: '内置流式随包 —— SenseVoice 未下载时必须明说"可用且无需下载"，'
            '否则用户会以为必须下 231MB 才能用语音');

    final optional =
        tester.widget<Text>(find.byKey(const Key('voice-sensevoice-optional')));
    final text = optional.data ?? optional.textSpan!.toPlainText();
    expect(text, contains('可选'), reason: 'SenseVoice 是可选高精度模型');
    expect(text, contains('未下载不影响语音输入'),
        reason: '不能让「未下载」看起来像故障/缺失必需件');

    // 三段说明长文已从页面底部删除（只留在 ? 抽屉里）。
    expect(find.textContaining('14M 中文 streaming zipformer 已随 App 打包'),
        findsNothing, reason: '说明长文收进抽屉后，页面上不该还有');
    expect(find.textContaining('经 ModelScope 官方仓库下载'), findsNothing);
    expect(find.textContaining('麦克风权限在「设置 → 设备权限」里统一开启'), findsNothing);
  });

  testWidgets('⑨ AppBar「?」打开说明抽屉：标题 + 三段原文 + 统一抓手 + 可滚动；关闭回原页',
      (tester) async {
    // 矮屏：让三段说明超出可视高度，同时验证「可滚动」而不是溢出。
    tester.view.physicalSize = const Size(320, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpScreen(tester);
    expect(find.byKey(const Key('voice-help')), findsOneWidget,
        reason: 'AppBar 右上角要有「?」入口');
    expect(find.text('语音识别说明'), findsNothing);

    await tester.tap(find.byKey(const Key('voice-help')));
    await tester.pumpAndSettle();

    expect(find.text('语音识别说明'), findsOneWidget, reason: '抽屉标题');
    // 三段原文搬进抽屉（不是删掉）。
    expect(find.textContaining('流式识别（内置）：14M 中文 streaming zipformer'),
        findsOneWidget);
    expect(find.textContaining('整段识别（可选）：SenseVoiceSmall'), findsOneWidget);
    expect(find.textContaining('「卸载语音输入」会删掉两套模型'), findsOneWidget);
    expect(find.textContaining('麦克风权限在「设置 → 设备权限」里统一开启'), findsOneWidget);

    // 统一抓手由 BwSheetShell 默认渲染（别自绘 ⇒ 只能有一个）。
    expect(find.byType(BwSheetHandle), findsOneWidget,
        reason: '抽屉抓手必须走 BwSheetShell 的统一 BwSheetHandle');

    // 内容可滚动：矮屏下三段说明超出可视高度，应能滚（不是溢出裁字）。
    final scrollable = tester.state<ScrollableState>(find
        .descendant(
          of: find.byType(BwSheetShell),
          matching: find.byType(Scrollable),
        )
        .first);
    expect(scrollable.position.maxScrollExtent, greaterThan(0),
        reason: '说明抽屉内容要能滚动（矮屏/大字号下不能溢出）');
    expect(tester.takeException(), isNull);

    // 关闭 ⇒ 回原页。
    await tester.tap(find.byKey(const Key('voice-help-close')));
    await tester.pumpAndSettle();
    expect(find.text('语音识别说明'), findsNothing, reason: '关掉抽屉应回到原页');
    expect(find.byKey(const Key('voice-total-status')), findsOneWidget);
  });
}
