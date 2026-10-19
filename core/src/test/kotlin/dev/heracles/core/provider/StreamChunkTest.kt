package dev.heracles.core.provider

import dev.heracles.core.tool.NativeToolCall
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * 流式契约的行为守卫 —— `25-流式工作步骤.md` §5.2。
 *
 * 这些测试守的是**用户能不能看到"一个字一个字出来"**这件事本身。
 * 它们**不测** HTTP（那是 `provider-http` 的职责），只测契约语义：
 *
 * | 不变量 | 若破坏，用户看到 |
 * |---|---|
 * | chunk 顺序 = 生成顺序 | 文字乱序 |
 * | 恰好一个 `done` 且在最后 | UI 永远转圈，或提前结束 |
 * | reasoning 与 content **分离** | 思考与答案粘成一坨（用户报的原始缺陷） |
 * | 增量（δ）语义：拼接 = 全文 | 内容重复或丢失 |
 */
class StreamChunkTest {

    private fun provider(respond: String) = FakeProvider().apply {
        onPrompt("hello", respond)
    }

    // ------------------------------------------------------------ 顺序与终止

    /**
     * ★ 核心不变量：chunk **顺序**必须等于生成顺序。
     *
     * 顺序错乱在"一次性返回"的实现里根本不会出现 ——
     * 这也正是为什么必须显式覆盖接口的默认实现来测（默认实现只会吐 1 个块）。
     */
    @Test
    fun `chunk 顺序等于生成顺序`() = runBlocking {
        val text = "一二三四五"
        val p = provider(text)
        p.load(ProviderConfig())

        val chunks = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 64)).toList()

        // 最后一个是 done，其余是内容块
        val content = chunks.filter { !it.done }
        assertEquals(
            text,
            content.joinToString("") { it.deltaText },
            "把所有增量按顺序拼接必须等于原文 —— 顺序错了这里就会挂",
        )
    }

    @Test
    fun `恰好一个 done 块且位于最后`() = runBlocking {
        val p = provider("abcdef")
        p.load(ProviderConfig())

        val chunks = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 64)).toList()

        assertEquals(1, chunks.count { it.done }, "一次流式响应必须【恰好】产出一个 done 块")
        assertTrue(chunks.last().done, "done 块必须在最后，否则 UI 会提前收尾")
    }

    @Test
    fun `done 块携带 finishReason 且不含内容`() = runBlocking {
        val p = provider("abc")
        p.load(ProviderConfig())

        val chunks = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 64)).toList()

        val done = chunks.last()
        assertEquals(FinishReason.STOP, done.finishReason)
        assertFalse(done.hasPayload, "done 块不得夹带内容 —— 否则调用方会把内容算两遍")
    }

    @Test
    fun `非终止块不带 finishReason`() = runBlocking {
        val p = provider("abcd")
        p.load(ProviderConfig())

        val chunks = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 64)).toList()

        chunks.filter { !it.done }.forEach {
            assertNull(it.finishReason, "只有 done 块可以有 finishReason")
        }
    }

    /**
     * ★ "逐字"这件事必须是**可观测**的。
     *
     * 若实现偷偷攒成一大块再吐，用户看到的还是"等想完了再全部展示" ——
     * 那正是用户批评的原始现象。所以这里断言块数 = 字符数。
     */
    @Test
    fun `默认逐字符产出而不是一次吐完`() = runBlocking {
        val text = "思考一下这个问题"
        val p = provider(text)
        p.load(ProviderConfig())

        val chunks = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 64)).toList()

        assertEquals(
            text.length,
            chunks.count { !it.done },
            "每块应当只有 1 个字符 —— 块数等于字符数才叫逐字",
        )
        assertTrue(chunks.size > 2, "至少要有多块，否则就不是流式")
    }

    // ------------------------------------------------------------ 思考与正文分离

    /**
     * ★★★ 用户最在意的一条：**思考与正文必须是两个通道**。
     *
     * `25` §2 错误一就是"把思考当成正文/粘在一起"。分离是 UI 能
     * 把思考渲染成"过程"、把 content 渲染成"答案"的**前提**。
     */
    @Test
    fun `reasoning 与 text 分离不合并`() {
        val chunk = StreamChunk(deltaText = "答案", deltaReasoning = "思考")
        assertEquals("答案", chunk.deltaText)
        assertEquals("思考", chunk.deltaReasoning)
        assertTrue(chunk.hasPayload)
    }

    @Test
    fun `只有思考的块其正文为空`() {
        val chunk = StreamChunk.reasoning("我需要先看看文件")
        assertTrue(chunk.deltaText.isEmpty(), "思考块不得污染正文通道")
        assertEquals("我需要先看看文件", chunk.deltaReasoning)
        assertTrue(chunk.hasPayload, "只有思考也算有内容，不能被当成心跳丢弃")
    }

    @Test
    fun `只有正文的块其思考为空`() {
        val chunk = StreamChunk.text("好的")
        assertTrue(chunk.deltaReasoning.isEmpty())
        assertFalse(chunk.done)
    }

    @Test
    fun `空块被判定为无内容`() {
        // 心跳块（例如只有 role）必须能被识别并丢弃，否则 UI 会渲染空行
        assertFalse(StreamChunk().hasPayload)
        assertFalse(StreamChunk(deltaText = "", deltaReasoning = "").hasPayload)
    }

    @Test
    fun `done 工厂方法语义正确`() {
        val d = StreamChunk.done(FinishReason.LENGTH)
        assertTrue(d.done)
        assertEquals(FinishReason.LENGTH, d.finishReason)
        assertFalse(d.hasPayload)
    }

    // ------------------------------------------------- 原生调用（ADR-031 step 2）

    /**
     * ★★ 终止块是**原生调用唯一的落脚点**。
     *
     * `AgentLoop` 是"看到 `done` 即收流"，所以调用必须与终止块**同块**到达；
     * 分两块的话调用会被静默漏掉 —— 那正是"模型要调工具却什么都没发生"。
     */
    @Test
    fun `终止块携带拼装完成的原生调用`() {
        val call = NativeToolCall("call_1", "write_file", """{"path":"a.txt"}""")
        val d = StreamChunk.done(FinishReason.TOOL_CALLS, listOf(call))

        assertTrue(d.done)
        assertEquals(FinishReason.TOOL_CALLS, d.finishReason)
        assertEquals(listOf(call), d.toolCalls)
        assertTrue(d.hasToolCalls, "带调用的终止块必须能被识别")
    }

    /**
     * ★ 调用**不是**内容增量 —— 别把它算进 [StreamChunk.hasPayload]。
     *
     * 那个字段的语义是"要不要当成心跳丢掉"，而调用是终止块上的**整体载荷**；
     * 混进来会让"done 块不得夹带内容"这条既有约定失效（上面那条测试就红了）。
     */
    @Test
    fun `原生调用不计入内容增量`() {
        val d = StreamChunk.done(FinishReason.TOOL_CALLS, listOf(NativeToolCall("c", "t", "{}")))
        assertFalse(d.hasPayload, "调用不是δ，不得算作内容增量")
        assertTrue(d.hasToolCalls)

        // 普通块默认没有调用（既有行为不变）
        assertFalse(StreamChunk.text("x").hasToolCalls)
        assertFalse(StreamChunk.done(FinishReason.STOP).hasToolCalls)
    }

    // ------------------------------------------------------------ 增量语义

    /**
     * 契约是**增量（δ）**而不是"累积快照"。
     *
     * 快照式的负载会随输出线性增长（逐 token 推送 = O(n²) 拷贝）。
     * 这条测试把"拼接 = 全文"这个等式钉死在契约层。
     */
    @Test
    fun `增量拼接等于全文`() = runBlocking {
        val text = "我需要先查看一下这个文件的内容，然后决定怎么改。"
        val p = provider(text)
        p.load(ProviderConfig())

        val chunks = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 128)).toList()

        val joined = chunks.filter { !it.done }.joinToString("") { it.deltaText }
        assertEquals(text, joined)
        // 每个块都必须是【部分】，不能有任何一块等于全文
        assertTrue(
            chunks.filter { !it.done }.all { it.deltaText.length < text.length },
            "任何单个块都不该是全文 —— 否则就是攒完再吐",
        )
    }

    @Test
    fun `空响应只产出 done 块`() = runBlocking {
        val p = provider("")
        p.load(ProviderConfig())

        val chunks = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 16)).toList()

        assertEquals(1, chunks.size, "空响应不该产出内容块")
        assertTrue(chunks[0].done)
    }

    // ------------------------------------------------------------ 与既有契约的兼容

    /**
     * 接口的**默认实现**把老 provider 优雅降级为"一次性吐全文"。
     *
     * 这是刻意的（ADR-016：优先新增而非修改）：接口加方法不得强迫
     * 无关实现全部改一遍。但**真实后端不得依赖它** —— 依赖它等于没做流式。
     */
    @Test
    fun `默认实现退化为一次性吐全文`() = runBlocking {
        // 一个只实现 generate() 的最小 provider —— 不覆盖 generateStream
        val legacy = object : ModelProvider {
            override val id = "legacy:test"
            override val kind = ProviderKind.LOCAL
            override val capabilities = ProviderCapabilities(
                supportsGrammar = false,
                supportsJsonSchema = false,
                supportsPrefixCache = false,
                needsPrewarm = false,
            )

            override suspend fun load(config: ProviderConfig) = Result.success(Unit)
            override suspend fun prewarm(frozenPrefix: String) = Result.success(Unit)
            override suspend fun generate(request: GenerateRequest) = Result.success(
                GenerateResult("全文", CacheStats.withoutCacheReporting(1, 1), FinishReason.STOP)
            )

            override suspend fun release() = Unit
            override fun health() = ProviderHealth(true, "ok")
        }

        val chunks = legacy.generateStream(GenerateRequest(prompt = "x", maxOutputTokens = 8)).toList()

        assertEquals(2, chunks.size, "默认实现：1 个内容块 + 1 个 done 块")
        assertEquals("全文", chunks[0].deltaText)
        assertTrue(chunks[1].done)
    }

    /**
     * ★ 回归锁：`FakeProvider` **必须**覆盖默认实现。
     *
     * 若哪天有人删掉 `FakeProvider.generateStream()`，它会静默退化成
     * "一次性吐全文"，而 `AgentLoop`/UI 的所有流式测试仍然会 PASS
     * —— 但用户看到的东西又变回"等想完了再全部展示"。
     *
     * 这条测试就是拦这个的：它断言**块数与字符数相等**。
     */
    @Test
    fun `FakeProvider 必须真的流式而不是退化为默认实现`() = runBlocking {
        val text = "0123456789"
        val p = provider(text)
        p.load(ProviderConfig())

        val chunks = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 64)).toList()

        assertTrue(
            chunks.size >= text.length,
            "FakeProvider 必须显式实现流式；若退化为默认实现，块数会是 2 —— 那会让所有流式测试变成假绿",
        )
    }

    @Test
    fun `FakeProvider 流式与 generate 的文本一致`() = runBlocking {
        val text = "一致性与否"
        val p = provider(text)
        p.load(ProviderConfig())

        val streamed = p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 64))
            .toList().filter { !it.done }.joinToString("") { it.deltaText }

        assertNotNull(streamed)
        assertEquals(text, streamed, "流式与一次性两条路径必须产出同一份文本")
    }

    @Test
    fun `未 load 时 FakeProvider 流式失败`() = runBlocking {
        val p = provider("abc")
        var thrown: Throwable? = null
        try {
            p.generateStream(GenerateRequest(prompt = "hello", maxOutputTokens = 8)).toList()
        } catch (t: Throwable) {
            thrown = t
        }
        assertNotNull(thrown, "未 load 就必须失败，而不是产出空流让 UI 空转")
    }

    @Test
    fun `没有匹配规则时流式失败`() = runBlocking {
        val p = provider("abc")
        p.load(ProviderConfig())
        var thrown: Throwable? = null
        try {
            p.generateStream(GenerateRequest(prompt = "不匹配的输入", maxOutputTokens = 8)).toList()
        } catch (t: Throwable) {
            thrown = t
        }
        assertNotNull(thrown)
    }
}
