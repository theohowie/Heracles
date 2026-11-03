// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **BotGateway 纯逻辑单测**（V0.5 第一批）：状态机 / 会话派生 /
// Markdown 剥离 / 重连退避。连接器行为见 `onebot11_connector_test.dart`。
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  group('BotStateMachine — 五态迁移表（§N19.2）', () {
    test('★★★ 合法主干：unconfigured → connecting → connected', () {
      final sm = BotStateMachine();
      expect(sm.status, ContractBot.statusUnconfigured);
      sm.transitionTo(ContractBot.statusConnecting);
      sm.transitionTo(ContractBot.statusConnected);
      expect(sm.status, ContractBot.statusConnected);
    });

    test('★★★ 非法迁移抛 StateError（状态错了比崩了更危险）', () {
      final sm = BotStateMachine();
      // unconfigured 不能一步跳到 connected（必须经过 connecting）
      expect(() => sm.transitionTo(ContractBot.statusConnected),
          throwsStateError);
      // 状态必须保持不变（迁移失败不许留半态）
      expect(sm.status, ContractBot.statusUnconfigured);
    });

    test('★★ token 缺失路径：connecting → failed(带码) → connecting（退避重连）', () {
      final sm = BotStateMachine();
      sm.transitionTo(ContractBot.statusConnecting);
      sm.transitionTo(ContractBot.statusFailed,
          failureReason: ContractBot.errTokenRequired);
      expect(sm.failureReason, ContractBot.errTokenRequired);
      sm.transitionTo(ContractBot.statusConnecting);
      expect(sm.failureReason, isNull, reason: '重连时必须清掉旧原因');
    });

    test('★ stop：connected → unconfigured；connected → disabled', () {
      final sm = BotStateMachine();
      sm.transitionTo(ContractBot.statusConnecting);
      sm.transitionTo(ContractBot.statusConnected);
      sm.transitionTo(ContractBot.statusUnconfigured);
      final sm2 = BotStateMachine()
        ..transitionTo(ContractBot.statusConnecting)
        ..transitionTo(ContractBot.statusConnected)
        ..transitionTo(ContractBot.statusDisabled);
      expect(sm2.status, ContractBot.statusDisabled);
    });

    test('★ 未启用 ⇒ 初始即 disabled（disabled → connecting 可重启用）', () {
      final sm = BotStateMachine();
      sm.transitionTo(ContractBot.statusDisabled);
      sm.transitionTo(ContractBot.statusConnecting);
      expect(sm.status, ContractBot.statusConnecting);
    });
  });

  group('会话派生（§N19.6）', () {
    test('★★★ bot/qq-<chatType>-<peerId>：稳定 + 合法文件名字符', () {
      final a = botSessionIdFor(BotChatType.private, '12345');
      final b = botSessionIdFor(BotChatType.group, '98765');
      expect(a, 'bot/qq-private-12345');
      expect(b, 'bot/qq-group-98765');
      // 合法文件名字符（会落盘为会话 id）
      expect(RegExp(r'^[0-9A-Za-z/_-]+$').hasMatch(a), isTrue);
      expect(RegExp(r'^[0-9A-Za-z/_-]+$').hasMatch(b), isTrue);
    });

    test('★★ 稳定性：同输入同输出（重启可续）', () {
      expect(botSessionIdFor(BotChatType.group, '42'),
          botSessionIdFor(BotChatType.group, '42'));
    });

    test('★ 防御式清洗：peerId 出现非法字符 ⇒ 替换为 _（不抛、不塌缩）', () {
      final id = botSessionIdFor(BotChatType.private, '12/34 x');
      expect(id, 'bot/qq-private-12_34_x');
      expect(RegExp(r'^[0-9A-Za-z/_-]+$').hasMatch(id), isTrue);
    });
  });

  group('stripMarkdown（§N19.4，QQ 不渲染 MD）', () {
    test('★★★ 常见标记全剥、文字保留', () {
      expect(OneBot11Connector.stripMarkdown('**加粗** 与 `code`'),
          '加粗 与 code');
      expect(OneBot11Connector.stripMarkdown('~~删除~~ __下划__'), '删除 下划');
      expect(OneBot11Connector.stripMarkdown('## 标题\n- 项目一\n* 项目二'),
          '标题\n项目一\n项目二');
      expect(OneBot11Connector.stripMarkdown('> 引用'), '引用');
    });

    test('★ 纯文本原样（不引入也不丢内容）', () {
      expect(OneBot11Connector.stripMarkdown('hello 世界 123'), 'hello 世界 123');
    });

    test('★ URL 不改写（链接本身可点）', () {
      expect(OneBot11Connector.stripMarkdown('见 https://a.example.com/x'),
          contains('https://a.example.com/x'));
    });
  });

  group('重连退避（§N19.2）', () {
    test('★★★ 指数：2s → 4s → 8s', () {
      expect(OneBot11Connector.reconnectDelayMs(0), 2000);
      expect(OneBot11Connector.reconnectDelayMs(1), 4000);
      expect(OneBot11Connector.reconnectDelayMs(2), 8000);
    });

    test('★★★ 封顶 60s（不许无限翻倍）', () {
      expect(OneBot11Connector.reconnectDelayMs(6), 60000,
          reason: '2s*2^6=128s ⇒ 封顶 60s');
      expect(OneBot11Connector.reconnectDelayMs(20), 60000);
    });
  });
}
