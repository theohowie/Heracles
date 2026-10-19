package dev.heracles.agent

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolCall

/**
 * 解析 agent 的输出（`AgentLoop.TOOL_PROTOCOL` 规定的两种 JSON）。
 *
 * ## 为什么这个解析器必须存在
 *
 * 本地后端用 GBNF **强制**输出形状（`实测-06` 验证有效）。
 * 但**云端不支持 GBNF**（`02-契约规范.md` §6 降级规则），
 * 只能靠 `response_format: json_object` + 提示词 —— 两者都**不保证**。
 *
 * 所以解析器要扛住三种真实失败模式：
 *
 * | 失败模式 | 处理 |
 * |---|---|
 * | 模型把 JSON 包在 markdown 代码块里 | **剥壳后重试解析**（`实测-02` P2 的实测行为） |
 * | 模型输出解释文字而非 JSON | [AgentOutput.Unparseable] → 不执行，让模型重试 |
 * | JSON 合法但字段不对 | [AgentOutput.Unparseable] → 同上 |
 *
 * **核心原则：解析失败时绝不猜模型意图。** 宁可多花一轮，
 * 也不能把"我以为你想删文件"变成真实操作。
 */
internal object AgentOutputParser {

    /**
     * @param knownTools 本次会话**可用**的工具名（[AgentLoop.activeTools]）。
     *   只用于"工具名当顶层键"这一容错形态的白名单判定（见下方 ★★ 形状漂移容错）：
     *   不认识的名字**不猜**，仍然判 [AgentOutput.Unparseable]。
     */
    fun parse(raw: String, knownTools: Set<String> = emptySet()): AgentOutput {
        val text = stripFences(raw).trim()
        if (text.isEmpty()) return AgentOutput.Unparseable("输出为空")

        // ★★ 先试标签形态（2026-10-14 ADR-019；2026-10-16 扩到 apply_patch）★★
        //
        // 为什么**先于 JSON**：`write_file` / `apply_patch` 走标签 + CDATA，
        // 而标签内容里可能含 `{`（HTML/JS/smali 到处都是）——
        // 若先试 JSON，会先失败一次再回落，白跑一遍解析。
        // 标签形态有明确的开始标记（`<write_file` / `<apply_patch`），判起来是 O(1)。
        parseCdataTag(text)?.let { return it }

        val json = runCatching { JsonParser.parseString(text).asJsonObject }.getOrElse {
            return AgentOutput.Unparseable("不是合法 JSON，也不是 <write_file> 标签")
        }

        // 优先判 final —— 有 final 字段就是收工，不再看 tool
        if (json.has("final") && !json.get("final").isJsonNull) {
            return AgentOutput.FinalAnswer(json.get("final").asString)
        }

        // ★ 计划（2026-10-14，harness）：`{"plan":["…","…"]}`
        //
        // 位置：在 tool 之前判 —— 计划与工具不会同时出现，
        // 但计划是"这一轮的特殊产物"，先识别能少一次分支。
        if (json.has("plan") && !json.get("plan").isJsonNull) {
            val plan = TaskPlan.parse(text)
                ?: return AgentOutput.Unparseable("plan 字段格式不对（需要至少 2 个字符串项）")
            return AgentOutput.PlanReady(plan)
        }

        if (json.has("tool") && !json.get("tool").isJsonNull) {
            val name = json.get("tool").asString
            if (name.isBlank()) return AgentOutput.Unparseable("tool 字段为空")
            // ★ 容错②：`{"tool":"apply_patch","path":…,"patch":…}` ——
            //   参数平铺在顶层（没套 `args`）。同样是"同一条调用、另一种写法"。
            //   `args: null` 也不能崩（Gson 的 getAsJsonObject 会抛），所以包一层。
            val argsObj = runCatching { json.getAsJsonObject("args") }.getOrNull()
            val args = argsObj ?: flatArgs(json)
            return AgentOutput.ToolRequest(ToolCall(name, parseArgs(args)))
        }

        // ★★ 形状漂移容错①（2026-10-19 真机实测）★★
        //
        // 现场（设备会话 `s1792340628214` 第 4 轮「添加一个商品详情页。」）：
        // 模型在 `response_format: json_object` 下把调用写成
        // `{"apply_patch":{"path":"mall.html","patch":"@@ -1,1 +1,1 @@\n"}}`
        // —— **工具名当顶层键**。连输出两轮后触发解析熔断，整个任务失败。
        //
        // ## 为什么这不是"猜意图"
        //
        // 键必须**恰好**是本次可用的工具名（[knownTools]）且值是对象，才归一化成
        // `ToolCall`；未知名字仍判 Unparseable（猜垃圾输出才是危险）。
        // 参数照旧走 [parseArgs]，下游 `ToolValidator` 的白名单/必填检查**一步不少**。
        //
        // ## 为什么值得容错
        //
        // 云端请求恒为 `temperature=0`（铁律 3）：复现同一上下文的代价是
        // **必然复现同一错误**。旧实现连挂两轮就熔断 ⇒ 一次语法漂移 = 任务失败，
        // 而这条形状本身语义唯一、可静态判定。
        val entries = json.entrySet()
        if (entries.size == 1) {
            val (key, value) = entries.first()
            if (key in knownTools && value.isJsonObject) {
                return AgentOutput.ToolRequest(ToolCall(key, parseArgs(value.asJsonObject)))
            }
        }

        val keys = entries.map { it.key }
        return AgentOutput.Unparseable(
            if (keys.isEmpty()) {
                "是合法 JSON 对象，但没有任何字段"
            } else {
                "是合法 JSON，但顶层字段只有 ${keys.joinToString("、") { "「$it」" }}，" +
                    "不是 tool / final / plan 三者之一"
            }
        )
    }

    /**
     * **原生轨的入口**（ADR-031 step 2）—— 与 [parse] 汇合到**同一个**中间表示。
     *
     * ## 为什么不复用 [parse]
     *
     * 原生轨拿到的**不是自由文本**，而是 provider 已经拆好的
     * `(工具名, arguments JSON 字符串)`。把它拼回 `{"tool":…}` 或
     * `<write_file>` 文本再走 [parse] 是**故意不做**的：那等于把 wire 事实
     * 降级成"模型的自由发挥"，于是"模型写了个畸形 JSON"与
     * "框架自己拼坏了字符串"再也分不开 —— 排查时最需要区分的恰好是这两者。
     *
     * ## 归一化只有一处
     *
     * `arguments` 走**同一个** [parseArgs]（标量一律转字符串）——
     * 两条轨的 [ToolCall.args] 语义因此逐字段相同，
     * 下游 `ToolValidator` / 工具实现完全不知道调用从哪条轨来。
     *
     * ## 解析失败绝不猜
     *
     * `arguments` 不是合法 JSON 对象 ⇒ [AgentOutput.Unparseable]（**不执行**）。
     * 空串与 `{}` 视为"没有参数"（合法）；其余一律要求是对象。
     */
    fun fromNativeCall(call: NativeToolCall): AgentOutput {
        if (call.tool.isBlank()) return AgentOutput.Unparseable("原生工具调用缺少工具名")
        val json = call.argumentsJson.trim()
        val argsObj = if (json.isEmpty() || json == "{}") {
            null
        } else {
            val el = runCatching { JsonParser.parseString(json) }.getOrNull()
            if (el == null || !el.isJsonObject) {
                return AgentOutput.Unparseable(
                    "原生 tool_calls 的 arguments 不是合法 JSON 对象：${json.take(200)}"
                )
            }
            el.asJsonObject
        }
        return AgentOutput.ToolRequest(ToolCall(call.tool, parseArgs(argsObj)))
    }

    /**
     * **解析 CDATA 标签形态**（2026-10-14 ADR-019；2026-10-16 扩到 `apply_patch`）。
     *
     * ## 期望形态
     *
     * ```
     * <write_file path="index.html">
     * <![CDATA[
     * <!DOCTYPE html>
     * <html lang="zh-CN">
     * …
     * ]]>
     * </write_file>
     * ```
     *
     * ```
     * <apply_patch path="smali/com/x/App.smali">
     * <![CDATA[
     * @@ -12,7 +12,6 @@
     * -    const/4 v0, 0x1
     * +    const/4 v0, 0x0
     * ]]>
     * </apply_patch>
     * ```
     *
     * ## 为什么用正则而不是 XML 解析器
     *
     * 1. 这是**固定形状**（一个标签 + 固定属性），不是通用 XML 文档
     * 2. CDATA 段内的内容**不是 XML**（HTML/JS/smali 里的 `<` `&` 全是裸的）——
     *    交给 XML 解析器反而会炸
     * 3. 正则提取与"绕开转义地狱"的初衷一致：直接切字符串，不解释内容
     *
     * ## CDATA 段的边界（防提前闭合）
     *
     * 用**最后一个** `]]>` 而不是第一个作为结束 —— 若内容里恰好
     * 有 `]]>`（JS 里 `if (a[b[c]] > d)`），取最后一个能保证不截断。
     * GBNF 语法层也已保证"`]]>` 只出现在结尾"。
     *
     * @return 解析成功返回 [AgentOutput.ToolRequest]；**不是标签形态返回 null**
     *         （让调用方继续走 JSON 分支）
     */
    private fun parseCdataTag(text: String): AgentOutput? {
        // O(1) 判定开头，避免对每条自由文本都跑昂贵正则
        val shape = CDATA_SHAPES.firstOrNull { text.startsWith("<${it.tag}") } ?: return null

        val pathMatch = PATH_RE.find(text)
            ?: return AgentOutput.Unparseable("${shape.tag} 标签缺少 path 属性")
        val path = pathMatch.groupValues[1]

        val open = text.indexOf("<![CDATA[")
        if (open < 0) return AgentOutput.Unparseable("${shape.tag} 标签缺少 <![CDATA[ 段")

        // ★ 取**最后一个** `]]>`：内容里偶发的 `]]>` 不致截断
        val close = text.lastIndexOf("]]>")
        if (close < 0 || close <= open) {
            return AgentOutput.Unparseable("${shape.tag} 的 CDATA 段没有正确闭合")
        }

        // 起始符后有一个换行（提示词要求换行，剥掉它避免文件头多一个空行）
        var content = text.substring(open + CDATA_OPEN.length, close)
        if (content.startsWith("\n")) content = content.substring(1)
        // 结尾符前的换行同理（`…;` + \n + `]]>`）
        if (content.endsWith("\n")) content = content.dropLast(1)

        return AgentOutput.ToolRequest(
            ToolCall(shape.tag, mapOf("path" to path, shape.arg to content)),
        )
    }

    /**
     * 走 CDATA 标签形态的工具。
     *
     * ⚠️ 这两个名字必须与**文本轨道协议里教给模型的标签**一致
     * （`AgentLoop.TOOL_PROTOCOL_CLOUD` 的 `<write_file>` / `<apply_patch>`），
     * 否则协议教了、解析器认不出，表现为"模型明明调了工具却没执行"。
     */
    private data class CdataShape(val tag: String, val arg: String)

    private val CDATA_SHAPES = listOf(
        CdataShape("write_file", "content"),
        CdataShape("apply_patch", "patch"),
    )

    private val PATH_RE = Regex("""path\s*=\s*"([^"]*)"""")
    private const val CDATA_OPEN = "<![CDATA["

    /**
     * 解析 args 对象。**值一律按字符串处理** ——
     * 工具参数只允许扁平标量（`02-契约规范.md` §4.2），
     * 模型偶尔会把数字写成不带引号的形式，这里统一转成字符串。
     */
    private fun parseArgs(obj: JsonObject?): Map<String, String> {
        if (obj == null) return emptyMap()
        val out = LinkedHashMap<String, String>()   // 保持插入序，保证确定性
        obj.entrySet().forEach { (k, v) ->
            out[k] = if (v.isJsonNull) "" else runCatching { v.asString }.getOrElse { v.toString() }
        }
        return out
    }

    /** `{"tool":"apply_patch","path":…,"patch":…}` —— 把 `tool`/`args` 之外的顶层字段当参数。 */
    private fun flatArgs(json: JsonObject): JsonObject? {
        val out = JsonObject()
        json.entrySet().forEach { (k, v) ->
            if (k != "tool" && k != "args") out.add(k, v)
        }
        return if (out.size() == 0) null else out
    }

    /**
     * 剥掉 markdown 代码块围栏。
     *
     * **这不是多余的防御** —— `实测-02` P2 实测过：
     * 带 `tools` 的请求下，模型有很高概率把 JSON 包在
     * ```json ... ``` 里。本地靠 GBNF 治住了，云端只能在这里治。
     */
    private fun stripFences(raw: String): String {
        var t = raw.trim()
        if (!t.startsWith("```")) return t

        // 去掉首行围栏（可能带语言标注，如 ```json）
        val firstNewline = t.indexOf('\n')
        if (firstNewline < 0) return t
        t = t.substring(firstNewline + 1)

        // 去掉结尾围栏
        val lastFence = t.lastIndexOf("```")
        if (lastFence >= 0) t = t.substring(0, lastFence)

        return t.trim()
    }
}

/** agent 一轮输出的**四种**可能。 */
internal sealed interface AgentOutput {
    /** 任务完成，给用户的最终答复 */
    data class FinalAnswer(val text: String) : AgentOutput

    /** 请求调用一个工具 */
    data class ToolRequest(val call: ToolCall) : AgentOutput

    /**
     * **产出任务计划**（2026-10-14，harness）。
     *
     * 用户原话：
     * > 「先拿到问题先分析，**做一个待办**，按照待办完成任务」
     *
     * 模型首轮产出结构化待办，此后每轮都以"计划 + 当前进度"
     * 为工作记忆（见 [AgentLoop.renderProgressLedger]）。
     */
    data class PlanReady(val plan: TaskPlan) : AgentOutput

    /**
     * 无法解析。**必须导致"不执行任何工具"** ——
     * 这是防"静默走错路"的关键（`实测-06` 的核心教训）。
     */
    data class Unparseable(val detail: String) : AgentOutput
}
