package dev.heracles.core.patch

/**
 * 补丁的一行。
 *
 * KDoc 来源：`26-编码层工具链与逆向引擎.md` §4.3。
 */
sealed interface PatchLine {
    /** 行内容（不含 diff 的前导标记字符） */
    val text: String

    /** 上下文行（原文里存在，应用后仍在） */
    data class Context(override val text: String) : PatchLine

    /** 删除行 */
    data class Remove(override val text: String) : PatchLine

    /** 新增行 */
    data class Add(override val text: String) : PatchLine
}

/** 一个修改块（`@@ -旧起点,旧行数 +新起点,新行数 @@`）。 */
data class PatchHunk(
    val oldStart: Int,
    val oldCount: Int,
    val newStart: Int,
    val newCount: Int,
    val lines: List<PatchLine>,
)

/** 解析结果。 */
data class ParsedPatch(val hunks: List<PatchHunk>) {
    /** 改变的行数（不含上下文）—— 用于回报"改了几处" */
    val changeCount: Int get() = hunks.sumOf { h -> h.lines.count { it !is PatchLine.Context } }
}

/** 应用结果。**失败时绝不产生半成品** —— 见 [UnifiedPatch.apply]。 */
sealed interface ApplyResult {
    /**
     * @param whitespaceTolerant 是否靠"忽略行尾空白"才匹配上的。
     *   如实回报：让模型知道它的补丁与原文有空白差异（下次可以更准）。
     */
    data class Ok(
        val text: String,
        val hunks: Int,
        val changedLines: Int,
        val whitespaceTolerant: Boolean = false,
    ) : ApplyResult

    data class Failed(val reason: String) : ApplyResult
}

/**
 * unified diff 的解析与应用 —— `26-编码层工具链与逆向引擎.md` §4.3。
 *
 * ## 为什么是纯函数（不碰文件系统）
 *
 * `apply_patch` 的**全部失败模式都在文本层**：上下文不匹配、行尾空白差异、
 * CRLF、末尾有无换行、行号漂移。把它们放进纯函数后可以**穷举测试**，
 * 不必准备临时目录、不必清理。工具侧只剩"读文件 → 调它 → 写文件"。
 *
 * ## ★ 原子性：失败**不得**半写入
 *
 * [apply] 只在**全部**修改块都成功后才返回 [ApplyResult.Ok]。
 * 任何一个块匹配不上就整体失败 —— 不返回"改了一半"的文本。
 * 理由：改了一半的 smali 会编译出**行为诡异**的 APK，比"什么都没改"难查得多。
 */
object UnifiedPatch {

    private val HUNK_HEADER =
        Regex("""^@@\s+-(\d+)(?:,(\d+))?\s+\+(\d+)(?:,(\d+))?\s+@@""")

    /** 这些是 diff 的元信息头，**不是**内容行 */
    private fun isMetaLine(line: String): Boolean =
        line.startsWith("diff ") || line.startsWith("index ") ||
            line.startsWith("--- ") || line.startsWith("+++ ") ||
            line.startsWith("new file mode") || line.startsWith("deleted file mode") ||
            line.startsWith("similarity index") || line.startsWith("rename ") ||
            line.startsWith("old mode") || line.startsWith("new mode") ||
            line.startsWith("\\ No newline at end of file")

    /**
     * 解析。
     *
     * @return 格式非法或**没有任何修改块**时返回 null —— **不猜**。
     *   返回一个空补丁会让调用方以为"成功但没改"，那是最坏的结果。
     */
    fun parse(diff: String): ParsedPatch? {
        val normalized = diff.replace("\r\n", "\n").replace('\r', '\n')
        // ★ 去掉**结尾**那个换行再切分。
        //
        // 否则 `"…\n+NEW\n"` 会切出末尾一个空元素，而空元素被当作
        // 「空上下文行」（真实 unified diff 里确实用空行表示空上下文行）——
        // 于是每个修改块都会凭空多一行上下文，**整份补丁永远匹配不上**。
        //
        // 这是模型的真实输出形态：几乎必然以换行结尾。
        // （该 bug 被 PatchToolsTest 抓住：补丁声明 1 行，却被当成 2 行。）
        val lines = (if (normalized.endsWith("\n")) normalized.dropLast(1) else normalized)
            .split('\n')
        val hunks = ArrayList<PatchHunk>()
        var i = 0
        while (i < lines.size) {
            val m = HUNK_HEADER.find(lines[i])
            if (m == null) {
                // 修改块之间允许有元信息头；其它意外行一律忽略（宽容解析）
                i++
                continue
            }
            val oldStart = m.groupValues[1].toInt()
            val oldCount = m.groupValues[2].ifEmpty { "1" }.toInt()
            val newStart = m.groupValues[3].toInt()
            val newCount = m.groupValues[4].ifEmpty { "1" }.toInt()
            i++

            val body = ArrayList<PatchLine>()
            while (i < lines.size && HUNK_HEADER.find(lines[i]) == null) {
                val raw = lines[i]
                when {
                    isMetaLine(raw) -> { /* 跳过 */ }
                    raw.startsWith("+") -> body.add(PatchLine.Add(raw.substring(1)))
                    raw.startsWith("-") -> body.add(PatchLine.Remove(raw.substring(1)))
                    raw.startsWith(" ") -> body.add(PatchLine.Context(raw.substring(1)))
                    // 完全空行：多数生成器把"空上下文行"写成空串（省掉前导空格）
                    raw.isEmpty() -> body.add(PatchLine.Context(""))
                    else -> {
                        // 修改块内出现认不出的行 ⇒ 补丁是坏的。宁可直接失败。
                        return null
                    }
                }
                i++
            }
            hunks.add(PatchHunk(oldStart, oldCount, newStart, newCount, body))
        }
        return if (hunks.isEmpty()) null else ParsedPatch(hunks)
    }

    /** 便捷入口：解析 + 应用。 */
    fun applyDiff(original: String, diff: String): ApplyResult {
        val parsed = parse(diff) ?: return ApplyResult.Failed(
            "补丁格式无法解析（没有找到 @@ 修改块）。请用 unified diff 格式，" +
                "并确保至少含一个 @@ -a,b +c,d @@ 头。"
        )
        return apply(original, parsed)
    }

    /**
     * 应用。
     *
     * ## 匹配策略（严格优先，但给出明确的失败原因）
     *
     * 1. 按修改块声明的行号**精确**匹配
     * 2. 不匹配 → 全文搜索"旧侧"序列；**唯一命中**才采用（容忍模型写错行号）
     * 3. 0 处命中 → 再用"忽略行尾空白"重试一次（并如实标记）
     * 4. 仍失败 → 整体 [ApplyResult.Failed]，**不返回半成品**
     */
    fun apply(original: String, patch: ParsedPatch): ApplyResult {
        val eol = if (original.contains("\r\n")) "\r\n" else "\n"
        val normalized = original.replace("\r\n", "\n").replace('\r', '\n')
        val trailingNewline = normalized.endsWith("\n")
        val lines: MutableList<String> =
            if (normalized.isEmpty()) mutableListOf()
            else normalized.removeSuffix("\n").split("\n").toMutableList()

        var delta = 0
        var whitespaceTolerant = false
        var changed = 0

        for ((n, hunk) in patch.hunks.withIndex()) {
            // ★ 顺序**必须**保留（交错），不能写成"全部上下文 + 全部删除" ——
            //   unified diff 的语义是"把旧侧的行序列换成新侧的行序列"，
            //   上下文行是**位置标记**，夹在删除行之间。拼错顺序会让
            //   90% 的补丁匹配不上（这个 bug 被 UnifiedPatchTest 当场抓住）。
            val oldSide = hunk.lines.filter { it !is PatchLine.Add }.map { it.text }
            val newSide = hunk.lines.filter { it !is PatchLine.Remove }.map { it.text }

            // ---- 定位 ----
            val at: Int
            if (oldSide.isEmpty()) {
                // 纯新增块：没有可匹配的旧侧，只能信行号
                at = (hunk.oldStart - 1 + delta).coerceIn(0, lines.size)
            } else {
                val expected = hunk.oldStart - 1 + delta
                when {
                    matchesAt(lines, expected, oldSide, tolerant = false) -> at = expected
                    else -> {
                        val hits = allMatches(lines, oldSide, tolerant = false)
                        when {
                            hits.size == 1 -> at = hits[0]
                            hits.size > 1 -> return ApplyResult.Failed(
                                "第 ${n + 1} 个修改块的上下文在文件中出现 ${hits.size} 次，" +
                                    "无法确定改哪一处。请补足上下文行使其唯一。"
                            )
                            else -> {
                                val tolerantHits = allMatches(lines, oldSide, tolerant = true)
                                when {
                                    tolerantHits.size == 1 -> {
                                        at = tolerantHits[0]
                                        whitespaceTolerant = true
                                    }
                                    else -> return ApplyResult.Failed(
                                        "第 ${n + 1} 个修改块的上下文与文件不匹配" +
                                            "（声明行号 ${hunk.oldStart}，附近内容对不上）。" +
                                            "请先 read_file 看清现状再生成补丁。"
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // ---- 替换 ----
            val end = minOf(at + oldSide.size, lines.size)
            lines.subList(at, end).clear()
            lines.addAll(at, newSide)
            delta += newSide.size - oldSide.size
            changed += hunk.lines.count { it !is PatchLine.Context }
        }

        // ★ 空补丁**不是成功**（2026-10-19 真机教训）——
        //   设备会话里模型输出过 `patch = "@@ -1,1 +1,1 @@\n"`：有块头、**没有任何
        //   +/- 行**。旧实现会走到 [ApplyResult.Ok]（文本原样），工具层再报
        //   "补丁已应用，但文件内容未发生变化" = **成功** ⇒ 计划被推进、任务空转，
        //   用户看到的是"它说改好了、其实什么都没改"。
        //   空补丁 = 模型没写出改动，必须失败并说清原因。
        if (changed == 0) {
            return ApplyResult.Failed(
                "补丁里没有任何改动：只有 @@ 块头，没有以 + 或 - 开头的行。" +
                    "要改文件，就在 @@ 块里写出真正的删除/新增行；不需要改就别再调 apply_patch。"
            )
        }

        val body = lines.joinToString(eol)
        val text = if (trailingNewline) body + eol else body
        return ApplyResult.Ok(text, patch.hunks.size, changed, whitespaceTolerant)
    }

    private fun matchesAt(
        lines: List<String>,
        at: Int,
        side: List<String>,
        tolerant: Boolean,
    ): Boolean {
        if (at < 0 || at + side.size > lines.size) return false
        for (k in side.indices) {
            if (!sameLine(lines[at + k], side[k], tolerant)) return false
        }
        return true
    }

    private fun allMatches(lines: List<String>, side: List<String>, tolerant: Boolean): List<Int> {
        val out = ArrayList<Int>()
        if (side.isEmpty() || side.size > lines.size) return out
        for (start in 0..(lines.size - side.size)) {
            if (matchesAt(lines, start, side, tolerant)) out.add(start)
        }
        return out
    }

    private fun sameLine(a: String, b: String, tolerant: Boolean): Boolean =
        if (tolerant) a.trimEnd() == b.trimEnd() else a == b
}
