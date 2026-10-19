package dev.heracles.agent.tools

import dev.heracles.agent.ToolOutcome
import dev.heracles.workspace.RealWorkspaceFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory

/**
 * 文件工具层的行为门禁 —— P1-4（`read_file` 分段读取）。
 *
 * ## 为什么这几条断言必须存在（而不是"顺便测个偏移量"）
 *
 * 1. **零回退**：`read_file` 是常驻工具、模型每一轮都在用。加了参数之后，"不传参数"
 *    那条路必须与加参数之前**逐字节一致** —— 否则上下文/前缀行为悄悄变了没人知道。
 * 2. **截断必须如实**：静默截断比"读不完"更糟 —— 模型会把"我看到的就是全部"当真，
 *    然后基于残缺内容下结论（与 `04-抗幻觉设计.md` 里"谎称完成"同源）。
 *    所以表头里的"第几行/共几行/还有多少行/用哪个 offset 继续"必须**能被程序接续**。
 * 3. **非法参数是 `Failure` 不是异常**：抛异常会打断整个 agent 循环。
 * 4. **不许绕开 `WorkspaceFs`**：> 1 MB 照旧硬失败、越界路径照旧被 `PathGuard` 拒 ——
 *    分段读**不是**"读大文件/绕沙箱"的后门。
 */
class FileToolsTest {

    private val root: Path = createTempDirectory("file-tools")
    private val fs = RealWorkspaceFs.open(root)

    private fun write(rel: String, text: String) {
        val p = root.resolve(rel)
        p.parent?.let { Files.createDirectories(it) }
        Files.writeString(p, text)
    }

    /** 磁盘上的原始字节 —— 判"逐字节一致"时用它，不自证于被测实现。 */
    private fun raw(rel: String): String =
        String(Files.readAllBytes(root.resolve(rel)), StandardCharsets.UTF_8)

    private fun read(vararg args: Pair<String, String>): ToolOutcome = runBlocking {
        ReadFileTool(fs).execute(args.toMap())
    }

    private fun ok(out: ToolOutcome): String {
        assertTrue(out is ToolOutcome.Success, "应当成功，实际：$out")
        return (out as ToolOutcome.Success).detail
    }

    private fun fail(out: ToolOutcome): String {
        assertTrue(out is ToolOutcome.Failure, "应当是 Failure（不许抛异常、更不许假装成功）：$out")
        return (out as ToolOutcome.Failure).reason
    }

    /**
     * 分段返回的**第一行是表头**（`已读第 X–Y 行 …`）—— 剥掉它就是纯文件内容。
     * 模型与测试都靠这个约定接续读（表头里不含换行，所以按首个 `\n` 切是明确的）。
     */
    private fun body(out: String): String =
        if (out.startsWith("已读第 ")) out.substringAfter("\n") else out

    /** 表头里"用 offset=N 继续"的 N；读到末尾的表头没有它。 */
    private fun nextOffset(header: String): Int? =
        Regex("offset=(\\d+)").find(header)?.groupValues?.get(1)?.toInt()

    // ---------------------------------------------------------------- ① 零回退

    @Test
    @DisplayName("★ 不传 offset/limit ⇒ 与旧行为逐字节一致（含 CRLF / 中文 / 末尾换行 / 空文件）")
    fun noPagingIsByteIdenticalToOldBehavior() {
        val cases = linkedMapOf(
            "plain.txt" to "hello\nworld\n",
            "crlf.txt" to "a\r\nb\r\n",
            "cn.txt" to "第一行\n第二行\n\n",
            "noeol.txt" to "no trailing newline",
            "empty.txt" to "",
        )
        cases.forEach { (name, text) -> write(name, text) }

        cases.forEach { (name, text) ->
            // ① 键缺失（旧调用形态）② 显式空串 —— 两条都必须与磁盘原文逐字节相同
            assertEquals(text, ok(read("path" to name)), "键缺失时行为变了：$name")
            assertEquals(
                text,
                ok(read("path" to name, "offset" to "", "limit" to "")),
                "传空串时行为变了：$name",
            )
            assertEquals(raw(name), ok(read("path" to name)), "结果与磁盘字节不一致：$name")
        }
    }

    @Test
    @DisplayName("★ 显式要求覆盖全文（offset=1 + limit 够大）≈ 整读：逐字节一致且不给表头")
    fun fullCoverageRequestEqualsWholeRead() {
        write("cn.txt", "第一行\n第二行\n第三行\n")
        val whole = ok(read("path" to "cn.txt"))
        val sliced = ok(read("path" to "cn.txt", "offset" to "1", "limit" to "9999"))
        assertEquals(whole, sliced)
        assertEquals(raw("cn.txt"), sliced)
        assertFalse(sliced.startsWith("已读第 "), "覆盖全文不该加表头（模型不必剥壳）：$sliced")
    }

    // ---------------------------------------------------------------- ② 切片正确

    @Test
    @DisplayName("切片：行边界 / 末尾不足 limit / 只给 offset / 只给 limit / CRLF 原样保留")
    fun pagingSlicesOnLineBoundaries() {
        write("six.txt", "l1\nl2\nl3\nl4\nl5\nl6\n")

        assertEquals(
            "已读第 3–4 行 / 共 6 行；还有 2 行未读，用 offset=5 继续\nl3\nl4\n",
            ok(read("path" to "six.txt", "offset" to "3", "limit" to "2")),
        )
        // 末尾不足 limit：不许报"还有负数行未读"，要明说读到末尾
        assertEquals(
            "已读第 5–6 行 / 共 6 行；已读到文件末尾\nl5\nl6\n",
            ok(read("path" to "six.txt", "offset" to "5", "limit" to "10")),
        )
        // 只给 offset：读到文件末尾
        assertEquals(
            "已读第 4–6 行 / 共 6 行；已读到文件末尾\nl4\nl5\nl6\n",
            ok(read("path" to "six.txt", "offset" to "4")),
        )
        // 只给 limit：offset 缺省 = 1
        assertEquals(
            "已读第 1–2 行 / 共 6 行；还有 4 行未读，用 offset=3 继续\nl1\nl2\n",
            ok(read("path" to "six.txt", "limit" to "2")),
        )

        // CRLF 必须原样保留（不许把 \r 悄悄吃掉、把文件改了个样交出去）
        write("crlf.txt", "a\r\nb\r\nc\r\n")
        val one = ok(read("path" to "crlf.txt", "offset" to "2", "limit" to "1"))
        assertEquals("b\r\n", body(one), "切片必须保留 \\r\\n")
    }

    // ---------------------------------------------------------------- ③ 截断如实 + 可接续

    @Test
    @DisplayName("★ 截断如实告知，且表头能被程序用来接续读完（逐轮拼接 == 原文）")
    fun truncationNoticeAllowsContinuation() {
        val lines = (1..10).map { "line$it" }
        val cases = linkedMapOf(
            "with_eol.txt" to lines.joinToString("\n") + "\n",
            "no_eol.txt" to lines.joinToString("\n"),
        )
        cases.forEach { (name, text) -> write(name, text) }

        cases.forEach { (name, text) ->
            val collected = StringBuilder()
            var offset = 1
            var rounds = 0
            while (true) {
                rounds++
                assertTrue(rounds <= 10, "$name 接续不收敛（表头里的 offset 提示算错了？）")

                val out = ok(read("path" to name, "offset" to offset.toString(), "limit" to "3"))
                val header = out.substringBefore("\n")
                assertTrue(header.startsWith("已读第 "), "$name 分段返回必须有表头：$header")
                assertTrue(header.contains("共 10 行"), "$name 必须报总行数：$header")
                collected.append(body(out))

                val next = nextOffset(header)
                if (next == null) {
                    assertTrue(header.contains("已读到文件末尾"), "$name 最后一轮必须明说读到末尾：$header")
                    break
                }
                assertEquals(offset + 3, next, "$name 继续用的 offset 必须紧接着上一轮：$header")
                // 未读行数必须是真的（不是写死的"还有若干行"）
                assertTrue(
                    header.contains("还有 ${10 - (offset + 2)} 行未读"),
                    "$name 必须如实报未读行数：$header",
                )
                offset = next
            }
            assertEquals(4, rounds, "$name 应当 4 轮读完（10 行 / 每轮 3 行）")
            assertEquals(text, collected.toString(), "$name 逐轮拼接必须与原文逐字节一致")
        }
    }

    // ---------------------------------------------------------------- ④ 非法参数

    @Test
    @DisplayName("非法参数 → Failure（不是异常、不是空成功），reason 点名参数并带上收到的值")
    fun invalidParamsFailWithReadableReason() {
        write("f.txt", "a\nb\nc\n")

        listOf(
            Triple("offset", "0", "offset"),
            Triple("offset", "-3", "offset"),
            Triple("offset", "abc", "offset"),
            Triple("offset", "1.5", "offset"),
            Triple("limit", "0", "limit"),
            Triple("limit", "-1", "limit"),
            Triple("limit", "x", "limit"),
        ).forEach { (key, value, mustName) ->
            val reason = fail(read("path" to "f.txt", key to value))
            assertTrue(reason.contains(mustName), "reason 要点名是哪个参数：$reason")
            assertTrue(reason.contains(value), "reason 要带上收到的值：$reason")
            assertTrue(reason.length > 8, "reason 要可读，不是空壳：$reason")
        }

        // offset 超出文件行数（含 offset = 行数 + 1）
        assertTrue(fail(read("path" to "f.txt", "offset" to "4")).contains("超出文件行数"))
        assertTrue(
            fail(read("path" to "f.txt", "offset" to "99", "limit" to "1")).contains("超出文件行数"),
        )

        // 分段读**不许**成为绕开 fs 的后门：路径不存在 / 越界仍照旧失败
        assertTrue(
            fail(read("path" to "nope.txt", "offset" to "1", "limit" to "1")).contains("读取失败"),
        )
        assertTrue(
            fail(read("path" to "../escape.txt", "offset" to "1", "limit" to "1"))
                .contains("路径被拒绝"),
        )

        // path 本身为空时，分段参数也救不了
        assertTrue(fail(read("path" to " ", "offset" to "1")).contains("path"))
    }

    @Test
    @DisplayName("★ 分段读不绕开 WorkspaceFs 的 1 MB 上限：超限照旧硬失败")
    fun pagingDoesNotBypassSizeLimit() {
        write("big.txt", "x".repeat(1_000_001))
        val reason = fail(read("path" to "big.txt", "offset" to "1", "limit" to "10"))
        assertTrue(reason.contains("文件过大"), "超限文件必须照旧拒绝（分段不是读大文件的后门）：$reason")
    }

    // ---------------------------------------------------------------- ⑤ 边界

    @Test
    @DisplayName("边界：空文件 / 单行（有换行、无换行）/ 只有一个换行")
    fun emptyAndSingleLineBoundaries() {
        write("empty.txt", "")
        // 整读维持旧行为（空成功；旧行为就是返回 ""）
        assertEquals("", ok(read("path" to "empty.txt")))
        // 显式分段：如实说"0 行"，而不是返回空成功让人以为读到了内容
        val emptyReason = fail(read("path" to "empty.txt", "offset" to "1", "limit" to "5"))
        assertTrue(emptyReason.contains("空文件"), "reason 要如实说明：$emptyReason")
        assertTrue(emptyReason.contains("0 行"), "reason 要给出真实行数：$emptyReason")
        assertTrue(fail(read("path" to "empty.txt", "limit" to "5")).contains("空文件"))

        write("one.txt", "only\n")
        assertEquals("only\n", ok(read("path" to "one.txt", "offset" to "1", "limit" to "1")))
        assertEquals("only\n", ok(read("path" to "one.txt", "offset" to "1")))
        assertTrue(fail(read("path" to "one.txt", "offset" to "2")).contains("超出文件行数"))

        write("one_noeol.txt", "only")
        assertEquals("only", ok(read("path" to "one_noeol.txt", "offset" to "1", "limit" to "5")))
        assertTrue(fail(read("path" to "one_noeol.txt", "offset" to "2")).contains("超出文件行数"))

        // 只有一个换行的文件 = 1 个空行（`cat -n` 的直觉），不是 2 行
        write("nl.txt", "\n")
        assertEquals("\n", ok(read("path" to "nl.txt", "offset" to "1", "limit" to "1")))
        assertTrue(fail(read("path" to "nl.txt", "offset" to "2")).contains("超出文件行数"))
    }

    // ---------------------------------------------------------------- ⑥ 工具面与描述

    @Test
    @DisplayName("★ 工具面钉住：参数名 / 可空声明 / 描述必须告诉模型\"第一行是表头\"")
    fun specSurfaceAndDescriptionArePinned() {
        val spec = ReadFileTool(fs).spec
        assertEquals("read_file", spec.name)
        // 参数名列表就是模型看到的 schema（也是前缀缓存的一部分）：改名/改序要**故意**
        assertEquals(listOf("path", "offset", "limit", "numbered"), spec.parameters.map { it.name })

        // ★ 两条独立的"可以不填"通道，都要钉住（2026-10-18 F7a 之后校验器语义变了）：
        //   · optional = true   ⇒ **缺键**放行（云端原生 function calling 会少发可选字段）
        //   · allowEmpty = true ⇒ 传**空串**放行（本地/方言路径的既有契约，空串 = 整读）
        //   去掉任何一条，模型都会在对应那条路上被校验器拦下。
        val offset = spec.parameters.first { it.name == "offset" }
        val limit = spec.parameters.first { it.name == "limit" }
        val numbered = spec.parameters.first { it.name == "numbered" }
        val path = spec.parameters.first { it.name == "path" }
        assertTrue(offset.optional && limit.optional, "offset/limit 必须 optional（缺键 = 整读）")
        assertTrue(offset.allowEmpty && limit.allowEmpty, "offset/limit 也必须允许空串（空串 = 整读）")
        assertTrue(numbered.optional && numbered.allowEmpty, "numbered 必须可选（缺键 = 不带行号）")
        assertFalse(path.optional, "path 必须必填")
        assertFalse(path.allowEmpty, "path 不许为空")

        val d = spec.description
        assertTrue(d.contains("offset") && d.contains("limit"), "描述没告诉模型有这个能力：$d")
        assertTrue(d.contains("numbered"), "描述必须广告行号能力，否则模型永远想不起来用：$d")
        assertTrue(
            d.contains("第一行"),
            "必须说清分段返回的第一行是行号说明，否则模型会把它当成文件内容：$d",
        )
        assertTrue(
            d.contains("空字符串"),
            "必须说清整读怎么写（校验器要求键必填、值可空）：$d",
        )
    }

    // ------------------------------------------------ 写操作回执（2026-10-19）

    private fun writeTool(vararg args: Pair<String, String>): ToolOutcome = runBlocking {
        WriteFileTool(fs).execute(args.toMap())
    }

    @Test
    @DisplayName("★ 新建文件回执：说清是新建 + 给内容预览")
    fun writeNewFileReceiptShowsCreation() {
        val out = ok(writeTool("path" to "new.txt", "content" to "第一行\n第二行\n"))
        assertTrue(out.contains("新建文件"), "回执要说清是新建：$out")
        assertTrue(out.contains("+ 第一行"), "回执要给 diff 预览：$out")
    }

    @Test
    @DisplayName("★★ 覆盖已有文件回执：给**真实 diff**（不是只报写了多少字节）")
    fun writeExistingFileReceiptShowsDiff() {
        write("f.txt", "old\nkeep\n")
        val out = ok(writeTool("path" to "f.txt", "content" to "old\nnew\nkeep\n"))
        assertTrue(out.contains("@@"), "回执必须有 diff 头：$out")
        assertTrue(out.contains("+ new"), "新增行要出现：$out")
        assertFalse(out.contains("+ old"), "未变化的行不该被当成新增：$out")
    }

    @Test
    @DisplayName("★ 内容完全一样 ⇒ 如实说「未变化」（不谎报改动）")
    fun writeUnchangedReceiptIsHonest() {
        write("same.txt", "same\n")
        val out = ok(writeTool("path" to "same.txt", "content" to "same\n"))
        assertTrue(out.contains("未变化"), "没改就直说：$out")
    }

    @Test
    @DisplayName("★★ 覆盖写前保存快照 ⇒ restore_path 能恢复原文（改错了能退回来）")
    fun overwriteCanBeRestored() {
        write("r.txt", "旧内容\n")
        val out = ok(writeTool("path" to "r.txt", "content" to "新内容\n"))
        assertTrue(out.contains("restore_path"), "回执要告诉模型可撤销：$out")

        val restore = runBlocking { RestorePathTool(fs).execute(mapOf("path" to "r.txt")) }
        assertTrue(restore is ToolOutcome.Success, "实际：$restore")
        assertEquals("旧内容\n", raw("r.txt"), "恢复的必须是覆盖前的原文")
    }

    // ------------------------------------------------ 读取行号（2026-10-19）

    @Test
    @DisplayName("★ numbered=true ⇒ cat -n 风格行号；默认仍是逐字节一致（零回退）")
    fun numberedReadAddsLineNumbers() {
        write("n.txt", "alpha\nbeta\ngamma\n")
        val out = ok(read("path" to "n.txt", "numbered" to "true"))
        assertTrue(out.contains("     1\talpha"), "行号从 1 起、等宽对齐：$out")
        assertTrue(out.contains("     3\tgamma"), "第三行编号正确：$out")
        // 默认（不传 numbered）必须与旧行为逐字节一致 —— 这是零回退锚点
        assertEquals("alpha\nbeta\ngamma\n", ok(read("path" to "n.txt")))
    }

    @Test
    @DisplayName("★ 分段 + numbered ⇒ 行号从 offset 起（不是从 1）")
    fun numberedPagedStartsAtOffset() {
        write("n.txt", "l1\nl2\nl3\nl4\nl5\n")
        val out = ok(
            read("path" to "n.txt", "offset" to "3", "limit" to "2", "numbered" to "true"),
        )
        assertTrue(out.contains("     3\tl3"), "行号必须从 3 起：$out")
        assertTrue(out.contains("     4\tl4"), "第二行是 4：$out")
        assertFalse(out.contains("     1\t"), "不许从头编号：$out")
        assertTrue(out.startsWith("已读第 3–4 行"), "分段表头仍要保留：$out")
    }
}
