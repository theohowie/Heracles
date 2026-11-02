// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 失败收尾分类测试**（`classifyFailureStop` 纯函数）。
//
// | # | 用例 | 抓的缺陷 |
// |---|---|---|
// | ① | 取消 ⇒ user_cancel（不可续） | 用户停止被当成"可继续" |
// | ② | 工具预算 ⇒ token_budget（不可续） | 预算停被画成可续 |
// | ③ | **重试耗尽 + 超时原因 ⇒ provider_timeout** | provider_timeout 永无来源（死枚举） |
// | ④ | **重试耗尽 + 网络原因 ⇒ network** | network 永无来源 |
// | ⑤ | 未耗尽重试 ⇒ 不归类（普通失败仍走 failed） | 一次偶发重试就误报"网络故障" |
// | ⑥ | 轮次上限文本 ⇒ max_rounds | 轮次停被漏判 |
// | ⑦ | 普通错误 ⇒ reason=null（不伪装可续） | 失败被伪装成"可继续" |
// | ⑧ | policyOff ⇒ canContinue=false（不自动续跑） | off 模式仍给继续按钮 |
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

FailureStopClassification classify({
  String reason = '普通错误',
  bool cancelled = false,
  bool budgetReached = false,
  int retryCount = 0,
  String? lastRetryReason,
  bool policyOff = false,
}) =>
    classifyFailureStop(
      reason: reason,
      cancelled: cancelled,
      budgetReached: budgetReached,
      retryCount: retryCount,
      lastRetryReason: lastRetryReason,
      policyOff: policyOff,
    );

void main() {
  test('① 取消 ⇒ user_cancel（不可续）', () {
    final c = classify(cancelled: true, policyOff: false);
    expect(c.reason, RunStopReason.userCancel);
    expect(c.canContinue, isFalse, reason: '★ 用户主动取消不该再"自动续跑"');
  });

  test('② 工具预算 ⇒ token_budget（不可续）', () {
    final c = classify(budgetReached: true, policyOff: false);
    expect(c.reason, RunStopReason.tokenBudget);
    expect(c.canContinue, isFalse, reason: '★ 预算到顶再续只会继续烧钱');
  });

  test('③ 重试耗尽 + 超时 ⇒ provider_timeout（可续）', () {
    final c = classify(
      retryCount: ContractRunContinue.maxNetworkRetries,
      lastRetryReason: 'request timeout',
    );
    expect(c.reason, RunStopReason.providerTimeout,
        reason: '★ 这是 provider_timeout 唯一真实来源');
    expect(c.canContinue, isTrue, reason: '超时通常可重试 ⇒ 允许继续');
  });

  test('④ 重试耗尽 + 网络 ⇒ network', () {
    final c = classify(
      retryCount: ContractRunContinue.maxNetworkRetries,
      lastRetryReason: 'network unreachable',
    );
    expect(c.reason, RunStopReason.network,
        reason: '★ 这是 network 唯一真实来源');
    expect(c.canContinue, isTrue);
  });

  test('⑤ 未耗尽重试 ⇒ 不归类（普通失败仍走 failed）', () {
    final c = classify(
      retryCount: 1,
      lastRetryReason: 'network unreachable',
      reason: '普通错误',
    );
    expect(c.reason, isNull,
        reason: '★ 一次偶发重试就报"网络故障"会误导用户');
  });

  test('⑥ 轮次上限文本 ⇒ max_rounds', () {
    expect(classify(reason: 'Maximum turns reached').reason,
        RunStopReason.maxRounds);
    expect(classify(reason: '已达最大轮次').reason, RunStopReason.maxRounds);
  });

  test('⑦ 普通错误 ⇒ null（不伪装可续）', () {
    expect(classify(reason: 'Undefined name foo').reason, isNull);
  });

  test('⑧ policyOff ⇒ canContinue=false（off 模式不自动续）', () {
    final c = classify(
      retryCount: ContractRunContinue.maxNetworkRetries,
      lastRetryReason: 'timeout',
      policyOff: true,
    );
    expect(c.reason, RunStopReason.providerTimeout);
    expect(c.canContinue, isFalse,
        reason: '★ off 模式只发原因，不给"继续"按钮');
  });

  test('⑨ 优先级：取消 > 预算 > 重试耗尽', () {
    expect(
      classify(cancelled: true, budgetReached: true, retryCount: 9).reason,
      RunStopReason.userCancel,
    );
    expect(
      classify(budgetReached: true, retryCount: 9, lastRetryReason: 'timeout')
          .reason,
      RunStopReason.tokenBudget,
    );
  });
}
