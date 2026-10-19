package dev.heracles.core.provider

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * 缓存指标归一化 —— `02-契约规范.md` §3.4（FR-11.6）。
 *
 * 防的是什么：拿不到缓存字段的 provider 被填成 0，
 * 于是"命中率 0%"持续 3 轮触发告警，用户被误导去排查一个不存在的问题。
 */
class CacheStatsTest {

    @Test
    @DisplayName("provider 未上报缓存字段时 hitRate 必须是 null，而不是 0")
    fun unavailableIsNullNotZero() {
        val s = CacheStats.withoutCacheReporting(promptTokens = 1000, outputTokens = 50)
        assertFalse(s.cacheReportingAvailable)
        assertNull(s.hitRate, "用 0 代替『不可用』会误触命中率告警（02-契约规范.md §3.4）")
    }

    @Test
    @DisplayName("正常命中率计算")
    fun hitRateComputed() {
        val s = CacheStats(cachedTokens = 900, promptTokens = 100, outputTokens = 20)
        assertTrue(s.cacheReportingAvailable)
        assertEquals(0.9, s.hitRate!!, 1e-9)
        assertEquals(1000, s.totalInputTokens)
    }

    @Test
    @DisplayName("append-only 稳态：命中率远高于 90% 目标")
    fun appendOnlySteadyState() {
        // 实测-01 §4.2 的真实数字
        val s = CacheStats(cachedTokens = 677, promptTokens = 24, outputTokens = 25)
        assertEquals(0.9657, s.hitRate!!, 0.001)
        assertTrue(s.hitRate!! > 0.90)
    }

    @Test
    @DisplayName("分支场景：命中率塌到 24% 左右，应触发告警线")
    fun branchScenario() {
        // 实测-01 §4.1 的真实数字
        val s = CacheStats(cachedTokens = 168, promptTokens = 516, outputTokens = 25)
        assertEquals(0.2456, s.hitRate!!, 0.001)
        assertTrue(s.hitRate!! < 0.70, "分支场景必须低于告警线，否则告警形同虚设")
    }

    @Test
    @DisplayName("零 token 不产生 NaN")
    fun zeroTokensNoNaN() {
        assertNull(CacheStats(cachedTokens = 0, promptTokens = 0, outputTokens = 0).hitRate)
    }

    @Test
    @DisplayName("本地后端成本恒为 0，未知时延用 -1 而非 0")
    fun localDefaults() {
        val s = CacheStats(cachedTokens = 100, promptTokens = 10, outputTokens = 5)
        assertEquals(0L, s.costUsdMicros)
        assertEquals(CacheStats.UNKNOWN_MS, s.prefillMs)
        assertEquals(CacheStats.UNKNOWN_MS, s.decodeMs)
    }
}
