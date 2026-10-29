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
 */

package com.heracles.sandbox.demo

import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import com.heracles.sandbox.api.ChannelType
import kotlin.concurrent.thread

/**
 * 5 分钟快速上手的**最小闭环** demo。
 *
 * 五个按钮 = 验收标准：
 *   ① 装 rootfs      —— 内置优先，失败转 OCI（演示双策略）
 *   ② 执行命令       —— `echo hello` + **工具链如实探测**（演示 execute + 回调）
 *   ③ 读写文件       —— HOST / SANDBOX 两套视角对比
 *   ④ 查四条通道     —— 可用性 / 前置条件 / 风险等级
 *   ⑤ AIDL 跨进程    —— bindService → ISandboxService → execute（[AidlClientDemo]）
 *
 * 设计取舍：
 * - ①–④ 走**进程内**（[SandboxFacade]）：让 5 分钟闭环的门槛最低。
 *   ★ 但进程内路径也**走 `SandboxServiceCore`**，不是 `ProotEngine` 直通 ——
 *   否则并发上限 / 进程账本 / 关闭回收三条保障全都没有（见 `SandboxFacade` 的类注释）。
 * - ⑤ 走**真正跨进程**的 AIDL（`:sandbox` 独立进程）：演示两条路径的差别，
 *   以及宿主必须处理的重连 / 错误码映射。
 * - **单线程顺序执行**：demo 只要结果可读，不需要并发。
 * - **不隐藏失败**：任何一步失败都把真实错误码与原因打出来，
 *   并说明「这是正常的、该怎么修」，而不是 catch 掉假装成功。
 */
class MainActivity : ComponentActivity() {

    private lateinit var facade: SandboxFacade
    private lateinit var aidl: AidlClientDemo
    private lateinit var output: TextView
    private lateinit var scroll: ScrollView
    private val runner = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "sandbox-demo").apply { isDaemon = true }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildUi())

        facade = SandboxFacade(this)
        aidl = AidlClientDemo(this) { message -> log(message) }
        log("Heracles-taixu-sandbox demo")
        log("ABI: ${android.os.Build.SUPPORTED_ABIS.joinToString()}")
        log("★ 仅支持 arm64-v8a（PTY JNI 与内置 PRoot 都是 AArch64）")
        log("")
        log(facade.rootfsSummary())
        log("")
        log("按顺序点：① → ② → ③ → ④；想对比跨进程形态再点 ⑤")
        log("")
    }

    override fun onDestroy() {
        super.onDestroy()
        // ★ 必须解绑，否则泄漏 ServiceConnection（宿主侧最常见的 binder 泄漏）
        runCatching { aidl.unbind() }
        runner.shutdownNow()
    }

    // ---------------------------------------------------------------- UI

    private fun buildUi(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(28, 60, 28, 28)
        }
        root.addView(button("① 装 rootfs（内置优先 → OCI 兜底）") { step1InstallRootfs() })
        root.addView(button("② 执行命令（echo hello / 工具链探测 / PTY）") { step2Execute() })
        root.addView(button("③ 读写文件（HOST vs SANDBOX 两套视角）") { step3Files() })
        root.addView(button("④ 查四条通道") { step4Channels() })
        root.addView(button("⑤ AIDL 跨进程（bind :sandbox → execute）") { step5Aidl() })

        scroll = ScrollView(this).apply { isFillViewport = true }
        output = TextView(this).apply {
            textSize = 11f
            typeface = android.graphics.Typeface.MONOSPACE
            setTextIsSelectable(true)
        }
        scroll.addView(output)
        root.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        return root
    }

    private fun button(label: String, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            isAllCaps = false
            textSize = 12f
            setOnClickListener { runner.execute { runCatching(action).onFailure { log("!! ${it.message}") } } }
        }

    private fun log(msg: String) {
        Log.i(TAG, msg)
        runOnUiThread {
            output.append(msg)
            output.append("\n")
            scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }

    // ------------------------------------------------------- ① 装 rootfs

    /**
     * rootfs 的**双策略**演示。
     *
     * 顺序刻意是「内置 → OCI」：
     * 内置（APK assets 里打包的 minimal rootfs）离线可用、秒级解包；
     * OCI 要网络、要几分钟，但能装出完整工具链。
     * 用户第一次打开沙箱时多半没网，不能让他卡在"装不了 rootfs"。
     */
    private fun step1InstallRootfs() {
        log("=== ① 装 rootfs ===")

        // 已经装过就不重复装（除非用户想换）
        val existing = facade.rootfs.status()
        if (existing.installed) {
            log("已安装：${existing.label}（source=${existing.source}）")
            log("路径(宿主视角)=${existing.rootfsPath}")
            log("跳过。想重装请用 resetRootfs / 卸载重装 demo。")
            log("")
            return
        }

        // ★ 注意：`useBundledRootfs()` 的设计契约是**永不抛异常** ——
        //   所有失败都表达在 `BundledRootfsResult.outcome` 里
        //   （NOT_BUNDLED / CORRUPT / UNSUPPORTED / IO_ERROR）。
        //
        //   所以这里**不能**只用 runCatching{}.getOrElse{} —— 那样只在抛异常时
        //   才记录日志，而「没打包 / 格式不支持」这些**正常失败**会被静默吞掉，
        //   表现为「内置试过了但什么都没说就跳去 OCI」，极难排查。
        //   （这是本工程真机上踩过的坑：离线时内置明明在 APK 里却装不上。）
        log("[1/2] 试内置 minimal rootfs（离线，主路径）…")
        val bundledResult = runCatching {
            kotlinx.coroutines.runBlocking { facade.rootfs.useBundledRootfs() }
        }.getOrElse { t ->
            log("  内置抛异常（不应该）：${t::class.java.simpleName}: ${t.message}")
            null
        }

        if (bundledResult != null && bundledResult.isInstalled) {
            log("  ✅ 内置 rootfs 就绪：${facade.rootfsSummary()}")
            log("  （本次**全程离线**，未访问任何网络）")
            log("")
            return
        }

        // 内置失败：**把真实原因说清楚**，别让用户以为"试过了"
        if (bundledResult != null) {
            log("  内置未生效：outcome=${bundledResult.outcome}")
            log("  原因：${bundledResult.message}")
            log("  ⇒ 这不是「没试」，是内置路径确实失败了。请按上面原因修：")
            when (bundledResult.outcome.name) {
                "NOT_BUNDLED" ->
                    log("     APK 的 assets 里没有 rootfs-bundle.tar(.gz)。" +
                        "检查 sandbox-runtime/src/main/assets/，重新构建。")
                "UNSUPPORTED" ->
                    log("     压缩格式不支持（只认 gzip 与裸 tar）。改用 .tar.gz 重新打包。")
                "CORRUPT" ->
                    log("     压缩包损坏。重新获取并校验 sha256 后重新构建。")
                "IO_ERROR" ->
                    log("     磁盘/权限问题。检查设备剩余空间（需 >100 MB）。")
                else -> log("     见上面 message。")
            }
            log("")
        }

        log("[2/2] 改走 OCI（需要网络）…")
        val ref = DEFAULT_OCI_REF
        log("  拉取 $ref")
        runCatching {
            kotlinx.coroutines.runBlocking {
                facade.rootfs.installOci(ref) { percent, message ->
                    if (percent < 0) log("    · $message")
                    else if (percent % 20 == 0) log("    $percent% $message")
                }
            }
            log("  ✅ OCI rootfs 安装完成：${facade.rootfsSummary()}")
        }.onFailure { t ->
            log("  ❌ OCI 也失败：${t::class.java.simpleName}: ${t.message}")
            log("")
            log("  ⇒ 两条路都不通。这正是双策略存在的理由：")
            log("     · 内置：开源分发若不打包 rootfs，离线就用不了")
            log("     · OCI：没网或镜像仓库不可达时就用不了")
            log("     宿主集成时至少要保证一条可用。")
        }
        log("")
    }

    // ------------------------------------------------------- ② 执行命令

    private fun step2Execute() {
        log("=== ② 执行命令 ===")

        if (!facade.isProotReady()) {
            log("⚠️ PRoot 未就绪，先看提示：")
            log(facade.prootMissingHint())
            log("")
            return
        }

        log("--- echo hello（管道模式，非 PTY）")
        log(runCommand("echo hello", usePty = false))

        // ====================================================================
        // rootfs 内能力探测：如实报告沙箱里有什么 / 缺什么
        // ====================================================================
        // 沙箱只负责「在执行面里跑命令」。内置 rootfs 是 Alpine minirootfs，
        // 只带 busybox，所以下面大半是「缺」—— 这是基线状态，不是故障。
        //
        // 需要构建工具（JDK / Gradle / Android SDK）时，装进 **rootfs**，
        // 用 execute 在沙箱内调用；**不要**打成 APK 原生库在宿主进程跑。
        log("--- rootfs 内可用命令探测（内置 Alpine 只有 busybox）")
        log(
            runCommand(
                buildString {
                    append("for t in sh ls cp grep sed tar unzip gzip apk wget ")
                    append("gcc make python3 git java gradle aapt2 apksigner zipalign; do ")
                    append("p=\$(command -v \$t 2>/dev/null); ")
                    append("if [ -n \"\$p\" ]; then echo \"  [有] \$t -> \$p\"; ")
                    append("else echo \"  [缺] \$t\"; fi; done")
                },
                usePty = false,
            )
        )
        log("  ↑ 缺的那些是真的缺。要补就往 rootfs 里装（apk add / OCI 镜像），")
        log("    然后在沙箱内 execute —— 不是在我们自己的 APK 里塞二进制。")

        log("--- PTY 模式（测试真实终端语义：tty 应该有名字）")
        log(runCommand("echo fd0=\$(readlink /proc/self/fd/0); [ -t 0 ] && echo IS_TTY || echo NOT_TTY", usePty = true))
        log("")
    }

    /**
     * 把 suspend 的执行包成阻塞调用，返回可读文本。
     *
     * 真实宿主**不该**这样 —— 应该用回调驱动 UI（见 integration-guide）。
     * demo 里这样做只是为了让日志顺序可读。
     */
    private fun runCommand(command: String, usePty: Boolean, timeoutMs: Long = 180_000): String {
        val sb = StringBuilder()
        val latch = java.util.concurrent.CountDownLatch(1)
        val request = com.heracles.sandbox.api.ExecutionRequest(
            command = command,
            workingDirectory = "/",
            timeoutMillis = timeoutMs,
            usePty = usePty,
        )
        val callback = object : com.heracles.sandbox.api.IExecutionCallback.Stub() {
            override fun onOutput(stream: Int, chunk: String, sequence: Long) {
                sb.append(chunk)
            }

            override fun onProgress(percent: Int, message: String) = Unit

            override fun onExit(result: com.heracles.sandbox.api.ExecutionResult) {
                sb.append("\n  → exit=${result.exitCode} ${result.durationMillis}ms")
                if (result.timedOut) sb.append(" [超时]")
                if (result.cancelled) sb.append(" [已取消]")
                if (result.truncated) sb.append(" [输出已截断]")
                latch.countDown()
            }

            override fun onError(code: Int, message: String) {
                sb.append("  → 沙箱错误 code=$code: $message")
                latch.countDown()
            }

            override fun isCancelled(): Boolean = false
        }

        facade.execute(request, callback, kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO))
        latch.await(timeoutMs + 15_000, java.util.concurrent.TimeUnit.MILLISECONDS)

        val text = sb.toString().trimEnd()
        return if (text.isBlank()) "  → 无输出（可能仍在运行）" else text
    }

    // ------------------------------------------------------- ③ 读写文件

    /**
     * **两套路径视角**的对比演示 —— 沙箱里最容易出错的地方。
     *
     * 同一个字符串在两套语义下指向不同文件，这是 PRoot 的 `-b` 绑定
     * 与零宽通道叠加后的必然结果，不是 bug。
     */
    private fun step3Files() {
        log("=== ③ 读写文件 ===")

        // --- HOST 视角：App 自己的 cache，普通 App 100% 能写
        val hostPath = java.io.File(cacheDir, "demo-host.txt").absolutePath
        val payload = "hello HOST @ ${System.currentTimeMillis()}"
        log("[HOST] 写 $hostPath")
        val w = facade.files.write(hostPath, payload.toByteArray(), com.heracles.sandbox.api.PathView.HOST)
        log("  success=${w.success} size=${w.size} path=${w.path}")
        if (!w.success) log("  失败: code=${w.errorCode} ${w.errorMessage}")

        log("[HOST] 读回")
        val r = facade.files.read(hostPath, com.heracles.sandbox.api.PathView.HOST)
        log("  success=${r.success} size=${r.size}")
        log("  content=${r.asText()}")
        log("  一致: ${if (r.asText() == payload) "✅" else "❌"}")
        log("")

        // --- SANDBOX 视角：同一个字符串落到 rootfs 内
        val sandboxPath = "/workspace/demo-sandbox.txt"
        log("[SANDBOX] 同一个字符串 \"$sandboxPath\" 在沙箱视角下落点：")
        runCatching {
            log("  宿主视角等价路径 = ${facade.sandboxToHost(sandboxPath)}")
            val w2 = facade.files.write(sandboxPath, "via SANDBOX".toByteArray(), com.heracles.sandbox.api.PathView.SANDBOX)
            log("  写入 success=${w2.success} 实际路径=${w2.path}")
            if (!w2.success) log("  失败: code=${w2.errorCode} ${w2.errorMessage}")
        }.onFailure { t ->
            log("  （需要先装 rootfs：${t.message}）")
        }
        log("")
        log("★ 结论：字符串一样，文件不同。execute 里看到的是沙箱视角，")
        log("  readFile(HOST) 看到的是宿主视角 —— AIDL 的 pathView 必填就是为了这个。")
        log("")
    }

    // ------------------------------------------------------- ④ 查通道

    private fun step4Channels() {
        log("=== ④ 四条通道 ===")
        val channels = facade.queryChannels()
        if (channels.isEmpty()) {
            log("⚠️ 没拿到通道（channel 模块未初始化）")
            return
        }
        channels.forEach { info ->
            log("")
            log("[${info.channelType?.name ?: "?"}] ${info.displayName}")
            log("  available = ${info.available}  risk = ${info.risk?.name ?: "?"}")
            log("  identity  = ${info.executionIdentity}")
            log("  pty=${info.supportsPty} crossAppData=${info.supportsCrossAppData}")
            log("  ${info.capabilitySummary}")
            if (!info.available) {
                info.missingPrerequisites.forEach { log("    缺: $it") }
            }
        }
        log("")
        log("★ 沙箱只报告「事实 + 风险」，不做 allow/deny 决策。")
        log("  放不放行是宿主的信任策略（本 demo 里见 ChannelDemo.demoPolicy）。")
        log("")
        log("本机实际可用通道: " + facade.queryChannels()
            .filter { it.available }
            .joinToString { it.channelType?.name ?: "?" })
        @Suppress("UNUSED_EXPRESSION")
        ChannelType.entries.size
        log("")
    }

    // ------------------------------------------------- ⑤ AIDL 跨进程

    /**
     * **跨进程**闭环：`bindService` → `ISandboxService` → `execute` → 读结果。
     *
     * 与 ② 的区别不是「写法不同」，而是**执行面换了进程**：
     * ② 在宿主进程里跑 `SandboxServiceCore`，⑤ 通过 binder 让 `:sandbox` 进程里的
     * `SandboxService`（ISandboxService.Stub）去跑同一个 core。
     *
     * 所以这一步骤顺带验证了一件运行时才会暴露的事：
     * **两个进程各自装了一个 core，但它们看同一个 rootfs 目录**
     * （`{filesDir}/sandbox`，filesDir 在同 App 的不同进程间是同一个路径）。
     * 也就是说 ① 在这里装好的 rootfs，⑤ 里能直接用；反过来 ⑤ 装的 ② 也能用。
     */
    private fun step5Aidl() {
        log("=== ⑤ AIDL 跨进程 ===")
        if (!aidl.bind()) {
            log("❌ 绑定失败，跳过")
            return
        }
        aidl.runDemo(command = "echo hello")
        log("")
    }

    companion object {
        private const val TAG = "SandboxDemo"

        /**
         * 默认 OCI 镜像：Alpine（~3 MB）。
         *
         * 够跑 `sh` / `echo` / 基本 busybox。要 `aapt2` 需要换镜像
         * 或装完再 `apk add`。
         */
        private const val DEFAULT_OCI_REF = "docker.io/library/alpine:3.20"
    }
}
