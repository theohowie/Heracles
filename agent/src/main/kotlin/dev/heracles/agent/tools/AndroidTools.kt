package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.BuildProfileLoader
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.progress.TaskProgress
import dev.heracles.core.progress.finishQuietly
import dev.heracles.core.progress.startQuietly
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolRegistry
import dev.heracles.core.tool.ToolSpec
import dev.heracles.toolchain.AndroidBuildEngine
import dev.heracles.toolchain.AndroidProjectScaffold
import dev.heracles.toolchain.ApkReverseEngine
import dev.heracles.toolchain.BuildProfiles
import dev.heracles.toolchain.ToolchainPaths
import dev.heracles.workspace.WorkspaceFs
import java.nio.file.Path

/**
 * 编码层的 6 个工具 —— `26-编码层工具链与逆向引擎.md` §4.2。需求模块 3 / 4。
 *
 * ## ⚠️ 全部是**长尾**工具，不进冻结区
 *
 * 它们只在 `search_tools` 命中后才披露（常驻上限 `Contract.Tools.FROZEN_LIMIT`，S1b 起 = 12）。
 * 理由：工具 schema 进冻结区就吃缓存前缀预算，而**可见工具过多会降低选择准确率**
 * （契约 §4.1；该规律原是在 4B / 约 10 个工具上实测的，云端阈值更宽但同样存在）。
 *
 * ⇒ 每个工具的描述都必须写**什么时候用**，因为"该不该搜它"正是模型要判断的事。
 *
 * ## 共同约定
 *
 * · 所有路径都是**工作区相对**路径（sandbox 边界由 `PathGuard` 守）
 * · 所有耗时步骤都有超时（`Contract.Toolchain.*`），且**超时会真的杀掉进程**
 * · 失败时回报的是"缺什么/哪一步错"，不是笼统的"失败"
 */

/** 脚手架 —— 需求模块 6：让模型"填空"而不是"从零写项目骨架"。 */
class ScaffoldAndroidTool(private val fs: WorkspaceFs) : AgentTool {

    private val scaffold = AndroidProjectScaffold(fs)

    override val spec = ToolSpec(
        name = "scaffold_android",
        description = "在工作区里新建一个最小可编译的 Android 项目骨架（AndroidManifest.xml、MainActivity.java、res/、build_apk.sh）。想做 Android App 但目录还是空的时先用它，再按需求改文案与布局。",
        parameters = listOf(
            ToolParam("project_dir", "string", "项目目录（相对工作区），例如 hello"),
            ToolParam("package_name", "string", "包名，全小写、至少两段，例如 com.example.hello"),
            // ★ optional = true（2026-10-18，F7b）：缺键由实现兜底 `ifBlank { "Heracles App" }`，
            //   与传空串同义 ⇒ 不该因缺键被校验器拦下。
            ToolParam(
                "app_name", "string", "应用显示名，例如 我的应用（不填时用 Heracles App）",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val dir = args["project_dir"].orEmpty().trim()
        val pkg = args["package_name"].orEmpty().trim()
        val name = args["app_name"].orEmpty().trim().ifBlank { "Heracles App" }
        if (dir.isBlank()) return ToolOutcome.Failure("project_dir 为空")
        if (pkg.isBlank()) return ToolOutcome.Failure("package_name 为空")
        return try {
            val written = scaffold.create(dir, pkg, name)
            ToolOutcome.Success(
                "已创建 Android 项目骨架：\n" + written.joinToString("\n") { "  · $it" } +
                    "\n下一步：改 res/layout/activity_main.xml 与 src/…/MainActivity.java，然后调用 build_apk。"
            )
        } catch (e: IllegalArgumentException) {
            ToolOutcome.Failure(e.message ?: "参数非法")
        } catch (e: Exception) {
            ToolOutcome.Failure("创建骨架失败：${e.message}")
        }
    }
}

/** 从零构建 APK（**不使用 Gradle**）—— 需求模块 4。 */
class BuildApkTool(
    private val fs: WorkspaceFs,
    private val toolchain: ToolchainPaths,
    private val runner: dev.heracles.core.exec.ShellRunner,
    private val health: dev.heracles.core.guard.DeviceHealthSource?,
    /** 进度旁路（App 用它挂前台服务）—— 见 [ProgressReportingTool]。 */
    private val progress: TaskProgress = TaskProgress.NONE,
    /**
     * **SAF 工作区的 staging 根**（2026-10-18，F6b / ADR-032）—— App 传
     * `getExternalFilesDir(null)/build-staging`（**不能**用 cacheDir：shell 进不去 App 私有目录）。
     * **默认 null ⇒ POSIX / CLI / 单测行为与改造前完全一致**（零回退）。
     */
    private val stagingRoot: Path? = null,
    /**
     * **staging 专用的 shell runner 工厂** —— App 传一个"cwd 相对 staging 根解析"的实现。
     * 默认 null ⇒ SAF 分支会给明确的装配错误（POSIX 用不到）。
     */
    private val stagingRunnerFactory: ((Path) -> dev.heracles.core.exec.ShellRunner)? = null,
    /**
     * **本次构建用哪份 profile**（F9b）—— 默认读工作区
     * [dev.heracles.core.contract.Contract.Toolchain.PROFILE_FILE]（不存在则内置 Android）。
     *
     * 每次 `execute` 解析一次（profile 是**装配期数据**，不进工具 schema；见 [BuildProfileLoader]）。
     * 测试注入它来覆盖/固定行为，生产不需要传。
     */
    private val profileResolver: suspend (WorkspaceFs) -> BuildProfileLoader.Result =
        { ws -> BuildProfileLoader.load(ws) },
) : AgentTool {

    private val scaffold = AndroidProjectScaffold(fs)

    override val spec = ToolSpec(
        name = "build_apk",
        // ⚠️ 描述必须与实现一致（ADR-026 / ADR-027）：Android 上**没有** zipalign 这个二进制，
        //   对齐是引擎在**进程内**用 ZipAligner 做的（且自校验、对齐必须发生在签名之前）。
        //   把 zipalign 写成流水线的一步 = 教模型去找一个不存在的工具。改前的文案是
        //   "aapt2 → javac → d8 → zipalign → apksigner"，已由 AndroidToolsTest 钉住（防回退）。
        description = "把工作区里的 Android 项目编译成可安装的 APK（aapt2 → javac → d8 → 进程内对齐（ZipAligner，ADR-027）→ apksigner，不用 Gradle）。对齐由本工具在进程内完成并自校验，不需要 zipalign 二进制（Android 上也没有它）。目录为空时会先生成骨架。构建较慢，一次只调一次。",
        parameters = listOf(
            ToolParam(
                "project_dir", "string", "项目目录（相对工作区），根目录传空字符串",
                allowEmpty = true,
            ),
            // ★ optional = true（2026-10-18，F7b）：`docs/27` §2.2 记的那次
            //   「缺少必填参数：out_apk」摩擦的**根治点** —— 引擎与工具都有默认值
            //   （`ifBlank { BuildProfiles…defaultName }` / `AndroidBuildEngine.build(outApk = …)`），
            //   缺键与传空串同义。描述里保留默认值说明，让模型知道不填会得到什么名字。
            ToolParam(
                "out_apk", "string",
                "输出文件名（相对项目目录），不填时默认 ${BuildProfiles.ANDROID.artifact.defaultName}",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val dir = args["project_dir"].orEmpty().trim()
        // 默认名**唯一来源**是 BuildProfile（F9a 收尾）：别在这里再写一个字面量
        val out = args["out_apk"].orEmpty().trim().ifBlank {
            BuildProfiles.ANDROID.artifact.defaultName
        }

        // ---- 解析本次构建的 profile（F9b）----
        // ★ 坏配置必须**明确失败**，不许静默回退到内置（那会让用户以为在用自己那份）。
        val resolution = try {
            profileResolver(fs)
        } catch (e: Exception) {
            BuildProfileLoader.Result.Invalid("解析 profile 时异常：${e.message}")
        }
        val profile = when (resolution) {
            is BuildProfileLoader.Result.Loaded -> resolution.profile
            is BuildProfileLoader.Result.Default -> resolution.profile
            is BuildProfileLoader.Result.Invalid -> return ToolOutcome.Failure(
                "构建剖面配置无效：${resolution.reason}\n" +
                    "（配置文件：${Contract.Toolchain.PROFILE_FILE}；修好它，或删掉它就会回到内置 Android 剖面。）",
            )
        }
        // 留痕：用了工作区 profile 就必须说（尤其 id="android" 覆盖内置——静默覆盖 = 看不见的分歧）
        val profileNote = (resolution as? BuildProfileLoader.Result.Loaded)?.let {
            "\n（本机构建剖面：${it.profile.id}，来源：${it.sourcePath}）"
        }.orEmpty()

        // 空目录 = 从零 → 先搭骨架（需求里的"0→1"）
        if (!scaffold.isAndroidProject(dir)) {
            val empty = fs.list(dir).isEmpty()
            if (empty) {
                val pkg = "com.heracles." + (dir.ifBlank { "root" })
                    .lowercase().replace(Regex("[^a-z0-9]"), "")
                    .ifBlank { "app" }
                try {
                    scaffold.create(dir, pkg, "Heracles App")
                } catch (e: Exception) {
                    return ToolOutcome.Failure("自动创建骨架失败：${e.message}（可以先用 scaffold_android 指定包名）")
                }
            }
        }

        // profile 是**每次构建**的输入 ⇒ 引擎按本次 profile 构造（不加 build(..., profile) 重载：
        // 那会把装配期数据变成调用期参数，到处透传，更容易两套真相）
        val engine = AndroidBuildEngine(
            runner, fs, toolchain, health, progress, stagingRoot, stagingRunnerFactory, profile,
        )
        val outcome = engine.build(dir, out)
        return if (outcome.ok) {
            ToolOutcome.Success(
                buildString {
                    append("构建成功：").append(outcome.apkPath).append('\n')
                    append(outcome.stepsSummary()).append('\n')
                    // ★ 如实告知"产物不是凭空出现在 SAF 里的"（F6b）：用户/模型都要知道它先去了 staging
                    if (outcome.stagedBuild) {
                        append("（SAF 工作区：已在 App 内部 staging 构建（镜像 ")
                        append(outcome.stagedMirrorFiles)
                        append(" 个文件），产物已回写到 ").append(outcome.apkPath).append("）\n")
                    }
                    append("下一步可以用 run_shell_command 执行 `pm install -r ")
                    append(outcome.apkPath).append("` 安装（需用户确认）。")
                    append(profileNote)
                }
            )
        } else {
            ToolOutcome.Failure(
                buildString {
                    append(outcome.reason)
                    if (outcome.steps.isNotEmpty()) {
                        append("\n已完成阶段：\n").append(outcome.stepsSummary())
                    }
                    if (outcome.excerpt.isNotBlank()) {
                        append("\n").append(outcome.excerpt)
                    }
                    append(profileNote)
                }
            )
        }
    }
}

/** 反编译 / 摊开 APK —— 需求模块 3。 */
class ApkDecompileTool(
    fs: WorkspaceFs,
    toolchain: ToolchainPaths,
    runner: dev.heracles.core.exec.ShellRunner,
    /** 进度旁路（App 用它挂前台服务）。 */
    progress: TaskProgress = TaskProgress.NONE,
) : AgentTool {

    private val engine = ApkReverseEngine(runner, fs, toolchain, progress)

    override val spec = ToolSpec(
        name = "apk_decompile",
        // ⚠️ 描述必须与实现一致：`with_smali` **默认 true** ⇒ 包里有 dex 而缺 baksmali.jar 时
        //   是**硬失败**（ApkReverseEngine.decompile 的 reason 点名 baksmali.jar），不是"没装就跳过"；
        //   没有 dex 的包（如资源 split）不会走这一步。旧文案"装了 baksmali 时还会反编译出 smali"
        //   读起来像可选项 ⇒ 模型会跳过补救。
        description = "把一个 APK 摊开成可读的文件树（清单、资源、assets、classes.dex，并把 dex 反汇编成 smali）。想看清 APK 里有什么、或准备改包时先用它。默认要 smali（前提是包里有 dex）：没有 baksmali.jar 时这一步会失败，此时文件树已摊开 —— 要么补上 baksmali.jar，要么传 with_smali=false 只摊资源。",
        parameters = listOf(
            ToolParam("apk", "string", "要摊开的 APK（相对工作区），例如 app.apk"),
            ToolParam("out_dir", "string", "摊开到哪个目录，例如 app-unpacked（**需为空或不存在**：解包只写不删，非空目录会被拒绝）"),
            // ★ optional = true（2026-10-18，F7b）：缺键与空串同义 ⇒ `!= "false"` ⇒ 默认 true
            //   （描述里已写明"默认 true"）。注意这是**硬失败**语义：默认 true 时缺
            //   baksmali.jar 会失败，不是"没装就跳过"（ADR 记录在案）。
            ToolParam(
                "with_smali", "string",
                "是否反编译 smali（默认 true，需要 baksmali.jar，缺 jar 会失败；只改资源可传 false 省时间）",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val apk = args["apk"].orEmpty().trim()
        val out = args["out_dir"].orEmpty().trim()
        if (apk.isBlank()) return ToolOutcome.Failure("apk 为空")
        if (out.isBlank()) return ToolOutcome.Failure("out_dir 为空")
        val withSmali = args["with_smali"].orEmpty().trim().lowercase() != "false"

        val r = engine.decompile(apk, out, withSmali)
        return if (r.ok) {
            ToolOutcome.Success("已摊开 $apk → $out\n${r.stepsSummary()}")
        } else {
            ToolOutcome.Failure(
                listOfNotNull(r.reason, r.dirPath?.let { "（已摊开的目录：$it）" }, r.excerpt.ifBlank { null })
                    .joinToString("\n")
            )
        }
    }
}

/** 重新打包并签名 —— 需求模块 3。 */
class ApkRecompileTool(
    fs: WorkspaceFs,
    toolchain: ToolchainPaths,
    runner: dev.heracles.core.exec.ShellRunner,
    /** 进度旁路（App 用它挂前台服务）。 */
    progress: TaskProgress = TaskProgress.NONE,
) : AgentTool {

    private val engine = ApkReverseEngine(runner, fs, toolchain, progress)

    override val spec = ToolSpec(
        name = "apk_recompile",
        // ⚠️ 描述必须与实现一致：ApkReverseEngine.recompile → sign() 走的是**进程内**
        //   ZipAligner（ADR-027），不再有外部 zipalign 这一步（Android 上没有它）。
        description = "把改动过的目录重新打包成 APK 并签名（smali/ 目录存在时先用 smali.jar 汇编成 classes.dex，缺 smali.jar 会失败；打包后由进程内 ZipAligner 对齐，再 apksigner 签名）。改完 apk_decompile 摊开的目录后用它将成果变成可安装的包。",
        parameters = listOf(
            ToolParam("dir", "string", "改动过的目录（apk_decompile 的输出目录）"),
            ToolParam("out_apk", "string", "输出的 APK 路径，例如 app-patched.apk"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val dir = args["dir"].orEmpty().trim()
        val out = args["out_apk"].orEmpty().trim()
        if (dir.isBlank()) return ToolOutcome.Failure("dir 为空")
        if (out.isBlank()) return ToolOutcome.Failure("out_apk 为空")

        val r = engine.recompile(dir, out)
        return if (r.ok) {
            ToolOutcome.Success("已重新打包并签名：${r.apkPath}\n${r.stepsSummary()}")
        } else {
            ToolOutcome.Failure(listOfNotNull(r.reason, r.excerpt.ifBlank { null }).joinToString("\n"))
        }
    }
}

/** 签名（单独用：构建产物已有、只想换密钥重签，或给别人的包签名）。 */
class ApkSignTool(
    fs: WorkspaceFs,
    toolchain: ToolchainPaths,
    runner: dev.heracles.core.exec.ShellRunner,
    /** 进度旁路（App 用它挂前台服务）。 */
    progress: TaskProgress = TaskProgress.NONE,
) : AgentTool {

    private val engine = ApkReverseEngine(runner, fs, toolchain, progress)

    override val spec = ToolSpec(
        name = "apk_sign",
        // ⚠️ 描述必须与实现一致（ADR-027）：签名前**总是**走进程内 ZipAligner（无"有没有
        //   zipalign"这条分支）；只有对齐**抛异常**时才退回原样复制（ApkReverseEngine.sign）。
        //   旧文案"没有 zipalign 就跳过，跳过不影响安装"是 ADR-026 时期的叙事，已不成立 ——
        //   模型会照它对用户保证"不影响安装"，而这正是 ADR-026 禁止制造的假象。
        description = "给一个 APK 签名（apksigner sign 后再 verify 自校验）。用于给改过的包签名，或重新签一个已有的包。签名前总是先用进程内 ZipAligner 对齐（不需要 zipalign 二进制）；对齐会移动字节，已带 v2/v3 签名的包会对齐失败，此时退回未对齐的原包并在步骤里写明原因。签名后才能真正安装。",
        parameters = listOf(
            ToolParam("apk", "string", "要签名的 APK（相对工作区）"),
            // ★ optional = true（2026-10-18，F7b）：缺键 ⇒ 实现 `ifBlank { apk }` ⇒ 覆盖输入包
            //   （原地重签）。描述里写明这个默认值，否则模型不知道不填会签到哪里去。
            ToolParam(
                "out_apk", "string",
                "签名后的输出路径。不填（或传空字符串）= 覆盖输入包本身（原地重签）",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val apk = args["apk"].orEmpty().trim()
        val out = args["out_apk"].orEmpty().trim().ifBlank { apk }
        if (apk.isBlank()) return ToolOutcome.Failure("apk 为空")

        val r = engine.sign(apk, out)
        return if (r.ok) {
            ToolOutcome.Success("已签名并校验通过：${r.apkPath}\n${r.stepsSummary()}")
        } else {
            ToolOutcome.Failure(listOfNotNull(r.reason, r.excerpt.ifBlank { null }).joinToString("\n"))
        }
    }
}

/** class → dex。 */
class D8ConvertTool(
    fs: WorkspaceFs,
    toolchain: ToolchainPaths,
    runner: dev.heracles.core.exec.ShellRunner,
    /** 进度旁路（App 用它挂前台服务）。 */
    progress: TaskProgress = TaskProgress.NONE,
) : AgentTool {

    private val engine = ApkReverseEngine(runner, fs, toolchain, progress)

    override val spec = ToolSpec(
        name = "d8_convert",
        // ⚠️ 堆上限从契约值插值，**不写死数字**：实现读 Contract.Toolchain.JVM_HEAP
        //   （ApkReverseEngine.d8 的 `java -Xmx…`），写死的话契约一改描述就骗人。
        description = "把一批 .class 文件转换成 classes.dex（用 d8，堆上限 ${Contract.Toolchain.JVM_HEAP}，避免设备上 OOM）。手上有编译好的 Java class、要自己做 dex 时用它。",
        parameters = listOf(
            ToolParam("class_dir", "string", "存放 .class 的目录（会递归查找）"),
            ToolParam("out_dir", "string", "dex 输出目录，产物是 <out_dir>/classes.dex"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val src = args["class_dir"].orEmpty().trim()
        val out = args["out_dir"].orEmpty().trim()
        if (src.isBlank() || out.isBlank()) return ToolOutcome.Failure("class_dir 与 out_dir 都不能为空")

        val r = engine.d8(src, out)
        return if (r.ok) {
            ToolOutcome.Success("已生成 dex：${r.dirPath}/classes.dex\n${r.stepsSummary()}")
        } else {
            ToolOutcome.Failure(listOfNotNull(r.reason, r.excerpt.ifBlank { null }).joinToString("\n"))
        }
    }
}

/**
 * 把长任务（构建 / 逆向）包上**前台服务的生命周期** —— `26` §7.1。
 *
 * ## 为什么是"装饰器"而不是"往每个引擎里塞 start/finish"
 *
 * 「任务什么时候开始 / 结束」是**工具调用**的属性，不是引擎内部的知识：
 *
 * · 一次工具调用 = 一次任务 —— `execute` 进 → `execute` 出，边界天然明确；
 * · 写进引擎的话，五个工具 ×「成功 / 失败 / 抛异常」三条路，
 *   每一处都要记得撤服务；**漏一处就是通知栏永远挂着"正在构建"**；
 * · 工具层还统一兜住**参数校验失败**（引擎根本没被调到）这条路。
 *
 * 覆盖的结果形态有四种：`Success` / `Failure` / `NeedsApproval`（这次调用没做事，
 * 按未成功撤掉）/ **抛异常**（撤掉后原样抛出）。四种都撤服务 —— 没撤 = 假"正在构建"。
 *
 * 引擎只负责把**步骤**播出来（`AndroidBuildEngine.record()`），
 * 生命周期归这里 —— 职责边界与 `ShellRunner`（接口在纯 JVM、实现在 Android）一致。
 *
 * ## 不吞异常
 *
 * `try/finally` 的写法能覆盖"抛异常"这条路径，但**不能**直接在 `finally` 里
 * `finish(true)` —— 那时还不知道成败。所以这里显式 catch → 撤服务 → 原样抛出
 * （工具抛异常是上层 [dev.heracles.agent.AgentLoop] 的事，不该被这里改写）。
 */
class ProgressReportingTool(
    private val inner: AgentTool,
    private val progress: TaskProgress,
    /** 通知栏第一行的文案 —— 用 **args** 拼，好带上"在构建哪个项目"。 */
    private val label: (Map<String, String>) -> String,
) : AgentTool {

    /** 规格**原样透出**：分组表 / 冻结区判定 / `assertConsistent` 看到的都是内层工具。 */
    override val spec: ToolSpec get() = inner.spec

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        progress.startQuietly(label(args))

        val outcome = try {
            inner.execute(args)
        } catch (t: Throwable) {
            // 抛异常也必须撤服务，否则通知栏里永远挂着"正在构建"（用户以为卡死了）
            progress.finishQuietly(false, "${t.javaClass.simpleName}: ${t.message.orEmpty()}")
            throw t
        }

        val (ok, summary) = when (outcome) {
            is ToolOutcome.Success -> true to outcome.detail
            is ToolOutcome.Failure -> false to outcome.reason
            // 需要用户确认 = 这次调用**没有做事**（这 5 个工具都是"做完才回来"）。
            // ⇒ 按"未成功"撤服务，文案带上原因 —— 不然通知栏里会留个空的"正在构建"，
            //   而实际上什么都没在跑。
            is ToolOutcome.NeedsApproval -> false to "需要确认：${outcome.detail}"
        }
        progress.finishQuietly(ok, oneLine(summary))
        return outcome
    }
}

/**
 * 取**一行**摘要给通知栏用：第一个非空行 → 压掉多余空白 → 超长截断。
 *
 * 通知栏只能显示一行；直接把整段 message（成功时是"构建成功：…\n步骤…"）
 * 塞进去会被系统截成莫名其妙的半句。
 */
internal fun oneLine(text: String, maxChars: Int = Contract.Progress.SUMMARY_MAX_CHARS): String {
    val line = text.lineSequence()
        .map { it.trim().replace(Regex("\\s+"), " ") }
        .firstOrNull { it.isNotEmpty() }
        .orEmpty()
    return if (line.length <= maxChars) line else line.take(maxChars - 1).trimEnd() + "…"
}

/**
 * 编码层工具的**注册清单**（长尾部分）。
 *
 * 把"有哪些工具 + 各自属于哪一组"集中在一处 —— 分组是显式传入的
 * （[dev.heracles.core.tool.ToolGroup] 的注释解释了为什么不自动猜）。
 */
object AndroidTools {

    /**
     * 建全部编码层工具（不包含常驻工具）。
     *
     * @param progress 长任务进度 —— App 传实现（挂前台服务 + 通知栏），
     *   CLI / 单测用默认的 [TaskProgress.NONE]（**零行为变化**）。
     * @param stagingRoot **SAF 工作区的 staging 根**（F6b / ADR-032）—— App 传
     *   `getExternalFilesDir(null)/build-staging`。默认 null ⇒ POSIX/CLI/单测零回退。
     * @param stagingRunnerFactory staging 专用 shell runner 工厂（App 侧把相对 cwd 映射到 staging）。
     */
    fun create(
        fs: WorkspaceFs,
        toolchain: ToolchainPaths,
        runner: dev.heracles.core.exec.ShellRunner,
        health: dev.heracles.core.guard.DeviceHealthSource? = null,
        progress: TaskProgress = TaskProgress.NONE,
        stagingRoot: Path? = null,
        stagingRunnerFactory: ((Path) -> dev.heracles.core.exec.ShellRunner)? = null,
    ): List<AgentTool> = listOf(
        // 脚手架只写几个文件（毫秒级），**不包** —— 包了通知栏会闪一下又没，像 bug
        ScaffoldAndroidTool(fs),
        wrap(
            BuildApkTool(
                fs, toolchain, runner, health, progress, stagingRoot, stagingRunnerFactory,
            ),
            progress,
        ) { a ->
            "正在构建 APK：${a["project_dir"].orEmpty().ifBlank { "工作区根" }}"
        },
        wrap(ApkDecompileTool(fs, toolchain, runner, progress), progress) { a ->
            "正在摊开 APK：${a["apk"].orEmpty()}"
        },
        wrap(ApkRecompileTool(fs, toolchain, runner, progress), progress) { a ->
            "正在重打包并签名：${a["dir"].orEmpty()}"
        },
        wrap(ApkSignTool(fs, toolchain, runner, progress), progress) { a ->
            "正在签名：${a["apk"].orEmpty()}"
        },
        wrap(D8ConvertTool(fs, toolchain, runner, progress), progress) { a ->
            "正在生成 dex：${a["class_dir"].orEmpty()}"
        },
    )

    /**
     * 没有进度实现时**原样返回**内层工具。
     *
     * 理由：CLI / 单测路径不该因为"多了个功能"而多一层对象、
     * 多一次回调 —— 行为与之前**逐字节一致**，回归面为零。
     */
    private fun wrap(
        tool: AgentTool,
        progress: TaskProgress,
        label: (Map<String, String>) -> String,
    ): AgentTool = if (progress === TaskProgress.NONE) tool else ProgressReportingTool(tool, progress, label)


    /**
     * 分组表 —— 供 [ToolRegistry] 把同义说法纳入检索面。
     *
     * 覆盖范围是**全部长尾工具**（不只 Android 那 6 个）：
     * 漏一个 ⇒ 那个工具的同义说法（「解压」「补丁」）搜不到，
     * 模型只能编「我做不到」，**没有任何报错**（静默退化）。
     */
    val GROUPS: Map<String, dev.heracles.core.tool.ToolGroup> = mapOf(
        "scaffold_android" to dev.heracles.core.tool.ToolGroup.BUILD,
        "build_apk" to dev.heracles.core.tool.ToolGroup.BUILD,
        "apk_decompile" to dev.heracles.core.tool.ToolGroup.APK,
        "apk_recompile" to dev.heracles.core.tool.ToolGroup.APK,
        "apk_sign" to dev.heracles.core.tool.ToolGroup.APK,
        "d8_convert" to dev.heracles.core.tool.ToolGroup.APK,
        // 归档与补丁（ArchiveTools / PatchTools）—— 逆向流程要解包、重打包、改 smali
        "unzip_file" to dev.heracles.core.tool.ToolGroup.ARCHIVE,
        "zip_file" to dev.heracles.core.tool.ToolGroup.ARCHIVE,
        "apply_patch" to dev.heracles.core.tool.ToolGroup.PATCH,
    )

    /**
     * 校验：名字不重复，且分组表覆盖全部工具。
     *
     * ## 为什么要在启动期断言
     *
     * 分组漏了某一个工具 ⇒ 该工具的**同义说法检索不到** ⇒ 模型搜不到
     * 就只能编（"我做不到"），**没有任何报错**。这是典型的静默退化，
     * 必须在启动时把它变成响亮失败（同 [ToolRegistry] 的 `init` 断言）。
     */
    fun assertConsistent(tools: List<AgentTool>) {
        val names = tools.map { it.spec.name }
        require(names.size == names.toSet().size) { "编码层工具名重复：$names" }
        val ungrouped = names.filterNot { it in GROUPS }
        require(ungrouped.isEmpty()) {
            "这些编码层工具没有登记分组，检索会静默失灵：$ungrouped（请补进 AndroidTools.GROUPS）"
        }
        // 常驻 + 长尾的总数必须还在「模型能选对」的范围内（契约 §4.1）
        require(names.size <= Contract.Tools.LONG_TAIL_LIMIT) {
            "长尾工具 ${names.size} 个，超过 Contract.Tools.LONG_TAIL_LIMIT " +
                "(${Contract.Tools.LONG_TAIL_LIMIT}) —— 工具太多会让模型选错"
        }
    }
}
