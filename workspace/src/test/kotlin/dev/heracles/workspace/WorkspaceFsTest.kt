package dev.heracles.workspace

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path

/**
 * 路径越界防护测试 —— **安全关键**，不允许有漏网。
 *
 * 这是本地沙箱（`00-需求文档.md` §2.13.1）的第一道防线。
 * 一旦漏掉，agent 就能读写整个文件系统。
 */
class PathGuardTest {

    @TempDir
    lateinit var root: Path

    @Test
    @DisplayName("正常相对路径可以解析")
    fun normalPath() {
        val p = PathGuard.resolve(root, "src/main/App.kt")
        assertTrue(p.startsWith(root.toAbsolutePath().normalize()))
        assertTrue(p.toString().endsWith("App.kt"))
    }

    @Test
    @DisplayName("★ 相对路径穿越必须被拒")
    fun rejectsRelativeTraversal() {
        listOf(
            "../secret.txt",
            "../../etc/passwd",
            "src/../../outside.txt",
            "a/b/../../../c",
        ).forEach { evil ->
            assertThrows(PathEscapeException::class.java, { PathGuard.resolve(root, evil) },
                "未拦截路径穿越：$evil")
        }
    }

    @Test
    @DisplayName("★ 绝对路径必须被拒")
    fun rejectsAbsolutePath() {
        listOf(
            "/etc/passwd",
            "/data/data/com.other.app/files",
            "\\windows\\system32",
            "C:/Windows/System32",
        ).forEach { evil ->
            assertThrows(PathEscapeException::class.java, { PathGuard.resolve(root, evil) },
                "未拦截绝对路径：$evil")
        }
    }

    @Test
    @DisplayName("★ 符号链接指向工作区外必须被拒")
    fun rejectsSymlinkEscape() {
        val outside = Files.createTempDirectory("heracles-outside")
        try {
            Files.write(outside.resolve("secret.txt"), "机密".toByteArray(StandardCharsets.UTF_8))
            val link = root.resolve("sneaky")
            runCatching { Files.createSymbolicLink(link, outside) }
                .onFailure { return }   // Windows 无权限时跳过

            assertThrows(PathEscapeException::class.java, {
                PathGuard.resolve(root, "sneaky/secret.txt")
            }, "未拦截符号链接逃逸")
        } finally {
            outside.toFile().deleteRecursively()
        }
    }

    @Test
    @DisplayName("空路径必须被拒")
    fun rejectsEmpty() {
        assertThrows(PathEscapeException::class.java) { PathGuard.resolve(root, "   ") }
    }

    @Test
    @DisplayName("工作区根自身可解析")
    fun rootItself() {
        val p = PathGuard.resolve(root, ".")
        assertEquals(root.toAbsolutePath().normalize(), p)
    }
}

/**
 * 工作区读写测试。
 *
 * 全部用 `@TempDir`，**不依赖真机、不留垃圾** —— 这是把 `:workspace`
 * 做成纯 JVM 模块的全部意义。
 */
class WorkspaceFsTest {

    @TempDir
    lateinit var dir: Path

    private fun ws() = RealWorkspaceFs.open(dir, "test")

    @Test
    @DisplayName("写→读往返（含中文与 emoji）")
    fun writeReadRoundTrip() = kotlinx.coroutines.runBlocking {
        val fs = ws()
        val content = "# 标题\n中文内容 ✅\n\t缩进\n"
        fs.writeText("docs/说明.md", content)
        assertEquals(content, fs.readText("docs/说明.md"))
    }

    @Test
    @DisplayName("写入自动创建父目录")
    fun autoCreateParent() = kotlinx.coroutines.runBlocking {
        val fs = ws()
        fs.writeText("a/b/c/deep.txt", "x")
        assertTrue(fs.exists("a/b/c/deep.txt"))
    }

    @Test
    @DisplayName("★ 列表顺序必须确定 —— 顺序不固定会让 prompt 变动、缓存归零")
    fun listIsDeterministic() = kotlinx.coroutines.runBlocking {
        val fs = ws()
        // 故意乱序创建
        listOf("z.txt", "a.txt", "m.txt").forEach { fs.writeText(it, "x") }
        Files.createDirectories(dir.resolve("dirB"))
        Files.createDirectories(dir.resolve("dirA"))

        val first = fs.list().map { it.relativePath }
        repeat(5) { assertEquals(first, fs.list().map { it.relativePath }) }

        // 目录在前，同类按路径排序
        assertEquals(listOf("dirA", "dirB", "a.txt", "m.txt", "z.txt"), first)
    }

    @Test
    @DisplayName("★ 写入也必须过路径防护 —— 不能只有读受限")
    fun writeAlsoGuarded() = kotlinx.coroutines.runBlocking {
        val fs = ws()
        assertThrows(PathEscapeException::class.java) {
            kotlinx.coroutines.runBlocking { fs.writeText("../evil.txt", "x") }
        }
        assertThrows(PathEscapeException::class.java) {
            kotlinx.coroutines.runBlocking { fs.writeText("/tmp/evil.txt", "x") }
        }
    }

    @Test
    @DisplayName("读不存在的文件必须抛错，不得静默返回空串")
    fun readMissingThrows() = kotlinx.coroutines.runBlocking {
        assertThrows(IllegalArgumentException::class.java) { kotlinx.coroutines.runBlocking { ws().readText("nope.txt") } }
    }

    @Test
    @DisplayName("超大文件必须被拒 —— 直接读入会挤占上下文预算")
    fun rejectsOversizedFile() = kotlinx.coroutines.runBlocking {
        val fs = ws()
        Files.write(dir.resolve("big.txt"), ByteArray((MAX_READ_BYTES + 100).toInt()) { 'a'.code.toByte() })
        assertThrows(IllegalArgumentException::class.java) { kotlinx.coroutines.runBlocking { fs.readText("big.txt") } }
    }
}

/**
 * `WorkspaceStorage.delete` 的测试（2026-10-10 补）。
 *
 * ## 为什么要单独测这个
 *
 * 首版接口**只有写没有删** —— 于是 `SessionStore.deleteSession`
 * 删不掉消息文件，只能用"写空"代替，在磁盘上留下空文件。
 * 现在补上了，就要有测试守住它的三条语义约定：
 *
 * 1. 只删**文件**，不递归删目录（工作区是用户的真实项目文件夹）
 * 2. 目标不存在时返回 `false`（幂等，不抛）
 * 3. 路径穿越必须被拦（删除比读取更危险，绝不能漏）
 */
class PosixStorageDeleteTest {

    @TempDir
    lateinit var root: Path

    private fun storage() = PosixStorage(root)

    @Test
    @DisplayName("★★ info.rootPath 必须是**存储根**，不是进程 CWD（真机：App 的 CWD 是 / ⇒ 引擎拿 / 当工作区）")
    fun infoRootPathIsStorageRootNotCwd() {
        val fs = StorageBackedWorkspaceFs(PosixStorage(root))
        assertEquals(
            root.toAbsolutePath().normalize(),
            fs.info.rootPath,
            "适配层曾用 Paths.get(\".\").toAbsolutePath() 凑数 —— CLI 的 CWD 恰好是工作区根，所以一直没暴露；" +
                "App 进程内 CWD 是 /，于是 ZipFs/对齐/chmod 全在跟根目录打交道（见实测-12 §13）",
        )
    }

    @Test
    @DisplayName("★ SAF（没有真实根）必须明说 realRootPath=null，不许假装有路径")
    fun safHasNoRealRoot() {
        val fake = MemoryStorage()
        assertEquals(null, fake.realRootPath, "SAF 只有 content:// URI，没有绝对路径")
        // 适配层仍要给出一个非空 WorkspaceInfo（UI 要展示），但不能当真路径用
        val adapted = StorageBackedWorkspaceFs(fake)
        assertEquals("saf", adapted.info.name)
        // ★ F6a：SAF 适配后必须**如实**标出"没有真实路径"，构建类工具据此拒绝
        assertTrue(!adapted.info.hasRealPath, "SAF 工作区的 hasRealPath 必须是 false")
        // 对照：POSIX 存储适配后 hasRealPath = true
        assertTrue(
            StorageBackedWorkspaceFs(PosixStorage(root)).info.hasRealPath,
            "POSIX 工作区的 hasRealPath 必须是 true（零回退）",
        )
    }

    @Test
    @DisplayName("删掉存在的文件，返回 true 且文件真的没了")
    fun deletesExistingFile() = kotlinx.coroutines.runBlocking {
        val s = storage()
        s.writeText("a.txt", "hi")
        assertTrue(s.exists("a.txt"))

        assertTrue(s.delete("a.txt"), "删除应当返回 true")
        assertTrue(!s.exists("a.txt"), "文件应当真的没了")
    }

    @Test
    @DisplayName("删不存在的文件返回 false，不抛（幂等）")
    fun deleteMissingIsIdempotent() = kotlinx.coroutines.runBlocking {
        assertTrue(!storage().delete("nope.txt"))
    }

    @Test
    @DisplayName("★ 不删目录 —— 递归删除用户项目文件夹不可逆")
    fun refusesToDeleteDirectory() = kotlinx.coroutines.runBlocking {
        val s = storage()
        s.writeText("sub/inner.txt", "x")   // 建出 sub/ 目录

        assertTrue(!s.delete("sub"), "目录不该被删")
        assertTrue(s.exists("sub/inner.txt"), "目录内容必须原样还在")
    }

    @Test
    @DisplayName("★ 删除也必须过路径防护 —— 删除比读取更危险")
    fun deleteIsGuarded() {
        // 在容器外放一个"受害者"文件，确认删不掉它
        val outside = root.parent.resolve("victim-${System.nanoTime()}.txt")
        Files.write(outside, "must survive".toByteArray(StandardCharsets.UTF_8))
        try {
            kotlinx.coroutines.runBlocking {
                assertThrows(PathEscapeException::class.java) {
                    kotlinx.coroutines.runBlocking { storage().delete("../${outside.fileName}") }
                }
            }
            assertTrue(Files.exists(outside), "容器外的文件必须原样存在")
        } finally {
            Files.deleteIfExists(outside)
        }
    }

    @Test
    @DisplayName("空路径返回 false（不误删根）")
    fun blankPathReturnsFalse() = kotlinx.coroutines.runBlocking {
        assertTrue(!storage().delete(""))
    }
}

/**
 * 内存版 [WorkspaceStorage] —— 测试专用（`:workspace` 里造不出 Android 的 SAF 实现）。
 *
 * [realRootPath] 默认 `null` ⇒ 模拟 SAF（没有真实根）；传一个 `Path` 就是 POSIX。
 */
private class MemoryStorage(
    private val displayNameOverride: String = "saf",
    private val realRoot: Path? = null,
) : WorkspaceStorage {

    private val texts = linkedMapOf<String, String>()
    private val blobs = linkedMapOf<String, ByteArray>()

    override val displayName: String get() = displayNameOverride
    override val locationLabel: String get() = "content://tree/x"
    override val realRootPath: Path? get() = realRoot

    override suspend fun isWritable(): Boolean = true
    override suspend fun list(relativeDir: String): List<FileEntry> = emptyList()
    override suspend fun readText(relativePath: String): String = texts[relativePath] ?: ""
    override suspend fun writeText(relativePath: String, content: String): Long {
        texts[relativePath] = content
        return content.toByteArray(StandardCharsets.UTF_8).size.toLong()
    }

    override suspend fun readBytes(relativePath: String): ByteArray =
        blobs[relativePath] ?: throw IllegalArgumentException("文件不存在：$relativePath")

    override suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long {
        blobs[relativePath] = bytes
        return bytes.size.toLong()
    }

    override suspend fun exists(relativePath: String): Boolean =
        relativePath in texts || relativePath in blobs

    override suspend fun mkdirs(relativeDir: String) = Unit

    override suspend fun delete(relativePath: String): Boolean {
        val text = texts.remove(relativePath)
        val blob = blobs.remove(relativePath)
        return text != null || blob != null
    }
}

/**
 * 只实现**文本通道**的 [WorkspaceFs] 替身 —— 钉住"接口默认体必须显式抛"这条纪律。
 *
 * 为什么需要它：`readBytes`/`writeBytes` 的默认体是 `throw UnsupportedOperationException`。
 * 默认体最危险的下场是**后人为了修红把它改成 `return ByteArray(0)`** —— 那就从"漏实现会炸"
 * 变成了"漏实现会静默骗人"。所以这里断言：**抛，且消息可读**。
 */
private class TextOnlyFs(private val dir: Path) : WorkspaceFs {
    override val info = WorkspaceInfo(dir, "text-only")
    override suspend fun list(relativeDir: String): List<FileEntry> = emptyList()
    override suspend fun readText(relativePath: String): String = "x"
    override suspend fun writeText(relativePath: String, content: String): Long = content.length.toLong()
    override suspend fun exists(relativePath: String): Boolean = false
    override suspend fun mkdirs(relativeDir: String) = Unit
}

/**
 * **字节通道**（2026-10-18，F6a / ADR-032）—— F6b"镜像进 staging + 产物回写"的地基。
 *
 * 盯住四件事：
 * 1. **逐字节一致**：二进制（0x00…0xFF）走字节通道**不做任何编码转换**（文本通道会改坏它）；
 * 2. **上限是"抛"不是"截断"**：截断的字节流 = 坏文件，比失败更糟；
 * 3. **不是后门**：`../` 逃逸在字节通道上照旧被 `PathGuard` 拒；
 * 4. **默认体显式抛**：漏实现必须立刻炸（见 [TextOnlyFs]）。
 */
class ByteIoTest {

    @TempDir
    lateinit var root: Path

    private fun fs() = RealWorkspaceFs.open(root)

    @Test
    @DisplayName("★ 字节往返：二进制 0x00–0xFF / 空文件 / 中文路径，逐字节一致")
    fun byteRoundTripIsExact() = kotlinx.coroutines.runBlocking {
        val f = fs()

        val binary = ByteArray(256) { it.toByte() } // 0x00 … 0xFF（含 NUL 与高位字节）
        assertEquals(256L, f.writeBytes("bin/data.bin", binary))
        assertArrayEquals(binary, f.readBytes("bin/data.bin"), "字节通道不许做任何编码转换")

        assertEquals(0L, f.writeBytes("空 文件.bin", ByteArray(0)), "空文件必须能写")
        assertArrayEquals(ByteArray(0), f.readBytes("空 文件.bin"), "空文件必须能读回")

        val cn = "第一行\n第二行".toByteArray(StandardCharsets.UTF_8)
        f.writeBytes("中文/说明.txt", cn)
        assertArrayEquals(cn, f.readBytes("中文/说明.txt"), "中文路径必须能往返")
    }

    @Test
    @DisplayName("★ 覆盖写：重复写入**截断**旧内容（不留尾巴）")
    fun overwriteTruncatesOldBytes() = kotlinx.coroutines.runBlocking {
        val f = fs()
        f.writeBytes("a.bin", ByteArray(100) { 1 })
        f.writeBytes("a.bin", ByteArray(3) { 2 })
        assertArrayEquals(ByteArray(3) { 2 }, f.readBytes("a.bin"), "覆盖写必须先截断")
    }

    @Test
    @DisplayName("★ 字节通道不是后门：../ 逃逸照旧被 PathGuard 拒")
    fun pathGuardStillApplies() {
        assertThrows(PathEscapeException::class.java) {
            kotlinx.coroutines.runBlocking { fs().readBytes("../escape.bin") }
        }
        assertThrows(PathEscapeException::class.java) {
            kotlinx.coroutines.runBlocking { fs().writeBytes("../escape.bin", ByteArray(1)) }
        }
    }

    @Test
    @DisplayName("★ 上限是「抛」不是「截断」：超限抛 + 消息可读；恰好等于上限放行")
    fun overLimitIsRejectedNotTruncated() {
        val e = assertThrows(IllegalArgumentException::class.java) {
            readBytesLimited(java.io.ByteArrayInputStream(ByteArray(5)), maxBytes = 4)
        }
        assertTrue(e.message!!.contains("上限"), "消息要说明撞的是上限：${e.message}")
        assertTrue(e.message!!.contains("不截断"), "消息要说明不会返回截断的字节：${e.message}")

        // 边界：恰好等于上限必须放行（不能多拦一个字节）
        assertArrayEquals(
            ByteArray(4),
            readBytesLimited(java.io.ByteArrayInputStream(ByteArray(4)), maxBytes = 4),
        )
    }

    @Test
    @DisplayName("★ 两个上限是**两条独立的线**：二进制（内存预算）必须远大于文本（上下文预算）")
    fun textAndBinaryLimitsAreDistinctBudgets() {
        assertTrue(
            MAX_BINARY_BYTES > MAX_READ_BYTES,
            "二进制上限($MAX_BINARY_BYTES)必须大于文本上限($MAX_READ_BYTES) —— " +
                "前者搬资源/APK（内存预算），后者防日志塞满上下文",
        )
    }

    @Test
    @DisplayName("★ 接口默认体必须**显式抛**（防后人改成 return ByteArray(0) 来修红）")
    fun defaultImplFailsLoudly() {
        val textOnly = TextOnlyFs(root)
        val read = assertThrows(UnsupportedOperationException::class.java) {
            kotlinx.coroutines.runBlocking { textOnly.readBytes("a.bin") }
        }
        assertTrue(read.message!!.contains("字节 IO"), "消息必须点明缺的是什么：${read.message}")

        val write = assertThrows(UnsupportedOperationException::class.java) {
            kotlinx.coroutines.runBlocking { textOnly.writeBytes("a.bin", ByteArray(1)) }
        }
        assertTrue(write.message!!.contains("字节 IO"), "消息必须点明缺的是什么：${write.message}")
    }

    @Test
    @DisplayName("★ 适配层：字节 IO 委托到底层存储（SAF 字节流由这条通道喂上来）")
    fun adapterDelegatesByteIo() = kotlinx.coroutines.runBlocking {
        val adapted = StorageBackedWorkspaceFs(MemoryStorage())
        val bytes = byteArrayOf(0, -1, 127, 10, 13)

        assertEquals(5L, adapted.writeBytes("x/y.bin", bytes))
        assertArrayEquals(bytes, adapted.readBytes("x/y.bin"))
        assertTrue(!adapted.info.hasRealPath, "SAF 适配层的 hasRealPath 必须是 false")
    }
}

/**
 * `WorkspaceFs.delete`（P1-3，2026-10-18）—— 工具层 `delete_path` 的底座。
 *
 * ## 三条被钉住的语义
 *
 * 1. **不递归**：目录非空 ⇒ **抛**（`Files.delete` 的 `DirectoryNotEmptyException`）。
 *    递归是**工具层**的决定（它先预扫描、再逐层删）；存储层替它决定就等于
 *    "任何调用者只要调 delete 就能删整棵树"。
 * 2. **不存在 ⇒ false**：与 [WorkspaceFs.delete] 的 KDoc 一致（不抛，幂等）。
 * 3. **越界 ⇒ 抛 `PathEscapeException`**：删除比读取更危险，判据不许有任何漏网。
 */
class WorkspaceFsDeleteTest {

    @TempDir
    lateinit var root: Path

    private fun fs() = RealWorkspaceFs.open(root)

    @Test
    @DisplayName("★ 删文件：返回 true 且真的没了")
    fun deletesFile() = kotlinx.coroutines.runBlocking {
        Files.writeString(root.resolve("a.txt"), "x")
        assertTrue(fs().delete("a.txt"))
        assertTrue(!Files.exists(root.resolve("a.txt")), "文件必须被删掉")
    }

    @Test
    @DisplayName("★ 删**空**目录：成功")
    fun deletesEmptyDir() = kotlinx.coroutines.runBlocking {
        Files.createDirectories(root.resolve("d"))
        assertTrue(fs().delete("d"))
        assertTrue(!Files.exists(root.resolve("d")), "空目录必须被删掉")
    }

    @Test
    @DisplayName("★★ 删非空目录：**抛错且内容原样**（递归是工具层的决定，存储层不替它做）")
    fun nonEmptyDirThrowsAndKeepsContent() {
        Files.createDirectories(root.resolve("d"))
        Files.writeString(root.resolve("d/keep.txt"), "keep")

        assertThrows(java.io.IOException::class.java) {
            kotlinx.coroutines.runBlocking { fs().delete("d") }
        }
        assertTrue(Files.exists(root.resolve("d/keep.txt")), "非空目录必须原样保留（不许删一半）")
    }

    @Test
    @DisplayName("★ 删不存在的路径：返回 false（幂等，不抛）")
    fun missingReturnsFalse() = kotlinx.coroutines.runBlocking {
        assertTrue(!fs().delete("nope.txt"))
    }

    @Test
    @DisplayName("★★ 路径穿越必须被 PathGuard 拒绝（删除比读取更危险）")
    fun escapeIsRejected() {
        Files.writeString(root.resolve("outside-target.txt"), "x")
        assertThrows(PathEscapeException::class.java) {
            kotlinx.coroutines.runBlocking { fs().delete("../outside-target.txt") }
        }
        assertTrue(Files.exists(root.resolve("outside-target.txt")), "越界目标不许被动到")
    }

    @Test
    @DisplayName("★ 工作区根不许删")
    fun rootIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            kotlinx.coroutines.runBlocking { fs().delete("") }
        }
    }

    @Test
    @DisplayName("★ 适配层：delete 必须委托存储层（SAF 的 DocumentFile 删文件由这条通道喂上来）")
    fun adapterDelegatesDelete() = kotlinx.coroutines.runBlocking {
        val adapted = StorageBackedWorkspaceFs(MemoryStorage())
        adapted.writeText("a.txt", "x")
        assertTrue(adapted.delete("a.txt"))
        assertTrue(!adapted.exists("a.txt"), "删完必须不存在")
    }

    @Test
    @DisplayName("★ 接口默认体必须**显式抛**（防后人改成 return false 来修红）")
    fun defaultImplFailsLoudly() {
        val textOnly = TextOnlyFs(root)
        val e = assertThrows(UnsupportedOperationException::class.java) {
            kotlinx.coroutines.runBlocking { textOnly.delete("a.txt") }
        }
        assertTrue(e.message!!.contains("删除"), "消息必须点明缺的是什么：${e.message}")
    }
}
