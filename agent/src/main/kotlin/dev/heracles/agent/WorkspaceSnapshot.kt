package dev.heracles.agent

import dev.heracles.core.contract.Contract
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs

/**
 * **工作区快照**（F8a / P2-1「跨轮记忆」，2026-10-18）—— 只读地把"现在有什么"变成一段文本。
 *
 * ## 它解决的是哪一件事
 *
 * 用户批评（`docs/27` §2.2 ③）：*"每个会话做完任务说一句打包成 apk 就应该能打"*。
 * 卡点是**跨轮只回放文本**：模型看不到工作区现状，于是
 * 要么重复劳动、要么在"文件似乎不存在"的错误前提上瞎猜。
 *
 * ## 为什么是"快照"而不是"回放工具轨迹"
 *
 * 完整轨迹回放 = 把历次 `tool_result` 原文再塞一遍 ⇒ 上下文成本乘 N，
 * 而且**旧结果会与新事实矛盾**（第 1 轮读过 `a.txt`，第 3 轮它已经变了）。
 * 快照只描述**此刻**：文件树 + 最近改动路径 + 产物 ⇒ 成本恒定、永不过期。
 * 需要内容时模型自己 `read_file`（读到的永远是新版本）。
 *
 * ## 三条硬纪律（每一条都有测试钉住）
 *
 * 1. **纯函数**：输出只取决于（排序后的条目、records 的路径、轮次、上限）。
 *    **不含时间戳、不含绝对路径、不含随机** —— 否则前缀缓存与可复现性一起塌
 *    （`FileEntry` 的 KDoc 已经为"不加 mtime"写过同一条理由）。
 * 2. **只读**：本对象**只调用** `list`，绝不 `writeText`/`mkdirs`（测试钉住写调用数 == 0）。
 * 3. **截断如实**：到上限就写"另有 N 项未列出"；遍历被兜住时只能说"**至少** N 个"。
 *    **静默截断**比不注入更糟 —— 模型会在错误前提上得出"文件不存在"。
 *
 * ## 已知边界（**取舍**，不是缺陷 —— `WorkspaceSnapshotInvalidationTest` 钉住）
 *
 * 「变更才注入」的判据是**渲染出来的那段文本**（去掉轮次标记后逐字节比，见 [factsOf]）。
 * 那段文本**刻意**不含 mtime、也不含文件内容（R1 的理由）⇒
 * **同路径 + 同大小 + 「最近改动」行不变**时文本相同，我们**不**重新注入
 * （典型：反复把同一个文件写成同样长度）。
 *
 * 为什么接受它：要覆盖这一情形，只能把"本轮发生过成功写"算进判据 ⇒
 * 退化成"写一次注入一次"（= 每轮都注入，白烧 token，F8b 就白做了）。
 * 影响有限：这种情况下文件树本就没有可观察变化，模型照旧快照**不会得到错误结论**
 * （路径没变、大小没变）。
 *
 * ⚠️ 换句话说：快照陈述的是「**发生过什么 + 现在有什么**」，
 * **不是**「文件内容的哈希」。需要内容时模型自己 `read_file`（读到的永远是新版本）。
 *
 * ## 它**不**进冻结前缀
 *
 * 调用点在 `AgentLoop` 每轮开头，以 `Turn.User` **append**（与 `renderProgressLedger`
 * 同一个槽位）⇒ 前缀零回退是**结构上不可能变**，不是"我们保证"。
 *
 * ⚠️ **未验**：真模型会不会被它误导（例如看到 `dist/` 就以为已经构建过）。
 * 本对象只陈述事实，并在产物行里显式写明"文件存在 ≠ 构建成功"。
 */
internal object WorkspaceSnapshot {

    /** 写类工具：只有它们**成功**执行过，才算"最近改动"。 */
    private val WRITE_TOOLS = setOf("write_file", "apply_patch")

    /**
     * 产物后缀（小写比较）。
     *
     * 刻意是一个**短的、可枚举的**集合 —— 不是"看起来像产物的都算"。
     * 猜错方向（把源码当产物）比不列更糟：模型会以为拿到了构建结果。
     */
    private val ARTIFACT_SUFFIXES = listOf(".apk", ".aab", ".jar", ".dex", ".zip")

    /** 根目录出现即值得说的工程标记（纯事实，不做"该不该构建"的建议）。 */
    private val PROJECT_MARKERS = listOf("AndroidManifest.xml", "build.gradle", "build.gradle.kts")

    /**
     * 渲染快照。
     *
     * **只有**「真的没有任何内容可读」**且**「没有任何目录读失败」时才返回 `null`（不注入空壳）。
     * 反过来说：**只要有目录读不到，就必须返回一段明确的话**，哪怕文件数为 0 ——
     * 因为"读不到"是**未知**，而 `null` 会被读成"没什么可说"（≈"这里没东西"）。
     * 全部目录都失败时给的是 ⚠️ 陈述；部分失败时给的是"有 N 个目录读取失败"的计数。
     *
     * @param records 本轮之前的执行记录（只读；用来算"最近改动"）
     * @param turnIndex 轮次（只进文本当标记；是会话内局部量，不进冻结前缀）
     */
    suspend fun render(
        workspace: WorkspaceFs,
        records: List<TurnRecord>,
        turnIndex: Int,
        maxEntries: Int = Contract.Context.MAX_SNAPSHOT_ENTRIES,
        maxDepth: Int = Contract.Context.MAX_SNAPSHOT_DEPTH,
        maxChars: Int = Contract.Context.MAX_SNAPSHOT_CHARS,
        maxWalk: Int = Contract.Context.MAX_SNAPSHOT_WALK,
        maxRecent: Int = Contract.Context.MAX_SNAPSHOT_RECENT,
    ): String? {
        val walk = walk(workspace, maxDepth, maxWalk)
        val recent = recentWrites(records, maxRecent)
        val unreadable = walk.unreadableDirs > 0
        // ★ 「全部目录都读不到」与「部分读不到」必须分开：
        //   前者是"未知"（什么都别断言），后者是"其余部分的陈述仍然成立"。
        val allDirsFailed = walk.attemptedDirs > 0 && walk.unreadableDirs == walk.attemptedDirs
        // ⚠️ 只有"**真的什么都没有可读、且没有任何目录读失败**"才允许返回 null。
        //   读失败时返回 null = 把"读不到"说成"没什么可说"（同一个谎的两个版本）。
        if (walk.files.isEmpty() && recent.isEmpty() && !unreadable) return null

        val sorted = walk.files.sortedBy { it.relativePath }
        val listed = sorted.take(maxEntries)
        val artifacts = sorted.filter { isArtifact(it.relativePath) }
        val markers = PROJECT_MARKERS.filter { m -> sorted.any { it.relativePath == m } }

        val head = "【工作区现状 · 第 $turnIndex 轮】"
        val treeLines = listed.map { it.render() }
        val tail = mutableListOf<String>()

        if (allDirsFailed) {
            // ★ 一个目录都读不到 ⇒ 只能陈述"读不到"。**不许**在这一格沉默：
            //   沉默会被模型合理地读成"这里没东西 ⇒ 我新建吧"，然后覆盖用户的东西。
            //   （"省略"比"错误"更难发现 —— 错误会被断言抓，省略只会让人走错方向。）
            tail.add(
                "⚠️ 无法读取工作区：${walk.unreadableDirs} 个目录全部读取失败" +
                    " —— 这不是「空工作区」，是「读不到」",
            )
        }

        // ★ 如实计数：没被兜住 ⇒ 精确总数；被兜住 ⇒ 只能说"至少"
        val total = if (walk.truncated) {
            "至少 ${sorted.size} 个文件（目录过大，遍历已在 ${maxWalk} 项处停止）"
        } else {
            "共 ${sorted.size} 个文件"
        }
        val hidden = sorted.size - listed.size
        val countLine = if (hidden > 0) "（$total；另有 $hidden 项未列出 —— 已达上限 $maxEntries）" else "（$total）"
        if (listed.isNotEmpty() || hidden > 0) tail.add(countLine)

        if (unreadable && !allDirsFailed) {
            // 读不到的目录**不能当空目录**：那会让模型以为"这里没有文件"
            tail.add("（有 ${walk.unreadableDirs} 个目录读取失败，其内容未计入 —— 不是「空目录」）")
        }

        if (recent.isNotEmpty()) tail.add("【最近改动】" + recent.joinToString("、"))
        if (artifacts.isNotEmpty()) {
            tail.add(
                "【产物】" + artifacts.joinToString("、") { "${it.relativePath} (${it.sizeBytes}B)" } +
                    "（文件存在 ≠ 构建成功 —— 要结论请自己核对或重新构建）",
            )
        }
        if (markers.isNotEmpty()) {
            tail.add("【工程标记】根目录有 " + markers.joinToString("、") + " ⇒ 看起来是 Android 工程")
        }

        return clamp(head, treeLines, tail, maxChars)
    }

    // ---------------------------------------------------------------- 内部

    /**
     * **变更判定用的"事实"**（F8b）—— 去掉首行的**轮次标记**，只留事实。
     *
     * ## 为什么必须去掉标记
     *
     * [render] 的首行是 `【工作区现状 · 第 N 轮】`，而 `N` 每轮都变。
     * 若直接拿整段文本比"变没变"，**每轮都算变了** ⇒ "变更才注入"退化成
     * "每轮都注入"（F8b 白做）。所以判据必须是**标记之外**的那部分。
     *
     * ## 标记的语义（因此可以滞后）
     *
     * 标记 = **取这份快照的那一轮**，不是"当前第几轮"。事实没变时我们**不**重新注入
     * ⇒ 历史里那份的标记会停在取它的那一轮 —— 这是**准确**的：
     * 它描述的就是"第 N 轮时的工作区现状"，而既然事实没变，它就仍然成立。
     * （这比每轮补一句"现状未变"省 token，也更诚实：不制造新事实。）
     *
     * ⚠️ 判据**就是快照文本本身**（文件名 + 大小 + 最近改动 + 产物），
     * 不是"文件数变了"之类的近似 —— 改名一个文件（条目数不变）也会被判为变更。
     */
    internal fun factsOf(snapshotText: String): String = snapshotText.substringAfter('\n')

    /**
     * @param attemptedDirs 真正调用过 `list` 的目录数（**成功 + 失败**）
     * @param unreadableDirs 其中失败的目录数
     *
     * 两个数都要：只报失败数时，**"全部失败"与"部分失败"分不开** ——
     * 而这两种情况对模型的含义完全不同（前者是"未知"，后者是"其余部分是空的"）。
     */
    private class Walk(
        val files: List<FileEntry>,
        val truncated: Boolean,
        val attemptedDirs: Int,
        val unreadableDirs: Int,
    )

    /**
     * 有界遍历。
     *
     * ## 为什么顺序也要讲
     *
     * 遍历用的栈是 LIFO ⇒ **入栈顺序反过来**查目录才能得到稳定的访问顺序。
     * 顺序不稳定时，一旦撞上 [maxWalk] 兜底，**"哪 5000 个进了结果"就随机了**
     * ⇒ 同一棵树两次渲染可能不同 ⇒ 纯函数不成立。输出最终还会按路径排序，
     * 但**兜底时的入选集合**只能靠遍历顺序定 —— 所以这里必须排。
     */
    private suspend fun walk(workspace: WorkspaceFs, maxDepth: Int, maxWalk: Int): Walk {
        val files = ArrayList<FileEntry>()
        var truncated = false
        var attempted = 0
        var unreadable = 0
        val stack = ArrayDeque<Pair<String, Int>>()
        stack.addLast("" to 0)

        while (stack.isNotEmpty()) {
            if (files.size >= maxWalk) {
                truncated = true
                break
            }
            val (dir, depth) = stack.removeLast()
            attempted++
            val entries = try {
                workspace.list(dir)
            } catch (e: Exception) {
                // 读不到 ≠ 空。计数后如实上报，绝不静默当空目录。
                unreadable++
                continue
            }
            for (e in entries.sortedBy { it.relativePath }) {
                if (e.isDirectory) continue
                files.add(e)
                if (files.size >= maxWalk) break
            }
            // ★ 撞上成本闸 ⇒ 后面**可能还有**。这里必须置位：
            //   走到"栈空"才退出的话，被闸住的这一轮就**不会**留下痕迹，
            //   于是"至少 N 个"会被错报成"共 N 个"（我的测试当场抓到了这个漏报）。
            //   宁可保守地说下界，也**绝不**把一个下界当成精确总数。
            if (files.size >= maxWalk) {
                truncated = true
                break
            }
            if (depth >= maxDepth) continue
            // 反序入栈 ⇒ 出栈时按路径升序，遍历顺序可复现
            val subDirs = entries.filter { it.isDirectory }.map { it.relativePath }.sortedDescending()
            for (d in subDirs) stack.addLast(d to (depth + 1))
        }
        return Walk(files, truncated, attempted, unreadable)
    }

    /**
     * 「最近改动」= **成功执行过**的写类工具动过的路径。
     *
     * ⚠️ 只认 `toolSucceeded == true`：被拦截 / 失败的写**不许**混进来。
     * 那是"把没发生的事写成发生了"（与 H-1 同源的假信息），
     * 模型会据此以为文件已经写好，从此不再写。
     */
    private fun recentWrites(records: List<TurnRecord>, maxRecent: Int): List<String> {
        val seen = LinkedHashSet<String>()
        // 倒着走：越靠后的记录越新 ⇒ 第一次见到的位置就是"最近一次动它"的位置
        for (r in records.asReversed()) {
            val t = r.toolCall ?: continue
            if (t.tool !in WRITE_TOOLS) continue
            if (r.toolSucceeded != true) continue
            val path = t.args["path"]?.takeIf { it.isNotBlank() } ?: continue
            seen.add(path)
        }
        // 最近的排前面：会话里越靠后 = 越新
        return seen.take(maxRecent).toList()
    }

    private fun isArtifact(path: String): Boolean {
        val lower = path.lowercase()
        return ARTIFACT_SUFFIXES.any { lower.endsWith(it) }
    }

    /**
     * 字符硬闸：从**尾部**逐行丢，并标注"已截断"。
     *
     * 从尾部丢（而不是从头）是为了保住 `【工作区现状】` 头与树的开头 ——
     * 模型最先需要的是"这是什么工作区"，不是最后几个文件。
     * 尾部那几段（最近改动 / 产物 / 工程标记）信息密度更高，
     * 所以先丢**树的行**，树丢光了再丢尾部段。
     */
    private fun clamp(head: String, treeLines: List<String>, tail: List<String>, maxChars: Int): String {
        val tree = treeLines.toMutableList()
        val tailLines = tail.toMutableList()
        var dropped = 0
        fun assemble(): String = buildString {
            append(head).append('\n')
            tree.forEach { append(it).append('\n') }
            tailLines.forEach { append(it).append('\n') }
            if (dropped > 0) append("（内容过长，已截断 $dropped 行）\n")
        }
        while (assemble().length > maxChars) {
            when {
                tree.isNotEmpty() -> { tree.removeAt(tree.size - 1); dropped++ }
                tailLines.size > 1 -> { tailLines.removeAt(tailLines.size - 1); dropped++ }
                else -> break
            }
        }
        return assemble().trimEnd()
    }
}
