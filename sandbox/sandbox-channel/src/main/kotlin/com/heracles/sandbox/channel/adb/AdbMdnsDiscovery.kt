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
 *           - SERVICE_PAIRING = "_adb-tls-pairing._tcp." / SERVICE_CONNECT = "_adb-tls-connect._tcp."
 *           - buildDiscoveryListener：**回调里绝不调用任何 NSD API**，一律异步派发
 *           - resolveService 串行化（NsdManager 不允许并发 resolve）
 *           - MulticastLock 的获取与释放
 *
 * 上游注释里那条血泪教训原样搬过来（别改成 registerServiceInfoCallback）：
 *   「mDNS 发现使用 Android NsdManager 经典 API（discoverServices + resolveService），
 *    不使用 Android 14 的 registerServiceInfoCallback，避免已知的 onServiceUpdated
 *    无限递归 StackOverflowError（NSD Binder 回调在部分设备上会对同一服务连续触发
 *    onServiceUpdated，且调用栈不跨线程，导致同步无限递归）」。
 */

package com.heracles.sandbox.channel.adb

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 一个 mDNS 发现的 ADB 端点。
 */
data class AdbEndpoint(
    /** mDNS 服务名（如 `adb-XXXXXX-YYYYYY`）。 */
    val name: String,
    val host: String,
    val port: Int,
) {
    val formatted: String get() = AdbPairingStateMachine.formatEndpoint(host, port)
}

/**
 * 无线调试端点的 mDNS 发现器。
 *
 * <p>**只做发现**：拿到 host/port 后交给 [AdbPairingStateMachine]，
 * 本类不知道配对码，也不做连接。这让「发现」与「配对流程」可以各自单测/替换。
 *
 * <p>三条上游纪律，逐条落实：
 * 1. **回调里不调任何 NSD API**：`onServiceFound` 只把结果投递到主线程队列，
 *    resolve 在队列里做（上游用协程，这里用 Handler —— 本模块没有 coroutines 之外
 *    的调度需求，且 Handler 少一层依赖）。
 * 2. **resolve 串行化**：NsdManager 不支持并发 resolve，用 [resolving] 互斥。
 * 3. **MulticastLock 按需持有**：只有 [start] 到 [stop] 之间才持有，
 *    用完立刻释放（上游为「规避空闲耗电」专门改成按需）。
 *
 * <p>权限：需要 `android.permission.INTERNET` 与
 * `android.permission.CHANGE_WIFI_MULTICAST_STATE`。后者在本模块的
 * manifest 里声明（见 sandbox-channel/src/main/AndroidManifest.xml），
 * 属于 normal 级权限，安装即授予，不需要运行时申请。
 */
class AdbMdnsDiscovery(
    context: Context,
    /** 发现到**配对**端点时回调（喂给状态机的 `PairingEndpointDiscovered`）。 */
    private val onPairingEndpoint: (AdbEndpoint) -> Unit,
    /** 发现到**连接**端点时回调（喂给状态机的 `ConnectEndpointAvailable`）。 */
    private val onConnectEndpoint: (AdbEndpoint) -> Unit,
) {

    private val appContext: Context = context.applicationContext ?: context

    private val nsdManager: NsdManager? =
        runCatching { appContext.getSystemService(NsdManager::class.java) }.getOrNull()

    private val multicastLock: WifiManager.MulticastLock? = runCatching {
        appContext.getSystemService(WifiManager::class.java)
            ?.createMulticastLock(MULTICAST_LOCK_TAG)
            ?.apply { setReferenceCounted(false) }
    }.getOrNull()

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 已启动标记：重复 start 是幂等的（上游 startDiscoveryInternal 用 getAndSet 同款）。 */
    private val started = AtomicBoolean(false)

    /** NsdManager 不允许并发 resolve。 */
    private val resolving = AtomicBoolean(false)

    private val pairingListener = buildListener(isPairing = true)
    private val connectListener = buildListener(isPairing = false)

    /** 最近一次发现的端点（宿主想「手动填端口」时可读）。 */
    @Volatile
    var lastPairingEndpoint: AdbEndpoint? = null
        private set

    @Volatile
    var lastConnectEndpoint: AdbEndpoint? = null
        private set

    /** 开始发现配对与连接端点。失败（无 NsdManager / 无 Wi-Fi）时静默返回 false。 */
    fun start(): Boolean {
        if (started.getAndSet(true)) return true
        val nsd = nsdManager ?: return false.also { started.set(false) }
        return try {
            runCatching { if (multicastLock?.isHeld == false) multicastLock.acquire() }
            nsd.discoverServices(SERVICE_PAIRING, NsdManager.PROTOCOL_DNS_SD, pairingListener)
            nsd.discoverServices(SERVICE_CONNECT, NsdManager.PROTOCOL_DNS_SD, connectListener)
            true
        } catch (t: Throwable) {
            started.set(false)
            false
        }
    }

    /** 停止发现并释放 MulticastLock。幂等。 */
    fun stop() {
        if (!started.getAndSet(false)) return
        val nsd = nsdManager ?: return
        runCatching { nsd.stopServiceDiscovery(pairingListener) }
        runCatching { nsd.stopServiceDiscovery(connectListener) }
        runCatching { if (multicastLock?.isHeld == true) multicastLock.release() }
    }

    /**
     * 构建发现监听器。
     *
     * <p>★ 所有回调体都只做「投递 + 立即返回」，绝不在此调用 `resolveService`
     * 或任何其它 NSD 方法 —— 这是上游为了规避同步递归崩溃定下的纪律。
     */
    private fun buildListener(isPairing: Boolean): NsdManager.DiscoveryListener =
        object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                // 只记录：发现失败不等于通道不可用（宿主可能手动填端口）。
                started.set(false)
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                // 立即返回；resolve 投递到主线程队列再做。
                val copy = serviceInfo
                mainHandler.post { resolveSerialized(copy, isPairing) }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
        }

    /** 串行化 resolve：已有进行中的 resolve 就跳过本次（上游同款 `compareAndSet` 保护）。 */
    private fun resolveSerialized(serviceInfo: NsdServiceInfo, isPairing: Boolean) {
        if (!resolving.compareAndSet(false, true)) return
        val nsd = nsdManager
        if (nsd == null) {
            resolving.set(false)
            return
        }
        // 用已废弃但各版本都稳定的 resolveService：它在所有 Android 版本上行为一致，
        // 而 registerServiceInfoCallback 在部分设备会对同一服务反复回调（上游注释）。
        @Suppress("DEPRECATION")
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                resolving.set(false)
            }

            override fun onServiceResolved(info: NsdServiceInfo) {
                try {
                    deliver(info, isPairing)
                } finally {
                    resolving.set(false)
                }
            }
        }
        try {
            @Suppress("DEPRECATION")
            nsd.resolveService(serviceInfo, listener)
        } catch (t: Throwable) {
            resolving.set(false)
        }
    }

    /** 校验并投递端点：端口越界或 host 为空一律丢弃（宁可不报，也不喂坏数据给状态机）。 */
    private fun deliver(info: NsdServiceInfo, isPairing: Boolean) {
        val host = runCatching { info.host?.hostAddress }.getOrNull()?.takeIf { it.isNotBlank() } ?: return
        val port = info.port
        if (!AdbPairingStateMachine.isValidPort(port)) return
        val name = info.serviceName.orEmpty()
        val endpoint = AdbEndpoint(name = name, host = host, port = port)
        if (isPairing) {
            lastPairingEndpoint = endpoint
            onPairingEndpoint(endpoint)
        } else {
            lastConnectEndpoint = endpoint
            onConnectEndpoint(endpoint)
        }
    }

    companion object {
        /** 配对端点的 mDNS 服务类型。 */
        const val SERVICE_PAIRING: String = "_adb-tls-pairing._tcp."

        /** 连接端点的 mDNS 服务类型。 */
        const val SERVICE_CONNECT: String = "_adb-tls-connect._tcp."

        private const val MULTICAST_LOCK_TAG = "heracles-sandbox-wireless-adb-mdns"
    }
}
