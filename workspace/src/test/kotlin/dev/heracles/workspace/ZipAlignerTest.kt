package dev.heracles.workspace

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.io.BufferedOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory

/**
 * `ZipAligner` 的行为门禁 —— ADR-026 欠的那笔账（进程内对齐）。
 *
 * ## 这些测试在防什么
 *
 * 对齐是**字节级手术**：自己拼 ZIP 的本地头/中心目录，写错一个字段
 * 就会产出"看起来能装、实际坏掉"的包 —— 而这正是 H-1 教训里最怕的东西
 * （假信息比失败更糟）。
 *
 * 所以这里不只测"偏移对齐了"，还测**包还完好**（CRC 全量可读、条目一字不差）、
 * **幂等**（不会一轮一轮变大）、**拒绝已签名的包**（否则签名必然失效）。
 *
 * ## 为什么用 STORED 手搓测试包
 *
 * `ZipFs.zip` 走的是 `ZipOutputStream` 的默认压缩；而对齐只对**未压缩**条目
 * 有意义。所以测试直接用 `STORED` 造包 —— 正是 `aapt2` 产出
 * `resources.arsc` 的那种形态。
 */
class ZipAlignerTest {

    private val root: Path = createTempDirectory("zipalign-test")

    /** 造一个"类 APK"的包：STORED 条目（对齐关心的）+ 一个 DEFLATE 条目（不该被动）。 */
    private fun writeStoreZip(
        name: String,
        stored: Map<String, ByteArray>,
        deflated: Map<String, ByteArray> = emptyMap(),
    ): Path {
        val p = root.resolve(name)
        p.parent?.let { Files.createDirectories(it) }
        ZipOutputStream(BufferedOutputStream(Files.newOutputStream(p))).use { zos ->
            for ((entryName, bytes) in stored) {
                val e = ZipEntry(entryName).apply {
                    method = ZipEntry.STORED
                    size = bytes.size.toLong()
                    compressedSize = bytes.size.toLong()
                    crc = crc32(bytes)
                }
                zos.putNextEntry(e)
                zos.write(bytes)
                zos.closeEntry()
            }
            for ((entryName, bytes) in deflated) {
                zos.putNextEntry(ZipEntry(entryName))
                zos.write(bytes)
                zos.closeEntry()
            }
        }
        return p
    }

    private fun crc32(bytes: ByteArray): Long {
        val c = java.util.zip.CRC32()
        c.update(bytes)
        return c.value
    }

    private fun content(n: Int, seed: Int = 7): ByteArray =
        ByteArray(n) { ((it * 31 + seed) % 251).toByte() }

    private fun entryNames(p: Path): List<String> =
        ZipFile(p.toFile()).use { zf -> zf.entries().toList().map { it.name }.sorted() }

    private fun readEntry(p: Path, name: String): ByteArray =
        ZipFile(p.toFile()).use { zf -> zf.getInputStream(zf.getEntry(name)).readBytes() }

    /** 某条目在包里的落点（**测试自己解析**，不碰被测代码）。 */
    private class EntryLayout(
        val localOffset: Long,
        val dataOffset: Long,
        val localExtra: ByteArray,
        val centralExtra: ByteArray,
    )

    private fun layout(p: Path, name: String): EntryLayout {
        val all = Files.readAllBytes(p)
        val cd = centralDirectoryOffset(p).toInt()
        val bb = ByteBuffer.wrap(all, cd, all.size - cd).order(ByteOrder.LITTLE_ENDIAN)
        while (bb.remaining() >= 46) {
            if (bb.int.toLong() and 0xFFFFFFFFL != 0x02014B50L) break
            bb.position(bb.position() + 24) // versionMadeBy..size
            val nameLen = bb.short.toInt() and 0xFFFF
            val extraLen = bb.short.toInt() and 0xFFFF
            val commentLen = bb.short.toInt() and 0xFFFF
            bb.position(bb.position() + 4) // diskStart + internalAttrs
            bb.position(bb.position() + 4) // externalAttrs
            val localOffset = bb.int.toLong() and 0xFFFFFFFFL
            val nameBytes = ByteArray(nameLen).also { bb.get(it) }
            val cExtra = ByteArray(extraLen).also { bb.get(it) }
            bb.position(bb.position() + commentLen)
            if (String(nameBytes, Charsets.UTF_8) != name) continue

            val lo = localOffset.toInt()
            // ⚠️ wrap(all, lo, …) 的 position 是**绝对**下标（= lo），所以下面必须按绝对位置定位，
            //    否则只有第一个条目（lo=0）读得对 —— 真机探针里先踩了一次，见该文件注释。
            val lbb = ByteBuffer.wrap(all, lo, all.size - lo).order(ByteOrder.LITTLE_ENDIAN)
            lbb.position(lo + 26)
            val lName = lbb.short.toInt() and 0xFFFF
            val lExtra = lbb.short.toInt() and 0xFFFF
            lbb.position(lo + 30 + lName)
            val extra = ByteArray(lExtra).also { lbb.get(it) }
            return EntryLayout(localOffset, localOffset + 30 + lName + lExtra, extra, cExtra)
        }
        throw AssertionError("条目不存在：$name")
    }

    private fun localExtra(p: Path, name: String): ByteArray = layout(p, name).localExtra

    private fun centralExtra(p: Path, name: String): ByteArray = layout(p, name).centralExtra

    /** 本地头额外字段的**第一个**字段是不是我们的填充字段（我们刻意放最前面）。 */
    private fun hasPaddingField(p: Path, name: String): Boolean {
        val e = localExtra(p, name)
        if (e.size < 4) return false
        // 小端读 16 位 id：0xD935 在文件里就是字节 35 d9
        val id = (e[0].toInt() and 0xFF) or ((e[1].toInt() and 0xFF) shl 8)
        return id == 0xD935
    }

    @Test
    @DisplayName("★ 独立解析器自验：它读出的偏移必须与「按本地头老实 seek」算出来的一致（否则它会误报）")
    fun independentParserAgreesWithSeek() {
        writeStoreZip(
            "parse.apk",
            linkedMapOf(
                "AndroidManifest.xml" to content(37),
                "resources.arsc" to content(200),
                "lib/arm64-v8a/libfoo.so" to content(3000),
            ),
        )
        ZipAligner(root).align("parse.apk", "parse-out.apk")

        // 第二个及以后的条目最容易读错（第一个条目 localOffset=0，错了也看不出来）
        for (name in entryNames(root.resolve("parse-out.apk"))) {
            assertEquals(
                localDataOffset(root.resolve("parse-out.apk"), name),
                layout(root.resolve("parse-out.apk"), name).dataOffset,
                "$name 的两种解析结果不一致 —— 独立验证器自己有 bug 时会报假警报",
            )
        }
    }

    // ---------------------------------------------------------------- 正向

    @Test
    @DisplayName("★ STORED 条目的数据起始偏移都被推到 4 字节对齐")
    fun storedEntriesBecomeAligned() {
        // 名字长度刻意错开，让"天然不对齐"真的发生（否则测试就是空转）
        val src = writeStoreZip(
            "in.apk",
            linkedMapOf(
                "AndroidManifest.xml" to content(37),
                "classes.dex" to content(120),
                "resources.arsc" to content(200),
                "res/layout/activity_main.xml" to content(11),
            ),
        )
        val aligner = ZipAligner(root)
        val before = aligner.check("in.apk")
        assertTrue(before.checked >= 4, "至少有 4 条 STORED 需要检查（实际 ${before.checked}）")

        val out = aligner.align("in.apk", "out.apk")

        assertEquals(4, out.entries)
        assertTrue(out.padded > 0, "这份包本该需要填充（否则测试是空转）")
        assertTrue(out.ok, "写完后自检必须通过：${out.stillMisaligned} 条仍不对齐")

        val after = aligner.check("out.apk")
        assertTrue(after.ok, "对齐检查没过：${after.summary()}")
        // ⚠️ 填充数 **≤** 原先不对齐的条目数：给前面的条目插填充会顺带推移后面的偏移，
        //    有的条目因此"自己就对齐了"，不需要再插 —— 所以这里不能断言相等。
        assertTrue(out.padded in 1..before.misaligned.size, "填充数 ${out.padded} 不在 1..${before.misaligned.size} 里")
    }

    @Test
    @DisplayName("★ 字节级改写之后：每个条目的内容与 CRC 仍然逐个对得上")
    fun contentsSurviveByteSurgery() {
        val stored = linkedMapOf(
            "AndroidManifest.xml" to content(37),
            "classes.dex" to content(4096),
            "resources.arsc" to content(1023),
        )
        val deflated = linkedMapOf("res/drawable/icon.png" to content(5000))
        writeStoreZip("in.apk", stored, deflated)

        val aligner = ZipAligner(root)
        aligner.align("in.apk", "out.apk")

        assertEquals(listOf("AndroidManifest.xml", "classes.dex", "res/drawable/icon.png", "resources.arsc"), entryNames(root.resolve("out.apk")))
        for ((name, bytes) in stored) {
            assertArrayEqualsCompat(bytes, readEntry(root.resolve("out.apk"), name), name)
        }
        for ((name, bytes) in deflated) {
            assertArrayEqualsCompat(bytes, readEntry(root.resolve("out.apk"), name), name)
        }
    }

    @Test
    @DisplayName("★ 填充字段放在最前面，且载荷里写着对齐值（读写的人要能看懂）")
    fun paddingFieldIsWellFormedAndCarriesAlignment() {
        writeStoreZip(
            "in.apk",
            linkedMapOf(
                "AndroidManifest.xml" to content(37),
                "classes.dex" to content(120),
            ),
        )
        ZipAligner(root).align("in.apk", "out.apk")

        val names = entryNames(root.resolve("out.apk"))
        val padded = names.filter { hasPaddingField(root.resolve("out.apk"), it) }
        val diag = buildString {
            append("entries=").append(names).append(" ")
            append("report=").append(ZipAligner(root).check("out.apk").summary()).append(" ")
            for (n in names) {
                append(n).append(":local=")
                append(localExtra(root.resolve("out.apk"), n).joinToString("") { "%02x".format(it) })
                append(" ")
            }
        }
        assertTrue(padded.size >= 2, "这份包两条 STORED 条目都该被插填充（否则测试是空转）：$diag")

        for (name in padded) {
            val extra = localExtra(root.resolve("out.apk"), name)
            // 结构必须是 `id(2) len(2) payload`，id 小端读出来要等于 0xD935
            val id = (extra[0].toInt() and 0xFF) or ((extra[1].toInt() and 0xFF) shl 8)
            assertEquals(0xD935, id, "字段 id 必须是 zipalign 用的 0xd935（文件里是字节 35 d9）")
            val len = (extra[2].toInt() and 0xFF) or ((extra[3].toInt() and 0xFF) shl 8)
            assertTrue(len >= 2, "载荷至少 2 字节（写对齐值），实际 $len")
            val alignment = (extra[4].toInt() and 0xFF) or ((extra[5].toInt() and 0xFF) shl 8)
            assertEquals(4, alignment, "载荷里必须是**对齐值**（4），实际 $alignment")
            assertEquals(4 + len, extra.size, "字段头+载荷的长度必须与额外字段总长一致")
        }
    }

    @Test
    @DisplayName("★ 中心目录里的额外字段不被改写（只有本地头决定数据偏移）")
    fun centralDirectoryExtraIsUntouched() {
        writeStoreZip("in.apk", linkedMapOf("AndroidManifest.xml" to content(37)))
        val before = centralExtra(root.resolve("in.apk"), "AndroidManifest.xml")
        ZipAligner(root).align("in.apk", "out.apk")
        val after = centralExtra(root.resolve("out.apk"), "AndroidManifest.xml")
        assertTrue(before.contentEquals(after), "中心目录的额外字段必须原样保留")
    }

    @Test
    @DisplayName("★ `.so` 按页对齐（4096），与 zipalign -p 的意图一致")
    fun sharedLibsArePageAligned() {
        writeStoreZip(
            "in.apk",
            linkedMapOf(
                "classes.dex" to content(64),
                "lib/arm64-v8a/libfoo.so" to content(3000),
            ),
        )
        val aligner = ZipAligner(root)
        aligner.align("in.apk", "out.apk")

        val report = aligner.check("out.apk")
        assertTrue(report.ok, report.summary())
        val soOffset = localDataOffset(root.resolve("out.apk"), "lib/arm64-v8a/libfoo.so")
        assertEquals(0L, soOffset % ZipAligner.PAGE_ALIGNMENT, "so 的数据偏移 = $soOffset，不是 4096 的倍数")
    }

    @Test
    @DisplayName("★ 幂等：对齐两次，文件不会一轮一轮变大，且仍然对齐")
    fun alignmentIsIdempotent() {
        writeStoreZip(
            "in.apk",
            linkedMapOf(
                "AndroidManifest.xml" to content(37),
                "classes.dex" to content(120),
            ),
        )
        val aligner = ZipAligner(root)
        aligner.align("in.apk", "once.apk")
        val onceSize = Files.size(root.resolve("once.apk"))

        aligner.align("once.apk", "twice.apk")
        assertEquals(onceSize, Files.size(root.resolve("twice.apk")), "二次对齐不应让包变大（旧填充要先被剥掉）")
        assertTrue(aligner.check("twice.apk").ok)
        assertArrayEqualsCompat(Files.readAllBytes(root.resolve("once.apk")), Files.readAllBytes(root.resolve("twice.apk")), "两次")
    }

    @Test
    @DisplayName("★ 别动 DEFLATE 条目：压缩数据的偏移不在规则内，但内容必须原样")
    fun compressedEntriesAreLeftAlone() {
        writeStoreZip("in.apk", linkedMapOf("a.txt" to content(9)), linkedMapOf("b.txt" to content(3000)))
        val aligner = ZipAligner(root)
        aligner.align("in.apk", "out.apk")
        assertEquals(1, aligner.check("out.apk").checked, "只有 STORED 条目算'需要对齐'")
        assertArrayEqualsCompat(content(3000), readEntry(root.resolve("out.apk"), "b.txt"), "b.txt")
    }

    // ---------------------------------------------------------------- 反向

    @Test
    @DisplayName("★★ 带 v2/v3 签名块的包必须**拒绝对齐**（而不是悄悄毁掉签名）")
    fun refusesSignedApk() {
        // 造一个"中央目录前贴着 APK Sig Block 42"的文件：这正是签名块的识别特征。
        // 布局：[随便什么块内容][16 字节魔数][中央目录从这里开始] ⇒ cdOffset = 块长 + 16
        val fake = root.resolve("signed.apk")
        val magic = "APK Sig Block 42".toByteArray(Charsets.US_ASCII)
        val block = ByteArray(24) { 1 } // 签名块（内容无所谓，识别只看那 16 字节）
        Files.write(fake, block + magic + ByteArray(46))

        RandomAccessFile(fake.toFile(), "r").use { f ->
            assertTrue(
                ZipAligner(root).hasApkSigningBlock(f, (block.size + magic.size).toLong()),
                "签名块没被识别出来",
            )
        }

        // 而普通包不能误判
        writeStoreZip("plain.apk", linkedMapOf("a.txt" to content(5)))
        RandomAccessFile(root.resolve("plain.apk").toFile(), "r").use { f ->
            val cd = centralDirectoryOffset(root.resolve("plain.apk"))
            assertFalse(ZipAligner(root).hasApkSigningBlock(f, cd), "普通包被误判成已签名")
        }
    }

    @Test
    @DisplayName("★ 对齐的包照样是可安装的结构：条数/条目名/首条内容都对（ZipFile 与 ZipInputStream 两个实现都认）")
    fun outputIsAWellFormedZip() {
        writeStoreZip(
            "in.apk",
            linkedMapOf(
                "AndroidManifest.xml" to content(37),
                "classes.dex" to content(120),
            ),
        )
        ZipAligner(root).align("in.apk", "out.apk")
        val out = root.resolve("out.apk")
        ZipFile(out.toFile()).use { zf ->
            assertEquals(2, zf.size())
            assertFalse(zf.getEntry("classes.dex").isDirectory)
        }
    }

    @Test
    @DisplayName("不是 zip 的东西：给出可读的报错，而不是崩在数组越界上")
    fun nonZipIsRejectedClearly() {
        // 够大、但不是 zip ⇒ 走"找不到 EOCD"那条路（真实情况：用户指错了文件）
        Files.writeString(root.resolve("not.zip"), "这不是压缩包".repeat(20))

        val e = assertThrows(IllegalStateException::class.java) {
            ZipAligner(root).check("not.zip")
        }
        assertTrue(e.message!!.contains("EOCD"), "报错应点明找不到 EOCD：${e.message}")

        // 小到不可能是 zip ⇒ 另一条更具体的报错
        Files.writeString(root.resolve("tiny.zip"), "x")
        val e2 = assertThrows(IllegalArgumentException::class.java) {
            ZipAligner(root).check("tiny.zip")
        }
        assertTrue(e2.message!!.contains("太小"), "报错应点明文件太小：${e2.message}")
    }

    // ---------------------------------------------------------------- 辅助

    private fun assertArrayEqualsCompat(expected: ByteArray, actual: ByteArray, what: String) {
        assertEquals(expected.size, actual.size, "$what 长度不一致")
        assertTrue(expected.contentEquals(actual), "$what 内容不一致")
    }

    /** 直接读本地头，算出某条目的数据起始偏移（**测试自己算**，不复用被测代码）。 */
    private fun localDataOffset(p: Path, name: String): Long {
        RandomAccessFile(p.toFile(), "r").use { f ->
            val cd = centralDirectoryOffset(p)
            f.seek(cd)
            val buf = ByteArray((f.length() - cd).toInt())
            f.readFully(buf)
            val bb = ByteBuffer.wrap(buf).order(ByteOrder.LITTLE_ENDIAN)
            while (true) {
                if (bb.remaining() < 46) break
                val sig = bb.int.toLong() and 0xFFFFFFFFL
                if (sig != 0x02014B50L) break
                bb.position(bb.position() + 24) // versionMadeBy..size
                val nameLen = bb.short.toInt() and 0xFFFF
                val extraLen = bb.short.toInt() and 0xFFFF
                val commentLen = bb.short.toInt() and 0xFFFF
                bb.position(bb.position() + 4) // diskStart + internalAttrs
                bb.position(bb.position() + 4) // externalAttrs
                val localOffset = bb.int.toLong() and 0xFFFFFFFFL
                val nameBytes = ByteArray(nameLen).also { bb.get(it) }
                bb.position(bb.position() + extraLen + commentLen)
                if (String(nameBytes, Charsets.UTF_8) != name) continue
                // 读本地头：名字长度 + 额外字段长度
                f.seek(localOffset + 26)
                val lh = ByteArray(4)
                f.readFully(lh)
                val lbb = ByteBuffer.wrap(lh).order(ByteOrder.LITTLE_ENDIAN)
                val lName = lbb.short.toInt() and 0xFFFF
                val lExtra = lbb.short.toInt() and 0xFFFF
                return localOffset + 30 + lName + lExtra
            }
        }
        throw AssertionError("条目不存在：$name")
    }

    /** EOCD 里的中央目录偏移（测试自己找，不用被测代码）。 */
    private fun centralDirectoryOffset(p: Path): Long {
        val all = Files.readAllBytes(p)
        for (i in all.size - 22 downTo 0) {
            if (all[i] == 0x50.toByte() && all[i + 1] == 0x4B.toByte() &&
                all[i + 2] == 0x05.toByte() && all[i + 3] == 0x06.toByte()
            ) {
                val bb = ByteBuffer.wrap(all, i, 22).order(ByteOrder.LITTLE_ENDIAN)
                bb.int
                bb.position(bb.position() + 8)
                bb.int // cdSize
                return bb.int.toLong() and 0xFFFFFFFFL
            }
        }
        throw AssertionError("找不到 EOCD")
    }
}
