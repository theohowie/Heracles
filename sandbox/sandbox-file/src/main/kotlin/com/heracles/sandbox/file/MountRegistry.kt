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

import com.heracles.sandbox.api.MountBackend
import com.heracles.sandbox.api.MountEntry
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.runtime.BindMount
import com.heracles.sandbox.runtime.MountAdmin
import com.heracles.sandbox.runtime.MountBindSource
import java.util.concurrent.ConcurrentHashMap

/**
 * 逻辑命名挂载点注册表。
 *
 * ============================================================================
 * 职责边界
 * ============================================================================
 * 只做三件事：
 *  1. 存 / 取 / 列 [MountEntry]（线程安全）
 *  2. 注册时**结构自检**（[MountEntry.validate]），配错了立刻发现
 *  3. 给执行层提供 [bindMounts]（实现 [MountBindSource]）
 *
 * **不做**：路径解析（那是 [MountResolver]）、文件读写（那是 [SandboxFileService]
 * 与 [SafDocumentIo]）。
 *
 * ============================================================================
 * 为什么注册时就校验，而不是用的时候
 * ============================================================================
 * 一个挂载点配错（比如 SAF 却填了 hostPath），如果等到模型第一次读文件才报错，
 * 排查成本会非常高（模型会以为是自己路径拼错了）。
 * 注册是宿主初始化时做的，此时失败**立刻可见、立刻可改**。
 */
class MountRegistry(
    /** rootfs 的宿主侧根目录；`ROOTFS_RELATIVE` 解析需要它。可为 null（尚未装 rootfs）。 */
    private val rootfsHostRoot: () -> String? = { null },
) : MountBindSource, MountAdmin {

    /** 注册顺序也要稳定（`listMounts()` 的返回顺序），所以额外维护一个有序表。 */
    private val entries = ConcurrentHashMap<String, MountEntry>()
    private val orderedNames = mutableListOf<String>()
    private val lock = Any()

    // ── 注册 / 注销 ────────────────────────────────────────────────────

    /**
     * 注册或覆盖一个挂载点。同名覆盖（幂等，便于宿主启动时重复注册）。
     *
     * @throws SandboxException `CODE_INVALID_ARGUMENT`：结构非法
     */
    override fun register(entry: MountEntry) {
        entry.validate()?.let { reason ->
            throw SandboxException(SandboxException.CODE_INVALID_ARGUMENT, reason)
        }
        // bindTo 的结构性约束放这里校验（它依赖 runtime 的白名单语义）
        if (entry.wantsBind) {
            if (!entry.bindTo.startsWith("/")) {
                throw SandboxException(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    "bindTo 必须是 guest 内的绝对路径，实际='${entry.bindTo}'",
                )
            }
            if (entry.backend == MountBackend.SAF_TREE) {
                throw SandboxException(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    "SAF_TREE 不支持 bindTo：SAF 的 document URI 没有稳定的物理映射，" +
                        "绑进 PRoot 会在 Android 16+ 直接失效。请只在宿主侧读写。",
                )
            }
        }
        synchronized(lock) {
            if (!entries.containsKey(entry.name)) orderedNames += entry.name
            entries[entry.name] = entry
        }
    }

    /** 注销；返回是否真的删掉了。 */
    fun unregister(name: String): Boolean = synchronized(lock) {
        val removed = entries.remove(name) != null
        if (removed) orderedNames.remove(name)
        removed
    }

    /** 清空（宿主切换配置表时用）。 */
    fun clear() = synchronized(lock) {
        entries.clear()
        orderedNames.clear()
    }

    // ── 查询 ──────────────────────────────────────────────────────────

    /** 按逻辑名取（**不含 `@`**）。未注册返回 null。 */
    fun get(name: String): MountEntry? = entries[name]

    /** 是否已注册。 */
    fun contains(name: String): Boolean = entries.containsKey(name)

    /** 按注册顺序列出（稳定）。 */
    override fun list(): List<MountEntry> = synchronized(lock) {
        orderedNames.mapNotNull { entries[it] }
    }

    /** 已注册数量。 */
    val size: Int get() = entries.size

    /**
     * rootfs 的宿主侧根目录；未就绪时为 null。
     *
     * 暴露给 [MountResolver]：`ROOTFS_RELATIVE` 解析需要拼物理路径。
     */
    fun rootfsRoot(): String? = rootfsHostRoot()?.trimEnd('/')

    // ── MountBindSource ───────────────────────────────────────────────

    /**
     * 需要 bind 进 rootfs 的条目。
     *
     * 只返回 `wantsBind == true` 且**能算出宿主物理路径**的条目：
     * - `SAF_TREE` 永远不会出现在这里（注册时已禁止 bindTo）
     * - `ROOTFS_RELATIVE` 需要 rootfs 已就绪，否则跳过（不让执行层拿到半截路径）
     */
    override fun bindMounts(): List<BindMount> {
        val root = rootfsHostRoot()?.trimEnd('/')
        return list().mapNotNull { entry ->
            if (!entry.wantsBind) return@mapNotNull null
            val hostDir = when (entry.backend) {
                MountBackend.ROOTFS_RELATIVE -> {
                    if (root == null) return@mapNotNull null
                    "$root/${entry.hostPath.trim('/')}"
                }
                MountBackend.HOST_PRIVATE_DIR -> entry.hostPath.trimEnd('/')
                MountBackend.SAF_TREE -> return@mapNotNull null
            }
            BindMount(hostPath = hostDir, guestPath = entry.bindTo)
        }
    }
}
