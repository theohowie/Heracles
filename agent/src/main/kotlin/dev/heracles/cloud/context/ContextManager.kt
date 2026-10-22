package dev.heracles.cloud.context

import dev.heracles.core.text.TextMath

/**
 * **云端上下文预算管理器**（`CloudAgentPipeline`，模块二）。
 *
 * ## 它替代了什么
 *
 * 旧路径有两处**无条件暴力截断**：
 *
 * | 旧实现 | 行为 | 问题 |
 * |---|---|---|
 * | `MainActivity.kt:1662` `HISTORY_MAX_TURNS = 10` | 跨 run 历史只喂最近 **10 轮** | 静默丢历史、无标注；128K 上下文下 10 轮远不到 1/10 |
 * | `AgentLoop.kt:736/739` | 工作记忆里失败原因 `take(80)`、拦截原因 `take(40)` | 模型看不到失败细节，而失败细节正是它改对的前提 |
 *
 * 这两处都是**按轮数/字符数**硬切，与"模型到底能装多少"无关。
 *
 * ## 本类的做法：**按 token 预算装，装不下才摘要**
 *
 * 1. 预算 = 模型真实上下文窗口 × [budgetRatio]（默认 0.8，给输出与系统提示留余量）
 * 2. **装得下就全装** —— 不做任何"保留最近 N 轮"的选择
 * 3. 装不下时，**从最旧的消息开始**移出，并把移出的部分交给摘要器压缩成一段
 * 4. **工具结果与历史同等对待** —— 不因为"它是工具结果"就先砍它
 *
 * ## 为什么"从最旧开始"而不是"保留最近 N 轮"
 *
 * append-only 会话的语义是"越新的越相关"，但**"丢掉多少"应该由预算决定，
 * 而不是由轮数决定**。同样 10 轮，短问答可能只占 2K token，长代码讨论可能占 200K ——
 * 一个固定轮数不可能同时正确。
 *
 * ## 确定性（缓存的前提）
 *
 * 同样的输入必须选出同样的消息集合：排序依据只有**消息序号**，
 * 不含时间戳/随机数/Map 迭代序。`ContextManagerTest` 钉住这一点。
 *
 * @param modelContextWindow 模型的真实上下文窗口（token）。来自服务端上报，
 *   上报缺失时由调用方给保守兜底（见 `CloudBudget.defaultWindowFor`）。
 */
class ContextManager(
    private val modelContextWindow: Int,
    /** 预算占比。0.8 = 给输出/系统提示留 20%。 */
    private val budgetRatio: Double = DEFAULT_BUDGET_RATIO,
    /** 摘要器 —— 溢出时把被移出的消息压成一段文字。 */
    private val summarizer: ConversationSummarizer,
) {

    init {
        require(modelContextWindow > 0) { "modelContextWindow 必须 > 0，收到 $modelContextWindow" }
        require(budgetRatio > 0.0 && budgetRatio <= 1.0) {
            "budgetRatio 必须在 (0,1]，收到 $budgetRatio"
        }
    }

    /** 本管理器允许占用的 token 预算。 */
    val budgetTokens: Int get() = (modelContextWindow * budgetRatio).toInt()

    /**
     * 做一次装载决策 —— **纯函数**（不调用模型、不碰 IO）。
     *
     * 决策与执行分开，是为了让"到底装了什么"可单测、可复现。
     * 真正调摘要模型由 [applyCompaction] 在需要时执行。
     *
     * @param systemTokens 系统提示词 + 工具 schema 已占的 token（不可压缩）
     * @param messages 完整会话（**顺序即真实发生顺序**）
     * @return 装载计划
     */
    fun plan(systemTokens: Int, messages: List<AgentMessage>): ContextPlan {
        val available = budgetTokens - systemTokens
        if (available <= 0) {
            // 系统提示自己就超预算 —— 这是配置错误，不是"再砍一点历史"能救的。
            // 如实报告，让上层报警（不静默降级成"什么都不装"）。
            return ContextPlan(
                kept = emptyList(),
                dropped = messages,
                overflow = Overflow.SYSTEM_PROMPT_ALONE_EXCEEDS_BUDGET,
                availableTokens = available,
            )
        }

        // 从**最新**往旧装，直到装不下 —— 等价于"保留最近的消息"，
        // 但边界由 token 决定而不是轮数。
        var used = 0
        var cut = messages.size
        while (cut > 0) {
            val cost = messages[cut - 1].estimatedTokens
            if (used + cost > available) break
            used += cost
            cut--
        }

        if (cut == 0) {
            // 全装得下 —— **这一档是常态**，旧实现根本走不到这里。
            return ContextPlan(
                kept = messages,
                dropped = emptyList(),
                overflow = Overflow.NONE,
                availableTokens = available,
            )
        }

        // 有条目溢出：被移出的那段交给摘要器压缩。
        // ⚠️ 摘要**保留在 kept 之前**（它是更早内容的替身），顺序不能反。
        return ContextPlan(
            kept = messages.subList(cut, messages.size),
            dropped = messages.subList(0, cut),
            overflow = Overflow.TRIGGERED,
            availableTokens = available,
        )
    }

    /**
     * 如果 [plan] 判定溢出，**真正调用摘要器**，并返回可发给模型的最终消息列表。
     *
     * 摘要失败（网络/超限/空响应）⇒ **退回完整历史**并如实标记 ——
     * 宁可多花 token，也不能让模型在残缺上下文上继续做事
     * （旧实现 `AgentLoop.kt:1246-1250` 对"摘要为空"的处理是对的，本类沿用）。
     */
    suspend fun applyCompaction(
        systemTokens: Int,
        messages: List<AgentMessage>,
    ): CompactedContext {
        val p = plan(systemTokens, messages)
        if (p.overflow != Overflow.TRIGGERED) {
            return CompactedContext(
                messages = p.kept,
                summary = null,
                keptCount = p.kept.size,
                droppedCount = p.dropped.size,
                summaryFailed = false,
                availableTokens = p.availableTokens,
            )
        }

        // ★ 摘要的输出预算必须 ≥ 4096：思考模型的思考与正文**共享** max_tokens，
        //   预算太小会让思考吃光预算、正文为空 ⇒ 摘要静默失败
        //   （旧实现 `AgentLoop.kt:1238` 就是 1024 —— 这正是要修的那一处）。
        val summaryResult = runCatching { summarizer.summarize(p.dropped) }
        val summary = summaryResult.getOrNull()?.takeIf { it.isNotBlank() }

        if (summary == null) {
            return CompactedContext(
                messages = messages,
                summary = null,
                keptCount = messages.size,
                droppedCount = 0,
                summaryFailed = true,
                availableTokens = p.availableTokens,
            )
        }

        val summaryMsg = AgentMessage(
            role = MessageRole.USER,
            text = "【此前会话摘要（原始记录因超出上下文预算已归档）】\n$summary",
            isSummary = true,
        )
        return CompactedContext(
            messages = listOf(summaryMsg) + p.kept,
            summary = summary,
            keptCount = p.kept.size,
            droppedCount = p.dropped.size,
            summaryFailed = false,
            availableTokens = p.availableTokens,
        )
    }

    companion object {
        /** 默认预算占比：留 20% 给输出与系统提示。 */
        const val DEFAULT_BUDGET_RATIO = 0.80

        /**
         * 摘要调用的输出预算下限 —— **不许低于 4096**。
         *
         * 理由（真机实测，`AgentLoop.kt:159-183` 记录）：`max_tokens` 是
         * **思考 + 正文共享的单一预算**。1024 时思考把它吃光、正文为空 ⇒
         * `finish_reason=length`、摘要静默失败。4096 是"思考 + 一段有用摘要"的下限。
         */
        const val MIN_SUMMARY_OUTPUT_TOKENS = 4096
    }
}

/** 装载决策的结果。 */
data class ContextPlan(
    /** 可以直接发给模型的消息（顺序不变）。 */
    val kept: List<AgentMessage>,
    /** 被移出的消息（顺序不变）—— 溢出的那部分，将被摘要。 */
    val dropped: List<AgentMessage>,
    val overflow: Overflow,
    /** 可用于对话的 token（预算 − 系统提示）。 */
    val availableTokens: Int,
)

/** 溢出的性质 —— **必须区分**，因为处置不同。 */
enum class Overflow {
    /** 全装得下。 */
    NONE,

    /** 有条目溢出，应做摘要。 */
    TRIGGERED,

    /**
     * 系统提示词**自己**就超过预算。
     *
     * 这不是"再砍历史"能救的：说明工具 schema / 系统提示太大，
     * 或者把模型的上下文窗口配错了。上层应当**响亮报警**，
     * 而不是静默地把历史砍到空。
     */
    SYSTEM_PROMPT_ALONE_EXCEEDS_BUDGET,
}

/** 摘要后的上下文。 */
data class CompactedContext(
    val messages: List<AgentMessage>,
    val summary: String?,
    val keptCount: Int,
    val droppedCount: Int,
    /**
     * 摘要**尝试过但失败了**。
     *
     * 此时 [messages] 是**完整未压缩**的历史 —— 如实告诉上层，
     * 让它决定要不要告知用户（绝不假装压缩成功）。
     */
    val summaryFailed: Boolean,
    val availableTokens: Int,
)

/** 会话中的一条消息（本管线自有的中立表示，不依赖 `core.provider.ChatMessage`）。 */
data class AgentMessage(
    val role: MessageRole,
    val text: String,
    /** 原生工具调用（assistant 轮）—— wire 形状见 `NativeToolCall`。 */
    val toolCalls: List<CloudToolCall> = emptyList(),
    /** 工具结果配对的 call id（tool 轮必填）。 */
    val toolCallId: String? = null,
    val isError: Boolean = false,
    /** 本条是压缩摘要（不是用户真实输入）。 */
    val isSummary: Boolean = false,
) {
    /**
     * token 估算 —— **每次读取时计算**，不缓存。
     *
     * 缓存会引入"消息被改了但估值没变"的隐患；而 [TextMath.estimateTokens]
     * 是 O(n) 纯函数，在装载决策里调用一两次的成本远低于一次 API 请求。
     */
    val estimatedTokens: Int
        get() = TextMath.estimateTokens(text) +
            toolCalls.sumOf { TextMath.estimateTokens(it.argumentsJson) }
}

enum class MessageRole { SYSTEM, USER, ASSISTANT, TOOL }

/** 本管线自有的工具调用表示（与 `core.tool.NativeToolCall` 同形，避免管线依赖旧类型）。 */
data class CloudToolCall(
    val id: String,
    val name: String,
    /** **未解析、未归一化**的 arguments 原文。 */
    val argumentsJson: String,
)

/**
 * 摘要器 —— 唯一需要"调用模型"的环节，抽成接口以便：
 * 1. 单测里注入确定性替身（不花真 Key）
 * 2. 上层控制用哪个模型做摘要（可以用便宜的小模型）
 */
interface ConversationSummarizer {
    /**
     * 把一段被移出的历史压成摘要。
     *
     * 实现**必须**用 ≥ [ContextManager.MIN_SUMMARY_OUTPUT_TOKENS] 的输出预算。
     * 失败请抛异常或返回空串（两种都会被 [ContextManager.applyCompaction] 当失败处理）。
     */
    suspend fun summarize(dropped: List<AgentMessage>): String
}
