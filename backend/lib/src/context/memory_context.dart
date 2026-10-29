/// **记忆系统的三作用域数据模型**（2026-10-29 重设计）—— **纯数据，无 IO**。
///
/// ## 为什么这些类型在 backend（而不是 App）
///
/// 记忆的**选择、预算、排序、渲染**必须能被 `dart test` 覆盖（宿主是 Flutter
/// 层，验证强度只有 `flutter test`）。所以 backend 收的是"宿主已经读好的结构化
/// 三段列表"（[MemoryContext]），而不是一段拼好的字符串 —— 这样预算与冲突裁决
/// 都在后端纯函数里做（见 `prompt/memory_prompt.dart`）。
///
/// ## 责任边界（别在这里加 IO）
///
/// · **读文件/解析 JSONL/校验会话是否存在** ⇒ 宿主（App `ScopedMemoryService`、
///   Kotlin `MemoryStore`）。本文件只定义"长什么样"；
/// · **排序/裁剪/渲染** ⇒ `memory_prompt.dart`；
/// · **写** ⇒ 能力层（`MemoryCapability.appendScoped` 等）。
///
/// 文件布局与条目行格式见 `.docs/记忆系统重设计-2026-10-29.md` §3.2；对外契约
/// 见 `docs/INTERFACE.md` §N12。
library;

/// **记忆作用域**（从"离用户最近"到"最远"）。
///
/// 顺序即注入顺序的反向：枚举值顺序 `global → workspace → session`，
/// 注入时按此顺序拼接，**session 放最后**（最易变 ⇒ 缓存损失最小）。
/// 冲突裁决反过来：**session > workspace > global**（离当前会话越近越可信）。
enum MemoryScope {
  /// 全局：跨工作区、跨会话；**对 agent 只读**（只能提议，用户确认后晋升）。
  global,

  /// 工作区：该工作区所有会话共享；随工作区存在。
  workspace,

  /// 会话私有：只在本会话可见；随会话删除而删除。
  session;

  /// 从 JSON / 通道入参里的字符串解析（不认识就返回 `null`，**不猜**）。
  static MemoryScope? tryParse(String? raw) {
    return switch (raw) {
      'global' => MemoryScope.global,
      'workspace' => MemoryScope.workspace,
      'session' => MemoryScope.session,
      _ => null,
    };
  }

  /// 线上/落盘用的名字（JSON 字段 `scope`）。
  String get wireName => switch (this) {
        MemoryScope.global => 'global',
        MemoryScope.workspace => 'workspace',
        MemoryScope.session => 'session',
      };

  /// 该作用域是否必须带 `sessionId`。
  bool get requiresSessionId => this == MemoryScope.session;

  /// 该作用域是否必须带 `workspacePath`（session 也需要 —— 记忆文件在
  /// `<工作区>/.heracles/memory/session/<sid>.jsonl`，路径本身就是隔离锚点）。
  bool get requiresWorkspacePath =>
      this == MemoryScope.workspace || this == MemoryScope.session;
}

/// **一条记忆**（三个作用域的条目形状完全一致）。
///
/// 字段与落盘 JSON 一一对应（`v` 版本字段由存储层处理，这里只管业务字段）：
/// `{id, scope, sid, kind, text, source, createdAt, expiresAt}`。
class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.scope,
    required this.kind,
    required this.text,
    required this.source,
    required this.createdAt,
    this.expiresAt,
  });

  /// 来源：用户亲手加（记忆页）。
  static const String sourceUser = 'user';

  /// 来源：模型通过 `save_memory` 记的。
  static const String sourceAgent = 'agent';

  /// 来源：旧 `memory.md` 迁移过来的（内容可能很长，不套用单条长度闸）。
  static const String sourceLegacy = 'legacy';

  /// 来源：用户在记忆页确认的模型提议（"已确认"）。
  static const String sourcePromoted = 'promoted';

  /// `m<epochMicros>`（沿用旧实现）。同 id 后写者胜（last-wins）。
  final String id;

  /// 归属作用域。**读时必须与寻址一致**，不符的条目丢弃并计数（防串台）。
  final MemoryScope scope;

  /// 词表：`preference / background / habit / other`（INTERFACE N7 沿用）。
  final String kind;

  /// 正文（单条上限 `ContractMemory.entryMaxChars`，迁移来的旧条目例外）。
  final String text;

  /// 来源，见 `sourceUser` / `sourceAgent` / `sourceLegacy` / `sourcePromoted`。
  /// **注入排序与优先级都依赖它**（user/promoted 同分置顶）。
  final String source;

  /// 毫秒时间戳。
  final int createdAt;

  /// 毫秒时间戳；`null` = 永不过期。过期即不参与注入。
  final int? expiresAt;

  /// 在 [nowMs] 这个时刻是否已过期。
  ///
  /// 边界取 `<=`：`expiresAt == now` 视为**已过期**（"到期"就是不再可用，
  /// 与旧实现 `MemoryEntry.isAlive()` 一致）。
  bool isExpiredAt(int nowMs) {
    final exp = expiresAt;
    return exp != null && exp <= nowMs;
  }

  /// 是否"用户已确认"（用户手加或已晋升的提议）—— 注入时优先。
  bool get isUserConfirmed =>
      source == sourceUser || source == sourcePromoted;

  @override
  String toString() =>
      'MemoryRecord(${scope.wireName}, $source, ${text.length} 字)';
}

/// **一次 run 的记忆快照**（三段，已按作用域分好）。
///
/// 宿主在构造 `RunOptions` 之前读好并传进来；backend 只读不写。
class MemoryContext {
  const MemoryContext({
    this.global = const [],
    this.workspace = const [],
    this.session = const [],
    this.globalEnabled = true,
    this.nowMs,
  });

  /// 全局段（用户维护、agent 只读）。
  final List<MemoryRecord> global;

  /// 工作区段（本工作区所有会话共享）。
  final List<MemoryRecord> workspace;

  /// 会话私有段（只在本会话可见）。
  final List<MemoryRecord> session;

  /// 全局记忆开关（设置项 `memoryGlobalEnabled`，默认开）。
  ///
  /// 关掉 ⇒ 宿主本可以不读 global，但**数据保留**；这里再挡一层，
  /// 保证即使宿主读进来了也不会注入（fail-closed 的反面：不多嘴）。
  final bool globalEnabled;

  /// 判过期用的"现在"（毫秒）。`null` ⇒ 用系统时钟。
  ///
  /// 显式传入是为了**可测**：过期边界用例不能依赖真实时间。
  final int? nowMs;

  /// 实际参与注入的 global 列表（开关关掉 ⇒ 空）。
  List<MemoryRecord> get effectiveGlobal =>
      globalEnabled ? global : const <MemoryRecord>[];

  /// 某个作用域的实际条目列表（global 已按开关过滤）。
  List<MemoryRecord> entriesOf(MemoryScope scope) => switch (scope) {
        MemoryScope.global => effectiveGlobal,
        MemoryScope.workspace => workspace,
        MemoryScope.session => session,
      };

  /// 三段都为空（按开关过滤后）—— 宿主可据此跳过渲染。
  bool get isEmpty =>
      effectiveGlobal.isEmpty && workspace.isEmpty && session.isEmpty;

  /// 求值时的"现在"（毫秒）。
  int nowMilliseconds() => nowMs ?? DateTime.now().millisecondsSinceEpoch;
}

/// **记忆寻址**（不变量 I1：`scope` + sessionId/workspacePath 三要素齐全才动手）。
///
/// 纯数据对象：**只做"形状"校验**（scope ↔ 字段、会话 id 格式）。
/// "会话是否存在 / 工作区是否登记 / 目标路径是否逐字匹配"这三步需要通道数据，
/// 由宿主完成（设计稿 §3.3.2 的 3–5 步）。宿主实现应在本对象之上追加校验，
/// **校验失败一律 fail-closed**，绝不回落到 global/workspace。
class MemoryAddress {
  const MemoryAddress({
    required this.scope,
    this.sessionId,
    this.workspacePath,
  });

  /// 会话 id 形状：`s` + 10~16 位数字（沿用 `session_store.dart` 的 `s<毫秒>`）。
  ///
  /// 这条正则同时**禁止路径分隔符与 `..`** —— 所以它既是格式校验，
  /// 也是防目录穿越的第二道闸。
  static final RegExp sessionIdPattern = RegExp(r'^s[0-9]{10,16}$');

  final MemoryScope scope;

  /// 当且仅当 [scope] == session 时非空。
  final String? sessionId;

  /// 绝对路径；[scope] == workspace/session 时必填。
  final String? workspacePath;

  /// 校验"形状"（设计稿 §3.3.2 第 1–2 步），不合规抛 [MemoryAddressError]。
  void validate() {
    switch (scope) {
      case MemoryScope.global:
        if (sessionId != null || workspacePath != null) {
          throw MemoryAddressError(
            MemoryAddressError.scopeMismatch,
            'global 记忆不接受 sessionId / workspacePath（防止跨层串台）',
            address: toJson(),
          );
        }
      case MemoryScope.workspace:
        if (sessionId != null) {
          throw MemoryAddressError(
            MemoryAddressError.scopeMismatch,
            'workspace 记忆不接受 sessionId（会话私有请用 scope=session）',
            address: toJson(),
          );
        }
        final ws = workspacePath;
        if (ws == null || ws.trim().isEmpty) {
          throw MemoryAddressError(
            MemoryAddressError.scopeMismatch,
            'workspace 记忆必须带非空 workspacePath',
            address: toJson(),
          );
        }
      case MemoryScope.session:
        final ws = workspacePath;
        if (ws == null || ws.trim().isEmpty) {
          throw MemoryAddressError(
            MemoryAddressError.scopeMismatch,
            'session 记忆必须带非空 workspacePath',
            address: toJson(),
          );
        }
        final sid = sessionId;
        if (sid == null || !sessionIdPattern.hasMatch(sid)) {
          throw MemoryAddressError(
            MemoryAddressError.sidFormat,
            'sessionId 形状必须是 s<10~16 位数字>（收到 ${sid ?? "null"}）；'
            '记忆不会回落到全局/工作区。',
            address: toJson(),
          );
        }
    }
  }

  /// 排障/错误回报用的形状（**不含记忆正文**，只含寻址）。
  Map<String, Object?> toJson() => <String, Object?>{
        'scope': scope.wireName,
        if (sessionId != null) 'sid': sessionId,
        if (workspacePath != null) 'workspacePath': workspacePath,
      };

  @override
  String toString() => 'MemoryAddress(${toJson()})';
}

/// **寻址校验失败**（fail-closed 的唯一出口）。
///
/// 为什么用异常而不是"返回 null/空列表"：空列表与"没有记忆"同形，
/// 调用方会当成正常态 —— 那正是旧 `read() → ''` 的教训（设计稿 §3.3.2）。
/// 宿主捕获后按"本轮无记忆 + 上报错误"处理，**绝不回落**。
class MemoryAddressError implements Exception {
  const MemoryAddressError(this.code, this.message, {this.address});

  /// scope ↔ 字段不匹配（设计稿 §3.3.2 第 1 步）。
  static const String scopeMismatch = 'E_SCOPE_MISMATCH';

  /// 会话 id 格式不合法（第 2 步）。
  static const String sidFormat = 'E_SID_FORMAT';

  /// 机器可读的错误码（INTERFACE §N12 的错误码词表）。
  final String code;

  /// 给人看的一句话（**不得含记忆正文**，只允许寻址信息）。
  final String message;

  /// 出错时的寻址形状（排障用）。
  final Map<String, Object?>? address;

  @override
  String toString() =>
      'MemoryAddressError($code): $message${address == null ? "" : " @ $address"}';
}
