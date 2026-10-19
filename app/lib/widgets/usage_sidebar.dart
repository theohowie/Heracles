import 'package:flutter/material.dart';

import '../models/session_usage.dart';
import '../theme/app_theme.dart';

/// **右侧边栏：会话用量与上下文**（2026-10-11，t13；需求见 `docs/24`）。
///
/// ## 手势：**打开只走按钮，不挂边缘滑动**
///
/// `docs/24` §4.3 与 `docs/21` §2.2 的共同教训：
/// **右侧边缘是系统返回区**，而且 Android 的返回手势左右边缘都有。
///
/// 左侧那次已经绕了两圈（把"区域太小"误判成"与系统冲突"，
/// 自写 GestureDetector 白费一场）。所以这里**不重蹈覆辙**：
///
/// - **打开**：标题栏的按钮 → 不会与任何系统手势竞争
/// - **关闭**：右滑 / 点遮罩 —— 这是抽屉的通用手势，且与系统返回**同向**
///
/// 实现上就是 `Scaffold.endDrawer` + `endDrawerEnableOpenDragGesture: false`：
/// 关掉"关闭态的边缘打开手势"，但保留"打开态的右滑关闭"
/// （Flutter `DrawerController` 把这两种手势分开挂 —— 见
/// `drawer.dart` 的 `_controller.isDismissed` 分支）。
///
/// ## 三组数据（`docs/24` §2.2–2.4 的一期子集）
///
/// | 组 | 一期是否完整 |
/// |---|---|
/// | Token 用量 | ✅ 完整（数据已就绪） |
/// | 上下文已用 | ⚠️ 只到"冻结区 + 对话"合计，无系统/工具细分（需改 `PrefixBuilder`） |
/// | 会话统计 | ⚠️ 有轮次/步数/耗时/速度；**无 TTFT、无工具用时**（需新埋点） |
///
/// 缺失的项**如实显示"需二期埋点"**，不拿别的数冒充 —— 那是假信息。
class UsageSidebar extends StatelessWidget {
  const UsageSidebar({
    super.key,
    required this.usage,
    required this.contextUsage,
    this.onClose,
  });

  /// 当前会话的累计用量
  final SessionUsage usage;

  /// 上下文占用
  ///
  /// ⚠️ 刻意**不叫** `context` —— 那会与每个 `build(BuildContext context)`
  /// 的参数同名，字段被参数遮蔽，读代码时极易误用（我自己第一版就写错了）。
  final ContextUsage contextUsage;

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final width = MediaQuery.of(context).size.width;
    // 与左侧抽屉一致的自适应宽度（窄屏 88%，宽屏 340）
    final drawerWidth = width < 400 ? width * 0.88 : 340.0;

    return Drawer(
      width: drawerWidth,
      backgroundColor: h.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(HRadius.lg),
          bottomLeft: Radius.circular(HRadius.lg),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, h),
            Divider(height: 1, color: h.border),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(HSpace.lg),
                children: [
                  _tokenSection(h),
                  const SizedBox(height: HSpace.xl),
                  _contextSection(h),
                  const SizedBox(height: HSpace.xl),
                  _sessionSection(h),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, Hue h) => Padding(
        padding: const EdgeInsets.fromLTRB(HSpace.lg, HSpace.md, HSpace.sm, HSpace.md),
        child: Row(
          children: [
            Icon(Icons.insights_rounded, size: 18, color: h.accent),
            const SizedBox(width: HSpace.sm),
            Text(
              '用量与上下文',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: h.text,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: '关闭',
              icon: Icon(Icons.close_rounded, size: 20, color: h.textDim),
              onPressed: onClose ?? () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );

  // ---------------------------------------------------------- Token 用量

  Widget _tokenSection(Hue h) {
    final rate = usage.hitRate;
    return _Section(
      h: h,
      title: 'Token 用量',
      children: [
        // 命中率是这一组的"主角"，放大显示
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              rate == null ? '不可用' : '${(rate * 100).round()}%',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                // ★ null 时用 textFaint 而不是绿/红 —— 它既不是好也不是坏，
                //   只是"没有这个数据"（契约 §3.4 的降级规则）
                color: rate == null ? h.textFaint : _rateColor(h, rate),
              ),
            ),
            const SizedBox(width: HSpace.sm),
            Text(
              '缓存命中',
              style: TextStyle(fontSize: 12, color: h.textFaint),
            ),
          ],
        ),
        if (rate == null)
          Padding(
            padding: const EdgeInsets.only(top: HSpace.xs),
            child: Text(
              '当前后端未上报缓存字段 —— 不是 0%',
              style: TextStyle(fontSize: 11, color: h.textFaint),
            ),
          ),
        const SizedBox(height: HSpace.md),
        _kv(h, 'Token 用量', formatTokensFull(usage.totalInputTokens + usage.outputTokens)),
        _kv(h, '未缓存输入', formatTokensFull(usage.reportedPromptTokens + usage.unreportedPromptTokens)),
        _kv(h, '缓存读取', formatTokensFull(usage.cachedTokens)),
        _kv(h, '输出', formatTokensFull(usage.outputTokens)),
        // ★ 分母标注（docs/24 §4.1 硬要求）——
        //   否则用户以为自己被少算了
        if (usage.hasUnreported)
          Padding(
            padding: const EdgeInsets.only(top: HSpace.md),
            child: Container(
              padding: const EdgeInsets.all(HSpace.sm + 2),
              decoration: BoxDecoration(
                color: HColors.warnOn(h.dark).withValues(alpha: h.dark ? 0.10 : 0.12),
                borderRadius: BorderRadius.circular(HRadius.sm),
                border: Border.all(
                    color: HColors.warnOn(h.dark).withValues(alpha: 0.35)),
              ),
              child: Text(
                '共 ${usage.turns} 轮，其中 ${usage.unreportedTurns} 轮未上报缓存。'
                '命中率**只统计已上报的 ${usage.reportedTurns} 轮** —— '
                '未上报不等于 0。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: HColors.warnOn(h.dark),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 命中率配色：与 `message_row.dart` 的胶囊阈值保持一致（80 / 50）
  Color _rateColor(Hue h, double r) {
    if (r >= 0.8) return HColors.successOn(h.dark);
    if (r >= 0.5) return HColors.warnOn(h.dark);
    return HColors.errorOn(h.dark);
  }

  // -------------------------------------------------------- 上下文已用

  Widget _contextSection(Hue h) {
    final ratio = contextUsage.ratio;
    final over = contextUsage.overLimit;

    return _Section(
      h: h,
      title: '上下文已用',
      children: [
        Row(
          children: [
            Text(
              ratio == null ? '未知' : '${(ratio * 100).round()}%',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                // 超限**必须**用 error 色明确示警 ——
                // 把进度条画满就算完，用户不知道已经越界了
                color: over
                    ? HColors.errorOn(h.dark)
                    : (ratio == null ? h.textFaint : h.text),
              ),
            ),
            const Spacer(),
            // ★ 估算值一律标 `~`（docs/24 §4.2）
            Text(
              '~${formatTokensCompact(contextUsage.used)}'
              ' / ${contextUsage.limit > 0 ? formatTokensCompact(contextUsage.limit) : '未知'}',
              style: TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 11.5,
                color: h.textDim,
              ),
            ),
          ],
        ),
        // ★ 上限来源（2026-10-14）—— 让用户知道这个数字从哪来。
        //
        // 为什么必须可见：上限算错会让压缩**过早触发**（丢上下文），
        // 用户看到"128K"却知道模型是 1M 时，需要能判断是
        // "服务端没上报"还是"内置表不认识这个模型"。
        if (contextUsage.limitSource.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            '上限来源：${contextUsage.limitSource}',
            style: TextStyle(fontSize: 10.5, color: h.textFaint),
          ),
        ],
        const SizedBox(height: HSpace.sm),
        if (ratio != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(HRadius.pill),
            child: LinearProgressIndicator(
              // clamp：超限时不能把进度条撑出容器
              value: ratio.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: h.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(
                over ? HColors.errorOn(h.dark) : h.accent,
              ),
            ),
          ),
        if (over)
          Padding(
            padding: const EdgeInsets.only(top: HSpace.xs),
            child: Text(
              '已超出上下文上限 —— 下一轮可能被截断',
              style: TextStyle(fontSize: 11, color: HColors.errorOn(h.dark)),
            ),
          ),
        const SizedBox(height: HSpace.md),
        _legend(h, h.accent, '系统提示与工具定义',
            contextUsage.frozenTokens),
        _legend(h, HColors.infoOn(h.dark), '对话消息',
            contextUsage.conversationTokens),
        const SizedBox(height: HSpace.sm),
        Text(
          '均为估算值，非真实 tokenizer',
          style: TextStyle(fontSize: 10.5, height: 1.4, color: h.textFaint),
        ),
      ],
    );
  }

  Widget _legend(Hue h, Color color, String label, int tokens) => Padding(
        padding: const EdgeInsets.only(bottom: HSpace.xs + 2),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: HSpace.sm),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: h.textDim),
              ),
            ),
            Text(
              '~${formatTokensCompact(tokens)}',
              style: TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 11.5,
                color: h.textFaint,
              ),
            ),
          ],
        ),
      );

  // ---------------------------------------------------------- 会话统计

  Widget _sessionSection(Hue h) {
    final tps = usage.outputTokensPerSecond;
    return _Section(
      h: h,
      title: '会话统计',
      children: [
        _kv(h, '运行次数', '${usage.runs}'),
        _kv(h, '轮次', '${usage.turns}'),
        _kv(h, '工具调用', '${usage.steps}'),
        _kv(h, '模型用时', _formatDuration(usage.wallMs)),
        _kv(
          h,
          '输出速度',
          tps == null || tps <= 0 ? '—' : '${tps.round()} tok/s',
        ),
      ],
    );
  }

  /// 毫秒 → `233分55秒` / `1小时2分` （参考图是"233分55秒"这种写法）
  String _formatDuration(int ms) {
    if (ms <= 0) return '—';
    final totalSec = ms ~/ 1000;
    final h0 = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    if (h0 > 0) return '$h0小时$m分';
    if (m > 0) return '$m分$s秒';
    return '$s秒';
  }

  Widget _kv(Hue h, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: HSpace.sm),
        child: Row(
          children: [
            Expanded(
              child: Text(
                k,
                style: TextStyle(fontSize: 12.5, color: h.textDim),
              ),
            ),
            Text(
              v,
              style: TextStyle(
                fontFamily: kMonoFontFamily,
                fontFamilyFallback: kMonoFallback,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: h.text,
              ),
            ),
          ],
        ),
      );
}

/// 一组（标题 + 内容）
class _Section extends StatelessWidget {
  const _Section({required this.h, required this.title, required this.children});

  final Hue h;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: h.textFaint,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: HSpace.sm + 2),
        ...children,
      ],
    );
  }
}

/// 标题栏的**紧凑指示器**（常驻，点击打开右侧边栏）。
///
/// `docs/24` §5 的取舍：手机宽度放不下参考图那种三簇并排状态条，
/// 所以常驻部分**只占一个图标大小的位置**，详细信息进边栏。
///
/// 显示哪个数？**上下文占比优先**（它决定"还能不能继续聊"），
/// 没有上限信息时退到命中率。
class UsageIndicator extends StatelessWidget {
  const UsageIndicator({
    super.key,
    required this.usage,
    required this.contextUsage,
    required this.onTap,
  });

  final SessionUsage usage;

  /// ⚠️ 同 [UsageSidebar]：不叫 `context`，避免被 `build` 的参数遮蔽
  final ContextUsage contextUsage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final ratio = contextUsage.ratio;
    final rate = usage.hitRate;

    // ★ **两个数都常驻**（2026-10-11 修正）
    //
    // 用户原话要的是两件东西：「命中缓存率…显示在一个固定位置」**和**
    // 「上下文窗口已用多少」。我第一版只显示一个（占比优先、命中率退居
    // 后备），结果**上限已知时命中率就看不见了** —— 而那是需求的第一句。
    //
    // 手机上放不下参考图那种三簇状态条（`docs/24` §5），但**两个数
    // 加两个小图标**放得下：图标负责区分，数字保持紧凑。
    final rateLabel = rate == null ? '—' : '${(rate * 100).round()}%';
    final rateColor = rate == null
        // 不可用既不好也不坏 → 用最淡的字色，不用绿/红
        ? h.textFaint
        : (rate >= 0.8 ? HColors.successOn(h.dark) : h.textDim);

    final String ctxLabel;
    final Color ctxColor;
    if (ratio == null) {
      ctxLabel = '—';
      ctxColor = h.textFaint;
    } else {
      final pct = (ratio * 100).round();
      ctxLabel = '$pct%';
      ctxColor = contextUsage.overLimit
          ? HColors.errorOn(h.dark)
          : (pct >= 80 ? HColors.warnOn(h.dark) : h.textDim);
    }

    return Tooltip(
      message: '用量与上下文\n缓存命中 $rateLabel · 上下文已用 $ctxLabel',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: HSpace.sm, vertical: HSpace.xs + 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 有没有未上报轮次 —— 有就加一个小标记（docs/24 §4.1 的 `*` 建议）
              if (usage.hasUnreported) ...[
                Text(
                  '*',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: HColors.warnOn(h.dark),
                  ),
                ),
                const SizedBox(width: 2),
              ],
              Icon(Icons.cached_rounded, size: 13, color: rateColor),
              const SizedBox(width: 3),
              Text(rateLabel, style: _num(h, rateColor)),
              const SizedBox(width: HSpace.sm),
              Icon(Icons.donut_large_rounded, size: 12, color: ctxColor),
              const SizedBox(width: 3),
              Text(ctxLabel, style: _num(h, ctxColor)),
            ],
          ),
        ),
      ),
    );
  }

  TextStyle _num(Hue h, Color color) => TextStyle(
        fontFamily: kMonoFontFamily,
        fontFamilyFallback: kMonoFallback,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: color,
      );
}
