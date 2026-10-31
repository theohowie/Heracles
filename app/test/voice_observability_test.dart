/// **语音可观测 + 防双写（T0-3）单测**（task-26，2026-10-31）。
///
/// 钉住的行为：
/// 1) 内置模型解压失败：**自动重试一次**（attempts=2、资产被读两轮），
///    并把**人话原因**暴露在 `bundledStreamingError` / `lastEnsureErrorCode`（notify）；
/// 2) 解压进度（`bundledStreamingProgress`）在过程中上报、结束后归 null；
/// 3) 前端订阅了 `AgentBridge.voicePartials` ⇒ `VoiceInputController`
///    **不得再二次插入 final**（防双写）；没订阅时才代填（保证无 UI 时不回归）。
///
/// 全部假通道/假解码器/假资产，不依赖真模型与网络；日志不涉及识别正文。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:heracles/services/voice_input.dart';
import 'package:heracles/services/voice_service.dart';
import 'package:heracles/services/voice_stream.dart';

/// 假资产加载器（可注入失败 + 计数）。
class FakeAssetLoader {
  FakeAssetLoader(this.sizes, {this.delay = Duration.zero});

  final Map<String, int> sizes;
  Duration delay;
  bool fail = false;
  final Map<String, int> calls = {};

  int get totalCalls => calls.values.fold(0, (a, b) => a + b);

  Future<Uint8List> load(String assetKey) async {
    calls[assetKey] = (calls[assetKey] ?? 0) + 1;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('资产读取失败（测试注入）');
    final name = assetKey.split('/').last;
    final size = sizes[name];
    if (size == null) throw StateError('没有这个资产：$assetKey');
    return Uint8List(size);
  }
}

/// 假流式解码器：start 给一段草稿，finish 给最终结果（走 runner 完整收尾）。
class FakeStreamDecoder implements VoiceStreamDecoder {
  final StreamController<VoiceDecodeUpdate> _updates =
      StreamController<VoiceDecodeUpdate>.broadcast();

  @override
  Stream<VoiceDecodeUpdate> get updates => _updates.stream;

  @override
  Future<void> start() async {
    scheduleMicrotask(() => _updates.add(const VoiceDecodeUpdate('你好')));
  }

  @override
  void accept(Uint8List pcm) {}

  @override
  void finish() {
    _updates.add(const VoiceDecodeUpdate('你好世界', endpoint: true, done: true));
  }

  @override
  Future<void> dispose() async {
    if (!_updates.isClosed) await _updates.close();
  }
}

const _fakeAssetDir = 'fake/assets';
const _fakeFiles = <VoiceModelFile>[
  VoiceModelFile('encoder.onnx', 8),
  VoiceModelFile('decoder.onnx', 4),
  VoiceModelFile('joiner.onnx', 3),
  VoiceModelFile('tokens.txt', 2),
];
const _fakeSizes = {
  'encoder.onnx': 8,
  'decoder.onnx': 4,
  'joiner.onnx': 3,
  'tokens.txt': 2,
};

Future<void> seedBundled(String root, FakeAssetLoader loader) async {
  await extractBundledModel(
    dir: '$root/voice_models/$kBundledStreamingDirName',
    files: _fakeFiles,
    completeMarker: kBundledStreamingMarker,
    assetDir: _fakeAssetDir,
    loadAsset: loader.load,
  );
  loader.calls.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const commandChannel = MethodChannel('heracles/command');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final voice = VoiceModelController.shared();
  final toasts = <String>[];
  final commandCalls = <String>[];

  late Directory tmp;
  late String root;
  late FakeAssetLoader loader;
  late StreamController<dynamic> events;

  setUpAll(() {
    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      commandCalls.add(call.method);
      switch (call.method) {
        case 'devicePermissions':
          return <String, String>{'microphone': 'granted'};
        case 'startVoiceRecord':
          return <String, Object?>{'ok': true, 'sessionId': 'v1'};
        case 'stopVoiceRecord':
          return <String, Object?>{'ok': true, 'path': '/nonexistent/test.wav'};
        case 'cancelVoiceRecord':
          return <String, Object?>{'ok': true};
        case 'deviceProfile':
          return <String, Object?>{'ok': false};
      }
      return null;
    });
  });

  tearDownAll(() {
    messenger.setMockMethodCallHandler(commandChannel, null);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    toasts.clear();
    commandCalls.clear();
    tmp = await Directory.systemTemp.createTemp('voice_observability_');
    root = tmp.path;
    loader = FakeAssetLoader(_fakeSizes);
    VoiceModelController.bundledModelFilesForTest = _fakeFiles;
    VoiceModelController.bundledAssetDirForTest = _fakeAssetDir;
    VoiceModelController.bundledAssetLoaderForTest = loader.load;
    VoiceInputController.decoderFactoryForTest = null;
    events = StreamController<dynamic>.broadcast();
    AgentBridge.voiceEventSourceForTest = () => events.stream;

    voice.profile = JevDeviceProfile(
      model: 'test',
      totalRamMb: 8192,
      freeStorageMb: 99999,
      appFilesDir: root,
    );
    voice.loaded = true;
    voice.voiceEnabled = true;
    voice.voiceUninstalled = false;
    voice.installed = false;
    voice.engineReady = false;
    voice.bundledStreamingReady = false;
    voice.streamingInstalled = false;
    voice.bundledStreamingError = null;
    voice.bundledStreamingProgress = null;
    voice.lastEnsureAttempts = 0;
    voice.lastEnsureErrorCode = null;
  });

  tearDown(() async {
    VoiceModelController.bundledModelFilesForTest = null;
    VoiceModelController.bundledAssetDirForTest = null;
    VoiceModelController.bundledAssetLoaderForTest = null;
    VoiceInputController.decoderFactoryForTest = null;
    AgentBridge.voiceEventSourceForTest = null;
    if (!events.isClosed) await events.close();
    voice.profile = null;
    voice.loaded = false;
    voice.bundledStreamingReady = false;
    voice.streamingInstalled = false;
    voice.bundledStreamingError = null;
    voice.bundledStreamingProgress = null;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('可观测：解压失败原因 + 自动重试一次', () {
    test('失败：attempts=2（资产读两轮）、人话原因可读、进度归 null、notify 有通知', () async {
      loader.fail = true;
      var notified = 0;
      void listener() => notified++;
      voice.addListener(listener);
      addTearDown(() => voice.removeListener(listener));

      // 让进度/错误有明确的初始态可断言。
      expect(voice.bundledStreamingProgress, isNull);

      final result = await voice.ensureStreamingReady();

      expect(result.ok, isFalse);
      expect(result.attempts, 2, reason: '失败必须自动重试一次（共 2 次尝试）');
      expect(voice.lastEnsureAttempts, 2);
      expect(result.errorCode, isNotNull);
      expect(result.errorCode, isNot(kVoiceUninstalledError));
      expect(voice.bundledStreamingError, isNotNull);
      expect(voice.bundledStreamingError, contains('尝试 2/2'));
      // 第一轮在第一个文件就抛错；重试一轮同样第一个文件抛错 ⇒ 共 2 次读取。
      expect(loader.totalCalls, 2, reason: '两轮尝试各读一次第一个文件');
      expect(voice.bundledStreamingReady, isFalse);
      expect(voice.bundledStreamingProgress, isNull, reason: '结束后进度归 null');
      expect(notified, greaterThan(0), reason: '错误/进度必须 notify 出去');
    });

    test('成功：进度曾上报（>0）且结束后归 null，失败原因清空', () async {
      final progressSamples = <double?>[];
      void listener() => progressSamples.add(voice.bundledStreamingProgress);
      voice.addListener(listener);
      addTearDown(() => voice.removeListener(listener));

      final result = await voice.ensureStreamingReady();

      expect(result.ok, isTrue);
      expect(result.attempts, 1, reason: '一次成功不该重试');
      expect(voice.bundledStreamingReady, isTrue);
      expect(voice.bundledStreamingError, isNull);
      expect(voice.bundledStreamingProgress, isNull);
      expect(
        progressSamples.whereType<double>().any((p) => p > 0),
        isTrue,
        reason: '过程中应上报过 0<x≤1 的进度；实际 $progressSamples',
      );
    });
  });

  group('防双写：有 partial 监听时不再二次插 final', () {
    Future<void> warmUp(TextEditingController target) async {
      await seedBundled(root, loader);
      voice.refreshInstalled();
      expect(voice.bundledStreamingReady, isTrue);
      VoiceInputController.decoderFactoryForTest = (_) => FakeStreamDecoder();
    }

    test('有监听（前端接了草稿）⇒ 停止后输入框**不**被代填', () async {
      final target = TextEditingController();
      addTearDown(target.dispose);
      await warmUp(target);

      final partials = <VoicePartial>[];
      final sub = AgentBridge.voicePartials.listen(partials.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(AgentBridge.hasVoicePartialListener, isTrue);

      final voiceInput = VoiceInputController.shared();
      await voiceInput.onMicTap(target: target, toast: toasts.add);
      expect(voiceInput.recording, isTrue);
      await voiceInput.onMicTap(target: target, toast: toasts.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(partials, isNotEmpty, reason: '流式 partial 应已发出');
      expect(
        target.text,
        isEmpty,
        reason: '前端已在展示草稿 ⇒ 后端不得再往输入框插一份（双写）',
      );
      expect(voiceInput.phase, VoiceInputPhase.idle);
    });

    test('无监听（前端还没接）⇒ 仍代填最终文本（不回归"点麦克风没反应"）', () async {
      final target = TextEditingController();
      addTearDown(target.dispose);
      await warmUp(target);
      expect(AgentBridge.hasVoicePartialListener, isFalse);

      final voiceInput = VoiceInputController.shared();
      await voiceInput.onMicTap(target: target, toast: toasts.add);
      await voiceInput.onMicTap(target: target, toast: toasts.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(target.text, '你好世界');
    });
  });
}
