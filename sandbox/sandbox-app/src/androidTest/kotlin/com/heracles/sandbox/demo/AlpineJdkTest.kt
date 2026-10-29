/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * 设备侧验证：在 **Alpine rootfs 内**装 musl 版 JDK + 跑 Gradle。
 *
 * ============================================================================
 * 为什么不用 Temurin
 * ============================================================================
 * Temurin 是 **glibc** 构建（解释器 `/lib/ld-linux-aarch64.so.1`），
 * 而内置 rootfs 是 Alpine（**musl**，只有 `/lib/ld-musl-aarch64.so.1`）。
 *
 * 真机实测：把 Temurin 解压进 `/opt/ja` 后 `java -version` 返回 **127**
 * —— 内核找不到 ELF 解释器。这与 Phase 7 的 bionic/musl 是同一类问题：
 * **ABI 不匹配的东西放进去也跑不了**。
 *
 * ⇒ Alpine rootfs 要装 Alpine 自己的 musl 版 JDK：`apk add openjdk17-jdk`。
 *   Gradle 是 Java 归档（与 ABI 无关），跟着哪个 JDK 都能跑。
 */

package com.heracles.sandbox.demo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.runtime.BuildSuiteCatalog
import com.heracles.sandbox.runtime.BuildSuiteInstaller
import com.heracles.sandbox.runtime.ToolchainLayout
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AlpineJdkTest {

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val TAG = "AlpineJdkTest"

    /** 诊断：沙箱内网络 + Alpine 源是否可用（不装大件）。 */
    @Test
    fun diagnose_apkNetworkAndRepo() {
        val facade = SandboxFacade(context)
        assertTrue("需要 rootfs", runBlocking { facade.ensureRootfs() })
        ensureDns(facade)

        val update = runCommand(facade, "apk update 2>&1", 180_000)
        logI("apk update: exit=${update.exitCode} out=[${update.stdout.trim().take(400)}]")

        val jdkSearch = runCommand(facade, "apk list 2>/dev/null | grep -i jdk | head -6", 180_000)
        logI("apk list jdk: out=[${jdkSearch.stdout.trim()}]")

        assertTrue("apk update 应成功（exit=${update.exitCode}）", update.exitCode == 0)
    }

    /** 主线：装 musl JDK + 跑 Gradle，**全程在 rootfs 内**。 */
    @Test
    fun alpineMuslJdk_andGradle_runInsideSandbox() {
        val facade = SandboxFacade(context)
        assertTrue("需要 rootfs", runBlocking { facade.ensureRootfs() })
        ensureDns(facade)

        // ---- 1. 装 Alpine 的 musl JDK ----
        val add = runCommand(facade, "apk add --no-cache openjdk17-jdk 2>&1", 900_000)
        logI("apk add openjdk17-jdk: exit=${add.exitCode} tail=[${add.stdout.trim().takeLast(400)}]")
        assertEquals("apk add 应成功（out=${add.stdout.takeLast(300)}）", 0, add.exitCode)

        // ---- 2. java -version ----
        val java = runCommand(facade, "java -version 2>&1", 180_000)
        logI("sandbox java -version: exit=${java.exitCode} out=[${java.stdout.trim()}]")
        assertEquals("java 应在沙箱内可执行（out=${java.stdout}）", 0, java.exitCode)
        assertTrue(
            "应输出 OpenJDK 版本，实际=${java.stdout}",
            java.stdout.contains("openjdk version") || java.stdout.contains("OpenJDK"),
        )

        // ---- 3. 确认真的来自 rootfs ----
        val which = runCommand(facade, "command -v java")
        logI("sandbox which java = [${which.stdout.trim()}]")
        assertTrue(
            "java 必须来自 rootfs（实际=${which.stdout.trim()}）",
            which.stdout.contains("/usr/lib/jvm/") || which.stdout.contains("/usr/bin/java"),
        )

        // ---- 4. 装 Gradle（宿主 push 的归档，离线）----
        val extDir = context.getExternalFilesDir(null)
        val gradleArchive = File(extDir, GRADLE_ARCHIVE)
        assumeTrue("需要把 gradle 归档 push 到 ${extDir?.absolutePath}", gradleArchive.isFile)

        val installer = BuildSuiteInstaller(facade.rootfsHostRoot()!!)
        val gradleInstall = runBlocking {
            installer.installFromLocalArchive(BuildSuiteCatalog.GRADLE, gradleArchive) { _, _, s ->
                logI("gradle: $s")
            }
        }
        logI("gradle install: success=${gradleInstall.success} msg=${gradleInstall.message}")
        assertTrue("Gradle 必须装成功：${gradleInstall.message}", gradleInstall.success)

        // ---- 5. gradle --version（JAVA_HOME 指向 Alpine JDK）----
        val cmd = ToolchainLayout.envPrelude(ToolchainLayout.ALPINE_JDK_HOME) + "gradle --version 2>&1"
        val gv = runCommand(facade, cmd, 900_000)
        logI("sandbox gradle --version: exit=${gv.exitCode} out=[${gv.stdout.trim().take(700)}]")
        assertEquals("gradle 应在沙箱内可执行（out=${gv.stdout.take(400)}）", 0, gv.exitCode)
        assertTrue("应输出 Gradle 版本，实际=${gv.stdout}", gv.stdout.contains("Gradle 8."))
    }

    // ------------------------------------------------------------------

    /**
     * 内置 Alpine minirootfs **没有 `/etc/resolv.conf`** ⇒ DNS 不通 ⇒
     * `apk` 连不上源（真机实测 `temporary error (try again later)`）。
     * 补一份可用的 DNS：网关 + 两个公共 DNS。
     */
    private fun ensureDns(facade: SandboxFacade) {
        val existing = runCommand(facade, "test -s /etc/resolv.conf && echo HAS_DNS || echo NO_DNS", 30_000)
        logI("resolv.conf: ${existing.stdout.trim()}")
        if (existing.stdout.contains("NO_DNS")) {
            runCommand(
                facade,
                "printf \"nameserver 192.168.137.1\\nnameserver 114.114.114.114\\nnameserver 223.5.5.5\\n\" > /etc/resolv.conf",
                30_000,
            )
            val after = runCommand(facade, "cat /etc/resolv.conf", 30_000)
            logI("resolv.conf written: [${after.stdout.trim()}]")
        }
    }

    private fun logI(msg: String) = android.util.Log.i(TAG, msg)

    private fun runCommand(
        facade: SandboxFacade,
        command: String,
        timeoutMs: Long = 180_000,
    ): ExecutionResult {
        val latch = CountDownLatch(1)
        var result: ExecutionResult? = null
        val out = StringBuilder()
        facade.execute(
            ExecutionRequest(command = command, workingDirectory = "/", timeoutMillis = timeoutMs),
            object : IExecutionCallback.Stub() {
                override fun onOutput(stream: Int, chunk: String, sequence: Long) { out.append(chunk) }
                override fun onProgress(percent: Int, message: String) = Unit
                override fun onExit(r: ExecutionResult) { result = r; latch.countDown() }
                override fun onError(code: Int, message: String) {
                    result = ExecutionResult(
                        exitCode = -1, stdout = out.toString(), stderr = message,
                        durationMillis = 0, timedOut = false, cancelled = false,
                        truncated = false, channelType = ChannelType.NORMAL.ordinal,
                    )
                    latch.countDown()
                }
                override fun isCancelled(): Boolean = false
            },
        )
        latch.await(timeoutMs + 20_000, TimeUnit.MILLISECONDS)
        return result ?: ExecutionResult(
            exitCode = -1, stdout = out.toString(), stderr = "超时",
            durationMillis = timeoutMs, timedOut = true, cancelled = false,
            truncated = false, channelType = ChannelType.NORMAL.ordinal,
        )
    }

    companion object {
        const val GRADLE_ARCHIVE = "gradle-8.14.2-bin.zip"
    }
}
