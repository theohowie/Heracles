package dev.heracles.agent.tools

import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.RealWorkspaceFs
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory

/**
 * 假 runner —— **必须记下调用参数**，否则"超时被收敛了没"这类断言无从下手。
 */
private class FakeShellRunner(
    private val result: ShellResult = ShellResult(0, "ok", "", false, 12L),
) : ShellRunner {
    val calls = mutableListOf<Triple<String, Int, String?>>()
    override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult {
        calls.add(Triple(command, timeoutSec, cwd))
        return result
    }
}

/**
 * `run_shell_command` 的工具层测试 —— `26-编码层工具链与逆向引擎.md` §4.1。
 *
 * ## 这一层测什么
 *
 * `CommandGuard` / `LogFilter` / `ThermalGuard` 都已在 `:core` 各自测过。
 * 这里测的是**它们的组合顺序**——也就是最容易被忽略、最容易写反的地方：
 *
 * · 拒绝要在**起进程之前**发生（不能"先跑再判"）
 * · 超时要在**交给 runner 之前**被收敛（不能把 99999 传下去）
 * · 非 0 退出码必须是 `Failure`（否则模型把失败当成功）
 */
class ShellToolsTest {

    private val root: Path = createTempDirectory("shell-tool-test")
    private val fs = RealWorkspaceFs.open(root)

    private fun tool(runner: ShellRunner, health: dev.heracles.core.guard.DeviceHealthSource? = null) =
        RunShellCommandTool(runner, fs, health)

    @Test
    @DisplayName("★ 被拒绝的命令**不会**触达 runner（判定必须在起进程之前）")
    fun deniedCommandNeverReachesRunner() = runBlocking {
        val runner = FakeShellRunner()
        val r = tool(runner).execute(mapOf("command" to "am force-stop com.foo"))

        assertTrue(r is ToolOutcome.Failure, "应当失败，实际：$r")
        assertTrue(runner.calls.isEmpty(), "★ 被拒绝的命令绝不能真的执行 —— 实际执行了：${runner.calls}")
    }

    @Test
    @DisplayName("★ 需确认的命令走 NeedsApproval（不是 Failure，蓝色而非红色）")
    fun needsApprovalIsDistinct() = runBlocking {
        val runner = FakeShellRunner()
        val r = tool(runner).execute(mapOf("command" to "rm -rf build"))
        assertTrue(r is ToolOutcome.NeedsApproval, "应当需确认，实际：$r")
        assertTrue(runner.calls.isEmpty(), "确认前不得执行")
    }

    @Test
    @DisplayName("★ 超时被收敛到上限（模型不能自己把超时设成 1 小时）")
    fun timeoutIsClamped() = runBlocking {
        val runner = FakeShellRunner()
        tool(runner).execute(mapOf("command" to "ls", "timeout_sec" to "99999"))
        assertEquals(
            dev.heracles.core.contract.Contract.Shell.MAX_TIMEOUT_SEC,
            runner.calls.single().second,
            "超时必须被收敛到 Contract 里的上限",
        )
    }

    @Test
    @DisplayName("超时默认值来自 Contract")
    fun timeoutDefaultsToContract() = runBlocking {
        val runner = FakeShellRunner()
        tool(runner).execute(mapOf("command" to "ls"))
        assertEquals(
            dev.heracles.core.contract.Contract.Shell.DEFAULT_TIMEOUT_SEC,
            runner.calls.single().second,
        )
    }

    @Test
    @DisplayName("cwd 越界 → 在起进程前失败")
    fun cwdEscapeIsBlocked() = runBlocking {
        val runner = FakeShellRunner()
        val r = tool(runner).execute(mapOf("command" to "ls", "cwd" to "../outside"))
        assertTrue(r is ToolOutcome.Failure, "应当失败，实际：$r")
        assertTrue(runner.calls.isEmpty())
    }

    // ---------- F7b：optional 参数（缺键 ⇒ 实现里的默认分支） ----------

    @Test
    @DisplayName("★ cwd 缺键 ⇒ 交给 runner 的是 null（= 工作区根），与传空串逐字等价")
    fun missingCwdEqualsBlankCwd() = runBlocking {
        val missing = FakeShellRunner()
        tool(missing).execute(mapOf("command" to "ls"))
        val blank = FakeShellRunner()
        tool(blank).execute(mapOf("command" to "ls", "cwd" to ""))

        assertNull(missing.calls.single().third, "缺键时必须是 null（由 runner 落到工作区根）")
        assertEquals(
            missing.calls.single().third, blank.calls.single().third,
            "缺键与传空串必须走同一条路",
        )
    }

    @Test
    @DisplayName("★ timeout_sec 缺键 ⇒ Contract 默认值，与传空串等价")
    fun missingTimeoutEqualsBlankTimeout() = runBlocking {
        val missing = FakeShellRunner()
        tool(missing).execute(mapOf("command" to "ls"))
        val blank = FakeShellRunner()
        tool(blank).execute(mapOf("command" to "ls", "timeout_sec" to ""))

        assertEquals(
            dev.heracles.core.contract.Contract.Shell.DEFAULT_TIMEOUT_SEC,
            missing.calls.single().second,
        )
        assertEquals(missing.calls.single().second, blank.calls.single().second)
    }

    @Test
    @DisplayName("工具面：cwd / timeout_sec 标了 optional，command 仍必填")
    fun optionalParamsArePinned() {
        val spec = tool(FakeShellRunner()).spec
        assertTrue(spec.parameters.first { it.name == "cwd" }.optional, "cwd 必须 optional")
        assertTrue(
            spec.parameters.first { it.name == "timeout_sec" }.optional,
            "timeout_sec 必须 optional",
        )
        assertFalse(spec.parameters.first { it.name == "command" }.optional, "command 必须必填")
    }

    @Test
    @DisplayName("★ 非 0 退出码必须是 Failure（成败不能靠猜）")
    fun nonZeroExitIsFailure() = runBlocking {
        val runner = FakeShellRunner(ShellResult(1, "", "error: 编译失败", false, 30L))
        val r = tool(runner).execute(mapOf("command" to "javac Foo.java"))
        assertTrue(r is ToolOutcome.Failure, "非 0 退出码必须失败，实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("编译失败"), "要带上错误内容")
    }

    @Test
    @DisplayName("成功时摘录里有 exit=0 与全量日志路径")
    fun successCarriesLogPath() = runBlocking {
        val runner = FakeShellRunner(ShellResult(0, "installed ok", "", false, 5L))
        val r = tool(runner).execute(mapOf("command" to "ls"))
        assertTrue(r is ToolOutcome.Success, "应当成功，实际：$r")
        val detail = (r as ToolOutcome.Success).detail
        assertTrue(detail.contains("exit=0"), "要给出退出码，实际：$detail")
        assertTrue(detail.contains(".heracles/logs/"), "要给出完整日志路径，实际：$detail")
        // 日志真的落盘了
        assertTrue(
            Files.walk(root).use { s -> s.anyMatch { it.fileName.toString().startsWith("shell-") } },
            "全量日志必须真的写进工作区",
        )
    }

    @Test
    @DisplayName("★ 超时被明确标注（不能伪装成普通失败）")
    fun timeoutIsMarked() = runBlocking {
        val runner = FakeShellRunner(
            ShellResult(ShellResult.TIMEOUT_EXIT_CODE, "partial", "", true, 120_000L)
        )
        val r = tool(runner).execute(mapOf("command" to "sleep 999"))
        assertTrue(r is ToolOutcome.Failure)
        assertTrue((r as ToolOutcome.Failure).reason.contains("[超时]"), "必须标出超时")
    }

    @Test
    @DisplayName("★ 熔断触发时命令**不执行**")
    fun thermalPauseBlocksExecution() = runBlocking {
        val runner = FakeShellRunner()
        val hot = object : dev.heracles.core.guard.DeviceHealthSource {
            override suspend fun read() = dev.heracles.core.guard.DeviceHealth(90, 460, true)
        }
        val r = tool(runner, hot).execute(mapOf("command" to "ls"))
        assertTrue(r is ToolOutcome.Failure, "过热必须暂停，实际：$r")
        assertTrue((r as ToolOutcome.Failure).reason.contains("已暂停"), "理由要说明是暂停")
        assertTrue(runner.calls.isEmpty(), "暂停时不得执行命令")
    }

    @Test
    @DisplayName("command 为空 → 失败")
    fun blankCommandFails() = runBlocking {
        assertTrue(tool(FakeShellRunner()).execute(mapOf("command" to " ")) is ToolOutcome.Failure)
    }

    // ------------------------------------------------ 日志摘录档位（F5a / P1-5）

    /** 读本次测试**唯一**落盘的那份 shell 日志（每个测试方法有独立临时工作区）。 */
    private fun onlyLogText(): String {
        val dir = root.resolve(Contract.Toolchain.LOG_DIR)
        val files = Files.list(dir).use { stream -> stream.toList() }
        assertEquals(1, files.size, "应当恰好一份日志，实际：$files")
        return Files.readString(files[0])
    }

    @Test
    @DisplayName("★ 全量日志落盘不受摘录档位影响：档位只管摘录，证据文件一行不少")
    fun fullLogFileIsUnaffectedByExcerptTier() = runBlocking {
        // 300 行输出、每 3 行一个 error（命中区间连成一片 ⇒ 必然撑到额度）
        val raw = (1..300).joinToString("\n") { if (it % 3 == 0) "error: e$it" else "line $it" }
        val runner = FakeShellRunner(ShellResult(1, raw, "", false, 9L))

        // ① 极小档位（5 行）—— 摘录被压到 5 行，但落盘必须是完整的
        val tiny = RunShellCommandTool(runner, fs, maxExcerptLines = 5)
            .execute(mapOf("command" to "make"))
        assertTrue(tiny is ToolOutcome.Failure, "非 0 退出码必须是 Failure，实际：$tiny")
        val tinyText = (tiny as ToolOutcome.Failure).reason
        val tinyLog = onlyLogText()

        // ② 契约额度（200 行）—— 同一份输出再跑一次
        val cloud = RunShellCommandTool(runner, fs, maxExcerptLines = Contract.Shell.LOG_EXCERPT_LINES)
            .execute(mapOf("command" to "make"))
        assertTrue(cloud is ToolOutcome.Failure, "非 0 退出码必须是 Failure，实际：$cloud")
        val cloudText = (cloud as ToolOutcome.Failure).reason
        val cloudLog = onlyLogText()

        // ★ 落盘正文必须与档位无关（这是最容易写坏的一条：拿"截断后的摘录"去落盘）
        assertEquals(
            tinyLog.substringAfter("\n\n"),
            cloudLog.substringAfter("\n\n"),
            "全量日志正文不许随摘录档位变化",
        )
        assertEquals(
            300,
            cloudLog.substringAfter("\n\n").trimEnd('\n').lines().size,
            "落盘正文必须仍是完整的 300 行",
        )
        // 表头里的"摘录只有 N 行"必须与档位同源（不许写死 40）
        assertTrue(tinyLog.contains("摘录只有 5 行"), "小档位表头数字错了：${tinyLog.take(200)}")
        assertTrue(cloudLog.contains("摘录只有 200 行"), "云端档表头数字错了：${cloudLog.take(200)}")
        // 摘录本身必须真的按档位变，否则"分级"没生效
        val tinyErrors = Regex("error: e").findAll(tinyText).count()
        val cloudErrors = Regex("error: e").findAll(cloudText).count()
        assertTrue(tinyErrors < 5, "5 行额度里不该出现这么多 error：$tinyErrors")
        assertTrue(cloudErrors > tinyErrors, "云端档摘录必须真的多给内容（$tinyErrors → $cloudErrors）")
    }

    @Test
    @DisplayName("★ 默认额度 = 契约值（S1b 起 200）：表头报真数、摘录 ≤ 额度、落盘日志表头写 200")
    fun defaultTierIsTheContractValue() = runBlocking {
        val raw = (1..100).joinToString("\n") { "line $it\nerror: e$it\nline $it-b" }
        val runner = FakeShellRunner(ShellResult(1, raw, "", false, 3L))

        val out = RunShellCommandTool(runner, fs).execute(mapOf("command" to "make"))
        assertTrue(out is ToolOutcome.Failure, "非 0 退出码必须是 Failure")
        val text = (out as ToolOutcome.Failure).reason

        // 表头形状与改造前一致（命中数 / 总行数 / 截断 / 完整日志路径）
        assertTrue(text.contains("100 处错误 / 共 300 行"), "表头必须报真数：$text")
        assertTrue(text.contains("（摘录已截断）"), "超过额度必须如实说截断：$text")
        assertTrue(text.contains(Contract.Toolchain.LOG_DIR), "必须给出完整日志路径：$text")

        // 摘录正文（表头之后、末尾「耗时」之前的那些行）必须 ≤ 契约额度
        val body = text.substringAfter("\n").substringBefore("\n（耗时")
        assertTrue(
            body.lines().size <= Contract.Shell.LOG_EXCERPT_LINES,
            "默认摘录必须 ≤ ${Contract.Shell.LOG_EXCERPT_LINES} 行，实际 ${body.lines().size}",
        )
        // 落盘日志表头的数字也必须与契约同源（不是写死的另一个数）
        assertTrue(
            onlyLogText().contains("摘录只有 ${Contract.Shell.LOG_EXCERPT_LINES} 行"),
            "默认日志表头数字必须是 ${Contract.Shell.LOG_EXCERPT_LINES}",
        )
    }
}

/** `search_tools` 的行为门禁 —— `26-编码层工具链与逆向引擎.md` §5.2。 */
class SearchToolsToolTest {

    private fun spec(name: String, desc: String, params: List<dev.heracles.core.tool.ToolParam> = emptyList()) =
        ToolSpec(name, desc, params)

    private val resident = listOf(spec("read_file", "读文件"), spec("write_file", "写文件"))

    private val longTail = listOf(
        spec(
            "build_apk", "从零构建 APK",
            listOf(dev.heracles.core.tool.ToolParam("project_dir", "string", "项目目录")),
        ),
        spec("apk_sign", "给 APK 签名"),
    )

    private val registry = dev.heracles.core.tool.ToolRegistry(
        resident, longTail, mapOf("build_apk" to dev.heracles.core.tool.ToolGroup.BUILD),
    )

    @Test
    @DisplayName("★ 命中后写入已披露集合（grammar 靠它枚举工具名）")
    fun hitRecordsDisclosure() = runBlocking {
        val disclosed = mutableSetOf<String>()
        val r = SearchToolsTool(registry, disclosed).execute(mapOf("query" to "打包"))
        assertTrue(r is ToolOutcome.Success, "应当命中，实际：$r")
        assertTrue("build_apk" in disclosed, "必须记录披露，否则模型生成不出这个调用")
        assertTrue((r as ToolOutcome.Success).detail.contains("build_apk"))
    }

    @Test
    @DisplayName("★ 无命中：如实说没有，并列出可用工具（不硬凑）")
    fun missIsHonest() = runBlocking {
        val disclosed = mutableSetOf<String>()
        val r = SearchToolsTool(registry, disclosed).execute(mapOf("query" to "量子纠缠"))
        assertTrue(r is ToolOutcome.Failure, "应当失败，实际：$r")
        val reason = (r as ToolOutcome.Failure).reason
        assertTrue(reason.contains("没有匹配"), "要如实说没找到")
        assertTrue(reason.contains("read_file"), "要给出可用的常驻工具，实际：$reason")
        assertTrue(disclosed.isEmpty(), "没找到就不该披露任何东西")
    }

    @Test
    @DisplayName("披露带上参数表（模型需要参数名与含义才能正确调用）")
    fun rendersParameterTable() = runBlocking {
        val r = SearchToolsTool(registry, mutableSetOf()).execute(mapOf("query" to "打包"))
        val detail = (r as ToolOutcome.Success).detail
        assertTrue(detail.contains("project_dir"), "要列出参数名，实际：$detail")
        assertTrue(detail.contains("项目目录"), "要列出参数含义")
    }

    @Test
    @DisplayName("★ 披露文本要说清\"可以不填\"的两种形态：可省略 / 可以传空字符串（F7b）")
    fun rendersOptionalityHints() = runBlocking {
        // 这是**模型唯一能"看见"可选性的地方**（冻结前缀 JSON 的 required 数组是给协议看的）
        val params = listOf(
            dev.heracles.core.tool.ToolParam(
                "both", "string", "两者都有", allowEmpty = true, optional = true,
            ),
            dev.heracles.core.tool.ToolParam("opt", "string", "只可省略", optional = true),
            dev.heracles.core.tool.ToolParam("empty", "string", "只可空串", allowEmpty = true),
        )
        val reg = dev.heracles.core.tool.ToolRegistry(
            resident = resident,
            longTail = listOf(spec("hint_tool", "提示语测试 打包", params)),
            groups = emptyMap(),
        )
        val r = SearchToolsTool(reg, mutableSetOf()).execute(mapOf("query" to "打包"))
        assertTrue(r is ToolOutcome.Success, "应当命中，实际：$r")
        val detail = (r as ToolOutcome.Success).detail

        assertTrue(detail.contains("（可省略，可以传空字符串）"), "两者都有就都写，实际：$detail")
        assertTrue(detail.contains("（可省略）"), "optional 必须显式说，实际：$detail")
        assertTrue(detail.contains("（可以传空字符串）"), "allowEmpty 照旧要说，实际：$detail")
    }

    @Test
    @DisplayName("★ 默认披露额度：真的披露 6 条，且文案里的数字是 6（「文案说 6、实际给 3」没人抓得住）")
    fun defaultDiscloseLimitDisclosesSixAndSaysSix() = runBlocking {
        // 6 个同分组工具 ⇒ 查询「apk」必然全部命中（检索面由分组关键词提供）
        val tail = (1..6).map { spec("apk_tool_$it", "APK 工具 $it") }
        val groups = tail.associate { it.name to dev.heracles.core.tool.ToolGroup.APK }
        // 默认值 = 契约里那唯一一档（6）。S1b 之前这里传的是"云端档"，
        // 因为当时默认是"本地 3"、云端另配 6；分级删除后**默认就是 6**。
        val default = dev.heracles.core.tool.ToolRegistry(
            resident = resident,
            longTail = tail,
            groups = groups,
        )

        val disclosed = mutableSetOf<String>()
        val r = SearchToolsTool(default, disclosed).execute(mapOf("query" to "apk"))
        assertTrue(r is ToolOutcome.Success, "应当命中，实际：$r")
        val detail = (r as ToolOutcome.Success).detail

        // ★ 不只断言注册表配置：真的数一遍披露了几条、文案里的数字是不是同一个。
        //   "上层配了 6、实现里仍写死 3"这种谎话，只有跑一遍才抓得住。
        assertEquals(6, disclosed.size, "默认档一次必须真的披露 6 个（不是文案写 6、实际给 3）")
        assertTrue(detail.contains("找到 6 个工具"), "实际返回条数与文案必须一致：$detail")
        assertTrue(detail.contains("一次最多披露 6 个"), "默认档文案必须是 6：$detail")

        // 显式收紧（3）时文案也必须跟着说 3 —— 参数仍然真的生效（不是写死的 6）
        val tight = dev.heracles.core.tool.ToolRegistry(resident, tail, groups, discloseLimit = 3)
        val tightDetail = (
            SearchToolsTool(tight, mutableSetOf()).execute(mapOf("query" to "apk"))
                as ToolOutcome.Success
            ).detail
        assertEquals(
            3,
            tightDetail.substringAfter("找到 ").substringBefore(" 个").toInt(),
            "显式收紧后必须只披露 3 条：$tightDetail",
        )
        assertTrue(tightDetail.contains("一次最多披露 3 个"), "文案必须跟着配置走：$tightDetail")
    }
}
