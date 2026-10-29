/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 * SPDX-License-Identifier: GPL-3.0
 *
 * 诊断：为什么 aapt2 compile 在沙箱里失败。
 */

package com.heracles.sandbox.demo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.runtime.ToolchainLayout
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AaptDiagTest {

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val TAG = "AaptDiagTest"

    @Test
    fun diagnose_aapt2_compile() {
        val facade = SandboxFacade(context)
        assertTrue(runBlocking { facade.ensureRootfs() })
        val env = ToolchainLayout.envPrelude(ToolchainLayout.ALPINE_JDK_HOME)

        for (cmd in listOf(
            "aapt2 version 2>&1",
            "ls -ld /tmp 2>&1",
            "ls -l /workspace/hello 2>&1",
            "ls -l /workspace/hello/res/values 2>&1",
            "cat /workspace/hello/AndroidManifest.xml 2>&1 | head -5",
            "cd /workspace/hello && aapt2 compile --dir res -o compiled.zip 2>&1; echo RC=\$?",
            "cd /workspace/hello && aapt2 compile --dir res -o /tmp/c.zip 2>&1; echo RC=\$?",
            "cd /workspace/hello && aapt2 compile res/values/strings.xml -o /tmp/one.zip 2>&1; echo RC=\$?",
            "command -v zip; zip -v 2>&1 | head -2",
        )) {
            val r = run(facade, "$env $cmd", 180_000)
            logI("CMD [$cmd] exit=${r.exitCode} out=[${r.stdout.trim().take(600)}]")
        }
    }

    private fun logI(msg: String) = android.util.Log.i(TAG, msg)

    private fun run(facade: SandboxFacade, command: String, timeoutMs: Long = 120_000): ExecutionResult {
        val latch = CountDownLatch(1)
        var result: ExecutionResult? = null
        val out = StringBuilder()
        facade.execute(
            ExecutionRequest(command = command, workingDirectory = "/", timeoutMillis = timeoutMs),
            object : IExecutionCallback.Stub() {
                override fun onOutput(stream: Int, chunk: String, sequence: Long) { out.append(chunk) }
                override fun onProgress(percent: Int, message: String) = Unit
                override fun onExit(r: ExecutionResult) { result = r; latch.countDown() }
                override fun onError(code: Int, message: String) {
                    result = ExecutionResult(-1, out.toString(), message, 0, false, false, false, ChannelType.NORMAL.ordinal)
                    latch.countDown()
                }
                override fun isCancelled(): Boolean = false
            },
        )
        latch.await(timeoutMs + 20_000, TimeUnit.MILLISECONDS)
        return result ?: ExecutionResult(-1, out.toString(), "超时", timeoutMs, true, false, false, ChannelType.NORMAL.ordinal)
    }
}
