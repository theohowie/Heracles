/// **进程执行能力** —— 基于 `Process.start` 的 [ShellCapability] 实现。
///
/// ## 三条必须守住的线
///
/// 1. **流式读输出，禁止 `readAllBytes()`**
///    构建类命令的输出可能是几 MB。全读进内存 = OOM（手机上尤其致命）。
///    这里用 `listen` 逐块转发，[onOutput] 拿到什么就回调什么。
///
/// 2. **超时只 kill 自己起的这个进程**
///    `AGENTS.md` 硬约束：**禁止 kill / force-stop 用户设备上的任何应用**。
///    2026-10-09 有过真实事故（误杀用户的监控 App）。
///    ⇒ 这里的 `_kill` 只作用于本方法 `Process.start` 返回的那一个 `Process`
///    对象，**绝不**用 `pkill` / `killall` / 按名字找进程。
///    Windows 上还会先试 `taskkill /T`（只针对这个 pid 的树）。
///
/// 3. **内置命令守卫**
///    `kill` / `am force-stop` / `pm uninstall` / `pm clear` 一律
///    [CapabilityFailure]，并说明"这是产品硬约束"。
///    工具层（`shell_tools.dart` 的 `checkCommandSafety`）也挡了一遍 ——
///    能力层再挡一遍是**故意重复**：能力层可能被替换（CLI / App / 未来别的宿主），
///    而"不许杀用户应用"是产品级约束，不是某个实现的细节。
///
/// ## 输出上限
///
/// 总量上限 [ContractShell.maxOutputBytes]（1 MB）。超了**标注截断**，
/// 但**继续把流读完** —— 不读会把子进程的管道写满，进程反而卡死。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../capability/capabilities.dart';
import '../contract/contract.dart';

/// 内置命令守卫的判定结果。
class ShellGuardVerdict {
  const ShellGuardVerdict({required this.blocked, required this.reason});

  const ShellGuardVerdict.allow()
      : blocked = false,
        reason = null;

  final bool blocked;
  final String? reason;
}

/// 基于 `Process.start` 的 shell 实现。
class ProcessShellCapability implements ShellCapability {
  /// [workRoot] 是命令的工作目录（绝对路径）。
  /// [executable] 可换成别的 shell（默认按平台选）。
  ///
  /// 为什么 `workRoot` 用 initializing formal 而 `executable` 用初始化列表：
  /// **位置参数**可以写成 `this._workRoot`；**命名参数不能以下划线开头**，
  /// 所以 `_executable = executable` 只能保留（并 ignore 那条 lint）。
  ProcessShellCapability(
    this._workRoot, {
    String? executable,
  }) : _executable = executable; // ignore: prefer_initializing_formals

  final String _workRoot;
  final String? _executable;

  String get workRoot => _workRoot;

  /// 平台默认 shell。
  ///
  /// **不硬编码成 `bash`**：Windows 上没有 bash；Android 上有 `/system/bin/sh`
  /// 但没有 `bash`（除非用户装了 Termux）。用平台默认最稳。
  String get _shell {
    // 先取出到局部变量再判空：`_executable` 是 private final，Dart 3 的
    // field promotion 在 `!= null` 之后已经把它提升为非空，
    // 再写 `_executable!` 就是多余的 `!`（`unnecessary_non_null_assertion`）。
    final executable = _executable;
    if (executable != null) return executable;
    return Platform.isWindows ? 'cmd.exe' : '/system/bin/sh';
  }

  List<String> _shellArgs(String command) {
    if (Platform.isWindows && (_executable == null || _executable == 'cmd.exe')) {
      return ['/c', command];
    }
    return ['-c', command];
  }

  // ==========================================================================
  // 命令守卫
  // ==========================================================================

  /// **产品硬约束**：这些命令一律拒绝。
  ///
  /// 为什么不是 `NeedsApproval` 而是直接 `Failure`：
  /// 旧实现里 `kill` 类命令需要审批，但审批档位存在"始终允许"的白名单，
  /// 一旦用户误点就是**永久放行**。这条底线不该有"记住我的选择"。
  static final List<_Guard> _guards = [
    _Guard(
      // 单独出现 kill / killall / pkill：终止进程
      RegExp(r'(^|[\s;&|(])kill(all)?\b'),
      'kill / killall',
    ),
    _Guard(
      RegExp(r'(^|[\s;&|(])pkill\b'),
      'pkill',
    ),
    _Guard(
      RegExp(r'\bam\s+force-stop\b'),
      'am force-stop',
    ),
    _Guard(
      RegExp(r'\bam\s+kill\b'),
      'am kill',
    ),
    _Guard(
      RegExp(r'\bpm\s+uninstall\b'),
      'pm uninstall',
    ),
    _Guard(
      RegExp(r'\bpm\s+clear\b'),
      'pm clear',
    ),
    _Guard(
      RegExp(r'\bpm\s+disable\b'),
      'pm disable',
    ),
  ];

  /// 检查命令是否被守卫拦截。
  static ShellGuardVerdict checkCommand(String command) {
    final lower = command.toLowerCase();
    for (final g in _guards) {
      if (g.pattern.hasMatch(lower)) {
        return ShellGuardVerdict(
          blocked: true,
          reason: '命令包含 `${g.label}` —— 拒绝执行。'
              '这**不是**参数错误，而是 Heracles 的产品硬约束：'
              '设备是用户的，后端**不许**终止/卸载/清空用户设备上的任何应用'
              '（2026-10-09 曾误杀用户的监控 App，这条底线不再有"记住我的选择"）。'
              '如果你需要腾内存，只能停本任务自己启动的进程，或请用户手动处理。',
        );
      }
    }
    return const ShellGuardVerdict.allow();
  }

  // ==========================================================================
  // 执行
  // ==========================================================================

  @override
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(seconds: ContractShell.defaultTimeoutSeconds),
    void Function(String chunk)? onOutput,
  }) async {
    if (command.trim().isEmpty) {
      return const CapabilityFailure('命令为空。', isRetryable: true);
    }

    // ★ 守卫先于一切
    final verdict = checkCommand(command);
    if (verdict.blocked) {
      return CapabilityFailure(verdict.reason!, isRetryable: false);
    }

    if (!Directory(_workRoot).existsSync()) {
      return CapabilityFailure('工作目录不存在：`$_workRoot`。');
    }

    Process process;
    try {
      process = await Process.start(
        _shell,
        _shellArgs(command),
        workingDirectory: _workRoot,
        runInShell: false,
      );
    } catch (e) {
      return CapabilityFailure('无法启动 shell（`$_shell`）：${_humanize(e)}');
    }

    final stdoutBuf = _CappedBuffer(ContractShell.maxOutputBytes);
    final stderrBuf = _CappedBuffer(ContractShell.maxOutputBytes);

    // 流式转发（**不是** readAllBytes）。
    //
    // 两个流的完成用一个 completer 汇合：**必须等两个流都 done** 再取输出，
    // 否则最后一块（往往正是关键的那行报错）会被丢掉。
    var pendingStreams = 2;
    final streamsDone = Completer<void>();
    void onStreamDone() {
      pendingStreams--;
      if (pendingStreams == 0 && !streamsDone.isCompleted) streamsDone.complete();
    }

    final outSub = process.stdout.transform(utf8.decoder).listen((chunk) {
      stdoutBuf.write(chunk);
      onOutput?.call(chunk);
    }, onError: (Object e) {
      stderrBuf.write('\n[读取 stdout 出错：${_humanize(e)}]');
    }, onDone: onStreamDone);
    final errSub = process.stderr.transform(utf8.decoder).listen((chunk) {
      stderrBuf.write(chunk);
      onOutput?.call(chunk);
    }, onError: (Object e) {
      stderrBuf.write('\n[读取 stderr 出错：${_humanize(e)}]');
    }, onDone: onStreamDone);

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      _terminate(process);
    });

    final exit = await process.exitCode;
    timer.cancel();
    // 进程退了但流可能还有缓冲没吐完 —— 给它们一点时间收尾
    await streamsDone.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        outSub.cancel().ignore();
        errSub.cancel().ignore();
      },
    );

    final exitCode = timedOut ? -1 : exit;

    final buf = StringBuffer();
    final out = stdoutBuf.toString();
    final err = stderrBuf.toString();
    if (out.isNotEmpty) buf.write(out);
    if (err.isNotEmpty) {
      if (buf.isNotEmpty) buf.writeln();
      buf.writeln('[stderr]');
      buf.write(err);
    }
    if (buf.isEmpty) buf.write('（无输出）');

    if (timedOut) {
      buf.writeln();
      buf.writeln('⚠️ 命令超时（${timeout.inSeconds} 秒），已终止**本命令自己启动的进程**。'
          '（不会去动设备上的其它应用 —— 那是产品硬约束。）');
    }
    if (exitCode != 0 && !timedOut) {
      buf.writeln();
      buf.writeln('（命令退出码：$exitCode）');
    }
    final truncatedNote = stdoutBuf.truncated || stderrBuf.truncated;
    if (truncatedNote) {
      buf.writeln();
      buf.writeln('⚠️ 输出已截断：总量上限 '
          '${_formatSize(ContractShell.maxOutputBytes)}。'
          '需要看完整输出请把命令改成输出到文件，再用 read_file 分段读。');
    }

    final text = buf.toString().trimRight();

    if (timedOut) {
      return CapabilityFailure(text, isRetryable: true);
    }
    return CapabilitySuccess(
      text,
      metadata: {
        'exitCode': exitCode,
        'truncated': truncatedNote,
        'timedOut': false,
      },
    );
  }

  /// 只终止**本方法启动的那一个进程**（及其子进程树）。
  ///
  /// ⚠️ 绝不按名字查找进程。Windows 上 `taskkill /T /PID` 也只作用于该 pid 的树。
  Future<void> _terminate(Process process) async {
    final pid = process.pid;
    try {
      if (Platform.isWindows) {
        // 先温和地杀树，再兜底 kill 自己
        final killer = await Process.start(
          'taskkill',
          ['/PID', '$pid', '/T', '/F'],
          runInShell: false,
        );
        await killer.exitCode.timeout(
          const Duration(milliseconds: ContractShell.killGraceMs),
          onTimeout: () {
            killer.kill();
            return -1;
          },
        );
      }
      process.kill(ProcessSignal.sigkill);
    } catch (_) {
      // 进程可能已经自己退出了 —— 忽略
    }
  }

  static String _humanize(Object e) {
    final s = e.toString();
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// 带总量上限的字符串缓冲。
///
/// 超限后**继续接收**（不背压子进程），只是不再往正文里加。
class _CappedBuffer {
  _CappedBuffer(this.maxBytes);

  final int maxBytes;
  final StringBuffer _buf = StringBuffer();
  var _bytes = 0;
  var _truncated = false;

  bool get truncated => _truncated;

  void write(String chunk) {
    if (_truncated) return;
    final remaining = maxBytes - _bytes;
    if (remaining <= 0) {
      _truncated = true;
      return;
    }
    final chunkBytes = utf8.encode(chunk).length;
    if (chunkBytes <= remaining) {
      _buf.write(chunk);
      _bytes += chunkBytes;
      return;
    }
    // 截到字节上限：按 rune 累加，避免切碎多字节字符
    var taken = 0;
    final sb = StringBuffer();
    for (final r in chunk.runes) {
      final b = utf8.encode(String.fromCharCode(r)).length;
      if (taken + b > remaining) break;
      sb.writeCharCode(r);
      taken += b;
    }
    _buf.write(sb.toString());
    _bytes += taken;
    _truncated = true;
  }

  @override
  String toString() => _buf.toString();
}

class _Guard {
  const _Guard(this.pattern, this.label);
  final RegExp pattern;
  final String label;
}
