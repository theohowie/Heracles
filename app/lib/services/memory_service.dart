// Copyright (C) 2026 The Heracles Authors
//
// **三作用域记忆服务（App 侧核心）** —— 2026-10-29 记忆分层重设计。
//
// ============================================================================
// 这个文件负责什么（不负责什么）
// ============================================================================
// 按设计稿 §3.1 / §3.2 / §3.3 / §3.6 与 `docs/INTERFACE.md` §N12：
//
// | 职责 | 在本文件 | 备注 |
// |---|---|---|
// | 地址 8 步强校验（fail-closed） | ✅ | 1/2/6/7 本地做；3/4/5 用注入回调 |
// | JSONL 解析 / 墓碑折叠 / compact | ✅ | 记忆文件不是会话正文，允许整体重写 |
// | 按文件路径的写队列 | ✅ | 覆盖「读→判→淘汰→追加」整个事务 |
// | 淘汰（过期→旧 agent→旧 user→拒写） | ✅ | 回报 `evicted`，不静默丢条目 |
// | global 作用域读写 | ✅ 路由 | 走 `memory.*` 通道（Kotlin 是唯一写者） |
// | workspace / session 读写 | ✅ 路由 | 走 `fs.*`：`<工作区>/.heracles/memory/…` |
//
// **不负责**：宿主接线（agent 构造前读三段、RunOptions.memory、AgentBridge
// 新方法）—— 那是 task-8b；会话正文的 append-only 纪律与本文件无关（记忆
// 单独成文件，**绝不**写进会话正文 `.jsonl`，也绝不放 App 私有 `sessions/`）。
//
// ============================================================================
// 三条不变量（别在实现里违背）
// ============================================================================
// I1: `scope` + `sessionId`/`workspacePath` 三要素齐全才动手。任何一步校验失败
//     **抛异常**，绝不回落到 global/workspace/默认实例 —— "空"与"错"绝不同形。
// I2: 改写一律**追加**（条目重写 = 同 id 后写者胜；删除/清空 = 墓碑），
//     只有 compact 才整体重写（先 `.tmp` 再 `fs.rename`，失败保留原文件）。
// I3: 存储预算 ≠ 注入预算。本文件只碰存储软预算（`MemoryStoreBudget`，
//     数值来自 backend `ContractMemory`）；注入预算由 backend `memory_prompt.dart` 管。
//
// ============================================================================
// 日志纪律（SEC）
// ============================================================================
// 记忆正文是用户隐私：本文件**任何**日志/错误只允许出现 id、条数、字符长度、
// 路径与错误码 —— 不许打印 `text` 内容。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:heracles_backend/heracles_backend.dart'
    show
        ContractMemory,
        MemoryAddress,
        MemoryAddressError,
        MemoryRecord,
        MemoryScope,
        memoryKeywords,
        memoryRelevanceScore;

import 'device_capabilities.dart';
import 'session_store.dart';

// ============================================================================
// 错误码（INTERFACE §N12.4 的码表；带 ★ 的是本文件内部扩展，不跨 wire）
// ============================================================================

/// 记忆服务的错误码词表。
abstract final class MemoryErrorCode {
  /// 第 1 步：scope 与 sessionId/workspacePath 的必填关系不符。
  static const String scopeMismatch = 'E_SCOPE_MISMATCH';

  /// 第 2 步：会话 id 形状不合法（`^s[0-9]{10,16}$`）。
  static const String sidFormat = 'E_SID_FORMAT';

  /// 第 3 步：会话不在 `sessions.json`。
  static const String sidUnknown = 'E_SID_UNKNOWN';

  /// 第 4 步：工作区未登记 / 不是绝对路径。
  static const String workspaceUnknown = 'E_WORKSPACE_UNKNOWN';

  /// 第 5 步：解析出的目标路径与规范路径不逐字相等。
  static const String pathMismatch = 'E_PATH_MISMATCH';

  /// 第 6 步：对 global 的 agent 写操作（全局只读）。
  static const String scopeReadonly = 'E_SCOPE_READONLY';

  /// 第 7 步：单条正文超 `ContractMemory.entryMaxChars`；或淘汰后仍放不下。
  static const String entryTooLong = 'E_ENTRY_TOO_LONG';

  /// 通道/文件读写失败。
  static const String storeIo = 'E_STORE_IO';

  /// ★ 内部扩展：正文为空（不落半条空记忆）。
  static const String entryEmpty = 'E_ENTRY_EMPTY';

  /// ★ 内部扩展：要更新/删除的条目不存在。
  static const String entryNotFound = 'E_ENTRY_NOT_FOUND';

  /// ★ 内部扩展：正文疑似含密钥/令牌（SEC4，明文存储的泄露风险）。
  static const String secretRejected = 'E_SECRET_REJECTED';
}

/// 记忆服务唯一的失败出口。
///
/// 为什么抛异常而不是返回 `null`/空列表：空列表与"没有记忆"同形，
/// 调用方会当成正常态继续跑（旧 `read() → ''` 的教训，设计稿 §3.3.2）。
/// 宿主捕获后按"本轮该段无记忆 + 上报错误"处理，**绝不回落**。
class MemoryServiceError implements Exception {
  const MemoryServiceError(this.code, this.message, {this.address});

  final String code;

  /// 给人看的一句话（**不得含记忆正文**，只允许寻址/条数/长度）。
  final String message;

  /// 出错时的寻址形状（排障用）。
  final Map<String, Object?>? address;

  /// 统一的错误返回形状（`{ok:false,code,error,address}`）。
  Map<String, Object?> toJson() => <String, Object?>{
        'ok': false,
        'code': code,
        'error': message,
        if (address != null) 'address': address,
      };

  @override
  String toString() => 'MemoryServiceError($code): $message'
      '${address == null ? '' : ' @ $address'}';
}

// ============================================================================
// 预算（存储侧；数值唯一来源 = backend `ContractMemory`）
// ============================================================================

/// 存储软预算（**可注入小数值，便于单测**）。
///
/// 默认值全部来自 backend `ContractMemory`（三侧同一组数，见 INTERFACE §N12.8）；
/// 单测把预算调小，才能在不造几 MB 数据的前提下验证淘汰顺序。
class MemoryStoreBudget {
  const MemoryStoreBudget({
    this.workspaceStorageSoftMaxBytes = ContractMemory.storageWorkspaceSoftMaxBytes,
    this.sessionStorageSoftMaxBytes = ContractMemory.storageSessionSoftMaxBytes,
    this.workspaceEntriesSoftMax = ContractMemory.entriesSoftMax,
    this.sessionEntriesSoftMax = ContractMemory.sessionEntriesSoftMax,
    this.entryMaxChars = ContractMemory.entryMaxChars,
  });

  /// workspace 作用域存储软预算（字节）。
  final int workspaceStorageSoftMaxBytes;

  /// session 作用域（每个会话）存储软预算（字节）。
  final int sessionStorageSoftMaxBytes;

  /// workspace 作用域条目软上限。
  final int workspaceEntriesSoftMax;

  /// session 作用域（每个会话）条目软上限。
  final int sessionEntriesSoftMax;

  /// 单条正文长度上限（字符）。
  final int entryMaxChars;

  /// 某作用域的字节软预算。
  int storageSoftMaxBytesOf(MemoryScope scope) => switch (scope) {
        MemoryScope.workspace => workspaceStorageSoftMaxBytes,
        MemoryScope.session => sessionStorageSoftMaxBytes,
        // global 的预算在 Kotlin（唯一写者）；这里给个同值只为统计展示。
        MemoryScope.global => ContractMemory.storageGlobalSoftMaxBytes,
      };

  /// 某作用域的条目软上限。
  int entriesSoftMaxOf(MemoryScope scope) => switch (scope) {
        MemoryScope.workspace => workspaceEntriesSoftMax,
        MemoryScope.session => sessionEntriesSoftMax,
        MemoryScope.global => ContractMemory.entriesSoftMax,
      };

  /// compact 触发阈值：无效行占比 ≥ 该值（设计稿 §3.2.2）。
  static const double compactInvalidRatio = 0.5;

  /// compact 触发阈值：文件字节数 ≥ 软预算 × 该值。
  static const double compactSizeRatio = 0.8;
}

// ============================================================================
// 数据模型（JSONL 行形状见 INTERFACE §N12.3）
// ============================================================================

/// 一条记忆（三作用域同一形状）。
///
/// 名字带 `Scoped` 是为了不与 App 旧模型 `global_memory.dart` 的
/// [MemoryEntry]（没有 scope/sid）混淆 —— **JSON 形状只有一套**：
/// `{v,id,scope,sid?,kind,text,source,createdAt,expiresAt?}`。
class ScopedMemoryEntry {
  const ScopedMemoryEntry({
    required this.id,
    required this.scope,
    this.sid,
    required this.kind,
    required this.text,
    required this.source,
    required this.createdAt,
    this.expiresAt,
  });

  final String id;
  final MemoryScope scope;

  /// 当且仅当 [scope] == session 时非空（落盘校验锚点）。
  final String? sid;

  final String kind;
  final String text;
  final String source;
  final int createdAt;
  final int? expiresAt;

  /// 是否已过期（边界 `<=`：到期即不可用，与旧 `MemoryEntry.isAlive` 同口径）。
  bool isExpiredAt(int nowMs) {
    final exp = expiresAt;
    return exp != null && exp <= nowMs;
  }

  /// 落盘 JSON 行（字段顺序固定，便于人读与 diff）。
  Map<String, Object?> toJson() => <String, Object?>{
        'v': 1,
        'id': id,
        'scope': scope.wireName,
        if (scope == MemoryScope.session) 'sid': sid,
        'kind': kind,
        'text': text,
        'source': source,
        'createdAt': createdAt,
        if (expiresAt != null) 'expiresAt': expiresAt,
      };

  /// 转成 backend 的 `MemoryRecord`（task-8b 填 `RunOptions.memory` 用）。
  MemoryRecord toRecord() => MemoryRecord(
        id: id,
        scope: scope,
        kind: kind,
        text: text,
        source: source,
        createdAt: createdAt,
        expiresAt: expiresAt,
      );

  /// 深拷贝（更新/迁移时改字段用）。
  ScopedMemoryEntry copyWith({String? text, String? kind, String? source}) =>
      ScopedMemoryEntry(
        id: id,
        scope: scope,
        sid: sid,
        kind: kind ?? this.kind,
        text: text ?? this.text,
        source: source ?? this.source,
        createdAt: createdAt,
        expiresAt: expiresAt,
      );

  @override
  String toString() =>
      'ScopedMemoryEntry(${scope.wireName}, $source, ${text.length} 字)';
}

/// 一次读取的扫描结果。
class MemoryScanResult {
  const MemoryScanResult({
    required this.entries,
    this.skippedForeign = 0,
    this.invalidLines = 0,
    this.totalLines = 0,
    this.truncated = false,
  });

  /// 存活条目（已折叠墓碑、同 id 后写者胜；`read` 默认已过滤过期）。
  final List<ScopedMemoryEntry> entries;

  /// 因 `scope`/`sid` 与寻址不符而被丢弃的条目数（第 8 步：绝不注入）。
  final int skippedForeign;

  /// 文件里非存活行数（墓碑 + 同 id 旧版本 + 坏行 + foreign 行）。
  final int invalidLines;

  /// 文件里非空行总数（compact 占比计算用）。
  final int totalLines;

  /// 读取是否被通道 1 MB 上限截断（截断时只解析了尾部）。
  final bool truncated;
}

/// 一次写入的结果（成功才返回；失败抛 [MemoryServiceError]）。
class MemoryWriteOutcome {
  const MemoryWriteOutcome({
    this.id,
    this.entries = 0,
    this.bytes = 0,
    this.evicted = const <String>[],
  });

  /// 本次写入是否成功（成功才返回该对象；失败一律抛 [MemoryServiceError]）。
  bool get ok => true;

  /// 新增/更新的条目 id（删除/清空为 null）。
  final String? id;

  /// 写入后该作用域的存活条目数。
  final int entries;

  /// 写入后该文件的字节数。
  final int bytes;

  /// 为腾预算被淘汰的条目 id（**不静默丢条目**）。
  final List<String> evicted;
}

/// 一次 compact 的结果。
class MemoryCompactResult {
  const MemoryCompactResult({
    required this.beforeLines,
    required this.afterLines,
    required this.removed,
  });

  final int beforeLines;
  final int afterLines;
  final int removed;
}

/// 记忆统计（存储侧；注入侧数字由 backend 给）。
class ScopedMemoryStats {
  const ScopedMemoryStats({
    required this.scope,
    required this.entries,
    required this.bytes,
    required this.storageSoftMaxBytes,
    required this.entriesSoftMax,
  });

  final MemoryScope scope;
  final int entries;
  final int bytes;
  final int storageSoftMaxBytes;
  final int entriesSoftMax;
}

/// 一条待确认的全局记忆提议（agent 写 global 的唯一通道）。
class ScopedMemoryProposal {
  const ScopedMemoryProposal({
    required this.id,
    required this.text,
    required this.kind,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String text;
  final String kind;
  final String status;
  final int createdAt;
}

// ============================================================================
// 地址校验的上下文（内部）
// ============================================================================

/// 校验通过后的寻址（含算好的目标文件路径）。
class _ResolvedAddress {
  const _ResolvedAddress({
    required this.scope,
    this.workspacePath,
    this.sessionId,
    this.path,
  });

  final MemoryScope scope;
  final String? workspacePath;
  final String? sessionId;

  /// workspace/session 的目标记忆文件绝对路径；global 为 null。
  final String? path;
}

/// 一次文件扫描的原始结果（未过滤过期）。
class _FileScan {
  const _FileScan({
    required this.entries,
    required this.totalLines,
    required this.skippedForeign,
    required this.truncated,
  });

  final List<ScopedMemoryEntry> entries;
  final int totalLines;
  final int skippedForeign;
  final bool truncated;

  int get invalidLines =>
      totalLines > entries.length ? totalLines - entries.length : 0;
}

// ============================================================================
// SEC4：疑似密钥/令牌（与 backend save_memory、global_memory 同一口径）
// ============================================================================

/// 与 `global_memory.dart` 的 `_secretPattern` **逐字一致**（同一道闸）。
final RegExp _secretPattern = RegExp(
    r'(sk-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}'
    r'|gho_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{15,}|[A-Fa-f0-9]{32,})');

// ============================================================================
// ScopedMemoryService
// ============================================================================

/// **三作用域记忆的读写核心**（App 侧）。
///
/// ## 构造参数（为什么要注入）
///
/// 第 3/4/5 步校验依赖宿主数据（`sessions.json` / 工作区登记表 / 宿主路径
/// 解析），注入后单测能在**不启 Flutter 引擎**的情况下逐条验错误码；
/// 生产默认值直接走 [SessionStore] 与 `heracles/command` 的工作区登记表。
///
/// ## 写队列（不变量）
///
/// 同一文件的所有写操作串行（`_queues[path]` 的 Future 链），覆盖
/// 「读→判→淘汰→追加」**整个事务** —— 否则两个 append 各自读到旧文件 ⇒
/// 丢一条。会话正文与记忆文件是两条独立队列，互不阻塞。
///
/// ## 池化（`memoryPooling`）
///
/// 本类**不缓存解析结果**（默认关；池化是 8b 的可选优化）。没有缓存就没有
/// "key 缺失 ⇒ 用默认实例"的串台入口（设计稿 §3.6.2 的红线）。
class ScopedMemoryService {
  /// 工厂：命名参数（可读性好）→ 私有位置参数构造（避免
  /// `prefer_initializing_formals` 对私有字段的误报；字段仍是私有的）。
  factory ScopedMemoryService({
    DeviceChannelClient? channel,
    MethodChannel? workspaceChannel,
    MemoryStoreBudget budget = const MemoryStoreBudget(),
    Future<bool> Function(String workspacePath, String sessionId)? hasSession,
    Future<Set<String>> Function()? listWorkspaces,
    String Function(String workspacePath, String sessionId)? sessionPathFor,
    String Function(String workspacePath)? workspacePathFor,
    int Function()? nowMs,
  }) =>
      ScopedMemoryService._(
        channel ?? const DeviceChannelClient(),
        workspaceChannel ?? _kWorkspaceChannel,
        budget,
        hasSession,
        listWorkspaces,
        sessionPathFor,
        workspacePathFor,
        nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
      );

  ScopedMemoryService._(
    this._ch,
    this._workspaceChannel,
    this.budget,
    this._hasSession,
    this._listWorkspaces,
    this._sessionPathFor,
    this._workspacePathFor,
    this._nowMs,
  );

  /// 工作区登记表通道（`heracles/command` 的 `listWorkspaces`）。
  ///
  /// 直接用通道而不是 import `AgentBridge`：`AgentBridge` 在 task-8b 会
  /// import 本文件，反向 import 会成环；而且本类只需要"取登记表"这一件事。
  static const MethodChannel _kWorkspaceChannel =
      MethodChannel('heracles/command');

  /// 记忆文件所在的工作区相对目录（`<工作区>/.heracles/memory`）。
  static const String memoryDirRel = '.heracles/memory';

  final DeviceChannelClient _ch;
  final MethodChannel _workspaceChannel;
  final MemoryStoreBudget budget;

  final Future<bool> Function(String, String)? _hasSession;
  final Future<Set<String>> Function()? _listWorkspaces;
  final String Function(String, String)? _sessionPathFor;
  final String Function(String)? _workspacePathFor;
  final int Function() _nowMs;

  /// `path → 排在队尾的 Future`（写事务串行化）。
  final Map<String, Future<void>> _queues = <String, Future<void>>{};

  /// 已经 mkdir 过的目录（一实例只建一次，避免每次写都多发两条通道调用）。
  final Set<String> _ensuredDirs = <String>{};

  /// 递增序号：同一毫秒内的多条记忆 id 不撞（id 形状仍是 `m<epochMicros>`）。
  int _idSeq = 0;

  // --------------------------------------------------------------------------
  // 静态路径工具（8b 与测试都用同一套拼装，避免第二份真相）
  // --------------------------------------------------------------------------

  /// 规范化工作区绝对路径：`\`→`/`、折叠 `//`、去尾部 `/`。
  ///
  /// 返回 `null` = 不是可用的设备绝对路径（调用方按 E_WORKSPACE_UNKNOWN 处理）。
  static String? normalizeWorkspacePath(String? raw) {
    if (raw == null) return null;
    var t = raw.trim().replaceAll('\\', '/');
    if (t.isEmpty || !t.startsWith('/')) return null;
    t = t.replaceAll(RegExp('/{2,}'), '/');
    if (t.length > 1 && t.endsWith('/')) t = t.substring(0, t.length - 1);
    return t;
  }

  /// 工作区记忆目录：`<ws>/.heracles/memory`。
  static String workspaceMemoryDir(String workspacePath) =>
      '${normalizeWorkspacePath(workspacePath) ?? workspacePath}/$memoryDirRel';

  /// workspace 作用域文件：`<ws>/.heracles/memory/workspace.jsonl`。
  static String workspaceMemoryFile(String workspacePath) =>
      '${workspaceMemoryDir(workspacePath)}/workspace.jsonl';

  /// session 作用域文件：`<ws>/.heracles/memory/session/<sid>.jsonl`。
  static String sessionMemoryFile(String workspacePath, String sessionId) =>
      '${workspaceMemoryDir(workspacePath)}/session/$sessionId.jsonl';

  // --------------------------------------------------------------------------
  // 读
  // --------------------------------------------------------------------------

  /// 读一个作用域的存活条目（默认过滤过期）。
  ///
  /// - global ⇒ `memory.list`（旧 APK 没有该方法时回落 `memory.read` 解析）；
  /// - workspace/session ⇒ `fs.readText` 读 JSONL（超过通道 1 MB 上限时改
  ///   `readTailLines` 取尾部，并在结果上标 `truncated`）。
  ///
  /// 校验失败抛 [MemoryServiceError]（fail-closed，"空"与"错"不同形）。
  Future<MemoryScanResult> read(
    MemoryAddress address, {
    bool includeExpired = false,
  }) async {
    final resolved = await _validate(address, writing: false);
    if (resolved.scope == MemoryScope.global) {
      return _readGlobal(includeExpired: includeExpired);
    }
    final scan = await _scanFile(
      resolved.path!,
      scope: resolved.scope,
      expectedSid: resolved.sessionId,
    );
    final now = _nowMs();
    final entries = includeExpired
        ? scan.entries
        : scan.entries.where((e) => !e.isExpiredAt(now)).toList();
    return MemoryScanResult(
      entries: entries,
      skippedForeign: scan.skippedForeign,
      invalidLines: scan.invalidLines,
      totalLines: scan.totalLines,
      truncated: scan.truncated,
    );
  }

  // --------------------------------------------------------------------------
  // 写（agent 路径：workspace/session 本地写；global 永久拒绝）
  // --------------------------------------------------------------------------

  /// **agent 写记忆**（`save_memory` 的落点）。
  ///
  /// - `session` / `workspace` ⇒ 本地 JSONL 追加（带淘汰与墓碑）；
  /// - `global` ⇒ 恒抛 [MemoryErrorCode.scopeReadonly]（不变量 I4：
  ///   全局对 agent 只读，只能 [proposeGlobal]）。
  ///
  /// [kind] 词表：`preference / background / habit / other`。
  Future<MemoryWriteOutcome> append(
    MemoryAddress address,
    String text, {
    String kind = 'other',
  }) async {
    final resolved = await _validate(address, writing: true, agent: true);
    if (resolved.scope == MemoryScope.global) {
      // 第 6 步：agent 写 global（_validate 里已拦，这里再显式写一次防回归）
      throw const MemoryServiceError(
        MemoryErrorCode.scopeReadonly,
        '全局记忆只读：模型不能直接写入；请改用 propose_global_memory 提议，'
        '由用户确认后晋升。',
      );
    }
    return _writeLocal(
      resolved,
      text,
      kind: kind,
      source: MemoryRecord.sourceAgent,
    );
  }

  /// 删除若干条目（追加 `tomb:"del"`，**绝不整文件清空**）。
  Future<MemoryWriteOutcome> delete(
    MemoryAddress address,
    List<String> ids,
  ) async {
    final resolved = await _validate(address, writing: true, agent: true);
    if (resolved.scope == MemoryScope.global) {
      throw const MemoryServiceError(
        MemoryErrorCode.scopeReadonly,
        '全局记忆只读：agent 不能删除全局条目（用户可在记忆页操作）。',
      );
    }
    final cleaned = ids.where((e) => e.trim().isNotEmpty).toSet().toList();
    if (cleaned.isEmpty) {
      throw const MemoryServiceError(
        MemoryErrorCode.entryNotFound,
        '要删除的 id 列表是空的。',
      );
    }
    return _withQueue(resolved.path!, () async {
      final scan = await _scanFile(
        resolved.path!,
        scope: resolved.scope,
        expectedSid: resolved.sessionId,
      );
      final existing = scan.entries.map((e) => e.id).toSet();
      final missing = cleaned.where((id) => !existing.contains(id)).toList();
      if (missing.length == cleaned.length) {
        throw const MemoryServiceError(
          MemoryErrorCode.entryNotFound,
          '要删除的条目都不存在（可能已被删除）。',
        );
      }
      final now = _nowMs();
      final tomb = jsonEncode(<String, Object?>{
        'v': 1,
        'tomb': 'del',
        'ids': cleaned,
        'at': now,
      });
      await _appendRaw(resolved.path!, '$tomb\n');
      await _maybeCompact(resolved);
      final after = await _scanFile(
        resolved.path!,
        scope: resolved.scope,
        expectedSid: resolved.sessionId,
      );
      final bytes = await _fileBytes(resolved.path!);
      return MemoryWriteOutcome(
        entries: after.entries.length,
        bytes: bytes,
      );
    });
  }

  /// 清空一个作用域（追加 `tomb:"clear"`，**不是截断文件**）。
  Future<MemoryWriteOutcome> clear(MemoryAddress address) async {
    final resolved = await _validate(address, writing: true, agent: true);
    if (resolved.scope == MemoryScope.global) {
      throw const MemoryServiceError(
        MemoryErrorCode.scopeReadonly,
        '全局记忆只读：agent 不能清空全局记忆（用户可在记忆页操作）。',
      );
    }
    return _withQueue(resolved.path!, () async {
      final now = _nowMs();
      final tomb = jsonEncode(<String, Object?>{'v': 1, 'tomb': 'clear', 'at': now});
      await _appendRaw(resolved.path!, '$tomb\n');
      await _maybeCompact(resolved);
      final bytes = await _fileBytes(resolved.path!);
      return MemoryWriteOutcome(entries: 0, bytes: bytes);
    });
  }

  // --------------------------------------------------------------------------
  // 写（用户路径：global 允许，走 memory.userEdit；其余本地写）
  // --------------------------------------------------------------------------

  /// **用户路径新增**（记忆页 / AgentBridge 的用户动作）。
  ///
  /// global ⇒ `memory.userEdit{action:"add"}`（全局唯一的写入口在 Kotlin）；
  /// workspace/session ⇒ source=`user` 的本地追加。
  Future<MemoryWriteOutcome> userAdd(
    MemoryAddress address,
    String text, {
    String kind = 'other',
  }) async {
    _checkEntryText(text);
    final resolved = await _validate(address, writing: true, agent: false);
    if (resolved.scope == MemoryScope.global) {
      return _globalUserEdit(<String, Object?>{
        'action': 'add',
        'text': text.trim(),
        'kind': kind,
      });
    }
    return _writeLocal(
      resolved,
      text,
      kind: kind,
      source: MemoryRecord.sourceUser,
    );
  }

  /// 用户更新一条（global 走通道；本地 = 同 id 追加新版本）。
  Future<MemoryWriteOutcome> userUpdate(
    MemoryAddress address,
    String id,
    String text,
  ) async {
    _checkEntryText(text);
    final resolved = await _validate(address, writing: true, agent: false);
    if (resolved.scope == MemoryScope.global) {
      return _globalUserEdit(<String, Object?>{
        'action': 'update',
        'id': id,
        'text': text.trim(),
      });
    }
    return _updateLocal(resolved, id, text.trim());
  }

  /// 用户删除（global 走通道；本地 = tombstone）。
  Future<MemoryWriteOutcome> userDelete(
    MemoryAddress address,
    List<String> ids,
  ) async {
    final resolved = await _validate(address, writing: true, agent: false);
    if (resolved.scope == MemoryScope.global) {
      return _globalUserEdit(<String, Object?>{
        'action': 'delete',
        'ids': ids,
      });
    }
    return delete(address, ids);
  }

  /// 用户清空（global 走通道；本地 = tombstone clear）。
  Future<MemoryWriteOutcome> userClear(MemoryAddress address) async {
    final resolved = await _validate(address, writing: true, agent: false);
    if (resolved.scope == MemoryScope.global) {
      return _globalUserEdit(<String, Object?>{'action': 'clear'});
    }
    return clear(address);
  }

  // --------------------------------------------------------------------------
  // 全局提议（agent 写 global 的唯一通道）
  // --------------------------------------------------------------------------

  /// 提议一条全局记忆（进入 `proposals.jsonl`，用户确认后才晋升）。
  Future<MemoryWriteOutcome> proposeGlobal(String note, {String kind = 'other'}) async {
    _checkEntryText(note);
    final raw = await _ch.call('memory.propose', <String, Object?>{
      'note': note.trim(),
      'kind': kind,
    });
    final err = errorOf(raw);
    if (err != null) {
      throw MemoryServiceError(MemoryErrorCode.storeIo, '提议全局记忆失败：$err');
    }
    return MemoryWriteOutcome(
      id: raw['id'] as String?,
      entries: _intOf(raw['entries']) ?? 0,
      bytes: _intOf(raw['bytes']) ?? 0,
    );
  }

  /// 列出提议（默认 `pending`）。
  Future<List<ScopedMemoryProposal>> listProposals({String? status = 'pending'}) async {
    final args = <String, Object?>{};
    if (status != null) args['status'] = status;
    final raw = await _ch.call('memory.proposals', args);
    final err = errorOf(raw);
    if (err != null) {
      throw MemoryServiceError(MemoryErrorCode.storeIo, '读取记忆提议失败：$err');
    }
    final list = raw['entries'];
    if (list is! List) return const <ScopedMemoryProposal>[];
    return <ScopedMemoryProposal>[
      for (final item in list)
        if (item is Map)
          ScopedMemoryProposal(
            id: '${item['id'] ?? ''}',
            text: '${item['text'] ?? ''}',
            kind: '${item['kind'] ?? 'other'}',
            status: '${item['status'] ?? 'pending'}',
            createdAt: _intOf(item['createdAt']) ?? 0,
          ),
    ];
  }

  /// 晋升 / 忽略一条提议（**用户动作**，agent 不可触发）。
  Future<MemoryWriteOutcome> resolveProposal(String id, {required bool promote}) async {
    final raw = await _ch.call('memory.resolveProposal', <String, Object?>{
      'id': id,
      'action': promote ? 'promote' : 'reject',
    });
    final err = errorOf(raw);
    if (err != null) {
      throw MemoryServiceError(MemoryErrorCode.storeIo, '处理记忆提议失败：$err');
    }
    return MemoryWriteOutcome(id: raw['entryId'] as String?);
  }

  // --------------------------------------------------------------------------
  // 检索 / 统计 / 维护
  // --------------------------------------------------------------------------

  /// 关键词检索（与注入同一分词/打分口径；**不注入**）。
  Future<List<ScopedMemoryEntry>> search(
    MemoryAddress address,
    String query, {
    int limit = 20,
  }) async {
    final resolved = await _validate(address, writing: false);
    final keywords = memoryKeywords(query);
    if (resolved.scope == MemoryScope.global) {
      final raw = await _ch.call('memory.search', <String, Object?>{
        'query': query,
        'limit': limit,
      });
      final err = errorOf(raw);
      if (err == null) {
        final list = raw['entries'];
        final out = <ScopedMemoryEntry>[];
        if (list is List) {
          for (final item in list) {
            if (item is! Map) continue;
            final e = _entryFromChannel(item.cast<String, Object?>());
            if (e != null && e.scope == MemoryScope.global) out.add(e);
          }
        }
        return out.take(limit).toList();
      }
      if (!err.contains('未知方法')) {
        throw MemoryServiceError(MemoryErrorCode.storeIo, '检索全局记忆失败：$err');
      }
      // 旧 APK：回落本地打分
      final scan = await _readGlobal(includeExpired: false);
      return _rankByQuery(scan.entries, keywords, limit);
    }
    final scan = await read(address);
    return _rankByQuery(scan.entries, keywords, limit);
  }

  /// 某作用域的存储统计。
  Future<ScopedMemoryStats> stats(MemoryAddress address) async {
    final resolved = await _validate(address, writing: false);
    if (resolved.scope == MemoryScope.global) {
      final raw = await _ch.call('memory.stats');
      final err = errorOf(raw);
      if (err == null) {
        final limits = raw['limits'];
        return ScopedMemoryStats(
          scope: MemoryScope.global,
          entries: _intOf(raw['entries']) ?? 0,
          bytes: _intOf(raw['bytes']) ?? 0,
          storageSoftMaxBytes: _intOf(limits is Map ? limits['storageSoftMaxBytes'] : null) ??
              budget.storageSoftMaxBytesOf(MemoryScope.global),
          entriesSoftMax: budget.entriesSoftMaxOf(MemoryScope.global),
        );
      }
      if (!err.contains('未知方法')) {
        throw MemoryServiceError(MemoryErrorCode.storeIo, '读取全局记忆统计失败：$err');
      }
      final scan = await _readGlobal(includeExpired: true);
      return ScopedMemoryStats(
        scope: MemoryScope.global,
        entries: scan.entries.length,
        bytes: _entriesBytes(scan.entries),
        storageSoftMaxBytes: budget.storageSoftMaxBytesOf(MemoryScope.global),
        entriesSoftMax: budget.entriesSoftMaxOf(MemoryScope.global),
      );
    }
    final scan = await _scanFile(
      resolved.path!,
      scope: resolved.scope,
      expectedSid: resolved.sessionId,
    );
    return ScopedMemoryStats(
      scope: resolved.scope,
      entries: scan.entries.length,
      bytes: _entriesBytes(scan.entries),
      storageSoftMaxBytes: budget.storageSoftMaxBytesOf(resolved.scope),
      entriesSoftMax: budget.entriesSoftMaxOf(resolved.scope),
    );
  }

  /// 强制 compact：把存活条目整体重写（`.tmp` → `fs.rename`）。
  ///
  /// 只对 workspace/session 有效（global 的 compact 在 Kotlin）。失败保留原文件。
  Future<MemoryCompactResult> compact(MemoryAddress address) async {
    final resolved = await _validate(address, writing: true, agent: false);
    if (resolved.scope == MemoryScope.global) {
      throw const MemoryServiceError(
        MemoryErrorCode.scopeReadonly,
        'global 记忆的 compact 由设备桥（Kotlin）负责，Dart 侧不重写。',
      );
    }
    return _withQueue(resolved.path!, () async {
      final scan = await _scanFile(
        resolved.path!,
        scope: resolved.scope,
        expectedSid: resolved.sessionId,
      );
      await _rewriteLive(resolved, scan);
      final after = await _scanFile(
        resolved.path!,
        scope: resolved.scope,
        expectedSid: resolved.sessionId,
      );
      return MemoryCompactResult(
        beforeLines: scan.totalLines,
        afterLines: after.entries.length,
        removed: scan.totalLines - after.entries.length,
      );
    });
  }

  /// 删除某个会话的记忆文件（**SessionStore.deleteSession 的切入点**，8b 用）。
  ///
  /// 与 [read]/[append] 不同，这里**不校验会话是否还在 `sessions.json`**：
  /// 8b 的删除顺序可能是"先删索引、再删记忆"，那时 sid 已经不存在 ——
  /// 如果也走第 3 步，删除会被 E_SID_UNKNOWN 挡住，记忆文件永远残留。
  /// 仍然校验 **sid 形状（第 2 步）**、**工作区登记（第 4 步）**、
  /// **路径逐字相等（第 5 步）**，防止借删除做路径穿越。
  Future<bool> deleteSessionFile(String workspacePath, String sessionId) async {
    if (!MemoryAddress.sessionIdPattern.hasMatch(sessionId)) {
      throw MemoryServiceError(
        MemoryErrorCode.sidFormat,
        'sessionId 形状必须是 s<10~16 位数字>（收到 $sessionId）；删除记忆不会回落到别的路径。',
        address: <String, Object?>{'scope': 'session', 'sid': sessionId},
      );
    }
    final ws = normalizeWorkspacePath(workspacePath);
    if (ws == null) {
      throw const MemoryServiceError(
        MemoryErrorCode.workspaceUnknown,
        '工作区路径不是设备上的绝对路径。',
      );
    }
    final known = await _knownWorkspaces();
    if (!known.contains(ws)) {
      throw MemoryServiceError(
        MemoryErrorCode.workspaceUnknown,
        '工作区未登记：$ws（删除记忆不会猜别的工作区）。',
        address: <String, Object?>{'workspacePath': ws},
      );
    }
    final canonical = sessionMemoryFile(ws, sessionId);
    final resolvedPath =
        _sessionPathFor?.call(ws, sessionId) ?? canonical;
    if (_normalizeFsPath(resolvedPath) != canonical) {
      throw MemoryServiceError(
        MemoryErrorCode.pathMismatch,
        '解析出的目标路径与规范路径不一致，已拒绝删除。',
        address: <String, Object?>{'workspacePath': ws, 'sid': sessionId},
      );
    }
    final raw = await _ch.call('fs.delete', <String, Object?>{
      'path': canonical,
      'recursive': false,
    });
    final err = errorOf(raw);
    if (err == null || err.contains('不存在')) return true;
    throw MemoryServiceError(
      MemoryErrorCode.storeIo,
      '删除会话记忆文件失败：$err',
      address: <String, Object?>{'workspacePath': ws, 'sid': sessionId},
    );
  }

  // --------------------------------------------------------------------------
  // 地址 8 步校验
  // --------------------------------------------------------------------------

  /// 执行校验（第 1/2/6/7 步本地；第 3/4/5 步用注入回调）。
  Future<_ResolvedAddress> _validate(
    MemoryAddress address, {
    required bool writing,
    bool agent = true,
  }) async {
    // 第 1 步：scope ↔ 字段必填关系。
    //
    // ⚠️ backend `MemoryAddress.validate()` 把"session 但 sid 为 null"报成
    // `E_SID_FORMAT`；按 INTERFACE §N12.4 第 1 步，**缺字段属 scope 不匹配**，
    // 只有"字段在但形状不对"才是第 2 步的 `E_SID_FORMAT`。这里先补这一条，
    // 其余形状规则仍复用 backend 的唯一实现（不重写第二份）。
    if (address.scope == MemoryScope.session && address.sessionId == null) {
      throw MemoryServiceError(
        MemoryErrorCode.scopeMismatch,
        'session 记忆必须带 sessionId（会话私有记忆不接受"只给工作区"）。',
        address: address.toJson(),
      );
    }
    try {
      address.validate();
    } on MemoryAddressError catch (e) {
      throw MemoryServiceError(e.code, e.message, address: e.address);
    }

    final scope = address.scope;
    if (scope == MemoryScope.global) {
      // 第 6 步：global 对 agent 只读（用户路径 agent=false 才放行）
      if (writing && agent) {
        throw const MemoryServiceError(
          MemoryErrorCode.scopeReadonly,
          '全局记忆只读：模型不能直接写入；请改用 propose_global_memory 提议，'
          '由用户确认后晋升。',
          address: <String, Object?>{'scope': 'global'},
        );
      }
      return const _ResolvedAddress(scope: MemoryScope.global);
    }

    final ws = normalizeWorkspacePath(address.workspacePath);
    final sid = address.sessionId;

    // 第 3 步之前的前置：session/workspace 都必须有可用的绝对工作区路径。
    // （设计稿把"绝对路径 + 已登记"放在第 4 步；但没有路径时第 3 步的
    //  「会话是否存在」都无从查起，所以先在这里 fail-closed 成第 4 步的码。）
    if (ws == null) {
      throw MemoryServiceError(
        MemoryErrorCode.workspaceUnknown,
        '工作区路径不是设备上的绝对路径（收到 ${address.workspacePath}）。',
        address: address.toJson(),
      );
    }

    // 第 3 步：会话必须存在于 sessions.json（session 作用域）
    if (scope == MemoryScope.session) {
      final exists = await _sessionExists(ws, sid!);
      if (!exists) {
        throw MemoryServiceError(
          MemoryErrorCode.sidUnknown,
          '找不到会话 $sid（工作区 $ws）；记忆不会回落到全局/工作区。',
          address: address.toJson(),
        );
      }
    }

    // 第 4 步：工作区必须在登记表里
    final known = await _knownWorkspaces();
    if (!known.contains(ws)) {
      throw MemoryServiceError(
        MemoryErrorCode.workspaceUnknown,
        '工作区未登记：$ws（记忆不会猜别的工作区）。',
        address: address.toJson(),
      );
    }

    // 第 5 步：解析出的目标路径必须逐字等于规范路径
    final canonical = scope == MemoryScope.session
        ? sessionMemoryFile(ws, sid!)
        : workspaceMemoryFile(ws);
    final resolvedPath = scope == MemoryScope.session
        ? (_sessionPathFor?.call(ws, sid!) ?? canonical)
        : (_workspacePathFor?.call(ws) ?? canonical);
    if (_normalizeFsPath(resolvedPath) != canonical) {
      throw MemoryServiceError(
        MemoryErrorCode.pathMismatch,
        '解析出的目标路径与规范路径不一致（期望 $canonical，实际 $resolvedPath），'
        '已拒绝本次操作。',
        address: address.toJson(),
      );
    }

    return _ResolvedAddress(
      scope: scope,
      workspacePath: ws,
      sessionId: sid,
      path: canonical,
    );
  }

  /// 第 3 步的默认实现：`SessionStore.listSessions` 里有没有这个 id。
  Future<bool> _sessionExists(String workspacePath, String sessionId) async {
    final injected = _hasSession;
    if (injected != null) return injected(workspacePath, sessionId);
    try {
      final store = SessionStore(
        workspaceRoot: workspacePath,
        channel: _ch,
      );
      final list = await store.listSessions();
      return list.any((m) => m.id == sessionId);
    } catch (_) {
      return false;
    }
  }

  /// 第 4 步的默认实现：`heracles/command` 的 `listWorkspaces`。
  Future<Set<String>> _knownWorkspaces() async {
    final injected = _listWorkspaces;
    if (injected != null) {
      final set = await injected();
      final out = <String>{};
      for (final p in set) {
        final n = normalizeWorkspacePath(p);
        if (n != null) out.add(n);
      }
      return out;
    }
    try {
      final list = await _workspaceChannel.invokeListMethod<dynamic>('listWorkspaces');
      final out = <String>{};
      if (list != null) {
        for (final item in list) {
          if (item is! Map) continue;
          final n = normalizeWorkspacePath('${item['path'] ?? ''}');
          if (n != null) out.add(n);
        }
      }
      return out;
    } catch (_) {
      // 通道不可用 ⇒ 空集合 ⇒ 一律 E_WORKSPACE_UNKNOWN（fail-closed）
      return const <String>{};
    }
  }

  // --------------------------------------------------------------------------
  // 本地（workspace/session）写事务
  // --------------------------------------------------------------------------

  Future<MemoryWriteOutcome> _writeLocal(
    _ResolvedAddress resolved,
    String text, {
    required String kind,
    required String source,
  }) async {
    _checkEntryText(text);
    final trimmed = text.trim();
    final now = _nowMs();
    final entry = ScopedMemoryEntry(
      id: 'm${now * 1000 + (_idSeq++ % 1000)}',
      scope: resolved.scope,
      sid: resolved.sessionId,
      kind: kind,
      text: trimmed,
      source: source,
      createdAt: now,
    );
    return _withQueue(resolved.path!, () async {
      final scan = await _scanFile(
        resolved.path!,
        scope: resolved.scope,
        expectedSid: resolved.sessionId,
      );
      final evicted = _evictForRoom(
        scan.entries,
        entry,
        scope: resolved.scope,
        now: now,
      );
      final buf = StringBuffer();
      if (evicted.isNotEmpty) {
        buf.writeln(jsonEncode(<String, Object?>{
          'v': 1,
          'tomb': 'del',
          'ids': evicted,
          'at': now,
        }));
      }
      buf.writeln(jsonEncode(entry.toJson()));
      await _appendRaw(resolved.path!, buf.toString());
      await _maybeCompact(resolved);
      final after = await _scanFile(
        resolved.path!,
        scope: resolved.scope,
        expectedSid: resolved.sessionId,
      );
      final bytes = await _fileBytes(resolved.path!);
      return MemoryWriteOutcome(
        id: entry.id,
        entries: after.entries.length,
        bytes: bytes,
        evicted: evicted,
      );
    });
  }

  Future<MemoryWriteOutcome> _updateLocal(
    _ResolvedAddress resolved,
    String id,
    String text,
  ) async {
    _checkEntryText(text);
    return _withQueue(resolved.path!, () async {
      final scan = await _scanFile(
        resolved.path!,
        scope: resolved.scope,
        expectedSid: resolved.sessionId,
      );
      final existing = scan.entries.where((e) => e.id == id).toList();
      if (existing.isEmpty) {
        throw MemoryServiceError(
          MemoryErrorCode.entryNotFound,
          '条目不存在：$id（可能已被删除）。',
          address: _resolvedAddressJson(resolved),
        );
      }
      // 同 id 后写者胜：追加一条同 id 新版本，旧版本由 compact 折叠。
      final updated = existing.first.copyWith(text: text);
      final line = jsonEncode(updated.toJson());
      await _appendRaw(resolved.path!, '$line\n');
      await _maybeCompact(resolved);
      final bytes = await _fileBytes(resolved.path!);
      return MemoryWriteOutcome(id: id, entries: scan.entries.length, bytes: bytes);
    });
  }

  /// 淘汰：**只做腾位置，不落盘**（落盘由调用方把 tombstone + 新行一次写入）。
  ///
  /// 顺序（设计稿 §3.4.1，确定性，禁止随机）：
  /// ① 过期 → ② 最旧 `agent` → ③ 最旧 `user/promoted/legacy` → ④ 仍放不下抛
  /// [MemoryErrorCode.entryTooLong]（**绝不写半条**）。
  List<String> _evictForRoom(
    List<ScopedMemoryEntry> entries,
    ScopedMemoryEntry incoming, {
    required MemoryScope scope,
    required int now,
  }) {
    final live = List<ScopedMemoryEntry>.of(entries);
    final evicted = <String>[];
    final softMaxBytes = budget.storageSoftMaxBytesOf(scope);
    final softMaxEntries = budget.entriesSoftMaxOf(scope);
    final incomingLine = jsonEncode(incoming.toJson());

    int projected() {
      var total = _utf8Length(incomingLine) + 1;
      for (final e in live) {
        total += _utf8Length(jsonEncode(e.toJson())) + 1;
      }
      if (evicted.isNotEmpty) {
        total += _utf8Length(jsonEncode(<String, Object?>{
              'v': 1,
              'tomb': 'del',
              'ids': evicted,
              'at': now,
            })) +
            1;
      }
      return total;
    }

    var guard = entries.length + 1;
    while ((live.length + 1 > softMaxEntries || projected() > softMaxBytes) &&
        guard-- > 0) {
      final victim = _pickVictim(live, now);
      if (victim == null) {
        throw MemoryServiceError(
          MemoryErrorCode.entryTooLong,
          '存储软预算放不下这条记忆，且已无条目可淘汰（单条 ${incoming.text.length} '
          '字符 / 预算 $softMaxBytes 字节、$softMaxEntries 条）；'
          '**未写入任何内容**。请精简正文或先清理旧记忆。',
          address: <String, Object?>{'scope': scope.wireName},
        );
      }
      evicted.add(victim.id);
      live.removeWhere((e) => e.id == victim.id);
    }
    return evicted;
  }

  /// 选一个淘汰对象；没有可淘汰的返回 `null`。
  ScopedMemoryEntry? _pickVictim(List<ScopedMemoryEntry> live, int now) {
    if (live.isEmpty) return null;
    List<ScopedMemoryEntry> sorted(Iterable<ScopedMemoryEntry> src) =>
        src.toList()..sort((a, b) {
          final c = a.createdAt.compareTo(b.createdAt);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
    // ① 过期（过期条目最先走）
    final expired = sorted(live.where((e) => e.isExpiredAt(now)));
    if (expired.isNotEmpty) return expired.first;
    // ② 最旧 agent
    final agents = sorted(
      live.where((e) => e.source == MemoryRecord.sourceAgent),
    );
    if (agents.isNotEmpty) return agents.first;
    // ③ 最旧 user / promoted / legacy（user 最后动）
    final rest = sorted(live);
    return rest.isEmpty ? null : rest.first;
  }

  // --------------------------------------------------------------------------
  // 文件读写（fs.* 通道）
  // --------------------------------------------------------------------------

  /// 串行化同一文件的写事务。
  Future<T> _withQueue<T>(String path, Future<T> Function() op) {
    final previous = _queues[path] ?? Future<void>.value();
    final gate = Completer<void>();
    _queues[path] = gate.future;
    return previous.then((_) => op()).whenComplete(() {
      if (!gate.isCompleted) gate.complete();
      if (identical(_queues[path], gate.future)) _queues.remove(path);
    });
  }

  Future<void> _ensureDirs(String path) async {
    final memoryDir = _memoryDirOf(path);
    final dirs = <String>[
      memoryDir,
      if (_hasSessionDir(path)) '$memoryDir/session',
    ];
    for (final dir in dirs) {
      if (!_ensuredDirs.add(dir)) continue;
      // 目录已存在时宿主可能报错，忽略 —— 成败由随后的写操作决定。
      await _ch.call('fs.mkdir', <String, Object?>{'path': dir});
    }
  }

  bool _hasSessionDir(String path) => path.contains('/$memoryDirRel/session/');

  String _memoryDirOf(String path) {
    final i = path.indexOf('/$memoryDirRel/');
    return i > 0 ? path.substring(0, i + memoryDirRel.length + 1) : path;
  }

  /// 把通道文本读成全量/尾部文本；读不到（文件不存在）返回空串。
  Future<({String text, bool truncated})> _readText(String path) async {
    final raw = await _ch.call('fs.readText', <String, Object?>{
      'path': path,
      'offsetLine': 1,
      'maxLines': 0,
    });
    final err = errorOf(raw);
    if (err == null) {
      final text = (raw['text'] as String?) ?? '';
      if (raw['truncated'] != true) return (text: text, truncated: false);
      // 超过通道 1 MB 上限：改读尾部（记忆只注入候选窗，旧行不影响注入）
      final tail = await _ch.call('fs.readTailLines', <String, Object?>{
        'path': path,
        'maxLines': ContractMemory.retrievalMaxCandidates,
      });
      final tailErr = errorOf(tail);
      if (tailErr != null) return (text: text, truncated: true);
      return (text: (tail['text'] as String?) ?? '', truncated: true);
    }
    if (err.contains('不存在')) return (text: '', truncated: false);
    throw MemoryServiceError(
      MemoryErrorCode.storeIo,
      '读取记忆文件失败：$err',
      address: <String, Object?>{'path': path},
    );
  }

  Future<_FileScan> _scanFile(
    String path, {
    required MemoryScope scope,
    String? expectedSid,
  }) async {
    final read = await _readText(path);
    final folded = _parseAndFold(
      read.text,
      expectedScope: scope,
      expectedSid: expectedSid,
    );
    return _FileScan(
      entries: folded.entries,
      totalLines: folded.totalLines,
      skippedForeign: folded.skippedForeign,
      truncated: read.truncated,
    );
  }

  /// 解析 JSONL 并折叠墓碑（同 id 后写者胜）。
  _FoldResult _parseAndFold(
    String raw, {
    required MemoryScope expectedScope,
    String? expectedSid,
  }) {
    final live = <String, ScopedMemoryEntry>{};
    var totalLines = 0;
    var foreign = 0;
    var legacySeq = 0;

    for (var line in const LineSplitter().convert(raw)) {
      line = line.trim();
      if (line.isEmpty) continue;
      totalLines++;

      final brace = line.indexOf('{');
      if (brace < 0) {
        // 无结构纯文本行（旧数据）：按 legacy 条目保留，不丢内容
        legacySeq++;
        final entry = ScopedMemoryEntry(
          id: 'legacy-$legacySeq',
          scope: expectedScope,
          sid: expectedScope == MemoryScope.session ? expectedSid : null,
          kind: 'other',
          text: line,
          source: MemoryRecord.sourceLegacy,
          createdAt: 0,
        );
        live[entry.id] = entry;
        continue;
      }

      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(line.substring(brace));
        if (decoded is Map) json = decoded.cast<String, dynamic>();
      } catch (_) {
        json = null;
      }
      if (json == null) {
        // 坏 JSON 行：降级为 legacy 纯文本（宁可显示，也不丢内容）
        legacySeq++;
        final entry = ScopedMemoryEntry(
          id: 'legacy-$legacySeq',
          scope: expectedScope,
          sid: expectedScope == MemoryScope.session ? expectedSid : null,
          kind: 'other',
          text: line,
          source: MemoryRecord.sourceLegacy,
          createdAt: 0,
        );
        live[entry.id] = entry;
        continue;
      }

      // ---- 墓碑 ----
      final tomb = json['tomb'];
      if (tomb is String) {
        if (tomb == 'clear') {
          live.clear();
        } else if (tomb == 'del') {
          final ids = json['ids'];
          if (ids is List) {
            for (final id in ids) {
              live.remove('$id');
            }
          }
        }
        continue;
      }

      // ---- 条目 ----
      final id = json['id'];
      final text = json['text'];
      if (id is! String || id.trim().isEmpty || text is! String || text.isEmpty) {
        continue; // 坏条目：跳过这一行，其余照解析
      }
      final scopeRaw = json['scope'];
      final declaredScope =
          scopeRaw is String ? MemoryScope.tryParse(scopeRaw) : null;
      final entryScope = declaredScope ?? expectedScope;
      if (entryScope != expectedScope) {
        foreign++;
        continue;
      }
      final sidRaw = json['sid'];
      final entrySid = sidRaw is String ? sidRaw.trim() : null;
      if (expectedScope == MemoryScope.session) {
        if (entrySid == null || entrySid.isEmpty || entrySid != expectedSid) {
          foreign++;
          continue;
        }
      } else if (entrySid != null && entrySid.isNotEmpty) {
        // workspace 文件的条目不许带 sid（带了说明是 session 文件被复制过来）
        foreign++;
        continue;
      }
      final entry = ScopedMemoryEntry(
        id: id,
        scope: entryScope,
        sid: expectedScope == MemoryScope.session ? expectedSid : null,
        kind: '${json['kind'] ?? 'other'}',
        text: text,
        source: '${json['source'] ?? MemoryRecord.sourceAgent}',
        createdAt: _intOf(json['createdAt']) ?? 0,
        expiresAt: _intOf(json['expiresAt']),
      );
      live[entry.id] = entry; // 同 id 后写者胜
    }

    return _FoldResult(
      entries: live.values.toList(growable: false),
      totalLines: totalLines,
      skippedForeign: foreign,
    );
  }

  /// 追加文本（优先 `fs.appendText`；旧 APK 回落「读改写」并断言前缀）。
  Future<void> _appendRaw(String path, String text) async {
    await _ensureDirs(path);
    final raw = await _ch.call('fs.appendText', <String, Object?>{
      'path': path,
      'text': text,
    });
    final err = errorOf(raw);
    if (err == null) return;

    if (err.contains('父目录不存在')) {
      // 目录刚建失败/被删：清缓存重试一次
      _ensuredDirs.removeWhere((d) => path.startsWith(d));
      await _ensureDirs(path);
      final retry = await _ch.call('fs.appendText', <String, Object?>{
        'path': path,
        'text': text,
      });
      final retryErr = errorOf(retry);
      if (retryErr == null) return;
      throw MemoryServiceError(
        MemoryErrorCode.storeIo,
        '写入记忆文件失败（目录建不出来）：$retryErr',
        address: <String, Object?>{'path': path},
      );
    }

    if (err.contains('未知方法') || err.contains('文件不存在') || err.contains('不支持追加')) {
      // 兜底：读改写（断言既有内容是新的前缀，绝不吃掉旧数据）
      final existing = (await _readText(path)).text;
      final needsNewline = existing.isNotEmpty && !existing.endsWith('\n');
      final updated = '$existing${needsNewline ? '\n' : ''}$text';
      if (!updated.startsWith(existing)) {
        throw MemoryServiceError(
          MemoryErrorCode.storeIo,
          '追加断言失败：拼接结果不是"旧内容 + 新行"，已放弃写入。',
          address: <String, Object?>{'path': path},
        );
      }
      final w = await _ch.call('fs.writeText', <String, Object?>{
        'path': path,
        'text': updated,
      });
      final werr = errorOf(w);
      if (werr != null) {
        throw MemoryServiceError(
          MemoryErrorCode.storeIo,
          '写入记忆文件失败：$werr',
          address: <String, Object?>{'path': path},
        );
      }
      return;
    }

    throw MemoryServiceError(
      MemoryErrorCode.storeIo,
      '写入记忆文件失败：$err',
      address: <String, Object?>{'path': path},
    );
  }

  Future<int> _fileBytes(String path) async {
    final text = (await _readText(path)).text;
    return _utf8Length(text);
  }

  /// 按阈值自动 compact（best-effort；失败只记日志，不影响已落盘的写入）。
  Future<void> _maybeCompact(_ResolvedAddress resolved) async {
    try {
      final path = resolved.path!;
      final scan = await _scanFile(
        path,
        scope: resolved.scope,
        expectedSid: resolved.sessionId,
      );
      final bytes = await _fileBytes(path);
      final softMax = budget.storageSoftMaxBytesOf(resolved.scope);
      final ratio = scan.totalLines == 0
          ? 0.0
          : scan.invalidLines / scan.totalLines;
      final tooManyInvalid = ratio >= MemoryStoreBudget.compactInvalidRatio;
      final tooBig = bytes >= (softMax * MemoryStoreBudget.compactSizeRatio);
      if (!tooManyInvalid && !tooBig) return;
      await _rewriteLive(resolved, scan);
    } on MemoryServiceError catch (e) {
      // compact 失败不影响追加（原文件保留，不丢数据）
      _log('compact 跳过：${e.code}');
    }
  }

  /// 把存活条目整体重写到 `<file>.tmp`，再 `fs.rename` 覆盖原文件。
  Future<void> _rewriteLive(_ResolvedAddress resolved, _FileScan scan) async {
    final path = resolved.path!;
    final tmp = '$path.tmp';
    final buf = StringBuffer();
    for (final e in scan.entries) {
      buf.writeln(jsonEncode(e.toJson()));
    }
    final w = await _ch.call('fs.writeText', <String, Object?>{
      'path': tmp,
      'text': buf.toString(),
    });
    final werr = errorOf(w);
    if (werr != null) {
      await _ch.call('fs.delete', <String, Object?>{'path': tmp, 'recursive': false});
      throw MemoryServiceError(
        MemoryErrorCode.storeIo,
        'compact 写入临时文件失败（原文件未动）：$werr',
        address: <String, Object?>{'path': path},
      );
    }
    final r = await _ch.call('fs.rename', <String, Object?>{'from': tmp, 'to': path});
    final rerr = errorOf(r);
    if (rerr != null) {
      await _ch.call('fs.delete', <String, Object?>{'path': tmp, 'recursive': false});
      throw MemoryServiceError(
        MemoryErrorCode.storeIo,
        'compact 覆盖原文件失败（原文件未动）：$rerr',
        address: <String, Object?>{'path': path},
      );
    }
    _log('compact 完成：${scan.totalLines} 行 → ${scan.entries.length} 条');
  }

  // --------------------------------------------------------------------------
  // global 作用域（走 memory.* 通道）
  // --------------------------------------------------------------------------

  Future<MemoryScanResult> _readGlobal({required bool includeExpired}) async {
    final raw = await _ch.call('memory.list', <String, Object?>{
      'includeExpired': includeExpired,
      'limit': 0,
    });
    final err = errorOf(raw);
    if (err == null) {
      final list = raw['entries'];
      final entries = <ScopedMemoryEntry>[];
      var foreign = 0;
      var malformed = 0;
      if (list is List) {
        for (final item in list) {
          if (item is! Map) {
            malformed++;
            continue;
          }
          final e = _entryFromChannel(item.cast<String, Object?>());
          if (e == null) {
            malformed++;
            continue;
          }
          if (e.scope != MemoryScope.global) {
            foreign++;
            continue;
          }
          entries.add(e);
        }
      }
      return MemoryScanResult(
        entries: entries,
        skippedForeign: foreign,
        invalidLines: malformed,
        totalLines: entries.length + foreign + malformed,
      );
    }
    if (err.contains('未知方法')) {
      // 旧 APK：只有 memory.read（全局原文）。按旧 memory.md 规则解析。
      final rawRead = await _ch.call('memory.read');
      final readErr = errorOf(rawRead);
      if (readErr != null) {
        throw MemoryServiceError(
          MemoryErrorCode.storeIo,
          '读取全局记忆失败：$readErr',
        );
      }
      final text = (rawRead['text'] as String?) ?? '';
      final entries = parseLegacyGlobal(text);
      return MemoryScanResult(
        entries: includeExpired
            ? entries
            : entries.where((e) => !e.isExpiredAt(_nowMs())).toList(),
        totalLines: entries.length,
      );
    }
    throw MemoryServiceError(
      MemoryErrorCode.storeIo,
      '读取全局记忆失败：$err',
    );
  }

  Future<MemoryWriteOutcome> _globalUserEdit(Map<String, Object?> args) async {
    final raw = await _ch.call('memory.userEdit', args);
    final err = errorOf(raw);
    if (err != null) {
      final code = (raw['code'] as String?)?.trim();
      throw MemoryServiceError(
        (code != null && code.isNotEmpty) ? code : MemoryErrorCode.storeIo,
        '写入全局记忆失败：$err',
        address: const <String, Object?>{'scope': 'global'},
      );
    }
    final evictedRaw = raw['evicted'];
    final evicted = <String>[
      if (evictedRaw is List) for (final id in evictedRaw) '$id',
    ];
    return MemoryWriteOutcome(
      id: raw['id'] as String?,
      entries: _intOf(raw['entries']) ?? 0,
      bytes: _intOf(raw['bytes']) ?? 0,
      evicted: evicted,
    );
  }

  ScopedMemoryEntry? _entryFromChannel(Map<String, Object?> j) {
    final id = j['id'];
    final text = j['text'];
    if (id is! String || id.trim().isEmpty || text is! String) return null;
    final scope = MemoryScope.tryParse(j['scope'] as String?) ?? MemoryScope.global;
    final sid = (j['sid'] as String?)?.trim();
    final expires = j['expiresAt'];
    return ScopedMemoryEntry(
      id: id,
      scope: scope,
      sid: (sid == null || sid.isEmpty) ? null : sid,
      kind: '${j['kind'] ?? 'other'}',
      text: text,
      source: '${j['source'] ?? MemoryRecord.sourceAgent}',
      createdAt: _intOf(j['createdAt']) ?? 0,
      expiresAt: expires is num ? expires.toInt() : null,
    );
  }

  // --------------------------------------------------------------------------
  // 小工具
  // --------------------------------------------------------------------------

  void _checkEntryText(String raw) {
    final t = raw.trim();
    if (t.isEmpty) {
      throw const MemoryServiceError(
        MemoryErrorCode.entryEmpty,
        '要记住的内容是空的。',
      );
    }
    if (t.length > budget.entryMaxChars) {
      throw MemoryServiceError(
        MemoryErrorCode.entryTooLong,
        '单条记忆最长 ${budget.entryMaxChars} 字符（这条 ${t.length} 字符），'
        '没有写入。请精简，或改用 write_file 记成文件。',
      );
    }
    if (_secretPattern.hasMatch(t)) {
      throw const MemoryServiceError(
        MemoryErrorCode.secretRejected,
        '内容疑似包含密钥/令牌，拒绝写入长期记忆（明文存储，泄露风险）。',
      );
    }
  }

  List<ScopedMemoryEntry> _rankByQuery(
    List<ScopedMemoryEntry> entries,
    Set<String> keywords,
    int limit,
  ) {
    final scored = <({ScopedMemoryEntry entry, int score})>[
      for (final e in entries)
        (entry: e, score: memoryRelevanceScore(e.text, keywords)),
    ]..sort((a, b) {
        if (a.score != b.score) return b.score.compareTo(a.score);
        return b.entry.createdAt.compareTo(a.entry.createdAt);
      });
    return <ScopedMemoryEntry>[
      for (final s in scored)
        if (s.score > 0) s.entry,
    ].take(limit).toList();
  }

  int _entriesBytes(List<ScopedMemoryEntry> entries) => entries.fold<int>(
        0,
        (n, e) => n + _utf8Length(jsonEncode(e.toJson())) + 1,
      );

  Map<String, Object?> _resolvedAddressJson(_ResolvedAddress r) =>
      <String, Object?>{
        'scope': r.scope.wireName,
        if (r.sessionId != null) 'sid': r.sessionId,
        if (r.workspacePath != null) 'workspacePath': r.workspacePath,
      };

  static String _normalizeFsPath(String raw) {
    var t = raw.trim().replaceAll('\\', '/');
    t = t.replaceAll(RegExp('/{2,}'), '/');
    if (t.length > 1 && t.endsWith('/')) t = t.substring(0, t.length - 1);
    return t;
  }

  static int _utf8Length(String s) => utf8.encode(s).length;

  void _log(String message) {
    // SEC：只允许 id/条数/长度 —— 调用方保证 message 里没有记忆正文
    debugPrint('[heracles][memory] $message');
  }

  /// **旧格式解析**（旧 `memory.md` / 旧 APK 的 `memory.read`）。
  ///
  /// 规则与 `global_memory.dart` 的 `parseEntries` 一致（读它、不改它）：
  /// · 行内第一个 `{` 起能解成 JSON ⇒ 取 id/kind/text/source/createdAt/expiresAt，
  ///   缺省补 `agent` / `0`；`scope`/`sid` 缺省按 global 补（旧文件没有这两个字段）；
  /// · 否则 ⇒ `{id:"legacy-N", kind:"other", text:整行, source:"legacy", createdAt:0}`；
  /// · 空正文的 JSON 行跳过（旧实现同款）。
  ///
  /// 迁移来的旧条目**不受 8000 字符写闸限制**（写闸只管新写；旧数据可能很长，
  /// 截断它们比保留更危险 —— 设计稿 §3.7.2 第 4 步）。
  static List<ScopedMemoryEntry> parseLegacyGlobal(String raw) {
    final out = <ScopedMemoryEntry>[];
    var legacySeq = 0;
    for (var line in const LineSplitter().convert(raw)) {
      line = line.trim();
      if (line.isEmpty) continue;
      final brace = line.indexOf('{');
      if (brace >= 0) {
        Map<String, dynamic>? json;
        try {
          final decoded = jsonDecode(line.substring(brace));
          if (decoded is Map) json = decoded.cast<String, dynamic>();
        } catch (_) {
          json = null;
        }
        if (json != null) {
          final text = (json['text'] as String?) ?? '';
          if (text.isEmpty) continue;
          final scopeRaw = json['scope'];
          final sidRaw = json['sid'];
          final sid = sidRaw is String ? sidRaw.trim() : '';
          out.add(ScopedMemoryEntry(
            id: (json['id'] as String?) ?? 'm${out.length}',
            scope: scopeRaw is String
                ? (MemoryScope.tryParse(scopeRaw) ?? MemoryScope.global)
                : MemoryScope.global,
            sid: sid.isEmpty ? null : sid,
            kind: '${json['kind'] ?? 'other'}',
            text: text,
            source: '${json['source'] ?? MemoryRecord.sourceAgent}',
            createdAt: _intOf(json['createdAt']) ?? 0,
            expiresAt: _intOf(json['expiresAt']),
          ));
          continue;
        }
      }
      legacySeq++;
      out.add(ScopedMemoryEntry(
        id: 'legacy-$legacySeq',
        scope: MemoryScope.global,
        kind: 'other',
        text: line,
        source: MemoryRecord.sourceLegacy,
        createdAt: 0,
      ));
    }
    return out;
  }
}

/// 一次 JSONL 折叠的结果（内部）。
class _FoldResult {
  const _FoldResult({
    required this.entries,
    required this.totalLines,
    required this.skippedForeign,
  });

  final List<ScopedMemoryEntry> entries;
  final int totalLines;
  final int skippedForeign;
}

/// 宽松取 int：`int` / `double` / 数字字符串都能来（与旧实现同口径）。
int? _intOf(Object? v) {
  if (v is int) return v;
  if (v is num) return v.isFinite ? v.toInt() : null;
  if (v is String) return int.tryParse(v.trim());
  return null;
}
