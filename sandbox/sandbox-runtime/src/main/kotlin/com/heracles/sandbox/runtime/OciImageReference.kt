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
 *           runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/OciImageReference.kt
 *
 * ============================================================================
 * 为什么单独一个文件
 * ============================================================================
 * 这 120 行是**纯语法解析**（没有任何 IO、没有网络、没有 Android 依赖），
 * 与 [OciRootfsInstaller] 的「下载 + 校验 + 解包」是两类不同的东西：
 * 前者可以在 PC 上的普通 JVM 单测里跑，后者不行。分开之后
 * 「镜像引用语法」这一块是可独立验证的。
 *
 * ============================================================================
 * 与上游 taixu OciImageReference 的差异（逐条）
 * ============================================================================
 * 1. **字段结构不同**。上游是 `(repo, tag, digest)`，其中 `repo` 不含 registry
 *    host（它只支持 Docker Hub，host 硬编码在 client 里）。
 *    这里拆成 `(registryHost, repository, tag, digest)` 四个字段 —— 因为沙箱
 *    允许 [OciRootfsInstaller] 的 `registryBaseOverride` 指向自建 registry，
 *    host 必须是数据而不是常量。
 * 2. **放宽 registry host 限制**。上游明确抛「当前安装线路只支持 Docker Hub 镜像」
 *    （`require(first in setOf("docker.io", "index.docker.io"))`）。
 *    沙箱不内置这种信任假设 —— host 由调用方给，由
 *    [OciRootfsInstaller] 的 HTTPS 强制策略兜底（明文 HTTP 一律拒绝）。
 * 3. **`docker.io` -> `registry-1.docker.io` 的别名映射**移到了这里
 *    （上游在 Endpoint 里做）。理由：这是**镜像引用语义**的一部分，
 *    不是 registry 连接细节。
 * 4. **错误类型**：上游用 `require`（抛 IllegalArgumentException）；
 *    这里统一抛 [SandboxException] 的 CODE_INVALID_ARGUMENT —— 因为这是
 *    AIDL 边界上的错误，宿主需要拿到稳定的错误码而不是 Kotlin 的断言异常。
 * 5. **解析逻辑本体逐条保留**：registry host 判定（含 `.`/`:`/localhost/
 *    非小写四种信号）、单段名补 `library/`、tag 与 digest 的互斥、
 *    digest 必须 `sha256:<64 hex>`、tag 字符集、仓库名全小写。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.SandboxException

/**
 * OCI 镜像引用。
 *
 * 支持的形态（与 docker CLI 的常用写法一致）：
 * ```
 *   alpine                          -> registry-1.docker.io/library/alpine:latest
 *   alpine:3.20                     -> registry-1.docker.io/library/alpine:3.20
 *   library/alpine:3.20             -> registry-1.docker.io/library/alpine:3.20
 *   docker.io/library/alpine:3.20   -> registry-1.docker.io/library/alpine:3.20
 *   alpine@sha256:<64 hex>          -> 按 digest 拉
 * ```
 */
data class OciImageReference(
    /** registry 主机名，如 `registry-1.docker.io`（注意不是 `docker.io`） */
    val registryHost: String,
    /** 仓库路径，如 `library/alpine` */
    val repository: String,
    /** tag；按 digest 拉时为空串 */
    val tag: String,
    /** `sha256:...`；没指定为 null */
    val digest: String?,
) {
    /** 拼成 manifest 请求的引用（digest 优先，否则 tag）。 */
    val manifestRef: String get() = digest ?: tag.ifEmpty { "latest" }

    /** 人类可读的原样引用。 */
    val canonical: String get() = buildString {
        append(registryHost)
        append('/')
        append(repository)
        if (digest != null) {
            append('@')
            append(digest)
        } else {
            append(':')
            append(tag)
        }
    }

    companion object {
        /** Docker 的仓库路径语法：小写字母数字 + 分隔符。 */
        private const val COMPONENT = "[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"
        private val REPO_GRAMMAR = Regex("($COMPONENT(?:/$COMPONENT)*)")
        private val TAG_GRAMMAR = Regex("[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}")
        private val DIGEST_GRAMMAR = Regex("sha256:[a-f0-9]{64}")
        private val IMAGE_ID_GRAMMAR = Regex("[a-f0-9]{64}")

        /** Docker Hub 的实际 registry 端点（`docker.io` 只是别名，不能直连）。 */
        const val DOCKER_HUB_REGISTRY = "registry-1.docker.io"

        /**
         * 解析镜像引用。
         *
         * @throws SandboxException CODE_INVALID_ARGUMENT 格式不合法
         */
        fun parse(value: String): OciImageReference {
            val raw = value.trim()
            if (raw.isEmpty()) {
                throw SandboxException(SandboxException.CODE_INVALID_ARGUMENT, "镜像引用为空")
            }
            if (raw.length > 1024) {
                throw SandboxException(SandboxException.CODE_INVALID_ARGUMENT, "镜像引用过长（>1024）")
            }
            // 纯 64 位 hex 是镜像 ID，不是仓库名
            if (raw.matches(IMAGE_ID_GRAMMAR)) {
                throw SandboxException(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    "镜像 ID 不能当镜像名用；请使用 tag 或 @sha256:<digest>",
                )
            }

            // ---- 拆出 registry host ----
            // 判定信号（与 docker 一致）：第一段含 `.` 或 `:`，或是 localhost，
            // 或含大写字母（仓库名必须全小写 ⇒ 含大写的第一段只能是 host）。
            val firstSegment = raw.substringBefore('/')
            val hasExplicitHost = '/' in raw &&
                ('.' in firstSegment || ':' in firstSegment ||
                    firstSegment == "localhost" || firstSegment != firstSegment.lowercase())

            var host: String
            var rest: String
            if (hasExplicitHost) {
                host = firstSegment
                rest = raw.substringAfter('/')
            } else {
                host = "docker.io"
                rest = raw
            }
            // docker.io 只是别名，实际端点不同
            host = when (host) {
                "docker.io", "index.docker.io" -> DOCKER_HUB_REGISTRY
                else -> host
            }

            // ---- 拆出 digest（@ 之后） ----
            var digest: String? = null
            val atIndex = rest.indexOf('@')
            if (atIndex >= 0) {
                digest = rest.substring(atIndex + 1)
                rest = rest.substring(0, atIndex)
                if (!DIGEST_GRAMMAR.matches(digest)) {
                    throw SandboxException(
                        SandboxException.CODE_INVALID_ARGUMENT,
                        "digest 格式无效（要求 sha256:<64 位小写 hex>）：$digest",
                    )
                }
            }

            // ---- 拆出 tag（最后一个 `:` 之后，且必须在最后一个 `/` 之后） ----
            var tag = ""
            val colonIndex = rest.lastIndexOf(':')
            if (colonIndex > rest.lastIndexOf('/')) {
                tag = rest.substring(colonIndex + 1)
                rest = rest.substring(0, colonIndex)
                if (!TAG_GRAMMAR.matches(tag)) {
                    throw SandboxException(
                        SandboxException.CODE_INVALID_ARGUMENT,
                        "tag 格式无效：$tag",
                    )
                }
            }

            // ---- 校验仓库路径 ----
            val match = REPO_GRAMMAR.matchEntire(rest)
                ?: throw SandboxException(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    "仓库名格式无效（必须小写，仅允许 [a-z0-9._-] 与 /）：$rest",
                )
            var repository = match.groupValues[1]
            // 单段名补 library/ —— **只在 Docker Hub 上**。
            // 这是 Hub 的命名约定，不是 OCI 规范：自建 registry 的
            // `myhost:5000/app` 仓库名就是 `app`，补成 `library/app` 会 404。
            if ('/' !in repository && host == DOCKER_HUB_REGISTRY) {
                repository = "library/$repository"
            }

            if (tag.isEmpty() && digest == null) tag = "latest"

            return OciImageReference(host, repository, tag, digest)
        }
    }
}
