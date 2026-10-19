package dev.heracles.provider.http

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.ProviderCallException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URI
import java.nio.charset.StandardCharsets
import java.time.Duration

/**
 * HTTP + JSON 公共设施。
 *
 * ## ★ 为什么用 `HttpURLConnection` 而不是 `java.net.http.HttpClient`
 *
 * 首版用的是 `java.net.http.HttpClient`（JDK 11+），理由是"JDK 自带不引依赖"。
 * **但那个理由是错的** ——
 * `java.net.http` 包**在 `android.jar` 里根本不存在**（Android 从未包含它）。
 *
 * 已用 Android 37 的 `android.jar` 实测确认：
 *
 * | API | Android |
 * |---|---|
 * | `java.net.http.HttpClient` | ❌ **不存在** |
 * | `java.net.HttpURLConnection` | ✅ 存在 |
 * | `java.net.URL` | ✅ 存在 |
 *
 * 结论：**改用 `HttpURLConnection`，零依赖**。
 * 不需要 OkHttp、不需要 Ktor（见 `11-复用调研.md` §5 的依赖准入政策）。
 *
 * ## `HttpURLConnection` 的坑（这里都处理了）
 *
 * | 坑 | 处理 |
 * |---|---|
 * | 默认不跟随重定向 | 手动处理或依赖默认（POST 不自动跟随，可接受） |
 * | 错误流与正常流分离 | **必须读 `errorStream`**，否则拿不到 API 的错误信息 |
 * | 连接复用 | 读完后 `disconnect()`，否则连接池泄漏 |
 * | 默认超时是无限的 | 显式设置 connect/read 超时 |
 * | `getOutputStream` 前不能调 `getInputStream` | 严格按顺序 |
 *
 * 这些胶水写一次，全项目复用 —— 比引入 700 KB 的网络库划算。
 */
internal object HttpJson {

    /** POST 一个 JSON 体，返回解析后的 [JsonObject]。 */
    fun postJson(
        url: String,
        body: String,
        headers: Map<String, String> = emptyMap(),
        timeout: Duration = Duration.ofMinutes(5),
    ): JsonObject {
        val raw = request("POST", url, body, headers, timeout)
        // ★ 判型（2026-10-14）：响应体是数组/标量/null 时
        //   `asJsonObject` 会抛 ClassCastException —— 换成能读懂的错误
        val el = JsonParser.parseString(raw)
        require(el.isJsonObject) {
            "期望 JSON 对象，实际收到：" +
                (if (el.isJsonArray) "数组" else el.toString().take(120))
        }
        return el.asJsonObject
    }

    fun getJson(
        url: String,
        headers: Map<String, String> = emptyMap(),
        timeout: Duration = Duration.ofSeconds(30),
    ): JsonObject {
        val raw = request("GET", url, null, headers, timeout)
        val el = JsonParser.parseString(raw)
        require(el.isJsonObject) {
            "期望 JSON 对象，实际收到：" +
                (if (el.isJsonArray) "数组" else el.toString().take(120))
        }
        return el.asJsonObject
    }

    /** GET 原始文本（`/health` 这类非 JSON 端点用）。 */
    fun getText(
        url: String,
        headers: Map<String, String> = emptyMap(),
        timeout: Duration = Duration.ofSeconds(30),
    ): String = request("GET", url, null, headers, timeout)

    /** POST 原始文本，返回原始响应文本。 */
    fun postText(
        url: String,
        body: String,
        headers: Map<String, String> = emptyMap(),
        timeout: Duration = Duration.ofMinutes(5),
    ): String = request("POST", url, body, headers, timeout)

    /**
     * POST 一个 JSON 体，**逐行流式**消费 SSE 响应。
     *
     * ## ★ 为什么不能"先 `readText()` 再切分"
     *
     * 用户的原话是「**一个字一个字出来，不是等 AI 想完了再全部展示**」。
     * 先把整个响应体读进内存再解析，**就回到了非流式** —— 只是换了个 API 名字。
     * 所以这里必须是：读到一个事件 → 立刻 `emit` → 上层立刻渲染。
     *
     * ## 取消语义（最容易泄漏的一点）
     *
     * 本函数是**阻塞式** Flow（不是 `callbackFlow`）：
     * `emit` 是挂起点，但 `read()` 不是 —— 也就是说取消**不会**自动打断正在进行的那次
     * `read()`。所以 `finally` 里必须 `close()` 输入流，让阻塞中的 `read()`
     * 立刻抛 `IOException` 退出。否则：
     *  - 读线程永远挂在 `read()` 上，协程结构化并发**永远不结束**
     *  - 连接不归还连接池
     *
     * `finally` 在**取消**时同样执行（阻塞流被挂起在 `emit` 上时取消会直接走 `finally`），
     * 所以这条路径是可靠的。
     *
     * ## 错误处理
     *
     * - 非 2xx：读 `errorStream` 抛 [HttpJsonException]（与 [request] 一致 ——
     *   拿不到错误体就只能看到"HTTP 400"六个字符，排查成本极高）
     * - 流中途断开：`read()` 抛 `IOException`，Flow 以异常结束（上层决定是否重试）
     * - `[DONE]` 标记会被过滤掉，**不会**作为事件发给上层（它不是 JSON）
     */
    fun postSse(
        url: String,
        body: String,
        headers: Map<String, String> = emptyMap(),
        timeout: Duration = Duration.ofMinutes(15),
    ): Flow<SseEvent> = flow {
        val conn = (URI.create(url).toURL().openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            val ms = timeout.toMillis().coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            connectTimeout = ms
            // 流式下 readTimeout 是"两个 chunk 之间的最大间隔"，不是"整轮最大耗时"。
            // 设得太小会在长思考（本地 thinking 一段可十几秒无输出）时误杀。
            readTimeout = ms
            instanceFollowRedirects = false
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            // 显式要求 SSE：某些网关（含 DashScope）在缺失 Accept 时会走非流式分支
            setRequestProperty("Accept", "text/event-stream")
        }

        var stream: InputStream? = null
        try {
            conn.doOutput = true
            conn.outputStream.use { it.write(body.toByteArray(StandardCharsets.UTF_8)) }

            val code = conn.responseCode
            if (code !in 200..299) {
                val detail = conn.errorStream?.let { readAll(it) } ?: "(无响应体)"
                throw HttpJsonException(code, extractErrorDetail(detail))
            }

            val input = conn.inputStream ?: throw HttpJsonException(code, "(响应体为空)")
            stream = input

            // ★ 不用 BufferedReader.readLine()：它会把半个 UTF-8 字符当合法文本
            //   （中文 3 字节被网络分包切开 → 乱码），本项目输出全中文，必然踩。
            //   SseDecoder 在【字节层】切分，只对完整的行做 UTF-8 解码。
            val decoder = SseDecoder()
            val buf = ByteArray(SSE_READ_BUFFER_BYTES)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                for (payload in decoder.accept(buf, 0, n)) {
                    if (payload != SseDecoder.DONE_MARKER) emit(SseEvent(payload))
                }
            }
            for (payload in decoder.finish()) {
                if (payload != SseDecoder.DONE_MARKER) emit(SseEvent(payload))
            }
        } finally {
            // ★ 取消路径的关键：close() 打断阻塞中的 read()，disconnect() 归还连接
            runCatching { stream?.close() }
            conn.disconnect()
        }
    }

    private fun request(
        method: String,
        url: String,
        body: String?,
        headers: Map<String, String>,
        timeout: Duration,
    ): String {
        val conn = (URI.create(url).toURL().openConnection() as HttpURLConnection).apply {
            requestMethod = method
            // java.time.Duration.toMillis() 是内置方法；夹取到 Int 范围（超长超时会溢出）
            val ms = timeout.toMillis().coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            connectTimeout = ms
            readTimeout = ms
            // HttpURLConnection 默认会对 POST 做透明重定向，
            // 那会把体积不小的 body 重复发送。显式关掉。
            instanceFollowRedirects = method == "GET"
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
        }

        return try {
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                conn.outputStream.use { it.write(body.toByteArray(StandardCharsets.UTF_8)) }
            }

            val code = conn.responseCode
            // ★ 关键：错误响应必须从 errorStream 读，否则 detail 永远是空串。
            val stream: InputStream = if (code in 200..299) {
                conn.inputStream ?: return ""
            } else {
                conn.errorStream ?: return throw HttpJsonException(code, "(无响应体)")
            }
            val text = stream.use { readAll(it) }

            if (code !in 200..299) {
                throw HttpJsonException(code, extractErrorDetail(text))
            }
            text
        } finally {
            // 必须 disconnect —— 否则连接不归还池子，长时间运行会泄漏
            conn.disconnect()
        }
    }

    private fun readAll(input: InputStream): String =
        BufferedReader(InputStreamReader(input, StandardCharsets.UTF_8)).use { it.readText() }

    /** 从各家格式的错误体里尽力提取可读信息。 */
    private fun extractErrorDetail(raw: String): String {
        if (raw.isBlank()) return "(空响应体)"
        // OpenAI 兼容：{"error":{"message":"..."}}
        runCatching {
            val o = JsonParser.parseString(raw).asJsonObject
            o.getAsJsonObject("error")?.get("message")?.asString?.let { return it }
            o.get("message")?.asString?.let { return it }
            // llama.cpp：{"error":"..."}
            o.get("error")?.takeIf { it.isJsonPrimitive }?.asString?.let { return it }
        }
        return raw.take(400)
    }

    /** 单次读取的字节数 —— 见 [Contract.Stream] */
    private val SSE_READ_BUFFER_BYTES: Int = Contract.Stream.READ_BUFFER_BYTES
}

/**
 * 一个**原始** SSE 事件负载（`data:` 后面的那段字符串）。
 *
 * 刻意不在这一层解析 JSON：SSE 只是传输格式，
 * 各家 provider 的载荷结构不同（llama.cpp 会多带 `timings`），
 * 解析责任属于各 provider。这样 `HttpJson` 不需要知道任何模型厂商的事。
 */
@JvmInline
value class SseEvent(val payload: String)

/**
 * HTTP 层异常。`statusCode` 供上层区分"限流可重试"与"请求错误不可重试"。
 *
 * 2026-10-19：改为继承 [ProviderCallException] —— 让 `:agent`（不依赖本模块）
 * 也能消费"可重试"语义，而不用去认 HTTP 异常类型。
 */
class HttpJsonException(
    val statusCode: Int,
    val detail: String,
) : ProviderCallException(
    message = "HTTP $statusCode: $detail",
    // 429 / 5xx 属于**可重试**（`02-契约规范.md` §9 的语义）
    retryable = statusCode == 429 || statusCode in 500..599,
)
