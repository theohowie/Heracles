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

package com.heracles.sandbox.runtime

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.zip.GZIPOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 回归测试：**内置 rootfs 的流所有权**。
 *
 * ============================================================================
 * 这个测试为什么存在（真实 bug 的墓碑）
 * ============================================================================
 * 真机现象：离线时点「① 装 rootfs」，日志说
 *
 * ```
 * 内置未生效：outcome=CORRUPT
 * 原因：内置 rootfs（rootfs-bundle.tar）解包时出错：AssetInputStream is closed
 * ```
 *
 * 内置 rootfs 明明打进了 APK（assets/rootfs-bundle.tar 9.1 MB 在包里），
 * 却报「压缩包损坏」—— 这个错误文案会把人一路误导到怀疑打包脚本。
 *
 * **根因**：调用点写的是
 *
 * ```kotlin
 * val (stream, reason) = raw.use { detectAndWrap(it) }   // ← BUG
 * ```
 *
 * `use {}` 在 lambda 返回时关闭 `raw`，但 `detectAndWrap` 返回的
 * `BufferedInputStream` / `GZIPInputStream` **仍然要从 raw 读数据**。
 * 于是第一次 read 就抛 `AssetInputStream is closed`（Android 的 AssetManager
 * 流在关闭后的特有报错），被 catch(Throwable) 归成 CORRUPT。
 *
 * 修复：把流的生命周期交给后面真正的消费者（`stream.use { ... }`），
 * `detectAndWrap` 本身不关闭任何东西。
 *
 * ============================================================================
 * 为什么这些断言能抓住它
 * ============================================================================
 * 1. `wrappedStreamRemainsReadable` —— 包装后**必须仍能读完**。
 *    这正是 bug 的表现：`use{}` 之后包装流读到 0 字节就抛。
 * 2. `rawIsNotClosedByDetect_wrap` —— detectAndWrap 返回非 null 时
 *    **不得**关闭 raw（所有权已转移给包装流）。
 * 3. 反过来，返回 null（不支持的格式）时 raw 由调用方关闭 —— 这条也测，
 *    免得"修 bug 改成永不关闭"引出资源泄漏。
 */
class BundledRootfsStreamOwnershipTest {

    /**
     * 一个**行为等价于 Android `AssetInputStream`** 的输入流。
     *
     * ========================================================================
     * 为什么必须自己实现，不能直接用 ByteArrayInputStream（这里吃过亏）
     * ========================================================================
     * 第一版测试直接包了 `ByteArrayInputStream`，结果**变异验证没变红**：
     * 把修复改回 bug 版本 `raw.use { detectAndWrap(it) }` 之后，测试依旧全绿。
     *
     * 原因是 `ByteArrayInputStream.close()` 是**空操作**（JDK 文档明说
     * "Closing a ByteArrayInputStream has no effect"）—— 关掉之后照样能读。
     *
     * 而真机上 `AssetManager.open()` 返回的 `AssetInputStream` 关闭后再 read
     * 会**抛 IOException("AssetInputStream is closed")**。正是这个差异让
     * 「提前 close」从无害变成了致命。
     *
     * 所以这个类**必须**在关闭后抛异常，否则测试根本测不出这个 bug。
     * 教训：假对象要假在「观测点」上，不能假得比真的更宽松。
     */
    private class TrackedInputStream(bytes: ByteArray) : InputStream() {
        private val delegate = ByteArrayInputStream(bytes)
        private var closed = false

        /** 被 close 过的次数。 */
        var closeCount: Int = 0
            private set

        override fun read(): Int {
            ensureOpen()
            return delegate.read()
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            ensureOpen()
            return delegate.read(b, off, len)
        }

        override fun available(): Int {
            ensureOpen()
            return delegate.available()
        }

        /** 模拟 AssetInputStream：关闭后再读 → IOException。 */
        private fun ensureOpen() {
            if (closed) throw java.io.IOException("AssetInputStream is closed")
        }

        override fun close() {
            closeCount++
            closed = true
            delegate.close()
        }
    }

    /** 构造一段最小但合法的 tar（512 字节头 + 一个文件 + 两个空块）。 */
    private fun minimalTarBytes(fileName: String, content: String): ByteArray {
        val contentBytes = content.toByteArray(Charsets.UTF_8)

        fun padBlock(bytes: ByteArray): ByteArray {
            val padded = ((bytes.size + 511) / 512) * 512
            return bytes.copyOf(padded)
        }

        val header = ByteArray(512)
        fun put(field: String, value: String, offset: Int, length: Int) {
            val bytes = value.toByteArray(Charsets.US_ASCII)
            bytes.copyInto(header, offset, 0, minOf(bytes.size, length))
        }
        put("name", fileName, 0, 100)
        put("mode", "0000644", 100, 8)
        put("uid", "0000000", 108, 8)
        put("gid", "0000000", 116, 8)
        put("size", contentBytes.size.toString(8).padStart(11, '0'), 124, 12)
        put("mtime", "00000000000", 136, 12)
        // 校验和字段：先填 8 个空格，算完再写
        for (i in 148 until 156) header[i] = ' '.code.toByte()

        var sum = 0
        for (b in header) sum += b.toInt() and 0xff
        put("chksum", sum.toString(8).padStart(6, '0') + "\u0000 ", 148, 8)

        put("typeflag", "0", 156, 1)
        put("magic", "ustar", 257, 6)
        header[263] = 0
        put("version", "00", 263, 2)

        val out = ByteArrayOutputStream()
        out.write(header)
        out.write(padBlock(contentBytes))
        out.write(ByteArray(1024)) // 两个空块 = 归档结束
        return out.toByteArray()
    }

    private fun gzip(bytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { it.write(bytes) }
        return out.toByteArray()
    }

    /**
     * `detectAndWrap` **不触碰 AssetManager**（它只做格式探测与流包装）。
     *
     * 但 `BundledRootfs` 的构造参数是非空的 `AssetManager`，纯 JVM 测试里
     * 造不出真对象（`AssetManager` 是 final 类，连 Proxy 都代理不了）。
     *
     * 解决办法：用**反射构造一个未初始化的实例**（`Unsafe`/`allocateInstance`
     * 语义）。被测函数 `detectAndWrap` 不触碰任何字段，所以字段全为 null
     * 也无所谓 —— 这恰好也**证明了**它不依赖 assets。
     *
     * 若将来有人给 `detectAndWrap` 加了 assets 依赖，这里会立刻 NPE，
     * 测试变红而不是悄悄通过。
     */
    private fun newBundledRootfsForDetectOnly(): BundledRootfs {
        val ctor = BundledRootfs::class.java.declaredConstructors
            .first { it.parameterCount == 3 }
        // 用一个「绝不会被调用」的构造路径：直接拿 sun.misc.Unsafe 分配
        val unsafeField = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe")
        unsafeField.isAccessible = true
        val unsafe = unsafeField.get(null)
        val allocate = unsafe.javaClass.getMethod("allocateInstance", Class::class.java)
        return allocate.invoke(unsafe, BundledRootfs::class.java) as BundledRootfs
    }
    // =====================================================================

    /**
     * ★★★ 最重要的回归：**直接覆盖 tryInstall 的那个调用点** ★★★
     *
     * 这条测的是 `openBundleStream(raw)` —— 也就是 tryInstall 里
     * 真正会出 bug 的那一步。之前的测试只调 `detectAndWrap`，
     * 绕过调用点，所以**变异验证没变红**（把修复改回 bug 写法后测试仍全绿）。
     *
     * 用「关闭后再读就抛 IOException」的假流来模拟 Android AssetInputStream，
     * 才能真正复现真机的 `AssetInputStream is closed`。
     */
    @Test
    fun openBundleStream_keepsRawReadable_soExtractionCanProceed() {
        val payload = minimalTarBytes("etc/os-release", "ID=alpine\n")
        val raw = TrackedInputStream(gzip(payload))

        val (stream, reason) = newBundledRootfsForDetectOnly().openBundleStream(raw)

        assertNotNull("gzip 应被识别（reason=$reason）", stream)
        assertNull(reason)

        // ★ 关键：模拟真实解包——流必须还能读完
        val readBack = try {
            stream!!.readBytes()
        } catch (failure: Throwable) {
            throw AssertionError(
                "包装流读取失败：${failure.message}。" +
                    "若消息是 \"AssetInputStream is closed\"，说明 openBundleStream " +
                    "提前关闭了 raw —— 这正是真机 bug 的复现。",
                failure,
            )
        } finally {
            runCatching { stream?.close() }
        }

        assertEquals(
            "必须能读回完整的 tar（大小不符说明流被提前关闭）",
            payload.size,
            readBack.size,
        )
        assertTrue(payload.contentEquals(readBack))
    }

    /**
     * 反方向：走 `openBundleStream` 遇到不支持的格式时，raw 应**由它关闭**
     * （没有包装流接手，不关就泄漏 fd）。
     */
    @Test
    fun openBundleStream_closesRaw_whenFormatUnsupported() {
        val zstd = byteArrayOf(0x28, 0xb5.toByte(), 0x2f, 0xfd.toByte(), 0, 0, 0, 0)
        val raw = TrackedInputStream(zstd)

        val (stream, reason) = newBundledRootfsForDetectOnly().openBundleStream(raw)

        assertNull(stream)
        assertNotNull(reason)
        assertEquals(
            "不支持格式时没有包装流接手 raw，openBundleStream 必须自己关闭它（防 fd 泄漏）",
            1,
            raw.closeCount,
        )
    }

    /**
     * ★ 核心回归：gzip 包装之后，**流必须仍能完整读出**。
     *
     * 变异验证方法：把调用点改回 `raw.use { detectAndWrap(it) }`，
     * 这条应当立刻变红（读到 0 字节或抛 "closed"）。
     */
    @Test
    fun wrappedStreamRemainsReadable_afterDetectAndWrap() {
        val payload = minimalTarBytes("etc/os-release", "ID=alpine\n")
        val raw = TrackedInputStream(gzip(payload))

        val (stream, reason) = newBundledRootfsForDetectOnly().detectAndWrap(raw)

        assertNotNull("gzip magic 应被识别并包装成可读流（reason=$reason）", stream)
        assertNull("识别成功时不应有错误原因", reason)

        // 关键断言：能读出**完整的原始 tar 字节**
        val readBack = stream!!.readBytes()
        stream.close()

        assertEquals(
            "包装流读出的内容必须与原始 tar 完全一致（若这里为 0 或抛 closed，" +
                "说明 raw 在 detectAndWrap 返回前被关闭了 —— 就是那个真机 bug）",
            payload.size,
            readBack.size,
        )
        assertTrue("读出的内容应与原始 tar 逐字节一致", payload.contentEquals(readBack))
    }

    /**
     * ★ 所有权契约：返回非 null 时，**detectAndWrap 不得关闭 raw**。
     *
     * 变异验证：在 detectAndWrap 成功分支里加 `raw.close()`，这条应变红。
     */
    @Test
    fun detectAndWrap_mustNotCloseRaw_whenWrapping() {
        val payload = minimalTarBytes("bin/sh", "#!/bin/sh\n")
        val raw = TrackedInputStream(gzip(payload))

        val (stream, _) = newBundledRootfsForDetectOnly().detectAndWrap(raw)
        assertNotNull(stream)

        assertEquals(
            "包装成功时 raw 的关闭责任已转移给包装流，detectAndWrap 不得关闭它",
            0,
            raw.closeCount,
        )

        // 关闭包装流时，应当**连带**关闭 raw（GZIPInputStream 的语义）
        stream!!.close()
        assertEquals("关闭包装流应连带关闭底层 raw（避免 fd 泄漏）", 1, raw.closeCount)
    }

    /**
     * 裸 tar（无压缩）也应被包装且可读。
     *
     * 这条同时覆盖**真机实际情况**：AGP 的 `compressDebugAssets` 会把
     * `assets/rootfs-bundle.tar.gz` **自动解压**成 `assets/rootfs-bundle.tar`，
     * 所以运行期读到的往往是裸 tar。之前只测 gzip 会漏掉这条路径。
     */
    @Test
    fun bareTar_isWrappedAndReadable() {
        val payload = minimalTarBytes("etc/hostname", "sandbox\n")
        val raw = TrackedInputStream(payload)

        val (stream, reason) = newBundledRootfsForDetectOnly().detectAndWrap(raw)
        assertNotNull("裸 tar 应被当作 tar 接受（reason=$reason）", stream)

        val readBack = stream!!.readBytes()
        stream.close()
        assertEquals(payload.size, readBack.size)
        assertTrue(payload.contentEquals(readBack))
    }

    /** 不支持的格式：返回 null + **可读的原因**，且此时 raw 由调用方关闭（本函数不关）。 */
    @Test
    fun unsupportedFormat_returnsNullWithReason_andLeavesRawToCaller() {
        // zstd magic: 28 b5 2f fd
        val zstd = byteArrayOf(0x28, 0xb5.toByte(), 0x2f, 0xfd.toByte(), 0, 0, 0, 0)
        val raw = TrackedInputStream(zstd)

        val (stream, reason) = newBundledRootfsForDetectOnly().detectAndWrap(raw)

        assertNull("zstd 不在支持范围，应返回 null", stream)
        assertNotNull("必须给出可读的失败原因（不能静默）", reason)
        assertTrue("原因里应提到 zstd", reason!!.contains("zstd"))
        assertTrue("原因里应给出可操作的修复建议", reason.contains("tar"))

        assertEquals(
            "返回 null 时所有权未转移，本函数不应关闭 raw（由调用方关）",
            0,
            raw.closeCount,
        )
        raw.close()
    }

    /** xz：同样明确拒绝并说明原因。 */
    @Test
    fun xzFormat_isRejectedWithReason() {
        val xz = byteArrayOf(0xfd.toByte(), 0x37, 0x7a, 0x58, 0x5a, 0x00, 0, 0)
        val raw = TrackedInputStream(xz)

        val (stream, reason) = newBundledRootfsForDetectOnly().detectAndWrap(raw)
        assertNull(stream)
        assertNotNull(reason)
        assertTrue("原因里应提到 xz", reason!!.contains("xz"))
        raw.close()
    }

    /** ZIP：明确拒绝（ZIP 保不住 Linux 权限位与符号链接，解出来不可执行）。 */
    @Test
    fun zipFormat_isRejectedWithReason() {
        // PK\x03\x04
        val zip = byteArrayOf(0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0)
        val raw = TrackedInputStream(zip)

        val (stream, reason) = newBundledRootfsForDetectOnly().detectAndWrap(raw)
        assertNull(stream)
        assertNotNull(reason)
        assertTrue("原因里应提到 ZIP", reason!!.contains("ZIP"))
        assertTrue("原因里应说明为什么不行（权限/符号链接）", reason.contains("权限"))
        raw.close()
    }

    /** 空文件：给出「过短」而不是崩。 */
    @Test
    fun emptyInput_returnsReasonInsteadOfThrowing() {
        val raw = TrackedInputStream(ByteArray(0))
        val (stream, reason) = newBundledRootfsForDetectOnly().detectAndWrap(raw)
        assertNull(stream)
        assertNotNull(reason)
        raw.close()
    }
}
