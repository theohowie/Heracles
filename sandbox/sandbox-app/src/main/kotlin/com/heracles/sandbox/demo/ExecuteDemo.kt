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
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.api.RootfsStatus
import com.heracles.sandbox.runtime.RootfsManager
import java.io.File
import kotlinx.coroutines.runBlocking

/**
 * 「装 rootfs → 执行命令」最小示例 —— **宿主最常抄的一段代码**。
 *
 * 与 [MainActivity] 分开，是因为 MainActivity 是 UI + 日志；
 * 这里是纯粹的「怎么用」，可以被任何项目直接复制。
 *
 * ```kotlin
 * val demo = ExecuteDemo(context)
 * demo.ensureRootfs { pct, msg -> println("$pct% $msg") }
 * val out = demo.run("echo hello")
 * println(out)
 * ```
 *
 * ⚠️ **这不是 AIDL 的用法**。跨进程接入见 `docs/integration-guide.md`。
 */
class ExecuteDemo(context: Context) {

    private val appContext = context.applicationContext

    private val baseDir: File = File(appContext.filesDir, "sandbox").apply { mkdirs() }

    private val rootfs: RootfsManager = RootfsManager(
        baseDir = baseDir,
        assets = appContext.assets,
    )

    // ------------------------------------------------------------------
    // rootfs：双策略
    // ------------------------------------------------------------------

    /**
     * 保证 rootfs 可用。**先内置，后 OCI**。
     *
     * 这个顺序对应任务书的双策略硬约束：用户第一次打开沙箱时多半没网，
     * 不能让他卡在「装不了 rootfs」。内置（若 APK 打包了）秒级可用；
     * OCI 需要网络但能给完整工具链。
     *
     * @return 最终生效的 [RootfsStatus]
     * @throws SandboxException 两条路都不通时抛（错误码来自具体失败原因）
     */
    fun ensureRootfs(
        ociFallback: String = DEFAULT_OCI_REF,
        onProgress: (Int, String) -> Unit = { _, _ -> },
    ): RootfsStatus {
        // 已装就直接返回，不重复下载
        val existing = rootfs.status()
        if (existing.installed) return existing

        onProgress(-1, "尝试内置 minimal rootfs（离线 fallback）…")
        val bundled = runCatching { runBlocking { rootfs.useBundledRootfs() } }.getOrNull()
        if (bundled != null && bundled.isInstalled) {
            onProgress(100, "内置 rootfs 就绪")
            return rootfs.status()
        }

        onProgress(-1, "内置不可用（本次构建未打包），改走 OCI: $ociFallback")
        return runBlocking {
            rootfs.installOci(ociFallback) { percent, message ->
                onProgress(percent, message)
            }
        }
    }

    /** 当前 rootfs 状态（一句话）。 */
    fun statusText(): String {
        val st = rootfs.status()
        return if (!st.installed) "未安装" else
            "${st.label} (source=${st.source}, ${st.sizeBytes}B, snapshots=${st.snapshotCount})"
    }

    /**
     * 快照 / 重置 —— 这是 PRoot 真正的价值所在：
     * **随便折腾，坏了能一键回到干净状态**（不是"跑恶意代码没事"，见
     * `docs/security-boundary.md`）。
     */
    fun snapshotBeforeRisky(name: String = "before-demo"): RootfsStatus =
        runBlocking { rootfs.snapshotRootfs(name) }

    fun resetToSnapshot(name: String = "before-demo"): RootfsStatus =
        runBlocking { rootfs.resetRootfs(name) }

    // ------------------------------------------------------------------
    // 执行
    // ------------------------------------------------------------------

    /**
     * 执行一条命令并返回聚合输出（阻塞）。
     *
     * demo 用；真实宿主应该用回调驱动（见 integration-guide）。
     *
     * @return 形如 `"hello\nexit=0 12ms"` 的可读文本
     */
    fun run(
        command: String,
        workingDirectory: String = "/",
        usePty: Boolean = false,
        timeoutMillis: Long = 120_000,
    ): String {
        val facade = SandboxFacade(appContext)
        if (!facade.isProotReady()) return facade.prootMissingHint()

        val sb = StringBuilder()
        val latch = java.util.concurrent.CountDownLatch(1)
        val request = ExecutionRequest(
            command = command,
            workingDirectory = workingDirectory,
            timeoutMillis = timeoutMillis,
            usePty = usePty,
        )
        facade.execute(
            request = request,
            callback = object : IExecutionCallback.Stub() {
                override fun onOutput(stream: Int, chunk: String, sequence: Long) {
                    sb.append(chunk)
                }

                override fun onProgress(percent: Int, message: String) = Unit
                override fun onExit(result: ExecutionResult) {
                    sb.append("\nexit=${result.exitCode} ${result.durationMillis}ms")
                    latch.countDown()
                }

                override fun onError(code: Int, message: String) {
                    sb.append("沙箱错误 code=$code: $message")
                    latch.countDown()
                }

                override fun isCancelled(): Boolean = false
            },
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO),
        )
        latch.await(timeoutMillis + 15_000, java.util.concurrent.TimeUnit.MILLISECONDS)
        return sb.toString().trimEnd()
    }

    companion object {
        /** Alpine：~3 MB，够跑 `sh` / `echo` / busybox。要 `aapt2` 需换镜像或装完再 `apk add`。 */
        const val DEFAULT_OCI_REF = "docker.io/library/alpine:3.20"
    }
}
