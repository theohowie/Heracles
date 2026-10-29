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
 * ============================================================================
 * 时区（TZ）注入的 JVM 单测 —— 不需要 Android 设备
 * ============================================================================
 * 为什么这组断言值得存在：
 *   沙箱里的 `date` 要跟随手机系统时区，全靠 `hostEnvironment()` 里那一个 TZ。
 *   它是**唯一来源**：管道路径 `environment().clear()+putAll(hostEnvironment())`、
 *   PTY 路径 `PtySession.open(envp = hostEnvironment())`（整体替换）都以它为准，
 *   PRoot 再把自身 environ 透传给 guest 子进程。
 *
 * 背景（D5 = A，ADR-039）：内置 Alpine rootfs 没有 zoneinfo，命名时区在 guest 里
 * 只会回退 UTC；所以注入的是**按设备当前偏移算出的 POSIX 串**（如 `CST-8`）。
 * 这组断言锁住四件容易悄悄退化的事：
 *   1. 偏移 → POSIX 串的**符号方向**（POSIX 是"西为正"，东八区写 `CST-8`）；
 *   2. 夏令时按**注入时刻**取当前偏移（不是把 EST+5 写死）；
 *   3. 半小时偏移写成 `-5:30` 而不是取整；
 *   4. `hostEnvironment()` 里真的有 TZ，且是 POSIX 串而不是命名 id；
 *      外加未知时区退回命名 id、TZ 受保护不可被 overlay 覆盖。
 *
 * 变异验证（改代码必须能变红）：
 *   把 [formatPosixOffset] 的 `if (totalMinutes > 0) "-" else "+"` 两个分支对调
 *   ⇒ 前四条断言（CST-8 / EST+5 / IST-5:30 / EDT+4）全部变红。
 */

package com.heracles.sandbox.runtime

import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.util.TimeZone
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ProotEngineTimeZoneTest {

    private lateinit var sandboxRoot: File
    private lateinit var engine: ProotEngine

    /** POSIX TZ 串的形态：3–4 字母名字 + 取反的 `±hh[:mm]`。 */
    private val posixTz = Regex("[A-Za-z]{3,4}[+-]\\d{1,2}(:\\d{2})?")

    private fun utc(isoInstant: String): Long = Instant.parse(isoInstant).toEpochMilli()

    /** 北半球夏令时（7 月）与标准时（1 月）各一个固定时刻，锁死断言不随跑测日期漂移。 */
    private val julyUtc = utc("2026-07-01T04:00:00Z")
    private val januaryUtc = utc("2026-01-15T12:00:00Z")

    @Before
    fun setUp() {
        sandboxRoot = Files.createTempDirectory("heracles-tz-test").toFile()
        // 主构造器不吃 Android Context：路径全部显式给出，纯 JVM 可跑。
        engine = ProotEngine(
            prootBinary = File(sandboxRoot, "libproot.so"),
            loaderBinary = null,
            rootfsHostRoot = File(sandboxRoot, "rootfs"),
            workspaceHostRoot = File(sandboxRoot, "workspace"),
            homeHostRoot = File(sandboxRoot, "home"),
            tmpHostRoot = File(sandboxRoot, "tmp"),
            attachmentsHostRoot = File(sandboxRoot, "attachments"),
        )
    }

    @After
    fun tearDown() {
        sandboxRoot.deleteRecursively()
    }

    // ========================================================================
    // 纯函数：偏移 → POSIX 串
    // ========================================================================

    @Test
    fun `东八区生成 CST-8`() {
        assertEquals(
            "东八区必须生成 CST-8（POSIX 的符号表示'本地时间在 UTC 之西'，所以 +8 写成 -8）",
            "CST-8",
            posixTzFor(julyUtc, "Asia/Shanghai"),
        )
    }

    @Test
    fun `西五区冬季生成 EST+5`() {
        assertEquals(
            "西五区标准时必须生成 EST+5（符号反转：UTC-5 写成 +5）",
            "EST+5",
            posixTzFor(januaryUtc, "America/New_York"),
        )
    }

    @Test
    fun `半小时偏移写成带分钟的 -5 30`() {
        assertEquals(
            "UTC+5:30 必须写成 IST-5:30（不能取整成 IST-5 或 IST-6）",
            "IST-5:30",
            posixTzFor(julyUtc, "Asia/Kolkata"),
        )
    }

    @Test
    fun `有夏令时的时区按注入时刻取当前偏移`() {
        // 同一条时区、两个注入时刻 ⇒ 结果必须不同：证明是"按当前偏移算"而不是写死一个串。
        assertEquals(
            "America/New_York 7 月是 EDT（UTC-4）⇒ EDT+4（POSIX 西为正：-4h 写成 +4）",
            "EDT+4",
            posixTzFor(julyUtc, "America/New_York"),
        )
        assertEquals(
            "America/New_York 1 月是 EST（UTC-5）⇒ EST+5",
            "EST+5",
            posixTzFor(januaryUtc, "America/New_York"),
        )
        assertNotEquals(
            "夏/冬两次的 POSIX 串必须不同（否则就是把偏移或缩写写死了）",
            posixTzFor(julyUtc, "America/New_York"),
            posixTzFor(januaryUtc, "America/New_York"),
        )
    }

    @Test
    fun `南半球夏令时方向相反也按月取偏移`() {
        // 悉尼：1 月是 AEDT（UTC+11），7 月是 AEST（UTC+10）。
        assertEquals("AEDT-11", posixTzFor(januaryUtc, "Australia/Sydney"))
        assertEquals("AEST-10", posixTzFor(julyUtc, "Australia/Sydney"))
    }

    @Test
    fun `UTC 生成零偏移 POSIX 串`() {
        val tz = posixTzFor(julyUtc, "UTC")
        assertEquals("UTC+0", tz)
        assertTrue("零偏移也必须能过 POSIX 形态", posixTz.matches(tz))
    }

    @Test
    fun `未知时区退回命名 id 而不是编造缩写`() {
        // 保守取舍（写进 ADR-039）：映射表没收录就退回命名 id，让 guest 回到
        // "透传成功但显示 UTC" 的旧行为，而不是编一个缩写把时间说错。
        val unknown = "Mars/Olympus_Mons"
        assertEquals(
            "未收录的时区必须原样退回命名 id（不擅自发明缩写）",
            unknown,
            posixTzFor(julyUtc, unknown),
        )
    }

    @Test
    fun `空时区 id 返回空串`() {
        assertEquals("空 id 必须返回空串，调用方据此不注入 TZ", "", posixTzFor(julyUtc, "  "))
    }

    // ========================================================================
    // hostEnvironment：真实注入点
    // ========================================================================

    @Test
    fun `hostEnvironment 注入 POSIX 串而不是命名 id`() {
        val original = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("Asia/Shanghai"))
            val env = engine.hostEnvironment()
            val tz = env["TZ"]
            assertEquals("hostEnvironment 必须注入 POSIX 串", "CST-8", tz)
            assertTrue(
                "TZ 必须是 POSIX 形态（命名 id 在无 zoneinfo 的 rootfs 里会回退 UTC）：$tz",
                tz != null && posixTz.matches(tz),
            )
        } finally {
            TimeZone.setDefault(original)
        }
    }

    @Test
    fun `TZ 跟随默认时区变化而不是硬编码`() {
        val original = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("Asia/Tokyo"))
            assertEquals("Asia/Tokyo ⇒ JST-9", "JST-9", engine.hostEnvironment()["TZ"])
            TimeZone.setDefault(TimeZone.getTimeZone("Asia/Kolkata"))
            assertEquals("Asia/Kolkata ⇒ IST-5:30", "IST-5:30", engine.hostEnvironment()["TZ"])
        } finally {
            TimeZone.setDefault(original)
        }
    }

    @Test
    fun `TZ 在 PROTECTED_GUEST_KEYS 里`() {
        assertTrue(
            "TZ 必须受保护：否则调用方可以把沙箱时区改成与设备不一致的值",
            ProotEngine.PROTECTED_GUEST_KEYS.contains("TZ"),
        )
    }

    @Test
    fun `guestEnvironment overlay 无法覆盖 TZ`() {
        // 改前：TZ 不在保护集合 ⇒ overlay 的 UTC 会被 put 进 guest env（本条变红）。
        val guarded = engine.guestEnvironment(interactive = false, overlay = mapOf("TZ" to "UTC"))
        assertFalse(
            "overlay 里的 TZ 必须被过滤掉（时区只能由宿主 hostEnvironment 注入）",
            guarded.containsKey("TZ"),
        )

        // 对照：非保护键仍然生效 —— 证明过滤逻辑本身没被写坏、这条测试不是空跑。
        val normal = engine.guestEnvironment(interactive = false, overlay = mapOf("FOO_BAR" to "1"))
        assertEquals("1", normal["FOO_BAR"])
    }
}
