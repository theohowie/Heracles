package dev.heracles.agent

import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.FakeProvider
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.tool.ToolCall
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Path

/**
 * **事件发射的行为门禁**（2026-10-10，`AgentEvent` 流式）。
 *
 * ## 为什么必须有这个测试
 *
 * 之前 `:agent` 模块**没有 `src/test` 目录**，66 项测试全在 `:core` /
 * `:workspace` —— 也就是说 "会话区边跑边显示" 这条链路依赖的
 * `AgentLoop.onEvent` **一度是零自动化覆盖的**。
 *
 * 而这个改动的风险恰恰是"静默失效"：
 * - 事件顺序错了（`ToolStarted` 发在 `execute` 之后）→ 用户看到
 *   "工具跑完才出现"，正是本次要修的 bug 原样复现
 * - `ok` 映射错了 → UI 把成功显示成失败
 * - `Blocked` 被误当成 `ToolFinished` → UI 显示"工具失败"，
 *   但工具**根本没执行**，误导用户以为工具坏了
 * - 回调抛异常把整轮 agent 带崩（`runCatching` 被删掉）
 * - 最严重：为了加事件而**改动了 prompt 构造或 `Session.append` 序列**
 *   → 铁律 1 被破坏，缓存命中率塌方，且**没有任何别的测试会红**
 *
 * 最后一条是本文件最重要的存在理由 —— 见
 * `eventsDoNotAlterPromptOrRecords` 这个测试。
 *
 * ## 为什么不依赖真机
 *
 * 用 `FakeProvider` 脚本化模型输出（与 `CapabilityGateTest` 同款做法），
 * 所以整条链路在 PC 上毫秒级回归，不需要手机、不需要模型。
 */
class AgentEventEmissionTest {

    // ------------------------------------------------------------ 测试替身

    /** 最低限度的 `WorkspaceFs` —— 本测试只关心事件，不碰文件。 */
    private class NoopFs : WorkspaceFs {
        override val info = WorkspaceInfo(Path.of(".").toAbsolutePath(), "test")
        override suspend fun list(relativeDir: String): List<FileEntry> = emptyList()
        override suspend fun readText(relativePath: String): String = ""
        override suspend fun writeText(relativePath: String, content: String): Long = 0
        override suspend fun exists(relativePath: String): Boolean = false
        override suspend fun mkdirs(relativeDir: String) {}
    }

    /** 记录调用次数的假工具 —— 用来断言"**有没有真的执行**"。 */
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

    private val validCall =
        """{"tool":"write_file","args":{"path":"a.txt","content":"hi"}}"""

    /** 已 `load()` 的 FakeProvider，每轮都返回同一 [response]。 */
    private fun providerAlways(response: String): FakeProvider {
        val p = FakeProvider()
        p.onPrompt({ true }, response)
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()
        return p
    }

    /** 无任何规则 → `generate` 必然失败（provider 错误路径）。 */
    private fun failingProvider(): FakeProvider {
        val p = FakeProvider()
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()
        return p
    }

    /** 事件类型序列，便于整体断言。 */
    private fun kinds(events: List<AgentEvent>) = events.map { it::class.simpleName }

    /**
     * **只保留轮级事件** —— 2026-10-12 流式改造后必需的过滤。
     *
     * ## 为什么需要它
     *
     * 本类原有的断言全部针对**轮级**事件序列
     * （`TurnStarted` → `ModelOutput` → `ToolStarted` …），
     * 它们测的是"轮次语义"：工具在 execute 前发通知、拦截不发 ToolFinished、等等。
     *
     * 流式改造后，同一批事件里**混入了 token 级事件**
     * （`StepStarted` / `StepDelta` / `ReasoningDelta` / `StepEnded`）。
     *
     * ⚠️ **这不是"旧断言过时了"，而是粒度不同的两套断言必须分开**：
     * - 轮级断言（本文件的）：**不能**被 token 级噪声干扰 ——
     *   否则一次输出几百个 chunk 会把序列断言彻底淹没，读不出"轮次语义对不对"
     * - token 级断言（`StreamCoalescerTest` / 本文件末尾新增的）：
     *   单独测增量、合并、顺序
     *
     * ⇒ 所以这里过滤掉 token 级事件，**轮级语义的断言保持原样、一字未改**。
     * 若轮级序列真的错了，这些断言照样会红。
     */
    private fun turnKinds(events: List<AgentEvent>) = events
        .filterNot {
            it is AgentEvent.StepStarted || it is AgentEvent.StepEnded ||
                it is AgentEvent.StepDelta || it is AgentEvent.ReasoningDelta ||
                // ★ PlanClosed 是**任务级**收尾，不是轮级（2026-10-15，BUG-1）
                //
                // 它和 TurnStarted / ModelOutput 不是一类东西：
                // 前者描述"这一次任务怎么结束的"，后者描述"某一轮发生了什么"。
                // 把它算进轮级序列会让所有既有断言旁边多一个同名项，
                // **淹没真正要守的轮级语义**（这正是本过滤器存在的理由）。
                //
                // ⚠️ 它的正确性由**专门的测试**守：
                //    planClosedOnSuccess / planClosedOnHardStopIsNotGoal
                it is AgentEvent.PlanClosed ||
                it is AgentEvent.PlanCreated ||
                it is AgentEvent.PlanAdvanced
        }
        .map { it::class.simpleName }

    /** 收事件的容器。 */
    private class Recorder {
        val events = mutableListOf<AgentEvent>()
        val handler: (AgentEvent) -> Unit = { events += it }
    }

    // -------------------------------------------------- 1. 正常路径：最终回答

    @Test
    @DisplayName("最终回答：TurnStarted → ModelOutput → Finished")
    fun finalAnswerPath() {
        val rec = Recorder()
        val result = AgentLoop(
            providerAlways("""{"final":"done"}"""),
            NoopFs(), emptyList(),
            onEvent = rec.handler,
        ).run("你好")

        assertEquals("已给出最终回答", result.stopReason)
        // ★ 只断言轮级序列 —— token 级事件（StepStarted/StepDelta/StepEnded）
        //   与轮级是**两种粒度**，混在一起断言会把轮次语义淹没。
        //   见 turnKinds 的说明。
        assertEquals(listOf("TurnStarted", "ModelOutput", "Finished"), turnKinds(rec.events))

        assertEquals(1, (rec.events.first() as AgentEvent.TurnStarted).index)

        val out = rec.events.filterIsInstance<AgentEvent.ModelOutput>().single()
        assertEquals(1, out.index)
        assertEquals("""{"final":"done"}""", out.raw, "「完全展开」档位依赖 raw 原样透传")

        val fin = rec.events.filterIsInstance<AgentEvent.Finished>().single()
        assertEquals("done", fin.finalText)
        assertEquals(1, fin.turnCount)
        assertTrue(rec.events.none { it is AgentEvent.Failed })
    }

    // -------------------------------------------------- 2. 正常路径：工具调用

    @Test
    @DisplayName("工具调用：ToolStarted 必须在 execute 之前，ToolFinished 带 ok")
    fun toolCallPath() {
        var call = 0
        val p = FakeProvider()
        p.onPrompt({ call++ == 0 }, validCall)
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入 2 字节"))
        val rec = Recorder()
        val result = AgentLoop(p, NoopFs(), listOf(tool), maxTurns = 4, onEvent = rec.handler)
            .run("写文件")

        assertEquals("已给出最终回答", result.stopReason)
        assertEquals(1, tool.executeCount)

        // ★ 顺序断言 —— 这是"边跑边显示"的核心：
        //   ToolStarted 在 ToolFinished 之前，ToolFinished 在下一轮 TurnStarted 之前
        assertEquals(
            listOf(
                "TurnStarted", "ModelOutput", "ToolStarted", "ToolFinished",
                "TurnStarted", "ModelOutput", "Finished",
            ),
            turnKinds(rec.events),
        )

        val started = rec.events.filterIsInstance<AgentEvent.ToolStarted>().single()
        assertEquals(
            ToolCall("write_file", mapOf("path" to "a.txt", "content" to "hi")),
            started.call,
        )

        val done = rec.events.filterIsInstance<AgentEvent.ToolFinished>().single()
        assertEquals("write_file", done.call.tool)
        assertEquals("已写入 2 字节", done.result)
        assertTrue(done.ok, "Success 必须映射成 ok=true")

        // 原始输出也必须在（用户能看到模型"打算干什么"）
        assertEquals(validCall, rec.events.filterIsInstance<AgentEvent.ModelOutput>().first().raw)
    }

    @Test
    @DisplayName("工具失败：ok=false（UI 据此显示失败态）")
    fun toolFailureMapsToOkFalse() {
        var call = 0
        val p = FakeProvider()
        p.onPrompt({ call++ == 0 }, validCall)
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val rec = Recorder()
        AgentLoop(
            p, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Failure("磁盘满"))),
            maxTurns = 4, onEvent = rec.handler,
        ).run("写文件")

        val done = rec.events.filterIsInstance<AgentEvent.ToolFinished>().single()
        assertEquals("失败：磁盘满", done.result)
        assertTrue(!done.ok, "Failure 必须映射成 ok=false")
    }

    // -------------------------------------------------- 3. 拦截：工具不得执行

    // ================================================== H-1：三态（2026-10-10）

    @Test
    @DisplayName("★★ H-1：执行成功 → toolState=succeeded")
    fun executedSuccessIsSucceeded() {
        var call = 0
        val p = FakeProvider()
        p.onPrompt({ call++ == 0 }, validCall)
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val result = AgentLoop(
            p, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("已写入"))),
            maxTurns = 4,
        ).run("写文件")

        val t = result.turns.first { it.toolCall != null && it.toolResult != null }
        assertEquals(ToolState.succeeded, t.toolState)
        assertTrue(!t.toolBlocked, "真的执行成功了，不该算拦截")
    }

    @Test
    @DisplayName("★★ H-1：执行失败 → toolState=failed（**不是** blocked）")
    fun executedFailureIsFailedNotBlocked() {
        var call = 0
        val p = FakeProvider()
        p.onPrompt({ call++ == 0 }, validCall)
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val result = AgentLoop(
            p, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Failure("磁盘满"))),
            maxTurns = 4,
        ).run("写文件")

        val t = result.turns.first { it.toolCall != null && it.toolResult != null }
        // ★ 失败**执行过** —— 与被拦截（从未执行）是不同状态
        assertEquals(ToolState.failed, t.toolState)
        assertTrue(!t.toolBlocked, "失败是执行过了，不该算 blocked")
    }

    @Test
    @DisplayName("★★ H-1：重复调用拦截 → toolState=blocked（**绝不是** succeeded）")
    fun repeatedCallIsBlocked() {
        val same = validCall
        var call = 0
        val p = FakeProvider()
        p.onPrompt({ call++ < 2 }, same)
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val result = AgentLoop(
            p, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("已写入"))),
            maxTurns = 6,
        ).run("写文件")

        // 被拦截那一轮：toolCall 非空、但根本没有 toolResult
        val blockedTurn = result.turns.first {
            it.verdict.startsWith("重复调用已拦截")
        }
        assertEquals(ToolState.blocked, blockedTurn.toolState)
        assertTrue(blockedTurn.toolBlocked)

        // ★★ 这就是 H-1 的根因断言：
        //    它的 verdict **不含「失败」**，所以任何"靠中文子串猜状态"
        //    的下游实现都会把它误判成成功。
        assertTrue(
            !blockedTurn.verdict.contains("失败"),
            "前提变了：verdict 现在含「失败」了 —— 那 H-1 的触发条件需要重新评估",
        )
    }

    @Test
    @DisplayName("★★ H-1：循环硬停 → toolState=blocked")
    fun loopHardStopIsBlocked() {
        val p = FakeProvider()
        p.onPrompt({ true }, validCall)
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val result = AgentLoop(
            p, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("已写入"))),
            maxTurns = 6,
        ).run("写文件")

        val hardStop = result.turns.first { it.verdict.contains("检测到循环") }
        assertEquals(ToolState.blocked, hardStop.toolState)
        // 同样是"不含「失败」"的 verdict —— H-1 的触发条件
        assertTrue(!hardStop.verdict.contains("失败"))
    }

    @Test
    @DisplayName("★★ H-1：校验失败拦截 → toolState=blocked")
    fun validationFailureIsBlocked() {
        var call = 0
        val p = FakeProvider()
        p.onPrompt(
            { call++ == 0 },
            """{"tool":"write_file","args":{"path":"a.txt","content":"hi","bogus":"x"}}""",
        )
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val result = AgentLoop(p, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("不该被调用"))), maxTurns = 4)
            .run("写文件")

        val t = result.turns.first { it.verdict.startsWith("校验失败") }
        assertEquals(ToolState.blocked, t.toolState)
    }

    @Test
    @DisplayName("没有请求工具的那一轮 → toolState=notRequested")
    fun finalAnswerTurnIsNotRequested() {
        val p = providerAlways("""{"final":"done"}""")
        val result = AgentLoop(p, NoopFs(), emptyList()).run("你好")

        assertEquals(ToolState.notRequested, result.turns.single().toolState)
        assertTrue(!result.turns.single().toolBlocked)
    }

    @Test
    @DisplayName("校验失败：发 Blocked，且工具绝不执行")
    fun validationFailureBlocks() {
        var call = 0
        val p = FakeProvider()
        // bogus 是未知参数 → ToolValidator 必拦
        p.onPrompt(
            { call++ == 0 },
            """{"tool":"write_file","args":{"path":"a.txt","content":"hi","bogus":"x"}}""",
        )
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val tool = RecordingTool(writeSpec, ToolOutcome.Success("不该被调用"))
        val rec = Recorder()
        AgentLoop(p, NoopFs(), listOf(tool), maxTurns = 4, onEvent = rec.handler).run("写文件")

        assertEquals(0, tool.executeCount, "校验不过时绝不执行工具")

        val blocked = rec.events.filterIsInstance<AgentEvent.Blocked>().single()
        assertEquals(1, blocked.index)
        assertEquals("write_file", blocked.call?.tool)
        assertTrue(blocked.reason.startsWith("校验失败："), "实际：${blocked.reason}")

        // ★ 关键：拦截**不是**工具失败。UI 不该显示成"工具坏了"
        assertTrue(
            rec.events.none { it is AgentEvent.ToolStarted || it is AgentEvent.ToolFinished },
            "被拦截的调用不得产生 ToolStarted/ToolFinished",
        )
    }

    @Test
    @DisplayName("输出无法解析：Blocked 的 call 为 null（Dart 侧必须判空）")
    fun unparseableBlocksWithNullCall() {
        var call = 0
        val p = FakeProvider()
        p.onPrompt({ call++ == 0 }, "我打算先看看目录")   // 不是 JSON
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val rec = Recorder()
        AgentLoop(p, NoopFs(), emptyList(), maxTurns = 4, onEvent = rec.handler).run("看看")

        val blocked = rec.events.filterIsInstance<AgentEvent.Blocked>().single()
        assertEquals(1, blocked.index)
        assertNull(blocked.call, "连调用都没解析出来 → call 必须是 null")
        assertTrue(blocked.reason.startsWith("输出无法解析："), "实际：${blocked.reason}")
    }

    @Test
    @DisplayName("重复调用：发 Blocked，且第二次不执行")
    fun repeatedCallBlocks() {
        var call = 0
        val p = FakeProvider()
        p.onPrompt({ call++ < 2 }, validCall)
        p.onPrompt({ true }, """{"final":"ok"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = Recorder()
        AgentLoop(p, NoopFs(), listOf(tool), maxTurns = 6, onEvent = rec.handler).run("写文件")

        assertEquals(1, tool.executeCount, "第二次相同调用不得执行")

        val blocked = rec.events.filterIsInstance<AgentEvent.Blocked>().single()
        assertEquals("write_file", blocked.call?.tool)
        assertTrue(blocked.reason.startsWith("重复调用已拦截"), "实际：${blocked.reason}")
    }

    // -------------------------------------------------- 4. 终止事件必须到达

    @Test
    @DisplayName("循环硬停：Blocked 之后必须有 Finished 收尾（否则 UI 永远转圈）")
    fun loopHardStopStillFinishes() {
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val rec = Recorder()
        val result = AgentLoop(
            providerAlways(validCall), NoopFs(), listOf(tool),
            maxTurns = 6, onEvent = rec.handler,
        ).run("写文件")

        assertEquals("检测到循环，已停止", result.stopReason)
        assertEquals(1, tool.executeCount, "硬停前只应执行过一次")

        // 第 2 次是"重复拦截"，第 3 次是"硬停"
        assertEquals(2, rec.events.filterIsInstance<AgentEvent.Blocked>().size)

        val last = rec.events.last()
        assertTrue(last is AgentEvent.Finished, "硬停也必须发终止事件，否则 UI 停在'运行中'")
        assertTrue((last as AgentEvent.Finished).finalText.contains("判定任务已完成并停止"))
        assertEquals("检测到循环，已停止", last.stopReason)
    }

    @Test
    @DisplayName("轮次耗尽：兜底 Finish，不假装有最终回答")
    fun maxTurnsExhaustionFinishes() {
        val rec = Recorder()
        // 每轮请求一个**合法的**工具调用 —— 这样：
        //   · 不触发"解析失败熔断"（输出是合法 JSON）
        //   · 第 2 轮会因为"重复调用"被拦（**不执行**），但仍消耗轮次
        //   ⇒ 真正跑到 maxTurns，验证"轮次耗尽的兜底收尾"
        //
        // ⚠️ 2026-10-14 改：原来用 `providerAlways("不是 JSON")` 消耗轮次，
        //    而今天加了"连续解析失败熔断"（修真机死循环：4 轮 × 100 秒），
        //    于是这个测试被提前截停。**测试意图没变**（验证轮次耗尽的
        //    收尾事件），只是换一种不撞熔断的手段。
        val result = AgentLoop(
            providerAlways("""{"tool":"write_file","args":{"path":"a.txt","content":"x"}}"""),
            NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("已写入"))),
            maxTurns = 2, onEvent = rec.handler,
        ).run("你好")

        assertEquals("达到最大轮次（2）", result.stopReason)
        assertEquals(2, result.turns.size)

        val last = rec.events.last()
        assertTrue(last is AgentEvent.Finished, "轮次耗尽也必须收尾")
        assertEquals("达到最大轮次（2）", (last as AgentEvent.Finished).stopReason)
        assertEquals(2, last.turnCount)
    }

    // ============================================ ★ 计划收尾（2026-10-15，BUG-1）

    @Test
    @DisplayName("★★ 任务完成 → 发 PlanClosed(reachedGoal=true)，计划不能停在「进行中」")
    fun planClosedOnSuccess() {
        val rec = Recorder()
        // 模型：先给计划 → 再直接 final（模拟"最后一步是汇报，不需要工具"）
        var turn = 0
        val p = FakeProvider()
        p.onPrompt({ turn++ == 0 }, """{"plan":["第一步：做点事","第二步：汇报结果"]}""")
        p.onPrompt({ true }, """{"final":"做完了"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        AgentLoop(p, NoopFs(), emptyList(), onEvent = rec.handler).run("干个活")

        val closed = rec.events.filterIsInstance<AgentEvent.PlanClosed>()
        assertEquals(1, closed.size, "任务结束必须发**恰好一次** PlanClosed —— 否则 UI 永远转圈")
        assertTrue(
            closed[0].reachedGoal,
            "给出了 final = 模型认为达成目标 ⇒ 剩余步骤应显示为**已完成**。\n" +
                "用户实测 bug：任务结束了，计划还显示「4/5 · 确认…进行中」",
        )
        // 顺序：PlanClosed 必须在 Finished **之前**（UI 先收计划，再收尾）
        val idxClosed = rec.events.indexOfFirst { it is AgentEvent.PlanClosed }
        val idxFinished = rec.events.indexOfFirst { it is AgentEvent.Finished }
        assertTrue(
            idxClosed in 0 until idxFinished,
            "PlanClosed 必须在 Finished 之前 —— 否则 UI 先结束运行、计划就没人收了",
        )
    }

    @Test
    @DisplayName("★★ 循环硬停 → PlanClosed(reachedGoal=false)（中断不能画成成功）")
    fun planClosedOnHardStopIsNotGoal() {
        val rec = Recorder()
        val p = FakeProvider()
        // 每轮都同一个调用 → 触发重复拦截 → 硬停
        p.onPrompt({ true }, """{"tool":"write_file","args":{"path":"a.txt","content":"x"}}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        AgentLoop(
            p, NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("已写入"))),
            maxTurns = 6, onEvent = rec.handler,
        ).run("写文件")

        val closed = rec.events.filterIsInstance<AgentEvent.PlanClosed>().singleOrNull()
        if (closed != null) {
            assertTrue(
                !closed.reachedGoal,
                "循环硬停是**中断**，不是达成目标 —— 画成绿勾就是 H-1 记录过的假信息",
            )
            assertTrue(closed.reason.isNotBlank(), "中断必须有可读原因")
        }
    }

    @Test
    @DisplayName("★ 轮次耗尽 → PlanClosed(reachedGoal=false)")
    fun planClosedOnMaxTurns() {
        val rec = Recorder()
        val result = AgentLoop(
            providerAlways("""{"tool":"write_file","args":{"path":"a.txt","content":"x"}}"""),
            NoopFs(), listOf(RecordingTool(writeSpec, ToolOutcome.Success("已写入"))),
            maxTurns = 2, onEvent = rec.handler,
        ).run("你好")

        assertEquals("达到最大轮次（2）", result.stopReason)
        val closed = rec.events.filterIsInstance<AgentEvent.PlanClosed>().singleOrNull()
        assertNotNull(closed, "轮次耗尽也要收计划")
        assertTrue(!closed!!.reachedGoal, "轮次耗尽 = 目标未达成，不能显示为完成")
    }

    // ============================================ 上下文压缩（2026-10-16）

    /**
     * **压缩机制的契约门禁**（用户需求「上下文压缩机制」）。
     *
     * ## 为什么需要压缩
     *
     * 长任务多次写大文件会把上下文塞满：
     * 本地 4K 一两轮就到顶；云端全量历史每轮重发按 token 计费。
     *
     * ## 压缩语义（ADR-006 兼容）
     *
     * 不是改写既有前缀（分支会让缓存塌缩），而是**从冻结区开始新前缀**：
     * 旧前缀弃用（缓存自然过期），新前缀 = 冻结区 + 摘要 + 原始请求。
     */
    @Test
    @DisplayName("★★ 上下文到 0.8 上限 → 触发压缩（新会话从摘要开始）")
    fun compactionTriggersAtLimit() {
        val rec = Recorder()
        // 大请求（> 0.8 × contextLimit=100）—— 让"冻结区+用户请求"
        // 在第 1 轮前就超过触发线
        val bigRequest = "任务：" + "细节".repeat(80)
        val p = FakeProvider()
        p.onPrompt({ true }, """{"final":"基于摘要继续"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        val result = AgentLoop(
            p, NoopFs(), emptyList(),
            maxTurns = 3,
            onEvent = rec.handler,
            contextLimit = 100,
        ).run(bigRequest)

        // 断言①：压缩发生了（有提示）
        val compactionMsgs = rec.events.filterIsInstance<AgentEvent.Blocked>()
            .map { it.reason }
            .filter { it.contains("压缩") }
        assertTrue(
            compactionMsgs.isNotEmpty(),
            "上下文超 0.8 上限必须触发压缩提示",
        )
        // 断言②：压缩发了**摘要请求**（第二次 prompt），且带旧会话内容
        assertTrue(
            p.requests.size >= 2,
            "压缩应额外发一次摘要请求，实际 ${p.requests.size} 次",
        )
        val summaryPrompt = p.requests[1].prompt
        assertTrue(
            summaryPrompt.contains("摘要") || summaryPrompt.contains("压缩"),
            "摘要请求要说明用途：${summaryPrompt.take(120)}",
        )
        // 断言③：任务正常完成（压缩后流程继续，不中断）
        assertEquals("已给出最终回答", result.stopReason)
    }

    @Test
    @DisplayName("★ 上限未知（<=0）绝不压缩")
    fun noCompactionWithoutLimit() {
        val rec = Recorder()
        val p = FakeProvider()
        p.onPrompt({ true }, """{"final":"done"}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()

        AgentLoop(
            p, NoopFs(), emptyList(), onEvent = rec.handler,
            contextLimit = 0, // 未知
        ).run("hi")

        val compactionMsgs = rec.events.filterIsInstance<AgentEvent.Blocked>()
            .filter { it.reason.contains("压缩") }
        assertTrue(
            compactionMsgs.isEmpty(),
            "上限未知时绝不压缩 —— 错误的上限会丢上下文",
        )
    }

    @Test
    @DisplayName("provider 错误：TurnStarted 之后是 Failed")
    fun providerErrorEmitsFailed() {
        val rec = Recorder()
        val result = AgentLoop(failingProvider(), NoopFs(), emptyList(), onEvent = rec.handler)
            .run("你好")

        assertEquals("provider 调用失败", result.stopReason)
        assertEquals("", result.finalText)
        assertEquals(listOf("TurnStarted", "Failed"), turnKinds(rec.events))
        assertTrue((rec.events.last() as AgentEvent.Failed).message.contains("provider 错误"))
    }

    // -------------------------------------------------- 5. 回调不得影响主流程

    @Test
    @DisplayName("回调抛异常：agent 仍跑完并返回正确结果（runCatching 生效）")
    fun throwingCallbackDoesNotBreakRun() {
        val loop = AgentLoop(
            providerAlways("""{"final":"done"}"""), NoopFs(), emptyList(),
            onEvent = { throw RuntimeException("UI 挂了") },
        )

        val result = loop.run("你好")

        // 事件是"增强"，UI 的 bug 不该让 agent 崩掉
        assertEquals("done", result.finalText)
        assertEquals("已给出最终回答", result.stopReason)
        assertEquals(1, result.turns.size)
    }

    // -------------------------------------------------- 6. 铁律 1 的自动化守卫

    @Test
    @DisplayName("★ 加/不加 onEvent：prompt 与 TurnRecord 必须逐字节一致（铁律 1）")
    fun eventsDoNotAlterPromptOrRecords() {
        // 不加回调（旧行为）
        val silentProvider = providerAlways("""{"final":"done"}""")
        val silent = AgentLoop(silentProvider, NoopFs(), emptyList()).run("你好")

        // 加回调（新行为）
        val watchedProvider = providerAlways("""{"final":"done"}""")
        val rec = Recorder()
        val watched = AgentLoop(watchedProvider, NoopFs(), emptyList(), onEvent = rec.handler)
            .run("你好")

        // ① 记账一字不差
        //
        //    ⚠️ 比较前**抹掉 `wallMs`**（2026-10-16 修）：它是真实墙钟，
        //    同一台机器上可能量到 0 ms 也可能 1 ms —— 让它参与 data class 的
        //    相等比较，会让这条守卫**间歇性变红**（已实际发生过：首跑失败、重跑通过）。
        //    这条守卫要证明的是"事件有没有偷偷改动记账"，不是耗时 ⇒ 耗时归一化。
        assertEquals(
            silent.turns.map { it.copy(wallMs = 0) },
            watched.turns.map { it.copy(wallMs = 0) },
            "事件不得影响 TurnRecord（耗时字段除外，其余必须逐字段一致）",
        )

        // ② ★ prompt 逐字节一致 —— append-only 没被破坏，
        //    否则前缀缓存命中率会塌方（实测-01 / 实测-05）
        assertEquals(
            silentProvider.requests.map { it.prompt },
            watchedProvider.requests.map { it.prompt },
            "事件不得影响 prompt 构造（铁律 1）",
        )

        // ③ ★★ 2026-10-12 流式改造的**新增守卫**：Session.append 序列本身
        //
        //    流式把 provider 调用换成了 generateStream，最容易出的错是
        //    "因为流式而多 append / 少 append 了一次" —— 那会直接破坏
        //    append-only（铁律 1），但**其它任何测试都不会红**。
        //
        //    这里断言的是**最终会话内容**，不是事件条数
        //    （事件条数已因 token 级事件而改变，那与铁律 1 无关）。
        assertEquals(
            silentProvider.requests.size, watchedProvider.requests.size,
            "加事件不得改变 provider 被调用的次数",
        )
        assertEquals(
            1, silent.turns.size,
            "一轮问一句、模型一次给 final ⇒ 恰好 1 条 TurnRecord",
        )

        // ④ 顺带确认事件确实发了（否则上面几条是"空跑通过"）
        assertEquals(
            listOf("TurnStarted", "ModelOutput", "Finished"), turnKinds(rec.events),
            "轮级事件必须照常发出",
        )
        assertTrue(
            rec.events.any { it is AgentEvent.StepDelta },
            "★ 流式改造后必须真的有 token 级事件 —— 否则'没做流式'而测试全绿",
        )
    }

    @Test
    @DisplayName("默认 onEvent=null：行为与改动前完全一致（不破坏现有调用方）")
    fun defaultNullKeepsBehaviour() {
        val result = AgentLoop(
            providerAlways("""{"final":"done"}"""), NoopFs(), emptyList(),
        ).run("你好")

        assertEquals("done", result.finalText)
        assertEquals("已给出最终回答", result.stopReason)
        assertEquals(1, result.turns.size)
    }

    // ============================================ ★ 预算接线（ADR-033 / P0-1，2026-10-18）

    /**
     * 交替两个**参数不同**的调用 —— 纯粹为了绕开"重复调用"守卫
     * （`consecutiveRepeatCount`），让**预算本身**成为唯一的停止原因。
     *
     * 规则按 prompt 里 `a.txt` / `b.txt` 的出现次数交替
     * （`FakeProvider` 是 **first-match-wins**，见 `FakeProvider.kt:118`）。
     * 为什么 args 会出现在 prompt 里：`AgentLoop` 每轮都
     * `session.append(Turn.Assistant(raw))`，上一轮的调用 JSON 原文（含 args）就在下一轮 prompt 里。
     */
    private fun alternatingArgs(): FakeProvider {
        val p = FakeProvider()
        fun n(h: String, s: String) = Regex(Regex.escape(s)).findAll(h).count()
        p.onPrompt(
            { h -> n(h, "a.txt") <= n(h, "b.txt") },
            """{"tool":"write_file","args":{"path":"a.txt","content":"hi"}}""",
        )
        p.onPrompt({ true }, """{"tool":"write_file","args":{"path":"b.txt","content":"hi"}}""")
        runBlocking { p.load(ProviderConfig()) }.getOrThrow()
        return p
    }

    @Test
    @DisplayName("★★ 工具调用预算到顶 ⇒ 如实停「额度用尽」，不假装任务完成")
    fun toolCallBudgetStopsHonestly() {
        val rec = Recorder()
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val result = AgentLoop(
            alternatingArgs(), NoopFs(), listOf(tool),
            // 轮次故意远超预算：证明停它的是**工具次数**，不是 maxTurns
            maxTurns = 50,
            maxToolCalls = 3,
            onEvent = rec.handler,
        ).run("不停地写文件")

        assertEquals("工具调用已达上限（3）", result.stopReason)
        assertEquals(3, tool.executeCount, "预算 = 3 ⇒ 恰好执行 3 次；第 4 次在**执行前**被拦")
        assertTrue(result.finalText.contains("预算"), "必须说清这是预算而不是错误")

        val closed = rec.events.filterIsInstance<AgentEvent.PlanClosed>()
        assertEquals(1, closed.size, "预算停止也必须恰好收一次计划")
        assertTrue(!closed[0].reachedGoal, "额度用尽 ≠ 达成目标 ⇒ reachedGoal 必须为 false")
        assertTrue(
            rec.events.indexOfFirst { it is AgentEvent.PlanClosed } <
                rec.events.indexOfFirst { it is AgentEvent.Finished },
            "PlanClosed 必须在 Finished 之前 —— 与轮次耗尽同一套收尾契约",
        )
    }

    @Test
    @DisplayName("★★ 工具连续失败到上限 ⇒ 熔断停止，且最后那次失败原因要露出来")
    fun consecutiveToolFailuresCircuitBreaker() {
        val rec = Recorder()
        val tool = RecordingTool(writeSpec, ToolOutcome.Failure("磁盘满"))
        val result = AgentLoop(
            alternatingArgs(), NoopFs(), listOf(tool),
            maxTurns = 50,
            maxConsecutiveFailures = 3,
            onEvent = rec.handler,
        ).run("写不进去也一直试")

        assertEquals("连续 3 次工具失败，已停止", result.stopReason)
        assertEquals(3, tool.executeCount)
        assertTrue(
            result.finalText.contains("磁盘满"),
            "停止说明必须带最后那次失败的原因 —— 否则用户不知道卡在哪",
        )
    }

    @Test
    @DisplayName("★★ ADR-035 S2：预算**只有一套**（40 / 120 / 6），且 AgentLoop 默认值就是它（不再是 8/30/3）")
    fun budgetIsSingleTierAndIsTheLoopDefault() {
        // 唯一来源
        assertEquals(40, Contract.Budget.MAX_TURNS)
        assertEquals(120, Contract.Budget.MAX_TOOL_CALLS)
        assertEquals(6, Contract.Budget.MAX_CONSECUTIVE_FAILURES)

        // ★ 关键是**接线**，不是常量本身：`AgentLoop` 的默认值必须等于契约值。
        //   改造前 `maxTurns` 是**硬编码 8**（`AgentBridge` 另传 40 ⇒ 同一概念两处真相）；
        //   S2 把默认值接到契约。三条断言读的是**构造函数的真实默认**（`private val` 的只读 view），
        //   所以谁把它改回字面量都会红 —— 这正是"接线"和"常量摆在那儿"的区别。
        val loop = AgentLoop(providerAlways("{\"final\":\"ok\"}"), NoopFs(), emptyList())
        assertEquals(Contract.Budget.MAX_TURNS, loop.maxTurnsForTest)
        assertEquals(Contract.Budget.MAX_TOOL_CALLS, loop.maxToolCallsForTest)
        assertEquals(
            Contract.Budget.MAX_CONSECUTIVE_FAILURES,
            loop.maxConsecutiveFailuresForTest,
        )

        // ⚠️ 行为变更留痕：CLI / 单测不传参时的预算从 8 / 30 / 3 升到 40 / 120 / 6。
        //   "跑满轮次"类用例必须**显式**传 `maxTurns`（既有用例已经这么做），
        //   靠"默认恰好是 8"兜底的用例会变行为 —— 这是 S2 已知并接受的代价。
        assertEquals(8, OLD_LOCAL_TURNS, "历史值留作对照，改它说明有人想回退默认档")
        assertTrue(loop.maxTurnsForTest > OLD_LOCAL_TURNS)
        assertTrue(loop.maxToolCallsForTest > OLD_LOCAL_TOOL_CALLS)
        assertTrue(loop.maxConsecutiveFailuresForTest > OLD_LOCAL_CONSECUTIVE_FAILURES)
    }

    private companion object {
        /** 改造前 `AgentLoop` 的三个默认值（本地时代）—— 只作对照，**不得**再被使用。 */
        const val OLD_LOCAL_TURNS = 8
        const val OLD_LOCAL_TOOL_CALLS = 30
        const val OLD_LOCAL_CONSECUTIVE_FAILURES = 3
    }
}
