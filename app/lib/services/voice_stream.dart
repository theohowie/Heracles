/// **流式语音（方案 A）的 Dart 侧**（契约 `docs/INTERFACE.md` §N13）。
///
/// ```text
/// [Kotlin] AudioRecord ~100ms 分片
///    → EventChannel('heracles/voice')  {type:"chunk", sessionId, seq, pcm, sampleRate}
///    → [本文件] VoiceChunkGate 按 seq 丢乱序/重复、按 sessionId 丢旧会话
///    → [独立 isolate] sherpa OnlineRecognizer: acceptWaveform → isReady → decode → getResult
///    → [主 isolate] VoicePartialPacer 节流 200–300ms
///    → AgentBridge.emitVoicePartial(VoicePartial{sessionId,text,isFinal,seq,tsMs})
/// ```
///
/// 三条纪律（§N13.1）：
/// 1. **音频绝不上云**；解码只在设备本机 isolate 内，主 isolate 不做解码/IO。
/// 2. **主 isolate 只做转发/节流/取消**。识别器（含 sherpa 绑定）在 isolate 内初始化。
/// 3. **回退**：流式模型未下载 / 加载失败 / 旧包没有事件流 ⇒ 调用方走
///    现有整段识别（`VoiceAsr.transcribeWav`），行为与今天一致。
///
/// 本文件的纯逻辑（[VoiceChunkGate] / [VoicePartialPacer] / [VoiceStreamRunner]）
/// 都可在测试里注入假解码器与假时钟，**不依赖真模型**。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'agent_bridge.dart';
import 'voice_service.dart';

/// 同一 session 两次 partial 的**最小间隔**（§N13.3：≥200ms）。
const kVoicePartialMinGap = Duration(milliseconds: 200);

/// 尾部 flush 的**最大滞后**（§N13.3：≤300ms）。
const kVoicePartialMaxGap = Duration(milliseconds: 300);

/// 录音硬上限（§N13.1：60 秒，语义与旧路径一致）。
const kVoiceStreamMaxDuration = Duration(seconds: 60);

/// 起录后等第一片的最长时间；等不到 = 旧包/通道没实现 ⇒ 回退。
const kVoiceFirstChunkTimeout = Duration(milliseconds: 1500);

/// Kotlin 分片的采样率（固定 16kHz，契约 §N13.2）。
const kVoiceChunkSampleRate = 16000;

/// 定时器注入点（测试用可控时钟；生产 = `Timer`）。
typedef VoicePaceSchedule = void Function(Duration delay, void Function() action);

// ---------------------------------------------------------------- 平台事件

enum VoiceStreamEventType { chunk, end }

/// Kotlin → Dart 的一条音频事件（`{type:"chunk"/"end", sessionId, seq, pcm, sampleRate}`）。
class VoiceStreamEvent {
  const VoiceStreamEvent.chunk({
    required this.sessionId,
    required this.seq,
    required this.pcm,
    required this.sampleRate,
  }) : type = VoiceStreamEventType.chunk;

  const VoiceStreamEvent.end({required this.sessionId})
      : type = VoiceStreamEventType.end,
        seq = 0,
        pcm = null,
        sampleRate = kVoiceChunkSampleRate;

  final VoiceStreamEventType type;
  final String sessionId;
  final int seq;
  final Uint8List? pcm;
  final int sampleRate;

  /// 解析平台事件；不认识的形状返回 null（**宽松**：新宿主加字段不影响旧 Dart）。
  static VoiceStreamEvent? parse(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    final sid = raw['sessionId'];
    final sessionId = sid is String ? sid : '';
    if (type == 'chunk') {
      final rawPcm = raw['pcm'];
      final Uint8List? pcm;
      if (rawPcm is Uint8List) {
        pcm = rawPcm;
      } else if (rawPcm is List<int>) {
        pcm = Uint8List.fromList(rawPcm);
      } else if (rawPcm is List) {
        pcm = Uint8List.fromList(rawPcm.whereType<int>().toList());
      } else {
        pcm = null;
      }
      if (pcm == null) return null;
      final seq = raw['seq'];
      final rate = raw['sampleRate'];
      return VoiceStreamEvent.chunk(
        sessionId: sessionId,
        seq: seq is int ? seq : -1,
        pcm: pcm,
        sampleRate: rate is int && rate > 0 ? rate : kVoiceChunkSampleRate,
      );
    }
    if (type == 'end') return VoiceStreamEvent.end(sessionId: sessionId);
    return null;
  }

  @override
  String toString() => type == VoiceStreamEventType.chunk
      ? 'VoiceStreamEvent.chunk(session: $sessionId, seq: $seq, '
          'bytes: ${pcm?.length ?? 0})'
      : 'VoiceStreamEvent.end(session: $sessionId)';
}

/// 分片排序门：**按 seq 丢弃乱序/重复片**，旧会话的迟到片整条丢弃。
///
/// 为什么不按 `seq == last + 1` 报错：无线/主线程排队都可能让一片晚到，
/// 流式语音的语义是"少一片继续出草稿"，不是"整段失败"（契约 §N13.2）。
class VoiceChunkGate {
  VoiceChunkGate({this.sessionId});

  /// 当前会话 id（null = 还没定，第一片到达时自取）。
  String? sessionId;

  int _lastSeq = -1;

  int get lastSeq => _lastSeq;

  /// 被丢弃的旧会话事件数 **/** 重复或乱序分片数。
  int droppedStale = 0;
  int droppedDuplicate = 0;

  /// 接受则返回事件；乱序/重复/旧会话返回 null。
  VoiceStreamEvent? accept(VoiceStreamEvent event) {
    final current = sessionId;
    if (event.type == VoiceStreamEventType.end) {
      if (current != null && event.sessionId.isNotEmpty && event.sessionId != current) {
        droppedStale++;
        return null;
      }
      return event;
    }
    if (current != null && event.sessionId != current) {
      droppedStale++;
      return null;
    }
    sessionId ??= event.sessionId;
    if (event.seq <= _lastSeq) {
      droppedDuplicate++;
      return null;
    }
    _lastSeq = event.seq;
    return event;
  }
}

// ---------------------------------------------------------------- 解码器

/// 一次增量解码的结果。
class VoiceDecodeUpdate {
  const VoiceDecodeUpdate(
    this.text, {
    this.endpoint = false,
    this.done = false,
  });

  /// **累积整段草稿**（不是增量片段）。
  final String text;

  /// 静音断句（VAD endpoint，~800ms）—— 该句定稿。
  final bool endpoint;

  /// 输入已收尾（`finish()` 后的最后一次结果）。
  final bool done;

  @override
  String toString() =>
      'VoiceDecodeUpdate("$text", endpoint: $endpoint, done: $done)';
}

/// 增量解码器抽象（生产 = isolate + sherpa；测试 = 假实现）。
abstract class VoiceStreamDecoder {
  /// 加载模型/建好解码器；失败抛异常 ⇒ 调用方回退整段识别。
  Future<void> start();

  /// 塞一片 PCM16 单声道；不得阻塞主 isolate（实现内部排队）。
  void accept(Uint8List pcm);

  /// 结束输入：解码完尾音，最后一次更新带 `done: true`。
  void finish();

  /// 累积草稿 / 断句 / 收尾通知（广播流）。
  Stream<VoiceDecodeUpdate> get updates;

  /// 释放资源（幂等）。
  Future<void> dispose();
}

/// 生产解码器：**独立 isolate** + sherpa-onnx `OnlineRecognizer`。
///
/// `start()` 会等 isolate 把模型加载完（190MB 量级，真机 1–3 秒）；
/// 失败抛 [StateError]（调用方回退整段识别）。所有 PCM 经 `SendPort` 送进
/// isolate，解码结果经 `ReceivePort` 回主 isolate —— 主 isolate 不做解码。
class SherpaVoiceStreamDecoder implements VoiceStreamDecoder {
  SherpaVoiceStreamDecoder({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;

  final StreamController<VoiceDecodeUpdate> _updates =
      StreamController<VoiceDecodeUpdate>.broadcast();
  final Completer<void> _ready = Completer<void>();

  Isolate? _isolate;
  ReceivePort? _replyPort;
  SendPort? _command;
  bool _disposed = false;
  bool _finishRequested = false;

  /// isolate 命令口还没握手完成前先排队的 PCM（最多 200 片 ≈ 20 秒）。
  final List<Uint8List> _pending = [];

  @override
  Stream<VoiceDecodeUpdate> get updates => _updates.stream;

  @override
  Future<void> start() async {
    if (_disposed) throw StateError('解码器已释放');
    final reply = ReceivePort();
    _replyPort = reply;
    reply.listen(_onMessage);
    _isolate = await Isolate.spawn<Map<String, Object?>>(
      _voiceStreamWorker,
      <String, Object?>{
        'reply': reply.sendPort,
        'encoder': encoder,
        'decoder': decoder,
        'joiner': joiner,
        'tokens': tokens,
      },
      debugName: 'heracles-voice-stream-decoder',
    );
    await _ready.future.timeout(const Duration(seconds: 25));
  }

  void _onMessage(dynamic message) {
    if (message is! Map) return;
    switch (message['type']) {
      case 'port':
        final port = message['port'];
        if (port is! SendPort) return;
        _command = port;
        for (final pcm in _pending) {
          _command!.send(pcm);
        }
        _pending.clear();
        if (_finishRequested) _command!.send('finish');
      case 'ready':
        if (!_ready.isCompleted) _ready.complete();
      case 'error':
        final text = message['message'] as String? ?? '流式解码失败';
        final err = StateError(text);
        if (!_ready.isCompleted) {
          _ready.completeError(err);
        } else if (!_updates.isClosed) {
          _updates.addError(err);
        }
      case 'update':
        if (_updates.isClosed) return;
        final text = message['text'];
        _updates.add(
          VoiceDecodeUpdate(
            text is String ? text : '',
            endpoint: message['endpoint'] == true,
            done: message['done'] == true,
          ),
        );
    }
  }

  @override
  void accept(Uint8List pcm) {
    if (_disposed) return;
    final command = _command;
    if (command == null) {
      if (_pending.length < 200) _pending.add(Uint8List.fromList(pcm));
      return;
    }
    command.send(Uint8List.fromList(pcm));
  }

  @override
  void finish() {
    if (_disposed) return;
    _finishRequested = true;
    _command?.send('finish');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _command?.send('dispose');
    // 给 isolate 一点时间自己 free 掉 ffi 内存，再硬杀（防泄漏）。
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _replyPort?.close();
    _replyPort = null;
    if (!_updates.isClosed) await _updates.close();
  }
}

/// isolate 入口（**顶层函数**：`Isolate.spawn` 只认顶层/静态闭包）。
void _voiceStreamWorker(Map<String, Object?> args) {
  final reply = args['reply'] as SendPort;
  final command = ReceivePort();
  reply.send(<String, Object?>{'type': 'port', 'port': command.sendPort});

  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  var committed = '';
  var torn = false;

  void teardown() {
    if (torn) return;
    torn = true;
    try {
      stream?.free();
    } catch (_) {}
    try {
      recognizer?.free();
    } catch (_) {}
    command.close();
  }

  void sendUpdate(String text, {bool endpoint = false, bool done = false}) {
    reply.send(<String, Object?>{
      'type': 'update',
      'text': text,
      'endpoint': endpoint,
      'done': done,
    });
  }

  try {
    sherpa.initBindings();
    recognizer = sherpa.OnlineRecognizer(
      buildStreamingRecognizerConfig(
        encoder: args['encoder'] as String,
        decoder: args['decoder'] as String,
        joiner: args['joiner'] as String,
        tokens: args['tokens'] as String,
      ),
    );
    stream = recognizer.createStream();
    reply.send(<String, Object?>{'type': 'ready'});
  } catch (e) {
    reply.send(<String, Object?>{'type': 'error', 'message': '$e'});
    teardown();
    return;
  }

  void decodeReady() {
    final r = recognizer;
    final s = stream;
    if (r == null || s == null) return;
    while (r.isReady(s)) {
      r.decode(s);
    }
  }

  command.listen((message) {
    if (torn) return;
    if (message is String) {
      if (message == 'finish') {
        try {
          final r = recognizer!;
          final s = stream!;
          s.inputFinished();
          decodeReady();
          final text = committed + r.getResult(s).text;
          sendUpdate(text, endpoint: true, done: true);
        } catch (e) {
          reply.send(<String, Object?>{'type': 'error', 'message': '$e'});
        }
        teardown();
      } else if (message == 'dispose') {
        teardown();
      }
      return;
    }
    if (message is! Uint8List) return;
    try {
      final r = recognizer!;
      final s = stream!;
      s.acceptWaveform(
        samples: _pcm16ToFloat32(message),
        sampleRate: kVoiceChunkSampleRate,
      );
      decodeReady();
      var text = committed + r.getResult(s).text;
      if (r.isEndpoint(s)) {
        // 断句：本句定稿写进 committed，草稿对 UI 是一次 isFinal；
        // 之后新句子继续往同一份累积文本后面接（text 只增不减）。
        committed = text;
        sendUpdate(text, endpoint: true);
        r.reset(s);
      } else {
        sendUpdate(text);
      }
    } catch (e) {
      reply.send(<String, Object?>{'type': 'error', 'message': '$e'});
    }
  });
}

/// PCM16LE 字节 → `[-1, 1]` Float32 采样（ sherpa 的 `acceptWaveform` 口径）。
Float32List _pcm16ToFloat32(Uint8List bytes) {
  final frames = bytes.length ~/ 2;
  final out = Float32List(frames);
  final view = ByteData.sublistView(bytes);
  for (var i = 0; i < frames; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// 流式 zipformer 的 model type。
///
/// ★ **真机教训（2026-10-29，e35e48c6）**：`sherpa-onnx-streaming-zipformer-
/// bilingual-zh-en-2023-02-20` 是 **zipformer v1**，必须写 `'zipformer'`。
/// 写成 `'zipformer2'` 时 sherpa 走 v2 加载路径，日志先报
/// `'query_head_dims' does not exist in the metadata`，17ms 后**整个进程
/// 死亡**（native abort，Dart 侧 try/catch 救不了）。analyze/单测/构建都
/// 发现不了，只有真机能撞出来 —— 别改回 zipformer2。
const kStreamingModelType = 'zipformer';

/// **流式识别器配置**（纯数据构造，不触发 native；单测可锁）。
///
/// 端点规则压到 0.8s（契约 §N13.3：静音 ~800ms 断句）：
/// rule1 = 解码出词后的尾静音，rule2 = 只有 blank 的尾静音。
sherpa.OnlineRecognizerConfig buildStreamingRecognizerConfig({
  required String encoder,
  required String decoder,
  required String joiner,
  required String tokens,
}) {
  return sherpa.OnlineRecognizerConfig(
    model: sherpa.OnlineModelConfig(
      transducer: sherpa.OnlineTransducerModelConfig(
        encoder: encoder,
        decoder: decoder,
        joiner: joiner,
      ),
      tokens: tokens,
      numThreads: 2,
      debug: false,
      modelType: kStreamingModelType,
    ),
    decodingMethod: 'greedy_search',
    enableEndpoint: true,
    rule1MinTrailingSilence: 0.8,
    rule2MinTrailingSilence: 0.8,
    rule3MinUtteranceLength: 20,
  );
}

/// 按 [VoiceModelController] 的流式模型路径建解码器；模型没备好返回 null
/// （调用方据此回退整段识别，不报错）。
VoiceStreamDecoder? createSherpaStreamDecoder(VoiceModelController voice) {
  final encoder = voice.streamingEncoderPath;
  final decoder = voice.streamingDecoderPath;
  final joiner = voice.streamingJoinerPath;
  final tokens = voice.streamingTokensPath;
  if (encoder == null ||
      decoder == null ||
      joiner == null ||
      tokens == null) {
    return null;
  }
  return SherpaVoiceStreamDecoder(
    encoder: encoder,
    decoder: decoder,
    joiner: joiner,
    tokens: tokens,
  );
}

// ---------------------------------------------------------------- 节流

/// **200–300ms 节流器**（契约 §N13.3）。
///
/// · 距上次发出 ≥200ms ⇒ 立即发；
/// · 否则排一次 flush 到「上次 + 200ms」（≤300ms 上限由此保证）；
/// · 同一文本不重发；`isFinal` 立即发、不节流。
class VoicePartialPacer {
  VoicePartialPacer({
    required this.emit,
    VoicePaceSchedule? schedule,
    DateTime Function()? now,
    this.minGap = kVoicePartialMinGap,
    this.maxGap = kVoicePartialMaxGap,
  })  : _schedule = schedule ?? ((delay, action) => Timer(delay, action)),
        _now = now ?? DateTime.now;

  /// `(累积草稿, 是否定稿)`。
  final void Function(String text, bool isFinal) emit;
  final VoicePaceSchedule _schedule;
  final DateTime Function() _now;
  final Duration minGap;
  final Duration maxGap;

  String _latest = '';
  String _lastSent = '';
  bool _hasSent = false;
  DateTime? _lastSentAt;
  bool _timerPending = false;
  bool _cancelled = false;

  /// 最近一次真正发出去的文本（测试/回退填字用）。
  String get lastSentText => _lastSent;

  /// 待发草稿（未发出的最新值）。
  String get pendingText => _latest;

  /// 已取消：之后不再发任何 partial。
  void cancel() {
    _cancelled = true;
  }

  /// 解码器报告新草稿。[text] 与上次发出相同 ⇒ 不重复发。
  ///
  /// 返回 true = 本次已立即发出；false = 已排队/无变化/已取消。
  bool onSubmit(String text) {
    if (_cancelled) return false;
    _latest = text;
    if (_hasSent && text == _lastSent) return false;
    final now = _now();
    final last = _lastSentAt;
    if (last == null || now.difference(last) >= minGap) {
      _send(now, isFinal: false);
      return true;
    }
    _armFlush();
    return false;
  }

  /// 强制立即发（断句/停止/60 秒上限）。`isFinal=true` 不节流。
  void flush({bool isFinal = true}) {
    if (_cancelled) return;
    if (!isFinal && _hasSent && _latest == _lastSent) return;
    _send(_now(), isFinal: isFinal);
  }

  /// 记录「这段文本已经以 isFinal 发过」：让后续 onSubmit 以它为基线
  /// 继续算节流窗口（final 不经过节流，但基线必须对齐，否则下一句会
  /// 立刻重发同一段）。
  void markFinal(String text) {
    _latest = text;
    _lastSent = text;
    _hasSent = true;
    _lastSentAt = _now();
  }

  void _armFlush() {
    if (_timerPending) return;
    _timerPending = true;
    final last = _lastSentAt;
    if (last == null) {
      _schedule(Duration.zero, _fireFlush);
      return;
    }
    var due = last.add(minGap);
    final hardDue = last.add(maxGap);
    if (hardDue.isBefore(due)) due = hardDue;
    var delay = due.difference(_now());
    if (delay.isNegative) delay = Duration.zero;
    _schedule(delay, _fireFlush);
  }

  void _fireFlush() {
    _timerPending = false;
    if (_cancelled) return;
    if (_hasSent && _latest == _lastSent) return;
    // 挂起的 flush 可能早于「上次发出 + 最小间隔」（例如 final 刚把
    // 基线推后）⇒ 再排一次，绝不提前发。
    final last = _lastSentAt;
    if (last != null && _now().difference(last) < minGap) {
      _armFlush();
      return;
    }
    _send(_now(), isFinal: false);
  }

  void _send(DateTime now, {required bool isFinal}) {
    _lastSentAt = now;
    _lastSent = _latest;
    _hasSent = true;
    emit(_latest, isFinal);
  }
}

// ---------------------------------------------------------------- 会话泵

/// 一次流式语音的**编排**：平台事件 → 排序门 → 解码器 → 节流 → VoicePartial。
///
/// 生命周期：
/// ```dart
/// final runner = VoiceStreamRunner(...);
/// await runner.start();      // 加载失败/等不到第一片 ⇒ onUnavailable + 自毁
/// runner.onPlatformEvent(..)// 或由内部订阅 events
/// final text = await runner.stop();  // 结束：等最终结果（带兜底超时）
/// await runner.cancel();     // 取消：立即停发
/// ```
class VoiceStreamRunner {
  VoiceStreamRunner({
    required this.sessionId,
    required this.decoder,
    required this.events,
    required this.emitPartial,
    VoicePaceSchedule? schedule,
    DateTime Function()? now,
    this.maxDuration = kVoiceStreamMaxDuration,
    this.firstEventTimeout = kVoiceFirstChunkTimeout,
    this.finalTimeout = const Duration(seconds: 3),
    this.onTimeout,
    this.onUnavailable,
  })  : _schedule = schedule ?? ((delay, action) => Timer(delay, action)),
        _now = now ?? DateTime.now {
    _pacer = VoicePartialPacer(
      emit: _onPaced,
      schedule: _schedule,
      now: _now,
    );
  }

  final String sessionId;
  final VoiceStreamDecoder decoder;

  /// 平台音频事件流（`heracles/voice`）。
  final Stream<dynamic> events;
  final void Function(VoicePartial partial) emitPartial;
  final VoicePaceSchedule _schedule;
  final DateTime Function() _now;
  final Duration maxDuration;
  final Duration firstEventTimeout;
  final Duration finalTimeout;

  /// 60 秒上限触发：调用方应停录（`stopVoiceRecord`），然后走回退/收尾。
  final void Function()? onTimeout;

  /// 流式不可用（旧包/事件通道报错/等不到第一片）：调用方如实提示并回退。
  final void Function(String reason)? onUnavailable;

  late final VoicePartialPacer _pacer;
  final VoiceChunkGate _gate = VoiceChunkGate();
  final Completer<void> _finalEmitted = Completer<void>();

  StreamSubscription<dynamic>? _eventSub;
  StreamSubscription<VoiceDecodeUpdate>? _decoderSub;

  bool _started = false;
  bool _cancelled = false;
  bool _finishing = false;
  bool _finished = false;
  bool _sawEvent = false;
  bool _unavailableNotified = false;
  bool _finalSent = false;
  int _partialSeq = 0;
  int _endpoints = 0;
  String _text = '';

  /// 当前累积草稿（最近一次解码结果）。
  String get text => _text;

  /// 已发出过 `isFinal`（断句或收尾）。
  bool get emittedFinal => _finalSent;

  /// 是否已判定流式不可用（调用方应回退整段识别）。
  bool get unavailable => _unavailableNotified;

  /// 已发出的 partial 条数（测试/诊断用）。
  int get partialCount => _partialSeq;

  /// 静音断句次数。
  int get endpointCount => _endpoints;

  /// 被丢弃的乱序/重复/旧会话事件数。
  int get droppedChunks => _gate.droppedDuplicate;
  int get droppedStaleEvents => _gate.droppedStale;

  /// 是否已收尾。
  bool get finished => _finished;

  /// 开始：订阅事件流 + 加载解码器 + 武装超时。
  ///
  /// 解码器加载失败会抛异常（调用方 catch 后回退）；事件流错误/等不到
  /// 第一片则**不抛**，走 [onUnavailable] 并由 [unavailable] 反映。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _gate.sessionId = sessionId.isEmpty ? null : sessionId;
    // ★ 先订事件、再加载模型：模型加载（1–3 秒）期间 Kotlin 已经在发片，
    //   订阅晚了就丢开头几片（EventChannel 没有回放）。解码器在 ready 之前
    //   会把片排队（[SherpaVoiceStreamDecoder._pending]）。
    _eventSub = events.listen(
      _onPlatformEvent,
      onError: (Object e) => _notifyUnavailable('流式事件通道不可用：$e'),
    );
    _decoderSub = decoder.updates.listen(
      _onDecodeUpdate,
      onError: (Object e) => _notifyUnavailable('流式解码出错：$e'),
    );
    await decoder.start();
    // 旧包/通道没实现：不报错也不来事件。等不到第一片 ⇒ 回退。
    _schedule(firstEventTimeout, () {
      if (_sawEvent || _finished || _cancelled) return;
      _notifyUnavailable('拿不到音频分片（旧包或事件通道未实现）');
    });
    // 60 秒上限：仍属录音硬约束（§N13.1），到点如实收尾并通知调用方停录。
    _schedule(maxDuration, () {
      if (_finished || _cancelled) return;
      _finishCurrent();
      if (!_finalSent) _emitFinal(_text);
      _completeFinal();
      onTimeout?.call();
    });
  }

  void _onPlatformEvent(dynamic raw) {
    if (_cancelled || _finished) return;
    final event = VoiceStreamEvent.parse(raw);
    if (event == null) return;
    final accepted = _gate.accept(event);
    if (accepted == null) return;
    _sawEvent = true;
    if (accepted.type == VoiceStreamEventType.end) {
      _finishCurrent();
      return;
    }
    final pcm = accepted.pcm;
    if (pcm != null) decoder.accept(pcm);
  }

  void _onDecodeUpdate(VoiceDecodeUpdate update) {
    if (_cancelled || _finished) return;
    final text = update.text;
    if (text.isNotEmpty) _text = text;
    if (update.done) {
      _text = text;
      // 60 秒上限/兜底可能已经发过 final ⇒ 不重复发；最终文本以解码器
      // 的 done 为准（只是不再多发一条 partial）。
      if (!_finalSent) _emitFinal(text);
      _completeFinal();
      _disposeDecoder();
      return;
    }
    if (update.endpoint) {
      // 静音断句：立即发 isFinal（不节流），然后继续听下一句。
      _endpoints++;
      _emitFinal(text);
      return;
    }
    _pacer.onSubmit(text);
  }

  void _onPaced(String text, bool isFinal) {
    if (_cancelled) return;
    if (isFinal) {
      _emitFinal(text);
    } else {
      _emitPartial(text, isFinal: false);
    }
  }

  void _emitPartial(String text, {required bool isFinal}) {
    emitPartial(
      VoicePartial(
        sessionId: sessionId,
        text: text,
        isFinal: isFinal,
        seq: _partialSeq++,
        tsMs: _now().millisecondsSinceEpoch,
      ),
    );
  }

  void _emitFinal(String text) {
    if (_cancelled) return;
    _finalSent = true;
    _pacer.markFinal(text);
    _emitPartial(text, isFinal: true);
  }

  /// 结束录音：等解码器把尾音解完（最终结果经 `done` 更新回来）。
  ///
  /// 兜底：解码器 2 秒内不回调 ⇒ 用当前草稿发 final，别让用户干等。
  Future<String> stop() async {
    if (_cancelled) return _text;
    _finishCurrent();
    try {
      await _finalEmitted.future.timeout(finalTimeout);
    } on TimeoutException {
      if (!_finalSent) _emitFinal(_text);
      _completeFinal();
    }
    _disposeDecoder();
    return _text;
  }

  void _finishCurrent() {
    if (_finishing || _finished) return;
    _finishing = true;
    // 尾部必须尽快 flush：把还没发的最新草稿发出去（非定稿，定稿由 done 给）。
    _pacer.flush(isFinal: false);
    decoder.finish();
    // 解码器不守规矩（永远不回 done）时兜底收尾。
    _schedule(finalTimeout, () {
      if (_finished || _cancelled) return;
      if (!_finalSent) _emitFinal(_text);
      _completeFinal();
      _disposeDecoder();
    });
  }

  /// 取消：**立即停发** partial（已发出的保留，由 UI 决定是否清除）。
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _pacer.cancel();
    await _eventSub?.cancel();
    _eventSub = null;
    await _decoderSub?.cancel();
    _decoderSub = null;
    await decoder.dispose();
    _completeFinal();
  }

  void _completeFinal() {
    _finished = true;
    if (!_finalEmitted.isCompleted) _finalEmitted.complete();
  }

  void _notifyUnavailable(String reason) {
    if (_unavailableNotified || _cancelled) return;
    _unavailableNotified = true;
    onUnavailable?.call(reason);
    unawaited(cancel());
  }

  void _disposeDecoder() {
    unawaited(decoder.dispose());
  }

  /// 释放（幂等，失败不抛）。
  Future<void> dispose() => cancel();
}
