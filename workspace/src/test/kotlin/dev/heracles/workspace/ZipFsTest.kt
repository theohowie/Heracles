package dev.heracles.workspace

import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory

/**
 * `ZipFs` 的行为门禁 —— `26-编码层工具链与逆向引擎.md` §3.1。
 *
 * 盯住三件事：
 * 1. **zip-slip 必须被拦住** —— 压缩包内的条目名是**外部输入**，
 *    `PathGuard` 只管包本身，管不到包里面
 * 2. **往返无损** —— 解压再压缩，文件内容一字不差
 * 3. **确定性** —— 同一份内容必须产出同一份字节（重打包 APK 要用）
 */
class ZipFsTest {

    private val root: Path = createTempDirectory("zipfs-test")

    private fun write(rel: String, text: String) {
        val p = root.resolve(rel)
        p.parent?.let { Files.createDirectories(it) }
        Files.writeString(p, text)
    }

    @Test
    @DisplayName("★ 压缩 → 解压往返：内容一字不差")
    fun roundTripIsLossless() = runBlocking {
        write("proj/MainActivity.java", "class MainActivity {}\n")
        write("proj/res/values/strings.xml", "<resources/>\n")

        val zfs = ZipFs(root)
        val out = zfs.zip("proj", "app.zip")
        assertEquals(2, out.entries)

        val restored = zfs.unzip("app.zip", "restored")
        assertEquals(2, restored.entries)
        assertEquals(
            "class MainActivity {}\n",
            Files.readString(root.resolve("restored/MainActivity.java")),
        )
        assertEquals(
            "<resources/>\n",
            Files.readString(root.resolve("restored/res/values/strings.xml")),
        )
    }

    @Test
    @DisplayName("★ 确定性：同一份内容压两次，字节完全相同")
    fun zipIsDeterministic() = runBlocking {
        write("d/a.txt", "a")
        write("d/b.txt", "b")
        val zfs = ZipFs(root)
        zfs.zip("d", "one.zip")
        val first = Files.readAllBytes(root.resolve("one.zip"))
        // 故意改变 mtime，检验实现是否真的没把它写进包
        Files.setLastModifiedTime(root.resolve("d/a.txt"), java.nio.file.attribute.FileTime.fromMillis(0))
        zfs.zip("d", "two.zip")
        val second = Files.readAllBytes(root.resolve("two.zip"))
        assertArrayEquals(first, second, "压缩包必须字节稳定（可复现构建的前提）")
    }

    @Test
    @DisplayName("★ zip-slip：条目名带 ../ 必须被拒绝，且不写任何东西到工作区外")
    fun zipSlipIsRejected() = runBlocking {
        val evil = root.resolve("evil.zip")
        ZipOutputStream(Files.newOutputStream(evil)).use { zos ->
            zos.putNextEntry(ZipEntry("../escaped.txt"))
            zos.write("pwned".toByteArray())
            zos.closeEntry()
        }

        val zfs = ZipFs(root)
        assertThrows(PathEscapeException::class.java) {
            runBlocking { zfs.unzip("evil.zip", "dest") }
        }
        assertTrue(
            !Files.exists(root.parent.resolve("escaped.txt")),
            "越界文件绝不能落到工作区外",
        )
    }

    @Test
    @DisplayName("★ 绝对路径条目名同样拒绝")
    fun absoluteEntryNameIsRejected() = runBlocking {
        val evil = root.resolve("abs.zip")
        ZipOutputStream(Files.newOutputStream(evil)).use { zos ->
            zos.putNextEntry(ZipEntry("/tmp/abs.txt"))
            zos.write("x".toByteArray())
            zos.closeEntry()
        }
        assertThrows(PathEscapeException::class.java) {
            runBlocking { ZipFs(root).unzip("abs.zip", "dest") }
        }
    }

    @Test
    @DisplayName("解压到工作区根：dest_dir 传空字符串合法")
    fun unzipToRootIsAllowed() = runBlocking {
        write("s/f.txt", "hello")
        val zfs = ZipFs(root)
        zfs.zip("s", "s.zip")
        val out = zfs.unzip("s.zip", "")
        assertEquals(1, out.entries)
        assertTrue(Files.exists(root.resolve("f.txt")))
    }

    @Test
    @DisplayName("压缩包不能把自己装进去（否则第二次运行体积翻倍）")
    fun archiveExcludesItself() = runBlocking {
        write("s/f.txt", "hello")
        val zfs = ZipFs(root)
        val out = zfs.zip("", "self.zip")
        // 根目录下只有 s/ 与 self.zip，自身必须被排除
        assertEquals(1, out.entries)
    }

    @Test
    @DisplayName("压一个不存在的目录 → 明确失败（不产出空包）")
    fun zippingMissingDirFails() {
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { ZipFs(root).zip("no-such-dir", "x.zip") }
        }
    }

    @Test
    @DisplayName("★ apkLayout：resources.arsc 与 *.so 不压缩，其余照压——对齐才有意义（ADR-027）")
    fun apkLayoutKeepsUncompressibleEntriesStored() = runBlocking {
        // 内容要够大，DEFLATE 才有压缩空间（否则"压了"和"没压"看不出差别）
        write("p/resources.arsc", "A".repeat(4096))
        write("p/lib/arm64-v8a/libx.so", "B".repeat(4096))
        write("p/classes.dex", "C".repeat(4096))
        write("p/res/raw/data.txt", "D".repeat(4096))

        val zfs = ZipFs(root)
        zfs.zip("p", "apk.zip", apkLayout = true)
        zfs.zip("p", "plain.zip")

        fun methodOf(archive: String, name: String): Int =
            java.util.zip.ZipFile(root.resolve(archive).toFile()).use { zf ->
                zf.entries().toList().first { it.name == name }.method
            }

        for (name in listOf("resources.arsc", "lib/arm64-v8a/libx.so")) {
            assertEquals(ZipEntry.STORED, methodOf("apk.zip", name), "$name 必须未压缩（mmap 直读的前提）")
        }
        assertEquals(ZipEntry.DEFLATED, methodOf("apk.zip", "classes.dex"), "dex 照常压缩")
        assertEquals(ZipEntry.DEFLATED, methodOf("apk.zip", "res/raw/data.txt"), "普通资源照常压缩")

        // 通用压缩工具（zip_file）不受这套纪律影响
        assertEquals(ZipEntry.DEFLATED, methodOf("plain.zip", "resources.arsc"), "没开 apkLayout 就不该改压缩方式")

        // 未压缩条目的内容仍然一字不差（STORED 写坏了会读不出来）
        java.util.zip.ZipFile(root.resolve("apk.zip").toFile()).use { zf ->
            val e = zf.getEntry("resources.arsc")
            assertArrayEquals("A".repeat(4096).toByteArray(), zf.getInputStream(e).readBytes())
        }
    }
}
