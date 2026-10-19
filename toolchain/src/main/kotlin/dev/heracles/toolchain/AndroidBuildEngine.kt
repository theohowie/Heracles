package dev.heracles.toolchain

import dev.heracles.core.contract.Contract
import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import dev.heracles.core.guard.DeviceHealthSource
import dev.heracles.core.guard.ThermalGuard
import dev.heracles.core.guard.ThermalVerdict
import dev.heracles.core.progress.TaskProgress
import dev.heracles.core.progress.stepQuietly
import dev.heracles.core.text.LogFilter
import dev.heracles.workspace.RealWorkspaceFs
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.ZipAligner
import dev.heracles.workspace.ZipFs
import java.nio.file.Files
import java.nio.file.Path
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicInteger

/** 一次构建里某个阶段的结果。**逐阶段留痕**是定位失败的前提。 */
data class BuildStep(
    val name: String,
    val exitCode: Int,
    val durationMs: Long,
    /** 该阶段是否由**进程内**代码完成（而不是 shell） */
    val inProcess: Boolean = false,
)

/** 构建结果。 */
data class BuildOutcome(
    val ok: Boolean,
    /** 产出的 APK（工作区相对路径），失败时为 null */
    val apkPath: String? = null,
    val steps: List<BuildStep> = emptyList(),
    /** 给模型看的诊断（已是 ≤40 行的摘录） */
    val excerpt: String = "",
    /** 失败的一句话原因（成功时为 null） */
    val reason: String? = null,
    /**
     * 是否在 **App 内部 staging** 构建（2026-10-18，F6b / ADR-032）。
     *
     * SAF 工作区没有真实路径 ⇒ 先镜像进 staging 构建，再把产物回写用户工作区。
     * 工具层据此**如实告诉用户**"产物不是凭空出现在 SAF 里的"（默认 false ⇒ POSIX 零回退）。
     */
    val stagedBuild: Boolean = false,
    /** 镜像了多少个文件进 staging（仅 [stagedBuild] 时有意义，给用户一个规模感知）。 */
    val stagedMirrorFiles: Int = 0,
) {
    /** 逐阶段摘要，一行一个 —— 让模型一眼看出**卡在哪一步**。 */
    fun stepsSummary(): String = steps.joinToString("\n") { s ->
        val mark = if (s.exitCode == 0) "✓" else "✗"
        val where = if (s.inProcess) "（进程内）" else ""
        "$mark ${s.name}$where exit=${s.exitCode} ${s.durationMs}ms"
    }
}

/**
 * **从零构建 APK** —— `26-编码层工具链与逆向引擎.md` §6.2。需求模块 4。
 *
 * ## 硬约束：不使用 Gradle
 *
 * 流水线是 `build_apk.sh`（模板见 [BuildTemplates.BUILD_SCRIPT]）：
 *
 * ```
 * aapt2 compile → aapt2 link → javac → d8 → 塞 classes.dex → 对齐（进程内）→ apksigner
 * ```
 *
 * 本类的职责**不是**复刻这条流水线，而是：
 *
 * 1. 校验前提（工具链齐不齐、项目在不在），**在起进程之前**给出可操作的提示
 * 2. 注入工具路径（`AAPT2=… sh build_apk.sh …`）
 * 3. **补上脚本做不到的两步** —— 插入 `classes.dex`（设备没有 `zip` 命令）
 *    与**对齐**（设备没有 `zipalign` 命令，ADR-027）
 * 4. 按契约做熔断、超时、日志摘录、产物校验
 *
 * ## 为什么"塞 dex"这一步由本类在进程内做
 *
 * 设备 `/system/bin` 里没有 `zip`/`jar`（Android 精简掉了）。脚本遇到
 * 这种环境会以 `exit 10` 退出并打印 `STAMP=…`/`DEX=…`/`BASE=…`，
 * 本类据这些路径用 [ZipFs.putFile] 完成插入、创建 `STAMP` 后重跑 `package`。
 *
 * **这是脚本与本类之间的显式契约**（不是隐式约定）—— 所以脚本把三个路径
 * 都打印出来，而不是让本类去猜。
 *
 * 对齐同理：脚本以 `exit 11` 退出并打印 `IN=`/`OUT=`/`ASTAMP=`，
 * 本类用 [ZipAligner] 在进程内对齐、自校验、创建 `ASTAMP` 后重跑。
 *
 * ## 前置条件（真机上必须由用户/环境提供）
 *
 * | 组件 | 从哪来 |
 * |---|---|
 * | `javac` | **设备没有 JDK** ⇒ Termux 的 `openjdk-17` 或 proot 环境 |
 * | `aapt2` / `apksigner` | Android SDK build-tools（需下载/推入） |
 * | `d8.jar` / `android.jar` | 同上 |
 *
 * (`zipalign` **不在**这张表里 —— Android 上没有它，对齐由本类在进程内做。)
 *
 * 找不到时**明确说缺什么**（`26` §7.2：只说"失败"会让模型去改 Java 代码，
 * 那是浪费轮次且必然再失败）。
 */
class AndroidBuildEngine(
    private val runner: ShellRunner,
    private val fs: WorkspaceFs,
    private val toolchain: ToolchainPaths,
    private val health: DeviceHealthSource? = null,
    /**
     * 进度旁路 —— App 用它把"正在构建"挂到前台服务 + 通知栏（见 [TaskProgress]）。
     * 默认 [TaskProgress.NONE]：CLI / 单测不关心进度，行为与以前**完全一致**。
     */
    private val progress: TaskProgress = TaskProgress.NONE,
    /**
     * **SAF 工作区的构建暂存根**（2026-10-18，F6b / ADR-032）—— App 传
     * `getExternalFilesDir(null)/build-staging`。
     *
     * ⚠️ **不能放 `cacheDir`/`filesDir`**（App 私有 `/data/data/...`）：构建管线是用
     * **shell 身份**（Shizuku/Stellar，UID 2000）跑 `aapt2`/`javac`/`d8` 的，
     * shell 进不去 App 私有目录 ⇒ 每一步都是 Permission denied。
     * `getExternalFilesDir` 在 `/sdcard/Android/data/<pkg>/files`，App 与 shell
     * **两侧都能写**（`实测-12` §14.7 / ADR-030 的证据）。
     *
     * **默认 `null`** ⇒ CLI / 单测 / POSIX 路径行为与改造前**完全一致**（零回退）。
     * SAF 且这里为 null 时 `build()` 会给一条"App 装配错误"的明确失败。
     */
    private val stagingRoot: Path? = null,
    /**
     * **staging 专用的 [ShellRunner] 工厂**（2026-10-18，F6b）。
     *
     * 为什么必须换 runner：`ShellRunner.run` 的 `cwd` 是**工作区相对**路径，
     * 而 App 侧 runner（`DeviceShellRunner`）把 cwd 映射到**用户工作区根**。
     * staging 在另一个绝对目录 ⇒ 必须由装配处给一个"把相对 cwd 映射到 staging 根"的 runner
     * （并把 `cwd = null` 也当作 staging 根，否则脚本会跑在 shell 的默认目录里）。
     *
     * App 侧实现要点见 `AgentBridge`；测试用假 runner。
     * 默认 `null` ⇒ POSIX 路径用不到它；SAF 缺它时给明确装配错误。
     */
    private val stagingRunnerFactory: ((Path) -> ShellRunner)? = null,
    /**
     * **构建剖面**（P2-2，2026-10-18）—— 探测判据 / 步骤名 / 默认产物名都从它取。
     *
     * 默认 [BuildProfiles.ANDROID] ⇒ 既有调用点（含位置参数）**零改动、零行为变化**。
     * 将来加第二份 profile（release / 另一平台）时，引擎不用改 —— 只是多一份数据。
     *
     * ⚠️ 本轮**不做 JSON 外部加载**；也确实**只有 Android 一份**。
     */
    private val profile: BuildProfile = BuildProfiles.ANDROID,
) {

    private val scaffold = AndroidProjectScaffold(fs, profile.buildScriptName)
    private val zipFs: ZipFs by lazy { ZipFs(fs.info.rootPath) }

    /**
     * **进程内对齐**（ADR-027）—— 对齐这一步不再依赖外部 `zipalign`。
     *
     * Android 上**没有** `zipalign` 这个二进制（ADR-026 真机实测），
     * 而"跳过对齐"是笔欠账：本引擎现在自己把 4 字节对齐做掉，
     * 并且做完会**重新读一遍产物**自证（见 [ZipAligner.align]）。
     */
    private val aligner: ZipAligner by lazy { ZipAligner(fs.info.rootPath) }
    private val logSeq = AtomicInteger(0)

    /**
     * 构建。
     *
     * @param projectDir 项目目录（工作区相对），`""` = 工作区根
     * @param outApk 输出文件名（**相对项目目录**），默认取
     *   [BuildProfile.Artifact.defaultName]（内置 Android 剖面 = `app-debug.apk`）
     */
    suspend fun build(projectDir: String, outApk: String = profile.artifact.defaultName): BuildOutcome {
        // ---------- ⓪ 工作区类型分叉（2026-10-18，F6a/F6b / ADR-032） ----------
        //   · POSIX（有真实根）：**就地构建** —— 下面全部代码一字未动（零回退）
        //   · SAF（只有 content://）：镜像进 App 内部 staging 构建 → 产物回写用户工作区
        //   ★ 这一步必须留在**最前面**：SAF 的 fs.info.rootPath 只是占位（进程 CWD `/`），
        //     先碰它一下（isAndroidProject / ZipFs / 脚本 cwd）就已经在跟根目录打交道了。
        if (!fs.info.hasRealPath) return buildViaStaging(projectDir, outApk)

        // ---------- ① 前提校验（在起进程之前） ----------
        //   探测判据来自 profile（`probe.manifestFile`）；**判据本身没变**：只看清单文件存在。
        if (!isAndroidProject(projectDir)) {
            return BuildOutcome(
                ok = false,
                reason = "${projectDir.ifBlank { "（工作区根）" }} 里没有 ${profile.probe.manifestFile} —— " +
                    "这里不是 Android 项目。若要新建一个，先用 scaffold_android 生成骨架再构建。",
            )
        }
        val missing = toolchain.missing()
        if (missing.isNotEmpty()) {
            return BuildOutcome(
                ok = false,
                reason = "工具链不完整，缺：${missing.joinToString("、")}。" +
                    "设备上没有 JDK/SDK，需要先把它们放进工作区的 ${Contract.Toolchain.DIR}/，" +
                    "或用环境变量 HERACLES_TOOLCHAIN 指向已装好的目录（例如 Termux 的 " +
                    "/data/data/com.termux/files/usr/bin）。${toolchain.d8Hint()}",
            )
        }

        // ---------- ② 熔断（构建是最容易过热的操作） ----------
        thermalBlock()?.let { return BuildOutcome(ok = false, reason = it) }

        val steps = ArrayList<BuildStep>()

        // ---------- ③ 每次构建都重写脚本（模板升级要能生效） ----------
        scaffold.writeBuildScript(projectDir)

        // ---------- ③b 中间目录必须由 **App** 建，不能留给脚本 ----------
        //
        // ★ 2026-10-17 真机实测（App 进程内自检抓到）：外置存储（FUSE/MediaProvider）
        //   上 App 只能"看进"**自己拥有**的目录 —— shell 建的目录，App 连 `stat` 都是
        //   `AccessDeniedException`。症状是插 dex 报"压缩包不存在"，而文件就躺在
        //   引擎要找的那个路径上（诊断见 `实测-12` §13）。
        //
        //   ⇒ 这里预建 `.heracles/build` 与 `build/dex`（App 身份创建 ⇒ App 拥有），
        //     脚本那边配套只 `rm -rf "$BUILD"/*` 清内容、**保留目录本身**。
        //     见 [appReadable] 与脚本里的同名注释。
        listOf(Contract.Toolchain.BUILD_DIR, "${Contract.Toolchain.BUILD_DIR}/dex").forEach {
            fs.mkdirs(joinRel(projectDir, it))
        }

        val keystore = ensureKeystore()
        val env = envPrefix(keystore)
        val script = profile.buildScriptName

        // ---------- ④ prepare ----------
        val prep = runner.run(
            appReadable("$env sh $script prepare . $outApk", fs.info.rootPath),
            Contract.Toolchain.BUILD_TIMEOUT_SEC,
            projectDir.ifBlank { null },
        )
        record(steps, BuildStep(profile.step(BuildProfile.Step.Id.PREPARE).render(), prep.exitCode, prep.durationMs))
        if (!prep.ok) return fail("构建在 prepare 阶段失败", projectDir, steps, prep)

        // ---------- ⑤ package（可能要求外部插入 dex / 外部对齐） ----------
        // 再次熔断：prepare 是最热的一段，跑完必须重新看一次温度
        thermalBlock()?.let { return BuildOutcome(ok = false, steps = steps, reason = it) }

        var pkg = runner.run(
            appReadable("$env sh $script package . $outApk", fs.info.rootPath),
            Contract.Toolchain.BUILD_TIMEOUT_SEC,
            projectDir.ifBlank { null },
        )

        // ---------- ⑤a 插 classes.dex（设备没有 zip 时脚本以 exit 10 交回） ----------
        if (pkg.exitCode == EXIT_NEED_DEX_INSERT) {
            val paths = parseDexInsertPaths(pkg.stderr, projectDir)
                ?: return fail(
                    "脚本要求外部插入 classes.dex，但没有给出 BASE= / DEX= / STAMP= 路径" +
                        "（脚本与本引擎版本不一致？）",
                    projectDir, steps, pkg,
                )

            // 等待次数只在"真等过"时才写进步骤名 —— 让报告能看出是不是踩到过那一瞬
            var waitedNote = ""
            val inserted = try {
                // ★ 先等它"对 App 可见"（FUSE 的 chmod 可能刚走到一半，见 awaitRegularFile）
                val waited = awaitRegularFile(fs.info.rootPath, paths.base)
                val bytes = zipFs.putFile(paths.base, "classes.dex", paths.dex)
                if (waited > 1) waitedNote = "，等可见 ×${waited - 1}"
                bytes
            } catch (e: Exception) {
                return fail("插入 classes.dex 失败：${e.message}", projectDir, steps, pkg)
            }
            // ★ 契约的一部分：插入方必须创建 STAMP，否则脚本会反复要求插入
            fs.writeText(paths.stamp, "inserted by AndroidBuildEngine\n")
            val insertStep = profile.step(BuildProfile.Step.Id.INSERT_DEX)
            record(
                steps,
                BuildStep(
                    insertStep.render("（$inserted 字节$waitedNote）"),
                    0, 0L, inProcess = insertStep.inProcess,
                ),
            )

            pkg = runner.run(
                appReadable("$env sh $script package . $outApk", fs.info.rootPath),
                Contract.Toolchain.BUILD_TIMEOUT_SEC,
                projectDir.ifBlank { null },
            )
        }
        // ---------- ⑤b 进程内对齐（Android 上没有 zipalign，脚本以 exit 11 交回） ----------
        // 顺序很关键：对齐**必须**在签名之前（`build_apk.sh` 的流水线顺序，
        // 也是 ADR-026/027 的硬约束 —— 对齐会移动字节，任何 v2/v3 签名都会失效），
        // 所以脚本会先停下来问我们，而不是自己 cp 一份未对齐的包去签名。
        if (pkg.exitCode == EXIT_NEED_ALIGN) {
            val paths = parseAlignPaths(pkg.stderr, projectDir)
                ?: return fail(
                    "脚本要求外部对齐，但没有给出 IN= / OUT= / ASTAMP= 路径" +
                        "（脚本与本引擎版本不一致？）",
                    projectDir, steps, pkg,
                )

            val result = try {
                // ★ 同一瞬之差：IN=`base.apk` 是**我们上一步刚写完**的包（见 awaitRegularFile）
                awaitRegularFile(fs.info.rootPath, paths.input)
                aligner.align(paths.input, paths.output)
            } catch (e: Exception) {
                return fail("进程内对齐失败：${e.message}", projectDir, steps, pkg)
            }
            // ★ 同一个契约：做完必须创建 ASTAMP，否则脚本会反复要求对齐
            fs.writeText(paths.stamp, "aligned by AndroidBuildEngine\n")
            val alignStep = profile.step(BuildProfile.Step.Id.ALIGN)
            record(
                steps,
                BuildStep(
                    alignStep.render(
                        "（4 字节；stored .so 页对齐；填充 ${result.padded}/${result.entries} 条，" +
                            "${result.bytesIn}→${result.bytesOut} 字节）",
                    ),
                    0, 0L, inProcess = alignStep.inProcess,
                ),
            )

            pkg = runner.run(
                appReadable("$env sh $script package . $outApk", fs.info.rootPath),
                Contract.Toolchain.BUILD_TIMEOUT_SEC,
                projectDir.ifBlank { null },
            )
            if (pkg.exitCode == EXIT_NEED_ALIGN) {
                return fail("脚本重复要求对齐 —— ASTAMP 没生效？", projectDir, steps, pkg)
            }
        }

        record(steps, BuildStep(profile.step(BuildProfile.Step.Id.PACKAGE).render(), pkg.exitCode, pkg.durationMs))
        if (!pkg.ok) return fail("构建在 package 阶段失败", projectDir, steps, pkg)

        // ---------- ⑥ 产物校验（**不要相信 exit=0**） ----------
        val apkRel = joinRel(projectDir, outApk)
        // ★ 产物是 apksigner（shell）刚写的：同样给它一个"变可见"的机会（见 awaitRegularFile）
        awaitRegularFile(fs.info.rootPath, apkRel)
        if (!fs.exists(apkRel)) {
            return BuildOutcome(
                ok = false,
                steps = steps,
                reason = "构建报成功，但产物不存在：$apkRel —— " +
                    "exit code 不等于结果（同 2026-10-10 的 H-1 教训），请检查 apksigner 的输出。",
            )
        }

        return BuildOutcome(ok = true, apkPath = apkRel, steps = steps)
    }

    /**
     * **SAF 工作区的构建路径**：镜像 → staging 内构建 → 产物回写（2026-10-18，F6b / ADR-032）。
     *
     * ## 为什么不改引擎内部逻辑
     *
     * 流水线（脚本 + 插 dex + 对齐 + 签名）全部依赖真实路径。这里在 staging 里
     * **new 一个同样的引擎**（`fs` 换成 `RealWorkspaceFs(staging)`）：
     * 同一条流水线、同一套校验、同一份契约（`exit 10` / `exit 11`），一行内部逻辑都没改。
     *
     * ## 失败语义（每条都必须**明确**，不许含糊）
     *
     * | 情形 | 行为 |
     * |---|---|
     * | 不是 Android 项目 | 失败，**不镜像**（别把无关文件拷进 staging） |
     * | 回写目标已存在 | 失败，**不覆盖**用户文件（不可逆） |
     * | 镜像超限 / 读失败 | 失败，文案带"收到了多少" + staging 已清理 |
     * | 中途构建失败 | 原样透出内层原因 + "staging 已清理：<路径>" |
     * | 回写失败 | 如实说"构建成功但回写失败"，不谎称成功 |
     *
     * staging 在 `finally` 里清理：成功 / 失败 / 抛异常都清。
     */
    private suspend fun buildViaStaging(projectDir: String, outApk: String): BuildOutcome {
        val root = stagingRoot
            ?: return BuildOutcome(
                ok = false,
                reason = "这个工作区没有真实文件路径（SAF 授权），构建需要在 App 内部的临时目录里进行，" +
                    "但当前版本没有提供临时目录。请更新或重装 App；" +
                    "或改用「默认工作区」（它有真实路径，可原地构建），" +
                    "或把项目放到有真实路径的位置（应用私有目录）后再构建。",
            )

        // ---------- ① 用户工作区里必须**真有** Android 项目（先校验，再镜像） ----------
        if (!isAndroidProject(projectDir)) {
            return BuildOutcome(
                ok = false,
                reason = "${projectDir.ifBlank { "（工作区根）" }} 里没有 ${profile.probe.manifestFile} —— " +
                    "这里不是 Android 项目。SAF 工作区会先把项目镜像进 staging 再构建，" +
                    "非项目目录**不做镜像**（不把无关文件拷进去）。" +
                    "请先用 scaffold_android 生成骨架，或把 project_dir 指向真正的项目目录。",
            )
        }

        // ---------- ② 回写目标已存在 ⇒ 失败不覆盖（用户文件不可逆） ----------
        val outRel = joinRel(projectDir, outApk)
        if (fs.exists(outRel)) {
            return BuildOutcome(
                ok = false,
                reason = "回写目标已存在：$outRel —— 不覆盖用户已有文件（覆盖不可逆）。" +
                    "请换一个 out_apk 名字再试" +
                    "（例如 ${profile.artifact.defaultName.removeSuffix(".apk")}-2.apk）。",
            )
        }

        // ---------- ③ staging：建 → 镜像 → 内层构建 → 回写 → 清理 ----------
        val stagingDir = try {
            Files.createDirectories(root)
            Files.createTempDirectory(root, "heracles-build-")
        } catch (e: Exception) {
            return BuildOutcome(
                ok = false,
                reason = "无法创建构建用的临时目录（$root）：${e.message} —— " +
                    "外部文件目录可能不可写；可改用「默认工作区」直接构建。",
            )
        }
        // ★ 内层必须用**映射到 staging** 的 runner：cwd 是工作区相对路径，
        //   App 侧 runner 会把它映射到用户工作区根 —— 不换 runner 脚本就跑到别处去了。
        val stagingRunner = try {
            stagingRunnerFactory?.invoke(stagingDir)
        } catch (e: Exception) {
            null
        } ?: run {
            BuildStaging.deleteRecursively(stagingDir)
            return BuildOutcome(
                ok = false,
                reason = "SAF 工作区构建需要专用的执行通道，但当前版本没有提供。" +
                    "请更新或重装 App；或改用「默认工作区」（它有真实路径，可原地构建）。",
            )
        }
        try {
            val stats = try {
                BuildStaging.mirrorInto(fs, projectDir, stagingDir)
            } catch (e: IllegalArgumentException) {
                return BuildOutcome(
                    ok = false,
                    reason = "镜像进 staging 失败：${e.message}\n（staging 已清理：$stagingDir）",
                )
            }

            val stagingFs = RealWorkspaceFs.open(stagingDir)
            // ★ 同一个构造函数、同一套逻辑 —— 只把 fs / runner 换成 staging 的
            //   profile 也照传：**同一份数据**驱动内外两层，避免"内外步骤名不一致"这种隐蔽分叉。
            val inner = AndroidBuildEngine(
                runner = stagingRunner,
                fs = stagingFs,
                toolchain = toolchain,
                health = health,
                progress = progress,
                profile = profile,
            )
            val built = inner.build("", outApk)
            if (!built.ok) {
                val reason = (built.reason ?: "构建失败") +
                    "\n（已在 App 内部 staging 构建（镜像 ${stats.files} 个文件）；" +
                    "staging 已清理：$stagingDir）"
                return built.copy(reason = reason)
            }

            val apkRel = built.apkPath
                ?: return BuildOutcome(
                    ok = false,
                    reason = "构建声称成功但没有给出产物路径（staging 已清理：$stagingDir）",
                )
            val bytes = try {
                stagingFs.readBytes(apkRel)
            } catch (e: Exception) {
                return BuildOutcome(
                    ok = false,
                    reason = "读取 staging 里的产物失败：${e.message}（staging 已清理：$stagingDir）",
                )
            }
            return when (val wb = BuildStaging.writeBack(fs, outRel, bytes)) {
                is BuildStaging.WriteBack.Exists -> BuildOutcome(
                    ok = false,
                    reason = "回写目标已存在：$outRel —— 不覆盖用户已有文件（构建产物未写入）。" +
                        "请换一个 out_apk 名字再试。",
                )
                is BuildStaging.WriteBack.Ok -> built.copy(
                    apkPath = wb.relativePath,
                    stagedBuild = true,
                    stagedMirrorFiles = stats.files,
                )
            }
        } catch (e: Exception) {
            // 兜底：镜像/构建设计上不抛，但磁盘写满之类仍可能抛 —— 不能让 staging 泄漏
            return BuildOutcome(
                ok = false,
                reason = "staging 构建异常：${e.message}（staging 已清理：$stagingDir）",
            )
        } finally {
            if (!BuildStaging.deleteRecursively(stagingDir)) {
                // 清理失败不掩盖结果，但必须留痕（别让人以为 staging 很干净）
                System.err.println("★ staging 清理失败（残留可能占空间）：$stagingDir")
            }
        }
    }

    /**
     * 这个目录是不是 Android 项目 —— **判据来自 profile**（`probe.manifestFile`），不硬编码。
     *
     * 判据本身与改造前**逐字节一致**：只看清单文件是否存在。
     * （`AndroidProjectScaffold.isAndroidProject` 是同一条判据的 scaffold 视角；
     * 引擎自己这条是为了让探测规则也走数据，而不是在引擎里再写一次文件名。）
     */
    private suspend fun isAndroidProject(projectDir: String): Boolean {
        val dir = projectDir.trim().trimEnd('/')
        val manifest = if (dir.isEmpty()) {
            profile.probe.manifestFile
        } else {
            "$dir/${profile.probe.manifestFile}"
        }
        return fs.exists(manifest)
    }

    /**
     * 确保有一份可用的签名密钥。
     *
     * 顺序：工具链里已有的 `heracles.jks` → 内嵌的[DebugKeystore]。
     * 内嵌那份是**公开口令的调试密钥**（同 Android SDK 的 `debug.keystore`），
     * **不得用于分发** —— 见其类注释。
     *
     * @return 传给脚本的密钥路径（若用了内嵌那份，返回工作区相对路径，
     *   脚本以项目目录为 cwd 运行，故这里返回**设备绝对路径**更稳妥）
     */
    suspend fun ensureKeystore(): String {
        // ★ 同 build()：先拦非 POSIX，再碰 fs.info.rootPath（F6a / ADR-032）
        workspacePathBlocker(fs)?.let { throw IllegalStateException(it) }
        toolchain.keystore?.let { return it }
        val rel = Contract.Toolchain.KEYSTORE
        val p = fs.info.rootPath.resolve(rel)
        if (!Files.exists(p)) {
            Files.createDirectories(p.parent)
            Files.write(p, DebugKeystore.bytes())
        }
        return p.toString()
    }

    // ------------------------------------------------------------------ 内部

    /** 熔断检查；被拦返回理由，放行返回 null。 */
    private suspend fun thermalBlock(): String? {
        val src = health ?: return null
        return when (val v = ThermalGuard.check(src.read())) {
            is ThermalVerdict.Pause -> "★ 已暂停：${v.reason}"
            ThermalVerdict.Allow -> null
        }
    }

    private data class DexInsertPaths(val base: String, val dex: String, val stamp: String)

    private data class AlignPaths(val input: String, val output: String, val stamp: String)

    /**
     * 从脚本 stderr 里取出 `BASE=`/`DEX=`/`STAMP=` 三行，并转成**工作区相对**路径。
     *
     * 脚本以项目目录为 cwd 运行，所以它给出的是项目相对路径（`./.heracles/build/…`）；
     * 工作区相对路径要再把项目目录拼回来。取不到任何一项就返回 null（**不猜**）。
     */
    private fun parseDexInsertPaths(stderr: String, projectDir: String): DexInsertPaths? {
        fun value(key: String): String? = stderr.lineSequence()
            .firstOrNull { it.startsWith("$key=") }
            ?.substringAfter('=')
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { joinRel(projectDir, it) }

        val base = value("BASE") ?: return null
        val dex = value("DEX") ?: return null
        val stamp = value("STAMP") ?: return null
        return DexInsertPaths(base, dex, stamp)
    }

    /**
     * 从脚本 stderr 里取出 `IN=`/`OUT=`/`ASTAMP=` 三行（**与 dex 插入同一套契约**：
     * 脚本做不了的那一步，就把需要的路径打出来交给调用方）。
     *
     * 键名刻意与 `BASE`/`DEX`/`STAMP` 区分开，这样两套路径同时出现在日志里
     * 也不会被解析混（脚本出错时 stderr 里可能两段都有）。
     */
    private fun parseAlignPaths(stderr: String, projectDir: String): AlignPaths? {
        fun value(key: String): String? = stderr.lineSequence()
            .firstOrNull { it.startsWith("$key=") }
            ?.substringAfter('=')
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { joinRel(projectDir, it) }

        val input = value("IN") ?: return null
        val output = value("OUT") ?: return null
        val stamp = value("ASTAMP") ?: return null
        return AlignPaths(input, output, stamp)
    }

    private fun envPrefix(keystore: String): String = buildList {
        // ★ 设备上没有 PATH 里的 java/javac —— 定位到 JDK 就注入 JAVA_HOME 并把
        //   <JDK>/bin 挂到 PATH 最前面（PATH 里的旧值用 $PATH 保住，PC 上不动它）。
        //   PC 上 javaHome 为 null（JDK 本就在 PATH 里），这段什么都不做。
        toolchain.javaHome?.let {
            add("JAVA_HOME=${quote(it)}")
            add("PATH=\"${it}/bin:\$PATH\"")
        }
        // ★ bionic 前缀树的库目录（2026-10-17 **App 进程内**自检抓到）。
        //
        //   Termux 的 java/javac 是 bionic 动态链接的，libz.so.1 等就在前缀树的
        //   usr/lib 里；没有 LD_LIBRARY_PATH 就 **CANNOT LINK EXECUTABLE**。
        //   CLI 那条路之所以"看起来不需要"，是因为它的包装脚本自己 export 了
        //   （见 ToolchainPaths.bionicLibDirs 的注释）—— App 进程内没有这层包装。
        //
        //   追加而不是覆盖：包装脚本/用户环境已有的值要保住。
        //   只在**像 Termux 前缀树**时才加（PC 上这个列表为空，什么都不动）。
        toolchain.bionicLibDirs().takeIf { it.isNotEmpty() }?.let {
            add("LD_LIBRARY_PATH=\"${it.joinToString(":")}:\$LD_LIBRARY_PATH\"")
        }
        toolchain.aapt2?.let { add("AAPT2=${quote(it)}") }
        // ★ 对齐走**进程内**（ADR-027）：脚本遇到此模式会以 exit 11 交回，
        //   由本引擎用 ZipAligner 做，然后重跑 package 让它继续签名。
        //   这里**不再**注入 ZIPALIGN —— 有外部 zipalign 也不用它：
        //   同一份逻辑在 PC 与设备上行为一致，而且自带校验（外部二进制在
        //   Android 上根本不存在，见 ADR-025/026）。
        add("ALIGN_MODE=inprocess")
        toolchain.apksigner?.let { add("APKSIGNER=${quote(it)}") }
        toolchain.d8Jar?.let { add("D8_JAR=${quote(it)}") }
        toolchain.androidJar?.let { add("ANDROID_JAR=${quote(it)}") }
        add("KEYSTORE=${quote(keystore)}")
        add("KS_PASS=${DebugKeystore.PASS}")
        add("KEY_ALIAS=${Contract.Toolchain.KEY_ALIAS}")
        add("MIN_SDK=${Contract.Toolchain.MIN_SDK}")
        add("TARGET_SDK=${Contract.Toolchain.TARGET_SDK}")
    }.joinToString(" ")

    /**
     * 失败：**全量日志落盘 + ≤40 行摘录**进上下文。
     *
     * 与 `run_shell_command` 同一套纪律（`26` §7.3）：上下文里只放摘录，
     * 细节让模型自己去 `read_file` —— 否则 append-only 的历史里会永久
     * 压着几百行编译器输出。
     */
    private suspend fun fail(
        prefix: String,
        projectDir: String,
        steps: List<BuildStep>,
        last: ShellResult,
    ): BuildOutcome {
        val rel = joinRel(
            projectDir,
            "${Contract.Toolchain.LOG_DIR}/build-fail-${LocalDate.now().format(DateTimeFormatter.BASIC_ISO_DATE)}-${logSeq.incrementAndGet()}.log",
        )
        val logFile = try {
            fs.writeText(rel, "# $prefix\n\n" + last.combined())
            rel
        } catch (e: Exception) {
            // 日志落盘失败**不得**影响诊断结论 —— 摘录仍然可用
            null
        }
        val excerpt = LogFilter.extract(last.combined(), last.exitCode, logFile)
        return BuildOutcome(
            ok = false,
            steps = steps,
            excerpt = LogFilter.format(excerpt, last.exitCode, last.timedOut),
            reason = "$prefix（exit=${last.exitCode}）",
        )
    }

    /** 拼相对路径，顺手处理 `./` 前缀与空目录。 */
    private fun joinRel(dir: String, name: String): String {
        val d = dir.trim().trimEnd('/').removePrefix("./").trimEnd('/')
        val n = name.trim().trimStart('/').removePrefix("./")
        return if (d.isEmpty()) n else "$d/$n"
    }

    /**
     * 记一步，**同时**把进度播出去。
     *
     * 两件事写在一处的理由：`BuildStep` 是**结果**（回给模型看的步骤摘要），
     * `progress` 是**过程**（通知栏上的实时文案）。二者永远同一个来源，
     * 分开写迟早会出现"通知说到了某步、摘要里没有"这种自相矛盾。
     *
     * [steps] 由调用方传入（它是 `build()` 的局部变量）—— 刻意**不做成字段**：
     * 引擎实例会跨多次构建复用，字段会让上一次的步骤串到这一次。
     *
     * 进度是旁路（[stepQuietly] 吞异常），所以这里绝不影响构建结果。
     */
    private fun record(steps: MutableList<BuildStep>, step: BuildStep) {
        steps.add(step)
        progress.stepQuietly("${if (step.exitCode == 0) "✓" else "✗"} ${step.name}")
    }

    private fun quote(s: String): String = "\"$s\""

    companion object {
        /** 脚本约定：需要外部插入 `classes.dex`。 */
        const val EXIT_NEED_DEX_INSERT = 10

        /**
         * 脚本约定：需要外部**对齐**（`ALIGN_MODE=inprocess`）。
         *
         * 与 [EXIT_NEED_DEX_INSERT] 同一个套路：脚本把做不了的那步交回来，
         * 并把需要的路径打在 stderr 上；调用方做完创建 STAMP 再重跑。
         */
        const val EXIT_NEED_ALIGN = 11
    }
}
