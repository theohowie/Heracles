package dev.heracles.agent.tools

import dev.heracles.agent.AgentTool
import dev.heracles.agent.ToolOutcome
import dev.heracles.core.contract.Contract
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URI
import java.nio.charset.Charset
import java.util.zip.GZIPInputStream

/**
 * **联网抓取网页** —— `web_fetch`（2026-10-19，对齐 Claude Code / Codex 的 WebFetch）。
 *
 * ## 为什么必须有它
 *
 * 手机上的编码智能体经常需要"看文档 / 看 API 说明 / 核对某个报错"。没有联网工具时，
 * 模型只能靠训练数据猜（幻觉），或让用户自己贴内容。成熟智能体都提供 WebFetch。
 *
 * ## 安全边界（这不是可选优化）
 *
 * · 只允许 `http` / `https`
 * · **拒绝内网 / 本机 / 链路本地地址** —— 判定在 DNS 解析之后做（见 [isBlockedHost]），
 *   否则 `http://127.0.0.1:8080`、`http://192.168.1.1`、十进制写法都能绕过
 * · 下载字节与正文长度都有硬上限（[Contract.Web]）—— 结果会永久留在 append-only 会话里
 *
 * ## 它**不是**浏览器
 *
 * 不执行 JS、不带 Cookie、不做登录。抓不到动态渲染的内容时**如实返回空/很少的正文**，
 * 由模型自己决定换 URL 或告诉用户 —— 不假装"页面就是这样"。
 */
/**
 * 联网工具的分组表（给 `search_tools` 用）与装配入口。
 *
 * 它与 [AndroidTools]/[PathTools] 同构：**分组表必须覆盖全部长尾工具** ——
 * 漏一个 ⇒ 那个工具的同义说法在检索里搜不到、静默退化。
 */
object WebTools {
    val GROUPS: Map<String, dev.heracles.core.tool.ToolGroup> = mapOf(
        "web_fetch" to dev.heracles.core.tool.ToolGroup.NETWORK,
    )

    /** 生产装配：默认拒绝内网地址（`allowLoopback` 只给测试）。 */
    fun create(): List<AgentTool> = listOf(WebFetchTool())
}

class WebFetchTool(
    /**
     * 测试用：允许 loopback（本地起 HTTP server 验真实抓取路径）。
     * **生产装配永远不传** ⇒ 默认拒绝内网地址。
     */
    private val allowLoopback: Boolean = false,
) : AgentTool {

    /**
     * **网络 IO，但可并发**（2026-10-19）。
     *
     * 它是最值得并发的工具（一次抓 3 个文档页，串行要等 3 个 RTT）。
     * 不共享可变状态、不写文件 ⇒ 并发没有正确性问题。
     * 数量由批次上限兜住（`Contract.Tools.MAX_NATIVE_CALLS_PER_TURN` = 4）。
     */
    override val parallelSafe: Boolean get() = true

    override val spec = ToolSpec(
        name = "web_fetch",
        description = "抓取一个公开网页并转成纯文本（http/https，最多 " +
            "${Contract.Web.MAX_BYTES / 1024} KB，正文最多 ${Contract.Web.MAX_TEXT_CHARS} 字）。" +
            "返回标题 + 正文摘录；超长会截断并说明。不执行 JS、不带 Cookie、拒绝内网/本机地址。" +
            "适合查文档、README、API 说明；不要用它抓需要登录的页面。",
        parameters = listOf(
            ToolParam("url", "string", "完整 URL，例如 https://example.com / https://kotlinlang.org/docs/coroutines-overview.html"),
        ),
    )

    override suspend fun execute(args: Map<String, String>): ToolOutcome {
        val raw = args["url"].orEmpty().trim()
        if (raw.isEmpty()) return ToolOutcome.Failure("url 不能为空")

        val uri = runCatching { URI(raw) }.getOrNull()
            ?: return ToolOutcome.Failure("不是合法的 URL：$raw")
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") {
            return ToolOutcome.Failure("只支持 http/https，收到：${scheme ?: "（无 scheme）"}")
        }
        val host = uri.host ?: return ToolOutcome.Failure("URL 缺少主机名：$raw")
        val blocked = isBlockedHost(host)
        // allowLoopback 只给测试用（本地起 HTTP server 验真实抓取路径）
        if (blocked != null && !allowLoopback) return ToolOutcome.Failure(blocked)

        val response = runCatching { fetch(uri) }
            .getOrElse { e ->
                return ToolOutcome.Failure(
                    "抓取失败：${e.javaClass.simpleName}: ${e.message ?: "无详情"}",
                )
            }

        val contentType = response.contentType.lowercase()
        val isHtml = contentType.contains("text/html") || contentType.isEmpty()
        val truncatedDownload = response.truncated
        val text = if (isHtml) {
            htmlToText(response.body)
        } else {
            response.body.trim()
        }
        if (text.isBlank()) {
            return ToolOutcome.Failure(
                "页面没有可读文本（HTTP ${response.status}，${contentType.ifEmpty { "未知类型" }}；" +
                    "可能是动态渲染或非文本内容）",
            )
        }
        val body = if (text.length > Contract.Web.MAX_TEXT_CHARS) {
            text.take(Contract.Web.MAX_TEXT_CHARS) +
                "\n…（正文已截断，原文 ${text.length} 字符）"
        } else {
            text
        }
        val head = buildString {
            append("URL: ").append(uri)
            response.title?.let { append("\n标题: ").append(it) }
            append("\nHTTP ").append(response.status)
            if (contentType.isNotEmpty()) append("，类型 ").append(contentType.substringBefore(';'))
            if (truncatedDownload) {
                append("，只读了前 ").append(Contract.Web.MAX_BYTES / 1024).append(" KB")
            }
            append("\n\n")
        }
        return ToolOutcome.Success(head + body)
    }

    /** 抓取结果 —— 只保留工具要用的部分。 */
    private class Fetched(
        val status: Int,
        val contentType: String,
        val body: String,
        val title: String?,
        val truncated: Boolean,
    )

    private fun fetch(uri: URI): Fetched {
        val conn = (uri.toURL().openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = Contract.Web.CONNECT_TIMEOUT_MS
            readTimeout = Contract.Web.READ_TIMEOUT_MS
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", Contract.Web.USER_AGENT)
            setRequestProperty("Accept", "text/html,text/plain,application/json;q=0.8,*/*;q=0.5")
            setRequestProperty("Accept-Encoding", "gzip")
        }
        try {
            val status = conn.responseCode
            if (status !in 200..299) {
                throw IllegalStateException("HTTP $status")
            }
            val rawStream = conn.inputStream
            val stream = if (conn.contentEncoding?.contains("gzip", ignoreCase = true) == true) {
                GZIPInputStream(rawStream)
            } else {
                rawStream
            }
            val bytes = stream.use { readLimited(it, Contract.Web.MAX_BYTES) }
            val charset = charsetOf(conn.contentType)
            val text = bytes.first.toString(charset)
            val contentType = conn.contentType.orEmpty()
            return Fetched(
                status = status,
                contentType = contentType,
                body = text,
                title = if (contentType.contains("html", ignoreCase = true) ||
                    contentType.isEmpty()
                ) {
                    TITLE.find(text)?.groupValues?.getOrNull(1)?.let(::decodeEntities)?.trim()
                        ?.takeIf { it.isNotEmpty() }
                } else {
                    null
                },
                truncated = bytes.second,
            )
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        private val TITLE = Regex(
            "<title[^>]*>(.*?)</title>",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
        )

        /**
         * 内网 / 本机判定。**在 DNS 解析之后**做 —— 十进制/十六进制 IP 与域名别名同样挡住。
         * @return null = 允许；非 null = 给模型看的拒绝原因
         */
        internal fun isBlockedHost(host: String): String? {
            val lower = host.lowercase()
            if (lower == "localhost" || lower.endsWith(".localhost") || lower == "0.0.0.0") {
                return "拒绝访问本机地址：$host"
            }
            val addrs = runCatching { InetAddress.getAllByName(host) }.getOrElse {
                return "域名解析失败：$host"
            }
            for (a in addrs) {
                if (a.isAnyLocalAddress || a.isLoopbackAddress || a.isLinkLocalAddress ||
                    a.isSiteLocalAddress || a.isMulticastAddress
                ) {
                    return "拒绝访问内网/本机地址：$host（解析为 ${a.hostAddress}）"
                }
            }
            return null
        }

        /** 读最多 [max] 字节；返回（内容, 是否被截断）。 */
        internal fun readLimited(input: java.io.InputStream, max: Int): Pair<ByteArray, Boolean> {
            val out = ByteArrayOutputStream(minOf(max, 64 * 1024))
            val buf = ByteArray(16 * 1024)
            var total = 0
            var truncated = false
            while (true) {
                // 每次只读到"上限 + 1"，多出来的那一个字节就是"还有内容"的证据
                val want = minOf(buf.size, max + 1 - total)
                if (want <= 0) {
                    truncated = true
                    break
                }
                val n = input.read(buf, 0, want)
                if (n < 0) break
                if (total + n > max) {
                    out.write(buf, 0, max - total)
                    total = max
                    truncated = true
                    break
                }
                out.write(buf, 0, n)
                total += n
                if (total == max) {
                    // 已读满：探一个字节确认是否真到结尾（read() 会消耗掉它，但本来就是多余的）
                    truncated = input.read() >= 0
                    break
                }
            }
            return out.toByteArray() to truncated
        }

        /** 从 Content-Type 里取 charset；认不出就用 UTF-8（现代网页绝大多数）。 */
        internal fun charsetOf(contentType: String?): Charset {
            val m = Regex("charset=([A-Za-z0-9_\\-]+)", RegexOption.IGNORE_CASE)
                .find(contentType.orEmpty()) ?: return Charsets.UTF_8
            return runCatching { Charset.forName(m.groupValues[1]) }.getOrDefault(Charsets.UTF_8)
        }

        /**
         * HTML → 可读文本（**子集**实现，够给模型看）：
         * 去 `script`/`style`/`noscript` 整块、块级标签转空行、其余标签去掉、解码常见实体、压缩空白。
         */
        internal fun htmlToText(html: String): String {
            var s = html
            // 整块丢弃（DOT_MATCHES_ALL 才能跨行）
            s = Regex(
                "<(script|style|noscript|svg|template)[^>]*>.*?</\\1\\s*>",
                setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
            ).replace(s, "\n")
            s = Regex("<!--.*?-->", RegexOption.DOT_MATCHES_ALL).replace(s, "\n")
            // 块级换行
            s = Regex(
                "</?(p|div|section|article|header|footer|main|nav|aside|h[1-6]|li|tr|ul|ol|table|pre|blockquote|br)\\b[^>]*>",
                RegexOption.IGNORE_CASE,
            ).replace(s, "\n")
            s = Regex("<[^>]+>").replace(s, "")
            s = decodeEntities(s)
            // 行内连续空白压成一个空格；空行压成一个换行
            s = s.lineSequence()
                .map { line -> line.replace(Regex("[ \\t\\u00a0\\u200b]+"), " ").trim() }
                .filter { it.isNotEmpty() }
                .joinToString("\n")
            return s
        }

        internal fun decodeEntities(s: String): String {
            var out = s
                .replace("&nbsp;", " ")
                .replace("&lt;", "<")
                .replace("&gt;", ">")
                .replace("&quot;", "\"")
                .replace("&#39;", "'")
                .replace("&apos;", "'")
                .replace("&amp;", "&")
            // 数字实体（&#123; / &#x1F600;）—— 子集：只处理 < 0x10000 的
            out = Regex("&#(x?)([0-9a-fA-F]+);").replace(out) { m ->
                val code = if (m.groupValues[1].isEmpty()) {
                    m.groupValues[2].toIntOrNull(10)
                } else {
                    m.groupValues[2].toIntOrNull(16)
                }
                if (code != null && code in 0x20..0xFFFF) {
                    runCatching { String(Character.toChars(code)) }.getOrDefault(m.value)
                } else {
                    m.value
                }
            }
            return out
        }
    }
}
