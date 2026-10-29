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
 *   原文件：app/src/main/kotlin/b/ai/exec/Router.kt   （route() 的决策部分）
 *   原文件：app/src/main/kotlin/b/ai/core/Perms.kt    （三档权限模型：WorkMode NORMAL/SHIZUKU/ROOT）
 *   原文件：app/src/main/kotlin/b/ai/exec/Root.kt     （State 四态，用于「不可用原因」的分类）
 * 移植方式：只取「决策结果」——给定偏好与实际可用性，算出该走哪一档。
 *   **刻意不移植**：Router.route() 里按目标路径反查通道的部分（那是文件通道的事，
 *   见 ZeroWidthFileChannel）、以及任何 UI / 弹窗 / 「允许-拒绝」交互。
 *
 * 本文件是**纯 JVM**逻辑：不 import 任何 android.*，不读文件系统，不做 IO，
 * 因此可以直接在 JUnit 里跑（ChannelSelectorTest）。
 */

package com.heracles.sandbox.channel

import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.SandboxException

/**
 * 某个通道在**这一刻**的事实：是什么档、能不能用。
 *
 * <p>刻意比 [com.heracles.sandbox.api.ChannelInfo] 更小：
 * 选路只需要「可用性」，不需要文案 / 风险 / 能力描述。
 * 用这个最小类型可以保证选路逻辑是纯函数、且单测不必构造 Parcelable。
 *
 * <p><b>为什么没有 allow / deny 字段</b>：沙箱不做权限决策。
 * [available] 表达的是「前置条件是否满足」，不是「宿主是否放行」。
 * 一个 available=true 且 riskLevel=HIGH 的 Root 通道意味着
 * 「能用，但是影响整机，请宿主自己决定要不要用」。
 */
data class ChannelFact(
    /** 通道档位。 */
    val type: ChannelType,
    /** 前置条件是否满足（与「宿主是否允许」无关）。 */
    val available: Boolean,
)

/**
 * 通道选路：给定「宿主想要的」与「实际能用的」，算出最终用哪一档。
 *
 * ============================================================================
 * 选路规则（两条，无隐藏分支）
 * ============================================================================
 * 1. **宿主显式指定**（`preferred >= 0`）：就用它。
 *    - 该通道不可用 → 抛 [SandboxException.CODE_CHANNEL_UNAVAILABLE]，
 *      **不静默降级**。理由：宿主可能因为风险考量特意点了 Root，
 *      悄悄换成 NORMAL 会让「高危操作被降权后仍然显示成功」，
 *      比直接失败危险得多。
 *    - 越界（`preferred >= 4` 或 `preferred < -1`）→
 *      抛 [SandboxException.CODE_INVALID_ARGUMENT]。
 * 2. **自动选路**（`preferred == -1`）：按 [ChannelType] 的声明顺序
 *    （NORMAL → SHIZUKU → ROOT → WIRELESS_ADB）取**第一个可用**的。
 *
 * 第 2 条为什么是「从最低权限开始」而不是「从最强能力开始」：
 * 执行通道只决定**以什么身份**跑命令，真正的隔离由 PRoot 提供；
 * 在能力相同时选权限最小的那个是唯一不会「默认踩到用户没同意的东西」的顺序。
 * 宿主若想提权，必须显式传 `preferred`（Root=2 / Shizuku=1）。
 * **这不是权限策略，只是确定性的默认值** —— 策略永远在宿主侧。
 *
 * <p>上游对照：baicodex 的 `Router.route()` 第一句就是
 * `when (Cfg.workMode) { ROOT -> ...; SHIZUKU -> ...; NORMAL -> ... }`，
 * 即「用户/设置已经选定了档位，路由照办」。本类把那个档位显式化为 [preferred]，
 * 并补上上游没有的两种情况：指定档位不可用时的报错、以及自动选路的优先级。
 */
object ChannelSelector {

    /** 自动选路的偏好顺序：与 [ChannelType] 的声明顺序一致（契约要求，不要改）。 */
    val AUTO_ORDER: List<ChannelType> = ChannelType.entries.toList()

    /**
     * 选一个可用于执行的通道。
     *
     * @param preferred 宿主指定的通道 ordinal；-1 表示自动选路
     * @param facts     当前各通道的可用性（缺项按「不可用」处理）
     * @return 实际使用的通道
     * @throws SandboxException `CODE_INVALID_ARGUMENT`（preferred 越界）/
     *         `CODE_CHANNEL_UNAVAILABLE`（指定通道不可用）/ `CODE_NO_CHANNEL`（一个都没有）
     */
    @Throws(SandboxException::class)
    fun select(preferred: Int, facts: List<ChannelFact>): ChannelType =
        selectOrNull(preferred, facts)
            ?: when {
                preferred == AUTO_PREFERRED -> throw SandboxException(
                    SandboxException.CODE_NO_CHANNEL,
                    "当前没有任何可用通道（连 NORMAL 都不可用，属不应发生的状态）",
                )
                else -> throw SandboxException(
                    SandboxException.CODE_CHANNEL_UNAVAILABLE,
                    "指定的通道 ${nameOf(preferred)} 当前不可用：" +
                        (facts.firstOrNull { it.type.ordinal == preferred }?.let { unavailableHint(it) }
                            ?: "未探测到该通道"),
                )
            }

    /**
     * 同 [select]，但「选不出来」时返回 null 而不抛异常。
     *
     * <p>宿主若要展示「哪些通道现在能用」而不是直接执行，用这个更顺手。
     */
    fun selectOrNull(preferred: Int, facts: List<ChannelFact>): ChannelType? {
        if (preferred != AUTO_PREFERRED &&
            preferred !in 0 until ChannelType.entries.size
        ) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "preferred 越界：$preferred（只接受 -1 或 0..${ChannelType.entries.size - 1}）",
            )
        }
        if (preferred != AUTO_PREFERRED) {
            val wanted = ChannelType.entries[preferred]
            return if (isAvailable(facts, wanted)) wanted else null
        }
        return AUTO_ORDER.firstOrNull { isAvailable(facts, it) }
    }

    /**
     * 自动选路（`preferred == -1` 的语义），选不出来返回 null。
     *
     * <p>与 [selectOrNull] 分开暴露，是为了让「自动」这件事在调用点读起来
     * 不含魔法数字 -1。
     */
    fun autoSelect(facts: List<ChannelFact>): ChannelType? = selectOrNull(AUTO_PREFERRED, facts)

    /** 按契约顺序重排为 `NORMAL, SHIZUKU, ROOT, WIRELESS_ADB`，缺项补 `available=false`。 */
    fun normalize(facts: List<ChannelFact>): List<ChannelFact> {
        val byType = facts.associate { it.type to it.available }
        return AUTO_ORDER.map { ChannelFact(it, byType[it] ?: false) }
    }

    /** 某个通道当前是否可用；重复项按「任一为 true 即可用」合并（探测结果取并集，避免漏报）。 */
    fun isAvailable(facts: List<ChannelFact>, type: ChannelType): Boolean =
        facts.any { it.type == type && it.available }

    /** `preferred` 的「自动」哨兵值（来自 AIDL 契约）。 */
    const val AUTO_PREFERRED: Int = -1

    /** ordinal → 可读名，报错文案用。 */
    fun nameOf(ordinal: Int): String = ChannelType.entries.getOrNull(ordinal)?.name ?: "ordinal=$ordinal"

    private fun unavailableHint(fact: ChannelFact): String =
        when (fact.type) {
            ChannelType.NORMAL -> "普通 App 通道不可用（不应发生）"
            ChannelType.SHIZUKU -> "Shizuku 未安装 / 未启动 / 未授权"
            ChannelType.ROOT -> "设备没有 su，或 su 未授权本应用"
            ChannelType.WIRELESS_ADB -> "无线调试未开启，或尚未完成 adb pair 配对"
        }
}
