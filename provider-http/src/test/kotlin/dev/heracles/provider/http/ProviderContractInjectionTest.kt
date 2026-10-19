package dev.heracles.provider.http

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.ReasoningLevel
import kotlinx.coroutines.runBlocking
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * 契约注入的**位置守卫** —— `25-流式工作步骤.md` §10.3、`AGENTS.md` 硬约束。
 *
 * ## 为什么值得单独一个测试文件
 *
 * 这一层所有字段的**错误都是静默的**：
 *
 * | 写错 | 现象 | 代价 |
 * |---|---|---|
 * | `stream` 留在 `false` | 不报错，只是"不流式" | **用户看到的整件事没发生** |
 * | 云端漏 `reasoning_effort` | 不报错 | 用户选了 Max 却拿到 default |
 * | 云端误发 Qwen 专有字段 | 某些端点**静默忽略**，另一些直接 400 | 见 ADR-035 |
 *
 * **没有一条能靠"跑一遍看看"发现** —— 只能靠断言请求体的字面结构。
 * 所以这些测试不测"结果对不对"，只测"**发出去的东西长什么样**"。
 *
 * ## ⚠️ ADR-035 S3：本地 llama-server 章节已删除（2026-10-18）
 *
 * 本文件原来还有**一整章**针对本地 `LlamaServerProvider` 的断言（`enable_thinking` 必须嵌套在
 * `chat_template_kwargs` 里、`cache_prompt` / `id_slot` 保留、本地 `authHeaders`、
 * Base URL 的 `/v1` 容错）。**这些断言守护的实现已随本地后端一起删除**，
 * 留着只会是"给不存在的代码写测试"。历史版本见 git（`LlamaServerProvider.kt` 删除前的提交）
 * 与 `docs/实测-01/02/03` 里当年那些读数。
 *
 * ⚠️ 保留的教训（云端仍然要防）：**专有字段不得当通用默认发** —— `enable_thinking` 就是这么
 * 给 DeepSeek / 中转站发 400 的（见 `云端任何推理档位都不发 enable_thinking`）。
 */
class ProviderContractInjectionTest {

    private fun cloudProvider() = OpenAiCompatProvider(
        id = "cloud:test",
        baseUrl = "https://example.invalid/v1",
        apiKey = "k",
        modelName = "m",
    )

    private fun cloudPayload(
        provider: OpenAiCompatProvider,
        stream: Boolean,
        reasoning: ReasoningLevel,
    ): JsonObject {
        val m = OpenAiCompatProvider::class.java.getDeclaredMethod(
            "buildRequestBody",
            List::class.java,
            Int::class.javaPrimitiveType,
            dev.heracles.core.provider.StructuredSpec::class.java,
            Boolean::class.javaPrimitiveType,
            ReasoningLevel::class.java,
            // ★ F7b（2026-10-18）：`tools` 参数追加在最后。这里必须跟着改 ——
            //   反射是按**签名**找方法的，签名对不上会 NoSuchMethodException
            //   （编译期看不出来，只有跑测试才炸）。
            List::class.java,
        )
        m.isAccessible = true
        return m.invoke(
            provider,
            listOf(ChatMessage(ChatRole.USER, "hi")),
            16,
            null,
            stream,
            reasoning,
            // 既有契约注入测试**不带**原生工具 ⇒ 请求体与改动前逐字节相同
            emptyList<dev.heracles.core.tool.ToolSpec>(),
        ) as JsonObject
    }

    // ------------------------------------------------------------ 云端 OpenAI 兼容

    @Test
    fun `云端流式请求体里 stream 为 true`() {
        val payload = cloudPayload(cloudProvider(), stream = true, reasoning = ReasoningLevel.AUTO)
        assertTrue(payload.get("stream").asBoolean)
    }

    /** ★ 云端**支持**分档 —— 现在这是**唯一**的思考表达方式 */
    @Test
    fun `云端 Low High 映射到 reasoning_effort`() {
        assertEquals(
            "low",
            cloudPayload(cloudProvider(), stream = true, ReasoningLevel.LOW)
                .get("reasoning_effort").asString,
        )
        assertEquals(
            "high",
            cloudPayload(cloudProvider(), stream = true, ReasoningLevel.HIGH)
                .get("reasoning_effort").asString,
        )
    }

    /** `MAX` 在部分端点无此档，退化为 `high`（`25` §10.3） */
    @Test
    fun `云端 Max 退化为 high`() {
        assertEquals(
            "high",
            cloudPayload(cloudProvider(), stream = true, ReasoningLevel.MAX)
                .get("reasoning_effort").asString,
        )
    }

    /**
     * `AUTO` 必须**不传**该字段。
     *
     * 我们并不知道服务端理解的 `"auto"` 是什么；某些端点会把不认识的取值判非法。
     * "不传"是唯一诚实的表达。
     */
    @Test
    fun `云端 Auto 不传 reasoning_effort`() {
        val payload = cloudPayload(cloudProvider(), stream = true, reasoning = ReasoningLevel.AUTO)
        assertFalse(
            payload.has("reasoning_effort"),
            "Auto 不应猜一个取值传下去；不传才是诚实的（服务端用自己的默认）",
        )
    }

    /**
     * ★★ S2 起这条从"默认不发"升级为"**能力已不存在**"★★
     *
     * S1a 把 `enable_thinking` 从"通用默认"降级成"显式 opt-in"（那条 400 的修复）；
     * **S2 删掉了字段与开关本身** —— 现在**没有任何取值、任何档位**能让这个键出现。
     * 断言仍写成"键不存在"，因为这才是**whitelist 口径**：请求体里出现它就是回归。
     */
    @Test
    fun `云端 Off 不传 reasoning_effort 也不发 Qwen 专有字段`() {
        val payload = cloudPayload(cloudProvider(), stream = true, reasoning = ReasoningLevel.OFF)
        assertFalse(payload.has("reasoning_effort"))
        // ★ ADR-035：那个字段是 **Qwen3 系专有**的，曾被当成通用默认发给**所有**端点 ⇒
        //   中转站的 DeepSeek 见到它直接 `HTTP 400: 深度思考参数互相冲突`（用户实测）。
        assertFalse(
            payload.has("enable_thinking"),
            "★ 云端**不得**发 enable_thinking（Qwen3 专有字段，DeepSeek/中转站会 400）",
        )
    }

    /**
     * ★★ S2：**四个档位全扫一遍**，证明"字段已彻底退场"不是只对 `OFF` 成立。
     *
     * 为什么需要它：删掉 `disableThinking` 之后，"不发"是**结构性的**（没有任何分支会写这个键）。
     * 但结构性的东西**最容易在下次重构里被加回来**（比如有人为了"省 token"重新引入一个开关）。
     * 这条断言把"**任何**档位下都不出现"钉住 —— 比单测一个 `OFF` 强一档。
     */
    @Test
    fun `云端任何推理档位都不发 enable_thinking`() {
        for (level in ReasoningLevel.entries) {
            val payload = cloudPayload(cloudProvider(), stream = true, reasoning = level)
            assertFalse(
                payload.has("enable_thinking"),
                "★ 档位 $level 下出现了 enable_thinking —— 该字段已随 ADR-035 S2 退场，" +
                    "要按端点判断请走 ADR（DashScope 的代价见 provider 类 KDoc）",
            )
            // 顶层与嵌套层都必须没有（历史坑：放错层级会被**静默忽略**）
            val kk = payload.getAsJsonObject("chat_template_kwargs")
            assertTrue(kk == null || !kk.has("enable_thinking"), "嵌套层里也不许出现：$level")
        }
    }

    @Test
    fun `云端流式也索取 usage`() {
        val payload = cloudPayload(cloudProvider(), stream = true, reasoning = ReasoningLevel.LOW)
        assertTrue(payload.getAsJsonObject("stream_options").get("include_usage").asBoolean)
    }

    /** 云端 `temperature=0` 是确定性硬要求，不得被本次改动碰掉 */
    @Test
    fun `云端温度仍然为 0`() {
        val payload = cloudPayload(cloudProvider(), stream = true, reasoning = ReasoningLevel.LOW)
        assertEquals(0, payload.get("temperature").asInt)
    }

    // ------------------------------------------------------------ 档位语义（与实现无关）

    @Test
    fun `档位到布尔开关的映射符合实测`() {
        assertEquals(null, ReasoningLevel.AUTO.thinkingRequested, "Auto = 由实现决定，不是开也不是关")
        assertEquals(false, ReasoningLevel.OFF.thinkingRequested)
        assertEquals(true, ReasoningLevel.LOW.thinkingRequested)
        assertEquals(true, ReasoningLevel.HIGH.thinkingRequested)
        assertEquals(true, ReasoningLevel.MAX.thinkingRequested)
    }

    @Test
    fun `线上档位名 Default 已更名为 Auto`() {
        assertEquals(ReasoningLevel.AUTO, ReasoningLevel.fromWire("auto"))
        // 旧名兼容：读到 "default" 不能让设置解析崩掉，退化为 Auto
        assertEquals(ReasoningLevel.AUTO, ReasoningLevel.fromWire("default"))
        assertEquals(ReasoningLevel.AUTO, ReasoningLevel.fromWire(null))
        assertEquals(ReasoningLevel.OFF, ReasoningLevel.fromWire("off"))
        assertEquals(ReasoningLevel.LOW, ReasoningLevel.fromWire("LOW"))
        assertEquals(ReasoningLevel.HIGH, ReasoningLevel.fromWire("high"))
        assertEquals(ReasoningLevel.MAX, ReasoningLevel.fromWire("max"))
    }

    /** 请求体必须是合法 JSON（防止有人手工拼字符串拼坏） */
    @Test
    fun `生成的请求体可被重新解析`() {
        val payload = cloudPayload(cloudProvider(), stream = true, reasoning = ReasoningLevel.LOW)
        val reparsed = JsonParser.parseString(payload.toString()).asJsonObject
        assertEquals(payload.toString(), reparsed.toString(), "请求体必须是可往返解析的合法 JSON")
    }

    /** 未 load 就调 generateStream 必须立刻失败（而不是挂在一个永远不会发生的请求上） */
    @Test
    fun `未 load 时流式请求立刻失败`() {
        val provider = cloudProvider()
        var thrown: Throwable? = null
        try {
            // 只收一个元素就够触发内部 check(loaded)
            runBlocking {
                provider.generateStream(GenerateRequest(prompt = "hi", maxOutputTokens = 4))
                    .collect { }
            }
        } catch (t: Throwable) {
            thrown = t
        }
        assertNotNull(thrown, "未 load 时 generateStream 必须抛错")
        assertTrue(
            thrown!!.message?.contains("load") == true,
            "错误信息应说明要先 load，实际：${thrown.message}",
        )
    }
}
