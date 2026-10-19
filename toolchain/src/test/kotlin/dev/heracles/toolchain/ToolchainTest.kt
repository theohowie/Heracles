package dev.heracles.toolchain

import dev.heracles.core.contract.Contract
import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import dev.heracles.core.progress.TaskProgress
import dev.heracles.workspace.RealWorkspaceFs
import dev.heracles.workspace.ZipAligner
import dev.heracles.workspace.ZipFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import java.security.KeyStore
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory

/**
 * `ToolchainLocator` 的行为门禁 —— `26-编码层工具链与逆向引擎.md` §6.1。
 *
 * 重点在**优先级**：工作区自带的工具链必须压过系统里的旧版本，
 * 否则"我明明推到工作区了"和"用的却是 Termux 里那份"会同时成立 ——
 * 这类 bug 的症状是"改了没效果"，极难查。
 */
class ToolchainLocatorTest {

    private val root: Path = createTempDirectory("toolchain-locate")

    private fun touch(p: Path): Path {
        Files.createDirectories(p.parent)
        Files.writeString(p, "stub")
        return p
    }

    @Test
    @DisplayName("★ 工作区 .heracles/toolchain/ 优先于 ANDROID_HOME")
    fun workspaceWins() {
        val wsAapt2 = touch(root.resolve(".heracles/toolchain/aapt2"))
        val sdkDir = createTempDirectory("fake-sdk")
        val sdkAapt2 = touch(sdkDir.resolve("build-tools/34.0.0/aapt2"))

        val paths = ToolchainLocator.locate(root, mapOf("ANDROID_HOME" to sdkDir.toString()))
        assertEquals(wsAapt2.toString(), paths.aapt2)
        assertTrue(sdkAapt2.toString() != paths.aapt2)
    }

    @Test
    @DisplayName("支持版本化子目录（build-tools/34.0.0/aapt2、platforms/android-34/android.jar）")
    fun findsVersionedSubdirs() {
        val sdkDir = createTempDirectory("fake-sdk2")
        touch(sdkDir.resolve("build-tools/34.0.0/aapt2"))
        touch(sdkDir.resolve("build-tools/34.0.0/lib/d8.jar"))
        touch(sdkDir.resolve("platforms/android-34/android.jar"))

        val paths = ToolchainLocator.locate(
            createTempDirectory("empty-ws"),
            mapOf("ANDROID_HOME" to sdkDir.toString()),
            extraDirs = emptyList(),
        )
        assertTrue(paths.aapt2!!.endsWith("aapt2"))
        assertTrue(paths.d8Jar!!.endsWith("d8.jar"))
        assertTrue(paths.androidJar!!.endsWith("android.jar"))
    }

    @Test
    @DisplayName("★ 真机部署布局（摊开的 Termux 前缀树）能被定位到 —— 2026-10-16 实测的那棵树")
    fun findsTermuxPrefixLayout() {
        // 复刻真机上 /data/local/tmp/heracles/toolchain/ 的形状：
        //   android.jar / d8.jar / apksigner.jar / apktool.jar / heracles.jks  ← 顶层（PC 上 push 的件）
        //   bin/{aapt2,apksigner,env.sh}                                       ← PC 侧生成的包装脚本
        //   termux/usr/bin/aapt2                                               ← Termux 的 bionic 包摊开
        //   termux/usr/lib/jvm/java-17-openjdk/bin/{java,javac}                ← Termux 的 JDK（5 层深）
        val tree = root.resolve("devtree")
        touch(tree.resolve("android.jar"))
        touch(tree.resolve("d8.jar"))
        touch(tree.resolve("apksigner.jar"))
        touch(tree.resolve("apktool.jar"))
        touch(tree.resolve("heracles.jks"))
        touch(tree.resolve("bin/aapt2"))
        touch(tree.resolve("bin/apksigner"))
        touch(tree.resolve("termux/usr/bin/aapt2"))
        touch(tree.resolve("termux/usr/lib/jvm/java-17-openjdk/bin/javac"))
        touch(tree.resolve("termux/usr/lib/jvm/java-17-openjdk/bin/java"))

        val paths = ToolchainLocator.locate(root, emptyMap(), extraDirs = listOf(tree))

        // ★ 必须命中 `bin/` 里的**包装脚本**，不是根目录的 jar（2026-10-16 真机 bug，见下一条测试）
        assertEquals(tree.resolve("bin/aapt2").toString(), paths.aapt2)
        assertEquals(tree.resolve("bin/apksigner").toString(), paths.apksigner)
        assertEquals(tree.resolve("termux/usr/lib/jvm/java-17-openjdk").toString(), paths.javaHome)
        assertTrue(paths.d8Jar!!.endsWith("d8.jar"))
        assertTrue(paths.androidJar!!.endsWith("android.jar"))
        assertEquals(tree.resolve("heracles.jks").toString(), paths.keystore)
        // ★ 这棵树里**没有 zipalign**（Android 上根本不存在）—— 仍必须判定为"可以构建"
        assertTrue(paths.canBuildApk(), "缺 zipalign 不影响可构建性（ADR-026）")
    }

    @Test
    @DisplayName("★★ Termux 前缀树要给出 bionic 库目录（2026-10-17 App 进程内自检抓到缺 LD_LIBRARY_PATH）")
    fun derivesBionicLibDirs() {
        val tree = root.resolve("devtree2")
        touch(tree.resolve("bin/aapt2"))
        touch(tree.resolve("termux/usr/lib/jvm/java-17-openjdk/bin/javac"))
        touch(tree.resolve("termux/usr/lib/jvm/java-17-openjdk/bin/java"))

        val paths = ToolchainLocator.locate(root, emptyMap(), extraDirs = listOf(tree))
        val libs = paths.bionicLibDirs()

        // 与 deploy 脚本手工验证过的三条**完全一致**
        // （staging/deploy-toolchain.ps1：$dev/termux/usr/lib:$jh/lib:$jh/lib/server）
        assertEquals(tree.resolve("termux/usr/lib").toString(), libs[0], "实际：$libs")
        assertEquals(
            tree.resolve("termux/usr/lib/jvm/java-17-openjdk/lib").toString(),
            libs[1],
            "实际：$libs",
        )
        assertEquals(
            tree.resolve("termux/usr/lib/jvm/java-17-openjdk/lib/server").toString(),
            libs[2],
            "实际：$libs",
        )
        assertEquals(3, libs.size, "不要多塞 —— 实际：$libs")
    }

    @Test
    @DisplayName("★ PC 上（JDK 在 PATH 里、aapt2 在 build-tools 下）**不**给 LD_LIBRARY_PATH")
    fun pcGetsNoBionicLibDirs() {
        val sdkDir = createTempDirectory("fake-sdk3")
        touch(sdkDir.resolve("build-tools/34.0.0/aapt2"))
        touch(sdkDir.resolve("build-tools/34.0.0/lib/d8.jar"))
        touch(sdkDir.resolve("platforms/android-34/android.jar"))

        val paths = ToolchainLocator.locate(
            createTempDirectory("empty-ws3"),
            mapOf("ANDROID_HOME" to sdkDir.toString()),
            extraDirs = emptyList(),
        )
        assertTrue(paths.javaHome == null, "PC 上不该有 javaHome：${paths.javaHome}")
        assertEquals(emptyList<String>(), paths.bionicLibDirs(), "别把宿主 /usr/lib 塞进去")
    }

    @Test
    @DisplayName("★★ 名字的优先级要**跨目录**生效：可执行的 apksigner 胜过分层的 apksigner.jar")
    fun executableWinsOverJarAcrossDirs() {
        // 真机原样：jar 平铺在根目录，真身在 bin/ 子目录。
        // 旧实现"先把第一个命中的名字用掉"⇒ 根目录的 jar 赢 ⇒ 脚本报
        // `apksigner.jar: can't execute: Permission denied`（2026-10-16 真机抓到）。
        val tree = root.resolve("priority")
        touch(tree.resolve("apksigner.jar"))
        touch(tree.resolve("bin/apksigner"))

        val paths = ToolchainLocator.locate(root, emptyMap(), extraDirs = listOf(tree))
        assertEquals(tree.resolve("bin/apksigner").toString(), paths.apksigner)

        // 而"只有 jar"时必须退到 jar —— 这条路径仍然合法（脚本与 ApkReverseEngine
        // 都能用 `java -jar` 调它，见 ToolchainPaths.apksignerCommand）
        val jarOnly = root.resolve("jaronly")
        touch(jarOnly.resolve("apksigner.jar"))
        val p2 = ToolchainLocator.locate(root, emptyMap(), extraDirs = listOf(jarOnly))
        assertEquals(jarOnly.resolve("apksigner.jar").toString(), p2.apksigner)
    }

    @Test
    @DisplayName("★ apksigner 是 jar 时要变成 `java -jar <jar>`（否则 Permission denied）")
    fun apksignerCommandHandlesJar() {
        val exe = ToolchainPaths(apksigner = "/x/bin/apksigner")
        assertEquals("\"/x/bin/apksigner\"", exe.apksignerCommand())

        val jar = ToolchainPaths(apksigner = "/x/apksigner.jar")
        assertEquals("java -jar \"/x/apksigner.jar\"", jar.apksignerCommand())

        assertEquals("", ToolchainPaths().apksignerCommand())
    }

    @Test
    @DisplayName("★ 什么都不在 → 每一项都是 null，且 missing() 如实列出（不假装可用）")
    fun nothingFoundIsHonest() {
        val paths = ToolchainLocator.locate(createTempDirectory("empty2"), emptyMap())
        assertFalse(paths.canBuildApk())
        assertEquals(listOf("aapt2", "apksigner", "d8.jar", "android.jar"), paths.missing(), 
            "zipalign 已降级为可选（ADR-026：Android 上没有它），不得出现在缺失清单里")
    }

    @Test
    @DisplayName("★ 不假设 ANDROID_HOME 存在（真机上通常没有）")
    fun doesNotRequireAndroidHome() {
        val ws = createTempDirectory("ws-no-sdk")
        listOf("aapt2", "apksigner", "d8.jar", "android.jar").forEach {
            touch(ws.resolve(".heracles/toolchain/$it"))
        }
        val paths = ToolchainLocator.locate(ws, emptyMap())
        assertTrue(paths.canBuildApk(), "工作区自带工具链时应可构建，实际缺：${paths.missing()}")
    }
}

/** `BuildTemplates` 的门禁 —— 模板错了就是"每个项目都错"，所以必须钉住。 */
class BuildTemplatesTest {

    @Test
    @DisplayName("★ 脚本里不得残留 __DOLLAR__ 占位符（残留会让整份脚本变成垃圾）")
    fun noPlaceholderResidue() {
        val s = BuildTemplates.script()
        assertFalse(s.contains(BuildTemplates.DOLLAR), "占位符未被替换")
        assertTrue(s.contains("#!/system/bin/sh"))
        assertTrue(s.contains("\$MODE"), "替换后应当是真的 shell 变量")
    }

    @Test
    @DisplayName("★ 默认产物名单一来源：脚本值仍是 app-debug.apk，但由 BuildProfile 注入（F9a 收尾）")
    fun defaultOutComesFromProfile() {
        val s = BuildTemplates.script()

        // ① 占位符必须被替换掉（残留会让脚本退化成 `OUT=__DEFAULT_OUT__`）
        assertFalse(
            s.contains(BuildTemplates.DEFAULT_OUT_PLACEHOLDER),
            "默认产物名占位符未被替换：${BuildTemplates.DEFAULT_OUT_PLACEHOLDER}",
        )
        // ② **值不变**：手工直跑脚本的兜底仍然是 app-debug.apk（独立断言，不是读 profile 自证）
        assertTrue(s.contains("OUT=app-debug.apk"), "脚本默认产物名必须仍是 app-debug.apk")
        // ③ **来源唯一**：拼出来的值就是 profile 里的默认名
        assertTrue(
            s.contains("OUT=${BuildProfiles.ANDROID.artifact.defaultName}"),
            "脚本默认产物名必须来自 BuildProfiles.ANDROID.artifact.defaultName",
        )
    }

    @Test
    @DisplayName("★ 脚本不得使用 Gradle（需求硬约束）")
    fun noGradle() {
        // 注释里出现「不使用 Gradle」是正常的 —— 只检查**可执行部分**
        val code = BuildTemplates.script().lineSequence()
            .filterNot { it.trimStart().startsWith("#") }
            .joinToString("\n")
            .lowercase()
        assertFalse(code.contains("gradle"), "禁止 Gradle；可执行部分：\n$code")
        assertFalse(code.contains("gradlew"))
    }

    @Test
    @DisplayName("★ 脚本不得用 -bootclasspath（JDK 17+ 实测报错：目标 17 不支持该选项）")
    fun noBootClasspath() {
        val s = BuildTemplates.script()
        assertFalse(
            s.contains("-bootclasspath"),
            "javac -bootclasspath 在 JDK 17+ 上直接报错，会搞死整条流水线",
        )
        assertTrue(s.contains("-classpath"), "必须用 -classpath 指向 android.jar")
    }

    @Test
    @DisplayName("流水线顺序：对齐必须在 apksigner 之前（顺序反了签名会失效）")
    fun alignBeforeApksigner() {
        val s = BuildTemplates.script()
        val si = s.indexOf("apksigner_cmd sign")
        // 两种对齐实现都要在签名之前：外部 zipalign 与"交给调用方"
        for (m in listOf("ZIPALIGN\" -f -p 4", "echo \"NEED_ALIGN\"")) {
            val at = s.indexOf(m)
            assertTrue(at in 1..si, "对齐步骤（$m @ $at）必须出现在 apksigner sign（$si）之前")
        }
    }

    @Test
    @DisplayName("★ 对齐契约（ADR-027）：ALIGN_MODE=inprocess 时脚本以 exit 11 交回，并把路径打在 stderr 上")
    fun inProcessAlignContract() {
        val s = BuildTemplates.script()
        assertTrue(s.contains("ALIGN_MODE="), "脚本必须认 ALIGN_MODE")
        assertTrue(s.contains("exit 11"), "必须用 exit 11 表示「请调用方对齐」")
        for (key in listOf("IN=", "OUT=", "ASTAMP=")) {
            assertTrue(s.contains("echo \"$key"), "$key 必须打在 stderr 上（调用方要照它干活，不能猜）")
        }
        // 幂等：对齐完成后（ASTAMP 存在）必须跳过，否则会死循环
        assertTrue(
            s.contains("[ -f \"\$ALIGN_STAMP\" ]"),
            "必须先看 ASTAMP 是否存在（否则重跑 package 会再次要求对齐 → 死循环）",
        )
        // 三种模式都要有，且「默认跳过必须明说」（H-1 教训）
        assertTrue(s.contains("external)"), "要支持外部 zipalign 模式（手工跑脚本用）")
        assertTrue(s.contains("inprocess)"), "要支持进程内对齐模式")
        assertTrue(s.contains("跳过对齐"), "既没工具也没调用方代劳时，必须**明说**跳过")
    }

    @Test
    @DisplayName("★ apksigner 一律走 apksigner_cmd（jar 形态也要能跑，2026-10-16 真机 bug）")
    fun apksignerAlwaysGoesThroughWrapper() {
        val s = BuildTemplates.script()
        assertTrue(s.contains("apksigner_cmd()"), "脚本必须定义 apksigner_cmd")
        assertTrue(s.contains("*.jar) java -jar"), "jar 形态必须用 java -jar 调")
        assertTrue(s.contains("apksigner_cmd sign"), "签名要走 apksigner_cmd")
        assertTrue(s.contains("apksigner_cmd verify"), "自校验也要走 apksigner_cmd")

        // ★ 只检查**代码行**：脚本的注释里会引用那行坏代码做说明（那是给用户的文档），
        //   把注释也算进来就成了"注释即违规"的假红。
        val code = s.lines().filterNot { it.trimStart().startsWith("#") }.joinToString("\n")
        assertFalse(
            code.contains("\"\$APKSIGNER\" sign"),
            "不得直接执行 \$APKSIGNER：它是 jar 时会报 can't execute: Permission denied",
        )
    }

    @Test
    @DisplayName("★ 内存受限：javac 与 d8 都必须显式给 -Xmx512m")
    fun heapIsBounded() {
        val s = BuildTemplates.script()
        assertTrue(s.contains("javac -J-Xmx512m"), "javac 必须限堆")
        assertTrue(s.contains("java -Xmx512m -cp"), "d8 必须用 java -Xmx512m 调起")
    }

    @Test
    @DisplayName("清单含 android:exported（API 31+ 必需，漏了会安装/启动失败）")
    fun manifestHasExported() {
        assertTrue(BuildTemplates.MANIFEST.contains("android:exported=\"true\""))
    }

    @Test
    @DisplayName("★ 脚本不能 `rm -rf` 掉 build 目录本身（App 必须拥有那个目录）")
    fun keepsBuildDirAlive() {
        val s = BuildTemplates.script()
        assertFalse(
            Regex("""rm -rf "${'$'}BUILD"\s*$""", RegexOption.MULTILINE).containsMatchIn(s),
            "删掉整个目录 ⇒ 以 shell 身份重建 ⇒ App 连 stat 都被 AccessDenied（见 appReadable）",
        )
        assertTrue(
            s.contains("[ \"\$p\" = \"\$BUILD/dex\" ] && continue"),
            "清理时必须**跳过 dex/** —— 它是 App 预建的，删掉重建就归 shell 了",
        )
        assertTrue(s.contains("rm -rf \"\$BUILD/dex\"/*"), "dex/ 只清里面的文件，目录本身留活口")
        assertTrue(
            s.contains("mkdir -p \"\$BUILD/classes\" \"\$BUILD/gen\" \"\$BUILD/dex\""),
            "已存在时 mkdir -p 是空操作 —— 必须保留，CLI/PC 上没有调用方预建目录",
        )
    }
}

/**
 * `appReadable` 的门禁 —— 2026-10-17 **App 进程内**自检抓到的"shell 产出 App 读不了"。
 *
 * 存在理由、FUSE 的四条实测事实都在它自己的 KDoc 里。这里只钉住**改了就出人命**的三点：
 *
 * 1. 退出码**原样保留** —— 脚本靠 `exit 10/11` 把"要我插 dex / 要我对齐"交回引擎，
 *    退出码被改掉整条契约就哑了（构建会静默地少做一步）；
 * 2. chmod 的目标是**工作区绝对路径**（不是 `.`：引擎有的命令带 cwd、有的不带）；
 * 3. 报错不致命 —— PC 上可能没有 `chmod`，不能让它污染输出或退出码。
 */
class AppReadableTest {

    @Test
    @DisplayName("★ 退出码必须原样保留（exit 10/11 是插 dex / 对齐的交回契约）")
    fun keepsExitCode() {
        val out = appReadable("sh build.sh package . app.apk", Paths.get("/ws"))
        assertTrue(out.startsWith("sh build.sh package . app.apk;"), "命令本体必须原样在最前面：$out")
        assertTrue(out.contains("rc=\$?"), "必须先把退出码存下来：$out")
        assertTrue(out.contains("exit \$rc"), "必须用它收尾：$out")
        assertTrue(
            out.indexOf("chmod") < out.indexOf("exit \$rc"),
            "chmod 必须在收尾之前（写在 exit 后面就永远跑不到）：$out",
        )
    }

    @Test
    @DisplayName("★ chmod 打在工作区绝对路径上，且失败不致命")
    fun chmodsWorkspaceRoot() {
        // 注意：断言用**解析后的 Path** 拼期望值 —— Windows 上 `/a/b` 会变成 `\a\b`，
        // 硬写正斜杠的断言在别的平台上必挂（自己踩过）。
        val ws = Paths.get("/storage/emulated/0/Android/data/com.theohowie.heracles/files/ws")
        val out = appReadable("true", ws)
        assertTrue(out.contains("chmod -R a+rwX '$ws'"), "实际：$out")
        assertTrue(out.contains("2>/dev/null"), "PC 上没有 chmod 也不能污染输出：$out")
    }

    @Test
    @DisplayName("路径里的单引号要转义（不然 chmod 会吃掉半条路径）")
    fun escapesSingleQuote() {
        val ws = Paths.get("/ws/it's here")
        val escaped = ws.toString().replace("'", "'\\''")
        val out = appReadable("true", ws)
        assertTrue(out.contains("'$escaped'"), "实际：$out")
    }
}

/**
 * 内嵌调试密钥的正确性 —— **必须验**。
 *
 * 它在源文件里是一大串 Base64，肉眼无法判断有没有抄错一个字符；
 * 而错误的后果是"签名失败"，报错信息完全指不到密钥本身。
 * 这里直接把它当 JKS 载入（口令 android），能载入且别名在，就证明字节是对的。
 */
class DebugKeystoreTest {

    @Test
    @DisplayName("★ 内嵌密钥能被 JKS 载入，且别名 heracles 存在")
    fun embeddedKeystoreIsValid() {
        val ks = KeyStore.getInstance("JKS")
        DebugKeystore.bytes().inputStream().use { ks.load(it, DebugKeystore.PASS.toCharArray()) }
        assertTrue(ks.containsAlias(Contract.Toolchain.KEY_ALIAS), "别名必须是 ${Contract.Toolchain.KEY_ALIAS}")
        val key = ks.getKey(Contract.Toolchain.KEY_ALIAS, DebugKeystore.PASS.toCharArray())
        assertTrue(key.algorithm == "RSA")
        assertEquals(DebugKeystore.PASS, Contract.Toolchain.KEYSTORE_PASS, "口令必须与契约一致")
    }
}

/** `AndroidProjectScaffold` 的门禁。 */
class AndroidProjectScaffoldTest {

    private val root: Path = createTempDirectory("scaffold")
    private val fs = RealWorkspaceFs.open(root)
    private val scaffold = AndroidProjectScaffold(fs)

    @Test
    @DisplayName("生成的骨架齐全（清单 / Activity / 资源 / 构建脚本）")
    fun createsAllFiles() = runBlocking {
        val written = scaffold.create("hello", "com.example.hello", "我的应用")
        assertTrue(written.any { it.endsWith("AndroidManifest.xml") })
        assertTrue(written.any { it.endsWith("src/com/example/hello/MainActivity.java") })
        assertTrue(written.any { it.endsWith("res/values/strings.xml") })
        assertTrue(written.any { it.endsWith("build_apk.sh") })
        assertTrue(Files.exists(root.resolve("hello/build_apk.sh")))
        // 包名真的被替换进去了
        assertTrue(Files.readString(root.resolve("hello/AndroidManifest.xml")).contains("com.example.hello"))
        assertTrue(Files.readString(root.resolve("hello/res/values/strings.xml")).contains("我的应用"))
        assertTrue(scaffold.isAndroidProject("hello"))
    }

    @Test
    @DisplayName("★ 包名非法 → 在写任何文件之前就拒绝")
    fun invalidPackageIsRejectedBeforeWriting() {
        assertThrows(IllegalArgumentException::class.java) {
            runBlocking { scaffold.create("bad", "com.Example.App") }
        }
        assertFalse(Files.exists(root.resolve("bad")), "非法包名不该留下半个项目")
    }

    @Test
    @DisplayName("应用名里的 XML 特殊字符被转义（否则 strings.xml 解析失败）")
    fun appNameIsEscaped() = runBlocking {
        scaffold.create("esc", "com.example.esc", "A & B <C>")
        val strings = Files.readString(root.resolve("esc/res/values/strings.xml"))
        assertTrue(strings.contains("A &amp; B &lt;C&gt;"), "特殊字符必须转义，实际：$strings")
    }
}

/** 假 runner：按命令内容模拟脚本行为，并把结果落到真实磁盘上（与真脚本契约一致）。 */
private class ScriptSimulatingRunner(
    private val root: Path,
    /** 故意产出一个**不是 zip** 的 base.apk，用来验证"对齐失败要诚实" */
    private val corruptBaseApk: Boolean = false,
) : ShellRunner {

    val commands = mutableListOf<String>()
    val exitCodes = mutableListOf<Int>()

    override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
        commands.add(command)
        val projectDir = cwd ?: ""
        val base = root.resolve("$projectDir/.heracles/build").normalize()
        val dex = base.resolve("dex/classes.dex")
        val stamp = base.resolve("dex-inserted")

        return when {
            command.contains(" prepare ") -> {
                // 模拟 aapt2 link 产出 base.apk + d8 产出 classes.dex
                Files.createDirectories(dex.parent)
                Files.writeString(dex, "DEX-BYTES")
                if (corruptBaseApk) {
                    Files.writeString(base.resolve("base.apk"), "这不是一个 zip")
                } else {
                    ZipOutputStream(Files.newOutputStream(base.resolve("base.apk"))).use { zos ->
                        // resources.arsc 用 STORED（与 aapt2 的真实行为一致）
                        val arsc = "ARSC".toByteArray()
                        zos.putNextEntry(ZipEntry("resources.arsc").apply {
                            method = ZipEntry.STORED
                            size = arsc.size.toLong()
                            compressedSize = arsc.size.toLong()
                            crc = java.util.zip.CRC32().apply { update(arsc) }.value
                        })
                        zos.write(arsc)
                        zos.closeEntry()
                    }
                }
                exitCodes.add(0)
                ShellResult(0, "[1/5]…[4/5] ok", "", false, 1500L)
            }

            command.contains(" package ") -> {
                val alignStamp = base.resolve("aligned")
                val alignedApk = base.resolve("aligned.apk")
                if (!Files.exists(stamp)) {
                    exitCodes.add(AndroidBuildEngine.EXIT_NEED_DEX_INSERT)
                    ShellResult(
                        AndroidBuildEngine.EXIT_NEED_DEX_INSERT, "",
                        "NEED_DEX_INSERT\nSTAMP=./.heracles/build/dex-inserted\n" +
                            "DEX=./.heracles/build/dex/classes.dex\nBASE=./.heracles/build/base.apk\n",
                        false, 10L,
                    )
                } else if (!Files.exists(alignStamp)) {
                    // ★ 与真脚本一致：引擎注入 ALIGN_MODE=inprocess ⇒ 这一步永远以
                    //   exit 11 交回（对齐必须在签名之前，脚本不能自己 cp 一份去签）
                    exitCodes.add(AndroidBuildEngine.EXIT_NEED_ALIGN)
                    ShellResult(
                        AndroidBuildEngine.EXIT_NEED_ALIGN, "",
                        "NEED_ALIGN\nIN=./.heracles/build/base.apk\n" +
                            "OUT=./.heracles/build/aligned.apk\nASTAMP=./.heracles/build/aligned\n",
                        false, 10L,
                    )
                } else {
                    // 签名阶段：用引擎对齐好的那份（真脚本就是签 aligned.apk）
                    val src = if (Files.exists(alignedApk)) alignedApk else base.resolve("base.apk")
                    // 输出名取自命令最后一个参数（脚本的 $3）
                    //
                    // ⚠️ 必须先把引擎追加的收尾（`; rc=$?; chmod …; exit $rc`）切掉 ——
                    //   那是跟在脚本**后面**的另一条命令，不会进脚本的 argv；
                    //   直接 `substringAfterLast(' ')` 会切到 `exit $rc` 上。
                    val outName = command.substringBefore("; rc=\$?").trim().substringAfterLast(' ')
                    Files.copy(
                        src,
                        root.resolve("$projectDir/$outName"),
                        java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                    )
                    exitCodes.add(0)
                    ShellResult(0, "✓ 已产出", "", false, 2000L)
                }
            }

            else -> {
                exitCodes.add(-9)
                ShellResult(-9, "", "未预期的命令", false, 0L)
            }
        }
    }
}

/**
 * `AndroidBuildEngine` 的门禁 —— `26-编码层工具链与逆向引擎.md` §6.2（需求模块 4）。
 *
 * 这里跑的是**真实的引擎逻辑**：只有 shell 是假的（脚本行为被模拟出来，
 * 并且**真的往磁盘写文件**），所以"塞 classes.dex"这一步是用真的
 * [ZipFs] 完成的 —— 它正是真机上唯一的进程内步骤，值得被真测。
 */
class AndroidBuildEngineTest {

    private val root: Path = createTempDirectory("build-engine")
    private val fs = RealWorkspaceFs.open(root)
    private val runner = ScriptSimulatingRunner(root)

    private val toolchain = ToolchainPaths(
        aapt2 = "/opt/t/aapt2",
        zipalign = "/opt/t/zipalign",
        apksigner = "/opt/t/apksigner",
        d8Jar = "/opt/t/d8.jar",
        androidJar = "/opt/t/android.jar",
    )

    private fun engine() = AndroidBuildEngine(runner, fs, toolchain)

    @Test
    @DisplayName("★ 进度旁路：每一步都播给 TaskProgress（App 拿它更新通知栏）")
    fun reportsStepsToProgress() = runBlocking {
        AndroidProjectScaffold(fs).create("prog", "com.example.prog", "Prog")

        val steps = mutableListOf<String>()
        var started = 0
        var finished = 0
        val progress = object : TaskProgress {
            override fun start(task: String) {
                started++
            }

            override fun step(text: String) {
                steps.add(text)
            }

            override fun finish(ok: Boolean, summary: String) {
                finished++
            }
        }

        val outcome = AndroidBuildEngine(runner, fs, toolchain, null, progress).build("prog")

        assertTrue(outcome.ok, "构建应当成功：${outcome.reason}")
        // 播出去的步骤 == 步骤摘要，**逐条一致**（同一个来源，不许两边各写一份）
        assertEquals(
            outcome.steps.map { "${if (it.exitCode == 0) "✓" else "✗"} ${it.name}" },
            steps,
        )
        // 生命周期（start/finish）归**工具层装饰器** —— 引擎只播步骤，不决定任务起止。
        // 这条断言把这个职责边界钉住：谁想"顺手在引擎里 start 一下"会立刻红。
        assertEquals(0, started, "引擎不该自己 start（那是 AndroidTools 装饰器的事）")
        assertEquals(0, finished, "引擎不该自己 finish（那是 AndroidTools 装饰器的事）")
    }

    @Test
    @DisplayName("★ 进度是旁路：实现抛异常也不影响构建结果（功能正确性 > 可观测性）")
    fun progressFailureDoesNotBreakBuild() = runBlocking {
        AndroidProjectScaffold(fs).create("prog2", "com.example.prog2", "Prog2")

        val boom = object : TaskProgress {
            override fun start(task: String): Unit = throw IllegalStateException("boom")
            override fun step(text: String): Unit = throw IllegalStateException("boom")
            override fun finish(ok: Boolean, summary: String): Unit = throw IllegalStateException("boom")
        }

        val outcome = AndroidBuildEngine(runner, fs, toolchain, null, boom).build("prog2")

        assertTrue(outcome.ok, "进度抛异常**不得**影响构建：${outcome.reason}")
    }

    @Test
    @DisplayName("★ 端到端：骨架 → 构建 → 产出含 classes.dex 的 APK")
    fun buildsApkEndToEnd() = runBlocking {
        AndroidProjectScaffold(fs).create("hello", "com.example.hello", "Hello")

        val outcome = engine().build("hello")

        assertTrue(outcome.ok, "构建应当成功，实际：${outcome.reason}\n${outcome.stepsSummary()}")
        assertEquals("hello/app-debug.apk", outcome.apkPath)
        assertTrue(Files.exists(root.resolve("hello/app-debug.apk")))
    }

    @Test
    @DisplayName("★ 进程内插入的 classes.dex 真的进了 APK（这是设备上唯一可行路径）")
    fun dexIsInsertedInProcess() = runBlocking {
        AndroidProjectScaffold(fs).create("hello2", "com.example.hello2", "Hello")
        engine().build("hello2", "out.apk")

        val entries = ZipFs(root).listEntries("hello2/out.apk").map { it.name }
        assertTrue("classes.dex" in entries, "APK 里必须有 classes.dex，实际条目：$entries")
        assertTrue("resources.arsc" in entries, "原有条目不能丢，实际：$entries")
    }

    @Test
    @DisplayName("★ 逐阶段留痕：prepare / 插入 dex / 进程内对齐 / package 四段都能看到")
    fun recordsEveryStep() = runBlocking {
        AndroidProjectScaffold(fs).create("hello3", "com.example.hello3", "Hello")
        val outcome = engine().build("hello3")

        assertEquals(4, outcome.steps.size, "应当有四段：${outcome.stepsSummary()}")
        assertTrue(outcome.steps[1].inProcess, "第二段必须是进程内插入 dex")
        assertTrue(outcome.steps[2].inProcess, "第三段必须是进程内对齐")
        assertTrue(outcome.stepsSummary().contains("process") || outcome.stepsSummary().contains("进程内"))
        assertTrue(outcome.stepsSummary().startsWith("✓"), "第一段应成功")
    }

    @Test
    @DisplayName("★ 进程内对齐（exit 11）：产物真的对齐了 —— 用 ZipAligner 独立复检")
    fun alignsInProcess() = runBlocking {
        AndroidProjectScaffold(fs).create("helloa", "com.example.helloa", "Hello")
        val outcome = engine().build("helloa", "out.apk")
        assertTrue(outcome.ok, "构建应当成功：${outcome.reason}\n${outcome.stepsSummary()}")

        val report = ZipAligner(root).check("helloa/out.apk")
        assertTrue(report.ok, "产物必须是对齐过的：${report.summary()}")
        assertTrue(report.checked > 0, "应当有 STORED 条目参与对齐（否则测试是空转）")
    }

    @Test
    @DisplayName("★ 进程内那步失败 → 如实报错、不留『已做过』的步骤、不产出伪产物")
    fun inProcessFailureIsHonest() = runBlocking {
        // base.apk 不是合法 zip ⇒ 插入 classes.dex 直接就失败（进程内那步）
        val bad = ScriptSimulatingRunner(root, corruptBaseApk = true)
        val eng = AndroidBuildEngine(bad, fs, toolchain)
        AndroidProjectScaffold(fs).create("hellob", "com.example.hellob", "Hello")

        val outcome = eng.build("hellob")

        assertFalse(outcome.ok, "坏包不该报成功")
        assertTrue(outcome.reason!!.contains("classes.dex"), "原因要点明卡在哪一步：${outcome.reason}")
        assertTrue(
            outcome.steps.none { it.inProcess },
            "失败时不得留下『已做过』的进程内步骤：${outcome.stepsSummary()}",
        )
        assertFalse(Files.exists(root.resolve("hellob/app-debug.apk")), "不得产出伪产物")
    }

    @Test
    @DisplayName("★ 工具路径真的被注入到命令里（否则脚本找不到 aapt2）")
    fun injectsToolPaths() = runBlocking {
        AndroidProjectScaffold(fs).create("hello4", "com.example.hello4", "Hello")
        engine().build("hello4")

        val prepare = runner.commands.first { it.contains(" prepare ") }
        assertTrue(prepare.contains("""AAPT2="/opt/t/aapt2""""), "实际命令：$prepare")
        assertTrue(prepare.contains("""D8_JAR="/opt/t/d8.jar""""))
        assertTrue(prepare.contains("""ANDROID_JAR="/opt/t/android.jar""""))
        assertTrue(prepare.contains("MIN_SDK=31"), "minSdk 必须来自 Contract（Android 12）")
        // ★ 对齐：引擎**不**注入 ZIPALIGN，而是声明"我自己来"（ADR-027）
        assertTrue(prepare.contains("ALIGN_MODE=inprocess"), "实际命令：$prepare")
        assertFalse(prepare.contains("ZIPALIGN="), "工具链里有 zipalign 也不用它（PC 与设备行为要一致）")
    }

    @Test
    @DisplayName("★★ 设备侧 bionic 前缀树必须注入 LD_LIBRARY_PATH（2026-10-17 App 内自检抓到：没有它 java 起不来）")
    fun injectsBionicLibPath() = runBlocking {
        // 真机形状：JDK 在 <prefix>/usr/lib/jvm/<ver>，aapt2 在 <prefix>/bin/（包装脚本）
        val tc = ToolchainPaths(
            aapt2 = "/tc/bin/aapt2",
            apksigner = "/tc/bin/apksigner",
            d8Jar = "/tc/d8.jar",
            androidJar = "/tc/android.jar",
            javaHome = "/tc/termux/usr/lib/jvm/java-17-openjdk",
        )
        AndroidProjectScaffold(fs).create("helloLd", "com.example.hellold", "Hello")
        AndroidBuildEngine(runner, fs, tc).build("helloLd")

        val prepare = runner.commands.first { it.contains(" prepare ") }
        assertTrue(prepare.contains("LD_LIBRARY_PATH="), "实际命令：$prepare")
        assertTrue(prepare.contains("/tc/termux/usr/lib"), "前缀树的 usr/lib 必须在里面：$prepare")
        assertTrue(prepare.contains("\$LD_LIBRARY_PATH"), "必须**追加**已有值而不是覆盖：$prepare")
    }

    @Test
    @DisplayName("★ PC 上不注入 LD_LIBRARY_PATH —— 别把宿主 /usr/lib 塞进去")
    fun doesNotInjectLibPathOnPc() = runBlocking {
        // 本类的 toolchain 固定没有 javaHome（PC 形状）
        AndroidProjectScaffold(fs).create("helloPc", "com.example.hellopc", "Hello")
        engine().build("helloPc")

        val prepare = runner.commands.first { it.contains(" prepare ") }
        assertFalse(prepare.contains("LD_LIBRARY_PATH"), "实际命令：$prepare")
    }

    @Test
    @DisplayName("★★ 每条构建命令末尾都要把产出放开给 App 读（FUSE 只认 mode；否则插 dex 报\"压缩包不存在\"）")
    fun opensOutputsToApp() = runBlocking {
        AndroidProjectScaffold(fs).create("helloOpen", "com.example.helloopen", "Hello")
        engine().build("helloOpen")

        val prepare = runner.commands.first { it.contains(" prepare ") }
        // 目标必须是**工作区绝对路径**：这条命令带 cwd，下一条可能不带
        assertTrue(
            prepare.contains("chmod -R a+rwX '$root'"),
            "必须把工作区整体放开（含目录的执行位 —— 少了它 App 进不去子目录）。实际：$prepare",
        )
        // 退出码不能被 chmod 吃掉 —— 引擎靠 exit 10/11 判断"该我插 dex / 该我对齐"
        assertTrue(prepare.contains("rc=\$?"), "实际：$prepare")
        assertTrue(prepare.trimEnd().endsWith("exit \$rc"), "实际：$prepare")
        // prepare 与 package 都不能漏（package 才是产出最终 APK 的那一步）
        assertTrue(
            runner.commands.filter { it.contains(" package ") }.all {
                it.contains("chmod -R a+rwX '$root'")
            },
            "package 步骤同样要放开：${runner.commands.filter { it.contains(" package ") }}",
        )
    }

    @Test
    @DisplayName("★★ .heracles/build 与 build/dex 必须由 **App** 先建（外置存储上 App 只能看进自己拥有的目录）")
    fun createsBuildDirsBeforeScript() = runBlocking {
        AndroidProjectScaffold(fs).create("helloOwn", "com.example.helloown", "Hello")

        // 探针 runner：一被调用就记下"此刻目录在不在"，然后立刻失败（只关心跑之前的状态）
        val seen = ArrayList<Pair<Boolean, Boolean>>()
        val spy = object : ShellRunner {
            override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
                seen.add(
                    Files.isDirectory(root.resolve("helloOwn/.heracles/build")) to
                        Files.isDirectory(root.resolve("helloOwn/.heracles/build/dex")),
                )
                return ShellResult(7, "", "探针：只看目录在不在", false, 1L)
            }
        }

        val out = AndroidBuildEngine(spy, fs, toolchain).build("helloOwn")

        assertFalse(out.ok, "探针命令注定失败")
        assertTrue(seen.isNotEmpty(), "脚本根本没被调用？")
        assertTrue(seen.first().first, "prepare 之前 .heracles/build 必须已存在（由 App 建）")
        assertTrue(seen.first().second, "…/build/dex 也必须已存在（App 要进去读 classes.dex）")
    }

    @Test
    @DisplayName("★★ shell 产出晚一瞬才可见 → 引擎要等，不许报\"压缩包不存在\"（FUSE 视线差一瞬）")
    fun waitsForLateArtifacts() = runBlocking {
        AndroidProjectScaffold(fs).create("helloLate", "com.example.hellolate", "Hello")
        val build = root.resolve("helloLate/.heracles/build")

        // 假 runner：prepare 立刻返回，产物由**另一个线程**晚 200 ms 才落盘
        // （真机上的形状：脚本已退出，而 chmod -R 还差一点没走完 ⇒ App 当下 stat 不到）
        val late = object : ShellRunner {
            override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
                val stamp = build.resolve("dex-inserted")
                return when {
                    command.contains(" prepare ") -> {
                        Thread {
                            Thread.sleep(200)
                            Files.createDirectories(build.resolve("dex"))
                            Files.writeString(build.resolve("dex/classes.dex"), "DEX-BYTES")
                            // base.apk 必须是个**真 zip**：引擎要用 ZipFs 往里插条目
                            ZipOutputStream(Files.newOutputStream(build.resolve("base.apk"))).use { zos ->
                                zos.putNextEntry(ZipEntry("AndroidManifest.xml"))
                                zos.write("M".toByteArray())
                                zos.closeEntry()
                            }
                        }.apply { isDaemon = true; start() }
                        ShellResult(0, "✓ prepare", "", false, 1L)
                    }

                    command.contains(" package ") && !Files.exists(stamp) -> ShellResult(
                        10, "",
                        "NEED_DEX_INSERT\nSTAMP=./.heracles/build/dex-inserted\n" +
                            "DEX=./.heracles/build/dex/classes.dex\nBASE=./.heracles/build/base.apk\n",
                        false, 1L,
                    )

                    command.contains(" package ") -> {
                        Files.writeString(root.resolve("helloLate/app-debug.apk"), "SIGNED")
                        ShellResult(0, "✓ 已产出", "", false, 1L)
                    }

                    else -> ShellResult(-9, "", "未预期", false, 0L)
                }
            }
        }

        val out = AndroidBuildEngine(late, fs, toolchain).build("helloLate")

        assertTrue(out.ok, "应当等得到产物，实际：${out.reason}")
        val insert = out.steps.firstOrNull { it.name.contains("插入 classes.dex") }
        assertTrue(insert != null, "插入步骤必须在：${out.steps.map { it.name }}")
        assertTrue(
            insert!!.name.contains("等可见"),
            "这条用例就是踩\"晚一瞬\"的：步骤名该留下等待痕迹（实际：${insert.name}）",
        )
    }

    @Test
    @DisplayName("★ 自动落盘一份调试密钥（设备上没有 keytool）")
    fun writesDebugKeystore() = runBlocking {
        AndroidProjectScaffold(fs).create("hello5", "com.example.hello5", "Hello")
        engine().build("hello5")
        val ks = root.resolve(Contract.Toolchain.KEYSTORE)
        assertTrue(Files.exists(ks), "调试密钥必须落盘到 ${Contract.Toolchain.KEYSTORE}")
        assertTrue(Files.size(ks) > 1000, "落盘的应当是完整的 JKS")
    }

    @Test
    @DisplayName("★ 工具链不齐 → 明确说缺什么，且**不起进程**")
    fun reportsMissingToolchain() = runBlocking {
        AndroidProjectScaffold(fs).create("hello6", "com.example.hello6", "Hello")
        val broken = AndroidBuildEngine(runner, fs, ToolchainPaths())
        val outcome = broken.build("hello6")

        assertFalse(outcome.ok)
        assertTrue(outcome.reason!!.contains("aapt2"), "要指出缺 aapt2，实际：${outcome.reason}")
        assertTrue(outcome.reason!!.contains("d8.jar"))
        assertTrue(
            runner.commands.none { it.contains("hello6") },
            "前提不满足时不得起进程（浪费一次 3 分钟的超时）",
        )
    }

    @Test
    @DisplayName("★ 不是 Android 项目 → 明确提示，不假装构建")
    fun nonProjectIsRejected() = runBlocking {
        Files.createDirectories(root.resolve("notaproject"))
        val outcome = engine().build("notaproject")
        assertFalse(outcome.ok)
        assertTrue(outcome.reason!!.contains("AndroidManifest.xml"))
    }

    @Test
    @DisplayName("★ 脚本说成功但产物不存在 → 判为失败（exit code ≠ 结果）")
    fun verifiesArtifactExists() = runBlocking {
        AndroidProjectScaffold(fs).create("hello7", "com.example.hello7", "Hello")
        // 模拟一个"报成功但没产出"的 runner
        val liar = object : ShellRunner {
            override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
                if (command.contains(" prepare ")) {
                    val d = root.resolve("hello7/.heracles/build/dex")
                    Files.createDirectories(d)
                    Files.writeString(d.resolve("classes.dex"), "D")
                    Files.createDirectories(d.parent)
                    ZipOutputStream(Files.newOutputStream(d.parent.resolve("base.apk"))).use { zos ->
                        zos.putNextEntry(ZipEntry("resources.arsc")); zos.write("A".toByteArray()); zos.closeEntry()
                    }
                }
                return ShellResult(0, "✓ 都成功了", "", false, 5L)
            }
        }
        val outcome = AndroidBuildEngine(liar, fs, toolchain).build("hello7")
        assertFalse(outcome.ok, "没有产物就不能算成功")
        assertTrue(outcome.reason!!.contains("产物不存在"), "实际：${outcome.reason}")
    }
}

/**
 * **真跑一遍脚本** —— 唯一能抓住 shell 层缺陷的测试。
 *
 * ## 为什么必须存在（2026-10-16 **真机**事故）
 *
 * 首次在真机上执行 `sh build_apk.sh all` 直接失败：
 *
 * ```
 * build_apk.sh[16]: 2: parameter not set
 * ```
 *
 * 脚本开头有 `set -u`，却写 `PROJ="$2"` —— 参数少于 3 个时**必炸**，
 * 而下面那行 `[ -z "$PROJ" ] && PROJ=.` 的兜底**永远执行不到**。
 *
 * 上面的 [BuildTemplatesTest] 断言**全部通过**：它只比对*文本*
 * （顺序、选项名、占位符），从不执行脚本。**文本正确 ≠ 能跑**。
 *
 * ## 关于可跳过
 *
 * 需要一台有 POSIX shell 的机器。找不到就 `assumeTrue` 跳过 ——
 * 宁可少测一项，也不要让"本机没装 Git Bash"把整条测试链变红。
 *
 * ⚠️ **局限**：本机跑的是 bash，设备上是 mksh。本测试只保证
 * **POSIX 语法层**没问题；mksh 特有行为仍以真机为准。
 */
class BuildScriptExecutionTest {

    /** 找一个能用的 POSIX shell；找不到返回 null。 */
    private fun findShell(): String? {
        System.getenv("HERACLES_SH")?.let { if (Files.isExecutable(Paths.get(it))) return it }
        for (name in listOf("bash", "sh")) onPath(name)?.let { return it }
        // Windows + Git for Windows：从 git.exe 反推同级的 bash.exe（不写死本机路径）
        val git = onPath("git") ?: return null
        val cand = Paths.get(git).parent?.parent?.resolve("bin/bash.exe") ?: return null
        return if (Files.isExecutable(cand)) cand.toString() else null
    }

    private fun onPath(name: String): String? {
        val path = System.getenv("PATH") ?: return null
        for (dir in path.split(java.io.File.pathSeparator)) {
            if (dir.isBlank()) continue
            for (ext in listOf("", ".exe")) {
                val c = Paths.get(dir, name + ext)
                if (Files.isExecutable(c)) return c.toString()
            }
        }
        return null
    }

    @Test
    @DisplayName("★★ 脚本能被真 shell 执行：参数少于 3 个也**不能崩**")
    fun scriptRunsWithFewArguments() {
        val shell = findShell()
        assumeTrue(shell != null, "本机没有 POSIX shell（可用 HERACLES_SH 指定）")

        val dir = createTempDirectory("build-script")
        Files.writeString(dir.resolve("build_apk.sh"), BuildTemplates.script())

        // 真机就是只传了 1 个参数（`sh build_apk.sh all`）—— 这一档必须覆盖
        val cases = listOf(
            emptyList(),
            listOf("all"),
            listOf("prepare", "."),
            listOf("package", ".", "out.apk"),
            listOf("没有这个模式"),
        )
        for (args in cases) {
            val proc = ProcessBuilder(listOf(shell, "build_apk.sh") + args)
                .directory(dir.toFile())
                .redirectErrorStream(true)
                .apply {
                    // ★ 清空 PATH：脚本必须走到"缺工具"，而不是捡到本机凑巧装的 aapt2
                    environment()["PATH"] = dir.toString()
                }
                .start()
            val out = proc.inputStream.bufferedReader().readText()
            val code = proc.waitFor()

            assertFalse(out.contains("parameter not set"), "参数少时崩了（真机事故原样复现）：\n$out")
            // bash 的措辞与 mksh 不同：mksh 说 "parameter not set"，bash 说 "unbound variable"
            assertFalse(out.contains("unbound variable"), "参数少时崩了（bash 措辞）：\n$out")
            assertFalse(out.contains("syntax error"), "语法错误：\n$out")
            assertFalse(out.contains("bad substitution"), "参数展开写法有问题：\n$out")
            // 未知模式要显式报错；其余情况是"缺工具" —— 但都必须是 2（环境不完整），不是 127/126
            assertEquals(2, code, "期望 exit 2（环境不完整）；参数=$args，实际=$code，输出：\n$out")
            assertTrue(
                out.contains("缺工具") || out.contains("未知模式"),
                "既没说缺工具也没说模式不对，说明脚本提前崩了：\n$out",
            )
        }
    }

    @Test
    @DisplayName("★★ 每个位置参数都必须写 \${N:-}（否则 set -u 下直接崩）")
    fun positionalParamsUseDefaults() {
        val s = BuildTemplates.script()
        assertTrue(s.contains("set -u"), "前提变了：脚本不再用 set -u，本约束需重新评估")
        for (name in listOf("MODE", "PROJ", "OUT")) {
            val line = s.lines().first { it.startsWith("$name=") }
            assertTrue(
                line.contains(":-"),
                "$name 必须写成 \${N:-} 兜底（set -u 下裸 \$N 会硬报 parameter not set）：$line",
            )
        }
    }

    @Test
    @DisplayName("★★ 子进程环境注入：列出的键被覆盖，未列出的原样继承（真机逼 exit 10 靠它）")
    fun envIsInjectedWithoutClearingTheRest() = runBlocking {
        val shell = findShell()
        assumeTrue(shell != null, "本机没有 POSIX shell（可用 HERACLES_SH 指定）")

        val dir = createTempDirectory("runner-env")
        val runner = LocalProcessShellRunner(
            tempDir = dir,
            // assumeTrue 已排除 null；这里 `!!` 只是让编译器满意（assumeTrue 不是契约函数）
            shell = listOf(shell!!, "-c"),
            env = mapOf("HERACLES_PROBE_ONLY" to "42"),
        )

        // ① 列出的键必须进子进程
        val r1 = runner.run("echo \"v=\$HERACLES_PROBE_ONLY\"", 30, null)
        assertEquals(0, r1.exitCode, "子进程没跑起来：${r1.stderr}")
        assertTrue(
            r1.stdout.contains("v=42"),
            "注入的环境变量没进子进程：stdout=${r1.stdout} stderr=${r1.stderr}",
        )

        // ② 未列出的键**不得**被清空 —— 清空会把 LD_LIBRARY_PATH 一起带走，
        //    真机上 Termux 的 aapt2/java 全靠它（这正是 --nozip 只改 PATH 的前提）。
        //
        //    ⚠️ 为什么不逐字比对 PATH：Windows 上 sh（Git Bash/MSYS）会把 PATH
        //    改写成 POSIX 形式，逐字比对必然假红。这里只断言"没被清掉/没被截断"。
        val r2 = runner.run("echo \"p=\$PATH\"", 30, null)
        val childPath = r2.stdout.substringAfter("p=").trim()
        assertTrue(childPath.isNotEmpty(), "未列出的键被清掉了：子进程 PATH 为空")
        assertTrue(childPath.length > 20, "子进程 PATH 看着被截断了：$childPath")
    }
}

/**
 * **SAF 构建暂存区**（F6b / ADR-032）—— 镜像 / 上限 / 回写 / 清理。
 *
 * 这一层是纯 JVM 的，所以能在 PC 上把"抄进去、抄回来、擦干净"三条纪律全部测死；
 * 真机上只剩两件事要验：DocumentFile 的真实读写、以及真实工具链下的端到端产物（报告里列为未验）。
 */
class BuildStagingTest {

    /** 内存版 SAF 工作区替身：`hasRealPath=false`（只有 content:// 语义）。 */
    private class MemoryFs(
        private val seedFiles: Map<String, ByteArray> = emptyMap(),
    ) : dev.heracles.workspace.WorkspaceFs {
        override val info = dev.heracles.workspace.WorkspaceInfo(
            Paths.get("/placeholder-not-a-workspace"), "saf", hasRealPath = false,
        )
        val files = linkedMapOf<String, ByteArray>().apply { putAll(seedFiles) }
        val reads = mutableListOf<String>()

        override suspend fun list(relativeDir: String): List<dev.heracles.workspace.FileEntry> {
            val dir = relativeDir.trim().trim('/')
            val prefix = if (dir.isEmpty()) "" else "$dir/"
            val found = linkedMapOf<String, dev.heracles.workspace.FileEntry>()
            val dirs = linkedSetOf<String>()
            for (p in files.keys) {
                if (!p.startsWith(prefix)) continue
                val rest = p.removePrefix(prefix)
                if (rest.isEmpty()) continue
                val slash = rest.indexOf('/')
                if (slash >= 0) dirs += prefix + rest.substring(0, slash)
                else found[p] = dev.heracles.workspace.FileEntry(p, files.getValue(p).size.toLong(), false)
            }
            for (d in dirs) found[d] = dev.heracles.workspace.FileEntry(d, 0L, true)
            return found.values.sortedWith(compareBy({ !it.isDirectory }, { it.relativePath }))
        }

        override suspend fun readText(relativePath: String): String = ""
        override suspend fun writeText(relativePath: String, content: String): Long = 0L
        override suspend fun exists(relativePath: String): Boolean {
            val p = relativePath.trim().trim('/')
            if (p.isEmpty()) return true
            return p in files || files.keys.any { it.startsWith("$p/") }
        }
        override suspend fun mkdirs(relativeDir: String) = Unit
        override suspend fun readBytes(relativePath: String): ByteArray {
            reads += relativePath
            return files[relativePath] ?: throw IllegalArgumentException("文件不存在：$relativePath")
        }
        override suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long {
            files[relativePath] = bytes
            return bytes.size.toLong()
        }
    }

    private fun bytes(s: String) = s.toByteArray(Charsets.UTF_8)
    private fun staging() = createTempDirectory("staging")

    @Test
    @DisplayName("★ 镜像：目录结构与字节逐字节一致（二进制含 0x00，不做编码转换）")
    fun mirrorCopiesStructureAndBytes() = runBlocking {
        val bin = byteArrayOf(0, 1, -1, 127, 10)
        val fs = MemoryFs(
            mapOf(
                "app/AndroidManifest.xml" to bytes("<manifest/>"),
                "app/src/Main.java" to bytes("class Main {}"),
                "app/res/raw/blob.bin" to bin,
            ),
        )
        val dest = staging()
        val stats = BuildStaging.mirrorInto(fs, "app", dest)

        assertEquals(bytes("<manifest/>").toList(), Files.readAllBytes(dest.resolve("AndroidManifest.xml")).toList())
        assertEquals(bytes("class Main {}").toList(), Files.readAllBytes(dest.resolve("src/Main.java")).toList())
        assertEquals(bin.toList(), Files.readAllBytes(dest.resolve("res/raw/blob.bin")).toList(), "字节通道不许改字节")
        assertEquals(3, stats.files)
        assertEquals((bytes("<manifest/>").size + bytes("class Main {}").size + bin.size).toLong(), stats.bytes)
    }

    @Test
    @DisplayName("★ 镜像排除 App 元数据（.heracles/*），但**保留签名密钥**（构建输入，否则每次换 key）")
    fun mirrorSkipsAppMetaButKeepsKeystore() = runBlocking {
        val jks = ByteArray(16) { 7 }
        val fs = MemoryFs(
            mapOf(
                "app/AndroidManifest.xml" to bytes("<m/>"),
                "app/.heracles/keys/heracles.jks" to jks,
                "app/.heracles/build/base.apk" to bytes("old"),
                "app/.heracles/logs/x.log" to bytes("log"),
            ),
        )
        val dest = staging()
        val stats = BuildStaging.mirrorInto(fs, "app", dest)

        assertEquals(jks.toList(), Files.readAllBytes(dest.resolve(".heracles/keys/heracles.jks")).toList(), "签名密钥必须带过去")
        assertFalse(Files.exists(dest.resolve(".heracles/build")), "旧构建产物不该被镜像")
        assertFalse(Files.exists(dest.resolve(".heracles/logs")), "日志不该被镜像")
        assertTrue(stats.skippedAppMeta > 0, "跳过的元数据要计数（给排查用）")
    }

    @Test
    @DisplayName("★ 镜像有字节上限：超限**明确失败**并带上「已拷多少」（不是悄悄截断）")
    fun mirrorRejectsOverSizeLimit() = runBlocking {
        val fs = MemoryFs(mapOf("p/a.bin" to ByteArray(6), "p/b.bin" to ByteArray(6)))
        val e = assertThrows(IllegalArgumentException::class.java) {
            runBlocking { BuildStaging.mirrorInto(fs, "p", staging(), maxBytes = 10) }
        }
        assertTrue(e.message!!.contains("超过上限"), "要说明撞的是上限：${e.message}")
        assertTrue(e.message!!.contains("字节"), "要给出量级：${e.message}")
    }

    @Test
    @DisplayName("★ 镜像有文件数上限（别把超大工程整体拷进 staging）")
    fun mirrorRejectsOverFileLimit() = runBlocking {
        val fs = MemoryFs(mapOf("p/a" to bytes("1"), "p/b" to bytes("2")))
        val e = assertThrows(IllegalArgumentException::class.java) {
            runBlocking { BuildStaging.mirrorInto(fs, "p", staging(), maxFiles = 1) }
        }
        assertTrue(e.message!!.contains("文件数"), "要说明撞的是文件数上限：${e.message}")
    }

    @Test
    @DisplayName("★ 镜像有深度上限（防病态深树 / 成环）")
    fun mirrorRejectsTooDeep() = runBlocking {
        val fs = MemoryFs(mapOf("p/a/b/c.txt" to bytes("x")))
        val e = assertThrows(IllegalArgumentException::class.java) {
            runBlocking { BuildStaging.mirrorInto(fs, "p", staging(), maxDepth = 1) }
        }
        assertTrue(e.message!!.contains("层"), "要说明撞的是深度上限：${e.message}")
    }

    @Test
    @DisplayName("★ 回写：目标不存在 ⇒ 写入并返回 Ok（走字节通道）")
    fun writeBackWritesWhenAbsent() = runBlocking {
        val fs = MemoryFs()
        val bytes = byteArrayOf(9, 8, 7)
        val r = BuildStaging.writeBack(fs, "app/app-debug.apk", bytes)
        assertTrue(r is BuildStaging.WriteBack.Ok, "应写入成功，实际：$r")
        assertEquals(bytes.toList(), fs.files.getValue("app/app-debug.apk").toList())
    }

    @Test
    @DisplayName("★ 回写：目标已存在 ⇒ **不覆盖**（用户文件不可逆），原内容必须一字不动")
    fun writeBackRefusesToOverwrite() = runBlocking {
        val original = bytes("user's own file")
        val fs = MemoryFs(mapOf("app/app-debug.apk" to original))
        val r = BuildStaging.writeBack(fs, "app/app-debug.apk", byteArrayOf(1, 2, 3))
        assertTrue(r is BuildStaging.WriteBack.Exists, "已存在必须返回 Exists，实际：$r")
        assertEquals(original.toList(), fs.files.getValue("app/app-debug.apk").toList(), "用户文件不许被覆盖")
    }

    @Test
    @DisplayName("★ staging 清理：整棵树删净；不存在时也返回 true（幂等）")
    fun deleteRecursivelyCleansAndIsIdempotent() {
        val dir = staging()
        Files.createDirectories(dir.resolve("a/b"))
        Files.write(dir.resolve("a/b/x.bin"), ByteArray(4))
        assertTrue(BuildStaging.deleteRecursively(dir), "整棵树应删净")
        assertFalse(Files.exists(dir), "清理后目录必须消失")

        assertTrue(BuildStaging.deleteRecursively(dir), "已不存在的目录再删应返回 true（幂等）")
    }

    // ------------------------------ 三道上限必须与 Contract 同源（F10 收尾，2026-10-18）

    @Test
    @DisplayName("★★ 文件数上限来自 Contract：恰好 = STAGING_MAX_FILES 通过，+1 被拒（测试里不写字面量）")
    fun fileCapComesFromContract() = runBlocking {
        val limit = Contract.Toolchain.STAGING_MAX_FILES

        val atLimit = (1..limit).associate { "p/f%05d.txt".format(it) to bytes("x") }
        val ok = BuildStaging.mirrorInto(MemoryFs(atLimit), "p", staging())
        assertEquals(limit, ok.files, "恰好等于上限必须通过（边界不能多拦一个）")

        val over = (1..(limit + 1)).associate { "p/f%05d.txt".format(it) to bytes("x") }
        val e = assertThrows(IllegalArgumentException::class.java) {
            runBlocking { BuildStaging.mirrorInto(MemoryFs(over), "p", staging()) }
        }
        assertTrue(
            e.message!!.contains(limit.toString()),
            "错误信息要带上限值（证明用的是同一个来源）：${e.message}",
        )
    }

    @Test
    @DisplayName("★★ 深度上限来自 Contract：恰好 = STAGING_MAX_DEPTH 通过，+1 层被拒（测试里不写字面量）")
    fun depthCapComesFromContract() = runBlocking {
        val limit = Contract.Toolchain.STAGING_MAX_DEPTH
        fun nested(dirs: Int) = (1..dirs).joinToString("/") { "d$it" }

        // 文件落在第 limit 层目录里 ⇒ 通过
        val ok = BuildStaging.mirrorInto(
            MemoryFs(mapOf("p/${nested(limit)}/f.txt" to bytes("x"))), "p", staging(),
        )
        assertEquals(1, ok.files, "第 limit 层内的文件必须被镜像")

        // 第 limit+1 层目录 ⇒ 入栈时 depth+1 > limit ⇒ 拒
        val e = assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                BuildStaging.mirrorInto(
                    MemoryFs(mapOf("p/${nested(limit + 1)}/f.txt" to bytes("x"))), "p", staging(),
                )
            }
        }
        assertTrue(
            e.message!!.contains(limit.toString()),
            "错误信息要带上限值（证明用的是同一个来源）：${e.message}",
        )
    }

    @Test
    @DisplayName("★★ 字节上限来自 Contract：恰好 = STAGING_MAX_BYTES 通过，+1 字节被拒（测试里不写字面量）")
    fun byteCapComesFromContract() = runBlocking {
        val limit = Contract.Toolchain.STAGING_MAX_BYTES
        require(limit <= Int.MAX_VALUE.toLong()) { "上限必须能装进 ByteArray 才能做边界测试" }
        val exact = ByteArray(limit.toInt())

        val ok = BuildStaging.mirrorInto(MemoryFs(mapOf("p/big.bin" to exact)), "p", staging())
        assertEquals(limit, ok.bytes, "恰好等于上限必须通过（边界不能多拦一个字节）")

        // 排序后先写 1 字节、再检查 big.bin ⇒ 1 + limit > limit 时必须拒（且不写下那 64MB）
        val e = assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                BuildStaging.mirrorInto(
                    MemoryFs(mapOf("p/a_one.bin" to bytes("y"), "p/b_big.bin" to exact)), "p", staging(),
                )
            }
        }
        assertTrue(
            e.message!!.contains(limit.toString()),
            "错误信息要带上限值（证明用的是同一个来源）：${e.message}",
        )
    }
}

/**
 * **构建剖面数据化**（P2-2 / F9a）—— 门禁。
 *
 * 要防的不是"代码能不能跑"，而是**数据与引擎变成两套真相**：
 * profile 写"prepare → 插入 dex → 对齐 → package"，引擎却按另一份字符串记录；
 * 或者有人改步骤名（它进工具结果与 UI ⇒ 等于改产品文案）而测试没红。
 *
 * ⇒ 所以这里有一条**从记录取实际序列**再和 profile 对比的测试：
 * 读 `BuildOutcome.steps`（引擎真的记下来的），不是读常量。
 */
class BuildProfileTest {

    private fun newFs(prefix: String): Pair<RealWorkspaceFs, Path> {
        val root = createTempDirectory(prefix)
        return RealWorkspaceFs.open(root) to root
    }

    private fun toolchain() = ToolchainPaths(
        aapt2 = "/opt/t/aapt2",
        zipalign = "/opt/t/zipalign",
        apksigner = "/opt/t/apksigner",
        d8Jar = "/opt/t/d8.jar",
        androidJar = "/opt/t/android.jar",
    )

    @Test
    @DisplayName("★ F9a：内置 Android profile 的步骤串/顺序/进程内标记被冻结（步骤名=产品文案，不许改）")
    fun builtInProfileIsFrozen() {
        val profile = BuildProfiles.ANDROID

        assertEquals("android", profile.id)
        assertEquals(
            listOf("prepare", "插入 classes.dex", "进程内对齐", "package"),
            profile.steps.map { it.title },
            "步骤名会进工具结果与 UI，改名=改产品文案",
        )
        assertEquals(
            listOf(
                BuildProfile.Step.Id.PREPARE,
                BuildProfile.Step.Id.INSERT_DEX,
                BuildProfile.Step.Id.ALIGN,
                BuildProfile.Step.Id.PACKAGE,
            ),
            profile.steps.map { it.id },
        )
        assertEquals(listOf(false, true, true, false), profile.steps.map { it.inProcess })

        // 静态步骤的**全名**逐字节钉住（动态步骤的细节含运行时数字，见下一条测试）
        assertEquals(
            "prepare（aapt2 compile → link → javac → d8）",
            profile.step(BuildProfile.Step.Id.PREPARE).render(),
        )
        assertEquals(
            "package（对齐 → apksigner）",
            profile.step(BuildProfile.Step.Id.PACKAGE).render(),
        )

        // 探测/脚本/产物也是"已在代码里的事实"
        assertEquals("AndroidManifest.xml", profile.probe.manifestFile)
        assertEquals("build_apk.sh", profile.buildScriptName)
        assertEquals("app-debug.apk", profile.artifact.defaultName)
        assertEquals(BuildProfiles.ANDROID_MANIFEST, profile.probe.manifestFile)
        assertEquals(BuildProfiles.BUILD_SCRIPT, profile.buildScriptName)
    }

    @Test
    @DisplayName("★★ F9a：profile 描述的步骤序列 == 引擎实际记录的步骤序列（从 BuildOutcome.steps 取）")
    fun profileStepsMatchEngineRecordedSteps() = runBlocking {
        val (fs, root) = newFs("profile-steps")
        AndroidProjectScaffold(fs).create("app", "com.example.prof", "Prof")

        val out = AndroidBuildEngine(ScriptSimulatingRunner(root), fs, toolchain()).build("app")
        assertTrue(out.ok, "构建应当成功：${out.reason}\n${out.stepsSummary()}")

        val profile = BuildProfiles.ANDROID
        assertEquals(profile.steps.size, out.steps.size, "实际步数≠profile：${out.stepsSummary()}")

        // ★ 从**记录**里取序列：按 title 前缀反查回 profile 的 id，顺序也必须一致
        val actualIds = out.steps.map { actual ->
            (
                profile.steps.firstOrNull { actual.name.startsWith(it.title) }
                    ?: error("引擎记录了 profile 里没有的步骤：${actual.name}")
                ).id
        }
        assertEquals(
            profile.steps.map { it.id }, actualIds,
            "步骤顺序与 profile 不一致（数据/代码两套真相）：${out.stepsSummary()}",
        )

        profile.steps.forEachIndexed { i, declared ->
            val actual = out.steps[i]
            if (declared.fixedDetail != null) {
                // 静态步骤：比**全文** —— 引擎自己另写一份文案会被抓到
                assertEquals(declared.render(), actual.name, "静态步骤文案被改了（进工具结果与 UI）：${actual.name}")
            } else {
                // 动态步骤：只比前缀 —— 细节含运行时数字，比全文会假红
                assertTrue(actual.name.startsWith(declared.title), "动态步骤必须以 profile 的 title 开头：${actual.name}")
                assertTrue(
                    actual.name.length > declared.title.length,
                    "动态步骤必须带运行时细节（否则 profile 声明它是动态的就自相矛盾）：${actual.name}",
                )
            }
            assertEquals(declared.inProcess, actual.inProcess, "inProcess 与 profile 不一致：${actual.name}")
        }

        // ★ 动态步骤的**文案格式**也钉住：数字每次不同，但措辞是产品文案 —— 改了要红
        assertTrue(
            Regex("^插入 classes\\.dex（\\d+ 字节(，等可见 ×\\d+)?）$").matches(out.steps[1].name),
            "插入 dex 步骤的文案格式被改了（步骤名=产品文案）：${out.steps[1].name}",
        )
        assertTrue(
            Regex("^进程内对齐（4 字节；stored \\.so 页对齐；填充 \\d+/\\d+ 条，\\d+→\\d+ 字节）$")
                .matches(out.steps[2].name),
            "进程内对齐步骤的文案格式被改了（步骤名=产品文案）：${out.steps[2].name}",
        )
    }

    @Test
    @DisplayName("★ F9a：探测规则与引擎实际判据一致（有清单⇒越过探测；无清单⇒点名缺清单）")
    fun probeMatchesActualDetection() = runBlocking {
        val (fs, root) = newFs("profile-probe")
        val runner = ScriptSimulatingRunner(root)
        // 空工具链 ⇒ 越过探测后必然停在"工具链不完整"，用它来观测"探测通过了"
        val emptyToolchain = ToolchainPaths()

        fs.mkdirs("with_manifest")
        fs.writeText("with_manifest/${BuildProfiles.ANDROID_MANIFEST}", "<manifest/>")
        val probePassed = AndroidBuildEngine(runner, fs, emptyToolchain).build("with_manifest")
        assertFalse(probePassed.ok)
        assertTrue(probePassed.reason.orEmpty().contains("工具链不完整"), "应当越过探测、停在工具链：${probePassed.reason}")
        assertFalse(
            probePassed.reason.orEmpty().contains(BuildProfiles.ANDROID_MANIFEST),
            "不该误报缺清单：${probePassed.reason}",
        )

        val noProject = AndroidBuildEngine(runner, fs, emptyToolchain).build("no_manifest")
        assertFalse(noProject.ok)
        assertTrue(
            noProject.reason.orEmpty().contains(BuildProfiles.ANDROID_MANIFEST),
            "无清单必须点名是哪个文件（与 profile 同源）：${noProject.reason}",
        )
    }

    @Test
    @DisplayName("★ F9a：默认产物名来自 profile（引擎不再自写字面量）")
    fun defaultArtifactNameComesFromProfile() = runBlocking {
        val (fs, root) = newFs("profile-artifact")
        AndroidProjectScaffold(fs).create("app", "com.example.art", "Art")

        // 不传 outApk ⇒ 用 profile.artifact.defaultName
        val out = AndroidBuildEngine(ScriptSimulatingRunner(root), fs, toolchain()).build("app")
        assertTrue(out.ok, "构建应当成功：${out.reason}")
        assertEquals("app/${BuildProfiles.ANDROID.artifact.defaultName}", out.apkPath)
        // 与改造前的字面量**逐字节一致**（零行为变化）
        assertEquals("app/app-debug.apk", out.apkPath)
    }

    @Test
    @DisplayName("★★ F9a：引擎真的**读** profile（换一份 profile ⇒ 步骤名/产物名跟着变，不改引擎）")
    fun engineFollowsInjectedProfile() = runBlocking {
        val (fs, root) = newFs("profile-injected")
        val custom = BuildProfiles.ANDROID.copy(
            id = "android-custom",
            steps = BuildProfiles.ANDROID.steps.map { it.copy(title = "V2-" + it.title) },
            artifact = BuildProfile.Artifact(defaultName = "custom-debug.apk"),
        )
        AndroidProjectScaffold(fs, custom.buildScriptName).create("app", "com.example.custom", "Custom")

        val out = AndroidBuildEngine(
            ScriptSimulatingRunner(root), fs, toolchain(), profile = custom,
        ).build("app")

        assertTrue(out.ok, "构建应当成功：${out.reason}\n${out.stepsSummary()}")
        assertEquals("app/custom-debug.apk", out.apkPath, "默认产物名必须来自 profile")
        assertEquals(
            custom.steps.map { it.title },
            out.steps.map { it.name.substringBefore("（") },
            "步骤名必须跟着 profile 变（若引擎硬编码，这条会红）",
        )
        custom.steps.forEachIndexed { i, declared ->
            if (declared.fixedDetail != null) {
                assertEquals(declared.render(), out.steps[i].name, "静态步骤全名也必须来自 profile")
            }
        }
    }

    @Test
    @DisplayName("★ F9b：内置 release 剖面 ⇒ 只改产物名（app-release.apk），步骤名/顺序不变")
    fun releaseProfileOnlyChangesArtifactName() = runBlocking {
        val (fs, root) = newFs("profile-release")
        AndroidProjectScaffold(fs).create("app", "com.example.rel", "Rel")

        val out = AndroidBuildEngine(
            ScriptSimulatingRunner(root), fs, toolchain(), profile = BuildProfiles.ANDROID_RELEASE,
        ).build("app")

        assertTrue(out.ok, "构建应当成功：${out.reason}\n${out.stepsSummary()}")
        assertEquals("app/app-release.apk", out.apkPath, "产物名必须来自 release profile")
        // release 只是**数据不同** —— 步骤名与顺序一个字都不该变（否则就是偷偷改了管线）
        assertEquals(
            BuildProfiles.ANDROID.steps.map { it.title },
            BuildProfiles.ANDROID_RELEASE.steps.map { it.title },
        )
    }
}
