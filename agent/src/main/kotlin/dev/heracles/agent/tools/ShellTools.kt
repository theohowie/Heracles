package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.exec.CommandGuard
import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import dev.heracles.core.guard.DeviceHealthSource
import dev.heracles.core.guard.ThermalGuard
import dev.heracles.core.guard.ThermalVerdict
import dev.heracles.core.text.LogFilter
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.workspace.PathEscapeException
import dev.heracles.workspace.WorkspaceFs
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.concurrent.atomic.AtomicInteger

/**
 * **执行 shell 命令** —— `26-编码层工具链与逆向引擎.md` §4.1。
 *
 * ## 为什么这是本阶段最危险的一个工具
 *
 * 它给了模型**任意 shell**。所有其它工具的能力边界都由代码写死，
 * 只有这个没有 —— 所以它必须**叠四层防护**，缺一层都不能上：
 *
 * | 层 | 机制 | 拦什么 |
 * |---|---|---|
 * | ① 判定 | [CommandGuard] | `force-stop` / `kill` / `rm -rf /` 等（`AGENTS.md` 硬约束） |
 * | ② 沙箱 | `cwd` 限定在工作区内 | 在别的目录里乱写 |
 * | ③ 时限 | 超时 + [Contract.Shell.MAX_TIMEOUT_SEC] 上限 | 挂死 |
 * | ④ 熔断 | [ThermalGuard] | 过热 / 断电风险下继续跑 |
 *
 * ## 输出为什么不是"原始日志"
 *
 * 全量日志**落盘**（`.heracles/logs/`），进上下文的只有**摘录**（行数 =
 * [Contract.Shell.LOG_EXCERPT_LINES]，200；2026-10-18 F5a 的 P1-5 定的值，
 * ADR-035 S1b 起是**唯一**一档 —— 原先的"本地 40 / 云端 200"分级已删）。
 * 理由见 [LogFilter] 的类注释：append-only 的历史里塞 500 行日志，
 * 之后每一轮都要为它付 prefill —— 但反过来，只给 40 行会让模型看不到全貌、
 * 只好再 `read_file` 摸一遍（信息饥饿）。
 *
 * ⚠️ 额度**只影响摘录**：落盘的全量日志一行不少。
 *
 * ## ⚠️ 已知边界（如实声明）
 *
 * [CommandGuard] 是**防呆**，不是防蓄意攻击（变量拼接 / `eval` / 脚本包装
 * 都能绕过）。详见其类注释的"能力边界"表。真正的隔离需要沙箱，
 * 那是独立量级的工作。
 *
 * @param runner 真正的执行者；Android 侧是 `ShizukuShellRunner`，
 *   PC/CLI 侧是 `LocalProcessShellRunner`，测试侧是假实现
 * @param health 设备健康来源；`null` = 不做熔断检查（测试/CLI 场景）
 * @param maxExcerptLines 回给模型的日志摘录行数。默认
 *   [Contract.Shell.LOG_EXCERPT_LINES]（200）。留参数是为了测试能构造更小的额度；
 *   分级删除后装配处**不再**按后端传值。
 */
class RunShellCommandTool(
    private val runner: ShellRunner,
    private val fs: WorkspaceFs,
    private val health: DeviceHealthSource? = null,
    private val maxExcerptLines: Int = Contract.Shell.LOG_EXCERPT_LINES,
) : AgentTool {

    init {
        require(maxExcerptLines >= 1) {
            "maxExcerptLines 必须 ≥ 1（否则摘录永远是空的），收到 $maxExcerptLines"
        }
    }

    private val logSeq = AtomicInteger(0)

    override val spec = ToolSpec(
        name = "run_shell_command",
        description = "在工作区里执行一条 shell 命令（如 ls、grep、aapt2、javac、java -cp d8.jar …）。命令在工作区目录下运行。禁止杀进程、重启设备或删除工作区外的文件。返回的是错误摘录，完整日志会落盘，需要细节时用 read_file 读它。",
        parameters = listOf(
            ToolParam("command", "string", "要执行的命令，单条即可；有多步请分多次调用，便于定位失败"),
            // ★ optional = true（2026-10-18，F7b）：缺键与空串同义 ——
            //   cwd 空 ⇒ 不校验、`cwd.ifBlank { null }` 交给 runner（= 工作区根）；
            //   timeout_sec 空 ⇒ `toIntOrNull() ?: Contract.Shell.DEFAULT_TIMEOUT_SEC`。
            ToolParam(
                "cwd", "string", "命令的工作目录（相对工作区），不填（或传空字符串）= 工作区根目录",
                allowEmpty = true,
                optional = true,
            ),
            ToolParam(
                "timeout_sec", "string",
                "超时秒数，不填时默认 ${Contract.Shell.DEFAULT_TIMEOUT_SEC}，最大 ${Contract.Shell.MAX_TIMEOUT_SEC}",
                allowEmpty = true,
                optional = true,
            ),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val command = args["command"].orEmpty().trim()
        if (command.isBlank()) return ToolOutcome.Failure("command 为空")

        // ---------- ① 命令判定 ----------
        when (val verdict = CommandGuard.check(command)) {
            is CommandGuard.Deny -> return ToolOutcome.Failure("命令被拒绝：${verdict.reason}")
            is CommandGuard.NeedsApproval -> return ToolOutcome.NeedsApproval(verdict.reason)
            CommandGuard.Allow -> Unit
        }

        // ---------- ② cwd 限定在工作区内 ----------
        val cwd = args["cwd"].orEmpty().trim()
        if (cwd.isNotEmpty()) {
            try {
                // 只是为了**验证**它在工作区内 —— 真正的解析由 ShellRunner 承担。
                // 越界必须在这里就被拦下（不能等到 shell 里 cd 出去）。
                fs.info.rootPath.let { dev.heracles.workspace.PathGuard.resolve(it, cwd) }
            } catch (e: PathEscapeException) {
                return ToolOutcome.Failure("工作目录被拒绝：${e.reason}")
            }
        }

        // ---------- ③ 超时（带上限，模型不能自己延长到 1 小时） ----------
        val requested = args["timeout_sec"].orEmpty().trim().toIntOrNull()
            ?: Contract.Shell.DEFAULT_TIMEOUT_SEC
        val timeout = requested.coerceIn(1, Contract.Shell.MAX_TIMEOUT_SEC)
        val clamped = if (timeout != requested) {
            "（请求 ${requested}s，已收敛到 ${timeout}s）"
        } else {
            ""
        }

        // ---------- ④ 热 / 电量熔断 ----------
        if (health != null) {
            when (val v = ThermalGuard.check(health.read())) {
                is ThermalVerdict.Pause -> return ToolOutcome.Failure("★ 已暂停：${v.reason}")
                ThermalVerdict.Allow -> Unit
            }
        }

        // ---------- 执行 ----------
        val result = try {
            runner.run(command, timeout, cwd.ifBlank { null })
        } catch (e: Exception) {
            return ToolOutcome.Failure("执行失败（未能启动进程）：${e.message}")
        }

        // ---------- 全量日志落盘（失败**不阻断**回报） ----------
        val logPath = writeLog(command, result, maxExcerptLines)

        // ★ 摘录额度传进去（F5a；S1b 起唯一一档 = 200）。**只影响摘录**，落盘已在上一步完成。
        val excerpt = LogFilter.extract(result.combined(), result.exitCode, logPath, maxExcerptLines)
        val text = LogFilter.format(excerpt, result.exitCode, result.timedOut)
        val head = buildString {
            append(text)
            append("\n（耗时 ${result.durationMs}ms")
            if (clamped.isNotEmpty()) append("，超时").append(clamped)
            append("）")
        }

        return if (result.ok) {
            ToolOutcome.Success(head)
        } else {
            // 非 0 退出码**必须**是 Failure —— 否则模型会把失败当成功继续往下走
            ToolOutcome.Failure(head)
        }
    }

    /**
     * 把全量日志写进工作区。**失败不抛** —— 日志是证据，命令本身才是结果；
     * 因为日志写不进去而丢掉"命令到底跑成没跑成"是本末倒置。
     *
     * ⚠️ [maxExcerptLines] **只用于表头文案**（"给模型的摘录只有 N 行"），
     * 不参与日志正文的截断：正文只受 [Contract.Shell.MAX_CAPTURED_BYTES] 约束。
     * 表头里的 N 必须与真实摘录档位同源 —— 否则就是在一份证据文件里说谎。
     */
    private suspend fun writeLog(
        command: String,
        result: ShellResult,
        maxExcerptLines: Int,
    ): String? {
        val log = result.combined()
        if (log.isBlank()) return null
        val capped = if (log.length > Contract.Shell.MAX_CAPTURED_BYTES) {
            log.take(Contract.Shell.MAX_CAPTURED_BYTES)
        } else {
            log
        }
        val date = LocalDate.now().format(DateTimeFormatter.BASIC_ISO_DATE)
        val name = "${Contract.Toolchain.LOG_DIR}/shell-$date-${logSeq.incrementAndGet()}.log"
        val header = buildString {
            append("# 命令： ").append(command).append('\n')
            append("# 退出码： ").append(result.exitCode)
            if (result.timedOut) append("（超时被中止）")
            append('\n')
            append("# 耗时： ").append(result.durationMs).append("ms\n")
            append("# 说明： 这是完整日志。给模型的摘录只有 ")
            append(maxExcerptLines).append(" 行 —— 需要细节时读这个文件。\n\n")
        }
        return try {
            fs.writeText(name, header + capped)
            name
        } catch (e: Exception) {
            null
        }
    }
}
