package dev.heracles.agent

import dev.heracles.core.contract.Contract

/**
 * **思考预算的执行策略** —— 阻断"开了思考就完全不能用"。
 *
 * ## 它防的是什么（Captain 2026-10-12 升级为硬要求）
 *
 * 实测（`25` §12.1，llama-server + Qwen3.5-4B，档位 `low`，`max_tokens=512`）：
 *
 * ```
 * 512 个 chunk 全部是 reasoning_content   ← 思考吃光全部预算
 * 正文 0 字符                              ← 没有工具调用、没有最终回答
 * finish_reason = length                   ← 被截断，不是生成完
 * ```
 *
 * 这不是"慢"，是**功能完全不可用**：用户正因为想看思考才去开推理等级，
 * 结果一开就永远出不了答案，agent 永不收敛。
 *
 * ## 为什么"两个预算"这个说法需要澄清
 *
 * **`max_tokens` 只有一个，我们不能真的给思考单独开一个配额** ——
 * OpenAI 兼容接口没有这个参数，本地 llama.cpp 也没有。
 *
 * 所以本策略做的是**客户端侧的执行**，两层：
 *
 * | 层 | 手段 | 效果 |
 * |---|---|---|
 * | 1 | **截断**：思考累计超过预算后，接下来的思考增量**不再转发**给 UI | 防止思考把轮次拖到死不收工；省下的是**墙钟**，不是 token |
 * | 2 | **提示**：思考被截断时，给正文留出信号（见 `AgentLoop`） | 让模型有机会转入回答 |
 *
 * ⚠️ **诚实说明**：手段 1 **不能减少已消耗的 token**（服务端已经在生成它们了）。
 * 它保证的是"**UI 不被无限思考拖住、轮次能收口**"。
 * 真正的 token 级控制要靠**用户选更低的档位**（`OFF`）或**更小的 `max_tokens`**。
 *
 * 这个区别很重要 —— 不能对外宣称"我们给思考单独分配了预算"，
 * 那是**做不到的事**。
 */
object ThinkingBudget {

    /**
     * 思考的**展示预算**（字符数口径，用于流式实时判定）。
     *
     * 用"字符数"而不是"token 数"，因为流式过程中我们**只有字符**，
     * 拿不到增量 token 计数（服务端只在最后给一次 usage）。
     * 用 [dev.heracles.core.text.TextMath.estimateTokens] 反推——
     * 它在 `实测-08` 里校准过，做粗略预算足够（见其 KDoc 的告诫）。
     *
     * @param maxOutputTokens 本轮的总输出预算
     * @return 允许转发的思考字符上限（**不是**服务端的 token 限制）
     */
    fun reasoningCharBudget(maxOutputTokens: Int): Int {
        val ratioChars = (maxOutputTokens * Contract.Stream.MAX_REASONING_BUDGET_RATIO).toInt()
        val floorChars = Contract.Stream.MIN_REASONING_BUDGET_TOKENS
        // 思考的字符预算取"比例值"与"下限"的较大者。
        // 中文大致 0.7 token/字，所以字符数略大于 token 数是正常的。
        return maxOf(ratioChars, floorChars)
    }

    /**
     * 是否应当**继续转发**思考增量。
     *
     * @param forwardedChars 已经转发出去的思考字符数
     * @param maxOutputTokens 本轮总预算
     */
    fun shouldForwardReasoning(forwardedChars: Int, maxOutputTokens: Int): Boolean =
        forwardedChars < reasoningCharBudget(maxOutputTokens)

    /**
     * 思考是否已经**超预算**（用于告知用户"思考被截断"）。
     *
     * ⚠️ 超预算**不是错误**，UI 不该报红 —— 它只是"思考够长了，该出答案了"。
     */
    fun isReasoningOverBudget(forwardedChars: Int, maxOutputTokens: Int): Boolean =
        forwardedChars >= reasoningCharBudget(maxOutputTokens)
}
