// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **模拟长会话回归**（2026-11-06）：40+ 轮真实 agent 循环里，压缩**只发生一次**。
//
// ## 为什么必须有这条（而不是只测单元）
//
// 用户最在意的指标是**缓存命中率**，而命中率只被一件事毁掉：
// **同一份历史被反复改写**。旧实现就是这么坏的（micro 每轮在 40% 线上
// 换占位符 ⇒ 命中率 40%~48%）。
//
// 单测能证明"某一层的算术对"，但证明不了"**跑一整段长会话时压缩只来一次**"——
// 那需要框架真的每轮调一次 `compress(state)`，也就是这个用例。
//
// ## 本文件锁住的契约
//
// 1. 40 轮模拟：占用爬到 85% ⇒ **恰好一次**压缩事件；
// 2. 压完占用**显著下降**（不是象征性降几百 token）；
// 3. 压完之后到 run 结束**不再触发**（前缀保住，缓存才可能命中）；
// 4. run 正常收尾（压缩不许把任务搞失败）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:heracles_backend/heracles_backend.dart';
import 'package:test/test.dart';

/// 脚本化 client：前 [toolRounds] 轮请求工具把历史拉长，最后一轮给正文。
///
/// ## 为什么每轮都要带一段长正文
///
/// 压缩决策看的是 `state.history` 的**文本估算**（框架真值这一路我们会另外
/// 用 `usages` 覆盖；本用例故意不报 usage，让估算成为唯一信号 —— 这样
/// "40 轮慢慢涨到线"的过程才是可预期的）。
///
/// ## 为什么每轮参数都不同
///
/// 框架的 loop detector 判据是"`工具名:参数JSON` 字节完全相同 ×N"，
/// 参数不变会在第 6 轮直接判"检测到循环"把 run 打掉（踩过）。
class _LongSessionClient implements LLMClient {
  _LongSessionClient({required this.toolRounds, required this.fillerChars});

  final int toolRounds;
  final int fillerChars;
  int calls = 0;

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async =>
      _reply(modelConfig);

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async =>
      Stream<StreamingMessage>.fromIterable([
        StreamingMessage(modelMessage: _reply(modelConfig)),
      ]);

  ModelMessage _reply(ModelConfig modelConfig) {
    calls++;
    if (calls <= toolRounds) {
      return ModelMessage(
        model: modelConfig.model,
        stopReason: 'tool_calls',
        textOutput: '第 $calls 轮：继续推进任务。${'字' * fillerChars}',
        functionCalls: [
          FunctionCall(
            id: 'call-$calls',
            name: 'list_files',
            arguments: '{"path":"probe-$calls"}',
          ),
        ],
      );
    }
    return ModelMessage(
      model: modelConfig.model,
      stopReason: 'stop',
      textOutput: '任务已完成。',
    );
  }
}

void main() {
  test('★★★ 40 轮长会话：85% 触发一次压缩、占用显著下降、之后不再触发', () async {
    // ★ 用**生产窗口**（128K）而不是小窗口：33 个工具定义本身就占约 10.4K token
    //   （真机读数 10.6K，见 `.docs/实测-*`）。窗口只要小到 20K，
    //   光工具定义就吃掉一半预算 ⇒ "压完刚好贴着线" ⇒ 每轮都触发。
    //   那不是压缩的 bug，是**窗口配置**的 bug（128K 下工具定义只占 8%）。
    const window = 128000;
    final line = (window * ContractCompaction.autoCompactThreshold).floor();
    // 40 轮 ×（2800 字正文 + 工具结果）≈ 40 × 2850 ≈ 114K
    // ⇒ 约第 35 轮越过 108.8K 线；压完全 24 条原文 ≈ 34K + 工具定义 10.4K
    // ⇒ 余下 5 轮涨到 ≈ 59K，**不会再触发**。
    final client = _LongSessionClient(toolRounds: 40, fillerChars: 2800);
    final agent = HeraclesAgent(
      config: const BackendConfig(
        apiKey: 'k',
        modelName: 'm',
        modelWindowTokens: window,
      ),
      capabilities: const Capabilities(),
      client: client,
      options: const RunOptions(maxTurns: 80, maxToolCalls: 200),
    );

    final events = <HeraclesEvent>[];
    await for (final e in agent.run('跑一个很长的任务，慢慢推进')) {
      events.add(e);
    }

    final compressed = events.whereType<HeraclesContextCompressed>().toList();
    final failed = events.whereType<HeraclesFailed>().toList();

    // ④ run 正常收尾
    expect(failed, isEmpty,
        reason: '压缩不许把任务搞失败：${failed.map((e) => e.reason).join('；')}');
    expect(events.whereType<HeraclesFinished>(), hasLength(1));

    // ① 恰好一次
    expect(compressed, hasLength(1),
        reason: '★★ 重复触发 = 每轮改写历史前缀 = 缓存命中率崩。'
            '实际发生 ${compressed.length} 次（合计 ${client.calls} 轮模型调用）');

    final event = compressed.single;
    expect(event.beforeTokens, greaterThanOrEqualTo(line),
        reason: '触发时必须真的到线（不许提前压）');
    // ② 显著下降
    expect(event.afterTokens, lessThan((event.beforeTokens * 0.7).round()),
        reason: '★★ 压完必须显著变小，实际 '
            '${event.beforeTokens}→${event.afterTokens}');
    expect(event.afterTokens, lessThan(line), reason: '压完必须低于触发线');

    // ③ 压完之后到 run 结束都没再触发 ⇒ 最终占用仍在安全区
    final finalUsage = agent.state == null
        ? 0
        : WindowRatioCompressor.estimateMessagesUsage(agent.state!);
    expect(finalUsage, lessThan(line),
        reason: '★ run 结束时占用必须仍低于触发线（否则下一轮一开就又要压）');

    // 压缩走了本地记忆（零 API 成本）——这条也说明"省钱"落地了
    expect(agent.lastCompactionEvent?.usedApi, isFalse,
        reason: '长会话里 Session Memory 可用 ⇒ 不该花摘要调用');
    final snapshot = agent.state!.history.messages.whereType<UserMessage>().any(
          (m) => m.contents.whereType<TextPart>().any(
                (p) => p.text.trimLeft().startsWith('[上下文压缩快照]'),
              ),
        );
    expect(snapshot, isTrue, reason: '压缩必须留下可追溯的快照（不是静默丢历史）');
  });
}
