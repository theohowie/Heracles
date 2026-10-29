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

package com.heracles.sandbox.demo

import android.app.Application
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.Process
import android.util.Log
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.channel.ChannelManager
import com.heracles.sandbox.file.HostPath
import com.heracles.sandbox.file.PathSemantics
import com.heracles.sandbox.file.SandboxFileService
import com.heracles.sandbox.file.ZeroWidthFileChannel
import com.heracles.sandbox.runtime.EventSink
import com.heracles.sandbox.runtime.PathResolver
import com.heracles.sandbox.runtime.RootfsManager
import com.heracles.sandbox.runtime.SandboxDependencies
import com.heracles.sandbox.runtime.SandboxService
import com.heracles.sandbox.runtime.SandboxServiceCore
import java.io.File

/**
 * 把 [SandboxService]（AIDL Stub）真正挂到 Android 上的那个 `Service`。
 *
 * ============================================================================
 * 为什么要有独立进程 `:sandbox`
 * ============================================================================
 * `AndroidManifest.xml` 里声明的是：
 *
 * ```xml
 * <service android:name=".SandboxServiceHost"
 *          android:exported="false"
 *          android:process=":sandbox" />
 * ```
 *
 * `android:process=":sandbox"` 让执行面跑在**独立进程**里，这是 AIDL 形态相对
 * 「进程内直调」的**主要价值**（见 `docs/integration-guide.md` §1 的对比表）：
 *
 *   - **崩溃隔离**：PRoot 卡死 / SIGSEGV / OOM 发生在 `:sandbox`，宿主 UI 进程
 *     不受影响；宿主收到 `onServiceDisconnected` 后重连即可（见 [AidlClientDemo]）。
 *   - **生命周期解耦**：宿主 Activity 被回收时执行面可以继续活着（本 demo 用
 *     `BIND_AUTO_CREATE`，没有前台服务通知 —— 所以进程仍会随宿主一起被系统回收，
 *     但「宿主的 UI 线程卡死」不再波及执行）。
 *   - **执行面不碰 UI**：本进程里没有任何 View、没有 Looper 上的业务代码。
 *
 * 代价（要如实知道）：所有调用都过 binder，大文件（`writeFile` 的 `byte[]`）
 * 会被 Parcel 拷一次，单次事务上限 1 MB（== 1,048,576 B）。超过上限的
 * 文件要走进程内形态，或者先落 HOST 路径再让沙箱内命令去读。
 *
 * ============================================================================
 * 本类只做「装配 + 生命周期」
 * ============================================================================
 * - `onBind` 返回 [SandboxService]（AIDL Stub）本身；
 * - 依赖（[ChannelManager] / [SandboxFileService] / 事件日志）在这里注入
 *   —— 这正是 [SandboxServiceCore] 把 SPI 做成构造参数的原因：runtime 不反向
 *   import 宿主；
 * - `onDestroy` 调 [SandboxService.shutdown]（**阻塞**，见那边的注释）。
 *
 * 装配代码与 `SandboxFacade` 的装配逻辑**刻意共享同一套路径约定**
 * （`{filesDir}/sandbox` 下的 rootfs / workspaces / tmp / home / attachments），
 * 否则同一个 APK 的进程内路径与跨进程路径会看到两套不同的 rootfs —— 那是比
 * 「Service 缺失」更难排查的故障。
 */
class SandboxServiceHost : Service() {

    private var service: SandboxService? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate: pid=${Process.myPid()} process=${Application.getProcessName()}")

        val assembly = SandboxHostAssembly(this)
        service = SandboxService(assembly.core)

        val diagnosis = assembly.core.diagnose()
        Log.i(TAG, "core 装配完成：${diagnosis.summary()}")
        Log.i(
            TAG,
            "   rootfsReady=${diagnosis.rootfsReady} source=${diagnosis.rootfsSource} " +
                "prootUsable=${diagnosis.prootUsable} ptyNative=${diagnosis.ptyNativeAvailable} " +
                "workspaceReady=${diagnosis.workspaceReady}",
        )
    }

    /**
     * 绑定入口。
     *
     * `exported=false` ⇒ 只有本 App 能绑（本 demo 的 [AidlClientDemo] 走显式
     * `Intent(this, SandboxServiceHost::class.java)`，跨进程绑定时系统会自动
     * 在本进程（`:sandbox`）里把 Service 拉起来）。
     *
     * 注意：**没有** `onUnbind` 的收尾逻辑 —— 解绑不等于任务结束，执行中的命令
     * 应该继续跑完（契约里 `execute` 是非阻塞的，结果靠回调）。真正的收尾只发生在
     * 进程要死的时候（[onDestroy]）。
     */
    override fun onBind(intent: Intent?): IBinder? {
        Log.i(TAG, "onBind: intent=${intent?.action ?: "(null)"}")
        return service
    }

    /**
     * 进程即将结束 ⇒ 回收进程树。
     *
     * ★ 这一步**不能省**：PRoot 的 tracee（guest 里的 `bash` / `gradle` 后代）在
     * 宿主进程消失后会被 reparent 到 init 永久存活，App 侧再无手段回收。所以
     * [SandboxService.shutdown] 是阻塞的，这里也如实阻塞 —— 本进程此刻没有 UI，
     * 阻塞的代价只有一个「进程晚死几百毫秒」。
     */
    override fun onDestroy() {
        val startedAt = System.nanoTime()
        Log.i(TAG, "onDestroy: 开始回收（pid=${Process.myPid()}）")
        try {
            service?.shutdown()
        } catch (failure: Throwable) {
            // onDestroy 里抛异常会让进程以「崩溃」姿态退出，污染 logcat 里的死因
            Log.w(TAG, "onDestroy: shutdown 失败", failure)
        } finally {
            service = null
            val millis = (System.nanoTime() - startedAt) / 1_000_000
            Log.i(TAG, "onDestroy: 回收完成，耗时 ${millis}ms")
        }
        super.onDestroy()
    }

    private companion object {
        const val TAG = "SandboxSvc"
    }
}

/**
 * 组装 [SandboxServiceCore] 的四个 SPI。
 *
 * 与 `SandboxFacade` 里那段装配是同一套做法，只是这里跑在 `:sandbox` 进程里。
 * 抽成独立类（而不是塞在 Service 里）的理由：Service 的 `onCreate` 只该负责
 * 「拿到一个能用的 core」，装配细节越多越容易在生命周期里写出顺序错误。
 *
 * @param context Service 的上下文（用 `applicationContext` 更安全，但 Service
 *                本身就是单例，这里直接用不会泄漏 Activity）
 */
internal class SandboxHostAssembly(context: Context) {

    private val appContext = context.applicationContext

    /** 沙箱数据根（宿主视角）：`{filesDir}/sandbox`。与进程内形态同一个目录。 */
    val baseDir: File = File(appContext.filesDir, BASE_DIR_NAME).apply { mkdirs() }

    /** 四通道探测（NORMAL / SHIZUKU / ROOT / WIRELESS_ADB）。 */
    private val channelManager = ChannelManager(context = appContext)

    /**
     * `PathResolver` 的委托目标：**core 自己的** [RootfsManager]。
     *
     * 为什么不在装配期新建一个 RootfsManager：那样会有两份 `activeRootfs` 状态，
     * 一边 install 完另一边还以为没装（这个坑在进程内形态里真实存在，见
     * `SandboxFacade.rootfs` 的注释）。所以这里让 SPI 指向 core 持有的那一个。
     */
    private val coreRef = CoreHolder()

    private val pathResolver = object : PathResolver {
        override fun sandboxToHost(sandboxPath: String): String = resolver().sandboxToHost(sandboxPath)

        override fun hostToSandbox(hostPath: String): String? = resolver().hostToSandbox(hostPath)

        override fun rootfsHostRoot(): String? = coreRef.core?.rootfs?.rootfsHostPath()

        private fun resolver(): PathResolver =
            coreRef.core?.rootfs ?: throw SandboxException(
                SandboxException.CODE_ROOTFS_NOT_READY,
                "沙箱核心尚未装配完成，无法换算路径",
            )
    }

    /**
     * 文件读写：HOST 视角交给 [SandboxFileService]（含零宽通道与 400 KB 单次读上限）。
     *
     * 注入的方向是「core → 宿主实现」：core 只会在 `pathView == HOST` 时回调它
     * （见 `SandboxServiceCore.readFile`），SANDBOX 视角由 core 自己按 rootfs 换算。
     */
    private val fileService = SandboxFileService(
        pathSemantics = PathSemantics {
            coreRef.core?.rootfs?.rootfsHostPath()?.let { HostPath.parse(it) }
        },
        zeroWidth = ZeroWidthFileChannel(),
    )

    /** PRoot 二进制：只认 `nativeLibraryDir`（Android 10+ 禁止从 App data exec）。 */
    private val prootBinary = File(appContext.applicationInfo.nativeLibraryDir, PROOT_NAME)

    private val loaderBinary = File(appContext.applicationInfo.nativeLibraryDir, PROOT_LOADER_NAME)
        .takeIf { it.isFile }

    /**
     * 逻辑核心。
     *
     * 并发上限用默认值（前台 4 / 持久 8）：沙箱不猜宿主的工作负载语义，
     * 宿主想调就自己构造 core（见 `SandboxServiceCore` 的构造参数）。
     */
    val core: SandboxServiceCore = SandboxServiceCore(
        dependencies = SandboxDependencies(
            eventSink = LogcatEventSink,
            pathResolver = pathResolver,
            channelQuery = channelManager,
            fileAccess = { path, view ->
                // core 只在 HOST 视角回调这里（见 SandboxServiceCore.readFile 的注释），
                // 委托给 fileService 是为了拿到零宽通道与 400 KB 单次读上限。
                // 签名要求返回非 null 的 FileResult，所以不能「不适用就返回 null」——
                // SANDBOX 视角根本不会走到这里，无需分支。
                fileService.read(path, view)
            },
        ),
        baseDir = baseDir,
        assets = appContext.assets,
        prootBinary = prootBinary,
        loaderBinary = loaderBinary,
    ).also { built ->
        coreRef.core = built
    }

    /** 让回调闭包在 core 构造完成之后才解析到它。 */
    private class CoreHolder {
        @Volatile
        var core: SandboxServiceCore? = null
    }

    private companion object {
        const val BASE_DIR_NAME = "sandbox"
        const val PROOT_NAME = "libproot.so"
        const val PROOT_LOADER_NAME = "libproot-loader.so"
    }
}

/**
 * 事件出口：把沙箱的全局事件打到 logcat。
 *
 * 为什么 `NoOpEventSink` 不够：`:sandbox` 进程里没有 UI，logcat 是**唯一**能观察
 * 「rootfs 装好了 / 进程登记了 / 进程并发超限被拒」的地方。宿主真实接入时应该把
 * 这些事件转成自己的会话事件流（那是宿主的事，沙箱不反向依赖宿主）。
 *
 * `priority` 用 `INFO`：这些都是正常生命周期事件；失败路径由呼叫方自己打 WARN。
 */
internal object LogcatEventSink : EventSink {
    override fun onEvent(category: String, message: String, payload: Map<String, String>) {
        val detail = if (payload.isEmpty()) {
            ""
        } else {
            payload.entries.joinToString(prefix = " ", separator = " ") { (key, value) -> "$key=$value" }
        }
        Log.i("SandboxEvent", "[$category] $message$detail")
    }
}
