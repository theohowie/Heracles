/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * 设备侧验证：把 **JDK 17 + Gradle** 装进 rootfs，并在**沙箱内**跑起来。
 *
 * ============================================================================
 * 这个用例证明什么、不证明什么
 * ============================================================================
 * 证明：
 *   - 190 MB 的 JDK tar.gz 与 130 MB 的 Gradle zip 能被离线装进 rootfs
 *   - 单层顶层目录会被正确上提（`jdk-17.x/bin` → `/opt/ja/bin`）
 *   - `java -version` / `gradle --version` 在 **PRoot guest 内** 执行成功
 *
 * 不证明：
 *   - 能跑完整的 `gradle assembleDebug`（还需要 android.jar、AGP 依赖、
 *     Gradle 插件下载等，属于另一个量级的验证）
 *
 * ★ 归档从**外部 files 目录**读（宿主用 adb push 推上去），
 *   目的是避免在设备上重新下载 320 MB —— 也顺便验证了
 *   `installFromLocalArchive`（离线安装）这条路径。
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
class BuildSuiteJvmTest {

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val TAG = "BuildSuiteJvmTest"

    @Test
    fun jdkAndGradle_runInsideSandbox() {
        val facade = SandboxFacade(context)
        assertTrue("需要 rootfs", runBlocking { facade.ensureRootfs() })
        val rootfsRoot = facade.rootfsHostRoot()!!

        // ---- 找归档（宿主 push 到外部 files 目录）----
        val extDir = context.getExternalFilesDir(null)
        val jdkArchive = File(extDir, JDK_ARCHIVE)
        val gradleArchive = File(extDir, GRADLE_ARCHIVE)
        logI("extDir=${extDir?.absolutePath}")
        logI("jdk=${jdkArchive.absolutePath} exists=${jdkArchive.isFile} size=${if (jdkArchive.isFile) jdkArchive.length() else -1}")
        logI("gradle=${gradleArchive.absolutePath} exists=${gradleArchive.isFile} size=${if (gradleArchive.isFile) gradleArchive.length() else -1}")

        // 归档没推上来就跳过（不伪造通过）
        assumeTrue("需要先把 JDK/Gradle 归档 push 到 ${extDir?.absolutePath}", jdkArchive.isFile && gradleArchive.isFile)

        val installer = BuildSuiteInstaller(rootfsRoot)

        // ---- 装 JDK ----
        val jdk = runBlocking {
            installer.installFromLocalArchive(BuildSuiteCatalog.JDK17, jdkArchive) { d, t, s ->
                logI("jdk: $s ($d/$t)")
            }
        }
        logI("jdk install: success=${jdk.success} msg=${jdk.message}")
        assertTrue("JDK 必须装成功：${jdk.message}", jdk.success)

        // ---- 装 Gradle ----
        val gradle = runBlocking {
            installer.installFromLocalArchive(BuildSuiteCatalog.GRADLE, gradleArchive) { d, t, s ->
                logI("gradle: $s ($d/$t)")
            }
        }
        logI("gradle install: success=${gradle.success} msg=${gradle.message}")
        assertTrue("Gradle 必须装成功：${gradle.message}", gradle.success)

        // ---- 验证单层目录已上提 ----
        val jdkBin = File(rootfsRoot, "opt/ja/bin/java")
        val gradleBin = File(rootfsRoot, "opt/gradle/bin/gradle")
        logI("host view: jdkBin=${jdkBin.isFile} gradleBin=${gradleBin.isFile}")
        assertTrue("JDK 应被上提到 /opt/ja/bin/java（实际不存在）", jdkBin.isFile)
        assertTrue("Gradle 应被上提到 /opt/gradle/bin/gradle（实际不存在）", gradleBin.isFile)

        // ---- 沙箱内执行 java -version ----
        val java = runCommand(facade, ToolchainLayout.envPrelude() + "java -version 2>&1", 180_000)
        logI("sandbox java -version: exit=${java.exitCode} out=[${java.stdout.trim()}] err=[${java.stderr.trim()}]")
        assertEquals("java 应在沙箱内可执行（stderr=${java.stderr}）", 0, java.exitCode)
        assertTrue(
            "java -version 应输出版本号，实际=${java.stdout}",
            java.stdout.contains("openjdk version") || java.stdout.contains("OpenJDK"),
        )

        // ---- 沙箱内执行 gradle --version ----
        val gv = runCommand(facade, ToolchainLayout.envPrelude() + "gradle --version 2>&1", 600_000)
        logI("sandbox gradle --version: exit=${gv.exitCode} out=[${gv.stdout.trim().take(600)}]")
        assertEquals("gradle 应在沙箱内可执行（stderr=${gv.stderr}）", 0, gv.exitCode)
        assertTrue(
            "gradle --version 应输出 Gradle 版本，实际=${gv.stdout}",
            gv.stdout.contains("Gradle 8."),
        )

        // ---- 确认真的在沙箱里：java 的路径必须是 guest 路径 ----
        val which = runCommand(facade, ToolchainLayout.envPrelude() + "command -v java")
        logI("sandbox which java = [${which.stdout.trim()}]")
        assertTrue(
            "java 必须来自 rootfs 的 /opt/ja（实际=${which.stdout.trim()}）",
            which.stdout.contains("/opt/ja/"),
        )
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
        latch.await(timeoutMs + 15_000, TimeUnit.MILLISECONDS)
        return result ?: ExecutionResult(
            exitCode = -1, stdout = out.toString(), stderr = "超时",
            durationMillis = timeoutMs, timedOut = true, cancelled = false,
            truncated = false, channelType = ChannelType.NORMAL.ordinal,
        )
    }

    companion object {
        const val JDK_ARCHIVE = "jdk17-aarch64-linux.tar.gz"
        const val GRADLE_ARCHIVE = "gradle-8.14.2-bin.zip"
    }
}
