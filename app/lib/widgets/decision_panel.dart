import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/jev.dart';
import '../services/jev_service.dart';
import '../services/settings_controller.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';
import '../theme/pressable.dart';
import 'bw_approval.dart';

/// **决策模式的正文区**（2026-10-27 用户定）—— 与工作模式共用
/// 一个主界面，点顶栏 H 图标切换进来。
///
/// 形态（照预览 v3）：最新决策 = 一张结果卡（推荐/不推荐指示灯 +
/// 置信度 + 概率条 + 理由），其下是决策历史；底部是与工作模式
/// 同一套托盘式输入单元（白卡 + 信息条），底行只有引擎胶囊与
/// 发送键。决策历史与工作会话各自独立、互不混排。
class DecisionPanel extends StatefulWidget {
  const DecisionPanel({
    super.key,
    required this.jev,
    required this.settings,
    required this.inputController,
    required this.onOpenConfig,
  });

  final JevController jev;
  final SettingsController settings;
  final TextEditingController inputController;
  final VoidCallback onOpenConfig;

  @override
  State<DecisionPanel> createState() => _DecisionPanelState();
}

class _DecisionPanelState extends State<DecisionPanel> {
  final _focus = FocusNode();

  /// 正在当大卡展示的决策 id；null = 最新一条。
  String? _displayId;
  String? _lastSeenLatestId;

  @override
  void initState() {
    super.initState();
    _lastSeenLatestId = widget.jev.latest?.id;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  JevDecision? get _displayed {
    final history = widget.jev.history;
    if (history.isEmpty) return null;
    if (_displayId == null) return history.first;
    for (final d in history) {
      if (d.id == _displayId) return d;
    }
    return history.first;
  }

  void _syncLatest() {
    final id = widget.jev.latest?.id;
    if (id != _lastSeenLatestId) {
      _lastSeenLatestId = id;
      // 新决策出来就展示它（用户刚问的就该在眼前）。
      _displayId = null;
    }
  }

  Future<void> _send() async {
    final text = widget.inputController.text.trim();
    if (text.isEmpty || widget.jev.busy) return;
    widget.inputController.clear();
    _focus.unfocus();
    await widget.jev.ask(text, widget.settings.value);
  }

  /// **切换引擎来源**（2026-10-28 用户定）：点输入卡左下胶囊开
  /// 单选抽屉，与工作模式切换模型同一套 `showBwRadioSheet`；
  /// 配置页不再放来源选择（用户原话：来源放切换抽屉里、配置页
  /// 不用展示）。
  Future<void> _switchSource() async {
    final jev = widget.jev;
    final picked = await showBwRadioSheet<JevSource>(
      context,
      title: '引擎来源',
      subtitle: '点选即生效；接口地址、密钥与本地模型在「设置 · 模型」里编辑',
      options: JevSource.values,
      current: jev.config.source,
      labelOf: (s) => s.label,
    );
    if (picked != null && picked != jev.config.source) {
      await jev.updateConfig(jev.config.copyWith(source: picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    return AnimatedBuilder(
      animation: widget.jev,
      builder: (context, _) {
        _syncLatest();
        final jev = widget.jev;
        final displayed = _displayed;
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  HSpace.lg,
                  HSpace.md,
                  HSpace.lg,
                  HSpace.lg,
                ),
                children: [
                  if (jev.lastError != null)
                    _ErrorCard(
                      h: h,
                      message: jev.lastError!,
                      onDismiss: jev.dismissError,
                      onOpenConfig: widget.onOpenConfig,
                    ),
                  if (jev.busy && displayed == null)
                    _ThinkingCard(h: h)
                  else if (displayed == null)
                    _emptyState(h)
                  else ...[
                    _DecisionCard(h: h, decision: displayed),
                    if (jev.busy)
                      Padding(
                        padding: const EdgeInsets.only(top: HSpace.md),
                        child: _ThinkingRow(h: h),
                      ),
                  ],
                  if (jev.history.length > 1 ||
                      (displayed != null &&
                          jev.history.any((d) => d.id != displayed.id))) ...[
                    const SizedBox(height: HSpace.xl),
                    Row(
                      children: [
                        Text(
                          '决策历史',
                          style: HTxt.sectionTitle.copyWith(color: h.textDim),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => unawaited(_confirmClear()),
                          behavior: HitTestBehavior.opaque,
                          child: Text(
                            '清空',
                            style: HTxt.caption.copyWith(color: h.textFaint),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: HSpace.sm),
                    for (final d in jev.history)
                      if (displayed == null || d.id != displayed.id)
                        Padding(
                          padding: const EdgeInsets.only(bottom: HSpace.sm),
                          child: _HistoryRow(
                            h: h,
                            decision: d,
                            onTap: () => setState(() => _displayId = d.id),
                          ),
                        ),
                  ],
                ],
              ),
            ),
            _inputUnit(h),
          ],
        );
      },
    );
  }

  Future<void> _confirmClear() async {
    final ok = await showBwConfirmSheet(
      context,
      title: '清空决策历史？',
      message: '所有问答记录都会删掉，不可恢复。',
      confirmLabel: '清空',
      cancelLabel: '取消',
    );
    if (ok) {
      setState(() => _displayId = null);
      await widget.jev.clearHistory();
    }
  }

  Widget _emptyState(Hue h) {
    const examples = ['今晚要不要熬夜把这个功能做完', '周末要不要去参加线下活动', '现在换新手机划算吗'];
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '有什么拿不准的？\n交给决策引擎判断',
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w800,
              height: 1.45,
              color: h.text,
            ),
          ),
          const SizedBox(height: HSpace.md),
          Text(
            '它只做判断：亮绿灯是推荐、红灯是不推荐，并给出置信度。',
            style: HTxt.secondary.copyWith(color: h.textFaint, height: 1.5),
          ),
          const SizedBox(height: HSpace.xl),
          for (final e in examples) ...[
            Pressable(
              child: GestureDetector(
                onTap: () {
                  widget.inputController.text = e;
                  _focus.requestFocus();
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 15,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: h.surface,
                    border: Border.all(color: h.border),
                    borderRadius: BorderRadius.circular(HRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.balance, size: 17, color: h.textDim),
                      const SizedBox(width: 8),
                      Text(e, style: HTxt.body.copyWith(color: h.text)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: HSpace.md),
          ],
        ],
      ),
    );
  }

  /// 底部输入单元 —— 与工作模式 InputBar 同一套两层托盘形态
  /// （等宽双层卡、托盘压灰、信息条坐在托盘下沿带上）。
  Widget _inputUnit(Hue h) {
    final jev = widget.jev;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HSpace.md,
          HSpace.sm + 2,
          HSpace.md,
          HSpace.md,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: h.dark
                      ? h.surface
                      : Color.alphaBlend(
                          Colors.black.withValues(alpha: 0.12),
                          h.surface,
                        ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: h.dark ? 0.30 : 0.05,
                      ),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(width: double.infinity, height: 0),
                Container(
                  decoration: BoxDecoration(
                    color: h.dark ? h.surfaceAlt : Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: h.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 110),
                        child: CupertinoTextField.borderless(
                          controller: widget.inputController,
                          focusNode: _focus,
                          maxLines: null,
                          minLines: 1,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => unawaited(_send()),
                          placeholder: '说一件你拿不准的事…',
                          placeholderStyle: TextStyle(
                            fontSize: 15,
                            // 深色下 textFaint 压在卡面上几乎看不见
                            // （2026-10-28 用户实报）→ 提一档到 textDim。
                            color: h.textDim,
                          ),
                          style: TextStyle(fontSize: 15, color: h.text),
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
                        child: Row(
                          children: [
                            // ★ 来源胶囊与工作模式模型胶囊同规格
                            // （2026-10-28 用户对图指出高度/样式不一致）：
                            // 高 38、横边距 12、字号 14、无边框，填充
                            // 深色提亮一档（2C2C2E）/ 浅色 surfaceAlt；
                            // 结构同 _ModelSelector 的 Material+InkWell
                            // （GestureDetector 在真机有过点不动的教训）。
                            // 点按开来源切换抽屉（同工作模式切模型）。
                            Pressable(
                              borderRadius: BorderRadius.circular(999),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => unawaited(_switchSource()),
                                  borderRadius:
                                      BorderRadius.circular(HRadius.pill),
                                  child: Container(
                                    height: 38,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: h.dark
                                          ? const Color(0xFF2C2C2E)
                                          : h.surfaceAlt,
                                      borderRadius: BorderRadius.circular(
                                        HRadius.pill,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          jev.config.source == JevSource.cloud
                                              ? Icons.cloud
                                              : Icons.memory,
                                          size: 16,
                                          color: h.text,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          jev.config.source.label,
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: h.text,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                            // 麦克风占位：与工作模式同规格（38 圆钮、
                            // 同填充），在发送键左侧；语音识别未接入，
                            // 点按给如实提示。
                            Pressable(
                              borderRadius: BorderRadius.circular(999),
                              child: SizedBox(
                                width: 38,
                                height: 38,
                                child: Material(
                                  color: h.dark
                                      ? const Color(0xFF2C2C2E)
                                      : h.surfaceAlt,
                                  shape: const CircleBorder(
                                    side: BorderSide(
                                      color: Colors.transparent,
                                    ),
                                  ),
                                  child: InkWell(
                                    onTap: () => showIosToast(
                                      context,
                                      '语音识别还没接入，这个按钮先占位',
                                      icon: AppIcons.mic,
                                    ),
                                    customBorder: const CircleBorder(),
                                    child: Icon(
                                      AppIcons.mic,
                                      size: 19,
                                      color: h.textDim,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            // ★ 发送键与工作模式 _SendButton 逐项同规格
                            // （2026-10-28 用户对图指出样式不一样）：
                            // 38 圆、h.text 实底 + 同色描边、AppIcons.send、
                            // 前景深色取反（0A0A0B）/ 浅色白。
                            Pressable(
                              borderRadius: BorderRadius.circular(999),
                              enabled: !jev.busy,
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: h.text,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: h.text),
                                ),
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: jev.busy
                                        ? null
                                        : () => unawaited(_send()),
                                    customBorder: const CircleBorder(),
                                    child: jev.busy
                                        ? Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: h.dark
                                                  ? const Color(0xFF0A0A0B)
                                                  : Colors.white,
                                            ),
                                          )
                                        : Icon(
                                            AppIcons.send,
                                            size: 19,
                                            color: h.dark
                                                ? const Color(0xFF0A0A0B)
                                                : Colors.white,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 44,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Text(
                          jev.config.source == JevSource.cloud
                              ? '经云端接口出决策'
                              : '本地模型在本机出决策 · 不联网',
                          style: HTxt.caption.copyWith(color: h.textDim),
                        ),
                        const Spacer(),
                        Text(
                          '历史保存在本机',
                          style: HTxt.caption.copyWith(color: h.textFaint),
                        ),
                      ],
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
}

/// 结果卡：指示灯 + 置信度 + 概率条 + 理由。
class _DecisionCard extends StatelessWidget {
  const _DecisionCard({required this.h, required this.decision});

  final Hue h;
  final JevDecision decision;

  static const _green = Color(0xFF22C55E);
  static const _red = Color(0xFFEF4444);

  @override
  Widget build(BuildContext context) {
    final yes = decision.recommended;
    final confPct = (decision.confidence * 100).round();
    final yesPct = (decision.yesProb * 100).round();
    return Container(
      decoration: BoxDecoration(
        color: h.surface,
        border: Border.all(color: h.border),
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            decision.question,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${decision.engineLabel} · ${_elapsedText(decision.elapsedMs)} · ${_timeText(decision.createdAt)}',
            style: HTxt.caption.copyWith(color: h.textFaint),
          ),
          const SizedBox(height: HSpace.lg),
          Row(
            children: [
              Expanded(child: _lamp(on: yes, isYes: true)),
              const SizedBox(width: HSpace.md),
              Expanded(child: _lamp(on: !yes, isYes: false)),
            ],
          ),
          const SizedBox(height: HSpace.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$confPct%',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '置信度（${yes ? '推荐' : '不推荐'}）',
                style: HTxt.caption.copyWith(color: h.textDim),
              ),
              if (decision.confidence < 0.55) ...[
                const SizedBox(width: 8),
                Text(
                  '把握不大，当个参考',
                  style: HTxt.caption.copyWith(color: h.textFaint),
                ),
              ],
            ],
          ),
          const SizedBox(height: HSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(HRadius.pill),
            child: Row(
              children: [
                Expanded(
                  flex: (decision.yesProb * 1000).round().clamp(1, 999),
                  child: Container(height: 8, color: _green),
                ),
                Expanded(
                  flex: ((1 - decision.yesProb) * 1000).round().clamp(1, 999),
                  child: Container(height: 8, color: _red),
                ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                '推荐 $yesPct%',
                style: HTxt.caption.copyWith(color: h.textFaint),
              ),
              const Spacer(),
              Text(
                '不推荐 ${100 - yesPct}%',
                style: HTxt.caption.copyWith(color: h.textFaint),
              ),
            ],
          ),
          if (decision.reason != null) ...[
            const SizedBox(height: HSpace.md),
            Divider(height: 1, color: h.border),
            const SizedBox(height: HSpace.md),
            Text(
              '理由',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: h.text,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              decision.reason!,
              style: TextStyle(fontSize: 13.5, height: 1.65, color: h.textDim),
            ),
            if (decision.reasonSource.caption.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                decision.reasonSource.caption,
                style: HTxt.caption.copyWith(color: h.textFaint),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _lamp({required bool on, required bool isYes}) {
    final color = isYes ? _green : _red;
    final dark = h.dark;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        color: on ? color.withValues(alpha: dark ? 0.16 : 0.07) : h.surface,
        border: Border.all(
          color: on ? color.withValues(alpha: dark ? 0.55 : 0.35) : h.border,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(HRadius.md),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on ? color : h.border,
              boxShadow: on
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.45),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 9),
          Text(
            isYes ? '推荐' : '不推荐',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: on ? color : h.textFaint,
            ),
          ),
        ],
      ),
    );
  }

  static String _elapsedText(int ms) {
    if (ms >= 1000) return '耗时 ${(ms / 1000).toStringAsFixed(1)} 秒';
    return '耗时 $ms 毫秒';
  }

  static String _timeText(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.h,
    required this.decision,
    required this.onTap,
  });

  final Hue h;
  final JevDecision decision;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final yes = decision.recommended;
    return Pressable(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: h.surface,
            border: Border.all(color: h.border),
            borderRadius: BorderRadius.circular(HRadius.lg),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: yes ? _DecisionCard._green : _DecisionCard._red,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      decision.question,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${yes ? '推荐' : '不推荐'} · 置信度 '
                      '${(decision.confidence * 100).round()}% · '
                      '${decision.engineLabel} · ${_whenText(decision.createdAt)}',
                      style: HTxt.caption.copyWith(color: h.textFaint),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _whenText(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(t.hour)}:${two(t.minute)}';
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '昨天 $hm';
    if (diff < 7) {
      const names = ['一', '二', '三', '四', '五', '六', '日'];
      return '周${names[t.weekday - 1]} $hm';
    }
    return '${t.month}月${t.day}日 $hm';
  }
}

class _ThinkingCard extends StatelessWidget {
  const _ThinkingCard({required this.h});
  final Hue h;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: h.surface,
        border: Border.all(color: h.border),
        borderRadius: BorderRadius.circular(HRadius.xl),
      ),
      padding: const EdgeInsets.symmetric(vertical: 34),
      child: _ThinkingRow(h: h),
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow({required this.h});
  final Hue h;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CupertinoActivityIndicator(radius: 9, color: h.textDim),
        const SizedBox(width: 9),
        Text('正在判断…', style: HTxt.secondary.copyWith(color: h.textDim)),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.h,
    required this.message,
    required this.onDismiss,
    required this.onOpenConfig,
  });

  final Hue h;
  final String message;
  final VoidCallback onDismiss;
  final VoidCallback onOpenConfig;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: HSpace.md),
      decoration: BoxDecoration(
        color: h.surface,
        border: Border.all(color: h.border),
        borderRadius: BorderRadius.circular(HRadius.lg),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13.5, height: 1.55, color: h.text),
            ),
          ),
          GestureDetector(
            onTap: onOpenConfig,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                '去配置',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: h.text,
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Icon(Icons.close, size: 16, color: h.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}
