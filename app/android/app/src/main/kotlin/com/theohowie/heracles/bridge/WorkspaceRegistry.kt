package com.theohowie.heracles.bridge

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * **工作区登记表**（2026-10-22，Kotlin 侧只剩设备能力之后从 `SessionStore` 里抽出来的）。
 *
 * ## 它只管"登记"这一件事
 *
 * 会话（`.heracles/sessions/` 下的 `.jsonl`）的读写已经搬到 Dart 后端，
 * 所以这里**不再**持有 `WorkspaceStorage`，也不再读写会话内容 ——
 * 只负责 `heracles_workspaces` 这份 SharedPreferences：
 *
 * ```json
 * {"list":"[{\"path\":\"/storage/emulated/0/test\",\"name\":\"test\",
 *           \"treeUri\":\"content://.../tree/primary%3Atest\"}]"}
 * ```
 *
 * 字段就是老代码那三个（`path` / `name` / `treeUri`）——
 * **格式沿用**，用户的旧登记不会因为这次重构失效。
 *
 * ## 为什么 SAF 的 `treeUri` 必须跟着路径一起存
 *
 * 分区存储下 App 对 `/storage/emulated/0/...` **没有 POSIX 写权限**
 * （属 `media_rw` 组，我们不在组里，实测 `EPERM`）。
 * 只有 SAF 授权给的 `content://` 权限能用 ⇒ [DeviceFs] 靠这条记录
 * 判断"这个绝对路径该走 `DocumentFile` 还是 `java.io.File`"。
 */
class WorkspaceRegistry(private val context: Context) {

    /**
     * 一条工作区登记。
     *
     * @param path 设备上的**绝对 POSIX 路径**（对用户可见的那个）
     * @param name 显示名（缺省用目录名）
     * @param treeUri SAF 树 URI；空串 = 走 POSIX（App 自己写得到的目录）
     */
    data class Entry(val path: String, val name: String, val treeUri: String) {
        val isSaf: Boolean get() = treeUri.isNotBlank()
        fun toMap(): Map<String, Any?> = mapOf(
            "id" to path,
            "name" to name,
            "path" to path,
            "treeUri" to treeUri,
            "isSaf" to isSaf,
        )
    }

    companion object {
        /** prefs 名（**沿用旧名**，否则用户已登记的工作区会全部消失）。 */
        const val PREFS = "heracles_workspaces"

        /** 列表键（沿用旧键）。 */
        private const val KEY_LIST = "list"

        /** 会话数据目录（Dart 侧读写，本类只用来数一数会话文件）。 */
        const val DOT_DIR = ".heracles"

        /** 会话清单文件（`sessions.json`，Dart 侧写的；数条数用）。 */
        private const val KEY_SESSIONS = "$DOT_DIR/sessions.json"

        /**
         * **内置「默认工作区」的目录名 / 显示名**（原「应用工作区」，ADR-030）。
         *
         * 目录 = `<外置私有目录>/app-workspace`
         *   = `/storage/emulated/0/Android/data/<pkg>/files/app-workspace`
         *
         * 为什么不用 `files/` 根：那里会堆诊断产物（自检、探针文件）；
         * 用户的工作区不该被这些占着。
         */
        const val APP_WORKSPACE_DIR = "app-workspace"
        const val APP_WORKSPACE_NAME = "默认工作区"
    }

    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ------------------------------------------------------------ 读

    /** 全部登记（按写入顺序；损坏的记录**跳过**而不是让整表读不出来）。 */
    fun list(): List<Entry> {
        val raw = prefs.getString(KEY_LIST, null) ?: return emptyList()
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val out = mutableListOf<Entry>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val path = o.optString("path")
            if (path.isBlank()) continue
            val dirName = File(path).name
            out += Entry(
                path = path,
                name = o.optString("name").ifBlank { dirName },
                treeUri = o.optString("treeUri"),
            )
        }
        return out
    }

    /**
     * 找出 `path` 落在哪个**已登记的 SAF 工作区**之下。
     *
     * ## 匹配规则（三条都必要）
     *
     * 1. **最长前缀**优先 —— 嵌套登记时（`/a` 与 `/a/b`）取更具体的那个；
     * 2. **必须在分隔符边界**上 —— `/storage/emulated/0/tes` 不能匹配 `/storage/emulated/0/test`；
     * 3. `treeUri` 必须非空 —— POSIX 工作区不需要 SAF。
     *
     * @return 命中的登记 + 相对段（`""` = 工作区根自身）；没命中返回 null
     */
    fun matchSaf(path: String): Pair<Entry, String>? {
        var best: Pair<Entry, String>? = null
        for (e in list()) {
            if (!e.isSaf) continue
            val root = e.path.trimEnd('/')
            if (path != root && !path.startsWith("$root/")) continue
            val rel = if (path == root) "" else path.substring(root.length + 1)
            if (best == null || root.length > best.first.path.length) best = e to rel
        }
        return best
    }

    // ------------------------------------------------------------ 写

    /**
     * 登记（或更新）一个工作区。
     *
     * 幂等：同 `path` 会**替换**旧记录（保留顺序：先删后加，位置变到末尾 ——
     * 与旧实现一致，用户看到的是"最近登记的在最后"）。
     *
     * @return 登记后的条目；`null` = 目录不存在且没有 SAF 授权（**不假装成功**）
     */
    fun add(path: String, name: String, treeUri: String = ""): Map<String, Any?>? {
        val dir = File(path)
        if (treeUri.isBlank() && !dir.isDirectory) return null
        val entry = Entry(
            path = path,
            name = name.ifBlank { dir.name.ifBlank { path } },
            treeUri = treeUri,
        )
        val all = list().filter { it.path != path } + entry
        save(all)
        return entry.toMap()
    }

    /** 从列表移除（**不删文件夹本身**）。 */
    fun remove(path: String) {
        save(list().filter { it.path != path })
    }

    /**
     * **登记内置「默认工作区」**（幂等）。
     *
     * 编码层要求工作区 **App 与 shell 都能写**，而真机上唯一满足的
     * `Android/data/<pkg>/files/...` 在 SAF 里**选不到**（系统不让浏览 `Android/data`）
     * ⇒ 这条必须由 App 自己登记（ADR-030）。
     *
     * @return 条目；`null` = 建不出目录（例如存储被摘掉）—— 如实回 null
     */
    fun ensureAppWorkspace(): Map<String, Any?>? {
        val base = context.getExternalFilesDir(null) ?: return null
        val dir = File(base, APP_WORKSPACE_DIR)
        if (!dir.isDirectory && !dir.mkdirs()) return null

        val path = dir.absolutePath
        list().firstOrNull { it.path == path }?.let { return it.toMap() }
        return add(path = path, name = APP_WORKSPACE_NAME)
    }

    // ------------------------------------------------------------ 会话数（只读、只数）

    /**
     * 数一个工作区里有多少个会话（**只数，不解析语义**）。
     *
     * ## 为什么不在这里读会话内容
     *
     * 会话的**格式与语义**已经归 Dart（`backend/`），Kotlin 再解析一遍就是
     * 两份真相。这里只做一件无害的事：把 `sessions.json` 当 JSON 数组数长度。
     *
     * 读不出来（工作区失效 / 文件还没写）⇒ 返回 `0`。
     * **这不是"会话丢了"，只是"数不出来"** —— 侧边栏那个数字纯参考。
     */
    suspend fun sessionCount(fs: DeviceFs, entry: Entry): Int = runCatching {
        val text = fs.readWholeText(entry.path.trimEnd('/') + "/" + KEY_SESSIONS)
        val arr = JSONArray(text.trim())
        arr.length()
    }.getOrDefault(0)

    private fun save(all: List<Entry>) {
        val arr = JSONArray()
        all.forEach { e ->
            arr.put(
                JSONObject().apply {
                    put("path", e.path)
                    put("name", e.name)
                    put("treeUri", e.treeUri)
                }
            )
        }
        prefs.edit().putString(KEY_LIST, arr.toString()).apply()
    }
}
