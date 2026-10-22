package dev.heracles.cloud

import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.tool.CloudTool
import dev.heracles.cloud.tool.CloudToolExecutor
import dev.heracles.cloud.tool.CloudToolRegistry
import dev.heracles.cloud.tool.ToolOutcome
import dev.heracles.cloud.tool.ToolRunStatus
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **并行调用的真并发门禁**（2026-10-21）。
 *
 * ## 为什么需要"耗时"证据，而不只是"接收了 3 个调用"
 *
 * 真机日志能证明 `calls=3`（模型一轮发了 3 个），但**证明不了它们真的重叠执行**——
 * 串行执行同样会产生那行日志。用户的价值来自"3 个读并行往返"，
 * 所以必须测**墙钟**。
 *
 * ## 这个文件同时钉住一个**我自己写出的 bug**
 *
 * `CloudToolExecutor` 第一版把**全部** accepted 调用都 `async` 并行，
 * 注释却写"由 `parallelSafe` 声明决定"——**代码没看那个声明**。
 * 后果：两个 `write_file` 并发写同一文件、两个审批弹窗抢单槽队列。
 *
 * ⇒ 本文件两个方向都测：**该并发的并发**、**不该并发的绝不并发**。
 */
class CloudParallelConcurrencyTest {

    private val WORK_MS = 200L

    /** 造一个会阻塞 [WORK_MS] 的工具。 */
    private fun slowTool(name: String, parallelSafe: Boolean): CloudTool = CloudTool(
        spec = ToolSpec(name, "slow"),
        run = { delay(WORK_MS); ToolOutcome.Success("$name done") },
        parallelSafe = parallelSafe,
    )

    private fun executorOf(
        tools: List<CloudTool>,
        neverConcurrent: Set<String> = emptySet(),
    ): CloudToolExecutor = CloudToolExecutor(
        registry = CloudToolRegistry(resident = tools),
        neverConcurrent = neverConcurrent,
        executeTool = { call, _ ->
            // 走真实的工具执行体（含 registry 查找）
            val t = tools.first { it.spec.name == call.name }
            when (val o = t.run(emptyMap())) {
                is ToolOutcome.Success -> dev.heracles.cloud.tool.ToolRunResult(call, ToolRunStatus.OK, o.detail)
                is ToolOutcome.Failure -> dev.heracles.cloud.tool.ToolRunResult(call, ToolRunStatus.FAILED, o.reason, isError = true)
                else -> dev.heracles.cloud.tool.ToolRunResult(call, ToolRunStatus.FAILED, "x", isError = true)
            }
        },
    )

    @Test
    @DisplayName("★★★ parallelSafe 的多个调用必须**真并发**（墙钟 ≈ 1×WORK，不是 N×WORK）")
    fun parallelSafeToolsOverlap() = runBlocking {
        val tools = listOf(slowTool("read_file", true), slowTool("grep_files", true), slowTool("list_files", true))
        val exec = executorOf(tools)

        val started = System.nanoTime()
        val results = exec.executeTurn(
            listOf(
                CloudToolCall("c1", "read_file", "{}"),
                CloudToolCall("c2", "grep_files", "{}"),
                CloudToolCall("c3", "list_files", "{}"),
            )
        )
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertEquals(3, results.size)
        assertTrue(results.all { it.status == ToolRunStatus.OK }, "三个都该成功")
        // 串行会是 ~600ms；并发应显著低于 2×WORK
        assertTrue(
            elapsedMs < WORK_MS * 2,
            "三个 parallelSafe 工具必须重叠执行。串行应 ≈${WORK_MS * 3}ms，实际 ${elapsedMs}ms",
        )
    }

    @Test
    @DisplayName("★★★ 非 parallelSafe（写类）必须**串行**（墙钟 ≈ N×WORK，防写冲突）")
    fun unsafeToolsRunSequentially() = runBlocking {
        val tools = listOf(
            slowTool("write_file", false),
            slowTool("edit", false),
            slowTool("apply_patch", false),
        )
        val exec = executorOf(tools)

        val started = System.nanoTime()
        exec.executeTurn(
            listOf(
                CloudToolCall("c1", "write_file", "{}"),
                CloudToolCall("c2", "edit", "{}"),
                CloudToolCall("c3", "apply_patch", "{}"),
            )
        )
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertTrue(
            elapsedMs >= WORK_MS * 3,
            "三个写类工具**必须串行**（并发写同一文件会竞态）。实际 ${elapsedMs}ms，" +
                "应 ≥ ${WORK_MS * 3}ms —— 若小于它说明 parallelSafe 又被忽略了",
        )
    }

    @Test
    @DisplayName("★★ 声明了 parallelSafe 但在 neverConcurrent 里 ⇒ 仍然串行（审批类例外）")
    fun neverConcurrentOverridesParallelSafe() = runBlocking {
        // run_shell_command 会走审批；即使将来有人把它标 parallelSafe，也不能并发
        val tools = listOf(slowTool("run_shell_command", true), slowTool("build_apk", true))
        val exec = executorOf(tools, neverConcurrent = setOf("run_shell_command", "build_apk"))

        val started = System.nanoTime()
        exec.executeTurn(
            listOf(
                CloudToolCall("c1", "run_shell_command", "{}"),
                CloudToolCall("c2", "build_apk", "{}"),
            )
        )
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertTrue(
            elapsedMs >= WORK_MS * 2,
            "审批类工具不得并发（单槽队列会喂错 reply）。实际 ${elapsedMs}ms",
        )
    }

    @Test
    @DisplayName("★★ 混合批次：读类并发、写类串行；返回顺序仍 = 输入顺序")
    fun mixedBatchKeepsOrderAndPartialConcurrency() = runBlocking {
        val tools = listOf(
            slowTool("read_file", true),
            slowTool("write_file", false),
            slowTool("grep_files", true),
        )
        val exec = executorOf(tools)

        val started = System.nanoTime()
        val results = exec.executeTurn(
            listOf(
                CloudToolCall("c1", "write_file", "{}"),   // 写在前
                CloudToolCall("c2", "read_file", "{}"),    // 读
                CloudToolCall("c3", "grep_files", "{}"),   // 读
            )
        )
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        // 顺序必须与输入一致（UI 步骤列表不能抖）
        assertEquals(listOf("write_file", "read_file", "grep_files"), results.map { it.call.name })
        // 墙钟：两个读并发 + 一个写串行 ⇒ 约 2×WORK（若全串行 3×WORK）
        assertTrue(
            elapsedMs < WORK_MS * 3,
            "两个读应并发掉一部分时间。实际 ${elapsedMs}ms（全串行约 ${WORK_MS * 3}ms）",
        )
    }

    @Test
    @DisplayName("★★ 超单轮上限的调用仍**配对回填**未执行（不静默丢，否则下次请求 400）")
    fun overflowStillBackfilled() = runBlocking {
        val tools = listOf(slowTool("read_file", true))
        val exec = CloudToolExecutor(
            registry = CloudToolRegistry(resident = tools),
            maxCallsPerTurn = 2,
            executeTool = { call, _ -> dev.heracles.cloud.tool.ToolRunResult(call, ToolRunStatus.OK, "ok") },
        )
        val results = exec.executeTurn(
            (1..4).map { CloudToolCall("c$it", "read_file", "{}") }
        )
        assertEquals(4, results.size, "每个调用都必须有结果（wire 配对语义）")
        assertEquals(2, results.count { it.status == ToolRunStatus.NOT_EXECUTED })
        assertTrue(results.filter { it.status == ToolRunStatus.NOT_EXECUTED }.all { it.isError })
    }
}
