package dev.heracles.agent

import dev.heracles.core.provider.CacheStats
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.GenerateResult
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.ProviderCapabilities
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ProviderHealth
import dev.heracles.core.provider.ProviderKind
import dev.heracles.core.provider.StreamChunk
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Paths
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger

/**
 * **真并发执行的门禁**（2026-10-19）。
 *
 * ## 这组断言守什么
 *
 * 并行批次以前是**串行**跑的（语义对、慢）。现在 `AgentTool.parallelSafe` 为 true 的工具
 * 会**同时执行** —— 这带来两个必须钉死的风险：
 *
 * 1. **该并发的没并发**（性能白改）⇒ 用"峰值并发数"直接证明真的重叠了；
 * 2. **不该并发的并发了**（正确性灾难：两个 `write_file` 同时写）⇒
 *    用"默认 `parallelSafe = false` + 写工具峰值并发恒为 1"证明。
 * 3. **结果配错调用**（并发跑完顺序乱了）⇒ 用"结果按调用顺序回填"证明。
 *
 * ⚠️ 本文件**自带全套夹具**（不依赖 `NativeToolFlowTest` 里那些 private 类）——
 * 测试之间的隐式耦合会让"改一个文件炸另一个"变得莫名其妙。
 */
class ParallelExecutionTest {

    // ==================================================== 夹具

    private class NoopFs : WorkspaceFs {
        override val info = WorkspaceInfo(Paths.get("noop"), "noop")
        override suspend fun list(relativeDir: String): List<FileEntry> = emptyList()
        override suspend fun readText(relativePath: String): String = ""
        override suspend fun writeText(relativePath: String, content: String): Long = 0
        override suspend fun exists(relativePath: String): Boolean = false
        override suspend fun mkdirs(relativeDir: String) = Unit
    }

    private data class ScriptTurn(
        val text: String,
        val finish: FinishReason = FinishReason.STOP,
        val calls: List<NativeToolCall> = emptyList(),
    )

    /** 按轮次脚本化的 provider（原生轨：每轮回一批 tool_calls）。 */
    private class ScriptedProvider(private val script: List<ScriptTurn>) : ModelProvider {
        override val id = "scripted:parallel"
        override val kind = ProviderKind.CLOUD
        override val capabilities = ProviderCapabilities(
            supportsGrammar = true,
            supportsJsonSchema = true,
            supportsPrefixCache = true,
            needsPrewarm = true,
        )
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
            val t = script.getOrNull(turn) ?: error("脚本用完了（第 ${turn + 1} 轮没有脚本）")
            turn++
            return Result.success(
                GenerateResult(t.text, CacheStats.withoutCacheReporting(0, 0), t.finish, t.calls),
            )
        }

        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
            val t = script.getOrNull(turn) ?: error("脚本用完了（第 ${turn + 1} 轮没有脚本）")
            turn++
            if (t.text.isNotEmpty()) emit(StreamChunk.text(t.text))
            emit(StreamChunk.done(t.finish, t.calls))
        }

        override fun lastStreamCache(): CacheStats = CacheStats.withoutCacheReporting(0, 0)
    }

    private val readSpec = ToolSpec(
        "read_file", "读文件", listOf(ToolParam("path", "string", "路径")),
    )
    private val writeSpec = ToolSpec(
        "write_file", "写文件",
        listOf(ToolParam("path", "string", "路径"), ToolParam("content", "string", "内容")),
    )

    /** 记录**同时在跑**的最大工具数 —— 这是"真并发"最直接的证据。 */
    private class ConcurrencyProbe {
        private val current = AtomicInteger(0)
        private val peak = AtomicInteger(0)

        suspend fun <T> track(body: suspend () -> T): T {
            val now = current.incrementAndGet()
            peak.accumulateAndGet(now) { a, b -> maxOf(a, b) }
            try {
                return body()
            } finally {
                current.decrementAndGet()
            }
        }

        val maxObserved: Int get() = peak.get()
    }

    private class SlowTool(
        override val spec: ToolSpec,
        private val probe: ConcurrencyProbe,
        private val delayMs: Long,
        override val parallelSafe: Boolean,
    ) : AgentTool {
        val executeCount = AtomicInteger(0)
        override suspend fun execute(args: Map<String, String>): ToolOutcome =
            probe.track {
                executeCount.incrementAndGet()
                delay(delayMs)
                ToolOutcome.Success("ok:${args["path"]}")
            }
    }

    private suspend fun runScript(
        provider: ScriptedProvider,
        tool: AgentTool,
        request: String = "跑一下",
    ): AgentRunResult {
        provider.load(ProviderConfig()).getOrThrow()
        return AgentLoop(
            provider, NoopFs(), listOf(tool),
            maxTurns = 3, nativeToolsEnabled = true,
        ).run(request)
    }

    // ==================================================== ① 可并发：真的重叠

    @Test
    @DisplayName("★★ parallelSafe 的读调用在批次里**同时**执行（峰值并发 = 批内数量）")
    fun parallelSafeToolsRunConcurrently() {
        val probe = ConcurrencyProbe()
        val tool = SlowTool(readSpec, probe, delayMs = 200, parallelSafe = true)
        // ⚠️ 第一个原生调用由主流程**单独**执行（协议要求：它先跑，其余进批次）。
        //   所以这里发 4 个 ⇒ 第一个串行 + 其余 3 个并发 ⇒ 峰值应对应 3。
        val calls = (1..4).map { NativeToolCall("c$it", "read_file", """{"path":"f$it.txt"}""") }
        val provider = ScriptedProvider(
            listOf(
                ScriptTurn("", FinishReason.TOOL_CALLS, calls),
                ScriptTurn("读完", FinishReason.STOP),
            ),
        )

        runBlocking { runScript(provider, tool, "读四个文件") }

        assertEquals(4, tool.executeCount.get(), "四个都要执行")
        assertEquals(
            3, probe.maxObserved,
            "批内 3 个可并发调用必须同时跑（峰值 3）；" +
                "如果等于 1 就是完全串行 —— 那这个改动毫无意义",
        )
    }

    @Test
    @DisplayName("★ 并发版总耗时 < 串行总和（重叠真的发生了）")
    fun concurrentTotalIsFasterThanSum() {
        val probe = ConcurrencyProbe()
        val tool = SlowTool(readSpec, probe, delayMs = 200, parallelSafe = true)
        val calls = (1..3).map { NativeToolCall("c$it", "read_file", """{"path":"f$it.txt"}""") }
        val provider = ScriptedProvider(
            listOf(
                ScriptTurn("", FinishReason.TOOL_CALLS, calls),
                ScriptTurn("读完", FinishReason.STOP),
            ),
        )

        val started = System.nanoTime()
        runBlocking { runScript(provider, tool, "读三个文件") }
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertTrue(
            elapsedMs < 3 * 200,
            "并发应当比串行（≥600ms）快，实测 ${elapsedMs}ms —— 否则根本没并发",
        )
    }

    // ==================================================== ② 不可并发：绝不重叠

    @Test
    @DisplayName("★★ 写工具（parallelSafe 默认 false）**绝不**并发：峰值并发 = 1")
    fun unsafeToolsNeverOverlap() {
        val probe = ConcurrencyProbe()
        val tool = SlowTool(writeSpec, probe, delayMs = 150, parallelSafe = false)
        val calls = (1..3).map {
            NativeToolCall("c$it", "write_file", """{"path":"f$it.txt","content":"x"}""")
        }
        val provider = ScriptedProvider(
            listOf(
                ScriptTurn("", FinishReason.TOOL_CALLS, calls),
                ScriptTurn("写完", FinishReason.STOP),
            ),
        )

        runBlocking { runScript(provider, tool, "写三个文件") }

        assertEquals(3, tool.executeCount.get(), "三个都要执行")
        assertEquals(1, probe.maxObserved, "写操作**不许**并发（否则数据可能错乱）")
    }

    @Test
    @DisplayName("★ 并发资格默认关闭：不声明 parallelSafe 的工具一律串行")
    fun parallelSafeDefaultsToFalse() {
        val probe = ConcurrencyProbe()
        val tool = object : AgentTool {
            override val spec = readSpec
            override suspend fun execute(args: Map<String, String>): ToolOutcome =
                probe.track {
                    delay(120)
                    ToolOutcome.Success("ok")
                }
        }
        // 默认值就是"不可并发" —— 新增工具的人不必记得显式关掉
        assertEquals(false, tool.parallelSafe, "默认必须是 false（保守）")
    }

    // ==================================================== ③ 结果与顺序仍然确定

    @Test
    @DisplayName("★★ 并发跑完后，结果仍按**调用顺序**回填（配对不能错位）")
    fun resultsAreFilledInCallOrder() {
        val probe = ConcurrencyProbe()
        val tool = SlowTool(readSpec, probe, delayMs = 30, parallelSafe = true)
        val calls = listOf(
            NativeToolCall("c1", "read_file", """{"path":"first.txt"}"""),
            NativeToolCall("c2", "read_file", """{"path":"second.txt"}"""),
            NativeToolCall("c3", "read_file", """{"path":"third.txt"}"""),
        )
        val provider = ScriptedProvider(
            listOf(
                ScriptTurn("", FinishReason.TOOL_CALLS, calls),
                ScriptTurn("读完", FinishReason.STOP),
            ),
        )

        val run = runBlocking { runScript(provider, tool, "读三个文件") }

        val results = run.turns.mapNotNull { it.toolResult }.filter { it.contains("ok:") }
        assertEquals(3, results.size, "三条工具结果都要在：$results")
        assertEquals(
            listOf("ok:first.txt", "ok:second.txt", "ok:third.txt"),
            results,
            "结果必须按调用顺序回填，否则模型会把结果配错调用",
        )
    }
}
