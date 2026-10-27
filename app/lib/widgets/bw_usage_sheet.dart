import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/session_usage.dart';
import '../theme/app_theme.dart';
import 'bw_approval.dart';

/// 用量半抽屉（2026-10-24 黑白改版，替代右侧抽屉）。
///
/// 左右滑动两页：
/// - 第 1 页「上下文」：环图 + 冻结/对话/剩余三项（真实数据；
///   系统/工具定义等六项细分等后端 N2 落地后再补，**不造假数据**）
/// - 第 2 页「缓存」：累计加权命中率 + 稳态命中率 + 输入/命中/未命中/输出
///
/// 上限未知时环图只画灰环、中心显示「—」；缓存未上报时显示「未上报」，不写 0%。
Future<void> showUsageSheet(
  BuildContext context,
  SessionUsage usage,
  ContextUsage contextUsage,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(),
    builder: (sheetCtx) => BwSheetShell(
      onDismissRequest: () => Navigator.of(sheetCtx).pop(),
      child: _UsageSheet(usage: usage, contextUsage: contextUsage),
    ),
  );
}

class _UsageSheet extends StatefulWidget {
  const _UsageSheet({required this.usage, required this.contextUsage});

  final SessionUsage usage;
  final ContextUsage contextUsage;

  @override
  State<_UsageSheet> createState() => _UsageSheetState();
}

class _UsageSheetState extends State<_UsageSheet> {
  final _page = PageController();
  int _index = 0;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.62,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: h.border,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Text(
                    _index == 0 ? '上下文占用' : '缓存命中',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  // 页点：当前页黑圆点，其余灰点
                  for (var i = 0; i < 2; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Container(
                        width: _index == i ? 7 : 5,
                        height: _index == i ? 7 : 5,
                        decoration: BoxDecoration(
                          color: _index == i ? h.text : h.textFaint,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, size: 20, color: h.textDim),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _page,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  _ContextPage(contextUsage: widget.contextUsage),
                  _CachePage(usage: widget.usage),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _index == 0 ? '左滑查看缓存命中' : '右滑返回上下文占用',
                style: TextStyle(fontSize: 12, color: h.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 第 1 页：上下文环图。
///
/// 数据优先吃后端 `context_updated` 的分项（N2，7 固定键）：
/// 有分项就按分项画多段环图；没有（老后端/还没跑过）退回
/// 冻结/对话两分的老口径，不画假数。
class _ContextPage extends StatelessWidget {
  const _ContextPage({required this.contextUsage});

  final ContextUsage contextUsage;

  static const _keyOrder = [
    'system',
    'toolDefs',
    'toolResults',
    'reasoning',
    'assistant',
    'user',
    'summary',
  ];
  static const _keyLabels = {
    'system': '系统提示',
    'toolDefs': '工具定义',
    'toolResults': '工具结果',
    'reasoning': '思考',
    'assistant': '助手回复',
    'user': '用户消息',
    'summary': '历史摘要',
  };

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final ratio = contextUsage.ratio;
    final over = contextUsage.overLimit;
    final limit = contextUsage.limit;
    final remaining = limit > 0
        ? (limit - contextUsage.used).clamp(0, limit)
        : 0;

    // 分项段：固定键按序取非零值，未知键合并为「其他」。
    final breakdown = contextUsage.breakdown;
    final segments = <({String label, double value, Color color})>[];
    if (breakdown != null && breakdown.values.any((v) => v > 0)) {
      final ramp = <Color>[
        h.text,
        h.textDim,
        h.textFaint,
        h.accent,
        Color.lerp(h.text, h.surface, 0.55)!,
        Color.lerp(h.text, h.surface, 0.75)!,
        h.border,
      ];
      var ci = 0;
      for (final key in _keyOrder) {
        final v = breakdown[key] ?? 0;
        if (v <= 0) continue;
        segments.add((
          label: _keyLabels[key] ?? key,
          value: v.toDouble(),
          color: ramp[ci++ % ramp.length],
        ));
      }
      var other = 0;
      for (final e in breakdown.entries) {
        if (!_keyOrder.contains(e.key) && e.value > 0) other += e.value;
      }
      if (other > 0) {
        segments.add((
          label: '其他',
          value: other.toDouble(),
          color: ramp[ci % ramp.length],
        ));
      }
    }
    final hasBreakdown = segments.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        children: [
          const SizedBox(height: 8),
          SizedBox(
            width: 168,
            height: 168,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(168, 168),
                  painter: _DonutPainter(
                    segments: hasBreakdown
                        ? [
                            for (final s in segments)
                              (value: s.value, color: s.color),
                          ]
                        : [
                            (
                              value: contextUsage.frozenTokens.toDouble(),
                              color: h.text,
                            ),
                            (
                              value: contextUsage.conversationTokens.toDouble(),
                              color: h.textDim,
                            ),
                          ],
                    total: limit > 0 ? limit.toDouble() : null,
                    trackColor: h.border,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ratio == null ? '—' : '${(ratio * 100).round()}%',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        color: over ? HColors.errorOn(h.dark) : h.text,
                      ),
                    ),
                    Text(
                      '已用',
                      style: TextStyle(fontSize: 12, color: h.textDim),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (hasBreakdown) ...[
            for (final s in segments)
              _kv(h, s.label, '~${formatTokensCompact(s.value.round())}',
                  swatch: s.color),
          ] else ...[
            _kv(h, '冻结内容', '~${formatTokensCompact(contextUsage.frozenTokens)}',
                swatch: h.text),
            _kv(h, '对话内容',
                '~${formatTokensCompact(contextUsage.conversationTokens)}',
                swatch: h.textDim),
          ],
          _kv(h, '剩余',
              limit > 0 ? '~${formatTokensCompact(remaining)}' : '未知',
              swatch: h.border),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '~${formatTokensCompact(contextUsage.used)}',
                style: HTxt.mono(13),
              ),
              Text(' / ', style: TextStyle(color: h.textDim)),
              Text(
                limit > 0 ? formatTokensCompact(limit) : '未知',
                style: HTxt.mono(13).copyWith(color: h.textDim),
              ),
            ],
          ),
          if (over)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '已超出上下文上限 —— 下一轮可能被截断',
                style: TextStyle(fontSize: 12, color: HColors.errorOn(h.dark)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 第 2 页：缓存命中（口径与旧侧栏一致：累计加权为主，稳态单独一行）。
class _CachePage extends StatelessWidget {
  const _CachePage({required this.usage});

  final SessionUsage usage;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final rate = usage.hitRate;
    final steady = usage.steadyHitRate;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                rate == null ? '未上报' : '${(rate * 100).round()}%',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: rate == null ? h.textFaint : h.text,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '缓存命中（累计·加权）',
                style: TextStyle(fontSize: 12, color: h.textFaint),
              ),
            ],
          ),
          if (rate == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '当前后端未上报缓存字段 —— 不是 0%',
                style: TextStyle(fontSize: 12, color: h.textFaint),
              ),
            ),
          const SizedBox(height: 16),
          _kv(h, '稳态命中率（轮次平均）',
              steady == null ? '—' : '${(steady * 100).round()}%'),
          _kv(h, '输入（含缓存）', formatTokensFull(usage.totalInputTokens)),
          _kv(h, '· 命中缓存', formatTokensFull(usage.cachedTokens)),
          _kv(h, '· 未命中', formatTokensFull(usage.uncachedInputTokens)),
          _kv(h, '输出', formatTokensFull(usage.outputTokens)),
          _kv(h, 'Token 用量',
              formatTokensFull(usage.totalInputTokens + usage.outputTokens)),
          if (usage.hasUnreported)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '共 ${usage.turns} 轮，其中 ${usage.unreportedTurns} 轮未上报缓存。'
                '命中率只统计已上报的 ${usage.reportedTurns} 轮 —— 未上报不等于 0。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: h.textDim,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Widget _kv(Hue h, String k, String v, {Color? swatch}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        if (swatch != null) ...[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: swatch, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
        ],
        Text(k, style: TextStyle(fontSize: 14, color: h.textDim)),
        const Spacer(),
        Text(
          v,
          style: HTxt.mono(13),
        ),
      ],
    ),
  );
}

/// 环图：冻结（实色）+ 对话（灰色）两段，剩余为空轨道。
///
/// total 为 null（上限未知）时只画灰环，不画假进度。
class _DonutPainter extends CustomPainter {
  const _DonutPainter({
    required this.segments,
    required this.total,
    required this.trackColor,
  });

  final List<({double value, Color color})> segments;
  final double? total;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14;
    canvas.drawCircle(center, radius, track);
    final t = total;
    if (t == null || t <= 0) return;
    const gap = 0.04; // 段与段之间的空隙（弧度）
    var start = -math.pi / 2;
    for (final seg in segments) {
      final sweep = (seg.value / t).clamp(0.0, 1.0) * 2 * math.pi;
      if (sweep <= gap) {
        start += sweep;
        continue;
      }
      canvas.drawArc(
        rect,
        start + gap / 2,
        sweep - gap,
        false,
        Paint()
          ..color = seg.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14
          ..strokeCap = StrokeCap.round,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.total != total ||
      old.segments.length != segments.length ||
      old.segments.toString() != segments.toString();
}
