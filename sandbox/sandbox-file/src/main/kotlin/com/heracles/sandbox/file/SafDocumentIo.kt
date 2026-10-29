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

/**
 * SAF（Storage Access Framework）文档 I/O 的抽象。
 *
 * ============================================================================
 * 为什么要抽一个接口出来
 * ============================================================================
 * 1. **可单测**：`DocumentsContract` / `ContentResolver` 在 JVM 单测里跑不了，
 *    抽成接口后 [MountResolver] 的三条后端分支都能用假实现覆盖。
 * 2. **依赖清晰**：`sandbox-file` 不直接依赖 `android.content.ContentResolver`，
 *    实现放 `sandbox-app`（那里本来就有 `Context`）。
 *
 * ============================================================================
 * 实现方必须遵守的约定
 * ============================================================================
 * - `treeUri` 必须是 `takePersistableUriPermission` 之后的持久化授权，
 *   否则设备重启后失效
 * - **不得**把 SAF URI 转成物理路径再读写（`file://` 那套在 Android 16+ 已封锁）
 * - 路径分隔符统一用 `/`，`relativePath` 是相对 tree 的路径（如 `sub/a.txt`）
 */
interface SafDocumentIo {

    /**
     * 读取 tree 下的一个文档。
     *
     * @param treeUri     持久化 tree URI（`content://...`）
     * @param relativePath 相对 tree 根的子路径（`/` 分隔，可为空表示 tree 根）
     * @param maxBytes    最多读多少字节；`<= 0` 表示不限制
     * @return 文件内容；文档不存在时返回 null（**不要抛异常**，由调用方决定错误码）
     */
    fun read(treeUri: String, relativePath: String, maxBytes: Long): ByteArray?

    /**
     * 写入 tree 下的一个文档（不存在则创建）。
     *
     * @return 是否成功
     */
    fun write(treeUri: String, relativePath: String, data: ByteArray): Boolean

    /**
     * 文档是否存在。
     */
    fun exists(treeUri: String, relativePath: String): Boolean
}
