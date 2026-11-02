// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 后台保活引导**（2026-11-02，对应 #2/T0）。
//
// 2026-11-02 第三版（用户裁定重做）：**行样式与设备权限页统一**——
// 浅灰圆角图标砖 + 标题 + 说明 + 右侧状态胶囊/按钮，统一分隔线，
// 卡片外壳与权限卡一致（h.surfaceAlt + HRadius.xl + 行内边距 18/13）。
// 不再发明第二套行样式。
//
// 四行的可行动口径（`keepaliveStatus` / `oemGuide` 落地前，用现有通道做到位）：
// 1) 前台服务：后端 `keepaliveStatus` 未落地 ⇒ 「未检测到（等后端读数）」
//    + 行尾「查看说明」（弹一层解释前台服务是什么、为什么需要）—— 不留死文案。
// 2) 忽略电池优化：未开启 ⇒ 「去授权」（`requestIgnoreBatteryOptimizations`，
//    真机已验证）；**通道不可用**（raw 通道探针抛 MissingPluginException /
//    测试环境无 handler 挂死）⇒ 「当前版本不支持」，与
//    「没有生效，可再试」（请求返回但状态未变）**明确区分**。
// 3) 自启动：`autostartGuide()` 的 `{brand, path}` **原样上屏** + 「复制」
//    （剪贴板 + toast）；契约红线：只引导，**不自动跳转**。
// 4) 后台弹出界面 / 锁屏显示：`oemGuide(backgroundPopup / lockScreenShow)`
//    后端未落地 ⇒ **整行隐藏，不画死行**（落地后按自启动行同款补两行）。
//
// 状态一律以 `heracles.bg.batteryIgnored` / `heracles.bg.lastKilled`
// （Android 侧写入）为准；没有数就不显示，绝不编。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/agent_bridge.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

/// 后台运行卡行 —— **与设备权限页同规格**（图标砖 + 标题 + 说明 + 右侧控件）。
///
/// 公开是为了让测试钉住「行结构复用同一规格」（组件类型断言），
/// 也给后续权限页抽共享行组件留好接口。
class KeepaliveRow extends StatelessWidget {
  const KeepaliveRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.subtitleKey,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Key? subtitleKey;

  /// 右侧控件（胶囊 / 按钮）；null = 行尾留白。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 浅灰圆角图标砖（与抽屉「设置」行/权限页同规格）
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: h.surface,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 17, color: h.text),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 15, color: h.text)),
                const SizedBox(height: 2),
                Text(subtitle,
                    key: subtitleKey,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: h.textFaint)),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class BackgroundKeepaliveCard extends StatefulWidget {
  const BackgroundKeepaliveCard({super.key, this.bridge});

  /// 电池优化 / 自启动通道（V0.4 T0-2 已落地）。测试可注入替身；
  /// 默认走真通道。
  final AgentBridge? bridge;

  /// Android/后端在"任务被系统停止"时写这个键（值为人话或时间戳）
  static const String prefsLastKilled = 'heracles.bg.lastKilled';
  /// 电池优化是否已忽略（Android 侧写入；缺省 = 未知，不编）
  static const String prefsBatteryIgnored = 'heracles.bg.batteryIgnored';

  @override
  State<BackgroundKeepaliveCard> createState() =>
      _BackgroundKeepaliveCardState();
}

class _BackgroundKeepaliveCardState extends State<BackgroundKeepaliveCard>
    with WidgetsBindingObserver {
  late final AgentBridge _bridge = widget.bridge ?? AgentBridge();

  bool? _batteryIgnored;
  String? _lastKilled;
  bool _lastKilledLoaded = false;

  /// ★ 通道缺失（后端三态语义 2026-11-02 二次裁定：requestIgnoreBattery
  /// Optimizations 返回 `null` = 旧宿主没有这条通道）⇒ 「当前版本不支持」，
  /// **不引导重试**（试多少次都一样）。
  bool _batteryUnsupported = false;

  /// 最近一次请求结果（null=通道缺失 / false=没生效 / true=已确认）。
  bool? _batteryResult;

  /// 自启动引导路径（`autostartGuide()` 原样；null = 未返回 ⇒ 通用 OEM 说明）。
  String? _autostartText;

  /// ④ 系统授权页打开期间锁按钮（防连点叠 Intent）。
  bool _openingBattery = false;

  /// 是否点过「去授权」——点过而状态仍未变 ⇒ 明说"没有生效"。
  bool _batteryAttempted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reloadPrefs();
    _loadAutostartGuide();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 回到前台（从系统授权页返回）⇒ 重读真实状态 + 重探通道。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reloadPrefs();
  }

  Future<void> _reloadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _batteryIgnored =
            p.getBool(BackgroundKeepaliveCard.prefsBatteryIgnored);
        _lastKilled = p.getString(BackgroundKeepaliveCard.prefsLastKilled);
        _lastKilledLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _lastKilledLoaded = true);
    }
  }

  Future<void> _loadAutostartGuide() async {
    try {
      final g = await _bridge.autostartGuide();
      if (!mounted) return;
      setState(() =>
          _autostartText = g == null ? null : '${g.brand}：${g.path}');
    } catch (_) {
      if (mounted) setState(() => _autostartText = null);
    }
  }

  /// 「去授权」：拉系统确认页；返回后**重读真实状态**（不乐观置位）。
  Future<void> _requestBattery() async {
    if (_openingBattery || _batteryIgnored == true) return;
    setState(() => _openingBattery = true);
    try {
      // ★ 三态（后端 2026-11-02 二次裁定）：null=通道缺失 / false=没生效 /
      //   true=已确认。null ⇒ 「当前版本不支持」并不再给按钮（试多少次都一样）。
      _batteryResult = await _bridge.requestIgnoreBatteryOptimizations();
    } finally {
      if (mounted) {
        await _reloadPrefs();
        if (mounted) {
          setState(() {
            _openingBattery = false;
            _batteryAttempted = true;
            _batteryUnsupported = _batteryResult == null;
          });
        }
      }
    }
  }

  /// 自启动路径复制到剪贴板 + toast（只引导，不跳转）。
  Future<void> _copyAutostartPath() async {
    final text = _autostartText ??
        'MIUI：设置→应用设置→应用管理→本应用→自启动；'
            'EMUI：手机管家→应用启动管理；ColorOS：设置→应用→自启动';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    showIosToast(context, '已复制自启动路径');
  }

  /// 前台服务说明层：解释它是什么、为什么需要（没有任何操作，纯科普）。
  void _showForegroundExplain(BuildContext context) {
    final h = Hue.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(),
      builder: (ctx) => SafeArea(
        child: Container(
          key: const Key('keepalive-fg-explain-sheet'),
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: h.surface,
            borderRadius: BorderRadius.circular(HRadius.lg),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('什么是前台服务？',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: h.text)),
              const SizedBox(height: 10),
              Text(
                '前台服务 = 在通知栏挂着一条常驻通知的后台进程。'
                '它是 Android 里唯一被系统"承认"的长期运行方式：'
                '没有它，长时间任务在锁屏/切走后很快会被系统冻结或杀掉。\n\n'
                '为什么需要：构建、长对话这类任务一跑几分钟，'
                '必须靠前台服务保住进程，同时让你随时能看到它还活着。\n\n'
                '当前版本的状态读数等后端 keepaliveStatus 落地后显示，'
                '届时这里会显示真实运行状态。',
                style: TextStyle(
                    fontSize: 12.5, height: 1.65, color: h.textFaint),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('知道了',
                      style: TextStyle(fontSize: 13, color: h.accent)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final batteryReady = _batteryIgnored == true;
    final channelDown = _batteryUnsupported;

    // 电池优化行右侧控件（三态互斥，绝不并排）：
    // 已开启 ⇒ 状态胶囊；通道不可用 ⇒ 「当前版本不支持」；否则 ⇒ 去授权按钮。
    Widget? batteryTrailing;
    if (batteryReady) {
      batteryTrailing = _pill(h, '已开启');
    } else if (channelDown) {
      batteryTrailing = _pill(h, '当前版本不支持',
          pillKey: const Key('keepalive-battery-unsupported'));
    } else {
      batteryTrailing = TextButton(
        key: const Key('background-battery-action'),
        // ④ 系统授权页打开期间锁按钮（防连点叠 Intent）
        onPressed: _openingBattery ? null : _requestBattery,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          minimumSize: const Size(0, 28),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          _openingBattery ? '打开中…' : '去授权',
          style: TextStyle(fontSize: 12.5, color: h.accent),
        ),
      );
    } // null（探针未回）⇒ 行尾留白，不提前下结论

    final autostartPath = _autostartText ??
        'MIUI：设置→应用设置→应用管理→本应用→自启动；'
            'EMUI：手机管家→应用启动管理；ColorOS：设置→应用→自启动';

    return Container(
      key: const Key('background-keepalive-card'),
      width: double.infinity,
      // 外壳与设备权限页卡片一致（surfaceAlt + xl 圆角 + 行内边距）
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 1) 前台服务：等后端读数，但有「查看说明」的出路 ----
          KeepaliveRow(
            icon: AppIcons.bolt,
            title: '前台服务',
            subtitle: '未检测到（等后端读数）',
            trailing: TextButton(
              key: const Key('keepalive-fg-explain'),
              onPressed: () => _showForegroundExplain(context),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('查看说明',
                  style: TextStyle(fontSize: 12.5, color: h.accent)),
            ),
          ),
          _rowDivider(h),
          // ---- 2) 忽略电池优化：去授权 / 已开启 / 当前版本不支持 ----
          KeepaliveRow(
            icon: AppIcons.bolt,
            title: '忽略电池优化',
            subtitle: _batteryIgnored == null
                ? '未检测到'
                : (batteryReady ? '已忽略（允许后台）' : '未开启（可能被限流）'),
            trailing: batteryTrailing,
          ),
          if (_batteryAttempted && !batteryReady)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
              child: Text(
                // ★ 三态话术：环境不支持 ≠ 这次没成功 —— 两种失败两种话
                channelDown
                    ? '当前版本不支持「忽略电池优化」授权入口；'
                        '后台保活仍可用，可在系统设置里手动配置。'
                    : '没有生效：已在授权页取消或被系统拒绝。可再试一次。',
                key: const Key('background-battery-note'),
                style: TextStyle(fontSize: 11, height: 1.4, color: h.textDim),
              ),
            ),
          _rowDivider(h),
          // ---- 3) 自启动：OEM 路径原样上屏 + 复制（只引导不跳转） ----
          KeepaliveRow(
            icon: AppIcons.settings,
            title: '自启动',
            subtitle: autostartPath,
            subtitleKey: const Key('keepalive-autostart-path'),
            trailing: TextButton(
              key: const Key('keepalive-autostart-copy'),
              onPressed: () => _copyAutostartPath(),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('复制',
                  style: TextStyle(fontSize: 12.5, color: h.accent)),
            ),
          ),
          // ---- 4) 后台弹出界面 / 锁屏显示：oemGuide(backgroundPopup /
          //     lockScreenShow) 后端未落地 ⇒ **整行隐藏，不画死行**。
          //     落地后在这里加两行 KeepaliveRow（同自启动行：路径 + 复制），
          //     数据源换 bridge 的 oemGuide(kind)（行结构接缝已留好）。
          if (_lastKilledLoaded &&
              _lastKilled != null &&
              _lastKilled!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
              child: Container(
                key: const Key('background-last-killed'),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: h.surface,
                  borderRadius: BorderRadius.circular(HRadius.sm),
                  border: Border.all(color: h.border),
                ),
                child: Text(
                  '上次任务在后台被系统停止（$_lastKilled）',
                  style: TextStyle(
                      fontSize: 11.5, height: 1.45, color: h.textDim),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
            child: Text(
              'Android 不保证永不被杀：系统在内存紧张/省电策略下仍可能停止后台任务。'
              '被停止后下次打开会如实提示，不会假装还在跑。',
              style: TextStyle(fontSize: 11, height: 1.5, color: h.textFaint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowDivider(Hue h) =>
      Divider(height: 1, indent: 18, endIndent: 18, color: h.border);

  /// 状态胶囊（与权限页 pill 同形：实心反色）。
  Widget _pill(Hue h, String label, {Key? pillKey}) => Container(
        key: pillKey,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: h.text,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: h.bg,
          ),
        ),
      );
}
