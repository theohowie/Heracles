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
 *           （上游 `importArchive` 的 tar/tar.gz/tar.xz/tar.zst 分支 + ZIP 拒绝策略）
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * APK assets 内置 minimal rootfs 的**离线 fallback**：把 `assets/rootfs-bundle.tar`
 * （或 `.tar.gz`）解到目标目录。用于「没网 / 装不上 OCI」时至少能跑一个最小环境。
 *
 * ============================================================================
 * ★ 优雅失败（本文件最重要的契约）
 * ============================================================================
 * **assets 里很可能没有 `rootfs-bundle.tar`**（本仓库当前就没有 —— 见下方
 * 「现状」）。这种情况下必须：
 *
 *   1. **绝不崩溃**（不抛 NullPointerException / 不读 null stream）
 *   2. **绝不假装成功**（不建个空目录就 return）
 *   3. 返回**明确的错误码 + 可操作的文案**
 *
 * 错误码区分得很细，因为宿主要按码分支（[SandboxException] 的注释也这么说：
 * 按码比按文案稳）：
 *
 *   - [BundledRootfsResult.Outcome.NOT_BUNDLED]  —— assets 里根本没有这个文件。
 *     这不是错误，是「本次构建没打内置 rootfs」；宿主应该说「请联网安装」。
 *   - [BundledRootfsResult.Outcome.CORRUPT]      —— 文件在，但解包/压缩格式坏了。
 *     这是**打包错误**，宿主应该报 bug。
 *   - [BundledRootfsResult.Outcome.UNSUPPORTED]  —— 文件在，但是不支持的压缩格式
 *     （zstd/xz 需要原生库，依赖白名单里没有）。宿主应该说「换 gzip 包」。
 *   - [BundledRootfsResult.Outcome.INSTALLED]    —— 成功。
 *   - [BundledRootfsResult.Outcome.IO_ERROR]     —— 磁盘/权限问题。
 *
 * 调用方拿到的永远是 [BundledRootfsResult]，**不会**因为 assets 缺文件而抛异常。
 * （[BundledRootfs.installOrThrow] 是给「内置 rootfs 是硬性要求」的宿主用的
 * 便捷包装，它会把 Outcome 翻译成 SandboxException。）
 *
 * ============================================================================
 * 现状（诚实记录）
 * ============================================================================
 * 本仓库的 `sandbox-runtime/src/main/assets/` 目录**目前是空的** ——
 * 没有 `rootfs-bundle.tar`。原因：一个能跑 `sh` + 核心 utils 的 aarch64
 * rootfs 压缩后仍有 2~5 MB，而它的构建需要（a）从 OCI 拉取一次真实镜像并
 * 导出，（b）在有 Linux 的环境里做 tar，属于发布流程而不是源码交付。
 *
 * ⇒ 因此**默认行为就是 NOT_BUNDLED**，这是设计好的路径而不是缺陷：
 *   ```
 *   val result = bundled.tryInstall(targetDir)
 *   if (result.outcome == BundledRootfsResult.Outcome.NOT_BUNDLED) {
 *       // 走 OCI：installer.install("docker.io/library/alpine:3.20", …)
 *   }
 *   ```
 * 打包方式见 [BUNDLE_ASSET_NAMES] 的注释。
 *
 * ============================================================================
 * 与上游 taixu RootfsInstaller.importArchive 的差异
 * ============================================================================
 * 1. **不移植 ZIP**：上游对 ZIP 明确抛「ZIP 无法可靠保留 Linux 权限与符号链接」。
 *    本文件沿用这个判断，但改成 [Outcome.UNSUPPORTED] 而不是抛异常 ——
 *    保持本文件「永不抛」的契约。
 * 2. **不移植 xz / zstd**：`org.tukaani.xz` 与 `com.github.luben.zstd` 都不在
 *    依赖白名单里。检测到这两个 magic 时返回 [Outcome.UNSUPPORTED] 并说明原因
 *    （而不是解出一堆垃圾）。
 * 3. **不移植 `normalizeImportedRoot`**（上游处理「tar 里套了一个顶层目录」）。
 *    内置 bundle 的布局由我们自己的打包脚本控制，约定**直接以 `/etc`、`/bin`
 *    开头**。若发现有单层包裹，仍然尝试下钻一次（[findEffectiveRoot]）——
 *    这比直接失败对使用者友好，但注释写明这是兼容而非主路径。
 * 4. **新增 magic 探测**：先读 6 字节判断压缩格式，再决定用哪个 InputStream。
 *    上游也是这么做的（`buffered.mark(8)`），这里保持同样思路但更明确地
 *    暴露「不支持」这个结果。
 * 5. **不移植 `preserveUserDirectories`**（升级时保留 /root 与 /opt/taixu）。
 *    内置 rootfs 是**全新安装**的 fallback，没有「旧用户目录」可言；
 *    真正需要保留的数据在工作区（[WorkspaceManager] 管），不在 rootfs 里。
 */

package com.heracles.sandbox.runtime

import android.content.res.AssetManager
import com.heracles.sandbox.api.RootfsStatus
import com.heracles.sandbox.api.SandboxException
import java.io.BufferedInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.zip.GZIPInputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 内置 rootfs 安装的结果。
 *
 * **本类不抛异常**（除非协程被取消）—— 所有失败都表达为 [Outcome]。
 */
data class BundledRootfsResult(
    val outcome: Outcome,
    /** 人类可读说明（可直接展示给用户） */
    val message: String,
    /** 成功时的 rootfs 路径；失败为 null */
    val rootfsPath: String? = null,
    /** 成功时的体积 */
    val sizeBytes: Long = 0L,
    /** 失败时的 [SandboxException.CODE_*] 建议码；成功为 0 */
    val suggestedErrorCode: Int = 0,
) {
    enum class Outcome {
        /** 装好了。 */
        INSTALLED,

        /**
         * assets 里没有内置 rootfs。**这不是错误** —— 本次构建没打包而已，
         * 宿主应回退到 OCI 安装。
         */
        NOT_BUNDLED,

        /** 文件在，但 tar/压缩流坏了（打包错误）。 */
        CORRUPT,

        /** 文件在，但压缩格式不受支持（zstd / xz / zip）。 */
        UNSUPPORTED,

        /** 磁盘 I/O 或权限问题。 */
        IO_ERROR,
    }

    val isInstalled: Boolean get() = outcome == Outcome.INSTALLED

    /** 转成 RootfsStatus（只在成功时有意义）。 */
    fun toStatus(): RootfsStatus = if (isInstalled) {
        RootfsStatus(
            installed = true,
            source = RootfsStatus.SOURCE_BUNDLED,
            label = BundledRootfs.BUNDLED_LABEL,
            ociRef = "",
            sizeBytes = sizeBytes,
            snapshotName = "",
            snapshotCount = 0,
            rootfsPath = rootfsPath.orEmpty(),
        )
    } else {
        RootfsStatus.NOT_INSTALLED
    }
}

/**
 * APK assets 内置 minimal rootfs 的解包器。
 *
 * @param assets    宿主的 AssetManager
 * @param eventSink 事件上报（可选）
 * @param tarExtractor tar 解包器（可注入以便测试）
 */
class BundledRootfs(
    private val assets: AssetManager,
    private val eventSink: EventSink = NoOpEventSink,
    private val tarExtractor: TarStreamExtractor = TarStreamExtractor(),
) {

    /**
     * 尝试安装内置 rootfs 到 [targetDir]。
     *
     * **永不抛异常**（协程取消除外）。所有失败都通过 [BundledRootfsResult.outcome]
     * 表达，调用方按 outcome 分支即可 —— 不做 try/catch 也不会崩。
     */
    suspend fun tryInstall(targetDir: File): BundledRootfsResult = withContext(Dispatchers.IO) {
        try {
            // ---- 1. 找 assets 里的 bundle（按优先级） ----
            val bundled = findBundledAsset()
                ?: return@withContext BundledRootfsResult(
                    outcome = BundledRootfsResult.Outcome.NOT_BUNDLED,
                    message = "本次构建未内置 rootfs（assets 里没有 ${BUNDLE_ASSET_NAMES.joinToString(" / ")}）。" +
                        "请联网通过 installRootfs(ociRef) 安装完整环境，例如 docker.io/library/alpine:3.20。",
                    suggestedErrorCode = SandboxException.CODE_ROOTFS_NOT_READY,
                )

            eventSink.onEvent(
                EventSink.CATEGORY_ROOTFS,
                "开始解包内置 rootfs",
                mapOf("asset" to bundled, "target" to targetDir.absolutePath),
            )

            // ---- 2. 打开 asset 流，探测压缩格式 ----
            val raw: InputStream = try {
                assets.open(bundled)
            } catch (failure: IOException) {
                return@withContext BundledRootfsResult(
                    outcome = BundledRootfsResult.Outcome.IO_ERROR,
                    message = "无法打开内置 rootfs（$bundled）：${failure.message}",
                    suggestedErrorCode = SandboxException.CODE_IO,
                )
            }

            // ================================================================
            // ★ 这里**绝对不能**写 `raw.use { detectAndWrap(it) }`
            // ================================================================
            // `use {}` 会在 lambda 返回后**关闭 raw**，而 detectAndWrap 返回的
            // buffered / GZIPInputStream 仍然要从 raw 读数据 —— 于是解包一开始
            // 就抛 `AssetInputStream is closed`，被归到 CORRUPT。
            //
            // 这是本工程真机上抓到的 bug：离线时内置 rootfs 明明在 APK 里，
            // 却报「压缩包损坏」，一路误导到怀疑打包脚本。
            //
            // 正确做法：**把流的生命周期交给后面的 `stream.use {}`**，
            // 这里只做探测与包装，不关闭任何东西。
            // （GZIPInputStream 关闭时会连带关闭底层 buffered→raw，所以
            //   最终 close 仍然只发生一次，且发生在正确的所有者手里。）
            //
            // 这段逻辑抽成 openBundleStream() 就是为了让它能被单测直接覆盖 ——
            // 光测 detectAndWrap 测不到这个 bug（见 BundledRootfsStreamOwnershipTest）。
            val (stream, unsupportedReason) = openBundleStream(raw)
            if (stream == null) {
                return@withContext BundledRootfsResult(
                    outcome = BundledRootfsResult.Outcome.UNSUPPORTED,
                    message = unsupportedReason.orEmpty(),
                    suggestedErrorCode = SandboxException.CODE_ROOTFS_CORRUPT,
                )
            }

            // ---- 3. 解包到 staging，成功后再替换 ----
            val staging = File(targetDir.parentFile ?: targetDir, "${targetDir.name}.staging")
            deleteTree(staging)
            if (!staging.mkdirs() && !staging.isDirectory) {
                return@withContext BundledRootfsResult(
                    outcome = BundledRootfsResult.Outcome.IO_ERROR,
                    message = "无法创建解包临时目录：${staging.absolutePath}",
                    suggestedErrorCode = SandboxException.CODE_IO,
                )
            }

            try {
                stream.use { input ->
                    tarExtractor.extract(input, staging, handleWhiteouts = false)
                }
            } catch (cancellation: CancellationException) {
                deleteTree(staging)
                throw cancellation
            } catch (corrupt: SandboxException) {
                deleteTree(staging)
                return@withContext BundledRootfsResult(
                    outcome = BundledRootfsResult.Outcome.CORRUPT,
                    message = "内置 rootfs（$bundled）解包失败：${corrupt.message}。" +
                        "这是打包问题，请检查打包脚本生成的 tar 是否完整。",
                    suggestedErrorCode = SandboxException.CODE_ROOTFS_CORRUPT,
                )
            } catch (failure: Throwable) {
                deleteTree(staging)
                return@withContext BundledRootfsResult(
                    outcome = BundledRootfsResult.Outcome.CORRUPT,
                    message = "内置 rootfs（$bundled）解包时出错：${failure.message ?: failure::class.java.simpleName}",
                    suggestedErrorCode = SandboxException.CODE_ROOTFS_CORRUPT,
                )
            }

            // ---- 4. 兼容「tar 里套了一层顶层目录」 ----
            val effectiveRoot = findEffectiveRoot(staging)

            // ---- 5. 校验 + 启用 ----
            val validationError = validateBundledRootfs(effectiveRoot)
            if (validationError != null) {
                deleteTree(staging)
                return@withContext BundledRootfsResult(
                    outcome = BundledRootfsResult.Outcome.CORRUPT,
                    message = validationError,
                    suggestedErrorCode = SandboxException.CODE_ROOTFS_CORRUPT,
                )
            }

            val finalRoot = try {
                if (effectiveRoot != staging) {
                    // 顶层有包裹：把内层挪出来
                    val normalized = File(staging.parentFile, "${staging.name}.normalized")
                    deleteTree(normalized)
                    if (!effectiveRoot.renameTo(normalized)) {
                        deleteTree(staging)
                        return@withContext BundledRootfsResult(
                            outcome = BundledRootfsResult.Outcome.IO_ERROR,
                            message = "无法整理内置 rootfs 的目录结构（${effectiveRoot.absolutePath}）",
                            suggestedErrorCode = SandboxException.CODE_IO,
                        )
                    }
                    deleteTree(staging)
                    if (!normalized.renameTo(staging)) {
                        deleteTree(normalized)
                        return@withContext BundledRootfsResult(
                            outcome = BundledRootfsResult.Outcome.IO_ERROR,
                            message = "无法提交内置 rootfs 的目录结构",
                            suggestedErrorCode = SandboxException.CODE_IO,
                        )
                    }
                }
                replaceTarget(staging, targetDir)
                targetDir
            } catch (failure: Throwable) {
                deleteTree(staging)
                return@withContext BundledRootfsResult(
                    outcome = BundledRootfsResult.Outcome.IO_ERROR,
                    message = "无法启用内置 rootfs：${failure.message ?: failure::class.java.simpleName}",
                    suggestedErrorCode = SandboxException.CODE_IO,
                )
            }

            val size = directorySize(finalRoot)
            eventSink.onEvent(
                EventSink.CATEGORY_ROOTFS,
                "内置 rootfs 安装完成",
                mapOf("asset" to bundled, "bytes" to size.toString()),
            )
            return@withContext BundledRootfsResult(
                outcome = BundledRootfsResult.Outcome.INSTALLED,
                message = "已从内置资源（$bundled）安装 minimal rootfs",
                rootfsPath = finalRoot.absolutePath,
                sizeBytes = size,
            )
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Throwable) {
            // 兜底：本类的契约是「永不因为 assets/IO 问题抛异常」。
            // 走到这里说明有意料之外的 bug，但也不该让宿主崩溃。
            BundledRootfsResult(
                outcome = BundledRootfsResult.Outcome.IO_ERROR,
                message = "安装内置 rootfs 时发生意外错误：${failure.message ?: failure::class.java.simpleName}",
                suggestedErrorCode = SandboxException.CODE_INTERNAL,
            )
        }
    }

    /**
     * 安装；失败时抛 [SandboxException]。
     *
     * 给「内置 rootfs 是硬性要求」的宿主用。错误码来自
     * [BundledRootfsResult.suggestedErrorCode]，所以宿主仍然能按码分支。
     */
    suspend fun installOrThrow(targetDir: File): BundledRootfsResult {
        val result = tryInstall(targetDir)
        if (!result.isInstalled) {
            throw SandboxException(
                if (result.suggestedErrorCode != 0) {
                    result.suggestedErrorCode
                } else {
                    SandboxException.CODE_ROOTFS_NOT_READY
                },
                result.message,
            )
        }
        return result
    }

    /** 内置 rootfs 是否可用（只看 assets 里有没有文件，不解包）。 */
    fun isBundled(): Boolean = findBundledAsset() != null

    // ========================================================================
    // 内部
    // ========================================================================

    /** 按优先级找 assets 里的 bundle；返回实际命中的 asset 名或 null。 */
    private fun findBundledAsset(): String? {
        val available = try {
            assets.list("")?.toSet().orEmpty()
        } catch (_: IOException) {
            emptySet()
        }
        // 也可能被放在子目录里
        val availableInRootfsDir = try {
            assets.list(ASSET_SUBDIR)?.toSet().orEmpty()
        } catch (_: IOException) {
            emptySet()
        }

        BUNDLE_ASSET_NAMES.forEach { name ->
            if (name in available) return name
            if (name in availableInRootfsDir) return "$ASSET_SUBDIR/$name"
        }
        return null
    }

    /**
     * 读 magic 判断压缩格式，返回 (可用流, 不支持的原因)。
     *
     * 支持：裸 tar、tar.gz（gzip）。
     * 不支持（明确给出原因，不静默失败）：zstd、xz、zip。
     */
    /**
     * 打开内置 bundle 的**可解包流**，并接管 [raw] 的生命周期。
     *
     * ========================================================================
     * ★★★ 这个函数存在的唯一理由：把「流所有权」钉死在一个可测的地方 ★★★
     * ========================================================================
     * 历史 bug：调用点曾写成 `raw.use { detectAndWrap(it) }`。`use {}` 在
     * lambda 返回后立刻关闭 raw，而返回的包装流还要读它 —— 解包第一步就抛
     * `AssetInputStream is closed`，被归成 `Outcome.CORRUPT`，错误文案是
     * 「压缩包损坏」，把排查方向带偏到打包脚本上。
     *
     * **契约**（改它之前先读懂）：
     * - 返回非 null：返回的流**拥有** [raw]，调用方 `use {}` 关闭它即可
     *   （GZIPInputStream 会连带关闭 buffered → raw，close 只发生一次）。
     * - 返回 null：本函数**已**关闭 [raw]（没有包装流接手，不关就泄漏）。
     *
     * 之所以独立成函数而不是内联在 tryInstall 里：tryInstall 要 AssetManager，
     * 纯 JVM 单测造不出来；而这段逻辑恰恰是出 bug 的地方，必须能被单测覆盖。
     */
    internal fun openBundleStream(raw: InputStream): Pair<InputStream?, String?> {
        val (stream, reason) = detectAndWrap(raw)
        if (stream == null) {
            // 探测失败：没有包装流接手 raw，必须由我们关闭（否则 fd 泄漏）
            runCatching { raw.close() }
        }
        return stream to reason
    }

    /**
     * 探测压缩格式并包装成 tar 可读的流。
     *
     * 支持：裸 tar、tar.gz（gzip）。
     * 不支持（明确给出原因，不静默失败）：zstd、xz、zip。
     *
     * ========================================================================
     * ★ 返回值与 [raw] 的**生命周期契约**（改这个函数前必读）
     * ========================================================================
     * - 返回非 null 时：返回的流**拥有** [raw]，调用方负责 close 它
     *   （close 包装流会连带关闭 raw）。
     * - 返回 null 时：**本函数不关闭** [raw]，由调用方（[openBundleStream]）关闭。
     *
     * 这个函数刻意是 `internal` 以**便于单测**：它不是 Android API 依赖，
     * 可以在纯 JVM 上验证流所有权语义。
     */
    internal fun detectAndWrap(raw: InputStream): Pair<InputStream?, String?> {
        val buffered = BufferedInputStream(raw, MAGIC_PROBE_BYTES)
        buffered.mark(MAGIC_PROBE_BYTES)
        val magic = ByteArray(MAGIC_PROBE_BYTES)
        val read = buffered.read(magic)
        buffered.reset()

        if (read < 2) {
            return null to "内置 rootfs 文件为空或过短（读到 $read 字节），无法识别格式"
        }

        fun at(index: Int): Int = if (index < read) magic[index].toInt() and 0xff else -1

        // gzip: 1f 8b
        if (at(0) == 0x1f && at(1) == 0x8b) {
            return GZIPInputStream(buffered) to null
        }
        // zstd: 28 b5 2f fd
        if (at(0) == 0x28 && at(1) == 0xb5 && at(2) == 0x2f && at(3) == 0xfd) {
            return null to "内置 rootfs 使用 zstd 压缩（magic 28 b5 2f fd），沙箱未内置 zstd 解码器" +
                "（依赖白名单里没有 zstd 库）。请重新打包为 tar 或 tar.gz。"
        }
        // xz: fd 37 7a 58 5a 00
        if (at(0) == 0xfd && at(1) == 0x37 && at(2) == 0x7a && at(3) == 0x58 && at(4) == 0x5a) {
            return null to "内置 rootfs 使用 xz 压缩（magic fd 37 7a 58 5a 00），沙箱未内置 xz 解码器" +
                "（依赖白名单里没有 XZ 库）。请重新打包为 tar 或 tar.gz。"
        }
        // zip: 50 4b 03 04
        if (at(0) == 0x50 && at(1) == 0x4b && at(2) == 0x03 && at(3) == 0x04) {
            return null to "内置 rootfs 是 ZIP 格式。ZIP 无法可靠保留 Linux 权限位与符号链接，" +
                "解出来的 rootfs 无法执行任何二进制。请改用 tar 或 tar.gz。"
        }
        // 其它：当作裸 tar。tar 的 magic 在 offset 257（"ustar"），
        // 但这里不预读 257 字节校验 —— 让 tar 解析器自己报错，错误信息更准确。
        return buffered to null
    }

    /**
     * 若 tar 里只有**一个顶层目录**且它自己看起来像个 rootfs，就下钻一层。
     *
     * 兼容 `alpine-minirootfs-3.20.0-aarch64/` 这种打包方式（官方 minirootfs
     * tar 就是套了一层）。主路径（我们自己的打包脚本）是直接以 /etc 开头。
     */
    private fun findEffectiveRoot(staging: File): File {
        val children = staging.listFiles().orEmpty()
        if (children.size != 1) return staging
        val only = children[0]
        if (!only.isDirectory) return staging
        val looksLikeRootfs = File(only, "etc").isDirectory ||
            File(only, "bin").isDirectory ||
            File(only, "usr").isDirectory
        return if (looksLikeRootfs) only else staging
    }

    /** 校验解包结果像不像 rootfs；返回错误说明或 null（通过）。 */
    private fun validateBundledRootfs(rootfs: File): String? {
        if (!rootfs.isDirectory) {
            return "内置 rootfs 解包后不是目录：${rootfs.absolutePath}"
        }
        val entries = rootfs.listFiles()?.size ?: 0
        if (entries == 0) {
            return "内置 rootfs 解包后是空目录：${rootfs.absolutePath}（tar 里没有任何条目？）"
        }
        val hasShell = File(rootfs, "bin/sh").exists() ||
            File(rootfs, "usr/bin/sh").exists() ||
            File(rootfs, "bin/bash").exists()
        val hasEtc = File(rootfs, "etc").isDirectory
        if (!hasShell && !hasEtc) {
            return "内置 rootfs 不像一个可用的根文件系统：既没有 bin/sh 也没有 etc/。" +
                "请检查打包脚本是否在正确的目录下执行了 tar。"
        }
        return null
    }

    /** 用 staging 原子替换 targetDir。 */
    private fun replaceTarget(staging: File, target: File) {
        target.parentFile?.let { parent ->
            if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
                throw IOException("无法创建 rootfs 父目录：${parent.absolutePath}")
            }
        }
        val backup = File(target.parentFile, "${target.name}.old-${System.currentTimeMillis()}")
        if (target.exists()) {
            deleteTree(backup)
            if (!target.renameTo(backup)) {
                throw IOException("无法移开旧 rootfs：${target.absolutePath}")
            }
        }
        if (!staging.renameTo(target)) {
            // 回滚
            if (backup.exists()) runCatching { backup.renameTo(target) }
            throw IOException("无法启用新 rootfs：${staging.absolutePath} -> ${target.absolutePath}")
        }
        deleteTree(backup)
    }

    private fun directorySize(dir: File): Long = runCatching {
        dir.walkTopDown()
            .filter { it.isFile && !it.isSymlinkNoFollow() }
            .sumOf { it.length() }
    }.getOrDefault(0L)

    /** 递归删除（不跟随符号链接，防删到 rootfs 之外）。 */
    private fun deleteTree(file: File) {
        if (!file.exists() && !file.isSymlinkNoFollow()) return
        if (file.isSymlinkNoFollow()) {
            runCatching { java.nio.file.Files.deleteIfExists(file.toPath()) }
            return
        }
        if (file.isDirectory) {
            file.listFiles().orEmpty().forEach { deleteTree(it) }
            runCatching { file.delete() }
        } else {
            runCatching { java.nio.file.Files.deleteIfExists(file.toPath()) }
        }
    }

    companion object {
        /** 内置 rootfs 的展示名（RootfsStatus.label）。 */
        const val BUNDLED_LABEL = "bundled-minimal"

        /** assets 子目录名（备选布局）。 */
        const val ASSET_SUBDIR = "rootfs"

        /**
         * 按优先级尝试的 asset 文件名。
         *
         * **打包约定**（给发布流程用）：
         * ```
         *   # 在 rootfs 根目录里执行（不要带顶层目录，我们的 findEffectiveRoot 只是兼容）
         *   sudo tar --numeric-owner -cf rootfs-bundle.tar .
         *   # 可选：gzip 压缩（推荐，体积小一半以上）
         *   gzip -9 rootfs-bundle.tar   # => rootfs-bundle.tar.gz
         *   # 放进 sandbox-runtime/src/main/assets/
         * ```
         * **不要**用 `tar -zcvf` 之类带 `-v` 的命令（会把文件名打到 stdout，
         * 在 CI 里没有坏处但在脚本里容易误当作产物）。**不要**用 zip。
         *
         * 顺序说明：先 `.tar.gz`（体积小，优先），再裸 `.tar`。
         */
        val BUNDLE_ASSET_NAMES = listOf(
            // ★ 优先 `.bin`（2026-10-28）：AGP 会把 `assets/*.tar.gz` **自动解压**成
            //   `assets/*.tar` 再打进 APK —— 实测 APK 里从 3.77 MB 变成 8.69 MB，
            //   白背 4.9 MB。改成 `.bin` 后缀不触发那条规则，压缩态原样进包；
            //   运行期靠 `detectAndWrap` 的 **magic 探测**判断是 gzip，不依赖扩展名。
            "rootfs-bundle.bin",
            // 兼容旧包（万一有人还在用 .tar.gz 打包的 AAR）
            "rootfs-bundle.tar.gz",
            "rootfs-bundle.tar",
        )

        /** magic 探测需要的字节数（xz 要 5 字节，留 8 字节余量）。 */
        private const val MAGIC_PROBE_BYTES = 8
    }
}
