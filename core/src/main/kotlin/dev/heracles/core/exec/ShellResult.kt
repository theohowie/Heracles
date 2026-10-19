package dev.heracles.core.exec

/**
 * 一次 shell 执行的**原始**结果 —— `26-编码层工具链与逆向引擎.md` §4.1。
 *
 * ## 为什么这里是"原始"的
 *
 * 把原始输出变成"给模型看的文本"是 [dev.heracles.core.text.LogFilter] 的职责。
 * 分开的理由很实际：
 *
 * | 关注点 | 能否在 PC 上穷举测试 |
 * |---|---|
 * | 执行命令（起进程、超时、杀进程） | ❌ 需要真设备 |
 * | 过滤日志（正则、截断、合并） | ✅ 纯函数，毫秒级 |
 *
 * 混在一起就变成"要测过滤必须先能起进程" —— 那等于测不了。
 */
data class ShellResult(
    /** 进程退出码；超时被杀的见 [TIMEOUT_EXIT_CODE] */
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
    /** 是否因超时被中止（此时 [exitCode] 一定是 [TIMEOUT_EXIT_CODE]） */
    val timedOut: Boolean,
    val durationMs: Long,
    /**
     * 全量原始日志的**落盘路径**（工作区相对路径），可能为 null。
     *
     * 存在的意义：进上下文的只有**摘录**（[dev.heracles.core.contract.Contract.Shell.LOG_EXCERPT_LINES]
     * 行；S1b 之前分本地 40 / 云端 200 两档，分级已随 ADR-035 删除），
     * 但模型需要细节时可以自己去读这个文件 —— 比把几千行塞进上下文省 token，
     * 也避免违反铁律 1（append-only 一旦写进历史就永久占位）。
     */
    val logFile: String? = null,
) {
    val ok: Boolean get() = exitCode == 0

    /** 合并流，供过滤器使用。stderr 在后 —— 出错信息通常在那儿。 */
    fun combined(): String = when {
        stderr.isBlank() -> stdout
        stdout.isBlank() -> stderr
        else -> stdout + "\n" + stderr
    }

    companion object {
        /**
         * 超时被杀时的退出码。
         *
         * 取 -1 而不是 124（`timeout` 命令的约定）：我们不是 `timeout`，
         * 而且真机上进程被 SIGKILL 时 `waitFor()` 返回值**不可靠**
         * （可能拿到 137 也可能拿到别的），用统一的哨兵值更容易在
         * 日志与 UI 上认出"这是超时，不是程序自己的失败"。
         */
        const val TIMEOUT_EXIT_CODE = -1

        fun timeout(partialStdout: String, partialStderr: String, durationMs: Long, logFile: String? = null) =
            ShellResult(
                exitCode = TIMEOUT_EXIT_CODE,
                stdout = partialStdout,
                stderr = partialStderr,
                timedOut = true,
                durationMs = durationMs,
                logFile = logFile,
            )
    }
}
