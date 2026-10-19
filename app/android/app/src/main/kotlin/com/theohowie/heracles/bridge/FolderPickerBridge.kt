package com.theohowie.heracles.bridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import java.io.File

/**
 * 文件夹选择器 —— 「新建工作区」的真实实现。
 *
 * ## 为什么是"选择"而不是"创建"
 *
 * 电脑上的智能体（Codex / Cursor / Trae）里，**工作区 = 一个已有项目文件夹**。
 * 用户点"打开文件夹"，选一个已存在的目录。
 *
 * 之前把它实现成"在应用私有目录里创建新目录"是**概念错误**：
 * 那样用户根本看不到自己的代码，工作区成了一个空的沙箱。
 *
 * ## SAF 的坑：拿到的是 URI 不是路径
 *
 * `ACTION_OPEN_DOCUMENT_TREE` 返回 `content://com.android.externalstorage.documents/tree/...`，
 * 而我们的 `:workspace` 模块用 `java.io.File` 读文件。
 *
 * 所以这里做一次**URI → 真实路径**的解析：
 * - 主存储（`primary:`）→ `/storage/emulated/0/...`
 * - SD 卡（`XXXX-XXXX:`）→ `/storage/XXXX-XXXX/...`
 *
 * 拿不到真实路径时返回 null，上层会提示用户换一个位置。
 * **不静默降级** —— 那样用户会以为选上了，实际写不进去。
 */
class FolderPickerBridge(private val activity: Activity) {

    companion object {
        const val REQUEST_CODE = 0x4846 // 'HF'
    }

    private var pendingResult: ((Map<String, Any?>?) -> Unit)? = null

    fun launch(onResult: (Map<String, Any?>?) -> Unit) {
        pendingResult = onResult
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
        }
        activity.startActivityForResult(intent, REQUEST_CODE)
    }

    fun onCancelled() {
        val r = pendingResult
        pendingResult = null
        r?.invoke(null)
    }

    fun onActivityResult(data: Intent?) {
        val r = pendingResult
        pendingResult = null
        val uri = data?.data ?: run { r?.invoke(null); return }

        // 持久化授权 —— 否则重启后就没权限写这个目录了
        runCatching {
            activity.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }

        val path = toRealPath(uri)
        if (path == null) {
            r?.invoke(null)
            return
        }

        val dir = File(path)
        // ★ 关键：SAF 授权 ≠ POSIX 权限。
        //
        // 分区存储下 `ACTION_OPEN_DOCUMENT_TREE` 给的是 content:// 权限，
        // 应用进程对真实路径**仍然没有 write 权限**。实测：
        //   test/.heracles/ 创建成功（走 SAF）
        //   test/hello.py   写入失败（走 java.io.File → Operation not permitted）
        //
        // 所以这里**先探测能不能真的写**，把结论如实告诉用户 ——
        // 否则用户选完文件夹、发消息、才看到"写入失败"，那时已经太晚。
        val writable = probeWritable(dir)

        r?.invoke(
            mapOf(
                "id" to path,
                "name" to (dir.name.ifBlank { path }),
                "path" to path,
                // ★ SAF tree URI —— 分区存储下**必须**靠它才能读写
                "treeUri" to uri.toString(),
                "isSaf" to true,
                "sessionCount" to 0,
                "exists" to true,
                "writable" to writable,
            )
        )
    }

    /**
     * 探测目录是否**真的**可写（POSIX 级）。
     *
     * 不做真实写入测试（会留下垃圾文件），
     * 而是用 `File.canWrite()` + 尝试创建并立即删除一个临时目录 ——
     * 后者能捕捉到 `canWrite()` 漏报的情况。
     */
    private fun probeWritable(dir: File): Boolean {
        if (!dir.isDirectory) return false
        if (!dir.canWrite()) return false
        val probe = File(dir, ".heracles_probe_${System.currentTimeMillis()}")
        return try {
            if (probe.mkdir()) {
                probe.delete()
                true
            } else {
                false
            }
        } catch (e: Throwable) {
            false
        }
    }

    /**
     * `content://.../tree/primary%3ADownload` → `/storage/emulated/0/Download`
     *
     * 解析失败返回 null（例如选了网盘、Google Drive 这类没有本地路径的位置）。
     */
    private fun toRealPath(uri: Uri): String? {
        val docId = runCatching { DocumentsContract.getTreeDocumentId(uri) }.getOrNull()
            ?: return null

        val parts = docId.split(":", limit = 2)
        val type = parts.getOrNull(0) ?: return null
        val rel = parts.getOrNull(1).orEmpty()

        val base = when (type) {
            "primary" -> "/storage/emulated/0"
            // SD 卡：type 形如 "1234-5678"
            else -> "/storage/$type"
        }
        val full = if (rel.isBlank()) base else "$base/$rel"

        // 归一化 + 防穿越
        val f = File(full)
        return runCatching { f.canonicalPath }.getOrNull()
    }
}
