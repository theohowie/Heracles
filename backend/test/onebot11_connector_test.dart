// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **OneBot 11 连接器行为单测**（V0.5 第一批；契约 §N19）。
//
// 全部走注入缝（wsConnect/时钟/delay），**不碰真网络**；
// 真实 NapCat 连通性无凭据 ⇒ 标"未验证"（§N19.9）。
import 'dart:async';
import 'dart:convert';

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 可编程假 socket（记录发出的帧，喂入收到的帧）。
class FakeBotSocket implements BotSocket {
  final controller = StreamController<String>.broadcast();
  final List<String> sent = <String>[];
  int closeCount = 0;

  @override
  Stream<String> get messages => controller.stream;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close() async => closeCount++;

  void receive(Map<String, Object?> json) =>
      controller.add(jsonEncode(json));
}

void main() {
  late FakeBotSocket socket;
  late List<Duration> delays;
  late int ts;
  late OneBot11Connector c;

  final connectCalls = <({Uri uri, Map<String, String> headers})>[];

  Future<BotSocket> fakeConnect(Uri uri, Map<String, String> headers) async {
    connectCalls.add((uri: uri, headers: headers));
    return socket;
  }

  OneBot11Connector build({
    String? token = 'tok',
    String? botQq = '10000',
    Set<String> admins = const {'10001'},
    bool enabled = true,
  }) {
    return OneBot11Connector(
      config: OneBot11Config(
          host: '192.168.1.10', port: 3001, enabled: enabled),
      tokenReader: () async => token,
      botQqReader: () async => botQq,
      adminReader: () async => admins,
      wsConnect: fakeConnect,
      now: () => ts,
      // ★ delayFn 必须让渡事件队列（真实实现是 timer）：
      //   若纯微任务，断线后"重连→已关闭流→done→重连"会变成微任务自旋，
      //   饿死测试体（这个坑真实踩过：测试挂死在断线用例）。
      delayFn: (d) async {
        delays.add(d);
        await Future<void>.delayed(Duration.zero);
      },
    );
  }

  /// 等一个事件循环：broadcast 流投递是微任务，echo 后要让 listener 跑完
  Future<void> pump() => Future<void>.delayed(Duration.zero);

  /// 推一条群/私聊事件（段数组或 CQ 字符串）。
  Map<String, Object?> event({
    required Object message,
    String? messageId = 'm1',
    String messageType = 'private',
    int userId = 10001,
    int? groupId,
  }) =>
      {
        'post_type': 'message',
        'message_type': messageType,
        'message_id': messageId,
        'sender': {'user_id': userId},
        if (groupId != null) 'group_id': groupId,
        'message': message,
      };

  setUp(() {
    socket = FakeBotSocket();
    delays = <Duration>[];
    ts = 1000000;
    connectCalls.clear();
    c = build();
  });

  group('fail-closed：启动闸（§N19.2）', () {
    test('★★★ token 缺失 ⇒ failed(E_BOT_TOKEN_REQUIRED) 且【不发起连接】', () async {
      c = build(token: '   ');
      await c.start();

      expect(c.status, ContractBot.statusFailed);
      expect(c.failureReason, ContractBot.errTokenRequired);
      expect(connectCalls, isEmpty,
          reason: '缺凭据就不该有网络行为 —— 这是 fail-closed 的核心断言');
      expect(socket.sent, isEmpty);
    });

    test('★★ 未启用 ⇒ 初始即 disabled（不连接）', () {
      c = build(enabled: false);
      expect(c.status, ContractBot.statusDisabled);
      expect(connectCalls, isEmpty);
    });

    test('★★★ 正常启动：echo 0 回包 ⇒ connected，token 进 Bearer 头', () async {
      await c.start();
      // echo 请求已发出（get_login_info），但此刻**还没** connected
      expect(c.status, ContractBot.statusConnecting);
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});
      await pump();
      expect(c.status, ContractBot.statusConnected);
      expect(connectCalls.single.uri.toString(), 'ws://192.168.1.10:3001',
          reason: '★ URL 上绝不带 token（URL 会进日志）');
      expect(connectCalls.single.headers['Authorization'], 'Bearer tok');
    });
  });

  group('入站解析（§N19.3：段数组优先，CQ 回退）', () {
    setUp(() async {
      await c.start();
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});
      await pump();
    });

    test('★★★ 段数组：text 拼接 + @bot 判定（at qq == botQQ）', () async {
      final m = await c.handleEventJson(jsonEncode(event(message: [
        {'type': 'text', 'data': {'text': '帮我 '}},
        {'type': 'at', 'data': {'qq': '10000'}},
        {'type': 'text', 'data': {'text': '看看日志'}},
      ])));
      expect(m, isNotNull);
      expect(m!.text, '帮我 @10000 看看日志');
      expect(m.isAtBot, isTrue);
      expect(m.heraclesSessionId, 'bot/qq-private-10001');
    });

    test('★★ CQ 回退：字符串消息剥离 CQ 码取文本', () async {
      final m = await c.handleEventJson(jsonEncode(
          event(message: '前缀[CQ:face,id=1]正文[CQ:image,file=a.png]')));
      expect(m!.text, '前缀正文');
    });

    test('★ 非 message 事件（meta/notice）⇒ 忽略', () async {
      expect(
          await c.handleEventJson(
              jsonEncode({'post_type': 'meta_event', 'meta_event_type': 'heartbeat'})),
          isNull);
    });
  });

  group('fail-closed：白名单与群聊触发（§N19.3）', () {
    setUp(() async {
      await c.start();
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});
      await pump();
    });

    test('★★★ 白名单外 ⇒ 丢弃 + 审计 E_BOT_NOT_ALLOWED（正文不进审计）', () async {
      final m = await c.handleEventJson(jsonEncode(event(
          message: '这是一条秘密正文', userId: 99999)));
      expect(m, isNull);
      final dropped = c.auditJsonl
          .map(jsonDecode)
          .where((e) => e['code'] == ContractBot.errNotAllowed)
          .toList();
      expect(dropped, hasLength(1));
      expect(jsonEncode(dropped.single).contains('秘密正文'), isFalse,
          reason: '★ 审计只记元数据 —— 正文永不上账');
      expect(dropped.single['textLen'], '这是一条秘密正文'.length);
    });

    test('★★★ 空白名单 = 拒绝所有人（fail-closed）', () async {
      c = build(admins: const {});
      await c.start();
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});

      final m = await c.handleEventJson(jsonEncode(event(
          message: 'hi', messageId: 'm9', userId: 10001)));
      expect(m, isNull, reason: '空白名单必须连管理员本人都拒 —— 宁可全拒不可漏放');
      expect(
          c.auditJsonl.map(jsonDecode).any((e) =>
              e['code'] == ContractBot.errNotAllowed),
          isTrue);
    });

    test('★★★ 群聊没 @ ⇒ 静默忽略（普通群聊噪音不刷审计）', () async {
      final m = await c.handleEventJson(jsonEncode(event(
          message: '大家周末干嘛', messageId: 'm2',
          messageType: 'group', groupId: 555)));
      expect(m, isNull);
      expect(c.auditJsonl, isEmpty, reason: '普通群聊不该留痕');
    });

    test('★★★ 群聊 @ 了 bot ⇒ 响应；botQQ 未知 ⇒ E_BOT_GROUP_TRIGGER_UNKNOWN',
        () async {
      // 已知 botQQ + @bot ⇒ 投递
      final m = await c.handleEventJson(jsonEncode(event(
          message: [
            {'type': 'at', 'data': {'qq': '10000'}},
            {'type': 'text', 'data': {'text': ' 报告状态'}},
          ],
          messageId: 'm3',
          messageType: 'group',
          groupId: 555)));
      expect(m, isNotNull);
      expect(m!.peerId, '555');

      // botQQ 未知 ⇒ 即便 @ 了也拒（无法判定 @ 的是谁）
      final c2 = build(botQq: '');
      await c2.start();
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});
      final m2 = await c2.handleEventJson(jsonEncode(event(
          message: [
            {'type': 'at', 'data': {'qq': '10000'}},
          ],
          messageId: 'm4',
          messageType: 'group',
          groupId: 555)));
      expect(m2, isNull);
      expect(
          c2.auditJsonl.map(jsonDecode).any((e) =>
              e['code'] == ContractBot.errGroupTriggerUnknown),
          isTrue);
    });

    test('★★ 去重窗口：同 message_id 只处理一次', () async {
      final e = jsonEncode(event(message: 'hello', messageId: 'dup1'));
      final first = await c.handleEventJson(e);
      final second = await c.handleEventJson(e);
      expect(first, isNotNull);
      expect(second, isNull, reason: 'NapCat 重连会重推事件 —— 窗口内必须去重');
    });
  });

  group('离线排队（§N19.3）', () {
    setUp(() async {
      await c.start();
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});
      c.setAppAvailable(false);
    });

    test('★★★ App 不可用 ⇒ 入队（FIFO），回前台按序 drain', () async {
      await c.handleEventJson(jsonEncode(event(message: '一', messageId: 'q1')));
      ts += 10;
      await c.handleEventJson(jsonEncode(event(message: '二', messageId: 'q2')));

      expect(c.queuedCount, 2);
      final drained = c.drainQueued();
      expect(drained.map((e) => e.text.replaceFirst('@10000 ', '')),
          ['一', '二'], reason: '必须按序');
      expect(c.queuedCount, 0, reason: 'drain 即清空');
    });

    test('★★★ 队列满 ⇒ 丢弃 + 审计 E_BOT_QUEUE_FULL（上限钉死）', () async {
      for (var i = 0; i < 50; i++) {
        final r = await c.handleEventJson(
            jsonEncode(event(message: 'm$i', messageId: 'f$i')));
        expect(r, isNotNull);
      }
      // 第 51 条 ⇒ 满
      final overflow = await c.handleEventJson(
          jsonEncode(event(message: '溢出', messageId: 'overflow')));
      expect(overflow, isNull);
      expect(c.queuedCount, 50);
      expect(
          c.auditJsonl.map(jsonDecode).any((e) =>
              e['code'] == ContractBot.errQueueFull),
          isTrue);
    });
  });

  group('出站限流与审计（§N19.4）', () {
    setUp(() async {
      await c.start();
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});
      await pump();
    });

    test('★★★ 每会话限流：第 11 条 ⇒ 丢弃 + 审计 E_BOT_RATE_LIMITED', () async {
      for (var i = 0; i < 10; i++) {
        expect(
            await c.sendText(
                chatType: BotChatType.private, peerId: '10001', text: 'r$i'),
            isTrue);
      }
      expect(
          await c.sendText(
              chatType: BotChatType.private, peerId: '10001', text: '第11条'),
          isFalse);
      expect(
          c.auditJsonl.map(jsonDecode).any((e) =>
              e['code'] == ContractBot.errRateLimited),
          isTrue);
    });

    test('★★ 主动写限流：第 4 条 ⇒ 丢弃（全局 3 条/分钟）', () async {
      for (var i = 0; i < 3; i++) {
        expect(
            await c.sendText(
                chatType: BotChatType.private,
                peerId: '1000$i',
                text: 'p$i',
                proactive: true),
            isTrue);
      }
      expect(
          await c.sendText(
              chatType: BotChatType.private,
              peerId: '10003',
              text: 'p3',
              proactive: true),
          isFalse,
          reason: '主动写是全局限流 —— 换会话也不给绕');
    });

    test('★★ 出站帧是 OneBot action（send_private/send_group），且为剥壳纯文本',
        () async {
      await c.sendText(
          chatType: BotChatType.private,
          peerId: '10001',
          text: '**要点**：\n- 修好了 `bug`');
      final frame = jsonDecode(socket.sent.last) as Map;
      expect(frame['action'], 'send_private_msg');
      expect(frame['params']['message'], '要点：\n修好了 bug');
    });

    test('★ 断线时发送 ⇒ 审计 E_BOT_SEND_FAILED 且返回 false', () async {
      // 模拟真断线：close + 流 done（真实 WebSocket 断开都会触发 onDone）
      await socket.close();
      socket.controller.close();
      await pump();
      expect(c.status, ContractBot.statusFailed);
      final ok = await c.sendText(
          chatType: BotChatType.private, peerId: '10001', text: 'hi');
      expect(ok, isFalse);
      expect(
          c.auditJsonl.map(jsonDecode).any((e) =>
              e['code'] == ContractBot.errSendFailed),
          isTrue);
      // ★ 假 socket 的流被永久关闭 ⇒ 重连会立刻拿回"已关闭"的流形成自旋
      //   （真 socket 有真实退避延时，不会这样）—— 停用连接器断开循环
      await c.disable();
      expect(c.status, ContractBot.statusDisabled);
    });
  });

  group('审批红线（§N19.7）', () {
    setUp(() async {
      await c.start();
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});
      await pump();
    });

    test('★★★ 手机未确认 ⇒ 审计 approval_denied（拒绝要留痕）', () async {
      final msg = await c.handleEventJson(jsonEncode(event(
          message: '删掉所有日志', messageId: 'a1')));
      c.recordApprovalDenied(
          msg: msg!, code: 'E_APPROVAL_DENIED');
      final line = c.auditJsonl.map(jsonDecode).lastWhere(
          (e) => e['kind'] == 'approval_denied');
      expect(line['code'], 'E_APPROVAL_DENIED');
      expect(jsonEncode(line).contains('删掉所有日志'), isFalse,
          reason: '红线事件也只记元数据');
    });
  });

  group('审计脱敏（§N19.5）', () {
    setUp(() async {
      await c.start();
      socket.receive({'status': 'ok', 'retcode': 0, 'echo': '0'});
      await pump();
    });

    test('★★★ 全部审计行不含 token（token 只进请求头）', () async {
      await c.handleEventJson(jsonEncode(event(message: 'x', messageId: 't1')));
      for (final line in c.auditJsonl) {
        expect(line.contains('tok'), isFalse,
            reason: '★ token 绝不能出现在审计里');
      }
    });
  });
}
