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
 *           - executeShell：连不上就先 connect，再 shell；输出 200_000 字符上限
 *           - connectTo：先试 mDNS 给的 host，失败再试 127.0.0.1 回环
 *           - 候选端点回退（explicit → discovered → saved）
 *   原文件：app/src/main/assets/bin/adb
 *           （★ 本文件采用的就是这个 wrapper 的思路：**不内嵌 ADB 协议栈**，
 *             而是调用一个已配对的 adb 客户端二进制；wrapper 在「同一条命令周期内
 *             connect + 执行」以避免 PRoot 下 daemon 被重启导致断连）
 *
 * ★ 关于「为什么没有内嵌 ADB 协议实现」
 *   上游 tianxuan 内嵌 `com.flyfishxu.kadb`（Kotlin 版 ADB 客户端）。
 *   本沙箱**刻意不引入它**：
 *     1. 它是上游之外的第二套第三方依赖；沙箱 AAR 要保持「能被任何 Android
 *        Agent 项目直接复用」，依赖面越小越好（本模块只有 core-ktx + coroutines）。
 *     2. 内嵌 ADB 需要自行管理 RSA 密钥对与 AUTH 签名流程，出错时的失败模式
 *        （TLS/SPAKE2 混在配对里、AUTH token 过期）极难在没有真机常态化回归的情况下维护。
 *   因此本实现走**进程外 adb 客户端**：只要有任何一个可用的 `adb` 可执行文件
 *   （Termux 的 android-tools、PRoot rootfs 里的 platform-tools、或宿主自己放的
 *   arm64 静态 adb），就能用。这也是上游 assets/bin/adb wrapper 的做法。
 *   若宿主确实需要纯 Kotlin 实现，请往 `AdbTransport` 这个 SPI 里注一个实现即可，
 *   本类不会因此改动一行。
 */

package com.heracles.sandbox.channel.adb

import android.content.Context
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.RiskLevel
import com.heracles.sandbox.channel.ChannelStatus
import com.heracles.sandbox.channel.SandboxChannel
import com.heracles.sandbox.channel.ShellOutcome
import com.heracles.sandbox.channel.repeatLimit
import com.heracles.sandbox.channel.shellQuote
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit

/**
 * 无线 ADB 的传输层 SPI。
 *
 * <p>把「怎么跟 adb 说话」与「通道怎么选路/降级」分开：
 * - 默认实现 [ExternalAdbCliTransport] 调用外部 adb 二进制；
 * - 宿主可注入纯 Kotlin 实现（如内嵌 kadb），不必改本模块。
 */
interface AdbTransport {

    /** 传输层是否就绪（例如 adb 二进制存在且可执行）。 */
    fun isReady(): Boolean

    /** 不可用的原因（就绪时为空串）。 */
    fun unavailableReason(): String

    /**
     * 在指定 `host:port` 上执行一条 shell 命令。
     *
     * <p>实现应当**先 connect 再执行**（上游 wrapper 的核心手法：
     * PRoot 里 adb daemon 会被反复重启，隔开两条命令就断连）。
     */
    fun shell(host: String, port: Int, command: String, timeoutMs: Long): ShellOutcome

    /**
     * 在**配对端口**上完成 `adb pair host:port code` 的密钥交换。
     *
     * <p>单独一个方法而不是复用 [shell]：配对与执行用的是**不同的端口和不同的协议阶段**
     * （`_adb-tls-pairing._tcp.` + SPAKE2 vs `_adb-tls-connect._tcp.` + TLS）。
     * 上游踩过的坑就是两者混用 —— 用连接端口去 pair 会得到
     * 「TLS 握手失败」这种误导性错误（见 [AdbFailure.TLS_HANDSHAKE_FAILED]）。
     */
    fun pair(host: String, port: Int, pairingCode: String, timeoutMs: Long): ShellOutcome
}

/**
 * 默认传输层：调用外部 `adb` 可执行文件。
 *
 * <p>候选顺序与上游 wrapper 一致（先找「真 adb」再退回 PATH）：
 * 1. 环境变量 `HERACLES_ADB`（宿主可显式指定）
 * 2. PRoot rootfs 里的 platform-tools（`/sandbox/rootfs/opt/android-sdk/platform-tools/adb` 类路径）
 * 3. Termux 的 `/data/data/com.termux/files/usr/bin/adb`
 * 4. `PATH` 里的 `adb`
 *
 * <p>每条命令一次 `adb -H host -P port shell <cmd>`：不常驻 daemon 连接，
 * 与上游 `ShellResult` 的「一次性进程」哲学一致。
 */
class ExternalAdbCliTransport(
    /** 额外候选路径（宿主可注入）。 */
    private val extraCandidates: List<String> = emptyList(),
    private val env: Map<String, String> = System.getenv(),
) : AdbTransport {

    @Volatile
    private var cachedPath: String? = null

    /** 找到的 adb 路径；找不到返回 null。 */
    fun adbPath(): String? {
        cachedPath?.let { if (File(it).canExecute()) return it }
        val candidates = buildList {
            env["HERACLES_ADB"]?.takeIf { it.isNotBlank() }?.let { add(it) }
            addAll(extraCandidates)
            addAll(DEFAULT_CANDIDATES)
        }
        val hit = candidates.firstOrNull { File(it).canExecute() }
            ?: pathLookup()
        cachedPath = hit
        return hit
    }

    private fun pathLookup(): String? = runCatching {
        val process = ProcessBuilder("/system/bin/sh", "-c", "command -v adb")
            .redirectErrorStream(true)
            .start()
        val text = process.inputStream.bufferedReader().readText()
        runCatching { process.waitFor(5, TimeUnit.SECONDS) }
        text.lineSequence().map { it.trim() }.firstOrNull { it.startsWith("/") && File(it).canExecute() }
    }.getOrNull()

    override fun isReady(): Boolean = adbPath() != null

    override fun unavailableReason(): String = if (isReady()) {
        ""
    } else {
        "未找到 adb 可执行文件：需要一个可用的 adb 客户端" +
            "（Termux 的 android-tools / rootfs 里的 platform-tools / 宿主自带的 arm64 静态 adb），" +
            "或用环境变量 HERACLES_ADB 指定"
    }

    override fun shell(host: String, port: Int, command: String, timeoutMs: Long): ShellOutcome {
        val adb = adbPath() ?: return ShellOutcome(-1, "[无线 ADB] ${unavailableReason()}")
        val serial = AdbPairingStateMachine.formatEndpoint(host, port)
        // ★ connect 与执行必须在**同一条 sh 命令**里完成。
        //   上游 assets/bin/adb wrapper 的注释写得很清楚：
        //   「PRoot 下 ADB daemon 独立调用重启导致断连」——
        //   分成两次调用时 daemon 可能已被重启，第二条命令就找不到设备。
        //   注意 `-H`/`-P` 指定的是 **adb server** 的位置，不是设备；
        //   设备要用 `-s host:port` 指定，别混了（混了会静默连到本机 server 上）。
        val script = buildString {
            append(adb.shellQuote()).append(" connect ").append(serial.shellQuote())
            append(" >/dev/null 2>&1; ")
            append(adb.shellQuote())
            append(" -s ").append(serial.shellQuote())
            append(" shell ").append(command.shellQuote())
        }
        val process = runCatching {
            ProcessBuilder("/system/bin/sh", "-c", script)
                .redirectErrorStream(true)
                .start()
        }.getOrElse { error ->
            return ShellOutcome(
                -1,
                "[无线 ADB] 启动 adb 失败：${error.javaClass.simpleName}: ${error.message}",
            )
        }
        return drain(process, timeoutMs)
    }

    /**
     * `adb pair host:port code`。
     *
     * <p>配对**不需要**先 connect（配对端口与连接端口是两个不同端口），
     * 因此这里只跑一条命令。配对成功后 adb 会把长期私钥写进
     * `~/.android/adbkey`（外部客户端自己管理，沙箱不碰密钥文件）。
     */
    override fun pair(host: String, port: Int, pairingCode: String, timeoutMs: Long): ShellOutcome {
        val adb = adbPath() ?: return ShellOutcome(-1, "[无线 ADB] ${unavailableReason()}")
        val serial = AdbPairingStateMachine.formatEndpoint(host, port)
        val process = runCatching {
            ProcessBuilder(adb, "pair", serial, pairingCode)
                .redirectErrorStream(true)
                .start()
        }.getOrElse { error ->
            return ShellOutcome(
                -1,
                "[无线 ADB] 启动 adb pair 失败：${error.javaClass.simpleName}: ${error.message}",
            )
        }
        return drain(process, timeoutMs)
    }

    private fun drain(process: Process, timeoutMs: Long): ShellOutcome {
        val buffer = StringBuilder()
        val reader = Thread {
            runCatching {
                process.inputStream.bufferedReader().forEachLine { line ->
                    synchronized(buffer) { buffer.appendLine(line) }
                }
            }
        }.apply { isDaemon = true }
        reader.start()
        runCatching { process.outputStream.close() }
        val finished = runCatching { process.waitFor(timeoutMs, TimeUnit.MILLISECONDS) }.getOrDefault(false)
        if (!finished) runCatching { process.destroyForcibly() }
        reader.join(2_000)
        val text = synchronized(buffer) { buffer.toString() }.trim().repeatLimit()
        return if (finished) {
            ShellOutcome(runCatching { process.exitValue() }.getOrDefault(-1), text)
        } else {
            ShellOutcome(-1, "$text\n[无线 ADB 超时 ${timeoutMs}ms，已强制结束]".trim(), timedOut = true)
        }
    }

    companion object {
        /** 常见 adb 位置（PRoot rootfs / Termux / 常见前缀）。 */
        val DEFAULT_CANDIDATES: List<String> = listOf(
            "/data/data/com.termux/files/usr/bin/adb",
            "/system/bin/adb",
            "/usr/bin/adb",
            "/usr/local/bin/adb",
            "/opt/android-sdk/platform-tools/adb",
            "/opt/tianxuan/tools/android-suite-offline/bin/adb",
        )
    }
}

/**
 * 无线 ADB 通道（tianxuan 移植）。
 *
 * ============================================================================
 * 探测方法（四级，全部无副作用、有界超时）
 * ============================================================================
 * 1. **传输层是否就绪**（[AdbTransport.isReady]）：没有 adb 客户端就直接不可用。
 * 2. **是否已配对过**：读取持久化的配对标记（[pairedOnce]）。
 *    没配对过 ⇒ 需要用户先在系统「无线调试」里输 6 位配对码，
 *    此时通道报不可用并说明缺什么（这不是错误，是正常前置条件）。
 * 3. **连接端口是否在监听**：对保存的端口做一次 TCP connect
 *    （[CHANNEL_PROBE_TIMEOUT_MS] 内），**只连不执行**，因此不会产生副作用。
 * 4. **链路探活**（可选，`exec("echo ok")`）：只在 3 通过后做，
 *    避免把「端口通但 adb 未授权」误判成可用。
 *
 * ============================================================================
 * 降级路径
 * ============================================================================
 * | 情况 | 结果 |
 * |---|---|
 * | 没有 adb 客户端 | available=false，原因指向「需要一个 adb 二进制」|
 * | 从未配对 | available=false，原因指向「无线调试 → 使用配对码配对」|
 * | 已配对但端口不通 | available=false，原因指向「无线调试可能已关闭/端口已变」|
 * | 端口通但链路探活失败 | available=false，原因带 adb 的原始输出 |
 *
 * 四种情况 [exec] 都不阻塞地返回 `exitCode = -1`，绝不抛异常。
 *
 * ============================================================================
 * 能力与风险
 * ============================================================================
 * 身份是 **shell(2000)**：能 `pm` / `am` / `screencap` / `logcat`，
 * 但**不是 root**，也绕不过 SELinux。所以：
 * - [riskLevel] = HIGH：拿到 shell 身份意味着能卸载/停用应用、读多数系统信息，
 *   虽然不如 root 彻底，但对普通用户来说已经是「影响整机」的级别。
 * - [supportsCrossAppData] = false：shell domain 读不到 `app_data_file`。
 *
 * <p>注意这个「HIGH」**不是禁止**：沙箱只报事实，宿主决定放不放行。
 */
class WirelessAdbChannel(
    private val context: Context? = null,
    /** 传输层；默认外部 adb 客户端。 */
    private val transport: AdbTransport = ExternalAdbCliTransport(),
    /** 纯状态机（配对流程）。 */
    private val stateMachine: AdbPairingStateMachine = AdbPairingStateMachine(),
    /**
     * 已配对标记的读取器。
     *
     * <p>做成 lambda 而不是让本类自己碰 SharedPreferences：
     * 1. 沙箱不做持久化决策（那是宿主的设置存储）；
     * 2. 无线 ADB 的状态机与探测因此能纯 JVM 单测。
     */
    private val pairedOnce: () -> Boolean = { false },
    /** 上次成功使用的连接端口（宿主持久化后注入）；0 表示没有。 */
    private val savedPort: () -> Int = { 0 },
    private val savedHost: () -> String = { AdbPairingStateMachine.LOOPBACK },
) : SandboxChannel {

    override val type: ChannelType = ChannelType.WIRELESS_ADB
    override val displayName: String = "无线 ADB"
    override val riskLevel: RiskLevel = RiskLevel.HIGH
    override val supportsPty: Boolean = false
    override val supportsCrossAppData: Boolean = false

    /** mDNS 发现器；懒建（避免无 Wi-Fi 设备上构造就炸）。 */
    @Volatile
    private var discovery: AdbMdnsDiscovery? = null

    /** 当前状态机快照（宿主可读来显示配对进度）。 */
    val pairingSnapshot: AdbPairingSnapshot get() = stateMachine.snapshot

    override fun probe(): ChannelStatus {
        val identity = "shell(2000) via adb tcp"
        val summary = "经无线调试以 shell(2000) 执行；可 pm / am / screencap / logcat，不是 root"

        // ① 传输层
        if (!transport.isReady()) {
            return ChannelStatus.unavailable(
                type = type,
                reason = transport.unavailableReason(),
                missing = listOf("可用的 adb 客户端可执行文件"),
                identity = identity,
                summary = summary,
                detail = mapOf("state" to "NO_TRANSPORT"),
            )
        }

        // ② 是否配对过
        if (!runCatchingCatching { pairedOnce() }!!) {
            return ChannelStatus.unavailable(
                type = type,
                reason = "尚未完成无线调试配对：在系统「无线调试」里打开「使用配对码配对设备」，" +
                    "再让宿主提交 6 位配对码",
                missing = listOf("开启系统「无线调试」", "完成 adb pair 配对"),
                identity = identity,
                summary = summary,
                detail = mapOf("state" to "NOT_PAIRED"),
            )
        }

        // ③ 连接端口是否在监听（只连不执行，无副作用）
        val port = runCatchingCatching { savedPort() }!!
        if (!AdbPairingStateMachine.isValidPort(port)) {
            return ChannelStatus.unavailable(
                type = type,
                reason = "已配对但没有已知的连接端口：无线调试端口每次开启都会变，" +
                    "需要重新发现或手动填 5 位连接端口",
                missing = listOf("无线调试连接端口"),
                identity = identity,
                summary = summary,
                detail = mapOf("state" to "NO_PORT"),
            )
        }
        val host = runCatchingCatching { savedHost() }!!
        if (!isPortOpen(host, port)) {
            return ChannelStatus.unavailable(
                type = type,
                reason = "连接端口 $host:$port 无法连接：无线调试可能已关闭、端口已变化，" +
                    "或手机不在同一个 Wi-Fi 下",
                missing = listOf("无线调试保持开启", "与本机同一局域网"),
                identity = identity,
                summary = summary,
                detail = mapOf("state" to "PORT_CLOSED", "port" to port.toString()),
            )
        }

        // ④ 链路探活
        val alive = exec("echo ok", null, CHANNEL_PROBE_TIMEOUT_MS)
        if (!alive.isSuccess) {
            return ChannelStatus.unavailable(
                type = type,
                reason = "连接端口在监听但链路探活失败（exit=${alive.exitCode}）：" +
                    alive.output.take(200).ifBlank { "无输出" },
                missing = listOf("adb 授权未撤销"),
                identity = identity,
                summary = summary,
                detail = mapOf("state" to "LINK_DEAD", "host" to host, "port" to port.toString()),
            )
        }

        return ChannelStatus.ready(
            type = type,
            identity = "$identity @ $host:$port",
            summary = summary,
            detail = mapOf(
                "state" to "READY",
                "host" to host,
                "port" to port.toString(),
                "pairingState" to stateMachine.state.name,
            ),
        )
    }

    /**
     * 经无线 ADB 执行。
     *
     * <p>**命令语义是宿主视角**：`adb shell` 跑在设备的 `/system/bin/sh`，
     * 与 PRoot 无关。要跑 PRoot 必须由 runtime 组装好完整命令行。
     */
    override fun exec(command: String, stdin: String?, timeoutMs: Long): ShellOutcome {
        if (!transport.isReady()) {
            return ShellOutcome(-1, "[无线 ADB] ${transport.unavailableReason()}")
        }
        val port = runCatchingCatching { savedPort() }!!
        if (!AdbPairingStateMachine.isValidPort(port)) {
            return ShellOutcome(-1, "[无线 ADB] 通道不可用：没有已知的连接端口，请先完成配对")
        }
        val host = runCatchingCatching { savedHost() }!!
        return try {
            transport.shell(host, port, command, timeoutMs)
        } catch (t: Throwable) {
            ShellOutcome(-1, "[无线 ADB] 执行异常：${t.javaClass.simpleName}: ${t.message}")
        }
    }

    // ── 配对流程 ────────────────────────────────────────────────────────

    /**
     * 开始 mDNS 发现（宿主想「自动发现配对端口」时调）。
     *
     * <p>发现到的端点会被喂进状态机；配对/连接的实际动作由宿主按状态机提示推进。
     */
    fun startDiscovery(): Boolean {
        val ctx = context ?: return false
        val instance = discovery ?: synchronized(this) {
            discovery ?: AdbMdnsDiscovery(
                context = ctx,
                onPairingEndpoint = { endpoint ->
                    stateMachine.handle(
                        AdbPairingEvent.PairingEndpointDiscovered(endpoint.host, endpoint.port),
                    )
                },
                onConnectEndpoint = { endpoint ->
                    stateMachine.handle(
                        AdbPairingEvent.ConnectEndpointAvailable(endpoint.host, endpoint.port),
                    )
                },
            ).also { discovery = it }
        }
        return instance.start()
    }

    /** 停止发现。 */
    fun stopDiscovery() {
        runCatching { discovery?.stop() }
    }

    /**
     * 提交 6 位配对码，推进配对流程。
     *
     * <p>**本方法只推进状态机**：真正的 SPAKE2 交换由传输层负责
     * （默认外部 adb 客户端会执行 `adb pair host:port code`）。
     * 这样「配对状态」与「配对实现」解耦，状态机可以被完整单测。
     *
     * @return 推进后的快照；配对码非法或端口非法时直接落到 FAILED
     */
    fun submitPairingCode(pairingCode: String, port: Int = 0, host: String = AdbPairingStateMachine.LOOPBACK): AdbPairingSnapshot {
        val snapshot = stateMachine.handle(AdbPairingEvent.StartPairing(pairingCode, host, port))
        if (snapshot.state != AdbPairingState.PAIRING_PORT_PROBE) return snapshot

        val endpoint = snapshot.pairingEndpoint
        if (endpoint.isEmpty()) {
            return stateMachine.handle(
                AdbPairingEvent.PairingPortRejected(AdbFailure.NO_PAIRING_ENDPOINT),
            )
        }
        val (h, p) = splitEndpoint(endpoint) ?: return stateMachine.handle(
            AdbPairingEvent.PairingPortRejected(AdbFailure.INVALID_PORT, "端点解析失败：$endpoint"),
        )

        // ① 端口探测：只做 TCP connect。
        if (!isPortOpen(h, p)) {
            return stateMachine.handle(
                AdbPairingEvent.PairingPortRejected(
                    AdbFailure.PAIRING_PORT_UNREACHABLE,
                    "配对端口 $h:$p 不可达：确认「使用配对码配对设备」窗口还开着",
                ),
            )
        }
        stateMachine.handle(AdbPairingEvent.PairingPortAccepted)

        // ② 真正的配对交给传输层（外部 adb 客户端执行 adb pair）。
        val pairOutcome = runCatchingCatching {
            transport.pair(h, p, pairingCode, PAIRING_TIMEOUT_MS)
        }
        return when {
            pairOutcome == null -> stateMachine.handle(
                AdbPairingEvent.AuthFailed(AdbFailure.UNKNOWN, "传输层未返回结果"),
            )
            pairOutcome.isSuccess -> stateMachine.handle(AdbPairingEvent.AuthSucceeded)
            // 上游的判据：TLS/SSL 字样多半是「端口搞错了」而不是配对码错。
            pairOutcome.output.contains("SSL", ignoreCase = true) ||
                pairOutcome.output.contains("TLS", ignoreCase = true) ->
                stateMachine.handle(
                    AdbPairingEvent.AuthFailed(AdbFailure.TLS_HANDSHAKE_FAILED, pairOutcome.output.take(200)),
                )
            else -> stateMachine.handle(
                AdbPairingEvent.AuthFailed(AdbFailure.AUTH_FAILED, pairOutcome.output.take(200).ifBlank { "配对码不正确" }),
            )
        }
    }

    /** 从 FAILED 回到 DISCONNECTED 以重试。 */
    fun retryPairing(): AdbPairingSnapshot = stateMachine.handle(AdbPairingEvent.Retry)

    /** 显式断开/重置配对状态。 */
    fun resetPairing() {
        stateMachine.handle(AdbPairingEvent.Disconnect)
        stopDiscovery()
    }

    // ── 内部工具 ────────────────────────────────────────────────────────

    /** TCP 探测：只连不读写，因此没有副作用。 */
    private fun isPortOpen(host: String, port: Int, timeoutMs: Int = CHANNEL_PROBE_TIMEOUT_MS.toInt()): Boolean =
        runCatching {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), timeoutMs)
                true
            }
        }.getOrDefault(false)

    /** `host:port` → (host, port)；支持 `[ipv6]:port`。 */
    private fun splitEndpoint(endpoint: String): Pair<String, Int>? {
        val trimmed = endpoint.trim()
        if (trimmed.startsWith("[")) {
            val close = trimmed.indexOf(']')
            if (close <= 0) return null
            val host = trimmed.substring(1, close)
            val port = trimmed.substringAfter(':', "").toIntOrNull() ?: return null
            return if (AdbPairingStateMachine.isValidPort(port)) host to port else null
        }
        val index = trimmed.lastIndexOf(':')
        if (index <= 0) return null
        val host = trimmed.substring(0, index)
        val port = trimmed.substring(index + 1).toIntOrNull() ?: return null
        return if (AdbPairingStateMachine.isValidPort(port)) host to port else null
    }

    /** 同 ShizukuAccessImpl 里的写法：捕 Throwable，不给 Error 冒头的机会。 */
    private inline fun <T> runCatchingCatching(block: () -> T): T? = try {
        block()
    } catch (t: Throwable) {
        null
    }

    companion object {
        /** 通道探测的 TCP 超时。 */
        const val CHANNEL_PROBE_TIMEOUT_MS: Long = 2_000L

        /** 配对握手超时（SPAKE2 + 用户手输配对码，给宽一点）。 */
        const val PAIRING_TIMEOUT_MS: Long = 30_000L
    }
}
