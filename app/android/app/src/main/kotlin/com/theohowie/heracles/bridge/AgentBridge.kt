package com.theohowie.heracles.bridge

import android.content.Context
import dev.heracles.agent.AgentEvent
import dev.heracles.agent.AgentLoop
import dev.heracles.agent.AgentRunResult
import dev.heracles.agent.AgentTool
import dev.heracles.agent.ApprovalMode
import dev.heracles.agent.TaskPlan
import dev.heracles.agent.ToolZonePlan
import dev.heracles.agent.TurnRecord
import dev.heracles.agent.tools.AndroidTools
import dev.heracles.agent.tools.AskUserTool
import dev.heracles.agent.tools.FindFilesTool
import dev.heracles.agent.tools.GrepFilesTool
import dev.heracles.agent.tools.ImageTools
import dev.heracles.agent.tools.WebTools
import dev.heracles.agent.tools.ListFilesTool
import dev.heracles.agent.tools.MkdirTool
import dev.heracles.agent.tools.PathTools
import dev.heracles.agent.tools.PatchTools
import dev.heracles.agent.tools.ReadFileTool
import dev.heracles.agent.tools.RunShellCommandTool
import dev.heracles.agent.tools.SaveMemoryTool
import dev.heracles.agent.tools.SearchToolsTool
import dev.heracles.agent.tools.UnzipFileTool
import dev.heracles.agent.tools.UpdatePlanTool
import dev.heracles.agent.tools.WriteFileTool
import dev.heracles.agent.tools.ZipFileTool
import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ReasoningLevel
import dev.heracles.core.tool.ToolRegistry
import dev.heracles.provider.http.AnthropicProvider
import dev.heracles.provider.http.OpenAiCompatProvider
import dev.heracles.provider.http.OpenAiResponsesProvider
import dev.heracles.toolchain.ToolchainLocator
import dev.heracles.workspace.PosixStorage
import dev.heracles.workspace.StorageBackedWorkspaceFs
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceStorage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import android.util.Base64
import java.io.File

/**
 * Kotlin 侧的会话运行器 —— Flutter 通过 Platform Channel 调它。
 *
 * ## 为什么逻辑必须在 Kotlin
 *
 * `AgentLoop` / `Session` / `PrefixBuilder` 是**已验证的资产**
 * （66 项测试 + 实测 06/07/08/09/10），且缓存纪律（铁律 1）
 * 在 Kotlin 层由**类型**保障（`Session` 只暴露 `append()`）。
 * Dart 无法复制这个保障。见 `15-前端选型与通道协议.md` §2。
 *
 * ## 当前实现范围
 *
 * 这一版实现**单次运行**（一次请求 → 完整结果），不做流式推送。
 * 流式（EventChannel）在下一步 —— 先把链路跑通，再优化交互。
 *
 * ## 后端选择
 *
 * | 值 | 后端 | 用途 |
 * |---|---|---|
 * | `cloud` | OpenAI 兼容 | **发行版（唯一）** |
 * | `local` | llama-server | ⛔ **2026-10-18 起已废弃**（ADR-035；代码删除进行中，见下） |
 *
 * ⚠️ **`local` 分支是一条"已知会撞墙"的路径，不是漏做**（S2 之后的如实描述）：
 * S1b/S2 把工具面与预算全部按云端档收敛（**11 个工具的冻结区** + **200 行摘录** +
 * **40 轮 / 120 次调用**），而本地 llama.cpp 是 **4096 上下文** ⇒ 这个组合**几乎必然撑爆**。
 * 同时 Dart 侧仍在给自建（`openaiChat` + selfHosted）与"未配置 provider"发 `backend='local'`
 * （`app/lib/services/agent_bridge.dart` 的 `backend` 三元表达式）。
 * **S4 会删掉 Dart 的本地预设与这条映射**；在那之前用户若选「自建」会看到失败 ——
 * **已知且有时限的窗口**（ADR-035 的删除顺序：S3 删 `LlamaServerProvider` / S4 删 App 侧）。
 * `enable_thinking` 那一整套已随 S1a/S2 从云端 wire 上摘掉。
 */
class AgentBridge(private val context: Context) {

    /**
     * 跑一次 agent 会话。
     *
     * @param workspacePath 工作区绝对路径（**用户选的已有文件夹**）
     * @param request 用户请求
     * @param attachments 附件（path/name/kind）—— 内容在这里读取
     * @param backend `local` 或 `cloud`
     * @param baseUrl 后端地址（local 默认 127.0.0.1:8080；cloud 必填）
     * @param apiKey 云端 Key（local 忽略）
     * @param modelName 模型名
     * @param onEvent **可选**实时事件回调（2026-10-10 流式）。默认 `null` ——
     *   不传就与旧行为完全一致（只有最终 `AgentRunResult`）。
     *   ⚠️ 回调在 **IO 线程**被调用，调用方负责切主线程（见 `MainActivity`）。
     * @return 运行结果（含每轮记录）
     */
    suspend fun run(
        workspacePath: String,
        request: String,
        backend: String,
        baseUrl: String,
        apiKey: String,
        modelName: String,
        attachments: List<Map<String, String>> = emptyList(),
        treeUri: String = "",
        /**
         * 最大推理轮次。**`<= 0` = 按后端自动**（ADR-033 / P0-1，2026-10-18）。
         *
         * 改造前这里是硬默认 `8`，而 `MainActivity` **从不传参** ⇒ 真机上恒定 8 轮，
         * UI 无法调（`docs/27` §2.2）。云端模型用它跑「脚手架 → 改码 → 构建」必然
         * 撞墙（实测症状：`达到最大轮次（8），任务未完成`）。
         *
         * 现在：`0` ⇒ 交给 [Contract.Budget.MAX_TURNS]（40）；
         * 传正数则以调用方为准（设置项就靠这条覆盖默认档）。
         */
        maxTurns: Int = 0,
        /**
         * **推理等级**（2026-10-12，S4/S5）—— 由输入框上方那个开关传下来。
         *
         * `null` / 认不出 → [ReasoningLevel.AUTO]（= 与改造前完全一致）。
         * 真正的"认不出的值"过滤在 `MainActivity.parseReasoningLevel`，
         * 那里会留一条日志；这里只负责把值交给 [AgentLoop]。
         */
        reasoningLevel: ReasoningLevel = ReasoningLevel.AUTO,
        /**
         * **历史对话**（2026-10-14 新增）—— 之前的 (用户消息, 助手回答) 对。
         *
         * ## 为什么需要
         *
         * 用户实测：「让他继续完成任务，他输出了又是**没有记忆了**」。
         * 根因：`AgentLoop.run` 每次都 `Session.start()` 从零开始 ——
         * 用户看到的对话历史（Dart 侧）与模型看到的上下文（session）
         * 是**两套东西**。
         *
         * 由 `MainActivity` 从会话文件读出来传进来（按时间正序）。
         * 空 = 首次对话（与旧行为一致）。
         */
        history: List<Pair<String, String>> = emptyList(),
        /**
         * **当前会话 id**（2026-10-19）—— 用于**计划落盘**。
         *
         * 计划（`TaskPlan`）活在 `AgentLoop` 内存里，切会话/重启后会丢；
         * 这里按会话把计划存在 `.heracles/plans/<sessionId>.json`，下次 run 读回来
         * 传给 `initialPlan`。`null` / 空 = 不落盘（CLI / 测试路径行为不变）。
         */
        sessionId: String? = null,
        /**
         * **审批档位**（2026-10-19）—— 来自设置里的 `PermissionMode`。
         *
         * 缺省 [ApprovalMode.WORKSPACE_AUTO]（与接档位之前行为一致：
         * 只在工具返回 `NeedsApproval` 时问用户）。
         */
        approvalMode: ApprovalMode = ApprovalMode.WORKSPACE_AUTO,
        /**
         * **ask_user 弹窗回调**（2026-10-16 用户需求）——
         * 模型调 `ask_user` 工具时触发；UI 弹窗收集回答。
         *
         * 回答由 MainActivity 经 `replyAsk` 通道写回
         * [AgentLoop.AskReplyQueue]，工具拿到后继续。
         *
         * 不传 = ask_user 不可用（工具列表里也不会有它 —— CLI 场景）。
         */
        onAskUser: ((question: String) -> Unit)? = null,
        onEvent: ((AgentEvent) -> Unit)? = null,
        /**
         * **过程态落盘回调**（2026-10-12，S5）—— 一步一次。
         *
         * ⚠️ 它在 **IO 线程**被调用（整个 `run` 都在 `Dispatchers.IO`），
         * 所以实现里**必须自己 `withContext(Dispatchers.IO)`**（幂等，安全）
         * 或直接用阻塞 IO —— 详见 `MainActivity` 的落盘实现。
         *
         * 不传 = 与旧行为完全一致（过程不落盘）。
         */
        onStepEnded: ((
            index: Int,
            stepId: String,
            thinking: String,
            text: String,
            status: String,
            durationMs: Long,
            title: String,
        ) -> Unit)? = null,
        /**
         * **用户插话队列**（2026-10-13，思考间隙引导）——
         * MainActivity 在 run 期间持有它；`interruptRun` 通道往里 offer。
         * 不传 = 无插话能力（与旧行为一致）。
         */
        interruptQueue: AgentLoop.InterruptQueue = AgentLoop.InterruptQueue.EMPTY,
    ): AgentRunResult = withContext(Dispatchers.IO) {

        val provider: ModelProvider = when (backend) {
            "anthropic" -> AnthropicProvider(
                id = "anthropic:$modelName",
                baseUrl = baseUrl.ifBlank { AnthropicProvider.DEFAULT_BASE_URL },
                apiKey = apiKey,
                modelName = modelName.ifBlank { "claude-sonnet-4-5" },
            )
            "responses" -> OpenAiResponsesProvider(
                id = "responses:$modelName",
                baseUrl = baseUrl,
                apiKey = apiKey,
                modelName = modelName.ifBlank { "gpt-4o" },
            )
            "cloud" -> OpenAiCompatProvider(
                id = "cloud:$modelName",
                baseUrl = baseUrl.ifBlank { OpenAiCompatProvider.DASHSCOPE_BASE_URL },
                apiKey = apiKey,
                modelName = modelName.ifBlank { "qwen3.8-flash" },
                // ★ S2（ADR-035）：`disableThinking` **参数已删** —— 不再有"要不要发
                //   Qwen3 专有 `enable_thinking`"这个决定点。理由与代价见 provider 的类 KDoc：
                //   发它给 DeepSeek / 中转站会 `HTTP 400`（实测），而删掉后 DashScope/Qwen3
                //   失去了关思考的开关（本地实测 5.1 倍 slowdown）—— 恢复要靠"按端点判断"，
                //   那是另一件事，别在这里偷偷加回来。
            )
            else -> error(
                "本地后端已删除（ADR-035）。请选择云端 provider（如 tokenrhythm / deepseek-flash）；" +
                    "自建/未配置路径会在 S4 一并清理（当前 backend=\"$backend\"）。",
            )
        }

        provider.load(ProviderConfig()).getOrElse { e ->
            error("无法连接 $backend 后端（${e.message}）")
        }

        // ---- 选存储后端（2026-10-10 路线 A）----
        //
        // 用户在侧边栏选的文件夹，可能有两种访问方式：
        //
        //   1. **SAF**（treeUri 非空）—— 分区存储下的默认路径。
        //      真机实测：用户目录属 media_rw 组，我们的 App 不在组里，
        //      所以 java.io.File 写不了，必须走 DocumentFile。
        //   2. **POSIX** —— 应用私有目录，或已获全盘权限时。
        //
        // [WorkspaceStorage] 抽象掉这个差异，上层的工具层完全不用感知。
        // ★★ 工作区自愈（2026-10-20）—— App 的依赖目录由 App 自己建，**不问用户** ★★
        //
        // ## 产品约定（用户原话）
        //
        // 「所有的依赖文件是 APP 自己给根目录的，包括 `.heracles`。用户随便拿一个新的、
        //   且空的文件夹给你，你都可以直接在上面完成；或者这个文件夹里面有内容，
        //   也可以直接接管。**这不是要报错的问题**，这个地方是 APP 自带的功能。」
        //
        // ## 旧行为错在哪
        //
        // 原来这里只有一句 `if (!storage.isWritable()) error(...)`。
        // 于是"工作区目录被外部删掉/改名"这类**不是用户的错、也不该让用户处理**的情况，
        // 会变成一句 `无法创建目录：.heracles` 把任务打死 —— 而 `.heracles` 是**我们自己的**内部目录。
        //
        // ## 现在的分层
        //
        // ① **能自愈的自愈**：根还活着 ⇒ 缺什么目录建什么目录 ⇒ 写个探针文件确认真的能写
        // ② **不能自愈才说人话**：只有"这个文件夹真的没了/没权限了"才报错，
        //    且文案是**可执行动作**（重新选工作区），不是甩一个 `content://` URI 出去
        val storage: WorkspaceStorage = if (treeUri.isNotBlank()) {
            AndroidSafStorage(
                context = context,
                treeUri = android.net.Uri.parse(treeUri),
                displayName = File(workspacePath).name.ifBlank { "workspace" },
            )
        } else {
            val dir = File(workspacePath)
            if (!dir.isDirectory) error("工作区不存在或不是目录：$workspacePath")
            PosixStorage(dir.toPath())
        }

        // `:workspace` 自己的依赖目录（会话/计划/快照都在 `.heracles` 下）。
        // 列在这里 ⇒ **每次 run 前自动补齐**，用户永远不需要手动创建它们。
        run {
            val problem = when (storage) {
                is AndroidSafStorage -> storage.ensureWorkspace(
                    listOf(".heracles", ".heracles/sessions", ".heracles/plans"),
                )
                else -> null // POSIX：`writeText` 自带 mkdirs，不需要预建
            }
            if (problem != null) error(problem)
        }

        val fs = StorageBackedWorkspaceFs(storage)

        // ★ ask_user 回答通道（2026-10-16）—— 每次 run 一个（与 interruptQueue 同生命周期）。
        //   模型调 ask_user → 工具挂起在队列上；UI 弹窗提交回答 → reply() → 工具拿到。
        val askQueue = AgentLoop.AskReplyQueue()
        // 挂到实例上：MainActivity 的 replyAsk 通道要往里投回答
        activeAskQueue = askQueue

        // ★ 危险操作审批通道（2026-10-19）—— 与 askQueue 同生命周期。
        //   工具返回 NeedsApproval ⇒ AgentLoop 挂起在这里；UI 点允许/拒绝 → replyApproval。
        val approvalQueue = AgentLoop.ApprovalQueue()
        // ★ 跨 run 的「始终允许」白名单（2026-10-19）：从设置里读出来预填。
        //   为什么由装配处读写：`:agent` 是纯 JVM，**不知道**会话/设置存在哪 ——
        //   落盘归这里管，AgentLoop 只持有那份内存集合。
        //
        // ⚠️ 2026-10-19 真机排障：这一步**埋了句**，不是噪音。当时的真机现象是
        //   「点了『本会话始终允许』、write_file 执行成功、run 正常结束，
        //   但 `shared_prefs/heracles_approvals.xml` 里的集合仍然是**空的**」——
        //   而 `finally` 里 `saveAlwaysAllowed` 是 `runCatching`，**写失败/写空集都不出声**。
        //   没有这行就只能靠 `run-as cat` 反推，二选一猜不清：
        //   「ALLOW_ALWAYS 根本没到 approve()」 vs 「到了但集合没写进去」。
        //   这行记**读到了几条**，与下面 finally 的「写了 N 条」成对看，一次就能定位。
        runCatching { alwaysAllowedTools() }.getOrDefault(emptySet()).let { seeded ->
            approvalQueue.seed(seeded)
            println("[heracles][approval] seed ${seeded.size} 条持久白名单：${seeded.sorted()}")
        }
        activeApprovalQueue = approvalQueue

        // ================== 编码层 wiring（阶段二，ADR-020/021/023）==================
        //
        // 常驻 / 长尾两分：常驻进冻结区（吃缓存），长尾靠 search_tools 按需披露。
        // 见 `26-编码层工具链与逆向引擎.md` §5。
        val workspaceRoot: java.nio.file.Path = File(workspacePath).toPath()

        // 设备侧 shell —— App 自己**没有** shell 身份，必须经 Stellar/Shizuku
        // （`ProcessBuilder` 在 Android 上只能以 App 自己的 UID 跑）
        val shellRunner = DeviceShellRunner { rel ->
            File(workspacePath, rel).absolutePath
        }
        val health = SystemHealthSource(context)

        // 外部工具（aapt2 / d8.jar / android.jar / apksigner / zipalign）的定位；
        // 找不到不报错 —— 真正用到的工具会**在起进程之前**给出"缺哪个"的失败
        val toolchain = ToolchainLocator.locate(
            workspaceRoot = workspaceRoot,
            env = System.getenv(),
        )

        // 编码层长尾：6 个 Android 工具 + 解压/打包 + 补丁。
        // schema **不进冻结区**；参数表随 search_tools 的结果进历史尾部（可变区）。
        //
        // ★ 进度 = 前台服务（LMK 保护）——见 `26` §7.1。
        //   `build_apk` 一次要跑几秒到几分钟，用户必然会切走；**没有前台服务
        //   就是"半路被杀"**。挂载点选在工具层（不是引擎里）：一次工具调用
        //   = 一次任务，边界天然明确，且失败/抛异常四条路都统一收口。
        //
        // ★ F6b / ADR-032：SAF 工作区没有真实路径 ⇒ 构建要在 **App 内部 staging** 里跑。
        //
        //   ⚠️ 位置必须**shell 也够得着**：构建管线是用 shell 身份（Shizuku/Stellar，UID 2000）
        //   跑 aapt2/javac/d8 的，而 shell **进不去 App 私有目录**（`/data/data/<pkg>/…`）。
        //   ⇒ 用 `getExternalFilesDir`（`/sdcard/Android/data/<pkg>/files`，App 与 shell
        //   两侧都能写；`实测-12` §14.7 / ADR-030 的证据），**不用 cacheDir**。
        //   拿不到外部目录时**不传**（引擎会给明确的装配错误），不拿"能写但 shell 进不去"的
        //   cacheDir 假装能用。
        //
        //   还要给 staging 专用的 runner：`ShellRunner.cwd` 是**工作区相对**路径，App 侧
        //   `DeviceShellRunner` 会把它映射到**用户工作区根** —— 不换 runner，脚本会跑到别处。
        val buildStagingRoot = context.getExternalFilesDir(null)
            ?.let { File(it, "build-staging").toPath() }
        val buildStagingRunnerFactory: ((java.nio.file.Path) -> dev.heracles.core.exec.ShellRunner)? =
            { root ->
                val delegate = DeviceShellRunner { rel ->
                    File(root.toFile(), rel).absolutePath
                }
                object : dev.heracles.core.exec.ShellRunner {
                    override suspend fun run(command: String, timeoutSec: Int, cwd: String?) =
                        // cwd=null 是"根"：staging 构建里必须落成 staging 根，
                        // 否则脚本会跑在 shell 的默认目录（不是我们镜像到的那个目录）。
                        delegate.run(command, timeoutSec, cwd ?: ".")
                }
            }
        val androidLongTail: List<AgentTool> = AndroidTools.create(
            fs = fs,
            toolchain = toolchain,
            runner = shellRunner,
            health = health,
            progress = BuildTaskProgress(context),
            stagingRoot = buildStagingRoot,
            stagingRunnerFactory = buildStagingRunnerFactory,
        ) +
            listOf(UnzipFileTool(fs), ZipFileTool(fs)) + PatchTools.create(fs)
        // 名字重复 / 漏登记分组 ⇒ 启动期就响亮失败（不是运行期静默失灵）
        AndroidTools.assertConsistent(androidLongTail)

        // ★ 文件操作三件套（P1-3，2026-10-18）：`delete_path` / `move_path` / `copy_path`。
        //   ⚠️ S1b 起它们**与其它长尾工具一样对所有人可见**（原"只在云端长尾
        //   `ToolZonePlan.CLOUD_ONLY_LONG_TAIL`"的取舍随本地后端退场：
        //   当年是因为本地长尾 11/12 没余量、且不想给 4B 额外递刀）。
        val pathTools: List<AgentTool> = PathTools.create(fs)
        PathTools.assertConsistent(pathTools)

        // ================== 工具分区（常驻 / 长尾）==================
        //
        // ★ ADR-035 S1b（2026-10-18）：**不再按后端分级**。本地后端删除后
        //   `ToolZonePlan` 只剩**一份**常驻名单（10 个：原"本地 7 个"+ 原"云端专有 3 个"），
        //   上限 `Contract.Tools.FROZEN_LIMIT = 12`（`search_tools` 自己也要进冻结区 ⇒ 实际 11/12）。
        //   决策本身在 `:agent` 的 `ToolZonePlan`（纯函数、有单测）—— App 侧只负责造实例。
        //
        //   候选里常驻与长尾混在一起，由 `partition` 按名字分；顺序保持装配顺序
        //   （冻结区最终由 `PrefixBuilder` 按名字典序重排，所以这里只管名单）。
        val candidateTools: List<AgentTool> = buildList {
            add(ListFilesTool(fs))
            add(ReadFileTool(fs))
            add(WriteFileTool(fs))
            // ★ 任务计划工具（2026-10-19）—— 计划从"首轮正文一次性 JSON"变成可反复改写的状态。
            //   常驻（模型每轮都要能改计划）；实际状态由 AgentLoop 拦截维护。
            add(UpdatePlanTool())
            // ★ 建目录（2026-10-15 用户反馈）——
            //   write_file 能建父目录但建不了空目录（tests/ 等）
            add(MkdirTool(fs))
            // ★ 长期记忆（2026-10-16 用户反馈）——
            //   跨会话记住项目偏好与坑（启动时自动注入）
            add(SaveMemoryTool(fs))
            // **有弹窗回调才注册 ask_user** ——
            // CLI/测试没有 UI 弹窗，注册了也只是让模型调一个必然超时的工具。
            if (onAskUser != null) add(AskUserTool(askQueue))
            // ★ 常驻的 shell（2026-10-16 阶段二）——
            //   aapt2 / javac / d8 / apksigner **全部**经它执行，
            //   所以它必须是常驻而不是长尾（长尾要多一轮搜索才够用）
            // ★ 日志摘录行数（F5a / P1-5）：S1b 起**只有一个数**
            //   （`Contract.Shell.LOG_EXCERPT_LINES` = 200）⇒ 这里**不再传**，
            //   默认值就是它（原先按后端传的时候有两档 40/200）。
            add(RunShellCommandTool(shellRunner, fs, health))
            // ★ 搜索工具（2026-10-18，P1-1）—— 纯 `WorkspaceFs`、**不依赖 shell**，
            //   SAF 工作区也能用。S1b 起**常驻**（原"云端常驻、本地长尾"的取舍随本地退场）。
            add(FindFilesTool(fs))
            add(GrepFilesTool(fs))
            addAll(androidLongTail)
            addAll(pathTools)
            // ★ 联网抓取（2026-10-19，对齐成熟智能体的 WebFetch）——
            //   不占常驻格（常驻已 12/12），走长尾：`search_tools("网络/网页")` 可发现。
            addAll(WebTools.create())
            // ★ 读图（2026-10-19，多模态）—— 模型主动"看"工作区里的截图/设计稿。
            //   走长尾（常驻格已满）；读取成功后图片随后续请求发出（见 ViewImageTool KDoc）。
            addAll(ImageTools.create(fs))
        }
        // 越档**当场抛**（不静默截断 —— 截断会让模型"以为工具没了"，只能靠命中率下滑发现）
        val zone = ToolZonePlan.partition(candidateTools)
        val tools: List<AgentTool> = zone.resident
        val longTail: List<AgentTool> = zone.longTail

        // 披露集与 AgentLoop **共享同一个实例** —— 否则披露了却调不动
        val disclosed = mutableSetOf<String>()
        val registry = ToolRegistry(
            resident = tools.map { it.spec },
            longTail = longTail.map { it.spec },
            // 分组表要覆盖**全部**长尾工具（漏一个 ⇒ 那个工具的同义说法检索不到、静默退化）
            // ★ 分组表**只能**用 `AndroidTools.allGroups`（2026-10-19 真机事故）：
            //   过去这里自己拼一份、而 `assertConsistent` 只认 AndroidTools.GROUPS，
            //   于是别的模块登记的工具被判"没登记" ⇒ 启动期抛异常 ⇒ App 打不开会话。
            //   现在两边读同一份并集，"登记了却漏拼"这种错不可能再发生。
            groups = AndroidTools.allGroups,
            // ★ S1b：三个上限**不再按后端传**（`Contract.Zone` 已删）——
            //   默认值就是唯一一套 12 / 24 / 6。装配处刻意不传，
            //   避免"App 侧自己造判断"（`docs/27` §3 根因 C 那类分裂）。
        )

        // search_tools 自身**不放进 registry**：它是披露机制的入口，
        // 让它能检索到自己会形成"永远能搜到"的循环。
        val toolsWithMeta = tools + SearchToolsTool(registry, disclosed)

        // ★ 计划落盘（2026-10-19）：按会话存 `.heracles/plans/<sid>.json`。
        //   · 读回失败（首次 / 损坏）⇒ null，行为与改动前一致
        //   · 写入失败**不能**影响运行（计划是记忆增强，不是硬依赖）
        val planPath = sessionId?.takeIf { it.isNotBlank() }
            ?.let { ".heracles/plans/$it.json" }
        val initialPlan = planPath?.let { p ->
            runCatching { fs.readText(p) }.getOrNull()?.let { TaskPlan.fromJson(it) }
        }
        val persistPlan: (suspend (TaskPlan) -> Unit)? = planPath?.let { p ->
            { plan: TaskPlan ->
                runCatching {
                    fs.mkdirs(".heracles/plans")
                    fs.writeText(p, plan.toJson())
                }
            }
        }

        val loop = AgentLoop(
            provider = provider,
            workspace = fs,
            tools = toolsWithMeta,            // ★★ 原生 function calling 接线（2026-10-19）★★
            //
            // 此前**刻意没接**：响应侧（`tool_calls` → 执行 → 配对回填）当时还没落地，
            // 发 tools 只会把"看得见的解析失败"换成"模型调了工具却什么都不发生"。
            // ADR-031 step 2 已把响应侧补齐（单测 `NativeToolFlowTest` 钉住），
            // 于是这里按 provider 的能力位打开：
            //   · 云端三家（OpenAI 兼容 / Anthropic / Responses）`supportsNativeTools` 都是 true
            //   · 关掉时（CLI/测试默认）走文本协议，请求体逐字节不变
            // ⚠️ **真 Key 验证仍未做**（AGENTS 的 wire 纪律）—— 打开后必须用真 Key 跑一轮，
            //    确认中转站真的接受 `tools` 并返回 `tool_calls`（否则要退回文本轨）。
            nativeToolsEnabled = provider.capabilities.supportsNativeTools,
            // ★ 长尾 + 披露集（ADR-023）：只有被披露过的长尾工具才会进
            //   grammar 枚举与调用派发；**冻结区始终只装常驻工具**（门禁 G13）。
            longTail = longTail,
            disclosed = disclosed,
            // ★ 轮次（ADR-033 / P0-1，2026-10-18；S2 起默认值就是契约值）——
            //   用户设置里可调：`>0` 覆盖，`0` = 用 `Contract.Budget.MAX_TURNS`（40）。
            //   ⚠️ 这个三元式**不能省成 `maxTurns = maxTurns`**：`0` 传下去会让
            //   `for (turnIndex in 1..0)` 一轮都不跑（静默"什么都没做"）。
            maxTurns = if (maxTurns > 0) maxTurns else Contract.Budget.MAX_TURNS,
            // ★ 工具次数 / 连续失败：**不再重复传**（S2）——
            //   `AgentLoop` 的默认值就是 `Contract.Budget.MAX_TOOL_CALLS`（120）/
            //   `MAX_CONSECUTIVE_FAILURES`（6）。装配处再传一遍等于把"同一个数"写两处，
            //   将来改契约时漏一处就会出现"App 与 CLI 预算不同"（`docs/27` §3 根因 C 那类分裂）。
            //   历史：S1b 之前这里按后端给两档（本地 30/3、云端 120/6），
            //   更早的 P0-1 之前 `MAX_TOOL_CALLS_PER_TASK` 是**死常量**。
            //   三个数的**唯一来源** = `Contract.Budget`（见其 KDoc 的表）。
            // ★ 推理等级（2026-10-12）—— 默认 AUTO，行为与改造前一致
            reasoningLevel = reasoningLevel,
            // ★ 流式：把 AgentLoop 的事件一路上抛给 MainActivity 的 EventChannel。
            //   onEvent 为 null 时 AgentLoop 内部直接 return，零开销。
            onEvent = onEvent,
            // ★ 过程态落盘：一步一次上抛给 MainActivity 写 `.jsonl`
            //   （修「切会话后步骤消失」—— 见 `SessionStore.appendStep`）。
            onStepEnded = onStepEnded,
            // ★ 思考间隙引导（2026-10-13）：MainActivity 在 MethodChannel
            //   `interruptRun` 里往这个队列 offer；AgentLoop 在每轮开始前
            //   drain。本次 run 结束后队列作废（每次 run 新建一个）。
            interruptQueue = interruptQueue,
            // ★ ask_user 回答通道（2026-10-16）：模型提问 → 挂起 →
            //   UI 弹窗回答 → reply()。本次 run 结束后队列作废。
            askReplies = askQueue,
            // ★ 危险操作审批（2026-10-19）：NeedsApproval 时挂起问用户
            approvalReplies = approvalQueue,
            // ★ 跨 run 持久白名单的**读点**（2026-10-19 修断线）：只 seed 不读的话
            //   「始终允许」永远是摆设 —— 详见 AgentLoop.persistentAllowlist 的 KDoc。
            persistentAllowlist = approvalQueue.alwaysAllowed,
            // ★ 审批档位（2026-10-19）：手动档在**执行前**问；完全访问档自动放行 NeedsApproval
            approvalMode = approvalMode,
            // ★ 计划跨 run 记忆（2026-10-19）：从会话文件恢复 + 变更即落盘
            initialPlan = initialPlan,
            onPlanChanged = persistPlan,
            // ★ 上下文上限（2026-10-16 压缩机制）—— 按后端类型给
            //   （本地 4096 / 云端 128K，与用量面板同源）
            contextLimit = contextLimitTokens(backend != "local"),
            // ★ 冻结区常驻上限（ADR-035 S1b）—— S1b 起**不再传**：
            //   默认 = `Contract.Tools.FROZEN_LIMIT`（12），计数含 `search_tools` 元工具
            //   （它也要进冻结区）⇒ 今天 10 个业务常驻 + 1 个元工具 = 11 ≤ 12。
            //   ⚠️ 越档会在 `PrefixBuilder.buildFrozen` 的 `require` 上**当场抛**
            //   （不是静默截断）—— 原先"本地档 8 顶满"那个坑就是这个机制抓的。
            // ★ 工具协议（F3c）：S1b 起**不再传 backend** —— 协议只剩两态
            //   （`nativeToolsEnabled` 决定原生 / 云端文本），本地那份文案已随本地后端删除。
        )

        // ★ 让装配处在**取消/异常**后仍能拿到本次 run 的逐轮记账（2026-10-20）
        //
        // `CancellationException` 会把 `AgentRunResult` 一起带走 ⇒ `MainActivity`
        // 的 catch 块拿不到 records ⇒ 写不出 usage 兜底行
        // ⇒ 被「停止」或失败中断的 run，**整段用量凭空消失**。
        // 真机证据：2026-10-20 两次"跑到一半被停"的会话，jsonl 只有 user + step。
        activeLoop = loop

        try {
            // ★ 传历史（2026-10-14）—— 让模型"记得"之前的对话。
            //   不传 = 每次都是新会话（用户实测的"没有记忆了"）
            // ★ 记忆注入（2026-10-16）：读 .heracles/memory.md 拼进首条消息 ——
            //   模型每次 run 都"记得"项目偏好与坑。读取失败静默跳过。
            val memoryNote = runCatching {
                if (fs.exists(".heracles/memory.md")) {
                    val m = fs.readText(".heracles/memory.md")
                    if (m.isNotBlank()) {
                        "\n\n【长期记忆（跨会话保留的项目知识与用户偏好）】\n$m"
                    } else ""
                } else ""
            }.getOrDefault("")

            // ★ 记忆注入（2026-10-16）：buildPrompt 读 .heracles/memory.md
            //   拼进首条消息 —— 模型每次 run 都"记得"项目偏好与坑
            // ★ 多模态（2026-10-19）：图片附件转 data URL，随请求发给支持读图的后端
            loop.run(
                buildPrompt(request, attachments, memoryNote),
                history,
                images = imageDataUrls(attachments),
            )
        } finally {
            // ★ 记下冻结区规模，供"用量与上下文"面板展示（2026-10-11，t13）
            //
            // 放在 finally：**失败也要记** —— 面板要能解释"这次为什么贵/满了"，
            // 而失败那次的冻结区同样是真实发送过的。
            lastFrozenTokens = loop.frozenPrefix.estimatedTokens
            // ★ 把本 run 里用户点过的「始终允许」写回设置（2026-10-19）。
            //   写失败**不能**影响 run 结果 —— 白名单是增强，不是硬依赖。
            //   ⚠️ 但要**出声**：`runCatching` 静默吞掉读写异常时，真机上表现为
            //   「设置页永远显示『无』」，而没有任何线索能区分"没读到 / 没写进 / 写了空集"。
            //   与 run 开头的 `[heracles][approval] seed …` 成对看。
            val saved = runCatching {
                saveAlwaysAllowed(approvalQueue.alwaysAllowed)
                approvalQueue.alwaysAllowed.toSortedSet()
            }
            println(
                "[heracles][approval] save ${saved.getOrNull()?.size ?: -1} 条：" +
                    "${saved.getOrNull() ?: saved.exceptionOrNull()?.let { "${it.javaClass.simpleName}: ${it.message}" }}",
            )
            // ★ ask / 审批队列随 run 结束作废（此时回答已无意义）
            activeAskQueue = null
            activeApprovalQueue = null
            // ⚠️ `activeLoop` **故意不在这里清空**（2026-10-20）：
            //   本 finally 在 `bridge.run` 抛出**之前**执行，而调用方的 catch 要在此之后
            //   才读 `lastRecords` 记账。清空它恰好会让兜底失效（那就白改了）。
            //   它由**下一次 run** 覆盖，生命周期比本次 run 略长一格 —— 只写不读的地方，
            //   留一格是安全的。
            provider.release()
        }
    }

    /**
     * 上一次 `run()` 的**冻结区** token 估算（系统提示词 + 工具定义 + 工具协议）。
     *
     * ## 为什么用"上一次"而不是现算
     *
     * 冻结区只取决于 `systemPrompt` + 工具集合 + skill 索引，而这些都在
     * `run()` 里组装。要在别处复算，就得把工具构造逻辑再抄一遍
     * （工具需要 `WorkspaceFs`，构造起来并不轻）——
     * 抄一份就是**第二处真相**，迟早会漂移。
     *
     * 记下来则天然一致：面板显示的正是**这次真正发出去的那个前缀**。
     *
     * `-1` = 还没跑过任何一次（面板据此显示"未开始"而不是 `~0`）。
     */
    @Volatile
    var lastFrozenTokens: Int = -1
        private set

    /**
     * **当前 run 的 ask_user 回答队列**（2026-10-16）。
     *
     * run 期间非 null；`MainActivity` 的 `replyAsk` 通道往里投用户回答。
     * run 结束置 null（队列生命周期与 run 相同）。
     */
    @Volatile
    var activeAskQueue: AgentLoop.AskReplyQueue? = null

    /** 用户回答了 ask_user 的提问（UI 弹窗提交时调用）。 */
    fun replyAsk(text: String) {
        activeAskQueue?.reply(text)
    }

    /**
     * **当前 run 的危险操作审批队列**（2026-10-19）。
     *
     * run 期间非 null；`MainActivity` 的 `replyApproval` 通道往里投用户决定。
     * run 结束置 null（队列生命周期与 run 相同）。
     */
    @Volatile
    var activeApprovalQueue: AgentLoop.ApprovalQueue? = null

    /**
     * **当前 run 的 `AgentLoop`**（2026-10-20）—— 只为一件事：取消/异常后
     * 从 [AgentLoop.lastRecords] 取回本次已发生的逐轮记账，写 usage 兜底行。
     *
     * 为什么需要：`CancellationException` 原样抛出是对的（调用方靠它区分"用户停的"
     * 与"provider 出错"），但代价是 `AgentRunResult` 丢了 —— 而本次 run
     * **已经发出去的请求是真的花了钱的**。
     *
     * ⚠️ 生命周期比 run **略长一格**：`run()` 的 finally 里**不清空**它，
     * 因为调用方的 catch 要在此之后才读。由下一次 run 覆盖（只写不读的地方留一格是安全的）。
     */
    @Volatile
    var activeLoop: AgentLoop? = null

    /**
     * **被取消 / 失败中断的 run 的 usage 兜底记账**（2026-10-20）。
     *
     * ## 修的是什么
     *
     * `MainActivity.persistTurns` 只在 `finalText` 非空时写 `role=assistant`（带 usage），
     * 而取消/异常**根本不经过它**。⇒ 一次被「停止」的 run，**整段用量凭空消失**。
     *
     * 真机证据（2026-10-20，e35e48c6）：两次跑到一半被停的会话，`.jsonl` 里
     * 只有 `user` + `step`，没有 `assistant`、也没有 `usage` ⇒ L1 采样对这类 run 完全失明。
     *
     * ## 为什么落 `role=usage` 而不是 `role=assistant`
     *
     * UI 把 `assistant` 当**对话气泡**渲染；被停的 run `finalText` 是空的，
     * 落成 assistant 会多一个**空气泡**。`usage` 是纯记账行：UI 不认识就跳过
     * （`chat_screen` 有 `case 'usage': break;`），采样脚本按 `role in {assistant, usage}` 取数。
     *
     * ## 为什么吞异常但**必须出声**
     *
     * 记账失败不能影响 run 结果（白名单/记账都是增强，不是硬依赖）；
     * 但静默失败正是"数据凭空消失"最难查的成因 —— 所以打一行日志。
     */
    suspend fun persistCancelledUsage(
        store: SessionStore,
        storage: dev.heracles.workspace.WorkspaceStorage,
        sessionId: String,
        stopReason: String,
    ) {
        if (sessionId.isBlank()) return
        val turns = activeLoop?.lastRecords.orEmpty()
        if (turns.isEmpty()) return
        var cached = 0
        var prompt = 0
        var out = 0
        for (t in turns) {
            val c = t.cache
            cached += c.cachedTokens ?: 0
            prompt += c.promptTokens
            out += c.outputTokens
        }
        // 全是 0 ⇒ 这次 run 还没真正发出过请求，无可记
        if (cached + prompt + out <= 0) return
        // ★★ 必须跳出**已被取消**的协程上下文（2026-10-20 真机踩到）★★
        //
        // 第一次实现直接在这里 `store.appendMessage(...)`，真机 logcat 报：
        //   `[heracles][usage] 兜底行写入失败：JobCancellationException: StandaloneCoroutine was cancelled`
        //
        // 根因：本函数是在 `catch (CancellationException)` 里被调的，此时
        // **调用方的 Job 已经处于 cancelled 状态** ⇒ 任何挂起点（`appendMessage` 是 suspend，
        // 内部还会 `withContext(IO)`）都会立刻抛 `JobCancellationException`。
        // 换句话说：**"取消之后还想再做一件事"必须换一个不会被取消的 scope**。
        //
        // `NonCancellable` 正是为这种"清理/记账必须完成"的场景准备的 —— 它让这段
        // 代码不再响应父 Job 的取消。⚠️ 代价：这里若卡住，会拖住 catch 的返回；
        // 记账是一次小 append（毫秒级），可接受。
        withContext(NonCancellable + Dispatchers.IO) {
            runCatching {
                store.appendMessage(
                    storage, sessionId,
                    mapOf(
                        "role" to "usage",
                        "text" to "",
                        "cached" to cached,
                        "prompt" to prompt,
                        "out" to out,
                        "turns" to turns.size,
                        "stopReason" to stopReason,
                        "ts" to System.currentTimeMillis(),
                    ),
                )
            }.onFailure {
                println("[heracles][usage] 兜底行写入失败：${it.javaClass.simpleName}: ${it.message}")
            }
        }
    }

    /** 用户对需要确认的工具调用了「允许 / 始终允许 / 拒绝」（UI 弹窗提交时调用）。 */
    fun replyApproval(decision: String) {
        val d = when (decision.lowercase()) {
            "allow_always", "always" -> AgentLoop.ApprovalDecision.ALLOW_ALWAYS
            "allow", "allow_once" -> AgentLoop.ApprovalDecision.ALLOW_ONCE
            else -> AgentLoop.ApprovalDecision.DENY
        }
        activeApprovalQueue?.reply(d)
    }

    // ---------------------------------------------------------------- 始终允许（持久白名单）

    /**
     * **「始终允许」的工具白名单**（2026-10-19）—— 跨 run 有效。
     *
     * ## 存在哪
     *
     * `SharedPreferences("heracles_approvals")` 的一个 `StringSet`。
     * 与用户设置（`AppSettings`）**分开存**：那是 Flutter 侧的模型/外观配置，
     * 而这份是**安全决定**，不该被"恢复默认设置"顺手清掉，也不该随设置导出。
     *
     * ## 安全语义（不许淡化）
     *
     * · 粒度是**工具名**（"允许 write_file"），不是某个具体命令 —— 与 Claude Code 的
     *   "always allow this tool" 一致；粒度再细会变成"每个文件都要点一次"
     * · 用户可以随时在设置页**整体清除**
     * · 它只跳过"要不要问"这一步；工具自身的守卫（`CommandGuard` / 路径校验）照常生效
     */
    private val approvalsPrefs by lazy {
        context.getSharedPreferences("heracles_approvals", Context.MODE_PRIVATE)
    }

    /** 读当前白名单（返回**副本** —— `getStringSet` 的集合不可直接改）。 */
    fun alwaysAllowedTools(): Set<String> =
        approvalsPrefs.getStringSet(KEY_ALWAYS_ALLOWED, emptySet())
            ?.toSet() ?: emptySet()

    /** 覆盖写入白名单。 */
    private fun saveAlwaysAllowed(tools: Collection<String>) {
        // ★ 存**副本**：SharedPreferences 不会立即用你给的集合对象，
        //   但传一个之后还会被 main 线程改的集合是自找麻烦。
        approvalsPrefs.edit()
            .putStringSet(KEY_ALWAYS_ALLOWED, tools.toSet())
            .apply()
    }

    /** 清空白名单（设置页「清除」按钮）。 */
    fun clearAlwaysAllowed() {
        approvalsPrefs.edit().remove(KEY_ALWAYS_ALLOWED).apply()
    }

    /** 把**当前 run 内**的临时白名单也写回（run 中途被问到时用）。 */
    fun persistAlwaysAllowedNow() {
        activeApprovalQueue?.let { saveAlwaysAllowed(it.alwaysAllowed) }
    }

    /**
     * 上下文上限（token）—— **按后端类型区分**（2026-10-14 用户反馈修复）。
     *
     * ## 修的是什么
     *
     * 用户实测：调用基元律动的 `deepseek-v4-flash-0731`（**1M 上下文**），
     * 但 UI 显示「上下文已用 56% · ~2.3K / 4.1K」—— 上限被算成 4096。
     *
     * ## 根因
     *
     * `Contract.Context.DEFAULT_CTX = 4096` 是**本地 llama.cpp 的值**
     *（注释写明"实测：4096 下内存已紧张"），但它被当作**全局默认**
     * 用到了云端 —— 云端模型动辄 128K–1M，按 4K 算会：
     *   · 显示"已用 56%"（实际不到 0.3%）→ **误导用户**
     *   · 触发 `COMPACTION_TRIGGER_RATIO`（0.8）→ **过早压缩会话**，
     *     白白丢掉上下文、损害缓存命中（铁律 1）
     *
     * ## 修法：按后端给不同默认
     *
     * | 后端 | 默认上限 | 依据 |
     * |---|---|---|
     * | 本地 llama.cpp | 4096 | 手机内存实测（原值，不动）|
     * | 云端 / 自建 | 128K | 常见云端模型的下限 |
     *
     * @param isCloud 当前是否走云端类后端（含 Anthropic / Responses）
     */
    fun contextLimitTokens(isCloud: Boolean): Int =
        if (isCloud) Contract.Context.DEFAULT_CLOUD_CTX
        else ProviderConfig().contextSize


    /**
     * 把附件内容拼进请求。
     *
     * ## 为什么在这里读而不是让 agent 用工具读
     *
     * 附件是**用户主动提供的上下文**，不是 agent 要去探索的东西。
     * 让它再调一次 `read_file` 既浪费一轮，又可能因为路径不在工作区内
     * 而被 `PathGuard` 拦下（附件在应用缓存里，不属工作区）。
     *
     * ## 尺寸控制
     *
     * 单个文本附件超过 [MAX_ATTACHMENT_CHARS] 就截断 ——
     * 上下文是有限的（`02-契约规范.md` §3.3），
     * 一个 1MB 的日志会直接挤爆预算。
     */
    private fun buildPrompt(
        request: String,
        attachments: List<Map<String, String>>,
        memoryNote: String = "",
    ): String {
        // ★ 记忆注入（2026-10-16 用户需求「Agent 记忆功能」）——
        //
        // ## 为什么注入而不是靠模型自己想起来去读
        //
        // 记忆的价值在于**自动生效** —— 每次会话开始模型就知道
        // "这个项目的偏好与坑"，不需要它先猜着调 read_file。
        // 这与 CLAUDE.md 的做法一致：启动时注入，用户可编辑。
        //
        // ## 为什么 memoryNote 由调用方传入
        //
        // 读取（fs.exists/readText）是 **suspend** 调用，而本函数是
        // 同步的 —— 在 run() 的 IO 协程里读好后作为参数传入，
        // 保持本函数纯净（可测试、无隐式挂起）。
        //
        // ## 失败静默
        //
        // 记忆不存在（首次使用）或读取失败 → 空串，不影响任务。
        // 记忆是增强，不是依赖。
        if (attachments.isEmpty()) return request + memoryNote

        val sb = StringBuilder()
        attachments.forEach { a ->
            val path = a["path"].orEmpty()
            val name = a["name"].orEmpty()
            val kind = a["kind"].orEmpty()
            if (path.isBlank()) return@forEach
            val f = File(path)
            if (!f.isFile) return@forEach

            sb.append("\n\n【附件】")
            sb.append(name)
            when (kind) {
                "text" -> {
                    val text = runCatching { f.readText() }.getOrNull()
                    if (text != null) {
                        val body = if (text.length > MAX_ATTACHMENT_CHARS) {
                            text.take(MAX_ATTACHMENT_CHARS) +
                                "\n…（已截断，原文 " + text.length + " 字符）"
                        } else {
                            text
                        }
                        sb.append("\n```\n")
                        sb.append(body)
                        sb.append("\n```")
                    } else {
                        sb.append("（读取失败）")
                    }
                }
                "image" -> {
                    // ★ 多模态已接通（2026-10-19）：图片会作为**多模态输入**随请求发送
                    //   （见 [imageDataUrls]），这里只需要在正文里标注"有图"，
                    //   不再写"当前模型不支持读图"那种假话。
                    sb.append("（图片，")
                    sb.append(f.length())
                    sb.append(" 字节，已作为多模态输入随本次请求发送）")
                }
                else -> {
                    sb.append("（二进制文件，")
                    sb.append(f.length())
                    sb.append(" 字节）")
                }
            }
        }

        return if (request.isBlank()) (sb.toString().trim() + memoryNote)
        else request + sb + memoryNote
    }

    /**
     * 图片附件 → **data URL** 列表（2026-10-19，多模态）。
     *
     * ## 为什么在这里转而不是在 Dart
     *
     * 附件模型**刻意只存路径**（见 `app/lib/models/attachment.dart`）：照片动辄几 MB，
     * base64 塞进消息流会撑爆内存并拖慢每次重建。真正读取发生在**发送那一刻**，
     * 且 Kotlin 侧本来就要 `File(path)` 校验存在性。
     *
     * ## 上限（两条都是硬的）
     *
     * · 单张 ≤ [MAX_ATTACHMENT_IMAGE_BYTES]：base64 膨胀 ~33%，4 MB 原图 ≈ 5.3 MB 文本
     * · 最多 [MAX_ATTACHMENT_IMAGES] 张：每张都会在**每一轮**重新计 token
     *
     * 超限的图片**不发**（正文里仍会写明"图片 N 字节"），但不静默失败 ——
     * 模型会看到"有一张图但没送出去"这种信息缺口，由它决定是否向用户确认。
     */
    private fun imageDataUrls(attachments: List<Map<String, String>>): List<String> {
        val out = mutableListOf<String>()
        for (a in attachments) {
            if (out.size >= MAX_ATTACHMENT_IMAGES) break
            if (a["kind"] != "image") continue
            val path = a["path"].orEmpty()
            if (path.isBlank()) continue
            val f = File(path)
            if (!f.isFile) continue
            if (f.length() > MAX_ATTACHMENT_IMAGE_BYTES) continue
            val bytes = runCatching { f.readBytes() }.getOrNull() ?: continue
            val mime = when (f.extension.lowercase()) {
                "png" -> "image/png"
                "jpg", "jpeg" -> "image/jpeg"
                "webp" -> "image/webp"
                "gif" -> "image/gif"
                else -> "image/png"
            }
            out += "data:$mime;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
        }
        return out
    }

    /**
     * 把 [AgentRunResult] 转成 Flutter 能吃的 Map。
     *
     * 字段名与 Dart 侧 `AgentEvent` 对齐 —— 两边改一处就要改另一处，
     * 所以字段名**集中在这里**，不要在别处硬编码字符串。
     */
    fun toMap(result: AgentRunResult): Map<String, Any?> = mapOf(
        "stopReason" to result.stopReason,
        "finalText" to result.finalText,
        "totalCachedTokens" to result.totalCachedTokens,
        "totalPromptTokens" to result.totalPromptTokens,
        "totalOutputTokens" to result.totalOutputTokens,
        "steadyHitRate" to result.steadyHitRate,
        "turns" to result.turns.map { it.toMap() },
    )

    /**
     * 单轮记录 → Dart。
     *
     * ## `toolState` 为什么必须显式传（2026-10-10 修复 H-1）
     *
     * 原先 Dart 侧靠 `verdict` 里的**中文子串**猜状态
     * （`verdict.contains('失败')`），而拦截类的 verdict
     * （"重复调用已拦截…"、"★ 检测到循环，强制停止"）**不含「失败」**，
     * 于是被当成成功 → 画出**绿色成功卡**，且落盘 `ok: true`。
     *
     * 现在把 Kotlin 侧算好的三态**原样**送过去，Dart 不再自己猜。
     * 取值：`succeeded` / `failed` / `blocked` / `none`（本轮没请求工具）。
     */
    private fun TurnRecord.toMap(): Map<String, Any?> = mapOf(
        "index" to index,
        "verdict" to verdict,
        "tool" to toolCall?.tool,
        "args" to toolCall?.args,
        "result" to toolResult,
        "wallMs" to wallMs,
        "cachedTokens" to cache.cachedTokens,
        "promptTokens" to cache.promptTokens,
        "outputTokens" to cache.outputTokens,
        // ★ 结构化三态 —— Dart 侧**唯一**允许用来决定卡片颜色的依据
        "toolState" to when (toolState) {
            dev.heracles.agent.ToolState.succeeded -> "succeeded"
            dev.heracles.agent.ToolState.failed -> "failed"
            dev.heracles.agent.ToolState.blocked -> "blocked"
            dev.heracles.agent.ToolState.notRequested -> "none"
        },
    )

    // ------------------------------------------------------ 实时事件 → Dart

    /**
     * 把 [AgentEvent] 序列化成 Flutter 能吃的 Map（2026-10-10 流式）。
     *
     * ## 为什么集中在这里
     *
     * 与 [toMap] 同理：字段名是 Kotlin↔Dart 的**契约**，
     * 两边改一处就要改另一处。集中在这里就不会有人另处硬编码字符串。
     *
     * ## 字段约定（与 Dart 侧 `AgentEvent.fromMap` 严格对齐）
     *
     * 每个 Map **必带** `type` 与 `ts`；`type` 取值：
     * `turn_started` / `model_output` / `tool_started` /
     * `tool_finished` / `blocked` / `finished` / `failed`。
     *
     * ## 两个必须小心的点
     *
     * 1. **`Blocked.call` 可能为 null**（`Unparseable` 分支连调用都没解析出来）
     *    → 这里显式写 `null`，Dart 侧必须判空。写成 `emptyMap()` 会让 UI
     *    显示一张空工具卡片，那是假信息。
     * 2. **`cachedTokens` 为 null 必须原样传下去**（`02-契约规范.md` §3.4）
     *    —— 用 0 代替会让 UI 显示"命中率 0%"，误报缓存坏了。
     */
    fun toEventMap(event: AgentEvent): Map<String, Any?> = when (event) {
        is AgentEvent.TurnStarted -> mapOf(
            "type" to "turn_started",
            "ts" to event.ts,
            "index" to event.index,
        )

        is AgentEvent.ModelOutput -> mapOf(
            "type" to "model_output",
            "ts" to event.ts,
            "index" to event.index,
            "raw" to event.raw,
            "wallMs" to event.wallMs,
            "cache" to cacheToMap(event.cache),
        )

        is AgentEvent.ToolStarted -> mapOf(
            "type" to "tool_started",
            "ts" to event.ts,
            "index" to event.index,
            "tool" to event.call.tool,
            "args" to event.call.args,
        )

        is AgentEvent.ToolFinished -> mapOf(
            "type" to "tool_finished",
            "ts" to event.ts,
            "index" to event.index,
            "tool" to event.call.tool,
            "args" to event.call.args,
            "result" to event.result,
            "ok" to event.ok,
            "wallMs" to event.wallMs,
        )

        is AgentEvent.Blocked -> mapOf(
            "type" to "blocked",
            "ts" to event.ts,
            "index" to event.index,
            // ★ 可能为 null —— Dart 必须判空，不要伪造空调用
            "tool" to event.call?.tool,
            "args" to event.call?.args,
            "reason" to event.reason,
        )

        is AgentEvent.Finished -> mapOf(
            "type" to "finished",
            "ts" to event.ts,
            "finalText" to event.finalText,
            "stopReason" to event.stopReason,
            "turnCount" to event.turnCount,
        )

        is AgentEvent.Failed -> mapOf(
            "type" to "failed",
            "ts" to event.ts,
            "message" to event.message,
        )

        // ★ 思考间隙引导（2026-10-13）：插话被注入会话 ——
        //   Dart 侧在工作步骤流里渲染一张插话卡片（确认"模型看到了"）
        is AgentEvent.Interrupted -> mapOf(
            "type" to "interrupted",
            "ts" to event.ts,
            "index" to event.index,
            "text" to event.text,
        )

        // ★ ask_user：模型向用户提问（2026-10-16）——
        //   工具已挂起等待，Dart 收到后弹窗收集回答。
        //   问题文本放进 "text"（Dart 侧 fromMap 统一用 message 承载人读文本）
        is AgentEvent.AskUser -> mapOf(
            "type" to "ask_user",
            "ts" to event.ts,
            "index" to event.index,
            "text" to event.question,
        )

        // ★ 危险工具需要用户确认（2026-10-19，三态门禁的 UI 闭环）——
        //   AgentLoop 已挂起；Dart 弹窗 → replyApproval → 允许则重新执行。
        is AgentEvent.ApprovalRequest -> mapOf(
            "type" to "approval_request",
            "ts" to event.ts,
            "index" to event.index,
            "tool" to event.call.tool,
            "args" to event.call.args,
            "reason" to event.reason,
        )

        // ★ 任务计划（2026-10-14，harness）—— 待办清单的产生与推进
        is AgentEvent.PlanCreated -> mapOf(
            "type" to "plan_created",
            "ts" to event.ts,
            "index" to event.index,
            "steps" to event.steps,
        )

        is AgentEvent.PlanAdvanced -> mapOf(
            "type" to "plan_advanced",
            "ts" to event.ts,
            "index" to event.index,
            "doneCount" to event.doneCount,
            "activeIndex" to event.activeIndex,
        )

        // ★ 计划收尾（2026-10-15，BUG-1）—— 任务结束时明确告诉 UI
        //   剩余步骤该显示成"已完成"（正常达成）还是"已中断"（循环/熔断）。
        //
        //   没有它，最后一步（通常是"汇报结果"，不需要工具）会
        //   永远停在"进行中"—— 用户实测截图：任务已结束但显示 4/5。
        is AgentEvent.PlanClosed -> mapOf(
            "type" to "plan_closed",
            "ts" to event.ts,
            "doneCount" to event.doneCount,
            "reachedGoal" to event.reachedGoal,
            "reason" to event.reason,
        )

        // ==================================================== token 级（2026-10-12）
        //
        // ⚠️⚠️ **这四类曾经完全没有分支** —— S1/S2 加好了事件类、
        // AgentLoop 也真的在发，但 `toEventMap` 的 `when` 是穷尽表达式，
        // **编译不过**（`app:compileDebugKotlin` 直接失败）。
        //
        // 换句话说：在补上这四段之前，「逐字流」在后端**一寸都没到过 Dart** ——
        // 用户看到的仍然是"等 AI 想完了再全部展示"。
        // 这是 S5 顺手堵掉的一个真实断点（不是重构，是缺件）。
        //
        // 字段名与 Dart 侧 `AgentEvent.fromMap` 严格对齐：
        // `stepId` / `title` / `delta` / `status` / `durationMs` / `summary`。

        is AgentEvent.StepStarted -> mapOf(
            "type" to "step_started",
            "ts" to event.ts,
            "stepId" to event.stepId,
            "title" to event.title,
            // 本轮最终要调用的工具 —— 此时还不知道，恒为 null（见 KDoc）
            "tool" to event.tool,
            "index" to event.index,
        )

        is AgentEvent.ReasoningDelta -> mapOf(
            "type" to "reasoning_delta",
            "ts" to event.ts,
            "stepId" to event.stepId,
            // ★ **增量**（几个字），不是累积全文 —— UI 自己累加。
            //   粘成全文会让"逐字"变成"每次重发一遍"，且无法与正文分轨。
            "delta" to event.delta,
        )

        is AgentEvent.StepDelta -> mapOf(
            "type" to "step_delta",
            "ts" to event.ts,
            "stepId" to event.stepId,
            "delta" to event.delta,
        )

        is AgentEvent.StepEnded -> mapOf(
            "type" to "step_ended",
            "ts" to event.ts,
            "stepId" to event.stepId,
            // 三态（ok / empty / error）—— **不是布尔**，见 AgentEvent 的 KDoc
            "status" to event.status,
            "durationMs" to event.durationMs,
            "summary" to event.summary,
            "index" to event.index,
        )
    }

    /**
     * 缓存指标 → Map。
     *
     * `cachedTokens` **允许为 null**（provider 未上报），
     * 与 Dart 侧 `TurnMetrics` 的"不可用"语义一致。
     */
    private fun cacheToMap(cache: dev.heracles.core.provider.CacheStats): Map<String, Any?> = mapOf(
        "cachedTokens" to cache.cachedTokens,
        "promptTokens" to cache.promptTokens,
        "outputTokens" to cache.outputTokens,
        // null = 不可用（不是 0%）—— UI 要显示 "—"
        "hitRate" to cache.hitRate,
    )

    companion object {
        /**
         * 单个文本附件注入上下文的最大字符数。
         *
         * 8000 字符 ≈ 3000 token —— 已经占掉上下文预算的相当一部分。
         * 不设上限的话，一个 1MB 的日志会直接把预算挤爆
         * （`02-契约规范.md` §3.3 上下文预算）。
         */
        const val MAX_ATTACHMENT_CHARS = 8000

        /** 单张图片附件的最大字节数（多模态，2026-10-19）—— 4 MB */
        const val MAX_ATTACHMENT_IMAGE_BYTES = 4 * 1024 * 1024

        /** 一次请求最多带几张图（多模态，2026-10-19）—— 每张每轮都计 token */
        const val MAX_ATTACHMENT_IMAGES = 2

        /** 「始终允许」白名单在 SharedPreferences 里的键（2026-10-19） */
        private const val KEY_ALWAYS_ALLOWED = "always_allowed_tools"
    }
}
