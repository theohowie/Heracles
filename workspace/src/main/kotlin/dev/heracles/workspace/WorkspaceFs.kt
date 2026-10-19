package dev.heracles.workspace

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption

/**
 * 工作区文件系统 —— `00-需求文档.md` §2.13.1「沙箱在本地」的实现基础。
 *
 * ## 设计要点
 *
 * 1. **每个方法都过 [PathGuard]** —— 没有任何一条路径能绕过越界检查
 * 2. **所有 IO 走 `Dispatchers.IO`** —— 不在协程里做阻塞 IO
 * 3. **接口而非实现类**（[WorkspaceFs] + [RealWorkspaceFs]）——
 *    阶段二的权限档位要在执行前插入"用户确认"，用假实现测试更容易
 *
 * ## 刻意不做的事（YAGNI）
 *
 * - 不做文件监听（阶段二再需要）
 * - 不做增量同步（阶段二）
 * - 不做 Git（阶段二，用户已明确）
 */
interface WorkspaceFs {
    val info: WorkspaceInfo

    /** 列出相对路径下的条目（非递归）。路径 `""` 表示根。 */
    suspend fun list(relativeDir: String = ""): List<FileEntry>

    /** 读取文本文件。文件过大时抛出（防止把整个日志塞进上下文）。 */
    suspend fun readText(relativePath: String): String

    /** 写入文本文件，自动创建父目录。返回写入字节数。 */
    suspend fun writeText(relativePath: String, content: String): Long

    /** 文件或目录是否存在 */
    suspend fun exists(relativePath: String): Boolean

    /**
     * 创建目录（含缺失的父目录）。已存在时**静默成功**（幂等）。
     *
     * ## 为什么需要（2026-10-15 用户反馈「没有生成目录的工具」）
     *
     * `writeText` 虽会自动建父目录，但**建空目录做不到**——
     * 模型想表达"我要一个 tests/ 目录"（如建测试结构）时没有工具可用。
     */
    suspend fun mkdirs(relativeDir: String)

    /**
     * 读取**字节**（二进制通道）—— 2026-10-18，F6a / ADR-032。
     *
     * 存在的理由：F6b 要把非 POSIX 工作区镜像进 App 内部 staging 构建、再把产物**按字节**回写。
     * 文本通道（[readText]）不能用来搬字节：它按 UTF-8 解码，二进制会被替换字符悄悄改坏。
     *
     * ## 上限语义：**超限抛，不截断**
     *
     * 上限 [MAX_BINARY_BYTES]（64MB，与文本的 [MAX_READ_BYTES] 是**两条独立的线**）：
     * · 文本 [MAX_READ_BYTES] = 1MB：那是"别把日志塞满上下文"的**上下文预算**；
     * · 二进制 [MAX_BINARY_BYTES] = 64MB：那是"别把手机内存打爆"的**内存预算**（要搬的是
     *   资源 / libs / 成品 APK，比源码大一个量级）。
     * 超限一律**抛**，绝不返回截断的字节数组 —— 半个文件比失败更糟（会得到"能写进去但坏掉"的产物）。
     *
     * ## 默认实现
     *
     * 默认体**显式抛** [UnsupportedOperationException]：`RealWorkspaceFs` 与
     * `StorageBackedWorkspaceFs` 都覆盖它；但仓库里还有若干**测试替身**只实现了文本通道。
     * 给默认体是为了不让"新增字节能力"去改一堆无关测试文件；
     * 失败是**响亮的**，不是静默空读（后者会骗人）。见 `ByteIoTest.defaultImplFailsLoudly`。
     */
    suspend fun readBytes(relativePath: String): ByteArray =
        throw UnsupportedOperationException("该 WorkspaceFs 实现未提供字节 IO：$relativePath")

    /**
     * 写入**字节**（二进制通道），自动创建父目录。返回写入字节数。
     *
     * 语义与上限见 [readBytes]：写入同样受 [MAX_BINARY_BYTES] 约束（超限抛，不静默截断）。
     */
    suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long =
        throw UnsupportedOperationException("该 WorkspaceFs 实现未提供字节 IO：$relativePath")

    /**
     * 删除**一个**路径（文件或目录）—— P1-3（`rm` 的底座），2026-10-18。
     *
     * ## 语义边界（很重要）
     *
     * · 本方法**不递归**：目录非空时由实现**失败**（POSIX：`DirectoryNotEmptyException`；
     *   SAF：返回 `false`，因为 `DocumentFile.delete()` 对目录是**递归**的，
     *   放开它等于把"删空目录"变成"删整棵"—— 见 `AndroidSafStorage.delete` 的 KDoc）。
     *   递归是**工具层**的事（它先预扫描、再逐层删），这里不替它决定。
     * · 文件不存在 ⇒ 返回 `false`（不是异常：调用方通常已经先 `exists` 过；
     *   把"不存在"和"删不掉"分开由工具层处理）。
     * · 真正的 IO 失败（权限 / 非空目录 / SAF 拒绝）**抛异常** —— 工具层转成可解释的失败。
     *
     * ## 默认实现
     *
     * 默认体**显式抛** [UnsupportedOperationException]（与 [readBytes] 同一条纪律）：
     * 仓库里还有若干只实现文本通道的测试替身，给默认体是为了不逼着它们全改；
     * 但**必须响亮**——静默 `false` 会让"删除没生效"变成最难查的那类 bug。
     */
    suspend fun delete(relativePath: String): Boolean =
        throw UnsupportedOperationException("该 WorkspaceFs 实现未提供删除：$relativePath")
}

/** 单文件**文本**读取上限（字节）。超过则拒绝 —— 见 [WorkspaceFs.readText] 的说明。 */
const val MAX_READ_BYTES: Long = 1_000_000

/**
 * 单文件**字节**读写上限（二进制通道）—— 2026-10-18，F6a。
 *
 * ## 为什么与 [MAX_READ_BYTES] 不是一个数
 *
 * | 通道 | 上限 | 约束的是什么 |
 * |---|---|---|
 * | 文本 [readText] | [MAX_READ_BYTES]（1MB） | **上下文预算**（读进来的东西会进 prompt） |
 * | 字节 [readBytes] | 本常量（64MB） | **内存预算**（只在进程内搬，不直接进 prompt） |
 *
 * 64MB 的依据：F6b 要镜像的是"项目 → staging"与"成品 APK → 工作区"，手机上的
 * 源码项目与 APK 通常远小于此；再大就该走流式（本任务不预埋）。**超限抛，不截断** ——
 * 截断的字节流就是坏文件。
 */
const val MAX_BINARY_BYTES: Long = 64L * 1024 * 1024

/** 有界拷贝的缓冲大小 —— 64KB 与 JDK 的典型流拷贝一致，不参与任何语义。 */
private const val BYTE_COPY_BUFFER = 64 * 1024

/**
 * **有界**读取整个流 —— SAF 的 `InputStream` 与测试共用（2026-10-18，F6a）。
 *
 * ## 为什么单独抽出来
 *
 * `AndroidSafStorage` 在 `:app`（Android 模块），那里**没有纯 JVM 单测**；
 * 把它"边读边计数"的核心逻辑抽到这里，就能在 `:workspace` 单测里覆盖
 * "超限必须抛、不返回截断结果"这条纪律。DocumentFile 那层接线仍需真机验（见 F6a 报告）。
 *
 * @throws IllegalArgumentException 读取量超过 [maxBytes]（**不截断、不返回半份**）
 */
fun readBytesLimited(input: java.io.InputStream, maxBytes: Long = MAX_BINARY_BYTES): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buf = ByteArray(BYTE_COPY_BUFFER)
    var total = 0L
    while (true) {
        val n = input.read(buf)
        if (n < 0) break
        total += n
        if (total > maxBytes) {
            throw IllegalArgumentException(
                "二进制读取超过上限（${maxBytes}B）—— 不截断，请改用流式处理或缩小文件"
            )
        }
        out.write(buf, 0, n)
    }
    return out.toByteArray()
}

class RealWorkspaceFs(override val info: WorkspaceInfo) : WorkspaceFs {

    private val root: Path = info.rootPath.toAbsolutePath().normalize()

    init {
        if (!Files.isDirectory(root)) {
            throw IllegalArgumentException("工作区根不是目录：$root")
        }
    }

    override suspend fun list(relativeDir: String): List<FileEntry> = withContext(Dispatchers.IO) {
        val dir = if (relativeDir.isBlank()) root else PathGuard.resolve(root, relativeDir)
        if (!Files.isDirectory(dir)) return@withContext emptyList()

        Files.list(dir).use { stream ->
            stream
                .map { p ->
                    FileEntry(
                        relativePath = root.relativize(p).toString().replace('\\', '/'),
                        sizeBytes = if (Files.isDirectory(p)) 0L else Files.size(p),
                        isDirectory = Files.isDirectory(p),
                    )
                }
                // 排序保证**确定性** —— 顺序不固定会让 prompt 变动、缓存归零
                .sorted(compareBy({ !it.isDirectory }, { it.relativePath }))
                .toList()
        }
    }

    override suspend fun readText(relativePath: String): String = withContext(Dispatchers.IO) {
        val p = PathGuard.resolve(root, relativePath)
        require(Files.isRegularFile(p)) { "不是文件：$relativePath" }
        val size = Files.size(p)
        require(size <= MAX_READ_BYTES) {
            "文件过大（${size}B > ${MAX_READ_BYTES}B）：$relativePath —— " +
                "直接读入会挤占上下文预算"
        }
        String(Files.readAllBytes(p), StandardCharsets.UTF_8)
    }

    override suspend fun writeText(relativePath: String, content: String): Long =
        withContext(Dispatchers.IO) {
            val p = PathGuard.resolve(root, relativePath)
            p.parent?.let { Files.createDirectories(it) }
            val bytes = content.toByteArray(StandardCharsets.UTF_8)
            Files.write(
                p, bytes,
                StandardOpenOption.CREATE,
                StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE,
            )
            bytes.size.toLong()
        }

    override suspend fun exists(relativePath: String): Boolean = withContext(Dispatchers.IO) {
        if (relativePath.isBlank()) return@withContext true
        val p = runCatching { PathGuard.resolve(root, relativePath) }.getOrNull()
            ?: return@withContext false
        Files.exists(p)
    }

    override suspend fun mkdirs(relativeDir: String) = withContext(Dispatchers.IO) {
        // 根目录 = 已存在（幂等，不报错）
        if (relativeDir.isBlank()) return@withContext
        val p = PathGuard.resolve(root, relativeDir)
        Files.createDirectories(p)
    }

    /**
     * 删除文件 / **空**目录（P1-3）。非空目录由 `Files.delete` 抛
     * `DirectoryNotEmptyException`（**不递归** —— 递归是工具层的决定，见
     * [WorkspaceFs.delete] 的语义边界）。路径越界由 [PathGuard] 拒（抛 `PathEscapeException`）。
     */
    override suspend fun delete(relativePath: String): Boolean = withContext(Dispatchers.IO) {
        if (relativePath.isBlank()) throw IllegalArgumentException("不能删除工作区根目录")
        val p = PathGuard.resolve(root, relativePath)
        Files.deleteIfExists(p)
    }

    /**
     * 字节读取（F6a）。**两道上限**：先按文件大小快速失败，再用 [readBytesLimited]
     * 兜住"stat 之后文件又变大"的竞态 —— 两条都超限**抛**，不返回截断结果。
     */
    override suspend fun readBytes(relativePath: String): ByteArray = withContext(Dispatchers.IO) {
        val p = PathGuard.resolve(root, relativePath)
        require(Files.isRegularFile(p)) { "不是文件：$relativePath" }
        val size = Files.size(p)
        require(size <= MAX_BINARY_BYTES) {
            "文件过大（${size}B > ${MAX_BINARY_BYTES}B）：$relativePath —— 二进制通道不截断"
        }
        Files.newInputStream(p).use { readBytesLimited(it, MAX_BINARY_BYTES) }
    }

    override suspend fun writeBytes(relativePath: String, bytes: ByteArray): Long =
        withContext(Dispatchers.IO) {
            require(bytes.size.toLong() <= MAX_BINARY_BYTES) {
                "写入过大（${bytes.size}B > ${MAX_BINARY_BYTES}B）：$relativePath"
            }
            val p = PathGuard.resolve(root, relativePath)
            p.parent?.let { Files.createDirectories(it) }
            Files.write(
                p, bytes,
                StandardOpenOption.CREATE,
                StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE,
            )
            bytes.size.toLong()
        }

    companion object {
        /** 打开（必要时创建）一个工作区。 */
        fun open(path: Path, name: String = path.fileName?.toString() ?: "workspace"): RealWorkspaceFs {
            Files.createDirectories(path)
            return RealWorkspaceFs(WorkspaceInfo(path.toAbsolutePath().normalize(), name))
        }
    }
}
