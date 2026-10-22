package dev.heracles.agent

import dev.heracles.core.tool.AskOption
import dev.heracles.core.tool.AskQuestion

/**
 * **`ask_user` 的 `questions` 参数解析**（2026-10-21）。
 *
 * ## 为什么单独一个文件
 *
 * 同一份解析要在**两个地方**用：
 * · `AskUserTool.execute` —— 校验参数、挂起等回答
 * · `AgentLoop` 发 `AskUser` 事件 —— 把题目结构带给 UI 渲染
 *
 * 抄两份就会漂移：UI 显示的题与工具实际等的题**不是同一批**，
 * 那是"用户答了 A 题、模型收到 B 题"这类最难查的错位。
 * ⇒ 单一真相，两处共用。
 *
 * ## 容错边界（只归一形状，**不猜语义**）
 *
 * 模型常见写法有三种，都认：
 * 1. 顶层直接数组：`[{…},{…}]`
 * 2. 包一层：`{"questions":[{…}]}`
 * 3. `options` 元素是裸字符串：`["覆盖","另存"]`（等价于 `{"label":"覆盖"}`）
 *
 * 形状不对 ⇒ 返回**空列表**（调用方据此报失败）。**绝不**用正则猜、
 * 也绝不把解析失败的字符串当题干塞给用户。
 */
object AskUserArgs {

    /** 解析成功且**全部题目通过校验**才返回非空；否则返回空列表。 */
    fun parse(raw: String): List<AskQuestion> {
        val list = parseLoose(raw)
        if (list.isEmpty()) return emptyList()
        // 校验（含 id 唯一）—— 任何一题不合法就整体判失败，
        // 因为"部分题目可用"会让 UI 与工具看到的题数不一致。
        for (q in list) {
            if (q.validate() != null) return emptyList()
        }
        val dupIds = list.map { it.id }
            .groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        if (dupIds.isNotEmpty()) return emptyList()
        return list
    }

    /** 校验失败时的**人话原因**（给工具结果用，比"格式错误"有用得多）。 */
    fun explain(raw: String): String {
        if (raw.isBlank()) return "questions 为空"
        val list = parseLoose(raw)
        if (list.isEmpty()) {
            return "questions 不是合法的 JSON 数组。正确形状：" +
                """[{"id":"q1","question":"…","multi":false,""" +
                """"options":[{"label":"A"},{"label":"B"}]}]"""
        }
        for (q in list) {
            q.validate()?.let { return it }
        }
        val dupIds = list.map { it.id }
            .groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        if (dupIds.isNotEmpty()) return "question id 重复：${dupIds.joinToString("、")}"
        return "未知格式问题"
    }

    private fun parseLoose(raw: String): List<AskQuestion> {
        val text = raw.trim()
        if (text.isEmpty()) return emptyList()
        return runCatching {
            // `:agent` 用 **Gson**（不是 org.json —— 后者是 Android 平台类，
            // 纯 JVM 模块里不可用；本模块的依赖清单只有 gson）。
            val root = com.google.gson.JsonParser.parseString(text)
            val arr = when {
                root.isJsonArray -> root.asJsonArray
                root.isJsonObject -> root.asJsonObject.getAsJsonArray("questions")
                    ?: return emptyList()
                else -> return emptyList()
            }
            val out = mutableListOf<AskQuestion>()
            for (i in 0 until arr.size()) {
                val e = arr.get(i)
                if (!e.isJsonObject) continue
                val o = e.asJsonObject
                val id = o.get("id")?.takeIf { it.isJsonPrimitive }?.asString
                    ?.takeIf { it.isNotBlank() } ?: "q${i + 1}"
                val q = o.get("question")?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
                val opts = o.getAsJsonArray("options") ?: continue
                val list = mutableListOf<AskOption>()
                for (j in 0 until opts.size()) {
                    when (val oe = opts.get(j)) {
                        // 对象形式：{"label":"覆盖","description":"…"}
                        is com.google.gson.JsonObject -> {
                            val label = oe.get("label")?.takeIf { it.isJsonPrimitive }
                                ?.asString.orEmpty()
                            if (label.isNotBlank()) {
                                val desc = oe.get("description")
                                    ?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()
                                list += AskOption(label, desc)
                            }
                        }
                        // 裸字符串形式："覆盖"
                        is com.google.gson.JsonPrimitive -> {
                            val s = oe.asString
                            if (s.isNotBlank()) list += AskOption(s)
                        }
                        else -> Unit
                    }
                }
                val multi = o.get("multi")?.takeIf { it.isJsonPrimitive }?.asBoolean ?: false
                out += AskQuestion(id = id, question = q, options = list, multi = multi)
            }
            out
        }.getOrDefault(emptyList())
    }
}
