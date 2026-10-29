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
 */

package com.heracles.sandbox.demo

import android.content.Context
import com.heracles.sandbox.api.ChannelInfo
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.RiskLevel
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.channel.ChannelManager
import com.heracles.sandbox.channel.ChannelFact
import com.heracles.sandbox.channel.ChannelSelector

/**
 * 「通道能力查询」最小示例。
 *
 * ============================================================================
 * 这个类为什么存在
 * ============================================================================
 * 沙箱**不做权限决策**。它只回答三件事：
 *
 *   1. 现在有哪些通道？
 *   2. 各自的前置条件满足了吗？
 *   3. 各自的风险等级是多少？
 *
 * 「要不要放行」是**宿主**的事。本类里的 [demoPolicy] 是一个**演示性**策略，
 * 用来展示宿主该怎么消费这些信息 —— 它在沙箱之外，宿主可以整个换掉。
 */
class ChannelDemo(context: Context) {

    private val appContext = context.applicationContext
    private val manager = ChannelManager(context = appContext)

    /** 四条通道的可读报告。 */
    fun report(): String {
        val channels = manager.queryChannels()
        if (channels.isEmpty()) return "没拿到任何通道（channel 模块未正确初始化）"

        return buildString {
            appendLine("=== 四条通道 ===")
            channels.forEach { info ->
                appendLine()
                appendLine(format(info))
            }

            appendLine()
            appendLine("=== 自动选路的建议（仅供参考）===")
            // 自动选路：priority -1 = 从最小权限开始找第一个可用的
            val facts = channels.map {
                ChannelFact(
                    type = ChannelType.entries[it.type],
                    available = it.available,
                )
            }
            appendLine("  自动选路 → ${describe(runCatching {
                ChannelSelector.select(ChannelSelector.AUTO_PREFERRED, facts)
            })}")

            // 显式指定：可用就用，不可用就报错（**不静默降级**）
            ChannelType.entries.forEach { type ->
                val verdict = runCatching {
                    ChannelSelector.select(type.ordinal, facts)
                }
                appendLine("  指定 ${type.name} → ${describe(verdict)}")
            }

            appendLine()
            append("★ 上面只是**建议**。宿主可以完全无视，自己按 ChannelInfo 做决策。")
        }
    }

    private fun describe(result: Result<ChannelType>): String = result.fold(
        onSuccess = { "选 ${it.name}" },
        onFailure = { t ->
            when (t) {
                is SandboxException -> "不可用（code=${t.code}）：${t.message}"
                else -> "异常：${t.message}"
            }
        },
    )

    /** 单个通道的格式化输出。 */
    fun format(info: ChannelInfo): String = buildString {
        val type = info.channelType?.name ?: "UNKNOWN(${info.type})"
        val risk = info.risk?.name ?: "UNKNOWN(${info.riskLevel})"
        appendLine("[$type] ${info.displayName}")
        appendLine("  available   = ${info.available}")
        appendLine("  riskLevel   = $risk")
        appendLine("  identity    = ${info.executionIdentity}")
        appendLine("  pty         = ${info.supportsPty}   crossAppData = ${info.supportsCrossAppData}")
        appendLine("  capability  = ${info.capabilitySummary}")
        if (!info.available) {
            appendLine("  缺前置条件:")
            info.missingPrerequisites.forEach { appendLine("    · $it") }
            if (info.unavailableReason.isNotBlank()) appendLine("  原因: ${info.unavailableReason}")
        }
    }

    /**
     * **宿主侧**的信任策略示例 —— 刻意放在 demo 里而不在沙箱里。
     *
     * 换成 Heracles 自己的策略、换成别的 Agent 项目的策略，
     * 沙箱一行都不用改。这就是「沙箱不做决策」的价值。
     */
    fun demoPolicy(info: ChannelInfo): PolicyVerdict = when (info.risk) {
        RiskLevel.LOW -> PolicyVerdict.ALLOW
        RiskLevel.MEDIUM -> PolicyVerdict.ASK_EACH_TIME
        RiskLevel.HIGH -> PolicyVerdict.ASK_EACH_TIME
        null -> PolicyVerdict.DENY
    }

    /** 宿主侧决策结果（**宿主的**概念，不是沙箱的）。 */
    enum class PolicyVerdict { ALLOW, ASK_EACH_TIME, DENY }

    /** 把所有通道按 [demoPolicy] 过一遍。 */
    fun policyReport(): String = buildString {
        appendLine("=== 宿主侧策略演练（沙箱不参与）===")
        manager.queryChannels().forEach { info ->
            val verdict = if (!info.available) "（不可用，跳过）" else demoPolicy(info).name
            appendLine("  ${info.channelType?.name} risk=${info.risk?.name} → $verdict")
        }
        appendLine()
        append("★ 换个宿主，这张映射表可以完全不同 —— 这正是沙箱不做决策的意义。")
    }

    /** 当前实际可用的通道。 */
    fun availableChannels(): List<ChannelType> =
        manager.queryChannels().filter { it.available }.mapNotNull { it.channelType }
}
