// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 续跑模式三档**（2026-11-02，对应 #1）。
//
// 用户定版：**三档，不能混成一个开关**
//   · 关闭续跑 = 跑一轮就停；
//   · 每轮询问 = 每轮结束问"是否继续"（默认不自动）；
//   · 自动续跑 = 最多 3 轮；第 3 轮仍未完成 ⇒ 弹确认「继续会额外消耗 token」。
//
// 存储：`SharedPreferences['heracles.run.continueMode']` ∈ off|ask|auto。
// ⚠️ 临时落点：`AppSettings`/`SettingsController` 属 services/models（不在前端
//   写域）—— 待正式字段落地后把读写迁过去，本组件只改 `_load/_save` 两处。

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// 续跑模式（三档）设置区 —— 插进设置页「通用/模型」附近即可。
class RunContinueModeSection extends StatefulWidget {
  const RunContinueModeSection({super.key});

  static const String prefsKey = 'heracles.run.continueMode';

  /// off | ask | auto
  static String modeOf(SharedPreferences p) =>
      p.getString(prefsKey) ?? 'off';

  @override
  State<RunContinueModeSection> createState() =>
      _RunContinueModeSectionState();
}

class _RunContinueModeSectionState extends State<RunContinueModeSection> {
  String _mode = 'off';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _mode = RunContinueModeSection.modeOf(p));
    }).catchError((_) {});
  }

  Future<void> _pick(String mode) async {
    setState(() => _mode = mode);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(RunContinueModeSection.prefsKey, mode);
    } catch (_) {
      // 存不下也不回滚 UI —— 下次打开按默认 off，不会偷偷自动续跑
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Column(
      key: const Key('run-continue-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('续跑模式',
              style: HTxt.sectionTitle.copyWith(color: h.textDim)),
        ),
        _row(h, 'off', '关闭续跑', '跑一轮就停（默认，不额外消耗 token）'),
        _row(h, 'ask', '每轮询问', '每轮结束问「是否继续」，默认不自动继续'),
        _row(h, 'auto', '自动续跑',
            '最多 3 轮；第 3 轮仍未完成会弹确认（继续会额外消耗 token）'),
      ],
    );
  }

  Widget _row(Hue h, String value, String title, String subtitle) {
    final selected = _mode == value;
    return InkWell(
      key: Key('run-mode-$value'),
      onTap: () => _pick(value),
      borderRadius: BorderRadius.circular(HRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(
              selected ? CupertinoIcons.check_mark_circled : CupertinoIcons.circle,
              size: 18,
              color: selected ? h.accent : h.textFaint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                          color: h.text)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11.5, height: 1.4, color: h.textFaint)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
