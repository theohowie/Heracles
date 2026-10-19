package dev.heracles.toolchain

import dev.heracles.core.contract.Contract
import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.file.Files
import java.nio.file.Path
// ⚠️ 用 Paths.get 而不是 Path.of —— 见 ToolchainPaths 顶部注释：
//    Android 上 Path.of 要 API 34，Paths.get 只要 API 26。
import java.nio.file.Paths
import java.util.concurrent.TimeUnit

/**
 * **本机进程版** [ShellRunner] —— `26-编码层工具链与逆向引擎.md` §4.1。
 *
 * ## 用在哪
 *
 * · `:cli` 与 PC 上的集成测试（真起进程，验证命令串是否真的能被 shell 解析）
 * · **不用于 Android 设备**：设备上 App 没有 shell 身份，
 *   必须走 `ShizukuShellRunner`（经 Shizuku 的 `newProcess`）
 *
 * ## 与 `AGENTS.md` 硬约束的关系（**必须说清楚，否则看起来像违规**）
 *
 * > 禁止 kill / force-stop 用户设备上的任何应用。
 *
 * 本类在超时后调用 `destroyForcibly()` —— 杀的是**我们自己刚起的子进程**，
 * 不是用户的应用。这两件事必须区分：
 *
 * | 行为 | 判定 |
 * |---|---|
 * | 超时后杀自己起的 `aapt2`/`javac` | ✅ **必须做**（残留会持续吃内存，见 `实测-04`） |
 * | 杀用户的 App / 系统进程 | ❌ 永久禁止 |
 *
 * ## 为什么把输出重定向到文件
 *
 * `Process` 的 stdout/stderr 管道有 64KB 缓冲。**不读就会被写满**，
 * 子进程随之阻塞 —— 表现为"命令永远不结束"，然后被超时误杀，
 * 排查方向会一路错到"是不是命令本身有问题"。
 *
 * ⇒ 直接 `redirectOutput` 到临时文件，等进程结束后一次性读回。
 */
class LocalProcessShellRunner(
    /** 临时目录；默认用系统临时目录 */
    private val tempDir: Path = Paths.get(System.getProperty("java.io.tmpdir")),
    /** 编码 —— 中文输出必须显式指定，否则 Windows 上会读出乱码 */
    private val charset: java.nio.charset.Charset = Charsets.UTF_8,
    /** 用哪个 shell 跑（Windows 上是 `sh`；没有则用 cmd） */
    private val shell: List<String> = defaultShell(),
    /**
     * 额外注入子进程的环境变量（覆盖同名继承值）。
     *
     * ## 为什么需要它（2026-10-16 真机验证时补上）
     *
     * 真机上要**故意造出"设备没有 `zip`"** 这个条件，才能验证脚本 `exit 10`
     * → 引擎进程内插 dex 那条分支。做法就是把子进程的 `PATH` 换成
     * "只含 JDK 的 bin"（实测设备上 `zip` 来自 Termux 的 `usr/bin`）。
     *
     * 与"命令串里写 `PATH=… sh …`"相比，走进程环境更干净：
     * 命令串不会被污染，也不依赖 shell 的赋值语法。
     *
     * 注意：**只覆盖列出的键**，其余环境（如 `LD_LIBRARY_PATH`，Termux 的
     * `aapt2`/`java` 都靠它）原样继承 —— 那正是我们要的。
     */
    private val env: Map<String, String> = emptyMap(),
) : ShellRunner {

    override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult =
        withContext(Dispatchers.IO) {
            val started = System.currentTimeMillis()
            val tag = "heracles-sh-" + started
            val outFile = tempDir.resolve("$tag.out")
            val errFile = tempDir.resolve("$tag.err")

            val pb = ProcessBuilder(shell + command)
            if (!cwd.isNullOrBlank()) pb.directory(Paths.get(cwd).toFile())
            if (env.isNotEmpty()) pb.environment().putAll(env)
            pb.redirectOutput(outFile.toFile())
            pb.redirectError(errFile.toFile())

            val process = try {
                pb.start()
            } catch (e: Exception) {
                return@withContext ShellResult(
                    exitCode = -2,
                    stdout = "",
                    stderr = "无法启动进程：${e.message}",
                    timedOut = false,
                    durationMs = System.currentTimeMillis() - started,
                )
            }

            val finished = process.waitFor(timeoutSec.toLong(), TimeUnit.SECONDS)
            val exit = if (finished) {
                process.exitValue()
            } else {
                // ★ 杀自己起的子进程（见类注释的边界表）——
                //   不杀会留下持续吃内存的 aapt2/javac，把后续每一轮都拖慢
                process.destroy()
                if (!process.waitFor(3, TimeUnit.SECONDS)) process.destroyForcibly()
                ShellResult.TIMEOUT_EXIT_CODE
            }

            val stdout = readCapped(outFile)
            val stderr = readCapped(errFile)
            runCatching { Files.deleteIfExists(outFile) }
            runCatching { Files.deleteIfExists(errFile) }

            ShellResult(
                exitCode = exit,
                stdout = stdout,
                stderr = stderr,
                timedOut = !finished,
                durationMs = System.currentTimeMillis() - started,
            )
        }

    /** 读回输出并夹到上限（`-v` 类输出能把磁盘/内存打满）。 */
    private fun readCapped(p: Path): String {
        if (!Files.exists(p)) return ""
        val size = Files.size(p)
        val text = String(Files.readAllBytes(p), charset)
        return if (size > Contract.Shell.MAX_CAPTURED_BYTES) {
            text.take(Contract.Shell.MAX_CAPTURED_BYTES) + "\n…（输出过大，已截断）"
        } else {
            text
        }
    }

    companion object {
        /**
         * 默认 shell。
         *
         * Windows 上用 Git 自带的 `sh`（若在 PATH 里），否则退回 `cmd /c`。
         * 本项目脚本全部按 POSIX sh 写，所以**优先 `sh`** ——
         * 用 `cmd` 跑会立刻失败，而这个失败是**响亮**的（好过静默走错）。
         */
        fun defaultShell(): List<String> {
            val os = System.getProperty("os.name").lowercase()
            return if (os.contains("win")) {
                if (which("sh") != null) listOf("sh", "-c") else listOf("cmd.exe", "/c")
            } else {
                listOf("/bin/sh", "-c")
            }
        }

        private fun which(cmd: String): String? {
            val path = System.getenv("PATH") ?: return null
            val exts = if (System.getProperty("os.name").lowercase().contains("win")) {
                listOf("", ".exe", ".bat", ".cmd")
            } else {
                listOf("")
            }
            return path.split(java.io.File.pathSeparator).asSequence()
                .mapNotNull { dir ->
                    exts.asSequence().map { dir + java.io.File.separator + cmd + it }.firstOrNull {
                        Files.isExecutable(Paths.get(it)) || Files.isRegularFile(Paths.get(it))
                    }
                }
                .firstOrNull()
        }
    }
}
