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
 *           runtime/src/main/java/top/wkbin/taixu/runtime/WorkspaceManager.kt
 *           runtime/src/main/java/top/wkbin/taixu/runtime/WorkspaceAtomicWriter.kt
 *
 * ============================================================================
 * 这是什么
 * ============================================================================
 * 工作区（宿主视角）的管理：目录创建、路径换算入口、快照、重置、体积统计。
 *
 * **注意视角**：本类所有路径都是**宿主视角**（`{filesDir}/sandbox/workspace/...`）。
 * 沙箱视角的 `/workspace` 是 PRoot `-b` 绑定出来的，只有 [ProotEngine] 认这个别名。
 * 两者之间的换算**只允许**走 [ProotPathResolver]。
 *
 * ============================================================================
 * 与上游 taixu WorkspaceManager 的差异（这是删减最多的一个文件）
 * ============================================================================
 * 上游 WorkspaceManager 是 **50 KB / 约 1300 行**，因为它同时承担了：
 * 项目 CRUD（Room DAO）、GitHub 导入、ZIP 导出、APK 反编译、项目类型探测、
 * 文件树读写、SAF 目录树交互 —— 那些都属于**控制面**（项目工作流），不是执行面。
 *
 * 删掉的（逐条）：
 *   1. `observeProjects()` / `listProjects()` / `createProject()` /
 *      `deleteProject()` —— Room DAO。沙箱没有 Room（硬约束），且「有哪些项目」
 *      是宿主的概念。
 *   2. `importProjectArchive()` / `importGithubProject()` / `exportProject()` ——
 *      需要 git / zip / SAF。这些是**项目工作流**，由宿主模块负责；
 *      沙箱只提供「把文件放进工作区」的能力（[ensureWorkspace] + 文件通道）。
 *   3. `importApkForReverse()` / `unpackApk()` / `writeReverseReadme()` ——
 *      反编译工作流，纯控制面。
 *   4. `detectProjectType()` / `extractPackageName()` / `ProjectType` ——
 *      项目类型推断，控制面。
 *   5. `listFiles()` / `readFile()` / `writeFile()` / `createFile()` /
 *      `createDirectory()` / `renameItem()` / `deleteItem()` ——
 *      **这些**是执行面的能力，但沙箱的对外契约里文件读写走
 *      `ISandboxService.readFile/writeFile` + `sandbox-file` 模块（零宽通道），
 *      不应该在 runtime 里再实现一遍（会出现两套权限检查）。
 *   6. `linuxWorkingDirectory()` / `workspaceForName()` / `usesSharedStorage()`
 *      —— 分布式路径解析，改用 [ProotPathResolver] 统一。
 *   7. `writeProjectTypeMetadata()` / `readProjectTypeMetadata()` —— 项目元数据。
 *   8. `isValidGitUrl*()` —— 无 git。
 *
 * 保留并改写的：
 *   - **工作区目录的建立与规范**（[ensureWorkspace]）：含名称白名单校验
 *     （名字会拼成目录名，`..` 会逃逸）
 *   - **快照 / 重置**（[snapshot] / [reset] / [restoreSnapshot]）：
 *     「构建前存档、失败回滚」的执行面能力
 *   - **体积统计**（[usageBytes]）：宿主展示用
 *   - **安全的相对路径拼接**（[resolveHostPath]）：所有「工作区内的相对路径」
 *     都必须经过它，禁止调用方自己拼 `File(workspaceDir, relative)`
 *
 * ============================================================================
 * 安全边界（红线）
 * ============================================================================
 * - 工作区名：`[A-Za-z0-9_-]{1,64}`，**不允许** `.` / `/` / 空格
 * - 工作区内的相对路径：规范化后必须仍在工作区内（拒绝 `..` 与绝对路径）
 * - 工作区根目录必须由宿主指定，且**不允许**是 `/`（防误删）
 */

package com.heracles.sandbox.runtime

import com.heracles.sandbox.api.SandboxException
import java.io.File
import java.io.IOException
import java.nio.file.Files
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 一个工作区（宿主视角）。
 *
 * @param name       工作区名（已通过白名单校验）
 * @param hostPath   宿主上的绝对路径
 * @param sandboxPath 沙箱视角路径（`/workspace` 或 `/workspace/<name>`）
 */
data class Workspace(
    val name: String,
    val hostPath: String,
    val sandboxPath: String,
) {
    /** 宿主侧目录对象。 */
    val hostDir: File get() = File(hostPath)
}

/**
 * 工作区管理器（宿主视角）。
 *
 * 设计成单目录而不是多项目：沙箱的「工作区」就是 PRoot 里那个 `/workspace`。
 * 多项目隔离由宿主自己用子目录完成（[createSubWorkspace] 提供安全的名字校验
 * 与路径换算，但不维护项目元数据 —— 那是控制面）。
 *
 * @param workspacesRoot 全部工作区的根目录（宿主视角；必须在 App 私有目录内）
 * @param snapshotRoot   快照仓库根目录
 * @param eventSink      事件上报（可选）
 */
class WorkspaceManager(
    val workspacesRoot: File,
    snapshotRoot: File,
    private val eventSink: EventSink = NoOpEventSink,
    /** 每个工作区最多保留几个快照。 */
    snapshotKeep: Int = SnapshotStore.DEFAULT_MAX_KEEP,
) {

    private val snapshots = SnapshotStore(snapshotRoot, snapshotKeep)

    /**
     * 默认工作区（PRoot 里 `/workspace` 对应的那个）。
     *
     * 沙箱启动时自动建立，宿主不需要显式创建。
     */
    val defaultWorkspace: Workspace
        get() = Workspace(
            name = DEFAULT_WORKSPACE_NAME,
            hostPath = File(workspacesRoot, DEFAULT_WORKSPACE_NAME).absolutePath,
            sandboxPath = SANDBOX_ROOT,
        )

    /**
     * 确保默认工作区存在。
     *
     * @throws SandboxException CODE_IO
     */
    suspend fun ensureDefaultWorkspace(): Workspace = withContext(Dispatchers.IO) {
        ensureWorkspace(DEFAULT_WORKSPACE_NAME)
    }

    /**
     * 确保名为 [name] 的工作区存在（幂等）。
     *
     * @throws SandboxException CODE_INVALID_ARGUMENT 名字非法 / CODE_IO 建不出来
     */
    suspend fun ensureWorkspace(name: String): Workspace = withContext(Dispatchers.IO) {
        validateWorkspaceName(name)
        ensureRoot()
        val dir = File(workspacesRoot, name)
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) {
            throw SandboxException(
                SandboxException.CODE_IO,
                "无法创建工作区目录：${dir.absolutePath}",
            )
        }
        val workspace = Workspace(
            name = name,
            hostPath = dir.absolutePath,
            sandboxPath = if (name == DEFAULT_WORKSPACE_NAME) SANDBOX_ROOT else "$SANDBOX_ROOT/$name",
        )
        eventSink.onEvent(
            EventSink.CATEGORY_LIFECYCLE,
            "工作区已就绪",
            mapOf("name" to name, "host" to workspace.hostPath, "sandbox" to workspace.sandboxPath),
        )
        workspace
    }

    /**
     * 列出全部工作区（按名字排序）。
     *
     * 只统计**目录**；快照仓库不在工作区根下，所以不会被混进来。
     */
    fun listWorkspaces(): List<Workspace> {
        if (!workspacesRoot.isDirectory) return emptyList()
        return workspacesRoot.listFiles().orEmpty()
            .filter { it.isDirectory && !it.isSymlinkNoFollow() }
            .filter { WORKSPACE_NAME.matches(it.name) }
            .sortedBy { it.name }
            .map { dir ->
                Workspace(
                    name = dir.name,
                    hostPath = dir.absolutePath,
                    sandboxPath = if (dir.name == DEFAULT_WORKSPACE_NAME) SANDBOX_ROOT
                    else "$SANDBOX_ROOT/${dir.name}",
                )
            }
    }

    /**
     * 把工作区里的**相对路径**解析成宿主绝对路径。
     *
     * **所有**「工作区内的相对路径」都必须经过这里 —— 禁止调用方自己拼
     * `File(workspaceDir, relative)`，那正是路径穿越漏洞的来源。
     *
     * 规则：
     *   - 相对路径不能是绝对路径（`/etc/passwd` 拒绝）
     *   - 不能含 `..`（`../../databases` 拒绝，即使规范化后还在根内也拒绝
     *     —— 明确拒绝比「规范化后放行」更容易审计）
     *   - 规范化后必须仍在工作区内（双保险）
     *
     * @throws SandboxException CODE_INVALID_ARGUMENT 越界
     */
    fun resolveHostPath(workspace: Workspace, relativePath: String): File {
        if (relativePath.startsWith("/") || relativePath.startsWith("\\")) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "工作区内的相对路径不能是绝对路径：$relativePath",
            )
        }
        // Windows 盘符式绝对路径（`C:\...`）也要拒绝
        if (relativePath.length >= 2 && relativePath[1] == ':') {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "工作区内的相对路径不能带盘符：$relativePath",
            )
        }
        val segments = relativePath.replace('\\', '/').split('/')
        if (segments.any { it == ".." }) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "工作区内的相对路径不允许包含 ..（$relativePath）",
            )
        }
        val root = workspace.hostDir.canonicalFile
        val candidate = File(root, relativePath).canonicalFile
        if (candidate != root && !candidate.startsWith(root)) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "路径越界（不在工作区内）：$relativePath",
            )
        }
        return candidate
    }

    /** 工作区占用字节数（不跟随符号链接）。 */
    fun usageBytes(workspace: Workspace): Long = directorySize(workspace.hostDir)

    /** 全部工作区占用字节数。 */
    fun totalUsageBytes(): Long = listWorkspaces().sumOf { usageBytes(it) }

    // ========================================================================
    // 快照 / 重置
    // ========================================================================

    /** 列出该工作区的全部快照（按创建时间升序）。 */
    suspend fun listSnapshots(workspace: Workspace): List<SnapshotInfo> = withContext(Dispatchers.IO) {
        snapshots.list().filter { it.name.startsWith("${workspace.name}${SNAPSHOT_SEPARATOR}") }
    }

    /**
     * 给工作区做快照。
     *
     * 典型用法：**在危险操作（构建、批量改写）之前**调用，失败后
     * [restoreSnapshot] 回滚。
     *
     * @param label 快照标签（追加在工作区名后面，便于人读）
     * @throws SandboxException CODE_INVALID_ARGUMENT / CODE_IO
     */
    suspend fun snapshot(workspace: Workspace, label: String): SnapshotInfo = withContext(Dispatchers.IO) {
        val snapshotName = "${workspace.name}${SNAPSHOT_SEPARATOR}${sanitizeLabel(label)}"
        snapshots.create(snapshotName, workspace.hostDir)
    }

    /**
     * 把快照恢复到工作区。
     *
     * @param snapshotName [snapshot]/[listSnapshots] 返回的名字
     */
    suspend fun restoreSnapshot(
        workspace: Workspace,
        snapshotName: String,
    ): Unit = withContext(Dispatchers.IO) {
        snapshots.restore(snapshotName, workspace.hostDir)
        eventSink.onEvent(
            EventSink.CATEGORY_LIFECYCLE,
            "工作区已从快照恢复",
            mapOf("workspace" to workspace.name, "snapshot" to snapshotName),
        )
    }

    /**
     * 重置工作区为空目录（清空全部内容）。
     *
     * 先做一次自动快照（除非 [keepSnapshot] 为 false），这样「重置」不会
     * 成为不可恢复的操作 —— 这是刻意的：用户误点重置的代价太高。
     *
     * @param keepSnapshot 是否先做一份 `auto-before-reset` 快照（默认 true）
     */
    suspend fun reset(workspace: Workspace, keepSnapshot: Boolean = true) = withContext(Dispatchers.IO) {
        if (keepSnapshot && directorySize(workspace.hostDir) > 0) {
            runCatching { snapshot(workspace, "auto-before-reset") }
                .onFailure { failure ->
                    eventSink.onEvent(
                        EventSink.CATEGORY_LIFECYCLE,
                        "重置前自动快照失败（继续重置）",
                        mapOf(
                            "workspace" to workspace.name,
                            "error" to (failure.message ?: "unknown"),
                        ),
                    )
                }
        }
        val dir = workspace.hostDir
        if (dir.isDirectory) {
            dir.listFiles().orEmpty().forEach { deleteTree(it) }
        } else {
            ensureWorkspace(workspace.name)
        }
        eventSink.onEvent(
            EventSink.CATEGORY_LIFECYCLE,
            "工作区已重置",
            mapOf("workspace" to workspace.name),
        )
    }

    /** 删除一个工作区及其快照。 */
    suspend fun deleteWorkspace(workspace: Workspace) = withContext(Dispatchers.IO) {
        require(workspace.name != DEFAULT_WORKSPACE_NAME) {
            "不允许删除默认工作区（${DEFAULT_WORKSPACE_NAME}）；请改用 reset()"
        }
        deleteTree(workspace.hostDir)
        listSnapshots(workspace).forEach { snapshots.delete(it.name) }
    }

    /** 快照仓库总占用（宿主展示用）。 */
    fun snapshotUsageBytes(): Long = snapshots.usageBytes()

    /** 清空全部快照。 */
    suspend fun clearSnapshots() = withContext(Dispatchers.IO) { snapshots.clear() }

    // ========================================================================
    // 内部
    // ========================================================================

    private fun ensureRoot() {
        if (!workspacesRoot.isDirectory && !workspacesRoot.mkdirs() && !workspacesRoot.isDirectory) {
            throw SandboxException(
                SandboxException.CODE_IO,
                "无法创建工作区根目录：${workspacesRoot.absolutePath}",
            )
        }
    }

    /**
     * 校验工作区名。
     *
     * 名字会直接拼成目录名，所以必须严格：
     * `[A-Za-z0-9_-]{1,64}`，不能用 `.`（避免 `.` / `..`）、不能用空格
     * （Android 文件系统与 shell 引用都容易出错）。
     */
    private fun validateWorkspaceName(name: String) {
        if (!WORKSPACE_NAME.matches(name)) {
            throw SandboxException(
                SandboxException.CODE_INVALID_ARGUMENT,
                "工作区名非法：\"$name\"（只允许 1..64 位 [A-Za-z0-9_-]）",
            )
        }
    }

    /** 把快照标签清洗成安全片段（只保留字母数字与 `-`）。 */
    private fun sanitizeLabel(label: String): String {
        val cleaned = label.replace(Regex("[^A-Za-z0-9-]"), "-").trim('-')
        return cleaned.take(40).ifEmpty { "snap" }
    }

    private fun directorySize(dir: File): Long = runCatching {
        dir.walkTopDown()
            .filter { it.isFile && !it.isSymlinkNoFollow() }
            .sumOf { it.length() }
    }.getOrDefault(0L)

    private fun deleteTree(file: File) {
        if (!file.exists() && !file.isSymlinkNoFollow()) return
        if (file.isSymlinkNoFollow()) {
            runCatching { Files.deleteIfExists(file.toPath()) }
            return
        }
        if (file.isDirectory) {
            file.listFiles().orEmpty().forEach { deleteTree(it) }
            runCatching { file.delete() }
        } else {
            runCatching { Files.deleteIfExists(file.toPath()) }
        }
    }

    companion object {
        /** 默认工作区名（对应 PRoot 里 `/workspace`）。 */
        const val DEFAULT_WORKSPACE_NAME = "workspace"

        /** 沙箱视角的工作区根。 */
        const val SANDBOX_ROOT = "/workspace"

        /** 快照名里工作区与标签的分隔符。 */
        const val SNAPSHOT_SEPARATOR = "."

        private val WORKSPACE_NAME = Regex("[A-Za-z0-9_-]{1,64}")
    }
}
