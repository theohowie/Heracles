package dev.heracles.agent.tools

import dev.heracles.agent.ToolOutcome
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.MAX_READ_BYTES
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Paths

/**
 * 搜索工具的行为门禁 —— `27-工具面诊断.md` P1-1。
 *
 * ## 为什么这些断言必须存在
 *
 * 1. **不依赖 shell**：两个工具只接收 `WorkspaceFs`（构造函数里没有 `ShellRunner`），
 *    所以"SAF 工作区也能用"是**结构保证**，不是靠某次真机跑通。本测试用内存假实现，
 *    连真磁盘都不碰 —— SAF 后端根本没有"真路径"可碰。
 * 2. **截断必须如实**：静默截断比"没找到"更糟。模型会把"我看到的就是全部"当真，
 *    然后基于残缺结果下结论。所以"共 N / 只显示前 M / 还有 K 未显示"里的数字
 *    必须能被程序核对，而不是写死的文案。
 * 3. **越界是拒绝不是跳过**：`dir` 里的 `..`、以及**后端返回的**越界条目，
 *    都必须让整次调用失败。静默跳过会让一次越界尝试从日志里消失。
 * 4. **工具内部不许抛异常**：非法正则 / 非法参数 / 坏后端一律是 `Failure`。
 *    抛出去会打断整轮任务。
 * 5. **工具名与参数名要钉住**：工具名是缓存前缀的一部分（冻结区），改名等于
 *    让所有会话的前缀失效。
 */
class FsSearchToolsTest {

    // ==================================================================== 夹具

    /**
     * 内存工作区 —— 测试**绝不碰真磁盘**。
     *
     * 为什么不用 `RealWorkspaceFs` + 临时目录（`FileToolsTest` 那样）：
     * ① 要证明工具只依赖 `WorkspaceFs` 接口（SAF 就是另一套实现）；
     * ② 越界条目、含 NUL 的"二进制"、超过 1 MB 的文件这类**坏输入**，
     *    只有在假实现里才能廉价构造。
     */
    private class FakeFs : WorkspaceFs {

        private val files = linkedMapOf<String, String>()
        private val emptyDirs = linkedSetOf<String>()

        /** 每次 readText 的目标 —— 用来断言"二进制/超大文件根本没被读"。 */
        val reads = mutableListOf<String>()

        /** 注入"坏后端"返回的越界条目。 */
        var injectedEntries: List<FileEntry> = emptyList()

        /** 这些目录列不出来（模拟权限 / 瞬时 IO 错误）。 */
        val failingDirs = mutableSetOf<String>()

        override val info = WorkspaceInfo(Paths.get("fake-workspace"), "fake")

        fun file(path: String, content: String) {
            files[path] = content
        }

        fun dir(path: String) {
            emptyDirs += path
        }

        override suspend fun list(relativeDir: String): List<FileEntry> {
            val dir = relativeDir.trim().trim('/')
            if (dir in failingDirs) throw IllegalStateException("列目录失败：$dir")

            val prefix = if (dir.isEmpty()) "" else "$dir/"
            val found = linkedMapOf<String, FileEntry>()
            val childDirs = linkedSetOf<String>()

            for ((path, content) in files) {
                if (!path.startsWith(prefix)) continue
                val rest = path.removePrefix(prefix)
                if (rest.isEmpty()) continue
                val slash = rest.indexOf('/')
                if (slash >= 0) {
                    childDirs += prefix + rest.substring(0, slash)
                } else {
                    val size = content.toByteArray(Charsets.UTF_8).size.toLong()
                    found[path] = FileEntry(path, size, false)
                }
            }
            for (path in emptyDirs) {
                if (path == dir || !path.startsWith(prefix)) continue
                val rest = path.removePrefix(prefix)
                if (rest.isEmpty()) continue
                val slash = rest.indexOf('/')
                childDirs += if (slash >= 0) prefix + rest.substring(0, slash) else path
            }
            childDirs.forEach { found[it] = FileEntry(it, 0L, true) }

            // 与真实实现同样的确定性顺序：目录在前、路径排序
            val result = found.values
                .sortedWith(compareBy({ !it.isDirectory }, { it.relativePath }))
                .toMutableList()
            // 越界条目只在根目录注入一次（模拟"坏后端"）
            if (dir.isEmpty()) result += injectedEntries
            return result
        }

        override suspend fun readText(relativePath: String): String {
            reads += relativePath
            val content = files[relativePath]
                ?: throw IllegalArgumentException("文件不存在：$relativePath")
            if (content.toByteArray(Charsets.UTF_8).size > MAX_READ_BYTES) {
                throw IllegalArgumentException("文件过大：$relativePath")
            }
            return content
        }

        override suspend fun writeText(relativePath: String, content: String): Long {
            files[relativePath] = content
            return content.toByteArray(Charsets.UTF_8).size.toLong()
        }

        override suspend fun exists(relativePath: String): Boolean {
            val path = relativePath.trim().trim('/')
            if (path.isEmpty()) return true
            if (path in files || path in emptyDirs) return true
            return files.keys.any { it.startsWith("$path/") } ||
                emptyDirs.any { it.startsWith("$path/") }
        }

        override suspend fun mkdirs(relativeDir: String) {
            val path = relativeDir.trim().trim('/')
            if (path.isNotEmpty()) emptyDirs += path
        }
    }

    private fun find(fs: WorkspaceFs, vararg args: Pair<String, String>): ToolOutcome =
        runBlocking { FindFilesTool(fs).execute(args.toMap()) }

    private fun grep(fs: WorkspaceFs, vararg args: Pair<String, String>): ToolOutcome =
        runBlocking { GrepFilesTool(fs).execute(args.toMap()) }

    private fun ok(out: ToolOutcome): String {
        assertTrue(out is ToolOutcome.Success, "应当成功，实际：$out")
        return (out as ToolOutcome.Success).detail
    }

    private fun fail(out: ToolOutcome): String {
        assertTrue(out is ToolOutcome.Failure, "应当是 Failure（不许抛异常、更不许假装成功）：$out")
        return (out as ToolOutcome.Failure).reason
    }

    // ============================================================ ① find_files

    @Test
    @DisplayName("find_files：按文件名匹配、任意深度，输出按路径排序")
    fun findFilesMatchesByFileNameAtAnyDepth() {
        val fs = FakeFs().apply {
            file("src/Main.kt", "fun main() {}")
            file("src/util/Text.kt", "fun text() {}")
            file("app/src/main/AndroidManifest.xml", "<manifest/>")
            file("README.md", "# hi")
        }
        val out = ok(find(fs, "pattern" to "*.kt"))

        assertTrue(out.contains("src/Main.kt"), "任意深度的 *.kt 都要命中：$out")
        assertTrue(out.contains("src/util/Text.kt"))
        assertFalse(out.contains("README.md"), "*.kt 不该命中 README.md")
        assertTrue(
            out.indexOf("src/Main.kt") < out.indexOf("src/util/Text.kt"),
            "输出必须确定（按路径排序），否则同一状态会产生不同 prompt：$out",
        )
        assertTrue(out.startsWith("找到 2 个匹配的文件"), "总数必须是真数：$out")
    }

    @Test
    @DisplayName("find_files：路径通配（* 不跨目录、** 任意层）+ dir 限范围")
    fun findFilesMatchesPathPatternsAndDirectoryScope() {
        val fs = FakeFs().apply {
            file("src/Main.kt", "")
            file("src/deep/Nested.kt", "")
            file("lib/Main.kt", "")
            file("build.gradle.kts", "")
            file("app/build.gradle", "")
        }

        val direct = ok(find(fs, "pattern" to "src/*.kt"))
        assertTrue(direct.contains("src/Main.kt"))
        assertFalse(direct.contains("src/deep/Nested.kt"), "单个 * 不跨目录：$direct")

        val deep = ok(find(fs, "pattern" to "src/**/*.kt"))
        assertTrue(deep.contains("src/Main.kt"), "** 必须能匹配 0 层目录：$deep")
        assertTrue(deep.contains("src/deep/Nested.kt"), "** 必须能匹配任意层目录：$deep")

        val gradle = ok(find(fs, "pattern" to "build.gradle*"))
        assertTrue(gradle.contains("build.gradle.kts"), "不含 / 时按文件名匹配：$gradle")
        assertTrue(gradle.contains("app/build.gradle"), "不含 / 时在任何深度都要找：$gradle")

        val scoped = ok(find(fs, "pattern" to "*.kt", "dir" to "lib"))
        assertTrue(scoped.contains("lib/Main.kt"))
        assertFalse(scoped.contains("src/Main.kt"), "dir 必须限住搜索范围：$scoped")
    }

    @Test
    @DisplayName("find_files：0 命中是 Success 且明说 0，并交代忽略规则")
    fun findFilesZeroHitsIsSuccessAndExplainsScope() {
        val fs = FakeFs().apply { file("src/Main.kt", "") }
        val out = ok(find(fs, "pattern" to "*.java"))

        assertTrue(out.contains("0 命中"), "0 命中必须明说，不能把空结果说成找到：$out")
        assertTrue(out.contains("pattern=*.java"), "必须回显搜索条件：$out")
        assertTrue(out.contains(".git"), "0 命中时要说明忽略规则，否则模型不知道是不是被跳过了：$out")
    }

    @Test
    @DisplayName("★ find_files：截断如实报出「共 N / 只显示前 M / 还有 K」")
    fun findFilesTruncationReportsRealTotal() {
        val fs = FakeFs()
        repeat(5) { fs.file("src/F$it.kt", "") }

        val out = ok(find(fs, "pattern" to "*.kt", "max_results" to "2"))
        assertTrue(out.contains("共 5 个匹配"), "必须报真实总数（不能只说「截断了」）：$out")
        assertTrue(out.contains("只显示前 2 个"), "必须报显示了几条：$out")
        assertTrue(out.contains("还有 3 个未显示"), "未显示数必须是真的：$out")
        assertEquals(
            2,
            out.lines().count { it.endsWith(".kt") },
            "正文只能给 max_results 条路径：$out",
        )
    }

    @Test
    @DisplayName("find_files：非法参数 → 可读 Failure（不抛异常、不空成功）")
    fun findFilesRejectsInvalidParams() {
        val fs = FakeFs().apply { file("src/Main.kt", "") }

        assertTrue(fail(find(fs, "pattern" to " ")).contains("pattern"))
        assertTrue(fail(find(fs, "pattern" to "../etc/*")).contains(".."))
        assertTrue(fail(find(fs, "pattern" to "/abs/*.kt")).contains("/"))

        // 越界：一律拒绝，且说明原因
        assertTrue(fail(find(fs, "pattern" to "*.kt", "dir" to "../other")).contains("路径被拒绝"))
        assertTrue(fail(find(fs, "pattern" to "*.kt", "dir" to "/abs")).contains("路径被拒绝"))
        assertTrue(fail(find(fs, "pattern" to "*.kt", "dir" to "C:/x")).contains("路径被拒绝"))

        // 目录拼错 vs 真的 0 命中，必须让模型分得清
        assertTrue(fail(find(fs, "pattern" to "*.kt", "dir" to "nope")).contains("目录不存在"))
        assertTrue(fail(find(fs, "pattern" to "*.kt", "dir" to "src/Main.kt")).contains("是文件"))

        listOf("0", "-1", "abc").forEach { bad ->
            val reason = fail(find(fs, "pattern" to "*.kt", "max_results" to bad))
            assertTrue(reason.contains("max_results"), "reason 要点名参数：$reason")
            assertTrue(reason.contains(bad), "reason 要带上收到的值：$reason")
        }

        // 超上限是收敛并说明，不是失败 —— 模型只是"想尽量多"
        val clamped = ok(find(FakeFs().apply { file("a.kt", "") }, "pattern" to "*.kt", "max_results" to "5000"))
        assertTrue(clamped.contains("收敛到上限"), "超上限必须如实说收敛了：$clamped")
    }

    // ============================================================ ② grep_files

    @Test
    @DisplayName("grep_files：输出「路径:行号:内容」，行号 1-based 且命中数/文件数正确")
    fun grepFilesReportsPathLineAndContent() {
        val fs = FakeFs().apply {
            file("src/A.kt", "package a\n\nfun needle() {}\n")
            file("src/B.kt", "// 没有命中\n")
        }
        val out = ok(grep(fs, "pattern" to "needle"))

        assertTrue(out.contains("src/A.kt:3:fun needle() {}"), "格式必须是 路径:行号:内容：$out")
        assertTrue(out.contains("命中 1 处，共 1 个文件"), "必须报命中数与文件数：$out")
        assertFalse(out.contains("src/B.kt"), "没命中的文件不该出现：$out")
    }

    @Test
    @DisplayName("grep_files：正则与 ignore_case（默认区分大小写）")
    fun grepFilesSupportsRegexAndCaseOption() {
        val fs = FakeFs().apply {
            file("src/A.kt", "fun main() {}\nfun helper() {}\n")
            file("src/B.kt", "NEEDLE\n")
        }

        val regex = ok(grep(fs, "pattern" to "fun\\s+\\w+\\("))
        assertTrue(regex.contains("src/A.kt:1:fun main() {"), "正则必须真的生效：$regex")
        assertTrue(regex.contains("src/A.kt:2:fun helper() {"))

        // 默认区分大小写：NEEDLE 不该被 needle 命中
        assertTrue(ok(grep(fs, "pattern" to "needle")).startsWith("0 命中"))

        val insensitive = ok(grep(fs, "pattern" to "needle", "ignore_case" to "true"))
        assertTrue(insensitive.contains("src/B.kt:1:NEEDLE"), "ignore_case=true 必须生效：$insensitive")
        assertTrue(insensitive.contains("忽略大小写"), "必须回显大小写策略：$insensitive")

        assertTrue(
            fail(grep(fs, "pattern" to "x", "ignore_case" to "maybe")).contains("ignore_case"),
            "非法布尔值必须点名参数"
        )
    }

    @Test
    @DisplayName("★ grep_files：非法正则 → Failure（不抛 PatternSyntaxException）")
    fun grepFilesInvalidRegexIsReadableFailure() {
        val fs = FakeFs().apply { file("a.txt", "x") }
        val reason = fail(grep(fs, "pattern" to "["))

        assertTrue(reason.contains("正则"), "reason 要点明是正则问题：$reason")
        assertTrue(reason.contains("["), "reason 要带上收到的 pattern：$reason")
        assertTrue(reason.length > 8, "reason 要可读，不是空壳：$reason")
    }

    @Test
    @DisplayName("★ grep_files：截断时「还有 N 处未显示」是真数（超出上限仍继续数）")
    fun grepFilesTruncationCountsEveryHit() {
        val fs = FakeFs().apply {
            file("a.txt", "hit1\nhit2\nhit3\n")
            file("b.txt", "hit4\nhit5\n")
        }
        val out = ok(grep(fs, "pattern" to "hit", "max_results" to "2"))

        assertTrue(out.contains("共命中 5 处（2 个文件）"), "总数与文件数必须是真数：$out")
        assertTrue(out.contains("只显示前 2 处"), "必须报显示了几处：$out")
        assertTrue(out.contains("还有 3 处未显示"), "未显示数必须是真的：$out")
        assertEquals(
            2,
            out.lines().count { Regex("""^[ab]\.txt:\d+:""").containsMatchIn(it) },
            "正文只能给 max_results 条命中：$out",
        )
    }

    // ============================================================== ③ 扫描边界

    @Test
    @DisplayName("★ 固定忽略目录（.git/build/.heracles/node_modules…）两个工具都跳过，并说明")
    fun ignoredDirectoriesAreSkippedForBothTools() {
        val fs = FakeFs().apply {
            file("src/keep.txt", "needle")
            file(".git/config.txt", "needle")
            file("build/out.txt", "needle")
            file(".heracles/log.txt", "needle")
            file("node_modules/pkg/i.js", "needle")
            file("app/build/cache.txt", "needle")
        }

        val found = ok(find(fs, "pattern" to "*.txt"))
        assertTrue(found.contains("src/keep.txt"))
        listOf(
            ".git/config.txt", "build/out.txt", ".heracles/log.txt",
            "node_modules/pkg/i.js", "app/build/cache.txt",
        ).forEach {
            assertFalse(found.contains(it), "忽略目录里的文件必须被跳过：$it in $found")
        }
        assertTrue(found.contains("跳过"), "跳过目录必须如实说明：$found")

        val hits = ok(grep(fs, "pattern" to "needle"))
        assertTrue(hits.contains("src/keep.txt:1:needle"))
        assertFalse(hits.contains(".git/config.txt"), "grep 也必须跳过忽略目录：$hits")
        assertTrue(hits.contains("命中 1 处"), "只该剩下 1 处命中：$hits")
    }

    @Test
    @DisplayName("★ 深度上限：40 层深目录不栈溢出、不返回深层文件，并如实说截断")
    fun depthLimitStopsRunawayRecursionWithoutStackOverflow() {
        val fs = FakeFs()
        val deep = (1..40).joinToString("/") { "d$it" }
        fs.file("$deep/Deep.kt", "")
        fs.file("Shallow.kt", "")

        val out = ok(find(fs, "pattern" to "*.kt"))
        assertTrue(out.contains("Shallow.kt"))
        assertFalse(out.contains("Deep.kt"), "超过深度上限的文件不该被返回：$out")
        assertTrue(out.contains("超过 16 层未进入"), "深度截断必须如实说明：$out")

        fs.file("$deep/Deep.txt", "needle")
        val hits = ok(grep(fs, "pattern" to "needle"))
        assertTrue(hits.startsWith("0 命中"), "深处的命中不该被扫到（同一条深度规则）：$hits")
    }

    @Test
    @DisplayName("★ 越界：dir 里的 .. 与「坏后端返回的越界条目」都必须 Failure（列目录 + 读取两条路）")
    fun pathEscapesAreRejectedForBothTools() {
        val fs = FakeFs().apply { file("src/a.txt", "needle") }
        assertTrue(fail(find(fs, "pattern" to "*.txt", "dir" to "../")).contains("路径被拒绝"))
        assertTrue(fail(grep(fs, "pattern" to "needle", "dir" to "../")).contains("路径被拒绝"))

        val bad = FakeFs().apply {
            file("src/a.txt", "needle")
            injectedEntries = listOf(FileEntry("../outside.txt", 6L, false))
        }
        assertTrue(
            fail(find(bad, "pattern" to "*.txt")).contains("路径被拒绝"),
            "find 必须拒绝后端返回的越界条目，不许静默跳过",
        )
        assertTrue(
            fail(grep(bad, "pattern" to "needle")).contains("路径被拒绝"),
            "grep 必须拒绝后端返回的越界条目，不许静默跳过",
        )
    }

    @Test
    @DisplayName("★ 二进制与超大文件：跳过并在结果里说明，且读之前就拦下")
    fun grepSkipsBinaryAndOversizedFilesButSaysSo() {
        val fs = FakeFs().apply {
            file("src/ok.txt", "needle here")
            file("assets/logo.png", "needle")                  // 扩展名黑名单
            file("weird.txt", "needle\u0000binary")            // 读后 NUL 检测
            file("huge.txt", "x".repeat(1_000_001))            // 超过 MAX_READ_BYTES
        }

        val out = ok(grep(fs, "pattern" to "needle"))
        assertTrue(out.contains("src/ok.txt:1:needle here"))
        assertFalse(out.contains("logo.png:1"), "二进制文件不该出命中：$out")
        assertFalse(out.contains("weird.txt:1"), "含 NUL 的文件不该出命中：$out")
        assertTrue(out.contains("跳过 2 个二进制文件"), "跳过的二进制文件必须说明：$out")
        assertTrue(out.contains("跳过 1 个超大文件"), "跳过的超大文件必须说明：$out")
        assertFalse(fs.reads.contains("assets/logo.png"), "扩展名黑名单必须在读之前生效")
        assertFalse(fs.reads.contains("huge.txt"), "超大文件必须在读之前按 sizeBytes 拦下")
    }

    @Test
    @DisplayName("grep_files：超长行截断并说明（minified 文件一行能吃掉整个预算）")
    fun grepTruncatesVeryLongLines() {
        val fs = FakeFs().apply { file("min.js", "needle" + "x".repeat(1000) + "\n") }

        val out = ok(grep(fs, "pattern" to "needle"))
        assertTrue(out.contains("min.js:1:needle"), "命中必须保留行首（模式就在那里）：$out")
        assertTrue(out.contains("…"), "超长行必须带省略号，不能整行塞进上下文：$out")
        assertTrue(out.contains("行超过 240 字符已截断"), "截断必须如实说明：$out")
    }

    @Test
    @DisplayName("坏目录：列不出来只记录、不毁掉整次搜索（并如实说明）")
    fun unreadableDirectoryIsReportedNotFatal() {
        val fs = FakeFs().apply {
            file("src/a.txt", "needle")
            file("broken/b.txt", "needle")
            failingDirs += "broken"
        }

        val out = ok(grep(fs, "pattern" to "needle"))
        assertTrue(out.contains("src/a.txt:1:needle"))
        assertTrue(out.contains("读不了"), "列不出来的目录必须如实说明：$out")
    }

    @Test
    @DisplayName("空工作区：两个工具都是 0 命中 Success（不是 Failure）")
    fun emptyWorkspaceGivesZeroHitsNotFailure() {
        val fs = FakeFs()
        assertTrue(ok(find(fs, "pattern" to "*")).startsWith("0 命中"))
        val hits = ok(grep(fs, "pattern" to "."))
        assertTrue(hits.startsWith("0 命中"))
        assertTrue(hits.contains("已扫 0 个文本文件"), "必须报扫描规模：$hits")
    }

    // ============================================================== ④ 工具面

    @Test
    @DisplayName("★ 工具面钉住：名字 / 参数名 / 可空声明 / 描述里的关键事实")
    fun toolSurfaceIsPinned() {
        val findSpec = FindFilesTool(FakeFs()).spec
        assertEquals(
            "find_files",
            findSpec.name,
            "工具名是缓存前缀的一部分 —— 改名等于让所有会话的前缀失效",
        )
        assertEquals(listOf("pattern", "dir", "max_results"), findSpec.parameters.map { it.name })
        assertFalse(findSpec.parameters.first { it.name == "pattern" }.allowEmpty, "pattern 不许为空")
        assertTrue(findSpec.parameters.first { it.name == "dir" }.allowEmpty, "dir 必须允许空串（根目录）")
        assertTrue(
            findSpec.parameters.first { it.name == "dir" }.optional,
            "dir 必须 optional：缺键就走工作区根（否则云端 schema 会把它列进 required）",
        )
        assertTrue(
            findSpec.parameters.first { it.name == "max_results" }.allowEmpty,
            "max_results 必须允许空串（校验器把所有声明参数当必填键）",
        )
        assertTrue(
            findSpec.parameters.first { it.name == "max_results" }.optional,
            "max_results 必须 optional：缺键就走默认值",
        )
        assertFalse(
            findSpec.parameters.first { it.name == "pattern" }.optional,
            "pattern 是必填（缺了根本不知道找什么）",
        )
        listOf("不依赖 shell", ".git", "build", ".heracles", "node_modules", "截断").forEach {
            assertTrue(findSpec.description.contains(it), "find_files 描述必须说清「$it」：${findSpec.description}")
        }

        val grepSpec = GrepFilesTool(FakeFs()).spec
        assertEquals("grep_files", grepSpec.name)
        assertEquals(
            listOf("pattern", "dir", "max_results", "ignore_case"),
            grepSpec.parameters.map { it.name },
        )
        assertFalse(grepSpec.parameters.first { it.name == "pattern" }.allowEmpty, "pattern 不许为空")
        assertTrue(
            grepSpec.parameters.first { it.name == "ignore_case" }.allowEmpty,
            "ignore_case 必须允许空串（= 区分大小写）",
        )
        // grep 的三个可选参数都必须在缺键时走默认值（dir=根 / max_results=40 / 区分大小写）
        listOf("dir", "max_results", "ignore_case").forEach { name ->
            assertTrue(
                grepSpec.parameters.first { it.name == name }.optional,
                "$name 必须 optional：缺键就走默认值",
            )
        }
        assertFalse(
            grepSpec.parameters.first { it.name == "pattern" }.optional,
            "pattern 是必填（缺了根本不知道搜什么）",
        )
        listOf("不依赖 shell", "行号", "正则", "忽略", "截断").forEach {
            assertTrue(grepSpec.description.contains(it), "grep_files 描述必须说清「$it」：${grepSpec.description}")
        }
    }

    // ============================================================ ⑦ .gitignore（2026-10-19）

    @Test
    @DisplayName("★★ 根 .gitignore 的目录规则生效：find_files 不再扫进自定义产物目录")
    fun gitignoreSkipsIgnoredDirectory() {
        // ★ 用 dist/ 而不是 build/ —— build/ 在固定忽略名单里，测不到 .gitignore 这条路径
        val fs = FakeFs().apply {
            file(".gitignore", "dist/\n")
            file("dist/output.txt", "generated")
            file("src/Main.kt", "fun main() {}")
        }
        val out = ok(find(fs, "pattern" to "*.txt"))

        assertFalse(out.contains("dist/output.txt"), "被 .gitignore 忽略的目录不该出现在结果里：$out")
        assertTrue(out.contains(".gitignore"), "要如实说明有被 .gitignore 跳过的项（不静默）：$out")
    }

    @Test
    @DisplayName("★★ 根 .gitignore 的文件规则生效：grep_files 不搜 *.log")
    fun gitignoreSkipsIgnoredFile() {
        val fs = FakeFs().apply {
            file(".gitignore", "*.log\n")
            file("debug.log", "ERROR boom")
            file("src/Main.kt", "val x = 1")
        }
        val out = ok(grep(fs, "pattern" to "ERROR"))
        assertFalse(out.contains("debug.log"), "被忽略的文件不该被搜：$out")
    }

    @Test
    @DisplayName("★ 没有 .gitignore 时行为完全不变（零回退）")
    fun withoutGitignoreNothingIsSkipped() {
        // 固定忽略名单里本来就有 build/ —— 换成自定义目录验证"没有 .gitignore 不额外忽略"
        val fs = FakeFs().apply {
            file("generated/output.txt", "generated")
            file("src/Main.kt", "fun main() {}")
        }
        val out = ok(find(fs, "pattern" to "*.txt"))
        assertTrue(out.contains("generated/output.txt"), "没有 .gitignore 就不该额外忽略：$out")
    }
}
