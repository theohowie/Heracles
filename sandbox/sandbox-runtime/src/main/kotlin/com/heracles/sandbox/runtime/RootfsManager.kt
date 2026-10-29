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
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/RootfsInstaller.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/LinuxEnvironmentManager.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/RuntimePathManager.kt
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * rootfs 的**双策略统一入口**（这是本项目相对 taixu 的核心架构选择）：
 *
 *   - **OCI 策略**：有网 + 需要完整工具链 ⇒ 从 registry 拉 alpine/debian/ubuntu
 *     （[OciRootfsInstaller]）
 *   - **内置策略**：没网 / 快速启动 ⇒ 用 APK assets 里的 minimal rootfs
 *     （[BundledRootfs]）
 *
 * 两条策略装出来的东西**落在同一个位置**（[rootfsDir]），所以上层的
 * [ProotEngine] 不需要知道是哪种来的。差异只体现在 [RootfsStatus.source]。
 *
 * 另外本类是 [PathResolver] 的**默认实现**：因为「rootfs 在哪」这个问题
 * 只有它知道（安装/重置/回滚都会改变答案），所以路径换算读的是它的
 * volatile 字段，而不是某个构造期快照。
 *
 * ============================================================================
 * 与上游 taixu 的差异（逐条，重点是删掉的多发行版矩阵）
 * ============================================================================
 * 1. **不做多发行版**（上游 `distros/<id>/rootfs` 支持 ubuntu/alpine/debian 并存）。
 *    沙箱只需要**一个**活动 rootfs：`{base}/rootfs`。理由：
 *    - 多发行版并存是**控制面**需求（用户选哪个系统），沙箱只负责「执行」；
 *    - 两套 rootfs 会让 PathResolver 的答案依赖「当前是哪个 distro」，
 *      而 PathResolver 是**无参**接口（见 SandboxDependencies.kt）——
 *      接口签名本身就说明了一个活动 rootfs 的设计。
 *    需要多环境时宿主换 rootfs 目录即可（本类的 [rootfsDir] 可配置）。
 * 2. **不移植 `checkForUpdate()` / `updateOci()` / `finalizePendingUpdate()` /
 *    `rollbackPendingUpdate()`**（增量更新事务）。
 *    沙箱的更新语义是「重装」：装到 staging → 校验 → 原子替换。
 *    失败时旧 rootfs **原样保留**（[OciRootfsInstaller.replaceTarget] 已实现），
 *    所以不需要一套独立的事务状态机。SNAPSHOT 机制（[snapshotRootfs]）覆盖了
 *    「升级前存档」的需求。
 * 3. **不移植 `uninstallDistro()`**（多发行版删除）。等价能力是 [resetRootfs]。
 * 4. **不移植 lxc-images 回退线路**（见 OciRootfsInstaller 的删减说明）。
 * 5. **不移植 `distroSizeMarker` 体积缓存**（上游为了启动路径不遍历数万文件）。
 *    沙箱的 rootfs 体积只在 [status] 里算，且 [status] 不是启动快路径 ——
 *    宿主要在 UI 上显示体积时才会调。加了缓存反而要维护失效时机。
 * 6. **不移植 `cleanupStalePtyMarkers`**（taixu 用 `script` 回退后端时的 PTY
 *    marker 文件）。沙箱用真 PTY（[PtySession]），没有 marker 文件。
 * 7. **保留**：staging → 校验 → 原子替换的三段式；安装失败清理 staging；
 *    「已安装」判定不只看 marker 还要看目录真的存在（[isInstalled]）。
 * 8. **新增**：`source` 显式记录（bundled / oci），存进 marker 文件，
 *    这样重启后还能回答「这个 rootfs 是怎么来的」——否则宿主没法提示用户
 *    「你现在是 minimal 环境，建议联网装完整版」。
 */

package com.heracles.sandbox.runtime

import android.content.res.AssetManager
import com.heracles.sandbox.api.RootfsStatus
import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * rootfs 双策略管理器，同时是 [PathResolver] 的默认实现。
 *
 * 线程安全：所有改变 rootfs 的操作（install / reset / snapshot restore）都在
 * [mutationLock] 下串行执行 —— 两个并发的 install 会互相踩 staging 目录。
 * 读取侧（[status] / [sandboxToHost]）不加锁，靠 volatile 字段。
 *
 * @param baseDir           全部沙箱数据的根（宿主视角，App 私有目录内）
 * @param assets            AssetManager（内置 rootfs 用）
 * @param eventSink         事件上报
 * @param registryBaseOverride 可选：OCI registry base 覆盖（自建镜像站）
 * @param snapshotKeep      最多保留几个 rootfs 快照
 */
class RootfsManager(
    val baseDir: File,
    private val assets: AssetManager,
    private val eventSink: EventSink = NoOpEventSink,
    registryBaseOverride: String? = null,
    snapshotKeep: Int = SnapshotStore.DEFAULT_MAX_KEEP,
) : PathResolver {

    /** rootfs 目录（宿主视角）。 */
    val rootfsDir: File = File(baseDir, ROOTFS_DIR_NAME)

    /** 安装过程中的临时目录父目录。 */
    private val stagingRoot: File = File(baseDir, STAGING_DIR_NAME)

    /** 快照仓库。 */
    private val snapshots = SnapshotStore(File(baseDir, SNAPSHOT_DIR_NAME), snapshotKeep)

    /** 「已安装」标记文件（记 source / label / ociRef）。 */
    private val markerFile: File = File(baseDir, MARKER_FILE_NAME)

    private val ociInstaller = OciRootfsInstaller(
        stagingRoot = stagingRoot,
        eventSink = eventSink,
        registryBaseOverride = registryBaseOverride,
    )

    private val bundled = BundledRootfs(assets, eventSink)

    private val mutationLock = Mutex()

    /**
     * 当前 rootfs 是否可用。**volatile**：读侧不加锁，写入在 [mutationLock] 内。
     *
     * 注意这里存的是「目录路径」而不是 boolean —— rootfs 未安装时是 null，
     * 这样 [PathResolver] 的实现天然拿到正确答案，不需要两处状态同步。
     */
    @Volatile
    private var activeRootfs: File? = null

    init {
        // 启动时探测一次：上次进程退出前装好的 rootfs 要能被认出来。
        activeRootfs = probeInstalledRootfs()
    }

    /**
     * 便捷构造器：`RootfsManager(context)`。
     *
     * 数据根目录固定为 `{context.filesDir}/sandbox`（与 [SandboxServiceCore]
     * 的默认布局一致：rootfs / workspaces / tmp / home / attachments 都在这下面）。
     *
     * 需要自定义根目录（多环境并存、测试用临时目录）时用**主构造器**传 File ——
     * 这也是本类保持主构造器为 `(baseDir, assets, …)` 的原因：路径必须由调用方
     * 显式给出，不能由本类去猜 `filesDir`。
     */
    constructor(context: android.content.Context) : this(
        baseDir = File(context.filesDir, DEFAULT_BASE_DIR_NAME),
        assets = context.assets,
    )

    /**
     * [useBundledRootfs] 的短别名。
     *
     * 保留两个名字是因为：短名适合宿主 demo 里链式调用，长名与
     * `ISandboxService.useBundledRootfs` 的 AIDL 方法名对齐。
     */
    suspend fun useBundled(): BundledRootfsResult = useBundledRootfs()

    // ========================================================================
    // PathResolver 实现（默认实现，见 SandboxDependencies.kt）
    // ========================================================================

    override fun sandboxToHost(sandboxPath: String): String =
        ProotPathResolver { activeRootfs }.sandboxToHost(sandboxPath)

    override fun hostToSandbox(hostPath: String): String? =
        ProotPathResolver { activeRootfs }.hostToSandbox(hostPath)

    override fun rootfsHostRoot(): String? = activeRootfs?.absolutePath

    // ========================================================================
    // 状态查询
    // ========================================================================

    /** rootfs 是否可用（目录存在 + 有 marker 或看起来像 rootfs）。 */
    fun isInstalled(): Boolean = activeRootfs != null

    /** 当前 rootfs 宿主路径；未安装为 null。 */
    fun rootfsHostPath(): String? = activeRootfs?.absolutePath

    /**
     * 当前状态。
     *
     * 未安装时返回 [RootfsStatus.NOT_INSTALLED]（不是抛异常 —— 「没装」是
     * 正常状态，宿主需要能查询它）。
     *
     * **同步阻塞**（会遍历 rootfs 统计体积）。这样设计是因为 AIDL 的
     * `RootfsStatus` 查询本身是同步的（见 sandbox-app 的 Stub），把它做成
     * suspend 只是把阻塞挪了个位置。调用方如果是 UI 线程，请自行切到 IO。
     */
    fun status(): RootfsStatus {
        val root = activeRootfs ?: return RootfsStatus.NOT_INSTALLED
        val meta = readMarker()
        return RootfsStatus(
            installed = true,
            source = meta?.source ?: RootfsStatus.SOURCE_NONE,
            label = meta?.label.orEmpty(),
            ociRef = meta?.ociRef.orEmpty(),
            sizeBytes = directorySize(root),
            snapshotName = "",
            snapshotCount = snapshots.list().size,
            rootfsPath = root.absolutePath,
        )
    }

    /** 当前 rootfs 是否来自内置 assets。 */
    fun isBundled(): Boolean = readMarker()?.source == RootfsStatus.SOURCE_BUNDLED

    /** 内置 rootfs 是否可用（不解包，只查 assets）。 */
    fun bundledAvailable(): Boolean = bundled.isBundled()

    // ========================================================================
    // 安装：OCI 策略
    // ========================================================================

    /**
     * 从 OCI registry 安装 rootfs。
     *
     * @param ociRef 镜像引用，如 `docker.io/library/alpine:3.20`
     * @throws SandboxException CODE_INVALID_ARGUMENT / CODE_NETWORK /
     *         CODE_ROOTFS_CORRUPT / CODE_IO
     */
    suspend fun installOci(
        ociRef: String,
        onProgress: RootfsInstallProgress = RootfsInstallProgress { _, _ -> },
    ): RootfsStatus = mutationLock.withLock {
        eventSink.onEvent(
            EventSink.CATEGORY_ROOTFS,
            "开始安装 OCI rootfs",
            mapOf("ref" to ociRef),
        )
        val result = ociInstaller.install(ociRef, rootfsDir, onProgress)
        writeMarker(
            Marker(source = RootfsStatus.SOURCE_OCI, label = result.label, ociRef = result.ociRef),
        )
        // ★ 只有全部成功后才更新 activeRootfs：中途失败时旧 rootfs 仍然可用。
        activeRootfs = rootfsDir
        eventSink.onEvent(
            EventSink.CATEGORY_ROOTFS,
            "OCI rootfs 已启用",
            mapOf("path" to rootfsDir.absolutePath, "bytes" to result.sizeBytes.toString()),
        )
        result
    }

    // ========================================================================
    // 安装：内置策略（离线 fallback）
    // ========================================================================

    /**
     * 使用 APK 内置的 minimal rootfs。
     *
     * ★ **优雅失败**：assets 里没有 bundle 时返回 [BundledRootfsResult.Outcome.NOT_BUNDLED]，
     * **不抛异常、不建空目录**。调用方按 outcome 分支即可（典型处理：
     * 提示用户「本次构建没内置 rootfs，请联网走 OCI 安装」）。
     *
     * 需要「内置 rootfs 是硬性要求」语义时用 [useBundledOrThrow]。
     */
    suspend fun useBundledRootfs(): BundledRootfsResult = mutationLock.withLock {
        eventSink.onEvent(EventSink.CATEGORY_ROOTFS, "开始安装内置 rootfs", emptyMap())
        val result = bundled.tryInstall(rootfsDir)
        when (result.outcome) {
            BundledRootfsResult.Outcome.INSTALLED -> {
                writeMarker(
                    Marker(
                        source = RootfsStatus.SOURCE_BUNDLED,
                        label = BundledRootfs.BUNDLED_LABEL,
                        ociRef = "",
                    ),
                )
                activeRootfs = rootfsDir
                eventSink.onEvent(
                    EventSink.CATEGORY_ROOTFS,
                    "内置 rootfs 已启用",
                    mapOf("path" to rootfsDir.absolutePath, "bytes" to result.sizeBytes.toString()),
                )
            }
            BundledRootfsResult.Outcome.NOT_BUNDLED -> {
                // 刻意的静默：这是「本次构建没打包」而不是错误，不该刷告警。
                eventSink.onEvent(
                    EventSink.CATEGORY_ROOTFS,
                    "本次构建未内置 rootfs（走 OCI 安装）",
                    emptyMap(),
                )
            }
            else -> {
                eventSink.onEvent(
                    EventSink.CATEGORY_ROOTFS,
                    "内置 rootfs 安装失败",
                    mapOf("outcome" to result.outcome.name, "message" to result.message),
                )
            }
        }
        result
    }

    /**
     * 同 [useBundledRootfs]，但失败时抛异常（给「内置 rootfs 是硬性要求」的宿主）。
     *
     * @throws SandboxException 错误码来自 [BundledRootfsResult.suggestedErrorCode]
     */
    suspend fun useBundledOrThrow(): RootfsStatus {
        val result = useBundledRootfs()
        if (!result.isInstalled) {
            throw SandboxException(
                result.suggestedErrorCode.takeIf { it != 0 } ?: SandboxException.CODE_ROOTFS_NOT_READY,
                result.message,
            )
        }
        return result.toStatus()
    }

    // ========================================================================
    // 快照 / 重置
    // ========================================================================

    /**
     * 给当前 rootfs 做快照。
     *
     * 典型用法：**装工具链之前**存档，装崩了一条命令回到能跑的状态 ——
     * 比重新下载 300 MB 快得多。
     *
     * @param name 快照名（同名覆盖）
     * @throws SandboxException CODE_ROOTFS_NOT_READY / CODE_INVALID_ARGUMENT
     */
    suspend fun snapshotRootfs(name: String): RootfsStatus = mutationLock.withLock {
        val root = activeRootfs ?: throw SandboxException(
            SandboxException.CODE_ROOTFS_NOT_READY,
            "rootfs 未安装，无法创建快照",
        )
        snapshots.create(name, root)
        eventSink.onEvent(
            EventSink.CATEGORY_ROOTFS,
            "rootfs 快照已创建",
            mapOf("name" to name, "path" to root.absolutePath),
        )
        status()
    }

    /** 列出全部 rootfs 快照。 */
    suspend fun listSnapshots(): List<SnapshotInfo> = withContext(Dispatchers.IO) {
        snapshots.list()
    }

    /**
     * 重置 rootfs。
     *
     * @param snapshotName 非空 ⇒ 从该快照恢复；空串 ⇒ **清空重装**（当前实现是
     *                     清空目录并标记未安装，让宿主重新选择 OCI 或内置策略）。
     *
     * 为什么「清空重装」不自己重装：装哪个策略是宿主的决定（[installOci] 需要
     * 镜像名，[useBundledRootfs] 可能没有 bundle）。沙箱不替宿主猜。
     *
     * @throws SandboxException CODE_INVALID_ARGUMENT 快照不存在
     */
    suspend fun resetRootfs(snapshotName: String): RootfsStatus = mutationLock.withLock {
        if (snapshotName.isNotBlank()) {
            val root = rootfsDir
            snapshots.restore(snapshotName, root)
            activeRootfs = root
            eventSink.onEvent(
                EventSink.CATEGORY_ROOTFS,
                "rootfs 已从快照恢复",
                mapOf("name" to snapshotName, "path" to root.absolutePath),
            )
            return@withLock status()
        }

        // 清空重装：删掉 rootfs + marker，让状态回到「未安装」
        deleteTree(rootfsDir)
        runCatching { markerFile.delete() }
        activeRootfs = null
        eventSink.onEvent(
            EventSink.CATEGORY_ROOTFS,
            "rootfs 已清空（等待重新安装）",
            mapOf("path" to rootfsDir.absolutePath),
        )
        RootfsStatus.NOT_INSTALLED
    }

    /** 快照占用总字节数。 */
    fun snapshotUsageBytes(): Long = snapshots.usageBytes()

    /** 删除一个快照。 */
    suspend fun deleteSnapshot(name: String): Boolean = withContext(Dispatchers.IO) {
        snapshots.delete(name)
    }

    // ========================================================================
    // 内部
    // ========================================================================

    /**
     * 探测已安装的 rootfs。
     *
     * 判定条件（两个都要满足，避免把垃圾目录当 rootfs）：
     *   1. 目录存在
     *   2. 有 marker 文件 **或** 看起来像 rootfs（有 etc/os-release 或 bin/sh）
     *
     * 为什么允许「没有 marker 但像 rootfs」：用户可能手动把 rootfs 塞进来，
     * 或者上一个版本没有 marker 机制（升级兼容）。这种情况 source 会是
     * [RootfsStatus.SOURCE_NONE]，宿主据此提示「来源未知」。
     */
    private fun probeInstalledRootfs(): File? {
        if (!rootfsDir.isDirectory) return null
        if (markerFile.isFile) return rootfsDir
        val looksLikeRootfs = File(rootfsDir, "etc/os-release").isFile ||
            File(rootfsDir, "usr/lib/os-release").isFile ||
            File(rootfsDir, "bin/sh").exists() ||
            File(rootfsDir, "usr/bin/sh").exists()
        if (looksLikeRootfs) {
            eventSink.onEvent(
                EventSink.CATEGORY_ROOTFS,
                "发现没有标记文件的 rootfs（来源未知，可能是手动放入）",
                mapOf("path" to rootfsDir.absolutePath),
            )
            return rootfsDir
        }
        return null
    }

    /** marker 文件内容（`key=value` 每行一个）。 */
    private data class Marker(
        val source: Int,
        val label: String,
        val ociRef: String,
    )

    private fun readMarker(): Marker? {
        if (!markerFile.isFile) return null
        return runCatching {
            val map = markerFile.readLines()
                .mapNotNull { line ->
                    val index = line.indexOf('=')
                    if (index <= 0) null else line.substring(0, index) to line.substring(index + 1)
                }
                .toMap()
            Marker(
                source = map["source"]?.toIntOrNull() ?: RootfsStatus.SOURCE_NONE,
                label = map["label"].orEmpty(),
                ociRef = map["oci_ref"].orEmpty(),
            )
        }.getOrNull()
    }

    private fun writeMarker(marker: Marker) {
        try {
            baseDir.mkdirs()
            markerFile.writeText(
                buildString {
                    append("source=").append(marker.source).append('\n')
                    append("label=").append(marker.label).append('\n')
                    append("oci_ref=").append(marker.ociRef).append('\n')
                },
            )
        } catch (failure: IOException) {
            // marker 写失败不影响 rootfs 本身可用；下次探测会走「像不像 rootfs」分支
            eventSink.onEvent(
                EventSink.CATEGORY_ROOTFS,
                "写入 rootfs 标记文件失败（rootfs 本身可用）",
                mapOf("error" to (failure.message ?: "unknown")),
            )
        }
    }

    /**
     * 统计目录体积（**不跟随符号链接**）。
     *
     * ## 旧实现为什么错（2026-10-29 真机抓到）
     *
     * 旧代码用 `dir.walkTopDown()`：它判断目录走 `File.isDirectory`，
     * 而那个**跟随符号链接** ⇒ Alpine 的 `/lib -> usr/lib`、`/bin -> usr/bin`
     * 以及 JDK 的 `default-jvm -> java-17-openjdk` 会被反复下钻，体积成倍放大。
     * 真机现象：`du` 实际 295 MB，UI 显示 **21.6 GB**。
     *
     * 改用 NIO `walkFileTree`（**不传 FOLLOW_LINKS**）：目录链接不下钻、
     * 链接本身不计入 → 与 `du` 口径一致。
     */
    /** 统计目录体积 —— 实现见 [directorySizeNoFollowLinks]（顶层函数，便于 JVM 单测）。 */
    internal fun directorySize(dir: File): Long = directorySizeNoFollowLinks(dir)

    private fun deleteTree(file: File) {
        // ★ 用 NIO 判符号链接（等价于 isSymlinkNoFollow，但不跨文件依赖扩展函数）
        val isLink =
            runCatching { java.nio.file.Files.isSymbolicLink(file.toPath()) }.getOrDefault(false)
        if (!file.exists() && !isLink) return
        if (isLink) {
            runCatching { Files.deleteIfExists(file.toPath()) }
            return
        }
        if (file.isDirectory) {
            file.listFiles().orEmpty().forEach { deleteTree(it) }
            runCatching { file.delete() }
        } else {
            runCatching { Files.deleteIfExists(file.toPath()) }
        }
    }

    companion object {
        /** rootfs 目录名。 */
        const val ROOTFS_DIR_NAME = "rootfs"

        /** 安装 staging 目录名。 */
        const val STAGING_DIR_NAME = "rootfs-staging"

        /** 快照目录名。 */
        const val SNAPSHOT_DIR_NAME = "rootfs-snapshots"

        /** 安装标记文件名。 */
        const val MARKER_FILE_NAME = "rootfs.installed"

        /** `RootfsManager(context)` 便捷构造器使用的数据根目录名（在 filesDir 下）。 */
        const val DEFAULT_BASE_DIR_NAME = "sandbox"

        /**
         * 推荐的默认 OCI 镜像。
         *
         * alpine 是刻意选的：体积最小（约 8 MB 三层），装得快，适合「先能跑
         * 再装工具链」。需要 apt/dpkg 时宿主应该换 `debian:12-slim`。
         */
        const val RECOMMENDED_OCI_REF = "docker.io/library/alpine:3.20"
    }
}
