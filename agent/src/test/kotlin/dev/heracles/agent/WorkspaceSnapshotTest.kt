package dev.heracles.agent

import dev.heracles.core.contract.Contract
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
import dev.heracles.core.tool.ToolCall
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **工作区快照门禁**（F8a / P2-1「跨轮记忆」）—— 零真机、零网络。
 *
 * ## 这个文件守的是什么
 *
 * `WorkspaceSnapshot` 本身很朴素，但它踩的是**最容易塌的两块地基**：
 * 前缀缓存（由 append-only 保证）与"如实陈述"（模型会拿它当事实）。
 *
 * | # | 不变量 | 若破坏，用户看到 |
 * |---|---|---|
 * | 1 | ★★ **纯函数**：同一棵树 ⇒ 逐字节相同（含 list 顺序被打乱） | 每轮前缀抖 ⇒ 缓存命中率塌（铁律 1） |
 * | 2 | ★★ **只读**：只调 `list`，写调用数 == 0 | "看一眼工作区"把用户文件改了 |
 * | 3 | ★★ **截断如实计数**（行数 / 遍历 / 字符三条闸） | 模型以为"文件不存在"，在错误前提上瞎干 |
 * | 4 | ★★ 读不到的目录**不当空目录**（如实上报条数） | 权限问题被伪装成"这里没东西" |
 * | 5 | ★★ 「最近改动」只认**成功**的写类工具 | 被拦截的写被写成"已完成"（H-1 同源的假信息） |
 * | 6 | ★★ 不含时间戳/绝对路径 | 时间进 prompt（`02` §1.1 禁止清单）；SAF 下还会是假路径 |
 * | 7 | ★★ **开关关着 ⇒ 一个字节都不碰**（连 render 都不调） | F8a 的"零回退"失去结构保证 |
 *
 * ⚠️ **未验**：真模型会不会被快照误导（例如看到 `dist/` 就以为已经构建过）。
 * 本文件只能证明"文本里写的是事实"，证明不了"模型会正确使用事实"。
 */
class WorkspaceSnapshotTest {

    // ------------------------------------------------------------ 替身：内存树

    /**
     * 内存工作区树（`Map<相对路径, 内容>`）。
     *
     * · [reverseOrder]：让 `list` 返回**与排序相反**的顺序 —— 用来证明
     *   "输出不依赖 `list` 的返回顺序"（SAF 与 POSIX 的顺序并不一致）
     * · [failDirs]：列出即抛（模拟权限失败）
     * · 写调用计数：用来钉住"快照**只读**"
     */
    private class TreeFs(
        private val files: Map<String, String> = emptyMap(),
        private val reverseOrder: Boolean = false,
        private val failDirs: Set<String> = emptySet(),
    ) : WorkspaceFs {
        override val info = WorkspaceInfo(java.nio.file.Path.of("/ws"), "tree")

        var listCalls = 0
            private set
        var writeCalls = 0
            private set
        var mkdirCalls = 0
            private set

        override suspend fun list(relativeDir: String): List<FileEntry> {
            listCalls++
            if (relativeDir in failDirs) throw RuntimeException("Permission denied: $relativeDir")
            val prefix = if (relativeDir.isEmpty()) "" else "$relativeDir/"
            val children = LinkedHashMap<String, Boolean>()
            for (p in files.keys) {
                if (!p.startsWith(prefix)) continue
                val rest = p.removePrefix(prefix)
                val slash = rest.indexOf('/')
                if (slash < 0) children[p] = false else children[prefix + rest.substring(0, slash)] = true
            }
            val entries = children.map { (path, isDir) ->
                FileEntry(path, if (isDir) 0L else (files[path]?.length ?: 0).toLong(), isDir)
            }
            return if (reverseOrder) entries.reversed() else entries
        }

        override suspend fun readText(relativePath: String): String = files[relativePath] ?: ""
        override suspend fun writeText(relativePath: String, content: String): Long {
            writeCalls++
            return content.length.toLong()
        }
        override suspend fun exists(relativePath: String): Boolean = files.containsKey(relativePath)
        override suspend fun mkdirs(relativeDir: String) {
            mkdirCalls++
        }
    }

    // ------------------------------------------------------------ 替身：按轮次脚本化的 provider

    private class ScriptedProvider(private val texts: List<String>) : ModelProvider {
        override val id = "scripted:snapshot"
        override val kind = ProviderKind.CLOUD
        override val capabilities = ProviderCapabilities(
            supportsGrammar = true,
            supportsJsonSchema = true,
            supportsPrefixCache = true,
            needsPrewarm = true,
        )

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

        override suspend fun generate(request: GenerateRequest): Result<GenerateResult> {
            requests += request
            val t = texts.getOrElse(turn++) { texts.last() }
            return Result.success(GenerateResult(t, CacheStats.withoutCacheReporting(0, 0), FinishReason.STOP))
        }

        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
            requests += request
            val t = texts.getOrElse(turn++) { texts.last() }
            t.forEach { emit(StreamChunk.text(it.toString())) }
            emit(StreamChunk.done(FinishReason.STOP, emptyList()))
        }

        override fun lastStreamCache(): CacheStats = CacheStats.withoutCacheReporting(0, 0)
    }

    // ------------------------------------------------------------ 记录构造

    private fun record(
        index: Int,
        tool: String? = null,
        path: String? = null,
        succeeded: Boolean? = null,
    ) = TurnRecord(
        index = index,
        userText = "任务",
        rawOutput = "",
        toolCall = tool?.let { ToolCall(it, if (path != null) mapOf("path" to path) else emptyMap()) },
        toolResult = if (succeeded == true) "ok" else null,
        verdict = if (tool != null) "工具成功" else "直接回答",
        cache = CacheStats.withoutCacheReporting(0, 0),
        wallMs = 1L,
        toolSucceeded = succeeded,
    )

    // ============================================================ 1. 纯函数 / 确定性

    @Test
    @DisplayName("★★ 同一棵树 ⇒ 逐字节相同（两次调用、以及 list 顺序被打乱之后）")
    fun renderIsPureIncludingListOrder() = runBlocking {
        val tree = mapOf(
            "AndroidManifest.xml" to "m",
            "src/Main.kt" to "fun main() {}",
            "src/res/strings.xml" to "<r/>",
            "README.md" to "hi",
        )
        val a = WorkspaceSnapshot.render(TreeFs(tree), emptyList(), 1)
        val b = WorkspaceSnapshot.render(TreeFs(tree), emptyList(), 1)
        val shuffled = WorkspaceSnapshot.render(TreeFs(tree, reverseOrder = true), emptyList(), 1)

        assertNotNull(a)
        assertEquals(a, b, "同一棵树两次渲染必须逐字节相同（否则前缀每轮抖 ⇒ 缓存塌）")
        assertEquals(
            a, shuffled,
            "★ 输出**不许**依赖 `list` 的返回顺序：SAF 与 POSIX 顺序不一致，" +
                "靠顺序会让 App 与 CLI 的 prompt 不同",
        )
        assertTrue(a!!.contains("共 4 个文件"), "四个文件都要被数进去：$a")
        assertTrue(a.contains("src/Main.kt"), "嵌套文件要在树里：$a")
    }

    @Test
    @DisplayName("★★ 不含时间戳、不含绝对路径（时间进 prompt 是禁止项；SAF 下还会是假路径）")
    fun renderHasNoTimestampOrAbsolutePath() = runBlocking {
        val text = WorkspaceSnapshot.render(TreeFs(mapOf("a.txt" to "x")), emptyList(), 3)!!
        assertFalse(
            Regex("""\d{4}-\d{2}-\d{2}""").containsMatchIn(text),
            "不许出现日期（时间戳进 prompt 会让缓存归零）：$text",
        )
        assertFalse(Regex("""\d{2}:\d{2}""").containsMatchIn(text), "不许出现时刻：$text")
        assertFalse(text.contains("/ws"), "不许出现工作区根（SAF 下那是占位路径，是假的）：$text")
        assertFalse(text.contains("\n/"), "不许出现绝对路径行：$text")
    }

    // ============================================================ 2. 只读

    @Test
    @DisplayName("★★ 快照只读：只调 list，写 / 建目录调用数必须为 0")
    fun renderNeverWrites() = runBlocking {
        val fs = TreeFs(mapOf("a.txt" to "x", "d/b.txt" to "y"))
        WorkspaceSnapshot.render(fs, listOf(record(1, "write_file", "c.txt", true)), 1)
        assertTrue(fs.listCalls > 0, "当然要读目录")
        assertEquals(0, fs.writeCalls, "★ 快照**绝不**写文件（看一眼工作区不该改用户文件）")
        assertEquals(0, fs.mkdirCalls, "★ 也不许建目录")
    }

    // ============================================================ 3. 三条闸 + 如实计数

    @Test
    @DisplayName("★★ 行数闸：超出上限必须**如实说**还有多少项，不许静默截断")
    fun entryCapIsReportedHonestly() = runBlocking {
        val tree = (1..10).associate { "f%02d.txt".format(it) to "x" }
        val text = WorkspaceSnapshot.render(TreeFs(tree), emptyList(), 1, maxEntries = 3)!!
        assertTrue(text.contains("f01.txt"), "留下的必须是排序后的前 3 个：$text")
        assertFalse(text.contains("f10.txt"), "被截掉的不许出现：$text")
        assertTrue(
            text.contains("另有 7 项未列出"),
            "★ 必须写清还有几项 —— 静默截断会让模型以为'工作区就这么大'（然后在错误前提上干活）：$text",
        )
        assertTrue(text.contains("共 10 个文件"), "总数要如实：$text")
    }

    @Test
    @DisplayName("★★ 遍历闸：被兜住时只能说「至少 N 个」，不许编一个精确总数")
    fun walkCapDegradesToAtLeast() = runBlocking {
        val tree = (1..10).associate { "f%02d.txt".format(it) to "x" }
        val text = WorkspaceSnapshot.render(TreeFs(tree), emptyList(), 1, maxEntries = 200, maxWalk = 4)!!
        assertTrue(
            text.contains("至少"),
            "★ 遍历在上限处停止 ⇒ 总数是**下界**，不能报成精确值：$text",
        )
        assertFalse(text.contains("共 10 个文件"), "不许把下界写成精确总数：$text")
        assertTrue(
            text.contains("遍历已在 4 项处停止"),
            "★ 还要说清是被**谁**兜住的（成本闸和展示闸是两回事，混着说等于没说清）：$text",
        )
    }

    @Test
    @DisplayName("★ 字符闸：超出硬上限必须截断并**标注**，且长度真的收敛")
    fun charCapClampsAndMarks() = runBlocking {
        val tree = (1..50).associate { "very-long-file-name-%03d.kt".format(it) to "x".repeat(20) }
        val text = WorkspaceSnapshot.render(TreeFs(tree), emptyList(), 1, maxChars = 600)!!
        assertTrue(text.contains("已截断"), "截断必须留痕（不许悄悄少给）：$text")
        assertTrue(
            text.length <= 600 + 40,
            "★ 硬闸必须真的收敛（标注行自身占位很小）：实际 ${text.length}",
        )
        assertTrue(text.contains("【工作区现状"), "头部要保住（模型先要知道'这是什么工作区'）")
    }

    // ============================================================ 4. 读不到的目录 ≠ 空目录

    @Test
    @DisplayName("★★ 读不到的目录**不许**当空目录：如实报条数")
    fun unreadableDirIsReportedNotSwallowed() = runBlocking {
        val fs = TreeFs(mapOf("a.txt" to "x", "secret/hidden.txt" to "y"), failDirs = setOf("secret"))
        val text = WorkspaceSnapshot.render(fs, emptyList(), 1)!!
        assertTrue(text.contains("a.txt"), "读得到的照常列：$text")
        assertTrue(
            text.contains("1 个目录读取失败"),
            "★ 读不到 ≠ 这里没有东西。权限问题被伪装成'空目录'，模型会据此判断文件不存在：$text",
        )
        assertFalse(text.contains("hidden.txt"), "读不到的文件不该假装看到了：$text")
    }

    // ============================================================ 5. 最近改动只认成功的写

    @Test
    @DisplayName("★★ 被拦截 / 失败的写**不许**进「最近改动」（这是最容易写成假信息的地方）")
    fun blockedWritesAreNotReportedAsDone() = runBlocking {
        val fs = TreeFs(mapOf("real.txt" to "x"))
        val records = listOf(
            record(1, "write_file", "ok.txt", succeeded = true),
            // 被拦截：请求了但没执行（toolSucceeded == null）
            record(2, "write_file", "blocked.txt", succeeded = null),
            // 执行了但失败
            record(3, "write_file", "failed.txt", succeeded = false),
            // 只读工具不算"改动"
            record(4, "read_file", "read-only.txt", succeeded = true),
        )
        val text = WorkspaceSnapshot.render(fs, records, 4)!!
        assertTrue(text.contains("ok.txt"), "成功的写要报：$text")
        assertFalse(
            text.contains("blocked.txt"),
            "★ 被拦截的写**不许**出现在'最近改动'里 —— 那会让模型以为文件已经写好、从此不再写" +
                "（与 H-1 同源：把没发生的事写成发生了）：$text",
        )
        assertFalse(text.contains("failed.txt"), "★ 失败同样不许：$text")
        assertFalse(text.contains("read-only.txt"), "读不算改动：$text")
    }

    @Test
    @DisplayName("★ 最近改动：去重、最近的排前面、条数受上限约束")
    fun recentWritesDedupeAndOrder() = runBlocking {
        val records = listOf(
            record(1, "write_file", "a.txt", true),
            record(2, "write_file", "b.txt", true),
            record(3, "write_file", "a.txt", true), // 又写了一次 a
            record(4, "apply_patch", "c.txt", true),
        )
        val text = WorkspaceSnapshot.render(TreeFs(mapOf("a.txt" to "x")), records, 4, maxRecent = 3)!!
        val line = text.lines().single { it.startsWith("【最近改动】") }
        assertEquals("【最近改动】c.txt、a.txt、b.txt", line, "最近的在前，且不重复：$line")
    }

    // ============================================================ 6. 产物 / 工程标记

    @Test
    @DisplayName("★ 产物与工程标记：只列**可枚举**的产物后缀，且明说'文件在 ≠ 构建成功'")
    fun artifactsAndProjectMarkers() = runBlocking {
        val tree = mapOf(
            "AndroidManifest.xml" to "m",
            "app/build/app-debug.apk" to "APKAPK",
            "src/Main.kt" to "fun main() {}",
        )
        val text = WorkspaceSnapshot.render(TreeFs(tree), emptyList(), 1)!!
        assertTrue(text.contains("app-debug.apk (6B)"), "产物要带字节数：$text")
        assertFalse(
            text.lines().any { it.startsWith("【产物】") && it.contains("Main.kt") },
            "★ 源码**不许**被当成产物（猜错方向比不列更糟：模型会以为拿到了构建结果）",
        )
        assertTrue(text.contains("文件存在 ≠ 构建成功"), "★ 不许让模型把'文件在'读成'构建过了'：$text")
        assertTrue(text.contains("看起来是 Android 工程"), "根有清单就该说：$text")
    }

    @Test
    @DisplayName("★ 空工作区 + 无记录 ⇒ 不注入空壳（返回 null）")
    fun emptyWorkspaceReturnsNull() = runBlocking {
        assertNull(WorkspaceSnapshot.render(TreeFs(), emptyList(), 1), "没东西可说就不要注入")
    }

    @Test
    @DisplayName("★ 三个上限来自 Contract（不许有魔法数字）")
    fun capsComeFromContract() {
        assertEquals(200, Contract.Context.MAX_SNAPSHOT_ENTRIES)
        assertEquals(4, Contract.Context.MAX_SNAPSHOT_DEPTH)
        assertEquals(4_000, Contract.Context.MAX_SNAPSHOT_CHARS)
        assertTrue(Contract.Context.MAX_SNAPSHOT_WALK >= Contract.Context.MAX_SNAPSHOT_ENTRIES)
    }

    // ============================================================ 7. 与 AgentLoop 的接线

    @Test
    @DisplayName("★★ 开关**关着**时：连 render 都不调（list 调用 0 次）⇒ 零回退是结构性的")
    fun disabledSwitchTouchesNothing() = runBlocking {
        val fs = TreeFs(mapOf("a.txt" to "x"))
        val provider = ScriptedProvider(listOf("""{"final":"ok"}"""))
        provider.load(ProviderConfig())
        AgentLoop(provider, fs, emptyList(), maxTurns = 1).run("干活")

        assertEquals(
            0, fs.listCalls,
            "★ 关着开关时**一个字节都不碰**：连目录都不读（不是'读了但不用'）—— " +
                "F8a 的零回退靠这个结构性事实，不靠'我们保证'",
        )
        assertFalse(
            provider.requests.any { r -> r.messages.orEmpty().any { it.content.contains("【工作区现状") } },
            "关着的时候 prompt 里不许出现快照",
        )
    }

    @Test
    @DisplayName("★★ 开着时：快照作为**追加的 Turn.User**进入请求，且 SYSTEM（冻结前缀）逐字节不变")
    fun enabledAppendsSnapshotWithoutTouchingFrozenPrefix() = runBlocking {
        val tree = mapOf("AndroidManifest.xml" to "m", "src/Main.kt" to "fun main() {}")

        val off = ScriptedProvider(listOf("""{"final":"ok"}"""))
        off.load(ProviderConfig())
        AgentLoop(off, TreeFs(tree), emptyList(), maxTurns = 1).run("干活")

        val on = ScriptedProvider(listOf("""{"final":"ok"}"""))
        on.load(ProviderConfig())
        AgentLoop(on, TreeFs(tree), emptyList(), maxTurns = 1, snapshotInjectionEnabled = true).run("干活")

        val sysOff = off.requests.first().messages.orEmpty().first { it.role == ChatRole.SYSTEM }.content
        val sysOn = on.requests.first().messages.orEmpty().first { it.role == ChatRole.SYSTEM }.content
        assertEquals(
            sysOff, sysOn,
            "★ 冻结前缀（SYSTEM 消息）必须**逐字节相同** —— 快照绝不进前缀。" +
                "这是我方案里那句'结构上不可能变'的机器可验证形式",
        )

        val injected = on.requests.first().messages.orEmpty().filter { it.content.contains("【工作区现状") }
        assertEquals(1, injected.size, "快照应当恰好注入一条")
        assertTrue(
            injected.single().content.contains("AndroidManifest.xml"),
            "注入的应当是**当时**的工作区现状：${injected.single().content}",
        )
        assertTrue(
            on.requests.first().messages.orEmpty().last().content.contains("【工作区现状"),
            "★ 快照必须在**最后**追加（append-only）：它天然就是历史里最新的那一份，" +
                "所以 F8b 的'变更才注入'不会让模型看不到现状",
        )
        assertTrue(
            off.requests.first().messages.orEmpty().none { it.content.contains("【工作区现状") },
            "关着的那条链路里不许有这个字符串（对照组成立）",
        )
    }
}
