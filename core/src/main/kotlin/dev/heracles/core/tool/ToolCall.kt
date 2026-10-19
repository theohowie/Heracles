package dev.heracles.core.tool

/**
 * 一次解析成功的工具调用。
 *
 * 注意这是**已通过语法约束的原始解析结果**，尚未经过 [ToolValidator] 的语义校验。
 * 两者必须分开：解析失败是格式问题（可重试），校验失败是语义问题（应拒绝）。
 */
data class ToolCall(
    val tool: String,
    val args: Map<String, String>,
)

/**
 * 一次**原生**（provider function calling）工具调用 —— ADR-031 step 2 的载荷。
 *
 * ## 为什么与 [ToolCall] **分开**，而不是给它加一个 `id` 字段
 *
 * ⚠️ **不要**引用"data class 相等性被用于重复检测"当理由 —— **那不是当前代码的事实**：
 * `AgentLoop` 的重复检测是**逐字段比较**（`prev.tool != call.tool || prev.args != call.args`），
 * 全仓库没有任何地方依赖 [ToolCall] 的 data-class 相等性。真正的理由是下面三条：
 *
 * 1. **不该污染执行 IR**：`id` 只在"回填工具结果"时需要，而 [ToolCall] 还要进
 *    GBNF 语法、校验器与记账 —— 那些地方不需要也不该看到 wire id。
 * 2. **两条轨的"相等"语义不同**：文本轨 = 工具名 + 参数；原生轨 = 工具名 + 参数 + wire id。
 *    塞进同一个 data class 后两种语义共用一个 `equals`，谁对谁错取决于读代码的人。
 * 3. **转换点必须唯一**：原生 → 执行的转换只发生在 `AgentOutputParser.fromNativeCall`。
 *    id 一旦进了 [ToolCall]，很容易被顺手拿去做去重 key / 缓存 key ——
 *    而 wire id 由服务端生成、**不可复现**（同样的调用两次会给两个 id），
 *    会把确定性的东西变成不确定。
 *
 * ⇒ 原生轨单独一个类型：`id` 是**必须原样回传的 wire 事实**，
 * 而执行侧只认 [ToolCall]（转换点唯一：`AgentOutputParser.fromNativeCall`）。
 *
 * @param id wire 上的调用 id：OpenAI `tool_calls[].id`、
 *   Anthropic `tool_use` 块的 `id`、Responses 的 `call_id`。
 *   **空串 = 该后端没给 id**（不许自己编一个：回填时对不上会被判非法）。
 * @param tool 工具名（原始值，不在这里做白名单校验）。
 * @param argumentsJson **未解析、未归一化**的 arguments 原文。
 *   OpenAI / Responses 给的本来就是一段 JSON 字符串；Anthropic 给的是对象，
 *   由 provider 序列化成字符串。
 *   ⚠️ 解析与"标量→字符串"归一化**只有一处**（`AgentOutputParser.parseArgs`）——
 *   provider 不许自己归一化，否则两条轨会分叉出"两套真相"。
 */
data class NativeToolCall(
    val id: String,
    val tool: String,
    val argumentsJson: String,
)
