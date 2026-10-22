package dev.heracles.cloud

import dev.heracles.agent.AgentTool
import dev.heracles.cloud.context.AgentMessage
import dev.heracles.cloud.context.ContextManager
import dev.heracles.cloud.context.ConversationSummarizer
import dev.heracles.cloud.tool.CloudTool
import dev.heracles.cloud.tool.CloudToolRegistry
import dev.heracles.cloud.tool.ToolBuilder
import dev.heracles.cloud.tool.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.tool.CloudParam
import dev.heracles.core.tool.ParamType
import dev.heracles.core.text.TextMath

/**
 * **新管线装配器** —— 把现有的 [AgentTool] 集合与 [ModelProvider] 接到
 * [CloudAgentPipeline] 上。
 *
 * ## 设计要点：**复用工具实现，重建工具声明**
 *
 * 工具**执行体**（`AgentTool.execute`）一个都不用重写 —— 它们是对的。
 * 要重建的只有**声明**（`spec`）：旧 `ToolParam` 只能表达 string，
 * 新 `CloudParam` 能表达 integer/boolean/array/enum。
 *
 * ## 模块五的常驻队列修复
 *
 * | 工具 | 旧位置 | 新位置 | 理由 |
 * |---|---|---|---|
 * | `edit` | **长尾**（12 格顶满被挤走） | **常驻** | 它存在的全部理由就是防"整文件重写"；藏起来等于不存在 |
 * | `apply_patch` | 常驻 | 常驻 | 局部替换的主力 |
 * | `read_file`/`list_files`/`write_file`/`mkdir` | 常驻 | 常驻 | 高频 |
 * | `find_files`/`grep_files` | 常驻 | 常驻 | 看代码的第一步 |
 * | `run_shell_command` | 常驻 | 常驻 | 构建/逆向全走它 |
 * | `update_plan`/`ask_user`/`save_memory` | 常驻 | 常驻 | 元能力 |
 * | `apk_*`/`d8_convert`/`zip_*`/`delete_path`/`move_path`/`copy_path`/`restore_path`/`web_fetch`/`view_image` | 长尾 | **可检索** | 低频，但**检索到即可当轮调用**（不像旧机制要多跑一轮） |
 */
object CloudPipelineAssembler {

    /**
     * 从现有 [AgentTool] 列表构造云端注册表。
     *
     * @param tools 现有工具实例（执行体原样复用）
     * @param typedSpecs 名字 → 类型化参数声明。**没给的工具退回旧 spec**
     *   （`jsonSchema` 为空 ⇒ provider 走旧渲染，不会崩）
     */
    fun buildRegistry(
        tools: List<AgentTool>,
        typedSpecs: Map<String, TypedToolDecl> = TYPED_DECLS,
    ): CloudToolRegistry {
        val residentNames = RESIDENT_NAMES
        val cloudTools = tools.map { tool ->
            val name = tool.spec.name
            val decl = typedSpecs[name]
            val spec = if (decl != null) {
                dev.heracles.core.tool.cloudToolSpec(decl.name, decl.description, decl.params)
            } else {
                // 没给类型化声明 ⇒ 用旧 spec（jsonSchema 为 null ⇒ 旧渲染路径）
                tool.spec
            }
            CloudTool(
                spec = spec,
                run = { args -> tool.execute(args).toCloudOutcome() },
                parallelSafe = tool.parallelSafe,
                keywords = decl?.keywords.orEmpty(),
                isMeta = name in META_NAMES,
            )
        }

        // ★ 常驻名单顺序固定（确定性 ⇒ 前缀缓存前提）
        val resident = residentNames.mapNotNull { n -> cloudTools.firstOrNull { it.spec.name == n } }
        val disclosable = cloudTools.filter { it.spec.name !in residentNames }
        return CloudToolRegistry(resident = resident, disclosable = disclosable)
    }

    /** 旧 [dev.heracles.agent.ToolOutcome] → 新 [ToolOutcome]（纯映射，不改语义）。 */
    private fun dev.heracles.agent.ToolOutcome.toCloudOutcome(): ToolOutcome = when (this) {
        is dev.heracles.agent.ToolOutcome.Success -> ToolOutcome.Success(detail)
        is dev.heracles.agent.ToolOutcome.SuccessWithImage ->
            ToolOutcome.SuccessWithImage(detail, imageDataUrl)
        is dev.heracles.agent.ToolOutcome.Failure -> ToolOutcome.Failure(reason)
        is dev.heracles.agent.ToolOutcome.NeedsApproval -> ToolOutcome.NeedsApproval(detail)
    }

    /** 用 provider 跑一次摘要（[ContextManager] 的依赖）。 */
    fun summarizer(provider: ModelProvider): ConversationSummarizer =
        object : ConversationSummarizer {
            override suspend fun summarize(dropped: List<AgentMessage>): String {
                val transcript = buildString {
                    dropped.forEach { m ->
                        append("【").append(m.role.name.lowercase()).append("】")
                        append(m.text).append('\n')
                    }
                }
                val prompt = dev.heracles.cloud.prompt.CloudPrompts.SUMMARY +
                    "\n\n---\n\n" + transcript
                val result = provider.generate(
                    GenerateRequest(
                        prompt = prompt,
                        // ★ 必须 ≥ 4096：思考与正文共享 max_tokens，
                        //   1024 会被思考吃光 ⇒ 摘要为空 ⇒ 压缩静默失效
                        //   （旧实现 AgentLoop.kt:1238 就是这个 bug）。
                        maxOutputTokens = ContextManager.MIN_SUMMARY_OUTPUT_TOKENS,
                        structuredOutput = null,
                        deterministic = false,
                    )
                ).getOrThrow()
                return result.text
            }
        }

    /**
     * 构造完整管线。
     *
     * @param modelContextWindow 模型的真实上下文窗口。**优先用服务端上报的值**
     *   （`ModelCapability.contextWindow`）；拿不到时才用 [defaultWindowFor]。
     * @param approval **审批门禁**。生产装配**必须传** —— 不传等于关掉危险操作审批
     *   （见 `CloudAgentPipeline` 的 `approval` KDoc：那是安全底线，不是可选项）。
     *   只有单测 / 无 UI 的 CLI 才该传 `null`，且必须明确知道自己不需要审批。
     */
    fun build(
        provider: ModelProvider,
        tools: List<AgentTool>,
        modelContextWindow: Int = defaultWindowFor(provider),
        approval: ApprovalGate? = null,
        askGate: AskGate? = null,
        onPlanChanged: (suspend (List<PlanStepView>) -> Unit)? = null,
        onEvent: ((CloudEvent) -> Unit)? = null,
    ): CloudAgentPipeline {
        val registry = buildRegistry(tools)
        return CloudAgentPipeline(
            provider = provider,
            registry = registry,
            modelContextWindow = modelContextWindow,
            contextManager = ContextManager(
                modelContextWindow = modelContextWindow,
                summarizer = summarizer(provider),
            ),
            approval = approval,
            askGate = askGate,
            onPlanChanged = onPlanChanged,
            onEvent = onEvent,
        )
    }

    /**
     * 上下文窗口兜底。
     *
     * ## 为什么 fallback 是 128K 而不是 4096
     *
     * 旧代码 `Contract.Context.DEFAULT_CTX = 4096` 是**本地 llama.cpp 的内存实测值**
     * （注释自己写着"4096 下内存已紧张"）。把它当云端兜底会让压缩在 3.2K token
     * 就触发 —— 那是**严重过早压缩**（AGENTS.md 记录的 `实测` 正是这个 bug）。
     *
     * 128K 是主流云端模型的**保守下限**（GPT-4o 128K / Claude 200K / Qwen-Max 128K）。
     * 更大的窗口请由服务端上报（`GET /v1/models` 的 `contextWindow` 字段）。
     */
    fun defaultWindowFor(provider: ModelProvider): Int =
        if (provider.kind == dev.heracles.core.provider.ProviderKind.CLOUD) {
            Contract.Context.DEFAULT_CLOUD_CTX
        } else {
            Contract.Context.DEFAULT_CTX
        }

    /** 常驻名单 —— 顺序固定。 */
    val RESIDENT_NAMES: List<String> = listOf(
        "list_files",
        "read_file",
        "write_file",
        // ★★ 模块五-1：`edit` 与 `apply_patch` **都**常驻。
        //    旧 `ToolZonePlan.RESIDENT` 12 格顶满把 edit 挤到长尾 ⇒ 模型想不起用它
        //    ⇒ 继续整文件重写（而那正是 edit 存在的理由）。
        "edit",
        "apply_patch",
        "mkdir",
        "find_files",
        "grep_files",
        "run_shell_command",
        "update_plan",
        "ask_user",
        "save_memory",
    )

    private val META_NAMES = setOf("search_tools", "update_plan", "ask_user")
}

/** 一个工具的**类型化声明**（云端原生 schema 用）。 */
data class TypedToolDecl(
    val name: String,
    val description: String,
    val params: List<CloudParam>,
    val keywords: List<String> = emptyList(),
)

/**
 * 类型化声明表 —— **这是模块一的核心交付**。
 *
 * 每个参数都给了真实类型。旧实现这里是 55 个 `"string"`。
 */
val TYPED_DECLS: Map<String, TypedToolDecl> = mapOf(
    "read_file" to TypedToolDecl(
        name = "read_file",
        description = "读取工作区里一个文本文件。大文件可用 offset/limit 分段读。" +
            "写补丁前建议传 numbered=true 拿到行号。",
        params = listOf(
            CloudParam("path", ParamType.Text, "相对于工作区的文件路径"),
            CloudParam("offset", ParamType.Int, "起始行号（1-based）。整读时省略", required = false),
            CloudParam("limit", ParamType.Int, "最多读多少行。整读时省略", required = false),
            CloudParam("numbered", ParamType.Bool, "是否给每行加行号（cat -n 风格）。默认 false", required = false),
        ),
        keywords = listOf("读", "查看", "文件内容", "read"),
    ),
    "write_file" to TypedToolDecl(
        name = "write_file",
        description = "把完整内容写入工作区里的文件（自动建父目录）。新建文件或大改时用它；" +
            "只改几行请用 edit / apply_patch。",
        params = listOf(
            CloudParam("path", ParamType.Text, "相对于工作区的文件路径"),
            CloudParam("content", ParamType.Text, "要写入的完整文件内容"),
        ),
        keywords = listOf("写", "新建", "创建文件", "write"),
    ),
    "edit" to TypedToolDecl(
        name = "edit",
        description = "把文件里的 old_string（原文，逐字符一致、含缩进）替换成 new_string。" +
            "默认要求 old_string 只出现一次；出现多次会失败（请给更多上下文，或 replace_all=true）。" +
            "new_string 传空串 = 删除该段。**改代码优先用它**，比整文件重写更安全省 token。",
        params = listOf(
            CloudParam("path", ParamType.Text, "要修改的文件路径（必须已存在）"),
            CloudParam("old_string", ParamType.Text, "要被替换的原文（逐字符一致，含缩进换行）"),
            CloudParam("new_string", ParamType.Text, "替换后的文本；空字符串表示删除"),
            CloudParam("replace_all", ParamType.Bool, "true = 替换所有出现处；默认 false", required = false),
        ),
        keywords = listOf("改", "替换", "修改", "edit", "replace"),
    ),
    "apply_patch" to TypedToolDecl(
        name = "apply_patch",
        description = "应用 unified diff 补丁（@@ 定位块，- 删 + 增）。" +
            "任何一块匹配不上则整体失败、文件一个字节都不改。适合多处、小幅修改。",
        params = listOf(
            CloudParam("path", ParamType.Text, "要修改的文件路径（必须已存在）"),
            CloudParam("patch", ParamType.Text, "unified diff 文本"),
        ),
        keywords = listOf("补丁", "diff", "patch", "批量改"),
    ),
    "list_files" to TypedToolDecl(
        name = "list_files",
        description = "列出一个目录下的文件与子目录（不递归）。不确定项目结构时先用它。",
        params = listOf(
            CloudParam("dir", ParamType.Text, "相对工作区的目录路径，根目录传空字符串", required = false),
        ),
        keywords = listOf("列出", "目录", "ls", "list"),
    ),
    "mkdir" to TypedToolDecl(
        name = "mkdir",
        description = "创建目录（含父目录）。",
        params = listOf(CloudParam("dir", ParamType.Text, "相对工作区的目录路径")),
        keywords = listOf("建目录", "mkdir", "创建目录"),
    ),
    "find_files" to TypedToolDecl(
        name = "find_files",
        description = "按文件名通配查找工作区里的文件（只返回文件）。" +
            "支持 * ? ** 以及 [abc] 字符集和 {kt,java} 枚举。",
        params = listOf(
            CloudParam("pattern", ParamType.Text, "通配，例如 *.kt、src 双星号 星号.java、*.{kt,java}"),
            CloudParam("dir", ParamType.Text, "在哪个目录下搜索；不传 = 工作区根", required = false),
            CloudParam("max_results", ParamType.Int, "最多返回多少条，默认 40，最多 200", required = false),
        ),
        keywords = listOf("找文件", "查找", "find", "文件名"),
    ),
    "grep_files" to TypedToolDecl(
        name = "grep_files",
        description = "在工作区文件内容里按正则搜索，返回「相对路径:行号:行内容」。",
        params = listOf(
            CloudParam("pattern", ParamType.Text, "Java 正则，例如 TODO|FIXME"),
            CloudParam("dir", ParamType.Text, "在哪个目录下搜索；不传 = 工作区根", required = false),
            CloudParam("max_results", ParamType.Int, "最多返回多少处，默认 40，最多 200", required = false),
            CloudParam("ignore_case", ParamType.Bool, "忽略大小写；默认 false", required = false),
        ),
        keywords = listOf("搜内容", "grep", "查找代码"),
    ),
    "run_shell_command" to TypedToolDecl(
        name = "run_shell_command",
        description = "在工作区里执行一条 shell 命令（如 ls、grep、aapt2、javac、d8）。" +
            "命令在工作区目录下运行。返回错误摘录，完整日志落盘可用 read_file 读。",
        params = listOf(
            CloudParam("command", ParamType.Text, "要执行的命令"),
            CloudParam("cwd", ParamType.Text, "工作目录（相对工作区）；不填 = 工作区根", required = false),
            CloudParam("timeout_sec", ParamType.Int, "超时秒数，默认 120，最大 900", required = false),
        ),
        keywords = listOf("执行命令", "shell", "运行", "构建"),
    ),
    "update_plan" to TypedToolDecl(
        name = "update_plan",
        description = "更新任务计划（多步任务用）。传**完整**的步骤列表，可随时新增/删除/重排/改状态。" +
            "计划会显示在界面上，并作为你下一轮的工作记忆。",
        params = listOf(
            CloudParam(
                "steps",
                ParamType.Array(
                    items = ParamType.Object(
                        props = listOf(
                            CloudParam("text", ParamType.Text, "这一步要做什么"),
                            CloudParam(
                                "status", ParamType.Text, "pending / active / done（只允许一个 active）",
                                enum = listOf("pending", "active", "done"),
                            ),
                        )
                    ),
                ),
                "完整的步骤列表",
            ),
        ),
        keywords = listOf("计划", "待办", "plan", "步骤"),
    ),
    "ask_user" to TypedToolDecl(
        name = "ask_user",
        description = "当你需要用户做决策、确认方案或补充信息时，向用户提问。**必须给选项**（用户点选）。" +
            "可以一次问多个问题，用户会逐题作答。用于：需求不明确、有多种做法要选、缺关键信息。",
        params = listOf(
            CloudParam(
                "questions",
                ParamType.Array(
                    items = ParamType.Object(
                        props = listOf(
                            CloudParam("id", ParamType.Text, "题目唯一 id，回答按它回填"),
                            CloudParam("question", ParamType.Text, "题干"),
                            CloudParam("multi", ParamType.Bool, "true = 多选，false = 单选", required = false),
                            CloudParam(
                                "options",
                                ParamType.Array(
                                    items = ParamType.Object(
                                        props = listOf(
                                            CloudParam("label", ParamType.Text, "用户看到的选项文字（回答用它回传）"),
                                            CloudParam("description", ParamType.Text, "补充说明，可为空", required = false),
                                        )
                                    ),
                                ),
                                "至少 1 个选项",
                            ),
                        )
                    ),
                ),
                "题目列表",
            ),
        ),
        keywords = listOf("问用户", "确认", "选项", "ask"),
    ),
    "save_memory" to TypedToolDecl(
        name = "save_memory",
        description = "记住一条跨会话的信息（用户偏好、项目背景、踩过的坑）。",
        params = listOf(CloudParam("content", ParamType.Text, "要记住的一条信息，一句话写清楚")),
        keywords = listOf("记忆", "记住", "memory"),
    ),
)
