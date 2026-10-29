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

import android.os.DeadObjectException
import android.util.Log
import com.heracles.sandbox.api.ChannelInfo
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.FileResult
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.api.ISandboxService
import com.heracles.sandbox.api.MountEntry
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.RootfsStatus
import com.heracles.sandbox.api.SandboxException
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * `ISandboxService.Stub` 的**唯一**实现：AIDL 协议 ↔ [SandboxServiceCore] 的适配层。
 *
 * ============================================================================
 * 这个类为什么存在
 * ============================================================================
 * 契约（`sandbox-api` 的 7 个 AIDL）与逻辑核心（[SandboxServiceCore]）早就写好了，
 * 但两者之间**缺一个 Stub** —— 见 [SandboxServiceCore] 的 KDoc：「本类刻意不实现
 * AIDL Stub」。于是任何宿主按 `docs/integration-guide.md` §3.4 接入都拿不到 IBinder。
 * 本类就是补上的那一块。
 *
 * **纪律：本类不含任何业务逻辑。** 每个方法只做三件事：
 *   1. 把 AIDL 类型/回调翻译成 runtime 的类型/回调；
 *   2. 处理「同步方法 vs suspend 方法」的阻塞语义差异；
 *   3. 把 [SandboxException] 映射成跨进程能活下来的形态（见下）。
 * 一旦某个方法里出现「判断 rootfs 在不在」「限制并发」这类东西，就是写错了地方。
 *
 * ============================================================================
 * ★ 异常映射：绝不靠「抛异常」传错误码
 * ============================================================================
 * 三条独立的理由，任何一条都足以否决「把异常跨 binder 抛出去」：
 *
 * 1. **没有可用的载体类。** `android.app.ServiceSpecificException` 是 AOSP 的
 *    `@hide` 类，**不在公开 SDK 的 `android.jar` 里**（已核验：android-36 的
 *    android.jar 全量扫描 `ServiceSpecific` 零命中）。用了就是编译期
 *    `Unresolved reference` —— 不是缺 import 的问题。
 * 2. **就算有，码也会丢。** binder 只对少数几种异常有专门分支；其余走
 *    `EX_TRANSIENT_ERROR`，对端拿到的只是一个没有 `code` 的 `RuntimeException`。
 *    [SandboxException] 继承 `java.lang.Exception`（受检），正好落在这个坑里。
 * 3. **契约本来就留了通道。** 每个 AIDL 方法自己的返回值/回调里就有错误位，
 *    用它比抛异常更精确（异常过 binder 只保得住半句话，保不住 `path` 回显等字段）。
 *
 * 因此本类**按「该方法有没有错误码出口」分档**处理，错误码 [SandboxException.code]
 * 全程原样保留：
 *
 * | 方法 | 错误出口 | 形态 |
 * |---|---|---|
 * | [execute] | `IExecutionCallback.onError(code, message)` | 回调，**不抛** |
 * | [installRootfs] | `IExecutionCallback.onError(code, message)` | 回调，**不抛** |
 * | [readFile] / [writeFile] | `FileResult(success=false, errorCode, errorMessage)` | 返回值，**不抛** |
 * | [queryChannels] | 契约未定义错误位 ⇒ 退化为 `emptyList()` + ERROR 日志 | 返回值 |
 * | [snapshotRootfs] | 契约未定义错误位 ⇒ 退化为 `RootfsStatus.NOT_INSTALLED` + 日志 | 返回值 |
 * | [useBundledRootfs] / [resetRootfs] | 返回 `void`，**无任何出口** | 只能抛；用**公开**的 `IllegalStateException`，message 里带 `code=xx` |
 *
 * 最后一行是唯一的例外，且刻意受限：
 *   - 只用 `IllegalStateException`（公开 API）；
 *   - message 形如 `"useBundledRootfs 失败（code=2）：本次构建未内置 rootfs…"`，
 *     宿主可用正则 `code=(\d+)` 把码捞回来；
 *   - 跨 binder 过去会变成 `RuntimeException`，但 **message 会保留**，
 *     所以宿主仍然能按码分支。这不是「优雅」，是「没有别的出口」时的最优解。
 *
 * ============================================================================
 * 线程模型
 * ============================================================================
 * - `execute` / `installRootfs` 是**非阻塞**的：立刻返回，真正的工作在
 *   [scope]（`SupervisorJob + Dispatchers.IO`）里跑，结果经回调上报。
 * - `readFile` / `writeFile` / `useBundledRootfs` / `snapshotRootfs` /
 *   `resetRootfs` / `queryChannels` 在 AIDL 里就是**同步**方法（契约如此：
 *   见 `ISandboxService.aidl` 与 `docs/api-reference.md` §1 的「阻塞」列）。
 *   而 [SandboxServiceCore] 把它们做成了 `suspend` ⇒ 这里用 [runBlocking] 包。
 *   **在 binder 线程上阻塞是可接受的**：binder 线程池不是主线程，
 *   且 AIDL 同步方法的阻塞是调用方明确要求的语义（代价被记在契约里）。
 * - [shutdown] 由 Service 的 `onDestroy()` 调用，**会阻塞** —— 必须阻塞，
 *   否则 `onDestroy` 返回后进程可能立刻被杀，PRoot 的 tracee 就被 reparent 到
 *   init 永久存活（见 [SandboxServiceCore.shutdown] 的注释）。
 *
 * @param core 逻辑核心（由宿主 / `sandbox-app` 的组装层构造，本类不关心它怎么来的）
 * @param scope 非阻塞方法（execute / installRootfs）的协程作用域；测试可注入
 */
class SandboxService(
    private val core: SandboxServiceCore,
    /**
     * 命名挂载层的管理面。由宿主装配时注入（实现是 sandbox-file 的 MountRegistry）。
     *
     * 传 null 表示本实例不支持命名挂载：egisterMount 会明确返回错误，
     * listMounts 返回空表，**其余四类能力完全不受影响**。
     */
    private val mountAdmin: MountAdmin? = null,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) : ISandboxService.Stub() {

    /**
     * 还在跑的非阻塞任务（execute / installRootfs）。
     *
     * 为什么要记账：`shutdown()` 里得先把这些协程叫停，再让 core 收尾进程树；
     * 否则「进程已停、协程还在往死掉的回调里写」会刷一堆 DeadObjectException，
     * 而且 [SandboxServiceCore.shutdown] 之后不该再有新输出。
     */
    private val jobs: MutableSet<Job> = Collections.newSetFromMap(ConcurrentHashMap<Job, Boolean>())

    /** 关闭标志：`shutdown()` 之后到来的调用直接拒绝，不再触碰 core。 */
    private val closed = AtomicBoolean(false)

    // ========================================================================
    // 执行（非阻塞；错误走 onError）
    // ========================================================================

    /**
     * 在 PRoot 内执行命令。
     *
     * 非阻塞：把 [IExecutionCallback] 适配成 [ExecutionSink] 后交给
     * [SandboxServiceCore.execute]，立即返回。
     *
     * 关于 `sequence`：**由沙箱侧生成**（core 里一个 per-execution 的 `AtomicLong`，
     * 从 0 单调递增），本类只透传。宿主据此检测丢失/重排 —— 若这里再编号一遍
     * 就会和 core 的序号错位。
     *
     * 错误：前置检查失败 / 并发超限 ⇒ `callback.onError(code, msg)`，**不会**有 onExit；
     * 命令跑完（含非 0 退出码 / 超时 / 取消）⇒ `callback.onExit(result)`。
     */
    override fun execute(request: ExecutionRequest?, callback: IExecutionCallback?) {
        val sink = AidlExecutionSink(requireCallback(callback, "execute"))
        if (request == null) {
            // Parcel 里是 null（宿主传了 null / 反序列化失败）：按参数非法报，别让 core 去 NPE
            sink.onError(SandboxException.CODE_INVALID_ARGUMENT, "execute: request 为 null")
            return
        }
        if (closed.get()) {
            sink.onError(SandboxException.CODE_INTERNAL, "沙箱服务已关闭（onDestroy 之后不再接受执行）")
            return
        }
        try {
            track(core.execute(request, sink))
        } catch (failure: Throwable) {
            // core.execute 内部已把业务错误收敛成 sink.onError；
            // 走到这里说明请求在进 core 之前就坏了（理论上不应发生）。
            Log.w(TAG, "execute 未能启动", failure)
            sink.onError(codeOf(failure), "execute 未能启动：${describe(failure)}")
        }
    }

    // ========================================================================
    // 文件（同步；错误走 FileResult.errorCode，绝不抛）
    // ========================================================================

    /**
     * 读文件。
     *
     * [SandboxServiceCore.readFile] 是 `suspend`，AIDL 契约里 `readFile` 是同步的
     * ⇒ 用 [runBlocking] 包住（在 binder 线程上阻塞，见类注释的「线程模型」）。
     *
     * **失败不抛异常**：契约给 `FileResult` 留了 `success/errorCode/errorMessage`，
     * 用它比抛异常更精确（异常过 binder 保不住 `path` 回显等结构化字段）。
     * `pathView` 非法这种参数错误在进 core 之前就拦下，同样落成失败的 FileResult。
     */
    override fun readFile(path: String?, pathView: Int): FileResult =
        fileOperation(path, pathView, "readFile") { resolved, view -> core.readFile(resolved, view) }

    /**
     * 写文件。语义与 [readFile] 完全一致（同步 + 失败走 FileResult）。
     */
    override fun writeFile(path: String?, data: ByteArray?, pathView: Int): FileResult {
        val bytes = data ?: ByteArray(0)
        return fileOperation(path, pathView, "writeFile") { resolved, view ->
            core.writeFile(resolved, bytes, view)
        }
    }

    // ========================================================================
    // 通道（同步；契约无错误位 ⇒ 失败退化为 emptyList）
    // ========================================================================

    /**
     * 查四个通道。
     *
     * [ChannelManager] 的探测本身**永不抛**（单条通道探测失败只会让那条
     * `available=false`），所以正常情况下这里不会走失败分支。万一真出了意外，
     * 契约没给 `queryChannels` 留错误位，只能退化成 `emptyList()` 并打 ERROR 日志
     * —— **返回空列表而不是抛异常**，是为了让宿主的「通道表 UI」不至于因为一次
     * 探测抖动就整块崩掉（`docs/integration-guide.md` §5 的验收项）。
     *
     * 注意这会**起进程**探测（ROOT 的 `su -c id`、ADB 的 `adb shell`），
     * 结果有 3 秒缓存；宿主别在 UI 线程高频调（AIDL 同步调用的固有代价）。
     */
    override fun queryChannels(): List<ChannelInfo> {
        if (closed.get()) {
            Log.w(TAG, "queryChannels: 服务已关闭，返回空列表")
            return emptyList()
        }
        return try {
            runBlocking { core.queryChannels() }
        } catch (failure: Throwable) {
            Log.e(TAG, "queryChannels 失败（契约无错误位，返回空列表）：${describe(failure)}", failure)
            emptyList()
        }
    }

    // ========================================================================
    // rootfs 管理
    // ========================================================================

    /**
     * 从 OCI 安装 rootfs（非阻塞；错误走 onError）。
     *
     * 起一个协程跑 suspend 版 [SandboxServiceCore.installRootfs]，进度经
     * [IExecutionCallback.onProgress] 上报（`percent < 0` = 不确定进度，
     * 与 OCI 安装器的语义一致）。
     *
     * **终态怎么表达**：AIDL 只给了这一个回调做「进度 + 结束」，于是约定为
     *   - 成功 ⇒ `onExit(ExecutionResult(exitCode = 0, stdout = <RootfsStatus 摘要>))`
     *   - 失败 ⇒ `onError(code, message)`（不会有 onExit，与 execute 的约定一致）
     * 复用 `onExit` 而不是只发 `onProgress(100, …)`，是因为宿主需要**唯一一个**
     * 可以 await 的终态，否则「装完了还是失败了」分不清。`stdout` 里放根文件系统
     * 摘要（label / source / 体积 / 路径），宿主可直接展示。
     *
     * 不支持取消：AIDL 契约没给 `installRootfs` 取消通道，core 的安装也在
     * `RootfsManager` 的互斥锁里跑（中途打断会留下半装状态）。
     */
    override fun installRootfs(ociRef: String?, callback: IExecutionCallback?) {
        val sink = AidlExecutionSink(requireCallback(callback, "installRootfs"))
        if (closed.get()) {
            sink.onError(SandboxException.CODE_INTERNAL, "沙箱服务已关闭（onDestroy 之后不再安装 rootfs）")
            return
        }
        val reference = ociRef.orEmpty()
        val startedAtNanos = System.nanoTime()
        track(
            scope.launch {
                try {
                    val status = core.installRootfs(reference, sink)
                    sink.onExit(
                        ExecutionResult(
                            exitCode = 0,
                            stdout = describeRootfs(status),
                            stderr = "",
                            durationMillis = elapsedMillis(startedAtNanos),
                            timedOut = false,
                            cancelled = false,
                            truncated = false,
                            // rootfs 安装不走执行通道；-1 = 未选路（与 ExecutionRequest 的约定一致）
                            channelType = CHANNEL_NONE,
                        ),
                    )
                } catch (cancellation: CancellationException) {
                    sink.onError(SandboxException.CODE_CANCELLED, "rootfs 安装被取消")
                    throw cancellation
                } catch (failure: Throwable) {
                    sink.onError(codeOf(failure), "rootfs 安装失败：${describe(failure)}")
                }
            },
        )
    }

    /**
     * 用 APK 内置 minimal rootfs。
     *
     * ★ AIDL 返回 `void`、也没有 callback ⇒ **这是本类唯一必须依赖异常的方法之一**。
     * 用公开的 [IllegalStateException]，message 里带 `code=xx`（原因见类注释的「异常映射」）。
     *
     * 语义要点：[SandboxServiceCore.useBundledRootfs] **永不抛**，失败表达为
     * [BundledRootfsResult.outcome]；其中 `NOT_BUNDLED`（本次构建没打包）不是错误，
     * 但站在 AIDL 角度「没装上」必须是一个可判定的失败 ⇒ 也抛，
     * code 取 [BundledRootfsResult.suggestedErrorCode]（= `CODE_ROOTFS_NOT_READY`）。
     *
     * 成功时不抛也不返回任何东西 —— 与 `void` 契约一致。
     */
    override fun useBundledRootfs() {
        if (closed.get()) throw closedFailure("useBundledRootfs")
        val result = try {
            runBlocking { core.useBundledRootfs() }
        } catch (failure: Throwable) {
            throw asIllegalState("useBundledRootfs", failure)
        }
        if (!result.isInstalled) {
            val code = result.suggestedErrorCode.takeIf { it != 0 }
                ?: SandboxException.CODE_ROOTFS_NOT_READY
            throw IllegalStateException(
                "useBundledRootfs 失败（code=$code）：${result.message}" +
                    "（outcome=${result.outcome}）",
            )
        }
    }

    /**
     * 给当前 rootfs 打快照（同步）。
     *
     * 契约的返回类型 [RootfsStatus] **没有错误位** ⇒ 失败退化为
     * [RootfsStatus.NOT_INSTALLED] + ERROR 日志。宿主能区分「没装」（`installed=false`）
     * 与「装好了」（`installed=true` + 快照数），而「没装」也正是失败时最常见的原因。
     */
    override fun snapshotRootfs(name: String?): RootfsStatus {
        if (closed.get()) {
            Log.w(TAG, "snapshotRootfs: 服务已关闭")
            return RootfsStatus.NOT_INSTALLED
        }
        return try {
            runBlocking { core.snapshotRootfs(name.orEmpty()) }
        } catch (failure: Throwable) {
            Log.e(
                TAG,
                "snapshotRootfs(\"${name.orEmpty()}\") 失败（契约无错误位，返回 NOT_INSTALLED）：" +
                    describe(failure),
                failure,
            )
            RootfsStatus.NOT_INSTALLED
        }
    }

    /**
     * 重置 rootfs（同步）。
     *
     * `name` 为空串 ⇒ 清空重装（core 的语义，见 [RootfsManager.resetRootfs]）。
     *
     * ★ 返回 `void` ⇒ 失败只能抛；用公开的 [IllegalStateException] + message 带 `code=xx`。
     */
    override fun resetRootfs(name: String?) {
        if (closed.get()) throw closedFailure("resetRootfs")
        try {
            runBlocking { core.resetRootfs(name.orEmpty()) }
        } catch (failure: Throwable) {
            throw asIllegalState("resetRootfs", failure)
        }
    }

        // ======================================================================
        // 命名挂载层（宿主侧配置通道）
        // ======================================================================
        // ★ 这两个方法**不是第 5 类核心能力**：上面四类（execute / readFile+writeFile
        //   / queryChannels / rootfs 管理）的语义一字未改。
        //   它们只是让宿主能把「挂载配置表」送进执行面进程 —— 因为 @name 的解析
        //   必须发生在执行面（SandboxFileService 在这里）。

        /**
         * 注册 / 覆盖一个逻辑命名挂载点。
         *
         * 结构非法时返回带 `errorCode` 的失败结果，**不抛异常**：
         * 配置错误是宿主侧问题，用返回值表达更好处理（也避免跨进程异常丢失原因）。
         */
        override fun registerMount(entry: MountEntry?): FileResult {
            if (closed.get()) {
                return mountFailure(SandboxException.CODE_CANCELLED, "服务已关闭")
            }
            if (entry == null) {
                return mountFailure(SandboxException.CODE_INVALID_ARGUMENT, "MountEntry 不能为 null")
            }
            val admin = mountAdmin
                ?: return mountFailure(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    "本服务实例未装配 MountRegistry（宿主启动时未注入 mountAdmin）",
                )
            return try {
                admin.register(entry)
                Log.i(
                    TAG,
                    "挂载点已注册：${entry.prefix} backend=${entry.backend}" +
                        (if (entry.readOnly) "（只读）" else "") +
                        (if (entry.wantsBind) " bindTo=${entry.bindTo}" else ""),
                )
                mountOk()
            } catch (e: SandboxException) {
                mountFailure(e.code, e.message.orEmpty())
            } catch (failure: Throwable) {
                mountFailure(
                    SandboxException.CODE_INTERNAL,
                    "${failure.javaClass.simpleName}: ${failure.message}",
                )
            }
        }

        /** 挂载管理接口的成功返回（无文件内容，path 留空）。 */
        private fun mountOk(): FileResult = FileResult(
            success = true,
            path = "",
            data = null,
            size = 0L,
            lastModified = 0L,
            pathView = PathView.HOST.wireValue,
            errorCode = 0,
            errorMessage = "",
        )

        /** 挂载管理接口的失败返回。 */
        private fun mountFailure(code: Int, message: String): FileResult = FileResult(
            success = false,
            path = "",
            data = null,
            size = 0L,
            lastModified = 0L,
            pathView = PathView.HOST.wireValue,
            errorCode = code,
            errorMessage = message,
        )

        /** 列出已注册挂载点（宿主用于展示只读状态与挂载来源）。 */
        override fun listMounts(): List<MountEntry> {
            if (closed.get()) return emptyList()
            return try {
                mountAdmin?.list().orEmpty()
            } catch (failure: Throwable) {
                Log.w(TAG, "listMounts 失败：${failure.javaClass.simpleName}")
                emptyList()
            }
        }


    // ========================================================================
    // 生命周期
    // ========================================================================

    /**
     * 收尾。**必须**由 Service 的 `onDestroy()` 调用。
     *
     * 顺序有讲究：
     *   1. 先 cancel 还在跑的非阻塞任务（它们各自收到 CancellationException，
     *      core 的 execute 在取消分支里仍会给宿主补一个 `onExit(cancelled = true)`，
     *      这样宿主不会永远等一个永远不会来的终态）；
     *   2. 再 [SandboxServiceCore.shutdown] —— 停掉在册进程（SIGTERM 进程组 →
     *      宽限 → SIGKILL）并清工作区快照。
     *
     * **会阻塞**：见类注释。这是刻意的 —— `onDestroy` 返回后进程可能立刻消失，
     * 清理没做完就等于制造孤儿 PRoot 进程。
     */
    fun shutdown() {
        if (!closed.compareAndSet(false, true)) return
        Log.i(TAG, "shutdown(): 取消 ${jobs.size} 个在跑任务，随后回收进程树")
        jobs.toList().forEach { job -> runCatching { job.cancel() } }
        try {
            runBlocking { core.shutdown() }
        } catch (failure: Throwable) {
            // 已经在死了：清理失败只能记下来，不能让它把 onDestroy 变成崩溃
            Log.w(TAG, "shutdown(): core 收尾失败", failure)
        }
        jobs.clear()
        scope.cancel()
        Log.i(TAG, "shutdown(): 完成")
    }

    // ========================================================================
    // 内部工具
    // ========================================================================

    /** 记账一个非阻塞任务，完成时自动出账。 */
    private fun track(job: Job) {
        jobs += job
        job.invokeOnCompletion { jobs -= job }
    }

    /**
     * 文件读写共用骨架：参数校验 → 阻塞调用 → 失败统一落成 `FileResult`。
     *
     * 全程**不抛异常**：契约里 `FileResult` 自带 `errorCode`，
     * 而抛异常过 binder 只会把它变成一个没有 code 的 `RuntimeException`。
     */
    private fun fileOperation(
        path: String?,
        pathView: Int,
        operation: String,
        action: suspend (String, PathView) -> FileResult,
    ): FileResult {
        val raw = path.orEmpty()
        val view = try {
            PathView.fromWire(pathView)
        } catch (invalid: SandboxException) {
            // 非法 pathView 是**参数**错误：进 core 之前就拦，回显原始 wire 值方便排查
            return fileFailure(raw, pathView, invalid.code, invalid.message.orEmpty())
        }
        if (closed.get()) {
            return fileFailure(
                raw,
                view.wireValue,
                SandboxException.CODE_INTERNAL,
                "$operation: 沙箱服务已关闭",
            )
        }
        return try {
            runBlocking { action(raw, view) }
        } catch (failure: Throwable) {
            // core 把可预期失败都表达成 FileResult；走到这里说明是内部 bug，
            // 但仍然不该让宿主崩 —— 落成失败结果并打日志。
            Log.w(TAG, "$operation 意外失败", failure)
            fileFailure(raw, view.wireValue, codeOf(failure), "$operation 失败：${describe(failure)}")
        }
    }

    private fun fileFailure(path: String, pathView: Int, code: Int, message: String): FileResult =
        FileResult(
            success = false,
            path = path,
            data = null,
            size = -1L,
            lastModified = 0L,
            pathView = pathView,
            errorCode = code,
            errorMessage = message.ifBlank { "未知错误" },
        )

    /**
     * 回调不能为 null（否则本次调用的结果无处投递）。
     *
     * 这是**宿主侧的编程错误**（不是沙箱错误，没有对应的 `CODE_*`），
     * 且此刻没有任何投递通道可用 ⇒ 用公开的 [IllegalArgumentException] 抛，
     * 让宿主在开发期就撞到墙上，而不是让一次执行静默消失。
     */
    private fun requireCallback(callback: IExecutionCallback?, operation: String): IExecutionCallback =
        callback ?: throw IllegalArgumentException(
            "$operation: callback 不能为 null（沙箱的错误与输出都通过它上报，传 null 等于放弃结果）",
        )

    /** 服务已关闭时的统一异常（`void` 返回方法用）。 */
    private fun closedFailure(operation: String): IllegalStateException = IllegalStateException(
        "$operation 失败（code=${SandboxException.CODE_INTERNAL}）：沙箱服务已关闭",
    )

    /**
     * 把任意失败折成**公开**的 `IllegalStateException`，message 里带 `code=xx`。
     *
     * 只给「返回 void、契约无错误位」的方法用（`useBundledRootfs` / `resetRootfs`）。
     * message 格式是**契约的一部分**（宿主用 `code=(\d+)` 解析），改动要同步文档。
     */
    private fun asIllegalState(operation: String, thrown: Throwable): IllegalStateException {
        val sandbox = thrown as? SandboxException
        if (sandbox == null) Log.w(TAG, "$operation 失败（非 SandboxException）", thrown)
        val code = sandbox?.code ?: SandboxException.CODE_INTERNAL
        val detail = sandbox?.message ?: describe(thrown)
        return IllegalStateException("$operation 失败（code=$code）：$detail")
    }

    /** 错误码提取：`SandboxException` 原样，其余折成 `CODE_INTERNAL`。 */
    private fun codeOf(thrown: Throwable): Int =
        (thrown as? SandboxException)?.code ?: SandboxException.CODE_INTERNAL

    private fun describe(thrown: Throwable): String =
        "${thrown.javaClass.simpleName}: ${thrown.message ?: "无详情"}"

    private fun elapsedMillis(startedAtNanos: Long): Long = (System.nanoTime() - startedAtNanos) / 1_000_000

    private fun describeRootfs(status: RootfsStatus): String = if (!status.installed) {
        "rootfs: 未安装"
    } else {
        "rootfs: ${status.label.ifBlank { "unknown" }} " +
            "(source=${status.source}, ${status.sizeBytes} B, snapshots=${status.snapshotCount}, " +
            "path=${status.rootfsPath})"
    }

    companion object {
        private const val TAG = "SandboxService"

        /** 「没有通道」哨兵（`ExecutionRequest.channelType` 用同一个约定）。 */
        private const val CHANNEL_NONE = -1
    }
}

/**
 * 把 AIDL 的 [IExecutionCallback] 适配成 runtime 的 [ExecutionSink]。
 *
 * 两者形状几乎一样（增量输出 / 进度 / 结束 / 错误 / 取消拉取），差异只有两处：
 *
 * 1. **回调会抛 `DeadObjectException`**（宿主进程死了）。沙箱侧绝不能让它把
 *    执行协程打崩 —— 那会跳过 `finally { registry.stop(...) }`，并发名额泄漏。
 *    所以每次投递都 `try/catch`，只记日志。
 * 2. **`isCancelled()` 走 binder（跨进程时是同步 IPC）**。契约要求实现必须
 *    立即返回；这里只能保证「对端抛异常不炸到我们」。
 *    宿主进程已经消失时返回 `true`：没人接收输出了，继续跑只是烧电与留孤儿进程。
 *
 * 同一份适配器给两条路复用：
 *   - 跨进程：`SandboxService`（binder 线程被调用 → 回调再跨回宿主）
 *   - 进程内：`SandboxFacade.execute`（demo 用，回调直接是本地对象）
 *
 * @param callback 宿主实现的回调；不得为 null
 */
class AidlExecutionSink(
    private val callback: IExecutionCallback,
) : ExecutionSink {

    /** 增量输出。`sequence` 由 core 生成，这里只透传（不要自己再编号）。 */
    override fun onOutput(stream: Int, chunk: String, sequence: Long) {
        deliver { callback.onOutput(stream, chunk, sequence) }
    }

    override fun onProgress(percent: Int, message: String) {
        deliver { callback.onProgress(percent, message) }
    }

    override fun onExit(result: ExecutionResult) {
        deliver { callback.onExit(result) }
    }

    override fun onError(code: Int, message: String) {
        deliver { callback.onError(code, message) }
    }

    override fun isCancelled(): Boolean = try {
        callback.isCancelled()
    } catch (dead: DeadObjectException) {
        Log.i(TAG, "宿主进程已消失，按「已取消」处理本次执行（不再产生孤儿进程）")
        true
    } catch (failure: Throwable) {
        Log.w(TAG, "isCancelled() 调用失败，按未取消处理：${failure.javaClass.simpleName}")
        false
    }

    /** 投递一次回调；宿主已死或实现抛异常都不能影响沙箱侧的执行流程。 */
    private inline fun deliver(block: () -> Unit) {
        try {
            block()
        } catch (dead: DeadObjectException) {
            Log.i(TAG, "宿主进程已消失，回调被丢弃")
        } catch (failure: Throwable) {
            // 契约说「回调实现绝不能阻塞」，但宿主写错时我们不能跟着崩
            Log.w(TAG, "回调宿主时出错：${failure.javaClass.simpleName}: ${failure.message}")
        }
    }

    private companion object {
        const val TAG = "SandboxService"
    }
}
