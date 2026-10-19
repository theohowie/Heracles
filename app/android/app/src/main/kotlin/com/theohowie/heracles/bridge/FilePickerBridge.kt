package com.theohowie.heracles.bridge

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File

/**
 * 原生文件选择器 —— **零第三方依赖**。
 *
 * ## 为什么不用 file_picker
 *
 * `file_picker` 的 `android/build.gradle` 写死了 `compileSdk 34`，
 * 而它的传递依赖 `flutter_plugin_android_lifecycle` 要求**所有消费者**
 * 都 compile against ≥ 36 —— 两者冲突会**直接让整个构建失败**：
 *
 * ```
 * :file_picker is currently compiled against android-34
 * :flutter_plugin_android_lifecycle requires ... version 36 or later
 * ```
 *
 * 实测 `file_picker` 8.3.7 与 9.2.3 都如此（截至 2026-10）。
 * 而调 Android 自带的 SAF（Storage Access Framework）只需这段代码。
 *
 * ## 为什么要把 content:// 复制到缓存
 *
 * SAF 返回的是 `content://` URI，**不是文件路径**。
 * 而我们的 `:workspace` 模块用普通 `java.io.File` 读文件 ——
 * 无法直接读 URI。所以选中后**复制一份到应用缓存**，
 * 拿到真实路径再交给 agent。
 *
 * 代价是占一份磁盘空间；收益是整条链路只用一种 IO 抽象。
 * 附件用完（发送完）应当清理，见 [clearCache]。
 */
class FilePickerBridge(private val activity: Activity) {

    private var pendingResult: ((List<Map<String, Any?>>) -> Unit)? = null
    private var pendingError: ((String) -> Unit)? = null

    /**
     * 请求码 —— 与 MainActivity.onActivityResult 约定。
     */
    companion object {
        const val REQUEST_CODE = 0x4845  // 'HE'
    }

    /**
     * 拉起系统选择器。
     *
     * ⚠️ 用经典的 startActivityForResult 而不是 egisterForActivityResult：
     * 后者需要 ndroidx.activity 依赖，而 Flutter 的 embedding 没有
     * 把它暴露到编译期 classpath（实测 Unresolved reference）。
     * FlutterActivity 自带 onActivityResult 转发，够用。
     *
     * @param imagesOnly true = 只选图片（相册），false = 任意文件
     */
    fun launch(
        imagesOnly: Boolean,
        multiple: Boolean,
        onResult: (List<Map<String, Any?>>) -> Unit,
        onError: (String) -> Unit,
    ) {
        pendingResult = onResult
        pendingError = onError

        val mime = if (imagesOnly) "image/*" else "*/*"
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
        }
        activity.startActivityForResult(intent, REQUEST_CODE)
    }

    /** 用户取消选择 —— 必须回空列表，否则 Dart 侧会一直等待 */
    fun onCancelled() {
        val r = pendingResult
        pendingResult = null
        pendingError = null
        r?.invoke(emptyList())
    }

    /** 系统选择器带结果返回时调这里 */
    fun onActivityResult(data: Intent?) {
        val result = pendingResult
        val error = pendingError
        pendingResult = null
        pendingError = null

        if (result == null) return

        try {
            val uris = mutableListOf<Uri>()
            if (data?.clipData != null) {
                val clip = data.clipData!!
                for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
            } else if (data?.data != null) {
                uris.add(data.data!!)
            }

            if (uris.isEmpty()) {
                result(emptyList())
                return
            }

            val out = uris.mapNotNull { copyToCache(it) }
            result(out)
        } catch (e: Throwable) {
            error?.invoke(e.message ?: e.javaClass.simpleName)
        }
    }

    /**
     * 把 `content://` 复制到应用缓存，返回 {path, name, size}。
     *
     * 复制失败（权限、空间不足）时返回 null 而不是抛 ——
     * 一个文件失败不该让整批选择失败。
     */
    private fun copyToCache(uri: Uri): Map<String, Any?>? = runCatching {
        val resolver = activity.contentResolver
        val name = queryDisplayName(uri) ?: "file_${System.currentTimeMillis()}"

        val dir = File(activity.cacheDir, "attachments").apply { mkdirs() }
        // 用时间戳前缀避免同名覆盖；保留原名便于识别
        val target = File(dir, "${System.currentTimeMillis()}_$name")

        resolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        } ?: return null

        mapOf(
            "path" to target.absolutePath,
            "name" to name,
            "size" to target.length(),
        )
    }.getOrNull()

    /** 从 ContentResolver 查真实文件名（SAF 的 URI 不暴露文件名） */
    private fun queryDisplayName(uri: Uri): String? = runCatching {
        activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        }
    }.getOrNull()

    /**
     * 清理已发送的附件缓存。
     *
     * 不清理会让缓存目录无限增长 —— 用户每选一次文件就留一份副本。
     */
    fun clearCache() {
        runCatching {
            File(activity.cacheDir, "attachments").listFiles()?.forEach { it.delete() }
        }
    }
}
