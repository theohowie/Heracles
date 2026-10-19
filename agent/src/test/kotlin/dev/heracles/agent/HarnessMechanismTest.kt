package dev.heracles.agent

import dev.heracles.core.contract.Contract
import dev.heracles.core.context.PrefixBuilder
import dev.heracles.core.patch.ApplyResult
import dev.heracles.core.patch.UnifiedPatch
import dev.heracles.core.provider.CacheStats
import dev.heracles.core.provider.FakeProvider
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.GenerateResult
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.ProviderCapabilities
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ProviderHealth
import dev.heracles.core.provider.ProviderKind
import dev.heracles.core.tool.ToolCall
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **harness 核心机制的行为门禁**（2026-10-14）。
 *
 * ## 用户真机反馈（原话）
 *
 * > 「两次的思考过程是不是极度相似？都是用户怎么这么样，
 * >   明明这个是已经思考过的，结果还是再思考一遍。
 * >   这个 agent 还有很大的缺陷，一个完好的智能体最核心的是
 * >   **harness**，但是本 APP 没有」
 *
 * ## 这个文件守什么
 *
 * | # | 不变量 | 破坏后果 |
 * |---|---|---|
 * | 1 | 工作记忆**包含已完成的事实** | 模型重复思考（用户看到的直接现象）|
 * | 2 | 工作记忆**不含未执行的操作** | 进度撒谎（把拦截/失败当完成）|
 * | 3 | 计划推进只认**真实成功** | 进度条作弊 |
 * | 4 | 计划解析失败**返回 null** | 编造空计划 → UI 显示假进度 |
 */
class HarnessMechanismTest {

    /** 空文件系统替身（这些测试只验工作记忆与计划，不碰真实 IO）。 */
    private class NoopFs : dev.heracles.workspace.WorkspaceFs {
        override val info = dev.heracles.workspace.WorkspaceInfo(
            java.nio.file.Path.of(".").toAbsolutePath(), "test"
        )
        override suspend fun list(relativeDir: String): List<dev.heracles.workspace.FileEntry> =
            emptyList()
        override suspend fun readText(relativePath: String): String = ""
        override suspend fun writeText(relativePath: String, content: String): Long = 0
        override suspend fun exists(relativePath: String): Boolean = false
        override suspend fun mkdirs(relativeDir: String) {}
    }

    private fun record(
        index: Int,
        tool: String?,
        succeeded: Boolean?,
        verdict: String,
        result: String? = null,
    ) = TurnRecord(
        index = index,
        userText = "写个2048",
        rawOutput = "{}",
        toolCall = tool?.let { ToolCall(it, mapOf("path" to "index.html")) },
        toolResult = result,
        verdict = verdict,
        cache = CacheStats.withoutCacheReporting(0, 0),
        wallMs = 100,
        toolSucceeded = succeeded,
    )

    // ============================================================
    // 1. 工作记忆：必须包含已完成的事实
    // ============================================================

    @Test
    @DisplayName("★★ 工作记忆必须列出已成功的工具调用（消除重复思考）")
    fun ledgerListsSuccessfulWork() {
        val loop = AgentLoop(
            dev.heracles.core.provider.FakeProvider(), NoopFs(), emptyList()
        )
        val ledger = loop.renderProgressLedgerForTest(
            listOf(
                record(1, "list_files", true, "工具成功", "a.txt\nb.txt"),
                record(2, "read_file", true, "工具成功", "<html>…"),
            )
        )
        assertNotNull(ledger, "有真实执行记录就必须产出工作记忆")
        assertTrue(ledger!!.contains("查看目录文件"), "要写明做过什么：$ledger")
        assertTrue(ledger.contains("读取文件"), "两步都要出现：$ledger")
        assertTrue(
            ledger.contains("不要重复"),
            "必须**明确禁止重复** —— 用户看到的正是'又思考一遍'：$ledger",
        )
    }

    @Test
    @DisplayName("★★ 工作记忆不得把拦截/失败写成已完成（进度不能撒谎）")
    fun ledgerDoesNotClaimBlockedWork() {
        val loop = AgentLoop(
            dev.heracles.core.provider.FakeProvider(), NoopFs(), emptyList()
        )
        val ledger = loop.renderProgressLedgerForTest(
            listOf(
                record(1, "list_files", null, "校验失败：参数 dir 为空"),
                record(2, "write_file", false, "工具失败", "磁盘满"),
            )
        )
        assertNotNull(ledger)
        assertTrue(ledger!!.contains("被拦截"), "拦截要如实标为被拦截：$ledger")
        assertTrue(ledger.contains("失败"), "失败要如实标为失败：$ledger")
        assertTrue(
            !ledger.contains("已完成：写入文件"),
            "**绝不能**把失败写成已完成 —— 那会让模型以为做过了：$ledger",
        )
    }

    @Test
    @DisplayName("★ 没有真实执行记录时不产出工作记忆（首轮不该被污染）")
    fun noLedgerOnFirstTurn() {
        val loop = AgentLoop(
            dev.heracles.core.provider.FakeProvider(), NoopFs(), emptyList()
        )
        assertNull(loop.renderProgressLedgerForTest(emptyList()), "首轮没有事实可说")
    }

    // ============================================================
    // 2. 计划状态：只由模型显式给（2026-10-19 删掉"工具成功自动勾"）
    // ============================================================
    //
    // 旧实现在任意工具成功时把第一个未完成步标 done —— 真机上模型先 list_files
    // （与"写 notes.py"无关）就把该步勾掉，模型下一轮自己发现"记录说做完了、
    // 文件却不存在"。自动推进已删除；推进只来自 update_plan（见
    // NativeToolFlowTest.toolSuccessDoesNotAutoAdvancePlan 的门禁）。

    private val threeSteps = TaskPlan(listOf(
        TaskPlan.Step("查看现有文件结构"),
        TaskPlan.Step("创建 index.html"),
        TaskPlan.Step("验证游戏可运行"),
    )).activated()

    @Test
    @DisplayName("★★ update_plan 解析：状态归一化（多 active 只留第一个 / 无 active 自动标第一个未完成）")
    fun parseUpdateNormalizesStatuses() {
        val p = TaskPlan.parseUpdate(
            """[{"text":"a","status":"done"},{"text":"b","status":"active"},{"text":"c","status":"active"}]"""
        )
        assertNotNull(p, "合法输入必须解析出计划")
        assertEquals(TaskPlan.Status.done, p!!.steps[0].status)
        assertEquals(TaskPlan.Status.active, p.steps[1].status)
        assertEquals(TaskPlan.Status.pending, p.steps[2].status, "第二个 active 必须降为 pending")

        val q = TaskPlan.parseUpdate("""[{"text":"a","status":"done"},{"text":"b"}]""")
        assertNotNull(q)
        assertEquals(
            TaskPlan.Status.active, q!!.steps[1].status,
            "没有 active 时第一个未完成步要变 active（UI 的『现在在干什么』必须有答案）",
        )

        // 纯字符串数组是宽容旧写法：视为 pending，再由归一化标出 active
        val r = TaskPlan.parseUpdate("""["a","b"]""")
        assertEquals(2, r?.steps?.size)
        assertEquals(TaskPlan.Status.active, r!!.steps[0].status)

        // 空/非法一律 null —— 不编造空计划
        assertEquals(null, TaskPlan.parseUpdate("not json"))
        assertEquals(null, TaskPlan.parseUpdate("[]"))
        assertEquals(null, TaskPlan.parseUpdate("""[{"status":"done"}]"""))
    }

    @Test
    @DisplayName("★★ 计划可落盘/还原：toJson → fromJson 往返保持步骤与状态")
    fun planJsonRoundTrip() {
        val p = TaskPlan(
            listOf(
                TaskPlan.Step("看结构", TaskPlan.Status.done),
                TaskPlan.Step("写页面", TaskPlan.Status.active),
                TaskPlan.Step("验证", TaskPlan.Status.pending),
            )
        )
        val back = TaskPlan.fromJson(p.toJson())
        assertNotNull(back, "落盘的 JSON 必须能还原")
        assertEquals(p, back)
        assertEquals(null, TaskPlan.fromJson("not json"), "损坏的落盘文件 ⇒ null（不造计划）")
    }

    // ============================================================
    // 3. 计划解析：失败必须返回 null（不编造）
    // ============================================================

    @Test
    @DisplayName("★★ 合法 plan 正确解析")
    fun parsesValidPlan() {
        val p = TaskPlan.parse("""{"plan":["查看结构","写文件","验证"]}""")
        assertNotNull(p)
        assertEquals(3, p!!.steps.size)
        assertEquals("查看结构", p.steps[0].text)
    }

    @Test
    @DisplayName("★★ 单步计划**有效**（2026-10-15 改：原断言被真机实测推翻）")
    fun acceptsSingleStepPlan() {
        // ## 这条测试的来历（一次真实的纠错）
        //
        // 原断言是 `assertNull(...)`，理由「单步清单没有'进度可见'的价值」。
        // **真机实测推翻了这个判断**（用户实测 2026-10-14 21:14）：
        // > 让它「read hello.txt and show me the content」
        // > 模型给了单步计划（读文件确实只需 1 步）
        // > → 「输出无法解析：plan 字段格式不对（需要至少 2 个字符串项）」
        // > → 白白浪费一整轮
        //
        // 单步任务是真实存在的；强制 ≥2 步会让模型凑假步骤或不给计划。
        // **"要不要显示 1 步的卡片"是 UI 的展示决策，不是协议的合法性问题。**
        val p = TaskPlan.parse("""{"plan":["读 hello.txt 并显示内容"]}""")
        assertNotNull(p, "单步计划必须被接受 —— 否则真实任务白烧一轮")
        assertEquals(1, p!!.steps.size)
    }

    @Test
    @DisplayName("★★ 空 plan 才无效（那不是计划）")
    fun rejectsEmptyPlan() {
        assertNull(
            TaskPlan.parse("""{"plan":[]}"""),
            "空数组不是计划 —— 没有可执行的步骤",
        )
    }

    @Test
    @DisplayName("★★ 非法/缺字段的 plan → null（绝不编造空计划）")
    fun rejectsMalformedPlan() {
        assertNull(TaskPlan.parse("""{"plan":"不是数组"}"""))
        assertNull(TaskPlan.parse("""{"final":"回答"}"""), "没有 plan 字段")
        assertNull(TaskPlan.parse("不是 JSON"))
        assertNull(TaskPlan.parse("""{"plan":["  ","   "]}"""),
            "全是空白项 → 过滤后为空 → 无效")
    }

    @Test
    @DisplayName("★ 计划的渲染文本带上三态标记（给模型看的进度）")
    fun rendersStatusMarks() {
        val text = threeSteps.render()
        assertTrue(text.contains("[>]"), "进行中要有标记：$text")
        assertTrue(text.contains("[ ]"), "未开始要有标记：$text")
        assertTrue(text.contains("只做"), "要提示只做当前那一步：$text")
    }

    // ============================================ ask_user（2026-10-16）

    /**
     * **ask_user 工具的行为门禁**（用户需求「ask 功能」）。
     *
     * 修的是模型面对信息不足时的三种坏反应：
     * 瞎猜 / 放弃 / 谎称完成（`实测-08`）。正确反应：问用户。
     */
    @Test
    @DisplayName("★★ ask_user：用户回答后工具返回回答内容")
    fun askUserReturnsUserAnswer() {
        val queue = AgentLoop.AskReplyQueue()
        val tool = dev.heracles.agent.tools.AskUserTool(queue)

        val outcome = runBlocking {
            // 模拟 UI：工具挂起后 100ms，回答到达（真实时序）
            launch {
                kotlinx.coroutines.delay(100)
                queue.reply("覆盖原文件")
            }
            tool.execute(mapOf("question" to "文件已存在，覆盖吗？"))
        }

        assertTrue(
            outcome is ToolOutcome.Success &&
                outcome.detail.contains("覆盖原文件"),
            "用户的回答必须原样回到模型：$outcome",
        )
    }

    @Test
    @DisplayName("★★ ask_user：问题为空 → 失败（不挂起）")
    fun askUserRejectsBlankQuestion() {
        val tool = dev.heracles.agent.tools.AskUserTool(AgentLoop.AskReplyQueue())
        val outcome = runBlocking { tool.execute(mapOf("question" to "  ")) }
        assertTrue(
            outcome is ToolOutcome.Failure,
            "空问题不该挂起等回答 —— 立即失败让模型修正",
        )
    }

    @Test
    @DisplayName("★ ask_user：超时返回可读的失败（不无限挂起）")
    fun askUserTimesOut() {
        // 用极短超时的队列模拟"用户一直不回答"
        val queue = AgentLoop.AskReplyQueue(timeout = kotlin.time.Duration.parse("100ms"))
        val tool = dev.heracles.agent.tools.AskUserTool(queue)
        val outcome = runBlocking { tool.execute(mapOf("question" to "在吗？")) }
        assertTrue(
            outcome is ToolOutcome.Failure && outcome.reason.contains("超时"),
            "超时必须返回**可读的失败**并指引模型自行决定，而不是无限挂起：$outcome",
        )
    }

    // ============================================================
    // 4. 工具协议（F3c 的"按后端分档"已随 ADR-035 S1b 删除 ⇒ 只剩 文本 / 原生 两态）
    // ============================================================

    /**
     * ⚠️ **这里原来有一份 `LEGACY_LOCAL_PROTOCOL`**（改动前那份 760 字文案的逐字符副本），
     * 用来钉"本地档零回退"。ADR-035 S1b 把本地后端与那份文案一起删了
     * （它的前提是"4B 手里没有 `apply_patch`"，而 S1b 之后 `apply_patch` **全员常驻**），
     * 所以**副本一并删除** —— 留着它只会变成"钉一份没人用的字符串"。
     */

    /** 只看提示词的用例，不执行任何工具。 */
    private class StubTool(override val spec: ToolSpec) : AgentTool {
        override suspend fun execute(args: Map<String, String>): ToolOutcome =
            ToolOutcome.Success("不该被调用")
    }

    /** 造一个 loop。[native] = 是否走原生轨（S1b 起**唯一**的协议开关）。 */
    private fun protocolLoop(native: Boolean = false): AgentLoop = AgentLoop(
        provider = FakeProvider(),
        workspace = NoopFs(),
        tools = listOf(StubTool(ToolSpec("write_file", "写文件"))),
        nativeToolsEnabled = native,
    )

    @Test
    @DisplayName("★★ 协议文案确实进冻结前缀：手工按「系统提示 + 协议」重建，文本与 hash 逐字节相同")
    fun textProtocolIsWhatGoesIntoTheFrozenPrefix() {
        // 冻结前缀 hash 的**直接**证据：手工重建一次，与真实 loop 对比。
        // （不埋魔数 hash：那种断言会在任何无关的系统提示/工具改动上误报。）
        val provider = FakeProvider()
        val spec = ToolSpec("write_file", "写文件")
        val manual = PrefixBuilder.buildFrozenAligned(
            systemPrompt = AgentLoop.DEFAULT_SYSTEM_PROMPT + "\n\n" + AgentLoop.TOOL_PROTOCOL_CLOUD,
            tools = listOf(spec),
            skillIndex = emptyList(),
            cacheBlockTokens = provider.capabilities.cacheBlockTokens,
            maxFrozen = Contract.Tools.FROZEN_LIMIT,
        )
        val loop = AgentLoop(
            provider = provider,
            workspace = NoopFs(),
            tools = listOf(StubTool(spec)),
        )
        assertEquals(
            manual.text, loop.frozenPrefix.text,
            "协议文案必须原样进冻结前缀 —— 变了 ⇒ 跨构建首次 prefix cache 全 miss",
        )
        assertEquals(manual.hash, loop.frozenPrefix.hash, "冻结前缀 hash 必须与手工重建一致")
    }

    @Test
    @DisplayName("★★ 文本轨明说「优先局部替换」，且不再有「每次都写全，不要只写片段」")
    fun cloudProtocolPrefersPartialEdit() {
        val text = protocolLoop().frozenPrefix.text

        assertTrue(text.contains("优先局部替换"), "文本轨必须明说优先局部替换：$text")
        assertTrue(text.contains("apply_patch"), "要点名 apply_patch（它已常驻在手边）")
        assertTrue(text.contains("<apply_patch"), "要给标签形态的例子，否则模型得猜格式")
        assertFalse(text.contains("每次都写全"), "这句对强模型是**反向教练**，必须去掉")
        assertFalse(text.contains("不要只写片段"), "同上")
        // 截断护栏不能顺手删掉，只是换了做法：分段 + 增量补，而不是每段重写整文件
        assertTrue(text.contains("增量"), "大文件的截断护栏要保留（换成增量补）")
    }

    @Test
    @DisplayName("★★ 文本轨里教的 apply_patch 例子**真的能被解析、真的能应用**")
    fun cloudPromptExampleIsActuallyParseableAndApplicable() {
        val text = protocolLoop().frozenPrefix.text

        // 从提示词里**抠出**那个例子（而不是在测试里另抄一份）——
        // 这样"提示词里的例子"和"测试验的例子"永远是同一个，改坏了立刻红
        val match = Regex("(?s)<apply_patch path=\"[^\"]+\">.*?</apply_patch>").find(text)
        assertNotNull(
            match,
            "文本轨协议里没有 apply_patch 的例子了 —— 只说「优先局部替换」而不给格式，模型只能猜",
        )
        val example = match!!.value

        val parsed = AgentOutputParser.parse(example)
        assertTrue(
            parsed is AgentOutput.ToolRequest,
            "提示词教的这个例子，解析器**不认** —— 模型照着写就会「明明调了工具却没执行」：$parsed",
        )
        val call = (parsed as AgentOutput.ToolRequest).call
        assertEquals("apply_patch", call.tool, "例子必须解析成 apply_patch")
        assertEquals("index.html", call.args["path"], "path 要解析出来")
        val patch = call.args["patch"].orEmpty()
        assertTrue(patch.contains("@@"), "补丁体要解析出来（缺 @@ 说明 CDATA 剥错了）：$patch")

        // 补丁体本身必须是能应用的 unified diff —— **行数声明与内容必须自洽**：
        // 若例子写成「@@ -12,7 +12,7 @@」却只给 1 行，模型照抄就永远匹配不上
        // （2026-10-18 第一版就是这个问题，被这条用例抓住）。
        assertNotNull(UnifiedPatch.parse(patch), "例子里的补丁体不是合法 unified diff：$patch")
        val original = (1..9).joinToString("\n") { "L$it" } +
            "\n<html>\n<head>\n<title>旧标题</title>\n</head>\n</html>\n"
        val applied = UnifiedPatch.applyDiff(original, patch)
        assertTrue(
            applied is ApplyResult.Ok,
            "例子里的补丁**应用不到**一个正常文件上（模型照抄就会失败）：$applied",
        )
        val result = (applied as ApplyResult.Ok).text
        assertTrue(result.contains("<title>新标题</title>"), "改完之后要有新标题：$result")
        assertFalse(result.contains("<title>旧标题</title>"), "旧标题必须被替换掉")
    }

    @Test
    @DisplayName("★★ 协议只剩两态：默认 = 文本轨；开原生 = 换文案，且**不再教文本调用语法**")
    fun protocolSwitchesOnlyOnTheNativeFlag() {
        val text = protocolLoop().frozenPrefix.text // 默认（nativeToolsEnabled = false）
        val native = protocolLoop(native = true).frozenPrefix.text

        // 文本轨：教 JSON / 标签语法，并优先局部替换
        assertTrue(text.contains("优先局部替换"), "默认必须是文本轨（云端/发行版路径）")
        assertTrue(text.contains("{\"tool\":\"read_file\""), "文本轨要给 JSON 形态的例子")
        assertTrue(text.contains("<write_file"), "文本轨要给标签形态的例子")

        // 原生轨：**不许**再教文本调用语法（F7c 硬前置 2：两套真相 ⇒ 静默失败）
        assertTrue(native.contains("原生"), "原生轨必须明说走原生 function calling")
        assertFalse(
            native.contains("{\"tool\":\"read_file\""),
            "原生轨里还教 JSON 调用语法 ⇒ 模型会把调用写进正文，而'原生优先'会忽略它（静默失败）",
        )
        // 但"计划 / 收尾"这两个**不是调用语法**的机制必须保留（原生轨没有"结束"这种调用）
        assertTrue(text.contains("## 输出格式（三种"), "文本轨必须自报有哪几种输出形态")
        for ((name, t) in listOf("文本轨" to text, "原生轨" to native)) {
            for (marker in listOf("{\"plan\"", "{\"final\"")) {
                assertTrue(t.contains(marker), "$name 少了关键形态「$marker」⇒ 协议被写坏了")
            }
        }
        // 文本轨的三种输出形态（计划 / 标签+CDATA / JSON）都要在
        for (marker in listOf("<write_file", "<apply_patch", "{\"tool\":\"read_file\"")) {
            assertTrue(text.contains(marker), "文本轨少了关键形态「$marker」⇒ 协议被写坏了")
        }

        assertNotEquals(text, native, "两态协议文案必须不同，否则切换根本没生效")
    }

    // ============================================================
    // 5. 原生 `tools` 请求侧（F7b / ADR-031 决策 2）—— **出厂不发**
    //
    // 这一步只做**请求侧的能力与装配**：声明（能力位）与启用（本参数）是两件事。
    // 发出去但响应侧不解析 `tool_calls` ⇒ 模型走原生通道、正文为空 ⇒
    // "模型明明调了工具却什么都没发生"的**静默失败**，比今天的熔断更难查。
    // ============================================================

    /** 一个**声明**支持原生工具、但本轮不启用它的后端 —— 用来证明"能力位 ≠ 已启用"。 */
    private class NativeCapableProvider : ModelProvider {
        override val id: String = "test:native-capable"
        override val kind: ProviderKind = ProviderKind.CLOUD
        override val capabilities: ProviderCapabilities = ProviderCapabilities(
            supportsGrammar = false,
            supportsJsonSchema = true,
            supportsPrefixCache = false,
            needsPrewarm = false,
            supportsNativeTools = true,
        )

        override suspend fun load(config: ProviderConfig): Result<Unit> = Result.success(Unit)
        override suspend fun prewarm(frozenPrefix: String): Result<Unit> = Result.success(Unit)
        override suspend fun generate(request: GenerateRequest): Result<GenerateResult> =
            Result.success(
                GenerateResult("", CacheStats.withoutCacheReporting(0, 0), FinishReason.STOP),
            )

        override suspend fun release() = Unit
        override fun health(): ProviderHealth = ProviderHealth(true, "test")
    }

    @Test
    @DisplayName("★★ 能力位 true **也不代表**已启用 —— 默认一条 tools 声明都不发")
    fun nativeToolsAreOffByDefaultEvenWhenCapable() {
        val loop = AgentLoop(
            provider = NativeCapableProvider(),
            workspace = NoopFs(),
            tools = listOf(StubTool(ToolSpec("write_file", "写文件"))),
        )
        assertTrue(
            loop.nativeToolSpecs().isEmpty(),
            "开关默认关 ⇒ 空列表 ⇒ 文本轨请求体逐字节不变（能力位只声明'有能力'）",
        )
    }

    @Test
    @DisplayName("★★ 打开后发 activeTools()（常驻 + 已披露长尾），顺序稳定")
    fun nativeToolSpecsFollowActiveToolsAndOrder() {
        val longTailTool = ToolSpec("build_apk", "构建")
        val loop = AgentLoop(
            provider = NativeCapableProvider(),
            workspace = NoopFs(),
            tools = listOf(
                StubTool(ToolSpec("write_file", "写文件")),
                StubTool(ToolSpec("read_file", "读文件")),
            ),
            longTail = listOf(StubTool(longTailTool)),
            // 已经被披露 ⇒ 下一轮必须能**原生**调用它
            disclosed = mutableSetOf("build_apk"),
            nativeToolsEnabled = true,
        )

        assertEquals(
            listOf("write_file", "read_file", "build_apk"),
            loop.nativeToolSpecs().map { it.name },
            "顺序 = 常驻在前、长尾按装配顺序；披露后必须进数组（否则长尾在原生轨永远调不动）",
        )
        assertTrue(
            loop.activeTools().map { it.spec.name }.contains("build_apk"),
            "披露过的长尾工具确实'可用'",
        )
        // 未披露时不得出现
        val fresh = AgentLoop(
            provider = NativeCapableProvider(),
            workspace = NoopFs(),
            tools = listOf(StubTool(ToolSpec("write_file", "写文件"))),
            longTail = listOf(StubTool(longTailTool)),
            nativeToolsEnabled = true,
        )
        assertFalse(
            fresh.nativeToolSpecs().map { it.name }.contains("build_apk"),
            "没披露的长尾工具不许进数组（模型不该看见还调不动）",
        )
    }

    // ============================================================
    // 6. 输出形状漂移的容错（2026-10-19 真机：商城会话第 4 轮熔断现场）
    //
    // 现场：模型输出 `{"apply_patch":{"path":"mall.html","patch":"@@ -1,1 +1,1 @@\n"}}`
    // —— 工具名当顶层键。连输出两轮后触发「连续解析失败」熔断。
    // 容错只归一化**可静态判定**的写法：键必须恰好是本次可用工具名。
    // ============================================================

    @Test
    @DisplayName("★★ 工具名当顶层键（真机漂移形态）→ 归一化成同一条 ToolCall")
    fun toolNameAsTopLevelKeyIsNormalized() {
        val raw = """{"apply_patch":{"path":"mall.html","patch":"@@ -1,1 +1,1 @@\n"}}"""
        val parsed = AgentOutputParser.parse(raw, knownTools = setOf("apply_patch", "read_file"))
        assertTrue(parsed is AgentOutput.ToolRequest, "这种形状必须能归一化，实际：$parsed")
        val call = (parsed as AgentOutput.ToolRequest).call
        assertEquals("apply_patch", call.tool)
        assertEquals("mall.html", call.args["path"])
        assertTrue(call.args["patch"].orEmpty().contains("@@"))
    }

    @Test
    @DisplayName("★★ 未知工具名当顶层键 → 仍判不可解析（不猜垃圾输出）")
    fun unknownTopLevelKeyIsStillUnparseable() {
        val raw = """{"whatever":{"path":"x"}}"""
        val parsed = AgentOutputParser.parse(raw, knownTools = setOf("apply_patch"))
        assertTrue(parsed is AgentOutput.Unparseable, "未知名字不能猜成工具调用：$parsed")
        val detail = (parsed as AgentOutput.Unparseable).detail
        assertTrue(detail.contains("whatever"), "失败原因要露出顶层字段名，便于排查：$detail")
    }

    @Test
    @DisplayName("★ 参数平铺在顶层（tool + 平级参数）→ 也归一化")
    fun flatArgsAreNormalized() {
        val raw = """{"tool":"apply_patch","path":"a.html","patch":"@@ -1,1 +1,1 @@\n-a\n+b\n"}"""
        val parsed = AgentOutputParser.parse(raw)
        assertTrue(parsed is AgentOutput.ToolRequest, "平铺参数必须能解析：$parsed")
        val call = (parsed as AgentOutput.ToolRequest).call
        assertEquals("a.html", call.args["path"])
        assertEquals("@@ -1,1 +1,1 @@\n-a\n+b\n", call.args["patch"])
    }

    @Test
    @DisplayName("★ 顶层字段名会出现在不可解析原因里（纠正提示要能说清错在哪）")
    fun unparseableDetailExposesTopLevelKeys() {
        val parsed = AgentOutputParser.parse("""{"name":"apply_patch","arguments":{}}""")
        assertTrue(parsed is AgentOutput.Unparseable)
        val detail = (parsed as AgentOutput.Unparseable).detail
        assertTrue(detail.contains("name"), "原因里要有实际顶层键：$detail")
        assertTrue(detail.contains("arguments"), "原因里要有实际顶层键：$detail")
    }
}
