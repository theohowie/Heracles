package dev.heracles.cloud

import dev.heracles.agent.AgentEvent
import dev.heracles.agent.ApprovalMode
import dev.heracles.cloud.context.AgentMessage
import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.context.MessageRole
import dev.heracles.cloud.tool.CloudTool
import dev.heracles.cloud.tool.CloudToolRegistry
import dev.heracles.cloud.tool.ToolOutcome
import dev.heracles.cloud.tool.ToolRunStatus
import dev.heracles.core.provider.FakeProvider
import dev.heracles.core.tool.ToolCall
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **接线层门禁** —— `CloudBridgeAdapters`（2026-10-21）。
 *
 * ## 为什么这层必须有测试
 *
 * 适配层是**两个系统之间的缝**。缝的特征是：两边各自都测过，缝本身没测。
 * 而这里的缝有两处会**静默出错**：
 *
 * 1. **审批事件翻译错** ⇒ UI 不弹窗 ⇒ 用户永远无法批准合法操作（安全副作用）
 * 2. **事件翻译丢字段** ⇒ UI 显示错乱（用户以为 Agent 没干活）
 *
 * ⇒ 逐条钉住映射关系。
 */
class CloudBridgeAdaptersTest {

    // ============================================================
    // 审批门禁适配
    // ============================================================

    @Test
    @DisplayName("★★★ FULL_ACCESS 档**绝不发审批事件**（BUG-1 的核心）")
    fun fullAccessNeverEmitsApprovalEvent() = runBlocking {
        val events = mutableListOf<AgentEvent>()
        val queue = dev.heracles.agent.AgentLoop.ApprovalQueue()
        val gate = CloudBridgeAdapters.approvalGate(
            mode = ApprovalMode.FULL_ACCESS,
            queue = queue,
            emitEvent = { events += it },
        )

        val allowed = gate.requestApproval("write_file", mapOf("path" to "a.txt"), "会改文件")

        assertTrue(allowed, "完全访问档必须放行")
        assertTrue(events.isEmpty(), "完全访问档**绝不能**发审批事件（否则 UI 会弹窗 = BUG-1 复发）")
    }

    @Test
    @DisplayName("★★ MANUAL 档必须发审批事件（否则用户永远不被问）")
    fun manualModeEmitsApprovalEvent() = runBlocking {
        val events = mutableListOf<AgentEvent>()
        val queue = dev.heracles.agent.AgentLoop.ApprovalQueue()
        val gate = CloudBridgeAdapters.approvalGate(
            mode = ApprovalMode.MANUAL,
            queue = queue,
            emitEvent = { events += it },
        )

        // 模拟 UI 立刻点「拒绝」（否则这个 await 会挂 10 分钟）
        launch {
            kotlinx.coroutines.delay(50)
            queue.reply(dev.heracles.agent.AgentLoop.ApprovalDecision.DENY)
        }

        val allowed = gate.requestApproval("run_shell_command", mapOf("command" to "rm -rf tmp"), "危险")

        assertTrue(events.isNotEmpty(), "手动档必须发审批事件")
        val req = events.first() as AgentEvent.ApprovalRequest
        assertEquals("run_shell_command", req.call.tool, "工具名必须透传")
        assertEquals("rm -rf tmp", req.call.args["command"], "参数必须透传（UI 要看清才能签字）")
        assertEquals("危险", req.reason, "理由必须透传")
        assertTrue(!allowed, "用户拒绝 ⇒ false")
    }

    @Test
    @DisplayName("★★★ 超时必须按**拒绝**处理（绝不在没人看时放行）")
    fun timeoutIsDenied() = runBlocking {
        val events = mutableListOf<AgentEvent>()
        // 超时设 1ms，且没人 reply
        val queue = dev.heracles.agent.AgentLoop.ApprovalQueue(
            timeout = kotlin.time.Duration.parse("1ms"),
        )
        val gate = CloudBridgeAdapters.approvalGate(
            mode = ApprovalMode.MANUAL,
            queue = queue,
            emitEvent = { events += it },
        )

        val allowed = gate.requestApproval("write_file", emptyMap(), "会改文件")

        assertTrue(!allowed, "超时绝不能当允许 —— 那是『没人看的时候自动放行』")
    }

    @Test
    @DisplayName("★ ALLOW_ALWAYS ⇒ true（本会话始终允许）")
    fun allowAlwaysIsAllowed() = runBlocking {
        val queue = dev.heracles.agent.AgentLoop.ApprovalQueue()
        val gate = CloudBridgeAdapters.approvalGate(
            mode = ApprovalMode.MANUAL,
            queue = queue,
            emitEvent = {},
        )
        launch {
            kotlinx.coroutines.delay(50)
            queue.reply(dev.heracles.agent.AgentLoop.ApprovalDecision.ALLOW_ALWAYS)
        }
        assertTrue(gate.requestApproval("write_file", emptyMap(), "会改文件"))
    }

    // ============================================================
    // 事件翻译
    // ============================================================

    @Test
    @DisplayName("★★ TurnStarted / Failed / Finished 一一对应（不丢不编）")
    fun simpleEventsMapOneToOne() {
        val started = CloudBridgeAdapters.toLegacyEvent(CloudEvent.TurnStarted(3))
        assertTrue(started is AgentEvent.TurnStarted)
        assertEquals(3, (started as AgentEvent.TurnStarted).index)

        val failed = CloudBridgeAdapters.toLegacyEvent(CloudEvent.Failed("网络断了"))
        assertTrue(failed is AgentEvent.Failed)
        assertEquals("网络断了", (failed as AgentEvent.Failed).message)

        val finished = CloudBridgeAdapters.toLegacyEvent(CloudEvent.Finished("做完了", "完成", 5))
        assertTrue(finished is AgentEvent.Finished)
        val f = finished as AgentEvent.Finished
        assertEquals("做完了", f.finalText)
        assertEquals("完成", f.stopReason)
        assertEquals(5, f.turnCount)
    }

    @Test
    @DisplayName("★★ 工具**失败/未执行**必须翻译成 Blocked（UI 画拦截卡，不是成功卡）")
    fun failedToolMapsToBlocked() {
        val invalid = CloudBridgeAdapters.toLegacyEvent(
            CloudEvent.ToolFinished(1, "edit", ToolRunStatus.SCHEMA_INVALID, isError = true)
        )
        assertTrue(invalid is AgentEvent.Blocked, "参数非法必须显示为拦截，不能是成功")
        assertTrue((invalid as AgentEvent.Blocked).reason.contains("Schema"))

        val notExecuted = CloudBridgeAdapters.toLegacyEvent(
            CloudEvent.ToolFinished(1, "write_file", ToolRunStatus.NOT_EXECUTED, isError = true)
        )
        assertTrue(notExecuted is AgentEvent.Blocked)
        assertTrue((notExecuted as AgentEvent.Blocked).reason.contains("未执行"))
    }

    @Test
    @DisplayName("★ 工具**成功**翻译成 ToolFinished 且 ok=true")
    fun okToolMapsToToolFinished() {
        val ev = CloudBridgeAdapters.toLegacyEvent(
            CloudEvent.ToolFinished(2, "read_file", ToolRunStatus.OK, isError = false)
        )
        assertTrue(ev is AgentEvent.ToolFinished)
        val tf = ev as AgentEvent.ToolFinished
        assertTrue(tf.ok)
        assertEquals("read_file", tf.call.tool)
    }

    @Test
    @DisplayName("★ Warning 用 Blocked 承载（旧事件类型里没有警告这个类型，不新造）")
    fun warningMapsToBlocked() {
        val ev = CloudBridgeAdapters.toLegacyEvent(CloudEvent.Warning("上下文摘要失败"))
        assertTrue(ev is AgentEvent.Blocked)
        assertTrue((ev as AgentEvent.Blocked).reason.contains("摘要失败"))
    }

    // ============================================================
    // 历史转换
    // ============================================================

    @Test
    @DisplayName("★★ 历史转换保持 user→assistant 顺序（否则模型因果理解错乱）")
    fun historyOrderPreserved() {
        val history = listOf(
            "第一个问题" to "第一个回答",
            "第二个问题" to "第二个回答",
        )
        val msgs = CloudBridgeAdapters.toAgentMessages(history)

        assertEquals(4, msgs.size)
        assertEquals(MessageRole.USER, msgs[0].role)
        assertEquals("第一个问题", msgs[0].text)
        assertEquals(MessageRole.ASSISTANT, msgs[1].role)
        assertEquals("第一个回答", msgs[1].text)
        assertEquals(MessageRole.USER, msgs[2].role)
        assertEquals("第二个问题", msgs[2].text)
        assertEquals(MessageRole.ASSISTANT, msgs[3].role)
    }

    @Test
    @DisplayName("★ 空回答不产生空 assistant 消息（不制造噪音）")
    fun blankAssistantSkipped() {
        val msgs = CloudBridgeAdapters.toAgentMessages(listOf("问题" to ""))
        assertEquals(1, msgs.size, "空回答不该产生 assistant 消息")
        assertEquals(MessageRole.USER, msgs[0].role)
    }

    @Test
    @DisplayName("★ 空历史 ⇒ 空列表（首次对话）")
    fun emptyHistory() {
        assertTrue(CloudBridgeAdapters.toAgentMessages(emptyList()).isEmpty())
    }

    // ============================================================
    // 分流开关
    // ============================================================

    @Test
    @DisplayName("★★★ 默认走**新管线**（2026-10-21 翻转；旧管线转为 fallback）")
    fun pipelineEnabledByDefault() {
        val saved = CloudPipelineFlags.override
        try {
            CloudPipelineFlags.override = null
            // 不设环境变量时（测试进程通常没设）⇒ 新管线
            if (System.getenv(CloudPipelineFlags.ENV_VAR) == null) {
                assertTrue(
                    CloudPipelineFlags.isCloudPipeline(),
                    "默认必须是新管线 —— 它已通过真 Key 真机验证，旧管线降级为 fallback",
                )
            }
        } finally {
            CloudPipelineFlags.override = saved
        }
    }

    @Test
    @DisplayName("★★★ 显式 override=false ⇒ 退回旧管线（fallback 仍然可用）")
    fun legacyCanBeForced() {
        val saved = CloudPipelineFlags.override
        try {
            CloudPipelineFlags.override = false
            assertFalse(CloudPipelineFlags.isCloudPipeline(), "必须能显式退回旧管线（它是唯一回退路径）")
        } finally {
            CloudPipelineFlags.override = saved
        }
    }

    @Test
    @DisplayName("★ override = true 时明确启用（测试/调试入口）")
    fun overrideEnables() {
        val saved = CloudPipelineFlags.override
        try {
            CloudPipelineFlags.override = true
            assertTrue(CloudPipelineFlags.isCloudPipeline())
        } finally {
            CloudPipelineFlags.override = saved
        }
    }

    // ============================================================
    // 未验证 wire 的轨必须自动退回旧管线（2026-10-21 自查）
    // ============================================================

    @Test
    @DisplayName("★★★ Anthropic / Responses 两轨必须【自动退回旧管线】（wire 未真 Key 验证）")
    fun unverifiedBackendsFallBackToLegacy() {
        val saved = CloudPipelineFlags.override
        try {
            CloudPipelineFlags.override = true // 就算总开关强行打开
            assertFalse(
                CloudPipelineFlags.isCloudPipelineForBackend("anthropic"),
                "Anthropic 轨的 tools 形状从未真 Key 验证 ⇒ 不得走新管线",
            )
            assertFalse(
                CloudPipelineFlags.isCloudPipelineForBackend("responses"),
                "Responses 轨同理",
            )
        } finally {
            CloudPipelineFlags.override = saved
        }
    }

    @Test
    @DisplayName("★★★ OpenAI 兼容轨走新管线（唯一真机验证过的那条）")
    fun verifiedBackendUsesNewPipeline() {
        val saved = CloudPipelineFlags.override
        try {
            CloudPipelineFlags.override = true
            assertTrue(
                CloudPipelineFlags.isCloudPipelineForBackend("cloud"),
                "OpenAI 兼容是唯一真 Key 验过的轨 ⇒ 走新管线",
            )
        } finally {
            CloudPipelineFlags.override = saved
        }
    }

    @Test
    @DisplayName("★★ 总开关关掉时任何 backend 都退回旧管线（两道闸是 AND）")
    fun masterSwitchOffBeatsBackend() {
        val saved = CloudPipelineFlags.override
        try {
            CloudPipelineFlags.override = false
            assertFalse(CloudPipelineFlags.isCloudPipelineForBackend("cloud"))
            assertFalse(CloudPipelineFlags.isCloudPipelineForBackend("anthropic"))
            assertFalse(CloudPipelineFlags.isCloudPipelineForBackend("responses"))
        } finally {
            CloudPipelineFlags.override = saved
        }
    }

    @Test
    @DisplayName("★ 未验证轨名单必须只有两条（防手滑放宽）")
    fun unverifiedBackendListIsDeliberate() {
        assertEquals(
            setOf("anthropic", "responses"),
            CloudPipelineFlags.UNVERIFIED_BACKENDS,
            "放宽这个集合 = 拿未验证的 wire 赌用户。要先真 Key 验证才能删条目",
        )
    }
}
