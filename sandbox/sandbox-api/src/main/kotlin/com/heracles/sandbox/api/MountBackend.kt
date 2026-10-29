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

/**
 * 命名挂载点的**后端类型**。
 *
 * ============================================================================
 * 为什么要有这一层（一句话）
 * ============================================================================
 * 模型只写 `@name/...`，**物理路径由宿主解析**。
 * 换设备 / 改共享目录时只改配置表，**模型提示词和历史对话不用动**。
 *
 * ============================================================================
 * 三种后端
 * ============================================================================
 * 见下面的枚举常量。选错后端最典型的后果：
 * - 用 [HOST_PRIVATE_DIR] 指向电脑上的文件 —— 根本访问不到（Android 沙箱）
 * - 用物理路径代替 [SAF_TREE] —— Android 16 起 `/Android/data` 等已被默认封锁，
 *   SAF 是**跨设备文件在 Android 上的合法入口**
 *
 * @property wireValue AIDL 上的整数值。**不要改已有数字**（跨进程会错位）。
 */
enum class MountBackend(val wireValue: Int) {

    /**
     * 主根：路径相对 **rootfs**，读写都在 PRoot 内完成。
     *
     * 语义上等价于「工作区」。
     * - 读：`<rootfs>/<hostPath>/<rest>`
     * - 写：同上
     * - 可 bind 进 PRoot（`bindTo` 指定 guest 挂载点，如 `/mnt/workspace`）
     *
     * 适合：项目源码、构建中间产物、沙箱自己的文件。
     */
    ROOTFS_RELATIVE(0),

    /**
     * 宿主应用**私有目录**的绝对路径（如 `/data/data/<pkg>/files/...`）。
     *
     * - 读：`<hostPath>/<rest>`
     * - 写：同上（`readOnly` 时不写）
     * - 可 bind 进 PRoot：本 App 私有目录 PRoot 能读，适合放共享库、构建缓存
     *
     * 适合：`filesDir` / `cacheDir` 下的共享资源。
     *
     * ⚠️ 只是**本应用私有**目录。想读用户选的目录（相机、下载、电脑同步目录）
     * 必须用 [SAF_TREE] —— 那才是 Android 上合法的跨应用入口。
     */
    HOST_PRIVATE_DIR(1),

    /**
     * 用户通过 `ACTION_OPEN_DOCUMENT_TREE` 授权的**持久化 SAF 目录树**。
     *
     * - 读：`ContentResolver.openInputStream(treeUri 下的子文档)`
     * - 写：`openOutputStream`（`readOnly` 时**宿主侧直接拒绝**）
     * - **不转换成物理路径**：SAF 的 document URI 没有稳定物理映射，
     *   硬转会在 Android 16+ 直接失效
     * - 一般**不 bind** 进 PRoot（拿不到可绑定物理映射时就不绑，只在宿主侧读写）
     *
     * 这是**跨设备 / 电脑文件在 Android 上的正确入口**。
     * 不要为了它能用而去申请 `MANAGE_EXTERNAL_STORAGE`（商店审核高风险，且不必要）。
     */
    SAF_TREE(2),
    ;

    companion object {
        /** 从 AIDL 的整数还原；未知值返回 null（**不要猜一个默认值**）。 */
        fun fromWire(value: Int): MountBackend? = entries.firstOrNull { it.wireValue == value }
    }
}
