// Copyright (C) 2026 Heracles-taixu-sandbox contributors
// SPDX-License-Identifier: GPL-3.0
//
// T1 工具（aapt2 / aidl / zipalign）内置解包器的单测。
//
// 为什么必须测：
//   · 解包失败会留下「半个工具目录」—— `command -v aapt2` 成功但执行缺库，
//     比完全没有更难查
//   · 忘记 chmod +x → rootfs 里 Permission denied（真机踩过，退出码 126）
//   · 没内置时必须如实报 NOT_BUNDLED，不能假装成功（上层据此决定联网还是报错）

package com.heracles.sandbox.runtime

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class BundledTooltoolsTest {

    private lateinit var tmp: File
    private lateinit var rootfs: File

    /** 假 asset 表：名字 → 内容。 */
    private val assets = mutableMapOf<String, ByteArray>()

    @Before
    fun setUp() {
        tmp = Files.createTempDirectory("tooltools-test").toFile()
        rootfs = File(tmp, "rootfs").apply { mkdirs() }
    }

    @After
    fun tearDown() {
        tmp.deleteRecursively()
    }

    private fun extractor(rootfsRoot: String? = rootfs.absolutePath) = BundledTooltools(
        openAsset = { name -> assets[name]?.let { ByteArrayInputStream(it) as InputStream } },
        rootfsHostRoot = { rootfsRoot },
    )

    /** 造一个"够大"的假二进制（过 MIN_BYTES 检查）。 */
    private fun fakeBinary(size: Int = 200_000, fill: Byte = 0x7F): ByteArray =
        ByteArray(size) { i -> if (i == 0) fill else (i % 251).toByte() }

    private fun installAllFakeAssets() {
        for (name in BundledTooltools.TOOL_NAMES) {
            assets["${BundledTooltools.ASSET_PREFIX}$name"] = fakeBinary()
        }
    }

    // ── 正常路径 ────────────────────────────────────────────────────────

    @Test
    fun `解包三个工具并置可执行位`() {
        installAllFakeAssets()
        val r = extractor().ensureExtracted()

        assertEquals(BundledTooltools.ExtractResult.Status.READY, r.status)
        assertTrue(r.ok)
        val dir = File(rootfs, "opt/as")
        assertTrue("目标目录应存在", dir.isDirectory)
        for (name in BundledTooltools.TOOL_NAMES) {
            val f = File(dir, name)
            assertTrue("$name 应存在", f.isFile)
            // ⚠️ 可执行位断言**只在 POSIX 上有意义**：
            //   Windows 没有 exec 位，`File.canExecute()` 对任何存在的文件都返回 true，
            //   所以在 Windows 上跑这条断言**抓不到「忘记 chmod +x」**（已实测变异验证）。
            //   真正的门禁是设备/CI-linux 上的运行；这里用 assumeTrue 明示边界，
            //   而不是留一条在 Windows 上**恒真**的假断言。
            if (File.separatorChar == '/') {
                assertTrue("$name 应可执行（POSIX）", f.canExecute())
            }
            assertEquals("$name 体积应一致", 200_000L, f.length())
        }
        // 临时目录不能残留
        assertFalse("staging 不应残留", File(rootfs, "opt/.as-staging").exists())
    }

    @Test
    fun `幂等 —— 第二次跳过且不重写`() {
        installAllFakeAssets()
        val e = extractor()
        val first = e.ensureExtracted()
        assertEquals(BundledTooltools.ExtractResult.Status.READY, first.status)

        val aapt2 = File(rootfs, "opt/as/aapt2")
        val mtime = aapt2.lastModified()
        Thread.sleep(10)

        val second = e.ensureExtracted()
        assertEquals(BundledTooltools.ExtractResult.Status.READY, second.status)
        assertTrue("第二次应报已存在", second.message.contains("已存在"))
        assertEquals("不该重写文件", mtime, aapt2.lastModified())
    }

    // ── 如实报告的分支 ──────────────────────────────────────────────────

    @Test
    fun `没内置 T1 时报 NOT_BUNDLED（不假装成功）`() {
        val r = extractor().ensureExtracted()
        assertEquals(BundledTooltools.ExtractResult.Status.NOT_BUNDLED, r.status)
        assertFalse(r.ok)
        assertTrue(r.message.contains("未内置"))
    }

    @Test
    fun `rootfs 未就绪时报 ROOTFS_NOT_READY`() {
        installAllFakeAssets()
        val r = extractor(rootfsRoot = null).ensureExtracted()
        assertEquals(BundledTooltools.ExtractResult.Status.ROOTFS_NOT_READY, r.status)
        assertFalse(r.ok)
    }

    @Test
    fun `内置不完整（缺一个）时报 FAILED 并点名缺哪个`() {
        assets["${BundledTooltools.ASSET_PREFIX}aapt2"] = fakeBinary()
        assets["${BundledTooltools.ASSET_PREFIX}aidl"] = fakeBinary()
        // 故意不给 zipalign

        val r = extractor().ensureExtracted()
        assertEquals(BundledTooltools.ExtractResult.Status.FAILED, r.status)
        assertTrue("应点名缺 zipalign，实际=${r.message}", r.message.contains("zipalign"))
        // 失败不应产生目标目录
        assertFalse("失败后不该有目标目录", File(rootfs, "opt/as").exists())
    }

    @Test
    fun `asset 体积异常（被截断）时报 FAILED 且不落盘`() {
        for (name in BundledTooltools.TOOL_NAMES) {
            // 只有 1 KB，低于 MIN_BYTES
            assets["${BundledTooltools.ASSET_PREFIX}$name"] = ByteArray(1024)
        }
        val r = extractor().ensureExtracted()
        assertEquals(BundledTooltools.ExtractResult.Status.FAILED, r.status)
        assertTrue("应提到体积异常，实际=${r.message}", r.message.contains("体积异常"))
        assertFalse("失败后不该有目标目录", File(rootfs, "opt/as").exists())
    }

    // ── 原子性 ──────────────────────────────────────────────────────────

    @Test
    fun `已有旧目录时，新解包会整体替换（不留旧文件）`() {
        installAllFakeAssets()
        // 先造一个"旧版本"目录，里面有个多余文件
        val oldDir = File(rootfs, "opt/as").apply { mkdirs() }
        File(oldDir, "stale.so").writeText("old")

        val r = extractor().ensureExtracted()
        assertEquals(BundledTooltools.ExtractResult.Status.READY, r.status)
        assertFalse("旧的多余文件应被清掉", File(oldDir, "stale.so").exists())
        for (name in BundledTooltools.TOOL_NAMES) {
            assertTrue("$name 应存在", File(oldDir, name).isFile)
        }
    }

    @Test
    fun `工具常量与契约一致（前端与脚本按这些名字找）`() {
        assertEquals("aapt2", BundledTooltools.TOOL_NAMES[0])
        assertEquals(listOf("aapt2", "aidl", "zipalign"), BundledTooltools.TOOL_NAMES)
        assertEquals("/opt/as", BundledTooltools.GUEST_TOOL_DIR)
        assertEquals("tooltools/", BundledTooltools.ASSET_PREFIX)
    }
}
