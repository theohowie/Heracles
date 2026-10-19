package dev.heracles.core.context

import dev.heracles.core.text.TextMath

/**
 * 冻结区**块对齐** —— 云端缓存的关键优化（`实测-07`）。
 *
 * ## 为什么需要这个
 *
 * `实测-07` 发现：**DashScope 的前缀缓存按 1024 token 块对齐**。
 * 命中数恒为 1024 的整数倍，而前缀实际约 783 token。
 *
 * 后果：
 *
 * | 冻结区长度 | 能命中的块 | 浪费 |
 * |---|---|---|
 * | 513 | **0** | 整个冻结区每轮全价重算 |
 * | 1024 | 1 | 满 |
 * | 1100 | 1 | 最后 76 token 每轮重算 |
 * | 2048 | 2 | 满 |
 *
 * **当前实测就踩了这个坑**：冻结区 513 token → **命中 0**，
 * 5 轮全部 0.0%（见 `实测-08`）。
 *
 * ## 做法
 *
 * 用**无意义但确定**的填充把冻结区补到块边界的**略上方**，
 * 而不是略下方 —— 因为 token 估算有误差，宁可超出一点。
 *
 * > **为什么不直接砍到 1024？**
 * > 砍会丢失真实的工具描述，损害模型能力。
 * > 补只是多花一点 token（1 块约 1024 token 的输入成本），
 * > 换来**整块命中**，净赚。
 *
 * ## 确定性
 *
 * 填充内容**必须逐字节确定**，否则缓存归零（`02-契约规范.md` §1.2）。
 * 这里用固定字符串重复，不含时间、随机、序号之外的可变量。
 */
object PrefixAligner {

    /**
     * 云端缓存块大小（token）。
     *
     * **不是通用常量** —— 它是 DashScope 实测值（`实测-07`）。
     * 换 provider 必须重新测；本地 llama.cpp 是 token 级精确，不需要对齐。
     */
    const val CLOUD_CACHE_BLOCK_TOKENS = 1024

    /** 填充行的内容。**逐字节固定**，不得含可变量。 */
    private const val FILLER_LINE =
        "- 说明：以下为格式占位内容，用于使上下文长度对齐到服务端缓存块边界。\n"

    /**
     * 安全裕度：在估算基础上额外多补的比例。
     *
     * `实测-08` 证明 token 估算**不可靠**（曾高估 40%，导致块对齐失效、命中率 0%）。
     * 既然方向可能是高估也可能是低估，就必须**朝"多补"的方向留裕度**：
     * 多补的代价是每块多花一点输入 token；
     * 少补的代价是**整块完全不命中** —— 后者贵得多。
     *
     * 30% 是权衡值：即使估算低估 20%，仍能跨过块边界。
     */
    private const val SAFETY_MARGIN = 1.3

    /**
     * 把冻结区文本补齐到「至少 [targetTokens]，且略超过块边界」。
     *
     * @param text 原始冻结区文本
     * @param targetTokens 目标 token 数（通常是块大小的整数倍）
     * @return 补齐后的文本；若已超过目标则**原样返回**（绝不截断）
     */
    fun padToBlockBoundary(
        text: String,
        targetTokens: Int = CLOUD_CACHE_BLOCK_TOKENS,
    ): PaddedPrefix {
        // 关键：把目标放大到 SAFETY_MARGIN 倍，确保**即使估算低估也跨过边界**。
        // 这不是浪费 —— 见 SAFETY_MARGIN 的说明。
        val guardedTarget = (targetTokens * SAFETY_MARGIN).toInt()

        val current = TextMath.estimateTokens(text)
        if (current >= guardedTarget) {
            return PaddedPrefix(text, current, addedTokens = 0, aligned = true)
        }

        val sb = StringBuilder(text)
        sb.append("\n## 附：格式占位\n")
        var added = 0
        // 逐行补，接近目标时停止 —— 保证确定性（不用随机填充）
        while (TextMath.estimateTokens(sb.toString()) < guardedTarget) {
            sb.append(FILLER_LINE)
            added += TextMath.estimateTokens(FILLER_LINE)
            // 防御：估算失效时不要死循环
            if (added > guardedTarget * 3) break
        }

        val finalTokens = TextMath.estimateTokens(sb.toString())
        return PaddedPrefix(
            text = sb.toString(),
            estimatedTokens = finalTokens,
            addedTokens = finalTokens - current,
            aligned = true,
        )
    }

    /**
     * 计算应该对齐到哪个块倍数：**当前长度向上取整到下一个块边界**。
     *
     * 例：513 → 1024；1025 → 2048；2048 → 2048（正好则不动）。
     */
    fun nextBlockBoundary(currentTokens: Int, blockTokens: Int = CLOUD_CACHE_BLOCK_TOKENS): Int {
        if (currentTokens <= 0) return blockTokens
        val blocks = (currentTokens + blockTokens - 1) / blockTokens
        return blocks * blockTokens
    }
}

/** 补齐结果。 */
data class PaddedPrefix(
    val text: String,
    val estimatedTokens: Int,
    val addedTokens: Int,
    val aligned: Boolean,
)
