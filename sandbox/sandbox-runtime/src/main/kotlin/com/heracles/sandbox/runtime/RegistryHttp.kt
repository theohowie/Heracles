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
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/RootfsHttpPolicy.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/OciLayerStore.kt（下载部分）
 *
 * ============================================================================
 * 为什么单独拆出来
 * ============================================================================
 * 这是沙箱里**唯一**发起网络请求的地方。把它单独成文件有两个实在的好处：
 *   1. **安全审计面收敛**：想知道「沙箱会连哪些地址、带什么头、允不允许明文」，
 *      只看这一个文件就够，不用在 800 行安装逻辑里翻。
 *   2. **HTTPS 强制策略只有一处实现**：上游用 OkHttp 的拦截器做
 *      「禁止 HTTPS→HTTP 降级」；沙箱没有 OkHttp（依赖白名单），所以这里把
 *      策略做在 [openConnection] + [get] 两层，重定向**逐跳**检查。
 *      策略如果散落多处，早晚会有一条路径漏掉。
 *
 * ============================================================================
 * 与上游 taixu RootfsHttpPolicy 的差异
 * ============================================================================
 * 1. **OkHttp -> HttpURLConnection**（依赖白名单限制）。等价能力：
 *    - 不活动的读超时（不是总传输时长）⇒ `readTimeout`，语义一致
 *    - 禁止 HTTPS→HTTP 降级 ⇒ 见 [get] 的逐跳检查（比上游的拦截器更严格：
 *      上游只在 3xx 且带 Location 时检查，这里连初始 URL 也检查）
 * 2. **重定向自己跟随**（`instanceFollowRedirects = false`）。
 *    `HttpURLConnection` 的自动跟随无法在跳与跳之间做 scheme 检查，
 *    用它就等于放弃了降级防护。
 * 3. **跨 host 重定向时丢弃 token**。blob 下载通常会 302 到对象存储
 *    （S3 / CDN），那些主机不认识 registry 的 Bearer token；更重要的是
 *    **不该把 registry 凭据发给第三方主机**。上游 OkHttp 默认会保留头，
 *    这是个容易被忽略的凭据泄漏面。
 * 4. **新增 [currentThreadCheck]**：`HttpURLConnection` 的阻塞 read 不响应
 *    协程取消，长下载只能靠线程中断（runInterruptible）打破；这里把中断
 *    转成 CancellationException，让 [OciRootfsInstaller] 的取消路径生效。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.SandboxException
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import kotlinx.coroutines.CancellationException

/**
 * Registry HTTP 传输层。
 *
 * @param registryBaseOverride 显式的 registry base（自建 / 局域网镜像站）。
 *        **只有**非 null 时才允许该 base 用明文 HTTP；否则一律要求 https。
 */
internal class RegistryHttp(private val registryBaseOverride: String?) {

    /** 一次 GET 的结果。 */
    data class Response(
        val body: String,
        /** `Docker-Content-Digest` 响应头（没有则为空串）。 */
        val contentDigest: String,
        val contentType: String?,
    )

    /** 该镜像引用应使用的 registry base URL。 */
    fun baseFor(ref: OciImageReference): String =
        registryBaseOverride?.trimEnd('/') ?: "https://${ref.registryHost}"

    /**
     * GET 一个 URL，跟随最多 [MAX_REDIRECTS] 跳，返回响应体。
     *
     * @throws SandboxException CODE_NETWORK / CODE_ROOTFS_CORRUPT / CODE_INVALID_ARGUMENT
     */
    fun get(url: String, token: String?, accept: String): Response {
        var currentUrl = url
        var currentToken = token
        var redirects = 0

        while (true) {
            currentThreadCheck()
            val connection = openConnection(currentUrl, accept, currentToken)
            try {
                val status = connection.responseCode
                when {
                    status in 200..299 -> {
                        val body = connection.inputStream
                            .bufferedReader(Charsets.UTF_8)
                            .use { it.readText() }
                        return Response(
                            body = body,
                            contentDigest = connection.getHeaderField("Docker-Content-Digest").orEmpty(),
                            contentType = connection.getHeaderField("Content-Type"),
                        )
                    }

                    status in 300..399 -> {
                        val location = connection.getHeaderField("Location")
                            ?: throw SandboxException(
                                SandboxException.CODE_NETWORK,
                                "HTTP $status 但没有 Location 头：$currentUrl",
                            )
                        if (++redirects > MAX_REDIRECTS) {
                            throw SandboxException(
                                SandboxException.CODE_NETWORK,
                                "重定向次数过多（>$MAX_REDIRECTS）：$url",
                            )
                        }
                        val next = try {
                            URI(currentUrl).resolve(location).toString()
                        } catch (failure: Throwable) {
                            throw SandboxException(
                                SandboxException.CODE_NETWORK,
                                "无法解析重定向目标（$location）：${failure.message}",
                                failure,
                            )
                        }

                        // ★ 逐跳 HTTPS→HTTP 降级检查
                        val currentScheme = URI(currentUrl).scheme?.lowercase()
                        val nextScheme = URI(next).scheme?.lowercase()
                        if (currentScheme == "https" && nextScheme == "http") {
                            throw SandboxException(
                                SandboxException.CODE_NETWORK,
                                "拒绝 HTTPS→HTTP 降级重定向：$currentUrl -> $next",
                            )
                        }

                        // ★ 跨 host 时丢弃 token：不要把 registry 凭据发给
                        //   对象存储/CDN 等第三方主机（见文件头差异 3）。
                        val currentHost = runCatching { URI(currentUrl).host }.getOrNull()
                        val nextHost = runCatching { URI(next).host }.getOrNull()
                        if (currentHost != nextHost) {
                            currentToken = null
                        }

                        currentUrl = next
                    }

                    status == 401 -> throw SandboxException(
                        SandboxException.CODE_NETWORK,
                        "registry 鉴权失败 HTTP 401（$currentUrl）；镜像可能不存在或为私有",
                    )

                    status == 404 -> throw SandboxException(
                        SandboxException.CODE_ROOTFS_CORRUPT,
                        "registry 上找不到资源 HTTP 404（$currentUrl）；请检查镜像名与 tag",
                    )

                    else -> throw SandboxException(
                        SandboxException.CODE_NETWORK,
                        "registry 请求失败 HTTP $status（$currentUrl）",
                    )
                }
            } catch (failure: IOException) {
                throw SandboxException(
                    SandboxException.CODE_NETWORK,
                    "registry 网络错误（$currentUrl）：${failure.message ?: failure::class.java.simpleName}",
                    failure,
                )
            } finally {
                runCatching { connection.disconnect() }
            }
        }
    }

    /**
     * 打开一个 blob 下载连接（**不**跟随重定向，由调用方处理或直接读流）。
     *
     * 返回已确认 `200` 的连接；状态不是 200 时抛异常并已断开连接。
     *
     * @throws SandboxException CODE_NETWORK
     */
    fun openBlobStream(
        url: String,
        token: String?,
        onRedirect: (String) -> Unit = {},
    ): HttpURLConnection {
        var currentUrl = url
        var currentToken = token
        var redirects = 0

        while (true) {
            currentThreadCheck()
            val connection = openConnection(currentUrl, ACCEPT_BLOB, currentToken)
            try {
                val status = connection.responseCode
                if (status == 200) {
                    // 成功：连接交给调用方读流，**不要**在这里 disconnect
                    return connection
                }
                if (status in 300..399) {
                    val location = connection.getHeaderField("Location")
                        ?: throw SandboxException(
                            SandboxException.CODE_NETWORK,
                            "blob 下载返回 HTTP $status 但没有 Location 头：$currentUrl",
                        )
                    if (++redirects > MAX_REDIRECTS) {
                        throw SandboxException(
                            SandboxException.CODE_NETWORK,
                            "blob 下载重定向次数过多（>$MAX_REDIRECTS）：$url",
                        )
                    }
                    val next = URI(currentUrl).resolve(location).toString()
                    val currentScheme = URI(currentUrl).scheme?.lowercase()
                    val nextScheme = URI(next).scheme?.lowercase()
                    if (currentScheme == "https" && nextScheme == "http") {
                        throw SandboxException(
                            SandboxException.CODE_NETWORK,
                            "拒绝 blob 下载的 HTTPS→HTTP 降级重定向：$currentUrl -> $next",
                        )
                    }
                    if (runCatching { URI(currentUrl).host }.getOrNull() !=
                        runCatching { URI(next).host }.getOrNull()
                    ) {
                        currentToken = null
                    }
                    onRedirect(next)
                    connection.disconnect()
                    currentUrl = next
                    continue
                }

                // 非 200 / 非重定向
                val detail = runCatching {
                    connection.errorStream?.bufferedReader()?.readText()
                }.getOrNull()?.take(256).orEmpty()
                throw SandboxException(
                    SandboxException.CODE_NETWORK,
                    buildString {
                        append("下载 blob 失败 HTTP ").append(status).append("（").append(currentUrl).append('）')
                        if (detail.isNotBlank()) append("：").append(detail)
                    },
                )
            } catch (failure: IOException) {
                runCatching { connection.disconnect() }
                throw SandboxException(
                    SandboxException.CODE_NETWORK,
                    "blob 下载网络错误（$currentUrl）：${failure.message ?: failure::class.java.simpleName}",
                    failure,
                )
            } catch (failure: Throwable) {
                runCatching { connection.disconnect() }
                throw failure
            }
        }
    }

    /**
     * 打开一个「探测」连接（用于读 `/v2/` 的 401 挑战头）。
     *
     * 与 [openBlobStream] 的区别：**不校验状态码**，把连接原样交给调用方
     * 去读 `WWW-Authenticate`（401 是这里的正常路径，不是错误）。
     * 调用方负责 disconnect。
     */
    fun openChallengeProbe(url: String, token: String? = null): HttpURLConnection =
        openConnection(url, accept = "application/json", token = token)

    /**
     * 建一个连接。
     *
     * ★ 安全策略：只有 https 允许；明文 http **仅当**显式配置了
     * [registryBaseOverride]（局域网 / 自建镜像站）时才放行。
     */
    private fun openConnection(
        url: String,
        accept: String,
        token: String?,
    ): HttpURLConnection {
        val uri = try {
            URI(url)
        } catch (failure: Throwable) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "非法 registry URL：$url",
                failure,
            )
        }
        val scheme = uri.scheme?.lowercase()
        if (scheme != "https" && scheme != "http") {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "不支持的 URL scheme：$scheme（只允许 https）",
            )
        }
        if (scheme == "http" && registryBaseOverride == null) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "拒绝使用明文 HTTP 访问 registry（$url）；" +
                    "请配置 https 镜像，或显式指定 registryBaseOverride",
            )
        }
        val connection = uri.toURL().openConnection() as HttpURLConnection
        connection.connectTimeout = CONNECT_TIMEOUT_MILLIS
        // 读超时按「不活动」而不是「总时长」：大 layer 在慢网下也需要时间
        connection.readTimeout = READ_TIMEOUT_MILLIS
        connection.instanceFollowRedirects = false // 自己跟随，逐跳校验
        connection.setRequestProperty("User-Agent", USER_AGENT)
        connection.setRequestProperty("Accept", accept)
        if (!token.isNullOrBlank()) {
            connection.setRequestProperty("Authorization", "Bearer $token")
        }
        return connection
    }

    /**
     * 检查线程中断。
     *
     * HttpURLConnection 的阻塞 read 不响应协程取消，长下载只能靠线程中断
     * （runInterruptible）打破；这里把中断转成 CancellationException。
     */
    fun currentThreadCheck() {
        if (Thread.currentThread().isInterrupted) {
            throw CancellationException("下载被取消（线程中断）")
        }
    }

    companion object {
        const val USER_AGENT = "Heracles-taixu-sandbox/1.0"
        const val CONNECT_TIMEOUT_MILLIS = 15_000

        /** 不活动读超时（2 分钟）。 */
        const val READ_TIMEOUT_MILLIS = 120_000

        const val MAX_REDIRECTS = 5

        const val ACCEPT_BLOB = "application/octet-stream"

        /** manifest 的 Accept 头（覆盖 OCI index / docker manifest list / 两种 manifest）。 */
        const val ACCEPT_MANIFEST =
            "application/vnd.oci.image.index.v1+json, " +
                "application/vnd.docker.distribution.manifest.list.v2+json, " +
                "application/vnd.oci.image.manifest.v1+json, " +
                "application/vnd.docker.distribution.manifest.v2+json"
    }
}

/** 供 OciRootfsInstaller 使用：把 InputStream 交给调用方时保证最终关闭连接。 */
internal inline fun <T> HttpURLConnection.useStream(block: (InputStream) -> T): T =
    try {
        inputStream.use(block)
    } finally {
        runCatching { disconnect() }
    }
