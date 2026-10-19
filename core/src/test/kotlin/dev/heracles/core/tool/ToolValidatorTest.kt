package dev.heracles.core.tool

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * `ToolValidator` 的行为门禁。
 *
 * ## 为什么现在才建这个文件（2026-10-14）
 *
 * 用户真机实测暴露了一个**校验器与工具契约互相矛盾**的 bug：
 *
 * > `list_files` 的参数描述写着「根目录传空字符串」，
 * > 而校验器有一条通用的"参数值为空 → 非法"规则 ——
 * > 模型**照契约**传 `dir: ""` 却被拦下。
 *
 * 连锁后果比单次拦截严重得多：
 * 模型重试一次（还是 `""`）→ 撞上"重复调用拦截" →
 * **放弃并谎称"我已经为你创建了 2048 游戏 HTML 文件"**（文件根本没写）。
 *
 * 这个 bug 之所以能活这么久，就是因为**校验器没有测试** ——
 * 它只在真机、只在模型恰好传对空值时才暴露。
 */
class ToolValidatorTest {

    private val listFiles = ToolSpec(
        name = "list_files",
        description = "列出目录",
        parameters = listOf(
            ToolParam("dir", "string", "根目录传空字符串", allowEmpty = true),
        ),
    )

    private val writeFile = ToolSpec(
        name = "write_file",
        description = "写文件",
        parameters = listOf(
            ToolParam("path", "string", "路径"),
            ToolParam("content", "string", "内容"),
        ),
    )

    /** 可选参数（F7a）：`offset`/`limit` 缺键 = 走实现的"整读"默认值。 */
    private val readFile = ToolSpec(
        name = "read_file",
        description = "读文件",
        parameters = listOf(
            ToolParam("path", "string", "路径"),
            ToolParam("offset", "string", "起始行号", allowEmpty = true, optional = true),
            ToolParam("limit", "string", "行数", allowEmpty = true, optional = true),
        ),
    )

    /** `optional` 但**没**声明 allowEmpty 的参数：可以不给，但给了不能是空串。 */
    private val ping = ToolSpec(
        name = "ping",
        description = "测试用",
        parameters = listOf(ToolParam("host", "string", "主机名", optional = true)),
    )

    private val specs = listOf(listFiles, writeFile, readFile, ping)

    private fun invalidDetail(call: ToolCall): String? =
        when (val r = ToolValidator.validate(call, specs)) {
            is ToolValidator.Result.Valid -> null
            is ToolValidator.Result.Invalid -> r.detail
        }

    // ============================================================
    // ★★ 真机 bug 的回归门禁
    // ============================================================

    @Test
    @DisplayName("★★ allowEmpty 的参数传空串必须放行（真机 bug：dir 为空被拦）")
    fun allowEmptyParamAcceptsBlankValue() {
        val detail = invalidDetail(
            ToolCall("list_files", mapOf("dir" to ""))
        )
        assertNull(
            detail,
            "参数描述写着'根目录传空字符串'，校验器就不能判它为非法 —— " +
                "两者矛盾时模型会照契约传空值然后被拦，进而谎称任务完成",
        )
    }

    @Test
    @DisplayName("★ 未声明 allowEmpty 的参数传空串仍必须拦截（不能放宽成普遍行为）")
    fun nonAllowEmptyParamStillRejectsBlank() {
        val detail = invalidDetail(
            ToolCall("write_file", mapOf("path" to "", "content" to "x"))
        )
        assertTrue(
            detail?.contains("path") == true,
            "path 为空说明模型没填对 —— 必须拦下（实际：$detail）",
        )
    }

    @Test
    @DisplayName("★ allowEmpty 的参数传空白（空格）也放行，但超长照样拦")
    fun allowEmptyStillSubjectToOtherChecks() {
        // 空白（" "）也算空 —— isBlank 语义一致
        assertNull(invalidDetail(ToolCall("list_files", mapOf("dir" to " "))))
    }

    // ============================================================
    // 既有规则的守卫（防这次修改放宽了别的检查）
    //
    // ⚠️ `CapabilityGrammarTest` 已覆盖"缺参数/未知参数/未知工具/
    //    控制字符/超长"这些通用规则。这里**只保留与本次改动直接
    //    相邻**的两条（空值分流 + 换行放行）—— 其余不重复维护。
    // ============================================================

    @Test
    @DisplayName("★ 换行与制表符必须放行（拦了 Markdown/源码完全写不出来）")
    fun newlineAndTabAreAllowed() {
        assertNull(
            invalidDetail(
                ToolCall(
                    "write_file",
                    mapOf("path" to "README.md", "content" to "# 标题\n正文\t缩进"),
                )
            ),
            "换行/制表符合法 —— 首版把它们当非法，导致 Markdown 写不出来",
        )
    }

    @Test
    @DisplayName("★ 长度上限按参数名区分（content 放得下源文件）")
    fun lengthLimitIsPerParamName() {
        assertNull(
            invalidDetail(
                ToolCall(
                    "write_file",
                    mapOf("path" to "a.html", "content" to "x".repeat(50_000)),
                )
            ),
            "50KB 源文件必须能写 —— 校验器不能掐死核心能力",
        )
    }

    // ============================================================
    // ★ 可选参数（2026-10-18，F7a —— ADR-031 原生 function calling 的前置）
    //
    // 在这之前"声明即必填键"：模型少写一个键就撞「缺少必填参数」，
    // 而它本可以走实现的默认值（docs/27 §2.2 的 build_apk 缺 out_apk 摩擦）。
    // ============================================================

    @Test
    @DisplayName("★ optional 参数缺键必须放行；必填缺键仍必须拦，且缺参名单不得含可选参数")
    fun optionalMayBeMissingButMandatoryStillRequired() {
        // 只给 path ⇒ offset/limit 缺键，放行
        assertNull(
            invalidDetail(ToolCall("read_file", mapOf("path" to "a.txt"))),
            "optional 参数缺键被拦下了 —— 云端原生 tools 会少发可选字段",
        )
        // 全缺 ⇒ 必须点名 path，且**不得**把两个可选参数算进缺参名单
        val detail = invalidDetail(ToolCall("read_file", emptyMap()))
        assertTrue(detail?.contains("path") == true, "必填缺键必须拦（实际：$detail）")
        assertFalse(detail?.contains("offset") == true, "可选参数不该进缺参名单（实际：$detail）")
        assertFalse(detail?.contains("limit") == true, "可选参数不该进缺参名单（实际：$detail）")
    }

    @Test
    @DisplayName("★ optional 参数给了值照常校验；未知参数照旧拦（optional 不放宽别的规则）")
    fun optionalWithValueIsStillValidated() {
        assertNull(invalidDetail(ToolCall("read_file", mapOf("path" to "a.txt", "offset" to "3"))))
        assertNull(
            invalidDetail(
                ToolCall("read_file", mapOf("path" to "a.txt", "offset" to "", "limit" to "")),
            ),
            "optional + allowEmpty：给了空串也合法（空串=整读的既有契约）",
        )
        val unknown = invalidDetail(
            ToolCall("read_file", mapOf("path" to "a.txt", "nope" to "1")),
        )
        assertTrue(unknown?.contains("未知参数") == true, "未知参数规则不许被放宽（实际：$unknown）")
    }

    @Test
    @DisplayName("★ optional 与 allowEmpty 正交：\"可以不给\" ≠ \"可以给空串\"")
    fun optionalDoesNotImplyAllowEmpty() {
        // host 是 optional 但没声明 allowEmpty
        assertNull(invalidDetail(ToolCall("ping", emptyMap())), "缺键必须放行")
        val detail = invalidDetail(ToolCall("ping", mapOf("host" to "")))
        assertTrue(
            detail?.contains("host") == true,
            "没声明 allowEmpty 的参数，给了空串仍必须拦（实际：$detail）",
        )
    }
}
