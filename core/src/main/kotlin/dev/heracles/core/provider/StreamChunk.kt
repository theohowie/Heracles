package dev.heracles.core.provider

import dev.heracles.core.tool.NativeToolCall

/**
 * 流式生成的一个**增量块** —— `25-流式工作步骤.md` §5.2。
 *
 * ## 为什么是"增量"而不是"到目前为止的全文"
 *
 * 用户要的是「**一个字一个字出来**」，而不是「等 AI 想完了再全部展示」。
 * UI 侧要能**立刻**渲染每一个 token，所以契约给的是 δ（增量）：
 * 调用方自己累加到 buffer，累加规则是**字符串直接拼接**。
 *
 * **不要**把这个类型改成"累积快照" —— 那会让每个 chunk 的负载随输出线性增长，
 * 逐 token 推送时变成 O(n²) 的字符串拷贝。
 *
 * ## 两个通道必须分开
 *
 * | 字段 | 语义 | 用户可见性 |
 * |---|---|---|
 * | [deltaReasoning] | **思考过程**（`reasoning_content` / `reasoning`） | ★ 用户最想看的那一个 |
 * | [deltaText] | 最终正文（`content`） | 最终答案 |
 *
 * 二者**不得**合并进同一个字段（`25` §2 错误一：把思考粘进正文，
 * 切会话后无法区分"过程"与"答案"）。
 *
 * ## 生命周期
 *
 * 一次 `generateStream()` 产出 **0..n 个内容块 + 恰好 1 个 [done] 块**。
 * `done` 块携带 [finishReason]，其 `delta*` 恒为空。
 * 出错时以异常终止 Flow（不产出 `done`），由调用方决定重试 ——
 * 与 `generate()` 返回 `Result` 的语义保持一致。
 *
 * ## 原生工具调用（ADR-031 step 2）
 *
 * 各家的 `tool_calls` 在流里是**分片**到达的，**任一单片都不是合法 JSON**。
 * 分片契约是**wire 细节**，所以由 provider **在内部拼装**，
 * 只把**拼装完成的**中立结果（[NativeToolCall]）挂在**终止块**上向上传
 * （见 [toolCalls]）。上层永远看不到 `index` / `partial_json`。
 *
 * @param deltaText 正文增量；空串表示本块不含正文
 * @param deltaReasoning 思考增量；空串表示本块不含思考
 * @param done 是否为终止块
 * @param finishReason 终止块的结束原因；非终止块恒为 `null`
 * @param toolCalls **拼装完成**的原生调用；只有终止块可能非空
 */
data class StreamChunk(
    val deltaText: String = "",
    val deltaReasoning: String = "",
    val done: Boolean = false,
    val finishReason: FinishReason? = null,
    val toolCalls: List<NativeToolCall> = emptyList(),
) {
    /** 本块是否真的携带**内容增量**（用于过滤心跳块） */
    val hasPayload: Boolean get() = deltaText.isNotEmpty() || deltaReasoning.isNotEmpty()

    /**
     * 本块是否携带原生调用。
     *
     * **刻意不算进 [hasPayload]**：那个字段的语义是"内容增量"，
     * 而工具调用是**终止块上的整体载荷**（不是 δ）。
     * `StreamChunkTest` 已钉住"done 块不得夹带内容"—— 让它继续只讲内容。
     */
    val hasToolCalls: Boolean get() = toolCalls.isNotEmpty()

    companion object {
        /** 终止块 —— 一次流式响应里**恰好**产出一个 */
        fun done(reason: FinishReason = FinishReason.STOP): StreamChunk =
            StreamChunk(done = true, finishReason = reason)

        /**
         * 终止块 + 本轮**拼装完成**的原生调用。
         *
         * 调用必须与终止块**同块**到达：分两块的话，调用方在 `done` 上收流时
         * 会漏掉调用（`AgentLoop` 就是"看到 done 即结束收集"）。
         */
        fun done(reason: FinishReason, toolCalls: List<NativeToolCall>): StreamChunk =
            StreamChunk(done = true, finishReason = reason, toolCalls = toolCalls)

        /** 仅正文的增量 */
        fun text(delta: String): StreamChunk = StreamChunk(deltaText = delta)

        /** 仅思考的增量 */
        fun reasoning(delta: String): StreamChunk = StreamChunk(deltaReasoning = delta)
    }
}

/**
 * 推理档位 —— **provider 无关**的抽象。
 *
 * ## ★ 为什么放在这里（而不是 provider 内部）
 *
 * `AGENTS.md` 硬约束：**provider 专有字段不得泄漏到 `ModelProvider` 之上**。
 *
 * `enable_thinking`（本地 llama.cpp）与 `reasoning_effort`（云端 OpenAI 兼容）
 * 是**两个互不相同的专有字段**，上层不得直接设置。上层只表达"我要多深的推理"，
 * 由各 provider 映射到自己后端的字段（`25-流式工作步骤.md` §10.3）。
 *
 * ## ★ 实测的平台差异（必须如实对待，不要假装统一）
 *
 * `llama-server` b11401 + Qwen3.5-4B，Captain 实测：
 *
 * | 后端字段 | 结果 |
 * |---|---|
 * | `chat_template_kwargs.enable_thinking: true` | ✅ 生效（出 `reasoning_content`） |
 * | `chat_template_kwargs.enable_thinking: false` | ✅ 生效（0 个 `reasoning_content`） |
 * | `reasoning_effort: "low"`（顶层，本地） | ❌ **被静默忽略** |
 *
 * ⇒ **本地只有开 / 关两态**；`LOW` / `HIGH` / `MAX` 在本地**映射结果完全相同**（都是"开"）。
 * 云端（DeepSeek / DashScope 等）支持 `reasoning_effort` 分档。
 *
 * UI **必须**如实说明这一点，否则用户会以为"调到 Max 就更聪明"。
 */
enum class ReasoningLevel {
    /** 由实现按任务复杂度启发式决定（默认档） */
    AUTO,

    /** 关闭思考 —— 最快（本地实测 ~3 s vs ~15 s） */
    OFF,

    /** 浅思考 */
    LOW,

    /** 深思考 */
    HIGH,

    /** 最深思考（后端不支持则退化为 [HIGH]） */
    MAX,
    ;

    /**
     * 本档位是否要求"打开思考"。
     *
     * 本地 llama.cpp 只有这一个布尔量可用 —— `LOW`/`HIGH`/`MAX` 在此**无法区分**。
     * `AUTO` 返回 `null`，表示"由实现决定"，不是"开"也不是"关"。
     */
    val thinkingRequested: Boolean?
        get() = when (this) {
            AUTO -> null
            OFF -> false
            LOW, HIGH, MAX -> true
        }

    companion object {
        /** 线上表示（设置持久化 / Flutter 通道用）。`Default` 已更名为 `Auto`（`25` §10.1） */
        fun fromWire(raw: String?): ReasoningLevel = when (raw?.trim()?.lowercase()) {
            "off", "none", "false" -> OFF
            "low" -> LOW
            "high" -> HIGH
            "max" -> MAX
            else -> AUTO
        }

        /** 线上表示的小写名 */
        val ReasoningLevel.wire: String get() = name.lowercase()
    }
}
