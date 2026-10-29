/*
 * Copyright (C) 2026 The Heracles Authors
 *
 * SPDX-License-Identifier: GPL-3.0
 */

package com.theohowie.heracles.bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.heracles.sandbox.api.ChannelInfo
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.api.MountBackend
import com.heracles.sandbox.api.MountEntry
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.channel.ChannelManager
import com.heracles.sandbox.file.AndroidSafDocumentIo
import com.heracles.sandbox.file.MountRegistry
import com.heracles.sandbox.file.MountResolver
import com.heracles.sandbox.file.PathSemantics
import com.heracles.sandbox.file.SandboxFileService
import com.heracles.sandbox.file.ZeroWidthFileChannel
import com.heracles.sandbox.runtime.SandboxDependencies
import com.heracles.sandbox.runtime.SandboxServiceCore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/**
 * 沙箱（Heracles-taixu-sandbox）的设备桥。
 *
 * ============================================================================
 * 这是什么、不是什么
 * ============================================================================
 * 沙箱是**内联在本 APK 里的执行面**（PRoot + rootfs），不是第二个 App。
 * 本类只做一件事：把沙箱的能力以 MethodChannel 暴露给 Dart。
 *
 * **它不负责权限决策**：沙箱只回答「有哪些通道可用、风险多高」，
 * 放不放行由 Heracles 控制面（Dart 侧门禁）决定。
 *
 * ============================================================================
 * 与既有 `exec.run` 的关系
 * ============================================================================
 * `heracles/device` 的 `exec.run` 走 [DeviceShell]（真实设备 shell/Shizuku）。
 * 本类的 `sandbox.execute` 是**另一条路**：命令在 PRoot rootfs 内跑。
 * 两者刻意分开——沙箱不会替代设备 shell，也不会绕过它。
 *
 * ============================================================================
 * 通道协议（`heracles/sandbox`）
 * ============================================================================
 * | 方法 | 参数 | 返回 |
 * |---|---|---|
 * | `status` | — | `{installed, rootfsSummary, prootReady, channels:[...]}` |
 * | `activate` | `ociRef?` | `{ok, summary}`：装 rootfs（内置优先，OCI 兜底） |
 * | `execute` | `command, workdir?, timeoutMs?, usePty?` | 流式回调 + 最终 `{exitCode, stdout, stderr, durationMs}` |
 * | `readFile` / `writeFile` | `path, view?` | `{ok, text?, size, errorCode, error}` |
 * | `registerMount` | `name, backend, hostPath?, treeUri?, readOnly?, bindTo?` | `{ok, error?}` |
 * | `listMounts` | — | `[{name, backend, readOnly, bindTo, description}]` |
 * | `queryChannels` | — | `[...]` |
 *
 * ⚠️ 流式输出走 `sandbox/output` 回调通道（`{id, stream, chunk}`），
 * 由彼此独立的 MethodChannel 发送——避免把大输出塞进 `result.success`。
 */
class SandboxBridge(
    private val context: Context,
    private val scope: CoroutineScope,
    private val mainHandler: Handler,
) {

    private val baseDir: File =
        File(context.filesDir, BASE_DIR_NAME).apply { mkdirs() }

    /** 四通道汇总器（实现 runtime 的 ChannelQuery SPI）。 */
    private val channelManager = ChannelManager(context)

    /** 给 Dart 看的一行 rootfs 摘要。 */
    private fun rootfsSummary(): String = runCatching {
        val s = core.rootfs.status()
        if (!s.installed) "未安装" else "${s.label} (source=${s.source}, ${s.sizeBytes} B, snapshots=${s.snapshotCount})"
    }.getOrDefault("未知")

    /** 命名挂载注册表：模型只写 `@name/...`，物理路径由这里解析。 */
    val mounts: MountRegistry = MountRegistry {
        core.rootfs.rootfsHostPath()
    }

    private val mountResolver = MountResolver(mounts, AndroidSafDocumentIo(context))

    private val files = SandboxFileService(
        pathSemantics = PathSemantics {
            core.rootfs.rootfsHostPath()?.let { com.heracles.sandbox.file.HostPath.parse(it) }
        },
        zeroWidth = ZeroWidthFileChannel(),
        mountResolver = mountResolver,
    )

    /**
     * 沙箱逻辑核心。
     *
     * PRoot 二进制从 **nativeLibraryDir** 取（W^X 只允许那里 exec）。
     */
    private val core: SandboxServiceCore = SandboxServiceCore(
        dependencies = SandboxDependencies(
            // 沙箱内部事件目前不向 Dart 暴露；将来要展示“正在解包 rootfs”再接
            eventSink = com.heracles.sandbox.runtime.NoOpEventSink,
            pathResolver = object : com.heracles.sandbox.runtime.PathResolver {
                override fun sandboxToHost(sandboxPath: String): String =
                    core.rootfs.sandboxToHost(sandboxPath)

                override fun hostToSandbox(hostPath: String): String? =
                    core.rootfs.hostToSandbox(hostPath)

                override fun rootfsHostRoot(): String? = core.rootfs.rootfsHostPath()
            },
            // 沙箱只报通道可用性；**权限决策在 Heracles 控制面（Dart 门禁）**
            channelQuery = channelManager,
            fileAccess = { path, view -> files.read(path, view) },
        ),
        baseDir = baseDir,
        assets = context.assets,
        prootBinary = File(context.applicationInfo.nativeLibraryDir, "libproot.so"),
        loaderBinary = File(context.applicationInfo.nativeLibraryDir, "libproot-loader.so"),
        mountBindSource = mounts,
        commandRewriter = mountResolver,
    )

    private var outputChannel: MethodChannel? = null
    private var executionCounter = 0

    /**
     * **T2 编译环境**（≈415 MB）的激活器（2026-10-29）。
     *
     * 直接基于 `core` 构建 —— 本桥只持有 `SandboxServiceCore`，没有
     * `SandboxFacade`。与沙箱 demo 的 Facade 用的是**同一个**
     * `ToolchainActivation` 实现，行为一致。
     */
    private val toolchain: com.heracles.sandbox.runtime.ToolchainActivation by lazy {
        com.heracles.sandbox.runtime.ToolchainActivation(
            rootfsHostRoot = File(
                core.rootfs.rootfsHostPath() ?: File(baseDir, "rootfs").absolutePath,
            ),
            runInSandbox = { command, timeoutMs ->
                val out = StringBuilder()
                val err = StringBuilder()
                val res = runBlocking {
                    core.executeAndWait(
                        ExecutionRequest(
                            command = command,
                            workingDirectory = "/",
                            timeoutMillis = timeoutMs,
                        ),
                        object : com.heracles.sandbox.runtime.ExecutionSink {
                            override fun onOutput(stream: Int, chunk: String, sequence: Long) {
                                if (stream ==
                                    com.heracles.sandbox.runtime.ExecutionSink.STREAM_STDERR
                                ) {
                                    err.append(chunk)
                                } else {
                                    out.append(chunk)
                                }
                            }

                            override fun onProgress(percent: Int, message: String) = Unit
                            override fun onExit(result: ExecutionResult) = Unit
                            override fun onError(code: Int, message: String) = Unit
                            override fun isCancelled(): Boolean = false
                        },
                    )
                }
                com.heracles.sandbox.runtime.ToolchainActivation.CommandOutcome(
                    exitCode = res.exitCode,
                    stdout = out.toString().ifBlank { res.stdout },
                    stderr = err.toString().ifBlank { res.stderr },
                )
            },
        )
    }

    /** 生成一个新的流式任务 id（执行与 T2 激活共用同一命名空间，避免混淆）。 */
    private fun nextExecutionId(): String = "sbx-${++executionCounter}"

    /**
     * 推一帧进度到流式通道（T2 下载用）。
     *
     * Dart 侧按 `percent` + `message` 读（见 `SandboxOutputChunk`）。
     * `total <= 0` 时传 `percent = -1`（不确定进度）—— 界面应显示不确定态，
     * **不要**画一个假的百分比。
     */
    private fun emitProgress(id: String, done: Long, total: Long, stage: String) {
        val percent = if (total > 0) ((done * 100) / total).toInt() else -1
        val mb = { b: Long -> "%.1f".format(b / 1024.0 / 1024.0) }
        val message = if (total > 0) {
            "$stage ${mb(done)} / ${mb(total)} MB"
        } else {
            "$stage ${mb(done)} MB"
        }
        mainHandler.post {
            outputChannel?.invokeMethod(
                "progress",
                mapOf("id" to id, "percent" to percent, "message" to message),
            )
        }
    }

    init {
        // ★ rootfs 已经装过时（比如上次运行装好的），`activateRootfs()` 会提前返回，
        //   默认挂载点就永远不会注册 —— 真机上表现为 `@workspace` 报「未注册」。
        //   所以构造时补一次（幂等，register 允许同名覆盖）。
        if (runCatching { core.rootfs.status().installed }.getOrDefault(false)) {
            registerDefaultMounts()
            // ★ T1（aapt2/aidl/zipalign）同理（2026-10-29 真机抓到的 bug）：
            //   内置资产只在「rootfs 首次安装」那条路上解包，rootfs 已装过就跳过 ——
            //   真机现象是 `/opt/as: No such file or directory`、`aapt2: not found`。
            //   T1 是**每次启动都要保证**的东西，所以构造时补一次（幂等）。
            runCatching { core.ensureTooltools() }
        }
    }

    /** 挂到 Flutter 引擎上。 */
    fun register(engine: io.flutter.embedding.engine.FlutterEngine) {
        outputChannel = MethodChannel(engine.dartExecutor.binaryMessenger, OUTPUT_CHANNEL)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    /**
     * **仅 debug 的自检入口**（由 adb 显式触发，用户可见行为零变化）。
     *
     * ```
     * adb shell am start -n com.theohowie.heracles/.MainActivity --ez sandbox.selftest true
     * ```
     *
     * 结果全部写 logcat（tag `SandboxSelfTest`）。
     * 存在的理由：沙箱能力目前还没有 UI 入口（UI 归前端线），
     * 但没有真机证据就不能说「内置成功」。这是最小侵入的取证方式。
     * **release 构建里不会被触发**（调用方会判 BuildConfig.DEBUG）。
     */
    fun runSelfTest() {
        scope.launch {
            val tag = "SandboxSelfTest"
            fun log(msg: String) = android.util.Log.i(tag, msg)

            log("=== 沙箱自检开始 ===")
            log("proot: " + File(context.applicationInfo.nativeLibraryDir, "libproot.so").let {
                "${it.absolutePath} exists=${it.isFile} size=${if (it.isFile) it.length() else -1}"
            })
            log("loader: " + File(context.applicationInfo.nativeLibraryDir, "libproot-loader.so").let {
                "exists=${it.isFile} size=${if (it.isFile) it.length() else -1}"
            })
            log("status(before): " + rootfsSummary())

            // ① 激活（内置优先）
            val activated = withContext(Dispatchers.IO) {
                runCatching { activateRootfs(null) }.getOrDefault(false)
            }
            log("activate: ok=$activated  status(after)=" + rootfsSummary())
            if (!activated) {
                log("!! 激活失败，自检终止")
                return@launch
            }

            // ② 在 rootfs 内执行
            val r = withContext(Dispatchers.IO) {
                runCatching {
                    runBlocking {
                        core.executeAndWait(
                            ExecutionRequest(
                                command = "echo sandbox-ok; pwd; id -u; cat /etc/alpine-release 2>/dev/null",
                                workingDirectory = "/",
                                timeoutMillis = 60_000,
                            ),
                            object : com.heracles.sandbox.runtime.ExecutionSink {
                                override fun onOutput(stream: Int, chunk: String, sequence: Long) = Unit
                                override fun onProgress(percent: Int, message: String) = Unit
                                override fun onExit(result: ExecutionResult) = Unit
                                override fun onError(code: Int, message: String) = Unit
                                override fun isCancelled(): Boolean = false
                            },
                        )
                    }
                }.getOrNull()
            }
            if (r == null) {
                log("!! execute 抛异常")
            } else {
                log("execute exit=${r.exitCode} duration=${r.durationMillis}ms")
                log("stdout=[${r.stdout.trim()}]")
                log("stderr=[${r.stderr.trim()}]")
            }

            // ③ 命名挂载：写文件 → 命令内读取
            File(baseDir, "rootfs/opt/ws").mkdirs()
            val w = withContext(Dispatchers.IO) {
                files.write("@workspace/selftest.txt", "mount-ok".toByteArray(), PathView.HOST)
            }
            log("write @workspace/selftest.txt: ok=${w.success} err=${w.errorMessage}")
            val cat = withContext(Dispatchers.IO) {
                runCatching {
                    runBlocking {
                        core.executeAndWait(
                            ExecutionRequest(
                                command = "cat @workspace/selftest.txt",
                                workingDirectory = "/",
                                timeoutMillis = 60_000,
                            ),
                            object : com.heracles.sandbox.runtime.ExecutionSink {
                                override fun onOutput(stream: Int, chunk: String, sequence: Long) = Unit
                                override fun onProgress(percent: Int, message: String) = Unit
                                override fun onExit(result: ExecutionResult) = Unit
                                override fun onError(code: Int, message: String) = Unit
                                override fun isCancelled(): Boolean = false
                            },
                        )
                    }
                }.getOrNull()
            }
            log("cat @workspace/selftest.txt: exit=${cat?.exitCode} stdout=[${cat?.stdout?.trim()}]")

            // ④ 通道（沙箱只报可用性，不做权限决策）
            log("channels: " + channelsMaps().joinToString { "${it["name"]}=${it["available"]}/risk${it["risk"]}" })
            log("=== 沙箱自检结束 ===")
        }
    }

    // ---------------------------------------------------------------- 分发

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            dispatch(call, result)
        } catch (e: Throwable) {
            reply(result, failure("沙箱桥内部错误：${e.javaClass.simpleName}: ${e.message}"))
        }
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> scope.launch { reply(result, statusMap()) }

            "activate" -> {
                val ociRef = call.argument<String>("ociRef")
                scope.launch {
                    val ok = withContext(Dispatchers.IO) { activateRootfs(ociRef) }
                    reply(result, mapOf("ok" to ok) + statusMap())
                }
            }

            "execute" -> {
                val command = call.argument<String>("command")
                    ?: return reply(result, failure("execute 缺少参数 command"))
                val workdir = call.argument<String>("workdir") ?: "/workspace"
                val timeoutMs = (call.argument<Number>("timeoutMs"))?.toLong() ?: 120_000L
                val usePty = call.argument<Boolean>("usePty") ?: false
                executeAsync(command, workdir, timeoutMs, usePty, result)
            }

            "readFile" -> {
                val path = call.argument<String>("path")
                    ?: return reply(result, failure("readFile 缺少参数 path"))
                scope.launch {
                    val r = withContext(Dispatchers.IO) { files.read(path, PathView.HOST) }
                    reply(result, fileResultMap(r))
                }
            }

            "writeFile" -> {
                val path = call.argument<String>("path")
                    ?: return reply(result, failure("writeFile 缺少参数 path"))
                val text = call.argument<String>("text")
                    ?: return reply(result, failure("writeFile 缺少参数 text"))
                scope.launch {
                    val r = withContext(Dispatchers.IO) {
                        files.write(path, text.toByteArray(Charsets.UTF_8), PathView.HOST)
                    }
                    reply(result, fileResultMap(r))
                }
            }

            "registerMount" -> {
                val name = call.argument<String>("name")
                    ?: return reply(result, failure("registerMount 缺少参数 name"))
                val backendWire = call.argument<Number>("backend")?.toInt() ?: 0
                val backend = MountBackend.fromWire(backendWire)
                    ?: return reply(result, failure("未知 backend=$backendWire"))
                val entry = MountEntry(
                    name = name,
                    backend = backend,
                    hostPath = call.argument<String>("hostPath") ?: "",
                    treeUri = call.argument<String>("treeUri") ?: "",
                    readOnly = call.argument<Boolean>("readOnly") ?: false,
                    bindTo = call.argument<String>("bindTo") ?: "",
                    description = call.argument<String>("description") ?: "",
                )
                scope.launch {
                    reply(result, runCatching { mounts.register(entry) }
                        .fold(
                            onSuccess = { mapOf("ok" to true) },
                            onFailure = { e -> failure((e as? SandboxException)?.message ?: e.message.orEmpty()) },
                        ))
                }
            }

            "listMounts" -> scope.launch {
                reply(result, mapOf("ok" to true, "mounts" to mounts.list().map { m ->
                    mapOf(
                        "name" to m.name,
                        "backend" to m.backend.wireValue,
                        "readOnly" to m.readOnly,
                        "bindTo" to m.bindTo,
                        "description" to m.description,
                    )
                }))
            }

            "queryChannels" -> scope.launch { reply(result, mapOf("ok" to true, "channels" to channelsMaps())) }

            // ---- 重置 / 快照（设置页「重置沙箱」用）----
            // reset 的语义见 sandbox 的 RootfsManager：name 为空 = 清空重装；
            // 给了名字 = 回滚到该快照。**它是破坏性操作**，UI 必须二次确认。
            "reset" -> {
                val snapshot = call.argument<String>("snapshot") ?: ""
                scope.launch {
                    val r = withContext(Dispatchers.IO) {
                        runCatching { runBlocking { core.resetRootfs(snapshot) } }
                    }
                    reply(result, r.fold(
                        onSuccess = { st ->
                            // 重置后原来的挂载点会失效（rootfs 目录被换掉），补注册一次
                            registerDefaultMounts()
                            mapOf(
                                "ok" to true,
                                "installed" to st.installed,
                                "rootfsSummary" to rootfsSummary(),
                                // ★ 必须带上：Dart 侧 `_statusFrom` 用 installed && prootReady
                                //   判「就绪」，少了它重置后会被误判成未就绪
                                //   （2026-10-29 单测抓到）。
                                "prootReady" to File(
                                    context.applicationInfo.nativeLibraryDir,
                                    "libproot.so",
                                ).isFile,
                                "channels" to channelsMaps(),
                            )
                        },
                        onFailure = { e -> failure(e.message ?: e.javaClass.simpleName) },
                    ))
                }
            }

            "snapshot" -> {
                val name = call.argument<String>("name") ?: ""
                if (name.isBlank()) return reply(result, failure("snapshot 需要 name"))
                scope.launch {
                    val r = withContext(Dispatchers.IO) {
                        runCatching { runBlocking { core.snapshotRootfs(name) } }
                    }
                    reply(result, r.fold(
                        onSuccess = { st ->
                            mapOf(
                                "ok" to true,
                                "snapshotName" to st.snapshotName,
                                "snapshotCount" to st.snapshotCount,
                            )
                        },
                        onFailure = { e -> failure(e.message ?: e.javaClass.simpleName) },
                    ))
                }
            }

            // ---- T2 编译环境（≈415 MB，用户主动激活）—— 2026-10-29 ----
            //
            // ⚠️ 这三条**不在 AIDL 契约里**：沙箱的 AIDL 只允许新增
            //    registerMount / listMounts（用户 2026-10-28 裁定）。
            //    这里是 Heracles 自己的桥，通过 Kotlin 直调 `SandboxFacade` 完成，
            //    Dart 侧只负责「触发 + 收进度」。
            "buildSuiteStatus" -> scope.launch {
                val st = withContext(Dispatchers.IO) {
                    runCatching { toolchain.status() }
                }
                // ★ 自愈（2026-10-29）：T2 就绪但 PATH 里没有 gradle 时补一次链接。
                //   老用户是在"PATH 链接"这一步存在之前装的 T2 —— 他们不会再点一次
                //   安装，所以必须在这里补，否则 `gradle` 永远 not found。
                //   `ln -sf` 幂等，且只在就绪时才跑，代价可忽略。
                if (st.getOrNull()?.ready == true) {
                    withContext(Dispatchers.IO) {
                        runCatching { toolchain.repairPath() }
                    }
                }
                reply(result, st.fold(
                    onSuccess = { s ->
                        mapOf(
                            "ok" to true,
                            "ready" to s.ready,
                            "version" to s.version,
                            "installDir" to s.installDir,
                            "parts" to s.parts,
                        )
                    },
                    onFailure = { e -> failure(e.message ?: e.javaClass.simpleName) },
                ))
            }

            "activateBuildSuite" -> {
                // 进度推到流式通道，UI 才能画进度条（415 MB 不能干等）
                val progressId = nextExecutionId()
                scope.launch {
                    val r = withContext(Dispatchers.IO) {
                        runCatching {
                            toolchain.activate { done, total, stage ->
                                emitProgress(progressId, done, total, stage)
                            }
                        }
                    }
                    reply(result, r.fold(
                        onSuccess = { a ->
                            mapOf(
                                "ok" to a.success,
                                "message" to a.message,
                                "alreadyReady" to a.alreadyReady,
                                "ready" to (a.status?.ready ?: false),
                                "parts" to (a.status?.parts ?: emptyMap<String, Boolean>()),
                            )
                        },
                        onFailure = { e -> failure(e.message ?: e.javaClass.simpleName) },
                    ))
                }
            }

            "resetBuildSuite" -> scope.launch {
                val r = withContext(Dispatchers.IO) { runCatching { toolchain.reset() } }
                reply(result, r.fold(
                    onSuccess = { ok -> mapOf("ok" to true, "cleared" to ok) },
                    onFailure = { e -> failure(e.message ?: e.javaClass.simpleName) },
                ))
            }

            else -> reply(result, failure("未知方法：${call.method}"))
        }
    }

    // ---------------------------------------------------------------- 实现

    /**
     * 激活沙箱：**内置 rootfs 优先（离线），OCI 兜底（要网）**。
     *
     * 这就是「一步初始化」里的那一半 —— 装环境，不涉及签名/打包。
     */
    private fun activateRootfs(ociRef: String?): Boolean {
        if (core.rootfs.status().installed) return true

        val bundled = runCatching { runBlocking { core.rootfs.useBundledRootfs() } }.getOrNull()
        if (bundled?.isInstalled == true) {
            registerDefaultMounts()
            return true
        }
        if (ociRef.isNullOrBlank()) return false
        return runCatching {
            runBlocking { core.rootfs.installOci(ociRef) }
            val ok = core.rootfs.status().installed
            if (ok) registerDefaultMounts()
            ok
        }.getOrDefault(false)
    }

    /**
     * 注册默认挂载点。
     *
     * ⚠️ `@workspace` 的 hostPath 用 `opt/ws` 而不是 `workspace`：
     * guest 的 `/workspace` 是 bind 挂载（宿主 workspaces 目录），
     * 用它会**盖住** rootfs 内的同名目录，命令里会读到另一个目录。
     */
    private fun registerDefaultMounts() {
        runCatching {
            mounts.register(
                MountEntry(
                    name = "workspace",
                    backend = MountBackend.ROOTFS_RELATIVE,
                    hostPath = "opt/ws",
                    description = "沙箱工作区（读写）",
                ),
            )
            File(baseDir, "rootfs/opt/ws").mkdirs()
        }
    }

    private fun executeAsync(
        command: String,
        workdir: String,
        timeoutMs: Long,
        usePty: Boolean,
        result: MethodChannel.Result,
    ) {
        val id = nextExecutionId()
        // 立即回一个 id，真正的结果走 output 通道 + 最后的 done 通知
        reply(result, mapOf("ok" to true, "id" to id))

        val request = ExecutionRequest(
            command = command,
            workingDirectory = workdir,
            timeoutMillis = timeoutMs,
            usePty = usePty,
        )
        scope.launch {
            try {
                runBlocking {
                    core.executeAndWait(request, object : com.heracles.sandbox.runtime.ExecutionSink {
                        override fun onOutput(stream: Int, chunk: String, sequence: Long) {
                            mainHandler.post {
                                outputChannel?.invokeMethod(
                                    "output",
                                    mapOf("id" to id, "stream" to stream, "chunk" to chunk),
                                )
                            }
                        }

                        override fun onProgress(percent: Int, message: String) {
                            mainHandler.post {
                                outputChannel?.invokeMethod(
                                    "progress",
                                    mapOf("id" to id, "percent" to percent, "message" to message),
                                )
                            }
                        }

                        override fun onExit(result: ExecutionResult) = Unit

                        override fun onError(code: Int, message: String) {
                            mainHandler.post {
                                outputChannel?.invokeMethod(
                                    "error",
                                    mapOf("id" to id, "code" to code, "message" to message),
                                )
                            }
                        }

                        override fun isCancelled(): Boolean = false
                    })
                }.let { r ->
                    mainHandler.post {
                        outputChannel?.invokeMethod("done", mapOf("id" to id, "result" to executionMap(r)))
                    }
                }
            } catch (e: SandboxException) {
                mainHandler.post {
                    outputChannel?.invokeMethod(
                        "error",
                        mapOf("id" to id, "code" to e.code, "message" to e.message.orEmpty()),
                    )
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    outputChannel?.invokeMethod(
                        "error",
                        mapOf("id" to id, "code" to SandboxException.CODE_INTERNAL,
                            "message" to "${e.javaClass.simpleName}: ${e.message}"),
                    )
                }
            }
        }
    }

    private fun statusMap(): Map<String, Any?> {
        val status = runCatching { core.rootfs.status() }.getOrNull()
        return mapOf(
            "ok" to true,
            "installed" to (status?.installed ?: false),
            "rootfsSummary" to rootfsSummary(),
            "prootReady" to (File(context.applicationInfo.nativeLibraryDir, "libproot.so").isFile),
            "channels" to channelsMaps(),
        )
    }

    private fun channelsMaps(): List<Map<String, Any?>> = runCatching {
        core.queryChannels().map { c: ChannelInfo ->
            mapOf(
                "type" to c.type,
                "name" to c.displayName,
                "available" to c.available,
                "reason" to c.unavailableReason,
                "risk" to c.riskLevel,
            )
        }
    }.getOrDefault(emptyList())

    private fun executionMap(r: ExecutionResult): Map<String, Any?> = mapOf(
        "exitCode" to r.exitCode,
        "stdout" to r.stdout,
        "stderr" to r.stderr,
        "durationMs" to r.durationMillis,
        "timedOut" to r.timedOut,
        "cancelled" to r.cancelled,
        "truncated" to r.truncated,
    )

    private fun fileResultMap(r: com.heracles.sandbox.api.FileResult): Map<String, Any?> = mapOf(
        "ok" to r.success,
        "text" to if (r.success) r.asText() else null,
        "size" to r.size,
        "errorCode" to r.errorCode,
        "error" to r.errorMessage,
    )

    // ---------------------------------------------------------------- 工具

    private fun reply(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { runCatching { result.success(value) } }
    }

    private fun failure(reason: String): Map<String, Any?> =
        mapOf("ok" to false, "error" to reason)


    companion object {
        const val CHANNEL = "heracles/sandbox"
        const val OUTPUT_CHANNEL = "heracles/sandbox/output"

        /** 沙箱数据根目录名（与 `sandbox-runtime` 的约定一致）。 */
        private const val BASE_DIR_NAME = "sandbox"
    }
}
