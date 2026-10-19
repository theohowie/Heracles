package dev.heracles.core.provider

import dev.heracles.core.tool.NativeToolCall

/**
 * 对话消息角色 —— 云端 `/chat/completions` 需要。
 *
 * 本地后端走 `/completion`（裸 prompt，精确测缓存），
 * 云端后端走 `/chat/completions`（要 chat template + 工具调用）。
 * 两者请求模型不同，因此 [GenerateRequest] 同时保留 `prompt` 与 `messages`。
 */
enum class ChatRole(val wire: String) {
    SYSTEM("system"),
    USER("user"),
    ASSISTANT("assistant"),
    TOOL("tool"),
}

/**
 * 一条对话消息。
 *
 * ## 原生 function calling 的形状（ADR-031 step 2）
 *
 * 只含角色与文本就是**文本轨**（今天的行为，零改动）。原生轨多两个字段：
 *
 * | 场景 | 填什么 |
 * |---|---|
 * | assistant 轮**发起了**原生调用 | [nativeCalls] 非空（`content` 通常为空串 —— 这是正常的） |
 * | 工具结果回填 | `role = TOOL` + [toolCallId] 非空（OpenAI：`tool` 消息 + `tool_call_id`；Anthropic：`user` 轮里的 `tool_result` 块） |
 * | 工具**失败了** | 上面再加 [isError]（Anthropic 的 `tool_result.is_error`）——"失败"是**语义**，不是某家的语法 |
 *
 * ⚠️ **两条铁律**：
 * 1. `role = TOOL` 的消息**必须**带 [toolCallId]——没有 id 的"孤立 tool 消息"
 *    格式非法（DashScope 会忽略或报错，2026-10-09 实修记录）。
 *    ⇒ 文本轨**继续**走 `USER` + 纯文本（[toolCallId] 为 null），**一字节不变**。
 * 2. 带 [nativeCalls] 的 assistant 消息，在下一轮请求里**必须**跟齐
 *    每个调用的结果消息（或用合成的"未执行"结果补齐），否则服务端会判非法。
 *
 * @param nativeCalls 该轮模型请求的原生调用（默认空 = 文本轨）
 * @param toolCallId 本消息回填的是哪一次原生调用；null = 文本轨的工具结果
 * @param isError 工具结果是否是**失败**（仅对 `role = TOOL` 有意义）。
 *   必须如实传：把它写成 false，模型会以为操作成功了 ⇒ 在错误的前提上继续做事。
 */
data class ChatMessage(
    val role: ChatRole,
    val content: String,
    val nativeCalls: List<NativeToolCall> = emptyList(),
    val toolCallId: String? = null,
    val isError: Boolean = false,
)
