package com.theohowie.heracles.bridge

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.locks.ReentrantLock

/**
 * **长期记忆存储（global 作用域）** —— `heracles/device` 通道里 `memory.*` 的实现。
 *
 * ## 2026-10-29 重写：单文件 `memory.md` → 三作用域契约里的 global 目录
 *
 * 契约见 `docs/INTERFACE.md` §N12.2–§N12.5（**唯一权威**；本文只记实现取舍）。
 * Kotlin 这一侧只负责 **global + 提议 + 迁移**，workspace/session 两作用域
 * 在工作区目录里、由 Dart 经 `fs.*` 读写（Kotlin 不碰）。
 *
 * 目录（全部在 App 私有外置目录下，卸载即丢，这是有意的取舍）：
 *
 * ```
 * <externalFilesDir>/heracles/memory/
 *   ├── global.jsonl      ← 真源（append-only：条目行 + 墓碑行）
 *   ├── proposals.jsonl   ← agent 提议（pending/promoted/rejected）
 *   ├── index.json        ← 派生索引（可重建，绝不当真源）
 *   ├── migrate.json      ← 迁移标记（幂等）
 *   └── legacy/           ← 旧文件备份与搬入的 memory.md
 * ```
 *
 * ## 为什么 append-only + 墓碑，而不是"读到内存、改完整个重写"
 *
 * 记忆是**跨会话、跨工作区共享**的，两个入口（用户编辑 / agent 提议晋升）
 * 可能同时来。若每次改写都"清空 + 逐条重写"，中途崩溃就会**整份记忆归零**。
 * 现在改写 = 追加一行墓碑（`{"v":1,"tomb":"del",...}`），读取时折叠：
 *
 * · 同 id 后写者胜（last-wins）；
 * · `tomb:"del"` 只影响**它之前**出现的那些条目；
 * · `tomb:"clear"` 清掉它之前的全部条目，之后的条目照常有效。
 *
 * 折叠的代价是文件里会有"已死"的行 ⇒ [maybeCompactLocked] 在无效行占比
 * 达到 [COMPACT_GARBAGE_RATIO]（50%）或文件超过软预算
 * [COMPACT_SIZE_RATIO]（80%）时，把存活条目重写成 `global.jsonl.tmp`
 * 再 `rename` 覆盖；**失败保留原文件**（宁可不压，也不丢数据）。
 *
 * ## 存储预算：**不再"到顶就拒写"**
 *
 * 旧实现是 256 KB 硬闸，满了拒绝。现行契约（§N12.8）是**软预算 + 确定性淘汰**：
 * 超 [GLOBAL_SOFT_BYTES]（8 MB）或 [ENTRIES_SOFT_MAX]（5000 条）时：
 * ① 先删过期 → ② 再删最旧 `source=agent` → ③ 再删最旧 promoted/legacy
 * → ④ **最后**删最旧 user（用户亲手写的东西优先级最高）→ ⑤ 仍放不下才
 * `E_ENTRY_TOO_LONG`。淘汰的 id 回在 `evicted:[…]` 里（**不静默丢条目**）。
 *
 * **不做 LRU** 是有意的取舍：读变写会让每次注入都改文件，既抖前缀缓存
 * 又放大写放大，而记忆的"热度"本来就不可靠。
 *
 * ## 全局只读：`append` 永久返回 `E_SCOPE_READONLY`
 *
 * 契约 §N12.1：global 只有**用户**能写，agent 只能提议（→ `proposals.jsonl`
 * → 用户晋升 → `source:"promoted"`）。旧方法名 `memory.append` 保留，
 * 让旧调用方拿到**明确错误**而不是"未知方法"（§N12.10 的过渡态）。
 *
 * ## 安全与隐私
 *
 * · SEC4：疑似密钥/令牌的写入一律拒收（[SECRET_PATTERN]，与 backend
 *   `interaction_tools.dart` / App `global_memory.dart` **同源同形**）。
 *   覆盖**所有**写入路径：userEdit add/update、propose、resolveProposal(promote)。
 * · 日志只允许出现 id / 条数 / 长度 / 字节数，**绝不打印记忆正文**，
 *   也不打印异常里可能夹带的正文（只打异常类名）。
 *
 * ## 错误形状（没有"静默成功"分支）
 *
 * 成功 `{"ok":true,…}`；失败 `{"ok":false,"code":<CODE>,"error":<人话>}`。
 * 契约错误码见 §N12.5；本文件另用三个实现面错误码（已报给 Lead 补文档）：
 * `E_BAD_ARG`（缺参/参数非法）、`E_NOT_FOUND`（条目/提议不存在）、
 * `E_SECRET`（SEC4 拒收）。
 *
 * ## 并发
 *
 * 所有入口都在同一把 [lock]（`ReentrantLock`）里跑：读-改-写在同一个临界区，
 * 不存在 TOCTOU 窗口；可重入是因为 [maybeCompactLocked] 等内部函数会
 * 再次进入读写。临界区内只有本地文件 IO（无挂起点），
 * 所以用 `withContext(Dispatchers.IO)` + `ReentrantLock` 而不是 `Mutex`。
 */
class MemoryStore(private val context: Context) {

    companion object {
        /** 记忆根目录名（`<externalFilesDir>/heracles`）。 */
        const val DIR = "heracles"

        /** 记忆子目录名（`<externalFilesDir>/heracles/memory`）。 */
        const val SUBDIR = "memory"

        /** 条目真源文件名（JSONL，append-only）。 */
        const val GLOBAL_FILE = "global.jsonl"

        /** 提议文件名（JSONL）。 */
        const val PROPOSALS_FILE = "proposals.jsonl"

        /** 派生索引文件名（可重建，绝不当真源）。 */
        const val INDEX_FILE = "index.json"

        /** 迁移标记文件名（幂等锚点）。 */
        const val MIGRATE_FILE = "migrate.json"

        /** 迁移备份/搬入子目录名。 */
        const val LEGACY_DIR = "legacy"

        /** 旧单文件记忆的文件名（在 [DIR] 下，**不在** [SUBDIR] 下）。 */
        const val LEGACY_FILE = "memory.md"

        /** 行格式版本（`{"v":1,…}`；未来升版时读侧要兼容）。 */
        const val VERSION = 1

        /** Kotlin 侧只处理这一个作用域。 */
        const val SCOPE = "global"

        /** 单条正文上限（字符数，UTF-16 code unit 口径）。 */
        const val ENTRY_MAX_CHARS = 8000

        /** global 存储软预算（字节）。超了走淘汰，不是拒写。 */
        const val GLOBAL_SOFT_BYTES = 8 * 1024 * 1024

        /** global 条目软上限（条）。 */
        const val ENTRIES_SOFT_MAX = 5000

        /** `memory.search` 的默认返回条数。 */
        const val SEARCH_DEFAULT_LIMIT = 20

        /** `memory.list` / `memory.proposals` 里 0 表示"不限"。 */
        const val LIMIT_UNLIMITED = 0

        /** 无效行占比达到这个比例就 compact。 */
        const val COMPACT_GARBAGE_RATIO = 0.5

        /** 文件超过软预算的这个比例就 compact。 */
        const val COMPACT_SIZE_RATIO = 0.8

        /** `kind` 词表（§N12.3，与 N7 一致；**不静默纠正**）。 */
        val KINDS: Set<String> = setOf("preference", "background", "habit", "other")

        /** `source` 词表。 */
        val SOURCES: Set<String> = setOf("user", "agent", "legacy", "promoted")

        /** 提议状态词表。 */
        val PROPOSAL_STATUSES: Set<String> = setOf("pending", "promoted", "rejected")

        /**
         * SEC4：疑似密钥/令牌（与 backend `interaction_tools.dart`、
         * App `global_memory.dart` **逐字相同**）。宽匹配宁可误拦 ——
         * 误拦的代价是用户换一句脱敏写法，漏拦的代价是凭据进了明文文件。
         */
        val SECRET_PATTERN = Regex(
            "(sk-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}" +
                "|gho_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{15,}|[A-Fa-f0-9]{32,})",
        )

        private const val TAG = "HeraclesMemory"
    }

    /**
     * 唯一的那把锁（见类注释「并发」）。
     *
     * `ReentrantLock` 而非普通锁：内部函数（fold/compact/index 写入）会
     * 重复进入读写路径，可重入才不会自己把自己锁死。
     */
    private val lock = ReentrantLock()

    /** 单调递增的 id 生成器，保证同一毫秒内的多次写入不撞 id。 */
    private var lastMicros: Long = 0L

    /** global.jsonl 的绝对路径（拿不到外置私有目录时为 null）。 */
    fun path(): String? = globalFileOrNull()?.absolutePath

    // ====================================================================
    // 公共 API（12 个通道方法里 Kotlin 负责的 12 个）
    // ====================================================================

    /**
     * `memory.read` → `{ok,text,bytes}`
     *
     * 兼容保留：返回 `global.jsonl` **原文**（供旧 `parseEntries` 直接吃；
     * 旧纯文本行与 JSON 行都在原文里）。文件不存在 ⇒ `text:""`、`bytes:0`，
     * 这是"第一次用还没有记忆"的正常状态，**不是错误**。
     */
    suspend fun read(): Map<String, Any?> = io {
        val f = globalFileOrNull()
        if (f == null) {
            // 旧实现的语义：拿不到私有目录时 read 仍是 ok（空记忆），
            // 只有写路径才必须报错 —— 读空是能继续工作的。
            return@io mapOf("ok" to true, "text" to "", "bytes" to 0)
        }
        if (!f.exists()) return@io mapOf("ok" to true, "text" to "", "bytes" to 0)
        val bytes = f.readBytes()
        mapOf(
            "ok" to true,
            "text" to String(bytes, Charsets.UTF_8),
            "bytes" to bytes.size,
        )
    }

    /**
     * `memory.append` → **永久** `{ok:false,code:"E_SCOPE_READONLY",…}`
     *
     * global 只读（§N12.1）：agent 没有直写全局的通道，只能提议。
     * 方法名保留是为了让旧调用方（旧记忆页的"新增/编辑"）拿到明确人话错误
     * 而不是"未知方法"（§N12.10 的过渡态，**不是 bug**）。
     *
     * 入参 `note` 只用来记**长度**（日志），正文一律不落盘、不打日志。
     */
    suspend fun append(note: String): Map<String, Any?> {
        Log.i(TAG, "append rejected: scope=global readonly chars=${note.trim().length}")
        return err(
            "E_SCOPE_READONLY",
            "全局记忆只读：agent 不能直接写入 global。" +
                "请用 memory.propose 提交提议，由用户在记忆页确认后晋升。",
        )
    }

    /**
     * `memory.clear` → `{ok,removed,bytes}`
     *
     * 兼容等义于 `userEdit{action:"clear"}`：追加一行 `tomb:"clear"`，
     * 之后折叠结果为空；无效行占比 100% ⇒ 紧接着 compact 会把它压成空文件。
     * 文件不存在也成功（幂等）。
     */
    suspend fun clear(): Map<String, Any?> = io { deleteLocked(requireDirLocked(), emptyList(), all = true) }

    /**
     * `memory.list` → `{ok,entries[],total,bytes}`
     *
     * [includeExpired] 默认 false（过期条目不返回）；[limit] 为 0 表示不限。
     * `total` = 过滤后、截断前的条数。
     */
    suspend fun list(
        includeExpired: Boolean = false,
        limit: Int = LIMIT_UNLIMITED,
    ): Map<String, Any?> = io {
        val dir = requireDirLocked()
        val fold = fold(readTextOrEmpty(globalFile(dir)))
        val nowMs = System.currentTimeMillis()
        val all = fold.entries.values
            .filter { includeExpired || !it.isExpired(nowMs) }
            .sortedWith(NEWEST_FIRST)
        val page = if (limit > 0) all.take(limit) else all
        mapOf(
            "ok" to true,
            "entries" to page.map { entryMap(it) },
            "total" to all.size,
            "bytes" to survivingBytes(aliveOf(fold, nowMs)),
        )
    }

    /**
     * `memory.search` → `{ok,entries[],total}`
     *
     * global 关键词检索：简单分词（空白/标点切分；中文没有空格时补 2 字滑窗），
     * 命中数当得分，按 得分降序 → createdAt 降序。**只检索，不注入**。
     * 过期条目不参与检索（与 list 默认口径一致）。查不到 ⇒ 空列表 + ok:true。
     */
    suspend fun search(query: String, limit: Int = SEARCH_DEFAULT_LIMIT): Map<String, Any?> = io {
        val q = query.trim()
        if (q.isEmpty()) throw StoreException("E_BAD_ARG", "memory.search 缺少查询词 query")
        val tokens = tokenize(q)
        if (tokens.isEmpty()) throw StoreException("E_BAD_ARG", "查询词里没有可检索的关键词")
        val dir = requireDirLocked()
        val fold = fold(readTextOrEmpty(globalFile(dir)))
        val nowMs = System.currentTimeMillis()
        val scored = ArrayList<Pair<Entry, Int>>()
        for (e in fold.entries.values) {
            if (e.isExpired(nowMs)) continue
            val hay = (e.text + " " + e.kind).lowercase(Locale.US)
            var score = 0
            for (t in tokens) if (hay.contains(t)) score++
            if (score > 0) scored.add(e to score)
        }
        scored.sortWith(
            compareByDescending<Pair<Entry, Int>> { it.second }
                .thenByDescending { it.first.createdAt }
                .thenByDescending { it.first.id },
        )
        val cap = if (limit > 0) limit else SEARCH_DEFAULT_LIMIT
        val page = scored.take(cap)
        Log.i(TAG, "search: tokens=${tokens.size} hits=${scored.size} returned=${page.size}")
        mapOf(
            "ok" to true,
            "entries" to page.map { entryMap(it.first) },
            "total" to scored.size,
        )
    }

    /**
     * `memory.delete` → `{ok,removed,bytes}`
     *
     * [all] = true 等价 clear；否则只删 [ids] 里**存在**的条目。
     * 一条都不存在 ⇒ `E_NOT_FOUND`（**不静默成功**）。
     */
    suspend fun delete(ids: List<String>, all: Boolean = false): Map<String, Any?> = io {
        val clean = ids.map { it.trim() }.filter { it.isNotEmpty() }
        if (!all && clean.isEmpty()) {
            throw StoreException("E_BAD_ARG", "memory.delete 需要 ids（非空）或 all:true")
        }
        deleteLocked(requireDirLocked(), clean, all)
    }

    /**
     * `memory.userEdit` → `{ok,id?,bytes,entries,evicted[]}`
     *
     * **只有用户路径调用**（能力对象不暴露）。四种 action：
     *
     * · `add`（要 text，kind 可给，缺省 other）
     * · `update`（要 id + text，kind 可给；保留原 createdAt/source/expiresAt）
     * · `delete`（要 id）
     * · `clear`（不需要其他参数）
     *
     * 参数非法一律 `E_BAD_ARG`，**不静默纠正**（例如 kind 不在词表里就报错，
     * 不悄悄改成 other —— 悄悄改会让用户以为存下了原意）。
     */
    suspend fun userEdit(
        action: String,
        id: String? = null,
        text: String? = null,
        kind: String? = null,
    ): Map<String, Any?> = io {
        val dir = requireDirLocked()
        when (action.trim()) {
            "add" -> {
                val body = validateText(text)
                val k = validateKind(kind)
                val entry = Entry(
                    id = nextEntryId(),
                    kind = k,
                    text = body,
                    source = "user",
                    createdAt = System.currentTimeMillis(),
                    expiresAt = null,
                )
                writeEntryLocked(dir, entry, replaceId = null, origin = "userEdit.add")
            }

            "update" -> {
                val targetId = requiredId(id, "update")
                val body = validateText(text)
                val old = fold(readTextOrEmpty(globalFile(dir))).entries[targetId]
                    ?: throw StoreException("E_NOT_FOUND", "条目不存在：$targetId")
                val k = if (kind.isNullOrBlank()) old.kind else validateKind(kind)
                writeEntryLocked(
                    dir,
                    old.copy(text = body, kind = k),
                    replaceId = targetId,
                    origin = "userEdit.update",
                )
            }

            "delete" -> {
                val targetId = requiredId(id, "delete")
                deleteLocked(dir, listOf(targetId), all = false) + mapOf("id" to targetId)
            }

            "clear" -> deleteLocked(dir, emptyList(), all = true)

            else -> throw StoreException(
                "E_BAD_ARG",
                "未知 action：$action（只支持 add / update / delete / clear）",
            )
        }
    }

    /**
     * `memory.propose` → `{ok,id,pending}`
     *
     * agent 提议写入 `proposals.jsonl`（状态 pending）。**同一道 SEC4 闸**
     * （不变量 I8：每条写入路径都过）。
     */
    suspend fun propose(note: String, kind: String? = null): Map<String, Any?> = io {
        val dir = requireDirLocked()
        val body = validateText(note)
        val k = validateKind(kind)
        val nowMs = System.currentTimeMillis()
        val id = nextProposalId()
        val obj = JSONObject()
            .put("v", VERSION)
            .put("id", id)
            .put("status", "pending")
            .put("kind", k)
            .put("text", body)
            .put("source", "agent")
            .put("createdAt", nowMs)
        val f = proposalsFile(dir)
        appendRaw(f, obj.toString() + "\n")
        Log.i(TAG, "propose: id=$id kind=$k chars=${body.length}")
        mapOf("ok" to true, "id" to id, "pending" to countPending(f))
    }

    /**
     * `memory.proposals` → `{ok,entries[],total}`
     *
     * [status] 缺省 `pending`；传 `all`（或空）返回全部。按 createdAt 降序。
     */
    suspend fun proposals(status: String? = "pending"): Map<String, Any?> = io {
        val dir = requireDirLocked()
        val want = (status ?: "pending").trim().lowercase(Locale.US)
        if (want.isNotEmpty() && want != "all" && want !in PROPOSAL_STATUSES) {
            throw StoreException(
                "E_BAD_ARG",
                "未知 status：$status（支持 pending / promoted / rejected / all）",
            )
        }
        val map = readProposalsLocked(proposalsFile(dir))
        val all = map.values
            .filter { want.isEmpty() || want == "all" || it.strOrEmpty("status").ifEmpty { "pending" } == want }
            .sortedByDescending { it.longOrNull("createdAt") ?: 0L }
        mapOf(
            "ok" to true,
            "entries" to all.map { proposalMap(it) },
            "total" to all.size,
        )
    }

    /**
     * `memory.resolveProposal` → `{ok,id,entryId?}`
     *
     * `promote`：把提议正文以 `source:"promoted"` 追加进 `global.jsonl`
     * （走同一套长度/SEC4/淘汰检查），并把提议标记 promoted + promotedId；
     * `reject`：标记 rejected。`proposals.jsonl` 用 tmp + rename 整体重写
     * （提议文件小，且必须能原地改状态；真源仍是 global.jsonl）。
     *
     * 已处理过的提议再处理 ⇒ `E_BAD_ARG`（**不重复晋升**）。
     */
    suspend fun resolveProposal(id: String, action: String): Map<String, Any?> = io {
        val dir = requireDirLocked()
        val targetId = id.trim()
        if (targetId.isEmpty()) throw StoreException("E_BAD_ARG", "memory.resolveProposal 缺少参数 id")
        val act = action.trim().lowercase(Locale.US)
        if (act != "promote" && act != "reject") {
            throw StoreException("E_BAD_ARG", "未知 action：$action（只支持 promote / reject）")
        }
        val f = proposalsFile(dir)
        val map = readProposalsLocked(f)
        val obj = map[targetId] ?: throw StoreException("E_NOT_FOUND", "提议不存在：$targetId")
        val status = obj.strOrEmpty("status").ifEmpty { "pending" }
        if (status != "pending") {
            throw StoreException("E_BAD_ARG", "提议已处理（status=$status），不能重复处理")
        }
        val nowMs = System.currentTimeMillis()
        if (act == "promote") {
            val text = obj.strOrEmpty("text")
            if (text.isBlank()) throw StoreException("E_BAD_ARG", "提议正文为空，无法晋升：$targetId")
            // 提议落盘时已过 SEC4；晋升再验一次 —— 防旧提议/手改文件绕过（I8）。
            if (SECRET_PATTERN.containsMatchIn(text)) {
                throw StoreException("E_SECRET", SECRET_REJECT_MESSAGE)
            }
            if (text.length > ENTRY_MAX_CHARS) {
                throw StoreException(
                    "E_ENTRY_TOO_LONG",
                    "提议正文 ${text.length} 字符，超过单条上限 $ENTRY_MAX_CHARS，无法晋升。",
                )
            }
            val entry = Entry(
                id = nextEntryId(),
                kind = obj.strOrEmpty("kind").ifEmpty { "other" },
                text = text,
                source = "promoted",
                createdAt = nowMs,
                expiresAt = null,
            )
            val written = writeEntryLocked(dir, entry, replaceId = null, origin = "resolveProposal.promote")
            obj.put("status", "promoted").put("resolvedAt", nowMs).put("promotedId", entry.id)
            map[targetId] = obj
            rewriteProposalsLocked(f, map)
            Log.i(TAG, "resolveProposal promote: proposal=$targetId entry=${entry.id}")
            return@io written + mapOf("id" to targetId, "entryId" to entry.id, "promoted" to true)
        }
        obj.put("status", "rejected").put("resolvedAt", nowMs)
        map[targetId] = obj
        rewriteProposalsLocked(f, map)
        Log.i(TAG, "resolveProposal reject: proposal=$targetId")
        mapOf("ok" to true, "id" to targetId, "promoted" to false)
    }

    /**
     * `memory.stats` → `{ok,entries,expired,bytes,fileBytes,pendingProposals,limits{…},path}`
     *
     * 存储组与注入组两组数字都给（§N12.8：两者互不推导）。
     * `bytes` = **存活条目的序列化字节数**（约等于 compact 后的文件大小，
     * 可预算比较；不随墓碑膨胀）；`fileBytes` = 磁盘上 `global.jsonl` 实际字节数。
     */
    suspend fun stats(): Map<String, Any?> = io {
        val dir = memoryDirOrNull()
        val gf = if (dir == null) null else globalFile(dir)
        val raw = if (gf == null) "" else readTextOrEmpty(gf)
        val fold = fold(raw)
        val nowMs = System.currentTimeMillis()
        val alive = fold.entries.values.filter { !it.isExpired(nowMs) }
        val limits = linkedMapOf<String, Any?>(
            "storageSoftMaxBytes" to GLOBAL_SOFT_BYTES,
            "entriesSoftMax" to ENTRIES_SOFT_MAX,
            "entryMaxChars" to ENTRY_MAX_CHARS,
            // 注入组（与 backend ContractMemory 同一组数；Kotlin 无法 import Dart）
            "globalWorkspaceInjectMaxChars" to 6000,
            "sessionInjectMaxChars" to 4000,
            "injectMaxEntriesPerScope" to 40,
            "injectCandidateMaxBytes" to 64 * 1024,
            "retrievalMaxCandidates" to 200,
            "summaryMaxChars" to 40,
            "windowRatioCap" to 0.05,
        )
        mapOf(
            "ok" to true,
            "scope" to SCOPE,
            "entries" to alive.size,
            "expired" to (fold.entries.size - alive.size),
            "bytes" to survivingBytes(alive),
            "fileBytes" to (if (gf != null && gf.exists()) gf.length() else 0L),
            "pendingProposals" to (if (dir == null) 0 else countPending(proposalsFile(dir))),
            "limits" to limits,
            "path" to (gf?.absolutePath),
        )
    }

    /**
     * `memory.migrate` → `{ok,migrated,alreadyMigrated?,backup?,entries,reason?}`
     *
     * 把旧 `<externalFilesDir>/heracles/memory.md` 一次性迁进 `global.jsonl`：
     *
     * 1. `migrate.json` 已有 `v==1` 且 `global.jsonl` 存在 ⇒ `alreadyMigrated`
     *    （幂等，**不重复迁**）；
     * 2. 没有旧文件 ⇒ `{migrated:false, reason:"no-legacy-file"}`（正常状态）；
     * 3. **先备份**到 `legacy/memory.md.<ts>.bak`，备份失败即中止（原文件不动）；
     * 4. 逐行解析：行内第一个 `{` 起能解析成 JSON 的，取 id/kind/text/source/
     *    createdAt/expiresAt（缺省 legacy / other / legacy / 0 / null）；
     *    否则**整行原文**作 legacy 条目（kind=other、source=legacy、createdAt=0）；
     *    补 `v:1` 与 `scope:"global"`；**迁移条目不受 8000 字闸**（旧数据不删改）；
     * 5. 写 `global.jsonl.tmp` + fsync + rename；写 index / migrate 标记；
     * 6. 成功后旧 `memory.md` 改名进 `legacy/`；任何失败删 tmp、原文件不动、
     *    返回 `E_MIGRATE_FAILED`。
     */
    suspend fun migrate(): Map<String, Any?> = io {
        val base = context.getExternalFilesDir(null)
            ?: throw StoreException("E_STORE_IO", "无法定位 App 私有目录（外部存储可能被摘除）")
        val dir = requireDirLocked()
        val globalFile = globalFile(dir)
        val markFile = File(dir, MIGRATE_FILE)
        val legacyFile = File(File(base, DIR), LEGACY_FILE)

        // ① 幂等：标记在且真源在
        val mark = readJsonOrNull(markFile)
        if (mark != null && mark.optInt("v", 0) == VERSION && globalFile.exists()) {
            Log.i(TAG, "migrate: already migrated")
            return@io mapOf(
                "ok" to true,
                "migrated" to false,
                "alreadyMigrated" to true,
                "entries" to fold(readTextOrEmpty(globalFile)).entries.size,
            )
        }

        // ② 没有旧文件
        if (!legacyFile.exists() || !legacyFile.isFile) {
            Log.i(TAG, "migrate: no legacy file")
            return@io mapOf(
                "ok" to true,
                "migrated" to false,
                "alreadyMigrated" to false,
                "reason" to "no-legacy-file",
                "entries" to 0,
            )
        }

        // ③ global.jsonl 已有内容但没标记（例如上次迁到一半 / 手工放进去的）
        //    ⇒ **绝不覆盖**（覆盖会丢数据）。如实报 alreadyMigrated 并补标记。
        if (globalFile.exists() && globalFile.length() > 0L) {
            val alive = fold(readTextOrEmpty(globalFile)).entries.size
            writeMigrateMark(dir, entries = alive, backup = null, reason = "global-jsonl-exists")
            Log.w(TAG, "migrate: global.jsonl exists ($alive entries), refusing to overwrite")
            return@io mapOf(
                "ok" to true,
                "migrated" to false,
                "alreadyMigrated" to true,
                "reason" to "global-jsonl-exists",
                "entries" to alive,
            )
        }

        // ④ 先备份（失败即中止，原文件不动）
        val stamp = System.currentTimeMillis()
        val backupName = "$LEGACY_FILE.$stamp.bak"
        val legacyDir = File(dir, LEGACY_DIR)
        val backupFile = File(legacyDir, backupName)
        try {
            copyFileSynced(legacyFile, backupFile)
        } catch (e: Throwable) {
            Log.w(TAG, "migrate: backup failed (${e.javaClass.simpleName})")
            throw StoreException(
                "E_MIGRATE_FAILED",
                "迁移中止：备份旧记忆文件失败（${e.javaClass.simpleName}），原文件未改动。",
            )
        }

        val tmp = File(dir, "$GLOBAL_FILE.tmp")
        try {
            // ⑤ 解析 + 写 tmp
            val entries = parseLegacyEntries(legacyFile)
            val sb = StringBuilder()
            for (e in entries) sb.append(entryJsonString(e)).append('\n')
            FileOutputStream(tmp).use { out ->
                out.write(sb.toString().toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
            // ⑥ 提交：rename 覆盖
            if (!tmp.renameTo(globalFile)) {
                // 目标可能已存在（理论上前面的分支已排除）；删了再试一次
                if (globalFile.exists() && !globalFile.delete()) {
                    throw StoreException("E_MIGRATE_FAILED", "迁移中止：无法写入 global.jsonl（rename 失败）。")
                }
                if (!tmp.renameTo(globalFile)) {
                    throw StoreException("E_MIGRATE_FAILED", "迁移中止：无法写入 global.jsonl（rename 失败）。")
                }
            }
            // ⑦ 派生索引 + 迁移标记
            writeIndexBestEffort(dir)
            writeMigrateMark(dir, entries = entries.size, backup = "$LEGACY_DIR/$backupName", reason = null)
            // ⑧ 旧文件改名进 legacy/（失败不算迁移失败：数据已迁且已备份）
            var legacyMoved = false
            try {
                val dest = File(legacyDir, LEGACY_FILE)
                val target = if (dest.exists()) File(legacyDir, "$LEGACY_FILE.$stamp.moved") else dest
                legacyMoved = legacyFile.renameTo(target)
            } catch (e: Throwable) {
                Log.w(TAG, "migrate: legacy rename failed (${e.javaClass.simpleName})")
            }
            Log.i(TAG, "migrate: migrated ${entries.size} entries (legacyMoved=$legacyMoved)")
            mapOf(
                "ok" to true,
                "migrated" to true,
                "alreadyMigrated" to false,
                "entries" to entries.size,
                "backup" to "$LEGACY_DIR/$backupName",
                "legacyMoved" to legacyMoved,
            )
        } catch (e: StoreException) {
            runCatching { if (tmp.exists()) tmp.delete() }
            throw e
        } catch (e: Throwable) {
            runCatching { if (tmp.exists()) tmp.delete() }
            Log.w(TAG, "migrate failed (${e.javaClass.simpleName})")
            throw StoreException(
                "E_MIGRATE_FAILED",
                "迁移失败（${e.javaClass.simpleName}）：tmp 已删除，原 memory.md 未改动。",
            )
        }
    }

    // ====================================================================
    // 统一 IO + 错误外壳
    // ====================================================================

    /** 在 IO 线程 + 全局锁内跑 [block]；异常统一折成 `{ok:false,code,error}`。 */
    private suspend fun io(block: () -> Map<String, Any?>): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            lock.lock()
            try {
                block()
            } catch (e: StoreException) {
                // 只打错误码与异常类名：**绝不**打正文（e.message 里也不带正文）
                Log.w(TAG, "store error: ${e.code} (${e.javaClass.simpleName})")
                err(e.code, e.message)
            } catch (e: Throwable) {
                Log.w(TAG, "store io error: ${e.javaClass.simpleName}")
                err("E_STORE_IO", "记忆存储 IO 失败：${e.javaClass.simpleName}")
            } finally {
                lock.unlock()
            }
        }

    private fun err(code: String, reason: String?): Map<String, Any?> = mapOf(
        "ok" to false,
        "code" to code,
        "error" to (reason ?: code),
    )

    // ====================================================================
    // 路径
    // ====================================================================

    private fun memoryDirOrNull(): File? {
        val base = context.getExternalFilesDir(null) ?: return null
        return File(File(base, DIR), SUBDIR)
    }

    private fun globalFileOrNull(): File? = memoryDirOrNull()?.let { globalFile(it) }

    private fun globalFile(dir: File): File = File(dir, GLOBAL_FILE)

    private fun proposalsFile(dir: File): File = File(dir, PROPOSALS_FILE)

    /** 写路径用：定位并创建目录，拿不到就报 `E_STORE_IO`。 */
    private fun requireDirLocked(): File {
        val dir = memoryDirOrNull()
            ?: throw StoreException(
                "E_STORE_IO",
                "无法定位 App 私有目录（外部存储可能被摘除）—— 长期记忆暂不可用",
            )
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) {
            throw StoreException("E_STORE_IO", "无法创建记忆目录：${dir.absolutePath}")
        }
        return dir
    }

    // ====================================================================
    // 条目模型与 JSON
    // ====================================================================

    /** 一条 global 记忆（scope 恒为 global，不落进 data class 以免到处传）。 */
    private data class Entry(
        val id: String,
        val kind: String,
        val text: String,
        val source: String,
        val createdAt: Long,
        val expiresAt: Long?,
    ) {
        fun isExpired(nowMs: Long): Boolean = expiresAt != null && expiresAt <= nowMs
    }

    /** 条目 → 一行 JSON（写入用，带解析字段顺序无关）。 */
    private fun entryJsonString(e: Entry): String = JSONObject()
        .put("v", VERSION)
        .put("id", e.id)
        .put("scope", SCOPE)
        .put("kind", e.kind)
        .put("text", e.text)
        .put("source", e.source)
        .put("createdAt", e.createdAt)
        .apply {
            val exp = e.expiresAt
            if (exp == null) put("expiresAt", JSONObject.NULL) else put("expiresAt", exp)
        }
        .toString()

    /** 条目 → 返回给 Dart 的 Map（字段与 §N12.3 同名）。 */
    private fun entryMap(e: Entry): Map<String, Any?> = linkedMapOf(
        "v" to VERSION,
        "id" to e.id,
        "scope" to SCOPE,
        "kind" to e.kind,
        "text" to e.text,
        "source" to e.source,
        "createdAt" to e.createdAt,
        "expiresAt" to e.expiresAt,
    )

    private fun lineBytes(e: Entry): Long = entryJsonString(e).toByteArray(Charsets.UTF_8).size.toLong()

    /** 折叠结果里**未过期**的条目（统计口径统一用它，避免 expired 混进 bytes）。 */
    private fun aliveOf(fold: Fold, nowMs: Long): List<Entry> =
        fold.entries.values.filter { !it.isExpired(nowMs) }

    private fun survivingBytes(entries: Collection<Entry>): Long {
        var n = 0L
        for (e in entries) n += lineBytes(e)
        return n
    }

    private val NEWEST_FIRST: Comparator<Entry> =
        compareByDescending<Entry> { it.createdAt }.thenByDescending { it.id }

    // ====================================================================
    // 折叠（append-only 文件 → 存活条目）
    // ====================================================================

    /**
     * 折叠结果。[invalidLines] 只用于 compact 判断与日志，**不报错**：
     * 一行坏数据不该让整份记忆读不出来（长期数据的容错取舍）。
     */
    private class Fold(
        val entries: LinkedHashMap<String, Entry>,
        val totalLines: Int,
        val invalidLines: Int,
        val tombstoneLines: Int,
    )

    /**
     * `raw` → 存活条目。
     *
     * · 墓碑 `{"v":1,"tomb":"del","ids":[…]}`：删它**之前**的这些 id；
     * · 墓碑 `{"v":1,"tomb":"clear"}`：清掉它之前的全部；
     * · 条目：同 id 后写者胜；`scope` 不是 global 的**丢弃并计数**（§N12.4 第 8 步）。
     */
    private fun fold(raw: String): Fold {
        val entries = LinkedHashMap<String, Entry>()
        var total = 0
        var invalid = 0
        var tombs = 0
        for (line in raw.lineSequence()) {
            val s = line.trim()
            if (s.isEmpty()) continue
            total++
            val obj = runCatching { JSONObject(s) }.getOrNull()
            if (obj == null) {
                invalid++
                continue
            }
            val tomb = obj.strOrEmpty("tomb")
            if (tomb.isNotEmpty()) {
                tombs++
                when (tomb) {
                    "clear" -> entries.clear()
                    "del" -> {
                        val arr = obj.optJSONArray("ids")
                        if (arr == null) {
                            invalid++
                        } else {
                            for (i in 0 until arr.length()) {
                                val id = arr.optString(i, "")
                                if (id.isNotEmpty()) entries.remove(id)
                            }
                        }
                    }
                    else -> invalid++ // 未知墓碑：当无效行，不猜
                }
                continue
            }
            val id = obj.strOrEmpty("id")
            if (id.isEmpty()) {
                invalid++
                continue
            }
            val scope = obj.strOrEmpty("scope").ifEmpty { SCOPE }
            if (scope != SCOPE) {
                // 强校验：scope 不符的条目一律丢弃并计数（防文件被复制串台）
                invalid++
                continue
            }
            val text = obj.strOrEmpty("text")
            if (text.isEmpty()) {
                invalid++
                continue
            }
            val kind = obj.strOrEmpty("kind").ifEmpty { "other" }
            val source = obj.strOrEmpty("source").ifEmpty { "legacy" }
            val createdAt = obj.longOrNull("createdAt") ?: 0L
            val expiresAt = obj.longOrNull("expiresAt")?.takeIf { it > 0L }
            entries[id] = Entry(id, kind, text, source, createdAt, expiresAt)
        }
        return Fold(entries, total, invalid, tombs)
    }

    // ====================================================================
    // 写入核心（add / update / promote 共用）
    // ====================================================================

    /**
     * 写一条条目：先按 [replaceId]（update 时）追加一行 del 墓碑，
     * 再按淘汰计划追加淘汰墓碑，最后追加新条目行 —— **一次 write + fsync**，
     * 不会留下"写了一半的条目"。
     *
     * 淘汰见 [planEviction]。写完检查是否 compact。
     */
    private fun writeEntryLocked(
        dir: File,
        entry: Entry,
        replaceId: String?,
        origin: String,
    ): Map<String, Any?> {
        val nowMs = System.currentTimeMillis()
        val gf = globalFile(dir)
        val before = fold(readTextOrEmpty(gf))
        if (replaceId != null && !before.entries.containsKey(replaceId)) {
            throw StoreException("E_NOT_FOUND", "条目不存在：$replaceId")
        }
        val line = entryJsonString(entry)
        val newLineBytes = line.toByteArray(Charsets.UTF_8).size.toLong()
        // 被替换的旧版本不进淘汰候选（否则可能把"正在更新的这条"淘汰掉）
        val candidates = before.entries.values.filter { it.id != replaceId }
        val plan = planEviction(candidates, newLineBytes, nowMs)

        val buf = StringBuilder()
        if (replaceId != null) buf.append(tombDelLine(listOf(replaceId), nowMs)).append('\n')
        if (plan.isNotEmpty()) buf.append(tombDelLine(plan, nowMs)).append('\n')
        buf.append(line).append('\n')
        appendRaw(gf, buf.toString())

        val compactError = maybeCompactLocked(gf)
        writeIndexBestEffort(dir)
        val after = fold(readTextOrEmpty(gf))
        Log.i(
            TAG,
            "$origin: id=${entry.id} alive=${after.entries.size} evicted=${plan.size} " +
                "chars=${entry.text.length}",
        )
        val out = linkedMapOf<String, Any?>(
            "ok" to true,
            "id" to entry.id,
            "bytes" to survivingBytes(aliveOf(after, System.currentTimeMillis())),
            "entries" to after.entries.size,
            "evicted" to plan,
        )
        if (compactError != null) out["compactError"] = compactError
        return out
    }

    /**
     * 计算淘汰计划（**不写文件**，纯函数）：返回要删的 id 列表。
     *
     * 顺序（§N12.8，确定性）：① 过期（最旧优先）→ ② 最旧 `source=agent`
     * → ③ 最旧 promoted/legacy → ④ **最旧 user（最后动）**。
     * 四条走完仍放不下 ⇒ `E_ENTRY_TOO_LONG`（绝不写半条）。
     */
    private fun planEviction(entries: List<Entry>, newLineBytes: Long, nowMs: Long): List<String> {
        var count = entries.size
        var bytes = survivingBytes(entries)
        val evicted = LinkedHashSet<String>()

        fun fits(): Boolean =
            count + 1 <= ENTRIES_SOFT_MAX && bytes + newLineBytes <= GLOBAL_SOFT_BYTES

        if (fits()) return emptyList()

        fun evict(e: Entry) {
            if (evicted.add(e.id)) {
                count--
                bytes -= lineBytes(e)
            }
        }

        // ① 过期
        for (e in entries.filter { it.isExpired(nowMs) }.sortedBy { it.createdAt }) {
            if (fits()) break
            evict(e)
        }
        // ② 最旧 source=agent
        for (e in entries.filter { it.source == "agent" }.sortedBy { it.createdAt }) {
            if (fits()) break
            evict(e)
        }
        // ③ 最旧 promoted / legacy（不是用户亲手写的，先动）
        for (e in entries.filter { it.source != "agent" && it.source != "user" }
            .sortedBy { it.createdAt }) {
            if (fits()) break
            evict(e)
        }
        // ④ 最旧 user（**最后动** —— 用户亲手写的东西优先级最高，§N12.8）
        for (e in entries.filter { it.source == "user" }.sortedBy { it.createdAt }) {
            if (fits()) break
            evict(e)
        }
        if (!fits()) {
            throw StoreException(
                "E_ENTRY_TOO_LONG",
                "写入这条后仍超出 global 软预算（${GLOBAL_SOFT_BYTES / 1024 / 1024} MB / " +
                    "$ENTRIES_SOFT_MAX 条），按淘汰顺序清理后依然放不下，已拒绝（未写入任何内容）。",
            )
        }
        return evicted.toList()
    }

    /**
     * 删除（[all] = true 等价 clear）。墓碑只针对**存活**的 id 写，
     * 不存在 ⇒ `E_NOT_FOUND`（不静默成功）。
     */
    private fun deleteLocked(dir: File, ids: List<String>, all: Boolean): Map<String, Any?> {
        val nowMs = System.currentTimeMillis()
        val gf = globalFile(dir)
        val before = fold(readTextOrEmpty(gf))
        val targets: List<String> = if (all) {
            before.entries.keys.toList()
        } else {
            ids.filter { before.entries.containsKey(it) }
        }
        if (!all && targets.isEmpty()) {
            throw StoreException("E_NOT_FOUND", "要删除的条目都不存在：${ids.joinToString(",")}")
        }
        if (all && before.entries.isEmpty()) {
            // 幂等：本来就是空的。仍然写一行 clear 墓碑（保证"清空"这件事被记录）
            appendRaw(gf, tombClearLine(nowMs) + "\n")
            return linkedMapOf(
                "ok" to true,
                "removed" to 0,
                "bytes" to 0L,
                "entries" to 0,
            )
        }
        val line = if (all) tombClearLine(nowMs) else tombDelLine(targets, nowMs)
        appendRaw(gf, line + "\n")
        val compactError = maybeCompactLocked(gf)
        writeIndexBestEffort(dir)
        val after = fold(readTextOrEmpty(gf))
        Log.i(TAG, "delete: all=$all removed=${targets.size} alive=${after.entries.size}")
        val out = linkedMapOf<String, Any?>(
            "ok" to true,
            "removed" to targets.size,
            "bytes" to survivingBytes(aliveOf(after, System.currentTimeMillis())),
            "entries" to after.entries.size,
        )
        if (compactError != null) out["compactError"] = compactError
        return out
    }

    // ====================================================================
    // 墓碑行
    // ====================================================================

    private fun tombDelLine(ids: List<String>, at: Long): String {
        val arr = JSONArray()
        for (id in ids) arr.put(id)
        return JSONObject()
            .put("v", VERSION)
            .put("tomb", "del")
            .put("ids", arr)
            .put("at", at)
            .toString()
    }

    private fun tombClearLine(at: Long): String = JSONObject()
        .put("v", VERSION)
        .put("tomb", "clear")
        .put("at", at)
        .toString()

    // ====================================================================
    // compact
    // ====================================================================

    /**
     * 无效行占比 ≥ [COMPACT_GARBAGE_RATIO] 或文件 > 软预算 × [COMPACT_SIZE_RATIO]
     * ⇒ 把**存活且未过期**的条目重写成 `global.jsonl.tmp` 再 rename 覆盖。
     *
     * 返回 null = 没压（或压成功）；返回字符串 = 压失败的人话原因
     * （**不抛**：调用方的写入已经成功，压缩失败不该让它看起来失败）。
     */
    private fun maybeCompactLocked(gf: File): String? {
        if (!gf.exists()) return null
        val raw = readTextOrEmpty(gf)
        val f = fold(raw)
        val nowMs = System.currentTimeMillis()
        val alive = f.entries.values.filter { !it.isExpired(nowMs) }
        val garbage = f.totalLines - alive.size
        val ratio = if (f.totalLines <= 0) 0.0 else garbage.toDouble() / f.totalLines
        val softBytes = (GLOBAL_SOFT_BYTES.toLong() * COMPACT_SIZE_RATIO).toLong()
        val need = ratio >= COMPACT_GARBAGE_RATIO || gf.length() > softBytes
        if (!need) return null
        return try {
            val sb = StringBuilder()
            for (e in alive.sortedBy { it.createdAt }) sb.append(entryJsonString(e)).append('\n')
            writeAtomic(gf, sb.toString())
            Log.i(TAG, "compact: lines=${f.totalLines} alive=${alive.size} ratio=${"%.2f".format(ratio)}")
            null
        } catch (e: Throwable) {
            Log.w(TAG, "compact failed (${e.javaClass.simpleName}), 原文件保留")
            "compact 失败（${e.javaClass.simpleName}），原文件已保留"
        }
    }

    // ====================================================================
    // 提议
    // ====================================================================

    private fun readProposalsLocked(f: File): LinkedHashMap<String, JSONObject> {
        val out = LinkedHashMap<String, JSONObject>()
        for (line in readTextOrEmpty(f).lineSequence()) {
            val s = line.trim()
            if (s.isEmpty()) continue
            val o = runCatching { JSONObject(s) }.getOrNull() ?: continue
            val id = o.strOrEmpty("id")
            if (id.isEmpty()) continue
            out[id] = o // 同 id 后写者胜
        }
        return out
    }

    private fun rewriteProposalsLocked(f: File, map: LinkedHashMap<String, JSONObject>) {
        val sb = StringBuilder()
        for (o in map.values) sb.append(o.toString()).append('\n')
        writeAtomic(f, sb.toString())
    }

    private fun countPending(f: File): Int =
        readProposalsLocked(f).values.count {
            it.strOrEmpty("status").ifEmpty { "pending" } == "pending"
        }

    private fun proposalMap(o: JSONObject): Map<String, Any?> = linkedMapOf(
        "v" to o.optInt("v", VERSION),
        "id" to o.strOrEmpty("id"),
        "status" to o.strOrEmpty("status").ifEmpty { "pending" },
        "kind" to o.strOrEmpty("kind").ifEmpty { "other" },
        "text" to o.strOrEmpty("text"),
        "source" to o.strOrEmpty("source").ifEmpty { "agent" },
        "createdAt" to (o.longOrNull("createdAt") ?: 0L),
        "resolvedAt" to o.longOrNull("resolvedAt"),
        "promotedId" to o.strOrEmpty("promotedId").ifEmpty { null },
    )

    // ====================================================================
    // 迁移
    // ====================================================================

    /**
     * 旧 `memory.md` → 条目列表。
     *
     * 逐行：行内第一个 `{` 起能解析成 JSONObject ⇒ 读字段（缺省见 KDoc）；
     * 否则**整行原文**作 legacy 条目。**不受 8000 字闸**（旧数据不许删改）。
     * 同一文件里重复 id 的，后者重新生成 id（last-wins 会丢条目，迁移不允许丢）。
     */
    private fun parseLegacyEntries(legacyFile: File): List<Entry> {
        val raw = String(legacyFile.readBytes(), Charsets.UTF_8)
        val out = ArrayList<Entry>()
        val seen = HashSet<String>()
        for (line in raw.lineSequence()) {
            val s = line.trim()
            if (s.isEmpty()) continue
            var entry: Entry? = null
            val brace = s.indexOf('{')
            if (brace >= 0) {
                val obj = runCatching { JSONObject(s.substring(brace)) }.getOrNull()
                if (obj != null) {
                    val text = obj.strOrEmpty("text")
                    if (text.isNotEmpty()) {
                        entry = Entry(
                            id = obj.strOrEmpty("id").ifEmpty { nextEntryId() },
                            kind = obj.strOrEmpty("kind").ifEmpty { "other" },
                            text = text,
                            source = obj.strOrEmpty("source").ifEmpty { "legacy" },
                            createdAt = obj.longOrNull("createdAt") ?: 0L,
                            expiresAt = obj.longOrNull("expiresAt")?.takeIf { it > 0L },
                        )
                    }
                }
            }
            if (entry == null) {
                // 旧纯文本行（`- <ISO> — 正文`）原文保留，不猜结构
                entry = Entry(
                    id = nextEntryId(),
                    kind = "other",
                    text = s,
                    source = "legacy",
                    createdAt = 0L,
                    expiresAt = null,
                )
            }
            val id = if (seen.add(entry.id)) entry.id else nextEntryId()
            out.add(entry.copy(id = id))
        }
        return out
    }

    private fun writeMigrateMark(dir: File, entries: Int, backup: String?, reason: String?) {
        val obj = JSONObject()
            .put("v", VERSION)
            .put("scope", SCOPE)
            .put("entries", entries)
            .put("migratedAt", System.currentTimeMillis())
        if (backup != null) obj.put("backup", backup)
        if (reason != null) obj.put("reason", reason)
        try {
            writeAtomic(File(dir, MIGRATE_FILE), obj.toString())
        } catch (e: Throwable) {
            Log.w(TAG, "migrate mark write failed (${e.javaClass.simpleName})")
        }
    }

    /** 派生索引（**可重建，绝不当真源**）：写失败只记日志，不影响主流程。 */
    private fun writeIndexBestEffort(dir: File) {
        try {
            val gf = globalFile(dir)
            val f = fold(readTextOrEmpty(gf))
            val nowMs = System.currentTimeMillis()
            val alive = f.entries.values.filter { !it.isExpired(nowMs) }
            val obj = JSONObject()
                .put("v", VERSION)
                .put("scope", SCOPE)
                .put("entries", alive.size)
                .put("bytes", survivingBytes(alive))
                .put("updatedAt", nowMs)
            writeAtomic(File(dir, INDEX_FILE), obj.toString())
        } catch (e: Throwable) {
            Log.w(TAG, "index write failed (${e.javaClass.simpleName})")
        }
    }

    // ====================================================================
    // 校验（SEC4 / 长度 / kind）
    // ====================================================================

    /** SEC4 的拒收人话（**唯一来源**，各处共用）。 */
    private val SECRET_REJECT_MESSAGE: String
        get() = "内容疑似包含密钥/令牌，拒绝写入长期记忆（记忆是明文，泄露风险）。" +
            "如需记录，请写\"密钥存放在何处\"而不是密钥本身。"

    /**
     * 所有写入路径的统一正文闸：trim → 非空 → 长度 ≤ [ENTRY_MAX_CHARS]
     * → SEC4。**顺序有意义**：先报长度，用户改短；密钥闸最后（它最贵）。
     */
    private fun validateText(text: String?): String {
        val body = (text ?: "").trim()
        if (body.isEmpty()) throw StoreException("E_BAD_ARG", "要记住的内容是空的")
        if (body.length > ENTRY_MAX_CHARS) {
            throw StoreException(
                "E_ENTRY_TOO_LONG",
                "单条记忆 ${body.length} 字符，超过上限 $ENTRY_MAX_CHARS 字符。" +
                    "请拆成多条，或改用工作区里的笔记文件。",
            )
        }
        if (SECRET_PATTERN.containsMatchIn(body)) {
            throw StoreException("E_SECRET", SECRET_REJECT_MESSAGE)
        }
        return body
    }

    /** kind 词表校验（**不静默纠正**：给错就报错，缺省才用 other）。 */
    private fun validateKind(kind: String?): String {
        if (kind.isNullOrBlank()) return "other"
        val k = kind.trim().lowercase(Locale.US)
        if (k !in KINDS) {
            throw StoreException(
                "E_BAD_ARG",
                "未知 kind：$kind（只支持 ${KINDS.joinToString(" / ")}）",
            )
        }
        return k
    }

    private fun requiredId(id: String?, action: String): String {
        val s = (id ?: "").trim()
        if (s.isEmpty()) throw StoreException("E_BAD_ARG", "userEdit $action 缺少参数 id")
        return s
    }

    // ====================================================================
    // 文件 IO 原语
    // ====================================================================

    private fun readTextOrEmpty(f: File): String =
        if (!f.isFile) "" else String(f.readBytes(), Charsets.UTF_8)

    private fun readJsonOrNull(f: File): JSONObject? {
        if (!f.isFile) return null
        return runCatching { JSONObject(readTextOrEmpty(f).trim()) }.getOrNull()
    }

    /**
     * 追加写 + `fd.sync()`（掉电也不丢这次的追加）。
     *
     * ★ **不读旧内容**：append 的代价与文件大小无关，长记忆也不卡。
     */
    private fun appendRaw(f: File, text: String) {
        f.parentFile?.let { parent ->
            if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
                throw StoreException("E_STORE_IO", "无法创建记忆目录：${parent.absolutePath}")
            }
        }
        try {
            FileOutputStream(f, /* append = */ true).use { out ->
                out.write(text.toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
        } catch (e: Throwable) {
            throw StoreException("E_STORE_IO", "写入记忆文件失败（${e.javaClass.simpleName}）")
        }
    }

    /**
     * 原子写：写 `.tmp` + fsync 再 rename 覆盖。失败删 tmp、**保留原文件**。
     */
    private fun writeAtomic(target: File, text: String) {
        target.parentFile?.let { parent ->
            if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
                throw StoreException("E_STORE_IO", "无法创建记忆目录：${parent.absolutePath}")
            }
        }
        val tmp = File(target.parentFile, target.name + ".tmp")
        try {
            FileOutputStream(tmp).use { out ->
                out.write(text.toByteArray(Charsets.UTF_8))
                out.flush()
                out.fd.sync()
            }
        } catch (e: Throwable) {
            runCatching { if (tmp.exists()) tmp.delete() }
            throw StoreException("E_STORE_IO", "写临时文件失败（${e.javaClass.simpleName}）")
        }
        if (!tmp.renameTo(target)) {
            // POSIX rename 可以覆盖；个别实现（或目标被占）会失败 ⇒ 删目标再试一次。
            // 删目标到 rename 之间有极短窗口，所以只在第一次 rename 失败后才走这一步。
            if (target.exists() && !target.delete()) {
                runCatching { tmp.delete() }
                throw StoreException("E_STORE_IO", "替换文件失败：${target.name}")
            }
            if (!tmp.renameTo(target)) {
                runCatching { tmp.delete() }
                throw StoreException("E_STORE_IO", "替换文件失败：${target.name}")
            }
        }
    }

    private fun copyFileSynced(src: File, dst: File) {
        dst.parentFile?.let { parent ->
            if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
                throw StoreException("E_MIGRATE_FAILED", "无法创建备份目录：${parent.absolutePath}")
            }
        }
        FileInputStream(src).use { input ->
            FileOutputStream(dst).use { out ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    out.write(buf, 0, n)
                }
                out.flush()
                out.fd.sync()
            }
        }
    }

    // ====================================================================
    // 杂项
    // ====================================================================

    /**
     * `m<epochMicros>` 形状的 id（§N12.3）。
     *
     * 用 `millis * 1000` 做基准再单调 +1：同一毫秒内连写多条也不会撞 id，
     * 而形状仍是"微秒时间戳"（对 UI 排序/展示够用）。
     */
    private fun nextMicros(): Long {
        var v = System.currentTimeMillis() * 1000L
        if (v <= lastMicros) v = lastMicros + 1L
        lastMicros = v
        return v
    }

    private fun nextEntryId(): String = "m" + nextMicros()

    private fun nextProposalId(): String = "p" + nextMicros()

    /**
     * 简单分词：空白/标点切分；整串只有一个词且长度 > 2 时补 2 字滑窗
     * （中文没有空格 ⇒ 不补滑窗会"整句搜不到、单字搜一堆"）。
     */
    private fun tokenize(query: String): List<String> {
        val parts = query.lowercase(Locale.US)
            .split(Regex("[\\s\\p{Punct}，。、；：！？（）【】「」《》·…—]+"))
            .filter { it.isNotEmpty() }
        if (parts.size > 1) return parts
        val one = parts.firstOrNull() ?: return emptyList()
        if (one.length <= 2) return listOf(one)
        val grams = LinkedHashSet<String>()
        grams.add(one)
        for (i in 0 until one.length - 1) grams.add(one.substring(i, i + 2))
        return grams.toList()
    }

    /**
     * `org.json` 的坑：字段值是 `JSONObject.NULL` 时 `optString` 返回字符串
     * "null"（不是 fallback）⇒ 统一用这个取，缺键/显式 null 都给空串。
     */
    private fun JSONObject.strOrEmpty(name: String): String {
        if (!has(name) || isNull(name)) return ""
        val v = opt(name) ?: return ""
        return if (v is String) v else v.toString()
    }

    /** 同上，数字/字符串数字都认；缺键/显式 null 给 null。 */
    private fun JSONObject.longOrNull(name: String): Long? {
        if (!has(name) || isNull(name)) return null
        return when (val v = opt(name)) {
            is Number -> v.toLong()
            is String -> v.trim().toLongOrNull()
            else -> null
        }
    }

    /** 业务失败（内部异常，统一被 [io] 折成错误 Map）。 */
    private class StoreException(val code: String, override val message: String) : Exception(message)
}
