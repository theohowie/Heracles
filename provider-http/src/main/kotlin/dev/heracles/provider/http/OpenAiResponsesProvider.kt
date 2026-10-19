package dev.heracles.provider.http

import com.google.gson.JsonArray
import com.google.gson.JsonObject
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
import dev.heracles.core.provider.StreamChunk
import dev.heracles.core.provider.FinishReason
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import java.time.Duration

/**
 * **OpenAI Responses 协议的 provider**（2026-10-14，用户要求真实支持）。
 *
 * ## 与 Chat Completions 的差异（为什么要独立类）
 *
 * | 项 | Chat Completions | **Responses** |
 * |---|---|---|
 * | 端点 | `/v1/chat/completions` | **`/v1/responses`** |
 * | 历史形态 | `messages[]` | **`input[]`**（typed items）|
 * | 系统提示 | `messages[0] role=system` | **顶层 `instructions`** |
 * | 正文 | `choices[0].message.content` | **`output[]` 里 `type:"message"` 块** |
 * | 上限 | `max_tokens` | **`max_output_tokens`**（`max_tokens` 会 400）|
 * | JSON 模式 | `response_format` | **`text.format`**（⚠️ **未实现**，见下「约束解码」）|
 * | 流结束 | `data: [DONE]` | **`response.completed` 事件**（无 [DONE]）|
 *
 * ## 范围（诚实声明）
 *
 * 本实现覆盖 Heracles 需要的核心面：文本生成（流式/非流式）、
 * instructions、max_output_tokens、input 数组。
 * **不覆盖**：原生 web_search / background 模式 / previous_response_id
 * 续传（那需要服务端存储语义，与 AgentLoop 的 append-only 会话管理是
 * 两条路）。需要时再扩展，不在注释里假装支持。
 *
 * ## ⚠️ 约束解码：**没有**（2026-10-18 校准，**已知债务**）
 *
 * 上表那行的 `text.format` **本实现没有发** —— 全类**不读** `request.structuredOutput`。
 * 注意 `buildBody` 收的是**整个** `GenerateRequest` ⇒ 它**读得到**，今天只是没读
 * （这属于"**会漂移**"，与 [AnthropicProvider] 那种"结构上不可能"不同；
 * `NativeToolsRequestTest.responsesHasTheSeamButDoesNotUseItYet` 把这条差别钉住了）。
 * ⇒ 走 Responses 这条云路径时，**约束解码实际是"没有"**，只靠提示词 + 输出校验，
 * 与 `02-契约规范.md` §6「云端降级成 `json_object`」**不符**。
 *
 * ⚠️ 这是**缺口，不是设计**。**本轮不补**：补它 = 改 wire 行为 + 真 Key 验证 = **新的未验面**，
 * 而这一轮的真机/真 Key 证据本来就都空着（见 `docs/27` §7.2）。补的时候**必须同时**做两件事：
 * ① 原生 `tools` 非空 ⇒ **不发**约束解码（互斥；三家断言见 `NativeToolsRequestTest` 第 6 节）；
 * ② 真 Key 实测 `text.format` 被接受、且模型行为符合预期（**未验**）。
 *
 * ## 鉴权
 *
 * `Authorization: Bearer <key>`（与 Chat Completions 相同 ——
 * Responses 是 OpenAI 自家协议，不是 Anthropic 那种独立头）。
 */
class OpenAiResponsesProvider(
    override val id: String,
    private val baseUrl: String,
    private val apiKey: String,
    private val modelName: String,
    private val instructions: String = "",
    private val requestTimeout: Duration = Duration.ofMinutes(15),
) : ModelProvider {

    override val kind: ProviderKind = ProviderKind.CLOUD

    override val capabilities: ProviderCapabilities = ProviderCapabilities(
        supportsGrammar = false,
        supportsJsonSchema = true,
        supportsPrefixCache = false,
        needsPrewarm = false,
        cacheBlockTokens = 0,
        // ★ 能力声明（ADR-031 决策 2）：Responses 的 `tools` 是**扁平**形状（无 `function` 外层）。
        //   ⚠️ "有能力" ≠ "已在发" —— 响应侧解析（step 2）没落地前不许打开。
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
            // ★ 多模态（2026-10-19）：Responses 轨暂未接通图片 —— 显式失败，不静默丢图。
            if (request.images.isNotEmpty()) {
                return@withContext Result.failure(
                    UnsupportedOperationException(
                        "当前 Responses 后端暂不支持读图（已接通 OpenAI 兼容轨）；" +
                            "请换用 OpenAI 兼容提供商，或移除图片后重试。",
                    ),
                )
            }
            runCatching {
                val resp = HttpJson.postText(
                    "$baseUrl/v1/responses",
                    buildBody(request, stream = false).toString(),
                    headers = authHeaders(),
                    timeout = requestTimeout,
                )
                parseResponse(resp)
            }
        }

    override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
        check(loaded) { "先 load 再 generateStream（provider 生命周期）" }
        if (request.images.isNotEmpty()) {
            error("当前 Responses 后端暂不支持读图（已接通 OpenAI 兼容轨）；请换用 OpenAI 兼容提供商")
        }
        // ★ 原生调用分片（ADR-031 step 2）：按 `item_id` 归并，`output_item.done` **权威**
        val toolCalls = ResponsesToolCalls()
        var terminalEmitted = false

        suspend fun emitTerminal(reason: FinishReason) {
            if (terminalEmitted) return
            terminalEmitted = true
            val calls = toolCalls.assembled()
            // `response.completed` 的字面意思是"响应对象完整了"，但**有函数调用项**时
            // 真实语义是"模型请求了工具" ⇒ 必须报 TOOL_CALLS，
            // 否则上层分不清"要调工具"与"正常结束"（静默失败）。
            val effective = if (reason == FinishReason.STOP && calls.isNotEmpty()) {
                FinishReason.TOOL_CALLS
            } else {
                reason
            }
            emit(StreamChunk.done(effective, calls))
        }

        HttpJson.postSse(
            url = "$baseUrl/v1/responses",
            body = buildBody(request, stream = true).toString(),
            headers = authHeaders(),
            timeout = Duration.ofMinutes(5),
        ).collect { event ->
            val root = runCatching { JsonHolder.parse(event.payload) }.getOrNull()
                ?: return@collect
            when (root.get("type")?.asString) {
                // 流式正文增量
                "response.output_text.delta" -> {
                    val t = root.get("delta")?.takeIf { !it.isJsonNull }?.asString ?: ""
                    if (t.isNotEmpty()) emit(StreamChunk(deltaText = t))
                }
                // ★ 工具调用项出现：这里才有 id / name
                "response.output_item.added" -> {
                    val item = root.getAsJsonObject("item") ?: return@collect
                    if (item.get("type")?.asString == "function_call") {
                        toolCalls.onItemAdded(
                            itemId = item.get("id")?.takeIf { !it.isJsonNull }?.asString ?: "",
                            callId = item.get("call_id")?.takeIf { !it.isJsonNull }?.asString,
                            name = item.get("name")?.takeIf { !it.isJsonNull }?.asString,
                        )
                    }
                }
                // ★ 参数分片：**只拼接、不解析**（任一单片都不是合法 JSON）
                "response.function_call_arguments.delta" -> {
                    toolCalls.onArgsDelta(
                        itemId = root.get("item_id")?.takeIf { !it.isJsonNull }?.asString ?: "",
                        delta = root.get("delta")?.takeIf { !it.isJsonNull }?.asString,
                    )
                }
                // ★ 权威事件：带完整 `arguments`，与累积值不一致时**以它为准**
                "response.output_item.done" -> {
                    val item = root.getAsJsonObject("item") ?: return@collect
                    if (item.get("type")?.asString == "function_call") {
                        toolCalls.onItemDone(
                            itemId = item.get("id")?.takeIf { !it.isJsonNull }?.asString ?: "",
                            callId = item.get("call_id")?.takeIf { !it.isJsonNull }?.asString,
                            name = item.get("name")?.takeIf { !it.isJsonNull }?.asString,
                            arguments = item.get("arguments")?.takeIf { !it.isJsonNull }?.asString,
                        )
                    }
                }
                // 失败事件（流开始后才失败的场景）
                "error" -> error(root.get("message")?.asString ?: "流错误")
                // 终止事件（无 [DONE]，靠它收尾）
                "response.completed" -> emitTerminal(FinishReason.STOP)
                // ★ `incomplete` 是**被截断**，不是正常结束（F7c 修既有债务）：
                //   老代码把两个事件都写成 STOP ⇒ "输出被截断"在链路上**不可见**。
                "response.incomplete" -> emitTerminal(FinishReason.LENGTH)
                "response.failed" -> {
                    error(
                        root.getAsJsonObject("response")?.getAsJsonObject("error")
                            ?.get("message")?.asString ?: "response.failed"
                    )
                }
            }
        }

        // ★ 兜底：流提前结束（没发 completed/incomplete）也要交出终止块，
        //   否则原生调用会**静默丢失**（AgentLoop 把"要调工具"当成"什么都没说"）。
        emitTerminal(FinishReason.STOP)
    }

    // ------------------------------------------------------ 请求体

    private fun buildBody(request: GenerateRequest, stream: Boolean): JsonObject =
        JsonObject().apply {
            addProperty("model", modelName)

            // messages → instructions（系统）+ input（对话）
            val msgs = request.messages
                ?: listOf(ChatMessage(ChatRole.USER, request.prompt))
            val sys = msgs.filter { it.role == ChatRole.SYSTEM }.joinToString("\n") { it.content }
            if (sys.isNotEmpty() || instructions.isNotEmpty()) {
                addProperty(
                    "instructions",
                    listOf(instructions, sys).filter { it.isNotEmpty() }.joinToString("\n\n"),
                )
            }

            add("input", JsonArray().apply {
                for (m in msgs) {
                    when (m.role) {
                        ChatRole.SYSTEM -> { /* 已并入 instructions */ }
                        // ★★ 原生轨（ADR-031 step 2 硬前置 1）★★
                        //   Responses 把函数调用与结果放在**顶层 item**（不是 message 字段）：
                        //     · 发起调用 = `function_call` 项（带 `call_id`）
                        //     · 工具结果 = `function_call_output` 项（`call_id` 必须逐字相同）
                        //   文本轨：`nativeCalls` 空 ⇒ 与改动前逐字节相同的 message 项。
                        ChatRole.ASSISTANT -> {
                            if (m.content.isNotEmpty() || m.nativeCalls.isEmpty()) {
                                add(messageItem("assistant", m.content))
                            }
                            m.nativeCalls.forEach { c ->
                                add(JsonObject().apply {
                                    addProperty("type", "function_call")
                                    addProperty("call_id", c.id)
                                    addProperty("name", c.tool)
                                    addProperty("arguments", c.argumentsJson)
                                })
                            }
                        }
                        ChatRole.TOOL -> add(JsonObject().apply {
                            addProperty("type", "function_call_output")
                            addProperty("call_id", m.toolCallId ?: "")
                            addProperty("output", m.content)
                        })
                        else -> add(messageItem("user", m.content))
                    }
                }
            })

            // ⚠️ Responses 用 max_output_tokens —— 传 max_tokens 会 400
            addProperty("max_output_tokens", request.maxOutputTokens)
            if (stream) addProperty("stream", true)

            // ★ 原生 `tools`（ADR-031 决策 2 请求侧）：Responses 形状是**扁平**的
            //   （`{type,name,description,parameters}`，没有 `function` 外层）。
            //   空列表 ⇒ 不加这个键，请求体与改动前逐字节相同。
            if (request.tools.isNotEmpty()) {
                add("tools", NativeToolSchema.responses(request.tools))
            }
        }

    // ------------------------------------------------------ 响应解析

    private fun parseResponse(resp: String): GenerateResult {
        val root = JsonHolder.parse(resp)
        // ★ 判型（2026-10-14）：`{"error": null}` 时 getAsJsonObject 会崩
        root.get("error")?.takeIf { it.isJsonObject }?.asJsonObject?.let { e ->
            error(e.get("message")?.takeIf { !it.isJsonNull }?.asString ?: e.toString())
        }
        // 正文 = output[] 里 type=="message" 块的 content[] 中
        // type=="output_text" 的文本拼接（Responses 的嵌套形状）
        // ★ 每层都判型（聚合服务可能给出非对象项）
        val text = StringBuilder()
        val output = root.getAsJsonArray("output")
        output?.forEach { item ->
            if (!item.isJsonObject) return@forEach
            val obj = item.asJsonObject
            if (obj.get("type")?.asString == "message") {
                obj.getAsJsonArray("content")?.forEach { c ->
                    if (!c.isJsonObject) return@forEach
                    val co = c.asJsonObject
                    if (co.get("type")?.asString == "output_text") {
                        text.append(co.get("text")?.takeIf { !it.isJsonNull }?.asString ?: "")
                    }
                }
            }
        }
        val usage = root.get("usage")?.takeIf { it.isJsonObject }?.asJsonObject
        // ★ 原生调用（非流式）：`output[]` 里 `type=="function_call"` 的项
        val calls = NativeCalls.fromResponsesOutput(root)
        val status = mapStatus(root)
        return GenerateResult(
            text = text.toString(),
            cache = CacheStats(
                cachedTokens = null, // Responses 不报前缀缓存（除非配 prompt_cache_key）
                promptTokens = usage?.get("input_tokens")?.asInt ?: 0,
                outputTokens = usage?.get("output_tokens")?.asInt ?: 0,
            ),
            // ★ F7c 修既有债务：老代码恒为 STOP ⇒ `max_output_tokens` 截断在链路上查不到。
            //   Responses 的非流式响应给顶层 `status`（completed / incomplete / failed）。
            //
            //   并且：`completed` + 有 function_call 项 ⇒ 真实语义是"模型请求了工具"。
            finishReason = if (status == FinishReason.STOP && calls.isNotEmpty()) {
                FinishReason.TOOL_CALLS
            } else {
                status
            },
            toolCalls = calls,
        )
    }

    /**
     * Responses 顶层 `status` → [FinishReason]。
     *
     * `incomplete` 只可能来自 `incomplete_details.reason == "max_output_tokens"`，
     * 语义上就是**长度截断** ⇒ [FinishReason.LENGTH]。
     * 缺 `status` 时按 STOP（老/简化端点不给，不能因此判成错误）。
     */
    private fun mapStatus(root: JsonObject): FinishReason =
        when (root.get("status")?.takeIf { !it.isJsonNull }?.asString) {
            "completed" -> FinishReason.STOP
            "incomplete" -> FinishReason.LENGTH
            "failed" -> FinishReason.ERROR
            null -> FinishReason.STOP
            else -> FinishReason.ERROR
        }

    private fun authHeaders() = mapOf("Authorization" to "Bearer $apiKey")

    /** `input` 里的普通消息项（与改动前的形状**逐字段相同**）。 */
    private fun messageItem(role: String, content: String) = JsonObject().apply {
        addProperty("type", "message")
        addProperty("role", role)
        addProperty("content", content)
    }

    private object JsonHolder {
        fun parse(s: String) = com.google.gson.JsonParser.parseString(s).asJsonObject
    }
}
