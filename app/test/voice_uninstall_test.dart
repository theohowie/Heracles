/// **语音真卸载（T0-2）单测**（task-26，2026-10-31）。
///
/// 钉住的行为：
/// 1) `deleteAllVoiceModels()` 一次删干净三个目录（sensevoice-small /
///    streaming-zipformer-zh-14m / streaming-zipformer），状态全 false，
///    返回**实际释放字节**与失败项；
/// 2) 卸载后 `ensureStreamingReady()` 返回 `E_VOICE_UNINSTALLED` 且
///    **不读资产、不重建目录**（假卸载的核心：删了又自动解压）；
/// 3) 卸载后点麦克风**不录音**、只给人话提示；
/// 4) 卸载标记**落盘**：重载 controller（模拟重启）仍不可用；
/// 5) `installVoiceModels()` 清标记并幂等解压（字节校验）；
/// 6) 删除/安装都幂等。
///
/// 用**假小资产 + 假加载器**，不依赖 24MB 真模型、不依赖网络。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/services/voice_asr.dart';
import 'package:heracles/services/voice_input.dart';
import 'package:heracles/services/voice_service.dart';
import 'package:heracles/services/voice_stream.dart';

/// 起不来的假解码器：让"流式"走加载失败分支（不在 flutter_tester 里起真 isolate）。
class _FailingDecoder implements VoiceStreamDecoder {
  @override
  Future<void> start() async => throw StateError('测试注入：不加载真模型');

  @override
  void accept(Uint8List pcm) {}

  @override
  void finish() {}

  @override
  Stream<VoiceDecodeUpdate> get updates =>
      const Stream<VoiceDecodeUpdate>.empty();

  @override
  Future<void> dispose() async {}
}

/// 假资产加载器：按字节数造内容 + 计数（可注入失败）。
class FakeAssetLoader {
  FakeAssetLoader(this.sizes);

  final Map<String, int> sizes;
  final Map<String, int> calls = {};
  bool fail = false;

  int get totalCalls => calls.values.fold(0, (a, b) => a + b);

  Future<Uint8List> load(String assetKey) async {
    calls[assetKey] = (calls[assetKey] ?? 0) + 1;
    if (fail) throw StateError('资产读取失败（测试注入）');
    final name = assetKey.split('/').last;
    final size = sizes[name];
    if (size == null) throw StateError('没有这个资产：$assetKey');
    return Uint8List(size);
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

Future<int> dirBytes(Directory dir) async {
  var total = 0;
  if (!dir.existsSync()) return 0;
  await for (final e in dir.list(recursive: true, followLinks: false)) {
    if (e is File) {
      try {
        total += await e.length();
      } catch (_) {}
    }
  }
  return total;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const commandChannel = MethodChannel('heracles/command');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final voice = VoiceModelController.shared();
  final calls = <String>[];
  final toasts = <String>[];

  late Directory tmp;
  late String root;
  late FakeAssetLoader loader;
  late String sensevoiceDir;
  late String bundledDir;
  late String oldStreamingDir;

  Future<void> seedFile(String path, int bytes) async {
    final raf = await File(path).open(mode: FileMode.write);
    await raf.truncate(bytes);
    await raf.close();
  }

  setUpAll(() {
    messenger.setMockMethodCallHandler(commandChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'devicePermissions':
          return <String, String>{'microphone': 'granted'};
        case 'startVoiceRecord':
          return <String, Object?>{'ok': true, 'sessionId': 'v1'};
        case 'stopVoiceRecord':
          return <String, Object?>{'ok': false, 'error': '测试不走到识别'};
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
    calls.clear();
    toasts.clear();
    tmp = await Directory.systemTemp.createTemp('voice_uninstall_');
    root = tmp.path;
    sensevoiceDir = '$root/voice_models/sensevoice-small';
    bundledDir = '$root/voice_models/$kBundledStreamingDirName';
    oldStreamingDir = '$root/voice_models/$kStreamingVoiceDirName';
    loader = FakeAssetLoader(_fakeSizes);
    VoiceModelController.bundledModelFilesForTest = _fakeFiles;
    VoiceModelController.bundledAssetDirForTest = _fakeAssetDir;
    VoiceModelController.bundledAssetLoaderForTest = loader.load;
    VoiceInputController.decoderFactoryForTest = null;

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
    voice.lastFreedBytes = 0;
    voice.lastDeleteFailures = const <String>[];
    voice.lastEnsureErrorCode = null;

    // 三个目录都造点内容（卸载要一次删干净）。
    await Directory(sensevoiceDir).create(recursive: true);
    await seedFile('$sensevoiceDir/dummy.onnx', 100);
    await Directory(oldStreamingDir).create(recursive: true);
    await seedFile('$oldStreamingDir/dummy.onnx', 50);
    // 内置模型：用假资产解压一份完整的（含 .complete）。
    await extractBundledModel(
      dir: bundledDir,
      files: _fakeFiles,
      completeMarker: kBundledStreamingMarker,
      assetDir: _fakeAssetDir,
      loadAsset: loader.load,
    );
    loader.calls.clear();
    voice.refreshInstalled();
  });

  tearDown(() async {
    VoiceModelController.bundledModelFilesForTest = null;
    VoiceModelController.bundledAssetDirForTest = null;
    VoiceModelController.bundledAssetLoaderForTest = null;
    VoiceInputController.decoderFactoryForTest = null;
    voice.profile = null;
    voice.loaded = false;
    voice.voiceEnabled = true;
    voice.voiceUninstalled = false;
    voice.installed = false;
    voice.engineReady = false;
    voice.bundledStreamingReady = false;
    voice.streamingInstalled = false;
    voice.bundledStreamingError = null;
    voice.lastDeleteFailures = const <String>[];
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('deleteAllVoiceModels：一次删干净 + 状态归零 + 字节回报', () {
    test('三个目录都删掉；installed/bundled/streaming 全 false；freed 与失败项正确', () async {
      expect(Directory(bundledDir).existsSync(), isTrue);
      final expectedBytes = (await dirBytes(Directory(sensevoiceDir))) +
          (await dirBytes(Directory(bundledDir))) +
          (await dirBytes(Directory(oldStreamingDir)));
      expect(expectedBytes, greaterThan(0));
      expect(voice.bundledStreamingReady, isTrue);

      final result = await voice.deleteAllVoiceModels();

      expect(Directory(sensevoiceDir).existsSync(), isFalse);
      expect(Directory(bundledDir).existsSync(), isFalse);
      expect(Directory(oldStreamingDir).existsSync(), isFalse);
      expect(voice.installed, isFalse);
      expect(voice.bundledStreamingReady, isFalse);
      expect(voice.streamingInstalled, isFalse);
      expect(voice.engineReady, isFalse);
      expect(result.removedDirs, hasLength(3));
      expect(result.freedBytes, expectedBytes);
      expect(result.failures, isEmpty);
      expect(result.ok, isTrue);
      expect(voice.lastFreedBytes, expectedBytes);
      // 标记必须落盘。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kVoiceUninstalledPrefsKey), isTrue);
      expect(prefs.getBool(kVoiceEnabledPrefsKey), isFalse);
    });

    test('删除时释放引擎缓存：注册的 engineReleaseHooks 都被调用', () async {
      var released = 0;
      void hook() => released++;
      VoiceModelController.registerEngineRelease(hook);

      await voice.deleteAllVoiceModels();

      expect(released, 1, reason: '真卸载必须释放 voice_asr/流式解码器等缓存');
    });

    test('删除幂等：第二次 freed=0、failures 空、仍保持已卸载', () async {
      await voice.deleteAllVoiceModels();
      final second = await voice.deleteAllVoiceModels();
      expect(second.freedBytes, 0);
      expect(second.failures, isEmpty);
      expect(voice.voiceUninstalled, isTrue);
      expect(voice.voiceEnabled, isFalse);
    });
  });

  group('已卸载闸门：绝不自动解压 / 不录音', () {
    test('ensureStreamingReady 返回 E_VOICE_UNINSTALLED，且不读资产不建目录', () async {
      await voice.deleteAllVoiceModels();
      loader.calls.clear();

      final result = await voice.ensureStreamingReady();

      expect(result.ok, isFalse);
      expect(result.errorCode, kVoiceUninstalledError);
      expect(result.uninstalled, isTrue);
      expect(loader.totalCalls, 0, reason: '已卸载时不得读任何资产');
      expect(Directory(bundledDir).existsSync(), isFalse,
          reason: '已卸载时不得自动重建模型目录');
      expect(voice.bundledStreamingReady, isFalse);
      expect(voice.lastEnsureErrorCode, kVoiceUninstalledError);
    });

    test('点麦克风：只提示"已卸载"，不调 startVoiceRecord', () async {
      await voice.deleteAllVoiceModels();
      final target = TextEditingController();
      addTearDown(target.dispose);

      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );

      expect(calls.contains('startVoiceRecord'), isFalse);
      expect(toasts.single, contains('已卸载'));
      expect(VoiceInputController.shared().recording, isFalse);
      expect(Directory(bundledDir).existsSync(), isFalse);
    });

    test('整段识别硬闸：卸载后即使 engineReady 残留也拒绝转写（E_VOICE_UNINSTALLED）', () async {
      await voice.deleteAllVoiceModels();
      // 模拟"内存里 engineReady 还残留 true"的边界：VoiceAsr 必须再拦一次。
      voice.engineReady = true;
      await expectLater(
        VoiceAsr.transcribeWav('$root/nonexistent.wav'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            kVoiceUninstalledError,
          ),
        ),
      );
    });
  });

  group('卸载标记持久化（重启仍不可用）', () {
    test('重载 controller（模拟重启）：标记从 prefs 恢复，仍不可用且不解压', () async {
      await voice.deleteAllVoiceModels();
      // 模拟进程重启：内存状态回默认，再 load() 从 prefs 恢复。
      voice.loaded = false;
      voice.voiceUninstalled = false;
      voice.voiceEnabled = true;
      voice.bundledStreamingReady = false;
      voice.installed = false;
      voice.engineReady = false;
      loader.calls.clear();

      await voice.load();

      expect(voice.voiceUninstalled, isTrue, reason: '卸载标记必须跨重启保持');
      expect(voice.voiceEnabled, isFalse);
      expect(voice.bundledStreamingReady, isFalse);
      expect(voice.streamingInstalled, isFalse);
      expect(loader.totalCalls, 0, reason: '启动也不得自动解压');

      // 重载后点麦克风同样拒绝。
      toasts.clear();
      calls.clear();
      final target = TextEditingController();
      addTearDown(target.dispose);
      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );
      expect(calls.contains('startVoiceRecord'), isFalse);
      expect(toasts.single, contains('已卸载'));
    });
  });

  group('installVoiceModels：清标记 + 幂等解压恢复', () {
    test('卸载后安装：标记清掉、内置模型幂等解压、again 可流式', () async {
      final deleted = await voice.deleteAllVoiceModels();
      expect(deleted.ok, isTrue);
      expect(Directory(bundledDir).existsSync(), isFalse);

      final first = await voice.installVoiceModels();

      expect(first.ok, isTrue);
      expect(first.bundledReady, isTrue);
      expect(voice.voiceUninstalled, isFalse);
      expect(voice.voiceEnabled, isTrue);
      expect(voice.bundledStreamingReady, isTrue);
      expect(voice.streamingInstalled, isTrue);
      expect(voiceModelDirComplete(bundledDir, _fakeFiles), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kVoiceUninstalledPrefsKey), isFalse);
      expect(prefs.getBool(kVoiceEnabledPrefsKey), isTrue);

      // 幂等：再装一次不再读资产。
      final callsBefore = loader.totalCalls;
      final second = await voice.installVoiceModels();
      expect(second.ok, isTrue);
      expect(loader.totalCalls, callsBefore);
    });

    test('安装后点麦克风不再走"已卸载"分支（会进入录音流程）', () async {
      await voice.deleteAllVoiceModels();
      await voice.installVoiceModels();
      // 不加载真模型：注入"起不来"的假解码器（流式失败会如实回退，但不影响录音）。
      VoiceInputController.decoderFactoryForTest = (_) => _FailingDecoder();
      toasts.clear();
      calls.clear();
      final target = TextEditingController();
      addTearDown(target.dispose);

      await VoiceInputController.shared().onMicTap(
        target: target,
        toast: toasts.add,
      );

      expect(toasts.any((t) => t.contains('已卸载')), isFalse);
      expect(calls.contains('startVoiceRecord'), isTrue);
      await VoiceInputController.shared().cancelIfRecording();
    });
  });
}
