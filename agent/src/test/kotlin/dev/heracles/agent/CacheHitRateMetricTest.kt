package dev.heracles.agent

import dev.heracles.core.provider.CacheStats
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **缓存命中率的两种口径**（2026-10-19）。
 *
 * ## 为什么必须同时有两条断言
 *
 * 云端实测（`docs/实测-L1缓存复测-2026-10-19.md`）发现真实的指标陷阱：
 * 同一份数据，**轮次平均 90.8%** 而 **token 加权只有 84.6%**。
 * 原因是低命中的轮次恰好是 prompt 最大的轮次（首轮冻结前缀、压缩后重建）。
 *
 * ⇒ 只报轮次平均会让人以为"已经达标了"，而账单是按 token 走的。
 * 这两条断言把"两个数必须都能算出来、且允许不相等"钉死。
 */
class CacheHitRateMetricTest {

    private fun turn(cached: Int?, prompt: Int, out: Int = 10) = TurnRecord(
        index = 0,
        userText = "q",
        rawOutput = "",
        toolCall = null,
        toolResult = null,
        verdict = "",
        cache = CacheStats(cachedTokens = cached, promptTokens = prompt, outputTokens = out),
        wallMs = 0,
    )

    private fun result(vararg turns: TurnRecord) =
        AgentRunResult(turns.toList(), finalText = "", stopReason = "done")

    @Test
    @DisplayName("★★ 大轮 miss 会拉低加权命中率、却几乎不影响轮次平均（这就是陷阱）")
    fun weightedExposesBigMisses() {
        val r = result(
            turn(0, 1000),      // 首轮：冷启动，被两种口径都跳过
            turn(300, 300),     // 50% —— 但只有 600 token
            turn(300, 300),     // 50% —— 600
            turn(5000, 5000),   // 50% —— 却有一万
        )
        // 轮次平均：(0.5 + 0.5 + 0.5) / 3 = 0.5
        assertEquals(0.5, r.steadyHitRate!!, 1e-9)
        // token 加权：(300+300+5000) / (600+600+10000) —— 大轮主导
        assertEquals(5600.0 / 11200.0, r.steadyWeightedHitRate!!, 1e-9)
    }

    @Test
    @DisplayName("★★ 真实场景：平均 90.8% 但加权仅 84.6%（复刻本轮实测数据）")
    fun reproducesMeasuredDivergence() {
        // 数据取自 s1792340628214 的四轮 + 一个低命中大轮（s1792024078870 t1）
        val r = result(
            turn(9472, 1247),    // 首轮（被跳过）
            turn(12928, 370),
            turn(13056, 821),
            turn(9728, 262),
            turn(9600, 300),
            turn(22912, 10701),  // 低命中但吃 token
        )
        val avg = r.steadyHitRate!!
        val weighted = r.steadyWeightedHitRate!!
        assertTrue(avg > 0.88, "轮次平均应当很好看：$avg")
        assertTrue(weighted < avg, "加权必须低于平均（大 miss 在这里显露）")
        assertTrue(
            avg - weighted > 0.02,
            "两者差距必须被算出来，而不是被平均掩盖：avg=$avg weighted=$weighted",
        )
    }

    @Test
    @DisplayName("★ provider 不上报缓存字段 ⇒ 两个口径都必须是 null（不是 0）")
    fun unavailableStaysNull() {
        val r = result(
            turn(null, 100),
            turn(null, 200),
        )
        assertNull(r.steadyHitRate)
        assertNull(r.steadyWeightedHitRate)
    }

    @Test
    @DisplayName("★ 只有一轮（全是冷启动）⇒ 稳态口径为 null，不是 0")
    fun singleTurnHasNoSteadyRate() {
        val r = result(turn(500, 500))
        assertNull(r.steadyHitRate)
        assertNull(r.steadyWeightedHitRate)
    }
}
