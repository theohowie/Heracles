package com.theohowie.heracles.bridge

import android.content.Context
import android.net.Uri
import dev.heracles.workspace.PosixStorage
import dev.heracles.workspace.WorkspaceStorage
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * 工作区与会话的持久化 —— 对应「电脑上智能体」的项目结构。
 *
 * ## 正确的概念模型（2026-10-10 修正）
 *
 * ```
 * 工作区 = 用户【选择的一个已有文件夹】（项目的根）
 *    │
 *    ├── 在里面直接发消息  → 自动新建会话
 *    └── 会话 A   ⋯重命名 / 🗑删除 / ⭐收藏
 * ```
 *
 * **工作区不是"新建"出来的** —— 它是一个已有文件夹。
 *
 * ## ★ 会话数据必须走 [WorkspaceStorage]（2026-10-10 实修）
 *
 * 首版直接用 `java.io.File` 写 `<工作区>/.heracles/sessions.json` ——
 * 在 SAF 授权的目录上必然失败：
 *
 * ```
 * /storage/emulated/0/test/.heracles/sessions.json:
 *   open failed: EPERM (Operation not permitted)
 * ```
 *
 * 因为用户目录属 `media_rw` 组，而 App 不在这个组里
 * （见 `docs/20-存储访问路线对比.md` §0）。
 *
 * **所以本类不持有 `File`，只持有 [WorkspaceStorage]。**
 */
class SessionStore(private val context: Context) {

    companion object {
        const val DOT_DIR = ".heracles"
        private const val FILE = "sessions.json"
        private const val KEY = "$DOT_DIR/$FILE"

        /**
         * 过程态（`step`）单条落盘的**上限**（字符，`think` 与 `text` 各自）。
         *
         * ## 为什么必须有上限
         *
         * 逐字过程是**长**的：真机实测一轮思考 1315 字符只是"短思考"，
         * 开了推理等级后更长的思考很常见（`docs/25` §12.1）。
         * 会话文件已经会明显变大（体积实测见 `docs/25` §14），
         * 不设上限的话，长时间使用后单个 `.jsonl` 能到几 MB，
         * 而 `appendMessage` 是**读全文 + 追加 + 写全文** ——
         * 那会让"每个步骤写一次盘"退化成 O(n²) 的 IO。
         *
         * ## 为什么是 4000 而不是更小
         *
         * 4000 字符 ≈ 2800 token（中文 0.7/字）。它**大于**本地单轮的
         * 输出预算（`max_tokens` 512），所以**正常的一轮永远不会被截断** ——
         * 上限只在异常的长思考/长工具结果上生效。
         *
         * ## ⚠️ 截断**绝不静默**
         *
         * 截断时同时写 `"truncated": true`，读回时 UI 必须显示
         * "此处已截断（共 N 字符）"。**把丢掉的字数如实告诉用户** ——
         * 静默截断 = 让用户以为模型只说了这么多，那是假信息。
         */
        const val STEP_TEXT_LIMIT = 4000

        /**
         * **内置「应用工作区」的目录名 / 显示名**（2026-10-17）。
         *
         * 目录 = `<外置私有目录>/app-workspace`
         *   = `/storage/emulated/0/Android/data/<pkg>/files/app-workspace`
         *
         * 为什么不是 `files/ws`（自检用的那个）：自检会把
         * `selfcheck/`、`encode-selfcheck.txt`、探针文件堆在里面；
         * 用户的工作区不该被诊断产物占据。两者同级、权限相同。
         */
        const val APP_WORKSPACE_DIR = "app-workspace"
        const val APP_WORKSPACE_NAME = "默认工作区"
    }

    private val prefs = context.getSharedPreferences("heracles_workspaces", Context.MODE_PRIVATE)

    // ------------------------------------------------------------ 工作区

    suspend fun listWorkspaces(): List<Map<String, Any?>> {
        val raw = prefs.getString("list", null) ?: return emptyList()
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val out = mutableListOf<Map<String, Any?>>()
        var migrated = false

        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val path = o.optString("path")
            if (path.isBlank()) continue

            var treeUri = o.optString("treeUri")

            // ★ 自动迁移旧记录（2026-10-10）
            //
            // 上一版 App 登记的工作区**没有 treeUri 字段** ——
            // 那时我还没意识到 SAF 需要它。结果这类旧记录会走
            // PosixStorage → java.io.File → EPERM（真机实测）。
            //
            // 但**授权其实还在**（`takePersistableUriPermission` 早就调过）：
            //   UriPermission{...tree/primary%3Atest [prefix]}
            //   persistable=0x3 persisted=0x3
            //
            // 所以不该让用户重选一次 —— 从系统里把授权捞回来即可。
            if (treeUri.isBlank()) {
                val recovered = findPersistedTreeUriFor(path)
                if (recovered != null) {
                    treeUri = recovered
                    migrated = true
                }
            }

            val hasSaf = treeUri.isNotBlank()
            val dir = File(path)
            // POSIX 且目录不存在 -> 用户删了文件夹，跳过
            // SAF 下 File.isDirectory 恒为 false（权限组不同）—— 不能据此判断
            if (!hasSaf && !dir.isDirectory) continue

            val storage = storageFor(path, treeUri, dir.name)
            out += mapOf(
                "id" to path,
                "name" to (o.optString("name").ifBlank { dir.name }),
                "path" to path,
                "treeUri" to treeUri,
                "isSaf" to hasSaf,
                "sessionCount" to sessions(storage).size,
                "exists" to true,
            )
        }

        // 迁移结果落盘，下次不用再算
        if (migrated) save(out)
        return out
    }

    /**
     * 从系统已持有的持久化授权里，找出对应某个真实路径的 tree URI。
     *
     * `content://com.android.externalstorage.documents/tree/primary%3Atest`
     *   → documentId = `primary:test` → `/storage/emulated/0/test`
     *
     * 匹配不上返回 null（例如用户撤销过授权）。
     */
    private fun findPersistedTreeUriFor(path: String): String? {
        val wanted = runCatching { File(path).canonicalPath }.getOrNull() ?: path
        for (perm in context.contentResolver.persistedUriPermissions) {
            if (!perm.isWritePermission) continue
            val docId = runCatching {
                android.provider.DocumentsContract.getTreeDocumentId(perm.uri)
            }.getOrNull() ?: continue

            val parts = docId.split(":", limit = 2)
            val type = parts.getOrNull(0) ?: continue
            val rel = parts.getOrNull(1).orEmpty()
            val base = if (type == "primary") "/storage/emulated/0" else "/storage/$type"
            val full = if (rel.isBlank()) base else "$base/$rel"

            val candidate = runCatching { File(full).canonicalPath }.getOrNull() ?: continue
            if (candidate == wanted) return perm.uri.toString()
        }
        return null
    }

    suspend fun addWorkspace(path: String, name: String, treeUri: String = ""): Map<String, Any?>? {
        val dir = File(path)
        if (treeUri.isBlank() && !dir.isDirectory) return null

        val list = listWorkspaces().toMutableList()
        list.removeAll { it["path"] == path }
        list.add(
            mapOf(
                "id" to path,
                "name" to if (name.isBlank()) dir.name else name,
                "path" to path,
                "treeUri" to treeUri,
                "isSaf" to treeUri.isNotBlank(),
                "sessionCount" to 0,
                "exists" to true,
            )
        )
        save(list)
        return list.firstOrNull { it["path"] == path }
    }

    suspend fun removeWorkspace(path: String) {
        save(listWorkspaces().filter { it["path"] != path })
    }

    /**
     * **登记内置「应用工作区」**（2026-10-17）—— 一个 App 拥有、shell 也写得进的工作区。
     *
     * ## 为什么必须有它（真机实测，不是推的）
     *
     * 编码层要求工作区 **App 与 shell 都能写**：中间产物由 shell（Shizuku/Stellar）写，
     * 而插 dex / 进程内对齐 / 读产物由 App 自己写。2026-10-17 在真机上逐条验过
     * （同一台 `测试机`）：
     *
     * | 位置 | App 写 | shell 写 |
     * |---|---|---|
     * | 用户自己的 `/sdcard/Download/…` | ✗ `mkdir: Permission denied`（App 不在 `media_rw` 组） | ✓ |
     * | `/sdcard/Android/data/<pkg>/files/…`（含子目录） | ✓（App 自己的目录） | ✓（shell 在 `ext_data_rw` 组） |
     *
     * ⚠️ 写这个目录时**不要**用"斜杠紧跟星号"的通配符写法。
     *    Kotlin 的块注释是**可嵌套**的：注释正文里出现那个两字符组合会**开一层内层注释**，
     *    于是本 KDoc 的收尾符先关掉内层、外层再也关不掉 —— 编译器报
     *    `Unclosed comment`，并且**从这里往后整个文件都编译不过**。
     *    2026-10-17 真机构建就是这么挂的（`:app:compileDebugKotlin`；
     *    注意 `flutter analyze` 只看 Dart，**看不到**这个错）。
     *
     * 而 SAF 选择器（[FolderPickerBridge]）**选不到** `Android/data`
     * —— Android 11+ 不允许浏览它。于是「用户选一个文件夹 → 让 agent 构建」
     * 在当前实现下**必然失败**，且失败会晚到"构建到一半"才出现。
     *
     * ## 取舍（如实记下，不粉饰）
     *
     * 这个目录对用户**不完全可见**（多数文件管理器看不到 `Android/data`），
     * 且**卸载即丢**。它是"可构建的沙箱"，**不是**"用户的项目目录"——
     * 真正要构建用户自己的项目，得先解决 App 对 `/sdcard` 的写权限
     * （见 `26` §6.5 末尾的遗留）。
     *
     * ## 幂等
     *
     * 已登记就**原样返回**（保留用户可能改过的状态）；不重复追加、不覆盖顺序。
     *
     * @return 登记后的工作区条目（形状与 [listWorkspaces] 一致）；`null` = 建不出目录
     */
    suspend fun ensureAppWorkspace(): Map<String, Any?>? {
        // 没有外置私有目录（极少数情况，如存储被摘掉）→ 如实回 null，不假装成功
        val base = context.getExternalFilesDir(null) ?: return null
        val dir = File(base, APP_WORKSPACE_DIR)
        if (!dir.isDirectory && !dir.mkdirs()) return null

        val path = dir.absolutePath
        listWorkspaces().firstOrNull { it["path"] == path }?.let { return it }
        return addWorkspace(path = path, name = APP_WORKSPACE_NAME)
    }

    private fun save(list: List<Map<String, Any?>>) {
        val arr = JSONArray()
        list.forEach { m ->
            arr.put(
                JSONObject().apply {
                    put("path", m["path"])
                    put("name", m["name"])
                    put("treeUri", m["treeUri"] ?: "")
                }
            )
        }
        prefs.edit().putString("list", arr.toString()).apply()
    }

    /**
     * 根据工作区路径与 treeUri 选出正确的存储实现。
     *
     * **这是本类唯一需要知道 SAF 存在的地方** —— 其余逻辑全走抽象接口。
     */
    fun storageFor(path: String, treeUri: String, displayName: String): WorkspaceStorage =
        if (treeUri.isNotBlank()) {
            AndroidSafStorage(context, Uri.parse(treeUri), displayName)
        } else {
            PosixStorage(File(path).toPath(), displayName)
        }

    // ------------------------------------------------------------ 会话

    /** 列出某工作区下的会话，按「收藏 > 最后活动时间」排序 */
    suspend fun sessions(storage: WorkspaceStorage): List<Map<String, Any?>> {
        if (!storage.exists(KEY)) return emptyList()
        val text = runCatching { storage.readText(KEY) }.getOrNull() ?: return emptyList()
        val arr = runCatching { JSONArray(text) }.getOrNull() ?: return emptyList()

        val out = mutableListOf<Map<String, Any?>>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out += mapOf(
                "id" to o.optString("id"),
                "title" to o.optString("title", "新会话"),
                "updatedAt" to o.optLong("updatedAt", 0L),
                "starred" to o.optBoolean("starred", false),
                "archived" to o.optBoolean("archived", false),
            )
        }
        return out.sortedWith(
            compareByDescending<Map<String, Any?>> { it["starred"] == true }
                .thenByDescending { (it["updatedAt"] as? Long) ?: 0L }
        )
    }

    // ------------------------------------------------------------ ★ 消息持久化

    /**
     * 会话消息的存放路径：`.heracles/sessions/<id>.jsonl`
     *
     * ## ★ 为什么必须有这个（2026-10-10 严重 bug 修复）
     *
     * 首版只把**会话元数据**（标题/时间/收藏）写进 `sessions.json`，
     * 而**对话内容只活在 Flutter 的内存里**。
     * 结果：用户切换会话 → `_messages.clear()` → **记录永久丢失**。
     *
     * 用户反馈原话：
     * > "切换会话，会话之前的记录没了，这个很恐怖啊！！"
     *
     * ## 为什么用 JSONL 而不是单个 JSON 数组
     *
     * 1. **追加写** —— 新消息 append 一行即可，不用重写整个文件
     * 2. **抗损坏** —— 一行坏了不影响其它行（JSON 数组一处语法错就全废）
     * 3. **可读** —— 用户用文本编辑器直接能看，符合"外化大脑"的设计
     *    （见 `19-工作区架构.md`）
     *
     * 每行格式：
     * ```json
     * {"role":"user","text":"...","ts":1791611845161}
     * {"role":"tool","tool":"write_file","args":{...},"result":"...","state":"succeeded","ok":true}
     * {"role":"assistant","text":"...","cached":1024,"prompt":1200,"out":50,"ms":6530}
     * {"role":"step","i":3,"stepId":"turn-3","stage":"ok","think":"...","text":"...","ms":4200}
     * ```
     *
     * ## ★ `step` 是过程态，2026-10-12（S5）新增
     *
     * 用户报的 bug 照录：
     * > "我从会话1切换会话2，前面几轮输出的工作步骤不见了……
     * >  但是它已经生成的步骤会消失"
     *
     * 根因就是这里**没有 step 这个 role**：过程（思考 + 叙述）只活在
     * 一轮的内存里，切会话 → 从磁盘重读 → 磁盘上没有 ⇒ 消失。
     *
     * **旧判断「过程态不该持久化」被推翻** —— 理由见
     * `app/lib/models/message.dart` 顶部那段（逐条对照）与
     * `docs/25-流式工作步骤.md` §5.5：用户要的**恰恰是过程本身**。
     *
     * ## ⚠️ 未知 role 必须被**忽略**，不得让读取失败
     *
     * `jsonToMessage` 的 `when` 没有 `else` 分支 —— 不认识的 role
     * 只会得到 `role/text/ts` 三个基础字段，**不会抛异常**。
     * 这条性质是**有意的**：`.jsonl` 是长期存在的用户数据，
     * 将来加 role 时，旧版本 App 仍然要能把其余消息读出来。
     *
     * ## `state` 与 `ok` 的关系（2026-10-10 修复 H-1）
     *
     * tool 记录的 `state` 是**权威三态**：`succeeded` / `failed` / `blocked`。
     *
     * - `blocked` = **请求了工具但从未执行**（循环 / 重复 / 校验不过）。
     *   它既不是成功也不是失败 —— 画成任一个都在骗用户。
     * - `ok` 是**兼容字段**，为不认识 `state` 的旧读取方保留。
     *   写出时 `ok = (state == "succeeded")`，所以旧的读取路径
     *   最多把 `blocked` 显示成"失败"，**绝不会误报成功**。
     *
     * ## 旧数据（没有 `state` 字段）不追溯
     *
     * 历史上因 H-1 落盘的拦截记录是 `ok: true` + `result: ""`。
     * **我们不做迁移**，理由：
     *
     * 1. 无法可靠区分 —— "`ok:true` 且 `result` 为空"也可能是
     *    某个成功工具本来就没输出（例如 `list_files` 空目录返回
     *    的文案非空，但将来可能有工具真的返回空串）。
     *    用不可靠的规则去**改写用户的历史记录**，风险大于收益。
     * 2. 影响面随时间收敛 —— 新记录一律正确；旧记录只影响
     *    那几条已被错误落盘的拦截。
     *
     * 用户切回旧会话时，那几条旧记录**仍显示为成功**（如实说明，
     * 不假装已修好）。新产生的记录则正确显示"被拦截"。
     */
    fun messagesPath(sessionId: String) = "$DOT_DIR/sessions/$sessionId.jsonl"

    /** 读取一个会话的全部消息（按写入顺序） */
    suspend fun loadMessages(
        storage: WorkspaceStorage,
        sessionId: String,
    ): List<Map<String, Any?>> {
        val path = messagesPath(sessionId)
        if (!storage.exists(path)) return emptyList()

        val text = try {
            storage.readText(path)
        } catch (e: Throwable) {
            // 读不出来不能静默 —— 但要和"空会话"区分开
            return listOf(
                mapOf(
                    "role" to "system",
                    "text" to "无法读取会话记录：${e.message}",
                    "ts" to 0L,
                )
            )
        }

        val out = mutableListOf<Map<String, Any?>>()
        for (line in text.lineSequence()) {
            val t = line.trim()
            if (t.isEmpty()) continue
            val o = runCatching { JSONObject(t) }.getOrNull() ?: continue
            out += jsonToMessage(o)
        }
        return out
    }

    /**
     * 追加一条消息。
     *
     * **追加而不是重写** —— 这是 JSONL 的核心价值：
     * 长会话下每次写都重写整个文件会越来越慢。
     */
    suspend fun appendMessage(
        storage: WorkspaceStorage,
        sessionId: String,
        message: Map<String, Any?>,
    ) {
        val path = messagesPath(sessionId)
        val line = messageToJson(message).toString() + "\n"

        val existing = if (storage.exists(path)) {
            runCatching { storage.readText(path) }.getOrNull() ?: ""
        } else {
            ""
        }

        try {
            storage.writeText(path, existing + line)
        } catch (e: Throwable) {
            // ★ 不静默 —— 丢消息是严重问题，必须让用户知道
            throw IllegalStateException(
                "无法保存会话记录：" + storage.locationLabel + "/" + path +
                    "（" + e.message + "）"
            )
        }
    }

    /**
     * 删除会话时一并删掉消息文件。
     *
     * **真删除**（2026-10-10 补）：`WorkspaceStorage` 现在有 `delete` 了，
     * 不再用"写空"代替 —— 那样会在磁盘上留下一个空文件，
     * 用户用文件管理器看会以为还有记录。
     *
     * 删除失败**不抛** —— 清理失败不该让整个会话操作崩掉
     *（消息文件残留最多浪费几 KB，而抛异常会让用户以为删除也没成功）。
     */
    suspend fun deleteMessages(storage: WorkspaceStorage, sessionId: String) {
        runCatching { storage.delete(messagesPath(sessionId)) }
    }

    /**
     * 追加一条**过程态步骤**（2026-10-12，S5）。
     *
     * 这是修用户报的「切会话后已生成的步骤会消失」的落盘入口。
     *
     * ## ★ 写入时机：**每个步骤结束时写一次**（不是每 token 一次）
     *
     * 过程是**流式**的（一轮几百个 chunk），但**落盘不是流**：
     *
     * | 方案 | 代价 | 结论 |
     * |---|---|---|
     * | 每 token 写一次 | 一轮 500 次「读全文 + 追加 + 写全文」 | ❌ 会卡 UI，且 O(n²) |
     * | 每 16ms 写一次 | 同上，只是频率稍低 | ❌ 磁盘寿命与耗电都不划算 |
     * | **每步结束时写一次** | 一轮 1 次（轮数 = 步数） | ✅ **采用** |
     * | 只在 `run()` 返回后批量写 | 运行中途切走 → 那一轮**仍然消失** | ❌ 正是用户报的场景 |
     *
     * 选"每步写一次"的理由：
     * 1. **频率与轮数同阶**（一轮 1 条），而不是与 token 数同阶；
     * 2. **切走的窗口最小** —— `StepEnded` 一到就落盘，此后任何时刻切会话
     *    都能读回这一步。若只在 `run()` 返回后批量写，用户切走时
     *    **整轮的步骤都不在磁盘上**，那正是他抱怨的现象。
     * 3. 单条记录是**完整**的（`think` + `text` + 状态 + 耗时），
     *    不是半截增量 —— 读回来就能直接渲染，不需要"重放"。
     *
     * ## ⚠️ 写失败**不抛**
     *
     * 与 [appendMessage] 不同（那里丢用户的输入是严重问题）。
     * 这里丢的是**过程记录**：抛出去会让 `AgentLoop` 结束后整轮结果写盘
     * 连带失败 —— 用"过程丢了"换来"结果也丢了"是明确的亏本交易。
     * 但**绝不静默**：用 println 留痕（`HERC-PERSIST`），便于真机排查。
     *
     * @return true = 确实写入（false = 模型给的是空步骤，跳过没写）
     */
    suspend fun appendStep(
        storage: WorkspaceStorage,
        sessionId: String,
        step: Map<String, Any?>,
    ): Boolean {
        val (body, truncated) = toStep(step)
        if (body.getString("think").isEmpty() && body.getString("text").isEmpty()) {
            // 空步骤（既没思考也没正文）不落盘 —— 那不是"过程"，
            // 落下去只会在历史里留一串空卡片
            return false
        }
        if (truncated) body.put("truncated", true)

        return try {
            appendMessage(storage, sessionId, body.toMessageMap())
            true
        } catch (e: Throwable) {
            println("HERC-PERSIST 步骤落盘失败（不影响本轮运行）：${e.message}")
            false
        }
    }

    /**
     * 步骤字段 → `.jsonl` 行内容（与 `chat_screen._toMessages` 的 `'step'` 分支一一对应）。
     *
     * | `.jsonl` | 含义 |
     * |---|---|
     * | `i` | 第几轮（`AgentLoop` 的 `turnIndex`） |
     * | `stepId` | 事件流的步骤标识（`turn-3`） |
     * | `title` | 人可读标题 |
     * | `think` | **思考全文** |
     * | `text` | **正文全文** |
     * | `stage` | `ok` / `empty` / `error` |
     * | `ms` | 墙钟耗时 |
     * | `truncated` | 被上限截断过（只在截断时写） |
     *
     * ⚠️ 字段名**故意与 `assistant`/`tool` 行区分**（`think` 不是 `text`），
     * 因为"思考"和"正文"是两条轨，粘在一起就再也分不开了
     * （`docs/25` §2 错误一）。
     */
    private fun toStep(step: Map<String, Any?>): Pair<JSONObject, Boolean> {
        var think = (step["thinking"] as? String).orEmpty()
        var text = (step["text"] as? String).orEmpty()
        var cut = false

        if (think.length > STEP_TEXT_LIMIT) {
            think = think.take(STEP_TEXT_LIMIT)
            cut = true
        }
        if (text.length > STEP_TEXT_LIMIT) {
            text = text.take(STEP_TEXT_LIMIT)
            cut = true
        }

        val o = JSONObject().apply {
            put("role", "step")
            put("text", text)
            put("think", think)
            (step["index"] as? Int)?.let { put("i", it) }
            (step["stepId"] as? String)?.takeIf { it.isNotBlank() }?.let { put("stepId", it) }
            (step["title"] as? String)?.takeIf { it.isNotBlank() }?.let { put("title", it) }
            put("stage", (step["stage"] as? String) ?: "ok")
            put("ms", (step["durationMs"] as? Long) ?: 0L)
            put("ts", System.currentTimeMillis())
        }
        return o to cut
    }

    /** [toStep] 的产物 → [appendMessage] 要的通用字段形状 */
    private fun JSONObject.toMessageMap(): Map<String, Any?> {
        val m = mutableMapOf<String, Any?>(
            "role" to optString("role", "step"),
            "text" to optString("text"),
            "ts" to optLong("ts", System.currentTimeMillis()),
            "think" to optString("think"),
            "stage" to optString("stage", "ok"),
            "ms" to optLong("ms", 0L),
        )
        if (has("i")) m["i"] = optInt("i")
        if (has("stepId")) m["stepId"] = optString("stepId")
        if (has("title")) m["title"] = optString("title")
        if (has("truncated")) m["truncated"] = optBoolean("truncated", false)
        return m
    }

    private fun jsonToMessage(o: JSONObject): Map<String, Any?> {
        val role = o.optString("role", "user")
        val m = mutableMapOf<String, Any?>(
            "role" to role,
            "text" to o.optString("text"),
            "ts" to o.optLong("ts", 0L),
        )
        when (role) {
            "tool" -> {
                m["tool"] = o.optString("tool")
                // ★ 三态优先（2026-10-10 修复 H-1）。
                //
                // 老记录没有 `state`，只有 `ok`。**旧数据不追溯**：
                // 保持原样读回（`ok` 是 true 就还是成功）—— 见
                // [messageToJson] 的说明与 MainActivity 的落盘处。
                if (o.has("state")) {
                    m["state"] = o.optString("state", "failed")
                } else if (o.has("ok")) {
                    m["ok"] = o.optBoolean("ok", true)
                }
                // 拦截原因（只有被拦截的记录有）—— 用户排查问题需要它
                if (o.has("reason")) m["reason"] = o.optString("reason")
                o.optJSONObject("args")?.let { a ->
                    val map = mutableMapOf<String, String>()
                    a.keys().forEach { k -> map[k] = a.optString(k) }
                    m["args"] = map
                }
                m["result"] = o.optString("result")
            }
            "assistant" -> {
                if (o.has("cached")) m["cached"] = o.optInt("cached")
                m["prompt"] = o.optInt("prompt", 0)
                m["out"] = o.optInt("out", 0)
                m["ms"] = o.optLong("ms", 0L)
            }
            // ★★ 过程态步骤（2026-10-12，S5）★★
            //
            // 读回来必须**完整**（含思考与正文的区分），否则切会话后
            // 用户看到的步骤是残缺的 —— 那比"完全没有"更难被发现。
            "step" -> {
                if (o.has("i")) m["i"] = o.optInt("i")
                if (o.has("stepId")) m["stepId"] = o.optString("stepId")
                if (o.has("title")) m["title"] = o.optString("title")
                m["think"] = o.optString("think")
                m["stage"] = o.optString("stage", "ok")
                if (o.has("ms")) m["ms"] = o.optLong("ms", 0L)
                // 截断标记：**原样读回**，UI 据此如实告知用户
                if (o.optBoolean("truncated", false)) m["truncated"] = true
            }
            // ⚠️ 刻意**没有 `else`** —— 不认识的 role 只保留
            //    role/text/ts 三个基础字段，**绝不抛异常**。
            //    `.jsonl` 是长期存在的用户数据，将来加 role 时
            //    旧版本 App 必须还能读出其余消息（见 [messagesPath] 的说明）。
        }
        return m
    }

    private fun messageToJson(m: Map<String, Any?>): JSONObject =
        JSONObject().apply {
            put("role", m["role"])
            put("text", m["text"] ?: "")
            put("ts", m["ts"] ?: System.currentTimeMillis())
            when (m["role"]) {
                "tool" -> {
                    put("tool", m["tool"])
                    // ★ 三态字段（2026-10-10 修复 H-1）—— 新记录的**唯一权威**。
                    //   写出时优先用它；只有老调用方只给 `ok` 时才回落。
                    val state = m["state"] as? String
                    if (state != null) {
                        put("state", state)
                        // 兼容字段：让**不认识 state 的旧读取方**也
                        // 至少不会误报成功（blocked/failed 都写 false）
                        put("ok", state == "succeeded")
                    } else {
                        put("ok", m["ok"] == true)
                    }
                    // 拦截原因 —— 可选字段，只有被拦截的记录才有
                    (m["reason"] as? String)?.takeIf { it.isNotBlank() }?.let {
                        put("reason", it)
                    }
                    @Suppress("UNCHECKED_CAST")
                    (m["args"] as? Map<String, String>)?.let { a ->
                        put("args", JSONObject().apply { a.forEach { (k, v) -> put(k, v) } })
                    }
                    put("result", m["result"] ?: "")
                }
                "assistant" -> {
                    (m["cached"] as? Int)?.let { put("cached", it) }
                    put("prompt", m["prompt"] ?: 0)
                    put("out", m["out"] ?: 0)
                    put("ms", m["ms"] ?: 0L)
                }
                // ★ 过程态步骤（2026-10-12，S5）—— 字段与 [toStep] 一致
                "step" -> {
                    put("think", m["think"] ?: "")
                    (m["i"] as? Int)?.let { put("i", it) }
                    (m["stepId"] as? String)?.takeIf { it.isNotBlank() }?.let { put("stepId", it) }
                    (m["title"] as? String)?.takeIf { it.isNotBlank() }?.let { put("title", it) }
                    put("stage", (m["stage"] as? String) ?: "ok")
                    put("ms", m["ms"] ?: 0L)
                    if (m["truncated"] == true) put("truncated", true)
                }
                // ★★ `usage`：失败/被取消的 run 的**纯记账行**（2026-10-20）★★
                //
                // ## 这个分支为什么必须有（不写就有真实 bug）
                //
                // `messageToJson` 是**白名单式**序列化：只把 `when` 里点名的字段写出去。
                // 没有 `usage` 分支时，2026-10-20 真机写出来的行是
                //   `{"role":"usage","text":"","ts":…}`  ← **cached/prompt/out 全丢了**
                // 而那三个数正是这一行存在的**唯一理由**（L1 缓存采样靠它）。
                //
                // ⇒ 记账行"写成功了"但内容是空的，比没写更糟：采样脚本会把它当成
                //    一次 0 token 的轮次，静默污染分母。
                "usage" -> {
                    put("cached", m["cached"] ?: 0)
                    put("prompt", m["prompt"] ?: 0)
                    put("out", m["out"] ?: 0)
                    (m["turns"] as? Int)?.let { put("turns", it) }
                    (m["stopReason"] as? String)?.takeIf { it.isNotBlank() }?.let {
                        put("stopReason", it)
                    }
                }
            }
        }

    suspend fun createSession(storage: WorkspaceStorage, title: String): String {
        val id = "s${System.currentTimeMillis()}"
        val list = sessions(storage).toMutableList()
        list.add(
            mapOf(
                "id" to id,
                "title" to title.ifBlank { "新会话" },
                "updatedAt" to System.currentTimeMillis(),
                "starred" to false,
                "archived" to false,
            )
        )
        writeSessions(storage, list)
        return id
    }

    suspend fun renameSession(storage: WorkspaceStorage, id: String, title: String) {
        writeSessions(
            storage,
            sessions(storage).map { if (it["id"] == id) it + ("title" to title) else it }
        )
    }

    /**
     * 删除一个会话：元数据 + 消息文件。
     *
     * ## ★ 补上了漏掉的 [deleteMessages]（2026-10-10）
     *
     * 首版只从 `sessions.json` 移除元数据，**从没删过消息文件** ——
     * 于是用户在侧边栏删掉的会话，其 `.heracles/sessions/<id>.jsonl`
     * 一直留在磁盘上（隐私与整洁两方面都是问题：
     * 用户以为删了，其实对话内容还完整躺着）。
     */
    suspend fun deleteSession(storage: WorkspaceStorage, id: String) {
        writeSessions(storage, sessions(storage).filter { it["id"] != id })
        deleteMessages(storage, id)
    }

    suspend fun toggleStar(storage: WorkspaceStorage, id: String): Boolean {
        var now = false
        writeSessions(
            storage,
            sessions(storage).map {
                if (it["id"] == id) {
                    now = !(it["starred"] == true)
                    it + ("starred" to now)
                } else it
            }
        )
        return now
    }

    /** 切换归档，返回新状态 */
    suspend fun toggleArchive(storage: WorkspaceStorage, id: String): Boolean {
        var now = false
        writeSessions(
            storage,
            sessions(storage).map {
                if (it["id"] == id) {
                    now = !(it["archived"] == true)
                    it + ("archived" to now)
                } else it
            }
        )
        return now
    }

    suspend fun touchSession(storage: WorkspaceStorage, id: String) {
        writeSessions(
            storage,
            sessions(storage).map {
                if (it["id"] == id) it + ("updatedAt" to System.currentTimeMillis()) else it
            }
        )
    }

    /**
     * 写会话元数据。
     *
     * ## ★ 不静默吞异常（2026-10-10 实修）
     *
     * 首版用 `runCatching` 包住整个写入 —— 真机出现
     * 「目录建了、文件没写、界面无提示」，排查时毫无线索。
     * **静默失败比崩溃更难排查。**
     */
    private suspend fun writeSessions(
        storage: WorkspaceStorage,
        list: List<Map<String, Any?>>,
    ) {
        val arr = JSONArray()
        list.forEach { m ->
            arr.put(
                JSONObject().apply {
                    put("id", m["id"])
                    put("title", m["title"])
                    put("updatedAt", m["updatedAt"])
                    put("starred", m["starred"] == true)
                    put("archived", m["archived"] == true)
                }
            )
        }
        try {
            storage.writeText(KEY, arr.toString())
        } catch (e: Throwable) {
            throw IllegalStateException(
                "无法写会话记录：" + storage.locationLabel + "/" + KEY +
                    "（" + e.message + "）"
            )
        }
    }
}
