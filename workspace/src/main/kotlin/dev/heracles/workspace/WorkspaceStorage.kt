package dev.heracles.workspace

/**
 * 底层存储抽象 —— 让 `:workspace` 能同时支持两种实现。
 *
 * ## 为什么需要这一层（2026-10-10）
 *
 * 分区存储下，用户选的文件夹有两种访问方式：
 *
 * | 方式 | 权限来源 | 路径 | 上架 |
 * |---|---|---|---|
 * | **POSIX**（`java.io.File`） | 应用私有目录 / 全盘权限 | 真实路径 | ✅ / ❌ |
 * | **SAF**（`content://`） | 用户授权 | 只有 URI | ✅ |
 *
 * 实测证据（`docs/20-存储访问路线对比.md`）：
 * ```
 * /storage/emulated/0/test  drwxrws--- u0_a239 media_rw
 *   App 的组 groups=10330(u0_a330)  → 不在 media_rw → 写不了
 * ```
 *
 * ## 为什么这层要放在 `:workspace` 里
 *
 * **`:workspace` 是纯 JVM 模块**（`13-框架约束与门禁.md` G1：禁止 `android.*`）。
 * 它不能直接 import `DocumentFile`。
 *
 * 所以：**这里只定义接口，Android 侧提供 SAF 实现**。
 *
 * ```
 * :workspace  ──定义──►  WorkspaceStorage (interface)
 *                              ▲
 *                    ┌─────────┴──────────┐
 *           PosixStorage       AndroidSafStorage
 *          （本模块内）         （:app 模块内，用 DocumentFile）
 * ```
 *
 * ## 设计约束
 *
 * 1. **只用相对路径** —— 抽象层不暴露绝对路径，SAF 根本没有这个概念
 * 2. **只用 String/ByteArray** —— 不泄漏 `java.nio.file.Path`
 * 3. **所有方法可以抛异常** —— 调用方必须处理，不许静默
 */
interface WorkspaceStorage {

    /**
     * 真实文件系统根 —— **只有 POSIX 有**，SAF 返回 `null`。
     *
     * `locationLabel` 是给人看的字符串（SAF 是 `DocumentFile://primary:x`），
     * 不能当路径用。而进程内的 ZIP / 对齐 / 拼接 shell 命令都需要**真正的绝对路径**，
     * 所以单独给一个字段，并**明说** SAF 没有。
     *
     * ⚠️ 2026-10-17 真机教训（`实测-12` §13）：这里原先没有这个字段，
     * 适配层只好用 `Paths.get(".").toAbsolutePath()`（= **进程 CWD**）凑数。
     * CLI 的 CWD 恰好就是工作区根，于是在 PC/CLI 上"看起来对"；到了 **App 进程内**
     * CWD 是 `/`，引擎于是把 `/` 当工作区 —— 报错信息"压缩包不存在：x → /x"
     * 才把它暴露出来（同一个 bug 还会让模型的 `run_shell_command` 用错 cwd、
     * 让 `chmod -R a+rwX` 去 chmod 整个根目录）。
     */
    val realRootPath: java.nio.file.Path? get() = null

    /** 用于 UI 展示的名字（POSIX 是文件夹名，SAF 也是） */
    val displayName: String

    /**
     * 用于 UI 展示的位置描述。
     *
     * - POSIX：`/storage/emulated/0/myapp`
     * - SAF：`DocumentFile://primary:myapp`（没有真实路径，如实说明）
     */
    val locationLabel: String

    /** 该存储是否**真的可写**（POSIX 权限探测 / SAF 授权探测） */
    suspend fun isWritable(): Boolean

    /**
     * 列出目录下的条目（非递归）。
     *
     * @param relativeDir 相对根目录的路径，`""` 表示根
     */
    suspend fun list(relativeDir: String): List<FileEntry>

    /** 读文本。超过 [MAX_READ_BYTES] 必须抛异常，不得截断。 */
    suspend fun readText(relativePath: String): String

    /** 写文本，自动创建父目录。返回写入字节数。 */
    suspend fun writeText(relativePath: String, content: String): Long

    /**
     * 读**字节**（二进制通道）—— 2026-10-18，F6a / ADR-032。
     *
     * 与 [readText] 的区别：**不做任何字符解码**（文本通道会把二进制改成替换字符）。
     * 上限固定为 [MAX_BINARY_BYTES]（64MB），超限**抛**、不截断。语义见
     * [WorkspaceFs.readBytes]。
     */
    suspend fun readBytes(relativePath: String): ByteArray

    /** 写**字节**，自动创建父目录。返回写入字节数。上限同 [readBytes]。 */
    suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long

    suspend fun exists(relativePath: String): Boolean

    /**
     * 创建目录（含缺失的父目录）。已存在时**静默成功**（幂等）。
     *
     * ## 为什么需要（2026-10-15 用户反馈）
     *
     * `writeText` 会建**父目录**，但建**空目录**（如 `tests/`）做不到。
     */
    suspend fun mkdirs(relativeDir: String)

    /**
     * 删除一个**文件**。
     *
     * ## 为什么补这个方法（2026-10-10）
     *
     * 首版只有写没有删 —— 于是 `SessionStore.deleteSession` 删不掉
     * `<工作区>/.heracles/sessions/<id>.jsonl`，只能用「写空」代替，
     * **留下一个空文件**。那是真实的接口缺失，不是实现偷懒：
     * 想删也没得调。
     *
     * ## 语义约定
     *
     * - **只删文件，不递归删目录** —— 递归删除对用户目录太危险
     *   （工作区是用户的真实项目文件夹，误删不可逆）
     * - 目标不存在时返回 `false`（幂等，不抛）
     * - 删除失败（权限等）返回 `false`，**不抛** ——
     *   清理失败不该让整个会话操作崩掉
     *
     * @return 真的删掉了才返回 `true`
     */
    suspend fun delete(relativePath: String): Boolean
}

/**
 * POSIX 文件系统实现 —— 应用私有目录、或已获全盘权限时的用户目录。
 */
class PosixStorage(
    private val root: java.nio.file.Path,
    override val displayName: String = root.fileName?.toString() ?: "workspace",
) : WorkspaceStorage {

    private val norm: java.nio.file.Path = root.toAbsolutePath().normalize()

    override val realRootPath: java.nio.file.Path get() = norm

    override val locationLabel: String get() = norm.toString()

    override suspend fun isWritable(): Boolean = kotlinx.coroutines.withContext(
        kotlinx.coroutines.Dispatchers.IO
    ) {
        if (!java.nio.file.Files.isDirectory(norm)) return@withContext false
        if (!java.nio.file.Files.isWritable(norm)) return@withContext false
        // canWrite 可能漏报 —— 真的试建一个临时目录
        val probe = norm.resolve(".heracles_probe_${System.nanoTime()}")
        try {
            java.nio.file.Files.createDirectory(probe)
            java.nio.file.Files.deleteIfExists(probe)
            true
        } catch (e: Throwable) {
            false
        }
    }

    override suspend fun list(relativeDir: String): List<FileEntry> =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val dir = if (relativeDir.isBlank()) norm else PathGuard.resolve(norm, relativeDir)
            if (!java.nio.file.Files.isDirectory(dir)) return@withContext emptyList()

            java.nio.file.Files.list(dir).use { stream ->
                stream
                    .map { p ->
                        FileEntry(
                            relativePath = norm.relativize(p).toString().replace('\\', '/'),
                            sizeBytes =
                                if (java.nio.file.Files.isDirectory(p)) 0L
                                else java.nio.file.Files.size(p),
                            isDirectory = java.nio.file.Files.isDirectory(p),
                        )
                    }
                    // 排序必须**确定性** —— 顺序不固定会让 prompt 变动、缓存归零
                    .sorted(compareBy({ !it.isDirectory }, { it.relativePath }))
                    .toList()
            }
        }

    override suspend fun readText(relativePath: String): String =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val p = PathGuard.resolve(norm, relativePath)
            require(java.nio.file.Files.isRegularFile(p)) { "不是文件：$relativePath" }
            val size = java.nio.file.Files.size(p)
            require(size <= MAX_READ_BYTES) {
                "文件过大（${size}B > ${MAX_READ_BYTES}B）：$relativePath"
            }
            String(java.nio.file.Files.readAllBytes(p), Charsets.UTF_8)
        }

    override suspend fun writeText(relativePath: String, content: String): Long =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val p = PathGuard.resolve(norm, relativePath)
            p.parent?.let { java.nio.file.Files.createDirectories(it) }
            val bytes = content.toByteArray(Charsets.UTF_8)
            java.nio.file.Files.write(
                p, bytes,
                java.nio.file.StandardOpenOption.CREATE,
                java.nio.file.StandardOpenOption.TRUNCATE_EXISTING,
                java.nio.file.StandardOpenOption.WRITE,
            )
            bytes.size.toLong()
        }

    override suspend fun exists(relativePath: String): Boolean =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            if (relativePath.isBlank()) return@withContext true
            val p = runCatching { PathGuard.resolve(norm, relativePath) }.getOrNull()
                ?: return@withContext false
            java.nio.file.Files.exists(p)
        }

    /**
     * 字节读取（F6a）—— 与 [readText] 同形：先按文件大小快速失败，
     * 再用 [readBytesLimited] 兜住"stat 之后文件变大"的竞态。**两处都抛，不截断。**
     */
    override suspend fun readBytes(relativePath: String): ByteArray =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val p = PathGuard.resolve(norm, relativePath)
            require(java.nio.file.Files.isRegularFile(p)) { "不是文件：$relativePath" }
            val size = java.nio.file.Files.size(p)
            require(size <= MAX_BINARY_BYTES) {
                "文件过大（${size}B > ${MAX_BINARY_BYTES}B）：$relativePath —— 二进制通道不截断"
            }
            java.nio.file.Files.newInputStream(p).use { readBytesLimited(it, MAX_BINARY_BYTES) }
        }

    override suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            require(bytes.size.toLong() <= MAX_BINARY_BYTES) {
                "写入过大（${bytes.size}B > ${MAX_BINARY_BYTES}B）：$relativePath"
            }
            val p = PathGuard.resolve(norm, relativePath)
            p.parent?.let { java.nio.file.Files.createDirectories(it) }
            java.nio.file.Files.write(
                p, bytes,
                java.nio.file.StandardOpenOption.CREATE,
                java.nio.file.StandardOpenOption.TRUNCATE_EXISTING,
                java.nio.file.StandardOpenOption.WRITE,
            )
            bytes.size.toLong()
        }

    override suspend fun mkdirs(relativeDir: String) =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            // 根目录 = 已存在（幂等）
            if (relativeDir.isBlank()) return@withContext
            val p = PathGuard.resolve(norm, relativeDir)
            java.nio.file.Files.createDirectories(p)
        }

    /**
     * 删除一个**文件**。
     *
     * ## 路径穿越必须**抛**，不能吞（2026-10-10 由测试抓出）
     *
     * 首版实现用 `runCatching { PathGuard.resolve(...) }.getOrNull()` ——
     * 于是 `delete("../evil")` 静默返回 `false`。
     *
     * 那与 [readText]/[writeText] **不一致**（它们会抛），
     * 而**删除是本类里最危险的操作** —— 用 `false` 掩盖一次越界尝试，
     * 会让"有人在尝试删容器外的文件"这条信息消失。
     *
     * 所以这里只把"文件不存在"当作 `false`（幂等），
     * **越界照抛**。
     */
    override suspend fun delete(relativePath: String): Boolean =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            if (relativePath.isBlank()) return@withContext false
            // 刻意**不** runCatching —— 越界必须让调用方看见
            val p = PathGuard.resolve(norm, relativePath)
            // 只删文件 —— 递归删目录对用户的真实项目文件夹太危险
            if (!java.nio.file.Files.isRegularFile(p)) return@withContext false
            runCatching { java.nio.file.Files.delete(p) }.isSuccess
        }
}

/**
 * 把 [WorkspaceStorage] 适配成 [WorkspaceFs]。
 *
 * 这样上层的 `:agent`（工具层）**完全不需要知道**底下是 POSIX 还是 SAF。
 */
class StorageBackedWorkspaceFs(
    private val storage: WorkspaceStorage,
) : WorkspaceFs {

    override val info: WorkspaceInfo = WorkspaceInfo(
        // ★ **必须**是存储根，不是进程 CWD（2026-10-17 真机：App 的 CWD 是 `/`，
        //   于是引擎/ZipFs/chmod 全都在跟根目录打交道）。见 [WorkspaceStorage.realRootPath]。
        //
        //   SAF 没有绝对路径 ⇒ 退回 CWD 只是为了让 `WorkspaceInfo` 非空；
        //   **任何需要绝对路径的功能在 SAF 上都必须失败**（编码层要求 POSIX 工作区，
        //   `20-存储访问路线对比.md` 已有定论），不要把它当成"能用"。
        rootPath = storage.realRootPath ?: java.nio.file.Paths.get(".").toAbsolutePath(),
        name = storage.displayName,
        // ★ F6a / ADR-032：把"这个 rootPath 是占位还是真的"如实带到 WorkspaceInfo 上。
        //   构建类工具据此**在碰 rootPath 之前**拒绝（见 toolchain 的 workspacePathBlocker）。
        //   注意：这里**不改**上面的退回行为 —— 只是把事实标出来。
        hasRealPath = storage.realRootPath != null,
    )

    override suspend fun list(relativeDir: String): List<FileEntry> = storage.list(relativeDir)

    override suspend fun readText(relativePath: String): String = storage.readText(relativePath)

    override suspend fun writeText(relativePath: String, content: String): Long =
        storage.writeText(relativePath, content)

    override suspend fun readBytes(relativePath: String): ByteArray = storage.readBytes(relativePath)

    override suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long =
        storage.writeBytes(relativePath, bytes)

    override suspend fun exists(relativePath: String): Boolean = storage.exists(relativePath)

    override suspend fun mkdirs(relativeDir: String) = storage.mkdirs(relativeDir)

    /**
     * 删除（P1-3）：直接委托存储层 —— POSIX 走 `Files.delete`、SAF 走
     * `DocumentFile.delete`（**只删文件**）。语义边界见 [WorkspaceFs.delete]。
     */
    override suspend fun delete(relativePath: String): Boolean = storage.delete(relativePath)
}
