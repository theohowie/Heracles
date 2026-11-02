// Copyright (C) 2026 The Heracles Authors
//
// **MCP 配置与连接测试（App 侧服务层）** —— V0.4 F3，契约见
// `docs/INTERFACE.md` §N16.2。
//
// ============================================================================
// 职责边界（谁负责什么）
// ============================================================================
// | 事 | 谁做 | 为什么 |
// |---|---|---|
// | 配置的**持久化**（SharedPreferences `heracles_mcp`.servers） | 宿主（Kotlin） | 配置是设备级资产，跟着 App 生命周期，不跟着某次会话 |
// | `mcpList` / `mcpSave` / `mcpDelete` 三个通道方法 | 宿主（Kotlin） | 见上 |
// | **保存前的第一道校验** | 本文件（backend `validateMcpServer`） | 非法配置到"连接时"才报，模型会白等一次超时；而且宿主的二次拦截是**兜底**不是主闸 |
// | 密钥进 env 的拦截 | 本文件 + 宿主（双闸） | 配置是明文落盘的，密钥一旦写进去就永久泄露 |
// | 连接测试 | 本文件（转调 backend `probeMcpConnection`） | 通道上没有 `testMcpConnection`：**宿主不重复实现一份"假连接"**；App 也不引框架内部类型 |
//
// 本文件**不存任何缓存/镜像**：读一律回宿主拿。
// backend 里有 `McpConfigStore`（纯内存 CRUD）可以用，但这里**故意不用它做读缓存** ——
// 一旦本地留一份镜像，就多出"宿主写失败但本地显示已保存"这类第二真相；
// 配置只有一份，在宿主。
//
// ============================================================================
// 连接测试怎么做的（2026-11-02 产品拍板：走 backend 探活）
// ============================================================================
// 真实连接 = `backend` 的 `probeMcpConnection(cfg)`：真发 JSON-RPC
// （initialize → notifications/initialized → tools/list，含 SSE 与分页），
// 返回纯数据 `{status, tools, error, latencyMs, serverName}`。
//
// 为什么不在 App 里直接 import 框架的 `McpSession`：`app/pubspec.yaml` 只直接依赖
// `heracles_backend`，`dart_agent_core` 只是**传递依赖**；直接 import 会触发
// `depend_on_referenced_packages`，并把"框架内部类型"变成 App 的编译期契约
// （同款判断见 `local_agent.dart` 的注释）。把探活放 backend，边界一致：
// **MCP 这一摊事只在 backend**，App 只消费公共面。
//
// 三条仍然成立的纪律：
//   · `connector` 注入缝保留（测试/宿主可替换），但**生产默认就是真探活**；
//   · **绝不**返回假的 `connected` / 假的 `tools` 数；
//   · backend 探活把它自己的 `unsupported`/`failed` 交上来时，本层原样转成失败，
//     不做"洗成成功"的翻译。
//
// ============================================================================
// 日志 / 错误文案纪律（SEC）
// ============================================================================
// · `env` 的**值**永不出现在任何日志、异常、错误文案里（配置里出现密钥直接在本地被拒，
//   连通道都不发）；
// · URL 一律走 [McpService.redactUrl]：只留 scheme + host + port + path，
//   query / fragment / userinfo 全部丢掉（`?api_key=`、`#token=` 是常见的泄密点）；
// · `Authorization` 头的值会被 [McpService.sanitizeError] 抹掉；
// · 错误文案里的异常原文截断到 [_maxErrorChars]：宿主/框架的异常里常带整条请求。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:heracles_backend/heracles_backend.dart'
    show
        ContractMcp,
        McpServerConfig,
        probeMcpConnection,
        redactMcpUrl,
        sanitizeMcpError,
        validateMcpServer;

// ============================================================================
// 错误码（★ 是本文件内部扩展，不跨 wire；跨 wire 的只有 ContractMcp.err*）
// ============================================================================

/// MCP 服务层的错误码词表。
abstract final class McpErrorCode {
  /// 宿主没有 MCP 能力（`MissingPluginException`：旧 APK / 未注册该通道）。
  ///
  /// ⚠️ 与"没有配置服务器"**必须区分**：两者都表现为"列表是空的"，
  /// 但前者是"这个客户端根本做不到"，后者是"你还没加"。混为一谈会让用户
  /// 反复去"添加服务器"，而真正该做的是升级 App。
  static const String hostUnsupported = 'E_MCP_HOST_UNSUPPORTED';

  /// 通道调用本身失败（平台异常 / 超时）。
  static const String channelIo = 'E_MCP_CHANNEL_IO';

  /// 宿主返回的形状不对（缺 `servers` 数组等）。
  static const String badResponse = 'E_MCP_BAD_RESPONSE';

  /// ★ 宿主回了 `ok:false` 但没给 code（只给一句人话）。
  static const String hostRejected = 'E_MCP_HOST_REJECTED';
}

/// MCP 服务层唯一的失败出口（`listServers()` 用；其余方法用结果对象，不抛）。
///
/// 为什么 `listServers` 抛而不是返回空列表：空列表与"没配置"同形，
/// 调用方会当成正常态继续跑（记忆服务踩过同一个坑，见 `memory_service.dart`）。
class McpServiceError implements Exception {
  const McpServiceError(this.code, this.message);

  final String code;

  /// 给人看的一句话（**不含 env 值 / URL query / 认证头**）。
  final String message;

  /// 是否属于"这个宿主版本没有 MCP 能力"（UI 据此显示"请升级 App"而不是"还没配置"）。
  bool get hostUnsupported => code == McpErrorCode.hostUnsupported;

  /// 统一的错误返回形状（与宿主 `{ok:false,code,error}` 同形，便于 UI 一套逻辑）。
  Map<String, Object?> toJson() => <String, Object?>{
        'ok': false,
        'code': code,
        'error': message,
      };

  @override
  String toString() => 'McpServiceError($code): $message';
}

// ============================================================================
// 数据模型
// ============================================================================

/// 一次连接测试的结果（**如实四态**，没有"大概连上了"）。
class McpTestResult {
  const McpTestResult({
    required this.status,
    this.tools,
    this.error,
    this.latencyMs = 0,
  });

  /// `not_configured` | `unsupported` | `failed` | `connected`（[ContractMcp] 的词表）。
  final String status;

  /// 工具数：**只有 `connected` 才有**，其余一律 `null`（0 也不给 —— 0 会被读成"连上了但没工具"）。
  final int? tools;

  /// 人话原因（`connected` 时 `null`）。
  final String? error;

  /// 从发起连接测试到拿到结果的实际耗时（毫秒）。
  ///
  /// `unsupported` / `not_configured` 恒为 0：这两个状态**根本没有发起连接**，
  /// 报个数字会让人误以为"测过了"。
  final int latencyMs;

  bool get isConnected => status == ContractMcp.statusConnected;

  /// 是否给用户"去改配置"的动作（而不是"重试"）。
  bool get needsConfig => status == ContractMcp.statusNotConfigured;

  @override
  String toString() =>
      'McpTestResult($status, tools: $tools, ${latencyMs}ms)'
      '${error == null ? '' : ', error: $error'}';
}

/// 保存结果（`ok:false` 时 `code` + `error` 必有）。
class McpSaveResult {
  const McpSaveResult({required this.ok, this.code, this.error});

  const McpSaveResult.success()
      : ok = true,
        code = null,
        error = null;

  const McpSaveResult.fail(this.code, this.error) : ok = false;

  final bool ok;
  final String? code;
  final String? error;

  @override
  String toString() => ok ? 'McpSaveResult(ok)' : 'McpSaveResult($code): $error';
}

/// 删除结果（`deleted` 是宿主的实话：名字不存在 ⇒ `ok:true, deleted:false`）。
class McpDeleteResult {
  const McpDeleteResult({
    required this.ok,
    this.deleted = false,
    this.code,
    this.error,
  });

  const McpDeleteResult.fail(this.code, this.error)
      : ok = false,
        deleted = false;

  final bool ok;
  final bool deleted;
  final String? code;
  final String? error;

  @override
  String toString() =>
      'McpDeleteResult(ok: $ok, deleted: $deleted)${code == null ? '' : ': $code'}';
}

/// 注入式连接测试的结果（低层形状，由 connector 返回）。
///
/// 为什么不直接让 connector 返回 [McpTestResult]：`status` 的四态判定、耗时、
/// 脱敏是**本服务的职责**；connector 只该说"通没通 / 几个工具 / 为什么不通"。
class McpConnectorOutcome {
  const McpConnectorOutcome({required this.ok, this.tools, this.error});

  /// 通了；[tools] 必须是**真实** discover 出来的工具数。
  const McpConnectorOutcome.connected(this.tools)
      : ok = true,
        error = null;

  /// 没通；[error] 是人话原因（会被 [McpService.sanitizeError] 清洗后再给用户看）。
  const McpConnectorOutcome.failed(this.error)
      : ok = false,
        tools = null;

  final bool ok;
  final int? tools;
  final String? error;
}

/// 连接测试的注入缝。
///
/// 生产**默认**不是 `null`：默认走 backend `probeMcpConnection`（见 [_probeViaBackend]）。
/// 只有测试或宿主想替换实现时才显式传一个。
typedef McpConnector = Future<McpConnectorOutcome> Function(McpServerConfig cfg);

// ============================================================================
// McpService
// ============================================================================

/// MCP 配置的读写门面 + 连接测试入口。
///
/// 通道：`heracles/command` 的 `mcpList` / `mcpSave` / `mcpDelete`。
/// 通道**不抛 PlatformException**（失败一律 `{ok:false,error,code}`），
/// 本类只把"平台层面根本调不通"（[MissingPluginException]）翻译成
/// [McpErrorCode.hostUnsupported]。
class McpService {
  McpService({
    MethodChannel? channel,
    McpConnector? connector,
    bool backendProbe = true,
    this.timeout = _defaultTimeout,
    this.probeTimeout = _defaultProbeTimeout,
    int Function()? nowMs,
  })  : _channel = channel ?? const MethodChannel(ContractMcp.channel),
        _injectedConnector = connector,
        _useBackendProbe = backendProbe,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// **不要探活**的构造（只给测试 / 特殊宿主）。
  ///
  /// 用它时 `testConnection` 会如实返回「连接测试未接入」而不是去连网络 ——
  /// 这个状态必须**能被显式表达**，否则"没接上"与"没配"就分不开了。
  factory McpService.withoutProbe({
    MethodChannel? channel,
    Duration timeout = _defaultTimeout,
    int Function()? nowMs,
  }) =>
      McpService(
        channel: channel,
        backendProbe: false,
        timeout: timeout,
        nowMs: nowMs,
      );

  /// 单次通道调用上限。宿主卡死时宁可给一句"超时"，也不许 UI 永久转圈。
  static const Duration _defaultTimeout = Duration(seconds: 10);

  /// backend 探活**每一次** RPC 的上限（握手 + 每次 tools/list 分页各算一次）。
  static const Duration _defaultProbeTimeout = Duration(seconds: 15);

  /// 本层总兜底：探活内部已有超时；这层只防"探活自己卡住"。
  static const Duration connectTimeout = Duration(seconds: 20);

  /// 旧宿主没有 MCP 能力时的说明（**必须**与"没配置服务器"区别开）。
  static const String hostUnsupportedMessage = '当前客户端版本没有 MCP 能力（宿主未实现 '
      '`${ContractMcp.listMethod}` 等方法）。这不等于"没有配置服务器"，请更新 App 后重试。';

  /// 连接测试未接入时的说明（只有 [McpService.withoutProbe] 会走到）。
  static const String connectorMissingMessage =
      '连接测试未接入（本实例显式关闭了探活）：本次**没有**真正连接，也不提供工具数。';

  final MethodChannel _channel;
  final McpConnector? _injectedConnector;
  final bool _useBackendProbe;
  final Duration timeout;

  /// backend 探活每一次 RPC 的上限（透传给 `probeMcpConnection`）。
  final Duration probeTimeout;
  final int Function() _nowMs;

  /// 实际生效的连接器：**注入优先**，其次 backend 探活，最后 `null`（未接入）。
  McpConnector? get connector {
    final injected = _injectedConnector;
    if (injected != null) return injected;
    return _useBackendProbe ? _probeViaBackend : null;
  }

  /// 生产实现：真连一次（backend `probeMcpConnection`）。
  ///
  /// 只做**翻译**不做修饰：backend 说 connected 才 connected，`tools` 只能用 backend 给的真实值；
  /// 其余状态（`unsupported` / `failed`）一律保持失败，原因原样带出（已是脱敏后的文本）。
  Future<McpConnectorOutcome> _probeViaBackend(McpServerConfig cfg) async {
    final r = await probeMcpConnection(cfg, timeout: probeTimeout);
    if (r.status == ContractMcp.statusConnected && r.tools != null) {
      return McpConnectorOutcome.connected(r.tools);
    }
    return McpConnectorOutcome.failed(
      r.error ??
          (r.status == ContractMcp.statusUnsupported
              ? ContractMcp.stdioUnsupportedMessage
              : '连接测试失败（探活没有给出原因）。'),
    );
  }

  // --------------------------------------------------------------------------
  // 读
  // --------------------------------------------------------------------------

  /// 列出全部草稿配置（宿主为准，本类不缓存）。
  ///
  /// 失败**抛** [McpServiceError]（空列表 ≠ 读失败 ≠ 没配置）：
  /// - 宿主 `ok:false` ⇒ 带宿主的 code 与人话；
  /// - 形状不对（缺 `servers`）⇒ [McpErrorCode.badResponse]；
  /// - 通道不存在（旧宿主）⇒ [McpErrorCode.hostUnsupported]。
  Future<List<McpServerConfig>> listServers() async {
    final raw = await _call(ContractMcp.listMethod, null);
    final map = _asMap(raw);
    if (map['ok'] != true) {
      throw McpServiceError(
        _codeOf(map) ?? McpErrorCode.hostRejected,
        sanitizeError('读取 MCP 配置失败：${_errorOf(map)}'),
      );
    }
    final list = map['servers'];
    if (list is! List) {
      // 缺键 ≠ 空数组：前者是宿主实现有问题，后者是"确实没配置"。
      throw const McpServiceError(
        McpErrorCode.badResponse,
        '宿主返回的 MCP 配置形状不对（缺 servers 数组），无法判断是否已配置。',
      );
    }
    final out = <McpServerConfig>[];
    var skipped = 0;
    for (final item in list) {
      if (item is! Map) {
        skipped++;
        continue;
      }
      final cfg = _serverFrom(item.cast<String, Object?>());
      if (cfg == null) {
        skipped++;
        continue;
      }
      out.add(cfg);
    }
    _log('list: ${out.length} 项${skipped > 0 ? '（跳过 $skipped 条坏数据）' : ''}');
    return out;
  }

  // --------------------------------------------------------------------------
  // 写
  // --------------------------------------------------------------------------

  /// 保存（新增或覆盖同名）。
  ///
  /// **两道本地闸**，都在调通道之前：
  /// 1. env 键名含 `KEY`/`TOKEN`/`SECRET`/`PASSWORD` ⇒ [ContractMcp.errSecretInEnv]。
  ///    这一条比 backend `validateMcpServer` 更宽（多了 `PASSWORD`），所以要先跑：
  ///    否则会落到 `errInvalidConfig`，用户看到的就不是"密钥别写这里"了。
  /// 2. backend `validateMcpServer`（name/transport/command/url 的形状）⇒
  ///    [ContractMcp.errInvalidConfig]。
  ///
  /// 返回结果对象而不抛：契约里通道就是不抛的，UI 一套 `r.ok` 逻辑到底。
  Future<McpSaveResult> saveServer(McpServerConfig cfg) async {
    final secretKeys = secretEnvKeys(cfg);
    if (secretKeys.isNotEmpty) {
      // 只报**键名**，绝不回显值。
      return McpSaveResult.fail(
        ContractMcp.errSecretInEnv,
        '不要把密钥写进 MCP 环境变量（${secretKeys.join('、')}）：MCP 配置会明文保存，'
        '密钥请放宿主的安全存储。',
      );
    }
    final invalid = validateMcpServer(cfg);
    if (invalid != null) {
      return McpSaveResult.fail(ContractMcp.errInvalidConfig, sanitizeError(invalid));
    }
    try {
      final raw = await _call(ContractMcp.saveMethod, <String, Object?>{
        'server': cfg.toJson(),
      });
      final map = _asMap(raw);
      if (map['ok'] == true) {
        _log('save: ${describe(cfg)}');
        return const McpSaveResult.success();
      }
      return McpSaveResult.fail(
        _codeOf(map) ?? McpErrorCode.hostRejected,
        sanitizeError(_errorOf(map)),
      );
    } on McpServiceError catch (e) {
      return McpSaveResult.fail(e.code, e.message);
    }
  }

  /// 删除（名字不存在 ⇒ `ok:true, deleted:false`，不谎报删掉了）。
  Future<McpDeleteResult> deleteServer(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const McpDeleteResult.fail(
        McpErrorCode.badResponse,
        '要删除的 MCP 服务器名是空的。',
      );
    }
    try {
      final raw = await _call(ContractMcp.deleteMethod, <String, Object?>{
        'name': trimmed,
      });
      final map = _asMap(raw);
      if (map['ok'] != true) {
        return McpDeleteResult.fail(
          _codeOf(map) ?? McpErrorCode.hostRejected,
          sanitizeError(_errorOf(map)),
        );
      }
      final deleted = map['deleted'] == true;
      _log('delete: $trimmed -> deleted=$deleted');
      return McpDeleteResult(ok: true, deleted: deleted);
    } on McpServiceError catch (e) {
      return McpDeleteResult.fail(e.code, e.message);
    }
  }

  // --------------------------------------------------------------------------
  // 连接测试
  // --------------------------------------------------------------------------

  /// 测一台服务器能不能连上（**不落库、不改配置**）。
  ///
  /// 四态判定（顺序即优先级）：
  /// - 名字不在配置里 ⇒ `not_configured`（先让用户去加配置，而不是看一个连接超时）；
  /// - `transport == stdio` ⇒ `unsupported` + [ContractMcp.stdioUnsupportedMessage]，
  ///   **不发起连接**（手机端没有可执行子进程环境，试也是白等）；
  /// - 没有可用 connector（只有 [McpService.withoutProbe] 会这样）⇒ `failed` +
  ///   [connectorMissingMessage]（如实，不假报）；
  /// - 其余交给 connector（生产 = backend 探活），通 ⇒ `connected` + 真实工具数；
  ///   不通 ⇒ `failed` + 人话。
  Future<McpTestResult> testConnection(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return const McpTestResult(
        status: ContractMcp.statusNotConfigured,
        error: '没有指定要测试的 MCP 服务器名。',
      );
    }

    McpServerConfig? cfg;
    try {
      final servers = await listServers();
      for (final s in servers) {
        if (s.name == trimmed) {
          cfg = s;
          break;
        }
      }
    } on McpServiceError catch (e) {
      // 配置都读不出来时，"失败原因"就是读失败本身（别假装是连接失败）。
      return McpTestResult(status: ContractMcp.statusFailed, error: e.message);
    }
    if (cfg == null) {
      return McpTestResult(
        status: ContractMcp.statusNotConfigured,
        error: '未找到名为「$trimmed」的 MCP 配置（可能已被删除）：请先在配置页添加。',
      );
    }

    if (cfg.transport == ContractMcp.transportStdio) {
      // latencyMs 保持 0：这里**没有**发起任何连接。
      return const McpTestResult(
        status: ContractMcp.statusUnsupported,
        error: ContractMcp.stdioUnsupportedMessage,
      );
    }

    final probe = connector;
    if (probe == null) {
      return const McpTestResult(
        status: ContractMcp.statusFailed,
        error: connectorMissingMessage,
      );
    }

    final startedAt = _nowMs();
    try {
      final outcome = await probe(cfg).timeout(connectTimeout);
      final latency = _nowMs() - startedAt;
      if (outcome.ok && outcome.tools != null) {
        _log('test: ${describe(cfg)} -> connected(${outcome.tools} tools, ${latency}ms)');
        return McpTestResult(
          status: ContractMcp.statusConnected,
          tools: outcome.tools,
          latencyMs: latency,
        );
      }
      // `ok:true` 但没给工具数 = 契约没被满足。不接受"大概连上了"：
      // 假 tools 数会让 UI 显示"已连接 · 0 个工具"，比直接说失败更误导。
      final reason = outcome.ok
          ? '连接测试返回了成功，但没有给出工具数（不接受"大概连上了"）。'
          : outcome.error ?? '连接失败（未给出原因）。';
      _log('test: ${describe(cfg)} -> failed(${latency}ms)');
      return McpTestResult(
        status: ContractMcp.statusFailed,
        error: sanitizeError(reason),
        latencyMs: latency,
      );
    } on TimeoutException {
      return McpTestResult(
        status: ContractMcp.statusFailed,
        error: '连接超时（${connectTimeout.inSeconds} 秒）：服务器没有响应。',
        latencyMs: _nowMs() - startedAt,
      );
    } catch (e) {
      return McpTestResult(
        status: ContractMcp.statusFailed,
        error: sanitizeError('连接失败：$e'),
        latencyMs: _nowMs() - startedAt,
      );
    }
  }

  // --------------------------------------------------------------------------
  // 安全：密钥识别 / 脱敏
  // --------------------------------------------------------------------------

  /// env 里**看起来是密钥**的键名（大小写无关）。
  ///
  /// 判据是"键名含关键字"而不是"值看起来像密钥"：键名是用户自己能看见、能改的，
  /// 提示"别把 X 写进 env"才有可操作性；靠值猜会漏掉自定义格式的 token。
  static List<String> secretEnvKeys(McpServerConfig cfg) => <String>[
        for (final k in cfg.env.keys)
          if (_secretKeyPattern.hasMatch(k)) k,
      ];

  static final RegExp _secretKeyPattern =
      RegExp(r'KEY|TOKEN|SECRET|PASSWORD', caseSensitive: false);

  /// URL 脱敏：**只留 scheme + host + port + path**。
  ///
  /// 实现**在 backend**（`redactMcpUrl`）—— 探活那边的错误文案也要脱敏，
  /// 两处各写一份就会漂移（一边改了另一边不会跟进，也没有编译错误提醒）。
  static String redactUrl(String raw) => redactMcpUrl(raw);

  /// 把任意文本洗成可以给用户看 / 写日志的样子（抹 `Authorization`/`Bearer`、
  /// URL 换成 [redactUrl] 结果、截断过长异常）。实现同样在 backend。
  ///
  /// **不保证**能抹掉任意秘密，所以真正的防线是"密钥根本不进 env"。
  static String sanitizeError(String raw) => sanitizeMcpError(raw);

  /// 一条配置的**可打印**摘要（日志 / 错误上下文用；不含 env，URL 已脱敏）。
  static String describe(McpServerConfig cfg) => cfg.transport == ContractMcp.transportHttp
      ? '${cfg.name} (http -> ${redactUrl(cfg.url)})'
      : '${cfg.name} (stdio)';

  // --------------------------------------------------------------------------
  // 内部：通道与解析
  // --------------------------------------------------------------------------

  /// 调通道并把"平台层面调不通"翻译成 [McpServiceError]。
  Future<Object?> _call(String method, Object? args) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args).timeout(timeout);
    } on MissingPluginException {
      throw const McpServiceError(
        McpErrorCode.hostUnsupported,
        hostUnsupportedMessage,
      );
    } on TimeoutException {
      throw McpServiceError(
        McpErrorCode.channelIo,
        '调用宿主 `$method` 超时（${timeout.inSeconds} 秒）：没有拿到回包。',
      );
    } on PlatformException catch (e) {
      // 契约上通道不抛 PlatformException；真抛了说明宿主实现有 bug，
      // 这里兜住并**只带 code**（message 里可能有请求细节）。
      throw McpServiceError(
        McpErrorCode.channelIo,
        sanitizeError('通道 `$method` 异常：${e.code}'),
      );
    }
  }

  Map<String, Object?> _asMap(Object? raw) {
    if (raw is Map) return raw.cast<String, Object?>();
    throw const McpServiceError(
      McpErrorCode.badResponse,
      '宿主返回的不是一个对象（与 §N16.2 的 {ok,...} 形状不符）。',
    );
  }

  McpServerConfig? _serverFrom(Map<String, Object?> j) {
    final name = '${j['name'] ?? ''}'.trim();
    if (name.isEmpty) return null; // 无名配置无法寻址，跳过（已在日志里计数）
    final transport = '${j['transport'] ?? ''}'.trim();
    final argsRaw = j['args'];
    final envRaw = j['env'];
    return McpServerConfig(
      name: name,
      transport: transport.isEmpty ? ContractMcp.transportHttp : transport,
      command: '${j['command'] ?? ''}',
      url: '${j['url'] ?? ''}',
      args: <String>[
        if (argsRaw is List) for (final a in argsRaw) '$a',
      ],
      env: <String, String>{
        if (envRaw is Map)
          for (final e in envRaw.entries) '${e.key}': '${e.value}',
      },
      enabled: j['enabled'] != false, // 缺省 true（与 backend 模型默认一致）
    );
  }

  String? _codeOf(Map<String, Object?> j) {
    final c = j['code'];
    if (c is! String) return null;
    final t = c.trim();
    return t.isEmpty ? null : t;
  }

  String _errorOf(Map<String, Object?> j) {
    final e = j['error'];
    if (e is String && e.trim().isNotEmpty) return e.trim();
    return '宿主没有给出失败原因。';
  }

  void _log(String message) {
    // SEC：只到这里为止 —— 调用方保证 message 里没有 env 值与 URL 的 query 段。
    debugPrint('[heracles][mcp] $message');
  }

  @override
  String toString() =>
      'McpService(connector: ${connector == null ? '未接入' : '已注入'})';
}
