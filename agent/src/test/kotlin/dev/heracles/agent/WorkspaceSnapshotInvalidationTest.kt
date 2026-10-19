package dev.heracles.agent

import dev.heracles.core.provider.CacheStats
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
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **「变更才注入」+ 压缩交互的门禁**（F8b / P2-1）—— 零真机、零网络。
 *
 * ## 观测点（照抄 F7c `NativeToolFlowTest` 的做法）
 *
 * 一律看**下一轮真实请求的消息列表** —— 不看实现、不读私有状态。
 * 快照注入是 `Turn.User` append，所以"注入了没有 / 注入了几份 / 是哪一份"
 * 都能从消息列表里**数出来**，而不是被相信。
 *
 * 快照消息的判定：`role == USER` **且** 内容以 `【工作区现状` 开头。
 * 这个前缀条件是必要的：压缩摘要走 `Turn.System`，若真模型在摘要里
 * 原样抄了快照块，它**不能**被算成"我们又注入了一份"。
 *
 * ## 守的不变量
 *
 * | # | 不变量 | 若破坏，用户看到 |
 * |---|---|---|
 * | 1 | ★★ 事实没变 ⇒ **不**新增块（判据 = 快照文本去标记） | 每轮重抄一遍，白烧 token（F8b 白做） |
 * | 2 | ★★ 事实变了（含**改名不改数量**）⇒ 追加 1 块 + 新轮次标记 | 改了内容却不注入 ⇒ 模型按旧现状干活 |
 * | 3 | ★★ 压缩重建会话后，**新会话里必须有快照**（压缩后同一轮就补） | 长会话压缩一次 ⇒ 模型**从此再也看不到**工作区现状 |
 * | 4 | ★★ 不出现两份**同轮次**快照；压缩前那份不残留 | 同一份现状出现两次 ⇒ 模型以为发生了两次变化 |
 * | 5 | ★★ 压缩路径**零回退**：开关只允许"增加快照"，其余消息逐字节相同 | 关着开关时压缩行为被改动（F8a 的零回退被侵蚀） |
 *
 * ⚠️ **已知边界**（有测试钉住，不是漏测）：同名 + 同大小、只有内容变了 ⇒ 快照文本不变
 * ⇒ 不重新注入。理由：快照**刻意**不含 mtime 也不含文件内容（`FileEntry` 的 KDoc 禁令 +
 * 我们不做内容回放）。要收紧只能让判据含"本轮发生过成功写"，那会退化成"写一次注入一次"。
 */
class WorkspaceSnapshotInvalidationTest {

    // ------------------------------------------------------------ 替身

    /** 可变内存树（F8b 需要"跑的过程中树变了"）。 */
    private class MutableTreeFs(initial: Map<String, String>) : WorkspaceFs {
        val files = LinkedHashMap(initial)
        override val info = WorkspaceInfo(java.nio.file.Path.of("/ws"), "tree")

        var listCalls = 0
            private set

        fun put(path: String, content: String) {
            files[path] = content
        }

        override suspend fun list(relativeDir: String): List<FileEntry> {
            listCalls++
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
        override suspend fun writeText(relativePath: String, content: String): Long {
            files[relativePath] = content
            return content.length.toLong()
        }
        override suspend fun exists(relativePath: String): Boolean = files.containsKey(relativePath)
        override suspend fun mkdirs(relativeDir: String) {}
    }

    /**
     * `read_file`：**只读**工具。
     *
     * 为什么"事实没变"那几条要用它而不是 [WriteTool]：
     * **一次成功的写本身就是事实变化** —— `records` 多一条成功写 ⇒ 快照的
     * `【最近改动】` 那一行会变 ⇒ 按判据**应该**重新注入。
     * 用"报成功但不碰树"的写工具去测"没变"，测的其实是**假事实**
     * （工具骗了文件系统，快照却如实记下了这次写）。
     */
    private class ReadTool : AgentTool {
        override val spec = ToolSpec(
            name = "read_file",
            description = "读文件",
            parameters = listOf(ToolParam("path", "string", "路径")),
        )

        var executeCount = 0
            private set

        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            executeCount++
            return ToolOutcome.Success("文件内容")
        }
    }

    /** `write_file`：执行时按 [onExecute] 改树（真实地"模型写了文件 ⇒ 树变了"）。 */
    private class WriteTool(
        private val fs: MutableTreeFs,
        private val onExecute: (MutableTreeFs) -> Unit,
    ) : AgentTool {
        override val spec = ToolSpec(
            name = "write_file",
            description = "写文件",
            parameters = listOf(ToolParam("path", "string", "路径"), ToolParam("content", "string", "内容")),
        )

        var executeCount = 0
            private set

        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            executeCount++
            onExecute(fs)
            return ToolOutcome.Success("已写入")
        }
    }

    /**
     * 按轮次脚本化的 provider；**摘要调用与轮次调用分开计数**。
     *
     * `compaction` 那次是 `provider.generate(...)`，而且**只传 prompt、不传 messages**
     * （见 `AgentLoop` 的摘要请求）—— 所以"轮次请求"与"摘要请求"可以用
     * `messages != null` 干净地区分开，不必靠 prompt 文本猜。
     */
    private class TurnProvider(
        private val turns: List<String>,
        private val summary: String = "【摘要】已完成若干步骤",
    ) : ModelProvider {
        override val id = "scripted:f8b"
        override val kind = ProviderKind.CLOUD
        override val capabilities = ProviderCapabilities(
            supportsGrammar = true,
            supportsJsonSchema = true,
            supportsPrefixCache = true,
            needsPrewarm = true,
        )

        val requests = mutableListOf<GenerateRequest>()
        var summaryCalls = 0
            private set
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

        override suspend fun generate(request: GenerateRequest): Result<GenerateResult> {
            requests += request
            summaryCalls++
            return Result.success(GenerateResult(summary, CacheStats.withoutCacheReporting(0, 0), FinishReason.STOP))
        }

        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
            requests += request
            val t = turns.getOrElse(turn++) { turns.last() }
            t.forEach { emit(StreamChunk.text(it.toString())) }
            emit(StreamChunk.done(FinishReason.STOP, emptyList()))
        }

        override fun lastStreamCache(): CacheStats = CacheStats.withoutCacheReporting(0, 0)

        /** 只看**轮次**请求（摘要请求的 `messages` 为 null）。 */
        fun turnRequests(): List<GenerateRequest> = requests.filter { it.messages != null }
    }

    // ------------------------------------------------------------ 观测工具

    private fun snapshots(req: GenerateRequest) = req.messages.orEmpty()
        .filter { it.role == ChatRole.USER && it.content.startsWith("【工作区现状") }

    private fun marker(text: String): String? =
        Regex("""【工作区现状 · 第 (\d+) 轮】""").find(text)?.groupValues?.get(1)

    private fun toolCall(path: String) = """{"tool":"write_file","args":{"path":"$path","content":"x"}}"""

    private fun readCall(path: String) = """{"tool":"read_file","args":{"path":"$path"}}"""

    private fun <T : AgentTool> loopOf(
        provider: TurnProvider,
        fs: MutableTreeFs,
        tool: T,
        enabled: Boolean,
        contextLimit: Int = 0,
    ): AgentRunResult = runBlocking {
        provider.load(ProviderConfig())
        AgentLoop(
            provider,
            fs,
            listOf(tool),
            maxTurns = 3,
            contextLimit = contextLimit,
            snapshotInjectionEnabled = enabled,
        ).run("干活")
    }

    // ============================================================ 1. 变更判定

    @Test
    @DisplayName("★★ 事实没变 ⇒ 第二轮**不**新增块（观测点：第二轮真实请求的消息列表）")
    fun unchangedTreeDoesNotReinject() = runBlocking {
        val fs = MutableTreeFs(mapOf("seed.txt" to "x"))
        val tool = ReadTool() // 只读：不写 ⇒ 树与「最近改动」都不变
        val p = TurnProvider(listOf(readCall("seed.txt"), """{"final":"done"}"""))
        loopOf(p, fs, tool, enabled = true)

        assertEquals(1, tool.executeCount, "对照组：工具真的执行过（否则'没变'是假的）")
        val second = p.turnRequests()[1]
        assertEquals(
            1, snapshots(second).size,
            "★ 事实没变 ⇒ 不许再注入一份（F8b 的全部意义）。" +
                "当前第二轮请求里的快照条数：${snapshots(second).size}",
        )
        assertEquals("1", marker(snapshots(second).single().content), "留下的仍是第 1 轮那份")
    }

    @Test
    @DisplayName("★ 一次**成功的写**本身就是事实变化：快照的「最近改动」变了 ⇒ 应当重新注入")
    fun successfulWriteCountsAsAChangeEvenIfTheTreeLooksTheSame() = runBlocking {
        val fs = MutableTreeFs(mapOf("seed.txt" to "x"))
        // 这个写工具**不碰树**（故意不真实）：用它来证明"判据包含了成功写这一事实"
        val tool = WriteTool(fs) { /* 不碰树 */ }
        val p = TurnProvider(listOf(toolCall("out.txt"), """{"final":"done"}"""))
        loopOf(p, fs, tool, enabled = true)

        val snaps = snapshots(p.turnRequests()[1])
        assertEquals(
            2, snaps.size,
            "★ 写成功了 ⇒ `records` 多一条成功写 ⇒ `【最近改动】out.txt` 出现在新快照里 ⇒ 事实**变了**。" +
                "这是有意的：工具说它写了，框架就必须把这件事实告诉模型",
        )
        assertTrue(snaps.last().content.contains("【最近改动】out.txt"), "新快照要记下这次写：${snaps.last().content}")
        assertFalse(snaps.first().content.contains("【最近改动】"), "第 1 轮还没有任何改动：${snaps.first().content}")
    }

    @Test
    @DisplayName("★★ 工具写了文件 ⇒ 树变了 ⇒ 追加 1 块且带**新轮次标记**")
    fun changedTreeInjectsNewBlockWithNewMarker() = runBlocking {
        val fs = MutableTreeFs(mapOf("seed.txt" to "x"))
        val tool = WriteTool(fs) { it.put("out.txt", "y") }
        val p = TurnProvider(listOf(toolCall("out.txt"), """{"final":"done"}"""))
        loopOf(p, fs, tool, enabled = true)

        val snaps = snapshots(p.turnRequests()[1])
        assertEquals(2, snaps.size, "树变了 ⇒ **追加**一块（不是改写旧的）")
        assertEquals("1", marker(snaps.first().content), "旧块保持原样（append-only）")
        assertEquals(
            "2", marker(snaps.last().content),
            "★ 新块必须带新轮次标记 —— 后出现的天然是权威那份",
        )
        assertTrue(
            snaps.last().content.contains("out.txt"),
            "新块描述的是**变更后**的事实：${snaps.last().content}",
        )
        assertFalse(
            snaps.first().content.contains("out.txt"),
            "旧块不许被改写成新事实（那就是改写历史）",
        )
    }

    @Test
    @DisplayName("★★ 判据是**快照文本**不是条目数：改名（数量不变）必须被判为变更")
    fun renameWithSameEntryCountChangesTheFacts() = runBlocking {
        val a = WorkspaceSnapshot.render(MutableTreeFs(mapOf("a.txt" to "1", "b.txt" to "2")), emptyList(), 1)!!
        val b = WorkspaceSnapshot.render(MutableTreeFs(mapOf("a.txt" to "1", "c.txt" to "2")), emptyList(), 1)!!
        assertEquals(a.lines().size, b.lines().size, "条目数相同 —— 这正是'数文件'式判据会漏掉的情形")
        assertTrue(
            WorkspaceSnapshot.factsOf(a) != WorkspaceSnapshot.factsOf(b),
            "★ 判据必须落在快照文本上：改名 = 变更",
        )
    }

    @Test
    @DisplayName("★ 已知边界（取舍，不是漏测）：同名同大小、只改内容 ⇒ 快照文本不变 ⇒ 不注入")
    fun sameNameSameSizeContentChangeIsNotDetected() = runBlocking {
        val a = WorkspaceSnapshot.render(MutableTreeFs(mapOf("a.txt" to "xx")), emptyList(), 1)!!
        val b = WorkspaceSnapshot.render(MutableTreeFs(mapOf("a.txt" to "yy")), emptyList(), 1)!!
        assertEquals(
            WorkspaceSnapshot.factsOf(a), WorkspaceSnapshot.factsOf(b),
            "★ 这是**已知边界**：快照刻意不含 mtime、也不含文件内容（`FileEntry` 的 KDoc 禁令 + " +
                "我们不做内容回放）⇒ 同路径同大小改内容检测不到。要收紧只能把'本轮发生过成功写'算进判据，" +
                "那会退化成'写一次注入一次'（每轮都注入）。取舍已记账，未验：真机是否真的踩得到",
        )
    }

    @Test
    @DisplayName("★ factsOf 纯函数：轮次标记不算变更")
    fun factsStripTheTurnMarker() {
        val t1 = "【工作区现状 · 第 1 轮】\n[FILE] a.txt  (1B)"
        val t5 = "【工作区现状 · 第 5 轮】\n[FILE] a.txt  (1B)"
        assertEquals("[FILE] a.txt  (1B)", WorkspaceSnapshot.factsOf(t1))
        assertEquals(
            WorkspaceSnapshot.factsOf(t1), WorkspaceSnapshot.factsOf(t5),
            "★ 轮次标记不算变更 —— 否则'第 N 轮'每轮都不同 ⇒ 判据恒为'变了' ⇒ 退化成每轮注入",
        )
    }

    // ============================================================ 2. 压缩交互（三种情形）

    @Test
    @DisplayName("★★ 压缩后：新会话里**必须有**快照（压缩前那份不残留、也不出现重复轮次）")
    fun compactionReinjectsSnapshotIntoTheFreshSession() = runBlocking {
        val fs = MutableTreeFs(mapOf("seed.txt" to "x"))
        val tool = ReadTool() // 只读：专测"压缩 + 之后没变"
        val p = TurnProvider(listOf(readCall("seed.txt"), """{"final":"done"}"""))
        loopOf(p, fs, tool, enabled = true, contextLimit = 1)

        assertEquals(1, p.summaryCalls, "★ 压缩必须真的发生了 —— 否则这条断言毫无意义（假绿）")
        val second = p.turnRequests()[1]
        assertTrue(
            second.messages.orEmpty().any { it.content.contains("此前任务进展摘要") },
            "新会话里应当有摘要（压缩确实重建了会话）",
        )
        val snaps = snapshots(second)
        assertEquals(
            1, snaps.size,
            "★ 压缩重建会话后**恰好一份**快照：压缩前那份随旧会话消失（不残留），" +
                "新会话里的这份是压缩后同一轮补上的（重置判据的作用）",
        )
        val markers = snaps.map { marker(it.content) }
        assertEquals(markers.distinct().size, markers.size, "★ 不许出现两份**同轮次**快照：$markers")
        assertTrue(
            snaps.single().content.contains("seed.txt"),
            "★ 压缩后模型**下一轮真的看得到**现状（这条就是'断言钉被消费'）：${snaps.single().content}",
        )
    }

    @Test
    @DisplayName("★★ 压缩后再变更 ⇒ 仍注入新的一份（第三情形）")
    fun changeAfterCompactionStillInjects() = runBlocking {
        val fs = MutableTreeFs(mapOf("seed.txt" to "x"))
        val tool = WriteTool(fs) { it.put("out.txt", "y") }
        val p = TurnProvider(listOf(toolCall("out.txt"), """{"final":"done"}"""))
        loopOf(p, fs, tool, enabled = true, contextLimit = 1)

        assertEquals(1, p.summaryCalls, "压缩真的发生了（对照）")
        val snaps = snapshots(p.turnRequests()[1])
        assertEquals(2, snaps.size, "压缩后一轮补的那份 + 变更后追加的那份 = 2")
        val markers = snaps.map { marker(it.content) }
        assertEquals(markers.distinct().size, markers.size, "轮次标记不得重复：$markers")
        assertTrue(
            snaps.last().content.contains("out.txt"),
            "最新那份必须是**变更后**的事实：${snaps.last().content}",
        )
        assertFalse(
            snaps.first().content.contains("out.txt"),
            "压缩后补的那份是变更前的事实 —— 不许被就地改成新事实",
        )
    }

    @Test
    @DisplayName("★★ 压缩**失败**（摘要为空）⇒ 会话保持原样 ⇒ 判据**不许**被重置（否则第二份重复快照）")
    fun failedCompactionKeepsSessionAndDoesNotDuplicateSnapshot() = runBlocking {
        val fs = MutableTreeFs(mapOf("seed.txt" to "x"))
        val tool = ReadTool()
        val p = TurnProvider(listOf(readCall("seed.txt"), """{"final":"done"}"""), summary = "")
        loopOf(p, fs, tool, enabled = true, contextLimit = 1)

        assertEquals(1, p.summaryCalls, "压缩尝试过（这次是为了失败）")
        val second = p.turnRequests()[1]
        assertFalse(
            second.messages.orEmpty().any { it.content.contains("此前任务进展摘要") },
            "摘要为空 ⇒ 压缩**不生效**，会话必须保持原样（'宁可慢也不丢上下文'）",
        )
        val snaps = snapshots(second)
        assertEquals(
            1, snaps.size,
            "★ 这条钉住重置的**位置**：`lastSnapshotFacts = null` 只能写在「会话真的被换掉」那一行。" +
                "若写成「压缩一触发就重置」，压缩失败时旧会话里的快照还在、却又补一份 ⇒ " +
                "两份同轮次快照（违反压缩情形②）",
        )
    }

    // ============================================================ 3. 压缩路径的零回退
    @Test
    @DisplayName("★★ 压缩路径零回退：开关只允许**增加**快照，其余消息逐字节相同（且关着时不读工作区）")
    fun disabledCompactionPathIsByteIdentical() = runBlocking {
        // 两条链路：同样的脚本、同样的初始树、同样触发压缩，唯一差别是开关
        fun fresh() = MutableTreeFs(mapOf("seed.txt" to "x"))

        val fsOff = fresh()
        val toolOff = WriteTool(fsOff) { it.put("out.txt", "y") }
        val pOff = TurnProvider(listOf(toolCall("out.txt"), """{"final":"done"}"""))
        loopOf(pOff, fsOff, toolOff, enabled = false, contextLimit = 1)

        val fsOn = fresh()
        val toolOn = WriteTool(fsOn) { it.put("out.txt", "y") }
        val pOn = TurnProvider(listOf(toolCall("out.txt"), """{"final":"done"}"""))
        loopOf(pOn, fsOn, toolOn, enabled = true, contextLimit = 1)

        assertEquals(1, pOff.summaryCalls, "关着开关时压缩也必须照常发生（零回退的另一半）")
        assertEquals(1, pOn.summaryCalls, "开着时压缩同样发生（对照）")

        val offReqs = pOff.turnRequests()
        val onReqs = pOn.turnRequests()
        assertEquals(offReqs.size, onReqs.size, "轮数不得因开关而变")
        for (i in offReqs.indices) {
            val filtered = onReqs[i].messages.orEmpty()
                .filterNot { it.role == ChatRole.USER && it.content.startsWith("【工作区现状") }
            assertEquals(
                offReqs[i].messages.orEmpty(), filtered,
                "★ 第 ${i + 1} 轮：开关**只允许新增快照**，其余消息必须逐字节相同" +
                    "（关着的那条链路里连'压缩摘要 + 用户请求'的顺序都不许变）",
            )
        }
        assertTrue(
            offReqs.all { snapshots(it).isEmpty() },
            "关着开关时整条链路（含压缩）里不许出现任何快照",
        )
        assertEquals(
            0, fsOff.listCalls,
            "★ 关着开关 ⇒ 连压缩路径也不读工作区（零回退是结构性的，不是'读了不用'）",
        )
        assertTrue(fsOn.listCalls > 0, "开着开关当然要读（对照组成立）")
    }
}
