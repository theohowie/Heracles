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

import android.content.Context
import com.heracles.sandbox.api.ChannelInfo
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.RootfsStatus
import com.heracles.sandbox.channel.ChannelManager
import com.heracles.sandbox.file.HostPath
import com.heracles.sandbox.file.PathSemantics
import com.heracles.sandbox.file.SandboxFileService
import com.heracles.sandbox.file.ZeroWidthFileChannel
import com.heracles.sandbox.runtime.AidlExecutionSink
import com.heracles.sandbox.runtime.EventSink
import com.heracles.sandbox.runtime.ProotEngine
import com.heracles.sandbox.runtime.RootfsManager
import com.heracles.sandbox.runtime.SandboxDependencies
import com.heracles.sandbox.runtime.SandboxServiceCore
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * demo 的「一次装配好四个模块」的单点 —— **进程内形态**。
 *
 * 为什么要有这个类：`MainActivity` 是 UI，`ExecuteDemo` / `FileDemo` /
 * `ChannelDemo` 各自只演示一件事；把**装配**集中到一处，
 * 一方面 demo 好读，另一方面这正是宿主集成时要抄的那段代码
 * （见 `docs/integration-guide.md` §2）。
 *
 * ============================================================================
 * ★ 2026-10-27 的关键修复：执行改走 SandboxServiceCore，不再直通 ProotEngine
 * ============================================================================
 * 旧实现（已删除）在 [execute] 里直接调 `engine.executePty / executePiped`。
 * 那样跑出来的命令**三条保障全都没有**：
 *
 *   1. **没有并发准入** —— 前台命令想开多少开多少。真机上「连点 8 次」就会起
 *      8 个 PRoot，手机直接卡死；契约要求的 `CODE_BUSY` 永远不会出现。
 *   2. **没有持久进程登记** —— 长跑命令不在任何账本里，宿主无从列出/逐个停掉。
 *   3. **没有 shutdown 整树回收** —— `onDestroy` 时无人调 `stopAll()`，
 *      PRoot 的 tracee 会被 reparent 到 init 永久存活（这是本项目最贵的坑之一，
 *      见 `ProcessRegistry` 的文件头）。
 *
 * 现在 [execute] 只做一件事：把 AIDL 形状的 [IExecutionCallback] 适配成
 * runtime 的 [AidlExecutionSink] 再交给 [SandboxServiceCore.execute]。
 * 也就是说 —— **进程内形态与跨进程形态现在走的是同一段逻辑**，区别只剩
 * 「调用是函数调用还是 binder 事务」。这正是本修复最大的收益：
 * 两者行为不再可能分叉。
 *
 * ============================================================================
 * 为什么进程内形态仍然保留（而不是让 demo 全走 AIDL）
 * ============================================================================
 * 任务书要求 demo 能在 5 分钟内跑通。走 AIDL 要多写一个 Service + Stub +
 * ServiceConnection + 跨进程序列化，任一处写错都跑不通，且报错信息会被
 * binder 吞掉一层。所以主界面（①②③④）走进程内，**AIDL 的完整用法另外
 * 在 [AidlClientDemo] 里给出可运行的跨进程版本**（⑤ 按钮）。
 *
 * 这同时证明了一件更重要的事：**沙箱可以当库用**，不只可以当 Service 用。
 *
 * @param context 任意 Context（内部只留 `applicationContext`）
 */
class SandboxFacade(context: Context) {

    private val appContext = context.applicationContext

    /** 沙箱所有运行时文件都放这里（宿主视角）。 */
    val baseDir: File = File(appContext.filesDir, BASE_DIR_NAME).apply { mkdirs() }

    /** 四通道探测。 */
    val channels: ChannelManager = ChannelManager(context = appContext)

    /** 进程内形态用的事件出口：logcat（与 `:sandbox` 进程里的 [LogcatEventSink] 同款）。 */
    private val eventSink: EventSink = LogcatEventSink

    /**
     * PRoot 二进制（proot + 可选 loader）。
     *
     * **只取一次**：分开调两次 `prepareProotBinary()` 有可能拿到不成对的结果
     * （热插拔 / 安装器正在解包时），而 proot 与 loader 版本必须匹配。
     */
    private val prootBinaries: Pair<File, File?> = prepareProotBinary()

    /**
     * 命名挂载注册表（`@name` → 物理/SAF）。
     *
     * rootfs 根目录用**委托**取（`core.rootfs` 是唯一权威），
     * 避免出现两份状态导致「装好了但解析说没装」。
     */
    val mounts: com.heracles.sandbox.file.MountRegistry =
        com.heracles.sandbox.file.MountRegistry { core.rootfs.rootfsHostPath() }

    /** SAF 实现（`@name` 指向用户授权目录时用）。 */
    private val safIo: com.heracles.sandbox.file.SafDocumentIo = com.heracles.sandbox.file.AndroidSafDocumentIo(appContext)

    /** 命名挂载解析器：`@name/...` → 物理路径 / SAF 文档。 */
    val mountResolver: com.heracles.sandbox.file.MountResolver =
        com.heracles.sandbox.file.MountResolver(mounts, safIo)

    /** 文件读写（含零宽通道 + 命名挂载）。rootfs 未就绪时也能用 HOST 视角。 */
    val files: SandboxFileService = SandboxFileService(
        pathSemantics = PathSemantics {
            core.rootfs.rootfsHostPath()?.let { HostPath.parse(it) }
        },
        zeroWidth = ZeroWidthFileChannel(),
        mountResolver = mountResolver,
    )

    /**
     * core 侧需要的 [com.heracles.sandbox.runtime.PathResolver]。
     *
     * 用**委托**（而不是自己新建一个 `RootfsManager`）持有，是为了和 core 共享
     * 同一份 `activeRootfs` 状态：两份状态会让「装好了但 execute 说没装」这种
     * bug 出现，而且两个对象自己都「没错」，极难排查。
     */
    private val corePaths: com.heracles.sandbox.runtime.PathResolver =
        object : com.heracles.sandbox.runtime.PathResolver {
            override fun sandboxToHost(sandboxPath: String): String =
                rootfsDelegate().sandboxToHost(sandboxPath)

            override fun hostToSandbox(hostPath: String): String? =
                rootfsDelegate().hostToSandbox(hostPath)

            override fun rootfsHostRoot(): String? = rootfsDelegate().rootfsHostPath()

            private fun rootfsDelegate(): RootfsManager = core.rootfs
        }

    /**
     * 逻辑核心 —— **本类的一切执行/rootfs 操作都经由它**。
     *
     * 构造期不需要 rootfs 已安装（`RootfsManager` 会在自己 init 里探测一次），
     * 所以这里可以直接建；PRoot 二进制缺失也不会抛，由 [isProotReady] /
     * [SandboxServiceCore.diagnose] 如实报告。
     */
    val core: SandboxServiceCore = SandboxServiceCore(
        dependencies = SandboxDependencies(
            eventSink = eventSink,
            pathResolver = corePaths,
            channelQuery = channels,
            fileAccess = { path, view ->
                // core 只在 HOST 视角回调这里（见 SandboxServiceCore.readFile）；
                // 委托给 files 是为了拿到零宽通道与 400 KB 单次读上限。
                files.read(path, view)
            },
        ),
        baseDir = baseDir,
        assets = appContext.assets,
        prootBinary = prootBinaries.first,
        loaderBinary = prootBinaries.second,
        // 命名挂载层：执行引擎从这里拿 bind 列表，命令串从这里改写 @name
        mountBindSource = mounts,
        commandRewriter = mountResolver,
    )

    /**
     * rootfs / 快照 / 安装标记的统一管理者，同时实现 `PathResolver`。
     *
     * ★ **就是 core 内部那一个**，不是新建的副本 —— 理由见 [corePaths]。
     * 这是 [SandboxServiceCore] 暴露 `rootfs` 属性的意义。
     */
    val rootfs: RootfsManager = core.rootfs

    /**
     * PRoot 执行核心的**只读视图** —— 仅供 [isProotReady] 的二进制/rootfs 体检。
     *
     * ⚠️ **不要再用它执行命令**：`engine.executePty/executePiped` 是直通路径，
     * 没有并发准入、没有进程账本、没有关闭时的整树回收。执行一律走 [execute]
     * → [SandboxServiceCore]。保留这个属性是为了 `docs/integration-guide.md` §2.2
     * 里那段装配说明仍然成立（宿主抄装配时确实要建 ProotEngine），
     * 也为了兼容 [ExecuteDemo] 等既有调用方。
     */
    val engine: ProotEngine? by lazy { buildEngineOrNull() }

    /** 供 UI 显示的一句话状态。 */
    fun rootfsSummary(): String {
        val st: RootfsStatus = rootfs.status()
        return if (!st.installed) {
            "rootfs: 未安装"
        } else {
            "rootfs: ${st.label.ifBlank { "unknown" }} " +
                "(source=${st.source}, ${st.sizeBytes} B, snapshots=${st.snapshotCount})"
        }
    }

    /** PRoot 是否可用（二进制齐全 + rootfs 已装）。 */
    fun isProotReady(): Boolean = engine?.let { it.isProotUsable() && it.isRootfsUsable() } ?: false

    /**
     * 确保 rootfs 可用：**先内置（离线），失败再 OCI**。
     *
     * 这就是 Heracles 初始化流程里的「激活沙箱」那一步 ——
     * 只是把环境装好，不涉及任何打包 / 签名。
     *
     * @return true = rootfs 已就绪
     */
    suspend fun ensureRootfs(ociFallback: String = DEFAULT_OCI_REF): Boolean {
        if (rootfs.status().installed) return true

        // ① 内置（离线，主路径）
        val bundled = runCatching { rootfs.useBundledRootfs() }.getOrNull()
        if (bundled?.isInstalled == true) return true

        // ② OCI（可选升级；要联网）
        return runCatching {
            rootfs.installOci(ociFallback)
            rootfs.status().installed
        }.getOrDefault(false)
    }

    /**
     * rootfs 在**宿主视角**的根目录；未安装时为 null。
     *
     * 构建套件要往 `<rootfs>/opt/...` 里装东西，所以需要暴露这个路径。
     */
    fun rootfsHostRoot(): File? = rootfs.rootfsHostPath()?.let { File(it) }

    // ========================================================================
    // T2 编译环境激活（≈415 MB，用户主动触发）—— 2026-10-29
    // ========================================================================
    //
    // ⚠️ 走 **Kotlin 直调**，不加 AIDL 方法 —— AIDL 契约只允许新增
    //    `registerMount` / `listMounts`（用户 2026-10-28 裁定）。
    //
    // 为什么下载不做在 Dart 侧：415 MB 走 MethodChannel 传字节是灾难。
    // 下载/校验/解压必须在原生侧，Dart 只负责「触发 + 收进度」。

    private val toolchain: com.heracles.sandbox.runtime.ToolchainActivation by lazy {
        com.heracles.sandbox.runtime.ToolchainActivation(
            rootfsHostRoot = rootfsHostRoot() ?: File(baseDir, "rootfs"),
            runInSandbox = { command, timeoutMs ->
                // 走与普通 execute 同一条链路（PRoot + rootfs），只是不流式回传，
                // 只把输出攒起来给调用方做诊断。
                val out = StringBuilder()
                val err = StringBuilder()
                val res = core.executeAndWait(
                    com.heracles.sandbox.api.ExecutionRequest(
                        command = command,
                        workingDirectory = "/",
                        timeoutMillis = timeoutMs,
                    ),
                    object : com.heracles.sandbox.runtime.ExecutionSink {
                        override fun onOutput(stream: Int, chunk: String, sequence: Long) {
                            if (stream == com.heracles.sandbox.runtime.ExecutionSink.STREAM_STDERR) {
                                err.append(chunk)
                            } else {
                                out.append(chunk)
                            }
                        }

                        override fun onProgress(percent: Int, message: String) = Unit
                        override fun onExit(result: com.heracles.sandbox.api.ExecutionResult) = Unit
                        override fun onError(code: Int, message: String) = Unit
                        override fun isCancelled(): Boolean = false
                    },
                )
                com.heracles.sandbox.runtime.ToolchainActivation.CommandOutcome(
                    exitCode = res.exitCode,
                    stdout = out.toString().ifBlank { res.stdout },
                    stderr = err.toString().ifBlank { res.stderr },
                )
            },
        )
    }

    /** T2 当前状态（**只读**，不触发下载）。 */
    fun buildSuiteStatus(): com.heracles.sandbox.runtime.ToolchainActivation.ToolchainStatus =
        toolchain.status()

    /**
     * 激活 T2 编译环境（幂等 + 单飞 + 断点续传 + 磁盘预检）。
     *
     * @param onProgress `(已下载, 总字节, 阶段)`；总字节未知为 -1
     */
    suspend fun activateBuildSuite(
        onProgress: (Long, Long, String) -> Unit = { _, _, _ -> },
    ): com.heracles.sandbox.runtime.ToolchainActivation.ActivationResult =
        toolchain.activate(onProgress)

    /**
     * 卸载 T2（T2-6）：**真卸载** —— 删 `/opt/t2` + JDK（`apk del` 优先）+ gradle 的 PATH 链接，
     * 返回删除清单 / 失败项 / 释放字节 / 当前缺失项。只动 T2，不碰 T0/T1 与用户工作区。
     */
    suspend fun resetBuildSuite(): com.heracles.sandbox.runtime.ToolchainActivation.ToolchainResetResult =
        toolchain.reset()


    /** 二进制缺失时给人看的说明。 */
    fun prootMissingHint(): String = buildString {
        appendLine("PRoot 二进制缺失。沙箱不含 proot/loader 二进制（上游产物，体积大），需要先准备：")
        appendLine("  bash tools/fetch-proot.sh          # 从 Termux proot 包取")
        appendLine("或把已有的 proot 放到：")
        appendLine("  ${File(baseDir, "bin").absolutePath}/proot")
        appendLine("  ${File(baseDir, "bin").absolutePath}/proot-loader.so")
        append("\n★ 没有 proot 时：文件读写（HOST 视角）、通道查询仍然可用，只有 execute 不可用。")
    }

    // ------------------------------------------------------------------
    // 执行：把 suspend 的 core 调用包成回调式，匹配 AIDL 的形状
    // ------------------------------------------------------------------

    /**
     * 与 `ISandboxService.execute` **同形**的进程内实现。
     *
     * 现在是**真·同一条路径**：回调经 [AidlExecutionSink] 适配后交给
     * [SandboxServiceCore.execute]，因此并发上限（超出 `CODE_BUSY`）、
     * 进程登记、关闭时的整树回收全都生效。
     *
     * @param scope **已废弃，保留只为源码兼容**。core 自带 `SupervisorJob + IO`
     *              作用域（[SandboxServiceCore.execute] 返回 `Job`），宿主传入的
     *              scope 不再被使用 —— 进程内形态与跨进程形态必须用同一套调度，
     *              否则「谁在什么线程上跑」又会分叉。
     */
    fun execute(
        request: ExecutionRequest,
        callback: IExecutionCallback,
        @Suppress("UNUSED_PARAMETER") scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    ) {
        core.execute(request, AidlExecutionSink(callback))
    }

    /** 主线程安全的通道列表（探测可能起进程，调用方应在后台线程调）。 */
    fun queryChannels(): List<ChannelInfo> = core.queryChannels()

    /** 路径语义：宿主视角 → 沙箱视角。 */
    fun hostToSandbox(hostPath: String): String? = rootfs.hostToSandbox(hostPath)

    /** 路径语义：沙箱视角 → 宿主视角。 */
    fun sandboxToHost(sandboxPath: String): String = rootfs.sandboxToHost(sandboxPath)

    // ------------------------------------------------------------------

    /**
     * 定位 PRoot 二进制（成对返回：proot + 可选 loader）。
     *
     * ============================================================================
     * 真机踩坑记录：Android 10+ 的 W^X 禁止从 App data 目录 exec
     * ============================================================================
     * **第一次实现是错的**：把 `nativeLibraryDir/libproot.so` **复制**到
     * `files/sandbox/bin/proot` 再 exec，真机上报：
     *
     * ```
     * Cannot run program ".../files/sandbox/bin/proot": error=13, Permission denied
     * ```
     *
     * `ls -la` 看得到 `-rwx------`，`run-as` 也能读 —— 但 **exec 仍然 EACCES**。
     * 原因：Android 10（API 29）起对 app 私有 data 分区施加 W^X 限制，
     * `untrusted_app` 域**不允许从 data 目录执行**（即便 chmod +x）。
     *
     * 正确做法：**直接 exec `nativeLibraryDir` 里的文件** ——
     * 那是 `/data/app/.../lib/arm64/`，被系统标记为可执行，且
     * `installer` 域属主，`untrusted_app` 有 r-x 权限。
     *
     * 所以本方法**返回 nativeLibraryDir 的路径本身，不做复制**。
     * 只有「宿主自己往 files/bin 放了 proot」这一条仍走 files（那种情况
     * 通常意味着宿主用了别的注入手段，由宿主自行保证可执行）。
     *
     * 查找顺序：
     *   1. `files/sandbox/bin/proot`            —— 宿主自备（可能不可 exec，见上）
     *   2. `nativeLibraryDir/libproot.so`       —— **推荐**：jniLibs 打包，系统保证可 exec
     *
     * 注意「找不到」时的返回：给一个**不存在的** `File` 而不是抛异常 ——
     * core 的 `diagnose()` / `isProotUsable()` 需要一个可判定的假值，
     * 构造期抛异常会让 demo 连诊断信息都显示不出来。
     */
    private fun prepareProotBinary(): Pair<File, File?> {
        val nativeDir = File(appContext.applicationInfo.nativeLibraryDir)

        // 1) 宿主自备（放 files/bin）—— 保留这条是因为某些宿主会用
        //    split APK / 动态 feature 注入，路径不在 nativeLibraryDir。
        val binDir = File(baseDir, "bin")
        val preplaced = File(binDir, "proot")
        if (preplaced.isFile && preplaced.length() > MIN_BINARY_BYTES) {
            val loader = File(binDir, "proot-loader.so").takeIf { it.isFile && it.length() > 0 }
            return preplaced to loader
        }

        // 2) nativeLibraryDir —— 直接从那儿 exec，**不复制**
        val fromLib = File(nativeDir, PROOT_NAME)
        if (fromLib.isFile && fromLib.length() > MIN_BINARY_BYTES) {
            val loader = File(nativeDir, PROOT_LOADER_NAME).takeIf { it.isFile && it.length() > 0 }
            return fromLib to loader
        }

        // 3) 都没有：返回「不存在的路径」，让 diagnose() 如实报告，而不是构造期崩溃
        return File(nativeDir, PROOT_NAME) to null
    }

    /**
     * 建 [ProotEngine]（**只用于体检/诊断**，不用于执行 —— 见 [engine] 的警告）。
     *
     * 返回 null 的条件与旧实现一致：rootfs 未安装时拿不到 `rootfsHostRoot`。
     */
    private fun buildEngineOrNull(): ProotEngine? {
        val (proot, loader) = prepareProotBinary()
        if (!proot.isFile || proot.length() <= MIN_BINARY_BYTES) return null
        val rootfsHost = core.rootfs.rootfsHostPath()?.let { File(it) } ?: return null

        return ProotEngine(
            prootBinary = proot,
            loaderBinary = loader,
            rootfsHostRoot = rootfsHost,
            workspaceHostRoot = File(rootfsHost, "workspace").apply { mkdirs() },
            homeHostRoot = File(rootfsHost, "root").apply { mkdirs() },
            tmpHostRoot = File(rootfsHost, "tmp").apply { mkdirs() },
            attachmentsHostRoot = File(appContext.filesDir, "attachments").apply { mkdirs() },
            eventSink = eventSink,
        )
    }

    companion object {
        /** 演示用的 `pathView` 常量，避免 demo 里散落魔法数字。 */
        val HOST: Int = PathView.HOST.wireValue
        val SANDBOX: Int = PathView.SANDBOX.wireValue

        /** 沙箱数据根目录名（与 `SandboxHostAssembly`、`RootfsManager` 同一约定）。 */
        private const val BASE_DIR_NAME = RootfsManager.DEFAULT_BASE_DIR_NAME

        /** jniLibs 里的 PRoot 文件名（见 `docs/integration-guide.md` §4）。 */
        private const val PROOT_NAME = "libproot.so"
        private const val PROOT_LOADER_NAME = "libproot-loader.so"

        /** PRoot 二进制的最小合理体积（低于这个值一定是没下全/被 strip 坏了）。 */
        private const val MIN_BINARY_BYTES = 100_000L

        /**
         * OCI 兜底镜像（只在内置 rootfs 不可用时才用，需联网）。
         * Alpine 约 4 MB，够跑基本命令。
         */
        const val DEFAULT_OCI_REF = "docker.io/library/alpine:3.20"
    }
}
