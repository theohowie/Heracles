/// **App 全局长期记忆**（2026-10-23）—— 跨会话、跨工作区共享。
///
/// ## 这个文件解决什么问题（用户报的现象）
///
/// 改动之前，记忆写在 `<工作区>/.heracles/memory.md`，有两个功能性缺陷：
///
/// | 缺陷 | 用户感知 |
/// |---|---|
/// | 存在工作区里 | 换个工作区 ⇒ 记忆全没了 |
/// | `renderMemory()` 全仓 0 处调用 | 记了也用不上，**换会话必失忆** |
///
/// 现在固定放在 **App 级私有目录**（`<getExternalFilesDir>/heracles/memory.md`），
/// 与工作区无关 —— 这正是"长期记忆"该有的语义。路径只有原生知道
/// （Dart 拿不到 `getExternalFilesDir` 的值），所以一切走 `memory.*` 通道。
///
/// ## 为什么这个类不在 `device_capabilities.dart` 里
///
/// 它同时服务两个消费方，而它们的生命周期完全不同：
///
/// | 消费方 | 怎么用 |
/// |---|---|
/// | `FileMemoryCapability`（backend 的 `MemoryCapability`） | 让模型能 `save_memory` |
/// | 设置页（读 / 清空、给用户看） | **与 agent 无关**，不该为了看记忆而构造一整套能力 |
///
/// 放在独立文件里，设置页可以直接 `const GlobalMemory()` 用，不用背着
/// workspace / shell / apk 那一堆东西。
///
/// ## 铁律：**失败不抛**
///
/// 记忆是"锦上添花"的能力，不是主链路。它失败时**绝不该让调用方崩**
/// （`MemoryCapability.read` 的签名甚至没有失败通道，本来就是 `String`）。
/// 所以：
///
/// · 通道不可用 / 文件读不出来 ⇒ [read] 返回 `''`
/// · 写入失败（含超 256KB）⇒ [append] 返回 `false`
///
/// ## ⚠️ 那"静默失败"怎么办
///
/// 不能静默 —— 用户以为记住了、实际没记，是最糟的一种失败。
/// 但本类又必须能被 `const` 构造（设置页要能直接 `const GlobalMemory()`，
/// 且**可变状态会让调用方之间产生隐式耦合**）。
///
/// ⇒ 解法：**失败原因从返回值出去**，不存字段。
/// 要原因就调 [readResult] / [appendResult]（返回带 `error` 的对象）；
/// 只要成败就用 [read] / [append] / [clear] 这套简单签名。
/// 两套都在，调用方按需要选，**没有隐藏的全局状态**。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:heracles_backend/heracles_backend.dart'
    show ContractMemory, MemoryAddress, MemoryScope;

import 'device_capabilities.dart';
import 'memory_service.dart';

/// 一次记忆读取的结果。
///
/// [text] 是正文；[error] 非 null 表示**读失败**（此时 [text] 为空串）。
/// 两者必须分开：`text == ''` 既可能是"还没有记忆"（正常），
/// 也可能是"读不出来"（异常），而这两种对用户要说不同的话。
class MemoryReadResult {
  const MemoryReadResult({
    required this.text,
    required this.bytes,
    this.error,
  });

  const MemoryReadResult.error(String reason)
      : text = '',
        bytes = 0,
        error = reason;

  final String text;

  /// 当前记忆的**字节数**（UTF-8；`0` = 没有记忆）。
  final int bytes;

  /// `null` = 读成功（含"文件不存在"这种正常情况）。
  final String? error;

  /// 有没有内容可显示。
  bool get isEmpty => text.trim().isEmpty;

  /// 是否已经接近上限（≥ 90%）。设置页据此提示用户清理。
  ///
  /// 2026-10-29：上限从"256 KB 硬写闸"改为 **global 存储软预算**
  /// （`ContractMemory.storageGlobalSoftMaxBytes`，8 MB）。"接近上限"只用于
  /// 建议清理，**不再意味着到顶会拒写**（超软预算由 Kotlin 侧按
  /// 过期→最旧 agent→最旧 user 淘汰）。
  bool get nearlyFull => bytes >= (GlobalMemory.storageSoftMaxBytes * 0.9);
}

/// 一次记忆写入的结果。
class MemoryWriteResult {
  const MemoryWriteResult({required this.ok, this.bytes, this.error});

  const MemoryWriteResult.failure(String reason)
      : ok = false,
        bytes = null,
        error = reason;

  final bool ok;

  /// 写入后的总字节数（成功时由 Kotlin 侧回报）。
  final int? bytes;

  /// `ok == false` 时的**人话原因**（超限 / 通道不可用 / 内容为空…）。
  final String? error;
}

/// **某作用域的记忆统计**（存储侧；INTERFACE §N12.6 的 `MemoryStats`）。
///
/// 注入侧数字（每轮最多多少字符）由 backend `ContractMemory` 给，
/// 不在这个对象里 —— 两组预算互不推导（N12.8）。
class MemoryStats {
  const MemoryStats({
    required this.scope,
    required this.entries,
    required this.bytes,
    required this.storageSoftMaxBytes,
    required this.entriesSoftMax,
  });

  factory MemoryStats.of(ScopedMemoryStats s) => MemoryStats(
        scope: s.scope.wireName,
        entries: s.entries,
        bytes: s.bytes,
        storageSoftMaxBytes: s.storageSoftMaxBytes,
        entriesSoftMax: s.entriesSoftMax,
      );

  /// `global / workspace / session`。
  final String scope;

  /// 存活条目数。
  final int entries;

  /// 存活条目的正文总字节（不含墓碑）。
  final int bytes;

  /// 该作用域的存储**软预算**（字节；超限淘汰，不拒写）。
  final int storageSoftMaxBytes;

  /// 该作用域的条目软上限。
  final int entriesSoftMax;
}

/// **一条待确认的全局记忆提议**（agent 写 global 的唯一通道）。
class MemoryProposal {
  const MemoryProposal({
    required this.id,
    required this.text,
    required this.kind,
    required this.status,
    required this.createdAt,
  });

  factory MemoryProposal.of(ScopedMemoryProposal p) => MemoryProposal(
        id: p.id,
        text: p.text,
        kind: p.kind,
        status: p.status,
        createdAt: p.createdAt,
      );

  final String id;
  final String text;
  final String kind;

  /// `pending / promoted / rejected`。
  final String status;
  final int createdAt;
}

// ============================================================================
// 旧 memory.md → global.jsonl 迁移（设计稿 §3.7；触发点 §3.7.2 步骤 0）
// ============================================================================

/// 迁移结果（`memory.migrate` 通道的 App 侧形状）。
///
/// 正常态有三种，**都不是错误**：
/// · `migrated:true` —— 真的迁移了（备份已写、旧文件留档）；
/// · `alreadyMigrated:true` —— 之前迁移过（幂等，字节不变）；
/// · `noLegacyFile` —— 从来没有旧 `memory.md`（新用户）。
class MemoryMigrationResult {
  const MemoryMigrationResult({
    required this.ok,
    this.migrated = false,
    this.alreadyMigrated = false,
    this.noLegacyFile = false,
    this.entries = 0,
    this.backup,
    this.error,
  });

  /// 通道返回形状 → 结果。**不抛**（迁移失败要能让主链路继续）。
  factory MemoryMigrationResult.fromChannel(Map<String, Object?> raw) {
    final ok = raw['ok'] == true;
    if (!ok) {
      final e = raw['error'];
      return MemoryMigrationResult(
        ok: false,
        error: e is String && e.trim().isNotEmpty ? e : '记忆迁移失败（未给出原因）',
      );
    }
    final reason = '${raw['reason'] ?? ''}';
    return MemoryMigrationResult(
      ok: true,
      migrated: raw['migrated'] == true,
      alreadyMigrated: raw['alreadyMigrated'] == true,
      noLegacyFile: reason == 'no-legacy-file',
      entries: (raw['entries'] is num)
          ? (raw['entries'] as num).toInt()
          : 0,
      backup: raw['backup'] is String ? raw['backup'] as String : null,
    );
  }

  /// `false` = 迁移过程失败（旧文件应原样保留，可重跑）。
  final bool ok;
  final bool migrated;
  final bool alreadyMigrated;
  final bool noLegacyFile;

  /// 迁移了多少条（0 = 没迁移）。
  final int entries;

  /// 迁移前备份路径（旧 `memory.md` 的留档）。
  final String? backup;

  /// `ok == false` 时的人话原因（**不含记忆正文**）。
  final String? error;
}

/// 进程内"是否已尝试过迁移"（一次性；设计稿 §3.7.2 步骤 0）。
bool _memoryMigrationAttempted = false;

/// **首轮记忆读取之前 best-effort 迁移一次**（幂等 + 不阻断）。
///
/// 调用点：`LocalAgentExecutor.run()` 首次读三作用域之前。
/// 之后的轮次直接短路（进程内 bool）—— 迁移是启动级动作，不该每轮都打通道。
///
/// 失败只 `debugPrint`（**不打印记忆正文**，只打印错误码/原因），
/// 绝不让记忆迁移把主链路搞崩（不变量 I7）。
Future<MemoryMigrationResult> runMemoryMigrationOnce({
  DeviceChannelClient? channel,
}) async {
  if (_memoryMigrationAttempted) {
    return const MemoryMigrationResult(ok: true, alreadyMigrated: true);
  }
  _memoryMigrationAttempted = true;
  final result = await migrateLegacyMemory(channel: channel);
  if (!result.ok) {
    // 仅排障：错误码/人话原因，绝不含正文。
    debugPrint('[heracles][memory] 迁移失败（不阻断运行）：${result.error}');
  } else if (result.migrated) {
    debugPrint('[heracles][memory] 旧记忆已迁移：${result.entries} 条，'
        '备份=${result.backup ?? "(无)"}');
  }
  return result;
}

/// 显式执行一次 `memory.migrate`（记忆页「重新迁移」按钮 / 排障用）。
///
/// 与 [runMemoryMigrationOnce] 不同：**没有一次性标记**，调用即执行
/// （Kotlin 侧幂等：`alreadyMigrated` / `no-legacy-file` 都是正常返回）。
Future<MemoryMigrationResult> migrateLegacyMemory({
  DeviceChannelClient? channel,
}) async {
  final ch = channel ?? const DeviceChannelClient();
  try {
    final raw = await ch.call('memory.migrate');
    return MemoryMigrationResult.fromChannel(raw);
  } catch (e) {
    return MemoryMigrationResult(ok: false, error: '调用记忆迁移失败：$e');
  }
}

/// 测试缝：清掉"已尝试迁移"标记（让一次性行为可重复验证）。
@visibleForTesting
void resetMemoryMigrationForTest() => _memoryMigrationAttempted = false;


/// App 全局长期记忆的客户端。
///
/// ## 2026-10-29：降级为**兼容层**
///
/// 记忆系统改为三作用域（session / workspace / global，见
/// `docs/INTERFACE.md` §N12），真正的读写/寻址/淘汰在
/// [ScopedMemoryService]。本类保留是为了：
///
/// · **旧设置页**仍直接 `const GlobalMemory()` 读列表/容量；
/// · `MemoryEntry` / [parseEntries] / [composeRetrieval] 仍被旧 UI 与既有测试用；
/// · `memory.read`（global.jsonl 原文）是兼容通道方法。
///
/// ⚠️ **关键红线（2026-10-29）**：旧实现的新增/编辑/删除走
/// `clear()` + 逐条 `append()`，而 Kotlin 的 `memory.append` 现在是
/// **永久只读**（`E_SCOPE_READONLY`）⇒ 那条路径会"先清空 global 再回写失败"，
/// 等于**丢掉整份全局记忆**。所以 [addEntry] / [updateEntry] / [deleteEntry] /
/// [clear] 已全部改走 [ScopedMemoryService] 的**用户路径**
/// （global ⇒ 通道 `memory.userEdit`，追加墓碑/原子重写，不再 clear+append）。
/// `_rewrite` 已删除。
class GlobalMemory {
  /// [channel] / [service] 均可注入（测试用 mock handler / 假服务）。
  ///
  /// `const` 构造 ⇒ 可以到处用 `const GlobalMemory()`；两者都不传时，
  /// 按需构造默认实现（无跨调用隐式状态）。
  const GlobalMemory({DeviceChannelClient? channel, ScopedMemoryService? service})
      : _ch = channel, // ignore: prefer_initializing_formals
        _service = service; // ignore: prefer_initializing_formals

  final DeviceChannelClient? _ch;
  final ScopedMemoryService? _service;

  DeviceChannelClient get _channel => _ch ?? const DeviceChannelClient();

  /// 用户路径的记忆服务（global 写走 `memory.userEdit`）。
  ScopedMemoryService get _svc => _service ?? ScopedMemoryService(channel: _ch);

  /// global 寻址（全局无需 session/workspace）。
  static const MemoryAddress globalAddress =
      MemoryAddress(scope: MemoryScope.global);

  /// **global 存储软预算**（8 MB，来自 backend `ContractMemory`）。
  ///
  /// 语义：软预算 ⇒ 超限**淘汰**（过期 → 最旧 agent → 最旧 user），
  /// **不是"到顶拒写"**。数值唯一来源仍是 `ContractMemory`（INTERFACE §N12.8）。
  static const int storageSoftMaxBytes =
      ContractMemory.storageGlobalSoftMaxBytes;

  /// 旧名（256 KB 写闸时代）：**已废弃**，保留只为旧设置页/旧测试能编译。
  ///
  /// ⚠️ 它现在的值等于 [storageSoftMaxBytes]（8 MB），**不再是 256KB**，
  /// 也**不再有任何"到顶拒写"语义** —— 别拿它当硬上限。
  @Deprecated('用 storageSoftMaxBytes；256KB 写闸已随记忆三作用域重设计废除')
  static const int maxBytes = storageSoftMaxBytes;

  /// 读全部记忆。
  ///
  /// 文件不存在 ⇒ `''`（第一次用还没有记忆，**这是正常状态**）。
  /// 读失败也⇒ `''` —— 想区分就调 [readResult]。
  Future<String> read() async => (await readResult()).text;

  /// 读全部记忆，**带字节数与失败原因**（设置页 / 排障用）。
  Future<MemoryReadResult> readResult() async {
    final raw = await _channel.call('memory.read');
    final err = errorOf(raw);
    if (err != null) return MemoryReadResult.error(err);

    final text = (raw['text'] as String?) ?? '';
    final n = raw['bytes'];
    final bytes = n is int ? n : (n is num ? n.toInt() : text.length);
    return MemoryReadResult(text: text, bytes: bytes);
  }

  /// 追加一条记忆（**一行**，行首带 ISO 时间戳 —— 由 Kotlin 侧加）。
  ///
  /// @return `true` = 写进去了；`false` = 没写（原因见 [appendResult]）。
  ///
  /// ⚠️ **超限时是"拒绝"而不是"截断"**：写半条会让用户以为记住了。
  Future<bool> append(String note) async => (await appendResult(note)).ok;

  /// 追加并拿到**失败原因**（**旧通道原语，过渡期兼容**）。
  ///
  /// ⚠️ 2026-10-29 起 `memory.append` 在 Kotlin 侧**永久只读**
  /// （返回 `E_SCOPE_READONLY`）—— 全局记忆只能由用户动作经
  /// `memory.userEdit` 写入。本方法保留只为"忘记升级的调用方拿到明确错误"，
  /// 新代码请用 [addEntry] 或 `ScopedMemoryService.userAdd`。
  @Deprecated('memory.append 已永久只读；用 addEntry / ScopedMemoryService.userAdd')
  Future<MemoryWriteResult> appendResult(String note) async {
    if (note.trim().isEmpty) {
      return const MemoryWriteResult.failure('要记住的内容是空的');
    }
    final raw = await _channel.call('memory.append', <String, Object?>{
      'note': note,
    });
    final err = errorOf(raw);
    if (err != null) return MemoryWriteResult.failure(err);

    final n = raw['bytes'];
    return MemoryWriteResult(
      ok: true,
      bytes: n is int ? n : (n is num ? n.toInt() : null),
    );
  }

  // ==========================================================================
  // 结构化条目（N7，2026-10-24 —— 前端 INTERFACE.md 的记忆页数据源）
  //
  // ## 格式
  //
  // global.jsonl 每行一条 **JSON 条目**（与 session/workspace 同形状，
  // 见 INTERFACE §N12.3）；`memory.read` 返回原文，解析时取行内第一个 `{`
  // 起 decode（Kotlin 旧格式行首的 ISO 时间戳前缀当噪声忽略）。
  //
  // ## 旧格式迁移
  //
  // 非 JSON 行（历史纯文本）读出来按 kind='other'、source='legacy' 的条目
  // 对待 —— 不丢内容，只是没有结构字段。
  //
  // ## 增删改：**不再 clear + 逐条 append**（2026-10-29 红线修复）
  //
  // 旧实现用 `read/append/clear` 三个原语合成改写，并在 `memory.append`
  // 永久只读之后变成"先清空再失败 = 丢整份记忆"。现在全部走
  // `ScopedMemoryService` 的用户路径（通道 `memory.userEdit`，Kotlin 侧
  // 追加墓碑/原子重写，成功或明确失败，**不存在半清空状态**）。
  // ==========================================================================

  /// 解析记忆文件全文为条目列表（含旧格式迁移）。
  static List<MemoryEntry> parseEntries(String raw) {
    final out = <MemoryEntry>[];
    var legacy = 0;
    for (var line in raw.split('\n')) {
      line = line.trim();
      if (line.isEmpty) continue;
      final brace = line.indexOf('{');
      if (brace >= 0) {
        try {
          final j = jsonDecode(line.substring(brace)) as Map<String, dynamic>;
          final text = (j['text'] as String?) ?? '';
          if (text.isEmpty) continue;
          out.add(MemoryEntry(
            id: (j['id'] as String?) ?? 'm${out.length}',
            kind: (j['kind'] as String?) ?? 'other',
            text: text,
            source: (j['source'] as String?) ?? 'agent',
            createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
            expiresAt: (j['expiresAt'] as num?)?.toInt(),
          ));
          continue;
        } catch (_) {
          // 落到 legacy 分支
        }
      }
      legacy++;
      out.add(MemoryEntry(
        id: 'legacy-$legacy',
        kind: 'other',
        text: line,
        source: 'legacy',
        createdAt: 0,
      ));
    }
    return out;
  }

  /// 条目 → 存储行（JSON）。
  ///
  /// ⚠️ 2026-10-29 起**不再由 App 拼存储行**（写入走 `memory.userEdit`，
  /// 行形状由 Kotlin 权威生成，见 INTERFACE §N12.3）。保留为测试/排障用的
  /// 形状参考不合适 —— 已删除，避免第二份真相。
  ///
  /// **检索式注入**（M4，2026-10-25）：按当前任务给条目打相关性分，
  /// 相关条目全文在前、其余压成一行摘要 —— 不再无差别全量塞入。
  ///
  /// ## 打分与排序（M6 显式优先在这里生效）
  ///
  /// · 关键词：ASCII 词（≥2 字符）+ CJK 二元组；得分 = 在条目正文的出现次数；
  /// · **用户亲手加的条目（source=user）同分置顶** —— "用户说记住"优先；
  /// · 无任何匹配 ⇒ 原文原样返回（旧行为，不白白破坏缓存）；
  /// · 相关性排序随任务变化 ⇒ 那一轮前缀缓存重建（固有代价，如实记账）。
  static String composeRetrieval(List<MemoryEntry> entries, String task) {
    entries = entries.where((e) => e.isAlive()).toList()
      ..sort((a, b) {
        if ((a.source == 'user') != (b.source == 'user')) {
          return a.source == 'user' ? -1 : 1;
        }
        return 0;
      });
    if (entries.isEmpty) return '';

    final keywords = <String>{};
    for (final m in RegExp(r'[A-Za-z0-9_]{2,}').allMatches(task)) {
      keywords.add(m.group(0)!.toLowerCase());
    }
    for (final m in RegExp(r'[一-鿿]{2}').allMatches(task)) {
      keywords.add(m.group(0)!);
    }
    if (keywords.isEmpty) {
      return entries.map((e) => e.text).join('\n');
    }

    final scored = <List<dynamic>>[];
    for (final e in entries) {
      var score = 0;
      final lower = e.text.toLowerCase();
      for (final k in keywords) {
        var idx = lower.indexOf(k);
        while (idx >= 0) {
          score++;
          idx = lower.indexOf(k, idx + k.length);
        }
      }
      scored.add([score, e]);
    }
    scored.sort((a, b) => (b[0] as int).compareTo(a[0] as int));

    final matched = scored.where((s) => (s[0] as int) > 0).toList();
    final rest = scored.where((s) => (s[0] as int) <= 0).toList();
    if (matched.isEmpty) {
      return entries.map((e) => e.text).join('\n');
    }
    final buf = StringBuffer();
    buf.writeln('【与当前任务相关的记忆】');
    for (final pair in matched) {
      final e = pair[1] as MemoryEntry;
      buf.writeln('- (${e.kind}) ${e.text}');
    }
    if (rest.isNotEmpty) {
      buf.writeln();
      buf.writeln('【其余记忆（摘要）】');
      for (final pair in rest) {
        final e = pair[1] as MemoryEntry;
        final t = e.text.length <= 40 ? e.text : '${e.text.substring(0, 40)}…';
        buf.writeln('- (${e.kind}) $t');
      }
    }
    return buf.toString().trimRight();
  }

  /// 列出全部**未过期**条目（M6 有效期：过期的读取即过滤）。
  Future<List<MemoryEntry>> listEntries() async =>
      parseEntries(await read()).where((e) => e.isAlive()).toList();

  /// 三作用域条目 → 旧 UI 模型（只增 `scope`/`sid`，字段一一对应）。
  static MemoryEntry entryOf(ScopedMemoryEntry e) => MemoryEntry(
        id: e.id,
        kind: e.kind,
        text: e.text,
        source: e.source,
        createdAt: e.createdAt,
        expiresAt: e.expiresAt,
        scope: e.scope.wireName,
        sid: e.sid,
      );

  /// 追加一条（用户路径；global ⇒ 通道 `memory.userEdit{action:"add"}`）。
  ///
  /// SEC4 由 [ScopedMemoryService] 统一执行（与本类旧的正则同一套口径），
  /// 这里先做一次是为了保留旧的**同文案**失败提示。
  ///
  /// [source] 只为兼容旧调用点保留：用户路径写入的 `source` 恒为 `user`
  /// （`promoted` 由提议晋升产生，不经过这里）。
  Future<MemoryWriteResult> addEntry(String text,
      {String kind = 'other', String source = 'user'}) async {
    final t = text.trim();
    if (t.isEmpty) return const MemoryWriteResult.failure('内容为空');
    if (_secretPattern.hasMatch(t)) {
      return const MemoryWriteResult.failure(
          '内容疑似包含密钥/令牌，拒绝写入长期记忆（明文存储，泄露风险）');
    }
    return _runUser(
      () => _svc.userAdd(globalAddress, t, kind: kind),
    );
  }

  /// **更新一条**（用户路径；global ⇒ `memory.userEdit{action:"update"}`）。
  ///
  /// ★ 2026-10-29 红线修复：不再"读全文→clear→逐条 append"。
  /// 那条路径在 `memory.append` 永久只读之后会**丢掉整份全局记忆**。
  Future<MemoryWriteResult> updateEntry(String id, String text) async {
    final t = text.trim();
    if (t.isEmpty) return const MemoryWriteResult.failure('内容为空');
    if (_secretPattern.hasMatch(t)) {
      return const MemoryWriteResult.failure('内容疑似包含密钥/令牌，拒绝写入');
    }
    return _runUser(() => _svc.userUpdate(globalAddress, id, t));
  }

  /// **删除一条**（用户路径；global ⇒ `memory.userEdit{action:"delete"}`）。
  ///
  /// ★ 同 [updateEntry]：绝不走 clear+append。
  Future<MemoryWriteResult> deleteEntry(String id) =>
      _runUser(() => _svc.userDelete(globalAddress, <String>[id]));

  /// 用户路径写操作的统一翻译：`MemoryWriteOutcome` → 旧 `MemoryWriteResult`。
  ///
  /// 失败**不抛**（本类的铁律"失败不抛"），把人话原因放进返回值。
  Future<MemoryWriteResult> _runUser(
    Future<MemoryWriteOutcome> Function() op,
  ) async {
    try {
      final out = await op();
      return MemoryWriteResult(ok: true, bytes: out.bytes);
    } on MemoryServiceError catch (e) {
      return MemoryWriteResult.failure(e.message);
    } catch (e) {
      return MemoryWriteResult.failure('记忆写入失败：$e');
    }
  }

  /// 容量（N7 的 memoryCapacity）：usedBytes / 软预算。
  ///
  /// `maxBytes` 现在 = **global 存储软预算**（8 MB），不是 256KB 硬上限；
  /// 超软预算只会触发淘汰，不拒写。
  Future<({int usedBytes, int maxBytes})> capacity() async {
    final r = await readResult();
    return (usedBytes: r.bytes, maxBytes: storageSoftMaxBytes);
  }

  /// 清空全局记忆（用户路径；`memory.userEdit{action:"clear"}`）。
  ///
  /// Kotlin 侧落到 `memory.clear` 等价的**用户确认后清空**语义（追加 clear
  /// 墓碑/原子重写），不再是裸截断。
  ///
  /// @return `false` = 清空失败（原因见 [clearResult]）。
  Future<bool> clear() async => (await clearResult()).ok;

  /// 清空并拿到失败原因（设置页用）。
  Future<MemoryWriteResult> clearResult() =>
      _runUser(() => _svc.userClear(globalAddress));
}

/// 疑似密钥/令牌特征（SEC4；与 backend save_memory 同一闸）。
final _secretPattern = RegExp(
    r'(sk-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}'
    r'|gho_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{15,}|[A-Fa-f0-9]{32,})');

/// **一条长期记忆**（N7 结构化条目）。
///
/// `kind` 词表由后端定（INTERFACE.md §7.3）：`preference`（长期偏好）/
/// `background`（项目背景）/ `habit`（使用习惯）/ `other`；前端只展示。
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.kind,
    required this.text,
    required this.source,
    required this.createdAt,
    this.expiresAt,
    this.scope,
    this.sid,
  });

  final String id;
  final String kind;
  final String text;
  final String source;

  /// 毫秒时间戳；legacy 条目为 0。
  final int createdAt;

  /// **有效期**（M6，2026-10-25）：到期时间戳；null = 永不过期。
  /// 读取时（[parseEntries] 之后的 [isAlive]）过滤过期条目。
  final int? expiresAt;

  /// 所属作用域（wire 名 `global/workspace/session`）。
  ///
  /// 2026-10-29 只增字段：旧数据/旧构造为 `null`（没有分层概念）。
  /// UI 据此分组展示；不参与旧 [MemoryEntry] 的解析规则。
  final String? scope;

  /// session 作用域时的会话 id（其它作用域恒 `null`）。
  final String? sid;

  bool isAlive([int? nowMs]) =>
      expiresAt == null || expiresAt! > (nowMs ?? DateTime.now().millisecondsSinceEpoch);
}
