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
 * ============================================================================
 * 沙箱边界加固（B6，task-20）的 JVM 单测 —— 不需要 Android 设备
 * ============================================================================
 * 为什么这些断言值得存在（它们锁的是「泄漏面」而不是「代码风格」）：
 *   PRoot 的 `-b` 是**唯一**能把宿主路径塞进 guest 的入口。改动前
 *   `HOST_SYSTEM_BINDINGS` 绑了 /proc /sys /system /system_ext /vendor /product
 *   /odm /apex /data/app /data/dalvik-cache /linkerconfig ...，真机实测（见
 *   .docs/实测-20-沙箱边界.md）后果是：
 *     - guest 里 `ls /system` 能看到宿主 build.prop/app/bin/apex；
 *     - guest 里 `ls /data` 能看到宿主 app/dalvik-cache；
 *     - guest 里 `head /proc/self/maps` 能读到宿主进程映射（含 /data/app 绝对路径）。
 *   加固后**只绑设备节点**（/dev、/dev/pts），宿主系统路径一律不进 guest。
 *
 * 这些断言全部是「命令行/常量可见」的，所以不依赖设备：
 *   1. argv 里的 `-b` 只允许 4 个沙箱自有目录（+ 设备节点，若宿主有 /dev）；
 *   2. argv 里不允许出现任何宿主系统路径（/proc /sys /system /apex /data ...）；
 *   3. 宿主进程环境只允许白名单键（PRoot 会把 environ 透传给 guest）；
 *   4. `validateBind` 对 `/proc` `/sys` `/dev` `/data` `/system` 目标必须拒绝，
 *      且对白名单目标必须放行（对照，证明不是"全拒"造成的假绿）。
 *
 * 变异验证（改代码必须能变红）：
 *   把 "/proc" 加回 [ProotEngine.HOST_DEVICE_BINDINGS] ⇒ 断言 1/2/3(设备节点清单) 变红；
 *   在 hostEnvironment() 里加一个 `put("ANDROID_DATA", ...)` ⇒ 环境白名单断言变红。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ProotEngineBoundaryTest {

    private lateinit var sandboxRoot: File
    private lateinit var rootfsDir: File
    private lateinit var workspaceDir: File
    private lateinit var homeDir: File
    private lateinit var tmpDir: File
    private lateinit var attachmentsDir: File
    private lateinit var engine: ProotEngine

    /** 宿主侧**绝不能**被 bind 进 guest 的系统路径根。 */
    private val forbiddenHostRoots = listOf(
        "/proc", "/sys", "/system", "/system_ext", "/vendor", "/product", "/odm",
        "/apex", "/data", "/linkerconfig",
    )

    /** 沙箱自有的四个 guest 绑定目标（默认 spec 下）。 */
    private val sandboxGuestTargets = setOf("/tmp", "/workspace", "/root", "/attachments")

    @Before
    fun setUp() {
        sandboxRoot = Files.createTempDirectory("heracles-boundary-test").toFile()
        rootfsDir = File(sandboxRoot, "rootfs").apply { mkdirs() }
        workspaceDir = File(sandboxRoot, "workspace").apply { mkdirs() }
        homeDir = File(sandboxRoot, "home").apply { mkdirs() }
        tmpDir = File(sandboxRoot, "tmp").apply { mkdirs() }
        attachmentsDir = File(sandboxRoot, "attachments").apply { mkdirs() }
        engine = ProotEngine(
            prootBinary = File(sandboxRoot, "libproot.so"),
            loaderBinary = null,
            rootfsHostRoot = rootfsDir,
            workspaceHostRoot = workspaceDir,
            homeHostRoot = homeDir,
            tmpHostRoot = tmpDir,
            attachmentsHostRoot = attachmentsDir,
        )
    }

    @After
    fun tearDown() {
        sandboxRoot.deleteRecursively()
    }

    // ========================================================================
    // argv 解析小工具
    // ========================================================================

    private fun argv(spec: ProotExecSpec = ProotExecSpec("true")): List<String> =
        engine.buildCommandLine(spec, interactive = false)

    /** 取所有 `-b` 后面的绑定值（原样，可能是 `host:guest` 或只有 `path`）。 */
    private fun bindValues(argv: List<String>): List<String> =
        argv.zipWithNext().filter { (flag, _) -> flag == "-b" }.map { (_, value) -> value }

    /**
     * 绑定值 -> 宿主侧路径。
     *
     * 注意 Windows：宿主路径里本身带盘符冒号（`C:\...`），所以按**最后一个**
     * 冒号切，且只有当冒号后面紧跟 `/`（guest 绝对路径）时才算分隔符；
     * 否则整串就是宿主路径（如 `/dev`、`/dev/pts` 这种原样绑定）。
     */
    private fun hostSideOf(bindValue: String): String {
        val separator = bindValue.lastIndexOf(':')
        return if (separator > 0 && bindValue.getOrNull(separator + 1) == '/') {
            bindValue.substring(0, separator)
        } else {
            bindValue
        }
    }

    private fun guestSideOf(bindValue: String): String? {
        val separator = bindValue.lastIndexOf(':')
        return if (separator > 0 && bindValue.getOrNull(separator + 1) == '/') {
            bindValue.substring(separator + 1)
        } else {
            null
        }
    }

    // ========================================================================
    // 1. 默认 bind 面
    // ========================================================================

    @Test
    fun `设备节点清单只含 dev 与 dev pts`() {
        // 加固的核心不变式：这是**唯一**允许的宿主系统绑定。
        // （变异：在清单里加回 /proc、/sys、/system ... ⇒ 本条与下一条变红）
        assertEquals(
            "宿主系统绑定只允许设备节点；其它宿主路径会变成 guest 可读的泄漏面",
            listOf("/dev", "/dev/pts"),
            ProotEngine.HOST_DEVICE_BINDINGS,
        )
    }

    @Test
    fun `默认命令行不 bind 任何宿主系统路径`() {
        val values = bindValues(argv())
        assertTrue("默认 spec 至少有四个沙箱自有绑定", values.size >= sandboxGuestTargets.size)

        values.forEach { value ->
            val host = hostSideOf(value)
            forbiddenHostRoots.forEach { root ->
                assertFalse(
                    "宿主路径 $host 落进了泄漏面 $root（不允许 bind 进 guest）：$value",
                    host == root || host.startsWith("$root/"),
                )
            }
        }

        // 线上 argv 会被「宿主上是否存在」过滤（Windows 单测机上 /dev 不存在），
        // 所以再对「设备节点都真实存在」的情况单独断言一次 —— 否则「有人往
        // HOST_DEVICE_BINDINGS 里加回 /proc」在 Windows 上会被静默过滤掉、测试假绿。
        ProotEngine.hostDeviceBindsFor { true }.forEach { host ->
            forbiddenHostRoots.forEach { root ->
                assertFalse(
                    "设备节点清单里混进了宿主系统路径 $host（会被 bind 进 guest）",
                    host == root || host.startsWith("$root/"),
                )
            }
        }

        // 整条 argv 里也不该出现这些路径（含 -r/-b 之外的参数）
        val argv = argv()
        listOf("/proc", "/sys", "/system", "/apex", "/data/app", "/data/dalvik-cache",
            "/vendor", "/product", "/odm", "/linkerconfig").forEach { path ->
            assertFalse("argv 里不应出现宿主系统路径 $path：$argv", argv.contains(path))
        }
    }

    @Test
    fun `默认 bind 的宿主侧只能是沙箱自有目录或设备节点`() {
        val allowedHosts = mutableSetOf(
            tmpDir.absolutePath,
            workspaceDir.absolutePath,
            homeDir.absolutePath,
            attachmentsDir.absolutePath,
        )
        allowedHosts += ProotEngine.HOST_DEVICE_BINDINGS
        bindValues(argv()).forEach { value ->
            assertTrue(
                "绑定源 ${hostSideOf(value)} 不在白名单（只允许沙箱自有目录与设备节点）",
                hostSideOf(value) in allowedHosts,
            )
        }
        // 同上：设备节点用「都真实存在」再断言一遍，防止 Windows 上被过滤掉而假绿
        val deviceHosts = setOf("/dev", "/dev/pts")
        ProotEngine.hostDeviceBindsFor { true }.forEach { host ->
            assertTrue("设备节点绑定只允许 /dev 与 /dev/pts，实际有 $host", host in deviceHosts)
        }
    }

    @Test
    fun `默认 bind 的 guest 侧只有四个沙箱自有目标`() {
        // 设备节点是「原样绑定」（host=guest=/dev），没有显式 guest 侧 ⇒ guestSideOf 为 null。
        val guests = bindValues(argv()).mapNotNull { guestSideOf(it) }.toSet()
        assertEquals(sandboxGuestTargets, guests)
    }

    @Test
    fun `额外挂载也只允许白名单 guest 目标`() {
        // 对照：白名单里的额外挂载仍然可用（不要为了加固把功能一起砍掉）。
        val bound = engine.validateBind(BindMount(sandboxRoot.absolutePath, "/workspace/extra"))
        assertTrue("白名单内的额外挂载必须放行：$bound", bound.endsWith(":/workspace/extra"))

        // 越权目标逐条拒绝：proc/sys/dev/data/system 都是宿主或伪文件系统
        listOf("/proc", "/sys", "/dev", "/data", "/data/data", "/system", "/apex").forEach { guest ->
            assertThrows(
                "guest 目标 $guest 在 ALLOWED_BIND_TARGETS 之外时必须拒绝",
                SandboxException::class.java,
            ) {
                engine.validateBind(BindMount(sandboxRoot.absolutePath, guest))
            }
        }
    }

    @Test
    fun `ALLOWED_BIND_TARGETS 不含宿主系统路径`() {
        val targets = ProotEngine.ALLOWED_BIND_TARGETS
        assertTrue(
            "四个沙箱自有目录必须在白名单里",
            targets.containsAll(sandboxGuestTargets),
        )
        forbiddenHostRoots.forEach { root ->
            assertFalse(
                "ALLOWED_BIND_TARGETS 不应包含 $root（会把宿主路径塞进 guest）",
                targets.contains(root),
            )
        }
        // /dev 也不能作为「额外挂载目标」被调用方指定（设备节点由我们内部绑定）
        assertFalse(targets.contains("/dev"))
    }

    @Test
    fun `guest 目标里的点点穿越必须拒绝`() {
        assertThrows(SandboxException::class.java) {
            engine.validateBind(BindMount(sandboxRoot.absolutePath, "/workspace/../proc"))
        }
        assertThrows(SandboxException::class.java) {
            engine.validateBind(BindMount(sandboxRoot.absolutePath, "workspace"))
        }
        assertThrows(SandboxException::class.java) {
            engine.validateBind(BindMount("relative/path", "/workspace"))
        }
    }

    // ========================================================================
    // 2. 启动参数
    // ========================================================================

    @Test
    fun `命令行带 kill-on-exit 且 rootfs 工作目录正确`() {
        val argv = argv()
        assertTrue("PRoot 必须带 --kill-on-exit（退出时收掉 tracee）", argv.contains("--kill-on-exit"))

        val rootfsArg = argv.indexOf("-r")
        assertTrue("必须用 -r 指定 rootfs", rootfsArg >= 0)
        assertEquals(rootfsDir.absolutePath, argv[rootfsArg + 1])

        val workdirArg = argv.indexOf("-w")
        assertTrue("必须用 -w 指定工作目录", workdirArg >= 0)
        assertEquals("/workspace", argv[workdirArg + 1])
    }

    // ========================================================================
    // 3. 宿主进程环境（PRoot 会原样透传给 guest）
    // ========================================================================

    @Test
    fun `宿主环境只包含白名单键`() {
        val env = engine.hostEnvironment()
        val unexpected = env.keys - HOST_ALLOWED_ENV_KEYS
        assertTrue("宿主环境出现白名单外的键：$unexpected", unexpected.isEmpty())
        assertTrue(
            "hostEnvironment 必须注入 TZ（POSIX 串见 TZ 单测）",
            env.containsKey("TZ"),
        )
    }

    @Test
    fun `宿主环境没有敏感变量也没有宿主 PATH 与 HOME`() {
        val env = engine.hostEnvironment()
        listOf("HOME", "PATH", "ANDROID_DATA", "ANDROID_ROOT", "ANDROID_ART_ROOT",
            "http_proxy", "https_proxy", "HTTPS_PROXY").forEach { key ->
            assertFalse("宿主敏感/无关变量 $key 不得注入沙箱环境", env.containsKey(key))
        }
        assertFalse(
            "环境键名里出现 ANDROID_ 前缀一般都是宿主泄漏",
            env.keys.any { it.startsWith("ANDROID_") },
        )
    }

    @Test
    fun `白名单本身不含敏感键`() {
        // 防「为了让测试变绿而把敏感键加进白名单」。
        listOf("HOME", "PATH", "ANDROID_DATA", "ANDROID_ROOT", "http_proxy", "HTTPS_PROXY")
            .forEach { key ->
                assertFalse("白名单不得包含敏感键 $key", key in HOST_ALLOWED_ENV_KEYS)
            }
    }
}
