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
 */

package com.heracles.sandbox.file

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException

/**
 * [SafDocumentIo] 的**真实实现**（用 `DocumentsContract` + `ContentResolver`）。
 *
 * ============================================================================
 * 为什么这一步必须用 SAF，而不是拼物理路径
 * ============================================================================
 * Android 10+ 起应用不能直接按物理路径访问别的应用的目录；
 * Android 13+ 对 `/Android/data` 进一步封锁。
 * 用户通过 `ACTION_OPEN_DOCUMENT_TREE` 授权的 tree URI 才是**合法入口**。
 *
 * 硬把 SAF URI 转成 `/storage/...` 物理路径会在新系统上直接失效 ——
 * 所以 [com.heracles.sandbox.file.MountResolver] 对 `SAF_TREE` 后端
 * **永不**产出物理路径，只产出 SAF 文档引用。
 *
 * ============================================================================
 * 授权流程（宿主侧做，不在本类里）
 * ============================================================================
 * ```
 * 1. 用户点「选择目录」→ ACTION_OPEN_DOCUMENT_TREE
 *    （Intent 必须带 FLAG_GRANT_READ_URI_PERMISSION | FLAG_GRANT_WRITE_URI_PERMISSION
 *      并在 onActivityResult 里拿 data.data）
 * 2. contentResolver.takePersistableUriPermission(
 *        uri, FLAG_GRANT_READ_URI_PERMISSION or FLAG_GRANT_WRITE_URI_PERMISSION)
 *    ← 没有这一步，**设备重启后授权就没了**
 * 3. MountRegistry.register(MountEntry(backend = SAF_TREE, treeUri = uri.toString(), ...))
 * ```
 * 之后设备重启仍然可用（持久化授权），不需要用户重新选目录。
 *
 * ============================================================================
 * 子路径解析
 * ============================================================================
 * `DocumentsContract` 只能按 **documentId** 定位，不能直接按相对路径。
 * 所以这里逐级 `findDocumentId` 下钻：`a/b/c.txt` →
 * 在 tree 根下找 `a` → 在 `a` 下找 `b` → …。
 * 段数一般很少（模型不会给超深路径），逐级查找足够。
 */
class AndroidSafDocumentIo(context: Context) : SafDocumentIo {

    private val resolver: ContentResolver = context.applicationContext.contentResolver

    override fun read(treeUri: String, relativePath: String, maxBytes: Long): ByteArray? {
        val uri = resolveDocumentUri(treeUri, relativePath) ?: return null
        return try {
            resolver.openInputStream(uri)?.use { input ->
                if (maxBytes <= 0) {
                    input.readBytes()
                } else {
                    val out = ByteArrayOutputStream()
                    val buf = ByteArray(64 * 1024)
                    var total = 0L
                    while (total < maxBytes) {
                        val want = minOf(buf.size.toLong(), maxBytes - total).toInt()
                        val n = input.read(buf, 0, want)
                        if (n <= 0) break
                        out.write(buf, 0, n)
                        total += n
                    }
                    out.toByteArray()
                }
            }
        } catch (missing: FileNotFoundException) {
            null
        } catch (denied: SecurityException) {
            // 授权被撤销（用户在系统设置里取消了）—— 当作「读不到」，由调用方报 IO 错
            null
        }
    }

    override fun write(treeUri: String, relativePath: String, data: ByteArray): Boolean {
        val parentRelative = relativePath.substringBeforeLast('/', "")
        val fileName = relativePath.substringAfterLast('/')
        if (fileName.isEmpty()) return false

        return try {
            val parentUri = if (parentRelative.isEmpty()) {
                Uri.parse(treeUri)
            } else {
                resolveDocumentUri(treeUri, parentRelative) ?: return false
            }
            val parentDocId = DocumentsContract.getDocumentId(parentUri)
            val childUri = DocumentsContract.buildDocumentUriUsingTree(
                Uri.parse(treeUri),
                DocumentsContract.createDocument(
                    resolver, parentUri, MIME_UNKNOWN, fileName,
                )?.let { DocumentsContract.getDocumentId(it) }
                    ?: DocumentsContract.getTreeDocumentId(parentUri) + "/" + fileName,
            )
            resolver.openOutputStream(childUri, "wt")?.use { it.write(data) } ?: return false
            true
        } catch (failure: Throwable) {
            // createDocument 在「同名已存在」时行为因 provider 而异，退回「查找后覆盖」
            runCatching {
                val existing = resolveDocumentUri(treeUri, relativePath) ?: return false
                resolver.openOutputStream(existing, "wt")?.use { it.write(data) } ?: return false
                true
            }.getOrDefault(false)
        }
    }

    override fun exists(treeUri: String, relativePath: String): Boolean =
        resolveDocumentUri(treeUri, relativePath) != null

    // ------------------------------------------------------------------

    /**
     * 把 `treeUri + 相对路径` 解析成**文档 URI**；不存在返回 null。
     *
     * 逐级下钻：不能一次性按路径查，`DocumentsContract` 只认 documentId。
     */
    private fun resolveDocumentUri(treeUri: String, relativePath: String): Uri? {
        val tree = runCatching { Uri.parse(treeUri) }.getOrNull() ?: return null
        val segments = relativePath.split('/').filter { it.isNotEmpty() && it != "." }
        if (segments.isEmpty()) {
            return runCatching { DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree)) }
                .getOrNull()
        }

        var currentDocId = runCatching { DocumentsContract.getTreeDocumentId(tree) }.getOrNull()
            ?: return null

        for (segment in segments) {
            val parentUri = runCatching {
                DocumentsContract.buildDocumentUriUsingTree(tree, currentDocId)
            }.getOrNull() ?: return null
            val childId = runCatching { findChildDocId(parentUri, segment) }.getOrNull() ?: return null
            currentDocId = childId
        }
        return runCatching { DocumentsContract.buildDocumentUriUsingTree(tree, currentDocId) }.getOrNull()
    }

    /** 在 [parentUri] 下按显示名找子文档的 documentId。 */
    private fun findChildDocId(parentUri: Uri, displayName: String): String? {
        val parentDocId = DocumentsContract.getDocumentId(parentUri)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parentUri, parentDocId)
        resolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1)
                if (name == displayName) return cursor.getString(0)
            }
        }
        return null
    }

    private companion object {
        /** 未知类型；provider 会按文件名推断。 */
        const val MIME_UNKNOWN = "application/octet-stream"
    }
}
