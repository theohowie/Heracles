package dev.heracles.agent

import dev.heracles.core.provider.CacheStats
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.GenerateResult
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.ProviderCapabilities
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ProviderHealth
import dev.heracles.core.provider.ProviderKind
import dev.heracles.core.provider.StreamChunk
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **「读不到」≠「空工作区」**（F8a 纪律的全局失败格，2026-10-18 补）。
 *
 * ## 补的是哪个洞
 *
 * F8a 对**单个**目录读取失败会计数并写"有 N 个目录读取失败 —— 不是「空目录」"，
 * 但**全部**目录都读不到时：`files` 空、`recent` 空 ⇒ `render` 返回 `null`
 * ⇒ **"整个工作区不可读"被静默当成了"没什么可说"**。
 *
 * 这正是"省略比错误更难发现"那一类：错误会被断言抓，省略只会让模型
 * **合理地**走错方向（"没文件 ⇒ 我新建吧"，然后覆盖用户的东西）。
 *
 * ## 四个不变量
 *
 * | # | 不变量 |
 * |---|---|
 * | 1 | 全部目录读不到 ⇒ **必须**输出 ⚠️ 陈述（不是 `null`、不是"0 个文件"） |
 * | 2 | 部分读不到 ⇒ 保留原有计数陈述，且**照旧**不把失败的目录当空目录 |
 * | 3 | 真的空工作区（可读、无文件）⇒ 仍然 `null`（不注入空壳 —— 这条别被顺手改坏） |
 * | 4 | 开关关着 ⇒ `listCalls == 0`（零回退不变） |
 *
 * 观测点：纯函数看 `render` 的文本；"真的会被模型看到"用**下一轮真实请求的消息列表**证。
 */
class WorkspaceSnapshotUnreadableTest {

    // ------------------------------------------------------------ 替身

    /** 可控失败的只读内存树：`failDirs` 里的目录 `list` 抛异常（模拟 EACCES/SAF 拒绝）。 */
    private class FailingTreeFs(
        private val files: Map<String, String>,
        private val failDirs: Set<String>,
    ) : WorkspaceFs {
        override val info = WorkspaceInfo(java.nio.file.Path.of("/ws"), "tree")

        var listCalls = 0
            private set

        override suspend fun list(relativeDir: String): List<FileEntry> {
            listCalls++
            if (relativeDir in failDirs) throw java.io.IOException("EACCES: 读不到 $relativeDir")
            val prefix = if (relativeDir.isEmpty()) "" else "$relativeDir/"
            val children = LinkedHashMap<String, Boolean>()
            for (p in files.keys) {
                if (!p.startsWith(prefix)) continue
                val rest = p.removePrefix(prefix)
                val slash = rest.indexOf('/')
                if (slash < 0) children[p] = false else children[prefix + rest.substring(0, slash)] = true
            }
            return children.map { (path, isDir) ->
                FileEntry(path, if (isDir) 0L else (files[path]?.length ?: 0).toLong(), isDir)
            }
        }

        override suspend fun readText(relativePath: String): String = files[relativePath] ?: ""
        override suspend fun writeText(relativePath: String, content: String): Long = content.length.toLong()
        override suspend fun exists(relativePath: String): Boolean = files.containsKey(relativePath)
        override suspend fun mkdirs(relativeDir: String) {}
    }

    /** 只读工具：执行成功但**不碰树**（避免"成功写"本身算事实变化，干扰本类的观测）。 */
    private class ReadTool : AgentTool {
        override val spec = ToolSpec(
            name = "read_file",
            description = "读文件",
            parameters = listOf(ToolParam("path", "string", "路径")),
        )

        override suspend fun execute(args: Map<String, String>): ToolOutcome = ToolOutcome.Success("文件内容")
    }

    private class ScriptedProvider(private val turns: List<String>) : ModelProvider {
        override val id = "scripted:unreadable"
        override val kind = ProviderKind.CLOUD
        override val capabilities = ProviderCapabilities(true, true, true, true)

        val requests = mutableListOf<GenerateRequest>()
        private var turn = 0
        private var loaded = false

        override suspend fun load(config: ProviderConfig): Result<Unit> {
            loaded = true
            return Result.success(Unit)
        }

        override suspend fun prewarm(frozenPrefix: String): Result<Unit> = Result.success(Unit)
        override suspend fun release() {
            loaded = false
        }

        override fun health(): ProviderHealth = ProviderHealth(loaded, "scripted")
        override suspend fun generate(request: GenerateRequest): Result<GenerateResult> =
            Result.success(GenerateResult("（不该被调用：本用例不压缩）", CacheStats.withoutCacheReporting(0, 0), FinishReason.STOP))

        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
            requests += request
            val t = turns.getOrElse(turn++) { turns.last() }
            t.forEach { emit(StreamChunk.text(it.toString())) }
            emit(StreamChunk.done(FinishReason.STOP, emptyList()))
        }

        override fun lastStreamCache(): CacheStats = CacheStats.withoutCacheReporting(0, 0)
    }

    private fun snapshots(msgs: List<ChatMessage>?) = msgs.orEmpty()
        .filter { it.role == ChatRole.USER && it.content.startsWith("【工作区现状") }

    // ============================================================ 1. 全部读不到

    @Test
    @DisplayName("★★ 全部目录读不到 ⇒ 输出 ⚠️ 明确陈述（不是 null、不是\"共 0 个文件\"）")
    fun allDirsUnreadableIsAnExplicitStatement() = runBlocking {
        val fs = FailingTreeFs(emptyMap(), failDirs = setOf(""))
        val text = WorkspaceSnapshot.render(fs, emptyList(), 1)

        assertNotNull(text, "★ 读不到**不许**返回 null —— null 会被读成\"没什么可说\"（≈\"这里没东西\"）")
        assertTrue(text!!.contains("无法读取工作区"), "要点名\"读不到\"：$text")
        assertTrue(text.contains("全部读取失败"), "要说清是**全部**失败（= 未知），不是部分：$text")
        assertTrue(text.contains("不是「空工作区」"), "必须把\"读不到\"与\"空\"显式区分开：$text")
        assertFalse(text.contains("共 0 个文件"), "★ 0 个文件是**断言**，读不到时无权断言：$text")
        assertTrue(
            WorkspaceSnapshot.factsOf(text).isNotBlank(),
            "★ 事实部分要有内容 ⇒ F8b 的变更判定/注入才会把它当一份有效快照",
        )
    }

    @Test
    @DisplayName("★★ 读不到的陈述**真的会进请求**（观测点：下一轮真实消息列表）")
    fun unreadableSnapshotActuallyReachesTheModel() = runBlocking {
        val fs = FailingTreeFs(emptyMap(), failDirs = setOf(""))
        val provider = ScriptedProvider(listOf(readCall("a.txt"), """{"final":"done"}"""))
        provider.load(ProviderConfig())
        AgentLoop(
            provider,
            fs,
            listOf(ReadTool()),
            maxTurns = 3,
            snapshotInjectionEnabled = true,
        ).run("干活")

        val first = provider.requests.first()
        val snaps = snapshots(first.messages)
        assertEquals(1, snaps.size, "第一轮就该注入一份（否则模型根本不知道读不到）")
        assertTrue(
            snaps.single().content.contains("无法读取工作区"),
            "★ 模型收到的就是\"读不到\"这句话：${snaps.single().content}",
        )
    }

    // ============================================================ 2. 部分读不到

    @Test
    @DisplayName("★ 部分目录读不到 ⇒ 保留计数陈述，且其余部分照常陈述")
    fun partialFailureKeepsTheRestOfTheStatement() = runBlocking {
        val fs = FailingTreeFs(mapOf("a.txt" to "x", "sub/b.txt" to "y"), failDirs = setOf("sub"))
        val text = WorkspaceSnapshot.render(fs, emptyList(), 1)!!

        assertTrue(text.contains("a.txt"), "读得到的部分必须照常列出：$text")
        assertTrue(text.contains("共 1 个文件"), "计数要如实：$text")
        assertTrue(text.contains("1 个目录读取失败"), "失败的目录要计数：$text")
        assertTrue(text.contains("不是「空目录」"), "原有措辞不许退化：$text")
        assertFalse(text.contains("全部读取失败"), "这不是\"全部失败\"（根可读）：$text")
    }

    @Test
    @DisplayName("★★ 根可读但**一个文件都没有**、子目录全读不到 ⇒ 也不许沉默、不许说\"0 个文件\"")
    fun readableButEmptyRootWithUnreadableSubdirIsNotSilent() = runBlocking {
        val fs = FailingTreeFs(mapOf("sub/b.txt" to "y"), failDirs = setOf("sub"))
        val text = WorkspaceSnapshot.render(fs, emptyList(), 1)

        assertNotNull(text, "★ 有目录读不到就不能返回 null（否则\"未知\"被说成\"没有\"）")
        assertFalse(text!!.contains("共 0 个文件"), "★ 不许断言 0 个文件：$text")
        assertTrue(text.contains("1 个目录读取失败"), "要把\"内容未知\"说出来：$text")
    }

    // ============================================================ 3. 边界与零回退

    @Test
    @DisplayName("★ 真的空工作区（可读、无文件、无改动）⇒ 仍然 null —— 这条不许被顺手改坏")
    fun genuinelyEmptyReadableWorkspaceIsStillNull() = runBlocking {
        val fs = FailingTreeFs(emptyMap(), failDirs = emptySet())
        assertEquals(null, WorkspaceSnapshot.render(fs, emptyList(), 1))
        assertEquals(1, fs.listCalls, "只探了根目录（对照）")
    }

    @Test
    @DisplayName("★★ 开关关着 ⇒ 一个字节都不碰：listCalls == 0，请求里没有任何快照")
    fun disabledSwitchTouchesNothingEvenWhenUnreadable() = runBlocking {
        val fs = FailingTreeFs(emptyMap(), failDirs = setOf(""))
        val provider = ScriptedProvider(listOf(readCall("a.txt"), """{"final":"done"}"""))
        provider.load(ProviderConfig())
        AgentLoop(
            provider,
            fs,
            listOf(ReadTool()),
            maxTurns = 3,
            snapshotInjectionEnabled = false,
        ).run("干活")

        assertEquals(0, fs.listCalls, "★ 关着开关时连\"读不到\"都不许去读")
        assertTrue(
            provider.requests.all { snapshots(it.messages).isEmpty() },
            "关着开关时不许出现任何快照",
        )
    }

    private fun readCall(path: String) = """{"tool":"read_file","args":{"path":"$path"}}"""
}
