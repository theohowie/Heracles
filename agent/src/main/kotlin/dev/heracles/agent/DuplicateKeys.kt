package dev.heracles.agent

import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import dev.heracles.core.contract.Contract
import java.io.StringReader

/**
 * **重复 JSON 键检测**（F9c / P2-2 第四段，2026-10-18）。
 *
 * ## 为什么必须自己扫
 *
 * `gson` 对 `{"id":"a","id":"b"}` 是 **last-wins**：不报错，`id` 只剩 `"b"`。
 * 离线实测（harness，**gson 2.11.0**）：
 *
 * | 试法 | 结果 |
 * |---|---|
 * | `JsonParser.parseString("{\"id\":\"a\",\"id\":\"b\"}")` | `size=1, id="b"` —— 不报错 |
 * | `GsonBuilder().setStrictness(STRICT).fromJson(...)` | 仍 `{"id":"b"}`、`size=1` —— 最严模式也不拒 |
 * | `JsonReader` 手工走 token | `names=[id, id]` —— **重复键在 token 层可见** |
 *
 * 这与 `BuildProfileLoader` 的第三条纪律（**未知字段拒绝**）是同一件事的两面：
 * **配置写错了必须明确失败**，否则就成了"看起来生效了"。
 *
 * ## 为什么用 gson 的 `JsonReader` 走 token，而不是自己写字符状态机
 *
 * 转义（`\"`、`\uXXXX`、代理对）、字符串边界、数字格式**全部交给 gson** ——
 * 自造 JSON 解析器恰恰是"防静默错误"代码最容易出边界 bug 的地方。
 * 我们只做 gson **不做**的三件事：**对象帧查重** / **报错路径** / **深度上限**。
 * 附带好处：`nextName()` 返回**已解码**的键名 ⇒ `"\u0061"` 与 `"a"` 被判为同键。
 *
 * ## 三条口径（都有测试钉住）
 *
 * 1. **值不参与判定**：`{"k":1,"k":1}` 也拒绝 —— "值一样所以无所谓"这个辩解一旦成立，
 *    就会掩盖"本想写两个不同对象"的错误。
 * 2. **数组元素各自独立作用域**：`[{"k":1},{"k":2}]` **不**算重复；`[{"k":1,"k":2}]` 算。
 * 3. **扫不动 ⇒ [Scan.Unusable]（明确失败）**，**不许**静默当作"没重复"。
 *    这条也覆盖两个边角：**空/纯空白输入**（`peek()` 直接抛 EOF ⇒ Unusable，而不是
 *    "没发现重复"）与 **lenient 扩展语法**（单引号键等：`JsonReader` 默认严格 ⇒ 抛 ⇒ Unusable）。
 *    [Scan.Clean] 的含义严格限定为"**我走完了一个完整的值，里面没有重复键**"。
 *
 *    ⚠️ **注意：这是「行为收窄」，不是「增强」。** lenient 扩展语法（单引号键、无引号键）
 *    **以前** gson 的 lenient parser 是接受的 ⇒ 那份配置**能**被加载；**现在**会被
 *    "无法检查重复键"明确拒绝。取舍理由：要兼容就得让扫描器也 lenient，等于把
 *    转义/字符串边界重新拿回自己手里 —— 正是路线 B 要避免的事；而 profile 的格式
 *    是**我们自己定义的**，没有理由用单引号键。（已按此口径报备 lead 并获批保留。）
 *
 * ⚠️ **未验**：仓库 pin 的 gson 是 **2.9.1**，上表的实测是在 **2.11.0** 上做的
 * （2.9.1 无 `Strictness` API，且离线缓存里没有该版本）⇒ **不许**把"2.11 验过"写成"2.9.1 已验证"。
 * 本实现**不依赖** gson 的版本行为：只用 `JsonReader` 最基础的 token 接口
 * （`peek`/`nextName`/`beginObject`/`beginArray`/`skipValue`/`endObject`/`endArray`/`hasNext`）。
 */
internal object DuplicateKeys {

    /** 路径根名（只为可读性；JSON 本身没有名字）。 */
    private const val ROOT = "root"

    /**
     * 一处重复键。
     *
     * @param key 键名（**已解码**：`"\u0061"` 报 `a`）
     * @param path 该键的**完整路径**（含键名本身），如 `root.steps[0].id`
     * @param count 出现次数（≥ 2）
     */
    internal data class Duplicate(val key: String, val path: String, val count: Int)

    /**
     * 扫描结果 —— **三态**，调用方必须区别对待后两者：
     * 把 [Unusable] 当成 [Clean] 就是静默放过。
     */
    internal sealed interface Scan {
        /** 没有重复键。 */
        data object Clean : Scan

        /** 有重复键（按**首次出现顺序**）。 */
        data class Found(val duplicates: List<Duplicate>) : Scan

        /** 扫不动（超深 / 遍历异常）。调用方**必须明确失败**。 */
        data class Unusable(val reason: String) : Scan
    }

    /** 失败文案里那段重复键——与 `rejectUnknown` 的"一次列全"同体例，不设条数上限。 */
    internal fun describe(duplicates: List<Duplicate>): String =
        "有重复键 " + duplicates.joinToString("、") {
            // 键名与路径都转义：带换行/引号的键名否则会把失败文案撕成好几行、还读不懂
            "\"${display(it.key)}\"（出现 ${it.count} 次，位置 ${display(it.path)}）"
        }

    /**
     * 扫一遍 token 流，返回全部重复键。
     *
     * **不递归**（显式帧栈）⇒ 无论多深都不会栈溢出；深度靠 [Contract.Json.MAX_DEPTH] 判。
     */
    internal fun scan(json: String): Scan {
        val reader = JsonReader(StringReader(json))
        val stack = ArrayList<Frame>()
        val found = LinkedHashMap<String, Duplicate>()
        try {
            when (reader.peek()) {
                JsonToken.BEGIN_OBJECT -> {
                    reader.beginObject()
                    stack.add(Frame.Obj(ROOT, HashSet()))
                }
                JsonToken.BEGIN_ARRAY -> {
                    reader.beginArray()
                    stack.add(Frame.Arr(ROOT, 0))
                }
                // 空输入 / 顶层是标量 ⇒ 根本没有键（顶层必须是对象的纪律在调用方，不在这里）
                else -> return Scan.Clean
            }

            while (stack.isNotEmpty()) {
                val top = stack.last()
                if (!reader.hasNext()) {
                    if (top is Frame.Obj) reader.endObject() else reader.endArray()
                    stack.removeAt(stack.lastIndex)
                    continue
                }
                when (top) {
                    is Frame.Obj -> {
                        val name = reader.nextName()
                        val path = "${top.path}.$name"
                        if (!top.keys.add(name)) {
                            found[path] = Duplicate(name, path, (found[path]?.count ?: 1) + 1)
                        }
                        descend(reader, path, stack)?.let { return it }
                    }
                    is Frame.Arr -> {
                        val path = "${top.path}[${top.index}]"
                        top.index++
                        descend(reader, path, stack)?.let { return it }
                    }
                }
            }
            return if (found.isEmpty()) Scan.Clean else Scan.Found(found.values.toList())
        } catch (e: Exception) {
            // 纪律：扫不动**不许**静默当作"没重复"
            return Scan.Unusable("遍历失败：${e.message}")
        } finally {
            runCatching { reader.close() }
        }
    }

    // ---------------------------------------------------------------- 内部

    private sealed interface Frame {
        val path: String

        /** 一个对象：**键集合按对象独立**（这就是"数组元素各自作用域"的实现）。 */
        class Obj(override val path: String, val keys: MutableSet<String>) : Frame

        /** 一个数组：只为了给元素编号，好让路径能写成 `xs[0]`。 */
        class Arr(override val path: String, var index: Int) : Frame
    }

    /** 进入一个**值**：容器 ⇒ 压帧（超深 ⇒ [Scan.Unusable]）；标量/null ⇒ 跳过。 */
    private fun descend(reader: JsonReader, path: String, stack: ArrayList<Frame>): Scan? =
        when (reader.peek()) {
            JsonToken.BEGIN_OBJECT -> {
                if (stack.size >= Contract.Json.MAX_DEPTH) {
                    Scan.Unusable("嵌套超过 ${Contract.Json.MAX_DEPTH} 层")
                } else {
                    reader.beginObject()
                    stack.add(Frame.Obj(path, HashSet()))
                    null
                }
            }
            JsonToken.BEGIN_ARRAY -> {
                if (stack.size >= Contract.Json.MAX_DEPTH) {
                    Scan.Unusable("嵌套超过 ${Contract.Json.MAX_DEPTH} 层")
                } else {
                    reader.beginArray()
                    stack.add(Frame.Arr(path, 0))
                    null
                }
            }
            else -> {
                reader.skipValue()
                null
            }
        }

    /** 键名进文案前先**转义**：键里带换行/引号时，失败文案必须还是一行、还能读。 */
    private fun display(key: String): String = buildString {
        for (c in key) {
            when (c) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> append(c)
            }
        }
    }
}
