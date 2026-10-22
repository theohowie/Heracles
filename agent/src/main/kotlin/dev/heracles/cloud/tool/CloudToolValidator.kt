package dev.heracles.cloud.tool

import dev.heracles.cloud.context.CloudToolCall

/**
 * **云端工具调用校验器**（`CloudAgentPipeline`，模块三）。
 *
 * ## 它替代了旧 `ToolValidator` 的什么
 *
 * 旧实现（`core/.../tool/ToolValidator.kt`）有四层校验，其中两层是**断头台**：
 *
 * | 旧规则 | 位置 | 对强模型的后果 |
 * |---|---|---|
 * | 按**参数名**猜语义：`content/text/body/code/patch/diff`→100KB、`command`→4000、**其余一律 500** | `:109-115` | `edit.old_string`/`new_string`、`update_plan.steps`、`ask_user.questions` 全落 500 ⇒ **常驻工具的正常输入被拦死**（英文 6 步计划实测 513 字符，直接超限） |
 * | 空值一律非法（除非 `allowEmpty`） | `:67-69` | 合法的 `dir: ""` 被拦（真机事故：模型放弃并谎称完成） |
 * | 控制字符非法 | `:86-93` | 首版把 `\n` 也算非法 ⇒ **Markdown 完全写不出来** |
 * | 必填/未知参数 | `:41-53` | 这条**保留**（防臆造参数名） |
 *
 * ## 本类的原则：**只做 schema 校验 + 一条物理安全阀**
 *
 * 1. **校验依据是 JSON Schema 本身**（类型、必填、枚举），不是参数名的字符串比较
 * 2. **不设任何"字符数上限"** —— 模型想写 200KB 的代码就让它写
 * 3. 唯一的物理闸是 [MAX_PAYLOAD_BYTES]（10MB）—— 防 Android OOM，不是防模型
 * 4. 超限时给出**明确、可操作**的提示，由模型**自主决定**分块 —— 不替它决定
 *
 * ## 为什么"值不合法"要报 Schema 错误而不是"猜着修"
 *
 * 改成 `Integer` 之后，模型给 `"200"`（字符串）是**真实的类型错误**。
 * 旧实现用 `toString()` 把所有东西抹平（`AgentOutputParser.kt:244-251`），
 * 于是"模型填错类型"这个事实永远消失了。现在**如实报错**，
 * 模型看到 `expected integer, got string "200"` 一轮就能改对 —— 它有这个能力。
 */
object CloudToolValidator {

    /**
     * **唯一的物理安全阀**：单次调用的参数总量上限 10MB。
     *
     * ## 为什么是 10MB 而不是 500 字符
     *
     * 500 字符是"防小模型失控续写"的经验值（旧注释自己写着）。云端强模型不会无故续写，
     * 而 500 字符会**拦死正常编辑**。
     *
     * 10MB 是**物理**约束：Android 上单个 JVM 字符串/字节数组超过这个量级很容易 OOM，
     * 而且它在 `arg1`（GC 压力）上就开始拖慢整个 App。这是设备限制，不是模型限制。
     *
     * ## 超限时的行为：**明确提示，由模型自主决定**
     *
     * 不自动切块、不静默截断。模型会看到"你的 content 是 12.3MB，超过 10MB 上限，
     * 请拆成多次 write_file / 用 apply_patch 分段" —— 然后**它自己**决定怎么分。
     * 这是"给模型信息"而不是"替模型做决定"。
     */
    const val MAX_PAYLOAD_BYTES = 10 * 1024 * 1024

    /**
     * 校验一次调用。
     *
     * @param call 模型发起的调用（arguments 原文）
     * @param schema 该工具的 JSON Schema（**空 = 该工具不接受参数**）
     * @return 通过 / 失败（带**具体到字段与类型**的原因）
     */
    fun validate(call: CloudToolCall, schema: ToolSchema?): Result {
        val raw = call.argumentsJson.trim()

        // 空串与 `{}` 等价于"没有参数"（与旧实现一致，且是正确的）
        if (raw.isEmpty() || raw == "{}") {
            val missing = schema?.requiredParams().orEmpty()
            return if (missing.isEmpty()) {
                Result.Valid(emptyMap())
            } else {
                Result.Invalid("缺少必填参数：${missing.joinToString()}")
            }
        }

        val parsed = parseObject(raw)
            ?: return Result.Invalid(
                "arguments 不是合法的 JSON 对象。收到：${raw.preview()}。" +
                    "请输出标准 JSON 对象（双引号键、无尾逗号），例如 {\"path\":\"a.txt\"}"
            )

        if (schema == null) {
            return if (parsed.isEmpty()) {
                Result.Valid(emptyMap())
            } else {
                Result.Invalid("工具 ${call.name} 不接受参数，但收到了：${parsed.keys.joinToString()}")
            }
        }

        val errors = mutableListOf<String>()

        // ① 未知参数 —— 防臆造（这条是从旧实现**保留**的正确规则）
        val known = schema.params.map { it.name }.toSet()
        val unknown = parsed.keys - known
        if (unknown.isNotEmpty()) {
            errors += "未知参数：${unknown.joinToString()}（该工具接受：${known.joinToString()}）"
        }

        // ② 必填缺失
        val missing = schema.requiredParams().filter { it !in parsed.keys }
        if (missing.isNotEmpty()) {
            errors += "缺少必填参数：${missing.joinToString()}"
        }

        // ③ **按 Schema 校验类型** —— 这是旧实现完全没有的能力
        for (p in schema.params) {
            val v = parsed[p.name] ?: continue
            val typeError = checkType(p, v)
            if (typeError != null) errors += typeError
        }

        if (errors.isNotEmpty()) return Result.Invalid(errors.joinToString("；"))

        // ④ 唯一的物理安全阀
        val bytes = raw.toByteArray(Charsets.UTF_8).size
        if (bytes > MAX_PAYLOAD_BYTES) {
            val mb = String.format("%.1f", bytes / 1024.0 / 1024.0)
            val limitMb = MAX_PAYLOAD_BYTES / 1024 / 1024
            return Result.Invalid(
                "参数总量 ${mb}MB，超过单次调用上限 ${limitMb}MB（这是 Android 内存限制，不是 token 限制）。" +
                    "请自主选择做法：① 用 apply_patch 只发差异片段；" +
                    "② 把内容拆成多次 write_file / edit 调用；" +
                    "③ 先写骨架，再用 apply_patch 增量补齐。"
            )
        }

        // ★ 校验全过之后，才把**字符串值的引号去掉**交给工具执行。
        //
        // 为什么必须在这一步（而不是 parseObject 里）：
        // `checkType` 需要看到引号才能判出 `string`；提前去引号会让所有字符串
        // 被判成 `unknown` ⇒ 校验全红（这正是我第一版修法的错法，单测立刻抓到）。
        //
        // 为什么必须做：
        // 不去引号 ⇒ 工具拿到 `"a.txt"`（带引号）当路径 ⇒ **文件永远找不到**。
        // 2026-10-21 真机症状：`read_file` / `write_file` 全部失败，但日志只显示
        // "调用了它"，看不出失败 ⇒ 模型反复重试 20 轮后放弃。
        return Result.Valid(parsed.mapValues { (_, v) -> unquoteIfString(v) })
    }

    // ---------------------------------------------------------------- 内部

    sealed interface Result {
        /** 校验通过，[args] 是**已解析**的参数（值保持 JSON 原始字符串表示）。 */
        data class Valid(val args: Map<String, String>) : Result

        data class Invalid(val detail: String) : Result
    }

    /**
     * 按 Schema 检查一个值的类型。
     *
     * 返回 `null` = 合法；否则返回**带期望类型与实际值**的原因。
     *
     * ⚠️ 这里**不做任何"宽容归一化"**（不把 `"200"` 当 200、不把 `"true"` 当 true）：
     * 那会让"模型填错类型"这个事实永远消失。模型看到具体错误一轮就能改对。
     */
    private fun checkType(p: SchemaParam, rawJsonValue: String): String? {
        val kind = when {
            rawJsonValue.startsWith("\"") -> "string"
            rawJsonValue == "true" || rawJsonValue == "false" -> "boolean"
            rawJsonValue == "null" -> "null"
            rawJsonValue.startsWith("[") -> "array"
            rawJsonValue.startsWith("{") -> "object"
            rawJsonValue.toDoubleOrNull() != null -> "number"
            else -> "unknown"
        }
        val expected = p.type
        val ok = when (expected) {
            "string" -> kind == "string"
            "integer" -> kind == "number" && rawJsonValue.toDoubleOrNull()?.let { it % 1.0 == 0.0 } == true
            "number" -> kind == "number"
            "boolean" -> kind == "boolean"
            "array" -> kind == "array"
            "object" -> kind == "object"
            else -> true
        }
        if (!ok) {
            return "参数 ${p.name} 类型错：期望 $expected，实际是 $kind（收到 ${rawJsonValue.preview()}）"
        }
        // 枚举校验
        if (p.enum.isNotEmpty() && kind == "string") {
            val actual = rawJsonValue.removeSurrounding("\"")
            if (actual !in p.enum) {
                return "参数 ${p.name} 取值非法：收到「$actual」，只允许 ${p.enum.joinToString("/")}"
            }
        }
        return null
    }

    private fun String.preview(): String =
        if (length <= 80) this else take(77) + "…"

    // ---------------------------------------------------------------- 极简 JSON 对象解析

    /**
     * 把 `arguments` 原文解析成"键 → **值的原始 JSON 文本**"。
     *
     * ## 为什么不用 Gson
     *
     * `:agent` 有 Gson，用它当然更省事。但这里刻意手写一个**只认顶层对象**的最小解析器，
     * 理由与 `PrefixBuilder` 手工序列化相同：**我们要保留每个值的原始类型信息**
     * （`"200"` vs `200` vs `200.0`），而 `Gson` 的 `asString` 会把它们全抹成字符串。
     * 保留原文才能让 [checkType] 判出真实的类型错误。
     *
     * ## 只支持顶层对象
     *
     * `arguments` 契约就是"一个 JSON 对象"（OpenAI/Anthropic/Responses 三家一致）。
     * 顶层不是对象 ⇒ 返回 `null`（调用方报"不是合法 JSON 对象"）。
     * 嵌套值**不深入解析**，原样保留文本（由工具自己按需处理）。
     */
    private fun parseObject(raw: String): Map<String, String>? {
        val s = raw.trim()
        if (!s.startsWith("{") || !s.endsWith("}")) return null
        val out = LinkedHashMap<String, String>()
        var i = 1
        val end = s.length - 1
        while (i < end) {
            while (i < end && s[i].isWhitespace()) i++
            if (i < end && s[i] == ',') { i++; continue }
            if (i >= end) break
            // 键必须是双引号字符串
            if (s[i] != '"') return null
            val keyEnd = findStringEnd(s, i)
            if (keyEnd < 0) return null
            val key = unescape(s.substring(i + 1, keyEnd))
            i = keyEnd + 1
            while (i < end && s[i].isWhitespace()) i++
            if (i >= end || s[i] != ':') return null
            i++
            while (i < end && s[i].isWhitespace()) i++
            // 值：原样切到顶层的 , 或 }
            val valStart = i
            var depth = 0
            var inStr = false
            var esc = false
            while (i < s.length) {
                val c = s[i]
                when {
                    esc -> esc = false
                    c == '\\' && inStr -> esc = true
                    c == '"' -> inStr = !inStr
                    inStr -> Unit
                    c == '{' || c == '[' -> depth++
                    c == '}' || c == ']' -> {
                        if (depth == 0) break  // 顶层结束（对应最外层 }）
                        depth--
                    }
                    c == ',' && depth == 0 -> break
                }
                i++
            }
            val valueText = s.substring(valStart, i).trim()
            if (valueText.isEmpty()) return null
            // ⚠️ 这里存**原始 JSON 形态**（字符串含引号）——
            //    类型校验 [checkType] 必须看到引号才能判出 `string`。
            //    去引号在**校验通过后**做（见 [validate] 的结尾），
            //    两件事混在一起就是 2026-10-21 那个"校验通过、执行全失败"的 bug。
            out[key] = valueText
        }
        return out
    }

    /**
     * 字符串值去引号 + 解转义；非字符串原样返回。
     *
     * ⚠️ 只该在**把值交给工具执行**时用。类型校验必须看原始形态（含引号），
     * 两件事不能混 —— 混了就是 2026-10-21 那个"校验通过、执行全失败"的 bug。
     */
    private fun unquoteIfString(raw: String): String {
        if (raw.length < 2) return raw
        if (!raw.startsWith("\"") || !raw.endsWith("\"")) return raw
        return unescape(raw.substring(1, raw.length - 1))
    }

    /** 找到双引号字符串的结束引号（跳过转义）。返回索引，-1 = 未闭合。 */
    private fun findStringEnd(s: String, startQuote: Int): Int {        var i = startQuote + 1
        var esc = false
        while (i < s.length) {
            val c = s[i]
            when {
                esc -> esc = false
                c == '\\' -> esc = true
                c == '"' -> return i
            }
            i++
        }
        return -1
    }

    private fun unescape(s: String): String {
        if ('\\' !in s) return s
        val sb = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '\\' && i + 1 < s.length) {
                when (val n = s[i + 1]) {
                    '"' -> { sb.append('"'); i += 2 }
                    '\\' -> { sb.append('\\'); i += 2 }
                    '/' -> { sb.append('/'); i += 2 }
                    'n' -> { sb.append('\n'); i += 2 }
                    'r' -> { sb.append('\r'); i += 2 }
                    't' -> { sb.append('\t'); i += 2 }
                    'b' -> { sb.append('\b'); i += 2 }
                    'f' -> { sb.append('\u000C'); i += 2 }
                    'u' -> {
                        if (i + 5 < s.length) {
                            val hex = s.substring(i + 2, i + 6)
                            val code = hex.toIntOrNull(16)
                            if (code != null) { sb.append(code.toChar()); i += 6 } else { sb.append(c); i++ }
                        } else { sb.append(c); i++ }
                    }
                    else -> { sb.append(n); i += 2 }
                }
            } else {
                sb.append(c); i++
            }
        }
        return sb.toString()
    }
}

/** 校验用的 Schema 视图（从 `ToolSpec.jsonSchema` 解析出来，或直接构造）。 */
data class ToolSchema(val params: List<SchemaParam>) {
    fun requiredParams(): List<String> = params.filter { it.required }.map { it.name }

    companion object {
        /**
         * 从预渲染的 JSON Schema 字符串**取回**校验所需的信息。
         *
         * ## ★★ 2026-10-21 真机事故：这里原来是**手写字符串扫描**，全错
         *
         * 真机现象：`read_file` 连续 20 轮被拒「参数不符合 Schema」，
         * 模型永远改不对。根因是本函数把参数名切错了 ——
         * 它靠 `json.indexOf(",\"")` 找下一个属性，而 `"description"` 里
         * 也含 `,"`，于是解析出 `params = [SchemaParam("limit"), SchemaParam(":")]`
         * 这种垃圾 ⇒ 所有真实参数都被判"未知参数"。**所有工具全废**。
         *
         * 教训：**手写 JSON 扫描器是 bug 工厂**。既然 `:agent` 已经有 Gson，
         * 而且这份字符串是**我们自己**的 `renderObjectSchema` 产出的（形状可信），
         * 就该用正规解析器。
         *
         * ⇒ 改为 Gson 解析。解析失败 ⇒ `null`（调用方按"无 schema"处理，**不猜**）。
         */
        fun fromRendered(json: String): ToolSchema? {
            val root = runCatching {
                com.google.gson.JsonParser.parseString(json)
            }.getOrNull() ?: return null
            if (!root.isJsonObject) return null
            val obj = root.asJsonObject
            val props = obj.getAsJsonObject("properties") ?: return null
            val requiredSet = obj.getAsJsonArray("required")
                ?.mapNotNull { runCatching { it.asString }.getOrNull() }
                ?.toSet()
                .orEmpty()

            val params = mutableListOf<SchemaParam>()
            props.entrySet().forEach { (name, el) ->
                if (!el.isJsonObject) return@forEach
                val p = el.asJsonObject
                val type = runCatching { p.get("type")?.asString }.getOrNull() ?: return@forEach
                val enumValues = p.getAsJsonArray("enum")
                    ?.mapNotNull { runCatching { it.asString }.getOrNull() }
                    .orEmpty()
                params += SchemaParam(
                    name = name,
                    type = type,
                    required = name in requiredSet,
                    enum = enumValues,
                )
            }
            return if (params.isEmpty()) null else ToolSchema(params)
        }
    }
}

/** 校验用的单个参数视图。 */
data class SchemaParam(
    val name: String,
    val type: String,
    val required: Boolean,
    val enum: List<String> = emptyList(),
)
