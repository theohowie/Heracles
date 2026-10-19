package dev.heracles.provider.http

/**
 * SSE（`text/event-stream`）解码器 —— `25-流式工作步骤.md` §5.2。
 *
 * ## 为什么单独成文件、而不是塞进 `HttpJson`
 *
 * SSE 的正确性有三个**很容易写错、又都不在 HTTP 层**的点：
 *
 * | # | 坑 | 写错的后果 |
 * |---|---|---|
 * | 1 | 事件边界是**空行**（`\n\n`），不是"一行一个事件" | 事件被拦腰截断，JSON 解析失败 |
 * | 2 | 一次网络读**可能拿到半个 UTF-8 字符**（中文一个字最多 3 字节） | **中文思考内容变乱码**（本项目输出全中文，必然踩） |
 * | 3 | `\r\n` 与 `\n` 两种行尾都可能出现 | 行内容尾部残留 `\r`，JSON 解析失败 |
 *
 * 把它做成**不依赖 socket 的纯函数**，上面三条都能被单元测试直接钉死 ——
 * 而"逐 token 中文乱码"这类缺陷一旦漏到 UI 上极难定位。
 *
 * ## 用法
 *
 * ```kotlin
 * val decoder = SseDecoder()
 * while (true) {
 *     val n = input.read(buf)
 *     if (n < 0) break
 *     for (payload in decoder.accept(buf, 0, n)) { /* 一个 data: 的负载 */ }
 * }
 * ```
 */
internal class SseDecoder {

    /** 尚未构成完整行的字节尾巴（含可能被切成两半的 UTF-8 序列） */
    private val lineBuffer = java.io.ByteArrayOutputStream()

    /**
     * 喂入一段原始字节，返回**本次能完整解析出的** `data:` 负载。
     *
     * 调用方按返回顺序逐个处理；未构成完整事件的部分留在内部。
     */
    fun accept(bytes: ByteArray, offset: Int, length: Int): List<String> {
        if (length <= 0) return emptyList()
        val out = mutableListOf<String>()
        var i = offset
        val end = offset + length
        while (i < end) {
            val b = bytes[i]
            if (b == LF) {
                // 完整一行（不含 LF）—— 末尾可能带 CR，交给 handleLine 裁掉
                val line = lineBuffer.toByteArray().toString(Charsets.UTF_8)
                lineBuffer.reset()
                handleLine(line, out)
            } else {
                lineBuffer.write(b.toInt())
            }
            i++
        }
        return out
    }

    /**
     * 流结束时调用：把残留在缓冲里的最后一行也尝试解析。
     *
     * 某些服务端（含部分 llama.cpp 版本）最后一个事件**不带结尾空行**，
     * 不调用本方法就会丢掉最后一个 token。
     */
    fun finish(): List<String> {
        val out = mutableListOf<String>()
        if (lineBuffer.size() > 0) {
            val line = lineBuffer.toByteArray().toString(Charsets.UTF_8)
            lineBuffer.reset()
            handleLine(line, out)
        }
        // 末尾空行触发的 flush 由 handleLine 内部在下一次 KEEP_ALIVE 时处理；
        // 这里补一次，覆盖"最后一个事件后没有空行"的情形。
        flushPending(out)
        return out
    }

    /** 已完成、但还没被空行确认的 data 负载（SSE 规范：同一个事件的多个 data 行要拼接） */
    private val pendingData = StringBuilder()

    /** 空行是否见过（用于拼接逻辑） */
    private var pending = false

    private fun handleLine(rawLine: String, out: MutableList<String>) {
        // 行尾 CR 必须裁掉（\r\n 行尾）；只裁一个，不 trim 内容空格
        val line = if (rawLine.endsWith("\r")) rawLine.dropLast(1) else rawLine

        if (line.isEmpty()) {
            // ★ 空行 = 事件边界
            flushPending(out)
            return
        }

        // SSE 规范允许 `:` 开头的注释行（心跳），必须忽略
        if (line.startsWith(":")) return

        val colon = line.indexOf(':')
        val field = if (colon < 0) line else line.substring(0, colon)
        if (field != "data") return // event: / id: / retry: 本项目用不到

        if (colon < 0) {
            pendingData.append("\n")
        } else {
            // 规范：冒号后若有一个空格，去掉它；其余空格保留
            val value = line.substring(colon + 1).removePrefix(" ")
            if (pendingData.isNotEmpty()) pendingData.append("\n")
            pendingData.append(value)
        }
        pending = true
    }

    private fun flushPending(out: MutableList<String>) {
        if (!pending) return
        val payload = pendingData.toString()
        pendingData.setLength(0)
        pending = false
        if (payload.isNotEmpty()) out += payload
    }

    companion object {
        private const val LF: Byte = 0x0A

        /** OpenAI 兼容流式的终止标记（**不是 JSON**，必须特判） */
        const val DONE_MARKER = "[DONE]"
    }
}
