// Copyright (C) 2026 The Heracles Authors
//
// **MCP 探活（真实 JSON-RPC 握手 + tools/list 发现）** —— V0.4 F3，2026-11-02。
// 契约见 `docs/INTERFACE.md` §N16.2；状态词表复用 `ContractMcp.status*`。
//
// ============================================================================
// 为什么放在 backend 而不是 App
// ============================================================================
// 产品拍板（2026-11-02）：App **只依赖 backend 的公共面**，不直接 import
// `dart_agent_core`。理由：
//  · `app/pubspec.yaml` 若加 `dart_agent_core` 直接依赖，`McpSession` 这类**框架内部类型**
//    就会成为 App 的编译期契约；框架一改，App 跟着红。
//  · 配置模型（`McpServerConfig`）与校验（`validateMcpServer`）已经在 backend，
//    探活也放这里，边界一致（"MCP 这一摊事只在 backend"）。
//  · 纯 Dart 包可以毫秒级 `dart test`，还能对着本地 `HttpServer` 做**真连**测试
//    —— App 侧做不到这一点（Flutter 测试里连本机端口同样可行，但没有必要）。
//
// 注意：这里**没有**用框架的 `McpSession`/`mcp_dart`，而是直接发 HTTP + JSON-RPC。
// 原因有两个：
//  1. 框架的 stdio 会话模型对手机端无意义，探活只需要"握手 + 数工具"两件事；
//  2. 直接发就能**完全控制** SSE 解析、超时口径、错误文案与脱敏 —— 这四样正是
//     用户会直接看到的东西，不能交给一个不返回原始信息的封装。
//
// ============================================================================
// 协议要点（踩坑清单，改之前先读）
// ============================================================================
// Streamable HTTP 传输（MCP 2025-06-18）：
//  1. 所有请求 `POST` 到**同一个** URL，body 是单条 JSON-RPC 消息；
//  2. `Accept` **必须**同时含 `application/json, text/event-stream` ——
//     只写 `application/json` 会被合规实现直接拒绝（406）；
//  3. 响应可能是**普通 JSON**，也可能是 **SSE**（`text/event-stream`）：
//     SSE 里真正的内容在 `data:` 行（多行 data 要拼接），`event:`/`id:`/`:` 注释都不是载荷；
//  4. `initialize` 之后**必须**发 `notifications/initialized`（通知，没有 id、
//     正常回 202 且 body 为空）—— 不发的话部分服务器会拒绝后续 `tools/list`；
//  5. 服务器可在 `initialize` 的响应头给 `Mcp-Session-Id`，后续请求**必须**带回；
//  6. 能力（tools）用 `tools/list` 取，结果是**可分页**的：`nextCursor` 存在就要继续取，
//     否则工具数会少 —— 而"工具数"是用户判断"连上没有"的唯一硬指标。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../contract/contract.dart';
import 'v4_extensions.dart';

/// 客户端声明的 MCP 协议版本。
///
/// 为什么写死一个而不是"让服务器挑"：`initialize` 的**请求**里这个字段是必填的
/// （服务器据此决定回哪套行为）；服务器若不支持会自己降级并在 result 里回报它选的版本。
const String kMcpProtocolVersion = '2025-06-18';

/// `clientInfo.version`（只是个自我介绍，服务器可能记日志）。
const String kMcpClientVersion = '0.4.0';

/// 探活结果（**纯数据**：没有框架类型、没有 Dio 类型，可以直接 `toJson()` 过通道）。
///
/// 形状与 §N16.2 对齐：`{status, tools, error, latencyMs, serverName?}`。
class McpProbeResult {
  const McpProbeResult({
    required this.status,
    this.tools,
    this.error,
    this.latencyMs = 0,
    this.serverName,
  });

  /// `connected` | `failed` | `unsupported`（`not_configured` 由调用方判断 ——
  /// "这台服务器在不在配置里"是配置仓库的事，不是探活的事）。
  final String status;

  /// 工具数：**只有 `connected` 才非空**。其余状态一律 `null`
  /// —— 0 会被读成"连上了但没工具"，与"没连上"必须可区分。
  final int? tools;

  /// 人话原因（`connected` 时 `null`）。已脱敏：不含 env 值、URL query、认证头。
  final String? error;

  /// 真实耗时（毫秒）。`unsupported` 恒 0：**根本没发请求**。
  final int latencyMs;

  /// 探的是哪台（便于并发探活时对上号）。
  final String? serverName;

  bool get isConnected => status == ContractMcp.statusConnected;

  Map<String, Object?> toJson() => <String, Object?>{
        'status': status,
        'tools': tools,
        'error': error,
        'latencyMs': latencyMs,
        'serverName': serverName,
      };

  @override
  String toString() => 'McpProbeResult(${serverName ?? '?'}: $status'
      '${tools == null ? '' : ', $tools tools'}, ${latencyMs}ms)'
      '${error == null ? '' : ' — $error'}';
}

/// 探活的内部失败（只在本文件里流转，出口一律转成 [McpProbeResult.error]）。
class _ProbeFailure implements Exception {
  const _ProbeFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// **探一台 MCP 服务器**：`initialize` → `notifications/initialized` → `tools/list`（含分页）。
///
/// 入参 [timeout] 是**每一次** RPC 的上限（不是总预算）：
/// 分页很多时总耗时可能超过它，但任何一次卡住都会立刻失败 —— 这是用户能感知到的边界。
///
/// [client] / [log] 是给测试与宿主留的注入缝：生产都不传。
Future<McpProbeResult> probeMcpConnection(
  McpServerConfig config, {
  Duration timeout = const Duration(seconds: 15),
  Dio? client,
  void Function(String message)? log,
}) async {
  // ① stdio 直接判 unsupported：手机端没有可执行子进程环境。
  //    必须在**发任何请求之前**返回 —— 否则会白白等一次超时，用户还以为在重试。
  if (config.transport == ContractMcp.transportStdio) {
    return McpProbeResult(
      status: ContractMcp.statusUnsupported,
      error: ContractMcp.stdioUnsupportedMessage,
      serverName: config.name,
    );
  }

  // ② 配置本身不完整就不该发请求（url 都没给，发出去也是 DNS 错误）。
  final url = config.url.trim();
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return McpProbeResult(
      status: ContractMcp.statusFailed,
      error: '配置不完整：http 传输需要一个 http:// 或 https:// 开头的地址。',
      serverName: config.name,
    );
  }

  final watch = Stopwatch()..start();
  final dio = client ??
      Dio(BaseOptions(
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
      ));

  try {
    // ③ initialize：唯一必填三件套是 protocolVersion / capabilities / clientInfo。
    final init = await _rpc(
      dio,
      url,
      timeout,
      <String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, Object?>{
          'protocolVersion': kMcpProtocolVersion,
          // 我们不要服务器回调（roots/sampling/elicitation），给空对象最诚实。
          'capabilities': <String, Object?>{},
          'clientInfo': <String, Object?>{
            'name': 'Heracles',
            'version': kMcpClientVersion,
          },
        },
      },
    );
    final initResult = init.payload['result'];
    if (initResult is! Map) {
      throw const _ProbeFailure(
        'initialize 的响应里没有 result（服务器不是 MCP，或返回了 error）。',
      );
    }
    // 服务器选的版本 / 会话 id：后续请求要带回去。
    final negotiated = initResult['protocolVersion'];
    final sessionId = init.sessionId;

    // ④ notifications/initialized：通知没有 id，正常回 202 + 空 body。
    await _notify(
      dio,
      url,
      timeout,
      <String, Object?>{'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      sessionId: sessionId,
      protocolVersion: negotiated is String ? negotiated : null,
    );

    // ⑤ tools/list：分页取全。少取一页，工具数就是错的。
    final names = <String>{};
    String? cursor;
    for (var page = 0; page < _maxToolPages; page++) {
      final res = await _rpc(
        dio,
        url,
        timeout,
        <String, Object?>{
          'jsonrpc': '2.0',
          'id': 100 + page,
          'method': 'tools/list',
          'params': <String, Object?>{
            if (cursor != null) 'cursor': cursor,
          },
        },
        sessionId: sessionId,
        protocolVersion: negotiated is String ? negotiated : null,
      );
      final result = res.payload['result'];
      if (result is! Map) {
        throw const _ProbeFailure('tools/list 的响应里没有 result。');
      }
      final tools = result['tools'];
      if (tools is! List) {
        throw const _ProbeFailure('tools/list 的响应里没有 tools 数组。');
      }
      for (final t in tools) {
        // 只数名字：没有名字的条目不算一个可调用的工具（宁可少数，不虚报）。
        if (t is Map && t['name'] is String && (t['name'] as String).trim().isNotEmpty) {
          names.add((t['name'] as String).trim());
        }
      }
      final next = result['nextCursor'];
      if (next is! String || next.isEmpty) break;
      cursor = next;
    }

    watch.stop();
    log?.call('[mcp.probe] ${config.name}: connected, ${names.length} tools, '
        '${watch.elapsedMilliseconds}ms, ${redactMcpUrl(url)}');
    return McpProbeResult(
      status: ContractMcp.statusConnected,
      tools: names.length,
      latencyMs: watch.elapsedMilliseconds,
      serverName: config.name,
    );
  } on _ProbeFailure catch (e) {
    watch.stop();
    // SEC：日志里不带 env 值，URL 一律脱敏（query 段是常见的 token 落点）。
    log?.call('[mcp.probe] ${config.name}: failed (${watch.elapsedMilliseconds}ms)');
    return McpProbeResult(
      status: ContractMcp.statusFailed,
      error: sanitizeMcpError(e.message),
      latencyMs: watch.elapsedMilliseconds,
      serverName: config.name,
    );
  } on TimeoutException {
    watch.stop();
    return McpProbeResult(
      status: ContractMcp.statusFailed,
      error: '连接超时（${timeout.inSeconds} 秒）：服务器没有在限定时间内完成握手。',
      latencyMs: watch.elapsedMilliseconds,
      serverName: config.name,
    );
  } catch (e) {
    watch.stop();
    return McpProbeResult(
      status: ContractMcp.statusFailed,
      error: sanitizeMcpError('连接失败：$e'),
      latencyMs: watch.elapsedMilliseconds,
      serverName: config.name,
    );
  } finally {
    // 自己 new 的 client 才释放；注入的由调用方管（测试里要复用）。
    if (client == null) dio.close(force: true);
  }
}

/// tools/list 最多翻多少页。
///
/// 有上限是因为 `nextCursor` 由服务器给：一个坏实现回同一个 cursor 就会死循环，
/// 而探活是 UI 上的一个按钮 —— 不能让它永远转。50 页 × 常见 100 个/页 = 5000 个工具，
/// 真实服务器远达不到这个量级。
const int _maxToolPages = 50;

/// 发一条 JSON-RPC 请求，返回解析后的对象与服务器给的会话 id（`Mcp-Session-Id`）。
///
/// 为什么把 sessionId 单独返回而不是塞进 payload：payload 是**服务器说的原话**，
/// 往里塞我们的私有键，迟早有人把它当真当成协议字段。
Future<({Map<String, Object?> payload, String? sessionId})> _rpc(
  Dio dio,
  String url,
  Duration timeout,
  Map<String, Object?> body, {
  String? sessionId,
  String? protocolVersion,
}) async {
  final response = await _post(
    dio,
    url,
    body,
    timeout,
    sessionId: sessionId,
    protocolVersion: protocolVersion,
  );
  final payload = _decodeBody(response);
  // JSON-RPC 层面的错误：服务器听懂了但拒绝了（能力/鉴权/协议版本）。
  final error = payload['error'];
  if (error is Map) {
    final code = error['code'];
    final message = error['message'];
    throw _ProbeFailure(
      '服务器拒绝了请求（JSON-RPC ${code ?? '?'}）：${message ?? '未给出原因'}',
    );
  }
  final sid = response.headers.value('mcp-session-id');
  return (
    payload: payload,
    sessionId: sid != null && sid.trim().isNotEmpty ? sid.trim() : sessionId,
  );
}

/// 发一条 JSON-RPC 通知（没有 id，服务器**不返回** JSON-RPC 结果）。
///
/// body 为空 / 202 都是正常；只在 HTTP 层面失败时报错
/// —— 通知本来就没有可解析的响应，硬解析会把"正常 202"误判成"响应畸形"。
Future<void> _notify(
  Dio dio,
  String url,
  Duration timeout,
  Map<String, Object?> body, {
  String? sessionId,
  String? protocolVersion,
}) async {
  await _post(
    dio,
    url,
    body,
    timeout,
    sessionId: sessionId,
    protocolVersion: protocolVersion,
  );
}

Future<Response<String>> _post(
  Dio dio,
  String url,
  Map<String, Object?> body,
  Duration timeout, {
  String? sessionId,
  String? protocolVersion,
}) async {
  try {
    final response = await dio
        .post<String>(
          url,
          data: jsonEncode(body),
          options: Options(
            responseType: ResponseType.plain,
            contentType: 'application/json',
            // 协议要求同时接受两种：普通 JSON 与 SSE。只写 application/json 会被 406。
            headers: <String, Object?>{
              'Accept': 'application/json, text/event-stream',
              if (sessionId != null) 'Mcp-Session-Id': sessionId,
              if (protocolVersion != null) 'MCP-Protocol-Version': protocolVersion,
            },
            // 4xx/5xx 要**当成数据**看（我们要读状态码给人话原因），不能抛成 DioException。
            validateStatus: (_) => true,
          ),
        )
        .timeout(timeout);
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) {
      throw _ProbeFailure(
        _httpMessage(status, response.headers.value('content-type'), url),
      );
    }
    return response;
  } on DioException catch (e) {
    throw _ProbeFailure(_dioMessage(e, url));
  }
}

/// HTTP 状态码 → 人话（**带下一步**，不是"请求失败"这种没有信息量的话）。
///
/// **必须带脱敏后的端点**：状态码相同的两个失败（401）可能来自完全不同的地址，
/// 用户同时配了多个 MCP 服务器时，"哪个地址回的 401"是排障的第一条信息。
/// 但 URL 的 query 段可能是 token ⇒ 走 [redactMcpUrl]，只留 scheme+host+path。
String _httpMessage(int status, String? contentType, String url) {
  final where = redactMcpUrl(url);
  String withWhere(String body) => '$body（端点：$where）';
  if (status == 401) {
    return withWhere('服务器返回 HTTP 401（鉴权失败：地址里需要有效的 API Key / Token）');
  }
  if (status == 403) {
    return withWhere('服务器返回 HTTP 403（已鉴权但无权访问这个 MCP 端点）');
  }
  if (status == 404) {
    return withWhere('服务器返回 HTTP 404（MCP 端点路径不对，检查地址是否少了 /mcp 或 /sse）');
  }
  if (status == 406) {
    return withWhere('服务器返回 HTTP 406（不接受我们声明的响应类型 application/json + text/event-stream）');
  }
  if (status >= 500) {
    return withWhere('服务器返回 HTTP $status（MCP 服务器内部错误，稍后重试或联系服务提供方）');
  }
  return withWhere('服务器返回 HTTP $status（${contentType ?? '未知 Content-Type'}）');
}

/// 网络层失败 → 人话。**URL 已脱敏**（query 段可能是 token）。
String _dioMessage(DioException e, String url) {
  final where = redactMcpUrl(url);
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return '连接超时：服务器在限定时间内没有响应（$where）。';
    case DioExceptionType.connectionError:
      return '连接失败：无法连接到 $where（网络不可达、域名解析失败或服务器未启动）。';
    case DioExceptionType.badCertificate:
      return '连接失败：$where 的 TLS 证书校验不通过（自签证书请改用受信任证书）。';
    case DioExceptionType.cancel:
      return '连接已取消。';
    case DioExceptionType.badResponse:
      return '服务器返回了无法处理的响应（$where）。';
    case DioExceptionType.unknown:
      return '连接失败：$e';
  }
}

/// 把响应体解成 JSON 对象：**普通 JSON 与 SSE 两种都要支持**。
Map<String, Object?> _decodeBody(Response<String> response) {
  final raw = response.data ?? '';
  if (raw.trim().isEmpty) {
    throw const _ProbeFailure('服务器返回了空响应（MCP 响应必须是一条 JSON-RPC 消息）。');
  }
  final contentType = (response.headers.value('content-type') ?? '').toLowerCase();
  final looksSse = contentType.contains('text/event-stream') || raw.contains('data:');
  if (looksSse) {
    final payload = _firstJsonObjectFromSse(raw);
    if (payload != null) return payload;
    // 声明是 SSE 但一条可解析的 data 都没有 —— 这跟"畸形 JSON"是同一类问题，
    // 只是失败点在 SSE 层，文案要说清是哪一层坏的。
    throw const _ProbeFailure(
      '服务器的 SSE 响应里没有可解析的 data 事件（不是合法的 JSON-RPC over SSE）。',
    );
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded.cast<String, Object?>();
    throw const _ProbeFailure('服务器的响应是一个 JSON 值但不是对象（不符合 JSON-RPC 2.0）。');
  } on FormatException {
    throw const _ProbeFailure(
      '服务器返回的内容无法解析为 JSON（Content-Type 也不是 text/event-stream）。',
    );
  }
}

/// 从 SSE 文本里取**第一个**能解析成 JSON 对象的 `data:` 载荷。
///
/// SSE 规则（只实现我们需要的部分）：
///  · 事件之间用空行分隔；
///  · 一个事件里可以有多行 `data:`，按换行拼接；
///  · `event:` / `id:` / `retry:` 与 `:` 开头的注释行都与载荷无关；
///  · 首个事件可能是 `event: message` + `data: {...}`，也可能是服务器发的心跳（注释行）。
Map<String, Object?>? _firstJsonObjectFromSse(String raw) {
  final buffer = StringBuffer();
  final payloads = <String>[];

  void flush() {
    if (buffer.isEmpty) return;
    payloads.add(buffer.toString());
    buffer.clear();
  }

  for (final line in raw.split(RegExp(r'\r?\n'))) {
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (line.startsWith('data:')) {
      // 规范规定 'data:' 后可有一个空格；没有也能兼容（trimLeft 吃掉）。
      buffer.write(line.substring(5).trimLeft());
    }
    // event:/id:/retry:/: 一律忽略 —— 它们不承载 JSON-RPC 载荷。
  }
  flush();

  for (final p in payloads) {
    try {
      final decoded = jsonDecode(p);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      continue; // 单个事件坏掉不影响后面的事件（服务器可能在 data 里混日志）
    }
  }
  return null;
}

// ============================================================================
// 脱敏（App 侧 `McpService` 直接复用这两个函数 —— 只留一份真相）
// ============================================================================

/// URL 脱敏：**只留 scheme + host + port + path**。
///
/// 丢掉：query（`?token=` 最常见的落点）、fragment、userinfo（`user:pass@`）。
/// 留着 host 与 path 才够排障（"是不是少了 /mcp"）。
String redactMcpUrl(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return '';
  final uri = Uri.tryParse(t);
  if (uri == null || uri.host.isEmpty) return '<地址无法解析>';
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port${uri.path}';
}

/// 把任意文本洗成能给用户看 / 写日志的样子。
///
/// 三件事：抹 `Authorization`/`Bearer` 的值、URL 换成 [redactMcpUrl] 结果、截断过长异常。
/// ⚠️ 它**不保证**能抹掉任意秘密（比如前缀不是 URL 的裸 key），
/// 所以真正的防线是"密钥根本不进 env"（见 `validateMcpServer` 与 App 侧第一道闸）。
String sanitizeMcpError(String raw, {int maxChars = 240}) {
  var t = raw.trim();
  if (t.isEmpty) return '未知错误（没有给出原因）。';
  t = t.replaceAll(_authHeaderPattern, r'$1***');
  t = t.replaceAll(_bearerPattern, 'Bearer ***');
  t = t.replaceAllMapped(_urlPattern, (m) => redactMcpUrl(m.group(0)!));
  if (t.length > maxChars) t = '${t.substring(0, maxChars)}…';
  return t;
}

// `Authorization: Bearer xxx` 要把 `Bearer` 一起吃掉 —— 只抹 `\S+` 会漏掉后面那个 token。
final RegExp _authHeaderPattern =
    RegExp(r'(authorization\s*[:=]\s*)(?:bearer\s+)?\S+', caseSensitive: false);
final RegExp _bearerPattern = RegExp(r'bearer\s+\S+', caseSensitive: false);
final RegExp _urlPattern = RegExp(r"https?://[^\s<>'”）]+");
