package dev.heracles.agent.tools

import dev.heracles.agent.AgentLoop
import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.PathEscapeException
import dev.heracles.workspace.WorkspaceFs

/**
 * 写文件工具 —— 方案 B 的**第一个真实工具**。
 *
 * 工具描述刻意写得很具体（"什么时候用"而非"这是什么"），
 * 这是 `02-契约规范.md` §4.2 的要求 —— 4B 模型对小模型描述很敏感。
 */
class WriteFileTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "write_file",
        description = "把内容写入工作区里的一个文件。文件不存在时创建，存在时覆盖。用于生成或修改代码。",
        parameters = listOf(
            ToolParam("path", "string", "相对于工作区的文件路径，例如 src/App.kt"),
            ToolParam("content", "string", "要写入的完整文件内容"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val path = args["path"].orEmpty()
        val content = args["content"].orEmpty()
        if (path.isBlank()) return ToolOutcome.Failure("path 为空")
        return try {
            // ★ 写前读原文（2026-10-19）：回执要给**真实改了什么**，不是"写了 N 字节"。
            //   读不到（新建 / 权限）就当"原内容不存在"，不影响写入。
            val before = runCatching {
                if (fs.exists(path)) fs.readText(path) else null
            }.getOrNull()
            // ★ 写前快照（2026-10-19）：改错了要能退回来
            val snapshotted = before?.let { Checkpoints.save(fs, path, it) } ?: false
            val bytes = fs.writeText(path, content)
            val receipt = DiffReceipt.render(before, content)
            val snapNote = when {
                before == null -> ""
                snapshotted -> "（原内容已存快照，可用 restore_path 撤销）"
                else -> "（原文件超过快照上限，**未保存快照**）"
            }
            ToolOutcome.Success("已写入 $path（$bytes 字节）\n\n$receipt$snapNote")
        } catch (e: PathEscapeException) {
            // 路径防护触发 —— 必须作为**显式失败**回报给模型，让它换路径
            ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            ToolOutcome.Failure("写入失败：${e.message}")
        }
    }
}

/**
 * **写操作回执的 diff**（2026-10-19）。
 *
 * ## 为什么必须有
 *
 * 旧回执只有"已写入 N 字节" / "N 个修改块 / M 行改动" —— 模型**和用户都核对不了**：
 * 它说改好了，但"改的是什么"没有任何独立通道。会话又是 append-only ⇒
 * 一段错误的改动会永久留在上下文里。
 *
 * ## 为什么是"简化 diff"而不是完整 LCS
 *
 * 手机端 + append-only：回执要**短**（[Contract.Tools.RESULT_DIFF_MAX_LINES]），
 * 目的只是"让人/模型能核对这一处改动"，不是产出可应用的补丁。
 * 做法：砍掉公共前缀/后缀，中间整段标成 `-`/`+`（足够看清，且 O(n)）。
 */
internal object DiffReceipt {

    fun render(before: String?, after: String): String {
        val cap = Contract.Tools.RESULT_DIFF_MAX_LINES
        val b = after.split('\n')

        if (before == null) {
            if (b.size == 1 && b[0].isEmpty()) return "（新建空文件）"
            val shown = b.take(cap)
            return buildString {
                append("（新建文件，共 ${b.size} 行）\n")
                shown.forEach { append("+ ").append(it).append('\n') }
                if (b.size > cap) append("… 还有 ${b.size - cap} 行\n")
            }.trimEnd()
        }

        val a = before.split('\n')
        if (before == after) return "（内容未变化）"

        var prefix = 0
        while (prefix < a.size && prefix < b.size && a[prefix] == b[prefix]) prefix++
        var suffix = 0
        while (suffix < a.size - prefix && suffix < b.size - prefix &&
            a[a.size - 1 - suffix] == b[b.size - 1 - suffix]
        ) {
            suffix++
        }

        val removed = a.subList(prefix, a.size - suffix)
        val added = b.subList(prefix, b.size - suffix)

        val half = cap / 2
        return buildString {
            append("@@ 第 ${prefix + 1} 行 @@\n")
            removed.take(half).forEach { append("- ").append(it).append('\n') }
            if (removed.size > half) append("… 还删了 ${removed.size - half} 行\n")
            added.take(half).forEach { append("+ ").append(it).append('\n') }
            if (added.size > half) append("… 还加了 ${added.size - half} 行\n")
        }.trimEnd()
    }
}

/**
 * 读文件工具。
 *
 * ## 分段读取（2026-10-18，P1-4）
 *
 * 大文件整读会挤爆上下文（本地 4096 token）。`offset` / `limit` 让它按行分段：
 *
 * · 两个都为空（缺失或空串）⇒ **与加参数之前逐字节一致**（零回退，有测试钉住）
 * · 分段时返回的**第一行**是行号说明（读了第几行、共几行、还有多少行未读、
 *   下一次用哪个 `offset`）—— 模型据此接续读，**不会**把截断当成"文件就这么长"
 * · 覆盖全文的请求（`offset=1` + `limit` 够大）也**不加表头** ⇒ 与整读逐字节一致
 *
 * ## 为什么是"读全文再切行"，而不是按行流式读
 *
 * [WorkspaceFs] 只暴露整读的 [WorkspaceFs.readText]，而底层两种实现
 * （POSIX 与 App 的 SAF 存储）**契约都要求**：`> MAX_READ_BYTES`(1 MB) 直接抛错、
 * **不得截断**。要做到"只读 100 行、不碰其余字节"就必须给 `WorkspaceFs` 加一个
 * 分段/流式读的方法，两种后端都得实现 —— 那是 `:workspace` 的改动，不在本工具范围。
 * 于是这里：整读（**已被 1 MB 上限兜住**，不存在"10 MB 进内存"）+ 本地切行。
 * 将来 `:workspace` 提供分段读，这里换实现即可，**对外行为不变**。
 *
 * ⚠️ 不要图省事绕开 `fs` 去 `fs.info.rootPath.resolve(...)` 直接读文件：
 * SAF 后端没有真实路径（那只是 CWD 占位），而且那样会**跳过 `PathGuard` 越界防护**。
 */
class ReadFileTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "read_file",
        description = "读取工作区里一个文本文件的内容。在修改前先用它看清现有代码。大文件可用 offset/limit 分段读（两个都不给或都传空字符串 = 整读，与不分段完全一致）；一旦分段，返回的**第一行**是行号说明（读了第几行、共几行、还有多少行未读、用哪个 offset 继续），它不是文件内容。写 `apply_patch` 前建议传 numbered=true 拿到行号，否则只能猜 @@ 的起点。",
        parameters = listOf(
            ToolParam("path", "string", "相对于工作区的文件路径"),
            // ★ optional = true（2026-10-18，F7a）：缺键 = 整读（与空串同义），
            //   实现里 `args["offset"].orEmpty()` 已经把两者抹平 ⇒ 不该因缺键被校验器拦下。
            ToolParam(
                "offset", "string",
                "起始行号（1-based）。整读时可省略（或传空字符串）；只想读后半段时填，例如 120",
                allowEmpty = true,
                optional = true,
            ),
            ToolParam(
                "limit", "string",
                "最多读多少行。整读时可省略（或传空字符串）；只读一段时填，例如 80",
                allowEmpty = true,
                optional = true,
            ),
            ToolParam(
                "numbered", "string",
                "是否给每行加行号（cat -n 风格，如「     1\\t代码」）。默认 false（原样返回）。" +
                    "**写 apply_patch 前建议传 true**：补丁的 @@ 起点要行号，光看内容只能猜",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val path = args["path"].orEmpty()
        if (path.isBlank()) return ToolOutcome.Failure("path 为空")

        val offsetRaw = args["offset"].orEmpty().trim()
        val limitRaw = args["limit"].orEmpty().trim()
        // ★ 2026-10-19：行号是可选的 —— 默认**不改变**返回内容（零回退）。
        val numbered = args["numbered"].orEmpty().trim().lowercase() in
            setOf("true", "1", "yes", "y")

        // ★ 零回退：两个都没给（键缺失或空串）⇒ 与加参数之前**逐字节一致**（除非显式要行号）
        if (offsetRaw.isEmpty() && limitRaw.isEmpty() && !numbered) return readWhole(path)

        // offset 缺省 = 1（"只给 limit"是合法用法：从头读 N 行）；写了就必须是整数
        val offset = if (offsetRaw.isEmpty()) 1 else (
            offsetRaw.toIntOrNull()
                ?: return ToolOutcome.Failure("offset 必须是整数行号（1-based），收到「$offsetRaw」")
            )
        if (offset < 1) return ToolOutcome.Failure("offset 必须 ≥ 1（1-based 行号），收到 $offset")
        val limit = if (limitRaw.isEmpty()) null else (
            limitRaw.toIntOrNull()
                ?: return ToolOutcome.Failure("limit 必须是整数行数，收到「$limitRaw」")
            )
        if (limit != null && limit < 1) return ToolOutcome.Failure("limit 必须 ≥ 1（行数），收到 $limit")

        return try {
            val text = fs.readText(path)
            val lines = splitLines(text)
            val total = lines.size
            if (total == 0) return ToolOutcome.Failure("$path 是空文件（0 行），没有内容可读")
            if (offset > total) {
                return ToolOutcome.Failure("offset=$offset 超出文件行数（$path 共 $total 行）")
            }

            val from = offset - 1
            val remaining = total - from
            // 用比较代替 from + limit，避免 limit 极大时整数溢出
            val to = if (limit == null || limit >= remaining) total else from + limit
            val body = sliceLines(lines, text, from, to)

            if (numbered) {
                // 行号从**真实行号**起（分段时是 offset，不是 1）
                val numberedBody = numberLines(
                    lines.subList(from, to), from + 1,
                    hasNewlineAfter = to < total || text.endsWith("\n"),
                )
                if (from == 0 && to == total) return ToolOutcome.Success(numberedBody)
                val tail =
                    if (to < total) "；还有 ${total - to} 行未读，用 offset=${to + 1} 继续"
                    else "；已读到文件末尾"
                return ToolOutcome.Success("已读第 ${from + 1}–$to 行 / 共 $total 行$tail\n$numberedBody")
            }

            // 覆盖全文 ⇒ 不给表头（模型不用剥壳，且与整读逐字节一致）
            if (from == 0 && to == total) {
                ToolOutcome.Success(body)
            } else {
                val tail =
                    if (to < total) "；还有 ${total - to} 行未读，用 offset=${to + 1} 继续"
                    else "；已读到文件末尾"
                ToolOutcome.Success("已读第 ${from + 1}–$to 行 / 共 $total 行$tail\n$body")
            }
        } catch (e: PathEscapeException) {
            ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            ToolOutcome.Failure("读取失败：${e.message}")
        }
    }

    /** 原始行为（逐字节一致）—— 整读的唯一路径。 */
    private suspend fun readWhole(path: String): ToolOutcome = try {
        ToolOutcome.Success(fs.readText(path))
    } catch (e: PathEscapeException) {
        ToolOutcome.Failure("路径被拒绝：${e.reason}")
    } catch (e: Exception) {
        ToolOutcome.Failure("读取失败：${e.message}")
    }
}

/**
 * 按 `\n` 切行 —— **保留行尾的 `\r`**（取出的内容与原文逐字节一致，不会把 CRLF 悄悄改成 LF）。
 *
 * 末尾的换行符不算"多一行"：`a\nb\n` 是 **2** 行（`cat -n` 的直觉），
 * 空串是 **0** 行，`"\n"` 是 **1** 行（一个空行）。
 */
private fun splitLines(text: String): List<String> {
    if (text.isEmpty()) return emptyList()
    val parts = text.split("\n")
    return if (parts.last().isEmpty()) parts.dropLast(1) else parts
}

/**
 * 取 `[from, to)` 行，并**保住换行边界**：被选中区间的最后一行之后，原文若还有换行符
 * （后面还有行，或原文以 `\n` 结尾）就补回一个 `\n`。
 *
 * 这样"分段读 + 拼接 == 原文"（接续读到尾 = 整读），也保证覆盖全文时与整读逐字节一致。
 */
private fun sliceLines(lines: List<String>, original: String, from: Int, to: Int): String {
    if (to <= from) return ""
    val body = lines.subList(from, to).joinToString("\n")
    val hasNewlineAfter = to < lines.size || original.endsWith("\n")
    return if (hasNewlineAfter) "$body\n" else body
}

/**
 * `cat -n` 风格的行号前缀（2026-10-19）。
 *
 * ## 为什么要有
 *
 * `apply_patch` 的 `@@ -旧起点,旧行数 +新起点,新行数 @@` 需要**行号**；而整读默认
 * 返回的是纯内容 ⇒ 模型只能靠猜或先分段读一次拿表头（白烧一轮）。
 * 这是成熟智能体的常规做法（Claude Code 的 Read 就是 `cat -n` 风格）。
 *
 * ## 边界
 *
 * 只改**显示**，不改文件；行号从 [startLine] 起（分段时 = 实际行号，不是 1）；
 * 缩进用空格补齐（`%6d` 等宽），末尾换行与原片段一致。
 */
private fun numberLines(lines: List<String>, startLine: Int, hasNewlineAfter: Boolean): String {
    if (lines.isEmpty()) return ""
    val body = lines.mapIndexed { i, line ->
        (startLine + i).toString().padStart(6) + "\t" + line
    }.joinToString("\n")
    return if (hasNewlineAfter) "$body\n" else body
}

/** 列目录工具 —— 让模型先看清项目结构。 */
class ListFilesTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "list_files",
        description = "列出工作区某个目录下的文件与子目录。不确定项目结构时先用它。",
        parameters = listOf(
            // ★ allowEmpty = true（2026-10-14 真机 bug）：
            //   描述里明说"根目录传空字符串"，而校验器原先一刀切判
            //   "为空非法" → 模型照契约传 "" 反被拦 → 重试撞重复拦截
            //   → 放弃并谎称完成（文件根本没写）。契约与校验必须一致。
            //
            // ★ optional = true（2026-10-18，F7a）：列根目录是**只读且无副作用**的默认动作，
            //   而实现就是 `args["dir"].orEmpty()` ⇒ 缺键与传 "" 逐字节同义，不该拦。
            ToolParam(
                "dir", "string", "相对工作区的目录路径，可省略（或传空字符串）= 工作区根目录",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val dir = args["dir"].orEmpty()
        return try {
            val entries = fs.list(dir)
            if (entries.isEmpty()) {
                ToolOutcome.Success("（空目录）")
            } else {
                ToolOutcome.Success(entries.joinToString("\n") { it.render() })
            }
        } catch (e: PathEscapeException) {
            ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            ToolOutcome.Failure("列举失败：${e.message}")
        }
    }
}

/**
 * 建目录工具（2026-10-15 用户反馈「没有生成目录的工具」）。
 *
 * ## 什么场景需要它
 *
 * · 建立项目结构（如 `tests/`、`assets/`、`src/utils/`）——
 *   `write_file` 虽会自动建**父目录**，但建**空目录**做不到
 * · 模型显式表达组织意图（"我要一个放配置的目录"）
 *
 * ## 幂等语义
 *
 * 目录已存在时**静默成功** —— 与 shell 的 `mkdir -p` 一致。
 * 模型不需要先 exists 再 mkdir（省一轮），重复建也不报错。
 */
class MkdirTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "mkdir",
        description = "创建工作区里的一个目录（自动创建缺失的父目录，已存在则不报错）。用于建立项目结构，如 tests/、assets/。",
        parameters = listOf(
            ToolParam("dir", "string", "相对工作区的目录路径，例如 src/utils"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val dir = args["dir"].orEmpty()
        if (dir.isBlank()) return ToolOutcome.Failure("dir 为空")
        return try {
            fs.mkdirs(dir)
            ToolOutcome.Success("已创建目录 $dir")
        } catch (e: PathEscapeException) {
            ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            ToolOutcome.Failure("创建目录失败：${e.message}")
        }
    }
}

/**
 * **向用户提问的工具**（2026-10-16 用户需求「ask 功能」）。
 *
 * ## 什么场景需要它（抗幻觉的最后一道防线）
 *
 * 模型面对**信息不足**时的三种坏反应：
 * · 瞎猜（编一个需求细节）
 * · 放弃（"无法完成"）
 * · **谎称完成**（`实测-08`：模型谎称"已创建文件"，实际没写）
 *
 * 正确反应：**问用户**。`04-抗幻觉设计.md` 的精神 —— 不确定就问。
 *
 * ## 典型触发场景
 *
 * · 需求有歧义（"做个页面"—— 什么主题？）
 * · 缺关键决策（"用哪种数据库？"）
 * · 文件冲突（"这个文件已存在，覆盖还是另存？"）
 * · 多方案选择（"方案 A 简单，方案 B 性能好，选哪个？"）
 *
 * ## 执行语义：挂起等待
 *
 * `execute` 会**挂起**直到用户回答（UI 弹窗 → [AgentLoop.AskReplyQueue.reply]）
 * 或超时。回答作为**工具结果**返回给模型 —— 对模型来说这就是一次
 * 正常的工具调用，不需要特殊处理。
 *
 * @param replies 回答通道；[AgentLoop.AskReplyQueue.EMPTY] = 不可用
 *   （工具会立即返回失败 —— CLI/测试里模型不该调用它）
 */
class AskUserTool(private val replies: AgentLoop.AskReplyQueue) : AgentTool {

    override val spec = ToolSpec(
        name = "ask_user",
        description = "当你需要用户提供信息、做决策或确认方案时，向用户提问。用于：需求不明确、有多种做法需要用户选择、缺少关键信息无法继续。不要用它询问你已知答案的事情。",
        parameters = listOf(
            ToolParam(
                "question", "string",
                "要问用户的问题，写清楚上下文和选项（如有）。例如：这个文件已存在，要覆盖还是另存为新文件？",
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val question = args["question"].orEmpty()
        if (question.isBlank()) return ToolOutcome.Failure("question 为空")

        // 挂起等待用户回答（UI 弹窗 → reply()）
        val answer = replies.await()
            ?: return ToolOutcome.Failure(
                "用户暂时没有回答（等待超时）。请自行决定下一步：换个做法继续，或在 final 里说明你卡在哪里、需要用户提供什么。"
            )

        return ToolOutcome.Success("用户回答：$answer")
    }
}

/**
 * **记忆工具**（2026-10-16 用户需求「Agent记忆功能」）。
 *
 * ## 解决什么
 *
 * 跨会话的**知识记忆**：用户偏好、项目背景、踩过的坑。
 * 与会话历史（append-only 的短期上下文）不同 —— 记忆是
 * **主动提炼**的长期知识：
 *
 * | | 会话历史 | 记忆 |
 * |---|---|---|
 * | 生命周期 | 单次 run | 跨会话永久 |
 * | 内容 | 全部过程 | 提炼后的结论 |
 * | 进入上下文的方式 | 本身就是上下文 | 启动时注入 |
 *
 * ## 存储：工作区 `.heracles/memory.md`
 *
 * · **随工作区走**：换项目 = 换记忆（项目背景不该带到别的项目）
 * · **Markdown 人类可读可编辑**：用户能直接看/改（信任感）
 * · **追加式**：每条记忆一行，不覆盖已有的（教训：覆盖会丢）
 *
 * ## 注入
 *
 * `AgentBridge.buildPrompt` 启动时读入并拼进系统上下文 ——
 * 模型每次 run 都"记得"这个项目的偏好与坑。（见 AgentBridge。）
 *
 * ## 工具语义：append 而非 write
 *
 * 模型只管"记一条"，不管文件结构 —— 避免它重写文件时把
 * 已有记忆删掉（models 曾因为重写配置丢过 Key，同类风险）。
 */
class SaveMemoryTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "save_memory",
        description = "把值得跨会话记住的信息写入长期记忆（用户偏好、项目背景、踩过的坑）。例如：用户偏好深色主题、这个项目用 Kotlin 2.3、SAF 写文件名会被改写。不要存一次性的任务细节。",
        parameters = listOf(
            ToolParam("content", "string", "要记住的一条信息，一句话写清楚"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val content = args["content"].orEmpty().trim()
        if (content.isBlank()) return ToolOutcome.Failure("content 为空")

        // ★ 与会话存储同目录约定（SessionStore.DOT_DIR = ".heracles"）
        val memoryPath = ".heracles/memory.md"
        return try {
            // 已有记忆 → 追加（保留历史记忆）；无 → 新建（带标题头）
            val existing = if (fs.exists(memoryPath)) fs.readText(memoryPath) else ""
            val header = if (existing.isEmpty()) "# Agent 长期记忆\n\n" else ""
            val ts = java.time.LocalDate.now().toString()
            val entry = "- [$ts] $content\n"
            fs.writeText(memoryPath, existing + header + entry)
            ToolOutcome.Success("已记住：$content")
        } catch (e: PathEscapeException) {
            ToolOutcome.Failure("路径被拒绝：${e.reason}")
        } catch (e: Exception) {
            ToolOutcome.Failure("记忆写入失败：${e.message}")
        }
    }
}
