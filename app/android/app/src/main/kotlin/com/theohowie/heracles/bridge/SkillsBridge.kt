package com.theohowie.heracles.bridge

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * **Skills 宿主桥**（V0.4 F1，2026-11-02）—— 契约见 `docs/INTERFACE.md` §N16.1。
 *
 * ## 这里**只做文件系统**，不解析 front-matter
 *
 * 解析/校验在 Dart 侧（backend 的 `parseSkillMd`）—— 那是唯一一份解析器。
 * 如果这里再解析一遍去判断"这文件合不合法"，就会出现两份真相：
 * 宿主说合法、backend 说非法，用户看到的是"装上了但列表里没有"。
 * 所以这里**把字节原样交回去**（`raw`），合法性由 Dart 判并逐条报错。
 *
 * 唯一例外是 [remove] 的 `name` 定位：只给名字时要找到对应目录，会做一次
 * **极简**的 `name:` 行提取（不校验、不报错，找不到就返回 false）。
 *
 * ## 启停状态为什么存在宿主
 *
 * 生命周期跟着**安装**而不是跟着会话；backend 是纯函数式的编排层（无 IO）。
 * 键空间是 `name → bool`，`builtin` 与 `user` 共用一张表 —— 所以内置技能
 * 没有路径也能被停用（Dart 用名字查表）。
 *
 * ## 与 backend 的常量关系
 *
 * [MAX_FILE_BYTES] / [MAX_DEPTH] 与 `ContractSkills`（`backend/lib/src/contract/contract.dart`）
 * 同值。Kotlin 无法 import Dart 常量，这里是**宿主的副本**：
 * Dart 侧仍会自己再判一次（超限/过深的条目进 `errors`），所以两边不一致只会
 * 影响"宿主愿不愿意读"，不会产生错误结论。改一处请同步另一处。
 */
class SkillsBridge(private val context: Context) {

    /** 单个 SKILL.md 读取上限（512 KB）—— 与 `ContractSkills.maxSkillFileBytes` 同值。 */
    private companion object {
        const val MAX_FILE_BYTES = 512 * 1024

        /** 递归扫描深度上限 —— 与 `ContractSkills.maxScanDepth` 同值。 */
        const val MAX_DEPTH = 4

        const val PREFS = "heracles_skills"
        const val KEY_ENABLED = "enabled"

        /** 技能目录（相对工作区根）—— 与 `ContractSkills.skillsDir` 同值。 */
        const val SKILLS_DIR = ".heracles/skills"

        const val ERR_NO_WORKSPACE = "E_SKILLS_NO_WORKSPACE"
        const val ERR_SOURCE_INVALID = "E_SKILL_SOURCE_INVALID"
        const val ERR_SOURCE_UNREACHABLE = "E_SKILL_SOURCE_UNREACHABLE"
        const val ERR_TOO_LARGE = "E_SKILL_TOO_LARGE"
        const val ERR_NOT_FOUND = "E_SKILL_NOT_FOUND"

        const val DOWNLOAD_TIMEOUT_MS = 15_000
    }

    // ---------------------------------------------------------------- 列清单

    /**
     * 扫 `<workspace>/.heracles/skills/<任意层>/SKILL.md`。
     *
     * ⚠️ 文档注释里**不要**写 `skills` 后面跟两个星号再加斜杠的通配写法：
     * Kotlin 支持**嵌套块注释**，那串字符会开一个永不闭合的内层注释，
     * 把后面几十行的代码全吞掉（实测报错：`Unclosed comment` + `Missing '}'`）。
     *
     * 返回 `{ok, entries:[{path, raw}], enabled:{name:bool}, errors:[...]}`。
     * `errors` 只装**读不出来**的（超限、IO 失败）；**语法非法不在这里报**
     * （那是 Dart 的事，见类注释）。
     */
    fun list(workspace: String): Map<String, Any?> {
        val root = skillsRoot(workspace)
            ?: return failure(ERR_NO_WORKSPACE, "没有可用的工作区路径：$workspace 不可写（技能目录需要 POSIX 可写目录）")

        val entries = JSONArray()
        val errors = JSONArray()
        if (!root.isDirectory) {
            // 目录还没有 = 一个技能都没装（**不是错误**）
            return mapOf("ok" to true, "entries" to entries, "enabled" to enabledMap(), "errors" to errors)
        }
        collect(root, 1, entries, errors)
        return mapOf("ok" to true, "entries" to entries, "enabled" to enabledMap(), "errors" to errors)
    }

    private fun collect(dir: File, depth: Int, out: JSONArray, errors: JSONArray) {
        if (depth > MAX_DEPTH) {
            errors.put("${dir.absolutePath}: 目录层级超过 $MAX_DEPTH 层，已跳过")
            return
        }
        val children = dir.listFiles() ?: return
        for (f in children.sortedBy { it.name }) {
            if (f.isDirectory) {
                // 跳过隐藏目录（.git 之类），避免无意义遍历
                if (!f.name.startsWith(".")) collect(f, depth + 1, out, errors)
                continue
            }
            if (f.name != "SKILL.md") continue
            if (f.length() > MAX_FILE_BYTES) {
                errors.put("${f.absolutePath}: 文件超过 ${MAX_FILE_BYTES / 1024} KB，已跳过")
                continue
            }
            val raw = runCatching { f.readText() }.getOrElse {
                errors.put("${f.absolutePath}: 读取失败（${it.javaClass.simpleName}）")
                return@getOrElse null
            } ?: continue
            out.put(
                JSONObject()
                    .put("path", f.absolutePath)
                    .put("raw", raw),
            )
        }
    }

    // ---------------------------------------------------------------- 启停

    /** 写 `name → enabled`（**不校验技能是否存在** —— Dart 侧已确认过）。 */
    fun setEnabled(name: String, enabled: Boolean): Map<String, Any?> {
        if (name.isBlank()) {
            return mapOf("ok" to false, "error" to "技能名不能为空", "code" to ERR_NOT_FOUND)
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val all = runCatching { JSONObject(prefs.getString(KEY_ENABLED, "{}") ?: "{}") }
            .getOrElse { JSONObject() }
        all.put(name, enabled)
        prefs.edit().putString(KEY_ENABLED, all.toString()).apply()
        return mapOf("ok" to true, "enabled" to enabledMap())
    }

    /** 当前启停表（缺省由 Dart 补 `true` —— 这里**不预填内置技能**，宿主不认识它们）。 */
    private fun enabledMap(): JSONObject =
        runCatching {
            JSONObject(
                context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .getString(KEY_ENABLED, "{}") ?: "{}",
            )
        }.getOrElse { JSONObject() }

    // ---------------------------------------------------------------- 安装

    /**
     * 安装：`source` 是 `https://` URL 或**绝对路径**（文件 / 目录均可）。
     *
     * 目标：`<workspace>/.heracles/skills/<slug>/SKILL.md`；同名目录已存在 ⇒ 覆盖。
     *
     * 返回 `{ok, installed:[{path, raw}], errors:[...]}`：
     * 一条坏的下不下来 / 读不出来，**不影响**其它条（逐条报错）。
     */
    fun install(workspace: String, source: String): Map<String, Any?> {
        val root = skillsRoot(workspace)
            ?: return failure(ERR_NO_WORKSPACE, "没有可用的工作区路径：$workspace 不可写")
        val src = source.trim()
        if (src.isEmpty()) return failure(ERR_SOURCE_INVALID, "安装来源不能为空")

        val installed = JSONArray()
        val errors = JSONArray()

        when {
            src.startsWith("https://") -> {
                val r = download(src)
                if (r.error != null) {
                    errors.put("$src: ${r.error}")
                } else {
                    val path = writeSkill(root, slugFor(urlFileName(src), r.text!!), r.text)
                    if (path == null) errors.put("$src: 写入技能目录失败") else installed.put(
                        JSONObject().put("path", path).put("raw", r.text),
                    )
                }
            }

            src.startsWith("/") -> {
                val f = File(src)
                when {
                    !f.exists() -> return failure(ERR_SOURCE_INVALID, "来源不存在：$src")
                    f.isFile -> {
                        if (f.length() > MAX_FILE_BYTES) {
                            return failure(ERR_TOO_LARGE, "文件超过 ${MAX_FILE_BYTES / 1024} KB：$src")
                        }
                        val text = runCatching { f.readText() }.getOrElse {
                            return failure(ERR_SOURCE_UNREACHABLE, "读取失败：$src（${it.javaClass.simpleName}）")
                        }
                        val path = writeSkill(root, slugFor(f.parentFile?.name ?: "skill", text), text)
                        if (path == null) errors.put("$src: 写入技能目录失败") else installed.put(
                            JSONObject().put("path", path).put("raw", text),
                        )
                    }
                    // 目录：递归装里面所有 SKILL.md（逐条独立成败）
                    else -> {
                        val found = JSONArray()
                        collect(f, 1, found, errors)
                        if (found.length() == 0 && errors.length() == 0) {
                            errors.put("$src: 目录里没有找到 SKILL.md")
                        }
                        for (i in 0 until found.length()) {
                            val o = found.optJSONObject(i) ?: continue
                            val text = o.optString("raw", "")
                            val slug = slugFor(File(o.optString("path", "")).parentFile?.name ?: "skill", text)
                            val path = writeSkill(root, slug, text)
                            if (path == null) {
                                errors.put("${o.optString("path")}: 写入技能目录失败")
                            } else {
                                installed.put(JSONObject().put("path", path).put("raw", text))
                            }
                        }
                    }
                }
            }

            // http:// / file:// / 相对路径一律拒绝：明文与相对路径都是"来源不可信"
            else -> return failure(
                ERR_SOURCE_INVALID,
                "来源必须是 https:// 链接或绝对路径（$src）",
            )
        }

        return mapOf(
            "ok" to (installed.length() > 0),
            "installed" to installed,
            "errors" to errors,
        )
    }

    // ---------------------------------------------------------------- 卸载

    /**
     * 卸载：优先用 `path`（Dart 从已解析清单里取，最准）；
     * 只给 `name` 时按 front-matter 的 `name:` 行反查目录。
     *
     * 只删**技能目录下**的父目录 —— `path` 落在技能目录外一律拒绝（防越界删除）。
     */
    fun remove(workspace: String, name: String, path: String?): Map<String, Any?> {
        val root = skillsRoot(workspace)
            ?: return failure(ERR_NO_WORKSPACE, "没有可用的工作区路径：$workspace 不可写")

        val target: File = if (!path.isNullOrBlank()) {
            val f = File(path)
            if (!f.absolutePath.startsWith(root.absolutePath + File.separator)) {
                return failure(ERR_SOURCE_INVALID, "拒绝删除技能目录之外的文件：$path")
            }
            f.parentFile ?: return failure(ERR_NOT_FOUND, "找不到技能目录：$path")
        } else {
            if (name.isBlank()) return failure(ERR_NOT_FOUND, "要给 name 或 path 才能卸载")
            findByDeclaredName(root, name) ?: return failure(ERR_NOT_FOUND, "找不到技能：$name")
        }

        if (!target.exists()) return failure(ERR_NOT_FOUND, "技能目录不存在：${target.absolutePath}")
        val ok = target.deleteRecursively()
        return if (ok) {
            mapOf("ok" to true, "removed" to true)
        } else {
            failure(ERR_SOURCE_UNREACHABLE, "删除失败（文件被占用？）：${target.absolutePath}")
        }
    }

    private fun findByDeclaredName(dir: File, name: String): File? {
        val children = dir.listFiles() ?: return null
        for (f in children) {
            if (f.isDirectory) {
                findByDeclaredName(f, name)?.let { return it }
                continue
            }
            if (f.name != "SKILL.md") continue
            val declared = runCatching {
                f.readLines()
                    .take(40)
                    .firstOrNull { it.trim().lowercase().startsWith("name:") }
                    ?.substringAfter(':')?.trim()
            }.getOrNull()
            if (declared == name) return f.parentFile
        }
        return null
    }

    // ---------------------------------------------------------------- 工具

    /** 工作区下的技能根目录；不可用（不存在且建不出来）⇒ null。 */
    private fun skillsRoot(workspace: String): File? {
        if (workspace.isBlank()) return null
        val ws = File(workspace)
        if (!ws.isDirectory) return null
        val root = File(ws, SKILLS_DIR)
        if (!root.exists() && !root.mkdirs()) return null
        return root
    }

    /**
     * 落盘到一个 slug 目录。返回写入后的绝对路径；失败 null。
     *
     * 同名覆盖：**覆盖是刻意的** —— 升级技能包时用户不该手动删旧目录。
     */
    private fun writeSkill(root: File, slug: String, text: String): String? = runCatching {
        val dir = File(root, slug)
        if (!dir.exists() && !dir.mkdirs()) return@runCatching null
        val out = File(dir, "SKILL.md")
        FileOutputStream(out).use { it.write(text.toByteArray(Charsets.UTF_8)) }
        out.absolutePath
    }.getOrNull()

    /**
     * 目录名 slug：`[a-z0-9-_]`，其余折叠成 `-`；拿不到可读名就用内容哈希。
     *
     * 为什么要 slug 而不是直接用名字：技能名可能含中文/空格/`..`
     * （`..` 会直接把目录跳出技能根 —— 目录穿越）。
     */
    private fun slugFor(raw: String, content: String): String {
        val s = raw.lowercase()
            .map { if (it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_') it else '-' }
            .joinToString("")
            .trim('-')
            .take(48)
        if (s.isNotEmpty()) return s
        // 空名/全非 ASCII ⇒ 用内容哈希，避免所有技能挤进同一个目录
        return "skill-" + content.hashCode().toUInt().toString(16)
    }

    private fun urlFileName(url: String): String =
        url.substringBefore('?').substringAfterLast('/').ifBlank { "skill" }

    private data class Download(val text: String?, val error: String?)

    /** **只允许 https**（明文 http 会被运营商/代理改写，装进来的技能正文不可信）。 */
    private fun download(url: String): Download {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = DOWNLOAD_TIMEOUT_MS
                readTimeout = DOWNLOAD_TIMEOUT_MS
                instanceFollowRedirects = false
                requestMethod = "GET"
            }
            val code = conn.responseCode
            if (code != 200) return Download(null, "HTTP $code")
            val bytes = conn.inputStream.use { it.readBytes() }
            if (bytes.size > MAX_FILE_BYTES) {
                return Download(null, "文件超过 ${MAX_FILE_BYTES / 1024} KB")
            }
            Download(String(bytes, Charsets.UTF_8), null)
        } catch (e: Exception) {
            // ⚠️ 只报异常类型，不拼 URL 全文（可能带临时 token）
            Download(null, "下载失败（${e.javaClass.simpleName}）")
        } finally {
            runCatching { conn?.disconnect() }
        }
    }

    private fun failure(code: String, message: String): Map<String, Any?> =
        mapOf("ok" to false, "error" to message, "code" to code)
}
