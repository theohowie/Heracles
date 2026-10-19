package dev.heracles.agent

import dev.heracles.core.contract.Contract
import dev.heracles.toolchain.BuildProfile
import dev.heracles.toolchain.BuildProfiles
import dev.heracles.workspace.RealWorkspaceFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import kotlin.io.path.createTempDirectory

/**
 * **工作区构建剖面加载器**（F9b / P2-2 第二段）—— 门禁。
 *
 * ## 为什么这个测试类的失败路径比成功路径多
 *
 * 加载器的正确性**不在"能读对一份好 JSON"**，而在"**读错时要明确失败**"。
 * 最危险的实现是 `runCatching { parse() }.getOrNull() ?: ANDROID` ——
 * 合法输入照样绿，而用户拼错字段名时**静默用回内置 profile**，
 * 用户以为在用自己那份（"看不见的分歧"）。所以这里每条坏输入都断言
 * `Result.Invalid` 且**文案要点名路径/字段**（能照着修）。
 *
 * ## 覆盖的坏输入（每条都是真会发生的）
 *
 * 坏 JSON · 缺/错 `schemaVersion` · 未知字段（顶层 + 嵌套）· 缺/重复/乱序步骤 ·
 * `artifact` 带路径 · `manifestFile` 带 `..` · 超长文件 · 类型错。
 * 另有：文件不存在 ⇒ `Default`（这是**正常路径**，不是失败）；`id="android"` 允许覆盖内置。
 */
class BuildProfileLoaderTest {

    private fun newFs(): RealWorkspaceFs = RealWorkspaceFs.open(createTempDirectory("profile-loader"))

    private suspend fun writeProfile(fs: RealWorkspaceFs, json: String) {
        fs.mkdirs(".heracles")
        fs.writeText(Contract.Toolchain.PROFILE_FILE, json)
    }

    private fun load(fs: RealWorkspaceFs): BuildProfileLoader.Result = runBlocking {
        BuildProfileLoader.load(fs)
    }

    /** 断言返回 `Invalid`，并返回文案（供进一步断言"点名了什么"）。 */
    private fun invalidReason(result: BuildProfileLoader.Result): String {
        assertTrue(
            result is BuildProfileLoader.Result.Invalid,
            "坏配置必须返回 Invalid（静默回退会把配置错误藏起来），实际：$result",
        )
        return (result as BuildProfileLoader.Result.Invalid).reason
    }

    private fun assertInvalid(json: String, vararg mustMention: String): String {
        val reason = invalidReason(load(newFs().also { runBlocking { writeProfile(it, json) } }))
        assertTrue(reason.contains(Contract.Toolchain.PROFILE_FILE), "文案要点名配置文件路径：$reason")
        mustMention.forEach {
            assertTrue(reason.contains(it), "文案要点名「$it」：$reason")
        }
        return reason
    }

    // ---------------------------------------------------------------- 正常路径

    @Test
    @DisplayName("★ 文件不存在 ⇒ Default（内置 Android；这是正常路径，不是失败）")
    fun missingFileYieldsDefault() {
        val result = load(newFs())
        assertTrue(result is BuildProfileLoader.Result.Default, "实际：$result")
        assertEquals(BuildProfiles.ANDROID, (result as BuildProfileLoader.Result.Default).profile)
    }

    @Test
    @DisplayName("★ 合法 JSON ⇒ Loaded（字段逐个落地，sourcePath 一起带出来）")
    fun validJsonIsLoaded() {
        val fs = newFs()
        runBlocking { writeProfile(fs, validJson()) }

        val result = load(fs)
        assertTrue(result is BuildProfileLoader.Result.Loaded, "实际：$result")
        val loaded = result as BuildProfileLoader.Result.Loaded
        assertEquals(Contract.Toolchain.PROFILE_FILE, loaded.sourcePath)

        val p = loaded.profile
        assertEquals("my-variant", p.id)
        assertEquals("我的变体", p.displayName)
        assertEquals("AndroidManifest.xml", p.probe.manifestFile)
        assertEquals("build_apk.sh", p.buildScriptName)
        assertEquals("app-debug.apk", p.artifact.defaultName)
        assertEquals(
            listOf("prepare", "插入 classes.dex", "进程内对齐", "package"),
            p.steps.map { it.title },
        )
        assertEquals(listOf(false, true, true, false), p.steps.map { it.inProcess })
        // 静态步骤的固定后缀也来自数据
        assertEquals("（aapt2 compile → link → javac → d8）", p.steps[0].fixedDetail)
    }

    @Test
    @DisplayName("★ 允许 id=\"android\" 覆盖内置（裁决点 3）；覆盖的留痕在工具层做，这里只保证能读进来")
    fun androidIdCanOverrideBuiltIn() {
        val fs = newFs()
        runBlocking { writeProfile(fs, validJson(id = "android", displayName = "自定义 Android")) }

        val result = load(fs)
        assertTrue(result is BuildProfileLoader.Result.Loaded, "实际：$result")
        val p = (result as BuildProfileLoader.Result.Loaded).profile
        assertEquals("android", p.id)
        assertEquals("自定义 Android", p.displayName, "覆盖必须真的生效（不是悄悄用回内置）")
    }

    // ---------------------------------------------------------------- 失败路径

    @Test
    @DisplayName("★ 坏 JSON ⇒ Invalid（点名路径，不抛异常）")
    fun badJsonIsInvalid() {
        val json = "{ 这不是 json"
        assertInvalid(json, "不是合法 JSON")
    }

    @Test
    @DisplayName("★ 缺 schemaVersion ⇒ Invalid（不猜版本）")
    fun missingSchemaVersionIsInvalid() {
        assertInvalid(
            validJson().replace("\"schemaVersion\": 1,", ""),
            "schemaVersion",
        )
    }

    @Test
    @DisplayName("★ schemaVersion 不是当前支持值 ⇒ Invalid（点名支持哪版）")
    fun wrongSchemaVersionIsInvalid() {
        assertInvalid(validJson().replace("\"schemaVersion\": 1", "\"schemaVersion\": 99"), "99", "不支持")
    }

    @Test
    @DisplayName("★ 未知**顶层**字段 ⇒ Invalid（拼错的字段名会被静默忽略，必须拒绝）")
    fun unknownTopLevelFieldIsInvalid() {
        assertInvalid(validJson(extraRoot = ",\n          \"artifactId\": \"typo\""), "artifactId", "未知字段")
    }

    @Test
    @DisplayName("★ 未知**嵌套**字段 ⇒ Invalid（steps 元素里的拼错同样拒绝）")
    fun unknownNestedFieldIsInvalid() {
        val steps = DEFAULT_STEPS.replace(
            "{ \"id\": \"ALIGN\", \"title\": \"进程内对齐\", \"inProcess\": true }",
            "{ \"id\": \"ALIGN\", \"title\": \"进程内对齐\", \"inProcess\": true, \"padBytes\": 4 }",
        )
        assertInvalid(validJson(steps = steps), "padBytes", "未知字段")
    }

    @Test
    @DisplayName("★ 缺步骤 ⇒ Invalid（点名缺哪个 id）")
    fun missingStepIsInvalid() {
        val steps = DEFAULT_STEPS.replace(
            "{ \"id\": \"ALIGN\", \"title\": \"进程内对齐\", \"inProcess\": true },",
            "",
        )
        assertInvalid(validJson(steps = steps), "ALIGN")
    }

    @Test
    @DisplayName("★ 步骤 id 重复 ⇒ Invalid")
    fun duplicateStepIsInvalid() {
        val steps = DEFAULT_STEPS.replace(
            "{ \"id\": \"ALIGN\", \"title\": \"进程内对齐\", \"inProcess\": true }",
            "{ \"id\": \"INSERT_DEX\", \"title\": \"插入 classes.dex\", \"inProcess\": true }",
        )
        assertInvalid(validJson(steps = steps), "重复")
    }

    @Test
    @DisplayName("★ 步骤顺序与引擎执行顺序不一致 ⇒ Invalid（否则\"数据=真相\"就破了）")
    fun wrongStepOrderIsInvalid() {
        val steps = """[
          { "id": "PACKAGE", "title": "package", "fixedDetail": "（对齐 → apksigner）" },
          { "id": "INSERT_DEX", "title": "插入 classes.dex", "inProcess": true },
          { "id": "ALIGN", "title": "进程内对齐", "inProcess": true },
          { "id": "PREPARE", "title": "prepare", "fixedDetail": "（aapt2 compile → link → javac → d8）" }
        ]"""
        assertInvalid(validJson(steps = steps), "顺序")
    }

    @Test
    @DisplayName("★ artifact.defaultName 带路径 ⇒ Invalid（回写目标只能是文件名）")
    fun artifactWithPathIsInvalid() {
        assertInvalid(validJson(artifact = "\"../evil.apk\""), "artifact.defaultName", "文件名")
    }

    @Test
    @DisplayName("★ probe.manifestFile 带 .. ⇒ Invalid（探测不能越界）")
    fun manifestWithDotDotIsInvalid() {
        val json = validJson().replace(
            "\"manifestFile\": \"AndroidManifest.xml\"",
            "\"manifestFile\": \"../AndroidManifest.xml\"",
        )
        assertInvalid(json, "probe.manifestFile")
    }

    @Test
    @DisplayName("★ 文件超过上限 ⇒ Invalid（配置文件来自工作区，可能是任意大小）")
    fun tooLongIsInvalid() {
        val huge = validJson() + "\n" + " ".repeat(Contract.Toolchain.PROFILE_MAX_CHARS)
        assertInvalid(huge, "上限", Contract.Toolchain.PROFILE_MAX_CHARS.toString())
    }

    @Test
    @DisplayName("★ 类型错（steps 不是数组）⇒ Invalid（不抛异常）")
    fun wrongTypeIsInvalid() {
        assertInvalid(validJson(steps = "\"not-an-array\""), "steps", "数组")
    }

    @Test
    @DisplayName("★ 类型错（schemaVersion 是字符串）⇒ Invalid")
    fun schemaVersionWrongTypeIsInvalid() {
        assertInvalid(validJson().replace("\"schemaVersion\": 1", "\"schemaVersion\": \"1\""), "schemaVersion")
    }

    // ---------------------------------------------------------------- F9c：重复键（路线 B）

    @Test
    @DisplayName("★★ 顶层重复键 ⇒ Invalid，文案点名键名/路径/次数（gson 是 last-wins，必须明确失败）")
    fun duplicateRootKeyIsInvalid() {
        assertInvalid(
            validJson(extraRoot = ",\n  \"id\": \"typo\""),
            "重复键", "root.id", "静默覆盖", "只允许出现一次",
        )
    }

    @Test
    @DisplayName("★★ 步骤内的重复键 ⇒ Invalid，路径带数组下标（root.steps[0].id）")
    fun duplicateKeyInsideStepIsInvalid() {
        val steps = """[
          { "id": "PREPARE", "id": "PACKAGE", "title": "prepare", "fixedDetail": "（aapt2 compile → link → javac → d8）" },
          { "id": "INSERT_DEX", "title": "插入 classes.dex", "inProcess": true },
          { "id": "ALIGN", "title": "进程内对齐", "inProcess": true },
          { "id": "PACKAGE", "title": "package", "fixedDetail": "（对齐 → apksigner）" }
        ]"""
        assertInvalid(validJson(steps = steps), "重复键", "root.steps[0].id")
    }

    @Test
    @DisplayName("★★ 重复键**先于**未知字段报（语法级先于语义级），且多处一次列全")
    fun duplicateKeyIsReportedBeforeUnknownField() {
        val reason = assertInvalid(
            validJson(
                extraRoot = ",\n  \"id\": \"typo\",\n  \"k\": 1,\n  \"k\": 2,\n  \"artifactId\": \"typo\"",
            ),
            "重复键",
        )
        assertTrue(reason.contains("root.id"), "第一处要点名：$reason")
        assertTrue(reason.contains("root.k"), "第二处也要列出来（不设条数上限）：$reason")
        assertFalse(reason.contains("未知字段"), "★ 重复键必须先报（语法级先于语义级）：$reason")
    }

    @Test
    @DisplayName("★★ 零回退机器证据：合法 profile 照常 Loaded（不同对象里同名键**不是**重复）")
    fun validProfileWithRepeatedKeyNamesInDifferentScopesStillLoads() {
        // 注意 `validJson()` 自带的步骤里 `id`/`title` 各出现 4 次、`inProcess` 2 次，
        // 且与根上的 `id` 同名 —— 作用域只要写错，这条会立刻红。
        val fs = newFs()
        runBlocking { writeProfile(fs, validJson()) }
        val result = load(fs)
        assertTrue(result is BuildProfileLoader.Result.Loaded, "实际：$result")
        assertEquals("my-variant", (result as BuildProfileLoader.Result.Loaded).profile.id)
    }

    // ---------------------------------------------------------------- 夹具

    private fun validJson(
        id: String = "my-variant",
        displayName: String = "我的变体",
        steps: String = DEFAULT_STEPS,
        artifact: String = "\"app-debug.apk\"",
        extraRoot: String = "",
    ): String = """
        {
          "schemaVersion": 1,
          "id": "$id",
          "displayName": "$displayName",
          "probe": { "manifestFile": "AndroidManifest.xml" },
          "buildScriptName": "build_apk.sh",
          "steps": $steps,
          "artifact": { "defaultName": $artifact }$extraRoot
        }
    """.trimIndent()

    private companion object {
        private val DEFAULT_STEPS = """[
          { "id": "PREPARE", "title": "prepare", "fixedDetail": "（aapt2 compile → link → javac → d8）" },
          { "id": "INSERT_DEX", "title": "插入 classes.dex", "inProcess": true },
          { "id": "ALIGN", "title": "进程内对齐", "inProcess": true },
          { "id": "PACKAGE", "title": "package", "fixedDetail": "（对齐 → apksigner）" }
        ]"""
    }
}
