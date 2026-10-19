package dev.heracles.core.context

import dev.heracles.core.contract.Contract
import dev.heracles.core.text.TextMath
import dev.heracles.core.tool.ToolSpec
import java.security.MessageDigest

/** Skill 索引条目（只有索引进冻结区，正文进动态区 —— `04-扩展模型.md` §2.5）。 */
data class SkillIndexEntry(
    val id: String,
    val name: String,
    val summary: String,
)

/**
 * 冻结区前缀 —— `02-契约规范.md` §1。
 *
 * 它是 prompt 中【逐字节不变】的部分。会话开始时构建一次并缓存哈希，
 * 之后每轮只校验不改写；一旦哈希漂移，缓存必然归零。
 */
data class FrozenPrefix(
    val text: String,
    /** SHA-256 十六进制；用于漂移检测（`02-契约规范.md` §1.2） */
    val hash: String,
    val estimatedTokens: Int,
)

/**
 * 冻结区构建器。
 *
 * ## 确定性是硬要求
 *
 * 本对象的所有输出必须是**纯函数**：同样的输入，任意次调用得到逐字节相同的结果。
 * 任何非确定性（时间、随机、集合遍历序、Map 迭代序）都会让缓存归零，
 * 而症状只是"变慢了"，极难定位。因此：
 *
 *  - 工具**按名字典序**排列
 *  - 参数**按名字典序**排列
 *  - JSON **手工序列化**，键序固定（不用依赖库，避免其内部顺序变化）
 *  - **不引入**任何时间戳 / 会话 ID / 随机数
 *
 * 对应回归测试：`PrefixBuilderDeterminismTest`
 */
object PrefixBuilder {

    /**
     * 构建冻结区。
     *
     * @param maxFrozen 常驻工具上限。默认 [Contract.Tools.FROZEN_LIMIT]（12）。
     *   ADR-035 S1b 之前它按后端给档（本地 8 / 云端 12），本地后端删除后
     *   `Contract.Zone` 已删，装配处不再按后端传值。
     * @throws IllegalArgumentException 工具数超过 [maxFrozen]
     */
    fun buildFrozen(
        systemPrompt: String,
        tools: List<ToolSpec>,
        skillIndex: List<SkillIndexEntry> = emptyList(),
        maxFrozen: Int = Contract.Tools.FROZEN_LIMIT,
    ): FrozenPrefix {
        require(tools.size <= maxFrozen) {
            "冻结区常驻工具不得超过 $maxFrozen 个（当前 ${tools.size}）。" +
                "超出部分必须经 search_tools 元工具暴露 —— 02-契约规范.md §4.1"
        }
        require(tools.map { it.name }.toSet().size == tools.size) {
            "工具名必须唯一"
        }

        val sb = StringBuilder()
        sb.append(systemPrompt.trim())
        sb.append("\n\n## 可用工具（仅以下这些，不得编造工具名）\n")
        // 顺序必须固定 —— 按名字典序，不依赖输入的排列
        tools.sortedBy { it.name }.forEach { sb.append(canonicalToolJson(it)).append('\n') }

        if (skillIndex.isNotEmpty()) {
            sb.append("\n## 可用技能索引（正文按需加载）\n")
            skillIndex.sortedBy { it.id }.forEach { s ->
                sb.append("- ").append(s.id).append(": ").append(s.name)
                    .append(" — ").append(s.summary).append('\n')
            }
        }

        val text = sb.toString()
        return FrozenPrefix(
            text = text,
            hash = sha256(text),
            estimatedTokens = TextMath.estimateTokens(text),
        )
    }

    /**
     * 构建**块对齐**的冻结区 —— 云端缓存优化的入口（`实测-07`）。
     *
     * ## 为什么需要
     *
     * `实测-07` 证明 DashScope 按 **1024 token 块**缓存，
     * 命中数恒为块大小的整数倍。**长度不足一块的冻结区命中率为 0。**
     *
     * 首次端到端实测就踩了这个坑：冻结区 513 token → 5 轮全部 0.0% 命中。
     *
     * ## 做法
     *
     * 先按 [buildFrozen] 正常构建，再用 [PrefixAligner] 补齐到块边界的**略上方**。
     * 补齐内容逐字节确定，因此哈希仍然稳定（`02-契约规范.md` §1.2）。
     *
     * @param cacheBlockTokens provider 的缓存块大小。
     *   **本地 llama.cpp 传 1**（token 级精确，不需要补齐，避免浪费 token）。
     * @param maxFrozen 常驻工具上限 —— 原样透传给 [buildFrozen]（默认 = 本地档）。
     */
    fun buildFrozenAligned(
        systemPrompt: String,
        tools: List<ToolSpec>,
        skillIndex: List<SkillIndexEntry> = emptyList(),
        cacheBlockTokens: Int = 1,
        maxFrozen: Int = Contract.Tools.FROZEN_LIMIT,
    ): FrozenPrefix {
        val base = buildFrozen(systemPrompt, tools, skillIndex, maxFrozen)
        if (cacheBlockTokens <= 1) return base

        val target = PrefixAligner.nextBlockBoundary(base.estimatedTokens, cacheBlockTokens)
        val padded = PrefixAligner.padToBlockBoundary(base.text, target)
        return FrozenPrefix(
            text = padded.text,
            hash = sha256(padded.text),
            estimatedTokens = padded.estimatedTokens,
        )
    }

    /**
     * 手工序列化为规范化 JSON。
     *
     * **刻意不使用 JSON 库**：库的键序、缩进、转义策略可能随版本变化，
     * 而这里的每一个字节都直接影响缓存命中率。
     *
     * ## `required` 只列**必填**参数（2026-10-18，F7a）
     *
     * `optional = true` 的参数只进 `properties`，**不进** `required` ——
     * 云端原生 function calling 会把这份 JSON 原样当 JSON Schema 发出去
     * （ADR-031），把可选参数列进 `required` 就是**教模型多填参数**
     * （`docs/27` §2.2 记的 `build_apk` 缺 `out_apk` 摩擦）。
     *
     * ⚠️ **改任何一个参数的 `optional` 都会改冻结前缀的 hash** ⇒ 首次请求
     * prefix cache 必然 miss 一次。这是预期代价（ADR-031"前缀缓存风险"已记），
     * **不要**为了让测试好看把 `required` 写回"全列"。
     *
     * 键序仍固定为 `type` → `properties` → `required`（`02-契约规范.md` §4.3）；
     * 全部参数都可选时 `required` 是**空数组** —— JSON Schema 里合法，
     * 且比"条件性省略整个键"更稳（形状不随内容变）。
     */
    fun canonicalToolJson(tool: ToolSpec): String {
        val params = tool.parameters.sortedBy { it.name }
        val required = params.filter { !it.optional }
        return buildString {
            append("{\"name\":\"").append(escape(tool.name)).append("\",")
            append("\"description\":\"").append(escape(tool.description)).append("\",")
            append("\"parameters\":{\"type\":\"object\",\"properties\":{")
            params.forEachIndexed { i, p ->
                if (i > 0) append(',')
                append('"').append(escape(p.name)).append("\":{\"type\":\"")
                append(escape(p.type)).append("\",\"description\":\"")
                append(escape(p.description)).append("\"}")
            }
            append("},\"required\":[")
            required.forEachIndexed { i, p ->
                if (i > 0) append(',')
                append('"').append(escape(p.name)).append('"')
            }
            append("]}}")
        }
    }

    fun sha256(s: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.UTF_8))
        val hex = StringBuilder(digest.size * 2)
        for (b in digest) {
            val v = b.toInt() and 0xFF
            hex.append(HEX[v ushr 4]).append(HEX[v and 0x0F])
        }
        return hex.toString()
    }

    private const val HEX = "0123456789abcdef"

    /** 最小化 JSON 字符串转义。转义结果必须稳定，不得依赖平台默认编码。 */
    private fun escape(s: String): String = buildString(s.length + 8) {
        for (ch in s) {
            when (ch) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (ch.code < 0x20) {
                    append("\\u").append(String.format("%04x", ch.code))
                } else {
                    append(ch)
                }
            }
        }
    }
}
