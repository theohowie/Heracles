// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **V0.4 长任务续跑 UI**（2026-11-02，对应 #1）。
//
// ## 背景与"契约适配"策略
//
// 后端 V0.4 会发 `run_stopped`（只增事件），字段：
//   reason / round / maxRounds / tokensSpent / tokensLimit / nextEstimate / canContinue
//   （reason ∈ max_rounds|token_budget|no_progress|provider_timeout|network|
//     process_killed|context_compress_failed|user_cancel）
//
// **当前 `AgentEvent` 还没有这些字段/常量**（只有 type/ts/index/raw/tool/args）。
// 所以这里做一层 [RunStopInfo.fromEvent] 契约适配：
//   · 优先把 `e.raw` 当 JSON 解析（后端把 payload 塞 raw 时即可用）；
//   · 其次读 `e.args`（Map<String,String>）；
//   · 都没有/解析失败 ⇒ null 字段 —— **绝不编数**，UI 显示"原因未知"并禁用继续。
// 后端把 `AgentEvent.kRunStopped` + 强类型字段落地后，删掉适配、直接读字段即可。

import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme/cupertino_kit.dart';

import '../services/agent_bridge.dart' show AgentEvent;
import '../theme/app_theme.dart';

/// **把后端/网络的原始失败文本变成人话**（V0.4 T0，2026-11-02）。
///
/// 用户要求：**每次非用户主动中断都要看到本轮失败原因**。但后端/中转站
/// 的原始 400 JSON 又长又技术（`CONTEXT_WINDOW_EXCEEDED` / requestId），
/// 直接塞进会话流不可读。这里只做**分类翻译**；匹配不到就原样截断，
/// 绝不吞掉原因、也绝不编造。
String humanizeRunFailure(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '运行失败（后端未上报原因）';
  final lower = s.toLowerCase();

  if (lower.contains('context_window_exceeded') ||
      lower.contains('prompt is too long') ||
      lower.contains('context length') ||
      lower.contains('maximum context') ||
      s.contains('上下文') ||
      s.contains('超过模型')) {
    return '上下文超出模型窗口：本次输入 + 历史对话太长。'
        '请精简内容、删除大附件或新建任务；换账号不会解决。';
  }
  if (lower.contains('401') ||
      lower.contains('403') ||
      lower.contains('unauthorized') ||
      lower.contains('invalid api key') ||
      lower.contains('invalid_api_key')) {
    return '模型认证失败：API Key 无效或无权限。请到「设置 → 模型」检查 Key。';
  }
  if (lower.contains('429') || lower.contains('rate limit')) {
    return '模型服务限流：请求太频繁，请稍后重试。';
  }
  // ★ 2026-11-10：超时分支必须排在「网络」之前，而且**必须吃下 Dio 的原文**。
  //
  // 踩过的坑（用户真机上报过、`前端对接清单 §16` 记着）：
  // Dio 的 receiveTimeout 文案是
  //   `The request connection took longer than 0:05:00…`
  // 里面带着 `connection` 这个词，但**不是网络故障**。原来这个分支只匹配
  // `timeout|timed out|超时` ⇒ 上面那句一个都不命中 ⇒ 掉进下面的 `connection`
  // 分支 ⇒ 用户看到「网络连接失败：请检查网络后重试」，被引导去查一个没坏的网络。
  // 所以这里补 `took longer than` / `receive timeout` / `read timeout`。
  final isTimeout = lower.contains('timeout') ||
      lower.contains('timed out') ||
      lower.contains('took longer than') ||
      lower.contains('time limit') ||
      lower.contains('deadline exceeded') ||
      s.contains('超时') ||
      s.contains('响应太慢');
  if (isTimeout) {
    // ★ 文案里**不再出现「网络」**：用户的网络往往没坏，说「网络」只会把人
    //   引去查路由。超时能做的动作就是等一会儿重试或换更快/更小的模型。
    return '模型服务超时：服务端响应太慢，本轮已中断。可以稍后重试，或换个更快的模型。';
  }
  // ★ 只有在**排除超时之后**，`connection` 才允许作为网络故障的依据。
  if (lower.contains('network') ||
      lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('connection reset') ||
      lower.contains('connection closed') ||
      lower.contains('handshake') ||
      lower.contains('dns') ||
      s.contains('网络')) {
    return '网络连接失败：请检查网络后重试。';
  }
  // 未匹配：保留原文（截断），不隐藏真正原因。
  return s.length > 300 ? '${s.substring(0, 300)}…' : s;
}

/// 一次 `run_stopped` 的结构化信息（字段可空 = 后端未上报）。
class RunStopInfo {
  const RunStopInfo({
    required this.reason,
    this.round,
    this.maxRounds,
    this.tokensSpent,
    this.tokensLimit,
    this.nextEstimate,
    this.canContinue,
    this.changedFiles = const <String>[],
    this.errorSummary,
    this.resumedFromRound,
  });

  final String reason;
  final int? round;
  final int? maxRounds;
  final int? tokensSpent;
  final int? tokensLimit;
  final int? nextEstimate;
  final bool? canContinue;
  final List<String> changedFiles;
  final String? errorSummary;
  final int? resumedFromRound;

  /// 事件 → 结构化信息（字段缺失保持 null）。
  static RunStopInfo? fromEvent(AgentEvent e) {
    if (e.type != kRunStoppedEvent) return null;
    Map<String, dynamic>? data;
    final raw = e.raw;
    if (raw != null && raw.trimLeft().startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) data = decoded.cast<String, dynamic>();
      } catch (_) {
        // raw 不是 JSON —— 交给 args 兜底
      }
    }
    data ??= <String, dynamic>{
      if (e.args != null) ...e.args!,
    };
    String? str(String k) {
      final v = data![k];
      if (v is String && v.isNotEmpty) return v;
      return null;
    }

    int? i(String k) {
      final v = data![k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    final reason = str('reason');
    if (reason == null) {
      // 没有 reason 也**不丢弃事件**：显示"原因未知"，让用户知道任务停了
      return const RunStopInfo(reason: 'unknown');
    }
    final files = data['changedFiles'];
    return RunStopInfo(
      reason: reason,
      round: i('round'),
      maxRounds: i('maxRounds'),
      tokensSpent: i('tokensSpent'),
      tokensLimit: i('tokensLimit'),
      nextEstimate: i('nextEstimate'),
      canContinue: data['canContinue'] is bool
          ? data['canContinue'] as bool
          : (data['canContinue'] == 'true'
              ? true
              : data['canContinue'] == 'false'
                  ? false
                  : null),
      changedFiles: files is List
          ? files.map((x) => x.toString()).where((x) => x.isNotEmpty).toList()
          : const <String>[],
      errorSummary: str('errorSummary') ?? str('error'),
      resumedFromRound: i('resumedFromRound'),
    );
  }

  /// 事件类型（字符串匹配；后端常量落地后换 `AgentEvent.kRunStopped`）。
  static const String kRunStoppedEvent = 'run_stopped';

  bool get isNoProgress => reason == 'no_progress';
  bool get isTokenBudget => reason == 'token_budget';

  /// 人话原因（每种 reason 一句，别把 no_progress 说成网络失败）。
  String get reasonText {
    switch (reason) {
      case 'max_rounds':
        return '轮次用尽';
      case 'token_budget':
        return 'token 预算用尽';
      case 'no_progress':
        return '连续两轮没有文件/测试/错误变化';
      case 'provider_timeout':
        return '模型服务超时';
      case 'network':
        return '网络中断';
      case 'process_killed':
        return '进程被系统结束';
      case 'context_compress_failed':
        return '上下文压缩失败';
      case 'user_cancel':
        return '你取消了任务';
      default:
        return '原因未知（后端未上报）';
    }
  }

  /// 续跑按钮是否可用（后端说能续 + 我们确实有字段）。
  bool get continueEnabled => canContinue == true;

  String? get continueDisabledReason {
    if (canContinue == null) return '后端未上报能否续跑';
    if (canContinue != true) return '该中断不支持续跑';
    return null;
  }
}

/// 「任务被中断」卡（消息流上方 / 输入卡上方）。
///
/// 与"红条"的区别：写清**为什么停**、**还能不能续**、**token 用掉多少**。
class RunStopBanner extends StatelessWidget {
  const RunStopBanner({
    super.key,
    required this.info,
    required this.onContinue,
    required this.onDismiss,
  });

  final RunStopInfo info;
  final VoidCallback onContinue;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final tokens = (info.tokensSpent != null && info.tokensLimit != null)
        ? '已用 ${info.tokensSpent} / 上限 ${info.tokensLimit}'
        : (info.tokensSpent != null ? '已用 ${info.tokensSpent} tokens' : null);
    final rounds = (info.round != null && info.maxRounds != null)
        ? '第 ${info.round} / ${info.maxRounds} 轮'
        : (info.round != null ? '第 ${info.round} 轮' : null);
    final next = info.nextEstimate != null ? '预计下一轮约 ${info.nextEstimate} tokens' : null;
    final resumed =
        info.resumedFromRound != null && info.resumedFromRound! > 1
            ? '从第 ${info.resumedFromRound} 轮继续'
            : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(HSpace.md, HSpace.sm, HSpace.md, 0),
      child: Container(
        key: const Key('run-stop-banner'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: h.surfaceAlt,
          borderRadius: BorderRadius.circular(HRadius.md),
          border: Border.all(color: h.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(AppIcons.warning, size: 15, color: h.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '任务被中断：${info.reasonText}',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: h.text),
                  ),
                ),
                InkWell(
                  onTap: onDismiss,
                  customBorder: const CircleBorder(),
                  child: Icon(AppIcons.close, size: 16, color: h.textFaint),
                ),
              ],
            ),
            if (resumed != null) _line(h, resumed),
            if (rounds != null) _line(h, rounds),
            if (tokens != null) _line(h, tokens),
            if (next != null) _line(h, next),
            if (info.changedFiles.isNotEmpty)
              _line(h, '已改文件：${info.changedFiles.take(3).join('、')}'
                  '${info.changedFiles.length > 3 ? ' 等 ${info.changedFiles.length} 个' : ''}'),
            if (info.errorSummary != null && info.errorSummary!.isNotEmpty)
              _line(h, '错误摘要：${info.errorSummary}'),
            if (info.continueDisabledReason != null)
              _line(h, info.continueDisabledReason!),
            const SizedBox(height: 8),
            Row(
              children: [
                CupertinoButton(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  color: info.continueEnabled ? h.text : h.surface,
                  borderRadius: BorderRadius.circular(HRadius.sm),
                  onPressed: info.continueEnabled ? onContinue : null,
                  child: Text(
                    '继续',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: info.continueEnabled ? h.bg : h.textFaint,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(Hue h, String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          text,
          style: TextStyle(fontSize: 11.5, height: 1.45, color: h.textDim),
        ),
      );
}

/// 自动续跑第 3 轮后的确认弹层 —— **已停用**（2026-11-02 用户裁定：
/// 续跑固定自动 3 轮，不弹自动确认；到上限只显示中断卡，由用户点「继续」）。
///
/// 保留函数供旧测试/引用编译；生产路径不再调用。
@Deprecated('2026-11-02: 续跑固定自动 3 轮，不再弹自动确认')
Future<bool?> showAutoContinueConfirm(
  BuildContext context, {
  int? tokensSpent,
  int? tokensLimit,
  int? nextEstimate,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) {
      final h = Hue.of(ctx);
      final tokens = (tokensSpent != null && tokensLimit != null)
          ? '已用 $tokensSpent / 上限 $tokensLimit tokens'
          : null;
      return AlertDialog(
        backgroundColor: h.surface,
        title: Text('继续会额外消耗 token',
            style: TextStyle(fontSize: 16, color: h.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('自动续跑已满 3 轮，任务仍未完成。',
                style: TextStyle(fontSize: 13, color: h.textDim)),
            if (tokens != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tokens,
                    style: TextStyle(fontSize: 12, color: h.textFaint)),
              ),
            if (nextEstimate != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('预计下一轮约 $nextEstimate tokens',
                    style: TextStyle(fontSize: 12, color: h.textFaint)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('停止', style: TextStyle(color: h.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('继续一轮',
                style: TextStyle(
                    color: h.accent, fontWeight: FontWeight.w600)),
          ),
        ],
      );
    },
  );
}
