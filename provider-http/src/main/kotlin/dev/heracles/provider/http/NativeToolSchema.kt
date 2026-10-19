package dev.heracles.provider.http

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.context.PrefixBuilder
import dev.heracles.core.tool.ToolSpec

/**
 * 工具声明的**两种表达**之间的唯一映射点 —— ADR-031 决策 2（请求侧）。
 *
 * ## 它存在的理由：不许有"两套真相"
 *
 * 同一批 `ToolSpec` 现在有两条出口：
 *
 * | 轨 | 长什么样 | 谁在用 |
 * |---|---|---|
 * | **文本轨** | `PrefixBuilder.canonicalToolJson`（进冻结前缀，模型照着它写 JSON/标签） | 本地 GBNF + 云端降级 |
 * | **原生轨** | 各家 `tools` 数组（`function` / `input_schema` / 扁平） | 云端原生 function calling |
 *
 * 两轨都由**同一个函数**产出语义内核：本文件把 `canonicalToolJson` 解析成 JSON 对象，
 * 各家只是**换外壳**（`{"type":"function","function":…}` / `{"input_schema":…}` / 扁平）。
 * ⇒ 工具的**名字、参数、描述、必填性**在任何一家里都不可能与文本轨分叉；
 * 想加"原生轨特有的字段"时，**先改 `canonicalToolJson`**，别在这里各写一份。
 *
 * ## ⚠️ 能力位 ≠ 已启用
 *
 * [dev.heracles.core.provider.ProviderCapabilities.supportsNativeTools] 只声明
 * "这个后端的 API 有能力"；**是否真的发**由装配方显式决定
 * （`AgentLoop(nativeToolsEnabled = …)`）。原因：响应侧还没解析 `tool_calls` 时
 * 发 `tools`，等于把"输出方言解析失败"换成"模型走原生通道、正文为空" ——
 * 那是**更难查的静默失败**。ADR-031 第 2 步落地前不要打开。
 *
 * ## 只装常驻工具（与披露机制天然冲突）
 *
 * 长尾工具是**逐轮披露**的（ADR-023）。若把它们也塞进 `tools` 数组，数组会随披露
 * **变长** ⇒ 前缀每次都抖、缓存命中率全塌。所以数组只装常驻工具；
 * 披露工具继续走文本轨。**这是设计取舍，不是遗漏。**
 *
 * ## 流式分片的契约（响应侧 / ADR-031 step 2 —— 先写死，免得写成"拼不起来"）
 *
 * `tool_calls` 在流式里**分片**到达，且**任一单片都不是合法 JSON**。
 * 三家的事件形状不同，但铁律相同：**攒齐再 parse，绝不逐片 parse**。
 *
 * | 家 | 拼什么 | 怎么归并 |
 * |---|---|---|
 * | OpenAI 兼容 | `choices[].delta.tool_calls[].function.arguments`（字符串片） | 按 `index` 归并；`id` / `function.name` **常只在首片**出现，后片为 null；最后一片的 `finish_reason == "tool_calls"`，`usage` 在带 `stream_options.include_usage` 的末块 |
 * | Anthropic | `content_block_delta` 里 `input_json_delta.partial_json` | 按 `content_block` 的**序号**归并；`content_block_start` 给 `id`/`name`（`input` 是空对象），`content_block_stop` 收口 |
 * | OpenAI Responses | `response.function_call_arguments.delta` | 按 `item_id` 归并；`response.output_item.added` 给 `name`/`call_id`，**以 `response.output_item.done` 的完整 arguments 为准**（它有全文，能自校验拼接） |
 *
 * 三条不许破的：
 * 1. **thinking/reasoning 增量绝不并入 `arguments`** —— 混进去就是非法 JSON，
 *    而且症状会伪装成"模型参数写错"。
 * 2. `arguments` 是**字符串拼接**，不是 JSON 合并（`{"a":` + `1}`）。
 * 3. 一轮里可能有**多个** `tool_calls`（并行调用）—— 我们**只执行一个**
 *    （`Contract.Tools.MAX_NATIVE_CALLS_PER_TURN`），≥2 个时**报错并明说收到了几个**，
 *    **不许静默丢**（模型会以为它调了三个工具）。
 */
internal object NativeToolSchema {

    /**
     * canonical 函数体（`{"name","description","parameters"}`）—— 两轨的**共同内核**。
     *
     * 刻意**解析** `canonicalToolJson` 而不是另拼一份：后者迟早与文本轨分叉，
     * 而分叉的表现是"模型按原生 schema 填了参数，校验器却按文本轨判非法"。
     */
    fun canonicalBody(tool: ToolSpec): JsonObject =
        JsonParser.parseString(PrefixBuilder.canonicalToolJson(tool)).asJsonObject

    /**
     * OpenAI 兼容（`/chat/completions`）：
     * `[{"type":"function","function":{"name","description","parameters"}}]`
     */
    fun openAiCompat(tools: List<ToolSpec>): JsonArray = JsonArray().apply {
        tools.forEach { tool ->
            add(
                JsonObject().apply {
                    addProperty("type", "function")
                    add("function", canonicalBody(tool))
                },
            )
        }
    }

    /**
     * Anthropic（`/v1/messages`）：
     * `[{"name","description","input_schema":{…}}]`
     *
     * 注意是 `input_schema`（不是 `parameters`），且**不套 `function` 外层** ——
     * Anthropic 的 tools 直接在顶层。照抄 OpenAI 形状会被判 400。
     */
    fun anthropic(tools: List<ToolSpec>): JsonArray = JsonArray().apply {
        tools.forEach { tool ->
            val body = canonicalBody(tool)
            add(
                JsonObject().apply {
                    add("name", body.get("name"))
                    add("description", body.get("description"))
                    // 参数对象**整体**搬过去（同一个 JSON 对象，不复制字段）
                    add("input_schema", body.get("parameters"))
                },
            )
        }
    }

    /**
     * OpenAI Responses（`/v1/responses`）：`[{"type":"function","name","description","parameters"}]`
     *
     * 与 `/chat/completions` 的区别是**扁平**：没有 `function` 外层。
     */
    fun responses(tools: List<ToolSpec>): JsonArray = JsonArray().apply {
        tools.forEach { tool ->
            val body = canonicalBody(tool)
            add(
                JsonObject().apply {
                    addProperty("type", "function")
                    add("name", body.get("name"))
                    add("description", body.get("description"))
                    add("parameters", body.get("parameters"))
                },
            )
        }
    }
}
