package dev.heracles.cloud.tool

import dev.heracles.cloud.context.CloudToolCall
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * **原生工具执行器**（`CloudAgentPipeline`，模块一）。
 *
 * ## 它替代了什么
 *
 * 旧 `AgentLoop` 里的执行路径混着文本轨的包袱：
 * - `AgentOutputParser.parse(raw)` 先跑一遍正则/CDATA 解析，再看有没有原生调用
 * - `nativeCalls.first()` 只按**第一个**调用决定整轮成败
 * - 并行能力靠 `MAX_NATIVE_CALLS_PER_TURN = 4` 硬上限 + `preFetchParallelSafe` 的
 *   "先并发跑掉再按序处理"两段式，形态复杂
 *
 * 本类**只处理原生调用**：没有 `arguments` 解析以外的任何解析，没有工具名猜测。
 *
 * ## 三条硬保证
 *
 * 1. **不做任何格式修复** —— arguments 不是合法 JSON ⇒ 该调用失败，把 Schema 错误
 *    原文交回模型。绝不 `replace("'", "\"")`、绝不补大括号。
 * 2. **全部执行，不设"一次只执行一个"** —— 模型发几个就执行几个（并行）。
 *    唯一的数量限制是 [MAX_CALLS_PER_TURN]（防单轮无限调用，不是防模型能力）。
 * 3. **未执行的调用必须配对回填**（`unexecutedResult`）—— 否则下次请求 400。
 *    这是 wire 语义，**不可删**。
 */
class CloudToolExecutor(
    private val registry: CloudToolRegistry,
    /**
     * 单轮最多执行多少个调用。
     *
     * **32** —— 这个数不是"模型能力上限"，而是"防跑飞"的成本闸：
     * 一轮发 32 个独立调用已是极端批量场景；再多说明它在"扫全库"，
     * 那更该用 `grep_files` 一次拿全。
     *
     * ⚠️ 与旧实现的关键区别：旧值是 **4**，理由是"云端模型经常一次发 2-3 个，
     * 4 够用"。但那会**逼模型多跑一轮**。新版给到 32，实际永不触发。
     * 超过时仍**如实回填"未执行"**，不静默丢。
     */
    private val maxCallsPerTurn: Int = MAX_CALLS_PER_TURN,
    /**
     * **永不并发的工具名**（即使声明了 `parallelSafe`）。
     *
     * 主要是**需要审批**的工具（`mutatingTools`）：审批队列是**单槽**的，
     * 两个并发审批会让"用户正在批准的是哪一个"失去意义，且第二个 reply 会喂错调用
     * （旧 `AgentLoop` 的 KDoc 明确记过这条）。
     *
     * 由管线把 `mutatingTools` 传进来。
     */
    private val neverConcurrent: Set<String> = emptySet(),
    /** 工具执行体（含审批、路径守卫等）—— 由装配层注入，本类不碰设备/文件系统细节。 */
    private val executeTool: suspend (CloudToolCall, Map<String, String>) -> ToolRunResult,
) {

    /**
     * 执行一轮的全部原生调用。
     *
     * ## 顺序保证
     *
     * 返回值**按输入顺序**排列（即使内部并行执行）。原因：
     * 1. 上层要把结果按 index 写回会话，顺序错乱会让模型对应错
     * 2. 事件顺序必须确定（UI 的步骤列表不能抖动）
     */
    suspend fun executeTurn(calls: List<CloudToolCall>): List<ToolRunResult> {
        if (calls.isEmpty()) return emptyList()

        val (accepted, overflow) = if (calls.size > maxCallsPerTurn) {
            calls.take(maxCallsPerTurn) to calls.drop(maxCallsPerTurn)
        } else {
            calls to emptyList()
        }

        // ★★ 2026-10-21 修：**只有 parallelSafe 的工具才并发** ★★
        //
        // ## 修的是什么（我自己的 bug）
        //
        // 上一版把**全部** accepted 调用都 `async` 并行，注释却写着
        // "由 Registry 的 parallelSafe 声明决定" —— **代码根本没看那个声明**。
        //
        // 后果（都是真问题）：
        // · 两个 `write_file` 同时写同一文件 ⇒ 竞态、内容错乱
        // · 两个需要**审批**的调用同时进 `ApprovalGate` ⇒ 审批队列是**单槽**，
        //   第二个 reply 会喂错调用（旧 `AgentLoop` 的 KDoc 明确警告过这条：
        //   "并发弹窗会让用户无法判断『我正在批准的是哪一个』"）
        // · `delete_path` 与 `read_file` 交错 ⇒ 读到的可能是删了一半的状态
        //
        // ## 现在怎么做（与旧 `AgentLoop.preFetchParallelSafe` 同一思路）
        //
        // 1. **先并发启动**可以并发的（parallelSafe 且不需审批）
        // 2. **按原顺序**取结果：能并发的 `await` 预取结果，其余**就地串行执行**
        //
        // ⇒ 并发收益保留、顺序确定（UI 步骤列表不抖）、副作用不打架。
        val executed = coroutineScope {
            val deferred = accepted.map { call ->
                val tool = registry.byName(call.name)
                val canConcurrent = tool != null &&
                    tool.parallelSafe &&
                    call.name !in neverConcurrent
                // 只需排队等审批的调用**永不并发**（单槽队列）
                call to if (canConcurrent) async { runOne(call) } else null
            }
            deferred.map { (call, d) -> d?.await() ?: runOne(call) }
        }

        // 超上限的必须回填"未执行"（配对语义，否则下次请求 400）
        val skipped = overflow.map { call ->
            ToolRunResult(
                call = call,
                status = ToolRunStatus.NOT_EXECUTED,
                output = "未执行：本轮调用数超过上限（$maxCallsPerTurn 个）。" +
                    "请分多轮发起，或改用一次能拿全的检索工具（如 grep_files / find_files）。",
                isError = true,
            )
        }

        return executed + skipped
    }

    /** 执行单个调用：查注册表 → 校验 → 执行。**任何一步失败都不抛，而是变成可回填的结果。** */
    private suspend fun runOne(call: CloudToolCall): ToolRunResult {
        val tool = registry.byName(call.name)
            ?: return ToolRunResult(
                call = call,
                status = ToolRunStatus.UNKNOWN_TOOL,
                output = "未执行：不存在名为 `${call.name}` 的工具。" +
                    "当前可用工具：${registry.allNames().joinToString()}",
                isError = true,
            )

        val validation = CloudToolValidator.validate(call, tool.schema)
        if (validation is CloudToolValidator.Result.Invalid) {
            // ★ 核心纪律：**不修复、不猜**。把具体错误交回模型，它有自我纠错能力。
            return ToolRunResult(
                call = call,
                status = ToolRunStatus.SCHEMA_INVALID,
                output = "未执行：参数不符合 Schema —— ${validation.detail}",
                isError = true,
            )
        }

        val args = (validation as CloudToolValidator.Result.Valid).args
        return runCatching { executeTool(call, args) }.getOrElse { e ->
            // 工具实现抛异常 = 真 bug，但**不能炸掉整轮**（模型还要继续）。
            // 如实回报，让模型知道"这个工具坏了"而不是"操作成功了"。
            ToolRunResult(
                call = call,
                status = ToolRunStatus.FAILED,
                output = "执行失败（内部错误）：${e::class.simpleName}: ${e.message ?: "未知"}",
                isError = true,
            )
        }
    }

    companion object {
        /** 单轮调用数上限 —— 成本闸，不是能力闸（见构造参数 KDoc）。 */
        const val MAX_CALLS_PER_TURN = 32
    }
}

/** 一次调用的执行结果。 */
data class ToolRunResult(
    val call: CloudToolCall,
    val status: ToolRunStatus,
    /** 回填给模型的文本（成功时是结果，失败时是**可操作的原因**）。 */
    val output: String,
    val isError: Boolean = false,
) {
    /**
     * 转成给模型看的 `tool_result` 内容。
     *
     * 成功就原样、失败加前缀 —— **不要**在这里改成 JSON 或加元信息：
     * 工具结果越像"工具说的人话"，模型越不容易把它当成新指令。
     */
    fun renderForModel(): String = if (isError) output else output
}

/** 执行状态 —— 用于记账与 UI，不要用它替代 [ToolRunResult.isError]。 */
enum class ToolRunStatus {
    /** 执行成功。 */
    OK,

    /** 工具执行了但报告失败（业务失败，如"文件不存在"）。 */
    FAILED,

    /** 参数不符合 Schema，未执行 —— 模型应修正参数重试。 */
    SCHEMA_INVALID,

    /** 工具名不在注册表里，未执行。 */
    UNKNOWN_TOOL,

    /**
     * 因超出单轮上限而**未执行**。
     *
     * ⚠️ 这一档必须回填一条"未执行"的 tool_result —— 否则服务端会因
     * "tool_calls 没有配对结果"返回 400。
     */
    NOT_EXECUTED,

    /** 需要用户审批，等待中（UI 弹窗）。 */
    NEEDS_APPROVAL,
}
