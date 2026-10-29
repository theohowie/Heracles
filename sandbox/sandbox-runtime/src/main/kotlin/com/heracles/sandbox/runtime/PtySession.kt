/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * This file is part of Heracles-taixu-sandbox.
 *
 * Heracles-taixu-sandbox is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Heracles-taixu-sandbox is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Heracles-taixu-sandbox.  If not, see <https://www.gnu.org/licenses/>.
 *
 * 移植来源: taixu dc7fcddb88e565929379597bbd811b440d00e34f
 *           runtime/src/main/java/top/wkbin/taixu/runtime/pty/NativePty.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/pty/NativePtyBackend.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/pty/NativePtySession.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/pty/PtyManager.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/pty/IncrementalUtf8Decoder.kt
 *
 * ============================================================================
 * 上游 5 个文件 -> 本文件 2 个类
 * ============================================================================
 *   上游 NativePty                    -> [PtySession] 的 companion（external fun）
 *   上游 NativePtyBackend/JniBackend  -> 直接内联进 [PtySession]（只有一条后端，
 *                                        上那层 interface 是为 Script 回退准备的）
 *   上游 NativePtySession             -> [PtySession]
 *   上游 NativePtyChild（信号/回收锁） -> [PtySession.child]（ChildState）
 *   上游 IncrementalUtf8Decoder       -> [IncrementalUtf8Decoder]
 *   上游 PtyManager/ScriptPtyManager  -> **不移植**（见删减说明 1）
 *
 * ============================================================================
 * 删减说明（对照上游逐条）
 * ============================================================================
 * 1. **不移植 `ScriptPtyManager`（Debian `script -qfec` 回退后端）。**
 *    上游需要它是因为老设备可能加载不到 JNI 库。本沙箱 ABI 定死 arm64-v8a 且
 *    .so 随 AAR 一起打包（见 build.gradle.kts 的 abiFilters），加载失败属于
 *    **打包错误**而非运行时环境差异；静默回退到 `script` 会让 PTY 语义
 *    （SIGWINCH / Ctrl+C / raw mode）悄悄降级且不报错，比直接失败更糟。
 *    ⇒ 加载失败时 [nativeAvailable] 为 false，调用方拿到明确错误码。
 * 2. **不移植 `LinuxSession` 接口。** 沙箱侧只有 [PtySession] 一个实现，
 *    抽接口没有第二个实现者。
 * 3. **输出改成 suspend 回调，不是 Flow。** 上游是
 *    `output: Flow<TerminalOutput>`；沙箱的执行是「一次调用 + IExecutionCallback
 *    直连」，用 suspend 回调（[PtyOutputListener]）能保证**顺序投递且不丢**，
 *    也不需为每次执行多起一个收集协程。只有单消费者时 Flow 中间层是纯开销。
 * 4. **新增退出码解码。** 上游 `pollExit` 只返回 boolean，把退出码丢了；
 *    而 `ExecutionResult.exitCode` 是 AIDL 契约的一部分。JNI 侧改成返回原始
 *    wait status（见 pty_bridge.cpp 的 nativeWaitNoHang），本文件负责解码。
 * 5. **新增超时与取消。** [PtySession.awaitExit] 支持 timeoutMillis，超时或
 *    取消后向**进程组** SIGTERM → 宽限 → SIGKILL，结果里区分 timedOut/cancelled。
 * 6. **新增一次性 stdin 喂入**（[PtySession.writeText]），供
 *    `ExecutionRequest.inputData` 使用。
 * 7. **不移植 `closeRuntimeResources` / `ExecutionEnvironmentContext` 注册。**
 *    那是 taixu 的运行时资源账本；沙箱的账本在 [ProcessRegistry]。
 * 8. **Stream 枚举保留但 PTY 只报 STDOUT。** 真 TTY 只有一根流（子进程自己不会
 *    区分），这是 TTY 的语义而不是简化的结果。`ExecutionResult.stderr` 由
 *    exec 管道路径（[ProotEngine]）负责填充。
 *
 * ============================================================================
 * ★ JNI 绑定
 * ============================================================================
 * pty_bridge.cpp 走 `JNI_OnLoad + RegisterNatives`，注册目标是
 *   com/heracles/sandbox/runtime/PtySession$Companion
 * 因此下面 companion 里的 7 个 `external fun` **签名必须与 cpp 的 kMethods
 * 表逐字一致**。改签名必须同步改 cpp，否则 loadLibrary 就抛
 * UnsatisfiedLinkError（刻意的：把问题挡在加载期而不是第一次调用时）。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.SandboxException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** PTY 输出流标识。真 TTY 只有一根流，见文件头删减说明 8。 */
enum class PtyStream { STDOUT, STDERR }

/** 一段 PTY 输出。 */
data class PtyOutput(val stream: PtyStream, val text: String)

/** PTY 输出回调。实现方**不得阻塞**（由读循环顺序调用）。 */
fun interface PtyOutputListener {
    suspend fun onOutput(output: PtyOutput)
}

/**
 * 一次 PTY 会话的结束状态。
 *
 * @param exitCode     子进程退出码；被信号杀死时为 128+signal（shell 惯例）
 * @param signal       退出信号号；0 表示正常退出
 * @param durationMillis 从 open 到回收的墙钟时长
 */
data class PtyExit(
    val exitCode: Int,
    val signal: Int,
    val durationMillis: Long,
    val timedOut: Boolean,
    val cancelled: Boolean,
) {
    val isSuccess: Boolean get() = exitCode == 0 && !timedOut && !cancelled
}

/**
 * 真 PTY 会话（openpty + fork + setsid + TIOCSCTTY + execve）。
 *
 * 典型用法：
 * ```
 *   PtySession.open(argv, env, cwd, cols, rows).use { pty ->
 *       pty.startPumping(listener)
 *       pty.awaitExit(timeoutMillis, cancelSignal)
 *   }
 * ```
 *
 * 关键不变量：**任何一次 JNI 调用都是有界的**（见 pty_bridge.cpp 线程模型），
 * 所以取消、关闭、超时都只是「停止轮询 + 发信号」，不会卡住调用线程。
 *
 * 本类**不可重复启动**读循环；会话用完后必须 [close]（幂等）。
 */
class PtySession private constructor(
    private val masterFd: Int,
    private val childPid: Int,
    private val scope: CoroutineScope,
) {

    private val closing = java.util.concurrent.atomic.AtomicBoolean(false)
    private val closeMutex = Mutex()
    private val inputMutex = Mutex()

    /** 子进程状态机：保证「回收」与「发信号」互斥，避免 pid 复用后误杀。 */
    private val child = ChildState()

    /** 解码器只在读循环里用（串行访问，无需加锁）。 */
    private val decoder = IncrementalUtf8Decoder(READ_BUFFER_BYTES)

    private var fdReleased = false
    private var pumpJob: Job? = null

    private val startedAtNanos = System.nanoTime()

    /** 会话是否还活着（非阻塞探测；不会把它回收掉导致后面拿不到退出码）。 */
    val isAlive: Boolean get() = child.isAlive

    /** fork 出的子进程 pid；-1 表示 fd 已释放。 */
    val pid: Int get() = if (fdReleased) -1 else childPid

    /**
     * 启动读循环：反复从 master 读、增量解码、把文本交给 [listener]。
     *
     * 循环在 nativeRead 返回 -1（EOF）时结束。EOF 早于子进程退出是正常现象
     * （slave 被关掉但子进程还没 wait 完）—— 因此这里**不**回收子进程，
     * 回收归 [awaitExit] 负责，否则退出码就丢了。
     */
    fun startPumping(listener: PtyOutputListener): PtySession {
        check(pumpJob == null) { "读循环已启动；PtySession 不可重复启动" }
        pumpJob = scope.launch {
            val buffer = ByteArray(READ_BUFFER_BYTES)
            try {
                while (!closing.get() && currentCoroutineContext().isActive) {
                    val read = try {
                        nativeRead(masterFd, buffer)
                    } catch (failure: IOException) {
                        // 并发 close 掉 master 时的 EIO/EBADF 是预期路径，按 EOF 处理。
                        break
                    }
                    if (read < 0) break
                    if (read > 0) {
                        val text = decoder.decode(buffer, read)
                        if (text.isNotEmpty()) {
                            listener.onOutput(PtyOutput(PtyStream.STDOUT, text))
                        }
                    } else {
                        // 100ms 内没数据：让出线程，别把 IO 线程占满。
                        delay(1)
                    }
                }
                // 收尾：冲出解码器里残留的不完整多字节序列（非法序列已 REPLACE）。
                if (readFinishedNormally()) {
                    val tail = decoder.finish()
                    if (tail.isNotEmpty()) {
                        listener.onOutput(PtyOutput(PtyStream.STDOUT, tail))
                    }
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            }
        }
        return this
    }

    /** 读循环是自然读到 EOF 结束的（而不是被 close/取消打断）。 */
    private fun readFinishedNormally(): Boolean = !closing.get()

    /**
     * 等待子进程结束。
     *
     * @param timeoutMillis <= 0 表示不超时
     * @param cancelSignal  每轮轮询检查一次；返回 true 即取消
     */
    suspend fun awaitExit(
        timeoutMillis: Long = 0L,
        cancelSignal: () -> Boolean = { false },
    ): PtyExit = withContext(Dispatchers.IO) {
        val deadline =
            if (timeoutMillis > 0) System.nanoTime() + timeoutMillis * MILLIS_TO_NANOS else Long.MAX_VALUE
        var timedOut = false
        var cancelled = false

        while (true) {
            val status = child.pollStatus()
            if (status != PTY_RUNNING) {
                return@withContext buildExit(status, timedOut, cancelled)
            }
            if (cancelSignal()) {
                cancelled = true
                terminate(CANCEL_GRACE_MILLIS)
                continue
            }
            if (System.nanoTime() >= deadline) {
                timedOut = true
                terminate(TIMEOUT_GRACE_MILLIS)
                continue
            }
            delay(POLL_INTERVAL_MILLIS)
        }
        @Suppress("UNREACHABLE_CODE")
        error("unreachable")
    }

    /**
     * 向**整个进程组**发 SIGTERM；宽限期内没退出则 SIGKILL。
     *
     * 注意 `terminate` 里每轮都会先走 `child.isAlive`（内部会 reap），所以
     * 一旦子进程已退出就绝不会再发信号 —— pid 可能已经被复用了。
     */
    private suspend fun terminate(graceMillis: Long) {
        if (!child.signal(SIGTERM)) return
        val exited = withTimeoutOrNull(graceMillis) {
            while (child.isAlive) delay(POLL_INTERVAL_MILLIS)
            true
        } ?: false
        if (!exited) {
            child.signal(SIGKILL)
            // SIGKILL 后给内核一点时间把进程摘干净，避免 close 后仍有 tracee 在动。
            withTimeoutOrNull(KILL_GRACE_MILLIS) {
                while (child.isAlive) delay(POLL_INTERVAL_MILLIS)
            }
        }
    }

    /** 把原始 wait status 解码成 [PtyExit]。 */
    private fun buildExit(status: Int, timedOut: Boolean, cancelled: Boolean): PtyExit {
        val duration = (System.nanoTime() - startedAtNanos) / MILLIS_TO_NANOS
        if (status == PTY_ERROR) {
            // 无法判定（多半已被外部回收过）：按失败处理，但保留可诊断的退出码。
            return PtyExit(
                exitCode = EXIT_UNKNOWN,
                signal = 0,
                durationMillis = duration,
                timedOut = timedOut,
                cancelled = cancelled,
            )
        }
        // 原始 wait status：低 7 位是终止信号，高字节是正常退出码。
        val termSignal = status and 0x7f
        val exitedNormally = termSignal == 0
        val exitCode = if (exitedNormally) (status shr 8) and 0xff else 128 + termSignal
        return PtyExit(exitCode, if (exitedNormally) 0 else termSignal, duration, timedOut, cancelled)
    }

    /**
     * 写入数据（键盘输入 / stdin 喂入）。按已写入字节数循环直到写完或失败。
     */
    suspend fun write(data: ByteArray) = withContext(Dispatchers.IO) {
        inputMutex.withLock {
            var offset = 0
            while (!closing.get() && offset < data.size) {
                currentCoroutineContext().ensureActive()
                val written = nativeWrite(masterFd, data, offset, data.size - offset)
                if (written < 0) throw IOException("PTY 写入失败（fd 可能已关闭）")
                offset += written
                // written == 0 表示内核缓冲满：让出后重试，不忙等。
                if (written == 0) delay(WRITE_RETRY_MILLIS)
            }
        }
    }

    /** 写入一段 UTF-8 文本。 */
    suspend fun writeText(text: String) = write(text.toByteArray(Charsets.UTF_8))

    /** 调整窗口尺寸（TIOCSWINSZ ⇒ 内核向前台进程组发 SIGWINCH）。 */
    suspend fun resize(columns: Int, rows: Int) = withContext(Dispatchers.IO) {
        inputMutex.withLock {
            if (closing.get()) return@withLock
            val cols = columns.coerceIn(20, 400)
            val rws = rows.coerceIn(5, 200)
            if (nativeResize(masterFd, cols, rws) != 0) {
                throw IOException("PTY resize 失败（cols=$cols rows=$rws）")
            }
        }
    }

    /** 发送 Ctrl+C（0x03）—— 真 TTY 下由行规程转成 SIGINT 发给前台进程组。 */
    suspend fun interrupt() = write(byteArrayOf(0x03))

    /**
     * 关闭会话。幂等。
     *
     * 顺序刻意固定：先停读循环 → 再停子进程 → 最后关 fd。
     * 反过来会在读循环还阻塞在 read 时把 fd 关掉（fd 被复用时就读到别人的数据）。
     */
    suspend fun close() = withContext(NonCancellable + Dispatchers.IO) {
        closeMutex.withLock {
            if (closing.get() && fdReleased) return@withLock
            closing.set(true)

            // 1) 停读循环
            pumpJob?.cancel()
            runCatching { pumpJob?.join() }

            // 2) 停子进程（SIGTERM → 宽限 → SIGKILL）
            runCatching { terminate(CLOSE_GRACE_MILLIS) }

            // 3) 关 fd（只关一次）
            if (!fdReleased) {
                runCatching { nativeCloseFd(masterFd) }
                fdReleased = true
            }

            // 4) 收掉本会话的读出协程
            scope.coroutineContext.cancelChildren()
        }
    }

    /**
     * 子进程状态机。
     *
     * 为什么必须有：`waitpid` 一旦成功回收了 pid，内核就可能把它复用给别的
     * 进程；此时再 `kill(-pid, …)` 会杀掉无关进程 —— 在 Android 上这意味着
     * 用户其它 App 被杀，是灾难级故障。所以「回收」与「发信号」必须同锁串行，
     * 且回收后状态固化为「已回收」，永不再发信号。
     */
    private inner class ChildState {
        private val lock = Any()
        private var reaped = false
        private var cachedStatus = PTY_RUNNING

        val isAlive: Boolean get() = synchronized(lock) { !reapLocked() }

        /** 非阻塞探测：返回 [PTY_RUNNING] / [PTY_ERROR] / 原始 wait status。 */
        fun pollStatus(): Int = synchronized(lock) {
            if (!reaped) {
                val status = nativeWaitNoHang(childPid).toInt()
                if (status != PTY_RUNNING) {
                    reaped = true
                    cachedStatus = status
                }
            }
            cachedStatus
        }

        /**
         * 向进程组发信号；已回收则返回 false —— 这**不是失败**：竞态里进程
         * 恰在探测与 kill 之间退出，属正常终止。
         */
        fun signal(signal: Int): Boolean = synchronized(lock) {
            if (reapLocked()) return@synchronized false
            if (nativeSignal(childPid, signal) == 0) return@synchronized true
            // 发信号失败：可能刚好退出，再探测一次；仍未退出才算真失败。
            !reapLocked() && nativeSignal(childPid, signal) == 0
        }

        /** 非阻塞回收；true 表示已回收（已退出）。 */
        private fun reapLocked(): Boolean {
            if (reaped) return true
            val status = nativeWaitNoHang(childPid).toInt()
            if (status != PTY_RUNNING) {
                reaped = true
                cachedStatus = status
            }
            return reaped
        }
    }

    companion object {
        /**
         * 载入 native 库。**只尝试一次**：dlopen 失败后的重复尝试会污染进程的
         * linker 状态，而且在 Android 上本来也不会第二次成功。
         */
        private val nativeLoaded: Boolean by lazy {
            try {
                System.loadLibrary(LIB_NAME)
                true
            } catch (_: UnsatisfiedLinkError) {
                // 打包问题（AAR 里缺 arm64-v8a/libpty_bridge.so）或 ABI 不匹配。
                // 不静默回退 —— 见文件头删减说明 1。
                false
            } catch (_: Throwable) {
                false
            }
        }

        /** 真 PTY 后端在本进程里是否可用。 */
        val nativeAvailable: Boolean get() = nativeLoaded

        private const val LIB_NAME = "pty_bridge"

        private const val READ_BUFFER_BYTES = 8192
        private const val POLL_INTERVAL_MILLIS = 10L
        private const val WRITE_RETRY_MILLIS = 2L
        private const val CANCEL_GRACE_MILLIS = 500L
        private const val TIMEOUT_GRACE_MILLIS = 300L
        private const val CLOSE_GRACE_MILLIS = 500L
        private const val KILL_GRACE_MILLIS = 1_000L
        private const val MILLIS_TO_NANOS = 1_000_000L

        /** 与 pty_bridge.cpp 的 kWaitRunning 一致。 */
        private const val PTY_RUNNING = -1

        /** 与 pty_bridge.cpp 的 kWaitError 一致。 */
        private const val PTY_ERROR = -2

        /** 无法判定退出状态时的退出码（与 shell 的 126/127 区分开）。 */
        const val EXIT_UNKNOWN = -1

        private const val SIGTERM = 15
        private const val SIGKILL = 9

        /**
         * 打开 PTY 会话并 exec 命令。
         *
         * @param argv  必须是**宿主机视角**的可执行文件路径（如 PRoot 二进制）
         * @param envp  "K=V" 形式；会**整体替换**子进程环境（不继承宿主环境）
         * @param cwd   宿主机视角的工作目录；null 表示 "/"
         * @throws SandboxException CODE_INTERNAL native 库没打进 AAR
         * @throws IOException openpty / fork 失败
         */
        suspend fun open(
            argv: List<String>,
            envp: Map<String, String>,
            cwd: String?,
            columns: Int,
            rows: Int,
            scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
        ): PtySession = withContext(Dispatchers.IO) {
            if (!nativeLoaded) {
                throw SandboxException(
                    SandboxException.CODE_INTERNAL,
                    "PTY native 库（lib$LIB_NAME.so）不可用：AAR 里缺少 arm64-v8a 产物，" +
                        "或当前设备不是 64 位 ARM。沙箱只支持 arm64-v8a。",
                )
            }
            require(argv.isNotEmpty()) { "argv 不能为空" }

            val pair = nativeOpenAndExec(
                argv.toTypedArray(),
                envp.entries.map { "${it.key}=${it.value}" }.toTypedArray(),
                cwd ?: "/",
                columns.coerceIn(20, 400),
                rows.coerceIn(5, 200),
            )
            if (pair == null || pair.size < 2) {
                throw IOException("PTY 打开失败（native 未返回 fd/pid）")
            }
            // ================================================================
            // ★ 给本会话一个**只属于自己的子作用域**，不能直接用调用方的 scope
            // ================================================================
            // 原因（真机 bug，务必保留）：
            //   [close] 里有 `scope.coroutineContext.cancelChildren()`，用来收掉
            //   本会话的读出协程。如果 scope 就是调用方那个，这句话会**取消调用方
            //   自己正在跑的协程**。
            //
            //   - 旧路径 `ProotEngine.execute()` 每次都 new 一个一次性 scope，
            //     打到的只有它自己 ⇒ 无害（所以这个 bug 潜伏了很久）；
            //   - 换成 `SandboxServiceCore`（长期存活的 supervisor scope）之后，
            //     cancelChildren 把「正在执行这条命令的协程」一起取消了 ⇒ 外层落进
            //     CancellationException 兜底分支，返回写死的 `exit=130 / 0ms /
            //     cancelled=true`。而命令其实**早已成功执行**（fd0=/dev/pts/0、
            //     IS_TTY 都打印出来了），只是结果被判成"已取消"。
            //
            //   `SupervisorJob(parent)` 保持「调用方被取消时本会话也跟着取消」
            //   的语义不变，但 cancelChildren 只打得到会话自己的读循环。
            val sessionScope = CoroutineScope(
                scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]),
            )
            PtySession(masterFd = pair[0], childPid = pair[1], scope = sessionScope)
        }

        // ====================================================================
        // JNI 声明 —— 与 pty_bridge.cpp 的 kMethods 表逐字对应。
        //
        // 改这里必须同步改 cpp，否则 RegisterNatives 失败 ⇒ JNI_OnLoad 返回
        // JNI_ERR ⇒ System.loadLibrary 抛 UnsatisfiedLinkError。
        // ====================================================================

        /** `([Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;II)[I` */
        private external fun nativeOpenAndExec(
            argv: Array<String>,
            envp: Array<String>,
            cwd: String?,
            columns: Int,
            rows: Int,
        ): IntArray?

        /** `(I[B)I` */
        private external fun nativeRead(fd: Int, buffer: ByteArray): Int

        /** `(I[BII)I` */
        private external fun nativeWrite(fd: Int, buffer: ByteArray, offset: Int, length: Int): Int

        /** `(III)I` */
        private external fun nativeResize(fd: Int, columns: Int, rows: Int): Int

        /** `(II)I` */
        private external fun nativeSignal(pid: Int, signal: Int): Int

        /** `(I)J` */
        private external fun nativeWaitNoHang(pid: Int): Long

        /** `(I)V` */
        private external fun nativeCloseFd(fd: Int)
    }
}

/**
 * 增量 UTF-8 解码器。
 *
 * 问题：`read()` 返回的字节块边界与 UTF-8 字符边界**无关**。一个 3 字节的中文
 * 字符完全可能被切成 1+2 落在两次 read 里，直接 `String(bytes)` 会得到替换字符
 * "�" —— 终端里表现为中文乱码，日志也不可搜索。
 *
 * 做法：保留「上次没组成完整字符的尾巴」，与下一块拼起来再解码。
 * 非法序列用 REPLACE 而不是抛异常（终端输出里本来就可能混入二进制）。
 *
 * 移植自 taixu 的 IncrementalUtf8Decoder，逻辑一致；差异是容量检查用 require
 * 给出更明确的失败信息，且 capacity 下限被夹到 MAX_SEQUENCE_BYTES。
 */
internal class IncrementalUtf8Decoder(capacityBytes: Int) {
    private val capacity = capacityBytes.coerceAtLeast(MAX_SEQUENCE_BYTES)

    private val decoder = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPLACE)
        .onUnmappableCharacter(CodingErrorAction.REPLACE)

    /** 累积缓冲：保留上次解码剩下的不完整序列（最多 3 字节）。 */
    private val pending = ByteBuffer.allocate(capacity + MAX_SEQUENCE_BYTES)

    /** 解码一块数据，返回**已确定的完整字符**；末尾不完整序列留到下次。 */
    fun decode(input: ByteArray, length: Int): String {
        require(length in 0..input.size) { "decode length=$length 越界（input.size=${input.size}）" }
        require(length <= pending.remaining()) { "UTF-8 输入块超过解码器容量" }

        pending.put(input, 0, length)
        pending.flip()

        // 最坏情况每个字节都是一个替换字符 ⇒ 预留 MAX_SEQUENCE_BYTES 余量防溢出。
        val chars = CharBuffer.allocate(pending.remaining() + MAX_SEQUENCE_BYTES)
        decoder.decode(pending, chars, /* endOfInput = */ false)
        pending.compact()
        chars.flip()
        return chars.toString()
    }

    /** 流结束时冲出残留字节（把不完整序列 REPLACE 掉）。 */
    fun finish(): String {
        pending.flip()
        val chars = CharBuffer.allocate(pending.remaining() + MAX_SEQUENCE_BYTES)
        decoder.decode(pending, chars, /* endOfInput = */ true)
        decoder.flush(chars)
        pending.clear()
        chars.flip()
        return chars.toString()
    }

    private companion object {
        /** UTF-8 最长字符编码长度。 */
        const val MAX_SEQUENCE_BYTES = 4
    }
}
