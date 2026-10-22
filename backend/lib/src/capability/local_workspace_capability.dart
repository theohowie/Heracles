/// **本地工作区能力** —— 基于 `dart:io` 的 [WorkspaceCapability] 实现。
///
/// ## 这个实现服务谁
///
/// PC 与手机**都能跑**（纯 `dart:io`，不 import Flutter、不碰 Android API）。
/// 它覆盖"普通 POSIX 路径"这一种存储；Android 的 SAF 工作区由 App 侧的
/// MethodChannel 实现，不走这里。
///
/// ## 两条不可退让的红线
///
/// 1. **路径穿越防护**：任何相对路径里出现 `..` 且逃出 `workRoot` ⇒
///    立刻 [CapabilityFailure]，**绝不碰 root 外的东西**。
///    理由不是"防止恶意模型"——是**防止一次手误**把 `/home/user` 删了。
///    旧实现有 `PathGuard` 专管这件事，迁移时丢了。
/// 2. **绝不抛异常**：所有失败都变成 [CapabilityFailure] + 一句人话。
///    异常会让模型看到堆栈，它读不懂也不知道下一步该做什么。
///    （工具壳 `ToolFactory` 虽然也兜底 catch，但能力层自己说清"为什么失败"
///    比"工具执行出错：FileSystemException…"有用得多。）
///
/// ## 行号前缀的格式
///
/// `read` 返回的每一行都带行号前缀，格式固定为：
///
/// ```
///     1| 第一行
///     2| 第二行
///    12| 第十二行
/// ```
///
/// —— 宽度 [ContractWorkspace.lineNumberWidth] 位、右对齐、后接 `| `。
/// **固定宽度是为了列对齐**，让模型（和 `edit` 的 oldText 比对）更容易对上。
/// 这个格式被 `test/local_workspace_capability_test.dart` 钉住。
library;

import 'dart:convert';
import 'dart:io';

import '../capability/capabilities.dart';
import '../contract/contract.dart';

/// 基于 `dart:io` 的工作区实现。
class LocalWorkspaceCapability implements WorkspaceCapability {
  /// [workRoot] 必须是绝对路径 —— 相对路径的语义取决于进程 CWD，
  /// 而 CWD 在 App 里可能是 `/`（`实测-03` 坑 27 踩过：引擎去跟根目录打交道）。
  LocalWorkspaceCapability(String workRoot)
      : _root = _normalizeRoot(workRoot);

  final Directory _root;

  /// 工作区根的绝对路径（用于错误信息里回告，不含尾部分隔符）。
  String get rootPath => _root.path;

  static Directory _normalizeRoot(String workRoot) {
    if (workRoot.trim().isEmpty) {
      throw ArgumentError('workRoot 不能为空');
    }
    final abs = Directory(workRoot).absolute.path;
    // 去掉尾部分隔符（Windows 的 "D:\a\" 与 "D:\a" 必须是同一个 root）
    final trimmed = abs.endsWith(Platform.pathSeparator) && abs.length > 1
        ? abs.substring(0, abs.length - 1)
        : abs;
    return Directory(trimmed);
  }

  // ==========================================================================
  // 路径解析 —— 唯一的安全闸
  // ==========================================================================

  /// 把相对路径解析成"确定在 root 内"的绝对 [FileSystemEntity] 路径。
  ///
  /// 返回 `null` 表示被拒；[lastError] 里有原因。
  ///
  /// ## 为什么用"规范化后比较前缀"而不是"检查字符串里有没有 `..`"
  ///
  /// 因为 `a/../../b`、`./../x`、`a\..\..\b`（Windows 分隔符）都是绕法。
  /// 唯一可靠的做法是**先把路径规范化成绝对路径，再判断它是否以 root 为前缀**。
  ///
  /// 还要额外挡两件事：
  /// - **绝对路径**：`path` 的契约是"相对工作区"，传绝对路径视为越界
  ///   （否则模型可以读 `/etc/passwd`）
  /// - **符号链接**：`root/link → /etc`，规范化文本不会暴露它。
  ///   ⇒ 解析出真实路径再比一次（`resolveSymbolicLinksSync`，失败就退回文本比较）
  String? _resolve(String path) {
    _lastError = null;

    if (path.trim().isEmpty) return _root.path;

    // 绝对路径一律拒绝（Windows 盘符 + POSIX 前导斜杠）
    final looksAbsolute = path.startsWith('/') ||
        path.startsWith(r'\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
    if (looksAbsolute) {
      _lastError = '只接受相对工作区的路径，收到绝对路径 `$path`。'
          '请改成相对路径（例如 `src/main.dart`）。';
      return null;
    }

    // 规范化：把 '\' 统一成 '/' 再交给 URI 解析，处理 `.` 与 `..`
    final normalizedRelative = _normalizeRelative(path);
    if (normalizedRelative == null) {
      _lastError = '路径 `$path` 越出了工作区根目录（`$rootPath`）。'
          '工作区以外的文件不可访问，请使用工作区内的相对路径。';
      return null;
    }

    final absolute = normalizedRelative.isEmpty
        ? _root.path
        : '${_root.path}${Platform.pathSeparator}$normalizedRelative';

    // 文本前缀检查（双保险：`_normalizeRelative` 已经挡过一次）
    if (!_isInsideRoot(absolute)) {
      _lastError = '路径 `$path` 越出了工作区根目录（`$rootPath`）。'
          '工作区以外的文件不可访问，请使用工作区内的相对路径。';
      return null;
    }

    // 符号链接检查：目标是"已存在"才做，失败就接受文本判断的结果
    final real = _tryRealPath(absolute);
    if (real != null && !_isInsideRoot(real)) {
      _lastError = '路径 `$path` 通过符号链接指向了工作区之外（真实路径 `$real`），已拒绝。';
      return null;
    }
    return absolute;
  }

  /// 上一次 [_resolve] 失败的原因（[CapabilityFailure] 的正文）。
  String? _lastError;

  /// 规范化相对路径：消掉 `.` / `..` / 重复分隔符。
  ///
  /// 返回 `null` = 越界（`..` 把栈弹空了）。返回 `''` = 就是 root 自己。
  String? _normalizeRelative(String raw) {
    final unified = raw.replaceAll(r'\', '/');
    final parts = <String>[];
    for (final seg in unified.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isEmpty) return null; // 逃出 root
        parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    return parts.join('/');
  }

  bool _isInsideRoot(String absolute) {
    final norm = _stripTrailingSep(absolute.replaceAll(r'\', '/'));
    final root = _stripTrailingSep(_root.path.replaceAll(r'\', '/'));
    if (norm == root) return true;
    return norm.startsWith('$root/');
  }

  String _stripTrailingSep(String p) =>
      p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;

  /// 尽力解析真实路径（跟随符号链接）；不存在的路径返回 `null`。
  String? _tryRealPath(String absolute) {
    try {
      return File(absolute).resolveSymbolicLinksSync();
    } catch (_) {
      try {
        return Directory(absolute).resolveSymbolicLinksSync();
      } catch (_) {
        return null;
      }
    }
  }

  /// 解析失败时返回统一的 [CapabilityFailure]。
  CapabilityFailure _fail([String? reason]) =>
      CapabilityFailure(reason ?? _lastError ?? '路径无法解析');

  static CapabilityFailure _ex(String action, Object e) =>
      CapabilityFailure('$action 失败：${_humanize(e)}');

  static String _humanize(Object e) {
    final s = e.toString();
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  // ==========================================================================
  // 列目录
  // ==========================================================================

  @override
  Future<CapabilityResult> list(
    String path, {
    bool recursive = false,
    int maxEntries = ContractTools.maxEntries,
  }) async {
    final abs = _resolve(path);
    if (abs == null) return _fail();

    final dir = Directory(abs);
    if (!await dir.exists()) {
      return CapabilityFailure(
        '目录不存在：`${path.isEmpty ? '.' : path}`（绝对路径 `$abs`）。'
        '用 list_files 不带参数可以看工作区根目录。',
      );
    }

    final entries = <String>[];
    var truncated = false;
    var skipped = 0;

    try {
      final stream = dir.list(recursive: recursive, followLinks: false);
      await for (final entity in stream) {
        if (entries.length >= maxEntries) {
          truncated = true;
          skipped++;
          // 已经知道超限，但仍然要把剩余数完 —— "被截断了多少"是
          // 模型判断"该不该用更精确的 find_files"的关键信息。
          continue;
        }
        entries.add(_describe(entity));
      }
    } catch (e) {
      return _ex('列目录', e);
    }

    final buf = StringBuffer();
    buf.writeln('工作区目录：`${path.isEmpty ? "." : path}`'
        '${recursive ? "（递归）" : ""}');
    if (entries.isEmpty) {
      buf.writeln('（空目录）');
    } else {
      for (final line in entries) {
        buf.writeln(line);
      }
    }
    if (truncated) {
      buf.writeln();
      buf.writeln('⚠️ 已截断：最多返回 $maxEntries 项，另有 $skipped 项未列出。'
          '需要更精确的结果请用 find_files 按模式查找。');
    }
    return CapabilitySuccess(
      buf.toString().trimRight(),
      metadata: {
        'entries': entries.length,
        'truncated': truncated,
        'skipped': skipped,
      },
    );
  }

  String _describe(FileSystemEntity entity) {
    final rel = _relativeOf(entity.path);
    try {
      final stat = entity.statSync();
      if (stat.type == FileSystemEntityType.directory) {
        return '[目录] $rel/';
      }
      return '[文件] $rel (${_formatSize(stat.size)})';
    } catch (_) {
      // stat 失败（权限 / 刚被删）：仍然列出名字，标"未知"
      return '[未知] $rel';
    }
  }

  String _relativeOf(String absolute) {
    final root = _root.path;
    if (absolute == root) return '.';
    final prefix = '$root${Platform.pathSeparator}';
    final rel =
        absolute.startsWith(prefix) ? absolute.substring(prefix.length) : absolute;
    return rel.replaceAll(r'\', '/');
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ==========================================================================
  // 读文件
  // ==========================================================================

  @override
  Future<CapabilityResult> read(
    String path, {
    int offset = 1,
    int limit = 0,
  }) async {
    final abs = _resolve(path);
    if (abs == null) return _fail();

    final file = File(abs);
    if (!await file.exists()) {
      return CapabilityFailure(
        '文件不存在：`$path`（绝对路径 `$abs`）。'
        '先用 list_files / find_files 确认路径。',
      );
    }

    try {
      final len = await file.length();
      if (len > ContractWorkspace.maxReadFileBytes) {
        return CapabilityFailure(
          '文件太大（${_formatSize(len)}，上限 '
          '${_formatSize(ContractWorkspace.maxReadFileBytes)}）：`$path`。'
          '请用 find_files / grep_files 定位，或换一个更小的文件。',
        );
      }

      final bytes = await file.readAsBytes();
      if (_looksBinary(bytes)) {
        return CapabilityFailure(
          '`$path` 看起来是二进制文件（含 NUL 字节），不能按文本读取。',
        );
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter().convert(text);
      final totalLines = lines.length;

      final start = offset < 1 ? 1 : offset;
      if (start > totalLines && totalLines > 0) {
        return CapabilityFailure(
          '起始行 $start 超出文件范围（`$path` 共 $totalLines 行）。',
          isRetryable: true,
        );
      }
      final end = limit <= 0
          ? totalLines
          : (start - 1 + limit).clamp(0, totalLines);

      final buf = StringBuffer();
      for (var i = start; i <= end; i++) {
        buf.writeln(_numbered(i, lines[i - 1]));
      }
      if (buf.isEmpty) {
        buf.writeln('（文件为空，或该区间没有内容）');
      } else if (end < totalLines) {
        buf.writeln();
        buf.writeln('（只显示了第 $start–$end 行，共 $totalLines 行。'
            '继续读用 offset=${end + 1}。）');
      }

      return CapabilitySuccess(
        buf.toString().trimRight(),
        metadata: {
          'totalLines': totalLines,
          'from': start,
          'to': end,
        },
      );
    } catch (e) {
      return _ex('读文件', e);
    }
  }

  /// 行号前缀：固定宽度右对齐 + `| `。
  String _numbered(int lineNo, String content) =>
      '${lineNo.toString().padLeft(ContractWorkspace.lineNumberWidth)}| $content';

  static bool _looksBinary(List<int> bytes) {
    final n = bytes.length < ContractWorkspace.binarySniffBytes
        ? bytes.length
        : ContractWorkspace.binarySniffBytes;
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }

  // ==========================================================================
  // 写文件
  // ==========================================================================

  @override
  Future<CapabilityResult> write(String path, String content) async {
    final abs = _resolve(path);
    if (abs == null) return _fail();

    try {
      final file = File(abs);
      final existed = await file.exists();
      final parent = file.parent;
      if (!await parent.exists()) {
        return CapabilityFailure(
          '父目录不存在：`${_relativeOf(parent.path)}`。'
          '先 mkdir 建目录，再写文件。',
          isRetryable: true,
        );
      }
      await file.writeAsString(content, flush: true);
      final len = utf8.encode(content).length;
      return CapabilitySuccess(
        '${existed ? "已覆盖写入" : "已创建"} `$path`（${_formatSize(len)}）。',
        metadata: {'bytes': len, 'created': !existed},
      );
    } catch (e) {
      return _ex('写文件', e);
    }
  }

  // ==========================================================================
  // 编辑（唯一命中）
  // ==========================================================================

  @override
  Future<CapabilityResult> edit(String path, String oldText, String newText) async {
    final abs = _resolve(path);
    if (abs == null) return _fail();

    if (oldText.isEmpty) {
      return const CapabilityFailure(
        '`old_string` 不能为空。要新建文件请用 write_file。',
        isRetryable: true,
      );
    }

    final file = File(abs);
    if (!await file.exists()) {
      return CapabilityFailure('文件不存在：`$path`。先用 list_files 确认路径。');
    }

    try {
      final original = await file.readAsString();
      final hits = _countOccurrences(original, oldText);

      if (hits == 0) {
        // 0 命中：说清**期望什么**，并给出最接近的实际内容，绝不"尽力猜"。
        final near = _closestLine(original, oldText);
        return CapabilityFailure(
          '在 `$path` 里找不到 `old_string`（0 处命中）。'
          'old_string 必须与文件内容**逐字符一致**（含缩进与换行）。'
          '${near == null ? "" : "文件里最接近的一行是：`$near`。"}'
          '请先用 read_file 看清实际内容再改。',
        );
      }
      if (hits > 1) {
        return CapabilityFailure(
          '`old_string` 在 `$path` 里命中了 $hits 处，无法确定改哪一处。'
          '请把 old_string 写长一些（带上足够的上文/下文），使它唯一。'
          '要整体重写请用 write_file。',
        );
      }

      final updated = original.replaceFirst(oldText, newText);
      await file.writeAsString(updated, flush: true);

      return CapabilitySuccess(
        '已修改 `$path`（1 处替换，${_lineDelta(original, updated)}）。',
        metadata: {
          'replacements': 1,
          'bytesBefore': utf8.encode(original).length,
          'bytesAfter': utf8.encode(updated).length,
        },
      );
    } catch (e) {
      return _ex('编辑文件', e);
    }
  }

  /// 子串出现次数（非重叠）。
  int _countOccurrences(String haystack, String needle) {
    var count = 0;
    var from = 0;
    while (true) {
      final idx = haystack.indexOf(needle, from);
      if (idx < 0) return count;
      count++;
      from = idx + needle.length;
    }
  }

  /// 找一行"最像" oldText 首行的内容，用于 0 命中时的提示。
  ///
  /// 只在**唯一最长公共前缀**足够长时才给（否则给一个毫不相干的句子纯属误导）。
  String? _closestLine(String content, String oldText) {
    final target = oldText.split('\n').first.trim();
    if (target.isEmpty) return null;
    String? best;
    var bestScore = 0;
    for (final line in const LineSplitter().convert(content)) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final score = _commonPrefixLen(t, target);
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }
    // 至少要有一半相同才算"接近"，否则宁可不给
    if (bestScore < (target.length / 2).ceil() || bestScore < 3) return null;
    return best!.length > 120 ? '${best.substring(0, 120)}…' : best;
  }

  int _commonPrefixLen(String a, String b) {
    final n = a.length < b.length ? a.length : b.length;
    var i = 0;
    while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  String _lineDelta(String before, String after) {
    final b = const LineSplitter().convert(before).length;
    final a = const LineSplitter().convert(after).length;
    final d = a - b;
    if (d == 0) return '行数不变（$a 行）';
    return d > 0 ? '新增 $d 行（$b→$a 行）' : '删除 ${-d} 行（$b→$a 行）';
  }

  // ==========================================================================
  // unified diff
  // ==========================================================================

  /// 应用 unified diff。
  ///
  /// 支持的形状（最小可用）：
  ///
  /// ```
  /// @@ -12,3 +12,4 @@
  ///  context line
  /// -removed line
  /// +added line
  /// ```
  ///
  /// **匹配不上必须说清是哪个 hunk、期望什么、实际是什么** —— 绝不"尽力猜"。
  /// 猜错的补丁比不打的补丁危险得多（它会静默改坏代码）。
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async {
    final abs = _resolve(path);
    if (abs == null) return _fail();

    final file = File(abs);
    if (!await file.exists()) {
      return CapabilityFailure('文件不存在：`$path`。补丁只能打到已存在的文件。');
    }

    final hunks = _parseHunks(patch);
    if (hunks.isEmpty) {
      return const CapabilityFailure(
        '补丁里没有找到任何 `@@ -a,b +c,d @@` 头。'
        'apply_patch 只接受 unified diff 格式；单处小改直接用 edit 更省事。',
        isRetryable: true,
      );
    }

    try {
      final original = await file.readAsString();
      var lines = const LineSplitter().convert(original);
      // 从后往前打，避免前面的 hunk 改动把后面的行号顶偏
      for (var i = hunks.length - 1; i >= 0; i--) {
        final hunk = hunks[i];
        // sealed 类型 + switch ⇒ 两种情况都在编译期被检查，
        // **没有 `as List<String>` 强转**（强转是运行时炸弹）。
        switch (_applyHunk(lines, hunk, i + 1, path)) {
          case _HunkApplied(lines: final patched):
            lines = patched;
          case _HunkFailed(failure: final failure):
            return failure;
        }
      }

      // ⚠️ **必须自己拼回正文，不能直接 `lines.join('\n')`**。
      //
      // `LineSplitter().convert('a\nb\n')` 得到 `['a','b']` —— 末尾那个换行
      // 在切分时被吃掉了，于是 `lines.join('\n')` 拼回来是 `'a\nb'`。
      // 直接写回就等于**静默地把文件末尾的换行删了**（POSIX 文本文件的标准形状
      // 是"每行都以 \n 结尾"），`git diff` 会多出一条 `\ No newline at end of file`，
      // 有些解析器/工具（shell 脚本、Makefile）会因此改变行为。
      //
      // 同理 **行尾风格**：`LineSplitter` 会把 `\r\n` 也当行分隔符并**丢掉 `\r`**，
      // 所以 CRLF 文件若按 `'\n'` 拼回去，**整个文件的每一行行尾都被改写了** ——
      // 这是数据损坏级的（Windows 项目的 `git diff` 会整文件变红）。
      // ⇒ 先探测原文件的行尾风格，按同一种风格拼回。
      //
      // 两个 bug 都与本次重构无关（是重写过程中新写的 apply_patch 测试抓出来的）：
      // 原先没有任何测试覆盖"打完补丁后文件字节还对不对"。
      //
      // ## 已知边界（**实测过**，不是猜的）
      //
      // 用 `_rejoin` 单独跑了一遍往返（见测试里的 CRLF / 末尾空行用例）：
      // - 统一行尾 + 任意末尾空行数：`"a\n\n\n"` / `"\n\n"` / `"a\r\nb\r\n"` 等
      //   **全部逐字节往返一致**（`LineSplitter` 会保留中间/末尾的空行元素，
      //   只是不带行尾，所以"补多一个 eol"正好抵掉）；
      // - **唯一会变的是混合行尾**：`"a\r\nb\n"` ⇒ `"a\r\nb\r\n"`
      //   （探测到 `\r\n` 就当整个文件是 CRLF）。这在真实项目里极少见，
      //   但**确实会改字节** —— 别以为"补丁打成功了 = 文件一个字节都没动"。
      final eol = _detectEol(original);
      final updated = _rejoin(lines, original, eol);
      await file.writeAsString(updated, flush: true);
      return CapabilitySuccess(
        '已应用 ${hunks.length} 个 hunk 到 `$path`'
        '（${_lineDelta(original, updated)}）。',
        metadata: {'hunks': hunks.length},
      );
    } catch (e) {
      return _ex('应用补丁', e);
    }
  }

  /// 探测原文件的行尾风格。
  ///
  /// 判据：出现 `\r\n` 就当 CRLF 文件。**故意不从"占多数"推断** ——
  /// 简单的规则更好解释，出错时也更好查（整文件一个风格是绝大多数情况）。
  static String _detectEol(String text) =>
      text.contains('\r\n') ? '\r\n' : '\n';

  /// 按原文件的行尾风格与"末尾有没有换行"拼回正文。
  ///
  /// - 原文件以行尾结束 ⇒ 结果也以行尾结束（补丁不该改变这件事）
  /// - 原文件不以行尾结束 ⇒ 结果也别多加（别"顺手美化"用户的文件）
  /// - 空行列表 ⇒ 空串（空文件打补丁后仍是空文件）
  static String _rejoin(List<String> lines, String original, String eol) {
    if (lines.isEmpty) return '';
    final joined = lines.join(eol);
    final originalEndsWithEol =
        original.endsWith('\n') || original.endsWith('\r');
    return originalEndsWithEol ? '$joined$eol' : joined;
  }

  /// 解析出全部 hunk。
  List<_Hunk> _parseHunks(String patch) {
    final hunks = <_Hunk>[];
    _Hunk? current;
    for (final raw in const LineSplitter().convert(patch)) {
      final header = _hunkHeader.firstMatch(raw);
      if (header != null) {
        current = _Hunk(
          oldStart: int.parse(header.group(1)!),
          oldCount: int.tryParse(header.group(2) ?? '') ?? 1,
          newStart: int.parse(header.group(3)!),
          newCount: int.tryParse(header.group(4) ?? '') ?? 1,
        );
        hunks.add(current);
        continue;
      }
      if (current == null) continue;
      // 补丁尾部/文件头（--- / +++ / diff --git）不进 hunk 体
      if (raw.startsWith('--- ') || raw.startsWith('+++ ')) continue;
      if (raw.startsWith('diff ') || raw.startsWith('index ')) continue;
      if (raw.isEmpty) {
        // 空行可能是"上下文是一行空行"（严格的 unified diff 会写一个空格）。
        // 这里按上下文空行处理 —— 比丢掉它更容易对上。
        current.lines.add(_PatchLine(_PatchKind.context, ''));
        continue;
      }
      final marker = raw[0];
      final body = raw.substring(1);
      switch (marker) {
        case ' ':
          current.lines.add(_PatchLine(_PatchKind.context, body));
        case '-':
          current.lines.add(_PatchLine(_PatchKind.remove, body));
        case '+':
          current.lines.add(_PatchLine(_PatchKind.add, body));
        default:
          // `\ No newline at end of file` 之类的元行：忽略
          break;
      }
    }
    return hunks;
  }

  /// `@@ -12,3 +12,4 @@`（逗号与数量可省，省了就是 1）。
  static final _hunkHeader = RegExp(r'^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@');

  /// 应用单个 hunk。返回**新行列表**（[_HunkApplied]）或一条失败回告（[_HunkFailed]）。
  ///
  /// ## 为什么返回类型是 [_HunkOutcome] 而不是 [CapabilityResult]
  ///
  /// 它成功时要交回 **`List<String>`**（被打过补丁的行），失败时要交回
  /// **[CapabilityFailure]** —— 这两个类型毫无关系，`CapabilityResult` 装不下
  /// 前者（`CapabilitySuccess` 的 `data` 是 `String`，硬塞进去要序列化再解析回来）。
  ///
  /// 旧写法把它声明成 [CapabilityResult] 却在末尾 `return result;`
  /// （`List<String>`）⇒ `dart analyze` 报 `return_of_invalid_type`，
  /// 而调用处靠 `applied as List<String>` 强转 —— **强转就是运行时炸弹**：
  /// 一旦哪天真的返回 `CapabilitySuccess`，就是 `_TypeError` 而不是一句人话。
  /// 现在用 sealed 类型让**两种情况都是编译期穷尽检查**的。
  ///
  /// 失败信息必须包含三样：**哪个 hunk** / **期望什么** / **实际是什么**。
  _HunkOutcome _applyHunk(
    List<String> lines,
    _Hunk hunk,
    int hunkNo,
    String path,
  ) {
    // hunk 期望匹配的"旧"行序列（上下文 + 删除）
    final expected = <String>[
      for (final l in hunk.lines)
        if (l.kind != _PatchKind.add) l.text,
    ];
    final replacement = <String>[
      for (final l in hunk.lines)
        if (l.kind != _PatchKind.remove) l.text,
    ];

    // 先在 header 声称的位置试；不对再全文件搜（模型给的 -a,b 经常偏）
    final claimed = hunk.oldStart - 1;
    var at = _matchAt(lines, expected, claimed);
    if (at < 0) {
      at = _matchAt(lines, expected, 0);
    }
    if (at < 0) {
      // ★ 明确说清：哪个 hunk、期望什么、实际是什么
      //
      // ⚠️ 空文件时 `lines.length - 1` 是 -1，`clamp(0, -1)` 会抛
      // `ArgumentError`（lowerLimit > upperLimit）⇒ 必须先分情况。
      final actualAt = lines.isEmpty ? 0 : claimed.clamp(0, lines.length - 1);
      final slice = <String>[];
      for (var i = actualAt; i < lines.length && slice.length < expected.length; i++) {
        slice.add(lines[i]);
      }
      return _HunkFailed(
        CapabilityFailure(
          '补丁第 $hunkNo 个 hunk 匹配不上（`$path`）。\n'
          '它声称从第 ${hunk.oldStart} 行开始，期望读到 ${expected.length} 行：\n'
          '${_preview(expected)}\n'
          '但文件第 ${actualAt + 1} 行附近实际是：\n'
          '${_preview(slice)}\n'
          '请先 read_file 看清当前内容，再按实际内容重写补丁。'
          '（不会"尽力猜"——猜错会静默改坏代码。）',
        ),
      );
    }

    final result = <String>[];
    result.addAll(lines.sublist(0, at));
    result.addAll(replacement);
    result.addAll(lines.sublist(at + expected.length));
    return _HunkApplied(result);
  }

  /// 在 [from] 处尝试匹配；不中返回 -1。
  int _matchAt(List<String> lines, List<String> expected, int from) {
    if (expected.isEmpty) return from.clamp(0, lines.length);
    if (from < 0 || from + expected.length > lines.length) return -1;
    for (var i = 0; i < expected.length; i++) {
      if (lines[from + i] != expected[i]) return -1;
    }
    return from;
  }

  String _preview(List<String> lines) {
    if (lines.isEmpty) return '  （空）';
    final shown = lines.take(8).map((l) => '  | $l').join('\n');
    return lines.length > 8 ? '$shown\n  | …（共 ${lines.length} 行）' : shown;
  }

  // ==========================================================================
  // 目录 / 存在性 / 删除 / 移动 / 复制
  // ==========================================================================

  @override
  Future<CapabilityResult> mkdir(String path) async {
    final abs = _resolve(path);
    if (abs == null) return _fail();
    try {
      final dir = Directory(abs);
      final existed = await dir.exists();
      await dir.create(recursive: true);
      return CapabilitySuccess(
        existed ? '目录已存在：`$path`' : '已创建目录 `$path`',
      );
    } catch (e) {
      return _ex('建目录', e);
    }
  }

  @override
  Future<bool> exists(String path) async {
    final abs = _resolve(path);
    if (abs == null) return false;
    try {
      return await File(abs).exists() || await Directory(abs).exists();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async {
    final abs = _resolve(path);
    if (abs == null) return _fail();

    if (abs == _root.path) {
      return const CapabilityFailure(
        '拒绝删除工作区根目录本身。要清理内容请指定具体的子目录或文件。',
      );
    }

    try {
      final file = File(abs);
      if (await file.exists()) {
        await file.delete();
        return CapabilitySuccess('已删除文件 `$path`。');
      }
      final dir = Directory(abs);
      if (!await dir.exists()) {
        return CapabilityFailure('路径不存在：`$path`（没有可删除的东西）。');
      }
      if (!recursive) {
        // 非空目录不递归 ⇒ 明确拒绝，**一个文件都不删**
        //
        // ⚠️ `Directory.list()` 返回的是 **Stream**，不是 List：
        // `isNotEmpty` 在 Stream 上不存在（旧写法 `await ....isNotEmpty` 直接
        // 编译不过 —— `undefined_getter`）。Stream 上能问的是 `isEmpty`，
        // 它等到"第一个元素或流结束"就返回，正好是我们要的"有没有子项"。
        final hasChild = !await dir.list(followLinks: false).isEmpty;
        if (hasChild) {
          return CapabilityFailure(
            '目录非空：`$path`。要删除非空目录必须显式传 recursive=true。'
            '（这一个字是故意的：删除不可恢复。）',
          );
        }
      }
      await dir.delete(recursive: recursive);
      return CapabilitySuccess('已删除目录 `$path`${recursive ? "（递归）" : ""}。');
    } catch (e) {
      return _ex('删除', e);
    }
  }

  @override
  Future<CapabilityResult> move(String from, String to) async {
    final fromAbs = _resolve(from);
    if (fromAbs == null) return _fail();
    final toAbs = _resolve(to);
    if (toAbs == null) return _fail();

    try {
      final src = File(fromAbs);
      if (await src.exists()) {
        if (!await Directory(File(toAbs).parent.path).exists()) {
          return CapabilityFailure('目标父目录不存在：`${_relativeOf(File(toAbs).parent.path)}`。');
        }
        await src.rename(toAbs);
        return CapabilitySuccess('已移动 `$from` → `$to`。');
      }
      final srcDir = Directory(fromAbs);
      if (!await srcDir.exists()) {
        return CapabilityFailure('源路径不存在：`$from`。');
      }
      if (!await Directory(Directory(toAbs).parent.path).exists()) {
        return CapabilityFailure('目标父目录不存在：`${_relativeOf(Directory(toAbs).parent.path)}`。');
      }
      await srcDir.rename(toAbs);
      return CapabilitySuccess('已移动 `$from` → `$to`。');
    } catch (e) {
      return _ex('移动', e);
    }
  }

  @override
  Future<CapabilityResult> copy(String from, String to) async {
    final fromAbs = _resolve(from);
    if (fromAbs == null) return _fail();
    final toAbs = _resolve(to);
    if (toAbs == null) return _fail();

    try {
      final src = File(fromAbs);
      if (await src.exists()) {
        final target = File(toAbs);
        if (!await target.parent.exists()) {
          return CapabilityFailure('目标父目录不存在：`${_relativeOf(target.parent.path)}`。');
        }
        await src.copy(toAbs);
        return CapabilitySuccess('已复制 `$from` → `$to`。');
      }
      final srcDir = Directory(fromAbs);
      if (!await srcDir.exists()) {
        return CapabilityFailure('源路径不存在：`$from`。');
      }
      var count = 0;
      await for (final e in srcDir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = e.path.substring(srcDir.path.length);
        final dest = File('$toAbs$rel');
        await dest.parent.create(recursive: true);
        await e.copy(dest.path);
        count++;
        if (count > ContractWorkspace.maxVisitedFiles) {
          return CapabilityFailure(
            '源目录文件数超过 ${ContractWorkspace.maxVisitedFiles}，'
            '已停止复制（已复制 $count 个文件，结果不完整）。',
          );
        }
      }
      return CapabilitySuccess('已复制目录 `$from` → `$to`（$count 个文件）。');
    } catch (e) {
      return _ex('复制', e);
    }
  }

  // ==========================================================================
  // findFiles —— 自己实现的 glob（不引依赖）
  // ==========================================================================

  @override
  Future<CapabilityResult> findFiles(
    String pattern, {
    int maxResults = ContractTools.maxEntries,
  }) async {
    if (pattern.trim().isEmpty) {
      return const CapabilityFailure(
        '`pattern` 不能为空。例：`**/*.dart`。',
        isRetryable: true,
      );
    }
    final normalizedPattern = pattern.replaceAll(r'\', '/');
    final matcher = _Glob.toRegExp(normalizedPattern);

    final hits = <String>[];
    var truncated = false;
    var visited = 0;

    try {
      await for (final entity in _root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        visited++;
        if (visited > ContractWorkspace.maxVisitedFiles) {
          truncated = true;
          break;
        }
        final rel = _relativeOf(entity.path);
        if (matcher.hasMatch(rel)) {
          if (hits.length >= maxResults) {
            truncated = true;
            break;
          }
          hits.add(rel);
        }
      }
    } catch (e) {
      return _ex('查找文件', e);
    }

    final buf = StringBuffer();
    buf.writeln('glob `$pattern` 找到 ${hits.length} 个文件'
        '${truncated ? "（已截断）" : ""}：');
    if (hits.isEmpty) {
      buf.writeln('（没有匹配。模式区分大小写；`**` 匹配任意层目录。）');
    } else {
      for (final h in hits) {
        buf.writeln(h);
      }
    }
    if (truncated) {
      buf.writeln();
      buf.writeln('⚠️ 已截断：最多返回 $maxResults 个文件'
          '（已访问 $visited 个）。请用更精确的模式缩小范围。');
    }
    return CapabilitySuccess(
      buf.toString().trimRight(),
      metadata: {'count': hits.length, 'truncated': truncated, 'visited': visited},
    );
  }

  // ==========================================================================
  // grepFiles —— 正则搜内容
  // ==========================================================================

  @override
  Future<CapabilityResult> grepFiles(
    String pattern, {
    String pathFilter = '',
    int maxResults = ContractTools.maxEntries,
  }) async {
    final RegExp re;
    try {
      re = RegExp(pattern);
    } catch (e) {
      return CapabilityFailure(
        '正则表达式无法编译：`$pattern`（${_humanize(e)}）。请检查括号/转义。',
        isRetryable: true,
      );
    }

    final filter = pathFilter.trim().isEmpty
        ? null
        : _Glob.toRegExp(pathFilter.replaceAll(r'\', '/'));

    final out = <String>[];
    var truncated = false;
    var visitedFiles = 0;
    var searchedFiles = 0;
    var skippedTooBig = 0;
    var skippedBinary = 0;

    try {
      await for (final entity in _root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        visitedFiles++;
        if (visitedFiles > ContractWorkspace.maxVisitedFiles) {
          truncated = true;
          break;
        }
        final rel = _relativeOf(entity.path);
        if (filter != null && !filter.hasMatch(rel)) continue;

        final len = await entity.length();
        if (len > ContractWorkspace.grepPerFileBytes) {
          skippedTooBig++;
          continue;
        }
        final bytes = await entity.readAsBytes();
        if (_looksBinary(bytes)) {
          skippedBinary++;
          continue;
        }
        searchedFiles++;

        final content = utf8.decode(bytes, allowMalformed: true);
        final lines = const LineSplitter().convert(content);
        for (var i = 0; i < lines.length; i++) {
          if (!re.hasMatch(lines[i])) continue;
          if (out.length >= maxResults) {
            truncated = true;
            break;
          }
          final text = lines[i];
          final shown = text.length > 300 ? '${text.substring(0, 300)}…' : text;
          out.add('$rel:${i + 1}: $shown');
        }
        if (truncated) break;
      }
    } catch (e) {
      return _ex('搜索内容', e);
    }

    final buf = StringBuffer();
    buf.writeln('正则 `$pattern` 找到 ${out.length} 条匹配'
        '（搜索了 $searchedFiles 个文件${truncated ? "，已截断" : ""}）：');
    if (out.isEmpty) {
      buf.writeln('（没有匹配。）');
    } else {
      for (final line in out) {
        buf.writeln(line);
      }
    }
    if (truncated) {
      buf.writeln();
      buf.writeln('⚠️ 已截断：最多返回 $maxResults 条匹配。请用更精确的正则或 path_filter。');
    }
    if (skippedTooBig > 0) {
      buf.writeln('（跳过 $skippedTooBig 个文件：单文件超过 '
          '${_formatSize(ContractWorkspace.grepPerFileBytes)} 上限。）');
    }
    if (skippedBinary > 0) {
      buf.writeln('（跳过 $skippedBinary 个二进制文件。）');
    }
    return CapabilitySuccess(
      buf.toString().trimRight(),
      metadata: {
        'count': out.length,
        'truncated': truncated,
        'searchedFiles': searchedFiles,
      },
    );
  }
}

// ============================================================================
// glob → RegExp（支持 * / ** / ?，不引依赖）
// ============================================================================

/// **最小 glob 引擎**。
///
/// 支持三种通配（工具描述里承诺的就是这三种 + 字符集/多选，这里按需实现）：
///
/// | 写法 | 含义 |
/// |---|---|
/// | `*` | 匹配任意**不含 `/`** 的片段 |
/// | `**` | 匹配任意**含 `/`** 的片段（可为零层） |
/// | `?` | 匹配单个非 `/` 字符 |
/// | `[abc]` / `[a-z]` | 字符集（`[!abc]` / `[^abc]` 为取反） |
/// | `{a,b}` | 多选 |
///
/// ## 为什么要自己写
///
/// `package:glob` 不在依赖里，而**不许新增依赖**。手写 60 行比引一个包更符合
/// 项目约束（`AGENTS.md`：新增依赖属于 ADR 级决策）。
class _Glob {
  const _Glob._();

  static RegExp toRegExp(String pattern) {
    final buf = StringBuffer('^');
    var i = 0;
    while (i < pattern.length) {
      final c = pattern[i];
      switch (c) {
        case '*':
          final isDouble = i + 1 < pattern.length && pattern[i + 1] == '*';
          if (isDouble) {
            i += 2;
            // `**/` 表示"零层或多层目录" ⇒ 连斜杠一起可选
            if (i < pattern.length && pattern[i] == '/') {
              i++;
              buf.write('(?:.*/)?');
            } else {
              buf.write('.*');
            }
          } else {
            i++;
            buf.write('[^/]*');
          }
        case '?':
          i++;
          buf.write('[^/]');
        case '[':
          final close = pattern.indexOf(']', i + 1);
          if (close < 0) {
            // 未闭合：按字面量处理
            buf.write(r'\[');
            i++;
          } else {
            var body = pattern.substring(i + 1, close);
            if (body.startsWith('!')) body = '^${body.substring(1)}';
            buf.write('[$body]');
            i = close + 1;
          }
        case '{':
          final close = pattern.indexOf('}', i + 1);
          if (close < 0) {
            buf.write(r'\{');
            i++;
          } else {
            final body = pattern.substring(i + 1, close);
            final alts = body.split(',').map(RegExp.escape).join('|');
            buf.write('(?:$alts)');
            i = close + 1;
          }
        default:
          buf.write(RegExp.escape(c));
          i++;
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }
}

// ============================================================================
// unified diff 的内部结构
// ============================================================================

enum _PatchKind { context, remove, add }

class _PatchLine {
  const _PatchLine(this.kind, this.text);
  final _PatchKind kind;
  final String text;
}

class _Hunk {
  _Hunk({
    required this.oldStart,
    required this.oldCount,
    required this.newStart,
    required this.newCount,
  });

  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
  final List<_PatchLine> lines = [];
}

/// [_applyHunk] 的结果：**要么**给出打过补丁的新行列表，**要么**给出一条失败回告。
///
/// 为什么不是 `List<String>?`（成功给列表、失败给 null + 从别处读错误）：
/// 那会退化成"随手判空"，失败原因要另找一个出口（字段/异常），
/// 编译器也无法保证"失败时一定有原因"。sealed 类型让**两件事绑在一起且可穷尽检查**。
sealed class _HunkOutcome {
  const _HunkOutcome();
}

/// 这个 hunk 打上了 —— 带上打过补丁的完整行列表。
final class _HunkApplied extends _HunkOutcome {
  const _HunkApplied(this.lines);

  /// 应用该 hunk 之后的**全文件行列表**（不是增量、不是片段）。
  final List<String> lines;
}

/// 这个 hunk 没打上 —— 带上给模型看的那句人话（含 hunk 号 / 期望 / 实际）。
final class _HunkFailed extends _HunkOutcome {
  const _HunkFailed(this.failure);

  /// 原样交给工具层的 [CapabilityFailure]。
  final CapabilityFailure failure;
}
