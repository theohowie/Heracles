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
 *   原文件：app/src/main/kotlin/b/ai/exec/Shiz.kt
 *           （State 四态 → 本类的 available/unavailableReason 映射）
 *
 * ★ 本文件**不 import 任何 rikka.shizuku.* 类型**。
 *   所有对 Shizuku 的接触都在 ShizukuAccessImpl 里（反射装载）。
 *   这是硬验收项：没有 Shizuku 的设备上，加载 / 调用本类绝不能抛
 *   NoClassDefFoundError，否则普通 App 通道会被连坐。
 */

package com.heracles.sandbox.channel.shizuku

import android.content.Context
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.RiskLevel
import com.heracles.sandbox.channel.ChannelStatus
import com.heracles.sandbox.channel.SandboxChannel
import com.heracles.sandbox.channel.ShellOutcome

/**
 * Shizuku 通道：经 Shizuku 的用户服务，以 shell（uid 2000）或 root（uid 0）身份执行。
 *
 * ============================================================================
 * 探测方法
 * ============================================================================
 * 三级真检测（**只信 binder 与权限位，不信「装了 App」**）：
 *
 * 1. `Shizuku.pingBinder()` —— 服务进程是否活着。
 *    上游注释把这条列为第一判据，因为「装了 Shizuku」和「Shizuku 在跑」是两件事。
 * 2. `Shizuku.isPreV11()` —— 服务版本是否够新（< 11 没有 `checkSelfPermission`）。
 * 3. `Shizuku.checkSelfPermission() == PERMISSION_GRANTED` —— 本应用是否已被授权。
 *
 * 再叠加一个「manager 是否安装」的辅助判据，**只用于区分文案**：
 * 没装 vs 装了没启动，引导完全不同（去装 vs 去启动服务）。
 *
 * ============================================================================
 * 降级路径（三条，都不抛异常）
 * ============================================================================
 * | 情况 | 结果 |
 * |---|---|
 * | 运行期没有 rikka 类（宿主没打包客户端库）| `loadError` → available=false |
 * | 装了但没启动服务 | `binderAlive=false` → available=false |
 * | 启动了但没授权本应用 | `permissionGranted=false` → available=false |
 *
 * 三种情况 [exec] 都立刻返回 `exitCode = -1` 加可读原因，
 * 不阻塞、不抛异常。ChannelSelector 的自动选路会落到 NORMAL。
 *
 * ============================================================================
 * 为什么"编译期能 import 但运行期没有"
 * ============================================================================
 * `sandbox-channel/build.gradle.kts` 对 Shizuku 是 `compileOnly`（已定稿的硬约束）。
 * 这意味着 APK 里**默认没有** `rikka.shizuku.*`。若把 direct import 写在
 * 通道层，任何一次类加载都会在 ART 校验阶段解析那些符号 → NoClassDefFoundError →
 * 连 NORMAL 都起不来。所以这里额外包了一层 [ShizukuAccess]
 * （见 ShizukuAccess.kt 顶部注释里的四条纪律）。
 */
class ShizukuChannel(
    /** 隔离层实现；默认走反射装载。测试可注入假的实现。 */
    private val access: ShizukuAccess = ShizukuAccessLoader.load(),
    /** 应用上下文；注入后才能拼出用户服务的 ComponentName。 */
    private val context: Context? = null,
) : SandboxChannel {

    override val type: ChannelType = ChannelType.SHIZUKU
    override val displayName: String = "Shizuku"
    override val riskLevel: RiskLevel = RiskLevel.MEDIUM
    override val supportsPty: Boolean = true

    /**
     * Shizuku 以 **shell(2000)** 或 **root(0)** 身份执行，两者都能读
     * `/data/data/<其它包名>`？—— 不能。shell 身份受 SELinux 约束
     * （`untrusted_app` 起不来，但 shell domain 也读不到 `app_data_file`）。
     * 只有 **root 后端**（uid 0）才真正穿透。
     *
     * <p>因此本字段表达的是「**可能**支持，取决于后端」：
     * 上游把 Shizuku 与 Root 都算作「能升级到更高身份」的档，
     * 但严格说 shell 后端不穿透。这里如实取 `false`，
     * 并在 [probe] 的 `detail` 里用 `backend` 报出实际后端，
     * 让宿主能自己判断（沙箱不做决策，只报事实）。
     */
    override val supportsCrossAppData: Boolean = false

    override fun probe(): ChannelStatus {
        context?.let { runCatching { access.attach(it) } }

        val facts = runCatching { access.facts(context) }
            .getOrElse {
                ShizukuFacts(loadError = "探测异常：${it.javaClass.simpleName}: ${it.message}")
            }

        // ① 运行期没有 Shizuku 客户端库 —— 这是**正常状态**，不是错误。
        facts.loadError?.let { error ->
            return ChannelStatus.unavailable(
                type = type,
                reason = "Shizuku 客户端库不可用：$error",
                missing = listOf("宿主未打包 dev.rikka.shizuku:api（本模块是 compileOnly）"),
                identity = "shell(2000)/root(0) via Shizuku",
                summary = SHIZUKU_SUMMARY,
                detail = mapOf("state" to "NO_CLIENT_LIB"),
            )
        }

        // ② 装了但服务没跑。
        if (!facts.binderAlive) {
            return if (facts.installed) {
                ChannelStatus.unavailable(
                    type = type,
                    reason = "Shizuku 已安装但服务未启动：先在 Shizuku App 里启动服务",
                    missing = listOf("Shizuku 服务运行中"),
                    identity = "shell(2000)/root(0) via Shizuku",
                    summary = SHIZUKU_SUMMARY,
                    detail = mapOf("state" to "NOT_RUNNING"),
                )
            } else {
                ChannelStatus.unavailable(
                    type = type,
                    reason = "设备未安装 Shizuku（${ShizukuProtocol.SHIZUKU_PACKAGE}）",
                    missing = listOf("Shizuku App", "Shizuku 服务运行中", "本应用被 Shizuku 授权"),
                    identity = "shell(2000)/root(0) via Shizuku",
                    summary = SHIZUKU_SUMMARY,
                    detail = mapOf("state" to "NOT_INSTALLED"),
                )
            }
        }

        // ③ 服务在跑，但版本太老。
        if (facts.preV11) {
            return ChannelStatus.unavailable(
                type = type,
                reason = "Shizuku 版本过旧（serviceVersion=${facts.version}），需要 v11 及以上",
                missing = listOf("Shizuku v11+"),
                identity = "shell(2000)/root(0) via Shizuku",
                summary = SHIZUKU_SUMMARY,
                detail = mapOf("state" to "TOO_OLD", "version" to facts.version.toString()),
            )
        }

        // ④ 服务在跑，但本应用没被授权。
        if (!facts.permissionGranted) {
            return ChannelStatus.unavailable(
                type = type,
                reason = "Shizuku 未授权本应用：到权限步骤申请 Shizuku 授权",
                missing = listOf("本应用被 Shizuku 授权"),
                identity = "shell(2000)/root(0) via Shizuku",
                summary = SHIZUKU_SUMMARY,
                detail = mapOf(
                    "state" to "NO_PERMISSION",
                    "version" to facts.version.toString(),
                    "uid" to facts.uid.toString(),
                ),
            )
        }

        // ⑤ 可用。后端由服务端 uid 决定（0=root / 2000=ADB）。
        val backend = when (facts.uid) {
            0 -> "root"
            SHELL_UID -> "adb"
            else -> "unknown(uid=${facts.uid})"
        }
        return ChannelStatus.ready(
            type = type,
            identity = "uid ${facts.uid}（$backend 后端）via Shizuku v${facts.version}",
            summary = SHIZUKU_SUMMARY,
            detail = mapOf(
                "state" to "READY",
                "backend" to backend,
                "uid" to facts.uid.toString(),
                "version" to facts.version.toString(),
            ),
        )
    }

    /**
     * 经 Shizuku 用户服务执行。
     *
     * <p>**命令语义是宿主视角**：用户服务跑的是 `/system/bin/sh`。
     * PRoot 命令行由 runtime 在宿主侧组装好再交进来 —— 通道只负责身份。
     */
    override fun exec(command: String, stdin: String?, timeoutMs: Long): ShellOutcome {
        context?.let { runCatching { access.attach(it) } }
        return try {
            access.exec(command, stdin, timeoutMs)
        } catch (t: Throwable) {
            // 隔离层已经承诺不抛；这里是最后一道保险，绝不让通道层炸掉 runtime。
            ShellOutcome(-1, "[Shizuku] 执行异常：${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /**
     * 申请 Shizuku 授权。
     *
     * <p>**这不是权限决策**：沙箱只是替调用方把系统的授权弹窗转起来，
     * 结果原样回报。是否允许永远是用户 + 宿主策略的事。
     *
     * <p>宿主必须在主线程调用（Shizuku 的 requestPermission 有主线程要求）。
     */
    fun requestPermission(onResult: (ShizukuPermissionResult) -> Unit) {
        val ctx = context
        if (ctx == null) {
            onResult(ShizukuPermissionResult.NO_SERVICE)
            return
        }
        runCatching { access.attach(ctx) }
        try {
            access.requestPermission(ctx, onResult)
        } catch (t: Throwable) {
            onResult(ShizukuPermissionResult.ERROR)
        }
    }

    /** Shizuku 服务重启后清掉缓存的连接。 */
    fun reset() {
        runCatching { access.reset() }
    }

    companion object {
        /** Android 的 shell uid。 */
        const val SHELL_UID: Int = 2000

        private const val SHIZUKU_SUMMARY =
            "经 Shizuku 以 shell(2000) 或 root(0) 身份执行；可 pm / am / screencap，" +
                "shell 后端仍受 SELinux 约束"
    }
}
