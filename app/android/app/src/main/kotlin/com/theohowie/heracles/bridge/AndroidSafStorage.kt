package com.theohowie.heracles.bridge

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.MAX_BINARY_BYTES
import dev.heracles.workspace.MAX_READ_BYTES
import dev.heracles.workspace.WorkspaceStorage
import dev.heracles.workspace.readBytesLimited
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * SAF 存储实现 —— 路线 A（2026-10-10 用户决定）。
 *
 * ## 为什么需要它
 *
 * 真机实测：用户选的文件夹属于 `media_rw` 组，而我们的 App 不在这个组：
 *
 * ```
 * /storage/emulated/0/test  drwxrws--- u0_a239 media_rw
 *   App 的组 groups=10330(u0_a330)  → 写不了
 * ```
 *
 * SAF 授权给的是 `content://` 权限 —— **能访问，但只能用 ContentResolver**。
 * 所以 `java.io.File` 那套完全用不了，必须走 `DocumentFile`。
 *
 * ## 关键设计
 *
 * [WorkspaceStorage] 接口定义在 `:workspace`（纯 JVM），
 * 本类在 `:app`（Android）实现它。
 *
 * **本类只能在真机上测** —— SAF 依赖 Android 的 ContentResolver。
 * 这是路线 A 的主要工程代价（见 `20-存储访问路线对比.md` §6）。
 */
class AndroidSafStorage(
    private val context: Context,
    private val treeUri: Uri,
    override val displayName: String,
) : WorkspaceStorage {

    override val locationLabel: String get() = treeUri.toString()

    /**
     * SAF **没有**真实文件系统根 —— 只有 `content://` URI。
     *
     * 显式声明 `null`（而不是继承默认值就完事）：任何需要绝对路径的功能
     * （进程内 ZIP / 对齐 / 拼接 shell 命令）在 SAF 上都**不可能**工作，
     * 调用方必须能一眼看到这个事实。编码层要求 POSIX 工作区 —— 见
     * `20-存储访问路线对比.md`。
     */
    override val realRootPath: java.nio.file.Path? get() = null

    private fun root(): DocumentFile? = DocumentFile.fromTreeUri(context, treeUri)

    override suspend fun isWritable(): Boolean = withContext(Dispatchers.IO) {
        val r = root() ?: return@withContext false
        if (!r.canWrite()) return@withContext false
        // 真的试一次 —— canWrite 可能漏报（实测过 java.io.File 的同类问题）
        runCatching {
            val probe = r.createDirectory(".heracles_probe") ?: return@runCatching false
            probe.delete()
            true
        }.getOrElse { false }
    }

    /**
     * 找到相对路径对应的 DocumentFile。
     *
     * `null` 表示不存在。**路径穿越在这里被结构性排除** ——
     * 因为我们是逐级 `findFile`，而不是拼字符串路径。
     */
    private fun resolve(relativePath: String): DocumentFile? {
        var cur: DocumentFile = root() ?: return null
        if (relativePath.isBlank()) return cur

        for (seg in relativePath.split('/')) {
            if (seg.isEmpty() || seg == "." || seg == "..") continue
            // ★ 与 resolveOrCreateDir 用**同一个**查找（2026-10-19）：只走 findFile
            //   会让"读得到"与"写得到"不一致 —— 读用 findFile 找到、写却找不到，
            //   症状是"文件明明在、却报不存在"。两处必须同源。
            cur = findChild(cur, seg) ?: return null
        }
        return cur
    }

    /** 找到父目录（写文件时用），不存在则逐级创建 */
    private fun resolveOrCreateDir(relativePath: String): DocumentFile? {
        var cur: DocumentFile = root() ?: return null
        if (relativePath.isBlank()) return cur

        for (seg in relativePath.split('/')) {
            if (seg.isEmpty() || seg == "." || seg == "..") continue
            val next = findChild(cur, seg)
            cur = if (next != null && next.isDirectory) {
                next
            } else {
                // ★ 建目录失败后**必须**再查一次（2026-10-19 真机事故）：
                //   DocumentsProvider 在同名目录已存在时会**自动改名**成
                //   `名字 (1)` / `名字 (2)` … 并返回成功。JS 时代踩过文件名改写
                //   （`hello.py` → `hello.py.txt`），目录也有同样的问题：
                //   真机上就出现过 33 个 `.heracles (N)` 垃圾目录。
                //   ⇒ 建完先看返回的名字是否与期望一致；不一致就**用回原名那个**，
                //     并把刚建出来的空目录删掉（它里面一定还没有东西）。
                val created = cur.createDirectory(seg)
                if (created != null && created.name != seg) {
                    runCatching { created.delete() }
                    findChild(cur, seg) ?: return null
                } else {
                    created ?: return null
                }
            }
        }
        return cur
    }

    /**
     * 在 [dir] 里按名字找子项（2026-10-19 真机事故修复）。
     *
     * ## 为什么不能只用 `DocumentFile.findFile`
     *
     * `DocumentFile.findFile(name)` 内部用 `DocumentsContract.buildDocumentUriUsingTree`
     * 按文档 id 定位，**名字必须精确命中**。真机上踩到的症状：
     * 工作区里 `.heracles` 目录明明存在（`ls -ld` 可见），但写会话记录时报
     * 「无法创建目录：.heracles」—— 因为 `findFile` 没找到 ⇒ 走 `createDirectory`
     * ⇒ 同名目录已存在 ⇒ 返回 null ⇒ 整条链路失败，**用户看到的是"运行失败"**。
     *
     * ⇒ 先 `findFile`（快路径），失败再**遍历子项做一次不区分大小写的比对**
     * （外部存储是大小写不敏感的，但 provider 返回的 display name 大小写可能不同）。
     */
    private fun findChild(dir: DocumentFile, name: String): DocumentFile? {
        dir.findFile(name)?.let { return it }
        // 慢路径：遍历比对（仅在 name 未命中时发生，代价可接受）
        return runCatching {
            dir.listFiles().firstOrNull { it.name?.equals(name, ignoreCase = true) == true }
        }.getOrNull()
    }

    override suspend fun list(relativeDir: String): List<FileEntry> =
        withContext(Dispatchers.IO) {
            val dir = resolve(relativeDir) ?: return@withContext emptyList()
            if (!dir.isDirectory) return@withContext emptyList()

            val base = relativeDir.trim('/')
            dir.listFiles()
                .filter { it.name != null }
                .map { f ->
                    FileEntry(
                        relativePath =
                            if (base.isEmpty()) f.name!! else "$base/${f.name}",
                        sizeBytes = if (f.isDirectory) 0L else f.length(),
                        isDirectory = f.isDirectory,
                    )
                }
                // 排序必须**确定性**（顺序不固定 → prompt 变动 → 缓存归零）
                .sortedWith(compareBy({ !it.isDirectory }, { it.relativePath }))
        }

    override suspend fun readText(relativePath: String): String =
        withContext(Dispatchers.IO) {
            val f = resolve(relativePath)
                ?: throw IllegalArgumentException("文件不存在：$relativePath")
            require(f.isFile) { "不是文件：$relativePath" }

            val size = f.length()
            require(size <= MAX_READ_BYTES) {
                "文件过大（${size}B > ${MAX_READ_BYTES}B）：$relativePath"
            }

            context.contentResolver.openInputStream(f.uri)?.use { ins ->
                ins.readBytes().toString(Charsets.UTF_8)
            } ?: throw IllegalStateException("无法打开：$relativePath")
        }

    /**
     * 字节读取（2026-10-18，F6a / ADR-032）—— DocumentFile 的 `InputStream` **直通**，不做解码。
     *
     * ⚠️ SAF 的 `DocumentFile.length()` 在多数 provider 上返回 **0（长度未知）**，
     * 所以**不能只靠长度校验**：真正的上限由 [readBytesLimited] 在读取过程中兜住
     * （超限抛，**不返回截断的字节**）。长度可读时先快速失败，省一次读。
     *
     * ⚠️ 本实现的单测边界：`DocumentFile`/`ContentResolver` 只能在真机上跑，
     * PC 单测覆盖的是共享的限流器 [readBytesLimited]（见 `ByteIoTest`）——
     * 这段接线本身**未在单测里验**（F6a 报告已如实标注）。
     */
    override suspend fun readBytes(relativePath: String): ByteArray =
        withContext(Dispatchers.IO) {
            val f = resolve(relativePath)
                ?: throw IllegalArgumentException("文件不存在：$relativePath")
            require(f.isFile) { "不是文件：$relativePath" }

            val size = f.length()
            require(size <= MAX_BINARY_BYTES) {
                "文件过大（${size}B > ${MAX_BINARY_BYTES}B）：$relativePath —— 二进制通道不截断"
            }
            context.contentResolver.openInputStream(f.uri)?.use { ins ->
                readBytesLimited(ins, MAX_BINARY_BYTES)
            } ?: throw IllegalStateException("无法打开：$relativePath")
        }

    /**
     * 文本写入 —— 委托 [writeBytes]（同一套"删旧建新 + 文件名改写防护 + 输出流"）。
     * 从 String 到字节只做一次 UTF-8 编码，行为与改造前**逐字节一致**。
     */
    override suspend fun writeText(relativePath: String, content: String): Long =
        writeBytes(relativePath, content.toByteArray(Charsets.UTF_8))

    /**
     * 字节写入（F6a）—— 与 [writeText] 同路，只把"内容"换成 ByteArray（不做任何编码转换）。
     *
     * ## 为什么必须保留"文件名改写防护"
     *
     * 那是 2026-10-10 真机实测换来的：`createFile("text/plain", "hello.py")` 落盘变
     * `hello.py.txt`。字节通道走的是同一个 `createFile`，所以同一套防护**必须**跟着。
     */
    override suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long =
        withContext(Dispatchers.IO) {
            require(bytes.size.toLong() <= MAX_BINARY_BYTES) {
                "写入过大（${bytes.size}B > ${MAX_BINARY_BYTES}B）：$relativePath"
            }
            val norm = relativePath.replace('\\', '/').trim('/')
            require(norm.isNotEmpty()) { "路径为空" }

            val parentRel = norm.substringBeforeLast('/', "")
            val fileName = norm.substringAfterLast('/')
            require(fileName.isNotEmpty()) { "文件名为空：$relativePath" }

            val parent = resolveOrCreateDir(parentRel)
                ?: throw IllegalStateException("无法创建目录：$parentRel")

            // 已存在则先删（DocumentFile 没有 truncate，必须删了重建）
            parent.findFile(fileName)?.let { existing ->
                if (!existing.delete()) {
                    throw IllegalStateException("无法覆盖已存在的文件：$relativePath")
                }
            }

            val created = parent.createFile(mimeOf(fileName), fileName)
                ?: throw IllegalStateException(
                    "无法创建文件：$relativePath（父目录可能不可写）"
                )

            // ★ 防御：provider 可能无视我们给的名字（自动补扩展名等）。
            //
            // 实测过 `text/plain` + `hello.py` → 磁盘上是 `hello.py.txt`。
            // 虽然 mimeOf 已改用 octet-stream 规避，但**不能假设所有
            // provider 都守规矩**（不同厂商的文件管理器实现差异很大）。
            //
            // 发现名字不符就删掉重试一次；再不行就如实报错 ——
            // 让 agent 写出的文件名与它以为的不一致，比直接失败更糟
            // （下一轮 read_file 找不到，会陷入困惑循环）。
            if (created.name != fileName) {
                val wrongName = created.name
                created.delete()
                val retry = parent.createFile("application/octet-stream", fileName)
                if (retry == null || retry.name != fileName) {
                    retry?.delete()
                    throw IllegalStateException(
                        "文件系统改写了文件名：请求 $fileName，实际 $wrongName。" +
                            "该位置不支持原样命名，请换一个文件夹。"
                    )
                }
                return@withContext writeTo(retry, bytes, relativePath)
            }

            writeTo(created, bytes, relativePath)
        }

    /** 写入并返回字节数 */
    private fun writeTo(
        file: DocumentFile,
        bytes: ByteArray,
        relativePath: String,
    ): Long {
        context.contentResolver.openOutputStream(file.uri)?.use { out ->
            out.write(bytes)
            out.flush()
        } ?: throw IllegalStateException("无法写入：$relativePath")
        return bytes.size.toLong()
    }

    override suspend fun exists(relativePath: String): Boolean =
        withContext(Dispatchers.IO) {
            if (relativePath.isBlank()) return@withContext true
            resolve(relativePath) != null
        }

    override suspend fun mkdirs(relativeDir: String) = withContext(Dispatchers.IO) {
        // 根目录 = 已存在（幂等）
        if (relativeDir.isBlank()) return@withContext
        // resolveOrCreateDir 内部逐级 createDirectory，已存在时静默 —— 幂等
        resolveOrCreateDir(relativeDir)
            ?: throw IllegalStateException("无法创建目录：$relativeDir（SAF 授权可能不含写权限）")
    }

    /**
     * 删除一个文件。
     *
     * **只删文件** —— `DocumentFile.delete()` 对目录是**递归删除**，
     * 而工作区是用户的真实项目文件夹，误删不可逆。
     * 所以先确认目标是文件（`isFile`），不是目录。
     */
    override suspend fun delete(relativePath: String): Boolean =
        withContext(Dispatchers.IO) {
            if (relativePath.isBlank()) return@withContext false
            val f = resolve(relativePath) ?: return@withContext false
            // 目录不删 —— 递归删除用户目录太危险
            if (!f.isFile) return@withContext false
            runCatching { f.delete() }.getOrDefault(false)
        }

    /**
     * `createFile` 需要一个 MIME 类型。
     *
     * ## ★ 陷阱：MIME 会让系统自动改文件名（2026-10-10 实测）
     *
     * 首版对所有代码文件返回 `text/plain` —— 结果
     * `createFile("text/plain", "hello.py")` 在磁盘上变成了
     * **`hello.py.txt`**！
     *
     * 原因：`DocumentsProvider` 发现 `text/plain` 的默认扩展名是 `.txt`，
     * 而传入的名字不以它结尾，于是**自动补后缀**。
     *
     * 对 agent 是致命的 —— 它以为写了 `hello.py`，
     * 下一轮 `read_file("hello.py")` 却找不到（实际叫 `hello.py.txt`）。
     *
     * ## 修法
     *
     * 对**已知扩展名的代码/文本文件**返回 `application/octet-stream`
     * —— 这个 MIME 没有默认扩展名，系统不会改名。
     *
     * 只对**真的有标准 MIME 的格式**（图片、PDF、JSON）用精确类型，
     * 那些类型本身就以对应后缀为标准，不会被改。
     */
    private fun mimeOf(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return when (ext) {
            // 这些 MIME 的标准扩展名与文件本身一致 —— 不会被改名
            "json" -> "application/json"
            "xml" -> "text/xml"
            "html", "htm" -> "text/html"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            // ★ 其余一律用无扩展名偏好的类型，保住原文件名
            //   （含 py/kt/js/md/txt/sh/... —— 它们都没有"标准"MIME）
            else -> "application/octet-stream"
        }
    }
}
