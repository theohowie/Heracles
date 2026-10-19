package dev.heracles.core.text

import dev.heracles.core.contract.Contract

/**
 * 回给模型的日志摘录 —— `26-编码层工具链与逆向引擎.md` §7.3。
 *
 * ## ★ 为什么是 40 行（本地档）而不是需求里写的 500 行
 *
 * 需求原文要求"只提取 error 附近的 30 行 / 返回不超过 500 行"。500 行在这个
 * 架构里是**有害**的，三条理由都能算出来：
 *
 * | # | 问题 | 量级 |
 * |---|---|---|
 * | 1 | 500 行 ≈ 5000+ token，而契约 §3.2 的 `prompt_n` 稳态增量目标是 **150 token** | **超 30 倍** |
 * | 2 | 铁律 1 是 append-only —— 摘录一旦写进历史就**永久**占位，之后每一轮都重付 prefill | 持续成本 |
 * | 3 | 4B 模型在 5000 token 噪声里定位根因的能力**远低于**在 40 行里 | 质量下降 |
 *
 * （2026-10-18，F5a / P1-5：上面三条都是**本地 4B** 的约束。云端上下文 128K、模型更强，
 * 40 行对它反而是**信息饥饿**（模型只好再 `read_file` 摸一遍，白烧一轮），所以摘录额度
 * 放大到 200。⚠️ **ADR-035 S1b 起它就是 [Contract.Shell.LOG_EXCERPT_LINES] 本身** ——
 * 原来还有一个"本地档 40"与按后端取值的 `logExcerptLinesFor(backend)`，随本地后端删除。
 * 服务对象没了 ⇒ 那三条约束的**原始实测依据仍在**，但**不再是**"为本地算的"。）
 *
 * 所以：**全量落盘**（[logFile]），**摘录进上下文**（≤ [Contract.Shell.LOG_EXCERPT_LINES]）。
 * 需要细节时模型用 `read_file` 主动去读 —— 那是一次**有目的**的读取，
 * 比一次吞掉整份日志省 token，也更接近人的做法。
 *
 * ⚠️ 摘录额度**只影响摘录**：落盘的全量日志一行不少（[extract] 的 `maxLines`
 * 不参与落盘，落盘在调用方 [dev.heracles.agent.tools.RunShellCommandTool.writeLog]）。
 */
data class LogExcerpt(
    /** 摘录正文（已含 `…` 省略标记） */
    val lines: List<String>,
    /** 原始日志总行数 */
    val totalLines: Int,
    /** 命中关键词的行数（0 = 真的没有错误行） */
    val matchedCount: Int,
    /** 是否因超出**摘录档位**（`extract(maxLines=…)`）而截断 */
    val truncated: Boolean,
    /** 全量日志落盘路径（工作区相对） */
    val logFile: String? = null,
    /** 是否因为日志过大而只扫描了首尾（此时 [matchedCount] 可能偏低） */
    val scannedPartially: Boolean = false,
    /** 未命中关键词但退出码非 0 ⇒ 退化为"末尾若干行" */
    val tailFallback: Boolean = false,
) {
    /** 真·干净：没有任何错误行，也没退化到 tail */
    val isClean: Boolean get() = matchedCount == 0 && !tailFallback
}

/**
 * 日志过滤器 —— `26-编码层工具链与逆向引擎.md` §4.1 / §7.3。
 *
 * **纯函数**：不碰文件系统、不起进程。所以可以在 PC 上穷举测试
 * （`LogFilterTest`），而执行命令那侧由 [dev.heracles.core.exec.ShellRunner] 的假实现顶替。
 *
 * ## 设计上最要紧的一条：**不许编造**
 *
 * 没有错误行时**必须**如实说"无错误行"，不得为了"看起来有用"而挑几行
 * 无关输出充当诊断。这跟 `14-框架验证报告.md` 的「进度不能撒谎」是同一条纪律。
 */
object LogFilter {

    /**
     * 命中关键词。
     *
     * 全部大小写不敏感 —— 各家工具风格不一（`error:` / `ERROR:` / `Error:`），
     * 漏报一个根因的代价远大于多带一行噪声。
     *
     * 包含 `panic:` / `traceback`：`javac`、`aapt2`、`python`、
     * `dex2oat` 各自的致命输出形态不同，只认 `error:` 会漏掉后两者。
     */
    private val HIT = Regex(
        """(error:|caused by:|failed|failure|exception|panic:|traceback)""",
        RegexOption.IGNORE_CASE,
    )

    /** `Traceback` 之类以行为单位的标记不需要额外处理；这里定义"末尾兜底"取多少行 */
    private const val TAIL_FALLBACK_DIVISOR = 2

    /** 区间之间的省略标记（也是渲染行，计入额度） */
    private const val GAP_MARKER = "  …"

    /**
     * 过滤。
     *
     * @param rawLog 原始日志（[dev.heracles.core.exec.ShellResult.combined]）
     * @param exitCode 退出码 —— 决定"无命中"时是否退化为末尾兜底
     * @param logFile 全量日志落盘路径（写进表头，方便模型自己去读）
     * @param maxLines **摘录渲染行数上限**（含 `…` 省略标记）。默认
     *   [Contract.Shell.LOG_EXCERPT_LINES]（200）。S1b 之前它是"本地档 40"、
     *   云端由 `RunShellCommandTool` 另传一个数；分级删除后**只有这一个默认值**，
     *   装配处也不再传（传值只为测试构造更小的额度）。
     *   ⚠️ 只影响**摘录**：全量日志的落盘由调用方负责，与本参数无关。
     */
    fun extract(
        rawLog: String,
        exitCode: Int,
        logFile: String? = null,
        maxLines: Int = Contract.Shell.LOG_EXCERPT_LINES,
    ): LogExcerpt {
        if (rawLog.isBlank()) return LogExcerpt(emptyList(), 0, 0, false, logFile)

        val maxScan = Contract.Shell.MAX_CAPTURED_BYTES
        val scannedPartially = rawLog.length > maxScan
        val text = if (scannedPartially) {
            val half = maxScan / 2
            rawLog.take(half) + "\n…（日志过长，中段未扫描）…\n" + rawLog.takeLast(half)
        } else {
            rawLog
        }

        val lines = text.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        val hitIdx = lines.indices.filter { HIT.containsMatchIn(lines[it]) }

        // ---- 无命中：**不得编造** ----
        if (hitIdx.isEmpty()) {
            if (exitCode == 0) {
                return LogExcerpt(
                    lines = emptyList(),
                    totalLines = lines.size,
                    matchedCount = 0,
                    truncated = false,
                    logFile = logFile,
                    scannedPartially = scannedPartially,
                )
            }
            // 退出码非 0 但没有错误关键词 —— 很常见（工具直接死了、被 OOM 杀了、
            // 或只打了 usage）。此时**末尾几行**才是有信息的那几行。
            // 取档位的一半（沿用 40 行时代的比例，零回退；云端档下同比例放大）。
            val tailCount = maxLines / TAIL_FALLBACK_DIVISOR
            val tail = lines.takeLast(tailCount).filter { it.isNotBlank() }
            return LogExcerpt(
                lines = tail,
                totalLines = lines.size,
                matchedCount = 0,
                truncated = lines.size > tail.size,
                logFile = logFile,
                scannedPartially = scannedPartially,
                tailFallback = true,
            )
        }

        // ---- 有命中：命中行 ± 上下文，合并重叠 ----
        val before = Contract.Shell.LOG_CONTEXT_BEFORE
        val after = Contract.Shell.LOG_CONTEXT_AFTER
        val cap = maxLines

        // 合并成区间，避免相邻命中产生重复行
        val ranges = ArrayList<IntArray>()
        for (i in hitIdx) {
            val s = maxOf(0, i - before)
            val e = minOf(lines.lastIndex, i + after)
            val lastRange = ranges.lastOrNull()
            if (lastRange != null && s <= lastRange[1] + 1) {
                lastRange[1] = maxOf(lastRange[1], e)
            } else {
                ranges.add(intArrayOf(s, e))
            }
        }

        // ★ 额度是**渲染行数**（含 `…` 省略标记），不是"日志行数"。
        //   否则 40 个孤立命中会渲染成 79 行 —— 与"≤40 行"的承诺不符。
        //   截断时**保留最早的命中** —— 最早的错误通常是根因，
        //   后面的往往是它的连锁反应（javac 一个未定义符号能带出几十条 error）。
        val out = ArrayList<String>(cap)
        var truncated = false
        var firstRange = true
        for (range in ranges) {
            val marker = if (firstRange) 0 else 1
            val size = range[1] - range[0] + 1
            if (out.size + marker + size > cap) {
                val room = cap - out.size - marker
                if (room > 0) {
                    if (!firstRange) out.add(GAP_MARKER)
                    for (i in range[0] until range[0] + room) out.add(lines[i])
                }
                truncated = true
                break
            }
            if (!firstRange) out.add(GAP_MARKER)
            for (i in range[0]..range[1]) out.add(lines[i])
            firstRange = false
        }

        return LogExcerpt(
            lines = out,
            totalLines = lines.size,
            matchedCount = hitIdx.size,
            truncated = truncated,
            logFile = logFile,
            scannedPartially = scannedPartially,
        )
    }

    /**
     * 渲染成给模型看的文本（`26` §4.1 的形状）。
     *
     * 表头**必须**同时给出"命中几处"和"总共多少行" —— 只给摘录会让模型
     * 以为日志就这么长，从而低估问题规模。
     */
    fun format(excerpt: LogExcerpt, exitCode: Int, timedOut: Boolean = false): String {
        val head = buildString {
            if (timedOut) append("[超时] ")
            append("[exit=$exitCode] ")
            when {
                excerpt.matchedCount > 0 ->
                    append("${excerpt.matchedCount} 处错误 / 共 ${excerpt.totalLines} 行")
                excerpt.tailFallback ->
                    append("未匹配到错误关键词，以下为末尾 ${excerpt.lines.size} 行（共 ${excerpt.totalLines} 行）")
                else ->
                    append("共 ${excerpt.totalLines} 行，无错误行")
            }
            if (excerpt.truncated) append("（摘录已截断）")
            if (excerpt.scannedPartially) append("（日志过大，中段未扫描）")
            if (excerpt.logFile != null) append("（完整日志：${excerpt.logFile}）")
        }
        if (excerpt.lines.isEmpty()) return head
        return head + "\n" + excerpt.lines.joinToString("\n")
    }
}
