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
 * 移植来源: taixu dc7fcddb88e565929379597bbd811b440d00e34f
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/TarStreamExtractor.kt
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * 流式 tar 解包器（OCI layer 与内置 rootfs bundle 共用）。
 *
 * 「流式」的含义：不落盘成 tar 文件、不 seek、不回读 —— 一个 InputStream 从头
 * 读到尾，边读边写。OCI layer 动辄几十 MB，先解压到临时 tar 再解包会让
 * 峰值磁盘占用翻倍。
 *
 * 支持：ustar（含 prefix 字段）、GNU 长文件名（`L`/`K`）、PAX 头（`x`/`g`）、
 * 普通文件、目录、符号链接、硬链接、设备/FIFO（跳过）。
 *
 * ============================================================================
 * 为什么必须自己写
 * ============================================================================
 * `java.util.zip` / `commons-compress` 都不解决这两个问题：
 *   1. **whiteout** —— OCI 镜像用 `.wh.` 前缀的文件表示「删除下层同名文件」。
 *      不处理的话，`docker import` 出来的 rootfs 里会多出大量 `.wh.*` 垃圾，
 *      而且被上层删除的文件仍然存在（镜像语义错乱）。
 *   2. **docker layer 的符号链接是绝对路径** —— layer tar 里 `/bin/sh -> /usr/bin/dash`
 *      这种链接在解到 `{rootfs}` 目录后必须重写成**相对链接**，否则链接会指向
 *      宿主机的 `/usr/bin/dash`（宿主机上根本不存在，或者更糟：存在但对不上）。
 *
 * ============================================================================
 * 与上游 taixu TarStreamExtractor 的差异（逐条）
 * ============================================================================
 * 1. **去掉 `AppLogger` / `SafeFileTree` 依赖**（上游 import 了 core 模块）。
 *    改用可注入的 [warn] 回调 + 本文件的 [deleteTree]。
 * 2. **去掉 `AndroidFileSystemOps` 的 `NoClassDefFoundError` 兜底**
 *    （那是为了 JVM 单测环境）。本文件直接判定 `android.system.Os` 可用性，
 *    不可用时退化到 `java.nio.file.Files`。
 * 3. **`ensurePathWritable` 保留但简化**：上游向上遍历父目录逐个 chmod，
 *    这里保留原逻辑（rootfs 解包后目录可能是 0555，不 chmod 会导致下一层
 *    解包 EACCES，这是真实踩过的坑）。
 * 4. **新增「已存在且是符号链接」的强制清理**（`deleteTree` 里显式判断
 *    `isSymbolicLink` 再删）。上游有，但注释不清；这里点明原因：
 *    对符号链接调 `File.delete()` 删的是链接本身，而 `walkBottomUp` **会跟随**
 *    符号链接进去删目标 —— 那会把 rootfs 外的文件删掉。
 * 5. **不移植 `interface FileSystemOps` （只有 Android 实现）**，直接内联。
 * 6. **保留** `computeRelativeSymlink` 的免越界判断、deferred hardlink 逻辑、
 *    解包后统一给目录补 owner rwx。
 */

package com.heracles.sandbox.runtime

import android.system.Os
import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.LinkOption
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 流式 tar 解包器。
 *
 * @param warn 警告回调（不致命的解包问题：跳过越界条目、chmod 失败等）。
 *             默认什么都不做 —— 沙箱在无宿主注入时也必须能装 rootfs。
 */
class TarStreamExtractor(
    private val warn: (String, Throwable?) -> Unit = { _, _ -> },
) {

    /**
     * 把 [input] 当作 tar 流解包到 [destination]。
     *
     * @param handleWhiteouts OCI layer 必须传 true；内置 rootfs bundle 传 false
     * @throws SandboxException CODE_ROOTFS_CORRUPT: tar 结构损坏 / 条目越界
     */
    suspend fun extract(
        input: InputStream,
        destination: File,
        handleWhiteouts: Boolean,
    ) = withContext(Dispatchers.IO) {
        if (!destination.isDirectory && !destination.mkdirs() && !destination.isDirectory) {
            throw SandboxException(
                SandboxException.CODE_IO,
                "无法创建解包目标目录：${destination.absolutePath}",
            )
        }
        ensurePathWritable(destination, destination)
        val destPath = destination.toPath().toAbsolutePath().normalize()

        // GNU / PAX 的元数据条目会把真正的名字/链接名放在**前一条**记录里，
        // 所以需要把挂起状态带到下一条。
        var pendingLongName: String? = null
        var pendingLongLink: String? = null
        var pendingPax: Map<String, String> = emptyMap()
        val globalPax = mutableMapOf<String, String>()
        // 硬链接可能指向后面才出现的条目，必须延后到全部解完再建。
        val deferredHardlinks = mutableListOf<Pair<File, File>>()

        var entries = 0L
        // 看到过多少个**结构合法**的条目头（不管最终是否被应用）。
        // 用来区分「输入根本不是 tar」和「所有条目都被安全策略拒绝」——
        // 这两种情况都让 entries == 0，但错误原因完全不同，文案不能混。
        var headersSeen = 0L
        while (true) {
            val headerBytes = ByteArray(HEADER_SIZE)
            val headerRead = readFully(input, headerBytes)
            if (headerRead == 0) break
            if (headerRead < HEADER_SIZE) break // 末尾残缺：按流结束处理
            if (headerBytes.all { it == ZERO }) break // 两个全零块 = tar 结束标记

            val header = parseHeader(headerBytes)
            if (header == null) {
                warn("跳过无法解析的 tar 头块（已见 $headersSeen 个条目）", null)
                continue
            }
            headersSeen++

            // ---- 元数据条目：消耗数据、记下挂起值、继续下一条 ----
            when (header.typeFlag) {
                TYPE_LONG_NAME -> {
                    pendingLongName = readPaddedData(input, header.size)
                        .toString(StandardCharsets.UTF_8)
                        .trimEnd('\u0000')
                    continue
                }
                TYPE_LONG_LINK -> {
                    pendingLongLink = readPaddedData(input, header.size)
                        .toString(StandardCharsets.UTF_8)
                        .trimEnd('\u0000')
                    continue
                }
                TYPE_PAX -> {
                    pendingPax = parsePax(readPaddedData(input, header.size))
                    continue
                }
                TYPE_GLOBAL_PAX -> {
                    globalPax.putAll(parsePax(readPaddedData(input, header.size)))
                    continue
                }
            }

            val entryName = pendingLongName
                ?: pendingPax["path"]
                ?: globalPax["path"]
                ?: header.name
            val linkName = pendingLongLink
                ?: pendingPax["linkpath"]
                ?: globalPax["linkpath"]
                ?: header.linkName
            pendingLongName = null
            pendingLongLink = null
            pendingPax = emptyMap()

            // 规范化：统一正斜杠 → 拆段 → 去掉空段与 "." 段。
            //
            // ★ `..` 段必须**显式拒绝**，不能靠 trimStart 把它裁掉。
            //   上游写法是 `entryName.trimStart('/', '.')`，它会把
            //   "../../escaped.txt" 静默改写成 "escaped.txt" —— 结果虽然没逃出
            //   目标目录（安全上没问题），但**没有任何痕迹**：既没有告警，
            //   也不会让人知道这个 tar 里存在越界条目。对一个安全边界来说，
            //   「静默改写」比「显式拒绝」差得多（审计时看不到发生过什么）。
            val normalizedName = entryName.replace('\\', '/')
            val segments = normalizedName.split('/').filter { it.isNotEmpty() && it != "." }
            if (segments.any { it == ".." }) {
                warn("跳过越界 tar 条目（含 .. 路径段，可能是恶意或被污染的归档）：$entryName", null)
                skipPaddedData(input, header.size)
                continue
            }
            val cleanName = segments.joinToString("/")
            if (cleanName.isBlank()) {
                skipPaddedData(input, header.size)
                continue
            }

            val candidate = destPath.resolve(cleanName).normalize()
            // ★ 越界防护：`../../etc/passwd` 之类的条目必须拒绝
            if (!candidate.startsWith(destPath)) {
                warn("跳过越界 tar 条目（试图逃出目标目录）：$entryName", null)
                skipPaddedData(input, header.size)
                continue
            }
            val target = candidate.toFile()

            // ---- whiteout：OCI 的「删除下层同名文件」语义 ----
            if (handleWhiteouts) {
                val parent = target.parentFile ?: destination
                when {
                    target.name == WHITEOUT_OPAQUE -> {
                        // .wh..wh..opq = 清空本目录（上层完全不透明的目录）
                        ensurePathWritable(parent, destination)
                        parent.listFiles().orEmpty().forEach { deleteTree(it, destination) }
                        skipPaddedData(input, header.size)
                        entries++
                        continue
                    }
                    target.name.startsWith(WHITEOUT_PREFIX) -> {
                        // .wh.<name> = 删除下层同名条目
                        ensurePathWritable(parent, destination)
                        deleteTree(File(parent, target.name.removePrefix(WHITEOUT_PREFIX)), destination)
                        skipPaddedData(input, header.size)
                        entries++
                        continue
                    }
                }
            }

            when (header.typeFlag) {
                TYPE_DIRECTORY -> {
                    ensurePathWritable(target.parentFile ?: destination, destination)
                    target.mkdirs()
                    // ★ 必须保留 owner rwx（0700 底）：否则后续往同一目录解包会 EACCES。
                    //   这是真踩过的坑（cmake 里的 0555 目录导致 rootfs 装到一半失败）。
                    val safeMode = if (header.mode > 0) {
                        (header.mode and MODE_MASK) or MODE_OWNER_RWX
                    } else {
                        MODE_DIR_DEFAULT
                    }
                    applyMode(target, safeMode)
                }

                TYPE_SYMLINK -> {
                    ensurePathWritable(target.parentFile ?: destination, destination)
                    target.parentFile?.mkdirs()
                    deleteTree(target, destination)
                    // ★ docker layer 里的绝对链接必须重写成相对链接，
                    //   否则 /bin/sh -> /usr/bin/dash 会指向宿主机路径。
                    val effectiveLink = computeRelativeSymlink(destination, target, linkName)
                    try {
                        createSymlink(effectiveLink, target.absolutePath)
                    } catch (failure: Throwable) {
                        warn("创建符号链接失败，强制删除后重试：$effectiveLink -> ${target.absolutePath}", failure)
                        deleteTree(target, destination)
                        createSymlink(effectiveLink, target.absolutePath)
                    }
                }

                TYPE_HARDLINK -> {
                    ensurePathWritable(target.parentFile ?: destination, destination)
                    target.parentFile?.mkdirs()
                    // 硬链接的源路径同样要显式拒绝 `..`（理由见上面 cleanName 的注释）
                    val linkSegments = linkName.replace('\\', '/')
                        .split('/')
                        .filter { it.isNotEmpty() && it != "." }
                    if (linkSegments.any { it == ".." }) {
                        warn("跳过越界硬链接（源路径含 ..）：$linkName", null)
                        skipPaddedData(input, header.size)
                        continue
                    }
                    val cleanLink = linkSegments.joinToString("/")
                    val sourceCandidate = destPath.resolve(cleanLink).normalize()
                    if (!sourceCandidate.startsWith(destPath)) {
                        warn("跳过越界硬链接（源在目标目录外）：$linkName", null)
                        skipPaddedData(input, header.size)
                        continue
                    }
                    deferredHardlinks += target to sourceCandidate.toFile()
                }

                TYPE_REGULAR, TYPE_REGULAR_ALT -> {
                    ensurePathWritable(target.parentFile ?: destination, destination)
                    target.parentFile?.mkdirs()
                    deleteTree(target, destination)
                    target.outputStream().use { output ->
                        copyData(input, header.size, output)
                    }
                    val safeMode = if (header.mode > 0) {
                        (header.mode and MODE_MASK) or MODE_OWNER_RW
                    } else {
                        MODE_FILE_DEFAULT
                    }
                    applyMode(target, safeMode)
                }

                else -> {
                    // 设备节点 / FIFO / 未知类型：普通 App 身份建不了也用不上，跳过。
                    skipPaddedData(input, header.size)
                }
            }
            entries++
        }

        // ---- 延后的硬链接：源已全部落地，逐个建 ----
        deferredHardlinks.forEach { (target, source) ->
            if (!source.isFile) return@forEach
            ensurePathWritable(target.parentFile ?: destination, destination)
            deleteTree(target, destination)
            target.parentFile?.mkdirs()
            runCatching {
                Files.createLink(target.toPath(), source.toPath())
            }.onFailure { failure ->
                // 部分文件系统（FUSE）不支持硬链接：退化为复制。
                // 语义上这与硬链接不同（改写一份不会影响另一份），但对 rootfs
                // 解包够用 —— 且比直接失败好。
                warn("硬链接不受支持，改为复制：${source.name}", failure)
                source.copyTo(target, overwrite = true)
            }
        }

        // ---- 收尾：保证所有目录都有 owner rwx ----
        // 否则 rootfs 可能被 0555 之类的目录锁住，宿主后续读/删都会失败。
        destination.walkBottomUp().forEach { file ->
            if (file.isDirectory && !Files.isSymbolicLink(file.toPath())) {
                file.setReadable(true, true)
                file.setWritable(true, true)
                file.setExecutable(true, true)
            }
        }
        if (entries == 0L) {
            // 两种截然不同的失败，文案必须分开（否则排查时会走错方向）：
            //   headersSeen == 0  ⇒ 输入根本不是 tar（空文件 / 没解压 / 格式错）
            //   headersSeen  > 0  ⇒ 是 tar，但全部条目都被安全策略拒绝
            //                        （典型：恶意归档全是 ../ 路径）
            if (headersSeen == 0L) {
                throw SandboxException(
                    SandboxException.CODE_ROOTFS_CORRUPT,
                    "tar 流里没有任何条目（可能是空文件，或压缩格式未解压就交给了 tar 解析器）",
                )
            }
            throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "tar 共 $headersSeen 个条目，但全部被拒绝（越界路径或非法类型）；" +
                    "这个归档可能是恶意或被污染的",
            )
        }
    }

    /**
     * 把 tar 里的链接目标换算成**相对于链接所在目录**的路径。
     *
     * 例：链接在 `{dest}/bin/sh`，目标 `/usr/bin/dash`
     *     ⇒ 返回 `../usr/bin/dash`
     *
     * 只有绝对链接需要换算；相对链接原样返回（tar 里的相对链接本来就是
     * 相对链接所在目录的）。
     */
    internal fun computeRelativeSymlink(
        destination: File,
        targetFile: File,
        linkName: String,
    ): String {
        if (!linkName.startsWith("/")) return linkName
        val destPath = destination.toPath().toAbsolutePath().normalize()
        val parentDir = targetFile.parentFile ?: destination
        val parentPath = parentDir.toPath().toAbsolutePath().normalize()
        val targetInGuest = destPath.resolve(linkName.trimStart('/')).normalize()
        // 目标逃出 rootfs：链接到 rootfs 根（这个链接在 guest 内指向 / 之外，
        // 只能这样兜底；不这样做会得到一个指向宿主机绝对路径的坏链接）。
        if (!targetInGuest.startsWith(destPath)) {
            return parentPath.relativize(destPath).toString().replace('\\', '/')
        }
        return parentPath.relativize(targetInGuest).toString().replace('\\', '/')
    }

    // ------------------------------------------------------------------------
    // 文件系统操作
    // ------------------------------------------------------------------------

    /** 创建符号链接：优先用 android.system.Os（权限位与行为最贴近 Linux）。 */
    private fun createSymlink(linkTarget: String, linkPath: String) {
        try {
            Os.symlink(linkTarget, linkPath)
            return
        } catch (_: NoClassDefFoundError) {
            // JVM 单测环境（没有 android.system.Os）
        } catch (_: UnsatisfiedLinkError) {
            // 同上
        } catch (failure: Throwable) {
            // Os.symlink 在目标已存在时会抛 EEXIST —— 由调用方先 deleteTree 处理，
            // 这里仍然尝试 Files 兜底，两条路都失败才真正失败。
        }
        Files.createSymbolicLink(File(linkPath).toPath(), File(linkTarget).toPath())
    }

    /** chmod：优先 Os.chmod（保留 setuid 等位），失败退化到 File 的读写执行位。 */
    private fun applyMode(file: File, mode: Int) {
        if (mode <= 0) return
        try {
            Os.chmod(file.absolutePath, mode)
            return
        } catch (_: Throwable) {
            // 退化路径：只能表达 rwx，表达不了 setuid/setgid/sticky
        }
        val f = file
        if (mode and MODE_OWNER_READ != 0) f.setReadable(true, false)
        if (mode and MODE_OWNER_WRITE != 0) f.setWritable(true, false)
        if (mode and MODE_OWNER_EXEC != 0) f.setExecutable(true, false)
    }

    /**
     * 保证从 [file] 到 [root] 的路径都可写。
     *
     * 为什么要向上遍历：上一层的 tar 条目可能把某个父目录设成 0555，
     * 下一次解包写到它下面就会 EACCES。这里把沿途目录补成 0700。
     */
    private fun ensurePathWritable(file: File, root: File) {
        val rootParent = root.parentFile
        var current: File? = file
        while (current != null && current != rootParent) {
            if (current.exists() && !current.canWrite()) {
                current.setWritable(true, true)
                runCatching { applyMode(current, MODE_OWNER_RWX) }
            }
            current = current.parentFile
        }
    }

    /**
     * 递归删除 [file]。
     *
     * ★ 关键细节：**符号链接不是目录**。`File.isDirectory` 会跟随符号链接，
     * 于是 `walkBottomUp` 会走进链接指向的目标里删东西 —— 如果链接指向 rootfs
     * 之外（比如 `/system`），那就删掉了宿主机的文件。所以每个节点都先判
     * `Files.isSymbolicLink`。
     */
    private fun deleteTree(file: File, root: File) {
        val path = file.toPath()
        if (Files.isSymbolicLink(path)) {
            runCatching { Files.delete(path) }
            return
        }
        // 越界防护：绝不删 root 之外的路径
        val rootPath = root.toPath().toAbsolutePath().normalize()
        val absPath = path.toAbsolutePath().normalize()
        if (absPath != rootPath && !absPath.startsWith(rootPath)) {
            warn("拒绝删除目标目录之外的文件：${file.absolutePath}", null)
            return
        }
        if (file.isDirectory) {
            file.listFiles().orEmpty().forEach { child -> deleteTree(child, root) }
            runCatching { file.delete() }
        } else {
            if (file.exists() && !file.canWrite()) file.setWritable(true, true)
            runCatching { Files.deleteIfExists(path) }
        }
    }

    // ------------------------------------------------------------------------
    // tar 解析
    // ------------------------------------------------------------------------

    private fun parseHeader(bytes: ByteArray): TarHeader? {
        if (bytes.size < HEADER_SIZE) return null

        // 校验 ustar magic（offset 257，长度 5，值为 "ustar"）。
        // 不是必须的：老式 v7 tar 没有 magic，也不影响解包。
        val shortName = bytes.decodeAscii(NAME_OFFSET, NAME_LENGTH)
        val prefix = bytes.decodeAscii(PREFIX_OFFSET, PREFIX_LENGTH)
        val name = if (prefix.isBlank()) shortName else "$prefix/$shortName"
        val mode = bytes.decodeAscii(MODE_OFFSET, MODE_LENGTH).trim().toIntOrNull(8) ?: 0
        val size = bytes.decodeAscii(SIZE_OFFSET, SIZE_LENGTH).trim().toLongOrNull(8) ?: 0L
        // size 为负（base-256 编码）时按 0 处理：这种大文件在 rootfs 里不应出现。
        val safeSize = if (size < 0) 0L else size
        val typeFlag = bytes[TYPE_FLAG_OFFSET].toInt().toChar()
        val linkName = bytes.decodeAscii(LINK_NAME_OFFSET, LINK_NAME_LENGTH)

        if (name.isBlank()) return null
        return TarHeader(name, mode, safeSize, typeFlag, linkName)
    }

    /** 从定长 ASCII 字段取值（去掉尾部 NUL）。 */
    private fun ByteArray.decodeAscii(offset: Int, length: Int): String {
        val end = (offset + length).coerceAtMost(size)
        var valueEnd = end
        while (valueEnd > offset && this[valueEnd - 1] == ZERO) valueEnd--
        return String(this, offset, valueEnd - offset, StandardCharsets.US_ASCII)
    }

    /**
     * 解析 PAX 扩展头。
     *
     * 格式：`<长度> <key>=<value>\n` 重复，其中 `<长度>` 包含它自己的字节数。
     */
    private fun parsePax(bytes: ByteArray): Map<String, String> {
        val text = bytes.toString(StandardCharsets.UTF_8)
        val result = mutableMapOf<String, String>()
        var offset = 0
        while (offset < text.length) {
            val space = text.indexOf(' ', offset)
            if (space <= offset) break
            val length = text.substring(offset, space).toIntOrNull() ?: break
            if (length <= 0) break
            val end = (offset + length).coerceAtMost(text.length)
            val record = text.substring(space + 1, end).trimEnd('\n')
            val separator = record.indexOf('=')
            if (separator > 0) {
                result[record.substring(0, separator)] = record.substring(separator + 1)
            }
            offset += length
        }
        return result
    }

    // ------------------------------------------------------------------------
    // 数据搬运
    // ------------------------------------------------------------------------

    /** 把 [size] 字节从 input 搬到 output，然后跳过 padding。 */
    private fun copyData(input: InputStream, size: Long, output: OutputStream) {
        var remaining = size
        val buffer = ByteArray(BUFFER_SIZE)
        while (remaining > 0) {
            val toRead = minOf(remaining, buffer.size.toLong()).toInt()
            val read = input.read(buffer, 0, toRead)
            if (read < 0) break
            output.write(buffer, 0, read)
            remaining -= read
        }
        skipPadding(input, size)
    }

    /** 跳过 [size] 字节数据 + padding。 */
    private fun skipPaddedData(input: InputStream, size: Long) {
        var remaining = size
        val buffer = ByteArray(BUFFER_SIZE)
        while (remaining > 0) {
            val toRead = minOf(remaining, buffer.size.toLong()).toInt()
            val read = input.read(buffer, 0, toRead)
            if (read < 0) break
            remaining -= read
        }
        skipPadding(input, size)
    }

    /** 读 [size] 字节到内存（只用于元数据条目，有上限保护）。 */
    private fun readPaddedData(input: InputStream, size: Long): ByteArray {
        if (size <= 0) {
            skipPadding(input, 0)
            return ByteArray(0)
        }
        if (size > MAX_IN_MEMORY_ENTRY_SIZE) {
            throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "tar 元数据条目过大（$size 字节，上限 $MAX_IN_MEMORY_ENTRY_SIZE）：疑似损坏的 tar",
            )
        }
        val bytes = ByteArray(size.toInt())
        var offset = 0
        while (offset < bytes.size) {
            val read = input.read(bytes, offset, bytes.size - offset)
            if (read < 0) break
            offset += read
        }
        skipPadding(input, size)
        return bytes
    }

    /** tar 的每个条目都补齐到 512 字节边界。 */
    private fun skipPadding(input: InputStream, dataSize: Long) {
        val padding = ((HEADER_SIZE - (dataSize % HEADER_SIZE)) % HEADER_SIZE).toInt()
        if (padding == 0) return
        readFully(input, ByteArray(padding))
    }

    /** 尽量读满 [buffer]，返回实际读到的字节数。 */
    private fun readFully(input: InputStream, buffer: ByteArray): Int {
        var offset = 0
        while (offset < buffer.size) {
            val read = input.read(buffer, offset, buffer.size - offset)
            if (read < 0) break
            offset += read
        }
        return offset
    }

    private data class TarHeader(
        val name: String,
        val mode: Int,
        val size: Long,
        val typeFlag: Char,
        val linkName: String,
    )

    private companion object {
        const val HEADER_SIZE = 512
        const val NAME_OFFSET = 0
        const val NAME_LENGTH = 100
        const val MODE_OFFSET = 100
        const val MODE_LENGTH = 8
        const val SIZE_OFFSET = 124
        const val SIZE_LENGTH = 12
        const val TYPE_FLAG_OFFSET = 156
        const val LINK_NAME_OFFSET = 157
        const val LINK_NAME_LENGTH = 100
        const val PREFIX_OFFSET = 345
        const val PREFIX_LENGTH = 155

        const val BUFFER_SIZE = 64 * 1024
        const val MAX_IN_MEMORY_ENTRY_SIZE = 4L * 1024L * 1024L

        const val TYPE_REGULAR = '0'
        const val TYPE_REGULAR_ALT = '\u0000'
        const val TYPE_HARDLINK = '1'
        const val TYPE_SYMLINK = '2'
        const val TYPE_DIRECTORY = '5'
        const val TYPE_LONG_NAME = 'L'
        const val TYPE_LONG_LINK = 'K'
        const val TYPE_PAX = 'x'
        const val TYPE_GLOBAL_PAX = 'g'

        const val ZERO: Byte = 0

        /** OCI whiteout：`.wh.<name>` 删除同名条目，`.wh..wh..opq` 清空目录。 */
        const val WHITEOUT_PREFIX = ".wh."
        const val WHITEOUT_OPAQUE = ".wh..wh..opq"

        /** 权限位（八进制）：07777 / 0700 / 0755 / 0600 / 0644 */
        const val MODE_MASK = 0xfff
        const val MODE_OWNER_RWX = 0x1c0
        const val MODE_DIR_DEFAULT = 0x1ed
        const val MODE_OWNER_RW = 0x180
        const val MODE_FILE_DEFAULT = 0x1a4
        const val MODE_OWNER_READ = 0x100
        const val MODE_OWNER_WRITE = 0x80
        const val MODE_OWNER_EXEC = 0x40
    }
}

/** 供诊断：判断一个文件是否是符号链接而不跟随它。 */
internal fun File.isSymlinkNoFollow(): Boolean =
    runCatching { Files.isSymbolicLink(toPath()) }.getOrDefault(false)

/** 供诊断：不跟随符号链接地判断是否目录。 */
internal fun File.isDirectoryNoFollow(): Boolean =
    runCatching { Files.isDirectory(toPath(), LinkOption.NOFOLLOW_LINKS) }.getOrDefault(false)
