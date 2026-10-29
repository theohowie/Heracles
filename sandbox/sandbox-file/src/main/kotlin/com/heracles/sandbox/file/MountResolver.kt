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

package com.heracles.sandbox.file

import com.heracles.sandbox.api.MountBackend
import com.heracles.sandbox.api.MountEntry
import com.heracles.sandbox.api.MountReadOnlyException
import com.heracles.sandbox.api.SandboxException
import com.heracles.sandbox.runtime.CommandRewriter

/**
 * **逻辑命名路径** → **物理路径 / SAF 文档** 的解析器。
 *
 * ============================================================================
 * 三级结构里的第 1 级
 * ============================================================================
 * ```
 * @name/...            ← 第 1 级：逻辑命名空间（模型只写这个）
 *    ↓ 本类
 * 物理路径 / SAF URI    ← 第 2 级：宿主绝对路径（或 SAF doc）
 *    ↓ PathSemantics
 * HOST / SANDBOX       ← 第 3 级：两套物理语义
 * ```
 *
 * ============================================================================
 * 解析顺序（严格按此顺序，不要调换）
 * ============================================================================
 * 1. 取 `@name` 前缀
 * 2. 查 [MountRegistry] —— **未注册直接报错，绝不回退到物理路径猜测**
 * 3. 只读 + 写操作 —— **宿主侧直接拒绝**，不进 PRoot 靠文件权限兜底
 * 4. 按 backend 分派：ROOTFS_RELATIVE / HOST_PRIVATE_DIR → 物理路径
 * 5. SAF_TREE → **保持为 SAF 文档操作**，不转物理路径
 *
 * ============================================================================
 * 为什么「未注册就报错」而不是猜
 * ============================================================================
 * 猜路径有两个恶果：
 * - 模型会以为自己拼对了（预览与实际不一致）
 * - 换设备后历史对话里的物理路径全失效，且报错位置离真正原因很远
 *
 * 明确报错虽然「更早失败」，但失败点就是配置点，好排查。
 */
class MountResolver(
    private val registry: MountRegistry,
    /** SAF 读写实现；传 null 表示本宿主不支持 SAF（遇到 SAF 挂载点会明确报错）。 */
    private val safIo: SafDocumentIo? = null,
) : CommandRewriter {

    // ── 对外：路径解析 ─────────────────────────────────────────────────

    /**
     * 解析一个模型给的路径。
     *
     * @param rawPath 模型给的路径。以 `@` 开头 → 走命名挂载；否则原样返回
     *                （兼容既有调用方仍用物理路径的情况，**不破坏现有语义**）
     * @param forWrite 是否是写操作（用于只读检查）
     * @throws SandboxException `CODE_MOUNT_UNKNOWN`：`@name` 未注册
     * @throws MountReadOnlyException：只读挂载点上的写操作
     */
    fun resolve(rawPath: String, forWrite: Boolean): ResolvedMount {
        if (!rawPath.startsWith("@")) {
            // 不是命名路径：交给调用方按原有 PathSemantics 处理（行为完全不变）
            return ResolvedMount.Plain(rawPath)
        }

        val (entry, rest) = split(rawPath)
        checkReadOnly(entry, rawPath, forWrite)

        return when (entry.backend) {
            MountBackend.ROOTFS_RELATIVE -> {
                val root = registry.rootfsRoot() ?: throw SandboxException(
                    SandboxException.CODE_ROOTFS_NOT_READY,
                    "挂载点 @${entry.name} 是 ROOTFS_RELATIVE，但 rootfs 尚未就绪",
                )
                val physical = joinPhysical("$root/${entry.hostPath.trim('/')}", rest)
                ResolvedMount.Physical(entry, physical)
            }

            MountBackend.HOST_PRIVATE_DIR -> {
                val physical = joinPhysical(entry.hostPath.trimEnd('/'), rest)
                ResolvedMount.Physical(entry, physical)
            }

            MountBackend.SAF_TREE -> {
                val io = safIo ?: throw SandboxException(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    "挂载点 @${entry.name} 是 SAF_TREE，但宿主没有提供 SafDocumentIo 实现",
                )
                ResolvedMount.Saf(entry, io, rest)
            }
        }
    }

    /**
     * 只读检查（**写操作在宿主侧就拒**）。
     *
     * 公开出来是为了让 `execute` 路径也能复用同一套判断。
     */
    fun checkReadOnly(entry: MountEntry, rawPath: String, forWrite: Boolean) {
        if (forWrite && entry.readOnly) {
            throw MountReadOnlyException(entry.name, rawPath)
        }
    }

    // ── CommandRewriter：execute 里的 @name 解析 ───────────────────────

    /**
     * 把命令串里的 `@name/...` 换成物理路径。
     *
     * 用正则**只替换命名字符串字面量**，避免误伤：
     * ```sh
     * cat @workspace/a.txt          → cat /…/a.txt
     * echo "@workspace/a.txt"       → echo "/…/a.txt"
     * grep -r foo @libs/            → grep -r foo /…/libs/
     * ```
     *
     * **SAF 挂载点不能出现在命令里**：SAF 没有物理路径，命令又只能在 PRoot 里跑。
     * 这种情况必须明确报错，而不是把 `content://` 塞给 shell。
     *
     * @throws SandboxException `CODE_MOUNT_UNKNOWN`：未注册
     * @throws SandboxException `CODE_INVALID_ARGUMENT`：SAF 挂载点出现在命令中
     */
    override fun rewriteCommand(commandLine: String): String {
        if (!commandLine.contains('@')) return commandLine

        return MOUNT_TOKEN.replace(commandLine) { match ->
            val raw = match.value
            val (entry, rest) = split(raw)
            val guestPath = toGuestPath(entry, rest)
                ?: throw SandboxException(
                    SandboxException.CODE_INVALID_ARGUMENT,
                    guestPathFailure(entry, raw),
                )
            guestPath
        }
    }

    /**
     * 命令里的 `@name` 要换成 **guest 路径**，不是宿主路径。
     *
     * ============================================================================
     * 为什么不能直接塞宿主路径（真机踩过）
     * ============================================================================
     * 命令是在 PRoot guest 里跑的，`sh` 看到的是 **guest 视角**。
     * 把 `<rootfs>/workspace/x.txt` 这样的宿主路径写进命令，
     * 在 guest 里会被解析成 `/workspace/x.txt` —— 而 guest 的 `/workspace`
     * 是**bind 挂载**（宿主 `sandbox/workspaces`），于是读到了**另一个目录**，
     * 表现为 `cat` 返回 1、内容为空。
     *
     * 规则：
     *   1. 配了 `bindTo` → 用 `bindTo + rest`（绑进去的那个挂载点）
     *   2. ROOTFS_RELATIVE 没配 `bindTo` → 用 `"/" + hostPath + rest`
     *      （guest 的根就是 rootfs，所以这条路径天然可见）
     *   3. HOST_PRIVATE_DIR 没配 `bindTo` → **报错**：
     *      宿主私有目录在 guest 里根本不可见，硬塞只会读到不存在的路径
     *   4. SAF_TREE → **报错**（没有物理路径）
     *
     * @return null 表示无法在 guest 内表达（调用方负责给出可读错误）
     */
    private fun toGuestPath(entry: MountEntry, rest: String): String? {
        if (entry.wantsBind) return joinPhysical(entry.bindTo, rest)
        return when (entry.backend) {
            MountBackend.ROOTFS_RELATIVE -> {
                val guestRoot = "/" + entry.hostPath.trim('/')
                // 标准 bind 会把某些 guest 路径整体盖住，写进去会读到别处
                if (SHADOWED_GUEST_PREFIXES.any { p ->
                        guestRoot == p || guestRoot.startsWith("$p/")
                    }
                ) {
                    null
                } else {
                    joinPhysical(guestRoot, rest)
                }
            }
            MountBackend.HOST_PRIVATE_DIR, MountBackend.SAF_TREE -> null
        }
    }

    /** 生成「为什么这条命令里的 @name 用不了」的人话说明。 */
    private fun guestPathFailure(entry: MountEntry, raw: String): String = when (entry.backend) {
        MountBackend.SAF_TREE ->
            "@${entry.name} 是 SAF_TREE 挂载点，**没有物理路径**，不能出现在命令里" +
                "（命令只能在 PRoot 内执行）。请用 readFile/writeFile 走宿主侧 SAF 读写。"
        MountBackend.HOST_PRIVATE_DIR ->
            "@${entry.name} 是 HOST_PRIVATE_DIR（宿主私有目录），在 PRoot guest 内**不可见**。" +
                "若要在命令里用它，请给它设置 bindTo（如 /opt/${entry.name}），" +
                "让宿主把它绑进 rootfs。"
        MountBackend.ROOTFS_RELATIVE ->
            "@${entry.name} 的 hostPath='${entry.hostPath}' 落在 PRoot 的标准 bind 覆盖区内" +
                "（${SHADOWED_GUEST_PREFIXES.joinToString()} 之一）。" +
                "guest 里这些路径指向宿主工作区，不是 rootfs 内的目录。" +
                "请改 hostPath（如 opt/${entry.name}），或设置 bindTo 显式指定挂载点。"
    }

    // ── 内部 ──────────────────────────────────────────────────────────

    /** 拆出 `@name` 与剩余相对路径；未注册抛 `CODE_MOUNT_UNKNOWN`。 */
    private fun split(rawPath: String): Pair<MountEntry, String> {
        val withoutAt = rawPath.removePrefix("@")
        val name = withoutAt.substringBefore('/')
        val rest = withoutAt.substringAfter('/', "")

        if (name.isEmpty()) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "命名路径缺名字：'$rawPath'（应形如 @workspace/a.txt）",
            )
        }
        val entry = registry.get(name) ?: throw SandboxException(
            SandboxException.CODE_MOUNT_UNKNOWN,
            "未注册的挂载点 '@$name'（已注册：${registry.list().joinToString { it.prefix }.ifBlank { "无" }}）。" +
                "请让宿主先注册，或用已注册的名字。",
        )
        // 越界防护：不允许 ../ 逃出挂载根
        if (rest.split('/').any { it == ".." }) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "路径不得含 '..'：'$rawPath'",
            )
        }
        return entry to rest
    }

    /** 拼物理路径，去掉多余斜杠。 */
    private fun joinPhysical(base: String, rest: String): String {
        val b = base.trimEnd('/')
        val r = rest.trimStart('/')
        return if (r.isEmpty()) b else "$b/$r"
    }

    companion object {
        /**
         * 命令串里的命名路径 token。
         *
         * - `@` 后面跟 `[a-z0-9_]+`
         * - 可带 `/子路径`（子路径里不含空白、引号、重定向符号、管道、分号）
         * - 前后不能紧贴标识符字符（避免误伤 `a@b.com` 之类）
         */
        /**
         * PRoot 一定会 bind 的 guest 路径（见 `ProotEngine.ALLOWED_BIND_TARGETS`
         * 与基础绑定）。落在这里面的 ROOTFS_RELATIVE 会被**盖住**，
         * 写进命令会读到宿主工作区而不是 rootfs 内的目录。
         */
        private val SHADOWED_GUEST_PREFIXES = listOf(
            // 沙箱自有的四个可写绑定（见 ProotEngine 的「沙箱自有绑定」段）
            "/workspace", "/root", "/tmp", "/attachments",
            // HOST_SYSTEM_BINDINGS 里的（guest 里指向宿主 Android 系统）
            "/dev", "/proc", "/sys", "/apex", "/system", "/system_ext",
            "/vendor", "/product", "/odm",
            "/data/app", "/data/dalvik-cache", "/linkerconfig",
        )
        private val MOUNT_TOKEN =
            Regex("(?<![A-Za-z0-9_./-])@([a-z0-9_]+)(/[^\\s\"'`|&;<>()]*)?")
    }
}

/**
 * 解析结果。
 *
 * 用 sealed 是为了**强迫调用方分支处理**：
 * 物理路径（可交给 `PathSemantics`）与 SAF 文档（只能走 SAF API）不能混。
 */
sealed class ResolvedMount {

    /** 不是命名路径：原样交给既有 `PathSemantics`，行为与引入挂载层之前**完全一致**。 */
    data class Plain(val raw: String) : ResolvedMount()

    /** 解析到一个**物理路径**（宿主视角绝对路径）。 */
    data class Physical(
        val entry: MountEntry,
        val hostPath: String,
    ) : ResolvedMount()

    /** 解析到一个 **SAF 文档**：只能用 SAF API 读写，**不转物理路径**。 */
    data class Saf(
        val entry: MountEntry,
        val io: SafDocumentIo,
        val relativePath: String,
    ) : ResolvedMount()
}
