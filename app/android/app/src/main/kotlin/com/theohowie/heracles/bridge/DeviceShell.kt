package com.theohowie.heracles.bridge

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * **设备侧命令执行**（2026-10-22）—— `heracles/device` 通道里 `exec.run` 的实现。
 *
 * 本文件是原 `DeviceShellRunner` 的**独立化改造**：逻辑照搬，但
 * **不再依赖 `dev.heracles.core.exec`**（那个模块已被删除，后端改 Dart 重写）。
 * 原来由 `:core` 提供的 `ShellResult` / `ShellRunner` / `Contract.Shell.MAX_CAPTURED_BYTES`
 * 现在都在本文件里自有定义 —— 契约形状改成通道要的
 * `{ok, code, stdout, stderr, timedOut}`。
 *
 * ## 为什么 App 需要它（不能直接 `ProcessBuilder`）
 *
 * App 自己**没有 shell 身份**：`ProcessBuilder("sh", …)` 在 Android 上以 App 自己的
 * UID 跑，连别人的东西都读不到。真正的 shell（UID 2000）或 root（UID 0）只能经
 * **Stellar / Shizuku** 拿 —— 那是 [DeviceShellManager] 的职责。
 *
 * ## 三条实现要点（每条都对应一个踩过的坑）
 *
 * ### ① 超时用「等锁 + 主动 destroy」，不用 `waitFor(timeout)`
 *
 * Stellar 给的是 `StellarRemoteProcess`，Shizuku 给的是 `IShizukuRemoteProcess`
 * —— 两者的 `waitFor` 重载**不保证一致**（一个是 `Process` 子类，一个是 AIDL）。
 * 依赖某个重载 = 编译期或运行期二选一的坑。
 * ⇒ 把 `waitFor()` 丢进单独线程，主线程用 [CountDownLatch] 等；超时就 `destroy()`。
 *
 * ### ② 两个流必须**并发**读
 *
 * 先读完 stdout 再读 stderr 会**死锁**：stderr 缓冲写满后子进程阻塞在写 stderr 上，
 * 而我们在等 stdout 结束。`javac` 输出量大时必现。
 *
 * ### ③ 输出各夹到 [MAX_CAPTURED_BYTES]（1MB），超了置 `truncated`
 *
 * `aapt2` 出错时能把同一段错误刷几十遍。不夹上限会把内存打爆。
 *
 * ## ⚠️ 只 kill **自己起的进程**（`AGENTS.md` 硬约束）
 *
 * 设备是用户的。本文件里唯一的 kill 是 [RemoteProc.destroy]，作用对象是
 * **本次 `exec.run` 刚起的那个子进程**（超时清理）。**绝不** `am force-stop` /
 * `kill -9` 任何用户 App，也不 `kill` 别人的 PID。
 */
class DeviceShell {
    companion object {
        /**
         * stdout / stderr **各自**的上限：1MB。
         *
         * 与老的 `Contract.Shell.MAX_CAPTURED_BYTES`（8MB）不同 —— 那个是
         * "全量日志落盘"的上限；通道里回给 Dart 的是**进模型上下文**的东西，
         * 1MB 已经远超任何合理预算（约 25 万 token）。
         */
        const val MAX_CAPTURED_BYTES: Int = 1 * 1024 * 1024

        /** 没有可用的 shell 通道时的退出码（与超时、与真实 exit code 都区分开）。 */
        const val EXIT_NO_SHELL: Int = -2

        /** 默认超时：120 s（与老 `Contract.Shell.DEFAULT_TIMEOUT_SEC` 一致）。 */
        const val DEFAULT_TIMEOUT_MS: Long = 120_000

        /** 允许的**最大**超时：15 min。模型可以要更长时间，但必须有上限。 */
        const val MAX_TIMEOUT_MS: Long = 15 * 60_000
    }

    /**
     * 执行一条命令。
     *
     * @param cmd 整条命令（会以 `sh -c <cmd>` 执行，因此支持管道 / 重定向）
     * @param cwd **绝对路径**的工作目录；null / 空 = 不 `cd`。
     *            远程进程没有"工作目录"参数，所以 `cd` 与命令拼成一条。
     * @param timeoutMs 超时（毫秒）；`<= 0` 用 [DEFAULT_TIMEOUT_MS]，上限 [MAX_TIMEOUT_MS]
     * @return `{ok, code, stdout, stderr, timedOut, truncated?}` ——
     *         `ok` 恒等于 `code == 0 && !timedOut`；**任何失败都不抛**，用 `error` 说明
     */
    suspend fun run(cmd: String, cwd: String?, timeoutMs: Long): Map<String, Any?> =
        withContext(Dispatchers.IO) {
            val started = System.currentTimeMillis()
            val budget = when {
                timeoutMs <= 0 -> DEFAULT_TIMEOUT_MS
                timeoutMs > MAX_TIMEOUT_MS -> MAX_TIMEOUT_MS
                else -> timeoutMs
            }

            val route = runCatching { DeviceShellManager.currentRoute() }
                .getOrDefault(DeviceShellManager.Route.NONE)
            if (route == DeviceShellManager.Route.NONE) {
                return@withContext result(
                    code = EXIT_NO_SHELL,
                    stdout = "",
                    stderr = "未检测到 Stellar 或 Shizuku 服务 —— " +
                        "请先在其中一个管理器里启动服务（设备权限页可查看状态）。",
                    timedOut = false,
                )
            }

            // ★ 2026-10-22 真机实测修：**shell 创建的文件 App 读不了（EACCES）**
            //
            // ## 现场
            //
            // 模型用 `run_shell_command` 写 `a.txt` / `b.txt` 成功，
            // 紧接着用 `read_file` 读同一批文件 ⇒ **EACCES**。
            // 模型自己都发现了："通过 shell 的 cat 校验内容正常，
            // 应该是工具层的权限问题"。
            //
            // ## 根因
            //
            // 远程进程（Shizuku/Stellar）以 **shell 身份**跑，它创建的
            // 文件属 shell 的 umask（通常 0022 ⇒ 0644/0755 还行，
            // 但外层应用或 provider 的 umask 可能是 0007/0077 ⇒ 0660/0700），
            // 而 App 是**另一个 UID** ⇒ 外置存储（FUSE）只看 mode 位、
            // 不看附加组 ⇒ 直接 EACCES。
            //
            // ## 修法
            //
            // 在**每条命令前**加 `umask 0000`：让 shell 写出的文件是
            // 0666、目录是 0777 —— 同机上的 App 就能读。
            // 这是「让 agent 自己写的文件自己读得回来」的最低成本修法；
            // 更彻底的做法是产出后统一 `chmod -R a+rwX`，但那要再扫一遍目录树。
            //
            // ⚠️ 安全性说明：这些路径都在**用户自己的工作区**里，
            //    放宽的是本项目产物的权限，不涉及系统目录。
            val full = buildString {
                append("umask 0000; ")
                if (!cwd.isNullOrBlank()) append("cd ${sq(cwd)} && ")
                append(cmd)
            }

            val proc = try {
                launch(route, full)
            } catch (e: Throwable) {
                return@withContext result(
                    code = EXIT_NO_SHELL,
                    stdout = "",
                    stderr = "无法启动远程进程（${route.label}）：" +
                        "${e.javaClass.simpleName}: ${e.message}",
                    timedOut = false,
                )
            }

            // ---- 并发读两个流（见类注释 ②）----
            val outBuf = StringBuilder()
            val errBuf = StringBuilder()
            val outCut = java.util.concurrent.atomic.AtomicBoolean(false)
            val errCut = java.util.concurrent.atomic.AtomicBoolean(false)
            val t1 = Reader(proc.stdout, outBuf, outCut, "heracles-sh-out").also { it.start() }
            val t2 = Reader(proc.stderr, errBuf, errCut, "heracles-sh-err").also { it.start() }

            // ---- 等退出（见类注释 ①）----
            val done = CountDownLatch(1)
            var exit = -1
            Thread({
                exit = runCatching { proc.waitFor() }.getOrDefault(-1)
                done.countDown()
            }, "heracles-sh-wait").apply { isDaemon = true; start() }

            val finished = done.await(budget.coerceAtLeast(1), TimeUnit.MILLISECONDS)
            if (!finished) {
                // ★ 这里杀的是**我们自己刚起的那个子进程**，不是用户设备上的应用
                runCatching { proc.destroy() }
                done.await(3, TimeUnit.SECONDS)
            }
            t1.join(2_000)
            t2.join(2_000)

            val outTrunc = outCut.get()
            val errTrunc = errCut.get()
            val m = result(
                code = if (finished) exit else EXIT_NO_SHELL,
                stdout = cap(outBuf.toString()),
                stderr = cap(errBuf.toString()),
                timedOut = !finished,
            ).toMutableMap()

            // 超时的 `code` 如实为 -1（"没有退出码"）—— 不要伪装成 124 之类的 shell 约定
            if (!finished) m["code"] = -1
            m["durationMs"] = System.currentTimeMillis() - started

            // ★ 2026-10-22 真机实测修：**让 App 读得回 shell 写的文件** ★
            //
            // ## 现场（`.jsonl` 原始 bytes）
            //
            // ```
            // run_shell_command: echo "hello" > c.txt   → 成功，ls -l 显示 -rw-rw---- shell ext_data_rw
            // read_file c.txt  → EACCES (Permission denied)
            // ```
            //
            // ## 为什么前面的 `umask 0000` 没用
            //
            // **外置存储（FUSE）不看 umask** —— 它按挂载参数强制 fmask/dmask，
            // 建出来的文件恒为 0660、目录 0770（`实测-03` 坑 13 早就记过这点，
            // 本轮又踩了一次，且用实测再次确认：加了 umask 之后**仍是 0660**）。
            //
            // ## 所以只能显式 chmod
            //
            // 坑 13 的三条对策里，②就是"shell 产出统一 `chmod -R a+rwX`"。
            // 放在每条命令**成功之后**做，且：
            // · 只对 `cwd`（工作区根）做，不碰系统目录
            // · **best-effort**：chmod 失败不影响命令本身的成败（不能因为
            //   "权限没修好"就把一条成功的命令报成失败）
            // · 5 秒上限：大项目上别把一次 `ls` 拖成十秒
            if (finished && exit == 0 && !cwd.isNullOrBlank()) {
                // 注意：`launch()` 返回的是本类的 `RemoteProc`（stdout/stderr/waitFor/destroy），
                // **不是** `java.lang.Process` —— 所以关流走 `stdout.close()`。
                val fix: RemoteProc? = runCatching {
                    launch(route, "chmod -R a+rwX ${sq(cwd)} 2>/dev/null; true")
                }.getOrNull()
                if (fix != null) {
                    runCatching {
                        val done = CountDownLatch(1)
                        Thread({
                            runCatching { fix.waitFor() }
                            done.countDown()
                        }, "heracles-chmod").apply { isDaemon = true; start() }
                        if (!done.await(5, TimeUnit.SECONDS)) {
                            runCatching { fix.destroy() }
                        }
                        runCatching { fix.stdout.close() }
                        runCatching { fix.stderr.close() }
                    }
                }
            }

            if (!finished) {
                m["error"] = "命令超时（${budget} ms），已终止该子进程"
            } else if (outTrunc || errTrunc) {
                m["truncated"] = true
                m["truncatedNote"] =
                    "输出超过 ${MAX_CAPTURED_BYTES}B 上限，已截断（stdout=${outTrunc}，" +
                        "stderr=${errTrunc}）"
            }
            m
        }

    // ------------------------------------------------------------------ 形状

    /** 统一返回形状。`ok` 是**派生值**，不单独传 —— 避免两处真相打架。 */
    private fun result(
        code: Int,
        stdout: String,
        stderr: String,
        timedOut: Boolean,
    ): Map<String, Any?> = mapOf(
        "ok" to (code == 0 && !timedOut),
        "code" to code,
        "stdout" to stdout,
        "stderr" to stderr,
        "timedOut" to timedOut,
    )

    // ------------------------------------------------------------------ 进程

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

    /**
     * 读到 EOF 为止，**但到上限就停**（不是读完再切）。
     *
     * 为什么到上限就停：`aapt2 -v` 的输出可以是几百 MB，读完再截
     * 等于把内存先打爆一次。停掉之后 `cut` 置 true，调用方据此置 `truncated`。
     */
    private class Reader(
        private val input: InputStream,
        private val sink: StringBuilder,
        private val cut: java.util.concurrent.atomic.AtomicBoolean,
        name: String,
    ) : Thread(name) {
        init {
            isDaemon = true
        }

        override fun run() {
            try {
                val r = input.bufferedReader()
                val buf = CharArray(8 * 1024)
                while (true) {
                    val n = r.read(buf)
                    if (n < 0) break
                    if (sink.length >= MAX_CAPTURED_BYTES) {
                        cut.set(true)
                        // 不再累积，但要继续把流读空 —— 否则子进程会因写满管道而卡住
                        continue
                    }
                    val room = MAX_CAPTURED_BYTES - sink.length
                    val take = if (n <= room) n else room
                    sink.appendRange(buf, 0, take)
                    if (take < n) cut.set(true)
                }
            } catch (_: Throwable) {
                // 进程被 destroy 时读会抛 —— 这不是错误，不要污染输出
            }
        }
    }

    /** 兜底夹一次（Reader 已限长，这里防的是"字符串本身超了"的边界）。 */
    private fun cap(text: String): String =
        if (text.length > MAX_CAPTURED_BYTES) {
            text.substring(0, MAX_CAPTURED_BYTES) + "\n…（输出过大，已截断）"
        } else {
            text
        }

    /** 单引号包裹（命令里出现单引号时用最朴素的转义）。 */
    private fun sq(s: String): String = "'" + s.replace("'", "'\\''") + "'"
}
