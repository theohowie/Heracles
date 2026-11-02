// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 后台保活引导**（2026-11-02，对应 #2/T0）。
//
// 只做**状态与引导**，不实现保活逻辑（Android/后端负责）。事实约束必须说清：
// 「Android 不保证永不被杀」—— 不能给用户"开了就一直跑"的错觉。
//
// 当前 services 还没有电池优化/前台服务/自启动跳转的接口 ⇒ 三个按钮先禁用并
// 说明"需要 Android 侧接口"（移交清单里写清），状态显示「未检测到」而不是编值。
// 上次任务被系统停止：读 `SharedPreferences['heracles.bg.lastKilled']`（后端/Android
// 写入；没有就不显示，绝不假装还在跑）。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

class BackgroundKeepaliveCard extends StatefulWidget {
  const BackgroundKeepaliveCard({super.key});

  /// Android/后端在"任务被系统停止"时写这个键（值为人话或时间戳）
  static const String prefsLastKilled = 'heracles.bg.lastKilled';
  /// 电池优化是否已忽略（Android 侧写入；缺省 = 未知，不编）
  static const String prefsBatteryIgnored = 'heracles.bg.batteryIgnored';

  @override
  State<BackgroundKeepaliveCard> createState() =>
      _BackgroundKeepaliveCardState();
}

class _BackgroundKeepaliveCardState extends State<BackgroundKeepaliveCard> {
  bool? _batteryIgnored;
  String? _lastKilled;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _batteryIgnored = p.getBool(BackgroundKeepaliveCard.prefsBatteryIgnored);
        _lastKilled = p.getString(BackgroundKeepaliveCard.prefsLastKilled);
      });
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
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
          if (_lastKilled != null && _lastKilled!.isNotEmpty)
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
          _statusRow(
            h,
            '电池优化',
            _batteryIgnored == null
                ? '未检测到（需要 Android 接口）'
                : (_batteryIgnored! ? '已忽略（允许后台）' : '未忽略（可能被限流）'),
          ),
          _statusRow(h, '自启动', '需在系统设置里手动允许'),
          const SizedBox(height: 10),
          // 三个入口：接口未就绪 ⇒ 禁用 + 说明（不许假成功）
          _actionRow(h, '申请忽略电池优化', '需要 Android 侧接口（已移交）'),
          _actionRow(h, '打开本应用电池设置', '需要 Android 侧接口（已移交）'),
          _actionRow(h, '打开自启动管理', 'MIUI：设置→应用设置→应用管理→本应用→自启动；'
              'EMUI：手机管家→应用启动管理；ColorOS：设置→应用→自启动'),
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
            const SizedBox(width: 6),
            Text('未就绪',
                style: TextStyle(fontSize: 10.5, color: h.textFaint)),
          ],
        ),
      );
}
