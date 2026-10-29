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
 *   原文件：app/src/main/kotlin/b/ai/exec/Router.kt （多通道汇总与状态报告）
 *           —— 上游的 Router 同时干「探测」「选路」「给 UI 出文案」三件事；
 *              这里只保留前两件，第三件交给宿主（沙箱不给文案决策）。
 * 上游：tianxuan (xiaozhe7772222/tianxuan) @ caad40090a4f2c2edbe54e6eaae60a3dd1de7d21
 *   原文件：runtime/src/main/java/top/wkbin/tianxuan/runtime/bridge/adb/EmbeddedAdbManager.kt
 *           （无线 ADB 作为独立通道汇入总表）
 */

package com.heracles.sandbox.channel

import android.content.Context
import com.heracles.sandbox.api.ChannelInfo
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.RiskLevel
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.channel.adb.WirelessAdbChannel
import com.heracles.sandbox.channel.normal.NormalChannel
import com.heracles.sandbox.channel.root.RootChannel
import com.heracles.sandbox.channel.shizuku.ShizukuChannel
import com.heracles.sandbox.runtime.ChannelQuery
import java.util.concurrent.ConcurrentHashMap

/**
 * 四个通道的汇总器：实现 runtime 的 [ChannelQuery] SPI。
 *
 * ============================================================================
 * 顺序是契约的一部分
 * ============================================================================
 * [queryChannels] 的顺序**固定**为 `NORMAL, SHIZUKU, ROOT, WIRELESS_ADB`
 * （= [ChannelType] 的声明顺序）。宿主可以直接用 `ordinal` 建索引，
 * 因此这里绝不能按「可用性」或「风险」重排 —— 那会让宿主的索引错位。
 * [ChannelSelector.normalize] 在选路时会强制这个顺序。
 *
 * ============================================================================
 * 探测是**带缓存**的，且永不抛异常
 * ============================================================================
 * 每次 [queryChannels] 都重新探测一遍虽然最准确，但其中两条探测要起进程
 * （Root 的 `su -c id`、无线 ADB 的 `adb shell echo ok`），
 * 宿主若在界面上每秒刷一次就会非常重。因此：
 *
 * - 探测结果缓存 [CACHE_TTL_MS]（默认 3 秒）；
 * - [refresh] 强制重探（用户刚在系统里改了授权时用）；
 * - 单条通道探测**失败不影响其它通道**：每个 probe 都包在自己的 try/catch 里，
 *   失败的那个降级为 available=false，其余照常。
 *
 * 最后这一条是整个模块最重要的性质（任务书里的硬验收项）：
 * **没有 Shizuku / 没有 root / 没有 adb 的普通设备上，NORMAL 必须始终可用。**
 */
class ChannelManager(
    /** 应用上下文；为 null 时 Shizuku / 无线 ADB 的探测会退化为「不可用」（不会崩）。 */
    private val context: Context? = null,
    /** 可选：宿主注入的无线 ADB 通道（想自己配传输层/持久化时用）。 */
    wirelessAdbChannel: WirelessAdbChannel? = null,
    /** 可选：宿主注入的 Shizuku 通道（想自己配 ShizukuAccess 时用）。 */
    shizukuChannel: ShizukuChannel? = null,
    /** 可选：宿主注入的 Root 通道。 */
    rootChannel: RootChannel? = null,
    private val cacheTtlMs: Long = CACHE_TTL_MS,
    /** 时间源（测试注入假时钟）。 */
    private val now: () -> Long = { System.currentTimeMillis() },
) : ChannelQuery {

    /**
     * 四个通道，按契约顺序。
     *
     * <p>[ShizukuChannel] 的构造会用反射装载隔离层 —— 这一步在**没有 Shizuku 的设备上
     * 也是安全的**（装载失败返回 UnavailableShizukuAccess，见 ShizukuAccess.kt）。
     */
    private val channels: List<SandboxChannel> = run {
        val normal: SandboxChannel = NormalChannel()
        val shizuku: SandboxChannel = shizukuChannel ?: ShizukuChannel(context = context)
        val root: SandboxChannel = rootChannel ?: RootChannel()
        val wirelessAdb: SandboxChannel = wirelessAdbChannel ?: WirelessAdbChannel(context = context)
        // 顺序 = ChannelType 的声明顺序。改成别的顺序会破坏宿主的 ordinal 索引。
        listOf(normal, shizuku, root, wirelessAdb)
    }

    /** 按 [ChannelType] 取通道（执行时用）。 */
    private val byType: Map<ChannelType, SandboxChannel> = channels.associateBy { it.type }

    /** 探测缓存：`ChannelType -> (探测时刻, 结果)`。 */
    private val cache = ConcurrentHashMap<ChannelType, CacheEntry>()

    private data class CacheEntry(val atMillis: Long, val status: ChannelStatus)

    // ── ChannelQuery ────────────────────────────────────────────────────

    /**
     * 当前所有通道及其可用性与风险等级，顺序固定为 [ChannelType] 的声明顺序。
     *
     * <p>**不含 allow / deny**：沙箱只报告事实。是否放行由宿主的信任策略决定。
     */
    override fun queryChannels(): List<ChannelInfo> = channels.map { channel ->
        val status = statusOf(channel)
        ChannelInfo(
            type = channel.type.ordinal,
            displayName = channel.displayName,
            available = status.available,
            unavailableReason = status.unavailableReason,
            missingPrerequisites = status.missingPrerequisites,
            riskLevel = channel.riskLevel.ordinal,
            capabilitySummary = status.capabilitySummary.ifBlank { channel.displayName },
            supportsPty = channel.supportsPty,
            supportsCrossAppData = channel.supportsCrossAppData,
            executionIdentity = status.executionIdentity,
        )
    }

    /**
     * 选一个可用于执行的通道。
     *
     * @throws SandboxException `CODE_CHANNEL_UNAVAILABLE`（指定通道不可用）/
     *         `CODE_NO_CHANNEL`（一个都没有）/ `CODE_INVALID_ARGUMENT`（preferred 越界）
     */
    override fun selectChannel(preferred: Int): Int {
        val facts = channels.map { ChannelFact(it.type, statusOf(it).available) }
        val selected = ChannelSelector.select(preferred, facts)
        return selected.ordinal
    }

    // ── 执行 ────────────────────────────────────────────────────────────

    /**
     * 用选定的通道执行。
     *
     * <p>`preferred = -1` 走自动选路。选不出来时返回 `exitCode = -1` 而不是抛异常，
     * 这样 runtime 的 execute 只有一条错误出口（与 [SandboxChannel.exec] 的约定一致）。
     *
     * @param command   完整命令行（PRoot 前缀已由 runtime 组装好）
     * @param preferred 宿主指定的通道 ordinal；-1 = 自动
     */
    fun execute(
        command: String,
        preferred: Int = ChannelSelector.AUTO_PREFERRED,
        stdin: String? = null,
        timeoutMs: Long = CapabilityChannel.DEFAULT_TIMEOUT_MS,
    ): ShellOutcome {
        val selected = try {
            ChannelType.entries[selectChannel(preferred)]
        } catch (e: SandboxException) {
            return ShellOutcome(-1, "[channel] ${e.message}")
        }
        val channel = byType[selected]
            ?: return ShellOutcome(-1, "[channel] 通道 $selected 未实现")
        return try {
            channel.exec(command, stdin, timeoutMs)
        } catch (t: Throwable) {
            ShellOutcome(
                -1,
                "[${channel.displayName}] 执行异常：${t.javaClass.simpleName}: ${t.message}",
            )
        }
    }

    /** 按类型取通道实现（宿主想直接调某个通道的专有方法时用）。 */
    fun channelOf(type: ChannelType): SandboxChannel? = byType[type]

    /**
     * 强制重探所有通道（丢掉缓存）。
     *
     * <p>用在：用户刚在系统里开了无线调试、刚给 Shizuku 授权、刚在 su 管理器里放行、
     * 或从后台回到前台时。单条通道探测失败不会中断其它通道的重探。
     */
    fun refresh(): List<ChannelInfo> {
        cache.clear()
        (byType[ChannelType.ROOT] as? RootChannel)?.reset()
        (byType[ChannelType.SHIZUKU] as? ShizukuChannel)?.reset()
        return queryChannels()
    }

    /** 丢掉某个通道的缓存（只重探一条时用）。 */
    fun invalidate(type: ChannelType) {
        cache.remove(type)
        if (type == ChannelType.ROOT) (byType[ChannelType.ROOT] as? RootChannel)?.reset()
        if (type == ChannelType.SHIZUKU) (byType[ChannelType.SHIZUKU] as? ShizukuChannel)?.reset()
    }

    /** 某个通道此刻的状态（走缓存）。 */
    fun statusOf(type: ChannelType): ChannelStatus? = byType[type]?.let { statusOf(it) }

    // ── 内部 ────────────────────────────────────────────────────────────

    /**
     * 带缓存地探测一个通道。
     *
     * <p>★ 这里是最关键的一道保险：**任何通道探测抛出的 Throwable 都被收敛成
     * 「该通道不可用」**。没有 Shizuku 时 ShizukuChannel 内部的隔离层本来就返回
     * 不可用；这里再兜一层，是为了防「将来有人往某个通道里加了会抛的代码」
     * 把整张通道表（尤其是 NORMAL）带崩。
     */
    private fun statusOf(channel: SandboxChannel): ChannelStatus {
        val type = channel.type
        val cached = cache[type]
        val timestamp = now()
        if (cached != null && timestamp - cached.atMillis in 0..cacheTtlMs) {
            return cached.status
        }
        val status = try {
            channel.probe()
        } catch (t: Throwable) {
            ChannelStatus.unavailable(
                type = type,
                reason = "探测异常：${t.javaClass.simpleName}: ${t.message}",
                missing = listOf("通道探测可正常完成"),
                identity = channel.displayName,
                summary = channel.displayName,
                detail = mapOf("state" to "PROBE_THREW"),
            )
        }
        cache[type] = CacheEntry(timestamp, status)
        return status
    }

    companion object {
        /** 探测缓存有效期：3 秒。宿主刷界面时不会每秒起两次进程。 */
        const val CACHE_TTL_MS: Long = 3_000L

        /**
         * 便捷构造：只给 Context，其余全默认。
         *
         * <p>这是宿主最常用的入口 —— 两行就能拿到一个完整实现的 [ChannelQuery]。
         */
        fun create(context: Context?): ChannelManager = ChannelManager(context = context)

        /** 通道声明的固定顺序（= [ChannelType.entries]）。 */
        val CHANNEL_ORDER: List<ChannelType> = ChannelType.entries.toList()

        /**
         * 每个通道的风险等级（供宿主展示时的静态参考；实际以 [ChannelInfo.riskLevel] 为准）。
         *
         * <p>NORMAL=LOW（影响限于沙箱）、SHIZUKU=MEDIUM（用户级授权即可获得）、
         * ROOT=HIGH（整机）、WIRELESS_ADB=HIGH（完整 shell 身份）。
         */
        val STATIC_RISK: Map<ChannelType, RiskLevel> = mapOf(
            ChannelType.NORMAL to RiskLevel.LOW,
            ChannelType.SHIZUKU to RiskLevel.MEDIUM,
            ChannelType.ROOT to RiskLevel.HIGH,
            ChannelType.WIRELESS_ADB to RiskLevel.HIGH,
        )
    }
}
