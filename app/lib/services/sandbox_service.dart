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

  // -------------------------------------------------------------- 重置 / 快照

  /// **重置沙箱**（破坏性）—— 整块回滚：`snapshot` 为空 = 清空 rootfs 回到
  /// 未激活态；给了名字 = 回滚到该快照。
  ///
  /// 由来：前端 2026-10-28 补的薄封装（§8 把「整块回滚」写成沙箱的核心卖点，
  /// 但客户端一直没有这个方法，设置页的「重置沙箱」落不了地）；后端侧随后
  /// 补了快照能力 ⇒ 签名带可选 `snapshot`，**不传参时行为与前端原版一致**。
  ///
  /// ⚠️ 会丢掉 rootfs 里的一切（未提交的构建产物、装的包、`@workspace` 里的文件
  /// 若在 rootfs 内也会没）。**UI 必须二次确认**，并说清会丢什么。
  ///
  /// ⚠️ 宿主侧若尚未实现 `reset`，通道调用会被收敛成失败形状，
  /// 返回的状态仍是重置前状态 —— 调用方**必须**核对返回的
  /// `installed` 是否真的变回 false，不要盲目报成功。
  ///
  /// 重置后挂载点会由后端自动补注册；前端调完重查一次 `status()` 即可。
  Future<SandboxStatus> reset({String snapshot = ''}) async {
    final raw = await _client.call('reset', <String, Object?>{'snapshot': snapshot});
    return _statusFrom(raw);
  }

  /// 给当前 rootfs 打快照（用于「构建前打点，失败回滚」）。
  ///
  /// 返回 `null` 表示失败（`error` 里有人话原因）。
  Future<SandboxSnapshotResult?> snapshot(String name) async {
    final raw = await _client.call('snapshot', <String, Object?>{'name': name});
    if (raw['ok'] != true) {
      return SandboxSnapshotResult(
        name: name,
        count: 0,
        error: (raw['error'] as String?) ?? '创建快照失败',
      );
    }
    return SandboxSnapshotResult(
      name: (raw['snapshotName'] as String?) ?? name,
      count: (raw['snapshotCount'] as num?)?.toInt() ?? 0,
      error: null,
    );
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

  // -------------------------------------------------------------- T2 编译环境

  /// T2 编译环境状态（**只读**，不触发下载）。
  Future<SandboxBuildSuiteStatus> buildSuiteStatus() async {
    final raw = await _client.call('buildSuiteStatus');
    return SandboxBuildSuiteStatus(
      ready: (raw['ready'] as bool?) ?? false,
      version: (raw['version'] as String?) ?? '',
      parts: ((raw['parts'] as Map?) ?? const {}).map(
        (k, v) => MapEntry(k.toString(), v == true),
      ),
      error: raw['ok'] == true ? null : (raw['error'] as String?) ?? '查询失败',
      // T2-6 只增字段：安装目录 / 当前占用 / 缺失项（人话）
      installDir: (raw['installDir'] as String?) ?? '',
      occupiedBytes: (raw['occupiedBytes'] as num?)?.toInt() ?? 0,
      missingLabels: ((raw['missing'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
    );
  }

  /// **激活 T2 编译环境**（≈415 MB，幂等 + 单飞 + 断点续传）。
  ///
  /// 进度走 [outputStream]（`isProgress` 的帧），所以调用前先进监听。
  /// 这是**用户主动**操作：UI 必须先说明体积并二次确认。
  Future<SandboxActivationResult> activateBuildSuite() async {
    attachOutputChannel();
    final raw = await _client.call('activateBuildSuite');
    return SandboxActivationResult(
      ok: raw['ok'] == true,
      message: (raw['message'] as String?) ?? '',
      alreadyReady: (raw['alreadyReady'] as bool?) ?? false,
      ready: (raw['ready'] as bool?) ?? false,
    );
  }

  /// 清掉 T2（只动编译环境，不碰 T0 基础环境 / T1 工具）。
  ///
  /// 旧接口，只回 `bool`（**保持兼容，别删**）。要看「删了什么 / 为什么失败 /
  /// 释放多少 / 现在缺什么」请用 [resetBuildSuiteVerbose]。
  Future<bool> resetBuildSuite() async {
    final raw = await _client.call('resetBuildSuite');
    return raw['ok'] == true;
  }

  /// **卸载 T2 并拿到真状态**（T2-6）：删除清单 / 失败项 / 释放字节 / 当前缺失项。
  ///
  /// 服务端（Kotlin `ToolchainActivation.reset()`）会：
  /// 1. `apk info -e` 判断 JDK 是否在 apk 库里 → 在就先 `apk del openjdk17-jdk`
  ///    （否则下次激活 `apk add` 会以为已装好而跳过，javac 永远缺失）；
  /// 2. 宿主侧删 `/opt/t2`、JDK 目录、`/usr/local/bin/gradle` 链接；
  /// 3. 复核 `status()` 必须变成未就绪，否则把残留列为失败项。
  ///
  /// 只动 T2，不碰 rootfs（T0）/ 内置工具（T1）/ 用户工作区。
  Future<SandboxBuildSuiteResetResult> resetBuildSuiteVerbose() async {
    final raw = await _client.call('resetBuildSuite');
    return SandboxBuildSuiteResetResult.fromMap(raw);
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

/// 快照结果。`error == null` 表示成功。
class SandboxSnapshotResult {
  const SandboxSnapshotResult({
    required this.name,
    required this.count,
    required this.error,
  });

  final String name;

  /// 当前快照总数（后端给的）。
  final int count;

  final String? error;

  bool get ok => error == null;
}

/// T2 编译环境状态。
class SandboxBuildSuiteStatus {
  const SandboxBuildSuiteStatus({
    required this.ready,
    required this.version,
    required this.parts,
    required this.error,
    this.installDir = '',
    this.occupiedBytes = 0,
    this.missingLabels = const <String>[],
  });

  /// 三项（jdk / gradle / androidJar）都齐了才为 true。
  final bool ready;

  /// 内容版本标记（改了组件会变，据此提示"需重新激活"）。
  final String version;

  /// 分项状态，如 `{jdk: true, gradle: false, androidJar: false}`。
  final Map<String, bool> parts;

  /// T2 安装目录（宿主绝对路径；UI 展示/排障用）。
  final String installDir;

  /// T2 当前占用字节（`/opt/t2` + JDK 目录）；UI 用来显示「卸载可释放 N MB」。
  final int occupiedBytes;

  /// 缺失项（**人话**，Kotlin 侧给，如「JDK 17（javac）」）。
  final List<String> missingLabels;

  final String? error;

  bool get ok => error == null;

  /// 缺哪一项（UI 要如实说"缺 Gradle"，而不是笼统说"未就绪"）。
  /// 优先用服务端给的人话文案；老版本服务端没这个字段时回落到 parts 的 key。
  List<String> get missing => missingLabels.isNotEmpty
      ? missingLabels
      : parts.entries.where((e) => !e.value).map((e) => e.key).toList();
}

/// T2 卸载失败项（路径 + 人话原因）。
class SandboxResetFailure {
  const SandboxResetFailure({required this.path, required this.reason});

  /// 沙箱视角路径（如 `/opt/t2`）。
  final String path;

  /// 失败原因（如「删除失败（路径仍存在：…）」「apk del 未成功…」）。
  final String reason;
}

/// T2 卸载结果（T2-6，对应 Kotlin `ToolchainResetResult`）。
class SandboxBuildSuiteResetResult {
  const SandboxBuildSuiteResetResult({
    required this.ok,
    required this.ready,
    required this.installDir,
    required this.removed,
    required this.failed,
    required this.freedBytes,
    required this.missing,
    required this.message,
  });

  /// 全部删除项成功 **且** 卸载后 `status().ready == false`。
  final bool ok;

  /// 卸载后重新探测的 ready（正常应为 false；true 说明有残留）。
  final bool ready;

  /// T2 安装目录（宿主绝对路径）。
  final String installDir;

  /// 实际删掉的路径清单（沙箱视角，如 `/opt/t2`）。
  final List<String> removed;

  /// 删除失败项（空 = 干净卸载）。
  final List<SandboxResetFailure> failed;

  /// **实测**释放字节数（删前占用 − 删后占用），不是估算。
  final int freedBytes;

  /// 卸载后仍缺失的项（正常 = 三项全缺 ⇒ 下次激活会重新安装）。
  final List<String> missing;

  /// 给人看的一句话（含失败原因 / 注意事项）。
  final String message;

  factory SandboxBuildSuiteResetResult.fromMap(Map<dynamic, dynamic> raw) {
    return SandboxBuildSuiteResetResult(
      ok: raw['ok'] == true,
      ready: raw['ready'] == true,
      installDir: (raw['installDir'] as String?) ?? '',
      removed: ((raw['removed'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      failed: ((raw['failed'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => SandboxResetFailure(
                path: (e['path'] as String?) ?? '',
                reason: (e['reason'] as String?) ?? '',
              ))
          .toList(growable: false),
      freedBytes: (raw['freedBytes'] as num?)?.toInt() ?? 0,
      missing: ((raw['missing'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      message: (raw['message'] as String?) ?? '',
    );
  }
}

/// T2 激活结果。
class SandboxActivationResult {
  const SandboxActivationResult({
    required this.ok,
    required this.message,
    required this.alreadyReady,
    required this.ready,
  });

  final bool ok;
  final String message;

  /// 已经装过、直接复用的（不是本次装的）。
  final bool alreadyReady;

  final bool ready;
}