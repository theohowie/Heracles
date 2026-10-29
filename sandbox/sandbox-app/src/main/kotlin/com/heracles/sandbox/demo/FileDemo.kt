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
import com.heracles.sandbox.api.FileResult
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.file.HostPath
import com.heracles.sandbox.file.PathSemantics
import com.heracles.sandbox.file.SandboxFileService
import com.heracles.sandbox.file.SandboxPath
import com.heracles.sandbox.file.ZeroWidthFileChannel
import com.heracles.sandbox.runtime.RootfsManager
import java.io.File

/**
 * 「读写文件 + 零宽通道」最小示例。
 *
 * ============================================================================
 * 这个类存在的唯一目的：把**两套路径视角**钉死
 * ============================================================================
 * 同一个字符串在两套语义下指向**不同文件**：
 *
 *   PathView.HOST    "/data/x"  → 真实 Android 文件系统 /data/x
 *                                  · 零宽通道只在此视角生效
 *                                  · 受 SELinux + DAC 限制
 *
 *   PathView.SANDBOX "/data/x"  → PRoot rootfs 内的 /data/x
 *                                  · 实际落在 {filesDir}/sandbox/rootfs/data/x
 *                                  · 沙箱内跑的命令看到的路径就是这一套
 *
 * 所以 `execute("cat /data/x")` 与 `readFile("/data/x", HOST)`
 * **可能读到不同文件**。这不是 bug，是两套语义的必然结果 ——
 * AIDL 的 `pathView` 必填就是为了逼调用方想清楚。
 *
 * `sandbox-file` 模块还提供了**类型安全**的重载（[HostPath] / [SandboxPath]），
 * 能用就用它，编译器会挡住混用。
 */
class FileDemo(context: Context) {

    private val appContext = context.applicationContext

    private val baseDir = File(appContext.filesDir, "sandbox").apply { mkdirs() }

    private val rootfs = RootfsManager(baseDir = baseDir, assets = appContext.assets)

    /** rootfs 未装时 `rootfsHostPath()` 为 null，PathSemantics 会抛 `CODE_ROOTFS_NOT_READY`。 */
    private val semantics = PathSemantics { rootfs.rootfsHostPath()?.let { HostPath.parse(it) } }

    private val files = SandboxFileService(
        pathSemantics = semantics,
        zeroWidth = ZeroWidthFileChannel(),
    )

    // ------------------------------------------------------------------

    /**
     * 演示 1：宿主视角往返。
     *
     * 用 App 自己的 `cacheDir` —— 普通 App 100% 能写，不依赖任何权限，
     * 适合当「第一条能跑通的写文件」。
     */
    fun hostRoundTrip(fileName: String = "demo-host-view.txt"): String {
        val hostPath = File(appContext.cacheDir, fileName).absolutePath
        val payload = "hello HOST @ ${System.currentTimeMillis()}"

        val w: FileResult = files.write(hostPath, payload.toByteArray(), PathView.HOST)
        if (!w.success) {
            return "写入失败: code=${w.errorCode} ${w.errorMessage}（path=${w.path}）"
        }

        val r: FileResult = files.read(hostPath, PathView.HOST)
        if (!r.success) {
            return "读取失败: code=${r.errorCode} ${r.errorMessage}（path=${r.path}）"
        }

        return buildString {
            appendLine("HOST 视角往返 ${if (r.asText() == payload) "✅ 一致" else "❌ 不一致"}")
            appendLine("  path 回显 = ${r.path}")
            appendLine("  size = ${r.size} B, lastModified = ${r.lastModified}")
            append("  content = ${r.asText()}")
        }
    }

    /**
     * 演示 2：同一个字符串，两套视角，两个文件。
     *
     * 这是本类**最重要**的演示 —— 新手最容易在这里踩坑。
     */
    fun twoViewsSameString(sandboxPath: String = "/workspace/demo-view-diff.txt"): String = buildString {
        appendLine("同一个字符串: $sandboxPath")

        // 先看沙箱视角的宿主等价路径（rootfs 未装会抛）
        val hostEquivalent = runCatching { semantics.sandboxToHost(sandboxPath) }
        hostEquivalent.fold(
            onSuccess = { appendLine("  沙箱视角 → 宿主实际路径 = $it") },
            onFailure = { appendLine("  沙箱视角换算失败（rootfs 未装？）: ${it.message}") },
        )
        appendLine("  宿主视角的同一字符串 = $sandboxPath（真实文件系统，两回事）")
        appendLine()

        // 沙箱视角写
        runCatching {
            val w = files.write(sandboxPath, "written via SANDBOX view".toByteArray(), PathView.SANDBOX)
            appendLine("  [SANDBOX] 写入 success=${w.success}，实际路径 = ${w.path}")
            if (!w.success) appendLine("            失败: code=${w.errorCode} ${w.errorMessage}")
        }.onFailure { appendLine("  [SANDBOX] 抛异常: ${it.message}") }

        // 宿主视角写同一个字符串
        runCatching {
            val w = files.write(sandboxPath, "written via HOST view".toByteArray(), PathView.HOST)
            appendLine("  [HOST]    写入 success=${w.success}，实际路径 = ${w.path}")
            if (!w.success) {
                appendLine("            失败: code=${w.errorCode} ${w.errorMessage}")
                appendLine("            （普通 App 写不了 /workspace 根下，这是**正确行为**）")
            }
        }.onFailure { appendLine("  [HOST]    抛异常: ${it.message}") }

        appendLine()
        append("结论：两个视角指向不同文件。用哪个必须显式说。")
    }

    /**
     * 演示 3：类型安全 API —— 编译器帮你挡视角误用。
     *
     * `SandboxFileService` 除了接受裸字符串 + [PathView]，还提供
     * [HostPath] / [SandboxPath] 重载。后者在编译期就阻止你把两者搞混。
     */
    fun typedApiDemo(): String = buildString {
        appendLine("类型安全 API（推荐用法）")
        val hostFile = File(appContext.cacheDir, "demo-typed.txt")
        runCatching {
            val w = files.writeHost(HostPath.parse(hostFile.absolutePath), "typed".toByteArray())
            appendLine("  writeHost: success=${w.success} size=${w.size}")
            val r = files.readHost(HostPath.parse(hostFile.absolutePath))
            appendLine("  readHost : success=${r.success} content=${r.asText()}")
        }.onFailure { appendLine("  失败: ${it.message}") }

        appendLine("  沙箱侧同理：files.writeSandbox(SandboxPath.parse(\"/workspace/x\"), bytes)")
        append("  混用 HostPath 与 SandboxPath = 编译不过 —— 这是刻意的设计。")
    }

    /**
     * 演示 4：零宽通道的**能力边界**（如实报告，不夸大）。
     *
     * 它只影响 `/storage/emulated/0/Android/{data,obb}`；
     * 读不到 `/data/data/<pkg>`（那是真私有目录，要 root/Shizuku）；
     * 绕不过 SELinux；ROM 打补丁后自动降级。
     */
    fun zeroWidthCapability(): String = buildString {
        appendLine("零宽文件通道（能力边界如实说明）")
        appendLine("  影响范围 : 仅 /storage/emulated/0/Android/{data,obb}")
        appendLine("  读不到   : /data/data/<pkg>（真私有目录，需 root/Shizuku）")
        appendLine("  绕不过   : SELinux")
        appendLine("  打补丁后 : 自动降级，不崩、不假装可用")
        appendLine()
        listOf(
            "/storage/emulated/0/Android/data",
            "/storage/emulated/0/Android/obb",
        ).forEach { target ->
            val ok = runCatching { File(target).list() != null }.getOrDefault(false)
            appendLine("  [$target] 原路径可列: ${if (ok) "是" else "否（ROM 限制或未授权）"}")
        }
        appendLine()
        append("★ 设备所有者对自己设备的工具，不是越权工具。")
    }

    /**
     * 演示 5：错误路径 —— 非法 `pathView` 明确报错，而不是"猜一个"。
     *
     * 沙箱在参数校验上「宁可报错也不猜」：猜错会写到错误文件，比报错危险得多。
     */
    fun invalidPathViewDemo(path: String): String = buildString {
        // AIDL 传进来的是裸 int，进沙箱第一件事就是 PathView.fromWire() 校验。
        // 非法值必须**明确报错**，不能猜一个默认值 —— 猜错会读写到错误的文件。
        val result = runCatching { PathView.fromWire(99) }
        val ex = result.exceptionOrNull()
        when {
            ex is SandboxException -> {
                appendLine("非法 pathView=99 → 正确抛出 SandboxException")
                appendLine("  code = ${ex.code}（期望 ${SandboxException.CODE_INVALID_ARGUMENT}）")
                appendLine("  message = ${ex.message}")
            }
            ex != null -> appendLine("抛了别的异常: ${ex::class.java.simpleName}: ${ex.message}")
            else -> appendLine("pathView=99 居然被接受了（不应该！）")
        }
        // 合法值对照
        appendLine("合法值对照: 0 → ${PathView.fromWire(0)}，1 → ${PathView.fromWire(1)}")
        append("  用合法值读 $path 成功: ${files.read(path, PathView.HOST).success}")
    }
}
