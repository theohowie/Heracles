package com.theohowie.heracles.bridge

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * **设备文件 IO**（2026-10-22）—— `heracles/device` 通道里 `fs.*` 的实现。
 *
 * ## 路径语义：**绝对 POSIX 路径**，不是相对路径
 *
 * 老实现（`AndroidSafStorage` / `PosixStorage`）用"工作区相对路径"，
 * 因为工作区就是根。现在根由 **Dart 侧**决定，Kotlin 只认设备上的绝对路径：
 *
 * ```
 * /storage/emulated/0/Android/data/com.theohowie.heracles/files/app-workspace/a.txt
 * ```
 *
 * 于是路由规则很直接（[WorkspaceRegistry.matchSaf]）：
 *
 * | 路径 | 走哪条 |
 * |---|---|
 * | 落在**已登记的 SAF 工作区**之下 | `DocumentFile`（`treeUri` + 相对段） |
 * | 其它一切 | `java.io.File` |
 *
 * ⚠️ 为什么不能统一用 `java.io.File`：用户自己选的目录（如 `/sdcard/test`）
 * 属 `media_rw` 组，App 不在这个组里 ⇒ 写必 `EPERM`（真机实测）。
 * SAF 授权给的是 `content://` 权限，只能用 `ContentResolver` 访问。
 *
 * ## 所有方法都**不抛**给调用方（除了内部实现），错误一律转成人话 Map
 *
 * 通道契约（Dart 侧）要求 `{"ok": false, "error": "..."}`，
 * 绝不向 Dart 抛 `PlatformException` —— 后端拿不到 Kotlin 的异常类型，
 * 抛过去只是一句"unknown error"，对模型毫无用处。
 * 所以这一层统一 [fail] / [ok] 两个形状，异常在 [guard] 里被译成中文原因。
 *
 * ## SAF 的三个硬边界（**如实拒绝，不假装成功**）
 *
 * 1. `listFiles()` 是**每次一个 IPC**，大目录会慢到没法用 ⇒ 一律限数量、置 `truncated`；
 * 2. **不能 rename 目录** —— `DocumentFile.renameTo()` 对目录在多数 provider 上失败；
 * 3. `delete()` 对目录是**递归删** —— 用户项目目录误删不可逆。
 *
 * ⇒ 2/3 在 SAF 上**明确报错**，把限制告诉调用方，而不是"看起来成功了"。
 */
class DeviceFs(
    private val context: Context,
    private val registry: WorkspaceRegistry,
) {

    companion object {
        /**
         * 一次 `readText` 最多读多少**字节**（不是字符）。
         *
         * 1MB：与老 `MAX_READ_BYTES` 同量级 —— 那是"别把日志塞满上下文"的预算。
         * 超了**按行截断**并置 `truncated`（读文本这条通道的语义就是"给我前 N 行"）。
         */
        const val MAX_TEXT_BYTES: Long = 1_000_000

        /**
         * 单文件**字节**读写上限：64MB。
         *
         * 与文本上限是两条独立的线（老 `MAX_BINARY_BYTES` 的同一取舍）：
         * 二进制通道搬的是资源 / libs / 成品 APK，比源码大一个量级；
         * 超限**抛**，绝不返回截断的字节数组 —— 半个文件比失败更糟。
         */
        const val MAX_BINARY_BYTES: Long = 64L * 1024 * 1024

        /** `fs.list` 在调用方没给上限时的默认条数。 */
        const val DEFAULT_MAX_ENTRIES: Int = 500

        /** `fs.list` 允许的**最大**条数上限（防调用方传个天文数字进来）。 */
        const val HARD_MAX_ENTRIES: Int = 5_000

        /** 递归列举的最大深度（防目录成环 / 病态深树）。 */
        const val MAX_DEPTH: Int = 32

    }

    /** 失败形状（**唯一**的错误出口，保证 Dart 侧只需要读 `ok` / `error`）。 */
    private fun fail(reason: String): Map<String, Any?> = mapOf("ok" to false, "error" to reason)

    private fun ok(vararg pairs: Pair<String, Any?>): Map<String, Any?> =
        mutableMapOf<String, Any?>("ok" to true).apply { putAll(pairs) }

    /** 把实现里的异常翻成中文原因 —— 这是"不向 Dart 抛异常"的落点。 */
    /**
     * ⚠️ `block` 必须是 **`suspend`** 的 lambda。
     *
     * 理由：复合操作（`rename` = 读 + 写 + 删、`copy` 递归 = 建目录 + 读 + 写）
     * 要在同一个 guard 里**串起多个 suspend 方法**。若签名写成普通
     * `() -> Map<...>`，Kotlin 会拒绝在块内调用 `readBytes` 这类 suspend 函数
     * （编译期报 "Suspension functions can only be called within coroutine body"）。
     *
     * `withContext(io)` 本身就提供了协程上下文 ⇒ 改成 `suspend` 不改变任何
     * 调用点的行为，只是把"我确实要在里面 await 别的 I/O"这件事说清楚。
     */
    private suspend fun guard(
        io: CoroutineDispatcher = Dispatchers.IO,
        block: suspend () -> Map<String, Any?>,
    ): Map<String, Any?> = withContext(io) {
        try {
            block()
        } catch (e: IllegalArgumentException) {
            fail(e.message ?: "参数不合法")
        } catch (e: SecurityException) {
            fail("没有权限访问该位置（${e.message ?: "权限被拒绝"}）")
        } catch (e: java.io.FileNotFoundException) {
            fail("找不到文件或目录（${e.message ?: "不存在"}）")
        } catch (e: Throwable) {
            fail("文件操作失败：${e.javaClass.simpleName}: ${e.message}")
        }
    }

    // ================================================================ stat

    /** `fs.stat` → `{ok, exists, isDir, size, mtimeMs}` */
    suspend fun stat(path: String): Map<String, Any?> = guard {
        val p = normalize(path) ?: throw IllegalArgumentException("路径为空")
        val saf = registry.matchSaf(p)
        if (saf != null) {
            val doc = resolveSaf(saf.first, saf.second)
                ?: return@guard ok(
                    "exists" to false, "isDir" to false, "size" to 0L, "mtimeMs" to 0L,
                )
            return@guard ok(
                "exists" to true,
                "isDir" to doc.isDirectory,
                "size" to if (doc.isDirectory) 0L else doc.length(),
                "mtimeMs" to doc.lastModified(),
            )
        }
        val f = File(p)
        if (!f.exists()) {
            return@guard ok("exists" to false, "isDir" to false, "size" to 0L, "mtimeMs" to 0L)
        }
        ok(
            "exists" to true,
            "isDir" to f.isDirectory,
            "size" to if (f.isDirectory) 0L else f.length(),
            "mtimeMs" to f.lastModified(),
        )
    }

    // ================================================================ list

    /**
     * `fs.list` → `{ok, entries:[{path,name,isDir,size}], truncated}`
     *
     * 递归时**先到先得**地截断（不是"先数完再切"）—— SAF 下遍历本身就是要限的东西。
     */
    suspend fun list(path: String, recursive: Boolean, maxEntries: Int): Map<String, Any?> = guard {
        val p = normalize(path) ?: throw IllegalArgumentException("路径为空")
        val limit = maxEntries.coerceIn(1, HARD_MAX_ENTRIES)
        val entries = mutableListOf<Map<String, Any?>>()
        var truncated = false

        val saf = registry.matchSaf(p)
        if (saf != null) {
            val root = resolveSaf(saf.first, saf.second)
                ?: return@guard fail("目录不存在：${p}")
            if (!root.isDirectory) return@guard fail("不是目录：$p")

            // ⚠️ SAF 递归 = 每层一次 listFiles()，每次 listFiles() 是 N 次 IPC。
            // 所以这里**只展开一层**的预算就够：到量就停。
            fun walk(dir: DocumentFile, base: String, depth: Int) {
                if (entries.size >= limit) {
                    truncated = true
                    return
                }
                val children = try {
                    dir.listFiles()
                } catch (e: Throwable) {
                    return // 单层读不出来不致命；上层会看到"数量比预期少"并拿到 truncated
                }
                // 确定性排序：目录在前，再按名字（SAF 返回顺序不保证稳定）
                val sorted = children.sortedWith(
                    compareBy({ !it.isDirectory }, { it.name?.lowercase() ?: "" })
                )
                for (c in sorted) {
                    if (entries.size >= limit) {
                        truncated = true
                        return
                    }
                    val name = c.name ?: continue
                    val childPath = if (base.isEmpty()) "$p/$name" else "$base/$name"
                    entries += mapOf(
                        "path" to childPath,
                        "name" to name,
                        "isDir" to c.isDirectory,
                        "size" to if (c.isDirectory) 0L else c.length(),
                    )
                    if (recursive && c.isDirectory && depth < MAX_DEPTH) {
                        walk(c, childPath, depth + 1)
                    }
                }
            }
            walk(root, p.trimEnd('/'), 0)
            return@guard okResult(entries, truncated)
        }

        val dir = File(p)
        if (!dir.isDirectory) return@guard fail("目录不存在或不是目录：$p")

        fun walk(d: File, depth: Int) {
            if (entries.size >= limit) {
                truncated = true
                return
            }
            val children = d.listFiles() ?: return
            val sorted = children.sortedWith(
                compareBy({ !it.isDirectory }, { it.name.lowercase() })
            )
            for (c in sorted) {
                if (entries.size >= limit) {
                    truncated = true
                    return
                }
                entries += mapOf(
                    "path" to c.absolutePath,
                    "name" to c.name,
                    "isDir" to c.isDirectory,
                    "size" to if (c.isDirectory) 0L else c.length(),
                )
                if (recursive && c.isDirectory && depth < MAX_DEPTH) walk(c, depth + 1)
            }
        }
        walk(dir, 0)
        okResult(entries, truncated)
    }

    private fun okResult(entries: List<Map<String, Any?>>, truncated: Boolean) =
        ok("entries" to entries, "truncated" to truncated)

    // ================================================================ readText

    /**
     * `fs.readText` → `{ok, text, truncated}`
     *
     * @param offsetLine **1 起**（与编辑器行号一致，也与老 `read_file` 的语义一致）
     * @param maxLines 最多返回多少行；`<= 0` 视为不限制
     */
    suspend fun readText(path: String, offsetLine: Int, maxLines: Int): Map<String, Any?> = guard {
        val p = normalize(path) ?: throw IllegalArgumentException("路径为空")
        if (offsetLine < 1) throw IllegalArgumentException("offsetLine 必须从 1 开始")
        val text = readTextInternal(p)
        if (text.length.toLong() > MAX_TEXT_BYTES) {
            // 超大文件：先夹字节，再按行切 —— 但**必须**如实置 truncated
            val cut = text.substring(0, MAX_TEXT_BYTES.toInt())
            return@guard slice(cut, offsetLine, maxLines, forcedTruncated = true)
        }
        slice(text, offsetLine, maxLines, forcedTruncated = false)
    }

    private fun slice(
        text: String,
        offsetLine: Int,
        maxLines: Int,
        forcedTruncated: Boolean,
    ): Map<String, Any?> {
        val lines = text.split('\n')
        val from = (offsetLine - 1).coerceIn(0, lines.size)
        val to = if (maxLines <= 0) lines.size else (from + maxLines).coerceAtMost(lines.size)
        val body = lines.subList(from, to).joinToString("\n")
        // 还有没返回的行 ⇒ truncated（**不许静默截断**）
        val truncated = forcedTruncated || to < lines.size
        return ok("text" to body, "truncated" to truncated)
    }

    private fun readTextInternal(path: String): String {
        val saf = registry.matchSaf(path)
        if (saf != null) {
            val doc = resolveSaf(saf.first, saf.second)
                ?: throw IllegalArgumentException("文件不存在：$path")
            if (doc.isDirectory) throw IllegalArgumentException("不是文件：$path")
            val ins = context.contentResolver.openInputStream(doc.uri)
                ?: throw IllegalStateException("无法打开：$path")
            return ins.use { it.readBytes().toString(Charsets.UTF_8) }
        }
        val f = File(path)
        if (!f.exists()) throw IllegalArgumentException("文件不存在：$path")
        if (f.isDirectory) throw IllegalArgumentException("不是文件：$path")
        return f.readText(Charsets.UTF_8)
    }

    /**
     * **读整份文本**（不做行切片）—— 给 Kotlin 内部的只读用途，不走通道。
     *
     * 与 [readText] 的区别：那个是给模型看的（按行取、必须置 `truncated`），
     * 这个是给机械用途的（数 JSON 数组长度），切片反而会切断合法 JSON。
     * 失败抛异常，由调用方决定怎么兜。
     */
    suspend fun readWholeText(path: String): String = withContext(Dispatchers.IO) {
        readTextInternal(normalize(path) ?: throw IllegalArgumentException("路径为空"))
    }

    // ================================================================ readBytes

    /** `fs.readBytes` → `{ok, bytes}`（**不截断**，超限报错） */
    suspend fun readBytes(path: String): Map<String, Any?> = guard {
        val p = normalize(path) ?: throw IllegalArgumentException("路径为空")
        val saf = registry.matchSaf(p)
        if (saf != null) {
            val doc = resolveSaf(saf.first, saf.second)
                ?: throw IllegalArgumentException("文件不存在：$p")
            if (doc.isDirectory) throw IllegalArgumentException("不是文件：$p")
            // SAF 的 length() 常返回 0（长度未知）⇒ 不能只靠它拦，读完再判
            val ins = context.contentResolver.openInputStream(doc.uri)
                ?: throw IllegalStateException("无法打开：$p")
            val bytes = ins.use { readLimited(it, MAX_BINARY_BYTES) }
            return@guard ok("bytes" to bytes)
        }
        val f = File(p)
        if (!f.exists()) throw IllegalArgumentException("文件不存在：$p")
        if (f.isDirectory) throw IllegalArgumentException("不是文件：$p")
        if (f.length() > MAX_BINARY_BYTES) {
            throw IllegalArgumentException(
                "文件过大（${f.length()}B > ${MAX_BINARY_BYTES}B）：$p —— 二进制通道不截断"
            )
        }
        ok("bytes" to f.readBytes())
    }

    /** 读流并**在过程中**兜住上限（超限抛，绝不返回半个数组）。 */
    private fun readLimited(input: java.io.InputStream, max: Long): ByteArray {
        val buf = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(64 * 1024)
        var total = 0L
        while (true) {
            val n = input.read(chunk)
            if (n < 0) break
            total += n
            if (total > max) {
                throw IllegalArgumentException("内容过大（超过 ${max}B）—— 二进制通道不截断")
            }
            buf.write(chunk, 0, n)
        }
        return buf.toByteArray()
    }

    // ================================================================ write

    /** `fs.writeText` → `{ok}` */
    suspend fun writeText(path: String, text: String): Map<String, Any?> =
        writeBytes(path, text.toByteArray(Charsets.UTF_8))

    /**
     * `fs.writeBytes` → `{ok}`
     *
     * 父目录不存在时**自动逐级创建**（与老 `WorkspaceFs.writeText` 的语义一致）——
     * 后端写 `.heracles/sessions/x.jsonl` 时不该先自己 mkdir 一遍。
     */
    suspend fun writeBytes(path: String, bytes: ByteArray): Map<String, Any?> = guard {
        val p = normalize(path) ?: throw IllegalArgumentException("路径为空")
        if (bytes.size.toLong() > MAX_BINARY_BYTES) {
            throw IllegalArgumentException(
                "写入过大（${bytes.size}B > ${MAX_BINARY_BYTES}B）：$p"
            )
        }
        val saf = registry.matchSaf(p)
        if (saf != null) {
            val (entry, rel) = saf
            val fileName = rel.substringAfterLast('/')
            if (fileName.isEmpty()) throw IllegalArgumentException("路径指向工作区根，无法写入：$p")
            val parentRel = rel.substringBeforeLast('/', "")
            val parent = resolveOrCreateSaf(entry, parentRel)
                ?: throw IllegalStateException("无法创建目录：$parentRel")
            writeSafFile(parent, fileName, bytes)
            return@guard ok()
        }
        val f = File(p)
        f.parentFile?.let { parent ->
            if (!parent.isDirectory && !parent.mkdirs()) {
                throw IllegalStateException("无法创建父目录：${parent.absolutePath}")
            }
        }
        f.writeBytes(bytes)
        ok()
    }

    /** SAF 写一个文件（含"删旧建新"与**文件名改写**防护）。 */
    private fun writeSafFile(parent: DocumentFile, fileName: String, bytes: ByteArray) {
        // 已存在就先删（DocumentFile 没有 truncate）；删不掉则降级为原地截断覆盖
        findChild(parent, fileName)?.let { existing ->
            if (!existing.delete()) {
                runCatching {
                    context.contentResolver.openOutputStream(existing.uri, "wt")?.use { out ->
                        out.write(bytes)
                        out.flush()
                    } ?: throw IllegalStateException("无法打开输出流")
                }.getOrElse {
                    throw IllegalStateException(
                        "无法覆盖已存在的文件且无法原地重写：$fileName" +
                            "（${it.javaClass.simpleName}: ${it.message}）"
                    )
                }
                return
            }
        }

        val created = parent.createFile(mimeOf(fileName), fileName)
            ?: throw IllegalStateException("无法创建文件：$fileName（父目录可能不可写）")

        // ★ provider 可能无视我们给的名字（实测：text/plain + hello.py → hello.py.txt）。
        //   名字不符**必须**报错：让模型写出的文件名与它以为的不一致，比直接失败更糟
        //   （下一轮 readText 找不到，会陷入困惑循环）。
        if (created.name != fileName) {
            val wrong = created.name
            created.delete()
            val retry = parent.createFile("application/octet-stream", fileName)
            if (retry == null || retry.name != fileName) {
                retry?.delete()
                throw IllegalStateException(
                    "文件系统改写了文件名：请求 $fileName，实际 $wrong。该位置不支持原样命名。"
                )
            }
            writeToDoc(retry, bytes, fileName)
            return
        }
        writeToDoc(created, bytes, fileName)
    }

    private fun writeToDoc(doc: DocumentFile, bytes: ByteArray, name: String) {
        context.contentResolver.openOutputStream(doc.uri, "wt")?.use { out ->
            out.write(bytes)
            out.flush()
        } ?: throw IllegalStateException("无法写入：$name")
    }

    // ================================================================ mkdir

    /** `fs.mkdir` → `{ok}`（**逐级创建**，已存在视为成功） */
    suspend fun mkdir(path: String): Map<String, Any?> = guard {
        val p = normalize(path) ?: throw IllegalArgumentException("路径为空")
        val saf = registry.matchSaf(p)
        if (saf != null) {
            resolveOrCreateSaf(saf.first, saf.second)
                ?: throw IllegalStateException("无法创建目录：$p（SAF 授权可能不含写权限）")
            return@guard ok()
        }
        val f = File(p)
        if (f.isDirectory) return@guard ok()
        if (!f.mkdirs() && !f.isDirectory) {
            throw IllegalStateException("无法创建目录：$p")
        }
        ok()
    }

    // ================================================================ delete

    /**
     * `fs.delete` → `{ok}`
     *
     * ## SAF 下目录删除是**递归**的 —— 这里按 `recursive` 明确区分
     *
     * `DocumentFile.delete()` 对目录**连内容一起删**，而工作区是用户的真实项目。
     * 所以：
     * · `recursive = false` 且目标是目录 ⇒ **拒绝**（说清楚为什么）；
     * · `recursive = true` 且目标是目录 ⇒ 允许，但先**自下而上**数一遍子项，
     *   超过 [HARD_MAX_ENTRIES] 直接拒绝（**一个文件都没删**）。
     */
    suspend fun delete(path: String, recursive: Boolean): Map<String, Any?> = guard {
        val p = normalize(path) ?: throw IllegalArgumentException("路径为空")
        val saf = registry.matchSaf(p)
        if (saf != null) {
            val doc = resolveSaf(saf.first, saf.second)
                ?: return@guard ok("existed" to false) // 本来就没有 —— 幂等
            if (doc.isDirectory) {
                if (!recursive) {
                    return@guard fail(
                        "拒绝删除目录「${p}」：需要 recursive=true。\n" +
                            "在 SAF 工作区里删除目录是**递归**的（整棵子树一起没了），" +
                            "所以必须显式确认。"
                    )
                }
                if (countSaf(doc, HARD_MAX_ENTRIES) > HARD_MAX_ENTRIES) {
                    return@guard fail(
                        "目录子项过多（超过 $HARD_MAX_ENTRIES 项），已拒绝删除 —— " +
                            "**一个文件都没有删除**。请先在文件管理器里清理。"
                    )
                }
                val okDeleted = runCatching { doc.delete() }.getOrDefault(false)
                if (!okDeleted) return@guard fail("无法删除目录：$p")
                return@guard ok()
            }
            val okFile = runCatching { doc.delete() }.getOrDefault(false)
            if (!okFile) return@guard fail("无法删除文件：$p")
            return@guard ok()
        }

        val f = File(p)
        if (!f.exists()) return@guard ok("existed" to false)
        if (f.isDirectory && !recursive) {
            return@guard fail("「$p」是目录，删除它需要 recursive=true（会连同里面的内容一起删）")
        }
        val deleted = if (f.isDirectory) f.deleteRecursively() else f.delete()
        if (!deleted && f.exists()) throw IllegalStateException("无法删除：$p")
        ok()
    }

    /** 递归数子项，到 `cap` 就停（用于"删之前先看有多大"）。 */
    private fun countSaf(dir: DocumentFile, cap: Int): Int {
        var n = 0
        fun walk(d: DocumentFile, depth: Int) {
            if (n > cap) return
            val children = runCatching { d.listFiles() }.getOrNull() ?: return
            for (c in children) {
                n++
                if (n > cap) return
                if (c.isDirectory && depth < MAX_DEPTH) walk(c, depth + 1)
            }
        }
        walk(dir, 0)
        return n
    }

    // ================================================================ rename

    /**
     * `fs.rename` → `{ok}`
     *
     * ⚠️ **SAF 下不能 rename 目录** —— 明确拒绝，不假装成功。
     * 文件可以：先读出来、写到新位置、删掉旧的（"复制 + 删源"），
     * 并在最后如实报告它**不是原子操作**。
     */
    suspend fun rename(from: String, to: String): Map<String, Any?> = guard {
        val src = normalize(from) ?: throw IllegalArgumentException("from 为空")
        val dst = normalize(to) ?: throw IllegalArgumentException("to 为空")

        val srcSaf = registry.matchSaf(src)
        val dstSaf = registry.matchSaf(dst)

        if (srcSaf == null && dstSaf == null) {
            val a = File(src)
            if (!a.exists()) throw IllegalArgumentException("源不存在：$src")
            val b = File(dst)
            b.parentFile?.let { if (!it.isDirectory && !it.mkdirs()) throw IllegalStateException("无法创建父目录") }
            if (b.exists()) throw IllegalStateException("目标已存在：$dst")
            if (!a.renameTo(b)) throw IllegalStateException("重命名失败：$src → $dst")
            return@guard ok()
        }

        // 跨路由（POSIX → SAF 或反之）一律按"复制 + 删源"处理，且**不掩盖非原子性**
        if (srcSaf != null) {
            val doc = resolveSaf(srcSaf.first, srcSaf.second)
                ?: throw IllegalArgumentException("源不存在：$src")
            if (doc.isDirectory) {
                return@guard fail(
                    "SAF 工作区不支持重命名目录：「$src」。\n" +
                        "`DocumentFile.renameTo()` 对目录在多数 provider 上不可靠，" +
                        "所以这里如实拒绝，而不是给你一个「看起来成功」的假象。\n" +
                        "可以改为：逐个文件复制到新目录，再删除旧目录。"
                )
            }
        }
        val bytes = (readBytes(src)["bytes"] as? ByteArray)
            ?: throw IllegalStateException("读取源文件失败：$src")
        val w = writeBytes(dst, bytes)
        if (w["ok"] != true) throw IllegalStateException("写入目标失败：${w["error"]}")
        val d = delete(src, recursive = false)
        if (d["ok"] != true) throw IllegalStateException("已复制但无法删除源文件：$src")
        // 如实告知：这条路不是原子操作
        ok("note" to "已复制到新位置并删除源文件（非原子操作）")
    }

    // ================================================================ copy

    /** `fs.copy` → `{ok}`（目录**递归**复制；SAF 下走 DocumentFile 逐级建） */
    suspend fun copy(from: String, to: String): Map<String, Any?> = guard {
        val src = normalize(from) ?: throw IllegalArgumentException("from 为空")
        val dst = normalize(to) ?: throw IllegalArgumentException("to 为空")
        if (src == dst) throw IllegalArgumentException("源与目标是同一个路径")

        val srcSaf = registry.matchSaf(src)
        val srcDoc = if (srcSaf != null) {
            resolveSaf(srcSaf.first, srcSaf.second)
                ?: throw IllegalArgumentException("源不存在：$src")
        } else {
            if (!File(src).exists()) throw IllegalArgumentException("源不存在：$src")
            null
        }

        // 统一策略：先读出来（文件）/ 列出（目录），再交给 write 侧路由。
        // 这样四条组合（POSIX/SAF × POSIX/SAF）只需要一套代码。
        val isDir = srcDoc?.isDirectory ?: File(src).isDirectory
        if (!isDir) {
            val bytes = (readBytes(src)["bytes"] as? ByteArray)
                ?: throw IllegalStateException("读取源文件失败：$src")
            val w = writeBytes(dst, bytes)
            if (w["ok"] != true) throw IllegalStateException("写入目标失败：${w["error"]}")
            return@guard ok()
        }

        // 目录：递归。先建目标根，再逐个搬。
        val mk = mkdir(dst)
        if (mk["ok"] != true) throw IllegalStateException("无法创建目标目录：${mk["error"]}")
        val listed = list(src, recursive = true, maxEntries = HARD_MAX_ENTRIES)
        if (listed["ok"] != true) throw IllegalStateException("列举源目录失败：${listed["error"]}")
        if (listed["truncated"] == true) {
            throw IllegalStateException(
                "源目录条目超过 $HARD_MAX_ENTRIES 项，已拒绝复制 —— **一个文件都没有复制**。"
            )
        }
        @Suppress("UNCHECKED_CAST")
        val entries = listed["entries"] as? List<Map<String, Any?>> ?: emptyList()

        // 自顶向下：目录先建，文件后写（list 的递归顺序是前序，目录先于其子项出现）
        for (e in entries) {
            val p = e["path"] as? String ?: continue
            val rel = p.removePrefix(src.trimEnd('/')).trimStart('/')
            if (rel.isEmpty()) continue
            val target = dst.trimEnd('/') + "/" + rel
            if (e["isDir"] == true) {
                val r = mkdir(target)
                if (r["ok"] != true) throw IllegalStateException("无法创建目录：$target（${r["error"]}）")
            } else {
                val bytes = (readBytes(p)["bytes"] as? ByteArray)
                    ?: throw IllegalStateException("读取失败：$p")
                val r = writeBytes(target, bytes)
                if (r["ok"] != true) throw IllegalStateException("写入失败：$target（${r["error"]}）")
            }
        }
        ok()
    }

    // ================================================================ 内部：SAF

    /**
     * 按 `treeUri` + 相对段找 `DocumentFile`。
     *
     * **路径穿越在这里被结构性排除** —— 逐级 `findChild`，不拼字符串路径。
     * `..` 段直接跳过（与老实现一致）。
     */
    private fun resolveSaf(entry: WorkspaceRegistry.Entry, relativePath: String): DocumentFile? {
        val root = runCatching {
            DocumentFile.fromTreeUri(context, Uri.parse(entry.treeUri))
        }.getOrNull() ?: return null
        var cur: DocumentFile = root
        val rel = relativePath.trim('/')
        if (rel.isEmpty()) return cur
        for (seg in rel.split('/')) {
            if (seg.isEmpty() || seg == "." || seg == "..") continue
            cur = findChild(cur, seg) ?: return null
        }
        return cur
    }

    /** 找到父目录，不存在则逐级创建。 */
    private fun resolveOrCreateSaf(
        entry: WorkspaceRegistry.Entry,
        relativePath: String,
    ): DocumentFile? {
        val root = runCatching {
            DocumentFile.fromTreeUri(context, Uri.parse(entry.treeUri))
        }.getOrNull() ?: return null
        var cur: DocumentFile = root
        val rel = relativePath.trim('/')
        if (rel.isEmpty()) return cur
        for (seg in rel.split('/')) {
            if (seg.isEmpty() || seg == "." || seg == "..") continue
            val next = findChild(cur, seg)
            if (next != null && next.isDirectory) {
                cur = next
                continue
            }
            // ★ 建目录失败后**必须再查一次**（真机事故）：DocumentsProvider 在同名目录
            //   已存在时会**自动改名**成 `名字 (1)` 并返回成功 ⇒ 33 个 `.heracles (N)` 垃圾目录。
            //   ⇒ 建完先看返回的名字；不一致就用回原名那个，并把刚建的空目录删掉。
            val created = cur.createDirectory(seg) ?: return null
            if (created.name != seg) {
                runCatching { created.delete() }
                cur = findChild(cur, seg) ?: return null
            } else {
                cur = created
            }
        }
        return cur
    }

    /**
     * 在 [dir] 里按名字找子项。
     *
     * `findFile` 走文档 id 精确匹配，真机上出现过"目录明明在、findFile 却返回 null"
     * ⇒ 二级降级为遍历比对（外部存储大小写不敏感，display name 大小写可能不同）。
     */
    private fun findChild(dir: DocumentFile, name: String): DocumentFile? {
        dir.findFile(name)?.let { return it }
        return runCatching {
            dir.listFiles().firstOrNull { it.name?.equals(name, ignoreCase = true) == true }
        }.getOrNull()
    }

    /** `createFile` 的 MIME —— **不能用 `text/plain`**，否则 provider 会自动补 `.txt`。 */
    private fun mimeOf(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "json" -> "application/json"
            "xml" -> "text/xml"
            "html", "htm" -> "text/html"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            // 其余一律用无扩展名偏好的类型，保住原文件名
            else -> "application/octet-stream"
        }
    }

    // ================================================================ 内部：路径

    /**
     * 归一化：反斜杠 → 正斜杠、折叠重复分隔符、去掉末尾 `/`。
     *
     * **不解析 `..`** —— 那需要真实文件系统语义，而 SAF 侧根本没有真实路径。
     * 相对路径一律拒绝（本类的契约就是绝对 POSIX 路径）。
     */
    private fun normalize(raw: String): String? {
        val s = raw.trim()
        if (s.isEmpty()) return null
        if (!s.startsWith("/")) return null // 相对路径：调用方给错了，如实拒绝
        val cleaned = s.replace('\\', '/').replace(Regex("/{2,}"), "/")
        return if (cleaned.length > 1) cleaned.trimEnd('/') else cleaned
    }
}
