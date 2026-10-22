package dev.heracles.core.tool

/**
 * **类型化工具参数** —— 云端原生 Function Calling 的 Schema 内核（`CloudAgentPipeline`，2026-10-21）。
 *
 * ## 它解决什么（旧 [ToolParam] 的根本缺陷）
 *
 * 旧的 [ToolParam.type] 只有 `String` 一个"类型"字段，而且**全仓 55 个参数全部填 `"string"`**：
 *
 * ```
 * ToolParam("max_results", "string", "最多返回多少条")   // 语义是 integer
 * ToolParam("replace_all", "string", "true = 全部替换")   // 语义是 boolean
 * ToolParam("steps", "string", "JSON 数组…")              // 语义是 array of objects
 * ```
 *
 * 成因写在 [ToolSpec] 的类注释里：「只允许扁平标量 —— 嵌套对象是小模型填错的头号来源」。
 * 那是 **GBNF 语法层无法表达类型** 的妥协，不是设计意图。
 *
 * ## 为什么本文件**手工序列化**而不是用 JSON 库
 *
 * `:core` 是纯 JVM 契约层，唯一依赖是 `kotlinx-coroutines`（见 `core/build.gradle.kts`），
 * **没有 Gson**。而且 Schema 会进请求体、影响前缀缓存 —— 必须**逐字节确定**
 * （键序固定、不依赖任何库的迭代序）。这与 [PrefixBuilder.canonicalToolJson] 的理由完全相同。
 *
 * ## 与旧路径的关系
 *
 * [cloudToolSpec] 产出的是**普通 [ToolSpec]**，只是多填了 [ToolSpec.jsonSchema]。
 * `jsonSchema == null` 时全仓行为与改动前**逐字节相同**（旧路径不受任何影响）。
 */
data class CloudParam(
    val name: String,
    val type: ParamType,
    val description: String,
    /**
     * 缺键是否允许（对应 JSON Schema 的 `required` 数组）。
     *
     * 默认 `true` = 必填。声明成可选时，**默认值必须写进 [description]** ——
     * 否则模型不知道该填什么。
     */
    val required: Boolean = true,
    /** 枚举取值（非空时渲染成 JSON Schema 的 `enum`）。 */
    val enum: List<String> = emptyList(),
)

/**
 * 参数类型 —— **只做 JSON Schema 能表达的那几种**，不做过度设计。
 *
 * ⚠️ 成员刻意不用 `String` / `Integer` 这些名字：它们会与 Kotlin 内置类型冲突，
 * 导致 `ParamType = String` 这种默认值写成内置类型的编译错误。
 *
 * `Array` / `Object` 刻意不带无限递归的 item schema：
 * - 目前真实需求只有两种（`array of objects`：`steps` / `questions`；`array of strings`）
 * - 递归 schema 会让本文件复杂度翻倍，而没有任何工具需要它
 * - 需要时再扩展 —— 但扩展前先问"这个形状真的必须嵌套吗"
 */
sealed interface ParamType {
    /** JSON Schema 的 `"type"` 字面量。 */
    val wire: String

    /** 字符串。 */
    data object Text : ParamType {
        override val wire: String get() = "string"
    }

    /** 整数。 */
    data object Int : ParamType {
        override val wire: String get() = "integer"
    }

    /** 浮点数。 */
    data object Num : ParamType {
        override val wire: String get() = "number"
    }

    /** 布尔。 */
    data object Bool : ParamType {
        override val wire: String get() = "boolean"
    }

    /**
     * 数组。
     *
     * @param items 元素类型；`Object` 时带属性表
     */
    data class Array(
        val items: ParamType = Text,
    ) : ParamType {
        override val wire: String get() = "array"
    }

    /**
     * 对象。
     *
     * @param props 属性表（空 = `{"type":"object"}` 自由形状）
     */
    data class Object(val props: List<CloudParam> = emptyList()) : ParamType {
        override val wire: String get() = "object"
    }
}

/**
 * 一次性把一批 [CloudParam] 渲染成一个**完整**的 JSON Schema 字符串
 * （`{"type":"object","properties":{…},"required":[…]}`）。
 *
 * 键序固定为 `type` → `properties` → `required`（与 `02-契约规范.md` §4.3 一致），
 * 参数按**名字典序**排列 ⇒ 同一份声明任意次渲染逐字节相同（前缀缓存的前提）。
 *
 * `required` 恒存在（全部可选时是空数组）—— JSON Schema 里合法，
 * 且比"条件性省略整个键"更稳：**形状不随内容变**。
 */
fun renderObjectSchema(params: List<CloudParam>): String {
    val sorted = params.sortedBy { it.name }
    return buildString {
        append("{\"type\":\"object\",\"properties\":{")
        sorted.forEachIndexed { i, p ->
            if (i > 0) append(',')
            append('"').append(escapeJson(p.name)).append("\":")
            append(renderParamSchema(p))
        }
        append("},\"required\":[")
        sorted.filter { it.required }.forEachIndexed { i, p ->
            if (i > 0) append(',')
            append('"').append(escapeJson(p.name)).append('"')
        }
        append("]}")
    }
}

/** 单个参数的 Schema（不含 `required` —— 那在父级）。 */
private fun renderParamSchema(p: CloudParam): String = buildString {
    append("{\"type\":\"").append(p.type.wire).append("\"")
    when (val t = p.type) {
        is ParamType.Array -> {
            append(",\"items\":")
            when (val items = t.items) {
                is ParamType.Object -> {
                    if (items.props.isEmpty()) {
                        append("{\"type\":\"object\"}")
                    } else {
                        append(renderObjectSchema(items.props))
                    }
                }
                else -> append("{\"type\":\"").append(items.wire).append("\"}")
            }
        }
        is ParamType.Object -> {
            if (t.props.isNotEmpty()) {
                append(",\"properties\":")
                append(renderObjectSchema(t.props))
            }
        }
        else -> Unit
    }
    if (p.enum.isNotEmpty()) {
        append(",\"enum\":[")
        p.enum.forEachIndexed { i, v ->
            if (i > 0) append(',')
            append('"').append(escapeJson(v)).append('"')
        }
        append(']')
    }
    append(",\"description\":\"").append(escapeJson(p.description)).append("\"}")
}

/**
 * 把类型化声明转成旧的 [ToolSpec]（**唯一**的桥接点）。
 *
 * 这样云端管线可以继续用 `:core` 已有的 [ToolSpec] 类型（`AgentTool.spec` 不用改），
 * 而 Provider 侧只需要"有 `jsonSchema` 就用它，没有就退回旧渲染"。
 */
fun cloudToolSpec(name: String, description: String, params: List<CloudParam>): ToolSpec =
    ToolSpec(
        name = name,
        description = description,
        parameters = params.map { p ->
            // 旧字段仍然填（文本轨/旧路径照旧可用）；云端走 jsonSchema，不看这里
            ToolParam(
                name = p.name,
                type = if (p.type is ParamType.Array || p.type is ParamType.Object) "string" else p.type.wire,
                description = p.description,
                optional = !p.required,
            )
        },
        jsonSchema = renderObjectSchema(params),
    )

/**
 * 最小化 JSON 字符串转义 —— **必须稳定**，不得依赖平台默认编码。
 *
 * 与 [PrefixBuilder] 的 private `escape` 同语义：这里复制一份是因为那个是 private，
 * 而把它提成 public 会让冻结区构造链暴露内部实现细节。
 */
fun escapeJson(s: String): String = buildString(s.length + 8) {
    for (ch in s) {
        when (ch) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (ch.code < 0x20) {
                append("\\u").append(String.format("%04x", ch.code))
            } else {
                append(ch)
            }
        }
    }
}
