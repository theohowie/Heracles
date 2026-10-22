package dev.heracles.cloud

import dev.heracles.cloud.context.AgentMessage
import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.context.MessageRole
import dev.heracles.cloud.tool.CloudTool
import dev.heracles.cloud.tool.CloudToolRegistry
import dev.heracles.cloud.tool.ToolOutcome
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
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **计划落盘 / 恢复门禁**（2026-10-21）。
 *
 * ## 为什么这一层必须单测而不是只靠真机
 *
 * 计划落盘是"切会话不丢计划"的唯一保障。真机 UI 自动化在本机极不稳定
 * （无线 ADB 反复掉线），而这条链路的核心是**纯代码逻辑**：
 *
 * 1. `update_plan` 执行后 ⇒ 必须回调 `onPlanChanged`（含正确步骤）
 * 2. `run(initialPlan=…)` ⇒ 必须把计划**注入第一轮请求的上下文**
 *
 * 两者都是确定性的，用单测锁比反复试设备可靠得多。
 * 剩下的"AgentBridge 真的写到 `.heracles/plans/<sid>.json`"是 5 行 IO 代码 + 编译期保证。
 */
class CloudPlanPersistenceTest {

    // ============================================================
    // 1) update_plan ⇒ onPlanChanged 被调用
    // ============================================================

    @Test
    @DisplayName("★★★ update_plan 执行后必须回调 onPlanChanged（否则切会话丢计划）")
    fun updatePlanInvokesCallback() = runBlocking {
        val persisted = mutableListOf<List<PlanStepView>>()
        val pipeline = pipelineOf(onPlanChanged = { steps -> persisted += steps })

        val stepsJson = """[{"text":"查看项目","status":"done"},{"text":"写文件","status":"active"}]"""
        pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan", """{"steps":$stepsJson}"""),
        )

        assertEquals(1, persisted.size, "必须回调一次（落盘是唯一保障）")
        assertEquals(2, persisted[0].size)
        assertEquals("查看项目", persisted[0][0].text)
        assertEquals(PlanStatusView.DONE, persisted[0][0].status)
        assertEquals("写文件", persisted[0][1].text)
        assertEquals(PlanStatusView.ACTIVE, persisted[0][1].status)
    }

    @Test
    @DisplayName("★★ 连续两次 update_plan ⇒ 回调两次，每次都带**全量**步骤")
    fun everyUpdatePersistsFullSteps() = runBlocking {
        val persisted = mutableListOf<List<PlanStepView>>()
        val pipeline = pipelineOf(onPlanChanged = { steps -> persisted += steps })

        pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan",
                """{"steps":[{"text":"A","status":"active"},{"text":"B","status":"pending"}]}"""),
        )
        pipeline.runMetaToolForTest(
            CloudToolCall("c2", "update_plan",
                """{"steps":[{"text":"A","status":"done"},{"text":"B","status":"active"}]}"""),
        )

        assertEquals(2, persisted.size)
        // 第二次必须是"全量 + 新状态"（不是增量），否则落盘会丢步骤
        assertEquals(2, persisted[1].size, "第二次也必须是全量 2 步")
        assertEquals(PlanStatusView.DONE, persisted[1][0].status)
        assertEquals(PlanStatusView.ACTIVE, persisted[1][1].status)
    }

    @Test
    @DisplayName("★★ 非法 steps ⇒ **不回调**（不写一个假计划到磁盘）")
    fun invalidPlanDoesNotPersist() = runBlocking {
        val persisted = mutableListOf<List<PlanStepView>>()
        val pipeline = pipelineOf(onPlanChanged = { steps -> persisted += steps })

        val r = pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan", """{"steps":"not-an-array"}"""),
        )

        assertTrue(r.isError && persisted.isEmpty(), "非法计划绝不能落盘（否则 UI 显示假进度）")
    }

    @Test
    @DisplayName("★ 回调抛异常 ⇒ 不影响 run（计划是增强，不是硬依赖）")
    fun persistFailureDoesNotBreakRun() = runBlocking {
        val pipeline = pipelineOf(onPlanChanged = { throw java.io.IOException("disk full") })

        val r = pipeline.runMetaToolForTest(
            CloudToolCall("c1", "update_plan", """{"steps":[{"text":"A","status":"active"}]}"""),
        )

        assertTrue(!r.isError, "落盘失败不能让 update_plan 本身失败：${r.output}")
    }

    // ============================================================
    // 2) initialPlan ⇒ 注入第一轮请求
    // ============================================================

    @Test
    @DisplayName("★★★ initialPlan 必须注入第一轮请求（恢复计划 = 模型知道自己在第几步）")
    fun initialPlanInjectedIntoFirstRequest() = runBlocking {
        val provider = RecordingProvider(
            turns = listOf(
                listOf(StreamChunk.text("好的"), StreamChunk.done(FinishReason.STOP)),
            )
        )
        val pipeline = pipelineWithProvider(provider)

        val restored = listOf(
            PlanStepView("已完成的步骤", PlanStatusView.DONE),
            PlanStepView("还要做的步骤", PlanStatusView.ACTIVE),
        )
        pipeline.run(
            userRequest = "继续",
            history = listOf(AgentMessage(MessageRole.USER, "继续")),
            initialPlan = restored,
        )

        assertTrue(provider.requests.isNotEmpty(), "必须发出至少一轮请求")
        val firstReqText = provider.requests[0].messages.orEmpty().joinToString("") { it.content }
        assertTrue(
            firstReqText.contains("当前任务计划与进度") && firstReqText.contains("已完成的步骤"),
            "恢复的计划必须注入第一轮上下文，否则模型不知道进度。实际：$firstReqText",
        )
    }

    @Test
    @DisplayName("★ 没有 initialPlan ⇒ 不注入计划块（不制造空计划噪音）")
    fun noInitialPlanNoInjection() = runBlocking {
        val provider = RecordingProvider(
            turns = listOf(
                listOf(StreamChunk.text("好的"), StreamChunk.done(FinishReason.STOP)),
            )
        )
        val pipeline = pipelineWithProvider(provider)
        pipeline.run(userRequest = "你好")

        val text = provider.requests[0].messages.orEmpty().joinToString("") { it.content }
        assertTrue(
            !text.contains("当前任务计划与进度"),
            "没有计划时不该注入（空计划会让模型以为有任务未完成）：$text",
        )
    }

    @Test
    @DisplayName("★★★ 计划落盘**往返一致**：写进 TaskPlan.toJson() 再读回，步骤与状态不丢")
    fun planJsonRoundTrip() {
        val steps = listOf(
            PlanStepView("查看项目结构", PlanStatusView.DONE),
            PlanStepView("写 index.html", PlanStatusView.ACTIVE),
            PlanStepView("验证页面", PlanStatusView.PENDING),
        )

        // 写：PlanStepView → TaskPlan → JSON（与旧管线同一个落盘格式）
        val json = CloudBridgeAdapters.toTaskPlan(steps).toJson()
        assertTrue(json.startsWith("["), "落盘格式应与旧 TaskPlan 一致（JSON 数组）：$json")

        // 读：JSON → TaskPlan → PlanStepView
        val back = dev.heracles.agent.TaskPlan.fromJson(json)
            ?.let { CloudBridgeAdapters.toPlanStepViews(it) }

        assertEquals(steps, back, "往返必须完全一致（顺序 + 文本 + 状态）")
    }

    @Test
    @DisplayName("★★ 空计划往返 ⇒ 空（不造出假步骤）")
    fun emptyPlanRoundTrip() {
        val json = CloudBridgeAdapters.toTaskPlan(emptyList()).toJson()
        val back = dev.heracles.agent.TaskPlan.fromJson(json)?.let {
            CloudBridgeAdapters.toPlanStepViews(it)
        }
        assertTrue(back.isNullOrEmpty(), "空计划读回来必须还是空：$json")
    }

    @Test
    @DisplayName("★★ 落盘文件损坏 ⇒ 当作『没有计划』（不崩、不造计划）")
    fun corruptPlanTreatedAsNone() {
        val bad = "{ this is not json"
        val back = dev.heracles.agent.TaskPlan.fromJson(bad)
        assertTrue(back == null, "坏文件必须返回 null（调用方据此认为没有可恢复计划）")
    }

    // ============================================================
    // 脚手架
    // ============================================================

    private fun pipelineOf(
        onPlanChanged: (suspend (List<PlanStepView>) -> Unit)? = null,
    ): CloudAgentPipeline {
        val tool = CloudTool(ToolSpec("dummy", "d"), run = { ToolOutcome.Success("ok") })
        return CloudAgentPipeline(
            provider = FakeProviderForPlan(),
            registry = CloudToolRegistry(resident = listOf(tool)),
            modelContextWindow = 128_000,
            contextManager = dev.heracles.cloud.context.ContextManager(
                modelContextWindow = 128_000,
                summarizer = object : dev.heracles.cloud.context.ConversationSummarizer {
                    override suspend fun summarize(dropped: List<AgentMessage>) = "s"
                },
            ),
            onPlanChanged = onPlanChanged,
        )
    }

    private fun pipelineWithProvider(provider: ModelProvider): CloudAgentPipeline {
        val tool = CloudTool(ToolSpec("dummy", "d"), run = { ToolOutcome.Success("ok") })
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

    private class FakeProviderForPlan : ModelProvider {
        override val id = "test:plan"
        override val kind = ProviderKind.CLOUD
        override val capabilities = ProviderCapabilities(
            supportsGrammar = false, supportsJsonSchema = true,
            supportsPrefixCache = true, needsPrewarm = false, cacheBlockTokens = 1024,
        )
        override suspend fun load(config: ProviderConfig) = Result.success(Unit)
        override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)
        override suspend fun release() = Unit
        override fun health() = ProviderHealth(true, "ok")
        override suspend fun generate(request: GenerateRequest) = Result.success(
            GenerateResult("", CacheStats.withoutCacheReporting(0, 0), FinishReason.STOP)
        )
        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> =
            flow { emit(StreamChunk.done(FinishReason.STOP)) }
    }

    private class RecordingProvider(private val turns: List<List<StreamChunk>>) : ModelProvider {
        val requests = mutableListOf<GenerateRequest>()
        private var idx = 0
        override val id = "test:rec"
        override val kind = ProviderKind.CLOUD
        override val capabilities = ProviderCapabilities(
            supportsGrammar = false, supportsJsonSchema = true,
            supportsPrefixCache = true, needsPrewarm = false, cacheBlockTokens = 1024,
        )
        override suspend fun load(config: ProviderConfig) = Result.success(Unit)
        override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)
        override suspend fun release() = Unit
        override fun health() = ProviderHealth(true, "ok")
        override suspend fun generate(request: GenerateRequest) = Result.success(
            GenerateResult("", CacheStats.withoutCacheReporting(0, 0), FinishReason.STOP)
        )
        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
            requests += request
            val t = turns.getOrElse(idx) { listOf(StreamChunk.done(FinishReason.STOP)) }
            idx++
            t.forEach { emit(it) }
        }
    }
}
