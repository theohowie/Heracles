package dev.heracles.toolchain

import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import dev.heracles.core.progress.TaskProgress
import dev.heracles.workspace.RealWorkspaceFs
import dev.heracles.workspace.ZipFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory

/**
 * 假 runner：**只记命令**，按需要把产物"写"出来（真磁盘），并把 smali/对齐要读的文件补齐。
 *
 * 不真的起 JVM —— 这里要钉的是**契约**（调了什么、参数是什么、缺件时怎么报），
 * 真跑 smali 已经在 PC 与真机上各验过一次（`实测-12` §10）。
 */
private class RecordingRunner(
    private val root: Path,
    /** 遇到这些子串就返回非 0（用来验"失败要如实报"） */
    private val failOn: List<String> = emptyList(),
) : ShellRunner {

    val commands = mutableListOf<String>()

    override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
        commands.add(command)
        if (failOn.any { command.contains(it) }) {
            return ShellResult(1, "", "boom", false, 1L)
        }
        // 把产物落到磁盘上 —— 后面的步骤（ZIP 读取、产物存在性校验）要靠它
        quotedAfter(command, "-o ")?.let { writeFile(it, "DEX") }
        quotedAfter(command, "--out ")?.let { writeFile(it, "APK") }
        return ShellResult(0, "ok", "", false, 1L)
    }

    private fun quotedAfter(command: String, flag: String): String? {
        val i = command.indexOf(flag)
        if (i < 0) return null
        val start = command.indexOf('"', i + flag.length)
        if (start < 0) return null
        val end = command.indexOf('"', start + 1)
        if (end < 0) return null
        return command.substring(start + 1, end)
    }

    private fun writeFile(path: String, content: String) {
        val p = if (java.io.File(path).isAbsolute) Path.of(path) else root.resolve(path)
        p.parent?.let { Files.createDirectories(it) }
        if (!Files.exists(p)) Files.writeString(p, content)
    }

    /** 命令里出现过 [needle] 吗 */
    fun saw(needle: String): Boolean = commands.any { it.contains(needle) }
}

/**
 * `ApkReverseEngine` 的**目录约定**门禁 —— `26` §6.3。
 *
 * ## 为什么单独立一个文件
 *
 * 这里钉的不是"能不能跑起来"，而是**两侧（反汇编/汇编）用不用同一套约定**。
 * 2026-10-16 真机补上 `baksmali.jar` 之后暴露过一个**静默忽略**：
 *
 * - `decompile` 摊开后目录里**同时**有 `classes.dex`（解包来的）和 `smali/`（反汇编来的）
 * - 旧的 `recompile` 判据是"有 `smali/` **且没有** `classes.dex`" ⇒ 永远为假
 * - 于是模型改了 smali，重打包却把**原始 dex** 装回去：`ok=true`、装成功、界面不动
 *
 * 那是仓库明令禁止的假信息（门禁 G15）。本文件的每一条都在防它复发。
 */
class ApkReverseEngineTest {

    private val root: Path = createTempDirectory("rev-engine")
    private val fs = RealWorkspaceFs.open(root)

    private fun write(rel: String, text: String = "x") {
        val p = root.resolve(rel)
        p.parent?.let { Files.createDirectories(it) }
        Files.writeString(p, text)
    }

    private fun withToolchain(smaliJar: String? = "smali.jar", baksmaliJar: String? = "baksmali.jar") =
        ToolchainPaths(
            apksigner = "apksigner",
            keystore = "k.jks",
            baksmaliJar = baksmaliJar,
            smaliJar = smaliJar,
        )

    // ---------- recompile：smali 是权威来源 ----------

    @Test
    @DisplayName("★ smali/ 存在就【必须】汇编 —— 哪怕 classes.dex 还在（防静默丢弃模型的改动）")
    fun smaliIsAssembledEvenWhenClassesDexStillExists() = runBlocking {
        write("d/classes.dex", "旧 dex")
        write("d/smali/com/example/App.smali", ".class public LApp;")
        val runner = RecordingRunner(root)

        val out = ApkReverseEngine(runner, fs, withToolchain()).recompile("d", "out.apk")

        assertTrue(
            runner.saw("com.android.tools.smali.smali.Main assemble"),
            "smali/ 在就必须汇编，实际命令：${runner.commands}",
        )
        assertTrue(runner.saw("\"d/smali\"") && runner.saw("\"d/classes.dex\""), "参数要指对目录与产物")
        assertTrue(out.ok, "重打包应当成功：${out.reason}")
    }

    @Test
    @DisplayName("★ 缺 smali.jar 且 smali/ 存在 → 明确失败（不得退回用现成的旧 dex）")
    fun missingSmaliJarFailsInsteadOfSilentlyUsingStaleDex() = runBlocking {
        write("d/classes.dex", "旧 dex")
        write("d/smali/com/example/App.smali", ".class public LApp;")
        val runner = RecordingRunner(root)

        val out = ApkReverseEngine(runner, fs, withToolchain(smaliJar = null)).recompile("d", "out.apk")

        assertFalse(out.ok, "缺 smali.jar 却报成功 = 把改动丢了还说自己做了")
        assertTrue(out.reason.orEmpty().contains("smali.jar"), "要点名缺谁：${out.reason}")
        assertFalse(runner.saw("assemble"), "没 jar 就不该起进程")
    }

    @Test
    @DisplayName("只有 classes.dex（只改资源那条路）→ 不碰汇编器，照常重打包")
    fun dexOnlyRepacksWithoutAssembling() = runBlocking {
        write("d/classes.dex", "dex")
        write("d/res/values/strings.xml", "<resources/>")
        val runner = RecordingRunner(root)

        val out = ApkReverseEngine(runner, fs, withToolchain()).recompile("d", "out.apk")

        assertTrue(out.ok, "实际：${out.reason}")
        assertFalse(runner.saw("assemble"), "没有 smali/ 就不该调汇编器：${runner.commands}")
    }

    @Test
    @DisplayName("★ 多 dex：smali/ → classes.dex，smali_classes2/ → classes2.dex（两侧映射一致）")
    fun multiDexSmaliDirsMapToDexNames() = runBlocking {
        write("d/smali/com/example/A.smali")
        write("d/smali_classes2/com/example/B.smali")
        write("d/smali_classes3/com/example/C.smali")
        val runner = RecordingRunner(root)

        val out = ApkReverseEngine(runner, fs, withToolchain()).recompile("d", "out.apk")

        assertTrue(out.ok, "实际：${out.reason}")
        assertTrue(runner.saw("\"d/smali\" -o \"d/classes.dex\""), "第一个 dex：${runner.commands}")
        assertTrue(runner.saw("\"d/smali_classes2\" -o \"d/classes2.dex\""), "classes2：${runner.commands}")
        assertTrue(runner.saw("\"d/smali_classes3\" -o \"d/classes3.dex\""), "classes3：${runner.commands}")
    }

    @Test
    @DisplayName("既没有 smali/ 也没有 classes.dex → 明确说\"这不是能重打包的目录\"")
    fun neitherSmaliNorDexIsRejected() = runBlocking {
        write("d/AndroidManifest.xml", "<manifest/>")
        val out = ApkReverseEngine(RecordingRunner(root), fs, withToolchain()).recompile("d", "out.apk")
        assertFalse(out.ok)
        assertTrue(out.reason.orEmpty().contains("classes.dex"), "实际：${out.reason}")
    }

    @Test
    @DisplayName("汇编失败要如实报（exit≠0 不能算成功）")
    fun assembleFailureIsReported() = runBlocking {
        write("d/smali/com/example/App.smali")
        val runner = RecordingRunner(root, failOn = listOf("assemble"))
        val out = ApkReverseEngine(runner, fs, withToolchain()).recompile("d", "out.apk")
        assertFalse(out.ok)
        assertTrue(out.reason.orEmpty().contains("smali"), "实际：${out.reason}")
    }

    // ---------- decompile：每个 dex 一个目录 ----------

    @Test
    @DisplayName("★ 多 dex 摊开：每个 dex 进【自己的】smali 目录（不再互相覆盖）")
    fun decompileGivesEachDexItsOwnSmaliDir() = runBlocking {
        write("src/classes.dex", "DEX1")
        write("src/classes2.dex", "DEX2")
        ZipFs(root).zip("src", "app.apk")

        val runner = RecordingRunner(root)
        val out = ApkReverseEngine(runner, fs, withToolchain())
            .decompile("app.apk", "out", withSmali = true)

        assertTrue(out.ok, "实际：${out.reason}")
        assertTrue(runner.saw("disassemble \"out/classes.dex\" -o \"out/smali\""), "第一个：${runner.commands}")
        assertTrue(runner.saw("disassemble \"out/classes2.dex\" -o \"out/smali_classes2\""), "第二个：${runner.commands}")
    }

    @Test
    @DisplayName("缺 baksmali.jar 且要求 smali → 失败但**保留摊开结果**（并点名缺谁）")
    fun decompileWithoutBaksmaliFailsLoudly() = runBlocking {
        write("src/classes.dex", "DEX1")
        ZipFs(root).zip("src", "app.apk")

        val out = ApkReverseEngine(RecordingRunner(root), fs, withToolchain(baksmaliJar = null))
            .decompile("app.apk", "out", withSmali = true)

        assertFalse(out.ok)
        assertTrue(out.reason.orEmpty().contains("baksmali.jar"), "实际：${out.reason}")
        assertTrue(Files.exists(root.resolve("out/classes.dex")), "摊开的结果要留下 —— 只改资源还能继续")
    }

    @Test
    @DisplayName("withSmali=false（只改资源）→ 完全不起 baksmali")
    fun decompileWithoutSmaliRunsNoTool() = runBlocking {
        write("src/classes.dex", "DEX1")
        write("src/resources.arsc", "ARSC")
        ZipFs(root).zip("src", "app.apk")

        val runner = RecordingRunner(root)
        val out = ApkReverseEngine(runner, fs, withToolchain()).decompile("app.apk", "out", withSmali = false)

        assertTrue(out.ok, "实际：${out.reason}")
        assertTrue(runner.commands.isEmpty(), "不该起任何进程，实际：${runner.commands}")
        assertTrue(Files.exists(root.resolve("out/resources.arsc")), "资源要摊开出来")
    }

    @Test
    @DisplayName("★★ smali 目录必须由 **App** 先建（外置存储上 App 只能看进自己拥有的目录）")
    fun smaliDirIsCreatedByApp() = runBlocking {
        write("src/classes.dex", "DEX1")
        ZipFs(root).zip("src", "app.apk")

        // 探针 runner：被调用的**那一刻**看 smali/ 在不在（baksmali 会往里写文件）
        val seen = ArrayList<Pair<Boolean, Boolean>>()
        val spy = object : ShellRunner {
            override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
                seen.add(
                    Files.isDirectory(root.resolve("out/smali")) to
                        Files.isDirectory(root.resolve("out")),
                )
                return ShellResult(0, "ok", "", false, 1L)
            }
        }
        val out = ApkReverseEngine(spy, fs, withToolchain()).decompile("app.apk", "out", withSmali = true)

        assertTrue(out.ok, "实际：${out.reason}")
        assertTrue(seen.isNotEmpty(), "baksmali 没被调用？")
        assertTrue(
            seen.first().first,
            "shell 建出来的 smali/ 属于 shell ⇒ App 连 stat 都是 AccessDenied，" +
                "而'读 smali 改它'正是这条路的意义（见 appReadable）",
        )
    }

    @Test
    @DisplayName("★ 目标目录【非空】→ 拒绝摊开（解包只写不删，残余会被静默打进产物）")
    fun decompileIntoNonEmptyDirIsRejected() = runBlocking {
        write("src/classes.dex", "DEX1")
        ZipFs(root).zip("src", "app.apk")
        // 上一次摊开留下的残留（真机那次是 `smali/`）
        write("out/smali/com/example/Old.smali", ".class public LOld;")

        val runner = RecordingRunner(root)
        val out = ApkReverseEngine(runner, fs, withToolchain()).decompile("app.apk", "out", withSmali = true)

        assertFalse(out.ok, "非空目标目录必须拒绝 —— 否则残留会被打进产物")
        assertTrue(out.reason.orEmpty().contains("不是空的"), "要说清原因：${out.reason}")
        assertTrue(runner.commands.isEmpty(), "拒绝时不该起任何进程：${runner.commands}")
        assertFalse(
            Files.exists(root.resolve("out/classes.dex")),
            "拒绝就不该留下半个摊开结果（免得下次又被误当成'已摊开'）",
        )
    }

    @Test
    @DisplayName("★ 进度旁路：逆向每一步也播给 TaskProgress（App 拿它更新通知栏）")
    fun reportsStepsToProgress() = runBlocking {
        write("p/classes.dex", "旧 dex")
        val runner = RecordingRunner(root)
        val steps = mutableListOf<String>()
        val progress = object : TaskProgress {
            override fun start(task: String) = Unit
            override fun step(text: String) {
                steps.add(text)
            }

            override fun finish(ok: Boolean, summary: String) = Unit
        }

        val out = ApkReverseEngine(runner, fs, withToolchain(), progress).recompile("p", "out.apk")

        assertTrue(out.ok, "重打包应当成功：${out.reason}")
        assertTrue(steps.isNotEmpty(), "逆向也要有进度（否则通知栏几分钟不动）")
        // 与构建引擎同一个约定：播出去的 == 步骤摘要，逐条一致
        assertEquals(
            out.steps.map { "${if (it.exitCode == 0) "✓" else "✗"} ${it.name}" },
            steps,
        )
    }
}
