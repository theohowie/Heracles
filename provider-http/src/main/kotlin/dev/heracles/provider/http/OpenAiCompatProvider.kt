package dev.heracles.provider.http

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.CacheStats
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.FinishReason
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
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import java.time.Duration

/**
 * 云端 OpenAI 兼容 provider —— **发行版的主用法**（`00-需求文档.md` §2.11）。
 *
 * 支持 DashScope / DeepSeek / Kimi / 智谱 / 任意自建 OpenAI 兼容端点。
 *
 * ## 与已删除的本地 provider 的差别（ADR-035 S3，**历史对照**）
 *
 * 本地后端（`LlamaServerProvider`）已于 2026-10-18 随 ADR-035 删除。
 * 下表保留的是"当年为什么两者 wire 形状不同"的**历史对照**，**不是现行实现**：
 *
 * | | 本地 provider（已删） | 本类 |
 * |---|---|---|
 * | 端点 | `/completion`（裸 prompt） | `/chat/completions`（chat template + 工具） |
 * | 缓存字段 | `timings.cache_n` | `usage.*`（各家不同，见 [CacheFieldMapper]） |
 * | 预热 | **必需**（本地有冷启动） | **可选**（无冷启动，但预热能省首次费用） |
 *
 * ## 契约注入（`02-契约规范.md` §5.2）
 *
 * `temperature=0` 由**本类内部**注入，调用方不需要也不允许设置 —— 否则铁律 3 会被悄悄绕过。
 *
 * ⚠️ **`enable_thinking` 已彻底退场**（2026-10-18，ADR-035 / S1a 起"默认不发"，
 * **S2 删掉字段本身**）：它是 **Qwen3 系专有字段**，而它此前被当成**通用默认**发往
 * **所有**云端端点 —— 中转站的 DeepSeek 见到它会 `HTTP 400: 深度思考参数互相冲突`
 * （用户实测，见下方"思考参数互斥"）。一个"给 Qwen 用的开关"默认发给所有人，
 * 是 F10 之前就存在的缺陷。**S2 之后本类不再有"关闭思考"这个能力**：
 * 思考档位只走标准字段 `reasoning_effort`（见 [reasoningLevel] 那一段）。
 *
 * ## ⚠️ 代价（不许淡化，ADR-035 风险表里挂着）
 *
 * DashScope / Qwen3 端点**默认开思考**，而它在本地方向实测过 **5.1 倍 slowdown**
 * （`实测-02`）。删掉字段后，**云端 Qwen3 端点失去了那个关思考的开关** ——
 * 想恢复必须做"**按端点**决定要不要发专有字段"（现在的 provider 拿不到"这是不是 DashScope"
 * 这个信息，靠 baseUrl 猜是脆的）。这是一次**能力删除，不是能力搬家**：标准字段
 * `reasoning_effort` 覆盖不了它（Qwen3 不认 / 认了也语义不同）。
 */

class OpenAiCompatProvider(
    override val id: String,
    private val baseUrl: String,
    private val apiKey: String,
    private val modelName: String,
    private val requestTimeout: Duration = Duration.ofMinutes(5),
    /**
     * 前缀缓存块大小。默认 1024 —— **DashScope 实测值**（`实测-07`）。
     *
     * 换 provider 必须重新实测：块大小不对会导致冻结区补齐到错误的边界，
     * 白花 token 且仍然不命中。
     */
    private val cacheBlockTokens: Int = 1024,
    /**
     * 流式下**两个 chunk 之间**的静默上限 —— 见 [Contract.Stream]。
     *
     * **不是整轮超时**：云端推理模型思考时可能几十秒不吐内容的 delta
     * （只发 `role` 心跳），设成整轮上限会误杀。
     */
    private val chunkIdleTimeout: Duration =
        Duration.ofSeconds(Contract.Stream.CHUNK_IDLE_TIMEOUT_SECONDS),
) : ModelProvider {

    override val kind: ProviderKind = ProviderKind.CLOUD

    override val capabilities: ProviderCapabilities = ProviderCapabilities(
        // 云端不支持 GBNF 语法约束 —— 只能靠 json_object + 提示词 + 输出校验
        supportsGrammar = false,
        supportsJsonSchema = true,
        // 前缀缓存由服务端自动处理，无需客户端参数
        supportsPrefixCache = true,
        // 云端无冷启动
        needsPrewarm = false,
        // 实测 DashScope 按 1024 token 块对齐（实测-07）。
        // 这是**实测值不是文档值** —— 换 provider 必须重新测。
        cacheBlockTokens = cacheBlockTokens,
        // ★ 能力声明（ADR-031 决策 2）：OpenAI 兼容端点收 `tools` 数组并回 `tool_calls`。
        //   ⚠️ 这只是"有能力"，**不等于已经在发** —— 发不发由 `AgentLoop(nativeToolsEnabled=…)`
        //   决定；响应侧解析（ADR-031 step 2）没落地前不许打开。
        supportsNativeTools = true,
    )

    private var loaded = false

    /** 累计用量 —— FR-10.5 的成本记账基础 */
    var totalCachedTokens: Int = 0
        private set
    var totalPromptTokens: Int = 0
        private set
    var totalOutputTokens: Int = 0
        private set

    /**
     * 最近一次**已发出**的请求体 —— 供测试断言 `reasoning_effort` 是否注入。
     *
     * 该字段若写错，云端**不会报错**，只是静默地不思考或一直思考 ——
     * 属于"看不见的退化"，必须有断言守卫。
     */
    var lastRequestBody: JsonObject? = null
        private set

    /**
     * 流式一轮的缓存记账 —— 云端把 `usage` 放在**末块**（需 `stream_options`）。
     *
     * 流式**不改变记账口径**：`CacheFieldMapper` 照样归一化，
     * 各家的字段差异（`cached_tokens` / `prompt_cache_hit_tokens` …）
     * 仍由那一处统一处理 —— 这也是它单独成文件的理由。
     */
    private var streamCache: CacheStats = CacheStats.withoutCacheReporting(0, 0)

    override fun lastStreamCache(): CacheStats = streamCache

    override suspend fun load(config: ProviderConfig): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            require(apiKey.isNotBlank()) { "apiKey 为空 —— 云端后端必须配置 Key" }
            // 用最小请求探活，顺便验证模型名拼写
            callChatOnce(
                messages = listOf(ChatMessage(ChatRole.USER, "hi")),
                maxOutputTokens = 1,
                structured = null,
            )
            loaded = true
        }
    }

    /**
     * 预热 —— 云端**没有冷启动**，但**缓存键必须完全匹配**。
     *
     * ## 为什么要发两条消息（2026-10-09 `实测-08` 修正）
     *
     * 首版实现只发 `[SYSTEM(prefix)]` 一条消息，结果 AgentLoop 里
     * 5 轮**全部 0% 命中** —— 而同期探针（发 `[SYSTEM, USER]` 两条）
     * 第 2 次就稳定命中 87.7%。
     *
     * 说明**消息数组的结构参与缓存键**：
     * 一条消息的请求**无法**为两条消息的请求建立缓存。
     *
     * 修法：预热请求与真实请求**保持相同的消息结构**
     * （`[SYSTEM(冻结区), USER(短问)]`），让服务端缓存的前缀
     * 与真实请求逐字节一致。
     */
    override suspend fun prewarm(frozenPrefix: String): Result<Unit> {
        if (!loaded) return Result.failure(IllegalStateException("必须先 load()"))
        if (frozenPrefix.isBlank()) return Result.success(Unit)
        return callChatOnce(
            // 结构与真实请求对齐：SYSTEM(冻结区) + USER
            messages = listOf(
                ChatMessage(ChatRole.SYSTEM, frozenPrefix),
                ChatMessage(ChatRole.USER, WARMUP_MARKER),
            ),
            maxOutputTokens = 1,
            structured = null,
        ).map { }
    }

    override suspend fun generate(request: GenerateRequest): Result<GenerateResult> {
        if (!loaded) return Result.failure(IllegalStateException("必须先 load()"))

        val messages = request.messages ?: listOf(ChatMessage(ChatRole.USER, request.prompt))
        return callChatOnce(
            messages,
            request.maxOutputTokens,
            request.structuredOutput,
            request.tools,
            request.images,
        ).map { (result, _) -> result }
    }

    /**
     * **流式**生成 —— 逐 token 产出（`25-流式工作步骤.md` §5.2）。
     *
     * ## 思考档位（本地 provider 已删，现在只有云端这一条路）
     *
     * 本地 provider 的两态开关（`chat_template_kwargs.enable_thinking`）随 ADR-035 S3 一起删除；
     * 现在**唯一**的表达方式是 `reasoning_effort`（分档，DeepSeek / DashScope 等认它）。
     *
     * 云端支持 `reasoning_effort` 分档，
     * 所以这里能把用户选的档位**如实**传下去。
     *
     * ## `reasoning_effort` 的取值
     *
     * - `AUTO` → **不传该字段**（让服务端用自己的默认，这是最诚实的选择：
     *   传一个我们并不理解的 `"auto"` 反而可能被某些端点当非法值拒绝）
     * - `OFF` → **也不传**（S2 起就是"什么都不发"）。⚠️ 这**不等于**"关掉了思考"：
     *   我们只是不表达偏好。S1a 之前这里还会发 Qwen3 专有的 `enable_thinking:false`，
     *   而那正是"给 DeepSeek 发 Qwen 字段 ⇒ 400"的缺陷根源（字段与能力都已删除，
     *   见类 KDoc 的"代价"段：DashScope 现在**没有**关思考的开关）。
     * - `LOW/HIGH/MAX` → 对应 `reasoning_effort` 字符串；
     *   `MAX` 在部分端点无此档，退化为 `"high"`
     */
    override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
        check(loaded) { "必须先 load()" }
        val messages = request.messages ?: listOf(ChatMessage(ChatRole.USER, request.prompt))
        val body = buildRequestBody(
            messages = messages,
            maxOutputTokens = request.maxOutputTokens,
            structured = request.structuredOutput,
            stream = true,
            reasoning = request.reasoning,
            tools = request.tools,
            images = request.images,
        )
        lastRequestBody = body

        var finishReason: FinishReason? = null
        var usage: JsonObject? = null
        var sawAny = false
        // ★ 原生调用分片归并（ADR-031 step 2）—— 只拼接，不解析（见 NativeCallAssembler）
        val toolCalls = OpenAiToolCalls()

        HttpJson.postSse(
            url = "${baseUrl.trimEnd('/')}/chat/completions",
            body = body.toString(),
            headers = mapOf("Authorization" to "Bearer $apiKey"),
            timeout = chunkIdleTimeout,
        ).collect { event ->
            val root = runCatching { JsonParser.parseString(event.payload).asJsonObject }.getOrNull()
                ?: return@collect // 非 JSON 的心跳块，跳过（一行坏数据不该杀掉整轮）

            // ★★ 错误分支的强转也必须判型（2026-10-14 真机崩溃真凶）★★
            //
            // 崩溃栈：com.google.gson.JsonNull cannot be cast to JsonObject
            //
            // 旧代码：`root.has("error")` 为 true 就调
            // `root.getAsJsonObject("error")` —— 但 `has` 对
            // `{"error": null}` **返回 true**，而 `getAsJsonObject`
            // 遇到 `JsonNull` 会**直接抛 ClassCastException**。
            //
            // 聚合服务（基元律动等）返回错误时正是这个形状 ——
            // UI 上看到的就是这行 Java 异常，而不是人话。
            //
            // 现在：只要是错误形状就读出**人话**再抛；
            // `error` 不是对象（null / 字符串）也要能报出来。
            if (root.has("error")) {
                val errEl = root.get("error")
                val msg = when {
                    errEl == null || errEl.isJsonNull -> "服务端返回了空错误对象"
                    errEl.isJsonObject -> errEl.asJsonObject.get("message")
                        ?.takeIf { !it.isJsonNull }?.asString ?: errEl.toString()
                    errEl.isJsonPrimitive -> errEl.asString
                    else -> errEl.toString()
                }
                // 有些服务把 code/message 放在顶层（基元律动的 401 形状）
                val top = root.get("message")?.takeIf { !it.isJsonNull }?.asString
                error("云端错误：" + (top ?: msg))
            }

            // ★ usage 判型（`"usage": null` 会崩）
            root.get("usage")?.takeIf { it.isJsonObject }?.asJsonObject?.let { usage = it }

            // ★★ 防御式取值（2026-10-14，与 parseChatResponse 同一批修复）★★
            //
            // 聚合服务的流式块可能带 `"choices":[null]` 或 choice 缺 delta ——
            // Gson 的 asJsonObject 对 JsonNull 直接 ClassCastException。
            // 一行坏数据**跳过**，绝不杀整轮。
            val choicesArr = root.getAsJsonArray("choices")
            val firstEl = choicesArr?.firstOrNull()
            val choice = if (firstEl != null && firstEl.isJsonObject) firstEl.asJsonObject else null
            if (choice == null) return@collect
            choice.get("finish_reason")?.takeIf { !it.isJsonNull }?.asString
                ?.let { finishReason = mapFinishReason(it) }

            val delta = choice.get("delta")?.takeIf { it.isJsonObject }?.asJsonObject ?: return@collect
            val text = delta.stringOrEmpty("content")
            // ★ 思考与正文分开；云端字段名有两种写法，都认
            val reasoning = delta.stringOrEmpty("reasoning_content")
                .ifEmpty { delta.stringOrEmpty("reasoning") }

            if (text.isNotEmpty() || reasoning.isNotEmpty()) {
                sawAny = true
                emit(StreamChunk(deltaText = text, deltaReasoning = reasoning))
            }

            // ★★ 原生调用分片（ADR-031 step 2）★★
            //
            // 与正文**同一个 delta** 里到达（首片给 id/name，之后只给 arguments 碎片）。
            // 这里**只拼接**：任一单片都不是合法 JSON，"攒齐再 parse"是硬规则。
            // thinking/reasoning 增量绝不并入 arguments —— 结构上保证：这段代码
            // 只读 `delta.tool_calls[]`，碰不到 text/reasoning。
            delta.getAsJsonArray("tool_calls")?.forEachIndexed { i, el ->
                if (el == null || !el.isJsonObject) return@forEachIndexed
                val tc = el.asJsonObject
                val idx = tc.get("index")?.takeIf { !it.isJsonNull }?.asInt ?: i
                val fn = tc.get("function")?.takeIf { it.isJsonObject }?.asJsonObject
                toolCalls.onDelta(
                    index = idx,
                    id = tc.stringOrEmpty("id").ifEmpty { null },
                    name = fn?.stringOrEmpty("name")?.ifEmpty { null },
                    argsFragment = fn?.stringOrEmpty("arguments")?.ifEmpty { null },
                )
                sawAny = true
            }
        }

        // 会计入账：流式不改变记账口径（仍是一次请求，只是分块接收）
        usage?.let { u ->
            val cache = CacheFieldMapper.auto(u)
            totalCachedTokens += cache.cachedTokens ?: 0
            totalPromptTokens += cache.promptTokens
            totalOutputTokens += cache.outputTokens
            streamCache = cache
        }

        // ★★ 终止块是原生调用**唯一**的落脚点（`AgentLoop` 看到 done 即收流）★★
        //   聚合服务可能不给 `finish_reason` ⇒ 有调用时必须报 TOOL_CALLS，
        //   否则"模型要调工具"会退化成 STOP/ERROR，链路上**再也查不到**（静默失败）。
        val assembled = toolCalls.assembled()
        val effective = finishReason
            ?: when {
                assembled.isNotEmpty() -> FinishReason.TOOL_CALLS
                sawAny -> FinishReason.STOP
                else -> FinishReason.ERROR
            }
        emit(StreamChunk.done(effective, assembled))
    }

    private fun JsonObject.stringOrEmpty(field: String): String =
        get(field)?.takeIf { !it.isJsonNull }?.asString.orEmpty()

    private fun mapFinishReason(raw: String): FinishReason = when (raw) {
        "stop" -> FinishReason.STOP
        "length" -> FinishReason.LENGTH
        "tool_calls" -> FinishReason.TOOL_CALLS
        else -> FinishReason.ERROR
    }

    override suspend fun release() {
        loaded = false
    }

    override fun health(): ProviderHealth =
        ProviderHealth(loaded, if (loaded) "$modelName @ $baseUrl" else "not loaded")

    // ---------------------------------------------------------------- 内部

    private suspend fun callChatOnce(
        messages: List<ChatMessage>,
        maxOutputTokens: Int,
        structured: StructuredSpec?,
        tools: List<ToolSpec> = emptyList(),
        images: List<String> = emptyList(),
    ): Result<Pair<GenerateResult, JsonObject>> = withContext(Dispatchers.IO) {
        runCatching {
            val body = buildRequestBody(
                messages, maxOutputTokens, structured,
                stream = false,
                // 非流式路径仍然默认关思考（铁律 3）：它是既有 CLI/测试在走的路径，
                // 行为不得因为本次改动而变化。想看思考流请走 generateStream()。
                reasoning = ReasoningLevel.OFF,
                tools = tools,
                images = images,
            )
            val json = HttpJson.postJson(
                url = "${baseUrl.trimEnd('/')}/chat/completions",
                body = body.toString(),
                headers = mapOf(
                    "Authorization" to "Bearer $apiKey",
                    // DashScope 要求显式声明异步；缺失时某些模型会走 SSE 分支
                    "Accept" to "application/json",
                ),
                timeout = requestTimeout,
            )
            parseChatResponse(json) to json
        }
    }

    private fun buildRequestBody(
        messages: List<ChatMessage>,
        maxOutputTokens: Int,
        structured: StructuredSpec?,
        stream: Boolean = false,
        reasoning: ReasoningLevel = ReasoningLevel.AUTO,
        tools: List<ToolSpec> = emptyList(),
        images: List<String> = emptyList(),
    ): JsonObject = JsonObject().apply {
        addProperty("model", modelName)
        add("messages", JsonArray().apply {
            messages.forEach { m ->
                add(JsonObject().apply {
                    addProperty("role", m.role.wire)
                    // ★★ 原生轨（ADR-031 step 2 硬前置 1）★★
                    //   `tool_calls` 一旦进历史，两侧都必须换形状：
                    //     · 结果消息 = `role:"tool"` + `tool_call_id`（孤立的 tool 消息非法）
                    //     · assistant 的 `tool_calls` 要**随历史重放**（否则下一轮的
                    //       tool 消息没有配对对象 ⇒ 同样是非法请求）
                    //   文本轨（nativeCalls 空、不是 TOOL）⇒ 只有 `{role, content}`，
                    //   与改动前**逐字节相同**。
                    if (m.role == ChatRole.TOOL) {
                        addProperty("tool_call_id", m.toolCallId ?: "")
                        addProperty("content", m.content)
                    } else if (m.nativeCalls.isNotEmpty()) {
                        add("tool_calls", JsonArray().apply {
                            m.nativeCalls.forEach { c ->
                                add(JsonObject().apply {
                                    addProperty("id", c.id)
                                    addProperty("type", "function")
                                    add("function", JsonObject().apply {
                                        addProperty("name", c.tool)
                                        addProperty("arguments", c.argumentsJson)
                                    })
                                })
                            }
                        })
                        // content 写 null 是**合规**形状（这一轮只有调用、没有正文）
                        if (m.content.isEmpty()) add("content", com.google.gson.JsonNull.INSTANCE)
                        else addProperty("content", m.content)
                    } else {
                        addProperty("content", m.content)
                    }
                })
            }

            // ★ 多模态（2026-10-19）：图片作为**单独一条 user 消息**附在最后。
            //   不塞进现有消息里，是为了不改动文本轨的既有形状（空列表 ⇒ 这段不执行 ⇒ 逐字节不变）。
            //   `image_url.url` 是 data URL —— OpenAI 兼容端点直接接受。
            if (images.isNotEmpty()) {
                add(JsonObject().apply {
                    addProperty("role", "user")
                    add("content", JsonArray().apply {
                        add(JsonObject().apply {
                            addProperty("type", "text")
                            addProperty("text", "（用户附上了下面的图片，请结合图片内容作答）")
                        })
                        images.forEach { url ->
                            add(JsonObject().apply {
                                addProperty("type", "image_url")
                                add("image_url", JsonObject().apply { addProperty("url", url) })
                            })
                        }
                    })
                })
            }
        })
        addProperty("max_tokens", maxOutputTokens)
        addProperty("stream", stream)

        if (stream) {
            // 不带 usage 就拿不到缓存记账（FR-10.5 的成本来源）
            add("stream_options", JsonObject().apply { addProperty("include_usage", true) })
        }

        // ↓ 契约注入：调用方不得设置（02-契约规范.md §5.2）
        addProperty("temperature", 0)

        // ★★ 思考参数**互斥**（2026-10-14 真机 400 修复）★★
        //
        // ## 用户实测
        //
        // 换成 `deepseek-v4-flash-0713`（支持思考的模型）后：
        //   `HTTP 400: 深度思考参数互相冲突`
        //
        // ## 根因
        //
        // 旧代码**同时**发了两个语义冲突的字段：
        //   · `enable_thinking: false`（Qwen3 系专有，铁律 3）
        //   · `reasoning_effort: <档位>`（通用分档，云端专有）
        //
        // 中转站/新版服务端会校验这个冲突并直接 400 ——
        // 而 400 对用户是"完全不可用"，不是"慢一点"。
        //
        // ## 规则：只发**通用**字段，专有字段一个都不发（S2 起）
        //
        // | 用户档位 | 发什么 | 为什么不发另一个 |
        // |---|---|---|
        // | 给了 `reasoning_effort` | **只发它** | 用户选了档位 → 不该被关思考覆盖 |
        // | 没给（auto/off） | **什么都不发** | 没选档位 = 交给服务端默认。发 Qwen 专有字段给 DeepSeek 会 400（实测过） |
        //
        // ⚠️ S2 删掉了 `enable_thinking` **字段与开关本身**：唯一会发它的分支（`disableThinking`）
        //    已不存在 ⇒ "两者永不共存"这个不变量**从"靠 if/else 维持"变成"结构上不可能"**。
        //    代价（DashScope 失去关思考开关）写在类 KDoc 的"代价"段，不许淡化。
        val effort = reasoningEffortOrNull(reasoning)
        if (effort != null) {
            // 用户显式选了档位 → 用标准字段表达
            addProperty("reasoning_effort", effort)
        }
        // 否则刻意什么都不发（不是"忘了"，见上表第 2 行）
        // ↑

        // ★★ 原生 `tools` 数组（ADR-031 决策 2 请求侧，2026-10-18）★★
        //
        // 非空 ⇒ 按 OpenAI 形状发出去；形状由 [NativeToolSchema] 统一映射
        // （与文本轨的 `canonicalToolJson` **同一个源**，不许两套真相）。
        //
        // ⚠️ 与 `response_format` **互斥**：`json_object` 说的是"必须给我 JSON"，
        //    `tools` 说的是"用原生工具调用" —— 同时发就是两份矛盾指令，
        //    模型很可能把方言 JSON 写进 `content`（`docs/27` §2.5③ 的病根**换个位置复发**）。
        //    所以有 `tools` 时**不发** `response_format`。
        //
        // ⚠️ 今天**零影响**：出厂 `tools` 为空（`nativeToolsEnabled` 默认 false）
        //    ⇒ 本段不进请求体，请求体与改动前逐字节相同（`NativeToolsRequestTest` 钉住）。
        if (tools.isNotEmpty()) {
            add("tools", NativeToolSchema.openAiCompat(tools))
        }

        if (tools.isEmpty()) {
            when (structured) {
                is StructuredSpec.Json -> add("response_format", JsonObject().apply {
                    addProperty("type", "json_object")
                })
                is StructuredSpec.JsonSchema -> add("response_format", JsonObject().apply {
                    addProperty("type", "json_object")
                })
                is StructuredSpec.Grammar -> {
                    // 云端不支持 GBNF。降级为 json_object，并依赖调用方的输出校验。
                    // 见 02-契约规范.md §6「云端降级」。
                    add("response_format", JsonObject().apply { addProperty("type", "json_object") })
                }
                null -> Unit
            }
        }
    }

    /**
     * 档位 → 云端 `reasoning_effort`。
     *
     * `AUTO` / `OFF` 返回 `null`：**不传该字段**。
     * 不传比传 `"auto"` 更诚实 —— 我们并不知道服务端理解的 `"auto"` 是什么，
     * 而某些端点会把不认识的取值直接判非法。
     *
     * `MAX` 部分端点无此档，退化为 `"high"`（`25` §10.3）。
     */
    private fun reasoningEffortOrNull(level: ReasoningLevel): String? = when (level) {
        ReasoningLevel.AUTO -> null
        ReasoningLevel.OFF -> null
        // ⚠️ 以下三档**在本地后端下无法区分**（本地只有布尔开关），
        //    这里的区分能力是云端独有的 —— 不要在 UI 上假装本地也有。
        ReasoningLevel.LOW -> "low"
        ReasoningLevel.HIGH -> "high"
        ReasoningLevel.MAX -> "high"
    }

    private fun parseChatResponse(json: JsonObject): GenerateResult {
        val choices = json.getAsJsonArray("choices")
        if (choices == null || choices.size() == 0) {
            return GenerateResult("", CacheStats.withoutCacheReporting(0, 0), FinishReason.ERROR)
        }
        // ★★ 防御式取值（2026-10-14 真机崩溃修复）★★
        //
        // 崩溃栈：com.google.gson.JsonNull cannot be cast to JsonObject
        //
        // 根因：**第三方聚合服务的响应形状不保证** ——
        // 基元律动（tokenrhythm.studio）实测可能返回
        // `"choices":[null]` 或 `"message": null`
        // （`getAsJsonObject` 对 JsonNull **直接 ClassCastException**，
        //  而不是返回 null —— Gson 的这个行为是隐式的）。
        //
        // 修法：所有强转前先 `isJsonObject` 判型 ——
        // 解析失败走正常的 ERROR 路径（用户看到"输出为空"），
        // **绝不能让 App 崩**。
        val first = choices[0]
        val choice = if (first != null && first.isJsonObject) first.asJsonObject else null
        val message = choice?.get("message")?.takeIf { it.isJsonObject }?.asJsonObject
        val text = message?.get("content")?.takeIf { !it.isJsonNull }?.asString.orEmpty()
            // ⚠️ message 可能为 null（聚合服务的错误形状）——
            //    此时回看 error 字段，把服务端的真实原因报给用户
            //
            // ★ 同样必须判型：`{"error": null}` 时 `getAsJsonObject` 会崩
            ?: run {
                val errEl = json.get("error")
                val detail = when {
                    errEl != null && errEl.isJsonObject -> errEl.asJsonObject
                        .get("message")?.takeIf { !it.isJsonNull }?.asString
                    errEl != null && errEl.isJsonPrimitive -> errEl.asString
                    else -> null
                } ?: json.get("message")?.takeIf { !it.isJsonNull }?.asString
                if (detail != null) {
                    return GenerateResult(
                        "服务端错误：$detail",
                        CacheStats.withoutCacheReporting(0, 0),
                        FinishReason.ERROR,
                    )
                }
                ""
            }

        // ★ usage 也要判型（`"usage": null` 在某些错误响应里出现）
        val usageObj = json.get("usage")?.takeIf { it.isJsonObject }?.asJsonObject
        val cache = CacheFieldMapper.auto(usageObj)
        totalCachedTokens += cache.cachedTokens ?: 0
        totalPromptTokens += cache.promptTokens
        totalOutputTokens += cache.outputTokens

        // ★ 原生调用（非流式）：`message.tool_calls[]` —— 与流式归并产出同一种中立类型
        val calls = NativeCalls.fromOpenAiMessage(message)
        val finish = when (choice?.get("finish_reason")?.takeIf { !it.isJsonNull }?.asString) {
            "stop" -> FinishReason.STOP
            "length" -> FinishReason.LENGTH
            "tool_calls" -> FinishReason.TOOL_CALLS
            // 聚合服务可能不给 finish_reason：有调用时**必须**报 TOOL_CALLS（不许静默当成正常结束）
            null -> if (calls.isNotEmpty()) FinishReason.TOOL_CALLS else FinishReason.STOP
            else -> FinishReason.ERROR
        }
        return GenerateResult(text, cache, finish, calls)
    }

    /** 展示用：累计用量摘要（FR-10.5） */
    fun usageSummary(): String =
        "累计 命中 ${totalCachedTokens} / 实算 ${totalPromptTokens} / 输出 ${totalOutputTokens}"

    companion object {
        /** DashScope 的 OpenAI 兼容端点（本项目当前使用的凭据，见 `.env` 的 `DASHSCOPE_API_KEY`） */
        const val DASHSCOPE_BASE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1"

        /**
         * 预热用的占位提问。
         *
         * **必须与真实请求的消息条数一致**，否则缓存键不匹配（见 [prewarm]）。
         * 内容本身不重要，但必须**逐字节固定**。
         */
        const val WARMUP_MARKER = "ping"
    }
}
