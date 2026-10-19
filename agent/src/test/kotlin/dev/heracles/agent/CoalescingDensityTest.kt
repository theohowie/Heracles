package dev.heracles.agent

import dev.heracles.core.contract.Contract
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **合并压缩比随 chunk 到达密度的关系** —— 把真机结论固化成回归锁。
 *
 * ## 为什么需要这个文件：真机实测的结论与直觉相反
 *
 * `coalesceProbe` 在真机上两次测出**压缩比 1.0×**（几乎没合并）。
 * 那不是合并算法没生效，而是**真机的 chunk 到达间隔远大于一帧**：
 *
 * ```
 * 真机实测（streamProbe）：
 *   chunk 总数     ：30
 *   块间隔中位数   ：6140 ms      ← ★ 不是 250 tok/s，而是每 6 秒一个 token
 * ```
 *
 * 本地模型在**页面缓存被挤压**时慢到每 token 数秒 —— 而 `AGENTS.md`
 * 早就记过这条（"内存 0.55 GB 就慢 10 倍"）。
 *
 * ## 结论（这条必须被记住，否则会反复"白修"）
 *
 * > **合并的压缩比 = 帧窗口 ÷ chunk 到达间隔**，
 * > **与算法实现无关**。间隔 ≥ 窗口时，压缩比**必然**≈1.0×。
 *
 * | 场景 | chunk 间隔 | 一帧内 chunk 数 | 压缩比 |
 * |---|---|---|---|
 * | 满载本地（约 250 tok/s） | ~4 ms | ~4 | **~4×** |
 * | 常规本地 | ~170 ms | <1 | **1.0×** |
 * | 内存受压（实测） | ~6,140 ms | ≪1 | **1.0×** |
 *
 * ⇒ **在慢机器上"没合并"是正常的**。真正该担心的不是压缩比数字，
 * 而是"间隔很小时是否**仍**合并" —— 那才是算法正确性。
 * 本文件的用例就是钉这一条。
 */
class CoalescingDensityTest {

    /** 跑一段模拟的 chunk 流，返回（原始 chunk 数, 实际推出的事件数） */
    private fun simulate(intervalMs: Long, chunkCount: Int): Pair<Int, Int> {
        val c = StreamCoalescer()
        c.startStep("turn-1", 0)
        var pushed = 0
        repeat(chunkCount) { i ->
            pushed += c.append("字", "", i * intervalMs).size
        }
        pushed += c.endStep("ok", 0, "", 1).size
        return chunkCount to pushed
    }

    @Test
    @DisplayName("★ 满载本地（~250 tok/s，间隔 4ms）⇒ 压缩比 ≈4×")
    fun fastModelCompresses() {
        val (raw, pushed) = simulate(intervalMs = 4, chunkCount = 1000)

        val ratio = raw.toDouble() / pushed
        assertTrue(
            ratio >= 3.0,
            "★ 满载本地必须真的合并（间隔 4ms < 帧窗口 16ms）。" +
                "实际压缩比 ${"%.1f".format(ratio)}×（原始 $raw → $pushed）",
        )
        // 理论上限：一帧 16ms 能装 4 个 chunk
        assertTrue(ratio <= 6.0, "压缩比不该超过理论值太多，实际 ${"%.1f".format(ratio)}×")
    }

    @Test
    @DisplayName("★ 如实：常规本地（间隔 170ms）⇒ 压缩比 ≈1.0×，这是物理限制")
    fun normalModelDoesNotCompress() {
        val (raw, pushed) = simulate(intervalMs = 170, chunkCount = 100)

        val ratio = raw.toDouble() / pushed
        assertTrue(
            ratio < 1.2,
            "★ 间隔 170ms > 帧窗口 16ms ⇒ 一帧内只有一个 chunk，无从合并。" +
                "实际 ${"%.1f".format(ratio)}× —— 若这里压缩比很高，说明实现有假",
        )
    }

    @Test
    @DisplayName("★ 真机复现：间隔 6140ms（内存受压）⇒ 压缩比 1.0×，且不得丢字")
    fun memoryStarvedMachineMatchesRealMeasurement() {
        val (raw, pushed) = simulate(intervalMs = 6_140, chunkCount = 30)

        // 真机实测就是 30 chunk → 30 条
        assertTrue(
            pushed in raw - 2..raw,
            "★ 复现真机结论：30 个 chunk 应产出约 30 条事件，实际 $pushed 条",
        )
    }

    @Test
    @DisplayName("★ 任何密度下都不得丢字（压缩比会变，内容不会变）")
    fun neverLosesCharsAtAnyDensity() {
        listOf(1L, 4L, 16L, 170L, 6_140L).forEach { interval ->
            val c = StreamCoalescer()
            c.startStep("turn-1", 0)
            val total = 200
            var collected = StringBuilder()
            repeat(total) { i ->
                c.append("字", "", i * interval).forEach { e ->
                    if (e is AgentEvent.StepDelta) collected.append(e.delta)
                }
            }
            c.endStep("ok", 0, "", 1).forEach { e ->
                if (e is AgentEvent.StepDelta) collected.append(e.delta)
            }

            assertEquals(
                "字".repeat(total), collected.toString(),
                "★ 间隔 ${interval}ms 下丢字了 —— 合并可以改条数，绝不能改内容",
            )
        }
    }

    @Test
    @DisplayName("★ 帧窗口的语义：一帧内**不超过保险丝**时一条都不推")
    fun oneFrameAtMostOneEventPerTrack() {
        val c = StreamCoalescer()
        c.startStep("turn-1", 0)

        // 同一帧内塞 40 个 chunk（**低于保险丝 48**）⇒ 应当全攒着
        var pushed = 0
        repeat(40) { pushed += c.append("字", "", 0).size }

        assertEquals(
            0, pushed,
            "★ 同一帧内（且未超保险丝）塞再多也只攒着 —— 这就是压缩比的来源",
        )
        assertEquals(40, c.pendingChars)
    }

    @Test
    @DisplayName("★ 保险丝是【保险】：同一帧内超限就提前泄洪（宁可多推不可积压）")
    fun fuseReleasesWhenOversizedInOneFrame() {
        val c = StreamCoalescer()
        c.startStep("turn-1", 0)

        // 同一帧内塞 100 个字符 ⇒ 超过保险丝 48，必须提前泄洪
        var pushed = 0
        repeat(100) { pushed += c.append("字", "", 0).size }

        assertTrue(
            pushed >= 1,
            "★ 保险丝必须跳闸 —— 否则一帧内会攒出巨型事件，处理它本身就掉帧",
        )
        // 而且应当是保险丝的整数倍级别，不是 100 条
        assertTrue(pushed <= 5, "泄洪也应当成块（约 $100/48 ≈ 2 块），实际 $pushed 条")
    }

    @Test
    @DisplayName("契约值自洽：帧窗口 16ms、保险丝 48 字符")
    fun contractValuesAreSane() {
        assertEquals(16L, Contract.Stream.FLUSH_INTERVAL_MS, "16ms = 一帧（60fps）")
        assertTrue(
            Contract.Stream.FLUSH_MIN_CHARS > 0,
            "保险丝必须为正，否则每字符一推",
        )
        // 保险丝在正常语速下不应频繁触发：一帧 16ms、满载 4ms/chunk ⇒ 一帧 4 字符
        assertTrue(
            Contract.Stream.FLUSH_MIN_CHARS > 4 * 4,
            "★ 保险丝必须远大于「一帧能攒的字符数」，否则它就会变成主要触发条件" +
                "（那正是压缩比退化到 2.0× 的原因）",
        )
    }
}
