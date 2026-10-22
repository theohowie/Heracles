package dev.heracles.cloud

import dev.heracles.agent.AgentEvent
import dev.heracles.cloud.context.AgentMessage
import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.context.MessageRole
import dev.heracles.cloud.prompt.CloudPrompts
import dev.heracles.cloud.tool.CloudTool
import dev.heracles.cloud.tool.CloudToolRegistry
import dev.heracles.cloud.tool.ToolOutcome
import dev.heracles.core.provider.FakeProvider
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.ProviderCapabilities
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ProviderKind
import dev.heracles.core.provider.StreamChunk
import dev.heracles.core.tool.AskOption
import dev.heracles.core.tool.AskQuestion
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **`update_plan` / `ask_user` 在新管线里的接线门禁**（2026-10-21）。
 *
 * ## 为什么必须有
 *
 * 这两个工具在第一版里被 `handleMetaTool` 的 `else` 分支接住，
 * 返回"需由装配层处理" —— **工具调了但 UI 完全没反应**。
 * 具体症状：
 * - 计划面板永远是空的（`update_plan` 返回失败，模型重试或放弃）
 * - `ask_user` 超时后用户只看到"任务卡死"
 *
 * 这类缺陷**不会报错**，只会表现为"Agent 好像变笨了"。
 */
class CloudMetaToolsTest {

    // ============================================================
    // update_plan
    // ============================================================

    @Test
    @DisplayName("★★★ update_plan 必须发 PlanUpdated 事件（旧版：工具调了但面板没反应）")
    fun updatePlanEmitsEvent() = runBlocking {
        val events = mutableListOf<CloudEvent>()
        val pipeline = pipelineOf(onEvent = { events += it })

        val steps = """[{"text":"查看项目结构","status":"done"},{"text":"写 index.html","status":"active"},{"text":"验证页面","status":"pending"}]"""
        val result = pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan", """{"steps":$steps}"""),
        )

        assertTrue(result.output.contains("计划已更新"), "应成功：${result.output}")

        val planEvent = events.filterIsInstance<CloudEvent.PlanUpdated>().firstOrNull()
        assertTrue(planEvent != null, "必须发 PlanUpdated 事件（否则计划面板不更新）")
        assertEquals(3, planEvent!!.steps.size)
        assertEquals("查看项目结构", planEvent.steps[0].text)
        assertEquals(PlanStatusView.DONE, planEvent.steps[0].status)
        assertEquals(PlanStatusView.ACTIVE, planEvent.steps[1].status)
        assertEquals(1, planEvent.doneCount)
        assertEquals(1, planEvent.activeIndex)
    }

    @Test
    @DisplayName("★★ 多个 active ⇒ 只留第一个（「现在在干什么」必须有唯一答案）")
    fun multipleActiveNormalized() = runBlocking {
        val events = mutableListOf<CloudEvent>()
        val pipeline = pipelineOf(onEvent = { events += it })

        val steps = """[{"text":"A","status":"active"},{"text":"B","status":"active"},{"text":"C","status":"pending"}]"""
        pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan", """{"steps":$steps}"""),
        )

        val ev = events.filterIsInstance<CloudEvent.PlanUpdated>().single()
        assertEquals(PlanStatusView.ACTIVE, ev.steps[0].status, "第一个 active 保留")
        assertEquals(PlanStatusView.PENDING, ev.steps[1].status, "第二个 active 降为 pending")
    }

    @Test
    @DisplayName("★★ 没有 active 但有未完成 ⇒ 第一个未完成变 active")
    fun noActiveAutoAdvances() = runBlocking {
        val events = mutableListOf<CloudEvent>()
        val pipeline = pipelineOf(onEvent = { events += it })

        val steps = """[{"text":"A","status":"done"},{"text":"B","status":"pending"}]"""
        pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan", """{"steps":$steps}"""),
        )

        val ev = events.filterIsInstance<CloudEvent.PlanUpdated>().single()
        assertEquals(PlanStatusView.ACTIVE, ev.steps[1].status)
        assertEquals(1, ev.activeIndex)
    }

    @Test
    @DisplayName("★★ 非法 steps ⇒ 失败，且**不造空计划**（编计划会让 UI 显示假进度）")
    fun invalidPlanRejected() = runBlocking {
        val events = mutableListOf<CloudEvent>()
        val pipeline = pipelineOf(onEvent = { events += it })

        val result = pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan", """{"steps":"not an array"}"""),
        )

        assertTrue(result.isError, "非法计划必须失败")
        assertTrue(events.none { it is CloudEvent.PlanUpdated }, "失败时**不该**发计划事件")
    }

    @Test
    @DisplayName("★★ 纯字符串元素也接受（宽容旧写法，视为 pending）")
    fun plainStringStepsAccepted() = runBlocking {
        val events = mutableListOf<CloudEvent>()
        val pipeline = pipelineOf(onEvent = { events += it })

        val steps = """["第一步","第二步"]"""
        pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan", """{"steps":$steps}"""),
        )

        val ev = events.filterIsInstance<CloudEvent.PlanUpdated>().single()
        assertEquals(2, ev.steps.size)
        // 没有 active ⇒ 第一个未完成自动变 active
        assertEquals(PlanStatusView.ACTIVE, ev.steps[0].status)
    }

    @Test
    @DisplayName("★★ 计划必须注入到**下一轮**请求的上下文（否则模型看不到进度）")
    fun planInjectedIntoNextTurn() = runBlocking {
        val provider = RecordingProvider(
            // 第 1 轮：调 update_plan；第 2 轮：纯文本收工
            turns = listOf(
                listOf(
                    StreamChunk.done(
                        FinishReason.TOOL_CALLS,
                        listOf(
                            dev.heracles.core.tool.NativeToolCall(
                                id = "c1",
                                tool = "update_plan",
                                argumentsJson = """{"steps":[{"text":"做A","status":"active"}]}""",
                            )
                        ),
                    )
                ),
                listOf(StreamChunk.text("做完了"), StreamChunk.done(FinishReason.STOP)),
            )
        )
        val pipeline = pipelineWithProvider(provider)

        pipeline.run("干活", listOf(AgentMessage(MessageRole.USER, "干活")))

        // 第 2 轮的请求里必须带计划
        assertTrue(provider.requests.size >= 2, "至少要两轮请求")
        val secondReq = provider.requests[1]
        val allText = secondReq.messages.orEmpty().joinToString("") { it.content }
        assertTrue(
            allText.contains("当前任务计划与进度") && allText.contains("做A"),
            "计划必须注入下一轮上下文，否则模型不知道自己在第几步。实际：$allText",
        )
    }

    // ============================================================
    // ask_user
    // ============================================================

    @Test
    @DisplayName("★★★ ask_user 必须发 AskUser 事件（旧版：工具调了但没弹窗，用户只看到卡死）")
    fun askUserEmitsEvent() = runBlocking {
        val events = mutableListOf<CloudEvent>()
        val gate = FakeAskGate(answer = "用户回答：\n问：要覆盖吗？\n答：覆盖")
        val pipeline = pipelineOf(onEvent = { events += it }, askGate = gate)

        val questions = """[{"id":"q1","question":"要覆盖吗？","multi":false,"options":[{"label":"覆盖"},{"label":"另存"}]}]"""
        val result = pipeline.runMetaToolForTest(
            CloudToolCall("c1", "ask_user", """{"questions":$questions}"""),
        )

        val askEvent = events.filterIsInstance<CloudEvent.AskUser>().firstOrNull()
        assertTrue(askEvent != null, "必须发 AskUser 事件（否则 UI 不弹窗）")
        assertEquals(1, askEvent!!.questions.size)
        assertEquals("要覆盖吗？", askEvent.questions[0].question)
        assertEquals(listOf("覆盖", "另存"), askEvent.questions[0].options.map { it.label })

        assertTrue(result.output.contains("用户回答"), "回答要喂回模型：${result.output}")
        assertTrue(gate.calls == 1, "必须真的问过一次")
    }

    @Test
    @DisplayName("★★ 无提问通道 ⇒ 如实说用户没回答，绝不编造答案")
    fun noAskGateDoesNotFabricate() = runBlocking {
        val events = mutableListOf<CloudEvent>()
        // askGate = null
        val pipeline = pipelineOf(onEvent = { events += it }, askGate = null)

        val questions = """[{"id":"q1","question":"要覆盖吗？","options":[{"label":"覆盖"}]}]"""
        val result = pipeline.runMetaToolForTest(
            CloudToolCall("c1", "ask_user", """{"questions":$questions}"""),
        )

        assertTrue(result.isError, "没有回答通道必须失败")
        assertTrue(
            result.output.contains("没有回答") || result.output.contains("超时"),
            "要如实说没回答，不能编一个答案：${result.output}",
        )
        // 事件仍然要发（UI 至少知道模型问了什么）
        assertTrue(events.any { it is CloudEvent.AskUser }, "即使没通道，也该让 UI 知道问了什么")
    }

    @Test
    @DisplayName("★★ 非法 questions ⇒ 失败并给出正确形状（不静默）")
    fun invalidQuestionsRejected() = runBlocking {
        val pipeline = pipelineOf(onEvent = {}, askGate = FakeAskGate("x"))

        val result = pipeline.runMetaToolForTest(
            CloudToolCall("c1", "ask_user", """{"questions":"not array"}"""),
        )

        assertTrue(result.isError)
        assertTrue(result.output.contains("不是合法的题目数组"), "要指明形状：${result.output}")
    }

    // ============================================================
    // 事件翻译（新 → 旧，一对多）
    // ============================================================

    @Test
    @DisplayName("★★★ PlanUpdated 必须翻成**两条**旧事件（PlanCreated + PlanAdvanced）")
    fun planUpdatedMapsToTwoLegacyEvents() {
        val ce = CloudEvent.PlanUpdated(
            turnIndex = 1,
            steps = listOf(
                PlanStepView("A", PlanStatusView.DONE),
                PlanStepView("B", PlanStatusView.ACTIVE),
            ),
            doneCount = 1,
            activeIndex = 1,
        )
        val legacy = CloudBridgeAdapters.toLegacyEvents(ce)

        assertEquals(2, legacy.size, "旧 UI 用两个事件分别画清单与进度，必须翻成两条")
        val created = legacy[0] as AgentEvent.PlanCreated
        assertEquals(listOf("A", "B"), created.steps)
        val advanced = legacy[1] as AgentEvent.PlanAdvanced
        assertEquals(1, advanced.doneCount)
        assertEquals(1, advanced.activeIndex)
    }

    @Test
    @DisplayName("★★ AskUser 翻译保留题目与 call")
    fun askUserMapsToLegacy() {
        val ce = CloudEvent.AskUser(
            turnIndex = 2,
            questions = listOf(
                AskQuestion(
                    id = "q1", question = "选哪个？", multi = false,
                    options = listOf(AskOption("A"), AskOption("B")),
                )
            ),
            call = CloudToolCall("c1", "ask_user", "{}"),
        )
        val legacy = CloudBridgeAdapters.toLegacyEvents(ce)
        assertEquals(1, legacy.size)
        val ask = legacy[0] as AgentEvent.AskUser
        assertEquals(1, ask.questions.size)
        assertEquals("选哪个？", ask.questions[0].question)
        assertEquals("ask_user", ask.call.tool)
    }

    // ============================================================
    // 脚手架
    // ============================================================

    private class FakeAskGate(private val answer: String?) : AskGate {
        var calls = 0
        override suspend fun awaitAnswers(questions: List<AskQuestion>): String? {
            calls++
            return answer
        }
    }

    private class RecordingProvider(private val turns: List<List<StreamChunk>>) : ModelProvider {
        val requests = mutableListOf<GenerateRequest>()
        private var idx = 0
        override val id = "test:recording"
        override val kind = ProviderKind.CLOUD
        override val capabilities = ProviderCapabilities(
            supportsGrammar = false,
            supportsJsonSchema = true,
            supportsPrefixCache = true,
            needsPrewarm = false,
            cacheBlockTokens = 1024,
        )

        override suspend fun load(config: ProviderConfig) = Result.success(Unit)
        override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)
        override suspend fun release() = Unit
        override fun health() = dev.heracles.core.provider.ProviderHealth(true, "ok")
        override suspend fun generate(request: GenerateRequest) =
            Result.success(dev.heracles.core.provider.GenerateResult("", dev.heracles.core.provider.CacheStats.withoutCacheReporting(0, 0), FinishReason.STOP))

        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
            requests += request
            val turn = turns.getOrElse(idx) { listOf(StreamChunk.done(FinishReason.STOP)) }
            idx++
            turn.forEach { emit(it) }
        }
    }

    private fun pipelineOf(
        onEvent: (CloudEvent) -> Unit,
        askGate: AskGate? = null,
    ): CloudAgentPipeline {
        val tool = CloudTool(
            spec = ToolSpec("dummy", "dummy"),
            run = { ToolOutcome.Success("ok") },
        )
        return CloudAgentPipeline(
            provider = FakeProvider(),
            registry = CloudToolRegistry(resident = listOf(tool)),
            modelContextWindow = 128_000,
            contextManager = dev.heracles.cloud.context.ContextManager(
                modelContextWindow = 128_000,
                summarizer = object : dev.heracles.cloud.context.ConversationSummarizer {
                    override suspend fun summarize(dropped: List<AgentMessage>) = "s"
                },
            ),
            askGate = askGate,
            onEvent = onEvent,
        )
    }

    private fun pipelineWithProvider(provider: ModelProvider): CloudAgentPipeline {
        val tool = CloudTool(spec = ToolSpec("dummy", "dummy"), run = { ToolOutcome.Success("ok") })
        return CloudAgentPipeline(
            provider = provider,
            registry = CloudToolRegistry(resident = listOf(tool)),
            modelContextWindow = 128_000,
            contextManager = dev.heracles.cloud.context.ContextManager(
                modelContextWindow = 128_000,
                summarizer = object : dev.heracles.cloud.context.ConversationSummarizer {
                    override suspend fun summarize(dropped: List<AgentMessage>) = "s"
                },
            ),
        )
    }
}