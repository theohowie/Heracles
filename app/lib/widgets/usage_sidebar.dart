import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../models/session_usage.dart';
import '../theme/app_theme.dart';
import '../theme/cupertino_kit.dart';

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
            Icon(AppIcons.usage, size: 19, color: h.accent),
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
            Tooltip(
              message: '关闭',
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: onClose ?? () => Navigator.of(context).pop(),
                child: Icon(AppIcons.close, size: 21, color: h.textDim),
              ),
            ),
          ],
        ),
      );

  // ---------------------------------------------------------- Token 用量

  Widget _tokenSection(Hue h) {
    // ★★ 三个命中率数字口径不同，**必须各自标注**（2026-10-21，BUG-5）★★
    //
    // 用户原话：「会话标题右边的第一个圆圈显示缓存命中率 94%，
    // 但是下方的显示 96%」—— 那不是两个 bug，是**两个口径共用了同一个名字**：
    //
    // | 数 | 算法 | 位置 |
    // |---|---|---|
    // | [rate]（累计·加权） | `Σcached / Σ(cached+prompt)`，**全部轮次** | 标题圆圈 + 本组主标题 |
    // | [steady]（稳态·轮次平均） | `drop(1)` 各轮命中率的**平均** | 本组「稳态命中率」一行 |
    //
    // 主标题沿用**累计加权**（它对应真实账单：大轮权重大）。稳态那个数
    // 单独一行，因为它系统性偏乐观（2026-10-19 实测：轮次平均 90.8% vs 加权 84.6%）。
    final rate = usage.hitRate;
    final steady = usage.steadyHitRate;
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
              // ★ 口径写进标签本身。原先只写「缓存命中」，
              //   与消息下方那个**单轮**命中率同名 ⇒ 94% vs 96% 看起来像 bug。
              '缓存命中（累计·加权）',
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
        // ★★ 稳态命中率（2026-10-21，BUG-5）★★
        //
        // 这个数 Kotlin 侧一直在传（`AgentBridge.toMap` 的 `steadyHitRate`），
        // Dart 侧只解析不展示 —— 用户因此永远看不到"跳过冷启动后"的口径。
        // 注意它是**轮次平均**（`turns.drop(1)` 的平均），与上面主标题的
        // token 加权**不是同一个数**，所以必须单独一行、单独标注。
        const SizedBox(height: HSpace.sm),
        _kv(
          h,
          '稳态命中率（最近一次·轮次平均）',
          steady == null ? '—' : '${(steady * 100).round()}%',
        ),
        // ★ 2026-10-23：这三行过去**互相矛盾**（用户自己一算就发现了）：
        //
        //   「未缓存输入 16690 / 缓存读取 16128 ⇒ 命中率 49%，怎么显示 97%？」
        //
        // 他的算式没错，是标签错了：16,690 是**整段输入**（已含命中的 16,128），
        // 真正的未命中是 16,690 − 16,128 = **562**。
        // 根因是 `promptTokens` 的语义在 2026-10-23 改成"整段"后，
        // 这两行的旧定义没跟着改（还把 cached 多加了一遍 ⇒ Token 用量虚高一倍）。
        //
        // 现在保证**加法自洽**：整段输入 = 命中 + 未命中；总量 = 整段输入 + 输出。
        _kv(h, '输入（含缓存）', formatTokensFull(usage.totalInputTokens)),
        _kv(h, '· 命中缓存', formatTokensFull(usage.cachedTokens)),
        _kv(h, '· 未命中', formatTokensFull(usage.uncachedInputTokens)),
        _kv(h, '输出', formatTokensFull(usage.outputTokens)),
        _kv(h, 'Token 用量', formatTokensFull(usage.totalInputTokens + usage.outputTokens)),
        // ★ 2026-10-22：删掉「"输出" = provider 上报的 completion_tokens 累加…」
        //   这句公式说明（用户：不是写给用户看的）。口径留在上面的代码注释里。
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
        // ★ 2026-10-22：删掉界面上的「上限来源：xxx」一行（用户：不是写给
        //   用户看的）。**判断依据保留在代码里**：上限算错会让压缩过早触发
        //   （丢上下文）—— 排障时看 `contextUsage.limitSource` 字段即可。
        const SizedBox(height: HSpace.sm),
        if (ratio != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(HRadius.pill),
            child: SizedBox(
              height: 6,
              child: CupertinoLinearActivityIndicator(
                // clamp：超限时不能把进度条撑出容器
                progress: ratio.clamp(0.0, 1.0),
                height: 6,
                color: over ? HColors.errorOn(h.dark) : h.accent,
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
        // ★ C5（2026-10-24）：有构成数据时把"冻结区"拆成 系统 / 工具定义
        //   两行（记忆/宪法/快照都在 system 消息里，合成一块）——
        //   用户能看见"上下文被什么吃掉了"。没有数据（没跑过）退回两行旧图例。
        if (contextUsage.breakdown != null) ...[
          _legend(h, h.accent, '系统提示与记忆',
              contextUsage.breakdown!['system'] ?? 0),
          _legend(h, HColors.infoOn(h.dark), '工具定义',
              contextUsage.breakdown!['tools'] ?? 0),
          _legend(h, HColors.infoOn(h.dark), '对话历史',
              contextUsage.breakdown!['history'] ?? 0),
        ] else ...[
          _legend(h, h.accent, '系统提示与工具定义',
              contextUsage.frozenTokens),
          _legend(h, HColors.infoOn(h.dark), '对话消息',
              contextUsage.conversationTokens),
        ],
        // ★ 2026-10-22：删掉「均为估算值，非真实 tokenizer」这句小字
        //   （用户：不是写给用户看的）。
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
        // ★★ 两个耗时并列，且**名字里写清口径**（2026-10-21，BUG-5）★★
        //
        // 用户原话：「耗时才 5172ms，改成秒为单位，这个是从开始执行任务到结束
        // 任务的耗时，你觉得会这么短？」—— 他说得对。5172ms 是**模型往返**的
        // 累加（`TurnRecord.wallMs`），而工具执行、审批等待、压缩**都不在里面**。
        //
        // 所以：
        //   · 上面一行 = 模型用时（旧的那个 5172ms），标签补上「不含工具」
        //   · 下面一行 = **任务总耗时**（Kotlin `AgentBridge.lastTaskWallMs`，
        //     从 run 开始到 run 结束的真实墙钟）
        // 恒有 任务总耗时 >= 模型用时。
        _kv(h, '模型用时（不含工具）', _formatDuration(usage.wallMs)),
        _kv(h, '任务总耗时', _formatDuration(usage.taskWallMs)),
        // ★ 2026-10-22：删掉「任务总耗时 = …真实墙钟…」这句公式说明
        //   （用户：不是写给用户看的）。口径已经写在**标签本身**
        //   （"模型用时（不含工具）"），不需要再配一段小字。
        _kv(
          h,
          '输出速度',
          tps == null || tps <= 0 ? '—' : '${tps.round()} tok/s',
        ),
      ],
    );
  }

  /// 毫秒 → 秒级人话：`5秒` / `1分2秒` / `1小时2分`
  ///
  /// ## 为什么不用「5172 ms」（2026-10-21，BUG-5 用户要求）
  ///
  /// 用户原话：「耗时才 5172ms，改成秒为单位」。毫秒对**任务级**耗时没有意义
  /// （精度远超人能感知的范围），而且会让人误以为那是"精确测量"。
  /// 低于 1 秒显示 `不到 1 秒`（不显示 `0秒` —— 那会让人以为没花时间）。
  String _formatDuration(int ms) {
    if (ms <= 0) return '—';
    if (ms < 1000) return '不到 1 秒';
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
      // ★ 口径写进 tooltip（2026-10-21，BUG-5）：这个圆圈是**累计·token 加权**
      //   命中率，与消息下方那个**单轮**命中率不是同一个数
      //   （用户曾看到 94% vs 96% 以为是 bug —— 其实是两个口径）。
      message: '用量与上下文\n缓存命中（累计·加权） $rateLabel · 上下文已用 $ctxLabel',
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
              Icon(CupertinoIcons.arrow_2_circlepath,
                  size: 14, color: rateColor),
              const SizedBox(width: 3),
              Text(rateLabel, style: _num(h, rateColor)),
              const SizedBox(width: HSpace.sm),
              Icon(CupertinoIcons.chart_pie, size: 13, color: ctxColor),
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
