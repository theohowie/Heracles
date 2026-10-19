package dev.heracles.agent

import dev.heracles.core.provider.CacheStats
import dev.heracles.core.tool.ToolCall
import dev.heracles.core.tool.ToolValidator

/**
 * 单轮记录 —— 供记账（FR-10.5）与 UI 展示（`06-UI界面设计.md` §5）。
 *
 * **每一轮都留痕**，而不只是汇总。原因是 `实测-05` 的教训：
 * 缓存行为不可假设，只能记账观测。
 */
data class TurnRecord(
    val index: Int,
    val userText: String,
    /** 模型输出的原始文本 */
    val rawOutput: String,
    /** 解析出的工具调用（若本轮没有工具调用则为 null） */
    val toolCall: ToolCall?,
    /** 工具执行结果（若未执行则为 null） */
    val toolResult: String?,
    val verdict: String,
    val cache: CacheStats,
    val wallMs: Long,
    /**
     * 工具**是否真的执行成功**；`null` = 本轮没有执行过工具。
     *
     * ## 为什么新增这个字段（2026-10-10 修复 H-1）
     *
     * 工具的状态本来只有三种：**成功 / 失败 / 被拦截（从未执行）**。
     * 但下游原先只靠 `verdict` 里的中文字符串猜（`!verdict.contains("失败")`），
     * 而拦截类的 verdict（"重复调用已拦截…"、"★ 检测到循环，强制停止"）
     * **都不含「失败」** → 被落盘成 `ok: true` → UI 画出**绿色成功卡**。
     *
     * 那是比"失败"更糟的**假信息**：用户会以为文件真的被改了。
     *
     * 靠字符串匹配判定状态本身就是脆弱的（改一个字就失效），
     * 所以这里给出**结构化**的依据。
     *
     * 默认 `null` ⇒ **既有 12 处 `TurnRecord(...)` 调用一字不改**（纯增量）：
     * 拦截类分支天然留 null（它们不执行任何东西），只有真正执行的那一处
     * 显式传入结果。
     */
    val toolSucceeded: Boolean? = null,
) {
    /**
     * 这一轮**请求了工具、但没有执行它**（架构层拦截）。
     *
     * 触发拦截的三条分支（重复调用 / 循环硬停 / 校验失败）都
     * `toolCall != null` 且 `toolSucceeded == null` —— 因为**工具根本没跑**。
     *
     * 说人话：**没有执行结果 = 没执行过**。
     */
    val toolBlocked: Boolean get() = toolCall != null && toolSucceeded == null

    /** 工具在本轮的**三态**状态（唯一权威来源，不要在别处再猜）。 */
    val toolState: ToolState
        get() = when {
            toolCall == null -> ToolState.notRequested
            toolSucceeded == null -> ToolState.blocked
            toolSucceeded == true -> ToolState.succeeded
            else -> ToolState.failed
        }

    /** 一行摘要，供 CLI 表格展示 */
    fun render(): String {
        val hit = cache.hitRate?.let { "%.1f%%".format(it * 100) } ?: "n/a"
        return String.format(
            "%-4d %-9s %-6s %-5s %7sms  %s",
            index,
            cache.cachedTokens?.toString() ?: "-",
            cache.promptTokens,
            hit,
            wallMs,
            toolCall?.let { "${it.tool}(${it.args.entries.joinToString(",") { "${it.key}=${it.value}" }})" }
                ?: verdict,
        )
    }
}

/**
 * 工具在一轮里的**三态**。
 *
 * **被拦截不等于失败** —— 这是本模块最容易搞错的一点，
 * 也是 H-1 的根源。被拦截意味着"我们**主动没执行**"（循环/重复/校验不过），
 * 它既不是成功也不是失败，画成任何一个都是在骗用户。
 */
enum class ToolState {
    /** 本轮没有请求工具（例如最终回答那一轮） */
    notRequested,

    /** 执行了，成功 */
    succeeded,

    /** 执行了，失败（工具自身报的错） */
    failed,

    /** **请求了但从未执行** —— 架构层拦截 */
    blocked,
}

/** 一次 agent 运行的完整结果 */
data class AgentRunResult(
    val turns: List<TurnRecord>,
    val finalText: String,
    val stopReason: String,
) {
    val totalCachedTokens: Int get() = turns.sumOf { it.cache.cachedTokens ?: 0 }
    val totalPromptTokens: Int get() = turns.sumOf { it.cache.promptTokens }
    val totalOutputTokens: Int get() = turns.sumOf { it.cache.outputTokens }

    /**
     * 稳态命中率 —— **轮次平均**（跳过第一轮；冷启动必然未命中）。
     *
     * ⚠️ 这个数**系统性偏乐观**：它把"吃 6000 token 的大轮"与"只加 300 token 的小轮"
     * **等权**看待。2026-10-19 的云端实测（`docs/实测-L1缓存复测-2026-10-19.md`）：
     * 轮次平均 **90.8%**，而同样的样本按 token 加权只有 **84.6%** —— 差 6.2 个百分点，
     * 因为低命中的正是 prompt 最大的那几轮（首轮冻结前缀、压缩后重建）。
     * ⇒ 报指标时必须**两个一起报**，看成本请用 [steadyWeightedHitRate]。
     */
    val steadyHitRate: Double?
        get() {
            val steady = turns.drop(1).mapNotNull { it.cache.hitRate }
            return if (steady.isEmpty()) null else steady.average()
        }

    /**
     * 稳态命中率 —— **token 加权**（`Σcached / Σ(cached+prompt)`，跳过第一轮）。
     *
     * 这才是**对应真实账单**的口径：一个 6000-token 的 miss 远比一个 300-token 的 hit 贵。
     * 与 [steadyHitRate] 一起展示，避免"轮次平均好看、实际很贵"的错觉。
     */
    val steadyWeightedHitRate: Double?
        get() {
            val steady = turns.drop(1).filter { it.cache.cacheReportingAvailable }
            val cached = steady.sumOf { it.cache.cachedTokens ?: 0 }
            val prompt = steady.sumOf { it.cache.promptTokens }
            val total = cached + prompt
            return if (total > 0) cached.toDouble() / total else null
        }
}

/** 工具执行结果 */
sealed interface ToolOutcome {

    /**
     * **"这次调用成功了吗"的唯一判据**（2026-10-19）。
     *
     * 为什么要有它：`SuccessWithImage` 上线后，散落各处的
     * `outcome is ToolOutcome.Success` 把它判成**失败** —— 真机上表现为
     * `view_image` 明明把图片送出去了，UI 却画红色失败卡、会话记 `ok:false`。
     * ⇒ 把所有"成功与否"的判断收敛到这一个属性，新增成功变体时只改这里。
     *
     * ⚠️ 源码扫描门禁（`ToolOutcomeContractTest`）禁止生产代码用 `x is ToolOutcome.Success`
     * 判断成功；它按**整段 getter 定义体**识别本属性，单行/折行/大括号三种写法都放行
     * ⇒ 这里的换行**不是**产品约束（早先按"必须同一行"实现过，已放宽）。
     */
    val isSuccess: Boolean get() = this is Success || this is SuccessWithImage

    data class Success(val detail: String) : ToolOutcome

    /**
     * 成功，**并且**这次调用的产物是一张图片（2026-10-19，`view_image`）。
     *
     * 为什么单独一个变体：图片不能塞进文本结果 —— 它要随**下一次请求**
     * 作为多模态输入发出去（`GenerateRequest.images`）。`AgentLoop` 看到这个变体会
     * 把 [imageDataUrl] 加进本 run 的图片列表，之后每轮都带上（模型"记得"看过）。
     */
    data class SuccessWithImage(val detail: String, val imageDataUrl: String) : ToolOutcome

    data class Failure(val reason: String) : ToolOutcome
    /** 需要用户确认（阶段二的权限三档会用上，见 `00-需求文档.md` §2.13.2） */
    data class NeedsApproval(val detail: String) : ToolOutcome
}

/** 一个可被 agent 调用的工具 */
interface AgentTool {
    val spec: dev.heracles.core.tool.ToolSpec

    /** 执行。**实现必须自行做路径/参数防护**，不得假设入参安全。 */
    suspend fun execute(args: Map<String, String>): ToolOutcome

    /**
     * **能否与同批次的其他调用真正并发执行**（2026-10-19）。
     *
     * ## 为什么默认 `false`（保守）
     *
     * 并发执行会引入**竞态**：两个 `write_file` 同时写同一文件、`delete_path` 与
     * `read_file` 交错 …… 这些错误的症状是"偶发的数据错乱"，**极难复现**。
     * 所以默认**串行**，只有明确安全的工具才打开 —— 宁可慢，不可错。
     *
     * ## 什么时候可以是 true
     *
     * · **纯读**工具（`read_file` / `list_files` / `find_files` / `grep_files` /
     *   `view_image` / `web_fetch`）—— 不产生副作用，并发没有正确性问题
     * · 注意 `web_fetch` 虽是网络 IO（并发收益最大），但它**有 SSRF 与限流**考量：
     *   本批次最多 `Contract.Tools.MAX_NATIVE_CALLS_PER_TURN`(=4) 个，量级可控，所以允许。
     *
     * ## 实现要求
     *
     * 声明 `true` 的工具**必须**：不共享可变状态、不改文件系统、不改设备。
     * 装配处（`AndroidTools.progressReporting` 等装饰器）**必须**把这个值透传出去 ——
     * 装饰器吞掉它会让"本来安全的工具白等"（性能问题）或"不安全工具被当安全"（正确性问题）。
     */
    val parallelSafe: Boolean get() = false
}

/** 校验 [ToolCall] 是否可执行；把 [ToolValidator] 的结论翻译成人类可读文本。 */
internal fun describeValidation(call: ToolCall, specs: List<dev.heracles.core.tool.ToolSpec>): String? =
    when (val r = ToolValidator.validate(call, specs)) {
        is ToolValidator.Result.Valid -> null
        is ToolValidator.Result.Invalid -> r.detail
    }
