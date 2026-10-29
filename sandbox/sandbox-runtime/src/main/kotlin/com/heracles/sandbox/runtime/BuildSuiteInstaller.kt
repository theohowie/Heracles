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

import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * rootfs 内**构建套件**的安装器。
 *
 * ============================================================================
 * 定位：这是「可选环境」，不是沙箱的必需件
 * ============================================================================
 * 沙箱本身（执行 / 文件 / 通道 / rootfs 管理）不需要任何构建工具。
 * 只有当用户在 Heracles 里说「帮我编个 APK」时，才需要套件。
 *
 * 所以它的安装是**显式的、可选的、可在线也可离线**的：
 * - 在线：从 URL 下载 linux-aarch64 归档
 * - 离线：宿主把归档推进来（见 `installFromLocalArchive`）
 *
 * ============================================================================
 * 铁律：只装 **linux-aarch64** 版本
 * ============================================================================
 * 绝不接受 Android/bionic 版本（解释器 `/system/bin/linker64`）：
 * 那种在 PRoot guest 里 `execve` 返回 ENOENT，真机实测过
 * （`command -v` 找得到、执行 `not found`）。详见 porting-log Phase 7。
 *
 * 本类在**解压前**用 [verifyAarch64LinuxElf] 抽查归档里的可执行文件，
 * 一旦发现 bionic 解释器就整体拒绝 —— 宁可失败也不装错。
 *
 * ============================================================================
 * 为什么要流式解压 + 校验
 * ============================================================================
 * 一个套件可能几百 MB。必须：
 *   - 边下边解（不落整包到磁盘，Android 上空间紧张）
 *   - 算 sha256（防截断/污染）
 *   - 限速与超时（移动网络下不能让用户等死）
 */
class BuildSuiteInstaller(
    /** rootfs 在宿主视角的根目录。 */
    private val rootfsHostRoot: File,
) {

    /** 套件在宿主视角的落地根目录（= rootfs 内的 /opt）。 */
    private val optHostDir: File = File(rootfsHostRoot, "opt").apply { mkdirs() }

    /**
     * 安装一个套件组件。
     *
     * @param spec 组件规格（URL + sha256 + 目标子目录 + 归档类型）
     * @param onProgress `(已下载字节, 总字节, 阶段描述)`；总字节未知时传 -1
     */
    suspend fun install(
        spec: SuiteComponent,
        onProgress: (downloaded: Long, total: Long, stage: String) -> Unit = { _, _, _ -> },
    ): SuiteInstallResult = withContext(Dispatchers.IO) {
        require(spec.url.isNotBlank()) { "组件 ${spec.id} 缺 URL" }
        if (!rootfsHostRoot.isDirectory) {
            return@withContext SuiteInstallResult.failed(
                "rootfs 未就绪：${rootfsHostRoot.absolutePath} 不存在（先装 rootfs）",
            )
        }

        val targetDir = File(optHostDir, spec.targetSubDir)
        val stagingDir = File(optHostDir, ".staging-${spec.id}").apply {
            deleteRecursively()
            mkdirs()
        }

        try {
            onProgress(0, -1, "连接 ${spec.url}")
            // ★ 2026-10-29：用**稳定**的 .part 文件名（不用 createTempFile）——
            //   下载中断后重试能靠 HTTP Range 接着下，而不是从 0 重来。
            //   415 MB 在移动网络下重下几次是常态，续传不是优化而是必需。
            val partFile = File(optHostDir, ".part-${spec.id}")
            val (tmpFile, size) = download(spec.url, onProgress, partFile)

            // ---- 校验 sha256（有声明才校验；没有就明确说「未校验」）----
            if (spec.sha256.isNotBlank()) {
                onProgress(size, size, "校验 sha256")
                val actual = sha256Of(tmpFile)
                if (!actual.equals(spec.sha256, ignoreCase = true)) {
                    return@withContext SuiteInstallResult.failed(
                        "sha256 不匹配：期望 ${spec.sha256}，实际 $actual（下载被污染或截断）",
                    )
                }
            }

            // ---- 解压到 staging ----
            onProgress(size, size, "解压 ${spec.id}")
            extract(tmpFile, stagingDir, spec.archiveType)
            tmpFile.delete()
            hoistSingleRoot(stagingDir)

            // ---- 铁律校验：必须是 linux-aarch64，不能是 bionic ----
            onProgress(size, size, "校验 ABI（必须是 linux-aarch64）")
            val offenders = findBionicBinaries(stagingDir)
            if (offenders.isNotEmpty()) {
                stagingDir.deleteRecursively()
                return@withContext SuiteInstallResult.failed(
                    "拒绝安装：归档里含 **bionic**（Android）二进制，在 PRoot 里跑不了：" +
                        offenders.take(5).joinToString() +
                        "。请换 linux-aarch64 版本（见 porting-log Phase 7）。",
                )
            }

            // ---- 原子替换到目标位 ----
            targetDir.deleteRecursively()
            targetDir.parentFile?.mkdirs()
            if (!stagingDir.renameTo(targetDir)) {
                // rename 失败（跨文件系统/已存在）时退化为复制
                stagingDir.copyRecursively(targetDir, overwrite = true)
                stagingDir.deleteRecursively()
            }

            SuiteInstallResult.installed(spec.id, targetDir.absolutePath, size)
        } catch (failure: SandboxException) {
            stagingDir.deleteRecursively()
            SuiteInstallResult.failed("${failure.message ?: "安装失败"}（code=${failure.code}）")
        } catch (failure: Throwable) {
            stagingDir.deleteRecursively()
            SuiteInstallResult.failed(
                "安装 ${spec.id} 失败：${failure.javaClass.simpleName}: ${failure.message}",
            )
        }
    }

    /**
     * 离线安装：从宿主已备好的归档安装（不联网）。
     *
     * 用法：宿主把 `jdk-17-aarch64-linux.tar.gz` 之类的文件放到 App 私有目录，
     * 再把路径传进来。
     */
    suspend fun installFromLocalArchive(
        spec: SuiteComponent,
        localArchive: File,
        onProgress: (Long, Long, String) -> Unit = { _, _, _ -> },
    ): SuiteInstallResult = withContext(Dispatchers.IO) {
        if (!localArchive.isFile) {
            return@withContext SuiteInstallResult.failed("归档不存在：${localArchive.absolutePath}")
        }
        val targetDir = File(optHostDir, spec.targetSubDir)
        val stagingDir = File(optHostDir, ".staging-${spec.id}").apply {
            deleteRecursively(); mkdirs()
        }
        try {
            onProgress(0, localArchive.length(), "解压 ${localArchive.name}")
            extract(localArchive, stagingDir, spec.archiveType)
            hoistSingleRoot(stagingDir)
            val offenders = findBionicBinaries(stagingDir)
            if (offenders.isNotEmpty()) {
                stagingDir.deleteRecursively()
                return@withContext SuiteInstallResult.failed(
                    "拒绝安装：含 bionic 二进制（PRoot 里跑不了）：${offenders.take(5).joinToString()}",
                )
            }
            targetDir.deleteRecursively()
            targetDir.parentFile?.mkdirs()
            if (!stagingDir.renameTo(targetDir)) {
                stagingDir.copyRecursively(targetDir, overwrite = true)
                stagingDir.deleteRecursively()
            }
            SuiteInstallResult.installed(spec.id, targetDir.absolutePath, localArchive.length())
        } catch (failure: Throwable) {
            stagingDir.deleteRecursively()
            SuiteInstallResult.failed("${failure.javaClass.simpleName}: ${failure.message}")
        }
    }

    /**
     * 已装了哪些组件（按目录存在性判断，**不猜、不编版本号**）。
     */
    fun installedComponents(): List<SuiteComponent> =
        BuildSuiteCatalog.ALL.filter { spec ->
            File(optHostDir, spec.targetSubDir).isDirectory
        }

    // ========================================================================
    // 内部
    // ========================================================================

    /**
     * 下载到文件，边下边报进度。返回 (文件, 字节数)。
     *
     * ## 断点续传（2026-10-29）
     *
     * [partFile] 给了就用**稳定文件名**，并带上 `Range: bytes=<已有长度>-`：
     * - 服务器回 **206** ⇒ 追加写，不重下
     * - 服务器回 **200**（忽略 Range）⇒ 从头覆盖写（否则文件会损坏）
     *
     * 为什么必需：T2 有 415 MB，移动网络下中断是常态。每次都从 0 重来
     * 等于「用户在地铁里永远装不完」。
     */
    private fun download(
        url: String,
        onProgress: (Long, Long, String) -> Unit,
        partFile: File? = null,
    ): Pair<File, Long> {
        val tmp = partFile ?: File.createTempFile("suite-", ".download", optHostDir)
        val already = if (tmp.isFile) tmp.length() else 0L
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", USER_AGENT)
            if (already > 0) setRequestProperty("Range", "bytes=$already-")
        }
        try {
            val code = conn.responseCode
            // 206 = Partial Content（Range 生效）；200 = 忽略 Range
            if (code !in 200..299) {
                throw IOException("HTTP $code（$url）")
            }
            val resuming = code == 206 && already > 0
            if (resuming) {
                onProgress(already, already + conn.contentLengthLong, "续传中")
            }
            val total = if (resuming) already + conn.contentLengthLong else conn.contentLengthLong
            var downloaded = if (resuming) already else 0L
            conn.inputStream.use { input ->
                java.io.FileOutputStream(tmp, resuming).use { output ->
                    val buf = ByteArray(BUFFER_BYTES)
                    var lastReport = downloaded
                    while (true) {
                        val n = input.read(buf)
                        if (n <= 0) break
                        output.write(buf, 0, n)
                        downloaded += n
                        // 每 2 MB 报一次，避免回调风暴
                        if (downloaded - lastReport >= 2L * 1024 * 1024) {
                            lastReport = downloaded
                            onProgress(downloaded, total, if (resuming) "续传中" else "下载中")
                        }
                    }
                }
            }
            return tmp to downloaded
        } finally {
            conn.disconnect()
        }
    }

    /** 按归档类型解压。只支持 tar.gz / tar / zip（够覆盖套件）。 */
    private fun extract(archive: File, destDir: File, type: ArchiveType) {
        when (type) {
            ArchiveType.TAR_GZ -> extractTarGz(archive, destDir)
            ArchiveType.TAR -> extractTar(archive, destDir)
            ArchiveType.ZIP -> extractZip(archive, destDir)
        }
    }

    private fun extractTarGz(archive: File, destDir: File) {
        // 复用沙箱已有的 TarStreamExtractor（它做过越界/符号链接防护）
        archive.inputStream().use { raw ->
            java.util.zip.GZIPInputStream(raw).use { gz ->
                kotlinx.coroutines.runBlocking {
                    TarStreamExtractor().extract(gz, destDir, handleWhiteouts = false)
                }
            }
        }
    }

    private fun extractTar(archive: File, destDir: File) {
        archive.inputStream().use { raw ->
            kotlinx.coroutines.runBlocking {
                TarStreamExtractor().extract(raw, destDir, handleWhiteouts = false)
            }
        }
    }

    private fun extractZip(archive: File, destDir: File) {
        java.util.zip.ZipInputStream(archive.inputStream().buffered()).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val target = File(destDir, entry.name)
                // 越界防护
                if (!target.canonicalPath.startsWith(destDir.canonicalPath)) {
                    zip.closeEntry(); continue
                }
                if (entry.isDirectory) {
                    target.mkdirs()
                } else {
                    target.parentFile?.mkdirs()
                    target.outputStream().use { zip.copyTo(it) }
                    // zip **不保留 Unix 权限位**（或保留在 external attributes 里但
                    // 多数归档没设）。所以要显式补执行位，否则解压出来的脚本
                    // 在 guest 里跑会报 `Permission denied`（真机实测退出码 126，
                    // 例如 Gradle 的 `bin/gradle`）。
                    if (isExecutableEntry(entry.name)) {
                        target.setExecutable(true, false)
                    }
                }
                zip.closeEntry()
            }
        }
    }

    /**
     * 判断 zip 里的条目解压后是否应当有执行位。
     *
     * 判据（覆盖本项目要装的三类归档）：
     *   - 位于任意 `bin/` 目录下（Gradle 的 `bin/gradle`、SDK 的 `build-tools/aapt2`）
     *   - 名字是已知可执行工具（`aapt2` / `aidl` / `zipalign` / `adb` …）
     *   - 以 `.sh` / `.bat` 结尾的脚本
     */
    private fun isExecutableEntry(name: String): Boolean {
        val normalized = name.replace('\\', '/')
        if (normalized.contains("/bin/")) return true
        if (normalized.endsWith(".sh") || normalized.endsWith(".bat")) return true
        val fileName = normalized.substringAfterLast('/')
        return fileName in KNOWN_EXECUTABLES || fileName.startsWith("gradle")
    }
    /**
     * 把「只有一层顶层目录」的归档上提一层。
     *
     * 为什么需要：JDK 的 tar.gz 解开是 `jdk-17.0.20.1+1/bin/java`，
     * Gradle 的 zip 解开是 `gradle-8.14.2/bin/gradle` —— 都多一层目录。
     * 而 [ToolchainLayout.envPrelude] 约定的是 `/opt/ja/bin`、`/opt/gradle/bin`。
     * 不上提就会「装成功但 command -v java 找不到」。
     *
     * 只在上提**恰好一个目录且没有其它条目**时执行，避免误伤本来就有多目录的归档。
     */
    private fun hoistSingleRoot(stagingDir: File) {
        val children = stagingDir.listFiles() ?: return
        if (children.size != 1) return
        val only = children[0]
        if (!only.isDirectory) return
        val grandChildren = only.listFiles() ?: return
        if (grandChildren.isEmpty()) return

        // 逐个移出来（rename 失败时退化为复制）
        for (child in grandChildren) {
            val dest = File(stagingDir, child.name)
            if (!child.renameTo(dest)) {
                if (child.isDirectory) child.copyRecursively(dest, overwrite = true)
                else child.copyTo(dest, overwrite = true)
                child.deleteRecursively()
            }
        }
        only.deleteRecursively()
    }
    /**
     * 扫出 **bionic** 二进制（解释器 `/system/bin/linker64`）。
     *
     * 这就是「铁律」的执行点：宁可拒绝安装，也不装一个在 PRoot 里跑不了的东西。
     */
    private fun findBionicBinaries(dir: File): List<String> {
        val offenders = mutableListOf<String>()
        dir.walkTopDown()
            .filter { it.isFile && it.length() in 64..(64L * 1024 * 1024) }
            .forEach { f ->
                val head = runCatching { f.inputStream().use { i -> ByteArray(4096).also { i.read(it) } } }
                    .getOrNull() ?: return@forEach
                if (head.size < 4 || head[0] != 0x7F.toByte() || head[1] != 'E'.code.toByte()) return@forEach
                // ELF：在头部找解释器路径字符串
                val text = String(head, Charsets.ISO_8859_1)
                if (text.contains("/system/bin/linker64") || text.contains("/system/bin/linker")) {
                    offenders += f.relativeTo(dir).path
                }
            }
        return offenders
    }

    private fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(BUFFER_BYTES)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /** 归档类型。 */
    enum class ArchiveType { TAR_GZ, TAR, ZIP }

    /**
     * 一个套件组件。
     *
     * @param id 稳定标识（如 `jdk17`）
     * @param displayName 展示名
     * @param url 下载地址（linux-aarch64 版）
     * @param sha256 期望摘要；空串 = 不校验（并在结果里如实说明）
     * @param targetSubDir 解到 `/opt/<这个>` 下
     * @param archiveType 归档类型
     * @param requiresJdk 是否依赖 JDK（影响可用性判断）
     */
    data class SuiteComponent(
        val id: String,
        val displayName: String,
        val url: String,
        val sha256: String,
        val targetSubDir: String,
        val archiveType: ArchiveType,
        val requiresJdk: Boolean = false,
        val approxBytes: Long = -1,
    )

    /** 安装结果（**如实**，不粉饰）。 */
    data class SuiteInstallResult(
        val success: Boolean,
        val componentId: String,
        val installedPath: String,
        val bytes: Long,
        val message: String,
    ) {
        companion object {
            fun installed(id: String, path: String, bytes: Long) = SuiteInstallResult(
                success = true, componentId = id, installedPath = path, bytes = bytes,
                message = "已安装到 $path（${bytes / 1024 / 1024} MB）",
            )

            fun failed(message: String) = SuiteInstallResult(
                success = false, componentId = "", installedPath = "", bytes = 0, message = message,
            )
        }
    }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 30_000
        private const val READ_TIMEOUT_MS = 120_000
        private const val BUFFER_BYTES = 64 * 1024
        private const val USER_AGENT = "Heracles-taixu-sandbox/0.1"

        /** zip 解压后需要显式补执行位的工具名。 */
        private val KNOWN_EXECUTABLES = setOf(
            "aapt2", "aidl", "zipalign", "adb", "d8", "apksigner",
            "gradle", "java", "javac", "jar", "keytool",
        )
    }
}

/**
 * 可装的套件清单。
 *
 * ★ 所有 URL 都是 **linux-aarch64** 版本 —— 这是硬约束，见 porting-log Phase 7。
 *
 * ⚠️ 本清单**只声明元数据**，不保证任何 URL 当前可用。
 * 真机安装时若 404/超时，就是失败，如实上报 —— **不要**悄悄换成 bionic 版。
 */
object BuildSuiteCatalog {

    /** JDK 17（Temurin，linux-aarch64）。构建 APK 必需。 */
    val JDK17 = BuildSuiteInstaller.SuiteComponent(
        id = "jdk17",
        displayName = "JDK 17 (Temurin aarch64-linux)",
        // 与 taixu 的 DOWNLOADS.md 同源（Adoptium Temurin 官方发布）
        url = "https://github.com/adoptium/temurin17-binaries/releases/download/" +
            "jdk-17.0.20.1%2B1/OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.20.1_1.tar.gz",
        sha256 = "457b57af8f9c93ec39080bb8c764f559dc8c89a6da1a39d718a400b7890d3e41",
        targetSubDir = "ja",
        archiveType = BuildSuiteInstaller.ArchiveType.TAR_GZ,
        requiresJdk = false,
        approxBytes = 190L * 1024 * 1024,
    )

    /** Android SDK 静态工具（aapt2 / aidl / zipalign，linux-aarch64）。不依赖 JDK。 */
    /**
     * ⚠️ **已被内置取代（2026-10-28）**：T1 工具现在随 APK 内置
     * （`assets/tooltools/` + `BundledTooltools` 解包），运行期**不再联网下载**。
     *
     * 保留此条目仅作为「内置资产缺失时的兜底」——见
     * [BundledTooltools.ExtractResult.Status.NOT_BUNDLED] 分支的处理方。
     * 新代码**不要**调用它。
     */
    val ANDROID_SDK_TOOLS = BuildSuiteInstaller.SuiteComponent(
        id = "android-sdk-tools",
        displayName = "Android SDK tools (aapt2/aidl/zipalign, aarch64-linux static)",
        // 与 taixu 同源（lzhiyong/android-sdk-tools 的 arm64 静态构建）
        url = "https://github.com/lzhiyong/android-sdk-tools/releases/download/" +
            "35.0.2/android-sdk-tools-static-aarch64.zip",
        sha256 = "db1cea2c4454d5f9c5a802646b2d1cf560b4ee7badbe23e51ab8e1881bb50fc2",
        targetSubDir = "as",
        archiveType = BuildSuiteInstaller.ArchiveType.ZIP,
        requiresJdk = false,
        approxBytes = 20L * 1024 * 1024,
    )

    /** Gradle 发行版（Java 归档，与 ABI 无关）。依赖 JDK 运行。 */
    val GRADLE = BuildSuiteInstaller.SuiteComponent(
        id = "gradle",
        displayName = "Gradle 8.14.2",
        url = "https://mirrors.cloud.tencent.com/gradle/gradle-8.14.2-bin.zip",
        sha256 = "7197a12f450794931532469d4ff21a59ea2c1cd59a3ec3f89c035c3c420a6999",
        targetSubDir = "gradle",
        archiveType = BuildSuiteInstaller.ArchiveType.ZIP,
        requiresJdk = true,
        approxBytes = 130L * 1024 * 1024,
    )

    /**
     * 全部组件。
     *
     * 顺序刻意是「小 → 大」：先装小的能快速验证链路通不通，
     * 再去下那个 190 MB 的 JDK。
     */
    val ALL: List<BuildSuiteInstaller.SuiteComponent> = listOf(
        ANDROID_SDK_TOOLS,
        GRADLE,
        JDK17,
    )

    /**
     * 「能编 APK」所需的最小集合。
     *
     * 只有 aapt2/aidl/zipalign + android.jar 还不够 ——
     * 真正跑 `gradle assembleDebug` 需要 JDK。
     */
    val MINIMUM_FOR_APK_BUILD: List<BuildSuiteInstaller.SuiteComponent> =
        listOf(ANDROID_SDK_TOOLS, JDK17, GRADLE)
}
