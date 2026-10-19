package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.ToolGroup
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.MAX_BINARY_BYTES
import dev.heracles.workspace.PathEscapeException
import dev.heracles.workspace.WorkspaceFs

/**
 * **文件操作三件套**（P1-3，2026-10-18）：`delete_path` / `move_path` / `copy_path`。
 *
 * ## 为什么不是"三个壳子"
 *
 * `WorkspaceFs` 原本没有删除能力 —— 本轮在 `:workspace` 补了 `delete`（POSIX 走 `Files.delete`，
 * SAF 走 `DocumentFile.delete` 并**只删文件**），三个工具再在它上面实现递归语义。
 *
 * ## 安全语义（先定，代码照此写）
 *
 * | 规则 | 理由 |
 * |---|---|
 * | 路径只允许工作区内相对路径（禁 `..` / 绝对 / 空 / 根目录） | 与 `FsSearchTools` 同款判据；越界删除不可逆 |
 * | 删除**非空目录必须显式 `recursive=true`** | 默认 `false` 时"删错一层"最多报错，不会毁树 |
 * | **递归删除 = 先整树预扫描再动手** | 不可逆操作不能删到一半才发现超限（`Contract.FsOps` 两道闸） |
 * | 目标已存在 ⇒ **失败不覆盖** | 与 F6b 回写同一条纪律：用户文件覆盖不可逆 |
 * | 目标父目录不存在 ⇒ **失败，不创建** | 自动建会把"路径打错一层"变成"在别处静默建目录+文件"（同族不可逆风险） |
 * | `move` = 复制 + 删源（**非原子**） | 真机上 SAF 没有可靠的跨目录 rename；不假装原子。失败文案必须说清"两份都在" |
 * | SAF（`hasRealPath=false`）**目录删除/移动明确拒绝** | `DocumentFile.delete()` 对目录是**递归**的 ⇒ 放开"删空目录"等于放开"删整棵"；文件三操作可用 |
 *
 * ## 分组与分区
 *
 * 三个都登记为 [ToolGroup.FILE]；**S1b 起全员都拿得到**（在长尾里，`search_tools` 披露后可用）。
 *
 * ⚠️ 加它们的时候（P1-3，2026-10-18）三者**只进云端长尾**
 * （`ToolZonePlan.CLOUD_ONLY_LONG_TAIL`，已随 ADR-035 S1b 删除）：当时本地长尾 11/12
 * 没有三格余量，且本地有常驻 `run_shell_command` 可做同样的事。
 * 本地后端退场 + 长尾上限 24 ⇒ 那条取舍**没有存在理由了**，现在长尾 11/24 有余量。
 */
object PathTools {

    /** 建全部文件操作工具（`AgentBridge` 装配用）。 */
    fun create(fs: WorkspaceFs): List<AgentTool> = listOf(
        DeletePathTool(fs),
        MovePathTool(fs),
        CopyPathTool(fs),
        // ★ 2026-10-19：写/删前快照的**恢复入口**（长尾；`search_tools` 披露后可用）。
        RestorePathTool(fs),
    )

    /**
     * 分组表 —— 供 [dev.heracles.core.tool.ToolRegistry] 把同义说法纳入检索面。
     *
     * 三个都归 [ToolGroup.FILE]（"文件 / 目录"那一组）。漏登记 ⇒ 搜"删除/移动/复制"搜不到
     * ⇒ 模型只能编"我做不到"，**没有任何报错**（静默退化）。
     */
    val GROUPS: Map<String, ToolGroup> = mapOf(
        "delete_path" to ToolGroup.FILE,
        "move_path" to ToolGroup.FILE,
        "copy_path" to ToolGroup.FILE,
        "restore_path" to ToolGroup.FILE,
    )

    /** 启动期断言：名字不重复 + 分组覆盖（与 `AndroidTools.assertConsistent` 同一条纪律）。 */
    fun assertConsistent(tools: List<AgentTool>) {
        val names = tools.map { it.spec.name }
        require(names.size == names.toSet().size) { "文件操作工具名重复：$names" }
        val ungrouped = names.filterNot { it in GROUPS }
        require(ungrouped.isEmpty()) {
            "这些文件操作工具没有登记分组，检索会静默失灵：$ungrouped（请补进 PathTools.GROUPS）"
        }
    }
}

// ======================================================================== 快照

/**
 * **写前快照**（checkpoint，2026-10-19）—— 让"改错了"有后悔药。
 *
 * ## 语义（刻意简单）
 *
 * 只保留**每个文件最近一次**被改动前的内容：`.heracles/checkpoints/latest/<原路径>`。
 * 语义 = "撤销刚才那一下"，不是版本历史（手机上做完整版本库要 git，ADR-034 仍 `Proposed`）。
 *
 * ## 边界
 *
 * - 单文件超过 [Contract.FsOps.CHECKPOINT_MAX_BYTES] ⇒ **不保存**（回执会说明，不静默）
 * - 快照失败**不影响主操作**（写文件不能因为备份失败而失败）—— 但回执要说清
 * - 目录不保存（删目录仍不可撤销；回执里已明说）
 */
internal object Checkpoints {

    private fun backupRel(path: String): String = "${Contract.FsOps.CHECKPOINT_DIR}/$path"

    /** @return `true` = 已保存；`false` = 太大/失败（调用方据此在回执里说明） */
    suspend fun save(fs: WorkspaceFs, path: String, content: String): Boolean {
        if (content.toByteArray().size > Contract.FsOps.CHECKPOINT_MAX_BYTES) return false
        return try {
            val dir = backupRel(path).substringBeforeLast('/', "")
            if (dir.isNotEmpty()) fs.mkdirs(dir)
            fs.writeText(backupRel(path), content)
            true
        } catch (_: Exception) {
            false
        }
    }

    suspend fun exists(fs: WorkspaceFs, path: String): Boolean =
        runCatching { fs.exists(backupRel(path)) }.getOrDefault(false)

    suspend fun load(fs: WorkspaceFs, path: String): String? =
        runCatching { if (exists(fs, path)) fs.readText(backupRel(path)) else null }.getOrNull()

    suspend fun restore(fs: WorkspaceFs, path: String): Long? =
        load(fs, path)?.let { content -> runCatching { fs.writeText(path, content) }.getOrNull() }
}

// ======================================================================== 工具

/** 删文件 / 删空目录 / （显式递归）删整棵。 */
class DeletePathTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "delete_path",
        description = "删除工作区里的一个文件或目录。默认只允许删**空目录**；删非空目录必须显式传 " +
            "recursive=true —— 那会**整棵删除且不可撤销**（没有回收站、没有撤销）。" +
            "SAF 工作区（content:// 授权）不支持删目录（DocumentFile 删目录是递归的，出于安全没有放开），" +
            "文件可以删。要保留可恢复性，请先 copy_path 备份。",
        parameters = listOf(
            ToolParam("path", "string", "要删除的文件或目录（相对工作区），例如 tmp/old.log"),
            ToolParam(
                "recursive", "string",
                "是否递归删除非空目录：true / false（默认 false）。为 true 时**整棵删除、不可撤销**。",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome = guard("删除") {
        val path = normalizePath(args["path"].orEmpty(), "path")
        val recursive = parseBool(args["recursive"], "recursive")
        val entry = entryOf(fs, path) ?: return@guard ToolOutcome.Failure("$path 不存在（或父目录不可读）")

        if (!entry.isDirectory) {
            // ★ 删文件前留快照（2026-10-19）：删除曾是最不可逆的一步。
            val before = runCatching { fs.readText(path) }.getOrNull()
            val saved = if (before != null) Checkpoints.save(fs, path, before) else false
            val deleted = fs.delete(path)
            return@guard if (deleted) {
                ToolOutcome.Success(
                    "已删除文件：$path" +
                        if (saved) "（删前内容已存快照，可用 restore_path 撤销）"
                        else "（**未保存快照**：文件过大或快照失败，不可撤销）",
                )
            } else {
                ToolOutcome.Failure("删除失败：$path（可能已被删除、或权限不足）")
            }
        }

        // ---- 目录 ----
        if (!fs.info.hasRealPath) return@guard ToolOutcome.Failure(safNoDirDelete(path))
        val children = childrenOf(fs, path)
        if (children.isNotEmpty() && !recursive) {
            return@guard ToolOutcome.Failure(
                "目录非空（${children.size} 项）：$path —— 若要整棵删除，请显式传 recursive=true" +
                    "（**不可撤销**：没有回收站，删了就没了）。若只想删其中文件：先 list_files 看清再逐个删。",
            )
        }
        if (recursive) {
            // ★ 先在**动手之前**把整棵树扫一遍（成本闸见 Contract.FsOps）
            preScan(fs, path)
            val deleted = deleteTree(fs, path)
            return@guard ToolOutcome.Success("已递归删除目录：$path（共 $deleted 项，不可撤销）")
        }
        // 空目录
        val deleted = fs.delete(path)
        return@guard if (deleted) {
            ToolOutcome.Success("已删除空目录：$path")
        } else {
            ToolOutcome.Failure("删除目录失败：$path（SAF 不支持删目录 / 权限不足）")
        }
    }
}

/** 移动 / 重命名（复制 + 删源，**非原子**）。 */
class MovePathTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "move_path",
        description = "移动或重命名工作区里的文件/目录（from → to）。**目标已存在会失败（不覆盖）**；" +
            "目标父目录必须已存在（不会自动创建）。实现是**先复制再删源（非原子）**：" +
            "若复制成功但删源失败，会如实告诉你「两份都在」。SAF 工作区不能移动目录（需删源目录），文件可以。",
        parameters = listOf(
            ToolParam("from", "string", "源路径（相对工作区），例如 src/old.kt"),
            ToolParam("to", "string", "目标路径（相对工作区），例如 src/new.kt"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome = guard("移动") {
        val from = normalizePath(args["from"].orEmpty(), "from")
        val to = normalizePath(args["to"].orEmpty(), "to")
        if (from == to) return@guard ToolOutcome.Failure("from 与 to 相同：$from（没有要移动的东西）")

        val src = entryOf(fs, from) ?: return@guard ToolOutcome.Failure("源路径不存在：$from")
        requireTargetFree(fs, to)?.let { return@guard it }
        requireParentExists(fs, to)?.let { return@guard it }
        if (src.isDirectory && to.startsWith("$from/")) {
            return@guard ToolOutcome.Failure(
                "不能把目录移动到它自己的子目录里：$from → $to（会把数据弄丢）",
            )
        }
        if (src.isDirectory && !fs.info.hasRealPath) {
            return@guard ToolOutcome.Failure(
                "SAF 工作区不支持移动目录（移动 = 复制 + 删源，而 SAF 不能删目录）。" +
                    "文件可以移动；目录请手动：先用 copy_path 复制，再逐个删源文件。",
            )
        }
        if (src.isDirectory) preScan(fs, from)

        // ★ 移动文件前留快照（2026-10-19）—— 移动后原路径消失，restore 能把它写回来
        val movedSnapshot = if (!src.isDirectory) {
            runCatching { fs.readText(from) }.getOrNull()
                ?.let { Checkpoints.save(fs, from, it) } ?: false
        } else {
            false
        }

        // ① 复制（失败时源目录**一个字节都没动**）
        val copied = try {
            copyTree(fs, src, to)
        } catch (e: Exception) {
            return@guard ToolOutcome.Failure(
                "移动的**复制阶段**失败：${e.describe()}\n源没有被删除：$from（目标可能留有半成品：$to）",
            )
        }

        // ② 删源（失败 ⇒ 两份都在，必须说清哪份是新的）
        return@guard try {
            val removed = deleteTree(fs, from)
            ToolOutcome.Success(
                "已移动：$from → $to（复制 $copied 项、删除源 $removed 项；**非原子**操作已完成）" +
                    if (movedSnapshot) "（原内容已存快照，可用 restore_path 恢复到 $from）" else "",
            )
        } catch (e: Exception) {
            ToolOutcome.Failure(
                "目标已就位：$to（复制了 $copied 项），但**源未删除**：$from\n" +
                    "原因：${e.describe()}\n" +
                    "现在**两份都在**：$to 是刚复制的新副本，$from 是原位置。请确认后手动删除源，别直接假设哪份是最新。",
            )
        }
    }
}

/** 复制文件 / 目录（递归）。 */
class CopyPathTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "copy_path",
        description = "复制工作区里的文件或目录（from → to，目录递归）。**目标已存在会失败（不覆盖）**；" +
            "目标父目录必须已存在（不会自动创建）。单个文件走字节通道（上限 " +
            "${Contract.FsOps.MAX_RECURSIVE_ENTRIES} 项 / 单文件 ${MAX_BINARY_BYTES / (1024 * 1024)}MB），不截断。",
        parameters = listOf(
            ToolParam("from", "string", "源路径（相对工作区），例如 app/app-debug.apk"),
            ToolParam("to", "string", "目标路径（相对工作区），例如 backup/app-debug.apk"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome = guard("复制") {
        val from = normalizePath(args["from"].orEmpty(), "from")
        val to = normalizePath(args["to"].orEmpty(), "to")
        if (from == to) return@guard ToolOutcome.Failure("from 与 to 相同：$from（没有要复制的东西）")

        val src = entryOf(fs, from) ?: return@guard ToolOutcome.Failure("源路径不存在：$from")
        requireTargetFree(fs, to)?.let { return@guard it }
        requireParentExists(fs, to)?.let { return@guard it }
        if (src.isDirectory && to.startsWith("$from/")) {
            return@guard ToolOutcome.Failure(
                "不能把目录复制到它自己的子目录里：$from → $to（会无限递归）",
            )
        }
        if (src.isDirectory) preScan(fs, from)

        return@guard try {
            val copied = copyTree(fs, src, to)
            ToolOutcome.Success("已复制：$from → $to（$copied 项）")
        } catch (e: Exception) {
            // 目标目录是本次新建的（前面已确认不存在）⇒ 尽力清理半成品；清不掉就如实说
            val cleaned = try {
                deleteTree(fs, to)
                true
            } catch (_: Exception) {
                false
            }
            ToolOutcome.Failure(
                "复制失败：${e.describe()}\n" +
                    if (cleaned) {
                        "已清理目标处的半成品：$to（源未动）"
                    } else {
                        "目标处可能留有半成品：$to（清理失败：SAF 不能删目录？）—— 请自行检查"
                    },
            )
        }
    }
}

// ★ 2026-10-19：撤销入口 —— 把 `.heracles/checkpoints/latest/<path>` 写回原路径
class RestorePathTool(private val fs: WorkspaceFs) : AgentTool {

    override val spec = ToolSpec(
        name = "restore_path",
        description = "撤销上一次对某个文件的修改：把写/删/移动**之前**保存的快照写回原路径。" +
            "`write_file` / `apply_patch` / `delete_path` / `move_path` 都会在动手前保存最近一次快照；" +
            "本工具恢复它。**只能撤销最近一次**（没有版本历史）；目录不能恢复。",
        parameters = listOf(
            ToolParam("path", "string", "要恢复的文件路径（相对工作区），例如 src/App.kt"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome = guard("恢复") {
        val path = normalizePath(args["path"].orEmpty(), "path")
        val content = Checkpoints.load(fs, path)
            ?: return@guard ToolOutcome.Failure(
                "没有 $path 的快照（可能从未改过、文件超过快照上限、或快照失败）" +
                    "—— 无法恢复，请如实告诉用户",
            )
        val bytes = try {
            fs.writeText(path, content)
        } catch (e: Exception) {
            return@guard ToolOutcome.Failure("恢复失败：${e.describe()}")
        }
        ToolOutcome.Success("已恢复 $path（写回 ${bytes} 字节的最近快照）")
    }
}

// ======================================================================== 共用逻辑

/**
 * 统一收口：三个工具都**不许抛** —— 越界、IO、参数错全部转成可解释的 `Failure`。
 */
private suspend fun guard(action: String, block: suspend () -> ToolOutcome): ToolOutcome = try {
    block()
} catch (e: PathEscapeException) {
    ToolOutcome.Failure("路径被拒绝：${e.reason}")
} catch (e: BadInput) {
    ToolOutcome.Failure(e.message ?: "参数不合法")
} catch (e: Exception) {
    ToolOutcome.Failure("${action}失败：${e.describe()}")
}

/** 参数/语义错误（转成 Failure，不走异常栈给人看）。 */
private class BadInput(message: String) : Exception(message)

private fun Throwable.describe(): String = when (this) {
    is BadInput -> message ?: "参数不合法"
    is java.nio.file.DirectoryNotEmptyException -> "目录非空（递归删除只能由工具层逐层进行）"
    is java.nio.file.NoSuchFileException -> "路径不存在"
    is java.nio.file.AccessDeniedException -> "没有权限"
    else -> message ?: this::class.simpleName ?: "未知错误"
}

/**
 * 归一化并校验一个工作区内相对路径（与 `FsSearchTools` 同款判据）。
 *
 * 拒绝：空 / 绝对路径 / 盘符 / `..` / 归一化后等于根目录。
 * 容许：`./a/b`、`a//b`、结尾 `/`（都会被规范化掉）。
 */
private fun normalizePath(raw: String, what: String): String {
    val s = raw.trim().replace('\\', '/')
    if (s.isEmpty()) throw BadInput("$what 不能为空（空路径 = 工作区根目录，不允许对根做删除/移动/复制）")
    if (s.startsWith("/")) throw BadInput("$what 不能是绝对路径：$raw（只允许工作区内相对路径）")
    if (Regex("^[A-Za-z]:").containsMatchIn(s)) {
        throw BadInput("$what 不能带盘符：$raw（只允许工作区内相对路径）")
    }
    val segments = s.split('/').filter { it.isNotEmpty() && it != "." }
    if (segments.any { it == ".." }) {
        throw BadInput("$what 不能包含 ..（操作只针对工作区内路径）：$raw")
    }
    val joined = segments.joinToString("/")
    if (joined.isEmpty()) throw BadInput("$what 不能是工作区根目录")
    return joined
}

/** 解析布尔参数：缺键/空串 = false；只接受 true/false（不猜别的写法）。 */
private fun parseBool(raw: String?, what: String): Boolean {
    val v = raw.orEmpty().trim().lowercase()
    return when (v) {
        "", "false" -> false
        "true" -> true
        else -> throw BadInput("$what 只接受 true / false，收到「${raw.orEmpty()}」")
    }
}

/**
 * 在**父目录列表**里找目标条目 —— 不额外假设 `list(file)` 的行为。
 *
 * 为什么不用"试着 list 一下，成功就是目录"：SAF 的 `resolve(file).listFiles()` 返回**空列表**，
 * 文件会被误判成空目录；POSIX 则抛 `NotDirectoryException`。两种实现行为不一致 ⇒ 不可依赖。
 */
private suspend fun entryOf(fs: WorkspaceFs, path: String): FileEntry? {
    if (path.isEmpty()) return null
    val parent = path.substringBeforeLast('/', "")
    return fs.list(parent).firstOrNull { it.relativePath == path }
}

/** 列子项（已按路径排序 —— 递归顺序确定 ⇒ 失败位置可复现）。 */
private suspend fun childrenOf(fs: WorkspaceFs, dir: String): List<FileEntry> =
    fs.list(dir).filter { it.relativePath != dir }.sortedBy { it.relativePath }

/**
 * **预扫描**：递归数一遍条目，超 [Contract.FsOps] 的闸就**在动手前**拒绝。
 *
 * 这是不可逆操作的底线：删到一半才发现超限，用户的项目已经少了一半。
 */
private suspend fun preScan(fs: WorkspaceFs, dir: String) {
    var count = 0
    suspend fun walk(path: String, depth: Int) {
        if (depth > Contract.FsOps.MAX_RECURSIVE_DEPTH) {
            throw BadInput(
                "目录层级超过 ${Contract.FsOps.MAX_RECURSIVE_DEPTH} 层（在 $path）—— 目录异常深或成环，" +
                    "拒绝递归操作（没有动任何文件）",
            )
        }
        for (child in childrenOf(fs, path)) {
            count++
            if (count > Contract.FsOps.MAX_RECURSIVE_ENTRIES) {
                throw BadInput(
                    "目录太大：已超过 ${Contract.FsOps.MAX_RECURSIVE_ENTRIES} 项（预扫描阶段就停止，**没有动任何文件**）—— " +
                        "请缩小范围，或先用 list_files 看清结构",
                )
            }
            if (child.isDirectory) walk(child.relativePath, depth + 1)
        }
    }
    walk(dir, 1)
}

/**
 * 递归复制。返回复制条目数（文件 + 目录）。
 *
 * 文件走**字节通道**（`readBytes` / `writeBytes`）：二进制安全，但受 64MB 单文件上限约束、
 * **不截断**。目录先 `mkdirs` 再逐个复制子项。
 */
private suspend fun copyTree(fs: WorkspaceFs, src: FileEntry, dst: String): Int {
    if (!src.isDirectory) {
        val bytes = fs.readBytes(src.relativePath)
        fs.writeBytes(dst, bytes)
        return 1
    }
    fs.mkdirs(dst)
    var n = 1
    for (child in childrenOf(fs, src.relativePath)) {
        val childName = child.relativePath.substringAfterLast('/')
        n += copyTree(fs, child, "$dst/$childName")
    }
    return n
}

/**
 * 递归删除。返回删除条目数（文件 + 目录）。
 *
 * **调用前必须已 `preScan`**（成本闸）；这里只按"先子后父"删，遇 IO 失败直接抛
 * （由上层如实报告"删到哪一步"）。
 */
private suspend fun deleteTree(fs: WorkspaceFs, path: String): Int {
    val entry = entryOf(fs, path) ?: return 0
    if (!entry.isDirectory) {
        if (!fs.delete(path)) throw BadInput("删除失败：$path（权限不足或已被删除）")
        return 1
    }
    var n = 1
    for (child in childrenOf(fs, path)) {
        n += deleteTree(fs, child.relativePath)
    }
    if (!fs.delete(path)) throw BadInput("删除目录失败：$path（SAF 不支持删目录 / 权限不足）")
    return n
}

/** 目标已存在 ⇒ 失败（不覆盖）。 */
private suspend fun requireTargetFree(fs: WorkspaceFs, to: String): ToolOutcome.Failure? =
    if (fs.exists(to)) {
        ToolOutcome.Failure(
            "目标已存在：$to —— **不覆盖**（覆盖用户文件不可逆）。请换一个目标名，或先确认/删除它。",
        )
    } else {
        null
    }

/**
 * 目标父目录必须已存在 ⇒ 失败（**不自动创建**）。
 *
 * 理由：`cp`/`mv` 的 POSIX 语义要求父目录存在；自动创建会把"路径打错一层"
 * 变成"在别处静默建了目录 + 文件"，与"不覆盖"同族的不可逆风险。
 */
private suspend fun requireParentExists(fs: WorkspaceFs, to: String): ToolOutcome.Failure? {
    val parent = to.substringBeforeLast('/', "")
    if (parent.isEmpty()) return null
    return if (!fs.exists(parent)) {
        ToolOutcome.Failure(
            "目标父目录不存在：$parent —— 不会自动创建。请先 mkdir 建好父目录，再重试（避免路径写错时在别处建出目录）。",
        )
    } else {
        null
    }
}

/**
 * SAF 下"不能删目录"的**可执行文案**（P1-3 方案 §4）。
 *
 * 为什么不是"静默跳过"：SAF 的 `AndroidSafStorage.delete` 只删文件，
 * 目录一律返回 false —— 若工具不解释，用户只会看到"删除失败"，然后反复重试。
 * 文案要同时给"为什么"（DocumentFile 删目录是递归的）与"怎么办"（文件可以删 / 换应用工作区）。
 */
private fun safNoDirDelete(path: String): String =
    "SAF 工作区（content:// 授权）不支持删除目录：$path —— " +
        "DocumentFile.delete() 对目录是**递归**删除，放开它等于把「删空目录」变成「删整棵」，" +
        "出于安全没有放开。**文件可以删**；要清空目录请先逐个删里面的文件，" +
        "或改用「默认工作区」（有真实路径、可以正常删目录）。"