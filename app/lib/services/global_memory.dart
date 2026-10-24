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
import 'device_capabilities.dart';

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
  bool get nearlyFull => bytes >= (GlobalMemory.maxBytes * 0.9);
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

/// App 全局长期记忆的客户端。
class GlobalMemory {
  /// [channel] 可注入（测试用 mock handler）。
  ///
  /// `const` 构造 + 无可变字段 ⇒ 可以到处用 `const GlobalMemory()`，
  /// 且**不存在"上一次操作的原因"这种跨调用隐式状态**（见文件头）。
  const GlobalMemory({DeviceChannelClient? channel})
      : _ch = channel ?? const DeviceChannelClient();

  final DeviceChannelClient _ch;

  /// 记忆文件大小上限：**256 KB**。
  ///
  /// 与 Kotlin `MemoryStore.MAX_BYTES`、backend `Contract.Memory.maxBytes`
  /// **必须同一个数**。真正的闸在 Kotlin（它是写入口），这里给 UI 显示用。
  static const int maxBytes = 256 * 1024;

  /// 读全部记忆。
  ///
  /// 文件不存在 ⇒ `''`（第一次用还没有记忆，**这是正常状态**）。
  /// 读失败也⇒ `''` —— 想区分就调 [readResult]。
  Future<String> read() async => (await readResult()).text;

  /// 读全部记忆，**带字节数与失败原因**（设置页 / 排障用）。
  Future<MemoryReadResult> readResult() async {
    final raw = await _ch.call('memory.read');
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

  /// 追加并拿到**失败原因**。
  ///
  /// 最常见的失败是"已达 256 KB 上限"，那句话是 Kotlin 写的（含当前大小
  /// 与上限），**原样透传**，不在这里改写。
  Future<MemoryWriteResult> appendResult(String note) async {
    if (note.trim().isEmpty) {
      return const MemoryWriteResult.failure('要记住的内容是空的');
    }
    final raw = await _ch.call('memory.append', <String, Object?>{
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
  // memory.md 每行一条 **JSON 条目**（Kotlin 侧追加时行首会带 ISO 时间戳
  // 前缀 —— 解析时取行内第一个 '{' 起 decode，前缀当噪声忽略）：
  //   {"id":"m169...","kind":"preference","text":"...","source":"user","createdAt":169...}
  //
  // ## 旧格式迁移
  //
  // 非 JSON 行（历史纯文本）读出来按 kind='other'、source='legacy' 的条目
  // 对待 —— 不丢内容，只是没有结构字段。**写入永远用新格式**。
  //
  // ## 为什么增删改走"读全文→改→clear→逐条 append"而不动 Kotlin
  //
  // 通道只有 read/append/clear 三个原语，而记忆文件在 App 私有目录
  // （Dart 够不到文件系统）—— 用三个原语合成改写是唯一不扩 Kotlin 的路。
  // 代价：改写期间若进程被杀，clear 已生效而 append 未完成 ⇒ 丢尾部条目。
  // 概率极低、后果是"少一条记忆"而非损坏 —— 如实接受。
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
  static String _entryLine(MemoryEntry e) => jsonEncode({
        'id': e.id,
        'kind': e.kind,
        'text': e.text,
        'source': e.source,
        'createdAt': e.createdAt,
      });

  /// 列出全部条目。
  Future<List<MemoryEntry>> listEntries() async =>
      parseEntries(await read());

  /// 追加一条（SEC4：疑似密钥拒收 —— 与 backend save_memory 同一闸）。
  Future<MemoryWriteResult> addEntry(String text,
      {String kind = 'other', String source = 'user'}) async {
    final t = text.trim();
    if (t.isEmpty) return const MemoryWriteResult.failure('内容为空');
    if (_secretPattern.hasMatch(t)) {
      return const MemoryWriteResult.failure(
          '内容疑似包含密钥/令牌，拒绝写入长期记忆（明文存储，泄露风险）');
    }
    return appendResult(_entryLine(MemoryEntry(
      id: 'm${DateTime.now().microsecondsSinceEpoch}',
      kind: kind,
      text: t,
      source: source,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    )));
  }

  /// 更新一条（读全文→改→clear→逐条重写）。
  Future<MemoryWriteResult> updateEntry(String id, String text) async {
    final entries = await listEntries();
    final idx = entries.indexWhere((e) => e.id == id);
    if (idx < 0) return MemoryWriteResult.failure('条目不存在：$id');
    final t = text.trim();
    if (t.isEmpty) return const MemoryWriteResult.failure('内容为空');
    if (_secretPattern.hasMatch(t)) {
      return const MemoryWriteResult.failure('内容疑似包含密钥/令牌，拒绝写入');
    }
    entries[idx] = MemoryEntry(
      id: entries[idx].id,
      kind: entries[idx].kind,
      text: t,
      source: entries[idx].source,
      createdAt: entries[idx].createdAt,
    );
    return _rewrite(entries);
  }

  /// 删除一条。
  Future<MemoryWriteResult> deleteEntry(String id) async {
    final entries = await listEntries();
    final n = entries.length;
    entries.removeWhere((e) => e.id == id);
    if (entries.length == n) {
      return MemoryWriteResult.failure('条目不存在：$id');
    }
    return _rewrite(entries);
  }

  Future<MemoryWriteResult> _rewrite(List<MemoryEntry> entries) async {
    final ok = await clear();
    if (!ok) return const MemoryWriteResult.failure('重写失败：清空原文件出错');
    for (final e in entries) {
      final r = await append(_entryLine(e));
      if (!r) {
        return const MemoryWriteResult.failure('重写失败：写入条目时超限');
      }
    }
    return MemoryWriteResult(ok: true, bytes: entries.length);
  }

  /// 容量（N7 的 memoryCapacity）：usedBytes / maxBytes。
  Future<({int usedBytes, int maxBytes})> capacity() async {
    final r = await readResult();
    return (usedBytes: r.bytes, maxBytes: maxBytes);
  }

  /// 清空记忆（把文件截断成 0 字节）。
  ///
  /// 为什么是"清空文件"而不是"删文件"：删了之后与"从没用过"无法区分，
  /// 而用户要的是"我把它清空了"。Kotlin 侧按这个语义实现（幂等）。
  ///
  /// @return `false` 时原因需要另取（本方法没有 detailed 版本 ——
  ///         清空只有"成功/失败"两种，UI 提示一句"清空失败"即可）。
  Future<bool> clear() async {
    final raw = await _ch.call('memory.clear');
    return errorOf(raw) == null;
  }
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
  });

  final String id;
  final String kind;
  final String text;
  final String source;
  final int createdAt; // 毫秒时间戳；legacy 条目为 0
}
