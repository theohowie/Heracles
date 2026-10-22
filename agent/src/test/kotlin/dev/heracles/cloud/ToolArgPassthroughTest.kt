package dev.heracles.cloud

import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.tool.CloudToolValidator
import dev.heracles.cloud.tool.ToolSchema
import dev.heracles.core.tool.renderObjectSchema
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **参数值透传门禁** —— 2026-10-21 真机致命 bug 的回归测试。
 *
 * ## 这个 bug 为什么最危险
 *
 * `CloudToolValidator.parseObject` 返回的是**原始 JSON 切片**：
 * ```
 * {"path":"a.txt"}  ⇒  args["path"] == "\"a.txt\""   // 带引号！
 * ```
 * ⇒ 工具拿 `"a.txt"` 当路径 ⇒ 文件不存在 ⇒ 模型反复重试直到放弃。
 *
 * ## 为什么它藏了很久
 *
 * - **类型校验是对的**：`checkType` 需要看到引号才能判 string ⇒ 校验全部通过
 * - **日志看不出**：诊断日志只记"调用了 read_file"，不记结果
 * - **单测看不出**：此前只测"校验是否通过"，没测"值是否原样交给工具"
 *
 * ⇒ 本文件专测**值透传**：工具拿到的必须是干净的值，不是 JSON 字面量。
 */
class ToolArgPassthroughTest {

    private fun schemaOf(tool: String): ToolSchema {
        val decl = TYPED_DECLS[tool] ?: error("no decl for $tool")
        return ToolSchema.fromRendered(renderObjectSchema(decl.params))!!
    }

    private fun args(raw: String, tool: String = "read_file"): Map<String, String> {
        val r = CloudToolValidator.validate(CloudToolCall("c1", tool, raw), schemaOf(tool))
        assertTrue(r is CloudToolValidator.Result.Valid, "应当校验通过：$r")
        return (r as CloudToolValidator.Result.Valid).args
    }

    @Test
    @DisplayName("★★★ 字符串参数**必须去掉引号**（真机 bug：工具拿到的是 \"a.txt\"）")
    fun stringValueIsUnquoted() {
        val a = args("""{"path":"a.txt"}""")
        assertEquals("a.txt", a["path"], "路径不能带引号，否则文件永远找不到")
    }

    @Test
    @DisplayName("★★★ 字符串里的转义要解开（\\n 变真换行，\\\" 变真引号）")
    fun stringEscapesAreDecoded() {
        val a = args("""{"path":"x","content":"line1\nline2 \"quoted\""}""", "write_file")
        assertEquals("line1\nline2 \"quoted\"", a["content"], "转义必须解开，否则写进文件的是字面 \\n")
    }

    @Test
    @DisplayName("★★★ 写文件的 content 必须原样到达（多行 + 中文 + 特殊字符）")
    fun writeContentPreserved() {
        val content = "第一行\\n第二行\\n  a = 1;\\n  b = \\\"x\\\";"
        val a = args("""{"path":"t.txt","content":"$content"}""", "write_file")
        assertEquals(
            "第一行\n第二行\n  a = 1;\n  b = \"x\";",
            a["content"],
            "多行内容必须原样，不能被转义序列破坏",
        )
    }

    @Test
    @DisplayName("★★ 数字 / 布尔参数保持原样（工具侧本来就要 \"200\" / \"true\"）")
    fun scalarsStayRaw() {
        val a = args("""{"path":"a.txt","offset":1,"numbered":true}""")
        assertEquals("1", a["offset"], "整数保留字符串形态")
        assertEquals("true", a["numbered"], "布尔保留字符串形态")
        assertEquals("a.txt", a["path"])
    }

    @Test
    @DisplayName("★★ 数组 / 对象参数保留 JSON 文本（steps / questions 靠它二次解析）")
    fun arraysAndObjectsStayJsonText() {
        val steps = """[{"text":"A","status":"done"}]"""
        val a = args("""{"steps":$steps}""", "update_plan")
        assertEquals(steps, a["steps"], "数组必须保留 JSON 文本，供上层解析")
    }

    @Test
    @DisplayName("★★ 空字符串参数（allowEmpty 语义）不能被当成缺失")
    fun emptyStringArg() {
        val a = args("""{"dir":""}""", "list_files")
        assertEquals("", a["dir"], "显式空串要保持空串（根目录语义）")
    }

    @Test
    @DisplayName("★★ unicode 转义要解开（\\u4e2d 变「中」）")
    fun unicodeEscapeDecoded() {
        val a = args("""{"path":"\u4e2d\u6587.txt"}""")
        assertEquals("中文.txt", a["path"], "\\u 转义必须解开")
    }
}
