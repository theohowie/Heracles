// Copyright (C) 2026 The Heracles Authors
// SPDX-License-Identifier: GPL-3.0
//
// **技能启停的运行时闸门**（V0.4 F1 收口，2026-11-02）。
//
// ## 这个文件补的是本轮的**真空洞**
//
// F1 之前：`SkillsService` 能列出技能、能改"已启用"开关 —— 但那个开关**只管 UI**。
// 真正注入系统提示的路径在 `LocalAgentExecutor._scanUserSkills()`，它自己扫一遍
// `SKILL.md` 就交给 backend，**从不看启停表**。
// 结果：用户在页面里把某个技能关掉，模型照样在用它 —— 一个看着生效、实际无效的开关。
//
// ## 为什么做成独立的纯函数
//
// 闸门的核心判断只有一句："这个技能的名字在不在启用集合里"。把它泡在
// `local_agent` 的异步扫描里就没法单测（要拉起整套能力/通道）。抽成纯函数后
// 能直接钉死三种边界 —— 尤其是**"读不到启停表"时必须放行**这条，
// 它是"旧宿主 / 通道缺失"不退化的唯一保证。
library;

import 'package:heracles_backend/heracles_backend.dart';

/// 按启用集合过滤技能。
///
/// - [enabledNames] 为 `null` ⇒ **不筛**（读不到启停表：旧宿主、通道缺失、读失败）。
///   宁可多注入一个技能，也不许因为读不到偏好就让用户"技能全没了"。
/// - 非 null 但为空集合 ⇒ **全部过滤**（用户确实把每一个都关了，这是真实意图）。
/// - 内置技能与用户技能**共用同一个集合**（宿主的表就是 `name → bool`）。
List<SkillEntry> filterEnabledSkills(
  List<SkillEntry> all,
  Set<String>? enabledNames,
) {
  if (enabledNames == null) return all;
  return [
    for (final s in all)
      if (enabledNames.contains(s.name)) s,
  ];
}
