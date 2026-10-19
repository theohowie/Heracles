package dev.heracles.core.provider

import dev.heracles.core.text.TextMath
import dev.heracles.core.tool.NativeToolCall
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/**
 * 可脚本化的假后端 —— `07-开发文档.md` §6.3。
 *
 * 它存在的唯一理由：**让缓存纪律可以在没有手机、没有模型的情况下被回归测试保护。**
 *
 * 本项目的最高风险不是 UI，也不是 JNI，而是"前缀是否逐字节稳定"。
 * 那个东西一旦写错，命中率会从 96.8% 塌到 24.3%（`实测-01` §4），
 * 而每轮多付 15 秒 —— 这种退化必须被单元测试当场拦住，
 * 不能等到推到手机上跑 30 秒才发现。
 *
 * ## 缓存模拟忠实于实测
 *
 * | 场景 | 实测 | 本替身的建模 |
 * |---|---|---|
 * | append-only（新 prompt 完整包含旧 KV） | 90 – 99 %，**稳定可依赖** | 复用 = 旧 KV 全长 |
 * | 新 prompt 完整落在旧 KV 里（重复提问） | 99 %+ | 复用 = 旧 KV 全长 |
 * | 分支（两边都还有剩余） | **25 – 105 %，不可预测**（实测-05） | **保守假设为 0** |
 *
 * 分支取 0 而不是某个"实测中位数"，是刻意的：
 * `实测-05` 证明分支复用率由服务端内部检查点状态决定，同一 prompt 可能 25 % 也可能 101 %。
 * 测试替身若给一个确定的中间值，会制造**虚假的确定性**，
 * 让人误以为"分支的代价可预测" —— 而事实正相反。
 *
 * @param branchReuseTokens 分支时可复用的 token 上限。
 *   默认 0（保守）。如需模拟乐观场景可显式传入，但**生产架构不得依赖非零值**。
 */
class FakeProvider(
    override val id: String = "fake:test",
    private val branchReuseTokens: Int = DEFAULT_BRANCH_REUSE_TOKENS,
) : ModelProvider {

    override val kind: ProviderKind = ProviderKind.LOCAL

    override val capabilities: ProviderCapabilities = ProviderCapabilities(
        supportsGrammar = true,
        supportsJsonSchema = true,
        supportsPrefixCache = true,
        needsPrewarm = true,
    )

    private data class Rule(
        val matcher: (String) -> Boolean,
        val response: String,
        val finishReason: FinishReason,
        /** 流式时每块的字符数 —— 见 [onPrompt] 的 `streamChunkChars` */
        val streamChunkChars: Int,
        /** 流式时先吐出的**思考**增量；默认空（模拟关 thinking） */
        val reasoning: String,
        /**
         * 本轮要回的**原生调用**（ADR-031 step 2）——
         * 零真机下测原生轨的唯一出路（真实后端要 Key + 网络）。
         */
        val nativeCalls: List<NativeToolCall> = emptyList(),
    )

    private val rules = mutableListOf<Rule>()

    /** 上一次成功生成的 prompt，用于模拟 KV 缓存中残留的内容 */
    private var lastPrompt: String? = null

    /** 已记录的生成请求，供测试断言"调用了几次""prompt 长什么样" */
    val requests: MutableList<GenerateRequest> = mutableListOf()

    var prewarmCount: Int = 0
        private set

    var loadCount: Int = 0
        private set

    private var loaded = false

    // ---------------------------------------------------------------- 脚本化

    /** 当 prompt 包含 [contains] 时返回 [respond] */
    fun onPrompt(
        contains: String,
        respond: String,
        finishReason: FinishReason = FinishReason.STOP,
        streamChunkChars: Int = streamChunkSize,
        reasoning: String = "",
        /**
         * 本轮回的原生调用（ADR-031 step 2）。
         *
         * ⚠️ 原生轨的典型形状是 **`respond = ""` + 非空本参数 +
         * `finishReason = TOOL_CALLS`** —— 三样都要显式给，
         * 替身**不替调用方猜**（猜错了就是"测试假绿"）。
         */
        nativeCalls: List<NativeToolCall> = emptyList(),
    ): FakeProvider = apply {
        rules += Rule({ it.contains(contains) }, respond, finishReason, streamChunkChars, reasoning, nativeCalls)
    }

    /** 自定义匹配（用于更复杂的场景） */
    fun onPrompt(
        match: (String) -> Boolean,
        respond: String,
        finishReason: FinishReason = FinishReason.STOP,
        streamChunkChars: Int = streamChunkSize,
        reasoning: String = "",
        nativeCalls: List<NativeToolCall> = emptyList(),
    ): FakeProvider = apply {
        rules += Rule(match, respond, finishReason, streamChunkChars, reasoning, nativeCalls)
    }

    // ------------------------------------------------------------ ModelProvider

    override suspend fun load(config: ProviderConfig): Result<Unit> {
        loadCount++
        loaded = true
        lastPrompt = null
        return Result.success(Unit)
    }

    override suspend fun prewarm(frozenPrefix: String): Result<Unit> {
        require(loaded) { "FakeProvider: 必须先 load() 才能 prewarm()" }
        prewarmCount++
        // 预热在真实后端会建立 KV；这里同步模拟，使后续首轮就能命中
        lastPrompt = frozenPrefix
        return Result.success(Unit)
    }

    override suspend fun generate(request: GenerateRequest): Result<GenerateResult> {
        if (!loaded) return Result.failure(IllegalStateException("FakeProvider: 未 load()"))
        requests += request

        val rule = rules.firstOrNull { it.matcher(request.prompt) }
            ?: return Result.failure(
                IllegalStateException(
                    "FakeProvider: 没有匹配的规则。prompt 前 200 字符：\n" +
                        request.prompt.take(200)
                )
            )

        val cache = simulateCache(request.prompt, rule.response)
        // 真实后端会把本轮 prompt + 生成内容留在 KV 里；下一轮若 append 则命中
        lastPrompt = request.prompt + rule.response

        return Result.success(
            GenerateResult(
                text = rule.response,
                cache = cache,
                finishReason = rule.finishReason,
                toolCalls = rule.nativeCalls,
            )
        )
    }

    /**
     * **流式**替身 —— 按规则的粒度（[Rule.streamChunkChars]）切分后一块块吐出。
     *
     * ## 为什么必须显式覆盖，而不是用接口的默认实现
     *
     * 接口默认实现是"调 `generate()` 再一次性吐全文"。**那样测试是假的**：
     * 它永远测不出"chunk 顺序错乱""思考与正文粘在一起""`done` 块出现两次"
     * 这类缺陷 —— 而那些正是用户看到的"一个字一个字出不来"。
     *
     * ## 顺序：**先思考、后正文**
     *
     * 真实后端（`enable_thinking=true`）就是先吐一串 `reasoning_content`、
     * 再吐 `content`。测试替身必须**照抄这个顺序**，否则
     * "思考块与正文块的分段"这类缺陷测不出来。
     *
     * ## 粒度可配的理由
     *
     * `AgentEventEmissionTest` 断言的是**轮级事件序列**（`ToolStarted` 在
     * `execute` 之前…）。若替身一律逐字符吐，那些断言会被 ~16 倍的
     * token 级事件淹没 —— 它们测的东西本身没错，只是被无关噪声干扰。
     * 所以既能逐字符（验证"逐字"），也能整块（验证轮级语义）。
     */
    override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
        if (!loaded) error("FakeProvider: 未 load()")
        requests += request

        val rule = rules.firstOrNull { it.matcher(request.prompt) }
            ?: error(
                "FakeProvider: 没有匹配的规则。prompt 前 200 字符：\n" +
                    request.prompt.take(200)
            )

        val cache = simulateCache(request.prompt, rule.response)
        // 真实后端会把本轮 prompt + 生成内容留在 KV 里；下一轮若 append 则命中
        lastPrompt = request.prompt + rule.response

        // ① 先吐思考（若该规则配了 reasoning）
        var r = 0
        while (r < rule.reasoning.length) {
            val end = minOf(r + rule.streamChunkChars, rule.reasoning.length)
            emit(StreamChunk.reasoning(rule.reasoning.substring(r, end)))
            r = end
        }

        // ② 再吐正文
        var i = 0
        while (i < rule.response.length) {
            val end = minOf(i + rule.streamChunkChars, rule.response.length)
            emit(StreamChunk.text(rule.response.substring(i, end)))
            i = end
        }

        emit(StreamChunk.done(rule.finishReason, rule.nativeCalls))
        // 记账与 generate() 对齐：缓存指标只在流末对账
        lastStreamCache = cache
    }

    /**
     * 最近一次流式响应的缓存指标。
     *
     * `generate()` 把 [CacheStats] 放在返回值里，而 [StreamChunk] **不含**
     * 缓存字段（它是 token 级增量，硬塞轮级指标是设计错误）。
     * 所以流式路径的记账在这里对账 —— 见 [AgentLoop] 的用法。
     */
    var lastStreamCache: CacheStats = CacheStats.withoutCacheReporting(0, 0)
        private set

    override fun lastStreamCache(): CacheStats = lastStreamCache

    /**
     * **新建规则**的默认每块字符数。
     *
     * 取 1（逐字符）是**刻意的** —— 让"逐字"这件事在测试里可见：
     * 若默认切成大块，"是否真的逐 token"就无法从 chunk 序列上判断。
     *
     * 需要轮级语义干净的测试（如 `AgentEventEmissionTest`）可以显式传大值，
     * 但**默认必须是逐字符**，否则 `StreamChunkTest` 的守卫会失去意义。
     */
    var streamChunkSize: Int = DEFAULT_STREAM_CHUNK_CHARS

    override suspend fun release() {
        loaded = false
        lastPrompt = null
    }

    override fun health(): ProviderHealth =
        ProviderHealth(ready = loaded, detail = if (loaded) "fake ready" else "not loaded")

    // ---------------------------------------------------------------- 内部

    private fun simulateCache(prompt: String, response: String): CacheStats {
        val totalPromptTokens = TextMath.estimateTokens(prompt)
        val previous = lastPrompt

        val cachedTokens: Int = if (previous == null) {
            0
        } else {
            val lcpChars = TextMath.longestCommonPrefixLength(previous, prompt)
            val lcpTokens = TextMath.estimateTokens(prompt.substring(0, lcpChars))

            // 两种情形都能**全额**复用：
            //  a) 新 prompt 完整包含旧 KV（append-only）
            //  b) 新 prompt 本身完整落在旧 KV 里（重复提问 / 前缀查询）
            // 两边都还有剩余才是分支 —— 而分支复用率不可预测（实测-05），故取保守值。
            if (lcpChars >= previous.length || lcpChars >= prompt.length) {
                lcpTokens
            } else {
                minOf(branchReuseTokens, lcpTokens)
            }
        }.coerceIn(0, totalPromptTokens)

        return CacheStats(
            cachedTokens = cachedTokens,
            promptTokens = totalPromptTokens - cachedTokens,
            outputTokens = TextMath.estimateTokens(response),
            prefillMs = CacheStats.UNKNOWN_MS,
            decodeMs = CacheStats.UNKNOWN_MS,
            costUsdMicros = 0,
        )
    }

    companion object {
        /**
         * 分支场景的复用上限默认值 —— **0，即保守假设为完全不复用**。
         *
         * 为什么不是某个"实测中位数"：`实测-05` 证明分支复用率
         * 由服务端内部检查点状态决定，同一前缀可能 25 % 也可能 101 %。
         * 给一个确定值会制造虚假确定性。
         */
        const val DEFAULT_BRANCH_REUSE_TOKENS = 0

        /** 流式替身默认每块字符数 —— 取小让"逐字"在测试里可见 */
        const val DEFAULT_STREAM_CHUNK_CHARS = 1
    }
}
