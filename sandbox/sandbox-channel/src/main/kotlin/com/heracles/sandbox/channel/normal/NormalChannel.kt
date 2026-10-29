/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * This file is part of Heracles-taixu-sandbox.
 *
 * Heracles-taixu-sandbox is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Heracles-taixu-sandbox is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Heracles-taixu-sandbox.  If not, see <https://www.gnu.org/licenses/>.
 *
 * ---------------------------------------------------------------------------
 * 移植来源
 * ---------------------------------------------------------------------------
 * 上游：baicodex (mubai0122/baicodex) @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95
 *   原文件：app/src/main/kotlin/b/ai/exec/Shell.kt  （Shell.run：ProcessBuilder("/system/bin/sh","-c",cmd)）
 *   原文件：app/src/main/kotlin/b/ai/core/Perms.kt   （WorkMode.NORMAL 这一档的定义）
 *
 * 说明：这一档在上游叫「沙箱通道」（Route.SANDBOX），即以**应用自身 UID** 执行 sh。
 * 在 taixu 的 PRoot 体系里它的意义更明确：PRoot 以 App 自身 UID 起进程，
 * 所以「普通 App 通道」就是 PRoot 能做的一切的上限 —— 不需要任何前置条件。
 */

package com.heracles.sandbox.channel.normal

import android.os.Process
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.RiskLevel
import com.heracles.sandbox.channel.ChannelStatus
import com.heracles.sandbox.channel.SandboxChannel
import com.heracles.sandbox.channel.ShellOutcome
import com.heracles.sandbox.channel.drainProcess
import java.util.concurrent.TimeUnit

/**
 * 普通 App 通道：以本应用 UID 执行 `/system/bin/sh -c`。
 *
 * ============================================================================
 * 能力边界（务必读）
 * ============================================================================
 * 可做：
 * - 读写本 App 的私有目录、`/sdcard` 上被授予的部分（受 scoped storage 约束）
 * - 以同一 UID 起 PRoot：这是 taixu 沙箱**唯一必需**的通道，所以它没有前置条件
 * - 通过 `sandbox-file` 的零宽通道穿透 `Android/data/<其它包名>`（与身份无关，见那边的 KDoc）
 *
 * 不可做（越权必须换通道，不能指望它）：
 * - 读别的 App 的 `/data/data/<其它包名>`（SELinux domain 不同，Unix 权限也拒）
 * - `pm` / `am` / `screencap` 等需要 shell 或 system 身份的命令
 * - 任何需要 uid 2000 / uid 0 的操作
 *
 * 因此 [supportsCrossAppData] 是 **false**：它的执行身份（u0_axxx）读不到别人的私有目录。
 * 零宽通道能穿透 `Android/data` 只是因为那边走的是 FUSE 的外部存储路径，
 * 而不是 `/data/data` —— 两者不要混为一谈。
 *
 * ============================================================================
 * 为什么它「永远可用」
 * ============================================================================
 * [probe] 只验证「能不能起一个 sh 进程」。理论上在本应用自己的进程里
 * `/system/bin/sh` 一定存在且可执行；若真的起不来（极端加固 ROM / 被 seccomp 拦），
 * 那说明连沙箱自身都跑不了，此时如实报告不可用。
 * ps：上游 baicodex 干脆不给 NORMAL 档做探测（`route()` 直接 `Route.SANDBOX`），
 * 这里补一次轻量自检，是为了让「连 NORMAL 都挂了」这件事在诊断里可见，
 * 而不是等到 execute 时才炸。
 */
class NormalChannel(
    /** 自检用的 shell 路径；测试可替换。 */
    private val shellPath: String = DEFAULT_SHELL,
    /** 自检超时；故意比执行超时短得多。 */
    private val probeTimeoutMs: Long = 3_000L,
) : SandboxChannel {

    override val type: ChannelType = ChannelType.NORMAL
    override val displayName: String = "普通 App"
    override val riskLevel: RiskLevel = RiskLevel.LOW
    override val supportsPty: Boolean = true
    override val supportsCrossAppData: Boolean = false

    override fun probe(): ChannelStatus {
        val pid = Process.myPid()
        val uid = Process.myUid()
        val identity = "u0_a${uid % 100_000} (uid=$uid, pid=$pid)"
        val summary = "以本应用 uid 执行；可起 PRoot，读写本应用目录与 /sdcard 授权范围"

        val outcome = runCatching { exec("echo sandbox-probe", null, probeTimeoutMs) }
            .getOrElse { ShellOutcome(-1, "探测异常：${it.javaClass.simpleName}: ${it.message}") }

        return when {
            outcome.timedOut -> ChannelStatus.unavailable(
                type = type,
                reason = "自检超时：${probeTimeoutMs}ms 内起不了 /system/bin/sh",
                missing = listOf("可用的 /system/bin/sh"),
                identity = identity,
                summary = summary,
            )

            outcome.exitCode == 0 && outcome.output.contains(PROBE_TOKEN) -> ChannelStatus.ready(
                type = type,
                identity = identity,
                summary = summary,
                detail = mapOf("shell" to shellPath, "uid" to uid.toString(), "pid" to pid.toString()),
            )

            else -> ChannelStatus.unavailable(
                type = type,
                reason = "自检失败（exit=${outcome.exitCode}）：${outcome.output.take(200).ifBlank { "无输出" }}",
                missing = listOf("可用的 /system/bin/sh"),
                identity = identity,
                summary = summary,
            )
        }
    }

    /**
     * 以本应用身份执行。
     *
     * <p>**命令语义是宿主视角**：这里直接起 `/system/bin/sh`，跑的是 Android 的文件系统。
     * 若调用方给的是沙箱视角路径（如 `/workspace/a.txt`），必须先由
     * `ProotEngine.toHostPath()` 换成宿主路径 —— 见 sandbox-file 的 PathSemantics。
     * 本类不做路径换算：通道不知道 rootfs 在哪。
     */
    override fun exec(command: String, stdin: String?, timeoutMs: Long): ShellOutcome {
        val process = runCatching {
            ProcessBuilder(shellPath, "-c", command)
                .redirectErrorStream(true)
                .start()
        }.getOrElse { error ->
            return ShellOutcome(
                exitCode = -1,
                output = "[普通 App] 启动失败：${error.javaClass.simpleName}: ${error.message}",
            )
        }
        return drainProcess(process, timeoutMs, stdin)
    }

    private companion object {
        const val DEFAULT_SHELL = "/system/bin/sh"
        const val PROBE_TOKEN = "sandbox-probe"
    }
}
