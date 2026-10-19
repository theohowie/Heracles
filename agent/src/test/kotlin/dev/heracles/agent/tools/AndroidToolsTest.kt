package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import dev.heracles.core.progress.TaskProgress
import dev.heracles.core.context.PrefixBuilder
import dev.heracles.core.tool.ToolCall
import dev.heracles.core.tool.ToolRegistry
import dev.heracles.core.tool.ToolSpec
import dev.heracles.core.tool.ToolValidator
import dev.heracles.toolchain.AndroidBuildEngine
import dev.heracles.toolchain.AndroidProjectScaffold
import dev.heracles.toolchain.ApkReverseEngine
import dev.heracles.toolchain.ToolchainPaths
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.RealWorkspaceFs
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory

/** 不会被执行到的 runner —— 这些用例全部在\"起进程之前\"就应当失败。 */
private class NeverRunner : ShellRunner {
    val commands = mutableListOf<String>()
    override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
        commands.add(command)
        return ShellResult(0, "", "", false, 1L)
    }
}

/**
 * 记录命令、一律报成功的 runner —— 用来观察**引擎到底把什么参数交给了脚本**
 * （F7b：`out_apk` 缺键时默认名有没有真的下发）。它当然不产出任何产物，
 * 所以构建本身必然失败 —— 那不影响"命令里带了什么"这个结论。
 */
private class RecordingOkRunner : ShellRunner {
    val commands = mutableListOf<String>()
    override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
        commands.add(command)
        return ShellResult(0, "", "", false, 1L)
    }
}

/**
 * **Android 上不存在**、因而不得在给模型看的描述里被说成可用/必需的二进制
 * （ADR-025 / ADR-026 / ADR-027）。
 *
 * 加新名字就在这里加一条 —— 全量盘点用例会自动覆盖注册表里的每个工具。
 */
private val UNAVAILABLE_ON_ANDROID = listOf("zipalign")

/**
 * 提到上面那些二进制时，所在**小句**必须落在这类否定语境里。
 *
 * 为什么按小句判：`build_apk` 的描述里**有**"不需要 zipalign 二进制"这句**正确**的事实，
 * 一刀切"整段不许出现这个词"会把它一起误杀；而真正的回退写法
 * （`d8 → zipalign → apksigner`）是一整个小句，会被这条抓住。
 */
private val NEGATIONS = listOf("不需要", "没有", "不依赖", "不用", "不是", "已出局")

/**
 * 编码层工具层的行为门禁 —— `26-编码层工具链与逆向引擎.md` §4.2。
 *
 * 引擎本身已在 `:toolchain` 里测过（含端到端构建）。这里只测**工具层**
 * 特有的三件事：
 *
 * 1. 参数缺失/非法 → 是 `Failure` 而不是抛异常（抛异常会打断整个 agent 循环）
 * 2. 环境不具备时**在起进程之前**就失败，并说清缺什么
 * 3. `build_apk` 的"空目录 = 从零"语义（需求模块 4 的 0→1 入口）
 */
class AndroidToolsTest {

    private val root: Path = createTempDirectory("android-tools")
    private val fs = RealWorkspaceFs.open(root)
    private val runner = NeverRunner()

    /** 空工具链 —— 用来验证\"缺什么说得很具体\"。 */
    private val emptyToolchain = ToolchainPaths()

    @Test
    @DisplayName("★ 工具清单：6 个编码层工具，名字唯一，且全部有分组")
    fun toolListIsConsistent() {
        val tools = AndroidTools.create(fs, emptyToolchain, runner)
        assertEquals(6, tools.size)
        AndroidTools.assertConsistent(tools) // 名字重复/漏分组会在这里响亮失败
        assertTrue(
            tools.all { it.spec.name in AndroidTools.GROUPS },
            "编码层工具必须全部登记分组",
        )
    }

    @Test
    @DisplayName("★ 分组表覆盖**全部**长尾工具（归档/补丁也在内，漏了就静默搜不到）")
    fun groupsCoverWholeLongTail() {
        val longTail = AndroidTools.create(fs, emptyToolchain, runner) +
            listOf(UnzipFileTool(fs), ZipFileTool(fs), ApplyPatchTool(fs))
        assertEquals(9, longTail.size)
        AndroidTools.assertConsistent(longTail)
    }

    @Test
    @DisplayName("★ 分组覆盖性：漏登记的工具有明确断言（否则检索静默失灵、没有任何症状）")
    fun missingGroupFailsLoudly() {
        val orphan = object : dev.heracles.agent.AgentTool {
            override val spec = dev.heracles.core.tool.ToolSpec("brand_new_tool", "谁也没登记它")
            override suspend fun execute(args: Map<String, String>) = ToolOutcome.Success("x")
        }
        val ex = org.junit.jupiter.api.assertThrows<IllegalArgumentException> {
            AndroidTools.assertConsistent(listOf(orphan))
        }
        assertTrue(ex.message!!.contains("brand_new_tool"), "断言必须点名，实际：${ex.message}")
    }

    @Test
    @DisplayName("★★ 分组校验认**全部模块**的分组（真机事故：edit 登记在 PatchTools 却被判未登记）")
    fun groupsFromOtherModulesAreRecognised() {
        // 真机症状：App 启动期抛「这些编码层工具没有登记分组：[edit]」，整个会话打不开。
        // 根因 = 各模块分工登记 GROUPS，而校验只看 AndroidTools.GROUPS。
        val foreign = listOf(
            ApplyPatchTool(fs),
            EditFileTool(fs),
            ViewImageTool(fs),
            WebFetchTool(),
        )
        // 这几个工具都登记在**别的模块**的 GROUPS 里，校验必须放行
        AndroidTools.assertConsistent(foreign)

        val union = AndroidTools.allGroups
        for (name in foreign.map { it.spec.name }) {
            assertTrue(name in union, "$name 必须出现在 allGroups 里，否则检索静默失灵")
        }
        // 已知的、按模块登记的条目一个都不能漏
        assertTrue("edit" in union, "edit 必须登记分组（PatchTools.GROUPS）")
        assertTrue("view_image" in union, "view_image 必须登记分组（ImageTools.GROUPS）")
        assertTrue("web_fetch" in union, "web_fetch 必须登记分组（WebTools.GROUPS）")
        assertTrue("delete_path" in union, "delete_path 必须登记分组（PathTools.GROUPS）")
    }

    @Test
    @DisplayName("scaffold_android：生成骨架并给出下一步")
    fun scaffoldWritesProject() = runBlocking {
        val r = ScaffoldAndroidTool(fs).execute(
            mapOf(
                "project_dir" to "hello",
                "package_name" to "com.example.hello",
                "app_name" to "我的应用",
            )
        )
        assertTrue(r is ToolOutcome.Success, "实际：$r")
        assertTrue((r as ToolOutcome.Success).detail.contains("build_apk"), "要提示下一步")
        assertTrue(Files.exists(root.resolve("hello/AndroidManifest.xml")))
    }

    @Test
    @DisplayName("★ scaffold_android：非法包名是 Failure 而**不是抛异常**（抛异常会打断 agent 循环）")
    fun scaffoldRejectsBadPackage() = runBlocking {
        val r = ScaffoldAndroidTool(fs).execute(
            mapOf("project_dir" to "bad", "package_name" to "com.Bad.Name")
        )
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("包名非法"), "要说清是包名问题")
    }

    @Test
    @DisplayName("★ build_apk：空目录会先自动搭骨架（\"从零\"入口），再在缺工具链时明确失败")
    fun buildApkScaffoldsThenReportsMissingToolchain() = runBlocking {
        val tool = BuildApkTool(fs, emptyToolchain, runner, null)
        val r = tool.execute(mapOf("project_dir" to "myapp"))

        assertTrue(r is ToolOutcome.Failure, "缺工具链时必须失败，实际：$r")
        assertTrue(Files.exists(root.resolve("myapp/AndroidManifest.xml")), "空目录应先被搭成项目")
        assertTrue(Files.exists(root.resolve("myapp/build_apk.sh")), "构建脚本必须落盘（可见可改）")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("aapt2"), "要指出缺哪个工具，实际：$reason")
        assertTrue(reason.contains("d8.jar"))
        assertTrue(runner.commands.isEmpty(), "前提不满足时不得起进程")
    }

    @Test
    @DisplayName("build_apk：非空但不是项目的目录**不会**被静默改写")
    fun buildApkDoesNotClobberNonEmptyDir() = runBlocking {
        Files.createDirectories(root.resolve("mine"))
        Files.writeString(root.resolve("mine/notes.txt"), "用户自己的东西")
        val r = BuildApkTool(fs, emptyToolchain, runner, null)
            .execute(mapOf("project_dir" to "mine"))

        assertTrue(r is ToolOutcome.Failure)
        assertTrue(Files.exists(root.resolve("mine/notes.txt")), "用户内容不得被动")
        assertFalse(Files.exists(root.resolve("mine/AndroidManifest.xml")), "不该悄悄建项目")
    }

    @Test
    @DisplayName("★ build_apk 的描述必须与实现一致：对齐是**进程内** ZipAligner，不是外部 zipalign（ADR-026/027）")
    fun buildApkDescriptionMatchesInProcessAligner() {
        val desc = BuildApkTool(fs, emptyToolchain, runner, null).spec.description

        // 正向：模型只能看到描述 ⇒ 必须说清"对齐由谁、在哪做"，
        // 否则模型会去找一个不存在的二进制（Android 上没有 zipalign）。
        assertTrue(desc.contains("进程内"), "描述要说清对齐在进程内完成，实际：$desc")
        assertTrue(desc.contains("ZipAligner"), "描述要点名进程内对齐器 ZipAligner，实际：$desc")

        // 反向（防回退）：zipalign **不得**再被写成流水线的一步。
        // 改前文案是 "aapt2 → javac → d8 → zipalign → apksigner" —— 箭头两侧出现它就说明回退了。
        assertFalse(
            Regex("[→>]\\s*zipalign|zipalign\\s*[→>]").containsMatchIn(desc),
            "zipalign 不许再出现在流水线里（Android 上没有它；ADR-027 对齐走进程内）：$desc",
        )
        assertFalse(
            desc.contains("有 zipalign"),
            "不许把 zipalign 说成\"有就用\"的可选项（引擎从不使用它）：$desc",
        )
    }

    // ================= 描述 ⇄ 实现 一致性门禁（P1-6） =================
    //
    // 模型**只能看到 description**：描述写错 = 教模型做错事（去装不存在的二进制、
    // 或向用户保证"跳过不影响安装"）。所以每条修过的描述各钉一个反向断言，
    // 再做一次**全量盘点** —— 以后新加的工具会自动被盘到。

    @Test
    @DisplayName("★ 全量盘点：注册表里每个工具的描述都不得把 Android 上不存在的二进制说成可用")
    fun registryDescriptionsRejectUnavailableBinaries() {
        val specs = registrySpecs()
        // 盘点必须覆盖模型能看到的全部工具：漏一个就漏一条错误描述
        assertTrue(
            specs.map { it.name }.containsAll(AndroidTools.GROUPS.keys + RESIDENT_TOOL_NAMES),
            "盘点漏了工具（长尾分组 + 常驻都要在），实际：${specs.map { it.name }}",
        )
        specs.forEach { spec ->
            assertTrue(spec.description.isNotBlank(), "${spec.name} 的描述为空：模型不知道何时该用它")
            UNAVAILABLE_ON_ANDROID.forEach { binary ->
                assertNoUsableMention(spec.name, spec.description, binary)
            }
        }
    }

    @Test
    @DisplayName("★ apk_recompile 描述：对齐由进程内 ZipAligner 做，不是流水线里的外部 zipalign")
    fun recompileDescriptionMatchesInProcessAligner() {
        val desc = ApkRecompileTool(fs, emptyToolchain, runner).spec.description
        assertTrue(desc.contains("进程内"), "要说清对齐在哪做，实际：$desc")
        assertTrue(desc.contains("ZipAligner"), "要点名进程内对齐器，实际：$desc")
        // 旧文案 "zipalign 在 apksigner 之前"：把 Android 上不存在的二进制写成流水线的一步
        assertFalse(desc.contains("zipalign"), "Android 上没有 zipalign（ADR-026/027）：$desc")
    }

    @Test
    @DisplayName("★ apk_sign 描述：对齐是**无条件**的进程内步骤，不得出现「跳过 / 不影响安装」")
    fun signDescriptionStatesUnconditionalInProcessAlignment() {
        val desc = ApkSignTool(fs, emptyToolchain, runner).spec.description
        assertTrue(
            desc.contains("进程内") && desc.contains("ZipAligner"),
            "要说清对齐由谁、在哪做，实际：$desc",
        )
        // 实现里每次 sign() 都先对齐（ApkReverseEngine.sign 没有"有没有 zipalign"这条分支）；
        // 只有对齐**抛异常**时才退回原样复制，并把原因写进步骤 —— 所以描述必须说"总是"。
        assertTrue(desc.contains("总是"), "对齐是每次签名都做的步骤，不是可选项，实际：$desc")
        assertFalse(desc.contains("跳过"), "对齐不是\"跳过\"分支（ADR-027），实际：$desc")
        assertFalse(desc.contains("不影响安装"), "不得向用户承诺\"不影响安装\"，实际：$desc")
        assertFalse(
            Regex("[→>]\\s*zipalign|zipalign\\s*[→>]").containsMatchIn(desc),
            "不许把 zipalign 写成流水线的一步，实际：$desc",
        )
    }

    @Test
    @DisplayName("★ apk_decompile 描述与行为一致：默认要 smali，缺 baksmali.jar 是失败而不是跳过")
    fun decompileDescriptionMatchesHardFailureOnMissingBaksmali() = runBlocking {
        // 造一个最小 APK：只要有 classes.dex 就会走 smali 分支
        val apk = root.resolve("tiny.apk")
        ZipOutputStream(Files.newOutputStream(apk)).use { z ->
            z.putNextEntry(ZipEntry("classes.dex"))
            z.write("dex\n035\u0000".toByteArray())
            z.closeEntry()
        }

        // 行为（实现）：空工具链 = 没有 baksmali.jar，而 with_smali 默认 true ⇒ Failure 且点名缺谁
        val r = ApkDecompileTool(fs, emptyToolchain, runner)
            .execute(mapOf("apk" to "tiny.apk", "out_dir" to "unpacked"))
        assertTrue(r is ToolOutcome.Failure, "缺 baksmali.jar 时必须失败，实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("baksmali.jar"), "失败原因要点名缺的文件，实际：$reason")

        // 描述：必须与上面这条**实际行为**一致（旧文案读起来像"没装就优雅跳过"）
        val desc = ApkDecompileTool(fs, emptyToolchain, runner).spec.description
        assertTrue(desc.contains("baksmali.jar"), "描述要点名缺谁，实际：$desc")
        assertTrue(desc.contains("失败"), "描述要如实说这是失败，实际：$desc")
        assertTrue(desc.contains("with_smali=false"), "描述要给出出路，实际：$desc")
        assertFalse(
            Regex("装了\\s*baksmali").containsMatchIn(desc),
            "不得把 smali 写成\"看装没装\"的可选项，实际：$desc",
        )
    }

    @Test
    @DisplayName("★ d8_convert 描述：堆上限取自 Contract.Toolchain.JVM_HEAP，不写死数字")
    fun d8DescriptionUsesContractHeap() {
        val desc = D8ConvertTool(fs, emptyToolchain, runner).spec.description
        assertTrue(
            desc.contains(Contract.Toolchain.JVM_HEAP),
            "堆上限必须与契约值一致（现在是 ${Contract.Toolchain.JVM_HEAP}），实际：$desc",
        )
        assertFalse(
            Regex("\\d+\\s*MB").containsMatchIn(desc),
            "不得写死 N MB（契约值一改描述就漂），实际：$desc",
        )
    }

    @Test
    @DisplayName("★ apk_sign：缺 apksigner 时说清缺谁，且不起进程（zipalign 已降级为可选）")
    fun signReportsMissingTools() = runBlocking {
        val r = ApkSignTool(fs, emptyToolchain, runner).execute(mapOf("apk" to "a.apk"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("apksigner"), "实际：$reason")
        // ★ ADR-026：zipalign 不再是签名前提（Android 上没有这个二进制）
        assertFalse(reason.contains("zipalign"), "不该再要求 zipalign：$reason")
        assertTrue(runner.commands.isEmpty())
    }

    @Test
    @DisplayName("★ d8_convert：缺 d8.jar 时明确失败（不假装转了）")
    fun d8ReportsMissingJar() = runBlocking {
        Files.createDirectories(root.resolve("classes/out"))
        val r = D8ConvertTool(fs, emptyToolchain, runner)
            .execute(mapOf("class_dir" to "classes", "out_dir" to "classes/out"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("d8.jar"))
        assertTrue(runner.commands.isEmpty())
    }

    @Test
    @DisplayName("apk_decompile：APK 不存在 → Failure（不是抛异常）")
    fun decompileMissingApkFails() = runBlocking {
        val r = ApkDecompileTool(fs, emptyToolchain, runner)
            .execute(mapOf("apk" to "nope.apk", "out_dir" to "out"))
        assertTrue(r is ToolOutcome.Failure, "实际：$r")
    }

    @Test
    @DisplayName("★ 必填参数为空 → 一律 Failure（模型漏参数是家常便饭，不能炸掉循环）")
    fun blankRequiredArgsFail() = runBlocking {
        assertTrue(
            ScaffoldAndroidTool(fs).execute(mapOf("project_dir" to " ")) is ToolOutcome.Failure
        )
        assertTrue(
            ApkDecompileTool(fs, emptyToolchain, runner).execute(mapOf("apk" to "a.apk")) is ToolOutcome.Failure
        )
        assertTrue(
            ApkRecompileTool(fs, emptyToolchain, runner).execute(mapOf("dir" to "d")) is ToolOutcome.Failure
        )
        assertTrue(
            D8ConvertTool(fs, emptyToolchain, runner)
                .execute(mapOf("class_dir" to "c", "out_dir" to " ")) is ToolOutcome.Failure
        )
    }

    // ============================================================
    // F7b（2026-10-18）：`optional = true` 的参数 —— 缺键由实现走默认值
    //
    // 为什么要有这一组：校验器以前"声明即必填"，模型少写一个键就撞
    // 「缺少必填参数」（`docs/27` §2.2 记的 build_apk 缺 out_apk 摩擦）。
    // 现在缺键放行 —— 那就必须证明**缺键真的会走到那个默认值**，
    // 否则"放行"等于把一个空值放进引擎。
    // ============================================================

    /** "看起来完整"的工具链：只为让前提校验通过，好观察引擎真正下发的命令。 */
    private val completeToolchain = ToolchainPaths(
        aapt2 = "aapt2", apksigner = "apksigner", d8Jar = "d8.jar", androidJar = "android.jar",
    )

    @Test
    @DisplayName("★ 参数名唯一：任何工具的 parameters 都不许重名（重名会产出**非法 JSON Schema**）")
    fun paramNamesAreUniqueEverywhere() {
        registrySpecs().forEach { s ->
            val names = s.parameters.map { it.name }
            assertEquals(
                names.size, names.toSet().size,
                "${s.name} 的参数名有重复：$names —— 冻结前缀里的 JSON 会出现重复键",
            )
        }
    }

    @Test
    @DisplayName("★ 参数面钉住：本轮动过的四个工具，参数**名字与顺序**一个不多一个不少")
    fun paramSurfaceOfTouchedToolsIsPinned() {
        assertEquals(
            listOf("project_dir", "package_name", "app_name"),
            ScaffoldAndroidTool(fs).spec.parameters.map { it.name },
        )
        assertEquals(
            listOf("project_dir", "out_apk"),
            BuildApkTool(fs, emptyToolchain, runner, null).spec.parameters.map { it.name },
        )
        assertEquals(
            listOf("apk", "out_dir", "with_smali"),
            ApkDecompileTool(fs, emptyToolchain, runner).spec.parameters.map { it.name },
        )
        assertEquals(
            listOf("apk", "out_apk"),
            ApkSignTool(fs, emptyToolchain, runner).spec.parameters.map { it.name },
        )
    }

    @Test
    @DisplayName("★ 真工具面：optional 参数进 properties、**不进** required（云端原生 tools 的 Schema 就靠它）")
    fun optionalParamsLeaveRequiredForRealTools() {
        registrySpecs().forEach { s ->
            val json = PrefixBuilder.canonicalToolJson(s)
            val required = json.substringAfter("\"required\":[").substringBefore("]")
            s.parameters.forEach { p ->
                assertTrue(
                    json.contains("\"${p.name}\":{\"type\""),
                    "${s.name}.${p.name} 必须留在 properties 里（省略 ≠ 不存在）：$json",
                )
                if (p.optional) {
                    assertFalse(
                        required.contains("\"${p.name}\""),
                        "${s.name}.${p.name} 标了 optional 就不许进 required：[$required]",
                    )
                } else {
                    assertTrue(
                        required.contains("\"${p.name}\""),
                        "${s.name}.${p.name} 是必填，必须在 required 里：[$required]",
                    )
                }
            }
        }
    }

    @Test
    @DisplayName("★ 可选参数白名单：**本注册表**（常驻 6 + 长尾 9）里只有这 12 个 optional=true，其余一律必填")
    fun optionalParamsAreWhitelisted() {
        val actual = registrySpecs()
            .flatMap { s -> s.parameters.filter { it.optional }.map { "${s.name}.${it.name}" } }
            .sorted()
        assertEquals(
            listOf(
                "apk_decompile.with_smali",   // 缺 ⇒ true（描述已写默认 true）
                "apk_sign.out_apk",           // 缺 ⇒ 覆盖输入包（原地重签）
                "build_apk.out_apk",          // 缺 ⇒ app-debug.apk
                "list_files.dir",             // 缺 ⇒ 工作区根
                "read_file.limit",            // 缺 ⇒ 读到末尾
                "read_file.numbered",         // 缺 ⇒ 不带行号（2026-10-19）
                "read_file.offset",           // 缺 ⇒ 从第 1 行
                "run_shell_command.cwd",      // 缺 ⇒ 工作区根
                "run_shell_command.timeout_sec", // 缺 ⇒ Contract.Shell.DEFAULT_TIMEOUT_SEC
                "scaffold_android.app_name",  // 缺 ⇒ Heracles App
                "unzip_file.dest_dir",        // 缺 ⇒ 工作区根
                "zip_file.src_dir",           // 缺 ⇒ 工作区根
            ).sorted(),
            actual,
            "可选参数集合变了：冻结前缀 hash 会变、模型看到的面也变 —— 要改就**有意识**地改这条白名单。" +
                "（注：toolsmith 的 find_files / grep_files 不在本表的注册表里，另有其测试。）",
        )
    }

    @Test
    @DisplayName("★ build_apk 缺 out_apk 不再被校验器拦下；但 project_dir 仍必须必填")
    fun buildApkWithoutOutApkPassesValidation() {
        val specs = registrySpecs()
        // ① 这就是 docs/27 §2.2 那次摩擦：模型只给 project_dir，被「缺少必填参数：out_apk」拦下
        assertEquals(
            ToolValidator.Result.Valid,
            ToolValidator.validate(ToolCall("build_apk", mapOf("project_dir" to "hello")), specs),
            "缺 out_apk 必须放行 —— 引擎与工具都有默认名",
        )
        // ② project_dir 保持必填：缺了会去构建工作区根，还可能在根上自动 scaffold 落盘
        val bad = ToolValidator.validate(ToolCall("build_apk", emptyMap()), specs)
        assertTrue(
            bad is ToolValidator.Result.Invalid && bad.detail.contains("project_dir"),
            "project_dir 缺键必须仍然被拦，实际：$bad",
        )
    }

    @Test
    @DisplayName("★ build_apk：out_apk 缺键 ⇒ 默认名 app-debug.apk **真的下发给了脚本**（与传空串同一条路）")
    fun buildApkOutApkDefaultReachesScript() = runBlocking {
        val missing = RecordingOkRunner()
        val blank = RecordingOkRunner()
        val explicit = RecordingOkRunner()

        val rMissing = BuildApkTool(fs, completeToolchain, missing, null)
            .execute(mapOf("project_dir" to "def-missing"))
        BuildApkTool(fs, completeToolchain, blank, null)
            .execute(mapOf("project_dir" to "def-blank", "out_apk" to ""))
        BuildApkTool(fs, completeToolchain, explicit, null)
            .execute(mapOf("project_dir" to "def-explicit", "out_apk" to "mine.apk"))

        assertTrue(
            missing.commands.isNotEmpty(),
            "前提校验应当通过并下发命令（否则这条用例什么都没证明）：$rMissing",
        )
        assertTrue(
            missing.commands.all { it.contains("app-debug.apk") },
            "缺键时每次调用都必须带默认名，实际：${missing.commands}",
        )
        assertEquals(
            missing.commands, blank.commands,
            "缺键与传空串必须走**同一条**默认分支（否则说明缺键被特殊对待了）",
        )
        assertTrue(explicit.commands.all { it.contains("mine.apk") }, "实际：${explicit.commands}")
        assertTrue(
            explicit.commands.none { it.contains("app-debug.apk") },
            "模型显式给的输出名不许被默认值顶掉，实际：${explicit.commands}",
        )
    }

    @Test
    @DisplayName("★ apk_sign：out_apk 缺键 ⇒ 默认**覆盖输入包本身**（原地重签），不是签到一个空名字")
    fun apkSignOutApkDefaultsToInput() = runBlocking {
        ZipOutputStream(Files.newOutputStream(root.resolve("sign-me.apk"))).use { z ->
            z.putNextEntry(ZipEntry("AndroidManifest.xml"))
            z.write("<manifest/>".toByteArray())
            z.closeEntry()
        }
        val tc = ToolchainPaths(apksigner = "apksigner")

        // 默认：产物名 = 输入包 ⇒ 文件本来就在 ⇒ 走到成功分支
        val inPlace = ApkSignTool(fs, tc, RecordingOkRunner()).execute(mapOf("apk" to "sign-me.apk"))
        assertTrue(inPlace is ToolOutcome.Success, "原地重签应当成功，实际：$inPlace")
        assertTrue(
            (inPlace as ToolOutcome.Success).detail.contains("sign-me.apk"),
            "缺键时输出应该就是输入包，实际：${inPlace.detail}",
        )

        // 对照：显式给了另一个名字，而假 runner 不会写出文件 ⇒ 实现如实报"产物不存在：<那个名字>"
        val other = ApkSignTool(fs, tc, RecordingOkRunner())
            .execute(mapOf("apk" to "sign-me.apk", "out_apk" to "signed.apk"))
        assertTrue(
            other is ToolOutcome.Failure && other.reason.contains("signed.apk"),
            "显式输出名必须被采用，实际：$other",
        )
    }

    @Test
    @DisplayName("★ scaffold_android：app_name 缺键 ⇒ 默认显示名 Heracles App 真的写进骨架")
    fun scaffoldAppNameDefaultsWhenMissing() = runBlocking {
        val r = ScaffoldAndroidTool(fs).execute(
            mapOf("project_dir" to "noname", "package_name" to "com.example.noname"),
        )
        assertTrue(r is ToolOutcome.Success, "实际：$r")
        val strings = Files.readString(root.resolve("noname/res/values/strings.xml"))
        assertTrue(strings.contains("Heracles App"), "缺键时必须走默认显示名，实际：$strings")
    }

    @Test
    @DisplayName("★ apk_decompile：with_smali=false 真的跳过 smali（与缺键=默认 true 形成对照）")
    fun decompileWithSmaliFalseSkipsSmaliBranch() = runBlocking {
        ZipOutputStream(Files.newOutputStream(root.resolve("tiny-off.apk"))).use { z ->
            z.putNextEntry(ZipEntry("classes.dex"))
            z.write("dex\n035\u0000".toByteArray())
            z.closeEntry()
        }
        // 另一条用例（decompileDescriptionMatchesHardFailureOnMissingBaksmali）证明**缺键**时
        // 默认 true ⇒ 缺 baksmali.jar 硬失败；这一条证明显式 false 时那条分支真的不走。
        val off = ApkDecompileTool(fs, emptyToolchain, runner)
            .execute(
                mapOf("apk" to "tiny-off.apk", "out_dir" to "unpacked-off", "with_smali" to "false"),
            )
        assertTrue(off is ToolOutcome.Success, "显式关掉 smali 时不该再因缺 baksmali.jar 失败，实际：$off")
        assertTrue(Files.exists(root.resolve("unpacked-off/classes.dex")), "解包产物必须落盘")
    }

    /** 常驻工具名（与 `AgentBridge` 的装配同源）—— 全量盘点必须覆盖它们。 */
    private val RESIDENT_TOOL_NAMES = listOf(
        "list_files", "read_file", "write_file", "mkdir", "save_memory", "run_shell_command",
    )
    /**
     * 模型能看到的**全部** [ToolSpec]：常驻（进冻结区）+ 长尾（`search_tools` 披露后）。
     *
     * 与 `AgentBridge` 的装配同源（常驻 6 + 长尾 9）；`search_tools` 自己**不在**注册表里
     * （它是披露机制入口，放进去会形成"永远搜得到自己"的循环）。
     */
    private fun registrySpecs(): List<ToolSpec> {
        val resident = listOf(
            ListFilesTool(fs), ReadFileTool(fs), WriteFileTool(fs),
            MkdirTool(fs), SaveMemoryTool(fs), RunShellCommandTool(runner, fs),
        )
        val longTail = AndroidTools.create(fs, emptyToolchain, runner) +
            listOf(UnzipFileTool(fs), ZipFileTool(fs), ApplyPatchTool(fs))
        return ToolRegistry(
            resident = resident.map { it.spec },
            longTail = longTail.map { it.spec },
            groups = AndroidTools.GROUPS,
        ).all
    }

    /**
     * 描述里提到 [binary] 的**小句**必须是否定语境（[NEGATIONS]）—— 否则就是在指路：
     * 模型会去找那个不存在的二进制，甚至据此向用户承诺"不影响安装"（ADR-026 禁止的假象）。
     */
    private fun assertNoUsableMention(toolName: String, desc: String, binary: String) {
        val clauses = desc.split(Regex("[，。；、：（）()；]"))
        clauses.filter { it.contains(binary) }.forEach { clause ->
            assertTrue(
                NEGATIONS.any { clause.contains(it) },
                "$toolName 的描述把 $binary 说成可用/必需的了（只允许出现在否定语境里）：$clause",
            )
        }
    }

    // ------------------------------------------- 非 POSIX 工作区拒绝（F6a / ADR-032）

    /**
     * 内存版工作区替身 —— SAF 语义（默认 `hasRealPath=false`）或 POSIX 语义。
     *
     * 支持 F6b 需要的字节通道，并记录"读过/写过哪些文件"：
     * 镜像路径的断言要靠 [reads]（镜像**真的发生**了吗），回写路径靠 [writes]。
     */
    private class MemoryFs(
        seeds: Map<String, ByteArray> = emptyMap(),
        hasRealPath: Boolean = false,
    ) : WorkspaceFs {

        override val info = WorkspaceInfo(
            Paths.get("/placeholder-not-a-workspace"),
            "mem-workspace",
            hasRealPath = hasRealPath,
        )

        val files = linkedMapOf<String, ByteArray>().apply { putAll(seeds) }
        val reads = mutableListOf<String>()
        val writes = linkedMapOf<String, ByteArray>()
        private val emptyDirs = linkedSetOf<String>()

        override suspend fun list(relativeDir: String): List<FileEntry> {
            val dir = relativeDir.trim().trim('/')
            val prefix = if (dir.isEmpty()) "" else "$dir/"
            val found = linkedMapOf<String, FileEntry>()
            val childDirs = linkedSetOf<String>()
            for (p in files.keys) {
                if (!p.startsWith(prefix)) continue
                val rest = p.removePrefix(prefix)
                if (rest.isEmpty()) continue
                val slash = rest.indexOf('/')
                if (slash >= 0) childDirs += prefix + rest.substring(0, slash)
                else found[p] = FileEntry(p, files.getValue(p).size.toLong(), false)
            }
            for (d in emptyDirs) {
                if (!d.startsWith(prefix) || d == dir) continue
                val rest = d.removePrefix(prefix)
                val slash = rest.indexOf('/')
                if (slash >= 0) childDirs += prefix + rest.substring(0, slash) else childDirs += d
            }
            for (d in childDirs) found[d] = FileEntry(d, 0L, true)
            return found.values.sortedWith(compareBy({ !it.isDirectory }, { it.relativePath }))
        }

        override suspend fun readText(relativePath: String): String =
            String(readBytes(relativePath), Charsets.UTF_8)

        override suspend fun writeText(relativePath: String, content: String): Long =
            writeBytes(relativePath, content.toByteArray(Charsets.UTF_8))

        override suspend fun exists(relativePath: String): Boolean {
            val p = relativePath.trim().trim('/')
            if (p.isEmpty()) return true
            return p in files || p in emptyDirs || files.keys.any { it.startsWith("$p/") }
        }

        override suspend fun mkdirs(relativeDir: String) {
            val p = relativeDir.trim().trim('/')
            if (p.isNotEmpty()) emptyDirs += p
        }

        override suspend fun readBytes(relativePath: String): ByteArray {
            reads += relativePath
            return files[relativePath] ?: throw IllegalArgumentException("文件不存在：$relativePath")
        }

        override suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long {
            writes[relativePath] = bytes
            files[relativePath] = bytes
            return bytes.size.toLong()
        }
    }

    @Test
    @DisplayName("★ 非 POSIX：构建入口**先拒绝**（可执行文案），且不报成'工具链不完整'（顺序对了）")
    fun nonPosixRejectsBuildBeforeAnythingElse() = runBlocking {
        val r = AndroidBuildEngine(runner, MemoryFs(), emptyToolchain).build("")

        assertFalse(r.ok, "非 POSIX 工作区必须拒绝构建")
        val reason = r.reason.orEmpty()
        assertTrue(reason.contains("没有真实文件路径"), "要说明真原因：$reason")
        assertTrue(reason.contains("默认工作区"), "要给出可执行的出路（一）：$reason")
        assertTrue(reason.contains("真实路径的位置"), "要给出可执行的出路（二）：$reason")
        assertFalse(
            reason.contains("工具链不完整"),
            "⓪ 工作区检查必须先于 ① 工具链检查 —— 否则模型会去补一个根本用不上的工具链：$reason",
        )
        assertTrue(runner.commands.isEmpty(), "拒绝必须发生在起进程之前")
    }

    @Test
    @DisplayName("★ 非 POSIX：逆向四入口（decompile/recompile/sign/d8）与 ensureKeystore 同样拒绝")
    fun nonPosixRejectsAllReverseEntries() = runBlocking {
        val engine = ApkReverseEngine(runner, MemoryFs(), emptyToolchain)

        listOf(
            "decompile" to engine.decompile("a.apk", "out"),
            "recompile" to engine.recompile("dir", "out.apk"),
            "sign" to engine.sign("a.apk", "out.apk"),
            "d8" to engine.d8("classes", "out-dex"),
        ).forEach { (name, outcome) ->
            assertFalse(outcome.ok, "$name 必须拒绝非 POSIX 工作区")
            assertTrue(
                outcome.reason.orEmpty().contains("没有真实文件路径"),
                "$name 的拒绝文案要说明原因：${outcome.reason}",
            )
        }

        val e = org.junit.jupiter.api.assertThrows<IllegalStateException> {
            runBlocking { AndroidBuildEngine(runner, MemoryFs(), emptyToolchain).ensureKeystore() }
        }
        assertTrue(e.message.orEmpty().contains("默认工作区"), "ensureKeystore 也要给可执行出路：${e.message}")
        assertTrue(runner.commands.isEmpty(), "所有拒绝都必须发生在起进程之前")
    }

    @Test
    @DisplayName("★ 非 POSIX：工具层（build_apk）把拒绝**如实**转成 Failure，且不谎称是别的问题")
    fun nonPosixSurfacesThroughToolLayer() = runBlocking {
        val r = BuildApkTool(MemoryFs(), emptyToolchain, runner, null)
            .execute(mapOf("project_dir" to "", "out_apk" to ""))

        assertTrue(r is ToolOutcome.Failure, "非 POSIX 必须失败，实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("没有真实文件路径"), "工具层必须原样透出可执行文案：$reason")
    }

    @Test
    @DisplayName("★ POSIX 零回退：检查顺序与报错与改动前一致（不是被工作区检查误杀）")
    fun posixBehaviorIsUnchanged() = runBlocking {
        // ① 空目录：与改动前一样，先报"没有 AndroidManifest.xml"
        val empty = AndroidBuildEngine(runner, fs, emptyToolchain).build("")
        assertFalse(empty.ok)
        assertTrue(
            empty.reason.orEmpty().contains("AndroidManifest.xml"),
            "POSIX 空目录的报错必须与改动前一致：${empty.reason}",
        )
        assertFalse(empty.reason.orEmpty().contains("没有真实文件路径"), "POSIX 不许被误判成 SAF")

        // ② 真有项目、缺工具链：与改动前一样报"工具链不完整"
        AndroidProjectScaffold(fs).create("app", "com.example.app", "App")
        val noToolchain = AndroidBuildEngine(runner, fs, emptyToolchain).build("app")
        assertFalse(noToolchain.ok)
        assertTrue(
            noToolchain.reason.orEmpty().contains("工具链不完整"),
            "POSIX 缺工具链的报错必须与改动前一致：${noToolchain.reason}",
        )
    }

    // ------------------------------------------- SAF：镜像 → staging 构建（F6b / ADR-032）

    private fun manifest() = "<manifest/>".toByteArray(Charsets.UTF_8)

    /** F9b：一份最小合法的工作区 profile（字段与 `BuildProfileLoader` 的 schema version 1 对齐）。 */
    private fun workspaceProfileJson(id: String, displayName: String) = """
        {
          "schemaVersion": 1,
          "id": "$id",
          "displayName": "$displayName",
          "probe": { "manifestFile": "AndroidManifest.xml" },
          "buildScriptName": "build_apk.sh",
          "steps": [
            { "id": "PREPARE", "title": "prepare", "fixedDetail": "（aapt2 compile → link → javac → d8）" },
            { "id": "INSERT_DEX", "title": "插入 classes.dex", "inProcess": true },
            { "id": "ALIGN", "title": "进程内对齐", "inProcess": true },
            { "id": "PACKAGE", "title": "package", "fixedDetail": "（对齐 → apksigner）" }
          ],
          "artifact": { "defaultName": "app-debug.apk" }
        }
    """.trimIndent()

    @Test
    @DisplayName("★ SAF + 未配置 stagingRoot ⇒ 明确说是**装配问题**（不悄悄拿占位路径构建）")
    fun safWithoutStagingRootExplainsWiringBug() = runBlocking {
        val saf = MemoryFs(mapOf("AndroidManifest.xml" to manifest()))
        val r = AndroidBuildEngine(runner, saf, emptyToolchain).build("")

        assertFalse(r.ok)
        val reason = r.reason.orEmpty()
        assertTrue(reason.contains("临时目录"), "要点名是装配处没给临时目录：$reason")
        assertTrue(reason.contains("默认工作区"), "要给出可执行出路（一）：$reason")
        assertTrue(reason.contains("真实路径的位置"), "要给出可执行出路（二）：$reason")
        assertTrue(saf.reads.isEmpty(), "装配错误下不该镜像任何东西")
        assertTrue(runner.commands.isEmpty(), "也不该起进程")
    }

    @Test
    @DisplayName("★ SAF 没有 Android 项目 ⇒ **不镜像**（别把无关文件拷进 staging）")
    fun safNonProjectIsNotMirrored() = runBlocking {
        val saf = MemoryFs(mapOf("notes.txt" to "hi".toByteArray(Charsets.UTF_8)))
        val stagingRoot = createTempDirectory("stg-nonproject")
        val r = AndroidBuildEngine(runner, saf, emptyToolchain, stagingRoot = stagingRoot).build("")

        assertFalse(r.ok)
        assertTrue(
            r.reason.orEmpty().contains("AndroidManifest.xml"),
            "要说清缺的是清单：${r.reason}",
        )
        assertTrue(saf.reads.isEmpty(), "非项目目录不许镜像")
        assertEquals(0L, Files.list(stagingRoot).use { it.count() }, "staging 根下不该留下任何东西")
    }

    @Test
    @DisplayName("★ SAF 回写目标已存在 ⇒ 失败不覆盖，且在**镜像之前**就拒绝（不做无用功）")
    fun safExistingArtifactIsRefusedBeforeMirroring() = runBlocking {
        val saf = MemoryFs(
            mapOf(
                "AndroidManifest.xml" to manifest(),
                "app-debug.apk" to "user's own file".toByteArray(Charsets.UTF_8),
            ),
        )
        val stagingRoot = createTempDirectory("stg-exists")
        val r = AndroidBuildEngine(runner, saf, emptyToolchain, stagingRoot = stagingRoot).build("")

        assertFalse(r.ok)
        assertTrue(r.reason.orEmpty().contains("已存在"), "要如实说目标已存在：${r.reason}")
        assertTrue(r.reason.orEmpty().contains("out_apk"), "要给出换名字的出路：${r.reason}")
        assertTrue(saf.reads.isEmpty(), "目标冲突必须在镜像前发现")
        assertEquals(0L, Files.list(stagingRoot).use { it.count() }, "不该为一次注定失败的构建建 staging")
        // ★ 用户文件一字不动（不覆盖）
        assertEquals(
            "user's own file".toByteArray(Charsets.UTF_8).toList(),
            saf.files.getValue("app-debug.apk").toList(),
        )
    }

    @Test
    @DisplayName("★ SAF：镜像 → 内层构建失败 ⇒ 原因透出、镜像确实发生、staging **被清干净**")
    fun safMirrorsThenCleansUpOnFailure() = runBlocking {
        val saf = MemoryFs(
            mapOf(
                "app/AndroidManifest.xml" to manifest(),
                "app/src/Main.java" to "class Main {}".toByteArray(Charsets.UTF_8),
            ),
        )
        val stagingRoot = createTempDirectory("stg-cleanup")
        val r = AndroidBuildEngine(
            runner, saf, emptyToolchain, stagingRoot = stagingRoot,
            // 镜像失败/内层失败都要清 staging —— 给个最小工厂（空工具链会在起进程前失败）
            stagingRunnerFactory = { NeverRunner() },
        ).build("app")

        assertFalse(r.ok)
        assertTrue(
            r.reason.orEmpty().contains("工具链不完整"),
            "内层引擎的失败原因必须透出（说明镜像成功、内层真的跑到了校验）：${r.reason}",
        )
        assertTrue(
            r.reason.orEmpty().contains("staging 已清理"),
            "失败时必须如实说明 staging 已清理：${r.reason}",
        )
        assertTrue(
            saf.reads.any { it.endsWith("AndroidManifest.xml") },
            "镜像必须真的读过用户工作区里的文件：${saf.reads}",
        )
        // ★ 最容易被漏测的一条：失败路径也必须把 staging 清干净
        assertEquals(0L, Files.list(stagingRoot).use { it.count() }, "失败后 staging 必须是空的")
        assertTrue(runner.commands.isEmpty(), "空工具链应在起进程前失败")
    }

    @Test
    @DisplayName("★ POSIX 零回退：即便配了 stagingRoot，仍在原地构建（不建 staging、报错与改造前一致）")
    fun posixIgnoresStagingRoot() = runBlocking {
        val stagingRoot = createTempDirectory("stg-posix")
        val r = AndroidBuildEngine(runner, fs, emptyToolchain, stagingRoot = stagingRoot).build("")

        assertFalse(r.ok)
        assertTrue(
            r.reason.orEmpty().contains("AndroidManifest.xml"),
            "POSIX 的报错必须与改动前同一句：${r.reason}",
        )
        assertFalse(r.reason.orEmpty().contains("没有真实文件路径"), "POSIX 不许走 SAF 分支")
        assertEquals(0L, Files.list(stagingRoot).use { it.count() }, "POSIX 路径不该用 staging")
    }

    @Test
    @DisplayName("★ SAF：装配处没给 staging runner ⇒ 明确装配错误（别静默跑到用户工作区去）")
    fun safWithoutStagingRunnerFailsExplicitly() = runBlocking {
        val saf = MemoryFs(mapOf("AndroidManifest.xml" to manifest()))
        val r = AndroidBuildEngine(
            runner, saf, emptyToolchain, stagingRoot = createTempDirectory("stg-norunner"),
        ).build("")

        assertFalse(r.ok)
        assertTrue(
            r.reason.orEmpty().contains("执行通道"),
            "要点名缺的是 SAF 构建的执行通道：${r.reason}",
        )
        assertTrue(saf.reads.isEmpty(), "装配错误下不该镜像")
    }

    @Test
    @DisplayName("★ SAF：staging 构建必须用**映射到 staging 的 runner**（外层用户工作区 runner 不许被用）")
    fun safUsesStagingRunnerNotWorkspaceRunner() = runBlocking {
        val saf = MemoryFs(mapOf("AndroidManifest.xml" to manifest()))
        val stagingRoot = createTempDirectory("stg-runner")
        // 有"工具链"（路径是假的）⇒ 内层会真的走到 runner.run(prepare)
        val dummyToolchain = ToolchainPaths(
            aapt2 = "/fake/aapt2",
            apksigner = "/fake/apksigner",
            d8Jar = "/fake/d8.jar",
            androidJar = "/fake/android.jar",
        )
        val stagingRunner = object : ShellRunner {
            val calls = mutableListOf<Pair<String, String?>>()
            override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
                calls += command to cwd
                return ShellResult(3, "", "staging 探针：故意让 prepare 失败", false, 1L)
            }
        }

        val r = AndroidBuildEngine(
            runner = runner,
            fs = saf,
            toolchain = dummyToolchain,
            stagingRoot = stagingRoot,
            stagingRunnerFactory = { stagingRunner },
        ).build("")

        assertFalse(r.ok)
        assertTrue(runner.commands.isEmpty(), "外层（用户工作区）runner 不许被 staging 构建用到：${runner.commands}")
        assertTrue(stagingRunner.calls.isNotEmpty(), "staging 构建必须走 staging runner")
        assertTrue(
            stagingRunner.calls.first().first.contains("build_apk.sh"),
            "命令里应包含构建脚本：${stagingRunner.calls.first()}",
        )
        assertTrue(
            r.reason.orEmpty().contains("staging 已清理"),
            "失败必须如实说明 staging 已清理：${r.reason}",
        )
        assertEquals(0L, Files.list(stagingRoot).use { it.count() }, "失败后 staging 必须清空")
    }

    // ------------------------------------------- 工作区 profile（F9b）

    @Test
    @DisplayName("★ F9b：工作区 profile 坏了 ⇒ 明确 Failure（点名文件与字段），**不静默回退**、不跑命令")
    fun invalidWorkspaceProfileIsHonestFailure() = runBlocking {
        val broken = MemoryFs(
            mapOf(
                "AndroidManifest.xml" to manifest(),
                ".heracles/build-profile.json" to
                    """{ "schemaVersion": 1, "id": "x", "unknownField": 1 }""".toByteArray(Charsets.UTF_8),
            ),
        )
        val r = BuildApkTool(broken, emptyToolchain, runner, null)
            .execute(mapOf("project_dir" to "", "out_apk" to ""))

        assertTrue(r is ToolOutcome.Failure, "坏配置必须失败，实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("构建剖面配置无效"), "要明说是配置问题：$reason")
        assertTrue(reason.contains(".heracles/build-profile.json"), "要点名配置文件：$reason")
        assertTrue(reason.contains("unknownField"), "要点名未知字段（拼错最难查）：$reason")
        assertTrue(runner.commands.isEmpty(), "配置都没读通就不该跑任何命令：${runner.commands}")
    }

    @Test
    @DisplayName("★ F9b：工作区 profile 生效 ⇒ 结果里**留痕来源**（覆盖内置必须看得见）")
    fun workspaceProfileOverrideIsTraceable() = runBlocking {
        val override = MemoryFs(
            mapOf(
                "AndroidManifest.xml" to manifest(),
                ".heracles/build-profile.json" to
                    workspaceProfileJson("android", "自定义剖面").toByteArray(Charsets.UTF_8),
            ),
            // POSIX 语义：本测试要验的是"越过探测、停在工具链检查"，别让它走 SAF staging 分支
            hasRealPath = true,
        )
        // 空工具链 ⇒ 越过探测后必停在"工具链不完整"；用它证明 profile 已被采纳（不必构建成功也能留痕）
        val r = BuildApkTool(override, emptyToolchain, runner, null)
            .execute(mapOf("project_dir" to "", "out_apk" to ""))

        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("工具链不完整"), "应当走到引擎校验：$reason")
        assertTrue(reason.contains("来源：.heracles/build-profile.json"), "覆盖内置必须留痕（看不见的分歧）：$reason")
        assertTrue(reason.contains("android"), "要写出用的是哪份 profile id：$reason")
    }

    @Test
    @DisplayName("★ F9b：工作区没有 profile ⇒ 内置 Android，且**不留来源痕**（零行为变化）")
    fun noWorkspaceProfileMeansBuiltInAndNoNote() = runBlocking {
        val plain = MemoryFs(mapOf("AndroidManifest.xml" to manifest()), hasRealPath = true)
        val r = BuildApkTool(plain, emptyToolchain, runner, null)
            .execute(mapOf("project_dir" to "", "out_apk" to ""))

        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("工具链不完整"), "内置 profile 行为不变：$reason")
        assertFalse(reason.contains("本机构建剖面"), "没配置文件就不该有来源痕：$reason")
    }
}

/**
 * **前台服务自启停**的工具层门禁 —— `26` §7.1、`实测-12` §13.4。
 *
 * 这一层管的是"任务什么时候开始、什么时候结束"（`build_apk` 动辄几分钟，
 * 用户必然切走；没有前台服务就是半路被 LMK 杀）。引擎里**不管**这件事
 * （`:toolchain` 是纯 JVM，连 `android.*` 都不许 import）——
 * 所以"起止"的正确性只能在这一层钉。
 *
 * 用假工具而不是真构建：这里要验的是**生命周期**，不是"能不能编译 Java"。
 */
class ProgressReportingToolTest {

    /** 记录回调顺序，供断言"成对、且 finish 一定在"。 */
    private class Recorder : TaskProgress {
        val events = mutableListOf<String>()

        override fun start(task: String) {
            events.add("start:$task")
        }

        override fun step(text: String) {
            events.add("step:$text")
        }

        override fun finish(ok: Boolean, summary: String) {
            events.add("finish:$ok:$summary")
        }
    }

    private class OkTool : AgentTool {
        override val spec = ToolSpec("ok_tool", "测试用")
        override suspend fun execute(args: Map<String, String>) =
            ToolOutcome.Success("构建成功：hello/app-debug.apk\n✓ prepare\n✓ package")
    }

    private class FailTool : AgentTool {
        override val spec = ToolSpec("fail_tool", "测试用")
        override suspend fun execute(args: Map<String, String>) =
            ToolOutcome.Failure("构建在 prepare 阶段失败（exit=1）\n已完成阶段：\n✗ prepare")
    }

    private class ApprovalTool : AgentTool {
        override val spec = ToolSpec("approval_tool", "测试用")
        override suspend fun execute(args: Map<String, String>) =
            ToolOutcome.NeedsApproval("要装到设备上，用户得先点确认")
    }

    private class ThrowTool : AgentTool {
        override val spec = ToolSpec("throw_tool", "测试用")
        override suspend fun execute(args: Map<String, String>): ToolOutcome =
            throw IllegalStateException("引擎炸了")
    }

    private fun wrap(tool: AgentTool, rec: Recorder) =
        ProgressReportingTool(tool, rec) { a -> "正在干活：${a["project_dir"].orEmpty()}" }

    @Test
    @DisplayName("★ 成功：start → finish(ok=true)，且摘要只取**第一行**（通知栏是一行）")
    fun successPairsStartAndFinish() = runBlocking {
        val rec = Recorder()
        val r = wrap(OkTool(), rec).execute(mapOf("project_dir" to "hello"))

        assertTrue(r is ToolOutcome.Success, "实际：$r")
        assertEquals(
            listOf(
                "start:正在干活：hello",
                // ★ 整段 message 是多行的，通知栏只能显示一行 ⇒ 只取首行，不许被截成半句
                "finish:true:构建成功：hello/app-debug.apk",
            ),
            rec.events,
        )
    }

    @Test
    @DisplayName("★ 失败：也要 finish（少一次 = 通知栏永远挂着\"正在构建\"）")
    fun failureAlsoFinishes() = runBlocking {
        val rec = Recorder()
        val r = wrap(FailTool(), rec).execute(emptyMap())

        assertTrue(r is ToolOutcome.Failure, "实际：$r")
        assertEquals(
            listOf(
                "start:正在干活：",
                "finish:false:构建在 prepare 阶段失败（exit=1）",
            ),
            rec.events,
        )
    }

    @Test
    @DisplayName("★ 抛异常：先 finish(false) 再把异常**原样**抛出（不改写上层语义）")
    fun throwFinishesAndRethrows() {
        val rec = Recorder()
        val ex = org.junit.jupiter.api.assertThrows<IllegalStateException> {
            runBlocking { wrap(ThrowTool(), rec).execute(emptyMap()) }
        }
        assertEquals("引擎炸了", ex.message, "异常必须原样抛出，不许换成别的")
        assertEquals(
            listOf("start:正在干活：", "finish:false:IllegalStateException: 引擎炸了"),
            rec.events,
        )
    }

    @Test
    @DisplayName("★ NeedsApproval 按\"未成功\"收尾（这次调用没做事，别留假进度）")
    fun approvalIsNotSuccess() = runBlocking {
        val rec = Recorder()
        wrap(ApprovalTool(), rec).execute(emptyMap())
        assertEquals(
            listOf("start:正在干活：", "finish:false:需要确认：要装到设备上，用户得先点确认"),
            rec.events,
        )
    }

    @Test
    @DisplayName("规格原样透出（分组表 / 冻结区判定看到的还是内层工具）")
    fun specIsDelegated() {
        val rec = Recorder()
        assertEquals("ok_tool", wrap(OkTool(), rec).spec.name)
        assertEquals("fail_tool", wrap(FailTool(), rec).spec.name)
    }

    @Test
    @DisplayName("★ 不传 progress ⇒ **不加壳**；传了 ⇒ 长任务都加壳、脚手架不加")
    fun wrappingIsExplicit() {
        val (fs, runner) = fixture()
        val bare = AndroidTools.create(fs, ToolchainPaths(), runner)
        assertTrue(
            bare.none { it is ProgressReportingTool },
            "CLI/测试路径不该多一层对象（回归面必须为零）",
        )

        val wrapped = AndroidTools.create(fs, ToolchainPaths(), runner, progress = Recorder())
        val byName = wrapped.associateBy { it.spec.name }
        assertTrue(
            byName.getValue("build_apk") is ProgressReportingTool &&
                byName.getValue("apk_decompile") is ProgressReportingTool &&
                byName.getValue("apk_recompile") is ProgressReportingTool &&
                byName.getValue("apk_sign") is ProgressReportingTool &&
                byName.getValue("d8_convert") is ProgressReportingTool,
            "5 个长任务都要挂前台服务生命周期",
        )
        // 脚手架只写几个文件（毫秒级）—— 包了通知栏会闪一下又没，像 bug
        assertTrue(byName.getValue("scaffold_android") !is ProgressReportingTool)
        AndroidTools.assertConsistent(wrapped)
    }

    @Test
    @DisplayName("oneLine：首行 + 压空白 + 超长截断（通知栏只有一行）")
    fun oneLineFlattens() {
        assertEquals("构建失败：缺 aapt2", oneLine("\n\n  构建失败：缺   aapt2  \n后续"))
        assertEquals("没有内容", oneLine("没有内容"))
        assertEquals("", oneLine("\n \n"))
        val long = "字".repeat(200)
        val cut = oneLine(long, maxChars = 10)
        assertEquals(10, cut.length, "截断后长度必须受 maxChars 约束，实际：$cut")
        assertTrue(cut.endsWith("…"), "截断要有省略号：$cut")
    }

    private fun fixture(): Pair<RealWorkspaceFs, ShellRunner> {
        val root = createTempDirectory("progress-tools")
        return RealWorkspaceFs.open(root) to NeverRunner()
    }
}
