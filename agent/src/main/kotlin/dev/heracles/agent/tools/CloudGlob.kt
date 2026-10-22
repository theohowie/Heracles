package dev.heracles.agent.tools

/**
 * glob 通配解析器（CloudAgentPipeline 模块五-3，2026-10-21）。
 *
 * ## 它修复的缺陷
 *
 * 旧实现（FsSearchTools.globToRegex）只支持星号 / 问号 / 双星号，类注释直接写着：
 *
 * > 不支持 [abc] / {a,b} —— 那两种会当字面量处理（0 命中，而不是错配）；
 * > 4B 模型不需要更多语法。
 *
 * 4B 模型不需要更多语法是能力裁剪，不是产品决定。而后果比报错更糟：
 * *.kt.java 这类写法被当字面量 ⇒ 0 命中 ⇒ 模型以为文件不存在，
 * 然后基于残缺事实下结论（可能去重新创建已存在的文件）。
 *
 * ## 完整语法（POSIX glob 的常用子集）
 *
 * | 写法 | 含义 | 例 |
 * |---|---|---|
 * | 星号 | 段内任意字符（不跨斜杠） | *.kt |
 * | 问号 | 段内单个字符 | Main?.kt |
 * | 双星号 | 任意层目录（含 0 层） | src 双星号 test.kt |
 * | [abc] | 字符集 | [Mm]ain.kt |
 * | [a-z] | 字符区间 | file[0-9].txt |
 * | [!abc] 或 [^abc] | 否定字符集 | [!.] 星号 |
 * | {a,b,c} | 枚举（可嵌套） | 星号.{kt,java} |
 *
 * ## 安全边界（必须保留）
 *
 * - 段内星号不跨目录：*.kt 不会匹配 src/A.kt
 * - 其余字符一律转义成字面量：模型写 a+b.kt 时不该被当正则
 * - 未闭合的括号当字面量 + 记 warning（0 命中比正则崩溃好，
 *   但必须把语法问题回给模型，否则它会以为文件不存在）
 *
 * ## 确定性
 *
 * 相同 pattern 永远产出相同正则（不依赖任何集合遍历序）⇒ 结果可复现。
 */
object CloudGlob {

    /**
     * 编译结果。
     *
     * @param regex 编译好的正则
     * @param warnings 语法问题 —— 必须回给模型，
     *   否则它会以为 0 命中 = 文件不存在
     */
    data class Compiled(
        val regex: Regex,
        val warnings: List<String> = emptyList(),
    )

    /**
     * 把 glob 编译成正则。
     *
     * 实现分两步（这是正确性关键）：
     * 1. expandBraces 把 {a,b} 展开成多个独立 pattern（返回 List）
     * 2. 每个 pattern 各自编译，最后用 (?:p1|p2) 合并
     *
     * 注意：不能直接在 pattern 字符串里插竖线 —— 那样后续的星号
     * 会被正则解析成只作用于最后一个分支，且字面量转义会吃掉竖线。
     */
    fun compile(pattern: String): Compiled {
        val warnings = mutableListOf<String>()
        val alternatives = expandBraces(pattern, warnings)
        val bodies = alternatives.map { singleToRegex(it, warnings) }
        val combined = if (bodies.size == 1) bodies[0] else bodies.joinToString("|", "(?:", ")")
        return Compiled(Regex(combined), warnings)
    }

    // ------------------------------------------------------------------ 单 pattern 转正则

    private fun singleToRegex(pattern: String, warnings: MutableList<String>): String {
        val out = StringBuilder()
        var i = 0
        while (i < pattern.length) {
            when (val ch = pattern[i]) {
                '*' -> {
                    val doubleStar = i + 1 < pattern.length && pattern[i + 1] == '*'
                    if (doubleStar) {
                        i += 2
                        if (i < pattern.length && pattern[i] == '/') {
                            out.append("(?:.*/)?")   // 双星号加斜杠 = 任意层目录（含 0 层）
                            i++
                        } else {
                            out.append(".*")
                        }
                        continue
                    }
                    out.append("[^/]*")
                }
                '?' -> out.append("[^/]")
                '[' -> {
                    val close = pattern.indexOf(']', i + 1)
                    if (close < 0) {
                        warnings += "pattern 里的 [ 没有闭合，已按字面量处理：$pattern"
                        out.append(Regex.escape("["))
                    } else {
                        out.append(buildCharClass(pattern.substring(i + 1, close), warnings))
                        i = close
                    }
                }
                else -> out.append(Regex.escape(ch.toString()))
            }
            i++
        }
        return out.toString()
    }

    /** 构建字符集；支持感叹号/脱字符否定与 a-z 区间。 */
    private fun buildCharClass(rawBody: String, warnings: MutableList<String>): String {
        var body = rawBody
        var negate = false
        if (body.startsWith("!") || body.startsWith("^")) {
            negate = true
            body = body.substring(1)
        }
        if (body.isEmpty()) {
            warnings += "pattern 里有空的方括号，已按字面量处理"
            return Regex.escape("[$rawBody]")
        }
        val sb = StringBuilder("[")
        if (negate) sb.append('^')
        var i = 0
        while (i < body.length) {
            val c = body[i]
            if (i + 2 < body.length && body[i + 1] == '-') {
                sb.append(escapeInClass(c)).append('-').append(escapeInClass(body[i + 2]))
                i += 3
            } else {
                sb.append(escapeInClass(c))
                i++
            }
        }
        sb.append(']')
        return sb.toString()
    }

    private fun escapeInClass(c: Char): String = when (c) {
        '\\', ']', '^', '-', '[' -> "\\$c"
        else -> if (c.code < 0x20) String.format("\\u%04x", c.code) else c.toString()
    }

    // ------------------------------------------------------------------ 花括号展开

    /**
     * 把 {a,b} 递归展开成多个独立 pattern。
     *
     * 例：src/{main,test} 加上 星号.{kt,java} 会展开成四个 pattern。
     *
     * 未闭合或无逗号 ⇒ 原样返回（按字面量处理）+ warning。
     */
    private fun expandBraces(pattern: String, warnings: MutableList<String>): List<String> {
        val open = firstTopLevelBrace(pattern)
        if (open < 0) return listOf(pattern)

        // 找与它匹配的右花括号（算嵌套深度）
        var depth = 0
        var close = -1
        for (i in open until pattern.length) {
            when (pattern[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) { close = i; break }
                }
            }
        }
        if (close < 0) {
            warnings += "pattern 里的左花括号没有闭合，已按字面量处理：$pattern"
            return listOf(pattern)
        }

        val prefix = pattern.substring(0, open)
        val body = pattern.substring(open + 1, close)
        val suffix = pattern.substring(close + 1)

        // 按顶层逗号切分
        val parts = mutableListOf<String>()
        var d = 0
        var start = 0
        for (i in body.indices) {
            when (body[i]) {
                '{' -> d++
                '}' -> d--
                ',' -> if (d == 0) { parts += body.substring(start, i); start = i + 1 }
            }
        }
        parts += body.substring(start)

        if (parts.size < 2) {
            warnings += "pattern 里的花括号没有逗号，已按字面量处理：$pattern"
            return listOf(pattern)
        }

        // 每个分支递归展开（分支里可能还有花括号），再与前后缀拼接
        val out = mutableListOf<String>()
        for (p in parts) {
            out += expandBraces(prefix + p + suffix, warnings)
        }
        return out
    }

    /** 第一个不在字符集内的左花括号。 */
    private fun firstTopLevelBrace(pattern: String): Int {
        var inClass = false
        var i = 0
        while (i < pattern.length) {
            when (pattern[i]) {
                '[' -> inClass = true
                ']' -> inClass = false
                '{' -> if (!inClass) return i
            }
            i++
        }
        return -1
    }
}
