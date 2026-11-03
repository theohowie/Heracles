// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **BotGateway 抽象 + 连接器状态机 + 会话绑定**（V0.5 第一批，2026-11-03；
// 契约见 `docs/INTERFACE.md` §N19）。
//
// ## 为什么状态机单独一个类
//
// 连接器（WS、重连、解析）都是 IO；状态机是**纯逻辑**。混在一起，"非法迁移
// 抛 StateError"这种断言就得拉起真 socket 才能测。抽出来后五态迁移表可以
// 被单测逐条钉死（§N19.2）。
//
// ## 红线（写进本文件，忘掉的先读这里）
//
// · 鉴权 fail-closed：token 空 ⇒ 拒绝启动，**不发起连接**；
// · 白名单 fail-closed：空白名单 = 拒绝所有人；
// · 群聊触发 fail-closed：botQQ 未知 ⇒ 群聊不响应；
// · **审批红线**：Bot 触发的危险操作走与 App 内完全相同的审批三态；
//   手机未确认 ⇒ 拒绝并写审计（`recordApprovalDenied`）——
//   **不许在无人值守时静默提权**。
library;

import '../contract/contract.dart';

/// 聊天类型（OneBot 11 的 `message_type`）。
enum BotChatType { private, group }

/// **归一后的入站消息**（已解析段/CQ、已过白名单与触发判定）。
class BotInboundMessage {
  const BotInboundMessage({
    required this.messageId,
    required this.chatType,
    required this.peerId,
    required this.senderId,
    required this.text,
    required this.ts,
    this.isAtBot = false,
    this.isReplyToBot = false,
  });

  /// OneBot `message_id`（去重键）。
  final String messageId;
  final BotChatType chatType;

  /// 私聊 = 对方 QQ；群聊 = 群号。
  final String peerId;
  final String senderId;

  /// 归一后的纯文本（段数组 text 拼接 / CQ 码剥离）。
  final String text;

  /// 群聊：是否 @了 bot（触发依据）。
  final bool isAtBot;

  /// 群聊：是否回复 bot 的消息。
  ///
  /// ⚠️ **v1 不把它当触发依据**：OneBot 11 的 reply 段只带 message_id，
  /// 无法验证被回复者是不是 bot —— fail-closed 方向宁可不响应
  /// （见 §N19.3 的 v1 局限说明）。
  final bool isReplyToBot;

  final int ts;

  /// **会话派生**：QQ 会话 ↔ Heracles 会话（稳定、合法文件名字符、重启可续）。
  ///
  /// 不做 hash —— 审计/运维里能一眼认出是哪个会话。
  String get heraclesSessionId => botSessionIdFor(chatType, peerId);
}

/// 会话派生规则（§N19.6）：`bot/qq-<chatType>-<peerId>`。
String botSessionIdFor(BotChatType chatType, String peerId) {
  final type = chatType == BotChatType.private ? 'private' : 'group';
  // peerId 只该是数字；防御式清洗（合法文件名字符），不改变正常输入
  final safePeer = peerId.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_');
  return '${ContractBot.sessionPrefix}-$type-$safePeer';
}

/// **五态状态机**（迁移表钉死，非法迁移抛 [StateError]）。
class BotStateMachine {
  String _status = ContractBot.statusUnconfigured;
  String? _failureReason;

  String get status => _status;
  String? get failureReason => _failureReason;

  /// 迁移表（§N19.2）。key = 当前态，value = 允许迁往的态。
  static const Map<String, Set<String>> _transitions = {
    ContractBot.statusUnconfigured: {
      ContractBot.statusConnecting,
      ContractBot.statusDisabled,
    },
    ContractBot.statusConnecting: {
      ContractBot.statusConnected,
      ContractBot.statusFailed,
      ContractBot.statusDisabled,
    },
    ContractBot.statusConnected: {
      // stop ⇒ unconfigured；断线重连先回 connecting；
      // ★ 断线 ⇒ failed(原因) → connecting（§N19.2 表里 connected 必须允许 failed，
      //   否则真实断线会触发非法迁移 —— 单测抓过这个洞）
      ContractBot.statusUnconfigured,
      ContractBot.statusConnecting,
      ContractBot.statusFailed,
      ContractBot.statusDisabled,
    },
    ContractBot.statusFailed: {
      // 退避到点 ⇒ 重连
      ContractBot.statusConnecting,
      ContractBot.statusDisabled,
    },
    ContractBot.statusDisabled: {
      // 重新启用：先回 unconfigured，或直接再 connecting
      ContractBot.statusUnconfigured,
      ContractBot.statusConnecting,
    },
  };

  bool canTransition(String to) =>
      _transitions[_status]?.contains(to) ?? false;

  /// 迁移；非法迁移抛 [StateError]（**不许静默吞** —— 状态错了比崩了更危险）。
  void transitionTo(String to, {String? failureReason}) {
    if (!canTransition(to)) {
      throw StateError('Bot 状态机非法迁移：$_status → $to');
    }
    _status = to;
    _failureReason = failureReason;
  }
}

/// **入站处理的审计事件**（由连接器产出，App 侧落 JSONL）。
///
/// ⚠️ 只有**元数据**：正文只记长度，token 永远不在这里出现。
class BotAuditEvent {
  const BotAuditEvent({
    required this.ts,
    required this.kind,
    this.chatType,
    this.peerId,
    this.senderId,
    this.messageId,
    this.textLen,
    this.code,
  });

  final int ts;
  final String kind;
  final String? chatType;
  final String? peerId;
  final String? senderId;
  final String? messageId;
  final int? textLen;
  final String? code;

  Map<String, Object?> toMap() {
    String? clip(String? v) {
      if (v == null) return null;
      final s = v.length > ContractBot.auditMaxChars
          ? v.substring(0, ContractBot.auditMaxChars)
          : v;
      return s;
    }

    return {
      'ts': ts,
      'kind': kind,
      if (chatType != null) 'chatType': chatType,
      if (peerId != null) 'peerId': clip(peerId),
      if (senderId != null) 'senderId': clip(senderId),
      if (messageId != null) 'messageId': clip(messageId),
      if (textLen != null) 'textLen': textLen,
      if (code != null) 'code': code,
    };
  }
}
