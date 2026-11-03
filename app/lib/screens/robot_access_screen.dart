// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **机器人接入二级页**（2026-11-03，对应 #7）。
//
// 后端 §N19 未落地 ⇒ 本轮**整页降级**：
// · 三张卡：飞书 / QQ(OneBot) / 微信官方；
// · 只有 OneBot 卡画**配置表单骨架**（模式 / 地址 / accessToken 掩码 /
//   botQQ / adminUsers / 启停 / 连接测试），但通道没接通 ⇒
//   整卡降级「接口未接通 + 需要什么」，保存/测试按钮**禁用**，不画假开关；
// · 飞书 / 微信官方卡：「下一批（需云中继）」；
// · 页面必须明示两句话：
//   「手机离线时消息排队」「Bot 不能绕过审批，危险操作仍需手机确认」。
//
// ## §N19 落地后的接线接缝
//
// 每张 OneBot 卡对应一个连接状态，四态：
// `未配置 / 连接中 / 已连接 / 失败`（[_BotStatus]）。
// 落地后：卡片读 `robotOnebotStatus()`（TODO 通道）→ 按态渲染
// 状态胶囊；表单启用 → 保存调 `saveOnebotConfig()`；连接测试调
// `testOnebotConnection()`。表单字段与通道字段一一对应，不用改结构。
//
// 样式沿用权限页 / KeepaliveRow 规格。

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/elastic_switch.dart';
import '../widgets/background_keepalive_card.dart';

/// OneBot 连接状态（§N19 落地后的四态；本轮全部停在「未配置」）：
/// `未配置 / 连接中 / 已连接 / 失败` —— 落地后在此声明 enum 并接
/// `robotOnebotStatus()`（TODO 通道），卡片按态渲染状态胶囊。
class RobotAccessScreen extends StatelessWidget {
  const RobotAccessScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return Scaffold(
      backgroundColor: h.bg,
      appBar: AppBar(
        title: const Text('机器人接入'),
        leading: IconButton(
          icon: const Icon(AppIcons.back, size: 21),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding:
            const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.lg, HSpace.xl),
        children: [
          // ---- QQ(OneBot)：表单骨架 + 整卡降级 ----
          _onebotCard(h),
          const SizedBox(height: HSpace.md),
          // ---- 飞书 / 微信官方：下一批（需云中继） ----
          _nextBatchCard(h, '飞书'),
          _nextBatchCard(h, '微信官方'),
          const SizedBox(height: HSpace.md),
          // ---- 两句必须明示的话（用户裁定，一字不改） ----
          Container(
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
                    Icon(AppIcons.info, size: 15, color: h.textDim),
                    const SizedBox(width: 8),
                    Text('必须知道的',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: h.text)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '· 手机离线时消息排队：Bot 收到的消息不会丢，'
                  '回到 App 后按序处理。\n'
                  '· Bot 不能绕过审批：危险操作仍需手机确认，'
                  '与聊天页同一套 Allow / NeedsApproval / Deny 判定。',
                  key: const Key('robot-caveats'),
                  style: TextStyle(
                      fontSize: 12, height: 1.65, color: h.textFaint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill(Hue h, String label, {Key? pillKey}) => Container(
        key: pillKey,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: h.text,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: h.bg)),
      );

  /// OneBot 卡：表单骨架（全部禁用）+ 降级说明。
  Widget _onebotCard(Hue h) => Container(
        key: const Key('robot-onbot-card'),
        width: double.infinity,
        decoration: BoxDecoration(
          color: h.surfaceAlt,
          borderRadius: BorderRadius.circular(HRadius.xl),
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KeepaliveRow(
              icon: AppIcons.terminal,
              title: 'QQ（OneBot）',
              subtitle: '接口未接通：本轮只有表单骨架，还不能保存或连接',
              subtitleKey: const Key('robot-onbot-degraded'),
              trailing: _pill(h, '接口未接通',
                  pillKey: const Key('robot-onbot-status')),
            ),
            // 需要什么（§N19）
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                '需要：后端 §N19 机器人接入通道（OneBot 收发、事件回传、'
                '离线消息队列与配置落盘）。落地后此卡自动激活，'
                '状态四态：未配置 / 连接中 / 已连接 / 失败。',
                style: TextStyle(fontSize: 12, height: 1.55, color: h.textFaint),
              ),
            ),
            Divider(height: 1, indent: 18, endIndent: 18, color: h.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('模式',
                      style:
                          TextStyle(fontSize: 12, color: h.textDim)),
                  const SizedBox(height: 4),
                  AbsorbPointer(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: 0.45,
                        child: Text('正向 WebSocket（ws://）｜反向 WebSocket',
                            style: TextStyle(
                                fontSize: 12.5, color: h.textFaint)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('robot-onbot-endpoint'),
                    enabled: false,
                    controller: TextEditingController(text: 'ws://（待后端通道落地）'),
                    style: TextStyle(fontSize: 12.5, color: h.textFaint),
                    decoration: const InputDecoration(labelText: '地址'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('robot-onbot-token'),
                    enabled: false,
                    obscureText: true, // ★ accessToken 掩码显示
                    controller: TextEditingController(text: 'accessToken'),
                    style: TextStyle(fontSize: 12.5, color: h.textFaint),
                    decoration:
                        const InputDecoration(labelText: 'accessToken（掩码显示）'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    enabled: false,
                    controller: TextEditingController(text: '（机器人 QQ 号）'),
                    style: TextStyle(fontSize: 12.5, color: h.textFaint),
                    decoration: const InputDecoration(labelText: 'botQQ'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    enabled: false,
                    controller: TextEditingController(text: '（管理员 QQ 号，逗号分隔）'),
                    style: TextStyle(fontSize: 12.5, color: h.textFaint),
                    decoration: const InputDecoration(labelText: 'adminUsers'),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(child: Text('启停')),
                      // 不画假开关：ElasticSwitch 禁用态（onChanged null）
                      const ElasticSwitch(value: false, onChanged: null),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const Key('robot-onbot-test'),
                      onPressed: null, // 通道未接通 ⇒ 禁用（不假测试）
                      child: Text('连接测试',
                          style:
                              TextStyle(fontSize: 13, color: h.textFaint)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  /// 飞书 / 微信官方：「下一批（需云中继）」—— 不画表单。
  Widget _nextBatchCard(Hue h, String title) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        decoration: BoxDecoration(
          color: h.surfaceAlt,
          borderRadius: BorderRadius.circular(HRadius.xl),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 15, color: h.text)),
                  const SizedBox(height: 2),
                  Text('下一批（需云中继）：手机没网时收不到消息，'
                      '需要一台中继来代理事件。',
                      style: TextStyle(
                          fontSize: 12.5, height: 1.45, color: h.textFaint)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _pill(h, '下一批'),
          ],
        ),
      );
}
