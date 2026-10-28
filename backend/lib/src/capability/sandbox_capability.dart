/// **沙箱能力**（内联 PRoot 执行面）与**执行面路由**。
///
/// ============================================================================
/// 为什么路由规则必须写死在后端
/// ============================================================================
/// 产品定调（2026-10-28 前端转述）：
///
/// > 沙箱的消费者是 **agent**，不是前端控制台。激活后，agent 执行的命令
/// > **默认全部走沙箱**；只有沙箱做不了的（需要动 Android 本身）才落手机 shell，
/// > **例外判定后端要给明确规则，不要让模型自由发挥**。
///
/// 所以本文件是**唯一**决定「这条命令在哪跑」的地方：
/// - 规则是**命令前缀白名单**（不是让模型选，也不是问模型）
/// - 模型没有参数可以影响路由（`run_shell_command` 不暴露 surface 参数）
/// - 规则变更只改这一张表，不影响工具签名
///
/// ============================================================================
/// 为什么是「白名单例外，沙箱默认」
/// ============================================================================
/// 反过来（默认手机 shell、白名单走沙箱）会有一个致命问题：
/// **新增的命令默认落在真实手机上**，出事（污染真实文件系统）才被发现。
/// 现在是「默认落沙箱」，最坏情况是沙箱里跑不动 → 报错 → 人来加规则，
/// **错在安全侧**。
library;

import 'capabilities.dart';

/// 执行面：这条命令跑在哪儿。
enum ExecutionSurface {
  /// PRoot rootfs 内（内联沙箱）。默认值。
  sandbox('sandbox'),

  /// 真实手机 shell（需要动 Android 本身时）。
  device('device');

  const ExecutionSurface(this.wire);

  /// 事件里给前端看的标记（**不要改**，前端按它写卡片标题）。
  final String wire;
}

/// 一次路由决策的结果。
class SurfaceDecision {
  const SurfaceDecision(this.surface, this.reason, {this.matchedRule});

  final ExecutionSurface surface;

  /// 人话原因（进事件/日志，也用于解释「为什么这条走了手机」）。
  final String reason;

  /// 命中的规则名（`null` = 走默认的沙箱）。
  final String? matchedRule;
}

/// **必须落手机 shell 的命令前缀表**（唯一真相）。
///
/// 每条都要能回答「为什么沙箱做不了」：
/// - `pm` / `am` / `cmd` / `dumpsys` / `settings` / `wm` / `svc` / `monkey`
///   → 操作 **Android 框架本身**（装包、启停 Activity、改系统设置）。rootfs 里没有这些二进制。
/// - `input` / `screencap` / `screenrecord` → **操作/读取真实屏幕**。沙箱里没有对应的设备节点语义。
/// - `content` / `media` / `appops` → 访问 **Android 的 ContentProvider / 权限系统**。
/// - `su` → 需要 **真实 root**，沙箱里的 `-0` 只是假象。
/// - `getprop` / `setprop` → **系统属性**，rootfs 里没有。
/// - `install` / `uninstall` / `pm install` → 改**设备上装了什么**。
///
/// ⚠️ 新增条目必须写清「为什么沙箱做不了」，否则一律默认走沙箱。
const Map<String, String> kDeviceOnlyCommandPrefixes = {
  'pm': '操作 Android 包管理（装包/禁用/查询真实已装应用）—— rootfs 里没有 pm',
  'am': '操作 Android Activity 管理器（启停应用）—— rootfs 里没有 am',
  'cmd': 'Android shell 的 cmd 子命令（wifi/telephony/…）—— 沙箱内无此二进制',
  'dumpsys': '读取 Android 系统服务状态 —— 沙箱内无 dumpsys',
  'settings': '读写 Android 系统设置 —— 沙箱内无 settings',
  'wm': '改屏幕分辨率/密度 —— 沙箱内无 wm',
  'svc': '开关 wifi/数据/电源 —— 沙箱内无 svc',
  'monkey': '向真实应用注入事件 —— 沙箱内无 monkey',
  'input': '向真实屏幕注入触摸/按键 —— 沙箱内无 input',
  'screencap': '截真实屏幕 —— 沙箱内无 screencap',
  'screenrecord': '录真实屏幕 —— 沙箱内无 screenrecord',
  'content': '查询 Android ContentProvider —— 沙箱内无 content',
  'appops': '改应用权限（AppOps）—— 沙箱内无 appops',
  'getprop': '读系统属性 —— 沙箱内无 getprop',
  'setprop': '写系统属性 —— 沙箱内无 setprop',
  'su': '需要真实 root —— 沙箱里的 id=0 只是 PRoot 假象，不是真 root',
  'reboot': '重启设备 —— 沙箱内无 reboot',
};

/// **必须落手机 shell 的路径前缀**（命令里出现就去手机）。
///
/// 理由：沙箱只 bind 了 `@name` 挂载点、rootfs 自身、以及 `/sdcard/Android/data/<本App>`。
/// 这些路径在沙箱里要么不存在、要么指向错误的位置 —— 硬在沙箱里跑会**静默读错/写错**，
/// 比报错更危险。
const List<String> kDeviceOnlyPathPrefixes = <String>[
  '/storage/',
  '/mnt/media_rw/',
  '/system/',
  '/vendor/',
  '/odm/',
  '/data/data/',
  '/data/system',
  '/sdcard/DCIM',
  '/sdcard/Download',
  '/sdcard/Pictures',
  '/sdcard/Movies',
  '/sdcard/Documents',
];

/// 命令里是否引用了**沙箱视角**的引用（`@name`）。
final RegExp _kMountRef = RegExp(r'(?<![A-Za-z0-9_./-])@([a-z0-9_]+)');

/// 取出命令的第一个词（跳过 `VAR=val` 前缀与环境变量）。
String _firstWord(String command) {
  final tokens = command.trim().split(RegExp(r'\s+'));
  for (final t in tokens) {
    if (t.isEmpty) continue;
    // 跳过 `FOO=bar` 形式的环境变量前缀
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(t)) continue;
    // 跳过 `sudo`/`env` 之类的包装词
    if (t == 'sudo' || t == 'env' || t == 'nohup' || t == 'time') continue;
    // 去掉路径前缀：`/system/bin/pm` → `pm`
    return t.split('/').last;
  }
  return '';
}

/// 命令里是否出现「必须去手机」的路径前缀。
String? _deviceOnlyPathIn(String command) {
  for (final p in kDeviceOnlyPathPrefixes) {
    if (command.contains(p)) return p;
  }
  return null;
}

/// **决定这条命令在哪跑**。
///
/// 判定顺序（**顺序即语义，别调换**）：
/// 1. 命令引用了 `@name` 挂载点 → **沙箱**（挂载点本身就在沙箱侧解析）
/// 2. 命令首个词命中 [kDeviceOnlyCommandPrefixes] → **手机**
/// 3. 命令里出现 [kDeviceOnlyPathPrefixes] 的路径 → **手机**
/// 4. 其余 → **沙箱**（默认）
///
/// @param command      原始命令串
/// @param sandboxReady 沙箱是否已激活且可用；**false 时一律回落手机**
///                     （否则未激活沙箱的用户所有命令都会失败）
SurfaceDecision decideSurface(String command, {required bool sandboxReady}) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    return const SurfaceDecision(ExecutionSurface.sandbox, '空命令，无实际执行');
  }

  if (!sandboxReady) {
    return const SurfaceDecision(
      ExecutionSurface.device,
      '沙箱未激活（或不可用）—— 按现状回落手机 shell；激活后默认走沙箱',
      matchedRule: 'sandbox-not-ready',
    );
  }

  // 1) 显式引用挂载点 ⇒ 必须沙箱（挂载点只存在于沙箱）
  if (_kMountRef.hasMatch(trimmed)) {
    return const SurfaceDecision(
      ExecutionSurface.sandbox,
      '命令引用了 @挂载点 —— 挂载点只在沙箱内可见',
      matchedRule: 'mount-ref',
    );
  }

  // 2) Android 专有命令
  final word = _firstWord(trimmed);
  final why = kDeviceOnlyCommandPrefixes[word];
  if (why != null) {
    return SurfaceDecision(
      ExecutionSurface.device,
      '需要动 Android 本身：$why',
      matchedRule: 'command:$word',
    );
  }

  // 3) Android 专有路径
  final path = _deviceOnlyPathIn(trimmed);
  if (path != null) {
    return SurfaceDecision(
      ExecutionSurface.device,
      '命令涉及真实设备路径 `$path` —— 沙箱里没有该路径（或指向错误位置），硬跑会静默读错/写错',
      matchedRule: 'path:$path',
    );
  }

  // 4) 默认：沙箱
  return const SurfaceDecision(
    ExecutionSurface.sandbox,
    '默认走沙箱（未命中任何「必须手机」规则）',
    matchedRule: 'default',
  );
}

/// **沙箱能力**：在 PRoot rootfs 内执行命令。
///
/// 实现由宿主注入（App 侧是 `sandbox_service.dart` 的 `SandboxService`）。
/// `null` ⇒ 沙箱能力不存在，路由会把一切回落手机 shell。
abstract class SandboxCapability {
  /// 沙箱是否已激活且可用（rootfs 已装 + PRoot 可执行）。
  Future<bool> isReady();

  /// 在 rootfs 内跑一条命令。
  ///
  /// ⚠️ 实现**必须**流式转发输出（长构建可能几 MB），不得 `readAllBytes()`。
  ///
  /// 返回值约定（**与手机 shell 一致**，前端按同一套字段渲染卡片）：
  /// - `metadata['exitCode']` int
  /// - `metadata['truncated']` bool
  /// - `metadata['timedOut']` bool
  /// - `metadata['durationMs']` int
  Future<CapabilityResult> run(
    String command, {
    Duration timeout = const Duration(minutes: 5),
    void Function(String chunk)? onOutput,
  });

  /// 重置沙箱（`snapshot` 为空 = 清空重装；非空 = 回滚到该快照）。
  ///
  /// 仅设置页「重置沙箱」调用；**agent 不应自动调它**（破坏性）。
  Future<CapabilityResult> reset({String snapshot = ''});
}
