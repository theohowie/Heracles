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
 * ---------------------------------------------------------------------------
 * 移植来源
 * ---------------------------------------------------------------------------
 * 上游：baicodex (mubai0122/baicodex) @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95
 *   原文件：app/src/main/kotlin/b/ai/exec/Shell.kt   （drainProcess / ShellResult / 超时强杀）
 *   原文件：app/src/main/kotlin/b/ai/exec/Root.kt    （每条命令一次 su -c 的调用形态）
 * 上游：tianxuan (xiaozhe7772222/tianxuan) @ caad40090a4f2c2edbe54e6eaae60a3dd1de7d21
 *   原文件：runtime/src/main/java/top/wkbin/tianxuan/runtime/bridge/adb/EmbeddedAdbManager.kt
 *           （ShellOutcome / 输出上限 200_000 字符）
 *
 * 本文件把「执行器」抽象成一个与身份无关的接口。四个通道各自实现它，
 * 上层（runtime 的 execute）只依赖这个接口，不知道底下是 App / Shizuku / su / adb。
 */

package com.heracles.sandbox.channel

import com.heracles.sandbox.api.ChannelType
import java.util.concurrent.TimeUnit

/**
 * 一次 shell 执行的原始结果（四通道统一形态）。
 *
 * <p>{@code exitCode = -1} 统一表示「通道层就失败了」而不是「命令返回非 0」：
 * 起不来进程、Binder 事务被拒、ADB 链路断开、超时被强杀，都属于这一类。
 * 这与上游 baicodex `ShellResult(-1, …)` 的约定一致。
 */
data class ShellOutcome(
    val exitCode: Int,
    val output: String,
    /** 是否因超时被强制结束。 */
    val timedOut: Boolean = false,
) {
    val isSuccess: Boolean get() = exitCode == 0 && !timedOut
}

/**
 * 一个执行通道的最小能力面。
 *
 * <p>**只做执行**。文件读写不走这里 —— 那是 `sandbox-file` 的零宽通道，
 * 两者的身份可能不同（例如以 NORMAL 身份执行 `cat`，但用零宽通道直读 data 目录），
 * 混在一起会让「这个路径到底由谁解析」变得不可判定。
 */
interface CapabilityChannel {

    /** 本执行器代表的通道档位。 */
    val type: ChannelType

    /**
     * 以本通道身份执行一段 shell。
     *
     * <p>命令语义是**沙箱视角**（PRoot 内 `/bin/sh -c`）还是**宿主视角**
     * （`/system/bin/sh -c`）由具体通道决定，见各实现的 KDoc。
     *
     * <p>本方法**不抛异常**：任何失败都收敛成 `exitCode = -1` + 可读原因，
     * 这样上层不必为四种通道写四份 try/catch。
     *
     * @param command   要执行的命令（由 sh -c 解释，可带管道与重定向）
     * @param stdin     一次性写入的标准输入；null 表示立刻关闭 stdin
     * @param timeoutMs 超时毫秒；到点强杀并置 `timedOut`
     */
    fun exec(command: String, stdin: String? = null, timeoutMs: Long = DEFAULT_TIMEOUT_MS): ShellOutcome

    companion object {
        /** 默认超时：与上游 baicodex `Root.run` / `Shiz.run` 的 120_000 ms 对齐。 */
        const val DEFAULT_TIMEOUT_MS: Long = 120_000L
    }
}

/**
 * 吃掉子进程输出并等待结束（stdout/stderr 合并）。
 *
 * <p>移植自 baicodex `Shell.kt` 的 `drainProcess`，做了两处收紧：
 *
 * 1. **输出上限**：上游不封顶，`logcat -d` 这类命令能把整段输出拉进内存；
 *    tianxuan 为此加了 200_000 字符上限（`MAX_SHELL_OUTPUT_CHARS`），此处沿用同一数值。
 *    超限时截断并显式标注，避免「看起来成功但内容不全」。
 * 2. **读线程与强杀的顺序**：先 destroyForcibly 再 join，保证超时后不会因为
 *    管道未关闭而卡在 read 上（上游是先 destroy 再 join，行为一致，此处补注释说明原因）。
 *
 * @param process  已启动的子进程（调用方负责用 `redirectErrorStream(true)` 合并流）
 * @param timeoutMs 等待上限
 * @param stdin    一次性写入的内容；null 表示立刻关闭 stdin
 */
internal fun drainProcess(process: Process, timeoutMs: Long, stdin: String? = null): ShellOutcome {
    val buffer = StringBuilder()
    val reader = Thread {
        runCatching {
            process.inputStream.bufferedReader().forEachLine { line ->
                synchronized(buffer) { buffer.appendLine(line) }
            }
        }
    }.apply {
        isDaemon = true
        name = "sandbox-sh-drain"
    }
    reader.start()

    runCatching {
        if (stdin != null) {
            process.outputStream.use { it.write(stdin.toByteArray(Charsets.UTF_8)) }
        } else {
            process.outputStream.close()
        }
    }

    val finished = runCatching { process.waitFor(timeoutMs, TimeUnit.MILLISECONDS) }.getOrDefault(false)
    if (!finished) {
        // 超时：先强杀再 join，否则读线程会一直阻塞在管道上。
        runCatching { process.destroyForcibly() }
    }
    reader.join(2_000)

    val text = synchronized(buffer) { buffer.toString() }.repeatLimit(MAX_SHELL_OUTPUT_CHARS)
    return if (finished) {
        val code = runCatching { process.exitValue() }.getOrDefault(-1)
        ShellOutcome(code, text)
    } else {
        ShellOutcome(-1, "$text\n[超时 ${timeoutMs}ms，已强制结束]".trim(), timedOut = true)
    }
}

/** 单次执行保留的最大字符数：与 tianxuan `MAX_SHELL_OUTPUT_CHARS` 同值（防 Java 堆 OOM）。 */
internal const val MAX_SHELL_OUTPUT_CHARS: Int = 200_000

/** 超出上限时截断并显式标注；未超限原样返回。 */
internal fun String.repeatLimit(limit: Int = MAX_SHELL_OUTPUT_CHARS): String =
    if (length <= limit) {
        this
    } else {
        take(limit) + "\n[输出超限已截断：原文 $length 字符，仅保留前 $limit]" +
            "；请缩小输出范围（head / grep / 加 -t 限制行数）"
    }

/** POSIX 单引号转义：把任意字符串安全地塞进 `sh -c` 的命令行。 */
internal fun String.shellQuote(): String = "'" + replace("'", "'\\''") + "'"
