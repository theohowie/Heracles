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
 *           runtime/src/main/java/top/wkbin/taixu/runtime/proot/ProotCommandBuilder.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/proot/ProotMountLayout.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/EnvironmentResolver.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/RuntimePathManager.kt（路径部分）
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * PRoot 执行核心：把「沙箱视角的一次命令」翻译成「宿主视角的一条 proot 命令行」，
 * 并且用两种方式真正跑起来：
 *
 *   - [executePiped]     —— ProcessBuilder + 两条管道（stdout/stderr 分开）
 *   - [executePty]       —— [PtySession] 真 TTY（单流、行缓冲、SIGWINCH）
 *
 * 另外本文件承担**路径换算的唯一出口**（[ProotPathResolver]）：宿主视角 ↔ 沙箱视角。
 * 这是沙箱里最容易出错的语义（同一个字符串在两套语义下指向不同文件），
 * 所以刻意只允许一处实现。
 *
 * ============================================================================
 * 与上游 taixu ProotCommandBuilder 的差异（逐条）
 * ============================================================================
 * 1. **不再注入 harness/core 概念**：`ShellCommand`、`StorageMountBinding`、
 *    `ConnectionIdentity`、`hostCredential`、`EnvironmentResolver.merge(provider=…)`
 *    全部去掉。改为直接吃 [ProotExecSpec]（本文件定义）。
 * 2. **不构造 `/opt/taixu` 绑定**（那是 taixu 的插件/工具目录）。
 *    沙箱只需要 `/workspace`、`/root`、`/tmp`、`/attachments` 四个绑定。
 * 3. **不构造 `/attachments` 的 `mkdirs()` 副作用**。上游在 build() 里做 IO
 *    （`attachmentsDir.mkdirs()`），这让「纯参数构造」不能用于单元测试。
 *    这里目录创建集中在 [ProotEngine.ensureHostDirs]，build 本身无副作用。
 * 4. **不构造 `.l2s` 反向绑定**（`--link2symlink` 的 backing store 自绑定）。
 *    沙箱用 `--link2symlink` 但把 backing store 放在 rootfs 外的
 *    `PROOT_L2S_DIR`（由环境变量指定），因此不需要额外 `-b`。
 *    理由：把 l2s 目录放进 rootfs 内部会污染 `-r` 的树、影响 sha256 快照口径。
 * 5. **不加 `--sysvipc`**。上游是因为要跑 apt/dpkg 的 System V IPC 场景；
 *    沙箱默认更保守（少一个内核接口暴露面），需要时用 [ProotExecSpec.extraFlags]。
 * 6. **不加 `-q`（QEMU）路径**。沙箱定死 arm64-v8a（见 build.gradle.kts）。
 * 7. **存储挂载（`/sdcard`）不从 Room 表读**。沙箱没有 Room；
 *    [SandboxDependencies] 也没有注入存储绑定。本文件只接受调用方显式传入的
 *    [BindMount] 列表，且**逐条做越界校验**。
 * 8. **环境变量不再拼进 shell 命令串**（上游 `export K=V; cmd`）。
 *    这里直接把环境变量交给 execve（PTY 路径）或 ProcessBuilder.environment()
 *    （管道路径）—— 这才是正确做法：上游那样做会让命令串里出现明文凭据，
 *    一旦命令被回显（set -x / 错误信息）就泄漏了。
 * 9. **不调用 `syncGuestGroups` / `hostSupplementaryGroupIds`**（那是为了消除
 *    bash 登录时的 "cannot find name for group ID" 噪音）。沙箱不用登录 shell。
 *
 * ============================================================================
 * 语义红线
 * ============================================================================
 * - 沙箱内**绝不**用 `-0`（--change-id=0:0）以外的身份。PRoot 的 -0 让沙箱内
 *   看起来是 root，但冻结在宿主 App 的 uid 上 —— 这正是「无 root 但有 root 观感」
 *   的全部含义。
 * - 绑定**只允许**本文件 [ALLOWED_BIND_TARGETS] 里的 guest 路径，防止调用方
 *   （或未来的注入方）把 `/data/data` 之类的宿主路径绑进沙箱。
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.io.IOException
import java.nio.file.Path
import java.nio.file.Paths
import java.util.TimeZone
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** 沙箱内默认工作目录（顶层常量，让 [ProotExecSpec] 的默认参数可用）。 */
const val DEFAULT_SANDBOX_WORKING_DIRECTORY = "/workspace"

/** 一次 PRoot 执行的参数（宿主/沙箱两套视角都已显式化）。 */
data class ProotExecSpec(
    /** 沙箱内 `sh -lc` 要执行的命令串 */
    val commandLine: String,
    /** 沙箱视角的工作目录，默认 /workspace */
    val workingDirectory: String = DEFAULT_SANDBOX_WORKING_DIRECTORY,
    /** 叠加在基础环境之上的环境变量（沙箱视角的值） */
    val environment: Map<String, String> = emptyMap(),
    /** <= 0 表示不超时 */
    val timeoutMillis: Long = 0L,
    /** 额外绑定（调用方显式给出，逐条校验 guest 目标是否在白名单内） */
    val extraBinds: List<BindMount> = emptyList(),
    /** 额外的 proot 参数（如 --sysvipc）；默认空 */
    val extraFlags: List<String> = emptyList(),
    /** PTY 列数/行数（仅 PTY 路径使用） */
    val columns: Int = 80,
    val rows: Int = 24,
)

/** 一条 PRoot 绑定：宿主绝对路径 -> 沙箱内 guest 路径。 */
data class BindMount(
    val hostPath: String,
    val guestPath: String,
    /** guest 路径是否有合法形态（由 [ProotEngine.validateBind] 用的白名单校验） */
) {
    override fun toString(): String = "$hostPath:$guestPath"
}

/** 一次执行的结果（与 AIDL 的 ExecutionResult 对齐但去掉 channel 字段）。 */
data class ProotResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
    val durationMillis: Long,
    val timedOut: Boolean,
    val cancelled: Boolean,
    val truncated: Boolean,
) {
    val isSuccess: Boolean get() = exitCode == 0 && !timedOut && !cancelled
}

/** 输出回调：由 [ProcessRegistry] / [SandboxServiceCore] 接到 IExecutionCallback。 */
fun interface ProotOutputListener {
    /** @param stream 1=stdout 2=stderr（与 IExecutionCallback.STREAM_* 一致） */
    fun onOutput(stream: Int, chunk: String)
}

/**
 * PRoot 执行核心。
 *
 * 不持有任何状态（除了不可变的路径与二进制位置），因此可以安全地被多个执行
 * 并发共用；并发/生命周期由上层的 [ProcessRegistry] 管理。
 *
 * @param prootBinary 宿主视角的 proot 可执行文件（来自 nativeLibraryDir 或 filesDir）
 * @param loaderBinary PRoot 的外部 loader（`PROOT_LOADER`）
 * @param rootfsHostRoot 宿主视角的 rootfs 根目录
 * @param workspaceHostRoot 宿主视角的 workspace 目录（绑到 guest /workspace）
 * @param homeHostRoot 宿主视角的 home 目录（绑到 guest /root）
 * @param tmpHostRoot 宿主视角的 tmp 目录（绑到 guest /tmp）
 * @param attachmentsHostRoot 宿主视角的附件目录（绑到 guest /attachments）
 * @param eventSink 可选事件上报（rootfs/exec 生命周期事件）
 */
class ProotEngine(
    val prootBinary: File,
    val loaderBinary: File?,
    val rootfsHostRoot: File,
    val workspaceHostRoot: File,
    val homeHostRoot: File,
    val tmpHostRoot: File,
    val attachmentsHostRoot: File,
    private val eventSink: EventSink = NoOpEventSink,
) {

    /**
     * 便捷构造器：`ProotEngine(context, rootfsManager)`。
     *
     * 自动从下列**约定位置**取二进制与目录（都在 App 私有目录内）：
     *   - PRoot 主程序：`{nativeLibraryDir}/libproot.so`
     *     （Android 10+ 禁止从 filesDir execve，所以必须走 APK 的 native lib 目录，
     *      这也正是 taixu 用 `libproot.so` 这个名字的原因）
     *   - PRoot loader ：`{nativeLibraryDir}/libproot-loader.so`
     *   - rootfs       ：[RootfsManager.rootfsDir]
     *   - workspace / home / tmp / attachments：`{filesDir}/sandbox/<name>`
     *
     * ⚠️ **找不到 `libproot.so` 时不会抛异常**：本构造器总是能建出对象，
     * 由 [isProotUsable] 报告可用性，[executePiped]/[executePty] 在真正执行时
     * 才失败并给出明确错误码（CODE_INTERNAL）。理由：宿主需要在「PRoot 还没
     * 打进 APK」时也能查询诊断信息，构造期就抛会让 demo 无法启动。
     *
     * 需要自定义路径（测试、多环境）时用主构造器 —— 路径必须由调用方显式给出。
     */
    constructor(context: android.content.Context, rootfsManager: RootfsManager) : this(
        prootBinary = File(context.applicationInfo.nativeLibraryDir, BUNDLED_PROOT_NAME),
        loaderBinary = File(context.applicationInfo.nativeLibraryDir, BUNDLED_PROOT_LOADER_NAME),
        rootfsHostRoot = rootfsManager.rootfsDir,
        workspaceHostRoot = File(context.filesDir, "$DEFAULT_BASE_DIR_NAME/$WORKSPACES_DIR_NAME"),
        homeHostRoot = File(context.filesDir, "$DEFAULT_BASE_DIR_NAME/$HOME_DIR_NAME"),
        tmpHostRoot = File(context.filesDir, "$DEFAULT_BASE_DIR_NAME/$TMP_DIR_NAME"),
        attachmentsHostRoot = File(context.filesDir, "$DEFAULT_BASE_DIR_NAME/$ATTACHMENTS_DIR_NAME"),
    )

    // ========================================================================
    // 环境变量组装
    // ========================================================================

    /**
     * 宿主侧进程环境（**给 proot 二进制自己**用的，不是给 guest 用的）。
     *
     * 这里必须**极简**：绝不能把宿主 App 的环境整个传下去 —— 那会把
     * `ANDROID_*`、甚至某些厂商注入的凭据变量带进沙箱进程树。
     */
    fun hostEnvironment(): Map<String, String> = buildMap {
        put("PROOT_L2S_DIR", File(rootfsHostRoot.parentFile ?: rootfsHostRoot, L2S_DIR_NAME)
            .apply { if (!exists()) mkdirs() }
            .absolutePath)
        loaderBinary?.takeIf { it.isFile && it.canRead() && it.length() > 0 }?.let {
            put("PROOT_LOADER", it.absolutePath)
        }
        // proot 自己会在 tmp 里放解压后的 loader；必须指向 App 私有可写目录
        // （Android 上没有 /tmp）。
        val tmp = tmpHostRoot.absolutePath
        put("TMPDIR", tmp)
        put("TMP", tmp)
        put("TEMP", tmp)
        put("PROOT_TMP_DIR", tmp)

        // ====================================================================
        // ★ TZ —— 必须放在**宿主进程环境**里，而不是 guestEnvironment()
        // ====================================================================
        // 为什么放这里就够：PRoot 默认把**自己的 environ 原样透传**给被 trace 的
        // guest 子进程，而两条执行路径都以本函数为**唯一**环境来源：
        //   - [executePiped]：`environment().clear()` + `putAll(hostEnvironment())`
        //   - [executePty]  ：`PtySession.open(envp = hostEnvironment())`（整体替换）
        // ⇒ 在这里设一次，管道与 PTY 两条路都继承到 guest。
        //
        // ★ 值 = **POSIX TZ 串**（如 `CST-8`），不是 IANA 命名时区。
        //   （D5 = A，ADR-039；证据见 .docs/实测-19-沙箱时区.md）
        //
        //   为什么换掉命名时区：内置 Alpine rootfs **没有 zoneinfo 数据库**
        //   （实测：`tar -tzf rootfs-bundle.bin` 518 条目里 zoneinfo/localtime/tzdata
        //    匹配 0 条；设备上 `ls /usr/share/zoneinfo` = No such file or directory）。
        //   于是命名时区（`Asia/Shanghai`）虽然透传成功，但 guest 的 libc 查不到
        //   该 id 只能回退 UTC —— 真机实测 `date` 恒为 UTC（TZPROBE 证据在实测-19 §5）。
        //   而 POSIX 固定偏移串**不依赖 zoneinfo**：同一 rootfs / 同一 proot 命令下
        //   实测 `TZ=CST-8 date` = 21:11:05 CST（实测-19 §7），这是选它的全部理由。
        //
        //   取舍（已写进 ADR-039，不要在这里偷偷放宽）：
        //   - 偏移在**每次执行**时按设备当前偏移重算 ⇒ 设备切时区后沙箱自然跟随；
        //   - POSIX 串里没有 DST 规则 ⇒ 若沙箱内进程跨过设备夏令时切换点会差 1 小时。
        //     中国无 DST ⇒ 恒正确；有 DST 的地区按"注入时刻的真实偏移 + 对应缩写"
        //     生成（见 [posixTzFor]），切换点之前的读数是对的。
        //   - rootfs 内**不做** shell 探测（探不探测结论都是"无 zoneinfo"，白花一次
        //     exec 与 PTY 开销，且会让纯函数无法单测）。
        val tz: String = posixTzFor(System.currentTimeMillis(), TimeZone.getDefault().id)
        if (tz.isNotBlank()) {
            put("TZ", tz)
        }

        // ====================================================================
        // ★ LD_LIBRARY_PATH —— 真机上踩过的坑，别删
        // ====================================================================
        // Termux 的 proot 是动态链接的，DT_NEEDED 里有 `libtalloc.so.2`。
        // 我们把 talloc 作为 `libtalloc.so` 打进 APK 的 jniLibs，Android 会把它
        // 解到 `nativeLibraryDir`（`/data/app/.../lib/arm64/`）。
        //
        // 但 nativeLibraryDir **不在** 动态链接器的默认搜索路径里：
        // `dlopen`/`execve` 解析 DT_NEEDED 时只找 `/system/lib64`、vendor 等，
        // 所以直接 exec 会报：
        //     CANNOT LINK EXECUTABLE "...": library "libtalloc.so.2" not found
        //
        // 两条修法，这里都用上了：
        //   a) 把 prootDir 加进 LD_LIBRARY_PATH（本段）；
        //   b) 把二进制里的 DT_NEEDED 从 `libtalloc.so.2` 补成 `libtalloc.so`
        //      （见 tools/fetch-proot.sh 的 patch 步骤 —— 因为两种文件名
        //       都要能被同一个 linker 找到，只做 (a) 时 SONAME 仍是 .so.2）。
        //
        // 同时把 loader 所在目录也带上：loader 若依赖别的库也是同一问题。
        prootBinary.parentFile?.let { dir ->
            val extra = buildList {
                add(dir.absolutePath)
                loaderBinary?.parentFile?.takeIf { it != dir }?.let { add(it.absolutePath) }
            }.distinct().joinToString(":")
            // 只**追加**，不覆盖宿主可能已经设好的（防御性：某些 ROM 会预置
            // 厂商库路径，覆盖掉会让 proot 找不到 bionic 的依赖）。
            val existing = System.getenv("LD_LIBRARY_PATH")?.takeIf { it.isNotBlank() }
            put("LD_LIBRARY_PATH", if (existing != null) "$extra:$existing" else extra)
        }

        // PRoot 需要知道宿主 linker config（Android 专有布局）。
        // 注意：**不**提供 PROOT_LOADER_32 —— 本沙箱只跑 arm64-v8a，
        // 设成空串会让 proot 尝试加载空路径，比不设更坏。
    }

    /**
     * Guest 侧环境（**沙箱内**进程看到的环境）。
     *
     * 只放最小可用集合 + 调用方叠加。刻意**不**继承宿主环境。
     *
     * @param interactive true 表示 PTY 交互（TERM 用 xterm-256color）；
     *                    false 表示一次性命令（TERM=dumb，并设非交互标志）
     */
    fun guestEnvironment(
        interactive: Boolean,
        overlay: Map<String, String> = emptyMap(),
    ): Map<String, String> = buildMap {
        put("HOME", GUEST_HOME)
        put("LANG", "C.UTF-8")
        put("LC_ALL", "C.UTF-8")
        put("TMPDIR", "/tmp")
        put("PATH", GUEST_PATH)
        put("TERM", if (interactive) "xterm-256color" else "dumb")
        if (!interactive) {
            put("DEBIAN_FRONTEND", "noninteractive")
            put("CI", "true")
            put("NONINTERACTIVE", "1")
        }
        // 调用方叠加放在最后：宿主注入的变量优先级最高，但绝不能覆盖 PATH/HOME
        // 这类会让沙箱彻底跑不起来的键 —— 见下方过滤。
        overlay.forEach { (key, value) ->
            if (key in PROTECTED_GUEST_KEYS) return@forEach
            require(ENVIRONMENT_KEY.matches(key)) { "非法环境变量名：$key" }
            put(key, value)
        }
    }

    // ========================================================================
    // 命令行构造（**无副作用**，可单测）
    // ========================================================================

    /**
     * 构造完整的 proot 命令行（含 argv[0]）。
     *
     * 无副作用：不 mkdirs、不读文件内容、不访问网络。
     *
     * @param interactive 是否交互（PTY）。影响 guest 的 SHELL 调用方式：
     *                    一次性命令用 `sh -lc`，交互用 `sh -l`（直接交给 PTY）
     */
    fun buildCommandLine(spec: ProotExecSpec, interactive: Boolean): List<String> = buildList {
        add(prootBinary.absolutePath)

        // ---- PRoot 行为开关 ----
        // --kill-on-exit：proot 退出时杀掉它的 tracee，避免残留进程
        add("--kill-on-exit")
        // --link2symlink：宿主文件系统（FUSE/sdcardfs）不允许硬链接，proot 用
        //   「符号链接 + 副本」模拟。apt/dpkg 没有它会直接失败。
        add("--link2symlink")
        // -L：让 proot 通过 loader 执行 guest 二进制（Android 上没有 binfmt_misc）
        add("-L")
        // --kernel-release：伪装 guest 内核版本（很多 postinst 脚本会做判断）
        add("--kernel-release=$GUEST_KERNEL_RELEASE")
        // -0：在 guest 内以 root(0:0) 身份出现，但**冻结在宿主 App 的 uid**
        //
        // ★ 真机踩坑：`-0` 与 `--change-id=0:0` **不能同时给**。两者在 proot 里
        //   是同一组互斥选项（-i / -0 / -S），同时给会在**每次执行**的 stderr 里
        //   打两行警告：
        //       proot warning: option -i/-0/-S was already specified
        //       proot info: only the last -i/-0/-S option is enabled
        //   这会污染命令的 stderr 捕获（宿主会把它们当成命令输出），
        //   所以只保留 `-0`（它本身就等价于 `--change-id=0:0`）。
        add("-0")

        // ---- 根文件系统 ----
        add("-r")
        add(rootfsHostRoot.absolutePath)

        // ---- 标准绑定：/dev /proc /sys 是 proot 自己会处理的伪文件系统，
        //      这里显式绑定的目的是「让 guest 看得见宿主的」（Android 专有布局）。----
        HOST_SYSTEM_BINDINGS
            .filter { path -> File(path).let { it.exists() && it.canRead() } }
            .forEach { path ->
                add("-b")
                add(path)
            }

        // ---- 沙箱自有绑定：/tmp /workspace /root /attachments ----
        add("-b")
        add("${tmpHostRoot.absolutePath}:/tmp")
        add("-b")
        add("${workspaceHostRoot.absolutePath}:/workspace")
        add("-b")
        add("${homeHostRoot.absolutePath}:/root")
        add("-b")
        add("${attachmentsHostRoot.absolutePath}:/attachments")


        // ---- 调用方额外绑定：逐条白名单校验 ----
        spec.extraBinds.forEach { bind ->
            val validated = validateBind(bind)
            add("-b")
            add(validated)
        }

        // ---- 调用方额外开关 ----
        spec.extraFlags.forEach { flag ->
            require(SAFE_EXTRA_FLAG.matches(flag)) { "非法的额外 proot 参数：$flag" }
            add(flag)
        }

        // ---- 工作目录（沙箱视角）----
        add("-w")
        add(spec.workingDirectory)

        // ---- guest shell + 命令 ----
        add(GUEST_SHELL)

        if (interactive) {
            // 交互：直接 exec 一个登录 shell，输入靠 PTY 喂
            add("-l")
        } else {
            // 一次性命令：-l 读 profile（PATH 等），-c 执行命令串
            add("-lc")
            add(spec.commandLine)
        }
    }

    /**
     * 校验一条绑定，返回 `host:guest` 形式。
     *
     * 红线：guest 目标必须在 [ALLOWED_BIND_TARGETS] 或其子路径内。这条校验是
     * 「防挂载逃逸」的最后一道防线 —— 即使调用方被污染，也不允许它把
     * `/data/data` 之类绑进沙箱。
     */
    fun validateBind(bind: BindMount): String {
        val guest = bind.guestPath.trim()
        if (!guest.startsWith("/")) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "绑定目标必须是沙箱内绝对路径：$guest",
            )
        }
        if (guest.split('/').any { it == ".." }) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "绑定目标不允许包含 ..：$guest",
            )
        }
        val normalizedGuest = normalizeGuestPath(guest)
        val allowed = ALLOWED_BIND_TARGETS.any { target ->
            normalizedGuest == target || normalizedGuest.startsWith("$target/")
        }
        if (!allowed) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "绑定目标 $normalizedGuest 不在允许列表内（只允许 ${ALLOWED_BIND_TARGETS.joinToString()} " +
                    "及其子路径）；如需挂载宿主目录请在宿主侧另建副本。",
            )
        }

        val host = File(bind.hostPath)
        if (!host.isAbsolute) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "绑定源必须是宿主绝对路径：${bind.hostPath}",
            )
        }
        val canonical = try {
            host.canonicalFile
        } catch (failure: IOException) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "无法解析绑定源路径：${bind.hostPath}",
                failure,
            )
        }
        if (!canonical.exists()) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "绑定源不存在：${canonical.absolutePath}",
            )
        }
        return "${canonical.absolutePath}:$normalizedGuest"
    }

    /** 把沙箱视角路径规范成 `/a/b` 形式（折叠 . 与重复斜杠，保留 .. 交给上层拒绝）。 */
    fun normalizeGuestPath(path: String): String {
        val parts = path.split('/').filter { it.isNotEmpty() && it != "." }
        return "/" + parts.joinToString("/")
    }

    // ========================================================================
    // 执行：管道路径
    // ========================================================================

    /**
     * 用两条管道执行（stdout / stderr 分开）。
     *
     * 适用于「一次性有界命令」：输出需要区分流、不需要 TTY 语义。
     *
     * 实现要点（都来自实测踩坑）：
     * - 退出后给排水加**超时**：`sh -c 'server &'` 这类命令会让孙进程继承管道
     *   写端，主进程退出后 EOF 永不到来，无限挂起会把 Agent 卡死。
     * - 超时/取消时先 SIGTERM 进程组，宽限后 SIGKILL，并**保留已读输出**
     *   （否则用户只看到一句 timeout，前面的诊断信息全丢）。
     * - 读循环用 runInterruptible：阻塞 read 只能靠线程中断打破。
     */
    suspend fun executePiped(
        spec: ProotExecSpec,
        scope: CoroutineScope,
        listener: ProotOutputListener? = null,
        cancelSignal: () -> Boolean = { false },
    ): ProotResult = withContext(Dispatchers.IO) {
        val startedAt = System.nanoTime()
        val argv = buildCommandLine(spec, interactive = false)
        val process = try {
            ProcessBuilder(argv)
                .directory(File("/"))
                .apply {
                    environment().clear()
                    environment().putAll(hostEnvironment())
                }
                .redirectErrorStream(false)
                .start()
        } catch (failure: IOException) {
            throw SandboxException(
                SandboxException.CODE_IO,
                "无法启动 PRoot：${failure.message}（proot=${prootBinary.absolutePath}）",
                failure,
            )
        }

        // 立即关闭子进程 stdin：任何意外读到 stdin 的命令都不会因为等输入而挂死。
        runCatching { process.outputStream.close() }

        val capture = CaptureBuffer(MAX_CAPTURE_BYTES)
        val stdoutDeferred = scope.async(Dispatchers.IO) {
            runInterruptible {
                drain(process.inputStream, STREAM_STDOUT, listener, capture.stdout)
            }
        }
        val stderrDeferred = scope.async(Dispatchers.IO) {
            runInterruptible {
                drain(process.errorStream, STREAM_STDERR, listener, capture.stderr)
            }
        }
        var timedOut = false
        var cancelled = false
        val exitCode: Int
        try {
            val deadline = if (spec.timeoutMillis > 0) {
                System.nanoTime() + spec.timeoutMillis * 1_000_000
            } else {
                Long.MAX_VALUE
            }
            // 轮询等待：既支持超时也支持取消信号。
            while (true) {
                val exited = runInterruptible { process.waitFor(POLL_WAIT_MILLIS, java.util.concurrent.TimeUnit.MILLISECONDS) }
                if (exited) break
                if (cancelSignal()) {
                    cancelled = true
                    stopProcessTree(process)
                    break
                }
                if (System.nanoTime() >= deadline) {
                    timedOut = true
                    stopProcessTree(process)
                    break
                }
                if (!scope.isActive) {
                    cancelled = true
                    stopProcessTree(process)
                    break
                }
            }
            exitCode = runCatching { process.exitValue() }.getOrDefault(SandboxException.CODE_TIMEOUT)
        } catch (failure: Throwable) {
            // 任何读取/等待异常都要先收掉进程树，绝不留下后台进程。
            runCatching { stopProcessTree(process) }
            throw failure
        }

        // 排水：给一个宽限期拿完剩余输出，超时就放弃（孙进程持管道场景）。
        val drained = withTimeoutOrNull(OUTPUT_DRAIN_MILLIS) {
            listOf(stdoutDeferred, stderrDeferred).awaitAll()
        }
        if (drained == null) {
            stdoutDeferred.cancel()
            stderrDeferred.cancel()
        }

        val duration = (System.nanoTime() - startedAt) / 1_000_000
        ProotResult(
            exitCode = if (timedOut || cancelled) exitCode.coerceAtLeast(1) else exitCode,
            stdout = capture.stdout.text(),
            stderr = capture.stderr.text(),
            durationMillis = duration,
            timedOut = timedOut,
            cancelled = cancelled,
            truncated = capture.stdout.truncated || capture.stderr.truncated,
        )
    }

    /** 等 200ms 让进程自己退；没退就 SIGTERM 进程组；再没退就 SIGKILL。 */
    private suspend fun stopProcessTree(process: Process) {
        // Java 的 Process 抽象拿不到进程组 id，只能 destroy()（SIGTERM 单进程）。
        // 真正的进程组回收由 [ProcessTreeReaper] 在 ProcessRegistry 层做。
        process.destroy()
        val exited = runCatching {
            process.waitFor(PROCESS_STOP_GRACE_MILLIS, java.util.concurrent.TimeUnit.MILLISECONDS)
        }.getOrDefault(false)
        if (!exited) {
            process.destroyForcibly()
            runCatching {
                process.waitFor(PROCESS_STOP_GRACE_MILLIS, java.util.concurrent.TimeUnit.MILLISECONDS)
            }
        }
    }

    /**
     * 排水读一个流。必须保持**非 suspend** 且跑在 runInterruptible 里：
     * 管道可能被未退出的孙进程持有导致 EOF 永不到来，只有线程中断才能打破
     * 阻塞中的 read()（InterruptedIOException，按 EOF 兜底）。
     */
    private fun drain(
        stream: java.io.InputStream,
        streamId: Int,
        listener: ProotOutputListener?,
        capture: BoundedCapture,
    ) {
        try {
            stream.use { input ->
                val buffer = ByteArray(READ_BUFFER_BYTES)
                val decoder = IncrementalUtf8Decoder(READ_BUFFER_BYTES)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    capture.append(buffer, read)
                    if (listener != null) {
                        val text = decoder.decode(buffer, read)
                        if (text.isNotEmpty()) {
                            // 回调异常绝不能让排水停止：停读会让子进程写满内核
                            // 管道缓冲（约 64KB）后永久阻塞，整棵进程树挂死。
                            runCatching { listener.onOutput(streamId, text) }
                        }
                    }
                }
                if (listener != null) {
                    val tail = decoder.finish()
                    if (tail.isNotEmpty()) runCatching { listener.onOutput(streamId, tail) }
                }
            }
        } catch (interrupted: java.io.InterruptedIOException) {
            // 超时收尾时从别的协程中断本线程 —— 按 EOF 处理，不是错误。
        } catch (failure: IOException) {
            // 同上：进程被强杀后管道关闭，属预期路径。
        }
    }

    // ========================================================================
    // 执行：PTY 路径
    // ========================================================================

    /**
     * 用真 PTY 执行（单流、行缓冲、SIGWINCH 可用）。
     *
     * 为什么需要：Java/Gradle 在 stdout 是管道时会**全量缓冲**，App 就收不到
     * 构建过程中的日志（表现为「卡住不动，最后一次性吐完」）。真 TTY 会让子
     * 进程按行 flush，日志就能流式到达。
     *
     * @param feedStdin 一次性写入 PTY 的 stdin（如 "y\n"）；空表示不喂
     */
    suspend fun executePty(
        spec: ProotExecSpec,
        scope: CoroutineScope,
        listener: ProotOutputListener? = null,
        cancelSignal: () -> Boolean = { false },
        feedStdin: String = "",
    ): ProotResult = withContext(Dispatchers.IO) {
        val startedAt = System.nanoTime()
        val argv = buildCommandLine(spec, interactive = false)

        // ====================================================================
        // ★ PTY 会话必须有自己的子作用域，不能直接把调用方的 scope 交出去
        // ====================================================================
        // [PtySession.close] 的收尾动作里有 `scope.coroutineContext.cancelChildren()`。
        // 那条语句的本意是「收掉本会话的读循环协程」，但它作用的是**交进来的那个 scope**。
        //
        // 于是「谁提供 scope」就决定了行为：
        //   - ProotEngine.execute() 每次都 new 一个一次性 scope（见那边的 `val scope`）
        //     ⇒ cancelChildren 打到的只是这个一次性 scope，无害；
        //   - SandboxServiceCore.execute() 用的是**长期存活**的 supervisor scope
        //     ⇒ cancelChildren 会把「正在执行这条命令的协程」一并取消，
        //        外层随即落入 CancellationException 分支，返回
        //        exitCode=130 / cancelled=true / durationMillis=0（那三个值是兜底分支
        //        里写死的），而命令其实已经**完整跑完、输出齐全**。
        //
        // 真机症状（2026-10-27 实测）：`② 执行命令` 的 PTY 那一步打印出了
        // `fd0=/dev/pts/0` 与 `IS_TTY`（证明命令成功），却报 `exit=130 0ms [已取消]`。
        //
        // 修法：给会话一个**只属于它自己**的子作用域。SupervisorJob(parent) 让它在
        // 调用方被取消时照样跟着取消（语义不变），而 cancelChildren 只会打到
        // 读循环协程，打不到调用方。
        val sessionScope = CoroutineScope(
            scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]),
        )
        val pty = PtySession.open(
            argv = argv,
            envp = hostEnvironment(),
            cwd = "/",
            columns = spec.columns,
            rows = spec.rows,
            scope = sessionScope,
        )

        try {
            pty.startPumping { output ->
                if (listener != null && output.text.isNotEmpty()) {
                    runCatching { listener.onOutput(STREAM_STDOUT, output.text) }
                }
            }

            // 等 shell 起来再喂 stdin；否则输入可能落在 shell 之前被吃掉。
            if (feedStdin.isNotEmpty()) {
                // 给 shell 一点时间完成初始化（读 profile / 建 TTY 控制终端）。
                kotlinx.coroutines.delay(STDIN_FEED_DELAY_MILLIS)
                runCatching { pty.writeText(feedStdin) }
            }

            val exit = pty.awaitExit(spec.timeoutMillis, cancelSignal)
            ProotResult(
                exitCode = exit.exitCode,
                stdout = "", // PTY 是单流，输出已经通过 listener 流式送出
                stderr = "",
                durationMillis = (System.nanoTime() - startedAt) / 1_000_000,
                timedOut = exit.timedOut,
                cancelled = exit.cancelled,
                truncated = false,
            )
        } catch (failure: Throwable) {
            runCatching { pty.close() }
            throw failure
        } finally {
            runCatching { pty.close() }
        }
    }

    /** 确保宿主侧目录都存在（build 本身无副作用，所以集中在这里）。 */
    fun ensureHostDirs() {
        listOf(tmpHostRoot, workspaceHostRoot, homeHostRoot, attachmentsHostRoot).forEach {
            if (!it.isDirectory && !it.mkdirs() && !it.isDirectory) {
                throw SandboxException(
                    SandboxException.CODE_IO,
                    "无法创建沙箱目录：${it.absolutePath}",
                )
            }
        }
        eventSink.onEvent(
            EventSink.CATEGORY_LIFECYCLE,
            "沙箱宿主目录已就绪",
            mapOf(
                "rootfs" to rootfsHostRoot.absolutePath,
                "workspace" to workspaceHostRoot.absolutePath,
                "tmp" to tmpHostRoot.absolutePath,
            ),
        )
    }

    /** PRoot 二进制是否可用（存在 + 可读 + 非空）。 */
    fun isProotUsable(): Boolean =
        prootBinary.isFile && prootBinary.canRead() && prootBinary.length() > MIN_BINARY_BYTES

    /** rootfs 是否至少像个 rootfs（有 os-release 或 bin/sh）。 */
    fun isRootfsUsable(): Boolean {
        if (!rootfsHostRoot.isDirectory) return false
        if (File(rootfsHostRoot, "etc/os-release").isFile) return true
        if (File(rootfsHostRoot, "usr/lib/os-release").isFile) return true
        return File(rootfsHostRoot, "bin/sh").exists() || File(rootfsHostRoot, "usr/bin/sh").exists()
    }

    // ========================================================================
    // 路径换算（给 sandbox-file 等上游模块用）
    //
    // ★ 这两个方法是**唯一的**路径换算入口。它们委托给 [ProotPathResolver]，
    //   而不是在这里再写一遍拼接逻辑 —— 路径换算的实现必须只有一份
    //   （见 SandboxDependencies.kt 里 PathResolver 的注释）。
    //
    // 语义速查：
    //   toHostPath("/workspace/a.txt")   -> "{rootfsHostRoot}/workspace/a.txt"
    //   toSandboxPath("/data/.../rootfs/workspace/a.txt") -> "/workspace/a.txt"
    // ========================================================================

    /**
     * 沙箱视角 -> 宿主视角。
     *
     * 含 **`..` 逃逸检查**：`/../../data/data` 规范化后会跑出 rootfs，直接抛
     * [SandboxException.CODE_INVALID_ARGUMENT]。
     *
     * @throws SandboxException rootfs 未就绪 / 路径不是绝对路径 / 越界
     */
    fun toHostPath(sandboxPath: String): String =
        ProotPathResolver { rootfsHostRoot }.sandboxToHost(sandboxPath)

    /**
     * 宿主视角 -> 沙箱视角；不在 rootfs 内时返回 **null**（不是抛异常 ——
     * 「这个宿主路径不归沙箱管」是正常结果，调用方需要能区分「不属于」与「出错」）。
     */
    fun toSandboxPath(hostPath: String): String? =
        ProotPathResolver { rootfsHostRoot }.hostToSandbox(hostPath)

    // ========================================================================
    // 便捷执行入口（AIDL 形状）
    // ========================================================================

    /**
     * 执行一次请求，过程通过 [IExecutionCallback] 上报 —— **非阻塞**，返回 Job。
     *
     * ⚠️ **与 [SandboxServiceCore.execute] 的分工，宿主必须知道**：
     *   - 本方法**不做** ProcessRegistry 并发准入（前台并发上限、持久进程登记、
     *     进程树回收）。它是一条「直通」路径，适合 demo / 单条命令 / 单元测试。
     *   - 生产路径应该用 [SandboxServiceCore.execute]：那里有并发上限
     *     （超限返回 CODE_BUSY）、进程账本、以及 shutdown 时的整树回收。
     *
     * 之所以两个都提供：ProotEngine 是执行核心（只该关心「怎么把命令跑起来」），
     * 而并发/生命周期属于编排层。把两者混在一起会让核心无法被单独复用。
     *
     * 错误契约（与 AIDL 一致）：前置检查失败走 [IExecutionCallback.onError]，
     * **不会**有 onExit；命令跑完（含超时/取消）走 [IExecutionCallback.onExit]。
     */
    fun execute(
        context: android.content.Context,
        request: com.heracles.sandbox.api.ExecutionRequest,
        callback: com.heracles.sandbox.api.IExecutionCallback,
    ): kotlinx.coroutines.Job {
        val scope = kotlinx.coroutines.CoroutineScope(
            kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO,
        )
        return scope.launch {
            try {
                val startedAt = System.nanoTime()

                // ---- 前置检查 ----
                if (!isRootfsUsable()) {
                    callback.onError(
                        com.heracles.sandbox.api.SandboxException.CODE_ROOTFS_NOT_READY,
                        "rootfs 未安装或不完整（${rootfsHostRoot.absolutePath}）：" +
                            "请先调用 RootfsManager.installOci() 或 useBundled()。",
                    )
                    return@launch
                }
                if (!isProotUsable()) {
                    callback.onError(
                        com.heracles.sandbox.api.SandboxException.CODE_INTERNAL,
                        "PRoot 二进制不可用（${prootBinary.absolutePath}）：" +
                            "APK 里缺少 libproot.so，或 ABI 不是 arm64-v8a。",
                    )
                    return@launch
                }
                ensureHostDirs()

                // ---- 组 spec ----
                val workingDirectory = try {
                    val normalized = normalizeGuestPath(request.workingDirectory)
                    if (".." in normalized.split('/')) {
                        callback.onError(
                            com.heracles.sandbox.api.SandboxException.CODE_INVALID_ARGUMENT,
                            "工作目录不允许包含 ..：${request.workingDirectory}",
                        )
                        return@launch
                    }
                    normalized
                } catch (failure: Throwable) {
                    callback.onError(
                        com.heracles.sandbox.api.SandboxException.CODE_INVALID_ARGUMENT,
                        "工作目录非法：${failure.message}",
                    )
                    return@launch
                }

                val overlay = buildMap {
                    request.environment.forEach { entry ->
                        val index = entry.indexOf('=')
                        if (index > 0) put(entry.substring(0, index), entry.substring(index + 1))
                    }
                }
                val spec = ProotExecSpec(
                    commandLine = request.command,
                    workingDirectory = workingDirectory,
                    environment = overlay,
                    timeoutMillis = request.timeoutMillis,
                    columns = request.ptyColumns,
                    rows = request.ptyRows,
                )

                // ---- 输出序号（单调递增，供宿主检测丢失/重排） ----
                val sequence = java.util.concurrent.atomic.AtomicLong(0)
                val listener = ProotOutputListener { stream, chunk ->
                    runCatching { callback.onOutput(stream, chunk, sequence.getAndIncrement()) }
                }
                val cancelSignal: () -> Boolean = {
                    runCatching { callback.isCancelled() }.getOrDefault(false)
                }

                // ---- 跑 ----
                val result = if (request.usePty) {
                    if (!PtySession.nativeAvailable) {
                        callback.onError(
                            com.heracles.sandbox.api.SandboxException.CODE_INTERNAL,
                            "本次请求要求 PTY（usePty=true），但 libpty_bridge.so 不可用" +
                                "（AAR 缺 arm64-v8a 产物）。请改用 usePty=false。",
                        )
                        return@launch
                    }
                    executePty(
                        spec = spec,
                        scope = scope,
                        listener = listener,
                        cancelSignal = cancelSignal,
                        feedStdin = request.inputData,
                    )
                } else {
                    executePiped(
                        spec = spec,
                        scope = scope,
                        listener = listener,
                        cancelSignal = cancelSignal,
                    )
                }

                callback.onExit(
                    com.heracles.sandbox.api.ExecutionResult(
                        exitCode = result.exitCode,
                        stdout = result.stdout,
                        stderr = result.stderr,
                        durationMillis = (System.nanoTime() - startedAt) / 1_000_000,
                        timedOut = result.timedOut,
                        cancelled = result.cancelled,
                        truncated = result.truncated,
                        channelType = request.channelType,
                    ),
                )
            } catch (cancellation: kotlinx.coroutines.CancellationException) {
                runCatching {
                    callback.onExit(
                        com.heracles.sandbox.api.ExecutionResult(
                            exitCode = 130,
                            stdout = "",
                            stderr = "执行被取消",
                            durationMillis = 0,
                            timedOut = false,
                            cancelled = true,
                            truncated = false,
                            channelType = request.channelType,
                        ),
                    )
                }
                throw cancellation
            } catch (failure: Throwable) {
                runCatching {
                    callback.onError(
                        com.heracles.sandbox.api.SandboxException.CODE_INTERNAL,
                        "执行失败：${failure.message ?: failure::class.java.simpleName}",
                    )
                }
            } finally {
                scope.coroutineContext.cancelChildren()
            }
        }
    }

    companion object {
        const val DEFAULT_WORKING_DIRECTORY = "/workspace"
        const val GUEST_HOME = "/root"
        const val GUEST_SHELL = "/bin/sh"
        const val GUEST_KERNEL_RELEASE = "6.1.0-heracles-sandbox"
        const val STREAM_STDOUT = 1
        const val STREAM_STDERR = 2

        private const val L2S_DIR_NAME = "l2s"
        private const val MIN_BINARY_BYTES = 4096L

        /**
         * PRoot 主程序在 APK native lib 目录里的文件名。
         *
         * 为什么必须叫 `lib*.so`：Android 只允许 `lib*.so` 形态的文件被解压到
         * `nativeLibraryDir`（并且 `extractNativeLibs` 打开时可执行）。taixu
         * 用的也是这个名字，来源是 Termux 的 proot 构建。
         */
        const val BUNDLED_PROOT_NAME = "libproot.so"

        /** PRoot 的外部 loader 文件名（`--link2symlink` 必需）。 */
        const val BUNDLED_PROOT_LOADER_NAME = "libproot-loader.so"

        /** `ProotEngine(context, rootfsManager)` 便捷构造器的数据根目录名。 */
        const val DEFAULT_BASE_DIR_NAME = "sandbox"

        private const val WORKSPACES_DIR_NAME = "workspaces"
        private const val HOME_DIR_NAME = "home"
        private const val TMP_DIR_NAME = "tmp"
        private const val ATTACHMENTS_DIR_NAME = "attachments"

        private const val READ_BUFFER_BYTES = 16 * 1024
        private const val MAX_CAPTURE_BYTES = 2 * 1024 * 1024
        private const val POLL_WAIT_MILLIS = 50L
        private const val PROCESS_STOP_GRACE_MILLIS = 500L
        private const val OUTPUT_DRAIN_MILLIS = 5_000L
        private const val STDIN_FEED_DELAY_MILLIS = 150L


        /** Guest 内的 PATH（不拼入 Android 的 /system/bin，避免与发行版工具冲突）。 */
        val GUEST_PATH = listOf(
            "/root/.local/bin",
            "/usr/local/sbin",
            "/usr/local/bin",
            "/usr/sbin",
            "/usr/bin",
            "/sbin",
            "/bin",
        ).joinToString(":")

        /** 调用方**不允许**覆盖的 guest 环境键（覆盖会让沙箱直接跑不起来）。 */
        // 注：TZ 也在这里 —— 时区由宿主按设备当前偏移算出的 POSIX 串决定
        //（见 hostEnvironment / posixTzFor），不允许调用方通过 overlay 把它改成
        // 沙箱内自说自话的值。
        // `internal` 仅为单测可断言（同模块 friend path），生产调用方无法触及。
        internal val PROTECTED_GUEST_KEYS =
            setOf("PATH", "HOME", "TMPDIR", "PROOT_LOADER", "PROOT_L2S_DIR", "TZ")

        private val ENVIRONMENT_KEY = Regex("[A-Za-z_][A-Za-z0-9_]*")

        /** 额外 proot 参数的白名单形态：只允许 `--flag` 或 `--flag=value`，value 不含 shell 元字符。 */
        private val SAFE_EXTRA_FLAG = Regex("--[a-z0-9][a-z0-9-]*(=[A-Za-z0-9_./:@+-]+)?")

        /**
         * 宿主侧系统路径，用于让 guest 能执行 Android 二进制 / 读 linker 配置。
         *
         * 移植自 taixu ProotMountLayout.hostSystemPaths，去掉了 `/data/misc/apexdata/...`
         * （需要更高权限，普通 App 身份读不到，绑了只会让 proot 报错）。
         *
         * ====================================================================
         * ★ `/dev` `/proc` `/sys` 必须绑 —— 真机踩过的坑
         * ====================================================================
         * 不加 `/dev` 时，PTY 路径下 guest 内的 `tty` 会回答 **"not a tty"**：
         * fork 出来的 shell 确实挂在 slave PTY 上（fd 0/1/2 都对），
         * 但 guest 里**看不到 `/dev/pts/N`**，于是 `isatty()` 找不到对应设备节点、
         * 判定失败。这会让所有交互式工具（`apt`、`vim`、带颜色的构建输出）
         * 静默退化成非交互模式 —— 很难排查，因为命令本身是"成功"的。
         *
         * `/proc` `/sys` 同理：很多程序靠它们判断环境，缺了会走错分支。
         * 这也是 proot-distro 等成熟方案的标准做法。
         */
        val HOST_SYSTEM_BINDINGS = listOf(
            // PTY 与设备节点（缺了 `tty`/`isatty()` 会判非终端）
            "/dev",
            "/dev/pts",
            // 伪文件系统
            "/proc",
            "/sys",
            "/apex",
            "/data/app",
            "/data/dalvik-cache",
            "/system",
            "/system_ext",
            "/vendor",
            "/product",
            "/odm",
            "/linkerconfig/com.android.art/ld.config.txt",
            "/linkerconfig/ld.config.txt",
            "/plat_property_contexts",
            "/property_contexts",
        )

        /** 宿主侧 linker 配置文件候选（诊断用）。 */
        val LINKER_CONFIG_PATHS = listOf(
            "/linkerconfig/com.android.art/ld.config.txt",
            "/linkerconfig/ld.config.txt",
        )

        /**
         * 允许作为 `-b` 目标的 guest 路径白名单（含其子路径）。
         *
         * 这条列表是**安全边界**：不在其中的 guest 路径一律拒绝绑定。
         */
        val ALLOWED_BIND_TARGETS = listOf(
            "/workspace",
            "/root",
            "/tmp",
            "/attachments",
            "/opt",
            "/usr/local",
            "/sdcard",
            "/data/local/tmp",
        )
    }

    /** 一次执行的两条流各自有界捕获。 */
    private class CaptureBuffer(limitBytes: Int) {
        val stdout = BoundedCapture(limitBytes)
        val stderr = BoundedCapture(limitBytes)
    }

    /**
     * 有界捕获：只保留前 N 字节，超出部分只记总数与截断标记。
     *
     * 为什么有界：一条 `find /` 可能产生几百 MB 输出，直接攒在内存里会 OOM。
     */
    private class BoundedCapture(private val limitBytes: Int) {
        private val buffer = java.io.ByteArrayOutputStream(64 * 1024)
        private var totalBytes = 0L
        var truncated = false
            private set

        fun append(bytes: ByteArray, count: Int) {
            totalBytes += count
            val remaining = limitBytes - buffer.size()
            if (remaining <= 0) {
                truncated = true
                return
            }
            val keep = minOf(count, remaining)
            buffer.write(bytes, 0, keep)
            if (keep < count) truncated = true
        }

        fun text(): String {
            val text = buffer.toString(Charsets.UTF_8.name())
            return if (!truncated) {
                text
            } else {
                "$text\n\n[输出已截断：共 $totalBytes 字节，仅保留前 ${buffer.size()} 字节]"
            }
        }
    }
}

// ============================================================================
// 路径换算
// ============================================================================

/**
 * [PathResolver] 的默认实现：宿主视角 ↔ 沙箱视角。
 *
 * 核心规则只有一条：**沙箱视角 `/x` == 宿主视角 `{rootfsHostRoot}/x`**。
 * 所有拼接都必须经过这里，禁止在别处写 `File(filesDir, "sandbox/rootfs$path")`
 * —— 那正是宿主/沙箱视角混淆的根源（见 SandboxDependencies.kt 的注释）。
 *
 * 安全边界：
 * - `sandboxToHost` 拒绝 `..` 穿越（规范化后必须仍在 rootfs 内）
 * - `hostToSandbox` 对 rootfs 外的路径返回 null（不是所有宿主路径都能映射）
 */
class ProotPathResolver(
    private val rootfsProvider: () -> File?,
) : PathResolver {

    override fun sandboxToHost(sandboxPath: String): String {
        val root = rootfsProvider() ?: throw SandboxException(
            SandboxException.CODE_ROOTFS_NOT_READY,
            "rootfs 未安装：无法换算沙箱路径 $sandboxPath",
        )
        if (!sandboxPath.startsWith("/")) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "沙箱路径必须是绝对路径：$sandboxPath",
            )
        }

        val rootPath = root.toPath().toAbsolutePath().normalize()
        val relative = sandboxPath.trimStart('/')
        val candidate = if (relative.isEmpty()) {
            rootPath
        } else {
            rootPath.resolve(relative).normalize()
        }
        // ★ 越界检查：`/../../data` 规范化后会跑到 rootfs 之外。
        if (!candidate.startsWith(rootPath)) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "沙箱路径越界（不允许 .. 穿越出 rootfs）：$sandboxPath",
            )
        }
        return candidate.toString()
    }

    override fun hostToSandbox(hostPath: String): String? {
        val root = rootfsProvider() ?: return null
        val rootPath = try {
            root.toPath().toAbsolutePath().normalize()
        } catch (_: Throwable) {
            return null
        }
        val candidate: Path = try {
            Paths.get(hostPath).toAbsolutePath().normalize()
        } catch (_: Throwable) {
            return null
        }
        if (!candidate.startsWith(rootPath)) return null
        val relative = rootPath.relativize(candidate).toString().replace('\\', '/')
        return if (relative.isEmpty()) "/" else "/$relative"
    }

    override fun rootfsHostRoot(): String? = rootfsProvider()?.absolutePath
}

// ============================================================================
// 小工具
// ============================================================================

/** `PathView` 帮助函数：把 AIDL 的 int 转成枚举后按视角换算。 */
fun ProotPathResolver.resolveFor(path: String, pathView: PathView): String = when (pathView) {
    PathView.SANDBOX -> sandboxToHost(path)
    PathView.HOST -> path
}

// ============================================================================
// 时区：POSIX TZ 串（D5 = A，ADR-039）
// ============================================================================
// 为什么是 POSIX 固定偏移而不是 IANA 命名时区（实测结论，别在这里翻案）：
//   内置 Alpine rootfs **没有 zoneinfo 数据库**（518 条目 0 匹配；设备上
//   `/usr/share/zoneinfo` 不存在）⇒ 命名时区透传成功但 guest 的 libc 查不到，
//   只能回退 UTC（真机 `date` 恒 UTC）。POSIX 串（`CST-8`）不查 zoneinfo，
//   同一 rootfs 实测有效（21:11:05 CST）。证据：.docs/实测-19-沙箱时区.md。
//
// 取舍（保守，不擅自发明）：
//   - 只对 [TZ_ABBREVIATIONS] 里**可信收录**的时区生成 POSIX 串；
//   - 未收录的时区**退回命名 id**（即改动前的行为）。此时 guest 会显示 UTC ——
//     这是已知且已报告的降级，不编造缩写（比如把没收录的时区硬凑成 CET）；
//   - 名字必须能过 POSIX 解析：只收 3–4 个纯字母的缩写，且**绝不**用
//     `UTC` / `GMT` 打头再挂非零偏移 —— 实测 `TZ=UTC-8` 两次表现不一致
//     （一次 0 偏移、一次 +8），属命名歧义。
// ============================================================================

/** 一条时区缩写：标准时缩写 + 夏令时缩写（null = 该时区不实行夏令时或未收录）。 */
internal data class TzAbbreviation(
    val standard: String,
    val daylight: String? = null,
)

/**
 * 按**注入时刻**的设备偏移生成 POSIX TZ 串。
 *
 * 例：`Asia/Shanghai` → `CST-8`；`America/New_York` 冬季 → `EST+5`、
 * 夏季（DST 生效）→ `EDT+4`；`Asia/Kolkata` → `IST-5:30`；`UTC` → `UTC+0`。
 *
 * 语义要点：
 * - 符号按 POSIX 约定**取反**：POSIX 的 `±hh[:mm]` 是「本地时间在 UTC 之**西**多少」，
 *   所以东八区（UTC+8）写成 `CST-8`，西五区（UTC-5）写成 `EST+5`。
 * - 偏移取 `TimeZone.getOffset(nowUtcMs)`（**带夏令时**的实际偏移），不是
 *   `getRawOffset()`（只有标准时，夏季会差 1 小时）。
 * - 缩写只影响 `date` 打印的名字，不影响时间；映射表缺夏令时缩写时退回标准时
 *   缩写（时间仍正确，只有名字在 DST 期间不贴合）。
 * - `zoneId` 为空 ⇒ 返回空串（调用方据此不注入 TZ）；未知 id ⇒ 返回原 id
 *   （降级为命名时区，见本节头部取舍）。
 *
 * @param nowUtcMs 用来求偏移的 UTC 时刻（毫秒）；测试注入固定值即可锁死夏/冬季
 * @param zoneId IANA 时区 id（Android 上是 `TimeZone.getDefault().id`）
 */
internal fun posixTzFor(nowUtcMs: Long, zoneId: String): String {
    val id = zoneId.trim()
    if (id.isEmpty()) return ""
    val zone = TimeZone.getTimeZone(id)
    // 未知 id 时 Java 静默返回 GMT 兜底（返回对象的 id 变成 "GMT"，与请求串不同），
    // 用它区分「认得的 id」与「不认得的 id」，避免把未知时区当成 UTC 处理。
    if (zone.id != id) return id
    val label = TZ_ABBREVIATIONS[id] ?: return id
    val offsetMillis = zone.getOffset(nowUtcMs)
    // 夏令时判定：偏移与标准时偏移不同 ⇒ 当前处于夏令时。
    // 只在该时区收录了夏令时缩写时才换名字，否则沿用标准时缩写（时间不受影响）。
    val daylightActive = label.daylight != null && offsetMillis != zone.rawOffset
    val name = if (daylightActive) label.daylight ?: label.standard else label.standard
    return name + formatPosixOffset(offsetMillis)
}

/**
 * 把毫秒偏移格式化成 POSIX 的 `±hh[:mm]` 片段（**符号取反**，见 [posixTzFor]）。
 *
 * `+05:30` → `-5:30`（因为 POSIX 说「西为正」）；`0` → `+0`；`-5h` → `+5`。
 */
private fun formatPosixOffset(offsetMillis: Int): String {
    val totalMinutes = offsetMillis / MILLIS_PER_MINUTE
    val sign = if (totalMinutes > 0) "-" else "+"
    val absolute = kotlin.math.abs(totalMinutes)
    val hours = absolute / 60
    val minutes = absolute % 60
    return if (minutes == 0) "$sign$hours" else "$sign$hours:$minutes"
}

private const val MILLIS_PER_MINUTE = 60_000

/**
 * 时区 id → 可信缩写（POSIX 名字）。
 *
 * 收录原则：
 * - 只用**3–4 个纯字母**的缩写（POSIX 名字部分的合法形态）；
 * - 缩写按 tzdata 口径（与设备 `date` 的传统缩写一致），中国 = `CST`；
 * - 有夏令时的地区同时给 `daylight`；已废除夏令时的地区只给 `standard`
 *   （如 `America/Mexico_City`、`America/Sao_Paulo`）；
 * - 只收录常见时区。**没收录不是漏了**，是刻意退回命名 id 的保守取舍。
 *
 * 注意：缩写与偏移是两件事 —— 时间由偏移决定、永远按设备当前偏移算；
 * 缩写只决定 `date` 打印出来的名字。所以某个名字写得不够贴切不会让时间错。
 */
internal val TZ_ABBREVIATIONS: Map<String, TzAbbreviation> = buildMap {
    // ---- 东亚 / 东南亚（UTC+8、+9；1991 年后中国大陆无夏令时）----
    listOf(
        "Asia/Shanghai", "Asia/Chongqing", "Asia/Harbin", "Asia/Macau",
        "Asia/Taipei", "PRC", "Hongkong",
    ).forEach { put(it, TzAbbreviation("CST")) }
    put("Asia/Hong_Kong", TzAbbreviation("HKT"))
    put("Asia/Singapore", TzAbbreviation("SGT"))
    put("Asia/Tokyo", TzAbbreviation("JST"))
    put("Asia/Seoul", TzAbbreviation("KST"))
    put("Asia/Pyongyang", TzAbbreviation("KST"))
    put("Asia/Bangkok", TzAbbreviation("ICT"))
    put("Asia/Ho_Chi_Minh", TzAbbreviation("ICT"))
    put("Asia/Saigon", TzAbbreviation("ICT"))
    put("Asia/Jakarta", TzAbbreviation("WIB"))

    // ---- 南亚 / 中东 ----
    put("Asia/Kolkata", TzAbbreviation("IST"))
    put("Asia/Calcutta", TzAbbreviation("IST"))
    put("Asia/Karachi", TzAbbreviation("PKT"))
    put("Asia/Kathmandu", TzAbbreviation("NPT"))
    put("Asia/Katmandu", TzAbbreviation("NPT"))
    put("Asia/Dubai", TzAbbreviation("GST"))
    put("Asia/Baghdad", TzAbbreviation("AST"))
    put("Asia/Jerusalem", TzAbbreviation("IST", "IDT"))

    // ---- 欧洲 ----
    put("Europe/London", TzAbbreviation("GMT", "BST"))
    put("Europe/Dublin", TzAbbreviation("GMT", "IST"))
    put("Europe/Lisbon", TzAbbreviation("WET", "WEST"))
    listOf(
        "Europe/Paris", "Europe/Berlin", "Europe/Rome", "Europe/Madrid",
        "Europe/Amsterdam", "Europe/Brussels", "Europe/Vienna", "Europe/Zurich",
        "Europe/Stockholm", "Europe/Oslo", "Europe/Copenhagen", "Europe/Prague",
        "Europe/Warsaw", "Europe/Budapest", "Europe/Belgrade",
    ).forEach { put(it, TzAbbreviation("CET", "CEST")) }
    put("Europe/Moscow", TzAbbreviation("MSK"))
    put("Europe/Istanbul", TzAbbreviation("TRT"))
    listOf(
        "Europe/Athens", "Europe/Helsinki", "Europe/Bucharest",
        "Europe/Kyiv", "Europe/Kiev",
    ).forEach { put(it, TzAbbreviation("EET", "EEST")) }

    // ---- 北美（US 前缀是历史别名，Android 上仍可能被当成默认时区）----
    put("America/New_York", TzAbbreviation("EST", "EDT"))
    put("US/Eastern", TzAbbreviation("EST", "EDT"))
    put("America/Toronto", TzAbbreviation("EST", "EDT"))
    put("America/Chicago", TzAbbreviation("CST", "CDT"))
    put("US/Central", TzAbbreviation("CST", "CDT"))
    put("America/Winnipeg", TzAbbreviation("CST", "CDT"))
    put("America/Denver", TzAbbreviation("MST", "MDT"))
    put("US/Mountain", TzAbbreviation("MST", "MDT"))
    put("America/Edmonton", TzAbbreviation("MST", "MDT"))
    put("America/Phoenix", TzAbbreviation("MST"))
    put("America/Los_Angeles", TzAbbreviation("PST", "PDT"))
    put("US/Pacific", TzAbbreviation("PST", "PDT"))
    put("America/Vancouver", TzAbbreviation("PST", "PDT"))
    put("America/Anchorage", TzAbbreviation("AKST", "AKDT"))
    put("US/Alaska", TzAbbreviation("AKST", "AKDT"))
    put("Pacific/Honolulu", TzAbbreviation("HST"))
    put("US/Hawaii", TzAbbreviation("HST"))
    put("America/Halifax", TzAbbreviation("AST", "ADT"))

    // ---- 拉美（墨西哥 2022、巴西 2019 起废除夏令时）----
    put("America/Mexico_City", TzAbbreviation("CST"))
    put("America/Sao_Paulo", TzAbbreviation("BRT"))
    put("America/Argentina/Buenos_Aires", TzAbbreviation("ART"))
    put("America/Buenos_Aires", TzAbbreviation("ART"))
    put("America/Bogota", TzAbbreviation("COT"))
    put("America/Lima", TzAbbreviation("PET"))
    put("America/Santiago", TzAbbreviation("CLT", "CLST"))

    // ---- 大洋洲（南半球：夏令时在 10 月—次年 4 月）----
    listOf("Australia/Sydney", "Australia/Melbourne", "Australia/Canberra", "Australia/Hobart")
        .forEach { put(it, TzAbbreviation("AEST", "AEDT")) }
    put("Australia/Brisbane", TzAbbreviation("AEST"))
    put("Australia/Adelaide", TzAbbreviation("ACST", "ACDT"))
    put("Australia/Perth", TzAbbreviation("AWST"))
    put("Pacific/Auckland", TzAbbreviation("NZST", "NZDT"))

    // ---- 非洲 ----
    put("Africa/Cairo", TzAbbreviation("EET", "EEST"))
    put("Africa/Johannesburg", TzAbbreviation("SAST"))
    put("Africa/Lagos", TzAbbreviation("WAT"))
    put("Africa/Nairobi", TzAbbreviation("EAT"))

    // ---- UTC 家族（零偏移；`UTC+0` 在 POSIX 与「UTC 特殊名」两种解释下都等于 UTC）----
    listOf("UTC", "Etc/UTC", "Etc/GMT", "GMT", "Universal", "Zulu")
        .forEach { put(it, TzAbbreviation("UTC")) }
}
