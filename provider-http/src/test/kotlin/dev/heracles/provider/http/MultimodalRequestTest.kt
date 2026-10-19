package dev.heracles.provider.http

import com.google.gson.JsonObject
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.ProviderConfig
import dev.heracles.core.provider.ReasoningLevel
import dev.heracles.core.provider.StructuredSpec
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * **多模态请求体的形状门禁**（2026-10-19）。
 *
 * ## 为什么这些断言必须有
 *
 * "把图片发出去"在 UI 上看不出对错：模型看不到图时，它照样能一本正经地编。
 * 所以必须钉住**请求体本身**：图片以 `image_url` 内容块出现在 messages 里，
 * 且**不传图时请求体逐字节不变**（既有缓存前缀与非多模态端点不受影响）。
 *
 * ⚠️ 这只是**形状**证据。按 `AGENTS.md` 的规矩，"wire 变更必须真 Key 验证"——
 * 本条链路的真 Key 验证**尚未做**（见 WORKLOG）。
 */
class MultimodalRequestTest {

    private val dataUrl = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private fun openAiBody(images: List<String>): JsonObject {
        val m = OpenAiCompatProvider::class.java.getDeclaredMethod(
            "buildRequestBody",
            List::class.java,
            Int::class.javaPrimitiveType,
            StructuredSpec::class.java,
            Boolean::class.javaPrimitiveType,
            ReasoningLevel::class.java,
            List::class.java,
            List::class.java,
        )
        m.isAccessible = true
        return m.invoke(
            OpenAiCompatProvider("cloud:test", "https://example.invalid/v1", "k", "m"),
            listOf(ChatMessage(ChatRole.USER, "这张图是什么？")),
            16,
            null,
            false,
            ReasoningLevel.AUTO,
            emptyList<Any>(),
            images,
        ) as JsonObject
    }

    @Test
    @DisplayName("★★ 有图 ⇒ messages 末尾多一条 user，content 是 [text, image_url] 数组")
    fun imageBecomesContentArray() {
        val body = openAiBody(listOf(dataUrl))
        val messages = body.getAsJsonArray("messages")
        assertEquals(2, messages.size(), "有图时应追加一条 user 消息：$messages")
        val last = messages[1].asJsonObject
        assertEquals("user", last.get("role").asString)
        val content = last.getAsJsonArray("content")
        assertEquals("text", content[0].asJsonObject.get("type").asString)
        val image = content[1].asJsonObject
        assertEquals("image_url", image.get("type").asString)
        assertEquals(dataUrl, image.getAsJsonObject("image_url").get("url").asString)
    }

    @Test
    @DisplayName("★ 不传图 ⇒ 请求体里没有 image_url（文本轨逐字节不变）")
    fun textOnlyBodyHasNoImageParts() {
        val body = openAiBody(emptyList())
        val messages = body.getAsJsonArray("messages")
        assertEquals(1, messages.size(), "纯文本请求不该多出消息：$messages")
        assertFalse(body.toString().contains("image_url"), "纯文本请求体不该有 image_url：$body")
    }

    @Test
    @DisplayName("★★ Anthropic 轨未接通读图 ⇒ 显式失败（不静默丢图）")
    fun anthropicFailsLoudly() = runBlocking {
        val p = AnthropicProvider(apiKey = "k", modelName = "m")
        p.load(ProviderConfig()).getOrThrow()
        val r = p.generate(
            GenerateRequest(
                prompt = "看这张图",
                maxOutputTokens = 16,
                images = listOf(dataUrl),
            ),
        )
        assertTrue(r.isFailure, "必须失败：$r")
        assertTrue(
            r.exceptionOrNull()?.message?.contains("不支持读图") == true,
            "失败原因必须说清是读图不支持：${r.exceptionOrNull()?.message}",
        )
    }

    @Test
    @DisplayName("★★ Responses 轨未接通读图 ⇒ 显式失败（不静默丢图）")
    fun responsesFailsLoudly() = runBlocking {
        val p = OpenAiResponsesProvider("responses:test", "https://example.invalid", "k", "m")
        p.load(ProviderConfig()).getOrThrow()
        val r = p.generate(
            GenerateRequest(
                prompt = "看这张图",
                maxOutputTokens = 16,
                images = listOf(dataUrl),
            ),
        )
        assertTrue(r.isFailure, "必须失败：$r")
        assertTrue(
            r.exceptionOrNull()?.message?.contains("不支持读图") == true,
            "失败原因必须说清是读图不支持：${r.exceptionOrNull()?.message}",
        )
    }

    @Test
    @DisplayName("纯文本请求在 Anthropic / Responses 轨仍正常构造（零回退）")
    fun textOnlyStillWorks() = runBlocking {
        val a = AnthropicProvider(apiKey = "k", modelName = "m")
        a.load(ProviderConfig()).getOrThrow()
        // 只构造请求体，不发网络：用反射调 buildBody 证明不抛
        val m = AnthropicProvider::class.java.getDeclaredMethod(
            "buildBody",
            List::class.java,
            Int::class.javaPrimitiveType,
            Boolean::class.javaPrimitiveType,
            List::class.java,
        )
        m.isAccessible = true
        val body = m.invoke(a, listOf(ChatMessage(ChatRole.USER, "hi")), 16, false, emptyList<Any>())
        assertTrue(body.toString().contains("hi"))
    }
}
