package dev.heracles.agent.tools

import dev.heracles.agent.ToolOutcome
import dev.heracles.workspace.RealWorkspaceFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files

/**
 * `edit`（old_string → new_string）的门禁 —— 2026-10-19。
 *
 * ## 为什么"多处出现必须失败"是核心断言
 *
 * 模型改代码时最常见的错误不是"没找到"，而是**改错了地方**。`edit` 的
 * "必须恰好一次"规则就是把这种错**变成可见的失败**：模型会收到"出现了 2 次"，
 * 然后补上下文重试，而不是悄悄改第一处、任务表面成功。
 */
class EditFileTest {

    private fun fs(): RealWorkspaceFs =
        RealWorkspaceFs.open(Files.createTempDirectory("heracles-edit-test"))

    private fun edit(fs: RealWorkspaceFs, vararg args: Pair<String, String>): ToolOutcome =
        runBlocking { EditFileTool(fs).execute(args.toMap()) }

    @Test
    @DisplayName("★★ 唯一命中 ⇒ 真替换，文件内容正确")
    fun uniqueMatchReplaces() {
        val fs = fs()
        runBlocking { fs.writeText("Main.kt", "val a = 1\nval b = 2\n") }
        val out = edit(fs, "path" to "Main.kt", "old_string" to "val b = 2", "new_string" to "val b = 42")

        assertTrue(out is ToolOutcome.Success, "应当成功：$out")
        val text = runBlocking { fs.readText("Main.kt") }
        assertEquals("val a = 1\nval b = 42\n", text)
        assertTrue(
            (out as ToolOutcome.Success).detail.contains("替换 1 处"),
            "回执要如实说替换了几处：${out.detail}",
        )
    }

    @Test
    @DisplayName("★★ 多处命中且未开 replace_all ⇒ 明确失败，文件一个字节都不改")
    fun ambiguousMatchFailsWithoutWriting() {
        val fs = fs()
        val original = "log(1)\nlog(2)\n"
        runBlocking { fs.writeText("a.txt", original) }
        val out = edit(fs, "path" to "a.txt", "old_string" to "log(", "new_string" to "print(")

        assertTrue(out is ToolOutcome.Failure, "歧义时必须失败：$out")
        assertTrue(
            (out as ToolOutcome.Failure).reason.contains("出现了 2 次"),
            "要说清出现次数：${out.reason}",
        )
        assertEquals(original, runBlocking { fs.readText("a.txt") }, "失败时文件必须原封不动")
    }

    @Test
    @DisplayName("★ replace_all=true ⇒ 批量替换全部命中")
    fun replaceAllWorks() {
        val fs = fs()
        runBlocking { fs.writeText("a.txt", "log(1)\nlog(2)\n") }
        val out = edit(
            fs, "path" to "a.txt", "old_string" to "log(",
            "new_string" to "print(", "replace_all" to "true",
        )
        assertTrue(out is ToolOutcome.Success, "应当成功：$out")
        assertEquals("print(1)\nprint(2)\n", runBlocking { fs.readText("a.txt") })
    }

    @Test
    @DisplayName("★ 找不到 ⇒ 明确失败（提示先 read_file，而不是猜）")
    fun notFoundFails() {
        val fs = fs()
        runBlocking { fs.writeText("a.txt", "hello\n") }
        val out = edit(fs, "path" to "a.txt", "old_string" to "world", "new_string" to "x")
        assertTrue(out is ToolOutcome.Failure)
        assertTrue((out as ToolOutcome.Failure).reason.contains("没有找到"))
    }

    @Test
    @DisplayName("★ old_string 为空 / path 为空 ⇒ 明确失败")
    fun emptyArgsFail() {
        val fs = fs()
        runBlocking { fs.writeText("a.txt", "hello\n") }
        assertTrue(edit(fs, "path" to "a.txt", "old_string" to "") is ToolOutcome.Failure)
        assertTrue(edit(fs, "path" to "", "old_string" to "hello") is ToolOutcome.Failure)
    }

    @Test
    @DisplayName("★ new_string 与 old_string 相同 ⇒ 如实说「内容未变化」，不刷成功卡")
    fun noChangeReported() {
        val fs = fs()
        runBlocking { fs.writeText("a.txt", "same\n") }
        val out = edit(fs, "path" to "a.txt", "old_string" to "same", "new_string" to "same")
        assertTrue(out is ToolOutcome.Success)
        assertTrue((out as ToolOutcome.Success).detail.contains("未变化"))
    }
}
