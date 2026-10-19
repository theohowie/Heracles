package com.theohowie.heracles.bridge

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import java.io.File

/**
 * 存储访问的两种模式 —— **实测对比用**（2026-10-10）。
 *
 * ## 背景
 *
 * 分区存储下，`ACTION_OPEN_DOCUMENT_TREE` 只给 `content://` 权限，
 * 应用对真实路径**没有 POSIX 写权限**：
 *
 * ```
 * /storage/emulated/0/test/hello.py: Operation not permitted
 * ```
 *
 * 两条路线：
 *
 * | | A. SAF（DocumentFile） | B. MANAGE_EXTERNAL_STORAGE |
 * |---|---|---|
 * | 权限来源 | `content://` URI | POSIX（全盘） |
 * | IO 方式 | `ContentResolver` | `java.io.File` |
 * | 上架 | ✅ 无障碍 | ⚠️ 严审 |
 * | 性能 | 每次操作一次 IPC | 原生 |
 *
 * 本文用**真机测量**回答"性能差多少"，而不是猜。
 */
object StorageProbe {

    /**
     * 写入 N 个文件，比较两种模式。
     *
     * @return 结果 Map（供 Flutter 展示）
     */
    fun benchmarkSaf(
        context: Context,
        treeUri: Uri,
        fileCount: Int = 20,
        payloadBytes: Int = 4096,
    ): Map<String, Any?> {
        val results = mutableMapOf<String, Any?>()

        val root = DocumentFile.fromTreeUri(context, treeUri)
        if (root == null) {
            results["error"] = "无法解析 tree URI"
            return results
        }

        val payload = "x".repeat(payloadBytes)

        // ---- 1. 创建目录 ----
        val tMkdir = System.nanoTime()
        var dir = root.findFile("saf-probe")
        if (dir == null) dir = root.createDirectory("saf-probe")
        val mkdirMs = (System.nanoTime() - tMkdir) / 1_000_000

        if (dir == null) {
            results["error"] = "无法创建目录（权限不足？）"
            return results
        }

        // ---- 2. 写入 N 个文件 ----
        val tWrite = System.nanoTime()
        var written = 0
        for (i in 0 until fileCount) {
            val name = "f$i.txt"
            var f = dir.findFile(name)
            if (f == null) f = dir.createFile("text/plain", name)
            if (f == null) continue
            runCatching {
                context.contentResolver.openOutputStream(f.uri)?.use { out ->
                    out.write(payload.toByteArray())
                }
                written++
            }
        }
        val writeMs = (System.nanoTime() - tWrite) / 1_000_000

        // ---- 3. 列出 ----
        val tList = System.nanoTime()
        val listed = dir.listFiles().size
        val listMs = (System.nanoTime() - tList) / 1_000_000

        // ---- 4. 读取 N 个文件 ----
        val tRead = System.nanoTime()
        var readBytes = 0L
        dir.listFiles().forEach { f ->
            runCatching {
                context.contentResolver.openInputStream(f.uri)?.use { ins ->
                    readBytes += ins.readBytes().size
                }
            }
        }
        val readMs = (System.nanoTime() - tRead) / 1_000_000

        // ---- 5. 清理 ----
        val tDel = System.nanoTime()
        dir.delete()
        val delMs = (System.nanoTime() - tDel) / 1_000_000

        results["mode"] = "saf"
        results["mkdirMs"] = mkdirMs
        results["writeMs"] = writeMs
        results["writeCount"] = written
        results["listMs"] = listMs
        results["listed"] = listed
        results["readMs"] = readMs
        results["readBytes"] = readBytes
        results["deleteMs"] = delMs
        results["perOpMs"] = if (written > 0) writeMs.toDouble() / written else 0.0
        return results
    }

    /**
     * 对照组：用 `java.io.File` 在**应用私有目录**做同样的事。
     *
     * 这就是"如果拿到 POSIX 权限会多快"的上限 ——
     * 因为私有目录我们本来就有完全权限。
     */
    fun benchmarkFile(
        context: Context,
        fileCount: Int = 20,
        payloadBytes: Int = 4096,
    ): Map<String, Any?> {
        val results = mutableMapOf<String, Any?>()
        val base = File(context.cacheDir, "file-probe")
        base.deleteRecursively()

        val payload = "x".repeat(payloadBytes)

        val tMkdir = System.nanoTime()
        val ok = base.mkdirs()
        val mkdirMs = (System.nanoTime() - tMkdir) / 1_000_000

        if (!ok && !base.isDirectory) {
            results["error"] = "无法创建目录"
            return results
        }

        val tWrite = System.nanoTime()
        var written = 0
        for (i in 0 until fileCount) {
            runCatching {
                File(base, "f$i.txt").writeText(payload)
                written++
            }
        }
        val writeMs = (System.nanoTime() - tWrite) / 1_000_000

        val tList = System.nanoTime()
        val listed = base.listFiles()?.size ?: 0
        val listMs = (System.nanoTime() - tList) / 1_000_000

        val tRead = System.nanoTime()
        var readBytes = 0L
        base.listFiles()?.forEach { f ->
            runCatching { readBytes += f.readBytes().size }
        }
        val readMs = (System.nanoTime() - tRead) / 1_000_000

        val tDel = System.nanoTime()
        base.deleteRecursively()
        val delMs = (System.nanoTime() - tDel) / 1_000_000

        results["mode"] = "file"
        results["mkdirMs"] = mkdirMs
        results["writeMs"] = writeMs
        results["writeCount"] = written
        results["listMs"] = listMs
        results["listed"] = listed
        results["readMs"] = readMs
        results["readBytes"] = readBytes
        results["deleteMs"] = delMs
        results["perOpMs"] = if (written > 0) writeMs.toDouble() / written else 0.0
        return results
    }
}
