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
 * 移植来源: taixu dc7fcddb88e565929379597bbd811b440d00e34f
 *           runtime/src/main/java/top/wkbin/taixu/runtime/LinuxRuntimeImpl.kt
 *             （上游 39 KB 的运行时门面：把 installer / proot / pty / registry
 *               串起来的那部分 —— 本文件只取「执行 + rootfs 管理」这条线）
 *           runtime/src/main/java/top/wkbin/taixu/runtime/LinuxRuntime.kt
 *             （接口形状）
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * `ISandboxService` 的**逻辑核心**：把 [RootfsManager] / [ProotEngine] /
 * [ProcessRegistry] / [WorkspaceManager] 编排起来，对外提供**suspend/阻塞函数**。
 *
 * ★ **本类刻意不实现 AIDL Stub。** AIDL 的 `ISandboxService.Stub` 由
 * `sandbox-app` 侧实现（因为只有它知道 Service 生命周期、Binder 线程池、
 * 前台服务通知）。本类只提供逻辑，保持「执行面」与「进程/生命周期」解耦。
 *
 * 典型的 Stub 写法（由 sandbox-app 做，不是本模块的事）：
 * ```
 *   override fun execute(request: ExecutionRequest, callback: IExecutionCallback) {
 *       scope.launch {
 *           core.execute(request) { stream, chunk, seq -> callback.onOutput(stream, chunk, seq) }
 *               .let { result -> callback.onExit(result) }
 *       }
 *   }
 * ```
 *
 * ============================================================================
 * 关键设计：事件如何流出去
 * ============================================================================
 * 有**两条**独立的通路，刻意不合并（见 SandboxDependencies.kt 的说明）：
 *
 *   - **直连回调**（[ExecutionSink]）—— 「这次调用」的输出与结果。
 *     对应 AIDL 的 `IExecutionCallback`（onOutput / onProgress / onExit / onError）。
 *     每次 execute 一个，生命周期随调用。
 *   - **全局事件**（[EventSink]）—— 沙箱全局状态（rootfs 装好了、进程登记了）。
 *     没有具体调用方，由宿主注入。
 *
 * 为什么分开：后台进程的输出没有「调用方」，但宿主仍想知道它活着；
 * 而前台命令的输出必须精确回到发起它的那个回调，不能广播。
 *
 * ============================================================================
 * 与上游 taixu LinuxRuntimeImpl 的差异（逐条）
 * ============================================================================
 * 1. **不移植 Koin 注入**：所有依赖由构造函数显式传入（[SandboxDependencies]
 *    就是为这个存在的）。
 * 2. **不移植 `RuntimeState` 状态机**（Installing/Ready/Error 之类的 sealed class
 *    与 DataStore 持久化）。沙箱的状态是**可推导的**（rootfs 在不在、proot
 *    可不可用、PTY native 能不能加载），不需要再存一份可能过期的副本。
 * 3. **不移植 `RuntimeHealthChecker` / `EnvironmentDoctor` / `EnvironmentRepairer`**
 *    （环境自检与自动修复，约 40 KB）。沙箱提供 [diagnose] 返回结构化诊断，
 *    但**不做自动修复** —— 修复是宿主策略（可能要下网络、可能改系统设置）。
 * 4. **不移植 `ProjectType` / `DistroConfigurator` / 项目模板**（控制面）。
 * 5. **不移植 `TerminalSessionManager` / `InteractiveSessionRegistry`**。
 *    交互式终端的会话管理属于 UI 层；沙箱只提供 [PtySession] 与一次性 PTY 执行。
 *    持久进程由 [ProcessRegistry] 记账，宿主可以自己起 PTY 后把会话句柄交给
 *    registry（用 [ProcessRegistry.register]）。
 * 6. **不移植 `executeStreaming` 的 Flow 版**。AIDL 是回调模型，Flow 中间层
 *    在这里只会多一层缓冲与背压问题。
 * 7. **保留并强化**：执行前置检查（rootfs / proot / 通道）、超时、取消、
 *    只读命令的 PTY 选择、错误码映射。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.RootfsStatus
import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/**
 * 一次执行的输出/结果出口 —— 对应 AIDL 的 `IExecutionCallback`。
 *
 * 所有方法都可能被后台线程调用。实现方（Stub）负责切回主线程。
 * **实现绝不能阻塞**：沙箱会按顺序投递并等待返回。
 */
interface ExecutionSink {
    /**
     * 增量输出。
     *
     * @param stream   1=stdout 2=stderr（与 IExecutionCallback.STREAM_* 一致）
     * @param chunk    UTF-8 已增量解码的文本片段（不会切坏多字节字符）
     * @param sequence 从 0 单调递增（宿主侧用于检测丢失/重排）
     */
    fun onOutput(stream: Int, chunk: String, sequence: Long)

    /** 进度；percent 负数表示不确定进度。 */
    fun onProgress(percent: Int, message: String)

    /** 正常结束（含非 0 退出码、超时、取消 —— 三者在 result 里区分）。 */
    fun onExit(result: ExecutionResult)

    /** 沙箱自身出错（此时不会有 onExit）。 */
    fun onError(code: Int, message: String)

    /** 取消信号（沙箱轮询此方法；实现必须立即返回）。 */
    fun isCancelled(): Boolean

    companion object {
        const val STREAM_STDOUT = 1
        const val STREAM_STDERR = 2
    }
}

/** 沙箱自检结果（结构化，宿主可直接展示）。 */
data class SandboxDiagnosis(
    /** rootfs 是否可用 */
    val rootfsReady: Boolean,
    /** rootfs 来源（[RootfsStatus.SOURCE_*]） */
    val rootfsSource: Int,
    /** PRoot 二进制是否可用 */
    val prootUsable: Boolean,
    /** PTY native 库是否加载成功 */
    val ptyNativeAvailable: Boolean,
    /** 工作区是否就绪 */
    val workspaceReady: Boolean,
) {
    /** 是否「可以执行命令」—— 三个必要条件都满足。 */
    val canExecute: Boolean get() = rootfsReady && prootUsable

    /** 人类可读的诊断摘要（宿主可直接展示）。 */
    fun summary(): String = buildString {
        if (canExecute) {
            append("沙箱就绪")
            if (!ptyNativeAvailable) append("（PTY 不可用：交互式命令会退化）")
        } else {
            append("沙箱未就绪：")
            val missing = buildList {
                if (!rootfsReady) add("rootfs 未安装")
                if (!prootUsable) add("PRoot 二进制不可用")
                if (!workspaceReady) add("工作区未创建")
            }
            append(missing.joinToString("；"))
        }
    }
}

/**
 * 沙箱逻辑核心。
 *
 * 线程安全：所有字段在构造时确定；[execute] 可并发调用（并发上限由
 * [ProcessRegistry] 管）。rootfs 变更操作在 [RootfsManager] 的锁内串行。
 *
 * @param dependencies 宿主注入的 SPI（EventSink / PathResolver / ChannelQuery / fileAccess）
 * @param baseDir      沙箱数据根目录（App 私有目录内）
 * @param assets       AssetManager（内置 rootfs 用）
 * @param prootBinary  宿主视角的 PRoot 可执行文件
 * @param loaderBinary PRoot 的 loader（可为 null，但 `--link2symlink` 会缺能力）
 * @param registryBaseOverride 可选：OCI registry base（自建镜像站）
 */
class SandboxServiceCore(
    private val dependencies: SandboxDependencies,
    baseDir: File,
    assets: android.content.res.AssetManager,
    private val prootBinary: File,
    private val loaderBinary: File?,
    registryBaseOverride: String? = null,
    /** 前台命令并发上限 */
    maxForeground: Int = ProcessRegistry.DEFAULT_MAX_FOREGROUND,
    /** 持久进程上限 */
    maxPersistent: Int = ProcessRegistry.DEFAULT_MAX_PERSISTENT,
    /**
     * 命名挂载层：需要 bind 进 rootfs 的条目来源。
     *
     * null = 不启用（行为与引入挂载层之前**完全一致**）。
     * 实现是 `sandbox-file` 的 `MountRegistry`；执行层只认这个接口，不依赖 file 模块。
     */
    private val mountBindSource: MountBindSource? = null,
    /**
     * 命名挂载层：命令串里 `@name/...` 的改写器。
     *
     * null = 不改写（命令原样进 shell，等价于不启用挂载层）。
     */
    private val commandRewriter: CommandRewriter? = null,
) {

    /** 沙箱数据根目录。 */
    val baseDir: File = baseDir

    /** 事件出口（宿主注入）。 */
    val eventSink: EventSink get() = dependencies.eventSink

    /** PTY native 是否可用（只探测一次，见 [PtySession]）。 */
    val ptyNativeAvailable: Boolean get() = PtySession.nativeAvailable


    // ---- 各组件 ----
    private val rootfsManager = RootfsManager(
        baseDir = baseDir,
        assets = assets,
        eventSink = dependencies.eventSink,
        registryBaseOverride = registryBaseOverride,
    )

    private val workspaces = WorkspaceManager(
        workspacesRoot = File(baseDir, WORKSPACES_DIR_NAME),
        snapshotRoot = File(baseDir, WORKSPACE_SNAPSHOTS_DIR_NAME),
        eventSink = dependencies.eventSink,
    )

    private val registry = ProcessRegistry(
        maxForeground = maxForeground,
        maxPersistent = maxPersistent,
        eventSink = dependencies.eventSink,
    )

    /** 执行用的协程作用域（读循环 / 排水协程挂在这里）。 */
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** 全局执行序号（给 id 用；与 per-execution 的 output sequence 不同）。 */
    private val executionCounter = AtomicLong(0)

    /** 对外暴露 rootfs 管理器（宿主可能想直接查状态）。 */
    val rootfs: RootfsManager get() = rootfsManager

    /** 对外暴露工作区管理器。 */
    val workspace: WorkspaceManager get() = workspaces

    /** 对外暴露进程注册表（宿主可能要列/停持久进程）。 */
    val processes: ProcessRegistry get() = registry

    // ========================================================================
    // 诊断
    // ========================================================================

    /** 自检（不抛异常，返回结构化结果）。 */
    fun diagnose(): SandboxDiagnosis = SandboxDiagnosis(
        rootfsReady = rootfsManager.isInstalled(),
        rootfsSource = rootfsManager.status().source,
        prootUsable = prootBinary.isFile && prootBinary.canRead() && prootBinary.length() > 0,
        ptyNativeAvailable = ptyNativeAvailable,
        workspaceReady = workspaces.defaultWorkspace.hostDir.isDirectory,
    )

    // ========================================================================
    // 执行
    // ========================================================================

    /**
     * 执行一次命令。
     *
     * **非阻塞**：立即返回 [Job]，过程通过 [sink] 上报。
     *
     * 错误处理契约：
     *   - 前置检查失败（rootfs 没装 / 通道不可用 / 并发超限）⇒ `sink.onError(code, msg)`，
     *     **不会**有 onExit
     *   - 命令跑完（含超时 / 取消）⇒ `sink.onExit(result)`
     *
     * @return 可用于 `job.cancel()`；取消会让沙箱走「SIGTERM 进程组 → 宽限 → SIGKILL」
     */
    fun execute(request: ExecutionRequest, sink: ExecutionSink): Job {
        val executionId = "exec-${executionCounter.incrementAndGet()}"
        return scope.launch {
            try {
                runExecution(executionId, request, sink)
            } catch (cancellation: CancellationException) {
                // 协程被取消（宿主的 Job.cancel()）：不是错误，但必须有终态，
                // 否则宿主永远等不到 onExit。
                runCatching {
                    sink.onExit(
                        ExecutionResult(
                            exitCode = EXIT_CANCELLED,
                            stdout = "",
                            stderr = "执行被取消",
                            durationMillis = 0,
                            timedOut = false,
                            cancelled = true,
                            truncated = false,
                            channelType = request.channelType,
                        ),
                    )
                }
                throw cancellation
            }
        }
    }

    /** [execute] 的 suspend 版本（宿主已经在自己协程里时用）。 */
    suspend fun executeAndWait(request: ExecutionRequest, sink: ExecutionSink): ExecutionResult {
        val executionId = "exec-${executionCounter.incrementAndGet()}"
        return runExecution(executionId, request, sink)
    }

    /**
     * 真正的执行流程。
     *
     * 顺序：前置检查 → 选通道 → 组 spec → 选 PTY/管道 → 登记进程 → 跑 → 出结果。
     */
    private suspend fun runExecution(
        executionId: String,
        request: ExecutionRequest,
        sink: ExecutionSink,
    ): ExecutionResult = withContext(Dispatchers.IO) {
        val startedAt = System.nanoTime()

        // ---- 1. 前置检查：rootfs ----
        if (!rootfsManager.isInstalled()) {
            val diagnosis = diagnose()
            val message = buildString {
                append("沙箱未就绪：rootfs 未安装。")
                if (!diagnosis.ptyNativeAvailable) append("（另外 PTY native 库也不可用）")
                append("请先调用 installRootfs(ociRef) 或 useBundledRootfs()。")
            }
            sink.onError(SandboxException.CODE_ROOTFS_NOT_READY, message)
            return@withContext errorResult(
                SandboxException.CODE_ROOTFS_NOT_READY,
                message,
                request.channelType,
                startedAt,
            )
        }

        // ---- 2. 前置检查：PRoot ----
        if (!prootBinary.isFile || !prootBinary.canRead() || prootBinary.length() == 0L) {
            val message = "PRoot 二进制不可用（${prootBinary.absolutePath}）：" +
                "AAR 里缺少 libproot.so，或当前 ABI 不是 arm64-v8a。"
            sink.onError(SandboxException.CODE_INTERNAL, message)
            return@withContext errorResult(
                SandboxException.CODE_INTERNAL,
                message,
                request.channelType,
                startedAt,
            )
        }

        // ---- 3. 选通道 ----
        // 沙箱只回答「有哪些通道可用」，权限决策在宿主。这里只做**可用性**校验。
        val channel = try {
            dependencies.channelQuery.selectChannel(request.channelType)
        } catch (failure: SandboxException) {
            sink.onError(failure.code, failure.message.orEmpty())
            return@withContext errorResult(failure.code, failure.message.orEmpty(), request.channelType, startedAt)
        }

        // ---- 4. 组 engine + spec ----
        val engine = ProotEngine(
            prootBinary = prootBinary,
            loaderBinary = loaderBinary,
            rootfsHostRoot = File(rootfsManager.rootfsHostPath()!!),
            workspaceHostRoot = workspaces.defaultWorkspace.hostDir,
            homeHostRoot = File(baseDir, HOME_DIR_NAME),
            tmpHostRoot = File(baseDir, TMP_DIR_NAME),
            attachmentsHostRoot = File(baseDir, ATTACHMENTS_DIR_NAME),
            eventSink = dependencies.eventSink,
        )
        engine.ensureHostDirs()

        // 工作目录（沙箱视角）必须校验：调用方可能传 `/../../etc`
        val workingDirectory = try {
            val normalized = engine.normalizeGuestPath(request.workingDirectory)
            if (".." in normalized.split('/')) {
                throw SandboxException(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    "工作目录不允许包含 ..：${request.workingDirectory}",
                )
            }
            normalized
        } catch (failure: SandboxException) {
            sink.onError(failure.code, failure.message.orEmpty())
            return@withContext errorResult(
                failure.code,
                failure.message.orEmpty(),
                channel,
                startedAt,
            )
        }

        // 环境变量：调用方给的是 "K=V" 列表，拆成 map
        val overlay = parseEnvironment(request.environment)

        // ---- 4.5 命名挂载层：`@name/...` → 物理路径（**必须在这里，早于 spec 组装**）----
        //
        // 顺序是硬约束：
        //   原始命令串 → CommandRewriter（@name 变成物理路径）→ ProotExecSpec → proot
        // 放到 proot 组装之后的话，`@name` 会原样进 shell，被当成变量或通配符。
        //
        // 为什么由 core 调、而不是塞进 ProotEngine：
        //   `sandbox-runtime` 不依赖 `sandbox-file`（依赖方向是 file → runtime）。
        //   core 通过 [CommandRewriter] / [MountBindSource] 两个接口拿到实现，
        //   执行层因此完全不知道 `@name` 的存在。
        val resolvedCommand = try {
            commandRewriter?.rewriteCommand(request.command) ?: request.command
        } catch (failure: SandboxException) {
            sink.onError(failure.code, failure.message.orEmpty())
            return@withContext errorResult(
                failure.code,
                failure.message.orEmpty(),
                channel,
                startedAt,
            )
        }

        // 命名挂载点要 bind 进 rootfs 的，合并进 extraBinds（仍然过 validateBind 白名单）
        val mountBinds = mountBindSource?.bindMounts().orEmpty()

        val spec = ProotExecSpec(
            commandLine = resolvedCommand,
            workingDirectory = workingDirectory,
            environment = overlay,
            timeoutMillis = request.timeoutMillis,
            extraBinds = mountBinds,
            columns = request.ptyColumns,
            rows = request.ptyRows,
        )

        // ---- 5. 输出序号（单调递增给宿主检测丢失） ----
        val sequence = AtomicLong(0)
        val listener = ProotOutputListener { stream, chunk ->
            sink.onOutput(stream, chunk, sequence.getAndIncrement())
        }

        // ---- 6. 选 PTY / 管道 ----
        // 只有「调用方明确要 PTY」时才走真 TTY。刻意不做「自动猜测」：
        // 真 TTY 会把 stderr 合并进 stdout（TTY 只有一根流），而 AIDL 契约里
        // stdout/stderr 是分开的 —— 自动切换会让宿主看到 stderr 变空的怪现象。
        val usePtyPath = request.usePty
        if (usePtyPath && !ptyNativeAvailable) {
            val message = "本次请求要求 PTY（usePty=true），但 PTY native 库不可用：" +
                "AAR 里缺少 arm64-v8a/libpty_bridge.so。请改用 usePty=false，或修复打包。"
            sink.onError(SandboxException.CODE_INTERNAL, message)
            return@withContext errorResult(SandboxException.CODE_INTERNAL, message, channel, startedAt)
        }

        // ---- 7. 登记进程（并发上限在这里生效） ----
        val cancelledFlag = AtomicBoolean(false)
        val kind = ExecutionKind.FOREGROUND
        val closer: suspend () -> Unit = {
            // 进程本身的收尾由 ProotEngine / PtySession 在各自的 finally 里做；
            // 这里只需要标记，让正在跑的循环尽快退出。
            cancelledFlag.set(true)
        }
        val probe: () -> Boolean = { !cancelledFlag.get() }

        // 前置检查通过、即将真正执行：这时才占并发名额（不要因为参数错误白占名额）
        try {
            registry.register(
                id = executionId,
                kind = kind,
                pid = -1,
                closer = closer,
                probe = probe,
            )
        } catch (busy: SandboxException) {
            sink.onError(busy.code, busy.message.orEmpty())
            return@withContext errorResult(busy.code, busy.message.orEmpty(), channel, startedAt)
        }

        try {
            // ---- 8. 跑 ----
            // 取消有两个来源：宿主的 sink.isCancelled()，以及 ProcessRegistry 的 closer
            val cancelSignal: () -> Boolean = {
                sink.isCancelled() || cancelledFlag.get()
            }

            val result = if (usePtyPath) {
                engine.executePty(
                    spec = spec,
                    scope = scope,
                    listener = listener,
                    cancelSignal = cancelSignal,
                    feedStdin = request.inputData,
                )
            } else {
                engine.executePiped(
                    spec = spec,
                    scope = scope,
                    listener = listener,
                    cancelSignal = cancelSignal,
                )
            }

            val duration = (System.nanoTime() - startedAt) / 1_000_000
            val finalResult = ExecutionResult(
                exitCode = result.exitCode,
                stdout = result.stdout,
                stderr = result.stderr,
                durationMillis = duration,
                timedOut = result.timedOut,
                cancelled = result.cancelled,
                truncated = result.truncated,
                channelType = channel,
            )

            // 超时/取消也走 onExit（AIDL 契约：「执行正常结束（包括非 0 退出码、
            // 超时、被取消 —— 三者都在 result 里区分）」）
            sink.onExit(finalResult)
            finalResult
        } catch (failure: SandboxException) {
            // 沙箱自身错误（启动失败等）：契约规定这种情况走 onError 而不是 onExit
            sink.onError(failure.code, failure.message.orEmpty())
            errorResult(failure.code, failure.message.orEmpty(), channel, startedAt)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Throwable) {
            val message = "执行时发生意外错误：${failure.message ?: failure::class.java.simpleName}"
            sink.onError(SandboxException.CODE_INTERNAL, message)
            errorResult(SandboxException.CODE_INTERNAL, message, channel, startedAt)
        } finally {
            // 释放并发名额（幂等）
            runCatching { registry.stop(executionId) }
        }
    }

    /**
     * 停止全部在跑/在册进程。
     *
     * 宿主在 Service.onDestroy() 里必须调这个 —— 否则 PRoot 的 tracee 会
     * reparent 到 init 永久存活。
     */
    suspend fun shutdown() {
        runCatching { registry.stopAll() }
        runCatching { workspaces.clearSnapshots() }
        eventSink.onEvent(EventSink.CATEGORY_LIFECYCLE, "沙箱已关闭", emptyMap())
    }

    // ========================================================================
    // rootfs 管理（转发给 RootfsManager，保持宿主只依赖一个门面）
    // ========================================================================

    /** 从 OCI 安装完整 rootfs。 */
    suspend fun installRootfs(
        ociRef: String,
        sink: ExecutionSink? = null,
    ): RootfsStatus = rootfsManager.installOci(ociRef) { percent, message ->
        runCatching { sink?.onProgress(percent, message) }
    }

    /**
     * 使用 APK 内置 minimal rootfs（离线 fallback）。
     *
     * **永不抛异常**：assets 里没有 bundle 时返回
     * [BundledRootfsResult.Outcome.NOT_BUNDLED]，宿主应回退到 [installRootfs]。
     */
    suspend fun useBundledRootfs(): BundledRootfsResult {
        val result = rootfsManager.useBundledRootfs()
        if (result.isInstalled) extractBundledTooltools()
        return result
    }

    /**
     * **T1 工具**（aapt2 / aidl / zipalign）的解包器。
     *
     * 这三个是**内置在 APK 里**的（高频操作：解析 APK、改资源），
     * 与 T2（JDK + Gradle，用户激活时下载）分开 —— 见 [BundledTooltools] 的 KDoc。
     */
    val tooltools: BundledTooltools = BundledTooltools(
        openAsset = { name -> runCatching { assets.open(name) }.getOrNull() },
        rootfsHostRoot = { rootfsManager.rootfsHostPath() },
    )

    /**
     * 确保 T1 工具已解包（幂等，可在 rootfs 就绪后随时调用）。
     *
     * 不抛异常：失败如实返回，由宿主决定怎么提示。
     */
    fun ensureTooltools(): BundledTooltools.ExtractResult = tooltools.ensureExtracted()

    /** rootfs 就绪后立即解包 T1；失败只记事件，不影响 rootfs 本身。 */
    private fun extractBundledTooltools() {
        val r = tooltools.ensureExtracted()
        dependencies.eventSink.onEvent(
            EventSink.CATEGORY_ROOTFS,
            "T1 工具解包：${r.status} ${r.message}",
            mapOf("status" to r.status.name, "path" to r.path),
        )
    }

    /** 当前 rootfs 状态。 */
    fun rootfsStatus(): RootfsStatus = rootfsManager.status()

    /** 给 rootfs 做快照。 */
    suspend fun snapshotRootfs(name: String): RootfsStatus = rootfsManager.snapshotRootfs(name)

    /**
     * 重置 rootfs。
     *
     * @param name 快照名；空串表示清空（等待宿主重新选策略安装）
     */
    suspend fun resetRootfs(name: String): RootfsStatus = rootfsManager.resetRootfs(name)

    // ========================================================================
    // 文件（按 PathView 语义转发）
    // ========================================================================

    /**
     * 读文件。
     *
     * 语义见 [PathView]：HOST 走宿主视角（含零宽通道，由 [SandboxDependencies.fileAccess]
     * 注入实现），SANDBOX 走 PRoot 根文件系统视角（经 [ProotPathResolver] 换算）。
     *
     * 说明：**本方法不做权限判断**（沙箱不实现权限策略，见 AIDL 注释）。
     */
    suspend fun readFile(path: String, pathView: PathView): com.heracles.sandbox.api.FileResult =
        withContext(Dispatchers.IO) {
            // HOST 视角 + 注入了零宽通道 ⇒ 交给注入实现（它才有跨 App 能力）
            if (pathView == PathView.HOST) {
                dependencies.fileAccess?.invoke(path, pathView)?.let { return@withContext it }
            }
            if (pathView == PathView.SANDBOX && !rootfsManager.isInstalled()) {
                return@withContext fileError(
                    path,
                    pathView,
                    SandboxException.CODE_ROOTFS_NOT_READY,
                    "rootfs 未安装：无法按沙箱视角读取 $path",
                )
            }
            val hostPath = if (pathView == PathView.SANDBOX) {
                try {
                    rootfsManager.sandboxToHost(path)
                } catch (failure: SandboxException) {
                    return@withContext fileError(
                        path,
                        pathView,
                        failure.code,
                        failure.message.orEmpty(),
                    )
                }
            } else {
                path
            }
            val file = File(hostPath)
            try {
                if (!file.isFile) {
                    return@withContext fileError(
                        path,
                        pathView,
                        SandboxException.CODE_IO,
                        "文件不存在或不是普通文件：$hostPath",
                    )
                }
                val data = file.readBytes()
                com.heracles.sandbox.api.FileResult(
                    success = true,
                    path = path,
                    data = data,
                    size = data.size.toLong(),
                    lastModified = file.lastModified(),
                    pathView = pathView.wireValue,
                    errorCode = 0,
                    errorMessage = "",
                )
            } catch (failure: Throwable) {
                fileError(
                    path,
                    pathView,
                    SandboxException.CODE_IO,
                    "读取文件失败：${failure.message ?: failure::class.java.simpleName}",
                )
            }
        }

    /**
     * 写文件。
     *
     * HOST 视角 + 注入了零宽通道 ⇒ 交给注入实现；否则直接落盘。
     */
    suspend fun writeFile(
        path: String,
        data: ByteArray,
        pathView: PathView,
    ): com.heracles.sandbox.api.FileResult = withContext(Dispatchers.IO) {
        if (pathView == PathView.SANDBOX && !rootfsManager.isInstalled()) {
            return@withContext fileError(
                path,
                pathView,
                SandboxException.CODE_ROOTFS_NOT_READY,
                "rootfs 未安装：无法按沙箱视角写入 $path",
            )
        }
        val hostPath = if (pathView == PathView.SANDBOX) {
            try {
                rootfsManager.sandboxToHost(path)
            } catch (failure: SandboxException) {
                return@withContext fileError(path, pathView, failure.code, failure.message.orEmpty())
            }
        } else {
            path
        }
        val file = File(hostPath)
        try {
            file.parentFile?.let { parent ->
                if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
                    return@withContext fileError(
                        path,
                        pathView,
                        SandboxException.CODE_IO,
                        "无法创建父目录：${parent.absolutePath}",
                    )
                }
            }
            file.writeBytes(data)
            com.heracles.sandbox.api.FileResult(
                success = true,
                path = path,
                data = data,
                size = data.size.toLong(),
                lastModified = file.lastModified(),
                pathView = pathView.wireValue,
                errorCode = 0,
                errorMessage = "",
            )
        } catch (failure: Throwable) {
            fileError(
                path,
                pathView,
                SandboxException.CODE_IO,
                "写入文件失败：${failure.message ?: failure::class.java.simpleName}",
            )
        }
    }

    /** 查询通道（转发给注入的 ChannelQuery）。 */
    fun queryChannels(): List<com.heracles.sandbox.api.ChannelInfo> =
        dependencies.channelQuery.queryChannels()

    // ========================================================================
    // 内部工具
    // ========================================================================

    private fun errorResult(
        code: Int,
        message: String,
        channelType: Int,
        startedAtNanos: Long,
    ): ExecutionResult = ExecutionResult(
        exitCode = EXIT_FAILURE,
        stdout = "",
        stderr = message,
        durationMillis = (System.nanoTime() - startedAtNanos) / 1_000_000,
        timedOut = code == SandboxException.CODE_TIMEOUT,
        cancelled = code == SandboxException.CODE_CANCELLED,
        truncated = false,
        channelType = channelType,
    )

    private fun fileError(
        path: String,
        pathView: PathView,
        code: Int,
        message: String,
    ): com.heracles.sandbox.api.FileResult = com.heracles.sandbox.api.FileResult(
        success = false,
        path = path,
        data = null,
        size = -1,
        lastModified = 0,
        pathView = pathView.wireValue,
        errorCode = code,
        errorMessage = message,
    )

    /** 把 `["K=V", ...]` 拆成 map；非法条目忽略并记事件（不因为一个坏变量废掉整次执行）。 */
    private fun parseEnvironment(entries: List<String>): Map<String, String> {
        val result = mutableMapOf<String, String>()
        entries.forEach { entry ->
            val index = entry.indexOf('=')
            if (index <= 0) {
                eventSink.onEvent(
                    EventSink.CATEGORY_EXEC,
                    "忽略非法环境变量条目（要求 K=V）",
                    mapOf("entry" to entry.take(64)),
                )
                return@forEach
            }
            result[entry.substring(0, index)] = entry.substring(index + 1)
        }
        return result
    }

    companion object {
        /** 通用失败退出码（前置检查失败、内部错误）。 */
        const val EXIT_FAILURE = 1

        /** 被取消的退出码（与 exec 路径的 128+SIGTERM 区分开）。 */
        const val EXIT_CANCELLED = 130

        private const val WORKSPACES_DIR_NAME = "workspaces"
        private const val WORKSPACE_SNAPSHOTS_DIR_NAME = "workspace-snapshots"
        private const val HOME_DIR_NAME = "home"
        private const val TMP_DIR_NAME = "tmp"
        private const val ATTACHMENTS_DIR_NAME = "attachments"
    }
}
