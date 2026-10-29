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
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/OciRegistryClient.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/OciImageReference.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/OciLayerStore.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/OciManifestStore.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/RootfsHttpPolicy.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/RootfsValidator.kt
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * 从 OCI Registry 拉取并安装完整 rootfs：
 *
 *   1. 解析镜像引用（`docker.io/library/alpine:3.20` / `alpine` / `x@sha256:...`）
 *   2. 匿名 token 流程（Docker Hub 的 `/v2/` 需要 Bearer token）
 *   3. 取 manifest（manifest list ⇒ 挑 linux/arm64 那一份）
 *   4. 逐个 layer：下载 blob → **真算 sha256 校验** → 解压 → 流式 tar 解包
 *   5. 校验结果像个 rootfs（有 os-release / bin/sh）
 *
 * ============================================================================
 * 与上游 taixu OciRegistryClient 的差异（逐条 —— 这是删减最多的一块）
 * ============================================================================
 * 1. **不引入 OkHttp**（上游用 OkHttp + 拦截器做 HTTPS→HTTP 降级防护）。
 *    沙箱 build.gradle.kts 的依赖白名单只有 androidx.core.ktx + coroutines，
 *    所以改用 `java.net.HttpURLConnection`。HTTPS→HTTP 降级防护显式实现：
 *    检查每一跳的 URL scheme（[openConnection] 里做）。
 * 2. **不引入 kotlinx.serialization**（上游用 JsonObject 解析 manifest）。
 *    本文件带一个**只处理所需子集**的极简 JSON 解析器（[MiniJson]）：
 *    只支持 object/array/string/number/bool/null，够读 manifest 与 token，
 *    不做任何转义以外的东西。
 * 3. **不移植 DaoCloud 镜像加速线路**（上游 AUTO 策略先试 daoCloud 再试官方）。
 *    沙箱只提供 Docker Hub 官方 + 可配置的 registry base 覆盖
 *    （[registryBaseOverride]，给自建/镜像站用）。理由：沙箱不该内置第三方
 *    镜像站的信任假设 —— 那是宿主策略。
 * 4. **不移植 `LxcImagesClient`**（TUNA lxc-images 回退）。沙箱的离线 fallback
 *    是 [BundledRootfs]（APK 内置），不是再拉一个网上的 tar。
 * 5. **不移植 `ElfInspector` 的 ARM64 ELF 校验**。上游要校验 `bin/bash` 与
 *    `ld-linux-aarch64.so.1` 的架构（防止拉到 x86 镜像）。本文件的做法更直接：
 *    在 manifest 阶段**只挑 `platform.architecture == "arm64"`** 的那份；
 *    最终校验只查 os-release / bin/sh 是否存在（[validateRootfs]）。
 *    不做 ELF 头解析是因为 minSdk 29 的普通 App 也不需要它，而且拉错架构时
 *    proot 会在启动时明确报错（不是静默错误）。
 * 6. **不移植 manifest / layer 的磁盘缓存**（上游 `OciManifestStore` 按 digest
 *    缓存、`OciLayerStore` 支持 Range 断点续传）。沙箱的 OCI 是**一次性安装**，
 *    装完就删临时文件；缓存只会在安装中断后留下一堆垃圾。保留的是「下载到
 *    临时文件 + 校验 + 解包 + 删除」的直线流程。
 * 7. **不移植并发下载 3 路 layer**（上游为移动网络限速做的优化）。
 *    改成顺序下载：每层下载完立刻解包（whiteout 语义依赖层顺序，本来就不能
 *    并发**解包**；而沙箱的安装是一次性操作，多花几十秒换一层简单的错误路径
 *    是划算的 —— 失败时你知道是哪一层）。
 * 8. **保留**：digest 格式校验（`sha256:[0-9a-f]{64}`）、每层 sha256 真校验、
 *    解包前后 staging 目录的原子替换、失败时清理 staging。
 *
 * ============================================================================
 * 校验纪律（不许造假）
 * ============================================================================
 * - layer 的 sha256 **真的算**（[sha256Hex]），与 manifest 里的 digest 比对，
 *   不符就抛 CODE_ROOTFS_CORRUPT 并且**删掉**已下载的临时文件。
 * - manifest 的 digest 也校验（如果是按 digest 拉的）。
 * - tar 是**真的流式解析**（[TarStreamExtractor]），不是解到壳里假装成功。
 * - 装完后的 rootfs 必须通过 [validateRootfs]（有 os-release 或 bin/sh），
 *   否则视为安装失败并清理 —— 不允许「目录建了就算装好」。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.RootfsStatus
import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.zip.GZIPInputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 一层 layer 的元数据（来自 manifest）。 */
private data class LayerRef(val digest: String, val mediaType: String, val size: Long)

/** 安装进度回调。 */
fun interface RootfsInstallProgress {
    /**
     * @param percent 0..100；**负数表示不确定进度**
     * @param message 人类可读阶段描述
     */
    fun onProgress(percent: Int, message: String)
}

/**
 * OCI rootfs 安装器。
 *
 * @param stagingRoot 临时解包目录的父目录（装完会 rename 成目标目录）
 * @param eventSink   事件上报（可选）
 */
class OciRootfsInstaller(
    private val stagingRoot: File,
    private val eventSink: EventSink = NoOpEventSink,
    private val tarExtractor: TarStreamExtractor = TarStreamExtractor(),
    /**
     * registry base 覆盖（给自建 registry / 镜像站用）。
     * 例：`https://my-mirror.example.com`。null 表示按镜像引用里的 host 走 HTTPS。
     */
    private val registryBaseOverride: String? = null,
) {

    /**
     * Registry HTTP 传输层（唯一发起网络请求的地方；HTTPS 强制策略在那里）。
     * 见 [RegistryHttp] 的文件头说明。
     */
    private val http = RegistryHttp(registryBaseOverride)
    /**
     * 拉取并安装 rootfs 到 [targetDir]。
     *
     * 流程是「装到 staging，成功后再原子替换 target」—— 中途失败绝不会留下
     * 半装状态的 target 目录。
     *
     * @param ociRef  镜像引用
     * @param targetDir 最终 rootfs 目录
     * @param onProgress 进度回调（可为空）
     * @throws SandboxException CODE_INVALID_ARGUMENT / CODE_NETWORK /
     *         CODE_ROOTFS_CORRUPT / CODE_IO
     */
    suspend fun install(
        ociRef: String,
        targetDir: File,
        onProgress: RootfsInstallProgress = RootfsInstallProgress { _, _ -> },
    ): RootfsStatus = withContext(Dispatchers.IO) {
        val parsed = OciImageReference.parse(ociRef)
        val staging = File(stagingRoot, "staging-${System.currentTimeMillis()}")
        deleteTree(staging)

        eventSink.onEvent(
            EventSink.CATEGORY_ROOTFS,
            "开始从 OCI 安装 rootfs",
            mapOf("ref" to parsed.canonical, "target" to targetDir.absolutePath),
        )

        try {
            if (!staging.mkdirs() && !staging.isDirectory) {
                throw SandboxException(
                    SandboxException.CODE_IO,
                    "无法创建 staging 目录：${staging.absolutePath}",
                )
            }

            onProgress.onProgress(0, "正在解析镜像清单…")
            val manifest = fetchManifest(parsed)
            val layers = manifest.layers
            if (layers.isEmpty()) {
                throw SandboxException(
                    SandboxException.CODE_ROOTFS_CORRUPT,
                    "镜像 ${parsed.canonical} 的 manifest 里没有任何 layer",
                )
            }

            val totalBytes = layers.sumOf { it.size }.coerceAtLeast(1L)
            var downloadedSoFar = 0L

            onProgress.onProgress(2, "共 ${layers.size} 层，合计 ${totalBytes / 1024 / 1024} MB")
            layers.forEachIndexed { index, layer ->
                val layerLabel = "第 ${index + 1}/${layers.size} 层"
                onProgress.onProgress(
                    percentOf(downloadedSoFar, totalBytes),
                    "正在下载$layerLabel…",
                )

                val blob = downloadBlob(parsed, layer.digest) { bytesThisLayer ->
                    // 进度按「已下载字节 / 总字节」算，绝对不含伪造的百分比
                    val percent = percentOf(downloadedSoFar + bytesThisLayer, totalBytes)
                    onProgress.onProgress(percent, "正在下载$layerLabel…")
                }

                try {
                    onProgress.onProgress(
                        percentOf(downloadedSoFar, totalBytes),
                        "正在解包$layerLabel…",
                    )
                    unpackLayer(blob, layer.mediaType, staging)
                } finally {
                    // 解包完立刻删：几层 layer 同时留在盘上会占几百 MB
                    resumeDelete(blob)
                }
                downloadedSoFar += layer.size
            }

            onProgress.onProgress(95, "正在校验 rootfs…")
            validateRootfs(staging)

            onProgress.onProgress(98, "正在启用新 rootfs…")
            replaceTarget(staging, targetDir)

            val sizeBytes = directorySize(targetDir)
            onProgress.onProgress(100, "安装完成")

            eventSink.onEvent(
                EventSink.CATEGORY_ROOTFS,
                "OCI rootfs 安装完成",
                mapOf(
                    "ref" to parsed.canonical,
                    "digest" to manifest.digest,
                    "bytes" to sizeBytes.toString(),
                ),
            )

            RootfsStatus(
                installed = true,
                source = RootfsStatus.SOURCE_OCI,
                label = parsed.canonical,
                ociRef = parsed.canonical,
                sizeBytes = sizeBytes,
                snapshotName = "",
                snapshotCount = 0,
                rootfsPath = targetDir.absolutePath,
            )
        } catch (cancellation: CancellationException) {
            deleteTree(staging)
            throw cancellation
        } catch (sandbox: SandboxException) {
            deleteTree(staging)
            eventSink.onEvent(
                EventSink.CATEGORY_ROOTFS,
                "OCI rootfs 安装失败",
                mapOf("ref" to parsed.canonical, "code" to sandbox.code.toString()),
            )
            throw sandbox
        } catch (failure: Throwable) {
            deleteTree(staging)
            eventSink.onEvent(
                EventSink.CATEGORY_ROOTFS,
                "OCI rootfs 安装失败",
                mapOf("ref" to parsed.canonical, "error" to (failure.message ?: "unknown")),
            )
            throw SandboxException(
                SandboxException.CODE_IO,
                "OCI rootfs 安装失败（${parsed.canonical}）：${failure.message ?: failure::class.java.simpleName}",
                failure,
            )
        }
    }

    // ========================================================================
    // manifest / token
    // ========================================================================

    private data class Manifest(val layers: List<LayerRef>, val digest: String)

    /**
     * 取 manifest，必要时跟随 manifest list 挑 linux/arm64。
     *
     * 注意 token 的 scope 是**按仓库**签的，所以挑完 arm64 子 manifest 后
     * 用的还是同一个 token（同一仓库），不需要重新申请。
     */
    private suspend fun fetchManifest(ref: OciImageReference): Manifest {
        val base = http.baseFor(ref)
        val token = fetchAnonymousToken(base, ref.repository)

        val first = http.get(
            url = "$base/v2/${ref.repository}/manifests/${ref.manifestRef}",
            token = token,
            accept = RegistryHttp.ACCEPT_MANIFEST,
        )
        val body = first.body
        val digest = first.contentDigest
        val contentType = first.contentType

        // 按 digest 拉的：必须校验 manifest 自身 digest
        ref.digest?.let { expected ->
            if (!digest.equals(expected, ignoreCase = true)) {
                throw SandboxException(
                    SandboxException.CODE_ROOTFS_CORRUPT,
                    "manifest digest 不匹配：期望 $expected，实际 $digest",
                )
            }
        }

        val json = MiniJson.parse(body)
        val root = json.asObject()

        // ---- manifest list / image index：挑 linux/arm64 ----
        val manifests = root["manifests"]?.asArray()
        if (manifests != null) {
            val arm64 = manifests.firstOrNull { entry ->
                val platform = entry.asObject()["platform"]?.asObject() ?: return@firstOrNull false
                platform["os"]?.asString() == "linux" &&
                    platform["architecture"]?.asString() == "arm64"
            } ?: throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "镜像 ${ref.canonical} 不提供 linux/arm64 平台（沙箱只支持 arm64-v8a）",
            )
            val childDigest = arm64.asObject()["digest"]?.asString()
                ?: throw SandboxException(
                    SandboxException.CODE_ROOTFS_CORRUPT,
                    "manifest list 条目缺少 digest",
                )
            // 递归取子 manifest（此时 manifestRef = digest）
            val child = http.get(
                url = "$base/v2/${ref.repository}/manifests/$childDigest",
                token = token,
                accept = RegistryHttp.ACCEPT_MANIFEST,
            )
            if (!child.contentDigest.equals(childDigest, ignoreCase = true)) {
                throw SandboxException(
                    SandboxException.CODE_ROOTFS_CORRUPT,
                    "子 manifest digest 不匹配：期望 $childDigest，实际 ${child.contentDigest}",
                )
            }
            return parseManifestBody(child.body, child.contentDigest)
        }

        // 已经通过 contentType 校验过是 manifest 而不是 list
        if (contentType != null && contentType.contains("manifest.list")) {
            throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "服务端返回 manifest list 但内容解析不出 manifests 数组",
            )
        }
        return parseManifestBody(body, digest)
    }

    private fun parseManifestBody(body: String, digest: String): Manifest {
        val root = MiniJson.parse(body).asObject()
        val layersArray = root["layers"]?.asArray()
            ?: throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "OCI manifest 没有 layers 数组（可能拿到的是 manifest list，未成功下钻）",
            )
        val layers = layersArray.map { element ->
            val obj = element.asObject()
            val layerDigest = obj["digest"]?.asString()
                ?: throw SandboxException(
                    SandboxException.CODE_ROOTFS_CORRUPT,
                    "layer 缺少 digest",
                )
            if (!layerDigest.matches(Regex("sha256:[a-f0-9]{64}"))) {
                throw SandboxException(
                    SandboxException.CODE_ROOTFS_CORRUPT,
                    "layer digest 格式非法（只支持 sha256）：$layerDigest",
                )
            }
            LayerRef(
                digest = layerDigest,
                mediaType = obj["mediaType"]?.asString().orEmpty(),
                size = obj["size"]?.asLong() ?: 0L,
            )
        }
        return Manifest(layers, digest)
    }

    /**
     * Docker Registry 匿名 token 流程。
     *
     * 先打 `/v2/` 拿 `WWW-Authenticate: Bearer realm=...,service=...`，
     * 再去 realm 换 token。Docker Hub 的 realm 是 `https://auth.docker.io/token`。
     *
     * 失败一律降级为「空 token」：公开镜像有时允许无 token 访问，让后续请求
     * 自己去撞 401 并给出更准确的错误信息。
     */
    private fun fetchAnonymousToken(base: String, repository: String): String {
        val challenge = try {
            probeAuthChallenge("$base/v2/")
        } catch (_: IOException) {
            null
        }
        val realm = challenge?.get("realm") ?: "https://auth.docker.io/token"
        val service = challenge?.get("service") ?: "registry.docker.io"

        val scope = try {
            URLEncoder.encode("repository:$repository:pull", Charsets.UTF_8.name())
        } catch (failure: Throwable) {
            throw SandboxException(SandboxException.CODE_INTERNAL, "无法编码 token scope", failure)
        }
        val tokenUrl = "$realm?service=${URLEncoder.encode(service, "UTF-8")}&scope=$scope"

        val body = http.get(tokenUrl, token = null, accept = "application/json").body
        val root = MiniJson.parse(body).asObject()
        // Docker Hub 用 "token"，有些实现用 "access_token"
        return root["token"]?.asString()
            ?: root["access_token"]?.asString()
            ?: throw SandboxException(
                SandboxException.CODE_NETWORK,
                "registry 未返回 token（$realm）；可能是私有镜像或镜像不存在",
            )
    }

    /** 从 `/v2/` 的 401 响应里解析 `WWW-Authenticate: Bearer realm="…",service="…"`。 */
    private fun probeAuthChallenge(v2Url: String): Map<String, String>? {
        val connection = http.openChallengeProbe(v2Url)
        return try {
            val status = connection.responseCode
            val header = connection.getHeaderField("WWW-Authenticate")
            if (header == null || !header.startsWith("Bearer ", ignoreCase = true)) {
                // 200 表示匿名可访问；其它情况交给调用方用默认 realm 试
                return null
            }
            val result = mutableMapOf<String, String>()
            // 形如：Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="…"
            header.removePrefix("Bearer ")
                .removePrefix("bearer ")
                .split(',')
                .forEach { part ->
                    val trimmed = part.trim()
                    val eq = trimmed.indexOf('=')
                    if (eq <= 0) return@forEach
                    val key = trimmed.substring(0, eq).trim()
                    val value = trimmed.substring(eq + 1).trim().trim('"')
                    result[key] = value
                }
            if (status == 200) null else result.takeIf { it.isNotEmpty() }
        } finally {
            runCatching { connection.disconnect() }
        }
    }

    // ========================================================================
    // blob 下载 + sha256 校验
    // ========================================================================

    /**
     * 下载一个 layer blob 到临时文件，**边下载边算 sha256**，下完立刻比对。
     *
     * @param onBytes 每读一块回调一次「本层累计字节数」（用于进度）
     * @throws SandboxException CODE_NETWORK / CODE_ROOTFS_CORRUPT
     */
    private suspend fun downloadBlob(
        ref: OciImageReference,
        digest: String,
        onBytes: (Long) -> Unit,
    ): File {
        val expected = digest.substringAfter("sha256:").lowercase()
        if (!expected.matches(Regex("[0-9a-f]{64}"))) {
            throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "layer digest 格式非法：$digest",
            )
        }
        val base = http.baseFor(ref)
        val token = fetchAnonymousToken(base, ref.repository)
        val target = File(stagingRoot, "blob-$expected.tmp")
        deleteTree(target)

        if (!stagingRoot.isDirectory && !stagingRoot.mkdirs() && !stagingRoot.isDirectory) {
            throw SandboxException(
                SandboxException.CODE_IO,
                "无法创建临时目录：${stagingRoot.absolutePath}",
            )
        }

        val md = MessageDigest.getInstance("SHA-256")
        var total = 0L
        // openBlobStream 已经处理了重定向（含逐跳 HTTPS 检查与跨 host 丢弃 token），
        // 并把连接交给我们读流；useStream 保证最终 disconnect。
        val connection = http.openBlobStream(
            url = "$base/v2/${ref.repository}/blobs/$digest",
            token = token,
        )
        val actual = connection.useStream { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(BUFFER_SIZE)
                while (true) {
                    http.currentThreadCheck()
                    val read = input.read(buffer)
                    if (read < 0) break
                    output.write(buffer, 0, read)
                    md.update(buffer, 0, read)
                    total += read
                    onBytes(total)
                }
            }
            md.digest().joinToString("") { "%02x".format(it) }
        }

        // ★ 真校验：sha256 不符就是数据损坏（或镜像站被劫持），绝不继续
        if (actual != expected) {
            resumeDelete(target)
            throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "layer 校验失败：期望 sha256=$expected，实际 sha256=$actual（下载已丢弃）",
            )
        }
        return target
    }

    /**
     * 解包一个 layer。
     *
     * mediaType 决定解压方式：
     *   - `...tar+gzip` / 非空且含 gzip  → GZIPInputStream
     *   - 其它 / 空                       → 当作裸 tar
     *
     * zstd **不支持**：需要额外的原生库（build.gradle.kts 的依赖白名单里没有）。
     * 遇到 zstd 明确失败并说明，而不是解出一堆垃圾。
     */
    private suspend fun unpackLayer(blob: File, mediaType: String, destination: File) {
        val lower = mediaType.lowercase()
        if ("zstd" in lower) {
            throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "该镜像使用 zstd 压缩的 layer（$mediaType），沙箱未内置 zstd 解码器。" +
                    "请改用 gzip 或未压缩层的基础镜像（如 alpine、debian 官方镜像）。",
            )
        }
        val handleWhiteouts = true
        blob.inputStream().use { raw ->
            val stream: InputStream = when {
                "gzip" in lower -> GZIPInputStream(raw)
                // mediaType 为空时按 gzip 猜（docker 最常见的其实是 gzip）
                lower.isEmpty() -> maybeGzip(raw)
                else -> raw
            }
            stream.use {
                tarExtractor.extract(it, destination, handleWhiteouts)
            }
        }
    }

    /** 靠 gzip magic（0x1f 0x8b）猜是否 gzip；不是就原样返回。 */
    private fun maybeGzip(input: InputStream): InputStream {
        val buffered = java.io.BufferedInputStream(input, 8)
        buffered.mark(4)
        val magic = ByteArray(2)
        val read = buffered.read(magic)
        buffered.reset()
        return if (read == 2 && magic[0] == 0x1f.toByte() && magic[1] == 0x8b.toByte()) {
            GZIPInputStream(buffered)
        } else {
            buffered
        }
    }

    // ========================================================================
    // 校验 / 目录替换
    // ========================================================================

    /**
     * 校验解包结果**至少像个 rootfs**。
     *
     * 这不是完整校验（不查 ELF 架构、不查动态链接器），只是「别把空目录
     * 当成功」的底线。真正的可用性由 PRoot 启动时暴露。
     */
    fun validateRootfs(rootfs: File) {
        if (!rootfs.isDirectory) {
            throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "rootfs 目录不存在：${rootfs.absolutePath}",
            )
        }
        val hasOsRelease = File(rootfs, "etc/os-release").isFile ||
            File(rootfs, "usr/lib/os-release").isFile
        val hasShell = File(rootfs, "bin/sh").exists() ||
            File(rootfs, "usr/bin/sh").exists() ||
            File(rootfs, "bin/bash").exists()

        if (!hasOsRelease && !hasShell) {
            throw SandboxException(
                SandboxException.CODE_ROOTFS_CORRUPT,
                "解包结果不像一个 rootfs：既没有 etc/os-release，也没有 bin/sh。",
            )
        }
    }

    /** 用 staging 原子替换 target；旧 target 先挪开，失败则回滚。 */
    private fun replaceTarget(staging: File, target: File) {
        target.parentFile?.let { if (!it.isDirectory && !it.mkdirs() && !it.isDirectory) {
            throw SandboxException(
                SandboxException.CODE_IO,
                "无法创建 rootfs 的父目录：${it.absolutePath}",
            )
        } }

        val backup = File(target.parentFile, "${target.name}.old-${System.currentTimeMillis()}")
        if (target.exists()) {
            deleteTree(backup)
            if (!target.renameTo(backup)) {
                throw SandboxException(
                    SandboxException.CODE_IO,
                    "无法移开旧 rootfs（${target.absolutePath}）",
                )
            }
        }
        if (!staging.renameTo(target)) {
            // 回滚：把旧 rootfs 放回去，不让沙箱停在「没有 rootfs」的状态
            if (backup.exists()) {
                runCatching { backup.renameTo(target) }
            }
            throw SandboxException(
                SandboxException.CODE_IO,
                "无法启用新 rootfs（${staging.absolutePath} -> ${target.absolutePath}）",
            )
        }
        deleteTree(backup)
    }


    // ========================================================================
    // 工具
    // ========================================================================

    private fun percentOf(done: Long, total: Long): Int =
        if (total <= 0) -1 else ((done * 100) / total).toInt().coerceIn(0, 99)

    /** 目录总字节数（不跟随符号链接）。 */
    private fun directorySize(dir: File): Long = runCatching {
        dir.walkTopDown()
            .filter { it.isFile && !it.isSymlinkNoFollow() }
            .sumOf { it.length() }
    }.getOrDefault(0L)

    /** 递归删除（不跟随符号链接，防越界）。 */
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

    /** 尽力删除（失败静默；用于临时 blob）。 */
    private fun resumeDelete(file: File) {
        runCatching { deleteTree(file) }
    }


    private companion object {
        /** 下载缓冲大小（64 KB：与 OCI layer 常见的块大小对齐）。 */
        const val BUFFER_SIZE = 64 * 1024
    }
}
