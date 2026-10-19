package dev.heracles.workspace

import java.nio.file.Path

/**
 * 文件或目录的元数据。
 *
 * 刻意只含**必要字段**：路径（相对工作区）、大小、是否目录。
 * 不加修改时间 —— 它会进 prompt，而**时间戳进冻结区会让缓存归零**
 * （`02-契约规范.md` §1.1 的禁止清单）。
 */
data class FileEntry(
    /** 相对工作区的路径，始终用 `/` 分隔（跨平台一致，且进 prompt 时稳定） */
    val relativePath: String,
    val sizeBytes: Long,
    val isDirectory: Boolean,
) {
    /** 供 prompt 展示的一行（格式必须稳定，否则破坏缓存） */
    fun render(): String =
        if (isDirectory) "[DIR]  $relativePath"
        else "[FILE] $relativePath  (${sizeBytes}B)"
}

/** 工作区根目录的位置与元信息。 */
data class WorkspaceInfo(
    val rootPath: Path,
    val name: String,
    /**
     * 该工作区是否有**真实**的文件系统根（2026-10-18，F6a / ADR-032）。
     *
     * ## 两种取值
     *
     * | 存储 | [hasRealPath] | [rootPath] 是什么 |
     * |---|---|---|
     * | POSIX（应用私有目录 / 已获全盘权限） | `true` | 真的工作区根 |
     * | SAF（只有 `content://` 授权） | `false` | **占位**（进程 CWD，App 里是 `/`） |
     *
     * ## 为什么必须有这个标记
     *
     * SAF 没有绝对路径，而 [WorkspaceInfo] 又必须给出一个非空 [rootPath]（UI 要展示、
     * 类型要求）。于是适配层退回进程 CWD —— 而 App 的 CWD 恰好是 `/`：
     * 构建/逆向引擎若拿它当工作区根，就会去跟**根目录**打交道
     * （`实测-03` 坑 14 的同类事故：构建从 6 s 变 40 s）。
     *
     * ⇒ 构建类工具在入口处用 `toolchain` 的 `workspacePathBlocker` 检查本字段，
     * 非 POSIX 直接拒绝（**先于**任何碰 [rootPath] 的代码）。**不要**把退回行为改掉 ——
     * 那会波及别处；要拦的是"拿占位路径当真的用"。
     */
    val hasRealPath: Boolean = true,
)
