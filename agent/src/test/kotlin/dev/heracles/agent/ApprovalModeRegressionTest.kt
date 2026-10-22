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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.nio.file.Paths
import java.util.concurrent.atomic.AtomicInteger

/**
 * **审批档位 × ApprovalRequest 事件的回归门禁**（2026-10-21，BUG-1）。
 *
 * ## 用户报的症状
 *
 * > 「开了完全权限，还要手动点允许」
 *
 * ## 根因（两层，缺一不可）
 *
 * 1. **Dart 侧**：`chat_screen.dart` 的 `_showApprovalDialog` **无条件弹窗** ——
 *    它只看"收到了一个 ApprovalRequest 事件"，从不看当前 `PermissionMode`。
 *    所以只要 Kotlin 侧任何一条路径漏发 / 漏判档位，用户就被拽回弹窗。
 *    （修法在 Dart 那侧加了 fullAccess 短路；本条测试只管 Kotlin 侧。）
 * 2. **Kotlin 侧反向漏洞**：`mutatingTools` **漏了 `edit` 与 `restore_path`** ——
 *    这份集合是白名单语义（不在里面 = MANUAL 档**不问就执行**），
 *    所以漏成员 = 手动审批档下的**静默放行**：用 `edit` 改代码不问，
 *    而用 `apply_patch` 改代码会问。同一个语义，两种行为。
 *
 * ## 这组断言守什么
 *
 * | 档位 | 工具 | 期望 |
 * |---|---|---|
 * | FULL_ACCESS | write_file / edit / 返回 NeedsApproval 的 write_file | **不发** ApprovalRequest，且**照常执行** |
 * | MANUAL | edit（带普通副作用工具） | **必须发** ApprovalRequest（漏了就是静默放行） |
 * | MANUAL | write_file（既有行为） | 仍必须发（钉住没被这次改动带跑） |
 * | WORKSPACE_AUTO | write_file（工作区内） | **不发**（默认档位的既有语义） |
 *
 * ## 为什么这些用例不能只测 `mutatingTools` 这个 `private val`
 *
 * 它是 `private` 的，而且**真正的语义是"发不发事件"**，不是"集合里有没有这个字符串"。
 * 所以这里一律走完整 `AgentLoop.run(...)` + 真实事件流。
 */
class ApprovalModeRegressionTest {

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
        override val id = "scripted:approval-mode"
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
            // 原生轨走 generateStream：正文增量先吐，终止块带 finish/calls（见 ApprovalAllowlistTest）
            if (t.text.isNotEmpty()) emit(StreamChunk.text(t.text))
            emit(StreamChunk.done(t.finish, t.calls))
        }

        override fun lastStreamCache(): CacheStats = CacheStats.withoutCacheReporting(0, 0)
    }

    /** 记录执行次数的假工具。 */
    private class RecordingTool(
        override val spec: ToolSpec,
        private val result: ToolOutcome = ToolOutcome.Success("已执行"),
    ) : AgentTool {
        val executeCount = AtomicInteger(0)
        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            executeCount.incrementAndGet()
            return result
        }
    }

    /** 返回一次 `NeedsApproval`（模拟命令守卫），用于钉 FULL_ACCESS 的"自动放行"路径。 */
    private class NeedsApprovalThenSuccessTool(override val spec: ToolSpec) : AgentTool {
        val executeCount = AtomicInteger(0)
        override suspend fun execute(args: Map<String, String>): ToolOutcome {
            val n = executeCount.incrementAndGet()
            return if (n == 1) ToolOutcome.NeedsApproval("这条命令需要人看一眼") else ToolOutcome.Success("已执行")
        }
    }

    private val editSpec = ToolSpec(
        "edit", "局部替换代码",
        listOf(
            ToolParam("path", "string", "路径"),
            ToolParam("old_string", "string", "原文"),
            ToolParam("new_string", "string", "新内容"),
        ),
    )
    private val writeSpec = ToolSpec(
        "write_file", "写文件",
        listOf(ToolParam("path", "string", "路径"), ToolParam("content", "string", "内容")),
    )
    private val restoreSpec = ToolSpec(
        "restore_path", "从快照恢复",
        listOf(ToolParam("path", "string", "路径")),
    )

    private fun editCall(id: String = "c1") =
        NativeToolCall(id, "edit", """{"path":"a.kt","old_string":"a","new_string":"b"}""")

    private fun writeCall(id: String = "c1") =
        NativeToolCall(id, "write_file", """{"path":"a.txt","content":"x"}""")

    private fun restoreCall(id: String = "c1") =
        NativeToolCall(id, "restore_path", """{"path":"a.txt"}""")

    /**
     * 跑一次完整任务，返回 (收到的审批事件, 工具执行次数)。
     *
     * 脚本统一两轮：第 1 轮给一个工具调用、第 2 轮给最终回答。
     * `approvalReplies` 一律用 `ApprovalQueue.EMPTY`（timeout=0 ⇒ `await()` 立刻返回 null
     * ⇒ 按拒绝处理）—— **绝不会挂**，也不会在没人看的时候放行。
     */
    private fun runOnce(
        mode: ApprovalMode,
        tool: AgentTool,
        call: NativeToolCall,
        persistentAllowlist: Set<String> = emptySet(),
    ): Pair<List<AgentEvent.ApprovalRequest>, AtomicInteger> {
        val provider = ScriptedProvider(
            listOf(
                ScriptTurn("", FinishReason.TOOL_CALLS, listOf(call)),
                ScriptTurn("好", FinishReason.STOP),
            ),
        )
        val requests = mutableListOf<AgentEvent.ApprovalRequest>()
        val counter = AtomicInteger(0)
        runBlocking {
            provider.load(ProviderConfig()).getOrThrow()
            AgentLoop(
                provider, NoopFs(), listOf(tool),
                maxTurns = 3,
                nativeToolsEnabled = true,
                approvalMode = mode,
                approvalReplies = AgentLoop.ApprovalQueue.EMPTY,
                persistentAllowlist = persistentAllowlist,
                onEvent = { if (it is AgentEvent.ApprovalRequest) requests += it },
            ).run("做点事")
        }
        // 用真实工具的执行次数当"到底跑没跑"的证据
        if (tool is RecordingTool) counter.set(tool.executeCount.get())
        if (tool is NeedsApprovalThenSuccessTool) counter.set(tool.executeCount.get())
        return requests to counter
    }

    // ============================================================
    // ★★ BUG-1 主诉：FULL_ACCESS 档**绝不**发 ApprovalRequest
    // ============================================================

    @Test
    @DisplayName("★★ 完全访问档：write_file **不发** ApprovalRequest 且照常执行（用户报的「还要点允许」）")
    fun fullAccessDoesNotEmitApprovalForWriteFile() {
        val tool = RecordingTool(writeSpec)
        val (requests, count) = runOnce(ApprovalMode.FULL_ACCESS, tool, writeCall())

        assertEquals(0, requests.size, "完全访问档不该弹窗（发了 ApprovalRequest = UI 会弹），实际：$requests")
        assertEquals(1, count.get(), "不问 ≠ 不执行：工具必须真的跑一次")
    }

    @Test
    @DisplayName("★★ 完全访问档：edit 同样**不发** ApprovalRequest（BUG-1 反向漏洞的另一半）")
    fun fullAccessDoesNotEmitApprovalForEdit() {
        val tool = RecordingTool(editSpec)
        val (requests, count) = runOnce(ApprovalMode.FULL_ACCESS, tool, editCall())

        assertEquals(0, requests.size, "完全访问档下 edit 也不许问，实际：$requests")
        assertEquals(1, count.get(), "工具必须真的跑一次")
    }

    @Test
    @DisplayName("★★ 完全访问档：工具自己返回 NeedsApproval 时**自动放行**、不弹窗（路径 B 也不许漏）")
    fun fullAccessAutoAllowsNeedsApproval() {
        // 这条钉的是"路径 B"：工具**实现**返回 NeedsApproval（真机上 write_file / 命令守卫会这样），
        // 完全访问档必须在**不问**的前提下直接重试执行。
        val tool = NeedsApprovalThenSuccessTool(writeSpec)
        val (requests, count) = runOnce(ApprovalMode.FULL_ACCESS, tool, writeCall())

        assertEquals(0, requests.size, "完全访问档下 NeedsApproval 也自动放行，不许弹窗：$requests")
        assertEquals(2, count.get(), "第 1 次返回 NeedsApproval、自动放行后必须重新执行一次")
    }

    @Test
    @DisplayName("★★ 完全访问档：restore_path 也不问（从快照写回文件 = 文件系统副作用）")
    fun fullAccessDoesNotEmitApprovalForRestorePath() {
        val tool = RecordingTool(restoreSpec)
        val (requests, _) = runOnce(ApprovalMode.FULL_ACCESS, tool, restoreCall())
        assertEquals(0, requests.size, "完全访问档不该问，实际：$requests")
    }

    // ============================================================
    // ★★ 反向漏洞：MANUAL 档下 edit / restore_path **必须问**
    // ============================================================

    @Test
    @DisplayName("★★ 手动审批档：edit **必须**发 ApprovalRequest（漏了 = 静默放行，BUG-1 根因）")
    fun manualAsksForEdit() {
        // ⚠️ 这条在修复前必红：`mutatingTools` 里没有 "edit" ⇒ needAsk=false ⇒
        //    既不发事件、也不等批准，`edit` 直接执行 —— 用户以为"手动审批"挡着，其实没挡。
        val tool = RecordingTool(editSpec)
        val (requests, count) = runOnce(ApprovalMode.MANUAL, tool, editCall())

        assertEquals(1, requests.size, "手动审批档下 edit 必须问一次，实际：$requests")
        assertEquals("edit", requests.first().call.tool)
        assertEquals(0, count.get(), "没人批准（EMPTY 队列）⇒ 绝不许执行")
    }

    @Test
    @DisplayName("★★ 手动审批档：restore_path **必须**发 ApprovalRequest（它会覆盖用户当前内容）")
    fun manualAsksForRestorePath() {
        val tool = RecordingTool(restoreSpec)
        val (requests, count) = runOnce(ApprovalMode.MANUAL, tool, restoreCall())

        assertEquals(1, requests.size, "手动审批档下 restore_path 必须问一次，实际：$requests")
        assertEquals(0, count.get(), "没人批准 ⇒ 不许执行")
    }

    @Test
    @DisplayName("★ 手动审批档：write_file 仍必须问（钉住既有行为没被带跑）")
    fun manualAsksForWriteFile() {
        val tool = RecordingTool(writeSpec)
        val (requests, count) = runOnce(ApprovalMode.MANUAL, tool, writeCall())
        assertEquals(1, requests.size, "手动审批档下 write_file 必须问：$requests")
        assertEquals(0, count.get(), "没人批准 ⇒ 不许执行")
    }

    // ============================================================
    // ★ 默认档位的语义不许被这次改动误伤
    // ============================================================

    @Test
    @DisplayName("★ 工作区内自动档：工作区内的 write_file **不问**（默认档位既有语义）")
    fun workspaceAutoDoesNotAskInsideWorkspace() {
        val tool = RecordingTool(writeSpec)
        val (requests, count) = runOnce(ApprovalMode.WORKSPACE_AUTO, tool, writeCall())
        assertEquals(0, requests.size, "工作区内不该问：$requests")
        assertEquals(1, count.get(), "应该直接执行")
    }

    @Test
    @DisplayName("★ 工作区内自动档：工作区外的 write_file **必须问**（越界判定照旧生效）")
    fun workspaceAutoAsksOutsideWorkspace() {
        val tool = RecordingTool(writeSpec)
        val outsideCall = NativeToolCall(
            "c1", "write_file",
            """{"path":"/sdcard/other/a.txt","content":"x"}""",
        )
        val (requests, count) = runOnce(ApprovalMode.WORKSPACE_AUTO, tool, outsideCall)
        assertEquals(1, requests.size, "越界必须问：$requests")
        assertEquals(0, count.get(), "没人批准 ⇒ 不许执行")
    }

    // ============================================================
    // ★ 档位解析（`ApprovalMode.parse` 与 Dart `PermissionMode.name` 的映射）
    // ============================================================

    @Test
    @DisplayName("★★ Dart `PermissionMode.fullAccess.name` → \"fullaccess\" 必须解析成 FULL_ACCESS")
    fun dartPermissionModeNameParses() {
        // Dart 侧传的是 `mode.name.toLowerCase()`。名字对不上 ⇒ 回落 WORKSPACE_AUTO
        // ⇒ 用户明明选了「完全访问」却仍被问 —— 这正是 BUG-1 的一个可能入口。
        assertEquals(ApprovalMode.FULL_ACCESS, ApprovalMode.parse("fullaccess"))
        assertEquals(ApprovalMode.FULL_ACCESS, ApprovalMode.parse("full_access"))
        assertEquals(ApprovalMode.FULL_ACCESS, ApprovalMode.parse("  FullAccess  "))
        assertEquals(ApprovalMode.MANUAL, ApprovalMode.parse("manual"))
        assertEquals(ApprovalMode.WORKSPACE_AUTO, ApprovalMode.parse("workspaceAuto"))
        // 认不出 / null ⇒ 最保守的 WORKSPACE_AUTO（不许默认成全放行）
        assertEquals(ApprovalMode.WORKSPACE_AUTO, ApprovalMode.parse(null))
        assertEquals(ApprovalMode.WORKSPACE_AUTO, ApprovalMode.parse("garbage"))
    }

    @Test
    @DisplayName("★ 白名单仍然生效：手动审批档 + 已始终允许 ⇒ 不发事件（这次改动不许带跑白名单）")
    fun allowlistStillShortCircuitsInManualMode() {
        val tool = RecordingTool(editSpec)
        val (requests, count) = runOnce(
            ApprovalMode.MANUAL, tool, editCall(),
            persistentAllowlist = setOf("edit"),
        )
        assertEquals(0, requests.size, "白名单里的 edit 不该再问：$requests")
        assertEquals(1, count.get(), "白名单命中 ⇒ 必须执行")
    }

    @Test
    @DisplayName("★ 守卫：写入类工具名单覆盖 edit / restore_path（未来漏加会在这条报红）")
    fun mutatingToolSetCoversKnownWriters() {
        // 用反射读 private val —— 这是**唯一**能防止"新增工具忘记加名单"的静态守卫。
        // 之所以只断言"包含"，不断言"恰好等于"：新增工具是正常演进，
        // 我们要拦的是**漏加**（少一个 = MANUAL 档静默放行），不是"多了一个"。
        val loop = AgentLoop(
            ScriptedProvider(emptyList()), NoopFs(), emptyList(),
            nativeToolsEnabled = true,
        )
        val field = AgentLoop::class.java.getDeclaredField("mutatingTools")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val set = field.get(loop) as Set<String>
        for (name in listOf(
            "write_file", "apply_patch", "edit", "restore_path",
            "delete_path", "move_path", "copy_path", "mkdir",
            "run_shell_command", "build_apk", "apk_sign",
        )) {
            assertTrue(
                name in set,
                "有副作用的工具 `$name` 必须在 mutatingTools 里 —— 漏了就是手动审批档的静默放行。" +
                    "实际集合：$set",
            )
        }
    }
}
