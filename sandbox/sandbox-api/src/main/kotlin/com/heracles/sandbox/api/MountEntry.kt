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

package com.heracles.sandbox.api

import android.os.Parcel
import android.os.Parcelable

/**
 * 一个**逻辑命名挂载点**。
 *
 * ============================================================================
 * 模型侧只看得到 [name]
 * ============================================================================
 * 模型永远只写 `@name/...`。`hostPath` / `treeUri` **不得出现在**
 * 提示词、few-shot 示例、历史对话里 —— 否则可迁移性就丢了：
 * 换设备或改共享目录时，历史对话里的物理路径会全部失效。
 *
 * ============================================================================
 * 字段与 backend 的对应关系
 * ============================================================================
 * | backend | 用到的字段 | 不用的字段 |
 * |---|---|---|
 * | [MountBackend.ROOTFS_RELATIVE] | [hostPath]（**rootfs 内相对路径**） | [treeUri] |
 * | [MountBackend.HOST_PRIVATE_DIR] | [hostPath]（**宿主绝对路径**） | [treeUri] |
 * | [MountBackend.SAF_TREE] | [treeUri]（持久化 SAF tree URI） | [hostPath] |
 *
 * 不匹配的字段保留为空串，**不要填一个“看起来对”的值**（那会掩盖配置错误）。
 *
 * @property name         逻辑名，**不含 `@`**。调用方拼成 `@name/...` 使用。
 *                        必须是 `[a-z0-9_]+`（见 [NAME_PATTERN]）
 * @property backend      后端类型
 * @property hostPath     ROOTFS_RELATIVE：rootfs 内相对路径（如 `workspace/proj`）
 *                        HOST_PRIVATE_DIR：宿主绝对路径（如 `/data/data/<pkg>/files/libs`）
 * @property treeUri      SAF_TREE：`takePersistableUriPermission` 之后的 tree URI 字符串
 * @property readOnly     true = **宿主侧直接拒绝写入**（不进 PRoot 再靠权限兜底）
 * @property bindTo       可选：要绑进 PRoot 的 guest 挂载点（如 `/mnt/libs`）。
 *                        为空表示不绑定，只在宿主侧读写。
 *                        ⚠️ 绑定目标受 `ProotEngine.ALLOWED_BIND_TARGETS` 白名单约束
 * @property description  给模型看的简短说明（可选，一句话）
 */
data class MountEntry(
    val name: String,
    val backend: MountBackend,
    val hostPath: String = "",
    val treeUri: String = "",
    val readOnly: Boolean = false,
    val bindTo: String = "",
    val description: String = "",
) : Parcelable {

    /** 模型看到的完整前缀，如 `@workspace`。 */
    val prefix: String get() = "@$name"

    /** 是否配置了要 bind 进 PRoot。 */
    val wantsBind: Boolean get() = bindTo.isNotBlank()

    /**
     * 结构自检。**注册时就校验**，不要等用到才发现配错。
     *
     * @return null 表示合法；否则返回人话错误描述
     */
    fun validate(): String? {
        if (!NAME_PATTERN.matches(name)) {
            return "挂载名非法：'$name'（只允许小写字母、数字、下划线，且不能为空）"
        }
        return when (backend) {
            MountBackend.ROOTFS_RELATIVE -> {
                if (hostPath.isBlank()) return "ROOTFS_RELATIVE 必须给 hostPath（rootfs 内相对路径）"
                // 用 File.isAbsolute 而不是 startsWith("/")：本仓库有 JVM 单测，
                // 在 Windows 上绝对路径是 `F:\...`，硬写 `/` 会让测试和实现互相打架。
                if (looksAbsolute(hostPath)) {
                    return "ROOTFS_RELATIVE 的 hostPath 必须是**相对**路径，实际='$hostPath'"
                }
                if (hostPath.contains("..")) return "hostPath 不得含 '..'：'$hostPath'"
                if (treeUri.isNotBlank()) return "ROOTFS_RELATIVE 不应设置 treeUri"
                null
            }

            MountBackend.HOST_PRIVATE_DIR -> {
                if (hostPath.isBlank()) return "HOST_PRIVATE_DIR 必须给 hostPath（宿主绝对路径）"
                if (!looksAbsolute(hostPath)) {
                    return "HOST_PRIVATE_DIR 的 hostPath 必须是**绝对**路径，实际='$hostPath'"
                }
                if (hostPath.contains("..")) return "hostPath 不得含 '..'：'$hostPath'"
                if (treeUri.isNotBlank()) return "HOST_PRIVATE_DIR 不应设置 treeUri"
                null
            }

            MountBackend.SAF_TREE -> {
                if (treeUri.isBlank()) return "SAF_TREE 必须给 treeUri（持久化授权的 tree URI）"
                if (!treeUri.startsWith("content://")) {
                    return "SAF_TREE 的 treeUri 必须是 content:// URI，实际='$treeUri'"
                }
                if (hostPath.isNotBlank()) {
                    return "SAF_TREE **不应**设置 hostPath —— SAF 没有可靠物理映射，" +
                        "写物理路径会在 Android 16+ 直接失效"
                }
                null
            }
        }
    }

    /**
     * 「看起来是绝对路径」的判定。
     *
     * 为什么不是简单的 `startsWith("/")`：
     * 本仓库有 **JVM 单测**，在 Windows 上绝对路径是 `F:\x`，
     * 而 `/abs` 在 Windows 上又**不是**绝对路径（只算「有根无盘」）。
     * 硬写一种会两边打架。
     *
     * ⚠️ Android 上 `File.isAbsolute` 等价于 `startsWith("/")`，
     * 所以这个判定在设备上的行为与硬写 `/` **完全一致**，没有放松安全语义。
     */
    private fun looksAbsolute(path: String): Boolean =
        path.startsWith("/") || path.startsWith("\\") || java.io.File(path).isAbsolute
    override fun writeToParcel(dest: Parcel, flags: Int) {
        dest.writeString(name)
        dest.writeInt(backend.wireValue)
        dest.writeString(hostPath)
        dest.writeString(treeUri)
        dest.writeInt(if (readOnly) 1 else 0)
        dest.writeString(bindTo)
        dest.writeString(description)
    }

    override fun describeContents(): Int = 0

    companion object {
        /** 逻辑名只允许 `[a-z0-9_]+`：避免与 shell 通配、大小写、路径分隔符纠缠。 */
        val NAME_PATTERN = Regex("^[a-z0-9_]+$")

        @JvmField
        val CREATOR: Parcelable.Creator<MountEntry> = object : Parcelable.Creator<MountEntry> {
            override fun createFromParcel(parcel: Parcel) = MountEntry(
                name = parcel.readString().orEmpty(),
                backend = MountBackend.fromWire(parcel.readInt())
                    ?: MountBackend.ROOTFS_RELATIVE,
                hostPath = parcel.readString().orEmpty(),
                treeUri = parcel.readString().orEmpty(),
                readOnly = parcel.readInt() != 0,
                bindTo = parcel.readString().orEmpty(),
                description = parcel.readString().orEmpty(),
            )

            override fun newArray(size: Int): Array<MountEntry?> = arrayOfNulls(size)
        }
    }
}
