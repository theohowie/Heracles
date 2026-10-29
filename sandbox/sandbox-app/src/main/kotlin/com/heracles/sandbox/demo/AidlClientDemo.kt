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

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.Process
import android.os.RemoteException
import android.util.Log
import com.heracles.sandbox.api.ChannelInfo
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.FileResult
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.api.ISandboxService
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.RootfsStatus
import com.heracles.sandbox.api.SandboxException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * **跨进程**用 AIDL 完整走一遍：`bindService` → `ISandboxService` → `execute` → 读结果。
 *
 * ============================================================================
 * 这条路径与进程内路径的区别（务必读完）
 * ============================================================================
 * 进程内路径 = `SandboxFacade.core.execute(...)`：纯函数调用，同一个 JVM、同一个
 * 地址空间、共享内存与 fd。
 *
 * 本类走的是真正的 binder 跨进程路径：
 *
 * ```
 *   宿主 UI 进程 (:main)                    沙箱进程 (:sandbox)
 *   ─────────────────────                   ──────────────────
 *   bindService(显式 Intent)  ──binder──▶   SandboxServiceHost.onCreate()
 *                                                 │ 装配 SandboxServiceCore
 *   onServiceConnected(binder) ◀──binder──        onBind() 返回 SandboxService(Stub)
 *   ISandboxService.Stub.asInterface(binder)
 *   svc.execute(req, cb)      ──binder──▶   Stub.onTransact → SandboxService.execute
 *                                                 │ core.execute(...) → ProotEngine
 *   cb.onOutput(...)          ◀──binder──         sink.onOutput(...)
 *   cb.onExit(result)         ◀──binder──         sink.onExit(...)
 * ```
 *
 * ⭐ **实质区别不只是「多一次拷贝」**，有五条必须在宿主侧考虑的：
 *
 * 1. **崩溃隔离**：`:sandbox` 进程崩了，宿主进程还活着、UI 不闪退。
 *    代价是宿主**必须**处理 `onServiceDisconnected` 并重连（见 [bind] 的注释），
 *    否则后续调用全部炸 `DeadObjectException`。
 * 2. **线程模型**：`execute` 返回后**回调来自 binder 线程池**，不是主线程，
 *    也不是你调用时所在的那个线程。更新 UI 必须自己 post（见 [Callback]）。
 * 3. **错误表达被迫改变**：进程内可以直接 catch `SandboxException` 拿 `code`；
 *    跨进程时异常会被 binder 压扁（`SandboxException` 是受检异常 ⇒ 对端只能拿到
 *    一个没有 `code` 的 `RuntimeException`，而 `android.app.ServiceSpecificException`
 *    是 @hide，公开 SDK 里根本不存在）。于是契约按方法分档：
 *      - `execute` / `installRootfs` 的错误走 `onError(code, msg)`；
 *      - `readFile` / `writeFile` 的错误走 `FileResult.errorCode`；
 *      - `queryChannels` 失败退化为 `emptyList()`、`snapshotRootfs` 失败退化为
 *        `RootfsStatus.NOT_INSTALLED`（契约没给它们留错误位）；
 *      - `useBundledRootfs` / `resetRootfs` 返回 void **只能抛**，用公开的
 *        `IllegalStateException`，且 message 里带 `code=xx` —— 宿主用正则捞码。
 *        **不要**指望异常类型能透传，message 能保留就已经是最好情况了。
 * 4. **生命周期绑定**：`BIND_AUTO_CREATE` 意味着「至少有一个客户端绑着」时进程在；
 *    全部解绑后系统**可以**随时回收 `:sandbox`（正在跑的命令会被打断）。
 *    需要长跑任务 → 宿主改用前台服务（本 demo 刻意不做，见 Manifest 注释）。
 * 5. **大对象上限**：binder 单次事务上限 1 MB，`writeFile` 的 `byte[]` 会被拷一次。
 *    写大文件请先在宿主侧落盘，再让沙箱内命令去读（或走 `PathView.HOST`）。
 *
 * ============================================================================
 * 怎么用
 * ============================================================================
 * ```kotlin
 * val demo = AidlClientDemo(context) { line -> log(line) }
 * demo.bind()                      // 异步；onReady 之后才能调
 * demo.runDemo()                   // 查通道 → 读 rootfs 状态 → execute 一条命令
 * demo.unbind()                    // Activity.onDestroy 里调
 * ```
 *
 * @param context   任意 Context（内部只留 `applicationContext`）
 * @param onLine    日志出口（demo 里是 `MainActivity.log`，内部会自己切主线程）
 */
class AidlClientDemo(
    context: Context,
    private val onLine: (String) -> Unit,
) {

    private val appContext = context.applicationContext

    /** 当前可用的远端接口；未连上 / 已断开时为 null。 */
    @Volatile
    private var remote: ISandboxService? = null

    /** 绑定状态（`onServiceConnected` 只能回调一次或多次，靠这个标志防并发）。 */
    private val connected = AtomicBoolean(false)

    /** 等 `onServiceConnected` 的闸门（[awaitReady] 用）。 */
    private var readyLatch = CountDownLatch(1)

    /**
     * 绑定回调。
     *
     * ⚠️ **三个方法都在主线程**（`bindService` 的约定），但其中的 [onServiceConnected]
     * 里拿到的 binder 是跨进程代理 —— 后续在它上面调用会阻塞到对端返回。
     * 所以本类的所有实际调用都放在调用方给的工作线程上（见 [runDemo]）。
     */
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            remote = binder?.let { ISandboxService.Stub.asInterface(it) }
            connected.set(true)
            line("✅ onServiceConnected: ${name?.flattenToShortString()}")
            line("   本进程 pid=${Process.myPid()}（宿主），binder 实现=${binder?.javaClass?.simpleName}")
            // 跨进程时 asInterface 返回的是 Proxy（不是 Stub 本身）——这是「真的过了 binder」
            // 的间接证据；直接证据要看 `adb shell ps -A | grep sandbox`。
            line("   代理类型=${remote?.javaClass?.name ?: "(null)"}")
            readyLatch.countDown()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // ★ 沙箱进程死了（或被杀）。这才是 AIDL 形态的存在理由：
            //   宿主进程还活着，UI 不闪退。宿主必须重连，不能继续用旧代理。
            line("⚠️ onServiceDisconnected: ${name?.flattenToShortString()} —— 沙箱进程已消失")
            line("   （本进程仍在运行 —— 这正是 :sandbox 独立进程的价值）")
            remote = null
            connected.set(false)
            readyLatch = CountDownLatch(1)
        }

        override fun onBindingDied(name: ComponentName?) {
            // 进程崩溃后重新拉起时会出现：旧的 binder 已永久失效，必须重新 bind
            line("⚠️ onBindingDied: ${name?.flattenToShortString()} —— 需要重新 bind")
            remote = null
            connected.set(false)
            readyLatch = CountDownLatch(1)
        }

        override fun onNullBinding(name: ComponentName?) {
            line("❌ onNullBinding: ${name?.flattenToShortString()} —— onBind 返回了 null（不应发生）")
            readyLatch.countDown()
        }
    }

    // ========================================================================
    // 绑定 / 解绑
    // ========================================================================

    /**
     * 绑定到 `:sandbox` 进程里的 [SandboxServiceHost]。
     *
     * 用**显式** Intent（`Intent(context, SandboxServiceHost::class.java)`）而不是
     * 隐式 action：`exported=false` 的 Service 只能被显式绑定；同时显式绑定
     * 也让「绑的是哪个类」在编译期就确定，不依赖 Manifest 里的字符串。
     *
     * `BIND_AUTO_CREATE`：绑上时若 `:sandbox` 没起来，系统会**新起一个进程**并调
     * `onCreate` + `onBind`。这就是 demo 里「点 ⑤ 时 ps 里多出 :sandbox」的原因。
     */
    fun bind(): Boolean {
        val intent = Intent(appContext, SandboxServiceHost::class.java)
        line("→ bindService(${SandboxServiceHost::class.java.name})")
        val ok = appContext.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        if (!ok) {
            line("❌ bindService 返回 false（Service 未在 Manifest 声明？或进程被禁止）")
            readyLatch.countDown()
        }
        return ok
    }

    /** 解绑。**必须在 `Activity.onDestroy` 里调**，否则宿主泄漏 ServiceConnection。 */
    fun unbind() {
        if (!connected.get() && remote == null) return
        runCatching { appContext.unbindService(connection) }
            .onFailure { line("unbindService 失败：${it.message}") }
        remote = null
        connected.set(false)
        line("← unbindService")
    }

    /**
     * 等绑定完成（最多 [timeoutMs]）。返回是否连上。
     *
     * demo 用阻塞等待是为了日志顺序可读；真实宿主应该回调驱动（`onServiceConnected`
     * 之后再发请求），而不是在一个工作线程里干等。
     */
    fun awaitReady(timeoutMs: Long = BIND_TIMEOUT_MS): Boolean {
        val ok = readyLatch.await(timeoutMs, TimeUnit.MILLISECONDS)
        if (!ok) line("❌ 等 onServiceConnected 超时（${timeoutMs}ms）")
        return ok && remote != null
    }

    // ========================================================================
    // 完整闭环：查通道 → 读 rootfs → execute → 读回结果
    // ========================================================================

    /**
     * 跑一遍完整的跨进程闭环。**阻塞**，请在后台线程调。
     *
     * 顺序刻意是「先只读查询，再执行」：
     *   - [ISandboxService.queryChannels] 是最轻的一步，能最早暴露「binder 通不通」；
     *   - rootfs 状态查询不改变任何东西；
     *   - 最后才执行命令（可能在 `:sandbox` 里起 PRoot）。
     *
     * 返回一段可读报告（同时逐行通过 [onLine] 输出）。
     */
    fun runDemo(command: String = "echo hello"): String {
        val report = StringBuilder()
        fun emit(text: String) {
            report.append(text).append('\n')
            line(text)
        }

        emit("=== ⑤ AIDL 跨进程闭环 ===")
        if (!awaitReady()) {
            emit("❌ 没连上远端服务，后续步骤跳过")
            return report.toString()
        }
        val service = remote ?: run {
            emit("❌ remote 为 null")
            return report.toString()
        }

        try {
            // ---- 1. 查通道（同步 AIDL 方法）----
            emit("[1/4] queryChannels()")
            val channels: List<ChannelInfo> = service.queryChannels()
            emit("   拿到 ${channels.size} 条通道")
            channels.forEach { info ->
                emit("   · ${info.channelType?.name ?: "?"} available=${info.available} risk=${info.risk?.name ?: "?"}")
            }

            // ---- 2. rootfs 状态（顺带演示「方法里没有 rootfsStatus」怎么拿）----
            // 契约里**没有** rootfsStatus() 方法（见 ISandboxService.aidl），
            // 只能通过 snapshotRootfs / installRootfs 的返回值拿状态。
            // 这里用一次「无副作用的探测」：snapshot 会真的打快照，太重，
            // 所以改为直接执行 `true` —— 若 rootfs 没装，execute 会立刻
            // onError(CODE_ROOTFS_NOT_READY)，这本身就是最准确的状态探测。
            emit("[2/4] 准备执行（rootfs 状态由 execute 的前置检查回答）")

            // ---- 3. 执行（非阻塞 + 回调）----
            emit("[3/4] execute($command)")
            val outcome = executeBlocking(service, command)
            emit("   stdout = ${outcome.stdout.trim().ifBlank { "(空)" }}")
            emit("   stderr = ${outcome.stderr.trim().ifBlank { "(空)" }}")
            if (outcome.errorCode != null) {
                emit("   ❌ onError(code=${outcome.errorCode}): ${outcome.errorMessage}")
                if (outcome.errorCode == SandboxException.CODE_ROOTFS_NOT_READY) {
                    emit("   ⇒ 先点「① 装 rootfs」，再回来点 ⑤")
                }
            } else {
                val result = outcome.result
                emit("   exit=${result?.exitCode} ${result?.durationMillis}ms" +
                    " timedOut=${result?.timedOut} cancelled=${result?.cancelled}")
            }

            // ---- 4. 跨进程文件读写（错误走 FileResult.errorCode，不抛异常）----
            emit("[4/4] writeFile / readFile（HOST 视角，落 App cache）")
            val path = "${appContext.cacheDir.absolutePath}/aidl-demo.txt"
            val payload = "via AIDL @ ${System.currentTimeMillis()}"
            val wrote: FileResult = service.writeFile(path, payload.toByteArray(), PathView.HOST.wireValue)
            emit("   write success=${wrote.success} size=${wrote.size} path=${wrote.path}")
            if (!wrote.success) emit("   失败 code=${wrote.errorCode} ${wrote.errorMessage}")
            val read: FileResult = service.readFile(path, PathView.HOST.wireValue)
            emit("   read  success=${read.success} size=${read.size}")
            emit("   content=${read.asText()}")
            emit("   一致: ${if (read.asText() == payload) "✅" else "❌"}")
        } catch (e: IllegalStateException) {
            // ★ `useBundledRootfs` / `resetRootfs` 是返回 void 的同步方法，契约没有
            //   错误位 ⇒ 沙箱侧只能抛公开的 IllegalStateException，并把 `code=xx`
            //   写进 message。宿主这里用正则把码捞回来 —— 这是「异常过 binder 会丢
            //   结构化字段，但 message 一定保留」这一事实的直接后果。
            val code = CODE_IN_MESSAGE.find(e.message.orEmpty())?.groupValues?.get(1)
            emit("❌ IllegalStateException（跨进程已降级为 RuntimeException）：code=${code ?: "?"} ${e.message}")
        } catch (e: RemoteException) {
            emit("❌ RemoteException（沙箱进程死了？）: ${e.message}")
        } catch (e: Throwable) {
            emit("❌ ${e::class.java.simpleName}: ${e.message}")
        }

        emit("★ 这条路径与进程内的区别：回调来自 binder 线程池、崩溃被隔离到 :sandbox、")
        emit("  错误码只能走 onError / FileResult / IllegalStateException(message 带 code=) 三条出口。")
        return report.toString()
    }

    /**
     * `execute` 的阻塞包装（demo 用；真实宿主应该回调驱动 UI）。
     *
     * 用 `CountDownLatch` 等终态：`onExit` 与 `onError` **互斥**（契约），
     * 任一个到达就放行。`onError` 之后**绝不会**再来 `onExit`，所以不需要超时兜底
     * 之外的特殊处理。
     */
    private fun executeBlocking(
        service: ISandboxService,
        command: String,
        timeoutMs: Long = EXEC_TIMEOUT_MS,
    ): Outcome {
        val done = CountDownLatch(1)
        val buffer = StringBuilder()
        val resultRef = AtomicReference<ExecutionResult?>(null)
        val errorCode = AtomicReference<Int?>(null)
        val errorMessage = AtomicReference<String>("")
        val cancelled = AtomicBoolean(false)
        val chunks = AtomicInteger(0)

        val callback = object : IExecutionCallback.Stub() {
            override fun onOutput(stream: Int, chunk: String, sequence: Long) {
                // ★ 回调在 binder 线程池上；这里只往 StringBuilder 里追加（单线程串行投递，
                //   契约保证「按顺序投递并等待返回」），不碰 UI、不做 IO。
                chunks.incrementAndGet()
                buffer.append(chunk)
                if (stream == IExecutionCallback.STREAM_STDERR && DEBUG_CHUNKS) {
                    Log.d(TAG, "stderr[$sequence] ${chunk.length} 字符")
                }
            }

            override fun onProgress(percent: Int, message: String) = Unit

            override fun onExit(result: ExecutionResult) {
                resultRef.set(result)
                done.countDown()
            }

            override fun onError(code: Int, message: String) {
                errorCode.set(code)
                errorMessage.set(message)
                done.countDown()
            }

            override fun isCancelled(): Boolean = cancelled.get()
        }

        val request = ExecutionRequest(
            command = command,
            // ★ 沙箱视角路径（PRoot 内部），不是宿主路径
            workingDirectory = "/",
            timeoutMillis = timeoutMs,
        )
        // 非阻塞：立即返回，过程全部走 callback
        service.execute(request, callback)

        val finished = done.await(timeoutMs + AWAIT_SLACK_MS, TimeUnit.MILLISECONDS)
        if (!finished) {
            // 超时了：把取消标志立起来，沙箱会在输出循环里看到并走 SIGTERM 流程。
            // ★ 这就是契约说的「拉模型取消」——宿主只需要改一个 volatile 标志。
            cancelled.set(true)
            return Outcome(
                stdout = buffer.toString(),
                stderr = "",
                result = null,
                errorCode = SandboxException.CODE_TIMEOUT,
                errorMessage = "宿主侧等待超时（${timeoutMs}ms），已置取消标志",
            )
        }
        line("   （本次收到 ${chunks.get()} 个 onOutput 分片）")
        return Outcome(
            stdout = buffer.toString(),
            stderr = resultRef.get()?.stderr.orEmpty(),
            result = resultRef.get(),
            errorCode = errorCode.get(),
            errorMessage = errorMessage.get(),
        )
    }

    /** [executeBlocking] 的返回值（把「回调终态」摊平成数据）。 */
    private data class Outcome(
        val stdout: String,
        val stderr: String,
        val result: ExecutionResult?,
        val errorCode: Int?,
        val errorMessage: String,
    )

    /** 日志出口：切回主线程（demo 的 `MainActivity.log` 内部会自己 post，这里保持一致）。 */
    private fun line(text: String) {
        Log.i(TAG, text)
        onLine(text)
    }

    companion object {
        private const val TAG = "AidlClientDemo"

        /** 绑定超时：冷启 `:sandbox` 要建进程 + 装配 core（含 rootfs 探测）。 */
        private const val BIND_TIMEOUT_MS = 15_000L

        /** 执行超时：与 `MainActivity.runCommand` 同量级。 */
        private const val EXEC_TIMEOUT_MS = 180_000L

        /** 等终态时比执行超时多留的余量（给「杀进程 + 收尾」用）。 */
        private const val AWAIT_SLACK_MS = 15_000L

        /** 是否把 stderr 分片也打到 logcat（排查输出顺序问题时开）。 */
        private const val DEBUG_CHUNKS = false

        /**
         * 从 `IllegalStateException.message` 里捞 `code=xx`。
         *
         * 这不是「凑合」：`useBundledRootfs` / `resetRootfs` 返回 `void`，AIDL 契约
         * 没有给它们留错误位，而 `ServiceSpecificException` 是 @hide（公开 SDK 里
         * 不存在）。所以「message 里带码」是唯一能让宿主按码分支的办法，
         * 格式因此成为契约的一部分（见 `SandboxService.kt` 的「异常映射」）。
         */
        private val CODE_IN_MESSAGE = Regex("""code=(\d+)""")
    }
}
