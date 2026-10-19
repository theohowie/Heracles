package dev.heracles.core.text

/**
 * 文本与 token 的确定性计算工具。
 *
 * 全部为纯函数 —— 前缀冻结链路（`PrefixBuilder`）依赖它们，
 * 任何非确定性都会让缓存归零（`02-契约规范.md` §1.2）。
 */
object TextMath {

    /**
     * 两个字符串的**逐字符**最长公共前缀长度。
     *
     * 为什么是逐字符而不是逐 token：缓存匹配在真实后端是 token 级的，
     * 但 token 级匹配的前提正是"前缀逐字节相同"。
     * 在测试替身里用字符级 LCP 足以复现"append-only 命中 / 分支塌缩"的行为差异。
     */
    fun longestCommonPrefixLength(a: String, b: String): Int {
        val limit = minOf(a.length, b.length)
        var i = 0
        while (i < limit && a[i] == b[i]) i++
        return i
    }

    /**
     * 粗略 token 估算（**确定性**，仅用于预算与测试，不参与计费）。
     *
     * ## ⚠️ 这个估算**不可靠**，不得用于缓存块对齐（2026-10-09 实测修正）
     *
     * 首版启发式是「CJK 1 token/字 + 其它 1 token/4 字符」。
     * `实测-08` 的缓存诊断证明它**严重高估**：
     *
     * | | 估算值 | API 实际值 | 偏差 |
     * |---|---|---|---|
     * | 冻结区文本 | 1027 | **732** | **+40%** |
     *
     * 后果很严重：块对齐按"假的 1024"补齐，真实长度只有 732 ——
     * **根本没跨过 1024 块边界，缓存命中率恒为 0%**。
     *
     * 修正后的系数（按 732/1027 反推）：
     * - CJK ≈ 0.7 token / 字（Qwen 对中文压缩得比预期好）
     * - 其它 ≈ 1 token / 3.5 字符
     *
     * ## 即便如此，**仍不得用它做块对齐**
     *
     * 估算终究是估算。块对齐必须用**实测 token 数**：
     * 先用 [dev.heracles.core.context.PrefixAligner] 保守补齐到明显超过块边界，
     * 再用 provider 返回的真实 `promptTokens` 校准。
     *
     * 本函数只用于"预算是否可能超限"这类**粗判**。
     */
    fun estimateTokens(s: String): Int {
        var cjk = 0
        var other = 0
        for (ch in s) {
            if (isCjk(ch)) cjk++ else other++
        }
        // 系数按实测-08 校准；刻意略微下修，避免再次高估
        return (cjk * 7 / 10) + (other * 2 + 6) / 7
    }

    private fun isCjk(ch: Char): Boolean {
        val c = ch.code
        return c in 0x4E00..0x9FFF ||   // CJK 统一表意
            c in 0x3400..0x4DBF ||      // 扩展 A
            c in 0x3000..0x303F ||      // CJK 标点
            c in 0xFF00..0xFFEF         // 全角
    }
}
