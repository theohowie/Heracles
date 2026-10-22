package dev.heracles.cloud

import dev.heracles.cloud.context.AgentMessage
import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.context.ContextManager
import dev.heracles.cloud.context.ConversationSummarizer
import dev.heracles.cloud.context.MessageRole
import dev.heracles.cloud.context.Overflow
import dev.heracles.cloud.tool.CloudToolValidator
import dev.heracles.cloud.tool.SchemaParam
import dev.heracles.cloud.tool.ToolSchema
import dev.heracles.core.tool.CloudParam
import dev.heracles.core.tool.ParamType
import dev.heracles.core.tool.renderObjectSchema
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **云端释放验证** —— 证明旧的小模型限制**真的被解除了**。
 *
 * 每个 `@DisplayName` 都写成"旧行为 vs 新行为"的对照，
 * 这样测试失败时能一眼看出是哪条限制复发了。
 */
class CloudPipelineReleaseTest {

    // ============================================================
    // 模块一：原生 Schema —— 真实类型
    // ============================================================

    @Test
    @DisplayName("★ integer 参数渲染成 type=integer（旧路径全仓 55 个参数都是 string）")
    fun integerParamRendersAsInteger() {
        val json = renderObjectSchema(
            listOf(
                CloudParam("max_results", ParamType.Int, "最多返回多少条"),
                CloudParam("timeout_sec", ParamType.Int, "超时秒数"),
            )
        )
        assertTrue(json.contains("\"max_results\":{\"type\":\"integer\""), "integer 必须是 integer：$json")
        assertTrue(json.contains("\"timeout_sec\":{\"type\":\"integer\""), "integer 必须是 integer：$json")
        assertFalse(json.contains("\"type\":\"string\""), "这两个参数不该退化成 string：$json")
    }

    @Test
    @DisplayName("★ boolean 参数渲染成 type=boolean")
    fun booleanParamRendersAsBoolean() {
        val json = renderObjectSchema(
            listOf(CloudParam("replace_all", ParamType.Bool, "是否全部替换"))
        )
        assertTrue(json.contains("\"type\":\"boolean\""), "boolean 必须是 boolean：$json")
    }

    @Test
    @DisplayName("★ array of objects 渲染成嵌套 items（旧实现只能塞进一个 string 参数）")
    fun arrayOfObjectsRendersNested() {
        val steps = CloudParam(
            "steps",
            ParamType.Array(
                items = ParamType.Object(
                    props = listOf(
                        CloudParam("text", ParamType.Text, "步骤描述"),
                        CloudParam("status", ParamType.Text, "状态", enum = listOf("pending", "active", "done")),
                    )
                ),
            ),
            "完整步骤列表",
        )
        val json = renderObjectSchema(listOf(steps))
        assertTrue(json.contains("\"type\":\"array\""), "必须是 array：$json")
        assertTrue(json.contains("\"items\":{\"type\":\"object\""), "items 必须是 object：$json")
        assertTrue(json.contains("\"enum\":[\"pending\",\"active\",\"done\"]"), "enum 必须渲染：$json")
    }

    @Test
    @DisplayName("★ Schema 确定性：同一声明渲染两次逐字节相同（前缀缓存前提）")
    fun schemaIsDeterministic() {
        val params = listOf(
            CloudParam("z_last", ParamType.Text, "最后一个"),
            CloudParam("a_first", ParamType.Int, "第一个"),
            CloudParam("m_mid", ParamType.Bool, "中间"),
        )
        assertEquals(renderObjectSchema(params), renderObjectSchema(params))
        val json = renderObjectSchema(params)
        assertTrue(json.indexOf("\"a_first\"") < json.indexOf("\"m_mid\""), "必须按名字典序：$json")
        assertTrue(json.indexOf("\"m_mid\"") < json.indexOf("\"z_last\""), "必须按名字典序：$json")
    }

    @Test
    @DisplayName("★ optional 参数不进 required 数组")
    fun optionalParamsNotRequired() {
        val json = renderObjectSchema(
            listOf(
                CloudParam("path", ParamType.Text, "路径", required = true),
                CloudParam("offset", ParamType.Int, "起始行", required = false),
            )
        )
        assertTrue(json.contains("\"required\":[\"path\"]"), "只有 path 必填：$json")
        assertFalse(json.contains("\"required\":[\"offset\"]"), "offset 不该必填：$json")
    }

    // ============================================================
    // 模块三：校验器 —— 没有 500 字符断头台
    // ============================================================

    @Test
    @DisplayName("★★ 长参数不再被 500 字符拦死（旧: edit.new_string 上限 500）")
    fun longParameterIsNotRejected() {
        val bigText = "x".repeat(5000)
        val schema = ToolSchema(listOf(SchemaParam("new_string", "string", true)))
        val call = CloudToolCall("c1", "edit", """{"new_string":"$bigText"}""")
        val result = CloudToolValidator.validate(call, schema)
        assertTrue(result is CloudToolValidator.Result.Valid, "5000 字符必须放行，实际：$result")
    }

    @Test
    @DisplayName("★★ 英文 6 步计划（>500 字符）必须放行（旧: steps 上限 500 实测超限）")
    fun englishSixStepPlanPasses() {
        // 实测长度 513（含状态字段与英文步骤描述）—— 旧实现在这里直接超 500 被拦
        val steps = """[{"text":"Read the existing index.html to understand the current structure and styling completely","status":"done"},{"text":"Create the game board grid layout with CSS","status":"done"},{"text":"Implement the 4x4 tile randomization logic in JavaScript","status":"done"},{"text":"Add score tracking and win-condition detection","status":"active"},{"text":"Verify the page runs correctly in a mobile browser","status":"pending"},{"text":"Package the project into a signed APK and install it on the device","status":"pending"}]"""
        assertTrue(steps.length > 500, "前提：这个 payload 必须 >500 字符，实际 ${steps.length}")
        val schema = ToolSchema(listOf(SchemaParam("steps", "array", true)))
        val call = CloudToolCall("c1", "update_plan", "{\"steps\":$steps}")
        val result = CloudToolValidator.validate(call, schema)
        assertTrue(result is CloudToolValidator.Result.Valid, "${steps.length} 字符的计划必须放行，实际：$result")
    }

    @Test
    @DisplayName("★ 唯一的物理闸是 10MB：超过才拦，且提示可操作")
    fun onlyPhysicalLimitIs10Mb() {
        val huge = "x".repeat(CloudToolValidator.MAX_PAYLOAD_BYTES + 10)
        // 必须给 schema：不给的话会被"该工具不接受参数"先拦下，走不到 10MB 闸
        val schema = ToolSchema(listOf(SchemaParam("content", "string", true)))
        val call = CloudToolCall("c1", "write_file", """{"content":"$huge"}""")
        val result = CloudToolValidator.validate(call, schema)
        assertTrue(result is CloudToolValidator.Result.Invalid, "超 10MB 必须拦下")
        val detail = (result as CloudToolValidator.Result.Invalid).detail
        assertTrue(detail.contains("MB"), "提示必须说清大小：$detail")
        assertTrue(detail.contains("apply_patch") || detail.contains("拆成"), "必须给出可操作建议：$detail")
    }

    @Test
    @DisplayName("★ 类型错如实报错，不静默归一化（旧实现 toString() 抹平一切）")
    fun typeMismatchIsReportedNotCoerced() {
        val schema = ToolSchema(listOf(SchemaParam("max_results", "integer", true)))
        val call = CloudToolCall("c1", "find_files", """{"max_results":"200"}""")
        val result = CloudToolValidator.validate(call, schema)
        assertTrue(result is CloudToolValidator.Result.Invalid, "字符串 200 喂给 integer 必须报错")
        val detail = (result as CloudToolValidator.Result.Invalid).detail
        assertTrue(detail.contains("integer"), "必须说清期望类型：$detail")
        assertTrue(detail.contains("string"), "必须说清实际类型：$detail")
    }

    @Test
    @DisplayName("★ enum 校验：status 只允许 pending/active/done")
    fun enumIsValidated() {
        val schema = ToolSchema(
            listOf(SchemaParam("status", "string", true, listOf("pending", "active", "done")))
        )
        val bad = CloudToolCall("c1", "update_plan", """{"status":"进行中"}""")
        assertTrue(CloudToolValidator.validate(bad, schema) is CloudToolValidator.Result.Invalid, "非法枚举必须拒绝")

        val good = CloudToolCall("c2", "update_plan", """{"status":"active"}""")
        assertTrue(CloudToolValidator.validate(good, schema) is CloudToolValidator.Result.Valid, "合法枚举必须放行")
    }

    @Test
    @DisplayName("★ integer 传 200 正常通过")
    fun integerValuePasses() {
        val schema = ToolSchema(listOf(SchemaParam("max_results", "integer", true)))
        val call = CloudToolCall("c1", "find_files", """{"max_results":200}""")
        assertTrue(CloudToolValidator.validate(call, schema) is CloudToolValidator.Result.Valid)
    }

    // ============================================================
    // 模块二：上下文 —— 不再"只留 10 轮"
    // ============================================================

    private class FakeSummarizer(private val result: String? = "摘要内容") : ConversationSummarizer {
        var calls = 0
        override suspend fun summarize(dropped: List<AgentMessage>): String {
            calls++
            return result ?: ""
        }
    }

    private fun msgs(n: Int, textLen: Int = 100): List<AgentMessage> =
        (1..n).map { i -> AgentMessage(MessageRole.USER, "msg$i " + "x".repeat(textLen)) }

    @Test
    @DisplayName("★★ 30 轮历史在 200K 窗口下全部装载（旧: 硬切最近 10 轮）")
    fun thirtyTurnsAllKeptUnderLargeWindow() {
        val cm = ContextManager(modelContextWindow = 200_000, summarizer = FakeSummarizer())
        val history = msgs(30, textLen = 200)
        val plan = cm.plan(systemTokens = 1000, messages = history)
        assertEquals(Overflow.NONE, plan.overflow, "200K 窗口下 30 轮短消息必须全装")
        assertEquals(30, plan.kept.size, "必须全部保留，不是 10 条")
        assertEquals(0, plan.dropped.size, "不该丢弃任何东西")
    }

    @Test
    @DisplayName("★ 溢出时才丢，且丢的是最旧的（不是固定轮数）")
    fun overflowDropsOldestOnly() {
        val cm = ContextManager(modelContextWindow = 1000, summarizer = FakeSummarizer())
        val history = msgs(30, textLen = 200)
        val plan = cm.plan(systemTokens = 100, messages = history)
        assertEquals(Overflow.TRIGGERED, plan.overflow, "小窗口必须触发溢出")
        assertTrue(plan.dropped.isNotEmpty(), "应有被丢弃的消息")
        val keptFirst = plan.kept.first().text.substringBefore(" ")
        val droppedLast = plan.dropped.last().text.substringBefore(" ")
        assertTrue(
            keptFirst.removePrefix("msg").toInt() > droppedLast.removePrefix("msg").toInt(),
            "保留的必须比丢弃的更新：kept=$keptFirst dropped=$droppedLast",
        )
    }

    @Test
    @DisplayName("★ 摘要失败退回完整历史并如实标记（宁可贵，不要残缺上下文）")
    fun summaryFailureFallsBackToFullHistory() = runBlocking {
        val cm = ContextManager(modelContextWindow = 500, summarizer = FakeSummarizer(result = null))
        val history = msgs(30, textLen = 200)
        val result = cm.applyCompaction(systemTokens = 100, messages = history)
        assertTrue(result.summaryFailed, "必须如实标记失败")
        assertEquals(30, result.messages.size, "失败时必须保留完整历史，不能残缺")
    }

    @Test
    @DisplayName("★ 摘要成功 ⇒ 摘要在最前面、原文被替换")
    fun summaryIsPrepended() = runBlocking {
        val cm = ContextManager(modelContextWindow = 500, summarizer = FakeSummarizer())
        val history = msgs(30, textLen = 200)
        val result = cm.applyCompaction(systemTokens = 100, messages = history)
        assertFalse(result.summaryFailed)
        assertNotNull(result.summary)
        assertTrue(result.messages.first().isSummary, "第一条必须是摘要")
        assertTrue(result.messages.first().text.contains("摘要内容"), "摘要正文要在里面")
        assertTrue(result.messages.size < 30, "总条数应少于原文")
    }

    @Test
    @DisplayName("★ 摘要输出预算下限 4096（旧: 1024 ⇒ 思考吃光预算、正文为空）")
    fun summaryBudgetFloorIs4096() {
        assertEquals(4096, ContextManager.MIN_SUMMARY_OUTPUT_TOKENS)
        assertTrue(
            ContextManager.MIN_SUMMARY_OUTPUT_TOKENS >= 4096,
            "摘要预算必须 ≥ 4096，否则思考模型会复现正文为空的故障",
        )
    }

    @Test
    @DisplayName("★ 装载决策是纯函数：同样输入两次结果相同（确定性）")
    fun planIsDeterministic() {
        val cm = ContextManager(modelContextWindow = 2000, summarizer = FakeSummarizer())
        val history = msgs(20, textLen = 300)
        val a = cm.plan(100, history)
        val b = cm.plan(100, history)
        assertEquals(a.kept.size, b.kept.size)
        assertEquals(a.dropped.size, b.dropped.size)
        assertEquals(a.kept.map { it.text }, b.kept.map { it.text })
    }

    // ============================================================
    // 模块四：熔断阈值与预算
    // ============================================================

    @Test
    @DisplayName("★★ 连续 Schema 失败阈值 = 5（旧: 2 ⇒ 把可自愈的漂移升级成任务失败）")
    fun consecutiveFailureLimitIsFive() {
        assertEquals(5, CloudAgentPipeline.DEFAULT_CONSECUTIVE_FAILURE_LIMIT)
    }

    @Test
    @DisplayName("★ 单轮输出预算 16384（旧: 4096，依据是本地 4096 上下文装不下大输出）")
    fun outputBudgetIs16k() {
        assertEquals(16_384, CloudAgentPipeline.MAX_OUTPUT_TOKENS)
    }

    @Test
    @DisplayName("★ 单轮调用上限 32（旧: 4 ⇒ 逼模型多跑一轮）")
    fun callsPerTurnIs32() {
        assertTrue(
            dev.heracles.cloud.tool.CloudToolExecutor.MAX_CALLS_PER_TURN >= 32,
            "旧值 4 会逼模型多跑轮次；云端应给足",
        )
    }

    // ============================================================
    // 模块四：提示词 — 没有"教练三连"
    // ============================================================

    @Test
    @DisplayName("★★ 系统提示词不含教练三连（2 步以上 / 一次只做一步 / 3000 字符分段）")
    fun systemPromptHasNoCoachTriad() {
        val p = dev.heracles.cloud.prompt.CloudPrompts.SYSTEM
        assertFalse(p.contains("2 步以上"), "『计划要给 2 步以上』必须删除")
        assertFalse(p.contains("一次只做当前那一步"), "『一次只做一步』必须删除")
        assertFalse(p.contains("3000 字符"), "『3000 字符分段』必须删除")
    }

    @Test
    @DisplayName("★ 系统提示词鼓励自主规划与并行（正向教练）")
    fun systemPromptEncouragesAutonomy() {
        val p = dev.heracles.cloud.prompt.CloudPrompts.SYSTEM
        assertTrue(p.contains("自主决定"), "必须明确鼓励自主")
        assertTrue(p.contains("一次发起多个"), "必须鼓励并行调用")
        assertTrue(p.contains("一次性写完整"), "必须允许长输出")
    }

    @Test
    @DisplayName("★★ 纯文本回答就是最终答复（不再要求 JSON 信封）")
    fun plainTextIsFinalAnswer() {
        val p = dev.heracles.cloud.prompt.CloudPrompts.SYSTEM
        assertFalse(p.contains("{\"final\""), "不该再教 JSON 信封")
        assertFalse(p.contains("只输出三种"), "不该再教三种顶层形状")
    }

    // ============================================================
    // 模块五：glob 语法
    // ============================================================

    @Test
    @DisplayName("★★ [abc] 字符集可用（旧: 当字面量 ⇒ 0 命中 ⇒ 模型以为文件不存在）")
    fun charClassWorks() {
        val r = dev.heracles.agent.tools.CloudGlob.compile("[Mm]ain.kt").regex
        assertTrue(r.matches("Main.kt"), "[Mm]ain.kt 必须匹配 Main.kt")
        assertTrue(r.matches("main.kt"), "[Mm]ain.kt 必须匹配 main.kt")
        assertFalse(r.matches("xain.kt"), "不该匹配 xain.kt")
    }

    @Test
    @DisplayName("★★ [a-z] 区间可用")
    fun charRangeWorks() {
        val r = dev.heracles.agent.tools.CloudGlob.compile("file[0-9].txt").regex
        assertTrue(r.matches("file3.txt"), "file[0-9].txt 必须匹配 file3.txt")
        assertFalse(r.matches("filex.txt"), "不该匹配 filex.txt")
    }

    @Test
    @DisplayName("★★ {kt,java} 枚举可用（旧: 0 命中）")
    fun braceEnumWorks() {
        val r = dev.heracles.agent.tools.CloudGlob.compile("*.{kt,java}").regex
        assertTrue(r.matches("Main.kt"), "*.{kt,java} 必须匹配 Main.kt")
        assertTrue(r.matches("Main.java"), "*.{kt,java} 必须匹配 Main.java")
        assertFalse(r.matches("Main.xml"), "不该匹配 Main.xml")
    }

    @Test
    @DisplayName("★ 语法仍不破坏：* 不跨目录、a+b 当字面量")
    fun wildcardBoundariesPreserved() {
        val star = dev.heracles.agent.tools.CloudGlob.compile("*.kt").regex
        assertTrue(star.matches("Main.kt"))
        assertFalse(star.matches("src/Main.kt"), "段内 * 不该跨目录")

        val plus = dev.heracles.agent.tools.CloudGlob.compile("a+b.kt").regex
        assertTrue(plus.matches("a+b.kt"), "a+b 必须当字面量")
        assertFalse(plus.matches("aab.kt") || plus.matches("ab.kt"), "不该被当正则")
    }

    @Test
    @DisplayName("★ 未闭合括号按字面量 + 记 warning（不静默 0 命中）")
    fun unclosedBracketWarns() {
        val compiled = dev.heracles.agent.tools.CloudGlob.compile("[abc")
        assertFalse(compiled.warnings.isEmpty(), "未闭合必须产生 warning，否则模型以为文件不存在")
    }
}
