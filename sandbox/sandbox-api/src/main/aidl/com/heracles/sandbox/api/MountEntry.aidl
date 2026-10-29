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
 */

package com.heracles.sandbox.api;

/*
 * 一个逻辑命名挂载点。实现在
 * sandbox-api/src/main/kotlin/com/heracles/sandbox/api/MountEntry.kt
 *
 * 字段语义（详见 docs/api-reference.md 的「MountRegistry」章节）：
 *   name         String  逻辑名（不含 @），只允许 [a-z0-9_]+
 *   backend      int     MountBackend.wireValue：0=ROOTFS_RELATIVE
 *                                               1=HOST_PRIVATE_DIR
 *                                               2=SAF_TREE
 *   hostPath     String  ROOTFS_RELATIVE：rootfs 内相对路径
 *                        HOST_PRIVATE_DIR：宿主绝对路径
 *   treeUri      String  SAF_TREE：持久化 tree URI（content://...）
 *   readOnly     boolean true = 宿主侧直接拒绝写入
 *   bindTo       String  可选：绑进 PRoot 的 guest 挂载点（受白名单约束）
 *   description  String  给模型看的简短说明（可选）
 *
 * ★ 模型侧只看得到 name。hostPath / treeUri 不得出现在提示词与历史里。
 */
parcelable MountEntry;
