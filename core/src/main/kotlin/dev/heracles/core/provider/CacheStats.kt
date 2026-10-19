package dev.heracles.core.provider

/**
 * 归一化缓存指标 —— `02-契约规范.md` §3.4（FR-11.6）。
 *
 * 后端可插拔后，不同 provider 的缓存字段名与语义都不同
 * （llama.cpp `timings.cache_n` / OpenAI `cached_tokens` /
 *   Anthropic `cache_read_input_tokens` / DeepSeek `prompt_cache_hit_tokens`）。
 *
 * **上层代码只允许看到本结构，不得直接读 provider 原始字段。**
 */
data class CacheStats(
    /**
     * 命中前缀缓存的输入 token。
     *
     * `null` 表示该 provider **未提供**此字段。
     * 严禁用 `0` 代替 —— 0 会被当成"命中率 0%"，
     * 从而误触 [dev.heracles.core.contract.Contract.Cache.HIT_RATE_ALERT] 告警。
     */
    val cachedTokens: Int?,

    /** 实际参与计算的输入 token（不含命中部分） */
    val promptTokens: Int,

    /** 输出 token */
    val outputTokens: Int,

    /** 无此概念的 provider 填 -1（例如云端只有总时延） */
    val prefillMs: Long = UNKNOWN_MS,

    val decodeMs: Long = UNKNOWN_MS,

    /** 本地后端恒为 0；云端按 provider 价目表计算 */
    val costUsdMicros: Long = 0,
) {
    /** 该 provider 是否上报了缓存字段 */
    val cacheReportingAvailable: Boolean get() = cachedTokens != null

    /**
     * 命中率。
     *
     * `null` = **不可用**（provider 未上报缓存字段），UI 必须显示"不可用"而不是 0。
     */
    val hitRate: Double?
        get() = cachedTokens?.let { cached ->
            val total = cached + promptTokens
            if (total > 0) cached.toDouble() / total else null
        }

    /** 输入 token 总量（命中 + 实算） */
    val totalInputTokens: Int get() = (cachedTokens ?: 0) + promptTokens

    companion object {
        const val UNKNOWN_MS = -1L

        /**
         * provider 未提供缓存字段时的降级构造。
         * 见 `02-契约规范.md` §3.4「降级规则」。
         */
        fun withoutCacheReporting(
            promptTokens: Int,
            outputTokens: Int,
            prefillMs: Long = UNKNOWN_MS,
            decodeMs: Long = UNKNOWN_MS,
            costUsdMicros: Long = 0,
        ) = CacheStats(
            cachedTokens = null,
            promptTokens = promptTokens,
            outputTokens = outputTokens,
            prefillMs = prefillMs,
            decodeMs = decodeMs,
            costUsdMicros = costUsdMicros,
        )
    }
}
