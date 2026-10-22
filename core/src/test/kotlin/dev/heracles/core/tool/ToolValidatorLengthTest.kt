package dev.heracles.core.tool

import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **参数长度门禁的回归测试**（2026-10-21，BUG-2）。
 *
 * ## 背景：500 字符是本地 4B 时代的断头台
 *
 * `ToolValidator` 原先按参数名白名单给长度上限：`content`/`patch` 放 100 KB，
 * **其余一律 500**。那份名单漏掉了后来新增的长参数 —— 尤其是 `edit` 的
 * `new_string` / `old_string`，以及 `update_plan` 的 `steps`。
 *
 * 真机症状（用户报告「补丁太长被截断 → 输出无法解析」）：
 *
 * ```
 * 模型给 edit.new_string 一个 >500 字符的补丁
 *   → ToolValidator 判「参数 new_string 超长（800 > 500）」
 *   → 调用被拦、什么都没执行
 *   → 模型重试（补丁还是那么长）→ 又拦
 *   → 连续 2 轮「输出无法解析」→ CONSECUTIVE_UNPARSEABLE 熔断
 * ```
 *
 * **不是模型的问题，是校验器自己把长补丁掐死了。**
 *
 * ## 修法与这组断言
 *
 * [ToolValidator] 的 `limitFor` 删除按名字的白名单，默认分支改为
 * `MAX_CONTENT_LENGTH`（100 KB）；只保留 `command` 的 4000（命令行有物理上限）。
 *
 * 所以这里钉三件事：
 * 1. 5000 字符的 `edit.new_string` **必须放行**（旧实现在这里挂）
 * 2. 513 字符的 `update_plan.steps` **必须放行**（旧实现在这里挂）
 * 3. 超 100 KB **仍必须拦住**（放宽不等于不设防）
 */
class ToolValidatorLengthTest {

    private val editSpec = ToolSpec(
        name = "edit",
        description = "局部替换",
        parameters = listOf(
            ToolParam("path", "string", "路径"),
            ToolParam("old_string", "string", "被替换的原文"),
            ToolParam("new_string", "string", "替换后的新内容"),
        ),
    )

    private val updatePlanSpec = ToolSpec(
        name = "update_plan",
        description = "更新计划",
        parameters = listOf(
            ToolParam("steps", "string", "JSON 数组"),
        ),
    )

    private val shellSpec = ToolSpec(
        name = "run_shell_command",
        description = "执行命令",
        parameters = listOf(
            ToolParam("command", "string", "命令行"),
        ),
    )

    private val specs = listOf(editSpec, updatePlanSpec, shellSpec)

    private fun invalidDetail(call: ToolCall): String? =
        when (val r = ToolValidator.validate(call, specs)) {
            is ToolValidator.Result.Valid -> null
            is ToolValidator.Result.Invalid -> r.detail
        }

    // ============================================================
    // ★★ 旧实现在这三条上会挂（真机 BUG-2 的回归门禁）
    // ============================================================

    @Test
    @DisplayName("★★ 5000 字符的 edit.new_string 必须放行（旧实现：超长 800 > 500 被拦 → 熔断）")
    fun longNewStringIsAccepted() {
        val patch = buildString {
            append("fun main() {\n")
            repeat(300) { append("    println(\"line $it that is reasonably long\")\n") }
            append("}\n")
        }
        assertTrue(patch.length > 5_000, "测试数据本身得足够长（实际 ${patch.length}）")

        val detail = invalidDetail(
            ToolCall("edit", mapOf("path" to "a.kt", "old_string" to "fun main() {}", "new_string" to patch)),
        )
        assertNull(
            detail,
            "长补丁是**正常**输入 —— 校验器拦它等于掐死 edit 工具，模型只能重试到熔断。" +
                "（实际被拦：$detail）",
        )
    }

    @Test
    @DisplayName("★★ 5000 字符的 edit.old_string 同样必须放行（它也是内容，不是路径）")
    fun longOldStringIsAccepted() {
        val old = "x".repeat(5_000)
        val detail = invalidDetail(
            ToolCall("edit", mapOf("path" to "a.txt", "old_string" to old, "new_string" to "y")),
        )
        assertNull(detail, "old_string 与 new_string 同量级（实际被拦：$detail）")
    }

    @Test
    @DisplayName("★★ 513 字符的 update_plan.steps 必须放行（旧实现：>500 就拦）")
    fun stepsOf513CharsAreAccepted() {
        val steps = """[{"text":"${"步".repeat(500)}","status":"pending"}]"""
        assertTrue(steps.length > 500, "测试数据得越过旧阈值（实际 ${steps.length}）")
        val detail = invalidDetail(ToolCall("update_plan", mapOf("steps" to steps)))
        assertNull(detail, "多步计划天然超过 500 字符（实际被拦：$detail）")
    }

    // ============================================================
    // ★ 放宽不等于不设防：100 KB 仍是硬边界
    // ============================================================

    @Test
    @DisplayName("★ 超 MAX_CONTENT_LENGTH（100KB）仍必须拦住 —— 防模型失控续写")
    fun overContentLimitStillRejected() {
        val huge = "x".repeat(ToolValidator.MAX_CONTENT_LENGTH + 1)
        val detail = invalidDetail(
            ToolCall("edit", mapOf("path" to "a.txt", "old_string" to "o", "new_string" to huge)),
        )
        assertTrue(
            detail?.contains("new_string") == true && detail.contains("超长"),
            "超过 100KB 必须拦（实际：$detail）",
        )
    }

    @Test
    @DisplayName("★ 恰好等于 MAX_CONTENT_LENGTH 放行（边界是 >，不是 >=）")
    fun exactlyAtContentLimitAccepted() {
        val max = "x".repeat(ToolValidator.MAX_CONTENT_LENGTH)
        assertNull(
            invalidDetail(
                ToolCall("edit", mapOf("path" to "a.txt", "old_string" to "o", "new_string" to max)),
            ),
        )
    }

    @Test
    @DisplayName("★ command 保留 4000 的物理上限（不受 content 放宽影响）")
    fun commandKeepsItsOwnLimit() {
        // 3999 放行
        assertNull(
            invalidDetail(ToolCall("run_shell_command", mapOf("command" to "a".repeat(3_999)))),
        )
        // 4001 拦住
        val detail = invalidDetail(
            ToolCall("run_shell_command", mapOf("command" to "a".repeat(4_001))),
        )
        assertTrue(
            detail?.contains("command") == true && detail.contains("超长"),
            "命令行长度上限不许被内容放宽带跑（实际：$detail）",
        )
    }

    @Test
    @DisplayName("★ 路径类短参数不再受 500 限制（统一门禁的副作用，可接受）")
    fun shortParamNamesAreNoLongerSpecialCased() {
        // 这**不是**推荐用法（路径本来就该短），只是钉住"门禁不再按名字猜"：
        // 没有哪条规则会因为参数叫 path 就额外收紧 —— 收紧只会误杀合法的长路径 / 长 JSON。
        val longPath = "a/".repeat(400) + "file.txt"
        assertTrue(longPath.length > 500)
        assertNull(
            invalidDetail(
                ToolCall("edit", mapOf("path" to longPath, "old_string" to "o", "new_string" to "n")),
            ),
        )
    }
}
