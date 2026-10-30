import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

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

// ------------------------------------------ 内置流式模型（B1，2026-10-30）
//
// ★ **流式语音开箱即用的默认模型 = 内置的 14M 中文 streaming zipformer**
// （HF 仓库 `csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23`，
// Apache-2.0；体积 ≈24.2MiB，打进 APK assets，**无需下载**）。
//
// 为什么换成内置小模型（2026-10-30 用户拍板 B1）：
// 上一版默认用 200MB 中英双语模型 + `startStreamingDownload()`，但设置页
// 从来没有流式模型的下载入口 ⇒ `streamingInstalled` 永远是 false ⇒ 语音
// 永远回退整段识别，"边说边出字"形同不存在。内置 14M 中文模型后，全新安装
// **第一次点麦克风**即自动解压可用（断网也可用；音频仍绝不上云）。
//
// 旧的 200MB 中英双语模型**降级为可选高精度模型**：下载 API 保留、绝不作为
// 使用前提（默认用内置；老用户已下载过的仍可被选中，见
// [VoiceModelController.activeStreamingModel]）。
//
// 卸载即删：模型解压到 `<appFilesDir>/voice_models/...`（App 私有目录），
// 卸载 App 时随数据一起删除，不会在用户存储里留垃圾。
//
// 资产校验：下面四个字节数是 2026-10-30 从上面 HF 仓库**实测下载**后写死的；
// 运行期按字节数逐个校验（不一致就重试解压，不崩）。下载时 sha256（留档）：
// · encoder-epoch-99-avg-1.int8.onnx 21,621,684  1C556EA5…126487B1
// · decoder-epoch-99-avg-1.int8.onnx  1,888,682  22F123BB…8C468BBF
// · joiner-epoch-99-avg-1.int8.onnx   1,795,562  A7CF9D82…75C36169
// · tokens.txt                           48,697  8B294DB9…8FF966AC

/// 内置模型的 asset 目录（pubspec 声明的这一整个目录）。
const kBundledStreamingAssetDir =
    'assets/voice/streaming-zipformer-zh-14m';

/// 内置模型解压到的子目录名（与 SenseVoice / 旧双语模型都分开）。
const kBundledStreamingDirName = 'streaming-zipformer-zh-14m';

/// 内置模型的 `.complete` 标识。
const kBundledStreamingMarker = 'streaming-zipformer-zh-14m-int8';

const kBundledStreamingEncoderName = 'encoder-epoch-99-avg-1.int8.onnx';
const kBundledStreamingDecoderName = 'decoder-epoch-99-avg-1.int8.onnx';
const kBundledStreamingJoinerName = 'joiner-epoch-99-avg-1.int8.onnx';
const kBundledStreamingTokensName = 'tokens.txt';

const kBundledStreamingModelFiles = <VoiceModelFile>[
  VoiceModelFile(kBundledStreamingEncoderName, 21621684),
  VoiceModelFile(kBundledStreamingDecoderName, 1888682),
  VoiceModelFile(kBundledStreamingJoinerName, 1795562),
  VoiceModelFile(kBundledStreamingTokensName, 48697),
];

int get kBundledStreamingModelTotalBytes =>
    kBundledStreamingModelFiles.fold(0, (sum, f) => sum + f.bytes);

/// 目录里是否「`.complete` 在 + 每个文件字节数精确对上」。
bool voiceModelDirComplete(String? dir, List<VoiceModelFile> files) {
  if (dir == null || !File('$dir/.complete').existsSync()) return false;
  for (final f in files) {
    final file = File('$dir/${f.name}');
    if (!file.existsSync() || file.lengthSync() != f.bytes) return false;
  }
  return true;
}

/// 把内置资产模型**幂等**解压（拷贝）到 [dir]。
///
/// · 目录已完整 ⇒ 直接返回，**不读资产**（二次调用零 IO）；
/// · 逐文件先写 `<name>.tmp` 再 rename ⇒ 半成品不会被当成完整；
/// · 已存在且字节正确的文件**跳过**（失败重试只补缺的）；
/// · 任一资产字节数不符/读不到 ⇒ 抛 [StateError]（调用方 catch 后置错误、
///   允许重试），并清掉本次的 `.tmp`，不留半个"完成标记"。
///
/// 纯文件 + 加载器逻辑（不碰 Flutter 状态），便于单测注入小文件。
Future<void> extractBundledModel({
  required String dir,
  required List<VoiceModelFile> files,
  required String completeMarker,
  required String assetDir,
  required Future<Uint8List> Function(String assetKey) loadAsset,
}) async {
  if (voiceModelDirComplete(dir, files)) return;
  final directory = Directory(dir);
  if (!directory.existsSync()) await directory.create(recursive: true);
  // 标记在但字节不对（半成品/旧版本残留）⇒ 先删标记，避免被误判完整。
  final marker = File('$dir/.complete');
  if (marker.existsSync()) await marker.delete();
  final tmpFiles = <File>[];
  try {
    for (final f in files) {
      final existing = File('$dir/${f.name}');
      if (existing.existsSync() && existing.lengthSync() == f.bytes) continue;
      final bytes = await loadAsset('$assetDir/${f.name}');
      if (bytes.length != f.bytes) {
        throw StateError(
          '${f.name} 内置资产字节数不对（应为 ${f.bytes}，实际 ${bytes.length}）',
        );
      }
      final tmp = File('$dir/${f.name}.tmp');
      tmpFiles.add(tmp);
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename('$dir/${f.name}');
    }
    await marker.writeAsString(
      '$completeMarker\n${DateTime.now().toIso8601String()}',
    );
  } catch (_) {
    for (final tmp in tmpFiles) {
      try {
        if (tmp.existsSync()) await tmp.delete();
      } catch (_) {}
    }
    rethrow;
  }
}



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

/// 一套**可用的流式模型**路径（[bundled] = 内置 14M 中文模型；
/// false = 用户手动下载的可选 200MB 中英双语模型）。
class StreamingModelPaths {
  const StreamingModelPaths({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
    required this.bundled,
  });

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
  final bool bundled;

  /// 人话标签（诊断/日志用，不打印识别正文）。
  String get label => bundled ? '内置 14M 中文流式模型' : '可选下载的中英双语流式模型';
}

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

  /// **流式模型**（§N13.4）是否可用（内置 14M 已解压 **或** 可选下载已完整）。
  bool streamingInstalled = false;

  /// **内置 14M 中文流式模型**是否已解压到 filesDir（首次使用自动解压）。
  bool bundledStreamingReady = false;

  /// 内置模型解压失败的人话原因（null = 没失败过；失败可重试）。
  String? bundledStreamingError;

  /// 并发保护：同一时刻只解压一次；完成后置回 null（失败允许重试）。
  Future<bool>? _ensureFuture;

  /// 测试注入（生产 = `rootBundle` + 常量）：资产加载器 / 文件清单 / 资产目录。
  @visibleForTesting
  static Future<Uint8List> Function(String assetKey)? bundledAssetLoaderForTest;
  @visibleForTesting
  static List<VoiceModelFile>? bundledModelFilesForTest;
  @visibleForTesting
  static String? bundledAssetDirForTest;

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

  // ------------------------------------------------ 内置 14M 中文流式模型

  List<VoiceModelFile> get _bundledFiles =>
      bundledModelFilesForTest ?? kBundledStreamingModelFiles;

  /// 内置模型解压目录（与 SenseVoice / 旧双语模型都**平级、互不覆盖**）。
  String? get bundledStreamingModelDir {
    final root = profile?.appFilesDir ?? '';
    if (root.isEmpty) return null;
    return '$root/voice_models/$kBundledStreamingDirName';
  }

  String? _bundledFile(String name) {
    final dir = bundledStreamingModelDir;
    return dir == null ? null : '$dir/$name';
  }

  String? get bundledStreamingEncoderPath =>
      _bundledFile(kBundledStreamingEncoderName);
  String? get bundledStreamingDecoderPath =>
      _bundledFile(kBundledStreamingDecoderName);
  String? get bundledStreamingJoinerPath =>
      _bundledFile(kBundledStreamingJoinerName);
  String? get bundledStreamingTokensPath =>
      _bundledFile(kBundledStreamingTokensName);

  /// 当前**实际可用**的流式模型：**内置 14M 优先**，其次可选下载的
  /// 200MB 中英双语模型（老用户手动下过才可能存在）。null = 都不可用。
  StreamingModelPaths? get activeStreamingModel {
    if (bundledStreamingReady) {
      final encoder = bundledStreamingEncoderPath;
      final decoder = bundledStreamingDecoderPath;
      final joiner = bundledStreamingJoinerPath;
      final tokens = bundledStreamingTokensPath;
      if (encoder != null &&
          decoder != null &&
          joiner != null &&
          tokens != null) {
        return StreamingModelPaths(
          encoder: encoder,
          decoder: decoder,
          joiner: joiner,
          tokens: tokens,
          bundled: true,
        );
      }
    }
    if (voiceModelDirComplete(streamingModelDir, kStreamingVoiceModelFiles)) {
      return StreamingModelPaths(
        encoder: streamingEncoderPath!,
        decoder: streamingDecoderPath!,
        joiner: streamingJoinerPath!,
        tokens: streamingTokensPath!,
        bundled: false,
      );
    }
    return null;
  }

  /// **首次使用前确保内置流式模型已解压**（幂等、可重试、不抛）。
  ///
  /// 并发调用**只解压一次**（共享同一个 Future）；失败返回 false 并记录
  /// [bundledStreamingError]，下一次调用会重试。
  Future<bool> ensureStreamingReady() {
    if (bundledStreamingReady) return Future.value(true);
    final inflight = _ensureFuture;
    if (inflight != null) return inflight;
    final future = _extractBundledStreaming();
    _ensureFuture = future.whenComplete(() {
      _ensureFuture = null;
    });
    return _ensureFuture!;
  }

  Future<bool> _extractBundledStreaming() async {
    try {
      profile ??= await AgentBridge().deviceProfile();
      final dir = bundledStreamingModelDir;
      if (dir == null) {
        bundledStreamingReady = false;
        bundledStreamingError = '拿不到本机存储目录（宿主未返回 deviceProfile）';
        notifyListeners();
        return false;
      }
      final files = _bundledFiles;
      await extractBundledModel(
        dir: dir,
        files: files,
        completeMarker: kBundledStreamingMarker,
        assetDir: bundledAssetDirForTest ?? kBundledStreamingAssetDir,
        loadAsset: bundledAssetLoaderForTest ?? _loadBundledAsset,
      );
      bundledStreamingReady = voiceModelDirComplete(dir, files);
      bundledStreamingError =
          bundledStreamingReady ? null : '内置流式模型解压后校验不通过';
    } catch (e) {
      bundledStreamingReady = false;
      bundledStreamingError = '内置流式模型解压失败：$e';
    }
    refreshInstalled();
    notifyListeners();
    return bundledStreamingReady;
  }

  static Future<Uint8List> _loadBundledAsset(String assetKey) async {
    final data = await rootBundle.load(assetKey);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

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
  ///
  /// 流式侧分两套（B1，2026-10-30）：**内置 14M 中文模型**已解压，或
  /// **可选下载**的 200MB 中英双语模型已完整 —— 任一可用即
  /// [streamingInstalled] = true（默认用内置，见 [activeStreamingModel]）。
  void refreshInstalled() {
    final dir = modelDir;
    installed = voiceModelDirComplete(dir, kVoiceModelFiles);
    bundledStreamingReady =
        voiceModelDirComplete(bundledStreamingModelDir, _bundledFiles);
    final downloadedStreaming =
        voiceModelDirComplete(streamingModelDir, kStreamingVoiceModelFiles);
    streamingInstalled = bundledStreamingReady || downloadedStreaming;
    if (installed && download.phase != VoiceModelPhase.downloading) {
      download = const VoiceDownloadState(phase: VoiceModelPhase.done);
    }
    if (downloadedStreaming &&
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
