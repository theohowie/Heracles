package dev.heracles.agent

/**
 * **任务计划**（2026-10-14，harness 核心机制之一）。
 *
 * ## 它解决什么（用户真机反馈）
 *
 * 用户原话：
 * > 「工作步骤就是把自己这一套工程展示出来，思考了什么，调用了什么工具，
 * >   完成了什么，**现在在干什么**」
 * > 「顶部显示任务计划（如「1.查看结构 ✓ 2.写HTML ←进行中 3.验证」）」
 *
 * 现状：模型每轮在**思考里**临时想待办（用户截图里能看到
 * "让我先思考核心功能：1. 4x4网格 2. 随机生成…"），但那只是
 * reasoning 文本 —— **不落盘、不结构化、UI 无法打勾、模型下一轮
 * 也不会稳定遵守**。
 *
 * ## 与 DeepSeek 工程描述的对应
 *
 * > 「规划器要**显式输出计划**，用户可预览、可修改」
 * > 「计划要绑定约束和完成标准」
 *
 * 本类就是那个"显式计划"。
 *
 * ## 与铁律 1（append-only）的关系
 *
 * 计划**只产生一次**（首轮），此后：
 * - 计划的**推进**不改写计划本身，只更新每一步的状态
 * - 给模型看的是"计划 + 当前进度"的渲染文本，作为 `Turn.User` append
 * - 用户在 UI 上看到的是同一份数据的可视化
 *
 * ## 为什么步骤状态要由 AgentLoop 推导而不是让模型自报
 *
 * 让模型每轮自报"我完成第几步了"是不可靠的（与任务「完成」判定
 * 不能用 LLM 自评是同一条纪律）。所以：
 * - **计划内容**由模型产出（它才有领域知识）
 * - **推进判定**由 AgentLoop 依据**真实工具执行记录**推导
 *   （见 `advance`），模型无法凭空宣称"第 3 步完成了"
 */
data class TaskPlan(
    /** 计划项（按执行顺序） */
    val steps: List<Step>,
) {
    /**
     * 单个计划步骤。
     *
     * @param text 人可读的一步（如"创建 index.html"）
     */
    data class Step(
        val text: String,
        val status: Status = Status.pending,
    )

    enum class Status {
        /** 还没做 */
        pending,

        /** 正在做（当前轮） */
        active,

        /** 已做完 */
        done,
    }

    /** 完成度（0..1）—— UI 显示进度用 */
    val progress: Double
        get() = if (steps.isEmpty()) 0.0
        else steps.count { it.status == Status.done }.toDouble() / steps.size

    /** 首轮之后把第一步标为 active（"现在在干什么"从第一个开始就有答案） */
    fun activated(): TaskPlan {
        if (steps.isEmpty() || steps.any { it.status != Status.pending }) return this
        val next = steps.toMutableList()
        next[0] = next[0].copy(status = Status.active)
        return copy(steps = next)
    }

    /** 渲染给模型看的文本（作为 `Turn.User` append，铁律 1） */
    fun render(): String = buildString {
        append("【当前任务计划与进度】\n")
        steps.forEachIndexed { i, s ->
            val mark = when (s.status) {
                Status.done -> "[x]"
                Status.active -> "[>]"
                Status.pending -> "[ ]"
            }
            append("$mark ${i + 1}. ${s.text}\n")
        }
        append("\n请只做**当前进行中**的那一步；做完继续下一步。")
    }

    /**
     * 序列化成 `update_plan` 同形状的 JSON 数组（2026-10-19）。
     *
     * 用途：**计划落盘**（`AgentBridge` 存 `.heracles/plans/<sessionId>.json`），
     * 让"继续这个会话"在重启/切会话后还能看到原计划。
     */
    fun toJson(): String = com.google.gson.JsonArray().also { arr ->
        steps.forEach { s ->
            arr.add(
                com.google.gson.JsonObject().apply {
                    addProperty("text", s.text)
                    addProperty("status", s.status.name)
                }
            )
        }
    }.toString()

    companion object {
        /**
         * 从落盘的 JSON 还原（与 [parseUpdate] 同一套形状与归一化）。
         *
         * 失败 ⇒ `null`（**不造空计划**，调用方据 null 视为"没有可恢复的计划"）。
         */
        fun fromJson(raw: String): TaskPlan? = parseUpdate(raw)

        /**
         * 从模型输出里解析计划（见 `02-契约规范.md` 的协议扩展）。
         *
         * 期望形态：
         * ```json
         * {"plan":["查看现有文件结构","创建 index.html","验证游戏可运行"]}
         * ```
         *
         * ⚠️ **解析失败返回 null** 而不是造一个空计划 ——
         * 与"未上报 ≠ 0"同一条纪律：编一个计划会让 UI 显示假进度。
         */
        fun parse(raw: String): TaskPlan? {
            // 与 `AgentOutputParser` 同一套解析（Gson 是 `:agent` 的已有依赖）——
            // 不引入新依赖，也不依赖 `:provider-http` 的持有对象（分层）
            val obj = runCatching {
                com.google.gson.JsonParser.parseString(raw)
            }.getOrNull() ?: return null
            if (!obj.isJsonObject) return null
            val arr = obj.asJsonObject.get("plan") ?: return null
            if (!arr.isJsonArray) return null
            val steps = arr.asJsonArray.mapNotNull { el ->
                val t = runCatching { el.asString }.getOrNull()
                if (t.isNullOrBlank()) null else Step(t.trim())
            }
            // ★★ 单步计划**有效**（2026-10-15 真机实测修复，BUG-3）★★
            //
            // ## 旧代码错在哪
            //
            // 旧实现 `if (steps.size < 2) return null` —— 理由是
            // 「单步清单没有进度可见的价值」。
            //
            // 用户实测（2026-10-14 21:14 截图）：
            // > 让它「read hello.txt and show me the content」
            // > 模型给了**单步计划**（读文件确实只需 1 步）
            // > → 「输出无法解析：plan 字段格式不对（需要至少 2 个字符串项）」
            // > → **白白浪费一整轮**
            //
            // ## 为什么那个理由站不住
            //
            // **单步任务是真实存在的**（"读个文件"、"看下目录"）。
            // 强制 ≥2 步会让模型面对两个坏选择：
            // ① 凑一个假的第 2 步（污染计划质量）
            // ② 干脆不产出计划（失去计划的全部价值）
            //
            // ## 判断"要不要显示"是 UI 的事，不是协议的事
            //
            // 协议层只该管"模型给的东西是否合法"——
            // 空数组才非法（那不是计划）。至于"1 步值不值得画一张卡片"
            // 是**展示决策**，交给 UI（`PlanChecklist` 可自行选择不渲染单步）。
            if (steps.isEmpty()) return null
            return TaskPlan(steps)
        }

        /**
         * 从 `update_plan` 工具的 `steps` 参数解析计划（2026-10-19）。
         *
         * 期望形态（JSON 数组；元素可以是对象或纯字符串）：
         * ```json
         * [{"text":"看结构","status":"done"},{"text":"写页面","status":"active"},{"text":"验证"}]
         * ```
         *
         * ## 归一化（不是"猜意图"，是**让状态机自洽**）
         *
         * - 字符串元素 ⇒ 视为 `pending` 的一步（宽容旧写法）
         * - `status` 认不出 ⇒ `pending`
         * - **多个 active** ⇒ 只保留第一个，其余降为 `pending`（UI 的"现在在干什么"必须有唯一答案）
         * - **没有 active 且有未完成步** ⇒ 第一个未完成步变 `active`
         * - 空数组 / 没有合法文本 ⇒ `null`（**不造空计划**，同 `parse` 的纪律）
         */
        fun parseUpdate(stepsJson: String): TaskPlan? {
            val el = runCatching {
                com.google.gson.JsonParser.parseString(stepsJson.trim())
            }.getOrNull() ?: return null
            if (!el.isJsonArray) return null

            var steps = el.asJsonArray.mapNotNull { e ->
                if (e.isJsonPrimitive) {
                    val t = runCatching { e.asString }.getOrNull()?.trim()
                    return@mapNotNull if (t.isNullOrBlank()) null else Step(t, Status.pending)
                }
                val o = runCatching { e.asJsonObject }.getOrNull() ?: return@mapNotNull null
                val t = o.get("text")
                    ?.let { runCatching { it.asString }.getOrNull() }
                    ?.trim()
                if (t.isNullOrBlank()) return@mapNotNull null
                val raw = o.get("status")
                    ?.let { runCatching { it.asString }.getOrNull() }
                    ?.lowercase()
                val status = when (raw) {
                    "done", "completed", "complete", "完成", "已完成" -> Status.done
                    "active", "doing", "current", "进行中", "正在做" -> Status.active
                    else -> Status.pending
                }
                Step(t, status)
            }
            if (steps.isEmpty()) return null

            val activeIdx = steps.indexOfFirst { it.status == Status.active }
            if (activeIdx >= 0) {
                steps = steps.mapIndexed { i, s ->
                    if (s.status == Status.active && i != activeIdx) {
                        s.copy(status = Status.pending)
                    } else s
                }
            } else {
                val firstUndone = steps.indexOfFirst { it.status != Status.done }
                if (firstUndone >= 0) {
                    steps = steps.toMutableList().also {
                        it[firstUndone] = it[firstUndone].copy(status = Status.active)
                    }
                }
            }
            return TaskPlan(steps)
        }
    }
}
