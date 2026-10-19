package dev.heracles.core.patch

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * `UnifiedPatch` 的行为门禁 —— `26-编码层工具链与逆向引擎.md` §4.3。
 *
 * ## 为什么围绕"失败"写的用例比"成功"还多
 *
 * 改 smali / XML 的价值全在**正确性**上：一个"改了一半"的 smali 会编译出
 * **行为诡异**的 APK（能装、能起、逻辑悄悄变了），比"什么都没改"难查得多。
 * 所以这里逐条钉死失败路径必须**整体失败**、绝不半写入。
 */
class UnifiedPatchTest {

    private fun apply(original: String, diff: String): ApplyResult =
        UnifiedPatch.applyDiff(original, diff)

    private fun okText(r: ApplyResult): String {
        assertTrue(r is ApplyResult.Ok, "应当成功，实际：$r")
        return (r as ApplyResult.Ok).text
    }

    private fun failedReason(r: ApplyResult): String {
        assertTrue(r is ApplyResult.Failed, "应当失败，实际：$r")
        return (r as ApplyResult.Failed).reason
    }

    // --------------------------------------------------------------- 基本

    @Test
    @DisplayName("单块修改：替换一行")
    fun replacesOneLine() {
        val original = "line1\nline2\nline3\n"
        val diff = """
            @@ -1,3 +1,3 @@
             line1
            -line2
            +LINE2
             line3
        """.trimIndent()

        assertEquals("line1\nLINE2\nline3\n", okText(apply(original, diff)))
    }

    @Test
    @DisplayName("纯新增块（oldCount = 0）")
    fun pureAddition() {
        val original = "p\nq\nr\n"
        val diff = """
            @@ -2,0 +3,1 @@
            +NEW
        """.trimIndent()

        assertEquals("p\nNEW\nq\nr\n", okText(apply(original, diff)))
    }

    @Test
    @DisplayName("★ 声明的行号写错，但上下文唯一 → 仍能定位（容忍模型数错行）")
    fun toleratesWrongLineNumber() {
        val original = "p\nq\nr\n"
        val diff = """
            @@ -9,1 +9,1 @@
            -p
            +P
        """.trimIndent()

        assertEquals("P\nq\nr\n", okText(apply(original, diff)))
    }

    // --------------------------------------------------------------- 失败路径

    @Test
    @DisplayName("★ 上下文不匹配 → 整体失败，且**不返回半成品**")
    fun contextMismatchFailsWholly() {
        val original = "a\nb\nc\n"
        val diff = """
            @@ -1,1 +1,1 @@
            -a
            +A
            @@ -9,1 +9,1 @@
            -zzz
            +ZZZ
        """.trimIndent()

        val r = apply(original, diff)
        assertTrue(r is ApplyResult.Failed, "第二块匹配不上就必须整体失败，实际：$r")
        assertTrue(failedReason(r).contains("上下文与文件不匹配"), "失败原因要能指导模型，实际：${failedReason(r)}")
    }

    @Test
    @DisplayName("★ 上下文出现多次 → 拒绝（不能猜改哪一处）")
    fun ambiguousContextIsRejected() {
        val original = "dup\nother\ndup\n"
        val diff = """
            @@ -9,1 +9,1 @@
            -dup
            +DUP
        """.trimIndent()

        val reason = failedReason(apply(original, diff))
        assertTrue(reason.contains("出现 2 次"), "必须说明歧义，实际：$reason")
        assertTrue(reason.contains("补足上下文"), "要给出可操作的下一步，实际：$reason")
    }

    @Test
    @DisplayName("★ 补丁以换行结尾（模型输出的真实形态）不能被当成多一个空上下文行")
    fun trailingNewlineIsNotAnExtraContextLine() {
        val original = "a\nb\n"
        // 注意：字符串**以 \n 结尾** —— 绝大多数模型/工具都是这个形态
        val diff = "@@ -2,1 +2,1 @@\n-b\n+B\n"
        assertEquals("a\nB\n", okText(apply(original, diff)))
    }

    @Test
    @DisplayName("补丁没有修改块 → 解析失败（不返回'成功但没改'）")
    fun noHunksIsRejected() {
        assertNull(UnifiedPatch.parse("这不是 diff"))
        val r = apply("a\n", "也不是 diff")
        assertTrue(r is ApplyResult.Failed)
    }

    @Test
    @DisplayName("修改块内出现认不出的行 → 解析失败（坏补丁宁可拒绝）")
    fun junkInsideHunkIsRejected() {
        assertNull(
            UnifiedPatch.parse(
                """
                @@ -1,1 +1,1 @@
                ????????
                """.trimIndent()
            )
        )
    }

    @Test
    @DisplayName("解析器能数清改了几行（供回报'改了几处'）")
    fun parsesChangeCount() {
        val p = UnifiedPatch.parse(
            """
            @@ -1,3 +1,3 @@
             ctx
            -old1
            +new1
            -old2
            +new2
            """.trimIndent()
        )
        assertNotNull(p)
        assertEquals(4, p!!.changeCount)
        assertEquals(1, p.hunks.size)
    }

    // --------------------------------------------------------------- 换行 / 空白

    @Test
    @DisplayName("★ CRLF 文件保持 CRLF（Android 资源与 smali 混用换行，写回不能改）")
    fun preservesCrlf() {
        val original = "a\r\nb\r\n"
        val diff = """
            @@ -1,1 +1,1 @@
            -a
            +A
        """.trimIndent()

        assertEquals("A\r\nb\r\n", okText(apply(original, diff)))
    }

    @Test
    @DisplayName("★ 末尾无换行的文件，应用后也不该凭空多出换行")
    fun preservesMissingTrailingNewline() {
        val original = "a\nb"
        val diff = """
            @@ -2,1 +2,1 @@
            -b
            +B
        """.trimIndent()

        assertEquals("a\nB", okText(apply(original, diff)))
    }

    @Test
    @DisplayName("★ 行尾空白差异：容错兜底，但**如实标记**（不让模型以为完全一致）")
    fun whitespaceTolerantMatchIsFlagged() {
        val original = "a   \nb\n" // 原文 a 后面有尾随空格
        val diff = """
            @@ -1,2 +1,2 @@
            -a
            +A
             b
        """.trimIndent()

        val r = apply(original, diff)
        assertTrue(r is ApplyResult.Ok, "应当容错匹配成功，实际：$r")
        val ok = r as ApplyResult.Ok
        assertEquals("A\nb\n", ok.text)
        assertTrue(ok.whitespaceTolerant, "容错匹配必须被标记出来")
    }

    @Test
    @DisplayName("多余元信息头（diff/index/---/+++）不影响解析")
    fun ignoresMetaHeaders() {
        val original = "x\ny\n"
        val diff = """
            diff --git a/f b/f
            index 1234567..89abcde 100644
            --- a/f
            +++ b/f
            @@ -1,1 +1,1 @@
            -x
            +X
        """.trimIndent()

        assertEquals("X\ny\n", okText(apply(original, diff)))
    }

    @Test
    @DisplayName("空上下文行（生成器省略前导空格）也算上下文")
    fun blankContextLineIsAccepted() {
        val original = "head\n\nbody\n"
        val diff = """
            @@ -1,3 +1,3 @@
             head

            -body
            +BODY
        """.trimIndent()

        assertEquals("head\n\nBODY\n", okText(apply(original, diff)))
    }

    @Test
    @DisplayName("★★ 空补丁（只有 @@ 块头、没有任何 +/- 行）必须失败 —— 不得当成功空转")
    fun emptyPatchMustFail() {
        // 2026-10-19 真机现场：模型对 mall.html 输出
        // `patch = "@@ -1,1 +1,1 @@\n"`。旧实现返回 Ok（文本没变），
        // 工具层再报"补丁已应用但内容未变"= 成功 ⇒ 计划被推进，任务空转。
        val original = "<html>\n<body>\n</body>\n</html>\n"
        val r = apply(original, "@@ -1,1 +1,1 @@\n")
        assertTrue(r is ApplyResult.Failed, "空补丁必须失败（不能伪装成成功），实际：$r")
        val reason = (r as ApplyResult.Failed).reason
        assertTrue(reason.contains("没有任何改动"), "失败原因要点明「空补丁」：$reason")

        // 只有上下文行的块同理：没有任何改动就是失败
        val contextOnly = apply(original, "@@ -1,1 +1,1 @@\n <html>\n")
        assertTrue(contextOnly is ApplyResult.Failed, "只含上下文行的块也必须失败：$contextOnly")
    }
}
