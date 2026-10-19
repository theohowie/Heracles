package dev.heracles.agent

import dev.heracles.core.contract.Contract
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **批量合并器的正确性守卫** —— `25-流式工作步骤.md` §5.4。
 *
 * ## 为什么这个类值得一整套测试
 *
 * 合并是**用户看不到但一旦错了就致命**的一层：
 *
 * | 缺陷 | 用户看到 | 有无别的测试会红 |
 * |---|---|---|
 * | 丢字（flush 时没清空/清早了） | 文字缺一块，**无任何报错** | ❌ 没有 |
 * | 重复（清空后又 flush 一次旧缓冲） | 同一段字出现两遍 | ❌ 没有 |
 * | 乱序 | 文字前后颠倒 | ❌ 没有 |
 * | **跨轨合并**（思考进正文） | 分不清"想法"与"答案" | ❌ 没有 |
 * | StepEnded 被自己的 delta 挡在后面 | UI 永远"生成中" | ❌ 没有 |
 *
 * **五条全部是静默的** —— 没有异常、没有日志、类型系统也管不着。
 * 只能靠断言。这正是本文件的存在理由。
 *
 * ## 为什么不 sleep
 *
 * 时间通过参数**注入**（`nowMs`），所以测试是完全确定的：
 * 不依赖真实时钟、不会 flaky、毫秒级跑完。
 */
class StreamCoalescerTest {

    /**
     * 测试用的固定阈值（与契约默认值解耦，契约改了不该让用例变红）。
     *
     * `frameMs` 默认给一个**较大**的值，这样单字符 `append` 不会意外触发
     * 帧节流 —— 需要测节流的用例显式传小值。
     */
    private fun coalescer(maxChars: Int = 10, frameMs: Long = 1_000_000) =
        StreamCoalescer(maxChars = maxChars, frameMs = frameMs)

    /** 把所有事件里某条轨道的内容拼起来 —— 用于验证"不丢字" */
    private fun joinedText(events: List<AgentEvent>): String =
        events.filterIsInstance<AgentEvent.StepDelta>().joinToString("") { it.delta }

    private fun joinedReasoning(events: List<AgentEvent>): String =
        events.filterIsInstance<AgentEvent.ReasoningDelta>().joinToString("") { it.delta }

    // ------------------------------------------------------- 不变量 1：不丢字

    @Test
    @DisplayName("★ 不丢字：攒着的内容在 flushAll 后必须全部出现")
    fun neverLosesChars() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)

        // 每块都很小，且不调 flushFrame ⇒ 全部攒在缓冲里
        val events = mutableListOf<AgentEvent>()
        listOf("你", "好", "世", "界").forEach { events += c.append(it, "", 0) }

        assertTrue(events.isEmpty(), "保险丝没到不该推任何东西")

        // 步骤结束时必须全部推出
        events += c.endStep("ok", 5, "你好世界", 1)
        assertEquals("你好世界", joinedText(events), "★ 尾部残留绝不能丢")
    }

    @Test
    @DisplayName("★ 不丢字：逐字符喂入 100 字，拼接必须一字不差")
    fun charByCharNeverLoses() {
        val c = coalescer(maxChars = 7)
        c.startStep("turn-1", 0)

        val source = "我需要先查看一下这个文件的内容，然后决定怎么改。"
        val events = mutableListOf<AgentEvent>()
        source.forEachIndexed { i, ch ->
            events += c.append(ch.toString(), "", (i * 3).toLong())
            // 模拟帧节拍：每 5 个字符来一帧
            if (i % 5 == 4) events += c.flushFrame((i * 3).toLong())
        }
        events += c.endStep("ok", 1, source, 1)

        assertEquals(source, joinedText(events), "逐字符喂入后必须能完整还原")
    }

    @Test
    @DisplayName("★ 不丢字：正文与思考各自的残留都能保住")
    fun neverLosesEitherTrack() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)

        val events = mutableListOf<AgentEvent>()
        events += c.append("答案", "思考", 0)
        events += c.endStep("ok", 1, "答案", 1)

        assertEquals("答案", joinedText(events), "正文残留不得丢")
        assertEquals("思考", joinedReasoning(events), "思考残留不得丢")
    }

    // ------------------------------------------------------- 不变量 2：不重复

    @Test
    @DisplayName("★ 不重复：flush 过的内容不得再出现一次")
    fun neverDuplicates() {
        val c = coalescer(maxChars = 4)
        c.startStep("turn-1", 0)

        val events = mutableListOf<AgentEvent>()
        events += c.append("abcd", "", 0)   // 触发保险丝 → 推出
        events += c.append("ef", "", 1)     // 攒着
        events += c.endStep("ok", 1, "abcdef", 1)

        assertEquals("abcdef", joinedText(events), "★ 重复会让同一段字出现两遍")
        assertEquals(
            4, events.filterIsInstance<AgentEvent.StepDelta>().first().delta.length,
            "第一次 flush 应当只含已攒的 4 字",
        )
    }

    @Test
    @DisplayName("★ 不重复：flushAll 连调两次，第二次必须是空的")
    fun flushAllIsIdempotent() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)
        c.append("内容", "", 0)

        val first = c.flushAll()
        val second = c.flushAll()

        assertEquals(1, first.size)
        assertTrue(second.isEmpty(), "★ 第二次 flushAll 必须为空（否则 = 重复推送）")
        assertEquals(0, c.pendingChars)
    }

    // ------------------------------------------------------- 不变量 3：不跨轨

    @Test
    @DisplayName("★★ 不跨轨合并：思考与正文永不进同一个事件")
    fun neverMergesTracks() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)

        val events = mutableListOf<AgentEvent>()
        events += c.append("正文内容", "思考内容", 0)
        events += c.endStep("ok", 1, "正文内容", 1)

        // 任一事件里都不得同时含两类内容
        events.forEach { e ->
            when (e) {
                is AgentEvent.StepDelta -> assertTrue(
                    !e.delta.contains("思考"),
                    "★ 思考混进正文 = 用户永远分不清'想法'与'答案'（25 §2 错误一）",
                )
                is AgentEvent.ReasoningDelta -> assertTrue(
                    !e.delta.contains("正文"),
                    "★ 正文混进思考",
                )
                else -> Unit
            }
        }
        assertEquals("正文内容", joinedText(events))
        assertEquals("思考内容", joinedReasoning(events))
    }

    @Test
    @DisplayName("思考与正文各自独立 flush（一条轨道不缺内容也不会带出另一条）")
    fun tracksFlushIndependently() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)

        // 只有思考有内容
        c.append("", "思考", 0)
        val frame1 = c.flushFrame(0)
        assertEquals(1, frame1.size, "只有思考就只推思考")
        assertTrue(frame1[0] is AgentEvent.ReasoningDelta)

        // 只有正文有内容
        c.append("正文", "", 0)
        val frame2 = c.flushFrame(16)
        assertEquals(1, frame2.size, "只有正文就只推正文")
        assertTrue(frame2[0] is AgentEvent.StepDelta)
    }

    @Test
    @DisplayName("★ 两条轨道在同一帧内都有内容 ⇒ 推两条事件（不合并成一个）")
    fun bothTracksInOneFrameGiveTwoEvents() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)

        c.append("正文", "思考", 0)
        val frame = c.flushFrame(0)

        assertEquals(2, frame.size, "★ 思考与正文必须各推各的 —— 合并 = 用户分不清想法与答案")
        assertEquals(1, frame.count { it is AgentEvent.StepDelta })
        assertEquals(1, frame.count { it is AgentEvent.ReasoningDelta })
    }

    // ------------------------------------------------------- 不变量 4：结构性事件直通

    @Test
    @DisplayName("★ StepStarted 不得被缓冲推迟（UI 要立刻知道新步骤开始）")
    fun stepStartedGoesOutImmediately() {
        val c = coalescer(maxChars = 1000)
        val events = c.startStep("turn-1", 0)

        assertEquals(1, events.size)
        assertTrue(events[0] is AgentEvent.StepStarted, "StepStarted 必须立刻直通")
        assertEquals("turn-1", (events[0] as AgentEvent.StepStarted).stepId)
    }

    @Test
    @DisplayName("★★ StepEnded 必须排在它自己的 delta 之后，且是最后一个")
    fun stepEndedComesAfterItsOwnDeltas() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)
        c.append("还没推出", "", 0)

        val events = c.endStep("ok", 7, "还没推出", 3)

        assertEquals(2, events.size)
        assertTrue(events[0] is AgentEvent.StepDelta, "尾部残留必须先出")
        assertTrue(
            events[1] is AgentEvent.StepEnded,
            "★ StepEnded 被自己的 delta 挡在后面 = UI 永远'生成中'",
        )
        val ended = events[1] as AgentEvent.StepEnded
        assertEquals("ok", ended.status)
        assertEquals(7, ended.durationMs)
        assertEquals("还没推出", ended.summary)
    }

    @Test
    @DisplayName("StepEnded 的三态：ok / empty / error 是可区分的字符串")
    fun stepEndedStatuses() {
        assertEquals("ok", AgentEvent.StepEnded.STATUS_OK)
        assertEquals("empty", AgentEvent.StepEnded.STATUS_EMPTY)
        assertEquals("error", AgentEvent.StepEnded.STATUS_ERROR)
        assertTrue(
            setOf(
                AgentEvent.StepEnded.STATUS_OK,
                AgentEvent.StepEnded.STATUS_EMPTY,
                AgentEvent.StepEnded.STATUS_ERROR,
            ).size == 3,
            "三态必须互不相同 —— 用布尔会把'空响应'误报成'失败'",
        )
    }

    // ------------------------------------------------------- ★ 帧节流（核心机制）

    /**
     * ★★ **压缩比的支配者是帧节流** —— 这是真机花两次实测买来的结论。
     *
     * `coalesceProbe` 实测：
     * - "时间或字符取先到者" ⇒ **2.0×**（被字符支配）
     * - "只在 chunk 到达时判帧" ⇒ **1.0×**（chunk 间隔 ~660ms > 16ms，每个 chunk 各推一次）
     *
     * 若有人把节流改成上述任一种，这个测试会立刻红。
     */
    @Test
    @DisplayName("★★ 帧节流：一帧窗口内来多少 chunk 都只推一条")
    fun frameThrottleBatchesWithinWindow() {
        val c = coalescer(maxChars = 10_000, frameMs = 16)
        c.startStep("turn-1", 0)

        // 同一个 16ms 窗口内塞 100 个 chunk
        var count = 0
        repeat(100) { count += c.append("字", "", 0).size }

        assertEquals(0, count, "★ 窗口没到 ⇒ 一条都不该推（内容留在缓冲里）")
        assertEquals(100, c.pendingChars, "内容必须攒着，不能丢")

        // 窗口到了 ⇒ 推出本帧累积的**全部**内容
        val frame = c.flushFrame(16)
        assertEquals(1, frame.size, "★ 一帧只推一条 —— 这就是压缩比的来源")
        assertEquals(100, (frame[0] as AgentEvent.StepDelta).delta.length, "但内容必须完整")
    }

    /**
     * ★★ **回归锁**：chunk 密集到达时必须真的合并。
     *
     * 第二次真机实测失败的场景是"chunk 间隔 ~660 ms"——那时**没有东西可合并**
     * （每个间隔本来就比一帧长）。所以要守住的是**另一种**情形：
     * chunk **密集**到达（间隔 < 帧窗口）时，绝不允许每个 chunk 各推一次。
     *
     * 这两者是不同的问题，混淆会得出错误结论：
     *
     * | chunk 间隔 vs 帧窗口 | 能否合并 | 压缩比 |
     * |---|---|---|
     * | 间隔 ≪ 窗口（本地快模型：250 tok/s ⇒ ~4 ms） | ✅ 能 | 高（≈10×） |
     * | 间隔 ≫ 窗口（慢/长思考：~660 ms） | ❌ **无东西可合并** | **≈1.0×（正常）** |
     *
     * ⇒ **压缩比取决于 chunk 到达密度，不是算法好坏。**
     * 本地 250 tok/s 时每 4 ms 一个 chunk，一帧能攒 4 个 ⇒ 压缩比 ≈4×；
     * 若模型慢到每 660 ms 一个 token，压缩比必然 ≈1×。
     */
    @Test
    @DisplayName("★★ 回归锁：密集 chunk（间隔 < 帧窗口）必须合并")
    fun denseChunksCoalesce() {
        val c = coalescer(maxChars = 10_000, frameMs = 16)
        c.startStep("turn-1", 0)

        // 模拟 250 tok/s：每 4 ms 一个字符
        var count = 0
        var pushedChars = 0
        repeat(100) { i ->
            val evts = c.append("字", "", i * 4L)
            count += evts.size
            pushedChars += evts.filterIsInstance<AgentEvent.StepDelta>().sumOf { it.delta.length }
        }

        // 100 个 chunk 跨 0..396 ms ⇒ 约 24 个帧窗口。若每个 chunk 各推一次就是 100 条
        assertTrue(
            count <= 30,
            "★★ 密集 chunk 必须合并到帧数级别 —— 100 个 chunk 应只推约 24 条，实际 $count 条",
        )
        assertTrue(count >= 10, "也不能一条都不推（那就不是流式了），实际 $count 条")
        assertEquals(
            100, pushedChars + c.pendingChars,
            "★ 不丢字：已推的 + 攒着的 = 总字数",
        )
    }

    /**
     * ★ **如实记录一条限制**：chunk 间隔大于帧窗口时，**无法**合并。
     *
     * 这不是 bug —— 中间根本没有可以合并的内容
     * （一帧之内只来了 1 个 chunk，攒它没有意义，反而增加延迟）。
     *
     * 写出来是为了防止后来人误以为"压缩比低 = 合并没生效"。
     */
    @Test
    @DisplayName("★ 如实：chunk 间隔 > 帧窗口时压缩比必然 ≈1.0×（无东西可合并）")
    fun sparseChunksCannotBeCompressed() {
        val c = coalescer(maxChars = 10_000, frameMs = 16)
        c.startStep("turn-1", 0)

        // 每 660 ms 一个字符（真机慢速场景）
        var count = 0
        repeat(20) { i -> count += c.append("字", "", i * 660L).size }

        // 第 1 个 chunk 在 t=0 时 lastFlushMs 刚被 startStep 设为 0 ⇒ 不推；
        // 它被下一个 chunk（t=660）顺带推出，所以每两个 chunk 之间推一次 ⇒ 19 条
        assertEquals(
            19, count,
            "★ 间隔 > 窗口 ⇒ 每个 chunk 各成一帧，压缩比 ≈1.0×。" +
                "这是【物理限制】不是缺陷 —— 没有可合并的内容",
        )
        assertEquals(0, c.pendingChars, "最后一个 chunk 已随帧推出，缓冲为空")
    }

    @Test
    @DisplayName("★ 事件数随**时间**增长，不随 chunk 数增长")
    fun eventCountFollowsTimeNotChunkCount() {
        val c = coalescer(maxChars = 10_000, frameMs = 16)
        c.startStep("turn-1", 0)

        var count = 0
        // 1000 个 chunk 分布在 160 ms 内（= 10 帧）
        repeat(1000) { i ->
            count += c.append("x", "", (i * 160L / 1000)).size
        }
        count += c.endStep("ok", 1, "", 1).size

        assertTrue(
            count <= 15,
            "★ 1000 个 chunk 在 10 帧里应只产出约 10 条事件，实际 $count 条",
        )
        assertTrue(count >= 5, "但也不能一条都不推（那样就不是流式了），实际 $count 条")
    }

    @Test
    @DisplayName("★ flushFrame 无条件推出（流结束时清空最后一批）")
    fun flushFrameIsUnconditional() {
        val c = coalescer(maxChars = 10_000, frameMs = 1_000_000)
        c.startStep("turn-1", 0)
        c.append("最后一小段", "", 0)

        val events = c.flushFrame(1)
        assertEquals(1, events.size, "★ flushFrame 不看阈值，无条件推")
        assertEquals("最后一小段", (events[0] as AgentEvent.StepDelta).delta)
    }

    @Test
    @DisplayName("★ 字符保险丝：单次攒太多时提前泄洪（防巨型事件）")
    fun oversizedFuseTriggers() {
        val c = coalescer(maxChars = 5)
        c.startStep("turn-1", 0)

        val before = c.append("1234", "", 0)
        assertTrue(before.isEmpty(), "差 1 个字符，保险丝不该跳")

        val at = c.append("5", "", 1)
        assertEquals(1, at.size, "★ 达到保险丝就提前泄洪")
        assertEquals("12345", (at[0] as AgentEvent.StepDelta).delta)
    }

    @Test
    @DisplayName("帧到了但缓冲为空 ⇒ 不产生空事件")
    fun emptyFrameProducesNothing() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)

        assertEquals(0, c.flushFrame(16).size)
        assertEquals(0, c.flushFrame(32).size)
    }

    @Test
    @DisplayName("空增量不产生事件（心跳块不得渲染成空行）")
    fun emptyDeltasProduceNothing() {
        val c = coalescer(maxChars = 1)
        c.startStep("turn-1", 0)

        assertEquals(0, c.append("", "", 0).size)
        assertEquals(0, c.append("", "", 100).size)
        assertEquals(0, c.flushFrame(1000).size)
    }

    // ------------------------------------------------------- 多步骤

    @Test
    @DisplayName("★ 换步骤必须清空缓冲（否则上一轮的尾巴串到下一轮）")
    fun startStepClearsPendingFromPreviousStep() {
        val c = coalescer(maxChars = 1000)
        c.startStep("turn-1", 0)
        c.append("第一轮的尾巴", "", 0)

        val events = c.startStep("turn-2", 10)

        // 上一轮的残留必须**先推出**（不能丢），再发新步骤的 StepStarted
        val text = joinedText(events)
        assertEquals("第一轮的尾巴", text, "★ 上一轮残留丢失 = 用户看到的内容不完整")

        val started = events.filterIsInstance<AgentEvent.StepStarted>().single()
        assertEquals("turn-2", started.stepId)
        assertTrue(
            events.indexOfFirst { it is AgentEvent.StepDelta } <
                events.indexOfFirst { it is AgentEvent.StepStarted },
            "旧残留必须排在 StepStarted 之前（否则 UI 会把它归到新步骤上）",
        )
    }

    @Test
    @DisplayName("增量事件都带正确的 stepId（多轮时不能串卡片）")
    fun eventsCarryStepId() {
        val c = coalescer(maxChars = 1)
        c.startStep("turn-7", 0)

        val events = c.append("内容", "", 0)
        val delta = events.filterIsInstance<AgentEvent.StepDelta>().single()
        assertEquals("turn-7", delta.stepId, "★ 没有 stepId 就无法归属到正确的步骤卡片")
    }

    // ------------------------------------------------------- 契约默认值

    @Test
    @DisplayName("默认构造用契约值（保险丝 48 字符）")
    fun defaultsComeFromContract() {
        val c = StreamCoalescer()
        c.startStep("turn-1", 0)
        // 47 字符不该推（保险丝未到），48 该推
        assertEquals(0, c.append("x".repeat(Contract.Stream.FLUSH_MIN_CHARS - 1), "", 0).size)
        assertEquals(1, c.append("x", "", 0).size)
    }
}
