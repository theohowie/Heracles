package dev.heracles.cloud

import dev.heracles.cloud.context.AgentMessage
import dev.heracles.cloud.context.CloudToolCall
import dev.heracles.cloud.context.ContextManager
import dev.heracles.cloud.context.MessageRole
import dev.heracles.cloud.prompt.CloudPrompts
import dev.heracles.cloud.tool.CloudToolExecutor
import dev.heracles.cloud.tool.CloudToolRegistry
import dev.heracles.cloud.tool.ToolOutcome
import dev.heracles.cloud.tool.ToolRunResult
import dev.heracles.cloud.tool.ToolRunStatus
import dev.heracles.core.provider.CacheStats
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.StreamChunk
import dev.heracles.core.tool.NativeToolCall
import kotlinx.coroutines.flow.toList

/**
 * **`CloudAgentPipeline` 主体** —— 为 2026 世代云端大模型设计的纯净执行管线。
 *
 * ## 与旧 `AgentLoop` 的关系：**隔离重建**，不是局部修补
 *
 * | | 旧 `AgentLoop` | 本管线 |
 * |---|---|---|
 * | 输出解析 | `AgentOutputParser`（CDATA 标签 + `{"tool":…}` 信封 + 正则） | **无解析器** —— 只消费 provider 已拆好的 `tool_calls` |
 * | 工具调用 | 两条轨并存（文本 JSON / 原生），`nativeToolsEnabled` 默认 false | **只有原生** |
 * | 参数类型 | 全 `string`，工具内二次解析 | 标准 JSON Schema（integer/boolean/array/enum） |
 * | 并行调用 | 上限 4，两段式 preFetch | 上限 32，全部并行 |
 * | 历史 | `HISTORY_MAX_TURNS=10` 硬切 | 8 万 token 预算内**全装**，溢出才摘要 |
 * | 校验 | 按参数名 500 字符白名单 | JSON Schema + 唯一 10MB 物理闸 |
 * | 熔断 | 连续解析失败 2 次 | 连续 5 次（给自我纠错留空间） |
 *
 * 旧 `AgentLoop` **保留不动**（fallback），由 `CloudPipelineFlags` 切换。
 *
 * ## 为什么可以没有解析器
 *
 * provider 已经按各家的 wire 契约把流式分片拼装成 `NativeToolCall`
 * （`NativeCallAssembler` / `AnthropicToolCalls` / Responses 的
 * `output_item.done`）。**拼装在 provider，语义在执行层** —— 这是既有架构的正确分层，
 * 本管线只是**不再往中间插一个"文本方言解析器"**。
 */
class CloudAgentPipeline(
    private val provider: ModelProvider,
    private val registry: CloudToolRegistry,
    /** 模型真实上下文窗口（token）。来自服务端上报；缺失时用保守兜底。 */
    private val modelContextWindow: Int,
    private val contextManager: ContextManager,
    /** 系统提示（默认 [CloudPrompts.SYSTEM]）。 */
    private val systemPrompt: String = CloudPrompts.SYSTEM,
    /** 单任务最大轮次。 */
    private val maxTurns: Int = DEFAULT_MAX_TURNS,
    /** 单任务工具调用总预算。 */
    private val maxToolCalls: Int = DEFAULT_MAX_TOOL_CALLS,
    /**
     * **连续"Schema 校验失败"熔断阈值**。
     *
     * ## 为什么是 5 而不是 2
     *
     * 旧值 2（`AgentLoop.CONSECUTIVE_UNPARSEABLE_LIMIT`）是为
     * **"正文恒为空"那类本地系统性故障**定的（llama.cpp 把 max_tokens 全烧在思考上）。
     * 那种故障重试确实没用。
     *
     * 但云端强模型遇到的更常见是**协议形状漂移 / 参数填错** ——
     * 而这类错误**是可自愈的**：给出具体 Schema 错误后，模型下一轮大概率改对。
     * 阈值 2 等于"第二次就给整个任务判死刑"。
     *
     * 5 的依据：`temperature=0` 下若真无自愈能力，5 轮足以证明；
     * 而给 5 轮的成本（5 次请求）远低于"任务失败让用户重来"的成本。
     */
    private val consecutiveSchemaFailureLimit: Int = DEFAULT_CONSECUTIVE_FAILURE_LIMIT,
    /**
     * **危险操作审批门禁** —— 2026-10-21 补。
     *
     * ## 为什么这是安全底线，不是可选项
     *
     * 新管线最初只把 `ToolOutcome.NeedsApproval` 映射成"失败回填给模型"
     * （`ToolRunStatus.NEEDS_APPROVAL`）—— **根本没有人被问过**。
     * 那意味着 `run_shell_command` 里的 `rm -rf` / 装 APK 这类被
     * `CommandGuard` 判为 `NeedsApproval` 的操作，在旧路径会弹窗问用户，
     * 在新路径会**直接以"未执行"失败** —— 看起来安全，实则：
     *
     * · 用户永远无法批准合法的危险操作（功能丢失）
     * · 若将来有人"顺手"把 NEEDS_APPROVAL 当成功放行，就变成**静默绕过审批**
     *
     * ⇒ 审批必须是一条**显式的、必填的**依赖，不能靠"忘了传就不用问"。
     *
     * `null` = 不启用审批（仅单测/CLI 使用）。**生产装配必须传**。
     * 见 [CloudPipelineAssembler.build] 的 `approval` 参数。
     */
    private val approval: ApprovalGate? = null,
    /**
     * **哪些工具会修改世界**（需要审批的工具集合）。
     *
     * 与旧 `AgentLoop.mutatingTools` **同语义**，但这里是新管线的 own copy ——
     * 不是因为想分叉，而是因为 `AgentLoop` 的字段是 private。
     * ⚠️ 两处必须保持一致：新增会改文件的工具时**两边都要加**。
     * 已有门禁 `CloudPipelineSafetyTest` 钉住"关键工具必须在名单里"。
     */
    private val mutatingTools: Set<String> = DEFAULT_MUTATING_TOOLS,
    /**
     * **提问门禁** —— `ask_user` 的 UI 插槽（2026-10-21）。
     *
     * `null` = 没有提问通道（CLI/单测）。此时 `ask_user` 会如实返回
     * "用户暂时没有回答"，**绝不编造答案**。
     */
    private val askGate: AskGate? = null,
    /**
     * **计划变更回调**（2026-10-21 补）—— 用于把计划**落盘**。
     *
     * ## 为什么必须补（弃用旧管线前的必要项）
     *
     * 旧 `AgentLoop` 有 `onPlanChanged` → `AgentBridge` 把计划写进
     * `.heracles/plans/<sessionId>.json`，切会话/重启后能读回来。
     * 新管线最初没有这条线 ⇒ **切会话后计划面板变空**（相对旧管线的**功能回归**）。
     *
     * 注入而非自己写盘：`:agent` 不认识 `WorkspaceStorage`/SAF（分层纪律，
     * 与旧 `AgentLoop.onPlanChanged` 同一个理由）。
     *
     * 回调抛异常会被吞掉并留痕 —— 计划落盘是记忆增强，不是硬依赖。
     */
    private val onPlanChanged: (suspend (List<PlanStepView>) -> Unit)? = null,
    /** 事件回调（UI 流式展示）。 */
    private val onEvent: ((CloudEvent) -> Unit)? = null,
) {

    /**
     * 跑完一个任务。
     *
     * **严格 append-only**：会话只追加，永不改写（铁律 1）。
     * 压缩是"新建一段会话"，不是在旧前缀上改尾部。
     */
    suspend fun run(
        userRequest: String,
        history: List<AgentMessage> = emptyList(),
        /** 从落盘的会话恢复的计划（`null`/空 = 没有可恢复的计划）。 */
        initialPlan: List<PlanStepView> = emptyList(),
    ): CloudRunResult {
        val executor = CloudToolExecutor(
            registry = registry,
            // ★ 需要审批的工具永不并发（审批队列单槽，并发会让 reply 喂错调用）
            neverConcurrent = mutatingTools,
            executeTool = { call, args -> runTool(call, args) },
        )

        // ★ 恢复落盘的计划（2026-10-21）—— 让"继续这个会话"能看到原计划
        if (initialPlan.isNotEmpty()) {
            currentPlan = normalizePlan(initialPlan)
        }

        // ★ 启动日志：确认走的是新管线 + 装配参数（真机验证时第一眼要看这个）
        println(
            "[heracles][cloud] pipeline START " +
                "provider=${provider.id} " +
                "kind=${provider.kind} " +
                "window=$modelContextWindow budget=${contextManager.budgetTokens} " +
                "resident=${registry.resident.size} disclosable=${registry.disclosable.size} " +
                "maxTurns=$maxTurns maxToolCalls=$maxToolCalls " +
                "approval=${if (approval != null) "on" else "OFF"} " +
                "askGate=${if (askGate != null) "on" else "OFF"} " +
                "history=${history.size}"
        )
        if (approval == null) {
            // ⚠️ 装配漏传审批门禁 ⇒ **大声说**（危险操作不会被问，这是安全问题）
            println("[heracles][cloud] ⚠️ WARNING: approval gate 未装配 —— 危险操作不会询问用户")
        }

        var session = history.toMutableList()
        session += AgentMessage(MessageRole.USER, userRequest)

        val records = mutableListOf<CloudTurnRecord>()
        val disclosed = mutableSetOf<String>()
        var toolCallCount = 0
        var consecutiveSchemaFailures = 0
        var finalText = ""
        var stopReason = ""

        for (turnIndex in 1..maxTurns) {
            emit(CloudEvent.TurnStarted(turnIndex))

            // ---------- ① 上下文装载（模块二）----------
            val systemTokens = estimateSystemTokens()
            val compacted = contextManager.applyCompaction(systemTokens, session)
            if (compacted.summaryFailed) {
                // 摘要失败 ⇒ 用完整历史继续（宁可贵，不要残缺上下文）
                emit(CloudEvent.Warning("上下文摘要失败，本次使用完整历史继续"))
            }
            val messages = toChatMessages(compacted.messages, systemPrompt, currentPlan)

            // ---------- ② 一轮模型生成 ----------
            val streamed = runCatching {
                provider.generateStream(
                    GenerateRequest(
                        prompt = userRequest,
                        maxOutputTokens = MAX_OUTPUT_TOKENS,
                        messages = messages,
                        // ★ 常驻 + 已披露，全部进 tools —— 不再有"披露才可用"的阻塞
                        tools = registry.activeTools(disclosed).map { it.spec },
                    )
                ).toList()
            }.getOrElse { e ->
                stopReason = "provider 错误：${e.message}"
                emit(CloudEvent.Failed(stopReason))
                return CloudRunResult(records, "", stopReason, 0, 0, 0)
            }

            val done = streamed.lastOrNull { it.done }
            val text = streamed.joinToString("") { it.deltaText }
            val nativeCalls = done?.toolCalls.orEmpty()
            val cache = provider.lastStreamCache()

            emit(CloudEvent.ModelOutput(turnIndex, text, nativeCalls.size, done?.finishReason))

            // ★★ 结构化诊断日志（2026-10-21）★★
            //
            // ## 为什么必须有（真机验证的唯一线索）
            //
            // 新管线第一版**一行日志都没有**。而真机验证时能拿到的只有 logcat ——
            // 没有这行就只能看到"任务失败了"，无法判断是：
            // · `tools` 被中转站拒了？
            // · 模型没发 `tool_calls`？
            // · 发了但参数不是合法 JSON？
            // · 输出被 max_tokens 截断（`finish=LENGTH`）？
            //
            // ## 与旧管线的格式**保持一致**（便于对照排查）
            //
            // `[heracles][turn] turn=N finish=X raw=L reasoning=R calls=C maxOut=M fail=F`
            //
            // ⚠️ **只打长度/枚举/数量，绝不打正文**（正文可能含用户数据）。
            //    `fail` 只打异常类型与消息，不含 Key（provider 已按纪律脱敏）。
            println(
                "[heracles][cloud-turn] turn=$turnIndex " +
                    "finish=${done?.finishReason ?: "FAILED"} " +
                    "raw=${text.length} " +
                    "calls=${nativeCalls.size} " +
                    "tools=${registry.activeTools(disclosed).size} " +
                    "maxOut=$MAX_OUTPUT_TOKENS " +
                    "msgs=${messages.size} " +
                    "toolNames=${nativeCalls.joinToString(",") { it.tool }.ifEmpty { "-" }}"
            )

            // ---------- ③ 无原生调用 ⇒ 这就是最终回答 ----------
            //
            // ★ 关键：**不再要求 JSON 信封**。旧实现把纯文本判成 Unparseable
            //   ⇒ 连挂两轮熔断 —— 那正是"为什么必须逼模型守格式"的来源。
            if (nativeCalls.isEmpty()) {
                finalText = text.trim()
                stopReason = "完成"
                records += CloudTurnRecord(
                    turnIndex, userRequest, text, emptyList(),
                    CloudTurnVerdict.FINAL_ANSWER, cache,
                )
                emit(CloudEvent.Finished(finalText, stopReason, records.size))
                return CloudRunResult(
                    records, finalText, stopReason,
                    cache.promptTokens, cache.cachedTokens ?: 0, cache.outputTokens,
                )
            }

            // ---------- ④ 有原生调用 ----------
            session += AgentMessage(
                role = MessageRole.ASSISTANT,
                text = text,
                toolCalls = nativeCalls.map { CloudToolCall(it.id, it.tool, it.argumentsJson) },
            )

            // 元工具（search_tools / update_plan / ask_user）先处理：它们不进普通执行路径
            val (metaCalls, realCalls) = nativeCalls.partition { isMetaTool(it.tool) }
            // ★ 元工具按**声明顺序**逐个处理（不能并行：update_plan 改的是循环状态，
            //   ask_user 要串行挂起 —— 并发会让"我正在批准的是哪一个"失去意义）
            val metaResults = mutableListOf<ToolRunResult>()
            for (meta in metaCalls) {
                metaResults += handleMetaTool(meta, disclosed, turnIndex)
            }
            metaResults.forEach { r ->
                session += AgentMessage(
                    role = MessageRole.TOOL,
                    text = r.output,
                    toolCallId = r.call.id,
                    isError = r.isError,
                )
            }

            // 预算扣减（元工具也计数 —— 否则模型可以靠反复 search_tools 免费跑）
            toolCallCount += metaCalls.size

            // ---------- ⑤ 并行执行真实工具（模块一）----------
            val budgetLeft = maxToolCalls - toolCallCount
            val toRun = if (realCalls.size > budgetLeft) {
                // 超预算的**必须配对回填**（否则下次请求 400）
                val accepted = realCalls.take(budgetLeft.coerceAtLeast(0))
                val rejected = realCalls.drop(accepted.size)
                val rejectedResults = rejected.map {
                    ToolRunResult(
                        call = CloudToolCall(it.id, it.tool, it.argumentsJson),
                        status = ToolRunStatus.NOT_EXECUTED,
                        output = "未执行：工具调用预算已用尽（$maxToolCalls 次）。" +
                            "请向用户如实说明任务未完成。",
                        isError = true,
                    )
                }
                executor.executeTurn(accepted.map { CloudToolCall(it.id, it.tool, it.argumentsJson) }) +
                    rejectedResults
            } else {
                executor.executeTurn(realCalls.map { CloudToolCall(it.id, it.tool, it.argumentsJson) })
            }
            toolCallCount += toRun.count { it.status != ToolRunStatus.NOT_EXECUTED }

            // ---------- ⑥ 回填结果（**每个**调用一条，含未执行的）----------
            var schemaFailuresThisTurn = 0
            toRun.forEach { r ->
                session += AgentMessage(
                    role = MessageRole.TOOL,
                    text = r.output,
                    toolCallId = r.call.id,
                    isError = r.isError,
                )
                if (r.status == ToolRunStatus.SCHEMA_INVALID) schemaFailuresThisTurn++

                // 图片类结果要随下一轮发出
                if (r.output.startsWith(IMAGE_PREFIX)) {
                    pendingImages += r.output.removePrefix(IMAGE_PREFIX)
                }
                emit(CloudEvent.ToolFinished(turnIndex, r.call.name, r.status, r.isError))
            }

            records += CloudTurnRecord(
                turnIndex, userRequest, text,
                toRun.map { it.call.name },
                CloudTurnVerdict.TOOL_CALLS,
                cache,
            )

            // ---------- ⑦ 熔断：连续 Schema 失败 ----------
            consecutiveSchemaFailures = if (schemaFailuresThisTurn > 0) {
                consecutiveSchemaFailures + schemaFailuresThisTurn
            } else {
                0
            }
            if (consecutiveSchemaFailures >= consecutiveSchemaFailureLimit) {
                // ★ 把**具体的 Schema 错误**作为反馈注入（不教格式、不猜）
                val lastErrors = toRun
                    .filter { it.status == ToolRunStatus.SCHEMA_INVALID }
                    .joinToString("\n") { "- ${it.call.name}: ${it.output}" }
                session += AgentMessage(
                    role = MessageRole.USER,
                    text = CloudPrompts.schemaCorrection(lastErrors),
                )
                stopReason = "连续 $consecutiveSchemaFailures 次参数校验失败，已停止"
                finalText = "模型连续 $consecutiveSchemaFailures 次未能给出符合 Schema 的参数，已停止。" +
                    "\n\n最后一次的错误：\n$lastErrors\n\n" +
                    "请检查该工具的 Schema 是否与模型能力匹配，或重试。"
                emit(CloudEvent.Finished(finalText, stopReason, records.size))
                return CloudRunResult(
                    records, finalText, stopReason,
                    records.sumOf { it.cache.promptTokens },
                    records.sumOf { it.cache.cachedTokens ?: 0 },
                    records.sumOf { it.cache.outputTokens },
                )
            }

            // 跑飞的保护：finish_reason=LENGTH 且无有效进展 ⇒ 如实报告
            if (done?.finishReason == FinishReason.LENGTH && toRun.isEmpty()) {
                stopReason = "输出被 max_tokens 截断，且未产生有效工具调用"
                emit(CloudEvent.Warning(stopReason))
            }
        }

        // ---------- 达到轮次上限：**如实说没做完** ----------
        stopReason = "达到最大轮次（$maxTurns），任务未完成"
        if (finalText.isBlank()) {
            finalText = CloudPrompts.budgetExhausted(stopReason)
        }
        emit(CloudEvent.Finished(finalText, stopReason, records.size))
        return CloudRunResult(
            records, finalText, stopReason,
            records.sumOf { it.cache.promptTokens },
            records.sumOf { it.cache.cachedTokens ?: 0 },
            records.sumOf { it.cache.outputTokens },
        )
    }

    // ------------------------------------------------------------------ 工具执行

    private val pendingImages = mutableListOf<String>()

    /**
     * **测试入口** —— 直接走真实的工具执行路径（含审批）。
     *
     * 为什么需要它：审批逻辑在 private 的 [runTool] 里，而 `run()` 需要
     * provider 真的发 `tool_calls`（`FakeProvider` 可控但很绕）。
     * 审批是**安全底线**，必须能被直接单测 —— 所以开这个 `internal` 口子。
     *
     * ⚠️ 只给测试用。生产代码请走 [run]。
     */
    internal suspend fun runToolForTest(call: CloudToolCall, args: Map<String, String>): ToolRunResult =
        runTool(call, args)

    /**
     * **元工具测试入口**（2026-10-21）。
     *
     * `update_plan` / `ask_user` / `search_tools` **不在** [registry] 里
     * （它们由管线拦截处理，见 [handleMetaTool]）⇒ [runToolForTest] 会返回
     * "未知工具"。测试元工具必须走这个入口。
     */
    internal suspend fun runMetaToolForTest(
        call: CloudToolCall,
        turnIndex: Int = 1,
    ): ToolRunResult = handleMetaTool(
        NativeToolCall(call.id, call.name, call.argumentsJson),
        mutableSetOf(),
        turnIndex,
    )

    private suspend fun runTool(call: CloudToolCall, args: Map<String, String>): ToolRunResult {
        val tool = registry.byName(call.name)
            ?: return ToolRunResult(call, ToolRunStatus.UNKNOWN_TOOL, "未知工具", isError = true)

        // ★★ 审批门禁（2026-10-21 补）★★
        //
        // 两处都要问，缺一不可：
        // ① 工具**自己**说"需要确认"（CommandGuard 判的 rm -rf / 装 APK 等）
        // ② 工具在 mutatingTools 名单里**且**档位要求问（由 gate 实现决定档位语义）
        //
        // 旧管线把"要不要问"的判断散在 AgentLoop 的 4 个调用点；这里收成一条路径。
        // ⚠️ 顺序：先执行再看 outcome（工具自己才知道要不要确认），
        //    所以 ① 天然在下面那个 when 里；② 在**执行前**判。
        val needsPreApproval = call.name in mutatingTools && approval != null
        if (needsPreApproval) {
            val allowed = approval!!.requestApproval(
                tool = call.name,
                args = args,
                reason = "该工具会修改文件或设备：${call.name}",
            )
            if (!allowed) {
                // 拒绝**不是错误**：如实回填，模型换个做法继续
                return ToolRunResult(
                    call, ToolRunStatus.NEEDS_APPROVAL,
                    "用户拒绝执行（未批准）：${call.name}。请换一个不修改文件的方案，" +
                        "或向用户说明你需要这个操作的理由。",
                    isError = true,
                )
            }
        }

        // 工具自己判"需要确认"（命令守卫）⇒ 用同一条 gate 问
        var outcome = tool.run(args)
        if (outcome is ToolOutcome.NeedsApproval) {
            val gate = approval
                ?: return ToolRunResult(
                    call, ToolRunStatus.NEEDS_APPROVAL,
                    "未执行：该操作需要用户确认，但当前没有审批通道（装配缺 ApprovalGate）。",
                    isError = true,
                )
            val allowed = gate.requestApproval(call.name, args, outcome.detail)
            if (!allowed) {
                return ToolRunResult(
                    call, ToolRunStatus.NEEDS_APPROVAL,
                    "用户拒绝执行：${outcome.detail}",
                    isError = true,
                )
            }
            // 批准 ⇒ **重新执行**（工具是有副作用的，第一次那次没有真正做）
            outcome = tool.run(args)
        }

        return when (outcome) {
            is ToolOutcome.Success ->
                ToolRunResult(call, ToolRunStatus.OK, outcome.detail)
            is ToolOutcome.SuccessWithImage ->
                ToolRunResult(
                    call, ToolRunStatus.OK,
                    IMAGE_PREFIX + outcome.imageDataUrl + "\n" + outcome.detail,
                )
            is ToolOutcome.Failure ->
                ToolRunResult(call, ToolRunStatus.FAILED, outcome.reason, isError = true)
            is ToolOutcome.NeedsApproval ->
                // 二次确认后仍是 NeedsApproval ⇒ 视为拒绝（绝不放行）
                ToolRunResult(call, ToolRunStatus.NEEDS_APPROVAL, "未执行：${outcome.detail}", isError = true)
        }
    }

    /**
     * 元工具由管线自己处理（不经过工具执行体）。
     *
     * ## 为什么这三个必须被拦截，而不是当普通工具跑
     *
     * | 工具 | 为什么不能普通执行 |
     * |---|---|
     * | `search_tools` | 它要改管线自己的 `disclosed` 集合 |
     * | `update_plan` | 计划是**循环状态**（挂在本次 run 上），工具实例拿不到 |
     * | `ask_user` | 要挂起等 UI 回答，工具实例需要回答队列 |
     *
     * ## 2026-10-21 补齐 update_plan / ask_user
     *
     * 之前这里只有 `search_tools`，其余元工具返回"需由装配层处理"⇒
     * **计划面板与提问弹窗在新管线里完全不工作**（工具调了但没 UI）。
     * 现在三个都真处理，并各自发对应的 [CloudEvent]。
     */
    private suspend fun handleMetaTool(
        call: NativeToolCall,
        disclosed: MutableSet<String>,
        turnIndex: Int,
    ): ToolRunResult {
        val cc = CloudToolCall(call.id, call.tool, call.argumentsJson)
        return when (call.tool) {
            "search_tools" -> {
                val q = extractSimpleString(call.argumentsJson, "query")
                val found = registry.search(q)
                if (found.isEmpty()) {
                    ToolRunResult(
                        cc, ToolRunStatus.FAILED,
                        "没有匹配「$q」的工具。当前可用：${registry.allNames().joinToString()}。" +
                            "换个更具体的关键词再搜。",
                        isError = true,
                    )
                } else {
                    disclosed.addAll(found.map { it.spec.name })
                    val detail = buildString {
                        append("找到 ${found.size} 个工具（**下一轮即可直接调用**）：\n")
                        found.forEach { t ->
                            append("- ${t.spec.name}：${t.spec.description}\n")
                        }
                    }
                    ToolRunResult(cc, ToolRunStatus.OK, detail)
                }
            }

            // ---------------------------------------------------------- update_plan
            "update_plan" -> {
                val stepsRaw = extractArrayText(call.argumentsJson, "steps")
                val parsed = parsePlanSteps(stepsRaw)
                if (parsed == null) {
                    // ★ 解析失败**不造空计划**（与旧 TaskPlan 的纪律一致）：
                    //   编一个计划会让 UI 显示假进度。
                    ToolRunResult(
                        cc, ToolRunStatus.FAILED,
                        "steps 不是合法计划：需要一个数组，元素形如 " +
                            """{"text":"查看项目结构","status":"pending|active|done"}。""" +
                            "收到：${stepsRaw.take(200)}",
                        isError = true,
                    )
                } else {
                    // 多个 active ⇒ 只留第一个（"现在在干什么"必须有唯一答案）
                    val normalized = normalizePlan(parsed)
                    currentPlan = normalized
                    emit(
                        CloudEvent.PlanUpdated(
                            turnIndex = turnIndex,
                            steps = normalized,
                            doneCount = normalized.count { it.status == PlanStatusView.DONE },
                            activeIndex = normalized.indexOfFirst { it.status == PlanStatusView.ACTIVE },
                        )
                    )
                    // ★ 落盘（2026-10-21 补）—— 切会话/重启后能读回来。
                    //   失败**不影响** run（计划是记忆增强，不是硬依赖），但要留痕。
                    val sink = onPlanChanged
                    if (sink != null && currentPlan.isNotEmpty()) {
                        runCatching { sink(currentPlan) }
                            .onFailure { println("[heracles][cloud] plan persist failed: ${it::class.simpleName}") }
                    }
                    val done = normalized.count { it.status == PlanStatusView.DONE }
                    ToolRunResult(
                        cc, ToolRunStatus.OK,
                        "计划已更新（${normalized.size} 步，完成 $done 步）\n" + renderPlan(normalized),
                    )
                }
            }

            // ---------------------------------------------------------- ask_user
            "ask_user" -> {
                val questionsRaw = extractArrayText(call.argumentsJson, "questions")
                val questions = runCatching {
                    dev.heracles.agent.AskUserArgs.parse(questionsRaw)
                }.getOrDefault(emptyList())

                if (questions.isEmpty()) {
                    ToolRunResult(
                        cc, ToolRunStatus.FAILED,
                        "questions 不是合法的题目数组。正确形状：" +
                            """[{"id":"q1","question":"…","multi":false,""" +
                            """"options":[{"label":"A"},{"label":"B"}]}]""",
                        isError = true,
                    )
                } else {
                    // ★ 先发事件让 UI 弹窗（**在挂起之前**），否则用户不知道模型在等什么
                    emit(CloudEvent.AskUser(turnIndex, questions, cc))
                    val answers = askGate?.awaitAnswers(questions)
                    if (answers == null) {
                        // 超时/无通道 ⇒ 如实说，让模型自己决定下一步（**绝不编造答案**）
                        ToolRunResult(
                            cc, ToolRunStatus.FAILED,
                            "用户暂时没有回答（等待超时或当前无提问通道）。" +
                                "请自行决定下一步：换个做法继续，或在最终回答里说明你卡在哪里、需要用户提供什么。",
                            isError = true,
                        )
                    } else {
                        ToolRunResult(cc, ToolRunStatus.OK, "用户回答：\n" + answers)
                    }
                }
            }

            else -> ToolRunResult(
                cc, ToolRunStatus.NOT_EXECUTED,
                "元工具 ${call.tool} 没有对应的处理分支（内部错误）",
                isError = true,
            )
        }
    }

    /** 当前计划（循环状态）—— 每轮注入到上下文尾部，模型据此知道进度。 */
    private var currentPlan: List<PlanStepView> = emptyList()

    /** 把计划渲染成人话（喂回模型）。 */
    private fun renderPlan(steps: List<PlanStepView>): String = buildString {
        append("【当前任务计划与进度】\n")
        steps.forEachIndexed { i, s ->
            val mark = when (s.status) {
                PlanStatusView.DONE -> "[x]"
                PlanStatusView.ACTIVE -> "[>]"
                PlanStatusView.PENDING -> "[ ]"
            }
            append("$mark ${i + 1}. ${s.text}\n")
        }
        append("\n请只做**当前进行中**的那一步；做完继续下一步。")
    }

    /** 多个 active ⇒ 只保留第一个；没有 active 且有未完成 ⇒ 第一个未完成变 active。 */
    private fun normalizePlan(steps: List<PlanStepView>): List<PlanStepView> {
        val firstActive = steps.indexOfFirst { it.status == PlanStatusView.ACTIVE }
        if (firstActive >= 0) {
            return steps.mapIndexed { i, s ->
                if (s.status == PlanStatusView.ACTIVE && i != firstActive) {
                    s.copy(status = PlanStatusView.PENDING)
                } else s
            }
        }
        val firstUndone = steps.indexOfFirst { it.status != PlanStatusView.DONE }
        if (firstUndone < 0) return steps
        return steps.toMutableList().also {
            it[firstUndone] = it[firstUndone].copy(status = PlanStatusView.ACTIVE)
        }
    }

    /**
     * 解析 `steps` 数组的原始 JSON 文本。
     *
     * 接受两种元素形状（宽容旧写法，与旧 `TaskPlan.parseUpdate` 一致）：
     * - `{"text":"…","status":"done"}`
     * - `"纯字符串"`（视为 pending）
     *
     * 解析不了 ⇒ `null`（调用方报"不是合法计划"，**不造空计划**）。
     */
    private fun parsePlanSteps(raw: String): List<PlanStepView>? {
        val text = raw.trim()
        if (!text.startsWith("[")) return null
        val objJson = runCatching {
            com.google.gson.JsonParser.parseString(text)
        }.getOrNull() ?: return null
        if (!objJson.isJsonArray) return null
        val out = mutableListOf<PlanStepView>()
        objJson.asJsonArray.forEach { el ->
            when {
                el.isJsonPrimitive -> {
                    val t = runCatching { el.asString }.getOrNull()?.trim()
                    if (!t.isNullOrBlank()) out += PlanStepView(t, PlanStatusView.PENDING)
                }
                el.isJsonObject -> {
                    val o = el.asJsonObject
                    val t = o.get("text")?.let { runCatching { it.asString }.getOrNull() }?.trim()
                    if (!t.isNullOrBlank()) {
                        val s = o.get("status")?.let { runCatching { it.asString }.getOrNull() }
                            ?.trim()?.lowercase()
                        val status = when (s) {
                            "done", "completed", "complete" -> PlanStatusView.DONE
                            "active", "doing", "current" -> PlanStatusView.ACTIVE
                            // 认不出 ⇒ pending（**不猜**）；但拼错的枚举会被 Schema 先拦下
                            else -> PlanStatusView.PENDING
                        }
                        out += PlanStepView(t, status)
                    }
                }
            }
        }
        return if (out.isEmpty()) null else out
    }

    /**
     * 从 arguments JSON 里取一个**数组值**的原文（用于 steps / questions）。
     *
     * 不做完整 JSON 解析：这里只要"把那一段数组原样切出来"，
     * 余下交给 `AskUserArgs` / `parsePlanSteps`。切不出来 ⇒ 空串（调用方报错）。
     */
    private fun extractArrayText(json: String, key: String): String {
        val keyIdx = json.indexOf("\"$key\"")
        if (keyIdx < 0) return ""
        val arrStart = json.indexOf('[', keyIdx)
        if (arrStart < 0) return ""
        var depth = 0
        var inStr = false
        var esc = false
        var i = arrStart
        while (i < json.length) {
            val c = json[i]
            when {
                esc -> esc = false
                c == '\\' && inStr -> esc = true
                c == '"' -> inStr = !inStr
                inStr -> Unit
                c == '[' -> depth++
                c == ']' -> {
                    depth--
                    if (depth == 0) return json.substring(arrStart, i + 1)
                }
            }
            i++
        }
        return ""
    }

    // ------------------------------------------------------------------ 辅助

    private fun isMetaTool(name: String): Boolean =
        name == "search_tools" || name == "update_plan" || name == "ask_user"

    private fun estimateSystemTokens(): Int =
        dev.heracles.core.text.TextMath.estimateTokens(systemPrompt) +
            registry.resident.sumOf {
                dev.heracles.core.text.TextMath.estimateTokens(it.spec.description) +
                    dev.heracles.core.text.TextMath.estimateTokens(it.spec.jsonSchema ?: "")
            }

        /**
     * 把会话 + 系统提示 + **当前计划**拼成 wire 消息。
     *
     * ## 为什么计划作为**最后一条 user 消息**注入
     *
     * 计划是**循环状态**，不进冻结前缀（否则每改一次计划前缀就抖、缓存全塌）。
     * 追加在尾部 = append-only 的合法用法，且模型每轮都能看到最新进度。
     *
     * 与旧 `AgentLoop.renderProgressLedger` 的位置语义一致（同样追加在尾部）。
     */
    private fun toChatMessages(
        history: List<AgentMessage>,
        system: String,
        plan: List<PlanStepView> = emptyList(),
    ): List<ChatMessage> = buildList {
        add(ChatMessage(ChatRole.SYSTEM, system))
        history.forEach { m ->
            when (m.role) {
                MessageRole.SYSTEM -> add(ChatMessage(ChatRole.SYSTEM, m.text))
                MessageRole.USER -> add(ChatMessage(ChatRole.USER, m.text))
                MessageRole.ASSISTANT -> add(
                    ChatMessage(
                        role = ChatRole.ASSISTANT,
                        content = m.text,
                        nativeCalls = m.toolCalls.map { NativeToolCall(it.id, it.name, it.argumentsJson) },
                    )
                )
                MessageRole.TOOL -> add(
                    ChatMessage(
                        role = ChatRole.TOOL,
                        content = m.text,
                        toolCallId = m.toolCallId,
                        isError = m.isError,
                    )
                )
            }
        }
        // ★ 计划注入在**最后**：模型每轮都能看到最新进度。
        //   追加而非改写 ⇒ append-only 合法；不进冻结前缀 ⇒ 缓存不塌。
        if (plan.isNotEmpty()) {
            add(ChatMessage(ChatRole.USER, renderPlan(plan)))
        }
    }

    /** 从 arguments JSON 里取一个顶层字符串值（只用于元工具的 `query`）。 */
    private fun extractSimpleString(json: String, key: String): String {
        val m = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"").find(json)
        return m?.groupValues?.get(1)?.replace("\\\"", "\"")?.replace("\\\\", "\\") ?: ""
    }

    private fun emit(e: CloudEvent) {
        onEvent?.invoke(e)
    }

    companion object {
        /** 单任务最大轮次（云端强模型一轮能做更多事，40 够用且不必再放大）。 */
        const val DEFAULT_MAX_TURNS = 40

        /** 单任务工具调用总预算。 */
        const val DEFAULT_MAX_TOOL_CALLS = 200

        /**
         * 连续 Schema 失败熔断阈值 —— **5**（旧值 2，见构造参数 KDoc）。
         */
        const val DEFAULT_CONSECUTIVE_FAILURE_LIMIT = 5

        /**
         * 单轮输出预算。
         *
         * **16384** —— 与旧默认 4096 的区别：旧值依据是"本地 llama.cpp 4096 上下文装不下大输出"
         * （`AgentLoop.kt:178-182`）。云端 256K~1M 窗口下，16K 输出只是小头，
         * 而它能让模型**一次性写完一个大文件**。同时它也是
         * `Contract.Inference.MAX_OUTPUT_TOKENS_CAP` 的值（不新增魔法数字）。
         */
        const val MAX_OUTPUT_TOKENS = 16_384

        /** 图片结果在工具输出里的内部前缀（装配层据此把图片抽出来随请求发）。 */
        internal const val IMAGE_PREFIX = "[[image-data-url]]"

        /**
         * **会修改世界**的工具 —— 在 MANUAL 档下执行前必须问用户。
         *
         * 与 `AgentLoop.mutatingTools` **逐项对齐**（含 2026-10-21 BUG-1 补的
         * `edit` / `restore_path`）。判据 = 有**文件系统 / 设备副作用**；
         * 读类（read_file/list_files/find_files/grep_files/web_fetch/view_image）
         * 与元工具（search_tools/update_plan/ask_user）不问 —— 问多了是噪音。
         */
        val DEFAULT_MUTATING_TOOLS: Set<String> = setOf(
            "write_file", "apply_patch", "edit", "restore_path",
            "delete_path", "move_path", "copy_path", "mkdir",
            "run_shell_command", "scaffold_android", "build_apk",
            "apk_decompile", "apk_recompile", "apk_sign", "d8_convert",
            "unzip_file", "zip_file",
        )
    }
}

/**
 * **审批门禁** —— 新管线的安全插槽（2026-10-21）。
 *
 * ## 为什么单独一个接口而不是直接依赖 `AgentLoop.ApprovalQueue`
 *
 * `dev.heracles.cloud` 的隔离原则是"不 import `dev.heracles.agent` 的内部类型"。
 * 审批是**策略**，装配层知道 UI 在哪；管线只该问"这次能不能执行"。
 * ⇒ 用接口反转依赖：装配层把 `ApprovalQueue` 适配成 [ApprovalGate]。
 *
 * ## 契约（三条，缺一不可）
 *
 * 1. **超时必须按"拒绝"处理** —— 绝不在没人看的时候放行
 * 2. **拒绝不是错误** —— 回填给模型的是"用户拒绝"，让它换个做法，而不是崩
 * 3. **实现必须可取消** —— 用户点「停止」时 `await` 要能退出
 */
interface ApprovalGate {
    /**
     * 请求用户批准一次工具调用。
     *
     * @param tool 工具名
     * @param args 参数（UI 展示用，**不要截断** —— 用户要看清才能签字）
     * @param reason 为什么需要批准（如"递归删除目录"、"要访问工作区外"）
     * @return `true` = 允许执行；`false` = 拒绝（含超时）
     */
    suspend fun requestApproval(tool: String, args: Map<String, String>, reason: String): Boolean
}

/**
 * **提问门禁** —— `ask_user` 的 UI 插槽（2026-10-21）。
 *
 * ## 为什么与 [ApprovalGate] 分开
 *
 * 两者都是"问用户"，但**返回值形状不同**：
 * - 审批：布尔（允许/拒绝）
 * - 提问：**多题多选**的答案（`题目 id → 选中的 label 列表`）
 *
 * 挤进一个接口会让两边都别扭（审批要返回一个没用的 Map，提问要返回一个没用的 Bool）。
 *
 * ## 契约
 *
 * 1. **超时必须返回 `null`** —— 由管线如实告诉模型"用户没回答"
 * 2. **绝不编造答案**：用户没点的选项不许出现在返回里
 * 3. **实现必须先发 UI 事件再挂起** —— 否则用户不知道在等什么
 */
interface AskGate {
    /**
     * 提问并等待回答。
     *
     * @param questions 已解析、已校验的题目（至少 1 题）
     * @return 渲染好的问答文本（喂回模型）；`null` = 超时/无通道
     */
    suspend fun awaitAnswers(questions: List<dev.heracles.core.tool.AskQuestion>): String?
}

/** 一轮的记账。 */
data class CloudTurnRecord(
    val turnIndex: Int,
    val userRequest: String,
    val modelText: String,
    val toolNames: List<String>,
    val verdict: CloudTurnVerdict,
    val cache: CacheStats,
)

enum class CloudTurnVerdict {
    FINAL_ANSWER,
    TOOL_CALLS,
}

/** 一次 run 的结果。 */
data class CloudRunResult(
    val records: List<CloudTurnRecord>,
    val finalText: String,
    val stopReason: String,
    val totalPromptTokens: Int,
    val totalCachedTokens: Int,
    val totalOutputTokens: Int,
)

/** 管线事件（UI 用）。 */
sealed interface CloudEvent {
    val turnIndex: Int

    data class TurnStarted(override val turnIndex: Int) : CloudEvent
    data class ModelOutput(
        override val turnIndex: Int,
        val text: String,
        val nativeCallCount: Int,
        val finishReason: FinishReason?,
    ) : CloudEvent

    data class ToolFinished(
        override val turnIndex: Int,
        val toolName: String,
        val status: ToolRunStatus,
        val isError: Boolean,
    ) : CloudEvent

    /**
     * **任务计划创建/更新**（2026-10-21）。
     *
     * 由 `update_plan` 工具触发。与旧 `AgentEvent.PlanCreated` 语义一致：
     * UI 拿它画打勾清单。
     *
     * @param steps 完整步骤列表（**每次都是全量**，不是增量 —— 增量的状态机
     *   在 UI 侧更难对，容易出现"某步消失"的错觉）
     * @param doneCount 其中已完成的步数
     * @param activeIndex 当前进行中那一步的下标（-1 = 没有）
     */
    data class PlanUpdated(
        override val turnIndex: Int,
        val steps: List<PlanStepView>,
        val doneCount: Int,
        val activeIndex: Int,
    ) : CloudEvent

    /**
     * **模型向用户提问**（`ask_user`，2026-10-21）。
     *
     * 到达时机 = 工具**正在挂起等待**回答。UI 必须弹窗；
     * 不弹的后果是队列超时，用户只看到任务卡死。
     */
    data class AskUser(
        override val turnIndex: Int,
        val questions: List<dev.heracles.core.tool.AskQuestion>,
        val call: CloudToolCall,
    ) : CloudEvent

    data class Warning(val message: String) : CloudEvent {
        override val turnIndex: Int get() = 0
    }

    data class Failed(val reason: String) : CloudEvent {
        override val turnIndex: Int get() = 0
    }

    data class Finished(
        val text: String,
        val reason: String,
        val turns: Int,
    ) : CloudEvent {
        override val turnIndex: Int get() = turns
    }
}

/**
 * 计划的一步（供 UI 渲染）—— 与旧 `dev.heracles.agent.TaskPlan.Step` 同形。
 *
 * 刻意不复用旧类型：`CloudAgentPipeline` 的隔离原则是不依赖
 * `dev.heracles.agent` 的内部模型，由适配层翻译。
 */
data class PlanStepView(val text: String, val status: PlanStatusView)

/** 计划步骤状态。 */
enum class PlanStatusView { PENDING, ACTIVE, DONE }
