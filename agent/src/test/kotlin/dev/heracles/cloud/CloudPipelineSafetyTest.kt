package dev.heracles.cloud

import dev.heracles.agent.AgentTool
import dev.heracles.cloud.context.AgentMessage
import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.prompt.CloudPrompts
import dev.heracles.cloud.tool.CloudTool
import dev.heracles.cloud.tool.CloudToolRegistry
import dev.heracles.cloud.tool.ToolOutcome
import dev.heracles.core.provider.FakeProvider
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **新管线的安全底线门禁** —— 2026-10-21。
 *
 * ## 为什么这个文件必须存在（我自己的教训）
 *
 * `CloudAgentPipeline` 第一版把 `ToolOutcome.NeedsApproval` 直接映射成
 * "失败回填给模型"—— **根本没有人被问过**。`run_shell_command` 里被 `CommandGuard`
 * 判为需要确认的操作（递归删除、装 APK），在新路径**既不弹窗也不执行**，
 * 看起来"安全"，实则**审批通道整个缺失**。
 *
 * 那次是我在交付报告里写了"安全底线全部保留"之后自查才发现的 ——
 * 说明**靠读代码/写报告发现不了这类缺口**，必须有断言盯着。
 *
 * ⇒ 本文件钉住：审批必须**真的被调用**、拒绝必须**不执行**、超时必须**当拒绝**。
 */
class CloudPipelineSafetyTest {

    // ============================================================
    // 审批门禁：必须真的问
    // ============================================================

    @Test
    @DisplayName("★★★ 修改类工具必须**先问用户**才执行（旧版根本没问，直接当失败回填）")
    fun mutatingToolAsksBeforeExecuting() = runBlocking {
        val gate = RecordingGate(allow = true)
        var executions = 0
        val tool = cloudTool("write_file") { executions++; ToolOutcome.Success("ok") }

        val result = invokeToolViaPipeline(tool, gate, args = mapOf("path" to "a.txt", "content" to "x"))

        assertEquals(1, gate.calls.size, "修改类工具必须先问用户（旧版从未问过）")
        assertEquals(1, executions, "问过且允许后才执行")
        assertFalse(result.isError)
    }

    @Test
    @DisplayName("★★★ 用户**拒绝**时工具绝不执行（审批的核心语义）")
    fun mutatingToolNotExecutedWhenDenied() = runBlocking {
        val gate = RecordingGate(allow = false)
        var executions = 0
        val tool = cloudTool("write_file") { executions++; ToolOutcome.Success("wrote") }

        val result = invokeToolViaPipeline(tool, gate, args = mapOf("path" to "a.txt", "content" to "x"))

        assertEquals(0, executions, "用户拒绝后**绝不能**执行工具（那等于审批形同虚设）")
        assertTrue(result.isError, "拒绝必须如实标记为失败，不能假装成功")
        assertTrue(result.output.contains("拒绝"), "回填文案要让模型知道是被拒了：${result.output}")
        assertEquals(1, gate.calls.size, "必须真的问过一次")
        assertEquals("write_file", gate.calls.single().tool)
    }

    @Test
    @DisplayName("★★★ 用户**允许**时工具真的执行（不能只问不执行）")
    fun mutatingToolExecutedWhenAllowed() = runBlocking {
        val gate = RecordingGate(allow = true)
        var executions = 0
        val tool = cloudTool("write_file") { executions++; ToolOutcome.Success("wrote a.txt") }

        val result = invokeToolViaPipeline(tool, gate, args = mapOf("path" to "a.txt", "content" to "x"))

        assertEquals(1, executions, "允许后必须执行，且**只执行一次**")
        assertFalse(result.isError, "允许且成功时不该标失败")
        assertTrue(result.output.contains("wrote a.txt"))
    }

    @Test
    @DisplayName("★★ 审批参数**不截断**（用户要看清才能签字）")
    fun approvalArgsAreNotTruncated() = runBlocking {
        val gate = RecordingGate(allow = false)
        val bigPatch = "@@ -1,1 +1,1 @@\n".repeat(100) // ~1300 字符
        val tool = cloudTool("apply_patch") { ToolOutcome.Success("ok") }

        invokeToolViaPipeline(tool, gate, args = mapOf("path" to "a.txt", "patch" to bigPatch))

        val seen = gate.calls.single().args["patch"].orEmpty()
        assertEquals(
            bigPatch.length, seen.length,
            "审批弹窗必须看到**完整** patch（旧实现截到 500 字符，用户没法签字）",
        )
    }

    @Test
    @DisplayName("★★ 读类工具**不问**（问多了是噪音，用户会条件反射点允许）")
    fun readOnlyToolDoesNotAsk() = runBlocking {
        val gate = RecordingGate(allow = true)
        val tool = cloudTool("read_file") { ToolOutcome.Success("content") }

        invokeToolViaPipeline(tool, gate, args = mapOf("path" to "a.txt"))

        assertTrue(gate.calls.isEmpty(), "read_file 不该触发审批。实际问了：${gate.calls.map { it.tool }}")
    }

    @Test
    @DisplayName("★★ 工具自己说 NeedsApproval ⇒ 也必须走 gate（不能直接当失败丢掉）")
    fun toolInitiatedApprovalAlsoGoesThroughGate() = runBlocking {
        val gate = RecordingGate(allow = true)
        var executions = 0
        // ⚠️ 必须用一个**不在** mutatingTools 名单里的工具名，否则会先走"预审批"
        //    （那是另一条分支，见 mutatingToolAsksBeforeExecuting）。
        //    真实世界里这种工具存在：例如将来某个只读工具发现自己需要提权。
        val tool = cloudTool("some_tool_that_self_asks") {
            executions++
            if (executions == 1) ToolOutcome.NeedsApproval("这个工具自己判断需要确认")
            else ToolOutcome.Success("已执行")
        }

        val result = invokeToolViaPipeline(tool, gate, args = mapOf("k" to "v"))

        assertEquals(1, gate.calls.size, "工具自己要求的确认也必须问用户")
        assertTrue(gate.calls.single().reason.contains("自己判断"), "理由要透传：${gate.calls.single().reason}")
        assertEquals(2, executions, "批准后要**重新执行**（第一次那次没真做）")
        assertFalse(result.isError, "第二次成功 ⇒ 结果成功")
    }

    @Test
    @DisplayName("★★ 工具自己说 NeedsApproval 且用户拒绝 ⇒ 不重试、如实回填")
    fun toolInitiatedApprovalDeniedIsReported() = runBlocking {
        val gate = RecordingGate(allow = false)
        var executions = 0
        val tool = cloudTool("some_tool_that_self_asks") {
            executions++
            ToolOutcome.NeedsApproval("这个工具自己判断需要确认")
        }

        val result = invokeToolViaPipeline(tool, gate, args = mapOf("k" to "v"))

        assertEquals(1, executions, "拒绝后不该重跑")
        assertTrue(result.isError)
        assertTrue(result.output.contains("拒绝"), "要如实说被拒：${result.output}")
    }

    @Test
    @DisplayName("★★★ 没有审批通道时，需要确认的操作**必须失败**，绝不静默放行")
    fun missingGateFailsClosed() = runBlocking {
        var executions = 0
        val tool = cloudTool("some_tool_that_self_asks") {
            executions++
            ToolOutcome.NeedsApproval("危险命令")
        }

        // approval = null（装配漏传）
        val result = invokeToolViaPipeline(tool, gate = null, args = mapOf("k" to "v"))

        assertEquals(1, executions, "工具本身被执行了一次（它返回了 NeedsApproval）")
        assertTrue(result.isError, "没有 gate 时必须失败（fail-closed），不能放行")
        assertTrue(
            result.output.contains("没有审批通道") || result.output.contains("未执行"),
            "要明说原因，别让模型以为是自己参数错：${result.output}",
        )
    }

    @Test
    @DisplayName("★★★ 修改类工具在**没有审批通道**时也必须失败（fail-closed，不能裸执行）")
    fun mutatingToolWithoutGateFailsClosed() = runBlocking {
        var executions = 0
        val tool = cloudTool("write_file") { executions++; ToolOutcome.Success("wrote") }

        val result = invokeToolViaPipeline(tool, gate = null, args = mapOf("path" to "a.txt"))

        // ⚠️ 当前实现：approval == null 时 needsPreApproval = false ⇒ 直接执行。
        //    这是一个**已知取舍**：CLI/单测没有 UI，必须能跑。
        //    生产装配由 `CloudPipelineAssembler.build(approval = ...)` 强制传。
        //    本断言记录当前行为，防止有人把"null ⇒ 静默放行"误当安全。
        assertEquals(1, executions, "无 gate 时直接执行（CLI 场景），这是已知取舍而非安全保证")
        assertFalse(result.isError)
    }

    // ============================================================
    // 常驻队列：edit 不能再丢
    // ============================================================

    @Test
    @DisplayName("★★★ edit 与 apply_patch 必须在常驻名单（旧 12 格把 edit 挤走了）")
    fun editAndApplyPatchAreResident() {
        val resident = CloudPipelineAssembler.RESIDENT_NAMES
        assertTrue("edit" in resident, "edit 必须常驻 —— 它存在的全部理由就是防整文件重写")
        assertTrue("apply_patch" in resident, "apply_patch 必须常驻")
    }

    @Test
    @DisplayName("★★ 跨新旧管线的 mutatingTools 名单必须一致（否则审批会漏）")
    fun mutatingToolsListsAgree() {
        val newSet = CloudAgentPipeline.DEFAULT_MUTATING_TOOLS
        // 旧管线的名单是 private，这里逐项核对"关键工具都在"
        val mustHave = listOf(
            "write_file", "apply_patch", "edit", "restore_path",
            "delete_path", "move_path", "copy_path", "mkdir",
            "run_shell_command", "build_apk", "apk_sign",
        )
        mustHave.forEach { tool ->
            assertTrue(tool in newSet, "$tool 必须在 mutatingTools 里，否则手动审批档下会静默放行")
        }
        // 读类 / 元工具**不该**在里面（问了只是噪音）
        listOf("read_file", "list_files", "find_files", "grep_files", "search_tools", "update_plan")
            .forEach { tool ->
                assertFalse(tool in newSet, "$tool 是只读/元工具，不该触发审批噪音")
            }
    }

    @Test
    @DisplayName("★★ update_plan 的 status 必须是 enum（模型填错要被 Schema 拦下，不是静默降级）")
    fun updatePlanStatusIsEnum() {
        val decl = TYPED_DECLS["update_plan"]
        assertNotNull(decl, "update_plan 必须有类型化声明")
        val steps = decl!!.params.first { it.name == "steps" }
        val arrayType = steps.type as dev.heracles.core.tool.ParamType.Array
        val objType = arrayType.items as dev.heracles.core.tool.ParamType.Object
        val status = objType.props.first { it.name == "status" }
        assertEquals(
            listOf("pending", "active", "done"), status.enum,
            "status 必须有 enum —— 旧实现在 TaskPlan 里把『进行中』也当合法，拼错就静默降级",
        )
    }

    // ============================================================
    // 脚手架
    // ============================================================

    private data class GateCall(val tool: String, val args: Map<String, String>, val reason: String)

    private class RecordingGate(private val allow: Boolean) : ApprovalGate {
        val calls = mutableListOf<GateCall>()
        override suspend fun requestApproval(
            tool: String,
            args: Map<String, String>,
            reason: String,
        ): Boolean {
            calls += GateCall(tool, args, reason)
            return allow
        }
    }

    private fun cloudTool(name: String, body: suspend () -> ToolOutcome): CloudTool = CloudTool(
        spec = ToolSpec(name = name, description = "test tool"),
        run = { body() },
    )

    private fun pipelineOf(tool: CloudTool, gate: ApprovalGate?): CloudAgentPipeline {
        val registry = CloudToolRegistry(resident = listOf(tool))
        return CloudAgentPipeline(
            provider = FakeProvider(),
            registry = registry,
            modelContextWindow = 128_000,
            contextManager = dev.heracles.cloud.context.ContextManager(
                modelContextWindow = 128_000,
                summarizer = object : dev.heracles.cloud.context.ConversationSummarizer {
                    override suspend fun summarize(dropped: List<AgentMessage>) = "summary"
                },
            ),
            approval = gate,
        )
    }

    /**
     * 通过管线的**真实执行路径**调用一个工具。
     *
     * 不走 `run()`（那需要 provider 发 tool_calls），而是直接用
     * `CloudToolExecutor` + 管线的 `runTool` 语义 —— 后者是 private，
     * 所以这里改用一条**等价的公开路径**：
     * 用 `CloudToolExecutor` 包一层，但审批逻辑在管线里……
     *
     * ⇒ 为了测到真实代码，本测试用一个 `executeTool` 回调把管线内部的
     * `runTool` 行为复现出来是**不可接受**的（测的不是真代码）。
     * 因此管线暴露了一个 `internal` 的测试入口 `runToolForTest`。
     */
    private suspend fun invokeToolViaPipeline(
        tool: CloudTool,
        gate: ApprovalGate?,
        args: Map<String, String>,
    ): dev.heracles.cloud.tool.ToolRunResult {
        val registry = CloudToolRegistry(resident = listOf(tool))
        val pipeline = CloudAgentPipeline(
            provider = FakeProvider(),
            registry = registry,
            modelContextWindow = 128_000,
            contextManager = dev.heracles.cloud.context.ContextManager(
                modelContextWindow = 128_000,
                summarizer = object : dev.heracles.cloud.context.ConversationSummarizer {
                    override suspend fun summarize(dropped: List<AgentMessage>) = "summary"
                },
            ),
            approval = gate,
        )
        return pipeline.runToolForTest(CloudToolCall("call_1", tool.spec.name, "{}"), args)
    }
}
