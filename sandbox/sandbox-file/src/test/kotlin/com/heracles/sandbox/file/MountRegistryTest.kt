/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * 命名挂载层的单元测试（纯 JVM，不需要设备）。
 *
 * 覆盖验收要求的四条：
 *   1. 未注册 @name → 报错
 *   2. readOnly 条目 writeFile → 宿主侧拒绝，返回 MountReadOnlyException
 *   3. 三种 backend 各自的 read/write 路径
 *   4. execute 命令串里的 @name/... 被正确解析
 */

package com.heracles.sandbox.file

import com.heracles.sandbox.api.MountBackend
import com.heracles.sandbox.api.MountEntry
import com.heracles.sandbox.api.MountReadOnlyException
import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

class MountRegistryTest {

    private lateinit var tmp: File
    private lateinit var rootfs: File
    private lateinit var registry: MountRegistry

    @Before
    fun setUp() {
        tmp = Files.createTempDirectory("mount-test").toFile()
        rootfs = File(tmp, "rootfs").apply { mkdirs() }
        registry = MountRegistry { rootfs.absolutePath }
    }

    @After
    fun tearDown() {
        tmp.deleteRecursively()
    }

    // ── 注册 / 校验 ────────────────────────────────────────────────────

    @Test
    fun `register 合法条目成功`() {
        registry.register(
            MountEntry(
                name = "workspace",
                backend = MountBackend.ROOTFS_RELATIVE,
                hostPath = "workspace",
                description = "工作区",
            ),
        )
        assertTrue(registry.contains("workspace"))
        assertEquals(1, registry.size)
    }

    @Test
    fun `register 非法名字被拒`() {
        try {
            registry.register(MountEntry(name = "Bad Name", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "x"))
            fail("应当拒绝非法名字")
        } catch (e: SandboxException) {
            assertEquals(SandboxException.CODE_INVALID_ARGUMENT, e.code)
        }
    }

    @Test
    fun `ROOTFS_RELATIVE 必须用相对路径`() {
        try {
            registry.register(
                MountEntry(name = "w", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "/abs/path"),
            )
            fail("应当拒绝绝对路径")
        } catch (e: SandboxException) {
            assertTrue(e.message!!.contains("相对"))
        }
    }

    @Test
    fun `HOST_PRIVATE_DIR 必须用绝对路径`() {
        try {
            registry.register(
                MountEntry(name = "l", backend = MountBackend.HOST_PRIVATE_DIR, hostPath = "rel/path"),
            )
            fail("应当拒绝相对路径")
        } catch (e: SandboxException) {
            assertTrue(e.message!!.contains("绝对"))
        }
    }

    @Test
    fun `SAF_TREE 必须有 content URI 且不得给 hostPath`() {
        try {
            registry.register(MountEntry(name = "s", backend = MountBackend.SAF_TREE, treeUri = "/file/x"))
            fail("应当拒绝非 content:// URI")
        } catch (e: SandboxException) {
            assertTrue(e.message!!.contains("content://"))
        }
        try {
            registry.register(
                MountEntry(
                    name = "s", backend = MountBackend.SAF_TREE,
                    treeUri = "content://tree/x", hostPath = "/should/not/be/here",
                ),
            )
            fail("应当拒绝给 SAF 挂 hostPath")
        } catch (e: SandboxException) {
            assertTrue(e.message!!.contains("不应"))
        }
    }

    @Test
    fun `SAF_TREE 不允许 bindTo`() {
        try {
            registry.register(
                MountEntry(
                    name = "s", backend = MountBackend.SAF_TREE,
                    treeUri = "content://tree/x", bindTo = "/mnt/s",
                ),
            )
            fail("SAF 不应允许 bindTo")
        } catch (e: SandboxException) {
            assertTrue(e.message!!.contains("bindTo"))
        }
    }

    @Test
    fun `同名覆盖且列表不重复`() {
        registry.register(MountEntry(name = "w", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "a"))
        registry.register(MountEntry(name = "w", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "b"))
        assertEquals(1, registry.size)
        assertEquals("b", registry.get("w")!!.hostPath)
    }

    @Test
    fun `list 顺序稳定`() {
        registry.register(MountEntry(name = "a", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "a"))
        registry.register(MountEntry(name = "b", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "b"))
        registry.register(MountEntry(name = "c", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "c"))
        assertEquals(listOf("@a", "@b", "@c"), registry.list().map { it.prefix })
    }

    // ── MountBindSource ───────────────────────────────────────────────

    @Test
    fun `只有 wantsBind 的条目会进 bind 列表`() {
        registry.register(MountEntry(name = "a", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "a", bindTo = "/mnt/a"))
        registry.register(MountEntry(name = "b", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "b"))
        val binds = registry.bindMounts()
        assertEquals(1, binds.size)
        assertEquals("/mnt/a", binds[0].guestPath)
        assertTrue(normPath(binds[0].hostPath).endsWith("/rootfs/a"))
    }

    @Test
    fun `rootfs 未就绪时 ROOTFS_RELATIVE 不进 bind 列表`() {
        val noRootfs = MountRegistry { null }
        noRootfs.register(MountEntry(name = "a", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "a", bindTo = "/mnt/a"))
        assertTrue(noRootfs.bindMounts().isEmpty())
    }
}

/**
 * 解析器测试：三种 backend 的读/写路径 + 只读拒绝 + 未注册报错。
 */
class MountResolverTest {

    private lateinit var tmp: File
    private lateinit var rootfs: File
    private lateinit var privateDir: File
    private lateinit var registry: MountRegistry
    private lateinit var fakeSaf: FakeSafIo
    private lateinit var resolver: MountResolver


    @Before
    fun setUp() {
        tmp = Files.createTempDirectory("resolver-test").toFile()
        rootfs = File(tmp, "rootfs").apply { mkdirs() }
        privateDir = File(tmp, "private").apply { mkdirs() }
        registry = MountRegistry { rootfs.absolutePath }
        fakeSaf = FakeSafIo()
        resolver = MountResolver(registry, fakeSaf)

        registry.register(
            MountEntry(
                name = "workspace", backend = MountBackend.ROOTFS_RELATIVE,
                hostPath = "workspace", description = "工作区（读写）",
            ),
        )
        registry.register(
            MountEntry(
                name = "libs", backend = MountBackend.HOST_PRIVATE_DIR,
                hostPath = privateDir.absolutePath, readOnly = true,
                description = "共享库（只读）",
            ),
        )
        registry.register(
            MountEntry(
                name = "pc_shared", backend = MountBackend.SAF_TREE,
                treeUri = "content://com.android.externalstorage.documents/tree/primary%3APC",
                description = "电脑共享目录（SAF）",
            ),
        )
    }

    @After
    fun tearDown() {
        tmp.deleteRecursively()
    }

    // ── ① 未注册 ──────────────────────────────────────────────────────

    @Test
    fun `未注册的 @name 直接报错，不回退猜路径`() {
        try {
            resolver.resolve("@nope/x.txt", forWrite = false)
            fail("应当抛 CODE_MOUNT_UNKNOWN")
        } catch (e: SandboxException) {
            assertEquals(SandboxException.CODE_MOUNT_UNKNOWN, e.code)
            assertTrue("错误里应列出已注册的名字", e.message!!.contains("@workspace"))
        }
    }

    // ── ② 只读拒绝 ────────────────────────────────────────────────────

    @Test
    fun `只读条目写入被宿主侧拒绝并返回可区分的异常`() {
        try {
            resolver.resolve("@libs/x.so", forWrite = true)
            fail("应当抛 MountReadOnlyException")
        } catch (e: MountReadOnlyException) {
            assertEquals("libs", e.mountName)
            assertEquals("@libs/x.so", e.attemptedPath)
            assertEquals(SandboxException.CODE_MOUNT_READ_ONLY, e.code)
        }
    }

    @Test
    fun `只读条目读取不受影响`() {
        val r = resolver.resolve("@libs/x.so", forWrite = false)
        assertTrue(r is ResolvedMount.Physical)
        assertTrue(normPath((r as ResolvedMount.Physical).hostPath).startsWith(normPath(privateDir.absolutePath)))
    }

    // ── ③ 三种 backend ───────────────────────────────────────────────

    @Test
    fun `ROOTFS_RELATIVE 解析到 rootfs 内物理路径`() {
        val r = resolver.resolve("@workspace/src/a.txt", forWrite = true) as ResolvedMount.Physical
        assertEquals(normPath(File(rootfs, "workspace/src/a.txt").absolutePath), normPath(r.hostPath))
    }

    @Test
    fun `HOST_PRIVATE_DIR 解析到宿主私有目录`() {
        val r = resolver.resolve("@libs/sub/a.so", forWrite = false) as ResolvedMount.Physical
        assertEquals(normPath(File(privateDir, "sub/a.so").absolutePath), normPath(r.hostPath))
    }

    @Test
    fun `SAF_TREE 保持为 SAF 文档，不转物理路径`() {
        val r = resolver.resolve("@pc_shared/docs/a.txt", forWrite = true)
        assertTrue("SAF 不能变成物理路径", r is ResolvedMount.Saf)
        val saf = r as ResolvedMount.Saf
        assertEquals("docs/a.txt", saf.relativePath)
        assertTrue(saf.entry.treeUri.startsWith("content://"))
    }

    @Test
    fun `不带 @ 的路径原样返回（不破坏既有语义）`() {
        val r = resolver.resolve("/data/local/tmp/a", forWrite = false)
        assertTrue(r is ResolvedMount.Plain)
        assertEquals("/data/local/tmp/a", (r as ResolvedMount.Plain).raw)
    }

    // ── ④ execute 命令改写 ───────────────────────────────────────────

    @Test
    fun `命令里的 @workspace 被改写成 guest 路径`() {
        // 命令在 PRoot guest 里跑，所以要换成 **guest 路径**而不是宿主路径。
        // 但 @workspace 的 hostPath="workspace" 正好落在标准 bind `/workspace` 覆盖区，
        // 这种情况必须**明确报错**（否则 guest 里会读到宿主工作区，静默错）。
        try {
            resolver.rewriteCommand("cat @workspace/a.txt")
            fail("落在 bind 覆盖区的 ROOTFS_RELATIVE 应报错")
        } catch (e: SandboxException) {
            assertEquals(SandboxException.CODE_INVALID_ARGUMENT, e.code)
            assertTrue("错误里应说明原因", e.message!!.contains("bind"))
        }
    }

    @Test
    fun `不在 bind 覆盖区的 ROOTFS_RELATIVE 在命令里用 guest 路径`() {
        registry.register(
            MountEntry(name = "optws", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "opt/ws"),
        )
        val out = resolver.rewriteCommand("cat @optws/a.txt")
        assertEquals("cat /opt/ws/a.txt", out)
    }

    @Test
    fun `配了 bindTo 的挂载点在命令里用 bindTo 路径`() {
        registry.register(
            MountEntry(
                name = "wbind", backend = MountBackend.ROOTFS_RELATIVE,
                hostPath = "workspace", bindTo = "/opt/wbind",
            ),
        )
        val out = resolver.rewriteCommand("cat @wbind/a.txt")
        assertEquals("cat /opt/wbind/a.txt", out)
    }

    @Test
    fun `HOST_PRIVATE_DIR 没配 bindTo 时在命令里明确报错`() {
        try {
            resolver.rewriteCommand("cat @libs/b.so")
            fail("宿主私有目录在 guest 内不可见，应报错")
        } catch (e: SandboxException) {
            assertEquals(SandboxException.CODE_INVALID_ARGUMENT, e.code)
            assertTrue("错误里应建议设置 bindTo", e.message!!.contains("bindTo"))
        }
    }

    @Test
    fun `命令里的多个 @name 都被改写（配好 bindTo）`() {
        registry.register(
            MountEntry(
                name = "wb2", backend = MountBackend.ROOTFS_RELATIVE,
                hostPath = "workspace", bindTo = "/opt/wb2",
            ),
        )
        registry.register(
            MountEntry(
                name = "lb2", backend = MountBackend.HOST_PRIVATE_DIR,
                hostPath = privateDir.absolutePath, bindTo = "/opt/lb2",
            ),
        )
        val out = resolver.rewriteCommand("@wb2/a @lb2/b.so")
        assertEquals("@wb2/a @lb2/b.so 都应被改写：$out", "/opt/wb2/a /opt/lb2/b.so", out)
        assertFalse("不应残留 @name", out.contains("@wb2"))
        assertFalse("不应残留 @name", out.contains("@lb2"))
    }

    @Test
    fun `命令里未注册的 @name 报错而不是原样传给 shell`() {
        try {
            resolver.rewriteCommand("cat @nope/x")
            fail("应当抛 CODE_MOUNT_UNKNOWN")
        } catch (e: SandboxException) {
            assertEquals(SandboxException.CODE_MOUNT_UNKNOWN, e.code)
        }
    }

    @Test
    fun `命令里出现 SAF 挂载点被明确拒绝`() {
        try {
            resolver.rewriteCommand("cat @pc_shared/a.txt")
            fail("SAF 无物理路径，命令里用不了")
        } catch (e: SandboxException) {
            assertEquals(SandboxException.CODE_INVALID_ARGUMENT, e.code)
            assertTrue(e.message!!.contains("SAF"))
        }
    }

    @Test
    fun `不含 @ 的命令原样返回`() {
        val cmd = "echo hello && ls -l /tmp"
        assertEquals(cmd, resolver.rewriteCommand(cmd))
    }

    @Test
    fun `邮箱样式不应被误改`() {
        val cmd = "echo someone@example.com"
        assertEquals(cmd, resolver.rewriteCommand(cmd))
    }

    @Test
    fun `路径穿越被拒`() {
        try {
            resolver.resolve("@workspace/../../etc/passwd", forWrite = false)
            fail("应拒绝 ..")
        } catch (e: SandboxException) {
            assertEquals(SandboxException.CODE_INVALID_ARGUMENT, e.code)
        }
    }
}

/**
 * 与 [SandboxFileService] 的集成：验证只读通过**文件服务**也被拒，
 * 且 SAF 走的是 SAF API（可通过 fake 的调用计数证明没有走文件系统）。
 */
class MountFileServiceIntegrationTest {

    private lateinit var tmp: File
    private lateinit var rootfs: File
    private lateinit var privateDir: File
    private lateinit var registry: MountRegistry
    private lateinit var fakeSaf: FakeSafIo
    private lateinit var service: SandboxFileService

    @Before
    fun setUp() {
        tmp = Files.createTempDirectory("svc-test").toFile()
        rootfs = File(tmp, "rootfs").apply { mkdirs() }
        privateDir = File(tmp, "private").apply { mkdirs() }
        registry = MountRegistry { rootfs.absolutePath }
        fakeSaf = FakeSafIo()
        val caseInsensitiveHost = PathSemantics { com.heracles.sandbox.file.HostPath(rootfs.absolutePath) }
        service = SandboxFileService(
            pathSemantics = caseInsensitiveHost,
            zeroWidth = null,
            mountResolver = MountResolver(registry, fakeSaf),
        )
        registry.register(
            MountEntry(name = "workspace", backend = MountBackend.ROOTFS_RELATIVE, hostPath = "workspace"),
        )
        registry.register(
            MountEntry(
                name = "libs", backend = MountBackend.HOST_PRIVATE_DIR,
                hostPath = privateDir.absolutePath, readOnly = true,
            ),
        )
        registry.register(
            MountEntry(
                name = "pc_shared", backend = MountBackend.SAF_TREE,
                treeUri = "content://tree/pc",
            ),
        )
    }

    @After
    fun tearDown() {
        tmp.deleteRecursively()
    }

    @Test
    fun `writeFile 到只读挂载点返回只读错误码`() {
        val r = service.write("@libs/x.so", "data".toByteArray(), PathView.HOST)
        assertFalse(r.success)
        assertEquals(SandboxException.CODE_MOUNT_READ_ONLY, r.errorCode)
    }

    @Test
    fun `writeFile 到可写挂载点成功并能读回`() {
        File(rootfs, "workspace").mkdirs()
        val w = service.write("@workspace/a.txt", "hello-sandbox".toByteArray(), PathView.HOST)
        assertTrue("写入应成功：${w.errorMessage}", w.success)

        val r = service.read("@workspace/a.txt", PathView.HOST)
        assertTrue("读取应成功：${r.errorMessage}", r.success)
        assertEquals("hello-sandbox", r.asText())
    }

    @Test
    fun `SAF 挂载点的读写走 SAF API 而不是文件系统`() {
        val w = service.write("@pc_shared/docs/a.txt", "saf-data".toByteArray(), PathView.HOST)
        assertTrue("SAF 写入应成功：${w.errorMessage}", w.success)
        assertEquals("应当调用 SAF write", 1, fakeSaf.writeCount)

        val r = service.read("@pc_shared/docs/a.txt", PathView.HOST)
        assertTrue(r.success)
        assertEquals("saf-data", r.asText())
        assertEquals("应当调用 SAF read", 1, fakeSaf.readCount)
    }

    @Test
    fun `SAF 只读挂载点写入被拒绝且不调用 SAF`() {
        registry.register(
            MountEntry(
                name = "pc_ro", backend = MountBackend.SAF_TREE,
                treeUri = "content://tree/ro", readOnly = true,
            ),
        )
        val before = fakeSaf.writeCount
        val r = service.write("@pc_ro/a.txt", "x".toByteArray(), PathView.HOST)
        assertFalse(r.success)
        assertEquals(SandboxException.CODE_MOUNT_READ_ONLY, r.errorCode)
        assertEquals("只读拒绝不应触达 SAF", before, fakeSaf.writeCount)
    }

    @Test
    fun `未注册挂载点返回 MOUNT_UNKNOWN`() {
        val r = service.read("@nope/a.txt", PathView.HOST)
        assertFalse(r.success)
        assertEquals(SandboxException.CODE_MOUNT_UNKNOWN, r.errorCode)
    }

    @Test
    fun `不带 @ 的路径仍然按原语义工作`() {
        val plain = File(tmp, "plain.txt")
        plain.writeText("plain-content")
        val r = service.read(plain.absolutePath, PathView.HOST)
        assertTrue("普通物理路径读取不应受影响：${r.errorMessage}", r.success)
        assertEquals("plain-content", r.asText())
    }
}

/**
 * 假 SAF 实现：用内存 map 模拟文档存储。
 *
 * 用途不止是省事 —— 它让测试能**证明**「SAF 分支没有偷偷走文件系统」：
 * 只要 `readCount`/`writeCount` 动了，就说明确实走了 SAF API。
 */
/**
 * 路径归一化：把 Windows 的 `\` 统一成 `/` 再比较。
 *
 * 为什么需要：解析器拼路径**永远用 `/`**（目标是 Android），
 * 而 JVM 单测跑在 Windows 上时 `File.absolutePath` 给的是 `F:\...`。
 * 直接字符串相等会在 Windows 上假红 —— 这不是产品缺陷，是测试口径问题。
 */
internal fun normPath(p: String): String = p.replace('\\', '/')

internal class FakeSafIo : SafDocumentIo {
    val store = mutableMapOf<Pair<String, String>, ByteArray>()
    var readCount = 0
    var writeCount = 0

    override fun read(treeUri: String, relativePath: String, maxBytes: Long): ByteArray? {
        readCount++
        val data = store[treeUri to relativePath] ?: return null
        return if (maxBytes > 0 && data.size > maxBytes) data.copyOf(maxBytes.toInt()) else data
    }

    override fun write(treeUri: String, relativePath: String, data: ByteArray): Boolean {
        writeCount++
        store[treeUri to relativePath] = data
        return true
    }

    override fun exists(treeUri: String, relativePath: String): Boolean =
        store.containsKey(treeUri to relativePath)
}