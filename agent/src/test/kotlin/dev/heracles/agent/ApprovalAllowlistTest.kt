package dev.heracles.agent

import dev.heracles.core.provider.CacheStats
import dev.heracles.core.provider.FinishReason
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.GenerateResult
import dev.heracles.core.provider.ModelProvider
import dev.heracles.core.provider.ProviderCapabilities
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ProviderHealth
import dev.heracles.core.provider.ProviderKind
import dev.heracles.core.provider.StreamChunk
import dev.heracles.core.tool.NativeToolCall
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.FileEntry
import dev.heracles.workspace.WorkspaceFs
import dev.heracles.workspace.WorkspaceInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Paths
import java.util.concurrent.atomic.AtomicInteger

/**
 * **「始终允许」白名单的跨 run 语义**（2026-10-19）。
 *
 * ## 背景
 *
 * 用户在审批弹窗点「本会话始终允许」后，工具名会被记住。原来的实现**只活在一个 run 里**
 * —— 下次开新会话又问一遍，用户会觉得"上次不是点过吗"。
 * 现在装配处（`AgentBridge`）会从 `SharedPreferences` 读出来 `seed(...)` 进 `ApprovalQueue`。
 *
 * ## 这组断言守什么
 *
 * `:agent` 只负责"**预填的白名单真的能跳过询问**"这一段（落盘在装配处，
 * 纯 JVM 单测覆盖不到 `SharedPreferences`）。所以这里用**两次 run 共用同一个队列**的方式，
 * 模拟"上次点过、这次已预填"的场景。
 */
class ApprovalAllowlistTest {

    private class NoopFs : WorkspaceFs {
        override val info = WorkspaceInfo(Paths.get("noop"), "noop")
        override suspend fun list(relativeDir: String): List<FileEntry> = emptyList()
        override suspend fun readText(relativePath: String): String = ""
        override suspend fun writeText(relativePath: String, content: String): Long = 0
        override suspend fun exists(relativePath: String): Boolean = false
        override suspend fun mkdirs(relativeDir: String) = Unit
    }

    private data class ScriptTurn(
        val text: String,
        val finish: FinishReason = FinishReason.STOP,
        val calls: List<NativeToolCall> = emptyList(),
    )

    private class ScriptedProvider(private val script: List<ScriptTurn>) : ModelProvider {
        override val id = "scripted:allowlist"
        override val kind = ProviderKind.CLOUD
        override val capabilities = ProviderCapabilities(
            supportsGrammar = true,
            supportsJsonSchema = true,
            supportsPrefixCache = true,
            needsPrewarm = true,
        )
        private var turn = 0
        private var loaded = false

        override suspend fun load(config: ProviderConfig): Result<Unit> {
            loaded = true
            return Result.success(Unit)
        }

        override suspend fun prewarm(frozenPrefix: String): Result<Unit> = Result.success(Unit)
        override suspend fun release() {
            loaded = false
        }

        override fun health(): ProviderHealth = ProviderHealth(loaded, "scripted")

        override suspend fun generate(request: GenerateRequest): Result<GenerateResult> {
            val t = script.getOrNull(turn) ?: error("脚本用完了")
            turn++
            return Result.success(
                GenerateResult(t.text, CacheStats.withoutCacheReporting(0, 0), t.finish, t.calls),
            )
        }

        override fun generateStream(request: GenerateRequest): Flow<StreamChunk> = flow {
            val t = script.getOrNull(turn) ?: error("脚本用完了")
            turn++
            // ⚠️ 2026-10-19：**必须**先吐正文增量，再吐终止块。
            //    原生轨（`nativeToolsEnabled = true`）走的是 `generateStream`，而 `AgentLoop`
            //    从**非终止块**累加 `deltaText` 作为 `raw`；终止块只带 finishReason / toolCalls（`StreamChunk.hasPayload`）。
            //    早先这里只 `emit(StreamChunk.done(...))` ⇒ 第 2 轮正文恒为空 ⇒
            //    「输出无法解析：输出为空」⇒ 走不到最终回答（本用例因此挂/断言失败过一次）。
            if (t.text.isNotEmpty()) emit(StreamChunk.text(t.text))
            emit(StreamChunk.done(t.finish, t.calls))
        }

        override fun lastStreamCache(): CacheStats = CacheStats.withoutCacheReporting(0, 0)
    }

    private val writeSpec = ToolSpec(
        "write_file", "写文件",
        listOf(ToolParam("path", "string", "路径"), ToolParam("content", "string", "内容")),
    )

    private class RecordingTool(
        override val spec: ToolSpec,
        private val result: ToolOutcome,
    ) : AgentTool {
        val executeCount = AtomicInteger(0)
        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            executeCount.incrementAndGet()
            return result
        }
    }

    @Test
    @DisplayName("★★ 白名单已预填 ⇒ 手动审批档**不再弹窗**，工具照常执行")
    fun seededAllowlistSkipsApproval() {
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val call = NativeToolCall("c1", "write_file", """{"path":"a.txt","content":"x"}""")
        val provider = ScriptedProvider(
            listOf(
                ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
                ScriptTurn("好", FinishReason.STOP),
            ),
        )
        // 模拟"装配处从 SharedPreferences 读出来并 seed"
        val queue = AgentLoop.ApprovalQueue()
        queue.seed(listOf("write_file"))
        val requests = mutableListOf<AgentEvent>()

        // ⚠️ 2026-10-19 修正：只 `seed(queue)` **不够** —— `alwaysAllowed` 原先没有任何读点，
        //    `approve()` 根本不会看它 ⇒ 这条测试会挂死在审批等待上（挂起在 ApprovalQueue.await）。
        //    装配处（AgentBridge）现在还必须把**同一份集合**作为 `persistentAllowlist` 传进来。
        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalMode = ApprovalMode.MANUAL,
                approvalReplies = queue,
                persistentAllowlist = queue.alwaysAllowed,
                onEvent = { if (it is AgentEvent.ApprovalRequest) requests += it },
            ).run("写文件")
        }

        assertEquals(0, requests.size, "白名单里的工具不该再问：$requests")
        assertEquals(1, tool.executeCount.get(), "工具必须照常执行")
    }

    @Test
    @DisplayName("★★ 反证：只 seed 但**没把集合接到读点** ⇒ 白名单不起作用（正是 2026-10-19 修掉的那个断线）")
    fun seedWithoutReadPointIsInert() {
        // 这条钉住修复的"另一半真相"：`alwaysAllowed` 被 `seed()` 写进去，
        // 但如果装配处忘了传 `persistentAllowlist`，它就是一份**没人读的集合**。
        // 反向证明：上面那条测试能过，靠的是读点接了线，而不是 seed() 本身。
        val queue = AgentLoop.ApprovalQueue()
        queue.seed(listOf("write_file"))
        assertTrue("write_file" in queue.alwaysAllowed, "seed 本身要能写进集合")

        // 用 EMPTY 队列当应答通道 ⇒ 无人回答 ⇒ 立刻按拒绝处理（不会挂）
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val call = NativeToolCall("c1", "write_file", """{"path":"a.txt","content":"x"}""")
        val provider = ScriptedProvider(
            listOf(
                ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
                ScriptTurn("好", FinishReason.STOP),
            ),
        )
        val requests = mutableListOf<AgentEvent>()
        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalMode = ApprovalMode.MANUAL,
                approvalReplies = AgentLoop.ApprovalQueue.EMPTY,
                // ← 故意**不**传 persistentAllowlist
                onEvent = { if (it is AgentEvent.ApprovalRequest) requests += it },
            ).run("写文件")
        }

        assertEquals(1, requests.size, "没接到读点 ⇒ 仍然要问：$requests")
        assertEquals(0, tool.executeCount.get(), "没人批准就不能执行")
    }

    @Test
    @DisplayName("★ 反证：不在白名单里的工具**仍然要问**（白名单不是「全放行」）")
    fun unseededToolStillAsks() {
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val call = NativeToolCall("c1", "write_file", """{"path":"a.txt","content":"x"}""")
        val provider = ScriptedProvider(
            listOf(
                ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
                ScriptTurn("好", FinishReason.STOP),
            ),
        )
        // 白名单里有别的工具，但没有 write_file
        // ⚠️ 用 **EMPTY**（timeout=0 ⇒ `await()` 立刻返回 null ⇒ 按拒绝处理），
        //    **不能**用默认 10 分钟超时的 `ApprovalQueue()`：测试里没人回答，
        //    而 `withTimeoutOrNull(10m)` **依赖协程事件循环的定时器**，在测试 harness /
        //    真机主线程被占住时**不一定能按时触发**（真机 2026-10-19 就踩到「工具全成功然后静默」）。
        //    首版这里写了 `ApprovalQueue()` + 注释"无 UI 应答 ⇒ 立即按拒绝处理" —— **那句注释是错的**。
        val queue = AgentLoop.ApprovalQueue.EMPTY
        queue.seed(listOf("run_shell_command"))
        val requests = mutableListOf<AgentEvent>()

        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalMode = ApprovalMode.MANUAL,
                approvalReplies = queue,
                // 读点接上（白名单里只有 run_shell_command ⇒ write_file 仍要问）
                persistentAllowlist = queue.alwaysAllowed,
                onEvent = { if (it is AgentEvent.ApprovalRequest) requests += it },
            ).run("写文件")
        }

        assertEquals(1, requests.size, "不在白名单里的工具必须问一次：$requests")
        assertEquals(0, tool.executeCount.get(), "没人批准就不能执行")
    }

    /**
     * **诊断用**（2026-10-19）：审查 `ApprovalQueue` 在本测试 harness 下**能不能超时**。
     *
     * 背景：`unseededToolStillAsks` / `seedWithoutReadPointIsInert` 用 `ApprovalQueue.EMPTY`
     * （timeout=0）当应答通道，**期望**它立刻返回 TIMEOUT。实测却挂死 —— 要么
     * `withTimeoutOrNull(Duration.ZERO)` 在这个上下文里不可靠，要么别的什么挡住了。
     *
     * 这条测试把这一点单独测出来，避免"产品 bug"与"测试 harness 假设"混在一起。
     */
    @Test
    @org.junit.jupiter.api.Timeout(60)
    @DisplayName("◐ 诊断：ApprovalQueue.EMPTY 的 await() 必须**立刻**返回 null，不能挂")
    fun emptyQueueAwaitReturnsImmediately() {
        val t0 = System.nanoTime()
        val d = runBlocking { AgentLoop.ApprovalQueue.EMPTY.await() }
        val ms = (System.nanoTime() - t0) / 1_000_000
        org.junit.jupiter.api.Assertions.assertNull(d, "EMPTY 队列没人回答 ⇒ 必须是 null")
        assertTrue(ms < 2000, "EMPTY 队列的 timeout=0 ⇒ 应该几乎立刻返回，实测 ${ms}ms")
    }

    @Test
    @org.junit.jupiter.api.Timeout(60)
    @DisplayName("◐ 诊断：普通 ApprovalQueue（10 分钟超时）+ 显式 1 秒…… 见下")
    fun shortTimeoutQueueReturnsNull() {
        // 用 runBlocking + withTimeoutOrNull 外包一层，验证超时机制本身在测试 harness 里是活的
        val t0 = System.nanoTime()
        val d = runBlocking {
            val q = AgentLoop.ApprovalQueue(kotlin.time.Duration.parse("300ms"))
            q.await()
        }
        val ms = (System.nanoTime() - t0) / 1_000_000
        org.junit.jupiter.api.Assertions.assertNull(d, "没人回答 ⇒ null")
        assertTrue(ms < 5000, "300ms 超时应该很快返回，实测 ${ms}ms")
    }

    @Test
    @org.junit.jupiter.api.Timeout(90)
    @DisplayName("★★ `ALLOW_ALWAYS` 点一次后，**同一 run 的后续同类调用**不再问（本 run 语义）")
    fun allowAlwaysAppliesWithinRun() {
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        // 同一 run 里两次 write_file：**参数必须不同，否则第二次会被"循环检测"拦下**
        // （阈值是连续 1 次：第 2 次相同调用**不执行**）。首版用了相同的 path/content ⇒
        // executeCount 只有 1，且 ToolStarted/ApprovalRequest 都不会再发 ⇒ 断言失真。
        val call1 = NativeToolCall("c1", "write_file", """{"path":"a.txt","content":"x"}""")
        val call2 = NativeToolCall("c2", "write_file", """{"path":"b.txt","content":"y"}""")
        val queue = AgentLoop.ApprovalQueue()
        val requests = mutableListOf<AgentEvent>()

        // ⚠️ 两个坑，都在这条测试的首两个版本上真踩过：
        //   ① 不能"先 reply 再 run"：队列是 RENDEZVOUS + trySend，**没人挂起接收时投递会被丢掉**
        //      ⇒ 第一次询问等不到回答 ⇒ 挂 10 分钟超时。
        //   ② 不能在 `emit(ApprovalRequest)` 的**同一个回调里**立刻 reply：那时 `await()` 还没挂起，
        //      同样丢包 ⇒ 一样挂死。**可靠的同步点是 `ToolStarted`** —— 它一定在 `await()` 之后发。
        var firstApproved = false
        // ⚠️ ③ **reply 必须是异步的**：`emit` 是**同步**回调，在它里面直接 `queue.reply()` 时
        //    `await()` 还没挂起 ⇒ trySend 失败 ⇒ 丢包 ⇒ 挂死。用 `CoroutineScope(Dispatchers.Default)`
        //    投递，让出调度，等 `await()` 真正挂起后再送。
        val replyScope = CoroutineScope(Dispatchers.Default)
        runBlocking {
            val p = ScriptedProvider(
                listOf(
                    ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call1)),
                    ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call2)),
                    ScriptTurn("好", FinishReason.STOP),
                ),
            )
            p.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                p, NoopFs(), listOf(tool),
                maxTurns = 4, nativeToolsEnabled = true,
                approvalMode = ApprovalMode.MANUAL,
                approvalReplies = queue,
                onEvent = {
                    when (it) {
                        is AgentEvent.ApprovalRequest -> requests += it
                        is AgentEvent.ToolStarted ->
                            if (!firstApproved) {
                                firstApproved = true
                                // 用户点「本会话始终允许」——异步投递，见上面的 ⚠️③
                                replyScope.launch {
                                    delay(50)
                                    queue.reply(AgentLoop.ApprovalDecision.ALLOW_ALWAYS)
                                }
                                Unit
                            }
                        else -> Unit
                    }
                },
            ).run("写两个文件")
        }

        assertEquals(1, requests.size, "只该问第一次：$requests")
        assertEquals(2, tool.executeCount.get(), "两次调用都要执行")
    }

    /**
     * 工具**第一次**返回 `NeedsApproval`、之后返回成功 —— 模拟 `write_file` 走**路径 B**。
     *
     * ⚠️ 为什么需要它：文件里别的用例用的 [RecordingTool] 恒定返回 `Success`，走的是**路径 A**
     * （`MANUAL` 档 + `mutatingTools` ⇒ `needAsk`）。而真机上 `write_file` 的工具实现自己会返回
     * `NeedsApproval`，于是 `AgentLoop` 走**路径 B**（`when (approve(...))`，批准后**重新 execute 一次**）。
     * 两条路由同一个 `RecordingTool` 表达不出来（要么永远 NeedsApproval ⇒ 批准后还是 NeedsApproval，
     * 要么永远 Success ⇒ 根本进不了路径 B）。
     */
    private class NeedsApprovalThenSuccessTool(override val spec: ToolSpec) : AgentTool {
        val executeCount = AtomicInteger(0)
        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            val n = executeCount.incrementAndGet()
            return if (n == 1) {
                ToolOutcome.NeedsApproval("写文件需要确认")
            } else {
                ToolOutcome.Success("已写入")
            }
        }
    }

    @Test
    @org.junit.jupiter.api.Timeout(90)
    @DisplayName("★★ 真机 bug 回归：走 NeedsApproval 那条路点「始终允许」也必须进持久白名单")
    fun needsApprovalPathRecordsAllowAlways() {
        // ## 这条钉的是真机上抓到的那个 bug（2026-10-19，设备 e35e48c6）
        //
        // 手动审批档 ⇒ 发 `Create t.txt with content x` ⇒ 弹窗点「本会话始终允许」⇒
        // write_file **执行成功**，但 `shared_prefs/heracles_approvals.xml` 里
        // `always_allowed_tools` 是**空集**（装配处 logcat：`seed 0 条：[]` → `save 0 条：[]`）。
        //
        // 根因：`AgentLoop` 有**两条**审批路径 --
        //   · 路径 A：`needAsk`（MANUAL 档 + `mutatingTools`）—— 历史上有把 ALLOW_ALWAYS 记进白名单
        //   · 路径 B：工具自己返回 `ToolOutcome.NeedsApproval` —— **原先一条都没记**
        //
        // ## ⚠️ 截至 2026-10-19 本用例**仍然 FAILED**，且这是**产品侧的真实缺口**（不是测试写错）
        //
        // Lead 的修法（`approve()` 记 `lastDecision`，路径 B 据此写白名单）在**只有路径 B** 时是对的：
        // 实测 `ApprovalMode.WORKSPACE_AUTO`（`needAsk=false` ⇒ 路径 A 不触发）下
        // `alwaysAllowed=[write_file]` ✅。
        //
        // 但**真机是 MANUAL 档**，而 `write_file` 在 `mutatingTools` 里 ⇒ 同一个调用**两条路都会触发**：
        //   ① 路径 A：`approve()` → 用户点 ALLOW_ALWAYS → `sessionApprovals += write_file`
        //   ② 工具执行，返回 `NeedsApproval` → 路径 B 再 `approve()`
        //      → **命中 `sig in sessionApprovals` 早退**（`return ApprovalResult.ALLOWED`）
        //      → 早退分支**不设 `lastDecision`** ⇒ 路径 B 的写白名单那行**永远不执行**
        //   ⇒ 实测 `alwaysAllowed=[]`，与真机现象一致。
        //
        // 单测可观测证据（`approve()` 里现成的 println）：
        //   `write_file asked → decision=ALLOW_ALWAYS` 紧跟 `write_file early-exit=sessionApprovals`
        //
        // **修法方向**（留给产品侧决定，本测试不改产品代码）：让「记持久白名单」不依赖
        // `lastDecision` 这个易被早退清掉的旁路 —— 例如把 `ALLOW_ALWAYS` 的写入集中到
        // `approve()` 里（拿到 d 为 ALLOW_ALWAYS 时**同时**写 `sessionApprovals` 与
        // `persistentAllowlist`），而不是分散在两条调用路径上。
        // 这条测试就该**保持红色**，直到产品把那一步补上。
        //
        // ⚠️ 因此本用例**必须**让工具返回 `NeedsApproval`（走路径 B）—— 用 `Success` 的
        //    `RecordingTool` 只会走路径 A，那条一直是通的，钉不住这个 bug。
        val tool = NeedsApprovalThenSuccessTool(writeSpec)
        val call = NativeToolCall("c1", "write_file", """{"path":"t.txt","content":"x"}""")
        val provider = ScriptedProvider(
            listOf(
                // 第 1 轮：模型要调 write_file（工具返回 NeedsApproval ⇒ 挂起问用户）
                ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
                // 第 2 轮：批准后重新执行成功 ⇒ 模型收工
                ScriptTurn("好", FinishReason.STOP),
            ),
        )
        val queue = AgentLoop.ApprovalQueue()
        val requests = mutableListOf<AgentEvent>()
        val replyScope = CoroutineScope(Dispatchers.Default)

        // ⚠️ 首版把同步点选成 `ToolFinished` —— **错的，而且症状是挂死**（实测：90s TimeoutException）。
        //
        // 路径 B 的真实时间线（`AgentLoop` 1700–1731）：`emit(ToolStarted)` → `execute()` 返回
        // NeedsApproval → `emit(ApprovalRequest)` → `await()` **挂起** …… 用户回答后
        // 再 execute 一次 → **然后才** `emit(ToolFinished)`。
        // 也就是说 `ToolFinished` 在 `await()` **之后**才发 ⇒ 它到达时 `await()` 已经在挂起，
        // 但**我的 reply 从未投递**（回调里根本没被触发）⇒ 等到 10 分钟超时 / JUnit 90s。
        // ⇒ 同步点必须选 **`ApprovalRequest`**：它在 `await()` **之前**发，是这条路径上唯一
        //    "马上要挂起"的信号。`emit` 是同步回调 ⇒ 在它里面**直接** `reply()` 会丢包
        //    （`trySend` 时还没人接收）⇒ 必须 `delay(50)` 异步投递，与 `allowAlwaysAppliesWithinRun` 同一写法。
        var replied = false
        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 4, nativeToolsEnabled = true,
                approvalMode = ApprovalMode.MANUAL,
                approvalReplies = queue,
                persistentAllowlist = queue.alwaysAllowed,
                onEvent = {
                    when (it) {
                        is AgentEvent.ApprovalRequest -> {
                            requests += it
                            if (!replied) {
                                replied = true
                                // 用户点「本会话始终允许」—— **必须异步投递**
                                replyScope.launch {
                                    delay(50)
                                    queue.reply(AgentLoop.ApprovalDecision.ALLOW_ALWAYS)
                                }
                                Unit
                            }
                        }
                        else -> Unit
                    }
                },
            ).run("写文件")
        }

        // ★ 这就是 Lead 修的那一行：路径 B 的 ALLOW_ALWAYS 也必须落到持久白名单里
        assertTrue(
            "write_file" in queue.alwaysAllowed,
            "走 NeedsApproval 那条路点「始终允许」后，持久白名单里必须有 write_file；" +
                "实测 ${queue.alwaysAllowed}（空集 = 真机那个 bug 复现了）",
        )
        assertEquals(1, requests.size, "只该问一次：$requests")
        assertEquals(2, tool.executeCount.get(), "第一次返回 NeedsApproval、批准后必须重新执行一次")
    }

    @Test
    @DisplayName("★★ 修断线后的真语义：`seed` 进来的白名单**跨 run 生效**（装配处落盘 ⇒ 下次 seed 回来）")
    fun seededAllowlistAppliesToLaterRun() {
        val tool = RecordingTool(writeSpec, ToolOutcome.Success("已写入"))
        val call = NativeToolCall("c1", "write_file", """{"path":"a.txt","content":"x"}""")

        // 模拟「上次 run 结束时 AgentBridge 落盘、这次 run 开始前 seed 回来」
        val saved = setOf("write_file")
        val requests = mutableListOf<AgentEvent>()
        runBlocking {
            val queue = AgentLoop.ApprovalQueue()
            queue.seed(saved)
            val p = ScriptedProvider(
                listOf(
                    ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
                    ScriptTurn("好", FinishReason.STOP),
                ),
            )
            p.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                p, NoopFs(), listOf(tool),
                maxTurns = 3, nativeToolsEnabled = true,
                approvalMode = ApprovalMode.MANUAL,
                approvalReplies = queue,
                persistentAllowlist = queue.alwaysAllowed,
                onEvent = { if (it is AgentEvent.ApprovalRequest) requests += it },
            ).run("写文件")
            // run 结束装配处会把「实际使用的白名单」原样写回 —— 这里核它没被清成空集
            assertEquals(saved, queue.alwaysAllowed, "落盘读到的白名单不许被 run 清掉")
        }

        assertEquals(0, requests.size, "已始终允许过的工具，新 run 不该再问：$requests")
        assertEquals(1, tool.executeCount.get(), "工具必须照常执行")
    }
}
