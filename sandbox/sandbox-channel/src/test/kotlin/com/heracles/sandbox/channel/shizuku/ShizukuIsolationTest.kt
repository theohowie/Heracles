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
 *   原文件：app/src/main/kotlin/b/ai/exec/Shiz.kt
 *           （被验证的行为：pingBinder 为 false 时 probe 必须报「不可用」而不是抛异常）
 *
 * ============================================================================
 * 这个测试守护的是本模块的**硬验收项**
 * ============================================================================
 * `sandbox-channel` 对 Shizuku 只有 compileOnly 依赖 ⇒ 运行期**默认没有**
 * rikka.shizuku.* 这些类。若任何通道代码在类加载期就解析了它们，
 * 缺类会抛 NoClassDefFoundError，把**普通 App 通道一起带崩**。
 *
 * 因此本测试断言三件事：
 * 1. 装载器 `ShizukuAccessLoader.load()` **永不抛**（连 Throwable 都不抛），
 *    且总返回一个可用的对象。
 * 2. [ShizukuChannel] 在没有可用 Shizuku 时，`probe()` 返回「不可用」而不是崩，
 *    `exec()` 返回 -1 而不是崩。
 * 3. 隔离层对外的每个方法都以 ShellOutcome / ChannelStatus 收口 ——
 *    调用方永远不需要为「Shizuku 不存在」写 try/catch。
 *
 * 注意本测试**不需要 Robolectric**：所有被测入口都能在没有 Context 的情况下工作
 * （探测会因此退化为「不可用」，这正是我们要验证的降级路径）。
 */

package com.heracles.sandbox.channel.shizuku

import com.heracles.sandbox.api.ChannelType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Shizuku 隔离层的降级测试。
 *
 * <p>⚠️ 本测试**不**验证「有 Shizuku 时能执行」—— 那需要真机 + 已授权的 Shizuku
 * （见任务书的环境说明：本机装了 Shizuku 但未授权）。这里守的是另一半：
 * **没有 Shizuku 时必须优雅降级**。
 */
class ShizukuIsolationTest {

    // ── 1. 装载器永不抛 ────────────────────────────────────────────────

    @Test
    fun `loader never throws and always returns an instance`() {
        // 不论 rikka 类在不在运行期 classpath，这一步都必须成功。
        // 若实现里出现了静态引用，这里会在类加载期抛 NoClassDefFoundError 而失败。
        val access: ShizukuAccess = ShizukuAccessLoader.load()
        assertNotNull(access)
        // 幂等：第二次拿到的是同一个（或至少是同样可用的）实现
        assertNotNull(ShizukuAccessLoader.load())
    }

    @Test
    fun `resetting the loader cache does not throw`() {
        ShizukuAccessLoader.clearForTest()
        assertNotNull(ShizukuAccessLoader.load())
    }

    // ── 2. 通道在无 Shizuku 时优雅降级 ──────────────────────────────────

    @Test
    fun `probe degrades to unavailable instead of crashing`() {
        // context = null：模拟「拿不到可用 Context / 无 Shizuku」的最坏情况
        val channel = ShizukuChannel(context = null)

        val status = channel.probe()

        // 关键断言：返回了一个**结构完整**的不可用状态，而不是抛异常
        assertEquals(ChannelType.SHIZUKU, status.type)
        assertFalse(status.available)
        assertTrue("必须给出不可用原因", status.unavailableReason.isNotBlank())
        // 必须如实说明缺什么，宿主才能引导用户
        assertTrue(
            "应说明缺少的前置条件，实际：${status.missingPrerequisites}",
            status.missingPrerequisites.isNotEmpty(),
        )
        // 风险等级与能力摘要是「信息」，即使不可用也要有条目
        assertEquals("Shizuku", channel.displayName)
        assertTrue(status.capabilitySummary.isNotBlank())
    }

    @Test
    fun `exec returns a failed outcome instead of throwing`() {
        val channel = ShizukuChannel(context = null)

        val outcome = channel.exec("echo hello", null, 1_000L)

        // 关键断言：exitCode = -1（通道层失败），且**没有异常逃逸**
        assertEquals(-1, outcome.exitCode)
        assertFalse(outcome.isSuccess)
        assertTrue("必须带可读原因", outcome.output.isNotBlank())
        // 绝不能被当成「命令成功但无输出」
        assertFalse(outcome.timedOut)
    }

    @Test
    fun `requestPermission without context reports NO_SERVICE instead of throwing`() {
        val channel = ShizukuChannel(context = null)

        var result: ShizukuPermissionResult? = null
        channel.requestPermission { result = it }

        // 一定会回调一次（不能静默丢弃）
        assertNotNull("授权申请必须回调一次", result)
        assertEquals(ShizukuPermissionResult.NO_SERVICE, result)
    }

    // ── 3. 隔离层的占位实现 ───────────────────────────────────────────

    @Test
    fun `unavailable access reports the reason and refuses to execute`() {
        val access = UnavailableShizukuAccess("测试用的缺失原因")

        // context = null 是合法输入：占位实现报「不可用」，不 dereference 上下文。
        val facts = access.facts(null)
        assertNotNull("必须带 loadError 说明为什么不可用", facts.loadError)
        assertTrue(facts.loadError!!.contains("测试用的缺失原因"))
        assertFalse("类装载失败时绝不能报告可用", facts.usable)

        val outcome = access.exec("echo hi", null, 1_000L)
        assertEquals(-1, outcome.exitCode)
        assertTrue(outcome.output.contains("测试用的缺失原因"))
    }

    @Test
    fun `ShizukuFacts usability requires every prerequisite`() {
        // 逐个置为 false，验证 usable 是全条件与（不是任一条件）
        assertFalse("完全没有前置条件时不可用", ShizukuFacts().usable)
        assertFalse(
            "binder 活着但没授权",
            ShizukuFacts(binderAlive = true, permissionGranted = false).usable,
        )
        assertFalse(
            "已授权但版本过旧",
            ShizukuFacts(binderAlive = true, permissionGranted = true, preV11 = true).usable,
        )
        assertTrue(
            "四项都满足才可用",
            ShizukuFacts(binderAlive = true, permissionGranted = true, preV11 = false).usable,
        )
        assertFalse(
            "类装载失败时其余字段再对也不可用",
            ShizukuFacts(
                binderAlive = true,
                permissionGranted = true,
                preV11 = false,
                loadError = "缺类",
            ).usable,
        )
    }

    // ── 4. 常量契约 ──────────────────────────────────────────────────

    @Test
    fun `protocol constants stay stable`() {
        // 这些值出现在 Binder 事务与 manifest 里，改动会破坏兼容性
        assertEquals("moe.shizuku.privileged.api", ShizukuProtocol.SHIZUKU_PACKAGE)
        assertEquals(4210, ShizukuProtocol.REQUEST_CODE)
        assertEquals(1, ShizukuProtocol.TX_EXEC)
        assertEquals(2, ShizukuProtocol.TX_UID)
        assertTrue(ShizukuProtocol.DESCRIPTOR.isNotBlank())
        // Binder 单次事务上限（约 1MB，留余量）
        assertTrue(ShizukuProtocol.MAX_STDIN_CHARS <= 1_000_000)
    }

    @Test
    fun `channel reports shell uid constant used for backend detection`() {
        assertEquals(2000, ShizukuChannel.SHELL_UID)
    }
}
