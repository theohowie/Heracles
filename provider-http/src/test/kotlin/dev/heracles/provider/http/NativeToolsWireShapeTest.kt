package dev.heracles.provider.http

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.GenerateResult
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **Anthropic / OpenAI-Responses 两轨的 wire 形状钉死**（2026-10-19）—— 零 Key、零网络。
 *
 * ## 这个文件为什么存在
 *
 * `AGENTS.md` 的硬规则：**wire 变更必须真 Key 验证过才算完成**。现实是
 * **只有 OpenAI 兼容轨有真 Key 证据**（F7，设备 `e35e48c6`）；Anthropic 与 Responses
 * **只有单测**。在没有 Key 的前提下，能做的最好的事是把形状**逐字段钉死**，
 * 并**如实标注**哪些条款是官方文档确认的、哪些没确认。
 *
 * | 轨 | 状态 | 本文件负责 |
 * |---|---|---|
 * | OpenAI 兼容 | ✅ 有真 Key 证据 | （对照，一行 `images` 的显式失败） |
 * | **Anthropic** | ❌ 无真 Key | `tools` / `tool_use` / `tool_result` / `stop_reason` |
 * | **Responses** | ❌ 无真 Key | `tools` / `function_call` / `function_call_output` |
 *
 * ## 核对依据（**只抄文档里写了的**；没写的标"未确认"）
 *
 * - Anthropic：官方 Python SDK 的类型定义（由官方 OpenAPI 生成）
 *   `ToolParam` / `ToolUseBlockParam` / `ToolResultBlockParam` / `StopReason` / `Message`
 * - OpenAI Responses：官方 OpenAPI（`openai/openai-openapi` 仓）
 *   `FunctionTool` / `FunctionToolCall` / `FunctionToolCallOutput` / `FunctionCallOutputItemParam`
 *   / `EasyInputMessage` / `ResponseFailedEvent` / `ResponseIncompleteEvent`
 *
 * ⚠️ 文档页面本身（platform.claude.com / platform.openai.com）**在本机抓不到**
 * （重定向 / Cloudflare 403），依据是上面两份**官方仓库**里的规范文件。
 *
 * ## 与既有文件的分工（不许重复）
 *
 * - [NativeToolsRequestTest]：`tools` 与约束解码的**互斥**（P0-2）
 * - [NativeCallReplayTest]：原生调用的**回放**（历史里发起/结果两边）
 * - **本文件**：两轨**各自的 wire 逐字段形状** + 文档差异的**显式记录**
 *   （例如 `desc[0]` 是 `null`、`tool_choice` 只存在于一家 —— 这些是"未确认"而不是"错误"）
 */
class NativeToolsWireShapeTest {

    // ================================================================ 夹具

    /**
     * 按 **名字 + 参数个数**取私有方法（照 [NativeCallReplayTest] 的写法）。
     *
     * ⚠️ 刻意**不**用 `getDeclaredMethod(精确类型)`：F7b 踩过一次 ——
     * 给 `buildBody` 加个参数后精确匹配在**运行时**抛 `NoSuchMethodException`，
     * 而编译是绿的（门禁静默失效）。按"名字 + 个数"取，签名微调不会让它消失，
     * 但**个数一变就会在这里红**，提醒你回来更新本文件。
     */
    private fun privateMethod(cls: Class<*>, name: String, arity: Int) =
        cls.declaredMethods.single { it.name == name && it.parameterCount == arity }
            .apply { isAccessible = true }

    private val specs = listOf(
        ToolSpec(
            "read_file", "读文件",
            listOf(
                ToolParam("path", "string", "路径"),
                ToolParam("offset", "string", "起始行号", allowEmpty = true, optional = true),
            ),
        ),
        ToolSpec("build_apk", "构建", listOf(ToolParam("project_dir", "string", "项目目录"))),
    )

    private fun anthropicProvider() =
        AnthropicProvider(baseUrl = "https://example.invalid", apiKey = "k", modelName = "m")

    private fun responsesProvider() =
        OpenAiResponsesProvider(
            id = "responses:test", baseUrl = "https://example.invalid", apiKey = "k", modelName = "m",
        )

    /** Anthropic `buildBody(messages, maxOutputTokens, stream, tools, images)` —— arity 5（2026-10-19 多模态后）。 */
    private fun anthropicBody(
        tools: List<ToolSpec> = emptyList(),
        messages: List<ChatMessage> = listOf(ChatMessage(ChatRole.USER, "hi")),
    ): JsonObject {
        val m = privateMethod(AnthropicProvider::class.java, "buildBody", 5)
        return m.invoke(anthropicProvider(), messages, 16, false, tools, emptyList<String>()) as JsonObject
    }

    /** Responses `buildBody(request, stream, images)` —— arity 3（2026-10-19 多模态后）。 */
    private fun responsesBody(
        tools: List<ToolSpec> = emptyList(),
        messages: List<ChatMessage> = listOf(ChatMessage(ChatRole.USER, "hi")),
    ): JsonObject {
        val m = privateMethod(OpenAiResponsesProvider::class.java, "buildBody", 3)
        val request = GenerateRequest(
            prompt = "hi", maxOutputTokens = 16, messages = messages, tools = tools,
        )
        return m.invoke(responsesProvider(), request, false, emptyList<String>()) as JsonObject
    }

    private fun parseAnthropic(json: String): GenerateResult {
        val m = privateMethod(AnthropicProvider::class.java, "parseResponse", 1)
        return m.invoke(anthropicProvider(), json) as GenerateResult
    }

    private fun parseResponses(json: String): GenerateResult {
        val m = privateMethod(OpenAiResponsesProvider::class.java, "parseResponse", 1)
        return m.invoke(responsesProvider(), json) as GenerateResult
    }

    private fun JsonObject.keysOf(): Set<String> = keySet()

    // ================================================================
    // 1. Anthropic 请求侧：`tools` 形状
    // ================================================================

    @Test
    @DisplayName("★★ Anthropic `tools`：`[].name/description/input_schema`（**无** `type`、**无** `function` 外层）")
    fun anthropicToolsHaveInputSchemaAndNoFunctionWrapper() {
        val tools = anthropicBody(tools = specs).getAsJsonArray("tools")

        assertEquals(specs.size, tools.size(), "工具声明不许被吞、也不许被复制")
        tools.forEach { el ->
            val obj = el.asJsonObject
            assertEquals(
                setOf("name", "description", "input_schema"),
                obj.keysOf(),
                "★ 文档（SDK `ToolParam`）里 function 工具只有这三项：`input_schema`/`name`/`description`。" +
                    "多出 `type`（= OpenAI 的 \"function\"）或 `function` 外层 ⇒ Anthropic 判非法。实际：$obj",
            )
            assertTrue(obj.get("name").isJsonPrimitive, "name 必须是字符串：$obj")
            assertTrue(obj.get("description").isJsonPrimitive, "description 必须是字符串：$obj")
            assertTrue(
                obj.get("input_schema").isJsonObject,
                "★ `input_schema` 必须是**对象**（SDK：`Required[InputSchema]`，且其 `type` 必须是 \"object\"）：$obj",
            )
        }

        // 第一项逐字段核对 canonical 源（两轨不许分叉）
        val first = tools[0].asJsonObject
        assertEquals("read_file", first.get("name").asString)
        assertEquals("读文件", first.get("description").asString)
        val schema = first.getAsJsonObject("input_schema")
        assertEquals("object", schema.get("type").asString)
        assertEquals(
            setOf("path", "offset"), schema.getAsJsonObject("properties").keySet(),
            "参数集必须齐全",
        )
        assertEquals(
            setOf("path"), schema.getAsJsonArray("required").map { it.asString }.toSet(),
            "required 只含非 optional 的参数",
        )
    }

    @Test
    @DisplayName("★★ 零回退：Anthropic 不给 tools ⇒ 请求体里**没有** `tools` 键（且其余逐字节不变）")
    fun anthropicWithoutToolsHasNoToolsKey() {
        val body = anthropicBody(tools = emptyList())
        assertFalse(body.has("tools"), "★ 空列表必须**不加键**（不是加空数组）：$body")
        assertEquals(
            "{\"model\":\"m\",\"max_tokens\":16," +
                "\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
            body.toString(),
            "★ 逐字符金标准：`tools` 为空时 Anthropic 请求体与原生轨之前**逐字节相同**。" +
                "有意改请求体时连同这条一起改（与 [NativeToolsRequestTest] 的做法一致）",
        )
        // 有 tools 时，只多出 `tools` 这一个键（键序也钉住：它在 messages 之后）
        assertEquals(
            listOf("model", "max_tokens", "messages", "tools"),
            anthropicBody(tools = specs).keySet().toList(),
            "有 tools 时**只允许**多出这一个顶层键，且位置在 messages 之后",
        )
    }

    // ================================================================
    // 2. Anthropic 响应侧：`tool_use` 块 / `stop_reason` / usage
    // ================================================================

    @Test
    @DisplayName("★★ Anthropic `tool_use` 块：`{type,id,name,input}`，`input` 是**对象**；`stop_reason=tool_use` ⇒ TOOL_CALLS")
    fun anthropicToolUseBlockShape() {
        val r = parseAnthropic(
            """
            {"id":"msg_1","type":"message","role":"assistant",
             "content":[
               {"type":"text","text":"好的"},
               {"type":"tool_use","id":"toolu_01","name":"read_file","input":{"path":"a.txt"}}
             ],
             "stop_reason":"tool_use",
             "usage":{"input_tokens":11,"output_tokens":7,"cache_read_input_tokens":3}}
            """.trimIndent(),
        )
        assertEquals("好的", r.text, "同一条消息里正文块仍要拼出来（原生轨不排斥正文）")
        assertEquals(FinishReason.TOOL_CALLS, r.finishReason, "`tool_use` 必须映射成 TOOL_CALLS")
        assertEquals(1, r.toolCalls.size)
        val call = r.toolCalls[0]
        assertEquals("toolu_01", call.id, "id 是要**原样**回传的 wire 事实（Skill/CLI 会把它写进 tool_use_id）")
        assertEquals("read_file", call.tool)
        assertEquals("{\"path\":\"a.txt\"}", call.argumentsJson, "input 是对象 ⇒ provider 序列化成字符串")
        // Anthropic 的 token 字段名与 OpenAI 不同
        assertEquals(11, r.cache.promptTokens, "input_tokens（不是 prompt_tokens）")
        assertEquals(7, r.cache.outputTokens, "output_tokens（不是 completion_tokens）")
        assertEquals(3, r.cache.cachedTokens, "cache_read_input_tokens")
    }

    @Test
    @DisplayName("★ Anthropic `stop_reason` 全表：end_turn/stop_sequence⇒STOP、max_tokens⇒LENGTH、其它⇒ERROR")
    fun anthropicStopReasonMapping() {
        fun reason(raw: String?): FinishReason = parseAnthropic(
            """{"content":[{"type":"text","text":"x"}]""" +
                (raw?.let { ",\"stop_reason\":\"$it\"" } ?: "") + "}",
        ).finishReason

        assertEquals(FinishReason.STOP, reason("end_turn"))
        assertEquals(FinishReason.STOP, reason("stop_sequence"))
        assertEquals(FinishReason.LENGTH, reason("max_tokens"))
        assertEquals(FinishReason.TOOL_CALLS, reason("tool_use"))
        assertEquals(FinishReason.STOP, reason(null), "缺 stop_reason 且无调用 ⇒ STOP（不能因此判错）")
        // ⚠️ 下面这些是 SDK 的 StopReason 里有、而**本实现没映射**的取值 ⇒ 落到 ERROR。
        //    这是**已知缺口**不是断言正确性：`pause_turn` 语义是"把响应原样回灌继续"，
        //    需要 previous-turn 回灌能力；`refusal` 是真·拒答。两者都要单独设计 + 真 Key 验证。
        assertEquals(
            FinishReason.ERROR, reason("pause_turn"),
            "★ 未映射 ⇒ ERROR（**已记录的缺口**，不是「已正确处理」）：pause_turn 要能把响应原样回灌",
        )
        assertEquals(FinishReason.ERROR, reason("refusal"), "未映射 ⇒ ERROR（已记录）")
        assertEquals(FinishReason.ERROR, reason("model_context_window_exceeded"), "未映射 ⇒ ERROR（已记录）")
    }

    // ================================================================
    // 3. Anthropic 回放：`tool_result` 块（含"空 id 不许出现"）
    // ================================================================

    @Test
    @DisplayName("★★ Anthropic `tool_result`：`{type,tool_use_id,content}` 三键，id 与 tool_use.id **逐字**相同")
    fun anthropicToolResultBlockShape() {
        val history = listOf(
            ChatMessage(ChatRole.USER, "读一下"),
            ChatMessage(ChatRole.ASSISTANT, "", nativeCalls = listOf(NativeToolCall("toolu_01", "read_file", "{\"path\":\"a.txt\"}"))),
            ChatMessage(ChatRole.TOOL, "文件内容", toolCallId = "toolu_01"),
        )
        val msgs = anthropicBody(messages = history).getAsJsonArray("messages").map { it.asJsonObject }

        val useBlock = msgs.single { it.get("role").asString == "assistant" }
            .getAsJsonArray("content")[0].asJsonObject
        assertEquals("tool_use", useBlock.get("type").asString)
        assertTrue(useBlock.get("input").isJsonObject, "input 必须是对象")

        val resultMsg = msgs.last()
        assertEquals("user", resultMsg.get("role").asString, "★ 工具结果回传用 **user 轮**（不是 role:tool）")
        val resultBlock = resultMsg.getAsJsonArray("content")[0].asJsonObject
        assertEquals("tool_result", resultBlock.get("type").asString)
        assertEquals(
            setOf("type", "tool_use_id", "content"),
            resultBlock.keysOf(),
            "文档（SDK `ToolResultBlockParam`）：`tool_use_id`/`type` 必填，`content` 可为字符串；" +
                "成功时**不该**出现 `is_error`（没失败就别声称失败）",
        )
        assertEquals(
            useBlock.get("id").asString, resultBlock.get("tool_use_id").asString,
            "★ 配对必须逐字相同 —— 对不上就是 Anthropic 的非法请求",
        )
        assertEquals("文件内容", resultBlock.get("content").asString, "`content` 可以是字符串（不必包成块数组）")
    }

    @Test
    @DisplayName("★★ 真 bug 回归：TOOL 消息**没有 id** 时退回 user 文本，绝不发 `tool_use_id:\"\"`")
    fun anthropicNeverSendsEmptyToolUseId() {
        val history = listOf(
            ChatMessage(ChatRole.USER, "读一下"),
            ChatMessage(ChatRole.TOOL, "文件内容", toolCallId = null),
        )
        val body = anthropicBody(messages = history)
        val raw = body.toString()
        assertFalse(
            raw.contains("tool_use_id"),
            "★ 空 `tool_use_id` 违反 SDK 的 `Required[str]`，且必然配不上任何 `tool_use.id`。" +
                "没有 id ⇒ 退回文本轨的 user 文本消息。实际：$raw",
        )
        val last = body.getAsJsonArray("messages").last().asJsonObject
        assertEquals("user", last.get("role").asString)
        assertTrue(
            last.get("content").isJsonPrimitive,
            "★ 文本轨的 content 必须还是**字符串**（块数组 = 老路径回归）：$last",
        )
        assertEquals("文件内容", last.get("content").asString)

        // 空串与 null 等价：都是"没有 id"
        val emptyId = anthropicBody(
            messages = listOf(ChatMessage(ChatRole.TOOL, "结果", toolCallId = "")),
        )
        assertFalse(emptyId.toString().contains("tool_use_id"), "空串同样不许发：$emptyId")
    }

    // ================================================================
    // 4. Responses 请求侧：`tools` 扁平形状
    // ================================================================

    @Test
    @DisplayName("★★ Responses `tools`：`tools[0].type == \"function\"` 且**扁平**（`name`/`description`/`parameters` 在顶层）")
    fun responsesToolsAreFlatFunctionType() {
        val tools = responsesBody(tools = specs).getAsJsonArray("tools")
        assertEquals(specs.size, tools.size())

        val first = tools[0].asJsonObject
        assertEquals("function", first.get("type").asString, "★ 文档（OpenAPI `FunctionTool`）：`type` 只能是 `function`")
        assertEquals(
            setOf("type", "name", "description", "parameters"),
            first.keysOf(),
            "★ Responses 是**扁平**的：不许有 `function` 外层（那是 /chat/completions 的形状）：$first",
        )
        assertEquals("read_file", first.get("name").asString)
        assertEquals("读文件", first.get("description").asString)
        assertTrue(
            first.get("parameters").isJsonObject,
            "★ 文档：`parameters` 是描述参数的 JSON schema **对象**（不是字符串）：$first",
        )
        assertEquals("object", first.getAsJsonObject("parameters").get("type").asString)
        assertEquals(
            setOf("path"), first.getAsJsonObject("parameters").getAsJsonArray("required").map { it.asString }.toSet(),
        )
    }

    @Test
    @DisplayName("★★ 零回退：Responses 不给 tools ⇒ 请求体里**没有** `tools` 键（且其余逐字节不变）")
    fun responsesWithoutToolsHasNoToolsKey() {
        val body = responsesBody(tools = emptyList())
        assertFalse(body.has("tools"), "★ 空列表必须**不加键**：$body")
        assertEquals(
            "{\"model\":\"m\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}]," +
                "\"max_output_tokens\":16}",
            body.toString(),
            "★ 逐字符金标准：`tools` 为空时 Responses 请求体与原生轨之前逐字节相同",
        )
        assertEquals(
            listOf("model", "input", "max_output_tokens", "tools"),
            responsesBody(tools = specs).keySet().toList(),
            "有 tools 时**只允许**多出这一个顶层键",
        )
    }

    @Test
    @DisplayName("★ `tool_choice` 现状：**两轨都不发**（文档里有这个键，但本实现是服务端默认 auto）")
    fun toolChoiceIsNeverSent() {
        // OpenAPI：Responses 的 `tool_choice` 取 "none" | "auto" | "required" | {type:"function",name}
        // Anthropic（SDK）：{type:"auto"|"any"|"tool"|"none", name?}
        // ⇒ 两家**都有**这个键，但语义映射不同（any ↔ required），且我们**没有要求**
        //    模型必须调工具的场景。**不发 = 服务端默认**，这是一条**有意**的现状，
        //    不是遗漏：真要接，必须先有"哪种场景需要强制调工具"的决策 + 真 Key 验证。
        assertFalse(anthropicBody(tools = specs).has("tool_choice"), "Anthropic 轨不发 tool_choice")
        assertFalse(responsesBody(tools = specs).has("tool_choice"), "Responses 轨不发 tool_choice")
    }

    // ================================================================
    // 5. Responses 回放：`function_call` / `function_call_output`
    // ================================================================

    @Test
    @DisplayName("★★ Responses 回放：顶层 item，`function_call`/`function_call_output` 的 `call_id` 逐字相同")
    fun responsesCallAndOutputItems() {
        val history = listOf(
            ChatMessage(ChatRole.USER, "读一下"),
            ChatMessage(ChatRole.ASSISTANT, "", nativeCalls = listOf(NativeToolCall("call_abc", "read_file", "{\"path\":\"a.txt\"}"))),
            ChatMessage(ChatRole.TOOL, "文件内容", toolCallId = "call_abc"),
        )
        val input = responsesBody(messages = history).getAsJsonArray("input").map { it.asJsonObject }

        val callItem = input.single { it.get("type").asString == "function_call" }
        assertEquals(
            setOf("type", "call_id", "name", "arguments"),
            callItem.keysOf(),
            "文档（OpenAPI `FunctionToolCall`）：必填 `type`/`call_id`/`name`/`arguments`；" +
                "我们只发这四项（`id`/`status`/`caller` 等是可选项，不发）",
        )
        assertTrue(callItem.get("arguments").isJsonPrimitive, "★ `arguments` 是 **JSON 字符串**（与 Anthropic 的 input 对象相反）")

        val outItem = input.single { it.get("type").asString == "function_call_output" }
        // ⚠️ 注意：文档里 `call_id` 在**响应对象**（`FunctionToolCallOutput`）中是必填，
        //    但在**请求项**（`FunctionCallOutputItemParam`）里是 `anyOf[string, null]` ⇒ **非必填**。
        //    我们照发（配对需要它），这是"文档允许 + 语义必需"，不是"文档要求"。
        assertEquals(
            setOf("type", "call_id", "output"),
            outItem.keysOf(),
            "实际形状：`{type, call_id, output}`",
        )
        assertEquals(
            callItem.get("call_id").asString, outItem.get("call_id").asString,
            "★ 配对必须逐字相同（`call_id` 由模型生成，我们只负责原样搬运）",
        )
        assertEquals("文件内容", outItem.get("output").asString, "`output` 可以是字符串")
    }

    @Test
    @DisplayName("★★ 真 bug 回归：TOOL/调用项**没有 id** 时退回 user 文本，绝不发 `call_id:\"\"`")
    fun responsesNeverSendsEmptyCallId() {
        val history = listOf(
            ChatMessage(ChatRole.USER, "读一下"),
            ChatMessage(ChatRole.TOOL, "文件内容", toolCallId = null),
            ChatMessage(ChatRole.ASSISTANT, "", nativeCalls = listOf(NativeToolCall("", "read_file", "{\"path\":\"a\"}"))),
        )
        val body = responsesBody(messages = history)
        val raw = body.toString()
        assertFalse(
            raw.contains("function_call\""),
            "★ 没有 call_id 就发不出可配对的 `function_call`（`call_id` 在文档里是必填）：$raw",
        )
        assertFalse(
            raw.contains("function_call_output"),
            "★ 空 `call_id` 的 function_call_output 是孤儿项，不许发：$raw",
        )
        val input = body.getAsJsonArray("input").map { it.asJsonObject }
        assertTrue(
            input.all { it.get("type").asString == "message" },
            "退回文本轨：每一项都是 message 项（与原生轨之前逐字节相同）",
        )
        assertTrue(
            input.any { it.get("role").asString == "user" && it.get("content").asString == "文件内容" },
            "工具结果仍要回灌（作为 user 文本），**不许静默丢**：$input",
        )
    }

    @Test
    @DisplayName("★ Responses 响应侧：`function_call` 项 ⇒ 回传用 `call_id`；`status=completed` + 有调用 ⇒ TOOL_CALLS")
    fun responsesFunctionCallItemParsing() {
        val r = parseResponses(
            """
            {"id":"resp_1","object":"response","status":"completed",
             "output":[
               {"id":"fc_item_1","type":"function_call","call_id":"call_xyz",
                "name":"read_file","arguments":"{\"path\":\"a.txt\"}","status":"completed"}
             ],
             "usage":{"input_tokens":20,"output_tokens":9}}
            """.trimIndent(),
        )
        assertEquals(1, r.toolCalls.size)
        assertEquals(
            "call_xyz", r.toolCalls[0].id,
            "★ 回传要用 **call_id**（模型生成的），不是 `id`（item id）—— 用错就配不上",
        )
        assertEquals(FinishReason.TOOL_CALLS, r.finishReason, "有 function_call 项 ⇒ 真实语义是「请求调工具」")
        assertEquals(20, r.cache.promptTokens)
        assertEquals(9, r.cache.outputTokens)
    }

    // ================================================================
    // 6. 两轨的**未确认**差异（写下来，不假装已确认）
    // ================================================================

    @Test
    @DisplayName("★ 未确认差异的记录：`description` 是否必填 —— 文档**未写**，我们**总是发**")
    fun descriptionIsAlwaysSentEvenThoughOptionalityIsUnconfirmed() {
        // Anthropic SDK `ToolParam.description: str` —— 非 `Required` ⇒ 文档上是**可选**；
        // 但 `str`（非 Optional[str]）意味着"没给就是 null"，null 是否合法**文档没写** ⇒ 未确认。
        // OpenAI OpenAPI `FunctionTool.description: anyOf[string, null]` ⇒ **显式可空**。
        // ⇒ 两家都没有"必须给描述"的硬要求；我们**总是发**（`canonicalToolJson` 恒有该键），
        //   这是安全方向（多给一个必定义项 ≠ 少给）。
        val anthropic = anthropicBody(tools = specs).getAsJsonArray("tools")[0].asJsonObject
        val responses = responsesBody(tools = specs).getAsJsonArray("tools")[0].asJsonObject
        assertTrue(anthropic.has("description"), "Anthropic：总是发（哪怕它是 null —— 未确认 null 是否合法）")
        assertTrue(responses.has("description"), "Responses：总是发")
        // ⚠️ 反过来说：若哪天 `ToolSpec.description` 为空串，两家收到的都是 `""` ——
        //    `""` 与 `null` 在文档里的区别**未确认**。这里不编结论。
        val blank = listOf(ToolSpec("t", "", listOf(ToolParam("a", "string", ""))))
        assertEquals(
            "",
            anthropicBody(tools = blank).getAsJsonArray("tools")[0].asJsonObject.get("description").asString,
            "空描述会被原样发成空串（未确认对方是否接受空串）",
        )
    }

    @Test
    @DisplayName("★ 未确认差异的记录：Anthropic `ToolParam.strict` vs OpenAI `FunctionTool.strict` —— **两轨都不发**")
    fun strictIsNeverSentOnEitherTrack() {
        // Anthropic SDK `ToolParam.strict: bool`（When true, guarantees schema validation）
        // OpenAI OpenAPI `FunctionTool.strict` —— 但在 Responses 的 `required` 列表里！
        //   ⚠️ 这是 **OpenAPI 声明必填 vs 官方指南展示不写** 的矛盾，
        //   本仓无从判断服务端是否真的要求它 ⇒ **未确认**，标注在此。
        // 现状：两轨都不发 `strict`（沿用 canonical 体的三项）。若真 Key 验证发现 400，
        //   这里就是第一个要补的地方 —— 补之前需要真 Key 证据。
        val anthropic = anthropicBody(tools = specs).getAsJsonArray("tools")[0].asJsonObject
        val responses = responsesBody(tools = specs).getAsJsonArray("tools")[0].asJsonObject
        assertFalse(anthropic.has("strict"), "Anthropic 轨不发 strict（可选字段）")
        assertFalse(
            responses.has("strict"),
            "★ Responses 轨不发 strict —— **未确认**：OpenAPI 把它列进 `required`，" +
                "但官方函数调用指南的示例里不写它。真 Key 验证时重点看这条",
        )
    }

    // ================================================================
    // 7. 多模态（**2026-10-19 已接通**；原"两轨显式失败"的缺口记录已兑现）
    // ================================================================

    private val dataUrl =
        "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    @Test
    @DisplayName("★★ Anthropic `generate()` 带图**不再**显式失败（早退已删除，2026-10-19 接通）")
    fun anthropicGenerateWithImageNoLongerFailsEarly() = runBlocking {
        val p = anthropicProvider()
        p.load(ProviderConfig()).getOrThrow()
        // ⚠️ **不发网络**：这里只证明"图片这一关过了" —— 失败原因不能再是「不支持读图」。
        //    形状断言在 `MultimodalTracksTest`（那边有整串金标准与 text/image 顺序）。
        val r = p.generate(GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = listOf(dataUrl)))
        assertFalse(
            r.exceptionOrNull()?.message?.contains("不支持读图") == true,
            "★ 早退已删除：带合法 PNG 不该再被判为「不支持读图」：${r.exceptionOrNull()?.message}",
        )
    }

    @Test
    @DisplayName("★★ Responses `generate()` 带图**不再**显式失败（早退已删除，2026-10-19 接通）")
    fun responsesGenerateWithImageNoLongerFailsEarly() = runBlocking {
        val p = responsesProvider()
        p.load(ProviderConfig()).getOrThrow()
        val r = p.generate(GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = listOf(dataUrl)))
        assertFalse(
            r.exceptionOrNull()?.message?.contains("不支持读图") == true,
            "★ 早退已删除：${r.exceptionOrNull()?.message}",
        )
    }

    @Test
    @DisplayName("★★ 两轨的流式入口同口径：带图**不再**以「不支持读图」终止")
    fun bothTracksNoLongerRejectImagesOnStreaming() {
        // 与 generate() 的语义对应：图片这一关已过 ⇒ 流式失败的原因只可能是网络。
        // ⚠️ 端点用 `127.0.0.1:9`（不可能连上）—— 这仍然**不是**网络证据，只是"图片没被拒"。
        val unreachable = "http://127.0.0.1:9"

        val anthropic = runCatching {
            runBlocking {
                AnthropicProvider(baseUrl = unreachable, apiKey = "k", modelName = "m")
                    .apply { load(ProviderConfig()).getOrThrow() }
                    .generateStream(GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = listOf(dataUrl)))
                    .collect { }
            }
        }
        assertFalse(
            anthropic.exceptionOrNull()?.message.orEmpty().contains("不支持读图"),
            "Anthropic 流式不该再报「不支持读图」：${anthropic.exceptionOrNull()?.message}",
        )

        val responses = runCatching {
            runBlocking {
                OpenAiResponsesProvider("responses:test", unreachable, "k", "m")
                    .apply { load(ProviderConfig()).getOrThrow() }
                    .generateStream(GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = listOf(dataUrl)))
                    .collect { }
            }
        }
        assertFalse(
            responses.exceptionOrNull()?.message.orEmpty().contains("不支持读图"),
            "Responses 流式不该再报「不支持读图」：${responses.exceptionOrNull()?.message}",
        )
    }

    @Test
    @DisplayName("★ 不传图 ⇒ 两轨请求体里没有任何图片形状的字节（零回退）")
    fun textOnlyBodiesHaveNoImageBytes() {
        val anthropic = anthropicBody().toString()
        val responses = responsesBody().toString()
        listOf(
            "image_url", "input_image", "base64", "\"image\"", "media_type",
        ).forEach { token ->
            assertFalse(anthropic.contains(token), "Anthropic 纯文本请求体不该出现 `$token`：$anthropic")
            assertFalse(responses.contains(token), "Responses 纯文本请求体不该出现 `$token`：$responses")
        }
    }

    @Test
    @DisplayName("★★ 缺口已兑现：两轨的 buildBody **都有** images 入口（arity 5 / 3）")
    fun bothTracksNowCanExpressImages() {
        // 【原文（2026-10-18）】"两轨连图片形状都构造不出来（buildBody 不收 images）" ——
        //   **那是缺口记录，2026-10-19 已兑现**。当时这段话自己就写明了要做什么：
        //     ① 从 data URL 拆 media_type/base64 ② 真 Key 验证
        //     ③ 把「带图 ⇒ failure」的断言改成形状断言。
        //   ①③ 已做（`DataUrl` + `MultimodalTracksTest`）；**② 仍未做**。
        //
        // 形状（留档，真 Key 验证时对着看）：
        //   Anthropic：{type:"image", source:{type:"base64", media_type, data}}
        //     （SDK `ImageBlockParam` + `Base64ImageSourceParam`：media_type ∈ jpeg/png/gif/webp）
        //   Responses：{type:"input_image", image_url:"<data URL>"}（OpenAPI `InputImageContent`）
        assertEquals(
            1,
            AnthropicProvider::class.java.declaredMethods
                .count { it.name == "buildBody" && it.parameterCount == 5 },
            "★ Anthropic `buildBody` 现在是 5 参（…, tools, images）—— 图片已有入口",
        )
        assertEquals(
            1,
            OpenAiResponsesProvider::class.java.declaredMethods
                .count { it.name == "buildBody" && it.parameterCount == 3 },
            "★ Responses `buildBody` 现在是 3 参（request, stream, images）",
        )
        // 对照：OpenAI 兼容轨的 `buildRequestBody` **有** images 参数（7 参里的最后一个）
        val compatHasImages = OpenAiCompatProvider::class.java.declaredMethods
            .any { it.name == "buildRequestBody" && it.parameterCount == 7 }
        assertTrue(compatHasImages, "对照：已接通的 OpenAI 兼容轨有 7 参（含 images）")
    }

    // ================================================================
    // 8. 请求体自校验（防止"拼坏了才恰好缺字段"）
    // ================================================================

    @Test
    @DisplayName("★ 两轨请求体往返：有/无 tools 都能被重新解析成同结构")
    fun bodiesRoundTrip() {
        listOf(
            anthropicBody(), anthropicBody(tools = specs),
            responsesBody(), responsesBody(tools = specs),
        ).forEach { body ->
            assertEquals(body.toString(), JsonParser.parseString(body.toString()).asJsonObject.toString())
        }
    }
}
