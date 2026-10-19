package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.io.IOException
import java.nio.file.Paths

/**
 * **文件操作三件套**（P1-3，2026-10-18）—— 门禁。
 *
 * ## 这个测试类在防什么
 *
 * 三个工具都是**不可逆操作**，所以"成功路径能跑"远不够。这里每条破坏性语义都有断言：
 * 删非空目录不传 `recursive` 必须**失败且原样不动**；递归前必须**预扫描**（超限时
 * 一个文件都不许删）；`move`/`copy` 目标已存在必须**不覆盖**；`..` / 绝对路径 /
 * 工作区根一律拒绝；SAF 下目录删除/移动**明确拒绝**（不是静默半残）。
 *
 * 用**内存替身** `TreeFs` 而不是真 POSIX 目录：本类要验的是**工具层语义**
 * （预扫描、递归、失败文案、SAF 分支）；`RealWorkspaceFs.delete` 的存储层语义
 * 由 `:workspace` 的 `WorkspaceFsDeleteTest` 钉住。
 */
class PathToolsTest {

    // ============================================================ 删除

    @Test
    @DisplayName("★ 删文件：成功且真的没了")
    fun deletesFile() = runBlocking {
        val fs = TreeFs(files = mapOf("a.txt" to "x".toByteArray()))
        val r = DeletePathTool(fs).execute(mapOf("path" to "a.txt"))

        assertTrue(r is ToolOutcome.Success, "应当成功，实际：$r")
        assertFalse(fs.exists("a.txt"), "文件必须真的被删")
    }

    @Test
    @DisplayName("★ 删**空**目录：成功")
    fun deletesEmptyDir() = runBlocking {
        val fs = TreeFs(dirs = setOf("empty"))
        val r = DeletePathTool(fs).execute(mapOf("path" to "empty"))

        assertTrue(r is ToolOutcome.Success, "应当成功，实际：$r")
        assertFalse(fs.exists("empty"), "空目录必须真的被删")
    }

    @Test
    @DisplayName("★★ 删非空目录 + 没传 recursive ⇒ **失败且原样不动**（默认语义必须是最保守的）")
    fun refusesNonEmptyDirWithoutRecursive() = runBlocking {
        val fs = TreeFs(
            files = mapOf("d/a.txt" to "a".toByteArray(), "d/sub/b.txt" to "b".toByteArray()),
            dirs = setOf("d", "d/sub"),
        )
        val r = DeletePathTool(fs).execute(mapOf("path" to "d"))

        assertTrue(r is ToolOutcome.Failure, "非空目录不传 recursive 必须失败，实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("recursive"), "要告诉用户怎么继续（recursive=true）：$reason")
        assertTrue(reason.contains("不可撤销"), "必须警告不可撤销：$reason")
        assertTrue(fs.exists("d/a.txt"), "★ 失败时**一个文件都不许动**")
        assertTrue(fs.exists("d/sub/b.txt"), "★ 子目录内容也必须原样")
    }

    @Test
    @DisplayName("★★ recursive=true ⇒ 整棵删干净，且文案给出删除项数")
    fun recursiveDeletesWholeTree() = runBlocking {
        val fs = TreeFs(
            files = mapOf("d/a.txt" to "a".toByteArray(), "d/sub/b.txt" to "b".toByteArray()),
            dirs = setOf("d", "d/sub"),
        )
        val r = DeletePathTool(fs).execute(mapOf("path" to "d", "recursive" to "true"))

        assertTrue(r is ToolOutcome.Success, "递归删除应当成功，实际：$r")
        assertTrue((r as ToolOutcome.Success).detail.contains("不可撤销"), "成功文案也要提不可撤销：${r.detail}")
        assertFalse(fs.exists("d"), "整棵必须被删")
        assertFalse(fs.exists("d/sub/b.txt"), "深层文件必须被删")
    }

    @Test
    @DisplayName("★ 删不存在的路径 ⇒ 明确 Failure（不静默成功）")
    fun deleteMissingFails() = runBlocking {
        val r = DeletePathTool(TreeFs()).execute(mapOf("path" to "nope.txt"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("不存在"), "要点明不存在：${r.reason}")
    }

    @Test
    @DisplayName("★★ 递归删除**先预扫描**：条目超限时一个文件都不许删")
    fun recursivePreScanRejectsBeforeDeleting() = runBlocking {
        val many = (1..(Contract.FsOps.MAX_RECURSIVE_ENTRIES + 5)).associate {
            "d/f%05d.txt".format(it) to "x".toByteArray()
        }
        val fs = TreeFs(files = many, dirs = setOf("d"))
        val r = DeletePathTool(fs).execute(mapOf("path" to "d", "recursive" to "true"))

        assertTrue(r is ToolOutcome.Failure, "超限必须失败，实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("预扫描"), "要说清是**动手前**拒绝的：$reason")
        assertTrue(reason.contains(Contract.FsOps.MAX_RECURSIVE_ENTRIES.toString()), "要带上上限值：$reason")
        assertTrue(fs.exists("d/f00001.txt"), "★ 预扫描失败时**一个文件都不许删**")
    }

    @Test
    @DisplayName("★★ SAF（hasRealPath=false）：目录删除**明确拒绝**（文件可以）")
    fun safRefusesDirDeleteExplicitly() = runBlocking {
        val fs = TreeFs(dirs = setOf("d"), hasRealPath = false)
        val r = DeletePathTool(fs).execute(mapOf("path" to "d"))

        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("SAF"), "要点名 SAF：$reason")
        assertTrue(reason.contains("不支持删除目录"), "要说清哪件事不支持：$reason")
        assertTrue(reason.contains("文件"), "要给出可行范围（文件可以删）：$reason")
        assertTrue(fs.exists("d"), "拒绝时不许动目标")
    }

    @Test
    @DisplayName("★ SAF：**文件**删除照常可用（别把整条能力一刀切掉）")
    fun safStillDeletesFiles() = runBlocking {
        val fs = TreeFs(files = mapOf("a.txt" to "x".toByteArray()), hasRealPath = false)
        val r = DeletePathTool(fs).execute(mapOf("path" to "a.txt"))
        assertTrue(r is ToolOutcome.Success, "SAF 文件删除应当可用，实际：$r")
        assertFalse(fs.exists("a.txt"))
    }

    // ============================================================ 路径安全（三条工具都要拒）

    @Test
    @DisplayName("★★ 三条工具都拒绝 `..`（工作区外一律不许碰）")
    fun allToolsRejectDotDot() = runBlocking {
        val fs = TreeFs(files = mapOf("a.txt" to "x".toByteArray()))
        val calls = listOf(
            DeletePathTool(fs) to mapOf("path" to "../a.txt"),
            MovePathTool(fs) to mapOf("from" to "a.txt", "to" to "../b.txt"),
            CopyPathTool(fs) to mapOf("from" to "a.txt", "to" to "../b.txt"),
        )
        calls.forEach { (tool, args) ->
            val r = tool.execute(args)
            assertTrue(r is ToolOutcome.Failure, "${tool.spec.name} 必须拒绝 ..：$r")
            assertTrue(
                (r as ToolOutcome.Failure).reason.contains(".."),
                "${tool.spec.name} 的文案要点明 ..：${r.reason}",
            )
        }
    }

    @Test
    @DisplayName("★ 绝对路径与盘符一律拒绝；工作区根也不许当操作对象")
    fun rejectsAbsoluteAndRoot() = runBlocking {
        val fs = TreeFs(files = mapOf("a.txt" to "x".toByteArray()))
        listOf("/etc/passwd", "C:/Windows/x").forEach { p ->
            val r = DeletePathTool(fs).execute(mapOf("path" to p))
            assertTrue(r is ToolOutcome.Failure, "绝对路径必须拒绝：$r")
        }
        val root = DeletePathTool(fs).execute(mapOf("path" to ""))
        assertTrue(root is ToolOutcome.Failure, "空路径 = 工作区根，必须拒绝：$root")
        assertTrue(
            (root as ToolOutcome.Failure).reason.contains("根目录"),
            "文案要点明白 ${root.reason}",
        )
    }

    @Test
    @DisplayName("★ 非法 recursive 值 ⇒ 明确 Failure 并列出可接受值（不猜）")
    fun invalidRecursiveValueFails() = runBlocking {
        val fs = TreeFs(dirs = setOf("d"))
        val r = DeletePathTool(fs).execute(mapOf("path" to "d", "recursive" to "yes"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("true"), "要列出可接受值：${r.reason}")
    }

    // ============================================================ 移动

    @Test
    @DisplayName("★ 移动文件：目标出现、源消失")
    fun movesFile() = runBlocking {
        val fs = TreeFs(files = mapOf("a.txt" to "hello".toByteArray()))
        val r = MovePathTool(fs).execute(mapOf("from" to "a.txt", "to" to "b.txt"))

        assertTrue(r is ToolOutcome.Success, "实际：$r")
        assertFalse(fs.exists("a.txt"), "源必须删掉")
        assertEquals("hello", String(fs.readBytes("b.txt")), "目标内容必须一致")
        assertTrue((r as ToolOutcome.Success).detail.contains("非原子"), "文案必须说明非原子：${r.detail}")
    }

    @Test
    @DisplayName("★★ 移动/复制：目标已存在 ⇒ **失败不覆盖**，两边原样")
    fun refusesOverwrite() = runBlocking {
        val fs = TreeFs(files = mapOf("a.txt" to "A".toByteArray(), "b.txt" to "B".toByteArray()))

        val move = MovePathTool(fs).execute(mapOf("from" to "a.txt", "to" to "b.txt"))
        val copy = CopyPathTool(fs).execute(mapOf("from" to "a.txt", "to" to "b.txt"))

        listOf("move" to move, "copy" to copy).forEach { (name, r) ->
            assertTrue(r is ToolOutcome.Failure, "$name 必须拒绝覆盖：$r")
            assertTrue(
                (r as ToolOutcome.Failure).reason.contains("目标已存在"),
                "$name 文案要点明目标已存在：${r.reason}",
            )
        }
        assertEquals("A", String(fs.readBytes("a.txt")), "源不许动")
        assertEquals("B", String(fs.readBytes("b.txt")), "★ 目标原内容不许被覆盖")
    }

    @Test
    @DisplayName("★ 目标父目录不存在 ⇒ **失败不自动创建**（避免路径打错在别处建目录）")
    fun missingParentFails() = runBlocking {
        val fs = TreeFs(files = mapOf("a.txt" to "x".toByteArray()))
        val r = CopyPathTool(fs).execute(mapOf("from" to "a.txt", "to" to "nope/b.txt"))

        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("父目录不存在"), "要点明父目录：${r.reason}")
        assertFalse(fs.exists("nope"), "★ 不许偷偷建父目录")
    }

    @Test
    @DisplayName("★ 不能把目录移动/复制到它自己的子目录里")
    fun refusesIntoOwnSubtree() = runBlocking {
        val fs = TreeFs(
            files = mapOf("d/a.txt" to "x".toByteArray()),
            dirs = setOf("d", "d/sub"),
        )
        val move = MovePathTool(fs).execute(mapOf("from" to "d", "to" to "d/sub/d2"))
        val copy = CopyPathTool(fs).execute(mapOf("from" to "d", "to" to "d/sub/d2"))

        assertTrue(move is ToolOutcome.Failure && copy is ToolOutcome.Failure, "两条都必须拒绝")
        assertTrue(
            (move as ToolOutcome.Failure).reason.contains("子目录"),
            "文案要点明子目录：${move.reason}",
        )
        assertTrue((copy as ToolOutcome.Failure).reason.contains("子目录"), "同上：${copy.reason}")
    }

    @Test
    @DisplayName("★ from == to ⇒ 明确失败（不做无意义操作）")
    fun sameFromAndToFails() = runBlocking {
        val fs = TreeFs(files = mapOf("a.txt" to "x".toByteArray()))
        val move = MovePathTool(fs).execute(mapOf("from" to "a.txt", "to" to "a.txt"))
        val copy = CopyPathTool(fs).execute(mapOf("from" to "a.txt", "to" to "a.txt"))
        assertTrue(move is ToolOutcome.Failure && copy is ToolOutcome.Failure)
        assertTrue((move as ToolOutcome.Failure).reason.contains("相同"), "要说明相同：${move.reason}")
    }

    @Test
    @DisplayName("★ SAF：文件移动可用（复制 + 删文件两条都支持）；目录移动明确拒绝")
    fun safMoveSemantics() = runBlocking {
        val safFile = TreeFs(files = mapOf("a.txt" to "x".toByteArray()), hasRealPath = false)
        val ok = MovePathTool(safFile).execute(mapOf("from" to "a.txt", "to" to "b.txt"))
        assertTrue(ok is ToolOutcome.Success, "SAF 文件移动应当可用：$ok")

        val safDir = TreeFs(files = mapOf("d/a.txt" to "x".toByteArray()), dirs = setOf("d"), hasRealPath = false)
        val refused = MovePathTool(safDir).execute(mapOf("from" to "d", "to" to "e"))
        assertTrue(refused is ToolOutcome.Failure, "SAF 目录移动必须拒绝：$refused")
        assertTrue(
            (refused as ToolOutcome.Failure).reason.contains("不支持移动目录"),
            "要说清哪件事不支持：${refused.reason}",
        )
    }

    @Test
    @DisplayName("★★ 移动的**复制成功、删源失败** ⇒ 如实说「两份都在」（别让用户猜哪份是新的）")
    fun moveReportsPartialWhenSourceDeleteFails() = runBlocking {
        val fs = TreeFs(
            files = mapOf("a.txt" to "x".toByteArray()),
            failDelete = setOf("a.txt"),
        )
        val r = MovePathTool(fs).execute(mapOf("from" to "a.txt", "to" to "b.txt"))

        assertTrue(r is ToolOutcome.Failure, "删源失败必须失败（不能报「已移动」）：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("源未删除"), "要点明源未删：$reason")
        assertTrue(reason.contains("两份都在"), "★ 必须说清两份都在、别假设哪份最新：$reason")
        assertTrue(fs.exists("b.txt"), "目标确实已就位")
        assertTrue(fs.exists("a.txt"), "源确实还在")
    }

    // ============================================================ 复制

    @Test
    @DisplayName("★ 复制文件：**字节级**一致（含 0x00 / 高位字节）")
    fun copiesBinaryBytesExactly() = runBlocking {
        val bytes = byteArrayOf(0, 1, -1, 127, -128, 10, 13)
        val fs = TreeFs(files = mapOf("a.bin" to bytes))
        val r = CopyPathTool(fs).execute(mapOf("from" to "a.bin", "to" to "b.bin"))

        assertTrue(r is ToolOutcome.Success, "实际：$r")
        assertTrue(bytes.contentEquals(fs.readBytes("b.bin")), "字节必须逐字节一致")
        assertTrue(fs.exists("a.bin"), "复制后源必须还在")
    }

    @Test
    @DisplayName("★ 复制目录：递归建目录 + 逐文件复制")
    fun copiesDirectoryRecursively() = runBlocking {
        val fs = TreeFs(
            files = mapOf("src/a.txt" to "A".toByteArray(), "src/sub/b.txt" to "B".toByteArray()),
            dirs = setOf("src", "src/sub"),
        )
        val r = CopyPathTool(fs).execute(mapOf("from" to "src", "to" to "dst"))

        assertTrue(r is ToolOutcome.Success, "实际：$r")
        assertEquals("A", String(fs.readBytes("dst/a.txt")))
        assertEquals("B", String(fs.readBytes("dst/sub/b.txt")))
        assertTrue(fs.exists("src/sub/b.txt"), "源目录必须原样保留")
    }

    @Test
    @DisplayName("★★ 复制**先预扫描**：目录超限时目标目录都不许创建")
    fun copyPreScanRejectsBeforeCreating() = runBlocking {
        val many = (1..(Contract.FsOps.MAX_RECURSIVE_ENTRIES + 5)).associate {
            "src/f%05d.txt".format(it) to "x".toByteArray()
        }
        val fs = TreeFs(files = many, dirs = setOf("src"))
        val r = CopyPathTool(fs).execute(mapOf("from" to "src", "to" to "dst"))

        assertTrue(r is ToolOutcome.Failure, "超限必须失败：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("预扫描"), "要说清是预扫描阶段：${r.reason}")
        assertFalse(fs.exists("dst"), "★ 预扫描失败时目标目录都不许创建")
    }

    @Test
    @DisplayName("★ 复制中途失败 ⇒ 尽力清理目标半成品并如实说明")
    fun copyCleansPartialTarget() = runBlocking {
        val fs = TreeFs(
            files = mapOf("src/ok.txt" to "A".toByteArray(), "src/bad.txt" to "B".toByteArray()),
            dirs = setOf("src"),
            failWrite = setOf("dst/bad.txt"),
        )
        val r = CopyPathTool(fs).execute(mapOf("from" to "src", "to" to "dst"))

        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("已清理"), "要说明已清理半成品：$reason")
        assertFalse(fs.exists("dst"), "本次新建的目标目录应被清理掉")
        assertTrue(fs.exists("src/ok.txt"), "源不许动")
    }

    // ============================================================ 分组/装配门禁

    @Test
    @DisplayName("★ 分组表覆盖三个工具名（漏登记 ⇒ 检索静默失灵）")
    fun groupsCoverAllTools() {
        val fs = TreeFs()
        val tools = PathTools.create(fs)
        PathTools.assertConsistent(tools) // 不抛即通过
        assertEquals(
            listOf("copy_path", "delete_path", "move_path", "restore_path"),
            tools.map { it.spec.name }.sorted(),
            "工具名是冻结前缀的一部分，改名即毁缓存",
        )
        tools.forEach { tool ->
            assertTrue(tool.spec.name in PathTools.GROUPS, "${tool.spec.name} 必须登记组")
        }
    }

    // ============================================================ 快照 / 撤销（2026-10-19）

    @Test
    @DisplayName("★★ 删文件前保存快照 ⇒ restore_path 能把原文恢复回来")
    fun deletedFileCanBeRestored() = runBlocking {
        val fs = TreeFs(files = mapOf("keep.txt" to "重要内容".toByteArray()))
        val del = DeletePathTool(fs).execute(mapOf("path" to "keep.txt"))
        assertTrue(del is ToolOutcome.Success, "实际：$del")
        assertFalse(fs.exists("keep.txt"), "前提：文件已被删")

        val restore = RestorePathTool(fs).execute(mapOf("path" to "keep.txt"))
        assertTrue(restore is ToolOutcome.Success, "有快照就必须能恢复：$restore")
        assertEquals("重要内容", fs.readText("keep.txt"), "恢复的必须是删除前的原文")
    }

    @Test
    @DisplayName("★ 没快照时 restore_path 如实失败（不假装恢复）")
    fun restoreWithoutSnapshotFails() = runBlocking {
        val fs = TreeFs()
        val r = RestorePathTool(fs).execute(mapOf("path" to "nope.txt"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue(
            (r as ToolOutcome.Failure).reason.contains("没有"),
            "失败原因要说清是'没有快照'：${r.reason}",
        )
    }

    @Test
    @DisplayName("★ 快照超过上限 ⇒ 回执如实说'未保存'（不静默）")
    fun tooLargeSnapshotIsReported() = runBlocking {
        val big = "x".repeat(Contract.FsOps.CHECKPOINT_MAX_BYTES + 1)
        val fs = TreeFs(files = mapOf("big.txt" to big.toByteArray()))
        val r = DeletePathTool(fs).execute(mapOf("path" to "big.txt"))
        assertTrue(r is ToolOutcome.Success, "删除本身不受快照上限影响：$r")
        assertTrue(
            (r as ToolOutcome.Success).detail.contains("未保存快照"),
            "超限必须如实说明，不能让用户以为还能撤销：${r.detail}",
        )
    }

    @Test
    @DisplayName("★ 重名工具 ⇒ assertConsistent 当场失败")
    fun duplicateNamesFailLoudly() {
        val dup = object : AgentTool {
            override val spec = ToolSpec("delete_path", "重名替身")
            override suspend fun execute(args: Map<String, String>): ToolOutcome = ToolOutcome.Success("x")
        }
        assertThrows(IllegalArgumentException::class.java) {
            PathTools.assertConsistent(listOf(dup, dup))
        }
    }
}

// ======================================================================== 内存替身

/**
 * 工具层语义测试用的内存工作区。
 *
 * · `hasRealPath = false` ⇒ 模拟 SAF（目录删除**返回 false**，与 `AndroidSafStorage.delete` 一致）
 * · `failDelete` / `failWrite` ⇒ 注入 IO 失败，用来验"失败时如实报、且清理半成品"
 */
private class TreeFs(
    files: Map<String, ByteArray> = emptyMap(),
    dirs: Set<String> = emptySet(),
    hasRealPath: Boolean = true,
    private val failDelete: Set<String> = emptySet(),
    private val failWrite: Set<String> = emptySet(),
) : WorkspaceFs {

    override val info: WorkspaceInfo = WorkspaceInfo(
        Paths.get("/placeholder-not-a-workspace"),
        "tree",
        hasRealPath = hasRealPath,
    )

    /** SAF 语义（hasRealPath=false）下目录一律不删 —— 与 `AndroidSafStorage.delete` 一致。 */
    private val allowDirDelete: Boolean = hasRealPath

    private val fileMap = linkedMapOf<String, ByteArray>().apply { putAll(files) }
    private val dirSet = linkedSetOf<String>().apply {
        addAll(dirs)
        // 自动补父目录（与 mkdirs 语义一致）
        dirs.forEach { d ->
            var cur = d
            while (cur.contains('/')) {
                cur = cur.substringBeforeLast('/')
                add(cur)
            }
        }
    }

    override suspend fun list(relativeDir: String): List<FileEntry> {
        val dir = relativeDir.trim().trimEnd('/')
        val prefix = if (dir.isEmpty()) "" else "$dir/"
        val childDirs = linkedSetOf<String>()
        val childFiles = linkedMapOf<String, FileEntry>()
        for (d in dirSet) {
            if (!d.startsWith(prefix) || d == dir) continue
            val rest = d.removePrefix(prefix)
            if (rest.isEmpty() || rest.contains('/')) continue
            childDirs += prefix + rest
        }
        for ((p, bytes) in fileMap) {
            if (!p.startsWith(prefix)) continue
            val rest = p.removePrefix(prefix)
            if (rest.isEmpty() || rest.contains('/')) continue
            childFiles[p] = FileEntry(p, bytes.size.toLong(), isDirectory = false)
        }
        return childDirs.map { FileEntry(it, 0L, isDirectory = true) } + childFiles.values
    }

    override suspend fun readText(relativePath: String): String =
        String(readBytes(relativePath), Charsets.UTF_8)

    override suspend fun writeText(relativePath: String, content: String): Long =
        writeBytes(relativePath, content.toByteArray(Charsets.UTF_8))

    override suspend fun readBytes(relativePath: String): ByteArray =
        fileMap[relativePath] ?: throw IllegalArgumentException("文件不存在：$relativePath")

    override suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long {
        if (relativePath in failWrite) throw IOException("模拟写入失败：$relativePath")
        fileMap[relativePath] = bytes
        mkdirs(relativePath.substringBeforeLast('/', ""))
        return bytes.size.toLong()
    }

    override suspend fun exists(relativePath: String): Boolean {
        val p = relativePath.trim().trimEnd('/')
        if (p.isEmpty()) return true
        return p in fileMap || p in dirSet || fileMap.keys.any { it.startsWith("$p/") }
    }

    override suspend fun mkdirs(relativeDir: String) {
        val p = relativeDir.trim().trimEnd('/')
        if (p.isEmpty()) return
        dirSet += p
        var cur = p
        while (cur.contains('/')) {
            cur = cur.substringBeforeLast('/')
            dirSet += cur
        }
    }

    override suspend fun delete(relativePath: String): Boolean {
        if (relativePath in failDelete) throw IOException("模拟删除失败：$relativePath")
        fileMap.remove(relativePath)?.let { return true }
        if (relativePath !in dirSet) return false
        // 与 AndroidSafStorage.delete 一致：目录一律不删（hasRealPath=false）；
        // POSIX 语义下**空目录**可以删，非空返回 false（让工具层去做递归）。
        if (!allowDirDelete) return false
        val children = list(relativePath)
        if (children.isNotEmpty()) return false
        dirSet.remove(relativePath)
        return true
    }
}
