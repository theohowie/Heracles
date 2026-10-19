package com.theohowie.heracles.bridge

import android.content.Context
import android.util.Log
import dev.heracles.agent.ToolOutcome
import dev.heracles.agent.tools.AndroidTools
import dev.heracles.core.progress.TaskProgress
import dev.heracles.toolchain.AndroidProjectScaffold
import dev.heracles.toolchain.ToolchainLocator
import dev.heracles.workspace.PosixStorage
import dev.heracles.workspace.StorageBackedWorkspaceFs
import dev.heracles.workspace.ZipFs
import kotlinx.coroutines.delay
import java.io.File

/**
 * **App 进程内的编码层自检** —— `26-编码层工具链与逆向引擎.md` §7。
 *
 * ## 它为什么存在
 *
 * 到 `实测-12` 为止，编码层验证的一直是**设备上跑引擎**（`:cli` + 设备自带 JDK）这条路径：
 * `OnDeviceEncodeProbe` 是**另一个进程**（`app_process` 起的 JVM），
 * 它不经过 App 的三个设备类。于是 `DeviceShellRunner`（Shizuku/Stellar 路由）、
 * `AgentBuildService`（能不能起来、扛不扛 LMK）、`SystemHealthSource`（温度/电量读数）
 * **一次都没在真机上跑过** —— 它们只是「编译过、APK 装得上」。
 *
 * 本类把这条链路**串起来在应用进程里真跑一遍**，把每一步的结果作为文本交回 UI：
 *
 * ```
 * ① AgentBuildService.start/stop  前台服务**显式**启停自检（起得来 + 通知可见），随即**停掉**
 * ② SystemHealthSource.read      电量/温度（读数喂给引擎的熔断）
 * ③ DeviceShellManager 路由      App 自己**没有** shell 身份，必须经 Stellar/Shizuku
 * ④ 工作区：两个身份都验          App 写 + shell 写**都要过**（最容易想当然的一步）
 * ⑤ ToolchainLocator.locate      工具链在设备上的位置（含「App 能不能看见」）
 * ⑥ 真 shell：id / java -version 身份与 JDK —— 所有构建二进制都靠它跑
 * ⑦ 交叉可见性                    App 建的文件 shell 读得到吗？shell 建的呢？（**最容易漏的一步**）
 * ⑧ AndroidProjectScaffold       建一个 Hello World 骨架
 * ⑨ build_apk（**工具层**）       真构建（aapt2 → javac → d8 → 插 dex → 对齐 → 签名）
 * ⑩ 产物条目自查（成功时）         **不信 ok=true**（G15：exit=0 不等于做了事）
 * ⑩ 路径诊断（失败时自动跑）       App 视角 + shell 视角对照 —— 见 `实测-12` §13.3
 * ⑪ 收尾：只**读**前台服务状态     **自启停的第二重证据**（读了再兜底）（不主动 stop，读了再兜底）
 * ```
 *
 * ## ⑨ 为什么走**工具层**而不是直接调引擎（2026-10-17 改）
 *
 * "前台服务**自启停**"是一个**工具层**的行为（装饰器包住一次工具调用），
 * 不在引擎里。之前直接 `AndroidBuildEngine.build()` = 自己手动起服务
 * ⇒ 恰好**绕开了**要验的那件事。现在走 `AndroidTools.create(..., progress)` +
 * `build_apk`，就是**模型在生产里走的那条路**。
 *
 * 于是 ① 必须先**停掉**服务，否则 ⑨ 的"自动起来"会被①留下的服务掩盖 ——
 * 那种"测出来是绿的、其实是假的"正是本节要避免的。
 *
 * ## 这个类第一次跑就抓出三个真问题（2026-10-17）
 *
 * 1. **引擎缺 `LD_LIBRARY_PATH`** —— App 进程内没有 CLI 包装脚本那层
 *    `export`，`java`/`javac` 直接 `CANNOT LINK EXECUTABLE … libz.so.1 not found`。
 *    CLI 那条路一直没暴露它，因为包装脚本自己导出了。
 * 2. **工作区"0777 就能写"是假的** —— `/data/local/tmp` 是 SELinux
 *    `shell_data_file`，`untrusted_app` 写被拒。见 [candidates] 的实测表。
 * 3. **`isRunning` 读得太早会得到自相矛盾的结论** —— `startForegroundService`
 *    是异步的（本类现在会等它）。
 *
 * 这三个都是**只有真机、且在 App 进程里跑**才会出现的 —— 与 `26` §7 的立意一致。
 *
 * ## 它**不是**产品功能
 *
 * 产品里这条链路由模型调 `build_apk`/`apk_decompile` 触发（`AndroidTools`）。
 * 本类是给「链路到底通不通」一个**可执行、可复现**的答案 —— 与 `:cli` 的
 * `OnDeviceEncodeProbe` 同一个立意，区别只在**跑在谁的进程里**。
 */
object EncodeSelfCheck {

    private const val TAG = "HeraclesEncode"

    /**
     * 默认工作区（**只有 shell 写得进去**，见 [candidates]）。
     *
     * `staging/deploy-toolchain.ps1` 把工具链推到 `/data/local/tmp/heracles/toolchain/`
     * 并**把权限放开到 0777** —— 所以 App 用 `Files` 就能读到它，
     * **不需要**把 244 MB 搬进 App（2026-10-17 真机实测：`run-as` 能看到全部组件）。
     *
     * 但**读**得见 ≠ **写**得进：这个目录的 SELinux 标签是 `shell_data_file`，
     * `untrusted_app` 的写操作会被拒（模式 0777 也救不了）。所以它只作为
     * [candidates] 里的对照组，不作为首选。
     */
    const val DEFAULT_WORKSPACE = "/data/local/tmp/heracles/app-ws"

    /**
     * **候选工作区**，按优先级 —— 判据不是"哪个顺手"，而是**App 与 shell 都必须能写**。
     *
     * 工具链的每一个二进制（aapt2/javac/d8）都由 **shell**（Shizuku/Stellar）执行，
     * 中间产物落在工作区里；而最终产物、进程内插入的 dex、进程内对齐都是 **App 自己**写。
     * 只要有一边写不了，构建就会死在某个看不懂的步骤上。
     *
     * 2026-10-17 真机实测三者（都是**跑出来的**，不是读文档推的）：
     *
     * | 位置 | App 写 | shell 写 | 为什么 |
     * |---|---|---|---|
     * | `/sdcard/Android/data/<pkg>/files/ws` | ✓ | ✓ | `media_rw_data_file`，组 `ext_data_rw`，而 shell **正在该组里** |
     * | `/data/local/tmp/heracles/app-ws` | ✗ | ✓ | SELinux `shell_data_file`：`untrusted_app` **写**被拒 |
     * | `/data/data/<pkg>/files/ws` | ✓ | ✗ | 应用私有目录，`shell`(uid 2000) 进不去 |
     *
     * 列表里**刻意保留**两个走不通的：自检的价值在于"把失败的原因带出来"，
     * 报告会逐个说明谁过谁不过，省得下次又去猜。
     */
    private fun candidates(context: Context): List<String> = buildList {
        // ① 两边都能写 —— 真机实测的唯一解
        context.getExternalFilesDir(null)?.let { add("${it.absolutePath}/ws") }
        // ② App 读得到、写不了（对照组）
        add(DEFAULT_WORKSPACE)
        // ③ App 写得了、shell 写不了（对照组）
        add("${context.filesDir.absolutePath}/ws")
    }

    private const val PROJECT_DIR = "selfcheck"
    private const val SELF_PKG = "com.theohowie.heracles.selfcheck"

    /**
     * 产物文件名（**显式传**给 `build_apk`，不靠它的默认值）。
     *
     * ⑩ 要自己拆包核对，就必须知道自己让它写哪个名字 ——
     * 从工具返回的文案里"解析"路径属于自找脆弱。
     */
    private const val APK_NAME = "app-debug.apk"

    /**
     * 跑一遍自检，返回**给用户看的报告**（同时逐行写 logcat，tag = `HeraclesEncode`）。
     *
     * 不抛异常：任何一步炸掉都会被记进报告（这个类的价值就是"把失败的原因带出来"）。
     *
     * @param workspacePath 传 null = 自动从 [candidates] 里挑第一个**两边都能写**的
     */
    suspend fun run(context: Context, workspacePath: String? = null): String {
        val lines = ArrayList<String>()
        fun say(s: String) {
            lines.add(s)
            Log.i(TAG, s)
        }

        say("═══ Heracles 编码层自检（App 进程内）═══")
        say("本进程        = uid ${android.os.Process.myUid()} / ${context.packageName}")

        // 工作区在 ⑥ 才定下来，但 runner 要先建出来给 ⑤/⑥ 用 —— 它的 lambda 每次
        // 调用时才读 wsPath，所以先声明、后赋值是安全的。
        var wsPath = ""
        val runner = DeviceShellRunner { rel -> File(wsPath, rel).absolutePath }

        var serviceUp = false
        try {
            AgentBuildService.start(context, "编码层自检：准备")
            // ★ `startForegroundService` 是**异步**的：`onStartCommand` 还没跑到
            //   `startForeground` 之前，`isRunning` 就是 false。立刻读会得到
            //   "启动成功但 isRunning=false" 这种自相矛盾的结论 —— 等它一下。
            for (i in 0 until 25) {
                if (AgentBuildService.isRunning()) {
                    serviceUp = true
                    break
                }
                delay(100)
            }
            // 通知**真的可见**吗？—— 与"服务在跑"是两件事：POST_NOTIFICATIONS 被拒、
            // 渠道被用户关掉、厂商 ROM 拦截，都会出现"跑着但没有通知"，
            // 而那在用户眼里就是"App 卡死"。见 AgentBuildService.isNotificationVisible。
            //
            // ★ 2026-10-17 复跑抓到的新事实：`isRunning=true` 会**早于**通知可见 ——
            //   `startForeground()` 返回后，通知还要经系统登记，那一刻
            //   `getActiveNotifications()` 还是空的（真机实测：立刻读 = false、
            //   构建期间 4/4 都是 true）。系统对前台服务通知本来就有"延迟显示"
            //   的机制（`FOREGROUND_SERVICE_DEFERRED`）；[AgentBuildService] 已按
            //   文档显式声明 `FOREGROUND_SERVICE_IMMEDIATE`。
            //   ⇒ 这里做**有界重试**，并把"多久才可见"打出来：
            //   "立刻可见"与"等了 300ms"是两种事实，报告不该把它们抹平。
            var notifVisible = false
            var notifWaitedMs = 0L
            if (serviceUp) {
                val t0 = System.currentTimeMillis()
                while (System.currentTimeMillis() - t0 < 12_000) {
                    if (AgentBuildService.isNotificationVisible(context)) {
                        notifVisible = true
                        break
                    }
                    delay(200)
                }
                notifWaitedMs = System.currentTimeMillis() - t0
            }
            say(
                "① 前台服务     " +
                    if (serviceUp) {
                        "起得来（isRunning=true）· 通知可见=$notifVisible" +
                            (if (notifVisible) "（${notifWaitedMs}ms 后可见）" else "（重试 12s 仍不可见）") +
                            " · POST_NOTIFICATIONS=${postNotificationsState(context)}"
                    } else {
                        "**没起来**：isRunning 2.5 秒内一直 false（start 没抛异常，但服务没跑）"
                    }
            )
        } catch (t: Throwable) {
            // API 34+ 少了 FOREGROUND_SERVICE_DATA_SYNC / 类型不匹配 ⇒ 这里抛 SecurityException，
            // 且系统报错**不会说**缺哪一条 —— 所以原样带出来
            say("① 前台服务     启动**失败**：${t.javaClass.simpleName}: ${t.message}")
        } finally {
            // ★ 这里**必须停掉**：⑨ 验的是"构建能不能**自己**把服务起来"，
            //   留着 ① 起的服务会把 ⑨ 的结果掩盖成假绿。
            AgentBuildService.stop(context)
            if (serviceUp) {
                say("   （已随即停掉 —— 留下 ① 的服务会掩盖 ⑨ 要验的「自启停」）")
            }
        }

        try {
            // ② 健康读数
            val health = SystemHealthSource(context)
            val h = health.read()
            say(
                "② 健康读数     " + (
                    h?.let {
                        "电量 ${it.batteryPercent}%  温度 ${it.batteryTempTenthsC / 10.0}°C  " +
                            "充电 ${it.charging}"
                    } ?: "**读不到**（null ⇒ 熔断会放行 —— 那是取舍，不是「健康」）"
                    )
            )

            // ③ shell 路由
            val st = DeviceShellManager.stellarStatus()
            val sz = DeviceShellManager.shizukuStatus()
            say(
                "③ shell 路由   ${DeviceShellManager.currentRoute().label}" +
                    "（Stellar available=${st.available} granted=${st.granted} uid=${st.uid}" +
                    "；Shizuku ping=${sz.first} granted=${sz.second}）"
            )

            // ④ 工作区：**两个身份都验**（App 写 + shell 写）
            //
            //   这一步最容易想当然 —— "目录权限 0777 就一定能写"？不是。
            //   决定权在 **SELinux**：`/data/local/tmp` 是 `shell_data_file`，
            //   `untrusted_app` 的写操作被拒（2026-10-17 真机实测，见 [candidates]）。
            say("④ 工作区       逐个候选试（App 写与 shell 写**都要过**）")
            var chosen: String? = null
            for (cand in (workspacePath?.let { listOf(it) } ?: candidates(context))) {
                val made = File(cand).mkdirs()
                val appOk = PosixStorage(File(cand).toPath(), "ws").isWritable()
                val sh = runner.run(
                    "mkdir -p '$cand' && touch '$cand/.shell-probe' && " +
                        "rm -f '$cand/.shell-probe' && echo SHELL_OK",
                    30,
                    null,
                )
                val shOk = sh.exitCode == 0 && sh.stdout.contains("SHELL_OK")
                val pass = appOk && shOk
                if (pass && chosen == null) chosen = cand
                say(
                    "   ${if (pass) "✓" else "✗"} $cand" +
                        "   App写=$appOk  shell写=$shOk" + (if (made) "  （本次新建）" else "") +
                        if (shOk) "" else "  ← shell 说：${oneline(sh.stdout + sh.stderr)}"
                )
            }

            val ws = chosen
            if (ws == null) {
                say("→ 没有任何候选**同时**满足 App 与 shell 可写 —— 构建必然失败，到此为止。")
            } else {
                wsPath = ws
                val wsRoot = File(ws).toPath()
                val fs = StorageBackedWorkspaceFs(PosixStorage(wsRoot, "app-ws"))

                // ⑤ 工具链定位（App 身份 + `Files` API —— 这就是"App 能不能看见工具链"的答案）
                val tc = ToolchainLocator.locate(workspaceRoot = wsRoot, env = System.getenv())
                say(
                    "⑤ 工具链       缺失=" +
                        (if (tc.missing().isEmpty()) "（无）" else tc.missing().joinToString("、"))
                )
                say("   aapt2       = ${tc.aapt2 ?: "（缺）"}")
                say("   apksigner   = ${tc.apksigner ?: "（缺）"}")
                say("   d8.jar      = ${tc.d8Jar ?: "（缺）"}")
                say("   android.jar = ${tc.androidJar ?: "（缺）"}")
                say("   JDK         = ${tc.javaHome ?: "（缺）"}")
                say(
                    "   smali       = baksmali=${tc.baksmaliJar ?: "（缺）"} / " +
                        "smali=${tc.smaliJar ?: "（缺）"}"
                )

                // ⑥ 真 shell 身份 + JDK（构建的每一个二进制都要经它执行）
                val idr = runner.run("id", 20, null)
                say("⑥ shell 身份   exit=${idr.exitCode}  ${oneline(idr.stdout + idr.stderr)}")
                if (tc.javaHome != null) {
                    // ★ 必须**带上** bionic 库目录 —— 与引擎 `envPrefix` 注入的东西一致。
                    //   不带的话必然 `CANNOT LINK EXECUTABLE … libz.so.1 not found`
                    //   （2026-10-17 第一次跑就是这么暴露"引擎缺 LD_LIBRARY_PATH"的）。
                    val libs = tc.bionicLibDirs()
                    val libEnv =
                        if (libs.isEmpty()) "" else "LD_LIBRARY_PATH=\"${libs.joinToString(":")}\" "
                    say(
                        "   bionic libs = " +
                            (if (libs.isEmpty()) "（不需要）" else libs.joinToString(":"))
                    )
                    val jr = runner.run("${libEnv}\"${tc.javaHome}/bin/java\" -version", 60, null)
                    say("   java -version → exit=${jr.exitCode}  ${oneline(jr.stderr + jr.stdout)}")
                }

                // ⑦ 交叉可见性：App 与 shell 各自建的文件，对方**看不看得见**
                //
                //   这是本类抓到的第三个"想当然"：目录 0777、文件 0660、
                //   App 也确实在 `ext_data_rw` 组里 —— 位都对，但**对方就是看不见**。
                //   真机上 `prepare` 明明 exit=0、`base.apk` 明明躺在引擎要找的路径上，
                //   引擎却在下一步报"压缩包不存在"（2026-10-17）。
                //   报告里把**两个方向**分开写，是为了下次一眼看出卡在哪一侧。
                val appProbe = "$ws/app-probe.txt"
                val shellProbe = "$ws/shell-probe.txt"
                runCatching { File(appProbe).writeText("from-app\n") }
                val shellReads = runner.run("cat '$appProbe' 2>&1", 30, null)
                val shellOk = shellReads.exitCode == 0 && shellReads.stdout.contains("from-app")
                say(
                    "⑦ 交叉可见性   App 建 → shell 读：" +
                        if (shellOk) "OK" else
                            "FAIL（${oneline(shellReads.stdout + shellReads.stderr)}）"
                )
                runner.run("echo from-shell > '$shellProbe' 2>&1", 30, null)
                val rawRead = runCatching { File(shellProbe).readText().trim() }
                var appOk = rawRead.getOrNull()?.contains("from-shell") == true
                var how = ""
                if (!appOk) {
                    // ★ 第二次实验：若 FUSE 只按 **mode** 判（不看附加组），`chmod` 就能救 ——
                    //   那"脚本每个阶段末尾 chmod 一下"就是个够用的修法。
                    //   若它按 **owner uid** 硬拒，`chown` 又被 `Operation not permitted`
                    //   挡死（实测过），就只能改**布局**（两个目录各管一个方向）。
                    val six = runner.run("chmod 666 '$shellProbe' 2>&1", 30, null)
                    val after = runCatching { File(shellProbe).readText().trim() }
                    appOk = after.getOrNull()?.contains("from-shell") == true
                    how = if (appOk) {
                        "（0660 读不了 ─chmod 666→ 能读 ⇒ FUSE 不看附加组、只看 mode）"
                    } else {
                        "（chmod 666 也救不了 ⇒ 按 owner uid 硬拒）" +
                            "  chmod:${oneline(six.stdout + six.stderr)}" +
                            "  再读:" + after.fold(
                                onSuccess = { "读到「$it」" },
                                onFailure = { "${it.javaClass.simpleName}: ${it.message}" },
                            )
                    }
                }
                say(
                    "            shell 建 → App 读：${if (appOk) "OK" else "FAIL"}$how" +
                        if (appOk && how.isNotEmpty()) "" else
                            "  原样读：" + rawRead.fold(
                                onSuccess = { "读到「$it」" },
                                onFailure = { "${it.javaClass.simpleName}: ${it.message}" },
                            )
                )
                if (!appOk) {
                    say(
                        "            ↑ 这一条失败会**直接掐死**所有进程内步骤" +
                            "（插 dex、对齐都要 App 亲手读 shell 产出的包）"
                    )
                }

                // ⑧ 骨架
                val files = AndroidProjectScaffold(fs).create(PROJECT_DIR, SELF_PKG, "Heracles SelfCheck")
                say("⑧ 建骨架       ${files.size} 个文件 → $PROJECT_DIR/")

                // ⑨ 真构建 —— **走模型会走的那条路**：`build_apk` 工具（`AndroidTools`）。
                //
                //   为什么不再直接 `AndroidBuildEngine.build()`：那样验的是"引擎能跑"，
                //   而"前台服务**自启停**"发生在**工具层**（装饰器包住一次工具调用）。
                //   直接调引擎 = 我自己手动起服务 = **恰好绕开了本轮要验的东西**。
                //
                //   下面的 progress 是"记录 + 采样"壳：真正做事的是 BuildTaskProgress
                //   （起/停前台服务 + 通知栏），我在这里顺手把证据留下来 ——
                //   服务在不在、通知看不看得见，**不靠"构建成功"来推**（进度是旁路，
                //   它出错是被吞掉的，见 TaskProgress 的注释）。
                val liveSteps = ArrayList<String>()
                var svcUpDuring = 0
                var svcDownDuring = 0
                var notifDuring = 0
                val svc = BuildTaskProgress(context)
                var finishedOk: Boolean? = null
                var finishedSummary = ""
                val progress = object : TaskProgress {
                    override fun start(task: String) {
                        svc.start(task)
                    }

                    override fun step(text: String) {
                        liveSteps.add(text)
                        if (AgentBuildService.isRunning()) svcUpDuring++ else svcDownDuring++
                        if (AgentBuildService.isNotificationVisible(context)) notifDuring++
                        svc.step(text)
                    }

                    override fun finish(ok: Boolean, summary: String) {
                        finishedOk = ok
                        finishedSummary = summary
                        svc.finish(ok, summary)
                    }
                }

                val buildTool = AndroidTools
                    .create(fs, tc, runner, health, progress)
                    .first { it.spec.name == "build_apk" }
                val started = System.currentTimeMillis()
                val outcome = buildTool.execute(
                    mapOf("project_dir" to PROJECT_DIR, "out_apk" to APK_NAME),
                )
                val ms = System.currentTimeMillis() - started
                val buildOk = outcome is ToolOutcome.Success

                say("⑨ 构建         ok=$buildOk  ${ms}ms（走 build_apk 工具 = 模型走的那条路）")
                liveSteps.forEach { say("   $it" ) }
                val sampled = svcUpDuring + svcDownDuring
                say(
                    "   前台服务     任务期间 isRunning 采样 $svcUpDuring/$sampled 为 true" +
                        (if (svcDownDuring > 0) "（$svcDownDuring 次 false ← 服务没跟上？）" else "") +
                        "；通知可见 $notifDuring/$sampled" +
                        "；finish(ok=$finishedOk) 后 isRunning=${AgentBuildService.isRunning()}" +
                        "   ← ${if (!AgentBuildService.isRunning()) "**自启停生效**" else "**没撤掉**"}"
                )
                say("   finish 摘要  ${oneline(finishedSummary)}")

                if (!buildOk) {
                    val reason = (outcome as? ToolOutcome.Failure)?.reason.orEmpty()
                    reason.lineSequence().filter { it.isNotBlank() }.forEach { say("   $it") }
                    if (reason.isBlank()) say("   ✗ 工具返回的不是 Success/Failure：$outcome")
                    // ⑩ 路径诊断：**站在 App 的角度**逐条问文件系统
                    //
                    //   2026-10-17：base.apk 明明是 0666、路径也确实是引擎要找的那个，
                    //   引擎却报"压缩包不存在"（`Files.isRegularFile` 返回 false）。
                    //   这种"文件明明在那儿"的错法**只能让 App 自己开口说**：
                    //   POSIX 位、FUSE、符号链接、SELinux 四层里到底是哪层挡的。
                    say("⑩ 路径诊断（App 视角；外部存储是 FUSE，权限判定与 POSIX 位不一致）")
                    listOf(
                        "$PROJECT_DIR/.heracles",
                        "$PROJECT_DIR/.heracles/build",
                        "$PROJECT_DIR/.heracles/build/base.apk",
                        "$PROJECT_DIR/.heracles/build/dex/classes.dex",
                    ).forEach { rel ->
                        val f = File(ws, rel)
                        val size = runCatching { f.length() }
                        val attrs = runCatching {
                            java.nio.file.Files.readAttributes(
                                f.toPath(),
                                java.nio.file.attribute.BasicFileAttributes::class.java,
                            )
                        }
                        say(
                            "   $rel  exists=${f.exists()} isFile=${f.isFile} " +
                                "canRead=${f.canRead()} len=" +
                                size.fold(
                                    onSuccess = { it.toString() },
                                    onFailure = { "${it.javaClass.simpleName}" },
                                ) +
                                "  attr=" +
                                attrs.fold(
                                    onSuccess = { "${it.size()}B" },
                                    onFailure = { "${it.javaClass.simpleName}: ${it.message}" },
                                )
                        )
                    }
                    say(
                        "   列 .heracles/build → " + runCatching {
                            File(ws, "$PROJECT_DIR/.heracles/build").list()?.joinToString(" ")
                                ?: "null（列不出来）"
                        }.fold(
                            onSuccess = { it },
                            onFailure = { "${it.javaClass.simpleName}: ${it.message}" },
                        )
                    )
                    say(
                        "   符号链接解析 → " + runCatching {
                            File(ws, "$PROJECT_DIR/.heracles/build").toPath().toRealPath().toString()
                        }.fold(
                            onSuccess = { it },
                            onFailure = { "${it.javaClass.simpleName}: ${it.message}" },
                        )
                    )
                    val lsOut = runner.run(
                        "ls -ld '$ws' '$ws/$PROJECT_DIR' '$ws/$PROJECT_DIR/.heracles' " +
                            "'$ws/$PROJECT_DIR/.heracles/build' 2>&1",
                        30,
                        null,
                    )
                    lsOut.stdout.trim().lineSequence().forEach { say("   [shell] $it") }
                } else {
                    // ⑩ ★ 不信 ok=true：自己把包拆开看条目（G15 同源）
                    val apkRel = "$PROJECT_DIR/$APK_NAME"
                    val f = File(ws, apkRel)
                    say(
                        "⑩ 产物         $apkRel  " +
                            (if (f.isFile) "${f.length()} 字节" else "【不存在】")
                    )
                    val names = runCatching {
                        ZipFs(wsRoot).listEntries(apkRel).map { it.name }
                    }.getOrNull()
                    if (names == null) {
                        say("   ✗ 读不回条目 —— 包可能是坏的")
                    } else {
                        val need = listOf("AndroidManifest.xml", "classes.dex", "resources.arsc")
                        say(
                            "   ${names.size} 个条目；" + need.joinToString("、") {
                                "$it=" + (if (names.contains(it)) "有" else "**没有**")
                            }
                        )
                    }
                }
            }
        } catch (t: Throwable) {
            say("✗ 自检抛异常：${t.javaClass.simpleName}: ${t.message}")
        } finally {
            // ★ "自启停"的**第二重证据**：这里**不主动** stop，只读状态。
            //   ⑨ 的 finish 若没走到，isRunning 就是 true —— 报告当场说出来，
            //   然后兜底撤掉，免得设备上留一个"永远在构建"的通知。
            val stillRunning = AgentBuildService.isRunning()
            say(
                "⑪ 收尾         前台服务 isRunning=$stillRunning" +
                    if (stillRunning) "   ← **没自动撤**（⑨ 的 finish 没走到？已兜底停掉）"
                    else "   ← ⑨ 结束时已自动撤（无需手动 stop）"
            )
            if (stillRunning) AgentBuildService.stop(context)
        }

        // 落到工作区（方便 `adb pull` 复核 —— 报告本身也是**证据**，
        // 不该只活在 logcat 里：logcat 会轮转，且要连设备才看得到）
        val report = lines.joinToString("\n")
        runCatching {
            val dir = File(
                wsPath.ifBlank {
                    context.getExternalFilesDir(null)?.absolutePath
                        ?: context.filesDir.absolutePath
                }
            )
            dir.mkdirs()
            File(dir, REPORT_NAME).writeText(report)
        }
        return report
    }

    /** 报告落盘的文件名（工作区根下）。 */
    const val REPORT_NAME = "encode-selfcheck.txt"

    /** 取第一行非空内容 —— 命令输出的首行足够说明身份/版本，报告要短。 */
    private fun oneline(text: String): String =
        text.lineSequence().firstOrNull { it.isNotBlank() }?.trim() ?: "（无输出）"

    /**
     * `POST_NOTIFICATIONS` 的状态 —— 用来解释"服务在跑但通知看不见"。
     *
     * API 33+ 才需要这个运行时权限；本项目 `minSdk = 31` ⇒ 31/32 上恒为"不需要"。
     * 前台服务的通知在 API 33+ **不需要**该权限也能显示（系统豁免），
     * 但用户可以在系统设置里把渠道关掉 —— 那时 `isNotificationVisible` 会是 false，
     * 而"服务在跑"仍是 true。两者分开报，才看得出是哪一种。
     */
    private fun postNotificationsState(context: Context): String {
        if (android.os.Build.VERSION.SDK_INT < 33) return "不需要（API < 33）"
        val granted = context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        return if (granted) "已授予" else "未授予"
    }
}
