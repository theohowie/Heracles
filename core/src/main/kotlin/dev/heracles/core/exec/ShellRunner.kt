package dev.heracles.core.exec

/**
 * 执行一条 shell 命令 —— `26-编码层工具链与逆向引擎.md` §4.1。
 *
 * ## 为什么是接口而不是直接实现
 *
 * 设备上的 shell 来自 Shizuku / Stellar（ADR-010 / ADR-016），那是 **Android 专有**的。
 * 而"跑一次构建流水线"的逻辑（`AndroidBuildEngine`）我们希望**在 PC 上测**。
 *
 * ⇒ 把副作用抽成接口：`:toolchain` 依赖本接口，Android 侧提供
 * [dev.heracles.core.exec.ShellRunner] 的实现（`ShizukuShellRunner`），
 * 测试侧提供假实现。这样构建编排的**步骤顺序**可以离线断言。
 *
 * ## 分层红线（`26` §3.2）
 *
 * - 本文件在 `:core`，**不得** `import android.*`（门禁 G1）
 * - `:core` **不得**依赖任何本项目模块（门禁 G2）
 * - 实现方**不得**自己 `new ProcessBuilder` 绕过 [CommandGuard]
 *   —— 放行点是唯一的（建议门禁 G11 强制）
 */
interface ShellRunner {

    /**
     * 执行。
     *
     * ★ **超时后必须真的 kill 进程**（含子进程），而不是只放弃等待。
     * 理由见 `实测-04-内存与热行为.md`：残留的 `aapt2` / `javac` / `dex2oat`
     * 会持续吃内存，把可用内存压到 0.5 GB 时代价是 **10× 变慢** ——
     * 也就是说"放弃等待"会让**后面的每一轮都变慢**，不只是这一次。
     *
     * ★ 返回**原始**输出，**不做**过滤（[dev.heracles.core.text.LogFilter] 负责过滤）。
     *
     * @param command 要执行的命令；调用方**必须**先经 [CommandGuard] 判定
     * @param timeoutSec 超时秒数；超时返回 [ShellResult.timedOut] = true
     * @param cwd 工作区**相对**路径；根目录传 null 或空串
     */
    suspend fun run(command: String, timeoutSec: Int, cwd: String? = null): ShellResult
}
