package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.MAX_READ_BYTES
import dev.heracles.workspace.PathEscapeException
import dev.heracles.workspace.WorkspaceFs
import java.util.regex.PatternSyntaxException

// ============================================================================
// 阈值
//
// ⚠️ 按 AGENTS.md 的纪律，阈值应当定义在 `core/contract/Contract.kt`。
// 本轮的文件范围被限定为**两个新文件**（禁止改 `Contract.kt`），所以先在这里
// 集中命名、逐条写明取值依据，避免把数字散落到逻辑里。待 Lead 授权后整体
// 平移到 `Contract.FsSearch`，本文件的逻辑不用动。
// ============================================================================

/**
 * 一次工具结果默认带多少行。
 *
 * ⚠️ **S1b 起它有自己的契约常量**（[Contract.FsSearch.DEFAULT_MAX_RESULTS] = 40）：
 * 此前它**直接复用** `Contract.Shell.LOG_EXCERPT_LINES`（当时 40），注释说"两者是同一个约束"；
 * 而 ADR-035 把日志摘录提到 200 ⇒ 复用会让"搜索默认 40 行"**悄悄变成 200**。
 * 成因（本地 4096 上下文）已经不存在 ⇒ **一个数的语义变了，不该连坐另一个**。
 * 值**保持 40**（零回退），绑定解开。理由与取舍见 `Contract.FsSearch` 的 KDoc。
 */
private const val DEFAULT_MAX_RESULTS: Int = Contract.FsSearch.DEFAULT_MAX_RESULTS

/**
 * 模型能要求的硬上限。
 *
 * 200 行是**上下文刹车**：会话是 append-only 的，一条超长工具结果会永远留在
 * 上下文里，之后每轮都付 prefill。真要更多时应当收窄 pattern / dir 再来一次。
 * （原先是本文件的私有字面量；S1b 连同上面的默认值一起搬进契约，消掉"契约外的魔法数字"。）
 */
private const val MAX_RESULTS_CAP: Int = Contract.FsSearch.MAX_RESULTS_CAP

/**
 * 递归深度上限（相对搜索起点）。
 *
 * Android 工程实测最深约 10 层（app/src/main/java/...），给 16 是 1.5 倍余量。
 * 它同时是**目录成环**的兜底：`WorkspaceFs.list` 不保证目录图一定是树 ——
 * 符号链接指回祖先时，只有深度上限能止住。
 */
private const val MAX_DEPTH: Int = 16

/**
 * 单次调用最多看多少个条目（文件 + 目录）。
 *
 * 2000 的依据：一个中型 Android 工程约 3–5 千个文件；而 App 侧 SAF 每次
 * list / read 都是一次 ContentResolver 调用（比 POSIX 慢一个量级）。
 * 到限就**如实说没扫完**，让模型收窄范围，而不是把一轮拖成分钟级。
 */
private const val MAX_VISITED: Int = 2_000

/** 单行命中内容的展示长度上限 —— minified 文件一行可达 100 KB，一条命中就能吃掉整个预算。 */
private const val MAX_LINE_CHARS: Int = 240

/** 跳过清单里最多列几个样例 —— 模型要的是"我漏了什么"，不是逐条明细。 */
private const val SKIPPED_SAMPLE: Int = 3

/**
 * 固定忽略的目录名（任意层级）。
 *
 * 为什么固定、不可配置：这些目录**不是用户的项目源码** ——
 * `.git` 是版本库、`build` / `out` 是构建产物、`.heracles` 是本项目自己的
 * 会话与日志、`node_modules` / `.gradle` / `.idea` 是依赖与 IDE 缓存。
 * 搜它们除了烧 token 什么也拿不到（想读其中某个文件仍可用 read_file 精确指定）。
 *
 * 显式把 dir 指到某个忽略目录上时**照搜**（见 [walkFiles] 的说明）——
 * 用户/模型明确要看的，不能悄悄跳过。
 */
private val IGNORED_DIRS = setOf(
    ".git", "build", ".heracles", "node_modules", ".gradle", ".idea", "out",
)

/**
 * 预判为二进制的扩展名 —— 读之前就跳过，省一次整读。
 *
 * 为什么不能只看 `FileEntry.sizeBytes`：SAF 的 `DocumentFile.length()` 在多数
 * provider 上返回 0（长度未知），大二进制不会被大小检查拦下。所以这里是第一道，
 * 后面还有两道兜底：sizeBytes 超限、读后检测 NUL。
 */
private val BINARY_EXTENSIONS = setOf(
    "apk", "aab", "jar", "dex", "class", "so", "a", "zip", "gz", "tar", "bz2",
    "xz", "7z", "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "ttf", "otf",
    "woff", "woff2", "mp3", "mp4", "webm", "wav", "ogg", "amr", "pdf", "jks",
    "keystore", "bin",
)

/**
 * **按名字找文件** —— `27-工具面诊断.md` P1-1。
 *
 * ## 为什么不能继续只靠 list_files
 *
 * "哪个文件定义了 Xxx"这种问题需要**全树按名筛**，而 list_files 一次只给一层。
 * 模型于是退化成 `run_shell_command("find ...")` —— 那条路在 SAF 工作区下有
 * "App 视角 vs shell 视角"的分裂，输出还会被 40 行摘录截断。
 *
 * 本工具纯走 [WorkspaceFs]（list 递归 + 不读内容）：**不需要 shell**，
 * SAF 工作区一样能用。这是它与 `grep_files` 分开成两个工具的原因 ——
 * 只找名字不该付出读文件内容的代价。
 *
 * ## pattern 语义（刻意只做三种通配）
 *
 * | 写法 | 含义 |
 * |---|---|
 * | `*` | 段内任意字符（不跨目录） |
 * | `?` | 段内单个字符 |
 * | `**` | 任意层目录 |
 *
 * 不含 `/` 的 pattern 按**文件名**匹配（任意深度，因此 `*.kt` 等价于
 * 任意目录层级的 `*.kt`）；含 `/` 的按**相对 dir 的路径**匹配。
 * 不支持 `[abc]` / `{a,b}` —— 那两种会当字面量处理（0 命中，而不是错配）；
 * 4B 模型不需要更多语法。
 *
 * 只返回**文件**；找目录请用 list_files。
 *
 * ## 所有结果都在输出里如实标注
 *
 * 截断（共 N 个、只显示前 M 个、还有多少未显示）、忽略目录、深度/扫描上限、
 * 跳过的文件 —— 全部写进结果。**静默截断比"没找到"更糟**：模型会把
 * "我看到的就是全部"当真，然后基于残缺结果下结论。
 */
class FindFilesTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "find_files",
        description = "按文件名或相对路径的通配查找工作区里的文件（只返回文件，不返回目录）。" +
            "* 匹配段内任意字符、? 匹配单个字符、** 匹配任意层目录；不含 / 的写法按文件名匹配、" +
            "任意深度（如 *.kt）。纯 Kotlin 走工作区文件系统，不依赖 shell，SAF 工作区同样可用。" +
            "固定忽略 ${ignoredRuleText()} 目录，最多递归 $MAX_DEPTH 层；" +
            "结果超过 max_results 会截断，并如实给出匹配总数。",
        parameters = listOf(
            ToolParam(
                "pattern", "string",
                "要匹配的通配，例如 *.kt、build.gradle*、src/?ain.kt、src/**",
            ),
            // ★ optional = true（2026-10-18，F7a）：缺键 = 走实现里的默认值。
            //   云端原生 function calling 会把它从 `required` 里去掉 —— 否则
            //   "可选参数"在 JSON Schema 上与必填没有区别，模型每次都得硬填。
            ToolParam(
                "dir", "string", "在哪个目录下搜索（相对工作区）；不传 = 工作区根（也可传空字符串）",
                allowEmpty = true,
                optional = true,
            ),
            ToolParam(
                "max_results", "string",
                "最多返回多少条，默认 $DEFAULT_MAX_RESULTS，最多 $MAX_RESULTS_CAP；不传 = 默认值（也可传空字符串）",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome = try {
        search(args)
    } catch (e: PathEscapeException) {
        // 越界是**拒绝**，不是"跳过" —— 静默跳过会让一次越界尝试从日志里消失
        ToolOutcome.Failure("路径被拒绝：${e.reason}")
    } catch (e: Exception) {
        // 工具内部绝不外抛：抛出去会打断整轮任务（AgentLoop 只把 Failure 交回模型）
        ToolOutcome.Failure("查找失败：${e.message}")
    }

    private suspend fun search(args: Map<String, String>): ToolOutcome {
        val pattern = args["pattern"].orEmpty().trim().replace('\\', '/')
        if (pattern.isBlank()) return ToolOutcome.Failure("pattern 为空")
        if (pattern.startsWith("/")) {
            return ToolOutcome.Failure("pattern 不能以 / 开头（路径都相对工作区）：$pattern")
        }
        if (pattern.split('/').any { it == ".." }) {
            return ToolOutcome.Failure("pattern 不能包含 ..（搜索只针对工作区内路径）：$pattern")
        }

        val dir = normalizeDir(args["dir"].orEmpty())
        val max = when (val parsed = parseMaxResults(args["max_results"].orEmpty())) {
            is MaxSpec.Bad -> return ToolOutcome.Failure(parsed.reason)
            is MaxSpec.Ok -> parsed
        }
        requireDirectory(fs, dir)?.let { return it }

        val matcher = globToRegex(pattern)
        val matchFullPath = pattern.contains('/')
        val stats = ScanStats()
        val matches = mutableListOf<String>()
        var totalMatches = 0

        walkFiles(fs, dir, stats) { entry ->
            val target = if (matchFullPath) {
                if (dir.isEmpty()) entry.relativePath else entry.relativePath.removePrefix("$dir/")
            } else {
                entry.relativePath.substringAfterLast('/')
            }
            if (matcher.matches(target)) {
                totalMatches++
                if (matches.size < max.value) matches.add(entry.relativePath)
            }
        }

        // 输出顺序必须确定 —— 顺序抖动会让同一状态产生不同 prompt（缓存前缀的前提）
        val sorted = matches.sorted()
        val scope = buildList {
            add("pattern=$pattern")
            add("dir=${dirLabel(dir)}")
            if (max.note.isNotEmpty()) add(max.note)
        }.joinToString("，")

        val text = buildString {
            when {
                totalMatches == 0 -> append("0 命中：没有文件匹配（$scope）")
                totalMatches > sorted.size ->
                    append("共 $totalMatches 个匹配，只显示前 ${sorted.size} 个（$scope）：\n")
                else -> append("找到 $totalMatches 个匹配的文件（$scope）：\n")
            }
            if (sorted.isNotEmpty()) append(sorted.joinToString("\n"))
            if (totalMatches > sorted.size) {
                append(
                    "\n（还有 ${totalMatches - sorted.size} 个未显示；" +
                        "加大 max_results 或收窄 pattern/dir 可看更多）"
                )
            }
            val notes = scanNotes(stats, zeroHits = totalMatches == 0)
            if (notes.isNotEmpty()) append("\n（$notes）")
        }
        return ToolOutcome.Success(text)
    }
}

/**
 * **按内容找代码** —— `27-工具面诊断.md` P1-1。
 *
 * ## 为什么必须有一个不依赖 shell 的 grep
 *
 * 现在模型搜内容只能 `run_shell_command("grep ...")`，两个坑：
 *
 * 1. shell 的 stdout 进上下文前被**摘录**（[Contract.Shell.LOG_EXCERPT_LINES] 行）——
 *    命中很多时模型**看不到全部**，还以为自己看全了；
 * 2. SAF 工作区里 shell 与 App **不是同一个视角**（权限/路径都不同），
 *    shell 里 grep 得到的结果可能根本不是 App 看到的那个目录。
 *
 * 本工具纯走 [WorkspaceFs]（list 递归 + readText + 进程内正则）：
 * 不依赖 shell，SAF 工作区一样能用，也不受 shell 摘录档位约束（有自己的预算，
 * 见 [DEFAULT_MAX_RESULTS]）。
 *
 * ## 结果格式与截断
 *
 * `相对路径:行号:行内容`，按路径与行号排序（确定顺序）。命中多时只显示前
 * max_results 处，并**如实给出**还有多少处未显示 —— 模型可以据此决定
 * "加大上限"还是"收窄范围"。
 *
 * ## 已知边界（如实声明）
 *
 * · 按行匹配，pattern **不跨行**（多行结构请分两次搜或用 read_file）
 * · 二进制判定 = 扩展名黑名单 + 读后 NUL 检测；SAF 后端把字节解成 UTF-8 之后
 *   二进制可能表现为替换字符而漏检（常见类型已被黑名单挡住）
 * · 单个文件超过 [MAX_READ_BYTES] 直接跳过（`WorkspaceFs.readText` 本来也会拒绝）
 */
class GrepFilesTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "grep_files",
        description = "在工作区文件内容里按正则搜索，返回「相对路径:行号:行内容」（按行匹配，pattern 不跨行）。" +
            "纯 Kotlin 走工作区文件系统，不依赖 shell，SAF 工作区同样可用。" +
            "固定忽略 ${ignoredRuleText()} 目录；二进制与超大文件会跳过并说明；单行超长会截断。" +
            "命中多时结果被截断，并如实给出未显示的命中数。",
        parameters = listOf(
            ToolParam(
                "pattern", "string",
                "要搜索的 Java 正则，例如 TODO|FIXME、fun\\s+\\w+、import .*kotlin",
            ),
            ToolParam(
                "dir", "string", "在哪个目录下搜索（相对工作区）；不传 = 工作区根（也可传空字符串）",
                allowEmpty = true,
                optional = true,
            ),
            ToolParam(
                "max_results", "string",
                "最多返回多少处命中，默认 $DEFAULT_MAX_RESULTS，最多 $MAX_RESULTS_CAP；不传 = 默认值（也可传空字符串）",
                allowEmpty = true,
                optional = true,
            ),
            ToolParam(
                "ignore_case", "string",
                "忽略大小写传 true；不传或空字符串 = 区分大小写",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome = try {
        grep(args)
    } catch (e: PathEscapeException) {
        ToolOutcome.Failure("路径被拒绝：${e.reason}")
    } catch (e: Exception) {
        ToolOutcome.Failure("搜索失败：${e.message}")
    }

    private suspend fun grep(args: Map<String, String>): ToolOutcome {
        val pattern = args["pattern"].orEmpty()
        if (pattern.isBlank()) return ToolOutcome.Failure("pattern 为空")

        val ignoreCase = when (val parsed = parseBool(args["ignore_case"].orEmpty(), "ignore_case")) {
            is BoolSpec.Bad -> return ToolOutcome.Failure(parsed.reason)
            is BoolSpec.Ok -> parsed.value
        }

        // 非法正则是**模型的输入错误**，必须变成可读 Failure —— 绝不能让
        // PatternSyntaxException 冒到 AgentLoop（那会打断整轮任务）
        val regex = try {
            if (ignoreCase) Regex(pattern, RegexOption.IGNORE_CASE) else Regex(pattern)
        } catch (e: PatternSyntaxException) {
            return ToolOutcome.Failure("正则非法（pattern=$pattern）：${e.description}")
        }

        val dir = normalizeDir(args["dir"].orEmpty())
        val max = when (val parsed = parseMaxResults(args["max_results"].orEmpty())) {
            is MaxSpec.Bad -> return ToolOutcome.Failure(parsed.reason)
            is MaxSpec.Ok -> parsed
        }
        requireDirectory(fs, dir)?.let { return it }

        val stats = ScanStats()
        val hits = mutableListOf<Hit>()
        val hitFiles = mutableSetOf<String>()
        var totalHits = 0

        walkFiles(fs, dir, stats) { entry ->
            val ext = entry.relativePath.substringAfterLast('/')
                .substringAfterLast('.', "")
                .lowercase()
            if (ext in BINARY_EXTENSIONS) {
                stats.skippedBinary += entry.relativePath
                return@walkFiles
            }
            if (entry.sizeBytes > MAX_READ_BYTES) {
                stats.skippedLarge += entry.relativePath
                return@walkFiles
            }

            val text = try {
                fs.readText(entry.relativePath)
            } catch (e: PathEscapeException) {
                throw e
            } catch (e: Exception) {
                // 单个文件读不了不该毁掉整次搜索 —— 但必须记下来并如实回报
                if (e.message?.contains("文件过大") == true) {
                    stats.skippedLarge += entry.relativePath
                } else {
                    stats.unreadable += entry.relativePath
                }
                return@walkFiles
            }
            if (text.indexOf('\u0000') >= 0) {
                // UTF-8 文本里不会有 NUL；出现即说明是二进制
                stats.skippedBinary += entry.relativePath
                return@walkFiles
            }
            stats.textFiles++

            val lines = text.split('\n')
            for (index in lines.indices) {
                val line = lines[index].removeSuffix("\r")
                if (!regex.containsMatchIn(line)) continue
                totalHits++
                hitFiles += entry.relativePath
                // 超过上限后**继续数**：截断提示里的"还有 N 处未显示"必须是真数
                if (hits.size >= max.value) continue
                val shown = if (line.length > MAX_LINE_CHARS) {
                    stats.longLinesTruncated++
                    line.take(MAX_LINE_CHARS) + "…"
                } else {
                    line
                }
                hits += Hit(entry.relativePath, index + 1, shown)
            }
        }

        // 同一状态必须产出同一段文本：按路径、行号排序（与遍历顺序无关）
        val sortedHits = hits.sortedWith(compareBy({ it.path }, { it.line }))
        val scope = buildList {
            add("pattern=$pattern")
            add("dir=${dirLabel(dir)}")
            if (ignoreCase) add("忽略大小写")
            add("已扫 ${stats.textFiles} 个文本文件")
            if (max.note.isNotEmpty()) add(max.note)
        }.joinToString("，")

        val text = buildString {
            when {
                totalHits == 0 -> append("0 命中：没有内容匹配（$scope）")
                totalHits > sortedHits.size ->
                    append(
                        "共命中 $totalHits 处（${hitFiles.size} 个文件），" +
                            "只显示前 ${sortedHits.size} 处（$scope）：\n"
                    )
                else -> append("命中 $totalHits 处，共 ${hitFiles.size} 个文件（$scope）：\n")
            }
            if (sortedHits.isNotEmpty()) {
                append(sortedHits.joinToString("\n") { "${it.path}:${it.line}:${it.text}" })
            }
            if (totalHits > sortedHits.size) {
                append(
                    "\n（还有 ${totalHits - sortedHits.size} 处未显示；" +
                        "加大 max_results 或收窄 pattern/dir 继续）"
                )
            }
            val notes = scanNotes(stats, zeroHits = totalHits == 0)
            if (notes.isNotEmpty()) append("\n（$notes）")
        }
        return ToolOutcome.Success(text)
    }
}

// ============================================================================
// 遍历
// ============================================================================

/** 一个命中点。`line` 是 1-based 行号（与编辑器一致）。 */
private data class Hit(val path: String, val line: Int, val text: String)

/** 一次搜索的扫描统计 —— 输出的"扫描说明"全部由它生成，不做二次猜测。 */
private class ScanStats {
    /** 看过的条目数（文件 + 目录） */
    var visited: Int = 0

    /** 命中扫描条目上限，提前停下 */
    var visitedLimitHit: Boolean = false

    /** 因固定规则跳过的目录数 */
    var ignoredDirs: Int = 0

    /** 因超过深度上限未进入的目录数 */
    var depthStops: Int = 0

    /** 真正读了内容的文本文件数（grep 用） */
    var textFiles: Int = 0

    /** 单行内容超长被截断的行数（grep 用） */
    var longLinesTruncated: Int = 0

    val skippedBinary = mutableListOf<String>()
    val skippedLarge = mutableListOf<String>()
    val unreadable = mutableListOf<String>()
}

/**
 * 遍历 [startDir] 下的所有文件，对每个文件回调一次。
 *
 * ## 为什么是显式队列而不是递归
 *
 * 目录深度**不受文件系统保证有界**（符号链接可以成环）。递归遇到环会
 * StackOverflowError —— 而"工具内部不许抛异常"这条纪律连 Error 也不能接
 * （catch Throwable 会把 OOM 一起吞掉）。用队列 + 深度上限，最坏情况也是
 * 有限步数停下来。
 *
 * ## 遍历顺序：广度优先
 *
 * 让"结果被 max_results 截断"时优先给**浅层**的文件 —— 那些更可能是用户
 * 真正要看的源码，而不是深处的产物。顺序确定（fs.list 自身已排序），
 * 所以同一工作区每次得到同一批结果。
 *
 * @param startDir 起点（`""` = 工作区根）。**它本身的目录名不受忽略规则影响** ——
 *   模型显式指定 search 一个被忽略的目录，就照搜；只有它的子目录按规则跳过。
 * @param onFile 每个**文件**条目回调一次；目录条目不回调。
 */
private suspend fun walkFiles(
    fs: WorkspaceFs,
    startDir: String,
    stats: ScanStats,
    onFile: suspend (FileEntry) -> Unit,
) {
    val queue = ArrayDeque<Pair<String, Int>>()
    queue.addLast(startDir to 0)

    while (queue.isNotEmpty()) {
        if (stats.visited >= MAX_VISITED) {
            stats.visitedLimitHit = true
            return
        }
        val (current, depth) = queue.removeFirst()

        val entries = try {
            fs.list(current)
        } catch (e: PathEscapeException) {
            // 越界不是"这个目录读不了" —— 是安全事件，必须让整次调用失败
            throw e
        } catch (e: Exception) {
            stats.unreadable += current.ifEmpty { "." }
            emptyList()
        }

        for (entry in entries) {
            // 后端返回的路径也必须守住 —— 不能假设 WorkspaceFs 的实现都守约
            // （真机上的 SAF 实现与 POSIX 实现是两套代码）
            if (isUnsafeEntryPath(entry.relativePath)) {
                throw PathEscapeException(entry.relativePath, "文件系统返回了越界路径")
            }
            if (stats.visited >= MAX_VISITED) {
                stats.visitedLimitHit = true
                return
            }
            stats.visited++

            if (entry.isDirectory) {
                val name = entry.relativePath.substringAfterLast('/')
                if (name in IGNORED_DIRS) {
                    stats.ignoredDirs++
                    continue
                }
                if (depth + 1 > MAX_DEPTH) {
                    stats.depthStops++
                    continue
                }
                queue.addLast(entry.relativePath to (depth + 1))
            } else {
                onFile(entry)
            }
        }
    }
}

// ============================================================================
// 参数与路径
// ============================================================================

private sealed interface MaxSpec {
    data class Ok(val value: Int, val note: String) : MaxSpec
    data class Bad(val reason: String) : MaxSpec
}

/**
 * 解析 `max_results`。
 *
 * 超过上限时**收敛并说明**（而不是失败）：模型要 500 条只是想"尽量多"，
 * 直接拒绝会逼它再猜一个能过的数，白费一轮。
 */
private fun parseMaxResults(raw: String): MaxSpec {
    val text = raw.trim()
    if (text.isEmpty()) return MaxSpec.Ok(DEFAULT_MAX_RESULTS, "")
    val value = text.toIntOrNull()
        ?: return MaxSpec.Bad("max_results 必须是整数，收到「$text」")
    if (value < 1) return MaxSpec.Bad("max_results 必须 ≥ 1，收到 $value")
    if (value > MAX_RESULTS_CAP) {
        return MaxSpec.Ok(MAX_RESULTS_CAP, "max_results 已从 $value 收敛到上限 $MAX_RESULTS_CAP")
    }
    return MaxSpec.Ok(value, "")
}

private sealed interface BoolSpec {
    data class Ok(val value: Boolean) : BoolSpec
    data class Bad(val reason: String) : BoolSpec
}

/** 解析布尔参数。只认几个明确写法，其余如实失败（不猜模型的意思）。 */
private fun parseBool(raw: String, name: String): BoolSpec = when (raw.trim().lowercase()) {
    "", "false", "0", "no", "n" -> BoolSpec.Ok(false)
    "true", "1", "yes", "y" -> BoolSpec.Ok(true)
    else -> BoolSpec.Bad("$name 只接受 true / false（或空字符串），收到「${raw.trim()}」")
}

/**
 * 规范化并校验 `dir`。返回工作区相对路径（`""` = 根）。
 *
 * 越界是**拒绝**（抛 [PathEscapeException]，由 execute 转成 Failure），
 * 不是静默当成空目录 —— 否则"有人在试探工作区外"这条信息就没了。
 */
private fun normalizeDir(raw: String): String {
    val dir = raw.trim().replace('\\', '/')
    if (dir.isEmpty() || dir == ".") return ""
    if (dir.startsWith("/")) throw PathEscapeException(raw, "dir 不能是绝对路径")
    if (dir.length >= 2 && dir[1] == ':' && dir[0].isLetter()) {
        throw PathEscapeException(raw, "dir 不能带盘符")
    }
    val segments = dir.split('/').filter { it.isNotEmpty() && it != "." }
    if (segments.any { it == ".." }) throw PathEscapeException(raw, "dir 不允许包含 ..")
    return segments.joinToString("/")
}

/**
 * `dir` 必须是**存在且是目录**。
 *
 * 为什么非查不可：`WorkspaceFs.list` 对不存在的路径返回空列表，
 * 而那会被工具当成"0 命中"—— 模型只会以为自己搜错了关键词，
 * 实际上是把目录名拼错了。这两种失败必须让模型分得清。
 */
private suspend fun requireDirectory(fs: WorkspaceFs, dir: String): ToolOutcome.Failure? {
    if (dir.isEmpty()) return null
    if (!fs.exists(dir)) return ToolOutcome.Failure("目录不存在：$dir")
    val parent = dir.substringBeforeLast('/', "")
    val entry = fs.list(parent).firstOrNull { it.relativePath == dir }
    return if (entry != null && !entry.isDirectory) {
        ToolOutcome.Failure("dir 是文件而不是目录：$dir（要读单个文件请用 read_file）")
    } else {
        null
    }
}

/**
 * 后端返回的条目路径是否安全。
 *
 * `WorkspaceFs` 的契约是"相对工作区、`/` 分隔"，但实现有两套
 * （POSIX / SAF），这里**不信任**任何一套：绝对路径、盘符、`..`
 * 一律当越界处理。这是纵深防御，不是重复劳动。
 */
private fun isUnsafeEntryPath(relativePath: String): Boolean {
    if (relativePath.isBlank()) return true
    if (relativePath.startsWith("/") || relativePath.startsWith("\\")) return true
    if (relativePath.length >= 2 && relativePath[1] == ':' && relativePath[0].isLetter()) return true
    return relativePath.split('/', '\\').any { it == ".." }
}

/**
 * glob → 正则。
 *
 * 只支持三种通配（见 [FindFilesTool] 的类注释）。`**` 后面紧跟 `/` 时表示
 * "任意层目录（含 0 层）"，所以 `**` + `/` + `*.kt` 也能匹配根目录下的 `*.kt`。
 *
 * 其余字符一律当字面量 —— 模型写 `a+b.kt` 时不该被解释成正则。
 */
private fun globToRegex(pattern: String): Regex {
    val regex = StringBuilder()
    var index = 0
    while (index < pattern.length) {
        when (val ch = pattern[index]) {
            '*' -> {
                val doubleStar = index + 1 < pattern.length && pattern[index + 1] == '*'
                if (doubleStar) {
                    index += 2
                    if (index < pattern.length && pattern[index] == '/') {
                        // `**` + `/` = 任意层目录（含直接命中）
                        regex.append("(?:.*/)?")
                        index += 1
                    } else {
                        regex.append(".*")
                    }
                    continue
                }
                regex.append("[^/]*")
            }
            '?' -> regex.append("[^/]")
            else -> regex.append(Regex.escape(ch.toString()))
        }
        index += 1
    }
    return Regex(regex.toString())
}

private fun dirLabel(dir: String): String = if (dir.isEmpty()) "工作区根" else dir

/** 给模型看的忽略规则（与 [IGNORED_DIRS] 同源，不手写第二份）。 */
private fun ignoredRuleText(): String = IGNORED_DIRS.joinToString("/")

/**
 * 输出的"扫描说明" —— 让模型知道自己**没看到什么**。
 *
 * 只在有东西被跳过时出现（除了 `visited` 计数）：
 * 没有隐藏任何东西时不必占 token；一旦有跳过/截断，就必须说清楚。
 */
private fun scanNotes(stats: ScanStats, zeroHits: Boolean): String {
    val parts = mutableListOf<String>()
    parts += "扫描 ${stats.visited} 个条目"
    if (stats.ignoredDirs > 0) {
        parts += "跳过 ${stats.ignoredDirs} 个固定忽略目录（${ignoredRuleText()}）"
    } else if (zeroHits) {
        // 0 命中时**必须**说明搜索范围：否则模型分不清"真没有"还是"没找对地方"
        parts += "已忽略目录：${ignoredRuleText()}"
    }
    if (stats.depthStops > 0) parts += "有 ${stats.depthStops} 个目录超过 $MAX_DEPTH 层未进入"
    if (stats.visitedLimitHit) {
        parts += "到 $MAX_VISITED 个条目上限即停，结果可能不完整（建议收窄 dir）"
    }
    if (stats.skippedBinary.isNotEmpty()) {
        parts += "跳过 ${stats.skippedBinary.size} 个二进制文件（${sample(stats.skippedBinary)}）"
    }
    if (stats.skippedLarge.isNotEmpty()) {
        parts += "跳过 ${stats.skippedLarge.size} 个超大文件（${sample(stats.skippedLarge)}）"
    }
    if (stats.unreadable.isNotEmpty()) {
        parts += "${stats.unreadable.size} 个文件或目录读不了（${sample(stats.unreadable)}）"
    }
    if (stats.longLinesTruncated > 0) {
        parts += "${stats.longLinesTruncated} 行超过 $MAX_LINE_CHARS 字符已截断"
    }
    return parts.joinToString("；")
}

/** 跳过清单只列前几个样例，后面的用"等"收口。 */
private fun sample(paths: List<String>): String {
    val head = paths.take(SKIPPED_SAMPLE).joinToString("、")
    return if (paths.size > SKIPPED_SAMPLE) "$head 等" else head
}
