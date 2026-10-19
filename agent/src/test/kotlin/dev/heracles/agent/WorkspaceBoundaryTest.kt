package dev.heracles.agent

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **工作区边界判定** —— 2026-10-19。
 *
 * ## 为什么这组断言必须有
 *
 * 设置里 `workspaceAuto` 写着「工作区内的改动自动执行，**越界仍会询问**」。
 * 在此之前"越界"**没有任何判定** —— 那句话只是文案。
 * 越界是**安全边界**：判宽了会放行不该放行的写操作，判窄了会把正常的相对路径也拦下来
 * （用户会被无意义的弹窗淹没，然后条件反射点「允许」）。
 */
class WorkspaceBoundaryTest {

    @Test
    @DisplayName("★ 工作区内的相对路径不算越界")
    fun relativePathsAreInside() {
        listOf("a.txt", "src/main/App.kt", "a/b/c.txt", "./a.txt", "a//b.txt", "a/./b.txt")
            .forEach {
                assertFalse(WorkspaceBoundary.isOutOfWorkspace(it), "「$it」应当算工作区内")
            }
    }

    @Test
    @DisplayName("★ 能真正消除的 .. 不算越界（a/../b.txt 在工作区内）")
    fun resolvableDotDotIsInside() {
        assertFalse(WorkspaceBoundary.isOutOfWorkspace("a/../b.txt"))
        assertFalse(WorkspaceBoundary.isOutOfWorkspace("a/b/../../c.txt"))
    }

    @Test
    @DisplayName("★★ 逃出根目录的 .. 算越界")
    fun escapingDotDotIsOutside() {
        listOf("../a.txt", "../../etc/passwd", "a/../../b.txt", "..\\..\\win.ini").forEach {
            assertTrue(WorkspaceBoundary.isOutOfWorkspace(it), "「$it」应当算越界")
        }
    }

    @Test
    @DisplayName("★★ 绝对路径 / 盘符 / 协议一律算越界")
    fun absoluteAndSchemesAreOutside() {
        listOf(
            "/sdcard/test/test/a.txt",
            "/etc/passwd",
            "C:/Windows/win.ini",
            "D:\\x.txt",
            "content://com.android.externalstorage.documents/tree/primary",
            "file:///etc/passwd",
        ).forEach {
            assertTrue(WorkspaceBoundary.isOutOfWorkspace(it), "「$it」应当算越界")
        }
    }

    @Test
    @DisplayName("★ 只看路径类参数，别的参数不误报")
    fun onlyPathArgsAreChecked() {
        val hits = WorkspaceBoundary.outOfWorkspaceArgs(
            mapOf(
                "path" to "../outside.txt",
                "content" to "内容里有个 / 斜杠",
                "command" to "rm -rf /",
            ),
        )
        assertTrue(hits.size == 1 && hits[0].startsWith("path="), "只该报 path：$hits")
    }

    @Test
    @DisplayName("★ 正常的工作区内调用 ⇒ 零命中（不打扰用户）")
    fun insideArgsProduceNoHits() {
        val hits = WorkspaceBoundary.outOfWorkspaceArgs(
            mapOf("path" to "src/App.kt", "content" to "hello", "dest" to "build/out.txt"),
        )
        assertTrue(hits.isEmpty(), "工作区内的写不该弹窗：$hits")
    }

    @Test
    @DisplayName("★ 空值 / 缺失参数不误报")
    fun emptyArgsAreIgnored() {
        assertTrue(WorkspaceBoundary.outOfWorkspaceArgs(emptyMap()).isEmpty())
        assertTrue(
            WorkspaceBoundary.outOfWorkspaceArgs(mapOf("path" to "  ", "dir" to "")).isEmpty(),
        )
    }
}
