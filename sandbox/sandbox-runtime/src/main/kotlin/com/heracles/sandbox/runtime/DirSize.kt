/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 */

package com.heracles.sandbox.runtime

import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes

/**
 * 统计目录体积（**不跟随符号链接**）。
 *
 * ============================================================================
 * 为什么必须抽成顶层函数
 * ============================================================================
 * 它原来是 `RootfsManager` 的私有方法，而那个类需要 Android `AssetManager` ——
 * 于是在 JVM 单测里没法验证。可这个函数**恰好是最容易写错、也最容易验证**的一段：
 * 它只用 `java.io` / `java.nio`，纯 JVM 就能跑（见 `DirSizeTest`）。
 *
 * ============================================================================
 * 旧实现为什么错（2026-10-29 真机抓到）
 * ============================================================================
 * 旧代码是：
 *
 *     dir.walkTopDown().filter { it.isFile && !it.isSymlinkNoFollow() }.sumOf { it.length() }
 *
 * `walkTopDown` 判断「要不要下钻」用的是 `File.isDirectory`，
 * 而它**跟随符号链接** ⇒ 下面这些链接会被当成真实目录反复遍历：
 * - Alpine 的 `/lib -> usr/lib`、`/bin -> usr/bin`、`/sbin -> usr/sbin`
 * - JDK 的 `default-jvm -> java-17-openjdk`
 *
 * 结果是体积被成倍放大：真机 `du` 实际 **295 MB**，UI 显示 **21.6 GB**。
 *
 * ============================================================================
 * 正确做法
 * ============================================================================
 * 用 NIO 的 `walkFileTree` 且**不传 `FOLLOW_LINKS`**：
 * - 目录符号链接**不下钻**（避免重复计数与环路）
 * - 符号链接本身的 `isRegularFile` 为 false（不计入）
 * ⇒ 与 `du -sb` 的口径一致。
 *
 * 权限问题（rootfs 里有 root 才能读的目录）不抛异常：跳过继续，
 * 因为「读不全」远好过「整个状态查询失败」。
 */
fun directorySizeNoFollowLinks(dir: File): Long = runCatching {
    if (!dir.isDirectory) return@runCatching 0L
    var total = 0L
    Files.walkFileTree(
        dir.toPath(),
        object : SimpleFileVisitor<Path>() {
            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                if (attrs.isRegularFile) total += attrs.size()
                return FileVisitResult.CONTINUE
            }

            // 权限不足等：跳过，别让整次统计失败
            override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult =
                FileVisitResult.CONTINUE
        },
    )
    total
}.getOrDefault(0L)
