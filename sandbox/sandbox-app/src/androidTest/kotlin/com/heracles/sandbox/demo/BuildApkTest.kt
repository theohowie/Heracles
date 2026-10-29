/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * 设备侧验证：**在沙箱内完整产出一个已签名 APK**。
 *
 * ============================================================================
 * 这条链要证明什么
 * ============================================================================
 * 不是「工具能跑」，而是「**能在沙箱里把源码编成 APK**」：
 *
 *   aapt2 compile  →  aapt2 link  →  javac  →  d8  →  zip  →  zipalign  →  apksigner
 *
 * 全程在 PRoot guest 内执行，产物落在 `/workspace/hello/`（rootfs 内），
 * 最后用 `aapt2 dump badging` 反解产物，确认它是结构正确的 APK。
 *
 * ============================================================================
 * 前置（宿主 push 上来）
 * ============================================================================
 *   /sdcard/Android/data/<test-pkg>/files/android.jar     （platform-34）
 *   /sdcard/Android/data/<test-pkg>/files/d8.jar
 *   /sdcard/Android/data/<test-pkg>/files/apksigner.jar
 *
 * 测试会把它们拷进 rootfs 的 `/opt/as/platforms/android-34/` 与 `/opt/tools/`，
 * 之后**只通过 execute 在沙箱内调用**。
 */

package com.heracles.sandbox.demo

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.heracles.sandbox.api.ChannelType
import com.heracles.sandbox.api.ExecutionRequest
import com.heracles.sandbox.api.ExecutionResult
import com.heracles.sandbox.api.IExecutionCallback
import com.heracles.sandbox.runtime.BuildSuiteCatalog
import com.heracles.sandbox.runtime.BuildSuiteInstaller
import com.heracles.sandbox.runtime.ToolchainLayout
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BuildApkTest {

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val TAG = "BuildApkTest"

    @Test
    fun buildSignedApk_insideSandbox() {
        val facade = SandboxFacade(context)
        assertTrue("需要 rootfs", runBlocking { facade.ensureRootfs() })
        val rootfs = facade.rootfsHostRoot()!!

        // ---------- 前置 1：DNS（apk 需要）----------
        ensureDns(facade)

        // ---------- 前置 2：aapt2/aidl/zipalign（刚装的 rootfs 没有，需要装）----------
        val hasAapt = run(facade, "test -x /opt/as/build-tools/aapt2 && echo HAS || echo NO", 30_000)
        if (hasAapt.stdout.contains("NO")) {
            val installer = BuildSuiteInstaller(rootfs)
            val inst = runBlocking {
                installer.install(BuildSuiteCatalog.ANDROID_SDK_TOOLS) { d, t, s -> if (s != "下载中") logI("sdk: $s") }
            }
            logI("sdk install: success=${inst.success} msg=${inst.message}")
            assertTrue("必须装上 aapt2：${inst.message}", inst.success)
        } else {
            logI("aapt2 已存在，跳过安装")
        }

        // ---------- 前置 3：zip + JDK（都走 apk，musl 版）----------
        val zipAdd = run(facade, "command -v zip >/dev/null 2>&1 || apk add --no-cache zip 2>&1", 600_000)
        logI("ensure zip: exit=${zipAdd.exitCode}")

        // javac/keytool 来自 Alpine 的 musl JDK（Temurin 是 glibc，跑不了）
        val hasJava = run(facade, "command -v javac >/dev/null 2>&1 && echo HAS || echo NO", 30_000)
        if (hasJava.stdout.contains("NO")) {
            val jdk = run(facade, "apk add --no-cache openjdk17-jdk 2>&1", 1_800_000)
            logI("apk add jdk: exit=${jdk.exitCode} tail=[${jdk.stdout.trim().takeLast(300)}]")
            // ⚠️ apk 会返回 1，但包其实装好了：真机实测它在 PRoot 下创建临时文件
            //    `usr/bin/.apk.xxxxxxxx` 失败，报 "1 error"，可 `javac` 是存在的。
            //    所以**以实际结果为准**（下面检查 javac），不以 apk 的退出码为准。
            val javacOk = run(facade, "command -v javac && javac -version 2>&1", 60_000)
            logI("javac check: exit=${javacOk.exitCode} out=[${javacOk.stdout.trim()}]")
            assertTrue("JDK 必须真的可用（apk 退出码=${jdk.exitCode}）：${javacOk.stdout.trim()}",
                javacOk.exitCode == 0 && javacOk.stdout.contains("javac"))
        } else {
            logI("JDK 已存在")
        }

        // ---------- 前置 3：把 android.jar / d8.jar / apksigner.jar 拷进 rootfs ----------
        val ext = context.getExternalFilesDir(null)!!
        val androidJarSrc = File(ext, "android.jar")
        val d8Src = File(ext, "d8.jar")
        val apksignerSrc = File(ext, "apksigner.jar")
        logI("archives: android.jar=${androidJarSrc.isFile} d8.jar=${d8Src.isFile} apksigner.jar=${apksignerSrc.isFile}")
        assumeTrue("需要 push android.jar / d8.jar / apksigner.jar 到 ${ext.absolutePath}",
            androidJarSrc.isFile && d8Src.isFile && apksignerSrc.isFile)

        val androidJar = File(rootfs, "opt/as/platforms/android-34/android.jar")
        androidJar.parentFile!!.mkdirs()
        androidJarSrc.copyTo(androidJar, overwrite = true)
        val toolsDir = File(rootfs, "opt/tools").apply { mkdirs() }
        d8Src.copyTo(File(toolsDir, "d8.jar"), overwrite = true)
        apksignerSrc.copyTo(File(toolsDir, "apksigner.jar"), overwrite = true)
        logI("copied into rootfs: android.jar=${androidJar.length()} d8=${File(toolsDir,"d8.jar").length()}")

        // ---------- 前置 4：写一个最小 Android 工程进 rootfs /workspace/hello ----------
        // ⚠️ 不能放 /workspace：guest 的 /workspace 是 bind 挂载（宿主 workspaces 目录），
        //    会被盖住。放 rootfs 内的 /opt/build 才不会被遮蔽。
        writeProject(File(rootfs, "opt/build/hello"))

        val env = ToolchainLayout.envPrelude(ToolchainLayout.ALPINE_JDK_HOME)
        val JAR = "/opt/as/platforms/android-34/android.jar"
        val D8 = "/opt/tools/d8.jar"
        val APKSIGNER = "/opt/tools/apksigner.jar"
        val P = "/opt/build/hello"

        // ---------- 步骤 1：aapt2 compile ----------
        val s1 = run(facade, "$env cd $P && aapt2 compile --dir res -o compiled.zip 2>&1", 300_000)
        step("1 aapt2 compile", s1)
        assertEquals("aapt2 compile 应成功", 0, s1.exitCode)

        // ---------- 步骤 2：aapt2 link ----------
        val s2 = run(
            facade,
            "$env cd $P && aapt2 link -o unsigned.apk -I $JAR " +
                "--manifest AndroidManifest.xml compiled.zip --java gen --auto-add-overlay 2>&1",
            300_000,
        )
        step("2 aapt2 link", s2)
        assertEquals("aapt2 link 应成功（out=${s2.stdout.take(400)}）", 0, s2.exitCode)

        // ---------- 步骤 3：javac ----------
        val s3 = run(
            facade,
            "$env cd $P && javac --release 11 -classpath $JAR -d classes " +
                "src/com/example/hello/MainActivity.java gen/com/example/hello/R.java 2>&1",
            300_000,
        )
        step("3 javac", s3)
        assertEquals("javac 应成功（out=${s3.stdout.take(400)}）", 0, s3.exitCode)

        // ---------- 步骤 4：d8 ----------
        val s4 = run(
            facade,
            "$env cd $P && mkdir -p dex && java -cp $D8 com.android.tools.r8.D8 " +
                "--lib $JAR --min-api 29 --output dex classes/com/example/hello/*.class 2>&1",
            600_000,
        )
        step("4 d8", s4)
        assertEquals("d8 应成功（out=${s4.stdout.take(400)}）", 0, s4.exitCode)

        // ---------- 步骤 5：把 classes.dex 塞进 APK ----------
        val s5 = run(facade, "$env cd $P && zip -j unsigned.apk dex/classes.dex 2>&1", 300_000)
        step("5 zip add dex", s5)
        assertEquals("zip 应成功（out=${s5.stdout.take(300)}）", 0, s5.exitCode)

        // ---------- 步骤 6：zipalign ----------
        val s6 = run(facade, "$env cd $P && zipalign -f 4 unsigned.apk aligned.apk 2>&1", 300_000)
        step("6 zipalign", s6)
        assertEquals("zipalign 应成功（out=${s6.stdout.take(300)}）", 0, s6.exitCode)

        // ---------- 步骤 7：生成 keystore 并签名 ----------
        val s7a = run(
            facade,
            "$env cd $P && keytool -genkeypair -keystore ks.jks -alias a -keyalg RSA " +
                "-keysize 2048 -validity 3650 -storepass android -keypass android " +
                "-dname \"CN=Sandbox,OU=Test,O=Heracles,C=CN\" 2>&1",
            300_000,
        )
        step("7a keytool", s7a)
        assertEquals("keytool 应成功（out=${s7a.stdout.take(400)}）", 0, s7a.exitCode)

        val s7b = run(
            facade,
            "$env cd $P && java -jar $APKSIGNER sign --ks ks.jks --ks-pass pass:android " +
                "--key-pass pass:android --out signed.apk aligned.apk 2>&1",
            600_000,
        )
        step("7b apksigner sign", s7b)
        assertEquals("apksigner sign 应成功（out=${s7b.stdout.take(400)}）", 0, s7b.exitCode)

        // ---------- 步骤 8：验签 ----------
        val s8 = run(facade, "$env cd $P && java -jar $APKSIGNER verify --print-certs signed.apk 2>&1", 300_000)
        step("8 apksigner verify", s8)
        assertEquals("apksigner verify 应成功（out=${s8.stdout.take(400)}）", 0, s8.exitCode)
        assertTrue("应含签名者信息，实际=${s8.stdout}", s8.stdout.contains("Signer #1"))

        // ---------- 步骤 9：反解产物，确认是结构正确的 APK ----------
        val s9 = run(facade, "$env cd $P && aapt2 dump badging signed.apk 2>&1", 300_000)
        step("9 aapt2 dump badging", s9)
        assertEquals("dump badging 应成功", 0, s9.exitCode)
        assertTrue("应解析出 package 名，实际=${s9.stdout.take(300)}",
            s9.stdout.contains("package: name='com.example.hello'"))

        // ---------- 步骤 10：产物清单（真实体积）----------
        val ls = run(facade, "$env cd $P && ls -l signed.apk && unzip -l signed.apk 2>&1 | head -12", 120_000)
        logI("SATOK product:\n${ls.stdout.trim()}")
    }

    // ------------------------------------------------------------------

    private fun ensureDns(facade: SandboxFacade) {
        val has = run(facade, "test -s /etc/resolv.conf && echo HAS || echo NO", 30_000)
        if (has.stdout.contains("NO")) {
            run(
                facade,
                "printf \"nameserver 192.168.137.1\\nnameserver 114.114.114.114\\nnameserver 223.5.5.5\\n\" > /etc/resolv.conf",
                30_000,
            )
            logI("resolv.conf written")
        }
    }

    /** 写一个最小但真实的 Android 工程（有 Activity、有资源）。 */
    private fun writeProject(dir: File) {
        dir.deleteRecursively()
        File(dir, "src/com/example/hello").mkdirs()
        File(dir, "res/values").mkdirs()

        File(dir, "AndroidManifest.xml").writeText(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <manifest xmlns:android="http://schemas.android.com/apk/res/android"
                package="com.example.hello">
                <uses-sdk android:minSdkVersion="29" android:targetSdkVersion="34" />
                <application android:label="@string/app_name">
                    <activity android:name=".MainActivity" android:exported="true" />
                </application>
            </manifest>
            """.trimIndent(),
        )

        File(dir, "res/values/strings.xml").writeText(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <resources>
                <string name="app_name">HelloSandbox</string>
            </resources>
            """.trimIndent(),
        )

        File(dir, "src/com/example/hello/MainActivity.java").writeText(
            """
            package com.example.hello;

            import android.app.Activity;

            /** 沙箱内编译用的最小 Activity。 */
            public class MainActivity extends Activity {
                public String greet() {
                    return "built inside PRoot sandbox";
                }
            }
            """.trimIndent(),
        )
        logI("project written to ${dir.absolutePath}")
    }

    private fun step(name: String, r: ExecutionResult) {
        logI("STEP $name: exit=${r.exitCode} out=[${r.stdout.trim().take(500)}]")
    }

    private fun logI(msg: String) = android.util.Log.i(TAG, msg)

    private fun run(
        facade: SandboxFacade,
        command: String,
        timeoutMs: Long = 300_000,
    ): ExecutionResult {
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
                    result = ExecutionResult(
                        exitCode = -1, stdout = out.toString(), stderr = message,
                        durationMillis = 0, timedOut = false, cancelled = false,
                        truncated = false, channelType = ChannelType.NORMAL.ordinal,
                    )
                    latch.countDown()
                }
                override fun isCancelled(): Boolean = false
            },
        )
        latch.await(timeoutMs + 30_000, TimeUnit.MILLISECONDS)
        return result ?: ExecutionResult(
            exitCode = -1, stdout = out.toString(), stderr = "超时",
            durationMillis = timeoutMs, timedOut = true, cancelled = false,
            truncated = false, channelType = ChannelType.NORMAL.ordinal,
        )
    }
}
