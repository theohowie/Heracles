package dev.heracles.provider.http

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **Responses 轨的思考（reasoning）事件识别门禁** —— 2026-10-21。
 *
 * ## 为什么需要这个测试（用户症状 → 缺陷形态）
 *
 * 用户报「思考过程几乎是英文」。审计三条 provider 轨时发现 **Responses 轨
 * 完全没接 reasoning 事件** —— 思考在 provider 层就被丢弃，UI 永远看不到，
 * 而正文照常 ⇒ 用户只会觉得"模型没思考"，**没有任何报错**。
 *
 * 这类"静默损失"不能靠读代码发现，必须有断言盯着。
 *
 * ## 教训：为什么它必须是一个可单测的纯函数
 *
 * 最初我把两个事件名写成 `when` 的两个分支。那种写法**测不到** ——
 * 要测就得起 HTTP server 或反射调私有分支。抽成 [OpenAiResponsesProvider.isReasoningDeltaEvent]
 * 之后，判定逻辑可以直接验证，且不会因为将来重构 `when` 而悄悄丢掉。
 *
 * ## 三条 provider 轨的一致性
 *
 * 另两轨的对应字段（只读核对结论，不在此文件断言）：
 * - Anthropic：`content_block_delta` 的 `delta.thinking` → `deltaReasoning` ✅
 * - OpenAI 兼容：`choices[].delta.reasoning_content`（回退 `.reasoning`）→ `deltaReasoning` ✅
 *
 * **思考语言由模型决定，代码无法强制；这里只保证"不丢"。**
 */
class ReasoningChannelTest {

    @Test
    @DisplayName("★★ reasoning_summary_text.delta 必须被识别（此前完全没接 ⇒ 思考全丢）")
    fun summaryDeltaIsRecognized() {
        assertTrue(
            OpenAiResponsesProvider.isReasoningDeltaEvent("response.reasoning_summary_text.delta"),
            "官方给的可读摘要是**多数端点**的思考来源，漏了它思考就没了",
        )
    }

    @Test
    @DisplayName("★★ reasoning_text.delta 必须被识别（部分端点只发原始思考流）")
    fun reasoningTextDeltaIsRecognized() {
        assertTrue(
            OpenAiResponsesProvider.isReasoningDeltaEvent("response.reasoning_text.delta"),
            "只接 summary 会让只发原始流的端点思考全丢",
        )
    }

    @Test
    @DisplayName("★★ 正文事件**不能**被当思考（否则思考与正文会串）")
    fun textDeltaIsNotReasoning() {
        assertFalse(
            OpenAiResponsesProvider.isReasoningDeltaEvent("response.output_text.delta"),
            "正文被当思考会让最终答案跑到思考区，用户看不到回答",
        )
    }

    @Test
    @DisplayName("★ 工具参数事件**不能**被当思考（否则 arguments 会混入非 JSON 文本）")
    fun argumentDeltaIsNotReasoning() {
        assertFalse(
            OpenAiResponsesProvider.isReasoningDeltaEvent("response.function_call_arguments.delta"),
            "思考混进 arguments 会产生非法 JSON，症状会伪装成『模型参数写错』",
        )
    }

    @Test
    @DisplayName("★ null / 空 / 未知事件名都安全（不崩、不误判）")
    fun unknownEventIsNotReasoning() {
        assertFalse(OpenAiResponsesProvider.isReasoningDeltaEvent(null), "null 不该崩")
        assertFalse(OpenAiResponsesProvider.isReasoningDeltaEvent(""), "空串不该误判")
        assertFalse(
            OpenAiResponsesProvider.isReasoningDeltaEvent("response.completed"),
            "终止事件不该被当思考",
        )
    }
}
