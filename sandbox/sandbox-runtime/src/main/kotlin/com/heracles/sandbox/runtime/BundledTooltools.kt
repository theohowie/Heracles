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

import java.io.File
import java.io.InputStream

/**
 * **T1 工具**（aapt2 / aidl / zipalign）的内置解包器。
 *
 * ============================================================================
 * 三档模型（2026-10-28 产品定调）
 * ============================================================================
 * | 档 | 内容 | 来源 | 何时可用 |
 * |---|---|---|---|
 * | **T0** | Alpine rootfs（3.77 MB 压缩 / 9 MB 解压） | **内置 APK** | 装完就有 |
 * | **T1** | aapt2 / aidl / zipalign（约 10.3 MB） | **内置 APK**（本类负责解包） | 装完就有 |
 * | **T2** | JDK 17 + Gradle + android.jar（≈440 MB） | **用户激活时下载** | 激活后 |
 *
 * 判据是「用得多不多」：aapt2 解析 APK 是高频操作 → 值得内置；
 * 从源码编译是低频重活 → 值得让用户按需下载。
 *
 * ============================================================================
 * 为什么这些资产是 **linux-aarch64**，不能用 Termux 的
 * ============================================================================
 * Termux 的 aapt2 是 **bionic**（解释器 `/system/bin/linker64`），在 PRoot guest 里
 * `execve` 返回 ENOENT —— 真机现象是 `command -v aapt2` 找得到、执行却 `not found`。
 * 而且那种二进制只能在**宿主进程**跑，打进 rootfs 等于白装。
 * 详见 `docs/porting-log.md` Phase 7。
 *
 * 所以 `tools/fetch-bundled-tools.ps1` 抓的是 `android-sdk-tools-static-aarch64`
 * （linux 静态构建），并在入库前做 ABI 校验。
 *
 * ============================================================================
 * 解包到哪、为什么是原子替换
 * ============================================================================
 * 目标：`<rootfs>/opt/as/{aapt2,aidl,zipalign}`
 *
 * 做法：先解到 `<rootfs>/opt/.as-staging/`，全部成功且 chmod 完成后再 rename。
 * 中途失败（磁盘满、被杀）只会留下 staging，**不会产生"半个工具目录"** ——
 * 半个目录比没有更糟：`command -v aapt2` 会成功，但执行时缺库。
 */
class BundledTooltools(
    /** 打开一个 asset；不存在返回 null。抽成函数是为了能在 JVM 单测里喂假数据。 */
    private val openAsset: (String) -> InputStream?,
    /** rootfs 的宿主侧根目录；未就绪返回 null。 */
    private val rootfsHostRoot: () -> String?,
) {

    /**
     * 确保 T1 工具已解包到 rootfs。
     *
     * 幂等：已经装好就直接返回 [ExtractResult.alreadyInstalled]。
     */
    fun ensureExtracted(): ExtractResult {
        val root = rootfsHostRoot()
            ?: return ExtractResult.notReady()

        val optDir = File(root, GUEST_TOOL_DIR.trimStart('/'))
        val targetDir = File(root, GUEST_TOOL_DIR.trimStart('/'))

        // 已经装好（三个都在、都可执行、体积合理）→ 直接返回
        val existing = TOOL_NAMES.map { File(targetDir, it) }
        if (existing.all { it.isFile && it.length() > MIN_BYTES && it.canExecute() }) {
            return ExtractResult.alreadyInstalled(targetDir.absolutePath)
        }

        // asset 里有没有？（没有说明这个 APK 没内置 T1 —— 如实报告，不要静默跳过）
        val available = TOOL_NAMES.filter { name -> openAsset("$ASSET_PREFIX$name") != null }
        if (available.isEmpty()) {
            return ExtractResult.notBundled()
        }
        if (available.size < TOOL_NAMES.size) {
            return ExtractResult.failed(
                "内置工具不完整：缺 ${TOOL_NAMES - available.toSet()}（assets/$ASSET_PREFIX 下）",
            )
        }

        val staging = File(root, "opt/.as-staging")
        try {
            staging.deleteRecursively()
            if (!staging.mkdirs() && !staging.isDirectory) {
                return ExtractResult.failed("无法创建临时目录：${staging.absolutePath}")
            }

            var total = 0L
            for (name in TOOL_NAMES) {
                val src = openAsset("$ASSET_PREFIX$name")
                    ?: return ExtractResult.failed("asset 打不开：$ASSET_PREFIX$name")
                val dst = File(staging, name)
                src.use { input ->
                    dst.outputStream().use { out -> input.copyTo(out) }
                }
                if (dst.length() <= MIN_BYTES) {
                    return ExtractResult.failed("$name 解包后体积异常：${dst.length()} B")
                }
                // ★ 必须置可执行：rootfs 里的文件由 PRoot 执行，没有 +x 会 Permission denied
                if (!dst.setExecutable(true, false)) {
                    return ExtractResult.failed("$name 置可执行位失败：${dst.absolutePath}")
                }
                total += dst.length()
            }

            // 原子替换：先清旧目录，再 rename staging → 目标
            targetDir.deleteRecursively()
            optDir.mkdirs()
            if (!staging.renameTo(targetDir)) {
                staging.copyRecursively(targetDir, overwrite = true)
                staging.deleteRecursively()
            }
            return ExtractResult.installed(targetDir.absolutePath, total)
        } catch (failure: Throwable) {
            staging.deleteRecursively()
            return ExtractResult.failed("${failure.javaClass.simpleName}: ${failure.message}")
        }
    }

    /** 解包结果（**如实**：没内置就说没内置，不要假装成功）。 */
    data class ExtractResult(
        val status: Status,
        val path: String = "",
        val bytes: Long = 0,
        val message: String = "",
    ) {
        enum class Status {
            /** 解包成功（或本来就是好的）。 */
            READY,

            /** 这个 APK 没内置 T1 —— 需要联网获取，由上层决定走哪条路。 */
            NOT_BUNDLED,

            /** rootfs 还没就绪。 */
            ROOTFS_NOT_READY,

            /** 解包失败（磁盘满、asset 损坏…）。 */
            FAILED,
            ;
        }

        val ok: Boolean get() = status == Status.READY

        companion object {
            fun installed(path: String, bytes: Long) =
                ExtractResult(Status.READY, path, bytes, "已解包 $bytes B 到 $path")

            fun alreadyInstalled(path: String) =
                ExtractResult(Status.READY, path, 0, "已存在，跳过")

            fun notBundled() = ExtractResult(
                Status.NOT_BUNDLED,
                message = "本 APK 未内置 T1 工具（assets/$ASSET_PREFIX 为空）",
            )

            fun notReady() = ExtractResult(
                Status.ROOTFS_NOT_READY,
                message = "rootfs 尚未就绪，无法解包工具",
            )

            fun failed(message: String) = ExtractResult(Status.FAILED, message = message)
        }
    }

    companion object {
        /** guest 内的工具目录（在 rootfs 内，不在任何标准 bind 覆盖区）。 */
        const val GUEST_TOOL_DIR = "/opt/as"

        /** assets 下的前缀。 */
        const val ASSET_PREFIX = "tooltools/"

        /** 三个工具名（与 `tools/fetch-bundled-tools.ps1` 产出一致）。 */
        val TOOL_NAMES = listOf("aapt2", "aidl", "zipalign")

        /** 低于这个体积一定是没下全/被截断。 */
        private const val MIN_BYTES = 100_000L
    }
}
