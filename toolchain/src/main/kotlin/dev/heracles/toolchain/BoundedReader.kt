package dev.heracles.toolchain

import dev.heracles.core.contract.Contract
import java.io.InputStream
import java.nio.charset.Charset
import java.nio.file.Files
import java.nio.file.Path

/**
 * **流式有界读取器** —— 物理防 OOM（2026-10-21）。
 *
 * ## 它修复的缺陷
 *
 * 旧 `LocalProcessShellRunner.readCapped()`（`LocalProcessShellRunner.kt:120-129`）：
 *
 * ```kotlin
 * private fun readCapped(p: Path): String {
 *     val size = Files.size(p)
 *     val text = String(Files.readAllBytes(p), charset)   // ← 先把整个文件读进内存
 *     return if (size > Contract.Shell.MAX_CAPTURED_BYTES) { … text.take(…) … }
 * }
 * ```
 *
 * 注释写着「读回输出并夹到上限（`-v` 类输出能把磁盘/内存打满）」—— 但
 * **内存这一半完全没防住**：一个 500MB 的日志会先 `readAllBytes` **OOM**，
 * 然后才轮到那个 `if` 判断。这是"防爆装置本身是爆点"的典型。
 *
 * 另外旧代码还有两处**单位混用**：
 * - `Files.size(p)` 是**字节**，`text.take(...)` 是**字符** —— 两者直接比较是错的
 * - `Contract.Shell.MAX_CAPTURED_BYTES` 名字是 BYTES，实际当字符用
 *
 * ## 本类的做法
 *
 * 1. **流式读**：`InputStream` + 固定大小缓冲区，到上限**立即停**，永不把整份文件驻留内存
 * 2. **按字节计量**：上限是**字节**，读的时候就用字节判
 * 3. **截断必须如实标记**：返回 [BoundedRead] 带 `truncated` 标志与真实总字节数
 *
 * ## 为什么仍然要保留上限（而不是完全不管）
 *
 * 这是**物理约束**，不是模型限制：Android 上单个字符串超过一定量级会 OOM
 * 或严重拖慢 GC。日志本身完整落盘（磁盘不受此限），进上下文的才有上限。
 */
object BoundedReader {

    /**
     * 从文件流式读取，最多 [maxBytes] 字节。
     *
     * @param maxBytes 字节上限（默认 [Contract.Shell.MAX_CAPTURED_BYTES]）
     */
    fun readFile(path: Path, charset: Charset, maxBytes: Int = Contract.Shell.MAX_CAPTURED_BYTES): BoundedRead {
        if (!Files.exists(path)) return BoundedRead("", truncated = false, totalBytes = 0)
        return Files.newInputStream(path).use { input ->
            readStream(input, charset, maxBytes)
        }
    }

    /**
     * 从任意流读取（shell 的 stdout/stderr 都能用）。
     *
     * ## 实现要点：**永远不多读一个缓冲区**
     *
     * 逐块读 8KB，累计到 `maxBytes` 就 `break`。这样峰值内存 = `maxBytes + 8KB`，
     * 与文件实际大小**无关**（500MB 和 5KB 花的是一样的内存）。
     */
    fun readStream(
        input: InputStream,
        charset: Charset,
        maxBytes: Int = Contract.Shell.MAX_CAPTURED_BYTES,
    ): BoundedRead {
        require(maxBytes >= 1) { "maxBytes 必须 ≥ 1，收到 $maxBytes" }

        val buffer = ByteArray(READ_CHUNK_BYTES)
        // 上限 + 一个缓冲区：够装下"刚好超限"的证据，又不会无界增长
        val sink = java.io.ByteArrayOutputStream(minOf(maxBytes, 64 * 1024))
        var total = 0L
        var truncated = false

        while (true) {
            val n = input.read(buffer)
            if (n <= 0) break
            total += n
            val room = maxBytes - sink.size()
            if (room <= 0) {
                truncated = true
                // ★ 但还要继续数总字节数（如实报告"总共多少"），只是**不再缓存**
                continue
            }
            if (n <= room) {
                sink.write(buffer, 0, n)
            } else {
                sink.write(buffer, 0, room)
                truncated = true
            }
        }

        return BoundedRead(
            text = String(sink.toByteArray(), charset),
            truncated = truncated,
            totalBytes = total,
        )
    }

    /**
     * 缓冲区大小 8 KB。
     *
     * 取 8KB 的理由：小于页大小（4KB）对齐的倍数不好；大于 64KB 会在手机上
     * 造成明显的分配压力。8KB 既不会频繁系统调用，也不会让单次分配过大。
     */
    private const val READ_CHUNK_BYTES = 8 * 1024
}

/**
 * 一次有界读取的结果。
 *
 * @param text 读到的正文（最多 `maxBytes` 字节解码后）
 * @param truncated 是否**真的**发生了截断
 * @param totalBytes 实际读到的总字节数（**即使截断也如实统计**）
 */
data class BoundedRead(
    val text: String,
    val truncated: Boolean,
    val totalBytes: Long,
) {
    /**
     * 给模型看的说明 —— 截断时**必须**出现，且必须说清"总共多少、给了多少"。
     *
     * 旧实现的表头写「这是完整日志」（`ShellTools.kt:188-196`）而实际被剪过 ——
     * 那是**假信息**，模型会基于残缺日志下结论。
     */
    fun truncationNote(): String = if (!truncated) {
        ""
    } else {
        "\n…（输出过大：共 $totalBytes 字节，此处只保留前 ${text.toByteArray(Charsets.UTF_8).size} 字节。" +
            "完整内容在落盘文件里，可用 read_file 分段读取。）"
    }
}
