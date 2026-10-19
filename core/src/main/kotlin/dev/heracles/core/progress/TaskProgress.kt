package dev.heracles.core.progress

/**
 * **长任务的进度回调** —— 纯 JVM，**没有任何 Android 依赖**（门禁 G1/G2）。
 *
 * ## 它解决什么：让"构建"能自己挂上前台服务
 *
 * 一次 `aapt2 + javac + d8` 全量构建在真机上要**几秒到几分钟**，
 * 而用户在这段时间里几乎必然会切走。App 退到后台后进程掉进 LMK 的
 * **第一回收档**（cached）—— 构建跑到一半被杀，用户看到的是"莫名其妙失败"
 * （`26-编码层工具链与逆向引擎.md` §7.1）。
 *
 * 唯一的手段是**前台服务**（`AgentBuildService`）。但服务是 Android 的东西，
 * 而"任务什么时候开始、什么时候结束"只有 `:agent`（工具层）与 `:toolchain`
 * （引擎）知道 —— 它们**不许** import `android.*`。
 *
 * ⇒ 这里只定义**回调形状**，由 App 侧提供实现（挂服务 + 通知栏），
 * 与 [dev.heracles.core.exec.ShellRunner] 的分工完全同构：
 * **接口在纯 JVM 层，实现落在 Android 层**。
 *
 * ## 生命周期：**必须**成对，且 `finish` 在成功/失败/需确认/抛异常四条路上都要走
 *
 * ```
 * start(task) ──► step(…) ──► step(…) ──► … ──► finish(ok, summary)
 *      │                                            ▲
 *      └──────────── 前台服务起来 ──────────────────┘ 撤掉
 * ```
 *
 * 漏掉 `finish` 的后果不是"没有进度"，而是**通知栏里永远挂着一个"正在构建"**
 * —— 用户会以为 App 卡死了。所以实现侧只该在 `finish` 里撤服务，
 * 而调用侧（`AndroidTools` 的 `ProgressReportingTool` 装饰器）保证四条路都收口：
 * `try { … } catch (t) { finishQuietly(false, …); throw t }` —— **不是** `finally`，
 * 因为 `finally` 里还不知道成败，写不出正确的 `ok`。
 *
 * ## ⚠️ 进度是**旁路**：它出错绝不许让构建失败
 *
 * 用 [startQuietly] / [stepQuietly] / [finishQuietly]（不抛版本）——
 * 通知栏因为权限、厂商 ROM 的差异而抛异常时，构建**照样要能跑完**。
 * 这是刻意的取舍：**功能正确性 > 可观测性**。
 *
 * 反过来说，这也意味着"通知没出来"**不会**让构建失败 —— 所以
 * `实测-12` §13.4 的自检会**分开**验两件事：服务在跑（`isRunning`）与
 * 通知真的可见（`activeNotifications`），不靠"构建成功"来推。
 */
interface TaskProgress {

    /** 任务开始（实现侧在这里起前台服务）。[task] 是给人看的一行文案。 */
    fun start(task: String)

    /** 一行进度（阶段名 / 已完成的一步）。实现侧在这里更新通知。 */
    fun step(text: String)

    /**
     * 任务结束 —— **无论成败**（含调用方抛异常）。
     *
     * @param ok 是否成功（实现侧据此决定文案，但**都必须**撤掉前台服务）
     * @param summary 一行摘要（失败时通常是原因的第一行）
     */
    fun finish(ok: Boolean, summary: String)

    companion object {
        /** 不关心进度（CLI / 单测 / 纯引擎用法）—— 调它永远安全。 */
        val NONE: TaskProgress = object : TaskProgress {
            override fun start(task: String) = Unit
            override fun step(text: String) = Unit
            override fun finish(ok: Boolean, summary: String) = Unit
        }
    }
}

/*
 * 上面三条的"不抛"版本。集中在这里而不是散在调用点 ——
 * 规则只有一条（"进度出错不许搞坏构建"），就该只有一处实现。
 * 副作用也明确：调用方**拿不到**异常，所以"通知没出来"必须由别的手段验证（见类注释）。
 */

/** [TaskProgress.start]，但**吞掉**异常（进度是旁路）。 */
fun TaskProgress.startQuietly(task: String) {
    runCatching { start(task) }
}

/** [TaskProgress.step]，但**吞掉**异常（进度是旁路）。 */
fun TaskProgress.stepQuietly(text: String) {
    runCatching { step(text) }
}

/** [TaskProgress.finish]，但**吞掉**异常（进度是旁路）。 */
fun TaskProgress.finishQuietly(ok: Boolean, summary: String) {
    runCatching { finish(ok, summary) }
}
