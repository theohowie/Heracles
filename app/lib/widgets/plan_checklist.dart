import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// **任务计划清单**（2026-10-14，harness 核心机制的 UI）。
///
/// ## 用户要的是什么（原话）
///
/// > 「工作步骤就是把自己这一套工程展示出来，思考了什么，
/// >   调用了什么工具，完成了什么，**现在在干什么**」
/// > 「顶部显示任务计划（如「1.查看结构 ✓ 2.写HTML ←进行中
/// >   3.验证」），下面是每一步的思考/工具调用」
///
/// ## 为什么它不是"又一个卡片"
///
/// 这是 harness 里**唯一回答"现在在干什么"**的地方：
/// - 工作步骤流回答"刚做了什么"（时间线，向后看）
/// - 计划清单回答"还要做什么、现在在哪一步"（进度，向前看）
///
/// 缺少它时用户只能靠翻时间线猜进度 —— 那正是"这个 agent 还有
/// 很大缺陷"的体感来源之一。
///
/// ## 状态语义（三态，与 TaskPlan.Status 一一对应）
///
/// | 图标 | 状态 | 含义 |
/// |---|---|---|
/// | `✓` | done | 这一 WHOLE 步已由**真实工具执行**推进（非模型自报）|
/// | `◐` 高亮 | active | 现在正在做这一步 |
/// | `○` 淡色 | pending | 还没开始 |
class PlanChecklist extends StatelessWidget {
  const PlanChecklist({
    super.key,
    required this.steps,
    required this.doneCount,
    required this.activeIndex,
    this.collapsed = false,
    this.onToggle,
    this.reachedGoal,
    this.closedReason,
  });

  /// 每一步的文本（按顺序）
  final List<String> steps;

  /// 已完成步数（前 N 个）
  final int doneCount;

  /// 当前进行中的步（0 起）；-1 = 全部完成
  final int activeIndex;

  /// 收起状态（用户点击标题行切换）
  final bool collapsed;
  final VoidCallback? onToggle;

  /// **计划是否真正达成目标**（2026-10-15，BUG-1）。
  ///
  /// · `true`  → 任务完成（正常绿勾）
  /// · `false` → **中断**（循环硬停 / 熔断 / 轮次耗尽）——
  ///   标题与图标用警示色，**不画成成功**
  /// · `null`  → 还没收尾（进行中）或老版本 Kotlin
  final bool? reachedGoal;

  /// 中断原因（`reachedGoal == false` 时显示）
  final String? closedReason;

  @override
  Widget build(BuildContext context) {
    final h = Hue.of(context);
    final total = steps.length;
    final allDone = doneCount >= total;

    return Container(
      margin: const EdgeInsets.only(bottom: HSpace.md),
      decoration: BoxDecoration(
        color: h.surfaceAlt,
        borderRadius: BorderRadius.circular(HRadius.md),
        border: Border.all(color: h.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- 标题行：进度 + 折叠 ----
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: HSpace.md, vertical: HSpace.sm + 2),
              child: Row(
                children: [
                  Icon(
                    // ★ 三态图标（2026-10-15，BUG-1）：
                    //   · 中断（reachedGoal == false）→ ⚠️ 警示
                    //   · 全部完成 → ✅
                    //   · 进行中 → 清单图标
                    reachedGoal == false
                        ? Icons.error_outline_rounded
                        : (allDone
                            ? Icons.check_circle_rounded
                            : Icons.checklist_rounded),
                    size: 15,
                    color: reachedGoal == false
                        ? HColors.warnOn(h.dark)
                        : (allDone ? HColors.successOn(h.dark) : h.accent),
                  ),
                  const SizedBox(width: HSpace.sm),
                  Text(
                    '任务计划',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: h.text,
                    ),
                  ),
                  const SizedBox(width: HSpace.sm),
                  Text(
                    // 中断时显示"已中断"而不是进度数字 ——
                    // 用户一眼能分辨"做完了"和"被停了"
                    reachedGoal == false ? '已中断' : '$doneCount/$total',
                    style: TextStyle(
                      fontSize: 11,
                      color: reachedGoal == false
                          ? HColors.warnOn(h.dark)
                          : h.textFaint,
                    ),
                  ),
                  const Spacer(),
                  // 进度条（一眼看出大概还剩多少）—— 比纯数字更快
                  SizedBox(
                    width: 56,
                    height: 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: total == 0 ? 0 : doneCount / total,
                        backgroundColor: h.border,
                        valueColor: AlwaysStoppedAnimation(
                          allDone ? HColors.successOn(h.dark) : h.accent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: HSpace.sm),
                  Icon(
                    collapsed
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_up_rounded,
                    size: 16,
                    color: h.textFaint,
                  ),
                ],
              ),
            ),
          ),
          // ---- 步骤清单 ----
          if (!collapsed)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  HSpace.md, 0, HSpace.md, HSpace.sm + 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < steps.length; i++)
                    _step(h, i, steps[i]),
                  // ★ 中断原因（2026-10-15，BUG-1）——
                  //   让用户知道"为什么停了"，而不是只有一句"已中断"
                  if (reachedGoal == false &&
                      closedReason != null &&
                      closedReason!.isNotEmpty) ...[
                    const SizedBox(height: HSpace.xs),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 12, color: HColors.warnOn(h.dark)),
                        const SizedBox(width: HSpace.xs),
                        Expanded(
                          child: Text(
                            closedReason!,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.4,
                              color: HColors.warnOn(h.dark),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _step(Hue h, int i, String text) {
    final done = i < doneCount;
    // activeIndex 由 Kotlin 侧给出（-1 = 全完成）；
    // 但 done 的步骤不该再显示为 active，这里做一次防御
    final active = !done && i == activeIndex;

    final color = done
        ? HColors.successOn(h.dark)
        : (active ? h.accent : h.textFaint);
    final style = TextStyle(
      fontSize: 12.5,
      height: 1.45,
      color: done
          ? h.textDim
          : (active ? h.text : h.textFaint),
      // 已完成的加删除线？不加 —— 那会让"做过的事"看起来像被否决。
      // 用**勾 + 淡色**已经足够区分。
      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: HSpace.xs + 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 三态图标
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              done
                  ? Icons.check_rounded
                  : (active
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded),
              size: 13,
              color: color,
            ),
          ),
          const SizedBox(width: HSpace.sm),
          Expanded(child: Text(text, style: style)),
          if (active)
            Text(
              '进行中',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: h.accent,
                letterSpacing: 0.3,
              ),
            ),
        ],
      ),
    );
  }
}
