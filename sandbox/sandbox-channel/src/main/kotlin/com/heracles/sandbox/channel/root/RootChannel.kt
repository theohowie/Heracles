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
 *   原文件：app/src/main/kotlin/b/ai/exec/Root.kt    （探测四态 / su 路径候选 / 一次一条 su -c）
 *   原文件：app/src/main/kotlin/b/ai/exec/Shell.kt   （Shell.exec(argv)：按参数数组起进程）
 *
 * 上游的关键教训（原样保留，别再踩）：
 *   Root.kt 原文 ——「不用 libsu 常驻会话——本机 KernelSU 下它连 `echo hi` 都读不回
 *   任何输出，退出码也不可信」。因此本实现每条命令独立起一次 `su -c`，
 *   stdout/stderr 由本进程直接读，退出码取真实进程值。
 */

package com.heracles.sandbox.channel.root

import android.os.Process
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.RiskLevel
import com.heracles.sandbox.channel.ChannelStatus
import com.heracles.sandbox.channel.SandboxChannel
import com.heracles.sandbox.channel.ShellOutcome
import com.heracles.sandbox.channel.drainProcess
import java.io.File

/**
 * Root 通道：每条命令一次 `su -c`。
 *
 * ============================================================================
 * 探测方法（三级，全部只读、无副作用）
 * ============================================================================
 * 1. **找 su 二进制**：先探常见绝对路径（见 [SU_CANDIDATES]，覆盖 Magisk / KernelSU /
 *    APatch / 老式 xbin 布局），都没有再用 `command -v su` 问 PATH。
 *    两步都失败 ⇒ 判定 `NO_SU`，**直接降级，不再尝试执行**（避免在无 root 设备上
 *    反复弹授权框，也避免被某些 su 实现记为异常调用）。
 * 2. **执行 `id` 看 uid**：`su -c id` 输出含 `uid=0` 才算可用。
 *    这里用 `id` 而不是 `whoami`：`id` 在所有 Android 上都存在。
 * 3. **区分三种失败**（上游 Root.State 的四态，去掉「已获得」）：
 *    - 进程起不来 / 超时（`GRANT_TIMEOUT` 内没结果）→ **TIMEOUT**：
 *      多半是授权框在等用户点「允许」。文案必须说「去点授权框」，而不是「没有 root」。
 *    - 退出码 -1 且无输出 → 判为超时同类。
 *    - 其它非 0 / 输出不含 uid=0 → **DENIED**：su 在，但没授权本应用。
 *
 * ============================================================================
 * 降级路径
 * ============================================================================
 * `NO_SU` / `DENIED` / `TIMEOUT` 三种都只是让 [probe] 返回 `available=false`，
 * 附上可读原因与缺失前置条件。[exec] 在不可用时**立即返回 exitCode=-1**，
 * 不抛异常、不重试、不阻塞 —— ChannelSelector 会因此把自动选路落到 NORMAL，
 * 普通 App 通道完全不受影响。
 *
 * ============================================================================
 * 风险
 * ============================================================================
 * [riskLevel] = HIGH。这不是「禁止」：宿主自己决定要不要用，
 * 沙箱只如实报告「这条通道能动整机」。
 */
class RootChannel(
    /** su 候选路径；测试可注入。 */
    private val suCandidates: List<String> = SU_CANDIDATES,
    /**
     * 等 su 授权框的上限。
     *
     * <p>上游取 60_000 ms（够用户点授权框，又不至于把工具调用拖死）。这里默认
     * 取 8_000 ms：探测发生在**通道发现**阶段（宿主可能每秒刷一次界面），
     * 60 秒会把探测变成阻塞操作。真正的长时间等待由第一次 [exec] 承担 ——
     * 那时用户的注意力就在这次调用上。
     */
    private val grantTimeoutMs: Long = 8_000L,
) : SandboxChannel {

    override val type: ChannelType = ChannelType.ROOT
    override val displayName: String = "Root"
    override val riskLevel: RiskLevel = RiskLevel.HIGH
    override val supportsPty: Boolean = true
    override val supportsCrossAppData: Boolean = true

    /** 探测结论缓存：su 路径一旦确定就不必反复扫目录（上游同样缓存）。 */
    @Volatile
    private var cachedSuPath: String? = null

    /** 探测结论本身也缓存 `available`，但**每次 [probe] 仍会重探 uid**（root 可能被撤）。 */
    @Volatile
    private var lastStatus: ChannelStatus? = null

    override fun probe(): ChannelStatus {
        val suPath = findSu()
        if (suPath == null) {
            return ChannelStatus.unavailable(
                type = type,
                reason = "设备没有 su：需解锁 bootloader 并刷入 Magisk / KernelSU / APatch",
                missing = listOf("已 root 的设备（su 二进制）"),
                identity = "root(0)",
                summary = "以 uid 0 执行；可读写任意路径、改系统设置、动其它 App 私有数据",
                detail = mapOf("suPath" to "", "probedCandidates" to suCandidates.joinToString(",")),
            ).also { lastStatus = it }
        }

        val outcome = runCatching { runSu(suPath, "id", grantTimeoutMs) }.getOrElse {
            ShellOutcome(-1, "探测异常：${it.javaClass.simpleName}: ${it.message}")
        }

        val status = when {
            outcome.timedOut || (outcome.exitCode == -1 && outcome.output.isBlank()) ->
                ChannelStatus.unavailable(
                    type = type,
                    reason = "等待 su 授权超时：请在 su 授权框点「允许」后重试",
                    missing = listOf("su 授权（本应用未被放行）"),
                    identity = "root(0)",
                    summary = ROOT_SUMMARY,
                    detail = mapOf("suPath" to suPath, "state" to "TIMEOUT"),
                )

            outcome.output.contains("uid=0") -> ChannelStatus.ready(
                type = type,
                identity = "root(0) via $suPath",
                summary = ROOT_SUMMARY,
                detail = mapOf("suPath" to suPath, "state" to "GRANTED"),
            )

            else -> ChannelStatus.unavailable(
                type = type,
                reason = "su 未授权：在 su 管理器里给本应用放行" +
                    "（${outcome.output.take(120).ifBlank { "无输出，退出码 ${outcome.exitCode}" }}）",
                missing = listOf("su 授权（本应用未被放行）"),
                identity = "root(0)",
                summary = ROOT_SUMMARY,
                detail = mapOf("suPath" to suPath, "state" to "DENIED"),
            )
        }
        lastStatus = status
        return status
    }

    /**
     * 以 root 身份执行。
     *
     * <p>命令作为**单个参数**传给 `su -c`，因此调用方不需要自己再套一层引号
     * （上游 Root.call 就是这么做的，注释写明「cmd 作为单个参数传入，不用自己拼引号」）。
     *
     * <p>**命令语义是宿主视角**：su 起的是 Android 原生的 `/system/bin/sh`。
     * 要跑 PRoot 的话，调用方必须把 host 侧完整命令行交进来。
     */
    override fun exec(command: String, stdin: String?, timeoutMs: Long): ShellOutcome {
        val cached = lastStatus
        if (cached != null && !cached.available) {
            return ShellOutcome(
                exitCode = -1,
                output = "[root] 通道不可用：${cached.unavailableReason}",
            )
        }
        val suPath = findSu() ?: return ShellOutcome(
            exitCode = -1,
            output = "[root] 设备没有 su：需先解锁 bootloader 并刷入 Magisk / KernelSU / APatch",
        )
        val outcome = runSu(suPath, command, timeoutMs, stdin)
        // 退出码非 0 且一个字都没有：基本是 su 被拒（授权框点了拒绝）。上游同款判据。
        if (outcome.exitCode != 0 && outcome.output.isBlank() && !outcome.timedOut) {
            return ShellOutcome(
                exitCode = outcome.exitCode,
                output = "[root] 命令返回 ${outcome.exitCode} 且无输出：" +
                    "多半是 su 被拒，去 su 管理器放行本应用",
                timedOut = false,
            )
        }
        return outcome
    }

    /** 清空探测缓存（用户在 su 管理器里刚改了授权后用）。 */
    fun reset() {
        cachedSuPath = null
        lastStatus = null
    }

    /** 设备上是否存在 su 二进制；找不到返回 null。 */
    fun findSu(): String? {
        cachedSuPath?.let { if (File(it).exists()) return it }
        val hit = suCandidates.firstOrNull { File(it).exists() }
            ?: pathLookup()
        cachedSuPath = hit
        return hit
    }

    /** 退路：问 PATH。用 NORMAL 身份跑 `command -v su`（不需要 root 就能查）。 */
    private fun pathLookup(): String? = runCatching {
        val process = ProcessBuilder("/system/bin/sh", "-c", "command -v su")
            .redirectErrorStream(true)
            .start()
        val outcome = drainProcess(process, 5_000L)
        outcome.output.lineSequence()
            .map { it.trim() }
            .firstOrNull { it.startsWith("/") }
    }.getOrNull()

    /** 一次 `su -c`：按参数数组起进程，不做二次转义。 */
    private fun runSu(suPath: String, command: String, timeoutMs: Long, stdin: String? = null): ShellOutcome {
        val process = runCatching {
            ProcessBuilder(suPath, "-c", command)
                .redirectErrorStream(true)
                .start()
        }.getOrElse { error ->
            // su 存在但起不来（比如刚被撤销/被杀）：按「超时/不可用」处理，不抛异常。
            return ShellOutcome(
                exitCode = -1,
                output = "[root] su 启动失败：${error.javaClass.simpleName}: ${error.message}",
            )
        }
        return drainProcess(process, timeoutMs, stdin)
    }

    /** 本进程 uid，仅用于日志（root 通道的意义是子进程 uid=0）。 */
    val callerUid: Int get() = Process.myUid()

    companion object {
        /** su 候选路径：覆盖 Magisk / KernelSU / APatch / 传统 xbin 布局（上游同款清单）。 */
        val SU_CANDIDATES: List<String> = listOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/su/bin/su",
            "/debug_ramdisk/su",
            "/data/adb/ksu/bin/su",
            "/data/adb/ap/bin/su",
        )

        private const val ROOT_SUMMARY = "以 uid 0 执行；可读写任意路径、改系统设置、动其它 App 私有数据"
    }
}
