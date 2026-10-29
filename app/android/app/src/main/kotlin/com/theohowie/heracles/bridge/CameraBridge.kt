package com.theohowie.heracles.bridge

import android.app.Activity
import android.content.ComponentName
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.util.Log
import android.provider.MediaStore
import android.provider.OpenableColumns
import java.io.File
import java.io.FileOutputStream

/**
 * 系统相机拍照 —— **零第三方依赖**，与 [FilePickerBridge] 同一套
 * 经典 startActivityForResult 模式（见那边的说明：androidx.activity
 * 不在编译期 classpath 上）。
 *
 * ## 为什么不用 FileProvider
 *
 * 给相机 intent 传 EXTRA_OUTPUT 需要一个相机 App 能写的 URI。
 * FileProvider 要 androidx.core 在编译期可见，没把握；改走
 * **MediaStore 插入**：先向系统相册申请一个空的图片条目拿到
 * content:// URI，相机直接写进去 —— 不需要 FileProvider
 * （API 29+ 分区存储下 insert 自己的条目免存储权限；低版本
 * 用 DATA 指向 App 私有外部目录，同样免权限）。注意相机
 * **权限**是另一回事：个别 ROM 的相机入口要求调用方持有
 * CAMERA 权限，见文末第二轮真机结论。拍完把内容复制进
 * cache/attachments，
 * 回与 [FilePickerBridge] 同形状的 {path, name, size}，
 * 前端当普通图片附件走既有管线。
 *
 * 用户取消时把预留的空条目删掉，不在相册里留空壳。
 *
 * ## 拉起相机的多级兜底（2026-10-29 真机实报后补）
 *
 * 第一版只发一条隐式 ACTION_IMAGE_CAPTURE＋EXTRA_OUTPUT，在
 * Redmi K60（HyperOS）上 startActivityForResult 直接抛异常，
 * 界面报「没有可用的相机应用」—— 但机器明明有相机。抛的到底
 * 是什么异常，第一版 catch 后全压成一句话，无从判断（疑似
 * EXTRA_OUTPUT 的 URI 授权标志与该 ROM 的校验不合）。
 * 现在按成功率从高到低逐级试，每级失败都留痕：
 *
 * 1. 隐式 intent ＋ EXTRA_OUTPUT ＋ 读写授权标志
 * 2. 隐式 intent ＋ EXTRA_OUTPUT（去掉授权标志）
 * 3. 显式 intent（按 queryIntentActivities 枚举到的相机组件）
 *    ＋ EXTRA_OUTPUT ＋ 授权标志 —— 需要 Manifest 里
 *    `<queries>` 声明 IMAGE_CAPTURE，包可见性才放行枚举
 * 4. 裸 intent（无 EXTRA_OUTPUT，结果走 data 里的缩略图 ——
 *    分辨率低，但至少能拍到）
 * 5. 显式组件 ＋ 裸 intent
 *
 * 全部失败时错误信息带上最后一次异常的类名与消息，
 * 不再把所有失败都说成「没有相机应用」。
 *
 * **第二轮真机结论（2026-10-29 09:48）**：兜底链跑通后错误
 * 摘要实锤了根因 —— SecurityException: Permission Denial …
 * with revoked permission android.permission.CAMERA。这个 ROM
 * 的相机入口要求调用方持有 CAMERA 权限，「委托系统相机就不用
 * 本 App 授权」的假设在这台机器上不成立。正解在 Dart 侧：
 * 点拍照前先查 devicePermissions，未授权先 requestPermission
 * 拉起系统申请（权限页的相机行是同一条链）。本类只负责把
 * 漏网的权限型失败翻成人话。
 */
class CameraBridge(private val activity: Activity) {

    /** 逐级兜底时最后一次启动异常的摘要，进最终错误信息。 */
    private var lastStartError: String? = null

    // ⚠️ 下面的 pending 状态**必须是 companion（进程级静态）**，不能是实例字段。
    //
    // ## 真机 bug（2026-10-29 用户报「点了 √ 就返回主页了，输入框里没图片」）
    //
    // 系统相机在前台时，本 Activity 很容易被系统回收重建（MIUI 上尤其明显，
    // 用户看到的是"返回主页/闪一下"）。重建后 `configureFlutterEngine` 会
    // **新建一个 CameraBridge**；若 pending 回调是实例字段，新实例里它是 null
    // ⇒ `onActivityResult` 拿到了照片却**没有收件人** ⇒ 照片被静默丢弃。
    //
    // 放进 companion 后：重建前后的实例共享同一份 pending 状态，
    // 新实例的 `onActivityResult` 仍能把结果交回原来的 MethodChannel 回调。
    companion object {
        const val REQUEST_CODE = 0x4843  // 'HC'

        @Volatile
        private var pendingResult: ((Map<String, Any?>?) -> Unit)? = null

        @Volatile
        private var pendingError: ((String) -> Unit)? = null

        @Volatile
        private var pendingUri: Uri? = null

        @Volatile
        private var pendingName: String? = null

        /** 当前这次拍照是否走缩略图模式（无 EXTRA_OUTPUT）。 */
        @Volatile
        private var pendingThumbnail = false
    }

    /** 拉起系统相机。全部路径都失败时走 onError（带异常摘要）。 */
    fun launch(
        onResult: (Map<String, Any?>?) -> Unit,
        onError: (String) -> Unit,
    ) {
        pendingResult = onResult
        pendingError = onError
        lastStartError = null

        val name = "IMG_${System.currentTimeMillis()}.jpg"

        // ★★ 2026-10-29 真机实测后的**路径顺序翻转** ★★
        //
        // 本机（Redmi K60 / HyperOS）的系统相机对 `EXTRA_OUTPUT` 完全不理：
        //   · 我们插入的 MediaStore 待定条目在返回后被丢弃（8494/8495/8497/8498 全没了）
        //   · 重试 4×350ms 读不到一个字节
        //   · 相册里也没有新照片 ⇒ **照片压根没产生**
        // 而**不带 EXTRA_OUTPUT 的裸 intent** 是真机上唯一带回数据的方式：
        //     18:01:51  onActivityResult req=18499 res=0 **data=true**  ← Bitmap 在 extras 里
        //
        // 所以：**优先走裸 intent（缩略图模式）**，拿 data 里的 Bitmap 存成文件。
        // 代价是分辨率低（相机给的缩略图级别）；要高清得改 CameraX 应用内拍照，
        // 那是后续独立任务 —— 先让"拍照能进输入框"这件事真的可用。
        if (tryStart(Intent(MediaStore.ACTION_IMAGE_CAPTURE))) {
            pendingThumbnail = true
            pendingUri = null
            pendingName = name
            Log.i("CameraBridge", "走裸 intent（缩略图模式）—— 本机唯一可靠路径")
            return
        }

        val uri = insertPendingImage(name)

        if (uri != null) {
            // 1/2 级：隐式 intent 带 EXTRA_OUTPUT
            if (tryStart(captureIntent(uri, withGrant = true)) ||
                tryStart(captureIntent(uri, withGrant = false))
            ) {
                pendingUri = uri
                pendingName = name
                pendingThumbnail = false
                return
            }
            // 3 级：显式组件带 EXTRA_OUTPUT
            for (component in captureComponents()) {
                val intent = captureIntent(uri, withGrant = true)
                    .setComponent(component)
                if (tryStart(intent)) {
                    pendingUri = uri
                    pendingName = name
                    pendingThumbnail = false
                    return
                }
            }
            // 带输出的路径全灭 —— 预留条目删掉，别在相册留空壳
            runCatching {
                activity.contentResolver.delete(uri, null, null)
            }
        }

        // 4 级：裸 intent 走缩略图
        if (tryStart(Intent(MediaStore.ACTION_IMAGE_CAPTURE))) {
            pendingThumbnail = true
            return
        }
        // 5 级：显式组件裸 intent
        for (component in captureComponents()) {
            val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
                .setComponent(component)
            if (tryStart(intent)) {
                pendingThumbnail = true
                return
            }
        }

        clearPending()
        // 权限型失败单独说人话（2026-10-29 第二轮真机实证）：
        // HyperOS 的相机入口（com.android.camera/.OneShotImage
        // Capture）要求调用方持有 CAMERA 权限，没授权时每一级
        // 都抛 SecurityException…revoked permission CAMERA。
        // Dart 侧点拍照前已先走申请链，这里是兜底口径。
        val err = lastStartError
        if (err != null &&
            err.contains("SecurityException") &&
            err.contains("CAMERA")
        ) {
            onError("相机权限未开启：请允许相机权限后再点一次拍照")
        } else {
            onError(
                "无法打开相机" +
                    (err?.let { "（$it）" } ?: ""),
            )
        }
    }

    /** 用户取消拍照 —— 删掉预留空条目并回 null（不是错误）。 */
    fun onCancelled() {
        deletePending()
        val r = pendingResult
        clearPending()
        r?.invoke(null)
    }

    /** 相机带结果返回时调这里；[data] 供缩略图模式取图。 */
    fun onActivityResult(data: Intent?) {
        // ★ 2026-10-29 埋点：先证明"回调到底有没有到"（没日志只能猜）
        Log.i("CameraBridge", "onActivityResult 进入: uri=$pendingUri name=$pendingName thumb=$pendingThumbnail hasResult=${pendingResult != null} data=${data != null}")
        val result = pendingResult
        val error = pendingError
        val uri = pendingUri
        val name = pendingName
        val thumbnail = pendingThumbnail
        clearPending()

        if (result == null) return

        // ★★ 2026-10-29 真机结论：本机（MIUI）相机**完全不写 EXTRA_OUTPUT**。
        //
        // 证据链：
        //   · 我插入的 pending 条目（media/8494/8495/8497）在返回后**全部消失**
        //   · 相册里最新照片是旧的 Download/MiShare 文件，不是这次拍的
        //   · 重试 4 次 × 350ms 读取都拿不到一个字节
        //   ⇒ 不是"写了读不到"，是**照片压根没产生**。
        //
        // 唯一真正"带数据回来"的是**缩略图模式**（无 EXTRA_OUTPUT）：
        //     18:01:51  onActivityResult req=18499 res=0 data=true
        //
        // 所以：**只要返回的 Intent 里带 Bitmap 就直接用它** —— 不管 resultCode，
        // 也不管当初走的是哪条启动路径。
        val bmpAny = runCatching {
            @Suppress("DEPRECATION")
            data?.extras?.get("data") as? Bitmap
        }.getOrNull()
        if (bmpAny != null) {
            Log.i("CameraBridge", "回调里带 Bitmap（缩略图模式）: ${bmpAny.width}x${bmpAny.height}")
            val saved = saveThumbnail(bmpAny, name)
            if (saved == null) error?.invoke("拍到的照片保存失败") else result(saved)
            return
        }

        if (thumbnail) {
            // 裸 intent 的图在返回 intent 的 "data" extra 里（Bitmap）
            val bmp = runCatching {
                @Suppress("DEPRECATION")
                data?.extras?.get("data") as? Bitmap
            }.getOrNull()
            if (bmp == null) {
                error?.invoke("相机没有返回照片")
                return
            }
            val saved = saveThumbnail(bmp, name)
            if (saved == null) {
                error?.invoke("拍到的照片保存失败")
            } else {
                result(saved)
            }
            return
        }

        if (uri == null) {
            result(null)
            return
        }
        try {
            // ★ 2026-10-29：**按"URI 里到底有没有内容"判定**，不看 resultCode。
            //
            // 真机日志证明 MIUI 相机拍完后回 RESULT_CANCELED（res=0），
            // 所以"取消"与"拍到"必须靠内容区分：
            //   · 有内容 → 就是拍到了，照常交付
            //   · 空/读不到 → 才算用户取消（`result(null)`，不报错）
            //
            // 判定同时做一次 IS_PENDING 归零：否则照片只在 App 里能看，
            // 相册里永远"还在处理中"。
            // ★★ 2026-10-29 第二次纠错：**判据必须"真去读字节"** ★★
            //
            // 上一版我用 `openAssetFileDescriptor(uri,"r").length` 判空，结果真机日志是：
            //     结果 URI 内容长度=-1
            //     按取消处理：URI 无内容
            // 而 -1 在 Android 里是 `AssetFileDescriptor.UNKNOWN_LENGTH` ——
            // **不是"空"，是"长度未知"**（content URI 常见）。照片明明拍到了
            // （media id 8494），却被我判成取消、还**把媒体库条目删了**（数据丢失，我的错）。
            //
            // 现在的判据只有一条：`copyToCache` 能不能把字节真的读出来。
            //   · 读到 ⇒ 拍到了，交付
            //   · 读不到 ⇒ 按取消处理，**绝不删除**用户媒体库里的任何条目
            //
            // ★ 2026-10-29 真机第三次纠错：**相机返回那一刻文件可能还没落完**。
            //
            // 实测（点完 ✓ 之后）：
            //     HeraclesAct: onActivityResult req=18499 res=0
            //     CameraBridge: 读不到 URI 内容，按取消处理: media/8495
            // 照片确实在 MediaStore 里（有 id），但立刻读会拿到 0 字节 ——
            // MIUI 是先回包、后 flush。所以**重试几次**再判取消。
            var copied: Map<String, Any?>? = null
            for (attempt in 1..4) {
                copied = copyToCache(uri, name)
                if (copied != null) {
                    if (attempt > 1) {
                        Log.i("CameraBridge", "第 $attempt 次读取成功（前面是文件没落完）")
                    }
                    break
                }
                Log.w("CameraBridge", "第 $attempt 次读不到 URI 内容: $uri")
                if (attempt < 4) Thread.sleep(350)
            }
            if (copied == null) {
                Log.w("CameraBridge", "重试 4 次仍读不到，按取消处理（不删媒体库条目）: $uri")
                result(null)
                return
            }
            Log.i("CameraBridge", "拍照成功: ${copied["path"]}")
            result(copied)
        } catch (e: Throwable) {
            error?.invoke(e.message ?: e.javaClass.simpleName)
        }
    }

    /** 组一条带 EXTRA_OUTPUT 的拍照 intent。 */
    private fun captureIntent(uri: Uri, withGrant: Boolean): Intent =
        Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            if (withGrant) {
                addFlags(
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
        }

    /** 试着拉起一个拍照 intent；失败记摘要、回 false 让上层换下一级。 */
    private fun tryStart(intent: Intent): Boolean = try {
        activity.startActivityForResult(intent, REQUEST_CODE)
        true
    } catch (e: Throwable) {
        // ★ 2026-10-29 埋点：把真实异常打出来（第一版全压成一句话，无从判断）
        Log.w("CameraBridge", "startActivityForResult 失败: ${e.javaClass.simpleName}: ${e.message}")
        lastStartError = "${e.javaClass.simpleName}: ${e.message ?: ""}"
            .trimEnd(':', ' ')
        false
    }

    /**
     * 枚举能处理拍照的组件（显式启动用）。靠 Manifest 的
     * `<queries>` 声明放行包可见性；枚举不到就返回空表，
     * 显式那两级自动跳过。
     */
    private fun captureComponents(): List<ComponentName> = runCatching {
        val probe = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
        @Suppress("DEPRECATION")
        activity.packageManager
            .queryIntentActivities(probe, PackageManager.MATCH_ALL)
            .map { ComponentName(it.activityInfo.packageName, it.activityInfo.name) }
    }.getOrDefault(emptyList())

    /** 缩略图模式：把 Bitmap 存成 JPEG 进 cache/attachments。 */
    private fun saveThumbnail(
        bmp: Bitmap,
        fallbackName: String?,
    ): Map<String, Any?>? = runCatching {
        val name = fallbackName ?: "photo_${System.currentTimeMillis()}.jpg"
        val dir = File(activity.cacheDir, "attachments").apply { mkdirs() }
        val target = File(dir, "${System.currentTimeMillis()}_$name")
        FileOutputStream(target).use { out ->
            bmp.compress(Bitmap.CompressFormat.JPEG, 92, out)
        }
        if (target.length() <= 0L) return null
        mapOf(
            "path" to target.absolutePath,
            "name" to name,
            "size" to target.length(),
        )
    }.getOrNull()

    private fun clearPending() {
        pendingResult = null
        pendingError = null
        pendingUri = null
        pendingName = null
        pendingThumbnail = false
    }

    private fun deletePending() {
        val uri = pendingUri ?: return
        runCatching { activity.contentResolver.delete(uri, null, null) }
    }

    /**
     * 向 MediaStore 申请一个待写入的图片条目。
     * API 29+：RELATIVE_PATH 到 Pictures/Heracles，免权限；
     * 更低版本：DATA 指向 App 私有外部目录文件，同样免权限。
     */
    private fun insertPendingImage(name: String): Uri? = runCatching {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= 29) {
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "Pictures/Heracles",
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            } else {
                val dir = File(
                    activity.getExternalFilesDir("Pictures"), "Heracles",
                ).apply { mkdirs() }
                @Suppress("DEPRECATION")
                put(MediaStore.Images.Media.DATA, File(dir, name).absolutePath)
            }
        }
        activity.contentResolver.insert(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values,
        )
    }.getOrNull()

    /** 拍完把 MediaStore 里的内容复制进 cache/attachments（同 FilePickerBridge 口径） */
    private fun copyToCache(uri: Uri, fallbackName: String?): Map<String, Any?>? =
        runCatching {
            val resolver = activity.contentResolver

            // 解除 pending，照片正式进相册
            if (Build.VERSION.SDK_INT >= 29) {
                val done = ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                }
                runCatching { resolver.update(uri, done, null, null) }
            }

            val name = queryDisplayName(uri) ?: fallbackName
                ?: "photo_${System.currentTimeMillis()}.jpg"
            val dir = File(activity.cacheDir, "attachments").apply { mkdirs() }
            val target = File(dir, "${System.currentTimeMillis()}_$name")

            resolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            if (target.length() <= 0L) return null

            mapOf(
                "path" to target.absolutePath,
                "name" to name,
                "size" to target.length(),
            )
        }.getOrNull()

    private fun queryDisplayName(uri: Uri): String? = runCatching {
        activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
        }
    }.getOrNull()
}
