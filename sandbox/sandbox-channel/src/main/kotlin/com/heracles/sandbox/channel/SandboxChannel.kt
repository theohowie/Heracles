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
 *
 * Heracles-taixu-sandbox is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Heracles-taixu-sandbox.  If not, see <https://www.gnu.org/licenses/>.
 *
 * ---------------------------------------------------------------------------
 * 移植来源
 * ---------------------------------------------------------------------------
 * 上游：baicodex (mubai0122/baicodex) @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95
 *   原文件：app/src/main/kotlin/b/ai/exec/Router.kt  （通道分档与「受限目录」判定）
 *   原文件：app/src/main/kotlin/b/ai/core/Perms.kt   （权限三档 + 特殊权限清单的「缺失前置条件」表达）
 * 移植的只是**事实描述**：一个通道现在能不能用、缺什么、以什么身份跑。
 * 上游里所有「去系统里开权限」的跳转（openAppSettings / openAllFiles / openA11y …）
 * 与 UI 一律不移植 —— 沙箱不引导用户，也不做权限决策。
 */

package com.heracles.sandbox.channel

import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.RiskLevel

/**
 * 一个通道此刻的**事实**状态（探测结果）。
 *
 * <p>刻意与 [com.heracles.sandbox.api.ChannelInfo] 分开：本类型是模块内部的探测产物，
 * 可以在单测里构造；[com.heracles.sandbox.api.ChannelInfo] 是 Parcelable 的对外契约，
 * 由 [ChannelManager] 从本类型映射过去。
 *
 * <p><b>没有 allow / deny。</b>沙箱只报告「前置条件是否满足」与「风险多高」，
 * 是否放行由宿主的信任策略决定（见 RiskLevel 的 KDoc）。
 */
data class ChannelStatus(
    val type: ChannelType,
    /** 前置条件是否满足。false 时由 [unavailableReason] 说明原因。 */
    val available: Boolean,
    /** 不可用原因（available=true 时为空串）。 */
    val unavailableReason: String = "",
    /** 缺少的前置条件清单（人读的短语，不是可点击的引导）。 */
    val missingPrerequisites: List<String> = emptyList(),
    /** 这个通道执行时的身份，如 `u0_a123` / `shell(2000)` / `root(0)` / `adb shell`。 */
    val executionIdentity: String = "",
    /** 一句话能力摘要（供宿主展示，不含决策）。 */
    val capabilitySummary: String = "",
    /** 给日志/调试用的额外事实（如 su 的绝对路径、Shizuku 版本号）。 */
    val detail: Map<String, String> = emptyMap(),
) {
    companion object {
        /** 构造一个「不可用」状态。 */
        fun unavailable(
            type: ChannelType,
            reason: String,
            missing: List<String> = emptyList(),
            identity: String = "",
            summary: String = "",
            detail: Map<String, String> = emptyMap(),
        ): ChannelStatus = ChannelStatus(
            type = type,
            available = false,
            unavailableReason = reason,
            missingPrerequisites = missing,
            executionIdentity = identity,
            capabilitySummary = summary,
            detail = detail,
        )

        /** 构造一个「可用」状态。 */
        fun ready(
            type: ChannelType,
            identity: String,
            summary: String,
            detail: Map<String, String> = emptyMap(),
        ): ChannelStatus = ChannelStatus(
            type = type,
            available = true,
            unavailableReason = "",
            missingPrerequisites = emptyList(),
            executionIdentity = identity,
            capabilitySummary = summary,
            detail = detail,
        )
    }
}

/**
 * 一个执行通道：既能探测自己「现在能不能用」，也能真的执行。
 *
 * <p>**通道只负责身份**。它拿到的 [CapabilityChannel.exec] 的 `command` 已经是
 * runtime 组装好的**宿主侧完整命令行**（含 PRoot 前缀、`-b` 绑定、`/bin/sh -c`），
 * 通道只决定「以谁的身份 spawn 它」。这条边界让通道实现完全不需要懂 PRoot，
 * 也避免四个通道各写一份 proot 参数拼装。
 *
 * <p>不可用时 [exec] 必须返回 `exitCode = -1` 并带上可读原因，**不得抛异常**：
 * 上层（runtime 的 execute）只会看到 [ShellOutcome]。
 */
interface SandboxChannel : CapabilityChannel {

    /** 宿主展示用名字（中文，与上游 Router 的档位名一致）。 */
    val displayName: String

    /**
     * 风险等级。
     *
     * <p>**这是信息不是决策**：HIGH 不代表沙箱拒绝，只代表「宿主默认应当要求确认」。
     */
    val riskLevel: RiskLevel

    /** 本通道的 spawn 是否支持 PTY（本模块只报告事实，PTY 由 runtime 的 PTY JNI 决定）。 */
    val supportsPty: Boolean

    /**
     * 本通道身份能否读其它 App 的 data 目录。
     *
     * <p>注意这是**执行身份**的能力，与零宽文件通道是两件事：
     * 零宽通道在 NORMAL 身份下也能穿透 Android/data（见 sandbox-file）。
     */
    val supportsCrossAppData: Boolean

    /**
     * 探测本通道此刻是否可用。
     *
     * <p>**必须可重入、可在任意线程调用、且永不抛异常**：
     * 实现内部要把所有失败收敛成 [ChannelStatus.unavailable]。
     * 这条约束是硬要求 —— 没有 Shizuku 的设备上，
     * 探测 Shizuku 通道不能把普通 App 通道一起带崩。
     */
    fun probe(): ChannelStatus
}
