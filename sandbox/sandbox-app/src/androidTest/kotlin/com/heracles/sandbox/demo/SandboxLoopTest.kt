/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * 设备侧验证：**rootfs 内**构建套件（linux-aarch64）能不能真的跑。
 *
 * 这个用例验证的是「沙箱内执行」这条路径，不是宿主进程：
 *   1. 装 rootfs
 *   2. 把 linux-aarch64 的 aapt2/aidl/zipalign 装进 rootfs 的 /opt/as
 *   3. 用 ISandboxService 等价的进程内路径 execute("aapt2 version")
 *   4. 断言 stdout 里出现真实版本号，且 exitCode == 0
 *
 * ★ 关键：断言必须能区分「在 rootfs 里跑通」与「宿主进程跑通」。
 *   所以额外断言 `readlink /proc/self/exe` 或 PATH 里是 /opt/as/...，
 *   并且用 rootfs 内独有的文件做交叉验证。
 */

package com.heracles.sandbox.demo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.runtime.BuildSuiteCatalog
import com.heracles.sandbox.runtime.BuildSuiteInstaller
import com.heracles.sandbox.runtime.ToolchainLayout
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SandboxLoopTest {

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val TAG = "SandboxLoopTest"

    /**
     * ① 沙箱最小闭环：装 rootfs → 执行 → 读写 → 查通道。
     *
     * 不依赖任何外部工具，纯沙箱自身能力。
     */
    @Test
    fun minimumLoop_works() {
        val facade = SandboxFacade(context)

        // ---- 1. rootfs ----
        val bundled = runBlocking { facade.ensureRootfs() }
        assertTrue("rootfs 必须可用（内置或 OCI）：$bundled", bundled)

        // ---- 2. 执行 ----
        val echo = runCommand(facade, "echo hello-sandbox")
        android.util.Log.i(TAG, "echo stdout=[${echo.stdout.trim()}] exit=${echo.exitCode}")
        assertEquals("echo 的退出码（stderr=${echo.stderr}）", 0, echo.exitCode)
        assertTrue("stdout 应含 hello-sandbox，实际=${echo.stdout}", echo.stdout.contains("hello-sandbox"))

        // ---- 3. 读写 ----
        val path = File(context.cacheDir, "loop-test.txt").absolutePath
        val payload = "loop-${System.currentTimeMillis()}"
        val w = facade.files.write(path, payload.toByteArray(), PathView.HOST)
        assertTrue("写入应成功：${w.errorMessage}", w.success)
        val r = facade.files.read(path, PathView.HOST)
        assertTrue("读取应成功：${r.errorMessage}", r.success)
        assertEquals("内容应一致", payload, r.asText())

        // ---- 4. 通道 ----
        val channels = facade.queryChannels()
        assertEquals("必须返回四条通道", 4, channels.size)
        assertEquals(
            "顺序必须是 NORMAL/SHIZUKU/ROOT/WIRELESS_ADB",
            listOf(
                ChannelType.NORMAL.ordinal,
                ChannelType.SHIZUKU.ordinal,
                ChannelType.ROOT.ordinal,
                ChannelType.WIRELESS_ADB.ordinal,
            ),
            channels.map { it.type },
        )
        assertTrue("NORMAL 必须始终可用", channels.first { it.type == ChannelType.NORMAL.ordinal }.available)
    }

    /**
     * ② **rootfs 内**装 linux-aarch64 工具链，并在沙箱内跑起来。
     *
     * 这是「构建能力放回 rootfs」的验收点。
     *
     * 只装最小的 `android-sdk-tools`（约 20 MB，aapt2/aidl/zipalign），
     * 不涉及 190 MB 的 JDK —— 用它证明「沙箱内执行」这条路是通的。
     */
    @Test
    fun buildSuiteInsideRootfs_runsInSandbox() {
        val facade = SandboxFacade(context)
        assertTrue("需要 rootfs", runBlocking { facade.ensureRootfs() })
        android.util.Log.i(TAG, "DIAG prootReady=" + facade.isProotReady())
        android.util.Log.i(TAG, "DIAG " + facade.rootfsSummary())

        val rootfsRoot = facade.rootfsHostRoot()!!
        val installer = BuildSuiteInstaller(rootfsRoot)

        // ---- 装最小组件（在线；失败就如实失败，不退回宿主兜底）----
        val result = runBlocking {
            installer.install(BuildSuiteCatalog.ANDROID_SDK_TOOLS) { done, total, stage ->
                // 只在关键阶段打印，避免刷屏
                if (stage != "下载中") println("install: $stage ($done/$total)")
            }
        }
        android.util.Log.i(TAG, "install result: success=${result.success} msg=${result.message}")
        println("install result: success=${result.success} msg=${result.message}")
        assertTrue("安装必须成功（失败就是失败，不做宿主兜底）：${result.message}", result.success)

        val optDir = File(rootfsRoot, "opt/as")
        assertTrue("目标目录应存在：${optDir.absolutePath}", optDir.isDirectory)

        // ---- 在沙箱内执行（关键）----
        // 先确认工具确实在 rootfs 里，而不是宿主上
        val which = runCommand(facade, "${ToolchainLayout.envPrelude()}command -v aapt2")
        android.util.Log.i(TAG, "sandbox which aapt2 = [${which.stdout.trim()}] exit=${which.exitCode}")
        println("sandbox which aapt2 = ${which.stdout.trim()}")
        assertEquals("command -v aapt2 退出码（stderr=${which.stderr} stdout=${which.stdout}）", 0, which.exitCode)
        assertTrue(
            "aapt2 必须来自 rootfs 内的 /opt/as（实际=${which.stdout.trim()}）",
            which.stdout.contains("/opt/as/"),
        )

        // 真正执行 aapt2
        val ver = runCommand(facade, "${ToolchainLayout.envPrelude()}aapt2 version 2>&1")
        android.util.Log.i(TAG, "sandbox aapt2 version = [${ver.stdout.trim()}] exit=${ver.exitCode}")
        android.util.Log.i(TAG, "sandbox aapt2 stderr = [${ver.stderr.trim()}]")
        println("sandbox aapt2 version = ${ver.stdout.trim()}")
        assertEquals("aapt2 在沙箱内应能执行（exit=${ver.exitCode}, stderr=${ver.stderr}）", 0, ver.exitCode)
        assertTrue(
            "应输出版本号，实际=${ver.stdout}",
            ver.stdout.contains("Android Asset Packaging Tool") || ver.stdout.contains("aapt"),
        )

        // ---- 交叉验证：确认它真的跑在 PRoot 里，不是宿主进程 ----
        val rootCheck = runCommand(facade, "ls /opt/as >/dev/null 2>&1 && echo IN_SANDBOX")
        assertTrue(
            "工具必须在沙箱 rootfs 的 /opt/as 下（实际=${rootCheck.stdout.trim()}）",
            rootCheck.stdout.contains("IN_SANDBOX"),
        )
    }

    // ------------------------------------------------------------------

    /** 跑一条命令并等结果（demo 用；生产宿主应该走回调驱动）。 */
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
                override fun onOutput(stream: Int, chunk: String, sequence: Long) {
                    out.append(chunk)
                }
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
        latch.await(timeoutMs + 10_000, TimeUnit.MILLISECONDS)
        return result ?: ExecutionResult(
            exitCode = -1, stdout = out.toString(), stderr = "超时",
            durationMillis = timeoutMs, timedOut = true, cancelled = false,
            truncated = false, channelType = ChannelType.NORMAL.ordinal,
        )
    }
}
