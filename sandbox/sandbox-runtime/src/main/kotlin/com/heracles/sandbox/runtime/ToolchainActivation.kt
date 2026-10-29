/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 */

package com.heracles.sandbox.runtime

import java.io.File
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * **T2 编译环境**的激活入口（≈415 MB，用户主动触发）。
 *
 * ============================================================================
 * 三档模型（2026-10-28/29 用户裁定）
 * ============================================================================
 * | 档 | 内容 | 来源 | 谁触发 |
 * |---|---|---|---|
 * | **T0** | Alpine rootfs（3.77 MB 压缩 / 9 MB） | 内置 APK | 自动（首次使用，离线） |
 * | **T1** | aapt2 / aidl / zipalign | 内置 APK | 自动（`BundledTooltools`） |
 * | **T2** | JDK 17 + Gradle + android.jar | **联网下载** | **用户点「激活」** |
 *
 * 判据是「值不值得让所有人背这 415 MB」：aapt2 解析 APK 是高频操作，
 * 从源码编译是低频重活。所以只有 T2 要下载。
 *
 * ============================================================================
 * 为什么不做成"下载后 exec"
 * ============================================================================
 * Android 10+ 的 W^X 禁止 exec 应用数据目录里的文件。但这里装的**不是**要宿主
 * 直接 exec 的东西 —— JDK/Gradle 都是 **rootfs 里的 Linux 二进制**，由 PRoot
 * 在沙箱内 exec，不受 W^X 限制（与 aapt2 同理）。
 *
 * ============================================================================
 * 可靠性设计（415 MB 比 3.8 MB 更容易失败，这些不是可选项）
 * ============================================================================
 * 1. **多源**：每个组件有主源 + 备源（腾讯 / 官方），逐个试
 * 2. **sha256**：有校验值就必验；**没有就如实说"未校验"**，绝不假装校验过
 * 3. **原子安装**：由 [BuildSuiteInstaller] 保证（staging → rename）
 * 4. **断点续传**：下载用稳定 `.part` 文件 + HTTP Range（见 installer）
 * 5. **磁盘预检**：不够就直接拒绝并说清需要多少，不要下到一半失败
 * 6. **单飞**：同一时刻只有一个激活任务，重复调用复用同一个结果
 * 7. **版本标记**：装完写 `opt/t2/.heracles-t2-version`，以后改内容能识别
 */
class ToolchainActivation(
    /** rootfs 在宿主视角的根目录。 */
    private val rootfsHostRoot: File,
    /** 在沙箱内跑一条命令（用来 `apk add` 装 JDK）。失败要如实返回。 */
    private val runInSandbox: suspend (command: String, timeoutMs: Long) -> CommandOutcome,
) {

    private val installer = BuildSuiteInstaller(rootfsHostRoot)

    /** 单飞：并发调用只跑一次真活。 */
    private val lock = Mutex()

    /** 上一次激活的终态（单飞复用；成功后可清空重来）。 */
    private var lastResult: ActivationResult? = null

    // ---------------------------------------------------------------- 状态

    /** 当前 T2 是否就绪（**只读探测，不触发下载**）。 */
    fun status(): ToolchainStatus {
        val t2 = File(rootfsHostRoot, T2_DIR)
        val marker = File(t2, VERSION_MARKER)
        val jdkHome = File(rootfsHostRoot, "usr/lib/jvm/java-17-openjdk")
        val gradleBin = findGradleBin(File(t2, "gradle"))
        val androidJar = File(t2, "platform/android.jar")

        val parts = linkedMapOf(
            "jdk" to (File(jdkHome, "bin/javac").isFile || File(jdkHome, "bin/javac").exists()),
            "gradle" to (gradleBin != null),
            "androidJar" to (androidJar.isFile && androidJar.length() > 1_000_000),
        )
        return ToolchainStatus(
            installDir = t2.absolutePath,
            version = if (marker.isFile) marker.readText().trim() else "",
            parts = parts,
            ready = parts.values.all { it },
        )
    }

    // ---------------------------------------------------------------- 激活

    /**
     * 激活 T2。**幂等**：已就绪直接返回；并发调用只跑一次。
     *
     * @param onProgress `(已下载, 总字节, 阶段)`；总字节未知传 -1
     */
    suspend fun activate(
        onProgress: (downloaded: Long, total: Long, stage: String) -> Unit = { _, _, _ -> },
    ): ActivationResult = lock.withLock {
        // ① 已就绪 → 直接返回
        val current = status()
        if (current.ready) {
            return@withLock ActivationResult.alreadyReady(current)
        }
        // ② 单飞复用上次终态
        lastResult?.let { prev ->
            if (prev.success) return@withLock prev
        }

        if (!rootfsHostRoot.isDirectory) {
            return@withLock ActivationResult.failed(
                "T0 基础环境未就绪（${rootfsHostRoot.absolutePath} 不存在）—— 先激活沙箱基础环境",
            ).also { lastResult = it }
        }

        // ③ 磁盘预检：不够就别开始（下到一半失败最伤用户）
        val free = rootfsHostRoot.usableSpace
        if (free in 1..(REQUIRED_BYTES - 1)) {
            return@withLock ActivationResult.failed(
                "存储空间不足：需要约 ${REQUIRED_BYTES / 1024 / 1024} MB，" +
                    "当前可用 ${free / 1024 / 1024} MB。请清理后重试。",
            ).also { lastResult = it }
        }

        try {
            // ---- 步骤 1/3：JDK（走 Alpine 官方源，签名由 apk 自己保证）----
            onProgress(0, -1, "安装 JDK 17（约 284 MB）")
            val jdk = runInSandbox("$APK_INSTALL_JDK", JDK_TIMEOUT_MS)
            // ⚠️ 真机已知：`apk add` 在 PRoot 里常常**退出码非 0 但实际装好了**
            //   （`usr/bin/.apk.xxx: No such file or directory`）。所以判据是**装出来没有**，
            //   不是退出码。这一点 sandbox 的实测记录里有（见 porting-log）。
            val jdkBin = File(rootfsHostRoot, "usr/lib/jvm/java-17-openjdk/bin/javac")
            if (!jdkBin.exists()) {
                return@withLock ActivationResult.failed(
                    "JDK 安装失败：javac 不存在。apk 输出：${jdk.tail()}",
                ).also { lastResult = it }
            }
            onProgress(0, -1, "JDK 就绪")

            // ---- 步骤 2/3：Gradle（多源 + sha256）----
            val gradle = installWithFallback(GRADLE, onProgress)
            if (!gradle.success) {
                return@withLock ActivationResult.failed("Gradle 安装失败：${gradle.message}")
                    .also { lastResult = it }
            }

            // ---- 步骤 3/3：android.jar（多源；镜像无校验值，如实标注）----
            val platform = installWithFallback(PLATFORM_ANDROID_JAR, onProgress)
            if (!platform.success) {
                return@withLock ActivationResult.failed("android.jar 安装失败：${platform.message}")
                    .also { lastResult = it }
            }

            // ---- 写版本标记 ----
            val t2 = File(rootfsHostRoot, T2_DIR).apply { mkdirs() }
            File(t2, VERSION_MARKER).writeText("$VERSION\n")
            // 给沙箱内用的便捷链接：/opt/t2/gradle/bin/gradle 与 /opt/t2/platform/android.jar
            writeHelperScripts(t2)

            val done = status()
            if (!done.ready) {
                return@withLock ActivationResult.failed(
                    "安装完成但自检未通过（缺：${done.parts.filterValues { !it }.keys.joinToString()}）",
                ).also { lastResult = it }
            }
            onProgress(1, 1, "完成")
            return@withLock ActivationResult.ok(done).also { lastResult = it }
        } catch (e: Throwable) {
            return@withLock ActivationResult.failed(
                "${e.javaClass.simpleName}: ${e.message}",
            ).also { lastResult = it }
        }
    }

    /** **重置** T2（删掉重装）。只影响 T2，不动 T0/T1。 */
    fun reset(): Boolean {
        lastResult = null
        return File(rootfsHostRoot, T2_DIR).deleteRecursively()
    }

    // ---------------------------------------------------------------- 内部

    /** 逐源尝试（主源挂了自动换备源），都失败才返回失败。 */
    private suspend fun installWithFallback(
        spec: Component,
        onProgress: (Long, Long, String) -> Unit,
    ): BuildSuiteInstaller.SuiteInstallResult {
        val urls = listOf(spec.url) + spec.alternateUrls
        var lastFailure: BuildSuiteInstaller.SuiteInstallResult? = null
        for ((index, url) in urls.withIndex()) {
            val label = if (index == 0) spec.displayName else "${spec.displayName}（备源 $index）"
            onProgress(0, -1, label)
            val suite = BuildSuiteInstaller.SuiteComponent(
                id = spec.id,
                displayName = label,
                url = url,
                sha256 = spec.sha256,
                targetSubDir = spec.targetSubDir,
                archiveType = spec.archiveType,
                approxBytes = spec.approxBytes,
            )
            val r = installer.install(suite, onProgress)
            if (r.success) return r
            lastFailure = r
            onProgress(0, -1, "${spec.displayName} 主源失败，换源重试")
        }
        return lastFailure ?: BuildSuiteInstaller.SuiteInstallResult.failed("无可用下载源")
    }

    /** Gradle 解压后可能是 `gradle-8.14.2/bin/gradle`；递归找一次。 */
    private fun findGradleBin(dir: File): File? {
        if (!dir.isDirectory) return null
        val direct = File(dir, "bin/gradle")
        if (direct.isFile) return direct
        val children = dir.listFiles() ?: return null
        for (child in children) {
            if (child.isDirectory) {
                findGradleBin(child)?.let { return it }
            }
        }
        return null
    }

    /** 在 `/opt/t2` 下放两个稳定路径，避免上层去猜版本目录名。 */
    private fun writeHelperScripts(t2: File) {
        val gradleBin = findGradleBin(File(t2, "gradle"))
        if (gradleBin != null) {
            File(t2, "gradle-home").writeText(
                (gradleBin.parentFile?.parentFile ?: gradleBin).absolutePath.substring(
                    rootfsHostRoot.absolutePath.length,
                ).trimStart('/').let { "/$it" },
            )
        }
    }

    private fun CommandOutcome.tail(): String =
        (stderr.ifBlank { stdout }).trim().takeLast(300)

    /** 一次沙箱内命令的结果。 */
    data class CommandOutcome(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
    )

    /** T2 状态（**如实**：哪个装了、哪个没装）。 */
    data class ToolchainStatus(
        val installDir: String,
        val version: String,
        val parts: Map<String, Boolean>,
        val ready: Boolean,
    )

    /** 激活结果。 */
    data class ActivationResult(
        val success: Boolean,
        val status: ToolchainStatus?,
        val message: String,
        val alreadyReady: Boolean = false,
    ) {
        companion object {
            fun ok(s: ToolchainStatus) = ActivationResult(true, s, "编译环境已就绪")
            fun alreadyReady(s: ToolchainStatus) =
                ActivationResult(true, s, "编译环境已就绪（无需重复安装）", alreadyReady = true)
            fun failed(message: String) = ActivationResult(false, null, message)
        }
    }

    /** 一个 T2 组件（多源）。 */
    private data class Component(
        val id: String,
        val displayName: String,
        val url: String,
        val alternateUrls: List<String>,
        val sha256: String,
        val targetSubDir: String,
        val archiveType: BuildSuiteInstaller.ArchiveType,
        val approxBytes: Long,
    )

    companion object {
        /** T2 在 rootfs 内的目录。 */
        const val T2_DIR = "opt/t2"
        const val VERSION_MARKER = ".heracles-t2-version"

        /** T2 需要预留的磁盘（JDK 284 MiB + Gradle 131 MB + jar 25 MB + 解压余量）。 */
        const val REQUIRED_BYTES = 500L * 1024 * 1024

        /**
         * T2 内容版本。
         * 改了组件/版本号就 bump —— 已装用户下次 `status()` 能看出差异，
         * 由上层决定「提示重新激活」还是「继续用」。
         */
        const val VERSION = "t2-2026-10-29"

        private const val JDK_TIMEOUT_MS = 15 * 60 * 1000L

        /** Alpine 官方源（JDK 用 musl 版，必须 `apk add` —— Temurin 是 glibc，跑不起来）。 */
        private const val APK_INSTALL_JDK =
            "apk add --no-cache openjdk17-jdk 2>&1 || true"

        /** Gradle：腾讯镜像 → 官方（sha256 取自官方 `.sha256` 文件，已核对）。 */
        private val GRADLE = Component(
            id = "gradle",
            displayName = "Gradle 8.14.2（约 131 MB）",
            url = "https://mirrors.cloud.tencent.com/gradle/gradle-8.14.2-bin.zip",
            alternateUrls = listOf(
                "https://services.gradle.org/distributions/gradle-8.14.2-bin.zip",
            ),
            sha256 = "7197a12f450794931532469d4ff21a59ea2c1cd59a3ec3f89c035c3c420a6999",
            targetSubDir = "t2/gradle",
            archiveType = BuildSuiteInstaller.ArchiveType.ZIP,
            approxBytes = 137_394_077L,
        )

        /**
         * android.jar：腾讯 AndroidSDK 镜像。
         *
         * ⚠️ **sha256 为空 = 未校验**。镜像站点不提供校验值，官方 `dl.google.com`
         * 的校验值在 `repository2-3.xml` 里（要解析 XML 且随版本变）。
         * 这里**如实标注未校验**，而不是编一个假值或假装校验过。
         * 需要强校验时可以改走 `dl.google.com` + 解析 XML（TODO）。
         */
        private val PLATFORM_ANDROID_JAR = Component(
            id = "platform",
            displayName = "android.jar（约 25 MB）",
            url = "https://mirrors.cloud.tencent.com/AndroidSDK/platform-34-ext7_r03.zip",
            alternateUrls = listOf(
                "https://dl.google.com/android/repository/platform-34-ext7_r03.zip",
            ),
            sha256 = "",
            targetSubDir = "t2/platform",
            archiveType = BuildSuiteInstaller.ArchiveType.ZIP,
            approxBytes = 60_000_000L,
        )
    }
}
