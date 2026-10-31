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
        val jdkHome = File(rootfsHostRoot, JDK_DIR)
        val gradleBin = findGradleBin(File(t2, "gradle"))
        val androidJar = File(t2, "platform/android.jar")

        val parts = linkedMapOf(
            "jdk" to (File(jdkHome, "bin/javac").isFile || File(jdkHome, "bin/javac").exists()),
            "gradle" to (gradleBin != null),
            "androidJar" to (androidJar.isFile && androidJar.length() > 1_000_000),
        )
        // 只增字段（T2-6）：UI 要能直接说「缺 JDK 17 / 缺 Gradle / 缺 android.jar」，
        // 而不是把 parts 的 key 原样翻给用户；占用空间让「卸载能释放多少」有依据。
        // ⚠️ JDK 也是 T2 的一部分（apk add 装进 rootfs 的 usr/lib/jvm），必须一起算进来，
        //    否则"激活占 415MB、卸载只释放 130MB"会对不上账。
        val missing = parts.filterValues { !it }.keys.map { PART_LABELS[it] ?: it }
        val occupied = directorySizeNoFollowLinks(t2) + directorySizeNoFollowLinks(jdkHome)
        return ToolchainStatus(
            installDir = t2.absolutePath,
            version = if (marker.isFile) marker.readText().trim() else "",
            parts = parts,
            ready = parts.values.all { it },
            occupiedBytes = occupied,
            missing = missing,
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
            // ★ 自愈（2026-10-29）：老用户装 T2 时还没有 PATH 链接这一步，
            //   不能因为"已就绪"就跳过 —— 否则 `gradle` 永远 not found。
            //   `ln -sf` 幂等，代价可忽略。
            linkIntoPath(onProgress)
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
            onProgress(0, -1, "准备网络（DNS）")
            // ★ 必须先修 DNS（2026-10-29 真机抓到）：Alpine minirootfs **不带**
            //   /etc/resolv.conf，`apk add` 会立刻失败（"temporary error"）。
            //   这是沙箱内所有联网操作的前提，不只 T2。
            val net = runInSandbox(PREPARE_NETWORK, 30_000)
            onProgress(0, -1, "安装 JDK 17（约 284 MB）")
            val jdk = runInSandbox(APK_INSTALL_JDK, JDK_TIMEOUT_MS)
            // ⚠️ 真机已知：`apk add` 在 PRoot 里常常**退出码非 0 但实际装好了**
            //   （`usr/bin/.apk.xxx: No such file or directory`）。所以判据是**装出来没有**，
            //   不是退出码。这一点 sandbox 的实测记录里有（见 porting-log）。
            val jdkBin = File(rootfsHostRoot, "$JDK_DIR/bin/javac")
            if (!jdkBin.exists()) {
                return@withLock ActivationResult.failed(
                    "JDK 安装失败：javac 不存在。\n" +
                        "  查过的路径：${jdkBin.absolutePath}（exists=${jdkBin.exists()}）\n" +
                        "  rootfs 根：${rootfsHostRoot.absolutePath}\n" +
                        "  usr/lib/jvm 内容：${File(rootfsHostRoot, "usr/lib/jvm").list()?.joinToString() ?: "读不到"}\n" +
                        "  DNS 准备输出：${net.tail(200)}\n" +
                        "  apk add 输出（exit=${jdk.exitCode}）：${jdk.tail(900)}",
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
              // ★ 把 gradle 挂进 PATH（否则 `gradle` 报 not found，exit 127 —— 真机抓到）
              linkIntoPath(onProgress)

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

    /**
     * **真的卸载 T2**（T2-6）—— 不只是 `rm -rf /opt/t2`。
     *
     * ## 为什么必须比"删一个目录"复杂
     * T2 由三部分组成，装法完全不同：
     * | 部分 | 装法 | 卸载方式 |
     * |---|---|---|
     * | Gradle + android.jar + 版本标记 | 宿主侧下载解压到 `opt/t2` | 删目录即可 |
     * | **JDK 17** | **沙箱内 `apk add openjdk17-jdk`** | 必须 `apk del`（否则 apk 数据库仍记「已安装」） |
     * | gradle 的 PATH 链接 | 沙箱内 `ln -s` 到 `/usr/local/bin/gradle` | 删链接 |
     *
     * ⚠️ JDK 这一步**不能只删目录**：`apk add` 的数据库（`/lib/apk/db/installed`）仍会
     * 认为 openjdk17-jdk 已安装，下次 `activate()` 里 `apk add --no-cache` 会**直接跳过**，
     * 于是 javac 永远缺失 —— 用户会看到"重装也没用"。所以先 `apk info -e` 探测、
     * 需要时 `apk del`，再兜底删宿主侧残留。
     *
     * 边界（**只动 T2**）：
     * - 不碰 rootfs 本身（T0）、不动 `opt/as`（T1 内置工具）、不动 `workspace/` 用户工作区；
     * - `apk del` 只点名 `openjdk17-jdk`，不跑 `apk del --purge`、不重装 rootfs。
     *
     * @param deleteDir 删除注入点（单测模拟"删不掉"用；默认真删）
     * @return 卸载结果：删了什么 / 失败项 / 释放多少 / 当前缺失项（**只增字段**）
     */
    suspend fun reset(
        deleteDir: (File) -> Boolean = { dir -> dir.deleteRecursively() },
    ): ToolchainResetResult = lock.withLock {
        val t2 = File(rootfsHostRoot, T2_DIR)
        val jdkHome = File(rootfsHostRoot, JDK_DIR)
        val gradleLink = File(rootfsHostRoot, GRADLE_LINK)
        val beforeBytes = directorySizeNoFollowLinks(t2) + directorySizeNoFollowLinks(jdkHome)

        val removed = mutableListOf<String>()
        val failed = mutableListOf<ResetFailure>()
        val warnings = mutableListOf<String>()

        // ---- ① JDK：先让 apk 数据库跟上（失败不阻断，但要如实记）----
        val jdkInApkDb = runCatching {
            runInSandbox(APK_HAS_JDK, APK_QUERY_TIMEOUT_MS).exitCode == 0
        }.getOrDefault(false)
        if (jdkInApkDb) {
            val del = runCatching { runInSandbox(APK_DEL_JDK, APK_DEL_TIMEOUT_MS) }.getOrNull()
            if (del == null || del.exitCode != 0) {
                warnings += "apk del openjdk17-jdk 未成功（exit=${del?.exitCode ?: "异常"}）" +
                    (del?.let { "：${it.tail(200)}" } ?: "") +
                    "；JDK 文件会由宿主侧删除，但 apk 数据库可能仍标记" +
                    "「已安装」⇒ 下次激活可能跳过 JDK 安装。"
            }
        }

        // ---- ② 宿主侧删除（apk del 可能只删了一部分，或根本没跑）----
        listOf(t2, jdkHome, gradleLink).forEach { target ->
            if (!target.exists()) return@forEach
            val guest = guestPathOf(rootfsHostRoot, target)
            var failureReason: String? = null
            val ok = try {
                deleteDir(target)
            } catch (failure: Throwable) {
                failureReason = "${failure.javaClass.simpleName}: ${failure.message}"
                false
            }
            // 以**实际存在性**为准，不信删除函数的返回值：`deleteRecursively()` 在
            // "删一半失败" 时会返回 false 但目标可能已不存在；反过来也可能返回 true
            // 却因权限/只读挂载留下残留。卸载结果必须反映磁盘真相。
            if (!target.exists()) {
                removed += guest
            } else {
                failed += ResetFailure(
                    guest,
                    failureReason
                        ?: if (ok) {
                            "删除调用返回成功但路径仍存在（残留）"
                        } else {
                            "删除失败（路径仍存在：${target.absolutePath}）"
                        },
                )
            }
        }

        // ---- ③ 复核：status() 必须变成"未就绪"，否则就是有残留 ----
        val after = status()
        val afterBytes = directorySizeNoFollowLinks(t2) + directorySizeNoFollowLinks(jdkHome)
        val freedBytes = (beforeBytes - afterBytes).coerceAtLeast(0L)
        if (after.ready) {
            failed += ResetFailure(
                after.installDir,
                "卸载后自检仍显示就绪（可能有残留文件：${after.parts}）",
            )
        }
        val success = failed.isEmpty()
        val message = buildString {
            append(if (success) "已卸载 T2 编译环境" else "T2 卸载未完全成功")
            append("：释放 ${formatBytes(freedBytes)}")
            if (removed.isEmpty()) {
                append("（本来就没装，没有可删的文件）")
            } else {
                append("，删除 ${removed.size} 项（${removed.joinToString("、")}）")
            }
            if (failed.isNotEmpty()) {
                append("；失败 ${failed.size} 项：")
                append(failed.joinToString("；") { "${it.path}（${it.reason}）" })
            }
            if (warnings.isNotEmpty()) {
                append("；注意：")
                append(warnings.joinToString("；"))
            }
            append("；当前缺失：")
            append(if (after.missing.isEmpty()) "无（意外）" else after.missing.joinToString("、"))
        }
        lastResult = null
        ToolchainResetResult(
            success = success,
            ready = after.ready,
            installDir = after.installDir,
            removed = removed,
            failed = failed,
            freedBytes = freedBytes,
            missing = after.missing,
            message = message,
        )
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

    /**
     * 把 T2 的可执行文件挂进 PATH（**沙箱内**执行 `ln -s`）。
     *
     * ## 为什么必须有这一步（2026-10-29 真机抓到）
     *
     * 装完 T2 后模型直接跑 `gradle --version`，得到：
     *
     *     /bin/sh: gradle: not found      EXIT=127
     *
     * 因为 gradle 只躺在 `/opt/t2/gradle/bin/gradle`，**不在 PATH** 上 ——
     * 装了却用不了，等于没装。用户和模型都不会去猜那个绝对路径。
     *
     * 做法：在 rootfs 内建 `/usr/local/bin/gradle` 软链（Alpine 默认 PATH 含该目录）。
     * 用沙箱内 `ln -s` 而不是宿主建链接：rootfs 是 Linux 布局，PRoot 里建最稳。
     */
    /** 供宿主调用：修一次 PATH 链接（幂等）。成功返回 true。 */
    suspend fun repairPath(): Boolean = linkIntoPath { _, _, _ -> }

    private suspend fun linkIntoPath(
        onProgress: (Long, Long, String) -> Unit,
    ): Boolean {
        onProgress(0, -1, "把 gradle 挂进 PATH")
        val r = runInSandbox(LINK_INTO_PATH, 60_000)
        // 失败不致命（仍可用绝对路径调用），但要说清楚
        if (r.exitCode != 0) {
            onProgress(
                0, -1,
                "gradle 挂 PATH 失败（可用 /opt/t2/gradle/bin/gradle）：${r.tail(200)}",
            )
        }
        return r.exitCode == 0
    }

    private fun CommandOutcome.tail(max: Int = 300): String =
        (stderr.ifBlank { stdout }).trim().takeLast(max)

    /** 一次沙箱内命令的结果。 */
    data class CommandOutcome(
        val exitCode: Int,
        val stdout: String,
        val stderr: String,
    )

    /** T2 状态（**如实**：哪个装了、哪个没装）。只增字段，旧读者的 `parts`/`ready` 语义不变。 */
    data class ToolchainStatus(
        val installDir: String,
        val version: String,
        val parts: Map<String, Boolean>,
        val ready: Boolean,
        /**
         * T2 当前占用（`/opt/t2` + JDK 目录，字节）。UI 用来显示「卸载可释放 N MB」。
         *
         * 口径与 `du -sb` 一致（见 [directorySizeNoFollowLinks]）：**不跟随符号链接**，
         * 读不到的目录跳过而不是让整次查询失败。
         */
        val occupiedBytes: Long = 0L,
        /**
         * 缺失项（**人话**，如 `JDK 17（javac）`）。`ready == true` 时为空。
         *
         * 为什么不用 `parts` 的 key 直接给 UI：`androidJar` 这种内部字段名对用户没有意义。
         */
        val missing: List<String> = emptyList(),
    )

    /** 卸载失败的一项（路径 + 人话原因；给 UI 直接显示）。 */
    data class ResetFailure(
        val path: String,
        val reason: String,
    )

    /**
     * T2 卸载结果（T2-6，**只增字段**；旧的 `reset(): Boolean` 语义落在 [success]）。
     *
     * @param success 全部删除项都成功 **且** 卸载后 `status().ready == false`
     * @param ready 卸载后重新探测的 `status().ready`（正常应为 false；true 说明有残留）
     * @param installDir T2 安装目录（宿主绝对路径，`/opt/t2` 对应的宿主位置）
     * @param removed 实际删掉的路径清单（**沙箱视角**，如 `/opt/t2`，与用户看到的路径一致）
     * @param failed 删除失败项；为空表示干净卸载
     * @param freedBytes 释放的字节数（删前占用 − 删后占用；**实测差**，不是估算）
     * @param missing 卸载后仍缺失的项（正常 = 三项全缺 ⇒ 下次激活会重新装）
     * @param message 给人看的一句话（含失败原因/注意事项）
     */
    data class ToolchainResetResult(
        val success: Boolean,
        val ready: Boolean,
        val installDir: String,
        val removed: List<String>,
        val failed: List<ResetFailure>,
        val freedBytes: Long,
        val missing: List<String>,
        val message: String,
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

        /**
         * JDK 在 rootfs 内的目录（`apk add openjdk17-jdk` 装到这里）。
         *
         * ★ 卸载必须一起删：JDK 是 T2 体积的大头（≈284 MB），只删 `/opt/t2`
         *   会出现"卸载成功但空间没释放"，且 `status()` 里 jdk 仍为 true。
         */
        const val JDK_DIR = "usr/lib/jvm/java-17-openjdk"

        /** gradle 的 PATH 链接（`/usr/local/bin/gradle` → `/opt/t2/gradle/bin/gradle`）。 */
        const val GRADLE_LINK = "usr/local/bin/gradle"

        /** 分项 key → 给人看的缺失项文案（`status().missing` 用）。 */
        private val PART_LABELS = mapOf(
            "jdk" to "JDK 17（javac）",
            "gradle" to "Gradle（bin/gradle）",
            "androidJar" to "android.jar（platform/android.jar）",
        )

        /** 判断 JDK 是否**在 apk 数据库里**（决定要不要先 `apk del`）。 */
        private const val APK_HAS_JDK = "apk info -e openjdk17-jdk >/dev/null 2>&1"

        /** 卸载 JDK（让 apk 数据库一致；否则下次 `apk add` 会跳过）。 */
        private const val APK_DEL_JDK = "apk del openjdk17-jdk 2>&1"

        private const val APK_QUERY_TIMEOUT_MS = 20_000L
        private const val APK_DEL_TIMEOUT_MS = 180_000L

        /**
         * 把宿主绝对路径翻成**沙箱视角**（给 `removed` 清单用；用户认的是 `/opt/t2`）。
         *
         * 注意：沙箱视角永远是 POSIX 风格（`/a/b`），而宿主可能是 Windows 跑单测
         * （`C:\…\opt\t2`）—— 所以这里统一把分隔符归一成 `/`，否则单测机上会得到
         * `/\opt\t2` 这种既不宿主也不沙箱的怪路径。
         */
        private fun guestPathOf(rootfsHostRoot: File, file: File): String {
            val root = rootfsHostRoot.absolutePath.replace('\\', '/').trimEnd('/')
            val abs = file.absolutePath.replace('\\', '/')
            return if (abs.startsWith(root)) "/" + abs.removePrefix(root).trimStart('/') else abs
        }

        private fun formatBytes(bytes: Long): String = when {
            bytes >= 1024L * 1024 * 1024 ->
                String.format(java.util.Locale.US, "%.2f GB", bytes / 1024.0 / 1024.0 / 1024.0)
            bytes >= 1024L * 1024 ->
                String.format(java.util.Locale.US, "%.1f MB", bytes / 1024.0 / 1024.0)
            bytes >= 1024 ->
                String.format(java.util.Locale.US, "%.1f KB", bytes / 1024.0)
            else -> "$bytes B"
        }

        /** T2 需要预留的磁盘（JDK 284 MiB + Gradle 131 MB + jar 25 MB + 解压余量）。 */
        const val REQUIRED_BYTES = 500L * 1024 * 1024

        /**
         * T2 内容版本。
         * 改了组件/版本号就 bump —— 已装用户下次 `status()` 能看出差异，
         * 由上层决定「提示重新激活」还是「继续用」。
         */
        const val VERSION = "t2-2026-10-29"

        private const val JDK_TIMEOUT_MS = 15 * 60 * 1000L

        /**
         * **准备网络**：Alpine minirootfs 不带 `/etc/resolv.conf`，任何联网操作
         * （`apk add`、`wget`）都会立刻失败。这里只在**缺失/为空**时写入，
         * 不覆盖用户已改过的配置。
         *
         * DNS 用的是国内公共 DNS（阿里 223.5.5.5 / 114DNS）—— 沙箱里的解析
         * 不能指望宿主 VPN 的 DNS（PRoot 里走的是真实网络栈）。
         */
        private const val PREPARE_NETWORK =
            "mkdir -p /etc 2>/dev/null; " +
                "if [ ! -s /etc/resolv.conf ]; then " +
                "printf 'nameserver 223.5.5.5\\nnameserver 114.114.114.114\\n" +
                "nameserver 119.29.29.29\\n' > /etc/resolv.conf; " +
                "echo wrote; else echo exists; fi; " +
                "echo ---; cat /etc/resolv.conf"

        /**
         * 把 gradle 挂进 PATH（rootfs 内执行）。
         *
         * 只链接 gradle：javac/java 由 `apk add openjdk17-jdk` 自己放进了
         * `/usr/bin`（实测 `javac -version` 直接可用），不用我们再管。
         * 幂等：`ln -sf` 重复执行安全。
         */
        private const val LINK_INTO_PATH =
            "mkdir -p /usr/local/bin && " +
                "chmod +x /opt/t2/gradle/bin/gradle 2>/dev/null; " +
                "ln -sf /opt/t2/gradle/bin/gradle /usr/local/bin/gradle && " +
                "echo linked; command -v gradle; gradle --version 2>&1 | head -4"

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
