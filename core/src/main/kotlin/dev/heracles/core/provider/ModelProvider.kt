package dev.heracles.core.provider

import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolSpec
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

/** 后端类型。UI 必须据此显示隐私指示（FR-11.9）。 */
enum class ProviderKind {
    /**
     * 跑在本机，数据不出设备。
     *
     * ⚠️ **已无真实 provider 使用**（ADR-035 S3，2026-10-18 删除 `LlamaServerProvider`）。
     * 值**刻意保留**：`FakeProvider` 与测试用它表达"本地/无网络"语义，UI 的隐私指示也按它分叉。
     * **不要**为它恢复任何真实实现 —— 本地后端已从产品里退场。
     */
    LOCAL,

    /** 远程 API，屏幕内容会离开设备 */
    CLOUD,
}

/**
 * provider 实际具备的能力。
 *
 * **必须由"测试连接"探测得出并记录**（`06-UI界面设计.md` §6.4），
 * 不得照抄文档 —— 各兼容实现的支持度差异很大。
 * 该结构直接决定 `02-契约规范.md` §5.2 的能力映射能否生效。
 */
data class ProviderCapabilities(
    /** 是否支持 GBNF 语法约束（llama.cpp 支持；云端一般不支持） */
    val supportsGrammar: Boolean,
    /** 是否支持 JSON Schema 约束 */
    val supportsJsonSchema: Boolean,
    /** 是否支持前缀缓存（决定省时间 / 省钱的程度） */
    val supportsPrefixCache: Boolean,
    /** 是否需要预热（本地 true，云端 false） */
    val needsPrewarm: Boolean,
    /**
     * 前缀缓存的**粒度**（token）。
     *
     * - **1** = token 级精确复用（llama.cpp）
     * - **1024** = 块级，命中数恒为块大小的整数倍（DashScope，`实测-07`）
     *
     * **这个值决定冻结区要不要补齐**（[dev.heracles.core.context.PrefixAligner]）：
     * 块级 provider 下，长度不足一块的冻结区**命中率为 0**
     * （实测踩过：513 token → 5 轮全 0.0%）。
     *
     * 未知时填 1（保守：不补齐，行为与本地一致）。
     */
    val cacheBlockTokens: Int = 1,

    /**
     * 后端**是否支持原生的工具调用接口**（请求侧带 `tools` 数组）——
     * ADR-031 决策 2。
     *
     * ## 这是一个**声明**，不是开关（2026-10-18，F7b）
     *
     * `true` 只说"这个后端的 API 有能力收 `tools` 并按自己的训练方式回 `tool_calls`"：
     * - **云端**（OpenAI 兼容 / Anthropic / Responses）⇒ `true`
     * - **本地**（llama.cpp）⇒ `false`（只有 GBNF 文本协议；4B 也没有原生工具训练）
     *
     * **"有能力" ≠ "已经在用"**。是否真的把 `tools` 发出去，由装配方显式决定
     * （`AgentLoop(nativeToolsEnabled = …)`）—— 因为**响应侧还没解析 `tool_calls`**
     * 时把 `tools` 发出去，等于把"输出方言解析失败"换成"模型走原生通道、
     * 正文为空"：今天只是熔断，那样是**更难查的静默失败**。
     * 所以 ADR-031 的第 2 步（解析并入同一条执行路径）落地前，这个位**不得**被当作"已启用"。
     *
     * 默认 `false`：既有实现不改也安全（本地路径零回退的**结构性**保证之一，
     * 而不是靠调用方自觉）。
     */
    val supportsNativeTools: Boolean = false,
)

/** provider 配置。本地与云端共用，各自只读自己需要的字段。 */
data class ProviderConfig(
    // --- 本地 ---
    val modelPath: String? = null,
    val contextSize: Int = Contract.Context.DEFAULT_CTX,
    val threads: Int = Contract.Inference.DEFAULT_THREADS,
    // --- 云端 ---
    val baseUrl: String? = null,
    val apiKey: String? = null,
    val modelName: String? = null,
)

/** 结构化输出的约束强度 —— `02-契约规范.md` §6 */
sealed interface StructuredSpec {
    /** 任意合法 JSON（工具调用参数） */
    data object Json : StructuredSpec

    /** GBNF 语法（llama.cpp 强约束；云端需降级） */
    data class Grammar(val gbnf: String) : StructuredSpec

    /** JSON Schema（云端） */
    data class JsonSchema(val schemaJson: String) : StructuredSpec
}

/**
 * 统一的生成请求。
 *
 * **注意**：这里刻意不包含 `temperature` / `enable_thinking` / `cache_prompt` / `id_slot`。
 * 这些由 provider 实现内部按契约注入（`02-契约规范.md` §5.2），
 * 调用方不需要、也不允许自己设置 —— 否则铁律 3 会被悄悄绕过。
 */
data class GenerateRequest(
    val prompt: String,
    val maxOutputTokens: Int,
    val structuredOutput: StructuredSpec? = null,
    /** true → provider 必须使用 temperature=0 等确定性参数 */
    val deterministic: Boolean = true,
    /**
     * 对话消息（云端 `/chat/completions` 用）。
     *
     * **默认 `null` 是刻意的后端中立**（ADR-016 规则：优先新增而非修改）：
     * - **本地后端**（`/completion`）：`null` → 用 [prompt]，并**忽略**本字段
     * - **云端后端**（`/chat/completions`）：非空 → 用消息；
     *   若为 `null` 则退化为单条 user 消息
     *
     * 这样同一次请求可以同时携带两种形态，各后端只读自己需要的那一份，
     * 上层不需要判断"当前是哪个后端"。
     */
    val messages: List<ChatMessage>? = null,
    /**
     * 推理档位 —— **provider 无关**的意图表达（`25-流式工作步骤.md` §10.3）。
     *
     * **刻意不是 `enable_thinking` / `reasoning_effort`**：
     * 那两个是**专有字段**，泄漏到这一层会违反 `AGENTS.md` 的
     * 「provider 专有字段不得泄漏到 `ModelProvider` 之上」。
     * 各 provider 自己把它映射成自己后端的参数。
     *
     * 默认 [ReasoningLevel.AUTO]：由实现决定。
     * **注意**：`AUTO` 在本地实现里退化为"关思考"（省时间），
     * 只有需要思考流式展示时才由用户显式调到 `LOW` 及以上。
     */
    val reasoning: ReasoningLevel = ReasoningLevel.AUTO,
    /**
     * 要作为**原生 `tools` 数组**发出去的工具声明（ADR-031 决策 2 的请求侧）。
     *
     * ## 为什么放在这里（后端中立）
     *
     * 它是**工具声明**，不是任何一家的专有字段：`ToolSpec` 本身就在 `:core`。
     * provider 只读这个字段、不自己判断后端；调用方只填声明、不管形状
     * （形状由各 provider 映射，见 `NativeToolSchema`）。
     * 空列表 = **今天的行为**（不向请求体里加任何东西）⇒ 既有后端逐字节不变。
     *
     * ## 三条纪律
     *
     * 1. **只装常驻工具**，不要装长尾/披露工具：披露会让数组**变长** ⇒
     *    前缀每披露一次抖一次、缓存全塌。披露机制与原生数组**天然冲突**
     *    （ADR-023 / 门禁 G13 把长尾挡在冻结区之外，这里是同一个理由）。
     * 2. **顺序由调用方给定且必须稳定**：同一个工具集两次构造必须逐字节相同，
     *    否则前缀缓存每轮 miss。
     * 3. **不支持的原后端必须忽略它**（本地 `LlamaServerProvider` 完全不读）——
     *    "零回退"是结构性的，不是靠调用方不发。
     *
     * ## 流式（ADR-031 step 2 的坑，先写死契约免得写成拼不起来）
     *
     * `tool_calls` 在流式里是**分片**到达的，且**任一单片都不是合法 JSON**：
     * 必须按各家的事件契约拼完再 `parse`（OpenAI 按 `delta.tool_calls[].index` 归并、
     * `arguments` 逐片字符串拼接；Anthropic 按 content block 序号 + `input_json_delta`；
     * Responses 用 `response.function_call_arguments.delta`，以 `output_item.done` 为准）。
     * thinking/reasoning 增量**绝不**并入 `arguments`。
     * 详见 `NativeToolSchema` 的文件头。
     */
    val tools: List<ToolSpec> = emptyList(),

    /**
     * **图片输入**（2026-10-19，多模态）—— 元素是 **data URL**
     * （`data:image/png;base64,....`）。
     *
     * ## 为什么用 data URL 而不是字节/路径
     *
     * data URL 是**后端中立**的：OpenAI 兼容端点直接吃 `image_url.url`；
     * Anthropic 需要拆成 `media_type` + base64 —— 由它自己从 data URL 拆。
     * 路径不行：`ModelProvider` 不该假设"图片在本地磁盘上"（将来可能是内容 URI/网络图）。
     *
     * ## 空列表 = 纯文本
     *
     * 默认空 ⇒ **请求体逐字节不变**（既有测试、缓存前缀、非多模态端点全不受影响）。
     * 不支持读图的后端**必须显式失败**，不能静默丢图 —— 静默丢图 = 模型假装看不见却继续答。
     */
    val images: List<String> = emptyList(),
)

enum class FinishReason {
    STOP,
    LENGTH,
    TOOL_CALLS,
    ERROR,
}

data class GenerateResult(
    val text: String,
    val cache: CacheStats,
    val finishReason: FinishReason,
    /**
     * 本轮模型通过**原生 function calling** 请求的调用（ADR-031 step 2）。
     *
     * 默认空列表 = **纯文本轨**（今天的行为）⇒ 既有实现的调用点零改动。
     *
     * ## 三条纪律
     *
     * 1. **全都要给**：收到几个就给几个 —— 由上层按
     *    `Contract.Tools.MAX_NATIVE_CALLS_PER_TURN` 决定口径并**如实报告**，
     *    provider 不许"只留第一个然后把剩下的丢掉"（那会让模型以为它调了全部）。
     * 2. **`arguments` 保持原文**：不解析、不归一化（见 [NativeToolCall]）。
     * 3. **空 `text` + 非空本字段是正常的**（原生轨的典型形状），
     *    上层**不得**把它当成"输出为空"的错误。
     */
    val toolCalls: List<NativeToolCall> = emptyList(),
)

data class ProviderHealth(
    val ready: Boolean,
    val detail: String = "",
)

/**
 * 模型后端统一接口 —— `07-开发文档.md` §5.1（FR-11.1）。
 *
 * 上层代码**只**依赖本接口，不知道背后是手机上的 4B 还是云端的千亿模型。
 *
 * 实现清单：
 *  - [FakeProvider]          测试用（本模块）
 *  - LlamaServerProvider     `:provider-http`，llama.cpp `/completion`（开发期）
 *  - OpenAiCompatProvider    `:provider-http`，云端 `/chat/completions`（发行版）
 *  - LocalLlamaProvider      `:inference`，JNI 内嵌 llama.cpp（阶段二可选）
 */
interface ModelProvider {
    /** 稳定标识，例如 `local:qwen3.5-4b` / `openai:deepseek-chat` */
    val id: String

    val kind: ProviderKind

    val capabilities: ProviderCapabilities

    /** 加载 / 建立连接 */
    suspend fun load(config: ProviderConfig): Result<Unit>

    /**
     * 预热冻结前缀 —— **铁律 2**。
     *
     * 不做预热的后果：首轮实测 26.7 s（`实测-01` §4.2）。
     * 云端 provider 应实现为空操作（无冷启动概念），但接口保留以统一生命周期。
     */
    suspend fun prewarm(frozenPrefix: String): Result<Unit>

    suspend fun generate(request: GenerateRequest): Result<GenerateResult>

    /**
     * **流式**生成 —— 逐 token 产出增量（`25-流式工作步骤.md` §5.2）。
     *
     * `generate()` 是"等想完了再全部展示"（粒度 = 一轮），
     * 本方法是"一个字一个字出来"（粒度 = 一个 token）。
     * **用户要的是后者**；`generate()` 保留给 CLI 与既有测试，不要删。
     *
     * ## 契约
     *
     * - 产出 **0..n 个内容块 + 恰好 1 个 `done` 块**（见 [StreamChunk]）
     * - `deltaReasoning` 与 `deltaText` **分离**，不得合并
     * - 出错时**以异常终止** Flow（不产出 `done`），与 `generate()` 的 `Result.failure` 语义对应
     * - 取消（下游 `collect` 被 cancel）时实现**必须关闭 HTTP 连接**，否则连接池泄漏
     *
     * ## 默认实现（刻意提供）
     *
     * 默认退化为**非流式**：调 [generate] 后一次性吐出全文。
     * 这样既有实现（测试替身、未来的 JNI provider）**不改也能编译**，
     * 不会因为接口新增方法而被迫改一堆无关代码（ADR-016 规则：优先新增而非修改）。
     *
     * ⚠️ 但**真实后端不得依赖这个默认实现** —— 那就等于没做流式。
     * [LlamaServerProvider] / [OpenAiCompatProvider] 均显式覆盖。
     */
    fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
        val result = generate(request).getOrThrow()
        if (result.text.isNotEmpty()) emit(StreamChunk.text(result.text))
        // ★ 原生调用必须跟着终止块一起走 —— 否则用默认实现的 provider
        //   （测试替身 / 未来的 JNI provider）会**静默丢掉**原生调用。
        if (result.toolCalls.isEmpty()) {
            emit(StreamChunk.done(result.finishReason))
        } else {
            emit(StreamChunk.done(result.finishReason, result.toolCalls))
        }
    }

    /**
     * 最近一次 [generateStream] 的缓存记账。
     *
     * ## 为什么流式需要**单独**一个入口
     *
     * [generate] 把 [CacheStats] 放在**返回值**里，调用方顺手就拿到了。
     * 但 [StreamChunk] **刻意不含**缓存字段 —— 它是 token 级增量，
     * 而缓存是**轮级**指标。给每个增量都挂一份轮级统计是设计错误
     * （负载无谓放大，且语义混乱：一个 token 怎么会"命中 1024 token"？）。
     *
     * ⇒ 流式路径的记账改由**流结束后**从这里对账。
     *
     * ## 契约
     *
     * - **流结束后**调用才有意义（`collect` 正常返回之后）
     * - 未上报时返回 [CacheStats.withoutCacheReporting]，
     *   **不得**填 0 —— 0 与"未上报"语义不同（`02-契约规范.md` §3.4）
     * - 默认实现返回"未上报"，这样既有实现不改也安全
     */
    fun lastStreamCache(): CacheStats = CacheStats.withoutCacheReporting(0, 0)

    /** 释放资源（本地卸载权重；云端断开连接） */
    suspend fun release()

    fun health(): ProviderHealth
}

/**
 * **provider 调用失败**的 provider 无关类型（2026-10-19 新增）。
 *
 * ## 为什么需要它（而不是让上层去认 HTTP 异常）
 *
 * `:agent` **不依赖** `:provider-http`（分层纪律：provider 只能通过
 * [ModelProvider] 接口被看见）。但"429 / 5xx 该退避重试、401 不该"
 * 这条语义**必须能被循环层消费** —— 否则它只是一句注释。
 *
 * 于是把"失败 + 是否可重试"提到 `:core` 的 provider 契约里：
 * 各 provider（OpenAI 兼容 / Anthropic / Responses）把自家 HTTP 异常
 * 翻译成这个类型；[dev.heracles.agent.AgentLoop] 只认 [retryable]。
 *
 * ⚠️ **只对"还没开始吐内容"的失败重试**：流式中途断开的请求可能已经计费、
 * 且重放会重复执行 —— 那是调用方（循环层）的判断，不是本类型的事。
 */
open class ProviderCallException(
    message: String,
    /** `true` = 换一次请求可能就好了（429 / 5xx / 连接被重置）；`false` = 参数/鉴权问题，重试只会更糟 */
    val retryable: Boolean,
    cause: Throwable? = null,
) : RuntimeException(message, cause)
