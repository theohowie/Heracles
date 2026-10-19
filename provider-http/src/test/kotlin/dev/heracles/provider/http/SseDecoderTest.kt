package dev.heracles.provider.http

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.nio.charset.StandardCharsets

/**
 * SSE 解码器的正确性守卫 —— `25-流式工作步骤.md` §5.2。
 *
 * 这些测试**全部是真实踩过的坑的固化**，不是凑覆盖率：
 *
 * | 测试 | 若失败，用户看到的现象 |
 * |---|---|
 * | [中文被网络分包切开也不乱码] | 思考内容变乱码（本项目输出全中文，必然踩） |
 * | [事件按空行切分而不是按行] | 事件被拦腰截断，JSON 解析失败 |
 * | [CRLF 行尾] | 行尾残留 `\r`，JSON 解析失败 |
 * | [注释心跳行被忽略] | 心跳被当成事件，解析失败 |
 */
class SseDecoderTest {

    private fun decodeAll(raw: String, chunkSize: Int = Int.MAX_VALUE): List<String> {
        val bytes = raw.toByteArray(StandardCharsets.UTF_8)
        val decoder = SseDecoder()
        val out = mutableListOf<String>()
        var i = 0
        while (i < bytes.size) {
            val end = minOf(i + chunkSize, bytes.size)
            out += decoder.accept(bytes, i, end - i)
            i = end
        }
        out += decoder.finish()
        return out
    }

    @Test
    fun `基本事件按空行切分`() {
        val raw = "data: {\"a\":1}\n\ndata: {\"b\":2}\n\n"
        assertEquals(listOf("""{"a":1}""", """{"b":2}"""), decodeAll(raw))
    }

    @Test
    fun `事件按空行切分而不是按行`() {
        // 一个事件横跨多行（SSE 规范允许 data 拆行），空行才是边界
        val raw = "data: AAA\ndata: BBB\n\n"
        // 规范：同一事件的多行 data 用 \n 连接
        assertEquals(listOf("AAA\nBBB"), decodeAll(raw))
    }

    @Test
    fun `DONE 标记原样吐出由上层过滤`() {
        val raw = "data: [DONE]\n\n"
        assertEquals(listOf("[DONE]"), decodeAll(raw))
    }

    @Test
    fun `CRLF 行尾不残留回车`() {
        val raw = "data: {\"a\":1}\r\n\r\n"
        val events = decodeAll(raw)
        assertEquals(listOf("""{"a":1}"""), events)
        assertTrue(!events[0].contains("\r"), "事件里不得残留 \\r（会让 JSON 解析失败）")
    }

    @Test
    fun `注释心跳行被忽略`() {
        val raw = ": keep-alive\n\ndata: {\"a\":1}\n\n"
        assertEquals(listOf("""{"a":1}"""), decodeAll(raw))
    }

    @Test
    fun `冒号后无空格也兼容`() {
        assertEquals(listOf("""{"a":1}"""), decodeAll("data:{\"a\":1}\n\n"))
    }

    /**
     * ★ 最重要的一条：**中文被网络分包切开不得乱码**。
     *
     * 中文一个字 3 字节（UTF-8）。TCP 分包与 4 KiB 缓冲都会**从字符中间切开**。
     * 若用 `BufferedReader.readLine()` 或"每读一段就 toString"，半个字符会变成
     * 替换字符 U+FFFD —— 而且**不报错**，用户只会看到"思考变成一堆问号"。
     *
     * 这里刻意逐字节喂（chunkSize = 1），把最坏的分包情形钉死。
     */
    @Test
    fun `中文被网络分包切开也不乱码`() {
        val thinking = "我需要先查看一下这个文件的内容"
        val raw = "data: {\"delta\":{\"reasoning_content\":\"$thinking\"}}\n\n"

        val events = decodeAll(raw, chunkSize = 1)

        assertEquals(1, events.size)
        assertTrue(
            events[0].contains(thinking),
            "逐字节喂入后中文必须完好，实际得到：${events[0]}",
        )
        assertTrue(!events[0].contains('\uFFFD'), "不得出现替换字符 U+FFFD（乱码信号）")
    }

    @Test
    fun `按 3 字节边界切也不乱码`() {
        val thinking = "思考过程一二三四五六七八九十"
        val raw = "data: {\"reasoning_content\":\"$thinking\"}\n\n"
        // 3 是中文的字节宽度；从缓冲起点对齐切会让很多切点落在字符内部
        val events = decodeAll(raw, chunkSize = 3)
        assertEquals(1, events.size)
        assertTrue(events[0].contains(thinking), "实际：${events[0]}")
    }

    @Test
    fun `最后一个事件缺结尾空行也不丢`() {
        // 部分 llama.cpp 版本最后一个事件不带结尾空行
        val raw = "data: {\"a\":1}\n\ndata: {\"b\":2}"
        assertEquals(listOf("""{"a":1}""", """{"b":2}"""), decodeAll(raw))
    }

    @Test
    fun `空输入不产生事件`() {
        assertEquals(emptyList<String>(), decodeAll(""))
        assertEquals(emptyList<String>(), decodeAll("\n\n"))
    }
}
