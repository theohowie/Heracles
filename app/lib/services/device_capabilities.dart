import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:heracles_backend/heracles_backend.dart';

import 'global_memory.dart';

// ============================================================================
// 能力契约 —— 直接来自 `backend`（不再是镜像）
// ============================================================================
//
// ## 2026-10-22：A 路线已切换完成
//
// 本文件曾经包含一段"契约镜像段"（把 backend 的 6 个 abstract class 与
// `CapabilityResult` 三态逐字抄一份），理由当时是 `app/pubspec.yaml` 还没有
// `heracles_backend` 依赖，而 `backend/` 正在被别人大改，硬挂 path 依赖会让
// 两边的验收互相污染。
//
// 现在依赖已加（`heracles_backend: path: ../backend`），镜像段**已删除**，
// 换成一个 import —— 因为**两份声明同一契约**必然是两份真相：backend 加一个
// 方法，App 侧不会编译失败，而是在运行时被当成"能力没实现"。
//
// ## 因此本文件的纪律
//
// · 只 import，**不重新声明**任何 `Capabilities` / `*Capability` / `CapabilityResult`
// · 实现类上加 `implements`，方法签名由编译器对着 backend 检查 ——
//   将来 backend 改契约，这里会**编译失败**（这才是想要的信号）
// ============================================================================

// ============================================================================
// 常量 —— 用 backend 的 `Contract*`（不是本地镜像）
// ============================================================================
//
// ## 为什么不再镜像数字
//
// 曾经 `_Limits` 抄了一份数值（`lineNumberWidth = 5` 等），因为
// `backend/lib/heracles_backend.dart` 没有 export `contract.dart`。
// 现在那份 export 已补上 ⇒ **数字只有一处来源**。
//
// ⚠️ 只有两个例外是**本文件自己的**（不是 backend 的常量），它们有独立注释：
//   · `grepMaxFilesPerCall` —— 通道下 1 文件 = 1 次 IPC 的降级上限
//   · `exitNoShell`         —— Kotlin `DeviceShell.EXIT_NO_SHELL`

/// backend 常量 + 本文件自己的降级上限（每项都注明来源）。
abstract final class _Limits {
  const _Limits._();

  /// `ContractWorkspace.lineNumberWidth`（5）。
  /// `read` 的行号前缀宽度（`"   12| 内容"` 里的 5）。
  static const int lineNumberWidth = ContractWorkspace.lineNumberWidth;

  /// `ContractWorkspace.grepPerFileBytes`（1 MB）。
  static const int grepPerFileBytes = ContractWorkspace.grepPerFileBytes;

  /// `ContractTools.maxEntries`（200）。
  static const int defaultMaxEntries = ContractTools.maxEntries;

  /// `ContractTools.webMaxChars`（50000）。
  static const int webMaxChars = ContractTools.webMaxChars;

  /// `ContractWeb.maxResponseBytes`（5 MB）。
  static const int webMaxResponseBytes = ContractWeb.maxResponseBytes;

  /// `ContractWeb.timeoutSeconds`（30）。
  static const int webTimeoutSeconds = ContractWeb.timeoutSeconds;

  /// `ContractWorkspace.maxReadFileBytes`（5 MB）。
  ///
  /// ⚠️ **通道比它更紧**：`fs.readText` 只能读 1 MB
  /// （`DeviceFs.MAX_TEXT_BYTES = 1_000_000`），超了就 `truncated: true`。
  static const int maxReadFileBytes = ContractWorkspace.maxReadFileBytes;

  /// 来源：`DeviceFs.MAX_TEXT_BYTES`（**Kotlin 侧**常量，不在 backend 里）。
  ///
  /// 这是 `fs.readText` 的硬上限 —— **本文件所有"读全文再写回"的逻辑都必须
  /// 尊重它**，否则会拿半截文本覆盖整个文件（见 `session_store.dart` 的同款防线）。
  static const int channelTextBytes = 1000 * 1000;

  /// 来源：`DeviceFs.HARD_MAX_ENTRIES`（5000，**Kotlin 侧**常量）。
  static const int channelHardMaxEntries = 5000;

  /// **本文件自己的降级上限**（不是 backend 常量）。
  ///
  /// `grepFiles` 在通道下是 **1 个文件 = 1 次 IPC**（先 list 再逐个 readText），
  /// 而 backend 的 `ContractWorkspace.maxVisitedFiles = 20000` 是按 POSIX
  /// 顺序读文件定的。20000 次 IPC 在真机上不可接受 ⇒ 这里降到 500 个文件/次，
  /// 并**如实报截断**。
  ///
  /// ⚠️ 这是**未经真机实测**的经验值，不是测出来的最优值。
  static const int grepMaxFilesPerCall = 500;

  /// `exec.run` 里 Kotlin 的 `DeviceShell.EXIT_NO_SHELL`（-2）。
  ///
  /// 与"命令超时"（此时 code 也是负，但 `timedOut == true`）是**两件不同的事**。
  static const int exitNoShell = -2;
}

// ============================================================================
// 通道客户端
// ============================================================================

/// `heracles/device` 通道的**薄封装**：把三种"拿不到结果"收敛成同一个形状。
///
/// ## 为什么单独抽一个类
///
/// 每个能力类都要做同一件事：`invokeMethod` → 读 `ok` / 取 `error`。
/// 散开写的话，"通道没注册"这条兜底必然被漏掉一两处（然后那一路会往
/// agent 循环里抛 `MissingPluginException`）。收在一处，只有一份真相。
///
/// ## 三种失败（**都不是异常**）
///
/// | 情况 | 返回 |
/// |---|---|
/// | 通道没注册（纯 Dart 测试 / 引擎没起来） | `{ok:false, error:"…不可用…"}` |
/// | 通道抛了 `PlatformException`（违反契约，但得兜住） | `{ok:false, error:"…不该发生…"}` |
/// | 返回的不是 Map（Kotlin 侧写错了） | `{ok:false, error:"…返回形状不对…"}` |
class DeviceChannelClient {
  /// [channel] 可注入（测试里换 `MethodChannel('test')` + mock handler）。
  const DeviceChannelClient({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 通道名 —— **必须与 `DeviceChannel.CHANNEL` 逐字一致**。
  static const String channelName = 'heracles/device';

  final MethodChannel _channel;

  /// 调一次通道方法。**永不抛**（除了真正的编程错误，如测试里 handler 自己抛）。
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    Object? raw;
    try {
      raw = await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      return <String, Object?>{
        'ok': false,
        'error': '设备通道 `$channelName` 不可用（App 没有挂上原生实现，'
            '或当前跑在纯 Dart 环境里）。文件 / 命令 / 温度这类设备能力全部不可用。',
      };
    } on PlatformException catch (e) {
      // 契约规定通道不该抛 —— 但"不该"不是"不会"，兜住比让 agent 崩了好。
      return <String, Object?>{
        'ok': false,
        'error': '设备通道抛出异常（本不该发生，$kDeviceBridgeBugHint）：'
            '${e.code}${e.message == null ? "" : " ${e.message}"}',
      };
    } catch (e) {
      return <String, Object?>{
        'ok': false,
        'error': '调用设备通道 $method 时出错（$kDeviceBridgeBugHint）：$e',
      };
    }

    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, Object?>{
      'ok': false,
      'error': '设备通道 $method 返回了意料之外的形状（${raw.runtimeType}），'
          '预期是 Map。这是原生侧的 bug。',
    };
  }
}

/// 通道违反契约时的统一提示尾巴（便于 logcat / 用户报障时对上号）。
const String kDeviceBridgeBugHint = '请把这条报给开发者';

/// 从通道返回里取人话错误；`ok == true` 返回 `null`。
String? errorOf(Map<String, Object?> raw) {
  if (raw['ok'] == true) return null;
  final dynamic e = raw['error'];
  if (e is String && e.trim().isNotEmpty) return e;
  return '设备通道返回了失败，但没有给出原因（`ok:false` 且缺 `error` 字段）—— '
      '这是原生侧的 bug，$kDeviceBridgeBugHint。';
}

// ============================================================================
// 1. 工作区文件能力
// ============================================================================

/// **工作区能力 → `fs.*` 通道方法**。
///
/// ## 两条设计约束
///
/// 1. **不碰 `dart:io`**：SAF 工作区（用户选的 `/sdcard/xxx`）在 `dart:io`
///    下完全不可用（App 不在 `media_rw` 组，写必 `EPERM`，真机实测见
///    `docs/20`）。所以每一个文件操作都必须走 `fs.*`，由 Kotlin 决定
///    "这次该走 `java.io.File` 还是 `DocumentFile`"。
/// 2. **路径在这儿解析，不在 Kotlin 那儿**：`DeviceFs` 只认绝对 POSIX 路径，
///    相对路径一律 `null`（它明说"调用方给错了，如实拒绝"）。所以
///    [resolve] 是**唯一的安全闸**：绝对路径拒绝、`..` 逃逸拒绝。
///
/// ## SAF 的三个硬边界怎么处理
///
/// Kotlin 侧对"SAF 下删目录 / 重命名目录"是**明确拒绝**并写好人话的
/// （`DeviceFs.delete` / `rename` 的注释：`DocumentFile.delete()` 对目录是递归的、
/// `renameTo()` 对目录不可靠）。本实现的做法是**原样透传那句 `error`**：
/// 不重试、不降级成"逐个复制"、不假装成功。理由：模型看到
/// 「SAF 工作区不支持重命名目录」才知道该换策略；看到"成功"会以为改完了。
/// **在系统文件管理里打开文件夹**（UI 专用：抽屉工作区菜单点路径时用）。
///
/// 走宿主 `fs.openFolder`（DocumentsUI 直达 / 文档树选择器兜底）。
/// 成功返回 null；失败返回人话原因，由 UI 用 toast 如实提示 ——
/// Android 11+ 对 `Android/data` 有系统级浏览限制，系统拒绝时
/// **不假装打开了**。
class FolderOpener {
  const FolderOpener({DeviceChannelClient? channel})
      : _ch = channel ?? const DeviceChannelClient();

  final DeviceChannelClient _ch;

  Future<String?> open(String path) async {
    final raw = await _ch.call('fs.openFolder', <String, Object?>{'path': path});
    return errorOf(raw);
  }
}

class DeviceWorkspaceCapability implements WorkspaceCapability {
  /// [workspaceRoot] 必须是**绝对路径**，且是设备上真实存在的目录
  /// （通常来自 `picker.folder` 或内置的 `app-workspace`）。
  DeviceWorkspaceCapability({
    required String workspaceRoot,
    DeviceChannelClient? channel,
  })  : _root = _normalizeRoot(workspaceRoot),
        _ch = channel ?? const DeviceChannelClient();

  final String _root;
  final DeviceChannelClient _ch;

  /// 上一次 [resolve] 失败的原因（给 [CapabilityFailure] 用）。
  String? _lastError;

  /// 工作区根的绝对路径（不含尾部分隔符）。
  String get rootPath => _root;

  /// 去掉尾部分隔符；并**要求绝对路径**（相对 root 的语义在这里没有意义）。
  static String _normalizeRoot(String raw) {
    final t = raw.trim().replaceAll('\\', '/');
    if (t.isEmpty) {
      throw ArgumentError('workspaceRoot 不能为空');
    }
    if (!t.startsWith('/')) {
      throw ArgumentError(
        'workspaceRoot 必须是设备上的绝对路径（收到 `$raw`）。'
        'SAF 工作区请传 `picker.folder` 返回的 path。',
      );
    }
    final trimmed = t.replaceAll(RegExp('/{2,}'), '/');
    if (trimmed.length > 1 && trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  // ------------------------------------------------------------------ 路径

  /// 把后端给的**相对路径**解析成设备上的绝对路径；`null` = 拒绝（原因在 [_lastError]）。
  ///
  /// ## 为什么要拒绝绝对路径
  ///
  /// 与 `LocalWorkspaceCapability._resolve` 同一条理由：`path` 的契约是
  /// "相对工作区"。放行绝对路径等于放行 `/data/data/<其它 pkg>/…`。
  /// 这里挡的**不是"恶意模型"**，而是"一次手滑"——删错目录不可逆。
  ///
  /// ## 为什么不检查符号链接
  ///
  /// `DeviceFs` 侧有 `MAX_DEPTH` / 逐级 `findChild`，但**没有** realpath 校验
  /// （SAF 根本没有真实路径）。这是一条**已知边界**：`<root>` 下若有指向
  /// 外部的符号链接，POSIX 路由会跟着走。如实记在这里，不假装挡住了。
  String? resolve(String path) {
    _lastError = null;
    final raw = path.trim().replaceAll('\\', '/');
    if (raw.isEmpty) return _root;

    final looksAbsolute =
        raw.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
    if (looksAbsolute) {
      _lastError = '只接受相对工作区的路径，收到绝对路径 `$path`。'
          '请改成相对路径（例如 `src/main.dart`）。';
      return null;
    }

    final parts = <String>[];
    for (final seg in raw.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isEmpty) {
          _lastError = '路径 `$path` 越出了工作区根目录（`$_root`）。'
              '工作区以外的文件不可访问。';
          return null;
        }
        parts.removeLast();
        continue;
      }
      parts.add(seg);
    }
    if (parts.isEmpty) return _root;
    return '$_root/${parts.join('/')}';
  }

  CapabilityFailure _fail() =>
      CapabilityFailure(_lastError ?? '路径无法解析（未知原因）。');

  /// 绝对路径 → 相对工作区的展示形式（`''` → `.`）。
  String relativeOf(String absolute) {
    final a = absolute.replaceAll('\\', '/');
    if (a == _root) return '.';
    final prefix = _root == '/' ? '/' : '$_root/';
    if (a.startsWith(prefix)) {
      final rel = a.substring(prefix.length);
      return rel.isEmpty ? '.' : rel;
    }
    // 不在工作区内（例如 Kotlin 返回了别处的路径）：原样回告，不要编造相对路径
    return a;
  }

  // ------------------------------------------------------------------ list

  @override
  Future<CapabilityResult> list(
    String path, {
    bool recursive = false,
    int maxEntries = _Limits.defaultMaxEntries,
  }) async {
    final abs = resolve(path);
    if (abs == null) return _fail();

    final limit = maxEntries.clamp(1, _Limits.channelHardMaxEntries);
    final raw = await _ch.call('fs.list', <String, Object?>{
      'path': abs,
      'recursive': recursive,
      'maxEntries': limit,
    });
    final err = errorOf(raw);
    if (err != null) return CapabilityFailure(err);

    final entries = _entriesOf(raw);
    final truncated = raw['truncated'] == true;

    final buf = StringBuffer();
    final shown = path.trim().isEmpty ? '.' : path.trim();
    buf.writeln('工作区目录：`$shown`${recursive ? "（递归）" : ""}');
    if (entries.isEmpty) {
      buf.writeln('（空目录）');
    } else {
      for (final e in entries) {
        buf.writeln(_describeEntry(e));
      }
    }
    if (truncated) {
      buf.writeln();
      buf.writeln('⚠️ 已截断：最多返回 $limit 项（另有未列出的条目）。'
          '需要更精确的结果请用 find_files 按模式查找。');
    }
    return CapabilitySuccess(
      buf.toString().trimRight(),
      metadata: <String, dynamic>{
        'entries': entries.length,
        'truncated': truncated,
      },
    );
  }

  /// 解析 `entries` 列表（丢掉形状不对的元素，而不是整条失败）。
  List<_FsEntry> _entriesOf(Map<String, Object?> raw) {
    final dynamic list = raw['entries'];
    final out = <_FsEntry>[];
    if (list is List) {
      for (final dynamic item in list) {
        if (item is Map) {
          final name = item['name'];
          final p = item['path'];
          if (name is String && p is String) {
            out.add(_FsEntry(
              name: name,
              path: p,
              isDir: item['isDir'] == true,
              size: _asInt(item['size']) ?? 0,
            ));
          }
        }
      }
    }
    return out;
  }

  String _describeEntry(_FsEntry e) {
    final rel = relativeOf(e.path);
    if (e.isDir) return '[目录] $rel/';
    return '[文件] $rel (${_formatSize(e.size)})';
  }

  // ------------------------------------------------------------------ read

  @override
  Future<CapabilityResult> read(
    String path, {
    int offset = 1,
    int limit = 0,
  }) async {
    final abs = resolve(path);
    if (abs == null) return _fail();
    if (offset < 1) {
      return const CapabilityFailure(
        'offset 必须从 1 开始（行号是 1-based）。',
        isRetryable: true,
      );
    }

    // 先 stat 一次：让"文件大到超过上限"与"读的时候出错"给出**不同的**解释。
    //
    // 为什么值得多一次 IPC：模型拿到"文件太大（12 MB）"会改用 grep_files /
    // find_files；拿到"读取失败"只会在同一个文件上重试。旧版的
    // `MAX_READ_FILE_BYTES` 就是为这个判断存在的（见 docs/07 与
    // `Contract.Workspace.maxReadFileBytes`）。
    final stat = await _ch.call('fs.stat', <String, Object?>{'path': abs});
    final statErr = errorOf(stat);
    if (statErr != null) return CapabilityFailure(statErr);
    if (stat['exists'] != true) {
      return CapabilityFailure(
        '文件不存在：`${path.trim()}`。先用 list_files / find_files 确认路径。',
        isRetryable: true,
      );
    }
    if (stat['isDir'] == true) {
      return CapabilityFailure(
        '`${path.trim()}` 是目录，不是文件。列目录请用 list_files。',
      );
    }
    final size = _asInt(stat['size']) ?? 0;
    if (size > _Limits.maxReadFileBytes) {
      return CapabilityFailure(
        '文件太大（${_formatSize(size)}，上限 '
        '${_formatSize(_Limits.maxReadFileBytes)}）：`${path.trim()}`。'
        '请用 find_files / grep_files 定位，或换一个更小的文件。',
      );
    }

    final r = await _readText(abs, offsetLine: offset, maxLines: limit);
    if (r.error != null) return CapabilityFailure(r.error!);

    final shown = path.trim().isEmpty ? '.' : path.trim();
    // Kotlin 的 readText 把 text 切成行再 join，所以可能带尾部换行；
    // 这里的 `LineSplitter` 语义与 backend 的 read 一致（末日空行不算一行）。
    final lines = const LineSplitter().convert(r.text);
    if (lines.isEmpty) {
      return CapabilitySuccess(
        '（文件为空，或该区间没有内容）—— `$shown`\n'
        '⚠️ 通道不返回总行数，所以无法区分"文件是空的"与"起始行 $offset 超出了末尾"。'
        '要确认的话用 offset=1 从头读。',
        metadata: <String, dynamic>{'lines': 0, 'truncated': r.truncated},
      );
    }

    final buf = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      buf.writeln(_numbered(offset + i, lines[i]));
    }
    final lastLine = offset + lines.length - 1;
    if (r.truncated) {
      buf.writeln();
      buf.writeln(
        '（只显示了第 $offset–$lastLine 行；文件还有更多内容没有返回。'
        '继续读用 offset=${lastLine + 1}。）',
      );
    }
    if (size > _Limits.channelTextBytes) {
      // 通道的 1MB 文本上限与"文件太大"是两件事：这里说清是哪一道闸卡住的，
      // 否则模型会以为是自己的 offset/limit 写错了。
      buf.writeln();
      buf.writeln('（注：这个文件 ${_formatSize(size)}，超过设备通道 '
          '${_formatSize(_Limits.channelTextBytes)} 的文本读取上限 —— '
          '超过该上限的部分读不回来。更深的内容请用 grep_files 定位行号后用 offset 精确读。）');
    }
    return CapabilitySuccess(
      buf.toString().trimRight(),
      metadata: <String, dynamic>{
        'from': offset,
        'to': lastLine,
        'truncated': r.truncated,
      },
    );
  }

  /// 行号前缀：宽度 [_Limits.lineNumberWidth] 位、右对齐、后接 `| `。
  ///
  /// 与 backend `LocalWorkspaceCapability._numbered` **逐字符一致**
  /// （`"   12| 内容"`）。固定宽度是为了列对齐，也让 `edit` 的 oldText 更好对。
  String _numbered(int lineNo, String content) =>
      '${lineNo.toString().padLeft(_Limits.lineNumberWidth)}| $content';

  /// 读一段文本（内部用）。失败用 [_TextRead.error] 表达，**不抛**。
  Future<_TextRead> _readText(
    String abs, {
    int offsetLine = 1,
    int maxLines = 0,
  }) async {
    final raw = await _ch.call('fs.readText', <String, Object?>{
      'path': abs,
      'offsetLine': offsetLine,
      'maxLines': maxLines,
    });
    final err = errorOf(raw);
    if (err != null) return _TextRead.error(err);
    return _TextRead(
      text: (raw['text'] as String?) ?? '',
      truncated: raw['truncated'] == true,
    );
  }

  // ------------------------------------------------------------------ write

  @override
  Future<CapabilityResult> write(String path, String content) async {
    final abs = resolve(path);
    if (abs == null) return _fail();

    // 先 stat 一次只为把"新建 / 覆盖"如实说清（模型需要知道它改了什么）。
    final existed = await exists(path);
    final raw = await _ch.call('fs.writeText', <String, Object?>{
      'path': abs,
      'text': content,
    });
    final err = errorOf(raw);
    if (err != null) return CapabilityFailure(err);

    final bytes = utf8.encode(content).length;
    final shown = path.trim().isEmpty ? '.' : path.trim();
    return CapabilitySuccess(
      '${existed ? "已覆盖写入" : "已创建"} `$shown`（${_formatSize(bytes)}）。',
      metadata: <String, dynamic>{'bytes': bytes, 'created': !existed},
    );
  }

  // ------------------------------------------------------------------ edit

  @override
  Future<CapabilityResult> edit(String path, String oldText, String newText) async {
    final abs = resolve(path);
    if (abs == null) return _fail();
    if (oldText.isEmpty) {
      return const CapabilityFailure(
        '`old_string` 不能为空。要新建文件请用 write_file。',
        isRetryable: true,
      );
    }

    final r = await _readText(abs);
    if (r.error != null) return CapabilityFailure(r.error!);
    if (r.truncated) {
      // 截断时做文本替换会**改坏一个我们没看全的文件** ⇒ 必须拒绝，说清原因。
      return CapabilityFailure(
        '`${path.trim()}` 超过了通道的 1MB 文本上限，只读回了前面一部分。'
        '在没读全的情况下做替换可能把文件改坏，所以拒绝执行。'
        '请用 read_file 分段确认要改的位置，再用 write_file 整体重写，'
        '或先把文件拆小。',
      );
    }

    final original = r.text;
    final hits = _countOccurrences(original, oldText);
    if (hits == 0) {
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
    final w = await _ch.call('fs.writeText', <String, Object?>{
      'path': abs,
      'text': updated,
    });
    final werr = errorOf(w);
    if (werr != null) return CapabilityFailure(werr);

    return CapabilitySuccess(
      '已修改 `$path`（1 处替换，${_lineDelta(original, updated)}）。',
      metadata: <String, dynamic>{
        'replacements': 1,
        'bytesBefore': utf8.encode(original).length,
        'bytesAfter': utf8.encode(updated).length,
      },
    );
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

  /// 0 命中时给一句"最接近的实际内容"（只在唯一最长公共前缀够长时才给）。
  ///
  /// 给一个毫不相干的句子纯属误导 ⇒ 门槛是"至少一半相同且 ≥ 3 字符"。
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
    if (bestScore < (target.length / 2).ceil() || bestScore < 3) return null;
    final b = best!;
    return b.length > 120 ? '${b.substring(0, 120)}…' : b;
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

  // ------------------------------------------------------------ applyPatch

  /// 应用 unified diff。
  ///
  /// ## 为什么这里有一份解析器（而不复用 backend 的）
  ///
  /// backend 的 `LocalWorkspaceCapability.applyPatch` 与它的 `_Hunk` /
  /// `_PatchLine` / `_Glob` **都是私有的**（下划线开头），跨包引用不到。
  /// 任务给的退路是「读文件全文 → 本地应用 → `fs.writeText` 写回」，
  /// 本实现照此做，**并逐条对齐 backend 的判定与报错口径**：
  ///
  /// - 同一套支持形状（`@@ -a,b +c,d @@` + 上下文/`-`/`+` 行）；
  /// - **先按 header 声称的位置试，不中再全文件搜**（模型给的 `-a,b` 经常偏）；
  /// - 匹配不上时**必须**说清「第几个 hunk / 期望什么 / 实际是什么」——
  ///   猜错的补丁比不打更危险（它会静默改坏代码），所以**绝不猜**。
  ///
  /// ⚠️ 这是一份**复制**：backend 改了这里不会跟着变。等 A 路线（app 依赖
  /// backend）之后，应改成 `DelegatingWorkspaceCapability` 包装一个
  /// `LocalWorkspaceCapability` 只为借它的 patch 实现 —— 已向 Lead 报告。
  @override
  Future<CapabilityResult> applyPatch(String path, String patch) async {
    final abs = resolve(path);
    if (abs == null) return _fail();

    final r = await _readText(abs);
    if (r.error != null) return CapabilityFailure(r.error!);
    if (r.truncated) {
      return CapabilityFailure(
        '`${path.trim()}` 超过了通道的 1MB 文本上限，补丁只能在读全的文件上打。'
        '已拒绝（把半个文件打上补丁会静默改坏代码）。',
      );
    }

    final hunks = _parseHunks(patch);
    if (hunks.isEmpty) {
      return const CapabilityFailure(
        '补丁里没有找到任何 `@@ -a,b +c,d @@` 头。'
        'apply_patch 只接受 unified diff 格式；单处小改直接用 edit 更省事。',
        isRetryable: true,
      );
    }

    final original = r.text;
    var lines = const LineSplitter().convert(original);
    // 从后往前打：前面的 hunk 改动不会把后面的行号顶偏
    for (var i = hunks.length - 1; i >= 0; i--) {
      final applied = _applyHunk(lines, hunks[i], i + 1, path.trim());
      if (applied.error != null) return CapabilityFailure(applied.error!);
      lines = applied.lines!;
    }

    final updated = lines.join('\n');
    final w = await _ch.call('fs.writeText', <String, Object?>{
      'path': abs,
      'text': updated,
    });
    final werr = errorOf(w);
    if (werr != null) return CapabilityFailure(werr);

    return CapabilitySuccess(
      '已应用 ${hunks.length} 个 hunk 到 `$path`（${_lineDelta(original, updated)}）。',
      metadata: <String, dynamic>{'hunks': hunks.length},
    );
  }

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
      // 文件头不进 hunk 体
      if (raw.startsWith('--- ') || raw.startsWith('+++ ')) continue;
      if (raw.startsWith('diff ') || raw.startsWith('index ')) continue;
      if (raw.isEmpty) {
        // 空行按"上下文是一行空行"处理 —— 比丢掉它更容易对上
        current.lines.add(const _PatchLine(_PatchKind.context, ''));
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
  static final RegExp _hunkHeader =
      RegExp(r'^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@');

  _HunkOutcome _applyHunk(List<String> lines, _Hunk hunk, int hunkNo, String path) {
    final expected = <String>[
      for (final l in hunk.lines)
        if (l.kind != _PatchKind.add) l.text,
    ];
    final replacement = <String>[
      for (final l in hunk.lines)
        if (l.kind != _PatchKind.remove) l.text,
    ];

    final claimed = hunk.oldStart - 1;
    var at = _matchAt(lines, expected, claimed);
    if (at < 0) at = _matchAt(lines, expected, 0);
    if (at < 0) {
      final actualAt = claimed.clamp(0, lines.isEmpty ? 0 : lines.length - 1);
      final slice = <String>[];
      for (var i = actualAt; i < lines.length && slice.length < expected.length; i++) {
        slice.add(lines[i]);
      }
      return _HunkOutcome.error(
        '补丁第 $hunkNo 个 hunk 匹配不上（`$path`）。\n'
        '它声称从第 ${hunk.oldStart} 行开始，期望读到 ${expected.length} 行：\n'
        '${_preview(expected)}\n'
        '但文件第 ${actualAt + 1} 行附近实际是：\n'
        '${_preview(slice)}\n'
        '请先 read_file 看清当前内容，再按实际内容重写补丁。'
        '（不会"尽力猜"——猜错会静默改坏代码。）',
      );
    }

    final result = <String>[];
    result.addAll(lines.sublist(0, at));
    result.addAll(replacement);
    result.addAll(lines.sublist(at + expected.length));
    return _HunkOutcome.ok(result);
  }

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

  // -------------------------------------------------------- mkdir / exists

  @override
  Future<CapabilityResult> mkdir(String path) async {
    final abs = resolve(path);
    if (abs == null) return _fail();

    final existed = await exists(path);
    final raw = await _ch.call('fs.mkdir', <String, Object?>{'path': abs});
    final err = errorOf(raw);
    if (err != null) return CapabilityFailure(err);
    return CapabilitySuccess(
      existed ? '目录已存在：`${path.trim()}`' : '已创建目录 `${path.trim()}`',
    );
  }

  @override
  Future<bool> exists(String path) async {
    final abs = resolve(path);
    if (abs == null) return false;
    final raw = await _ch.call('fs.stat', <String, Object?>{'path': abs});
    if (errorOf(raw) != null) return false;
    return raw['exists'] == true;
  }

  // ------------------------------------------------------------- delete

  @override
  Future<CapabilityResult> delete(String path, {bool recursive = false}) async {
    final abs = resolve(path);
    if (abs == null) return _fail();
    if (abs == _root) {
      // 与 backend 一致：拒绝删工作区根本身（删除不可恢复）
      return const CapabilityFailure(
        '拒绝删除工作区根目录本身。要清理内容请指定具体的子目录或文件。',
      );
    }

    final raw = await _ch.call('fs.delete', <String, Object?>{
      'path': abs,
      'recursive': recursive,
    });
    // ★ SAF 边界：递归删目录 / 非 recursive 删目录，Kotlin 侧会**明确拒绝**
    //   并写好人话（"一个文件都没有删除"之类）。这里**原样透传**，
    //   绝不重试、绝不当成功。
    final err = errorOf(raw);
    if (err != null) return CapabilityFailure(err);
    if (raw['existed'] == false) {
      return CapabilityFailure('路径不存在：`${path.trim()}`（没有可删除的东西）。');
    }
    return CapabilitySuccess(
      '已删除 `${path.trim()}`${recursive ? "（递归）" : ""}。',
    );
  }

  // --------------------------------------------------------- move / copy

  @override
  Future<CapabilityResult> move(String from, String to) async {
    final fromAbs = resolve(from);
    if (fromAbs == null) return _fail();
    final toAbs = resolve(to);
    if (toAbs == null) return _fail();

    final raw = await _ch.call('fs.rename', <String, Object?>{
      'from': fromAbs,
      'to': toAbs,
    });
    // ★ SAF 边界：`DocumentFile.renameTo()` 对目录不可靠 ⇒ Kotlin 明确拒绝。
    //   透传那句解释（它会告诉模型"可以改为逐个复制再删旧目录"）。
    final err = errorOf(raw);
    if (err != null) return CapabilityFailure(err);

    final note = raw['note'];
    final extra = (note is String && note.trim().isNotEmpty) ? '（注意：$note）' : '';
    return CapabilitySuccess('已移动 `${from.trim()}` → `${to.trim()}`。$extra');
  }

  @override
  Future<CapabilityResult> copy(String from, String to) async {
    final fromAbs = resolve(from);
    if (fromAbs == null) return _fail();
    final toAbs = resolve(to);
    if (toAbs == null) return _fail();

    final raw = await _ch.call('fs.copy', <String, Object?>{
      'from': fromAbs,
      'to': toAbs,
    });
    final err = errorOf(raw);
    if (err != null) return CapabilityFailure(err);
    return CapabilitySuccess('已复制 `${from.trim()}` → `${to.trim()}`。');
  }

  // ------------------------------------------------------------ findFiles

  @override
  Future<CapabilityResult> findFiles(
    String pattern, {
    int maxResults = _Limits.defaultMaxEntries,
  }) async {
    if (pattern.trim().isEmpty) {
      return const CapabilityFailure(
        '`pattern` 不能为空。例：`**/*.dart`。',
        isRetryable: true,
      );
    }
    final matcher = _Glob.toRegExp(pattern.replaceAll('\\', '/'));

    // 一次 list 拉全树（递归 + 硬上限），再在 Dart 侧过滤。
    // 为什么不分页：通道没有分页能力，而且过滤要在完整条目集上做才有意义。
    final listed = await _ch.call('fs.list', <String, Object?>{
      'path': _root,
      'recursive': true,
      'maxEntries': _Limits.channelHardMaxEntries,
    });
    final lerr = errorOf(listed);
    if (lerr != null) return CapabilityFailure(lerr);

    final entries = _entriesOf(listed);
    final treeTruncated = listed['truncated'] == true;

    final hits = <String>[];
    var truncated = treeTruncated;
    for (final e in entries) {
      if (e.isDir) continue;
      final rel = relativeOf(e.path);
      if (!matcher.hasMatch(rel)) continue;
      if (hits.length >= maxResults) {
        truncated = true;
        break;
      }
      hits.add(rel);
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
    if (treeTruncated) {
      buf.writeln();
      buf.writeln('⚠️ 结果被截断，可能还有更多：目录条目超过通道上限 '
          '${_Limits.channelHardMaxEntries} 项，工作区比这更大。');
    } else if (truncated) {
      buf.writeln();
      buf.writeln('⚠️ 结果被截断，可能还有更多：最多返回 $maxResults 个文件。'
          '请用更精确的模式缩小范围。');
    }
    return CapabilitySuccess(
      buf.toString().trimRight(),
      metadata: <String, dynamic>{
        'count': hits.length,
        'truncated': truncated,
        'visited': entries.where((e) => !e.isDir).length,
      },
    );
  }

  // ----------------------------------------------------------- grepFiles

  /// 按正则搜内容。
  ///
  /// ## ⚠️ 这是**降级实现**（与 backend 的 POSIX 版成本模型不同）
  ///
  /// 通道下每读一个文件就是**一次 IPC**（`fs.readText`），没有"批量读"。
  /// backend 的 `maxVisitedFiles = 20000` 是按顺序读本地文件定的；
  /// 20000 次 IPC 在真机上不可接受 ⇒ 这里限制每次最多扫
  /// [_Limits.grepMaxFilesPerCall]（500）个文件，并**在结果里如实报截断**。
  ///
  /// 诚实边界：
  /// - 单文件超过通道 1 MB 文本上限 ⇒ 跳过并计数（`skippedTooBig`）；
  /// - 二进制文件**无法识别**：`fs.stat` 不给 MIME，`fs.readText` 直接按 UTF-8
  ///   解（Kotlin 侧 `allowMalformed` 语义），所以这里**不做**二进制跳过，
  ///   只在结果里不声称"扫过所有文本"。这是已知缺口，已报告。
  @override
  Future<CapabilityResult> grepFiles(
    String pattern, {
    String pathFilter = '',
    int maxResults = _Limits.defaultMaxEntries,
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
        : _Glob.toRegExp(pathFilter.trim().replaceAll('\\', '/'));

    final listed = await _ch.call('fs.list', <String, Object?>{
      'path': _root,
      'recursive': true,
      'maxEntries': _Limits.channelHardMaxEntries,
    });
    final lerr = errorOf(listed);
    if (lerr != null) return CapabilityFailure(lerr);

    final entries = _entriesOf(listed);
    final treeTruncated = listed['truncated'] == true;

    final out = <String>[];
    var truncated = treeTruncated;
    var visitedFiles = 0;
    var searchedFiles = 0;
    var skippedTooBig = 0;

    for (final e in entries) {
      if (e.isDir) continue;
      visitedFiles++;
      if (visitedFiles > _Limits.grepMaxFilesPerCall) {
        truncated = true;
        break;
      }
      final rel = relativeOf(e.path);
      if (filter != null && !filter.hasMatch(rel)) continue;

      // 通道上限 1 MB：先按 stat 跳过明显过大的文件（省一次读）
      if (e.size > _Limits.grepPerFileBytes) {
        skippedTooBig++;
        continue;
      }

      final r = await _readText(e.path);
      if (r.error != null) continue; // 单文件读失败不致命，继续扫其它的
      if (r.truncated) {
        // 超 1MB：只读到了前 1MB ⇒ 搜它等于"搜了一半还说没有"，宁可跳过。
        skippedTooBig++;
        continue;
      }
      searchedFiles++;

      final lines = const LineSplitter().convert(r.text);
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
      if (out.length >= maxResults) {
        truncated = true;
        break;
      }
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
    if (treeTruncated) {
      buf.writeln();
      buf.writeln('⚠️ 结果被截断，可能还有更多：目录条目超过通道上限 '
          '${_Limits.channelHardMaxEntries} 项。');
    } else if (truncated) {
      buf.writeln();
      buf.writeln('⚠️ 结果被截断，可能还有更多：'
          '本次最多扫 ${_Limits.grepMaxFilesPerCall} 个文件 / 返回 $maxResults 条匹配。'
          '请用更精确的正则或 path_filter 缩小范围。');
    }
    if (skippedTooBig > 0) {
      buf.writeln('（跳过 $skippedTooBig 个文件：超过通道 1MB 文本上限，'
          '读不全所以不做内容判断。）');
    }
    return CapabilitySuccess(
      buf.toString().trimRight(),
      metadata: <String, dynamic>{
        'count': out.length,
        'truncated': truncated,
        'searchedFiles': searchedFiles,
        'skippedTooBig': skippedTooBig,
      },
    );
  }
}

/// `fs.list` 的一个条目（`{name, path, isDir, size, mtimeMs}`）。
class _FsEntry {
  const _FsEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
}

/// `fs.readText` 的内部结果（**不抛**，用 [error] 表达失败）。
class _TextRead {
  const _TextRead({required this.text, required this.truncated})
      : error = null;

  const _TextRead.error(String reason)
      : text = '',
        truncated = false,
        error = reason;

  final String text;
  final bool truncated;
  final String? error;
}

/// `_applyHunk` 的结果：要么是新行列表，要么是一句人话。
class _HunkOutcome {
  const _HunkOutcome.ok(List<String> this.lines) : error = null;
  const _HunkOutcome.error(String this.error) : lines = null;

  final List<String>? lines;
  final String? error;
}

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
  final List<_PatchLine> lines = <_PatchLine>[];
}

/// **最小 glob 引擎**（与 backend `_Glob` 的语义逐条对齐）。
///
/// | 写法 | 含义 |
/// |---|---|
/// | `*` | 匹配任意**不含 `/`** 的片段 |
/// | `**` | 匹配任意**含 `/`** 的片段（可为零层） |
/// | `?` | 匹配单个非 `/` 字符 |
/// | `[abc]` / `[a-z]` / `[!abc]` | 字符集（`!`/`^` 取反） |
/// | `{a,b}` | 多选 |
///
/// 为什么自己写而不引 `package:glob`：与 backend 的理由一样 —— 不新增依赖
/// （`AGENTS.md`：新增依赖属 ADR 级决策），60 行比一个包更符合约束。
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
// 2. 命令执行能力
// ============================================================================

/// **Shell 能力 → `exec.run`**。
///
/// ## 三种"失败"必须**分开报**（这是本类最重要的设计）
///
/// Kotlin 侧 `DeviceShell.run` 的返回里，`ok` 是**派生值**
/// （`ok == (code == 0 && !timedOut)`）。如果只看 `ok`，下列三种情况会糊成
/// 同一句"命令失败"，而它们**要用户做的事完全不同**：
///
/// | 场景 | 判据 | 用户该做什么 | 本实现的翻译 |
/// |---|---|---|---|
/// | 超时 | `timedOut == true` | 等设备凉下来 / 加 `timeout_seconds` | 失败，`isRetryable: true` |
/// | 没有可用 shell 路由 | `code == -2`（`EXIT_NO_SHELL`） | 去开 Shizuku / Stellar | 失败，`isRetryable: false` |
/// | 命令自己返回非 0 | 其它非 0 的 `code` | 看命令本身 / 看 stderr | 失败，`isRetryable: true` |
///
/// ⚠️ 与 backend `ProcessShellCapability` 的**有意差异**：那边对非 0 退出码返回
/// `CapabilitySuccess` + 正文里写"（命令退出码：N）"。这里按任务要求
/// （"非 0 退出码要如实报出来，不要当成功"）翻成 `CapabilityFailure`
/// —— **输出正文一字不少地带上**，模型照样读得到 stderr 与退出码，
/// 只是工具结果不再伪装成成功。这条差异已报告给 Lead。
///
/// ## 流式输出的现实
///
/// backend 的 `ShellCapability.run` 注释要求"实现必须流式转发输出"。
/// **通道做不到**：`exec.run` 是一次性 RPC，整条命令跑完才回结果
/// （`DeviceShell` 用 `CountDownLatch` 等 `waitFor`，中途不回任何东西）。
/// 所以 [onOutput] 只在结束时被调**一次**，拿到的是最终拼接文本。
/// 真流式需要 Kotlin 侧加事件通道 —— 已报告，本轮不扩 Kotlin。
class DeviceShellCapability implements ShellCapability {
  /// [workspaceRoot] 会作为命令的 `cwd`（通道侧会拼成 `cd '<cwd>' && cmd`）。
  ///
  /// 为什么必须显式给：远程进程（Stellar / Shizuku）**没有**"工作目录"参数，
  /// Kotlin 只能把 `cd` 拼进命令串。不给 cwd 的话命令会跑在 `/`
  /// （`实测-03` 坑 27 在 CLI 侧踩过同款）。
  DeviceShellCapability({
    required String workspaceRoot,
    DeviceChannelClient? channel,
  })  : _cwd = workspaceRoot.trim(),
        _ch = channel ?? const DeviceChannelClient();

  final String _cwd;
  final DeviceChannelClient _ch;

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  }) async {
    if (command.trim().isEmpty) {
      return const CapabilityFailure('命令为空。', isRetryable: true);
    }

    final raw = await _ch.call('exec.run', <String, Object?>{
      'cmd': command,
      'cwd': _cwd,
      'timeoutMs': timeout.inMilliseconds,
    });

    // ★★ `exec.run` 的 `ok` 是**派生值**（`ok = code == 0 && !timedOut`），
    // 不是"通道调用是否成功" —— 见 `DeviceShell.result()`。
    //
    // 所以这里**不能**用 `errorOf(raw)` 一刀切：命令返回非 0、以及超时，
    // 都会带 `ok:false`（有的还带 `error`），但那些都是**命令的结果**，
    // 不是"通道挂了"。一刀切会把 stdout/stderr/exitCode 全丢掉，
    // 只剩一句没有信息量的"失败了"。
    //
    // 真正的"通道挂了"只有一种形状：**连 `code` 字段都没有**
    // （上面 `_ch.call` 的三种兜底返回 `{ok:false, error}`）。
    final codeRaw = raw['code'];
    if (codeRaw == null) {
      final err = errorOf(raw);
      if (err != null) return CapabilityFailure(err);
      return const CapabilityFailure(
        '设备通道的 exec.run 没有返回退出码（code 字段缺失）—— '
        '这个响应形状不对，属原生侧 bug，请把这条报给开发者。',
      );
    }

    final code = _asInt(codeRaw) ?? -1;
    final timedOut = raw['timedOut'] == true;
    final stdout = (raw['stdout'] as String?) ?? '';
    final stderr = (raw['stderr'] as String?) ?? '';
    final truncated = raw['truncated'] == true;
    final truncatedNote = raw['truncatedNote'];
    final durationMs = _asInt(raw['durationMs']);
    // 通道在超时的时候会额外给一个 error（"命令超时（…ms），已终止该子进程"）
    final channelError = raw['error'];

    final text = _composeText(
      stdout: stdout,
      stderr: stderr,
      code: code,
      timedOut: timedOut,
      truncated: truncated,
      truncatedNote: truncatedNote is String ? truncatedNote : null,
      durationMs: durationMs,
      channelError: channelError is String ? channelError : null,
    );

    onOutput?.call(text);

    final meta = <String, dynamic>{
      'exitCode': code,
      'timedOut': timedOut,
      'truncated': truncated,
      'durationMs': durationMs,
    };

    // ---- ① 超时 ----
    if (timedOut) {
      return CapabilityFailure(
        '${text.trimRight()}\n\n'
        '⚠️ 命令超时（${timeout.inSeconds} 秒），已终止**本命令自己启动的那个子进程**。'
        '设备上其它应用一个都没有被动过（产品硬约束）。\n'
        '下一步：确认设备温度是否过高（温度熔断是设计行为），'
        '或把 timeout_seconds 调大后重试；长输出建议改成写文件再用 read_file 分段读。',
        isRetryable: true,
      );
    }

    // ---- ② 没有可用的 shell 路由（code == -2）----
    if (code == _Limits.exitNoShell) {
      return CapabilityFailure(
        '${text.trimRight()}\n\n'
        '⚠️ 设备上没有可用的 shell 通道（EXIT_NO_SHELL = ${_Limits.exitNoShell}），'
        '命令**根本没有执行**。\n'
        '这不是命令写错了，也不是超时：需要先在 App 里启动 Stellar 或 Shizuku 服务'
        '（设备权限页可以看状态），然后重试。',
        isRetryable: false,
      );
    }

    // ---- ③ 命令自己返回非 0 ----
    if (code != 0) {
      return CapabilityFailure(
        '${text.trimRight()}\n\n'
        '（命令退出码：$code —— 命令执行了，但没有成功返回。）',
        isRetryable: true,
      );
    }

    // ---- ④ 成功 ----
    return CapabilitySuccess(text.trimRight(), metadata: meta);
  }

  /// 拼给模型看的正文（stdout + [stderr] + 退出码 + 截断提示）。
  ///
  /// 与 backend `ProcessShellCapability.run` 的正文口径一致，额外多写了
  /// `durationMs`（排障时"这条命令花了多久"很有用，尤其是温度熔断前后）。
  String _composeText({
    required String stdout,
    required String stderr,
    required int code,
    required bool timedOut,
    required bool truncated,
    required String? truncatedNote,
    required int? durationMs,
    required String? channelError,
  }) {
    final buf = StringBuffer();
    if (stdout.isNotEmpty) buf.write(stdout);
    if (stderr.isNotEmpty) {
      if (buf.isNotEmpty) buf.writeln();
      buf.writeln('[stderr]');
      buf.write(stderr);
    }
    if (buf.isEmpty) {
      buf.write(timedOut ? '（超时，无输出）' : '（无输出）');
    }
    if (channelError != null && channelError.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln('（通道说明：${channelError.trim()}）');
    }
    if (truncated) {
      buf.writeln();
      buf.writeln('⚠️ 输出已截断：stdout / stderr 各自上限 1MB。'
          '${truncatedNote?.trim().isNotEmpty == true ? truncatedNote!.trim() : ""}'
          '需要看完整输出请把命令改成输出到文件，再用 read_file 分段读。');
    }
    if (durationMs != null && durationMs >= 0) {
      buf.writeln();
      buf.writeln('（耗时 ${durationMs}ms）');
    }
    return buf.toString();
  }
}

// ============================================================================
// 3. 设备健康读数
// ============================================================================

/// 一次 `health.read` 的快照。
///
/// **三个字段都可能为 `null`**：Kotlin 侧明确"读不到就 null，不填编造值"
/// （`DeviceHealth.kt`：这是安全熔断的输入，假"健康"会在发烫时放行，
/// 假"发烫"会无故阻断构建）。[error] 非 null 表示"整个读取流程失败"，
/// 与"问到了但没有值"是两件事。
class HealthSnapshot {
  const HealthSnapshot({
    this.batteryPercent,
    this.temperatureCelsius,
    this.charging,
    this.error,
  });

  const HealthSnapshot.error(String reason)
      : batteryPercent = null,
        temperatureCelsius = null,
        charging = null,
        error = reason;

  final int? batteryPercent;
  final double? temperatureCelsius;

  /// `null` = 读不到（Kotlin 侧 UNKNOWN 状态），**不是"没在充电"**。
  final bool? charging;

  final String? error;
}

/// **健康能力 → `health.read`**。
///
/// ## 为什么类名不叫 `DeviceHealthCapability`
///
/// 那个名字被 backend 的**抽象接口**占了（同一份契约镜像段里）。若实现类
/// 取同名就没法 `implements`。所以实现叫 `ChannelHealthCapability`
/// —— 名字里点明"走的是 MethodChannel"。
///
/// ## 三个 getter 各是一次 IPC
///
/// `health.read` 一次就给全三个字段，但接口把三者拆成三个方法。
/// 想省 IPC 就别逐个调，用 [snapshot] 一次拿全（Lead 接熔断时应该用这个）。
///
/// ## ⚠️ 接口设计缺陷（如实记下，本轮不改签名）
///
/// `DeviceHealthCapability.isCharging()` 返回**非空 `bool`**，而通道的
/// `charging` 可能是 `null`（系统 UNKNOWN）。非空签名迫使实现**猜一个值**，
/// **建议改成 `Future<bool?>`**。本轮按任务要求返回 `false`（保守默认，
/// 不会因为"读不到"而误判成"正在充电"从而放行长任务），并在
/// [isCharging] 的 KDoc 里说清这一点。
class ChannelHealthCapability implements DeviceHealthCapability {
  const ChannelHealthCapability({DeviceChannelClient? channel})
      : _ch = channel ?? const DeviceChannelClient();

  final DeviceChannelClient _ch;

  /// 读一次完整快照（一次 IPC 拿全三个字段）。
  Future<HealthSnapshot> snapshot() async {
    final raw = await _ch.call('health.read');
    final err = errorOf(raw);
    if (err != null) return HealthSnapshot.error(err);

    final battery = _asInt(raw['battery']);
    final tempRaw = raw['tempC'];
    final temp = tempRaw is num ? tempRaw.toDouble() : null;
    final charging = raw['charging'];

    return HealthSnapshot(
      // 越界的电量当成"读不到"（Kotlin 已经过滤过 0..100，这里双保险）
      batteryPercent: (battery != null && battery >= 0 && battery <= 100)
          ? battery
          : null,
      temperatureCelsius: temp,
      charging: charging is bool ? charging : null,
    );
  }

  @override
  Future<int?> batteryPercent() async => (await snapshot()).batteryPercent;

  @override
  Future<double?> temperatureCelsius() async =>
      (await snapshot()).temperatureCelsius;

  /// 是否正在充电。
  ///
  /// ⚠️ **`false` 有两种含义**：真的没在充电，**或者**读不到（通道
  /// `charging == null`，系统 UNKNOWN）。接口签名是非空 `bool`，无法区分
  /// —— 这是 [DeviceHealthCapability.isCharging] 的签名缺陷，**建议改成
  /// `Future<bool?>`**（本轮不改接口）。保守默认取 `false`：
  /// "读不到"不应被当成"正在充电"而放行长任务。
  ///
  /// 需要区分时用 [snapshot]：那里 `charging == null` 就是"读不到"。
  @override
  Future<bool> isCharging() async => (await snapshot()).charging ?? false;
}

// ============================================================================
// 4. APK 构建 / 逆向 —— **本轮明确"未实现"**
// ============================================================================

/// **APK 能力：本轮只有"明确的未实现"**。
///
/// ## 为什么不做（也为什么**不是**"偷懒"）
///
/// 旧的构建引擎（`aapt2` → `javac` → `d8` → 插 dex → 对齐 → 签名）随
/// `:toolchain` Kotlin 模块一起删除了（后端改 Dart 重写，见 `ADR-035` /
/// `docs/nextwork.md`）。今天设备上**没有任何一处代码**能构建 APK：
///
/// - Kotlin 侧 `DeviceChannel` 里**没有** `apk.*` 方法（只有 `buildNotify.*`
///   通知栏开关，那是"通知"不是"构建"）；
/// - `exec.run` 能跑命令，但拿它拼一套"aapt2 …"就是**假构建**：
///   缺前缀树注入（`LD_LIBRARY_PATH` / `-Djava.io.tmpdir`）、缺进程内对齐
///   （`ZipAligner`，Android 上没有 `zipalign` 二进制）、缺温度熔断接线。
///   拼出来的东西**看起来能跑**，实际会产出一个装不上的包 —— 那是**编造证据**，
///   比"如实说没有"糟得多。
///
/// ## 所以这里的 5 个方法全部返回"未实现"
///
/// 为什么全部 `isRetryable: false`：模型换个参数重试是**没有意义的**
/// （不是参数问题，是这条路根本不存在）。让它重试只会浪费轮次与预算。
///
/// ## 接线时长什么样
///
/// 真要做，正确顺序是：① Kotlin 侧加 `apk.build` / `apk.decompile` /
/// `apk.recompile` / `apk.sign` / `apk.install` 五个方法（复用已真机验证过的
/// `AndroidBuildEngine` / `ApkReverseEngine` 逻辑）→ ② 本类改成转发
/// → ③ 这里的方法体换成 `_ch.call('apk.build', …)`。
/// **接口签名已经对上，接线时不需要改这 5 个方法以外的任何东西。**
class DeviceApkCapability implements ApkCapability {
  const DeviceApkCapability();

  /// 统一的原因文本。
  ///
  /// 文里点名"旧 Kotlin 引擎已随 `:toolchain` 模块删除"：模型读到这句就知道
  /// **不是它自己参数写错了**，也就不会陷入"换个写法再试一次"的循环。
  static const String _notImplementedReason =
      'APK 构建/逆向能力在 Dart 后端尚未接线（旧 Kotlin 引擎已随 :toolchain 模块删除）。'
      '见 docs/nextwork.md。';

  static const CapabilityFailure _notImplemented = CapabilityFailure(
    _notImplementedReason,
    isRetryable: false,
  );

  /// 未实现。**不要**用 `exec.run` 假装能构建（见类注释）。
  @override
  Future<CapabilityResult> build({
    required String projectDir,
    void Function(String step)? onStep,
  }) async {
    onStep?.call('APK 构建：未接线');
    return _notImplemented;
  }

  @override
  Future<CapabilityResult> decompile(String apkPath, String outDir) async =>
      _notImplemented;

  @override
  Future<CapabilityResult> recompile({
    required String smaliDir,
    required String outApkPath,
    void Function(String step)? onStep,
  }) async {
    onStep?.call('APK 重打包：未接线');
    return _notImplemented;
  }

  @override
  Future<CapabilityResult> sign(String apkPath) async => _notImplemented;

  @override
  Future<CapabilityResult> install(String apkPath) async => _notImplemented;
}

// ============================================================================
// 5. 网络抓取（含 SSRF 防护）
// ============================================================================

/// **Web 抓取 + 真实 SSRF 防护**。
///
/// ## 为什么这层必须自己挡 SSRF（不能靠提示词、不能靠工具参数校验）
///
/// 威胁模型：模型读到网页内容（**不可信输入**），被其中的指令诱导去请求
/// `http://127.0.0.1:8080/…` 或 `http://169.254.169.254/latest/meta-data/`。
/// 工具参数校验挡不住它 —— 那个 URL 在语法上完全合法。**只有在发起请求的
/// 那一层**把目标地址判掉才成立，这也是 backend `WebCapability` 注释的原话。
///
/// ## 挡什么（[checkUrl] 的实现口径）
///
/// 1. **scheme** 只允许 `http` / `https`（挡 `file:` `content:` `ftp:` 等）；
/// 2. **host 字面量**：`localhost` / `*.localhost` / `*.local` 直接拒；
/// 3. **IP 字面量**：回环（`127/8`、`::1`）、私有段（`10/8`、`172.16/12`、
///    `192.168/16`）、链路本地与云元数据（`169.254/16`，含
///    `169.254.169.254`）、CGNAT（`100.64/10`）、保留段（`0/8`、`224+`、
///    `198.18/15`、`192.0.2/24` 等）、IPv6 ULA `fc00::/7`、`fe80::/10`、
///    IPv4-mapped（`::ffff:127.0.0.1`）**按映射后的 IPv4 再判一次**；
/// 4. **域名**：先 `InternetAddress.lookup`，**解析出来的每一个地址**都要通过
///    上面第 3 条 —— 只检查字符串挡不住 `evil.example.com → 127.0.0.1`；
/// 5. **重定向**：`followRedirects = false`，每一跳的 `Location` **重新走一遍
///    全套校验**（最多 5 跳）。跟跳是从这里绕过防护最常见的口子。
///
/// ## 诚实边界（不假装挡住了）
///
/// - **DNS rebinding**：校验时解析到的 IP 与真正连接时的 IP 可能不同
///   （TOCTOU）。`dart:io` 的 `HttpClient` 不让我们 pin 已校验的 IP，
///   所以这条**没有**堵死。要堵死需要 socket 级连接（自己建连接 + `Host` 头），
///   本轮没做 —— 如实记下。
/// - **代理**：`HttpClient` 默认读系统代理环境；若用户配了内网代理，
///   请求实际会打到代理（那是用户自己的选择，不是模型能控的）。
///
/// ## 为什么用 `dart:io` 而不是 `dio`（即使 `dio` 现在已经是依赖）
///
/// `app/pubspec.yaml` 里**已经有 `dio`**（backend 用，版本与它一致）。
/// 本类仍然用 `dart:io` 的 `HttpClient`，是三条具体理由，不是"没有依赖"：
///
/// 1. **SSRF 要手动跟跳** —— 这是本类最关键的逻辑（`followRedirects = false`
///    + 每跳重跑 [checkUrl]）。`dio` 的拦截器也能做，但"每次重定向都重新
///    解析 DNS 并重判 IP"在 `HttpClient` 上就是一个直白的循环；安全逻辑
///    越直白越容易审。
/// 2. **不需要 dio 的适配层** —— 这里只要 GET + 30 秒超时 + 5 MB 上限，
///    三样标准库都直接给。
/// 3. **当前行为已被单测钉住**（含 12 条 SSRF 用例）；换实现要重验一遍，
///    收益却只是"少用一个标准库"。
///
/// ⚠️ **诚实边界**：`dio` 可用而不用是**主动选择**。将来若要换
/// （代理配置 / cookie / HTTP/2），**只替换 [_fetchRaw]**，
/// SSRF 闸（[checkUrl]）与文本抽取（[_htmlToText]）都不用动。
/// 类名因此不叫 `DioWebCapability` —— 它内部确实没用 dio。
class DeviceWebCapability implements WebCapability {
  const DeviceWebCapability();

  /// 最多跟几跳重定向。
  static const int _maxRedirects = 5;

  /// 抓取网页并转成可读文本。
  @override
  Future<CapabilityResult> fetch(String url, {int maxChars = _Limits.webMaxChars}) async {
    final Uri uri;
    try {
      uri = Uri.parse(url.trim());
    } catch (e) {
      return CapabilityFailure(
        'URL 解析失败：`$url`（${_humanize(e)}）。请给出完整地址（含 https://）。',
        isRetryable: true,
      );
    }

    // ★ SSRF 闸（一）：语法与字面量检查 —— 先于任何网络动作
    final rejection = await checkUrl(uri);
    if (rejection != null) {
      return CapabilityFailure(rejection, isRetryable: false);
    }

    final fetched = await _fetchRaw(uri);
    if (fetched.error != null) return CapabilityFailure(fetched.error!);

    final contentType = fetched.contentType.toLowerCase();
    final body = _decodeBody(fetched.body, fetched.charset);

    final String text;
    if (contentType.contains('text/html') ||
        contentType.contains('application/xhtml') ||
        contentType.isEmpty) {
      text = _htmlToText(body);
    } else if (contentType.startsWith('text/') ||
        contentType.contains('json') ||
        contentType.contains('xml')) {
      text = body;
    } else {
      // 非文本（图片 / 压缩包 / PDF）：**不猜**，如实说抓不了
      return CapabilityFailure(
        '这个地址不是文本内容（Content-Type: ${fetched.contentType.isEmpty ? "未知" : fetched.contentType}），'
        'web_fetch 只能把文本页面转成可读文本，不解析二进制。',
        isRetryable: false,
      );
    }

    final trimmed = text.trim();
    final buf = StringBuffer();
    if (trimmed.isEmpty) {
      buf.writeln('（页面抓到了，但抽不出文本内容 —— 可能是纯脚本页面或空页。）');
      buf.writeln('URL：${uri.toString()}');
      buf.writeln('Content-Type：${fetched.contentType.isEmpty ? "未知" : fetched.contentType}');
    } else if (trimmed.length <= maxChars) {
      buf.write(trimmed);
    } else {
      buf.write(trimmed.substring(0, maxChars));
      buf.writeln();
      buf.writeln();
      buf.writeln('⚠️ 已截断：只返回前 $maxChars 个字符'
          '（全文约 ${trimmed.length} 字符）。需要后面的内容请换更具体的页面。');
    }
    if (fetched.truncated) {
      buf.writeln();
      buf.writeln('⚠️ 下载被截断：响应体超过 '
          '${_formatSize(_Limits.webMaxResponseBytes)} 上限，只读了前面一部分。');
    }

    return CapabilitySuccess(
      buf.toString().trimRight(),
      metadata: <String, dynamic>{
        'url': uri.toString(),
        'status': fetched.statusCode,
        'contentType': fetched.contentType,
        'truncated': fetched.truncated || trimmed.length > maxChars,
      },
    );
  }

  // ------------------------------------------------------------------ SSRF

  /// SSRF 判定：返回**拒绝原因**（人话）；`null` = 放行。
  ///
  /// 公开成静态方法是为了能单测：这条是**产品级安全要求**，
  /// 它应该被测试直接钉住，而不是只能通过"真的发一次请求"来验证。
  static Future<String?> checkUrl(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '只允许抓取 http / https 地址，收到的是 `${uri.scheme}`。'
          '（`file:` / `content:` / `ftp:` 等一律拒绝 —— 那可能是读取本机文件的通道。）';
    }
    if (uri.host.trim().isEmpty) {
      return 'URL 里没有主机名：`$uri`。';
    }
    if (uri.userInfo.isNotEmpty) {
      // 带账号密码的 URL 会把凭据写进日志/错误信息；正常网页抓取用不到
      return 'URL 里带了账号密码（user:pass@），出于安全一律拒绝。请改用不需要凭据的地址。';
    }

    final host = uri.host.toLowerCase();

    // (1) 主机名黑名单
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host == 'metadata' ||
        host.endsWith('.internal')) {
      return '拒绝访问 `$host`：这是本机 / 内网域名，'
          'web_fetch 不允许读内网与本机服务（防止网页内容诱导读取内网）。';
    }

    // (2) IP 字面量
    final literal = InternetAddress.tryParse(uri.host);
    if (literal != null) {
      final why = _blockedAddressReason(literal);
      if (why != null) return _blockedMessage(uri.host, why);
    } else {
      // (3) 域名：解析后**每一个**地址都要过一遍（挡 evil.com → 127.0.0.1）
      List<InternetAddress> addrs;
      try {
        addrs = await InternetAddress.lookup(host);
      } catch (e) {
        return '解析不了主机名 `$host`（${_humanize(e)}）。请检查地址拼写或网络。';
      }
      if (addrs.isEmpty) {
        return '主机名 `$host` 没有解析出任何地址。';
      }
      for (final addr in addrs) {
        final why = _blockedAddressReason(addr);
        if (why != null) {
          return _blockedMessage('$host → ${addr.address}', why);
        }
      }
    }

    if (uri.port < 0 || uri.port > 65535) {
      return '端口不合法：${uri.port}。';
    }
    return null;
  }

  /// 给出"这个地址为什么不许连"；`null` = 允许。
  ///
  /// 公开 IPv4 段是唯一允许的目标类型。IPv6 只放行全球单播（`2000::/3`）
  /// 且**不是** ULA / 链路本地 / 回环的那部分。
  static String? _blockedAddressReason(InternetAddress addr) {
    final bytes = addr.rawAddress;
    if (bytes.length == 4) {
      final b0 = bytes[0], b1 = bytes[1], b2 = bytes[2];
      if (b0 == 0) return '保留段 0.0.0.0/8';
      if (b0 == 10) return '私有网段 10.0.0.0/8';
      if (b0 == 127) return '回环地址 127.0.0.0/8';
      if (b0 == 169 && b1 == 254) {
        return '链路本地 / 云元数据段 169.254.0.0/16（含 169.254.169.254）';
      }
      if (b0 == 172 && b1 >= 16 && b1 <= 31) return '私有网段 172.16.0.0/12';
      if (b0 == 192 && b1 == 168) return '私有网段 192.168.0.0/16';
      if (b0 == 100 && b1 >= 64 && b1 <= 127) return '运营商 NAT 段 100.64.0.0/10';
      if (b0 == 198 && (b1 == 18 || b1 == 19)) return '基准测试段 198.18.0.0/15';
      if (b0 == 192 && b1 == 0 && b2 == 0) return '保留段 192.0.0.0/24';
      if (b0 == 192 && b1 == 0 && b2 == 2) return '文档段 192.0.2.0/24';
      if (b0 == 198 && b1 == 51 && b2 == 100) return '文档段 198.51.100.0/24';
      if (b0 == 203 && b1 == 0 && b2 == 113) return '文档段 203.0.113.0/24';
      if (b0 == 255) return '广播地址 255.255.255.255';
      if (b0 >= 224) return '组播 / 保留段 224.0.0.0/4';
      return null;
    }
    if (bytes.length == 16) {
      // IPv4-mapped（::ffff:a.b.c.d）⇒ 取后 4 字节按 IPv4 再判一次
      final allZeroPrefix = bytes.take(10).every((b) => b == 0);
      if (allZeroPrefix && bytes[10] == 0xff && bytes[11] == 0xff) {
        return _blockedAddressReason(
          InternetAddress.fromRawAddress(bytes.sublist(12)),
        );
      }
      // ::1（回环）
      if (bytes.take(15).every((b) => b == 0) && bytes[15] == 1) {
        return 'IPv6 回环地址 ::1';
      }
      // fc00::/7（ULA）
      if ((bytes[0] & 0xfe) == 0xfc) return 'IPv6 唯一本地地址 fc00::/7';
      // fe80::/10（链路本地）
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
        return 'IPv6 链路本地地址 fe80::/10';
      }
      // 只放行全球单播 2000::/3
      if ((bytes[0] & 0xe0) != 0x20) return 'IPv6 非全球单播地址（2000::/3 之外）';
      return null;
    }
    return '无法识别的地址长度（${bytes.length}B）';
  }

  static String _blockedMessage(String what, String why) =>
      '拒绝访问 `$what`：$why。\n'
      'web_fetch 不允许访问本机 / 内网 / 云元数据地址 —— '
      '这是产品级安全要求（模型可能被网页内容诱导去读内网服务，提示注入）。'
      '如果你确实需要抓公网内容，请给出公开可访问的 http(s) 地址。';

  // ------------------------------------------------------------------ 请求

  /// 真的发请求（[fetch] 的 IO 部分）。
  ///
  /// **手动跟跳**：`followRedirects = false`，每一跳重新跑 [checkUrl]。
  /// 自动跟跳 = 一次 302 就能把前面所有检查绕过去（最常见的 SSRF 绕过）。
  Future<_FetchedPage> _fetchRaw(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'Heracles/1.0 (+https://github.com/theohowie/heracles)';

    try {
      var current = uri;
      for (var hop = 0; hop <= _maxRedirects; hop++) {
        // ★ 每一跳都重跑 SSRF 闸（不只第一跳）
        if (hop > 0) {
          final why = await checkUrl(current);
          if (why != null) {
            return _FetchedPage.error('重定向到被拒绝的地址：$why');
          }
        }

        final req = await client
            .getUrl(current)
            .timeout(const Duration(seconds: _Limits.webTimeoutSeconds));
        req.followRedirects = false;
        final res = await req.close().timeout(
              const Duration(seconds: _Limits.webTimeoutSeconds),
            );

        final status = res.statusCode;
        final location = res.headers.value(HttpHeaders.locationHeader);
        if (status >= 300 && status < 400 && location != null) {
          // 丢掉响应体，避免连接挂着
          await res.drain<void>();
          final next = current.resolve(location);
          if (next.scheme != 'http' && next.scheme != 'https') {
            return _FetchedPage.error(
              '重定向到了非 http(s) 地址（`${next.scheme}`），已拒绝。',
            );
          }
          current = next;
          continue;
        }

        final contentType =
            res.headers.value(HttpHeaders.contentTypeHeader) ?? '';
        final charset = res.headers.contentType?.charset;

        final bytes = <int>[];
        var truncated = false;
        await for (final chunk in res.timeout(
          const Duration(seconds: _Limits.webTimeoutSeconds),
        )) {
          if (bytes.length + chunk.length > _Limits.webMaxResponseBytes) {
            truncated = true;
            break;
          }
          bytes.addAll(chunk);
        }

        return _FetchedPage(
          statusCode: status,
          contentType: contentType,
          charset: charset,
          body: bytes,
          truncated: truncated,
        );
      }
      return _FetchedPage.error(
        '重定向次数超过 $_maxRedirects 跳，已放弃（可能是循环重定向）。',
      );
    } on TimeoutException {
      return _FetchedPage.error(
        '抓取超时（${_Limits.webTimeoutSeconds} 秒）：`$uri`。'
        '页面太大或网络太慢，可以换一个更轻的地址。',
      );
    } on SocketException catch (e) {
      return _FetchedPage.error('网络连接失败：${e.message}（`$uri`）。');
    } catch (e) {
      return _FetchedPage.error('抓取失败：${_humanize(e)}（`$uri`）。');
    } finally {
      client.close(force: true);
    }
  }

  /// 字节 → 文本。
  ///
  /// 编码只认响应头声明的 charset（默认 UTF-8）：
  /// **不做**编码嗅探（猜错会把整页变成乱码，比"如实说解不出"更糟）。
  static String _decodeBody(List<int> bytes, String? charset) {
    final cs = (charset ?? 'utf-8').toLowerCase();
    if (cs == 'utf-8' || cs == 'utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    // latin1 是逐字节可逆的兜底；其它编码一律按 UTF-8 尽力解（不引转换库）
    if (cs == 'iso-8859-1' || cs == 'latin1' || cs == 'windows-1252') {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// HTML → 可读文本（剥标签）。
  ///
  /// 顺序很重要：先删**整块**（`script` / `style` / 注释），再剥标签，
  /// 最后解码实体 —— 反过来会把 `<script>` 里的 `&lt;` 之类解出假标签。
  static String _htmlToText(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
    s = s.replaceAll(
      RegExp(r'<(script|style|noscript)\b[^>]*>[\s\S]*?</\1\s*>',
          caseSensitive: false),
      ' ',
    );
    // 块级元素换行，行内元素变空格（保住"单词不粘连"）
    s = s.replaceAll(
      RegExp(r'</?(p|div|br|hr|li|tr|h[1-6]|section|article|header|footer|'
          r'blockquote|pre|table|thead|tbody|ul|ol|dl|dt|dd)\b[^>]*>',
          caseSensitive: false),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = _decodeEntities(s);
    // 折叠空白：行内多空格 → 一个；连续空行 → 一个空行
    s = s
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ').trim())
        .join('\n');
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  /// 解常见的 HTML 实体（不引 `package:html`：几十行够用，依赖是 ADR 级决策）。
  static String _decodeEntities(String s) {
    const named = <String, String>{
      '&nbsp;': ' ',
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&#39;': "'",
      '&apos;': "'",
      '&mdash;': '—',
      '&ndash;': '–',
      '&hellip;': '…',
      '&rsquo;': '’',
      '&lsquo;': '‘',
      '&ldquo;': '“',
      '&rdquo;': '”',
    };
    var out = s;
    named.forEach((k, v) => out = out.replaceAll(k, v));
    // 数字实体：&#123; / &#x1F600;
    out = out.replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|\d+);'), (m) {
      final raw = m.group(1)!;
      final code = raw.startsWith('x') || raw.startsWith('X')
          ? int.tryParse(raw.substring(1), radix: 16)
          : int.tryParse(raw);
      if (code == null || code <= 0 || code > 0x10ffff) return m.group(0)!;
      return String.fromCharCode(code);
    });
    return out;
  }
}

/// 一次抓取的结果（内部用，**不抛**）。
class _FetchedPage {
  const _FetchedPage({
    required this.statusCode,
    required this.contentType,
    required this.charset,
    required this.body,
    required this.truncated,
  })  : error = null;

  const _FetchedPage.error(String reason)
      : statusCode = 0,
        contentType = '',
        charset = null,
        body = const <int>[],
        truncated = false,
        error = reason;

  final int statusCode;
  final String contentType;
  final String? charset;
  final List<int> body;
  final bool truncated;
  final String? error;
}

// ============================================================================
// 6. 长期记忆
// ============================================================================

/// **记忆能力 → App 全局 `memory.md`**（2026-10-23 从"工作区"搬到"App"）。
///
/// ## 为什么改了存储位置（用户报的两个缺陷）
///
/// 原来写 `<工作区>/.heracles/memory.md`，带来两个**功能性**问题：
///
/// | 缺陷 | 后果 |
/// |---|---|
/// | 存工作区里 | 换个工作区 ⇒ 记忆全没了 |
/// | 只写不读 | `renderMemory()` 全仓 0 处调用 ⇒ 记了也用不上，换会话必失忆 |
///
/// 现在统一走 [GlobalMemory]（`<getExternalFilesDir>/heracles/memory.md`）：
/// **与工作区无关、跨会话共享**，也正是用户在设置页能看到的同一份数据
/// （一份真相，不是两处各存一份）。
///
/// ## 为什么构造参数还留着 `workspaceRoot`
///
/// **不用了，但保留**（标了 `@Deprecated` 意图）。理由：
///
/// - 调用点（`buildDeviceCapabilities`）一直在传它；
/// - 位置决策从"每个工作区一份"变成"App 一份"之后，`workspaceRoot`
///   对记忆已无意义 —— 但**删参数会让所有调用点编译失败**，
///   而记忆不是本轮唯一在动的地方（并行改动的文件多），少一个回归面更划算。
///
/// 传什么都不会影响行为。**新代码请用无参构造**。
///
/// ## 256 KB 上限在哪挡
///
/// 在 **Kotlin**（`MemoryStore.MAX_BYTES`，它是唯一写入口）——
/// 那才是不可绕过的地方。这里只负责把 Kotlin 的 `error` 原文透传：
/// 那句话已含"当前多大 / 加完多大 / 上限多少 / 该怎么办"，
/// 在这里重写一遍只会丢信息。
class FileMemoryCapability implements MemoryCapability {
  /// [workspaceRoot] **已不参与记忆路径**（保留仅为兼容旧调用点，见类注释）。
  FileMemoryCapability({
    @Deprecated('记忆已改为 App 全局，workspaceRoot 不再影响存储位置')
    String? workspaceRoot,
    GlobalMemory? memory,
    DeviceChannelClient? channel,
  }) : _memory = memory ?? GlobalMemory(channel: channel);

  final GlobalMemory _memory;

  /// 记忆客户端（设置页用的是同一个实现，只是一次性构造）。
  GlobalMemory get client => _memory;

  /// 记忆文件的概念位置（**由 Kotlin 决定**，这里给排障用）。
  ///
  /// ⚠️ 这是**展示用**的示意路径，Dart 侧拿不到 `getExternalFilesDir` 的
  /// 真实值。要精确路径请看 `memory.read` 的返回或 logcat。
  String get memoryPath => '<externalFilesDir>/heracles/memory.md';

  /// 读记忆。
  ///
  /// ⚠️ 接口签名是 `Future<String>`（**没有失败通道**）—— 读不到只能返回空串，
  /// 而"空串"与"读失败"在调用方看起来一样。想在界面上区分就用 [readResult]。
  /// 这是 [MemoryCapability.read] 的签名缺陷，本轮不改（已报告）。
  @override
  Future<String> read() => _memory.read();

  /// 带失败信息的读（设置页 / 排障用）。
  Future<MemoryReadResult> readResult() => _memory.readResult();

  @override
  Future<CapabilityResult> append(String note) async {
    final n = note.trim();
    if (n.isEmpty) {
      return const CapabilityFailure(
        '要记住的内容是空的。请给一句具体的项目知识或用户偏好。',
        isRetryable: true,
      );
    }

    final r = await _memory.appendResult(n);
    if (!r.ok) {
      // ★ Kotlin 写的人话**原样透传**（含"当前多大 / 上限多少 / 怎么办"）。
      //   超限属"这条路暂时走不通"而非"参数错"⇒ isRetryable: false，
      //   否则模型会换个说法反复重试同一件注定失败的事。
      return CapabilityFailure(
        r.error ?? '写入长期记忆失败（原因未知）',
        isRetryable: false,
      );
    }

    final bytes = r.bytes ?? 0;
    return CapabilitySuccess(
      '已记入长期记忆（App 全局，现在 ${_formatSize(bytes)}）。'
      '这条记忆**跨会话、跨工作区**都有效。',
      metadata: <String, dynamic>{
        'bytes': bytes,
        'addedChars': n.length,
        'limitBytes': GlobalMemory.maxBytes,
      },
    );
  }

  /// 清空全部记忆（**设置页用**，不在 backend 的 `MemoryCapability` 里）。
  Future<bool> clear() => _memory.clear();
}

// ============================================================================
// 便捷组装
// ============================================================================

/// **一次把 6 项能力装好**，交给 backend 的 `Capabilities`。
///
/// Lead 的接线点就是这里：
///
/// ```dart
/// final caps = buildDeviceCapabilities(workspaceRoot: ws.path);
/// // 然后 AgentBridge/caps 交给 backend 的 HeraclesAgent
/// ```
///
/// ## 为什么 APK 也用"未实现"的实现而不是 `null`
///
/// `Capabilities.apk == null` 会让工具层把 APK 工具标成**不可用**
/// （`isAvailable: () => apk != null`），模型看到的是一句"当前环境不支持"
/// —— 那会掩盖真相（真相是：这条能力被**移除**了，不是环境不支持）。
/// 传一个"明确说未实现 + 不可重试"的实现，模型能读到
/// "旧 Kotlin 引擎已随 `:toolchain` 删除"，不会陷入换参数重试的循环。
///
/// 想让它彻底不可见就传 `includeApk: false`（那时 `apk` 为 `null`）。
Capabilities buildDeviceCapabilities({
  required String workspaceRoot,
  DeviceChannelClient? channel,
  bool includeApk = true,
  bool includeWeb = true,
  bool includeMemory = true,
  bool includeHealth = true,
}) {
  final ch = channel ?? const DeviceChannelClient();
  return Capabilities(
    workspace: DeviceWorkspaceCapability(workspaceRoot: workspaceRoot, channel: ch),
    shell: DeviceShellCapability(workspaceRoot: workspaceRoot, channel: ch),
    deviceHealth:
        includeHealth ? ChannelHealthCapability(channel: ch) : null,
    apk: includeApk ? const DeviceApkCapability() : null,
    web: includeWeb ? const DeviceWebCapability() : null,
    memory:
        includeMemory ? FileMemoryCapability(channel: ch) : null,
  );
}

// ============================================================================
// 小工具
// ============================================================================

/// 宽松取 int（通道给 `Int` / `Long` 都会落到 `num`）。
int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

/// 字节数 → 人话（与 backend 的 `_formatSize` 同口径）。
String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 异常 → 短人话（堆栈对模型没用，截断到 300 字符）。
String _humanize(Object e) {
  final s = e.toString();
  return s.length > 300 ? '${s.substring(0, 300)}…' : s;
}
