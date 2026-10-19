package dev.heracles.core.text

import dev.heracles.core.contract.Contract
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * `LogFilter` 的行为门禁 —— `26-编码层工具链与逆向引擎.md` §7.3。
 *
 * 盯住四件事：
 * 1. **不编造** —— 没有错误行就说没有，不许拿无关输出冒充诊断
 * 2. **≤ 契约额度是字面成立的**（[Contract.Shell.LOG_EXCERPT_LINES]，S1b 起 = 200）——
 *    连 `…` 省略标记一起算，否则"额度行"会被一堆孤立命中撑成近两倍
 * 3. 失败但无关键词时**退化为尾部**（工具直接死了是常态），且如实标注
 * 4. 最早的错误优先（连锁错误里根因在最前面）
 */
class LogFilterTest {

    private val cap = Contract.Shell.LOG_EXCERPT_LINES

    @Test
    @DisplayName("★ 无错误行时如实说'无错误行'，绝不编造")
    fun cleanLogDoesNotInvent() {
        val raw = buildString {
            for (i in 1..50) appendLine("step $i: ok")
        }
        val ex = LogFilter.extract(raw, exitCode = 0)
        assertTrue(ex.isClean, "应当判定为干净")
        assertEquals(0, ex.matchedCount)
        assertTrue(ex.lines.isEmpty(), "干净日志不应产生摘录正文")
        assertTrue(
            LogFilter.format(ex, 0).contains("无错误行"),
            "表头必须说明没有错误行，实际：${LogFilter.format(ex, 0)}",
        )
    }

    @Test
    @DisplayName("★ 退出码非 0 但无关键词 → 退化为尾部，且如实标注")
    fun nonZeroWithoutKeywordFallsBackToTail() {
        val raw = buildString {
            for (i in 1..40) appendLine("line $i")
        }
        val ex = LogFilter.extract(raw, exitCode = 137)
        assertTrue(ex.tailFallback, "应退化到尾部兜底")
        assertFalse(ex.isClean, "退化到尾部**不是**干净")
        assertTrue(ex.lines.isNotEmpty())
        assertTrue(
            LogFilter.format(ex, 137).contains("未匹配到错误关键词"),
            "必须说明是兜底而非命中，实际：${LogFilter.format(ex, 137)}",
        )
    }

    @Test
    @DisplayName("命中行带前后各 5 行上下文")
    fun includesSurroundingContext() {
        val lines = (1..30).map { "line $it" }.toMutableList()
        lines[10] = "error: 找不到符号"
        val ex = LogFilter.extract(lines.joinToString("\n"), exitCode = 1)

        assertEquals(1, ex.matchedCount)
        assertEquals(11, ex.lines.size, "命中行 ± 5 行 = 11 行")
        assertEquals("line 6", ex.lines.first())
        assertEquals("line 16", ex.lines.last())
        assertFalse(ex.truncated)
    }

    @Test
    @DisplayName("★ 渲染行数（含省略标记）严格 ≤ 40")
    fun renderedExcerptNeverExceedsCap() {
        // 100 个孤立命中：若按"日志行数"计额度会渲染成近 80 行
        val lines = (1..300).map { if (it % 3 == 0) "error: e$it" else "line $it" }
        val ex = LogFilter.extract(lines.joinToString("\n"), exitCode = 1)

        assertTrue(
            ex.lines.size <= cap,
            "摘录渲染了 ${ex.lines.size} 行，超过上限 $cap",
        )
        assertTrue(ex.truncated, "应当标记已截断")
        assertTrue(LogFilter.format(ex, 1).contains("截断"), "表头必须说明截断")
    }

    @Test
    @DisplayName("★ 截断时保留**最早**的命中（根因在前面，后面是连锁反应）")
    fun truncationKeepsEarliestHits() {
        val lines = (1..200).map { if (it == 3) "error: 真正的根因" else "error: 连锁 $it" }
        val ex = LogFilter.extract(lines.joinToString("\n"), exitCode = 1)
        assertTrue(
            ex.lines.any { it.contains("真正的根因") },
            "最早的错误必须留下，实际首行：${ex.lines.first()}",
        )
    }

    @Test
    @DisplayName("多个命中区间合并去重，不重复输出同一行")
    fun overlappingRangesAreMerged() {
        val lines = (1..40).map { "line $it" }.toMutableList()
        lines[10] = "error: a"
        lines[11] = "error: b" // 相距 1 行 → 区间必然重叠
        val ex = LogFilter.extract(lines.joinToString("\n"), exitCode = 1)

        assertEquals(2, ex.matchedCount)
        val occurrences = ex.lines.count { it == "line 6" }
        assertEquals(1, occurrences, "重叠区间必须合并，不能重复")
        assertFalse(ex.lines.any { it.contains("…") }, "连续区间之间不该有省略标记")
    }

    @Test
    @DisplayName("CRLF 日志正常处理，且表头带出全量日志路径")
    fun crlfAndLogFileSurvive() {
        val raw = "step 1\r\nerror: boom\r\nstep 3\r\n"
        val ex = LogFilter.extract(raw, exitCode = 1, logFile = ".heracles/logs/build-1.log")
        assertEquals(1, ex.matchedCount)
        assertEquals(".heracles/logs/build-1.log", ex.logFile)
        assertTrue(
            LogFilter.format(ex, 1).contains(".heracles/logs/build-1.log"),
            "表头必须给出完整日志路径（模型要能自己去读）",
        )
    }

    @Test
    @DisplayName("常见致命输出形态都要能命中（javac / aapt2 / gradle 风格不同）")
    fun detectsCommonFailureShapes() {
        val samples = listOf(
            "MainActivity.java:12: error: cannot find symbol",
            "Caused by: java.lang.IllegalArgumentException: bad",
            "FAILURE: Build failed with an exception.",
            "Exception in thread \"main\" java.lang.NullPointerException",
            "panic: runtime error",
            "Traceback (most recent call last):",
        )
        for (s in samples) {
            val ex = LogFilter.extract("noise\n$s\nnoise", exitCode = 1)
            assertTrue(ex.matchedCount > 0, "「$s」应当被识别为错误行")
        }
    }

    @Test
    @DisplayName("空日志不崩")
    fun emptyLogIsSafe() {
        val ex = LogFilter.extract("", exitCode = 0)
        assertEquals(0, ex.totalLines)
        assertTrue(ex.lines.isEmpty())
    }

    @Test
    @DisplayName("超时会被显式标出（不能让模型以为是普通失败）")
    fun timeoutIsMarkedInHeader() {
        val ex = LogFilter.extract("killed", exitCode = -1)
        val text = LogFilter.format(ex, -1, timedOut = true)
        assertTrue(text.startsWith("[超时]"), "超时必须写在最前面，实际：$text")
    }

    // ----------------------------------------------------- 摘录额度（F5a / P1-5；S1b 起只有一档）

    @Test
    @DisplayName("★ 默认额度 = 契约值（200），且**最早命中仍保留**（根因优先不因额度改变）")
    fun excerptUsesContractBudget() {
        // 300 行、每 3 行一个错误 ⇒ 命中区间连成一片，必然撑到额度上限
        val raw = (1..300).joinToString("\n") { if (it % 3 == 0) "error: e$it" else "line $it" }

        val default = LogFilter.extract(raw, exitCode = 1) // 默认 = 契约额度
        val tight = LogFilter.extract(raw, exitCode = 1, maxLines = 20) // 显式收紧（测试用）

        assertTrue(
            default.lines.size <= Contract.Shell.LOG_EXCERPT_LINES,
            "默认必须 ≤ ${Contract.Shell.LOG_EXCERPT_LINES} 行，实际 ${default.lines.size}",
        )
        assertTrue(default.truncated)
        assertEquals(
            Contract.Shell.LOG_EXCERPT_LINES, default.lines.size,
            "300 行密集命中时应当**用满**额度（用不满说明额度没生效）",
        )
        assertTrue(
            tight.lines.size <= 20,
            "显式收紧后必须 ≤ 20 行，实际 ${tight.lines.size}",
        )
        assertEquals(
            default.lines.first(), tight.lines.first(),
            "最早的错误在任何额度下都必须留下（它是根因，不因额度变大而被换掉）",
        )
    }

    @Test
    @DisplayName("★ 日志短于额度 ⇒ 不截断、表头**不许**出现「截断」（别在小输出上撒谎）")
    fun shortLogIsNotMarkedTruncated() {
        // 30 行、1 个 error ⇒ 命中行 ± 5 = 11 行，任何额度都装得下
        val raw = (1..30).joinToString("\n") { if (it == 15) "error: 唯一根因" else "line $it" }

        listOf(Contract.Shell.LOG_EXCERPT_LINES, 20).forEach { tier ->
            val ex = LogFilter.extract(raw, exitCode = 1, maxLines = tier)
            assertFalse(ex.truncated, "额度 $tier 下 30 行日志不该被标成截断")
            assertFalse(
                LogFilter.format(ex, 1).contains("截断"),
                "额度 $tier 下表头不许说「截断」：${LogFilter.format(ex, 1)}",
            )
        }
    }

    @Test
    @DisplayName("★ 额度与搜索结果数是**两个**契约常量（S1b 解绑）：200 vs 40，不再互相连坐")
    fun excerptBudgetIsDecoupledFromSearchResults() {
        // 日志摘录：S1b 起唯一一档 = 200（原"本地 40 / 云端 200"分级已删）
        assertEquals(200, Contract.Shell.LOG_EXCERPT_LINES)
        // 搜索默认结果数：**保持 40**（零回退），且它现在有自己的常量，
        // 不再"直接复用"摘录额度 —— 否则摘录一提，搜索结果数会被动跟着涨 5 倍。
        assertEquals(40, Contract.FsSearch.DEFAULT_MAX_RESULTS)
        assertEquals(200, Contract.FsSearch.MAX_RESULTS_CAP)
        assertTrue(
            Contract.FsSearch.DEFAULT_MAX_RESULTS < Contract.Shell.LOG_EXCERPT_LINES,
            "两者若相等，说明又被绑回一个数了（解绑是 S1b 的有意决定）",
        )
        assertTrue(
            Contract.FsSearch.MAX_RESULTS_CAP <= Contract.FsSearch.DEFAULT_MAX_RESULTS * 10,
            "检索上限不该比默认值大一个量级（上下文是 append-only 的）",
        )
    }

    @Test
    @DisplayName("★ 默认额度与「显式传契约值」的摘录与渲染逐字节一致")
    fun defaultBudgetIsByteIdenticalToExplicitContractValue() {
        // 300 行、每 3 行一个错误 —— 覆盖"合并区间 + 截断"这条最复杂的路径
        val raw = (1..300).joinToString("\n") { if (it % 3 == 0) "error: e$it" else "line $it" }

        // 不传额度（默认路径）
        val implicit = LogFilter.extract(raw, exitCode = 1, logFile = ".heracles/logs/x.log")
        // 显式传契约里的那个数
        val explicit = LogFilter.extract(
            raw, exitCode = 1, logFile = ".heracles/logs/x.log",
            maxLines = Contract.Shell.LOG_EXCERPT_LINES,
        )

        assertEquals(implicit, explicit, "不传额度必须等价于显式传契约值（数据类逐字段相等）")
        assertEquals(
            LogFilter.format(implicit, 1),
            LogFilter.format(explicit, 1),
            "渲染文本也必须逐字节一致",
        )
    }
}
