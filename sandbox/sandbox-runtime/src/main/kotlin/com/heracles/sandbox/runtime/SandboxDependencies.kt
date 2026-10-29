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
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.ChannelInfo
import com.heracles.sandbox.api.FileResult
import com.heracles.sandbox.api.PathView

/**
 * 适配层：把 taixu runtime 与 harness / core 的耦合切断。
 *
 * ============================================================================
 * 为什么需要这层
 * ============================================================================
 * taixu 的 `runtime/` 模块原本通过 Koin 注入 + `core` 模块（Room DAO /
 * DataStore / AppLogger / AppResult）与 harness 双向通信：
 *
 *   - 155 个 runtime Kotlin 文件里有 **56 个** import 了 `top.wkbin.taixu.core.*`
 *   - 其中高频项：`AppLogger`(18)、`AppResult`(14)、`ShellQuote`(10)、
 *     `ErrorCode`(9)、`RuntimeState`(9)、`AppError`(9)、`RuntimePreferences`(7)
 *
 * 直接把 runtime 搬过来的话，要么连带搬进 Room/DataStore/Koin（那就把控制面
 * 搬进了沙箱，违反架构决策），要么逐个文件重写（成本远超预期）。
 *
 * **采取的策略（见 docs/porting-log.md 的 Phase 0 记录）**：
 * 在沙箱里保留一层**极薄**的适配器接口，把「harness/控制面」抽象为
 * 「可选的调用方」。沙箱只依赖下面这三个 SPI，由宿主（或 demo App）注入实现：
 *
 *   - [EventSink]     —— 命令状态上报（原本走 harness 回调）
 *   - [PathResolver]  —— 宿主视角 ↔ 沙箱视角的路径换算
 *   - [ChannelQuery]  —— 通道查询（原本由 harness 的权限层提供）
 *
 * 默认实现全部是「空安全实现」：没有任何注入时沙箱照样能装 rootfs、执行命令、
 * 读写文件 —— 只是不往外报事件、不提供跨越通道的能力。
 *
 * ============================================================================
 * 边界纪律
 * ============================================================================
 * 这三个接口**只允许**出现在沙箱侧；宿主实现它们即可，沙箱绝不反向 import
 * 宿主的任何类型。这样任何 Android Agent 项目都能复用沙箱。
 */

/**
 * 命令状态事件上报。
 *
 * <p>taixu 原本把执行状态通过 harness 的会话回调上报；现在改为宿主注入。
 * 默认实现见 [NoOpEventSink]：什么都不做。
 *
 * <p>注意这与 AIDL 的 `IExecutionCallback` **不重复**：`IExecutionCallback`
 * 是「这次调用的调用方」的直连回调，而本接口是「沙箱全局事件」——
 * 后台进程、rootfs 安装、通道切换等没有具体调用方的状态也从这里出。
 */
fun interface EventSink {
    /**
     * 上报一条沙箱事件。
     *
     * @param category 事件类别，见 [EventSink.CATEGORY_*]
     * @param message  人类可读描述
     * @param payload  结构化附加数据（可为空）
     */
    fun onEvent(category: String, message: String, payload: Map<String, String>)

    companion object {
        const val CATEGORY_EXEC = "exec"
        const val CATEGORY_ROOTFS = "rootfs"
        const val CATEGORY_CHANNEL = "channel"
        const val CATEGORY_LIFECYCLE = "lifecycle"
    }
}

/** 默认空实现：没有宿主注入时使用，不产生任何副作用。 */
object NoOpEventSink : EventSink {
    override fun onEvent(category: String, message: String, payload: Map<String, String>) = Unit
}

/**
 * 路径换算服务：宿主视角 ↔ 沙箱视角。
 *
 * <p>这是 taixu 的 PRoot `-b` 绑定语义在沙箱里的唯一出口。**所有**路径换算
 * 都必须经过它，禁止在各处散落 `File(filesDir, "sandbox/rootfs$path")` 这种拼接 ——
 * 那正是宿主视角/沙箱视角混淆的根源。
 */
interface PathResolver {
    /**
     * 沙箱视角 → 宿主视角。
     *
     * <p>例：`/workspace/a.txt` → `{filesDir}/sandbox/rootfs/workspace/a.txt`
     *
     * @throws com.heracles.sandbox.api.SandboxException
     *         当 rootfs 未安装（[com.heracles.sandbox.api.SandboxException.CODE_ROOTFS_NOT_READY]）
     *         或路径试图逃逸出 rootfs（`..` 穿越）时
     */
    fun sandboxToHost(sandboxPath: String): String

    /**
     * 宿主视角 → 沙箱视角；不在 rootfs 内时返回 null（不是所有宿主路径都能映射）。
     */
    fun hostToSandbox(hostPath: String): String?

    /** 当前 rootfs 在宿主上的根目录绝对路径；未安装时返回 null。 */
    fun rootfsHostRoot(): String?
}

/**
 * 通道查询 SPI。
 *
 * <p>由 `sandbox-channel` 模块实现并注入。沙箱 core 只依赖这个接口，
 * 因此 runtime 模块不需要知道 Shizuku / Root / ADB 的任何细节。
 */
interface ChannelQuery {
    /** 当前所有通道及其可用性与风险等级，顺序固定为 [com.heracles.sandbox.api.ChannelType] 的声明顺序。 */
    fun queryChannels(): List<ChannelInfo>

    /**
     * 选一个可用于执行的通道。
     *
     * @param preferred 宿主指定的通道 ordinal；-1 表示自动选路
     * @return 实际可用的通道 ordinal
     * @throws com.heracles.sandbox.api.SandboxException
     *         指定通道不可用 → `CODE_CHANNEL_UNAVAILABLE`；完全无通道 → `CODE_NO_CHANNEL`
     */
    fun selectChannel(preferred: Int): Int
}

/** 默认实现：只有 NORMAL 通道。没有注入 channel 模块时沙箱仍然能用。 */
object NormalOnlyChannelQuery : ChannelQuery {
    override fun queryChannels(): List<ChannelInfo> = emptyList()

    override fun selectChannel(preferred: Int): Int = 0 // ChannelType.NORMAL.ordinal
}

/**
 * 交给 [com.heracles.sandbox.api.ISandboxService] 的跨模块依赖集合。
 *
 * <p>sdandbox-app 或宿主负责组装；`sandbox-runtime` 里没有任何默认依赖
 * `sandbox-channel` / `sandbox-file` 的代码，模块依赖保持无环。
 */
class SandboxDependencies(
    val eventSink: EventSink = NoOpEventSink,
    val pathResolver: PathResolver,
    val channelQuery: ChannelQuery = NormalOnlyChannelQuery,
    /**
     * 文件读写实现（零宽通道）。返回 null 表示没注入，此时
     * `readFile/writeFile` 会退化为纯 PRoot 内路径访问。
     */
    val fileAccess: ((String, PathView) -> FileResult)? = null,
)
