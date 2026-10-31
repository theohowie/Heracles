/// **内置 14M 中文流式模型（B1）单测**（task-16，2026-10-30）。
///
/// 覆盖：
/// 1) `extractBundledModel`：解压成功 / 幂等（二次不读资产）/ 字节校验失败
///    可重试且不留 `.complete` 半成品 / 旧标记+坏文件会重解压；
/// 2) `VoiceModelController.ensureStreamingReady`：首次解压即用、**并发只解压
///    一次**、失败不崩可重试、`refreshInstalled` 正确识别内置模型；
/// 3) 可选下载的旧双语模型仍能作为回退被选中（内置缺失时 `bundled=false`）。
///
/// 全部用**假小文件 + 假资产加载器**，不依赖 24MB 真模型、不依赖网络。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:heracles/models/jev.dart';
import 'package:heracles/services/voice_service.dart';

/// 假资产加载器：按字节数造内容，并记录调用次数（可选延迟制造并发窗口）。
class FakeAssetLoader {
  FakeAssetLoader(this.sizes, {this.delay = Duration.zero});

  final Map<String, int> sizes;
  Duration delay;
  final Map<String, int> calls = {};
  bool fail = false;

  int get totalCalls => calls.values.fold(0, (a, b) => a + b);

  Future<Uint8List> load(String assetKey) async {
    calls[assetKey] = (calls[assetKey] ?? 0) + 1;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw StateError('资产读取失败（测试注入）');
    final name = assetKey.split('/').last;
    final size = sizes[name];
    if (size == null) throw StateError('没有这个资产：$assetKey');
    final bytes = Uint8List(size);
    // 填一点可校验的内容（首字节 = 名字长度，避免全 0 也能看出写没写）。
    if (size > 0) bytes[0] = name.length & 0xFF;
    return bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String root;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('voice_bundled_');
    root = tmp.path;
  });

  tearDown(() async {
    VoiceModelController.bundledAssetLoaderForTest = null;
    VoiceModelController.bundledModelFilesForTest = null;
    VoiceModelController.bundledAssetDirForTest = null;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  // ---------------------------------------------------- extractBundledModel

  group('extractBundledModel：解压 / 幂等 / 校验 / 重试', () {
    final files = <VoiceModelFile>[
      const VoiceModelFile('encoder.onnx', 8),
      const VoiceModelFile('decoder.onnx', 4),
      const VoiceModelFile('tokens.txt', 2),
    ];
    const assetDir = 'fake/assets';

    Future<void> extract(String dir, FakeAssetLoader loader) =>
        extractBundledModel(
          dir: dir,
          files: files,
          completeMarker: 'test-marker',
          assetDir: assetDir,
          loadAsset: loader.load,
        );

    test('解压成功：逐文件字节正确 + `.complete` 落盘', () async {
      final dir = '$root/model';
      final loader = FakeAssetLoader({'encoder.onnx': 8, 'decoder.onnx': 4, 'tokens.txt': 2});
      await extract(dir, loader);

      for (final f in files) {
        final file = File('$dir/${f.name}');
        expect(file.existsSync(), isTrue, reason: '${f.name} 应已写出');
        expect(file.lengthSync(), f.bytes);
      }
      final marker = File('$dir/.complete');
      expect(marker.existsSync(), isTrue);
      expect(marker.readAsStringSync(), contains('test-marker'));
      expect(voiceModelDirComplete(dir, files), isTrue);
    });

    test('幂等：第二次调用**不再读资产**（零 IO）', () async {
      final dir = '$root/model';
      final loader = FakeAssetLoader({'encoder.onnx': 8, 'decoder.onnx': 4, 'tokens.txt': 2});
      await extract(dir, loader);
      final first = loader.totalCalls;
      expect(first, 3);
      // 把完成标记改成哨兵：真正"零操作"的第二次调用必须原样保留它
      //（老实现会删标记重写 ⇒ 哨兵丢失 = 重扫/重写文件系统）。
      await File('$dir/.complete').writeAsString('KEEP-ME');
      await extract(dir, loader);
      expect(loader.totalCalls, first, reason: '已完整时不应重新读资产/重写文件');
      expect(
        File('$dir/.complete').readAsStringSync(),
        'KEEP-ME',
        reason: '已完整时不得重写 `.complete`（幂等 = 完全不动磁盘）',
      );
    });

    test('字节数不符 ⇒ 抛错、不写 `.complete`、不留 tmp、修好后可重试', () async {
      final dir = '$root/model';
      // decoder 声明 4 字节，但加载器只给 3 字节 ⇒ 必须失败。
      final loader = FakeAssetLoader({'encoder.onnx': 8, 'decoder.onnx': 3, 'tokens.txt': 2});
      await expectLater(extract(dir, loader), throwsA(isA<StateError>()));
      expect(File('$dir/.complete').existsSync(), isFalse, reason: '坏尺寸绝不能落完成标记');
      expect(File('$dir/decoder.onnx.tmp').existsSync(), isFalse, reason: '临时文件应清理');
      expect(voiceModelDirComplete(dir, files), isFalse);

      // 第二次：只有真正缺的（decoder/tokens）会重读，已完整的 encoder 跳过。
      final good = FakeAssetLoader({'encoder.onnx': 8, 'decoder.onnx': 4, 'tokens.txt': 2});
      await extract(dir, good);
      expect(good.calls['encoder.onnx'], isNull, reason: '已完整的文件应跳过');
      expect(voiceModelDirComplete(dir, files), isTrue);
    });

    test('旧标记在但文件字节不对 ⇒ 删标记并重解压（不误判完整）', () async {
      final dir = '$root/model';
      await Directory(dir).create(recursive: true);
      await File('$dir/.complete').writeAsString('test-marker');
      await File('$dir/encoder.onnx').writeAsBytes(List.filled(3, 0)); // 长度不对

      final loader = FakeAssetLoader({'encoder.onnx': 8, 'decoder.onnx': 4, 'tokens.txt': 2});
      await extract(dir, loader);
      expect(voiceModelDirComplete(dir, files), isTrue);
      expect(File('$dir/encoder.onnx').lengthSync(), 8);
    });
  });

  // ---------------------------------------- VoiceModelController.ensureStreamingReady

  group('VoiceModelController.ensureStreamingReady：内置模型开箱即用', () {
    final voice = VoiceModelController.shared();
    final fakeFiles = <VoiceModelFile>[
      const VoiceModelFile('encoder.onnx', 8),
      const VoiceModelFile('decoder.onnx', 4),
      const VoiceModelFile('joiner.onnx', 3),
      const VoiceModelFile('tokens.txt', 2),
    ];
    const fakeAssetDir = 'fake/assets';

    void seedController() {
      VoiceModelController.bundledModelFilesForTest = fakeFiles;
      VoiceModelController.bundledAssetDirForTest = fakeAssetDir;
      voice.profile = JevDeviceProfile(
        model: 'test',
        totalRamMb: 8192,
        freeStorageMb: 99999,
        appFilesDir: root,
      );
      voice.loaded = true;
      voice.installed = false;
      voice.engineReady = false;
      voice.bundledStreamingReady = false;
      voice.bundledStreamingError = null;
      voice.streamingInstalled = false;
      voice.refreshInstalled();
    }

    tearDown(() {
      voice.profile = null;
      voice.loaded = false;
      voice.bundledStreamingReady = false;
      voice.streamingInstalled = false;
      voice.bundledStreamingError = null;
    });

    test('首次 ensure ⇒ 解压成功、streamingInstalled/activeStreamingModel 可用', () async {
      seedController();
      final loader = FakeAssetLoader({
        'encoder.onnx': 8,
        'decoder.onnx': 4,
        'joiner.onnx': 3,
        'tokens.txt': 2,
      });
      VoiceModelController.bundledAssetLoaderForTest = loader.load;

      expect(voice.streamingInstalled, isFalse);
      expect((await voice.ensureStreamingReady()).ok, isTrue);

      expect(voice.bundledStreamingReady, isTrue);
      expect(voice.streamingInstalled, isTrue, reason: '内置解压完成即"流式可用"');
      expect(voice.bundledStreamingError, isNull);
      final model = voice.activeStreamingModel;
      expect(model, isNotNull);
      expect(model!.bundled, isTrue);
      expect(model.label, contains('内置'));

      final dir = voice.bundledStreamingModelDir!;
      expect(voiceModelDirComplete(dir, fakeFiles), isTrue);
      // 二次调用零资产读取（幂等）。
      final calls = loader.totalCalls;
      expect((await voice.ensureStreamingReady()).ok, isTrue);
      expect(loader.totalCalls, calls);
    });

    test('并发只解压一次：两个 await 共享同一次解压', () async {
      seedController();
      final loader = FakeAssetLoader({
        'encoder.onnx': 8,
        'decoder.onnx': 4,
        'joiner.onnx': 3,
        'tokens.txt': 2,
      }, delay: const Duration(milliseconds: 30));
      VoiceModelController.bundledAssetLoaderForTest = loader.load;

      final results = await Future.wait([
        voice.ensureStreamingReady(),
        voice.ensureStreamingReady(),
        voice.ensureStreamingReady(),
      ]);
      expect(results.map((r) => r.ok).toList(), [true, true, true]);
      // 四个文件各读一次（不是 4×3 次）。
      expect(loader.totalCalls, 4, reason: '并发调用必须共享同一次解压');
      expect(voice.streamingInstalled, isTrue);
    });

    test('解压失败不崩、可重试：第一次 loader 抛错 ⇒ false，第二次成功', () async {
      seedController();
      final bad = FakeAssetLoader({
        'encoder.onnx': 8,
        'decoder.onnx': 4,
        'joiner.onnx': 3,
        'tokens.txt': 2,
      })..fail = true;
      VoiceModelController.bundledAssetLoaderForTest = bad.load;

      expect((await voice.ensureStreamingReady()).ok, isFalse);
      expect(voice.bundledStreamingReady, isFalse);
      expect(voice.streamingInstalled, isFalse);
      expect(voice.bundledStreamingError, isNotNull);
      expect(voice.bundledStreamingError, contains('解压失败'));

      final good = FakeAssetLoader({
        'encoder.onnx': 8,
        'decoder.onnx': 4,
        'joiner.onnx': 3,
        'tokens.txt': 2,
      });
      VoiceModelController.bundledAssetLoaderForTest = good.load;
      expect((await voice.ensureStreamingReady()).ok, isTrue);
      expect(voice.bundledStreamingError, isNull);
    });

    test('内置缺失 + 旧双语模型完整 ⇒ 仍可用（bundled=false 的高精度路径）', () async {
      seedController();
      // 造一份"已下载完整"的旧双语模型（字节用真实常量尺寸太大，这里用
      // 真实常量但只声明文件存在 + 长度：用 truncate 造稀疏文件）。
      final oldDir = voice.streamingModelDir!;
      await Directory(oldDir).create(recursive: true);
      for (final f in kStreamingVoiceModelFiles) {
        final raf = await File('$oldDir/${f.name}').open(mode: FileMode.write);
        await raf.truncate(f.bytes);
        await raf.close();
      }
      await File('$oldDir/.complete').writeAsString('old');
      voice.refreshInstalled();

      expect(voice.bundledStreamingReady, isFalse);
      expect(voice.streamingInstalled, isTrue);
      final model = voice.activeStreamingModel;
      expect(model, isNotNull);
      expect(model!.bundled, isFalse);
      expect(model.decoder, contains(kStreamingDecoderName));
    });

    test('内置与可选下载都在 ⇒ **默认选内置**（旧双语降级为可选高精度）', () async {
      seedController();
      // 1) 老双语模型完整。
      final oldDir = voice.streamingModelDir!;
      await Directory(oldDir).create(recursive: true);
      for (final f in kStreamingVoiceModelFiles) {
        final raf = await File('$oldDir/${f.name}').open(mode: FileMode.write);
        await raf.truncate(f.bytes);
        await raf.close();
      }
      await File('$oldDir/.complete').writeAsString('old');
      // 2) 内置也解压好。
      VoiceModelController.bundledAssetLoaderForTest = FakeAssetLoader({
        'encoder.onnx': 8,
        'decoder.onnx': 4,
        'joiner.onnx': 3,
        'tokens.txt': 2,
      }).load;
      expect((await voice.ensureStreamingReady()).ok, isTrue);
      voice.refreshInstalled();

      final model = voice.activeStreamingModel;
      expect(model, isNotNull);
      expect(model!.bundled, isTrue, reason: '两套都在时必须优先内置 14M');
      expect(model.decoder, contains(kBundledStreamingDecoderName));
    });
  });
}
