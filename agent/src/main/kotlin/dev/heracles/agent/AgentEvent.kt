package dev.heracles.agent

import dev.heracles.core.provider.CacheStats
import dev.heracles.core.tool.ToolCall

/**
 * agent 运行过程中的**实时事件** —— 让 UI 能边跑边显示（2026-10-10）。
 *
 * ## 为什么需要它
 *
 * 用户反馈：
 * > "我在会话区发送消息，但是很长一段时间没有反应，
 * >  只有在回答完我的问题后才可以看到全部输出结果"
 *
 * 根因：首版 [AgentLoop.run] **只在全部跑完后返回** `AgentRunResult`。
 * 一轮本地模型 5–20 秒，8 轮就是几分钟 —— 期间 UI 完全空白。
 *
 * 对比参考：DeepSeek Harness / Reasonix 的会话区会**逐步**显示
 * 「思考中…」→ 工具卡片 → 结果，用户随时知道 agent 在干嘛。
 *
 * ## 设计约束
 *
 * 1. **回调可选**（默认 `null`）—— 不能破坏现有调用方与 66 项测试
 * 2. **不改变 append-only**（铁律 1）—— 事件只是**通知**，不参与 prompt 构造
 * 3. **每个事件都可序列化** —— 因为要跨 MethodChannel/EventChannel 传给 Dart
 *
 * ## 与 TurnRecord 的区别
 *
 * | | TurnRecord | AgentEvent |
 * |---|---|---|
 * | 时机 | 一轮**结束后** | 一轮**进行中** |
 * | 用途 | 记账、缓存统计 | UI 实时反馈 |
 * | 完整性 | 完整 | 允许只有部分信息 |
 *
 * ## ★ 两种粒度（2026-10-12 流式改造）
 *
 * | | 轮级（前 7 类） | token 级（后 4 类） |
 * |---|---|---|
 * | 频率 | 一轮几条第 | 一轮几百条 |
 * | 承载 | **最终结果 + 统计** | **过程**（正在吐什么字） |
 * | 触发 | 一轮生成**完毕**后 | 生成**进行中** |
 *
 * **两类都必须发，不是新旧替代。** 只有轮级 ⇒ 用户看到"等 AI 想完了再全部展示"
 * （这正是用户报的原始缺陷）；只有 token 级 ⇒ 丢掉缓存统计与最终结果。
 */
sealed interface AgentEvent {

    /** 事件发生时间（毫秒时间戳） */
    val ts: Long

    /**
     * 一轮开始 —— 模型正在生成。
     *
     * UI 应显示「思考中…」这类提示。
     * **本地模型不开 thinking**（`enable_thinking=false`），所以没有可见的
     * 推理文本 —— 我们只能如实说"正在生成"，不能假装有思考内容。
     */
    data class TurnStarted(
        val index: Int,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * 模型本轮生成完毕，产出了原始文本。
     *
     * **这是「完全展开」档位要显示的东西** —— 用户能看到模型的原始输出，
     * 包括它打算调用什么工具、为什么这么决定。
     */
    data class ModelOutput(
        val index: Int,
        val raw: String,
        val cache: CacheStats,
        val wallMs: Long,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /** 准备执行一个工具（已通过校验） */
    data class ToolStarted(
        val index: Int,
        val call: ToolCall,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /** 工具执行完毕 */
    data class ToolFinished(
        val index: Int,
        val call: ToolCall,
        val result: String,
        val ok: Boolean,
        val wallMs: Long,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * 被拦截（校验失败 / 循环检测 / 重复调用）。
     *
     * 单独一类而不是混进 ToolFinished —— 因为**它没有执行**，
     * UI 上不该显示成"工具失败"，那会误导用户以为工具坏了。
     */
    data class Blocked(
        val index: Int,
        val call: ToolCall?,
        val reason: String,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /** 最终回答 */
    data class Finished(
        val finalText: String,
        val stopReason: String,
        val turnCount: Int,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * **任务计划收尾**（2026-10-15 真机实测修复，BUG-1）。
     *
     * ## 修的是什么
     *
     * 用户实测（2026-10-14 21:20 截图）：
     * ```
     * 任务计划 4/5
     *  ✓ …（4 步已勾）
     *  ◐ 确认功能完整后给出最终说明   进行中    ← 永远停在这
     * ```
     * 但模型**已经给出了完整的最终回答** —— 任务结束了，计划还挂着"进行中"。
     *
     * ## 根因（设计矛盾）
     *
     * 计划推进的判据是「**真实工具执行成功**」（[TaskPlan.advance]）——
     * 这个判据本身是对的（不让模型自报进度）。**但最后一步通常不需要工具**：
     * "汇报结果"、"确认完成"这类步骤，模型是**直接输出 final** 结束的，
     * 永远不会有第 5 次工具调用 ⇒ 那一步永远勾不上。
     *
     * ## 为什么单独一个事件而不是改 Finished
     *
     * 收尾有**两种语义**，混在一起会让 UI 分不清：
     * | 结局 | 剩余步骤该怎么显示 |
     * |---|---|
     * | 正常给出最终回答 | ✅ 视为**已达成**（画绿勾）|
     * | 循环硬停 / 熔断 | ⚠️ **中断**，不是完成（不能画成成功）|
     *
     * 后者尤其重要 —— 把失败画成成功正是 H-1 记录过的假信息问题。
     *
     * @param doneCount 已完成的步数（UI 据此把剩余步骤置为 [Status.done]
     *   或显示"已中断"）
     * @param reachedGoal true = 正常完成；false = 中断（循环/熔断）
     * @param reason 人可读的收尾原因（中断时显示给用户）
     */
    data class PlanClosed(
        val doneCount: Int,
        val reachedGoal: Boolean,
        val reason: String,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * **ask_user：模型向用户提问**（2026-10-16 引入；**2026-10-21 改为选项式**）。
     *
     * 到达时机：模型调了 `ask_user` 工具，**工具正在挂起等待** ——
     * 此刻用户作答，模型下一轮就能拿到。
     *
     * ## UI 该做什么（2026-10-21 用户要求）
     *
     * 用户原话：
     * > 「ask 要是选项点击的，不是要我直接在下面输入，一般是 1、2、3、4 等等几个选项，
     * >   可以多选，单选，是 LLM 根据任务决定，可以一次发多个 ask，回答完自动下一个问题，
     * >   下面可以点击上一题和下一题。」
     *
     * ⇒ UI 弹**选项式**对话框：
     * · 一次可能有多题（[questions]）⇒ 逐题作答，答完自动跳下一题
     * · 每题 `multi=false` 单选 / `multi=true` 多选（**由模型决定**，UI 不猜）
     * · 有「上一题 / 下一题」导航
     * · 用户点的是 `label`，回传也用 `label`（不要自己拼文案）
     *
     * @param questions 题目列表（**至少 1 题**；旧版只有一个字符串，已废弃）
     * @param call 对应的工具调用（UI 可用它关联步骤卡片）
     */
    data class AskUser(
        val index: Int,
        val questions: List<dev.heracles.core.tool.AskQuestion>,
        val call: dev.heracles.core.tool.ToolCall,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * **工具需要用户确认才能执行**（2026-10-19，三态门禁的 UI 闭环）。
     *
     * ## 到达时机
     *
     * 工具返回了 [dev.heracles.agent.ToolOutcome.NeedsApproval]（今天 = `run_shell_command`
     * 的命令守卫 say "这条命令需要人看一眼"）。此刻 `AgentLoop` **已经挂起**在
     * [AgentLoop.ApprovalQueue] 上等待用户决定：
     *
     * · 允许 ⇒ **重新执行**该工具（`NeedsApproval` 的契约就是"这次没做事"）
     * · 拒绝 / 超时 ⇒ 作为失败回填给模型（不许谎称成功）
     *
     * ## 与 [AskUser] 的区别
     *
     * `ask_user` 是**模型主动问信息**；本事件是**框架拦下一个危险动作，
     * 请用户拍板**。两者都是模态的（任务停在这里），但语义不同 —— UI 的按钮也不同。
     */
    data class ApprovalRequest(
        val index: Int,
        val call: dev.heracles.core.tool.ToolCall,
        /** 为什么需要确认（来自工具/命令守卫的人话说明） */
        val reason: String,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * **用户插话被注入会话**（2026-10-13，思考间隙引导）。
     *
     * ## 语义（用户原话）
     *
     * 「第一个任务当前的思考过程结束了再引导」——
     * 不是打断流式（那会截断思考），而是**在当前轮结束后、
     * 下一轮开始前**把插话 append 进会话。
     *
     * ## `index` 的准确含义
     *
     * 插话被 append 进**这一轮开始前**的会话 —— 即 `index` 就是
     * "模型看到插话并回应它的那一轮"。UI 把插话卡片渲染在
     * 第 `index-1` 轮的工作步骤之后、第 `index` 轮之前。
     */
    data class Interrupted(
        val index: Int,
        val text: String,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * **任务计划产生**（2026-10-14，harness 核心）。
     *
     * 模型首轮产出结构化待办（`{"plan":[...]}`），UI 渲染成
     * 打勾式清单 —— 用户原话：
     * > 「工作步骤就是把自己这一套工程展示出来……现在在干什么」
     * > 「顶部显示任务计划（1.查看结构 ✓ 2.写HTML ←进行中 3.验证）」
     */
    data class PlanCreated(
        val index: Int,
        val steps: List<String>,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * **任务计划推进**（2026-10-14）。
     *
     * 由**真实工具执行记录**驱动，不是模型自报 ——
     * 见 [TaskPlan.advance] 的判据说明。
     *
     * @param doneCount 已完成步数（前 N 个为 done）
     * @param activeIndex 当前进行中的步（0 起）；-1 = 全部完成
     */
    data class PlanAdvanced(
        val index: Int,
        val doneCount: Int,
        val activeIndex: Int,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /** 出错 */
    data class Failed(
        val message: String,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    // ============================================================ token 级事件
    //
    // 上面 7 类是【轮级】：一轮最多几条，粒度是"一整轮生成完毕"。
    // 下面 4 类是【token 级】：一轮几百条，粒度是"几个字"。
    //
    // ★ 两者是**不同粒度，不是新旧替代** —— 轮级事件承载最终结果与统计，
    //   token 级事件承载"正在吐字"的过程。两类都必须发。
    //
    // ★ 用户的原话是「**一个字一个字出来，不是等 AI 想完了再全部展示**」。
    //   上面 7 类恰恰全是"等 AI 想完了"才发的 —— 所以只有它们仍然不够。
    //
    // ⚠️ Dart 侧兼容：新增的子类型 Dart 必须能**降级忽略**（`default:` 分支），
    //    否则 App 会在收到未知类型时崩掉。见 `25-流式工作步骤.md` §5.3。

    /**
     * **思考增量** —— 用户最想要的那一个。
     *
     * 数据源是后端的 `reasoning_content` / `reasoning` 字段
     * （本地 llama.cpp 在 `enable_thinking=true` 时返回，实测见 `25` §12）。
     *
     * ## 为什么必须与 [StepDelta] 分开
     *
     * 用户要区分「**AI 在想什么**」与「**AI 给的答案**」。
     * 粘进同一个字段后，UI 无法把思考渲染成灰色过程、把答案渲染成正文，
     * 而且**一旦粘了就再也分不开**（`25` §2 错误一）。
     *
     * ## 没有思考流时不会发这个事件
     *
     * `enable_thinking=false`（本地默认档 `AUTO`）时后端**一个
     * `reasoning_content` 都不返回**（实测 0 个）——
     * 此时**不发** [ReasoningDelta]，UI 也就不会显示空的思考区。
     * **不得**为了"看起来有思考"而伪造内容。
     *
     * @param stepId 步骤标识，见 [StepStarted.stepId]
     * @param delta 本次增量（几个字，**不是**累积全文）
     */
    data class ReasoningDelta(
        val stepId: String,
        val delta: String,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * **正文增量** —— 最终答案正在逐字生成。
     *
     * 与 [ReasoningDelta] 同理：`delta` 是**增量**，UI 自己累加。
     *
     * ⚠️ 注意：正文在流式期间是**未完成的 JSON**（我们的协议要求模型输出
     * `{"final":"..."}`）。所以 UI 在 `StepEnded` 之前**不能**按 JSON 解析它，
     * 只能当纯文本逐字显示（`25` §5.3 第 4 条）。
     */
    data class StepDelta(
        val stepId: String,
        val delta: String,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * 一个步骤开始 —— 与 [TurnStarted] 的区别是它带**步骤标识**。
     *
     * token 级事件靠 [stepId] 归属到具体的步骤卡片上。
     * 没有它，UI 只能把增量堆在最后一条消息上，多步骤时必然错位。
     *
     * @param stepId 形如 `turn-3`（第 3 轮的生成步骤），**会话内唯一**
     * @param title 人可读标题（如「正在生成第 3 轮」）
     * @param tool 本轮最终要调用的工具名 —— **此时还不知道**，恒为 `null`。
     *   保留该字段是为了将来"工具参数流式"能复用同一事件。
     */
    data class StepStarted(
        val stepId: String,
        val title: String,
        val tool: String? = null,
        val index: Int = 0,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent

    /**
     * 一个步骤结束 —— UI 据此停止"逐字"状态并按最终文本重新格式化。
     *
     * ⚠️ 必须**成对**出现（每个 [StepStarted] 恰有一个 [StepEnded]），
     * 否则 UI 会永远停在"生成中"。
     *
     * @param status `ok` / `empty` / `error` 三态（**不是**布尔 ——
     *   "生成了但内容为空"与"生成失败"对用户是不同的）
     * @param durationMs 该步骤墙钟耗时
     * @param summary 生成内容的**最终完整文本**（UI 用它替换掉逐字累积的草稿，
     *   顺带完成 Markdown 格式化）
     */
    data class StepEnded(
        val stepId: String,
        val status: String,
        val durationMs: Long,
        val summary: String,
        val index: Int = 0,
        override val ts: Long = System.currentTimeMillis(),
    ) : AgentEvent {
        companion object {
            /** 正常生成出内容 */
            const val STATUS_OK = "ok"

            /** 跑完了但内容为空 —— 与失败不同，不要混淆 */
            const val STATUS_EMPTY = "empty"

            /** 出错（provider 异常等） */
            const val STATUS_ERROR = "error"
        }
    }
}
