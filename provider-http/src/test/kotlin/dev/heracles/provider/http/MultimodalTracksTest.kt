package dev.heracles.provider.http

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.contract.Contract
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.ProviderConfig
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test
import java.util.Base64

/**
 * **多模态：Anthropic / Responses 两轨的请求形状门禁**（2026-10-19）。
 *
 * ## 与 [MultimodalRequestTest] 的分工（**不重叠**）
 *
 * | 文件 | 守哪一轨 |
 * |---|---|
 * | `MultimodalRequestTest` | **OpenAI 兼容**（`image_url.url` = 整个 data URL）+ 另两轨"未接通时显式失败" |
 * | **本文件** | **Anthropic**（拆成 `source.{media_type,data}`）+ **Responses**（`input_image` + `input` 数组）多模态的形状 / 零回退 / 失败面 / 流式不再抛 |
 *
 * ⚠️ `MultimodalRequestTest` 里那两条"Anthropic / Responses 未接通 ⇒ 显式失败"的断言
 * **必须随本次接通一起改**（它们守的是"没接通时别静默丢图"，接通后守的东西变了）。
 *
 * ## 为什么这些断言必须有
 *
 * "把图片发出去"在 UI 上看不出对错：模型看不到图时照样能一本正经地编。
 * 三家对图片的 wire 形状**互不相同**，而**写错全都静默**：
 *
 * | 后端 | 正确形状 | 写错的典型症状 |
 * |---|---|---|
 * | Anthropic | `content[].{type:"image", source:{type:"base64", media_type, data}}` | `data` 里带了 `data:` 前缀 ⇒ 400 或解出垃圾字节 |
 * | Responses | message item 的 `content` = **数组** `[{input_text},{input_image,image_url}]` | 抄 Chat 的 `"content":"…"` 字符串 / 用 `text`+`image_url` 块名 ⇒ 非法 |
 * | 两者共同 | 不传图 ⇒ 请求体**逐字节不变** | 多一个键 ⇒ 前缀缓存全 miss + 非多模态端点行为漂移 |
 *
 * ## 零回退用**整串金标准**，不是 `contains`
 *
 * 一个字节变了就该红（同 `NativeToolsRequestTest` 的理由）。`contains` 挡不住
 * "顺手多塞了一个空键"或"引号转义变了"这类漂移。
 *
 * ⚠️ **零真 Key 验证**：本文件证明的是"与公开 API 文档的形状一致"，
 * **不是**"真实服务端已接受"。按 `AGENTS.md`，这条 wire 变更**必须**真 Key 复验才算完成。
 */
class MultimodalTracksTest {

    // ---------------------------------------------------------------- 反射取私有请求体构造器

    /**
     * 按 **名字 + 参数个数**取方法，而**不是** `getDeclaredMethod(精确签名)`。
     *
     * 理由（F7b 踩过、`NativeCallReplayTest.privateMethod` 记过）：
     * 给 `buildBody` 加个参数后，精确签名匹配会在**运行时**抛 `NoSuchMethodException`，
     * 而**编译是绿的** —— 门禁静默失效。本次恰好就是在给 `buildBody` 加 `images` 参数，
     * 所以本文件所有反射调用**一律**走这条路。
     */
    private fun privateMethod(cls: Class<*>, name: String, arity: Int) =
        cls.declaredMethods.single { it.name == name && it.parameterCount == arity }
            .apply { isAccessible = true }

    /** Anthropic 的 `buildBody(messages, maxOutputTokens, stream, tools, images)` —— **5 个参数**。 */
    private fun anthropicBody(
        messages: List<ChatMessage>,
        images: List<String> = emptyList(),
    ): JsonObject {
        val p = AnthropicProvider(baseUrl = "https://example.invalid", apiKey = "k", modelName = "m")
        val m = privateMethod(AnthropicProvider::class.java, "buildBody", 5)
        return m.invoke(p, messages, 16, false, emptyList<Any>(), images) as JsonObject
    }

    /** Responses 的 `buildBody(request, stream, images)` —— **3 个参数**。 */
    private fun responsesBody(request: GenerateRequest): JsonObject {
        val p = OpenAiResponsesProvider(
            id = "responses:test", baseUrl = "https://example.invalid", apiKey = "k", modelName = "m",
        )
        val m = privateMethod(OpenAiResponsesProvider::class.java, "buildBody", 3)
        return m.invoke(p, request, false, request.images) as JsonObject
    }

    private fun responsesRequest(images: List<String> = emptyList()) = GenerateRequest(
        prompt = "ignored",
        maxOutputTokens = 16,
        messages = listOf(ChatMessage(ChatRole.USER, "hi")),
        images = images,
    )

    // ---------------------------------------------------------------- 测试数据

    /** 1×1 的 PNG（真实字节，不是随便一串 base64）。 */
    private val pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private val pngDataUrl = "data:image/png;base64,$pngBase64"

    /** 纯文本历史的**金标准输入**（三家共用同一段输入，便于对照）。 */
    private val textHistory = listOf(ChatMessage(ChatRole.USER, "hi"))

    // ================================================================
    // 1. Anthropic：有图 ⇒ 末尾多一条 user（text 在前 image 在后，data 是纯 base64）
    // ================================================================

    @Test
    @DisplayName("★★ Anthropic 有图 ⇒ messages 末尾多一条 user，content = [text, image]")
    fun anthropicImageBecomesExtraUserMessageWithImageBlock() {
        val body = anthropicBody(textHistory, images = listOf(pngDataUrl))
        val msgs = body.getAsJsonArray("messages")

        assertEquals(
            2, msgs.size(),
            "有图应**追加**一条 user 消息（原消息一条不动）：$msgs",
        )
        assertEquals("user", msgs[0].asJsonObject.get("role").asString, "原消息不被改写")
        assertEquals("hi", msgs[0].asJsonObject.get("content").asString)

        val last = msgs[1].asJsonObject
        assertEquals("user", last.get("role").asString, "图片那条必须是 user")
        val content = last.getAsJsonArray("content")
        assertEquals(2, content.size(), "引导语 + 图片，两块：$content")

        // ★ 顺序是硬的：text 在前、image 在后
        val textBlock = content[0].asJsonObject
        assertEquals("text", textBlock.get("type").asString, "content[0] 必须是 text")
        assertTrue(
            textBlock.get("text").asString.contains("图片"),
            "引导语要让模型知道下面有图：${textBlock.get("text").asString}",
        )

        val imageBlock = content[1].asJsonObject
        assertEquals("image", imageBlock.get("type").asString, "content[1] 必须是 image")

        val source = imageBlock.getAsJsonObject("source")
        assertEquals("base64", source.get("type").asString, "本类只发 base64 源（不发 url 源）")
        assertEquals("image/png", source.get("media_type").asString, "media_type 从 data URL 拆出来")
        assertEquals(
            pngBase64, source.get("data").asString,
            "★ `data` 必须是**纯 base64** —— 带 `data:` 前缀会让服务端 400 或解出垃圾字节",
        )
        assertFalse(
            source.get("data").asString.startsWith("data:"),
            "★ 前缀绝不许漏进去：${source.get("data").asString.take(40)}",
        )
        // 载荷本身必须真的能解码（防"拆出来的其实是带前缀的串"）
        assertEquals(
            Base64.getDecoder().decode(pngBase64).size,
            Base64.getDecoder().decode(source.get("data").asString).size,
            "拆出来的 data 必须仍是合法 base64",
        )
    }

    @Test
    @DisplayName("★★ Anthropic 不给图 ⇒ 请求体逐字节相同（整串金标准，不是 contains）")
    fun anthropicTextOnlyBodyIsPinnedByteForByte() {
        val body = anthropicBody(textHistory)
        assertEquals(
            // ★ 改动前的 Anthropic 请求体就是这个字面量（buildBody 的四个默认值：
            //   stream=false / tools 空 / 无 system）。
            //   多一个空格、多一个空键、引号转义变化 都会让这条红。
            "{\"model\":\"m\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
            body.toString(),
            "不传图 ⇒ 请求体必须与改动前逐字节相同（否则前缀缓存与非多模态端点都会受影响）",
        )
        assertFalse(body.toString().contains("image"), "纯文本请求体不该出现任何 image 字样：$body")
    }

    @Test
    @DisplayName("★ Anthropic 多图 ⇒ 同一块 content 里按序追加 image（文字只在最前一次）")
    fun anthropicMultipleImagesStayInOrderInOneMessage() {
        val gif = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        val webp = "data:image/webp;base64,UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA=="
        val msgs = anthropicBody(textHistory, images = listOf(pngDataUrl, gif, webp))
            .getAsJsonArray("messages")
        assertEquals(2, msgs.size(), "多图仍是**一条** user（不是每条一张消息）：$msgs")

        val content = msgs[1].asJsonObject.getAsJsonArray("content")
        assertEquals(4, content.size(), "1 条引导语 + 3 张图：$content")
        assertEquals("text", content[0].asJsonObject.get("type").asString)
        assertEquals(
            listOf("image/png", "image/gif", "image/webp"),
            (1..3).map { content[it].asJsonObject.getAsJsonObject("source").get("media_type").asString },
            "顺序 = 调用方给的顺序（乱序 = 图文对不上）",
        )
        for (i in 1..3) {
            assertEquals(
                "image", content[i].asJsonObject.get("type").asString,
                "★ 每张图都必须是独立的 image 块（不是拼进 text）",
            )
        }
    }

    // ================================================================
    // 2. Responses：有图 ⇒ input[] 末尾多一条 message item（content 是数组）
    // ================================================================

    @Test
    @DisplayName("★★ Responses 有图 ⇒ input 末尾多一条 message item，content = [input_text, input_image]")
    fun responsesImageBecomesExtraInputItemWithInputImage() {
        val body = responsesBody(responsesRequest(listOf(pngDataUrl)))
        val input = body.getAsJsonArray("input")

        assertEquals(
            2, input.size(),
            "有图应**追加**一条 item（原消息一条不动）：$input",
        )
        assertEquals("hi", input[0].asJsonObject.get("content").asString, "原消息不被改写")

        val last = input[1].asJsonObject
        assertEquals("message", last.get("type").asString, "必须仍是 `type:message` 的 item")
        assertEquals("user", last.get("role").asString)

        // ★★ Responses 的 message item 里 `content` 必须是**数组**
        //    （Chat Completions 那种字符串在这里是非法形状）
        val content = last.getAsJsonArray("content")
        assertEquals(2, content.size(), "引导语 + 图片，两块：$content")

        val textBlock = content[0].asJsonObject
        assertEquals(
            "input_text", textBlock.get("type").asString,
            "★ Responses 的文本块叫 `input_text`，**不是** Chat 的 `text`",
        )
        assertTrue(textBlock.get("text").asString.contains("图片"))

        val imageBlock = content[1].asJsonObject
        assertEquals(
            "input_image", imageBlock.get("type").asString,
            "★ Responses 的图片块叫 `input_image`，**不是** Chat 的 `image_url`",
        )
        assertEquals(
            pngDataUrl, imageBlock.get("image_url").asString,
            "★ `image_url` 是**整个 data URL 原样**（本协议不拆 mime/base64）",
        )
        // 本协议没有 `source` 子对象 —— 抄 Anthropic 的形状会非法
        assertNull(
            imageBlock.get("source"),
            "Responses 的图片块**没有** `source`（那是 Anthropic 的形状）：$imageBlock",
        )
    }

    @Test
    @DisplayName("★★ Responses 不给图 ⇒ 请求体逐字节相同（整串金标准，不是 contains）")
    fun responsesTextOnlyBodyIsPinnedByteForByte() {
        val body = responsesBody(responsesRequest())
        assertEquals(
            // ★ 改动前的 Responses 请求体就是这个字面量。
            "{\"model\":\"m\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":\"hi\"}]," +
                "\"max_output_tokens\":16}",
            body.toString(),
            "不传图 ⇒ 请求体必须与改动前逐字节相同",
        )
        assertFalse(body.toString().contains("input_image"), "纯文本请求体不该出现 input_image：$body")
    }

    @Test
    @DisplayName("★ Responses 多图 ⇒ 同一 item 的 content 里按序追加 input_image")
    fun responsesMultipleImagesStayInOrder() {
        val gif = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        val input = responsesBody(responsesRequest(listOf(pngDataUrl, gif))).getAsJsonArray("input")
        assertEquals(2, input.size(), "多图仍是**一条** item（不是每条一张消息）：$input")

        val content = input[1].asJsonObject.getAsJsonArray("content")
        assertEquals(3, content.size(), "1 条引导语 + 2 张图：$content")
        assertEquals("input_text", content[0].asJsonObject.get("type").asString)
        assertEquals(
            listOf(pngDataUrl, gif),
            (1..2).map { content[it].asJsonObject.get("image_url").asString },
            "顺序 = 调用方给的顺序，且原样回填 data URL",
        )
    }

    // ================================================================
    // 3. 失败面：data URL 坏了 ⇒ failure，且**文案说清原因**（不静默丢图）
    // ================================================================

    /** 两家对同一个坏 data URL 都必须给 failure（而不是"少发一张图然后继续"）。 */
    private fun assertBothTracksFail(images: List<String>, reasonContains: String) = runBlocking {
        val anthropic = AnthropicProvider(apiKey = "k", modelName = "m")
            .also { it.load(ProviderConfig()).getOrThrow() }
        val a = anthropic.generate(
            GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = images),
        )
        assertTrue(a.isFailure, "Anthropic 必须失败（不许静默丢图）：$a")
        val aMsg = a.exceptionOrNull()?.message.orEmpty()
        assertTrue(
            aMsg.contains(reasonContains), "Anthropic 的失败文案要说清原因，实得：`$aMsg`",
        )

        val responses = OpenAiResponsesProvider("responses:test", "https://example.invalid", "k", "m")
            .also { it.load(ProviderConfig()).getOrThrow() }
        val r = responses.generate(
            GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = images),
        )
        assertTrue(r.isFailure, "Responses 必须失败（不许静默丢图）：$r")
        val rMsg = r.exceptionOrNull()?.message.orEmpty()
        assertTrue(
            rMsg.contains(reasonContains), "Responses 的失败文案要说清原因，实得：`$rMsg`",
        )
    }

    @Test
    @DisplayName("★★ data URL 格式错（不是 data URL）⇒ 两家都 failure，文案说清")
    fun malformedDataUrlFailsBothTracks() {
        assertBothTracksFail(listOf("https://example.invalid/a.png"), "data URL")
    }

    @Test
    @DisplayName("★★ 缺 `;base64`（非 base64 的 data URL）⇒ failure，文案说清是编码问题")
    fun nonBase64DataUrlFailsBothTracks() {
        assertBothTracksFail(listOf("data:image/png,abc123"), "base64")
    }

    @Test
    @DisplayName("★★ mime 不支持（image/bmp）⇒ failure，文案列出允许的格式")
    fun unsupportedMimeFailsBothTracks() {
        assertBothTracksFail(
            listOf("data:image/bmp;base64,Qk1BAAAAAA=="),
            "不支持的图片格式",
        )
    }

    @Test
    @DisplayName("★★ 非标准写法 `image/jpg` 也拒（纠正就是猜）")
    fun nonStandardMimeIsRejectedNotCorrected() {
        assertBothTracksFail(listOf("data:image/jpg;base64,$pngBase64"), "不支持的图片格式")
    }

    @Test
    @DisplayName("★ base64 载荷非法 ⇒ failure，文案说清是解码失败")
    fun invalidBase64PayloadFailsBothTracks() {
        assertBothTracksFail(listOf("data:image/png;base64,@@@not-base64@@@"), "base64")
    }

    @Test
    @DisplayName("★ 空载荷 / 空 mime ⇒ failure（不猜「大概是个图片」）")
    fun emptyPayloadOrMimeFailsBothTracks() {
        assertBothTracksFail(listOf("data:image/png;base64,"), "空")
        assertBothTracksFail(listOf("data:;base64,$pngBase64"), "media type")
    }

    @Test
    @DisplayName("★★ 超过 Contract.Media.MAX_IMAGE_BYTES ⇒ failure，文案带上限出处")
    fun oversizedImageFailsBothTracks() {
        // 造一张刚好超限的图（解码后 MAX+1 字节）—— 上限**从 Contract 读**，不写死数字。
        val tooBig = Base64.getEncoder().encodeToString(ByteArray(Contract.Media.MAX_IMAGE_BYTES + 1))
        assertBothTracksFail(listOf("data:image/png;base64,$tooBig"), "过大")
    }

    @Test
    @DisplayName("★★ 失败文案里**不带整条 data URL**（图不许被搬进日志/会话）")
    fun failureMessageNeverEchoesTheWholeDataUrl() = runBlocking {
        // 用一个**超限**的图触发失败：这是最容易被"顺手把入参打进文案"的路径
        val huge = Base64.getEncoder().encodeToString(ByteArray(Contract.Media.MAX_IMAGE_BYTES + 1))
        val url = "data:image/png;base64,$huge"
        val p = AnthropicProvider(apiKey = "k", modelName = "m")
            .also { it.load(ProviderConfig()).getOrThrow() }
        val r = p.generate(GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = listOf(url)))
        val msg = r.exceptionOrNull()?.message.orEmpty()
        assertTrue(msg.isNotEmpty(), "必须有失败文案")
        assertTrue(
            msg.length < 512,
            "失败文案不许把图搬一遍（实得 ${msg.length} 字符）—— 它会进会话/日志",
        )
        assertFalse(msg.contains(huge.take(64)), "文案里不许出现载荷片段：$msg")
    }

    @Test
    @DisplayName("★ 上限常量存在且就是 Contract.Media.MAX_IMAGE_BYTES（不许在 provider 里另立数字）")
    fun imageLimitComesFromContract() {
        assertTrue(
            Contract.Media.MAX_IMAGE_BYTES > 0,
            "单图上限必须有出处（core/contract/Contract.kt 的 Media 对象）",
        )
        // 刚好等于上限的图必须**放行**（否则"上限"实际上小了一格）
        val atLimit = Base64.getEncoder().encodeToString(ByteArray(Contract.Media.MAX_IMAGE_BYTES))
        val msg = anthropicBody(textHistory, images = listOf("data:image/png;base64,$atLimit"))
            .getAsJsonArray("messages")[1].asJsonObject
        assertEquals(
            atLimit,
            msg.getAsJsonArray("content")[1].asJsonObject.getAsJsonObject("source").get("data").asString,
            "恰好 MAX_IMAGE_BYTES 的图必须放行（上限是 `>` 不是 `>=`）",
        )
    }

    // ================================================================
    // 4. 流式：带图**不再抛**（原来的早退已删除）
    // ================================================================

    /** 一个**不可能连上**的端点（RFC 2606 的 `.invalid` 保留域）。 */
    private val unreachable = "http://127.0.0.1:9"

    /**
     * 流式带图"不再抛"的口径：**抛出的异常不能是"不支持读图"那一条**。
     *
     * ⚠️ 这里**不发网络**就不可能拿到完整流 —— 所以断言的是：
     * 收集过程中抛出的**所有**异常都与"图片"无关（即：图片这一关已经过了，
     * 后面失败只可能是因为连不上 `127.0.0.1:9`）。这是零网络环境下
     * 对"早退已删除"最诚实的证明方式。
     */
    private fun assertStreamWithImagesDoesNotRejectImages(
        provider: Any,
        request: GenerateRequest,
    ) = runBlocking {
        val flow = (provider as dev.heracles.core.provider.ModelProvider).generateStream(request)
        try {
            flow.toList()
        } catch (t: Throwable) {
            val msg = t.message.orEmpty()
            assertFalse(
                msg.contains("不支持读图"),
                "★ 带图**不该**再被早退拒绝（早退已删除）：$msg",
            )
            // 也不该是"图片本身坏了"—— 我们用的是合法 PNG
            assertFalse(
                msg.contains("不支持的图片格式") || msg.contains("data URL"),
                "合法 PNG 不该在流式路径被判为坏图：$msg",
            )
        }
    }

    @Test
    @DisplayName("★★ Anthropic generateStream() 带图不再抛（早退已删除）")
    fun anthropicStreamAcceptsImages() {
        val p = AnthropicProvider(baseUrl = unreachable, apiKey = "k", modelName = "m")
        runBlocking { p.load(ProviderConfig()).getOrThrow() }
        assertStreamWithImagesDoesNotRejectImages(
            p,
            GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = listOf(pngDataUrl)),
        )
    }

    @Test
    @DisplayName("★★ Responses generateStream() 带图不再抛（早退已删除）")
    fun responsesStreamAcceptsImages() {
        val p = OpenAiResponsesProvider("responses:test", unreachable, "k", "m")
        runBlocking { p.load(ProviderConfig()).getOrThrow() }
        assertStreamWithImagesDoesNotRejectImages(
            p,
            GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = listOf(pngDataUrl)),
        )
    }

    @Test
    @DisplayName("★ 流式路径的坏图在**开流之前**就失败（不是流到一半才炸）")
    fun streamRejectsBadImageBeforeStarting() {
        val p = AnthropicProvider(baseUrl = unreachable, apiKey = "k", modelName = "m")
        runBlocking { p.load(ProviderConfig()).getOrThrow() }
        val thrown = assertThrows(IllegalArgumentException::class.java) {
            runBlocking {
                p.generateStream(
                    GenerateRequest(prompt = "看图", maxOutputTokens = 16, images = listOf("data:image/bmp;base64,Qk1B")),
                ).toList()
            }
        }
        assertTrue(
            thrown.message.orEmpty().contains("不支持的图片格式"),
            "坏图必须给出可读原因：${thrown.message}",
        )
    }

    // ================================================================
    // 5. DataUrl 单元口径（解析的唯一入口，独立于任何 provider）
    // ================================================================

    @Test
    @DisplayName("★ DataUrl.parse 白名单：jpeg/png/gif/webp 收，其余拒")
    fun dataUrlWhitelist() {
        assertEquals(
            setOf("image/jpeg", "image/png", "image/gif", "image/webp"),
            DataUrl.ALLOWED_MEDIA_TYPES,
            "白名单是四家官方 API 共同接受的栅格图格式",
        )
        for (mime in DataUrl.ALLOWED_MEDIA_TYPES) {
            val parsed = DataUrl.parse("data:$mime;base64,$pngBase64")
            assertEquals(mime, parsed.mediaType)
            assertEquals(pngBase64, parsed.base64, "★ 解析结果必须是**纯** base64（无前缀）")
        }
        for (bad in listOf("image/bmp", "image/svg+xml", "image/jpg", "text/plain", "application/pdf")) {
            val thrown = assertThrows(IllegalArgumentException::class.java) {
                DataUrl.parse("data:$bad;base64,$pngBase64")
            }
            assertTrue(
                thrown.message.orEmpty().contains("不支持的图片格式"),
                "mime `$bad` 必须被拒（不猜、不纠正）：${thrown.message}",
            )
        }
    }

    @Test
    @DisplayName("★ DataUrl.parse 大小写不敏感地认 `;base64`，但 media_type 归一成小写")
    fun dataUrlIsCaseInsensitiveOnMarker() {
        val parsed = DataUrl.parse("data:IMAGE/PNG;BASE64,$pngBase64")
        assertEquals("image/png", parsed.mediaType, "media_type 归一成小写")
        assertEquals(pngBase64, parsed.base64, "载荷保持原样（base64 本身大小写敏感）")
    }

    @Test
    @DisplayName("★★ 图片经 Anthropic 与 Responses 两轨发出的形状**互不串味**")
    fun twoTracksDoNotLeakEachOthersShape() {
        val anthropic = anthropicBody(textHistory, images = listOf(pngDataUrl)).toString()
        val responses = responsesBody(responsesRequest(listOf(pngDataUrl))).toString()

        // Anthropic 有 `source`、没有 `input_image` / `image_url`
        assertTrue(anthropic.contains("\"source\""), "Anthropic 必须有 source 对象：$anthropic")
        assertFalse(anthropic.contains("input_image"), "Anthropic 不许出现 Responses 的块名")
        assertFalse(anthropic.contains("\"image_url\""), "Anthropic 的图片块不是 image_url 形状")

        // Responses 有 `input_image` + 原样 data URL、没有 `source` / `media_type`
        assertTrue(responses.contains("\"input_image\""), "Responses 必须有 input_image：$responses")
        assertFalse(responses.contains("\"source\""), "Responses 不许出现 Anthropic 的 source 对象")
        assertFalse(responses.contains("\"media_type\""), "Responses 不拆 mime（拆了就是抄 Anthropic）")

        // 两者都必须把 data URL 里的图片真的带出去（不是只加了个空壳）
        assertTrue(anthropic.contains(pngBase64), "Anthropic 必须带上载荷")
        assertTrue(responses.contains(pngDataUrl), "Responses 必须带上**完整 data URL**")
    }

    /** 产出必须是**可再解析**的 JSON（防"拼坏了才恰好缺字段"）。 */
    @Test
    @DisplayName("★ 两轨带图的请求体都能再解析回同结构")
    fun bodiesRoundTrip() {
        listOf(
            anthropicBody(textHistory, images = listOf(pngDataUrl)),
            responsesBody(responsesRequest(listOf(pngDataUrl))),
        ).forEach { body ->
            val again = JsonParser.parseString(body.toString()).asJsonObject
            assertEquals(body, again, "请求体必须能逐字段解析回来：$body")
        }
    }
}
