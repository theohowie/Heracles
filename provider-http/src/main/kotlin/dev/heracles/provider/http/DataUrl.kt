package dev.heracles.provider.http

import dev.heracles.core.contract.Contract
import java.util.Base64

/**
 * **data URL 解析的唯一点**（2026-10-19，多模态三轨接通）。
 *
 * ## 为什么必须有这个文件
 *
 * 三家 provider 对图片的 wire 形状**都不一样**：
 *
 * | 后端 | 要什么 |
 * |---|---|
 * | OpenAI 兼容 | `image_url.url` = **整个 data URL 原样**（`OpenAiCompatProvider` 不动它） |
 * | **Anthropic** | `source = {type:"base64", media_type, data}` —— 要**拆开**，且 `data` 是**纯 base64** |
 * | **Responses** | `input_image.image_url` = **整个 data URL 原样**（和 OpenAI 兼容同形） |
 *
 * 如果各家自己 `substringAfter("base64,")`，那么**拆错时的表现各不相同、而且都静默**：
 * 最坏的一种是把 `data:image/png;base64,` 前缀一起当成 base64 发出去 ——
 * 服务端要么 400，要么解码出垃圾字节，**模型"看不见图"却照常作答**。
 * 所以解析**只此一处**，失败也**只此一处**（`AGENTS.md`：解析失败绝不猜）。
 *
 * ## 三条纪律
 *
 * 1. **mime 白名单**（[ALLOWED_MEDIA_TYPES] = jpeg / png / gif / webp），其余**明确失败**。
 *    不做"猜扩展名"、也不把 `image/jpg` 这种非标准写法纠正成 `image/jpeg` ——
 *    纠正就是猜（而且各家的校验松紧不同，我们猜对了也不代表对方接受）。
 * 2. **单图上限** [Contract.Media.MAX_IMAGE_BYTES]，按 **base64 解码后的字节数**算，
 *    不是文本长度（base64 有 4/3 膨胀，按文本长度算会**少放行 25%**）。
 * 3. 所有失败都抛 [IllegalArgumentException]，**`message` 必须说清是哪个文件/哪一步坏了** ——
 *    上层会把它原样变成 `Result.failure` 的理由，用户看到的就是这句话。
 *
 * ## 为什么是 `internal`
 *
 * 它是 `:provider-http` 的**实现细节**，不是契约：`:core` 的 `GenerateRequest.images`
 * 只说"元素是 data URL"（后端中立），拆不拆、怎么拆是各 provider 的事。
 * 泄漏成 `public` 就等于把 Anthropic 的形状知识推到了 provider 之上。
 *
 * ⚠️ 本文件**不做魔数检查**（PNG 签名 / JPEG SOI）：那需要解码前 8 个字节，
 * 会多一次失败面，而今天的收益不明确（mime 与字节不符时，是服务端最能判断的事）。
 * 这条是**已知边界**，不是遗漏。
 */
internal object DataUrl {

    /**
     * 允许的 `media_type` —— **只允许这四个**，其它明确失败。
     *
     * 依据：三家官方 API 共同接受的栅格图格式集合的交集。
     * `svg+xml` **刻意不在里面**：它可带脚本/外链，是攻击面，且多数端点不收。
     * `image/jpg` 也不在里面 —— 不是标准写法（标准是 `image/jpeg`），
     * 见类 KDoc 纪律 1：**纠正就是猜**。
     */
    val ALLOWED_MEDIA_TYPES: Set<String> = setOf(
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp",
    )

    /** 成功解析的结果：拆开的 mime + **纯** base64（不含 `data:` 前缀）。 */
    data class Parsed(
        /** 例如 `image/png` —— 已确认在白名单里。 */
        val mediaType: String,
        /** **纯** base64 文本。Anthropic 的 `source.data` 直接用它。 */
        val base64: String,
        /** 解码后的原始字节数（用来核对 [Contract.Media.MAX_IMAGE_BYTES]）。 */
        val byteCount: Int,
    )

    private const val PREFIX = "data:"
    private const val BASE64_MARKER = ";base64,"
    private const val BINARY_MARKER = ","

    /**
     * 解析一条 data URL。**失败一律抛 [IllegalArgumentException]（带原因）**。
     *
     * 认得的形状（大小写不敏感的部分只有 `;base64` 这个标记本身 ——
     * RFC 2397 里它是 `;base64`，实际端点都是小写，这里也照 URI 规范大小写不敏感地收）：
     *
     * ```
     * data:image/png;base64,iVBORw0KGgo...
     * ```
     *
     * **不认**的形状（全部明确失败，理由见表）：
     *
     * | 输入 | 为什么拒 |
     * |---|---|
     * | `https://…/a.png` | 不是 data URL（`ModelProvider` 的契约就是 data URL；网络图要上层先下回来） |
     * | `data:image/png,<urlencoded>` | 非 base64 编码（`;base64` 缺失）|
     * | `data:;base64,…` | mime 为空 —— 我们不猜"大概是个图片" |
     * | `data:image/bmp;base64,…` | mime 不在白名单 |
     * | `data:image/png;base64,` | 载荷为空 |
     * | `data:image/png;base64,@@@` | 不是合法 base64 |
     * | 解码后 > `MAX_IMAGE_BYTES` | 超限 |
     */
    fun parse(raw: String): Parsed {
        if (!raw.startsWith(PREFIX, ignoreCase = true)) {
            throw IllegalArgumentException(
                "图片不是 data URL（应以 `data:image/...;base64,` 开头）：" + preview(raw),
            )
        }
        // 先找 `;base64,` —— 有没有它决定"是不是 base64 编码"
        val markerIdx = raw.indexOf(BASE64_MARKER, ignoreCase = true)
        if (markerIdx < 0) {
            // 有逗号但没有 `;base64` = 非 base64 编码的 data URL（RFC 2397 允许，但这三家都不吃）
            val commaIdx = raw.indexOf(BINARY_MARKER)
            throw IllegalArgumentException(
                if (commaIdx >= 0) {
                    "图片 data URL 不是 base64 编码（缺 `;base64`）：只支持 base64 的 data URL"
                } else {
                    "图片 data URL 格式错误（既没有 `;base64,` 也没有 `,`）：" + preview(raw)
                },
            )
        }

        val mediaType = raw.substring(PREFIX.length, markerIdx).lowercase()
        if (mediaType.isEmpty()) {
            throw IllegalArgumentException(
                "图片 data URL 缺少 media type（`data:;base64,…`）—— 不猜格式，请给出 `data:image/png;base64,…`",
            )
        }
        if (mediaType !in ALLOWED_MEDIA_TYPES) {
            throw IllegalArgumentException(
                "不支持的图片格式 `$mediaType`：只接受 ${ALLOWED_MEDIA_TYPES.sorted().joinToString(" / ")}",
            )
        }

        val payload = raw.substring(markerIdx + BASE64_MARKER.length)
        if (payload.isEmpty()) {
            throw IllegalArgumentException("图片 data URL 的 base64 载荷为空（`$mediaType`）")
        }

        // ★ 先按文本长度粗筛再解码：base64 每 4 字符 ≤ 3 字节 ⇒ 文本长度上限是字节上限的 4/3。
        //   这一步只是为了**别为一张几百 MB 的坏输入分配大数组**，真正的判定是下面的解码后字节数。
        val textLimit = maxTextLength(Contract.Media.MAX_IMAGE_BYTES)
        if (payload.length > textLimit) {
            throw IllegalArgumentException(
                "图片过大：base64 文本 ${payload.length} 字符已超过 ${Contract.Media.MAX_IMAGE_BYTES} 字节上限（单图上限）",
            )
        }

        val bytes = try {
            // MIME 用 Basic 解码器：它**不接受** URL-safe 的 `-`/`_`，也不接受空白 ——
            // 这两样都是"发出去以后才在服务端炸"的输入，在这里拒掉更省事。
            Base64.getDecoder().decode(payload)
        } catch (e: IllegalArgumentException) {
            throw IllegalArgumentException(
                "图片 base64 解码失败（载荷不是合法 base64）：${e.message}",
            )
        }

        if (bytes.size > Contract.Media.MAX_IMAGE_BYTES) {
            throw IllegalArgumentException(
                "图片过大：解码后 ${bytes.size} 字节 > 上限 ${Contract.Media.MAX_IMAGE_BYTES} 字节（单图上限）",
            )
        }
        if (bytes.isEmpty()) {
            throw IllegalArgumentException("图片 data URL 解码后是空的（`$mediaType`）")
        }

        return Parsed(mediaType = mediaType, base64 = payload, byteCount = bytes.size)
    }

    /**
     * base64 文本长度上限：字节上限向上取整到 4 的倍数再 ×4/3。
     *
     * 写成一个函数而不是内联算式，是因为**这是唯一的"数字从哪来"的地方**：
     * 唯一的上限源是 [Contract.Media.MAX_IMAGE_BYTES]，这里只是它的一次换算。
     */
    private fun maxTextLength(maxBytes: Int): Long = ((maxBytes.toLong() + 2) / 3) * 4

    /**
     * 报错时的节选 —— **绝不能把整条 data URL 打进日志/异常**。
     *
     * 一张 4 MB 的图 base64 后 ≈ 5.3 MB 文本；塞进 `message` 会被上层记进会话/日志。
     * 只留前 32 个字符：足够看出"这到底是不是 data URL"，又不会把图本身搬一遍。
     */
    private fun preview(s: String): String {
        val head = s.take(PREVIEW_CHARS)
        return "`" + head + (if (s.length > PREVIEW_CHARS) "…" else "") + "`（共 ${s.length} 字符）"
    }

    /** 报错节选的长度（字符）—— 只为辨认，不承载信息量。 */
    private const val PREVIEW_CHARS = 32
}
