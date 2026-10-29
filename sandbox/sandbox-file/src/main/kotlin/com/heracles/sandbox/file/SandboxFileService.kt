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
 *   原文件：app/src/main/kotlin/b/ai/exec/FileOps.kt
 *           - readJava()：流式只读前 READ_BYTES（400_000）字节，不整个拉进内存
 *           - 二进制探测：前 4096 字节里有 0x00 就当二进制
 *           - writeJava()：先 mkdirs 再 writeText
 *           - real(route, path)：ZERO_WIDTH 时先 Router.map(path)
 *
 * 本文件是 `ISandboxService.readFile/writeFile` 的**实现**（宿主视角）。
 * 错误统一走 `SandboxException` 的错误码（见 [toFailure]），
 * 因为错误码是契约的一部分 —— 宿主按码分支比按文案匹配稳。
 */

package com.heracles.sandbox.file

import com.heracles.sandbox.api.FileResult
import com.heracles.sandbox.api.MountReadOnlyException
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.io.IOException

/**
 * 沙箱的文件读写服务：`readFile` / `writeFile` 的真实实现。
 *
 * ============================================================================
 * 三件事，界线分明
 * ============================================================================
 * 1. **路径语义**：由注入的 [PathSemantics] 决定「这个字符串是宿主视角还是沙箱视角」。
 *    本类自己**不做任何路径拼接** —— 那是 PathSemantics 的唯一职责。
 * 2. **零宽穿透**：只有 `PathView.HOST` 且路径落在 `Android/data` / `Android/obb`
 *    下时才由 [ZeroWidthFileChannel] 变换。其余路径一律原样访问。
 * 3. **IO 与错误码**：读写失败统一映射成 [SandboxException] 的错误码，
 *    再包成 [FileResult]（跨进程时不能在异常上带错误码）。
 *
 * **不做的事**：不做权限决策、不弹窗、不引导用户去系统设置。
 * 缺权限就是缺权限，如实报 `CODE_IO` 还是 `CODE_CHANNEL_UNAVAILABLE` 由事实决定。
 *
 * ============================================================================
 * 线程
 * ============================================================================
 * 所有方法都会做磁盘 IO，**不得在主线程调用**。
 * AIDL 的 binder 线程池调用是合适的；`SandboxFileProvider` 也在 binder 线程上调。
 */
class SandboxFileService(
    /** 路径语义（宿主 ↔ 沙箱）。 */
    private val pathSemantics: PathSemantics,
    /** 零宽通道；传 null 表示不启用零宽穿透（只有原生路径）。 */
    private val zeroWidth: ZeroWidthFileChannel? = null,
    /**
     * 命名挂载解析器；传 null 表示不启用 `@name/...`（行为与引入挂载层之前完全一致）。
     *
     * 解析顺序：**先 MountResolver（逻辑名 → 物理/SAF），再 PathSemantics（物理 → 两套视图）**。
     * 反过来会把两级语义糊在一起，`@name` 就再也拆不出去了。
     */
    private val mountResolver: MountResolver? = null,
) {

    // ── 读 ──────────────────────────────────────────────────────────────

    /**
     * 读文件（AIDL 入口形态：路径 + pathView）。
     *
     * @param path     调用方给的路径，按 [view] 语义解读
     * @param view     [PathView.HOST] 或 [PathView.SANDBOX]
     * @param maxBytes 最多读多少字节；`<= 0` 表示用默认 [DEFAULT_MAX_READ_BYTES]
     */
    fun read(path: String, view: PathView, maxBytes: Long = 0L): FileResult = try {
        when (val mount = mountResolver?.resolve(path, forWrite = false)) {
            null, is ResolvedMount.Plain -> {
                // 不带 @ 前缀（或未启用挂载层）：走原有两套物理语义，行为完全不变
                val raw = (mount as? ResolvedMount.Plain)?.raw ?: path
                readResolved(pathSemantics.resolveForFileIo(raw, view), maxBytes)
            }
            is ResolvedMount.Physical -> {
                // 命名路径解析成物理路径后，仍然交给 PathSemantics 做第二级（HOST 视图）
                readResolved(pathSemantics.resolveForFileIo(mount.hostPath, PathView.HOST), maxBytes)
            }
            is ResolvedMount.Saf -> readSaf(mount, path, maxBytes)
        }
    } catch (e: MountReadOnlyException) {
        failure(path, view, e)
    } catch (e: SandboxException) {
        failure(path, view, e)
    } catch (t: Throwable) {
        failure(path, view, SandboxException(SandboxException.CODE_INTERNAL, describe(t), t))
    }

    /**
     * 读文件（类型安全入口）。
     *
     * <p>宿主侧的便利重载：直接给 [HostPath] 或 [SandboxPath]，
     * 编译器就不会让你把两者搞混。
     */
    fun readHost(path: HostPath, maxBytes: Long = 0L): FileResult =
        read(path.value, PathView.HOST, maxBytes)

    /** 读沙箱路径（内部先换宿主路径）。 */
    fun readSandbox(path: SandboxPath, maxBytes: Long = 0L): FileResult =
        read(path.value, PathView.SANDBOX, maxBytes)

    // ── 写 ──────────────────────────────────────────────────────────────

    /**
     * 写文件（AIDL 入口形态）。
     *
     * @param path 调用方给的路径，按 [view] 语义解读
     * @param data 要写入的字节
     * @param view [PathView.HOST] 或 [PathView.SANDBOX]
     */
    fun write(path: String, data: ByteArray, view: PathView): FileResult = try {
        when (val mount = mountResolver?.resolve(path, forWrite = true)) {
            null, is ResolvedMount.Plain -> {
                val raw = (mount as? ResolvedMount.Plain)?.raw ?: path
                writeResolved(pathSemantics.resolveForFileIo(raw, view), data)
            }
            is ResolvedMount.Physical ->
                writeResolved(pathSemantics.resolveForFileIo(mount.hostPath, PathView.HOST), data)
            is ResolvedMount.Saf -> writeSaf(mount, path, data)
        }
    } catch (e: MountReadOnlyException) {
        // ★ 只读挂载点的写入由**宿主侧**直接拒绝，不进 PRoot 靠文件权限兜底
        failure(path, view, e)
    } catch (e: SandboxException) {
        failure(path, view, e)
    } catch (t: Throwable) {
        failure(path, view, SandboxException(SandboxException.CODE_INTERNAL, describe(t), t))
    }

    /** 写文本（UTF-8）的便利重载。 */
    fun writeText(path: String, text: String, view: PathView): FileResult =
        write(path, text.toByteArray(Charsets.UTF_8), view)

    /** 写宿主路径（类型安全）。 */
    fun writeHost(path: HostPath, data: ByteArray): FileResult =
        write(path.value, data, PathView.HOST)

    /** 写沙箱路径（类型安全）。 */
    fun writeSandbox(path: SandboxPath, data: ByteArray): FileResult =
        write(path.value, data, PathView.SANDBOX)

    // ── SAF（命名挂载的第三种后端）─────────────────────────────────────

    /**
     * 通过 SAF 读（**不转物理路径**）。
     *
     * SAF 的 document URI 没有稳定的物理映射，硬转成 `file://` 在 Android 16+
     * 会被直接拒绝。所以这里直接用 `ContentResolver` 那条路。
     */
    private fun readSaf(mount: ResolvedMount.Saf, requestedPath: String, maxBytes: Long): FileResult {
        val limit = if (maxBytes > 0) maxBytes else DEFAULT_MAX_READ_BYTES
        val bytes = mount.io.read(mount.entry.treeUri, mount.relativePath, limit)
            ?: return failResult(
                path = requestedPath,
                view = PathView.HOST.wireValue,
                code = SandboxException.CODE_IO,
                message = "SAF 文档不存在：${mount.entry.prefix}/${mount.relativePath}",
            )
        return FileResult(
            success = true,
            path = requestedPath,
            data = bytes,
            size = bytes.size.toLong(),
            lastModified = 0L,
            pathView = PathView.HOST.wireValue,
            errorCode = 0,
            errorMessage = "",
        )
    }

    /** 通过 SAF 写（只读检查已在 [MountResolver] 里做过，这里只管写）。 */
    private fun writeSaf(mount: ResolvedMount.Saf, requestedPath: String, data: ByteArray): FileResult {
        val ok = mount.io.write(mount.entry.treeUri, mount.relativePath, data)
        return if (ok) {
            FileResult(
                success = true,
                path = requestedPath,
                data = null,
                size = data.size.toLong(),
                lastModified = System.currentTimeMillis(),
                pathView = PathView.HOST.wireValue,
                errorCode = 0,
                errorMessage = "",
            )
        } else {
            failResult(
                path = requestedPath,
                view = PathView.HOST.wireValue,
                code = SandboxException.CODE_IO,
                message = "SAF 写入失败：${mount.entry.prefix}/${mount.relativePath}",
            )
        }
    }

    // ── 实现 ────────────────────────────────────────────────────────────

    private fun readResolved(resolved: PathSemantics.ResolvedPath, maxBytes: Long): FileResult {
        val actual = accessPathOf(resolved)
        val file = File(actual.value)
        val reported = resolved.reportedPath
        val viewWire = resolved.view.wireValue

        if (!file.exists()) {
            // 「不存在」与「读不到」必须分开报：前者是 CODE_IO，后者也是 CODE_IO，
            // 但文案不同 —— 而「路径不合法」才是 INVALID_ARGUMENT（已在解析阶段拦掉）。
            return failResult(
                path = reported,
                view = viewWire,
                code = SandboxException.CODE_IO,
                message = if (file.parentFile?.exists() == false) {
                    "父目录不存在：${actual.value}"
                } else {
                    "文件不存在：$reported（实际访问 ${actual.value}）"
                },
            )
        }
        if (file.isDirectory) {
            return failResult(
                path = reported,
                view = viewWire,
                code = SandboxException.CODE_INVALID_ARGUMENT,
                message = "这是一个目录，不是文件：$reported（列目录请用 list，本接口只读文件）",
            )
        }

        val limit = if (maxBytes > 0) maxBytes else DEFAULT_MAX_READ_BYTES
        val totalSize = file.length()

        val bytes = try {
            // 流式读前 limit 字节：上游 FileOps 的教训 —— readBytes() 会把整个文件
            // 拉进内存，大日志直接 OOM。这里只读到上限为止。
            file.inputStream().use { input ->
                readAtMost(input, limit)
            }
        } catch (e: IOException) {
            // 典型：/storage/emulated/0/Android/data/<别的包> 被 FUSE 拒绝（EACCES）。
            return failResult(
                path = reported,
                view = viewWire,
                code = SandboxException.CODE_IO,
                message = "读取失败：${describe(e)}（路径 $reported" +
                    "；若目标是其它 App 的 Android/data，需要零宽通道或「所有文件访问」）",
            )
        }

        return FileResult(
            success = true,
            path = reported,
            data = bytes,
            // size 报**文件真实大小**，不是本次读到的字节数：调用方据此判断是否被截断。
            size = totalSize,
            lastModified = file.lastModified(),
            pathView = viewWire,
            errorCode = 0,
            errorMessage = "",
        )
    }

    private fun writeResolved(resolved: PathSemantics.ResolvedPath, data: ByteArray): FileResult {
        val actual = accessPathOf(resolved)
        val file = File(actual.value)
        val reported = resolved.reportedPath
        val viewWire = resolved.view.wireValue

        if (file.isDirectory) {
            return failResult(
                path = reported,
                view = viewWire,
                code = SandboxException.CODE_INVALID_ARGUMENT,
                message = "目标是一个目录，不能写入文件：$reported",
            )
        }

        try {
            // 上游 writeJava：先 mkdirs 再写。这里保留同样的行为（父目录不存在就建）。
            file.parentFile?.mkdirs()
            file.outputStream().use { it.write(data) }
        } catch (e: IOException) {
            return failResult(
                path = reported,
                view = viewWire,
                code = SandboxException.CODE_IO,
                message = "写入失败：${describe(e)}（路径 $reported" +
                    "；若目标是其它 App 的 Android/data，需要零宽通道或「所有文件访问」）",
            )
        } catch (e: SecurityException) {
            return failResult(
                path = reported,
                view = viewWire,
                code = SandboxException.CODE_IO,
                message = "写入被拒绝：${describe(e)}（路径 $reported；Unix 权限或 SELinux 限制）",
            )
        }

        return FileResult(
            success = true,
            path = reported,
            data = null,
            size = data.size.toLong(),
            lastModified = file.lastModified(),
            pathView = viewWire,
            errorCode = 0,
            errorMessage = "",
        )
    }

    /**
     * 得到「实际要打开的宿主路径」。
     *
     * <p>两条规则的叠放顺序很重要：
     * 1. 沙箱视角已经由 [PathSemantics] 换算成宿主路径了（此时零宽**不适用**，
     *    因为零宽是 FUSE 特性，而 rootfs 目录是 App 私有区，本来就可读写）；
     * 2. 只有 HOST 视角、且落在 `Android/data` / `Android/obb` 时，
     *    才让 [ZeroWidthFileChannel] 做变换。
     *
     * 顺序反过来（先零宽再映射）会把 `\u200b` 塞进 rootfs 的路径里，
     * 变成一个谁也打不开的文件名。
     */
    private fun accessPathOf(resolved: PathSemantics.ResolvedPath): HostPath {
        val channel = zeroWidth ?: return resolved.host
        if (!ZeroWidthFileChannel.appliesTo(resolved.view, resolved.host.value)) {
            return resolved.host
        }
        return try {
            channel.mapForAccess(resolved.host)
        } catch (e: SandboxException) {
            // 探测结论是「不支持」时 mapForAccess 会原样返回，真正走到这里的
            // 只可能是实现改动带来的意外；退回原路径让读写报真实的 IO 错误。
            resolved.host
        }
    }

    /** 流式读至多 [limit] 字节。 */
    private fun readAtMost(input: java.io.InputStream, limit: Long): ByteArray {
        val cap = limit.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
        val buffer = ByteArray(cap)
        var total = 0
        while (total < cap) {
            val n = input.read(buffer, total, cap - total)
            if (n <= 0) break
            total += n
        }
        return if (total == cap) buffer else buffer.copyOf(total)
    }

    private fun failure(path: String, view: PathView, e: SandboxException): FileResult =
        failResult(path = path, view = view.wireValue, code = e.code, message = e.message.orEmpty())

    private fun failResult(path: String, view: Int, code: Int, message: String): FileResult = FileResult(
        success = false,
        path = path,
        data = null,
        size = -1L,
        lastModified = 0L,
        pathView = view,
        errorCode = code,
        errorMessage = message.ifBlank { "未知错误" },
    )

    private fun describe(t: Throwable): String =
        "${t.javaClass.simpleName}${t.message?.let { ": $it" }.orEmpty()}"

    companion object {
        /**
         * 默认单次读取上限：400_000 字节。
         *
         * <p>与上游 FileOps.READ_BYTES 同值。**这是「读多少」的上限，不是「文件多大」的
         * 限制**：`FileResult.size` 报的仍是真实大小，调用方可据此分段续读。
         */
        const val DEFAULT_MAX_READ_BYTES: Long = 400_000L

        /** 超过这个大小就认为是二进制（前 4096 字节里有 0x00）。与上游同款判据。 */
        const val BINARY_SNIFF_BYTES: Int = 4096

        /** 内容是否是二进制（用上游的 0x00 判据）。 */
        fun looksBinary(data: ByteArray): Boolean =
            data.take(BINARY_SNIFF_BYTES).any { it == 0.toByte() }
    }
}
