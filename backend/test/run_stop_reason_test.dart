/// **长任务续跑（V0.4）契约测试** —— `RunStopReason` / `HeraclesRunStopped` /
/// `ContinuePolicy` 的 wire 形状与默认值。
///
/// ## 这个文件抓什么缺陷
///
/// | # | 用例 | 抓的缺陷 |
/// |---|---|---|
/// | ① | 8 个 reason 的 wireName 逐字 | 拼错枚举名 ⇒ UI 拿到未知 reason（显示"原因未知"） |
/// | ② | `tryParse` 双向 | 从 checkpoint/事件恢复时把原因读错或抛异常 |
/// | ③ | 事件字段齐全 + 默认值 | 前端适配层读不到字段 ⇒ 中断卡没有轮次/token/继续按钮 |
/// | ④ | `ContinuePolicy` 默认 off + auto 默认 3 轮 | 默认行为被悄悄改（旧行为必须不变） |
/// | ⑤ | token 上限常量 = 200 万 | 产品拍板的数值漂移 |
library;

import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

void main() {
  group('RunStopReason（8 值 wire 契约）', () {
    test('① 每个 reason 的 wireName 逐字正确（UI/事件都靠它分支）', () {
      const expected = <RunStopReason, String>{
        RunStopReason.maxRounds: 'max_rounds',
        RunStopReason.tokenBudget: 'token_budget',
        RunStopReason.noProgress: 'no_progress',
        RunStopReason.providerTimeout: 'provider_timeout',
        RunStopReason.network: 'network',
        RunStopReason.processKilled: 'process_killed',
        RunStopReason.contextCompressFailed: 'context_compress_failed',
        RunStopReason.userCancel: 'user_cancel',
      };
      expect(RunStopReason.values.length, 8, reason: '枚举值只增不删');
      for (final e in expected.entries) {
        expect(e.key.wireName, e.value,
            reason: '★ wireName 是前端/落盘的唯一标识，拼错就等于原因未知');
      }
    });

    test('② tryParse 双向；未知值返回 null（不猜）', () {
      for (final r in RunStopReason.values) {
        expect(RunStopReason.tryParse(r.wireName), r);
      }
      expect(RunStopReason.tryParse('unknown_reason'), isNull);
      expect(RunStopReason.tryParse(null), isNull);
      expect(RunStopReason.tryParse(''), isNull);
    });
  });

  group('HeraclesRunStopped 事件字段', () {
    test('③ 字段齐全、默认值正确（前端 RunStopInfo 依赖这些）', () {
      const e = HeraclesRunStopped(
        reason: RunStopReason.maxRounds,
        round: 3,
        maxRounds: 3,
        tokensSpent: 123456,
        tokensLimit: 2000000,
        canContinue: true,
      );
      expect(e.reason, RunStopReason.maxRounds);
      expect(e.round, 3);
      expect(e.maxRounds, 3);
      expect(e.tokensSpent, 123456);
      expect(e.tokensLimit, 2000000);
      expect(e.canContinue, isTrue);
      // 未上报/未知的字段保持 null/空 —— 不编数
      expect(e.nextEstimate, isNull, reason: '没有估算依据就不许编数');
      expect(e.changedFiles, isEmpty);
      expect(e.errorSummary, isNull);
      expect(e.resumedFromRound, isNull);
    });

    test('③b no_progress 停时带人话摘要与改动文件', () {
      const e = HeraclesRunStopped(
        reason: RunStopReason.noProgress,
        round: 2,
        maxRounds: 3,
        tokensSpent: 1000,
        tokensLimit: 2000000,
        canContinue: true,
        changedFiles: ['lib/a.dart', 'test/b_test.dart'],
        errorSummary: '连续 2 轮没有进展（文件与错误都没变）',
        resumedFromRound: 1,
      );
      expect(e.errorSummary, contains('没有进展'));
      expect(e.changedFiles, hasLength(2));
      expect(e.resumedFromRound, 1);
    });
  });

  group('ContinuePolicy 默认值', () {
    test('④ 默认 off；auto 默认 3 轮；token 上限 200 万', () {
      const o = RunOptions();
      expect(o.continuePolicy, ContinuePolicy.off,
          reason: '★ 库默认必须与旧行为一致（跑一轮就停），不能悄悄开续跑');
      expect(o.maxRounds, ContractRunContinue.autoMaxRounds);
      expect(o.tokenLimit, ContractRunContinue.runTokenLimit);
      expect(ContractRunContinue.autoMaxRounds, 3);
      expect(ContractRunContinue.runTokenLimit, 2000000);
      expect(ContractRunContinue.noProgressRounds, 2);
      expect(ContractRunContinue.checkpointRole, 'run_checkpoint');
      // 恢复默认空 Map ⇒ 不恢复（旧行为）
      expect(o.resumeFromCheckpoint, isEmpty);
    });

    test('④b 三档语义可区分（不是布尔开关）', () {
      expect(ContinuePolicy.values, hasLength(3));
      expect(ContinuePolicy.off.name, 'off');
      expect(ContinuePolicy.ask.name, 'ask');
      expect(ContinuePolicy.auto.name, 'auto');
    });
  });
}
