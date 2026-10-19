package dev.heracles.agent

import dev.heracles.core.context.PrefixBuilder
import dev.heracles.core.context.Session
import dev.heracles.core.context.SkillIndexEntry
import dev.heracles.core.context.Turn
import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.GenerateResult
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.ProviderCallException
import dev.heracles.core.provider.ReasoningLevel
import dev.heracles.core.provider.StructuredSpec
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolCall
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.WorkspaceFs
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking

/**
 * Agent 循环 —— 把 `:core` 的机制、provider 的后端、workspace 的文件
 * 串成**一次完整的对话轮次**。
 *
 * ## 这个类是之前架构的缺口
 *
 * `12-模块与文件清单.md` 原本**没有 `:agent` 模块** ——
 * 实现时才发现：没有它，CLI 与将来的 App 会各自重复实现一遍循环。
 * 这与 `14-框架验证报告.md` 问题 2「约束派生文件」是同一类遗漏。
 *
 * ## 云端没有 GBNF，怎么保证输出可解析
 *
 * 本地走 GBNF（强约束），**云端不支持 GBNF**（`02-契约规范.md` §6 的降级规则）。
 * 所以这里用三层兜底：
 *
 * | 层 | 手段 |
 * |---|---|
 * | 1 | `response_format: json_object` |
 * | 2 | 提示词明确给出输出格式与示例 |
 * | 3 | **解析失败时不执行任何工具**，并把失败原因 append 回去让模型重试 |
 *
 * 第 3 层是关键 —— 宁可让模型重试一次，也**不能猜**它的意图。
 *
 * ## 铁律 1 的落实
 *
 * 每轮都通过 [Session.append] 追加，**永不改写**。
 * 这也是缓存命中的前提（append-only 稳态 90–99%，`实测-01` / `实测-07`）。
 */
/**
 * **审批档位**（2026-10-19，把 UI 的 `PermissionMode` 真正接到执行层）。
 *
 * 与 `AgentLoop.ApprovalQueue` 配合：
 * · [MANUAL]：写文件 / 执行命令等**有副作用**的工具，执行**前**先问用户（Allow/Deny）
 * · [WORKSPACE_AUTO]：默认 —— 工作区内自动放行；只有工具自己返回 `NeedsApproval`
 *   （如命令守卫判定"递归删除 / 装 APK"）时才问
 * · [FULL_ACCESS]：连 `NeedsApproval` 也**自动放行**（用户已显式选择"完全访问"）
 *
 * ⚠️ 名字与 Dart 的 `PermissionMode` 一一对应，但**故意不共享**：
 * `:agent` 不得依赖 Flutter；装配处（`AgentBridge`）做字符串映射，映射表只有一处。
 */
enum class ApprovalMode {
    MANUAL,
    WORKSPACE_AUTO,
    FULL_ACCESS;

    companion object {
        /** 认不出 / null ⇒ [WORKSPACE_AUTO]（与改动前行为一致，最保守的默认）。 */
        fun parse(raw: String?): ApprovalMode = when (raw?.trim()?.lowercase()) {
            "manual" -> MANUAL
            "fullaccess", "full_access" -> FULL_ACCESS
            else -> WORKSPACE_AUTO
        }
    }
}

class AgentLoop(
    private val provider: ModelProvider,
    private val workspace: WorkspaceFs,
    private val tools: List<AgentTool>,
    /**
     * **长尾工具** —— 只有被 `search_tools` 披露过才可能被调用（ADR-023）。
     *
     * ## 为什么不能直接塞进 [tools]
     *
     * 契约 §4.1 与门禁 G11：常驻工具数 ≤ `Contract.Tools.FROZEN_LIMIT`（12），
     * 而编码层一次新增 9 个长尾工具。全塞进去会撑爆冻结区，同时**可见工具过多会
     * 降低选择准确率**（该规律的原始实测是在 4B 上做的，云端阈值更宽但同样存在）。
     *
     * 默认空列表 ⇒ 老调用方（CLI / 测试）行为**逐字节不变**。
     */
    private val longTail: List<AgentTool> = emptyList(),
    /**
     * 本会话**已披露**的工具名。由调用方持有，并与
     * `SearchToolsTool` **共享同一个实例** —— 否则披露了却调不动。
     *
     * 会话内只增不减：一旦披露就长期可用（若"下一轮又收回"，
     * 模型会因为工具突然消失而反复重试）。
     */
    private val disclosed: MutableSet<String> = mutableSetOf(),
    private val systemPrompt: String = DEFAULT_SYSTEM_PROMPT,
    private val skillIndex: List<SkillIndexEntry> = emptyList(),
    /**
     * **单任务最大推理轮次** —— 默认 [Contract.Budget.MAX_TURNS]（40）。
     *
     * ## ⚠️ S2：**字面量 8 没了**（这是本轮最大的一次行为变更）
     *
     * 改造前这里是硬编码 `8`，而 `MainActivity` **从不传参** ⇒ 真机上恒定 8 轮，
     * UI 无法调（`docs/27` §2.2）。云端模型用它跑「脚手架 → 改码 → 构建」必然撞墙
     * （实测症状：`达到最大轮次（8），任务未完成`，`实测-12` §14.2）。
     *
     * S1b 时"发行版走 `Contract.Budget.MAX_TURNS`、CLI/单测默认仍是 8"是**两处真相**；
     * S2 把默认值接到契约 ⇒ **一个来源**。代价（**必须知情**）：
     * **CLI / 单测不传参时也从 8 变成 40** —— 靠"轮次上限恰好是 8"兜底的用例会变行为，
     * 所以凡是要"跑满轮次"的用例都应**显式传** `maxTurns`（既有用例已经这么做了）。
     *
     * 用户仍可从设置调小（`AgentBridge` 的 `maxTurns > 0` 覆盖）。
     */
    private val maxTurns: Int = Contract.Budget.MAX_TURNS,
    /**
     * **单任务工具调用总预算**（ADR-033 / P0-1，2026-10-18）—— 默认 [Contract.Budget.MAX_TOOL_CALLS]（120）。
     *
     * ## 为什么要有它（它不是新发明的，是**接线**）
     *
     * 这个数早在契约里写了，但 2026-10-18 之前**全仓库只在定义处出现** ——
     * 一个从未被执行的"安全阀"（`docs/27` §2.2 挖出来的）。真实后果是：
     * 模型可以在一轮里无限制地调工具，只受 [maxTurns] 约束，
     * 而 [maxTurns] 之前是"轮"不是"次"，一次循环里多次工具调用不受限。
     *
     * ## 与 [maxTurns] 的区别
     *
     * · [maxTurns]：**推理轮数**（每次模型输出 = 一轮）
     * · 本参数：**工具执行次数**（一个计划/一次批量调用可能在一轮里跑多次）
     *
     * 两个预算都要有，否则"轮数少但每次狂调工具"仍然能烧穿时间与电量。
     *
     * ⚠️ **S2 起这里是唯一来源**（S1b 时默认值另有 `Contract.Safety.DEFAULT_MAX_TOOL_CALLS` = 30，
     * 发行版显式传 120；`Safety` 已删，装配处也不再重复传）。
     */
    private val maxToolCalls: Int = Contract.Budget.MAX_TOOL_CALLS,
    /**
     * **连续工具执行失败上限**（ADR-033 / P0-1，2026-10-18）—— 超限熔断停止。
     * 默认 [Contract.Budget.MAX_CONSECUTIVE_FAILURES]（6）。
     *
     * ⚠️ 与 [CONSECUTIVE_UNPARSEABLE_LIMIT]（连续**解析**失败，阈值 2）是**两件事**：
     * 那个数"模型输不出可解析的东西"，这个数"工具真的执行失败了"。
     * `成功` 会把计数器清零（偶发失败不算系统性问题）；
     * `需要用户确认` **既不增也不清零**（它不是失败，也不代表进展）。
     */
    private val maxConsecutiveFailures: Int = Contract.Budget.MAX_CONSECUTIVE_FAILURES,
    /**
     * 每轮最大输出 token。
     *
     * ## 默认值为什么从 1024 提到 4096（2026-10-14 真机修复）
     *
     * 用户实测（云端 `deepseek-v4-flash-0731`，思考模型）：
     * 连续两轮「输出无法解析：输出为空」——
     *
     * ```
     * 第 4 轮 4553ms → 输出无法解析：输出为空
     * 第 5 轮 6565ms → 输出无法解析：输出为空
     * ```
     *
     * **根因**：`max_tokens = 1024` 里思考把预算吃光，
     * 正文 `content` 为空 → 解析失败 → 重试 → 再吃光 → 熔断。
     *
     * ## 为什么工具调用不需要更大，但思考模型需要
     *
     * 纯工具调用的 JSON 很短（几十 token），1024 绰绰有余；
     * 但**思考模型的思考也算在 max_tokens 内** ——
     * 1024 对它是"思考都不够用"。
     *
     * 4096 的取舍：
     * · 足够思考 + 一个完整工具调用（含 CDATA 写文件的中等内容）
     * · 远小于云端模型的上限，不会因超限被拒
     * · 本地 llama.cpp 由调用方显式传小值（4096 上下文装不下大输出）
     */
    private val maxOutputTokens: Int = 4096,
    /**
     * 调试模式：每轮打印模型原始输出。
     *
     * **不是开发残留** —— `实测-05` 的教训是"缓存与模型行为不可假设，只能观测"。
     * 死循环、格式漂移这类问题，不看原始输出就只能靠猜。
     * 用环境变量 `HERACLES_DEBUG=1` 打开。
     */
    private val debug: Boolean = System.getenv("HERACLES_DEBUG") == "1",
    /**
     * **实时事件回调**（2026-10-10）。可选，默认 `null` ——
     * 现有调用方（CLI / android-probe / AgentBridge）不传就完全保持原行为。
     *
     * 事件只是**通知**：
     * - 不参与 prompt 构造，不改 append-only（铁律 1）
     * - 不影响 [run] 的返回值
     * - 回调抛异常会被 [emit] 吞掉 —— UI 的 bug 不该搞挂 agent
     *
     * ## ★ 2026-10-12 起这里会收到**两种粒度**的事件
     *
     * | 粒度 | 类 | 频率 |
     * |---|---|---|
     * | 轮级 | `TurnStarted` / `ModelOutput` / `ToolStarted` … | 一轮几条 |
     * | **token 级** | `StepStarted` / `ReasoningDelta` / `StepDelta` / `StepEnded` | 一轮几百条（**已合并**） |
     *
     * token 级事件在 [AgentLoop] 内部**已经过 [StreamCoalescer] 批量合并**
     * （默认 16 ms / 48 字符取先到者）。所以收事件的一端**不需要再节流** ——
     * 但若它自己要跨线程（如 Android 主线程 post），应知道合并后
     * 仍是"每 16 ms 一批"，而不是"每 token 一次"。
     */
    private val onEvent: ((AgentEvent) -> Unit)? = null,
    /**
     * **一个步骤的最终过程落盘回调**（2026-10-12，S5）。
     *
     * ## 它解决什么
     *
     * 用户报的 bug 照录：
     * > "我从会话1切换会话2，前面几轮输出的工作步骤不见了……
     * >  但是它已经生成的步骤会消失"
     *
     * 根因是过程（思考 + 叙述）**从来没有落盘** —— 只活在
     * [AgentEvent.StepDelta] / [AgentEvent.ReasoningDelta] 的内存缓冲里。
     *
     * ## ★ 为什么用"回调"而不是让 AgentLoop 自己写文件
     *
     * `:agent` 不认识 `WorkspaceStorage`，也不该认识 ——
     * 那是 `:workspace` + Android 侧的事（分层，见 `01-架构总览.md`）。
     * 让 AgentLoop 直接落盘会把文件系统语义拽进核心循环。
     *
     * ## ★★ 调用时机：**一步一次，在 StepEnded 之后**
     *
     * 不是每 token 一次。理由（与 `SessionStore.appendStep` 的说明同一套）：
     * 1. **频率与步数同阶**（一轮 1 次），而不是与 token 数同阶；
     * 2. **切走的窗口最小** —— 这一步一结束就在磁盘上，
     *    此后任何时刻切会话都能读回。若攒到 `run()` 返回才写，
     *    用户中途切走时**整轮的步骤都不在磁盘上**，那正是他抱怨的现象。
     *
     * ## 参数
     *
     * @param index 第几轮（`turnIndex`，1 起）—— 与行级记录对齐用
     * @param stepId 步骤标识（`turn-3`）
     * @param thinking **思考全文**（不是增量；已过 [ThinkingBudget] 的截流，
     *   所以它与用户在界面上**实际看到的**思考一致 ——
     *   落盘的东西必须与看到的东西一致，否则用户会以为界面骗了他）
     * @param text 该步的正文全文
     * @param status [AgentEvent.StepEnded] 的三态字符串
     * @param durationMs 墙钟耗时
     * @param title 人可读标题（`StepStarted` 的那个）
     *
     * ## 异常处理
     *
     * 回调抛异常由 [emitStepEnded] **吞掉并留痕** —— 落盘失败绝不能
     * 把整轮 agent 搞挂（过程丢了还能重跑，结果丢了更糟）。
     */
    private val onStepEnded: ((
        index: Int,
        stepId: String,
        thinking: String,
        text: String,
        status: String,
        durationMs: Long,
        title: String,
    ) -> Unit)? = null,
    /**
     * **推理档位** —— 决定要不要开思考、以及（云端）思考多深。
     *
     * 默认 [ReasoningLevel.AUTO]：本地实现按"关思考"处理（省时间，
     * 且**关思考时后端一个 reasoning_content 都不返回**，所以不会有
     * 空思考区）。用户想看思考必须在 UI 上显式调到 `LOW` 及以上。
     *
     * ⚠️ **开了思考就必须配合思考预算** —— 见 [ThinkingBudget]：
     * 实测（`25` §12.1）思考会吃光整个 `max_tokens`，导致正文 0 字符、
     * 永远出不了工具调用。这不是"慢"，是**完全不可用**。
     */
    private val reasoningLevel: ReasoningLevel = ReasoningLevel.AUTO,
    /**
     * **用户插话队列**（2026-10-13，思考间隙引导）。
     *
     * ## 语义（用户原话，逐字）
     *
     * 「注意不是第一个任务结束，是第一个任务的**当前的思考过程结束了**
     * 再引导」—— 第一个任务跑到第 N 步，用户发第二条消息并选"插话"；
     * 等当前这步（思考）结束，模型在下一轮**看到**插话，
     * 自行比对原任务：是修改、追加还是删除，然后重新调整接下来的任务。
     *
     * ## 为什么是"轮间注入"而不是"打断流式"
     *
     * 打断流式 = 截断思考，模型正在写的那一步残废。
     * 轮间注入 = 等**当前轮完整结束**（思考+正文+工具调用都已 append），
     * 在下一轮 `TurnStarted` **之前**把插话 `Turn.User` append 进去 ——
     *
     * 1. **会话保持 append-only**（铁律 1）：插话只是追加，不改写历史，
     *    缓存前缀依然逐字节复用；
     * 2. **模型自己消化冲突**：下一轮的 prompt 自然包含
     *    原任务 + 已完成的步骤 + 插话 —— 比对、修正、调整待办
     *    是模型的能力，不需要 UI 或桥接层代劳"分析冲突"；
     * 3. **不打断已排期的工具调用**：当前轮发出的工具会执行完，
     *    其结果也在下一轮可见 —— 插话后的调整建立在实际完成的事之上。
     *
     * ## 接线方式：挂起式取件
     *
     * `:agent` 不知道谁在投递（UI/桥/测试），只认这个队列的
     * `drain()`。默认 [InterruptQueue.EMPTY] = 无插话能力，
     * 既有调用方零改动。
     */
    private val interruptQueue: InterruptQueue = InterruptQueue.EMPTY,

    /**
     * **ask_user 工具的回答通道**（2026-10-16 新增）。
     *
     * 模型调 `ask_user` 工具时挂起等待；UI 弹窗收集回答后 `reply()`。
     * 默认 [AskReplyQueue.EMPTY] = 无 ask 能力（CLI/测试零改动）。
     */
    private val askReplies: AskReplyQueue = AskReplyQueue.EMPTY,

    /**
     * **危险工具的用户审批通道**（2026-10-19）。
     *
     * 工具返回 [ToolOutcome.NeedsApproval] 时，`AgentLoop` 发 [AgentEvent.ApprovalRequest]
     * 并挂起在这里等用户决定；UI 点「允许 / 拒绝」后 `reply()`。
     *
     * 默认 [ApprovalQueue.EMPTY] = **无 UI ⇒ 立即拒绝**（CLI / 测试 / 自动化都安全）：
     * 既不会挂 10 分钟，也绝不会在没人看的情况下放行危险命令。
     */
    private val approvalReplies: ApprovalQueue = ApprovalQueue.EMPTY,

    /**
     * **审批档位**（2026-10-19）—— 决定"什么操作要问用户"。
     *
     * 默认 [ApprovalMode.WORKSPACE_AUTO]：与接档位之前**行为一致**
     * （只在工具返回 `NeedsApproval` 时问）。见 [ApprovalMode] 的完整语义。
     */
    private val approvalMode: ApprovalMode = ApprovalMode.WORKSPACE_AUTO,

    /**
     * **上下文上限**（token，2026-10-16 压缩机制用）。
     *
     * 由调用方传入（AgentBridge 按后端类型区分：本地 4096 / 云端 128K）——
     * AgentLoop 不该自己猜（各模型差异大，见 modelCapabilities 的教训）。
     *
     * `<= 0` = 不压缩（未知上限时宁可不用压缩，也别错误地丢上下文）。
     */
    private val contextLimit: Int = 0,

    /**
     * **恢复的任务计划**（2026-10-19）。
     *
     * ## 为什么需要
     *
     * 计划活在 `AgentLoop` 内存里 ⇒ 重启 App / 切走再切回，`plan` 归零：
     * 用户看到的是"计划还在 UI 上"，但模型下一轮**完全不知道**自己在哪一步。
     *
     * 装配处（`AgentBridge`）按 `sessionId` 从 `.heracles/plans/<sid>.json` 读回来传这里；
     * 传 `null` = 新会话 / 没有可恢复计划（与改动前行为一致）。
     *
     * ⚠️ 恢复的计划**不重发 `PlanCreated`** 事件：UI 从会话记录重建计划，
     * 这里只负责"模型侧的记忆"。
     */
    private val initialPlan: TaskPlan? = null,

    /**
     * **计划变更回调**（2026-10-19）—— 装配处据此落盘。
     *
     * 时机：产出计划 / `update_plan` / 自动推进。参数是**最新完整计划**。
     * 回调在 `run` 的 IO 上下文里同步调用 ⇒ 实现必须自己保证不抛（`runCatching`）。
     */
    private val onPlanChanged: (suspend (TaskPlan) -> Unit)? = null,

    /**
     * **冻结区常驻工具上限**（2026-10-18，ADR-033 / P2-3；S1b 起只有一档）。
     *
     * 默认 [Contract.Tools.FROZEN_LIMIT]（= 12）。原先它按后端给档
     * （本地 8 / 云端 12，`Contract.Zone.maxFrozenFor(backend)`）；本地后端删除后
     * `Zone` 已删，装配处**不再需要**按后端传 —— 传值只为测试构造越档场景。
     *
     * ⚠️ 计数包含 `search_tools` 元工具：它由装配处追加进 [tools]，
     * 而它一样要进冻结区（模型得知道有这个入口）。所以今天业务常驻 10 个
     * + 1 个元工具 = **11 ≤ 12**（只留 1 个空位）。
     */
    private val maxFrozenTools: Int = Contract.Tools.FROZEN_LIMIT,

    /**
     * 是否把**常驻工具**作为原生 `tools` 数组发出去（ADR-031 决策 2 的请求侧，F7b）。
     *
     * ## 默认 `false`，且这一步**刻意不发**（这不是保守，是安全）
     *
     * 响应侧（`tool_calls` → 工具执行的**同一条**中间表示）还没落地。
     * 现在把 `tools` 发出去，模型会改用原生通道回答，而我们只解析文本方言：
     * 正文为空 ⇒ "输出无法解析"熔断 —— 等于把今天**看得见**的失败
     * 换成"模型明明调了工具、却什么都没发生"的**静默失败**。
     *
     * ## 能力位 ≠ 启用（别把两件事混在一起）
     *
     * [dev.heracles.core.provider.ProviderCapabilities.supportsNativeTools] 是**声明**
     * （云端三家 `true` / 本地 `false`），本参数是**启用开关**。ADR-031 第 2 步落地后，
     * 由装配处显式打开：
     * `nativeToolsEnabled = provider.capabilities.supportsNativeTools`。
     * 在那之前，`supportsNativeTools = true` **不代表**"已经在用原生工具"。
     *
     * ## 本步的三条纪律（与 KDoc 一并钉住实现）
     *
     * 1. **只发常驻 [tools]**，不碰 [activeTools] —— 长尾是逐轮披露的，
     *    塞进数组会让数组变长 ⇒ 前缀每披露一次抖一次、缓存全塌
     *    （与门禁 G13 把长尾挡在冻结区外是同一个理由）。
     * 2. **顺序 = 装配给的候选顺序**，会话内恒定 ⇒ 前缀只变一次（不是每轮抖）。
     * 3. **开了原生就不再教文本方言**（F7c 硬前置）：两份指令并存时模型会把调用写进正文，
     *    而"原生优先"会忽略正文里的调用 ⇒ 白跑一轮且日志无错。见 [toolProtocol]。
     *
     * ⚠️ **ADR-035 S1b 删除了 `backend: String` 形参**（D2）：它活着的唯一理由是"选哪份协议文案"，
     * 而本地那份文案随本地后端一起退场（见 [TOOL_PROTOCOL_CLOUD] 的 KDoc）。
     * 现在协议只剩两个状态：**原生**（本开关为真）/ **云端文本**。
     */
    private val nativeToolsEnabled: Boolean = false,
    /**
     * **工作区快照注入开关**（F8a / P2-1「跨轮记忆」，2026-10-18）。
     *
     * ## ⚠️ 默认 `false`，而且**不许顺手开**
     *
     * F8a 的全部意义是"**零回退可证**"：开关关着时，整条链路的
     * prompt / 请求体 / 事件必须与改动前**逐字节相同** —— 这是**结构上不可能变**，
     * 不是"我们保证"：`snapshotInjectionEnabled = false` ⇒ 连
     * [WorkspaceSnapshot.render] 都不会被调用（`if` 之外没有任何副作用）。
     *
     * 功能要在 **F8b** 才开（"变更才注入" + compaction 交互做完之后）。
     *
     * ## 开的时候会发生什么
     *
     * 每轮在 `plan` 之后 append 一条 `Turn.User`（与 `renderProgressLedger`
     * 同一个槽位）⇒ **不动冻结前缀**、不改 `Session.render()`、严格 append-only。
     * 详见 [WorkspaceSnapshot] 的 KDoc。
     */
    private val snapshotInjectionEnabled: Boolean = false,
) {

    /**
     * **手动审批档位下"执行前必须先问用户"的工具**（2026-10-19）。
     *
     * 判据 = 有**文件系统 / 设备副作用**（写、删、移动、执行命令、构建/签名）。
     * 读类工具（read_file / list_files / find_files / grep_files）与元工具
     * （search_tools / update_plan）**不问** —— 问多了就是噪音，用户会条件反射点允许。
     */
    private val mutatingTools = setOf(
        "write_file", "apply_patch", "delete_path", "move_path", "copy_path", "mkdir",
        "run_shell_command", "scaffold_android", "build_apk", "apk_decompile",
        "apk_recompile", "apk_sign", "d8_convert", "unzip_file", "zip_file",
    )

    /**
     * 本会话真正用的**工具协议文案**。
     *
     * · 云端文本 = [TOOL_PROTOCOL_CLOUD]（`apply_patch` 常驻在手边 ⇒ 优先局部替换）
     * · **原生轨**（[nativeToolsEnabled]）= [TOOL_PROTOCOL_NATIVE]
     *
     * ⚠️ 原生那一档必须**先判**（F7c 硬前置 2）：开了原生 `tools` 就不能再教
     * JSON/标签方言，否则模型会把调用写进正文，而"原生优先"会**忽略**正文里的调用
     * ⇒ 白跑一轮且日志无错（静默失败）。详见 [TOOL_PROTOCOL_NATIVE] 的 KDoc。
     *
     * ⚠️ **ADR-035 S1b**：原先这里还有第三档"本地"（[TOOL_PROTOCOL]，760 字，**已删**）——
     * 它服务的是"4B 手里没有 `apply_patch`，提示局部替换等于教它调用一个手头没有的工具"，
     * 而 S1b 之后 `apply_patch` **全员常驻**、本地后端也随 ADR-035 退场 ⇒
     * 那一档**没有消费者**，留着就是不可达死代码。
     * ⇒ 协议现在只有**两态**：原生 / 云端文本。
     *
     * `internal` 是为了让测试能直接钉住"哪一档给了哪份文案"。
     */
    internal val toolProtocol: String =
        if (nativeToolsEnabled) TOOL_PROTOCOL_NATIVE else TOOL_PROTOCOL_CLOUD

    /**
     * 要作为原生 `tools` 数组发出去的**工具声明**（ADR-031 请求侧；2026-10-19 接线）。
     *
     * ## 为什么是函数而不是 val
     *
     * 长尾工具是**逐轮披露**的：`search_tools` 命中后 `disclosed` 会变，
     * 下一轮必须能真的调用它 —— 所以数组要按当前 [activeTools] **现算**。
     * 旧实现刻意只发常驻、把长尾留给文本轨；但原生轨一旦开启就**禁止再教文本方言**
     * （否则两套真相 ⇒ 模型把调用写进正文、原生优先忽略它 = 静默失败），
     * 于是"只发常驻"等于**长尾工具彻底不可用**。现在改成下发 activeTools()。
     *
     * ## 缓存代价（如实记）
     *
     * `tools` 数组变化会让把 tools 编进 prompt 的 provider **前缀失效一次**。
     * 代价只发生在"首次披露某个长尾工具"时（每会话至多 N 次），
     * 换来的是长尾工具在原生轨可用 —— 这是 ADR-031 请求侧的已知取舍。
     *
     * 默认 `nativeToolsEnabled = false` ⇒ **空列表** ⇒ 文本轨请求体逐字节不变。
     */
    internal fun nativeToolSpecs(): List<dev.heracles.core.tool.ToolSpec> =
        if (nativeToolsEnabled) activeTools().map { it.spec } else emptyList()

    /**
     * 冻结区 —— 会话内**逐字节不变**（`02-契约规范.md` §1）。
     *
     * ## 为什么要块对齐（`实测-08` 的教训）
     *
     * 首次端到端实测发现**5 轮全部命中 0.0%**，而 `实测-07` 明明测出
     * DashScope 命中 73%。根因是**冻结区只有 513 token，不足一个 1024 块**。
     *
     * 云端按块缓存 → 不足一块 = 完全不命中。
     * 所以这里按 provider 的 `cacheBlockTokens` 补齐：
     * - 云端（1024）：补齐到块边界的略上方
     * - 本地（1）：**不补齐**，token 级精确复用不需要，补了纯属浪费
     */
    val frozenPrefix = PrefixBuilder.buildFrozenAligned(
        // ★ F3c：工具协议进冻结前缀 —— 文本轨 / 原生轨各一份（S1b 起只有这两态）。
        //   代价：改文案 = **跨构建首次 prefix cache miss 一次**。
        systemPrompt = systemPrompt + "\n\n" + toolProtocol,
        tools = tools.map { it.spec },
        skillIndex = skillIndex,
        cacheBlockTokens = provider.capabilities.cacheBlockTokens,
        // ★ 上限（S1b 起唯一一档 = 12）：越档在这里**当场抛**，不静默截断。
        maxFrozen = maxFrozenTools,
    )

    /**
     * 本会话**当前可用**的工具 = 常驻 [tools] + 已被披露的长尾（ADR-023）。
     *
     * ## 为什么它只喂 grammar 与派发，**不喂 [frozenPrefix]**
     *
     * 长尾工具的 schema **不得**进冻结区（门禁 G13）：否则每披露一个工具，
     * 前缀就长一截 ⇒ 前缀缓存全塌，命中率从 90% 掉到 0。
     *
     * 它的参数表是经 `search_tools` 的**工具结果**进入历史尾部的（可变区），
     * 而 grammar 是**请求参数**、不进前缀缓存 ⇒ 披露不影响 `cache_n`。
     *
     * ⇒ [frozenPrefix] 只装 [tools]（逐字节恒定），本函数只喂**调用派发**
     *   （以及文本轨的"可用工具名"提示）。
     */
    internal fun activeTools(): List<AgentTool> =
        if (disclosed.isEmpty()) tools
        else tools + longTail.filter { it.spec.name in disclosed }

    /**
     * 发一个事件。**绝不抛出** —— 监听方的异常不能影响 agent 主流程。
     *
     * 吞异常是有意的：UI 侧（EventChannel 已关闭、渲染出错）不该让
     * 一轮正在跑的 agent 崩掉。
     */
    private fun emit(event: AgentEvent) {
        // ★ 诊断计数：合并前后的事件条数对比（`AgentLoopStats`）。
        //   必须在这里计 —— 这是"真实发出去多少条"的唯一出口。
        stats.recordEmitted(event)
        val handler = onEvent ?: return
        runCatching { handler(event) }
    }

    /**
     * 一步结束 → 通知 [onStepEnded] 把**过程**落盘（2026-10-12，S5）。
     *
     * ## 为什么吞异常但**必须留痕**
     *
     * 落盘失败不能让 agent 挂（过程丢了还能重跑，整轮结果丢了更糟）——
     * 所以 `runCatching`。但**绝不能静默**：真机出问题时
     * "为什么切会话后步骤没了"只能靠这行日志定位。
     *
     * 用 `println` 而不是日志框架：与 `MainActivity` / `SessionStore`
     * 的既有做法一致（`HERC-PERSIST` 前缀便于 `adb logcat | grep`）。
     */
    private fun emitStepEnded(
        index: Int,
        stepId: String,
        thinking: String,
        text: String,
        status: String,
        durationMs: Long,
    ) {
        val handler = onStepEnded ?: return
        runCatching {
            handler(
                index,
                stepId,
                thinking,
                text,
                status,
                durationMs,
                "第 $index 轮",
            )
        }.onFailure {
            println("HERC-PERSIST 步骤落盘回调失败（不影响本轮运行）：${it.message}")
        }
    }

    /**
     * **合并效果诊断**（2026-10-12）。
     *
     * ## 为什么要有它
     *
     * 「批量合并」这件事**必须能被实测**，不能只在注释里声称。
     * 尤其是在**没有 UI 的 CLI 环境**里 —— 我们没法观察"主线程每秒被
     * 打断多少次"，只能数**事件条数**。
     *
     * 条数就是主线程压力的直接代理指标：每条事件 =（在 Android 上）
     * 一次 `Handler.post` + 一次 MethodChannel 编解码。
     *
     * ## 怎么读
     *
     * | 字段 | 含义 |
     * |---|---|
     * | [rawTokenEvents] | **假如不合并**会发出多少条 token 级事件（≈ chunk 数） |
     * | [coalescedTokenEvents] | 实际发出多少条 |
     * | [compressionRatio] | 压缩比（如 512 → 32 就是 16×） |
     *
     * 两者的差值就是合并省下的主线程消息数。
     */
    class AgentLoopStats {
        /** token 级原始增量数（每个 chunk 算一条；**未**经过合并） */
        var rawTokenEvents: Int = 0
            private set

        /** 实际发出的 token 级事件数（**已**合并） */
        var coalescedTokenEvents: Int = 0
            private set

        /** 轮级事件数（不受合并影响，仅作对照） */
        var turnLevelEvents: Int = 0
            private set

        /** 合并压缩比；无数据时为 1.0 */
        val compressionRatio: Double
            get() = if (coalescedTokenEvents == 0) 1.0
            else rawTokenEvents.toDouble() / coalescedTokenEvents

        /** 合并**省下**的主线程消息数 */
        val savedPosts: Int get() = (rawTokenEvents - coalescedTokenEvents).coerceAtLeast(0)

        internal fun countRawTokenDelta() {
            rawTokenEvents++
        }

        internal fun recordEmitted(event: AgentEvent) {
            when (event) {
                // token 级：合并前会是 rawTokenEvents 条，合并后是这些
                is AgentEvent.StepDelta, is AgentEvent.ReasoningDelta -> coalescedTokenEvents++
                // 其余（轮级 + 步骤边界）：不受合并影响，仅作对照
                else -> turnLevelEvents++
            }
        }

        override fun toString(): String =
            "原始 token 事件=$rawTokenEvents，合并后=$coalescedTokenEvents，" +
                "压缩比=${"%.1f".format(compressionRatio)}×，省下 $savedPosts 次主线程消息"

        /** 供测试/CLI 重置 */
        fun reset() {
            rawTokenEvents = 0
            coalescedTokenEvents = 0
            turnLevelEvents = 0
        }
    }

    /** 本次（或最近一次）[run] 的合并诊断 —— 见 [AgentLoopStats] */
    val stats: AgentLoopStats = AgentLoopStats()

    /**
     * **工作记忆**（2026-10-14，harness 核心机制之一）。
     *
     * ## 它解决什么（用户真机反馈）
     *
     * 用户截图里两轮的思考**极度相似**：
     *
     * > 第 3 轮思考：「用户想让我写一个HTML…我需要先查看现有的文件结构…」
     * > 第 4 轮思考：「用户要求我写一个 HTML…我之前列出了文件，然后读取了
     * >   index.html，现在需要生成…」
     *
     * 第 4 轮**已经知道**做过什么，但第 3 轮不知道 —— 因为 AgentLoop
     * 从不告诉模型"你已经做过什么"。每次生成都面对同样的
     * 「用户请求 + 历史输出」，模型只能重新推导一遍计划。
     *
     * ## 为什么这是 harness 的必需品而不是锦上添花
     *
     * DeepSeek 那段工程描述里的关键一条：
     * **「工作记忆：当前任务状态，存任务状态机」**。
     * 没有它，agent 每轮都在"重新开始想"，导致：
     * 1. **思考重复**（用户看到的直接现象）
     * 2. **上下文膨胀**（每轮都重新推导，token 白烧）
     * 3. **行为漂移**（同一件事的两次推导可能不一致）
     *
     * ## 设计：从 [TurnRecord] 派生，不引入新状态
     *
     * `records` 已经逐轮记录了**事实**（工具、结果、verdict）。
     * 工作记忆只是把那些事实**渲染成给模型看的一段文本** ——
     * 单一事实来源，不会与记账漂移。
     *
     * ## 与铁律 1 的关系
     *
     * 它作为 `Turn.User` **append** 进会话（不改写历史）——
     * 正是 ADR-006 要求的"重试必须通过 append 实现"。
     * 代价是每轮多几十 token；收益是模型不再重复推导。
     */
    private fun renderProgressLedger(records: List<TurnRecord>): String? {
        if (records.isEmpty()) return null
        val lines = mutableListOf<String>()
        for (r in records) {
            val t = r.toolCall
            val line = when {
                // 真的执行过工具
                t != null && r.toolSucceeded == true ->
                    "${r.index}. 已完成：${friendlyTool(t.tool)}（${t.args["path"] ?: t.args.values.firstOrNull() ?: "—"}）→ 成功"
                t != null && r.toolSucceeded == false ->
                    "${r.index}. 失败：${friendlyTool(t.tool)} → ${r.toolResult?.take(80) ?: "未知原因"}"
                // 请求了但被拦（没执行）
                t != null ->
                    "${r.index}. 被拦截：${friendlyTool(t.tool)}（${r.verdict.take(40)}）"
                // 没法解析
                r.verdict.startsWith("输出无法解析") ->
                    "${r.index}. 输出格式错误（没有执行任何操作）"
                else -> null
            }
            if (line != null) lines.add(line)
        }
        if (lines.isEmpty()) return null
        return buildString {
            append("【你已经完成的工作（真实执行记录，不要重新做）】\n")
            lines.forEach { append(it).append('\n') }
            append("\n请基于以上进度继续。**不要重复已经成功的操作**；")
            append("如果下一步需要的文件已经读过，直接用它；")
            append("如果任务已完成，直接输出 {\"final\":\"<对用户的总结>\"}。")
        }
    }

    /** 工具名 → 人话（与 Dart 侧 friendlyToolName 同语义）。 */
    private fun friendlyTool(tool: String): String = when (tool) {
        "list_files" -> "查看目录文件"
        "read_file" -> "读取文件"
        "write_file" -> "写入文件"
        else -> tool
    }

    /**
     * **实际发出去的输出预算**（2026-10-14，修"输出为空"）。
     *
     * ## 为什么需要"随档位放大"
     *
     * 思考模型的**思考也占用 `max_tokens`**。
     * 用户实测：推理等级 = **High** + `max_tokens = 1024`
     * → 思考吃光 → 正文为空 → 「输出无法解析：输出为空」×2 → 熔断。
     *
     * 档位越高，思考越长，预算必须跟着涨 —— 否则
     * "用户选了更强的推理"反而变成"什么都答不出来"。
     *
     * ## 为什么不无脑给很大
     *
     * · 本地 llama.cpp 的上下文只有 4096 —— 输出预算过大会挤压输入
     * · 云端按 token 计费，给满 32K 会让简单任务也付长输出的钱
     *
     * 所以按档位给出**够用且不浪费**的阶梯。
     */
    private fun effectiveMaxOutputTokens(): Int {
        val base = maxOutputTokens
        val scaled = when (reasoningLevel) {
            ReasoningLevel.OFF, ReasoningLevel.AUTO -> base
            ReasoningLevel.LOW -> base * 2
            ReasoningLevel.HIGH -> base * 3
            ReasoningLevel.MAX -> base * 4
        }
        // 上限保护：不超过契约允许的单轮输出上限
        return scaled.coerceAtMost(Contract.Inference.MAX_OUTPUT_TOKENS_CAP)
    }

    /**
     * 工作记忆的**测试入口**（2026-10-14）。
     *
     * 为什么需要它：`renderProgressLedger` 是私有的（不该被外部调用
     * —— 它是轮循环的内部机制），但它的**输出内容**是这次修复的
     * 核心契约（"必须包含已完成的事实"、"不得把拦截写成已完成"），
     * 必须有门禁。所以只暴露这一个纯函数的 view。
     */
    internal fun renderProgressLedgerForTest(records: List<TurnRecord>): String? =
        renderProgressLedger(records)

    /**
     * **三个预算字段的只读 view**（S1b 加，S2 起用途变了但**更有用**）。
     *
     * 为什么还需要它：S2 把默认值接到了 [Contract.Budget]，
     * 而"默认值真的接线了"**不能**只看契约常量（那看不出 `AgentLoop` 里有没有人又写回字面量）——
     * 尤其是 [maxTurns] 曾是硬编码 `8`：谁把 `Contract.Budget.MAX_TURNS` 换回 `8`，
     * 这条 view 上的断言会红。`private val` 在测试里读不到 ⇒ 只能开这个口子。
     */
    internal val maxTurnsForTest: Int get() = maxTurns

    /** 见 [maxTurnsForTest]。 */
    internal val maxToolCallsForTest: Int get() = maxToolCalls

    /** 见 [maxTurnsForTest]。 */
    internal val maxConsecutiveFailuresForTest: Int get() = maxConsecutiveFailures

    /**
     * **用户插话的投递通道**（2026-10-13，思考间隙引导）。
     *
     * ## 为什么是线程安全的链表队列
     *
     * 投递方（Android 主线程的 MethodChannel 回调）与
     * 取件方（agent 协程，在轮与轮的间隙）**必然跨线程**。
     * `ConcurrentLinkedQueue` 无锁、投递不阻塞 UI ——
     * agent 什么时候取由轮循环决定，与投递时机解耦。
     *
     * ## 语义
     *
     * - `offer(text)`：UI 层"插话"动作。**不抛异常**、不排队上限
     *   （上限是 UI 层的策略；核心层如实存储）。
     * - `drainAll()`：轮循环在**每轮开始前**取走全部待插话 ——
     *   每条独立 append 为一个 `Turn.User`，保持"一句一记录"。
     * - [EMPTY]：无插话能力的单例 —— 既有调用方（CLI/测试/旧桥）
     *   零改动，`drainAll()` 恒空。
     */
    class InterruptQueue {
        private val q = java.util.concurrent.ConcurrentLinkedQueue<String>()

        /** 投递一条用户插话（线程安全，永不抛出） */
        fun offer(text: String) {
            val t = text.trim()
            if (t.isNotEmpty()) q.offer(t)
        }

        /** 取走当前全部待插话（按投递顺序） */
        fun drainAll(): List<String> {
            val out = mutableListOf<String>()
            while (true) {
                val t = q.poll() ?: break
                out.add(t)
            }
            return out
        }

        val isEmpty: Boolean get() = q.isEmpty()

        companion object {
            /** 无插话能力 —— 既有调用方零改动 */
            val EMPTY = InterruptQueue()
        }
    }

    /**
     * **ask_user 工具的回答通道**（2026-10-16，用户需求「ask 功能」）。
     *
     * ## 它解决什么
     *
     * agent 卡住/信息不足时的三种坏反应：瞎猜、放弃、谎称完成。
     * （`实测-08`：模型曾谎称"已创建 2048 文件"——文件根本没写。）
     * **正确反应是问用户**——这正是 `04-抗幻觉设计.md` 的精神：
     * 不确定就问，不要编。
     *
     * ## 工作流（与 InterruptQueue 相反的方向）
     *
     * ```
     * 模型 → {"tool":"ask_user","args":{"question":"…"}} → 工具执行
     *        工具挂起等待 ←── [AskReplyQueue] ←── UI 弹窗 → 用户输入
     *        拿到回答 → 作为工具结果返回给模型 → 继续任务
     * ```
     *
     * `InterruptQueue` 是"用户主动插入"，这个是"模型主动请求"——
     * 方向相反，但通道模式相同（线程安全队列 + 挂起等待）。
     *
     * ## 超时
     *
     * 用户可能永远不回答（锁屏/离开）。**默认等 10 分钟**，
     * 超时后工具返回"用户未回答"，让模型自行决定（换做法或说明卡点）
     * —— 而不是让整轮永远挂着。
     */
    class AskReplyQueue(
        /** 等待用户回答的最长时间；超过则放行（不无限挂起）*/
        private val timeout: kotlin.time.Duration = kotlin.time.Duration.parse("10m"),
    ) {
        private val channel = kotlinx.coroutines.channels.Channel<String>(
            kotlinx.coroutines.channels.Channel.RENDEZVOUS,
        )

        /** UI 层投递用户的回答（弹窗提交时调用）*/
        fun reply(text: String) {
            val t = text.trim()
            // trySend：RENEZVOUS 模式下无接收者会失败 —— 但工具挂起在
            // receive 上，正常路径一定有接收者。失败只发生在"运行已结束"
            // （工具已超时放行），此时回答无意义，丢弃即可。
            channel.trySend(t)
        }

        /** 工具侧挂起等待回答；超时返回 null */
        suspend fun await(): String? = kotlinx.coroutines.withTimeoutOrNull(timeout) {
            channel.receive()
        }

        /** 无 ask 能力的单例 —— 既有调用方（CLI/测试）零改动 */
        companion object {
            val EMPTY = AskReplyQueue()
        }
    }

    /**
     * **用户对一次审批请求的决定**（2026-10-19）。
     *
     * · [ALLOW_ONCE]：只执行这一次
     * · [ALLOW_ALWAYS]：**本 run 内**同一工具 + 同一关键参数不再问
     *   （成熟产品的 "Always allow"；范围仅当前任务，不落盘 —— 跨 run 的持久白名单
     *   是另一个安全决定，不该顺手做）
     * · [DENY]：不执行，作为失败回填
     */
    enum class ApprovalDecision { ALLOW_ONCE, ALLOW_ALWAYS, DENY }

    /** 审批询问的结果（含"没人回答"这一种）。 */
    enum class ApprovalResult { ALLOWED, DENIED, TIMEOUT }

    /**
     * **危险操作的用户审批队列**（2026-10-19）。
     *
     * ## 语义
     *
     * 工具返回 `NeedsApproval` ⇒ `AgentLoop` 发 `ApprovalRequest` + 挂起 `await()`：
     * · UI 点「允许」⇒ `reply(ALLOW_ONCE)` ⇒ 重新执行那次调用
     * · UI 点「本会话始终允许」⇒ `reply(ALLOW_ALWAYS)` ⇒ 执行，且**本 run 内**记住签名
     * · UI 点「拒绝」⇒ `reply(DENY)` ⇒ 以失败回填给模型
     * · 超时 ⇒ `null` ⇒ 同样按"未执行"失败回填（**绝不放行**）
     *
     * ## 为什么默认是"立即拒绝"（EMPTY）
     *
     * CLI / 测试 / 无人值守场景没有 UI。两个坏选择：
     * ① 等 10 分钟再超时 —— 任务白挂；
     * ② 默认放行 —— **在没人看的情况下执行危险命令**，这是最坏的。
     *
     * 所以 `EMPTY` 的 timeout = 0 ⇒ `await()` 立刻返回 null ⇒ 按拒绝处理。
     */
    class ApprovalQueue(
        private val timeout: kotlin.time.Duration = kotlin.time.Duration.parse("10m"),
    ) {
        private val channel = kotlinx.coroutines.channels.Channel<ApprovalDecision>(
            kotlinx.coroutines.channels.Channel.RENDEZVOUS,
        )

        /** UI 层投递决定（弹窗提交时调用） */
        fun reply(decision: ApprovalDecision) {
            channel.trySend(decision)
        }

        /** 工具侧挂起等待决定；超时返回 null（= 未获批准，坚决不放行） */
        suspend fun await(): ApprovalDecision? = kotlinx.coroutines.withTimeoutOrNull(timeout) {
            channel.receive()
        }

        companion object {
            /** 无 UI 能力：立即按"拒绝"处理 */
            val EMPTY = ApprovalQueue(kotlin.time.Duration.ZERO)
        }
    }

    /**
     * 跑一个任务。
     *
     * @param userRequest 用户的自然语言请求
     * @param history **之前几轮的用户请求与助手回答**（2026-10-14 新增）。
     *
     *   ## 为什么需要（用户实测的严重缺陷）
     *
     *   用户原话：
     *   > 「让他继续完成任务，他输出了又是**没有记忆了**」
     *
     *   根因：`Session.start(frozenPrefix)` **每次都从零开始** ——
     *   用户看到的"对话历史"（Dart 侧 messages）与模型实际看到的
     *   上下文（AgentLoop 的 session）**是两套东西**。
     *   所以第二条消息说"继续"时，模型完全不知道前面做过什么。
     *
     *   ## 与铁律 1（append-only）的关系
     *
     *   这不是"改写历史"，而是**把已有历史按时间顺序重建进新会话**——
     *   前缀完全相同，所以缓存仍然命中（前缀缓存不关心会话对象身份）。
     *
     *   ## 传入形态
     *
     *   交替的 `(user, assistant)` 文本对，**按时间正序**。
     *   工具调用结果不入历史（它们属于**上一条消息的中间过程**，
     *   而不是对话本身）—— 这与用户的直觉一致：
     *   他看到的是"我问了什么、它答了什么"。
     *
     * @return 完整运行记录（含每轮 `CacheStats`）
     */
    fun run(
        userRequest: String,
        history: List<Pair<String, String>> = emptyList(),
        /**
         * **用户随本次请求附带的图片**（2026-10-19，多模态）。
         *
         * 元素是 **data URL**（`data:image/png;base64,...`）—— provider 无关的表示：
         * 各 provider 自己翻译成自己的 wire（OpenAI `image_url` / Anthropic `image` block）。
         * 空列表 = 纯文本（**请求体逐字节不变**，既有测试与缓存前缀不受影响）。
         *
         * 会随**本次 run 的每个请求**附带（而不是只第一轮）：本项目的会话是纯文本的，
         * 不每轮带上模型就"看不到"图片。代价是每轮多付图片 token —— 已由调用方限量。
         */
        images: List<String> = emptyList(),
    ): AgentRunResult = runBlocking {
        // 本 run 的图片列表：初始 = 用户附带的，`view_image` 工具会往里追加（2026-10-19）
        val runImages = images.toMutableList()
        var session = Session.start(frozenPrefix)
        val records = mutableListOf<TurnRecord>()
        var finalText = ""
        var stopReason = "未完成"

        // ★ 重建历史上下文（2026-10-14）—— 让模型"记得"之前聊过什么。
        //   顺序必须与真实发生的一致（user → assistant → user → assistant），
        //   否则模型的因果理解会错乱。
        for ((prevUser, prevAssistant) in history) {
            if (prevUser.isNotBlank()) {
                session = session.append(Turn.User(prevUser))
            }
            if (prevAssistant.isNotBlank()) {
                session = session.append(Turn.Assistant(prevAssistant))
            }
        }

        // ★ 任务计划（2026-10-14，harness）—— 模型首轮产出，此后逐轮推进。
        //   `null` = 模型还没给计划（简单问答可能直接给 final，永远没有计划，
        //   这是**合法**的：不是每个任务都需要待办清单）。
        //   ★ 2026-10-19：`initialPlan` 非空 = 从落盘的会话计划恢复（模型侧记忆）。
        var plan: TaskPlan? = initialPlan

        /** 统一的"改计划"入口：更新内存 + 通知装配处落盘（suspend：落盘可能走磁盘/SAF）。 */
        suspend fun setPlan(p: TaskPlan) {
            plan = p
            onPlanChanged?.invoke(p)
        }

        /**
         * `update_plan` 的实际执行（单调用 / 并行调用共用，2026-10-19）。
         *
         * 它是**循环状态工具**：不碰文件/网络，只改 `plan` 并发事件。
         * 工具实例本身拿不到 `AgentLoop` 的 plan，所以必须在这里拦截。
         */
        suspend fun applyUpdatePlan(turnIndex: Int, call: ToolCall): ToolOutcome {
            val newPlan = TaskPlan.parseUpdate(call.args["steps"].orEmpty())
                ?: return ToolOutcome.Failure(
                    "steps 不是合法计划：需要 JSON 数组，元素形如 " +
                        "{\"text\":\"…\",\"status\":\"pending|active|done\"}",
                )
            setPlan(newPlan)
            emit(AgentEvent.PlanCreated(turnIndex, newPlan.steps.map { it.text }))
            emit(
                AgentEvent.PlanAdvanced(
                    turnIndex,
                    doneCount = newPlan.steps.count { it.status == TaskPlan.Status.done },
                    activeIndex = newPlan.steps.indexOfFirst {
                        it.status == TaskPlan.Status.active
                    },
                )
            )
            return ToolOutcome.Success(
                "计划已更新（${newPlan.steps.size} 步，完成 " +
                    "${newPlan.steps.count { it.status == TaskPlan.Status.done }} 步）\n" +
                    newPlan.render(),
            )
        }

        /** 本 run 内「始终允许」的操作签名（工具 + 关键参数）。**不落盘** —— 跨 run 的持久白名单是另一个安全决定。 */
        val sessionApprovals = mutableSetOf<String>()

        /** 「始终允许」的签名 = **工具名**（与 Claude Code 的 "always allow this tool" 同粒度）。
         *
         * 为什么不是"工具+参数"：同一 run 内重复的**完全相同**调用会被循环检测拦住，
         * 所以按参数记签名时这条白名单几乎用不上；而"允许 write_file"这种粒度
         * 正是用户在弹窗里能理解、也确实是常见选择的语义。
         */
        fun approvalSignature(call: ToolCall): String = call.tool

        /** 询问用户（或按本 run 的白名单直接放行）。 */
        suspend fun approve(turnIndex: Int, call: ToolCall, reason: String): ApprovalResult {
            val sig = approvalSignature(call)
            if (sig in sessionApprovals) return ApprovalResult.ALLOWED
            emit(AgentEvent.ApprovalRequest(turnIndex, call, reason))
            return when (approvalReplies.await()) {
                ApprovalDecision.ALLOW_ONCE -> ApprovalResult.ALLOWED
                ApprovalDecision.ALLOW_ALWAYS -> {
                    sessionApprovals += sig
                    ApprovalResult.ALLOWED
                }
                ApprovalDecision.DENY -> ApprovalResult.DENIED
                null -> ApprovalResult.TIMEOUT
            }
        }

        // 预热冻结区 —— 云端让它建立前缀缓存（实测-07：命中 1024 块）
        provider.prewarm(frozenPrefix.text)

        session = session.append(Turn.User(userRequest))

        // ★ 上下文压缩（2026-10-16 用户需求「上下文压缩机制」）
        //
        // ## 修的是什么
        //
        // `COMPACTION_TRIGGER_RATIO`（0.8）常量早已定义，但**机制从未实现** ——
        // 长任务（多次写大文件）会把上下文塞满：
        // · 本地（4K）：一两轮写文件就到顶，模型输出被截断
        // · 云端：按 token 计费，全量历史每轮都重发
        //
        // ## 为什么"重建会话"不违反 ADR-006
        //
        // ADR-006 禁止的是**在既有前缀上改写尾部**（分支会让缓存塌缩到
        // 不可预测）。压缩是**从冻结区重新开始一段全新前缀**：
        // 旧前缀不再使用（它的缓存自然过期），新前缀从零累积——
        // 对缓存而言这是"新会话"，不存在"尾部不同"的分支问题。
        //
        // ## 摘要怎么来
        //
        // 让模型自己总结（一次额外调用）："把到目前为止的任务进展
        // 压缩成一段话，保留文件路径、已完成/未完成的步骤、关键结论"。
        // 摘要作为 Turn.System 开启新会话 —— 模型下一轮看到的就是
        // "冻结区 + 摘要 + 用户原始请求"，可以无缝继续。
        //
        // ## 防反复触发
        //
        // 压缩后新会话从很小开始，本轮不会再触发；但为防御"摘要本身
        // 很大 + 后续轮次又膨胀"的极端情况，每个 run 最多压缩一次
        // （compacted 标记）—— 二次触发说明任务真的太大，如实达到
        // maxTurns 比反复压缩更诚实。
        var compacted = false
        // ★ 工作区快照的"上一份事实"（F8b「变更才注入」）。
        //   · null = 还没注入过，**或**会话刚被压缩重建（见 maybeCompact 里那行重置）
        //   · 比的是 `WorkspaceSnapshot.factsOf(...)`（**去掉轮次标记**的那部分），
        //     否则"第 N 轮"每轮都变 ⇒ 判据恒为"变了" ⇒ 退化成每轮都注入
        var lastSnapshotFacts: String? = null
        suspend fun maybeCompact() {
            // 上限未知（<=0）= 不压缩（宁可慢也别错误地丢上下文）
            if (compacted || contextLimit <= 0) return
            val limit = contextLimit
            val used = session.estimatedPromptTokens
            if (used < limit * Contract.Context.COMPACTION_TRIGGER_RATIO) return

            emit(AgentEvent.Blocked(0, null, "上下文接近上限（$used / $limit），正在压缩…"))
            val summaryPrompt = buildString {
                append("以下是你（助手）与用户此前的完整交互记录。请把它压缩成一段**供你自己后续使用**的摘要，")
                append("必须保留：任务目标、已创建/修改的文件路径及各自状态、关键结论与数据、尚未完成的步骤。")
                append("不要寒暄，直接输出摘要正文。\n\n")
                append(session.render().removePrefix(frozenPrefix.text))
            }
            val summaryResult = runCatching {
                provider.generate(
                    dev.heracles.core.provider.GenerateRequest(
                        prompt = summaryPrompt,
                        maxOutputTokens = 1024,
                        structuredOutput = null, // 摘要是自由文本，不约束格式
                        deterministic = false,   // 摘要不要求确定性
                    ),
                ).getOrThrow()
            }
            compacted = true // 无论成败只压一次（见上）
            val summary = summaryResult.getOrNull()?.text ?: ""
            if (summary.isBlank()) {
                // 摘要失败（网络/超限）—— 保持原会话继续，宁可慢也不丢上下文
                emit(AgentEvent.Blocked(0, null, "压缩失败，继续使用完整上下文"))
                return
            }

            // 新会话：冻结区不变（工具定义还在）+ 摘要 + 原始请求
            var fresh = Session.start(frozenPrefix)
            fresh = fresh.append(
                Turn.System(
                    "【此前任务进展摘要（上下文压缩，原始记录已归档）】\n$summary\n" +
                        "请基于以上摘要继续完成任务。"
                )
            )
            fresh = fresh.append(Turn.User(userRequest))
            session = fresh
            // ★ F8b：压缩是**唯一**会重建会话的地方 ⇒ 新会话里**没有**快照。
            //   不重置这个判据的话：压缩后若事实与压缩前相同，我们会"判定没变 ⇒ 不注入"
            //   ⇒ **新会话里一份快照都没有** ⇒ 模型从此看不到工作区现状
            //   （这正是 F8b 最容易漏的那条）。重置 ⇒ 压缩后的同一轮就重新注入。
            lastSnapshotFacts = null
            emit(
                AgentEvent.Blocked(
                    0, null,
                    "上下文已压缩：${used} → ${session.estimatedPromptTokens} tokens",
                )
            )
        }

        // ★★ 预算计数器（ADR-033 / P0-1，2026-10-18）★★
        //   两个都是**整轮任务**级别的，不随 turnIndex 重置：
        //   否则"每轮重新计数"就等于没有预算。
        var toolCallCount = 0
        var consecutiveToolFailures = 0

        for (turnIndex in 1..maxTurns) {

            // ★ 上下文压缩检查（2026-10-16）——
            //   每轮开始前检查一次（第 1 轮必然不触发：还没有历史膨胀）。
            //   放在最前：工作记忆/插话注入都发生在"确定要跑这一轮"之后。
            maybeCompact()
            // ★★ 思考间隙引导（2026-10-13）：在**每轮开始前**注入插话
            //
            // 到达这里的时机 = 上一轮已**完整结束**（思考 + 正文 +
            // 工具结果都已 append）—— 正是用户要求的
            // 「第一个任务的当前的思考过程结束了再引导」。
            //
            // 插话作为独立的 `Turn.User` 追加（append-only，铁律 1），
            // 下一轮 prompt 自然包含：原任务 + 已完成步骤 + 插话。
            // 模型在下一轮自行比对：修改/追加/删除，调整后续任务 ——
            // 冲突消解是**模型的能力**，桥接层与 UI 不代劳。
            //
            // 第 1 轮不注入：用户插话必然发生在首轮开始之后
            // （首轮前没有"正在跑的任务"），这里 drain 到的只会是
            // 上一轮结束后新投递的。
            val interrupts = interruptQueue.drainAll()
            for (msg in interrupts) {
                session = session.append(
                    Turn.User("[用户插话] $msg"),
                )
                // 事件：插话被注入 —— UI 在工作步骤流里渲染插话卡片，
                // 让用户确信"第二条消息被模型看到了"
                emit(AgentEvent.Interrupted(turnIndex, msg))
            }

            // ★★ 工作记忆注入（2026-10-14，harness 核心）★★
            //
            // ## 为什么必须每轮都注入
            //
            // 用户实测：第 3 轮与第 4 轮的思考**极度相似**
            // （都在"用户要求我写HTML…"从头推导）。根因是
            // 模型**看不到自己已经做过什么** —— `records` 里
            // 逐轮记录的事实从未回喂。
            //
            // 注入后模型第 2 轮就知道：「1. 已完成：查看目录文件 → 成功
            // 2. 已完成：读取文件（index.html）→ 成功」，
            // 于是不会再去"先查看文件结构"。
            //
            // ## 与插话的叠加
            //
            // 两者都是 `Turn.User` append（append-only，ADR-006）：
            // 先插话（用户的新指令），再进度（事实），
            // 模型先看到"用户改了什么要求"，再看到"我已做到哪"。
            val ledger = renderProgressLedger(records)
            if (ledger != null) {
                session = session.append(Turn.User(ledger))
            }

            // ★ 计划 + 当前进度（2026-10-14）：紧跟在事实之后 ——
            //   让模型既知道"做过什么"，也知道"计划里现在该做第几步"
            plan?.let { session = session.append(Turn.User(it.render())) }

            // ★ 工作区快照（F8a / P2-1「跨轮记忆」，**默认关**；F8b：变更才注入）
            //
            // 位置：**在计划之后**（第 4 段）。理由：保住 `ledger → plan` 的
            // 现有相邻关系不被扰动（上面那条注释就是依赖它的）⇒ 回归面最小。
            //
            // 开关关着 ⇒ 一个字节都不碰（连 render 都不调用）⇒ 零回退是结构性的。
            //
            // ## F8b：事实没变就不注入
            //
            // 判据 = `factsOf(快照文本)`（**去掉轮次标记**，见其 KDoc）。
            // 每轮都渲染（唯一能知道"变没变"的办法），但只有**变了**才 append。
            // 这不是"每轮多读一遍目录"的浪费 —— 那一次有界遍历（≤200 行 /
            // `MAX_SNAPSHOT_WALK` 项）比多烧几千 token 便宜得多。
            if (snapshotInjectionEnabled) {
                val snapshot = WorkspaceSnapshot.render(workspace, records, turnIndex)
                if (snapshot != null) {
                    val facts = WorkspaceSnapshot.factsOf(snapshot)
                    if (facts != lastSnapshotFacts) {
                        session = session.append(Turn.User(snapshot))
                        lastSnapshotFacts = facts
                    }
                }
            }

            val started = System.nanoTime()

            // 事件①：一轮开始 —— UI 立刻显示「第 N 轮 · 正在生成…」
            // 这是"发送消息后长时间无反应"的第一处修复点：
            // 它发生在 provider.generate **之前**，所以本地模型跑 5–20 秒的
            // 那段空白里，UI 至少有东西可显示。
            emit(AgentEvent.TurnStarted(turnIndex))

            // ★★ token 级：把 provider 的流式增量变成 UI 事件
            //
            // 返回 (一次性调用结果, 逐字事件序列的原始条数)。
            // 「一次性结果」这个语义**刻意保留** —— 轮级逻辑（记账、解析、append）
            // 仍然基于"完整的这一轮"，与改造前逐字节一致（铁律 1）。
            val streamStepId = "turn-$turnIndex"
            val streamed = runStreamingTurn(
                session = session,
                turnIndex = turnIndex,
                stepId = streamStepId,
                images = runImages,
            )

            if (streamed.failure != null) {
                records += TurnRecord(
                    turnIndex, userRequest, "", null, null,
                    "provider 错误：${streamed.failure.message}", dev.heracles.core.provider.CacheStats.withoutCacheReporting(0, 0),
                    (System.nanoTime() - started) / 1_000_000,
                )
                // 事件②：provider 调用失败 —— 唯一一处"真·失败"
                emit(AgentEvent.Failed("provider 错误：${streamed.failure.message}"))
                return@runBlocking AgentRunResult(records, "", "provider 调用失败")
            }

            val wallMs = (System.nanoTime() - started) / 1_000_000
            // 失败分支已提前 return，所以这里必然非空
            val result = streamed.result!!
            val raw = result.text

            // 事件③：本轮原始输出到手 —— 「完全展开」档位显示模型原话
            emit(AgentEvent.ModelOutput(turnIndex, raw, result.cache, wallMs))

            if (debug) {
                println()
                println("┌─ 第 $turnIndex 轮 · 原始输出（${raw.length} 字符，finish=${result.finishReason}）")
                println("│ " + raw.take(600).replace("\n", "\n│ "))
                if (raw.length > 600) println("│ …（截断，共 ${raw.length} 字符）")
                println("└─")
            }

            // ★★ 解析模型输出 —— **两条轨的唯一汇合点**（ADR-031 step 2）★★
            //
            // ## 优先级：**原生优先**（2026-10-18 Lead 定案 D-3）
            //
            // wire 上有原生调用 ⇒ **只**按原生轨执行，正文完全不参与执行决策。
            // 为什么不让正文优先、也不"先把正文当 final 收工"：
            //   · 一条响应里两个"真话" ⇒ 执行哪个没有客观依据；而模型**最擅长**
            //     用正文骗过框架（"final 优先"正好递给它这个台阶）
            //   · "原生校验失败就回落正文里的调用" ⇒ 一次响应可能**执行两个**调用
            // 正文**不丢**：照旧 append 进会话（`Turn.Assistant(raw, calls)`），
            // 并在本轮记录里写明"正文同时可解析为 X，已按原生轨执行"（不新增事件类型）。
            // ★ 传 activeTools() 的名字集合：解析器只认**真实可用**的工具名，
            //   用于"工具名当顶层键"那种形状漂移的归一化（见 AgentOutputParser）。
            val textParsed = AgentOutputParser.parse(
                raw, activeTools().map { it.spec.name }.toSet(),
            )
            val nativeCalls = result.toolCalls

            // ---- 并行调用（v2，2026-10-19）----
            //
            // 原生 tools 下云端模型经常一次发 2-3 个**独立**调用（两个 read_file、
            // read + grep）。v1 只执行第一个、其余标"未执行"，逼模型多跑一轮。
            // v2：**全部执行**（串行 —— 工具层没有并发保证，SAF/单文件写/shell 会互相踩），
            // 超过 `Contract.Tools.MAX_NATIVE_CALLS_PER_TURN` 的仍配对回填"未执行"。

            val parsed = when {
                nativeCalls.isNotEmpty() -> AgentOutputParser.fromNativeCall(nativeCalls.first())
                // ★★ 原生轨：**正文不再要求 JSON 信封**（2026-10-19）★★
                //
                // 云端模型在原生 tools 下回答时就是普通文本（不带任何 JSON）。
                // 旧实现把它判成 Unparseable ⇒ 连挂两轮直接熔断 ——
                // 这正是"为什么要按特定格式输出、限制 LLM 发挥"的来源。
                // 现在：原生轨 + 没有原生调用 + 正文非空 ⇒ 就是**最终回答**。
                nativeToolsEnabled && textParsed is AgentOutput.Unparseable && raw.isNotBlank() ->
                    AgentOutput.FinalAnswer(raw.trim())
                else -> textParsed
            }
            // ★ 明说（只记事实）：两条轨都给出可执行内容时留下痕迹 ——
            //   原生轨优先是**有意**的，不是"悄悄忽略了模型说的话"。
            val nativeNote = if (nativeCalls.isNotEmpty() && textParsed !is AgentOutput.Unparseable) {
                "；⚠️ 本轮正文同时可解析为「${describeTrack(textParsed)}」，已按**原生轨**执行（正文未参与执行）"
            } else {
                ""
            }

            when (parsed) {
                // ★★ 产出计划（2026-10-14，harness）★★
                //
                // 用户原话：「先拿到问题先分析，**做一个待办**，
                // 按照待办完成任务」。
                //
                // ## 为什么这一轮不执行工具
                //
                // 模型这一轮的产物是**计划本身**。执行留到下一轮 ——
                // 下一轮的工作记忆里带着"计划 + 当前进度"，
                // 模型于是明确知道"现在该做第 1 步"。
                //
                // ## 为什么要发事件（而不是只记在内存）
                //
                // UI 必须**立刻**把待办清单显示出来（打勾式推进）——
                // 用户才知道"agent 打算怎么干"，而不是盯着转圈猜。
                is AgentOutput.PlanReady -> {
                    val readyPlan = parsed.plan.activated()
                    setPlan(readyPlan)
                    records += TurnRecord(
                        turnIndex, userRequest, raw, null, null,
                        "产出任务计划（${readyPlan.steps.size} 步）", result.cache, wallMs,
                    )
                    session = session.append(Turn.Assistant(raw))
                    // 把计划回喂给模型（下一轮它就知道该做第 1 步）
                    session = session.append(Turn.User(readyPlan.render()))
                    emit(
                        AgentEvent.PlanCreated(
                            turnIndex, readyPlan.steps.map { it.text },
                        )
                    )
                    emit(
                        AgentEvent.PlanAdvanced(
                            turnIndex,
                            doneCount = 0,
                            activeIndex = 0,
                        )
                    )
                }

                is AgentOutput.FinalAnswer -> {
                    records += TurnRecord(
                        turnIndex, userRequest, raw, null, null,
                        "最终回答", result.cache, wallMs,
                    )
                    session = session.append(Turn.Assistant(raw))

                    // ★★ 有待消化的插话时，"最终回答"**不能**结束运行
                    // （2026-10-13，用户实测 bug）
                    //
                    // 用户场景：第一条「你看可以做什么？」是简单问题，
                    // 模型第 1 轮就给了 FinalAnswer —— 原实现直接 return，
                    // **插话队列根本没机会 drain**，第二条「你是谁开发的？」
                    // 被静默丢弃（UI 也没显示发出去了）。
                    //
                    // 正确语义：这版回答**先落为已发生的助手消息**
                    // （上面 append 已做），然后循环继续 → 下一轮开始前
                    // 注入插话 → 模型看到插话再回答。对用户来说就是：
                    // 第一问先答了，第二问紧接着被回答 —— 两问都不丢。
                    //
                    // ⚠️ 空转保护：maxTurns 是硬上限，循环不会无限转；
                    //    插话最多让运行多跑"插话数"轮。
                    //    判断用 `!isEmpty`（不在这里 drain —— 注入统一
                    //    发生在下一轮开始前，单一入口）
                    if (turnIndex < maxTurns && !interruptQueue.isEmpty) {
                        continue
                    }

                    finalText = parsed.text
                    stopReason = "已给出最终回答"
                    // ★ 计划收尾（2026-10-15，BUG-1）——
                    //   模型给了最终回答 = 它认为目标达成 ⇒ 剩余步骤视为**已完成**。
                    //
                    //   为什么必须在这里发：plan 的推进只认"工具成功"，
                    //   而**最后一步通常不需要工具**（"汇报结果"这类）——
                    //   不发这个事件，那一步会永远停在"进行中"
                    //   （用户实测截图：任务结束但显示 4/5）。
                    emit(
                        AgentEvent.PlanClosed(
                            doneCount = plan?.steps?.size ?: 0,
                            reachedGoal = true,
                            reason = "任务完成",
                        )
                    )
                    // 事件④：最终回答 —— UI 结束「运行中」态
                    emit(AgentEvent.Finished(finalText, stopReason, records.size))
                    return@runBlocking AgentRunResult(records, finalText, stopReason)
                }

                is AgentOutput.ToolRequest -> {
                    val call = parsed.call
                    val specNames = activeTools().map { it.spec.name }

                    // ---- 循环检测（2026-10-09 实修）----
                    //
                    // 首次端到端实测：模型写完 hello.py 后又写一遍，
                    // 写完 README.md 后**连续 5 轮输出完全相同的调用**，永不收工。
                    //
                    // 这是 agent 的经典失败模式："不知道何时算完成"。
                    // 仅靠提示词要求它输出 final **不可靠**（与抗幻觉同理：
                    // 否定性/终止性约束对模型弱）。必须由**架构层强制**。
                    val repeats = consecutiveRepeatCount(records, call)

                    if (repeats >= MAX_IDENTICAL_TOOL_CALLS) {
                        // 硬停：合成一个 final，不再执行
                        val detail = "已连续 $repeats 次请求相同的操作，判定任务已完成并停止。"
                        records += TurnRecord(
                            turnIndex, userRequest, raw, call, null,
                            "★ 检测到循环，强制停止$nativeNote", result.cache, wallMs,
                        )
                        // ★ 原生轨：这一轮的调用**没有执行**（硬停）——
                        //   `tool_calls` 进了会话就必须配上 `tool_result`（见 appendNotExecuted）
                        session = session.appendNotExecuted(raw, nativeCalls, NativeSkip.LOOP)
                        // 事件⑤：循环硬停 —— 这不是"工具失败"，是架构层拦截
                        emit(
                            AgentEvent.Blocked(
                                turnIndex, call,
                                "已连续 $repeats 次请求相同的操作，判定为循环并强制停止",
                            )
                        )
                        // 事件⑥：硬停本身也是"运行结束"，用 Finished 收尾（finalText=detail）
                        //
                        // ★ 计划收尾（2026-10-15，BUG-1）：**中断不是完成** ——
                        //   `reachedGoal = false`，UI 会把剩余步骤显示成
                        //   "已中断"而不是画绿勾。把失败画成成功是 H-1
                        //   记录过的假信息问题，这里不能再犯。
                        emit(
                            AgentEvent.PlanClosed(
                                doneCount = plan?.steps
                                    ?.count { it.status == TaskPlan.Status.done } ?: 0,
                                reachedGoal = false,
                                reason = "检测到循环，已强制停止",
                            )
                        )
                        emit(AgentEvent.Finished(detail, "检测到循环，已停止", records.size))
                        return@runBlocking AgentRunResult(records, detail, "检测到循环，已停止")
                    }

                    if (repeats >= 1) {
                        // 第二次相同调用：**不执行**。
                        //
                        // ★ 2026-10-14 修：提示必须区分"真完成"与"被拦后卡住"
                        //
                        // 用户实测：`list_files` 因 `dir` 为空被校验拦下
                        // （校验器的 bug，已修），模型重试同样的调用又撞上
                        // 这里 —— 而旧提示说"**如果目标已经达成**，输出 final
                        // 结束任务"，模型照做了，于是**谎称"我已经为你创建了
                        // 2048 游戏 HTML 文件"**（文件根本没写）。
                        //
                        // 根因：旧提示给了模型一条"宣布完成"的台阶，
                        // 却没检查目标是否真的达成。现在按**上一轮结局**分流：
                        //   · 上次成功 → 目标可能达成 → 允许收工
                        //   · 上次失败/被拦 → 目标**明确没达成** → 禁止声称完成，
                        //     要求换做法（改参数 / 换工具 / 说明卡在哪）
                        val lastFailed = records.lastOrNull()?.let { r ->
                            r.verdict.contains("失败") ||
                                r.verdict.contains("拦截") ||
                                r.verdict.contains("校验")
                        } == true

                        val guidance = if (lastFailed) {
                            "**注意：你上一次的操作没有成功，目标尚未达成。**" +
                                "不要重复同样的调用，也不要声称任务已完成。" +
                                "请换一种做法（修改参数、换用其它工具，或先在 final 里" +
                                "如实说明你卡在哪里、需要用户做什么）。"
                        } else {
                            "你刚才已经成功执行过完全相同的操作（${call.tool}，" +
                                "参数一致），结果没有变化。**不要重复执行。**" +
                                "如果目标已经达成，必须立即输出 " +
                                "{\"final\":\"<对用户的总结>\"} 结束任务。"
                        }

                        records += TurnRecord(
                            turnIndex, userRequest, raw, call, null,
                            "重复调用已拦截（第 ${repeats + 1} 次）$nativeNote", result.cache, wallMs,
                        )
                        session = session.appendNotExecuted(raw, nativeCalls, NativeSkip.LOOP)
                        session = session.append(Turn.System(guidance))
                        // 事件⑦：重复调用拦截（工具**没执行**，所以不是 ToolFinished）
                        emit(
                            AgentEvent.Blocked(
                                turnIndex, call,
                                "重复调用已拦截（第 ${repeats + 1} 次）：${call.tool} 参数一致，未执行",
                            )
                        )
                        continue
                    }

                    // ---- 校验（L2 白名单）----
                    val problem = describeValidation(call, activeTools().map { it.spec })

                    if (problem != null) {
                        // 校验不过 → **不执行**，append 失败原因让模型重试
                        records += TurnRecord(
                            turnIndex, userRequest, raw, call, null,
                            "校验失败：$problem$nativeNote", result.cache, wallMs,
                        )
                        session = session.appendNotExecuted(raw, nativeCalls, NativeSkip.VALIDATION)
                        session = session.append(
                            Turn.System("上一次调用未通过校验：$problem。请修正后重新输出。")
                        )
                        // 事件⑧：校验失败拦截 —— 工具**没有被执行**
                        emit(AgentEvent.Blocked(turnIndex, call, "校验失败：$problem"))
                        continue
                    }

                    // ---- 执行 ----
                    // ★ 派发也要用 activeTools()：只查 [tools] 的话，
                    //   被披露的长尾工具**能通过校验却找不到实现** ⇒ 崩。
                    val tool = activeTools().first { it.spec.name == call.tool }
                    // 事件⑨：校验通过、即将执行 —— UI 在此刻显示"正在执行 xx 工具"
                    // 顺序很重要：必须在 execute **之前**发，否则用户看到的
                    // 是"工具跑完才出现"，那正是本次要修的问题。
                    emit(AgentEvent.ToolStarted(turnIndex, call))

                    // ★ ask_user：工具会**挂起等待用户回答**（2026-10-16）——
                    //   必须在挂起**前**通知 UI 弹窗，否则用户不知道模型在等什么。
                    //   用户在弹窗里提交回答 → AskReplyQueue.reply() → 工具拿到。
                    if (call.tool == "ask_user") {
                        emit(
                            AgentEvent.AskUser(
                                turnIndex,
                                question = call.args["question"].orEmpty(),
                                call = call,
                            )
                        )
                    }

                    // ★★ 工具调用总预算（ADR-033 / P0-1，2026-10-18）★★
                    //
                    // 契约里的那个数（`MAX_TOOL_CALLS_PER_TASK`，后被 `docs/27` §2.2 挖出）
                    // 曾是**死常量**：全仓库只在定义处出现，从未被接线。
                    // 现在它是真预算（S2 起默认值 = `Contract.Budget.MAX_TOOL_CALLS`）：
                    // 到顶就**如实**停 —— 说"额度用尽"，而不是假装任务完成（那会让用户以为活干完了）。
                    if (toolCallCount >= maxToolCalls) {
                        val detail = "工具调用次数已达上限（$maxToolCalls），任务未完成。\n\n" +
                            "⚠️ 这是**预算**不是错误：模型没报错，是额度用完了。" +
                            "可以让我接着做（继续发消息），或把上限调大。"
                        // ★ 原生轨：预算用尽时**这一轮**也没执行 ⇒ 会话要配对
                        //   （文本轨这一支过去不留记录也不 append，保持逐字节不变）
                        if (nativeCalls.isNotEmpty()) {
                            records += TurnRecord(
                                turnIndex, userRequest, raw, call, null,
                                "★ 工具调用预算用尽（$maxToolCalls），本轮调用未执行$nativeNote",
                                result.cache, wallMs,
                            )
                            session = session.appendNotExecuted(raw, nativeCalls, NativeSkip.BUDGET)
                        }
                        emit(
                            AgentEvent.PlanClosed(
                                doneCount = plan?.steps
                                    ?.count { it.status == TaskPlan.Status.done } ?: 0,
                                reachedGoal = false,
                                reason = "工具调用已达上限（$maxToolCalls）",
                            )
                        )
                        emit(
                            AgentEvent.Finished(
                                detail, "工具调用已达上限（$maxToolCalls）", records.size
                            )
                        )
                        return@runBlocking AgentRunResult(
                            records, detail, "工具调用已达上限（$maxToolCalls）"
                        )
                    }
                    toolCallCount++

                    val toolStartedAt = System.nanoTime()
                    // ★ 审批判据（2026-10-19）：
                    //   · MANUAL 档：**所有**有副作用的工具都问
                    //   · WORKSPACE_AUTO 档：**只有越界**（路径跑到工作区外）才问 ——
                    //     这正是设置里那句「工作区内的改动自动执行，越界仍会询问」的后半句。
                    //     在此之前它只是文案：越界根本没有判定。
                    val outside = if (call.tool in mutatingTools) {
                        WorkspaceBoundary.outOfWorkspaceArgs(call.args)
                    } else {
                        emptyList()
                    }
                    val needAsk = when (approvalMode) {
                        ApprovalMode.MANUAL -> call.tool in mutatingTools
                        ApprovalMode.WORKSPACE_AUTO -> outside.isNotEmpty()
                        ApprovalMode.FULL_ACCESS -> false
                    }
                    var manualDenied = false
                    if (needAsk) {
                        val reason = if (approvalMode == ApprovalMode.MANUAL) {
                            "当前权限档位「手动审批」：${call.tool} 会修改文件或设备，需要你确认"
                        } else {
                            "这次 ${call.tool} 要访问**工作区之外**的位置（${outside.joinToString("；")}），" +
                                "当前档位「工作区内修改」只在工作区内自动放行，需要你确认"
                        }
                        manualDenied = approve(turnIndex, call, reason) != ApprovalResult.ALLOWED
                    }
                    // ★ update_plan 是**循环状态工具**（2026-10-19）：它的"执行"就是改 plan + 发事件，
                    //   没有文件/网络副作用。工具实例拿不到 AgentLoop 的 plan，所以在这里拦截。
                    var outcome = when {
                        manualDenied -> ToolOutcome.Failure(
                            "用户未批准（手动审批档位），未执行：${call.tool}",
                        )
                        call.tool == "update_plan" -> applyUpdatePlan(turnIndex, call)
                        else -> tool.execute(call.args)
                    }
                    // ★ 工具自己说"需要确认"（命令守卫）：完全访问档位直接放行；
                    //   其余档位挂起问用户 —— 允许则**重新执行**，拒绝/超时按失败回填
                    //   （绝不谎称成功、也绝不在没人看时放行）。
                    if (outcome is ToolOutcome.NeedsApproval) {
                        val reason = outcome.detail
                        outcome = if (approvalMode == ApprovalMode.FULL_ACCESS) {
                            tool.execute(call.args)
                        } else {
                            when (approve(turnIndex, call, reason)) {
                                ApprovalResult.ALLOWED -> tool.execute(call.args)
                                ApprovalResult.DENIED -> ToolOutcome.Failure("用户拒绝执行：$reason")
                                ApprovalResult.TIMEOUT ->
                                    ToolOutcome.Failure("等待用户确认超时，未执行：$reason")
                            }
                        }
                    }
                    val toolWallMs = (System.nanoTime() - toolStartedAt) / 1_000_000

                    val outcomeText = when (outcome) {
                        is ToolOutcome.Success -> outcome.detail
                        is ToolOutcome.SuccessWithImage -> outcome.detail
                        is ToolOutcome.Failure -> "失败：${outcome.reason}"
                        is ToolOutcome.NeedsApproval -> "需要用户确认：${outcome.detail}"
                    }

                    // ★ view_image（2026-10-19）：把图片加进本 run 的图片列表，
                    //   之后每轮请求都带上（模型"看过"这张图）。
                    if (outcome is ToolOutcome.SuccessWithImage) {
                        if (runImages.size < Contract.Media.MAX_IMAGES_PER_RUN) {
                            runImages += outcome.imageDataUrl
                        }
                    }

                    // ★ 连续失败计数（ADR-033 / P0-1）——
                    //   成功清零；需要确认**既不增也不清零**（不是失败，也不算进展）。
                    //   （这里两个成功分支都归 0 是对的，但下面几处"算不算成功"
                    //    一律走 `isSuccess`：图片也是成功，判错它就是真机上的红卡 bug。）
                    consecutiveToolFailures = when (outcome) {
                        is ToolOutcome.Success -> 0
                        is ToolOutcome.SuccessWithImage -> 0
                        is ToolOutcome.Failure -> consecutiveToolFailures + 1
                        is ToolOutcome.NeedsApproval -> consecutiveToolFailures
                    }

                    // 事件⑩：工具执行完毕（不论成败，ok 区分）
                    emit(
                        AgentEvent.ToolFinished(
                            turnIndex, call, outcomeText,
                            outcome.isSuccess,
                            toolWallMs,
                        )
                    )

                    records += TurnRecord(
                        turnIndex, userRequest, raw, call, outcomeText,
                        (if (outcome.isSuccess) "工具成功" else "工具失败") + nativeNote,
                        result.cache, wallMs,
                        // ★ 唯一**真正执行过**工具的分支 —— 只有这里能给出
                        //   结构化的成功/失败。上面三条拦截分支刻意不传，
                        //   于是它们是 `null` ⇒ `toolState == blocked`。
                        //   详见 TurnRecord.toolSucceeded 的说明（H-1）。
                        //   `isSuccess`（不是 `is Success`）：`SuccessWithImage` 也是成功 ——
                        //   这是"真机上 view_image 成功却记 failed / 红卡"的直接修复点。
                        toolSucceeded = outcome.isSuccess,
                    )

                    // ★ 原生轨回填（ADR-031 step 2）：assistant 轮带上 `tool_calls`，
                    //   工具结果带上**配对 id**（`tool_use_id` / `tool_call_id`）。
                    //   文本轨：`nativeCalls` 为空 ⇒ `Turn.Assistant(raw)` +
                    //   `callId = null` + `isError = false`，与改动前**逐字段相同**。
                    session = session.append(Turn.Assistant(raw, nativeCalls))
                    session = session.append(
                        Turn.ToolResult(
                            call.tool, outcomeText,
                            callId = nativeCalls.firstOrNull()?.id,
                            // 图片也算成功：否则 provider 会把这次 tool_result 标成错误
                            isError = nativeCalls.isNotEmpty() && !outcome.isSuccess,
                        )
                    )

                    // ★ 并行调用 v2（2026-10-19）：**逐个执行**本轮其余原生调用（串行）。
                    //   每个调用独立走：解析 → 校验 → 重复检测 → 预算 → 执行 → 事件 → 记录 → 配对回填。
                    //   单个失败**不打断后续**（独立操作）；连续失败熔断在批末统一判。
                    //   文本轨 `nativeCalls` 为空 ⇒ 这段整体不执行，与改动前逐字段相同。
                    var lastFailureText = outcomeText
                    val batchLimit = Contract.Tools.MAX_NATIVE_CALLS_PER_TURN
                    for ((extraIndex, extra) in nativeCalls.withIndex()) {
                        if (extraIndex == 0) continue // 第一个已在上面执行
                        if (extraIndex >= batchLimit) {
                            session = session.append(
                                Turn.ToolResult(
                                    extra.tool,
                                    "未执行：本轮原生调用超过上限（$batchLimit 个），" +
                                        "只执行了前 $batchLimit 个。",
                                    callId = extra.id, isError = true,
                                )
                            )
                            records += TurnRecord(
                                turnIndex, userRequest, raw, null, null,
                                "超出单轮调用上限（$batchLimit）未执行：${extra.tool}$nativeNote",
                                result.cache, wallMs,
                            )
                            continue
                        }
                        val extraParsed = AgentOutputParser.fromNativeCall(extra)
                        if (extraParsed !is AgentOutput.ToolRequest) {
                            val why = (extraParsed as? AgentOutput.Unparseable)?.detail ?: "无法解析"
                            session = session.append(
                                Turn.ToolResult(
                                    extra.tool, "失败：校验失败：$why",
                                    callId = extra.id, isError = true,
                                )
                            )
                            records += TurnRecord(
                                turnIndex, userRequest, raw, null, null,
                                "校验失败：$why$nativeNote", result.cache, wallMs,
                            )
                            emit(AgentEvent.Blocked(turnIndex, null, "并行调用参数非法：${extra.tool}"))
                            continue
                        }
                        val extraCall = extraParsed.call
                        val extraProblem = describeValidation(
                            extraCall, activeTools().map { it.spec },
                        )
                        if (extraProblem != null) {
                            session = session.append(
                                Turn.ToolResult(
                                    extra.tool, "失败：校验失败：$extraProblem",
                                    callId = extra.id, isError = true,
                                )
                            )
                            records += TurnRecord(
                                turnIndex, userRequest, raw, extraCall, null,
                                "校验失败：$extraProblem$nativeNote", result.cache, wallMs,
                            )
                            emit(AgentEvent.Blocked(turnIndex, extraCall, "校验失败：$extraProblem"))
                            continue
                        }
                        if (consecutiveRepeatCount(records, extraCall) >= 1) {
                            session = session.append(
                                Turn.ToolResult(
                                    extra.tool, "未执行：重复调用已拦截",
                                    callId = extra.id, isError = true,
                                )
                            )
                            records += TurnRecord(
                                turnIndex, userRequest, raw, extraCall, null,
                                "重复调用已拦截（并行批内）$nativeNote", result.cache, wallMs,
                            )
                            emit(AgentEvent.Blocked(turnIndex, extraCall, "重复调用已拦截：${extraCall.tool}"))
                            continue
                        }
                        if (toolCallCount >= maxToolCalls) {
                            session = session.append(
                                Turn.ToolResult(
                                    extra.tool,
                                    "未执行：工具调用已达上限（$maxToolCalls）",
                                    callId = extra.id, isError = true,
                                )
                            )
                            records += TurnRecord(
                                turnIndex, userRequest, raw, extraCall, null,
                                "工具调用已达上限（$maxToolCalls）$nativeNote",
                                result.cache, wallMs,
                            )
                            emit(AgentEvent.Blocked(turnIndex, extraCall, "工具调用已达上限（$maxToolCalls）"))
                            continue
                        }
                        toolCallCount++

                        val extraTool = activeTools().first { it.spec.name == extraCall.tool }
                        emit(AgentEvent.ToolStarted(turnIndex, extraCall))
                        if (extraCall.tool == "ask_user") {
                            emit(
                                AgentEvent.AskUser(
                                    turnIndex,
                                    question = extraCall.args["question"].orEmpty(),
                                    call = extraCall,
                                )
                            )
                        }
                        val extraStartedAt = System.nanoTime()
                        // ★ 审批判据（2026-10-19）：与单调用路径**同一条**规则，
                        //   否则"模型一次发 4 个调用"就能绕过越界询问。
                        val extraOutside = if (extraCall.tool in mutatingTools) {
                            WorkspaceBoundary.outOfWorkspaceArgs(extraCall.args)
                        } else {
                            emptyList()
                        }
                        val extraNeedAsk = when (approvalMode) {
                            ApprovalMode.MANUAL -> extraCall.tool in mutatingTools
                            ApprovalMode.WORKSPACE_AUTO -> extraOutside.isNotEmpty()
                            ApprovalMode.FULL_ACCESS -> false
                        }
                        var extraManualDenied = false
                        if (extraNeedAsk) {
                            val reason = if (approvalMode == ApprovalMode.MANUAL) {
                                "当前权限档位「手动审批」：${extraCall.tool} 会修改文件或设备，需要你确认"
                            } else {
                                "这次 ${extraCall.tool} 要访问**工作区之外**的位置" +
                                    "（${extraOutside.joinToString("；")}），" +
                                    "当前档位「工作区内修改」只在工作区内自动放行，需要你确认"
                            }
                            extraManualDenied = approve(turnIndex, extraCall, reason) !=
                                ApprovalResult.ALLOWED
                        }
                        var extraOutcome = when {
                            extraManualDenied -> ToolOutcome.Failure(
                                "用户未批准（手动审批档位），未执行：${extraCall.tool}",
                            )
                            extraCall.tool == "update_plan" -> applyUpdatePlan(turnIndex, extraCall)
                            else -> extraTool.execute(extraCall.args)
                        }
                        // ★ 并行批次里的"需要确认"同样要挂起问用户（2026-10-19）
                        if (extraOutcome is ToolOutcome.NeedsApproval) {
                            val reason = extraOutcome.detail
                            extraOutcome = if (approvalMode == ApprovalMode.FULL_ACCESS) {
                                extraTool.execute(extraCall.args)
                            } else {
                                when (approve(turnIndex, extraCall, reason)) {
                                    ApprovalResult.ALLOWED -> extraTool.execute(extraCall.args)
                                    ApprovalResult.DENIED -> ToolOutcome.Failure("用户拒绝执行：$reason")
                                    ApprovalResult.TIMEOUT ->
                                        ToolOutcome.Failure("等待用户确认超时，未执行：$reason")
                                }
                            }
                        }
                        val extraWallMs = (System.nanoTime() - extraStartedAt) / 1_000_000
                        val extraText = when (extraOutcome) {
                            is ToolOutcome.Success -> extraOutcome.detail
                            is ToolOutcome.SuccessWithImage -> extraOutcome.detail
                            is ToolOutcome.Failure -> "失败：${extraOutcome.reason}"
                            is ToolOutcome.NeedsApproval -> "需要用户确认：${extraOutcome.detail}"
                        }
                        // ★ view_image 在并行批次里同样收集（2026-10-19）
                        if (extraOutcome is ToolOutcome.SuccessWithImage &&
                            runImages.size < Contract.Media.MAX_IMAGES_PER_RUN
                        ) {
                            runImages += extraOutcome.imageDataUrl
                        }
                        lastFailureText = extraText
                        consecutiveToolFailures = when (extraOutcome) {
                            is ToolOutcome.Success -> 0
                            is ToolOutcome.SuccessWithImage -> 0
                            is ToolOutcome.Failure -> consecutiveToolFailures + 1
                            is ToolOutcome.NeedsApproval -> consecutiveToolFailures
                        }
                        emit(
                            AgentEvent.ToolFinished(
                                turnIndex, extraCall, extraText,
                                extraOutcome.isSuccess, extraWallMs,
                            )
                        )
                        records += TurnRecord(
                            turnIndex, userRequest, raw, extraCall, extraText,
                            (if (extraOutcome.isSuccess) "工具成功" else "工具失败") +
                                nativeNote,
                            result.cache, wallMs,
                            // 并行批次里同样是"图片 = 成功"（与上面第一个调用同一判据）
                            toolSucceeded = extraOutcome.isSuccess,
                        )
                        session = session.append(
                            Turn.ToolResult(
                                extraCall.tool, extraText,
                                callId = extra.id,
                                isError = !extraOutcome.isSuccess,
                            )
                        )
                    }

                    // ★★ 连续失败熔断（ADR-033 / P0-1，2026-10-18）★★
                    //
                    // 与"连续解析失败熔断"分工不同：那条管"模型输不出可解析的东西"，
                    // 这条管"工具真的连续执行失败"。放在记录落盘**之后** ——
                    // 用户要能看到最后那次失败是什么，而不是一个没尾巴的中断。
                    if (consecutiveToolFailures >= maxConsecutiveFailures) {
                        val detail = "连续 $consecutiveToolFailures 次工具执行失败，已停止。" +
                            "\n\n最后一次失败：\n$lastFailureText"
                        emit(
                            AgentEvent.PlanClosed(
                                doneCount = plan?.steps
                                    ?.count { it.status == TaskPlan.Status.done } ?: 0,
                                reachedGoal = false,
                                reason = "连续 $consecutiveToolFailures 次工具失败，已停止",
                            )
                        )
                        emit(
                            AgentEvent.Finished(
                                detail, "连续 $consecutiveToolFailures 次工具失败，已停止",
                                records.size,
                            )
                        )
                        return@runBlocking AgentRunResult(
                            records, detail, "连续 $consecutiveToolFailures 次工具失败，已停止"
                        )
                    }

                    // ★★ 计划推进 = **只认显式状态**（2026-10-19 真机教训）★★
                    //
                    // 旧实现：任意工具执行成功 ⇒ 自动把第一个未完成步标 done。
                    // 真机实测（设备会话 `s1792383004905`）：模型先 `list_files`
                    // （与"写 notes.py"**毫无关系**），进度条就把第 2 步勾成 done ⇒
                    // 模型下一轮自己发现"记录说做完了，但文件不存在"，当场指出矛盾。
                    // 进度条**撒谎**比"暂时不前进"更糟：它会污染模型的工作记忆。
                    //
                    // 现在：推进只来自 `update_plan`（模型显式给 status）或首轮计划。
                    // 代价：模型忘了更新时进度会滞后 —— 这是**诚实的滞后**，
                    // 且协议里已明确要求"每完成一步用 update_plan 标 done"。
                }

                is AgentOutput.Unparseable -> {
                    // 解析失败 → **不执行任何工具**，append 让模型重试
                    records += TurnRecord(
                        turnIndex, userRequest, raw, null, null,
                        "输出无法解析：${parsed.detail}$nativeNote", result.cache, wallMs,
                    )
                    // ★ 原生轨下"解析失败"= `arguments` 不是合法 JSON 对象 ⇒ 同样要配对
                    //   （文案归到「校验失败」，**不新造第五种**理由）
                    session = session.appendNotExecuted(raw, nativeCalls, NativeSkip.VALIDATION)
                    // ★ 纠正提示必须**具体到形状**（2026-10-19 真机教训）——
                    //   设备会话第 4 轮模型输出 `{"apply_patch":{…}}`（工具名当顶层键），
                    //   旧提示写的是"上次输出不是合法 JSON"：那是**错话**（它合法），
                    //   模型拿着这条自相矛盾的反馈，在 temperature=0 下原样复现第二次
                    //   ⇒ 熔断。空泛的"请严格按格式"救不了这种漂移，必须点名错在哪、
                    //   正确的三种顶层形状长什么样。
                    session = session.append(
                        Turn.System(
                            "上次输出无法按协议解析：${parsed.detail}。\n" +
                                "只接受三种顶层形状（**顶层键**必须是下列之一）：\n" +
                                "· 计划：{\"plan\":[\"步骤一\",\"步骤二\"]}\n" +
                                "· 调工具：{\"tool\":\"工具名\",\"args\":{…}}" +
                                "（**不要**把工具名当顶层键，如 {\"apply_patch\":{…}} 是错的）\n" +
                                "· 收尾：{\"final\":\"给用户的回答\"}\n" +
                                "只输出其中一种，不要任何解释。"
                        )
                    )
                    // 事件⑪：输出无法解析 —— 同样"什么都没执行"，
                    // 所以是 Blocked 而不是 ToolFinished；call 为 null
                    // （连调用都没解析出来）。
                    emit(AgentEvent.Blocked(turnIndex, null, "输出无法解析：${parsed.detail}"))

                    // ★★ 连续解析失败熔断（2026-10-14，真机死循环修复）★★
                    //
                    // 用户实测：正文恒为空、连续 4 轮「输出无法解析」，
                    // 每轮 100+ 秒（本地 llama.cpp 在思考上烧光 max_tokens，
                    // `content` 为空 —— 根因是请求没带
                    // `enable_thinking=false`，见 `docs/25` §12.1）。
                    //
                    // **重试救不了这种情况**：模型每一轮都在做同一件事
                    // （把预算全花在思考上），再给 8 轮也是一样的结果，
                    // 只是让用户多等十几分钟。
                    //
                    // 熔断阈值取 2：第一次失败值得重试（可能是偶发的
                    // 格式漂移）；连续两次同样的失败说明是**系统性**问题，
                    // 立刻停下并如实说明，让用户能去查配置。
                    val consecutiveUnparseable = records
                        .takeLast(CONSECUTIVE_UNPARSEABLE_LIMIT)
                        .count { it.verdict.startsWith("输出无法解析") }
                    if (consecutiveUnparseable >= CONSECUTIVE_UNPARSEABLE_LIMIT) {
                        // ★ 提示要覆盖**两种**真实成因（2026-10-14）——
                        //   旧提示只提"本地后端未关思考"，对云端思考模型
                        //   是误导（用户实测：云端 deepseek-v4-flash 也这样）。
                        // ★ 2026-10-19：措辞去掉"本地 llama.cpp / GBNF"那套（本地后端
                        //   已随 ADR-035 删除，再这么说用户不知道在讲什么），并**附上
                        //   最后一次原始输出** —— 用户/排查者要看到"它到底吐了什么"，
                        //   而不是只有一句"没有输出可解析"。
                        val lastRaw = raw.take(300).ifBlank { "（空）" }
                        val detail = "模型连续 $consecutiveUnparseable 轮没有按协议输出，已停止。\n\n" +
                            "最后一次原始输出：\n```\n$lastRaw\n```\n\n" +
                            "请再发一次；如果反复出现，换一个模型，或把推理等级调低" +
                            "（思考会占用输出预算，正文可能为空）。"
                        emit(
                            AgentEvent.Blocked(
                                turnIndex, null,
                                "连续 $consecutiveUnparseable 轮解析失败，已熔断停止",
                            )
                        )
                        // ★ 计划收尾（2026-10-15，BUG-1）：熔断 = 中断
                        emit(
                            AgentEvent.PlanClosed(
                                doneCount = plan?.steps
                                    ?.count { it.status == TaskPlan.Status.done } ?: 0,
                                reachedGoal = false,
                                reason = "连续解析失败，已熔断",
                            )
                        )
                        emit(AgentEvent.Finished(detail, "连续解析失败，已熔断", records.size))
                        return@runBlocking AgentRunResult(records, detail, "连续解析失败，已熔断")
                    }
                }
            }
        }

        // 事件⑫：到达最大轮次 —— 兜底收尾事件。
        // 没有它，UI 的"运行中"状态会永远转下去。停止原因如实写"达到最大轮次"，
        // 不假装有过最终回答。
        //
        // ★ 计划收尾（2026-10-15，BUG-1）：轮次耗尽 = **中断**（目标未达成）
        emit(
            AgentEvent.PlanClosed(
                doneCount = plan?.steps
                    ?.count { it.status == TaskPlan.Status.done } ?: 0,
                reachedGoal = false,
                reason = "达到最大轮次（$maxTurns），任务未完成",
            )
        )
        emit(AgentEvent.Finished(finalText, "达到最大轮次（$maxTurns）", records.size))
        AgentRunResult(records, finalText, "达到最大轮次（$maxTurns）")
    }

    /**
     * 原生轨：**调用没有执行**的那条路的会话回填（ADR-031 step 2 第 5 条硬前置）。
     *
     * ## 为什么必须合成一个"结果"
     *
     * 只要 `tool_calls` 进了会话，同一会话里就必须有与之**配对**的工具结果 ——
     * 会话是**长命**的（硬停/拦截之后用户还能接着发消息），下一次请求会把这段
     * 历史**原样重放**（无 `previous_response_id`，见 `Turn.ToolResult` 的 KDoc）。
     * 于是"没回话的 `tool_calls`"会真的发到服务端上。
     *
     * ## 为什么不"回放时把 tool_calls 摘掉"
     *
     * 那是**篡改历史**：① 前缀缓存按字节比，摘一次前缀就变了（命中率不可预测）；
     * ② 模型看到的历史与它自己说过的话不一致，行为更难预测。
     * 合成一条**如实说明"未执行"**的结果，两条都避开了。
     *
     * ## 文案统一
     *
     * 理由取自 [NativeSkip]（四种、可枚举）—— 分支自己编措辞 = 新的不确定源。
     *
     * @param calls 为空 ⇒ **退化成文本轨的 `append(Turn.Assistant(raw))`**（逐字节不变）
     */
    private fun Session.appendNotExecuted(
        raw: String,
        calls: List<NativeToolCall>,
        reason: String,
    ): Session {
        if (calls.isEmpty()) return append(Turn.Assistant(raw))
        var s = append(Turn.Assistant(raw, calls))
        for (c in calls) {
            s = s.append(Turn.ToolResult(c.tool, NativeSkip.text(reason), c.id, isError = true))
        }
        return s
    }

    /** 只用于**本轮记录里的一句话**：正文本来会被当成什么（不新增事件类型）。 */
    private fun describeTrack(o: AgentOutput): String = when (o) {
        is AgentOutput.FinalAnswer -> "final（收工）"
        is AgentOutput.ToolRequest -> "工具调用 ${o.call.tool}"
        is AgentOutput.PlanReady -> "任务计划（${o.plan.steps.size} 步）"
        is AgentOutput.Unparseable -> "不可解析"
    }

    /**
     * 一轮的**流式**执行 —— 把 provider 的 token 增量变成 UI 事件。
     *
     * ## ★ 为什么返回值里既有"逐字事件"又有"一次性结果"
     *
     * 这是本次改造最关键的设计决定。
     *
     * 改造前是 `provider.generate(...) -> GenerateResult`；
     * 改造后**必须**是流式，否则用户看不到"一个字一个字出来"。
     * 但轮级逻辑（记账、`AgentOutputParser.parse`、`Session.append`）
     * 全都建立在"**完整的这一轮文本**"之上 —— 而铁律 1 要求
     * `Session.append` 序列**一字不差**。
     *
     * ⇒ 所以这里的做法是：**把流式增量累加回一份完整文本**，
     * 让轮级逻辑完全看不到流式的存在。这样：
     *
     * | 保证 | 原因 |
     * |---|---|
     * | append 序列与改造前逐字节一致 | 轮级拿到的还是同一份 `raw` |
     * | `TurnRecord` 一字不差 | 同上 |
     * | prompt 构造不受影响 | 同上 |
     *
     * **这正是 `AgentEventEmissionTest` 里 `eventsDoNotAlterPromptOrRecords` 守卫的东西。**
     *
     * ## 缓存记账
     *
     * [dev.heracles.core.provider.StreamChunk] **不含**缓存字段 ——
     * 它是 token 级增量，硬塞轮级指标是设计错误。所以流式路径的
     * `CacheStats` 从 provider 的 `lastStreamCache` 对账
     * （`FakeProvider` 与两个真实 provider 都提供了它）。
     *
     * ## 思考预算
     *
     * 见 [ThinkingBudget]：思考超过预算后**不再转发**给 UI，
     * 防止"开了思考就永远出不了答案"。
     */
    private suspend fun runStreamingTurn(
        session: Session,
        turnIndex: Int,
        stepId: String,
        images: List<String> = emptyList(),
    ): StreamedTurn {
        val coalescer = StreamCoalescer()
        val text = StringBuilder()
        val reasoning = StringBuilder()

        // 步骤开始 —— 逐字事件必须有归属的步骤卡片（否则多轮时错位）
        coalescer.startStep(stepId, System.currentTimeMillis()).forEach { emit(it) }

        var budgetExhausted = false
        val stepStartedAt = System.currentTimeMillis()

        val request = GenerateRequest(
            prompt = session.render(),
            // ★ 输出预算随推理等级放大（2026-10-14）——
            //   高推理档会显著加长思考，若预算不跟着涨，
            //   思考仍会吃光 token 让正文为空（用户实测的真机现象）。
            maxOutputTokens = effectiveMaxOutputTokens(),
            messages = renderAsMessages(session),
            // ★★ 约束解码：只要求"合法 JSON"（2026-10-19，GBNF 已随本地后端删除）★★
            //
            // 历史：这里原先传 [StructuredSpec.Grammar]（由 `AgentOutputGrammar`
            // 生成 GBNF 文本）—— 那是**本地 llama.cpp 专用**的强约束。
            //
            // 本地后端已随 ADR-035 删除，而**云端没有 GBNF**：`OpenAiCompatProvider`
            // 对 Grammar 的处理本来就是"降级成 `response_format: json_object`"
            // （契约 §6）。也就是说今天那份 GBNF 文本**一个字节都不会上线** ——
            // 它只剩"意图标记"的作用，还拖着一整个生成器与 6 条测试。
            //
            // ⇒ 直接表达真实意图：**要一段合法 JSON**。云端行为逐字节不变
            //   （同样是 `response_format: json_object`），
            //   provider 专有字段依旧没有泄漏到这一层（AGENTS.md）。
            structuredOutput = StructuredSpec.Json,
            deterministic = true,
            reasoning = reasoningLevel,
            // ★ 原生 `tools` 数组（ADR-031 请求侧；2026-10-19 接线）——
            //   装 activeTools()（常驻 + 已披露的长尾）。默认关闭 ⇒ 空列表 ⇒
            //   文本轨请求体逐字节不变。
            tools = nativeToolSpecs(),
            // ★ 快照（不是可变列表的引用）：请求发出去之后 `view_image`
            //   还会往 runImages 里追加 —— 传引用会让"已发出的请求"事后变样
            //   （真机上是同一 tick 内消费所以看不出来，但语义上是错的）。
            images = images.toList(),
        )

        // ★★ 终止块的载荷**必须**接住（F7c）★★
        //
        // 早期版本写的是 `if (chunk.done) return@collect` —— 把终止块**整个丢掉**，
        // 于是 `finishReason` 只能写死 STOP、原生调用无处可取。
        // 后果不是"少一个字段"：**"模型要调工具却拿不到 call"与"模型什么都没说"
        // 变得无法区分**，而那正是静默失败的定义。
        var terminalReason: FinishReason? = null
        var terminalCalls: List<NativeToolCall> = emptyList()

        var attempt = 0
        while (true) {
            attempt++
            // ★ 429/5xx 退避重试（2026-10-19）：只在**还没吐出任何内容**时重试。
            val failure: Throwable? = try {
                provider.generateStream(request).collect { chunk ->
                if (chunk.done) {
                    // 只接终止块的载荷；正文/思考的累加仍然只认**非终止块**
                    // （`StreamChunkTest` 钉住"done 块不得夹带内容"，见 StreamChunk.hasPayload）。
                    terminalReason = chunk.finishReason
                    terminalCalls = chunk.toolCalls
                    return@collect
                }

                // ★ 诊断：每个 chunk 记一条"原始"事件 —— 若不做合并，
                //   这一条就会变成一次主线程 post。见 [AgentLoopStats]。
                stats.countRawTokenDelta()

                // ① 正文：全量累加（轮级逻辑要用），并按合并策略转发
                if (chunk.deltaText.isNotEmpty()) {
                    text.append(chunk.deltaText)
                }

                // ② 思考：同样累加，但**受预算限制**才转发
                val forwardReasoning = if (chunk.deltaReasoning.isEmpty()) {
                    ""
                } else {
                    reasoning.append(chunk.deltaReasoning)
                    if (ThinkingBudget.shouldForwardReasoning(reasoning.length, maxOutputTokens)) {
                        chunk.deltaReasoning
                    } else {
                        // 超预算：不再转发。只提示一次，避免刷屏
                        if (!budgetExhausted) {
                            budgetExhausted = true
                        }
                        ""
                    }
                }

                val now = System.currentTimeMillis()
                // ★ 合并 + 帧节流**都在 coalescer 内部**完成（见 StreamCoalescer.append）：
                //   它保证"一个 16 ms 窗口内最多推一次"，而窗口没到时把内容留在缓冲里。
                //
                //   ⚠️ 早期版本把帧判定写在**这里**（"距上次 flush ≥16ms 就推"），
                //   真机实测压缩比只有 **1.0×** —— 因为 chunk 间隔实测可达 ~660 ms，
                //   于是每个 chunk 各自触发一次推。节流必须与 chunk 到达节奏解耦。
                coalescer.append(
                    deltaText = chunk.deltaText,
                    deltaReasoning = forwardReasoning,
                    nowMs = now,
                ).forEach { emit(it) }
                }
                null
            } catch (t: Throwable) {
                t
            }

            if (failure == null) break

            // ★ 用户点「停止」= 正常取消，不是 provider 错误（2026-10-19 修复）：
            //   旧实现把 CancellationException 也吞成 failure ⇒ UI 可能显示"运行失败"，
            //   与 MainActivity 的 cancelled 正常路径打架。
            if (failure is CancellationException) throw failure

            // ★ 429/5xx 退避重试：只重试**还没吐内容**的调用
            //   （流式中途断开可能已计费、重放会重复执行）。
            val clean = text.isEmpty() && reasoning.isEmpty() && terminalCalls.isEmpty()
            val retryable = (failure as? ProviderCallException)?.retryable == true
            if (retryable && clean && attempt <= Contract.Provider.RETRY_MAX_ATTEMPTS) {
                delay(Contract.Provider.RETRY_BASE_DELAY_MS * (1L shl (attempt - 1)))
                continue
            }

            // 尾部残留仍要推出（否则用户看到的内容比实际少）
            coalescer.flushAll().forEach { emit(it) }
            val elapsed = System.currentTimeMillis() - stepStartedAt
            coalescer.endStep(
                status = AgentEvent.StepEnded.STATUS_ERROR,
                durationMs = elapsed,
                summary = failure.message ?: "未知错误",
                index = turnIndex,
            ).forEach { emit(it) }
            // ★ 出错也要落盘（2026-10-12，S5）—— "这一步失败了"本身是过程的一部分，
            //   用户切回会话时必须能看到"当时这里报了错"
            emitStepEnded(
                index = turnIndex,
                stepId = stepId,
                thinking = reasoning.toString(),
                text = text.toString(),
                status = AgentEvent.StepEnded.STATUS_ERROR,
                durationMs = elapsed,
            )
            return StreamedTurn(failure = failure)
        }

        // 步骤结束：先推出尾部残留，再发 StepEnded
        // ★ status 三态而非布尔 —— "生成成功但内容为空"与"失败"对用户不同
        //
        // ⚠️ 原生轨下 **"正文空 + 有工具调用"是正常的**（模型只回一个 tool call），
        // 报成 `STATUS_EMPTY`（"生成成功但内容为空"）就是**假警报**。
        val rawText = text.toString()
        val status = when {
            rawText.isNotEmpty() -> AgentEvent.StepEnded.STATUS_OK
            terminalCalls.isNotEmpty() -> AgentEvent.StepEnded.STATUS_OK
            else -> AgentEvent.StepEnded.STATUS_EMPTY
        }
        val elapsed = System.currentTimeMillis() - stepStartedAt
        coalescer.endStep(
            status = status,
            durationMs = elapsed,
            summary = rawText,
            index = turnIndex,
        ).forEach { emit(it) }

        // ★★ 过程落盘（2026-10-12，S5）★★
        //
        // 放在 `endStep` **之后**：此时这一步的正文与思考都已完整，
        // 落下的是一条**完整**记录（不是半截增量），读回来可直接渲染。
        //
        // `thinking` 用的是 [reasoning] —— 它已经被 [ThinkingBudget] 截流，
        // 与用户在界面上**实际看到的**思考完全一致。
        // 若这里改用"模型真正吐出的全部思考"，会出现
        // 「磁盘上有、屏幕上没有」的错位，用户会以为界面吞了内容。
        emitStepEnded(
            index = turnIndex,
            stepId = stepId,
            thinking = reasoning.toString(),
            text = rawText,
            status = status,
            durationMs = elapsed,
        )

        return StreamedTurn(
            result = GenerateResult(
                text = rawText,
                cache = streamCache(),
                // ★ 用**终止块真实给的**原因；没给（旧实现/异常收尾）才退化为 STOP。
                //   文本轨的语义**逐字节不变**：既有 provider 都发 `done(STOP|LENGTH|…)`，
                //   与老代码写死的 STOP 在"成功结束"这一路上完全一致；
                //   差别只在以前被**吃掉**的 LENGTH / TOOL_CALLS / ERROR 现在能看见了。
                finishReason = terminalReason ?: FinishReason.STOP,
                toolCalls = terminalCalls,
            ),
        )
    }

    /** 流式一轮的结果 —— 见 [runStreamingTurn] 的设计说明 */
    private class StreamedTurn(
        val result: GenerateResult? = null,
        val failure: Throwable? = null,
    )

    /**
     * 取流式路径的缓存记账。
     *
     * 真实 provider 把它放在各自的 `lastStreamCache` 上（见 [runStreamingTurn]
     * 的说明）；这里用接口约定的方法拿，拿不到就退化为"未上报"
     * （**不能填 0** —— 0 与"未上报"语义不同，见 [CacheStats]）。
     */
    private fun streamCache(): dev.heracles.core.provider.CacheStats =
        provider.lastStreamCache()

    /**
     * 把 [Session] 渲染成消息列表（云端 `/chat/completions` 用）。
     *
     * **必须与 [Session.render] 表达同一份内容**，否则两个后端的上下文会不一致 ——
     * 那会导致"换后端后模型突然不会做事了"。
     *
     * ## 工具结果为什么不用 `role: "tool"`（2026-10-09 实修）
     *
     * 第一次端到端测试发现模型**反复写同一个文件**，
     * 说明它读不到上一轮的工具结果。
     *
     * 根因：OpenAI 的 `role: "tool"` 消息**必须**配对一条 assistant 的
     * `tool_calls`（含 `tool_call_id`）。我们并没有走原生的 function-calling 流程
     * （而是让模型输出 JSON），所以没有 `tool_call_id` ——
     * 这种"孤立的 tool 消息"**格式不合法**，DashScope 会忽略或报错。
     *
     * **修法**：把工具结果作为 `user` 消息回灌。
     * 虽然不如原生 tool 角色"规范"，但它**真的能被模型看到** ——
     * 而"能被看到"比"格式规范"重要得多。
     *
     * ## ★★ 原生轨：**必须**换回原生 shape（ADR-031 step 2 硬前置 1）★★
     *
     * 上面那条修法成立的前提是"**没有** `tool_call_id`"。原生轨一旦成立，
     * 前提就变了：assistant 轮的 `tool_calls` 会随历史一起重放，
     * 此时工具结果若还是纯文本 `user` 消息，就是**孤立的 `tool_calls`**
     * （Anthropic 会直接判 400：`tool_use` 必须紧跟配对的 `tool_result`）。
     *
     * ⇒ 判别用 [Turn.ToolResult.callId] **是否为 null**：
     *   · `null` ⇒ 文本轨，**逐字节**保持原样（那条 2026-10-09 的修法继续有效）
     *   · 非 null ⇒ 原生轨，出真正的 `role = TOOL` + `toolCallId`
     *     （Anthropic 由 provider 自己翻成 `tool_result` 块，见其 `buildBody`）
     */
    private fun renderAsMessages(session: Session): List<ChatMessage> = buildList {
        add(ChatMessage(ChatRole.SYSTEM, frozenPrefix.text))
        session.turns.forEach { t ->
            when (t) {
                is Turn.User -> add(ChatMessage(ChatRole.USER, t.text))
                is Turn.Assistant -> add(
                    ChatMessage(ChatRole.ASSISTANT, t.text, nativeCalls = t.nativeCalls)
                )
                is Turn.ToolResult -> {
                    val callId = t.callId
                    if (callId == null) {
                        add(
                            ChatMessage(
                                ChatRole.USER,
                                "【工具执行结果】${t.tool} → ${t.result}\n" +
                                    "（若已达成目标，请输出 {\"final\":\"...\"} 结束；否则继续下一步。）",
                            )
                        )
                    } else {
                        add(
                            ChatMessage(
                                role = ChatRole.TOOL,
                                content = t.result,
                                toolCallId = callId,
                                isError = t.isError,
                            )
                        )
                    }
                }
                is Turn.System -> add(ChatMessage(ChatRole.USER, "【系统】${t.text}"))
            }
        }
    }

    /**
     * 统计"末尾连续多少次是**同一个且已生效**的工具调用"（2026-10-14 修复）。
     *
     * 比较的是**工具名 + 全部参数**，不是原始文本 —— 模型可能
     * 用不同空格重复同一个调用，那也算重复。
     *
     * ## ★★ 旧实现的致命缺陷（用户实测）★★
     *
     * 旧代码只比 `tool` 与 `args`，**不看上一次是否真执行成功**：
     *
     * ```
     * 轮1: write_file(path=X, content=A) → 校验失败，没执行
     * 轮2: write_file(path=X, content=A) → 判"重复"，拦截   ← 错！
     * 轮3: write_file(path=X, content=A) → 第二次重复 → 拦
     * 轮4: → 达到 MAX_IDENTICAL_TOOL_CALLS → 硬停
     * ```
     *
     * 用户实测正是这个：模型想写文件 → 被拦 → 换 CDATA 格式重试
     * → **又被拦** → 卡死不动（截图：`重复调用已拦截（第 2 次）`，
     * 计划 `0/2` 永远不推进）。**文件永远写不出来。**
     *
     * ## 正确语义：只有"执行**失败**后重试"才放行
     *
     * | 上一次记录 | 含义 | 计数？ | 为什么 |
     * |---|---|---|---|
     * | `toolSucceeded == true` | 真的改动了世界 | ✅ | 目标达成后还重复 = 循环（`实测-08` 原始场景）|
     * | `toolSucceeded == null`（被**拦**）| 同一个调用又来了一次 | ✅ | **不数它会让模型靠被拦无限刷**（第一版修复踩过）|
     * | `toolSucceeded == false`（执行**失败**）| 没生效 | ❌ 中断 | 重试是**合法且必要**的 |
     * | 工具名/参数不同 | 换做法了 | ❌ 中断 | —— |
     *
     * ## 用户实测场景（本次修复的起因）
     *
     * 模型 `write_file` 因参数问题**执行失败** → 换个写法重试 →
     * 旧实现判"重复"→ **拦截** → 再试 → 又拦 → 卡死（截图：
     * `重复调用已拦截（第 2 次）`，计划 `0/2` 永不推进，文件写不出来）。
     *
     * 用 [TurnRecord.toolSucceeded] 这个**结构化字段**做判据，而不是
     * 字符串匹配 verdict（那正是 H-1 记录过的脆弱做法）。
     */
    private fun consecutiveRepeatCount(records: List<TurnRecord>, call: ToolCall): Int {
        var n = 0
        for (r in records.asReversed()) {
            val prev = r.toolCall ?: break
            if (prev.tool != call.tool || prev.args != call.args) break
            // ★ 只有**执行失败**（toolSucceeded == false）才中断计数 ——
            //   那次尝试没生效，模型重试同样的调用是**合法**的。
            //
            //   为什么"被拦"（null）仍要计数：拦截本身就是
            //   "同一个调用又来了一次"的证据 —— 不数它的话，
            //   拦截会打断计数链，模型可以靠被拦无限刷下去
            //   （第一版修复就踩了这个坑，被 AgentEventEmissionTest 抓回）。
            //
            //   `true` = 真的做过 → 当然计数。
            if (r.toolSucceeded == false) break
            n++
        }
        return n
    }

    companion object {
        /**
         * 允许"完全相同"的工具调用出现的最大连续次数。
         *
         * 超过则**强制停止**。设为 2 的依据：首次端到端实测中模型
         * 在目标已达成后仍重复了 5 次（`实测-08`）。给 1 次宽容
         * （可能是合法的重试），第 2 次就判定为循环。
         */
        const val MAX_IDENTICAL_TOOL_CALLS = 2

        /**
         * **连续解析失败的熔断阈值**（2026-10-14）。
         *
         * 用户真机实测：正文恒为空、连续 4 轮「输出无法解析」，
         * 每轮 100+ 秒（本地 llama.cpp 把 max_tokens 全烧在思考上，
         * `content` 为空 —— 根因是请求没带 `enable_thinking=false`，
         * 见 `docs/25` §12.1 与 `实测-03` 坑 16）。
         *
         * **重试救不了系统性失败**：模型每一轮都在重复同一件事，
         * 给满 8 轮只是让用户多等十几分钟，结果一样。
         *
         * 取 2 的依据：首次失败值得重试（可能是偶发格式漂移）；
         * 连续两次**同样的**失败说明是配置/系统性问题，应立刻停下
         * 并如实说明，让用户能去查后端配置。
         */
        const val CONSECUTIVE_UNPARSEABLE_LIMIT = 2

        const val DEFAULT_SYSTEM_PROMPT =
            "你是 Heracles，一个运行在手机上的开发助手。" +
                "你可以读写工作区里的文件来帮用户完成开发任务。" +
                "先看清现状再动手；不确定项目结构时先用 list_files。"

        /**
         * **文本轨**的工具调用协议。
         *
         * ## ⚠️ 名字里的 `_CLOUD` 是历史命名（ADR-035 S1b 后已无"另一档"）
         *
         * 原先这里有一份"本地档" [TOOL_PROTOCOL]（760 字，**S1b 已删**）：它与本份**只差
         * "怎么改文件"那一节**。删它的理由不是"它写错了"，而是**它没有消费者了**：
         * · 本地后端随 ADR-035 退场（provider 在 S3 删除）；
         * · `apply_patch` 在 S1b 之后**全员常驻**，于是"4B 手里没有 `apply_patch`、
         *   提示局部替换等于教它调用一个手头没有的工具"这个前提**不存在了**。
         *
         * 改名（`TOOL_PROTOCOL_CLOUD` → `TOOL_PROTOCOL`）留到与文档一起收口的那一轮做，
         * 避免为了名字动一堆测试锚点。
         *
         * ## 措辞上刻意与"本地那套"相反的地方（**不是疏忽，是反向教练**）
         *
         * · `apply_patch` **常驻在手边** ⇒ 明说"只改几行就局部替换"，并把标签形态的例子给出来；
         * · **去掉**"每次都写全，不要只写片段"这种**绝对化**措辞 —— 那句对 4B 是必要的护栏，
         *   对强模型是**反向教练**：它会让强模型放弃自己更准的局部编辑能力去整文件重抄，
         *   于是"抄错别处 / 被输出上限截断"这两个症状回来了。
         * · 截断护栏**保留**，但改了做法：分段 + **用 `apply_patch` 增量补**，
         *   而不是"每段都把整个文件重写一遍"。
         *
         * ## 代价（别忘）
         *
         * 这份文案进**冻结前缀** ⇒ 云端跨构建**首次** prefix cache miss 一次。
         *
         * ⚠️ **零真机**：这里只保证"提示词变了"，**不保证**"模型真的开始局部替换了"——
         * 那要上机看真实会话（`docs/27` 的已知缺口）。
         */
        val TOOL_PROTOCOL_CLOUD = """
## 输出格式（三种，不要输出任何其它内容）

① 任务需要多步时，**先给计划**（只在开始时给一次）：
{"plan":["第一步要做什么","第二步要做什么","第三步要做什么"]}

② 要**改文件**时，用标签 + CDATA（这样代码里的引号/换行都不会坏）：

· 只改几行 ⇒ **优先局部替换**（`apply_patch` 已在你手边，不必先 `search_tools`）：
<apply_patch path="index.html">
<![CDATA[
@@ -10,5 +10,5 @@
 <html>
 <head>
-<title>旧标题</title>
+<title>新标题</title>
 </head>
 </html>
]]>
</apply_patch>

· 新建文件、或大改（改动超过半个文件）⇒ 整文件写：
<write_file path="index.html">
<![CDATA[
（这里放文件的完整内容，双引号、单引号、换行都直接写，不用转义）
]]>
</write_file>

③ 要**读文件/看目录**时，用 JSON：
{"tool":"read_file","args":{"path":"index.html"}}
{"tool":"list_files","args":{"dir":""}}

④ 任务已完成、要给用户最终答复时：
{"final":"<你的回答>"}

## 规则

- **拿到任务先分析，再给计划**：需要多步时先输出 ① 计划，
  或用 **`update_plan` 工具**维护计划（可反复改：新增/删除/改状态）
- 计划要给 **2 步以上**，每步是一句可执行的话
- 给出计划后，**一次只做当前那一步**；**每完成一步必须调用 `update_plan`** 把该步标 `done`、
  下一步标 `active` —— 进度条**只认你显式给的状态**，不会因为"某个工具成功了"自动勾（那会撒谎）
- ★★ **改代码优先局部替换**：只动几行就用 `apply_patch`（`@@` 定位块，`-` 是删掉的行、
  `+` 是新写的行、其余是上下文行），**不要**为了改一行把整个文件重写一遍 ——
  重写容易把别处抄错，也更容易被输出上限截断
- 单个文件很大（超过约 3000 字符）时**分几次**写：先写骨架，再用 `apply_patch` 增量补齐，
  不要每一轮都把整个文件重新写一遍
- 不确定文件内容时先 read_file 看清，不要凭猜测修改
- 不要编造工具名；只能使用上面列出的工具

⚠️ 系统每轮都会告诉你「你已经完成的工作」—— **不要重复已完成的操作**。
如果某个文件已经读过，直接用它的内容；如果任务已完成，直接输出 ④。
""".trim()

        /**
         * **原生轨**的工具协议（F7c 硬前置 2）——
         * 只在 `nativeToolsEnabled = true` 时用它，**替掉**文本轨那一份
         * （本地那份已随 ADR-035 删除）。
         *
         * ## 为什么必须换掉：两套调用语法并存 = 模型一半概率写进正文
         *
         * 开了原生 `tools` 之后，工具清单由**原生 function calling** 承担。
         * 若提示词继续教 `{"tool":…}` / `<write_file>`，就是**两套真相**：
         * 模型有相当概率把调用写进**正文**，而按 ADR-031 的"原生优先"，
         * 正文里的调用**会被忽略** ⇒ 白跑一轮，用户看到"模型什么都没做"，
         * 而日志里连一条错误都没有（静默失败）。
         *
         * ## 保留的两件（都不是"调用语法"，是**文本轨的收尾机制**）
         *
         * · `{"plan":[…]}`：计划机制靠正文解析，与工具调用无关
         * · `{"final":"…"}`：**收尾**仍靠正文 —— 原生轨里没有"结束"这种工具调用，
         *   而且"没有原生调用时回落文本轨"正是 `AgentLoop` 的既有设计
         *
         * ⚠️ **未验**：真模型在原生轨下会不会照做（零 Key、零真机）。
         * 本常量只是把"两套真相"这件事**在提示层面**消除掉。
         */
        val TOOL_PROTOCOL_NATIVE = """
你**通过原生 function calling** 拿到工具清单（本次请求的 `tools` 字段）。

- 需要动工具时：**直接发起工具调用**，不要用 JSON / 标签去"描述"调用
  （那些**不会**被执行，只有真正的工具调用才会）
- 回答用户时：**直接用普通文字回答**，不需要任何 JSON 包装
- **互不依赖**的操作可以一次发**多个**工具调用（最多 4 个，系统会依次执行）；
  有依赖就分轮 —— 拿到上一个结果再决定下一步
- 不确定文件内容时先 `read_file`，不要凭猜测修改
- 不要编造工具名；只能使用 `tools` 里给出的工具

多步任务：用 **`update_plan` 工具**维护计划 —— 传完整步骤列表，可随时新增/改状态/重排。
（也兼容一次性 JSON 写法：{"plan":["第一步要做什么","第二步要做什么"]}）

任务完成时：直接给出最终答复即可（普通文字；想显式收尾也可以写 {"final":"<回答>"}）。

## 规则

- 计划要给 **2 步以上**，每步是一句可执行的话
- 给出计划后，**一次只做当前那一步**；**每完成一步必须调用 `update_plan`** 把该步标 `done`、
  下一步标 `active` —— 进度条**只认你显式给的状态**，不会因为"某个工具成功了"自动勾（那会撒谎）
- ★★ **改代码优先局部替换**：只动几行就用 `apply_patch`，
  **不要**为了改一行把整个文件重写一遍（容易抄错，也更容易被输出上限截断）
- 单个文件很大（超过约 3000 字符）时**分几次**写：先写骨架，再用 `apply_patch` 增量补齐

⚠️ 系统每轮都会告诉你「你已经完成的工作」—— **不要重复已完成的操作**。
""".trim()
    }
}

/**
 * 原生轨"未执行"的**统一文案**（ADR-031 step 2 第 5 条硬前置）。
 *
 * ## 为什么要统一
 *
 * 原生调用没执行时，框架必须往会话里补一条**配对的**工具结果
 * （见 `AgentLoop.appendNotExecuted`）。若每个分支自己编一句，
 * 模型看到的"为什么没执行"就会五花八门 —— 那本身就是新的不确定源
 * （同一个事实，N 种措辞，行为更难预测）。
 *
 * ⇒ **四种、可枚举**。要加第五种，先改这里，别在分支里手写字符串。
 */
internal object NativeSkip {
    /** L2 校验不过（含"原生 arguments 不是合法 JSON"—— 它同样是校验失败）。 */
    const val VALIDATION = "校验失败"

    /** [Contract.Budget.MAX_TOOL_CALLS] 用尽。 */
    const val BUDGET = "工具调用预算用尽"

    /** 重复调用拦截 / 循环硬停。 */
    const val LOOP = "循环拦截"

    /** 一轮收到 ≥2 个调用（`Contract.Tools.MAX_NATIVE_CALLS_PER_TURN = 1`）。 */
    const val PARALLEL = "本实现一次只支持一个原生工具调用"

    fun text(reason: String): String = "未执行：$reason"
}
