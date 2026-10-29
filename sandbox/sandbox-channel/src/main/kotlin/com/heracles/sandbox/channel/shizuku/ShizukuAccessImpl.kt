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
 *           - probe()：pingBinder → getUid/getVersion → isPreV11 → checkSelfPermission
 *           - ask()：shouldShowRequestPermissionRationale 判 NEVER_ASK；6s 超时算 ERROR；
 *                    requestPermission 必须 post 到主线程
 *           - connect()：只绑一次用户服务（反复 bind 会让 Shizuku 侧连接累积）
 *           - run()：Parcel 事务 TX_EXEC，失败路径全部收敛成 ShellResult(-1, …)
 *
 * ★★★ 这是整个 sandbox-channel 里**唯一**允许 import rikka.shizuku.* 的文件 ★★★
 *
 * 它被 [ShizukuAccessLoader] 用 `Class.forName(字符串)` 反射装载，
 * **没有任何代码静态引用本类**。因此：
 *
 *   - 宿主没把 Shizuku 客户端库打进 APK ⇒ 本类装载失败 ⇒ 装载器返回
 *     UnavailableShizukuAccess ⇒ 通道报「不可用」⇒ 普通 App 通道照常工作。
 *   - 宿主打包了 Shizuku 客户端库但它没装/没启动 ⇒ 本类能装载，
 *     probe 报 binderAlive=false ⇒ 同样只是「不可用」。
 *
 * 两条路径都不会抛到调用方 —— 所有对外方法都以 try/catch(Throwable) 收口。
 *
 * ⚠️ 维护纪律：**不要把本文件的任何符号 import 到别处**，
 *    也不要把这里的逻辑挪回 ShizukuAccess.kt。隔离一旦破口，缺失的
 *    NoClassDefFoundError 会在类加载期把整条待用通道拖死。
 */

package com.heracles.sandbox.channel.shizuku

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import com.heracles.sandbox.channel.ShellOutcome
import com.heracles.sandbox.channel.repeatLimit
import rikka.shizuku.Shizuku
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * [ShizukuAccess] 的真实实现：唯一接触 `rikka.shizuku.*` 的地方。
 *
 * <p>与上游 Shiz.kt 的差异（都是**收紧**，不是放宽）：
 * 1. 探测结果不再携带 UI 文案（上游用 `ctx.getString(R.string.shiz_*)`），
 *    改由 [ShizukuChannel] 组装，本类只报事实。
 * 2. 所有对外方法的最外层都包 `try/catch (Throwable)`：
 *    上游大量用 `runCatching`（只捕 Exception），而 Shizuku 在某些设备上
 *    会抛 `NoClassDefFoundError`（provider 缺失）与 `IllegalStateException`（无主线程）。
 * 3. 授权回调加了自己的超时（上游 6_000 ms，这里同值但抽成常量并可注入）。
 */
internal class ShizukuAccessImpl(
    /** 授权弹窗的等待上限；测试可注入更短的值。 */
    private val permissionTimeoutMs: Long = PERMISSION_TIMEOUT_MS,
) : ShizukuAccess {

    // ── 上下文与用户服务连接状态 ──────────────────────────────────────────

    /** 应用上下文：仅用于取真实包名拼 `ComponentName`（用户服务必须指向本应用自己的组件）。 */
    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var remote: IBinder? = null

    @Volatile
    private var latch = CountDownLatch(1)

    @Volatile
    private var bound = false

    /** 授权监听器只挂一次（上游同款：反复 add 会让 Shizuku 侧 list 越来越长）。 */
    @Volatile
    private var permissionListenerAttached = false

    /** 当前等待中的授权回调；用序号防止「旧弹窗的结果」覆盖新一轮。 */
    @Volatile
    private var pendingCallback: ((Boolean) -> Unit)? = null

    private val askSeq = AtomicInteger(0)

    private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }

    /**
     * `UserServiceArgs` 是**重量级**对象：上游注释明确说
     * 「每次新建 args/conn 会让 Shizuku 侧连接累积」，所以只建一次。
     *
     * <p>它引用 [ShizukuExecService] 的 ComponentName —— 本应用自己的组件，
     * 因此包名必须来自 [appContext]（library 编译期不知道宿主 applicationId）。
     * 未 attach 时返回 null，[connect] 会据此放弃执行。
     */
    private val userServiceArgs: Shizuku.UserServiceArgs?
        get() {
            val context = appContext ?: return null
            return argsCache ?: synchronized(this) {
                argsCache ?: Shizuku.UserServiceArgs(
                    // ComponentName(Context, Class) 内部就取 context.packageName，
                    // 因此不必自己拼字符串（library 编译期也确实拿不到宿主 applicationId）。
                    ComponentName(context, ShizukuExecService::class.java),
                )
                    .daemon(false)
                    .version(ShizukuProtocol.USER_SERVICE_VERSION)
                    .processNameSuffix(ShizukuProtocol.USER_SERVICE_PROCESS_SUFFIX)
                    .debuggable(false)
                    .also { argsCache = it }
            }
        }

    @Volatile
    private var argsCache: Shizuku.UserServiceArgs? = null

    override fun attach(context: Context) {
        val application = context.applicationContext ?: context
        if (appContext !== application) {
            appContext = application
            // 包名变了说明 argsCache 指的组件也变了，必须重建。
            argsCache = null
        }
    }

    /** 用户服务绑定回调：连上就存 binder 并放行等待者。 */
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            remote = service
            latch.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            remote = null
            bound = false
            latch = CountDownLatch(1)
        }
    }

    // ── 探测 ────────────────────────────────────────────────────────────

    override fun facts(context: Context?): ShizukuFacts = try {
        if (context == null) {
            // 无 Context 时不 dereference，直接报不可用（纯 JVM 环境可安全探测）。
            ShizukuFacts(loadError = "缺少 Context，无法探测 Shizuku")
        } else {
            // 装了 App ≠ 能用，只用来区分「没装」和「没启动」（上游同款判据）。
            val installed = isManagerInstalled(context)
            if (!Shizuku.pingBinder()) {
                ShizukuFacts(binderAlive = false, installed = installed)
            } else {
                val uid = runCatchingCatching { Shizuku.getUid() } ?: -1
                val version = runCatchingCatching { Shizuku.getVersion() } ?: -1
                val preV11 = runCatchingCatching { Shizuku.isPreV11() } ?: true
                val granted = if (preV11) {
                    false
                } else {
                    runCatchingCatching { Shizuku.checkSelfPermission() } ==
                        PackageManager.PERMISSION_GRANTED
                }
                ShizukuFacts(
                    binderAlive = true,
                    installed = installed,
                    permissionGranted = granted,
                    preV11 = preV11,
                    uid = uid,
                    version = version,
                )
            }
        }
    } catch (t: Throwable) {
        // 典型：provider 未声明 ⇒ IllegalStateException；或 Shizuku 服务版本不匹配。
        ShizukuFacts(loadError = "Shizuku 探测异常：${t.javaClass.simpleName}: ${t.message}")
    }

    // ── 申请授权 ─────────────────────────────────────────────────────────

    override fun requestPermission(context: Context, onResult: (ShizukuPermissionResult) -> Unit) {
        try {
            if (!Shizuku.pingBinder()) {
                onResult(ShizukuPermissionResult.NO_SERVICE)
                return
            }
            val granted = runCatchingCatching { Shizuku.checkSelfPermission() } ==
                PackageManager.PERMISSION_GRANTED
            if (granted) {
                onResult(ShizukuPermissionResult.GRANTED)
                return
            }
            // 官方语义：这里为 true 表示用户选过「拒绝且不再询问」，
            // 再 request 也不会弹窗，只能去 Shizuku 管理器里手动开。
            if (runCatchingCatching { Shizuku.shouldShowRequestPermissionRationale() } == true) {
                onResult(ShizukuPermissionResult.NEVER_ASK)
                return
            }

            attachPermissionListener()
            val seq = askSeq.incrementAndGet()
            pendingCallback = { allowed ->
                if (seq == askSeq.get()) {
                    pendingCallback = null
                    onResult(if (allowed) ShizukuPermissionResult.GRANTED else ShizukuPermissionResult.DENIED)
                }
            }
            // 超时兜底：不允许「等弹窗」把调用方永久挂住。
            mainHandler.postDelayed({
                if (seq == askSeq.get() && pendingCallback != null) {
                    pendingCallback = null
                    onResult(ShizukuPermissionResult.ERROR)
                }
            }, permissionTimeoutMs)
            // requestPermission 只能在主线程发，且必须 binder 活着，否则抛 IllegalStateException。
            mainHandler.post {
                try {
                    Shizuku.requestPermission(ShizukuProtocol.REQUEST_CODE)
                } catch (t: Throwable) {
                    if (seq == askSeq.get()) {
                        pendingCallback = null
                        onResult(ShizukuPermissionResult.ERROR)
                    }
                }
            }
        } catch (t: Throwable) {
            onResult(ShizukuPermissionResult.ERROR)
        }
    }

    /** 监听器只挂一次。 */
    private fun attachPermissionListener() {
        if (permissionListenerAttached) return
        try {
            val listener = Shizuku.OnRequestPermissionResultListener { code, grant ->
                if (code == ShizukuProtocol.REQUEST_CODE) {
                    val callback = pendingCallback
                    pendingCallback = null
                    if (callback != null) {
                        mainHandler.post { callback(grant == PackageManager.PERMISSION_GRANTED) }
                    }
                }
            }
            Shizuku.addRequestPermissionResultListener(listener)
            permissionListenerAttached = true
        } catch (t: Throwable) {
            // 挂不上监听不影响探测：授权结果拿不到就按 ERROR 处理。
            permissionListenerAttached = false
        }
    }

    // ── 执行 ────────────────────────────────────────────────────────────

    override fun exec(command: String, stdin: String?, timeoutMs: Long): ShellOutcome {
        try {
            if (!Shizuku.pingBinder()) {
                return ShellOutcome(-1, "[Shizuku] 服务未运行：先在 Shizuku App 里启动服务")
            }
            if (runCatchingCatching { Shizuku.checkSelfPermission() } != PackageManager.PERMISSION_GRANTED) {
                return ShellOutcome(-1, "[Shizuku] 未授权：先到权限步骤申请 Shizuku 授权")
            }
            // Binder 单次事务放不下太大的 stdin；宁可明确报错也不要半截写入。
            if (stdin != null && stdin.length > ShizukuProtocol.MAX_STDIN_CHARS) {
                return ShellOutcome(
                    -1,
                    "[Shizuku] 标准输入过大（${stdin.length} 字符）：Binder 单次事务上限约 1MB，" +
                        "请改走 Root 通道或写小一点",
                )
            }
            val binder = connect() ?: return ShellOutcome(
                -1,
                "[Shizuku] 用户服务连接失败（服务刚重启？重试一次）",
            )
            return transactExec(binder, command, stdin, timeoutMs)
        } catch (t: Throwable) {
            return ShellOutcome(-1, "[Shizuku] 执行异常：${t.javaClass.simpleName}: ${t.message}")
        }
    }

    /** 一次 Parcel 事务：写 cmd / stdin / timeout，读回 exitCode / output。 */
    private fun transactExec(
        binder: IBinder,
        command: String,
        stdin: String?,
        timeoutMs: Long,
    ): ShellOutcome {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        return try {
            data.writeInterfaceToken(ShizukuProtocol.DESCRIPTOR)
            data.writeString(command)
            data.writeString(stdin)
            data.writeInt(timeoutMs.toInt())
            if (!binder.transact(ShizukuProtocol.TX_EXEC, data, reply, 0)) {
                ShellOutcome(-1, "[Shizuku] 事务被拒绝（调用方 uid 校验失败）")
            } else {
                reply.readException()
                val code = reply.readInt()
                ShellOutcome(code, reply.readString().orEmpty().repeatLimit())
            }
        } catch (t: Throwable) {
            // 上游同样把这里的异常收敛成 -1，而不是让 Binder 异常冒泡。
            ShellOutcome(-1, "[Shizuku] 事务异常：${t.javaClass.simpleName}: ${t.message}")
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /**
     * 绑定用户服务，返回可用的 binder。
     *
     * <p>上游的关键点：**只绑一次**。每次新建 args / conn 会让 Shizuku 侧
     * 的连接注册表累积，最终耗尽。
     */
    private fun connect(timeoutMs: Long = CONNECT_TIMEOUT_MS): IBinder? {
        remote?.let { if (it.isBinderAlive) return it else remote = null }
        if (!Shizuku.pingBinder()) return null
        val args = userServiceArgs ?: return null
        if (!bound) {
            val ok = try {
                Shizuku.bindUserService(args, serviceConnection)
                true
            } catch (t: Throwable) {
                false
            }
            if (!ok) return null
            bound = true
        }
        runCatching { latch.await(timeoutMs, TimeUnit.MILLISECONDS) }
        return remote
    }

    override fun reset() {
        remote = null
        bound = false
        latch = CountDownLatch(1)
        pendingCallback = null
        askSeq.incrementAndGet()
    }

    /** 用户服务所在的 uid（2000=shell / 0=root）；连不上返回 -1。 */
    fun userServiceUid(): Int {
        return try {
            val binder = connect() ?: return -1
            val data = Parcel.obtain()
            val reply = Parcel.obtain()
            try {
                data.writeInterfaceToken(ShizukuProtocol.DESCRIPTOR)
                if (!binder.transact(ShizukuProtocol.TX_UID, data, reply, 0)) {
                    -1
                } else {
                    reply.readException()
                    reply.readInt()
                }
            } finally {
                reply.recycle()
                data.recycle()
            }
        } catch (t: Throwable) {
            -1
        }
    }

    private fun isManagerInstalled(context: Context): Boolean = try {
        context.packageManager.getPackageInfo(ShizukuProtocol.SHIZUKU_PACKAGE, 0)
        true
    } catch (t: Throwable) {
        false
    }

    /**
     * `runCatching` 的 Throwable 版本。
     *
     * <p>Kotlin 标准库的 `runCatching` 只捕 `Throwable`（其实捕 Throwable），
     * 但这里显式写出来是为了自证：**任何** Error 都要被吞掉，
     * 绝不让 NoClassDefFoundError 冒到探测调用方。
     */
    private inline fun <T> runCatchingCatching(block: () -> T): T? = try {
        block()
    } catch (t: Throwable) {
        null
    }

    private companion object {
        const val PERMISSION_TIMEOUT_MS = 6_000L
        const val CONNECT_TIMEOUT_MS = 10_000L
    }
}
