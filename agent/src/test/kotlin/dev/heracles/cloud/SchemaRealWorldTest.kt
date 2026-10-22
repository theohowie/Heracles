package dev.heracles.cloud

import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.tool.CloudToolValidator
import dev.heracles.cloud.tool.ToolSchema
import dev.heracles.core.tool.renderObjectSchema
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **真机 Schema 失败复现**（2026-10-21）。
 *
 * 真机现象：`read_file` 连续被拒「参数不符合 Schema」，模型重试 20 轮。
 * 本测试用**真实的** `TYPED_DECLS` 声明，喂进模型真的会发的几种参数形状，
 * 找出到底哪一条过不去。
 */
class SchemaRealWorldTest {

    private fun schemaOf(toolName: String): ToolSchema? {
        val decl = TYPED_DECLS[toolName] ?: return null
        val rendered = renderObjectSchema(decl.params)
        return ToolSchema.fromRendered(rendered)
    }

    @Test
    @DisplayName("★★★ read_file: 只传 path（最常见）必须通过")
    fun readFilePathOnly() {
        val schema = schemaOf("read_file")!!
        val call = CloudToolCall("c1", "read_file", """{"path":"app.txt"}""")
        val r = CloudToolValidator.validate(call, schema)
        assertTrue(r is CloudToolValidator.Result.Valid, "只传 path 必须过。实际：$r")
    }

    @Test
    @DisplayName("★★★ read_file: path + offset + limit 都为整数必须通过")
    fun readFileWithInts() {
        val schema = schemaOf("read_file")!!
        val call = CloudToolCall("c1", "read_file", """{"path":"a.txt","offset":1,"limit":80}""")
        val r = CloudToolValidator.validate(call, schema)
        assertTrue(r is CloudToolValidator.Result.Valid, "整数参数必须过。实际：$r")
    }

    @Test
    @DisplayName("★★ read_file: numbered 为布尔必须通过")
    fun readFileWithBool() {
        val schema = schemaOf("read_file")!!
        val call = CloudToolCall("c1", "read_file", """{"path":"a.txt","numbered":true}""")
        val r = CloudToolValidator.validate(call, schema)
        assertTrue(r is CloudToolValidator.Result.Valid, "布尔参数必须过。实际：$r")
    }

    @Test
    @DisplayName("★★★ read_file: 模型把 offset 写成字符串 \"1\"（常见）应通过还是报错？")
    fun readFileOffsetAsString() {
        val schema = schemaOf("read_file")!!
        val call = CloudToolCall("c1", "read_file", """{"path":"a.txt","offset":"1"}""")
        val r = CloudToolValidator.validate(call, schema)
        // 这是**模型填错类型** ⇒ 应该报错（这是设计意图，让它自愈）
        // 但如果真机反复卡在这，就说明模型学不会 —— 那要重新权衡
        println("[probe] offset 传字符串 ⇒ $r")
        assertTrue(r is CloudToolValidator.Result.Invalid, "类型错应报错（设计意图）")
    }

    @Test
    @DisplayName("★★ 列出所有工具解析出的 schema，检查有没有解析成空/漏 required")
    fun allSchemasParseCorrectly() {
        val problems = mutableListOf<String>()
        for ((name, decl) in TYPED_DECLS) {
            val rendered = renderObjectSchema(decl.params)
            val schema = ToolSchema.fromRendered(rendered)
            if (schema == null) {
                problems += "$name: 解析成 null"
                continue
            }
            if (schema.params.isEmpty()) {
                problems += "$name: 解析出 0 个参数"
                continue
            }
            // required 必须与声明一致
            val expectedRequired = decl.params.filter { it.required }.map { it.name }.sorted()
            val actualRequired = schema.requiredParams().sorted()
            if (expectedRequired != actualRequired) {
                problems += "$name: required 不一致 期望=$expectedRequired 实际=$actualRequired"
            }
            // 每个参数的类型必须与声明一致
            for (p in decl.params) {
                val parsed = schema.params.firstOrNull { it.name == p.name }
                if (parsed == null) {
                    problems += "$name.${p.name}: 解析丢了"
                } else if (parsed.type != p.type.wire) {
                    problems += "$name.${p.name}: 类型不一致 期望=${p.type.wire} 实际=${parsed.type}"
                }
            }
        }
        assertTrue(problems.isEmpty(), "Schema 解析问题：\n" + problems.joinToString("\n"))
    }
}
