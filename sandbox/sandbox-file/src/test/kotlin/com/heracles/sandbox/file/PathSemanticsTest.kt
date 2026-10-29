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
 * ---------------------------------------------------------------------------
 * 移植来源
 * ---------------------------------------------------------------------------
 * 上游：baicodex (mubai0122/baicodex) @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95
 *   原文件：app/src/main/kotlin/b/ai/core/Paths.kt 与 b/ai/exec/Router.kt 的 normalize()
 *           （被验证的行为：`~/` 展开、相对路径处理、`//` 折叠）
 *
 * 本测试**不依赖 android.***：PathSemantics / HostPath / SandboxPath 都是纯 Kotlin。
 * 唯一的 android 相关类型是 PathView（它只依赖 Parcel/Parceable 的声明，
 * 在 unit test 里用 `testOptions.unitTests.isReturnDefaultValues` 即可，
 * 而这里根本没碰 Parcel —— 只用了它的 wireValue 与枚举本身）。
 */

package com.heracles.sandbox.file

import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PathSemantics] 与两个路径类型的测试。
 *
 * <p>核心断言（这就是本任务要证明的东西）：
 * 1. **同一字符串在两套语义下指向不同文件** —— 用同一份输入分别走
 *    HOST 与 SANDBOX 解析，断言结果不同。
 * 2. 换算双向自洽：`toHost(toSandbox(x)) == x`。
 * 3. **反向映射不是全定义**：rootfs 外的宿主路径 ⇒ null，而不是被伪造成沙箱路径。
 * 4. `..` 逃逸**报错**，不被静默钳制到 `/`。
 * 5. rootfs 未安装时沙箱视角报 `CODE_ROOTFS_NOT_READY`（而不是给出假路径）。
 */
class PathSemanticsTest {

    /** 典型的 rootfs 宿主位置。 */
    private val rootfsHost = "/data/user/0/com.theohowie.heracles/files/sandbox/rootfs"

    private fun semantics(): PathSemantics = PathSemantics.fixed(rootfsHost)

    // ── 1. 两套语义确实不同（本任务的核心命题）──────────────────────────

    @Test
    fun `the same string resolves to different files under the two views`() {
        val semantics = semantics()
        // 同一个输入字符串
        val input = "/data/data/com.example/app.bin"

        val hostResolved = semantics.resolveForFileIo(input, PathView.HOST)
        val sandboxResolved = semantics.resolveForFileIo(input, PathView.SANDBOX)

        // HOST：原样，就是真实的 /data/data/…
        assertEquals("/data/data/com.example/app.bin", hostResolved.host.value)
        // SANDBOX：被映射到 rootfs 之下 —— 完全不同的文件
        assertEquals("$rootfsHost/data/data/com.example/app.bin", sandboxResolved.host.value)

        // ★ 这就是「同一个字符串指向不同文件」的可执行证明
        assertNotEquals(hostResolved.host.value, sandboxResolved.host.value)

        // 各自回给宿主的路径仍保持调用方语义
        assertEquals(input, hostResolved.reportedPath)
        assertEquals(input, sandboxResolved.reportedPath)
        assertEquals(PathView.HOST, hostResolved.view)
        assertEquals(PathView.SANDBOX, sandboxResolved.view)
    }

    @Test
    fun `workspace path only exists as a host path after mapping`() {
        val semantics = semantics()
        val sandbox = SandboxPath.parse("/workspace/a.txt")
        val host = semantics.toHost(sandbox)

        assertEquals("$rootfsHost/workspace/a.txt", host.value)
        // 沙箱视角的字符串在宿主上并不直接存在
        assertNotEquals("/workspace/a.txt", host.value)
    }

    // ── 2. 双向自洽 ────────────────────────────────────────────────────

    @Test
    fun `round trip sandbox to host and back is stable`() {
        val semantics = semantics()
        listOf("/", "/workspace", "/workspace/a.txt", "/usr/bin/sh", "/etc/os-release").forEach { raw ->
            val sandbox = SandboxPath.parse(raw)
            val host = semantics.toHost(sandbox)
            val back = semantics.toSandbox(host)
            assertEquals("往返后应相等：$raw", sandbox, back)
        }
    }

    @Test
    fun `round trip host to sandbox and back is stable for paths inside rootfs`() {
        val semantics = semantics()
        listOf(
            rootfsHost,
            "$rootfsHost/workspace/a.txt",
            "$rootfsHost/usr/lib/libc.so",
        ).forEach { raw ->
            val host = HostPath.parse(raw)
            val sandbox = semantics.toSandbox(host)
            assertNotNull("rootfs 内的路径应可映射：$raw", sandbox)
            assertEquals(host, semantics.toHost(sandbox!!))
        }
    }

    @Test
    fun `the rootfs root itself maps to sandbox root`() {
        val semantics = semantics()
        assertEquals(SandboxPath.ROOT, semantics.toSandbox(HostPath.parse(rootfsHost)))
        assertEquals(rootfsHost, semantics.toHost(SandboxPath.ROOT).value)
    }

    // ── 3. 反向映射不是全定义 ──────────────────────────────────────────

    @Test
    fun `host paths outside the rootfs have no sandbox counterpart`() {
        val semantics = semantics()
        listOf(
            "/sdcard/Download/a.txt",
            "/data/data/com.example/app.bin",
            "/system/bin/sh",
            "/",
        ).forEach { raw ->
            assertNull("$raw 不在 rootfs 内，不应映射到沙箱", semantics.toSandbox(HostPath.parse(raw)))
            assertNull(semantics.hostToSandbox(raw))
        }
    }

    @Test
    fun `sibling directory with a shared prefix is not treated as inside rootfs`() {
        val semantics = semantics()
        // 前缀相同但不是一个目录：必须靠路径段判断，不能靠 startsWith 字符串
        val sibling = HostPath.parse("${rootfsHost}2/workspace/a.txt")
        assertNull(semantics.toSandbox(sibling))
        assertFalse(sibling.isUnder(HostPath.parse(rootfsHost)))
    }

    // ── 4. rootfs 未安装 ──────────────────────────────────────────────

    @Test
    fun `sandbox view fails with ROOTFS_NOT_READY when rootfs is not installed`() {
        val semantics = PathSemantics.notInstalled()

        val error = assertThrows(SandboxException::class.java) {
            semantics.resolveForFileIo("/workspace/a.txt", PathView.SANDBOX)
        }
        assertEquals(SandboxException.CODE_ROOTFS_NOT_READY, error.code)
        assertTrue(error.message!!.contains("/workspace/a.txt"))

        // 而 HOST 视角完全不受影响 —— 这就是「零宽通道不依赖 rootfs」的体现
        val host = semantics.resolveForFileIo("/sdcard/a.txt", PathView.HOST)
        assertEquals("/sdcard/a.txt", host.host.value)
        assertNull(semantics.rootfsHostRoot())
        assertNull(semantics.toSandbox(HostPath.parse("/sdcard/a.txt")))
    }

    @Test
    fun `rootfs root provider is re-read so install and reset are picked up`() {
        // 用可变 lambda 模拟「先没装、后装上」
        var root: HostPath? = null
        val semantics = PathSemantics { root }

        assertEquals(SandboxException.CODE_ROOTFS_NOT_READY, assertThrows(SandboxException::class.java) {
            semantics.toHost(SandboxPath.parse("/workspace"))
        }.code)

        root = HostPath.parse(rootfsHost)
        assertEquals("$rootfsHost/workspace", semantics.toHost(SandboxPath.parse("/workspace")).value)
    }

    // ── 5. 归一化：宿主视角 ───────────────────────────────────────────

    @Test
    fun `host normalize collapses duplicate slashes and dots`() {
        assertEquals("/sdcard/a.txt", HostPath.parse("/sdcard//a.txt").value)
        assertEquals("/sdcard/a.txt", HostPath.parse("/sdcard/./a.txt").value)
        assertEquals("/sdcard/a.txt", HostPath.parse("/sdcard/b/../a.txt").value)
        assertEquals("/sdcard", HostPath.parse("/sdcard/").value)
    }

    @Test
    fun `host normalize strips surrounding quotes and whitespace`() {
        // 模型常把路径写成带引号或带空白的样子（上游 Router.normalize 同款处理）
        assertEquals("/sdcard/a b.txt", HostPath.parse("  \"/sdcard/a b.txt\"  ").value)
        assertEquals("/sdcard/a.txt", HostPath.parse("'/sdcard/a.txt'").value)
    }

    @Test
    fun `host relative path is rejected instead of being guessed`() {
        listOf("a.txt", "./a.txt", "sub/a.txt").forEach { raw ->
            val error = assertThrows(SandboxException::class.java) { HostPath.parse(raw) }
            assertEquals("$raw 应被拒", SandboxException.CODE_INVALID_ARGUMENT, error.code)
            assertTrue(error.message!!.contains("绝对路径"))
        }
    }

    @Test
    fun `host tilde is rejected because there is no assumed home`() {
        val error = assertThrows(SandboxException::class.java) { HostPath.parse("~/a.txt") }
        assertEquals(SandboxException.CODE_INVALID_ARGUMENT, error.code)
        assertTrue(error.message!!.contains("~"))
    }

    @Test
    fun `empty host path is rejected`() {
        listOf("", "   ", "\"\"").forEach { raw ->
            val error = assertThrows(SandboxException::class.java) { HostPath.parse(raw) }
            assertEquals(SandboxException.CODE_INVALID_ARGUMENT, error.code)
        }
    }

    // ── 6. 归一化：沙箱视角 ───────────────────────────────────────────

    @Test
    fun `sandbox relative path resolves against workspace`() {
        // 与宿主侧不同：沙箱侧有确定的基准，所以相对路径是**合法**的
        assertEquals("/workspace/a.txt", SandboxPath.parse("a.txt").value)
        assertEquals("/workspace/sub/a.txt", SandboxPath.parse("sub/a.txt").value)
        assertEquals("/workspace/a.txt", SandboxPath.parse("./a.txt").value)
    }

    @Test
    fun `sandbox tilde maps to workspace`() {
        assertEquals("/workspace", SandboxPath.parse("~").value)
        assertEquals("/workspace/a.txt", SandboxPath.parse("~/a.txt").value)
    }

    @Test
    fun `sandbox normalize folds parents and duplicate slashes`() {
        assertEquals("/workspace/a.txt", SandboxPath.parse("/workspace//a.txt").value)
        assertEquals("/usr/bin", SandboxPath.parse("/usr/local/../bin").value)
        assertEquals("/", SandboxPath.parse("/").value)
        // 根下的 `.` 与重复斜杠可以抵掉，但 `..` 不能 —— 那是越界（见下面的逃逸测试）
        assertEquals("/", SandboxPath.parse("/.//.").value)
    }

    // ── 7. `..` 逃逸必须报错，不许静默钳制 ─────────────────────────────

    @Test
    fun `escaping above root is an error not a silent clamp`() {
        listOf("/..", "/../etc/passwd", "/a/../../b").forEach { raw ->
            val error = assertThrows("$raw 应被拒", SandboxException::class.java) {
                SandboxPath.parse(raw)
            }
            assertEquals(SandboxException.CODE_INVALID_ARGUMENT, error.code)
            // 明确断言「不是被钳制到 /」—— 钳制会让越权读变成合法读
            assertTrue(error.message!!.contains("越界"))
        }
    }

    @Test
    fun `host escaping above root is also an error`() {
        val error = assertThrows(SandboxException::class.java) { HostPath.parse("/../a") }
        assertEquals(SandboxException.CODE_INVALID_ARGUMENT, error.code)
    }

    @Test
    fun `escaping rootfs via sandbox path is blocked before mapping`() {
        val semantics = semantics()
        // 即便 rootfs 已装，越界路径也必须先在解析阶段被拒
        assertThrows(SandboxException::class.java) {
            semantics.resolveForFileIo("../../etc/passwd", PathView.SANDBOX)
        }
        // 而到 workspace 的上级是合法的（还在根内）
        assertEquals(
            "$rootfsHost/etc/passwd",
            semantics.resolveForFileIo("../etc/passwd", PathView.SANDBOX).host.value,
        )
    }

    // ── 8. 类型层面：两套路径不通用 ────────────────────────────────────

    @Test
    fun `host and sandbox paths carry different pathView values`() {
        assertEquals(PathView.HOST, HostPath.parse("/a").pathView)
        assertEquals(PathView.SANDBOX, SandboxPath.parse("/a").pathView)
        // wire 值不同，因此跨 AIDL 时不会混淆
        assertEquals(0, HostPath.parse("/a").pathView.wireValue)
        assertEquals(1, SandboxPath.parse("/a").pathView.wireValue)
    }

    @Test
    fun `path helpers behave on segment boundaries`() {
        val host = HostPath.parse("/sdcard/Download/a.txt")
        assertEquals("/sdcard/Download", host.parent().value)
        assertEquals("a.txt", host.name())
        assertTrue(host.isUnder(HostPath.parse("/sdcard")))
        assertFalse(host.isUnder(HostPath.parse("/sdcar")))
        assertEquals("Download/a.txt", host.relativeTo(HostPath.parse("/sdcard")))

        val sandbox = SandboxPath.parse("/workspace/sub/b.sh")
        assertEquals("b.sh", sandbox.name())
        assertTrue(sandbox.isUnder(SandboxPath.WORKSPACE))
    }

    // ── 9. PathResolver SPI 形态 ──────────────────────────────────────

    @Test
    fun `implements the runtime PathResolver SPI shapes`() {
        val semantics = semantics()
        // runtime 的接口是 String -> String；这里确认包装形态正确
        assertEquals("$rootfsHost/workspace/a.txt", semantics.sandboxToHost("/workspace/a.txt"))
        assertEquals("/workspace/a.txt", semantics.hostToSandbox("$rootfsHost/workspace/a.txt"))
        assertEquals(rootfsHost, semantics.rootfsHostRoot())
    }

    @Test
    fun `DEFAULT_VIEWS stay distinct in the decision table`() {
        // 决策表的两个锚点值（代码里多处引用，改它们就是改语义）
        assertEquals("/workspace", SandboxPath.WORKSPACE.value)
        assertEquals("/", SandboxPath.ROOT.value)
        assertEquals("/", HostPath.ROOT.value)
    }
}
