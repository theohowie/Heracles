package dev.heracles.provider.http

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.ReasoningLevel
import dev.heracles.core.provider.StructuredSpec
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolSpec
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **原生工具的"回放形状"门禁**（ADR-031 step 2 硬前置 1）—— 零真机、零网络。
 *
 * ## 这个文件守的是什么
 *
 * `tool_calls` 一旦进了历史，**两侧**都必须换成原生形状：
 * 发起方（assistant 的 `tool_calls` / `tool_use` / `function_call`）
 * 与结果方（`role:"tool"` / `tool_result` / `function_call_output`）。
 * 只做一半 = **孤立的 tool_calls**：Anthropic 直接判 400，
 * OpenAI 兼容端点会忽略或报错（`docs/02` §6 的降级语义）。
 *
 * | 后端 | assistant 发起 | 结果回填 |
 * |---|---|---|
 * | OpenAI 兼容 | `tool_calls[].{id,type,function{name,arguments}}` | `{role:"tool", tool_call_id, content}` |
 * | Anthropic | `content[].{type:"tool_use", id, name, **input 对象**} ` | user 轮 + `content[].{type:"tool_result", tool_use_id, is_error}` |
 * | Responses | 顶层 item `{type:"function_call", call_id, …}` | 顶层 item `{type:"function_call_output", call_id, output}` |
 *
 * ⚠️ **Anthropic 的 `input` 必须是对象**（不是 JSON 字符串）——
 * "照抄 OpenAI 形状会 400"的另一半就在这里。
 *
 * ## 零回归锚点
 *
 * 文本轨（`nativeCalls` 空、结果消息不带 id）⇒ 请求体必须与改动前**逐字段相同**：
 * OpenAI 只有 `{role, content}`、Anthropic 工具结果是纯文本 user 消息、
 * Responses 是 `{type:"message", …}`。四条断言分别钉住这三家 + `tools` 为空时不加键。
 *
 * ⚠️ **未验**：真实服务端会不会接受这些形状（零 Key、零网络）。
 * 本文件证明的是"与公开 API 文档的形状一致"，不是"服务端已接受"。
 */
class NativeCallReplayTest {

    // ---------------------------------------------------------------- 反射取私有请求体构造器

    /**
     * 按 **名字 + 参数个数**取方法，而不是 `getDeclaredMethod(精确类型)`。
     *
     * 理由：F7b 踩过一次 —— 给 `buildBody` 加个参数后，`getDeclaredMethod` 的
     * 精确签名匹配会在**运行时**抛 `NoSuchMethodException`，而编译是绿的。
     * 按名字 + 个数取，签名微调不会让门禁静默失效。
     */
    private fun privateMethod(cls: Class<*>, name: String, arity: Int) =
        cls.declaredMethods.single { it.name == name && it.parameterCount == arity }
            .apply { isAccessible = true }

    private fun anthropicBody(messages: List<ChatMessage>): JsonObject {
        val p = AnthropicProvider(baseUrl = "https://example.invalid", apiKey = "k", modelName = "m")
        val m = privateMethod(AnthropicProvider::class.java, "buildBody", 4)
        return m.invoke(p, messages, 1024, false, emptyList<ToolSpec>()) as JsonObject
    }

    private fun openAiBody(messages: List<ChatMessage>): JsonObject {
        val p = OpenAiCompatProvider(
            id = "cloud:test", baseUrl = "https://example.invalid/v1", apiKey = "k", modelName = "m",
        )
        val m = privateMethod(OpenAiCompatProvider::class.java, "buildRequestBody", 7)
        return m.invoke(
            p, messages, 1024, StructuredSpec.Json, false, ReasoningLevel.AUTO,
            emptyList<ToolSpec>(), emptyList<String>(),
        ) as JsonObject
    }

    private fun responsesBody(messages: List<ChatMessage>): JsonObject {
        val p = OpenAiResponsesProvider(
            id = "responses:test", baseUrl = "https://example.invalid", apiKey = "k", modelName = "m",
        )
        val request = GenerateRequest(
            prompt = "ignored",
            maxOutputTokens = 1024,
            messages = messages,
        )
        val m = privateMethod(OpenAiResponsesProvider::class.java, "buildBody", 2)
        return m.invoke(p, request, false) as JsonObject
    }

    // ---------------------------------------------------------------- 测试用消息

    private val call = NativeToolCall("call_1", "write_file", "{\"path\":\"a.txt\"}")

    /** 一次"发起调用 + 回填结果"的历史（原生轨）。 */
    private fun nativeHistory(isError: Boolean = false) = listOf(
        ChatMessage(ChatRole.SYSTEM, "系统提示"),
        ChatMessage(ChatRole.USER, "写文件"),
        ChatMessage(ChatRole.ASSISTANT, "", nativeCalls = listOf(call)),
        ChatMessage(ChatRole.TOOL, "已写入", toolCallId = "call_1", isError = isError),
    )

    /** 文本轨的同一段历史（**没有** id ⇒ 必须走老形状）。 */
    private fun textHistory() = listOf(
        ChatMessage(ChatRole.SYSTEM, "系统提示"),
        ChatMessage(ChatRole.USER, "写文件"),
        ChatMessage(ChatRole.ASSISTANT, """{"tool":"write_file","args":{}}"""),
        ChatMessage(ChatRole.USER, "【工具执行结果】write_file → 已写入"),
    )

    // ==================================================== Anthropic

    @Test
    @DisplayName("★★ Anthropic 回放：assistant ⇒ `tool_use` 块，`input` 必须是**对象**")
    fun anthropicAssistantReplaysToolUseBlocks() {
        val body = anthropicBody(nativeHistory())
        val msgs = body.getAsJsonArray("messages")
        val assistant = msgs.map { it.asJsonObject }.last { it.get("role").asString == "assistant" }
        val blocks = assistant.getAsJsonArray("content")
        assertTrue(blocks.size() == 1, "无正文时只该有 tool_use 块（实际 ${blocks.size()}）")

        val block = blocks[0].asJsonObject
        assertEquals("tool_use", block.get("type").asString)
        assertEquals("call_1", block.get("id").asString)
        assertEquals("write_file", block.get("name").asString)
        val input = block.get("input")
        assertTrue(
            input.isJsonObject,
            "★ `input` 必须是**对象**：Anthropic 与 OpenAI 最大的形状差异，" +
                "塞 JSON 字符串会被判非法",
        )
        assertEquals("a.txt", input.asJsonObject.get("path").asString)
    }

    @Test
    @DisplayName("★★ Anthropic 回放：工具结果 ⇒ user 轮 + `tool_result` 块（带 tool_use_id / is_error）")
    fun anthropicToolResultReplaysAsBlock() {
        val ok = anthropicBody(nativeHistory()).getAsJsonArray("messages")
            .map { it.asJsonObject }
            .filter { it.get("role").asString == "user" }
            .last()
        val okBlock = ok.getAsJsonArray("content")[0].asJsonObject
        assertEquals("tool_result", okBlock.get("type").asString)
        assertEquals(
            "call_1", okBlock.get("tool_use_id").asString,
            "★ id 必须与 assistant 里那个 `tool_use.id` **逐字相同**（配对是 Anthropic 的硬要求）",
        )
        assertEquals("已写入", okBlock.get("content").asString)
        assertTrue(okBlock.get("is_error") == null, "成功的结果不该带 is_error")

        val failed = anthropicBody(nativeHistory(isError = true)).getAsJsonArray("messages")
            .map { it.asJsonObject }.filter { it.get("role").asString == "user" }.last()
        assertEquals(
            true, failed.getAsJsonArray("content")[0].asJsonObject.get("is_error").asBoolean,
            "★ 失败必须如实标 is_error —— 标成成功，模型会在错的前提上继续做事",
        )
    }

    @Test
    @DisplayName("★ Anthropic 零回归：文本轨的工具结果仍是纯文本 user 消息")
    fun anthropicTextTrackUnchanged() {
        val body = anthropicBody(textHistory())
        val contents = body.getAsJsonArray("messages").map { it.asJsonObject.get("content") }
        assertTrue(
            contents.all { it.isJsonPrimitive },
            "★ 文本轨的 content 必须还是**字符串**（改成块数组 = 老路径回归）",
        )
        assertTrue(
            body.getAsJsonArray("messages").none {
                it.asJsonObject.get("content").isJsonArray
            },
        )
        assertTrue(body.get("tools") == null, "tools 为空时不得凭空加这个键（请求体逐字节不变）")
    }

    // ==================================================== OpenAI 兼容

    @Test
    @DisplayName("★★ OpenAI 回放：assistant ⇒ `tool_calls`（content 为 null 是合规形状）")
    fun openAiAssistantReplaysToolCalls() {
        val body = openAiBody(nativeHistory())
        val assistant = body.getAsJsonArray("messages").map { it.asJsonObject }
            .last { it.get("role").asString == "assistant" }

        val calls = assistant.getAsJsonArray("tool_calls")
        assertEquals(1, calls.size())
        val c = calls[0].asJsonObject
        assertEquals("call_1", c.get("id").asString)
        assertEquals("function", c.get("type").asString)
        assertEquals("write_file", c.getAsJsonObject("function").get("name").asString)
        assertEquals(
            "{\"path\":\"a.txt\"}",
            c.getAsJsonObject("function").get("arguments").asString,
            "★ arguments 必须是**字符串**（与 Anthropic 的 input 对象相反）",
        )
        assertTrue(
            assistant.get("content").isJsonNull,
            "★ 无正文时要写 null —— 不是空串（空串在部分端点会被当成「乱答」）",
        )
    }

    @Test
    @DisplayName("★★ OpenAI 回放：工具结果 ⇒ role=tool + tool_call_id")
    fun openAiToolMessageReplays() {
        val msgs = openAiBody(nativeHistory()).getAsJsonArray("messages").map { it.asJsonObject }
        val tool = msgs.single { it.get("role").asString == "tool" }
        assertEquals("call_1", tool.get("tool_call_id").asString)
        assertEquals("已写入", tool.get("content").asString)
    }

    @Test
    @DisplayName("★ OpenAI 零回归：文本轨消息仍是 `{role, content}` 两个键")
    fun openAiTextTrackUnchanged() {
        val msgs = openAiBody(textHistory()).getAsJsonArray("messages").map { it.asJsonObject }
        assertTrue(
            msgs.none { it.has("tool_calls") || it.has("tool_call_id") },
            "★ 文本轨不许出现原生键",
        )
        assertTrue(
            msgs.all { it.get("content").isJsonPrimitive },
            "★ 文本轨 content 必须还是字符串",
        )
    }

    // ==================================================== Responses

    @Test
    @DisplayName("★★ Responses 回放：调用与结果都是**顶层 item**（function_call / function_call_output）")
    fun responsesReplaysTopLevelItems() {
        val input = responsesBody(nativeHistory()).getAsJsonArray("input").map { it.asJsonObject }

        val callItem = input.single { it.get("type").asString == "function_call" }
        assertEquals("call_1", callItem.get("call_id").asString)
        assertEquals("write_file", callItem.get("name").asString)
        assertEquals("{\"path\":\"a.txt\"}", callItem.get("arguments").asString)

        val outItem = input.single { it.get("type").asString == "function_call_output" }
        assertEquals(
            "call_1", outItem.get("call_id").asString,
            "★ call_id 必须与 function_call 项逐字相同",
        )
        assertEquals("已写入", outItem.get("output").asString)
    }

    @Test
    @DisplayName("★ Responses 零回归：文本轨仍是 message 项；空正文的 assistant 也不会凭空多出调用")
    fun responsesTextTrackUnchanged() {
        val input = responsesBody(textHistory()).getAsJsonArray("input").map { it.asJsonObject }
        assertTrue(
            input.all { it.get("type").asString == "message" },
            "★ 文本轨每一项都必须是 message",
        )
        assertEquals(
            "user", input.last().get("role").asString,
            "老行为：工具结果作为 user 文本回灌",
        )
    }

    // ==================================================== 通用：配对完整性

    @Test
    @DisplayName("★★ 三家的配对完整性：每个发起的调用 id 都能找到结果 id（防『孤立的 tool_calls』）")
    fun everyCallHasAPairedResultInAllThreeShapes() {
        val history = nativeHistory()

        // Anthropic：assistant 的 tool_use.id ↔ user 轮的 tool_use_id
        val an = anthropicBody(history).getAsJsonArray("messages").map { it.asJsonObject }
        val anCalls = an.filter { it.get("role").asString == "assistant" }
            .flatMap { m -> m.getAsJsonArray("content").map { it.asJsonObject } }
            .filter { it.get("type").asString == "tool_use" }
            .map { it.get("id").asString }
        val anResults = an.flatMap { m ->
            val c = m.get("content")
            if (c == null || !c.isJsonArray) emptyList() else c.asJsonArray.map { it.asJsonObject }
        }.filter { it.get("type").asString == "tool_result" }
            .map { it.get("tool_use_id").asString }
        assertEquals(anCalls, anResults, "Anthropic：发起与结果必须一一配对")

        // OpenAI：tool_calls[].id ↔ role=tool.tool_call_id
        val oa = openAiBody(history).getAsJsonArray("messages").map { it.asJsonObject }
        val oaCalls = oa.flatMap { m ->
            val c = m.get("tool_calls")
            if (c == null || !c.isJsonArray) emptyList() else c.asJsonArray.map { it.asJsonObject.get("id").asString }
        }
        val oaResults = oa.filter { it.get("role").asString == "tool" }
            .map { it.get("tool_call_id").asString }
        assertEquals(oaCalls, oaResults, "OpenAI：发起与结果必须一一配对")

        // Responses：function_call.call_id ↔ function_call_output.call_id
        val rs = responsesBody(history).getAsJsonArray("input").map { it.asJsonObject }
        val rsCalls = rs.filter { it.get("type").asString == "function_call" }
            .map { it.get("call_id").asString }
        val rsResults = rs.filter { it.get("type").asString == "function_call_output" }
            .map { it.get("call_id").asString }
        assertEquals(rsCalls, rsResults, "Responses：发起与结果必须一一配对")
    }

    @Test
    @DisplayName("★ 上限口径有出处：Contract.Tools.MAX_NATIVE_CALLS_PER_TURN 存在且为 4（v2，不许有魔法数字）")
    fun maxNativeCallsComesFromContract() {
        assertEquals(
            4, Contract.Tools.MAX_NATIVE_CALLS_PER_TURN,
            "改动这个数必须同时改本断言与 AgentLoop 的批处理口径（AGENTS：魔法数字进 Contract）",
        )
    }

    /** 供上一条用例的解析健壮性：确认 body 本身是合法 JSON（防止把"解析失败"当绿）。 */
    private fun JsonObject.roundTrip(): JsonObject =
        JsonParser.parseString(toString()).asJsonObject

    @Test
    @DisplayName("★ 请求体自校验：三家产出的 body 都能再解析回同结构（不是拼坏了才恰好缺字段）")
    fun bodiesRoundTrip() {
        listOf(anthropicBody(nativeHistory()), openAiBody(nativeHistory()), responsesBody(nativeHistory()))
            .forEach { body ->
                val again = body.roundTrip()
                assertEquals(body.toString(), again.toString(), "请求体必须是可往返的合法 JSON")
            }
    }
}
