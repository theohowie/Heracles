// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **第 6 条 P2：语音模型下载卡不得随字节数抖动**（2026-10-29 用户反馈）。
//
// 旧行为：下载进度行是一整条无 maxLines 的 Text（'正在下载 x.onnx · 999.9 KB / 230.4 MB'）。
// 字节数从 999.9KB → 1.0MB 会短 2 个字符、9.9MB → 10.0MB 会长 1 个字符，
// 在 ~347dp 可用宽处跨过换行边界 ⇒ 行数 1↔2 变化 ⇒ 卡片高度抖动/进度条跳动。
//
// 规格：固定两行（第一行文件名 maxLines:1+ellipsis；第二行「已下载 X / Y」永不换行），
// 数字用 FontFeature.tabularFigures + 固定 1 位小数，整块高度不随数据变化。
//
// 本文件钉住：
//   ① 进度行**只占一行**（旧行为在 390dp 下折成两行 ⇒ 红）
//   ② 两行都显式 maxLines:1（旧行为 null ⇒ 红）
//   ③ 进度文案是「已下载 X / Y」且数字固定 1 位小数、字体带 tabularFigures（旧行为 ⇒ 红）
//   ④ 六个边界字节值下卡片高度**恒定**，且 390dp/320dp 两种宽度下高度一致
//   ⑤ 全程无 RenderFlex 溢出

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/screens/voice_settings_screen.dart';
import 'package:heracles/services/voice_service.dart';
import 'package:heracles/theme/app_theme.dart';

void main() {
  /// 单例控制器（生产同一对象；测试直接喂状态）。
  final controller = VoiceModelController.shared();
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('voice_card_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
    controller.download = const VoiceDownloadState();
    controller.installed = false;
    controller.engineReady = false;
    controller.preparing = false;
    controller.prepareError = null;
    controller.profile = null;
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(),
        builder: (context, inner) => HueScope(
          hue: Hue.darkHue,
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(body: child),
      );

  /// 喂一个"下载中"状态。注意：每次 pumpWidget 前都要重置，
  /// 否则 `load()` 的异步回填会把状态改回去（单例跨用例复用）。
  void seedDownloading(int received) {
    controller.profile = JevDeviceProfile(
      model: 'test',
      totalRamMb: 8192,
      freeStorageMb: 99999,
      appFilesDir: tmp.path,
    );
    controller.installed = false;
    controller.engineReady = false;
    controller.preparing = false;
    controller.prepareError = null;
    controller.download = VoiceDownloadState(
      phase: VoiceModelPhase.downloading,
      received: received,
      total: kVoiceModelTotalBytes,
      note: '正在下载 model_quant.onnx',
    );
  }

  Future<void> pumpAt(WidgetTester tester, double width, int received) async {
    await tester.binding.setSurfaceSize(Size(width, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    seedDownloading(received);
    await tester.pumpWidget(wrap(const VoiceSettingsScreen()));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 80));
  }

  /// 进度行（新旧实现都唯一含「 / 」的那条 Text）。
  final progress = find.textContaining(' / ');

  /// 卡片容器 = 进度条最近的 Container 祖先（_card 的 Container）。
  Finder cardOf() => find
      .ancestor(
        of: find.byType(LinearProgressIndicator),
        matching: find.byType(Container),
      )
      .first;

  /// 边界采样：0B / 999.9KB / 1.0MB / 9.9MB / 10.0MB / 231.5MB。
  final boundaries = <int>[
    0, // 0 B
    1023898, // 999.9 KB（999.9 * 1024 四舍五入）
    1024 * 1024, // 1.0 MB
    (9.9 * 1024 * 1024).round(), // 9.9 MB
    10 * 1024 * 1024, // 10.0 MB
    (231.5 * 1024 * 1024).round(), // 231.5 MB
  ];

  testWidgets('① 390dp 下进度行只占一行（旧行为折两行 ⇒ 高度抖动）', (tester) async {
    await pumpAt(tester, 390, boundaries[1]);
    expect(progress, findsOneWidget, reason: '应有一条进度行');

    final style = tester.widget<Text>(progress).style!;
    final h = tester.getSize(progress).height;
    // 测试字体（Ahem）每行 = fontSize；两行就是 24。给 1.6x 余量。
    expect(
      h,
      lessThanOrEqualTo(style.fontSize! * 1.6),
      reason: '进度行折行了（高 $h > 单行上限）：卡片高度会随字节数抖动',
    );
  });

  testWidgets('② 文件名行与进度行都显式 maxLines:1（不会换行改变高度）', (tester) async {
    await pumpAt(tester, 390, boundaries[2]);

    final title = tester.widget<Text>(find.text('SenseVoiceSmall'));
    expect(title.maxLines, 1, reason: '文件名必须单行 + ellipsis');

    final prog = tester.widget<Text>(progress);
    expect(prog.maxLines, 1, reason: '「已下载 X / Y」永不换行');
  });

  testWidgets('③ 文案是「已下载 X / Y」+ 固定 1 位小数 + tabularFigures', (tester) async {
    await pumpAt(tester, 390, boundaries[1]);

    final t = tester.widget<Text>(progress);
    final text = t.data ?? t.textSpan!.toPlainText();
    expect(text, startsWith('已下载 '),
        reason: '下载中文案应为「已下载 X / Y」，不能是「正在下载…」整段');
    expect(
      RegExp(r'^已下载 \d+\.\d (B|KB|MB|GB) / \d+\.\d (B|KB|MB|GB)$')
          .hasMatch(text),
      isTrue,
      reason: '数字必须固定 1 位小数（宽度稳定）：实际「$text」',
    );

    final features = t.style?.fontFeatures ?? const <FontFeature>[];
    expect(
      features.contains(const FontFeature.tabularFigures()),
      isTrue,
      reason: '数字要用 tabular figures（等宽数字），否则位数变化仍会挤动',
    );
  });

  testWidgets('④ 六个边界字节值 + 390/320 两种宽度 ⇒ 卡片高度恒定、无溢出',
      (tester) async {
    final heights = <int, double>{};
    for (final received in boundaries) {
      await pumpAt(tester, 390, received);
      heights[received] = tester.getSize(cardOf()).height;
      expect(tester.takeException(), isNull,
          reason: '字节数 $received 时出现了布局异常');
    }
    final distinct = heights.values.toSet();
    expect(distinct.length, 1,
        reason: '卡片高度随字节数变化：$heights（这就是用户看到的抖动）');

    // 同一数据、窄屏：高度不得因为换行而改变。
    await pumpAt(tester, 320, boundaries[1]);
    final narrow = tester.getSize(cardOf()).height;
    expect(narrow, heights[boundaries[1]],
        reason: '390dp 与 320dp 下卡片高度不一致 ⇒ 换行在改变布局');
    expect(tester.takeException(), isNull);
  });
}
