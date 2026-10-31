/// **会话持久化（Dart 侧）** —— 替代已删除的 Kotlin `SessionStore.kt`。
///
/// ## 数据布局（**必须与旧格式完全兼容**）
///
/// UI 与既有会话文件都按这个结构存在磁盘上，换实现**不许改格式**：
///
/// ```
/// <工作区>/.heracles/
///   ├── sessions.json          ← 索引（JSON 数组，可整体重写）
///   └── sessions/
///         ├── s1791611845161.jsonl   ← 会话（严格 append-only）
///         └── s1791611897233.jsonl
/// ```
///
/// `sessions.json` 的元素：`{id, title, updatedAt(毫秒), starred, archived}`。
/// `.jsonl` 每行一条 JSON，形状见 `_normalizeEntry` 与
/// `app/lib/screens/chat_screen.dart` 的 `_toMessages`（**它是消费者，以它为准**）。
///
/// ## ★ 铁律：`.jsonl` 严格 append-only
///
/// 会话记录**只准追加，绝不准整文件重写**。理由不是洁癖，是这套产品的
/// 缓存纪律：会话前缀必须字节稳定（`ADR-001`；append-only 命中 90–99% 可依赖，
/// 而分支 25–105% **不可预测**）。改写历史 = 前缀漂移 = 缓存全灭。
///
/// 本实现里只有两处可以整体写 `.jsonl`：
///
/// | 位置 | 为什么允许 |
/// |---|---|
/// | `seedBranch` | **新建**一个文件（不是改写已有会话） |
/// | `deleteSession` | **删掉**文件（不是改写内容） |
///
/// `appendMessage` 只准追加一行。
///
/// ## ⚠️ 一个必须如实说清的降级
///
/// **机械上不是 O(1) 追加**：`heracles/device` 通道**没有 append 原语**
/// （只有 `fs.writeText` 整体覆盖）。所以 `appendMessage` 的实际动作是
/// 「读全文 → 拼接 → 写全文」。语义上仍是 append-only（既有字节一个不改，
/// 旧内容是新内容的**前缀**），但长会话下每次写都是 O(n)。
/// 真铁律需要 Kotlin 侧加 `fs.appendText`（`File.appendText` /
/// SAF 侧 `openOutputStream(uri, "wa")`），见 `docs/nextwork.md`。
///
/// **这个降级带来一个必须堵的坑**：通道的 `fs.readText` 有 **1 MB 上限**
/// （`DeviceFs.MAX_TEXT_BYTES`），超了会 `truncated: true` **只给前 1 MB**。
/// 若拿这份"只有前半截"的文本去拼新行再写回，**后半截会被永久删掉** ——
/// 那就是教科书级的"读改写把用户数据吃掉"。所以 `appendMessage` 在
/// `truncated == true` 时**直接拒绝**并说明原因，绝不赌一把。
///
/// ## ⚠️ 并发：**调用方必须串行化**
///
/// 本类**不是线程安全的**，也**不打算让它看起来是**。同一个会话的两次
/// `appendMessage` 并发进入会互相读到对方的"旧全文"，后写的覆盖先写的（丢行）。
/// 调用方（agent 循环 / UI）必须保证**同一会话的 append 串行**。
/// 类内只做一件事：**检测**到并发时如实失败，而不是悄悄丢数据。
library;

import 'dart:convert';

import 'package:heracles_backend/heracles_backend.dart';

import 'device_capabilities.dart';

// ============================================================================
// 数据模型
// ============================================================================

/// 一条会话的**索引元数据**（`sessions.json` 里的一项）。
///
/// 字段名与旧格式逐字一致：`id` / `title` / `updatedAt` / `starred` / `archived`。
class SessionMeta {
  const SessionMeta({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.starred = false,
    this.archived = false,
  });

  /// 会话 id（`s<毫秒时间戳>`，与旧实现同款，便于人和旧文件对照）。
  final String id;

  /// 显示名。**空标题一律落到「新会话」**（UI 也会这么兜，两处一致）。
  final String title;

  /// 最后活动时间（**毫秒**）。排序主键之一。
  final int updatedAt;

  /// 收藏。排序时**优先于时间**（用户钉住的会话要浮在顶上）。
  final bool starred;

  /// 归档。归档的会话仍在索引里，由 UI 决定是否折叠显示。
  final bool archived;

  /// 索引里存的原样 Map（键名与旧格式一致，可直接给 `AgentBridge` 那类消费方）。
  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        'updatedAt': updatedAt,
        'starred': starred,
        'archived': archived,
      };

  /// 从索引里的一项解析；形状不对返回 `null`（**丢一项，不要让整个索引读失败**）。
  static SessionMeta? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.trim().isEmpty) return null;
    return SessionMeta(
      id: id,
      title: _titleOf(raw['title']),
      updatedAt: _intOf(raw['updatedAt']) ?? 0,
      starred: _boolOf(raw['starred']) ?? false,
      archived: _boolOf(raw['archived']) ?? false,
    );
  }

  SessionMeta copyWith({
    String? title,
    int? updatedAt,
    bool? starred,
    bool? archived,
  }) =>
      SessionMeta(
        id: id,
        title: title ?? this.title,
        updatedAt: updatedAt ?? this.updatedAt,
        starred: starred ?? this.starred,
        archived: archived ?? this.archived,
      );

  @override
  String toString() => 'SessionMeta($id, $title, updatedAt=$updatedAt, '
      'starred=$starred, archived=$archived)';
}

// ============================================================================
// SessionStore
// ============================================================================

/// 工作区内的会话读写（全部走 `heracles/device` 的 `fs.*`）。
///
/// ## 为什么一律走 `fs.*` 而不是 `dart:io`
///
/// SAF 工作区（用户选的 `/sdcard/xxx`）在 `dart:io` 下写必 `EPERM`
/// （App 不在 `media_rw` 组，真机实测见 `docs/20`）。旧 Kotlin 实现踩过
/// 一次：`sessions.json` 用 `java.io.File` 写 ⇒ 真机上永远存不进去。
/// 所以本类**不 import `dart:io`**，一切交给通道按路径路由（POSIX / SAF）。
///
/// ## 为什么 root 在构造函数里，不在每个方法参数里
///
/// 任务书写的是 `listSessions(root)` 这种形状。实现改成"构造时给一次"：
/// 一个工作区一个 store 实例，避免每个调用点重复传 root ——
/// **传错一次就会写进另一个工作区的会话目录**，而那种 bug 沉默且不可逆
/// （会话记录跑到别处，用户以为丢了）。要切工作区就换一个实例。
class SessionStore {
  /// [workspaceRoot] 必须是设备上的**绝对路径**（SAF 工作区请传
  /// `picker.folder` 返回的 `path`）。
  ///
  /// [channel] 可注入（测试用 mock handler）。
  SessionStore({
    required String workspaceRoot,
    DeviceChannelClient? channel,
  })  : _root = _normalizeRoot(workspaceRoot),
        _ch = channel ?? const DeviceChannelClient();

  final String _root;
  final DeviceChannelClient _ch;

  /// 索引相对工作区的位置（与旧实现同款）。
  static const String _indexRel = '.heracles/sessions.json';

  /// 存储根目录（相对工作区）。
  static const String _storeRel = '.heracles';

  /// 会话文件所在目录（相对工作区）。
  static const String _dirRel = '.heracles/sessions';

  /// 存储目录是否已确保过存在（见 [_ensureStorageDirs]）。
  bool _dirsEnsured = false;

  /// ★ 确保 `.heracles/` 与 `.heracles/sessions/` 存在（2026-10-27）。
  ///
  /// ## 真机 bug「重进会话记录全没了、工作区里根本没有 .heracles」
  ///
  /// 整个会话存储链（建会话 / 写索引 / 追加消息）此前**没有任何一处
  /// 建目录**，全靠宿主 `fs.writeText` 顺手建父目录、或目录被旧版本
  /// 建过。宿主不建父目录时（普通文件写的正常语义），每一次写都失败，
  /// 而失败又全程静默（`createSession` 不查 `_writeIndex` 结果、
  /// agent 循环不查 `appendMessage` 返回值）⇒ 聊的时候一切正常
  /// （消息都在内存里），重进会话才发现什么都没落盘。
  /// **目录是应用自己的存储结构，本就该由应用建，不该指望用户
  /// 或宿主的顺手行为。**
  ///
  /// 写入口统一兜底：一实例只建一次；结果不查 —— 目录已存在时
  /// 宿主报不报错都无所谓，成败由随后写操作自己的报错决定。
  Future<void> _ensureStorageDirs() async {
    if (_dirsEnsured) return;
    _dirsEnsured = true;
    await _ch.call('fs.mkdir', <String, Object?>{'path': '$_root/$_storeRel'});
    await _ch.call('fs.mkdir', <String, Object?>{'path': '$_root/$_dirRel'});
    // 2026-10-29（记忆三作用域）：记忆目录也由 App 预建。
    // 不建的话「第一次写记忆」会依赖宿主顺手建父目录 —— 会话目录踩过
    // 同一个坑（真机上静默失败，见上）。
    await _ch.call('fs.mkdir', <String, Object?>{'path': memoryDirPath});
    await _ch.call('fs.mkdir', <String, Object?>{'path': '$_root/$_memorySessionDirRel'});
  }

  /// **长会话只加载最近这么多条**（2026-10-23）。
  ///
  /// ## 为什么必须有这个数（用户报的"长会话卡住不动"）
  ///
  /// 会话 `.jsonl` 是只追加的，越聊越长。几百条消息之后：
  ///
  /// | 问题 | 量级 |
  /// |---|---|
  /// | 一次 `loadMessages` 的正文 | 几百 KB（`fs.readText` 整文件） |
  /// | 解析出的 Map 列表 | 每条 3–8 个字段 × 几百条 |
  /// | UI 侧 `_toMessages` 的强转 + `ListView` 重建 | 几百个 widget |
  /// | 每轮 `appendMessage` 的搬运量 | 整文件 ×2（读 + 写）= **O(n²)** |
  ///
  /// 前三项靠"只给最近 N 条"直接降下来；第四项靠 `fs.appendText`
  /// （真追加，O(追加量)）根治 —— 见 [appendMessage]。
  ///
  /// ## 为什么是 400
  ///
  /// 一条真实的长会话约 250–400 条消息（每轮 ≈ 1 用户 + 1 步骤 + 1 工具 + 1 回答）。
  /// 400 能让"最近几十轮"完整可见（用户回看几乎都在这个范围），
  /// 又不至于把几 MB 塞进内存。**超出的部分不丢** —— 见 [loadMessages] 的说明。
  static const int defaultRecentLimit = 400;

  /// `loadMessages` 允许的**最大**行数上限（防调用方传天文数字）。
  static const int _hardMaxLines = 20000;

  /// `loadMessages` 取尾部时的**行数余量**。
  ///
  /// `.jsonl` 的文件末尾有换行（可能读出一个空行），历史里也可能有空行 /
  /// 坏行 —— 这些行占了额度但解析后会被丢弃。多要 8 行就足以覆盖，
  /// 保证"要 N 条真的拿到 N 条"。
  static const int _lineSlack = 8;

  /// 上一次操作留下的失败原因（排障用；`null` = 上次没出错）。
  ///
  /// 为什么用字段而不是抛异常：会话读写失败**不该让 UI 崩**
  /// （旧实现有"建了目录没写文件、界面无提示"的事故 —— 静默失败比崩溃更难查，
  /// 所以**失败要能看见**；但也别抛，UI 那层没有恢复手段）。
  String? lastError;

  /// 上一次 [loadMessages] 是否**只加载了最近一段**（前面还有更早的历史）。
  ///
  /// 只增字段：老调用方忽略它即可；UI 可据此显示"加载更早"入口。
  /// 触发条件：长会话（> 通道 1MB）走 tail 兜底，或 `limit > 0` 的窗口截断。
  bool lastLoadHasEarlier = false;

  /// 上一次 [loadMessages] 是否因通道 1 MB 上限而**丢掉了头部**（只拿到尾部）。
  ///
  /// 与 [lastLoadHasEarlier] 的区别：它是"确知头部被截断"——
  /// 旧宿主没有 `fs.readTailLines` 时可能连"真正的尾部"都拿不到，这时
  /// [lastError] 会明确说"最新消息可能未显示"（不假装完整）。
  bool lastLoadTruncatedAtHead = false;

  /// 工作区根（绝对路径，无尾部分隔符）。
  String get workspaceRoot => _root;

  /// 索引文件的绝对路径。
  String get indexPath => '$_root/$_indexRel';

  /// 某个会话的消息文件绝对路径。
  ///
  /// ⚠️ id 非法（空 / 含路径分隔符 / 含 `..` / NUL / 绝对路径）⇒ 抛
  /// [ArgumentError]（**拒绝拼路径**，防目录穿越）。
  String messagesPath(String sessionId) =>
      '$_root/$_dirRel/${_checkedSessionId(sessionId)}.jsonl';

  /// 记忆目录（三作用域重设计，2026-10-29）。
  ///
  /// 记忆**绝不写进会话正文**（那是 append-only 的历史，见文件头纪律）；
  /// workspace/session 作用域在 `<工作区>/.heracles/memory/` 下单独成文件，
  /// 可以安全 compact（墓碑折叠）。
  static const String _memoryDirRel = '.heracles/memory';

  /// 会话私有记忆目录（相对 `_memoryDirRel`）。
  static const String _memorySessionDirRel = '$_memoryDirRel/session';

  /// 记忆目录绝对路径。
  String get memoryDirPath => '$_root/$_memoryDirRel';

  /// 某会话的私有记忆文件绝对路径（`<ws>/.heracles/memory/session/<sid>.jsonl`）。
  ///
  /// ⚠️ id 非法 ⇒ 抛 [ArgumentError]（**拒绝拼路径**）：本方法会被
  /// 「删会话时清记忆」调用，路径穿越在这里必须挡住。
  String sessionMemoryPath(String sessionId) =>
      '$_root/$_memorySessionDirRel/${_checkedSessionId(sessionId)}.jsonl';

  /// 记忆派生索引（可重建，绝不当真源；见 INTERFACE §N12.3）。
  String get memoryIndexPath => '$_root/$_memoryDirRel/index.json';

  /// **宽松穿越闸**（2026-10-29 用户裁定）：只拒绝**会改变路径语义**的 id。
  ///
  /// 为什么**不用**严格 `^s[0-9]{10,16}$`：`_newId()` 在 1000 次撞号后会生成
  /// `s<毫秒>-<5位>` 这类**合法**兜底 id —— 严格正则会把它们误伤成"永远删不掉
  /// 记忆/消息文件"。所以只拦真正危险的东西：
  /// 空串、路径分隔符（`/` `\`）、`..`、NUL、绝对路径。
  static String _checkedSessionId(String sessionId) {
    final sid = sessionId.trim();
    final illegal = sid.isEmpty ||
        sid.startsWith('/') ||
        sid.contains('/') ||
        sid.contains('\\') ||
        sid.contains('..') ||
        sid.contains('\u0000');
    if (illegal) {
      throw ArgumentError(
        '会话 id 非法（空串 / 含路径分隔符 / 含 `..` / NUL / 绝对路径）：'
        '`$sessionId` —— 拒绝拼文件路径（防目录穿越）。',
      );
    }
    return sid;
  }

  static String _normalizeRoot(String raw) {
    final t = raw.trim().replaceAll('\\', '/');
    if (t.isEmpty) throw ArgumentError('workspaceRoot 不能为空');
    if (!t.startsWith('/')) {
      throw ArgumentError(
        'workspaceRoot 必须是设备上的绝对路径（收到 `$raw`）。'
        'SAF 工作区请传 `picker.folder` 返回的 path。',
      );
    }
    final cleaned = t.replaceAll(RegExp('/{2,}'), '/');
    if (cleaned.length > 1 && cleaned.endsWith('/')) {
      return cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned;
  }

  // ==========================================================================
  // 索引（sessions.json）—— **可整体重写**（它是索引，不是会话）
  // ==========================================================================

  /// 列出会话，按「收藏 > 最后活动时间」倒序（与旧实现同一排序）。
  ///
  /// 索引不存在 / 损坏 ⇒ 返回空列表并置 [lastError]（**不崩 UI**，
  /// 但错误可见）。单条形状不对 ⇒ 只丢那一条（不因一项坏掉丢整张表）。
  Future<List<SessionMeta>> listSessions() async {
    final read = await _readIndex();
    return _sorted(read.items);
  }

  /// **会话是否存在**（2026-10-29，记忆寻址第 3 步的锚点）。
  ///
  /// `ScopedMemoryService` 的 `hasSession` 回调就接这里（它只拿到
  /// `(workspacePath, sessionId)`，不 import 本类 —— 避免循环依赖）。
  /// 索引损坏/读不出来 ⇒ `false`（fail-closed：宁可不读会话记忆，
  /// 也不把"读不出索引"当成"会话存在"而张冠李戴）。
  Future<bool> hasSession(String sessionId) async {
    final String sid;
    try {
      sid = _checkedSessionId(sessionId);
    } on ArgumentError {
      // 非法 id 直接 false（fail-closed；绝不拿它去查/拼）
      return false;
    }
    final list = await listSessions();
    for (final m in list) {
      if (m.id == sid) return true;
    }
    return false;
  }

  /// 列出会话并**带失败原因**（给"索引读不出来"要如实告警的场合）。
  Future<CapabilityResult> listSessionsResult() async {
    final read = await _readIndex();
    if (read.error != null) return CapabilityFailure(read.error!);
    final list = _sorted(read.items);
    final buf = StringBuffer('会话 ${list.length} 个：');
    if (list.isEmpty) {
      buf.write('（还没有会话）');
    } else {
      for (final m in list) {
        buf.write('\n- ${m.id}  ${m.title}'
            '${m.starred ? " [收藏]" : ""}${m.archived ? " [归档]" : ""}');
      }
    }
    return CapabilitySuccess(
      buf.toString(),
      metadata: <String, dynamic>{'count': list.length},
    );
  }

  /// 解析 + 排序（两处共用，避免排序口径漂移）。
  List<SessionMeta> _sorted(List<Object?> items) {
    final list = <SessionMeta>[];
    for (final item in items) {
      final meta = SessionMeta.fromMap(item);
      if (meta != null) list.add(meta);
    }
    list.sort((a, b) {
      if (a.starred != b.starred) return a.starred ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  /// 新建会话，返回新 id。
  ///
  /// id 形如 `s1791611845161`（**毫秒时间戳**，与旧实现同款 —— 既有文件名
  /// 都是这个形状，改格式会让新旧会话混在一个目录里看不出年代）。
  /// 同一毫秒内连续建两个会撞 id，这里加一个顺延/后缀避免覆盖已有文件。
  Future<String> createSession(String title) async {
    final id = await _newId();
    final list = await listSessions();
    final updated = <SessionMeta>[
      ...list,
      SessionMeta(
        id: id,
        title: _titleOf(title),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        starred: false,
        archived: false,
      ),
    ];
    await _writeIndex(updated);
    // 不预建空的 .jsonl：旧实现也不建（没有消息就没有文件），
    // 建一个空文件只会让"这个会话有记录吗"多一个假信号。
    return id;
  }

  /// 生成一个不撞现有文件的会话 id。
  Future<String> _newId() async {
    final ms = DateTime.now().millisecondsSinceEpoch;
    // 撞了就往后挪（不改变"是时间戳"这个语义，也不会破坏排序）
    for (var i = 0; i < 1000; i++) {
      final candidate = 's${ms + i}';
      final stat = await _ch.call('fs.stat', <String, Object?>{
        'path': messagesPath(candidate),
      });
      // stat 失败（通道挂了）⇒ 不纠结，直接用当前候选（真写不进去会另有报错）
      if (errorOf(stat) != null) return candidate;
      if (stat['exists'] != true) return candidate;
    }
    // 1000 个候选都撞了：只可能是一次批量导入，直接用当前毫秒 + 随机尾巴
    return 's$ms-${DateTime.now().microsecondsSinceEpoch % 100000}';
  }

  /// 改标题。
  Future<bool> renameSession(String sessionId, String title) async {
    final list = await listSessions();
    var found = false;
    final updated = list.map((m) {
      if (m.id != sessionId) return m;
      found = true;
      return m.copyWith(title: _titleOf(title));
    }).toList();
    if (!found) {
      lastError = '会话不存在：$sessionId';
      return false;
    }
    return _writeIndex(updated);
  }

  /// 删除会话：**元数据 + 消息文件一起删**。
  ///
  /// 旧实现的首版只从索引里移除、**从没删过 `.jsonl`** —— 于是用户以为删掉的
  /// 对话其实完整躺在磁盘上（隐私与整洁双输）。这里两件一起做。
  ///
  /// 删消息文件失败**不阻断**（索引已经改了）；失败记进 [lastError]，
  /// 因为是"残留几 KB" vs "让用户以为删除没成功"的取舍 —— 后者更糟。
  Future<bool> deleteSession(String sessionId) async {
    lastError = null;
    final list = await listSessions();
    final remaining = list.where((m) => m.id != sessionId).toList();
    if (remaining.length == list.length) {
      lastError = '会话不存在：$sessionId';
      return false;
    }
    final ok = await _writeIndex(remaining);
    // 删文件（`recursive: false`：它是文件，不是目录）。
    //
    // ★ 防穿越：`sessions.json` 若被污染成 `../evil`，messagesPath 会抛
    //   ArgumentError。这里**不拼路径、不删任何文件**，只记错误继续往下走
    //   （索引已改；"少删一个坏 id 的文件"远好于"删到会话目录外"）。
    String messagesFile = '';
    try {
      messagesFile = messagesPath(sessionId);
    } on ArgumentError catch (e) {
      lastError = '会话索引已更新，但会话 id 非法，消息文件未删除：$e';
    }
    if (messagesFile.isNotEmpty) {
      final del = await _ch.call('fs.delete', <String, Object?>{
        'path': messagesFile,
        'recursive': false,
      });
      final delErr = errorOf(del);
      if (delErr != null && !delErr.contains('不存在')) {
        lastError = '会话索引已更新，但消息文件删不掉：$delErr '
            '（残留文件：$messagesFile）';
      }
    }
    // 2026-10-29（记忆三作用域）：**会话删除 ⇒ 私有记忆一起删**
    // （会话私有的语义；也避免孤儿文件）。best-effort：失败不阻断删除
    // —— "残留几 KB 记忆" vs "让用户以为删除没成功"，后者更糟。
    await _deleteSessionMemory(sessionId);
    return ok;
  }

  /// 删某会话的私有记忆文件 + 从记忆索引里摘掉该会话（best-effort）。
  ///
  /// 与 [deleteSession] 同一取舍：索引已改，记忆残留不阻断；失败记
  /// [lastError] 供排障。**不碰 global**（全局记忆与会话无关）。
  Future<void> _deleteSessionMemory(String sessionId) async {
    try {
      // ★ 防穿越：非法 sid 在这里抛 ArgumentError（被下面 catch 住），
      //   绝不会拼出 `/ws/.heracles/memory/session/../evil.jsonl` 去删。
      final path = sessionMemoryPath(sessionId);
      final del = await _ch.call('fs.delete', <String, Object?>{
        'path': path,
        'recursive': false,
      });
      final err = errorOf(del);
      if (err != null && !err.contains('不存在')) {
        lastError = '${lastError == null ? "" : "$lastError；"}'
            '会话记忆文件删不掉：$err（残留：$path）';
      }
    } catch (e) {
      lastError = '${lastError == null ? "" : "$lastError；"}'
          '会话记忆文件删除异常：$e';
    }
    await _removeSessionFromMemoryIndex(sessionId);
  }

  /// 从 `memory/index.json` 的派生 `sessions` 子表里摘掉一个会话。
  ///
  /// 索引是**派生缓存**（INTERFACE §N12.3：可重建，绝不当真源）⇒
  /// 读/改/写失败都只影响统计，不影响读写；因此全部静默忽略。
  Future<void> _removeSessionFromMemoryIndex(String sessionId) async {
    try {
      final raw = await _ch.call('fs.readText', <String, Object?>{
        'path': memoryIndexPath,
        'offsetLine': 1,
        'maxLines': 0,
      });
      if (errorOf(raw) != null) return;
      final text = (raw['text'] as String?) ?? '';
      if (text.trim().isEmpty) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final sessions = decoded['sessions'];
      if (sessions is! Map || !sessions.containsKey(sessionId)) return;
      final nextSessions = Map<String, dynamic>.from(sessions);
      nextSessions.remove(sessionId);
      final next = Map<String, dynamic>.from(decoded)
        ..['sessions'] = nextSessions;
      await _ch.call('fs.writeText', <String, Object?>{
        'path': memoryIndexPath,
        'text': jsonEncode(next),
      });
    } catch (_) {
      // 派生索引：失败不报（下次读时因不一致而重建）。
    }
  }

  /// 切换收藏，返回**新状态**（旧实现同款语义）。
  Future<bool> toggleStar(String sessionId) async {
    final list = await listSessions();
    var now = false;
    var found = false;
    final updated = list.map((m) {
      if (m.id != sessionId) return m;
      found = true;
      now = !m.starred;
      return m.copyWith(starred: now);
    }).toList();
    if (!found) {
      lastError = '会话不存在：$sessionId';
      return false;
    }
    await _writeIndex(updated);
    return now;
  }

  /// 切换归档，返回**新状态**。
  Future<bool> toggleArchive(String sessionId) async {
    final list = await listSessions();
    var now = false;
    var found = false;
    final updated = list.map((m) {
      if (m.id != sessionId) return m;
      found = true;
      now = !m.archived;
      return m.copyWith(archived: now);
    }).toList();
    if (!found) {
      lastError = '会话不存在：$sessionId';
      return false;
    }
    await _writeIndex(updated);
    return now;
  }

  /// 把某个会话的 `updatedAt` 推到"现在"（有新消息时调）。
  Future<void> touchSession(String sessionId) async {
    final list = await listSessions();
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = list
        .map((m) => m.id == sessionId ? m.copyWith(updatedAt: now) : m)
        .toList();
    await _writeIndex(updated);
  }

  /// 索引的读结果（内部用）。
  Future<_IndexRead> _readIndex() async {
    lastError = null;
    final raw = await _ch.call('fs.readText', <String, Object?>{
      'path': indexPath,
      'offsetLine': 1,
      'maxLines': 0,
    });
    final err = errorOf(raw);
    if (err != null) {
      // 索引还不存在 = 这个工作区还没有会话。**这是正常状态，不是错误。**
      if (err.contains('不存在')) return const _IndexRead(<Object?>[]);
      lastError = '读取会话索引失败：$err';
      return _IndexRead(const <Object?>[], error: lastError);
    }
    if (raw['truncated'] == true) {
      // 索引被 1MB 文本上限截断 ⇒ 解析出来必然是不完整 JSON。
      // 绝不能拿它去 `_writeIndex`（那会把后面的会话全删掉）。如实失败。
      final chars = (raw['text'] as String?)?.length ?? 0;
      lastError = '会话索引超过通道 1MB 文本上限，无法完整读取'
          '（读回 $chars 字符）。'
          '这通常意味着会话数量异常多，请手动清理 sessions.json。';
      return _IndexRead(const <Object?>[], error: lastError);
    }
    final text = ((raw['text'] as String?) ?? '').trim();
    if (text.isEmpty) return const _IndexRead(<Object?>[]);
    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) {
        lastError = '会话索引格式不对（期望 JSON 数组，实际是 '
            '${decoded.runtimeType}）。文件：$indexPath';
        return _IndexRead(const <Object?>[], error: lastError);
      }
      return _IndexRead(decoded);
    } catch (e) {
      lastError = '会话索引不是合法 JSON：${_humanize(e)}。文件：$indexPath';
      return _IndexRead(const <Object?>[], error: lastError);
    }
  }

  /// 整体重写索引（**这是唯一允许整体重写的文件** —— 它是索引不是会话）。
  Future<bool> _writeIndex(List<SessionMeta> list) async {
    await _ensureStorageDirs();
    final arr = <Map<String, dynamic>>[for (final m in list) m.toMap()];
    final text = jsonEncode(arr);
    final raw = await _ch.call('fs.writeText', <String, Object?>{
      'path': indexPath,
      'text': text,
    });
    final err = errorOf(raw);
    if (err != null) {
      lastError = '写入会话索引失败：$err';
      return false;
    }
    return true;
  }

  // ==========================================================================
  // 会话消息（<id>.jsonl）—— **严格 append-only**
  // ==========================================================================

  /// 读一个会话的全部消息行（**原样 Map 列表**，按写入顺序）。
  ///
  /// ## 为什么返回"原样行"而不是强类型
  ///
  /// `agent_bridge.dart` 的 `loadMessages` 契约就是"返回原始行列表，由上层
  /// 转成 UI 模型 —— 桥接层不猜 UI 的形状"。这里保持同一口径：
  /// **磁盘上是什么就给什么**，不在这里做业务解释。
  ///
  /// ## 坏行怎么办
  ///
  /// 跳过（`.jsonl` 的价值就是"一行坏了不影响其它行"）。
  /// 但**读取整体失败**（不是"文件不存在"）时返回一条 `role: system` 记录
  /// 说明原因 —— 与旧实现同款：**不能静默返回空列表**，那会让用户以为
  /// 记录真的没了。
  /// 读一个会话的消息行（**原样 Map 列表**，按写入顺序）。
  ///
  /// ## 参数
  ///
  /// - [limit]：**只返回最近多少条**。`0`（默认）= "尽量全部"，
  ///   **保持向后兼容** —— 老调用点（`agent_bridge.loadMessages`）不传就还是全读。
  ///
  ///   ★ **T0-4（2026-10-31）**：`0` 不再等于"死读 readText"。
  ///   通道读文本有 **1 MB** 上限，超长会话这么读只会拿到**开头** 1 MB。
  ///   现在 `0` 的判定是：
  ///   · 文件 ≤ 1 MB ⇒ 读全（真正完整，[lastLoadHasEarlier] == false）；
  ///   · 文件 > 1 MB（stat 或 readText 的 truncated 确认）⇒ 自动 `fs.readTailLines`
  ///     读最后 [ContractSession.tailLoadLines] 行（[lastLoadHasEarlier] /
  ///     [lastLoadTruncatedAtHead] == true，返回列表头插一条 `_synthetic: paging`
  ///     的 system 行，带 `hasEarlier`/`truncatedAtHead` 键 —— **只增字段**）；
  ///   · 旧宿主没有 `fs.readTailLines` ⇒ 回落 readText 后**本地切最后 N 行**；
  ///     若 readText 也被 1 MB 截断，[lastError] 会明确写"最新消息可能未显示"
  ///     （绝不把前 1 MB 当完整历史）。
  /// - [offset]：从第几条（0 起）开始返回，配合 [limit] 做"往前翻更多"。
  ///   与 SQL 的 OFFSET 同语义：**在"最近 limit 条"这个窗口内**再偏移。
  ///   注意：`limit: 0` 的 tail 兜底下只用它做尾部窗口内偏移，不支持无限往前。
  ///
  /// ## 长会话怎么优化（2026-10-23，用户报"卡住不动"）
  ///
  /// ### 改之前（三个都慢）
  ///
  /// 1. `fs.readText` 把**整文件**读进一个 String（几百 KB → 内存峰值 2×）；
  /// 2. `LineSplitter().convert(text)` 再 split 出几百个 String；
  /// 3. 每条 `jsonDecode` + 建 Map，**全部**跑在**主 isolate**（`await` 不换线程）。
  ///
  /// 而且 1 还有个硬顶：通道的 `fs.readText` 上限 **1 MB**，
  /// 超过就 `truncated` —— 长会话连"读全"都做不到。
  ///
  /// ### 改之后
  ///
  /// | 步 | 做法 |
  /// |---|---|
  /// | 取文本 | `fs.readTailLines` 让 **Kotlin 侧**只读文件**尾部**（POSIX 反向 seek，只读尾部字节） |
  /// | 解析 | 只对拿到的这 N 行 `jsonDecode` |
  /// | 兜底 | 通道不支持 `fs.readTailLines`（旧 APK）⇒ 回落到 `fs.readText` 全量读 |
  ///
  /// ⚠️ **诚实的边界**：
  /// - 回落路径**没有**变快（仍是整文件 + 主 isolate 解析），只是保证旧 APK 还能用。
  /// - 解析仍在主 isolate。要彻底解决得把解析挪进 `Isolate.run`，
  ///   但那条需要把 `DeviceChannelClient` 的通道调用也搬过去（通道只能在主 isolate 用），
  ///   收益不抵复杂度 ⇒ 本轮只做"少读 + 少解析"。
  /// - **超出的历史不丢**：它在磁盘上，用 `offset` 往前翻可以取到
  ///   （见 `chat_screen` 的"加载更早的消息"入口）。
  ///
  /// ## 返回形状（**UI 的 `_toMessages` 直接吃**）
  ///
  /// 每行原样返回 Map。读不全 / 读失败时**追加一条 `role: system`** 说明原因
  /// —— 与旧实现同款：不能静默返回空列表，那会让用户以为记录真没了。
  Future<List<Map<String, dynamic>>> loadMessages(
    String sessionId, {
    int limit = 0,
    int offset = 0,
  }) async {
    lastError = null;
    lastLoadHasEarlier = false;
    lastLoadTruncatedAtHead = false;
    final want = limit <= 0 ? 0 : limit.clamp(1, _hardMaxLines);
    final skip = offset < 0 ? 0 : offset;

    // ★ 防穿越：非法 id 不拼路径（返回一条 system 说明，而不是抛给 UI）
    final String path;
    try {
      path = messagesPath(sessionId);
    } on ArgumentError catch (e) {
      lastError = '会话 id 非法，拒绝读取会话记录：$e';
      return _systemErrorRow(lastError!);
    }

    // ★ T0-4（2026-10-31）：`limit == 0`（"加载全部"）不再盲信 readText。
    //   超长会话（> 通道 1MB）改读**文件尾部** —— 旧行为只把前 1MB 当完整历史，
    //   用户切会话看到的是**开头**、最新消息反而丢了（只留一句 1MB 提示）。
    if (want == 0) {
      return _loadAllOrTail(path, skip: skip);
    }

    final raw = await _ch.call('fs.readTailLines', <String, Object?>{
      'path': path,
      // ★ 多要一点余量（want + skip + 缓冲）。
      //
      // 为什么要缓冲：.jsonl 末尾有换行、历史里也可能有空行/坏行，
      // 这些行**占了行数额度但解析后会被丢掉**。只要一点余量，
      // 就能保证"要 10 条真的拿到 10 条"，而不是偶尔少一条。
      'maxLines': _tailLineBudget(skip: skip, want: want),
    });

    final err = errorOf(raw);
    if (err != null) {
      // 旧 APK 没有 fs.readTailLines ⇒ 回落到"读全文 + 本地切尾"。
      //
      // ⚠️ 这里**不能**再调 `loadMessages(sessionId)`（不传 limit）——
      //    那会把整个文件原样返回、把分页彻底丢掉（曾经踩过）。
      //    所以这条回落路径自己读全文，然后走**同一套**窗口逻辑。
      if (err.contains('未知方法')) {
        final full = await _ch.call('fs.readText', <String, Object?>{
          'path': path,
          'offsetLine': 1,
          'maxLines': 0,
        });
        final ferr = errorOf(full);
        if (ferr != null) {
          if (ferr.contains('不存在')) return <Map<String, dynamic>>[];
          lastError = ferr;
          return _systemErrorRow(lastError!);
        }
        // 向下统一解析 + 窗口逻辑（want > 0 会自己截）
        return _parseAndWindow(full, want: want, skip: skip);
      }
      if (err.contains('不存在')) return <Map<String, dynamic>>[];
      lastError = err;
      return _systemErrorRow(lastError!);
    }

    return _parseAndWindow(raw, want: want, skip: skip);
  }

  /// 取尾部时请求多少行（`want + skip + 余量`，夹到硬上限）。
  int _tailLineBudget({required int skip, required int want}) =>
      (want + skip + _lineSlack).clamp(1, _hardMaxLines);

  /// **`limit == 0` 的"加载全部"**：能读全就读全；读不全（> 通道 1MB）改读尾部。
  ///
  /// 判定顺序（都是**事实**，不是猜）：
  /// 1. `fs.stat` 报的字节数 > [ContractSession.channelTextMaxBytes] ⇒ 直接 tail；
  /// 2. 否则 `fs.readText` 全量读，`truncated == true` ⇒ 仍走 tail；
  /// 3. 只有"真读全且没截断"才返回全部（`hasEarlier == false`）。
  Future<List<Map<String, dynamic>>> _loadAllOrTail(
    String path, {
    required int skip,
  }) async {
    final stat = await _ch.call('fs.stat', <String, Object?>{'path': path});
    final statErr = errorOf(stat);
    final size = (stat['size'] as num?)?.toInt();
    if (statErr == null &&
        size != null &&
        size > ContractSession.channelTextMaxBytes) {
      return _loadTail(path, skip: skip);
    }

    final full = await _ch.call('fs.readText', <String, Object?>{
      'path': path,
      'offsetLine': 1,
      'maxLines': 0,
    });
    final ferr = errorOf(full);
    if (ferr != null) {
      if (ferr.contains('不存在')) return <Map<String, dynamic>>[];
      lastError = ferr;
      return _systemErrorRow(lastError!);
    }
    if (full['truncated'] == true) {
      // stat 不可用 / 文件在两步之间长大 ⇒ 仍按尾部兜底。
      // ★ 绝不把"前 1MB"当完整历史 —— 这正是本轮修掉的 bug。
      return _loadTail(path, skip: skip);
    }

    return _parseAndWindow(full, want: 0, skip: skip);
  }

  /// 读**文件尾部**（长会话的 `limit=0` 兜底；旧宿主回退也走这里）。
  Future<List<Map<String, dynamic>>> _loadTail(
    String path, {
    required int skip,
  }) async {
    final tail = await _ch.call('fs.readTailLines', <String, Object?>{
      'path': path,
      'maxLines': _tailLineBudget(
        skip: skip,
        want: ContractSession.tailLoadLines,
      ),
    });
    final err = errorOf(tail);
    if (err == null) {
      // Kotlin 的 `readTailLines` 语义：`truncated == (tail.size >= want)`，
      // 即"前面**可能**还有"（DeviceFs KDoc 的诚实边界）。文件已确认超 1MB
      // ⇒ 头部一定被截，按 `truncatedAtHead = true` 如实上报。
      final hasEarlier = tail['truncated'] == true;
      lastLoadHasEarlier = hasEarlier;
      lastLoadTruncatedAtHead = hasEarlier;
      return _parseAndWindow(
        tail,
        want: ContractSession.tailLoadLines,
        skip: skip,
        hasEarlier: hasEarlier,
        truncatedAtHead: hasEarlier,
        pagingText: '（会话记录超过通道 1MB 上限：仅为省内存加载了最近 '
            '${ContractSession.tailLoadLines} 条；更早的消息仍在磁盘上，可继续加载。）',
      );
    }
    if (err.contains('不存在')) return <Map<String, dynamic>>[];
    if (!err.contains('未知方法')) {
      lastError = err;
      return _systemErrorRow(lastError!);
    }

    // ---- 旧宿主：没有 fs.readTailLines ----
    //
    // 能读到全文（旧实现没有 1MB 闸）⇒ 本地切最后 N 行，语义与 tail 一致；
    // 只拿到前 1MB ⇒ **拿不到真正的尾部**，必须如实说"最新消息可能未显示"，
    // 不能把前 1MB 当完整历史（那正是旧的 bug）。
    final full = await _ch.call('fs.readText', <String, Object?>{
      'path': path,
      'offsetLine': 1,
      'maxLines': 0,
    });
    final ferr = errorOf(full);
    if (ferr != null) {
      if (ferr.contains('不存在')) return <Map<String, dynamic>>[];
      lastError = ferr;
      return _systemErrorRow(lastError!);
    }
    final truncated = full['truncated'] == true;
    lastLoadHasEarlier = true;
    lastLoadTruncatedAtHead = truncated;
    lastError = truncated
        ? '通道不支持尾部读取（旧宿主），且会话超过通道 1MB 上限：'
            '当前只拿到前 1MB，**最新消息可能未显示**。请升级 App 后重新打开会话。'
        : '通道不支持尾部读取（旧宿主）：仅为省内存加载了最近 '
            '${ContractSession.tailLoadLines} 条；更早的消息仍在磁盘上。';
    return _parseAndWindow(
      full,
      want: ContractSession.tailLoadLines,
      skip: skip,
      hasEarlier: true,
      truncatedAtHead: truncated,
      pagingText: truncated
          ? '（通道不支持尾部读取且记录超过 1MB：当前显示的是前 1MB 的末尾，'
              '**最新消息可能未显示**；请升级 App。）'
          : '（通道不支持尾部读取（旧宿主）：仅为省内存加载了最近 '
              '${ContractSession.tailLoadLines} 条；更早的消息仍在磁盘上。）',
      appendNoShowSuffix: false,
    );
  }

  /// 统一的"读失败"返回形状：一条 system 行，**不是静默空列表**。
  List<Map<String, dynamic>> _systemErrorRow(String reason) =>
      <Map<String, dynamic>>[
        <String, dynamic>{'role': 'system', 'text': reason, 'ts': 0},
      ];

  /// 解析通道返回的文本 → 行列表，并应用分页窗口。
  ///
  /// 抽成方法是为了让**多条路径共用同一套窗口逻辑**
  /// （`readTailLines` 正常路径 / `readText` 回落路径 / `limit=0` 的 tail 兜底）——
  /// 分开写过一次就出过 bug：回落路径把整个文件原样返回，分页被丢。
  ///
  /// [hasEarlier]/[truncatedAtHead] 会**只增**地写进那条 `_synthetic: paging`
  /// 提示行（老读者忽略未知键）；[pagingText] 用来按来源给不同的人话。
  List<Map<String, dynamic>> _parseAndWindow(
    Map<String, Object?> raw, {
    required int want,
    required int skip,
    bool hasEarlier = false,
    bool truncatedAtHead = false,
    String? pagingText,
    bool appendNoShowSuffix = true,
  }) {
    final text = (raw['text'] as String?) ?? '';
    final all = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(text)) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map) {
          all.add(decoded.map((k, v) => MapEntry(k.toString(), v)));
        }
        // 不是对象（例如坏掉的一行只剩个数字）⇒ 跳过这行，不影响其它行
      } catch (_) {
        // 半行/坏行：跳过。`.jsonl` 的抗损坏能力就靠这个。
        continue;
      }
    }

    // ---- 分页窗口 ----
    //
    // `all` 是拿到的行（顺序 = 写入顺序）。几条路径内容**不一样**：
    //
    // | 路径 | `all` 是什么 |
    // |---|---|
    // | `readTailLines` | 已经是**最近 (want+skip+余量) 行** |
    // | `readText`（回落/全量） | **整个文件** |
    //
    // 统一做法：先截"最后 (want+skip) 条"，再在该窗口内甩掉 skip 条。
    // 这对两种情况都成立（对尾部读是幂等的：它本来就已经是尾巴）。
    List<Map<String, dynamic>> out;
    if (want > 0) {
      var window = all;
      final windowSize = want + skip;
      if (window.length > windowSize) {
        window = window.sublist(window.length - windowSize);
      }
      if (skip > 0 && window.length > skip) {
        window = window.sublist(0, window.length - skip);
      }
      // 尾部读带回来的余量可能让窗口偏长 ⇒ 只要最后 want 条
      if (window.length > want) {
        window = window.sublist(window.length - want);
      }
      out = List<Map<String, dynamic>>.of(window);
    } else {
      out = all;
    }

    // 有更早的消息没加载 ⇒ 插一条提示（UI 的 `_toMessages` 已支持 system role）。
    // ★ 只增：`hasEarlier` / `truncatedAtHead` 两个键 + `_synthetic` 标记。
    final earlier = hasEarlier || (want > 0 && all.length > out.length);
    if (earlier) {
      out.insert(0, <String, dynamic>{
        'role': 'system',
        'text': pagingText ??
            '（更早的消息未加载：只为省内存加载了最近 $want 条。'
                '完整记录仍在磁盘上。）',
        'ts': 0,
        '_synthetic': 'paging',
        'hasEarlier': true,
        if (truncatedAtHead) 'truncatedAtHead': true,
      });
    }

    if (lastError != null) {
      out.add(<String, dynamic>{
        'role': 'system',
        'text': appendNoShowSuffix
            ? '${lastError!}后面的消息没有显示。'
            : lastError!,
        'ts': 0,
      });
    }
    return out;
  }

  /// **追加一条消息** —— 只准追加，绝不准整文件重写。
  ///
  /// ## 实现形状（如实说明）
  ///
  /// 通道没有 append 原语 ⇒ 「读全文 → 在末尾拼一行 → 写全文」。
  /// **语义上仍是 append-only**：写之前断言 `updated` 以 `existing` 为前缀，
  /// 也就是**既有字节一个都没改**（见文件头 KDoc 的"降级"说明）。
  /// 机械上不是 O(1) 追加；真铁律需要 Kotlin 侧加 `fs.appendText`。
  ///
  /// ## 三道防线（任何一道不过就**拒绝写入**，绝不赌）
  ///
  /// 1. **旧文件读不全**（`truncated == true`，超过 1 MB）⇒ 拒绝。
  ///    否则写回时会把没读到的那半截**永久删掉**。
  /// 2. **并发 append** ⇒ 拒绝（见 `_appending`）。
  /// 3. **写回结果不是"旧内容 + 新行"** ⇒ 理论上不可能，但仍断言一次。
  ///
  /// ## ⚠️ 调用方必须串行化
  ///
  /// 同一会话的 append **不许并发**（本类不是线程安全的，也刻意不做成
  /// 看起来是）。类内只能**检测**并发并如实失败 —— 检测不到跨实例 /
  /// 跨进程的竞争。
  /// **追加一条消息** —— 只准追加，绝不准整文件重写。
  ///
  /// ## 2026-10-23：从"读改写"升级为**真追加**（长会话卡顿的根治）
  ///
  /// ### 改之前为什么卡
  ///
  /// 通道过去只有 `fs.writeText`（整体覆盖）⇒ 每次追加都是
  /// 「读全文 → 拼一行 → 写全文」。一轮对话有 3–5 次 append，于是：
  ///
  /// | 会话长度 | 单次 append 搬运 | 一轮（4 次） |
  /// |---|---|---|
  /// | 10 条 | ~2 KB | 8 KB |
  /// | 200 条 | ~40 KB | 320 KB |
  /// | 1000 条 | ~200 KB | **1.6 MB** |
  ///
  /// ⇒ **O(n²)**。而且撞上通道的 1 MB 文本上限后**直接拒绝写入**
  /// —— 表现就是"长会话聊到一半卡住不动"。
  ///
  /// ### 现在
  ///
  /// 优先走 `fs.appendText`（Kotlin 侧 `FileOutputStream(append=true)` /
  /// SAF `openOutputStream(uri,"wa")`）= **O(追加量)**，且不读旧内容
  /// ⇒ 1 MB 上限不再影响追加。
  ///
  /// **三条防线保留**（只是不再需要读全文来满足它们）：
  /// 1. 旧 APK 没有 `fs.appendText` ⇒ 回落"读改写"（那条路仍然正确，只是慢）；
  /// 2. 回落路径在 `truncated == true` 时**拒绝写入**（否则会吃掉后半截）；
  /// 3. 并发 append ⇒ 拒绝（见 `_appending`）。
  ///
  /// ## ⚠️ 调用方必须串行化
  ///
  /// 同一会话的 append **不许并发**（本类不是线程安全的，也刻意不做成
  /// 看起来是）。类内只能**检测**并发并如实失败。
  Future<bool> appendMessage(
    String sessionId,
    Map<String, dynamic> message,
  ) async {
    lastError = null;
    // ★ 防穿越：非法 id 不拼路径（如实失败，不抛给调用方）
    final String path;
    try {
      path = messagesPath(sessionId);
    } on ArgumentError catch (e) {
      lastError = '会话 id 非法，拒绝写入会话记录：$e';
      return false;
    }

    if (_appending) {
      // 检测到并发：如实失败比悄悄丢一行好
      lastError = '同一个会话的上一次追加还没写完（并发调用 appendMessage）。'
          '会话是 append-only 的，并发读改写会丢行 ⇒ 已拒绝本次写入。'
          '调用方必须把同一会话的 append 串行化。';
      return false;
    }
    _appending = true;
    try {
      // ---- 先序列化（失败就不用碰磁盘）----
      final entry = _normalizeEntry(message);
      if (entry == null) {
        lastError = '这一行消息缺少 role（或含不可编码对象），未写入。'
            '`.jsonl` 每行都必须有 role，否则读方不知道该怎么画。';
        return false;
      }
      final line = _encodeLine(entry);
      if (line == null) {
        lastError = '这一行消息无法编码成 JSON（可能含 NaN/Infinity 或循环引用），未写入。';
        return false;
      }

      // ---- ⓪ 先确保目录在（2026-10-27）：真追加与读改写都要求
      //      父目录已存在，缺了它每一次写都会失败 ----
      await _ensureStorageDirs();

      // ---- ① 优先：真追加（O(追加量)）----
      final appended = await _appendViaChannel(path, '$line\n');
      if (appended.ok) return true;
      if (!appended.supported) {
        // 通道不支持 ⇒ 回落读改写（旧 APK）。**不是失败**，只是慢。
        //
        // ⚠️ 仍在 `try` 块内 `await` 后再 return：`finally` 要等
        //   回落写完才复位 `_appending` 并发闸 —— 闸提前放开会让
        //   同一会话的第二次 append 挤进来读到半截文件（丢行场景）。
        final ok = await _appendReadModifyWrite(sessionId, path, '$line\n');
        if (!ok) _reportAppendFailure(sessionId);
        return ok;
      }
      lastError = appended.error;
      _reportAppendFailure(sessionId);
      return false;
    } finally {
      _appending = false;
    }
  }

  /// 落盘失败时留一条诊断日志（2026-10-27）：此前 append 失败全程
  /// 静默，是「记录全没了」迟迟定位不到的帮凶。日志走既有
  /// `[heracles][session]` 前缀，logcat 可查。
  void _reportAppendFailure(String sessionId) {
    // ignore: avoid_print
    print('[heracles][session] 消息落盘失败（$sessionId）：$lastError');
  }

  /// 走 `fs.appendText` 真追加。
  ///
  /// @return `ok` = 成功；`supported == false` = 通道没这个方法（旧 APK，
  ///         调用方应回落）；否则 `ok == false` 且 `error` 有原因。
  Future<({bool ok, bool supported, String? error})> _appendViaChannel(
    String path,
    String text,
  ) async {
    final raw = await _ch.call('fs.appendText', <String, Object?>{
      'path': path,
      'text': text,
    });
    final err = errorOf(raw);
    if (err == null) return (ok: true, supported: true, error: null);

    // 旧 APK：通道回"未知方法：fs.appendText"
    if (err.contains('未知方法')) {
      return (ok: false, supported: false, error: null);
    }
    // SAF provider 不支持 "wa" 追加模式 ⇒ 也回落（那条路仍正确）
    if (err.contains('不支持追加') || err.contains('文件不存在')) {
      return (ok: false, supported: false, error: null);
    }
    return (ok: false, supported: true, error: err);
  }

  /// 回落路径：读全文 → 拼 → 写全文。**只在通道不支持真追加时用。**
  ///
  /// 这一步保留了原来的三道防线（尤其"读不全就拒绝写"）——
  /// 它是唯一可能**吃掉用户数据**的地方，不能因为"现在是回落路径"就放松。
  Future<bool> _appendReadModifyWrite(
    String sessionId,
    String path,
    String lineWithNewline,
  ) async {
    final raw = await _ch.call('fs.readText', <String, Object?>{
      'path': path,
      'offsetLine': 1,
      'maxLines': 0,
    });
    final err = errorOf(raw);
    var existing = '';
    if (err != null) {
      if (!err.contains('不存在')) {
        lastError = '读取会话记录失败，未追加：$err';
        return false;
      }
      // 文件还不存在 ⇒ 本次写就是"建文件 + 第一行"，合法
    } else {
      if (raw['truncated'] == true) {
        lastError = '会话记录已超过通道 1 MB 文本上限，读不全'
            '（当前 APK 还没有 fs.appendText 快速追加）。'
            '**本次没有写入** —— 在"只读到前半截"的状态下拼新行再写回，'
            '会把没读到的那部分永久删掉。\n'
            '请升级 App，或先把旧会话归档/裁短。\n'
            '文件：$path';
        return false;
      }
      existing = (raw['text'] as String?) ?? '';
    }

    // 旧内容末尾没有换行时先补一个（补的是追加，既有字节没动）
    final needsNewline = existing.isNotEmpty && !existing.endsWith('\n');
    final updated = '$existing${needsNewline ? "\n" : ""}$lineWithNewline';

    // 防线：既有内容必须是新内容的**前缀**
    if (!updated.startsWith(existing)) {
      lastError = '内部断言失败：拼接结果不是"旧内容 + 新行"，已放弃写入（会丢用户数据）。';
      return false;
    }

    final w = await _ch.call('fs.writeText', <String, Object?>{
      'path': path,
      'text': updated,
    });
    final werr = errorOf(w);
    if (werr != null) {
      lastError = '写入会话记录失败（${_humanize(werr)}）。会话文件位置：$path';
      return false;
    }
    return true;
  }

  /// 本实例是否正在写（**只用于检测并发，不是锁**）。
  bool _appending = false;

  /// 从一条回答开新会话分支（与 UI 的 `_branchFrom` 配套）。
  ///
  /// ## 为什么是"新建文件"而不是"在原会话上开分支"
  ///
  /// 底层会话严格 append-only（`ADR-001`：分支的缓存命中 25–105% **不可预测**，
  /// 而 append-only 有 90–99%）。所以分支 = **新建一个会话，把原会话到
  /// 某条回答为止的内容整段抄过去**：新会话从第一行起就是干净的 append-only 流。
  ///
  /// 代价（如实写在 KDoc 里，别让人以为分支免费）：新会话第一轮**没有缓存命中**，
  /// 上下文要重新预填充一次。
  ///
  /// ## 参数形状与任务书的两处差异（故意的）
  ///
  /// - 任务书写 `seedBranch(root, id, entries)`；这里 **id 是返回值**（新会话的 id
  ///   调用方拿不到就没有意义），标题代替 id 做入参。想指定 id 可传 [sessionId]。
  /// - [entries] 里的值**故意宽松**：UI 传过来的 `i` / `ms` 是**字符串**
  ///   （`chat_screen.dart` 的 `_branchFrom` 里写的 `'i': old.index.toString()`）。
  ///   写入前会被 `_normalizeEntry` 规整成数字 —— 因为消费方
  ///   `_toMessages` 用的是 `(m['i'] as num?)?.toInt()`，
  ///   拿到字符串会**抛 TypeError 把读会话整条链路打断**。
  ///
  /// @return 新会话 id（建索引 / 写消息失败返回 `null`，原因在 [lastError]）
  Future<String?> seedBranch(
    List<Map<String, dynamic>> entries, {
    String title = '分支',
    String? sessionId,
  }) async {
    lastError = null;
    final newId = sessionId ?? await _newId();

    // ★ 防穿越：调用方显式指定的 id 非法 ⇒ 直接失败，不先写索引（否则
    //   索引里会留一条永远删不掉的坏会话）。
    final String? probe;
    try {
      probe = messagesPath(newId);
    } on ArgumentError catch (e) {
      lastError = '会话 id 非法，拒绝创建分支：$e';
      return null;
    }
    final id = newId;
    final pathHint = probe;

    // ---- 先落索引（索引成功、消息失败 ⇒ 用户看到空会话；反过来更糟：
    //      消息在但索引没有 ⇒ UI 根本列不出它，等于数据隐身）----
    final list = await listSessions();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _writeIndex(<SessionMeta>[
      ...list,
      SessionMeta(id: id, title: _titleOf(title), updatedAt: now),
    ]);
    if (lastError != null) return null;

    // ---- 整份写消息文件（**新建**，不是改写既有会话 ⇒ 允许）----
    final buf = StringBuffer();
    for (final e in entries) {
      final entry = _normalizeEntry(e);
      if (entry == null) continue;
      final line = _encodeLine(entry);
      if (line == null) continue;
      buf.writeln(line);
    }
    final raw = await _ch.call('fs.writeText', <String, Object?>{
      'path': pathHint,
      'text': buf.toString(),
    });
    final err = errorOf(raw);
    if (err != null) {
      lastError = '分支会话的消息写入失败：$err';
      return null;
    }
    return id;
  }
}

// ============================================================================
// 行规整 —— JSON 一行一条的守门人
// ============================================================================

/// 把一条 Map 编码成**单行** JSON；编码不了返回 `null`。
///
/// 为什么要单独一步而不是直接 `jsonEncode`：`jsonEncode` 对 `NaN` /
/// `Infinity` / 循环引用会**抛异常**。那种异常发生在写盘路径上，
/// 会把"这条消息没写成"变成"整个 append 崩了"。这里收敛成 `null`。
String? _encodeLine(Map<String, dynamic> entry) {
  try {
    final line = jsonEncode(entry);
    // `jsonEncode` 本身不会产出裸换行；真出现了说明被喂了畸形对象。
    // 一行一条是 `.jsonl` 的命根子 ⇒ 转义掉，绝不写多行。
    return line.contains('\n') ? line.replaceAll('\n', r'\n') : line;
  } catch (_) {
    return null;
  }
}

/// 规整一条消息，让它**能被消费方安全读回**。
///
/// ## 为什么需要这一步（不是多余的）
///
/// 消费方是 `chat_screen.dart` 的 `_toMessages`，它用的是**硬 cast**：
///
/// ```dart
/// index: (m['i'] as num?)?.toInt(),               // ← 字符串会抛 TypeError
/// durationMs: (m['ms'] as num?)?.toInt(),
/// truncated: (m['truncated'] as bool?) == true,   // ← 字符串会抛
/// ```
///
/// 而 UI 的 `_branchFrom` 恰恰传的是**字符串**（`'i': old.index.toString()`）。
/// 不规整的话：分支写进去 → 下次切换会话 → `as num?` 抛异常 → **整个会话打不开**。
/// 旧 Kotlin 侧靠 `JSONObject.optInt()` 的宽松转换躲过了这个问题；
/// Dart 的 JSON 读回来是 `num`/`String` 原样，所以必须在这里做。
///
/// ## 规整规则（只动"已知的数值/布尔字段"，**其它键一律原样保留**）
///
/// | 字段 | 目标类型 |
/// |---|---|
/// | `ts` / `i` / `ms` / `cached` / `prompt` / `out` / `turns` / `exitCode` | int |
/// | `ok` / `truncated` / `starred` / `archived` | bool |
/// | `text` / `think` / `tool` / `result` / `reason` / `stage` / `stepId` / `title` / `role` / `attach` / `surface` / `command` | String |
/// | `args` | Map（值原样，读方自己 `toString()`） |
///
/// `exitCode` / `surface` / `command` 是 **D6（2026-10-29）只增** 的历史命令卡
/// 字段（`docs/接口.md` §7.2）：旧文件缺它们照常解析；写入方取不到真实值就
/// **不写键**（不写假 0 / 不猜执行面），所以这里只做类型规整、不补默认值。
///
/// 未知键**保留**（`.jsonl` 是长期数据，将来加字段时旧版本也要能带着它）
/// —— 但 `null` 值会被去掉（省字节，且 `containsKey` 判断更干净）。
///
/// 返回 `null` = 这行没有 `role`（读方无法画它）。**不编造 role**。
Map<String, dynamic>? _normalizeEntry(Map<String, dynamic> message) {
  final out = <String, dynamic>{};
  for (final entry in message.entries) {
    final k = entry.key;
    final v = entry.value;
    if (v == null) continue;

    if (_intKeys.contains(k)) {
      final n = _intOf(v);
      if (n != null) out[k] = n;
      continue;
    }
    // ★ T1-5（2026-10-31）：`steadyHitRate` 是唯一浮点键（只增；
    //   解不出数就不写 —— 不写假 0）。
    if (_doubleKeys.contains(k)) {
      final d = _doubleOf(v);
      if (d != null) out[k] = d;
      continue;
    }
    if (_boolKeys.contains(k)) {
      final b = _boolOf(v);
      if (b != null) out[k] = b;
      continue;
    }
    if (_stringKeys.contains(k)) {
      out[k] = v is String ? v : '$v';
      continue;
    }
    out[k] = v;
  }

  // `role` 必须有（没有 role 的行读方不知道该怎么画）
  final role = out['role'];
  if (role == null || '$role'.trim().isEmpty) {
    // 不编造一个 role：那会让读方把一行未知数据画成用户消息。
    // 返回 null ⇒ 调用方**跳过这一行**，其余照写（`.jsonl` 的抗损坏纪律）。
    return null;
  }

  // `ts` 缺了就补（`.jsonl` 每行都该有时间戳，缺了排序/展示会怪）
  out['ts'] ??= DateTime.now().millisecondsSinceEpoch;
  return out;
}

const Set<String> _intKeys = <String>{
  'ts',
  'i',
  'ms',
  'cached',
  'prompt',
  'out',
  'turns',
  // ★ D6（2026-10-29）：历史命令卡的真实退出码（只增；缺失时调用方不写键）
  'exitCode',
  // ★ T1-5（2026-10-31）：会话用量汇总行 `role:"session_usage"` 的累计计数
  //   （只增；旧文件没有这些键照常读，未知键原样保留逻辑不动）
  'runs',
  'reportedTurns',
  'unreportedTurns',
};

/// 浮点键（T1-5）：`steadyHitRate` 是 double；宽松接受 num/数字字符串。
const Set<String> _doubleKeys = <String>{
  'steadyHitRate',
};

const Set<String> _boolKeys = <String>{
  'ok',
  'truncated',
  'starred',
  'archived',
};

const Set<String> _stringKeys = <String>{
  'role',
  'text',
  'think',
  'tool',
  'result',
  'reason',
  'stage',
  'stepId',
  'title',
  'attach',
  // ★ D6（2026-10-29）：历史命令卡的真实执行面/实际命令（只增）
  'surface', // sandbox / mobileShell / unknown
  'command',
  // ★ JSONL 记账（2026-10-29）：审批/提问结果行的字符串字段（只增；
  //   `questions`/`answers` 是 Map/List，走"未知键原样保留"那条路）
  'callId',
  'decision', // once / always / deny
  'outcome', // allowed/denied/timeout/cancelled/auto_allowed/answered
};

// ============================================================================
// 小工具
// ============================================================================

/// 索引读结果（内部用）。
class _IndexRead {
  const _IndexRead(this.items, {this.error});

  final List<Object?> items;
  final String? error;
}

/// 宽松取 int：`int` / `double` / 数字字符串都能来。
///
/// 为什么要吃字符串：UI 的 `_branchFrom` 传的是 `'i': index.toString()`。
int? _intOf(Object? v) {
  if (v is int) return v;
  if (v is num) return v.isFinite ? v.toInt() : null;
  if (v is String) return int.tryParse(v.trim());
  if (v is bool) return v ? 1 : 0;
  return null;
}

/// 宽松取 double：`num` / 数字字符串都认（T1-5 的 `steadyHitRate` 用）。
///
/// 返回 `null` = 无法解析（**不写假 0** —— 与 cached 同一条口径纪律）。
double? _doubleOf(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) {
    final t = v.trim();
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }
  return null;
}

/// 宽松取 bool：`bool` / `"true"·"1"` / `1` 都认（旧数据里三种都出现过）。
bool? _boolOf(Object? v) {  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final t = v.trim().toLowerCase();
    if (t == 'true' || t == '1' || t == 'yes') return true;
    if (t == 'false' || t == '0' || t == 'no') return false;
  }
  return null;
}

/// 标题兜底：空标题一律落到「新会话」。
String _titleOf(Object? v) {
  final t = v is String ? v.trim() : '';
  return t.isEmpty ? '新会话' : t;
}

/// 异常 → 短人话（与能力层同口径：堆栈对模型没用）。
String _humanize(Object e) {
  final s = e.toString();
  return s.length > 300 ? '${s.substring(0, 300)}…' : s;
}
