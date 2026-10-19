package dev.heracles.provider.http

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.CacheStats
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.GenerateResult
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.ProviderCapabilities
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ProviderHealth
import dev.heracles.core.provider.ProviderKind
import dev.heracles.core.provider.ReasoningLevel
import dev.heracles.core.provider.StreamChunk
import dev.heracles.core.provider.StructuredSpec
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import java.time.Duration

/**
 * **Anthropic Messages 协议的 provider**（2026-10-14，用户要求真实支持）。
 *
 * ## 与 OpenAI 兼容协议的差异（为什么要独立一个类）
 *
 * | 项 | OpenAI | **Anthropic** |
 * |---|---|---|
 * | 端点 | `/v1/chat/completions` | **`/v1/messages`** |
 * | 鉴权 | `Authorization: Bearer` | **`x-api-key`** + **`anthropic-version: 2023-06-01`** |
 * | 正文 | `choices[0].message.content`（字符串） | **`content[]` 数组**（`type:"text"` 块）|
 * | 工具调用 | `tool_calls[].function` | `content[]` 里 **`type:"tool_use"` 块** |
 * | 工具结果回传 | `role:"tool"` | `role:"user"` + `content:[{type:"tool_result"}]` |
 * | max_tokens | 可选 | **必填** |
 * | 思考 | `reasoning_effort` | **`thinking` 对象** |
 *
 * 差异大到"加参数"装不下 —— 独立实现才诚实。
 *
 * ## AgentLoop 的输出协议怎么承载（2026-10-18 校准）
 *
 * Anthropic 没有 GBNF，**也没有 `response_format`** ⇒ 本类**不发任何"约束解码"字段**：
 * `buildBody(messages, maxOutputTokens, stream, tools)` **连 `structured` 参数都没有**，
 * `StructuredSpec` 在这一层**根本进不来**（`NativeToolsRequestTest.anthropicHasNoStructuredSeam`
 * 对这条做了**结构性**断言）。策略是**靠提示词 + 解析器容错**。
 *
 * ⚠️ **原文（已删）写「`StructuredSpec.Grammar` 会走 `json_object` 降级，Anthropic 同样处理」是错的**：
 * 那是 **OpenAI 兼容路径**的降级（`OpenAiCompatProvider`），Anthropic 没有这条路。
 * 写成事实会让人误以为"这里也在约束解码"。
 * 若将来要接（例如改用 `tool_use` 强制 JSON），**必须同时**处理
 * 「原生 `tools` 非空 ⇒ **不发**约束解码」的互斥 + 真机验证，并改上面那条结构性测试。
 *
 * 附：本类不发约束解码 ⇒ 与原生 `tools` 的互斥是**真空成立**的（不是靠一个判断维持的）。
 *
 * ## 用户怎么选
 *
 * Provider 配置 `protocol = "anthropic"` → AgentBridge 走本类。
 * 配置页下拉里列出（用户参考图的三协议下拉）。
 */
class AnthropicProvider(
    override val id: String = "anthropic:claude",
    private val baseUrl: String = DEFAULT_BASE_URL,
    private val apiKey: String,
    private val modelName: String,
    private val requestTimeout: Duration = Duration.ofMinutes(15),
    private val maxTokensForMessages: Int = Contract.Provider.DEFAULT_MAX_OUTPUT_TOKENS,
) : ModelProvider {

    override val kind: ProviderKind = ProviderKind.CLOUD

    override val capabilities: ProviderCapabilities = ProviderCapabilities(
        supportsGrammar = false,
        supportsJsonSchema = true,
        // Anthropic 的 prompt caching（cache_control）是**显式标注**式的，
        // 与 OpenAI 的自动前缀缓存语义不同 —— 先如实声明不支持，
        // 待实测 cache_read_input_tokens 后再接（不假装支持）。
        supportsPrefixCache = false,
        needsPrewarm = false,
        cacheBlockTokens = 0,
        // ★ 能力声明（ADR-031 决策 2）：Anthropic 的 `tools` 用 `input_schema` 形状（见 [NativeToolSchema]）。
        //   ⚠️ "有能力" ≠ "已在发"：发不发由装配方决定，响应侧解析（step 2）没落地前不许打开。
        supportsNativeTools = true,
    )

    private var loaded = false

    override suspend fun load(config: ProviderConfig) = run {
        loaded = true
        Result.success(Unit)
    }

    override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)

    override suspend fun release() {
        loaded = false
    }

    override fun health() = ProviderHealth(loaded, if (loaded) "ok" else "未 load")

    override suspend fun generate(request: GenerateRequest): Result<GenerateResult> =
        withContext(Dispatchers.IO) {
            check(loaded) { "先 load 再 generate（provider 生命周期）" }
            // ★ 多模态（2026-10-19）：Anthropic 轨暂未接通图片。
            //   必须**显式失败**，不能静默丢图（否则模型"看不见图"却继续答，用户以为它看过）。
            if (request.images.isNotEmpty()) {
                return@withContext Result.failure(
                    UnsupportedOperationException(
                        "当前 Anthropic 后端暂不支持读图（已接通 OpenAI 兼容轨）；" +
                            "请换用 OpenAI 兼容提供商，或移除图片后重试。",
                    ),
                )
            }
            runCatching {
                val body = buildBody(
                    messages = request.messages ?: listOf(
                        ChatMessage(ChatRole.USER, request.prompt),
                    ),
                    maxOutputTokens = request.maxOutputTokens,
                    stream = false,
                    tools = request.tools,
                )
                val resp = HttpJson.postText(
                    "$baseUrl/v1/messages",
                    body.toString(),
                    headers = authHeaders(),
                    timeout = requestTimeout,
                )
                parseResponse(resp)
            }
        }

    override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
        check(loaded) { "先 load 再 generateStream（provider 生命周期）" }
        if (request.images.isNotEmpty()) {
            error("当前 Anthropic 后端暂不支持读图（已接通 OpenAI 兼容轨）；请换用 OpenAI 兼容提供商")
        }
        val body = buildBody(
            messages = request.messages ?: listOf(
                ChatMessage(ChatRole.USER, request.prompt),
            ),
            maxOutputTokens = request.maxOutputTokens,
            stream = true,
            tools = request.tools,
        )
        // Anthropic 的 SSE 事件流：content_block_delta 带 text_delta /
        // thinking_delta（思考）；content_block_start + input_json_delta 是**工具调用分片**；
        // message_delta 带 stop_reason 与用量
        //
        // ★ 分片归并（ADR-031 step 2）：按 **content block index** 归并，`partial_json` 拼接。
        val toolCalls = AnthropicToolCalls()
        var stopReason: FinishReason? = null
        var terminalEmitted = false
        HttpJson.postSse(
            url = "$baseUrl/v1/messages",
            body = body.toString(),
            headers = authHeaders(),
            timeout = Duration.ofSeconds(Contract.Stream.CHUNK_IDLE_TIMEOUT_SECONDS),
        ).collect { event ->
            val root = runCatching { JsonHolder.parse(event.payload) }.getOrNull()
                ?: return@collect
            when (root.get("type")?.asString) {
                "error" -> error(root.getAsJsonObject("error")?.get("message")?.asString ?: "流错误")
                // ★ 工具调用块的开始：这里才有 id / name（与 OpenAI 的"首片"同语义）
                "content_block_start" -> {
                    val block = root.getAsJsonObject("content_block") ?: return@collect
                    if (block.get("type")?.asString == "tool_use") {
                        toolCalls.onBlockStart(
                            index = root.get("index")?.takeIf { !it.isJsonNull }?.asInt ?: 0,
                            id = block.get("id")?.takeIf { !it.isJsonNull }?.asString,
                            name = block.get("name")?.takeIf { !it.isJsonNull }?.asString,
                            input = block.get("input"),
                        )
                    }
                }
                "content_block_delta" -> {
                    val delta = root.getAsJsonObject("delta") ?: return@collect
                    // ★ 参数分片：**只拼接、不解析**（任一单片都不是合法 JSON）
                    if (delta.get("type")?.asString == "input_json_delta") {
                        toolCalls.onJsonDelta(
                            index = root.get("index")?.takeIf { !it.isJsonNull }?.asInt ?: 0,
                            partialJson = delta.get("partial_json")?.takeIf { !it.isJsonNull }?.asString,
                        )
                        return@collect
                    }
                    // 思考与正文分开（与 OpenAI 路径的双轨同语义）
                    val text = delta.get("text")?.takeIf { !it.isJsonNull }?.asString ?: ""
                    val reasoning = delta.get("thinking")?.takeIf { !it.isJsonNull }?.asString ?: ""
                    if (text.isNotEmpty() || reasoning.isNotEmpty()) {
                        emit(StreamChunk(deltaText = text, deltaReasoning = reasoning))
                    }
                }
                "message_delta" -> {
                    val stop = root.getAsJsonObject("delta")?.get("stop_reason")?.asString
                    if (stop != null) {
                        stopReason = when (stop) {
                            // ★ `tool_use` 必须映射（老代码不认它 ⇒ 落到 STOP ⇒
                            //   "模型要调工具"在链路上彻底不可见）
                            "tool_use" -> FinishReason.TOOL_CALLS
                            "max_tokens" -> FinishReason.LENGTH
                            "end_turn", "stop_sequence" -> FinishReason.STOP
                            else -> FinishReason.ERROR
                        }
                    }
                    // ★ 终止块**只能出一个**（`AgentLoop` 看到 done 即收流）：
                    //   stop_reason 到齐时落块，并把**拼好的**调用一起带走。
                    if (stop != null && !terminalEmitted) {
                        terminalEmitted = true
                        emit(StreamChunk.done(stopReason ?: FinishReason.STOP, toolCalls.assembled()))
                    }
                }
                "message_stop" -> if (!terminalEmitted) {
                    terminalEmitted = true
                    val calls = toolCalls.assembled()
                    emit(
                        StreamChunk.done(
                            stopReason ?: if (calls.isNotEmpty()) FinishReason.TOOL_CALLS else FinishReason.STOP,
                            calls,
                        ),
                    )
                }
            }
        }

        // ★ 兜底：流提前结束（服务端没发 message_stop）时仍要交出终止块 ——
        //   否则 AgentLoop 会把"模型要调工具"当成"模型什么都没说"（静默失败）。
        if (!terminalEmitted) {
            val calls = toolCalls.assembled()
            emit(
                StreamChunk.done(
                    stopReason ?: if (calls.isNotEmpty()) FinishReason.TOOL_CALLS else FinishReason.STOP,
                    calls,
                ),
            )
        }
    }

    // ------------------------------------------------------ 请求体

    private fun buildBody(
        messages: List<ChatMessage>,
        maxOutputTokens: Int,
        stream: Boolean,
        tools: List<ToolSpec> = emptyList(),
    ): JsonObject = JsonObject().apply {
        addProperty("model", modelName)
        addProperty("max_tokens", maxOf(maxOutputTokens, 1)) // Anthropic 必填且 ≥1

        // system 与对话分离（Anthropic 的顶层 system 字段）
        val sys = messages.filter { it.role == ChatRole.SYSTEM }.joinToString("\n") { it.content }
        if (sys.isNotEmpty()) addProperty("system", sys)

        add("messages", JsonArray().apply {
            for (m in messages) {
                when (m.role) {
                    ChatRole.SYSTEM -> { /* 已并入顶层 system */ }
                    ChatRole.USER -> add(msgObj("user", m.content))
                    // ★★ 原生轨（ADR-031 step 2 硬前置 1）★★
                    //   assistant 轮发起过调用 ⇒ 必须回成 `tool_use` 块，
                    //   **`input` 是对象**（不是 JSON 字符串）。
                    ChatRole.ASSISTANT -> add(
                        if (m.nativeCalls.isEmpty()) msgObj("assistant", m.content)
                        else assistantWithToolUse(m)
                    )
                    // 工具结果：Anthropic 用 user 轮 + `tool_result` 块回传
                    //（`tool_use_id` 必须与 assistant 里那个 `tool_use.id` 逐字相同）
                    //
                    // ⚠️ 判别靠 `toolCallId`：为 null = 文本轨（阶段一的 JSON 文本协议），
                    //   继续走纯文本 user 消息 —— **一字节不变**。
                    ChatRole.TOOL -> add(
                        if (m.toolCallId == null) msgObj("user", m.content)
                        else toolResultMsg(m)
                    )
                }
            }
        })

        if (stream) addProperty("stream", true)

        // ★ 原生 `tools`（ADR-031 决策 2 请求侧）：Anthropic 形状 = `{name,description,input_schema}`
        //   且**不套 `function` 外层**（照抄 OpenAI 形状会 400）。
        //   空列表 ⇒ 不加这个键，请求体与改动前逐字节相同。
        if (tools.isNotEmpty()) {
            add("tools", NativeToolSchema.anthropic(tools))
        }

        // 思考控制：Anthropic 的 thinking 对象。阶段一按「关思考」处理
        //（与本地路径的默认一致），后续接 ReasoningLevel 再展开。
        // ⚠️ 只有新版模型接受 adaptive；旧模型要 enabled+budget。
        //    为稳妥先不发送 thinking 字段（默认即关）。
    }

    private fun msgObj(role: String, content: String) = JsonObject().apply {
        addProperty("role", role)
        addProperty("content", content)
    }

    /**
     * assistant 轮的**原生形状**（ADR-031 step 2）：
     * `content = [{type:"text"}, {type:"tool_use", id, name, input}]`。
     *
     * ⚠️ 与 OpenAI 最大的形状差异：`input` 必须是**对象**，不是 JSON 字符串 ——
     * 把字符串塞进去会被判非法（这正是"照抄 OpenAI 形状会 400"的另一半）。
     */
    private fun assistantWithToolUse(m: ChatMessage) = JsonObject().apply {
        addProperty("role", "assistant")
        add("content", JsonArray().apply {
            if (m.content.isNotEmpty()) {
                add(JsonObject().apply {
                    addProperty("type", "text")
                    addProperty("text", m.content)
                })
            }
            m.nativeCalls.forEach { c ->
                add(JsonObject().apply {
                    addProperty("type", "tool_use")
                    addProperty("id", c.id)
                    addProperty("name", c.tool)
                    add("input", inputOf(c.argumentsJson))
                })
            }
        })
    }

    /**
     * 工具结果的**原生形状**：user 轮 + `tool_result` 块。
     *
     * `is_error` 如实传 —— 把失败写成成功，模型会在错的前提上继续做事。
     */
    private fun toolResultMsg(m: ChatMessage) = JsonObject().apply {
        addProperty("role", "user")
        add("content", JsonArray().apply {
            add(JsonObject().apply {
                addProperty("type", "tool_result")
                addProperty("tool_use_id", m.toolCallId ?: "")
                addProperty("content", m.content)
                if (m.isError) addProperty("is_error", true)
            })
        })
    }

    /**
     * `arguments` 原文 → `input` **对象**。
     *
     * 解析不了就退化成空对象：这里**绝不编造参数** —— 参数合不合法由上层
     * 判定（`AgentOutputParser.fromNativeCall`）；本层只负责"把 wire 事实摆成对方要的形状"。
     */
    private fun inputOf(json: String): com.google.gson.JsonElement =
        runCatching { com.google.gson.JsonParser.parseString(json.ifBlank { "{}" }) }
            .getOrNull()
            ?.takeIf { it.isJsonObject }
            ?: JsonObject()

    private fun parseResponse(resp: String): GenerateResult {
        val root = JsonHolder.parse(resp)
        // ★ 判型（2026-10-14）：`{"error": null}` 时 getAsJsonObject 会崩
        root.get("error")?.takeIf { it.isJsonObject }?.asJsonObject?.let {
            error("Anthropic 错误：" + (it.get("message")?.asString ?: it.toString()))
        }
        // ★ 判型（2026-10-14）：内容块数组里可能有非对象项
        val text = root.getAsJsonArray("content")
            ?.filter { it.isJsonObject && it.asJsonObject.get("type")?.asString == "text" }
            ?.joinToString("") { it.asJsonObject.get("text")?.asString ?: "" }
            ?: ""
        // ★ 原生调用（非流式）：`content[]` 里 `type=="tool_use"` 的块
        val calls = NativeCalls.fromAnthropicContent(root)
        // 停止原因映射
        val finish = when (root.get("stop_reason")?.asString) {
            "end_turn" -> FinishReason.STOP
            "max_tokens" -> FinishReason.LENGTH
            "stop_sequence" -> FinishReason.STOP
            // ★ `tool_use`（老代码没这一支 ⇒ 有个工具调用却报 STOP）
            "tool_use" -> FinishReason.TOOL_CALLS
            // 缺 stop_reason 时按"有没有调用"判，不许把工具调用当成正常结束
            null -> if (calls.isNotEmpty()) FinishReason.TOOL_CALLS else FinishReason.STOP
            else -> FinishReason.ERROR
        }
        val usage = root.getAsJsonObject("usage")
        return GenerateResult(
            text = text,
            // ★ Anthropic 的 token 字段名与 OpenAI 不同：
            //   input_tokens / output_tokens / cache_read_input_tokens
            cache = CacheStats(
                cachedTokens = usage?.get("cache_read_input_tokens")?.takeIf { !it.isJsonNull }?.asInt,
                promptTokens = usage?.get("input_tokens")?.asInt ?: 0,
                outputTokens = usage?.get("output_tokens")?.asInt ?: 0,
            ),
            finishReason = finish,
            toolCalls = calls,
        )
    }

    private fun authHeaders() = mapOf(
        "x-api-key" to apiKey,
        "anthropic-version" to "2023-06-01",
    )

    /** 简易 JSON 持有（避免 provider-http 的内部对象跨类依赖）。 */
    private object JsonHolder {
        private val parser = com.google.gson.JsonParser()
        fun parse(s: String) = parser.parse(s).asJsonObject
    }

    companion object {
        const val DEFAULT_BASE_URL = "https://api.anthropic.com"
    }
}
