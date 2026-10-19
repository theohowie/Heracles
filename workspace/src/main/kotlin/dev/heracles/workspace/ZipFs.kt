package dev.heracles.workspace

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/** 归档操作的结果：条目数与总字节数。 */
data class ZipOutcome(val entries: Int, val bytes: Long)

/** 压缩包内的一个条目。 */
data class ArchiveEntry(
    val name: String,
    val isDirectory: Boolean,
    /** 原始字节数；`-1` = 未知（部分生成器不填） */
    val size: Long,
)

/**
 * ZIP 读写 —— `26-编码层工具链与逆向引擎.md` §3.1、§4.2。
 *
 * 供 `unzip_file` / `zip_file` 两个工具使用。
 *
 * ## 安全性：zip-slip 必须拦住
 *
 * 压缩包里可以放**任意文件名**，包括 `../../../etc/passwd`。天真实现
 * （`dest.resolve(entry.name)` 后直接写）会让一个恶意压缩包写到工作区之外 ——
 * 这正是 `PathGuard` 存在的理由，但 `PathGuard` **只在解压前校验了压缩包本身**，
 * 管不到包**内部**的条目名。
 *
 * ⇒ 每个条目名都要独立校验：规范化后**必须**仍在目标目录之下。
 *
 * ## 确定性：固定条目时间戳
 *
 * 所有条目用 [FIXED_TIME] 而不取"当前时间"。理由：本工具会被用于
 * **重打包 APK**，而"同一份内容出两个不同字节的包"会让
 * **可复现构建**失效（也是签名/比对时的经典噪声源）。
 */
class ZipFs(rootPath: Path) {

    private val root: Path = rootPath.toAbsolutePath().normalize()

    /**
     * 解压。
     *
     * @param archive 工作区相对路径的压缩包
     * @param destDir 工作区相对路径的目标目录（`""` = 工作区根）
     */
    suspend fun unzip(archive: String, destDir: String): ZipOutcome = withContext(Dispatchers.IO) {
        val src = PathGuard.resolve(root, archive)
        require(Files.isRegularFile(src)) { "不是文件：$archive" }
        val dest = if (destDir.isBlank()) root else PathGuard.resolve(root, destDir)
        Files.createDirectories(dest)
        val destNorm = dest.normalize()

        var count = 0
        var bytes = 0L
        ZipFile(src.toFile()).use { zf ->
            // 顺序确定：按条目名排序，避免不同实现下的顺序差异
            val entries = zf.entries().toList().sortedBy { it.name }
            for (entry in entries) {
                // ★ zip-slip 防护：条目名可能带 `../`
                val target = safeResolve(destNorm, entry.name, archive)
                if (entry.isDirectory) {
                    Files.createDirectories(target)
                    continue
                }
                target.parent?.let { Files.createDirectories(it) }
                zf.getInputStream(entry).use { input ->
                    Files.newOutputStream(target).use { output -> input.copyTo(output) }
                }
                count++
                bytes += entry.size.coerceAtLeast(0)
            }
        }
        ZipOutcome(count, bytes)
    }

    /**
     * 压缩。
     *
     * @param srcDir 工作区相对路径的源目录（`""` = 工作区根）
     * @param archive 工作区相对路径的输出压缩包（**会被覆盖**）
     * @param apkLayout 按 **APK 的存放纪律**选压缩方式：`resources.arsc` 与 `*.so`
     *   不压缩（STORED）。
     *
     *   ## 为什么这条不能省
     *
     *   `resources.arsc` 保持未压缩，是它**能被 mmap 直读**（不占 Java 堆、不拷贝）的前提；
     *   `lib` 下的 `.so` 未压缩 + **页对齐（4096）**后同样可以直接映射执行。
     *   Android 自己的打包工具就是这么做的。如果重打包时一律 DEFLATE，对齐就**失去意义**
     *   （对齐只管未压缩数据），产物还多一次解压开销。
     *
     *   ⇒ **只对"重打包成 APK"这条路径**设 true（[ApkReverseEngine.recompile]）；
     *   通用压缩工具（`zip_file`）保持 false —— 普通压缩包没有这套纪律。
     */
    suspend fun zip(srcDir: String, archive: String, apkLayout: Boolean = false): ZipOutcome = withContext(Dispatchers.IO) {
        val src = if (srcDir.isBlank()) root else PathGuard.resolve(root, srcDir)
        require(Files.isDirectory(src)) { "不是目录：$srcDir" }
        val out = PathGuard.resolve(root, archive)
        out.parent?.let { Files.createDirectories(it) }

        var count = 0
        var bytes = 0L
        ZipOutputStream(Files.newOutputStream(out)).use { zos ->
            // 排序保证**确定性**（同内容 → 同字节流）
            val files = Files.walk(src).use { s ->
                s.filter { Files.isRegularFile(it) }
                    .sorted()
                    .toList()
            }
            for (f in files) {
                // 别把输出包自己塞进去
                if (f.normalize() == out.normalize()) continue
                val name = src.relativize(f).toString().replace('\\', '/')
                val entry = ZipEntry(name).apply { time = FIXED_TIME }
                if (apkLayout && storeUncompressed(name)) {
                    // STORED 的本地头必须写明长度与 CRC（不能留空），所以先算一遍再写
                    entry.method = ZipEntry.STORED
                    entry.size = Files.size(f)
                    entry.compressedSize = entry.size
                    entry.crc = crc32Of(f)
                }
                zos.putNextEntry(entry)
                Files.newInputStream(f).use { it.copyTo(zos) }
                zos.closeEntry()
                count++
                bytes += Files.size(f)
            }
        }
        ZipOutcome(count, bytes)
    }

    /**
     * 把 [sourceFile] 作为 [entryName] 写入**已存在**的压缩包（同名的被替换）。
     *
     * ## 为什么需要它
     *
     * `aapt2 link -o app.apk` 已经产出了一个 APK（含二进制清单 + `resources.arsc`），
     * 只差 `classes.dex`。把 dex 塞进去的天真做法是 shell 里 `zip -j app.apk classes.dex`
     * —— 而 **Android 的 `/system/bin` 里没有 `zip`**，也没有 `jar`。
     *
     * ⇒ 这一步只能在**进程内**做。顺带还避免了一次 40–80MB 的工具下载。
     *
     * ## 实现要点：**保留原有的压缩方式**
     *
     * `aapt2` 产出的 `resources.arsc` 是 **STORED**（未压缩）—— 这是
     * `zipalign` 之后它能被 mmap 直读的前提。若这里统一用 DEFLATE 重写，
     * `resources.arsc` 会变成压缩存储，对齐就失去意义。
     *
     * ⇒ 逐条判断原条目的 `method`，STORED 的仍然 STORED，其余 DEFLATE。
     *
     * @return 写入的字节数
     */
    suspend fun putFile(archive: String, entryName: String, sourceFile: String): Long =
        withContext(Dispatchers.IO) {
            val target = PathGuard.resolve(root, archive)
            // 报错时把**解析后的绝对路径**也打出来：在真机上"文件明明在那儿"
            // 多半是权限/可见性问题（外置存储的 FUSE 只认 mode），只报相对路径
            // 会让人以为路径算错了（`实测-12` §13 的路径诊断就是这么逼出来的）。
            require(Files.isRegularFile(target)) { "压缩包不存在：$archive → $target" }
            val src = PathGuard.resolve(root, sourceFile)
            require(Files.isRegularFile(src)) { "源文件不存在：$sourceFile" }
            val name = entryName.replace('\\', '/')
            require(!name.startsWith("/") && !name.split('/').any { it == ".." }) {
                "条目名非法：$entryName"
            }

            val tmp = target.resolveSibling(target.fileName.toString() + ".tmp")
            val size = Files.size(src)
            ZipOutputStream(Files.newOutputStream(tmp)).use { zos ->
                // ① 原样搬运（跳过同名条目）
                ZipFile(target.toFile()).use { zf ->
                    for (e in zf.entries()) {
                        if (e.name == name) continue
                        val out = ZipEntry(e.name).apply { time = FIXED_TIME }
                        // ★ 保留压缩方式（见 KDoc）
                        if (e.method == ZipEntry.STORED && e.size >= 0 && e.crc >= 0) {
                            out.method = ZipEntry.STORED
                            out.size = e.size
                            out.compressedSize = e.size
                            out.crc = e.crc
                        }
                        zos.putNextEntry(out)
                        zf.getInputStream(e).use { it.copyTo(zos) }
                        zos.closeEntry()
                    }
                }
                // ② 追加新条目
                zos.putNextEntry(ZipEntry(name).apply { time = FIXED_TIME })
                Files.newInputStream(src).use { it.copyTo(zos) }
                zos.closeEntry()
            }
            Files.move(tmp, target, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            size
        }

    /** 列出压缩包内的条目（名字 + 是否目录 + 大小），按名字排序保证确定性。 */
    suspend fun listEntries(archive: String): List<ArchiveEntry> = withContext(Dispatchers.IO) {
        val target = PathGuard.resolve(root, archive)
        require(Files.isRegularFile(target)) { "压缩包不存在：$archive" }
        ZipFile(target.toFile()).use { zf ->
            zf.entries().toList()
                .map { ArchiveEntry(it.name, it.isDirectory, it.size) }
                .sortedBy { it.name }
        }
    }

    /** 解出单个条目到工作区文件（逆向时先取出 `classes.dex` 再反编译）。 */
    suspend fun extractEntry(archive: String, entryName: String, destFile: String): Long =
        withContext(Dispatchers.IO) {
            val target = PathGuard.resolve(root, archive)
            val dest = PathGuard.resolve(root, destFile)
            dest.parent?.let { Files.createDirectories(it) }
            ZipFile(target.toFile()).use { zf ->
                val entry = zf.getEntry(entryName)
                    ?: throw IllegalArgumentException("压缩包里没有条目：$entryName")
                zf.getInputStream(entry).use { input ->
                    Files.newOutputStream(dest).use { output -> input.copyTo(output) }
                }
                Files.size(dest)
            }
        }

    /**
     * APK 里哪类条目**必须**保持未压缩（STORED）。
     *
     * | 条目 | 理由 |
     * |---|---|
     * | `resources.arsc`（含任意路径） | 要能被 mmap 直读，不占堆、不拷贝 |
     * | 任意 `*.so` | 要先页对齐（4096）再映射执行 |
     *
     * 其余（png/xml/dex/…）照常压缩 —— 它们本来就要解压，压着更省空间。
     * 判定规则与 [ZipAligner] 的对齐规则**同源**：对齐只对未压缩条目有意义，
     * 所以"哪些不压缩"和"哪些要对齐"必须是同一套名单，否则一处改了一处没改，
     * 症状是"对齐了但没人用得上"。
     */
    private fun storeUncompressed(name: String): Boolean =
        name.endsWith(".so") || name == "resources.arsc" || name.endsWith("/resources.arsc")

    /** 流式算 CRC32（不把整个文件读进内存 —— `resources.arsc` 可能几十 MB）。 */
    private fun crc32Of(f: Path): Long {
        val crc = CRC32()
        val buf = ByteArray(64 * 1024)
        Files.newInputStream(f).use { input ->
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                crc.update(buf, 0, n)
            }
        }
        return crc.value
    }

    /**
     * 把压缩包内的条目名解析到目标目录内，越界即拒绝。
     *
     * @throws PathEscapeException 条目名试图逃出目标目录（zip-slip）
     */
    private fun safeResolve(destNorm: Path, entryName: String, archive: String): Path {
        val cleaned = entryName.replace('\\', '/')
        if (cleaned.startsWith("/") || Regex("^[A-Za-z]:").containsMatchIn(cleaned)) {
            throw PathEscapeException(archive, "压缩包内含绝对路径条目：$entryName")
        }
        val target = destNorm.resolve(cleaned).normalize()
        if (!target.startsWith(destNorm)) {
            throw PathEscapeException(archive, "压缩包内含越界条目（zip-slip）：$entryName")
        }
        return target
    }

    companion object {
        /** 固定条目时间（ms，2000-01-01）—— 见类注释的"确定性"一节 */
        const val FIXED_TIME = 946_684_800_000L
    }
}
