package com.theohowie.heracles.bridge

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.File

/**
 * **设备能力通道** `heracles/device`（2026-10-22）。
 *
 * ## 这一层现在**只有设备能力**，没有任何 Agent 逻辑
 *
 * 后端已用 Dart 重写（`backend/`）。Kotlin 侧保留且只保留"只有原生才能做"的事：
 *
 * | 方法 | 能力 | 实现 |
 * |---|---|---|
 * | `fs.*` | 文件系统（POSIX + SAF 双路由） | [DeviceFs] |
 * | `exec.run` | shell（Shizuku / Stellar 双路由） | [DeviceShell] |
 * | `health.read` | 电量 / 温度 / 充电 | [DeviceHealth] |
 * | `picker.folder` / `picker.files` | 系统选择器（必须走 Activity result） | [FolderPickerBridge] / [FilePickerBridge] |
 * | `buildNotify.*` | 前台服务 + 通知栏进度 | [BuildTaskProgress] → [AgentBuildService] |
 *
 * ## 铁律：**绝不向 Dart 抛 PlatformException**
 *
 * 后端拿不到 Kotlin 的异常类型 —— 一次 `PlatformException` 到那边只剩
 * 一句 "unknown error"，对模型毫无用处，对用户也没法解释。所以：
 *
 * · 业务失败 ⇒ `{"ok": false, "error": "<人话中文原因>"}`
 * · 未知方法 ⇒ `{"ok": false, "error": "未知方法：xxx"}`（**不用** `notImplemented()`）
 * · 参数缺失 ⇒ 同上
 *
 * 唯一的例外是通道本身没建起来（引擎没起来），那种情况 Dart 侧根本发不出调用。
 *
 * ## 线程模型
 *
 * · handler 在**主线程**被调（Flutter 的约定）；
 * · 文件 IO / shell / 健康读数全部 `suspend` + `Dispatchers.IO`（内部切）；
 * · `result.success/error` **必须在主线程**回（Flutter 的 `@UiThread` 要求），
 *   所以所有回复都经 [mainHandler] 回到主线程 —— **包括 picker 的回调**
 *   （它在 `onActivityResult` 里被调，时机不由我们决定）。
 */
class DeviceChannel(
    private val activity: Activity,
    private val registry: WorkspaceRegistry,
    private val fs: DeviceFs,
    private val shell: DeviceShell,
    private val health: DeviceHealth,
    private val build: BuildTaskProgress,
    private val memory: MemoryStore,
    private val filePicker: FilePickerBridge,
    private val folderPicker: FolderPickerBridge,
    private val scope: CoroutineScope,
    private val mainHandler: Handler = Handler(activity.mainLooper),
) {

    companion object {
        /** 通道名 —— **必须与 Dart 侧逐字一致**。 */
        const val CHANNEL = "heracles/device"
    }

    /** 在主线程回结果（Flutter 的 `Result` 是 `@UiThread`）。 */
    private fun reply(result: MethodChannel.Result, value: Any?) {
        if (Thread.currentThread() === mainHandler.looper.thread) {
            runCatching { result.success(value) }
        } else {
            mainHandler.post { runCatching { result.success(value) } }
        }
    }

    /** 统一的失败形状。 */
    private fun failure(reason: String): Map<String, Any?> =
        mapOf("ok" to false, "error" to reason)

    /** 挂到 Flutter 引擎上。 */
    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            dispatch(call, result)
        } catch (e: Throwable) {
            // 兜底：dispatch 内部理论上不抛（各实现都自己 guard），
            // 但"理论上"不该成为 Dart 侧收到 PlatformException 的理由。
            reply(
                result,
                failure("设备通道内部错误：${e.javaClass.simpleName}: ${e.message}"),
            )
        }
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ---------------------------------------------------------- 文件
            "fs.stat" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.stat 缺少参数 path"))
                scope.launch { reply(result, fs.stat(path)) }
            }

            "fs.list" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.list 缺少参数 path"))
                val recursive = call.argument<Boolean>("recursive") ?: false
                val maxEntries = call.argument<Int>("maxEntries")
                    ?: DeviceFs.DEFAULT_MAX_ENTRIES
                scope.launch { reply(result, fs.list(path, recursive, maxEntries)) }
            }

            "fs.readText" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.readText 缺少参数 path"))
                val offsetLine = call.argument<Int>("offsetLine") ?: 1
                val maxLines = call.argument<Int>("maxLines") ?: 0
                scope.launch { reply(result, fs.readText(path, offsetLine, maxLines)) }
            }

            "fs.readBytes" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.readBytes 缺少参数 path"))
                scope.launch { reply(result, fs.readBytes(path)) }
            }

            // ★ 从文件尾读最后 N 行（2026-10-23）—— 长会话加载走这条。
            //
            // 为什么不让 Dart 用 fs.readText 自己切尾巴：那要先把整文件读进内存
            // （原始 String + split 出的行列表 ≈ 2×），几百条会话在真机上会掉帧。
            // 这里 POSIX 走反向 seek，只读尾部字节。
            "fs.readTailLines" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.readTailLines 缺少参数 path"))
                val maxLines = call.argument<Int>("maxLines") ?: 0
                scope.launch { reply(result, fs.readTailLines(path, maxLines)) }
            }

            // ★ 真正的追加写（2026-10-23）—— 会话 .jsonl 的 append-only 靠它。
            //
            // 过去只有 fs.writeText（整体覆盖）⇒ Dart 每次追加都要
            // "读全文 + 拼 + 写全文" = O(n²)，长会话越聊越卡。
            // 这个方法是 O(追加量)。
            "fs.appendText" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.appendText 缺少参数 path"))
                val text = call.argument<String>("text")
                    ?: return reply(result, failure("fs.appendText 缺少参数 text"))
                scope.launch { reply(result, fs.appendText(path, text)) }
            }

            "fs.writeText" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.writeText 缺少参数 path"))
                val text = call.argument<String>("text")
                    ?: return reply(result, failure("fs.writeText 缺少参数 text"))
                scope.launch { reply(result, fs.writeText(path, text)) }
            }

            "fs.writeBytes" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.writeBytes 缺少参数 path"))
                val bytes = call.byteArrayArg("bytes")
                    ?: return reply(
                        result,
                        failure("fs.writeBytes 缺少参数 bytes（或类型不是 ByteArray）"),
                    )
                scope.launch { reply(result, fs.writeBytes(path, bytes)) }
            }

            "fs.mkdir" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.mkdir 缺少参数 path"))
                scope.launch { reply(result, fs.mkdir(path)) }
            }

            "fs.delete" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.delete 缺少参数 path"))
                val recursive = call.argument<Boolean>("recursive") ?: false
                scope.launch { reply(result, fs.delete(path, recursive)) }
            }

            "fs.rename" -> {
                val from = call.stringArg("from")
                    ?: return reply(result, failure("fs.rename 缺少参数 from"))
                val to = call.stringArg("to")
                    ?: return reply(result, failure("fs.rename 缺少参数 to"))
                scope.launch { reply(result, fs.rename(from, to)) }
            }

            "fs.copy" -> {
                val from = call.stringArg("from")
                    ?: return reply(result, failure("fs.copy 缺少参数 from"))
                val to = call.stringArg("to")
                    ?: return reply(result, failure("fs.copy 缺少参数 to"))
                scope.launch { reply(result, fs.copy(from, to)) }
            }

            // ---------------------------------------------------------- 打开文件夹
            //
            // ★ 2026-10-27（用户要求）：工作区菜单里点路径 → 在系统
            //   「文件」里打开那个目录。handler 本来就在主线程，直接做。
            "fs.openFolder" -> {
                val path = call.stringArg("path")
                    ?: return reply(result, failure("fs.openFolder 缺少参数 path"))
                reply(result, openFolderInFiles(path))
            }

            // ---------------------------------------------------------- 命令
            "exec.run" -> {
                val cmd = call.stringArg("cmd")
                    ?: return reply(result, failure("exec.run 缺少参数 cmd"))
                val cwd = call.argument<String>("cwd")
                val timeoutMs = (call.argument<Number>("timeoutMs"))?.toLong() ?: 0L
                scope.launch { reply(result, shell.run(cmd, cwd, timeoutMs)) }
            }

            // ---------------------------------------------------------- 健康
            "health.read" -> scope.launch { reply(result, health.read()) }

            // ---------------------------------------------------------- 长期记忆
            //
            // ★ 2026-10-23：记忆搬到 **App 全局**（不再放工作区里）。
            //   路径 `<externalFilesDir>/heracles/memory.md`，与工作区无关 ⇒
            //   跨工作区共享；且不受 SAF 限制（不用授权、不用 MANAGE_EXTERNAL_STORAGE）。
            //
            //   为什么不让 Dart 用 `fs.*` 自己拼路径：那要 Dart 知道
            //   `getExternalFilesDir` 的值，而它拿不到 —— 只有原生知道。
            "memory.read" -> scope.launch { reply(result, memory.read()) }

            "memory.append" -> {
                val note = call.argument<String>("note")
                    ?: return reply(result, failure("memory.append 缺少参数 note"))
                scope.launch { reply(result, memory.append(note)) }
            }

            "memory.clear" -> scope.launch { reply(result, memory.clear()) }

            // ---------------------------------------------------------- 选择器
            "picker.folder" -> launchFolderPicker(result)

            "picker.files" -> {
                val multiple = call.argument<Boolean>("multiple") ?: true
                launchFilePicker(multiple, result)
            }

            // ---------------------------------------------------------- 构建通知
            "buildNotify.start" -> {
                val title = call.argument<String>("title").orEmpty()
                build.start(title)
                reply(result, mapOf("ok" to true))
            }

            "buildNotify.step" -> {
                val text = call.argument<String>("text")
                    ?: return reply(result, failure("buildNotify.step 缺少参数 text"))
                build.step(text)
                reply(result, mapOf("ok" to true))
            }

            "buildNotify.finish" -> {
                build.finish()
                reply(result, mapOf("ok" to true))
            }

            else -> reply(result, failure("未知方法：${call.method}"))
        }
    }

    // ------------------------------------------------------------ 打开文件夹

    /**
     * 在系统「文件」里打开 [path] 指向的文件夹。两段式，逐级降级：
     *
     * 1. **DocumentsUI 直达**：路径换成 externalstorage 的 document Uri
     *    用 ACTION_VIEW 打开，系统文件直接停在那个目录；
     * 2. **文档树选择器兜底**：ACTION_OPEN_DOCUMENT_TREE 带初始位置 ——
     *    是选择器不是浏览器，但一样能看到目录内容。
     *
     * ## 已知限制（如实回错，不假装成功）
     *
     * Android 11+ 对 `Android/data` 有系统级浏览限制，DocumentsUI 可能
     * 拒绝停靠（本 App 自己的 app-workspace 也在 `Android/data/<pkg>`
     * 下）。两段都失败时回 `ok:false` 让 UI 如实提示，
     * **不许**静默吞掉装作打开了。
     */
    private fun openFolderInFiles(path: String): Map<String, Any?> {
        val file = File(path)
        if (!file.isDirectory) {
            return failure("文件夹不存在：$path")
        }
        // 路径 → (卷 id, 相对路径)：内置存储是 primary，外置卡是其 UUID
        var volume: String? = null
        var rel: String? = null
        for ((prefix, vol) in listOf(
            "/storage/emulated/0" to "primary",
            "/sdcard" to "primary",
        )) {
            if (path == prefix || path.startsWith("$prefix/")) {
                volume = vol
                rel = path.removePrefix(prefix).trim('/')
                break
            }
        }
        if (volume == null && path.startsWith("/storage/")) {
            val rest = path.removePrefix("/storage/")
            val vol = rest.substringBefore('/')
            if (vol.isNotBlank() && vol != "emulated" && vol != "self") {
                volume = vol
                rel = rest.removePrefix(vol).trim('/')
            }
        }
        val v = volume ?: return failure("这个位置不在共享存储里，系统文件打不开：$path")
        val docId = if (rel.isNullOrEmpty()) v else "$v:$rel"

        // 1) DocumentsUI 直达
        try {
            val uri = DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents", docId,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            return mapOf("ok" to true)
        } catch (e: Throwable) {
            // 落到兜底（无处理器 / 系统拒绝都算）
        }

        // 2) 文档树选择器兜底（带初始位置）
        return try {
            val treeUri = DocumentsContract.buildTreeDocumentUri(
                "com.android.externalstorage.documents", docId,
            )
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, treeUri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            mapOf("ok" to true)
        } catch (e: Throwable) {
            failure("没有能打开这个文件夹的文件管理器：${e.message ?: e.javaClass.simpleName}")
        }
    }

    // ------------------------------------------------------------ 选择器

    /**
     * 文件夹选择器 → `{ok, path, name, treeUri}`
     *
     * ## 选中后**顺手登记工作区**
     *
     * 不登记的话 [DeviceFs] 不知道这个路径该走 SAF（`registry.matchSaf` 查不到），
     * 于是后续 `fs.*` 会用 `java.io.File` 撞 `EPERM` —— 那时错误会晚到"构建到一半"。
     * 登记与 MainActivity 的 `pickWorkspace` **共用同一个** [WorkspaceRegistry]，
     * 所以两条通道不会各存一份。
     *
     * ## 取消 / 失败都必须回结果
     *
     * 取消回 `{ok:false, error:"已取消"}`。**不许不回** —— Dart 侧那个 `await`
     * 会永久挂起，界面看起来像"点了没反应"。
     */
    private fun launchFolderPicker(result: MethodChannel.Result) {
        activity.runOnUiThread {
            try {
                folderPicker.launch { ws ->
                    if (ws == null) {
                        reply(result, failure("用户取消，或所选位置没有本地路径（例如网盘）"))
                        return@launch
                    }
                    // ★ 受限目录 / 网盘：选择器会回 `ok:false` + 一句人话 + 出路。
                    //   **原样透传**那句 error（它已写清"为什么"和"下一步"），
                    //   并带上 `suggest` 让 UI 能直接画两个可用按钮。
                    if (ws["ok"] == false) {
                        val reason = (ws["error"] as? String)
                            ?: "这个位置无法用作工作区"
                        val suggest = ws["suggest"]
                        val payload = mutableMapOf<String, Any?>(
                            "ok" to false,
                            "error" to reason,
                        )
                        (ws["reason"] as? String)?.let { payload["reasonCode"] = it }
                        if (suggest is List<*>) payload["suggest"] = suggest
                        reply(result, payload)
                        return@launch
                    }
                    val path = ws["path"] as? String
                    if (path.isNullOrBlank()) {
                        reply(result, failure("所选位置没有本地路径"))
                        return@launch
                    }
                    val name = (ws["name"] as? String).orEmpty().ifBlank { File(path).name }
                    val treeUri = (ws["treeUri"] as? String).orEmpty()
                    // 登记（失败不阻断返回：登记失败 ⇒ 后续 fs.* 会走 POSIX 并如实报 EPERM）
                    scope.launch {
                        val entry = runCatching { registry.add(path, name, treeUri) }.getOrNull()
                        reply(
                            result,
                            mapOf(
                                "ok" to true,
                                "path" to path,
                                "name" to name,
                                "treeUri" to treeUri,
                                // 额外：登记是否成功（Dart 可据此提示；不影响主字段）
                                "registered" to (entry != null),
                            ),
                        )
                    }
                }
            } catch (e: Throwable) {
                reply(result, failure("无法打开文件夹选择器：${e.message}"))
            }
        }
    }

    /**
     * 文件选择器 → `{ok, files:[{path,name,size,mime}]}`
     *
     * ⚠️ **`mime` 是从扩展名推的**，不是 provider 报的真类型 ——
     * [FilePickerBridge] 只回 `path/name/size`（它把内容复制进 cache 就丢了 URI）。
     * 这个字段只用于 UI 图标/分类，不用于任何判定；推不出来时回
     * `application/octet-stream` 而不是猜一个具体类型。
     */
    private fun launchFilePicker(multiple: Boolean, result: MethodChannel.Result) {
        activity.runOnUiThread {
            try {
                filePicker.launch(
                    imagesOnly = false,
                    multiple = multiple,
                    onResult = { list ->
                        // 逐字段取出来再拼 —— 直接在 `mapOf("k" to ...)` 里混用
                        // `as? Number` + elvis，Kotlin 会把元素类型推成 `Serializable`
                        // 而不是 `Pair`，编译期报 "Argument type mismatch"（实测）。
                        val files: List<Map<String, Any?>> = list.map { m ->
                            val name: String = (m["name"] as? String).orEmpty()
                            val size: Long = (m["size"] as? Number)?.toLong() ?: 0L
                            val one: Map<String, Any?> = mutableMapOf(
                                "path" to m["path"],
                                "name" to name,
                                "size" to size,
                                "mime" to mimeOfName(name),
                            )
                            one
                        }
                        reply(result, mapOf("ok" to true, "files" to files))
                    },
                    onError = { msg -> reply(result, failure(msg)) },
                )
            } catch (e: Throwable) {
                reply(result, failure("无法打开文件选择器：${e.message}"))
            }
        }
    }

    /** 从文件名猜 MIME（推不出来就是 octet-stream，**不猜具体类型**）。 */
    private fun mimeOfName(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty()) return "application/octet-stream"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: "application/octet-stream"
    }

    // ------------------------------------------------------------ 参数

    /** 取字符串参数；空白串当作"没给"（Dart 侧 `null` 与 `""` 在这里等价）。 */
    private fun MethodCall.stringArg(name: String): String? =
        argument<String>(name)?.takeIf { it.isNotBlank() }

    /**
     * 取字节参数。
     *
     * Flutter 的 StandardMessageCodec 把 `Uint8List` 解成 `ByteArray`；
     * 但若 Dart 侧不小心传了 `List<int>`，这边也得认（而不是回一句莫名的失败）。
     */
    private fun MethodCall.byteArrayArg(name: String): ByteArray? {
        when (val v = argument<Any>(name)) {
            is ByteArray -> return v
            is IntArray -> return v.map { it.toByte() }.toByteArray()
            is List<*> -> {
                if (v.isEmpty()) return ByteArray(0)
                val out = ByteArray(v.size)
                for (i in v.indices) {
                    val n = v[i] as? Number ?: return null
                    out[i] = n.toByte()
                }
                return out
            }
            else -> return null
        }
    }
}
