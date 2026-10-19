package dev.heracles.agent

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.contract.Contract
import dev.heracles.toolchain.BuildProfile
import dev.heracles.toolchain.BuildProfiles
import dev.heracles.workspace.WorkspaceFs

/**
 * 从**工作区**加载构建剖面（F9b / P2-2 第二段，2026-10-18）。
 *
 * ## 为什么在 `:agent` 而不是 `:toolchain`
 *
 * `:toolchain` 的依赖只有 `:core` / `:workspace` / coroutines —— **没有 JSON 库**。
 * 而 `:agent` 已经有 gson（2.9.1，`AgentOutputParser` 在用）。把加载器放这里：
 * 零新依赖、零 `docs/11` 改动、不需要"加依赖"的 ADR。
 * `BuildProfile` 在 F9a 里已经做成 public，正好跨模块传。
 *
 * ## 为什么按"工作区约定"而不是给工具加参数
 *
 * 给 `build_apk` 加 `profile` 参数 = 改工具 schema 与描述 ⇒ **冻结前缀字节变、缓存前缀作废**
 * （`docs/27` §2.2 那次 `out_apk` 摩擦刚证明过 schema 变更的代价）。
 * ⇒ 约定文件 [Contract.Toolchain.PROFILE_FILE]（`.heracles/build-profile.json`）：
 * 存在就用、不存在用内置 [BuildProfiles.ANDROID]（今天的行为），**工具 schema 一个字不动**。
 *
 * ## 三条纪律
 *
 * 1. **永不抛**：解析/校验/读盘的所有异常都收敛成 [Result.Invalid]（工具层只认这个）。
 * 2. **不静默回退**：文件存在但坏 ⇒ `Invalid`（**不是** `Default`）。静默回退会让用户以为
 *    在用自己那份 profile，实际跑的是内置的 —— "看不见的分歧"。
 * 3. **未知字段拒绝**：拼错的字段名被静默忽略是最难查的一类错误（配置看起来生效了）。
 *
 * ## schema（version 1，四个键都是必填）
 *
 * ```json
 * {
 *   "schemaVersion": 1,
 *   "id": "my-variant",
 *   "displayName": "我的变体",
 *   "probe": { "manifestFile": "AndroidManifest.xml" },
 *   "buildScriptName": "build_apk.sh",
 *   "steps": [
 *     { "id": "PREPARE",    "title": "prepare",          "fixedDetail": "（…）" },
 *     { "id": "INSERT_DEX", "title": "插入 classes.dex", "inProcess": true },
 *     { "id": "ALIGN",      "title": "进程内对齐",        "inProcess": true },
 *     { "id": "PACKAGE",    "title": "package",          "fixedDetail": "（…）" }
 *   ],
 *   "artifact": { "defaultName": "app-debug.apk" }
 * }
 * ```
 *
 * `steps[].fixedDetail` 可选：给了就是**固定文案**（引擎渲染时忽略运行时细节），
 * 不给则由引擎在运行时拼（插 dex 字节数、对齐填充数）。
 * `steps` 的 **id 顺序必须与引擎执行顺序一致**（数据即真相，顺序错会让人以为管线变了）。
 */
object BuildProfileLoader {

    /** 加载结果 —— 工具层只认这三种，不再自己判断"文件在不在/对不对"。 */
    sealed interface Result {
        /** 工作区里有合法 profile（[sourcePath] 用于如实留痕："来源：…"）。 */
        data class Loaded(val profile: BuildProfile, val sourcePath: String) : Result

        /** 工作区没有 profile 文件 ⇒ 用内置（这是**正常路径**，不是失败）。 */
        data class Default(val profile: BuildProfile) : Result

        /** 文件存在但不可用；[reason] 已含路径与字段名，可直接给用户/模型看。 */
        data class Invalid(val reason: String) : Result
    }

    private val ROOT_KEYS = setOf("schemaVersion", "id", "displayName", "probe", "buildScriptName", "steps", "artifact")
    private val PROBE_KEYS = setOf("manifestFile")
    private val STEP_KEYS = setOf("id", "title", "fixedDetail", "inProcess")
    private val ARTIFACT_KEYS = setOf("defaultName")

    /** profile 的 `id`：小写字母/数字/`._-`（要能当文件名/日志标签，别让用户写空格与中文路径）。 */
    private val ID_PATTERN = Regex("^[a-z0-9][a-z0-9._-]*$")

    /** 引擎的**固定执行顺序**（校验 JSON 声明的顺序必须与它一致）。 */
    private val PIPELINE_ORDER = listOf(
        BuildProfile.Step.Id.PREPARE,
        BuildProfile.Step.Id.INSERT_DEX,
        BuildProfile.Step.Id.ALIGN,
        BuildProfile.Step.Id.PACKAGE,
    )

    /**
     * 读取并校验工作区 profile。
     *
     * @param fallback 文件不存在时用的内置剖面（默认 [BuildProfiles.ANDROID]）
     */
    suspend fun load(
        fs: WorkspaceFs,
        relativePath: String = Contract.Toolchain.PROFILE_FILE,
        fallback: BuildProfile = BuildProfiles.ANDROID,
    ): Result {
        val raw = try {
            if (!fs.exists(relativePath)) return Result.Default(fallback)
            fs.readText(relativePath)
        } catch (e: Exception) {
            return invalid(relativePath, "读不出来：${e.message}")
        }
        return try {
            parse(raw, relativePath)
        } catch (e: BadProfile) {
            invalid(relativePath, e.message ?: "格式错误")
        } catch (e: Exception) {
            // 兜底：加载器**永不抛**给调用方（工具层只认 Result）
            invalid(relativePath, "解析异常：${e.message}")
        }
    }

    // ---------------------------------------------------------------- 解析

    private fun parse(raw: String, path: String): Result {
        if (raw.length > Contract.Toolchain.PROFILE_MAX_CHARS) {
            return invalid(
                path,
                "内容超过上限（${raw.length} > ${Contract.Toolchain.PROFILE_MAX_CHARS} 字符）—— " +
                    "profile 只该描述探测/步骤/产物，不该这么大",
            )
        }
        val rootEl = try {
            JsonParser.parseString(raw)
        } catch (e: Exception) {
            return invalid(path, "不是合法 JSON：${e.message}")
        }
        if (!rootEl.isJsonObject) return invalid(path, "顶层必须是 JSON 对象")

        // ★ F9c：重复键拒绝（gson 是 last-wins、静默覆盖 ⇒ 只能自己扫 token）。
        //   位置：gson 解析**成功之后**（坏 JSON 仍由 gson 报，抢不了它的报文）、
        //   `rejectUnknown` **之前**（语法级先于语义级）。
        //   零回退：合法且无重复 ⇒ 与 F9b 走**同一条**路径（不新增字段、不改任何既有文案）。
        when (val scan = DuplicateKeys.scan(raw)) {
            is DuplicateKeys.Scan.Found -> return invalid(
                path,
                DuplicateKeys.describe(scan.duplicates) +
                    " —— JSON 对象里同一个键只允许出现一次；重复时后一个会**静默覆盖**前一个" +
                    "（gson 是 last-wins），所以这里直接拒绝",
            )
            // ⚠️ 扫不动**不许**当成"没重复"（同一条纪律：静默 = 放过）
            is DuplicateKeys.Scan.Unusable -> return invalid(
                path,
                "无法检查重复键（${scan.reason}）—— 拒绝，而不是当它没重复",
            )
            DuplicateKeys.Scan.Clean -> Unit
        }

        val root = rootEl.asJsonObject
        rejectUnknown(root, ROOT_KEYS, "顶层")

        val version = root.get("schemaVersion") ?: throw BadProfile(
            "缺 schemaVersion（当前支持 ${Contract.Toolchain.PROFILE_SCHEMA_VERSION}）",
        )
        if (!version.isJsonPrimitive || !version.asJsonPrimitive.isNumber) {
            throw BadProfile("schemaVersion 必须是整数")
        }
        val v = version.asInt
        if (v != Contract.Toolchain.PROFILE_SCHEMA_VERSION) {
            throw BadProfile(
                "不支持的 schemaVersion=$v（当前支持 ${Contract.Toolchain.PROFILE_SCHEMA_VERSION}）",
            )
        }

        val id = root.text("id")!!
        if (!ID_PATTERN.matches(id) || id.length > Contract.Toolchain.PROFILE_MAX_TEXT) {
            throw BadProfile("id 只能用小写字母/数字/._- 且不超过 ${Contract.Toolchain.PROFILE_MAX_TEXT} 字符：$id")
        }
        val displayName = root.text("displayName")!!
        checkText(displayName, "displayName")

        val probeObj = root.obj("probe")
        rejectUnknown(probeObj, PROBE_KEYS, "probe")
        val manifestFile = probeObj.text("manifestFile")!!
        checkSafeRelativePath(manifestFile, "probe.manifestFile")

        val buildScriptName = root.text("buildScriptName")!!
        checkSafeFileName(buildScriptName, "buildScriptName")

        val artifactObj = root.obj("artifact")
        rejectUnknown(artifactObj, ARTIFACT_KEYS, "artifact")
        val defaultName = artifactObj.text("defaultName")!!
        checkSafeFileName(defaultName, "artifact.defaultName")

        val stepsArr = root.array("steps")
        if (stepsArr.size() == 0) throw BadProfile("steps 不能为空")
        if (stepsArr.size() > Contract.Toolchain.PROFILE_MAX_STEPS) {
            throw BadProfile(
                "steps 超过上限（${stepsArr.size()} > ${Contract.Toolchain.PROFILE_MAX_STEPS}）",
            )
        }
        val steps = stepsArr.mapIndexed { i, el -> parseStep(el, i) }

        val ids = steps.map { it.id }
        val duplicated = ids.groupingBy { it }.eachCount().filterValues { it > 1 }.keys
        if (duplicated.isNotEmpty()) {
            throw BadProfile("steps 里 id 重复：${duplicated.joinToString("、")}")
        }
        if (ids != PIPELINE_ORDER) {
            throw BadProfile(
                "steps 的 id 顺序必须与引擎执行顺序一致：$PIPELINE_ORDER（实际：$ids）" +
                    "—— 顺序错会让\"数据即真相\"失效",
            )
        }

        return Result.Loaded(
            profile = BuildProfile(
                id = id,
                displayName = displayName,
                probe = BuildProfile.Probe(manifestFile = manifestFile),
                buildScriptName = buildScriptName,
                steps = steps,
                artifact = BuildProfile.Artifact(defaultName = defaultName),
            ),
            sourcePath = path,
        )
    }

    private fun parseStep(el: com.google.gson.JsonElement, index: Int): BuildProfile.Step {
        if (!el.isJsonObject) throw BadProfile("steps[$index] 必须是对象")
        val obj = el.asJsonObject
        rejectUnknown(obj, STEP_KEYS, "steps[$index]")

        val rawId = obj.text("id")!!
        val stepId = BuildProfile.Step.Id.entries.firstOrNull { it.name == rawId }
            ?: throw BadProfile(
                "steps[$index].id 未知：$rawId（允许：${BuildProfile.Step.Id.entries.joinToString("、")}）",
            )
        val title = obj.text("title")!!
        checkText(title, "steps[$index].title")
        val fixedDetail = obj.text("fixedDetail", required = false)
        if (fixedDetail != null) checkText(fixedDetail, "steps[$index].fixedDetail")
        return BuildProfile.Step(
            id = stepId,
            title = title,
            fixedDetail = fixedDetail,
            inProcess = obj.bool("inProcess", default = false),
        )
    }

    // ---------------------------------------------------------------- 校验小工具

    private class BadProfile(message: String) : Exception(message)

    private fun invalid(path: String, detail: String) =
        Result.Invalid("$path 不是合法构建剖面：$detail")

    private fun rejectUnknown(obj: JsonObject, allowed: Set<String>, where: String) {
        val unknown = obj.keySet() - allowed
        if (unknown.isNotEmpty()) {
            throw BadProfile(
                "$where 有未知字段 ${unknown.joinToString("、")}" +
                    "（允许：${allowed.joinToString("、")}）—— 拼错的字段会被静默忽略，所以这里直接拒绝",
            )
        }
    }

    private fun JsonObject.text(key: String, required: Boolean = true): String? {
        val el = get(key)
        if (el == null || el.isJsonNull) {
            if (required) throw BadProfile("缺字段 $key")
            return null
        }
        if (!el.isJsonPrimitive || !el.asJsonPrimitive.isString) throw BadProfile("$key 必须是字符串")
        return el.asString
    }

    private fun JsonObject.bool(key: String, default: Boolean): Boolean {
        val el = get(key) ?: return default
        if (!el.isJsonPrimitive || !el.asJsonPrimitive.isBoolean) throw BadProfile("$key 必须是布尔值")
        return el.asBoolean
    }

    private fun JsonObject.obj(key: String): JsonObject {
        val el = get(key) ?: throw BadProfile("缺字段 $key")
        if (!el.isJsonObject) throw BadProfile("$key 必须是对象")
        return el.asJsonObject
    }

    private fun JsonObject.array(key: String): JsonArray {
        val el = get(key) ?: throw BadProfile("缺字段 $key")
        if (!el.isJsonArray) throw BadProfile("$key 必须是数组")
        return el.asJsonArray
    }

    private fun checkText(value: String, what: String) {
        if (value.isBlank()) throw BadProfile("$what 不能为空")
        if (value.length > Contract.Toolchain.PROFILE_MAX_TEXT) {
            throw BadProfile("$what 超过 ${Contract.Toolchain.PROFILE_MAX_TEXT} 字符")
        }
    }

    /** 纯文件名：不许带路径分隔符（产物要落在项目目录里，不能指向别处）。 */
    private fun checkSafeFileName(value: String, what: String) {
        checkText(value, what)
        if (value == "." || value == ".." || value.contains('/') || value.contains('\\')) {
            throw BadProfile("$what 必须是**纯文件名**（不能带路径）：$value")
        }
    }

    /** 工作区内的相对路径：不许绝对路径 / `..` / 空段（探测不能越界）。 */
    private fun checkSafeRelativePath(value: String, what: String) {
        checkText(value, what)
        val segments = value.split('/')
        if (value.startsWith("/") || value.contains('\\') || segments.any { it.isEmpty() || it == "." || it == ".." }) {
            throw BadProfile("$what 必须是工作区内的相对路径（禁 .. / 绝对路径 / 空段）：$value")
        }
    }
}
