package dev.heracles.core.context

import dev.heracles.core.text.TextMath
import dev.heracles.core.tool.NativeToolCall

/**
 * 会话中的一轮。
 *
 * ## 原生轨的两个新字段为什么**对 [Session.render] 不可见**（ADR-031 step 2）
 *
 * 本地文本轨的 prompt 必须**逐字节不变**（铁律 1 + F3c 的 hash 证据），
 * 而 [render] 是本地/CLI 的 prompt 构造器。所以 `nativeCalls` / `callId` / `isError`
 * **只**被云端消息装配（`AgentLoop.renderAsMessages`）读取，一个字符都不进 [render]。
 * 对应 `SessionAppendOnlyTest` 里"带原生字段的会话 render 与不带时逐字节相同"那条断言。
 */
sealed interface Turn {
    data class User(val text: String) : Turn

    /**
     * 助手的一轮输出。
     *
     * @param nativeCalls 本轮模型通过**原生 function calling** 请求的调用；
     *   默认空 = 纯文本轨（今天的行为）。
     */
    data class Assistant(
        val text: String,
        val nativeCalls: List<NativeToolCall> = emptyList(),
    ) : Turn

    /**
     * 一次工具执行的结果 —— 回喂给模型。
     *
     * @param callId 若这次调用来自**原生轨**，这里是它在 wire 上的 id
     *   （OpenAI `tool_call_id` / Anthropic `tool_use_id` / Responses `call_id`）；
     *   `null` = 文本轨（回填成一条 user 文本消息，保持今天的行为）。
     *   ⚠️ **必须存在会话里**，不能只放当轮局部变量：每次请求都是**无状态重放**
     *   （没有 `previous_response_id`），下一轮要把 `tool_use` 与结果**配对**重放。
     * @param isError 工具**失败**（或被架构层拦下未执行）时为 true ——
     *   映射到 Anthropic 的 `tool_result.is_error` / 让模型知道"这条不是成功结果"。
     */
    data class ToolResult(
        val tool: String,
        val result: String,
        val callId: String? = null,
        val isError: Boolean = false,
    ) : Turn

    data class System(val text: String) : Turn
}

/**
 * 会话 —— **铁律 1 的类型级保障**（`01-架构总览.md` §3）。
 *
 * 本类**刻意不提供** `update()` / `removeAt()` / `replace()` / `set()` 之类的修改方法。
 * 目的：让"改写历史"在**类型层面不可能**，而不是靠 code review 记得住。
 *
 * 为什么这么较真：实测表明（`实测-01` §4）
 *  - append-only → 命中率 96.6–96.8%，稳态每轮 2.1 s
 *  - 尾部不同（分支）→ 命中率 24.3% 且**永久卡死**，每轮 17–19 s
 *
 * 而缓存塌缩的症状只是"变慢了"，不会报错、不会崩溃 —— 靠人眼是发现不了的。
 *
 * 对应回归测试：`SessionAppendOnlyTest`
 */
class Session private constructor(
    /** 会话开始即固定的冻结区，本会话内不可变 */
    val frozen: FrozenPrefix,
    private val turnList: List<Turn>,
) {
    val turns: List<Turn> get() = turnList

    /**
     * **唯一的修改入口**。返回新实例，不改动原实例。
     *
     * 失败重试也走这里 —— 通过追加一条说明，而不是改写上一条
     * （`02-契约规范.md` §2.2）。
     */
    fun append(turn: Turn): Session = Session(frozen, turnList + turn)

    /** 渲染为完整 prompt：[冻结区][动态区]。严格 append：前面部分永不改变。 */
    fun render(): String = buildString {
        append(frozen.text)
        for (t in turnList) {
            append('\n')
            when (t) {
                is Turn.User -> append("用户：").append(t.text)
                is Turn.Assistant -> append("助手：").append(t.text)
                is Turn.ToolResult -> append("工具[").append(t.tool).append("]：").append(t.result)
                is Turn.System -> append("系统：").append(t.text)
            }
        }
    }

    val estimatedPromptTokens: Int get() = TextMath.estimateTokens(render())

    val turnCount: Int get() = turnList.size

    companion object {
        fun start(frozen: FrozenPrefix): Session = Session(frozen, emptyList())
    }
}
