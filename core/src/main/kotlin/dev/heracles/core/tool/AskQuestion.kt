package dev.heracles.core.tool

/**
 * **`ask_user` 的一次提问**（2026-10-21 重做）。
 *
 * ## 为什么要重构
 *
 * 用户原话：
 * > 「ask 要是选项点击的，不是要我直接在下面输入，一般是 1、2、3、4 等等几个选项，
 * >   可以多选，单选，是 LLM 根据任务决定，可以一次发多个 ask，回答完自动下一个问题，
 * >   下面可以点击上一题和下一题。」
 *
 * 旧实现只有一个 `question: string` ⇒ 用户只能在输入框里手打，
 * 既慢又容易打错，而且**一次只能问一个**。成熟产品（Claude Code 的 plan 确认、
 * Cursor 的选项式澄清）都是**给选项让用户点**。
 *
 * ## 形状（模型给的 JSON）
 *
 * ```json
 * {"questions":[
 *   {"id":"q1","question":"要覆盖还是另存？","options":[
 *      {"label":"覆盖","description":"旧文件会被替换"},
 *      {"label":"另存","description":"保留旧文件"}],
 *    "multi":false},
 *   {"id":"q2","question":"需要哪些功能？","options":[...],"multi":true}
 * ]}
 * ```
 *
 * ## 三条设计约束（硬要求）
 *
 * 1. **`id` 由模型给**，回答按 id 回填 —— 否则多个问题会错位
 * 2. **`multi` 由模型决定**（单选 / 多选），不是 UI 猜
 * 3. **选项 `label` 必须唯一**（同一题内）—— 用户点的是 label，
 *    回答也用 label 回传，重名会让模型分不清点了哪个
 *
 * ## 为什么这里没有 JSON 解析
 *
 * `:core` 是**纯 JVM 契约层**，门禁 G1/G2 禁止 `import android.*`；
 * 而 `org.json` 在 Android 上是平台内置类、在纯 JVM 上要靠额外依赖
 * ⇒ 放在这里会把"解析实现"塞进契约层。
 * **解析归工具层**（`:agent` 有 JSON 能力），本文件只放**纯数据 + 校验**。
 */
data class AskQuestion(
    /** 题目标识（模型给，回答按它回填）。 */
    val id: String,
    /** 题干。 */
    val question: String,
    /** 选项（**至少 1 个**）。 */
    val options: List<AskOption>,
    /** 是否允许多选（模型决定）。 */
    val multi: Boolean = false,
) {
    /** 结构校验：返回错误原因，`null` = 合法。 */
    fun validate(): String? {
        if (id.isBlank()) return "question id 为空"
        if (question.isBlank()) return "题目「$id」的 question 为空"
        if (options.isEmpty()) return "题目「$id」没有 options（必须至少给 1 个选项）"
        if (options.any { it.label.isBlank() }) return "题目「$id」有空白选项"
        val dup = options.map { it.label }
            .groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        if (dup.isNotEmpty()) return "题目「$id」的选项重名：${dup.joinToString("、")}"
        return null
    }
}

/** 一个可点击的选项。 */
data class AskOption(
    /** 用户看到的文字（回答也用它回传）。 */
    val label: String,
    /** 补充说明（可为空）：帮用户理解后果。 */
    val description: String = "",
)

/**
 * **用户对一组提问的回答**（2026-10-21）。
 *
 * @param answers 题目 id → 选中的 label 列表（**多选就是多条**）；
 *   某题没答 ⇒ 不在 map 里（模型据此知道"这题被跳过"）
 */
data class AskAnswers(val answers: Map<String, List<String>>) {
    /**
     * 渲染成给模型看的**人话**（工具结果里用它）。
     *
     * 为什么不让模型自己去解析 JSON：工具结果越像"用户说的话"，
     * 模型越不容易把它当成新指令。这里刻意写成"问题 → 回答"的问答体。
     */
    fun render(questions: List<AskQuestion>): String {
        if (answers.isEmpty()) return "（用户未回答任何问题）"
        val sb = StringBuilder()
        for (q in questions) {
            val picked = answers[q.id]
            val text = if (picked.isNullOrEmpty()) "（未回答）" else picked.joinToString("、")
            sb.append("问：").append(q.question).append('\n')
            sb.append("答：").append(text).append('\n')
        }
        return sb.toString().trimEnd()
    }
}
