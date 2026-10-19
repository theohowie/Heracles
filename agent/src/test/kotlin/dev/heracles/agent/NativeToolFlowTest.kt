package dev.heracles.agent

import dev.heracles.core.contract.Contract
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
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Path

/**
 * **原生工具轨的端到端门禁**（ADR-031 step 2 响应侧）—— 零真机、零网络。
 *
 * ## 这个文件守的是什么（与 `NativeToolCallParsingTest` 的分工）
 *
 * `NativeToolCallParsingTest` 在 `:provider-http` 守"wire → 中立类型"；
 * 本文件守"**中立类型 → 真的被执行、结果真的被回填**"。
 * 两者缺一不可：只有前者 ⇒ "字段在流动"但调用被丢掉（**这正是 2026-10-18
 * 复核抓到的断链**：`result.toolCalls` 没人读，正文为空 ⇒ 报"输出无法解析" ⇒ 熔断）。
 *
 * | # | 不变量 | 若破坏，用户看到 |
 * |---|---|---|
 * | 1 | ★★ 原生调用**真的被执行**（参数还必须是解析后的 `Map`） | "模型明明调了工具，什么都没发生" |
 * | 2 | ★★ 两条轨同时给东西时**原生优先**，正文不落地为最终回答 | 模型用一个 `final` 骗过框架，活没干却宣布完成 |
 * | 3 | ★★ 执行过 ⇒ 回填**原生配对**（`role=TOOL` + `toolCallId` + 真实结果） | Anthropic 400 / 模型读不到结果 |
 * | 4 | ★★ **没执行**也回填配对（合成"未执行：…"） | 会话被重放时请求里带着"没回话的 tool_calls" |
 * | 5 | ≥2 个并行调用 ⇒ **全部执行**（串行），各自配对回填 | 一次并行请求 = 任务直接失败 / 只跑一个 |
 * | 5b | 超过单轮上限（4 个）⇒ 前 4 个执行，其余配对回填"未执行" | 未回话的 `tool_calls` ⇒ 400 |
 * | 6 | 文本轨（无原生调用）⇒ 回填形状**一字节不变** | 老路径回归（铁律 1 / 缓存前缀） |
 *
 * ## 观测手段
 *
 * 替身 `ScriptedTurnProvider` **记录每一次 `GenerateRequest`** —— 这样"回填"不是靠
 * 读实现代码猜的，而是**从下一轮真实请求的消息列表里看出来的**
 * （原生轨的证据只能在这种"重放出来的请求"里，`Session` 不对外暴露）。
 */
class NativeToolFlowTest {

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
        var lastArgs: Map<String, String>? = null
            private set
        /** 每次执行的参数（并行批次要按顺序核对） */
        val calls = mutableListOf<Map<String, String>>()

        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            executeCount++
            lastArgs = args
            calls += args
            return outcome
        }
    }

    /**
     * 第一次返回 `NeedsApproval`、之后成功的工具（2026-10-19 审批门禁用）。
     *
     * 语义与真实危险工具一致：**第一次什么都没做**，只有用户允许后
     * 才真正执行（所以第二次才算"执行过"）。
     */
    private class NeedsApprovalOnceTool(override val spec: ToolSpec) : AgentTool {
        var executeCount = 0
            private set

        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            executeCount++
            return if (executeCount == 1) {
                ToolOutcome.NeedsApproval("这条命令可能会改动系统，需要你确认")
            } else {
                ToolOutcome.Success("已执行")
            }
        }
    }

    /** 一轮的脚本：正文 + 结束原因 + 本轮要回的原生调用。 */
    private data class ScriptTurn(
        val text: String,
        val finish: FinishReason = FinishReason.STOP,
        val calls: List<NativeToolCall> = emptyList(),    )

    /**
     * **按轮次**脚本化的云端替身，并记录每次请求。
     *
     * 为什么不用 `FakeProvider`：它按 **prompt 内容**匹配规则，而原生轨的 prompt
     * 每轮都在长（append-only）—— "第几轮"才是脚本真正的维度。
     * 记录请求则让"回填的形状"可以被**断言**，而不是被相信。
     */
    private class ScriptedTurnProvider(private val script: List<ScriptTurn>) : ModelProvider {
        override val id = "scripted:native"
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
            val t = script.getOrNull(turn) ?: error("脚本用完了（第 ${turn + 1} 轮没有脚本）")
            turn++
            return Result.success(
                GenerateResult(t.text, CacheStats.withoutCacheReporting(0, 0), t.finish, t.calls)
            )
        }

        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
            requests += request
            val t = script.getOrNull(turn) ?: error("脚本用完了（第 ${turn + 1} 轮没有脚本）")
            turn++
            // 逐字符吐正文（走真流式路径，而不是接口的"一次性"默认实现）
            t.text.forEach { emit(StreamChunk.text(it.toString())) }
            emit(StreamChunk.done(t.finish, t.calls))
        }

        override fun lastStreamCache(): CacheStats = CacheStats.withoutCacheReporting(0, 0)
    }

    private val writeSpec = ToolSpec(
        name = "write_file",
        description = "写文件",
        parameters = listOf(
            ToolParam("path", "string", "路径"),
            ToolParam("content", "string", "内容"),
        ),
    )

    private fun recorder() = object {
        val events = mutableListOf<AgentEvent>()
        val handler: (AgentEvent) -> Unit = { events += it }
    }

    private fun providerOf(vararg turns: ScriptTurn) = ScriptedTurnProvider(turns.toList())

    // ==================================================== 1. 调用真的被执行

    @Test
    @DisplayName("★★ 原生调用真的被执行，且参数是**解析后**的 Map（不是原文）")
    fun nativeCallIsActuallyExecutedWithParsedArgs() {
        val call = NativeToolCall("call_1", "write_file", """{"path":"a.txt","content":"hi"}""")
        val provider = providerOf(ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)))
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(provider, NoopFs(), listOf(tool), maxTurns = 1, onEvent = rec.handler).run("写文件")
        }

        assertEquals(1, tool.executeCount, "原生调用必须被执行一次")
        assertEquals(
            mapOf("path" to "a.txt", "content" to "hi"), tool.lastArgs,
            "参数必须走**同一个** parseArgs 归一化 —— provider 侧给的是一整串 arguments 原文",
        )
        assertTrue(
            rec.events.any { it is AgentEvent.ToolFinished },
            "执行过必须有 ToolFinished",
        )
    }

    // ==================================================== 2. 原生优先（D-3）

    @Test
    @DisplayName("★★ 正文同时是合法 final + 有原生调用 ⇒ 原生优先：执行工具，正文不落地为最终回答")
    fun nativeTrackWinsOverParseableFinalBody() {
        val call = NativeToolCall("call_1", "write_file", """{"path":"a.txt","content":"hi"}""")
        // 模型"两条腿走路"：正文说收工，同时又要调工具 —— 这正是要防的形状
        val provider = providerOf(
            ScriptTurn("""{"final":"我已经写好了"}""", FinishReason.TOOL_CALLS, listOf(call)),
        )
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()

        val result = runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(provider, NoopFs(), listOf(tool), maxTurns = 1, onEvent = rec.handler).run("写文件")
        }

        assertEquals(1, tool.executeCount, "★ 原生优先 ⇒ 按调用执行，不能因为正文说了 final 就收工")
        assertTrue(
            result.finalText != "我已经写好了",
            "★ 正文里的 final **不得**成为本轮结论（否则模型用一句 final 就能骗过框架）",
        )
        assertTrue(
            result.turns.any { it.verdict.contains("已按") && it.verdict.contains("原生轨") },
            "★ 两条轨都给出可执行内容时必须**明说**：正文同时可解析为 final、已按原生轨执行。" +
                "实际记录：${result.turns.map { it.verdict }}",
        )
    }

    // ==================================================== 3. 执行过 ⇒ 原生配对回填

    @Test
    @DisplayName("★★ 执行后下一轮请求里是原生配对：assistant.tool_calls + role=TOOL + tool_call_id")
    fun executedCallIsReplayedAsNativePair() {
        val call = NativeToolCall("call_1", "write_file", """{"path":"a.txt","content":"hi"}""")
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
            ScriptTurn("""{"final":"好了"}"""),
        )
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(provider, NoopFs(), listOf(tool), maxTurns = 3, onEvent = rec.handler).run("写文件")
        }

        assertTrue(provider.requests.size >= 2, "必须有第二轮请求才能观察回填（实际 ${provider.requests.size}）")
        val msgs = provider.requests[1].messages
        assertNotNull(msgs, "云端请求必须带 messages")

        val assistant = msgs!!.last { it.role == ChatRole.ASSISTANT }
        assertEquals(
            listOf("call_1"), assistant.nativeCalls.map { it.id },
            "★ assistant 轮的 tool_calls 必须随历史重放 —— 否则下一轮的 tool 消息没有配对对象",
        )

        val toolMsg = msgs.single { it.role == ChatRole.TOOL }
        assertEquals("call_1", toolMsg.toolCallId, "★ tool 结果必须带配对的 id（Anthropic 的 tool_use_id）")
        assertEquals("已写入", toolMsg.content, "回填的必须是**真实**结果，不是占位文案")
        assertEquals(false, toolMsg.isError)

        assertTrue(
            msgs.none { it.role == ChatRole.USER && it.content.contains("【工具执行结果】") },
            "原生轨不得同时回填文本形态（一次工具结果只能有一种形状）",
        )
    }

    // ==================================================== 4. 没执行 ⇒ 合成配对

    @Test
    @DisplayName("★★ 没执行的调用（校验失败）也回填配对：TOOL 消息带『未执行：校验失败』")
    fun blockedCallStillGetsPairedResult() {
        // 工具名不在白名单 ⇒ L2 校验拦下，**没有执行**
        val bad = NativeToolCall("call_bad", "definitely_not_a_tool", """{"x":"1"}""")
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(bad)),
            ScriptTurn("""{"final":"换了做法"}"""),
        )
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()

        val result = runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(provider, NoopFs(), listOf(tool), maxTurns = 3, onEvent = rec.handler).run("随便")
        }

        assertEquals(0, tool.executeCount, "校验失败 ⇒ 不许执行")
        assertTrue(result.turns.any { it.verdict.contains("校验失败") })

        val msgs = provider.requests[1].messages!!
        val toolMsg = msgs.single { it.role == ChatRole.TOOL }
        assertEquals("call_bad", toolMsg.toolCallId, "★ 没执行也必须有配对结果（否则重放时是孤立的 tool_calls）")
        assertTrue(
            toolMsg.content.startsWith("未执行："),
            "★ 合成结果必须**如实说明未执行**，不能假装成功。实际：${toolMsg.content}",
        )
        assertEquals(true, toolMsg.isError, "未执行 = 错误结果（Anthropic 的 is_error）")
        assertTrue(
            msgs.last { it.role == ChatRole.ASSISTANT }.nativeCalls.any { it.id == "call_bad" },
            "assistant 的调用也要在历史里（否则配对无意义）",
        )
    }

    // ==================================================== 5. 并行调用（v2：全部执行）

    @Test
    @DisplayName("★★ 一轮收到 2 个原生调用 ⇒ **两个都执行**并各自配对回填结果（v2）")
    fun twoParallelCallsBothExecute() {
        val a = NativeToolCall("call_a", "write_file", """{"path":"a.txt","content":"a"}""")
        val b = NativeToolCall("call_b", "write_file", """{"path":"b.txt","content":"b"}""")
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(a, b)),
            // 第二轮：原生轨下的**纯文本**回答 —— 必须被当成最终回答（不再要求 JSON）
            ScriptTurn("两个文件已处理", FinishReason.STOP),
        )
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()

        val result = runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true, onEvent = rec.handler,
            ).run("写两个文件")
        }

        assertEquals(2, tool.executeCount, "v2：并行批次里的调用**都执行**（串行执行，不整轮作废）")
        assertEquals(
            listOf(mapOf("path" to "a.txt", "content" to "a"), mapOf("path" to "b.txt", "content" to "b")),
            tool.calls,
            "两个调用的参数都要真的到达工具层",
        )
        // 配对硬前置：两个 tool_call 都必须在下一轮请求里有真实 tool 消息
        val toolMsgs = provider.requests[1].messages!!.filter { it.role == ChatRole.TOOL }
        assertEquals(
            listOf("call_a", "call_b"), toolMsgs.map { it.toolCallId },
            "两个调用都要有配对结果（provider 重放要求）",
        )
        assertEquals(listOf("已写入", "已写入"), toolMsgs.map { it.content }, "两个结果都是真实执行结果")
        assertEquals(listOf(false, false), toolMsgs.map { it.isError }, "都不该是 error")
        assertEquals(
            "两个文件已处理", result.finalText.trim(),
            "★ 原生轨下纯文本回答 = 最终回答（不再需要 {\"final\":…} 信封）",
        )
    }

    @Test
    @DisplayName("★ 超过单轮上限（4 个）⇒ 前 4 个执行，其余**配对回填『未执行』**")
    fun callsBeyondBatchLimitArePairedAsNotExecuted() {
        val calls = (1..6).map {
            NativeToolCall("c$it", "write_file", """{"path":"f$it.txt","content":"x"}""")
        }
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, calls),
            ScriptTurn("完成", FinishReason.STOP),
        )
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
            ).run("写多个文件")
        }

        assertEquals(
            Contract.Tools.MAX_NATIVE_CALLS_PER_TURN, tool.executeCount,
            "只执行上限内的调用",
        )
        val toolMsgs = provider.requests[1].messages!!.filter { it.role == ChatRole.TOOL }
        assertEquals(6, toolMsgs.size, "每个 tool_call 都必须有配对结果（含超限的）")
        assertEquals(
            2, toolMsgs.count { it.content.startsWith("未执行：") },
            "超限的两个要如实标未执行：${toolMsgs.map { it.content }}",
        )
        assertEquals(
            listOf("c1", "c2", "c3", "c4", "c5", "c6"), toolMsgs.map { it.toolCallId },
            "配对顺序必须与调用顺序一致",
        )
    }

    @Test
    @DisplayName("★★ 被拦截的调用（重复调用）也配对：下一轮请求里是『未执行：循环拦截』")
    fun interceptedRepeatCallGetsSyntheticPair() {
        val first = NativeToolCall("call_1", "write_file", """{"path":"a.txt","content":"hi"}""")
        // 第二次是**完全相同的工具名 + 参数**，但 wire id 不同 ——
        // 这同时验证了"重复检测看的是名+参数，不是 wire id"（id 不许污染执行 IR）
        val again = NativeToolCall("call_2", "write_file", """{"path":"a.txt","content":"hi"}""")
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(first)),
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(again)),
            ScriptTurn("""{"final":"好"}"""),
        )
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(provider, NoopFs(), listOf(tool), maxTurns = 4, onEvent = rec.handler).run("写文件")
        }

        assertEquals(1, tool.executeCount, "重复调用只执行第一次")
        assertTrue(provider.requests.size >= 3, "被拦截后循环继续 ⇒ 有第三轮请求可观察")
        val toolMsgs = provider.requests[2].messages!!.filter { it.role == ChatRole.TOOL }
        assertEquals(
            listOf("call_1", "call_2"), toolMsgs.map { it.toolCallId },
            "★ 两次调用都必须有配对结果：第一次是真实结果，第二次是合成的『未执行』",
        )
        assertEquals("已写入", toolMsgs[0].content)
        assertTrue(
            toolMsgs[1].content.startsWith("未执行：") && toolMsgs[1].content.contains("循环拦截"),
            "合成文案必须走统一的 NativeSkip（实际：${toolMsgs[1].content}）",
        )
        assertEquals(true, toolMsgs[1].isError)
    }

    // ==================================================== 7. 提示层：不开原生就不换文案

    @Test
    @DisplayName("★★ 开了原生 tools ⇒ 协议文案**不再教** JSON/标签方言（否则正文里的调用会被忽略）")
    fun nativeModeSwitchesToolProtocol() {
        val provider = providerOf(ScriptTurn("""{"final":"ok"}"""))
        runBlocking { provider.load(ProviderConfig()).getOrThrow() }

        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val native = AgentLoop(
            provider, NoopFs(), listOf(tool),
            maxTurns = 1, nativeToolsEnabled = true,
        )
        assertTrue(
            native.nativeToolSpecs().isNotEmpty(),
            "开了原生 tools ⇒ 请求里必须真的带 tools 数组（否则后端起不了作用）",
        )
        assertTrue(
            !native.toolProtocol.contains("{\"tool\":") &&
                !native.toolProtocol.contains("<write_file"),
            "★ 原生轨**不许**再教 `{\"tool\":…}` / `<write_file>`：两套调用语法并存 ⇒ " +
                "模型会把调用写进正文，而原生优先会**忽略**它（白跑一轮、日志无错）",
        )
        assertTrue(
            native.toolProtocol.contains("{\"final\":") && native.toolProtocol.contains("{\"plan\":"),
            "★ 收尾与计划仍走文本轨（原生轨里没有'结束'这种工具调用），这两条必须留着",
        )

        // 零回退：没开原生时，文案 = 文本轨那一份（S1b 起它是**唯一**的文本协议）
        val textTrack = AgentLoop(provider, NoopFs(), listOf(tool), maxTurns = 1)
        assertEquals(
            AgentLoop.TOOL_PROTOCOL_CLOUD, textTrack.toolProtocol,
            "★ 云端文本轨的协议文案必须一字不变",
        )
        assertTrue(textTrack.nativeToolSpecs().isEmpty(), "没开原生 ⇒ tools 数组必须为空（请求体逐字节不变）")
    }

    // ==================================================== 6. 文本轨零回归

    @Test
    @DisplayName("★ 文本轨（无原生调用）⇒ 工具结果仍是 USER 文本，形状一字节不变")
    fun textTrackToolResultShapeUnchanged() {
        val provider = providerOf(
            ScriptTurn("""{"tool":"write_file","args":{"path":"a.txt","content":"hi"}}"""),
            ScriptTurn("""{"final":"好了"}"""),
        )
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = recorder()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(provider, NoopFs(), listOf(tool), maxTurns = 3, onEvent = rec.handler).run("写文件")
        }

        assertEquals(1, tool.executeCount, "文本轨照旧执行")
        val msgs = provider.requests[1].messages!!
        assertTrue(
            msgs.none { it.role == ChatRole.TOOL },
            "★ 文本轨**不许**冒出原生形状（没有 id 的孤立 tool 消息非法，2026-10-09 实修记录）",
        )
        assertTrue(
            msgs.any { it.role == ChatRole.USER && it.content.contains("【工具执行结果】") },
            "文本轨必须保持 2026-10-09 的修法：工具结果作为 user 文本回灌",
        )
    }

    // ==================================================== 9. update_plan 工具化（2026-10-19）

    @Test
    @DisplayName("★★ 原生 update_plan ⇒ 改计划状态 + 发 PlanCreated，下一轮工作记忆里是新计划")
    fun updatePlanMutatesLoopState() {
        val planSpec = ToolSpec(
            name = "update_plan",
            description = "更新计划",
            parameters = listOf(ToolParam("steps", "string", "步骤 JSON")),
        )
        val steps = """[{"text":"看结构","status":"done"},{"text":"写页面","status":"active"},{"text":"验证","status":"pending"}]"""
        val args = com.google.gson.JsonObject().apply { addProperty("steps", steps) }.toString()
        val call = NativeToolCall("call_p", "update_plan", args)
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
            ScriptTurn("完成", FinishReason.STOP),
        )
        // 工具实例**不该被真正执行**（状态由 AgentLoop 维护）
        val placeholder = RecordingTool(planSpec, ToolOutcome.Success("不该被调用"))
        val rec = recorder()
        val persisted = mutableListOf<TaskPlan>()

        val result = runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(placeholder),
                maxTurns = 3, nativeToolsEnabled = true, onEvent = rec.handler,
                onPlanChanged = { persisted += it },
            ).run("做个页面")
        }

        assertEquals(0, placeholder.executeCount, "update_plan 由 AgentLoop 拦截，不该走工具 execute")
        assertTrue(
            rec.events.any { it is AgentEvent.PlanCreated },
            "改计划必须发 PlanCreated（UI 要立刻看到新计划）",
        )
        assertTrue(persisted.isNotEmpty(), "计划变更必须通知落盘回调（onPlanChanged）")
        assertEquals(3, persisted.last().steps.size, "落盘的必须是最新完整计划")
        // 下一轮请求里必须带着新计划（作为工作记忆 Turn.User append）
        val secondPrompt = provider.requests.getOrNull(1)?.prompt.orEmpty()
        assertTrue(secondPrompt.contains("看结构"), "下一轮必须看到新计划：$secondPrompt")
        assertTrue(secondPrompt.contains("[x] 1."), "已完成步必须带 [x]：$secondPrompt")
        assertEquals("完成", result.finalText.trim())
    }

    @Test
    @DisplayName("★★ 恢复的计划注入第一轮工作记忆（重启/切会话后模型仍知道在哪一步）")
    fun initialPlanIsInjected() {
        val plan = TaskPlan(
            listOf(
                TaskPlan.Step("恢复的第一步", TaskPlan.Status.active),
                TaskPlan.Step("第二步", TaskPlan.Status.pending),
            )
        )
        val provider = providerOf(ScriptTurn("完成", FinishReason.STOP))
        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), emptyList(),
                maxTurns = 1, nativeToolsEnabled = true, initialPlan = plan,
            ).run("继续")
        }

        val prompt = provider.requests.first().prompt
        assertTrue(prompt.contains("恢复的第一步"), "恢复的计划必须进第一轮请求：$prompt")
        assertTrue(prompt.contains("[>] 1."), "active 状态必须保留：$prompt")
    }

    @Test
    @DisplayName("★★ 工具成功**不再自动勾计划**（进度条只认 update_plan，杜绝假进度）")
    fun toolSuccessDoesNotAutoAdvancePlan() {
        val writeCall = NativeToolCall("c1", "write_file", """{"path":"a.txt","content":"hi"}""")
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(writeCall)),
            ScriptTurn("完成", FinishReason.STOP),
        )
        val plan = TaskPlan(
            listOf(
                TaskPlan.Step("写 a.txt", TaskPlan.Status.active),
                TaskPlan.Step("验证", TaskPlan.Status.pending),
            )
        )
        val advanced = mutableListOf<AgentEvent.PlanAdvanced>()
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true, initialPlan = plan,
                onEvent = { e ->
                    if (e is AgentEvent.PlanAdvanced) advanced += e
                },
            ).run("写文件")
        }

        assertEquals(1, tool.executeCount, "前提：工具真的执行了")
        assertTrue(
            advanced.isEmpty(),
            "工具成功**不能**自动推进计划（旧实现会让进度条撒谎）：$advanced",
        )
    }

    // ==================================================== 10. 危险操作审批（2026-10-19）

    private fun approvalSpec() = ToolSpec(
        name = "run_shell_command",
        description = "跑命令",
        parameters = listOf(ToolParam("command", "string", "命令")),
    )

    private fun approvalCall() = NativeToolCall(
        "c_shell", "run_shell_command", """{"command":"rm -rf /sdcard/tmp"}""",
    )

    @Test
    @DisplayName("★★ 需要确认 ⇒ 用户允许后**重新执行**，模型拿到真实结果")
    fun approvalAllowReExecutesTool() {
        val tool = NeedsApprovalOnceTool(approvalSpec())
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(approvalCall())),
            ScriptTurn("完成", FinishReason.STOP),
        )
        val queue = AgentLoop.ApprovalQueue()
        val events = mutableListOf<AgentEvent>()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            val responder = launch {
                delay(200)
                queue.reply(AgentLoop.ApprovalDecision.ALLOW_ONCE)
            }
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalReplies = queue,
                onEvent = { events += it },
            ).run("跑个命令")
            responder.join()
        }

        assertEquals(2, tool.executeCount, "第一次 NeedsApproval、允许后第二次才真正执行")
        assertTrue(
            events.any { it is AgentEvent.ApprovalRequest },
            "必须发 ApprovalRequest（UI 才有弹窗）",
        )
        val toolMsg = provider.requests[1].messages!!.single { it.role == ChatRole.TOOL }
        assertEquals("已执行", toolMsg.content, "模型必须拿到**真实执行结果**")
        assertEquals(false, toolMsg.isError)
    }

    @Test
    @DisplayName("★★ 需要确认 ⇒ 用户拒绝：工具**不再执行**，模型收到显式失败")
    fun approvalDenyBlocksTool() {
        val tool = NeedsApprovalOnceTool(approvalSpec())
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(approvalCall())),
            ScriptTurn("好的", FinishReason.STOP),
        )
        val queue = AgentLoop.ApprovalQueue()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            val responder = launch {
                delay(200)
                queue.reply(AgentLoop.ApprovalDecision.DENY)
            }
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalReplies = queue,
            ).run("跑个命令")
            responder.join()
        }

        assertEquals(1, tool.executeCount, "拒绝后**绝不能**重新执行")
        val toolMsg = provider.requests[1].messages!!.single { it.role == ChatRole.TOOL }
        assertTrue(
            toolMsg.content.contains("用户拒绝"),
            "必须如实告诉模型被拒绝：${toolMsg.content}",
        )
        assertEquals(true, toolMsg.isError)
    }

    @Test
    @DisplayName("★★ 没有 UI（CLI/测试）⇒ 立即按拒绝处理（不挂 10 分钟、绝不放行）")
    fun approvalWithoutUiDeniesImmediately() {
        val tool = NeedsApprovalOnceTool(approvalSpec())
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(approvalCall())),
            ScriptTurn("好的", FinishReason.STOP),
        )

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                // 不传 approvalReplies ⇒ EMPTY ⇒ 立刻 null
            ).run("跑个命令")
        }

        assertEquals(1, tool.executeCount)
        val toolMsg = provider.requests[1].messages!!.single { it.role == ChatRole.TOOL }
        assertTrue(
            toolMsg.content.contains("等待用户确认超时"),
            "无人值守必须明确说没执行：${toolMsg.content}",
        )
    }

    // ==================================================== 11. 审批档位（2026-10-19）

    @Test
    @DisplayName("★★ 手动审批档：写文件**执行前**先问；拒绝 ⇒ 一次都不执行")
    fun manualModeDenyBlocksExecution() {
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val call = NativeToolCall("c_w", "write_file", """{"path":"a.txt","content":"x"}""")
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
            ScriptTurn("好", FinishReason.STOP),
        )
        val queue = AgentLoop.ApprovalQueue()
        val events = mutableListOf<AgentEvent>()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            val responder = launch {
                delay(200)
                queue.reply(AgentLoop.ApprovalDecision.DENY)
            }
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalReplies = queue,
                approvalMode = ApprovalMode.MANUAL,
                onEvent = { events += it },
            ).run("写文件")
            responder.join()
        }

        assertEquals(0, tool.executeCount, "拒绝后**一次都不能执行**")
        assertTrue(
            events.any { it is AgentEvent.ApprovalRequest },
            "手动档必须在执行前发审批请求",
        )
        val toolMsg = provider.requests[1].messages!!.single { it.role == ChatRole.TOOL }
        assertTrue(
            toolMsg.content.contains("用户未批准"),
            "必须如实告诉模型被拒绝：${toolMsg.content}",
        )
    }

    @Test
    @DisplayName("★★ 手动审批档：允许 ⇒ 正常执行一次")
    fun manualModeAllowExecutes() {
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val call = NativeToolCall("c_w", "write_file", """{"path":"b.txt","content":"y"}""")
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
            ScriptTurn("好", FinishReason.STOP),
        )
        val queue = AgentLoop.ApprovalQueue()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            val responder = launch {
                delay(200)
                queue.reply(AgentLoop.ApprovalDecision.ALLOW_ONCE)
            }
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalReplies = queue,
                approvalMode = ApprovalMode.MANUAL,
            ).run("写文件")
            responder.join()
        }

        assertEquals(1, tool.executeCount)
        val toolMsg = provider.requests[1].messages!!.single { it.role == ChatRole.TOOL }
        assertEquals("已写入", toolMsg.content)
    }

    @Test
    @DisplayName("★★ 完全访问档：NeedsApproval **自动放行**（不再弹窗/不再挂起）")
    fun fullAccessAutoApprovesNeedsApproval() {
        val tool = NeedsApprovalOnceTool(approvalSpec())
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(approvalCall())),
            ScriptTurn("好", FinishReason.STOP),
        )
        val events = mutableListOf<AgentEvent>()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalMode = ApprovalMode.FULL_ACCESS,
                onEvent = { events += it },
            ).run("跑个命令")
        }

        assertEquals(2, tool.executeCount, "完全访问档：NeedsApproval 后**直接重新执行**")
        assertTrue(
            events.none { it is AgentEvent.ApprovalRequest },
            "完全访问档不该弹审批：$events",
        )
        val toolMsg = provider.requests[1].messages!!.single { it.role == ChatRole.TOOL }
        assertEquals("已执行", toolMsg.content, "模型必须拿到真实执行结果")
    }

    @Test
    @DisplayName("★★ 「本会话始终允许」⇒ 同一工具后续调用**不再弹窗**（仅本 run）")
    fun allowAlwaysSkipsLaterApprovalsForSameTool() {
        val callA = NativeToolCall("c_a", "write_file", """{"path":"a.txt","content":"a"}""")
        val callB = NativeToolCall("c_b", "write_file", """{"path":"b.txt","content":"b"}""")
        val provider = providerOf(
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(callA)),
            ScriptTurn("", FinishReason.TOOL_CALLS, listOf(callB)),
            ScriptTurn("完成", FinishReason.STOP),
        )
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        // 短超时：若实现出错（第二次又弹窗），测试快速失败而不是挂 10 分钟
        val queue = AgentLoop.ApprovalQueue(kotlin.time.Duration.parse("400ms"))
        val approvals = mutableListOf<AgentEvent.ApprovalRequest>()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            val responder = launch {
                delay(150)
                queue.reply(AgentLoop.ApprovalDecision.ALLOW_ALWAYS)
            }
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 4, nativeToolsEnabled = true,
                approvalMode = ApprovalMode.MANUAL,
                approvalReplies = queue,
                onEvent = { e -> if (e is AgentEvent.ApprovalRequest) approvals += e },
            ).run("写两个文件")
            responder.join()
        }

        assertEquals(2, tool.executeCount, "两个写操作都应执行")
        assertEquals(1, approvals.size, "「始终允许」后第二次不该再问：$approvals")
        assertTrue(
            approvals.single().reason.contains("手动审批"),
            "第一次的审批理由应来自手动档位：${approvals.single().reason}",
        )
    }

    // ==================================================== 12. 多模态 / view_image（2026-10-19）

    @Test
    @DisplayName("★★ view_image ⇒ 图片随**下一次**请求发出（模型能持续「看到」）")
    fun viewImageAttachesToNextRequest() {
        val imageTool = object : AgentTool {
            override val spec = ToolSpec(
                "view_image", "看图",
                listOf(ToolParam("path", "string", "路径")),
            )

            override suspend fun execute(args: Map<String, String>): ToolOutcome =
                ToolOutcome.SuccessWithImage("已读取图片 a.png", "data:image/png;base64,AAAA")
        }
        val provider = providerOf(
            ScriptTurn(
                "", FinishReason.TOOL_CALLS,
                listOf(NativeToolCall("c_v", "view_image", """{"path":"a.png"}""")),
            ),
            ScriptTurn("图里是一个登录页", FinishReason.STOP),
        )

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(imageTool),
                maxTurns = 3, nativeToolsEnabled = true,
            ).run("看看这张图")
        }

        assertEquals(
            emptyList<String>(), provider.requests[0].images,
            "第一轮还没读图，不该带图片",
        )
        assertEquals(
            listOf("data:image/png;base64,AAAA"), provider.requests[1].images,
            "读图之后每一轮都必须带上图片（否则模型下一轮就「忘了」）",
        )
    }

    // ==================================================== 13. isSuccess 记账（2026-10-19 真机 bug）

    /**
     * **`SuccessWithImage` 也必须记成成功** —— 真机 bug 的回归门禁。
     *
     * 为什么这一条必须存在、光有 `ToolOutcomeContractTest` 不够：
     * 那个文件守的是"判据本身"和"源码里不再出现 `is Success`"；
     * 这条守的是**判据真的被用在了落盘字段上** ——
     * `ToolFinished.ok` / `verdict` / `toolSucceeded` / 配对回填的 `isError`。
     * 只把 `isSuccess` 定义对、却把它漏用在某一处，源码扫描是看不出来的。
     *
     * 判据取自 [TurnRecord] 的**结构化字段**（`toolSucceeded` / `toolState`），
     * 而不是 UI 或 CLI 的渲染文本 —— 后者是下游，前者的错它们一概继承。
     */
    @Test
    @DisplayName("★★ SuccessWithImage ⇒ toolSucceeded=true、verdict 是「工具成功」（真机红卡 bug）")
    fun successWithImageRecordsAsSucceeded() {
        val imageTool = RecordingTool(
            ToolSpec("view_image", "看图", listOf(ToolParam("path", "string", "路径"))),
            ToolOutcome.SuccessWithImage("已读取图片 a.png", "data:image/png;base64,AAAA"),
        )
        val provider = providerOf(
            ScriptTurn(
                "", FinishReason.TOOL_CALLS,
                listOf(NativeToolCall("c_v", "view_image", """{"path":"a.png"}""")),
            ),
            ScriptTurn("图里是登录页", FinishReason.STOP),
        )
        val rec = recorder()

        val run = runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(imageTool),
                maxTurns = 3, nativeToolsEnabled = true,
                onEvent = rec.handler,
            ).run("看看这张图")
        }

        val turn = run.turns.single { it.toolCall?.tool == "view_image" }
        assertEquals(
            true, turn.toolSucceeded,
            "SuccessWithImage 不是 Success 的子类型 —— 这里曾经是 false（真机 ok:false 的来源）",
        )
        assertEquals(ToolState.succeeded, turn.toolState, "UI 的三态来源必须是 succeeded")
        assertTrue(turn.verdict.contains("工具成功"), "verdict 应是「工具成功」：${turn.verdict}")
        assertTrue(turn.verdict.isNotBlank() && !turn.verdict.contains("工具失败"), "verdict：${turn.verdict}")

        val finished = rec.events.filterIsInstance<AgentEvent.ToolFinished>().single()
        assertTrue(finished.ok, "ToolFinished.ok 决定 UI 画绿卡还是红卡：$finished")
        // 配对回填给 provider 的 tool_result 也不该被标成 error（模型会读成"失败了"）
        val toolMsg = provider.requests[1].messages!!
            .single { it.role == ChatRole.TOOL && it.toolCallId == "c_v" }
        assertEquals(false, toolMsg.isError, "native tool_result 的 isError 必须为 false")
    }

    @Test
    @DisplayName("★ 并行批次里第二个调用是 SuccessWithImage 也记成功")
    fun successWithImageInExtraBatchRecordsAsSucceeded() {
        val write = RecordingTool(
            writeSpec, ToolOutcome.Success("已写入"),
        )
        val image = RecordingTool(
            ToolSpec("view_image", "看图", listOf(ToolParam("path", "string", "路径"))),
            ToolOutcome.SuccessWithImage("已读取图片 a.png", "data:image/png;base64,AAAA"),
        )
        val provider = providerOf(
            ScriptTurn(
                "", FinishReason.TOOL_CALLS,
                listOf(
                    NativeToolCall("c_1", "write_file", """{"path":"a.txt","content":"hi"}"""),
                    NativeToolCall("c_2", "view_image", """{"path":"a.png"}"""),
                ),
            ),
            ScriptTurn("写好了，图里是登录页", FinishReason.STOP),
        )

        val run = runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(write, image),
                maxTurns = 3, nativeToolsEnabled = true,
            ).run("写个文件再看看图")
        }

        // 第二个调用走的是**并行批次**那条记录路径（与第一个是两段独立代码）
        val rec = run.turns.single { it.toolCall?.tool == "view_image" }
        assertEquals(true, rec.toolSucceeded, "并行批次同样必须按 isSuccess 判：$rec")
        assertTrue(!rec.verdict.contains("工具失败"), "verdict：${rec.verdict}")
        val toolMsg = provider.requests[1].messages!!
            .single { it.role == ChatRole.TOOL && it.toolCallId == "c_2" }
        assertEquals(false, toolMsg.isError, "配对回填的 isError 必须为 false")
    }

    @Test
    @DisplayName("★ 反证：Failure 仍记失败（别把判据放宽成「一律成功」）")
    fun failureStillRecordsAsFailed() {
        val imageTool = RecordingTool(
            ToolSpec("view_image", "看图", listOf(ToolParam("path", "string", "路径"))),
            ToolOutcome.Failure("文件不存在：missing.png"),
        )
        val provider = providerOf(
            ScriptTurn(
                "", FinishReason.TOOL_CALLS,
                listOf(NativeToolCall("c_f", "view_image", """{"path":"missing.png"}""")),
            ),
            ScriptTurn("读不到图", FinishReason.STOP),
        )

        val run = runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(imageTool),
                maxTurns = 3, nativeToolsEnabled = true,
            ).run("看看这张图")
        }

        val turn = run.turns.single { it.toolCall?.tool == "view_image" }
        assertEquals(false, turn.toolSucceeded, "Failure 必须记 false：$turn")
        assertEquals(ToolState.failed, turn.toolState)
        assertTrue(turn.verdict.contains("工具失败"), "verdict 应含「工具失败」：${turn.verdict}")
    }
}
