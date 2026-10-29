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
 *   原文件：app/src/main/kotlin/b/ai/exec/ShizukuShell.kt （UserService 侧的 onTransact + exec）
 *   原文件：app/src/main/kotlin/b/ai/exec/Shiz.kt         （DESC / TX_EXEC / TX_UID / REQ_CODE 协议常量）
 *
 * 这是**跑在 Shizuku 用户服务进程里**的命令执行器。它属于我们自己的 APK，
 * 但由 Shizuku 以 shell（uid 2000）或 root（uid 0）身份拉起 ——
 * 因此它从不用启动本应用，也不要求本应用在前台。
 *
 * ★ 本文件**不 import 任何 rikka.shizuku.* 类型**：
 *   它只需要 android.app.Service / Binder / Parcel / ProcessBuilder。
 *   这保证了「用户服务进程」即使在 Shizuku 类不可用的环境下也能被加载
 *   （用户服务进程由 Shizuku 注入，classloader 里其实有它，但我们不依赖这一点）。
 */

package com.heracles.sandbox.channel.shizuku

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import java.util.concurrent.TimeUnit

/**
 * 本应用与 Shizuku 之间、**经由用户服务**的私有 Binder 协议。
 *
 * <p>之所以不用 AIDL 生成：这条通道是「应用 ↔ 自己的用户服务」的内部协议，
 * 不像 [com.heracles.sandbox.api.ISandboxService] 那样需要发布给第三方宿主。
 * 手写 Parcel 让 `sandbox-channel` 不必再引入一个 `aidl = true` 的编译开关。
 *
 * <p>**协议是单向的、只做两件事**：执行命令、报自己的 uid。
 * 不做文件读写 —— 文件走 `sandbox-file` 的零宽通道，见那边的 KDoc。
 */
object ShizukuProtocol {

    /** 事务描述符：Binder 端用来校验调用方，防止别的 App 猜中接口号乱调。 */
    const val DESCRIPTOR: String = "com.heracles.sandbox.channel.shizuku.IShizukuExec"

    /** `exec(cmd: String, stdin: String?, timeoutMs: Int) -> (exitCode: Int, output: String)`。 */
    const val TX_EXEC: Int = 1

    /** `getUid() -> Int`：用户服务所在进程的真实 uid（2000 = shell，0 = root）。 */
    const val TX_UID: Int = 2

    /** Shizuku 管理器的包名（`moe.shizuku.privileged.api`）。 */
    const val SHIZUKU_PACKAGE: String = "moe.shizuku.privileged.api"

    /** 申请 Shizuku 授权的 requestCode（与上游同值，避免宿主里两个库撞号）。 */
    const val REQUEST_CODE: Int = 4210

    /** 用户服务的版本号：改动 [ShizukuExecService] 的行为时递增，Shizuku 会重拉服务。 */
    const val USER_SERVICE_VERSION: Int = 1

    /** 传给 Shizuku 的进程名后缀。 */
    const val USER_SERVICE_PROCESS_SUFFIX: String = "exec"

    /** Binder 单次事务的安全上限（约 1MB，留出 Parcel 头部余量；上游写死 700_000）。 */
    const val MAX_STDIN_CHARS: Int = 700_000
}

/**
 * Shizuku 用户服务：以 shell / root 身份跑 `/system/bin/sh -c`。
 *
 * <p>**它不是组件式的常驻服务**：Shizuku 通过 `bindUserService` 把它拉起并绑定，
 * 每次 [ShizukuProtocol.TX_EXEC] 起一个独立子进程，读完输出就回收。
 *
 * <p>上游 baicodex 的写法原样保留（含调用方 uid 校验的三种放行值）：
 * 本应用自己、uid 0、uid 2000。别的 App 调进来会被拒 —— 这是本服务唯一的安全边界，
 * 因为它在 manifest 里是 `exported=true`（Shizuku 是另一个 uid，必须能 bind）。
 */
class ShizukuExecService : Service() {

    override fun onBind(intent: Intent?): IBinder = ExecBinder()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY

    private class ExecBinder : Binder() {

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            val caller = Binder.getCallingUid()
            val allowed = caller == Process.myUid() || caller == 0 || caller == 2000
            if (!allowed) {
                // 拒绝时也要 consume 掉参数，否则 Parcel 状态会错位。
                data.enforceInterface(ShizukuProtocol.DESCRIPTOR)
                reply?.writeException(SecurityException("caller uid $caller not allowed"))
                return true
            }
            when (code) {
                ShizukuProtocol.TX_EXEC -> {
                    data.enforceInterface(ShizukuProtocol.DESCRIPTOR)
                    val command = data.readString().orEmpty()
                    val stdin = data.readString()
                    val timeout = data.readInt().toLong()
                    val outcome = exec(command, stdin, if (timeout > 0) timeout else 120_000L)
                    reply?.writeNoException()
                    reply?.writeInt(outcome.first)
                    reply?.writeString(outcome.second)
                    return true
                }

                ShizukuProtocol.TX_UID -> {
                    data.enforceInterface(ShizukuProtocol.DESCRIPTOR)
                    reply?.writeNoException()
                    reply?.writeInt(Process.myUid())
                    return true
                }
            }
            return super.onTransact(code, data, reply, flags)
        }

        /**
         * 在用户服务进程里跑 sh。
         *
         * <p>用 `/system/bin/sh` 而不是 PRoot：用户服务的职责只是「换个身份」，
         * PRoot 命令行的组装在 runtime 侧完成后再交到这里。
         */
        private fun exec(command: String, stdin: String?, timeoutMs: Long): Pair<Int, String> {
            val process = runCatching {
                ProcessBuilder("/system/bin/sh", "-c", command)
                    .redirectErrorStream(true)
                    .start()
            }.getOrElse { error ->
                return -1 to "[user-service] 启动失败：${error.javaClass.simpleName}: ${error.message}"
            }

            val buffer = StringBuilder()
            val reader = Thread {
                runCatching {
                    process.inputStream.bufferedReader().forEachLine { line ->
                        synchronized(buffer) { buffer.appendLine(line) }
                    }
                }
            }.apply {
                isDaemon = true
                name = "sandbox-shizuku-user-svc"
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
            if (!finished) runCatching { process.destroyForcibly() }
            reader.join(2_000)

            val text = synchronized(buffer) { buffer.toString() }.trim()
            return if (finished) {
                val code = runCatching { process.exitValue() }.getOrDefault(-1)
                code to text
            } else {
                -1 to "$text\n[user-service 超时 ${timeoutMs}ms，已强制结束]"
            }
        }
    }
}
