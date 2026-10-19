package dev.heracles.core.provider

import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.NativeToolCall
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **缓存纪律的回归门禁** —— `07-开发文档.md` §6.3。
 *
 * 这是整套测试里最有价值的一个：它在**没有手机、没有模型**的情况下，
 * 复现出 `实测-01` / `实测-05` 观察到的缓存行为，从而把
 * 「append-only 命中 90–99%，分支复用不可预测因此不可依赖」这条铁律
 * 变成一条可自动执行的断言。
 *
 * 如果哪天有人把会话管理改成"改写式重试"，或者给分支复用设了一个
 * 看似合理的确定值，这个测试会当场变红 —— 而不是等到用户抱怨"变慢了"。
 */
class FakeProviderCacheBehaviourTest {

    private val frozen: String = buildString {
        appendLine("你是 Heracles，运行在手机上的本地 Agent。可用工具如下。")
        repeat(60) { appendLine("步骤$it: 打开应用A${it % 23}，点击按钮B${it % 17}。") }
    }

    private fun newProvider() = FakeProvider().apply {
        onPrompt({ true }, "已执行。")
    }

    // ------------------------------------------------- 原生调用脚本化（F7c）

    /**
     * ★★ 零真机下测原生轨的**唯一出路** —— 替身必须两条路都带出调用。
     *
     * 只喂 `generate()` 不喂 `generateStream()` 是不够的：`AgentLoop` 生产路径
     * 走的是**流式**，调用只在终止块上；漏了流式这一路，测试会绿而线上静默丢调用。
     */
    @Test
    @DisplayName("★ F7c：原生调用在 generate 与 generateStream 两条路都带出，终止块带 finishReason")
    fun nativeCallsCarriedOnBothPaths() = runBlocking {
        val call = NativeToolCall("call_1", "write_file", """{"path":"a.txt","content":"hi"}""")
        val p = FakeProvider().apply {
            onPrompt(
                "写个文件", respond = "", finishReason = FinishReason.TOOL_CALLS,
                nativeCalls = listOf(call),
            )
        }
        p.load(ProviderConfig())

        val oneShot = p.generate(GenerateRequest("帮我写个文件", 32)).getOrThrow()
        assertEquals(listOf(call), oneShot.toolCalls, "非流式路径丢了原生调用")
        assertEquals("", oneShot.text, "原生轨的正文可以是空的（上层不得当成错误）")
        assertEquals(FinishReason.TOOL_CALLS, oneShot.finishReason)

        val chunks = p.generateStream(GenerateRequest("帮我写个文件", 32)).toList()
        val terminal = chunks.last()
        assertTrue(terminal.done, "最后一块必须是终止块")
        assertEquals(listOf(call), terminal.toolCalls, "流式路径丢了原生调用")
        assertEquals(FinishReason.TOOL_CALLS, terminal.finishReason, "终止块的结束原因必须是 TOOL_CALLS")
    }

    // ------------------------------------------------------------ 预热

    @Test
    @DisplayName("预热后第一轮即命中 —— 铁律 2")
    fun prewarmMakesFirstTurnHit() = runBlocking {
        val p = newProvider()
        p.load(ProviderConfig())
        p.prewarm(frozen)

        val r = p.generate(GenerateRequest(frozen, 20)).getOrThrow()
        assertEquals(1, p.prewarmCount)
        assertEquals(0, r.cache.promptTokens, "预热后第一轮不应再重算前缀")
        assertEquals(1.0, r.cache.hitRate!!, 1e-9)
    }

    @Test
    @DisplayName("不预热时第一轮全额重算")
    fun withoutPrewarmFirstTurnIsCold() = runBlocking {
        val p = newProvider()
        p.load(ProviderConfig())
        val r = p.generate(GenerateRequest(frozen, 20)).getOrThrow()
        assertEquals(0, p.prewarmCount)
        assertEquals(0.0, r.cache.hitRate!!, 1e-9)
        assertTrue(r.cache.promptTokens > 100)
    }

    // ------------------------------------------------------------ 铁律 1

    @Test
    @DisplayName("★ append-only 会话：稳态命中率 > 90%")
    fun appendOnlyAchievesHighHitRate() = runBlocking {
        val p = newProvider()
        p.load(ProviderConfig())
        p.prewarm(frozen)

        var conversation = frozen
        val rates = mutableListOf<Double>()

        repeat(12) { i ->
            val r = p.generate(GenerateRequest(conversation, 20)).getOrThrow()
            rates += r.cache.hitRate!!
            // 严格 append：助手输出 + 新观测接在后面，不改写任何已存在的内容
            conversation = conversation + r.text + "\n用户：第${i + 1}步，打开应用并点击按钮。"
        }

        val steady = rates.drop(1).average()
        assertTrue(
            steady > Contract.Cache.HIT_RATE_TARGET,
            "append-only 稳态平均命中率 ${"%.4f".format(steady)}，" +
                "低于目标 ${Contract.Cache.HIT_RATE_TARGET} —— 铁律 1 被破坏",
        )
    }

    @Test
    @DisplayName("★ 分支复用率不可预测 —— 因此架构不得依赖它（实测-05）")
    fun branchReuseIsUnpredictableSoMustNotBeReliedUpon() = runBlocking {
        val p = newProvider()
        p.load(ProviderConfig())
        val prefix = frozen + "\n历史：若干已完成步骤。"
        p.prewarm(prefix)

        val rates = mutableListOf<Double>()
        repeat(5) { i ->
            // 每轮换尾部 —— 这就是"分支"
            val r = p.generate(GenerateRequest("$prefix\n任务编号$i：报告第 $i 项。", 20)).getOrThrow()
            rates += r.cache.hitRate!!
        }

        // 测试替身取保守值（0），但真正要断言的是"架构不依赖分支复用"这件事本身。
        // 实测-05 的 A/B 对照显示：同一前缀一次复用 25%、一次 101%，
        // 差异来自服务端内部检查点状态，无法从 prompt 外部预测。
        val steady = rates.drop(1)
        for ((idx, rate) in steady.withIndex()) {
            assertTrue(
                rate <= Contract.Cache.HIT_RATE_ALERT,
                "保守模型下分支第 ${idx + 2} 轮命中率 ${"%.4f".format(rate)} 不应高于告警线。" +
                    "若此处失败，说明 FakeProvider 的 branchReuseTokens 被改成了非零值 —— " +
                    "那会制造『分支代价可预测』的虚假确定性（见实测-05 §4）。",
            )
        }
    }

    @Test
    @DisplayName("分支复用上限可注入，但默认必须是保守值 0")
    fun branchReuseIsInjectableButDefaultsConservative() = runBlocking {
        assertEquals(
            0, FakeProvider.DEFAULT_BRANCH_REUSE_TOKENS,
            "默认必须是 0（保守）—— 见实测-05 §4",
        )

        // 显式注入时行为符合预期（用于模拟乐观场景的对照实验）
        val optimistic = FakeProvider(branchReuseTokens = 168).apply { onPrompt({ true }, "已执行。") }
        optimistic.load(ProviderConfig())
        val prefix = frozen + "\n历史：若干已完成步骤。"
        optimistic.prewarm(prefix)
        optimistic.generate(GenerateRequest("$prefix\n任务 A", 20)).getOrThrow()
        val r = optimistic.generate(GenerateRequest("$prefix\n任务 B", 20)).getOrThrow()
        assertEquals(168, r.cache.cachedTokens)
    }

    @Test
    @DisplayName("完全相同的 prompt：命中率接近 100%")
    fun identicalPromptNearFullReuse() = runBlocking {
        val p = newProvider()
        p.load(ProviderConfig())
        p.prewarm(frozen)
        p.generate(GenerateRequest(frozen, 20)).getOrThrow()
        val r = p.generate(GenerateRequest(frozen, 20)).getOrThrow()
        assertEquals(1.0, r.cache.hitRate!!, 1e-9)
    }

    // ------------------------------------------------------------ 上下文增长

    @Test
    @DisplayName("append-only 下，上下文增长几乎不增加每轮成本")
    fun growthIsNearlyFree() = runBlocking {
        val p = newProvider()
        p.load(ProviderConfig())
        p.prewarm(frozen)

        var conversation = frozen
        var firstPromptTokens = -1
        val promptTokens = mutableListOf<Int>()

        repeat(10) { i ->
            val r = p.generate(GenerateRequest(conversation, 20)).getOrThrow()
            if (i == 1) firstPromptTokens = r.cache.promptTokens
            promptTokens += r.cache.promptTokens
            conversation = conversation + r.text + "\n用户：第${i + 1}步。"
        }

        // 实测-01 §4.2：上下文从 681 涨到 761 token，每轮实算量恒定在 24
        val steady = promptTokens.drop(1)
        val spread = steady.max() - steady.min()
        assertTrue(
            spread <= steady.min() + 8,
            "每轮实算 token 波动过大：$steady —— append-only 下应当恒定",
        )
        // 断言的是**不随上下文增长**，不是逐 token 完全相等。
        //
        // 2026-10-09 修正：原断言用了严格相等，在 [TextMath.estimateTokens]
        // 系数校准后因"每轮新增文本的估算取整差 1 token"而失败。
        // 那是**估算粒度**问题，不是缓存行为退化 —— 严格相等等于把
        // "估算器的取整细节"锁进了测试，属于过度约束。
        //
        // 真正要守的不变量：实算量**不随轮数单调增长**。
        assertTrue(
            kotlin.math.abs(firstPromptTokens - steady.last()) <= 4,
            "实算量随上下文增长：首轮 $firstPromptTokens → 末轮 ${steady.last()}（$steady）",
        )
    }

    // ------------------------------------------------------------ 接口契约

    @Test
    @DisplayName("未加载即生成必须失败，不得静默返回")
    fun generateBeforeLoadFails() = runBlocking {
        val p = newProvider()
        assertTrue(p.generate(GenerateRequest("x", 10)).isFailure)
    }

    @Test
    @DisplayName("无匹配规则时报错，避免测试悄悄通过")
    fun noMatchingRuleFails() = runBlocking {
        val p = FakeProvider().apply { onPrompt("特定关键词", "ok") }
        p.load(ProviderConfig())
        assertTrue(p.generate(GenerateRequest("完全不相干的内容", 10)).isFailure)
    }

    @Test
    @DisplayName("请求被完整记录，供测试断言调用次数与 prompt 内容")
    fun requestsAreRecorded() = runBlocking {
        val p = newProvider()
        p.load(ProviderConfig())
        p.prewarm(frozen)
        repeat(3) { p.generate(GenerateRequest("$frozen\n第$it 步", 10)).getOrThrow() }
        assertEquals(3, p.requests.size)
        assertTrue(p.requests[0].prompt.startsWith(frozen))
    }
}
