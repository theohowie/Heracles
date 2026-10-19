package dev.heracles.agent

import dev.heracles.core.contract.Contract

/**
 * **工具分区计划** —— 决定哪些工具进冻结区（常驻）、哪些走 `search_tools` 披露。
 *
 * ## 为什么这段逻辑必须放在 `:agent`，而且必须是纯函数
 *
 * 真正装配工具的地方在 App 的 `AgentBridge`（Android 模块），那里**没法在纯 JVM 单测里跑**。
 * 而"哪个工具常驻"直接决定冻结前缀的字节（缓存命中率的前提）与门禁 G11/G13 ——
 * 它必须可测。所以把**决策**（本文件）与**构造**（AgentBridge 拿到 `WorkspaceFs` /
 * `ShellRunner` 之后 new 出实例）拆开：本文件只认工具名，不碰文件系统、不碰 shell、不碰 Android。
 *
 * ## ⚠️ ADR-035 S1b（2026-10-18）：**分级没了，只剩一套名单**
 *
 * 本地后端已删除 ⇒ 原来的三个概念里有两个**当场失去意义**，一并删除（不是改名）：
 *
 * | 已删 | 原语义 | 为什么没存在理由了 |
 * |---|---|---|
 * | `LOCAL_RESIDENT`（7） | 只有本地才有的 7 个 | 没有"本地"这个后端了 |
 * | `CLOUD_ONLY_RESIDENT`（+3） | 云端常驻、本地走长尾 | 同上；那 3 个现在**全员**常驻 |
 * | `CLOUD_ONLY_LONG_TAIL`（delete/move/copy） | 云端长尾、**本地彻底没有** | 同上；现在全员都能在长尾里拿到 |
 * | `residentNames(backend)` / `partition(candidates, backend)` 的 `backend` 形参 | 按后端选名单 | 只有一个后端了（D2：`backend: String` 在 S1b 删除） |
 *
 * ⇒ 今天只有 [RESIDENT] 一份名单 + [partition] 一个纯函数，**没有"哪个后端"这个输入**。
 * 历史与取舍见这里留下的注释（**不删理由**）：那些判断本身是真实的，只是服务的前端没了。
 *
 * ## 常驻 10 个 + `search_tools` 自己 = **11 ≤ 12**（只留 1 个空位）
 *
 * `search_tools` 自己的 schema **也进冻结区**（`AgentBridge` 把它追加在常驻之后一起交给
 * `AgentLoop`，`AgentLoop` 再把整份 `tools` 喂给 `PrefixBuilder`）⇒
 * 实际占用 = [RESIDENT].size + 1 = **11**，上限 [Contract.Tools.FROZEN_LIMIT] = 12。
 *
 * ⚠️ **所以往 [RESIDENT] 里加第 11 个名字就会把它顶到 12、加第 12 个就在
 * `PrefixBuilder.buildFrozen` 的 `require` 上当场抛**（不是"悄悄多一个工具"）。
 * 本轮（S1b）**实测占用 11/12**，`ToolZonePlanTest` 用显式断言钉住这个数 ——
 * 因为"本地后端下开不了会话"那个老坑正是这种越档，只是当年发生在本地那一档。
 *
 * ## 为什么 `find_files` / `grep_files` / `apply_patch` 现在**全员**常驻（原云端专有）
 *
 * · `find_files` / `grep_files`（P1-1）：只读、无副作用的"看代码"入口。云端上下文大、模型强，
 *   常驻它们能省掉"先 `search_tools` 再调用"的一整轮（典型任务第一步就是找代码）。
 *   当年不给本地是因为 4B 在工具数过 ~10 后选择准确率显著下降（契约 §4.1）—— 那条约束
 *   随本地退场，于是它们**没有理由再躲在长尾里**。
 * · `apply_patch`（F3b / P1-2）：**局部替换**。用户侧的痛点是模型默认 `write_file`
 *   **整文件重写**（抄错别处、烧 token），而 `apply_patch` 存在的全部理由就是防这个
 *   （见 `PatchTools.kt` 的对照表）；它此前在长尾里，要先 `search_tools` 才会被想起
 *   （模型只用"手头有"的工具）。当年提升它时撞上"本地 8 格已满（7 + `search_tools`）"的天花板，
 *   才做了"只让云端常驻"的取舍 —— 现在 12 格，**这个取舍自然消解**。
 *
 * 顺带留档"为什么当年不是新写一个 `old→new` 的 `edit`"：它的参数走 **JSON 通道**，而本地语法
 * `str ::= [^"\\]*` **禁转义**（`docs/27` §2.5 的本地时代记录；生成器已随 ADR-035 删除）——代码里的 `"` 与 `\`
 * （smali / XML / Java 字符串）**在本地根本生成不出来**。⇒ 本地可用的 `edit` 得先解决
 * "两段文本怎么过通道"（`apply_patch` 走 CDATA 天生免疫）。⚠️ **这个限制本身是本地时代的**
 * （`LOCAL_REQUIRES_GBNF`）⇒ 云端走原生 `tools` 时它**不适用**，随 ADR-035 一起退场。
 *
 * `ask_user` 只在有 UI 弹窗的调用方（App）里存在，CLI/测试不构造它 ——
 * 所以这里"白名单里有、候选里没有"是**正常情况**，按候选实际内容过滤即可，不要报错。
 *
 * ## 三个破坏性工具的"云端专有"也取消了（原 `CLOUD_ONLY_LONG_TAIL`）
 *
 * `delete_path` / `move_path` / `copy_path` 是**破坏性**文件操作（P1-3）。加它们时本地长尾
 * 已经 **11/12**，三个独立工具会变成 **14 > 12** ⇒ 当年只能"只在云端长尾"，
 * **代价是本地后端连 `search_tools` 都搜不到它们**（功能没丢：本地可用 `run_shell_command`
 * 执行 `rm` / `mv` / `cp`）。⇒ 今天长尾上限是 [Contract.Tools.LONG_TAIL_LIMIT]（24），
 * 全员都能拿到这三个；"少递一把刀"的顾虑也不需要了（那是 4B 的问题）。
 *
 * ## 越档 = 当场失败
 *
 * 超过上限直接 `require` 失败。**不静默截断**：截断会让模型
 * "以为没有这个工具"，而症状只是"任务莫名其妙做不成"，极难定位。
 */
object ToolZonePlan {

    /**
     * 常驻名单 —— **唯一**一份（ADR-035 S1b 之前分本地/云端两份）。
     *
     * 前 7 项与改动前 `AgentBridge` 的装配名单**一位不变、顺序不变**（历史锚点），
     * 后 3 项是原"云端专有"那三个（现在全员常驻）。
     *
     * ⚠️ 改这个列表 = 改冻结前缀的字节（首次请求 prefix cache 必 miss 一次），
     * 且**只剩 1 个空位**（10 + `search_tools` = 11 ≤ 12）—— 见类 KDoc。
     */
    val RESIDENT: List<String> = listOf(
        "list_files",
        "read_file",
        "write_file",
        "mkdir",
        "save_memory",
        "ask_user",
        "run_shell_command",
        "find_files",
        "grep_files",
        "apply_patch",
        // ★ 2026-10-19：计划从"首轮正文一次性解析"升级为**可反复调用的工具**。
        //   它必须常驻：模型每轮都要能改计划（新增/删除/改状态），
        //   走长尾的话每次都要先 search_tools —— 那会让"改计划"比"干活"还贵。
        //   占用：11 业务常驻 + search_tools = **12/12**（顶满；再加就要先挪走一个）。
        "update_plan",
    )

    /**
     * 常驻名单（保留函数形态：装配处与测试都按"名字列表"用它）。
     *
     * ADR-035 S1b 之前它收 `backend: String` 并按后端返回 7 / 10 个；本地后端删除后
     * 没有"哪个后端"这个输入了（D2）。**只有一份**。
     */
    fun residentNames(): List<String> = RESIDENT

    /**
     * 把候选工具分成常驻与长尾。
     *
     * @param candidates 全部候选（常驻候选与长尾候选混在一起 —— 本函数只按名字认，
     *   不关心某个工具是怎么构造出来的）
     * @return 两个列表都**保持 candidates 的相对顺序**（顺序确定 ⇒ 行为可复现），
     *   且**并集 = candidates**（S1b 起不再有"本地连候选都不算"的第三类工具）
     * @throws IllegalArgumentException 常驻或长尾数量超过 [Contract.Tools] 的上限
     */
    fun partition(candidates: List<AgentTool>): Partition {
        val residentNames = RESIDENT.toSet()
        val resident = candidates.filter { it.spec.name in residentNames }
        val longTail = candidates.filter { it.spec.name !in residentNames }

        val maxFrozen = Contract.Tools.FROZEN_LIMIT
        val maxLongTail = Contract.Tools.LONG_TAIL_LIMIT
        require(resident.size <= maxFrozen) {
            "常驻工具 ${resident.size} 个，超过上限 $maxFrozen" +
                "（Contract.Tools.FROZEN_LIMIT）。请把多出来的移到长尾 —— 静默截断会让模型" +
                "以为工具不存在：" + resident.map { it.spec.name }
        }
        require(longTail.size <= maxLongTail) {
            "长尾工具 ${longTail.size} 个，超过上限 $maxLongTail" +
                "（Contract.Tools.LONG_TAIL_LIMIT）。工具太多会让模型选错：" +
                longTail.map { it.spec.name }
        }
        return Partition(resident = resident, longTail = longTail)
    }

    /**
     * 分区结果。
     *
     * [resident] 进冻结区（常驻工具 schema 吃前缀预算），[longTail] 只在
     * `search_tools` 命中后披露。两个列表来自同一份 candidates、互不重叠，
     * **并集恒等于 candidates**（S1b 起 `CLOUD_ONLY_LONG_TAIL` 已删 —— 那是"并集不总是
     * candidates"的唯一来源）。
     */
    data class Partition(
        val resident: List<AgentTool>,
        val longTail: List<AgentTool>,
    )
}
