package dev.heracles.core.tool

import dev.heracles.core.contract.Contract
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * `ToolRegistry` 的行为门禁 —— `26-编码层工具链与逆向引擎.md` §5。
 *
 * 盯住三件事：
 * 1. **常驻数越限必须构造即失败**（不能静默退化 —— 静默退化的症状是
 *    命中率缓慢下滑，几周后才发现）
 * 2. 检索是**确定的**（得分 → 名字），且**无命中就返回空**，不硬凑
 * 3. [ToolRegistry.namesFor] 的集合可以随披露增长，而常驻部分不受影响
 *    —— 这是"缓存不塌"的前提（`26` §2.1）
 */
class ToolRegistryTest {

    private fun spec(name: String, desc: String = "工具 $name") = ToolSpec(name, desc)

    private val resident = (1..5).map { spec("resident_$it") }

    private val longTail = listOf(
        spec("build_apk", "从零构建一个可安装的 APK"),
        spec("apk_decompile", "把 APK 解包成 smali 与资源"),
        spec("apk_sign", "对 APK 签名"),
        spec("unzip_file", "解压压缩包"),
    )

    private val groups = mapOf(
        "build_apk" to ToolGroup.BUILD,
        "apk_decompile" to ToolGroup.APK,
        "apk_sign" to ToolGroup.APK,
        "unzip_file" to ToolGroup.ARCHIVE,
    )

    private fun registry() = ToolRegistry(resident, longTail, groups)

    // --------------------------------------------------------------- 上限

    @Test
    @DisplayName("★ 常驻超过 FROZEN_LIMIT → 构造即失败（不静默退化）")
    fun residentOverCapFailsLoudly() {
        val tooMany = (1..(Contract.Tools.FROZEN_LIMIT + 1)).map { spec("t_$it") }
        val e = assertThrows(IllegalArgumentException::class.java) {
            ToolRegistry(tooMany)
        }
        assertTrue(
            e.message!!.contains("FROZEN_LIMIT"),
            "错误信息要点明是哪条契约被违反，实际：${e.message}",
        )
    }

    @Test
    @DisplayName("刚好到上限是允许的（12 个常驻合法）")
    fun residentAtCapIsAllowed() {
        val exact = (1..Contract.Tools.FROZEN_LIMIT).map { spec("t_$it") }
        ToolRegistry(exact)
    }

    @Test
    @DisplayName("★ 上限可显式收紧（测试/调参用）：默认 12，13 个当场失败；传 3 则 4 个就失败")
    fun explicitMaxFrozenIsHonored() {
        val thirteen = (1..13).map { spec("t_$it") }
        assertThrows(IllegalArgumentException::class.java) {
            ToolRegistry(thirteen)
        }
        // 显式收紧仍然生效 —— 这条参数不再是"后端档位"，但机制本身必须还在
        val four = (1..4).map { spec("t_$it") }
        assertThrows(IllegalArgumentException::class.java) {
            ToolRegistry(four, maxFrozen = 3)
        }
        assertEquals(3, ToolRegistry(four.take(3), maxFrozen = 3).resident.size)
    }

    @Test
    @DisplayName("★ 长尾上限：默认 24 越限即失败，显式放宽后合法")
    fun longTailOverCapFailsLoudly() {
        val residentSpecs = (1..2).map { spec("r_$it") }
        val tooManyTail = (1..(Contract.Tools.LONG_TAIL_LIMIT + 1)).map { spec("lt_$it") }

        val e = assertThrows(IllegalArgumentException::class.java) {
            ToolRegistry(residentSpecs, tooManyTail)
        }
        assertTrue(
            e.message!!.contains("LONG_TAIL_LIMIT"),
            "错误信息要点明违反了哪条契约（截断会让模型以为工具没了），实际：${e.message}",
        )
        // 显式放宽后同一份输入合法
        val wider = ToolRegistry(
            residentSpecs, tooManyTail,
            maxLongTail = Contract.Tools.LONG_TAIL_LIMIT + 1,
        )
        assertEquals(Contract.Tools.LONG_TAIL_LIMIT + 1, wider.longTail.size)
    }

    @Test
    @DisplayName("★ 每次披露上限：默认 6（唯一一档），可显式收紧到 3")
    fun discloseLimitIsConfigurable() {
        val tail = (1..6).map { spec("apk_tool_$it", "APK 工具 $it") }
        val groups = tail.associate { it.name to ToolGroup.APK }

        val default = ToolRegistry(emptyList(), tail, groups)
        assertEquals(
            Contract.Tools.DISCLOSE_LIMIT,
            default.search("apk").size,
            "默认披露上限必须等于契约里的唯一一档（6）",
        )
        assertEquals(6, default.search("apk").size)

        val tight = ToolRegistry(emptyList(), tail, groups, discloseLimit = 3)
        assertEquals(3, tight.search("apk").size, "显式收紧后一次只披露 3 个")
    }

    @Test
    @DisplayName("工具名不能重复（否则 grammar 枚举出两个同名项）")
    fun duplicateNamesRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            ToolRegistry(listOf(spec("a")), listOf(spec("a")))
        }
    }

    // --------------------------------------------------------------- 检索

    @Test
    @DisplayName("★ 中文同义说法能命中（靠分组的同义词，不靠描述原文）")
    fun findsByChineseSynonym() {
        val found = registry().search("打包")
        assertTrue(found.any { it.name == "build_apk" }, "「打包」应命中 build_apk，实际：${found.map { it.name }}")
    }

    @Test
    @DisplayName("英文关键词也能命中")
    fun findsByEnglishKeyword() {
        assertTrue(registry().search("smali").any { it.name == "apk_decompile" })
        assertTrue(registry().search("zip").any { it.name == "unzip_file" })
    }

    @Test
    @DisplayName("★ 无命中返回空 —— 绝不硬凑'最接近的几个'")
    fun noMatchReturnsEmpty() {
        assertTrue(registry().search("量子纠缠").isEmpty())
        assertTrue(registry().search("").isEmpty())
    }

    @Test
    @DisplayName("结果确定：得分降序 → 名字升序（顺序抖动会让 grammar 抖动）")
    fun searchOrderIsDeterministic() {
        val r = registry()
        val a = r.search("apk").map { it.name }
        val b = r.search("apk").map { it.name }
        assertEquals(a, b)
        val sortedByName = a.sorted()
        assertEquals(sortedByName, a, "同分组同分时应按名字升序，实际：$a")
    }

    @Test
    @DisplayName("每轮披露数受 DISCLOSE_LIMIT 限制（否则 C 区被撑爆）")
    fun respectsDisclosureLimit() {
        val r = registry()
        val found = r.search("apk", limit = 1)
        assertEquals(1, found.size)
        // 默认值也必须收紧
        assertTrue(r.search("apk").size <= Contract.Tools.DISCLOSE_LIMIT)
    }

    // --------------------------------------------------------------- grammar 面

    @Test
    @DisplayName("★ namesFor：常驻恒在，长尾只在披露后出现")
    fun namesForGrowsWithDisclosure() {
        val r = registry()
        val before = r.namesFor()
        assertEquals(5, before.size)
        assertTrue("build_apk" !in before, "未披露的长尾不得进 grammar")

        val after = r.namesFor(disclosed = setOf("build_apk"))
        assertTrue("build_apk" in after, "披露后必须进 grammar（否则模型根本生成不出这个调用）")
        assertEquals(6, after.size)
    }

    @Test
    @DisplayName("★ namesFor 必须排序（契约 §1.2：工具按名字典序）")
    fun namesForIsSorted() {
        val names = registry().namesFor(setOf("apk_sign", "unzip_file"))
        assertEquals(names.sorted(), names)
    }

    @Test
    @DisplayName("★ 披露长尾**不改变**常驻集合 —— 这是'改 grammar 不塌缓存'的前提")
    fun residentSetUnaffectedByDisclosure() {
        val r = registry()
        val residentBefore = r.resident.map { it.name }
        r.namesFor(disclosed = setOf("build_apk", "apk_sign"))
        assertEquals(residentBefore, r.resident.map { it.name })
        assertEquals(5, r.resident.size)
    }

    @Test
    @DisplayName("byName 能查到长尾（校验器需要它来验参数）")
    fun byNameFindsLongTail() {
        assertEquals("build_apk", registry().byName("build_apk")?.name)
        assertEquals(null, registry().byName("不存在"))
    }
}
