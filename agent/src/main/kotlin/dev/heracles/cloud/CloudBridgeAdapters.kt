package dev.heracles.cloud

import dev.heracles.agent.AgentEvent
import dev.heracles.agent.AgentLoop
import dev.heracles.agent.ApprovalMode
import dev.heracles.cloud.tool.ToolRunStatus
import dev.heracles.core.tool.ToolCall

/**
 * **把新管线接到现有基础设施上的适配层**（2026-10-21）。
 *
 * ## 为什么需要它
 *
 * `dev.heracles.cloud` 的隔离原则是"不 import `dev.heracles.agent` 的内部类型"。
 * 但真实装配必须用**已有的**审批队列与 UI 事件通道 —— 否则要么重写一套（重复），
 * 要么让管线直接依赖旧类型（破坏隔离）。
 *
 * ⇒ 用适配器做**单向翻译**：旧类型 → 新接口（审批），新事件 → 旧事件（UI）。
 * 两个方向都只依赖**公开** API，管线本身仍然不知道 `AgentLoop` 的存在。
 */
object CloudBridgeAdapters {

    /**
     * 把旧的 `AgentLoop.AskReplyQueue` 适配成新的 [AskGate]（2026-10-21）。
     *
     * ## 契约对齐
     *
     * 1. **先发事件再挂起** —— 事件由管线自己发（`CloudEvent.AskUser`），
     *    本适配器只负责"等回答"，所以它拿到的已经是"UI 已知情"的状态。
     * 2. **超时返回 `null`** —— 管线据此如实告诉模型"用户没回答"，
     *    模型自己决定下一步。**绝不编造答案**。
     * 3. 返回**渲染好的人话**（不是原始 Map）—— 与旧 `AskAnswers.render` 一致：
     *    工具结果越像"用户说的话"，模型越不容易把它当成新指令。
     */
    fun askGate(queue: AgentLoop.AskReplyQueue): AskGate = object : AskGate {
        override suspend fun awaitAnswers(
            questions: List<dev.heracles.core.tool.AskQuestion>,
        ): String? {
            // `await()` 返回 null = 超时/取消 ⇒ 如实返回 null（不编答案）
            val answers = queue.await() ?: return null
            // 空 answers（用户一题没答）也算"没回答"，但不是超时 —— 仍如实渲染
            return answers.render(questions)
        }
    }

    /**
     * 把旧的 `AgentLoop.ApprovalQueue` 适配成新的 [ApprovalGate]。
     *
     * ## 与旧 `AgentLoop.approve()` 的语义对齐（必须一致）
     *
     * | 情形 | 旧 `AgentLoop` | 本适配器 |
     * |---|---|---|
     * | FULL_ACCESS 档 | 直接放行，**不发事件** | 直接 `true`，**不问队列** |
     * | `ALLOW_ONCE` | 执行 | `true` |
     * | `ALLOW_ALWAYS` | 执行 + 记签名 | `true`（队列内部已记账） |
     * | `DENY` | 失败回填 | `false` |
     * | 超时（`await` 返回 null） | 按**未执行**失败回填（绝不放行） | `false` |
     *
     * ⚠️ **超时必须是 false**：`await()` 返回 `null` 表示超时，
     * 绝不能当"允许"（那是"没人看的时候自动放行"）。
     *
     * @param mode 当前审批档位。`FULL_ACCESS` 时本适配器**永不**触碰队列。
     * @param queue 旧审批队列（UI 侧 `replyApproval` 往里投决定）
     * @param emitEvent 把审批请求转成旧 `AgentEvent.ApprovalRequest` 发给 UI
     */
    fun approvalGate(
        mode: ApprovalMode,
        queue: AgentLoop.ApprovalQueue,
        emitEvent: (AgentEvent) -> Unit,
    ): ApprovalGate = object : ApprovalGate {
        override suspend fun requestApproval(
            tool: String,
            args: Map<String, String>,
            reason: String,
        ): Boolean {
            // ★ FULL_ACCESS：**不弹窗**（用户已显式选"完全访问"）。
            //   这条与 2026-10-21 BUG-1 的修法一致 —— 档位判断必须在**每一层**都成立，
            //   任何一层漏判都会把用户拽回弹窗。
            if (mode == ApprovalMode.FULL_ACCESS) return true

            // 发事件让 UI 弹窗
            emitEvent(
                AgentEvent.ApprovalRequest(
                    index = 0,
                    call = ToolCall(tool, args),
                    reason = reason,
                )
            )

            // 挂起等用户决定。`null` = 超时 ⇒ **false**（绝不放行）
            return when (queue.await()) {
                AgentLoop.ApprovalDecision.ALLOW_ONCE,
                AgentLoop.ApprovalDecision.ALLOW_ALWAYS,
                -> true
                AgentLoop.ApprovalDecision.DENY -> false
                null -> false
            }
        }
    }

    /**
     * 把新管线的 [CloudEvent] 翻成旧的 [AgentEvent]（UI 已经在消费后者）。
     *
     * ## 为什么要翻译而不是让 UI 同时认两套
     *
     * Dart 侧 `chat_screen.dart` 有约 15 个 `case AgentEvent.kXxx` 分支。
     * 让 UI 认两套事件 = 两处真相 + 两套测试。翻译层只有一处，删掉新管线时
     * 这层也一起删，UI 零改动。
     *
     * ## 翻译口径（**不伪造信息**）
     *
     * | CloudEvent | AgentEvent | 说明 |
     * |---|---|---|
     * | `TurnStarted(i)` | `TurnStarted(i)` | 一一对应 |
     * | `ModelOutput(t, text, n, finish)` | `ModelOutput` | `finishReason` 直接透传 |
     * | `ToolFinished(name, status)` | `ToolFinished` 或 `Blocked` | 失败/未执行 ⇒ Blocked（UI 画拦截卡） |
     * | `Warning(msg)` | `Blocked(0, null, msg)` | 没有"警告"事件类型，用 Blocked 承载 |
     * | `Failed(reason)` | `Failed(reason)` | 一一对应 |
     * | `Finished(text, reason, turns)` | `Finished(...)` | 一一对应 |
     *
     * ⚠️ 未知事件返回 `null`（调用方跳过）—— **不猜、不编造**一个事件。
     */
    fun toLegacyEvent(e: CloudEvent): AgentEvent? = when (e) {
        is CloudEvent.TurnStarted -> AgentEvent.TurnStarted(e.turnIndex)

        is CloudEvent.ModelOutput -> AgentEvent.ModelOutput(
            index = e.turnIndex,
            raw = e.text,
            cache = dev.heracles.core.provider.CacheStats.withoutCacheReporting(0, 0),
            wallMs = 0,
        )

        is CloudEvent.ToolFinished -> when (e.status) {
            ToolRunStatus.OK -> AgentEvent.ToolFinished(
                index = e.turnIndex,
                call = ToolCall(e.toolName, emptyMap()),
                result = "",
                ok = true,
                wallMs = 0,
            )
            else -> AgentEvent.Blocked(
                index = e.turnIndex,
                call = ToolCall(e.toolName, emptyMap()),
                reason = when (e.status) {
                    ToolRunStatus.SCHEMA_INVALID -> "参数不符合 Schema，未执行：${e.toolName}"
                    ToolRunStatus.UNKNOWN_TOOL -> "未知工具：${e.toolName}"
                    ToolRunStatus.NOT_EXECUTED -> "未执行（超出单轮上限）：${e.toolName}"
                    ToolRunStatus.NEEDS_APPROVAL -> "需要用户确认或已被拒绝：${e.toolName}"
                    else -> "工具失败：${e.toolName}"
                },
            )
        }

        is CloudEvent.Warning -> AgentEvent.Blocked(0, null, e.message)

        is CloudEvent.Failed -> AgentEvent.Failed(e.reason)

        is CloudEvent.Finished -> AgentEvent.Finished(
            finalText = e.text,
            stopReason = e.reason,
            turnCount = e.turns,
        )

        // ---------- 计划（2026-10-21）----------
        //
        // 新管线每次发**全量**步骤列表（增量的状态机在 UI 侧更难对）。
        // 旧 UI 用 `PlanCreated(steps)` 重建清单 + `PlanAdvanced(done, active)` 更新进度
        // ⇒ 一条 `PlanUpdated` 翻成**两条**旧事件。调用方按顺序发即可。
        //
        // ⚠️ 这里只返回**第一条**（`PlanCreated`）；第二条由
        //    [toLegacyEvents] 一起给出。单返回值接口无法表达一对多。
        is CloudEvent.PlanUpdated -> AgentEvent.PlanCreated(
            index = e.turnIndex,
            steps = e.steps.map { it.text },
        )

        // ---------- ask_user（2026-10-21）----------
        is CloudEvent.AskUser -> AgentEvent.AskUser(
            index = e.turnIndex,
            questions = e.questions,
            call = ToolCall(e.call.name, emptyMap()),
        )
    }

    /**
     * **一对多**的事件翻译入口 —— 推荐用这个，而不是 [toLegacyEvent]。
     *
     * 有些新事件要翻成多条旧事件（例如 `PlanUpdated` ⇒
     * `PlanCreated` + `PlanAdvanced`，因为旧 UI 用两个事件分别画清单和进度）。
     * 单返回值接口表达不了，所以额外提供本方法。
     *
     * **不需要翻译的事件返回空列表**（不是返回一个错的事件）。
     */
    fun toLegacyEvents(e: CloudEvent): List<AgentEvent> = when (e) {
        is CloudEvent.PlanUpdated -> listOf(
            AgentEvent.PlanCreated(
                index = e.turnIndex,
                steps = e.steps.map { it.text },
            ),
            AgentEvent.PlanAdvanced(
                index = e.turnIndex,
                doneCount = e.doneCount,
                activeIndex = e.activeIndex,
            ),
        )
        else -> toLegacyEvent(e)?.let { listOf(it) } ?: emptyList()
    }

    /**
     * **计划 ↔ 落盘模型**的转换（2026-10-21）。
     *
     * ## 为什么放在这里而不是 `AgentBridge` 里
     *
     * 落盘文件是 `.heracles/plans/<sessionId>.json`，**新旧管线共用一个文件**
     * （切换管线时计划不丢）。旧管线用的是 `AgentLoop` 的 `TaskPlan.toJson()` 形状，
     * 所以新管线必须能**双向**转：
     *
     * ```
     * List<PlanStepView>  →  TaskPlan  →  toJson()   （写）
     * fromJson()  →  TaskPlan  →  List<PlanStepView> （读）
     * ```
     *
     * 放在 `AgentBridge`（Android 模块）里就**测不到**（纯 JVM 单测跑不了 Android）。
     * 放在这里 ⇒ `CloudPlanPersistenceTest` 能覆盖往返一致性。
     *
     * ⚠️ 顺序必须保持（计划步骤的先后是语义的一部分）。
     */
    fun toTaskPlan(steps: List<PlanStepView>): dev.heracles.agent.TaskPlan =
        dev.heracles.agent.TaskPlan(
            steps.map { s ->
                dev.heracles.agent.TaskPlan.Step(
                    text = s.text,
                    status = when (s.status) {
                        PlanStatusView.DONE -> dev.heracles.agent.TaskPlan.Status.done
                        PlanStatusView.ACTIVE -> dev.heracles.agent.TaskPlan.Status.active
                        PlanStatusView.PENDING -> dev.heracles.agent.TaskPlan.Status.pending
                    },
                )
            }
        )

    /** 反向：[TaskPlan] → [PlanStepView]（读回落盘计划）。 */
    fun toPlanStepViews(plan: dev.heracles.agent.TaskPlan): List<PlanStepView> =
        plan.steps.map { s ->
            PlanStepView(
                text = s.text,
                status = when (s.status) {
                    dev.heracles.agent.TaskPlan.Status.done -> PlanStatusView.DONE
                    dev.heracles.agent.TaskPlan.Status.active -> PlanStatusView.ACTIVE
                    dev.heracles.agent.TaskPlan.Status.pending -> PlanStatusView.PENDING
                },
            )
        }

    /**
     * 把旧 `history: List<Pair<String,String>>` 翻成新管线的 `List<AgentMessage>`。
     *
     * 顺序必须与真实发生一致（user → assistant → user → assistant），
     * 否则模型的因果理解会错乱（旧 `AgentLoop` 的注释也强调这一点）。
     */
    fun toAgentMessages(history: List<Pair<String, String>>): List<dev.heracles.cloud.context.AgentMessage> {
        val out = mutableListOf<dev.heracles.cloud.context.AgentMessage>()
        for ((user, assistant) in history) {
            if (user.isNotBlank()) {
                out += dev.heracles.cloud.context.AgentMessage(
                    dev.heracles.cloud.context.MessageRole.USER, user,
                )
            }
            if (assistant.isNotBlank()) {
                out += dev.heracles.cloud.context.AgentMessage(
                    dev.heracles.cloud.context.MessageRole.ASSISTANT, assistant,
                )
            }
        }
        return out
    }
}
