// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// ============================================================================
// 沙箱服务 —— 内联执行面（PRoot + rootfs）的 Dart 侧客户端
// ============================================================================
//
// ## 沙箱是什么、不是什么
//
// 沙箱是**内联在本 APK 里的执行面**（PRoot + Alpine rootfs），不是第二个 App，
// 也不是「更高权限的 shell」。它解决的问题是**文件系统污染与崩溃恢复**：
// 命令在 rootfs 里跑，产物、缓存、半成品都留在 rootfs，随时可整块回滚。
//
// ⚠️ PRoot **不提供 namespace / cgroup / seccomp**，所以它**不是敌对代码隔离**。
// 这一条在 `sandbox/docs/security-boundary.md` 与 README 顶部都写死了，别改。
//
// ## 与 `heracles/device` 的 `exec.run` 是两个东西
//
// | 通道 | 在哪跑 | 身份 | 用途 |
// |---|---|---|---|
// | `heracles/device` `exec.run` | 真实设备 | App / Shizuku / Root | 操作**真实手机**（装包、读系统文件…） |
// | `heracles/sandbox` `execute` | PRoot rootfs 内 | 沙箱内假 root | 跑**项目构建/脚本**，不碰真实系统 |
//
// **两条路刻意不合并**：沙箱不会替代设备 shell，也不会绕过它。
//
// ## 权限决策不在沙箱里
//
// 沙箱只回答「有哪些通道、可用吗、风险几级」；
// **放不放行由 Heracles 的门禁决定**（工具白名单 + 参数门禁三态）。
// 这是硬约束：`queryChannels()` 的返回里**没有** allow/deny 字段，
//  Dart 侧也**不得**把它当授权依据。
//
// ## 命名挂载（MountRegistry）
//
// 模型只写 `@name/...`（如 `@workspace/out/app.apk`），物理路径由 Kotlin 侧解析。
// **物理路径不得出现在提示词、few-shot、历史对话里** —— 否则换设备/改共享目录时
// 历史对话里的路径全失效。
//
// 三种挂载后端（`backend` 字段，与 Kotlin 的 `MountBackend.wireValue` 对应）：
//   0 = ROOTFS_RELATIVE    rootfs 内相对路径，读写都在沙箱内（等价工作区）
//   1 = HOST_PRIVATE_DIR   宿主私有目录绝对路径，可读写，必要时 bind 进 rootfs
//   2 = SAF_TREE           用户授权的 SAF 目录（跨设备文件的合法入口）
//
// 只读挂载点的写入会被**宿主侧直接拒绝**（错误码 13 `CODE_MOUNT_READ_ONLY`），
// 不会先进 PRoot 再靠文件权限兜底 —— 那样宿主分不清「只读」和「磁盘满」。
// ============================================================================

import 'dart:async';

import 'package:flutter/services.dart';

/// 沙箱未注册挂载点时返回的错误码（与 Kotlin `SandboxException.CODE_MOUNT_UNKNOWN` 一致）。
const int kSandboxCodeMountUnknown = 12;

/// 对只读挂载点写入时返回的错误码（与 `CODE_MOUNT_READ_ONLY` 一致）。
const int kSandboxCodeMountReadOnly = 13;

/// rootfs 还没装。
const int kSandboxCodeRootfsNotReady = 2;

/// 挂载后端枚举（与 Kotlin `MountBackend.wireValue` 一一对应）。
enum SandboxMountBackend {
  /// rootfs 内相对路径，读写都在沙箱内完成。
  rootfsRelative(0),

  /// 宿主应用私有目录的绝对路径。
  hostPrivateDir(1),

  /// 用户授权的持久化 SAF 目录树。
  safTree(2);

  const SandboxMountBackend(this.wireValue);

  final int wireValue;
}

/// 沙箱状态快照。
class SandboxStatus {
  const SandboxStatus({
    required this.installed,
    required this.rootfsSummary,
    required this.prootReady,
    required this.channels,
  });

  /// rootfs 是否已就绪（=「沙箱已激活」）。
  final bool installed;

  /// 给用户看的一行摘要，如 `bundled-minimal (source=1, 9040693 B, snapshots=0)`。
  final String rootfsSummary;

  /// PRoot 二进制是否在 `nativeLibraryDir`（W^X 只允许那里 exec）。
  final bool prootReady;

  /// 四条通道的可用性与风险等级。**不含 allow/deny** —— 授权是门禁的事。
  final List<SandboxChannelInfo> channels;

  bool get ready => installed && prootReady;
}

/// 一条通道的可用性描述。
class SandboxChannelInfo {
  const SandboxChannelInfo({
    required this.type,
    required this.name,
    required this.available,
    required this.reason,
    required this.risk,
  });

  final int type;
  final String name;
  final bool available;

  /// 不可用时的原因（人话）。可用时为空串。
  final String reason;

  /// 风险等级 0/1/2（与 `RiskLevel` 对应）。
  final int risk;

  @override
  String toString() => '$name(${available ? "可用" : "不可用"}/风险$risk)';
}

/// 一次沙箱执行的结果。
class SandboxExecResult {
  const SandboxExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.durationMs,
    required this.timedOut,
    required this.cancelled,
    required this.truncated,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final int durationMs;
  final bool timedOut;
  final bool cancelled;
  final bool truncated;

  bool get success => exitCode == 0 && !timedOut && !cancelled;

  factory SandboxExecResult.fromMap(Map<Object?, Object?> m) => SandboxExecResult(
        exitCode: (m['exitCode'] as num?)?.toInt() ?? -1,
        stdout: (m['stdout'] as String?) ?? '',
        stderr: (m['stderr'] as String?) ?? '',
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        timedOut: (m['timedOut'] as bool?) ?? false,
        cancelled: (m['cancelled'] as bool?) ?? false,
        truncated: (m['truncated'] as bool?) ?? false,
      );
}

/// 一个已注册的命名挂载点。
class SandboxMount {
  const SandboxMount({
    required this.name,
    required this.backend,
    required this.readOnly,
    required this.bindTo,
    required this.description,
  });

  /// 不含 `@` 的逻辑名。
  final String name;
  final SandboxMountBackend backend;

  /// 只读挂载点：写入会被宿主侧拒绝。
  final bool readOnly;

  /// 绑进 PRoot 的 guest 挂载点（空串 = 不绑定）。
  final String bindTo;
  final String description;

  /// 模型看到的完整前缀，如 `@workspace`。
  String get prefix => '@$name';

  factory SandboxMount.fromMap(Map<Object?, Object?> m) => SandboxMount(
        name: (m['name'] as String?) ?? '',
        backend: SandboxMountBackend.values.firstWhere(
          (b) => b.wireValue == ((m['backend'] as num?)?.toInt() ?? 0),
          orElse: () => SandboxMountBackend.rootfsRelative,
        ),
        readOnly: (m['readOnly'] as bool?) ?? false,
        bindTo: (m['bindTo'] as String?) ?? '',
        description: (m['description'] as String?) ?? '',
      );
}

/// `heracles/sandbox` 的**薄封装**：把「拿不到结果」收敛成同一形状，**永不抛**。
///
/// 为什么单独抽：每个方法都要做 `invokeMethod` → 读 `ok` / 取 `error`。
/// 散开写必然漏掉「通道没注册」这条兜底，然后那一路会往 agent 循环里抛
/// `MissingPluginException`。
class SandboxChannelClient {
  const SandboxChannelClient({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// 通道名 —— **必须与 Kotlin `SandboxBridge.CHANNEL` 逐字一致**。
  static const String channelName = 'heracles/sandbox';

  /// 流式输出通道 —— 必须与 `SandboxBridge.OUTPUT_CHANNEL` 一致。
  static const String outputChannelName = 'heracles/sandbox/output';

  final MethodChannel _channel;

  /// 调一次通道方法。**永不抛**。
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
        'error': '沙箱通道 `$channelName` 不可用（App 没挂上原生实现，'
            '或当前跑在纯 Dart 环境里）。',
      };
    } on PlatformException catch (e) {
      return <String, Object?>{
        'ok': false,
        'error': '沙箱通道抛出异常（本不该发生）：${e.code}'
            '${e.message == null ? "" : " ${e.message}"}',
      };
    } catch (e) {
      return <String, Object?>{
        'ok': false,
        'error': '调用沙箱通道 $method 时出错：$e',
      };
    }

    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, Object?>{
      'ok': false,
      'error': '沙箱通道 $method 返回了意料之外的形状（${raw.runtimeType}），预期是 Map。',
    };
  }
}

/// 沙箱服务门面。
///
/// 用法：
/// ```dart
/// final sandbox = SandboxService();
/// final status = await sandbox.status();
/// if (!status.installed) await sandbox.activate();       // 激活 = 装 rootfs
/// await sandbox.execute('echo hi', onOutput: (s) => print(s));
/// ```
class SandboxService {
  SandboxService({SandboxChannelClient? client})
      : _client = client ?? const SandboxChannelClient();

  final SandboxChannelClient _client;

  /// 流式输出回调（由原生侧主动 push）。
  final StreamController<SandboxOutputChunk> _outputs =
      StreamController<SandboxOutputChunk>.broadcast();

  /// 执行完成事件。
  final StreamController<SandboxExecDone> _dones =
      StreamController<SandboxExecDone>.broadcast();

  /// 执行出错事件。
  final StreamController<SandboxExecError> _errors =
      StreamController<SandboxExecError>.broadcast();

  MethodChannel? _outputChannel;
  bool _listening = false;

  Stream<SandboxOutputChunk> get outputStream => _outputs.stream;
  Stream<SandboxExecDone> get doneStream => _dones.stream;
  Stream<SandboxExecError> get errorStream => _errors.stream;

  /// 开始监听流式通道。**幂等**；App 启动时调一次即可。
  void attachOutputChannel({MethodChannel? channel}) {
    if (_listening) return;
    final ch = channel ?? const MethodChannel(SandboxChannelClient.outputChannelName);
    _outputChannel = ch;
    ch.setMethodCallHandler(_handleOutputCall);
    _listening = true;
  }

  Future<void> _handleOutputCall(MethodCall call) async {
    switch (call.method) {
      case 'output':
        final m = _asMap(call.arguments);
        _outputs.add(SandboxOutputChunk(
          id: (m['id'] as String?) ?? '',
          stream: (m['stream'] as num?)?.toInt() ?? 1,
          chunk: (m['chunk'] as String?) ?? '',
        ));
        break;
      case 'progress':
        final m = _asMap(call.arguments);
        _outputs.add(SandboxOutputChunk(
          id: (m['id'] as String?) ?? '',
          stream: 0,
          chunk: '',
          progressPercent: (m['percent'] as num?)?.toInt() ?? -1,
          progressMessage: (m['message'] as String?) ?? '',
        ));
        break;
      case 'done':
        final m = _asMap(call.arguments);
        _dones.add(SandboxExecDone(
          id: (m['id'] as String?) ?? '',
          result: SandboxExecResult.fromMap(_asMap(m['result'])),
        ));
        break;
      case 'error':
        final m = _asMap(call.arguments);
        _errors.add(SandboxExecError(
          id: (m['id'] as String?) ?? '',
          code: (m['code'] as num?)?.toInt() ?? -1,
          message: (m['message'] as String?) ?? '',
        ));
        break;
    }
  }

  // -------------------------------------------------------------- 状态 / 激活

  /// 查沙箱状态（**不触发任何副作用**）。
  Future<SandboxStatus> status() async {
    final raw = await _client.call('status');
    return _statusFrom(raw);
  }

  /// 激活沙箱：**内置 rootfs 优先（离线），OCI 兜底（要网）**。
  ///
  /// 这就是「一步初始化」的那一半 —— **只装环境，不签名、不打包**。
  ///
  /// @param ociRef 内置不可用时的 OCI 镜像引用；传 null 表示只用内置
  Future<SandboxStatus> activate({String? ociRef}) async {
    final raw = await _client.call('activate', <String, Object?>{
      'ociRef': ?ociRef,
    });
    return _statusFrom(raw);
  }

  // -------------------------------------------------------------- 执行

  /// 在沙箱 rootfs 内执行命令。
  ///
  /// 返回的 `Future` 在**提交后立即完成**（带 `id`）；真正的输出走
  /// [outputStream] / [doneStream] / [errorStream]。
  ///
  /// @param command 直接交给 rootfs 内 `/bin/sh -lc`，所以可以带管道与重定向；
  ///                命令里的 `@name/...` 会在**交给 shell 前**被解析成路径
  /// @param workdir 沙箱视角的工作目录（默认 `/workspace`）
  Future<SandboxSubmit> execute(
    String command, {
    String workdir = '/workspace',
    int timeoutMs = 120000,
    bool usePty = false,
  }) async {
    // 懒挂流式通道：调用方不必记得在启动时接线，`execute` 自己保证有人在听。
    attachOutputChannel();
    final raw = await _client.call('execute', <String, Object?>{
      'command': command,
      'workdir': workdir,
      'timeoutMs': timeoutMs,
      'usePty': usePty,
    });
    if (raw['ok'] != true) {
      return SandboxSubmit.failed((raw['error'] as String?) ?? '提交失败');
    }
    return SandboxSubmit.submitted((raw['id'] as String?) ?? '');
  }

  // -------------------------------------------------------------- 文件

  /// 读文件。`path` 可以是 `@name/...`，也可以是宿主绝对路径。
  Future<SandboxFileResult> readFile(String path) async {
    final raw = await _client.call('readFile', <String, Object?>{'path': path});
    return SandboxFileResult.fromMap(raw);
  }

  /// 写文本文件（UTF-8）。对只读挂载点写入会得到 [kSandboxCodeMountReadOnly]。
  Future<SandboxFileResult> writeFile(String path, String text) async {
    final raw = await _client.call('writeFile', <String, Object?>{
      'path': path,
      'text': text,
    });
    return SandboxFileResult.fromMap(raw);
  }

  // -------------------------------------------------------------- 挂载

  /// 注册（或覆盖）一个命名挂载点。
  ///
  /// 结构非法时返回 `ok=false`，**不要以为注册成功**。
  Future<SandboxFileResult> registerMount({
    required String name,
    required SandboxMountBackend backend,
    String hostPath = '',
    String treeUri = '',
    bool readOnly = false,
    String bindTo = '',
    String description = '',
  }) async {
    final raw = await _client.call('registerMount', <String, Object?>{
      'name': name,
      'backend': backend.wireValue,
      'hostPath': hostPath,
      'treeUri': treeUri,
      'readOnly': readOnly,
      'bindTo': bindTo,
      'description': description,
    });
    return SandboxFileResult.fromMap(raw);
  }

  /// 列出已注册挂载点（用于给用户展示「哪个是只读的」）。
  Future<List<SandboxMount>> listMounts() async {
    final raw = await _client.call('listMounts');
    if (raw['ok'] != true) return const <SandboxMount>[];
    final list = raw['mounts'];
    if (list is! List) return const <SandboxMount>[];
    return list
        .whereType<Map<Object?, Object?>>()
        .map(SandboxMount.fromMap)
        .toList(growable: false);
  }

  /// 查四条通道（**只报可用性与风险，不做授权**）。
  Future<List<SandboxChannelInfo>> queryChannels() async {
    final raw = await _client.call('queryChannels');
    return _channelsFrom(raw);
  }

  void dispose() {
    _outputChannel?.setMethodCallHandler(null);
    _listening = false;
    _outputs.close();
    _dones.close();
    _errors.close();
  }

  // -------------------------------------------------------------- 内部

  SandboxStatus _statusFrom(Map<String, Object?> raw) => SandboxStatus(
        installed: (raw['installed'] as bool?) ?? false,
        rootfsSummary: (raw['rootfsSummary'] as String?) ?? '',
        prootReady: (raw['prootReady'] as bool?) ?? false,
        channels: _channelsFrom(raw),
      );

  List<SandboxChannelInfo> _channelsFrom(Map<String, Object?> raw) {
    final list = raw['channels'];
    if (list is! List) return const <SandboxChannelInfo>[];
    return list.whereType<Map<Object?, Object?>>().map((m) {
      return SandboxChannelInfo(
        type: (m['type'] as num?)?.toInt() ?? 0,
        name: (m['name'] as String?) ?? '',
        available: (m['available'] as bool?) ?? false,
        reason: (m['reason'] as String?) ?? '',
        risk: (m['risk'] as num?)?.toInt() ?? 0,
      );
    }).toList(growable: false);
  }

  static Map<Object?, Object?> _asMap(Object? v) =>
      v is Map ? v : const <Object?, Object?>{};
}

/// 一次 `execute` 的提交结果（只是拿到 id，输出是流式的）。
class SandboxSubmit {
  const SandboxSubmit._(this.ok, this.id, this.error);

  factory SandboxSubmit.submitted(String id) => SandboxSubmit._(true, id, null);
  factory SandboxSubmit.failed(String error) => SandboxSubmit._(false, '', error);

  final bool ok;
  final String id;
  final String? error;
}

/// 流式输出片段（`stream` 1=stdout 2=stderr 0=进度）。
class SandboxOutputChunk {
  const SandboxOutputChunk({
    required this.id,
    required this.stream,
    required this.chunk,
    this.progressPercent = -1,
    this.progressMessage = '',
  });

  final String id;
  final int stream;
  final String chunk;
  final int progressPercent;
  final String progressMessage;

  bool get isStdout => stream == 1;
  bool get isStderr => stream == 2;
  bool get isProgress => stream == 0;
}

/// 执行完成。
class SandboxExecDone {
  const SandboxExecDone({required this.id, required this.result});
  final String id;
  final SandboxExecResult result;
}

/// 执行出错（沙箱侧错误，不是命令退出码非 0）。
class SandboxExecError {
  const SandboxExecError({
    required this.id,
    required this.code,
    required this.message,
  });
  final String id;
  final int code;
  final String message;

  /// 是否「挂了未注册的 `@name`」。
  bool get isUnknownMount => code == kSandboxCodeMountUnknown;

  /// 是否「往只读挂载点写」。
  bool get isReadOnlyMount => code == kSandboxCodeMountReadOnly;

  /// 是否「rootfs 还没装」。
  bool get isRootfsNotReady => code == kSandboxCodeRootfsNotReady;
}

/// 文件 / 挂载操作的统一结果。
class SandboxFileResult {
  const SandboxFileResult({
    required this.ok,
    required this.text,
    required this.size,
    required this.errorCode,
    required this.error,
  });

  final bool ok;
  final String? text;
  final int size;
  final int errorCode;
  final String error;

  /// 是否「只读挂载点被拒」—— 可直接据此给用户明确提示。
  bool get isReadOnly => errorCode == kSandboxCodeMountReadOnly;

  /// 是否「挂载点未注册」。
  bool get isUnknownMount => errorCode == kSandboxCodeMountUnknown;

  factory SandboxFileResult.fromMap(Map<String, Object?> m) => SandboxFileResult(
        ok: m['ok'] == true,
        text: m['text'] as String?,
        size: (m['size'] as num?)?.toInt() ?? 0,
        errorCode: (m['errorCode'] as num?)?.toInt() ?? 0,
        error: (m['error'] as String?) ?? '',
      );
}
