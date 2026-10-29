import 'package:heracles_backend/src/contract/contract.dart';
import 'package:test/test.dart';

/// **契约常量回归** —— 把每个数字钉死，防止它们再散回字面量。
///
/// ## 为什么这些断言是"复读机"却必须有
///
/// 这个文件看起来只是把 `contract.dart` 里的数字抄一遍 —— 那正是它的用处：
/// 它**不测逻辑，测"没有第二份真相"**。将来任何人（或任何重构）
/// 把 `ContractAgent.maxTurns` 从 40 改成 45，或者把它删掉换成一个内联的
/// `40` 字面量，这里立刻红。
///
/// ## 为什么 import `src/` 而不是 `package:heracles_backend/heracles_backend.dart`
///
/// 契约常量**故意不从公共 API 导出**：它只在后端内部用，宿主要什么数字
/// 应该读自己的配置，而不是 import 一堆常量。测试直接按路径取，
/// 顺带钉住"它在 `src/contract/contract.dart` 这个位置"。
///
/// ## 数值来源
///
/// 每个数字的依据写在 `contract.dart` 的 KDoc 里（旧实现踩过的坑 / 实测数据）。
/// **改这些数字 = 改产品契约**，必须先有新的实测数据。
void main() {
  group('ContractAgent — 编排预算（ADR-033）', () {
    test('★★★ maxTurns = 40（20 轮不够、60 轮以上必然打转）', () {
      expect(ContractAgent.maxTurns, 40);
    });

    test('★★★ maxToolCalls = 200（真实逆向任务 120 上下 + 60% 余量）', () {
      expect(ContractAgent.maxToolCalls, 200);
    });
  });

  group('ContractModel — 模型请求', () {
    test('★★★ defaultWindowTokens = 128000', () {
      expect(ContractModel.defaultWindowTokens, 128000);
    });

    test('★★★ maxOutputTokens = 16384（4096 会截断长补丁）', () {
      expect(ContractModel.maxOutputTokens, 16384);
    });

    test('★★★ defaultBaseUrl = https://api.openai.com', () {
      expect(ContractModel.defaultBaseUrl, 'https://api.openai.com');
    });
  });

  group('ContractCompression — 上下文压缩', () {
    test('★★★ compressAtRatio = 0.80（用户要求 80%）', () {
      // 注意是 double 而不是 int：0.5 太频繁、0.95 会先撞窗口
      expect(ContractCompression.compressAtRatio, 0.80);
      expect(ContractCompression.compressAtRatio, isA<double>());
    });

    test('★★★ keepRecentTurns = 6（按"轮"不按"条"）', () {
      expect(ContractCompression.keepRecentTurns, 6);
    });

    test('★★★ messagesPerTurn = 4', () {
      expect(ContractCompression.messagesPerTurn, 4);
    });
  });

  group('ContractTools — 工具默认值', () {
    test('★★★ maxEntries = 200', () {
      expect(ContractTools.maxEntries, 200);
    });

    test('★★★ shellTimeoutSeconds = 300（5 分钟）', () {
      expect(ContractTools.shellTimeoutSeconds, 300);
    });

    test('★★★ webMaxChars = 50000', () {
      expect(ContractTools.webMaxChars, 50000);
    });
  });

  group('ContractWorkspace — 文件能力', () {
    test('★★★ lineNumberWidth = 5', () {
      expect(ContractWorkspace.lineNumberWidth, 5);
    });

    test('★★★ diffContextLines = 3（diff -u 默认）', () {
      expect(ContractWorkspace.diffContextLines, 3);
    });

    test('★★★ maxReadFileBytes = 5 MB', () {
      expect(ContractWorkspace.maxReadFileBytes, 5 * 1024 * 1024);
      expect(ContractWorkspace.maxReadFileBytes, 5242880);
    });

    test('★★★ grepPerFileBytes = 1 MB', () {
      expect(ContractWorkspace.grepPerFileBytes, 1024 * 1024);
      expect(ContractWorkspace.grepPerFileBytes, 1048576);
    });

    test('★★★ maxVisitedFiles = 20000', () {
      expect(ContractWorkspace.maxVisitedFiles, 20000);
    });

    test('★★★ binarySniffBytes = 8192', () {
      expect(ContractWorkspace.binarySniffBytes, 8192);
    });
  });

  group('ContractShell — 命令执行', () {
    test('★★★ maxOutputBytes = 1 MB', () {
      expect(ContractShell.maxOutputBytes, 1024 * 1024);
      expect(ContractShell.maxOutputBytes, 1048576);
    });

    test('★★★ defaultTimeoutSeconds = 300', () {
      expect(ContractShell.defaultTimeoutSeconds, 300);
    });

    test('★★★ killGraceMs = 300（毫秒，不是秒）', () {
      expect(ContractShell.killGraceMs, 300);
    });
  });

  group('ContractWeb — 网络抓取', () {
    test('★★★ maxChars = 50000', () {
      expect(ContractWeb.maxChars, 50000);
    });

    test('★★★ timeoutSeconds = 30', () {
      expect(ContractWeb.timeoutSeconds, 30);
    });

    test('★★★ maxResponseBytes = 5 MB', () {
      expect(ContractWeb.maxResponseBytes, 5 * 1024 * 1024);
      expect(ContractWeb.maxResponseBytes, 5242880);
    });
  });

  group('ContractMemory — 长期记忆（2026-10-29 三作用域重设计）', () {
    // ⚠️ **旧断言为什么不再成立**（有意破坏性变更）：
    //
    // 旧断言是 `ContractMemory.maxBytes == 256*1024` —— 那个数同时被当成
    // "写闸"与"每轮固定开销"，把「能存多少」和「每轮付多少 token」焊死
    // （设计稿 §二）。重设计把两族常量拆开并**删除 maxBytes**，所以旧断言
    // 在语义上已无对象：继续断言它只会挡住正确的结构。
    // 现在改断言**新常量值与它们之间的关系**（关系比字面值更能抓漂移）。

    test('★★★ 注入预算：global+workspace 共享 6000，session 独立 4000', () {
      expect(ContractMemory.globalWorkspaceInjectMaxChars, 6000);
      expect(ContractMemory.sessionInjectMaxChars, 4000);
      expect(ContractMemory.sessionInjectMaxChars,
          lessThan(ContractMemory.globalWorkspaceInjectMaxChars),
          reason: '会话段是易变段，预算必须小于稳定段合计 —— 否则会话记忆会把'
              '全局/工作区的稳定前缀挤掉');
    });

    test('★★★ 存储软预算：8 MB / 16 MB / 512 KB，合计远大于注入预算', () {
      expect(ContractMemory.storageGlobalSoftMaxBytes, 8 * 1024 * 1024);
      expect(ContractMemory.storageWorkspaceSoftMaxBytes, 16 * 1024 * 1024);
      expect(ContractMemory.storageSessionSoftMaxBytes, 512 * 1024);
      expect(
        ContractMemory.storageSoftMaxBytes,
        ContractMemory.storageGlobalSoftMaxBytes +
            ContractMemory.storageWorkspaceSoftMaxBytes +
            ContractMemory.storageSessionSoftMaxBytes,
        reason: '合计常量必须等于三个分 scope 常量之和（不许单独调）',
      );
      expect(ContractMemory.storageSoftMaxBytes,
          greaterThan(1000 * ContractMemory.globalWorkspaceInjectMaxChars),
          reason: '存储预算必须远大于注入预算 —— 两者不是同一个旋钮（不变量 I3）');
    });

    test('★★★ 单条/条数/候选/摘要常量的量级关系', () {
      expect(ContractMemory.entryMaxChars, 8000);
      expect(ContractMemory.entryMaxChars,
          greaterThan(ContractMemory.globalWorkspaceInjectMaxChars),
          reason: '单条上限（存储）允许比一轮注入预算大 —— 一条长记忆可以「存得下、'
              '本轮不一定注入」');
      expect(ContractMemory.injectMaxEntriesPerScope, 40);
      expect(ContractMemory.injectCandidateMaxBytes, 64 * 1024);
      expect(ContractMemory.retrievalMaxCandidates, 200);
      expect(ContractMemory.summaryMaxChars, 40);
      expect(ContractMemory.entriesSoftMax, 5000);
      expect(ContractMemory.sessionEntriesSoftMax, 300);
      expect(ContractMemory.sessionEntriesSoftMax,
          lessThan(ContractMemory.entriesSoftMax));
    });

    test('★★★ 窗口自适应比例 5%，且常量值可被 min 截住', () {
      expect(ContractMemory.windowRatioCap, 0.05);
      // 128K 窗口 × 5% = 6400 > 6000 ⇒ 常量生效（小窗口才收缩，见 memory_prompt_test）
      expect(ContractModel.defaultWindowTokens * ContractMemory.windowRatioCap,
          greaterThan(ContractMemory.globalWorkspaceInjectMaxChars),
          reason: '默认窗口下常量应当先生效，否则 6000 这个数白写');
    });
  });

  group('分组之间的一致性（同一约定不能有第二份数字）', () {
    test('★★ webMaxChars 与 maxChars 是同一个约定 ⇒ 数值必须相同', () {
      // 工具层默认值与能力层默认值描述同一件事。
      // 不同就说明有一处被单独改过 —— 那正是这个测试要抓的漂移。
      expect(ContractTools.webMaxChars, ContractWeb.maxChars);
    });

    test('★★ shellTimeoutSeconds 与 defaultTimeoutSeconds 必须相同', () {
      expect(ContractTools.shellTimeoutSeconds,
          ContractShell.defaultTimeoutSeconds);
    });

    test('★ 行号宽度至少能装下 5 位数（否则 100000 行以上的文件会错位）', () {
      expect(ContractWorkspace.lineNumberWidth, greaterThanOrEqualTo(5));
    });

    test('★ 压缩比例必须在 (0, 1) 开区间内', () {
      expect(ContractCompression.compressAtRatio, greaterThan(0));
      expect(ContractCompression.compressAtRatio, lessThan(1));
    });
  });
}
