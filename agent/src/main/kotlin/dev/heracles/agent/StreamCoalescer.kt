package dev.heracles.agent

import dev.heracles.core.contract.Contract

/**
 * **token 级事件的批量合并器** —— `25-流式工作步骤.md` §5.4。
 *
 * ## 它解决的不是性能问题，是**能不能用**的问题
 *
 * `MainActivity.eventSink` 是 Flutter 的平台通道回调，**必须在主线程调用**。
 * 本地模型实测 ~250 tok/s（`实测-01`），而本项目的 MTP 会话统计里
 * 输出速度也稳定在 250 tok/s 量级。
 *
 * 逐 token 直接推 ⇒ **每秒 250 次 `Handler.post` + 250 次跨 MethodChannel 编解码**
 * ⇒ 主线程被这两件事占满 ⇒ **掉帧**。
 *
 * 用户要的是「**一个字一个字出来**」—— 那是**观感**要求。
 * 观感的帧率上限就是屏幕刷新率（60 Hz = 16 ms）。
 * **推得比一帧还密，用户看不见，机器却要付钱。**
 *
 * ⇒ 所以：**把合并窗口对齐到一帧**（[Contract.Stream.FLUSH_INTERVAL_MS]）。
 *
 * ## 两条触发线（**主次分明**，这是实测调出来的）
 *
 * | 触发 | 角色 | 依据 |
 * |---|---|---|
 * | **[flushFrame]（帧节拍）** | **支配者** | 每 16 ms 无条件推一次 ⇒ 每秒恒定 ≈62 条 |
 * | **字符保险丝**（[maxChars]） | 保险丝 | 只在单帧异常大时提前泄洪，正常永不触发 |
 *
 * ⚠️ **主次不能颠倒**。早期版本把两者当"取先到者"，结果事件数被
 * **字符阈值**支配（与帧率无关）⇒ 真机只压缩 **2.0×**。
 * 详见 [flushFrame] 的说明与 `docs/25` §13。
 *
 * ## 刻意做成**纯逻辑类**，不碰线程/Flow
 *
 * 合并的**正确性**（绝不丢字、绝不重排、绝不重复）是最要紧的事，
 * 而它跟"谁来调它"无关。所以本类：
 *
 * - 不启动任何线程，不持有锁
 * - 时间通过方法参数**注入**，测试可以完全控制
 * - 唯一的输出口是 [append] / [flushFrame] / [flushAll] 返回的事件
 *
 * ⇒ 100% 可单测（见 `StreamCoalescerTest`），不需要 sleep、不会 flaky。
 *
 * ## ★ 不变量（测试逐条守卫）
 *
 * 1. **不丢字**：所有 `append` 的内容最终必定出现在某个事件里
 * 2. **不乱序**：正文与思考各自保持追加顺序
 * 3. **不跨轨合并**：`reasoning` 与 `text` **永不**合并成同一个事件
 *    （合并=用户永远分不清"想法"与"答案"，正是 `25` §2 错误一）
 * 4. **不吞终止**：`StepStarted`/`StepEnded` 这类结构性事件**原样直通**，
 *    绝不进缓冲 —— 否则 [AgentEvent.StepEnded] 会被它自己的 delta 挡住，UI 永远转圈
 *
 * @param maxChars 字符**保险丝**阈值，默认 [Contract.Stream.FLUSH_MIN_CHARS]
 */
class StreamCoalescer(
    private val maxChars: Int = Contract.Stream.FLUSH_MIN_CHARS,
    /** 帧节流窗口（毫秒）—— 一个窗口内最多推一次 */
    private val frameMs: Long = Contract.Stream.FLUSH_INTERVAL_MS,
) {

    /** 正文缓冲 —— 与思考**分开**，合并时绝不交叉 */
    private val textBuf = StringBuilder()

    /** 思考缓冲 */
    private val reasoningBuf = StringBuilder()

    /** 上一次推出事件的时刻 —— 帧节流的基准 */
    private var lastFlushMs: Long = Long.MIN_VALUE

    /** 本合并器归属的步骤（增量必须落在正确的卡片上） */
    private var stepId: String = ""

    // ------------------------------------------------------------------ 生命周期

    /** 开始一个新步骤 —— 先推出上一轮残留，再发 [AgentEvent.StepStarted] */
    fun startStep(stepId: String, nowMs: Long): List<AgentEvent> {
        val pending = flushAll()
        this.stepId = stepId
        // 新步骤重新计时 —— 否则第一步会被"上一轮刚推过"压住
        this.lastFlushMs = nowMs
        return pending + AgentEvent.StepStarted(stepId = stepId, title = "正在生成")
    }

    /**
     * 处理一个流式增量。返回**本次应当推出的**事件（可能为空）。
     *
     * ## ★ 这里**只做两件事**：攒字 + 帧节流判定
     *
     * 真机实测踩过**两次**，这两条结论都是花钱买来的
     * （`coalesceProbe`，529 chunk / 120 秒与 348 秒两次运行）：
     *
     * | 实现 | 实测压缩比 | 问题 |
     * |---|---|---|
     * | 时间**或**字符，取先到者 | **2.0×** | 事件数被字符支配，与帧率无关 |
     * | 纯"每帧一次"但**只在 chunk 到达时判** | **1.0×** | ★ 见下 |
     * | **本实现（节流 + 溢出保留）** | 见 `docs/25` §13 | —— |
     *
     * ### 为什么"每帧一次"必须配**溢出保留**
     *
     * chunk 之间的间隔是**变化的**：本地模型实测既有 ~170 ms 的（第一个探针），
     * 也有 **~660 ms** 的（第二次探针，负载不同）。若判定写成
     * "距离上次 flush ≥ 16 ms 就推"，那么 chunk 间隔一旦 > 16 ms，
     * **每个 chunk 都会各自触发一次推** ⇒ 压缩比 = 1.0×（完全不合并）。
     *
     * 修法：**一帧的时间窗内最多推一次，但窗口没到就继续攒**。
     * 关键是"窗口没到"时**必须把内容留在缓冲里**，而不是推出去。
     * 这样节流由**时间**决定，与 chunk 到达节奏解耦。
     *
     * @param nowMs 当前时刻
     */
    fun append(
        deltaText: String,
        deltaReasoning: String,
        nowMs: Long,
    ): List<AgentEvent> {
        if (deltaReasoning.isNotEmpty()) reasoningBuf.append(deltaReasoning)
        if (deltaText.isNotEmpty()) textBuf.append(deltaText)

        // 保险丝：单次攒太多就提前泄洪（防止一帧内攒出巨型事件）
        val out = mutableListOf<AgentEvent>()
        out += flushIfOversized(reasoningBuf, ::reasoningEvent)
        out += flushIfOversized(textBuf, ::textEvent)

        // ★ 帧节流：距离上次推出**不足一帧**就继续攒（**不推**）
        if (nowMs - lastFlushMs < frameMs) return out

        // 到点了 ⇒ 推出本帧累积的全部内容
        out += flushUnconditional(reasoningBuf, ::reasoningEvent)
        out += flushUnconditional(textBuf, ::textEvent)
        lastFlushMs = nowMs
        return out
    }

    /**
     * **按帧节拍**推出攒下的内容 —— **无条件**（只要非空）。
     *
     * ⚠️ 调用者在**流结束时**（`done` chunk 到达）必须调一次，
     * 否则最后一个时间窗内的内容会留在缓冲里 —— 直到 `endStep` 才出来。
     * 虽然 `endStep` 也会推出，但那会让"最后一批字"的到达时间
     * 与实际生成时间错开（观感上就是"卡一下然后一次性出来"）。
     */
    fun flushFrame(nowMs: Long): List<AgentEvent> {
        val out = flushUnconditional(reasoningBuf, ::reasoningEvent) +
            flushUnconditional(textBuf, ::textEvent)
        lastFlushMs = nowMs
        return out
    }

    /** 把两个缓冲全部推出（步骤结束/循环退出时**必须**调，否则尾部字符丢失） */
    fun flushAll(): List<AgentEvent> = buildList {
        addAll(flushUnconditional(reasoningBuf, ::reasoningEvent))
        addAll(flushUnconditional(textBuf, ::textEvent))
    }

    /**
     * 结束当前步骤：先推出尾部残留，再发 [AgentEvent.StepEnded]。
     *
     * ⚠️ **必须调** —— 不调的话缓冲里最后几个字永远不会到达 UI
     * （用户看到的内容比模型实际生成的少一截，且无任何报错）。
     */
    fun endStep(
        status: String,
        durationMs: Long,
        summary: String,
        index: Int,
    ): List<AgentEvent> {
        val out = flushAll().toMutableList()
        out += AgentEvent.StepEnded(
            stepId = stepId,
            status = status,
            durationMs = durationMs,
            summary = summary,
            index = index,
        )
        return out
    }

    /** 供诊断：当前攒着还没推的字符数（正文 + 思考） */
    val pendingChars: Int get() = textBuf.length + reasoningBuf.length

    // ------------------------------------------------------------------ 内部

    /**
     * **保险丝**：单次攒得太多（≥ [maxChars]）就提前泄洪。
     *
     * 正常语速下**永远不会触发**（一帧内到不了 48 字），
     * 它防的是"模型一次性吐几千字、而下一帧还没到"这种极端情形 ——
     * 那种情况下单个事件会过大，主线程处理它的耗时本身就掉帧。
     *
     * ⚠️ 它**不参与**压缩比的支配（那是 [flushFrame] 的职责）。
     * 早期版本把保险丝当成主要触发条件，压缩比因此退化到 2.0×。
     */
    private fun flushIfOversized(
        buf: StringBuilder,
        make: (String) -> AgentEvent,
    ): List<AgentEvent> {
        if (buf.length < maxChars) return emptyList()
        val delta = buf.toString()
        buf.setLength(0)
        return listOf(make(delta))
    }

    /** **无条件**推出（只要非空）—— [flushFrame] / [flushAll] 用 */
    private fun flushUnconditional(
        buf: StringBuilder,
        make: (String) -> AgentEvent,
    ): List<AgentEvent> {
        if (buf.isEmpty()) return emptyList()
        val delta = buf.toString()
        buf.setLength(0)
        return listOf(make(delta))
    }

    /** 正文轨道的事件工厂（**只有**这一个入口，保证不会跟思考混） */
    private fun textEvent(delta: String): AgentEvent =
        AgentEvent.StepDelta(stepId = stepId, delta = delta)

    /** 思考轨道的事件工厂 */
    private fun reasoningEvent(delta: String): AgentEvent =
        AgentEvent.ReasoningDelta(stepId = stepId, delta = delta)
}
