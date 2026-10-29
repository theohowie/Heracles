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
 * 上游：tianxuan (xiaozhe7772222/tianxuan) @ caad40090a4f2c2edbe54e6eaae60a3dd1de7d21
 *   原文件：runtime/src/main/java/top/wkbin/tianxuan/runtime/bridge/adb/EmbeddedAdbManager.kt
 *           - ConnectionState（Disconnected/Discovering/Pairing/Connecting/Connected/Failed）
 *           - pair() / connect() / connectTo() 的候选端点回退与 127.0.0.1 回环重试
 *           - PAIRING_CODE = Regex("\\d{6}")、VALID_PORTS = 1024..65535
 *   原文件：app/src/main/assets/bin/adb（理解「connect 端口 ≠ pairing 端口」这件事的由来）
 *
 * 移植改造（这是本文件的重点）：
 *   上游把状态机**织在** EmbeddedAdbManager 里，与 Context / NsdManager /
 *   StateFlow / DataStore 缠在一起，完全无法单测。这里把它抽成
 *   **纯 Kotlin 状态机**：零 android 依赖、零 IO、零协程，时间由调用方喂进来
 *   （[now]、[timeoutMillis]），因此 JUnit4 里能逐条验证每个迁移。
 */

package com.heracles.sandbox.channel.adb

/**
 * 无线 ADB 配对/连接的状态。
 *
 * 迁移图（与任务书一致）：
 * ```
 *   DISCONNECTED ──discovered(pairing)──▶ PAIRING_PORT_PROBE
 *   PAIRING_PORT_PROBE ──portAccepted──▶ AUTH_HANDSHAKE
 *   PAIRING_PORT_PROBE ──probeFailed──▶ FAILED（可 retry）
 *   AUTH_HANDSHAKE ──spake2Ok──▶ CONNECTING
 *   AUTH_HANDSHAKE ──authFailed──▶ FAILED
 *   CONNECTING ──linkOk──▶ CONNECTED
 *   CONNECTING ──linkFailed──▶ FAILED（可 retry）
 *   FAILED ──retry──▶ DISCONNECTED
 *   任意 ──reset/disconnect──▶ DISCONNECTED
 * ```
 *
 * <p>[CONNECTED] 是终态（除显式 disconnect）；[FAILED] 只能经 [DISCONNECTED] 重试，
 * 这样「重试」在状态机里是一个明确的动作，而不是从 FAILED 到处乱跳。
 */
enum class AdbPairingState {
    /** 什么都没做；等待发现配对端点（或宿主直接给 host:port）。 */
    DISCONNECTED,

    /**
     * 已拿到配对端口，正在确认它真的在监听、且不是连接端口。
     *
     * <p>上游踩过的坑：把连接端口当配对端口去 pair，会得到
     * 「TLS 握手失败」这种看起来像证书问题的误导性错误。
     * 所以这个状态是独立的、有超时的。
     */
    PAIRING_PORT_PROBE,

    /**
     * 配对端口握手完成，正在做 SPAKE2 密钥交换（用户输入的 6 位配对码）。
     *
     * <p>成功后会拿到一份长期私钥；此后重启只要配对没被撤销就不必再输码。
     */
    AUTH_HANDSHAKE,

    /** 密钥已在手，正在连「连接端口」并做链路探活。 */
    CONNECTING,

    /** 链路可用。 */
    CONNECTED,

    /** 失败（带原因）。见 [AdbPairingEvent.Failed] 的 [AdbFailure]。 */
    FAILED,
    ;

    /** 是否处于「还在动」的状态（可以继续喂事件）。 */
    val isBusy: Boolean
        get() = this == PAIRING_PORT_PROBE || this == AUTH_HANDSHAKE || this == CONNECTING
}

/**
 * 失败原因分类。
 *
 * <p>分类的意义是**降级路径不同**：UI/宿主给出的引导完全不一样，
 * 不能统统显示成「连接失败」。这与上游 `Throwable.userMessage()` 里的
 * 分支判断是同一套判据，只是搬到了类型层面，便于单测。
 */
enum class AdbFailure {
    /** 6 位配对码格式不对（不是数字 / 位数不对）。 */
    INVALID_PAIRING_CODE,

    /** 端口号越界（合法范围 1024..65535）。 */
    INVALID_PORT,

    /** mDNS 没发现配对端点，且宿主没给显式端口。 */
    NO_PAIRING_ENDPOINT,

    /**
     * 配对端口探测失败：端口没在监听 / 连过去 TLS 直接失败。
     *
     * <p>最常见的真因：拿到的是**连接**端口而不是配对端口
     * （两个端口都在轮换，mDNS 服务类型也不同）。
     */
    PAIRING_PORT_UNREACHABLE,

    /** SPAKE2 交换失败：配对码不对，或配对窗口已过期（超时 2 分钟）。 */
    AUTH_FAILED,

    /** 连接端口不可达 / 不可用。 */
    CONNECT_PORT_UNREACHABLE,

    /** TLS 握手失败。上游注释：多半是「用连接端口当配对端口」或端口已变。 */
    TLS_HANDSHAKE_FAILED,

    /** 整体超时（某个状态停太久）。 */
    TIMEOUT,

    /** 其它未分类错误。 */
    UNKNOWN,
    ;

    /** 该失败是否「重试有意义」。配对码错了重试当然有意义；端口无效则要先改配置。 */
    val retryable: Boolean
        get() = when (this) {
            INVALID_PAIRING_CODE, INVALID_PORT -> false
            else -> true
        }
}

/**
 * 喂给状态机的事件。
 *
 * <p>刻意做成 sealed class 而不是「一堆 setter 方法」：这样编译器能保证
 * [AdbPairingStateMachine.handle] 里穷尽所有情况，新增事件不会漏处理。
 */
sealed class AdbPairingEvent {

    /** 宿主/发现层给出了一个配对端点（`_adb-tls-pairing._tcp.`）。 */
    data class PairingEndpointDiscovered(val host: String, val port: Int) : AdbPairingEvent()

    /** 给出 6 位配对码并开始。host/port 可显式给（mDNS 不可用时的兼容入口）。 */
    data class StartPairing(
        val pairingCode: String,
        val host: String = AdbPairingStateMachine.LOOPBACK,
        val port: Int = 0,
    ) : AdbPairingEvent()

    /** 配对端口探测成功（端口在监听、TLS 能起来）。 */
    data object PairingPortAccepted : AdbPairingEvent()

    /** 配对端口探测失败。 */
    data class PairingPortRejected(val failure: AdbFailure, val message: String = "") : AdbPairingEvent()

    /** SPAKE2 密钥交换成功（配对完成，私钥已落盘）。 */
    data object AuthSucceeded : AdbPairingEvent()

    /** 密钥交换失败（配对码错 / 窗口过期）。 */
    data class AuthFailed(val failure: AdbFailure, val message: String = "") : AdbPairingEvent()

    /** 拿到连接端口，准备连接。 */
    data class ConnectEndpointAvailable(val host: String, val port: Int) : AdbPairingEvent()

    /** 连接 + 链路探活成功。 */
    data object LinkEstablished : AdbPairingEvent()

    /** 连接失败。 */
    data class LinkFailed(val failure: AdbFailure, val message: String = "") : AdbPairingEvent()

    /** 已配对过、直接连接（跳过配对阶段）。 */
    data class StartConnect(val host: String = AdbPairingStateMachine.LOOPBACK, val port: Int) : AdbPairingEvent()

    /** 已经过去若干毫秒：用来触发超时判定。 */
    data class Tick(val elapsedMillis: Long) : AdbPairingEvent()

    /** 从 FAILED 回到 DISCONNECTED，准备重试。 */
    data object Retry : AdbPairingEvent()

    /** 显式断开/重置。 */
    data object Disconnect : AdbPairingEvent()
}

/**
 * 状态机对外的一次快照（不可变，可安全跨线程读）。
 */
data class AdbPairingSnapshot(
    val state: AdbPairingState = AdbPairingState.DISCONNECTED,
    /** 当前使用的配对端点（host:port）；没有时为空串。 */
    val pairingEndpoint: String = "",
    /** 当前使用的连接端点；没有时为空串。 */
    val connectEndpoint: String = "",
    /** 已失败的次数（[AdbPairingEvent.Retry] 不清零，便于宿主提示「第 N 次重试」）。 */
    val attempt: Int = 0,
    /** FAILED 时的原因；其余状态为 null。 */
    val failure: AdbFailure? = null,
    /** FAILED 时的人读原因。 */
    val failureMessage: String = "",
    /** 本状态开始的时刻（由调用方的时间源决定）。 */
    val stateEnteredAtMillis: Long = 0L,
) {
    val isConnected: Boolean get() = state == AdbPairingState.CONNECTED
    val isFailed: Boolean get() = state == AdbPairingState.FAILED
}

/**
 * 无线 ADB 的配对状态机：**纯 Kotlin，无 android 依赖，可直接 JUnit 单测**。
 *
 * ============================================================================
 * 为什么值得单独抽出来
 * ============================================================================
 * 上游 tianxuan 把这套逻辑写在 `EmbeddedAdbManager` 里，与 `Context` /
 * `NsdManager` / `StateFlow` / `DataStore` 缠在一起 —— 那意味着：
 * - 想验证「配对码错了会停在 AUTH_FAILED 而不是 CONNECTING」必须跑整机；
 * - 想验证「拿到连接端口当配对端口会报 TLS 而不是超时」根本没法构造。
 *
 * 抽出来后，本类只接受事件、只吐快照：**时间从外面喂**（[now] / 超时阈值），
 * 因此「超时」也能确定性测试，不需要 sleep。
 *
 * ============================================================================
 * 线程
 * ============================================================================
 * 不线程安全：由调用方串行化（无线 ADB 本来就是串行流程）。
 * 需要跨线程读时读 [snapshot]，那是不可变值。
 *
 * ============================================================================
 * 超时
 * ============================================================================
 * 每个「在动」的状态都有自己的预算；[timeoutMillis] 可整体覆盖（测试用）。
 * 超时判定由 [AdbPairingEvent.Tick] 驱动，**本类不自己起定时器**：
 * 定时器属于 Android 侧的 [WirelessAdbChannel]，不属于纯状态机。
 */
class AdbPairingStateMachine(
    /** 时间源（毫秒）。测试可注入假时钟。 */
    private val now: () -> Long = { System.currentTimeMillis() },
    /** 各状态的超时预算；小值便于测试。 */
    private val timeoutMillis: Map<AdbPairingState, Long> = DEFAULT_TIMEOUTS,
) {

    @Volatile
    private var current: AdbPairingSnapshot = AdbPairingSnapshot(stateEnteredAtMillis = now())

    /** 当前快照（不可变）。 */
    val snapshot: AdbPairingSnapshot get() = current

    /** 当前状态。 */
    val state: AdbPairingState get() = current.state

    /**
     * 喂一个事件，返回新快照。
     *
     * <p>非法迁移（例如在 CONNECTED 状态下又 `StartPairing`）会被**忽略**并原样
     * 返回当前快照，而不是抛异常：状态机是给 Android 生命周期驱动的，
     * 抛异常只会把无关的崩溃带给宿主。要判断是否被接受，比较返回的快照是否变化。
     */
    fun handle(event: AdbPairingEvent): AdbPairingSnapshot {
        val before = current
        val next = when (event) {
            is AdbPairingEvent.Disconnect -> resetSnapshot()

            is AdbPairingEvent.Retry -> {
                if (before.state == AdbPairingState.FAILED) {
                    enter(AdbPairingState.DISCONNECTED, attempt = before.attempt + 1)
                } else {
                    before
                }
            }

            is AdbPairingEvent.PairingEndpointDiscovered -> onPairingEndpoint(event, before)
            is AdbPairingEvent.StartPairing -> onStartPairing(event, before)
            is AdbPairingEvent.PairingPortAccepted -> onPairingPortAccepted(before)
            is AdbPairingEvent.PairingPortRejected -> onPairingPortRejected(event, before)
            is AdbPairingEvent.AuthSucceeded -> onAuthSucceeded(before)
            is AdbPairingEvent.AuthFailed -> onAuthFailed(event, before)
            is AdbPairingEvent.ConnectEndpointAvailable -> onConnectEndpoint(event, before)
            is AdbPairingEvent.LinkEstablished -> onLinkEstablished(before)
            is AdbPairingEvent.LinkFailed -> onLinkFailed(event, before)
            is AdbPairingEvent.StartConnect -> onStartConnect(event, before)
            is AdbPairingEvent.Tick -> onTick(event, before)
        }
        current = next
        return next
    }

    // ── 各状态的处理 ────────────────────────────────────────────────────

    private fun onPairingEndpoint(event: AdbPairingEvent.PairingEndpointDiscovered, before: AdbPairingSnapshot): AdbPairingSnapshot {
        // 只在空闲态接受端点发现；忙的时候忽略（避免流程中途端点被替换）。
        if (before.state != AdbPairingState.DISCONNECTED && before.state != AdbPairingState.FAILED) return before
        if (!isValidPort(event.port)) {
            return failed(AdbFailure.INVALID_PORT, "配对端口越界：${event.port}（合法 ${VALID_PORTS.first}..${VALID_PORTS.last}）", before)
        }
        return enter(
            AdbPairingState.PAIRING_PORT_PROBE,
            pairingEndpoint = formatEndpoint(event.host, event.port),
        )
    }

    private fun onStartPairing(event: AdbPairingEvent.StartPairing, before: AdbPairingSnapshot): AdbPairingSnapshot {
        if (!isValidPairingCode(event.pairingCode)) {
            return failed(
                AdbFailure.INVALID_PAIRING_CODE,
                "配对码必须是 6 位数字（收到 \"${event.pairingCode}\"）",
                before,
            )
        }
        val port = event.port
        // port=0 表示「用已发现的端点」；没发现过就报 NO_PAIRING_ENDPOINT。
        if (port == 0) {
            if (before.pairingEndpoint.isEmpty()) {
                return failed(
                    AdbFailure.NO_PAIRING_ENDPOINT,
                    "未发现配对端口：请在系统「无线调试」里打开「使用配对码配对设备」",
                    before,
                )
            }
            return enter(AdbPairingState.PAIRING_PORT_PROBE, pairingEndpoint = before.pairingEndpoint)
        }
        if (!isValidPort(port)) {
            return failed(AdbFailure.INVALID_PORT, "配对端口越界：$port", before)
        }
        return enter(
            AdbPairingState.PAIRING_PORT_PROBE,
            pairingEndpoint = formatEndpoint(event.host, port),
        )
    }

    private fun onPairingPortAccepted(before: AdbPairingSnapshot): AdbPairingSnapshot =
        if (before.state == AdbPairingState.PAIRING_PORT_PROBE) {
            enter(AdbPairingState.AUTH_HANDSHAKE)
        } else {
            before
        }

    private fun onPairingPortRejected(event: AdbPairingEvent.PairingPortRejected, before: AdbPairingSnapshot): AdbPairingSnapshot =
        if (before.state == AdbPairingState.PAIRING_PORT_PROBE) {
            failed(
                event.failure,
                event.message.ifBlank { "配对端口不可达：确认端口号且「使用配对码配对设备」窗口未关闭" },
                before,
            )
        } else {
            before
        }

    private fun onAuthSucceeded(before: AdbPairingSnapshot): AdbPairingSnapshot =
        if (before.state == AdbPairingState.AUTH_HANDSHAKE) {
            // 配对成功后通常要等连接端口出现（两端口不同，且 mDNS 上报有延迟），
            // 所以先进 CONNECTING 等端点，而不是直接 CONNECTED。
            enter(AdbPairingState.CONNECTING)
        } else {
            before
        }

    private fun onAuthFailed(event: AdbPairingEvent.AuthFailed, before: AdbPairingSnapshot): AdbPairingSnapshot =
        if (before.state == AdbPairingState.AUTH_HANDSHAKE) {
            failed(
                event.failure,
                event.message.ifBlank { "配对码不正确，或配对窗口已过期（约 2 分钟）" },
                before,
            )
        } else {
            before
        }

    private fun onConnectEndpoint(event: AdbPairingEvent.ConnectEndpointAvailable, before: AdbPairingSnapshot): AdbPairingSnapshot {
        if (before.state != AdbPairingState.CONNECTING && before.state != AdbPairingState.DISCONNECTED) return before
        if (!isValidPort(event.port)) {
            return failed(AdbFailure.INVALID_PORT, "连接端口越界：${event.port}", before)
        }
        return enter(AdbPairingState.CONNECTING, connectEndpoint = formatEndpoint(event.host, event.port))
    }

    private fun onLinkEstablished(before: AdbPairingSnapshot): AdbPairingSnapshot =
        if (before.state == AdbPairingState.CONNECTING) {
            enter(AdbPairingState.CONNECTED)
        } else {
            // 已经是 CONNECTED 就保持原样（幂等）。上游 connect() 也是幂等的。
            before
        }

    private fun onLinkFailed(event: AdbPairingEvent.LinkFailed, before: AdbPairingSnapshot): AdbPairingSnapshot =
        if (before.state == AdbPairingState.CONNECTING) {
            failed(event.failure, event.message.ifBlank { "连接失败：确认「无线调试」仍开着，或端口已变化" }, before)
        } else {
            before
        }

    private fun onStartConnect(event: AdbPairingEvent.StartConnect, before: AdbPairingSnapshot): AdbPairingSnapshot {
        if (!isValidPort(event.port)) {
            return failed(AdbFailure.INVALID_PORT, "连接端口越界：${event.port}", before)
        }
        if (before.state == AdbPairingState.CONNECTED) return before
        return enter(AdbPairingState.CONNECTING, connectEndpoint = formatEndpoint(event.host, event.port))
    }

    private fun onTick(event: AdbPairingEvent.Tick, before: AdbPairingSnapshot): AdbPairingSnapshot {
        if (!before.state.isBusy) return before
        val budget = timeoutMillis[before.state] ?: return before
        // 用 Tick 的自报值 + 进入时刻，而不是读 now()：
        // 这样测试可以完全控制时间推进，不必依赖真实时钟。
        val elapsed = event.elapsedMillis
        if (elapsed < budget) return before
        return failed(
            AdbFailure.TIMEOUT,
            "${before.state} 超过 ${budget}ms 未完成（已等 ${elapsed}ms）",
            before,
        )
    }

    // ── 迁移工具 ────────────────────────────────────────────────────────

    private fun resetSnapshot(): AdbPairingSnapshot = AdbPairingSnapshot(
        state = AdbPairingState.DISCONNECTED,
        stateEnteredAtMillis = now(),
    )

    private fun enter(
        state: AdbPairingState,
        pairingEndpoint: String = current.pairingEndpoint,
        connectEndpoint: String = current.connectEndpoint,
        attempt: Int = current.attempt,
    ): AdbPairingSnapshot = AdbPairingSnapshot(
        state = state,
        pairingEndpoint = pairingEndpoint,
        connectEndpoint = connectEndpoint,
        attempt = attempt,
        failure = null,
        failureMessage = "",
        stateEnteredAtMillis = now(),
    )

    private fun failed(failure: AdbFailure, message: String, before: AdbPairingSnapshot): AdbPairingSnapshot =
        AdbPairingSnapshot(
            state = AdbPairingState.FAILED,
            pairingEndpoint = before.pairingEndpoint,
            connectEndpoint = before.connectEndpoint,
            attempt = before.attempt,
            failure = failure,
            failureMessage = message,
            stateEnteredAtMillis = now(),
        )

    companion object {
        /** 回环地址：本机无线调试的 mDNS 解析结果有时是局域网 IP，回环往往更稳。 */
        const val LOOPBACK: String = "127.0.0.1"

        /** 合法端口范围（上游同值）。 */
        val VALID_PORTS: IntRange = 1024..65535

        /** 配对码：必须 6 位数字（上游同值；Android 的无线调试就是这样发的）。 */
        val PAIRING_CODE_REGEX: Regex = Regex("\\d{6}")

        /**
         * 各状态的超时预算。
         *
         * <p>来源：上游 `EmbeddedAdbManager` 的 `CONNECT_TIMEOUT_MS = 5_000`、
         * `RESOLVE_TIMEOUT_MS = 8_000`、`CONNECT_DISCOVERY_TIMEOUT_MS = 10_000`。
         * 配对握手额外给多一点（SPAKE2 + 用户手输配对码）。
         */
        val DEFAULT_TIMEOUTS: Map<AdbPairingState, Long> = mapOf(
            AdbPairingState.PAIRING_PORT_PROBE to 8_000L,
            AdbPairingState.AUTH_HANDSHAKE to 30_000L,
            AdbPairingState.CONNECTING to 10_000L,
        )

        /** 端口是否合法。 */
        fun isValidPort(port: Int): Boolean = port in VALID_PORTS

        /** 配对码是否合法（6 位数字）。 */
        fun isValidPairingCode(code: String): Boolean = PAIRING_CODE_REGEX.matches(code)

        /** `host:port` 格式化；IPv6 会补方括号（与 adb 的写法一致）。 */
        fun formatEndpoint(host: String, port: Int): String =
            if (host.contains(':')) "[$host]:$port" else "$host:$port"
    }
}
