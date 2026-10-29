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
  JevException(this.message, {this.diagnostics});

  /// 人话原因（**绝不含 API Key / 完整请求 URL** —— 只允许脱敏后的
  /// URL 与状态码，见 [JevCloudClient.sanitizeUrl]）。
  final String message;

  /// 失败时的可诊断快照（本地配置错误等没发请求的情况为 null）。
  final JevDiagnostics? diagnostics;

  @override
  String toString() => message;
}

/// **端点解析结果**（可诊断）。
///
/// [explicit] = 用户填的就是完整端点（`/decision` `/decisions`
/// `/systemone` 结尾），客户端原样使用；否则由客户端补段，[hint]
/// 说明补了什么、推荐填什么。裸域名（没写到 `/v1`）**不再静默**
/// 补 `/systemone` —— 行为固定，但必须带 hint。
class JevEndpointResolution {
  const JevEndpointResolution({
    required this.url,
    required this.explicit,
    this.hint,
  });

  /// 实际请求的端点（原文，可能带 query —— 诊断里请用
  /// [JevCloudClient.sanitizeUrl] 再输出）。
  final String url;

  /// 地址本身就是完整端点，客户端没有补段。
  final bool explicit;

  /// 补段/异常时的说明（用户该怎么填）。
  final String? hint;
}

/// **一次云端决策调用（含重试）的可诊断快照**。
///
/// 字段与 `docs/INTERFACE.md §N11` 对齐：
/// `{resolvedEndpoint, httpStatus, serverCode, serverMessage, traceId,
/// rawBody(≤2KB, 脱敏), elapsedMs, modelCorrected, hint}`；另附
/// [attempts] / [retriedAfter422] / [modelsCatalogReadable] /
/// [transportError] 供排障。
///
/// ★ 安全：这里的一切都可能进错误信息/日志，所以
/// [resolvedEndpoint] 只留 scheme+host+port+path，[rawBody] 只留
/// 2KB 且先脱敏；API Key 只出现在请求头。
class JevDiagnostics {
  const JevDiagnostics({
    required this.resolvedEndpoint,
    required this.httpStatus,
    required this.serverCode,
    required this.serverMessage,
    required this.traceId,
    required this.rawBody,
    required this.elapsedMs,
    required this.modelCorrected,
    required this.hint,
    this.attempts = 1,
    this.retriedAfter422 = false,
    this.modelsCatalogReadable = false,
    this.transportError,
  });

  /// 脱敏 URL（scheme://host[:port]/path，**query 与 fragment 一律
  /// 丢弃** —— 密钥可能被用户填在 query 里）。
  final String resolvedEndpoint;

  /// HTTP 状态码；连不上/超时等没拿到响应时为 null。
  final int? httpStatus;

  /// 服务端错误码：`body.code`，缺失时取 `body.serverCode`。
  final String? serverCode;

  /// 服务端人话：`body.serverMessage`，缺失时取 `body.message`。
  final String? serverMessage;

  /// 排障用（文档要求原样保留）。
  final String? traceId;

  /// 响应原文（脱敏后 ≤ [JevCloudClient.rawBodyLimit] 字节）。
  final String rawBody;

  /// 从发起第一次请求到拿到最终响应的耗时（含重试）。
  final int elapsedMs;

  /// 用户填的模型不是固定 ID `NeoHorse-Jev-4B`，已被强制纠正。
  final bool modelCorrected;

  /// 给用户看的下一步提示（可为 null）。
  final String? hint;

  /// 实际发出的请求次数（422 会重试一次，故为 1 或 2）。
  final int attempts;

  /// 这次成功/失败是「首次 422 → 重试」之后的第二次尝试。
  final bool retriedAfter422;

  /// 决策前模型目录是否已成功读取（决定 422 的 hint 措辞）。
  final bool modelsCatalogReadable;

  /// 传输层错误类型（`DioExceptionType.name`）；有 HTTP 响应时为 null。
  final String? transportError;

  bool get ok {
    final s = httpStatus;
    return s != null && s >= 200 && s < 300;
  }

  JevDiagnostics copyWith({String? hint}) => JevDiagnostics(
    resolvedEndpoint: resolvedEndpoint,
    httpStatus: httpStatus,
    serverCode: serverCode,
    serverMessage: serverMessage,
    traceId: traceId,
    rawBody: rawBody,
    elapsedMs: elapsedMs,
    modelCorrected: modelCorrected,
    hint: hint ?? this.hint,
    attempts: attempts,
    retriedAfter422: retriedAfter422,
    modelsCatalogReadable: modelsCatalogReadable,
    transportError: transportError,
  );

  Map<String, Object?> toJson() => {
    'resolvedEndpoint': resolvedEndpoint,
    'httpStatus': httpStatus,
    'serverCode': serverCode,
    'serverMessage': serverMessage,
    'traceId': traceId,
    'rawBody': rawBody,
    'elapsedMs': elapsedMs,
    'modelCorrected': modelCorrected,
    'hint': hint,
    'attempts': attempts,
    'retriedAfter422': retriedAfter422,
    'modelsCatalogReadable': modelsCatalogReadable,
    'transportError': transportError,
  };

  @override
  String toString() => 'JevDiagnostics(${toJson()})';
}

/// **一次成功决策的返回值**。
///
/// 兼容旧调用：旧代码按 `r.yesProb` / `r.thought` / `r.model` 读，
/// 这三个 getter 保留；新增 [diagnostics] 给设置页/日志做排障。
class JevDecisionResult {
  const JevDecisionResult({
    required this.yesProb,
    required this.thought,
    required this.model,
    required this.diagnostics,
  });

  /// 模型给出的「是」的概率（0–1，已 clamp）。
  final double yesProb;

  /// 模型自带思考（服务端给了才有；文档没有 `return_thought` 参数）。
  final String? thought;

  /// 服务端回报的模型名（为空时界面只显示「云端」）。
  final String model;

  /// 可诊断快照。
  final JevDiagnostics diagnostics;

  bool get recommended => yesProb >= 0.5;
  double get confidence => recommended ? yesProb : 1 - yesProb;
  int get elapsedMs => diagnostics.elapsedMs;
  bool get modelCorrected => diagnostics.modelCorrected;
  String? get hint => diagnostics.hint;
  int? get httpStatus => diagnostics.httpStatus;
  String get resolvedEndpoint => diagnostics.resolvedEndpoint;
  String? get traceId => diagnostics.traceId;
  String? get serverCode => diagnostics.serverCode;
  String? get serverMessage => diagnostics.serverMessage;
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
  /// **rawBody 上限（字节）** —— 诊断里只留这么多，且先脱敏。
  static const int rawBodyLimit = 2048;

  /// 平台限制的题数上限（1–16 题；本客户端恒发 1 道 recommend 题）。
  static const int maxQuestions = 16;

  /// 最近一次**成功**读取模型目录的 `modelsUrlFor` 结果。
  /// 用途：decide 撞 422 时判断「鉴权通过、模型目录可读」——
  /// 这条 hint 来自真实状态，不是猜的。
  static String? _lastCatalogOkUrl;

  /// 由配置的地址推出请求端点（**2026-10-29 用户实测定版**）。
  ///
  /// 平台事实（用户已确认的**正确填法**）：模型固定
  /// `NeoHorse-Jev-4B`，接口地址**填到 `/v1` 即可**
  /// （`https://tokenrhythm.studio/v1`）。据此的归一化规则：
  ///
  /// ① 以完整端点 `/decision` 结尾 ⇒ 原样使用（explicit）；
  /// ② 旧兼容端点 `/decisions` / `/systemone` ⇒ 原样使用（兼容，hint 提示推荐 /decision）；
  /// ③ 以 `/v1` 结尾（含 `/api/v1` 这类前缀）⇒ 补 `/decision`，
  ///    hint 说明「已按 /v1/decision 请求」；
  /// ④ 裸域名（只有 host，没有路径）⇒ **不再静默补 `/systemone`**，
  ///    按用户实测口径请求 `/v1/decision`，并给 hint 建议把地址填到 `/v1`；
  /// ⑤ 其它路径前缀（如 `/api`）⇒ 保留前缀补 `/decision`，hint 说明。
  ///
  /// ★ 地址里的 query/fragment 一律**丢弃**（不参与拼端点、不进 hint）：
  /// 密钥只许放 `Authorization` 头，若用户把它塞进 URL query，日志/诊断
  /// 里也不能带出来（见 [sanitizeUrl] / [redactSecrets]）。
  static JevEndpointResolution resolveEndpoint(String baseUrl) {
    var b = baseUrl.trim();
    String? queryNote;
    final queryCut = b.indexOf(RegExp(r'[?#]'));
    if (queryCut >= 0) {
      b = b.substring(0, queryCut);
      queryNote = '接口地址里的 query/fragment 已忽略 —— 密钥只放 '
          'Authorization 头，不要写进 URL。';
    }
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    JevEndpointResolution withNote(JevEndpointResolution r) => queryNote == null
        ? r
        : JevEndpointResolution(
            url: r.url,
            explicit: r.explicit,
            hint: _joinHints([r.hint, queryNote]),
          );
    if (b.isEmpty) {
      return const JevEndpointResolution(
        url: '',
        explicit: false,
        hint:
            '接口地址是空的 —— 用户实测可用的填法是 '
            'https://tokenrhythm.studio/v1（模型固定 NeoHorse-Jev-4B），'
            '也可直接填完整端点 https://tokenrhythm.studio/v1/decision。',
      );
    }
    // ① 完整 /decision 端点：原样用，不啰嗦。
    if (b.endsWith('/decision')) {
      return withNote(JevEndpointResolution(url: b, explicit: true));
    }
    // ② 旧兼容端点：原样用，但提示推荐填法。
    for (final seg in ['/decisions', '/systemone']) {
      if (b.endsWith(seg)) {
        return withNote(
          JevEndpointResolution(
            url: b,
            explicit: true,
            hint:
                '保留了兼容端点 $seg —— 基元律动平台推荐地址填到 /v1 '
                '（模型固定 NeoHorse-Jev-4B），客户端会补 /decision。',
          ),
        );
      }
    }
    final uri = Uri.tryParse(b);
    final path = uri?.path ?? '';
    // ③ 填到 /v1（含带前缀的 /api/v1 等）：用户实测可用的填法。
    if (b.endsWith('/v1')) {
      final target = sanitizeUrl('$b/decision');
      final hint = path == '/v1'
          ? '地址填到 /v1，已按 $target 请求（用户实测可用的填法；'
                '模型固定 NeoHorse-Jev-4B）。'
          : '保留了地址里的路径前缀（$path），在其后补 /decision —— '
                '已按 $target 请求。';
      return withNote(
        JevEndpointResolution(url: '$b/decision', explicit: false, hint: hint),
      );
    }
    // ④ 裸域名（没有路径或只有 /）：不再静默补 /systemone，
    // 按用户实测口径请求 /v1/decision，并明确提示该怎么填。
    if (path.isEmpty || path == '/') {
      final target = sanitizeUrl('$b/v1/decision');
      return withNote(
        JevEndpointResolution(
          url: '$b/v1/decision',
          explicit: false,
          hint:
              '地址只填了域名 —— 用户实测正确填法是填到 /v1'
              '（模型固定 NeoHorse-Jev-4B）；已按 $target 请求。',
        ),
      );
    }
    // ⑤ 其它路径前缀：保留前缀，在其后补 /decision。
    final target = sanitizeUrl('$b/decision');
    return withNote(
      JevEndpointResolution(
        url: '$b/decision',
        explicit: false,
        hint:
            '保留了地址里的路径前缀（$path），在其后补 /decision —— '
            '已按 $target 请求；基元律动平台推荐把地址填到 /v1。',
      ),
    );
  }

  /// 旧口径（返回 URL 字符串，保留给旧调用点）：[resolveEndpoint]
  /// 的薄包装，补段行为与 2026-10-29 定版一致。
  static String endpointFor(String baseUrl) => resolveEndpoint(baseUrl).url;

  /// **脱敏 URL**：只留 scheme + host + port + path，query（可能含
  /// 密钥）与 fragment 一律丢弃。诊断/日志里**只允许**这种形状。
  static String sanitizeUrl(String url) {
    var b = url.trim();
    final cut = b.indexOf(RegExp(r'[?#]'));
    if (cut >= 0) b = b.substring(0, cut);
    final uri = Uri.tryParse(b);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return b;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port${uri.path}';
  }

  static final _skPattern = RegExp(r'sk_[A-Za-z0-9_\-]{4,}');
  static final _bearerPattern = RegExp(
    r'bearer\s+[A-Za-z0-9._\-]+',
    caseSensitive: false,
  );

  /// **密钥脱敏**：显式传入的 Key 原样抹掉，再兜底抹 `sk_…` 与
  /// `Bearer …` 形状。错误信息、异常栈、rawBody、debug 日志都必须
  /// 先过这一步；Key 本体只出现在请求头。
  static String redactSecrets(String text, {String? apiKey}) {
    var out = text;
    final k = apiKey?.trim() ?? '';
    if (k.isNotEmpty) out = out.replaceAll(k, 'sk_***');
    out = out.replaceAll(_skPattern, 'sk_***');
    out = out.replaceAll(_bearerPattern, 'Bearer ***');
    return out;
  }

  /// 把响应/错误体裁成 ≤ [rawBodyLimit] 字节并脱敏（按 UTF-8 边界
  /// 截断，不产生半个汉字）。传输层没拿到 body 时返回空串。
  static String _redactRawBody(Object? body, String apiKey) {
    if (body == null) return '';
    String raw;
    if (body is String) {
      raw = body;
    } else {
      try {
        raw = jsonEncode(body);
      } catch (_) {
        raw = body.toString();
      }
    }
    final redacted = redactSecrets(raw, apiKey: apiKey);
    final bytes = utf8.encode(redacted);
    if (bytes.length <= rawBodyLimit) return redacted;
    var cut = rawBodyLimit - 3; // 留 3 字节给省略号
    while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
      cut--;
    }
    return '${utf8.decode(bytes.sublist(0, cut), allowMalformed: true)}…';
  }

  /// 读平台错误体（统一形状 `{code, message, traceId}`，另兼容
  /// `{serverCode, serverMessage}`）：`code` 缺失取 `serverCode`，
  /// `message` 缺失取 `serverMessage`，两者都做脱敏。
  static ({String? code, String? message, String? traceId, String rawBody})
  _parseErrorBody(Object? body, String apiKey) {
    Object? src = body;
    if (body is String) {
      try {
        src = jsonDecode(body);
      } catch (_) {
        src = null;
      }
    }
    String? text(Object? v) {
      if (v is String) return v;
      if (v is num) return '$v';
      return null;
    }

    String? code;
    String? message;
    String? traceId;
    if (src is Map) {
      code = text(src['code']) ?? text(src['serverCode']);
      message = text(src['serverMessage']) ?? text(src['message']);
      traceId = text(src['traceId']);
    }
    final trimmedMsg = message?.trim();
    return (
      code: code == null || code.trim().isEmpty
          ? null
          : redactSecrets(code.trim(), apiKey: apiKey),
      message: trimmedMsg == null || trimmedMsg.isEmpty
          ? null
          : redactSecrets(
              trimmedMsg.length > 1000
                  ? '${trimmedMsg.substring(0, 1000)}…'
                  : trimmedMsg,
              apiKey: apiKey,
            ),
      traceId: traceId == null || traceId.trim().isEmpty
          ? null
          : traceId.trim(),
      rawBody: _redactRawBody(src ?? body, apiKey),
    );
  }

  /// **模型目录地址**（编辑页「获取模型」用）：决策端点去掉最后
  /// 一段（`/decision` 等）后拼 `/models` —— 与提供商编辑页拉
  /// `GET /v1/models` 同一口径。平台文档说可用性与价格以模型
  /// 目录返回为准，目录里通常只有 `NeoHorse-Jev-4B` 一个决策模型
  /// （混着聊天模型时点选即可，JEV 只认决策模型）。
  static String modelsUrlFor(String baseUrl) {
    // 先按 resolveEndpoint 归一化（裸域名 → /v1/decision、/v1 → /v1/decision），
    // 再去掉末段拼 /models ⇒ 用户实测的 /v1 填法对应 /v1/models。
    var b = resolveEndpoint(baseUrl).url.trim();
    if (b.isEmpty) return '';
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    for (final seg in ['/decision', '/decisions', '/systemone']) {
      if (b.endsWith(seg)) {
        b = b.substring(0, b.length - seg.length);
        break;
      }
    }
    return '$b/models';
  }

  /// 拉模型目录（编辑页「获取模型」）。返回模型 ID 列表（去重排序）。
  /// 成功会记下「这个地址的目录可读」（decide 撞 422 时 hint 的依据）；
  /// 失败抛 [JevException]（人话原因 + [JevException.diagnostics]）。
  static Future<List<String>> fetchModels({
    required String baseUrl,
    required String apiKey,
    Dio? client,
  }) async {
    final key = apiKey.trim();
    final dio =
        client ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
            responseType: ResponseType.json,
          ),
        );
    final target = modelsUrlFor(baseUrl);
    final sw = Stopwatch()..start();
    final Response<dynamic> resp;
    try {
      resp = await dio.get<dynamic>(
        target,
        options: Options(
          headers: {
            if (key.isNotEmpty) 'Authorization': 'Bearer $key',
          },
        ),
      );
    } on DioException catch (e) {
      final d = _diagnose(
        e,
        endpoint: sanitizeUrl(target),
        apiKey: key,
        elapsedMs: sw.elapsedMilliseconds,
      );
      throw JevException(_humanizeHttpError(d), diagnostics: d);
    }
    final data = resp.data;
    final out = <String>{};
    void collect(Object? v) {
      if (v is List) {
        for (final e in v) {
          if (e is Map && e['id'] is String) {
            out.add(e['id'] as String);
          } else if (e is String) {
            out.add(e);
          }
        }
      }
    }

    if (data is Map) {
      collect(data['data']);
      collect(data['models']);
    } else if (data is List) {
      collect(data);
    }
    if (out.isEmpty) {
      final d = _diagnosticsFromResponse(
        data: data,
        status: resp.statusCode,
        endpoint: sanitizeUrl(target),
        apiKey: key,
        elapsedMs: sw.elapsedMilliseconds,
        hint: '目录请求本身成功了，但返回里没有模型 ID —— 检查接口地址是不是'
            '模型的 /v1/models（基元律动为 https://tokenrhythm.studio/v1/models）。',
      );
      throw JevException('模型目录是空的 —— 检查接口地址与密钥。', diagnostics: d);
    }
    _lastCatalogOkUrl = target;
    return out.toList()..sort();
  }

  /// 模型目录是否已在本进程里成功读过（decide 422 hint 用）。
  static bool modelsCatalogReadableFor(String baseUrl) =>
      _lastCatalogOkUrl == modelsUrlFor(baseUrl);

  @visibleForTesting
  static void resetModelsCatalogProbe() {
    _lastCatalogOkUrl = null;
  }

  /// 问一次是非题（返回可诊断对象，见 [JevDecisionResult]）。
  ///
  /// 报文严格照基元律动《JEV 决策模型 API》：`state` 用**字符串**
  /// （文档建议；旧版发 `{question: …}` 对象是 TypeSafe 官方形状，
  /// 本平台不认）、`questions.<id>` 为 noul 题、平台模型 ID 固定。
  /// 文档没有 `return_thought` 参数 —— 不再下发（未知参数可能
  /// 被平台以 422 拒掉）；服务端若仍回带 thought 就照常读。
  ///
  /// · 模型不是固定 ID `NeoHorse-Jev-4B` ⇒ **强制纠正**并标
  ///   `modelCorrected`（平台只认这一个决策模型；大小写/空格差异
  ///   也算填错 —— 用户实测正确填法是「模型 NeoHorse-Jev-4B +
  ///   接口地址填到 /v1」，这条已在 resolveEndpoint 里落成归一化）；
  /// · **只在 HTTP 422 时重试一次**：重试报文仍用 `recommend` 题键
  ///   （解析写死 `answers['recommend']`；照抄文档示例的 `stop`
  ///   会让 200 也误判「没给 noul」），只把 `instructions` 精简掉；
  /// · 失败抛 [JevException]（`.diagnostics` 带完整快照），成功
  ///   返回 [JevDecisionResult]（旧代码的 `r.yesProb` / `r.thought` /
  ///   `r.model` 仍可用）。
  static Future<JevDecisionResult> decide({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String question,
    Dio? client,
    bool? modelsCatalogReadable,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw JevException(
          '还没填 JEV 的 API 密钥 —— 到「设置 → 模型 → JEV 决策」里'
          '填上平台密钥（sk_ 开头）再试。');
    }
    final resolution = resolveEndpoint(baseUrl);
    if (resolution.url.trim().isEmpty) {
      throw JevException(
        resolution.hint ?? '接口地址是空的 —— 先填 JEV 的接口地址。',
      );
    }
    final requestedModel = model.trim();
    final modelCorrected = requestedModel != kJevDefaultModel;
    final catalogReadable =
        modelsCatalogReadable ?? modelsCatalogReadableFor(baseUrl);
    final dio =
        client ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 90),
            sendTimeout: const Duration(seconds: 20),
            responseType: ResponseType.json,
          ),
        );
    final endpoint = sanitizeUrl(resolution.url);
    final sw = Stopwatch()..start();
    Response<dynamic>? resp;
    var attempts = 0;
    while (true) {
      attempts += 1;
      try {
        resp = await dio.post<dynamic>(
          resolution.url,
          data: _requestBody(question, simplified: attempts > 1),
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $key',
            },
          ),
        );
        break;
      } on DioException catch (e) {
        final d = _diagnose(
          e,
          endpoint: endpoint,
          apiKey: key,
          elapsedMs: sw.elapsedMilliseconds,
          modelCorrected: modelCorrected,
          modelsCatalogReadable: catalogReadable,
          attempts: attempts,
          retriedAfter422: attempts > 1,
          endpointHint: resolution.hint,
        );
        // 只在首次 422 重试一次；其它状态码（401/403/413/429…）不重试。
        if (attempts == 1 && d.httpStatus == 422) continue;
        throw JevException(_humanizeHttpError(d), diagnostics: d);
      }
    }
    sw.stop();
    final parsed = _parseErrorBody(resp.data, key);
    final diag = JevDiagnostics(
      resolvedEndpoint: endpoint,
      httpStatus: resp.statusCode,
      serverCode: parsed.code,
      serverMessage: parsed.message,
      traceId: parsed.traceId,
      rawBody: parsed.rawBody,
      elapsedMs: sw.elapsedMilliseconds,
      modelCorrected: modelCorrected,
      hint: _joinHints([
        resolution.hint,
        if (modelCorrected) _modelCorrectedHint,
        if (attempts > 1)
          '首次 422 已用仍叫 recommend 的题精简重试成功（未改用文档'
              '示例的 stop 键）。',
      ]),
      attempts: attempts,
      retriedAfter422: attempts > 1,
      modelsCatalogReadable: catalogReadable,
    );
    final data = resp.data;
    if (data is! Map) {
      throw JevException(
        '决策服务返回了无法理解的内容。',
        diagnostics: diag.copyWith(
          hint: _joinHints([diag.hint, '响应不是 JSON 对象；看 rawBody 定位。']),
        ),
      );
    }
    final answers = data['answers'];
    if (answers is! Map) {
      throw JevException('决策服务没有返回 answers 字段。', diagnostics: diag);
    }
    final a = answers['recommend'];
    final noul = a is Map ? a['noul'] : null;
    if (noul is! num) {
      const trap =
          '解析写死 answers[\'recommend\'].noul；平台文档示例的题键是 '
          'stop —— 照抄会把 200 误判成「没给 noul」（本客户端发出的题键'
          '仍是 recommend）。';
      throw JevException(
        '决策服务没有给出是非判断（noul）。$trap',
        diagnostics: diag.copyWith(hint: _joinHints([diag.hint, trap])),
      );
    }
    final thought = a is Map ? a['thought'] : null;
    return JevDecisionResult(
      yesProb: noul.toDouble().clamp(0.0, 1.0),
      thought: (thought is String && thought.trim().isNotEmpty)
          ? thought.trim()
          : null,
      model: data['model'] as String? ?? '',
      diagnostics: diag,
    );
  }

  static const String _modelCorrectedHint =
      '模型名不是固定 ID NeoHorse-Jev-4B —— 平台只认这一个决策模型，'
      '已强制改用固定模型 ID 发送。';

  /// 决策请求体：`state` 字符串 + 一道 **仍叫 `recommend`** 的
  /// noul 题；模型恒为固定 ID（用户填错在 [decide] 里纠正并标记）。
  /// 422 重试时只精简掉 `instructions`（题键不变）。
  static Map<String, Object?> _requestBody(
    String question, {
    bool simplified = false,
  }) => {
    'model': kJevDefaultModel,
    'state': question,
    'questions': {
      'recommend': {
        'type': 'noul',
        if (!simplified) 'instructions': '推荐用户这样做吗？',
      },
    },
  };

  /// 由响应构造诊断（成功响应 / fetchModels 的「目录空」都走这里）。
  static JevDiagnostics _diagnosticsFromResponse({
    required Object? data,
    required int? status,
    required String endpoint,
    required String apiKey,
    required int elapsedMs,
    bool modelCorrected = false,
    bool modelsCatalogReadable = false,
    String? hint,
  }) {
    final parsed = _parseErrorBody(data, apiKey);
    return JevDiagnostics(
      resolvedEndpoint: endpoint,
      httpStatus: status,
      serverCode: parsed.code,
      serverMessage: parsed.message,
      traceId: parsed.traceId,
      rawBody: parsed.rawBody,
      elapsedMs: elapsedMs,
      modelCorrected: modelCorrected,
      hint: hint,
      modelsCatalogReadable: modelsCatalogReadable,
    );
  }

  /// 把一次 [DioException] 变成可诊断快照：**只读响应体**
  /// （`body.code` / `serverCode` / `serverMessage` / `message` /
  /// `traceId`，见 [_parseErrorBody]），不读 header，也不用
  /// `DioException.message` —— 那两处可能带 API Key / 完整 URL。
  static JevDiagnostics _diagnose(
    DioException e, {
    required String endpoint,
    required String apiKey,
    required int elapsedMs,
    bool modelCorrected = false,
    bool modelsCatalogReadable = false,
    int attempts = 1,
    bool retriedAfter422 = false,
    String? endpointHint,
  }) {
    final status = e.response?.statusCode;
    final parsed = _parseErrorBody(e.response?.data, apiKey);
    return JevDiagnostics(
      resolvedEndpoint: endpoint,
      httpStatus: status,
      serverCode: parsed.code,
      serverMessage: parsed.message,
      traceId: parsed.traceId,
      rawBody: parsed.rawBody,
      elapsedMs: elapsedMs,
      modelCorrected: modelCorrected,
      hint: _composeErrorHint(
        status: status,
        modelCorrected: modelCorrected,
        modelsCatalogReadable: modelsCatalogReadable,
        attempts: attempts,
        retriedAfter422: retriedAfter422,
        endpointHint: endpointHint,
      ),
      attempts: attempts,
      retriedAfter422: retriedAfter422,
      modelsCatalogReadable: modelsCatalogReadable,
      transportError: status == null ? e.type.name : null,
    );
  }

  /// 错误 hint：状态码 + **真实前置状态**（模型目录是否已读成功）
  /// 组合出下一步怎么办。措辞与 `docs/INTERFACE.md §N11` 对齐。
  static String? _composeErrorHint({
    required int? status,
    required bool modelCorrected,
    required bool modelsCatalogReadable,
    required int attempts,
    required bool retriedAfter422,
    String? endpointHint,
  }) {
    final parts = <String?>[endpointHint];
    if (modelCorrected) parts.add(_modelCorrectedHint);
    switch (status) {
      case 401:
        parts.add('401 = 密钥无效或没带 Authorization 头（无 Key 时鉴权'
            '先于参数校验，三发全 401）。');
      case 403:
        parts.add('403 = 账号没有该模型的权限/灰度。');
      case 404:
        parts.add('404 = 端点不对 —— 推荐 '
            'https://tokenrhythm.studio/v1/decision，或填到 /v1 由应用补全。');
      case 413:
        parts.add('413 = 请求体超限（平台 ≤1MiB）—— 问题太长，缩短后再试。');
      case 429:
        parts.add('429 = 限流 —— 稍等再试。');
      case 422:
        if (modelsCatalogReadable) {
          parts.add('鉴权通过、模型目录可读，422 多半是模型权限/参数/上游限制。');
        } else {
          parts.add('422 一般是参数/上游限制：1–16 道题、请求体 ≤1MiB、'
              '模型固定 NeoHorse-Jev-4B。');
        }
        if (attempts > 1 || retriedAfter422) {
          parts.add('首次 422 已用仍叫 recommend 的题精简重试一次'
              '（未改用文档示例的 stop 键）。');
        }
    }
    return _joinHints(parts);
  }

  /// 拼 hint（去空、去重、空格分隔）；全空返回 null。
  static String? _joinHints(List<String?> parts) {
    final seen = <String>{};
    final out = <String>[];
    for (final p in parts) {
      final s = p?.trim() ?? '';
      if (s.isEmpty || !seen.add(s)) continue;
      out.add(s);
    }
    return out.isEmpty ? null : out.join(' ');
  }

  /// 把一次 HTTP/传输错误翻成人话（设置页只拿 message；可诊断
  /// 细节在 [JevDiagnostics] / [JevException.diagnostics]）。
  ///
  /// 平台错误统一形状 `{code, message, traceId}`：code 已进
  /// `serverCode`、message 已进 `serverMessage`（[decide]/[fetchModels]
  /// 里的 [_parseErrorBody] 负责读），这里只拼**已脱敏**字段，
  /// 绝不带请求头/完整 URL/Key。
  static String _humanizeHttpError(JevDiagnostics d) {
    final code = d.httpStatus;
    final codeTag = (d.serverCode == null || d.serverCode!.isEmpty)
        ? ''
        : ' · code=${d.serverCode}';
    final trace = (d.traceId == null || d.traceId!.isEmpty)
        ? ''
        : '（traceId: ${d.traceId}）';
    final retried = d.attempts > 1 ? '（422 重试一次后仍失败）' : '';
    final msg = d.serverMessage?.trim() ?? '';
    if (msg.isNotEmpty) {
      return '决策服务出错（HTTP ${code ?? '—'}$codeTag）：$msg$trace$retried';
    }
    switch (code) {
      case 401:
      case 403:
        return '决策服务拒绝了密钥（$code$codeTag）—— 401 多为密钥无效，'
            '403 多为账号还没拿到该模型的权限/灰度，检查 JEV 配置里的 API 密钥。$trace';
      case 404:
        return '接口地址不对（404$codeTag）—— 推荐地址是 '
            'https://tokenrhythm.studio/v1/decision，或填到 /v1 由应用补全。';
      case 413:
        return '请求体太大（413$codeTag）—— 平台限制 ≤1MiB，问题缩短后再试。$trace';
      case 422:
        return '决策服务拒绝了报文（422$codeTag）—— 参数/上游限制：1–16 道题、'
            '请求体 ≤1MiB、模型固定 NeoHorse-Jev-4B；已自动重试一次。$trace';
      case 429:
        return '决策服务限流了（429$codeTag）—— 稍等再试。$trace';
    }
    if (code != null) return '决策服务出错（HTTP $code$codeTag）。$trace';
    return switch (d.transportError) {
      'connectionTimeout' ||
      'receiveTimeout' ||
      'sendTimeout' => '决策服务超时 —— 检查网络或换个接口地址。',
      'connectionError' => '连不上决策服务 —— 检查接口地址与网络。',
      'badCertificate' => '决策服务证书校验失败 —— 检查网络代理或接口地址。',
      'cancel' => '决策请求已取消。',
      null => '决策请求失败。',
      final t => '决策请求失败：$t',
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

  /// 最近一次决策尝试的可诊断快照（成功或失败都有；本地配置错误
  /// 等没发请求时为 null）。设置页可据此展示状态码/错误码/traceId。
  JevDiagnostics? lastDiagnostics;

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
    await refreshCloudKey();
    profile ??= await AgentBridge().deviceProfile();
    refreshDownloaded();
    loaded = true;
    notifyListeners();
  }

  /// 云端密钥是否已填（2026-10-29 预置端点后新增的就绪维度：
  /// 地址已预置，「配没配好」只看密钥）。状态展示（模型页卡、
  /// 决策顶栏）据此区分「已配置 / 待填密钥」，不假装就绪。
  bool cloudKeyPresent = false;

  Future<void> refreshCloudKey() async {
    try {
      cloudKeyPresent = (await JevStore.readCloudKey()).trim().isNotEmpty;
    } catch (_) {
      cloudKeyPresent = false;
    }
    if (loaded) notifyListeners();
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
    lastDiagnostics = null;
    notifyListeners();
    final sw = Stopwatch()..start();
    try {
      final double yesProb;
      final String? thought;
      final String engineLabel;
      switch (config.source) {
        case JevSource.cloud:
          if (!config.cloudReady) {
            throw JevException('云端接口地址是空的：先去 JEV 配置里恢复预置地址，或填上接口地址。');
          }
          final key = await JevStore.readCloudKey();
          final r = await JevCloudClient.decide(
            baseUrl: config.cloudBaseUrl,
            apiKey: key,
            model: config.cloudModel,
            question: question,
          );
          lastDiagnostics = r.diagnostics;
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
      lastDiagnostics = e.diagnostics;
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
