/// **阶段 3：API 结构化摘要（兜底）** —— 2026-11-06。
///
/// ## 什么时候才会走到这里（只在两种情况下）
///
/// 1. Session Memory **不可用**（宿主关掉 / 抽出来是空的 / 被标 `stale`）；
/// 2. 用户显式给了 `focus`（"这次压缩只保留 XX 相关的内容"）。
///
/// 其余情况一律走阶段 2（零 API）—— 省钱、省延迟，且结果确定。
///
/// ## 保留清单（八段，一段都不许省）
///
/// 任务目标 / 用户显式约束 / 已完成 / 关键决策 / 相关文件与路径 /
/// 错误与修复 / 未决问题 / 下一步。
///
/// 依据：Anthropic 的 compaction 实践（保留架构决策、未解决的 bug、实现细节，
/// 丢弃冗余工具输出）+ 真机教训（用户说过"文件写入 A，不要动 B"，
/// 自由摘要漏掉它 ⇒ 模型去改了 B，而用户不知道是压缩丢的）。
/// 所以这里**按固定标签块**要输出，而不是让模型写"要点"。
///
/// ## 失败语义（**绝不假装成功**）
///
/// · 网络/超时/异常 ⇒ `ok = false` + [ApiSummaryResult.failureReason]；
/// · 模型返回空 ⇒ 同上；
/// · **本类永不写历史** —— 改历史是流水线的事，失败时流水线不改任何东西
///   （原始记录一条不丢；要腾空间只能交给确定性兜底并如实说明）。
///
/// ## Key 与 URL 不进日志
///
/// [failureReason] 只用异常**类型名**（`DioException` / `TimeoutException`…）
/// 加一句人话，**不含 message/stack**：Dio 的 message 里带 URL，
/// 而 URL 里可能带 Key（AGENTS.md 的硬约束）。
library;

import 'package:dart_agent_core/dart_agent_core.dart';

import '../../contract/contract.dart';
import 'compaction_config.dart';
import 'message_scan.dart';
import 'token_estimation.dart';

/// 解析后的结构化摘要。
class ApiSummary {
  const ApiSummary({
    this.goal = '',
    this.constraints = const <String>[],
    this.done = const <String>[],
    this.decisions = const <String>[],
    this.files = const <String>[],
    this.errors = const <String>[],
    this.openIssues = const <String>[],
    this.nextStep = '',
    this.parsed = true,
  });

  final String goal;
  final List<String> constraints;
  final List<String> done;
  final List<String> decisions;
  final List<String> files;
  final List<String> errors;
  final List<String> openIssues;
  final String nextStep;

  /// 是否真的解析到了标签块（false = 模型给了自由文本，只能整段当目标）。
  ///
  /// 如实记录这个位：UI 与测试据此区分"结构化摘要"与"退化摘要"。
  final bool parsed;
}

/// 一次摘要调用的结果。
class ApiSummaryResult {
  const ApiSummaryResult({
    required this.ok,
    required this.usedApi,
    this.summary,
    this.raw = '',
    this.failureReason,
    this.apiTokens = 0,
    this.elapsedMs = 0,
  });

  /// 成功（拿到非空、可用的摘要）。
  final bool ok;

  /// 是否**发起了**模型调用（失败也是 true —— 钱已经花了，要如实记账）。
  final bool usedApi;

  /// 解析结果（失败为 null）。
  final ApiSummary? summary;

  /// 模型的原始输出（排障用；**不进历史**除非成功）。
  final String raw;

  /// 失败原因（人话，不含 URL/Key/堆栈）。
  final String? failureReason;

  /// 这次调用的 token 成本（provider 上报；没上报就是 0）。
  final int apiTokens;

  /// 耗时（毫秒）。
  final int elapsedMs;
}

/// 结构化摘要器。
class StructuredSummarizer {
  const StructuredSummarizer({
    required this.client,
    required this.modelConfig,
    this.config = const CompactionConfig(),
  });

  final LLMClient client;
  final ModelConfig modelConfig;
  final CompactionConfig config;

  /// **摘要提示词**（保留清单的落地）。
  ///
  /// ⚠️ 标签名是**英文定稿**（`goal` / `constraints` / `decisions` / `files` /
  /// `open_issues` / `plan` …）：模型对英文标签的服从度明显好于中文括号，
  /// 而且解析器只认这些标签 —— 改标签名必须同时改 [parse]。
  static const String promptTemplate = '''
你是上下文压缩器。把给出的对话历史压缩成结构化笔记，供同一个 agent 继续任务。

【必须保留（一个都不能少）】
1. <goal>：用户的任务目标（用用户自己的措辞概括）
2. <constraints>：用户显式提出的硬约束与偏好（例如"文件写入 A，不要动 B"、"不要改权限"、路径范围要求）
3. <done>：已经完成的步骤/改动（只写事实，不写计划）
4. <decisions>：已经做出的技术决策，以及**为什么**这么选
5. <files>：已创建/修改的文件路径，以及每个文件改了什么要点
6. <errors>：出现过的错误与对应的修复办法（保留关键报错原文一行）
7. <open_issues>：尚未解决的问题、失败的尝试及原因
8. <next_step>：当前 plan 的进度与下一步该做什么

【可以丢弃】
- 完整的工具原始输出（整份文件内容、长日志）—— 需要时可重新读取
- 重复内容、寒暄、与目标无关的旁枝

【输出格式】只输出下面八个标签块，不要任何额外解释：
<goal>…</goal>
<constraints>…</constraints>
<done>…</done>
<decisions>…</decisions>
<files>…</files>
<errors>…</errors>
<open_issues>…</open_issues>
<next_step>…</next_step>
''';

  /// 用一个**不带 focus** 的提示词生成摘要。
  Future<ApiSummaryResult> summarize({
    required List<LLMMessage> head,
    String? focus,
  }) async {
    final stopwatch = Stopwatch()..start();
    if (head.isEmpty) {
      return const ApiSummaryResult(
        ok: false,
        usedApi: false,
        failureReason: '没有可摘要的历史（head 为空）',
      );
    }

    final transcript = buildTranscript(head);
    if (transcript.trim().isEmpty) {
      return const ApiSummaryResult(
        ok: false,
        usedApi: false,
        failureReason: '历史里没有可摘要的文本（全是工具空输出/媒体）',
      );
    }

    final system = focus == null || focus.trim().isEmpty
        ? promptTemplate
        : '$promptTemplate\n'
            '【本次的重点（用户指定）】${clipText(focus.trim(), ContractCompaction.summaryFocusMaxChars)}\n'
            '在上述约束下，压缩时优先保留与这个重点相关的事实；但「必须保留」八段一个都不能少。';

    ModelMessage resp;
    try {
      resp = await client.generate(
        <LLMMessage>[
          SystemMessage(system),
          UserMessage.text(transcript),
        ],
        modelConfig: modelConfig,
      );
    } catch (e) {
      stopwatch.stop();
      return ApiSummaryResult(
        ok: false,
        usedApi: true,
        // 只留类型名：DioException 的 message 里带 URL（可能带 Key）
        failureReason: '摘要调用失败（${e.runtimeType}）',
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    }

    stopwatch.stop();
    final usage = resp.usage;
    final tokens = usage == null
        ? 0
        : (usage.promptTokens + usage.completionTokens) < 0
            ? 0
            : usage.promptTokens + usage.completionTokens;
    final text = (resp.textOutput ?? '').trim();
    if (text.isEmpty) {
      return ApiSummaryResult(
        ok: false,
        usedApi: true,
        failureReason: '摘要返回为空（模型没有给出任何内容）',
        apiTokens: tokens,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    }

    final parsed = parse(text);
    final usable = parsed.goal.isNotEmpty ||
        parsed.constraints.isNotEmpty ||
        parsed.done.isNotEmpty ||
        parsed.decisions.isNotEmpty ||
        parsed.files.isNotEmpty ||
        parsed.errors.isNotEmpty ||
        parsed.openIssues.isNotEmpty ||
        parsed.nextStep.isNotEmpty;
    if (!usable) {
      return ApiSummaryResult(
        ok: false,
        usedApi: true,
        raw: text,
        failureReason: '摘要内容无法解析（既没有标签块也没有正文）',
        apiTokens: tokens,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    }

    return ApiSummaryResult(
      ok: true,
      usedApi: true,
      summary: parsed,
      raw: text,
      apiTokens: tokens,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// **解析**模型输出里的八个标签块。
  ///
  /// 没有标签块但有正文 ⇒ 整段当 `goal`（`parsed=false`）——
  /// 这是"模型没按格式来"的降级路径：**留着信息**比整段丢掉好，
  /// 但 `parsed=false` 让调用方能如实告知"这次是退化摘要"。
  static ApiSummary parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const ApiSummary(goal: '', parsed: false);

    String block(String tag) {
      final start = trimmed.indexOf('<$tag>');
      if (start < 0) return '';
      final begin = start + tag.length + 2;
      final end = trimmed.indexOf('</$tag>', begin);
      if (end < 0) return '';
      return trimmed.substring(begin, end).trim();
    }

    List<String> lines(String tag) {
      final body = block(tag);
      if (body.isEmpty) return const <String>[];
      return <String>[
        for (final raw in body.split(RegExp(r'[\n\r]+')))
          if (_stripBullet(raw).isNotEmpty) _stripBullet(raw),
      ];
    }

    final goal = block('goal');
    final constraints = lines('constraints');
    final done = lines('done');
    final decisions = lines('decisions');
    final files = lines('files');
    final errors = lines('errors');
    final openIssues = lines('open_issues');
    final nextStep = block('next_step');

    final parsedAnything = goal.isNotEmpty ||
        constraints.isNotEmpty ||
        done.isNotEmpty ||
        decisions.isNotEmpty ||
        files.isNotEmpty ||
        errors.isNotEmpty ||
        openIssues.isNotEmpty ||
        nextStep.isNotEmpty;
    if (!parsedAnything) {
      return ApiSummary(
        goal: clipText(
          flattenText(trimmed),
          ContractCompaction.sessionMemoryGoalMaxChars,
        ),
        parsed: false,
      );
    }

    return ApiSummary(
      goal: flattenText(goal),
      constraints: constraints,
      done: done,
      decisions: decisions,
      files: files,
      errors: errors,
      openIssues: openIssues,
      nextStep: flattenText(nextStep),
      parsed: true,
    );
  }

  /// 把待摘要的历史拼成 transcript（**单条与总量都设上限**）。
  ///
  /// 上限是必须的：一次 `read_file` 的原文可能就是 200K 字符，
  /// 直接塞进摘要请求 = 摘要请求自己撞窗口（那就成"为了压缩而撞窗口"）。
  static String buildTranscript(List<LLMMessage> head) {
    final buf = StringBuffer();
    var used = 0;
    for (final m in head) {
      final line = switch (m) {
        UserMessage() => '[用户] ${partsText(m.contents)}',
        ModelMessage() =>
          '[助手] ${(m.textOutput ?? '').trim()}'
              '${m.functionCalls.isEmpty ? '' : '（调用：${m.functionCalls.map((c) => c.name).join(',')}）'}',
        FunctionExecutionResultMessage() =>
          '[工具结果] ${m.results.map((r) => '${r.name}${r.isError ? '(失败)' : ''}: ${partsText(r.content)}').join(' | ')}',
        SystemMessage() => '[系统] ${m.content}',
        _ => '',
      };
      if (line.trim().isEmpty) continue;
      final clipped = clipText(
        flattenText(line),
        ContractCompaction.summaryTranscriptMessageMaxChars,
      );
      if (used + clipped.length >
          ContractCompaction.summaryTranscriptTotalMaxChars) {
        buf.writeln('（更早的内容因长度上限被省略，需要请重新取证）');
        break;
      }
      buf.writeln(clipped);
      used += clipped.length;
    }
    return buf.toString();
  }

  static String _stripBullet(String raw) {
    var line = raw.trim();
    while (line.startsWith('- ') ||
        line.startsWith('* ') ||
        line.startsWith('• ')) {
      line = line.substring(2).trim();
    }
    line = line.replaceAll(RegExp(r'^\d+[.、)]\s*'), '').trim();
    return line;
  }
}
