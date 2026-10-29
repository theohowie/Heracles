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
 *   原文件：app/src/main/kotlin/b/ai/exec/Router.kt  （route() 的三档决策）
 *           —— 本测试验证的是**决策部分**：显式指定走哪档、自动选路取第一个可用。
 *              上游的 route() 里按目标路径反查通道的部分（零宽/原生/受限目录）
 *              故意不在这测，因为它已经移到 sandbox-file 的 PathSemantics。
 *
 * 本测试是纯 JVM 的：ChannelSelector 不 import android.*，不读文件系统。
 */

package com.heracles.sandbox.channel

import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.SandboxException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [ChannelSelector] 的选路优先级测试。
 *
 * <p>核心断言：
 * 1. **自动选路**按 `NORMAL → SHIZUKU → ROOT → WIRELESS_ADB` 取第一个可用的 ——
 *    四个通道全可用时选 NORMAL，而不是能力最强的 ROOT。这是本项目最重要的默认值。
 * 2. **显式指定**不可用时报 `CODE_CHANNEL_UNAVAILABLE`，**绝不静默降级**。
 * 3. 参数越界报 `CODE_INVALID_ARGUMENT`。
 * 4. 一个都没有报 `CODE_NO_CHANNEL`。
 */
class ChannelSelectorTest {

    private fun fact(type: ChannelType, available: Boolean) = ChannelFact(type, available)

    /** 全不可用。 */
    private fun none() = ChannelType.entries.map { fact(it, false) }

    /** 全部可用。 */
    private fun all() = ChannelType.entries.map { fact(it, true) }

    // ── 1. 自动选路（preferred = -1）──────────────────────────────────────

    @Test
    fun `auto select prefers NORMAL when every channel is available`() {
        // ★ 这是最重要的断言：能力最强是 ROOT，但默认选权限最小的 NORMAL。
        val selected = ChannelSelector.select(ChannelSelector.AUTO_PREFERRED, all())
        assertEquals(ChannelType.NORMAL, selected)
    }

    @Test
    fun `auto select falls through the fixed order`() {
        // NORMAL 不可用 → SHIZUKU
        assertEquals(
            ChannelType.SHIZUKU,
            ChannelSelector.select(
                ChannelSelector.AUTO_PREFERRED,
                listOf(fact(ChannelType.NORMAL, false), fact(ChannelType.SHIZUKU, true)),
            ),
        )
        // NORMAL/SHIZUKU 不可用 → ROOT
        assertEquals(
            ChannelType.ROOT,
            ChannelSelector.select(
                ChannelSelector.AUTO_PREFERRED,
                listOf(
                    fact(ChannelType.NORMAL, false),
                    fact(ChannelType.SHIZUKU, false),
                    fact(ChannelType.ROOT, true),
                ),
            ),
        )
        // 只有 WIRELESS_ADB 可用 → WIRELESS_ADB
        assertEquals(
            ChannelType.WIRELESS_ADB,
            ChannelSelector.select(
                ChannelSelector.AUTO_PREFERRED,
                listOf(fact(ChannelType.WIRELESS_ADB, true)),
            ),
        )
    }

    @Test
    fun `auto select ignores the order the facts were given in`() {
        // 故意倒序提供 facts：结果仍必须按 ChannelType 的声明顺序判定。
        val reversed = ChannelType.entries.reversed().map { fact(it, true) }
        assertEquals(ChannelType.NORMAL, ChannelSelector.select(ChannelSelector.AUTO_PREFERRED, reversed))
    }

    @Test
    fun `auto select returns NORMAL even when the other three are missing entirely`() {
        // 只提供 NORMAL 一条事实（其余缺项按不可用处理）
        val selected = ChannelSelector.select(
            ChannelSelector.AUTO_PREFERRED,
            listOf(fact(ChannelType.NORMAL, true)),
        )
        assertEquals(ChannelType.NORMAL, selected)
    }

    @Test
    fun `auto select throws NO_CHANNEL when nothing is available`() {
        val error = assertThrows(SandboxException::class.java) {
            ChannelSelector.select(ChannelSelector.AUTO_PREFERRED, none())
        }
        assertEquals(SandboxException.CODE_NO_CHANNEL, error.code)
    }

    @Test
    fun `autoSelect returns null instead of throwing`() {
        assertNull(ChannelSelector.autoSelect(none()))
        assertEquals(ChannelType.NORMAL, ChannelSelector.autoSelect(all()))
    }

    // ── 2. 显式指定 ─────────────────────────────────────────────────────

    @Test
    fun `explicit preference is honored even when a lower-risk channel exists`() {
        // 宿主点了 ROOT，就必须给 ROOT —— 不能因为 NORMAL 更安全就改写宿主的决定。
        assertEquals(ChannelType.ROOT, ChannelSelector.select(ChannelType.ROOT.ordinal, all()))
        assertEquals(ChannelType.SHIZUKU, ChannelSelector.select(ChannelType.SHIZUKU.ordinal, all()))
        assertEquals(
            ChannelType.WIRELESS_ADB,
            ChannelSelector.select(ChannelType.WIRELESS_ADB.ordinal, all()),
        )
    }

    @Test
    fun `explicit unavailable channel fails loudly instead of silently degrading`() {
        // ★ 第二个重要断言：指定的通道不可用时报错，不能偷偷换成 NORMAL。
        //   否则「高危操作被降权后仍显示成功」比直接失败危险得多。
        val facts = listOf(
            fact(ChannelType.NORMAL, true),
            fact(ChannelType.ROOT, false),
        )
        val error = assertThrows(SandboxException::class.java) {
            ChannelSelector.select(ChannelType.ROOT.ordinal, facts)
        }
        assertEquals(SandboxException.CODE_CHANNEL_UNAVAILABLE, error.code)
        // 报错信息要能指出是哪一档、为什么
        assertTrue(error.message!!.contains("ROOT"))
        assertTrue(error.message!!.contains("su"))
    }

    @Test
    fun `explicit unavailable channel gives a channel specific hint`() {
        val cases = mapOf(
            ChannelType.SHIZUKU to "Shizuku",
            ChannelType.ROOT to "su",
            ChannelType.WIRELESS_ADB to "无线调试",
        )
        cases.forEach { (type, keyword) ->
            val error = assertThrows(SandboxException::class.java) {
                ChannelSelector.select(type.ordinal, listOf(fact(type, false)))
            }
            assertEquals(SandboxException.CODE_CHANNEL_UNAVAILABLE, error.code)
            assertTrue(
                "${type.name} 的提示应提到 ${keyword}，实际：${error.message}",
                error.message!!.contains(keyword),
            )
        }
    }

    @Test
    fun `explicit channel never probed is reported as unavailable`() {
        // facts 里完全没有这一档 → 按「未探测到该通道」处理，而不是当成可用。
        val error = assertThrows(SandboxException::class.java) {
            ChannelSelector.select(
                ChannelType.WIRELESS_ADB.ordinal,
                listOf(fact(ChannelType.NORMAL, true)),
            )
        }
        assertEquals(SandboxException.CODE_CHANNEL_UNAVAILABLE, error.code)
        assertTrue(error.message!!.contains("未探测到"))
    }

    // ── 3. 参数校验 ─────────────────────────────────────────────────────

    @Test
    fun `out of range preference is INVALID_ARGUMENT`() {
        listOf(-2, -99, 4, 5, 100).forEach { bad ->
            val error = assertThrows(SandboxException::class.java) {
                ChannelSelector.select(bad, all())
            }
            assertEquals("preferred=$bad 应当是 INVALID_ARGUMENT", SandboxException.CODE_INVALID_ARGUMENT, error.code)
        }
    }

    @Test
    fun `minus one is the documented auto sentinel and is not treated as invalid`() {
        assertEquals(-1, ChannelSelector.AUTO_PREFERRED)
        assertEquals(ChannelType.NORMAL, ChannelSelector.select(-1, all()))
    }

    // ── 4. normalize / isAvailable ──────────────────────────────────────

    @Test
    fun `normalize always returns the four channels in declaration order`() {
        val shuffled = listOf(
            fact(ChannelType.ROOT, true),
            fact(ChannelType.WIRELESS_ADB, false),
            fact(ChannelType.NORMAL, true),
        )
        val normalized = ChannelSelector.normalize(shuffled)

        assertEquals(4, normalized.size)
        assertEquals(ChannelType.entries.toList(), normalized.map { it.type })
        // 缺失的 SHIZUKU 补成不可用
        assertEquals(false, normalized.first { it.type == ChannelType.SHIZUKU }.available)
        assertEquals(true, normalized.first { it.type == ChannelType.ROOT }.available)
    }

    @Test
    fun `isAvailable merges duplicate facts optimistically`() {
        // 同一通道两条矛盾的事实：任一条可用即算可用（探测结果取并集，避免漏报）
        val facts = listOf(
            fact(ChannelType.SHIZUKU, false),
            fact(ChannelType.SHIZUKU, true),
        )
        assertTrue(ChannelSelector.isAvailable(facts, ChannelType.SHIZUKU))
    }

    @Test
    fun `AUTO_ORDER matches the channel declaration order`() {
        // 顺序是契约的一部分：宿主用 ordinal 建索引，改顺序就是破坏 wire 契约。
        assertEquals(
            listOf(
                ChannelType.NORMAL,
                ChannelType.SHIZUKU,
                ChannelType.ROOT,
                ChannelType.WIRELESS_ADB,
            ),
            ChannelSelector.AUTO_ORDER,
        )
    }

    @Test
    fun `nameOf handles out of range ordinals`() {
        assertEquals("NORMAL", ChannelSelector.nameOf(0))
        assertEquals("WIRELESS_ADB", ChannelSelector.nameOf(3))
        assertEquals("ordinal=9", ChannelSelector.nameOf(9))
    }

    // ── 5. 真实设备情形回归 ─────────────────────────────────────────────
    // 这几条是照着**本机真机**（e35e48c6：装了 Shizuku 但没启动授权、无 root）写的。

    @Test
    fun `device with only normal channel available still executes on NORMAL`() {
        // 真机现状：无 root、Shizuku 装了但没授权、无线调试没开
        val facts = listOf(
            fact(ChannelType.NORMAL, true),
            fact(ChannelType.SHIZUKU, false),
            fact(ChannelType.ROOT, false),
            fact(ChannelType.WIRELESS_ADB, false),
        )
        assertEquals(ChannelType.NORMAL, ChannelSelector.select(ChannelSelector.AUTO_PREFERRED, facts))
        assertEquals(ChannelType.NORMAL, ChannelSelector.select(ChannelType.NORMAL.ordinal, facts))
        // 而且不能因为 SHIZUKU/ROOT 不可用就报「没有通道」
        assertNull(ChannelSelector.selectOrNull(ChannelType.ROOT.ordinal, facts))
    }

    @Test
    fun `root capable device still defaults to NORMAL in auto mode`() {
        // 有 root 也不自动用 —— 必须宿主显式要。
        val facts = listOf(
            fact(ChannelType.NORMAL, true),
            fact(ChannelType.ROOT, true),
        )
        assertEquals(ChannelType.NORMAL, ChannelSelector.select(ChannelSelector.AUTO_PREFERRED, facts))
        assertEquals(ChannelType.ROOT, ChannelSelector.select(ChannelType.ROOT.ordinal, facts))
    }
}
