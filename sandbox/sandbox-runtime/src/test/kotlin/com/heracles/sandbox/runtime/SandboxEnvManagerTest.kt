package com.heracles.sandbox.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **沙箱环境管理测试（V0.4 T0-3）**。
 *
 * 覆盖：profile 只实现 L1 / 网络策略风险标记 / 配方完整性 / 项目识别 / 体积预览。
 */
class SandboxEnvManagerTest {

    // ---- 1. 隔离等级：只实现 process(L1)，container/vm 明确未实现 ----
    @Test
    fun `container and vm are explicitly unimplemented`() {
        val c = SandboxProfile(isolationTier = IsolationTier.CONTAINER)
        assertFalse("container 不许假装已实现", c.implemented)
        assertNotNull(c.unimplementedNote)
        val v = SandboxProfile(isolationTier = IsolationTier.VM)
        assertFalse(v.implemented)
        val p = SandboxProfile()
        assertTrue("process(L1) 是当前唯一实现", p.implemented)
        assertNull(p.unimplementedNote)
    }

    @Test
    fun `tier parse unknown falls back to process`() {
        assertEquals(IsolationTier.PROCESS, IsolationTier.parse("process"))
        assertEquals(IsolationTier.CONTAINER, IsolationTier.parse("container"))
        assertEquals(IsolationTier.PROCESS, IsolationTier.parse("garbage"))
        assertEquals(IsolationTier.PROCESS, IsolationTier.parse(null))
    }

    // ---- 2. 网络策略：默认白名单 / 自由出网=显式+风险标记 / 策略级说明 ----
    @Test
    fun `default network policy is whitelist only and low risk`() {
        val n = NetworkPolicy()
        assertTrue(n.whitelistOnly)
        assertFalse(n.allowAllOutbound)
        assertEquals("low", n.riskLevel)
        assertTrue("UI 必须能看到策略级说明", n.riskNote.contains("策略级"))
        assertTrue("文案必须点明非硬隔离", n.riskNote.contains("非硬隔离"))
    }

    @Test
    fun `allow all outbound is explicit and marked high risk`() {
        val n = NetworkPolicy(allowAllOutbound = true)
        assertEquals("high", n.riskLevel)
        assertTrue(n.riskNote.contains("自由出网"))
        assertTrue("不许宣称硬隔离", n.riskNote.contains("非硬隔离"))
    }

    @Test
    fun `effective hosts include defaults plus extras deduped`() {
        val n = NetworkPolicy(extraHosts = listOf(" Registry.MyCorp.COM ", "registry.npmjs.org"))
        val hosts = n.effectiveHosts()
        assertTrue(hosts.contains("registry.npmjs.org"))
        assertTrue(hosts.contains("registry.mycorp.com"))
        assertEquals(hosts.size.toLong(), hosts.distinct().size.toLong())
    }

    // ---- 3. 配方：Node/Python/Deno/Bun/Go 齐全 + 未知不猜 ----
    @Test
    fun `recipes cover five runtimes with verify commands`() {
        val names = SandboxEnvManager.RECIPES.map { it.name }.toSet()
        assertEquals(setOf("node", "python3", "deno", "bun", "go"), names)
        for (r in SandboxEnvManager.RECIPES) {
            assertTrue("${r.name} 缺安装命令", r.installCommands.isNotEmpty())
            assertTrue("${r.name} 缺校验命令", r.verifyCommand.isNotEmpty())
            assertTrue("${r.name} 缺体积估算", r.approxBytes > 0)
            assertTrue(r.source.isNotEmpty())
        }
    }

    @Test
    fun `unknown recipe returns null instead of guessing`() {
        assertNull(SandboxEnvManager.recipe("ruby"))
        assertNull(SandboxEnvManager.installPreview("ruby"))
        assertNotNull(SandboxEnvManager.recipe("  Node "))
    }

    // ---- 4. 项目识别 ----
    @Test
    fun `detectProject maps manifests to envs`() {
        assertEquals(listOf("node"), SandboxEnvManager.detectProject(listOf("package.json")))
        assertEquals(listOf("python3"), SandboxEnvManager.detectProject(listOf("pyproject.toml")))
        assertEquals(listOf("go"), SandboxEnvManager.detectProject(listOf("go.mod")))
        assertEquals(listOf("deno"), SandboxEnvManager.detectProject(listOf("deno.json")))
        // Flutter 先于 Android（pubspec + gradle 同时存在）
        assertEquals(listOf("flutter"), SandboxEnvManager.detectProject(listOf("pubspec.yaml", "build.gradle")))
        assertEquals(listOf("android"), SandboxEnvManager.detectProject(listOf("build.gradle")))
        // 路径输入取 basename
        assertEquals(listOf("node"), SandboxEnvManager.detectProject(listOf("app/package.json")))
        // 认不出 ⇒ 空（不猜）
        assertTrue(SandboxEnvManager.detectProject(listOf("README.md")).isEmpty())
    }

    // ---- 5. 安装预览 ----
    @Test
    fun `installPreview exposes source and size before install`() {
        val p = requireNotNull(SandboxEnvManager.installPreview("node"))
        assertEquals("node", p["name"])
        assertTrue((p["approxBytes"] as Long) > 0)
        assertTrue((p["installCommands"] as List<*>).isNotEmpty())
    }
}
