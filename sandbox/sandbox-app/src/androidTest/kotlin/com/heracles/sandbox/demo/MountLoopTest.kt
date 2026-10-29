/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * 设备侧闭环验证：命名挂载层（MountRegistry）。
 *
 * ============================================================================
 * 验收要求（任务书第七节第 3 条）
 * ============================================================================
 * 1. 注册 @workspace（ROOTFS_RELATIVE，读写）
 * 2. 注册 @libs（HOST_PRIVATE_DIR，只读）
 * 3. 注册一个 SAF_TREE 挂载点
 * 4. writeFile("@libs/x") 被拒绝
 * 5. writeFile("@workspace/x") 成功
 * 6. execute("cat @workspace/x") 能在 PRoot 内读到内容
 *
 * 关于第 3 条：真机上拿 `ACTION_OPEN_DOCUMENT_TREE` 需要用户点选，
 * 自动化测试没法点。所以这里**用测试专用 SAF 实现**验证 `SAF_TREE` 分支
 * 的读写与只读拒绝；真实 `DocumentsContract` 实现见 `AndroidSafDocumentIo`
 * （它需要用户授权，属宿主交互流程，不在自动化范围）。
 * **这一点会在结论里如实说明，不假装测过真 SAF 授权。**
 */

package com.heracles.sandbox.demo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.api.MountBackend
import com.heracles.sandbox.api.MountEntry
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.file.SafDocumentIo
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MountLoopTest {

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val TAG = "MountLoopTest"

    /** 测试专用 SAF：内存存储，证明 SAF 分支不走文件系统。 */
    private class InMemorySaf : SafDocumentIo {
        val store = mutableMapOf<Pair<String, String>, ByteArray>()
        var writes = 0
        override fun read(treeUri: String, relativePath: String, maxBytes: Long): ByteArray? =
            store[treeUri to relativePath]
        override fun write(treeUri: String, relativePath: String, data: ByteArray): Boolean {
            writes++
            store[treeUri to relativePath] = data
            return true
        }
        override fun exists(treeUri: String, relativePath: String) =
            store.containsKey(treeUri to relativePath)
    }

    @Test
    fun mountRegistry_loopInsideSandbox() {
        val facade = SandboxFacade(context)
        assertTrue("需要 rootfs", runBlocking { facade.ensureRootfs() })
        val rootfs = facade.rootfsHostRoot()!!
        val saf = InMemorySaf()

        // 用独立的 registry/resolver，避免污染 facade 的默认配置
        val registry = com.heracles.sandbox.file.MountRegistry { rootfs.absolutePath }
        val resolver = com.heracles.sandbox.file.MountResolver(registry, saf)

        // ---- 1/2/3：注册三个挂载点 ----
        // ⚠️ hostPath 用 "opt/ws" 而不是 "workspace"：
        //    guest 的 `/workspace` 是 bind 挂载（宿主 workspaces 目录），
        //    用它会**盖住** rootfs 内的同名目录，命令里读到的是另一个目录。
        //    `opt/ws` 不在任何标准 bind 覆盖区内，文件 IO 与 guest 路径是同一处。
        registry.register(
            MountEntry(
                name = "workspace", backend = MountBackend.ROOTFS_RELATIVE,
                hostPath = "opt/ws", description = "工作区（读写）",
            ),
        )
        val libsDir = File(context.filesDir, "libs").apply { mkdirs() }
        registry.register(
            MountEntry(
                name = "libs", backend = MountBackend.HOST_PRIVATE_DIR,
                hostPath = libsDir.absolutePath, readOnly = true,
                description = "共享库（只读）",
            ),
        )
        registry.register(
            MountEntry(
                name = "pc_shared", backend = MountBackend.SAF_TREE,
                treeUri = "content://test/tree/pc", description = "电脑共享（SAF）",
            ),
        )
        logI("registered=${registry.list().map { it.prefix }}")

        // 用临时文件服务（不复用 facade.files，保持本用例自洽）
        val files = com.heracles.sandbox.file.SandboxFileService(
            pathSemantics = com.heracles.sandbox.file.PathSemantics {
                com.heracles.sandbox.file.HostPath.parse(rootfs.absolutePath)
            },
            zeroWidth = null,
            mountResolver = resolver,
        )

        // ---- 4：只读挂载点写入被拒 ----
        val denied = files.write("@libs/x.so", "nope".toByteArray(), PathView.HOST)
        logI("write @libs/x.so → success=${denied.success} code=${denied.errorCode} msg=${denied.errorMessage}")
        assertFalse("只读挂载点写入必须失败", denied.success)
        assertEquals(
            "必须是可区分的只读错误码",
            SandboxException.CODE_MOUNT_READ_ONLY, denied.errorCode,
        )

        // ---- 5：可写挂载点写入成功 ----
        File(rootfs, "opt/ws").mkdirs()
        val payload = "mounted-${System.currentTimeMillis()}"
        val ok = files.write("@workspace/x.txt", payload.toByteArray(), PathView.HOST)
        logI("write @workspace/x.txt → success=${ok.success} msg=${ok.errorMessage}")
        assertTrue("可写挂载点写入应成功：${ok.errorMessage}", ok.success)

        // 读回（宿主侧）
        val back = files.read("@workspace/x.txt", PathView.HOST)
        assertTrue("读回应成功", back.success)
        assertEquals(payload, back.asText())

        // ---- SAF 分支（用测试实现）----
        val safWrite = files.write("@pc_shared/docs/a.txt", "saf-data".toByteArray(), PathView.HOST)
        logI("write @pc_shared/docs/a.txt → success=${safWrite.success} safWrites=${saf.writes}")
        assertTrue("SAF 写入应成功：${safWrite.errorMessage}", safWrite.success)
        assertEquals("必须走 SAF API", 1, saf.writes)

        val safRead = files.read("@pc_shared/docs/a.txt", PathView.HOST)
        assertTrue("SAF 读取应成功", safRead.success)
        assertEquals("saf-data", safRead.asText())

        // ---- 6：execute 里的 @name 必须在 PRoot 内解析 ----
        // 注意：这里用 facade（它的 core 已注入 mountResolver 和同一个 rootfs），
        // 所以要把挂载点注册到 facade 自己的 registry 上，@name 才能被解析。
        facade.mounts.register(
            MountEntry(
                name = "workspace", backend = MountBackend.ROOTFS_RELATIVE,
                hostPath = "opt/ws",
            ),
        )
        val cat = runCommand(facade, "cat @workspace/x.txt")
        logI("execute cat @workspace/x.txt → exit=${cat.exitCode} stdout=[${cat.stdout.trim()}]")
        assertEquals("execute 的退出码", 0, cat.exitCode)
        assertTrue(
            "PRoot 内应读到挂载文件内容，实际=[${cat.stdout}]",
            cat.stdout.contains(payload),
        )

        // ---- 未注册的 @name 在命令里必须报错，不能原样进 shell ----
        val bad = runCommand(facade, "cat @nope/x.txt")
        logI("execute cat @nope/x.txt → exit=${bad.exitCode} output=[${(bad.stdout + bad.stderr).trim().take(200)}]")
        assertTrue("未注册挂载点应报错（非 0 退出）", bad.exitCode != 0)
    }

    // ------------------------------------------------------------------

    private fun logI(msg: String) = android.util.Log.i(TAG, msg)

    private fun runCommand(
        facade: SandboxFacade,
        command: String,
        timeoutMs: Long = 120_000,
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
}
