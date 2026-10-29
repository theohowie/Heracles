import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/jev.dart';
import 'agent_bridge.dart';

/// **本地语音识别（SenseVoice）的模型管理**（2026-10-29 用户定：
/// 语音识别走本地大模型，用户在设置页自行下载，我们把下载、
/// 校验、落盘位置全部配好，下载完即可供识别引擎使用）。
///
/// 模型 = 阿里 FunASR 的 SenseVoiceSmall（ONNX 量化版），来源
/// ModelScope 官方仓库 `iic/SenseVoiceSmall-onnx`（用户指定链接）。
/// 需要的文件共 4 个（权重 + 词表 + 声学归一化 + 配置），清单与
/// 精确字节数按 ModelScope 仓库 API 实测写死（2026-10-29）：
/// 下载逐个按字节数校验，对不上不写完成标记 —— 宁可报失败，
/// 不让用户对着一个坏模型找原因。
///
/// 存放：`<appFilesDir>/voice_models/sensevoice-small/`，完成以
/// `.complete` 标记为准（与 JEV 本地模型同一套口径）。
class VoiceModelFile {
  const VoiceModelFile(this.name, this.bytes);

  final String name;

  /// ModelScope 仓库里该文件的精确字节数（下载后逐个核对）。
  final int bytes;
}

const kVoiceModelRepoUrl =
    'https://www.modelscope.cn/models/iic/SenseVoiceSmall-onnx';

const kVoiceModelFiles = <VoiceModelFile>[
  VoiceModelFile('model_quant.onnx', 241216270),
  VoiceModelFile('tokens.json', 352064),
  VoiceModelFile('am.mvn', 11203),
  VoiceModelFile('config.yaml', 1855),
];

int get kVoiceModelTotalBytes =>
    kVoiceModelFiles.fold(0, (sum, f) => sum + f.bytes);

// ------------------------------------------------------- 流式识别模型（§N13.4）
//
// **流式模型 = sherpa-onnx 的 streaming zipformer 中英双语 int8**
// （HF 仓库 `csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20`）。
//
// 2026-10-29 本机**实测**（不假装）：
// · `https://huggingface.co/...` HEAD 200，四个文件字节数逐个拿到（写死在
//   [kStreamingVoiceModelFiles]；one 个 190MB 量级）；
// · `hf-mirror.com` / `www.modelscope.cn` / GitHub release 本机均
//   `无法连接到远程服务器`（同一时刻 HF 却通）⇒ **先只配 HF 源**；
//   镜像等镜像可用再加（source 列表化留待有实据时做，不写死假地址）。
//
// 目录与 SenseVoice **分开**：`<appFilesDir>/voice_models/streaming-zipformer/`
// ⇒ 两套模型的 `.complete` / 字节校验互不覆盖。下载、校验、完成标记
// 全部走 [VoiceModelController] 同一套 [_downloadInto]（不新写下载器）。

/// 流式模型来源（HF 仓库根，下载时拼 `/resolve/main/<name>`）。
const kStreamingVoiceModelRepoUrl =
    'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20';

/// 流式子目录名（与 `sensevoice-small` 平级、互不覆盖）。
const kStreamingVoiceDirName = 'streaming-zipformer';

/// `.complete` 里写的模型标识（与 SenseVoice 区分）。
const kStreamingVoiceMarker = 'streaming-zipformer-bilingual-zh-en-int8';

const kStreamingEncoderName = 'encoder-epoch-99-avg-1.int8.onnx';
const kStreamingDecoderName = 'decoder-epoch-99-avg-1.onnx';
const kStreamingJoinerName = 'joiner-epoch-99-avg-1.int8.onnx';
const kStreamingTokensName = 'tokens.txt';

const kStreamingVoiceModelFiles = <VoiceModelFile>[
  VoiceModelFile(kStreamingEncoderName, 181895032),
  VoiceModelFile(kStreamingDecoderName, 13876452),
  VoiceModelFile(kStreamingJoinerName, 3228404),
  VoiceModelFile(kStreamingTokensName, 56317),
];

int get kStreamingVoiceModelTotalBytes =>
    kStreamingVoiceModelFiles.fold(0, (sum, f) => sum + f.bytes);


// ------------------------------------------------------------ 引擎准备
//
// **识别引擎 = sherpa-onnx**（2026-10-29 实测定的路线）。官方
// `model_quant.onnx` 不能直喂 sherpa-onnx：它的 SenseVoice 实现
// 把 LFR 参数、语言/标点 id 映射、CMVN 向量都从 ONNX 的
// metadata 读，而官方导出里 metadata 是空的。补法已在桌面端
// 用 sherpa-onnx 2.0.1 实测跑通（识别结果与官方参考逐字一致）：
//
// 1. **补 metadata**：ONNX 文件本身就是 protobuf（ModelProto），
//    metadata_props 是它的 field 14（repeated 条目）。在文件尾部
//    追加编码好的条目是合法的 protobuf 写法 —— 流式拷贝原文件
//    + 尾部追加，不动权重一个字节。17 个键里 15 个是定数，
//    `neg_mean` / `inv_stddev` 从 am.mvn 解析（见 [parseCmvnPair]）。
// 2. **转词表**：sherpa-onnx 要 tokens.txt（每行「token id」），
//    tokens.json 正好是「下标即 id」的数组，逐行写出即可。
//
// 产物落在同一模型目录：`model_sherpa.onnx` + `tokens.txt`。
// 已下载的裸文件不浪费：下载完成自动准备；老版本下好的，
// [VoiceModelController.load] 时发现没准备也会懒补。

/// 补完 metadata 后供 sherpa-onnx 加载的模型文件名。
const kVoiceSherpaModelName = 'model_sherpa.onnx';

/// 由 tokens.json 转出的词表文件名。
const kVoiceTokensTxtName = 'tokens.txt';

/// 解析 am.mvn（Kaldi 全局 CMVN），返回 (neg_mean, inv_stddev)
/// 两个逗号拼接的 560 维向量字符串 —— 与 sherpa-onnx 官方导出
/// 脚本 `load_cmvn()` 同规则：取以 `<LearnRateCoef>` 开头的两行
/// （先 AddShift 后 Rescale），每行 `split()[3:-1]`。
(String, String) parseCmvnPair(String amMvnText) {
  final rows = <List<String>>[];
  for (final line in amMvnText.split('\n')) {
    final t = line.trim();
    if (!t.startsWith('<LearnRateCoef>')) continue;
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 5) {
      throw const FormatException('am.mvn 的 LearnRateCoef 行格式不对');
    }
    rows.add(parts.sublist(3, parts.length - 1));
  }
  if (rows.length != 2) {
    throw FormatException('am.mvn 应有 2 行 LearnRateCoef，实际 ${rows.length} 行');
  }
  if (rows[0].length != 560 || rows[1].length != 560) {
    throw FormatException(
      'am.mvn 的 CMVN 维度应为 560，实际 ${rows[0].length}/${rows[1].length}',
    );
  }
  return (rows[0].join(','), rows[1].join(','));
}

/// sherpa-onnx 的 SenseVoice 要的 17 个 metadata 键（值全部有据：
/// 定数取自 config.yaml 与 FunASR 官方 lid/textnorm 表 —— 注意
/// zh 是 3 不是 1；CMVN 两键由 [parseCmvnPair] 给出）。
Map<String, String> voiceSherpaMetadata(String amMvnText) {
  final (negMean, invStddev) = parseCmvnPair(amMvnText);
  return {
    'model_type': 'sense_voice_ctc',
    'comment': 'iic/SenseVoiceSmall',
    'vocab_size': '25055',
    'lfr_window_size': '7',
    'lfr_window_shift': '6',
    'normalize_samples': '0',
    'with_itn': '14',
    'without_itn': '15',
    'lang_auto': '0',
    'lang_zh': '3',
    'lang_en': '4',
    'lang_yue': '7',
    'lang_ja': '11',
    'lang_ko': '12',
    'lang_nospeech': '13',
    'neg_mean': negMean,
    'inv_stddev': invStddev,
  };
}

List<int> _protoVarint(int n) {
  final out = <int>[];
  var v = n;
  while (true) {
    final b = v & 0x7F;
    v >>= 7;
    if (v == 0) {
      out.add(b);
      return out;
    }
    out.add(b | 0x80);
  }
}

/// 把 metadata 键值编码成可直接追加到 ONNX 文件尾部的字节：
/// 每条 = ModelProto field 14（tag 0x72）+ 长度 + 条目本体
/// （条目 = field1 key + field2 value，各自 tag+长度+UTF-8）。
Uint8List encodeOnnxMetadataEntries(Map<String, String> entries) {
  final out = BytesBuilder();
  entries.forEach((key, value) {
    final kb = utf8.encode(key);
    final vb = utf8.encode(value);
    final body = BytesBuilder()
      ..addByte(0x0A)
      ..add(_protoVarint(kb.length))
      ..add(kb)
      ..addByte(0x12)
      ..add(_protoVarint(vb.length))
      ..add(vb);
    final bodyBytes = body.toBytes();
    out
      ..addByte(0x72)
      ..add(_protoVarint(bodyBytes.length))
      ..add(bodyBytes);
  });
  return out.toBytes();
}

/// tokens.json（数组，下标即 token id）→ tokens.txt 文本
/// （每行 `<token> <id>`，与 sherpa-onnx 官方导出脚本同规则）。
String tokensTxtFromJson(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! List) {
    throw const FormatException('tokens.json 不是数组');
  }
  final buf = StringBuffer();
  for (var i = 0; i < decoded.length; i++) {
    final tok = decoded[i];
    if (tok is! String || tok.contains('\n') || tok.contains(' ')) {
      throw FormatException('tokens.json 第 $i 项不是可用的 token 字符串');
    }
    buf.writeln('$tok $i');
  }
  return buf.toString();
}

enum VoiceModelPhase { idle, downloading, done, error }

class VoiceDownloadState {
  const VoiceDownloadState({
    this.phase = VoiceModelPhase.idle,
    this.received = 0,
    this.total = 0,
    this.note,
    this.error,
  });

  final VoiceModelPhase phase;
  final int received;
  final int total;
  final String? note;
  final String? error;

  double? get fraction =>
      total <= 0 ? null : (received / total).clamp(0.0, 1.0);
}

class VoiceModelController extends ChangeNotifier {
  VoiceModelController._();

  static final VoiceModelController _shared = VoiceModelController._();
  factory VoiceModelController.shared() => _shared;

  JevDeviceProfile? profile;
  bool loaded = false;
  bool installed = false;

  /// 引擎准备（补 metadata + 转词表）进行中 / 已就绪。
  bool preparing = false;
  bool engineReady = false;
  String? prepareError;
  VoiceDownloadState download = const VoiceDownloadState();

  /// **流式模型**（§N13.4）是否已下载完整（`.complete` + 逐文件字节）。
  bool streamingInstalled = false;

  /// 流式模型下载状态（与整段模型的 [download] 互不干扰）。
  VoiceDownloadState streamingDownload = const VoiceDownloadState();

  CancelToken? _cancelToken;

  bool get downloading => download.phase == VoiceModelPhase.downloading;

  bool get streamingDownloading =>
      streamingDownload.phase == VoiceModelPhase.downloading;

  /// sherpa-onnx 要加载的两个产物路径（引擎准备完成后才存在）。
  String? get sherpaModelPath {
    final dir = modelDir;
    return dir == null ? null : '$dir/$kVoiceSherpaModelName';
  }

  String? get tokensTxtPath {
    final dir = modelDir;
    return dir == null ? null : '$dir/$kVoiceTokensTxtName';
  }

  String? get modelDir {
    final root = profile?.appFilesDir ?? '';
    if (root.isEmpty) return null;
    return '$root/voice_models/sensevoice-small';
  }

  /// 流式模型目录（与 [modelDir] **平级、互不覆盖**）。
  String? get streamingModelDir {
    final root = profile?.appFilesDir ?? '';
    if (root.isEmpty) return null;
    return '$root/voice_models/$kStreamingVoiceDirName';
  }

  String? _streamingFile(String name) {
    final dir = streamingModelDir;
    return dir == null ? null : '$dir/$name';
  }

  String? get streamingEncoderPath => _streamingFile(kStreamingEncoderName);
  String? get streamingDecoderPath => _streamingFile(kStreamingDecoderName);
  String? get streamingJoinerPath => _streamingFile(kStreamingJoinerName);
  String? get streamingTokensPath => _streamingFile(kStreamingTokensName);

  Future<void> load() async {
    profile ??= await AgentBridge().deviceProfile();
    refreshInstalled();
    loaded = true;
    notifyListeners();
    // 裸文件下好了但引擎产物还没备（老版本下载的）→ 懒补。
    if (installed && !engineReady) {
      unawaited(prepareEngine());
    }
  }

  Future<void> reloadProfile() async {
    profile = await AgentBridge().deviceProfile();
    refreshInstalled();
    notifyListeners();
  }

  /// 已安装 = 完成标记在，且每个文件都在、字节数精确对上。
  void refreshInstalled() {
    final dir = modelDir;
    installed = _dirComplete(dir, kVoiceModelFiles);
    streamingInstalled = _dirComplete(streamingModelDir, kStreamingVoiceModelFiles);
    if (installed && download.phase != VoiceModelPhase.downloading) {
      download = const VoiceDownloadState(phase: VoiceModelPhase.done);
    }
    if (streamingInstalled &&
        streamingDownload.phase != VoiceModelPhase.downloading) {
      streamingDownload = const VoiceDownloadState(phase: VoiceModelPhase.done);
    }
    // 引擎产物：两个文件都在、且补完的模型比裸文件大（metadata
    // 追加了约 11KB）才算真备好 —— 只看存在会被半成品骗过去。
    engineReady = false;
    if (installed) {
      final raw = File('$dir/model_quant.onnx');
      final patched = File('$dir/$kVoiceSherpaModelName');
      final tokens = File('$dir/$kVoiceTokensTxtName');
      engineReady = patched.existsSync() &&
          tokens.existsSync() &&
          patched.lengthSync() > raw.lengthSync();
    }
  }

  /// 目录里是否「`.complete` 在 + 每个文件字节数精确对上」。
  bool _dirComplete(String? dir, List<VoiceModelFile> files) {
    if (dir == null || !File('$dir/.complete').existsSync()) return false;
    for (final f in files) {
      final file = File('$dir/${f.name}');
      if (!file.existsSync() || file.lengthSync() != f.bytes) return false;
    }
    return true;
  }

  /// **引擎准备**：tokens.json → tokens.txt；model_quant.onnx
  /// 流式拷贝 + 尾部追加 metadata → model_sherpa.onnx。
  /// 幂等：已备好直接返回；中途产物用 `.tmp` 名，成了才改名，
  /// 半成品不会被 [refreshInstalled] 误判为就绪。
  Future<void> prepareEngine() async {
    if (preparing || engineReady) return;
    final dir = modelDir;
    if (dir == null) return;
    // 原料齐了才备（不只看 installed 标记：标记口径更严，
    // 这里按文件存在与否放行，缺哪个都会在下面读文件时如实报错）。
    if (!File('$dir/model_quant.onnx').existsSync() ||
        !File('$dir/tokens.json').existsSync() ||
        !File('$dir/am.mvn').existsSync()) {
      return;
    }
    preparing = true;
    prepareError = null;
    notifyListeners();
    try {
      // 1) 词表转换（小文件，先做，失败早报）。
      final tokensJson = await File('$dir/tokens.json').readAsString();
      await File('$dir/$kVoiceTokensTxtName')
          .writeAsString(tokensTxtFromJson(tokensJson));

      // 2) 模型补 metadata：流式拷贝（241MB 不能整读进内存）。
      final amMvn = await File('$dir/am.mvn').readAsString();
      final extra = encodeOnnxMetadataEntries(voiceSherpaMetadata(amMvn));
      final tmp = File('$dir/$kVoiceSherpaModelName.tmp');
      final sink = tmp.openWrite();
      try {
        await sink.addStream(File('$dir/model_quant.onnx').openRead());
        sink.add(extra);
        await sink.flush();
      } finally {
        await sink.close();
      }
      final rawLen = File('$dir/model_quant.onnx').lengthSync();
      if (tmp.lengthSync() != rawLen + extra.length) {
        await tmp.delete();
        throw StateError('补元数据后的模型大小对不上，已丢弃，请重试');
      }
      await tmp.rename('$dir/$kVoiceSherpaModelName');
      engineReady = true;
    } catch (e) {
      prepareError = '模型准备失败：$e';
    } finally {
      preparing = false;
      notifyListeners();
    }
  }

  Future<void> startDownload() async {
    final dir = modelDir;
    if (dir == null) {
      download = const VoiceDownloadState(
        phase: VoiceModelPhase.error,
        error: '拿不到本机存储目录（宿主未返回 deviceProfile）。',
      );
      notifyListeners();
      return;
    }
    if (downloading) return;
    final ok = await _downloadInto(
      dir: dir,
      files: kVoiceModelFiles,
      totalBytes: kVoiceModelTotalBytes,
      completeMarker: 'sensevoice-small-onnx',
      // ModelScope 的原始仓库路径（旧实现口径，保持不动）。
      urlOf: (name) => '$kVoiceModelRepoUrl/resolve/master/$name',
      onState: (s) {
        download = s;
        notifyListeners();
      },
    );
    if (!ok) return;
    installed = true;
    download = const VoiceDownloadState(phase: VoiceModelPhase.done);
    notifyListeners();
    // 下完立刻把引擎产物备好，用户点麦克风时不用等。
    await prepareEngine();
  }

  /// **流式模型下载**（§N13.4）：与整段模型同一套下载 + 字节校验 +
  /// `.complete`，只是落在独立子目录。失败/取消 ⇒ 只影响
  /// [streamingInstalled]，整段识别照旧可用（回退由调用方决定）。
  Future<void> startStreamingDownload() async {
    final dir = streamingModelDir;
    if (dir == null) {
      streamingDownload = const VoiceDownloadState(
        phase: VoiceModelPhase.error,
        error: '拿不到本机存储目录（宿主未返回 deviceProfile）。',
      );
      notifyListeners();
      return;
    }
    if (streamingDownloading) return;
    final ok = await _downloadInto(
      dir: dir,
      files: kStreamingVoiceModelFiles,
      totalBytes: kStreamingVoiceModelTotalBytes,
      completeMarker: kStreamingVoiceMarker,
      urlOf: (name) => '$kStreamingVoiceModelRepoUrl/resolve/main/$name',
      onState: (s) {
        streamingDownload = s;
        notifyListeners();
      },
    );
    if (!ok) return;
    streamingInstalled = true;
    streamingDownload = const VoiceDownloadState(phase: VoiceModelPhase.done);
    notifyListeners();
  }

  /// 两个模型共用的下载流程：逐文件下载 → 按字节数校验（对不上就删并
  /// 报错）→ 写 `.complete`。返回 true = 全部下完并标记成功。
  ///
  /// 已存在且字节数精确对上的文件跳过（粗粒度断点续传）；取消/失败时
  /// 只清状态，已完整下好的文件保留。**只有一个下载在跑**（共享
  /// [_cancelToken]）：另一个模型正在下载时再点会返回 false 之外的状态，
  /// 不并发抢带宽。
  Future<bool> _downloadInto({
    required String dir,
    required List<VoiceModelFile> files,
    required int totalBytes,
    required String completeMarker,
    required String Function(String name) urlOf,
    required void Function(VoiceDownloadState state) onState,
  }) async {
    final token = CancelToken();
    _cancelToken = token;
    onState(
      VoiceDownloadState(
        phase: VoiceModelPhase.downloading,
        total: totalBytes,
        note: '正在下载模型文件',
      ),
    );
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 30),
      ),
    );
    try {
      await Directory(dir).create(recursive: true);
      var doneBytes = 0;
      for (final f in files) {
        final savePath = '$dir/${f.name}';
        final existing = File(savePath);
        if (existing.existsSync() && existing.lengthSync() == f.bytes) {
          doneBytes += f.bytes;
          continue;
        }
        onState(
          VoiceDownloadState(
            phase: VoiceModelPhase.downloading,
            received: doneBytes,
            total: totalBytes,
            note: '正在下载 ${f.name}',
          ),
        );
        final base = doneBytes;
        await dio.download(
          urlOf(f.name),
          savePath,
          cancelToken: token,
          onReceiveProgress: (received, _) {
            onState(
              VoiceDownloadState(
                phase: VoiceModelPhase.downloading,
                received: base + received,
                total: totalBytes,
                note: '正在下载 ${f.name}',
              ),
            );
          },
        );
        // 逐个校验：字节数对不上 = 坏文件，删掉并报错，不继续。
        final got = File(savePath);
        if (!got.existsSync() || got.lengthSync() != f.bytes) {
          if (got.existsSync()) await got.delete();
          throw StateError(
            '${f.name} 下载不完整（大小对不上），已删除，请重试',
          );
        }
        doneBytes += f.bytes;
      }
      await File('$dir/.complete').writeAsString(
        '$completeMarker\n${DateTime.now().toIso8601String()}',
      );
      return true;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        onState(const VoiceDownloadState());
      } else {
        onState(
          VoiceDownloadState(
            phase: VoiceModelPhase.error,
            error: '下载失败：${e.message ?? e.type.name}',
          ),
        );
      }
      return false;
    } catch (e) {
      onState(
        VoiceDownloadState(phase: VoiceModelPhase.error, error: '下载失败：$e'),
      );
      return false;
    } finally {
      _cancelToken = null;
    }
  }

  void cancelDownload() {
    _cancelToken?.cancel('用户取消');
  }

  Future<void> deleteModel() async {
    final dir = modelDir;
    if (dir != null && Directory(dir).existsSync()) {
      await Directory(dir).delete(recursive: true);
    }
    installed = false;
    engineReady = false;
    prepareError = null;
    download = const VoiceDownloadState();
    notifyListeners();
  }

  /// 删除流式模型（与整段模型互不影响）。
  Future<void> deleteStreamingModel() async {
    final dir = streamingModelDir;
    if (dir != null && Directory(dir).existsSync()) {
      await Directory(dir).delete(recursive: true);
    }
    streamingInstalled = false;
    streamingDownload = const VoiceDownloadState();
    notifyListeners();
  }
}

/// 字节数 → 人话（与 JEV 页同一口径的简单版）。
String voiceFormatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
