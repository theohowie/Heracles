package dev.heracles.toolchain

import dev.heracles.core.contract.Contract
import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import dev.heracles.core.progress.TaskProgress
import dev.heracles.core.progress.stepQuietly
import dev.heracles.core.text.LogFilter
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.ZipAligner
import dev.heracles.workspace.ZipFs
import java.nio.file.Files
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicInteger

/** 逆向流水线的一步。 */
data class ApkStep(
    val name: String,
    val exitCode: Int,
    val inProcess: Boolean = false,
)

/** 逆向操作的结果。 */
data class ApkOutcome(
    val ok: Boolean,
    /** 产出的 APK（工作区相对），未产出时 null */
    val apkPath: String? = null,
    /** 摊开到的目录（工作区相对），仅 decompile 有 */
    val dirPath: String? = null,
    val steps: List<ApkStep> = emptyList(),
    val excerpt: String = "",
    val reason: String? = null,
) {
    fun stepsSummary(): String = steps.joinToString("\n") { s ->
        val mark = if (s.exitCode == 0) "✓" else "✗"
        "$mark ${s.name}${if (s.inProcess) "（进程内）" else ""} exit=${s.exitCode}"
    }
}

/**
 * **APK 逆向与签名** —— `26-编码层工具链与逆向引擎.md` §6.3。需求模块 3。
 *
 * ## 为什么"摊开"与"打包"用进程内代码（不用 `unzip`/`zip`）
 *
 * 设备上**没有** `unzip` / `zip` / `jar`。而 [ZipFs] 是纯 JVM 的，
 * 既能在真机上跑，也能在 PC 上测（`实测-04` 的内存纪律同样适用：
 * 流式拷贝，不把整个 dex 读进内存）。
 *
 * ## 诚实的边界：能做什么、不能做什么
 *
 * | 操作 | 需要什么 | 没有时的行为 |
 * |---|---|---|
 * | 摊开资源 / 清单 / assets | 只要 [ZipFs] | ✅ 总能做 |
 * | **改 smali** | `baksmali.jar` + `smali.jar` | ❌ 明确报"缺 baksmali.jar"，**不假装成功** |
 * | 只换/加文件（assets、图标、配置） | 只要 [ZipFs] | ✅ 总能做 |
 * | 签名 | **进程内对齐**（[ZipAligner]）+ `apksigner` + 密钥 | ❌ 明确报缺哪个（`zipalign` **不需要**，ADR-027） |
 *
 * ⚠️ **不含** `apktool`：apktool 需要它自己的 `aapt2` 变体与框架资源，
 * 在裸设备上的成功率低。本层做的是"**能改文件就能改包**"这一最小闭环，
 * 而不是 apktool 的全功能替代。
 */
class ApkReverseEngine(
    private val runner: ShellRunner,
    private val fs: WorkspaceFs,
    private val toolchain: ToolchainPaths,
    /**
     * 进度旁路 —— App 用它把\"正在摊开/重打包/签名\"挂到前台服务 + 通知栏
     * （见 [TaskProgress]）。默认 [TaskProgress.NONE]：CLI / 单测行为不变。
     */
    private val progress: TaskProgress = TaskProgress.NONE,
) {

    private val zipFs: ZipFs by lazy { ZipFs(fs.info.rootPath) }
    private val logSeq = AtomicInteger(0)

    /**
     * 非 POSIX 工作区的统一拒绝（2026-10-18，F6a / ADR-032）。
     *
     * **必须在每个公共入口的第一行调用** —— 先于任何碰 `fs.info.rootPath` 的代码
     * （SAF 的 rootPath 只是占位 CWD，碰了就等于在跟 `/` 打交道）。
     *
     * @return `null` = 可以继续；非 null = 给模型看的拒绝结果
     */
    private fun blockNonPosix(): ApkOutcome? =
        workspacePathBlocker(fs)?.let { ApkOutcome(ok = false, reason = it) }

    /**
     * 摊开 APK。
     *
     * @param apk 工作区相对路径
     * @param outDir 摊开到的目录（工作区相对）
     * @param withSmali 是否顺带反编译 smali（需要 `baksmali.jar`）
     */
    suspend fun decompile(apk: String, outDir: String, withSmali: Boolean = true): ApkOutcome {
        blockNonPosix()?.let { return it }
        val steps = ArrayList<ApkStep>()

        // ★ 目标目录必须【空】（2026-10-17 真机实测抓到的污染，见 `实测-12` §11 坑 22）
        //
        // 解包**只写不删**（[ZipFs.unzip] 只 createDirectories + 写文件）。往一个已经摊开过
        // 别的包的目录里再摊开，会**留下上一个包的残余文件**；而 [recompile] 是把"目录里
        // 有什么"打成包 ⇒ 残余会被**静默打进产物**，`ok=true`、装得上、但包里多了不属于
        // 这个 APK 的东西。
        //
        // 今天就是被这条咬到的：复跑探针时，上一次 `--smali` 留下的 `smali/` 让这一次
        // "只改资源"的运行**偷偷走了汇编分支**（`--smali = false` 却汇编了）。
        // 与 G15 同源：**不能让"我做了什么"取决于上一次留下的垃圾**。
        if (outDir.isNotBlank()) {
            val existing = runCatching { fs.list(outDir) }.getOrDefault(emptyList())
            if (existing.isNotEmpty()) {
                return ApkOutcome(
                    ok = false,
                    reason = "目标目录 $outDir 不是空的（${existing.size} 个条目）。解包**只写不删**，" +
                        "往旧目录里摊开会把上一个包的残余文件一起打进产物 —— 请换一个空目录" +
                        "（或先删掉它）再试。",
                )
            }
        }

        // ① 进程内解包（不需要任何外部工具）
        // ★ 待解的包若是 shell 刚写出来的，给它一瞬变可见（见 awaitRegularFile）
        awaitRegularFile(fs.info.rootPath, apk)
        val entries = try {
            zipFs.unzip(apk, outDir)
        } catch (e: Exception) {
            return ApkOutcome(ok = false, reason = "解包失败：${e.message}")
        }
        record(steps, ApkStep("解包（${entries.entries} 个条目）", 0, inProcess = true))

        // ② 看清里面有什么 —— 这是"下一步该做什么"的依据
        val listing = try {
            zipFs.listEntries(apk)
        } catch (e: Exception) {
            emptyList()
        }
        val dexes = listing.filter { !it.isDirectory && it.name.endsWith(".dex") }.map { it.name }

        // ③ 可选：dex → smali
        if (withSmali && dexes.isNotEmpty()) {
            val baksmali = toolchain.baksmaliJar
                ?: return ApkOutcome(
                    ok = false,
                    dirPath = outDir,
                    steps = steps,
                    reason = "APK 已摊开到 $outDir，但**无法反编译 smali**：缺 baksmali.jar。" +
                        "把它放进 ${Contract.Toolchain.DIR}/（或用 HERACLES_TOOLCHAIN 指定目录）后重试。" +
                        "只改资源/assets 的话可以不带 smali 继续。",
                )
            // ★ 每个 dex 一个目录（apktool 的约定）：classes.dex → smali/，
            //   classes2.dex → smali_classes2/ …… 旧实现把所有 dex 都倒进同一个
            //   `smali/`，多 dex 的包会**互相覆盖**且不报错。
            dexes.forEachIndexed { i, dex ->
                val smaliDir = smaliDirFor(i)
                // ★ 目录必须由 **App** 建：外置存储（FUSE）上 App 只能"看进"自己拥有的目录，
                //   shell 建的 `smali/` 会让 App 连 `stat` 都是 AccessDenied ——
                //   而"读 smali 源码改它"正是逆向这条路的**全部意义**（见 `appReadable`）。
                fs.mkdirs(if (outDir.isBlank()) smaliDir else "$outDir/$smaliDir")
                val cmd = "java -Xmx${Contract.Toolchain.JVM_HEAP} -cp \"$baksmali\" " +
                    "com.android.tools.smali.baksmali.Main disassemble " +
                    "\"$outDir/$dex\" -o \"$outDir/$smaliDir\""
                val r = runner.run(
                    appReadable(cmd, fs.info.rootPath),
                    Contract.Toolchain.DECOMPILE_TIMEOUT_SEC,
                    null,
                )
                record(steps, ApkStep("baksmali $dex → $smaliDir/", r.exitCode))
                if (!r.ok) return fail("反编译 $dex 失败", steps, r)
            }
        }

        return ApkOutcome(ok = true, dirPath = outDir, steps = steps)
    }

    /**
     * 重新打包并签名。
     *
     * ## 目录约定（与 apktool 保持一致的直觉）
     *
     * ```
     * <dir>/AndroidManifest.xml   ← 二进制清单（aapt2 产出的那份，别改）
     * <dir>/resources.arsc
     * <dir>/res/…  <dir>/assets/…
     * <dir>/smali/                ← classes.dex 反汇编出来的（多 dex：smali_classes2/…）
     * <dir>/classes.dex           ← smali 汇编回去的产物 / 未改 smali 时的原件
     * ```
     *
     * ## ★ 只要 smali 目录存在，就**总是**重新汇编（2026-10-16 修的缺陷）
     *
     * 旧实现的判据是"有 `smali/` **且没有** `classes.dex`"。而 [decompile] 摊开时
     * **两份都留下**（解包得到的 `classes.dex` + 反汇编得到的 `smali/`），于是
     * 这个条件**永远为假** —— 模型改了 smali，重打包却静默把**原始 dex** 装回去，
     * 报成功、界面纹丝不动。这正是仓库明令禁止的那类"假信息"
     * （与门禁 G15 同源：**exit=0 不等于做了事**）。
     *
     * 现在的语义：`smali/`、`smali_classesN/` 是**权威来源**，存在即覆盖同名 dex；
     * 只有目录里没有 smali 目录时才直接用现成的 `classes.dex`（"只改资源"那条路）。
     * 缺 `smali.jar` 时**明确失败**，不静默跳过。
     *
     * ⚠️ 写这类注释时**别在 KDoc 里写 "smali 目录通配" 的那种写法**（`smali` 后面紧跟
     * 斜杠与星号）：那样会在注释中途就**提前关掉块注释**，剩下半个 KDoc 被当代码解析，
     * 报 `Expecting member declaration` 且位置指向注释里某一行，极难定位
     * （2026-10-16 就踩了：这一行本来是想警告它，结果自己又写了一遍 —— 直接让
     * `:toolchain:compileKotlin` 失败）。
     */
    suspend fun recompile(dir: String, outApk: String): ApkOutcome {
        blockNonPosix()?.let { return it }
        val steps = ArrayList<ApkStep>()
        val d = dir.trim().trimEnd('/')

        val smaliDirs = smaliDirsIn(d)
        val hasDex = fs.exists("$d/classes.dex")

        // shell（smali.jar）写出来的 dex：后面要由**进程内**打包读走，
        // 中间只隔几毫秒 —— 见 [awaitRegularFile]（FUSE 的 chmod 还没走完）
        val shellDex = ArrayList<String>()

        if (smaliDirs.isNotEmpty()) {
            val smali = toolchain.smaliJar
                ?: return ApkOutcome(
                    ok = false,
                    steps = steps,
                    reason = "目录里有 ${smaliDirs.joinToString("、") { "$it/" }}（smali 源码）" +
                        "但没有 smali.jar 汇编它。把它放进 ${Contract.Toolchain.DIR}/ 后重试 —— " +
                        "**不能**退回用现成的 classes.dex：那会把你的 smali 改动丢掉。",
                )
            for (dirName in smaliDirs) {
                val dexName = dexNameFor(dirName)
                val cmd = "java -Xmx${Contract.Toolchain.JVM_HEAP} -cp \"$smali\" " +
                    "com.android.tools.smali.smali.Main assemble \"$d/$dirName\" -o \"$d/$dexName\""
                val r = runner.run(
                    appReadable(cmd, fs.info.rootPath),
                    Contract.Toolchain.RECOMPILE_TIMEOUT_SEC,
                    null,
                )
                record(steps, ApkStep("$dirName/ → $dexName", r.exitCode))
                if (!r.ok) return fail("汇编 $dirName 失败", steps, r)
                shellDex.add("$d/$dexName")
            }
        } else if (!hasDex) {
            return ApkOutcome(
                ok = false,
                steps = steps,
                reason = "目录里既没有 classes.dex 也没有 smali/ —— 这不是一个能重新打包的 APK 目录。" +
                    "如果是只改资源，请确认摊开时用的是 apk_decompile。",
            )
        }

        // 进程内打包（确定性：条目排序 + 固定时间戳）
        // ★ apkLayout = true：`resources.arsc` 与 `*.so` 保持 **未压缩** ——
        //   这是"对齐有意义"的前提（见 ZipFs.zip 的 KDoc 与 ZipAligner）。
        //   不这么做的话，重打包出来的包虽然能装，却丢掉了 mmap 直读这条特性。
        //
        // ★ 打包前先等 shell 刚写的 dex 对 App 可见（见 awaitRegularFile）：
        //   不然会报"源文件不存在"，而文件就在那儿。
        shellDex.forEach { awaitRegularFile(fs.info.rootPath, it) }
        val packed = try {
            zipFs.zip(d, outApk, apkLayout = true)
        } catch (e: Exception) {
            return ApkOutcome(ok = false, steps = steps, reason = "打包失败：${e.message}")
        }
        record(steps, ApkStep("打包（${packed.entries} 个条目）", 0, inProcess = true))

        // 签名（zipalign 必须在 apksigner 之前）
        val signed = sign(outApk, outApk)
        return signed.copy(steps = steps + signed.steps)
    }

    /**
     * 签名（会自校验）。
     *
     * 顺序：**对齐 → apksigner sign → apksigner verify**。
     *
     * ## 对齐为什么是「进程内」的（ADR-027）
     *
     * 原先是「有 `zipalign` 就用，没有就 `cp` 跳过」。但 **Android 上没有
     * `zipalign`**（ADR-026 真机实测），于是设备侧永远是「跳过」——
     * 那是笔欠账。现在直接用 [ZipAligner] 在进程内做，PC 与设备行为一致。
     *
     * 对齐的输出与输入**不能是同一个文件**，所以先写到
     * `.heracles/build/aligned.apk` 再签出到 [outApk]。
     *
     * ⚠️ 对齐**失败**时（例如目标包已带 v2/v3 签名块 —— 对齐会令其失效）
     * 不硬撑：退回到原样复制，并把**原因留在步骤里**（模型要看得到"这次没对齐"）。
     */
    suspend fun sign(apk: String, outApk: String): ApkOutcome {
        blockNonPosix()?.let { return it }
        // ★ zipalign **不再是前提**（ADR-026/027，2026-10-16 真机实测）：
        //   Android 上没有这个二进制，而未对齐的 APK 照样能装；
        //   对齐由 [ZipAligner] 在进程内完成。
        if (toolchain.apksigner == null) {
            return ApkOutcome(ok = false, reason = "签名需要 apksigner，工具链里没有。")
        }

        val keystore = ensureKeystore()
        val alignedRel = "${Contract.Toolchain.BUILD_DIR}/aligned.apk"
        val steps = ArrayList<ApkStep>()

        // ---------- 对齐（必须在 apksigner 之前） ----------
        val alignStep = try {
            // 待签的包可能是 shell 刚写出来的（见 awaitRegularFile）
            awaitRegularFile(fs.info.rootPath, apk)
            val r = ZipAligner(fs.info.rootPath).align(apk, alignedRel)
            ApkStep(
                "进程内对齐（填充 ${r.padded}/${r.entries} 条，${r.bytesIn}→${r.bytesOut} 字节）",
                0,
                inProcess = true,
            )
        } catch (e: Exception) {
            val cp = runner.run(
                appReadable("cp \"$apk\" \"$alignedRel\"", fs.info.rootPath),
                Contract.Toolchain.SIGN_TIMEOUT_SEC,
                null,
            )
            if (!cp.ok) return fail("复制待签名 APK 失败（对齐回退）", steps, cp)
            ApkStep("对齐跳过：${e.message?.lineSequence()?.first()?.take(80)}", cp.exitCode)
        }
        record(steps, alignStep)

        val cmd = "${toolchain.apksignerCommand()} sign --ks \"$keystore\" " +
            "--ks-pass pass:${DebugKeystore.PASS} --ks-key-alias ${Contract.Toolchain.KEY_ALIAS} " +
            "--key-pass pass:${DebugKeystore.PASS} " +
            "--min-sdk-version ${Contract.Toolchain.MIN_SDK} " +
            "--out \"$outApk\" \"$alignedRel\""
        val sign = runner.run(
            appReadable(cmd, fs.info.rootPath),
            Contract.Toolchain.SIGN_TIMEOUT_SEC,
            null,
        )
        record(steps, ApkStep("apksigner sign", sign.exitCode))
        if (!sign.ok) return fail("签名失败", steps, sign)

        // ★ 自校验：**不要相信 exit=0**（H-1 教训）
        val verify = runner.run(
            appReadable(
                "${toolchain.apksignerCommand()} verify --min-sdk-version " +
                    "${Contract.Toolchain.MIN_SDK} \"$outApk\"",
                fs.info.rootPath,
            ),
            Contract.Toolchain.SIGN_TIMEOUT_SEC,
            null,
        )
        record(steps, ApkStep("apksigner verify", verify.exitCode))
        if (!verify.ok) return fail("签名自校验失败（产物不可安装）", steps, verify)

        // 产物存在性也要看（签名成功但没写出文件极罕见，但代价很低）
        if (!fs.exists(outApk)) {
            return ApkOutcome(
                ok = false, steps = steps,
                reason = "签名报成功但产物不存在：$outApk",
            )
        }

        return ApkOutcome(ok = true, apkPath = outApk, steps = steps)
    }

    /**
     * `class` → `dex` 转换（`d8_convert` 工具的后端）。
     *
     * ⚠️ 必须用 `java -cp <d8.jar>` 调用 [com.android.tools.r8.D8]：
     * build-tools 里那个 `d8` 包装脚本**传不进 JVM 参数**，
     * 于是无法限制堆大小 —— 而限制堆（`-Xmx512m`）是设备上跑得动的关键
     * （`实测-04`：可用内存被压到 0.5 GB 时代价是 10× 变慢）。
     */
    suspend fun d8(classDir: String, outDir: String): ApkOutcome {
        blockNonPosix()?.let { return it }
        val d8 = toolchain.d8Jar
            ?: return ApkOutcome(ok = false, reason = "缺 d8.jar，无法把 class 转成 dex。")
        val androidJar = toolchain.androidJar
            ?: return ApkOutcome(ok = false, reason = "缺 android.jar，d8 需要它做引用校验。")

        val classes = collectFiles(classDir, ".class")
        if (classes.isEmpty()) {
            return ApkOutcome(ok = false, reason = "$classDir 里没有 .class 文件。")
        }

        val cmd = "java -Xmx${Contract.Toolchain.JVM_HEAP} -cp \"$d8\" com.android.tools.r8.D8 " +
            "--lib \"$androidJar\" --min-api ${Contract.Toolchain.MIN_SDK} " +
            "--output \"$outDir\" " + classes.joinToString(" ") { "\"$it\"" }
        val r = runner.run(
            appReadable(cmd, fs.info.rootPath),
            Contract.Toolchain.D8_TIMEOUT_SEC,
            null,
        )
        val steps = listOf(ApkStep("d8（${classes.size} 个 class）", r.exitCode))
        if (!r.ok) return fail("d8 转换失败", steps, r)
        if (!fs.exists("$outDir/classes.dex")) {
            return ApkOutcome(
                ok = false, steps = steps,
                reason = "d8 报成功但没有产出 $outDir/classes.dex（exit code ≠ 结果）",
            )
        }
        return ApkOutcome(ok = true, dirPath = outDir, steps = steps)
    }

    // ------------------------------------------------------------------ 内部

    private suspend fun ensureKeystore(): String {
        toolchain.keystore?.let { return it }
        val rel = Contract.Toolchain.KEYSTORE
        val p = fs.info.rootPath.resolve(rel)
        if (!Files.exists(p)) {
            Files.createDirectories(p.parent)
            Files.write(p, DebugKeystore.bytes())
        }
        return p.toString()
    }

    // ---------- smali 目录约定（`decompile` 与 `recompile` 必须一致） ----------

    /**
     * 记一步，**同时**把进度播出去 —— 与 `AndroidBuildEngine.record()` 同一个约定：
     * 步骤摘要（结果）与通知栏文案（过程）永远同一个来源。
     *
     * [steps] 由调用方传入（各方法是各自的局部变量），刻意不做成字段 ——
     * 引擎实例跨多次调用复用，字段会把上一次的步骤串进来。
     *
     * 进度是旁路（`stepQuietly` 吞异常），绝不影响逆向结果。
     */
    private fun record(steps: MutableList<ApkStep>, step: ApkStep) {
        steps.add(step)
        progress.stepQuietly("${if (step.exitCode == 0) "✓" else "✗"} ${step.name}")
    }

    /**
     * 第 i 个 dex（0 基）对应的 smali 目录名 —— apktool 的约定：
     * `classes.dex` → `smali/`，`classes2.dex` → `smali_classes2/`。
     */
    private fun smaliDirFor(dexIndex: Int): String =
        if (dexIndex == 0) Contract.Toolchain.SMALI_DIR
        else Contract.Toolchain.SMALI_CLASSES_PREFIX + (dexIndex + 1)

    /** 反向映射：`smali/` → `classes.dex`，`smali_classesN/` → `classesN.dex`。 */
    private fun dexNameFor(smaliDir: String): String =
        if (smaliDir == Contract.Toolchain.SMALI_DIR) "classes.dex"
        else "classes" + smaliDir.removePrefix(Contract.Toolchain.SMALI_CLASSES_PREFIX) + ".dex"

    /**
     * 目录下所有待汇编的 smali 目录，按 dex 序号排序（`smali/` 永远第一）。
     *
     * 用 [WorkspaceFs.list] 而不是"猜 1..N"：模型可能只保留其中一个目录。
     */
    private suspend fun smaliDirsIn(dir: String): List<String> {
        val names = runCatching { fs.list(dir) }.getOrDefault(emptyList())
            .filter { it.isDirectory }
            .map { it.relativePath.substringAfterLast('/') }
            .filter { it == Contract.Toolchain.SMALI_DIR || it.startsWith(Contract.Toolchain.SMALI_CLASSES_PREFIX) }
            .distinct()
        return names.sortedBy { name ->
            if (name == Contract.Toolchain.SMALI_DIR) 0
            else name.removePrefix(Contract.Toolchain.SMALI_CLASSES_PREFIX).toIntOrNull() ?: Int.MAX_VALUE
        }
    }

    /** 收集某目录下指定后缀的文件（工作区相对路径）。 */
    private fun collectFiles(dirRel: String, suffix: String): List<String> {
        val root = fs.info.rootPath
        val dir = if (dirRel.isBlank()) root else root.resolve(dirRel.trimEnd('/'))
        if (!Files.isDirectory(dir)) return emptyList()
        return Files.walk(dir).use { s ->
            s.filter { Files.isRegularFile(it) && it.fileName.toString().endsWith(suffix) }
                .sorted()
                .map { root.relativize(it).toString().replace('\\', '/') }
                .toList()
        }
    }

    private suspend fun fail(prefix: String, steps: List<ApkStep>, last: ShellResult): ApkOutcome {
        val rel = "${Contract.Toolchain.LOG_DIR}/apk-" +
            "${LocalDate.now().format(DateTimeFormatter.BASIC_ISO_DATE)}-${logSeq.incrementAndGet()}.log"
        val logFile = try {
            fs.writeText(rel, "# $prefix\n\n" + last.combined())
            rel
        } catch (e: Exception) {
            null
        }
        val excerpt = LogFilter.extract(last.combined(), last.exitCode, logFile)
        return ApkOutcome(
            ok = false,
            steps = steps,
            excerpt = LogFilter.format(excerpt, last.exitCode, last.timedOut),
            reason = "$prefix（exit=${last.exitCode}）",
        )
    }
}
