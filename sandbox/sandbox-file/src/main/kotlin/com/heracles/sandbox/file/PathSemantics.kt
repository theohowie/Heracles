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
 *   原文件：app/src/main/kotlin/b/ai/core/Paths.kt
 *           （base() / ensure() / workspaceRoot()：全局数据根的解析与归一化）
 *   原文件：app/src/main/kotlin/b/ai/exec/Router.kt 的 normalize()
 *           （`~/` 展开、相对路径挂到数据根、`//` 折叠 —— 本文件的 normalize 移植自它）
 * 上游：taixu (wkbin/taixu) @ dc7fcddb88e565929379597bbd811b440d00e34f
 *   PRoot `-b` 绑定语义（runtime 的 ProotEngine 负责建立；
 *   本文件只负责**在类型层面**把两套视角分开，不做绑定）
 *
 * ============================================================================
 * 这个文件要解决什么问题
 * ============================================================================
 * taixu 用 PRoot 起 rootfs，并用 `-b <宿主路径>:<沙箱路径>` 把宿主目录绑进沙箱。
 * baicodex 的零宽文件通道则**直接以宿主路径**打开文件。
 * 两者合流后，**同一个字符串在两处指向不同文件**：
 *
 *   字符串 "/data/data/com.example/app.bin"
 *     在 execute 里（PRoot -b 重写后）→ 沙箱内的 /data/data/…（可能被绑到别处）
 *     在 readFile(PathView.HOST) 里        → 真实的 /data/data/…
 *     ⇒ 结果可能一个是「不存在」，另一个是「读到了」
 *
 * 光靠注释是管不住的：一个 String 从 A 函数传到 B 函数，谁也没法在
 * 编译期发现语义串了。所以本文件把两套视角做成**两个不兼容的类型**，
 * 让「把宿主路径传给沙箱函数」变成编译错误而不是线上 bug。
 *
 * ============================================================================
 * 何时用哪套（决策表）
 * ============================================================================
 * | 场景 | 该用哪个类型 | 说明 |
 * |---|---|---|
 * | ISandboxService.execute(command, workingDirectory) | SandboxPath | PRoot 内 /bin/sh 看到的路径 |
 * | execute 里命令字符串中的路径 | 原样字符串（不进类型）| 命令由沙箱内 sh 解释，天然是沙箱视角 |
 * | readFile(path, PathView.SANDBOX) | SandboxPath | 先换宿主路径再落盘 |
 * | readFile(path, PathView.HOST) | HostPath | 零宽通道直接按它打开 |
 * | 零宽通道（穿透 Android/data） | HostPath | 只有宿主视角能用零宽变换 |
 * | 宿主自己的 filesDir / cacheDir 下的文件 | HostPath | 真实 Android 路径 |
 * | 内部传给 File(...) / ProcessBuilder(...) | HostPath | 进程只认宿主视角 |
 * | rootfs 安装/解包目标 | HostPath（rootfsHostRoot）| 真实磁盘位置 |
 *
 * **一句话**：进程 API（File、ProcessBuilder、open()）只吃 HostPath；
 * 给沙箱里跑的 shell 只吃 SandboxPath。两者之间必须显式调用
 * toHost / toSandbox，中间没有隐式转换。
 *
 * ============================================================================
 * 为什么用 value class 而不是 sealed class
 * ============================================================================
 * value class 在 JVM 上会被内联成底层 String，因此：
 * - 运行时零开销（不额外分配对象）；
 * - AIDL / Parcel 边界上不需要转换（跨进程传的就是 String）；
 * - **但编译器仍然阻止**把 HostPath 传给要 SandboxPath 的地方。
 *
 * 这就是我们要的：**零运行时成本 + 编译期语义检查**。
 * sealed class 会在每个调用点产生装箱开销，而路径解析是热路径。
 */

package com.heracles.sandbox.file

import com.heracles.sandbox.api.PathView
import com.heracles.sandbox.api.SandboxException

/**
 * **宿主视角**路径：真实 Android 文件系统上的绝对路径。
 *
 * <p>例：`/data/data/com.theohowie.heracles/files/sandbox/rootfs/workspace/a.txt`
 * 或 `/sdcard/Download/b.txt` 或 `/storage/emulated/0/Android/data/com.x/files`。
 *
 * <p>**不变量**：构造后保证是非空、以 `/` 开头的绝对路径，且已做 `..` 折叠与
 * `//` 归一化（见 normalizeHost）。因此任何 HostPath 都可以安全地
 * `File(value)` 打开 —— 但仍可能因 Unix 权限/SELinux 失败，
 * 那是运行时的事，不是类型的事。
 *
 * <p>**绝不**把这个类型传进任何「在沙箱内执行」的 API：
 * 宿主路径在沙箱里可能根本不存在（rootfs 只绑定了几个目录）。
 */
@JvmInline
value class HostPath(val value: String) {

    /** 供日志/错误信息使用的展示形态（与 [value] 相同，语义上区分用途）。 */
    override fun toString(): String = value

    /** 对应的 [PathView] wire 值（AIDL 用）。 */
    val pathView: PathView get() = PathView.HOST

    /** 取父目录；已在根目录时返回自身。 */
    fun parent(): HostPath = HostPath(value.substringBeforeLast('/', "/").ifEmpty { "/" })

    /** 文件名（最后一段）。 */
    fun name(): String = value.substringAfterLast('/')

    /** 是否物理位于 [root] 之下（含 root 自身）。用路径段比较，避免 /a/bc 误匹配 /a/b。 */
    fun isUnder(root: HostPath): Boolean {
        val r = root.value.trimEnd('/')
        return value == r || value.startsWith("$r/")
    }

    /** 相对 [root] 的路径；不在其下时返回 null。 */
    fun relativeTo(root: HostPath): String? {
        val r = root.value.trimEnd('/')
        return when {
            value == r -> ""
            value.startsWith("$r/") -> value.removePrefix("$r/")
            else -> null
        }
    }

    companion object {
        /** 根目录。 */
        val ROOT: HostPath = HostPath("/")

        /**
         * 归一化并构造；非法输入抛 `SandboxException.CODE_INVALID_ARGUMENT`。
         *
         * 这是**唯一**推荐的构造入口（直接用 HostPath(...) 会跳过校验）。
         */
        @Throws(SandboxException::class)
        fun parse(raw: String): HostPath = HostPath(normalizeHost(raw))

        /** 归一化但不抛异常；非法输入返回 null。 */
        fun parseOrNull(raw: String): HostPath? = runCatching { parse(raw) }.getOrNull()
    }
}

/**
 * **沙箱视角**路径：PRoot 根文件系统内的路径，形如 `/workspace/a.txt`、`/usr/bin/sh`。
 *
 * <p>**不变量**：归一化后保证以 `/` 开头（相对路径按 `/workspace` 解析，
 * 与 `ExecutionRequest.workingDirectory` 的默认值一致）。
 *
 * <p>⚠️ **这个路径在宿主进程里不存在**。要真的读它，必须先
 * [PathSemantics.toHost] 换到宿主的 rootfs 目录下。
 * 直接把 `File(sandboxPath.value)` 打开**一定会失败**（除非恰好存在同名目录）——
 * 这就是本文件存在的原因。
 */
@JvmInline
value class SandboxPath(val value: String) {

    override fun toString(): String = value

    /** 对应的 [PathView] wire 值（AIDL 用）。 */
    val pathView: PathView get() = PathView.SANDBOX

    fun parent(): SandboxPath = SandboxPath(value.substringBeforeLast('/', "/").ifEmpty { "/" })

    fun name(): String = value.substringAfterLast('/')

    /** 是否位于某个沙箱子树之下（路径段比较）。 */
    fun isUnder(root: SandboxPath): Boolean {
        val r = root.value.trimEnd('/')
        return value == r || value.startsWith("$r/")
    }

    companion object {
        /** 沙箱根。 */
        val ROOT: SandboxPath = SandboxPath("/")

        /**
         * 默认工作区。
         *
         * <p>与 `ExecutionRequest.workingDirectory` 的默认值 `/workspace` 保持一致。
         */
        val WORKSPACE: SandboxPath = SandboxPath("/workspace")

        /**
         * 归一化并构造；非法输入（含越界 `..`）抛
         * `SandboxException.CODE_INVALID_ARGUMENT`。
         */
        @Throws(SandboxException::class)
        fun parse(raw: String): SandboxPath = SandboxPath(normalizeSandbox(raw))

        /** 归一化但不抛异常；非法输入返回 null。 */
        fun parseOrNull(raw: String): SandboxPath? = runCatching { parse(raw) }.getOrNull()
    }
}

/**
 * 路径语义的唯一出口：两套视角之间的换算。
 *
 * <p>实现 `com.heracles.sandbox.runtime.PathResolver`（runtime 的 SPI），
 * 因此 runtime 里所有 `toHostPath()` 调用点最终都走这里 —— 不会出现
 * 「各处散落 `File(filesDir, "sandbox/rootfs$path")`」的拼接。
 *
 * <h2>换算规则</h2>
 * PRoot 的绑定形如 `-b /data/data/<pkg>/files/sandbox/rootfs:/`，
 * 即**沙箱根 `/` 映射到宿主上的 rootfs 目录**。因此：
 *
 * ```
 * 沙箱 /workspace/a.txt  →  宿主 <rootfsHostRoot>/workspace/a.txt
 * 宿主 <rootfsHostRoot>/workspace/a.txt  →  沙箱 /workspace/a.txt
 * 宿主 /sdcard/b.txt     →  （不在 rootfs 内，返回 null）
 * ```
 *
 * <p>**反向映射不是全定义**：宿主上只有 rootfs 目录下的路径才对应沙箱路径。
 * 这也是 HostPath → SandboxPath 的转换返回可空值的原因 ——
 * 让「这个宿主路径在沙箱里没有对应物」成为类型上的显式情况，
 * 而不是一个假的 `/sdcard/b.txt` 被当成沙箱路径塞进命令里。
 *
 * @param rootfsRootProvider rootfs 在宿主上的绝对目录的**提供者**；未安装时返回 null。
 *        每次调用都重新取，这样 rootfs 装好/重置后不必重建本对象。
 */
class PathSemantics(
    private val rootfsRootProvider: () -> HostPath?,
) : com.heracles.sandbox.runtime.PathResolver {

    // ── 正向：沙箱 → 宿主 ─────────────────────────────────────────────

    /**
     * 沙箱视角 → 宿主视角。
     *
     * @throws SandboxException `CODE_ROOTFS_NOT_READY`（rootfs 没装，无宿主位置）/
     *         `CODE_INVALID_ARGUMENT`（路径试图用 `..` 逃出 rootfs）
     */
    override fun sandboxToHost(sandboxPath: String): String =
        toHost(SandboxPath.parse(sandboxPath)).value

    /**
     * 沙箱视角 → 宿主视角（类型安全版）。
     *
     * <p>这是本文件**推荐**的用法：入参是 [SandboxPath]，出参是 [HostPath]，
     * 编译器保证你不会把两者搞混。
     */
    @Throws(SandboxException::class)
    fun toHost(path: SandboxPath): HostPath {
        val root = rootfsRootProvider() ?: throw SandboxException(
            SandboxException.CODE_ROOTFS_NOT_READY,
            "rootfs 未安装：沙箱路径 ${path.value} 在宿主上没有对应位置" +
                "（先 installRootfs / useBundledRootfs）",
        )
        // SandboxPath.parse 已经归一并挡掉 .. 逃逸，这里只需拼。
        val relative = path.value.trimStart('/')
        val joined = if (relative.isEmpty()) root.value else "${root.value.trimEnd('/')}/$relative"
        val resolved = HostPath.parse(joined)
        // 双保险：拼接结果必须仍在 rootfs 根之下（防止 normalize 被绕过）。
        if (!resolved.isUnder(root)) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "路径逃出 rootfs：${path.value} → ${resolved.value}（rootfs 根 ${root.value}）",
            )
        }
        return resolved
    }

    // ── 反向：宿主 → 沙箱 ─────────────────────────────────────────────

    /**
     * 宿主视角 → 沙箱视角；**不在 rootfs 内时返回 null**。
     *
     * <p>注意签名：null 是「这个宿主路径在沙箱里没有对应物」，
     * 而不是错误。/sdcard/a.txt 就是典型例子 —— 除非它被 -b 绑定进了沙箱，
     * 否则沙箱里的 /sdcard/a.txt 是另一个东西。
     */
    override fun hostToSandbox(hostPath: String): String? {
        val host = HostPath.parseOrNull(hostPath) ?: return null
        return toSandbox(host)?.value
    }

    /** 宿主视角 → 沙箱视角（类型安全版）；不在 rootfs 内返回 null。 */
    fun toSandbox(path: HostPath): SandboxPath? {
        val root = rootfsRootProvider() ?: return null
        val relative = path.relativeTo(root) ?: return null
        val sandboxValue = if (relative.isEmpty()) "/" else "/$relative"
        return SandboxPath.parseOrNull(sandboxValue)
    }

    /** rootfs 的宿主根目录字符串（未安装时为 null）。 */
    override fun rootfsHostRoot(): String? = rootfsRootProvider.invoke()?.value

    /** 类型安全版的 [rootfsHostRoot]。 */
    fun rootfsRoot(): HostPath? = rootfsRootProvider.invoke()

    /**
     * 按 AIDL 的 pathView 把任意字符串解析成可落盘的宿主路径。
     *
     * <p>这是 `ISandboxService.readFile(path, pathView)` 的唯一解读入口：
     * - HOST → 原样归一化（零宽通道可以作用其上）
     * - SANDBOX → 先经 [toHost] 换到 rootfs 下
     *
     * @throws SandboxException 参数非法 / rootfs 未就绪
     */
    @Throws(SandboxException::class)
    fun resolveForFileIo(rawPath: String, view: PathView): ResolvedPath = when (view) {
        PathView.HOST -> ResolvedPath(
            host = HostPath.parse(rawPath),
            sandbox = null,
            view = PathView.HOST,
        )

        PathView.SANDBOX -> {
            val sandbox = SandboxPath.parse(rawPath)
            ResolvedPath(
                host = toHost(sandbox),
                sandbox = sandbox,
                // 语义上仍然是「调用方按沙箱视角要的」，即使内部已换成宿主路径。
                view = PathView.SANDBOX,
            )
        }
    }

    /**
     * 一次文件读写解析出来的结果：宿主上真正要操作的位置 + 原始语义。
     *
     * @property host    实际要 File(host.value) 的宿主路径
     * @property sandbox 调用方给的是沙箱视角时保留原值；HOST 视角时为 null
     * @property view    调用方**声明的**视角（回填到 FileResult.pathView 用）
     */
    data class ResolvedPath(
        val host: HostPath,
        val sandbox: SandboxPath?,
        val view: PathView,
    ) {
        /** 回给宿主的原始路径字符串（保持调用方语义，而不是内部换算后的）。 */
        val reportedPath: String get() = sandbox?.value ?: host.value
    }

    companion object {

        /** 创建一个「rootfs 固定在某目录」的实现（测试与 demo 用）。 */
        fun fixed(rootfsRoot: String?): PathSemantics =
            PathSemantics { rootfsRoot?.let { HostPath.parseOrNull(it) } }

        /**
         * 创建一个「rootfs 尚未安装」的实现：任何沙箱路径都报
         * CODE_ROOTFS_NOT_READY，任何宿主路径都映射不到沙箱。
         *
         * <p>这是沙箱**首次启动**时的正常状态，不是错误配置。
         */
        fun notInstalled(): PathSemantics = PathSemantics { null }
    }
}

// ============================================================================
// 归一化（移植自 baicodex Router.normalize + Paths 的路径处理）
// ============================================================================

/**
 * 归一化**宿主**路径。
 *
 * <p>规则（逐条对应上游 Router.normalize 的处理，但补上了 .. 折叠）：
 * 1. 去首尾空白、去成对引号（模型常把路径写成 `"/sdcard/a b.txt"`）
 * 2. `~` 前缀：宿主侧没有确定的 home 概念，**不展开**而是报错
 *    （上游展开到 Paths.base()；沙箱里没有「baicode 数据根」，不该保留该语义）
 * 3. 空串 → 错误
 * 4. 相对路径 → **错误**（不做「挂到某个默认根」的猜测）
 * 5. `..` 段折叠：不能逃到 `/` 之上
 * 6. `//` 折叠成 `/`，去掉尾部多余的 `/`
 *
 * <p>**为什么相对路径直接报错而不是猜一个基准**：上游把相对路径挂到
 * Paths.base()（/sdcard/baicode），那是它的产品决策。
 * 沙箱要能被任意 Agent 项目复用，就不能内置一个数据根；
 * 猜错的后果是「写到了用户没预期的位置」，比报错危险。
 *
 * @throws SandboxException `CODE_INVALID_ARGUMENT`
 */
internal fun normalizeHost(raw: String): String {
    val cleaned = raw.trim().trim('"').trim('\'').trim()
    if (cleaned.isEmpty()) {
        throw SandboxException(SandboxException.CODE_INVALID_ARGUMENT, "路径不能为空")
    }
    if (cleaned.startsWith("~")) {
        throw SandboxException(
            SandboxException.CODE_INVALID_ARGUMENT,
            "宿主视角不支持 ~ 展开（沙箱不假设任何 home 目录）：$raw；请传绝对路径",
        )
    }
    // Android 上 `File.isAbsolute` 等价于 `startsWith("/")`，所以第二个条件在设备上
    // **不改变任何行为**；加它是为了让 JVM 单测能在 Windows 跑（那里绝对路径是 `F:\x`）。
    if (!cleaned.startsWith("/") && !java.io.File(cleaned).isAbsolute) {
        throw SandboxException(
            SandboxException.CODE_INVALID_ARGUMENT,
            "宿主视角必须是绝对路径：$raw（相对路径没有可靠的基准目录，沙箱不猜）",
        )
    }
    return foldSegments(cleaned, raw)
}

/**
 * 归一化**沙箱**路径。
 *
 * <p>与 [normalizeHost] 的关键差异：**相对路径有确定基准**（/workspace），
 * 因为沙箱内的 CWD 默认就是它（见 ExecutionRequest.workingDirectory）。
 * 这让「模型给了个相对路径」在沙箱侧可以安全解析 ——
 * 沙箱内部的位置是可预期的，不像宿主侧那样会写到用户没预期的地方。
 *
 * <p>`~` 在沙箱里映射到 /workspace：比宿主侧宽松，因为沙箱是一个
 * 我们完全掌控的封闭环境，`~` 有一个可辩护的确定含义。
 *
 * @throws SandboxException `CODE_INVALID_ARGUMENT`
 */
internal fun normalizeSandbox(raw: String): String {
    val cleaned = raw.trim().trim('"').trim('\'').trim()
    if (cleaned.isEmpty()) {
        throw SandboxException(SandboxException.CODE_INVALID_ARGUMENT, "路径不能为空")
    }
    if (cleaned.startsWith("~")) {
        val rest = cleaned.removePrefix("~").trimStart('/')
        val base = SandboxPath.WORKSPACE.value
        return foldSegments(if (rest.isEmpty()) base else "$base/$rest", raw)
    }
    val absolute = if (cleaned.startsWith("/")) cleaned else "${SandboxPath.WORKSPACE.value}/$cleaned"
    return foldSegments(absolute, raw)
}

/**
 * 折叠 `.` 与 `..` 段、合并重复斜杠、去掉尾部斜杠。
 *
 * <p>这是唯一做 .. 处理的地方：.. 超过根时**报错而不是静默 clamp**，
 * 因为静默 clamp 会把「试图逃出 rootfs」变成「变成了 /」——
 * 那是一次真实的越权访问（读到 rootfs 根而不是被拒）。
 *
 * @param path 已保证以 `/` 开头
 * @param original 原始输入，只用于错误信息
 */
private fun foldSegments(path: String, original: String): String {
    val segments = ArrayDeque<String>()
    for (segment in path.split('/')) {
        when (segment) {
            "", "." -> Unit // 空段（重复斜杠）与当前目录直接丢掉
            ".." -> {
                if (segments.isEmpty()) {
                    throw SandboxException(
                        SandboxException.CODE_INVALID_ARGUMENT,
                        "路径越界：$original 用 .. 逃出了根目录（拒绝静默钳制到 /）",
                    )
                }
                segments.removeLast()
            }
            else -> segments.addLast(segment)
        }
    }
    return if (segments.isEmpty()) "/" else segments.joinToString(separator = "/", prefix = "/")
}
