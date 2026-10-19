package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolRegistry
import dev.heracles.core.tool.ToolSpec

/**
 * **任务计划工具**（2026-10-19）—— 把计划从"首轮正文一次性 JSON"升级成**可读写的状态**。
 *
 * ## 为什么必须是工具（而不是继续解析正文）
 *
 * 旧机制：模型在首轮正文里输出 `{"plan":[…]}`，之后**再也没有接口改它**；
 * 推进靠"任意工具成功就勾一步" ⇒ 模型改主意，计划不动；做无关操作，进度条照涨。
 * 成熟产品的计划是**工具**（Codex `update_plan`）：模型随时可以新增/删除/重排/改状态。
 *
 * ## 为什么 `execute` 什么都不做
 *
 * 计划是**循环状态**（在 `AgentLoop` 里），工具实例拿不到它。所以
 * `AgentLoop` 在派发时**拦截**这个名字，自己解析 `steps` 并更新状态；
 * 这个 `execute` 只是"注册表/校验器需要 spec"的占位 —— 真跑到这里说明装配错了，
 * 因此返回**显式失败**而不是假装成功。
 */
class UpdatePlanTool : AgentTool {

    override val spec = ToolSpec(
        name = "update_plan",
        description = "更新任务计划（多步任务用）。传**完整**的步骤列表，每一步有 text 与 status；" +
            "可以随时新增/删除/重排步骤或改状态。计划会显示在界面上，并作为你下一轮的工作记忆。",
        parameters = listOf(
            ToolParam(
                "steps", "string",
                "JSON 数组，例如 " +
                    "[{\"text\":\"查看项目结构\",\"status\":\"done\"}," +
                    "{\"text\":\"写 index.html\",\"status\":\"active\"}," +
                    "{\"text\":\"验证页面\",\"status\":\"pending\"}]；" +
                    "status 取 pending / active / done（只允许一个 active）",
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome =
        ToolOutcome.Failure("update_plan 由 AgentLoop 处理（直接执行它说明装配出了问题）")
}

/**
 * **检索长尾工具的元工具** —— `26-编码层工具链与逆向引擎.md` §5.2。
 *
 * ## 为什么不能让所有工具都在冻结区
 *
 * 两条约束把工具数夹死了（`Contract.Tools.FROZEN_LIMIT`，S1b 起 = 12）：
 *
 * · 工具 schema 进冻结区 ⇒ 每个都吃 `cache_n` 的前缀预算，而目标是命中率 > 90%
 * · 契约 §4.1：可见工具过多 ⇒ **选择准确率下降**（该规律原是在 4B / 约 10 个上实测的）
 *
 * ⚠️ **2026-10-18 ADR-035 S1b**：原先它是"本地档 8 / 云端 12"（ADR-033 的分级）；
 * 本地后端删除后 `Contract.Zone` 与按后端取值全部删除，**只剩一档 12**。
 * 本类的披露上限也不再需要"跟档位走"（见构造参数 `maxPerCall`）。
 *
 * 而本阶段要加 10 个工具。⇒ 只能**两段式披露**：
 *
 * ```
 * 第 1 段：search_tools("解压 apk")     → 命中 unzip_file（schema 进 C 区）
 * 第 2 段：unzip_file(archive=…, dest_dir=…)
 * ```
 *
 * ## 为什么披露不会塌掉缓存（§2.1 的关键发现）
 *
 * 工具名**枚举在 GBNF 里**，而 GBNF 是**请求参数**，**不参与前缀计算**。
 * 进冻结区的只有常驻工具的 schema 文本。
 *
 * ⇒ 披露一个工具 = 改 grammar + 往历史里追加一条工具结果，
 * 而**冻结区逐字节不变** ⇒ 缓存继续命中。
 *
 * ⚠️ 这一点是**设计论证**，尚待 `:cli` 实测确认（风险 T-3）。
 *
 * @param disclosed **会话级**的已披露集合。由 AgentLoop 持有并传给
 *   grammar 构建（`ToolRegistry.namesFor(disclosed)`）。跨会话必须清空 ——
 *   否则第二个会话的 grammar 会比第一个长，前缀对不上。
 */
class SearchToolsTool(
    private val registry: ToolRegistry,
    private val disclosed: MutableSet<String>,
    /**
     * 一次最多披露几个。
     *
     * 默认**跟随注册表**的 [ToolRegistry.discloseLimit] —— 而它本身默认是
     * `Contract.Tools.DISCLOSE_LIMIT`（6）⇒ 只在一个地方配，**不需要两处各配一遍**。
     * （S1b 之前默认是"本地档 3"、云端另配 6；分级删除后只剩一个默认值。）
     */
    private val maxPerCall: Int = registry.discloseLimit,
) : AgentTool {

    override val spec = ToolSpec(
        name = "search_tools",
        description = "搜索更多可用的工具（当前列表外的：解压/打包、APK 反编译与签名、从零构建 APK、D8 转换、删除/移动/复制文件、撤销恢复等）。用关键词描述你想做的事，例如「解压 apk」「打包」「签名」「构建」「撤销」「恢复文件」。找到后那些工具立刻可用。当前工具不够用时先用它找一找。",
        parameters = listOf(
            ToolParam("query", "string", "你想做什么，用关键词描述，例如：解压 apk / 重新打包 / 签名 / 构建 apk"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val query = args["query"].orEmpty().trim()
        if (query.isBlank()) return ToolOutcome.Failure("query 为空")

        // ★ 披露上限取注册表的值（S1b 起唯一一档 = 6）。
        //   显式传 limit 而不用 search() 的默认值 —— 默认值在注册表里，这里再显式传一次，
        //   是为了让"文案里的 N"与"实际返回的条数"**永远是同一个数**。
        val found = registry.search(query, maxPerCall)

        // ★ 无命中时**如实说没找到**，并给出可用的工具名。
        //   硬凑"最接近的几个"会诱导模型去用它不该用的工具 —— 比"没找到"更糟。
        if (found.isEmpty()) {
            return ToolOutcome.Failure(
                "没有匹配「$query」的工具。当前可用的常驻工具：" +
                    registry.resident.map { it.name }.sorted().joinToString("、") +
                    "。可以换个更具体的关键词再搜（例如「解压」「打包」「apk」「构建」）。"
            )
        }

        // 记录披露 —— 供 grammar 枚举（ToolRegistry.namesFor）
        disclosed.addAll(found.map { it.name })

        val text = buildString {
            append("找到 ${found.size} 个工具（已启用，可直接调用）：\n")
            found.forEach { append(render(it)) }
            if (found.size >= maxPerCall) {
                append("\n（一次最多披露 $maxPerCall 个；还需要别的请再搜一次）")
            }
        }
        return ToolOutcome.Success(text)
    }

    /**
     * 渲染工具说明。参数顺序**保持 spec 里的声明顺序**（那是按重要性排的，
     * 字典序会把必填参数排到后面去）。
     */
    private fun render(spec: ToolSpec): String = buildString {
        append("- ").append(spec.name).append("：").append(spec.description).append('\n')
        spec.parameters.forEach { p ->
            append("    · ").append(p.name).append("（").append(p.type).append("）：")
            append(p.description)
            // ★ 两条独立的"可以不填"通道都要说给模型听（2026-10-18，F7b）：
            //   · optional    ⇒ **键可以不写**（缺键由实现走默认值）
            //   · allowEmpty  ⇒ 键要写，但**值可以是空串**
            //   这里是**模型唯一能"看见"可选性的地方**（冻结前缀 JSON 的 `required`
            //   数组是给机器/协议看的），漏说一条模型就会去填一个本可省略的参数。
            val hints = buildList {
                if (p.optional) add("可省略")
                if (p.allowEmpty) add("可以传空字符串")
            }
            if (hints.isNotEmpty()) append("（").append(hints.joinToString("，")).append("）")
            append('\n')
        }
    }
}
