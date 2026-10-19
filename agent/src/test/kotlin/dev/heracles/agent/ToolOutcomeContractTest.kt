package dev.heracles.agent

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.io.File

/**
 * `ToolOutcome` 成功语义的**契约门禁**（2026-10-19）。
 *
 * ## 为什么需要这个文件
 *
 * `ToolOutcome` 有四个变体，其中**两个都是"成功"**：
 * [ToolOutcome.Success] 与 [ToolOutcome.SuccessWithImage]。
 * `SuccessWithImage` 上线（`view_image`）之后，历史上散落各处的
 * `outcome is ToolOutcome.Success` 把它判成**失败** ——
 * 真机上的表现是：`view_image` 明明把图片读出来并送进下一轮请求了，
 * UI 却画一张**红色失败卡**，会话里也记成 `ok:false`。
 *
 * 这类 bug **编译器抓不到**（`is Success` 语法完全合法），
 * 靠 code review 也守不住（同一个错误在 `AgentLoop.kt` 里出现了 10 处）。
 * 所以这里用两条腿守住：
 *
 * 1. **语义断言**：`isSuccess` 在四个变体上的取值钉死；
 * 2. **源码扫描门禁**：扫描 `agent` 模块的主源码，禁止再用 `is Success` 判断成功
 *    （详见 [successTypeTestIsBannedInProductionSource] 里的"为什么这样匹配"）。
 *
 * ## 为什么是"扫描源码"而不是"跑行为测试"
 *
 * 行为测试只能覆盖它**被写过**的那些路径。而这里的问题是**同一个错误模式散落在 N 处**，
 * 每新增一处（比如以后在某个新工具里加分支）都不会有人想起补测试。
 * 源码扫描是**全量**的：新写错的地方会立刻变红，且失败消息直接给出 文件 + 行号。
 *
 * 这与 `docs/13-框架约束与门禁.md` 的思路一致：**能静态守住的不靠自觉**。
 */
class ToolOutcomeContractTest {

    // ================================================================
    // 一、语义断言 —— "这次调用成不成功"的唯一判据
    // ================================================================

    @Test
    @DisplayName("★ Success.isSuccess == true")
    fun successIsSuccess() {
        assertTrue(
            ToolOutcome.Success("已写入 2 字节").isSuccess,
            "纯文本成功必须是成功",
        )
    }

    @Test
    @DisplayName("★★ SuccessWithImage.isSuccess == true（这条就是 bug 本身）")
    fun successWithImageIsSuccess() {
        val out = ToolOutcome.SuccessWithImage("已读取图片 a.png", "data:image/png;base64,AAAA")
        assertTrue(
            out.isSuccess,
            "带图片的成功**也是成功** —— 判错它就是真机上那张红色失败卡的根源",
        )
    }

    @Test
    @DisplayName("★ Failure.isSuccess == false")
    fun failureIsNotSuccess() {
        assertFalse(ToolOutcome.Failure("文件不存在").isSuccess, "失败不能算成功")
    }

    @Test
    @DisplayName("★ NeedsApproval.isSuccess == false（没执行 ≠ 成功）")
    fun needsApprovalIsNotSuccess() {
        assertFalse(
            ToolOutcome.NeedsApproval("要删一个目录").isSuccess,
            "需要确认意味着**什么也没做**，绝不能画成成功卡",
        )
    }

    @Test
    @DisplayName("四个变体的 isSuccess = [成功, 成功, 失败, 失败] —— 顺序钉死")
    fun allVariantsCovered() {
        // 这不是凑数：它把"每个变体都该归到哪一类"一次性钉死，
        // 以后**新增第五个成功变体**（例如 SuccessWithFile）时，这里会提示
        // 必须同时更新 `ToolOutcome.isSuccess`，而不是悄悄漏掉。
        val table = listOf(
            "Success" to ToolOutcome.Success("ok"),
            "SuccessWithImage" to ToolOutcome.SuccessWithImage("ok", "data:image/png;base64,AA"),
            "Failure" to ToolOutcome.Failure("bad"),
            "NeedsApproval" to ToolOutcome.NeedsApproval("ask"),
        )
        assertEquals(
            listOf("Success" to true, "SuccessWithImage" to true, "Failure" to false, "NeedsApproval" to false),
            table.map { (name, out) -> name to out.isSuccess },
            "四个变体的成功语义被改动 —— 下游（UI 卡片 / turnRecord.toolSucceeded / isError）全部会跟着错",
        )
    }

    // ================================================================
    // 二、源码扫描门禁 —— 禁止再用 `is ToolOutcome.Success` 判断成功
    // ================================================================

    /**
     * **为什么正则长这样**（这是本条门禁最需要交代的部分）。
     *
     * 目标：抓住"用类型判断**是否成功**"的写法，同时**放过**只关心 `detail` 的写法。
     *
     * ### 放行的写法（不能误伤）
     *
     * ```kotlin
     * val text = when (outcome) {
     *     is ToolOutcome.Success -> outcome.detail        // ← when 分支，取 detail
     *     is ToolOutcome.SuccessWithImage -> outcome.detail
     *     ...
     * }
     * ```
     *
     * 这类写法出现在**穷举 `when` 的 subject 位置**（`is X ->`），语义是
     * "按变体取字段"，**不是**在回答"成不成功"。它有一个天然的结构特征：
     * `is` 前面是**行首或 `when (… ) {` 之后**（或者紧跟在 `else` / `,` 后），
     * 后面紧跟 `->`。
     *
     * ### 要抓的写法（必须变红）
     *
     * 全都是**布尔上下文**里的类型判定 —— `is` 出现在表达式里，参与 `= / && / || / ! / if (...)`：
     *
     * ```kotlin
     * val ok = outcome is ToolOutcome.Success                      // 赋值
     * val ok = !(outcome !is ToolOutcome.Success)                  // 取反后赋值
     * toolSucceeded = outcome is ToolOutcome.Success               // 命名参数
     * (if (outcome is ToolOutcome.Success) "工具成功" else "工具失败") // if 条件
     * isError = !(outcome !is ToolOutcome.Success)                 // 赋值
     * assertTrue(outcome is ToolOutcome.Success)                   //（测试里，见下）
     * ```
     *
     * ### 匹配策略
     *
     * 只看**有效字符**（去掉行注释与块注释 —— 否则 [ToolOutcome.isSuccess] 自己的
     * KDoc 里那句"历史上 `outcome is ToolOutcome.Success`"会把自己扫红）：
     *
     * - `\b!\s*is\s+(ToolOutcome\.)?Success\b` —— **`!is` 永远抓**。
     *   `x !is Success` / `!(x is Success)` 只可能出现在布尔上下文里，
     *   因为取反的结果是个 `Boolean`，没法在 `when` 分支里取 `detail`。
     * - `\bis\s+(ToolOutcome\.)?Success\b` —— **普通 `is`**：再说一遍，
     *   紧跟 `->`（允许换行）的是 `when` 分支，放行；**其余一律抓**。
     *
     * 为什么可以这样砍：`when` 分支必须写成 `is Success -> ...`；
     * 而任何"判成功"的写法都**不可能**以 `->` 结尾（赋值/if 条件都以表达式或 `)` 收尾）。
     * 两者在语法上是**互斥**的，所以按 `->` 区分不产生歧义。
     *
     * ### 为什么连 `is Success`（不带 `ToolOutcome.` 限定）也抓
     *
     * 在 `ToolOutcome` 的伴生/扩展/`when` subject 上下文里可以省掉限定符，
     * 而这恰好是最容易被漏掉、也最容易被 grep 漏掉的写法。**省不省都抓**。
     *
     * ### 为什么不抓 `as ToolOutcome.Success` / `ToolOutcome.Success(…)`
     *
     * `as` 是**转换**（用在已经确认过成功的地方，或测试里取 `detail`），
     * 构造是**造出一个结果**。两者都不回答"成不成功"，不在本门禁的范围里。
     */
    // 边界用显式 lookbehind / lookahead 而不是 `\b`：
    //   - `(?<![\w.])`：前面不能是标识符字符或 `.`，防止把 `foo.is Success` 这种当类型判断；
    //   - `(?![\w.])`：后面不能是标识符字符 —— **这条是命门**：
    //     它保证 `SuccessWithImage` 不会被当成 `Success`（抓错 = 把正当代码扫红）。
    // `\b` 虽然在这里恰好也能区分 `Success` / `SuccessWithImage`（两者之间无分隔符），
    // 但把意图写成 lookahead 更直白，读者不用去推导 `\b` 的定义。
    private val successTypeTest = Regex("""(?<![\w.])is\s+(?:ToolOutcome\.)?Success(?![\w.])""")
    private val negatedSuccessTypeTest = Regex("""(?<![\w.])!\s*is\s+(?:ToolOutcome\.)?Success(?![\w.])""")

    /**
     * "这一行是不是 `when` 分支的开头" —— 注意用 `find(from)` 而不是 `matches()`：
     * `Regex.matches` 要求**整串**匹配，`" -> outcome.detail"` 显然不以 `->` 结尾，
     * 会一律返回 false（2026-10-19 踩过：那会让所有 when 分支都被误抓）。
     * 这里要的是"**以** `->` 开头"，必须用 `find(string = line, startIndex = from)`。
     */
    private fun isArrowBranchOpen(line: String, from: Int = 0): Boolean {
        val i = line.indexOfFirstNonSpace(from)
        return i >= 0 && line.startsWith("->", i)
    }

    private fun String.indexOfFirstNonSpace(from: Int): Int {
        var i = from
        while (i < length && this[i].isWhitespace()) i++
        return if (i < length) i else -1
    }

    /** 扫描目标：`:agent` 的主源码根（本模块自己的那部分）。 */
    private fun agentMainSourceRoot(): File {
        // ⚠️ 路径由运行时推导，不写死盘符：
        //   Gradle 跑测试时 CWD 是 **模块目录**（`agent/`），但 `:agent:test` 也可能被
        //   其他构建方式（IDE / 复合构建）拉起，CWD 不保证。所以这里**逐级上溯**找
        //   "同时含 `agent/src/main/kotlin` 的那一层"作为仓库根，找不到就直接失败并
        //   把走过的候选路径打出来 —— 静默跳过会让门禁变成摆设。
        val candidates = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
            .map { File(it, "agent/src/main/kotlin/dev/heracles/agent") }
            .take(5)
        return candidates.firstOrNull { it.isDirectory }
            ?: throw AssertionError(
                "找不到 agent 主源码目录。已尝试：\n" +
                    candidates.joinToString("\n") { "  - ${it.path}" } +
                    "\nCWD=${System.getProperty("user.dir")}",
            )
    }

    /** 仓库根（`agent/` 的上一级）—— 失败消息里用相对路径，跨机器可读。 */
    private fun repoRoot(): File = agentMainSourceRoot().let { it.parentFile.parentFile.parentFile.parentFile }

    /** 把行注释 / 块注释换成空格（保留换行，行号不变）。 */
    private fun stripComments(src: String): String {
        val out = StringBuilder(src.length)
        var i = 0
        while (i < src.length) {
            val c = src[i]
            val next = if (i + 1 < src.length) src[i + 1] else '\u0000'
            when {
                c == '/' && next == '/' -> {
                    while (i < src.length && src[i] != '\n') { out.append(' '); i++ }
                }
                c == '/' && next == '*' -> {
                    // Kotlin 的块注释**可以嵌套**（AGENTS.md 环境坑 16）——
                    // 所以这里按深度计数，而不是找第一个 "*/"。
                    var depth = 0
                    while (i < src.length) {
                        if (i + 1 < src.length && src[i] == '/' && src[i + 1] == '*') { depth++; out.append("  "); i += 2; continue }
                        if (i + 1 < src.length && src[i] == '*' && src[i + 1] == '/') {
                            depth--; out.append("  "); i += 2
                            if (depth == 0) break
                            continue
                        }
                        out.append(if (src[i] == '\n') '\n' else ' '); i++
                    }
                }
                else -> { out.append(c); i++ }
            }
        }
        return out.toString()
    }

    /** 一条命中：仓库相对路径 + 行号 + 原文行 + 原因。 */
    private data class Hit(val relPath: String, val line: Int, val text: String, val rule: String)

    /**
     * 白名单：`isSuccess` 的**定义体**。
     *
     * 为什么必须开这个口子：`isSuccess` 的唯一实现方式就是类型判断，
     * 禁掉它等于要求"定义自己不能存在"。本门禁收敛的正是**这一处**：
     * 允许用类型判断的地方有且只有 `isSuccess` 的实现。
     *
     * ### 为什么按"整段定义体"而不是"一行"来放行
     *
     * 最初按单行匹配（要求同一行里既有 `isSuccess` 又有 `get(`），
     * 结果把一条**格式约束**写进了产品代码 —— 谁把 getter 折成两行，
     * 门禁就会把 `isSuccess` 自己的实现判成违规（2026-10-19 已经在
     * `TurnRecord.kt` 的 KDoc 里留下这种警告）。门禁不该管代码怎么换行。
     * ⇒ 改成：从 `val isSuccess` 声明开始，取到**这一行结束或大括号配平的
     * getter 体结束**，把整段的换行压平后再判。
     *
     * 口子仍然很窄：必须以 `val isSuccess` 开头、且紧跟 `get(`。
     * 业务代码想在别处重定义成功判定（`val isSuccess = outcome is Success`）
     * 不满足 `get(`，照样会被扫红。
     */
    private val isSuccessDefinitionStart = Regex("""\bval\s+isSuccess\b""")
    private val getterStart = Regex("""\bget\s*\(""")

    /**
     * 求出 [line] 起、属于 `isSuccess` 定义体的**行号集合**（0-based，含首尾）。
     * 找不到定义体就返回空集（那就是没有白名单，正常扫）。
     */
    private fun isSuccessDefinitionLines(cleanLines: List<String>): Set<Int> {
        val start = cleanLines.indexOfFirst { isSuccessDefinitionStart.containsMatchIn(it) }
        if (start < 0) return emptySet()
        // 从声明行起往后看，把 getter 体收进来：
        //   - 同行的 `get() = …` 一行完事；
        //   - `get() { … }` 按大括号配平；
        //   - `get() =\n  …` 表达式体：收到大括号/行尾配平为止（最多看 10 行，够用且不会失控）。
        val out = mutableSetOf(start)
        var depth = 0
        var sawGetter = false
        for (i in start until minOf(cleanLines.size, start + 10)) {
            val line = cleanLines[i]
            if (i > start) out += i
            if (getterStart.containsMatchIn(line)) sawGetter = true
            // 统计本行大括号与括号配平
            line.forEach { c ->
                when (c) {
                    '{', '(' -> depth++
                    '}', ')' -> depth--
                }
            }
            if (sawGetter && depth <= 0 && i > start) break
            // 单行 `val isSuccess: Boolean get() = …`：声明行就含 get(，且本行配平
            if (sawGetter && i == start && depth <= 0) break
        }
        // 声明行里没有 get( ⇒ 不是我们认的那种写法，不白名单
        return if (sawGetter) out else emptySet()
    }

    /**
     * 扫描一段源码文本 —— **按行**，所以行号就是真实行号。
     *
     * @param relPath 失败消息里显示的名字。真实文件传仓库相对路径（够短、跨机器可读），
     *   自检用的临时文件传 `<synthetic>` —— 临时文件在 C 盘/别的盘上，
     *   `relativeTo(repoRoot())` 会抛 "different roots"（2026-10-19 踩过）。
     */
    private fun scanText(relPath: String, raw: String): List<Hit> {
        val cleanLines = stripComments(raw).lines()
        val rawLines = raw.lines()
        val hits = mutableListOf<Hit>()
        // ★ 白名单：`isSuccess` 自己的**定义体**（可能跨多行）。
        //   `val isSuccess get() = this is Success || this is SuccessWithImage`
        //   本质上就是"用类型判断"——**它必须是**，否则 `isSuccess` 无处定义（循环依赖）。
        //   这正是本门禁的收敛点：允许**唯一一处**用类型判断的地方，就是 `isSuccess` 本身。
        val whitelist = isSuccessDefinitionLines(cleanLines)
        for ((idx, line) in cleanLines.withIndex()) {
            if (idx in whitelist) continue
            // 先判 !is（它更具体；`!is` 里也含 "is"，但成功判定归到它自己的规则上，
            // 避免同一行被报两条重复的失败消息）。
            if (negatedSuccessTypeTest.containsMatchIn(line)) {
                hits += Hit(relPath, idx + 1, rawLines.getOrElse(idx) { "" }, "`!is Success`（取反的类型判断 = 布尔上下文）")
                continue
            }
            for (m in successTypeTest.findAll(line)) {
                // 跳过 `!is` 的那一半（上面已经抓过）
                if (m.range.first > 0 && line[m.range.first - 1] == '!') continue
                val after = line.substring(m.range.last + 1)
                // ① 同一行就是 `->`：是 when 分支
                if (isArrowBranchOpen(after)) continue
                // ② `->` 在下一行（老代码常见写法）：看下一行的开头。
                //    注意：只有当本行 `is X` 之后**什么都没有**时才可能是这种写法，
                //    否则（`is X && …` / `is X,`）一定不是分支。
                if (after.isBlank() && idx + 1 < cleanLines.size && isArrowBranchOpen(cleanLines[idx + 1])) continue
                hits += Hit(relPath, idx + 1, rawLines.getOrElse(idx) { "" }, "裸的类型判断（不是 `when` 分支取 detail）")
            }
        }
        return hits
    }

    /** 扫描一个真实文件（路径按仓库根相对化，失败消息才好读）。 */
    private fun scan(file: File): List<Hit> {
        val root = repoRoot()
        val rel = runCatching { file.relativeTo(root).path }
            .getOrElse { file.absolutePath }
            .replace('\\', '/')
        return scanText(rel, file.readText())
    }

    // ------------------------------------------------------------------

    @Test
    @DisplayName("★★ 生产源码里不得用 `is ToolOutcome.Success` 判断成功（只能用 isSuccess）")
    fun successTypeTestIsBannedInProductionSource() {
        val root = agentMainSourceRoot()
        val files = root.walkTopDown().filter { it.isFile && it.extension == "kt" }.sortedBy { it.path }.toList()

        // 先自检扫描器本身：扫空必然"绿"，那是假绿。
        // `agent` 主源码至少十几个文件（README/清单里记的是 20+），少于 5 个说明路径解析错了。
        assertTrue(
            files.size >= 5,
            "扫描到的 .kt 文件只有 ${files.size} 个（$root）—— 路径解析很可能错了，" +
                "否则这条门禁会**静默通过**（假绿）",
        )

        // 注意这里**故意不**断言"源码里必须存在 when 分支" ——
        // 未来若某个 when 被改写成 `when { }`，源码就干净了，不该因此变红。
        // "扫描器本身没坏"由下面的 scannerSelfCheck 负责钉住。

        val hits = files.flatMap { scan(it) }
        assertTrue(
            hits.isEmpty(),
            buildString {
                appendLine("★ 发现 ${hits.size} 处用类型判断「成功」的写法 —— 必须改用 `ToolOutcome.isSuccess`：")
                appendLine()
                hits.forEach { h ->
                    appendLine("  ${h.relPath}:${h.line}  [${h.rule}]")
                    appendLine("      ${h.text.trim()}")
                }
                appendLine()
                appendLine("为什么：`SuccessWithImage`（view_image）也是成功。")
                appendLine("用 `is Success` 判它 ⇒ 真机上画红色失败卡 / 会话记 ok:false。")
                appendLine("改法：`outcome is ToolOutcome.Success` → `outcome.isSuccess`；")
                appendLine("      `!(outcome !is ToolOutcome.Success)` → `outcome.isSuccess`。")
                appendLine("      取 detail 的 `when` 分支（`is Success -> x.detail`）**可以保留**。")
            },
        )
    }

    @Test
    @DisplayName("★ 扫描器自检：典型坏写法必被抓住、when 分支必被放行")
    fun scannerSelfCheck() {
        // 这条测试的理由：门禁的**假阴性**最可怕 —— 扫描器坏了会永远绿。
        // 这里用合成片段把"抓/放"两类写法各钉一遍，正则一被改坏立刻暴露。
        // 用 scanText 而不是落临时文件：临时文件在别的盘上，路径相对化会抛
        // "different roots"（2026-10-19 踩过），而且这里根本不需要文件。
        fun hitsOf(vararg lines: String): List<Hit> = scanText("<synthetic>", lines.joinToString("\n"))

        // ---- 必须抓（布尔上下文）----
        assertEquals(1, hitsOf("val ok = outcome is ToolOutcome.Success").size, "赋值上下文必须抓")
        assertEquals(1, hitsOf("val ok = outcome !is ToolOutcome.Success").size, "取反必须抓")
        assertEquals(1, hitsOf("val ok = !(outcome !is ToolOutcome.Success)").size, "双重取反必须抓")
        assertEquals(1, hitsOf("toolSucceeded = outcome is ToolOutcome.Success").size, "命名参数必须抓")
        assertEquals(1, hitsOf("""(if (o is Success) "工具成功" else "工具失败")""").size, "if 条件 + 省限定符必须抓")
        assertEquals(1, hitsOf("x is ToolOutcome.Success && y").size, "&& 里必须抓")
        assertEquals(1, hitsOf("return outcome is ToolOutcome.Success").size, "return 必须抓")

        // ---- 必须放（when 分支取 detail）----
        assertEquals(0, hitsOf("is ToolOutcome.Success -> outcome.detail").size, "when 分支必须放行")
        assertEquals(0, hitsOf("    is Success -> x.detail").size, "缩进 + 省限定符的 when 分支必须放行")
        assertEquals(0, hitsOf("is ToolOutcome.Success", "    -> outcome.detail").size, "`->` 折到下一行也必须放行")

        // ---- 注释里的代码不算（否则 ToolOutcome 自己的 KDoc 会把自己扫红）----
        assertEquals(0, hitsOf("// 历史上 `outcome is ToolOutcome.Success` 是错的").size, "行注释必须忽略")
        assertEquals(0, hitsOf("/* 块注释里的 x is ToolOutcome.Success */").size, "块注释必须忽略")
        // Kotlin 块注释可嵌套 —— 内层结束后仍在外层注释里，里面的代码照样不算
        assertEquals(
            0,
            hitsOf("/* 外层 /* 内层 */ x is ToolOutcome.Success */").size,
            "嵌套块注释必须按深度处理（AGENTS.md 环境坑 16）",
        )

        // ---- 不该抓的（没在回答"成不成功"）----
        assertEquals(0, hitsOf("val d = (o as ToolOutcome.Success).detail").size, "`as` 转换不抓")
        assertEquals(0, hitsOf("return ToolOutcome.Success(\"ok\")").size, "构造不抓")
        assertEquals(0, hitsOf("ToolOutcome.SuccessWithImage(\"a\", \"data:…\")").size, "SuccessWithImage 构造不抓（注意别把 SuccessWithImage 误判成 Success）")
        assertEquals(0, hitsOf("val ok = o is ToolOutcome.SuccessWithImage").size, "★★ SuccessWithImage 的类型判断**不属于**本门禁范围（抓它 = 误伤）")

        // ---- 白名单：isSuccess 自己的定义，**三种换行写法都必须放行** ----
        // 理由：门禁不该把"代码怎么排版"变成产品约束（曾经就是单行匹配，
        // 逼得 TurnRecord.kt 的 KDoc 里加了一条"必须写在同一行"的警告）。
        assertEquals(
            0,
            hitsOf("val isSuccess: Boolean get() = this is Success || this is SuccessWithImage").size,
            "单行 getter 定义必须放行",
        )
        assertEquals(
            0,
            hitsOf(
                "val isSuccess: Boolean",
                "    get() = this is Success || this is SuccessWithImage",
            ).size,
            "折行的表达式体 getter 必须放行（**这条是 2026-10-19 修的回归**）",
        )
        assertEquals(
            0,
            hitsOf(
                "val isSuccess: Boolean",
                "    get() {",
                "        return this is Success || this is SuccessWithImage",
                "    }",
            ).size,
            "大括号体的 getter 必须放行",
        )
        // 反向：白名单**不能**把别处重定义成功判定也放过
        assertEquals(
            1,
            hitsOf("val isSuccess = outcome is ToolOutcome.Success").size,
            "★ 别处重新定义 isSuccess 属于更严重的违规，必须扫红（白名单只认 `get(` 形式）",
        )
    }
}
