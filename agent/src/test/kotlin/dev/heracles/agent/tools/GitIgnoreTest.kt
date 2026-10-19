package dev.heracles.agent.tools

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * `.gitignore` 最小解析器的行为门禁（2026-10-19）。
 *
 * 它决定 `find_files` / `grep_files` **跳过哪些文件**，所以每条规则都要有断言：
 * 少跳过 = 白烧 token、把构建产物当源码；多跳过 = **模型看不见真实文件**（更糟）。
 */
class GitIgnoreTest {

    private fun ignore(text: String) = GitIgnore.parse(text)

    @Test
    @DisplayName("不含 / 的规则按文件名匹配，任意深度")
    fun basenameRuleMatchesAtAnyDepth() {
        val g = ignore("*.log\n")
        assertTrue(g.isIgnored("a.log", isDirectory = false))
        assertTrue(g.isIgnored("x/y/a.log", isDirectory = false))
        assertFalse(g.isIgnored("a.txt", isDirectory = false))
    }

    @Test
    @DisplayName("目录规则（尾 /）只匹配目录，不误伤同名文件")
    fun dirRuleMatchesOnlyDirectories() {
        val g = ignore("build/\n")
        assertTrue(g.isIgnored("build", isDirectory = true))
        assertTrue(g.isIgnored("app/build", isDirectory = true))
        assertFalse(g.isIgnored("build", isDirectory = false), "文件叫 build 不该被忽略")
    }

    @Test
    @DisplayName("前导 / 锚定工作区根：/dist 不匹配 sub/dist")
    fun leadingSlashAnchorsToRoot() {
        val g = ignore("/dist\n")
        assertTrue(g.isIgnored("dist", isDirectory = true))
        assertFalse(g.isIgnored("sub/dist", isDirectory = true))
    }

    @Test
    @DisplayName("含 / 的规则按路径匹配：src/gen 不匹配 other/src/gen")
    fun slashRuleMatchesPathFromRoot() {
        val g = ignore("src/gen\n")
        assertTrue(g.isIgnored("src/gen", isDirectory = true))
        assertFalse(g.isIgnored("other/src/gen", isDirectory = true))
    }

    @Test
    @DisplayName("反选 ! 生效，且后出现的规则覆盖先出现的（与 git 一致）")
    fun negationWinsWhenLast() {
        val g = ignore("*.log\n!keep.log\n")
        assertTrue(g.isIgnored("a.log", isDirectory = false))
        assertFalse(g.isIgnored("keep.log", isDirectory = false), "被 ! 反选的文件必须能看到")
    }

    @Test
    @DisplayName("** 匹配任意层目录")
    fun doubleStarMatchesAnyDepth() {
        val g = ignore("**/generated/**\n")
        assertTrue(g.isIgnored("a/generated/x.txt", isDirectory = false))
        assertTrue(g.isIgnored("a/generated/b/x.txt", isDirectory = false))
    }

    @Test
    @DisplayName("注释与空行解析为空规则（行为 = 加本功能之前）")
    fun commentsAndBlankLinesOnlyYieldEmpty() {
        assertTrue(ignore("# comment\n\n   \n").isEmpty())
        assertTrue(GitIgnore.EMPTY.isEmpty())
    }

    @Test
    @DisplayName("畸形规则不抛异常（忽略功能不能把搜索弄崩）")
    fun malformedRulesDoNotThrow() {
        val g = ignore("!\n/\n!\n")
        assertFalse(g.isIgnored("a", isDirectory = false))
    }
}
