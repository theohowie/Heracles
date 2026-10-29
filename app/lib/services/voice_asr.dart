import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_service.dart';

/// **离线语音识别**（sherpa-onnx × SenseVoiceSmall，2026-10-29）。
///
/// 模型文件由 [VoiceModelController] 下载并备好产物
/// （model_sherpa.onnx + tokens.txt）；这里只负责加载识别器、
/// 把宿主录好的 WAV 解成文本。识别器常驻复用：加载 241MB
/// 模型要几秒，不能每次点麦克风都重来；模型目录变了
/// （删了重下）按路径+大小重建。
///
/// 解码在当前 isolate 同步跑：点麦克风的语句一般几秒长，
/// 解码 1~3 秒可接受；真出现长录音卡顿再考虑搬 isolate
/// （sherpa 的绑定按 isolate 初始化，搬家要整套重做）。
class VoiceAsr {
  VoiceAsr._();

  static sherpa.OfflineRecognizer? _recognizer;
  static String? _recognizerKey;
  static bool _bindingsReady = false;

  /// 把一个 16kHz PCM16 WAV 文件识别成文本。
  /// 模型没备好 / 文件读不出 → 抛 [StateError] 带人话原因。
  static Future<String> transcribeWav(String wavPath) async {
    final voice = VoiceModelController.shared();
    if (!voice.engineReady) {
      throw StateError('语音模型还没准备好');
    }
    final modelPath = voice.sherpaModelPath!;
    final tokensPath = voice.tokensTxtPath!;
    final key = '$modelPath|${File(modelPath).lengthSync()}';
    if (_recognizer == null || _recognizerKey != key) {
      _recognizer?.free();
      _recognizer = null;
      _recognizerKey = null;
      if (!_bindingsReady) {
        sherpa.initBindings();
        _bindingsReady = true;
      }
      _recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            senseVoice: sherpa.OfflineSenseVoiceModelConfig(
              model: modelPath,
              // auto = 语种自动判别；ITN 开 = 数字/标点规整
              // （「九点」→「9点」并补句末标点，桌面实测口径）。
              language: 'auto',
              useInverseTextNormalization: true,
            ),
            tokens: tokensPath,
            numThreads: 2,
            debug: false,
          ),
          decodingMethod: 'greedy_search',
        ),
      );
      _recognizerKey = key;
    }

    final bytes = await File(wavPath).readAsBytes();
    final (samples, sampleRate) = decodeWavPcm16(bytes);
    if (samples.isEmpty) {
      throw StateError('录音是空的');
    }
    final stream = _recognizer!.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      _recognizer!.decode(stream);
      final result = _recognizer!.getResult(stream);
      return result.text.trim();
    } finally {
      stream.free();
    }
  }
}

/// WAV（PCM16）→ Float32 采样（-1..1）+ 采样率。
/// 通用 RIFF 解析：找 fmt / data 块；多声道按均值混成单声道；
/// 位深不是 16 或编码不是 PCM → 抛 [FormatException]。
(Float32List, int) decodeWavPcm16(Uint8List bytes) {
  if (bytes.length < 44 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('不是 WAV 文件');
  }
  final view = ByteData.sublistView(bytes);
  var audioFormat = 1;
  var channels = 1;
  var sampleRate = 16000;
  var bitsPerSample = 16;
  var dataOffset = -1;
  var dataLength = 0;
  var pos = 12;
  while (pos + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final size = view.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      audioFormat = view.getUint16(body, Endian.little);
      channels = view.getUint16(body + 2, Endian.little);
      sampleRate = view.getUint32(body + 4, Endian.little);
      bitsPerSample = view.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataOffset = body;
      dataLength = size;
      break;
    }
    pos = body + size + (size.isOdd ? 1 : 0);
  }
  if (dataOffset < 0) throw const FormatException('WAV 里没有 data 块');
  if (audioFormat != 1 || bitsPerSample != 16) {
    throw FormatException('只支持 PCM16 WAV（format=$audioFormat, bits=$bitsPerSample）');
  }
  final frames = dataLength ~/ (2 * channels);
  final out = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      sum += view.getInt16(dataOffset + (i * channels + c) * 2, Endian.little);
    }
    out[i] = (sum / channels) / 32768.0;
  }
  return (out, sampleRate);
}
