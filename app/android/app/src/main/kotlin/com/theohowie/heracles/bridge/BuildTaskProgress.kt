package com.theohowie.heracles.bridge

import android.content.Context

/**
 * **构建进度**（2026-10-22 改造）—— 把长任务接到前台服务 + 通知栏。
 *
 * ## 改造前后
 *
 * 原来它实现 `dev.heracles.core.progress.TaskProgress`（那个接口随 `:core` 一起删了），
 * 由 `:agent` 的工具层装饰器 `ProgressReportingTool` 驱动。
 * 现在 Agent 逻辑全在 Dart，**驱动方换成 Dart 后端**：
 *
 * ```
 * Dart: await channel.invokeMethod('buildNotify.start', {'title': '构建 APK'})
 *       … 每个步骤 …
 *       await channel.invokeMethod('buildNotify.finish')
 * ```
 *
 * ⇒ 本类现在是**朴素的三方法**，不再实现任何接口、不 import 任何 `dev.heracles.*`。
 *
 * ## 三个方法就是三件事
 *
 * | 方法 | 做什么 | 不做的后果 |
 * |---|---|---|
 * | [start] | `startForegroundService` + 通知栏 | App 切后台后被 LMK 杀，构建半路失败 |
 * | [step] | 更新通知栏文案 | 用户看到"正在构建"卡住不动，以为死机 |
 * | [finish] | `stopService`，撤掉通知 | **通知栏永远挂着"正在构建"** |
 *
 * ## 它**不**负责的事
 *
 * · 不判断成败 —— [finish] 只是一律撤服务（成败由 Dart 侧读 `exec.run` 的结果决定）；
 * · 不重试、不排队 —— 同一时刻只可能有一个构建；
 * · 不吞异常 —— 进度是旁路，出错不许让构建失败（内部 `runCatching`）。
 */
class BuildTaskProgress(private val context: Context) {

    /**
     * 开始。**只应由 Dart 在真正要跑长任务时调用** ——
     * 提前调会留下一个"假装在构建"的常驻通知。
     *
     * @param title 通知标题（Dart 侧给的，例如"构建 APK"）。
     *              空串时用默认文案，不让用户看到一条没有标题的通知。
     */
    fun start(title: String = "") {
        runCatching {
            AgentBuildService.start(
                context,
                title.ifBlank { "准备开始…" },
            )
        }
    }

    /** 更新一行步骤文案（真实步骤，不是假进度）。服务没在跑时静默忽略。 */
    fun step(text: String) {
        runCatching { AgentBuildService.progress(context, text) }
    }

    /**
     * 结束。**无论成败都撤服务** ——
     * 失败时更要把通知撤掉（否则用户看到一个"永远在构建"的通知，
     * 而真正的错误在对话里，两者矛盾）。
     */
    fun finish() {
        runCatching { AgentBuildService.stop(context) }
    }
}
