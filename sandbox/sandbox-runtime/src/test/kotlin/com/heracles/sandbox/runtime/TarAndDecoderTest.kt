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
 *
 * 移植来源: taixu dc7fcddb88e565929379597bbd811b440d00e34f
 *           runtime/src/main/java/top/wkbin/taixu/runtime/pty/IncrementalUtf8Decoder.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/TarStreamExtractor.kt
 *
 * 这两个组件的测试价值最高，因为它们是「最容易看起来对、实际错」的那类代码：
 *   - UTF-8 增量解码：错的时候表现为**偶发**中文乱码（只在块边界撞上时）
 *   - tar 解包：错的时候表现为 rootfs 能装但跑不起来（链接指向错、权限位错）
 *
 * 测试刻意用**真实字节序列**（不是 mock），所以是「真解析」而不是空跑。
 */

package com.heracles.sandbox.runtime

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class IncrementalUtf8DecoderTest {

    @Test
    fun `多字节字符被切成两块时不会变成替换字符`() {
        val decoder = IncrementalUtf8Decoder(8192)
        // "中" = E4 B8 AD（3 字节）。切成 1 + 2 两块。
        val bytes = "中".toByteArray(Charsets.UTF_8)
        assertEquals(3, bytes.size)

        val first = decoder.decode(bytes.copyOfRange(0, 1), 1)
        assertEquals("第一块只有半个字符，不应产出任何文本", "", first)

        val second = decoder.decode(bytes.copyOfRange(1, 3), 2)
        assertEquals("第二块应补齐成完整字符", "中", second)
    }

    @Test
    fun `三字节字符被切成三块`() {
        val decoder = IncrementalUtf8Decoder(8192)
        val bytes = "汉".toByteArray(Charsets.UTF_8)
        assertEquals(3, bytes.size)

        assertEquals("", decoder.decode(bytes.copyOfRange(0, 1), 1))
        assertEquals("", decoder.decode(bytes.copyOfRange(1, 2), 1))
        assertEquals("汉", decoder.decode(bytes.copyOfRange(2, 3), 1))
    }

    @Test
    fun `四字节 emoji 被切开也能还原`() {
        val decoder = IncrementalUtf8Decoder(8192)
        val text = "🚀" // U+1F680，4 字节 F0 9F 9A 80
        val bytes = text.toByteArray(Charsets.UTF_8)
        assertEquals(4, bytes.size)

        assertEquals("", decoder.decode(bytes.copyOfRange(0, 1), 1))
        assertEquals("", decoder.decode(bytes.copyOfRange(1, 3), 2))
        assertEquals(text, decoder.decode(bytes.copyOfRange(3, 4), 1))
    }

    @Test
    fun `完整块直接解出全部文本`() {
        val decoder = IncrementalUtf8Decoder(8192)
        val text = "hello 世界"
        val bytes = text.toByteArray(Charsets.UTF_8)
        assertEquals(text, decoder.decode(bytes, bytes.size))
    }

    @Test
    fun `finish 冲出残留的半个字符为替换字符`() {
        val decoder = IncrementalUtf8Decoder(8192)
        val bytes = "中".toByteArray(Charsets.UTF_8)
        // 只喂前 2 字节，然后结束：这是真会发生的（PTY 在字符中间 EOF）
        val partial = decoder.decode(bytes.copyOfRange(0, 2), 2)
        assertEquals("", partial)

        val tail = decoder.finish()
        assertEquals("残留的不完整序列应被替换，而不是丢弃或崩溃", "\uFFFD", tail)
    }

    @Test
    fun `混合 ASCII 与多字节字符跨块`() {
        val decoder = IncrementalUtf8Decoder(8192)
        val full = "abc中文def".toByteArray(Charsets.UTF_8)
        val builder = StringBuilder()
        // 逐字节喂：最坏情况下的块边界
        for (byte in full) {
            builder.append(decoder.decode(byteArrayOf(byte), 1))
        }
        builder.append(decoder.finish())
        assertEquals("abc中文def", builder.toString())
    }

    @Test
    fun `非法字节序列被替换而不是抛异常`() {
        val decoder = IncrementalUtf8Decoder(8192)
        // 0xFF 永远不是合法的 UTF-8 起始字节
        val result = decoder.decode(byteArrayOf(0xFF.toByte()), 1) + decoder.finish()
        assertTrue("非法字节应变成替换字符，实际：$result", result.contains('\uFFFD'))
    }
}

class TarStreamExtractorTest {

    @get:Rule
    val temp = TemporaryFolder()

    /** 构造一个 ustar 头（512 字节）。 */
    private fun tarHeader(
        name: String,
        size: Long,
        mode: Int,
        typeFlag: Char,
        linkName: String = "",
    ): ByteArray {
        val header = ByteArray(512)
        fun put(text: String, offset: Int, length: Int) {
            val bytes = text.toByteArray(Charsets.US_ASCII)
            System.arraycopy(bytes, 0, header, offset, minOf(bytes.size, length))
        }
        fun putOctal(value: Long, offset: Int, length: Int) {
            // tar 用「0 填充的八进制 + NUL」；长度含末尾 NUL
            val text = value.toString(8).padStart(length - 1, '0')
            put(text, offset, length - 1)
            header[offset + length - 1] = 0
        }
        put(name, 0, 100)
        putOctal(mode.toLong(), 100, 8)
        putOctal(0, 108, 8) // uid
        putOctal(0, 116, 8) // gid
        putOctal(size, 124, 12)
        putOctal(0, 136, 12) // mtime
        // checksum 字段先填空格，算完再写
        for (i in 148 until 156) header[i] = ' '.code.toByte()
        header[156] = typeFlag.code.toByte()
        put(linkName, 157, 100)
        put("ustar", 257, 5)
        header[262] = 0
        put("00", 263, 2)
        // checksum = 全部字节的无符号和
        var sum = 0L
        header.forEach { sum += (it.toInt() and 0xff) }
        putOctal(sum, 148, 8)
        return header
    }

    /** 一个条目的数据段 + padding。 */
    private fun tarData(content: ByteArray): ByteArray {
        val padding = ((512 - (content.size % 512)) % 512)
        return content + ByteArray(padding)
    }

    /** 两个全零块 = tar 结束标记。 */
    private fun tarEnd(): ByteArray = ByteArray(1024)

    private fun extract(
        tarBytes: ByteArray,
        destination: File,
        handleWhiteouts: Boolean = false,
        warnings: MutableList<String> = mutableListOf(),
    ): List<String> = runBlocking {
        TarStreamExtractor { message, _ -> warnings += message }
            .extract(ByteArrayInputStream(tarBytes), destination, handleWhiteouts)
        warnings
    }

    @Test
    fun `解出普通文件且内容正确`() {
        val dest = temp.newFolder("rootfs")
        val content = "hello tar".toByteArray()
        val tar = tarHeader("etc/hello.txt", content.size.toLong(), 0x1a4, '0') +
            tarData(content) + tarEnd()

        extract(tar, dest)

        val file = File(dest, "etc/hello.txt")
        assertTrue("文件应存在：${file.absolutePath}", file.isFile)
        assertEquals("hello tar", file.readText())
    }

    @Test
    fun `解出目录`() {
        val dest = temp.newFolder("rootfs")
        val tar = tarHeader("etc/", 0, 0x1ed, '5') + tarEnd()

        extract(tar, dest)

        assertTrue("目录应存在", File(dest, "etc").isDirectory)
    }

    @Test
    fun `绝对符号链接被重写成相对链接`() {
        val dest = temp.newFolder("rootfs")
        // /bin/sh -> /usr/bin/dash  （docker layer 里的典型形态）
        val tar = tarHeader("bin/sh", 0, 511, '2', linkName = "/usr/bin/dash") + tarEnd()

        extract(tar, dest)

        val link = File(dest, "bin/sh")
        assertTrue("链接应存在", Files.isSymbolicLink(link.toPath()))
        val target = Files.readSymbolicLink(link.toPath()).toString()
        assertEquals(
            "绝对链接应重写成相对链接（否则会指向宿主机的 /usr/bin/dash）",
            "../usr/bin/dash",
            target.replace('\\', '/'),
        )
    }

    @Test
    fun `相对符号链接原样保留`() {
        val dest = temp.newFolder("rootfs")
        val tar = tarHeader("bin/foo", 0, 511, '2', linkName = "bar") + tarEnd()

        extract(tar, dest)

        val link = File(dest, "bin/foo")
        assertTrue(Files.isSymbolicLink(link.toPath()))
        assertEquals("bar", Files.readSymbolicLink(link.toPath()).toString())
    }

    @Test
    fun `whiteout 删除下层同名文件`() {
        val dest = temp.newFolder("rootfs")
        // 第一层建 etc/old.conf，第二层用 .wh.old.conf 删掉它
        val layer1 = tarHeader("etc/old.conf", 3, 0x1a4, '0') +
            tarData("old".toByteArray()) + tarEnd()
        extract(layer1, dest)
        assertTrue("第一层应建出文件", File(dest, "etc/old.conf").isFile)

        val layer2 = tarHeader("etc/.wh.old.conf", 0, 0x1a4, '0') + tarEnd()
        extract(layer2, dest, handleWhiteouts = true)

        assertTrue(
            "whiteout 应删除下层文件：${File(dest, "etc/old.conf").absolutePath}",
            !File(dest, "etc/old.conf").exists(),
        )
    }

    @Test
    fun `不处理 whiteout 时文件保留`() {
        val dest = temp.newFolder("rootfs")
        val layer1 = tarHeader("etc/keep.conf", 4, 0x1a4, '0') +
            tarData("keep".toByteArray()) + tarEnd()
        extract(layer1, dest)

        val layer2 = tarHeader("etc/.wh.keep.conf", 0, 0x1a4, '0') + tarEnd()
        // handleWhiteouts = false（内置 bundle 场景）
        extract(layer2, dest, handleWhiteouts = false)

        assertTrue(
            "不处理 whiteout 时原文件应保留",
            File(dest, "etc/keep.conf").isFile,
        )
    }

    @Test
    fun `不透明 whiteout 清空目录`() {
        val dest = temp.newFolder("rootfs")
        val layer1 = tarHeader("etc/a.conf", 1, 0x1a4, '0') +
            tarData("a".toByteArray()) +
            tarHeader("etc/b.conf", 1, 0x1a4, '0') +
            tarData("b".toByteArray()) + tarEnd()
        extract(layer1, dest)
        assertTrue(File(dest, "etc/a.conf").isFile)
        assertTrue(File(dest, "etc/b.conf").isFile)

        val layer2 = tarHeader("etc/.wh..wh..opq", 0, 0x1a4, '0') + tarEnd()
        extract(layer2, dest, handleWhiteouts = true)

        assertTrue("不透明 whiteout 应清空目录内容", File(dest, "etc/a.conf").let { !it.exists() })
        assertTrue(!File(dest, "etc/b.conf").exists())
        assertTrue("但目录本身应保留", File(dest, "etc").isDirectory)
    }

    /**
     * 越界条目必须**显式拒绝 + 告警**，而不是静默改写。
     *
     * 本用例的 tar 只有一个条目且它越界 ⇒ 成功应用的条目数为 0 ⇒ 应抛
     * CODE_ROOTFS_CORRUPT，且文案要说明「全部被拒绝」而不是「没有条目」。
     * （后者会误导排查方向：让人以为是空文件/压缩格式问题。）
     */
    @Test
    fun `越界条目被拒绝并给出准确的失败原因`() {
        val dest = temp.newFolder("rootfs")
        val escaped = "escaped.txt".toByteArray()
        val tar = tarHeader("../../escaped.txt", escaped.size.toLong(), 0x1a4, '0') +
            tarData(escaped) + tarEnd()

        val warnings = mutableListOf<String>()
        val exception = runCatching {
            extract(tar, dest, warnings = warnings)
        }.exceptionOrNull()

        assertTrue(
            "越界条目绝对不能写出目标目录：${File(dest.parentFile, "escaped.txt").absolutePath}",
            !File(dest.parentFile, "escaped.txt").exists(),
        )
        assertTrue("必须有越界告警：$warnings", warnings.any { "越界" in it && ".." in it })

        val sandbox = exception as? com.heracles.sandbox.api.SandboxException
        assertTrue("应抛 SandboxException，实际：$exception", sandbox != null)
        assertEquals(
            com.heracles.sandbox.api.SandboxException.CODE_ROOTFS_CORRUPT,
            sandbox!!.code,
        )
        assertTrue(
            "文案应说明『全部被拒绝』而不是『没有条目』，实际：${sandbox.message}",
            sandbox.message.orEmpty().contains("全部被拒绝"),
        )
    }

    /**
     * 越界条目与合法条目混在一起时：合法条目照常解出、越界条目被拒，
     * **不应**因为存在一个坏条目就让整个归档失败 —— 否则一个被污染的
     * layer 会连累其余无害内容。
     */
    @Test
    fun `越界条目不影响同一归档里的合法条目`() {
        val dest = temp.newFolder("rootfs")
        val good = "good".toByteArray()
        val bad = "bad".toByteArray()
        val tar = tarHeader("etc/good.txt", good.size.toLong(), 0x1a4, '0') +
            tarData(good) +
            tarHeader("../evil.txt", bad.size.toLong(), 0x1a4, '0') +
            tarData(bad) +
            tarEnd()

        val warnings = mutableListOf<String>()
        extract(tar, dest, warnings = warnings)

        assertTrue("合法条目应解出", File(dest, "etc/good.txt").isFile)
        assertEquals("good", File(dest, "etc/good.txt").readText())
        assertTrue("越界条目应被拒绝", !File(dest.parentFile, "evil.txt").exists())
        assertTrue("应有越界告警：$warnings", warnings.any { "越界" in it })
    }

    @Test
    fun `空 tar 抛 ROOTFS_CORRUPT`() {
        val dest = temp.newFolder("rootfs")
        val exception = runCatching {
            runBlocking {
                TarStreamExtractor().extract(
                    ByteArrayInputStream(tarEnd()),
                    dest,
                    handleWhiteouts = false,
                )
            }
        }.exceptionOrNull()

        assertTrue("空 tar 应失败，实际：$exception", exception is com.heracles.sandbox.api.SandboxException)
        assertEquals(
            com.heracles.sandbox.api.SandboxException.CODE_ROOTFS_CORRUPT,
            (exception as com.heracles.sandbox.api.SandboxException).code,
        )
    }

    @Test
    fun `硬链接解出为真硬链接`() {
        val dest = temp.newFolder("rootfs")
        val content = "linked".toByteArray()
        // 先建目标文件，再建指向它的硬链接
        val tar = tarHeader("etc/a.txt", content.size.toLong(), 0x1a4, '0') +
            tarData(content) +
            tarHeader("etc/b.txt", 0, 0x1a4, '1', linkName = "etc/a.txt") +
            tarEnd()

        extract(tar, dest)

        val a = File(dest, "etc/a.txt")
        val b = File(dest, "etc/b.txt")
        assertTrue("a 应存在", a.isFile)
        assertTrue("b 应存在", b.isFile)
        assertEquals("linked", b.readText())
    }

    @Test
    fun `文件权限位被保留`() {
        val dest = temp.newFolder("rootfs")
        // 0755 的脚本
        val script = "#!/bin/sh\necho hi\n".toByteArray()
        val tar = tarHeader("usr/bin/run.sh", script.size.toLong(), 0x1ed, '0') +
            tarData(script) + tarEnd()

        extract(tar, dest)

        val file = File(dest, "usr/bin/run.sh")
        assertTrue("可执行位应被保留：${file.absolutePath}", file.canExecute())
    }

    @Test
    fun `解包后目录带 owner rwx`() {
        val dest = temp.newFolder("rootfs")
        // 目录权限是 0555（只读）—— 解包后必须补上 owner 写权限，
        // 否则同一目录下的下一个条目会 EACCES
        val tar = tarHeader("locked/", 0, 0x16d, '5') +
            tarHeader("locked/file.txt", 2, 0x1a4, '0') +
            tarData("ok".toByteArray()) + tarEnd()

        extract(tar, dest)

        val dir = File(dest, "locked")
        assertTrue("目录应存在", dir.isDirectory)
        assertTrue("目录应有 owner 写权限", dir.canWrite())
        assertTrue("子文件应解出", File(dir, "file.txt").isFile)
    }

    @Test
    fun `多个条目顺序解出`() {
        val dest = temp.newFolder("rootfs")
        val out = ByteArrayOutputStream()
        listOf("etc/one", "etc/two", "etc/three").forEachIndexed { index, name ->
            val body = "content$index".toByteArray()
            out.write(tarHeader(name, body.size.toLong(), 0x1a4, '0'))
            out.write(tarData(body))
        }
        out.write(tarEnd())

        extract(out.toByteArray(), dest)

        assertEquals("content0", File(dest, "etc/one").readText())
        assertEquals("content1", File(dest, "etc/two").readText())
        assertEquals("content2", File(dest, "etc/three").readText())
    }
}
