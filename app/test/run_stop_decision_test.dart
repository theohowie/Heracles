/// **V0.4 续跑判定矩阵**（`decideRunStop` 纯函数）。
///
/// ## 为什么单独测这个
///
/// 策略矩阵（off/ask/auto × 轮数/token/取消/失败/完成/无进展）如果只在
/// 端到端假 LLM 里覆盖，用例昂贵且容易"绿但没测到"；抽成纯函数后逐条断言。
///
/// | # | 用例 | 抓的缺陷 |
/// |---|---|---|
/// | ① | off + 未完成 ⇒ 不发（旧行为） | 默认被悄悄改成"自动续跑" |
/// | ② | ask ⇒ 每轮结束待确认 canContinue=true | 每轮询问语义丢失 |
/// | ③ | auto + 未到上限 ⇒ 不发（宿主自动续） | 提前打断自动续跑 |
/// | ④ | auto + 到上限 ⇒ max_rounds + canContinue | 无限续跑 / 到上限不停 |
/// | ⑤ | token 先到 ⇒ token_budget（off 下也如实报） | 预算停被吞 / 原因混成轮数 |
/// | ⑥ | 取消 ⇒ user_cancel（off 也发） | 用户停止被当成"失败" |
/// | ⑦ | failed ⇒ 不发（失败不是"可续"） | 失败被伪装成可续 |
/// | ⑧ | 已完成 ⇒ 不发 | 完成被画成"中断" |
/// | ⑨ | 无进展 ≥2 ⇒ no_progress + 人话摘要 | 打转不停 |
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:heracles/services/local_agent.dart';
import 'package:heracles_backend/heracles_backend.dart';

RunStopDecision? call({
  ContinuePolicy policy = ContinuePolicy.off,
  bool cancelled = false,
  bool failed = false,
  bool taskDone = false,
  int round = 1,
  int maxRounds = 3,
  int tokensSpent = 1000,
  int tokenLimit = 2000000,
  int noProgressStreak = 0,
}) =>
    decideRunStop(
      policy: policy,
      cancelled: cancelled,
      failed: failed,
      taskDone: taskDone,
      round: round,
      maxRounds: maxRounds,
      tokensSpent: tokensSpent,
      tokenLimit: tokenLimit,
      noProgressStreak: noProgressStreak,
      noProgressRounds: ContractRunContinue.noProgressRounds,
    );

void main() {
  test('① off + 未完成 ⇒ 不发（旧行为不变）', () {
    expect(call(policy: ContinuePolicy.off), isNull);
  });

  test('② ask ⇒ 每轮结束都待确认（canContinue=true，人话摘要）', () {
    final d = call(policy: ContinuePolicy.ask);
    expect(d, isNotNull);
    expect(d!.reason, 'max_rounds');
    expect(d.canContinue, isTrue);
    expect(d.summary, contains('等待确认'));
  });

  test('③ auto + 未到上限 ⇒ 不发（宿主自动续跑）', () {
    expect(call(policy: ContinuePolicy.auto, round: 1, maxRounds: 3), isNull);
    expect(call(policy: ContinuePolicy.auto, round: 2, maxRounds: 3), isNull);
  });

  test('④ auto + 到上限 ⇒ max_rounds + canContinue（不再无限续）', () {
    final d = call(policy: ContinuePolicy.auto, round: 3, maxRounds: 3);
    expect(d, isNotNull);
    expect(d!.reason, 'max_rounds');
    expect(d.canContinue, isTrue, reason: '★ 到上限要停下来问用户');
    expect(d.summary, contains('上限'));
  });

  test('⑤ token 先到 ⇒ token_budget（即使 off 也如实报原因）', () {
    final d = call(
      policy: ContinuePolicy.off,
      tokensSpent: 2000000,
      tokenLimit: 2000000,
    );
    expect(d, isNotNull);
    expect(d!.reason, 'token_budget');
    expect(d.canContinue, isFalse, reason: 'off 模式不许自动续');
    expect(d.summary, contains('token'));
  });

  test('⑥ 取消 ⇒ user_cancel（off 也发，且不可续）', () {
    final d = call(cancelled: true);
    expect(d, isNotNull);
    expect(d!.reason, 'user_cancel');
    expect(d.canContinue, isFalse);
  });

  test('⑦ failed ⇒ 不发（失败不是"可续"）', () {
    expect(call(failed: true, policy: ContinuePolicy.auto), isNull);
  });

  test('⑧ 已完成 ⇒ 不发（完成不画成中断）', () {
    expect(call(taskDone: true, policy: ContinuePolicy.auto), isNull);
    expect(call(taskDone: true, policy: ContinuePolicy.ask), isNull);
  });

  test('⑨ 连续 2 轮无进展 ⇒ no_progress + 人话摘要（不编数）', () {
    final d = call(noProgressStreak: 2, policy: ContinuePolicy.auto);
    expect(d, isNotNull);
    expect(d!.reason, 'no_progress');
    expect(d.summary, contains('没有进展'));
    // 只有 1 轮无进展 ⇒ 不停（可能是正常探查）
    expect(call(noProgressStreak: 1), isNull);
  });

  test('⑩ 优先级：取消 > token > 无进展 > 轮次', () {
    final cancelledWins = call(
      cancelled: true,
      tokensSpent: 2000000,
      noProgressStreak: 5,
      policy: ContinuePolicy.auto,
    );
    expect(cancelledWins!.reason, 'user_cancel');

    final tokenWins = call(
      tokensSpent: 2000000,
      noProgressStreak: 5,
      policy: ContinuePolicy.auto,
    );
    expect(tokenWins!.reason, 'token_budget');
  });
}
