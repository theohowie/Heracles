package dev.heracles.agent.tools

import dev.heracles.agent.ToolOutcome
import dev.heracles.workspace.RealWorkspaceFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory

/**
 * `apply_patch` 的工具层测试 —— `26-编码层工具链与逆向引擎.md` §4.3。
 *
 * [dev.heracles.core.patch.UnifiedPatch] 的算法已在 `:core` 穷举测试过，
 * 这里只测**工具层**的三件事：
 *
 * 1. 读写真的落到工作区（而不是只在内存里演一遍）
 * 2. 失败时**文件未被改动**（原子性在工具层依然成立）
 * 3. 路径越界被拦（工具层不能绕过 `PathGuard`）
 */
class PatchToolsTest {

    private val root: Path = createTempDirectory("patch-tool-test")
    private val fs = RealWorkspaceFs.open(root)
    private val tool = ApplyPatchTool(fs)

    private fun seed(rel: String, text: String) {
        val p = root.resolve(rel)
        p.parent?.let { Files.createDirectories(it) }
        Files.writeString(p, text)
    }

    private fun read(rel: String): String = Files.readString(root.resolve(rel))

    @Test
    @DisplayName("★ 改一行：只有那一行变，其他原样")
    fun patchesSingleLine() = runBlocking {
        seed(
            "smali/App.smali",
            """
            .class public LApp;
            .method f()V
                const/4 v0, 0x1
                return-void
            .end method
            """.trimIndent() + "\n",
        )

        val r = tool.execute(
            mapOf(
                "path" to "smali/App.smali",
                "patch" to "@@ -3,1 +3,1 @@\n-    const/4 v0, 0x1\n+    const/4 v0, 0x0\n",
            )
        )

        assertTrue(r is ToolOutcome.Success, "应当成功，实际：$r")
        val text = read("smali/App.smali")
        assertTrue(text.contains("const/4 v0, 0x0"), "改动应生效")
        assertTrue(text.contains(".class public LApp;"), "其余行必须原样保留")
        assertTrue(text.contains("return-void"), "其余行必须原样保留")

        // ★ 2026-10-19：回执必须给**真实 diff**（不是"N 个修改块 / M 行"）
        val detail = (r as ToolOutcome.Success).detail
        assertTrue(detail.contains("@@"), "回执要有 diff 头，用户/模型才能核对：$detail")
        assertTrue(detail.contains("-     const/4 v0, 0x1"), "被删的行要出现：$detail")
        assertTrue(detail.contains("+     const/4 v0, 0x0"), "新增的行要出现：$detail")
    }

    @Test
    @DisplayName("★ 补丁匹配不上 → 失败，且文件**一个字节都没变**")
    fun failedPatchLeavesFileUntouched() = runBlocking {
        val before = "a\nb\nc\n"
        seed("f.txt", before)

        val r = tool.execute(
            mapOf(
                "path" to "f.txt",
                "patch" to "@@ -1,1 +1,1 @@\n-完全不存在的一行\n+X\n",
            )
        )

        assertTrue(r is ToolOutcome.Failure, "应当失败，实际：$r")
        assertEquals(before, read("f.txt"), "失败的补丁绝不能改动文件")
    }

    @Test
    @DisplayName("文件不存在 → 明确失败（不创建空文件）")
    fun missingFileFails() = runBlocking {
        val r = tool.execute(mapOf("path" to "nope.txt", "patch" to "@@ -1,1 +1,1 @@\n-a\n+b\n"))
        assertTrue(r is ToolOutcome.Failure, "应当失败，实际：$r")
        assertTrue(!Files.exists(root.resolve("nope.txt")), "不得凭空创建文件")
    }

    @Test
    @DisplayName("path 为空 → 失败")
    fun blankPathFails() = runBlocking {
        val r = tool.execute(mapOf("path" to "  ", "patch" to "@@ -1,1 +1,1 @@\n-a\n+b\n"))
        assertTrue(r is ToolOutcome.Failure)
    }

    @Test
    @DisplayName("★ 路径越界被拦（工具层不能绕过 PathGuard）")
    fun pathEscapeIsBlocked() = runBlocking {
        val r = tool.execute(
            mapOf("path" to "../outside.txt", "patch" to "@@ -1,1 +1,1 @@\n-a\n+b\n")
        )
        assertTrue(r is ToolOutcome.Failure, "越界必须失败，实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("路径被拒绝"), "原因要说清是路径问题")
    }

    @Test
    @DisplayName("补丁没改动任何内容 → 如实说明，不谎报'已修改'")
    fun noOpPatchIsReportedHonestly() = runBlocking {
        seed("f.txt", "same\n")
        val r = tool.execute(
            mapOf("path" to "f.txt", "patch" to "@@ -1,1 +1,1 @@\n-same\n+same\n")
        )
        assertTrue(r is ToolOutcome.Success)
        assertTrue(
            (r as ToolOutcome.Success).detail.contains("未发生变化"),
            "无实质改动必须说清楚，实际：${r.detail}",
        )
    }
}
