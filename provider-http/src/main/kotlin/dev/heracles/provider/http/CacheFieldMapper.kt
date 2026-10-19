package dev.heracles.provider.http

import com.google.gson.JsonObject
import dev.heracles.core.provider.CacheStats

/**
 * 把各家 provider 的缓存字段映射到统一的 [CacheStats] —— `02-契约规范.md` §3.4。
 *
 * ## 为什么必须集中在一处
 *
 * | Provider | 命中字段 | 未命中字段 |
 * |---|---|---|
 * | llama.cpp | `timings.cache_n` | `timings.prompt_n` |
 * | OpenAI 兼容 | `usage.prompt_tokens_details.cached_tokens` | `usage.prompt_tokens` |
 * | DeepSeek | `usage.prompt_cache_hit_tokens` | `usage.prompt_cache_miss_tokens` |
 * | Anthropic | `usage.cache_read_input_tokens` | `usage.input_tokens` |
 *
 * 分散在各 provider 里就地读，会导致：
 * 1. 同一个字段被两个地方用不同方式解释
 * 2. "未上报时降级为 null"这条规则被漏掉，于是被填成 0
 *    → **误触命中率告警**，让人去排查一个不存在的问题（§3.4 降级规则）
 */
internal object CacheFieldMapper {

    /**
     * OpenAI 兼容格式（`usage.prompt_tokens_details.cached_tokens`）。
     *
     * 这是 DashScope / DeepSeek / Kimi / 智谱等**多数国内厂商**的格式。
     */
    fun fromOpenAiUsage(usage: JsonObject?): CacheStats {
        if (usage == null) return CacheStats.withoutCacheReporting(0, 0)

        val promptTokens = usage.intOr("prompt_tokens")
        val outputTokens = usage.intOr("completion_tokens")

        val cached = usage.getAsJsonObject("prompt_tokens_details")
            ?.takeIf { it.has("cached_tokens") }
            ?.get("cached_tokens")?.asInt

        // 命中部分已包含在 prompt_tokens 里 → 实算量要减掉
        val computed = if (cached != null) (promptTokens - cached).coerceAtLeast(0) else promptTokens

        return CacheStats(
            cachedTokens = cached,
            promptTokens = computed,
            outputTokens = outputTokens,
        )
    }

    /**
     * DeepSeek 原生格式（`prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`）。
     *
     * 与 OpenAI 格式的关键差别：这里的两个字段是**分开上报**的，
     * 命中数**不包含**在 prompt_tokens 里。
     */
    fun fromDeepSeekUsage(usage: JsonObject?): CacheStats {
        if (usage == null) return CacheStats.withoutCacheReporting(0, 0)

        val hit = usage.intOr("prompt_cache_hit_tokens").takeIf { usage.has("prompt_cache_hit_tokens") }
        val miss = usage.intOr("prompt_cache_miss_tokens")
        val promptTokens = if (miss > 0) miss else usage.intOr("prompt_tokens")
        val outputTokens = usage.intOr("completion_tokens")

        return CacheStats(
            cachedTokens = hit,
            promptTokens = promptTokens,
            outputTokens = outputTokens,
        )
    }

    /**
     * 自动选择：先试 DeepSeek 原生字段，再试 OpenAI 兼容字段。
     *
     * 顺序很重要 —— DeepSeek 的响应里**同时**有 `prompt_tokens` 和
     * `prompt_cache_hit_tokens`，若先用 OpenAI 分支会拿到 0（因为它找的是
     * `prompt_tokens_details.cached_tokens`，DeepSeek 不提供）。
     */
    fun auto(usage: JsonObject?): CacheStats {
        if (usage == null) return CacheStats.withoutCacheReporting(0, 0)
        return if (usage.has("prompt_cache_hit_tokens")) {
            fromDeepSeekUsage(usage)
        } else {
            fromOpenAiUsage(usage)
        }
    }

    private fun JsonObject.intOr(key: String): Int =
        if (has(key) && !get(key).isJsonNull) get(key).asInt else 0
}
