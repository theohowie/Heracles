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
 * ---------------------------------------------------------------------------
 * 移植来源
 * ---------------------------------------------------------------------------
 * 上游：baicodex (mubai0122/baicodex) @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95
 *   原文件：app/src/main/kotlin/b/ai/exec/FileOps.kt
 *           （readJava / writeJava 的打开方式与二进制判据；本类的 openFile 沿用）
 *
 * ★ 本类**没有直接上游**：baicodex 用 File 路径直接读写，不暴露 ContentProvider。
 *   新增它的理由是 taixu 的沙箱在**另一个进程**（sandbox-app 的 :sandbox 进程）
 *   里执行 build，而宿主（Agent 前端）需要把产物交出去给系统（PackageInstaller、
 *   分享 intent、外部分发）。Android 的做法就是 `content://` + FLAG_GRANT_READ_URI_PERMISSION。
 *
 *   因此本文件的设计目标是：**把任意 HostPath 变成一个可安全授予的 content:// URI**，
 *   同时不因为「路径可以任意拼」而变成一条越权读取通道 —— 见 [allowedRoots]。
 */

package com.heracles.sandbox.file

import android.content.ContentProvider
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.util.Base64
import java.io.File
import java.io.FileNotFoundException

/**
 * 跨进程文件访问的 ContentProvider。
 *
 * ============================================================================
 * 使用方式
 * ============================================================================
 * ```
 * // 写侧（沙箱进程）
 * val uri = SandboxFileProvider.uriFor(HostPath.parse("/sdcard/Download/a.apk"))
 * context.grantUriPermission(hostPkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
 *
 * // 读侧（宿主 / 系统）
 * contentResolver.openInputStream(uri)
 * ```
 *
 * 路径**不做明文拼接**：URI 的 lastPathSegment 是路径的 Base64url 编码。
 * 这样既避开了零宽字符（`\u200b`）在 URI 里被规范化掉的问题，
 * 也让「路径里带 `..`」这种注入在解析阶段就失败，而不是靠字符串过滤。
 *
 * ============================================================================
 * 安全模型（三道闸，缺一不可）
 * ============================================================================
 * 1. **exported=false + grantUriPermissions=true**（见本模块 AndroidManifest.xml）：
 *    别的应用不能直接枚举本 provider，只能读宿主**显式授予**的那一个 URI。
 * 2. **白名单根**（[allowedRoots]）：即使拿到了 URI，也只能访问注册过的根之下的路径。
 *    默认一个都不允许 —— 必须由宿主（或 provider 自己）显式 [addAllowedRoot]。
 * 3. **`..` 折叠 + isUnder 复核**：[HostPath.parse] 已挡掉越界 `..`，
 *    这里再用 `isUnder` 复核一次，防止将来有人绕过 parse。
 *
 * **本 provider 不做权限决策**：它只管「这个 URI 指向的文件在不在这台设备上、
 * 当前身份能不能打开」。是否该授予某个 URI 给某个应用，是宿主的事。
 */
class SandboxFileProvider : ContentProvider() {

    /**
     * 允许通过本 provider 暴露的宿主根目录白名单。
     *
     * <p>默认空 —— 一个文件都访问不了，直到 [addAllowedRoot] 被调用。
     * 这个默认值是刻意的：一个「默认就能读全盘」的 provider 是安全问题，
     * 不是一个便利功能。
     */
    private val allowedRoots = mutableSetOf<HostPath>()

    override fun onCreate(): Boolean = true

    override fun attachInfo(context: Context?, info: ProviderInfo?) {
        super.attachInfo(context, info)
        // 不在这里加任何默认根：白名单必须由宿主显式声明。
    }

    /**
     * 加一个允许暴露的根目录。
     *
     * <p>典型用法（宿主在 Application.onCreate 里）：
     * - `addAllowedRoot(HostPath.parse(context.filesDir.absolutePath))`
     * - `addAllowedRoot(HostPath.parse("/sdcard/Download"))`
     *
     * @return 是否成功加入（路径非法时 false）
     */
    fun addAllowedRoot(root: HostPath): Boolean = synchronized(allowedRoots) {
        allowedRoots.add(root)
    }

    /** 清空白名单（测试用）。 */
    fun clearAllowedRoots() = synchronized(allowedRoots) {
        allowedRoots.clear()
    }

    /** 当前白名单（快照）。 */
    fun allowedRoots(): List<HostPath> = synchronized(allowedRoots) { allowedRoots.toList() }

    // ── 读：openFile ────────────────────────────────────────────────────

    /**
     * 打开文件描述符。
     *
     * <p>支持 `"r"` / `"w"` / `"wt"` / `"wa"` / `"rw"` / `"rwt"`（[ParcelFileDescriptor] 的
     * 标准 mode 串）。写模式会建父目录（与 [SandboxFileService] 的行为一致）。
     *
     * @throws FileNotFoundException 路径不在白名单内 / 文件不存在 / 无权限
     */
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val path = resolveUri(uri) ?: throw FileNotFoundException("无法解析路径（或不在白名单内）：$uri")
        val file = File(path.value)

        val wantsWrite = mode.contains('w') || mode.contains('a') || mode.contains('+')
        if (wantsWrite) {
            file.parentFile?.mkdirs()
        } else if (!file.exists()) {
            throw FileNotFoundException("文件不存在：${path.value}")
        }
        // 统一转成 ParcelFileDescriptor 的规范 mode 串，避免把任意字符串透传给底层的 open()
        val normalizedMode = when {
            mode.contains("rwt") -> ParcelFileDescriptor.MODE_READ_WRITE or
                ParcelFileDescriptor.MODE_TRUNCATE
            wantsWrite && mode.contains('a') -> ParcelFileDescriptor.MODE_WRITE_ONLY or
                ParcelFileDescriptor.MODE_APPEND or ParcelFileDescriptor.MODE_CREATE
            wantsWrite && mode.contains('t') -> ParcelFileDescriptor.MODE_WRITE_ONLY or
                ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_CREATE
            wantsWrite -> ParcelFileDescriptor.MODE_WRITE_ONLY or ParcelFileDescriptor.MODE_CREATE
            mode.contains('+') -> ParcelFileDescriptor.MODE_READ_WRITE
            else -> ParcelFileDescriptor.MODE_READ_ONLY
        }
        return try {
            ParcelFileDescriptor.open(file, normalizedMode)
        } catch (e: FileNotFoundException) {
            throw e
        } catch (t: Throwable) {
            throw FileNotFoundException("打开失败：${t.javaClass.simpleName}: ${t.message}（${path.value}）")
        }
    }

    // ── 查：query 只用于 openable columns ──────────────────────────────

    /**
     * 只支持 [OpenableColumns]（`DISPLAY_NAME` / `SIZE`）与 [FileColumns]。
     *
     * <p>不支持任意 projection —— provider 不是数据库，接受任意列名只会
     * 让调用方以为能查别的东西。
     */
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val path = resolveUri(uri) ?: return null
        val file = File(path.value)
        if (!file.exists()) return null

        val columns = (projection?.toList() ?: DEFAULT_COLUMNS).filter { it in KNOWN_COLUMNS }
        val cursor = MatrixCursor(columns.toTypedArray(), 1)
        // 显式声明元素类型为 Any?：各列的类型不同（String / Long / null），
        // 让推导成 Comparable & Serializable 的交集会触发 KT-71420（未来版本直接报错）。
        val row: List<Any?> = columns.map { column ->
            when (column) {
                OpenableColumns.DISPLAY_NAME -> file.name
                OpenableColumns.SIZE -> if (file.isDirectory) 0L else file.length()
                FileColumns.IS_DIRECTORY -> if (file.isDirectory) 1L else 0L
                FileColumns.LAST_MODIFIED -> file.lastModified()
                FileColumns.ABSOLUTE_PATH -> path.value
                else -> null
            }
        }
        cursor.addRow(row.toTypedArray())
        return cursor
    }

    // ── 写：insert / delete / update ───────────────────────────────────

    /**
     * 支持两种写法：
     * 1. `insert(uriFor(文件), values)` —— 建一个空文件（或目录，若 [FileColumns.IS_DIRECTORY]=1）
     * 2. `insert(CONTENT_URI, values)` —— values 里必须带 [FileColumns.ABSOLUTE_PATH]
     *
     * <p>内容请走 [openFile] 的写模式：ContentValues 不适合塞二进制大块内容。
     */
    override fun insert(uri: Uri, values: ContentValues?): Uri? {
        val target = resolveUri(uri) ?: values?.getAsString(FileColumns.ABSOLUTE_PATH)
            ?.let { HostPath.parseOrNull(it) }
            ?: return null
        if (!isAllowed(target)) return null

        val file = File(target.value)
        val wantsDirectory = values?.getAsInteger(FileColumns.IS_DIRECTORY) == 1
        val created = try {
            if (wantsDirectory) file.mkdirs() else {
                file.parentFile?.mkdirs()
                file.createNewFile()
            }
        } catch (t: Throwable) {
            false
        }
        return if (created || file.exists()) uriFor(target) else null
    }

    /** 删除文件/目录。目录只删空目录（不做递归删除：递归删除是个太危险的原语）。 */
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
        val path = resolveUri(uri) ?: return 0
        val file = File(path.value)
        if (!file.exists()) return 0
        return if (file.delete()) 1 else 0
    }

    /** 只支持改 `lastModified`（其余列不敢支持：那会让 provider 变成任意文件改写面）。 */
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int {
        val path = resolveUri(uri) ?: return 0
        val file = File(path.value)
        if (!file.exists()) return 0
        val modified = values?.getAsLong(FileColumns.LAST_MODIFIED) ?: return 0
        return if (file.setLastModified(modified)) 1 else 0
    }

    /** 固定 MIME：不试图猜（猜错会让系统用错的应用打开文件）。 */
    override fun getType(uri: Uri): String {
        val path = resolveUri(uri) ?: return MIME_UNKNOWN
        return if (File(path.value).isDirectory) MIME_DIRECTORY else MIME_UNKNOWN
    }

    /** 只认 `file` 这一个路径段；别的前缀一律拒绝。 */
    private fun resolveUri(uri: Uri): HostPath? {
        if (uri.authority != AUTHORITY) return null
        val segments = uri.pathSegments
        if (segments.isEmpty() || segments[0] != PATH_FILES) return null
        val encoded = segments.getOrNull(1) ?: return null
        val decoded = decodePath(encoded) ?: return null
        return if (isAllowed(decoded)) decoded else null
    }

    /** 白名单复核：必须在某个已注册根之下。 */
    private fun isAllowed(path: HostPath): Boolean = synchronized(allowedRoots) {
        allowedRoots.any { path.isUnder(it) }
    }

    companion object {
        /**
         * 本 provider 的 authority。
         *
         * <p>**这是契约的一部分**，与 `sandbox-file/src/main/AndroidManifest.xml` 里的
         * `android:authorities` 必须一致。改动它会让所有已持久化的 URI 失效。
         */
        const val AUTHORITY: String = "com.heracles.sandbox.file.provider"

        /** `content://authority/file/<base64url>`。 */
        const val PATH_FILES: String = "file"

        private const val MIME_UNKNOWN = "application/octet-stream"
        private const val MIME_DIRECTORY = "vnd.android.document/directory"

        /** 默认返回的列（都是 [OpenableColumns] / [FileColumns] 里的标准列）。 */
        private val DEFAULT_COLUMNS = listOf(
            OpenableColumns.DISPLAY_NAME,
            OpenableColumns.SIZE,
            FileColumns.IS_DIRECTORY,
            FileColumns.LAST_MODIFIED,
        )

        private val KNOWN_COLUMNS = DEFAULT_COLUMNS + FileColumns.ABSOLUTE_PATH

        /** root URI。 */
        @JvmField
        val CONTENT_URI: Uri = Uri.parse("content://$AUTHORITY")

        /**
         * 把宿主路径编码成 content URI。
         *
         * <p>用 Base64url + 去掉 padding：URL-safe、无歧义、能承载零宽字符与中文。
         * 不直接拼路径的原因见类 KDoc。
         */
        fun uriFor(path: HostPath, authority: String = AUTHORITY): Uri {
            val encoded = Base64.encodeToString(
                path.value.toByteArray(Charsets.UTF_8),
                Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
            )
            return Uri.parse("content://$authority/$PATH_FILES/$encoded")
        }

        /** [uriFor] 的逆运算；不是本 provider 的 URI 或解码失败时返回 null。 */
        fun hostPathOf(uri: Uri, authority: String = AUTHORITY): HostPath? {
            if (uri.authority != authority) return null
            val segments = uri.pathSegments
            if (segments.size != 2 || segments[0] != PATH_FILES) return null
            return decodePath(segments[1])
        }

        private fun decodePath(encoded: String): HostPath? = try {
            val bytes = Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            HostPath.parseOrNull(String(bytes, Charsets.UTF_8))
        } catch (t: Throwable) {
            // 非法 Base64 / 非法路径：一律当成「没有这个 URI」，不要试图猜测。
            null
        }

        /** 带 id 的 URI（当前只用于 insert 的返回值形态）。 */
        fun withId(id: Long): Uri = ContentUris.withAppendedId(CONTENT_URI, id)
    }

    /**
     * 本 provider 支持的附加列。
     *
     * <p>不用 `android.provider.MediaStore` 里的同名常量：那会引入一份
     * 与媒体库无关的语义，且 MediaStore 的列在不同 API 上会变。
     */
    object FileColumns {
        /** 相对磁盘的绝对路径（只在 [FileColumns] 里用于 insert 的参数，query 也会返回）。 */
        const val ABSOLUTE_PATH: String = "absolute_path"

        /** 1 = 目录，0 = 普通文件。 */
        const val IS_DIRECTORY: String = "is_directory"

        /** 最后修改时间（毫秒）。 */
        const val LAST_MODIFIED: String = "last_modified"
    }
}
