package dev.heracles.core.context

import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec

import dev.heracles.core.contract.Contract
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * 冻结区的**确定性**回归测试 —— `07-开发文档.md` §6.2 必测项之一。
 *
 * 防的是什么：任何非确定性（时间戳、随机数、集合遍历序）混进冻结区。
 * 症状只是"变慢了"，不会报错 —— 必须靠测试拦住。
 */
class PrefixBuilderDeterminismTest {

    private fun tools() = listOf(
        ToolSpec(
            "send_message", "给联系人发送消息",
            listOf(
                ToolParam("text", "string", "消息正文"),
                ToolParam("contact", "string", "联系人姓名"),
            ),
        ),
        ToolSpec("open_app", "打开一个应用", listOf(ToolParam("name", "string", "应用名称"))),
    )

    @Test
    @DisplayName("同一输入构建 100 次，哈希必须全部相同")
    fun determinism() {
        val first = PrefixBuilder.buildFrozen("你是 Heracles，运行在手机上的本地 Agent。", tools())

        repeat(Contract.Testing.DETERMINISM_RUNS) { i ->
            val again = PrefixBuilder.buildFrozen("你是 Heracles，运行在手机上的本地 Agent。", tools())
            assertEquals(
                first.hash, again.hash,
                "第 ${i + 2} 次构建的哈希漂移了 —— 缓存必然归零（02-契约规范.md §1.2）",
            )
            assertEquals(first.text, again.text)
            assertEquals(first.estimatedTokens, again.estimatedTokens)
        }
    }

    @Test
    @DisplayName("工具输入顺序不影响输出（顺序不固定会让缓存随机归零）")
    fun toolOrderIndependence() {
        val a = PrefixBuilder.buildFrozen("sys", tools())
        val b = PrefixBuilder.buildFrozen("sys", tools().reversed())
        assertEquals(a.hash, b.hash)
    }

    @Test
    @DisplayName("参数输入顺序不影响输出")
    fun paramOrderIndependence() {
        val t1 = ToolSpec("t", "d", listOf(ToolParam("a", "string", "A"), ToolParam("b", "string", "B")))
        val t2 = ToolSpec("t", "d", listOf(ToolParam("b", "string", "B"), ToolParam("a", "string", "A")))
        assertEquals(PrefixBuilder.canonicalToolJson(t1), PrefixBuilder.canonicalToolJson(t2))
    }

    @Test
    @DisplayName("Skill 索引顺序不影响输出")
    fun skillIndexOrderIndependence() {
        val s = listOf(
            SkillIndexEntry("wechat-signin", "微信签到", "每日签到"),
            SkillIndexEntry("alarm", "闹钟", "创建提醒"),
        )
        assertEquals(
            PrefixBuilder.buildFrozen("sys", tools(), s).hash,
            PrefixBuilder.buildFrozen("sys", tools(), s.reversed()).hash,
        )
    }

    @Test
    @DisplayName("工具数超过上限必须当场失败（而不是悄悄变慢）")
    fun toolLimitEnforced() {
        val many = (1..Contract.Tools.FROZEN_LIMIT + 1).map { ToolSpec("t$it", "d") }
        assertThrows(IllegalArgumentException::class.java) {
            PrefixBuilder.buildFrozen("sys", many)
        }
    }

    @Test
    @DisplayName("工具名重复必须当场失败")
    fun duplicateToolNameRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            PrefixBuilder.buildFrozen("sys", listOf(ToolSpec("dup", "a"), ToolSpec("dup", "b")))
        }
    }

    @Test
    @DisplayName("内容不同则哈希不同（防止哈希退化成常量）")
    fun differentContentDifferentHash() {
        val a = PrefixBuilder.buildFrozen("sys A", tools())
        val b = PrefixBuilder.buildFrozen("sys B", tools())
        assertNotEquals(a.hash, b.hash)
    }

    @Test
    @DisplayName("冻结区以 system prompt 开头 —— 动态内容不得插到它前面")
    fun systemPromptFirst() {
        val p = PrefixBuilder.buildFrozen("SYS-MARKER", tools())
        assertTrue(p.text.startsWith("SYS-MARKER"))
    }

    // ============================================================
    // ★ `required` 语义（2026-10-18，F7a）
    //
    // `canonicalToolJson` 现在会被云端原生 function calling 直接当 JSON Schema 发出去
    // （ADR-031），所以 `required` **只能列真必填**：列多了 = 教模型多填参数。
    // 下面用**逐字符**的金标准字符串钉住，不用 "contains"（那种断言过了也说明不了格式没变）。
    // ============================================================

    @Test
    @DisplayName("★ 零回退：全必填工具的输出与旧格式逐字符相同（required 全列 + 键序不变）")
    fun allRequiredToolJsonUnchanged() {
        val t = ToolSpec(
            "t", "d",
            listOf(ToolParam("b", "string", "B"), ToolParam("a", "string", "A")),
        )
        assertEquals(
            "{\"name\":\"t\",\"description\":\"d\",\"parameters\":{\"type\":\"object\"," +
                "\"properties\":{\"a\":{\"type\":\"string\",\"description\":\"A\"}," +
                "\"b\":{\"type\":\"string\",\"description\":\"B\"}}," +
                "\"required\":[\"a\",\"b\"]}}",
            PrefixBuilder.canonicalToolJson(t),
            "全必填工具（既有全部工具都是这一类）的 JSON 不许变 —— 变了就是冻结前缀 hash 变",
        )
    }

    @Test
    @DisplayName("★ optional 参数只离开 required，仍留在 properties（照 read_file 的真实形状）")
    fun requiredListsOnlyMandatoryParams() {
        val t = ToolSpec(
            "read_file", "读文件",
            listOf(
                ToolParam("path", "string", "路径"),
                ToolParam("offset", "string", "起始行号", allowEmpty = true, optional = true),
                ToolParam("limit", "string", "行数", allowEmpty = true, optional = true),
            ),
        )
        assertEquals(
            "{\"name\":\"read_file\",\"description\":\"读文件\",\"parameters\":{\"type\":\"object\"," +
                "\"properties\":{\"limit\":{\"type\":\"string\",\"description\":\"行数\"}," +
                "\"offset\":{\"type\":\"string\",\"description\":\"起始行号\"}," +
                "\"path\":{\"type\":\"string\",\"description\":\"路径\"}}," +
                "\"required\":[\"path\"]}}",
            PrefixBuilder.canonicalToolJson(t),
        )
    }

    @Test
    @DisplayName("★ optional 只影响 required：属性对象逐字节不变（标志不外泄到 properties）")
    fun optionalFlagLeaksNowhereButRequired() {
        val mandatory = ToolSpec("t", "d", listOf(ToolParam("a", "string", "A")))
        val optional = ToolSpec("t", "d", listOf(ToolParam("a", "string", "A", optional = true)))
        val m = PrefixBuilder.canonicalToolJson(mandatory)
        val o = PrefixBuilder.canonicalToolJson(optional)
        assertEquals(m.replace("\"required\":[\"a\"]", "\"required\":[]"), o)
    }

    @Test
    @DisplayName("全部参数可选 ⇒ required 是空数组（合法 JSON Schema，且键序仍固定）")
    fun allOptionalMeansEmptyRequired() {
        val t = ToolSpec("t", "d", listOf(ToolParam("a", "string", "A", optional = true)))
        assertEquals(
            "{\"name\":\"t\",\"description\":\"d\",\"parameters\":{\"type\":\"object\"," +
                "\"properties\":{\"a\":{\"type\":\"string\",\"description\":\"A\"}}," +
                "\"required\":[]}}",
            PrefixBuilder.canonicalToolJson(t),
        )
    }

    @Test
    @DisplayName("★ required 的顺序 = 参数名字典序（与 properties 同序，不跟随声明顺序）")
    fun requiredFollowsNameOrder() {
        val t = ToolSpec(
            "t", "d",
            listOf(
                ToolParam("c", "string", "C", optional = true),
                ToolParam("b", "string", "B"),
                ToolParam("a", "string", "A"),
            ),
        )
        val json = PrefixBuilder.canonicalToolJson(t)
        assertTrue(
            json.endsWith("\"required\":[\"a\",\"b\"]}}"),
            "required 必须按名字典序且只含必填（实际：$json）",
        )
        assertTrue(json.indexOf("\"a\":") < json.indexOf("\"b\":"), "properties 也要按名序：$json")
    }
}
