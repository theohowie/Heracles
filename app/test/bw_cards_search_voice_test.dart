import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/models/settings.dart';
import 'package:heracles/models/view_options.dart';
import 'package:heracles/models/workspace.dart';
import 'package:heracles/screens/voice_settings_screen.dart';
import 'package:heracles/services/voice_asr.dart';
import 'package:heracles/services/voice_service.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/widgets/bw_approval.dart';
import 'package:heracles/widgets/bw_model_sheet.dart';
import 'package:heracles/widgets/git_branch_sheet.dart';
import 'package:heracles/widgets/workspace_drawer.dart';

/// **2026-10-29 抽屉样式统一 + 弹性搜索 + 语音设置页的回归测试**。
///
/// 用户定版：抽屉内单选一律图一式边框选项卡（未选中灰边框、
/// 选中黑边框）；动作行用无圆点的边框动作卡（按下黑边框）；
/// 分支抽屉底部并排黑按钮；侧边栏搜索就地弹性展开，不跳页。
/// 断言落在行为与关键视觉量（边框色）上，防改回去。
void main() {
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

  BoxDecoration cardDecoration(WidgetTester tester, Finder card) {
    final container = tester.widget<Container>(
      find
          .descendant(of: card, matching: find.byType(Container))
          .first,
    );
    return container.decoration as BoxDecoration;
  }

  // ---------------------------------------------------------- 选项卡

  testWidgets('BwOptionCard：选中 = 主文本色边框，未选中 = 灰边框',
      (tester) async {
    final h = Hue.darkHue;
    var taps = 0;
    await tester.pumpWidget(wrap(Column(
      children: [
        BwOptionCard(
          h: h,
          selected: true,
          title: '已选项',
          onTap: () => taps++,
        ),
        BwOptionCard(
          h: h,
          selected: false,
          title: '未选项',
          onTap: () => taps++,
        ),
      ],
    )));
    final cards = find.byType(BwOptionCard);
    expect(cardDecoration(tester, cards.at(0)).border!.top.color, h.text,
        reason: '选中卡边框必须是主文本色（浅色下黑边框）');
    expect(cardDecoration(tester, cards.at(1)).border!.top.color, h.border,
        reason: '未选中卡边框必须是常规边框色');
    await tester.tap(find.text('未选项'));
    expect(taps, 1);
  });

  testWidgets('BwActionCard：无圆点、灰边框、点按触发', (tester) async {
    final h = Hue.darkHue;
    var taps = 0;
    await tester.pumpWidget(wrap(BwActionCard(
      h: h,
      icon: CupertinoIcons.camera_fill,
      label: '相机',
      subtitle: '拍照',
      onTap: () => taps++,
    )));
    final deco = cardDecoration(tester, find.byType(BwActionCard));
    expect(deco.border!.top.color, h.border);
    expect(deco.borderRadius, BorderRadius.circular(18));
    await tester.tap(find.text('相机'));
    expect(taps, 1);
  });

  // ---------------------------------------------------------- 模型抽屉

  testWidgets('模型抽屉：提供商行是边框选项卡，点选切换', (tester) async {
    await usePhoneSurface(tester);
    String? picked;
    ModelProviderConfig cfg(String id, String model) => ModelProviderConfig(
          id: id,
          name: id,
          baseUrl: 'https://api.example.com/v1',
          model: model,
          apiKey: 'sk-test',
        );
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: GestureDetector(
          onTap: () => showModelSheet(
            ctx,
            providers: [cfg('p1', 'm-one'), cfg('p2', 'm-two')],
            activeProviderId: 'p1',
            reasoningLevel: ReasoningLevel.auto,
            onProviderSelected: (id) => picked = id,
          ),
          child: const Text('打开'),
        ),
      ),
    )));
    await tester.tap(find.text('打开'));
    await settle(tester, times: 10);
    expect(find.byType(BwOptionCard), findsNWidgets(2),
        reason: '两个提供商各一张边框选项卡');
    await tester.tap(find.text('m-two'));
    await settle(tester, times: 10);
    expect(picked, 'p2');
  });

  // ---------------------------------------------------------- 分支抽屉

  testWidgets('分支抽屉：选项卡列表 + 底部并排黑按钮（提交与推送）',
      (tester) async {
    await usePhoneSurface(tester);
    String? result;
    await tester.pumpWidget(wrap(Builder(
      builder: (ctx) => Center(
        child: GestureDetector(
          onTap: () async {
            result = await showGitBranchSheet(
              ctx,
              loader: () async => ['master', 'frontend'],
              current: 'master',
              onAdvanced: () {},
            );
          },
          child: const Text('打开'),
        ),
      ),
    )));
    await tester.tap(find.text('打开'));
    await settle(tester, times: 10);
    expect(find.byType(BwOptionCard), findsNWidgets(2));
    expect(find.text('新建分支'), findsOneWidget);
    expect(find.text('提交与推送'), findsOneWidget);
    await tester.tap(find.text('提交与推送'));
    await settle(tester, times: 10);
    expect(result, gitBranchSheetAdvanced);
  });

  // ---------------------------------------------------------- 抽屉搜索

  testWidgets('侧边栏搜索：点图标就地展开，搜索/清空/取消都工作',
      (tester) async {
    await usePhoneSurface(tester);
    String? query;
    await tester.pumpWidget(wrap(WorkspaceDrawer(
      workspaces: const [
        HWorkspace(
          id: 'w1',
          name: 'proj',
          path: '/x/proj',
          sessions: [
            HSession(id: 's1', title: '苹果会话'),
            HSession(id: 's2', title: '香蕉会话'),
          ],
        ),
      ],
      onSelectSession: (workspaceId, sessionId) {},
      onNewSession: (workspaceId) {},
      onOpenSettings: () {},
      viewOptions: const ViewOptions(),
      onViewOptionsChanged: (options) {},
      searchQuery: '',
      onSearchChanged: (q) => query = q,
    )));
    await settle(tester, times: 10);

    // 收起态：没有输入框（不跳搜索页的第一道防线）
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byIcon(CupertinoIcons.search).first);
    await settle(tester);
    expect(find.byType(TextField), findsOneWidget,
        reason: '搜索框应就地展开在侧边栏里，而不是弹抽屉/跳页');
    expect(find.text('取消'), findsOneWidget,
        reason: '展开后框外左侧应有「取消」');

    await tester.enterText(find.byType(TextField), '苹果');
    await settle(tester, times: 5);
    expect(find.byIcon(CupertinoIcons.xmark_circle_fill), findsOneWidget,
        reason: '有内容时搜索按钮左侧应出现小 ×');

    await tester.tap(find.text('搜索'));
    await settle(tester, times: 5);
    expect(query, '苹果', reason: '点框内「搜索」才提交筛选词');

    await tester.tap(find.byIcon(CupertinoIcons.xmark_circle_fill));
    await settle(tester, times: 5);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty, reason: '× 应清空输入内容');

    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(find.byType(TextField), findsNothing,
        reason: '取消后搜索框收起、按钮恢复');
  });

  // ---------------------------------------------------------- 语音

  test('语音模型清单：4 个文件、总字节与 ModelScope 仓库一致', () {
    expect(kVoiceModelFiles.map((f) => f.name), [
      'model_quant.onnx',
      'tokens.json',
      'am.mvn',
      'config.yaml',
    ]);
    expect(kVoiceModelTotalBytes, 241581392);
    expect(voiceFormatBytes(kVoiceModelTotalBytes), '230.4 MB');
  });

  test('语音模型安装判定：缺文件/大小对不上都不算已安装', () async {
    final tmp = await Directory.systemTemp.createTemp('voice_test_');
    addTearDown(() => tmp.delete(recursive: true));
    final c = VoiceModelController.shared();
    c.profile = JevDeviceProfile(
      model: 'test',
      totalRamMb: 8192,
      freeStorageMb: 99999,
      appFilesDir: tmp.path,
    );
    c.refreshInstalled();
    expect(c.installed, isFalse, reason: '目录都没有 → 未安装');

    final dir = Directory('${tmp.path}/voice_models/sensevoice-small');
    await dir.create(recursive: true);
    await File('${dir.path}/.complete').writeAsString('x');
    for (final f in kVoiceModelFiles) {
      // 故意写错大小（1 字节）—— 只有大小全对才算装好
      await File('${dir.path}/${f.name}').writeAsBytes([0]);
    }
    c.refreshInstalled();
    expect(c.installed, isFalse, reason: '文件大小对不上 → 未安装');
  });

  testWidgets('语音识别设置页：模型行、下载按钮在；权限卡已撤（只留设备权限页）',
      (tester) async {
    await usePhoneSurface(tester);
    await tester.pumpWidget(wrap(const VoiceSettingsScreen()));
    await settle(tester, times: 10);
    expect(find.text('SenseVoiceSmall'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    // 2026-10-29 用户定：麦克风权限只在设备权限页有一处，
    // 语音页不放权限卡（组标签「麦克风权限」不应出现）。
    expect(find.text('麦克风权限'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------- 视图选项真生效

  HSession sess(String id, {bool starred = false, int t = 0}) => HSession(
        id: id,
        title: id,
        starred: starred,
        lastActivity: DateTime.fromMillisecondsSinceEpoch(t),
      );

  test('排序：最近更新 = 收藏置顶 + 时间倒序', () {
    final out = sortSessionsForView(
      [sess('a', t: 100), sess('b', t: 300), sess('c', starred: true, t: 50)],
      const ViewOptions(),
    );
    expect(out.map((s) => s.id), ['c', 'b', 'a']);
  });

  test('排序：手动 = 按 manualOrder；未排的新会话在前按最近更新', () {
    final out = sortSessionsForView(
      [sess('a', t: 100), sess('b', t: 300), sess('c', t: 200), sess('d', t: 400)],
      const ViewOptions(
        sorting: SessionSorting.manual,
        manualOrder: ['b', 'a'],
      ),
    );
    // d、c 未排 → 在前（d 时间更新在更前）；b、a 按手动序在后
    expect(out.map((s) => s.id), ['d', 'c', 'b', 'a']);
  });

  test('手动拖动：只动本工作区内的相对顺序，全局表重写', () {
    final w1 = HWorkspace(
      id: 'w1',
      name: 'w1',
      path: '/1',
      sessions: [sess('a'), sess('b'), sess('c')],
    );
    final w2 = HWorkspace(
      id: 'w2',
      name: 'w2',
      path: '/2',
      sessions: [sess('x'), sess('y')],
    );
    const options = ViewOptions(
      sorting: SessionSorting.manual,
      manualOrder: ['a', 'b', 'c', 'x', 'y'],
    );
    // 把 c 拖到 a 之前
    final next = manualOrderAfterMove(
      [w1, w2],
      options,
      workspaceId: 'w1',
      draggedId: 'c',
      targetId: 'a',
      before: true,
    );
    expect(next, ['c', 'a', 'b', 'x', 'y']);
    // 原地拖动（拖到自己后面一位但顺序不变）→ null（不写无谓变更）
    final noop = manualOrderAfterMove(
      [w1, w2],
      options,
      workspaceId: 'w1',
      draggedId: 'a',
      targetId: 'b',
      before: true,
    );
    expect(noop, isNull);
  });

  test('ViewOptions 持久化：手动排序与顺序表往返不丢', () {
    const o = ViewOptions(
      sorting: SessionSorting.manual,
      manualOrder: ['s2', 's1'],
    );
    final back = ViewOptions.fromJson(o.toJson());
    expect(back.sorting, SessionSorting.manual);
    expect(back.manualOrder, ['s2', 's1']);
    // 脏数据不炸
    expect(ViewOptions.fromJson({'manualOrder': 'x'}).manualOrder, isEmpty);
  });

  testWidgets('视图选项抽屉：有「手动排序」，点选关闭后真回调',
      (tester) async {
    await usePhoneSurface(tester);
    ViewOptions? changed;
    await tester.pumpWidget(wrap(WorkspaceDrawer(
      workspaces: const [
        HWorkspace(id: 'w1', name: 'proj', path: '/x', sessions: []),
      ],
      onSelectSession: (workspaceId, sessionId) {},
      onNewSession: (workspaceId) {},
      onOpenSettings: () {},
      viewOptions: const ViewOptions(),
      onViewOptionsChanged: (o) => changed = o,
      searchQuery: '',
      onSearchChanged: (q) {},
    )));
    await settle(tester, times: 10);
    await tester.tap(find.byIcon(CupertinoIcons.slider_horizontal_3));
    await settle(tester, times: 10);
    expect(find.text('手动排序'), findsOneWidget);
    await tester.tap(find.text('手动排序'));
    await settle(tester, times: 5);
    // 点抽屉外关闭 → 关闭即提交
    await tester.tapAt(const Offset(30, 30));
    await settle(tester, times: 10);
    expect(changed?.sorting, SessionSorting.manual);
  });

  // ------------------------------------------------- 引擎准备纯逻辑

  String amMvnFixture() {
    final vals = List.filled(560, '1.5').join(' ');
    return '<AddShift> 1 560 [ \n<LearnRateCoef> 0 0 $vals ]\n'
        '<Rescale> 1 560 [ \n<LearnRateCoef> 0 0 $vals ]\n';
  }

  test('parseCmvnPair：两行各 560 值；维度不对抛错', () {
    final (neg, inv) = parseCmvnPair(amMvnFixture());
    expect(neg.split(',').length, 560);
    expect(inv.split(',').length, 560);
    expect(() => parseCmvnPair('<LearnRateCoef> 0 0 1.0 ]'), throwsFormatException);
  });

  test('voiceSherpaMetadata：17 键齐全，lang_zh=3', () {
    final meta = voiceSherpaMetadata(amMvnFixture());
    expect(meta.length, 17);
    expect(meta['model_type'], 'sense_voice_ctc');
    expect(meta['lang_zh'], '3');
    expect(meta['vocab_size'], '25055');
  });

  test('encodeOnnxMetadataEntries：protobuf 可解回原键值', () {
    final bytes = encodeOnnxMetadataEntries({'k1': 'v1', 'lang_zh': '3'});
    // 迷你解码：只解本函数产出的 field-14 条目序列
    var pos = 0;
    int readVarint() {
      var result = 0;
      var shift = 0;
      while (true) {
        final b = bytes[pos++];
        result |= (b & 0x7F) << shift;
        if (b < 0x80) return result;
        shift += 7;
      }
    }

    final out = <String, String>{};
    while (pos < bytes.length) {
      expect(bytes[pos++], 0x72);
      final len = readVarint();
      final end = pos + len;
      expect(bytes[pos++], 0x0A);
      final klen = readVarint();
      final key = utf8.decode(bytes.sublist(pos, pos + klen));
      pos += klen;
      expect(bytes[pos++], 0x12);
      final vlen = readVarint();
      out[key] = utf8.decode(bytes.sublist(pos, pos + vlen));
      pos += vlen;
      expect(pos, end);
    }
    expect(out, {'k1': 'v1', 'lang_zh': '3'});
  });

  test('tokensTxtFromJson：下标即 id', () {
    expect(tokensTxtFromJson('["<unk>","<s>","▁the"]'),
        '<unk> 0\n<s> 1\n▁the 2\n');
    expect(() => tokensTxtFromJson('{"a":1}'), throwsFormatException);
  });

  test('prepareEngine：小文件端到端（补 metadata + 转词表）', () async {
    final tmp = await Directory.systemTemp.createTemp('voice_prep_');
    addTearDown(() => tmp.delete(recursive: true));
    final dir = Directory('${tmp.path}/voice_models/sensevoice-small');
    await dir.create(recursive: true);
    await File('${dir.path}/tokens.json').writeAsString('["a","b"]');
    await File('${dir.path}/am.mvn').writeAsString(amMvnFixture());
    final raw = List<int>.generate(100, (i) => i);
    await File('${dir.path}/model_quant.onnx').writeAsBytes(raw);

    final c = VoiceModelController.shared();
    c.profile = JevDeviceProfile(
      model: 'test',
      totalRamMb: 8192,
      freeStorageMb: 99999,
      appFilesDir: tmp.path,
    );
    await c.prepareEngine();
    expect(c.prepareError, isNull);
    expect(c.engineReady, isTrue);
    expect(await File('${dir.path}/tokens.txt').readAsString(), 'a 0\nb 1\n');
    final patched = await File('${dir.path}/model_sherpa.onnx').readAsBytes();
    expect(patched.sublist(0, 100), raw, reason: '原文件字节原样打头');
    expect(patched.length, greaterThan(100), reason: '尾部追加了 metadata');
  });

  test('decodeWavPcm16：解析小 WAV（单声道）', () {
    // 造一个 16k 单声道 WAV：4 个采样 [0, 16384, -16384, 32767]
    final samples = [0, 16384, -16384, 32767];
    final data = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    // 按字节拼 44 字节标准头：
    final bytes = BytesBuilder()
      ..add('RIFF'.codeUnits)
      ..add((ByteData(4)..setUint32(0, 36 + data.lengthInBytes, Endian.little))
          .buffer
          .asUint8List())
      ..add('WAVEfmt '.codeUnits)
      ..add((ByteData(4)..setUint32(0, 16, Endian.little)).buffer.asUint8List())
      ..add((ByteData(2)..setUint16(0, 1, Endian.little)).buffer.asUint8List())
      ..add((ByteData(2)..setUint16(0, 1, Endian.little)).buffer.asUint8List())
      ..add(
          (ByteData(4)..setUint32(0, 16000, Endian.little)).buffer.asUint8List())
      ..add(
          (ByteData(4)..setUint32(0, 32000, Endian.little)).buffer.asUint8List())
      ..add((ByteData(2)..setUint16(0, 2, Endian.little)).buffer.asUint8List())
      ..add((ByteData(2)..setUint16(0, 16, Endian.little)).buffer.asUint8List())
      ..add('data'.codeUnits)
      ..add((ByteData(4)..setUint32(0, data.lengthInBytes, Endian.little))
          .buffer
          .asUint8List())
      ..add(data.buffer.asUint8List());
    final (out, rate) = decodeWavPcm16(bytes.toBytes());
    expect(rate, 16000);
    expect(out.length, 4);
    expect(out[1], closeTo(0.5, 0.001));
    expect(out[2], closeTo(-0.5, 0.001));
  });
}
