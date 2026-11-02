// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 后台保活引导**（2026-11-02，对应 #2/T0）。
//
// 只做**状态与引导**，不实现保活逻辑（Android/后端负责）。事实约束必须说清：
// 「Android 不保证永不被杀」—— 不能给用户"开了就一直跑"的错觉。
//
// 2026-11-02（F-B）：接口落地后把「未就绪」变成「可行动」——
//   · 「忽略电池优化」行：未开启 ⇒ 行内「去授权」按钮（调
//     `AgentBridge.requestIgnoreBatteryOptimizations()` 拉系统确认页），
//     回到前台 / 请求返回后**重读真实状态**（`WidgetsBindingObserver`，
//     与设备权限页同款模式）；已开启 ⇒ 只显示状态，不给按钮。
//   · 「自启动」行：调 `autostartGuide()` 拿 `{brand, path}`，路径文案
//     **原样上屏**（契约是"只引导不自动跳转"，这里不加任何跳转）。
//   · 全部调用不假成功：请求返回后状态仍以 `heracles.bg.batteryIgnored`
//     （Android 侧写入）为准；没生效就明说"没有生效：系统不支持或已取消"。
//   · 系统授权页打开期间锁按钮（防连点叠 Intent，权限页同款闸门）。
//
// 上次任务被系统停止：读 `SharedPreferences['heracles.bg.lastKilled']`
// （后端/Android 写入；没有就不显示，绝不假装还在跑）。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/agent_bridge.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

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

  /// 自启动引导路径（`autostartGuide()` 的 `{brand, path}` 原样拼接；
  /// null = 通道未返回 ⇒ 显示通用 OEM 说明，不编路径）。
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

  /// 回到前台（从系统授权页返回）⇒ 重读真实状态。
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
      // 读不到就不显示（绝不编状态）
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
      // 通道异常 ⇒ 保持通用说明（不编路径）
      if (mounted) setState(() => _autostartText = null);
    }
  }

  /// 「去授权」：拉系统确认页；返回后**重读真实状态**（不乐观置位）。
  Future<void> _requestBattery() async {
    if (_openingBattery || _batteryIgnored == true) return;
    setState(() => _openingBattery = true);
    try {
      await _bridge.requestIgnoreBatteryOptimizations();
    } finally {
      if (mounted) {
        await _reloadPrefs();
        if (mounted) {
          setState(() {
            _openingBattery = false;
            _batteryAttempted = true;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final batteryReady = _batteryIgnored == true;
    return Container(
      key: const Key('background-keepalive-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.clock, size: 16, color: h.textDim),
              const SizedBox(width: 8),
              Text('后台运行',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: h.text)),
            ],
          ),
          const SizedBox(height: 6),
          if (_lastKilledLoaded &&
              _lastKilled != null &&
              _lastKilled!.isNotEmpty)
            Container(
              key: const Key('background-last-killed'),
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: h.surface,
                borderRadius: BorderRadius.circular(HRadius.sm),
                border: Border.all(color: h.border),
              ),
              child: Text(
                '上次任务在后台被系统停止（$_lastKilled）',
                style: TextStyle(fontSize: 11.5, height: 1.45, color: h.textDim),
              ),
            ),
          _statusRow(h, '前台服务', '未检测到（需要 Android 接口）'),
          // ★ 忽略电池优化行（F-B①）：未开启 ⇒ 行内「去授权」；
          //   已开启 ⇒ 只显示状态，不给按钮。
          _batteryRow(h),
          // ★ 自启动行（F-B②）：autostartGuide 的路径原样上屏，
          //   只引导不自动跳转（契约红线）。
          _statusRow(
            h,
            '自启动',
            _autostartText ??
                'MIUI：设置→应用设置→应用管理→本应用→自启动；'
                    'EMUI：手机管家→应用启动管理；ColorOS：设置→应用→自启动',
          ),
          if (_batteryAttempted && !batteryReady)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '没有生效：系统不支持或已在授权页取消。可再试一次。',
                key: const Key('background-battery-note'),
                style: TextStyle(
                    fontSize: 11, height: 1.4, color: h.textDim),
              ),
            ),
          const SizedBox(height: 8),
          // 打开本应用电池设置：与上面同一系统页（引导兜底，通道未变）。
          _actionRow(h, '打开本应用电池设置', '同「去授权」拉起的系统页；亦可从系统设置进入'),
          const SizedBox(height: 8),
          Text(
            'Android 不保证永不被杀：系统在内存紧张/省电策略下仍可能停止后台任务。'
            '被停止后下次打开会如实提示，不会假装还在跑。',
            style: TextStyle(fontSize: 11, height: 1.5, color: h.textFaint),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(Hue h, String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: h.textDim)),
            ),
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      fontSize: 12, height: 1.45, color: h.textFaint)),
            ),
          ],
        ),
      );

  /// 忽略电池优化行：状态 + （未开启时）可点的「去授权」。
  Widget _batteryRow(Hue h) {
    final ready = _batteryIgnored == true;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: Text('电池优化',
                style: TextStyle(fontSize: 12, color: h.textDim)),
          ),
          Expanded(
            child: Text(
              _batteryIgnored == null
                  ? '未检测到'
                  : (ready ? '已忽略（允许后台）' : '未忽略（可能被限流）'),
              style: TextStyle(fontSize: 12, height: 1.45, color: h.textFaint),
            ),
          ),
          if (!ready)
            TextButton(
              key: const Key('background-battery-action'),
              // ④ 系统授权页打开期间锁按钮（防连点叠 Intent）
              onPressed: _openingBattery ? null : _requestBattery,
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _openingBattery ? '打开中…' : '去授权',
                style: TextStyle(fontSize: 12, color: h.accent),
              ),
            ),
        ],
      ),
    );
  }

  Widget _actionRow(Hue h, String label, String hint) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            SizedBox(
              width: 132,
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: h.textDim)),
            ),
            Expanded(
              child: Text(hint,
                  style: TextStyle(
                      fontSize: 10.5, height: 1.4, color: h.textFaint)),
            ),
          ],
        ),
      );
}
