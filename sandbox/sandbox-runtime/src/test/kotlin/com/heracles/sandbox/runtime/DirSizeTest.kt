// Copyright (C) 2026 Heracles-taixu-sandbox contributors
// SPDX-License-Identifier: GPL-3.0
//
// 目录体积统计的单测（纯 JVM，不需要设备）。
//
// ============================================================================
// 这个测试锁住什么
// ============================================================================
// 真机 bug（2026-10-29）：沙箱页显示 rootfs 体积 **21.6 GB**，而 `du` 只有 295 MB。
//
// 根因：旧实现用 `dir.walkTopDown()`，它判断目录走 `File.isDirectory` ——
// **跟随符号链接**。Alpine rootfs 里有大量目录链接
//（`/lib -> usr/lib`、`/bin -> usr/bin`、JDK 的 `default-jvm -> java-17-openjdk`），
// 于是同一批文件被反复遍历，体积成倍放大。
//
// 修法：NIO `walkFileTree`（不传 FOLLOW_LINKS）—— 目录链接不下钻、链接本身不计入。
//
// 这个测试用「普通目录 + 目录符号链接 + 文件符号链接 + 链接环」四种结构，
// 断言结果**只等于真实文件大小之和**。

package com.heracles.sandbox.runtime

import java.io.File
import java.nio.file.Files
import java.nio.file.Paths
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Assume.assumeTrue
import org.junit.Test

class DirSizeTest {

    private lateinit var tmp: File

    @Before
    fun setUp() {
        tmp = Files.createTempDirectory("dirsize-test").toFile()
        // 符号链接在 Windows 上需要管理员/开发者模式；没有就跳过（如实标注，不假装通过）
        val possible = try {
            Files.createSymbolicLink(File(tmp, ".probe").toPath(), File(tmp, "x").toPath())
            true
        } catch (_: Throwable) {
            false
        }
        assumeTrue("当前环境不支持创建符号链接（Windows 需开发者模式）", possible)
    }

    @After
    fun tearDown() {
        tmp.deleteRecursively()
    }

    private fun write(rel: String, bytes: Int): File {
        val f = File(tmp, rel)
        f.parentFile?.mkdirs()
        f.writeBytes(ByteArray(bytes) { 0x41 })
        return f
    }

    private fun link(rel: String, target: String) {
        val l = File(tmp, rel)
        l.parentFile?.mkdirs()
        Files.createSymbolicLink(l.toPath(), Paths.get(target))
    }

    // ────────────────────────────────────────────────────────────────────

    @Test
    fun `普通目录按真实文件大小求和`() {
        write("a.bin", 1000)
        write("sub/b.bin", 2000)

        val size = directorySizeNoFollowLinks(tmp)

        // 允许文件系统块大小带来的少量差异：只断言「至少包含这两份」
        assertTrue("应 ≥ 3000，实际 $size", size >= 3000)
        assertTrue("不应远超真实大小（说明重复计数），实际 $size", size < 3000 + 4096 * 8)
    }

    @Test
    fun `目录符号链接不被下钻（这就是 21_6GB 的根因）`() {
        write("real/big.bin", 5000)
        // 造 /lib -> real 这种链接；旧实现会把它当成真目录再数一遍
        link("lib", "real")

        val size = directorySizeNoFollowLinks(tmp)

        assertTrue("应只数一次（≥5000），实际 $size", size >= 5000)
        assertTrue(
            "★ 若把链接下的文件也数了（旧 bug），size 会接近 10000；实际 $size",
            size < 10000,
        )
    }

    @Test
    fun `文件符号链接本身不计入`() {
        write("real.bin", 4096)
        link("alias.bin", "real.bin")

        val size = directorySizeNoFollowLinks(tmp)

        assertTrue("应 ≈4096 而不是 8192，实际 $size", size < 4096 * 2)
        assertTrue(size >= 4096)
    }

    @Test
    fun `链接环不会死循环也不会爆掉`() {
        write("a/f.bin", 1024)
        // a/loop -> a   （指向自己的父目录）
        link("a/loop", "..")

        val size = directorySizeNoFollowLinks(tmp)

        assertTrue("应有限且 ≈1024，实际 $size", size >= 1024 && size < 1024 + 4096 * 8)
    }

    @Test
    fun `不存在的目录返回 0 而不是抛异常`() {
        assertEquals(0L, directorySizeNoFollowLinks(File(tmp, "nope")))
    }

    @Test
    fun `空目录返回 0`() {
        val empty = File(tmp, "empty").apply { mkdirs() }
        assertEquals(0L, directorySizeNoFollowLinks(empty))
    }
}
