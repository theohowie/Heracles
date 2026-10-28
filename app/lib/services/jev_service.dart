import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/jev.dart';
import '../models/settings.dart';
import 'agent_bridge.dart';
import 'settings_controller.dart';

/// **JEV 决策引擎的前端服务层**（2026-10-27）。
///
/// 分工：配置与历史落盘（本文件）、云端决策（[/v1/systemone] 兼容
/// 接口，本文件）、理由补写（借当前对话模型，本文件）、本地模型
/// 下载管理（本文件）；**本地推理**不在前端 —— GGUF 决策模型需要
/// 双向注意力＋选项字母读出的专用引擎，契约预留在
/// [AgentBridge.jevLocalDecide]，等宿主/后端接入。
class JevException implements Exception {
  JevException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 配置与历史的落盘（SharedPreferences + 安全存储）。
abstract final class JevStore {
  static const _kConfig = 'jevConfig';
  static const _kHistory = 'jevHistory';
  static const _secure = SecureKeyStore();

  /// 云端密钥在安全存储里的条目名（与提供商密钥同一套存储）。
  static const cloudKeyId = 'jev-cloud';

  static Future<JevConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kConfig);
    if (raw == null || raw.isEmpty) return const JevConfig();
    try {
      return JevConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const JevConfig();
    }
  }

  static Future<void> saveConfig(JevConfig c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kConfig, jsonEncode(c.toJson()));
  }

  static Future<List<JevDecision>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kHistory);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return [
        for (final e in list) JevDecision.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveHistory(List<JevDecision> history) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kHistory,
      jsonEncode([for (final d in history) d.toJson()]),
    );
  }

  static Future<String> readCloudKey() => _secure.read(cloudKeyId);
  static Future<void> writeCloudKey(String key) =>
      _secure.write(cloudKeyId, key);
}

/// 云端决策客户端 —— `/v1/systemone` 兼容接口（Jev 官方 /
/// StartLux 云端 / 自建 startlux-decide 三者同一报文）。
abstract final class JevCloudClient {
  /// 由配置的地址推出请求端点：地址填到 `/v1` 为止时补
  /// `/systemone`；已是完整 `/decisions` 地址（如 bamboonode
  /// 免费托管）时原样使用。
  static String endpointFor(String baseUrl) {
    var b = baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/decisions') || b.endsWith('/systemone')) return b;
    return '$b/systemone';
  }

  /// 问一次是非题。返回「是」的概率、模型自带思考（AutoThink 才有）
  /// 与服务端回报的模型名。
  static Future<({double yesProb, String? thought, String model})> decide({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String question,
  }) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 90),
        sendTimeout: const Duration(seconds: 20),
        responseType: ResponseType.json,
      ),
    );
    final Response<dynamic> resp;
    try {
      resp = await dio.post<dynamic>(
        endpointFor(baseUrl),
        data: {
          'state': {'question': question},
          'questions': {
            'recommend': {'type': 'noul', 'instructions': '推荐用户这样做吗？'},
          },
          // AutoThink 模型不确定时会先写一段思考 —— 要回来当理由。
          'return_thought': true,
          if (model.trim().isNotEmpty) 'model': model.trim(),
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            if (apiKey.trim().isNotEmpty)
              'Authorization': 'Bearer ${apiKey.trim()}',
          },
        ),
      );
    } on DioException catch (e) {
      throw JevException(_humanizeHttpError(e));
    }
    final data = resp.data;
    if (data is! Map) {
      throw JevException('决策服务返回了无法理解的内容。');
    }
    final answers = data['answers'];
    if (answers is! Map) {
      throw JevException('决策服务没有返回 answers 字段。');
    }
    final a = answers['recommend'];
    if (a is! Map || a['noul'] is! num) {
      throw JevException('决策服务没有给出是非判断（noul）。');
    }
    final thought = a['thought'];
    return (
      yesProb: (a['noul'] as num).toDouble().clamp(0.0, 1.0),
      thought: (thought is String && thought.trim().isNotEmpty)
          ? thought.trim()
          : null,
      model: data['model'] as String? ?? '',
    );
  }

  static String _humanizeHttpError(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) {
      return '决策服务拒绝了密钥（$code）—— 检查 JEV 配置里的 API 密钥。';
    }
    if (code == 404) {
      return '接口地址不对（404）—— 地址填到 /v1 为止，或填完整的 /v1/decisions 地址。';
    }
    if (code != null) return '决策服务出错（HTTP $code）。';
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout => '决策服务超时 —— 检查网络或换个接口地址。',
      DioExceptionType.connectionError => '连不上决策服务 —— 检查接口地址与网络。',
      _ => '决策请求失败：${e.message ?? e.type.name}',
    };
  }
}

/// **理由补写** —— 决策模型只给结论与概率，理由由当前对话模型
/// 写一到两句。没有可用的对话模型时返回 null（界面只显示概率，
/// 不编理由）。
abstract final class JevReasoner {
  static Future<String?> reason({
    required AppSettings settings,
    required String question,
    required bool recommended,
    required double confidence,
  }) async {
    final p = settings.effectiveProvider;
    if (p == null || p.baseUrl.trim().isEmpty || p.model.trim().isEmpty) {
      return null;
    }
    final prompt =
        '用户在纠结一件事：「$question」\n'
        '决策结论是：${recommended ? '推荐' : '不推荐'}'
        '（置信度 ${(confidence * 100).round()}%）。\n'
        '请用一到两句话给出理由，像朋友一样直接、具体，结合这件事本身；'
        '不要重复结论，不要提「决策」或「模型」，只输出理由本身。';
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 45),
        responseType: ResponseType.json,
      ),
    );
    var base = p.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    try {
      final String? text = switch (p.protocol) {
        ProviderProtocol.openaiChat => await _openAiChat(dio, base, p, prompt),
        ProviderProtocol.anthropic => await _anthropic(dio, base, p, prompt),
        ProviderProtocol.openaiResponses => await _openAiResponses(
          dio,
          base,
          p,
          prompt,
        ),
      };
      if (text == null) return null;
      final cleaned = text.trim().replaceAll(RegExp(r'^["「『]|["」』]$'), '');
      return cleaned.isEmpty ? null : cleaned;
    } catch (_) {
      // 理由是锦上添花：补写失败就安静地没有理由，绝不拖垮决策本身。
      return null;
    }
  }

  static Future<String?> _openAiChat(
    Dio dio,
    String base,
    ModelProviderConfig p,
    String prompt,
  ) async {
    final resp = await dio.post<dynamic>(
      '$base/chat/completions',
      data: {
        'model': p.model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
        'max_tokens': 220,
        'temperature': 0.5,
      },
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          if (p.apiKey.isNotEmpty) 'Authorization': 'Bearer ${p.apiKey}',
        },
      ),
    );
    final choices = (resp.data as Map?)?['choices'];
    if (choices is List && choices.isNotEmpty) {
      final msg = (choices.first as Map?)?['message'];
      final content = (msg as Map?)?['content'];
      if (content is String) return content;
    }
    return null;
  }

  static Future<String?> _anthropic(
    Dio dio,
    String base,
    ModelProviderConfig p,
    String prompt,
  ) async {
    final resp = await dio.post<dynamic>(
      '$base/messages',
      data: {
        'model': p.model,
        'max_tokens': 220,
        'temperature': 0.5,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      },
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          'anthropic-version': '2023-06-01',
          if (p.apiKey.isNotEmpty) 'x-api-key': p.apiKey,
        },
      ),
    );
    final content = (resp.data as Map?)?['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map && block['type'] == 'text') {
          final t = block['text'];
          if (t is String) return t;
        }
      }
    }
    return null;
  }

  static Future<String?> _openAiResponses(
    Dio dio,
    String base,
    ModelProviderConfig p,
    String prompt,
  ) async {
    final resp = await dio.post<dynamic>(
      '$base/responses',
      data: {'model': p.model, 'input': prompt, 'max_output_tokens': 220},
      options: Options(
        headers: {
          'Content-Type': 'application/json',
          if (p.apiKey.isNotEmpty) 'Authorization': 'Bearer ${p.apiKey}',
        },
      ),
    );
    final data = resp.data as Map?;
    final direct = data?['output_text'];
    if (direct is String) return direct;
    final output = data?['output'];
    if (output is List) {
      for (final item in output) {
        final content = (item as Map?)?['content'];
        if (content is List) {
          for (final c in content) {
            if (c is Map && c['type'] == 'output_text') {
              final t = c['text'];
              if (t is String) return t;
            }
          }
        }
      }
    }
    return null;
  }
}

enum JevDownloadPhase { idle, downloading, done, error }

class JevDownloadState {
  const JevDownloadState({
    this.phase = JevDownloadPhase.idle,
    this.received = 0,
    this.total = 0,
    this.note,
    this.error,
  });

  final JevDownloadPhase phase;
  final int received;
  final int total;

  /// 阶段说明（如「正在下载配置文件」）。
  final String? note;
  final String? error;

  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

/// **JEV 控制器**（App 级单例）—— 配置、历史、本机画像、下载与
/// 提问的统一状态源；决策页与配置页共用同一实例（下载不因切页中断）。
class JevController extends ChangeNotifier {
  JevController._();

  static final JevController _shared = JevController._();
  factory JevController.shared() => _shared;

  JevConfig config = const JevConfig();
  List<JevDecision> history = const [];
  JevDeviceProfile? profile;
  bool loaded = false;
  bool busy = false;
  String? lastError;

  final Map<JevSource, JevDownloadState> downloads = {};
  final Map<JevSource, CancelToken> _cancelTokens = {};

  /// 已下载完成的档位（以 `.complete` 标记文件为准，进页面时刷新）。
  final Set<JevSource> downloaded = {};

  JevDecision? get latest => history.isEmpty ? null : history.first;

  JevRecommendation? get recommendation =>
      profile == null ? null : recommendJev(profile!);

  Future<void> load() async {
    config = await JevStore.loadConfig();
    history = await JevStore.loadHistory();
    profile ??= await AgentBridge().deviceProfile();
    refreshDownloaded();
    loaded = true;
    notifyListeners();
  }

  Future<void> reloadProfile() async {
    profile = await AgentBridge().deviceProfile();
    refreshDownloaded();
    notifyListeners();
  }

  Future<void> updateConfig(JevConfig next) async {
    config = next;
    await JevStore.saveConfig(next);
    notifyListeners();
  }

  // ------------------------------------------------------------ 本地模型文件

  String? modelDirFor(JevModelSpec spec) {
    final root = profile?.appFilesDir ?? '';
    if (root.isEmpty) return null;
    return '$root/jev_models/${spec.dirName}';
  }

  void refreshDownloaded() {
    downloaded.clear();
    for (final spec in kJevModelSpecs) {
      final dir = modelDirFor(spec);
      if (dir == null) continue;
      if (File('$dir/.complete').existsSync()) {
        downloaded.add(spec.source);
        downloads[spec.source] = const JevDownloadState(
          phase: JevDownloadPhase.done,
        );
      }
    }
  }

  bool isDownloaded(JevSource source) => downloaded.contains(source);

  static const _hosts = ['https://hf-mirror.com', 'https://huggingface.co'];

  /// 下载一档本地模型：GGUF 权重 + BF16 仓库的 tokenizer/配置文件
  /// （本地引擎读出要用，GGUF 本身不带）。先镜像后官方源。
  Future<void> startDownload(JevModelSpec spec) async {
    final dir = modelDirFor(spec);
    if (dir == null) {
      downloads[spec.source] = JevDownloadState(
        phase: JevDownloadPhase.error,
        error: '拿不到本机存储目录（宿主未返回 deviceProfile）。',
      );
      notifyListeners();
      return;
    }
    if (downloads[spec.source]?.phase == JevDownloadPhase.downloading) {
      return;
    }
    final token = CancelToken();
    _cancelTokens[spec.source] = token;
    downloads[spec.source] = JevDownloadState(
      phase: JevDownloadPhase.downloading,
      total: spec.approxBytes,
      note: '正在下载权重',
    );
    notifyListeners();

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 30),
      ),
    );
    try {
      await Directory(dir).create(recursive: true);
      // ① 权重（占进度的绝大部分）
      await _downloadWithFallback(
        dio,
        spec.ggufRepo,
        spec.ggufFile,
        '$dir/${spec.ggufFile}',
        token,
        onProgress: (received, total) {
          downloads[spec.source] = JevDownloadState(
            phase: JevDownloadPhase.downloading,
            received: received,
            total: total > 0 ? total : spec.approxBytes,
            note: '正在下载权重',
          );
          notifyListeners();
        },
      );
      // ② 配置文件（从 BF16 仓库清单里挑非权重文件）
      downloads[spec.source] = JevDownloadState(
        phase: JevDownloadPhase.downloading,
        received: spec.approxBytes,
        total: spec.approxBytes,
        note: '正在下载配置文件',
      );
      notifyListeners();
      await _downloadConfigFiles(dio, spec, dir, token);
      // ③ 完成标记
      await File(
        '$dir/.complete',
      ).writeAsString('${spec.ggufFile}\n${DateTime.now().toIso8601String()}');
      downloaded.add(spec.source);
      downloads[spec.source] = const JevDownloadState(
        phase: JevDownloadPhase.done,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        downloads[spec.source] = const JevDownloadState();
        // 半截权重留着只会占空间且会被误判，清掉。
        final partial = File('$dir/${spec.ggufFile}');
        if (partial.existsSync()) await partial.delete();
      } else {
        downloads[spec.source] = JevDownloadState(
          phase: JevDownloadPhase.error,
          error: '下载失败：${e.message ?? e.type.name}',
        );
      }
    } catch (e) {
      downloads[spec.source] = JevDownloadState(
        phase: JevDownloadPhase.error,
        error: '下载失败：$e',
      );
    } finally {
      _cancelTokens.remove(spec.source);
      notifyListeners();
    }
  }

  Future<void> _downloadWithFallback(
    Dio dio,
    String repo,
    String file,
    String savePath,
    CancelToken token, {
    void Function(int received, int total)? onProgress,
  }) async {
    Object? lastError;
    for (final host in _hosts) {
      try {
        await dio.download(
          '$host/$repo/resolve/main/$file',
          savePath,
          cancelToken: token,
          onReceiveProgress: onProgress,
        );
        return;
      } catch (e) {
        lastError = e;
        if (token.isCancelled) rethrow;
      }
    }
    throw lastError ?? StateError('下载失败');
  }

  Future<void> _downloadConfigFiles(
    Dio dio,
    JevModelSpec spec,
    String dir,
    CancelToken token,
  ) async {
    Object? lastError;
    for (final host in _hosts) {
      try {
        final resp = await dio.get<dynamic>(
          '$host/api/models/${spec.configRepo}?blobs=true',
          cancelToken: token,
        );
        final siblings = (resp.data as Map?)?['siblings'];
        if (siblings is! List) throw StateError('配置清单格式不对');
        for (final s in siblings) {
          if (s is! Map) continue;
          final name = s['rfilename'] as String?;
          final size = (s['size'] as num?)?.toInt() ?? 0;
          if (name == null || name.isEmpty) continue;
          if (name.contains('safetensors') || name == '.gitattributes') {
            continue;
          }
          // 只下小文件（tokenizer/配置）；大文件一律跳过 —— 权重已单独下。
          if (size > 25 * 1024 * 1024) continue;
          await dio.download(
            '$host/${spec.configRepo}/resolve/main/$name',
            '$dir/$name',
            cancelToken: token,
          );
        }
        return;
      } catch (e) {
        lastError = e;
        if (token.isCancelled) rethrow;
      }
    }
    throw lastError ?? StateError('配置文件下载失败');
  }

  void cancelDownload(JevSource source) {
    _cancelTokens[source]?.cancel('用户取消');
  }

  Future<void> deleteModel(JevModelSpec spec) async {
    final dir = modelDirFor(spec);
    if (dir != null && Directory(dir).existsSync()) {
      await Directory(dir).delete(recursive: true);
    }
    downloaded.remove(spec.source);
    downloads[spec.source] = const JevDownloadState();
    notifyListeners();
  }

  // ------------------------------------------------------------ 提问

  /// 问一次决策。成功返回记录；失败把原因写进 [lastError] 并返回
  /// null —— **绝不假装给出了决策**。
  Future<JevDecision?> ask(String question, AppSettings settings) async {
    if (busy) return null;
    busy = true;
    lastError = null;
    notifyListeners();
    final sw = Stopwatch()..start();
    try {
      final double yesProb;
      final String? thought;
      final String engineLabel;
      switch (config.source) {
        case JevSource.cloud:
          if (!config.cloudReady) {
            throw JevException('云端还没配置：先去 JEV 配置里填接口地址。');
          }
          final key = await JevStore.readCloudKey();
          final r = await JevCloudClient.decide(
            baseUrl: config.cloudBaseUrl,
            apiKey: key,
            model: config.cloudModel,
            question: question,
          );
          yesProb = r.yesProb;
          thought = r.thought;
          engineLabel = r.model.isEmpty ? '云端' : '云端 · ${r.model}';
        case JevSource.local08 || JevSource.local2b:
          final spec = jevSpecFor(config.source)!;
          final dir = modelDirFor(spec) ?? '';
          final p = await AgentBridge().jevLocalDecide(
            modelDir: dir,
            question: question,
          );
          if (p == null) {
            throw JevException(
              isDownloaded(config.source)
                  ? '本地模型已下载好，但本地推理引擎还没接入（决策模型需要'
                        '双向注意力＋选项读出的专用引擎，在后端接入中）。'
                        '先切到云端就能体验决策。'
                  : '本地模型还没下载：先去 JEV 配置里下载 ${spec.displayName}。',
            );
          }
          yesProb = p;
          thought = null;
          engineLabel = spec.source.label;
      }
      sw.stop();

      var reason = thought;
      var reasonSource = thought != null
          ? JevReasonSource.modelThought
          : JevReasonSource.none;
      if (reason == null && config.reasonEnabled) {
        reason = await JevReasoner.reason(
          settings: settings,
          question: question,
          recommended: yesProb >= 0.5,
          confidence: yesProb >= 0.5 ? yesProb : 1 - yesProb,
        );
        if (reason != null) reasonSource = JevReasonSource.llm;
      }

      final decision = JevDecision(
        id: 'j${DateTime.now().millisecondsSinceEpoch}',
        question: question,
        yesProb: yesProb,
        engineLabel: engineLabel,
        elapsedMs: sw.elapsedMilliseconds,
        createdAt: DateTime.now(),
        reason: reason,
        reasonSource: reasonSource,
      );
      history = [decision, ...history].take(200).toList();
      await JevStore.saveHistory(history);
      return decision;
    } on JevException catch (e) {
      lastError = e.message;
      return null;
    } catch (e) {
      lastError = '决策失败：$e';
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> clearHistory() async {
    history = const [];
    await JevStore.saveHistory(history);
    notifyListeners();
  }

  void dismissError() {
    lastError = null;
    notifyListeners();
  }
}

/// 字节数 → 人类可读（下载进度/模型大小共用）。
String jevFormatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
