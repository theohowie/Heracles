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
 *           （上游只覆盖了 docker CLI 的常用写法；这里补齐规范化与拒绝用例）
 *
 * 这些测试刻意跑在**普通 JVM** 上（不需要 Android 设备）：OciImageReference
 * 是纯语法解析，没有 IO / 网络 / Android 依赖。这样「镜像引用怎么解析」
 * 这一块可以被真正的门禁守住，而不用靠人肉试。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.SandboxException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class OciImageReferenceTest {

    private fun assertRejected(ref: String) {
        try {
            OciImageReference.parse(ref)
            fail("期望拒绝 \"$ref\"，但解析成功了")
        } catch (expected: SandboxException) {
            assertEquals(
                "错误码应为 CODE_INVALID_ARGUMENT：\"$ref\"",
                SandboxException.CODE_INVALID_ARGUMENT,
                expected.code,
            )
        }
    }

    @Test
    fun `单段名补 library 前缀并默认 latest`() {
        val ref = OciImageReference.parse("alpine")
        assertEquals(OciImageReference.DOCKER_HUB_REGISTRY, ref.registryHost)
        assertEquals("library/alpine", ref.repository)
        assertEquals("latest", ref.tag)
        assertNull(ref.digest)
        assertEquals("registry-1.docker.io/library/alpine:latest", ref.canonical)
    }

    @Test
    fun `带 tag 的简写`() {
        val ref = OciImageReference.parse("alpine:3.20")
        assertEquals("library/alpine", ref.repository)
        assertEquals("3.20", ref.tag)
        assertEquals("3.20", ref.manifestRef)
    }

    @Test
    fun `两段名不再补 library`() {
        val ref = OciImageReference.parse("library/alpine:3.20")
        assertEquals("library/alpine", ref.repository)
        assertEquals("3.20", ref.tag)
    }

    @Test
    fun `显式 docker_io 映射到 registry-1`() {
        val ref = OciImageReference.parse("docker.io/library/alpine:3.20")
        assertEquals(OciImageReference.DOCKER_HUB_REGISTRY, ref.registryHost)
        assertEquals("library/alpine", ref.repository)
    }

    @Test
    fun `index_docker_io 也映射到 registry-1`() {
        val ref = OciImageReference.parse("index.docker.io/library/alpine")
        assertEquals(OciImageReference.DOCKER_HUB_REGISTRY, ref.registryHost)
    }

    @Test
    fun `自建 registry 的 host 被保留`() {
        val ref = OciImageReference.parse("my.registry.local:5000/team/app:v1")
        assertEquals("my.registry.local:5000", ref.registryHost)
        assertEquals("team/app", ref.repository)
        assertEquals("v1", ref.tag)
    }

    @Test
    fun `按 digest 拉取时 digest 优先于 tag`() {
        val d = "sha256:" + "a".repeat(64)
        val ref = OciImageReference.parse("alpine@$d")
        assertEquals(d, ref.digest)
        assertEquals("", ref.tag)
        assertEquals(d, ref.manifestRef)
        assertTrue(ref.canonical.endsWith("@$d"))
    }

    @Test
    fun `空引用被拒绝`() = assertRejected("")

    @Test
    fun `纯 64 位 hex 镜像 ID 被拒绝`() = assertRejected("a".repeat(64))

    @Test
    fun `仓库名含大写被拒绝`() = assertRejected("Alpine")

    @Test
    fun `非法 digest 被拒绝`() = assertRejected("alpine@sha256:xyz")

    @Test
    fun `digest 长度不足被拒绝`() = assertRejected("alpine@sha256:" + "a".repeat(63))

    @Test
    fun `非法 tag 字符被拒绝`() = assertRejected("alpine:3.20 beta")

    @Test
    fun `超长引用被拒绝`() = assertRejected("a".repeat(1025))

    /**
     * tag 与端口号的歧义：`myhost:5000/app` 里的 `5000` 是**端口**不是 tag。
     * 判定规则是「`:` 必须在最后一个 `/` 之后才算 tag」。
     */
    @Test
    fun `registry 端口不会被误认成 tag`() {
        val ref = OciImageReference.parse("myhost:5000/app")
        assertEquals("myhost:5000", ref.registryHost)
        assertEquals("app", ref.repository)
        assertEquals("latest", ref.tag)
    }

    @Test
    fun `dockerfile 风格的 latest 显式写法`() {
        val ref = OciImageReference.parse("docker.io/library/debian:latest")
        assertEquals("library/debian", ref.repository)
        assertEquals("latest", ref.tag)
    }
}
