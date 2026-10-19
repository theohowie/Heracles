package com.theohowie.heracles.bridge

import android.content.Context
import dev.heracles.core.progress.TaskProgress

/**
 * [TaskProgress] 的**设备侧实现** —— 把长任务（构建 / 逆向）接到前台服务 + 通知栏。
 *
 * ## 为什么实现落在 App 层
 *
 * `26-编码层工具链与逆向引擎.md` §7.1 要求"构建期间必须有一个前台服务"。
 * 但"任务开始了 / 结束了"只有 `:agent` 的工具层知道，而 `:agent` 是**纯 JVM**、
 * 不许 import `android.*`（门禁 G1/G2）。⇒ 与 `ShellRunner`（接口纯 JVM、
 * 实现在 `DeviceShellRunner`）完全同构：**接口在 `:core`，实现在这里**。
 *
 * ## 三个方法就是三件事，一一对应
 *
 * | 回调 | 做什么 | 不做的后果 |
 * |---|---|---|
 * | [start] | `startForegroundService` + 通知栏 | App 切后台后被 LMK 杀，构建半路失败 |
 * | [step] | 更新通知栏文案 | 用户看到"正在构建"卡住不动，以为死机 |
 * | [finish] | `stopService`，撤掉通知 | **通知栏永远挂着"正在构建"** |
 *
 * 挂载点在 [dev.heracles.agent.tools.AndroidTools.create]（装饰器），
 * 所以"引擎抛异常"这条路也会走到 [finish]。
 *
 * ## 它**不**负责的事
 *
 * · 不判断成败 —— [finish] 的 `ok` 只影响文案，撤服务一律执行；
 * · 不重试、不排队 —— 同时只可能有一个构建（工具层一次只调一次）；
 * · 不吞异常 —— 那是 `:core` 里 `startQuietly` / `stepQuietly` / `finishQuietly`
 *   的职责（进度是旁路，出错不许让构建失败）。
 */
class BuildTaskProgress(private val context: Context) : TaskProgress {

    override fun start(task: String) {
        AgentBuildService.start(context, task)
    }

    override fun step(text: String) {
        AgentBuildService.progress(context, text)
    }

    /**
     * 结束。**无论成败都撤服务** —— 这里刻意不看 `ok` 决定要不要撤：
     * 失败时更要把通知撤掉（否则用户看到的是一个"永远在构建"的通知，
     * 而真正的错误信息在对话里，两者矛盾）。
     *
     * @param summary 失败时通常是一行原因（工具层已压成单行），成功时是产物路径那行
     */
    override fun finish(ok: Boolean, summary: String) {
        // 先把最后一行写进通知栏，再撤 —— 顺序反了会写出一个"已停止"的空通知
        if (ok) AgentBuildService.progress(context, "完成：$summary")
        AgentBuildService.stop(context)
    }
}
