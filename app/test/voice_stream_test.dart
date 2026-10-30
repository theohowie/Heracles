/// **流式语音（方案 A）Dart 侧单测**（task-7，2026-10-29）。
///
/// 契约：`docs/INTERFACE.md` §N13。本文件**不依赖真模型/真通道**：
/// · 解码器 = 假实现（可手动喂累积草稿/断句/收尾）；
/// · 平台事件 = 内存 `StreamController`；
/// · 时钟与定时器 = 可推进的假时间线（节流窗口可精确断言）；
/// · 语音输入降级/回退 = mock `heracles/command` 通道。
///
/// 钉住的行为：
/// 1) 分片乱序/重复按 `seq` 丢弃，累积文本仍单调；
/// 2) 静音断句 ⇒ 立即 `isFinal`（不节流）；
/// 3) 节流窗口：任意 200ms 内 ≤1 条 partial，且尾部 flush 不晚于 300ms；
/// 4) 取消后不再出 partial（含已排队事件的丢弃）；
/// 5) 60 秒上限：到点收尾 + 通知停录 + 不再有新 partial；
/// 6) 流式不可用（旧包无事件流/通道报错/加载失败）⇒ 调用方回退整段识别；
/// 7) 无麦克风权限 / 流式模型未下载 / 旧包无 sessionId ⇒ 降级，不误报失败。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/services/voice_input.dart';
import 'package:heracles/services/voice_service.dart';
import 'package:heracles/services/voice_stream.dart';

// ---------------------------------------------------------------- 假时间线

class _Scheduled {
  _Scheduled(this.due, this.action);

  final DateTime due;
  final void Function() action;
  bool done = false;
}

/// 可推进的假时间线（同时充当 [VoicePaceSchedule]）。
class FakeTimeline {
  FakeTimeline() : now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  DateTime now;
  final List<_Scheduled> _pending = [];

  void schedule(Duration delay, void Function() action) {
    final due = delay.isNegative ? now : now.add(delay);
    _pending.add(_Scheduled(due, action));
  }

  /// 推进 [delta]，按到期时间顺序执行到期回调（执行中可再排新定时器）。
  void advance(Duration delta) {
    final target = now.add(delta);
    while (true) {
      _Scheduled? next;
      for (final p in _pending) {
        if (p.done || p.due.isAfter(target)) continue;
        if (next == null || p.due.isBefore(next.due)) next = p;
      }
      if (next == null) break;
      next.done = true;
      now = next.due;
      next.action();
    }
    now = target;
  }

  void clear() => _pending.clear();
}

// ---------------------------------------------------------------- 假解码器

class FakeDecoder implements VoiceStreamDecoder {
  final StreamController<VoiceDecodeUpdate> _updates =
      StreamController<VoiceDecodeUpdate>.broadcast();

  int startCount = 0;
  int acceptCount = 0;
  int finishCount = 0;
  int disposeCount = 0;
  bool get disposed => disposeCount > 0;

  /// 置非 null ⇒ `start()` 抛出（模拟模型加载失败）。
  Object? startError;

  /// `finish()` 时要吐出的更新（模拟解码尾音后的最终结果）。
  List<VoiceDecodeUpdate> onFinishUpdates = const [];

  /// dispose 时是否关闭 updates 流（默认 true；少数用例置 false 以继续喂事件）。
  bool closeOnDispose = true;

  final List<int> acceptedLengths = [];

  @override
  Stream<VoiceDecodeUpdate> get updates => _updates.stream;

  @override
  Future<void> start() async {
    startCount++;
    final err = startError;
    if (err != null) throw err;
  }

  @override
  void accept(Uint8List pcm) {
    acceptCount++;
    acceptedLengths.add(pcm.length);
  }

  @override
  void finish() {
    finishCount++;
    for (final u in onFinishUpdates) {
      _updates.add(u);
    }
  }

  void emit(String text, {bool endpoint = false, bool done = false}) {
    _updates.add(VoiceDecodeUpdate(text, endpoint: endpoint, done: done));
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    // 有些用例要在"已收尾/已取消"之后继续喂解码结果，验证泵真的不再转发；
    // 那些用例把 closeOnDispose 置 false（否则 broadcast 控制器已关，喂不进去）。
    if (closeOnDispose && !_updates.isClosed) await _updates.close();
  }
}

/// 让 stream 的 listen 回调跑完（微任务/事件循环各让一轮）。
Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Uint8List fakePcm([int length = 320]) => Uint8List(length);

Map<String, Object?> chunkEvent(int seq, {String sessionId = 's1'}) => {
      'type': 'chunk',
      'sessionId': sessionId,
      'seq': seq,
      'pcm': fakePcm(),
      'sampleRate': 16000,
    };

Map<String, Object?> endEvent({String sessionId = 's1'}) => {
      'type': 'end',
      'sessionId': sessionId,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ------------------------------------------------------------ 排序门

  group('VoiceChunkGate：按 seq 丢乱序/重复，旧会话整条丢', () {
    test('乱序 0,2,1,2 ⇒ 接受 0,2；重复/倒退计数', () {
      final gate = VoiceChunkGate(sessionId: 's1');
      final accepted = <int>[];
      for (final seq in [0, 2, 1, 2]) {
        final e = gate.accept(
          VoiceStreamEvent.parse(chunkEvent(seq))!,
        );
        if (e != null) accepted.add(e.seq);
      }
      expect(accepted, [0, 2], reason: '只接受严格递增的 seq');
      expect(gate.droppedDuplicate, 2, reason: 'seq 1 乱序、seq 2 重复');
      expect(gate.lastSeq, 2);
    });

    test('旧会话的 chunk/end 丢弃，不串台', () {
      final gate = VoiceChunkGate(sessionId: 's2');
      expect(gate.accept(VoiceStreamEvent.parse(chunkEvent(0, sessionId: 's1'))!),
          isNull);
      expect(gate.accept(VoiceStreamEvent.parse(endEvent(sessionId: 's1'))!),
          isNull);
      expect(gate.droppedStale, 2);
      expect(gate.lastSeq, -1);
    });

    test('end 事件原样通过（当前会话）', () {
      final gate = VoiceChunkGate(sessionId: 's1');
      final e = gate.accept(VoiceStreamEvent.parse(endEvent())!);
      expect(e, isNotNull);
      expect(e!.type, VoiceStreamEventType.end);
    });

    test('不认识的事件形状返回 null（宽松解析）', () {
      expect(VoiceStreamEvent.parse(null), isNull);
      expect(VoiceStreamEvent.parse(<String, Object?>{'type': 'nope'}), isNull);
      expect(
        VoiceStreamEvent.parse(<String, Object?>{'type': 'chunk', 'seq': 0}),
        isNull,
        reason: '没有 pcm 的 chunk 是坏片',
      );
      // pcm 传成 List<int> 也能收（平台差异容忍）。
      final e = VoiceStreamEvent.parse(<String, Object?>{
        'type': 'chunk',
        'sessionId': 's1',
        'seq': 0,
        'pcm': <int>[1, 2, 3, 4],
      });
      expect(e, isNotNull);
      expect(e!.pcm, hasLength(4));
    });
  });

  // ------------------------------------------------------------ 节流器

  group('VoicePartialPacer：200–300ms 窗口', () {
    test('任意 200ms 内最多 1 条；尾部 flush 不晚于 300ms', () {
      final timeline = FakeTimeline();
      final emitted = <({DateTime at, String text, bool isFinal})>[];
      final pacer = VoicePartialPacer(
        emit: (text, isFinal) =>
            emitted.add((at: timeline.now, text: text, isFinal: isFinal)),
        schedule: timeline.schedule,
        now: () => timeline.now,
      );

      pacer.onSubmit('你'); // t0 立即发
      timeline.advance(const Duration(milliseconds: 100));
      pacer.onSubmit('你好'); // 窗口内，排队
      timeline.advance(const Duration(milliseconds: 50)); // t=150 还不该发
      expect(emitted.length, 1, reason: '150ms 时仍在节流窗口内');

      timeline.advance(const Duration(milliseconds: 50)); // t=200 到点 flush
      expect(emitted.length, 2);
      expect(emitted.last.text, '你好');
      expect(
        emitted.last.at.difference(emitted.first.at),
        greaterThanOrEqualTo(kVoicePartialMinGap),
      );

      // 再次提交：间隔 10ms < 200 ⇒ 排队，到 t≈400 发。
      timeline.advance(const Duration(milliseconds: 10));
      pacer.onSubmit('你好呀');
      timeline.advance(const Duration(milliseconds: 300));
      expect(emitted.length, 3);
      expect(emitted.last.text, '你好呀');

      // 全部相邻间隔 ≥200ms。
      for (var i = 1; i < emitted.length; i++) {
        expect(
          emitted[i].at.difference(emitted[i - 1].at),
          greaterThanOrEqualTo(kVoicePartialMinGap),
          reason: '第 $i 条 partial 距上一条不足 200ms',
        );
      }
      // 数据可用 → 发出 的滞后不超过 maxGap。
      expect(
        emitted[1].at.difference(emitted[0].at),
        lessThanOrEqualTo(kVoicePartialMaxGap),
      );
    });

    test('同一文本不重发；flush(isFinal) 立即发、不节流', () {
      final timeline = FakeTimeline();
      final emitted = <({String text, bool isFinal})>[];
      final pacer = VoicePartialPacer(
        emit: (text, isFinal) => emitted.add((text: text, isFinal: isFinal)),
        schedule: timeline.schedule,
        now: () => timeline.now,
      );
      pacer.onSubmit('甲');
      pacer.onSubmit('甲');
      expect(emitted.length, 1, reason: '重复文本不该重发');

      pacer.flush(); // final 不节流
      expect(emitted.length, 2);
      expect(emitted.last.isFinal, isTrue);
      // final 之后基线对齐：同一文本不再发。
      pacer.onSubmit('甲');
      expect(emitted.length, 2);
    });

    test('cancel 后 onSubmit/flush 都不再发', () {
      final timeline = FakeTimeline();
      final emitted = <String>[];
      final pacer = VoicePartialPacer(
        emit: (text, _) => emitted.add(text),
        schedule: timeline.schedule,
        now: () => timeline.now,
      );
      pacer.onSubmit('甲');
      pacer.cancel();
      pacer.onSubmit('甲乙');
      pacer.flush();
      timeline.advance(const Duration(seconds: 1));
      expect(emitted, ['甲']);
    });
  });

  // ------------------------------------------------------------ 会话泵

  group('VoiceStreamRunner：累积/节流/断句', () {
    late FakeTimeline timeline;
    late FakeDecoder decoder;
    late StreamController<dynamic> events;
    late List<VoicePartial> partials;
    late List<String> unavailable;
    var timeouts = 0;

    VoiceStreamRunner build({String sessionId = 's1'}) => VoiceStreamRunner(
          sessionId: sessionId,
          decoder: decoder,
          events: events.stream,
          emitPartial: partials.add,
          schedule: timeline.schedule,
          now: () => timeline.now,
          onTimeout: () => timeouts++,
          onUnavailable: unavailable.add,
        );

    setUp(() {
      timeline = FakeTimeline();
      decoder = FakeDecoder();
      events = StreamController<dynamic>.broadcast();
      partials = <VoicePartial>[];
      unavailable = <String>[];
      timeouts = 0;
    });

    tearDown(() {
      timeline.clear();
      if (!events.isClosed) events.close();
    });

    test('分片乱序/重复按 seq 丢弃；累积草稿单调增长', () async {
      final runner = build();
      await runner.start();

      // 乱序 + 重复：只有 seq 0 / 2 会进解码器。
      events.add(chunkEvent(0));
      events.add(chunkEvent(2));
      events.add(chunkEvent(1));
      events.add(chunkEvent(2));
      await settle();
      expect(decoder.acceptCount, 2);
      expect(runner.droppedChunks, 2);

      decoder.emit('你');
      await settle();
      expect(partials.single.text, '你');
      expect(partials.single.isFinal, isFalse);
      expect(partials.single.seq, 0);
      expect(
        partials.single.tsMs,
        timeline.now.millisecondsSinceEpoch,
      );

      timeline.advance(const Duration(milliseconds: 100));
      decoder.emit('你好');
      await settle();
      expect(partials.length, 1, reason: '窗口内不立即发');

      timeline.advance(const Duration(milliseconds: 300));
      await settle();
      expect(partials.length, 2);
      expect(partials.last.text, '你好');
      // 单调：后一条以前一条为前缀（累积草稿只增不减）。
      for (var i = 1; i < partials.length; i++) {
        expect(
          partials[i].text.startsWith(partials[i - 1].text),
          isTrue,
          reason: '累积草稿出现回退：${partials.map((p) => p.text).toList()}',
        );
        expect(partials[i].seq, greaterThan(partials[i - 1].seq));
      }
      await runner.dispose();
    });

    test('静音断句 ⇒ 立即 isFinal（不节流），随后继续累积', () async {
      final runner = build();
      await runner.start();
      decoder.emit('你好');
      await settle();
      expect(partials.length, 1);

      // 10ms 后断句：isFinal 立即发，不等 200ms 窗口。
      timeline.advance(const Duration(milliseconds: 10));
      decoder.emit('你好。', endpoint: true);
      await settle();
      expect(partials.length, 2);
      expect(partials.last.isFinal, isTrue);
      expect(partials.last.text, '你好。');
      expect(runner.endpointCount, 1);

      // 断句后新句子继续累积（同一会话仍活跃）。
      timeline.advance(const Duration(milliseconds: 250));
      decoder.emit('你好。今天');
      await settle();
      expect(partials.length, 3);
      expect(partials.last.isFinal, isFalse);
      expect(partials.last.text, '你好。今天');
      expect(runner.text, '你好。今天');
      await runner.dispose();
    });

    test('空文本的静音端点**不发** partial（否则 UI 被 chars=0 final 刷屏）', () async {
      final runner = build();
      await runner.start();
      // 先给一片，避免 1.5s "等不到第一片"回退抢先触发。
      events.add(chunkEvent(0));
      await settle();
      // 真机实测过：没人说话时 VAD 每秒报一次 endpoint，text 为空。
      for (var i = 0; i < 5; i++) {
        timeline.advance(const Duration(seconds: 1));
        decoder.emit('', endpoint: true);
        await settle();
      }
      expect(partials, isEmpty, reason: '空断句不得产生 partial');
      expect(runner.endpointCount, 5, reason: '端点本身仍计数（诊断用）');
      // 真有字时才断句。
      decoder.emit('你好', endpoint: true);
      await settle();
      expect(partials.single.isFinal, isTrue);
      expect(partials.single.text, '你好');
      await runner.dispose();
    });

    test('同一文本的静音端点只发一次 final（真机 VAD 每秒重复报）', () async {
      final runner = build();
      await runner.start();
      events.add(chunkEvent(0));
      await settle();
      decoder.emit('你好');
      await settle();
      // 有字 ⇒ 断句一次。
      decoder.emit('你好', endpoint: true);
      await settle();
      expect(partials.where((p) => p.isFinal), hasLength(1));
      // 接着每秒重复同一文本的端点 ⇒ 不得再发 final。
      for (var i = 0; i < 4; i++) {
        timeline.advance(const Duration(seconds: 1));
        decoder.emit('你好', endpoint: true);
        await settle();
      }
      expect(
        partials.where((p) => p.isFinal),
        hasLength(1),
        reason: '文本没变时不得重复发 final（真机上会每秒一条）',
      );
      expect(runner.endpointCount, 5);
      // 真有新文本才再定稿。
      timeline.advance(const Duration(milliseconds: 300));
      decoder.emit('你好世界', endpoint: true);
      await settle();
      expect(partials.where((p) => p.isFinal), hasLength(2));
      expect(partials.last.text, '你好世界');
      await runner.dispose();
    });

    test('end 事件 ⇒ 解码收尾后发最终结果并关流', () async {
      final runner = build();
      decoder.closeOnDispose = false; // 收尾后还要喂一条"迟到结果"验证被忽略
      await runner.start();
      decoder.onFinishUpdates = const [
        VoiceDecodeUpdate('你好世界', endpoint: true, done: true),
      ];
      decoder.emit('你好');
      await settle();
      expect(partials.length, 1);

      events.add(endEvent());
      await settle();
      expect(decoder.finishCount, 1);

      final text = await runner.stop();
      expect(text, '你好世界');
      expect(partials.last.isFinal, isTrue);
      expect(partials.last.text, '你好世界');
      expect(runner.finished, isTrue);
      expect(runner.emittedFinal, isTrue);
      // 收尾后不再接受任何 partial。
      decoder.emit('迟到的结果');
      await settle();
      expect(partials.last.text, '你好世界');
      await runner.dispose();
    });

    test('取消后不再出 partial，也不再喂解码器', () async {
      final runner = build();
      decoder.closeOnDispose = false; // 取消后继续喂，验证确实被忽略
      await runner.start();
      decoder.emit('你');
      await settle();
      expect(partials.length, 1);

      await runner.cancel();
      expect(decoder.disposed, isTrue);
      final acceptedBefore = decoder.acceptCount;
      decoder.emit('你好');
      events.add(chunkEvent(3));
      timeline.advance(const Duration(seconds: 1)); // 若还有排队 flush 会被放出来
      await settle();
      expect(partials.length, 1, reason: '取消后不得再发 partial');
      expect(decoder.acceptCount, acceptedBefore, reason: '取消后不得再喂解码器');
      await runner.dispose();
    });

    test('60 秒上限：到点收尾 + 通知停录 + 不再有新 partial', () async {
      final runner = build();
      await runner.start();
      // 先给一片，避免 1.5s 的"等不到第一片"回退抢先触发（旧包判定）。
      events.add(chunkEvent(0));
      await settle();
      decoder.emit('你好');
      await settle();

      timeline.advance(const Duration(seconds: 59));
      expect(timeouts, 0, reason: '59 秒不该触发上限');
      expect(runner.finished, isFalse);

      timeline.advance(const Duration(milliseconds: 1200)); // t=60.2s
      expect(timeouts, 1, reason: '60 秒必须触发一次停录');
      expect(runner.finished, isTrue);
      expect(partials.last.isFinal, isTrue, reason: '上限到点要有最终结果');
      final count = partials.length;

      decoder.emit('上限之后不该再有');
      await settle();
      expect(partials.length, count);
      await runner.dispose();
    });

    test('事件流报错（旧包/通道未实现）⇒ onUnavailable 且不再出 partial', () async {
      final runner = build();
      await runner.start();
      events.addError(StateError('MissingPluginException(heracles/voice)'));
      await settle();
      expect(unavailable, hasLength(1));
      expect(runner.unavailable, isTrue);
      expect(partials, isEmpty);
      await runner.dispose();
    });

    test('等不到第一片（旧包不报错也不发）⇒ 1.5 秒后判不可用', () async {
      final runner = build();
      await runner.start();
      expect(unavailable, isEmpty);
      timeline.advance(const Duration(milliseconds: 1499));
      expect(unavailable, isEmpty);
      timeline.advance(const Duration(milliseconds: 2));
      expect(unavailable, hasLength(1));
      expect(runner.unavailable, isTrue);
      await runner.dispose();
    });

    test('第一片到了就不判不可用', () async {
      final runner = build();
      await runner.start();
      events.add(chunkEvent(0));
      await settle();
      timeline.advance(const Duration(seconds: 5));
      expect(unavailable, isEmpty);
      await runner.dispose();
    });

    test('解码器加载失败 ⇒ start 抛出（调用方回退整段识别）', () async {
      decoder.startError = StateError('模型加载失败');
      final runner = build();
      await expectLater(runner.start(), throwsStateError);
      await runner.dispose();
      expect(partials, isEmpty);
    });
  });

  // -------------------------------------------------- 识别器配置（回归）

  group('buildStreamingRecognizerConfig：真机崩溃回归', () {
    test('modelType 必须是 zipformer v1（写成 zipformer2 会 native abort）', () {
      final cfg = buildStreamingRecognizerConfig(
        encoder: '/m/encoder.int8.onnx',
        decoder: '/m/decoder.onnx',
        joiner: '/m/joiner.int8.onnx',
        tokens: '/m/tokens.txt',
      );
      // ★ 真机 e35e48c6 实测：'zipformer2' 会报
      //   "'query_head_dims' does not exist in the metadata" 并让进程死亡。
      expect(cfg.model.modelType, 'zipformer');
      expect(cfg.model.modelType, isNot('zipformer2'));
    });

    test('三件套路径 / 词表 / 解码方式 / 端点规则逐项对上', () {
      final cfg = buildStreamingRecognizerConfig(
        encoder: 'e',
        decoder: 'd',
        joiner: 'j',
        tokens: 't',
      );
      expect(cfg.model.transducer.encoder, 'e');
      expect(cfg.model.transducer.decoder, 'd');
      expect(cfg.model.transducer.joiner, 'j');
      expect(cfg.model.tokens, 't');
      expect(cfg.decodingMethod, 'greedy_search');
      expect(cfg.enableEndpoint, isTrue);
      // 契约 §N13.3：静音 ~800ms 断句。
      expect(cfg.rule1MinTrailingSilence, 0.8);
      expect(cfg.rule2MinTrailingSilence, 0.8);
    });
  });

  // ---------------------------------------------------- AgentBridge 接线

  group('AgentBridge：voicePartials / 事件源注入', () {
    test('事件源注入生效；emitVoicePartial 广播且可被监听', () async {
      final controller = StreamController<dynamic>.broadcast();
      AgentBridge.voiceEventSourceForTest = () => controller.stream;
      addTearDown(() {
        AgentBridge.voiceEventSourceForTest = null;
        controller.close();
      });

      final events = <dynamic>[];
      final sub = AgentBridge().voiceAudioEvents().listen(events.add);
      addTearDown(sub.cancel);
      controller.add(chunkEvent(0));
      await settle();
      expect(events, hasLength(1));

      const partial = VoicePartial(
        sessionId: 's1',
        text: '你好',
        isFinal: false,
        seq: 0,
        tsMs: 1,
      );
      final got = <VoicePartial>[];
      final sub2 = AgentBridge.voicePartials.listen(got.add);
      addTearDown(sub2.cancel);
      await settle();
      expect(AgentBridge.hasVoicePartialListener, isTrue);
      AgentBridge.emitVoicePartial(partial);
      await settle();
      expect(got, [partial]);
    });
  });

  // -------------------------------------------------- VoiceInputController

  group('VoiceInputController：降级与回退（mock 通道）', () {
    const commandChannel = MethodChannel('heracles/command');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    final toasts = <String>[];
    var microphone = 'granted';
    var startReply = <String, Object?>{'ok': true, 'sessionId': 'v1'};

    final voice = VoiceModelController.shared();

    /// 临时模型根目录（只造**字节数**、不写内容：`refreshInstalled` 只查
    /// 存在 + 长度，不需要真权重）。
    late Directory modelRoot;

    Future<void> seedFile(String dirPath, String name, int bytes) async {
      final raf = await File('$dirPath/$name').open(mode: FileMode.write);
      await raf.truncate(bytes);
      await raf.close();
    }

    Future<void> seedSenseVoice(String root) async {
      final dir = '$root/voice_models/sensevoice-small';
      await Directory(dir).create(recursive: true);
      await seedFile(dir, 'model_quant.onnx', 241216270);
      await seedFile(dir, 'tokens.json', 352064);
      await seedFile(dir, 'am.mvn', 11203);
      await seedFile(dir, 'config.yaml', 1855);
      // 引擎产物：补完 metadata 的模型必须比裸模型大（现有判定口径）。
      await seedFile(dir, kVoiceSherpaModelName, 241216270 + 11000);
      await seedFile(dir, kVoiceTokensTxtName, 100);
      await File('$dir/.complete').writeAsString('sensevoice-small-onnx');
    }

    Future<void> seedStreaming(String root) async {
      final dir = '$root/voice_models/$kStreamingVoiceDirName';
      await Directory(dir).create(recursive: true);
      for (final f in kStreamingVoiceModelFiles) {
        await seedFile(dir, f.name, f.bytes);
      }
      await File('$dir/.complete').writeAsString(kStreamingVoiceMarker);
    }

    String streamingMarkerPath() =>
        '${modelRoot.path}/voice_models/$kStreamingVoiceDirName/.complete';

    setUpAll(() async {
      messenger.setMockMethodCallHandler(commandChannel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'devicePermissions':
            return <String, String>{'microphone': microphone};
          case 'requestPermission':
            return <String, Object?>{'ok': true};
          case 'startVoiceRecord':
            return startReply;
          case 'stopVoiceRecord':
            return <String, Object?>{'ok': false, 'error': '测试不走到识别'};
          case 'cancelVoiceRecord':
            return <String, Object?>{'ok': true};
          case 'deviceProfile':
            return <String, Object?>{'ok': false};
        }
        return null;
      });
      modelRoot = await Directory.systemTemp.createTemp('voice_stream_');
      await seedSenseVoice(modelRoot.path);
      await seedStreaming(modelRoot.path);
      // B1（2026-10-30）：内置 14M 模型现在会真的存在，本文件只想测"回退/
      // 降级"，所以把内置资产加载器替换成**必然失败**的假加载器（不会读
      // 24MB 真资产）：`ensureStreamingReady()` 立即失败 ⇒ 走整段回退。
      VoiceModelController.bundledAssetLoaderForTest =
          (String assetKey) async => throw StateError('测试不读真内置资产');
    });

    tearDownAll(() async {
      messenger.setMockMethodCallHandler(commandChannel, null);
      await VoiceInputController.shared().cancelIfRecording();
      VoiceModelController.bundledAssetLoaderForTest = null;
      voice.loaded = false;
      voice.installed = false;
      voice.engineReady = false;
      voice.bundledStreamingReady = false;
      voice.bundledStreamingError = null;
      voice.streamingInstalled = false;
      voice.profile = null;
      if (modelRoot.existsSync()) await modelRoot.delete(recursive: true);
    });

    setUp(() {
      calls.clear();
      toasts.clear();
      microphone = 'granted';
      startReply = <String, Object?>{'ok': true, 'sessionId': 'v1'};
      // 确保两组模型目录/完成标记都在（上一个用例可能临时挪走过）。
      final marker = File(streamingMarkerPath());
      if (!marker.existsSync()) {
        marker.writeAsStringSync(kStreamingVoiceMarker);
      }
      // 内置模型默认"不可解压"（测试不读 24MB 真资产）；个别用例自行覆盖。
      VoiceModelController.bundledModelFilesForTest = null;
      VoiceModelController.bundledAssetDirForTest = null;
      VoiceModelController.bundledAssetLoaderForTest =
          (String assetKey) async => throw StateError('测试不读真内置资产');
      VoiceInputController.decoderFactoryForTest = null;
      // 上一个用例若解压过内置模型，清掉（模拟"内置还没解压"的冷开）。
      final bundledDir = Directory(
        '${modelRoot.path}/voice_models/$kBundledStreamingDirName',
      );
      if (bundledDir.existsSync()) bundledDir.deleteSync(recursive: true);
      voice.loaded = true;
      voice.bundledStreamingReady = false;
      voice.bundledStreamingError = null;
      voice.profile = JevDeviceProfile(
        model: 'test',
        totalRamMb: 8192,
        freeStorageMb: 99999,
        appFilesDir: modelRoot.path,
      );
      voice.refreshInstalled();
    });

    test('老双语模型在、内置未解压 ⇒ 点麦克风仍先解压内置模型（默认内置）', () async {
      // 老模型完整已在 setUp 里 seed（streamingInstalled == true）。
      expect(voice.streamingInstalled, isTrue);
      expect(voice.bundledStreamingReady, isFalse);
      // 注入"小号内置资产 + 必失败的解码器"：这条只验"解压是否被尝试/完成"，
      // 绝不在 flutter_tester 里起真 isolate / 真模型。
      VoiceModelController.bundledModelFilesForTest = const <VoiceModelFile>[
        VoiceModelFile('encoder.onnx', 4),
        VoiceModelFile('decoder.onnx', 2),
      ];
      VoiceModelController.bundledAssetDirForTest = 'fake/assets';
      VoiceModelController.bundledAssetLoaderForTest =
          (String assetKey) async =>
              Uint8List(assetKey.endsWith('encoder.onnx') ? 4 : 2);
      VoiceInputController.decoderFactoryForTest = (voice) =>
          FakeDecoder()..startError = StateError('测试注入：解码器加载失败');

      final target = TextEditingController();
      addTearDown(target.dispose);
      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );
      expect(
        voice.bundledStreamingReady,
        isTrue,
        reason: '即使老双语模型在，也要把内置 14M 备好（B1：默认用内置）',
      );
      // 解码器加载失败 ⇒ 不崩，如实回退（本用例的 decoder 是注入的必失败假件）。
      expect(VoiceInputController.shared().streamingActive, isFalse);
      expect(
        toasts.any((t) => t.contains('流式不可用，用整段识别')),
        isTrue,
        reason: '应如实提示回退；实际 toasts=$toasts',
      );
      await VoiceInputController.shared().cancelIfRecording();
    });

    test('无麦克风权限 ⇒ 拒绝开录并提示（不启动流式/不调 start）', () async {
      microphone = 'denied';
      final target = TextEditingController();
      addTearDown(target.dispose);
      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );
      expect(calls.contains('startVoiceRecord'), isFalse);
      expect(
        toasts,
        isNotEmpty,
        reason: '至少要有提示；实际 toasts=$toasts calls=$calls',
      );
      expect(calls.contains('requestPermission'), isTrue);
      expect(toasts.single, contains('麦克风权限'));
      expect(VoiceInputController.shared().streamingActive, isFalse);
    });

    test('流式模型未下载 ⇒ 回退整段识别（如实提示，不报失败）', () async {
      // 模拟"流式模型没下完"：文件在但缺 `.complete`（现有安装判定口径）。
      File(streamingMarkerPath()).deleteSync();
      voice.refreshInstalled();
      expect(voice.streamingInstalled, isFalse);
      expect(voice.bundledStreamingError, isNull, reason: '还没尝试解压内置模型');
      final target = TextEditingController();
      addTearDown(target.dispose);
      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );
      expect(VoiceInputController.shared().recording, isTrue);
      expect(VoiceInputController.shared().streamingActive, isFalse);
      expect(toasts.single, contains('流式不可用，用整段识别'));
      // ★ B1：不可用时**必须真的去试过内置模型解压**（失败可重试），
      // 而不是直接放弃流式（老实现的"下载前置"就是这条的根因）。
      expect(
        voice.bundledStreamingError,
        isNotNull,
        reason: '点麦克风时应先尝试 ensureStreamingReady()',
      );
      await VoiceInputController.shared().cancelIfRecording();
    });

    test('外部删掉流式模型、缓存还停在"已装" ⇒ 点麦克风重新看磁盘并回退', () async {
      expect(voice.streamingInstalled, isTrue, reason: 'setUp 里两组模型都完整');
      File(streamingMarkerPath()).deleteSync();
      // 缓存没刷新过：此时字段仍是 true（就是这条要防的"吃缓存"）。
      expect(voice.streamingInstalled, isTrue);
      final target = TextEditingController();
      addTearDown(target.dispose);
      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );
      expect(VoiceInputController.shared().streamingActive, isFalse);
      expect(toasts.single, contains('流式不可用，用整段识别'));
      // 点一次麦克风就把缓存纠正过来（不是只在本地临时判一下）。
      expect(voice.streamingInstalled, isFalse, reason: '点麦克风后缓存必须刷新');
      await VoiceInputController.shared().cancelIfRecording();
    });

    test('旧包 start 不回 sessionId ⇒ 回退整段识别', () async {
      voice.streamingInstalled = true;
      startReply = <String, Object?>{'ok': true}; // 旧包：没有 sessionId
      final target = TextEditingController();
      addTearDown(target.dispose);
      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );
      expect(VoiceInputController.shared().streamingActive, isFalse);
      expect(toasts.single, contains('流式不可用，用整段识别'));
      await VoiceInputController.shared().cancelIfRecording();
    });

    test('录音失败（ok:false）原样报错，不进入流式', () async {
      startReply = <String, Object?>{'ok': false, 'error': '麦克风被占用'};
      final target = TextEditingController();
      addTearDown(target.dispose);
      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );
      expect(toasts.single, contains('麦克风被占用'));
      expect(VoiceInputController.shared().streamingActive, isFalse);
    });
  });
}
