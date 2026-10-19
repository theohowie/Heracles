package com.theohowie.heracles.bridge

import dev.heracles.core.contract.Contract
import dev.heracles.core.exec.ShellResult
import dev.heracles.core.exec.ShellRunner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * **设备侧** [ShellRunner] —— `26-编码层工具链与逆向引擎.md` §4.1。
 *
 * ## 为什么必须有它（而不是复用 [LocalProcessShellRunner]）
 *
 * App 自己**没有 shell 身份**：`ProcessBuilder("sh", …)` 在 Android 上
 * 会以 App 自己的 UID 跑，连 `/system/bin/ls` 都读不到别人的东西。
 * 真正的 shell（UID 2000）或 root（UID 0）只能经 **Stellar / Shizuku** 拿 ——
 * 这正是 [DeviceShellManager] 的职责。
 *
 * ⇒ 本类是「[ShellRunner] 接口」与「[DeviceShellManager] 双管理器路由」的桥。
 *
 * ## 三条实现要点（每一条都对应一个曾经踩过的坑）
 *
 * ### ① 超时用「等锁 + 主动 destroy」，不用 `waitFor(timeout)`
 *
 * Stellar 给的是 `StellarRemoteProcess`，Shizuku 给的是 `IShizukuRemoteProcess`
 * —— 两者的 `waitFor` 重载**不保证一致**（一个是 `Process` 子类，一个是 AIDL）。
 * 依赖某个重载存在 = 编译期或运行期二选一的坑。
 *
 * ⇒ 把 `waitFor()` 丢进单独线程，主线程用 [CountDownLatch] 等；
 * 超时就 `destroy()`。**杀的是我们自己起的子进程**（`AGENTS.md` 的禁令
 * 针对的是用户设备上的别人的 App，不是我们的构建进程）。
 *
 * ### ② 两个流必须**并发**读
 *
 * 先读完 stdout 再读 stderr 会**死锁**：stderr 的缓冲被写满后子进程阻塞在
 * 写 stderr 上，而我们在等 stdout 结束。`javac` 输出量大时必现。
 *
 * ⇒ 两个读线程，各自读到底，最后 `join`。
 *
 * ### ③ 输出夹到 [Contract.Shell.MAX_CAPTURED_BYTES]
 *
 * `aapt2` 出错时能把同一段错误刷几十遍。不夹上限会把内存和 Context 一起打爆
 * （`实测-04`：内存被压到 0.5 GB 时代价是 10× 变慢）。
 *
 * ## ⚠️ 未在真机验证
 *
 * 本文件写于 2026-10-16，**尚未在真机上跑通**（当次会话无设备）。
 * 已通过 `:android-probe:compileDebugKotlin`（Android 目标编译）。
 * 首次真机使用请先跑 `run_shell_command("echo hello")` 与
 * `run_shell_command("ls -l")` 两条最小用例。
 */
class DeviceShellRunner(
    /**
     * 把**工作区相对路径**解析成设备绝对路径。
     *
     * 由 App 侧注入（它知道工作区根在哪）。`null` 或解析失败 ⇒ 不 `cd`，
     * 命令在工作区根以外执行 —— 此时调用方应当已经拦住了
     * （`RunShellCommandTool` 会用 `PathGuard` 先校验）。
     */
    private val resolveCwd: (String) -> String? = { null },
) : ShellRunner {

    override suspend fun run(command: String, timeoutSec: Int, cwd: String?): ShellResult =
        withContext(Dispatchers.IO) {
            val started = System.currentTimeMillis()

            val route = DeviceShellManager.currentRoute()
            if (route == DeviceShellManager.Route.NONE) {
                return@withContext ShellResult(
                    exitCode = EXIT_NO_SHELL,
                    stdout = "",
                    stderr = "未检测到 Stellar 或 Shizuku 服务 —— 请先在其中一个管理器里启动服务" +
                        "（设备权限页可查看状态）。",
                    timedOut = false,
                    durationMs = System.currentTimeMillis() - started,
                )
            }

            // cd 与命令合成一条：远程进程没有"工作目录"参数
            //
            // ⚠️ 这里**不做**任何权限处理：让 App 读得到 shell 的产出是**引擎**的活
            //（`appReadable()`，见 `实测-12` §13）。原因：外置存储的 FUSE 在**创建时**
            // 就把 mode 定死成 0660，`umask` 改不了它；把产物 chmod 放开才是唯一有效的手段，
            // 而"哪些产物需要放开"只有引擎知道（不该为此让每条 shell 命令都去递归 chmod）。
            val full = if (cwd.isNullOrBlank()) {
                command
            } else {
                val abs = resolveCwd(cwd)
                if (abs == null) command else "cd ${sq(abs)} && $command"
            }

            val proc = try {
                launch(route, full)
            } catch (e: Throwable) {
                return@withContext ShellResult(
                    exitCode = EXIT_NO_SHELL,
                    stdout = "",
                    stderr = "无法启动远程进程（${route.label}）：${e.message}",
                    timedOut = false,
                    durationMs = System.currentTimeMillis() - started,
                )
            }

            // ---- 并发读两个流（见类注释 ②）----
            val outBuf = StringBuilder()
            val errBuf = StringBuilder()
            val t1 = Reader(proc.stdout, outBuf, "heracles-sh-out").also { it.start() }
            val t2 = Reader(proc.stderr, errBuf, "heracles-sh-err").also { it.start() }

            // ---- 等退出（见类注释 ①）----
            val done = CountDownLatch(1)
            var exit = -1
            val waiter = Thread({
                exit = runCatching { proc.waitFor() }.getOrDefault(-1)
                done.countDown()
            }, "heracles-sh-wait").apply { isDaemon = true; start() }

            val finished = done.await(timeoutSec.toLong().coerceAtLeast(1), TimeUnit.SECONDS)
            if (!finished) {
                runCatching { proc.destroy() }
                // 给 destroy 一点时间落地，再把读者线程收掉
                done.await(3, TimeUnit.SECONDS)
            }
            t1.join(2_000)
            t2.join(2_000)

            ShellResult(
                exitCode = if (finished) exit else ShellResult.TIMEOUT_EXIT_CODE,
                stdout = cap(outBuf.toString()),
                stderr = cap(errBuf.toString()),
                timedOut = !finished,
                durationMs = System.currentTimeMillis() - started,
            )
        }

    // ------------------------------------------------------------------ 内部

    /** 远程进程的最小抽象 —— 两个管理器的流类型不同，收敛到这里。 */
    private interface RemoteProc {
        val stdout: InputStream
        val stderr: InputStream
        fun waitFor(): Int
        fun destroy()
    }

    private fun launch(route: DeviceShellManager.Route, command: String): RemoteProc =
        when (route) {
            DeviceShellManager.Route.STELLAR -> StellarProc(command)
            DeviceShellManager.Route.SHIZUKU -> ShizukuProc(command)
            DeviceShellManager.Route.NONE -> error("无可用路由")
        }

    /** Stellar：流是普通 `InputStream`。 */
    private class StellarProc(command: String) : RemoteProc {
        private val p = roro.stellar.Stellar.newProcess(arrayOf("sh", "-c", command), null, null)
        override val stdout: InputStream get() = p.inputStream
        override val stderr: InputStream get() = p.errorStream
        override fun waitFor(): Int = p.waitFor()
        override fun destroy() {
            runCatching { p.destroy() }
        }
    }

    /** Shizuku：流是 `ParcelFileDescriptor`，必须包一层。 */
    private class ShizukuProc(command: String) : RemoteProc {
        private val p = run {
            val binder = rikka.shizuku.Shizuku.getBinder()
                ?: throw IllegalStateException("Shizuku binder 不可用")
            val wrapped = rikka.shizuku.ShizukuBinderWrapper(binder)
            val svc = moe.shizuku.server.IShizukuService.Stub.asInterface(wrapped)
            svc.newProcess(arrayOf("sh", "-c", command), null, null)
        }
        override val stdout: InputStream
            get() = android.os.ParcelFileDescriptor.AutoCloseInputStream(p.inputStream)
        override val stderr: InputStream
            get() = android.os.ParcelFileDescriptor.AutoCloseInputStream(p.errorStream)
        override fun waitFor(): Int = p.waitFor()
        override fun destroy() {
            runCatching { p.destroy() }
        }
    }

    /** 读到 EOF 为止（不设长度上限，最后统一 [cap]）。 */
    private class Reader(
        private val input: InputStream,
        private val sink: StringBuilder,
        name: String,
    ) : Thread(name) {
        init {
            isDaemon = true
        }

        override fun run() {
            try {
                input.bufferedReader().use { r ->
                    val buf = CharArray(8 * 1024)
                    while (true) {
                        val n = r.read(buf)
                        if (n < 0) break
                        if (sink.length < Contract.Shell.MAX_CAPTURED_BYTES) {
                            sink.appendRange(buf, 0, n)
                        }
                    }
                }
            } catch (e: Throwable) {
                // 进程被 destroy 时读会抛 —— 这不是错误，不要污染输出
            }
        }
    }

    private fun cap(text: String): String =
        if (text.length > Contract.Shell.MAX_CAPTURED_BYTES) {
            text.take(Contract.Shell.MAX_CAPTURED_BYTES) + "\n…（输出过大，已截断）"
        } else {
            text
        }

    /** 单引号包裹（命令里出现单引号时用最朴素的转义）。 */
    private fun sq(s: String): String = "'" + s.replace("'", "'\\''") + "'"

    companion object {
        /** 没有可用的 shell 通道（与超时区分开）。 */
        const val EXIT_NO_SHELL = -2
    }
}
