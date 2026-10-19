package dev.heracles.provider.http

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import dev.heracles.core.tool.NativeToolCall

/**
 * 原生工具调用的**分片归并**与**响应形状提取** —— ADR-031 step 2 响应侧的**唯一**实现点。
 *
 * ## 为什么必须集中在这里
 *
 * `tool_calls` 在流里是**分片**到达的，而**任一单片都不是合法 JSON**：
 *
 * | 后端 | 分片事件 | 归并键 | 关键字段 |
 * |---|---|---|---|
 * | OpenAI 兼容 | `choices[].delta.tool_calls[]` | `index` | `function.arguments` **逐片字符串拼接** |
 * | Anthropic | `content_block_delta` + `input_json_delta` | content block `index` | `partial_json` 拼接 |
 * | Responses | `response.function_call_arguments.delta` | `item_id` | `delta` 拼接，`output_item.done` **权威** |
 *
 * ### 三条铁律（写在这里，因为这里是唯一会被改到的地方）
 *
 * 1. **`arguments` 是字符串拼接，不是 JSON 合并** —— 对 `{"a":1}` + `{"b":2}` 做"合并"
 *    会得到两个键、恰好也是错的结果，所以"看起来也能跑"；真相是 `{"a":1b":2}` 这种
 *    逐字拼接结果，**只有攒齐后再 parse** 才知道对不对。
 * 2. **思考/正文增量绝不并入 `arguments`** —— 结构上保证：这些函数的入参只有参数碎片，
 *    没有任何地方能塞进 `delta.text` / `delta.thinking`。
 * 3. **攒齐再 parse**：归并产出的只是**原始字符串**（[NativeToolCall.argumentsJson]），
 *    合法性由上层 `AgentOutputParser.fromNativeCall` 判定；**本层不解析、不归一化**，
 *    否则"标量→字符串"的规则会分叉成两套（两套真相）。
 *
 * ## 也**不**做的事
 *
 * 不做 `MAX_NATIVE_CALLS_PER_TURN` 的口径裁剪 —— **收到几个就原样给几个**：
 * 只留第一个会让模型以为它调了全部工具（静默丢），口径由 `AgentLoop` 决定并如实报告。
 */

/** OpenAI 兼容的 `delta.tool_calls[]` 归并器（非流式走 [NativeCalls.fromOpenAiMessage]）。 */
internal class OpenAiToolCalls {
    private class Slot {
        var id: String = ""
        var name: String = ""
        val args = StringBuilder()
    }

    private val slots = LinkedHashMap<Int, Slot>()

    /**
     * @param index wire 上的 `index`（缺省时调用方用数组下标兜底）
     * @param id 只有首片会给（`call_xxx`）
     * @param name 只取**首次出现的非空值**：契约里只有 `arguments` 是逐片拼接的，
     *   name 被重复上报时拼接会得到双份（"write_filewrite_file"）
     * @param argsFragment `function.arguments` 的**碎片**
     */
    fun onDelta(index: Int, id: String?, name: String?, argsFragment: String?) {
        val s = slots.getOrPut(index) { Slot() }
        if (!id.isNullOrEmpty()) s.id = id
        if (!name.isNullOrEmpty() && s.name.isEmpty()) s.name = name
        if (!argsFragment.isNullOrEmpty()) s.args.append(argsFragment)
    }

    /** 按 `index` **升序**给出（wire 上的顺序就是模型的调用顺序，不能靠到达顺序）。 */
    fun assembled(): List<NativeToolCall> = slots.entries
        .sortedBy { it.key }
        .map { (_, s) -> NativeToolCall(s.id, s.name, s.args.toString()) }
}

/** Anthropic 的 content block + `input_json_delta.partial_json` 归并器。 */
internal class AnthropicToolCalls {
    private class Slot {
        var id: String = ""
        var name: String = ""
        val json = StringBuilder()
    }

    private val slots = LinkedHashMap<Int, Slot>()

    /**
     * `content_block_start`：`content_block.type == "tool_use"` 时给 `id` / `name`
     * （有些实现会**顺手给完整 `input` 对象**，此时直接当全文用）。
     */
    fun onBlockStart(index: Int, id: String?, name: String?, input: JsonElement?) {
        val s = slots.getOrPut(index) { Slot() }
        if (!id.isNullOrEmpty()) s.id = id
        if (!name.isNullOrEmpty() && s.name.isEmpty()) s.name = name
        if (s.json.isEmpty() && input != null && input.isJsonObject && input.asJsonObject.size() > 0) {
            s.json.append(input.toString())
        }
    }

    /** `content_block_delta` 且 `delta.type == "input_json_delta"` 的 `partial_json`。 */
    fun onJsonDelta(index: Int, partialJson: String?) {
        if (partialJson.isNullOrEmpty()) return
        slots.getOrPut(index) { Slot() }.json.append(partialJson)
    }

    fun assembled(): List<NativeToolCall> = slots.entries
        .sortedBy { it.key }
        .map { (_, s) -> NativeToolCall(s.id, s.name, s.json.toString()) }
}

/** Responses 的 `function_call_arguments.delta` 归并器（以 `output_item.done` 为准）。 */
internal class ResponsesToolCalls {
    private class Slot {
        var callId: String = ""
        var name: String = ""
        val args = StringBuilder()
    }

    /** key = `item_id`（argument 事件只给 item_id，所以它才是稳定键）。 */
    private val slots = LinkedHashMap<String, Slot>()

    private fun slot(itemId: String): Slot = slots.getOrPut(itemId) { Slot() }

    fun onItemAdded(itemId: String, callId: String?, name: String?) {
        if (itemId.isEmpty()) return
        val s = slot(itemId)
        if (!callId.isNullOrEmpty()) s.callId = callId
        if (!name.isNullOrEmpty() && s.name.isEmpty()) s.name = name
    }

    fun onArgsDelta(itemId: String, delta: String?) {
        if (itemId.isEmpty() || delta.isNullOrEmpty()) return
        slot(itemId).args.append(delta)
    }

    /**
     * `response.output_item.done` —— **权威**：用它整体替换累积值。
     *
     * 理由：documented 契约是"以 `output_item.done` 为准"，那条事件里带完整的
     * `arguments`；若它与累积值不一致，**信它**（前面的增量可能因断线/重连缺片）。
     */
    fun onItemDone(itemId: String, callId: String?, name: String?, arguments: String?) {
        if (itemId.isEmpty()) return
        val s = slot(itemId)
        if (!callId.isNullOrEmpty()) s.callId = callId
        if (!name.isNullOrEmpty()) s.name = name
        if (arguments != null) {
            s.args.clear()
            s.args.append(arguments)
        }
    }

    fun assembled(): List<NativeToolCall> = slots.values
        .map { NativeToolCall(it.callId, it.name, it.args.toString()) }
}

/** 三家**非流式**响应里的调用提取 —— 与上面的流式归并产出同一种中立类型。 */
internal object NativeCalls {

    /**
     * OpenAI 兼容：`choices[0].message.tool_calls[]`。
     *
     * 合规形状：`{id, type:"function", function:{name, arguments:"<JSON 字符串>"}}`。
     * ⚠️ 有些聚合服务把 `arguments` 直接给成**对象**（不合规但真实存在）——
     * 那种情况序列化成字符串，而不是丢掉这个调用。
     */
    fun fromOpenAiMessage(message: JsonObject?): List<NativeToolCall> {
        val arr = message?.getAsJsonArray("tool_calls") ?: return emptyList()
        val out = ArrayList<NativeToolCall>(arr.size())
        for (el in arr) {
            if (el == null || !el.isJsonObject) continue
            val tc = el.asJsonObject
            val fn = tc.get("function")?.takeIf { it.isJsonObject }?.asJsonObject
            out += NativeToolCall(
                id = tc.str("id"),
                tool = fn?.str("name") ?: tc.str("name"),
                argumentsJson = argumentsOf(fn?.get("arguments") ?: tc.get("arguments")),
            )
        }
        return out
    }

    /**
     * Anthropic：`content[]` 里 `type == "tool_use"` 的块。
     *
     * `input` 是**对象**（不是字符串）⇒ 序列化成字符串，
     * 与 OpenAI 那条路产出同一种"未解析原文"。
     */
    fun fromAnthropicContent(root: JsonObject): List<NativeToolCall> {
        val arr = root.getAsJsonArray("content") ?: return emptyList()
        val out = ArrayList<NativeToolCall>(arr.size())
        for (el in arr) {
            if (el == null || !el.isJsonObject) continue
            val b = el.asJsonObject
            if (b.str("type") != "tool_use") continue
            val input = b.get("input")
            out += NativeToolCall(
                id = b.str("id"),
                tool = b.str("name"),
                argumentsJson = if (input == null || input.isJsonNull) "{}" else input.toString(),
            )
        }
        return out
    }

    /** Responses：`output[]` 里 `type == "function_call"` 的项（`call_id` 是要回传的 id）。 */
    fun fromResponsesOutput(root: JsonObject): List<NativeToolCall> {
        val arr = root.getAsJsonArray("output") ?: return emptyList()
        val out = ArrayList<NativeToolCall>(arr.size())
        for (el in arr) {
            if (el == null || !el.isJsonObject) continue
            val item = el.asJsonObject
            if (item.str("type") != "function_call") continue
            out += NativeToolCall(
                id = item.str("call_id").ifEmpty { item.str("id") },
                tool = item.str("name"),
                argumentsJson = argumentsOf(item.get("arguments")),
            )
        }
        return out
    }

    /** `arguments` 既可能是字符串（合规），也可能是对象（部分聚合服务）。 */
    private fun argumentsOf(el: JsonElement?): String = when {
        el == null || el.isJsonNull -> ""
        el.isJsonPrimitive -> el.asString
        else -> el.toString()
    }

    private fun JsonObject.str(field: String): String =
        get(field)?.takeIf { !it.isJsonNull }?.asString.orEmpty()
}
