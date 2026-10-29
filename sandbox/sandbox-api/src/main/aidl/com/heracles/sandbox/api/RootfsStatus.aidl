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
 * rootfs 的当前状态。实现（Kotlin，手写 Parcelable）在
 * sandbox-api/src/main/kotlin/com/heracles/sandbox/api/Models.kt
 *
 * 字段语义（详见 docs/api-reference.md）：
 *   installed      boolean 是否有可用 rootfs
 *   source         int     0=未安装 1=内置 bundled 2=OCI
 *   label          String  人类可读标识（"alpine-3.20" / "bundled-minimal"）
 *   ociRef         String  OCI 安装时回显引用；否则空串
 *   sizeBytes      long    占用字节；未知 -1
 *   snapshotName   String  当前生效快照名；无快照为空串
 *   snapshotCount  int     已有快照数量
 *   rootfsPath     String  **宿主视角**的 rootfs 根目录绝对路径
 *
 * ★ rootfsPath 是宿主视角：它真实落在 {app.filesDir}/sandbox/rootfs/ 下，
 *   宿主可以用普通 Java File API 访问；但沙箱内看到的 "/" 才是这个目录。
 */
parcelable RootfsStatus;
