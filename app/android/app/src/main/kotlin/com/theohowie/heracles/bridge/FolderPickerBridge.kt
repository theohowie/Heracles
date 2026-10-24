package com.theohowie.heracles.bridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
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
 *
 * ## ★★ Android 11+ 的"为了保护隐私，请选择其他文件夹"（2026-10-23）★★
 *
 * 这是**系统的**限制，不是我们的 bug：`ACTION_OPEN_DOCUMENT_TREE` 在
 * API 30+ 拒绝用户选择这几类位置 ——
 *
 * | 被拒位置 | 系统行为 |
 * |---|---|
 * | 内部存储**根**（`/sdcard`） | 灰掉，点了弹「为了保护隐私，请选择其他文件夹」 |
 * | `Download` 目录 | 同上 |
 * | `Android/data` · `Android/obb` | 同上（而且根本浏览不到） |
 * | `Documents` / 厂商目录 | Android 13+ 起部分机型也灰 |
 *
 * ### 我们能做什么（做不了什么）
 *
 * **做不了**：绕过它。那条限制的官方出路只有 `MANAGE_EXTERNAL_STORAGE`
 * （全盘访问，Play 商店需要额外审核）—— 属重大权限变更，**本轮明确不申请**。
 *
 * **做了三件**（都在这个类里，不需要改 UI）：
 *
 * 1. **[EXTRA_INITIAL_URI]** —— 把选择器起点设到**上次用的目录**（或主存储根）。
 *    用户不用每次从"最近"里翻。
 * 2. **[checkRestricted]** —— 选中受限目录时**不返回成功**，而是回一句人话，
 *    说清"为什么不让选"和"下一步该选什么"。系统那三行字对用户没有指导性。
 * 3. **[suggestFallback]** —— 同时把可用出路（选子文件夹 / 用「默认工作区」）
 *    一并回给 Dart，由 UI 展示。
 */
class FolderPickerBridge(private val activity: Activity) {

    companion object {
        const val REQUEST_CODE = 0x4846 // 'HF'

        /**
         * "上次用的目录"存在这里（`content://` 形式的 tree URI）。
         *
         * 为什么存 URI 而不是路径：`EXTRA_INITIAL_URI` 要的就是 URI。
         * 存路径还得反推 URI，多一步换算就多一处出错点。
         */
        private const val PREFS = "heracles_folder_picker"
        private const val KEY_LAST_URI = "last_tree_uri"

        /**
         * 系统在这些路径上会拒绝授权（API 30+）。
         *
         * 判定用**真实路径前缀**，因为系统文案只出现在 UI 上，
         * 我们拿不到"用户点了哪个被拒的条目"这个事件 —— 只能事后判。
         *
         * ⚠️ 这只是**兜底提示**：理论上系统根本不会让我们拿到这些 URI。
         * 留着它是为了覆盖"某些 ROM 放宽了但实际不可写"的情况。
         */
        private val RESTRICTED_EXACT = setOf(
            "/storage/emulated/0",   // 内部存储根
            "/storage/emulated/0/Download",
            "/storage/emulated/0/Android",
            "/storage/emulated/0/Android/data",
            "/storage/emulated/0/Android/obb",
        )
    }

    private var pendingResult: ((Map<String, Any?>?) -> Unit)? = null

    /**
     * 用户选的目录是否落在系统限制范围内。
     *
     * @return `null` = 可用；否则返回一句**人话**原因。
     */
    fun checkRestricted(path: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null // API 30 以下没这条限制
        val p = path.trimEnd('/')
        if (p.isEmpty()) return null
        if (RESTRICTED_EXACT.contains(p)) {
            return "Android 11 起系统不允许把「${fileNameOf(p)}」整个目录授权给应用（保护隐私）。"
        }
        // /storage/emulated/0/Android/... 整棵子树都不行
        if (p.startsWith("/storage/emulated/0/Android/")) {
            return "Android 11 起系统不允许授权 Android 目录下的任何位置（保护隐私）。"
        }
        // 其它存储卷（SD 卡）的根同样被拒
        if (Regex("^/storage/[A-Za-z0-9-]+$").matches(p)) {
            return "Android 11 起系统不允许把整个存储卷授权给应用（保护隐私）。"
        }
        return null
    }

    private fun fileNameOf(path: String): String = path.trimEnd('/').substringAfterLast('/')

    /**
     * 拉起系统目录选择器。
     *
     * @param lastUri 上次选中的 tree URI（用作 `EXTRA_INITIAL_URI` 起点）；
     *                空 = 不设起点（系统自己决定）
     */
    fun launch(lastUri: String = "", onResult: (Map<String, Any?>?) -> Unit) {
        pendingResult = onResult

        val remembered = lastUri.ifBlank { loadLastUri() }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
            )
            // ★ 把起点放到"上次用的目录"（API 26+）。
            //
            // 为什么值得加：系统默认从「最近」或根目录开始，而根目录在 API 30+
            // **是灰的** —— 用户第一眼看到一堆不能点的条目，非常困惑。
            // 给一个能用的起点，等于把"该往哪点"直接摆到眼前。
            //
            // ⚠️ 传了也不保证生效：部分 provider 会忽略它。忽略无害（退回默认行为），
            //    所以这里不做"失败就重试"之类的事。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && remembered.isNotBlank()) {
                runCatching {
                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(remembered))
                }
            }
        }

        // ★ 诊断 + 兜底（2026-10-20）：
        //   真机上出现过"点「选择文件夹」后没反应、logcat 也没有异常"的情况。
        //   两种可能：① startActivityForResult 抛了（Activity 已 finishing / 无 handler）
        //            ② 系统没有能处理 ACTION_OPEN_DOCUMENT_TREE 的 Activity
        //   ⚠️ 两条都**必须把 result 回掉**，否则 Dart 侧那个 `await` 永久挂起
        //      —— 界面看起来像"点了没反应"，其实是在等一个永不到来的结果。
        try {
            activity.startActivityForResult(intent, REQUEST_CODE)
            println("[heracles][picker] startActivityForResult 已发出 requestCode=$REQUEST_CODE")
        } catch (e: Throwable) {
            println(
                "[heracles][picker] startActivityForResult 失败：" +
                    "${e.javaClass.simpleName}: ${e.message}",
            )
            pendingResult = null
            onResult(null)
        }
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
            // ★ 网盘 / 无本地路径：给一句能指导下一步的话，而不是干巴巴的 null。
            //   null 仍然要回（沿用旧契约：Dart 侧据此判"没选"），
            //   但附带的 reason 让 UI 能说清为什么。
            r?.invoke(
                mapOf(
                    "ok" to false,
                    "reason" to "no_local_path",
                    "error" to "这个位置没有本地文件路径（例如网盘 / 云端盘），" +
                        "Heracles 只能在工作区的真实文件夹里读写。\n" +
                        "请选择「内部存储」里的一个子文件夹，或使用「默认工作区」。",
                )
            )
            return
        }

        // ★ 受限目录：不返回成功，直接说清原因与下一步
        val restricted = checkRestricted(path)
        if (restricted != null) {
            r?.invoke(
                mapOf(
                    "ok" to false,
                    "reason" to "restricted",
                    "path" to path,
                    "error" to restricted,
                    "suggest" to suggestFallback(),
                )
            )
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

        // 记住这次的选择（下次用 EXTRA_INITIAL_URI 起点）
        saveLastUri(uri.toString())

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
     * 受限时给用户的**出路**（Dart/UI 直接展示）。
     *
     * 两条都是真的能用（不是安慰话）：
     * 1. 选根目录**下面**的子文件夹 —— 子目录不受那条限制；
     * 2. 「默认工作区」= `Android/data/<pkg>/files/app-workspace`，
     *    由 App 自己创建，**完全不经过 SAF 选择器**，所以也不受限制。
     */
    private fun suggestFallback(): List<Map<String, String>> = listOf(
        mapOf(
            "action" to "pick_subfolder",
            "title" to "改选子文件夹",
            "detail" to "点进去选一个具体的项目文件夹（例如 Download 里的某个项目），" +
                "子文件夹可以正常授权。",
        ),
        mapOf(
            "action" to "use_app_workspace",
            "title" to "使用「默认工作区」",
            "detail" to "App 自带的目录，不受这个限制，创建后可以直接开始干活。",
        ),
    )

    private fun loadLastUri(): String = runCatching {
        activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE)
            .getString(KEY_LAST_URI, "").orEmpty()
    }.getOrDefault("")

    private fun saveLastUri(uri: String) {
        runCatching {
            activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE)
                .edit().putString(KEY_LAST_URI, uri).apply()
        }
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
