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
 * T2 编译环境的「真状态 / 真卸载」单测（T2-6）—— 不需要设备、不联网
 * ============================================================================
 * 为什么这组断言值得存在：
 *   改动前 `reset()` 只是 `File(opt/t2).deleteRecursively()` 并返回 Boolean，
 *   两个真问题被藏起来了：
 *     1. **JDK 没删**（它由 `apk add` 装进 usr/lib/jvm，体积 ≈284 MB）⇒
 *        "卸载成功"但空间几乎没释放、`status()` 里 jdk 仍为 true；
 *     2. **apk 数据库没清** ⇒ 下次激活 `apk add` 以为已装好而跳过，javac 永远缺失。
 *   现在 reset 返回 `{removed, failed, installDir, freedBytes, missing, ready}`，
 *   本文件锁的就是这些字段的**真实性**（不是"函数被调过"）。
 *
 * 覆盖：
 *   ① 空环境 status：未就绪 + 缺失项是**人话** + 占用 0
 *   ② 装好 T2 status：就绪 + 占用 > 0 + 缺失为空 + 版本标记可读
 *   ③ reset 清单：三件套（opt/t2、JDK 目录、gradle 链接）都被删、ready 翻转 false、
 *      freedBytes 是实测差、missing 三项
 *   ④ reset 边界：不碰 rootfs（T0）/ opt/as（T1）/ workspace（用户工作区）
 *   ⑤ 本来没装 ⇒ success 且 removed 为空、freedBytes 0
 *   ⑥ JDK 在 apk 库时先 `apk del`（数据库一致性）
 *   ⑦ `apk del` 失败但文件删掉 ⇒ 成功但 message 带警告（不谎报干净）
 *   ⑧ 删除失败 ⇒ failed 有明确路径+原因、success=false
 *   ⑨ 删了却仍就绪（残留/说谎）⇒ 列为失败，不许假绿
 */

package com.heracles.sandbox.runtime

import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ToolchainActivationTest {

    private lateinit var rootfs: File

    /** 假的沙箱执行器：记录命令并按需返回 apk 探测/卸载结果。 */
    private class FakeSandbox {
        val commands = mutableListOf<String>()
        var apkInfoInstalled = false
        var apkDelExit = 0

        suspend fun run(command: String, timeoutMs: Long): ToolchainActivation.CommandOutcome {
            commands += command
            return when {
                command.contains("apk info -e") ->
                    ToolchainActivation.CommandOutcome(if (apkInfoInstalled) 0 else 1, "", "")
                command.contains("apk del") ->
                    ToolchainActivation.CommandOutcome(
                        apkDelExit,
                        if (apkDelExit == 0) "deleted" else "",
                        if (apkDelExit == 0) "" else "apk: not installed",
                    )
                else -> ToolchainActivation.CommandOutcome(0, "", "")
            }
        }
    }

    private lateinit var sandbox: FakeSandbox

    @Before
    fun setUp() {
        rootfs = Files.createTempDirectory("heracles-t2-test").toFile()
        sandbox = FakeSandbox()
    }

    @After
    fun tearDown() {
        rootfs.deleteRecursively()
    }

    private fun activation(): ToolchainActivation = ToolchainActivation(
        rootfsHostRoot = rootfs,
        runInSandbox = { command, timeoutMs -> sandbox.run(command, timeoutMs) },
    )

    // ---------------------------------------------------------------- 夹具

    /** 造一份"已装好 T2"的 rootfs（含 T0/T1/用户工作区标记，用于验证边界）。 */
    private fun installFakeT2() {
        write("opt/t2/gradle/gradle-8.14.2/bin/gradle", "#!/bin/sh\n")
        write("opt/t2/platform/android.jar", "jar")
        // android.jar 要求 > 1MB 才算数（防"截断的假文件"）
        File(rootfs, "opt/t2/platform/android.jar").writeBytes(ByteArray(1_100_000))
        write("opt/t2/${ToolchainActivation.VERSION_MARKER}", "t2-test-version\n")
        write("usr/lib/jvm/java-17-openjdk/bin/javac", "javac")
        write("usr/local/bin/gradle", "/opt/t2/gradle/bin/gradle")
        // —— 这些**不该**被 reset 碰 ——
        write("bin/sh", "t0-rootfs")
        write("opt/as/aapt2", "t1-tool")
        write("workspace/user.txt", "user-work")
    }

    private fun write(relative: String, text: String): File {
        val file = File(rootfs, relative)
        file.parentFile?.mkdirs()
        file.writeText(text)
        return file
    }

    // ========================================================================
    // ① ② status 的真状态
    // ========================================================================

    @Test
    fun `空环境的 status 未就绪且缺失项是人话`() {
        val st = activation().status()
        assertFalse("没装 T2 时 ready 必须为 false", st.ready)
        assertEquals(3, st.parts.size)
        assertTrue("三项都应缺失：${st.parts}", st.parts.values.none { it })
        assertEquals(0L, st.occupiedBytes)
        assertEquals(
            "缺失项必须是人话（UI 直接显示），不能是内部 key",
            listOf("JDK 17（javac）", "Gradle（bin/gradle）", "android.jar（platform/android.jar）"),
            st.missing,
        )
        assertTrue(
            "installDir 应指向 rootfs 下的 opt/t2（宿主绝对路径，单测机上可能是反斜杠）",
            st.installDir.replace('\\', '/').endsWith("opt/t2"),
        )
        assertEquals("", st.version)
    }

    @Test
    fun `装好 T2 时 status 就绪且报占用与版本`() {
        installFakeT2()
        val st = activation().status()
        assertTrue("三项齐了必须 ready：${st.parts}", st.ready)
        assertTrue("缺少项应为空", st.missing.isEmpty())
        assertTrue(
            "占用必须≥ android.jar 体积（还要算 gradle/JDK）：${st.occupiedBytes}",
            st.occupiedBytes >= 1_100_000L,
        )
        assertEquals("t2-test-version", st.version)
    }

    // ========================================================================
    // ③ ④ ⑤ reset 清单与边界
    // ========================================================================

    @Test
    fun `reset 删掉三件套并把 ready 翻成 false`() {
        installFakeT2()
        val before = activation().status()
        assertTrue(before.ready)

        val result = runBlocking { activation().reset() }

        assertTrue("干净卸载时 success 必须为 true：${result.message}", result.success)
        assertFalse("卸载后 ready 必须翻转成 false", result.ready)
        assertEquals(
            "删除清单必须含三件套（沙箱视角路径）",
            listOf("/opt/t2", "/usr/lib/jvm/java-17-openjdk", "/usr/local/bin/gradle").sorted(),
            result.removed.sorted(),
        )
        assertTrue("失败项应为空：${result.failed}", result.failed.isEmpty())
        assertTrue("释放字节必须是实测差（约 1.1MB 起）：${result.freedBytes}", result.freedBytes > 1_000_000L)
        assertEquals(
            "卸载后三项都应回到缺失状态",
            listOf("JDK 17（javac）", "Gradle（bin/gradle）", "android.jar（platform/android.jar）"),
            result.missing,
        )
        assertTrue("message 要是人话：${result.message}", result.message.contains("已卸载"))
        assertTrue("message 要带释放体积：${result.message}", result.message.contains("MB"))

        // 文件必须**真的**不存在（不是只翻了个标志位）
        listOf(
            "opt/t2",
            "usr/lib/jvm/java-17-openjdk",
            "usr/local/bin/gradle",
        ).forEach { assertFalse("$it 必须已被删除", File(rootfs, it).exists()) }
        assertFalse("reset 后 status 必须未就绪", activation().status().ready)
    }

    @Test
    fun `reset 不碰 rootfs T1 与用户工作区`() {
        installFakeT2()
        val result = runBlocking { activation().reset() }
        assertTrue(result.success)

        assertTrue("T0 rootfs 的 bin/sh 不能被删", File(rootfs, "bin/sh").isFile)
        assertTrue("T1 内置工具 opt/as 不能被删", File(rootfs, "opt/as/aapt2").isFile)
        assertTrue("用户工作区不能被删", File(rootfs, "workspace/user.txt").isFile)
        assertEquals("user-work", File(rootfs, "workspace/user.txt").readText())
    }

    @Test
    fun `本来没装时 reset 也成功且清单为空`() {
        val result = runBlocking { activation().reset() }
        assertTrue(
            "'本来就没装'不该算失败：${result.message}",
            result.success,
        )
        assertFalse(result.ready)
        assertTrue("没有可删的东西 ⇒ removed 为空：${result.removed}", result.removed.isEmpty())
        assertEquals("没删东西 ⇒ 释放 0 字节", 0L, result.freedBytes)
        assertEquals(3, result.missing.size)
    }

    // ========================================================================
    // ⑥ ⑦ apk 数据库一致性
    // ========================================================================

    @Test
    fun `JDK 在 apk 库时先 apk del 再删文件`() {
        installFakeT2()
        sandbox.apkInfoInstalled = true
        sandbox.apkDelExit = 0

        val result = runBlocking { activation().reset() }

        assertTrue(result.success)
        assertTrue(
            "必须先探测 apk 库里有没有 JDK：${sandbox.commands}",
            sandbox.commands.any { it.contains("apk info -e openjdk17-jdk") },
        )
        assertTrue(
            "在库里就必须 apk del（否则下次 activate 会跳过 JDK）：${sandbox.commands}",
            sandbox.commands.any { it.contains("apk del openjdk17-jdk") },
        )
        assertFalse("文件仍要删干净", File(rootfs, "usr/lib/jvm/java-17-openjdk").exists())
        assertFalse("message 不该提 apk 失败（del 成功）：${result.message}", result.message.contains("apk del openjdk17-jdk 未成功"))
    }

    @Test
    fun `apk del 失败但文件删掉时不谎报干净`() {
        installFakeT2()
        sandbox.apkInfoInstalled = true
        sandbox.apkDelExit = 1

        val result = runBlocking { activation().reset() }

        // 文件层面确实删掉了 ⇒ 不把整次操作判死；但必须在 message 里如实提示数据库风险
        assertTrue("文件已删 ⇒ success 可为 true：${result.message}", result.success)
        assertFalse(File(rootfs, "usr/lib/jvm/java-17-openjdk").exists())
        assertTrue(
            "apk del 失败必须在 message 里留下风险说明：${result.message}",
            result.message.contains("apk del openjdk17-jdk 未成功") ||
                result.message.contains("apk 数据库"),
        )
    }

    // ========================================================================
    // ⑧ ⑨ 失败项必须如实报
    // ========================================================================

    @Test
    fun `删除失败会出现在 failed 里且 success 为 false`() {
        installFakeT2()
        val jdk = File(rootfs, "usr/lib/jvm/java-17-openjdk")

        val result = runBlocking {
            activation().reset { dir ->
                if (dir.absolutePath == jdk.absolutePath) false else dir.deleteRecursively()
            }
        }

        assertFalse("有删不掉的文件 ⇒ 不能报成功", result.success)
        assertEquals("失败项应只有 JDK 一条：${result.failed}", 1, result.failed.size)
        assertEquals("/usr/lib/jvm/java-17-openjdk", result.failed[0].path)
        assertTrue("失败原因不能为空", result.failed[0].reason.isNotBlank())
        assertTrue("message 要带失败项：${result.message}", result.message.contains("卸载未完全成功"))
        assertTrue("JDK 目录确实还在（注入的失败）", jdk.exists())
        assertTrue(
            "另外两项仍应删掉：${result.removed}",
            result.removed.contains("/opt/t2") && result.removed.contains("/usr/local/bin/gradle"),
        )
    }

    @Test
    fun `删完仍显示就绪时列为失败不假绿`() {
        installFakeT2()
        // 注入一个"嘴上说成功、实际不删"的删除函数：模拟残留/异常实现
        val result = runBlocking { activation().reset { true } }

        assertFalse("卸载后仍 ready ⇒ 必须判失败", result.success)
        assertTrue(
            "必须给出「卸载后仍就绪」的失败项：${result.failed}",
            result.failed.any { it.reason.contains("仍显示就绪") },
        )
        assertTrue("文件其实还在（注入函数没删）", activation().status().ready)
    }
}
