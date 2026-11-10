import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:heracles_backend/heracles_backend.dart' as hb;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/attachment.dart';
import '../models/jev.dart';
import '../models/message.dart';
import '../models/model_capabilities.dart';
import '../models/settings.dart';
import '../models/workspace.dart';
import 'local_agent.dart';
import 'global_memory.dart';
import 'memory_service.dart';
import 'session_store.dart';

/// **权限拉起的去向**（B2，2026-10-30）—— 宿主 `requestPermission` 的
/// `action` 字段（只增字段，旧调用点仍只读 `ok`）。
enum PermissionAction {
  /// 已弹/已发起系统授权框（结果要等回前台重新查）。
  requested,

  /// 系统不再弹框（永久拒绝 / 只能手动开）⇒ 打开了对应的系统设置页。
  settingsOpened,

  /// 拉起前就已经授予/可用，没有上系统界面。
  alreadyGranted,

  /// 宿主没回 action（旧版宿主 / 测试通道）—— 如实标未知，不猜。
  unknown;

  static PermissionAction parse(String? raw) => switch (raw) {
    'requested' => PermissionAction.requested,
    'settings_opened' => PermissionAction.settingsOpened,
    'already_granted' => PermissionAction.alreadyGranted,
    _ => PermissionAction.unknown,
  };

  /// 落盘/日志用的稳定标识（只许往后加，不许改名 —— 与全仓枚举铁律一致）。
  String get wireName => switch (this) {
    PermissionAction.requested => 'requested',
    PermissionAction.settingsOpened => 'settings_opened',
    PermissionAction.alreadyGranted => 'already_granted',
    PermissionAction.unknown => 'unknown',
  };
}

/// **一次权限拉起的结果**（B2，2026-10-30）。
///
/// `{ok, action, granted}` 的可诊断形态：`ok=false` 时 [error] 给宿主
/// 人话原因（如「厂商专属权限」）；[granted] 是**拉起前**的真实状态，
/// 用户点完回到 App 后要重新查 [AgentBridge.devicePermissions] 才是权威。
class PermissionLaunchResult {
  const PermissionLaunchResult({
    required this.ok,
    required this.action,
    required this.granted,
    this.error,
  });

  const PermissionLaunchResult.notSupported([String? error])
    : ok = false,
      action = PermissionAction.unknown,
      granted = false,
      error = error ?? '宿主未实现 requestPermission';

  final bool ok;
  final PermissionAction action;
  final bool granted;
  final String? error;

  @override
  String toString() =>
      'PermissionLaunchResult(ok: $ok, action: ${action.wireName}, '
      'granted: $granted${error == null ? '' : ', error: $error'})';
}

/// Flutter → Kotlin 的桥（`15-前端选型与通道协议.md` §3.1）。
///
/// ## 为什么核心逻辑不在这里
///
/// `AgentLoop` / `Session` / `PrefixBuilder` 是**已验证的资产**
/// （66 项测试 + 实测 06/07/08/09/10），且缓存纪律（铁律 1）
/// 在 Kotlin 层由**类型**保障。Dart 只做展示与输入。
///
/// ## 概念模型（2026-10-10 修正）
///
/// ```
/// 工作区 = 用户【选择的一个已有文件夹】
///    ├── 在里面直接发消息 → 自动新建会话
///    └── 会话 ⋯重命名 / 🗑删除 / ⭐收藏
/// ```
class AgentBridge {
  AgentBridge({ScopedMemoryService? memoryService})
      : _memory = memoryService ?? ScopedMemoryService() {
    _installOpenSessionHandler();
  }

  /// **三作用域记忆服务**（2026-10-29）。
  ///
  /// ## 为什么这里持有一个实例而不是每次 `const GlobalMemory()`
  ///
  /// 旧 N7 五个方法固定全局、走 `memory.read/append/clear` 三个原语；
  /// 现在要能按 scope 读写，且增删改必须走 `memory.userEdit`（Kotlin 是唯一
  /// 写者）。[ScopedMemoryService] 内部有**按路径的写队列**（同一路径的
  /// "读-判-淘汰-追加"事务必须串行），每次新建实例会丢这层串行保证 ——
  /// 所以桥里持有一个。
  ///
  /// 测试可注入假服务（`AgentBridge(memoryService: ...)`）。
  final ScopedMemoryService _memory;

  /// 按 scope 组装寻址（session 才带 sid；global 两者都不带）。
  static hb.MemoryAddress _addressOf({
    required hb.MemoryScope scope,
    String? sessionId,
    String? workspacePath,
  }) =>
      hb.MemoryAddress(
        scope: scope,
        sessionId: scope == hb.MemoryScope.session ? sessionId : null,
        workspacePath: scope == hb.MemoryScope.global ? null : workspacePath,
      );

  static const _channel = MethodChannel('heracles/command');

  // ★ `heracles/events` 的 EventChannel 已于 2026-10-22 **删除**。
  //
  // 那个通道的 Kotlin 侧 handler 随 `AgentBridge.kt` 一起消失，留着它就是
  // 一条永远静默的订阅（界面会永远停在"正在生成…"）。事件改由 `backend`
  // 的 `HeraclesAgent` 在**同一进程内**产出，见 `_localEvents`。
  //
  // ⚠️ 不要把这条通道加回来"以防万一"：静默无事件的流比明确没有流更难排查。

  /// **上一次 [fetchModels] 读到的模型能力映射**（2026-10-14 重做）。
  ///
  /// `模型 id → 能力`。用哪个模型就取哪条 —— **不能取全局最大值**
  ///（一个 Key 下 32K 与 1M 的模型混在一起，取最大值会让小模型
  /// 显示错误上限 → 压缩永不触发 → 请求超限）。
  Map<String, ModelCapabilities> _lastFetchedCaps = const {};
  Map<String, ModelCapabilities> get lastFetchedCaps => _lastFetchedCaps;

  /// 取某个模型的能力（没拉到过返回 null）。
  ModelCapabilities? capabilitiesOf(String modelId) =>
      _lastFetchedCaps[modelId];

  // ------------------------------------------------------------ 实时事件

  /// agent 运行过程的实时事件流。
  ///
  /// ## 为什么是流而不是回调
  ///
  /// 一轮 agent 会产出多个事件（轮开始 → 原始输出 → 工具开始 → 工具结束 →
  /// … → 最终回答），请求-响应模式无法表达"持续产出"
  /// （`15-前端选型与通道协议.md` §3.1）。
  ///
  /// ## 与 [run] 的关系
  ///
  /// 两者**并行**：这个流负责"边跑边显示"，而 [run] 仍然
  /// `await` 到完整 `AgentRunResult`。**流丢了也不影响最终结果** ——
  /// 因此 UI 必须在 `run` 返回后仍以返回值为准补齐界面，
  /// 不能假设一定收全过事件。
  ///
  /// ## 使用
  ///
  /// ```dart
  /// final sub = _bridge.events.listen((e) => setState(() => ...));
  /// // 记得在 dispose 里 sub.cancel()
  /// ```
  ///
  /// 该流是**广播流**（`receiveBroadcastStream` 本身即广播，
  /// `map` 会保留这一性质），因此多个 widget 可以同时监听 ——
  /// 会话区与将来的调试面板互不干扰。
  ///
  /// 每次访问本 getter 都会**新建一条平台订阅**，
  /// 调用方应只订阅一次并保存 `StreamSubscription`。
  ///
  /// ## ★ 2026-10-22：事件来源从 EventChannel 改为**进程内流**
  ///
  /// 重构把编排从 Kotlin 搬进了 Dart（`backend/`）。原来的
  /// `EventChannel('heracles/events')` **没有原生实现了**（那个 handler
  /// 随 `AgentBridge.kt` 一起删除）⇒ 继续听它就是一个永远静默的流，
  /// 界面会永远停在"正在生成…"。
  ///
  /// 现在的事件来自 `LocalAgentExecutor`（同一个 VM 内），不需要跨进程序列化。
  ///
  /// ⚠️ **铁律不变**：事件流可能丢（消费端提前取消/重建），
  /// UI 仍必须以 [run] 返回的 `AgentRunResult` 为准补齐界面。
  Stream<AgentEvent> get events => _localEvents.stream;

  /// 进程内事件的广播出口（**静态**：`AgentBridge` 会被多处置新，
  /// 而事件流必须全局唯一 —— 否则 UI 订阅的实例与真正在跑的实例不是同一个，
  /// 事件全丢）。
  static final StreamController<AgentEvent> _localEvents =
      StreamController<AgentEvent>.broadcast();

  /// **把进程内事件推给所有订阅者**（由 [run] 的事件泵调用）。
  static void emitLocalEvent(AgentEvent e) {
    // ★ 2026-11-04：顺手把 `context_updated` 帧里的**窗口上限**记下来（含落盘）。
    //
    // 为什么必须在这里记：环图/用量抽屉的上限此前**只活在本次进程里**
    // ——`contextLimitTokens()` 读的是静态 `_lastContextLimit`，而它只在
    // `run()` 收尾时被赋值。于是「装完新版/杀进程后重新打开旧会话」
    // 上限立刻变回 -1，顶栏与抽屉都显示 `—`（用户 2026-11-04 11:11 报的就是它）。
    // 帧是**后端权威值**（它自己算压缩线用的同一个数），落盘后重开也有数。
    final lim = e.limit;
    if (e.type == AgentEvent.kContextUpdated && lim != null && lim > 0) {
      _rememberContextLimit(lim, e.limitSource);
    }
    // ★ 2026-11-06：记住"上一次真实输入 token"（= 分项之和，后端按真值等比放大过）。
    //   为什么必须记：新一轮开始时 backend 的 `state.usages` 是空的，压缩决策只能
    //   退回字符估算（低估 2.5~3.5 倍）⇒ 真机出现"上下文 122%、压缩从不触发"。
    if (e.type == AgentEvent.kContextCompressed) {
      // ★ 2026-11-08：压缩事件**落盘**。界面提示是瞬态（换会话就清），
      //   而"到底压过几次、压了多少"必须能回看 —— 否则用户永远只能猜。
      debugPrint('[compact] before=${e.beforeTokens} after=${e.afterTokens} '
          'msgs=${e.beforeMessages}->${e.afterMessages}');
      unawaited(_persistCompactRow(e));
    }
    if (e.type == AgentEvent.kContextUpdated) {
      final bd = e.breakdown;
      if (bd != null && bd.isNotEmpty) {
        final sum = bd.values.fold<int>(0, (a, v) => a + v);
        if (sum > 0) _rememberPromptTokens(sum);
      }
    }
    if (!_localEvents.isClosed) _localEvents.add(e);
  }

  /// 记下窗口上限（内存 + 落盘）。**只在值变化时**写盘，避免每轮一次 IO。
  static void _rememberContextLimit(int limit, String? source) {
    if (limit <= 0) return;
    final changed = limit != _lastContextLimit || source != _lastContextLimitSource;
    _lastContextLimit = limit;
    if (source != null && source.isNotEmpty) _lastContextLimitSource = source;
    if (!changed) return;
    // 落盘失败不影响任何功能（只是下次启动又会显示 —，不静默改语义）。
    unawaited(() async {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setInt(_contextLimitKey, limit);
        final s = _lastContextLimitSource;
        if (s.isNotEmpty) await p.setString(_contextLimitSourceKey, s);
      } catch (_) {
        // 忽略
      }
    }());
  }

  /// **仅测试**：把用量相关的静态缓存清回"没跑过"。
  ///
  /// 为什么必须有：`_lastFrozenTokens` / `_lastContextLimit` / `_lastContextBreakdown`
  /// 都是**进程级静态**（与 `_localEvents` 同理，用量必须全局唯一）。
  /// 静态值会在同一个测试进程的用例之间**串味** —— 前一条用例设过的上限
  /// 会让后一条的"未知应为 -1"断言拿到旧值。测试必须能显式重置。
  @visibleForTesting
  static void debugResetUsageCache() {
    _lastFrozenTokens = -1;
    _lastContextBreakdown = const <String, int>{};
    _lastContextLimit = -1;
    _lastContextLimitSource = '';
  }

  /// 窗口上限落盘的键（跨进程重启仍可读）。
  /// **自动压缩阈值**（`/autocompact 0.9` 写进来；0.05~0.95 之外忽略）。
  ///
  /// 存 `SharedPreferences`：阈值是**用户偏好**，跨重启要还在。
  /// 读不到 = 用 backend 契约默认（`ContractCompaction.autoCompactThreshold`）。
  static const String _autoCompactKey = 'heracles.autocompact_threshold';

  /// 上一次真实输入 token 的**同步缓存**（`local_agent` 在非 async 处读它）。
  ///
  /// ⚠️ 必须**按会话**成立：`_knownPromptSession` 记录它属于哪个会话，
  /// 换会话就归零 —— 否则新会话首轮会被上个会话的体积顶过 85% 线而白压一次。
  static int knownPromptTokens = 0;
  static String _knownPromptSession = '';
  static String _activeSessionId = '';
  static String _activeWorkspacePath = '';

  /// **对外入口**：只有"当前会话"的已知体积才算数（会话切换后自动为 0）。
  static int get knownPromptTokensForActiveSession =>
      _knownPromptSession == _activeSessionId ? knownPromptTokens : 0;
  static const String _knownPromptKey = 'heracles.last_prompt_tokens';

  /// **「使用独立发送按钮」**（2026-11-08 用户要求，默认开）。
  ///
  /// 开 ⇒ 键盘回车插入换行，发送只走右下按钮；
  /// 关 ⇒ 回旧行为（回车即发送）。
  /// 存 prefs：跨重启要还在；`separateSendButtonForUi` 是同步读的入口。
  static bool separateSendButton = true;
  static const String _separateSendKey = 'heracles.separate_send_button';

  /// 同步读（UI 在 build 里用）。
  bool get separateSendButtonForUi => separateSendButton;

  static Future<void> loadSeparateSendButton() async {
    try {
      final p = await SharedPreferences.getInstance();
      separateSendButton = p.getBool(_separateSendKey) ?? true;
    } catch (_) {}
  }

  static Future<void> writeSeparateSendButton(bool v) async {
    separateSendButton = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_separateSendKey, v);
    } catch (_) {}
  }

  /// 把一次**自动压缩**写进会话 JSONL（`role: compact`, `auto: true`）。
  ///
  /// 只追加、不改历史：原始消息一个字节都不动（append-only 铁律）。
  /// 写失败只打日志、绝不打断 run —— 观测是附加品，不能反噬执行。
  static Future<void> _persistCompactRow(AgentEvent e) async {
    final sid = _activeSessionId;
    final ws = _activeWorkspacePath;
    if (sid.isEmpty || ws.isEmpty) return;
    try {
      // 静态事件路径里没有实例的 _storeFor 缓存 —— 直接建一个即可
      final store = SessionStore(workspaceRoot: ws);
      await store.appendMessage(sid, {
        'role': 'compact',
        'auto': true,
        'beforeTokens': e.beforeTokens,
        'afterTokens': e.afterTokens,
        'beforeMessages': e.beforeMessages,
        'afterMessages': e.afterMessages,
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (err) {
      debugPrint('[compact] persist failed: $err');
    }
  }

  static void _rememberPromptTokens(int v) {
    if (v <= 0) return;
    final sid = _activeSessionId;
    // 没有会话 id 时**不记**：宁可不优化，也不许把别的会话的体积带过来。
    if (sid.isEmpty) return;
    knownPromptTokens = v;
    _knownPromptSession = sid;
    unawaited(() async {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setInt('$_knownPromptKey.$sid', v);
      } catch (_) {}
    }());
  }

  /// 从 prefs 刷新缓存（run 开始时调一次）。
  /// 刷新"上一次真实输入 token"缓存 —— **按会话**（别的会话的值绝不复用）。
  static Future<void> refreshKnownPromptTokens(String sessionId) async {
    _activeSessionId = sessionId;
    _knownPromptSession = sessionId;
    knownPromptTokens = 0;
    if (sessionId.isEmpty) return;
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getInt('$_knownPromptKey.$sessionId') ?? 0;
      if (v > 0) knownPromptTokens = v;
    } catch (_) {}
  }

  /// /autocompact 的**同步缓存**（local_agent 在非 async 处读它）。
  static double? autoCompactOverride;

  /// 从 prefs 刷新缓存（app 启动 / 每次 run 前调一次即可）。
  static Future<void> refreshAutoCompactOverride() async {
    autoCompactOverride = await readAutoCompactThreshold();
  }

  static Future<double?> readAutoCompactThreshold() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getDouble(_autoCompactKey) ?? p.getInt(_autoCompactKey)?.toDouble();
      if (v == null) return null;
      if (v <= 0.05 || v >= 0.95) return null;
      return v;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> writeAutoCompactThreshold(double v) async {
    if (v <= 0.05 || v >= 0.95) return false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_autoCompactKey, v);
      return true;
    } catch (_) {
      return false;
    }
  }

  static const String _contextLimitKey = 'heracles.context_limit';
  static const String _contextLimitSourceKey = 'heracles.context_limit_source';

  /// 把平台通道的 Map 转成 `Map<String, dynamic>`。
  ///
  /// ⚠️ **生产路径已不再用它**（事件改走进程内流，不再过通道）。
  /// 保留是因为 `AgentEvent.fromMap` 仍然是 UI 的**事件词表契约** ——
  /// `agent_event_channel_test.dart` 用它验证"序列化后能原样解回来"，
  /// 那条测试锁的是 UI 认识的字段集合，与传输方式无关。
  // ignore: unused_element
  static Map<String, dynamic> _castMap(dynamic e) =>
      (e as Map<dynamic, dynamic>).cast<String, dynamic>();

  // ------------------------------------------------------------ 通知点击定位会话

  /// **Kotlin → Dart：用户点了完成通知，要求打开对应会话**（2026-10-19）。
  ///
  /// 此前只有 EventChannel 的"事件流"方向；这条是**命令回调**方向。
  /// 广播流 ⇒ 任何时候订阅都不会错过（页面重建也不丢；冷启动的请求由
  /// [consumePendingOpenSession] 兜底）。
  static final StreamController<Map<String, String>> _openSessionCtl =
      StreamController<Map<String, String>>.broadcast();
  static bool _openHandlerInstalled = false;

  static Stream<Map<String, String>> get openSessionRequests =>
      _openSessionCtl.stream;

  /// **Kotlin → Dart：刚登记了一个新工作区**（2026-11-02 T0）。
  ///
  /// ## 为什么需要这条反方向通知
  ///
  /// SAF 选择器期间 Activity 被系统回收时，Flutter 引擎也会一起重建 ⇒
  /// **Dart isolate 是全新的**：原来那个 `await pickWorkspace()` 早就不存在了。
  /// 新的 Dart 应用启动时会先 `listWorkspaces()`（此时新目录还没登记完），
  /// 几百毫秒后 Kotlin 才在 `onActivityResult` 里把目录写进登记表 ——
  /// 界面上的列表已经刷过去了，用户会以为"又没选上"。
  ///
  /// ⇒ 宿主登记成功后推一条 [hb.ContractFolderPicker.addedPushMethod]，
  /// 界面收到就重载列表。旧宿主不推 ⇒ 只是少一次刷新，不报错。
  static final StreamController<Map<String, dynamic>> _workspaceAddedCtl =
      StreamController<Map<String, dynamic>>.broadcast();

  static Stream<Map<String, dynamic>> get workspaceAdded =>
      _workspaceAddedCtl.stream;

  void _installOpenSessionHandler() {
    if (_openHandlerInstalled) return;
    _openHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openSession') {
        final raw = call.arguments;
        final args = raw is Map ? raw.cast<dynamic, dynamic>() : const {};
        _openSessionCtl.add({
          'sessionId': (args['sessionId'] as String?) ?? '',
          'workspacePath': (args['workspacePath'] as String?) ?? '',
        });
      } else if (call.method == hb.ContractFolderPicker.addedPushMethod) {
        final raw = call.arguments;
        final args = raw is Map
            ? raw.cast<String, dynamic>()
            : const <String, dynamic>{};
        _workspaceAddedCtl.add(args);
      }
      return null;
    });
  }

  /// **冷启动兜底**：Kotlin 在 Dart 还没就绪时先把"要打开的会话"存着。
  /// 返回 null = 没有待处理请求（最常见）。
  Future<Map<String, String>?> consumePendingOpenSession() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('consumePendingOpen');
      if (m == null) return null;
      final sid = (m['sessionId'] as String?) ?? '';
      if (sid.isEmpty) return null;
      return {
        'sessionId': sid,
        'workspacePath': (m['workspacePath'] as String?) ?? '',
      };
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// **V0.4 T0-2 后台保活引导**（2026-11-02，只引导/只读，不改系统设置）。
  ///
  /// 三件事：
  /// · [requestIgnoreBatteryOptimizations]：拉起系统"忽略电池优化"确认页；
  /// · [autostartGuide]：返回 OEM 自启路径文案（**不自动跳转**）；
  /// · [processKilled] / [consumeProcessKilled]：上次 run 是否被系统停止（如实提示，
  ///   不假装继续；提示消费后清标记）。
  ///
  /// ★ 返回 `Future<bool?>`（2026-11-02 二次裁定）：三态**不许混** ——
  /// · `null` = **当前版本不支持**（旧宿主没有这条通道，`MissingPluginException`）⇒
  ///   UI 显示"当前版本不支持"，**不该引导用户"再试一次"**（试多少次都一样）；
  /// · `false` = 没生效（`PlatformException` / 用户在授权页取消）⇒ UI 显示
  ///   "没有生效，可再试"；
  /// · `true` = 系统页已拉起并确认。
  ///
  /// ## 为什么不许吞成 false
  ///
  /// 旧实现把 `MissingPluginException` 也返回 `false` —— 旧宿主上用户点"去授权"
  /// 会看到"没有生效，可再试"，于是反复重试一个**根本不存在的方法**。
  /// "环境不支持"与"这次没成功"是两种失败，给用户的话术必须不同。
  Future<bool?> requestIgnoreBatteryOptimizations() async {
    try {
      final ok = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return ok ?? false;
    } on MissingPluginException {
      // 通道都不在 ⇒ 不是"这次失败"，是"没有这个能力"
      return null;
    } on PlatformException {
      return false;
    }
  }

  /// OEM 自启引导（`{brand, path}`）；通道不支持 ⇒ null（UI 显示通用说明）。
  Future<({String brand, String path})?> autostartGuide() =>
      oemGuide('autostart');

  /// **MIUI 保活三件套引导**（2026-11-02，只给数据**不自动跳转** —— 契约红线）。
  ///
  /// [kind] ∈ `autostart`（自启动）/ `backgroundPopup`（后台弹出界面）/
  /// `lockScreenShow`（锁屏显示）。
  ///
  /// · **未知 kind 在 Dart 侧先行拒绝**（`ArgumentError`，通道零调用）——
  ///   拼错的 kind 打到宿主只会得到一句"未知方法"，排障绕远路；
  /// · 宿主认不出的品牌给**通用兜底文案**（明说没有统一入口），**不编路径**；
  /// · `null` = 不可用（`MissingPluginException`/`PlatformException`/宿主
  ///   `ok:false`/brand 或 path 为空）—— 半截数据当没有，UI 显示通用说明。
  Future<({String brand, String path})?> oemGuide(String kind) async {
    const kinds = <String>{'autostart', 'backgroundPopup', 'lockScreenShow'};
    if (!kinds.contains(kind)) {
      throw ArgumentError.value(
          kind, 'kind', '未知的引导类型（必须是 ${kinds.toList()..sort()} 之一）');
    }
    try {
      final m = await _channel
          .invokeMapMethod<String, dynamic>('oemGuide', {'kind': kind});
      if (m == null || m['ok'] != true) return null;
      final brand = (m['brand'] as String?) ?? '';
      final path = (m['path'] as String?) ?? '';
      if (brand.isEmpty || path.isEmpty) return null;
      return (brand: brand, path: path);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// **保活状态聚合查询**（2026-11-02，只读 —— 不拉系统页、不改设置）。
  ///
  /// 对应通道 `keepaliveStatus`：Kotlin 侧**真实查**（前台服务运行位 /
  /// `PowerManager.isIgnoringBatteryOptimizations`），并附 MIUI 口径提醒
  /// （省电策略「无限制」≠ 系统电池优化白名单，真机实测存在）。
  ///
  /// ## 缺的不编
  ///
  /// · **字段级**：宿主没给的字段保持 null（[`KeepaliveStatus`] 全字段可空）；
  /// · **整体级**：`MissingPluginException`/`PlatformException`/宿主 `ok:false`
  ///   ⇒ 返回 null —— 状态**不可用**，UI 显示通用说明，**不许编一个全 false 的
  ///   状态假装查到了**。
  Future<KeepaliveStatus?> keepaliveStatus() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('keepaliveStatus');
      if (m == null || m['ok'] != true) return null;
      return KeepaliveStatus.fromMap(m);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 上次 run 是否被系统停止；`killedAt` = 毫秒时间戳（0 = 无记录）。
  Future<({bool killed, int killedAt})> processKilled() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('processKilled');
      if (m == null) return (killed: false, killedAt: 0);
      return (
        killed: (m['killed'] as bool?) ?? false,
        killedAt: (m['killedAt'] as int?) ?? 0,
      );
    } on MissingPluginException {
      return (killed: false, killedAt: 0);
    } on PlatformException {
      return (killed: false, killedAt: 0);
    }
  }

  /// **自动化任务真调度**（V0.4 T1-5，2026-11-02）。
  ///
  /// Kotlin 侧用 **AlarmManager** 注册周期闹钟（无新依赖）；到点**只发通知 + 写 pending 标记**，
  /// **不假装跑了 agent** —— 真正执行由 App 打开后 Dart 侧发起（进程死可恢复）。
  ///
  /// · [saveAutomationTasks]：保存任务清单（JSON 字符串）并重注册闹钟；
  /// · [loadAutomationTasks]：读回任务清单；
  /// · [consumePendingAutomation]：取出"到点待执行"的任务 id 列表（并清空）。
  Future<bool> saveAutomationTasks(String tasksJson) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'automationSave',
        {'tasks': tasksJson},
      );
      return m?['ok'] == true;
    } on MissingPluginException {
      return false; // 旧宿主没有该方法 ⇒ 如实失败
    } on PlatformException {
      return false;
    }
  }

  Future<String> loadAutomationTasks() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('automationLoad');
      return (m?['tasks'] as String?) ?? '[]';
    } on MissingPluginException {
      return '[]';
    } on PlatformException {
      return '[]';
    }
  }

  Future<List<String>> consumePendingAutomation() async {
    try {
      final m = await _channel
          .invokeMapMethod<String, dynamic>('automationConsumePending');
      return ((m?['taskIds'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// 提示消费后清标记（避免每次打开都提示）。
  Future<void> consumeProcessKilled() async {
    try {
      await _channel.invokeMethod('consumeProcessKilled');
    } on MissingPluginException {
      // 旧宿主没有这个方法 ⇒ 忽略
    } on PlatformException {
      // 忽略
    }
  }

  // ------------------------------------------------------------ 用量与上下文

  /// ★ 2026-10-22：这两个数**改由进程内 run 记账**（旧的 `usageInfo`
  /// 通道方法随 Kotlin 后端删除，一直返回 -1 ⇒ 顶栏 `— 0%`、侧栏"不可用"）。
  ///
  /// 静态：`AgentBridge` 会被多处 new，用量必须全局唯一（与 `_localEvents` 同理）。
  static int _lastFrozenTokens = -1;

  /// 上一次 run 的上下文构成（C5，2026-10-24；估算）。空 = 没有 run 过。
  static Map<String, int> _lastContextBreakdown = const <String, int>{};
  static int _lastContextLimit = -1;

  /// 上限的**来源说明**（「服务端上报」/「按契约默认值」…）。与上限一起落盘。
  static String _lastContextLimitSource = '';

  /// 上一次运行的**冻结区** token；`-1` = 还没跑过任何一次。
  ///
  /// 冻结区 = 系统提示词 + 工具定义 + 工具协议，会话内逐字节不变
  /// （`02-契约规范.md` §1）。
  ///
  /// ⚠️ 口径：**首轮请求的 promptTokens**（provider 真实上报，不是估算）。
  /// 首轮历史只有这一条用户消息，所以它 ≈ 冻结区 + 一句用户输入 ——
  /// 比旧实现的 `TextMath` 估算**更真**（估算曾 40% 高估）。
  Future<int> lastFrozenTokens() async => _lastFrozenTokens;

  /// **上下文构成**（C5，2026-10-24）：system / tools / history（估算 token）。
  /// 空 map = 还没跑过 —— 调用方退回旧图例，不得显示 0。
  Future<Map<String, int>> lastContextBreakdown() async =>
      _lastContextBreakdown;

  /// 上下文上限（token）。`<= 0` = 未知（不画进度条）。
  ///
  /// 来源优先级（2026-11-04 补）：
  /// 1. 本次进程里收到过的 `context_updated` 帧 / 最近一次 run 收尾；
  /// 2. **上次进程落盘的值**（`heracles.context_limit`）—— 修「重开旧会话变回 `—`」。
  Future<int> contextLimitTokens({required bool isCloud}) async {
    if (_lastContextLimit > 0) return _lastContextLimit;
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getInt(_contextLimitKey) ?? -1;
      if (v > 0) {
        _lastContextLimit = v;
        _lastContextLimitSource = p.getString(_contextLimitSourceKey) ?? '';
      }
    } catch (_) {
      // 读不到就保持"未知"（不猜）
    }
    return _lastContextLimit;
  }

  // ------------------------------------------------------------ 工作区

  /// **选一个已有文件夹**作为工作区（不是"创建新目录"）。
  ///
  /// 返回 null 表示用户取消，或选的位置没有本地路径
  /// （例如选了网盘 —— 那时无法用普通 File IO 写入）。
  /// ## 为什么要带 requestId + 超时（2026-11-02 T0 修复）
  ///
  /// SAF 选择器在前台时，本 Activity 可能被系统回收重建。旧实现有两个叠加的
  /// 死角，合起来就是用户报的"选完文件夹返回 ⇒ 黑屏"：
  ///
  /// 1. Kotlin 侧 pending 回调挂在 **Activity 实例**上 ⇒ 重建后新实例没有
  ///    收件人，选好的结果被静默丢弃；
  /// 2. Dart 侧这里**没有超时** ⇒ 上面那条一旦发生，这个 `await` 永久挂起，
  ///    UI 就那么卡着。
  ///
  /// 现在：
  /// - 每次调用生成 [requestId]，Kotlin 用它做**进程级**登记的键（Activity
  ///   重建后仍能对上）；
  /// - 等待超过 [hb.ContractFolderPicker.timeoutSeconds] 就**先回收**结果
  ///   （[_consumePickWorkspaceResult]）—— 因为 Kotlin 可能在我们超时之后
  ///   才把结果交回来，直接报失败会把"其实选成功了"误判成失败；
  /// - 回收不到才抛 [AgentBridgeException]，带上人话提示（重试 / 换默认工作区）。
  ///
  /// [timeout] 仅供测试注入更短的超时；生产不传，用契约常量。
  ///
  /// ## ★★ 超时只计**前台**时间（2026-11-02 真机纠错）★★
  ///
  /// 第一版直接 `future.timeout(45s)`，真机一测就露馅：
  ///
  /// ```
  /// 18:27:25.936  startActivityForResult 已发出
  /// 18:28:35.514  onActivityResult req=18502 res=-1 data=true   ← 结果好好的
  /// ```
  ///
  /// 系统选择器在前台停留了 **70 秒**（logcat：`visible->invisible(70217ms)`），
  /// 于是 45 秒一到 Dart 就报「选择结果已丢失」，可用户**还在挑目录**。
  /// 结果最后也真的登记成功了 —— UI 却在撒谎说失败。
  ///
  /// 计时器不该把"用户在系统选择器里挑文件夹"算作"我们的等待"。
  /// ⇒ 改成 [_ForegroundDeadline]：App 一进后台（选择器盖住我们）就停表，
  /// 回到前台再接着走。45 秒的真实含义变成「用户对着我们自己的界面干等 45 秒」，
  /// 那才是需要兜底的情况。
  Future<Map<String, dynamic>?> pickWorkspace({Duration? timeout}) async {
    // requestId 只用于**同一次调用**的配对，不需要全局唯一性，微秒时间戳足够
    // （同一时刻不可能发起两次选目录）。
    final requestId = 'pk_${DateTime.now().microsecondsSinceEpoch}';
    final limit =
        timeout ?? const Duration(seconds: hb.ContractFolderPicker.timeoutSeconds);

    final done = Completer<Map<String, dynamic>?>();
    final deadline = _ForegroundDeadline(limit, () {
      if (!done.isCompleted) {
        done.completeError(TimeoutException('pickWorkspace', limit));
      }
    })..start();

    // 通道回包 → 完成等待。**不 await**：先让 deadline 与回包并行跑。
    _channel
        .invokeMapMethod<String, dynamic>('pickWorkspace', {
          'requestId': requestId,
        })
        .then(
      (m) {
        if (!done.isCompleted) done.complete(m?.cast<String, dynamic>());
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
    );

    try {
      return await done.future;
    } on TimeoutException {
      // 超时 ≠ 失败：先问 Kotlin 要这次请求已产出的结果。
      final recovered = await _consumePickWorkspaceResult(requestId);
      if (recovered != null) return recovered;
      throw const AgentBridgeException(hb.ContractFolderPicker.timeoutMessage);
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    } on MissingPluginException {
      throw const AgentBridgeException('桥接未就绪');
    } finally {
      deadline.cancel();
    }
  }

  /// 取回某个 `requestId` 已完成但**没送达**的选择结果（超时后的补救）。
  ///
  /// 通道方法由 Kotlin 侧 `MainActivity` 提供；旧版本 App / 纯单测环境没有这个
  /// 方法 ⇒ [MissingPluginException]，返回 null 走超时错误分支，**不抛**。
  Future<Map<String, dynamic>?> _consumePickWorkspaceResult(
    String requestId,
  ) async {
    try {
      final m = await _channel
          .invokeMapMethod<String, dynamic>(hb.ContractFolderPicker.recoverMethod, {
            'requestId': requestId,
          })
          .timeout(
            const Duration(
              seconds: hb.ContractFolderPicker.recoverTimeoutSeconds,
            ),
          );
      return m?.cast<String, dynamic>();
    } catch (_) {
      // 回收本身失败不该盖住"超时"这个主因，交给上层给出超时提示。
      return null;
    }
  }

  /// 列出已登记的工作区（只返回文件夹仍存在的）
  Future<List<Map<String, dynamic>>> listWorkspaces() async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('listWorkspaces');
      return _maps(list);
    } on MissingPluginException {
      return const [];
    }
  }

  /// 从列表移除 —— **不删文件夹本身**
  Future<void> removeWorkspace(String path) async {
    try {
      await _channel.invokeMethod<bool>('removeWorkspace', {'path': path});
    } on MissingPluginException {
      // 忽略
    }
  }

  /// **登记内置「应用工作区」**（2026-10-17）—— 一个"能构建"的工作区。
  ///
  /// ## 为什么需要它（而且只能由 Kotlin 建）
  ///
  /// 编码层（构建 APK / 逆向）要求工作区 **App 与 shell 都能写**：
  /// 中间产物由 shell（Shizuku/Stellar）产出，插 dex / 对齐 / 读产物由 App 自己写。
  /// 真机实测（`测试机`，2026-10-17）只有一处同时满足：
  ///
  /// | 位置 | App 写 | shell 写 |
  /// |---|---|---|
  /// | 用户自己的 `/sdcard/Download/…` | ✗ `Permission denied` | ✓ |
  /// | `Android/data/<pkg>/files/**` | ✓ | ✓ |
  ///
  /// 而 [pickWorkspace]（SAF）**选不到** `Android/data`（Android 11+ 不允许浏览）。
  /// ⇒ 用户在侧边栏点这个入口，由 App 自己把那个目录登记成工作区。
  ///
  /// ## 诚实边界
  ///
  /// 该目录对用户**不完全可见**、**卸载即丢** —— 它是"可构建的沙箱"，
  /// 不是用户的项目目录。见 `26` §6.5 末尾的遗留。
  ///
  /// @return 登记后的工作区（形状同 [listWorkspaces] 的条目）；`null` = 建不出目录
  Future<Map<String, dynamic>?> ensureAppWorkspace() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('ensureAppWorkspace');
      return m?.cast<String, dynamic>();
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    } on MissingPluginException {
      throw const AgentBridgeException('桥接未就绪');
    }
  }

  // ------------------------------------------------------------ 会话
  //
  // ★★ 2026-10-22：会话 CRUD 从**通道**切到**进程内 `SessionStore`** ★★
  //
  // ## 为什么必须切（真机实测证据）
  //
  // 切之前 `listSessions` 走 `invokeListMethod('listSessions')`，而
  // `MainActivity` 已不再处理它 ⇒ 通道回 `{"ok": false, "error": "未知方法：listSessions"}`
  // ⇒ `invokeListMethod` 把那个 **Map 强转成 List** 时抛：
  //
  // ```
  // 读取工作区失败：type '_Map<Object?, Object?>' is not a subtype of
  // type 'List<dynamic>?' in type cast
  // ```
  //
  // 这是**真机上看到的第一条红字**（2026-10-22 14:31，设备 `e35e48c6`），
  // 后果是侧边栏永远空、连"发第一条消息"都进不去。
  //
  // ## 为什么能用同一个通道
  //
  // `SessionStore` 走 `heracles/device` 的 `fs.*`，那是**还活着**的通道
  // （`DeviceChannel` 17 个方法）。所以会话读写今天完全可用。
  //
  // ## 缓存
  //
  // `SessionStore` 与工作区绑定。`AgentBridge` 本身是无状态的（每次调用传路径），
  // 所以这里按 `路径|treeUri` 缓存实例 —— 键里带 treeUri 是因为同一个路径
  // 在 SAF 与 POSIX 下是不同的访问方式（漏了会拿错路由）。

  final Map<String, SessionStore> _sessionStores = {};

  SessionStore _storeFor(String workspacePath, String treeUri) {
    final key = '$workspacePath|$treeUri';
    return _sessionStores.putIfAbsent(
      key,
      () => SessionStore(workspaceRoot: workspacePath),
    );
  }

  Future<List<HSession>> listSessions(String workspacePath, {String treeUri = ''}) async {
    final store = _storeFor(workspacePath, treeUri);
    final metas = await store.listSessions();
    if (store.lastError != null) {
      // 读不出来**不静默返回空列表** —— 那会让用户以为"会话全丢了"。
      // 但也不抛（侧边栏是只读展示，抛了会整页红）。
      // 交给 UI 的空态 + 这个字段去排障。
      return const [];
    }
    return metas.map((m) => HSession.fromMap(m.toMap())).toList();
  }

  /// ★ 所有会话操作都必须带 [treeUri]（SAF 工作区的访问方式由它决定）。
  ///
  /// ⚠️ 今天 Dart 侧的 `SessionStore` 走 `heracles/device` 的 `fs.*`，
  /// 而 **Kotlin `DeviceFs` 自己按路径查登记表决定 SAF/POSIX 路由** ——
  /// 所以 `treeUri` 在 Dart 这一层只是保留参数（保持调用方签名不变），
  /// 不再需要手工往下传。留着它是因为 `workspace_drawer` 等调用方一直在传。
  Future<String?> createSession(
    String workspacePath,
    String title, {
    String treeUri = '',
  }) async {
    final store = _storeFor(workspacePath, treeUri);
    final id = await store.createSession(title);
    return id.isEmpty ? null : id;
  }

  /// **建一个新会话并把前缀消息灌进去**（2026-10-13，回答的「新会话分支」）。
  ///
  /// ## 为什么不是"在原会话上开分支"
  ///
  /// 会话必须**严格 append-only**（铁律 1）：append-only 命中 90–99%
  /// 可依赖，而分支只有 **25–105%、不可预测**（ADR-001）。
  /// 所以"分支"落地成**新建会话 + 复制前缀** —— 新会话从一开始
  /// 就是干净的 append-only 流。代价是上下文要重新预填充一次。
  Future<String?> seedBranch({
    required String workspacePath,
    required String title,
    required List<Map<String, String>> entries,
    String treeUri = '',
  }) async {
    final store = _storeFor(workspacePath, treeUri);
    // `entries` 是 `List<Map<String, String>>`（UI 侧的形状），
    // 而 `SessionStore.seedBranch` 吃 `List<Map<String, dynamic>>` ——
    // 这里做**显式**转换（不是隐式 upcast），避免砖头式泛型报错。
    final rows = entries
        .map((e) => <String, dynamic>{for (final kv in e.entries) kv.key: kv.value})
        .toList();
    return store.seedBranch(rows, title: title);
  }

  Future<void> renameSession(
    String workspacePath,
    String sessionId,
    String title, {
    String treeUri = '',
  }) async {
    await _storeFor(workspacePath, treeUri).renameSession(sessionId, title);
  }

  Future<void> deleteSession(
    String workspacePath,
    String sessionId, {
    String treeUri = '',
  }) async {
    await _storeFor(workspacePath, treeUri).deleteSession(sessionId);
  }

  /// 切换收藏，返回新状态
  Future<bool> toggleStar(
    String workspacePath,
    String sessionId, {
    String treeUri = '',
  }) async =>
      _storeFor(workspacePath, treeUri).toggleStar(sessionId);

  /// ★ 读取一个会话的历史消息
  ///
  /// 返回原始行列表，由上层转成 UI 模型 —— 桥接层不猜 UI 的形状。
  Future<List<Map<String, dynamic>>> loadMessages(
    String workspacePath,
    String sessionId, {
    String treeUri = '',
  }) async =>
      _storeFor(workspacePath, treeUri).loadMessages(sessionId);

  /// 切换归档，返回新状态
  Future<bool> toggleArchive(
    String workspacePath,
    String sessionId, {
    String treeUri = '',
  }) async =>
      _storeFor(workspacePath, treeUri).toggleArchive(sessionId);

  // ------------------------------------------------------------ 运行

  /// 跑一次 agent。
  ///
  /// **[sessionId] 为 null 时，Kotlin 侧会【自动新建会话】** ——
  /// 这就是"在工作区里直接发消息"的行为，与桌面版一致。
  Future<AgentRunResult> run({
    required String workspacePath,
    required String request,
    required AppSettings settings,
    String? sessionId,
    String treeUri = '',
    List<HAttachment> attachments = const [],
  }) async {
    // 2026-11-06: refresh cached knobs before building the executor.
    // They are read synchronously elsewhere, and a stale 0 makes the
    // compaction decision blind to the real prompt size.
    await refreshAutoCompactOverride();
    await refreshKnownPromptTokens(sessionId ?? '');
    _activeWorkspacePath = workspacePath;
    final provider = settings.effectiveProvider;

    // ★★ 未配置 provider ⇒ **就地明确失败**（2026-10-18，ADR-035 S4）★★
    //
    // ## 为什么不能"兜底"（这是本段存在的全部理由）
    //
    // 改之前是 `null => 'local'`：没选/没配 provider 就**静默**当成"本地后端"。
    // 本地后端删除后 `'local'` 在 Kotlin 侧是 `error(...)` ⇒ 用户看到的会是
    // 一句**装配期异常**（"本地后端已删除…"），既看不懂也不知道该干什么。
    //
    // 所以这里**不兜底到任何后端**：宁可在进通道之前就停下，把
    // **下一步该做什么**直接说给用户（`_reportRunFailure` 会把这句话
    // 原样显示在会话里）。
    //
    // ⚠️ 三个都要拦：`provider == null`（一个都没有）、`baseUrl` 为空、
    //    `apiKey` 为空。**空 Key 绝不能发出去** —— 服务端只会回 401，
    //    用户得到的是"Key 不对"，而真因是"根本没配"。
    //    唯一例外是**自建/局域网端点**：它可能确实不需要 Key（内网自建中转），
    //    所以那种情况只要求 `baseUrl`。
    final needsKey = provider != null && !AppSettings.isLocalConfig(provider);
    if (provider == null ||
        provider.baseUrl.trim().isEmpty ||
        (needsKey && provider.apiKey.trim().isEmpty)) {
      throw const AgentBridgeException(
        '还没有可用的模型提供商：请到「设置 → 模型」里选一个云端提供商并填入 API Key，'
        '然后回到这里重发。',
      );
    }

    // ★ 协议分派（2026-10-14）：三协议真实支持（各有对应 Kotlin provider）
    //
    // | protocol | 进程内 BackendProvider |
    // |---|---|---|
    // | anthropic | BackendProvider.anthropic（x-api-key + /v1/messages）|
    // | openaiResponses | BackendProvider.openAiResponses（/v1/responses）|
    // | openaiChat | BackendProvider.openAiCompatible（/v1/chat/completions）|
    //
    // ★ 2026-10-22：这张表不再产出**字符串**形式的后端名 —— 编排在进程内，
    //   协议直接映射成枚举（见 `local_agent.dart`）。旧的"字符串 → Kotlin 分派"
    //   已随通道一起消失。

    // ★★ 编排改为**进程内 Dart**（`backend/`）★★
    //
    // 原来这里 `invokeMapMethod('runAgent', ...)` 打给 Kotlin。那个类已随
    // 5 个 Kotlin 模块一起删除，`MainActivity` 也不再处理 `runAgent`
    // ⇒ 继续走通道只会拿到 `{"ok": false, "error": "未知方法：runAgent"}`，
    // 而 `AgentRunResult.fromMap` 会把那个 map 解成"空结果"，
    // 用户看到的是一条**空回答**（最糟的假信息）。
    //
    // 现在：直接用 `LocalAgentExecutor` 在同一个 Dart VM 里驱动
    // `HeraclesAgent`。参数不再需要序列化，`apiKey` 也不会离开本进程。
    // ★★ 2026-10-23（修「提问现在不可用」）：每次 run 一个 `AskGate` ★★
    //
    // ## 之前断在哪
    //
    // 这里构造执行器时**没传 `askGate`** ⇒ backend 的 `ask_user` 工具
    // `isAvailable: () => askGate != null` 为 false ⇒ 工具直接告诉模型
    // "当前环境不支持向用户提问" —— 用户看到的即"提问不可用"。
    //
    // ## 为什么门禁放在桥接层创建
    //
    // 提问是**双向**的：工具挂起等回答（`askUser`），UI 提交答案（`replyAsk`）。
    // 两端必须拿到**同一个实例**。放在桥接层创建，`replyAsk` 通过静态字段
    // `_currentAskGate` 找到它（`AgentBridge` 会被多处置新，与事件流同理，
    // 实例字段会找错对象）。
    final askGate = LocalAskGate();
    // ★ 审批白名单（2026-10-24 接线）：
    //   · 种子 = 持久化的「始终允许」名单（SharedPreferences，跨启动有效）；
    //   · run 中用户点「本会话始终允许」⇒ [onAlwaysAllow] 立刻持久化 +
    //     gate 内部记账（同一 run 的后续调用不再问）。
    //   白名单在宿主侧（gate）判定，backend 的 `_ApprovalHook` 只管"要批谁"。
    askGate.seedAllowed(await alwaysAllowedTools());
    askGate.onAlwaysAllow = _rememberAlwaysAllow;
    final executor = (AgentBridge.executorFactoryForTest ??
            LocalAgentExecutor.new)(
      workspacePath: workspacePath,
      settings: settings,
      sessionStore: SessionStore(workspaceRoot: workspacePath),
      askGate: askGate,
    );
    // ★ V0.4 T0-2（2026-11-02）：注入"上次 run 被系统停止"的探针（构造后赋值 ——
    //   测试工厂类型只有 4 个参数，不能加构造参数）。
    executor.processKilledProbe = processKilled;
    executor.processKilledConsume = consumeProcessKilled;
    _currentAskGate = askGate;

    try {
      // ★ 附件必须在这里传下去（2026-10-23 修）：
      //   这一行曾经只传 request/sessionId，于是**图片在桥接层就被丢掉** ——
      //   用户上传的图永远到不了模型。现在照片/截图会一路走到 `UserMessage`
      //   的多模态内容块（压缩 + 视觉能力判断在 `LocalAgentExecutor` 里做）。
      final handle = await executor.run(
        request: request,
        sessionId: sessionId,
        attachments: attachments,
      );
      _currentHandle = handle;

      // 把执行器产出的事件搬到全局广播流上（UI 只订阅 `events`）。
      final pump = handle.events.listen(AgentBridge.emitLocalEvent);
      try {
        final r = await handle.result;
        // ★ 用量记账落地（2026-10-22）：顶栏"上下文占用"与侧栏读这两个数。
        //   冻结区 = 首轮 promptTokens（provider 真实上报）；
        //   上限 = 用户配置的模型上下文长度（`fetchModels` 从服务端读到的）。
        _lastFrozenTokens = executor.lastFrozenTokens;
        // ★ C5（2026-10-24）：构成统计供侧栏"构成"行使用（估算）。
        _lastContextBreakdown = executor.lastBreakdown;
        // ★ 与帧/抽屉同一口径（2026-10-29）：逐模型能力优先，
        //   见 [ModelProviderConfig.effectiveContextWindow]。
        // ★ 2026-11-04：**不要再用 -1 覆盖**已知值 —— provider 能力没拉到时
        //   （很常见：中转站没 /models 能力）这里原本会把帧刚记下的权威值抹成 -1，
        //   于是抽屉又变 `—`。现在只有拿到正数才更新，并且照样落盘。
        final fromProvider = provider.effectiveContextWindow;
        if (fromProvider > 0) {
          _rememberContextLimit(fromProvider, '服务端上报');
        }
        return r;
      } finally {
        // ★ 2026-10-25：**不再 `await` 这个 cancel**。
        //
        // 我们需要的保证是「cancel 之后事件不再投递给 UI」，而这条在
        // `cancel()` **被调用的那一刻**就已经生效（broadcast 流无缓冲队列，
        // 投递是同步的）。返回的 Future 只表示"取消操作收尾完成"，**完成时机
        // 未定义** —— 实测：在 `flutter_test` 的 fake-async 里它**永不完成**
        // （`testWidgets` 里 await 会一直挂到测试结束），于是 `run()` 的 Future
        // 永不 resolve ⇒ 界面永远停在"运行中"、结果永不渲染。
        // 也就是说：把它放在返回路径上，等于让"一次运行能不能收尾"取决于一个
        // 没有时序保证的 Future。
        //
        // 所以照旧调用 `cancel()`（订阅确实被摘掉），只是不让它挡住返回。
        // ⚠️ 这不是"为了测试放宽生产行为"：生产（真 async）里它本来就是
        //    立即完成的（对照实测），改动后生产可观测行为**不变**。
        //
        // ★ 2026-10-30（P0 插队发送）：**先让已排队的事件投递完再退订**。
        //   `StreamController` 的投递是异步的；`handle.result` 完成那一刻可能
        //   还有"收尾事件"排在队列里（例：插话未送达提示）。直接 `cancel()`
        //   会把它们丢掉 —— UI 看不到最后一条提示。让出一个事件循环即可清空
        //   已排队投递，代价是 run 返回晚一个微任务（可忽略）。
        await Future<void>.delayed(Duration.zero);
        unawaited(pump.cancel());
        _currentHandle = null;
      }
    } catch (e) {
      _currentHandle = null;
      throw AgentBridgeException('运行失败：$e');
    } finally {
      // 本轮结束（成功/失败/取消）⇒ 关闭提问门禁的"当前"指针。
      // 之后迟到的 `replyAsk` 会如实返回 false，而不是打进下一轮。
      if (identical(_currentAskGate, askGate)) _currentAskGate = null;
    }
  }

  /// 当前在跑的句柄（**唯一**取消入口）。
  LocalRunHandle? _currentHandle;

  /// ★ **测试缝**（2026-10-25）：注入替身执行器 —— mock 基建回家。
  ///
  /// 旧测试 mock 的是 **Kotlin 时代的通道**（`heracles/command` 的
  /// `runAgent` / `heracles/events`），内核迁移后这条传输已删除 ⇒ mock
  /// 永远不被调用、事件永远不出现。这个缝让测试注入假执行器，事件走
  /// **与生产同一条路径**（handle.events → [emitLocalEvent] → UI 订阅），
  /// 断言的 UI 行为不变。生产恒为 null（真 [LocalAgentExecutor]）。
  static LocalAgentExecutor Function({
    required String workspacePath,
    required AppSettings settings,
    required SessionStore sessionStore,
    hb.AskGate? askGate,
  })? executorFactoryForTest;

  /// **当前 run 的提问门禁**（2026-10-23）。
  ///
  /// 静态：`AgentBridge` 会被多处置新，而 UI 的 `replyAsk` 与真正在跑的
  /// `run()` 可能不是同一个实例 —— 与 `_localEvents` / token 记账同理。
  /// 一次只允许一个 run（事件流单 sink），所以"当前"是明确的。
  static LocalAskGate? _currentAskGate;

  /// ~keep~ 旧实现留档：以下是被替换掉的通道调用（勿重新启用）：
  ///
  /// ```dart
  /// final raw = await _channel.invokeMapMethod<String, dynamic>('runAgent', {
  ///   'workspacePath': workspacePath,
  ///   'request': request,
  ///   'sessionId': sessionId,
  ///   'treeUri': treeUri,
  ///   'backend': backend,
  ///   'baseUrl': provider.baseUrl,
  ///   'apiKey': provider.apiKey,
  ///   'modelName': provider.model,
  ///   'reasoningLevel': settings.reasoningLevel.wire,
  ///   'permission': settings.permission.name,
  ///   'maxTurns': settings.maxTurns,
  ///   'attachments': attachments.map((a) => {
  ///         'path': a.path, 'name': a.name, 'kind': a.kind.name,
  ///       }).toList(),
  /// });
  /// return AgentRunResult.fromMap(raw!);
  /// ```
  ///
  /// ⚠️ 参数里的 `reasoningLevel` / `permission` 今天**没有映射到 backend**
  /// （框架的 `ModelConfig` 有 `reasoningEffort`，审批三态还没接线）——
  /// 这是本轮明确的缺口，见 `docs/nextwork.md`，不要以为它们生效了。
  ///
  /// 更早的实现（供对照）：
  /// ```dart
  /// } on PlatformException catch (e) {
  ///   throw AgentBridgeException(e.message ?? e.code);
  /// } on MissingPluginException {
  ///   throw const AgentBridgeException('桥接未就绪 —— 请确认已重新构建 APK（不是热重载）');
  /// }
  /// // ❌ provider == null / baseUrl 空 / apiKey 空 这三条校验**保留在上方**，
  /// //    它们与传输方式无关，是产品约束。
  /// ```
  /// ~endkeep~

  /// **V0.4 手动续跑入口**（契约 N14）：同一会话再跑一轮。
  ///
  /// 语义：用户点「继续」= 明确同意继续消耗 token；实现上是**一条可见的
  /// 用户消息**（“继续未完成的任务”）+ 正常 run —— 历史保持 append-only，
  /// 不伪造“自动续跑”那种不可见用户行。自动续跑（`ContinuePolicy.auto`）
  /// 由 `LocalAgentExecutor` 内部 continuation 处理，不调用本方法。
  Future<AgentRunResult> continueRun({
    required String workspacePath,
    required AppSettings settings,
    required String sessionId,
    String treeUri = '',
  }) =>
      run(
        workspacePath: workspacePath,
        request: '继续未完成的任务',
        settings: settings,
        sessionId: sessionId,
        treeUri: treeUri,
      );

  /// **停止当前在跑的那一轮**（2026-10-13）。
  ///
  /// 用户实测反馈：「暂停不了？」—— 停止按钮画出来了，但点下去
  /// 只会又发一条消息。Kotlin 侧此前**没有任何取消能力**。
  ///
  /// Kotlin 侧用 `job.cancel()` 真停：取消会传播到
  /// `HttpJson.postSse` 的 `finally`，那里 `close()` 输入流 +
  /// `disconnect()` 连接，**打断阻塞中的 `read()`**。
  ///
  /// 返回值：`true` = 确实取消到了一个在跑的任务；
  /// `false` = 没有在跑的（幂等，不是错误 —— 用户可能连点两下）。
  Future<bool> cancelRun() async {
    // ★ 2026-10-22：取消改走**进程内**（旧通道 `cancelRun` 已随 Kotlin 后端删除）。
    // 返回语义不变：`true` = 确实停了一个在跑的；`false` = 本来就没在跑（幂等）。
    final h = _currentHandle;
    if (h == null) return false;
    return h.cancel();
  }

  /// **向正在跑的任务插话**（2026-10-13，思考间隙引导）。
  ///
  /// ## 语义（与"停止"完全不同，用户原话）
  ///
  /// 「注意不是第一个任务结束，是第一个任务的当前的思考过程结束了
  /// 再引导」—— Kotlin 侧**不打断**当前轮；AgentLoop 在当前轮完整
  /// 结束、下一轮开始前把插话 append 进会话（`Turn.User`）。
  /// 模型在下一轮自行比对原任务与插话，决定修改/追加/删除。
  ///
  /// ## 返回 `false` 时调用方必须走**正常发送**
  ///
  /// 没有在跑的任务时"插话"与"发送"本就是同一件事 ——
  /// Kotlin 侧如实回 `accepted: false`，这里透传；
  /// **不要**在这里代发第二条，避免同一句话跑两遍。
  Future<bool> interruptRun(String text) async {
    // ★ 2026-10-30（P0 接线）：**真的入队**，不再恒 false。
    //
    // 语义（与"停止"完全不同）：
    // · 有在途 run ⇒ 把这句话放进该 run 的插话队列（≤4 条、trim 空忽略、
    //   重复去重、满则**拒绝**并返回 false 让调用方走正常发送 —— 绝不静默丢）；
    //   同时向事件流发一条 `interrupted` 让 UI 立刻渲染成一条用户消息；
    // · 没有在途 run ⇒ `false`（"插话"与"发送"本就是一件事，调用方正常发）。
    //
    // backend 侧由 `RunOptions.takeSteerMessage` + `_SteerHook` 在**当前轮完整
    // 结束之后**注入成 `UserMessage`（不打断在途模型流/工具；ask/审批挂起时
    // 轮不结束，插话自动排到恢复后的下一轮）。
    final h = _currentHandle;
    final t = text.trim();
    if (h == null || t.isEmpty) return false;
    final r = h.enqueueSteer(t);
    if (!r.accepted) return false; // 队列满/被拒 ⇒ 调用方正常发送
    if (r.added) {
      // 只有**真的新增**才发事件（重复插话不再多渲染一条用户气泡）。
      emitLocalEvent(AgentEvent(
        type: AgentEvent.kInterrupted,
        ts: DateTime.now().millisecondsSinceEpoch,
        // UI 读 `e.message` 渲染这条用户消息（见 chat_screen kInterrupted 分支）。
        message: t,
      ));
    }
    return true;
  }

  /// **设备权限状态**（2026-10-16，无线调试/Shizuku/adb 授权引导）。
  ///
  /// `writeSecureSettings` = 无障碍自愈的钥匙（ADR-016）是否已授予；
  /// `guidance` = 未授予时的三渠道引导文案（已授予为空串）；
  /// `shizuku` = **执行路由诊断**（ping / preV11 / granted / sui）——
  /// 用来解释「命令执行成功但 Shizuku 显示 0 个已授权应用」：
  /// 本机若装了 Stellar 等 Sui 系管理器，Shizuku-API 会**走 Sui**，
  /// Shizuku 的授权列表自然是 0。
  Future<
      ({
        bool writeSecureSettings,
        String guidance,
        Map<String, dynamic> shizuku,
      })> devicePermission() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('devicePermission');
      return (
        writeSecureSettings: (m?['writeSecureSettings'] as bool?) ?? false,
        guidance: (m?['guidance'] as String?) ?? '',
        shizuku: (m?['shizuku'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
    } on MissingPluginException {
      return (
        writeSecureSettings: false,
        guidance: '',
        shizuku: <String, dynamic>{},
      );
    } on PlatformException {
      return (
        writeSecureSettings: false,
        guidance: '',
        shizuku: <String, dynamic>{},
      );
    }
  }

  /// **Shizuku 授权并执行 pm grant**（2026-10-16 用户反馈完善）。
  ///
  /// 用户原话：「我在 shizuku 上面都找不到本 app 来授权」——
  /// 因为 App 没集成 Shizuku SDK。现在集成了：
  /// 点这个按钮 → Shizuku 弹授权框 → 同意后自动执行
  /// `pm grant <pkg> WRITE_SECURE_SETTINGS`（无障碍自愈钥匙）。
  ///
  /// 返回 `(success, message)` —— message 是可读的执行结果/错误。
  Future<({bool success, String message})> shizukuGrant() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('shizukuGrant');
      return (
        success: (m?['success'] as bool?) ?? false,
        message: (m?['message'] as String?) ?? '',
      );
    } on MissingPluginException {
      return (success: false, message: '平台未实现');
    } on PlatformException catch (e) {
      return (success: false, message: e.message ?? '调用失败');
    }
  }

  /// **强制走一次 Shizuku 授权弹窗**（2026-10-16）。
  ///
  /// 场景：诊断显示 `Shizuku 已授权本 App = 是`，但 Shizuku UI 显示
  /// 「已授权 0 个应用」—— 因为本 App 的授权是**遗留记录**，
  /// 从未走过 Shizuku 的申请弹窗，而它的列表只收录"走过申请流程"的应用。
  ///
  /// 本方法无条件调用 `Shizuku.requestPermission()`，让弹窗真的出现一次。
  Future<({bool success, String message})> shizukuForceRequest() async {
    try {
      final m =
          await _channel.invokeMapMethod<String, dynamic>('shizukuForceRequest');
      return (
        success: (m?['success'] as bool?) ?? false,
        message: (m?['message'] as String?) ?? '',
      );
    } on MissingPluginException {
      return (success: false, message: '平台未实现');
    } on PlatformException catch (e) {
      return (success: false, message: e.message ?? '调用失败');
    }
  }

  /// **App 进程内的编码层自检**（2026-10-17 引入；**2026-11-10 该能力已下线**）。
  ///
  /// ## 历史（为什么它曾经存在）
  ///
  /// 编码层的真机验证（`实测-12`）走的是**设备上跑引擎**那条路
  /// （`:cli` 的 `OnDeviceEncodeProbe` 是**别的进程**）。
  /// App 自己的三个设备类 —— `DeviceShellRunner`（Shizuku/Stellar 路由）、
  /// `AgentBuildService`（防 LMK 的前台服务）、`SystemHealthSource`（温度/电量）——
  /// **一次都没在真机上跑过**，它们只是「编译过、APK 装得上」。
  /// 当时本方法把它们串起来在**应用进程里**真跑一遍：
  /// 起前台服务 → 读健康 → 定位工具链 → 起 shell（`id`/`java -version`）
  /// → 建 Hello World 骨架 → 真构建 → **自己拆包看条目**（不信 `ok=true`）。
  ///
  /// ## ★ 2026-11-10：Kotlin 侧的 handler 早已删除，这里**不再调用通道**
  ///
  /// 旧实现是 `_channel.invokeMethod<String>('encodeSelfCheck')`。该方法随 5 个
  /// Kotlin 后端模块一起删掉了（见 `MainActivity.kt` 顶部「已删」表），
  /// `MainActivity` 的唯一兜底是 `else -> {ok:false, error:"未知方法：…"}` ——
  /// 回的是 **Map**，而 `invokeMethod<String>` 内部是 `decodeEnvelope(...) as String?`
  /// ⇒ 抛的是 **`_TypeError`**，既不是 `PlatformException` 也不是
  /// `MissingPluginException`，原来那两个 `catch` **一个都接不住**。
  /// 结果是：设置页「跑一遍编码层自检」的按钮把 `_selfCheckBusy` 置真后，
  /// 在 `await` 处抛错、`setState` 永不执行 ⇒ **用户看到永久转圈**。
  ///
  /// 所以现在**如实返回一句话**（不是异常、不是空串），保留 `Future<String>`
  /// 签名与调用方兼容。⚠️ **不要**为了"让按钮有反应"去恢复 Kotlin handler：
  /// 那等于把已删掉的能力重新开回来（属于契约变更，得先改 docs/INTERFACE.md）。
  Future<String> encodeSelfCheck() async {
    return '不可用：编码层自检能力已在当前版本移除（宿主通道方法已下线）。';
  }

  /// **ask_user 的回答通道**（2026-10-16 引入；**2026-10-23 改回进程内**）。
  ///
  /// 模型调 `ask_user` 工具时会**挂起等待** —— UI 收到 [kAskUser]
  /// 事件后弹**选项式**对话框，用户逐题点选后调用本方法。
  ///
  /// ## ★ 2026-10-23：不再走 MethodChannel（原先这是第三个断点）
  ///
  /// 旧实现是 `_channel.invokeMethod('replyAsk')` —— 那个 Kotlin handler
  /// 已随旧后端一起删除 ⇒ **回答永远回不到挂起的工具**（只能等 10 分钟超时）。
  /// 现在直接完成本轮 [LocalAskGate] 上挂起的 completer。
  ///
  /// ## 参数形状（按题目 id → 选中的 label 列表）
  ///
  /// 用户原话：「ask 要是选项点击的……可以多选，单选，是 LLM 根据任务决定，
  /// 可以一次发多个 ask，回答完自动下一个问题」。
  /// 一段文本表达不了"哪一题选了哪些项"，所以是 `Map<String, List<String>>`。
  ///
  /// ## 返回值 = **如实**
  ///
  /// `true` = 确实交到了一个正在等待的提问；
  /// `false` = 没有活动提问（run 已结束 / 已超时 / 先点了停止）。
  /// **不静默成功** —— 调用方可以据此判断，而不是以为"已经交上去了"。
  Future<bool> replyAsk(Map<String, List<String>> answers) async {
    final gate = _currentAskGate;
    if (gate == null) return false;
    return gate.replyAsk(answers);
  }

  /// **/compact 手动压缩**（2026-10-24，C2 的 P2 欠账）。
  ///
  /// ## 语义（append-only 约束下的"完全重置"）
  ///
  /// 会话文件是 append-only（铁律）⇒ **不能改写历史**。做法：
  /// 1. 读会话的全部 user/assistant 正文 + 工具结论（各截 200 字符）拼成记录；
  /// 2. 交给当前 provider 做一次摘要（[HeraclesAgent.summarizeTranscript]）；
  /// 3. 把摘要写成一行 `{role:"compact", summary}` **追加**到会话尾部。
  ///
  /// 下一次 run 回填历史时，`sessionRowsToHistory` 遇到这一行就丢弃之前
  /// 的一切、只带摘要进场 —— 与 Claude Code /compact 的"完全重置"同义，
  /// 但原文件一字未动，"把压缩前记录翻出来看"永远可行。
  ///
  /// 返回给 UI 展示的一段话（含摘要原文）。摘要为空/失败**不写标记**并抛出
  /// —— 空摘要等于"用户以为压了、实际全丢"。
  Future<String> compactSession({
    required String workspacePath,
    required String sessionId,
    required AppSettings settings,
    /// `/compact focus on …` 的重点（null/空 = 与旧行为一致）。
    String? focus,
  }) async {
    final provider = settings.effectiveProvider;
    if (provider == null || !settings.hasUsableProvider) {
      throw const AgentBridgeException('没有可用的模型配置，无法做摘要压缩');
    }
    final store = SessionStore(workspaceRoot: workspacePath);
    final rows = await store.loadMessages(sessionId);

    final buf = StringBuffer();
    for (final r in rows) {
      switch ((r['role'] as String?) ?? '') {
        case 'user':
          buf.writeln('用户：${(r['text'] ?? '').toString().trim()}');
        case 'assistant':
          buf.writeln('助手：${(r['text'] ?? '').toString().trim()}');
        case 'tool':
          final res = (r['result'] ?? '').toString().trim();
          final cut = res.length > 200 ? '${res.substring(0, 200)}…' : res;
          buf.writeln('工具 ${(r['tool'] ?? '')}：$cut');
      }
    }
    var transcript = buf.toString().trim();
    if (transcript.isEmpty) {
      return '这个会话还没有内容，不需要压缩。';
    }
    // 尾部 5 万字符：摘要关心"最近在干什么"，最早的开头丢了也可接受
    //（且明确是有损取舍，不是静默 —— 这句话写在这里，改的人看得见）。
    if (transcript.length > 50000) {
      transcript = transcript.substring(transcript.length - 50000);
    }

    final summary = await hb.HeraclesAgent.summarizeTranscript(
      config: hb.BackendConfig(
        apiKey: provider.apiKey,
        modelName: provider.model,
        baseUrl: provider.baseUrl,
        provider: switch (provider.protocol) {
          ProviderProtocol.anthropic => hb.BackendProvider.anthropic,
          ProviderProtocol.openaiResponses => hb.BackendProvider.openAiResponses,
          ProviderProtocol.openaiChat => hb.BackendProvider.openAiCompatible,
        },
      ),
      transcript: transcript,
      focus: focus,
    );
    if (summary.isEmpty) {
      throw const AgentBridgeException('模型没有返回摘要内容，未写入压缩标记');
    }

    await store.appendMessage(sessionId, {
      'role': 'compact',
      'summary': summary,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    return '✅ 会话已压缩（/compact）。更早的细节从下一次对话起不再进入上下文，'
        '摘要如下：\n\n$summary';
  }

  /// **危险操作审批通道**（2026-10-19 引入；**2026-10-24 改回进程内**）。
  ///
  /// backend 的 `_ApprovalHook` 在工具执行前调用 `AskGate.requestApproval`
  /// **挂起**等待；`LocalAskGate` 发 [kApprovalRequest] 事件，UI 弹窗让用户选
  /// 「允许 / 本会话始终允许 / 拒绝」，然后调用本方法完成挂起。
  /// `decision` 取值：`allow` / `allow_always` / `deny`（其它值按拒绝计）。
  ///
  /// ## ★ 2026-10-24：不再走 MethodChannel
  ///
  /// 旧实现打 `replyApproval` 通道 —— 那个 Kotlin handler 已随旧后端删除
  /// （`MainActivity` 只剩工作区/选择器/健康读数），调用必然失败 ⇒
  /// 审批决定永远回不到挂起的 hook，只能等 10 分钟超时。
  /// 现在直接完成本轮 `LocalAskGate` 上挂起的 completer（与 `replyAsk` 同形）。
  ///
  /// 返回 `true` = 确实交到了一个正在等待的审批；`false` = 没有挂起的审批
  /// （run 已结束/超时/先点了停止）—— **如实告知，不静默成功**。
  Future<bool> replyApproval({
    required String callId,
    required String decision,
  }) async {
    final gate = _currentAskGate;
    if (gate == null) return false;
    return gate.replyApproval(callId: callId, decision: decision);
  }

  /// **「始终允许」白名单**（2026-10-19 引入；2026-10-24 改存 Flutter 侧）。
  ///
  /// 用户在审批弹窗点了「本会话始终允许」后，那个工具名会被记住，
  /// **下次启动仍然生效**。存 `SharedPreferences`（键 `heracles.approvals`，
  /// StringList）—— 旧的原生键 `heracles_approvals.xml` 所在的 handler 已删，
  /// 新键从空开始（旧记录自然作废：工具集在内核重构后也变了，重批一次更安全）。
  ///
  /// 这份白名单不放进 `AppSettings`：它是**安全决定**，不该被"恢复默认设置"顺手清掉。
  static const _approvalsKey = 'heracles.approvals';

  Future<List<String>> alwaysAllowedTools() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_approvalsKey) ?? const [];
    } catch (_) {
      // 存储不可用（测试环境等）—— 当没有白名单，审批照常走弹窗。
      return const [];
    }
  }

  /// 白名单追加一条（`allow_always` 的持久化回调，见 `LocalAskGate.onAlwaysAllow`）。
  Future<void> _rememberAlwaysAllow(String tool) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cur = prefs.getStringList(_approvalsKey) ?? <String>[];
      if (!cur.contains(tool)) {
        await prefs.setStringList(_approvalsKey, [...cur, tool]);
      }
    } catch (_) {
      // 持久化失败：本次 run 内 gate 已记账（仍放行），只是重启后要重批 ——
      // 这是可接受的退化，不该让审批流程失败。
    }
  }

  /// 清空「始终允许」白名单（设置页「清除」按钮）。
  Future<void> clearAlwaysAllowed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_approvalsKey);
    } catch (_) {
      // 清空失败：下次审批会继续弹窗（比"清不掉旧白名单"安全得多）。
    }
  }

  // ==========================================================================
  // N7 / N12 结构化记忆（2026-10-24 起 / 2026-10-29 三作用域）
  //                      —— 前端记忆页数据源
  //
  // ★★ 过渡期数据风险修复（2026-10-29，本区块最重要的一条）★★
  //
  // 旧实现 update/delete = `GlobalMemory._rewrite` = `clear()` + 逐条 `append()`。
  // 而 Kotlin 的 `memory.append` 现在**永久只读**（`E_SCOPE_READONLY`）⇒
  // 那条路径会「先清空 global，再回写失败」= **丢掉整份全局记忆**。
  // 所以 update/delete/clear 全部切到 `memory.userEdit`
  // （`ScopedMemoryService.userUpdate/userDelete/userClear`）：Kotlin 侧追加
  // 墓碑/原子重写，只有"成功"或"明确失败"，**不存在半清空状态**。
  //
  // 兼容纪律（INTERFACE §N12.6）：旧五方法签名保留、默认 `global` ⇒
  // 前端不改也能编译；新增能力全部用命名参数追加。
  // ==========================================================================

  /// 列出某作用域的存活条目（旧无参调用 = global）。
  ///
  /// ⚠️ 旧签名 `List<MemoryEntry>` **没有失败通道**（读失败与"没有记忆"同形）。
  /// 想区分就用 [listMemoryResult]。
  Future<List<MemoryEntry>> listMemory({
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
    bool includeExpired = false,
  }) async =>
      (await listMemoryResult(
        scope: scope,
        sessionId: sessionId,
        workspacePath: workspacePath,
        includeExpired: includeExpired,
      ))
          .entries;

  /// 带失败原因的列出（"空"与"错"不同形）。
  Future<({List<MemoryEntry> entries, String? error})> listMemoryResult({
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
    bool includeExpired = false,
  }) async {
    try {
      final r = await _memory.read(
        _addressOf(scope: scope, sessionId: sessionId, workspacePath: workspacePath),
        includeExpired: includeExpired,
      );
      return (
        entries: r.entries.map(GlobalMemory.entryOf).toList(growable: false),
        error: null,
      );
    } on MemoryServiceError catch (e) {
      return (entries: const <MemoryEntry>[], error: e.message);
    } catch (e) {
      return (entries: const <MemoryEntry>[], error: '读取记忆失败：$e');
    }
  }

  /// 用户新增一条（SEC4 疑似密钥/超长由服务统一拒收）。
  Future<MemoryWriteResult> addMemory(
    String text, {
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
    String kind = 'other',
  }) =>
      _writeMemory(() => _memory.userAdd(
            _addressOf(scope: scope, sessionId: sessionId, workspacePath: workspacePath),
            text,
            kind: kind,
          ));

  /// 用户更新一条（global ⇒ `memory.userEdit{action:"update"}`）。
  Future<MemoryWriteResult> updateMemory(
    String id,
    String text, {
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
  }) =>
      _writeMemory(() => _memory.userUpdate(
            _addressOf(scope: scope, sessionId: sessionId, workspacePath: workspacePath),
            id,
            text,
          ));

  /// 用户删除一条（global ⇒ `memory.userEdit{action:"delete"}`）。
  Future<MemoryWriteResult> deleteMemory(
    String id, {
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
  }) =>
      _writeMemory(() => _memory.userDelete(
            _addressOf(scope: scope, sessionId: sessionId, workspacePath: workspacePath),
            <String>[id],
          ));

  /// 用户清空某作用域（global ⇒ `memory.userEdit{action:"clear"}`）。
  Future<MemoryWriteResult> clearMemory({
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
  }) =>
      _writeMemory(() => _memory.userClear(
            _addressOf(scope: scope, sessionId: sessionId, workspacePath: workspacePath),
          ));

  /// 关键词检索（与注入同一分词/打分口径；**不注入**）。
  ///
  /// 失败返回空列表（检索是增强，不阻断界面）；要原因请直接用
  /// `ScopedMemoryService.search`（它会抛 `MemoryServiceError`）。
  Future<List<MemoryEntry>> searchMemory(
    String query, {
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
    int limit = 20,
  }) async {
    try {
      final list = await _memory.search(
        _addressOf(scope: scope, sessionId: sessionId, workspacePath: workspacePath),
        query,
        limit: limit,
      );
      return list.map(GlobalMemory.entryOf).toList(growable: false);
    } on MemoryServiceError {
      return const <MemoryEntry>[];
    } catch (_) {
      return const <MemoryEntry>[];
    }
  }

  /// 存储统计（存储侧；注入侧预算数字由 backend `ContractMemory` 给）。
  ///
  /// 校验失败会抛 `MemoryServiceError`（fail-closed）—— UI 应显示错误态，
  /// 而不是把"引擎不可用"画成"0 条记忆"。
  Future<MemoryStats> memoryStats({
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
  }) async =>
      MemoryStats.of(await _memory.stats(
        _addressOf(scope: scope, sessionId: sessionId, workspacePath: workspacePath),
      ));

  /// **agent 提议一条全局记忆**（agent 写 global 的唯一通道；用户确认后才生效）。
  Future<MemoryWriteResult> proposeGlobalMemory(String note, {String kind = 'other'}) =>
      _writeMemory(() => _memory.proposeGlobal(note, kind: kind));

  /// 列出待用户确认的提议（默认 `pending`；读失败返回空列表）。
  Future<List<MemoryProposal>> listMemoryProposals({String? status = 'pending'}) async {
    try {
      final list = await _memory.listProposals(status: status);
      return list.map(MemoryProposal.of).toList(growable: false);
    } on MemoryServiceError {
      return const <MemoryProposal>[];
    } catch (_) {
      return const <MemoryProposal>[];
    }
  }

  /// 晋升 / 忽略一条提议（**用户动作**；agent 不可触发）。
  Future<MemoryWriteResult> resolveMemoryProposal(String id, {required bool promote}) =>
      _writeMemory(() => _memory.resolveProposal(id, promote: promote));

  /// 容量：`usedBytes / maxBytes`。
  ///
  /// 2026-10-29：`maxBytes` 语义改为**该作用域的存储软预算**
  /// （global = 8 MB；超限只淘汰、不拒写）。形状不变，旧 UI 零改动。
  Future<({int usedBytes, int maxBytes})> memoryCapacity({
    hb.MemoryScope scope = hb.MemoryScope.global,
    String? sessionId,
    String? workspacePath,
  }) async {
    try {
      final s = await _memory.stats(
        _addressOf(scope: scope, sessionId: sessionId, workspacePath: workspacePath),
      );
      return (usedBytes: s.bytes, maxBytes: s.storageSoftMaxBytes);
    } on MemoryServiceError {
      // 读不到统计时**不假装成功**：用量 0 + 软预算常量（UI 显示 0%），
      // 与旧行为一致（旧 capacity 也只有这个形状）。
      return (
        usedBytes: 0,
        maxBytes: hb.ContractMemory.storageGlobalSoftMaxBytes,
      );
    }
  }

  /// **旧 `memory.md` → `global.jsonl` 迁移**（INTERFACE §N12.5 `memory.migrate`）。
  ///
  /// 记忆页「重新迁移」按钮 / 排障用。**幂等**：
  /// `alreadyMigrated` / `noLegacyFile` 都是正常返回，不是错误。
  /// 与首轮自动触发（`runMemoryMigrationOnce`）共用同一套解析/日志。
  Future<MemoryMigrationResult> migrateMemory() => migrateLegacyMemory();

  /// 写操作统一翻译：`MemoryWriteOutcome` / `MemoryServiceError` → 旧结果类型。
  Future<MemoryWriteResult> _writeMemory(
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

  /// **N8 设备权限统一查询**（2026-10-25，INTERFACE.md §4.N8）。
  ///
  /// 返回每项 `granted / denied / unknown`（unknown = 探测不了，如 Shizuku
  /// 未启动）。权限项清单（新增先登记到 INTERFACE.md）：
  /// · `shizuku` —— 提权通道（binder 活且已授权）
  /// · `files` —— 文件夹访问（有 ≥1 个 SAF 授权文件夹/工作区 = granted；
  ///   2026-10-27 起不再恒 granted）
  /// · `allFiles` —— Android 11+「所有文件访问」（**我们按设计不申请**，
  ///   denied 是正常态——前端别渲染成红色警告）
  /// · `notifications` —— 通知（前台服务/构建进度依赖）
  /// · `accessibility` —— 无障碍服务
  /// · `overlay` —— 悬浮窗
  /// · `media` —— 图片与视频（33+ READ_MEDIA_IMAGES/VIDEO；以下存储权限）
  /// · `camera` —— 相机（拍照上传用，拍摄接口见 [takePhoto] 预留）
  /// · `calendar` —— 日历读写（后续自动化任务预留）
  /// · `automation` —— 屏幕自动化（厂商专属，恒 unknown，接口预留）
  /// · `install` —— 安装未知应用（在安装 APK 的流程里申请，不在权限页拨）
  ///
  /// 「去开启」走既有拉起流程（如 [shizukuGrant]），本方法只读。
  Future<Map<String, String>> devicePermissions() async {
    try {
      final raw = await _channel.invokeMapMethod<String, String>('devicePermissions');
      return raw ?? const {};
    } on MissingPluginException {
      return const {}; // 测试环境
    } on PlatformException {
      return const {};
    }
  }

  /// **拉起某项权限的系统授权流程**（2026-10-27，权限页弹性开关）。
  ///
  /// kind 取值：
  /// · `notifications` —— API 33+ 直接弹运行时授权框；低版本去通知设置页
  /// · `notificationsOff` —— 去应用通知设置页（关通知只能在那里）
  /// · `accessibility` —— 无障碍设置页（系统没有授权弹窗）
  /// · `overlay` —— 悬浮窗授权页（直达本 App）
  /// · `media` / `camera` / `calendar` / `microphone` —— 运行时权限，直接弹系统授权框
  /// · `appSettings` —— 本 App 系统详情页（撤销已授运行时权限只能去那）
  /// · `installPackages` —— 未知来源安装授权页（**预留给安装流程**：
  ///   构建出 APK 点安装时、未授权才调它，不在权限页里拨）
  /// · `automation` —— 屏幕自动化（厂商专属，如小米「后台弹出界面」；
  ///   无统一申请方式，宿主如实返回未实现，接口预留）
  ///
  /// 返回 true = 已拉起。**结果不在这里回** —— 用户在系统界面里点完
  /// 回到 App，页面重新查 [devicePermissions] 才是权威状态。
  ///
  /// ★ 2026-10-30（B2）：想区分「弹了系统框 / 去了设置页 / 本来就开着」
  /// 请用 [requestPermissionDetailed]；本方法保留旧语义（只看 `ok`），
  /// 现有调用点零改动。
  Future<bool> requestPermission(String kind) async =>
      (await requestPermissionDetailed(kind)).ok;

  /// **拉起权限并拿到去向**（B2，2026-10-30）。
  ///
  /// 宿主返回**只增**结构 `{ok, action, granted}`：
  /// · `action == requested` —— 系统授权框已拉起（首次 / 还能再问）；
  /// · `action == settingsOpened` —— 系统不再弹框（永久拒绝 / 关通知 /
  ///   低版本），已打开通知（或对应）设置页；
  /// · `action == alreadyGranted` —— 拉起前就可用，没上系统界面。
  ///
  /// [granted] 是**拉起前**的真实状态；用户回到 App 后必须重新查
  /// [devicePermissions] 才是权威（不要在 Dart 侧猜点了允许还是拒绝）。
  /// 通道不可用（测试环境/旧宿主）⇒ [PermissionLaunchResult.notSupported]，
  /// 不假装成功。
  Future<PermissionLaunchResult> requestPermissionDetailed(String kind) async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>(
        'requestPermission',
        <String, Object?>{'kind': kind},
      );
      if (m == null) return const PermissionLaunchResult.notSupported();
      return PermissionLaunchResult(
        ok: (m['ok'] as bool?) ?? false,
        action: PermissionAction.parse(m['action'] as String?),
        granted: (m['granted'] as bool?) ?? false,
        error: m['error'] as String?,
      );
    } on MissingPluginException {
      return const PermissionLaunchResult.notSupported();
    } on PlatformException catch (e) {
      return PermissionLaunchResult.notSupported(e.message);
    }
  }

  /// **拍照 —— 宿主实现**（2026-10-29 落地；契约 2026-10-27 预留）。
  ///
  /// 走命令通道 `takePhoto`：宿主向 MediaStore 申请一个图片
  /// 位置 → 拉起系统相机写入 → 复制进 cache/attachments，
  /// 回与 [pickFiles] 同形状的 `{path, name, size}`，调用方当
  /// 普通图片附件走既有附件管线。用户取消 / 宿主未实现 /
  /// 通道异常 → 返回 null，调用方按「没拍到」如实处理，
  /// 不得假装拍到了。相机权限行已在权限页（`camera`）；委托
  /// 系统相机拍照本身不要求本 App 持有相机权限。
  Future<Map<String, dynamic>?> takePhoto() async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>('takePhoto');
      if (m == null) return null;
      final map = m.cast<String, dynamic>();
      // 宿主把真失败回成错误 map（用户取消是回 null，不走这里）——
      // 把人话原因抛给调用方显示，别静默吞掉。
      if (map['ok'] == false && map['error'] is String) {
        throw AgentBridgeException(map['error'] as String);
      }
      if ((map['path'] as String?)?.isEmpty ?? true) return null;
      return map;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// **语音录音**（2026-10-29）—— 宿主 `VoiceRecorder`
  /// （AudioRecord 16kHz 单声道 PCM16 → WAV in cache/voice）。
  /// 录音文件供 services/voice_asr.dart 离线识别。三个方法都回
  /// 宿主的 map（{ok:true,...} / {ok:false,error:人话原因}）；
  /// 通道不可用（测试环境/宿主未实现）回 null，调用方如实报错。
  Future<Map<String, dynamic>?> startVoiceRecord() =>
      _voiceRecordCall('startVoiceRecord');

  /// 停录并封 WAV，成功回 {ok, path, name, size, durationMs}。
  Future<Map<String, dynamic>?> stopVoiceRecord() =>
      _voiceRecordCall('stopVoiceRecord');

  Future<Map<String, dynamic>?> cancelVoiceRecord() =>
      _voiceRecordCall('cancelVoiceRecord');

  Future<Map<String, dynamic>?> _voiceRecordCall(String method) async {
    try {
      final m = await _channel.invokeMapMethod<dynamic, dynamic>(method);
      if (m == null) return null;
      return m.cast<String, dynamic>();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  // ------------------------------------------------------ 流式语音（§N13）
  //
  // 契约：docs/INTERFACE.md §N13。
  // · Kotlin → Dart：`EventChannel('heracles/voice')` 发 PCM 粗片；
  // · Dart 进程内：解码后按 200–300ms 节流发 [VoicePartial]（累积草稿）；
  // · 旧包没有这条 EventChannel ⇒ 订阅报错/收不到片 ⇒ 调用方回退整段识别。

  static const _voiceEventChannel = EventChannel('heracles/voice');

  /// 音频事件源注入点（测试用假流；null = 真的 `EventChannel`）。
  static Stream<dynamic> Function()? voiceEventSourceForTest;

  /// 订阅 Kotlin 的 PCM 分片事件流（`{type:"chunk"/"end", ...}`）。
  ///
  /// ⚠️ 每次调用都会**新建一条平台订阅**（`receiveBroadcastStream` 的语义），
  /// 调用方只订阅一次并保存 `StreamSubscription`。旧包/通道未实现时，
  /// 错误以 **stream error**（`MissingPluginException`）形式出现，不抛同步异常。
  Stream<dynamic> voiceAudioEvents() {
    final fake = voiceEventSourceForTest;
    if (fake != null) return fake();
    return _voiceEventChannel.receiveBroadcastStream();
  }

  /// **流式语音的累积草稿事件**（进程内广播流）。
  ///
  /// 与 [events] 同理，控制器必须是**静态**的：`AgentBridge` 会被多处置新，
  /// 生产端（voice_input 的解码泵）与消费端（UI）可能不是同一个实例。
  static final StreamController<VoicePartial> _voicePartials =
      StreamController<VoicePartial>.broadcast();

  static Stream<VoicePartial> get voicePartials => _voicePartials.stream;

  /// 是否已有 UI 在监听草稿事件。
  ///
  /// 用途：前端还没接草稿展示时，语音输入要**继续把最终文本填进输入框**
  /// （否则用户点了麦克风什么都不会发生）；前端接了展示后就不再代填
  /// （避免"草稿 UI 一份 + 输入框再插一份"的双写）。
  static bool get hasVoicePartialListener => _voicePartials.hasListener;

  /// 推一段累积草稿给所有订阅者（由流式语音泵调用）。
  static void emitVoicePartial(VoicePartial partial) {
    if (!_voicePartials.isClosed) _voicePartials.add(partial);
  }

  /// **本机画像**（2026-10-27，JEV 决策引擎的本机检测用）——
  /// 宿主 `deviceProfile`（`heracles/command` 通道）：机型、总运行
  /// 内存、可用存储、App 私有目录。前端据此给本地模型选型推荐
  /// （见 models/jev.dart 的 recommendJev）。读不到（测试环境、
  /// 宿主未实现）返回 null，调用方按「检测不可用」如实处理。
  Future<JevDeviceProfile?> deviceProfile() async {
    try {
      final raw =
          await _channel.invokeMapMethod<dynamic, dynamic>('deviceProfile');
      if (raw == null || raw['ok'] != true) return null;
      return JevDeviceProfile.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// **本地 JEV 决策 —— 接口预留**（2026-10-27 用户定）。
  ///
  /// 契约：给 [modelDir]（含 GGUF 权重与 BF16 仓库的 tokenizer /
  /// decision_config.json）与用户问题 [question]，返回「推荐这样
  /// 做」的概率（0–1，即 systemone 的 `noul`）。
  ///
  /// ⚠️ 决策模型**不是**普通聊天模型：权重需要双向注意力读
  /// prompt、按选项字母 logits＋分类温度读出 —— 必须由专用引擎
  /// （llama.cpp 打补丁版＋startlux 读出层，或后端自研）承载，
  /// 宿主/后端接入前**恒返回 null**，调用方按「引擎未接入」
  /// 如实提示（模型可先下载备好），不得编造概率。
  Future<double?> jevLocalDecide({
    required String modelDir,
    required String question,
  }) async =>
      null;

  /// **拉取后端的可用模型列表**（2026-10-14，接入第三方 API 服务）。
  /// ## 为什么需要它
  ///
  /// 用户接入第三方聚合服务（如基元律动 tokenrhythm.studio）时，
  /// **不可能知道后端有哪些模型名** —— 手填必然填错（一个字符就 404/400）。
  /// OpenAI 兼容服务都有标准端点 `GET /v1/models`，拉回来让用户点选。
  ///
  /// ## 顺带读上下文长度
  ///
  /// 调完 [fetchModels] 后，[lastFetchedContextLength] 会带上
  /// 服务端上报的模型能力（**权威**）—— 用户实测痛点：
  /// 模型是 1M 上下文，App 却按猜的 128K 算，导致
  /// ① 使用率显示失真 ② **按 128K×0.8 过早压缩会话**。
  ///
  /// ## 协议（两级回退）
  ///
  /// ① **OpenAI 标准**：`GET {baseUrl}/models`，`Authorization: Bearer <key>`
  ///    响应 `{"data":[{"id":"gpt-4o","context_length":128000},…]}`
  /// ② **中转站专有**（能力字段在标准端点缺失时）：试 `{origin}/api/models`
  ///    —— 实测基元律动在这里返回完整的 `contextWindow` 等字段
  ///
  /// ## 为什么必须问服务端，不能内置表
  ///
  /// 用户实测抓到我编的表错了 2/25（`deepseek-flash` 与 `kimi-k3`
  /// 都是 1M，我写成 128K/256K）。中转站的模型名是**它自己起的别名**，
  /// 同一名字在不同中转站能力可能不同 —— 任何内置表都只是猜。
  ///
  /// ## 为什么用 Dart 直连（与测试连接同理由）
  ///
  /// 这是**配置期的一次性诊断操作**，不走 agent 链路（不建会话、
  /// 不落盘）。且纯 HTTP GET 无平台依赖 —— 不需要动 Kotlin。
  ///
  /// 返回模型 id 列表（按字母排序，去重）；能力映射存在
  /// [lastFetchedCaps] 里。失败抛 [AgentBridgeException]（人话消息）。
  Future<List<String>> fetchModels({
    required String baseUrl,
    required String apiKey,
  }) async {
    final base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final url = '$base/models';
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Accept', 'application/json');
      if (apiKey.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $apiKey');
      }
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();

      if (resp.statusCode == 401) {
        throw const AgentBridgeException('API Key 不对（401）');
      }
      if (resp.statusCode != 200) {
        throw AgentBridgeException(
          'HTTP ${resp.statusCode}：'
          '${body.length > 100 ? body.substring(0, 100) : body}',
        );
      }

      final j = jsonDecode(body);
      final ids = <String>[];
      // ★ 收集**每个模型**的能力信息（2026-10-14 重做）
      //
      // ## 之前错在哪
      //
      // 第一版取所有模型的 context_length **最大值**当全局上限 ——
      // 一个 Key 下有 25 个模型（有的 32K、有的 1M），取最大值
      // 会让 32K 的模型也显示 1M 上限 → 压缩永不触发 → 请求超限报错。
      //
      // ## 现在：按模型名精确匹配
      //
      // 存成 `模型 id → 能力` 的映射，用哪个模型就取哪条。
      final caps = <String, ModelCapabilities>{};
      void scanItem(dynamic e) {
        if (e is! Map) return;
        final id = e['id'] ?? e['name'];
        if (id is! String || id.isEmpty) return;
        ids.add(id);
        final c = ModelCapabilities.fromJson(e);
        if (c.hasAny) caps[id] = c;
      }

      if (j is Map && j['data'] is List) {
        // OpenAI 标准形状：{"data":[{"id":"…"},…]}
        for (final e in j['data'] as List) {
          scanItem(e);
        }
      } else if (j is List) {
        // 变体：直接就是数组 [{"id":"…"},…]
        for (final e in j) {
          scanItem(e);
        }
      }
      if (ids.isEmpty) {
        throw const AgentBridgeException('后端返回了空模型列表');
      }
      ids.sort();

      // ★★ 二级回退：标准端点没给能力字段时，试中转站专有端点 ★★
      //
      // 实测（2026-10-14）：基元律动的 `/v1/models` 未必带 `contextWindow`，
      // 但它的公开模型 API `/api/models` **带完整能力画像**
      //（29 个模型全有 contextWindow / maxOutputTokens / supportsTools…）。
      //
      // 为什么值得做：用户实测的痛点正是"上限算错"——
      // 而**能问就不要猜**。多试一个端点，胜过多一张会过期的表。
      if (caps.isEmpty) {
        final extra = await _tryFetchVendorCaps(base, apiKey);
        if (extra != null) caps.addAll(extra);
      }

      _lastFetchedCaps = caps;
      return ids.toSet().toList();
    } on FormatException {
      throw const AgentBridgeException('响应不是合法 JSON —— 检查 Base URL 是否正确');
    } on SocketException catch (e) {
      throw AgentBridgeException('连不上：${e.message}');
    } on HttpException catch (e) {
      throw AgentBridgeException('请求失败：${e.message}');
    }
  }

  /// **只拉模型能力**（不拉列表）—— 供"自动获取"用（2026-10-14 第三版）。
  ///
  /// ## 为什么需要独立入口
  ///
  /// [fetchModels] 是**用户手动点**的操作（拉列表给用户选）。
  /// 但能力获取**不该依赖用户点按钮** —— 那是第二版的设计缺陷：
  /// 不点就永远显示兜底值。
  ///
  /// 本方法在**需要时自动调用**（发消息前 / 打开用量面板时），
  /// 结果由调用方持久化进 provider 配置。
  ///
  /// ## 失败静默
  ///
  /// 拿不到能力**不影响任何功能**（只影响上限显示的准确度）——
  /// 所以不抛异常，返回 null 让调用方保持现有值。
  Future<Map<String, ModelCapabilities>?> fetchCapabilitiesOnly({
    required String baseUrl,
    required String apiKey,
  }) async {
    final base =
        baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    try {
      // ① OpenAI 标准端点
      final caps = <String, ModelCapabilities>{};
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse('$base/models'));
      req.headers.set('Accept', 'application/json');
      if (apiKey.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $apiKey');
      }
      final resp = await req.close();
      if (resp.statusCode == 200) {
        final body = await resp.transform(utf8.decoder).join();
        final j = jsonDecode(body);
        final list = (j is Map && j['data'] is List)
            ? j['data'] as List
            : (j is List ? j : const []);
        for (final e in list) {
          if (e is! Map) continue;
          final id = e['id'] ?? e['name'];
          if (id is! String || id.isEmpty) continue;
          final c = ModelCapabilities.fromJson(e);
          if (c.hasAny) caps[id] = c;
        }
      }
      client.close();

      // ② 标准端点没给能力 → 试中转站专有端点
      if (caps.isEmpty) {
        final extra = await _tryFetchVendorCaps(base, apiKey);
        if (extra != null) caps.addAll(extra);
      }
      return caps.isEmpty ? null : caps;
    } catch (_) {
      return null; // 静默：拿不到不影响功能
    }
  }

  /// **试中转站的专有模型端点**（二级回退，2026-10-14）。
  ///
  /// ## 为什么需要
  ///
  /// OpenAI 标准 `/v1/models` **只保证 `id`**（`context_length` 是
  /// 可选扩展）—— 但很多中转站在**自己的**端点里给完整能力画像。
  /// 实测基元律动：`GET {origin}/api/models` →
  /// `{"data":[{"id":…,"contextWindow":1000000,"maxOutputTokens":384000,…}]}`
  ///
  /// ## 为什么不是"为基元律动写死"
  ///
  /// 只试一个**路径约定**（`/api/models`，去掉 Base URL 的 `/v1` 后缀），
  /// 而且**失败完全静默**（返回 null）—— 它不是主路径，
  /// 拉到是赚到，拉不到不影响任何事。
  ///
  /// @return 模型 id → 能力；任何失败都返回 null
  Future<Map<String, ModelCapabilities>?> _tryFetchVendorCaps(
    String base,
    String apiKey,
  ) async {
    try {
      // 从 baseUrl 推出 origin：`https://host/v1` → `https://host`
      final uri = Uri.parse(base);
      final origin = '${uri.scheme}://${uri.authority}';
      final url = '$origin/api/models';

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Accept', 'application/json');
      if (apiKey.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $apiKey');
      }
      final resp = await req.close();
      if (resp.statusCode != 200) {
        client.close();
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      client.close();

      final j = jsonDecode(body);
      final out = <String, ModelCapabilities>{};
      final list = (j is Map && j['data'] is List)
          ? j['data'] as List
          : (j is List ? j : const []);
      for (final e in list) {
        if (e is! Map) continue;
        final id = e['id'] ?? e['name'];
        if (id is! String || id.isEmpty) continue;
        final c = ModelCapabilities.fromJson(e);
        if (c.hasAny) out[id] = c;
      }
      return out.isEmpty ? null : out;
    } catch (_) {
      // 完全静默：这是**尽力而为**的增强，不是主路径
      return null;
    }
  }

  // ------------------------------------------------------------ 附件 / 文件

  /// 调 Android 原生选择器（SAF / 相册）挑文件。
  ///
  /// **刻意不用 file_picker**：它的 `compileSdk 34` 与传递依赖
  /// `flutter_plugin_android_lifecycle` 要求的 ≥36 冲突，
  /// 会**直接让整个构建失败**（8.3.7 与 9.2.3 都如此，实测）。
  Future<List<Map<String, dynamic>>> pickFiles({
    bool imagesOnly = false,
    bool multiple = true,
  }) async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('pickFiles', {
        'imagesOnly': imagesOnly,
        'multiple': multiple,
      });
      return _maps(list);
    } on PlatformException catch (e) {
      throw AgentBridgeException(e.message ?? e.code);
    } on MissingPluginException {
      throw const AgentBridgeException('桥接未就绪');
    }
  }

  /// 列目录（"文件"视图用）
  Future<List<Map<String, dynamic>>> listDir(String path) async {
    try {
      final list = await _channel.invokeListMethod<dynamic>('listDir', {'path': path});
      return _maps(list);
    } on MissingPluginException {
      return const [];
    }
  }

  List<Map<String, dynamic>> _maps(dynamic list) => (list as List? ?? const [])
      .whereType<Map<dynamic, dynamic>>()
      .map((e) => e.cast<String, dynamic>())
      .toList();
}

/// 桥接错误 —— 携带**人类可读**的原因
class AgentBridgeException implements Exception {
  const AgentBridgeException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// **一段流式语音的累积草稿**（契约 `docs/INTERFACE.md` §N13.3）。
///
/// 由流式语音泵在**主 isolate** 里按 200–300ms 节流发出：
/// · [text] 是**累积整段草稿**（不是增量片段），只增不减；
/// · [isFinal] = 本轮识别定稿（静音断句 ~800ms / 停止 / 60 秒上限）；
/// · [seq] 是该会话内的序号（从 0 开始），[tsMs] 是发出时刻（epoch ms）。
///
/// 与 `widgets/voice_draft.dart` 里前端阶段的**同名占位类**不同：那个
/// 只有 3 个字段、是 UI 自己的形状；本类是**契约形状**（前端接展示时用本类，
/// 记得 `import ... hide` 或删掉占位类，别让两个 `VoicePartial` 同时可见）。
class VoicePartial {
  const VoicePartial({
    required this.sessionId,
    required this.text,
    required this.isFinal,
    required this.seq,
    required this.tsMs,
  });

  /// 一次录音会话的标识（旧会话的迟到事件据此丢弃）。
  final String sessionId;

  /// 目前为止的**累积整段草稿**。
  final String text;

  /// 是否本轮定稿（之后同一会话可能还有新句子，但本次识别已定稿）。
  final bool isFinal;

  /// 该会话内的序号（从 0 递增）。
  final int seq;

  /// 发出时刻（epoch 毫秒）。
  final int tsMs;

  Map<String, dynamic> toMap() => {
        'sessionId': sessionId,
        'text': text,
        'isFinal': isFinal,
        'seq': seq,
        'tsMs': tsMs,
      };

  @override
  bool operator ==(Object other) =>
      other is VoicePartial &&
      other.sessionId == sessionId &&
      other.text == text &&
      other.isFinal == isFinal &&
      other.seq == seq &&
      other.tsMs == tsMs;

  @override
  int get hashCode => Object.hash(sessionId, text, isFinal, seq, tsMs);

  @override
  String toString() =>
      'VoicePartial(session: $sessionId, seq: $seq, final: $isFinal, '
      'text: "$text")';
}

/// agent 运行过程中的**实时事件**（对应 Kotlin 侧 `AgentEvent`）。
///
/// ## 设计取舍：为什么用一个宽对象而不是 sealed class 层次
///
/// Kotlin 侧是 sealed interface（7 个 data class），但 Dart 这边刻意
/// 做成**单一类 + `type` 判别字段**：
/// 事件是**跨进程的弱契约**（Map），不是编译期类型。
/// 硬做成 7 个子类只会多出 7 段 `switch` 样板，却换不来任何编译期保障 ——
/// 真正的风险是"Kotlin 加了新事件类型而 Dart 不认识"，
/// 那用 [type] 判别 + 未知类型降级（[isKnown]）反而处理得更稳。
///
/// ## 所有字段都可空是刻意的
///
/// 不同 `type` 携带不同字段（`tool_started` 没有 `result`，
/// `failed` 没有 `index`）。用可空 + [type] 判别，而不是塞一堆默认值 ——
/// **默认值会伪造信息**（例如把缺失的 `ok` 当成 false，
/// UI 就会把"没执行"显示成"工具失败"）。
class AgentEvent {
  const AgentEvent({
    required this.type,
    required this.ts,
    this.index,
    this.raw,
    this.wallMs,
    this.cache,
    this.tool,
    this.args,
    this.surface,
    this.command,
    this.exitCode,
    this.truncated = false,
    this.activationCapability,
    this.activationBytes,
    this.activationSummary,
    this.activationBenefit,
    this.callId,
    this.workspaceInside,
    this.breakdown,
    this.limit,
    this.limitSource,
    this.planStepsDetailed,
    this.result,
    this.ok,
    this.reason,
    this.finalText,
    this.stopReason,
    this.turnCount,
    this.message,
    this.runStopReason,
    this.runStopRound,
    this.runStopMaxRounds,
    this.runStopTokensSpent,
    this.runStopTokensLimit,
    this.runStopNextEstimate,
    this.runStopCanContinue,
    this.runStopChangedFiles = const <String>[],
    this.runStopErrorSummary,
    this.runStopResumedFromRound,
    this.stepId,
    this.title,
    this.delta,
    this.status,
    this.durationMs,
    this.summary,
    this.planSteps,
    this.doneCount,
    this.activeIndex,
    this.reachedGoal,
    this.planClosedReason,
    this.outcome,
    this.questions,
    this.changeFiles,
    this.beforeMessages,
    this.afterMessages,
    this.beforeTokens,
    this.afterTokens,
  });

  /// 判别字段：轮级 `turn_started` / `model_output` / `tool_started` /
  /// `tool_finished` / `blocked` / `finished` / `failed`；
  /// token 级 `step_started` / `reasoning_delta` / `step_delta` / `step_ended`
  final String type;

  /// 事件发生时间（毫秒时间戳）
  final int ts;

  // ---- 轮次 ----
  final int? index;

  /// `model_output`：模型本轮原始输出（「完全展开」档位的数据源）
  final String? raw;

  // ---- 工具 ----
  final String? tool;
  final Map<String, String>? args;

  /// **这条命令在哪个执行面跑**（2026-10-29）：`'sandbox'` / `'device'`。
  ///
  /// - `tool_started`：**预判**（后端按与执行时同一张规则表算出，不是猜的）
  /// - `tool_finished`：**实际**（执行完的权威值，以它为准）
  /// - 其它事件 / 不涉及执行的工具：`null`
  ///
  /// 前端据此把卡片标题写成「在沙箱执行了命令」/「在手机执行了命令」。
  final String? surface;

  /// 命令全文（**不截断**）。前端命令层完整显示，长行横向滑。
  final String? command;

  /// 结构化退出码（`tool_finished`；手机 shell 与沙箱同口径）。
  ///
  /// 以前退出码混在结果文本里（`（命令退出码：1）`），前端只能正则抠 ——
  /// 现在它是字段。`null` = 该工具没有退出码概念（读文件、git 等）。
  final int? exitCode;

  /// 输出是否被截断（前端要如实标注「输出已截断」）。
  final bool truncated;

  // ---- activation_required（2026-10-29）----
  //
  // 工具因为「缺 T2 编译环境」而没执行时发这一帧。**不是失败事件** ——
  // 用户点一下激活就能继续，所以单独成一类（UI 弹引导卡，不画红色错误）。

  /// 能力标识（当前只有 `'apk-build'`）。
  final String? activationCapability;

  /// 预计下载字节数（UI 如实显示，别写"约几十 MB"）。
  final int? activationBytes;

  /// 一行说明，如 `JDK 17 + Gradle`。
  final String? activationSummary;

  /// 激活后能做到什么（弹卡时给用户看的收益）。
  final String? activationBenefit;

  /// `approval_required`：框架调用 id（答复 [AgentBridge.replyApproval] 必带回）。
  /// 其余事件为 null。
  final String? callId;

  /// `approval_required`：操作对象是否在工作区内（N1）。
  final bool? workspaceInside;

    /// `context_updated`（N2）：分项统计（key → 估算 token）。
    /// 固定键 system/toolDefs/toolResults/reasoning/assistant/user/summary，
    /// 只许新增不许改名；前端忽略不认识的并入「其他」。
    final Map<String, int>? breakdown;

    /// `context_updated`：窗口上限与来源（沿用 ContextUsage 口径）。
    final int? limit;
    final String? limitSource;

    /// `plan_updated`（N4）：完整计划帧的步骤明细（[{id,title,status}]，
    /// status ∈ pending/active/done/cancelled —— cancelled 为本实现的追加）。
    final List<Map<String, String>>? planStepsDetailed;

  /// `tool_finished`：工具结果文本
  final String? result;

  /// `tool_finished`：**只有这个事件有 ok**；
  /// 其它事件为 null —— 不要默认成 false
  final bool? ok;

  /// `blocked`：拦截原因（校验失败 / 循环 / 重复 / 无法解析）
  final String? reason;

  // ---- 计时 ----
  /// `model_output` = 本轮生成墙钟；`tool_finished` = 工具执行墙钟
  final int? wallMs;

  /// `model_output`：本轮缓存指标
  final EventCacheStats? cache;

  // ---- 结束 ----
  final String? finalText;
  final String? stopReason;
  final int? turnCount;

  /// `failed`：错误信息
  final String? message;

  // ---- V0.4 `run_stopped`（N14；只增字段）----
  /// 停止原因 wire 名（max_rounds/token_budget/no_progress/provider_timeout/
  /// network/process_killed/context_compress_failed/user_cancel）。
  final String? runStopReason;
  final int? runStopRound;
  final int? runStopMaxRounds;
  final int? runStopTokensSpent;
  final int? runStopTokensLimit;
  final int? runStopNextEstimate;
  final bool? runStopCanContinue;
  final List<String> runStopChangedFiles;
  final String? runStopErrorSummary;
  final int? runStopResumedFromRound;

  // ---- token 级（2026-10-12 流式逐字；见 Kotlin 侧 `AgentEvent` 的
  //      "token 级事件" 段与 `docs/25-流式工作步骤.md` §5.3）----

  /// `step_started` / `reasoning_delta` / `step_delta` / `step_ended`：
  /// 步骤标识，形如 `turn-3`。**token 级事件靠它归属到具体的步骤** ——
  /// 没有它，多步骤的增量只能全堆在最后一条消息上（必然错位）。
  final String? stepId;

  /// `step_started`：人可读标题（如「正在生成第 3 轮」）
  final String? title;

  /// `reasoning_delta` / `step_delta`：**本次增量**（几个字），
  /// 不是累积全文 —— 累加由 UI 自己做（见 `chat_screen` 的 `_deltaBuffer`）。
  final String? delta;

  /// `step_ended`：三态 `ok` / `empty` / `error`。
  ///
  /// ⚠️ **不是布尔** —— "生成了但内容为空"与"生成失败"对用户是不同的。
  final String? status;

  /// `step_ended`：该步骤墙钟耗时
  final int? durationMs;

  /// `step_ended`：生成内容的**最终完整文本** ——
  /// UI 用它替换掉逐字累积的草稿，并在此刻才做 Markdown 格式化。
  final String? summary;

  // ---- ★ 任务计划（2026-10-14，harness）----

  /// `plan_created`：待办清单的每一步文本（按顺序）
  final List<String>? planSteps;

  /// `plan_advanced`：已完成步数（前 N 个为 done）
  final int? doneCount;

  /// `plan_advanced`：当前进行中的步（0 起）；-1 = 全部完成
  final int? activeIndex;

  /// `plan_closed`：任务是否**真正达成目标**（2026-10-15，BUG-1）。
  ///
  /// · `true` → 模型给了最终回答，剩余步骤视为**已完成**（画绿勾）
  /// · `false` → 循环硬停 / 熔断 / 轮次耗尽，**明确的中断**
  /// · `null` → 老版本 Kotlin 没发这个字段（按"未知"处理，不改画法）
  ///
  /// ⚠️ 三态而非布尔：把"中断"画成"完成"是 H-1 记录过的假信息问题。
  final bool? reachedGoal;

  /// `plan_closed`：收尾原因（中断时显示给用户，如"检测到循环，已强制停止"）
  final String? planClosedReason;

  /// `ask_closed`（P0，2026-10-30）：提问气泡为什么被关闭。
  ///
  /// `timeout` = 300s 未回答；`aborted` = 用户停止/取消解挂。
  /// 其它事件恒 `null`（**不要默认成 timeout** —— 正常提交不发本事件）。
  final String? outcome;

  /// **`ask_user`：模型提的题目列表**（2026-10-21 选项式）。
  ///
  /// 每项形状：`{"id","question","multi","options":[{"label","description"}]}`。
  /// Kotlin 侧已经解析好结构（Dart **不解析 JSON**），UI 只管渲染。
  /// `null` / 空列表 = 题目格式非法（Kotlin 侧解析失败），UI 应提示而不是弹空窗。
  final List<Map<String, dynamic>>? questions;

  /// **`changes`：一次 run 的变更报告**（2026-10-22，对齐参考界面）。
  ///
  /// 每项：`{"path": 相对路径, "added": N, "removed": M}`。
  /// 数字来自**工具结果里的 diff**（不是模型自报）；空/坏数据由 UI 容错跳过。
  final List<Map<String, dynamic>>? changeFiles;

  // ---- ★ 上下文压缩（2026-10-23）----
  //
  // 用户原话：「上下文压缩机制这个要做一下，如果上下文达到了 80% 必须先自动
  // 压缩，然后继续任务，哪怕任务跑到一半」。
  //
  // 压缩是**有损**的（老消息被摘要成一段 XML，细节丢了），所以必须让用户看见，
  // 否则表现只有两种：模型"突然忘了前面说的事"，或者他压根不知道发生过。

  /// `context_compressed`：压缩**前**历史里有几条消息。
  ///
  /// ⚠️ 这是**消息条数**，不是轮次。
  final int? beforeMessages;

  /// `context_compressed`：压缩**后**历史里有几条消息。
  ///
  /// ⚠️ **不一定比 [beforeMessages] 小得多**：框架会把老消息删掉，但也会往
  /// 保留段头部插入 2 条（摘要快照 + 一句确认），所以这是"前后各自的真实值"，
  /// 不是"删掉了几条"。
  final int? afterMessages;

  /// `context_compressed`：压缩**前**估算的 token 数。
  ///
  /// ⚠️ **估算值，不是 provider 上报值**（此刻还没发请求）。
  /// UI 别拿它跟顶栏的"缓存命中率"混在一起比 —— 那是两个口径。
  final int? beforeTokens;

  /// `context_compressed`：压缩**后**估算的 token 数。
  ///
  /// ⚠️ **可能比 [beforeTokens] 大**（摘要文本本身也占 token，
  /// 若被压掉的老消息很短、摘要写得长就会反弹）。这不是 bug，UI 不要假设
  /// "一定变少"，也不要在差值为负时显示成异常。
  final int? afterTokens;

  // ------------------------------------------------------------ 判别辅助

  /// **一次 run 的变更报告**（写类工具按文件聚合，run 结束时发一条）。
  static const kChanges = 'changes';

  static const kTurnStarted = 'turn_started';
  static const kModelOutput = 'model_output';
  static const kToolStarted = 'tool_started';
  /// **需要激活能力**（2026-10-29）：工具因为缺 T2 编译环境而没执行。
  /// UI 据此弹引导卡（体积 / 收益 / [激活] 按钮）。
  static const kActivationRequired = 'activation_required';
  static const kToolFinished = 'tool_finished';
  static const kBlocked = 'blocked';
  static const kFinished = 'finished';
  static const kFailed = 'failed';

  /// **V0.4 长任务被策略停下**（N14）：不是完成、也不是普通错误；
  /// 后面可能紧跟 `failed`，UI 用 `runStopCanContinue` 决定“继续”是否可用。
  static const kRunStopped = 'run_stopped';

  /// **用户插话被注入会话**（2026-10-13，思考间隙引导）——
  /// 到达时机 = 上一轮完整结束、下一轮开始前。
  static const kInterrupted = 'interrupted';

  /// **任务计划产生**（2026-10-14，harness）—— 模型首轮产出待办清单。
  ///
  /// 用户原话：「先拿到问题先分析，**做一个待办**，按照待办完成任务」。
  static const kPlanCreated = 'plan_created';

  /// **任务计划推进**（2026-10-14）——
  /// 由**真实工具执行记录**驱动（不是模型自报）。
  static const kPlanAdvanced = 'plan_advanced';

  /// **任务计划收尾**（2026-10-15，修 BUG-1）。
  ///
  /// 任务结束时 AgentLoop 明确发出 —— 告诉 UI 剩余步骤该显示成
  /// "已完成"（正常达成）还是"已中断"（循环/熔断）。
  ///
  /// 没有它，最后一步（通常是"汇报结果"，**不需要工具**）会
  /// **永远停在"进行中"**（用户实测截图：任务已结束但显示 4/5）。
  static const kPlanClosed = 'plan_closed';

  /// **ask_user：模型向用户提问**（2026-10-16 用户需求）。
  ///
  /// 到达时机：`ask_user` 工具**已挂起等待** —— UI 收到后弹窗，
  /// 用户提交回答走 [replyAsk]。
  static const kAskUser = 'ask_user';

  /// **ask 已关闭**（P0，2026-10-30；只增事件）—— 提问气泡该收了。
  ///
  /// 载荷：`{type:"ask_closed", outcome:"timeout"|"aborted"}`。
  /// · `timeout`：超时（**300s / 5 分钟**）未回答 —— 模型收到的是"未回答"，
  ///   绝不编答案；UI 收掉提问气泡；
  /// · `aborted`：用户点停止/取消解挂；
  /// · 用户**正常提交或跳过**走 [replyAsk]，**不发**本事件（UI 自己已收）。
  static const kAskClosed = 'ask_closed';

  /// **危险工具需要用户确认**（2026-10-19，三态门禁的 UI 闭环）。
  ///
  /// 到达时机：Kotlin 侧 `AgentLoop` **已挂起**在审批队列上 —— UI 弹窗，
  /// 用户选允许/拒绝后走 [replyApproval]。允许 = 重新执行该工具；
  /// 拒绝/超时 = 作为失败回填给模型（绝不谎称成功）。
  static const kApprovalRequest = 'approval_request';

  /// **审批请求（N1 结构化形状，2026-10-24）**—— 取代 [kApprovalRequest]。
  ///
  /// 载荷：`callId`（答复配对必带）/ `tool` / `args` / `reason`（=risk，
  /// 一句话风险说明）/ `workspaceInside`（操作对象是否在工作区内）。
  /// 答复走 [AgentBridge.replyApproval]（结构化：callId + decision），
  /// decision ∈ deny / once（允许一次）/ always（本会话始终允许）。
  static const kApprovalRequired = 'approval_required';

  /// **上下文分项统计（N2，2026-10-24）**—— 每轮至少一帧。
  ///
  /// 载荷：`breakdown`（key→估算 token；固定键 system/toolDefs/toolResults/
  /// reasoning/assistant/user/summary，只许新增不许改名）+ `limit` + `limitSource`。
  /// 估算与压缩器同一套 CJK 系数（口径稳定）；reasoning/summary 恒 0
  /// （thought 不回放、快照消息不可辨识 —— 如实给 0，前端并入「其他」）。
  static const kContextUpdated = 'context_updated';

  /// **计划帧（N4，2026-10-24）**—— 取代 [kPlanCreated] 的完整帧形状：
  /// 每次变化发一帧全量（前端只读最后一帧，不做增量拼接）；
  /// 会话恢复时先发一帧还原；`steps` 为空 = 收起灵动岛。
  /// 载荷：`planStepsDetailed`（[{id,title,status}]，status ∈ pending/active/done）
  /// + 既有 planSteps/doneCount/activeIndex（兼容保留）。
  static const kPlanUpdated = 'plan_updated';

  /// **上下文已自动压缩**（2026-10-23）—— 让用户看得见"压缩真的发生了"。
  ///
  /// ## 为什么必须有这个事件
  ///
  /// 压缩是**有损**的：老消息被摘要成一段 XML 快照，细节丢了。在它之前，
  /// 用户完全看不到发生过 —— 表现只有两种，都很糟：
  ///
  /// - 模型"突然忘了前面说过的事"（用户以为模型变笨了）；
  /// - 或者什么都没察觉，直到发现上下文被悄悄改写过。
  ///
  /// 「到 80% 自动压缩然后继续任务」这个行为本身就该被看见：用户会明白
  /// "哦，它压缩了，所以刚才那段细节它可能不记得了"，而不是困惑。
  ///
  /// ## 触发时机（重要）
  ///
  /// 框架在**每一轮循环的最开头、请求发出之前**检查并压缩
  /// ⇒ 这个事件可能在一次 run 的**中间**到达（不是只在开头/结尾）。
  /// UI 应按到达顺序插在对话流里，而不是堆到最后。
  ///
  /// ## 字段（**逐字，照这个名渲染**）
  ///
  /// | 字段 | 类型 | 含义 |
  /// |---|---|---|
  /// | `beforeMessages` | int | 压缩前消息条数 |
  /// | `afterMessages` | int | 压缩后消息条数 |
  /// | `beforeTokens` | int | 压缩前**估算** token |
  /// | `afterTokens` | int | 压缩后**估算** token |
  ///
  /// ⚠️ `afterTokens` 可能 ≥ `beforeTokens`（摘要本身占 token），别假设一定变少。
  static const kContextCompressed = 'context_compressed';

  // ---- token 级（2026-10-12）----

  /// 一个步骤开始（带 `stepId`，是逐字增量的归属锚点）
  static const kStepStarted = 'step_started';

  /// **思考增量** —— 用户要的「AI 的思考过程，一个字一个字出来」
  static const kReasoningDelta = 'reasoning_delta';

  /// **正文增量** —— 最终答案正在逐字生成
  static const kStepDelta = 'step_delta';

  /// 一个步骤结束 —— UI 据此停止"逐字"状态并重新格式化
  static const kStepEnded = 'step_ended';

  /// Kotlin 侧认识的事件类型。未知类型 = 版本不一致，
  /// UI 应当忽略而不是崩溃（跨进程弱契约的必然情况）。
  static const _knownTypes = {
    kTurnStarted,
    kModelOutput,
    kToolStarted,
    kToolFinished,
    kBlocked,
    kFinished,
    kFailed,
    kRunStopped,
    kInterrupted,
    kPlanCreated,
    kPlanAdvanced,
    kPlanClosed,
    kAskUser,
    kAskClosed,
    kApprovalRequest,
    kApprovalRequired,
    kContextUpdated,
    kPlanUpdated,
    kStepStarted,
    kReasoningDelta,
    kStepDelta,
    kStepEnded,
    kChanges,
    kContextCompressed,
  };

  /// `step_ended` 的三态取值（与 Kotlin 侧 `StepEnded.STATUS_*` 对齐）。
  static const kStatusOk = 'ok';
  static const kStatusEmpty = 'empty';
  static const kStatusError = 'error';

  /// 是不是 token 级（逐字）事件。
  bool get isDelta =>
      type == kReasoningDelta || type == kStepDelta;
  bool get isKnown => _knownTypes.contains(type);

  /// 终止事件 —— UI 用它结束"运行中"状态
  bool get isTerminal => type == kFinished || type == kFailed;

  /// 工具**真的执行了**（区别于 blocked：没执行）
  bool get isExecutedTool =>
      (type == kToolStarted || type == kToolFinished) && tool != null;

  factory AgentEvent.fromMap(Map<String, dynamic> m) {
    final rawCache = m['cache'];
    final rawArgs = m['args'];
    return AgentEvent(
      type: (m['type'] as String?) ?? '',
      ts: (m['ts'] as num?)?.toInt() ?? 0,
      index: (m['index'] as num?)?.toInt(),
      raw: m['raw'] as String?,
      wallMs: (m['wallMs'] as num?)?.toInt(),
      cache: rawCache is Map
          ? EventCacheStats.fromMap(rawCache.cast<String, dynamic>())
          : null,
      // ★ blocked 的 tool 可能为 null（Unparseable 分支）—— 原样保留
      tool: m['tool'] as String?,
      args: rawArgs is Map
          ? rawArgs.map((k, v) => MapEntry(k.toString(), v.toString()))
          : null,
      result: m['result'] as String?,
      // ★ 只认真正的 bool；缺失就是 null，不默认 false
      ok: m['ok'] is bool ? m['ok'] as bool : null,
      reason: m['reason'] as String?,
      finalText: m['finalText'] as String?,
      stopReason: m['stopReason'] as String?,
      turnCount: (m['turnCount'] as num?)?.toInt(),
      // ★ `interrupted` 事件的插话原文走 Kotlin 的 `"text"` 字段 ——
      //   复用 `message` 承载（事件类不加专属字段，
      //   `message` 的语义就是"这条事件的人读文本"）
      message: (m['message'] ?? m['text']) as String?,
      // ★ 任务计划（2026-10-14）：`plan_created` 带 steps 数组
      planSteps: (m['steps'] as List?)?.whereType<String>().toList(),
      doneCount: (m['doneCount'] as num?)?.toInt(),
      activeIndex: (m['activeIndex'] as num?)?.toInt(),
      // ★ 计划收尾（2026-10-15，BUG-1）：
      //   `reachedGoal` 决定剩余步骤画绿勾（达成）还是"已中断"（循环/熔断）。
      //   **null 与 false 语义不同** —— null = 老 Kotlin 没发这个字段
      //   （按"未知"处理，不改画法），false = 明确的中断。
      reachedGoal: m['reachedGoal'] as bool?,
      planClosedReason: m['reason'] as String?,
      // ★ ask_closed（P0，2026-10-30）：outcome ∈ timeout/aborted；
      //   缺失 = 老版本/非该事件（按 null，不猜）。
      outcome: m['outcome'] as String?,
      // ★ ask_user 的题目结构（2026-10-21）：Kotlin 已解析好，这里只做类型转换。
      //   缺失 = 老版本 Kotlin（只会带 `text`）⇒ 返回 null，UI 走"降级为纯文本"分支。
      questions: (m['questions'] as List?)
          ?.map((e) => (e as Map).cast<String, dynamic>())
          .toList(),
      // ★ token 级字段：**缺失就是 null**，绝不伪造空串 ——
      //   空串 delta 会让 UI 以为"这一步真的吐了个空字"，
      //   而实际是版本不一致（老 Kotlin 不发这些字段）。
      stepId: m['stepId'] as String?,
      title: m['title'] as String?,
      delta: m['delta'] as String?,
      status: m['status'] as String?,
      durationMs: (m['durationMs'] as num?)?.toInt(),
      summary: m['summary'] as String?,
      // ★ 变更报告（2026-10-22）：`{"files":[{"path","added","removed"}]}`
      changeFiles: (m['files'] as List?)
          ?.whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(),
      // ★ 上下文压缩（2026-10-23）：四个数**缺失就是 null**，不伪造 0 ——
      //   0 条消息 / 0 token 是"真的空"，与"这条事件没带这个字段"是两件事。
      beforeMessages: (m['beforeMessages'] as num?)?.toInt(),
      afterMessages: (m['afterMessages'] as num?)?.toInt(),
      beforeTokens: (m['beforeTokens'] as num?)?.toInt(),
      afterTokens: (m['afterTokens'] as num?)?.toInt(),
    );
  }

  @override
  String toString() =>
      'AgentEvent($type, index=$index, tool=$tool, stepId=$stepId)';
}

/// 一轮的缓存指标（对应 Kotlin 侧 `CacheStats` 的子集）。
///
/// [cachedTokens] 与 [hitRate] 为 null 表示 **provider 未上报** ——
/// `02-契约规范.md` §3.4 明令：此时 UI 必须显示"不可用"，
/// **不得用 0 代替**（0 会被误读成"缓存坏了"）。
class EventCacheStats {
  const EventCacheStats({
    this.cachedTokens,
    required this.promptTokens,
    required this.outputTokens,
    this.hitRate,
  });

  final int? cachedTokens;
  final int promptTokens;
  final int outputTokens;
  final double? hitRate;

  /// provider 是否上报了缓存字段
  bool get reportingAvailable => cachedTokens != null;

  factory EventCacheStats.fromMap(Map<String, dynamic> m) => EventCacheStats(
        cachedTokens: (m['cachedTokens'] as num?)?.toInt(),
        promptTokens: (m['promptTokens'] as num?)?.toInt() ?? 0,
        outputTokens: (m['outputTokens'] as num?)?.toInt() ?? 0,
        hitRate: (m['hitRate'] as num?)?.toDouble(),
      );
}

/// 一次 agent 运行的完整结果（对应 Kotlin 侧 `AgentRunResult`）
class AgentRunResult {
  const AgentRunResult({
    required this.stopReason,
    required this.finalText,
    required this.turns,
    required this.totalCachedTokens,
    required this.totalPromptTokens,
    required this.totalOutputTokens,
    this.steadyHitRate,
    this.taskWallMs = 0,
    this.sessionId,
    this.cancelled = false,
    this.changeFiles,
    this.failureReason,
  });

  final String stopReason;
  final String finalText;
  final List<AgentTurn> turns;

  /// **变更报告**（2026-10-22）：本次 run 写类工具按文件聚合的结果，
  /// 每项 `{path, added, removed}`。`null`/空 = 这次没动过文件（不画卡片）。
  ///
  /// 数字来自工具结果的 diff（结果无 diff 时退回按参数行数估算），
  /// **不是模型自报** —— 模型可能撒谎，diff 不会。
  final List<Map<String, dynamic>>? changeFiles;

  final int totalCachedTokens;
  final int totalPromptTokens;
  final int totalOutputTokens;

  /// 稳态命中率（跳过第一轮冷启动）；null = 无法计算
  ///
  /// ## 口径（2026-10-21，BUG-5）
  ///
  /// Kotlin 侧 `AgentRunResult.steadyHitRate` = **轮次平均**
  /// （`turns.drop(1).mapNotNull { it.cache.hitRate }.average()`）。
  ///
  /// 它与 `SessionUsage.hitRate`（Σcached/Σ(cached+prompt)，**token 加权**、含全部轮次）
  /// **不是同一个数**，也**不会相等**：轮次平均把小轮与大轮等权，系统性偏乐观
  /// （2026-10-19 云端实测：轮次平均 90.8%，同样本加权 84.6%）。
  /// ⇒ UI 必须把两者**分别标注口径**，不能都叫「缓存命中」。
  final double? steadyHitRate;

  /// **任务总耗时（毫秒）** —— 从 run 开始到 run 结束的**真实墙钟**
  /// （含工具执行、审批/提问等待、上下文压缩）。
  ///
  /// ## 为什么必须单独有这个字段（2026-10-21，BUG-5）
  ///
  /// 用户原话：「耗时才 5172ms，改成秒为单位，这个是从开始执行任务到结束任务的
  /// 耗时，你觉得会这么短？」
  ///
  /// 他说得对。此前面板显示的"耗时"是 [turns] 里 `wallMs` 的累加，而
  /// `TurnRecord.wallMs` 只包住 `provider.generate` / 流式往返 ——
  /// **不含工具执行、不含压缩、不含审批等待**。一个改了三个文件、跑过一次构建的
  /// 任务，模型往返确实可能只有 5 秒，真实耗时却是几十秒。
  ///
  /// `0` = 该后端没提供（旧版 Kotlin / 取消路径）—— UI 显示 `—`，**不显示 0 秒**。
  final int taskWallMs;

  /// 本次运行所属会话。**没传 sessionId 时由 Kotlin 自动创建**。
  final String? sessionId;

  /// **这一轮是被用户取消的**（2026-10-13）。
  ///
  /// Kotlin 侧接住 `CancellationException` 时回 `cancelled: true`
  /// （那些字段本身就是空的）。UI 据此**不要**把空 `turns` /
  /// 空 `finalText` 当成"模型回答完了" —— 那会显示一条空回复。
  final bool cancelled;

  /// **本轮失败的人话原因**（V0.4 T0，2026-11-02）。
  ///
  /// `null` = 成功/取消/后端未上报；非 null 时 UI **必须**在会话流里显示，
  /// 不能只闪一下红条或只写「运行失败」。来源 = 事件流里的 `kFailed.message`。
  final String? failureReason;

  factory AgentRunResult.fromMap(Map<String, dynamic> m) {
    final rawTurns = (m['turns'] as List?) ?? const [];
    return AgentRunResult(
      stopReason: (m['stopReason'] as String?) ?? '',
      finalText: (m['finalText'] as String?) ?? '',
      turns: rawTurns
          .whereType<Map<dynamic, dynamic>>()
          .map((e) => AgentTurn.fromMap(e.cast<String, dynamic>()))
          .toList(),
      totalCachedTokens: (m['totalCachedTokens'] as num?)?.toInt() ?? 0,
      totalPromptTokens: (m['totalPromptTokens'] as num?)?.toInt() ?? 0,
      totalOutputTokens: (m['totalOutputTokens'] as num?)?.toInt() ?? 0,
      // 老后端没有这个字段 ⇒ 0（UI 显示 `—`），不要伪造一个数
      steadyHitRate: (m['steadyHitRate'] as num?)?.toDouble(),
      taskWallMs: (m['taskWallMs'] as num?)?.toInt() ?? 0,
      sessionId: m['sessionId'] as String?,
      cancelled: (m['cancelled'] as bool?) ?? false,
      failureReason: m['failureReason'] as String?,
    );
  }
}

/// 一轮记录（对应 Kotlin 侧 `TurnRecord`）
class AgentTurn {
  const AgentTurn({
    required this.index,
    required this.verdict,
    this.tool,
    this.args,
    this.result,
    required this.wallMs,
    this.cachedTokens,
    required this.promptTokens,
    required this.outputTokens,
    this.toolState,
  });

  final int index;
  final String verdict;
  final String? tool;
  final Map<String, String>? args;
  final String? result;
  final int wallMs;

  /// null = provider 未上报（UI 必须显示"不可用"而非 0%）
  final int? cachedTokens;
  final int promptTokens;
  final int outputTokens;

  /// 工具在本轮的**结构化三态**（2026-10-10 修复 H-1）。
  ///
  /// ## 为什么不再用 [isFailure] 猜
  ///
  /// 原先 UI 靠 `verdict.contains('失败')` 决定卡片颜色，而拦截类的
  /// verdict（"重复调用已拦截…"、"★ 检测到循环，强制停止"）**不含「失败」**
  /// → 被当成成功 → 画出**绿色成功卡**（而工具**从未执行**）。
  ///
  /// 那是比"失败"更糟的**假信息**。靠中文字符串匹配判定状态本身就是
  /// 脆弱的（改一个字就失效），所以改为消费 Kotlin 侧算好的结构化字段。
  ///
  /// `null` = 旧记录或旧后端**没有**提供该字段 —— 此时回落到
  /// [isFailure] 的启发式（并**不会**误报成功，见 [AgentTurn.fromMap]）。
  final ToolState? toolState;

  /// 工具**是否真的执行过**（含失败）。被拦截 = false。
  bool get toolExecuted =>
      toolState == ToolState.succeeded || toolState == ToolState.failed;

  /// 工具是否**成功执行** —— **唯一**允许画绿色的条件。
  ///
  /// `toolState == null`（旧数据）时回落到启发式：只有明确不是失败才当成功。
  bool get toolSucceeded =>
      toolState == ToolState.succeeded ||
      (toolState == null && tool != null && !isFailure);

  /// 工具是否**被拦截、从未执行**。
  bool get toolBlocked => toolState == ToolState.blocked;

  /// 启发式（**仅供旧数据回落**）：verdict 里含失败/拒绝/循环。
  ///
  /// ⚠️ 不要用它决定新数据的卡片颜色 —— 用 [toolState]。
  bool get isFailure =>
      verdict.contains('失败') || verdict.contains('拒绝') || verdict.contains('循环');

  TurnMetrics get metrics => TurnMetrics(
        cachedTokens: cachedTokens,
        promptTokens: promptTokens,
        outputTokens: outputTokens,
        wallMs: wallMs,
      );

  factory AgentTurn.fromMap(Map<String, dynamic> m) {
    final rawArgs = m['args'];
    return AgentTurn(
      index: (m['index'] as num?)?.toInt() ?? 0,
      verdict: (m['verdict'] as String?) ?? '',
      tool: m['tool'] as String?,
      args: rawArgs is Map
          ? rawArgs.map((k, v) => MapEntry(k.toString(), v.toString()))
          : null,
      result: m['result'] as String?,
      wallMs: (m['wallMs'] as num?)?.toInt() ?? 0,
      cachedTokens: (m['cachedTokens'] as num?)?.toInt(),
      promptTokens: (m['promptTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (m['outputTokens'] as num?)?.toInt() ?? 0,
      // ★ 结构化三态：只认已知取值，不认识就当"没提供"（走回落）
      toolState: ToolState.parse(m['toolState'] as String?),
    );
  }
}

/// **保活状态聚合**（`keepaliveStatus` 的 Dart 形状）。
///
/// ## 全字段可空是刻意的
///
/// 宿主"没给"的字段必须保持 null —— 这与"查到了、值是 false"是两回事。
/// 把缺字段补成 `false`，UI 就会把"查不到"渲染成"没在跑/没忽略"，
/// 那是编数据（`docs/INTERFACE.md` §N18.1 的"缺的不编"）。
class KeepaliveStatus {
  const KeepaliveStatus({
    this.foregroundServiceRunning,
    this.batteryIgnored,
    this.batteryNote,
    this.autostart,
  });

  /// 前台服务是否在跑（`AgentChatService.running` 真实位；null = 宿主没给）。
  final bool? foregroundServiceRunning;

  /// 是否已忽略电池优化（`PowerManager` 真实值；null = 宿主没给）。
  final bool? batteryIgnored;

  /// 口径差异提醒（如 MIUI「无限制」≠ 白名单）或读取失败原因；null = 没有提醒。
  final String? batteryNote;

  /// 当前品牌的自启动路径（null = 宿主没给/通用兜底也没拿到）。
  final ({String brand, String path})? autostart;

  /// 宽松解析：**缺的字段就是 null**（不做任何默认值补偿）。
  factory KeepaliveStatus.fromMap(Map<String, dynamic> m) {
    final auto = m['autostart'];
    final ({String brand, String path})? autostart;
    if (auto is Map) {
      final brand = (auto['brand'] as String?) ?? '';
      final path = (auto['path'] as String?) ?? '';
      autostart =
          (brand.isEmpty || path.isEmpty) ? null : (brand: brand, path: path);
    } else {
      autostart = null;
    }
    return KeepaliveStatus(
      foregroundServiceRunning: m['foregroundServiceRunning'] as bool?,
      batteryIgnored: m['batteryIgnored'] as bool?,
      batteryNote: m['batteryNote'] as String?,
      autostart: autostart,
    );
  }

  @override
  String toString() =>
      'KeepaliveStatus(fg: $foregroundServiceRunning, battery: $batteryIgnored, '
      'note: ${batteryNote == null ? '-' : '有'}, '
      'autostart: ${autostart == null ? '-' : autostart!.brand})';
}

/// 工具在一轮里的**三态**（对应 Kotlin 侧 `ToolState`）。
///
/// **被拦截 ≠ 失败** —— 这是 H-1 的根源，也是本枚举存在的理由。
enum ToolState {
  /// 本轮没有请求工具
  none,

  /// 执行了，成功
  succeeded,

  /// 执行了，失败（工具自身报错）
  failed,

  /// **请求了但从未执行** —— 架构层拦截（循环/重复/校验不过）
  blocked;

  /// 容错解析：未知/缺失 → `null`（让调用方走启发式回落，
  /// 而不是把不认识的值当成成功）。
  static ToolState? parse(String? raw) => switch (raw) {
        'succeeded' => ToolState.succeeded,
        'failed' => ToolState.failed,
        'blocked' => ToolState.blocked,
        'none' => ToolState.none,
        _ => null,
      };
}

/// **只在前台走表的一次性超时**（2026-11-02 · T0 真机纠错）。
///
/// ## 为什么不能用 `Future.timeout`
///
/// 真机 logcat 摆在那儿：
///
/// ```
/// 18:27:25.936  [heracles][picker] startActivityForResult 已发出
/// 18:28:35.514  HeraclesAct: onActivityResult req=18502 res=-1 data=true
/// ```
///
/// 结果**好好地回来了**（`res=-1` = RESULT_OK，`data` 非空），但系统选择器在前台
/// 停留了 **70 秒**（`SmartPower: visible->invisible(70217ms)`）——
/// `Future.timeout(45s)` 早在 45 秒时就判了死刑，UI 于是弹出
/// 「系统回收了文件夹选择器，选择结果已丢失」，可工作区其实登记成功了。
///
/// **这不是"超时太长/太短"的问题，是计时口径错了**：用户在系统选择器里挑文件夹，
/// 不该算作"我们的界面在干等"。
///
/// ⇒ App 进后台（选择器盖住我们）就停表，回到前台再接着走。
/// 于是 45 秒的真实含义是「用户对着**我们自己的界面**干等 45 秒」，那才该兜底。
class _ForegroundDeadline {
  _ForegroundDeadline(this.total, this.onExpire);

  final Duration total;
  final void Function() onExpire;

  Timer? _timer;
  _DeadlineObserver? _observer;
  bool _done = false;

  void start() {
    // 没有 WidgetsBinding（纯 Dart 单测）时退化成普通计时器 —— 功能不变，只是
    // 少了"后台停表"这层保护，而单测本来也不会切前后台。
    try {
      _observer = _DeadlineObserver(this);
      WidgetsBinding.instance.addObserver(_observer!);
    } catch (_) {
      _observer = null;
    }
    // ★ 按**当前**生命周期决定是否起表：调用点可能正好在后台
    //   （例如用户刚切回来、结果还没到）。`lifecycleState == null` 表示
    //   binding 还没收到第一次状态（冷启动早期）—— 按前台处理。
    final state = _currentLifecycle();
    if (state == null || state == AppLifecycleState.resumed) {
      _arm();
    }
  }

  AppLifecycleState? _currentLifecycle() {
    if (_observer == null) return null;
    try {
      return WidgetsBinding.instance.lifecycleState;
    } catch (_) {
      return null;
    }
  }

  void _arm() {
    if (_done) return;
    _timer?.cancel();
    _timer = Timer(total, () {
      if (_done) return;
      _done = true;
      onExpire();
    });
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
  }

  /// 生命周期回调：**只有 `resumed` 才走表**。
  ///
  /// `inactive`（下拉通知栏、来电话）与 `paused`（选择器/相机盖住我们）都停表：
  /// 这两种状态里用户根本没在等我们的回包。
  void onLifecycle(AppLifecycleState state) {
    if (_done) return;
    if (state == AppLifecycleState.resumed) {
      _arm();
    } else {
      _disarm();
    }
  }

  void cancel() {
    _done = true;
    _disarm();
    final o = _observer;
    if (o != null) {
      runCatchingRemoveObserver(o);
      _observer = null;
    }
  }

  static void runCatchingRemoveObserver(WidgetsBindingObserver o) {
    try {
      WidgetsBinding.instance.removeObserver(o);
    } catch (_) {
      // binding 已销毁（测试收尾）—— 忽略
    }
  }
}

/// 把 App 生命周期转给 [_ForegroundDeadline] 的观察者。
class _DeadlineObserver with WidgetsBindingObserver {
  _DeadlineObserver(this.owner);

  final _ForegroundDeadline owner;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    owner.onLifecycle(state);
  }
}
