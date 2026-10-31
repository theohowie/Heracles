// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **流式语音草稿接线：input_bar 订阅 AgentBridge.voicePartials**（task-7 / T0-1d）。
//
// 规格（用户第 8 条）：点麦克风开始录音后，ASR 每 200–300ms 回一段
// **累积全文**（`VoicePartial{sessionId,text,isFinal}`），输入框按录音开始时的
// 锚点就地增长：
// · 只替换草稿段 ⇒ 用户原来的前后缀一字不动、光标不被拽走；
// · final ⇒ 草稿转正式文本（草稿样式消失），光标落在插入段末尾；
// · 取消/失败 ⇒ 恢复录音前原文与选区；
// · 录音中用户手打 ⇒ 草稿落为正式文本，之后迟到的 partial 一律丢弃；
// · 无部分结果（流式不可用/旧包）⇒ 现有「录完再识别」回退不能被破坏。
//
// 本文件只驱动**契约边界**（`AgentBridge.emitVoicePartial` / 假解码器），
// 不 mock 已删除的传输。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/services/voice_input.dart';
import 'package:heracles/services/voice_service.dart';
import 'package:heracles/services/voice_stream.dart';
import 'package:heracles/theme/app_theme.dart';
import 'package:heracles/theme/cupertino_kit.dart';
import 'package:heracles/widgets/input_bar.dart';

/// 假流式解码器（测试注入）：`finish()` 时把最后一次累积文本作为 done 结果
/// 交给 runner —— 走真实「解码 → VoicePartial → UI」路径，不伪造 final。
class _FakeDecoder implements VoiceStreamDecoder {
  final StreamController<VoiceDecodeUpdate> _updates =
      StreamController<VoiceDecodeUpdate>.broadcast();

  /// `finish()` 时要交出的最终累积文本。
  String finishText = '';

  @override
  Stream<VoiceDecodeUpdate> get updates => _updates.stream;

  @override
  Future<void> start() async {}

  @override
  void accept(Uint8List pcm) {}

  @override
  void finish() {
    _updates.add(VoiceDecodeUpdate(finishText, done: true));
  }

  @override
  Future<void> dispose() async {
    if (!_updates.isClosed) await _updates.close();
  }
}

const _sessionId = 'v-wire';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const commandChannel = MethodChannel('heracles/command');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final voice = VoiceModelController.shared();
  final input = VoiceInputController.shared();

  Map<String, Object?> startReply = <String, Object?>{};
  late Directory tmp;
  late TextEditingController ctrl;
  late _FakeDecoder decoder;

  Future<void> seedSparse(String dirPath, String name, int bytes) async {
    await Directory(dirPath).create(recursive: true);
    final raf = await File('$dirPath/$name').open(mode: FileMode.write);
    await raf.truncate(bytes);
    await raf.close();
  }

  /// 内置流式模型「已就绪」：稀疏文件 + `.complete`（只校验存在+字节数）。
  Future<void> seedBundledReady() async {
    final dir = '${tmp.path}/voice_models/$kBundledStreamingDirName';
    await Directory(dir).create(recursive: true);
    for (final f in kBundledStreamingModelFiles) {
      await seedSparse(dir, f.name, f.bytes);
    }
    await File('$dir/.complete').writeAsString(kBundledStreamingMarker);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('voice_wiring_');
    await seedBundledReady();
    decoder = _FakeDecoder();
    startReply = <String, Object?>{'ok': true, 'sessionId': _sessionId};
    voice.profile = JevDeviceProfile(
      model: 'test',
      totalRamMb: 8192,
      freeStorageMb: 99999,
      appFilesDir: tmp.path,
    );
    voice.loaded = true;
    voice.voiceUninstalled = false;
    voice.voiceEnabled = true;
    voice.refreshInstalled();
    input.phase = VoiceInputPhase.idle;
    VoiceInputController.decoderFactoryForTest = (v) => decoder;
    AgentBridge.voiceEventSourceForTest = () => const Stream<dynamic>.empty();

    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      switch (call.method) {
        case 'devicePermissions':
          return <String, String>{'microphone': 'granted'};
        case 'requestPermission':
          return <String, Object?>{'ok': true};
        case 'startVoiceRecord':
          return startReply;
        case 'stopVoiceRecord':
          return <String, Object?>{'ok': true, 'path': '${tmp.path}/none.wav'};
        case 'cancelVoiceRecord':
          return <String, Object?>{'ok': true};
        case 'deviceProfile':
          return <String, Object?>{'ok': false};
      }
      return null;
    });
  });

  tearDown(() async {
    await input.cancelIfRecording();
    messenger.setMockMethodCallHandler(commandChannel, null);
    VoiceInputController.decoderFactoryForTest = null;
    AgentBridge.voiceEventSourceForTest = null;
    input.phase = VoiceInputPhase.idle;
    voice.profile = null;
    voice.loaded = false;
    voice.refreshInstalled();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: buildHeraclesTheme(dark: false),
        builder: (context, inner) => HueScope(
          hue: Hue.forDark(false, 0xFFFF7A45),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: child),
        ),
      );

  Future<void> pumpMicro(WidgetTester tester, [int n = 40]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump();
    }
  }

  Future<void> startRecording(WidgetTester tester) async {
    await tester.tap(find.byIcon(AppIcons.mic));
    await pumpMicro(tester);
    expect(input.phase, VoiceInputPhase.recording,
        reason: '点麦克风后应进入录音态（否则后面的 partial 无从谈起）');
    // 等流式泵就绪（runner.start 完成）。
    for (var i = 0; i < 60 && !input.streamingActive; i++) {
      await tester.pump();
    }
  }

  Future<void> stopRecording(WidgetTester tester) async {
    await tester.tap(find.byIcon(AppIcons.stop));
    for (var i = 0; i < 200 && input.phase != VoiceInputPhase.idle; i++) {
      await tester.pump();
    }
    expect(input.phase, VoiceInputPhase.idle, reason: '停录后应回到 idle');
    // idle 是在上一帧的异步续体里 notify 出来的：再 pump 一帧让「正在识别…」
    // 等依赖 phase 的 UI 真正重建（否则断言看到的是旧树）。
    await tester.pump();
    await tester.pump();
  }

  void emitPartial(String text, {bool isFinal = false}) {
    AgentBridge.emitVoicePartial(
      VoicePartial(
        sessionId: _sessionId,
        text: text,
        isFinal: isFinal,
        seq: 1,
        tsMs: 0,
      ),
    );
  }

  /// 把 runner / toast 里挂着的超时定时器走完（60s 上限/1.5s 首片/3s 收尾兜底
  /// / 2.2s toast 停留），免得测试结束时留下 pending Timer。
  Future<void> flushTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 61));
    // 上面这一跳可能触发 toast（它在同一帧才开始计时）⇒ 再走一跳烧掉它的
    // 2.2s 停留定时器。
    await tester.pump(const Duration(seconds: 5));
  }

  double underlineHeight(WidgetTester tester) =>
      tester.getSize(find.byKey(const Key('voice-draft-underline'))).height;

  testWidgets('① 累积 partial 按锚点增长：前后缀一字不动、光标不被拽走；final 后草稿态消失',
      (tester) async {
    ctrl = TextEditingController(text: '你好，世界')
      ..selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpWidget(wrap(InputBar(onSend: (_) {}, inputController: ctrl)));
    await tester.pump();

    await startRecording(tester);

    emitPartial('今天');
    await pumpMicro(tester, 4);
    expect(ctrl.text, '你好，今天世界', reason: '草稿应插在锚点 3，而不是追加到末尾');
    expect(ctrl.selection.baseOffset, 3, reason: '光标在草稿段之前不应被拽走');

    emitPartial('今天下午');
    await pumpMicro(tester, 4);
    expect(ctrl.text, '你好，今天下午世界');
    expect(ctrl.text.substring(0, 3), '你好，', reason: '用户前缀必须逐字保留');
    expect(ctrl.text.substring(ctrl.text.length - 2), '世界', reason: '用户后缀必须逐字保留');

    // 录音中的轻量提示 + 草稿下划线（不整屏 loading）。
    expect(find.text('正在识别…'), findsOneWidget);
    expect(underlineHeight(tester), greaterThan(0));

    // 停录：final 走真实解码器 done 结果。
    decoder.finishText = '今天下午三点';
    await stopRecording(tester);
    await tester.pump(const Duration(milliseconds: 200));

    expect(ctrl.text, '你好，今天下午三点世界');
    expect(ctrl.selection.baseOffset, 3 + '今天下午三点'.length,
        reason: '提交后光标应落在插入段末尾');
    expect(find.text('正在识别…'), findsNothing, reason: 'final 后「正在识别…」应消失');
    expect(underlineHeight(tester), 0, reason: 'final 后草稿样式应消失');

    await flushTimers(tester);
  });

  testWidgets('② 取消（页面销毁）恢复录音前原文与选区', (tester) async {
    ctrl = TextEditingController(text: '你好，世界')
      ..selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpWidget(wrap(InputBar(onSend: (_) {}, inputController: ctrl)));
    await tester.pump();

    await startRecording(tester);
    emitPartial('今天');
    await pumpMicro(tester, 4);
    expect(ctrl.text, '你好，今天世界');

    // 页面销毁 ⇒ 放弃本次录音：草稿必须清掉、原文与选区恢复。
    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump();

    expect(ctrl.text, '你好，世界', reason: '取消后不得把半成品草稿留在输入框');
    expect(ctrl.selection, const TextSelection.collapsed(offset: 3));

    // 页面销毁后宿主会 cancelIfRecording —— 它在 fake-async 里要真实异步
    // 走完（取消解码器/停录回包），所以放进 runAsync。
    await tester.runAsync(input.cancelIfRecording);
    await flushTimers(tester);
  });

  testWidgets('③ 录音中用户手打 ⇒ 草稿落为正式文本，迟到 partial 不再覆盖', (tester) async {
    ctrl = TextEditingController(text: '你好，世界')
      ..selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpWidget(wrap(InputBar(onSend: (_) {}, inputController: ctrl)));
    await tester.pump();

    await startRecording(tester);
    emitPartial('今天');
    await pumpMicro(tester, 4);
    expect(ctrl.text, '你好，今天世界');

    // 用户接管输入框：手打「天气」。
    ctrl.value = const TextEditingValue(
      text: '你好，今天天气世界',
      selection: TextSelection.collapsed(offset: 6),
    );
    await tester.pump();

    // 迟到的 partial 不得覆盖用户手打内容。
    emitPartial('今天下午三点');
    await pumpMicro(tester, 4);
    expect(ctrl.text, '你好，今天天气世界', reason: '用户手打后，旧 partial 必须丢弃');
    // 草稿段已落为正式文本 ⇒ 草稿样式消失（录音仍在继续，所以「正在识别…」
    // 会等到停录才收 —— 那是录音态提示，不是草稿态）。
    expect(underlineHeight(tester), 0, reason: '用户接管后不应再有草稿样式');

    await stopRecording(tester);
    expect(ctrl.text, '你好，今天天气世界');
    expect(find.text('正在识别…'), findsNothing, reason: '停录后录音态提示应消失');

    await flushTimers(tester);
  });

  testWidgets('④ 流式不可用（旧包不回 sessionId）⇒ 不接草稿、录入文本不被破坏',
      (tester) async {
    startReply = <String, Object?>{'ok': true}; // 旧包：没有 sessionId
    ctrl = TextEditingController(text: 'abc')
      ..selection = const TextSelection.collapsed(offset: 1);
    await tester.pumpWidget(wrap(InputBar(onSend: (_) {}, inputController: ctrl)));
    await tester.pump();

    await tester.tap(find.byIcon(AppIcons.mic));
    await pumpMicro(tester);
    expect(input.phase, VoiceInputPhase.recording);
    expect(input.streamingActive, isFalse, reason: '旧包没有 sessionId ⇒ 只能整段回退');

    // 整段识别路径不会有 partial；停录不得破坏原文。
    await stopRecording(tester);
    expect(ctrl.text, 'abc', reason: '无部分结果的回退路径不得改动输入框内容');
    expect(find.text('正在识别…'), findsNothing);

    await flushTimers(tester);
  });
}
