package dev.heracles.provider.http

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.GenerateResult
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **响应侧原生工具调用解析的门禁**（ADR-031 step 2）—— 零真机、零网络。
 *
 * ## 这个文件守的是"最容易假绿"的那一类
 *
 * `tool_calls` 在流里是**分片**到达的，任一单片**都不是合法 JSON**。
 * 如果测试只喂一整片（"参数一次到齐"），那么**拼接写成 JSON 合并、写成覆盖、
 * 甚至写成丢弃**，测试都会绿 —— 而线上必然拼不出东西。
 * 所以每条流式用例都**至少三片**，并且**最后真的 `parse` 一次**：
 * "字符串等于期望"只是充分条件，"能被解析成那个对象"才是证据。
 *
 * ## 分工
 *
 * - 流式：直接测[NativeCallAssembler] 的三个归并器（`index` / content block / `item_id`）
 * - 非流式：[NativeCalls] 三条提取路径，通过**反射**调各 provider 的私有
 *   `parseResponse` / `parseChatResponse`（与 `ProviderContractInjectionTest` 同一手法），
 *   这样测的是**真实 provider 代码**，不是测试里另抄一份逻辑
 *
 * ⚠️ **未验**：三个 provider 的 `generateStream` 里"事件 → 归并器"的那几行接线
 * （它需要 HTTP/SSE 才能跑到）。归并器与响应解析都有测试，接线本身没有 —— 别把
 * 这个文件的绿灯当成"流式接线已验"。
 */
class NativeToolCallParsingTest {

    // ---------------------------------------------------- 反射：真实 provider 的解析入口

    private fun parseOpenAi(json: String): GenerateResult {
        val p = OpenAiCompatProvider(
            id = "cloud:test",
            baseUrl = "https://example.invalid/v1",
            apiKey = "k",
            modelName = "m",
        )
        val m = OpenAiCompatProvider::class.java
            .getDeclaredMethod("parseChatResponse", JsonObject::class.java)
        m.isAccessible = true
        return m.invoke(p, JsonParser.parseString(json).asJsonObject) as GenerateResult
    }

    private fun parseAnthropic(json: String): GenerateResult {
        val p = AnthropicProvider(baseUrl = "https://example.invalid", apiKey = "k", modelName = "m")
        val m = AnthropicProvider::class.java.getDeclaredMethod("parseResponse", String::class.java)
        m.isAccessible = true
        return m.invoke(p, json) as GenerateResult
    }

    private fun parseResponses(json: String): GenerateResult {
        val p = OpenAiResponsesProvider(
            id = "responses:test",
            baseUrl = "https://example.invalid",
            apiKey = "k",
            modelName = "m",
        )
        val m = OpenAiResponsesProvider::class.java.getDeclaredMethod("parseResponse", String::class.java)
        m.isAccessible = true
        return m.invoke(p, json) as GenerateResult
    }

    // ==================================================== 1. OpenAI 兼容：分片拼接

    @Test
    @DisplayName("★★ OpenAI 三片 arguments 拼成**合法 JSON**（单片机拼不出来）")
    fun openAiFragmentsAssembleIntoValidJson() {
        val a = OpenAiToolCalls()
        a.onDelta(0, "call_1", "write_file", "{\"path\":\"a.")
        a.onDelta(0, null, null, "txt\",\"content\":\"")
        a.onDelta(0, null, null, "hi\"}")

        val calls = a.assembled()
        assertEquals(1, calls.size)
        assertEquals("call_1", calls[0].id, "首片才带 id")
        assertEquals("write_file", calls[0].tool)
        assertEquals(
            "{\"path\":\"a.txt\",\"content\":\"hi\"}", calls[0].argumentsJson,
            "arguments 必须是**逐片字符串拼接** —— 覆盖写、JSON 合并都会得到别的东西",
        )

        // ★ 真证据：攒齐后能被解析；单片时**必然失败**
        val obj = JsonParser.parseString(calls[0].argumentsJson).asJsonObject
        assertEquals("a.txt", obj.get("path").asString)
        assertEquals("hi", obj.get("content").asString)
        assertTrue(
            runCatching { JsonParser.parseString("{\"path\":\"a.") }.isFailure,
            "第一片本身必须是**非法 JSON** —— 否则这条测试证明不了「攒齐再 parse」是必要的",
        )
    }

    @Test
    @DisplayName("★ OpenAI：按 index 排序（wire 顺序才是调用顺序），name 只取首次非空")
    fun openAiOrderIsByIndexAndNameIsNotDoubled() {
        val a = OpenAiToolCalls()
        a.onDelta(1, "call_b", "read_file", "{\"path\":\"b\"}")
        a.onDelta(0, "call_a", "write_file", "{\"path\":\"a\"}")
        // 有些实现会把 name 重复上报；拼接会得到 "write_filewrite_file"
        a.onDelta(0, null, "write_file", "")

        val calls = a.assembled()
        assertEquals(listOf("call_a", "call_b"), calls.map { it.id }, "必须按 wire 的 index 排序")
        assertEquals("write_file", calls[0].tool, "name 重复上报时不得拼接出双份")
        assertEquals(2, calls.size, "★ 收到几个给几个 —— 静默丢第二个会让模型以为两个都调了")
    }

    // ==================================================== 2. Anthropic：content block

    @Test
    @DisplayName("★★ Anthropic：input_json_delta 多片拼成合法 JSON（按 content block index）")
    fun anthropicPartialJsonAssembles() {
        val a = AnthropicToolCalls()
        a.onBlockStart(0, "toolu_1", "write_file", null)
        a.onJsonDelta(0, "{\"path\":")
        a.onJsonDelta(0, "\"a.txt\",")
        a.onJsonDelta(0, "\"content\":\"hi\"}")

        val calls = a.assembled()
        assertEquals(1, calls.size)
        assertEquals("toolu_1", calls[0].id)
        assertEquals("write_file", calls[0].tool)
        val obj = JsonParser.parseString(calls[0].argumentsJson).asJsonObject
        assertEquals("a.txt", obj.get("path").asString)
        assertEquals("hi", obj.get("content").asString)
    }

    @Test
    @DisplayName("★ Anthropic：两个 block 交错到达也要各归各的")
    fun anthropicInterleavedBlocksDoNotMix() {
        val a = AnthropicToolCalls()
        a.onBlockStart(0, "toolu_a", "read_file", null)
        a.onBlockStart(1, "toolu_b", "write_file", null)
        a.onJsonDelta(0, "{\"path\":\"a\"}")
        a.onJsonDelta(1, "{\"path\":\"b\"}")
        a.onJsonDelta(0, "")

        val calls = a.assembled()
        assertEquals(listOf("toolu_a", "toolu_b"), calls.map { it.id })
        assertEquals("{\"path\":\"a\"}", calls[0].argumentsJson)
        assertEquals("{\"path\":\"b\"}", calls[1].argumentsJson)
    }

    @Test
    @DisplayName("★ Anthropic：content_block_start 直接给完整 input 对象时，它就是全文")
    fun anthropicStartInputObjectIsUsed() {
        val a = AnthropicToolCalls()
        a.onBlockStart(0, "toolu_1", "list_files", JsonParser.parseString("{\"dir\":\"\"}"))
        assertEquals("{\"dir\":\"\"}", a.assembled()[0].argumentsJson)
    }

    // ==================================================== 3. Responses：item_id + done 权威

    @Test
    @DisplayName("★★ Responses：delta 累积，`output_item.done` 权威（能补上缺片）")
    fun responsesItemDoneIsAuthoritative() {
        val a = ResponsesToolCalls()
        a.onItemAdded("item_1", "call_1", "write_file")
        a.onArgsDelta("item_1", "{\"path\":\"a.")
        a.onArgsDelta("item_1", "txt\"}")
        assertEquals("{\"path\":\"a.txt\"}", a.assembled()[0].argumentsJson, "只靠增量也要能拼出来")

        // 断线重连导致缺片时，done 里的完整 arguments 必须**覆盖**累积值
        val b = ResponsesToolCalls()
        b.onItemAdded("item_1", "call_1", "write_file")
        b.onArgsDelta("item_1", "{\"path\":\"a.")
        b.onItemDone("item_1", "call_1", "write_file", "{\"path\":\"a.txt\",\"content\":\"hi\"}")
        assertEquals(
            "{\"path\":\"a.txt\",\"content\":\"hi\"}", b.assembled()[0].argumentsJson,
            "done 是权威事件 —— 与累积值不一致时必须信它，否则会拼出一个**恰好也像 JSON** 的错对象",
        )
    }

    // ==================================================== 4. 非流式：三家提取 + 结束原因

    @Test
    @DisplayName("★ OpenAI 非流式：message.tool_calls → 中立调用，且 finish_reason=tool_calls 不能丢")
    fun openAiNonStreamingExtractsCalls() {
        val r = parseOpenAi(
            """
            {"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
              "tool_calls":[{"id":"call_1","type":"function",
                "function":{"name":"write_file","arguments":"{\"path\":\"a.txt\"}"}}]}}],
             "usage":{"prompt_tokens":10,"completion_tokens":5}}
            """.trimIndent(),
        )
        assertEquals("", r.text, "原生轨正文可以为空 —— 上层不得当成错误")
        assertEquals(FinishReason.TOOL_CALLS, r.finishReason)
        assertEquals(1, r.toolCalls.size)
        assertEquals("call_1", r.toolCalls[0].id)
        assertEquals("write_file", r.toolCalls[0].tool)
        assertEquals("{\"path\":\"a.txt\"}", r.toolCalls[0].argumentsJson)
    }

    @Test
    @DisplayName("★ OpenAI 非流式：`finish_reason` 缺失但**有调用**时，必须报 TOOL_CALLS（不许静默当成正常结束）")
    fun openAiMissingFinishReasonWithCallsReportsToolCalls() {
        val r = parseOpenAi(
            """
            {"choices":[{"message":{"role":"assistant","tool_calls":[
              {"id":"call_1","function":{"name":"write_file","arguments":"{\"path\":\"a\"}"}}]}}]}
            """.trimIndent(),
        )
        assertEquals(FinishReason.TOOL_CALLS, r.finishReason)
    }

    @Test
    @DisplayName("★ OpenAI 非流式：arguments 被给成**对象**（不合规聚合服务）也不能丢调用")
    fun openAiObjectArgumentsAreSerialized() {
        val r = parseOpenAi(
            """
            {"choices":[{"finish_reason":"tool_calls","message":{"tool_calls":[
              {"id":"call_1","function":{"name":"write_file","arguments":{"path":"a.txt"}}}]}}]}
            """.trimIndent(),
        )
        assertEquals(1, r.toolCalls.size, "对象形状也要认出这个调用")
        assertEquals("{\"path\":\"a.txt\"}", r.toolCalls[0].argumentsJson)
    }

    @Test
    @DisplayName("★ Anthropic 非流式：content 里的 tool_use 块 + stop_reason=tool_use")
    fun anthropicNonStreamingExtractsToolUse() {
        val r = parseAnthropic(
            """
            {"content":[{"type":"text","text":"我来写"},{"type":"tool_use","id":"toolu_1",
              "name":"write_file","input":{"path":"a.txt"}}],
             "stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}
            """.trimIndent(),
        )
        assertEquals("我来写", r.text, "正文块仍要保留（原生轨不排斥正文）")
        assertEquals(FinishReason.TOOL_CALLS, r.finishReason, "`tool_use` 必须映射 —— 老代码落到 STOP")
        assertEquals(1, r.toolCalls.size)
        assertEquals("toolu_1", r.toolCalls[0].id, "tool_use_id 是要原样回传的 wire 事实")
        assertEquals("write_file", r.toolCalls[0].tool)
        assertEquals("{\"path\":\"a.txt\"}", r.toolCalls[0].argumentsJson, "input 是对象 ⇒ 序列化成字符串")
    }

    @Test
    @DisplayName("★ Responses 非流式：output 里的 function_call 项 + status=completed 的真实含义")
    fun responsesNonStreamingExtractsFunctionCall() {
        val r = parseResponses(
            """
            {"status":"completed","output":[{"type":"function_call","id":"fc_1","call_id":"call_1",
              "name":"write_file","arguments":"{\"path\":\"a.txt\"}"}],
             "usage":{"input_tokens":10,"output_tokens":5}}
            """.trimIndent(),
        )
        assertEquals(FinishReason.TOOL_CALLS, r.finishReason)
        assertEquals(1, r.toolCalls.size)
        assertEquals("call_1", r.toolCalls[0].id, "回传要用 call_id（不是 item id）")
        assertEquals("{\"path\":\"a.txt\"}", r.toolCalls[0].argumentsJson)
    }

    @Test
    @DisplayName("★ Responses 非流式：status=incomplete ⇒ LENGTH（老代码恒 STOP ⇒ 截断查不到）")
    fun responsesIncompleteIsLength() {
        val r = parseResponses(
            """{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}""",
        )
        assertEquals(FinishReason.LENGTH, r.finishReason)
        assertTrue(r.toolCalls.isEmpty())
    }

    // ==================================================== 5. 零回退锚点：没有调用时一切照旧

    @Test
    @DisplayName("★ 不带工具调用的响应：结束原因与调用列表都与改动前一致（零回退）")
    fun plainResponsesStayUnchanged() {
        val oa = parseOpenAi(
            """{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"你好"}}]}""",
        )
        assertEquals("你好", oa.text)
        assertEquals(FinishReason.STOP, oa.finishReason)
        assertTrue(oa.toolCalls.isEmpty())

        val an = parseAnthropic(
            """{"content":[{"type":"text","text":"你好"}],"stop_reason":"end_turn"}""",
        )
        assertEquals("你好", an.text)
        assertEquals(FinishReason.STOP, an.finishReason)
        assertTrue(an.toolCalls.isEmpty())

        val rs = parseResponses(
            """{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"你好"}]}]}""",
        )
        assertEquals("你好", rs.text)
        assertEquals(FinishReason.STOP, rs.finishReason)
        assertTrue(rs.toolCalls.isEmpty(), "没有 function_call 项时不得凭空造出调用")
    }
}
