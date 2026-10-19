package dev.heracles.agent

import dev.heracles.agent.tools.SearchToolsTool
import dev.heracles.core.provider.FakeProvider
import dev.heracles.core.tool.ToolGroup
import dev.heracles.core.tool.ToolRegistry
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Paths

/**
 * **两段式披露链**的门禁 —— `26-编码层工具链与逆向引擎.md` §5、ADR-023。
 *
 * ## 它防的是一个具体而隐蔽的 bug
 *
 * 设计里"披露 = 工具名进 grammar 枚举"。但**能被 grammar 生成**与
 * **能被派发执行**是两件事：`AgentLoop` 原来两处都只看常驻表 `tools`
 * ⇒ 披露完之后模型生成了 `apk_sign`，校验**通过**，然后在
 * `tools.first { … }` 处 **`NoSuchElementException` 崩掉整个 run**。
 *
 * 所以本文件钉死三件事：
 *
 * 1. 未披露 ⇒ 长尾**不可调用**（`activeTools()` 里没有）
 * 2. 经 `search_tools` 披露 ⇒ 立刻**可调用**，且解析到的是同一个实例
 * 3. ★ **披露不得改动冻结区**（门禁 G13）—— 长尾 schema 一旦进了
 *    冻结前缀，每披露一个工具前缀就长一截，缓存全塌、命中率掉到 0
 */
class DisclosureTest {

    /** 空文件系统替身（这些用例不碰真实 IO）。 */
    private class NoopFs : WorkspaceFs {
        override val info = WorkspaceInfo(Paths.get(".").toAbsolutePath(), "test")
        override suspend fun list(relativeDir: String): List<FileEntry> = emptyList()
        override suspend fun readText(relativePath: String): String = ""
        override suspend fun writeText(relativePath: String, content: String): Long = 0
        override suspend fun exists(relativePath: String): Boolean = false
        override suspend fun mkdirs(relativeDir: String) {}
    }

    /** 记账用工具替身：被调用过几次。 */
    private class SpyTool(override val spec: ToolSpec) : AgentTool {
        var calls = 0
        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            calls++
            return ToolOutcome.Success("已执行 ${spec.name}")
        }
    }

    private val residentSpec = ToolSpec("write_file", "写文件")
    private val signSpec = ToolSpec("apk_sign", "给 APK 签名")

    private fun newLoop(disclosed: MutableSet<String>, tail: List<AgentTool>) = AgentLoop(
        provider = FakeProvider(),
        workspace = NoopFs(),
        tools = listOf(SpyTool(residentSpec)),
        longTail = tail,
        disclosed = disclosed,
    )

    @Test
    @DisplayName("★ 未披露 ⇒ 长尾工具不在 activeTools（也不进 grammar）")
    fun undisclosedLongTailIsInactive() {
        val loop = newLoop(mutableSetOf(), listOf(SpyTool(signSpec)))
        assertEquals(listOf("write_file"), loop.activeTools().map { it.spec.name })
    }

    @Test
    @DisplayName("★★ 披露链：search_tools 命中 → 共享披露集更新 → 长尾立刻可调用（旧实现在此崩）")
    fun searchToolsDisclosureEnablesLongTailCall() = runBlocking {
        val tail = SpyTool(signSpec)
        val disclosed = mutableSetOf<String>()
        val loop = newLoop(disclosed, listOf(tail))

        // 披露前：不可调用
        assertEquals(listOf("write_file"), loop.activeTools().map { it.spec.name })

        val registry = ToolRegistry(
            resident = listOf(residentSpec),
            longTail = listOf(signSpec),
            groups = mapOf("apk_sign" to ToolGroup.APK),
        )
        val result = SearchToolsTool(registry, disclosed).execute(mapOf("query" to "签名"))

        assertTrue(result is ToolOutcome.Success, "「签名」应当搜得到 apk_sign，实际：$result")
        assertTrue("apk_sign" in disclosed, "披露集必须被写入（它与 AgentLoop 共享同一实例）")
        assertEquals(
            listOf("write_file", "apk_sign"),
            loop.activeTools().map { it.spec.name },
            "披露后必须立刻可调用，否则模型会反复重试同一个工具",
        )
        // 派发点用的就是这个表达式（AgentLoop 里 `activeTools().first { … }`）
        assertEquals(tail, loop.activeTools().first { it.spec.name == "apk_sign" })
    }

    @Test
    @DisplayName("★★ 门禁 G13：披露前后冻结区**逐字节不变**（否则缓存全塌）")
    fun disclosureNeverTouchesFrozenPrefix() {
        val disclosed = mutableSetOf<String>()
        val loop = newLoop(disclosed, listOf(SpyTool(signSpec)))

        val before = loop.frozenPrefix
        assertFalse(before.text.contains("apk_sign"), "长尾 schema 泄漏进冻结区！")

        disclosed.add("apk_sign") // 模拟 search_tools 披露
        assertEquals(before, loop.frozenPrefix, "披露不得改动冻结区")
        // hash 是缓存漂移的判据（契约 §1.2）—— 它变了就等于缓存全失效
        assertEquals(before.hash, loop.frozenPrefix.hash, "冻结区 hash 变了 ⇒ 缓存全塌")
        assertFalse(loop.frozenPrefix.text.contains("apk_sign"))
    }
}
