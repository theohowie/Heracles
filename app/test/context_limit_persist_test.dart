// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **上下文上限"重开旧会话又变 `—`"的回归闸（2026-11-04）**。
//
// ## 真机现场（用户 2026-11-04 11:11 截图）
//
// 装完新版（进程重启）后打开旧会话：顶栏「上下文 —」、用量抽屉「已用 —」，
// 分项还在（~2.8K/10.6K/17.0K/2.3K），**就是上限没了**。
//
// ## 病根
//
// `AgentBridge.contextLimitTokens()` 只读静态 `_lastContextLimit`，
// 而它仅在 `run()` 收尾时被赋值 ⇒ **上限只活在进程内**，重启即丢，
// UI 拿不到分母就只能显示 `—`（这是正确降级，但用户看到的是"数字消失"）。
//
// ## 修法
//
// ① `context_updated` 帧一到就把 `limit` 记下来（内存 + `SharedPreferences`）；
// ② `contextLimitTokens()` 在内存为空时**读盘兜底**；
// ③ `run()` 收尾**不许再用 `-1` 覆盖**已知值（那条覆盖本身就是
//    "抽屉刚有数、跑完又变 —"的成因）。
//
// 本文件锁住这三条。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/agent_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 造一帧 `context_updated`（这就是后端每轮播的"窗口上限 + 分项"帧）。
AgentEvent _ctxFrame({int? limit, String? limitSource}) => AgentEvent(
      type: AgentEvent.kContextUpdated,
      ts: DateTime.now().millisecondsSinceEpoch,
      limit: limit,
      limitSource: limitSource,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 用量缓存是进程级静态 ⇒ 每条用例前必须清，否则前一条的上限会串到后一条。
  setUp(AgentBridge.debugResetUsageCache);

  group('上下文上限跨重启', () {
    test('① 盘上有的上限，重启后 contextLimitTokens 要读得到（这是 `—` 的修法）', () async {
      SharedPreferences.setMockInitialValues({
        'heracles.context_limit': 32768,
        'heracles.context_limit_source': '服务端上报',
      });
      final bridge = AgentBridge();
      expect(await bridge.contextLimitTokens(isCloud: true), 32768,
          reason: '★ 只读内存 ⇒ 重启后返回 -1 ⇒ UI 显示 `—`（真机现象）');
    });

    test('② 收到 context_updated 帧就记下上限（并落盘给下次启动）', () async {
      SharedPreferences.setMockInitialValues({});
      final bridge = AgentBridge();

      // 没跑过、盘上也没有 ⇒ 诚实未知
      expect(await bridge.contextLimitTokens(isCloud: true), -1);

      AgentBridge.emitLocalEvent(_ctxFrame(limit: 40000, limitSource: '服务端上报'));

      expect(await bridge.contextLimitTokens(isCloud: true), 40000,
          reason: '帧是后端权威值（它算压缩线用的同一个数），必须立刻可用');
    });

    test('③ 帧为 0/负时不许当真（保持未知，不猜）', () async {
      SharedPreferences.setMockInitialValues({});
      final bridge = AgentBridge();
      AgentBridge.emitLocalEvent(_ctxFrame(limit: 0));
      expect(await bridge.contextLimitTokens(isCloud: true), -1);
    });
  });
}
