package dev.heracles.agent

import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.FakeProvider
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ReasoningLevel
import dev.heracles.core.provider.StreamChunk
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Path

/**
 * **`AgentLoop` 流式改造的行为门禁** —— `25-流式工作步骤.md` §5.2 / §5.4。
 *
 * ## 这个文件测什么（以及为什么必须单独一个文件）
 *
 * `AgentEventEmissionTest` 守的是**轮级**语义（工具在 execute 前发通知、
 * 拦截不发 ToolFinished …）。本文件守的是**本次流式改造新增**的东西：
 *
 * | # | 不变量 | 若破坏，用户看到 |
 * |---|---|---|
 * | 1 | ★★ 流式下 `Session.append` 序列与一次性调用**完全一致**（铁律 1） | 缓存命中率塌方，且**别的测试全绿** |
 * | 2 | ★★ 思考超预算后**不再吃光预算**，仍能产出工具调用/最终答案 | **开了思考就完全不能用** |
 * | 3 | `ReasoningDelta` 真的发出来了 | 用户最想要的东西没出现 |
 * | 4 | 每个 `StepStarted` 都有配对的 `StepEnded` | UI 永远"生成中" |
 * | 5 | 流式下逐字拼接 = 完整文本 | 内容缺字/重复 |
 *
 * 第 1 与第 2 条是本任务的**核心验收项**。
 *
 * ## 为什么用自定义 provider 而不是只用 `FakeProvider`
 *
 * `FakeProvider` 的 `generateStream` 是从规则文本切出来的，
 * **无法脚本化"思考超长"这种病态情形** —— 而那恰是我们要防的。
 * 所以这里用一个可精确控制 chunk 序列的替身。
 */
class AgentStreamingTest {

    // ------------------------------------------------------------ 测试替身

    private class NoopFs : WorkspaceFs {
        override val info = WorkspaceInfo(Path.of(".").toAbsolutePath(), "test")
        override suspend fun list(relativeDir: String): List<FileEntry> = emptyList()
        override suspend fun readText(relativePath: String): String = ""
        override suspend fun writeText(relativePath: String, content: String): Long = 0
        override suspend fun exists(relativePath: String): Boolean = false
        override suspend fun mkdirs(relativeDir: String) {}
    }

    private class RecordingTool(
        override val spec: ToolSpec,
        private val outcome: ToolOutcome,
    ) : AgentTool {
        var executeCount = 0
            private set

        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            executeCount++
            return outcome
        }
    }

    private val writeSpec = ToolSpec(
        name = "write_file",
        description = "写文件",
        parameters = listOf(
            ToolParam("path", "string", "路径"),
            ToolParam("content", "string", "内容"),
        ),
    )

    /**
     * **可精确脚本化 chunk 序列**的 provider。
     *
     * 与 `FakeProvider` 的分工：`FakeProvider` 验证"规则 → 流"的一般路径，
     * 本替身验证**病态序列**（思考超长、只有思考没有正文、流中途抛错）。
     */
    private class ScriptedProvider(
        /** 每轮返回的 chunk 序列（不含 done，done 自动追加） */
        private val perTurn: List<List<StreamChunk>>,
    ) : dev.heracles.core.provider.ModelProvider {
        override val id = "scripted:test"
        override val kind = dev.heracles.core.provider.ProviderKind.LOCAL
        override val capabilities = dev.heracles.core.provider.ProviderCapabilities(
            supportsGrammar = true, supportsJsonSchema = true,
            supportsPrefixCache = true, needsPrewarm = true,
        )

        val prompts = mutableListOf<String>()
        private var turn = 0
        private var loaded = false

        override suspend fun load(config: ProviderConfig) = run { loaded = true; Result.success(Unit) }
        override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)
        override suspend fun release() { loaded = false }
        override fun health() = dev.heracles.core.provider.ProviderHealth(true, "ok")

        // 非流式路径必须与流式**产出同一份文本**，否则"一致性"测试无意义
        override suspend fun generate(request: dev.heracles.core.provider.GenerateRequest) =
            Result.success(
                dev.heracles.core.provider.GenerateResult(
                    text = chunksFor(request).filter { !it.done }
                        .joinToString("") { it.deltaText },
                    cache = dev.heracles.core.provider.CacheStats.withoutCacheReporting(3, 3),
                    finishReason = dev.heracles.core.provider.FinishReason.STOP,
                )
            )

        private fun chunksFor(request: dev.heracles.core.provider.GenerateRequest): List<StreamChunk> {
            prompts += request.prompt
            val idx = turn.coerceAtMost(perTurn.size - 1)
            if (turn < perTurn.size) turn++
            return perTurn[idx]
        }

        override fun generateStream(
            request: dev.heracles.core.provider.GenerateRequest,
        ): Flow<StreamChunk> = flow {
            chunksFor(request).forEach { emit(it) }
            emit(StreamChunk.done(dev.heracles.core.provider.FinishReason.STOP))
        }
    }

    /**
     * 可脚本化**失败**的 provider（2026-10-19 重试门禁用）。
     *
     * 只实现流式路径：前 [failuresBeforeSuccess] 次 `generateStream` 抛
     * [dev.heracles.core.provider.ProviderCallException]，之后正常吐 [successText]。
     */
    private class FlakyProvider(
        private val failuresBeforeSuccess: Int,
        private val retryable: Boolean,
        private val successText: String,
    ) : dev.heracles.core.provider.ModelProvider {
        override val id = "flaky:test"
        override val kind = dev.heracles.core.provider.ProviderKind.CLOUD
        override val capabilities = dev.heracles.core.provider.ProviderCapabilities(
            supportsGrammar = false,
            supportsJsonSchema = true,
            supportsPrefixCache = true,
            needsPrewarm = false,
        )

        var attempts = 0
            private set

        override suspend fun load(config: ProviderConfig) = Result.success(Unit)
        override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)
        override suspend fun release() = Unit
        override fun health() = dev.heracles.core.provider.ProviderHealth(true, "ok")

        override suspend fun generate(request: dev.heracles.core.provider.GenerateRequest) =
            error("本替身只测流式路径")

        override fun generateStream(
            request: dev.heracles.core.provider.GenerateRequest,
        ): Flow<StreamChunk> = flow {
            attempts++
            if (attempts <= failuresBeforeSuccess) {
                throw dev.heracles.core.provider.ProviderCallException(
                    "HTTP 429: rate limited",
                    retryable = retryable,
                )
            }
            emit(StreamChunk.text(successText))
            emit(StreamChunk.done(dev.heracles.core.provider.FinishReason.STOP))
        }
    }

    /** 把文本切成一串单字符 chunk（模拟真实逐 token） */
    private fun tokenize(text: String, reasoning: String = ""): List<StreamChunk> = buildList {
        reasoning.forEach { add(StreamChunk.reasoning(it.toString())) }
        text.forEach { add(StreamChunk.text(it.toString())) }
    }

    private fun recorder() = object {
        val events = mutableListOf<AgentEvent>()
        val handler: (AgentEvent) -> Unit = { events += it }
    }

    // ============================================ 1. ★★ 铁律 1：append 序列一致

    /**
     * **本任务的核心验收项 A**（Captain 明确要求）。
     *
     * `AgentLoop` 从 `generate()` 换成 `generateStream()` 之后，
     * `Session.append` 序列**必须一字不差**。
     *
     * ## 为什么这是最危险的一处
     *
     * 流式改造让"一轮"变成了几百次回调。任何一个在回调里
     * 多做/少做一次 `session.append`（哪怕只是"看起来更实时"），
     * 都会破坏 append-only ⇒ 前缀缓存从 90–99% 塌到不可预测
     * （`实测-01` / `实测-05`）—— 而**其它测试一个都不会红**。
     */
    @Test
    @DisplayName("★★ 铁律 1：流式下 prompt 序列与一次性调用完全一致")
    fun streamingPromptSequenceMatchesNonStreaming() {
        val callJson = """{"tool":"write_file","args":{"path":"a.txt","content":"hi"}}"""
        val finalJson = """{"final":"done"}"""

        // ★ 两条路径必须**面对完全相同的模型输出序列**，否则比的不是流式差异
        //   （首次写这个测试时踩了：FakeProvider 的规则永远返回同一句，
        //     于是第 2 轮被"重复调用拦截"，与 ScriptedProvider 不可比）。
        //
        //   这里用一个**开关**控制 FakeProvider 的返回，让它与脚本序列一致。
        var turnNo = 0
        val legacy = FakeProvider()
        legacy.onPrompt({ turnNo++ == 0 }, callJson)
        legacy.onPrompt({ true }, finalJson)
        runBlocking { legacy.load(ProviderConfig()) }.getOrThrow()

        val legacyLoop = AgentLoop(
            legacy, NoopFs(),
            listOf(RecordingTool(writeSpec, ToolOutcome.Success("已写入"))),
            maxTurns = 2,
        )
        val legacyResult = legacyLoop.run("写文件")

        // 流式：逐 token 吐同一份文本
        val streamed = ScriptedProvider(listOf(tokenize(callJson), tokenize(finalJson)))
        runBlocking { streamed.load(ProviderConfig()) }.getOrThrow()
        val streamedLoop = AgentLoop(
            streamed, NoopFs(),
            listOf(RecordingTool(writeSpec, ToolOutcome.Success("已写入"))),
            maxTurns = 2,
        )
        val streamedResult = streamedLoop.run("写文件")

        // ---- 断言 ①：每轮判定一致（= session 内容一致）----
        assertEquals(
            legacyResult.turns.map { it.verdict },
            streamedResult.turns.map { it.verdict },
            "★ 流式不得改变每轮的判定结果（= session 内容一致）",
        )
        assertEquals(
            legacyResult.stopReason, streamedResult.stopReason,
            "★ 流式不得改变停止原因",
        )
        assertEquals(
            legacyResult.finalText, streamedResult.finalText,
            "★ 流式不得改变最终回答",
        )

        // ---- 断言 ②：prompt **逐字节**一致 ----
        //   第 2 轮 prompt 包含第 1 轮全部 append 的结果，
        //   最能暴露"多 append / 少 append 一次"这类破坏铁律 1 的改动。
        assertEquals(
            legacy.requests.size, streamed.prompts.size,
            "★ provider 被调用的轮数必须相同",
        )
        assertEquals(
            legacy.requests[1].prompt, streamed.prompts[1],
            "★★ 第二轮 prompt 逐字节一致 ⇒ 第一轮 Session.append 序列一致（铁律 1）",
        )

        // ---- 断言 ③：确认流式路径真的走了（否则断言 ② 是空跑）----
        assertTrue(
            streamed.prompts[0].contains("写文件"),
            "prompt 应当含用户请求（确认比较的是真实 prompt）",
        )
    }

    @Test
    @DisplayName("★ 铁律 1：逐 token 流式与一次性调用产生同样的 TurnRecord")
    fun streamingTurnRecordsMatch() {
        val text = """{"final":"你好"}"""

        val oneShot = ScriptedProvider(listOf(listOf(StreamChunk.text(text))))
        runBlocking { oneShot.load(ProviderConfig()) }.getOrThrow()
        val a = AgentLoop(oneShot, NoopFs(), emptyList()).run("你好")

        val tokByTok = ScriptedProvider(listOf(tokenize(text)))
        runBlocking { tokByTok.load(ProviderConfig()) }.getOrThrow()
        val b = AgentLoop(tokByTok, NoopFs(), emptyList()).run("你好")

        assertEquals(a.turns.map { it.verdict }, b.turns.map { it.verdict })
        assertEquals(a.finalText, b.finalText)
        assertEquals(a.stopReason, b.stopReason)
    }

    // ============================================ 2. ★★ 思考预算（Captain 硬要求）

    /**
     * **本任务的核心验收项 B**（Captain 升级为硬要求）。
     *
     * ## 病态场景（实测复现，`25` §12.1）
     *
     * `max_tokens=512` + 开思考 ⇒ **512 个 chunk 全是 reasoning_content**，
     * 正文 0 字符，`finish_reason=length`。
     *
     * 后果不是"慢"，是**功能完全不可用**：
     * 用户正因为想看思考才去开推理等级，结果一开就永远出不了工具调用，
     * agent 永不收敛。
     *
     * ## 本测试证明什么
     *
     * 思考**远超预算**时：
     * 1. 不再无限转发思考（不会把 UI 拖住）
     * 2. **正文仍然能到达**，工具调用仍然会被解析并执行
     * 3. 整个 run 正常收敛（不是卡死）
     */
    @Test
    @DisplayName("★★ 思考超预算后仍能产出工具调用（开了思考也不能不可用）")
    fun thinkingBombStillProducesToolCall() {
        val callJson = """{"tool":"write_file","args":{"path":"a.txt","content":"hi"}}"""
        // 病态：思考极长（远超任何合理预算），正文只有一句
        val hugeThinking = "思考".repeat(500)

        val provider = ScriptedProvider(
            listOf(
                tokenize(callJson, hugeThinking),
                tokenize("""{"final":"完成"}"""),
            )
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()
        val result = AgentLoop(
            provider, NoopFs(), listOf(tool),
            maxTurns = 2,
            onEvent = rec.handler,
            reasoningLevel = ReasoningLevel.LOW,
        ).run("写文件")

        // ★ 断言：工具**真的被执行了**
        assertEquals(
            1, tool.executeCount,
            "★★ 思考吃光预算 ⇒ 正文 0 字符 ⇒ 工具永远不执行。这正是要防的'开了思考就不可用'",
        )
        assertEquals("已给出最终回答", result.stopReason, "★ run 必须正常收敛，不能卡死")
        assertEquals("完成", result.finalText)
        assertTrue(
            rec.events.any { it is AgentEvent.ToolStarted },
            "工具开始事件必须发出",
        )
    }

    @Test
    @DisplayName("★ 思考超预算后不再无限转发（不会把 UI 拖住）")
    fun reasoningForwardingIsCapped() {
        val hugeThinking = "长".repeat(2000)
        val provider = ScriptedProvider(listOf(tokenize("""{"final":"ok"}""", hugeThinking)))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        AgentLoop(
            provider, NoopFs(), emptyList(),
            maxOutputTokens = 128,
            onEvent = rec.handler,
            reasoningLevel = ReasoningLevel.LOW,
        ).run("你好")

        val forwarded = rec.events.filterIsInstance<AgentEvent.ReasoningDelta>()
            .joinToString("") { it.delta }

        val budget = ThinkingBudget.reasoningCharBudget(128)
        assertTrue(
            forwarded.length <= budget,
            "★ 转发的思考字符（${forwarded.length}）不得超过预算（$budget）—— 否则 UI 被拖住",
        )
        // 但也不能一个字都不给（那样用户开了思考却什么都看不到）
        assertTrue(forwarded.isNotEmpty(), "★ 预算内必须真的转发思考，否则'开了思考看不到思考'")
    }

    @Test
    @DisplayName("★ 思考预算不影响最终文本：正文完整到达且能解析出 final")
    fun reasoningCapDoesNotCorruptText() {
        val text = """{"final":"我是答案"}"""
        val provider = ScriptedProvider(listOf(tokenize(text, "思考".repeat(300))))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val result = AgentLoop(
            provider, NoopFs(), emptyList(),
            reasoningLevel = ReasoningLevel.LOW,
        ).run("你好")

        assertEquals(
            "我是答案", result.finalText,
            "★★ 截断的是【思考的转发】，绝不能截断正文 —— 否则答案被吃掉",
        )
        assertEquals("已给出最终回答", result.stopReason)
    }

    // ============================================ 3. 思考事件真的发出来了

    @Test
    @DisplayName("★ ReasoningDelta 真的发出（用户最想要的东西）")
    fun reasoningDeltaIsEmitted() {
        val provider = ScriptedProvider(
            listOf(tokenize("""{"final":"答案"}""", "我需要先看看文件"))
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        AgentLoop(
            provider, NoopFs(), emptyList(),
            onEvent = rec.handler,
            reasoningLevel = ReasoningLevel.LOW,
        ).run("你好")

        val reasoning = rec.events.filterIsInstance<AgentEvent.ReasoningDelta>()
        assertTrue(reasoning.isNotEmpty(), "★ 开了思考却没有 ReasoningDelta = 用户看不到思考过程")
        assertEquals(
            "我需要先看看文件",
            reasoning.joinToString("") { it.delta },
            "思考内容必须完整（未超预算时不得截断）",
        )
    }

    @Test
    @DisplayName("★ 关思考时不得伪造 ReasoningDelta（没有就是没有）")
    fun noReasoningWhenThinkingOff() {
        // 后端在 enable_thinking=false 时【0 个】reasoning_content（实测）
        val provider = ScriptedProvider(listOf(tokenize("""{"final":"答案"}""")))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        AgentLoop(
            provider, NoopFs(), emptyList(),
            onEvent = rec.handler,
            reasoningLevel = ReasoningLevel.OFF,
        ).run("你好")

        assertEquals(
            0, rec.events.count { it is AgentEvent.ReasoningDelta },
            "★ 关思考时后端不返回思考 ⇒ 不得伪造，否则等于骗用户",
        )
    }

    // ============================================ 4. 步骤成对 + 逐字拼接

    @Test
    @DisplayName("★★ 每个 StepStarted 都有配对的 StepEnded（否则 UI 永远转圈）")
    fun stepsArePaired() {
        val provider = ScriptedProvider(
            listOf(
                tokenize("""{"tool":"write_file","args":{"path":"a.txt","content":"hi"}}""", "想一下"),
                tokenize("""{"final":"完成"}"""),
            )
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        AgentLoop(
            provider, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("ok"))),
            maxTurns = 2, onEvent = rec.handler, reasoningLevel = ReasoningLevel.LOW,
        ).run("写文件")

        val started = rec.events.filterIsInstance<AgentEvent.StepStarted>()
        val ended = rec.events.filterIsInstance<AgentEvent.StepEnded>()

        assertEquals(started.map { it.stepId }, ended.map { it.stepId }, "★ 步骤必须一一配对")
        assertTrue(started.isNotEmpty(), "必须有步骤事件")
        assertTrue(
            started.map { it.stepId }.toSet().size == started.size,
            "步stepId 必须唯一（否则多轮会串卡片）",
        )
    }

    @Test
    @DisplayName("★ 逐字拼接 = StepEnded.summary 的完整文本（不丢字不重复）")
    fun streamedTextEqualsSummary() {
        val callJson = """{"tool":"write_file","args":{"path":"a.txt","content":"hi"}}"""
        val provider = ScriptedProvider(listOf(tokenize(callJson)))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        AgentLoop(
            provider, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("ok"))),
            maxTurns = 1, onEvent = rec.handler,
        ).run("写文件")

        val streamedText = rec.events.filterIsInstance<AgentEvent.StepDelta>()
            .joinToString("") { it.delta }
        val summary = rec.events.filterIsInstance<AgentEvent.StepEnded>().single().summary

        assertEquals(summary, streamedText, "★ 逐字累积必须等于最终完整文本")
        assertEquals(callJson, summary, "★ 累加结果必须等于模型原始输出（否则解析会失败）")
    }

    @Test
    @DisplayName("★ StepEnded 必须排在 ModelOutput 之前（逐字状态先结束，再做轮级处理）")
    fun stepEndedPrecedesModelOutput() {
        val provider = ScriptedProvider(listOf(tokenize("""{"final":"x"}""")))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        AgentLoop(provider, NoopFs(), emptyList(), onEvent = rec.handler).run("你好")

        val idxEnded = rec.events.indexOfFirst { it is AgentEvent.StepEnded }
        val idxModel = rec.events.indexOfFirst { it is AgentEvent.ModelOutput }

        assertTrue(idxEnded >= 0 && idxModel >= 0, "两类事件都必须在")
        assertTrue(
            idxEnded < idxModel,
            "★ StepEnded 必须在 ModelOutput 之前 —— 否则 UI 会先收到轮级结果、" +
                "再收到'步骤结束'，状态错乱",
        )
    }

    // ============================================ 5. 出错路径

    @Test
    @DisplayName("★ provider 流中途抛错：StepEnded(status=error) + Failed 都要发")
    fun streamFailureEmitsBothErrorEvents() {
        val failing = object : dev.heracles.core.provider.ModelProvider {
            override val id = "boom"
            override val kind = dev.heracles.core.provider.ProviderKind.LOCAL
            override val capabilities = dev.heracles.core.provider.ProviderCapabilities(
                supportsGrammar = false, supportsJsonSchema = false,
                supportsPrefixCache = false, needsPrewarm = false,
            )

            override suspend fun load(config: ProviderConfig) = Result.success(Unit)
            override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)
            override suspend fun release() = Unit
            override fun health() = dev.heracles.core.provider.ProviderHealth(false, "boom")
            override suspend fun generate(request: dev.heracles.core.provider.GenerateRequest):
                Result<dev.heracles.core.provider.GenerateResult> =
                Result.failure(RuntimeException("连接断开"))

            override fun generateStream(
                request: dev.heracles.core.provider.GenerateRequest,
            ): Flow<StreamChunk> = flow {
                emit(StreamChunk.text("半句"))
                throw RuntimeException("连接断开")
            }
        }
        runBlocking { failing.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        val result = AgentLoop(failing, NoopFs(), emptyList(), onEvent = rec.handler).run("你好")

        assertEquals("provider 调用失败", result.stopReason)
        assertTrue(rec.events.any { it is AgentEvent.Failed }, "★ 必须发 Failed")

        val ended = rec.events.filterIsInstance<AgentEvent.StepEnded>()
        assertEquals(1, ended.size, "出错也要收尾 —— 否则 UI 永远转圈")
        assertEquals(AgentEvent.StepEnded.STATUS_ERROR, ended[0].status)

        // ★ 出错前已收到的半句不能丢（用户至少看到已经生成的部分）
        assertEquals(
            "半句",
            rec.events.filterIsInstance<AgentEvent.StepDelta>().joinToString("") { it.delta },
            "★ 出错前的部分内容必须已经推出（不能留在缓冲里丢掉）",
        )
    }

    @Test
    @DisplayName("空响应：status=empty 且不产生假的 final")
    fun emptyResponseIsEmptyNotError() {
        val provider = ScriptedProvider(listOf(emptyList()))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        val result = AgentLoop(provider, NoopFs(), emptyList(), maxTurns = 1, onEvent = rec.handler)
            .run("你好")

        val ended = rec.events.filterIsInstance<AgentEvent.StepEnded>().single()
        assertEquals(
            AgentEvent.StepEnded.STATUS_EMPTY, ended.status,
            "★ '生成成功但内容为空'与'失败'必须可区分（用布尔会把空响应误报成失败）",
        )
        assertEquals("", result.finalText)
    }

    /**
     * ★★ F7c：**终止块不再被丢掉** —— 用"正文空 + 有原生调用"这条最容易被误判的形状取证。
     *
     * 老代码是 `if (chunk.done) return@collect`（终止块整个丢弃），于是：
     * ① `finishReason` 只能写死 STOP；② 原生调用无处可取；
     * ③ **"模型要调工具却拿不到 call"与"模型什么都没说"无法区分** ——
     * 而正文空 + 一个 tool call 恰恰是原生轨**最正常**的形状，
     * 报成 `STATUS_EMPTY`（"生成成功但内容为空"）就是给用户的假警报。
     */
    @Test
    @DisplayName("★★ F7c：正文空但终止块带原生调用 ⇒ StepEnded=OK **且调用真的被执行**")
    fun nativeCallInTerminalChunkIsNotReportedAsEmpty() {
        val call = NativeToolCall("call_1", "write_file", """{"path":"a.txt","content":"hi"}""")
        val provider = FakeProvider().apply {
            onPrompt(
                "写文件", respond = "", finishReason = FinishReason.TOOL_CALLS,
                nativeCalls = listOf(call),
            )
        }
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()
        val result = AgentLoop(
            provider, NoopFs(),
            listOf(tool),
            maxTurns = 1, onEvent = rec.handler,
        ).run("写文件")

        val ended = rec.events.filterIsInstance<AgentEvent.StepEnded>().first()
        assertEquals(
            AgentEvent.StepEnded.STATUS_OK, ended.status,
            "★ 「正文空 + 一个原生调用」是原生轨的正常形状，报成 STATUS_EMPTY 是假警报。" +
                "老代码把终止块丢掉 ⇒ 必然落到 EMPTY ⇒ 这条断言当时不可能成立。",
        )

        // ★★ 「状态变 OK」**不算接通** —— 调用必须真的被消费（2026-10-18 Lead 复核）★★
        //
        // 只断言 STATUS_OK 会**绿着掩盖断链**：老接线里 `result.toolCalls` 没人读，
        // `raw` 为空 ⇒ `parse("")` ⇒ Unparseable ⇒ 连续 2 轮熔断，
        // 用户看到的是"输出为空"，而状态位却是 OK。
        assertEquals(
            1, tool.executeCount,
            "原生调用必须真的被执行一次 —— 只校验 StepEnded 状态位属于假绿",
        )
        assertTrue(
            rec.events.any { it is AgentEvent.ToolFinished },
            "执行过就必须有 ToolFinished（否则 UI 上工具卡片永远转圈）",
        )
        assertTrue(
            result.turns.none { it.verdict.contains("输出无法解析") },
            "调用被消费了就不该出现『输出无法解析』；出现了说明 toolCalls 没被接上",
        )
    }

    // ============================================ 6. 默认行为不变

    @Test
    @DisplayName("★ 默认 reasoningLevel=AUTO：不发 ReasoningDelta（不改旧行为）")
    fun defaultLevelEmitsNoReasoning() {
        val provider = ScriptedProvider(listOf(tokenize("""{"final":"x"}""")))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        AgentLoop(provider, NoopFs(), emptyList(), onEvent = rec.handler).run("你好")

        assertEquals(
            0, rec.events.count { it is AgentEvent.ReasoningDelta },
            "默认档在本地退化为关思考 ⇒ 不应有思考事件",
        )
    }

    // ============================================ 7. ★ 合并效果（可实测）

    /**
     * **合并必须真的发生** —— 这是 S2 的核心性能要求。
     *
     * 本地 ~250 tok/s ⇒ 不合并就是每秒 250 次主线程 post ⇒ 掉帧。
     *
     * 本测试用一段**足够长**的输出证明：原始 chunk 数与实际事件数
     * 之间存在**数量级**的差距。若有人把合并去掉（或把阈值改成 1），
     * 这个测试立刻会红。
     */
    @Test
    @DisplayName("★★ 批量合并真的生效：原始 chunk 数 ≫ 实际事件数")
    fun coalescingActuallyReducesEvents() {
        // 500 个字符 ⇒ 500 个 chunk（逐字符）
        val long = """{"final":"""" + "答".repeat(480) + """"}"""
        val provider = ScriptedProvider(listOf(tokenize(long)))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val loop = AgentLoop(provider, NoopFs(), emptyList(), maxTurns = 1)
        loop.run("你好")

        val s = loop.stats
        assertTrue(
            s.rawTokenEvents >= 480,
            "前提：原始 chunk 应当有约 500 条，实际 ${s.rawTokenEvents}",
        )
        assertTrue(
            s.coalescedTokenEvents < s.rawTokenEvents,
            "★★ 合并必须真的减少条数（原始 ${s.rawTokenEvents} vs 实际 ${s.coalescedTokenEvents}）",
        )
        assertTrue(
            s.compressionRatio >= 2.0,
            "★ 压缩比应当有数量级意义，实际 ${s.compressionRatio}×",
        )
        assertEquals(
            s.rawTokenEvents - s.coalescedTokenEvents, s.savedPosts,
            "省下的条数 = 原始 - 合并后",
        )
    }

    @Test
    @DisplayName("★ 合并不得丢字：stats 与逐字拼接必须自洽")
    fun coalescingPreservesAllChars() {
        val payload = """{"final":""" + "字".repeat(200) + """"}"""
        val provider = ScriptedProvider(listOf(tokenize(payload)))
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        val loop = AgentLoop(provider, NoopFs(), emptyList(), maxTurns = 1, onEvent = rec.handler)
        loop.run("你好")

        val joined = rec.events.filterIsInstance<AgentEvent.StepDelta>()
            .joinToString("") { it.delta }

        assertEquals(payload, joined, "★ 合并可以改条数，但绝不能改内容")
        assertTrue(loop.stats.rawTokenEvents > loop.stats.coalescedTokenEvents, "确实合并了")
    }

    // ============================================ ★ 思考间隙引导（2026-10-13）

    /**
     * **用户实测 bug 的回归门禁**（2026-10-13）。
     *
     * ## 场景（用户原话）
     *
     * 第一条「你看可以做什么？」—— 简单问题，模型第 1 轮就给出
     * FinalAnswer。插话在**第 1 轮运行期间**投递。
     *
     * ## 被 bug 的行为
     *
     * 原实现：FinalAnswer 直接 `return` —— 插话队列**没机会 drain**，
     * 「你是谁开发的？」被静默丢弃（UI 也没显示发出去了）。
     *
     * ## 正确行为
     *
     * 1. 第 1 轮的回答**先落为已发生的助手消息**（session.append）；
     * 2. 循环继续 → 下一轮开始前注入插话（`Interrupted` 事件）；
     * 3. 模型在下一轮回答插话 → 运行以第 2 个 FinalAnswer 结束。
     * 两问都不丢。
     */
    @Test
    @DisplayName("★★ 轮间插话：FinalAnswer 后仍注入插话，两问都回答（静默丢弃回归）")
    fun interruptAfterFinalAnswerStillInjected() {
        val q = AgentLoop.InterruptQueue()

        // 第 1 轮：直接给最终回答（简单问题）；第 2 轮：回答插话
        val provider = ScriptedProvider(
            listOf(
                tokenize("""{"final":"可以写代码、读文件、查目录。"}"""),
                tokenize("""{"final":"我是 Heracles，由本项目的开发者构建。"}"""),
            )
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        // ★ 时序还原：插话在**第 1 轮运行期间**投递（用户发的第二条）。
        //   用 `prewarm` 挂钩模拟 —— provider.prewarm 在 run() 开头被调，
        //   但插话必须在第 1 轮 generate **之后**才投（真实时序）。
        //   所以这里用 ScriptedProvider 的 chunksFor 调用计数：
        //   第 1 次取 chunk 时（= 第 1 轮生成开始）不投，
        //   让投递发生在 FinalAnswer 之后的空窗 ——
        //   做法：直接在 onEvent 的 TurnStarted(1) 回调里投。
        val rec = recorder()
        var offered = false
        val timedHandler: (AgentEvent) -> Unit = { e ->
            // 第 1 轮的 ModelOutput 到手 = 第 1 轮"思考过程"结束 ——
            // 正是用户描述的投递时机
            if (!offered && e is AgentEvent.ModelOutput && e.index == 1) {
                q.offer("你是谁开发的？")
                offered = true
            }
            rec.handler(e)
        }

        val loop = AgentLoop(
            provider, NoopFs(), emptyList(),
            maxTurns = 4,
            onEvent = timedHandler,
            interruptQueue = q,
        )

        val result = runBlocking { loop.run("你看可以做什么？") }

        // 断言 ①：插话事件发过（index = 看到插话的那一轮 = 2）
        val interrupts = rec.events.filterIsInstance<AgentEvent.Interrupted>()
        assertEquals(1, interrupts.size, "插话事件必须发出")
        assertEquals(2, interrupts[0].index, "模型在第 2 轮看到插话")
        assertEquals("你是谁开发的？", interrupts[0].text)

        // 断言 ②：**两条回答都给了** —— 第二问没有被静默丢弃
        assertTrue(
            result.finalText.contains("Heracles"),
            "运行必须以对插话的回答结束（原 bug：第 1 问答完直接 return，" +
                "第 2 问被吞）—— 实际 finalText=${result.finalText}",
        )

        // 断言 ③：插话作为 Turn.User 进了第 2 轮的 prompt（append-only）
        val secondPrompt = provider.prompts.getOrNull(1) ?: ""
        assertTrue(
            secondPrompt.contains("你是谁开发的？"),
            "插话必须出现在第 2 轮 prompt 里 —— 模型才能'看到'它",
        )

        // 断言 ④：stopReason 如实（这轮的结束是因为回答了插话）
        assertEquals("已给出最终回答", result.stopReason)
    }

    /**
     * **没有插话时行为零变化** —— FinalAnswer 照常立即结束。
     * （防上面那条把"多跑一轮"错误地变成无条件行为。）
     */
    @Test
    @DisplayName("★ 无插话时 FinalAnswer 立即结束（零变化守卫）")
    fun noInterruptFinishesImmediately() {
        val provider = ScriptedProvider(
            listOf(tokenize("""{"final":"done"}"""))
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val loop = AgentLoop(
            provider, NoopFs(), emptyList(),
            maxTurns = 4,
            interruptQueue = AgentLoop.InterruptQueue.EMPTY,
        )
        val result = runBlocking { loop.run("hi") }

        assertEquals("done", result.finalText)
        // provider 只被调了 1 次 —— 没有多余的轮
        assertEquals(1, provider.prompts.size, "无插话时不该多跑轮次")
    }

    // ============================================ ★ 解析失败熔断（2026-10-14）

    /**
     * **真机死循环的回归门禁**（2026-10-14）。
     *
     * ## 用户实测
     *
     * 「你写一个HTML来实现2048小游戏」→ 连续 4 轮「输出无法解析」，
     * 每轮 100+ 秒（截图）。根因：本地 llama.cpp 把 `max_tokens`
     * 全烧在思考上、`content` 为空 —— 而**重试救不了系统性失败**。
     *
     * ## 这条测试防什么
     *
     * 防"模型一直输出不可解析的内容时，AgentLoop 陪它烧满 maxTurns"。
     * 连续两次同样失败必须**立刻熔断**，并给出一句能指导排查的说明。
     */
    @Test
    @DisplayName("★★ 连续解析失败 → 熔断停止（不再烧满 maxTurns）")
    fun consecutiveUnparseableTripsBreaker() {
        // 模型永远输出空内容（= 真机现象：思考吃光预算，content 为空）
        val provider = ScriptedProvider(
            List(8) { tokenize("") }
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val rec = recorder()
        val loop = AgentLoop(
            provider, NoopFs(), emptyList(),
            maxTurns = 8,
            onEvent = rec.handler,
        )
        val result = runBlocking { loop.run("写个2048") }

        // 断言 ①：**没有**跑满 8 轮 —— 熔断在 2 轮内生效
        assertTrue(
            provider.prompts.size <= AgentLoop.CONSECUTIVE_UNPARSEABLE_LIMIT,
            "连续解析失败必须尽早熔断，实际跑了 ${provider.prompts.size} 轮" +
                "（maxTurns=8）—— 真机上这是 4 轮 × 100 秒的等待",
        )

        // 断言 ②：停止原因如实说明"是熔断"，不是假装完成
        assertEquals("连续解析失败，已熔断", result.stopReason)

        // 断言 ③：给用户的说明要能指导排查（提到可能原因）
        assertTrue(
            result.finalText.contains("思考") || result.finalText.contains("max_tokens"),
            "熔断说明应指出常见原因，实际：${result.finalText}",
        )
    }

    /**
     * **首次解析失败仍应重试**（熔断不能误伤偶发失败）。
     */
    @Test
    @DisplayName("★ 单次解析失败仍重试（熔断不误伤偶发失败）")
    fun singleUnparseableStillRetries() {
        // 第 1 轮输出坏内容，第 2 轮正常给 final
        val provider = ScriptedProvider(
            listOf(
                tokenize("这不是 JSON"),
                tokenize("""{"final":"好的"}"""),
            )
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val loop = AgentLoop(provider, NoopFs(), emptyList(), maxTurns = 4)
        val result = runBlocking { loop.run("hi") }

        assertEquals("好的", result.finalText, "偶发失败后重试应当成功")
        assertEquals(2, provider.prompts.size, "应当重试了一次")
    }

    // ============================================ 8. 429/5xx 退避重试 + 取消语义

    @Test
    @DisplayName("★★ 429/5xx（retryable、且还没吐内容）⇒ 退避重试后成功")
    fun retryableFailureIsRetried() {
        val provider = FlakyProvider(
            failuresBeforeSuccess = 2,
            retryable = true,
            successText = """{"final":"好了"}""",
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val loop = AgentLoop(provider, NoopFs(), emptyList(), maxTurns = 2)
        val result = runBlocking { loop.run("hi") }

        assertEquals(3, provider.attempts, "失败 2 次 + 成功 1 次 = 3 次尝试")
        assertEquals("好了", result.finalText, "重试成功后必须正常收尾")
    }

    @Test
    @DisplayName("★★ 不可重试的 provider 错误（401 等）⇒ 不重试、如实失败")
    fun nonRetryableFailureIsNotRetried() {
        val provider = FlakyProvider(
            failuresBeforeSuccess = 1,
            retryable = false,
            successText = "不该到这里",
        )
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val loop = AgentLoop(provider, NoopFs(), emptyList(), maxTurns = 2)
        val result = runBlocking { loop.run("hi") }

        assertEquals(1, provider.attempts, "不可重试错误重试只会更糟（还可能重复计费）")
        assertEquals("provider 调用失败", result.stopReason)
    }

    @Test
    @DisplayName("★★ 用户点「停止」（CancellationException）⇒ 原样抛出，不当成 provider 错误")
    fun cancellationIsRethrown() {
        val provider = object : dev.heracles.core.provider.ModelProvider {
            override val id = "cancel:test"
            override val kind = dev.heracles.core.provider.ProviderKind.CLOUD
            override val capabilities = dev.heracles.core.provider.ProviderCapabilities(
                supportsGrammar = false,
                supportsJsonSchema = true,
                supportsPrefixCache = false,
                needsPrewarm = false,
            )

            override suspend fun load(config: ProviderConfig) = Result.success(Unit)
            override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)
            override suspend fun release() = Unit
            override fun health() = dev.heracles.core.provider.ProviderHealth(true, "ok")

            override suspend fun generate(request: dev.heracles.core.provider.GenerateRequest) =
                error("只测流式")

            override fun generateStream(
                request: dev.heracles.core.provider.GenerateRequest,
            ): Flow<StreamChunk> = flow {
                throw kotlinx.coroutines.CancellationException("用户停止")
            }
        }
        runBlocking { provider.load(ProviderConfig()) }.getOrThrow()

        val loop = AgentLoop(provider, NoopFs(), emptyList(), maxTurns = 2)
        org.junit.jupiter.api.assertThrows<kotlinx.coroutines.CancellationException> {
            runBlocking { loop.run("hi") }
        }
    }
}
