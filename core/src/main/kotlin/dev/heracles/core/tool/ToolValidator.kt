package dev.heracles.core.tool

/**
 * 工具调用的语义校验 —— `02-契约规范.md` §8（L2 白名单校验）。
 *
 * ## 与 GBNF 的分工
 *
 * | 层 | 负责 | 失败含义 |
 * |---|---|---|
 * | GBNF 语法 | 输出的**形状**（字段名、类型、工具名在集合内） | 服务端配置问题 |
 * | 本对象 | 输出的**语义**（必填参数齐全、值合理） | 模型判断问题 |
 *
 * 语法层已经保证了"工具名一定合法"，所以这里**不再重复检查工具名是否在集合内** ——
 * 那是防御性编程的浪费。但**必须**检查参数，因为 GBNF 无法表达"这个参数必填"。
 */
object ToolValidator {

    sealed interface Result {
        data object Valid : Result
        data class Invalid(val detail: String) : Result
    }

    /**
     * 校验。
     *
     * @param call 语法层已解析出的调用
     * @param tools 本次会话可用的工具集合
     */
    fun validate(call: ToolCall, tools: List<ToolSpec>): Result {
        val spec = tools.firstOrNull { it.name == call.tool }
            ?: return Result.Invalid(
                "工具 ${call.tool} 不在可用集合中（语法层本应拦住，说明 GBNF 未生效）"
            )

        // 必填参数齐全
        //
        // ★ 2026-10-18（F7a）：`optional = true` 的参数**允许缺键** —— 缺了由实现走默认值。
        //   在此之前"声明出来 = 必填键"，模型少写一个键就撞「缺少必填参数」，
        //   而云端原生 function calling 的 JSON Schema 本来就用 `required` 表达必填。
        //   ⚠️ 缺键与空串是**两件事**：空串仍由下面 allowEmpty 的规则单独判（不许合并）。
        val missing = spec.parameters
            .filter { !it.optional && it.name !in call.args }
            .map { it.name }
        if (missing.isNotEmpty()) {
            return Result.Invalid("缺少必填参数：${missing.joinToString()}")
        }

        // 无未知参数 —— 小模型常见错误是臆造参数名
        val known = spec.parameters.map { it.name }.toSet()
        val unknown = call.args.keys - known
        if (unknown.isNotEmpty()) {
            return Result.Invalid("出现未知参数：${unknown.joinToString()}")
        }

        // 参数值合理性
        for (p in spec.parameters) {
            val v = call.args[p.name] ?: continue
            // ★ 空值：**必须尊重参数自己的契约**（2026-10-14 真机 bug）
            //
            // 用户实测：`list_files` 的 `dir` 文档写着"根目录传空字符串"，
            // 而这里一刀切判"为空非法" → 合法调用被拦 → 模型重试仍撞
            // "重复调用拦截" → **放弃并谎称任务完成**（文件根本没写）。
            //
            // 校验器与工具契约矛盾时以**契约为准**：声明了
            // [ToolParam.allowEmpty] 的参数放行空串（长度/控制字符
            // 检查照跑）。
            if (v.isBlank() && !p.allowEmpty) {
                return Result.Invalid("参数 ${p.name} 为空")
            }

            // 长度上限**按参数名区分**（2026-10-09 实修）。
            // 见 [limitFor] —— 文件内容天然很长，路径天然很短。
            val limit = limitFor(p.name)
            if (v.length > limit) {
                return Result.Invalid("参数 ${p.name} 超长（${v.length} > $limit）")
            }

            // 控制字符检查 —— **必须排除换行与制表符**。
            //
            // 首版把 \n 也当成非法，导致 **Markdown 文件完全写不出来**：
            // README 必然含换行，于是每次都被拦，模型反复重试直到死循环。
            // 这是"校验器本身成为故障源"的典型。
            //
            // 合法的空白字符：\t(0x09) \n(0x0A) \r(0x0D)
            // 真正危险的是 NUL / ESC / 退格等 —— 它们通常意味着解析出错或注入。
            val bad = v.firstOrNull { ch ->
                ch.code < 0x20 && ch != '\n' && ch != '\r' && ch != '\t'
            }
            if (bad != null) {
                return Result.Invalid(
                    "参数 ${p.name} 含非法控制字符 U+%04X".format(bad.code)
                )
            }
        }
        return Result.Valid
    }

    /**
     * 每个参数的长度上限。
     *
     * `content` 类参数天然很长（一个源文件几千字符），
     * `path` 类天然很短。用同一个上限会导致**要么放行危险输入，要么拦死合法输入**。
     *
     * ⚠️ 2026-10-16 新增 `patch` / `command`（阶段二工具链）：
     * `apply_patch` 的 diff 天然超过 500 字符，`run_shell_command` 的
     * 复合命令行也会超 —— 若不在这里放行，这两个工具会**每次都失败**，
     * 而症状是"模型反复重试直到谎称完成"（同 2026-10-14 的 `list_files.dir`）。
     */
    private fun limitFor(paramName: String): Int = when (paramName) {
        "content", "text", "body", "code" -> MAX_CONTENT_LENGTH
        // 补丁正文与源码正文同量级
        "patch", "diff" -> MAX_CONTENT_LENGTH
        "command" -> MAX_COMMAND_LENGTH
        else -> MAX_ARG_VALUE_LENGTH
    }

    /**
     * 普通参数值长度上限。
     *
     * 500 是个经验值：联系人名、搜索关键词、应用名都远短于它；
     * 而模型失控时最容易的表现就是无限续写同一个参数。
     */
    const val MAX_ARG_VALUE_LENGTH = 500

    /**
     * `run_shell_command` 的命令行长度上限。
     *
     * 4000 的依据：本阶段最长的合法命令是
     * `java -Xmx512m -cp <长路径>/d8.jar com.android.tools.r8.D8 --lib … --output … <一长串 .class>`
     * —— 实测这类命令普遍在 300–1200 字符。4000 给出 3 倍余量，
     * 同时仍能拦住"模型失控式续写整份脚本"。
     */
    const val MAX_COMMAND_LENGTH = 4_000

    /**
     * 内容类参数（文件正文、消息正文）的长度上限。
     *
     * 100 KB —— 足够放下任何正常源文件，同时仍能拦住模型失控式续写。
     * **必须与 [limitFor] 配合**，否则"写文件"这个核心能力会被校验器自己掐死。
     */
    const val MAX_CONTENT_LENGTH = 100_000
}
