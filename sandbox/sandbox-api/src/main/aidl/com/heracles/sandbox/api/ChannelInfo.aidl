/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * This file is part of Heracles-taixu-sandbox.
 *
 * Heracles-taixu-sandbox is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

package com.heracles.sandbox.api;

/*
 * 一个执行通道的可用性与风险描述。实现（Kotlin，手写 Parcelable）在
 * sandbox-api/src/main/kotlin/com/heracles/sandbox/api/Models.kt
 *
 * 字段语义（详见 docs/api-reference.md 与 docs/channel-matrix.md）：
 *   type                   int      通道标识 —— ChannelType 的 ordinal
 *   displayName            String   人类可读通道名
 *   available              boolean  前置条件是否全部满足
 *   unavailableReason      String   不可用原因；可用时为空串
 *   missingPrerequisites   List<String> 缺失的前置条件（可直接展示给用户）
 *   riskLevel              int      RiskLevel 的 ordinal
 *   capabilitySummary      String   该通道能力的一句话摘要
 *   supportsPty            boolean  是否支持真实 PTY 语义
 *   supportsCrossAppData   boolean  是否能穿透访问其它 App 的 data 目录
 *   executionIdentity      String   执行身份（"u0_a123" / "shell" / "root"）
 *
 * ★ 本结构刻意**不含**「是否允许使用」的字段。沙箱只报告事实与风险等级，
 *   放不放行由宿主的信任策略决定。
 */
parcelable ChannelInfo;
