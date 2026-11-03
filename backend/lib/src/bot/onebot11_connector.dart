// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **OneBot 11 连接器**（V0.5 第一批，2026-11-03；契约见 `docs/INTERFACE.md` §N19）。
//
// ## v1 范围（手机侧现实约束）
//
// · **正向 WS**：手机**拨出**到局域网 NapCat（`ws://host:port`）——手机没有公网，
//   reverse 监听进配置但默认关（v1 不实现监听）；
// · token 走 **`Authorization: Bearer` 头**（不进 URL —— URL 会进日志）；
// · **fail-closed 三条**：token 空 ⇒ 拒绝启动（不发起连接）；空白名单 = 拒绝所有人；
//   群聊 botQQ 未知 ⇒ 不响应；
// · **所有凭据读取都是注入的**（[tokenReader]/[botQqReader]/[adminReader]）：
//   backend 是纯 Dart 包，secure storage 在 App 侧 —— 本文件只认"读出来的值"，
//   并保证读到的 token **只进请求头，不进日志/审计/异常文本**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../contract/contract.dart';
import 'bot_gateway.dart';

/// 连接器配置（token **不在这里** —— 它只存在 secure storage，经 [OneBot11Connector.tokenReader] 读取）。
class OneBot11Config {
  const OneBot11Config({
    required this.host,
    required this.port,
    this.enabled = false,
    this.transport = ContractBot.transportForward,
    this.reverseEnabled = false,
  });

  final String host;
  final int port;
  final bool enabled;

  /// v1 只支持 forward；reverse 进配置但默认关（§N19.1）。
  final String transport;
  final bool reverseEnabled;
}

/// **最小 socket 接口**（真实 `WebSocket` 的窄投影）。
///
/// 为什么不直接依赖 `WebSocket`：连接必须可注入测试替身 —— 否则"token 缺失
/// 拒启且**不发起连接**"这条 fail-closed 断言没法验证（得真起一个坏连接）。
abstract class BotSocket {
  Stream<String> get messages;
  void send(String data);
  Future<void> close();
}

/// `dart:io` WebSocket 适配 [BotSocket]（生产路径）。
class IoBotSocket implements BotSocket {
  IoBotSocket._(this._ws);

  final WebSocket _ws;

  static Future<BotSocket> connect(Uri uri, Map<String, String> headers) async {
    final ws = await WebSocket.connect(uri.toString(), headers: headers);
    return IoBotSocket._(ws);
  }

  @override
  Stream<String> get messages =>
      _ws.map((e) => e is String ? e : jsonEncode(e));

  @override
  void send(String data) => _ws.add(data);

  @override
  Future<void> close() => _ws.close();
}

/// **OneBot 11 正向 WS 连接器**（实现 `BotGateway` 语义；契约 §N19）。
class OneBot11Connector {
  OneBot11Connector({
    required OneBot11Config config,
    required this.tokenReader,
    required this.botQqReader,
    required this.adminReader,
    Future<BotSocket> Function(Uri uri, Map<String, String> headers)?
        wsConnect,
    this.auditSink,
    int Function()? now,
    Future<void> Function(Duration delay)? delayFn,
    })  : _config = config,
        _wsConnect = wsConnect ?? IoBotSocket.connect,
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        _delayFn = delayFn ?? ((d) => Future<void>.delayed(d)) {
    if (!config.enabled) {
      _sm.transitionTo(ContractBot.statusDisabled);
    }
  }

  final OneBot11Config _config;
  final Future<String?> Function() tokenReader;
  final Future<String?> Function() botQqReader;
  final Future<Set<String>> Function() adminReader;
  final Future<BotSocket> Function(Uri uri, Map<String, String> headers)
      _wsConnect;
  final void Function(BotAuditEvent event)? auditSink;
  final int Function() _now;
  final Future<void> Function(Duration delay) _delayFn;

  final BotStateMachine _sm = BotStateMachine();

  /// 入站流（已过白名单/触发/去重；App 不可用时走 [drainQueued]）。
  final StreamController<BotInboundMessage> _inbound =
      StreamController<BotInboundMessage>.broadcast();

  final List<BotInboundMessage> _queue = <BotInboundMessage>[];
  bool _appAvailable = true;
  bool _stopped = false;

  BotSocket? _socket;
  int _reconnectAttempt = 0;

  /// message_id → 首见时间（去重窗口）。
  final Map<String, int> _seen = <String, int>{};

  /// 限流滑动窗口：每会话回复 / 全局主动写。
  final Map<String, List<int>> _sessionSends = <String, List<int>>{};
  final List<int> _proactiveSends = <int>[];

  /// 审计 JSONL（App 侧逐行落盘；测试直接读这里）。
  final List<String> auditJsonl = <String>[];

  // ---- 只读面（UI/宿主展示用） ----

  String get status => _sm.status;
  String? get failureReason => _sm.failureReason;
  bool get isAppAvailable => _appAvailable;
  int get queuedCount => _queue.length;
  Stream<BotInboundMessage> get inbound => _inbound.stream;

  // ---------------------------------------------------------------------------
  // 生命周期
  // ---------------------------------------------------------------------------

  /// 启动（含 fail-closed 闸）。
  ///
  /// **token 空 ⇒ `failed(E_BOT_TOKEN_REQUIRED)`，且绝不调用连接函数** ——
  /// 这是"缺凭据就不该有网络行为"的 fail-closed（单测钉死）。
  Future<void> start() async {
    if (_stopped) {
      throw StateError('Bot 连接器已停用，不能 start（请重建实例）');
    }
    _sm.transitionTo(ContractBot.statusConnecting);
    final token = (await tokenReader())?.trim() ?? '';
    if (token.isEmpty) {
      _sm.transitionTo(ContractBot.statusFailed,
          failureReason: ContractBot.errTokenRequired);
      return;
    }
    await _connect(token);
  }

  Future<void> _connect(String token) async {
    final uri = Uri(scheme: 'ws', host: _config.host, port: _config.port);
    try {
      final socket = await _wsConnect(uri, {
        // ★ token 只进请求头：URL（会进日志）上绝不带 access_token
        'Authorization': 'Bearer $token',
      });
      _socket = socket;
      _reconnectAttempt = 0; // 连接成功 ⇒ 退避重置（§N19.2）
      // NapCat 正向 WS：echo 0 回包才算就绪（契约 §N19.2）
      socket.send(jsonEncode({'action': 'get_login_info', 'echo': '0'}));
      socket.messages.listen(_onSocketData, onDone: _onSocketDown,
          onError: (Object e) => _onSocketDown());
    } catch (e) {
      final reason = _safeReason(e);
      _sm.transitionTo(ContractBot.statusFailed, failureReason: reason);
      _scheduleReconnect(token);
    }
  }

  void _onSocketData(String data) {
    try {
      final m = jsonDecode(data);
      if (m is Map) {
        // echo 0 回包 ⇒ 连接就绪
        if (m['echo'] == '0' &&
            _sm.status == ContractBot.statusConnecting) {
          _sm.transitionTo(ContractBot.statusConnected);
          return;
        }
      }
      handleEventJson(data);
    } catch (_) {
      // 单帧解析失败不影响连接（不崩、不假装收到）
    }
  }

  void _onSocketDown() {
    _socket = null;
    if (_stopped) return;
    if (_sm.status == ContractBot.statusConnected) {
      _sm.transitionTo(ContractBot.statusFailed, failureReason: '连接已断开');
    }
    _scheduleReconnect(null);
  }

  /// **重连退避**：`base * 2^attempt` 封顶 max（§N19.2）。
  ///
  /// 纯函数（单测钉死指数与封顶）；真正 sleep 用可注入 [_delayFn]。
  static int reconnectDelayMs(int attempt) {
    final d = ContractBot.reconnectBaseMs * (1 << attempt);
    return d > ContractBot.reconnectMaxMs ? ContractBot.reconnectMaxMs : d;
  }

  Future<void> _scheduleReconnect(String? token) async {
    if (_stopped) return;
    final delay = Duration(
        milliseconds: reconnectDelayMs(_reconnectAttempt));
    _reconnectAttempt += 1;
    await _delayFn(delay);
    if (_stopped) return;
    if (_sm.status == ContractBot.statusFailed) {
      _sm.transitionTo(ContractBot.statusConnecting);
    }
    final t = token ?? (await tokenReader())?.trim() ?? '';
    if (t.isEmpty) {
      // 期间凭据被清 ⇒ 回到 fail-closed 原点
      _sm.transitionTo(ContractBot.statusFailed,
          failureReason: ContractBot.errTokenRequired);
      return;
    }
    await _connect(t);
  }

  /// 用户停用（设置页关开关）⇒ `disabled` 并断开；**不再重连**。
  Future<void> disable() async {
    _stopped = true;
    _sm.transitionTo(ContractBot.statusDisabled);
    await _socket?.close();
    _socket = null;
  }

  /// stop ⇒ 回 `unconfigured`（契约 §N19.2），不再重连。
  Future<void> stop() async {
    _stopped = true;
    _sm.transitionTo(ContractBot.statusUnconfigured);
    await _socket?.close();
    _socket = null;
  }

  // ---------------------------------------------------------------------------
  // 入站
  // ---------------------------------------------------------------------------

  /// App 可用性（前台/解锁）⇒ 决定入站直接投递还是排队（§N19.3）。
  void setAppAvailable(bool available) {
    _appAvailable = available;
  }

  /// 回前台：**按序**取出队列（FIFO）交给 App 处理。
  List<BotInboundMessage> drainQueued() {
    final out = List<BotInboundMessage>.of(_queue);
    _queue.clear();
    return out;
  }

  /// **解析 + 门禁 + 投递/排队**（可单测直调：不经 socket）。
  ///
  /// 返回值：null = 被丢弃（去重/白名单/触发/队列满），非 null = 已投递或已排队。
  Future<BotInboundMessage?> handleEventJson(String raw) async {
    final ts = _now();
    Map<String, Object?> m;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      m = decoded;
    } catch (_) {
      return null;
    }
    if (m['post_type'] != 'message') return null; // 非 message 事件（meta/notice）

    final chatType = m['message_type'] == 'group'
        ? BotChatType.group
        : BotChatType.private;
    final messageId = '${m['message_id'] ?? ''}';
    if (messageId.isEmpty) return null;
    final sender = (m['sender'] as Map?) ?? const {};
    final senderId = '${sender['user_id'] ?? ''}';
    if (senderId.isEmpty) return null;
    final peerId = chatType == BotChatType.group
        ? '${m['group_id'] ?? ''}'
        : senderId;
    if (chatType == BotChatType.group && peerId.isEmpty) return null;

    // ---- 去重（§N19.3）：窗口内重复 ⇒ 静默丢弃（不审计，防刷） ----
    if (!_registerSeen(messageId, ts)) return null;

    // ---- 解析：段数组优先，CQ 回退（§N19.3） ----
    final botQq = (await botQqReader())?.trim() ?? '';
    final parsed = _parseMessage(m['message'], botQq);
    final msg = BotInboundMessage(
      messageId: messageId,
      chatType: chatType,
      peerId: peerId,
      senderId: senderId,
      text: parsed.text,
      ts: ts,
      isAtBot: parsed.isAtBot,
      isReplyToBot: parsed.isReplyToBot,
    );

    // ---- 白名单 fail-closed（§N19.3）：空白名单 = 拒绝所有人 ----
    final admins = await adminReader();
    if (!admins.contains(senderId)) {
      _audit('dropped',
          msg: msg, peerId: peerId, senderId: senderId,
          messageId: messageId, textLen: msg.text.length,
          code: ContractBot.errNotAllowed);
      return null;
    }

    // ---- 群聊触发 fail-closed（§N19.3） ----
    if (chatType == BotChatType.group) {
      final triggered = botQq.isNotEmpty && msg.isAtBot;
      if (!triggered) {
        if (botQq.isEmpty) {
          // botQQ 未知 ⇒ 连"@的是不是 bot"都无法判定 ⇒ fail-closed 信号要留痕
          _audit('dropped',
              msg: msg, peerId: peerId, senderId: senderId,
              messageId: messageId, textLen: msg.text.length,
              code: ContractBot.errGroupTriggerUnknown);
        }
        // botQQ 已知但没 @ ⇒ 普通群聊噪音，**静默忽略**（不刷审计）
        return null;
      }
    }
    // 私聊 ⇒ 恒响应（无需 @）

    if (msg.text.trim().isEmpty) return null;

    // ---- 投递 / 排队（§N19.3） ----
    _audit('inbound',
        msg: msg, peerId: peerId, senderId: senderId,
        messageId: messageId, textLen: msg.text.length);
    if (_appAvailable) {
      _inbound.add(msg);
      return msg;
    }
    if (_queue.length >= ContractBot.queueMax) {
      _audit('dropped',
          msg: msg, peerId: peerId, senderId: senderId,
          messageId: messageId, textLen: msg.text.length,
          code: ContractBot.errQueueFull);
      return null;
    }
    _queue.add(msg);
    _audit('queued',
        msg: msg, peerId: peerId, senderId: senderId,
        messageId: messageId, textLen: msg.text.length);
    return msg;
  }

  /// 去重登记：true = 首见；false = 窗口内重复。超窗清理 + 条目上限清最老。
  bool _registerSeen(String messageId, int ts) {
    final first = _seen[messageId];
    if (first != null && ts - first < ContractBot.dedupeWindowMs) {
      return false;
    }
    // 清超窗
    if (_seen.length > 64) {
      _seen.removeWhere((_, t) => ts - t >= ContractBot.dedupeWindowMs);
    }
    // 条目上限：清最老（Map 按插入序，首键即最老）
    while (_seen.length >= ContractBot.dedupeMaxEntries) {
      _seen.remove(_seen.keys.first);
    }
    _seen[messageId] = ts;
    return true;
  }

  // ---------------------------------------------------------------------------
  // 出站
  // ---------------------------------------------------------------------------

  /// **文本回复**（Markdown 剥离纯文本；限流 fail-closed：超限丢弃 + 审计）。
  ///
  /// [proactive] = 主动写（非回复触发）⇒ 走更严的全局限流（§N19.4）。
  /// 返回 false = 被限流/发送失败（已审计，**不排队** —— 收件人下次再要）。
  Future<bool> sendText({
    required BotChatType chatType,
    required String peerId,
    required String text,
    bool proactive = false,
  }) async {
    final ts = _now();
    final sessionKey =
        '${chatType == BotChatType.private ? 'p' : 'g'}:$peerId';

    // 限流：滑动窗口 60s（§N19.4）
    final window = ts - 60000;
    final sessionTimes =
        (_sessionSends[sessionKey] ??= <int>[])..removeWhere((t) => t < window);
    if (sessionTimes.length >= ContractBot.ratePerSessionPerMinute) {
      _audit('dropped',
          chatTypeName: msgType(chatType),
          peerId: peerId, textLen: text.length,
          code: ContractBot.errRateLimited);
      return false;
    }
    if (proactive) {
      _proactiveSends.removeWhere((t) => t < window);
      if (_proactiveSends.length >= ContractBot.proactivePerMinute) {
        _audit('dropped',
            chatTypeName: msgType(chatType),
            peerId: peerId, textLen: text.length,
            code: ContractBot.errRateLimited);
        return false;
      }
      _proactiveSends.add(ts);
    }
    sessionTimes.add(ts);

    final socket = _socket;
    if (socket == null || _sm.status != ContractBot.statusConnected) {
      _audit('error',
          chatTypeName: msgType(chatType),
          peerId: peerId, textLen: text.length,
          code: ContractBot.errSendFailed);
      return false;
    }

    final action = chatType == BotChatType.private
        ? {'action': 'send_private_msg',
           'params': {'user_id': num.tryParse(peerId) ?? peerId,
                      'message': stripMarkdown(text)}}
        : {'action': 'send_group_msg',
           'params': {'group_id': num.tryParse(peerId) ?? peerId,
                      'message': stripMarkdown(text)}};
    try {
      socket.send(jsonEncode(action));
    } catch (_) {
      _audit('error',
          chatTypeName: msgType(chatType),
          peerId: peerId, textLen: text.length,
          code: ContractBot.errSendFailed);
      return false;
    }
    _audit('sent',
        chatTypeName: msgType(chatType),
        peerId: peerId, textLen: text.length);
    return true;
  }

  /// **审批红线**（§N19.7）：手机未确认 ⇒ 拒绝并写历史（`approval_denied`）。
  ///
  /// 回给 QQ 的文案由调用方用 [sendText] 发（backend 只负责审计这条红线）。
  void recordApprovalDenied({
    required BotInboundMessage msg,
    required String code,
  }) {
    _audit('approval_denied',
        msg: msg, peerId: msg.peerId, senderId: msg.senderId,
        messageId: msg.messageId, textLen: msg.text.length, code: code);
  }

  // ---------------------------------------------------------------------------
  // 解析（纯函数，可单测）
  // ---------------------------------------------------------------------------

  static String msgType(BotChatType t) =>
      t == BotChatType.private ? 'private' : 'group';

  /// 段数组优先（`message` 为 List），字符串回退 CQ 码（§N19.3）。
  static ({String text, bool isAtBot, bool isReplyToBot}) _parseMessage(
      Object? message, String botQq) {
    if (message is List) return _parseSegments(message, botQq);
    return _parseCq(message is String ? message : '', botQq);
  }

  static ({String text, bool isAtBot, bool isReplyToBot}) _parseSegments(
      List segs, String botQq) {
    final buf = StringBuffer();
    var isAt = false;
    var isReply = false;
    for (final s in segs) {
      if (s is! Map) continue;
      switch (s['type']) {
        case 'text':
          buf.write('${s['data']?['text'] ?? ''}');
        case 'at':
          final qq = '${s['data']?['qq'] ?? ''}';
          if (botQq.isNotEmpty && qq == botQq) isAt = true;
          buf.write('@$qq ');
        case 'reply':
          // v1 fail-closed：reply 段只带 message_id，**无法验证被回复者**，
          // 只记录、不作为触发依据（§N19.3 的 v1 局限说明）。
          isReply = true;
        default:
          break; // face/image 等不计入文本
      }
    }
    return (text: buf.toString(), isAtBot: isAt, isReplyToBot: isReply);
  }

  static final RegExp _cqPattern =
      RegExp(r'\[CQ:(\w+)((?:,[^,\]=]+=[^\]]*)*)\]');

  /// CQ 码回退解析：`[CQ:at,qq=..]` / `[CQ:reply,id=..]` / 普通文本。
  static ({String text, bool isAtBot, bool isReplyToBot}) _parseCq(
      String raw, String botQq) {
    final buf = StringBuffer();
    var isAt = false;
    var isReply = false;
    var last = 0;
    for (final m in _cqPattern.allMatches(raw)) {
      buf.write(raw.substring(last, m.start));
      last = m.end;
      final type = m.group(1)!;
      final params = <String, String>{};
      final ps = m.group(2) ?? '';
      if (ps.isNotEmpty) {
        for (final pair in ps.split(',')) {
          final i = pair.indexOf('=');
          if (i > 0) params[pair.substring(0, i)] = pair.substring(i + 1);
        }
      }
      switch (type) {
        case 'at':
          final qq = params['qq'] ?? '';
          if (botQq.isNotEmpty && qq == botQq) isAt = true;
          buf.write('@$qq ');
        case 'reply':
          isReply = true;
        default:
          break;
      }
    }
    buf.write(raw.substring(last));
    return (text: buf.toString(), isAtBot: isAt, isReplyToBot: isReply);
  }

  /// **Markdown 剥离为纯文本**（QQ 不渲染 MD，§N19.4）。
  ///
  /// 只剥标记、保留文字内容；保守起见**不改写链接**（URL 本身可点）。
  static String stripMarkdown(String raw) {
    var s = raw;
    s = s.replaceAll('**', '');
    s = s.replaceAll('__', '');
    s = s.replaceAll('~~', '');
    s = s.replaceAll('`', '');
    s = s.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '');
    return s.trim();
  }

  // ---------------------------------------------------------------------------
  // 审计（脱敏）
  // ---------------------------------------------------------------------------

  void _audit(
    String kind, {
    BotInboundMessage? msg,
    String? chatTypeName,
    String? peerId,
    String? senderId,
    String? messageId,
    int? textLen,
    String? code,
  }) {
    final sink = auditSink;
    final event = BotAuditEvent(
      ts: _now(),
      kind: kind,
      chatType: msg != null ? msgType(msg.chatType) : chatTypeName,
      peerId: peerId,
      senderId: senderId,
      messageId: messageId,
      textLen: textLen,
      code: code,
    );
    auditJsonl.add(jsonEncode(event.toMap()));
    sink?.call(event);
  }

  /// 异常 → 审计用的**脱敏原因**：只留类型名，不带 message
  /// （SocketException 的 message 可能含 host；万一哪天带了 token 也泄不出去）。
  static String _safeReason(Object e) => '连接失败（${e.runtimeType}）';
}
