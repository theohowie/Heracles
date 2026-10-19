package dev.heracles.agent.tools

import dev.heracles.agent.ToolOutcome
import dev.heracles.workspace.RealWorkspaceFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory

/**
 * 归档工具层的行为门禁 —— `26-编码层工具链与逆向引擎.md` §4.2。
 *
 * `ZipFs` 自己的不变量在 `:workspace:ZipFsTest` 里已经钉死（zip-slip / 往返 / 确定性 /
 * `apkLayout`）。这里只测**工具层**特有的三件事 —— 也就是模型真正会撞上的那三件事：
 *
 * 1. 参数缺失 / 非法 → 是 `Failure` 而**不是抛异常**（抛异常会打断整个 agent 循环）
 * 2. 包内条目名是**外部输入** ⇒ zip-slip 在工具层也必须变成 Failure 且**不写任何东西**
 * 3. `zip_file` 的**描述**必须写清"它不编译 dex / 不生成资源表，不要拿它替代 `build_apk`"
 *    —— 描述就是模型的说明书，写漏了它就会用错工具（这是**文档即行为**的那类约束）
 */
class ArchiveToolsTest {

    private val root: Path = createTempDirectory("archive-tools")
    private val fs = RealWorkspaceFs.open(root)

    private fun write(rel: String, text: String) {
        val p = root.resolve(rel)
        p.parent?.let { Files.createDirectories(it) }
        Files.writeString(p, text)
    }

    private fun unzip() = UnzipFileTool(fs)
    private fun zip() = ZipFileTool(fs)

    // ---------- 参数校验 ----------

    @Test
    @DisplayName("★ 必填参数为空 → Failure（模型漏参数是家常便饭，不能炸掉循环）")
    fun blankRequiredArgsFail() = runBlocking {
        assertTrue(unzip().execute(mapOf("archive" to " ")) is ToolOutcome.Failure)
        assertTrue(unzip().execute(emptyMap()) is ToolOutcome.Failure)
        assertTrue(zip().execute(mapOf("archive" to "")) is ToolOutcome.Failure)
        assertTrue(zip().execute(emptyMap()) is ToolOutcome.Failure)
    }

    @Test
    @DisplayName("工具名与参数面：改名/改参数会静默毁掉前缀缓存，所以要钉住")
    fun specSurfaceIsPinned() {
        val u = unzip().spec
        val z = zip().spec
        assertEquals("unzip_file", u.name)
        assertEquals("zip_file", z.name)
        assertEquals(listOf("archive", "dest_dir"), u.parameters.map { it.name })
        assertEquals(listOf("src_dir", "archive"), z.parameters.map { it.name })
    }

    @Test
    @DisplayName("★ zip_file 的描述必须说清\"它不编译 dex、不生成资源表、不要替代 build_apk\"")
    fun zipDescriptionWarnsItIsNotABuild() {
        val d = zip().spec.description
        assertTrue(d.contains("build_apk"), "必须点名 build_apk，否则模型会用压缩代替构建：$d")
        assertTrue(
            d.contains("编译") || d.contains("dex"),
            "必须说明它不做编译/dex，实际：$d",
        )
    }

    // ---------- 失败路径：一律 Failure，不抛异常 ----------

    @Test
    @DisplayName("解压不存在的包 → Failure（不是抛异常，且点名是哪个包）")
    fun unzipMissingArchiveFails() = runBlocking {
        val r = unzip().execute(mapOf("archive" to "nope.zip", "dest_dir" to "out"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("nope.zip"), "要点名：$r")
    }

    @Test
    @DisplayName("把普通文本文件当压缩包解 → Failure，并说明\"不是有效的压缩包\"")
    fun unzipNonZipFails() = runBlocking {
        write("notes.txt", "这不是一个 zip")
        val r = unzip().execute(mapOf("archive" to "notes.txt", "dest_dir" to "out"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("压缩包"), "实际：$r")
    }

    @Test
    @DisplayName("★ zip-slip 在**工具层**也必须失败，且不往工作区外写任何东西")
    fun zipSlipBecomesFailureWithoutEscaping() = runBlocking {
        ZipOutputStream(Files.newOutputStream(root.resolve("evil.zip"))).use { zos ->
            zos.putNextEntry(ZipEntry("../escaped-by-tool.txt"))
            zos.write("pwned".toByteArray())
            zos.closeEntry()
        }

        val r = unzip().execute(mapOf("archive" to "evil.zip", "dest_dir" to "dest"))
        assertTrue(r is ToolOutcome.Failure, "越界必须失败，实际：$r")
        assertTrue(
            (r as ToolOutcome.Failure).reason.contains("路径被拒绝"),
            "要说清是路径问题而不是\"解压失败\"：$r",
        )
        assertFalse(
            Files.exists(root.parent.resolve("escaped-by-tool.txt")),
            "越界文件绝不能落到工作区外",
        )
    }

    @Test
    @DisplayName("源目录越界（../）打包 → Failure，且不在工作区外留下产物")
    fun zipEscapingSourceDirFails() = runBlocking {
        val outside = root.parent.resolve("outside-src")
        Files.createDirectories(outside)
        Files.writeString(outside.resolve("f.txt"), "x")

        val r = zip().execute(mapOf("src_dir" to "../outside-src", "archive" to "out.zip"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("路径被拒绝"), "实际：$r")
        assertFalse(Files.exists(root.resolve("out.zip")), "拒绝之后不得留下半成品包")
    }

    // ---------- 正常路径 ----------

    @Test
    @DisplayName("★ 工具层往返：中文文件名 + 二进制内容，一字不差")
    fun roundTripThroughToolsIsLossless() = runBlocking {
        val binary = ByteArray(512) { (it % 256).toByte() }
        write("proj/res/values/字符串.xml", "<resources/>\n")
        Files.createDirectories(root.resolve("proj/lib"))
        Files.write(root.resolve("proj/lib/x.so"), binary)

        val z = zip().execute(mapOf("src_dir" to "proj", "archive" to "build/app.zip"))
        assertTrue(z is ToolOutcome.Success, "实际：$z")
        assertTrue((z as ToolOutcome.Success).detail.contains("2 个条目"), "实际：$z")

        val u = unzip().execute(mapOf("archive" to "build/app.zip", "dest_dir" to "restored"))
        assertTrue(u is ToolOutcome.Success, "实际：$u")

        assertEquals(
            "<resources/>\n",
            Files.readString(root.resolve("restored/res/values/字符串.xml")),
            "中文路径必须原样往返",
        )
        assertArrayEquals(
            binary,
            Files.readAllBytes(root.resolve("restored/lib/x.so")),
            "二进制内容必须字节一致（压缩工具最容易在这里出错）",
        )
    }

    @Test
    @DisplayName("dest_dir 传空字符串 = 解压到工作区根（合法，不是 undefined）")
    fun unzipToWorkspaceRootIsAllowed() = runBlocking {
        write("s/f.txt", "hello")
        val z = zip().execute(mapOf("src_dir" to "s", "archive" to "s.zip"))
        assertTrue(z is ToolOutcome.Success, "实际：$z")

        val u = unzip().execute(mapOf("archive" to "s.zip", "dest_dir" to ""))
        assertTrue(u is ToolOutcome.Success, "实际：$u")
        assertTrue(Files.exists(root.resolve("f.txt")), "应当落在工作区根")
    }

    // ---------- F7b：optional（缺键 ⇒ 与空串同一条默认分支） ----------

    @Test
    @DisplayName("★ unzip_file：dest_dir 缺键 ⇒ 解压到工作区根（与传空字符串等价）")
    fun unzipDestDirDefaultsToRootWhenMissing() = runBlocking {
        write("src2/f2.txt", "hello2")
        assertTrue(
            zip().execute(mapOf("src_dir" to "src2", "archive" to "src2.zip")) is ToolOutcome.Success,
        )
        val u = unzip().execute(mapOf("archive" to "src2.zip"))
        assertTrue(u is ToolOutcome.Success, "实际：$u")
        assertTrue(Files.exists(root.resolve("f2.txt")), "缺键时应当落在工作区根")
    }

    @Test
    @DisplayName("★ zip_file：src_dir 缺键 ⇒ 打包工作区根（与传空字符串等价）")
    fun zipSrcDirDefaultsToRootWhenMissing() = runBlocking {
        write("rootfile.txt", "at-root")
        val z = zip().execute(mapOf("archive" to "root.zip"))
        assertTrue(z is ToolOutcome.Success, "实际：$z")
        assertTrue(
            (z as ToolOutcome.Success).detail.contains("（工作区根）"),
            "成功文案要说明打的是根目录，实际：${z.detail}",
        )
        assertTrue(
            unzip().execute(mapOf("archive" to "root.zip", "dest_dir" to "back2")) is ToolOutcome.Success,
        )
        assertTrue(Files.exists(root.resolve("back2/rootfile.txt")), "根目录下的文件应当被打进包")
    }

    @Test
    @DisplayName("工具面：dest_dir / src_dir 标了 optional，archive 仍必填")
    fun optionalParamsArePinned() {
        assertTrue(unzip().spec.parameters.first { it.name == "dest_dir" }.optional)
        assertTrue(zip().spec.parameters.first { it.name == "src_dir" }.optional)
        assertFalse(unzip().spec.parameters.first { it.name == "archive" }.optional, "archive 必填")
        assertFalse(zip().spec.parameters.first { it.name == "archive" }.optional, "archive 必填")
    }

    @Test
    @DisplayName("打包后覆盖同名包：第二次仍然成功（模型重试是常态）")
    fun zipOverwritesExistingArchive() = runBlocking {
        write("p/a.txt", "1")
        assertTrue(zip().execute(mapOf("src_dir" to "p", "archive" to "p.zip")) is ToolOutcome.Success)
        assertTrue(zip().execute(mapOf("src_dir" to "p", "archive" to "p.zip")) is ToolOutcome.Success)
        assertTrue(unzip().execute(mapOf("archive" to "p.zip", "dest_dir" to "back")) is ToolOutcome.Success)
    }
}
