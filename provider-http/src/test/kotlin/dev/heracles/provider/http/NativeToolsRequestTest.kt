package dev.heracles.provider.http

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.heracles.core.context.PrefixBuilder
import dev.heracles.core.provider.ChatMessage
import dev.heracles.core.provider.ChatRole
import dev.heracles.core.provider.GenerateRequest
import dev.heracles.core.provider.ProviderCapabilities
import dev.heracles.core.provider.ReasoningLevel
import dev.heracles.core.provider.StructuredSpec
import dev.heracles.core.tool.ToolParam
import dev.heracles.core.tool.ToolSpec
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * 原生 `tools` 请求侧（ADR-031 决策 2）—— **只测"发出去的东西长什么样"**。
 *
 * ## 为什么不发网络请求
 *
 * 与 [ProviderContractInjectionTest] 同款理由：这一层的错误**全是静默的** ——
 * `tools` 形状写错，模型只会"用得很差"，不会报错。所以只构造请求体、断言字面结构。
 *
 * ## "零回退"的机械证据（不是"我看了好像没变"）
 *
 * **云端 `tools` 为空**：[OpenAiCompatProvider] 的请求体逐字符钉死 ——
 * 出厂 `nativeToolsEnabled = false` ⇒ 空列表 ⇒ 与 F7b 之前**一个字节都不差**。
 *
 * ⚠️ 这条**故意**是整串金标准（不是 `contains`）：一个字节变了就该红，
 * 让人**有意识地**改这一条，而不是"顺手改了请求体、谁也没发现"。
 * 将来有意改请求体时，连同本文件一起改并在提交信息里说明。
 *
 * ## ⚠️ ADR-035 S3：本地 `LlamaServerProvider` 的用例已删除（2026-10-18）
 *
 * 原来这里还有两条本地专属断言（本地请求体逐字符金标准 + "本地不能接收 tools 声明、
 * GBNF 照旧发"）。它们守护的实现已随本地后端一起删除，留着只是给不存在的代码写测试；
 * 历史见 `LlamaServerProvider.kt` 删除前的 git 提交与 `docs/实测-*`。
 */
class NativeToolsRequestTest {

    // ---------------------------------------------------------------- 夹具

    private val specs = listOf(
        ToolSpec(
            "read_file", "读文件",
            listOf(
                ToolParam("path", "string", "路径"),
                ToolParam("offset", "string", "起始行号", allowEmpty = true, optional = true),
            ),
        ),
        ToolSpec(
            "build_apk", "构建",
            listOf(ToolParam("project_dir", "string", "项目目录")),
        ),
    )

    private fun cloudProvider() = OpenAiCompatProvider(
        id = "cloud:test",
        baseUrl = "https://example.invalid/v1",
        apiKey = "k",
        modelName = "m",
    )

    private fun anthropicProvider() = AnthropicProvider(apiKey = "k", modelName = "m")

    private fun responsesProvider() = OpenAiResponsesProvider(
        id = "responses:test",
        baseUrl = "https://example.invalid",
        apiKey = "k",
        modelName = "m",
    )

    /**
     * 只构造请求体、不发请求 —— 与 [ProviderContractInjectionTest] 同款：
     * **用反射调私有方法**，而不是为了测试把构造器改成 public
     * （那会让外部绕过 provider 生命周期直接调它）。
     */
    private fun openAiBody(
        tools: List<ToolSpec> = emptyList(),
        structured: StructuredSpec? = null,
    ): JsonObject {
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
            cloudProvider(),
            listOf(ChatMessage(ChatRole.USER, "hi")),
            16,
            structured,
            false,
            ReasoningLevel.AUTO,
            tools,
            emptyList<String>(),
        ) as JsonObject
    }

    private fun anthropicBody(tools: List<ToolSpec> = emptyList()): JsonObject {
        // ★ 2026-10-19 多模态起 arity 是 5（…, tools, images）。按「名字 + 个数」取 ——
        //   精确签名会在这类加参数的改动后**运行时**失效而编译仍绿。
        val m = AnthropicProvider::class.java.declaredMethods
            .single { it.name == "buildBody" && it.parameterCount == 5 }
            .apply { isAccessible = true }
        return m.invoke(
            anthropicProvider(),
            listOf(ChatMessage(ChatRole.USER, "hi")),
            16,
            false,
            tools,
            emptyList<String>(),
        ) as JsonObject
    }

    /**
     * Responses 的 `buildBody` 收的是**整个** `GenerateRequest`
     * ⇒ 可以真的把 `structuredOutput` 传进去（别的两家连这个参数都没有）。
     * 这正是"这一家**将来会漂移**"的结构原因：它读得到，今天只是没读。
     */
    private fun responsesBody(
        tools: List<ToolSpec> = emptyList(),
        structured: StructuredSpec? = null,
    ): JsonObject {
        // ★ 2026-10-19 多模态起 arity 是 3（request, stream, images）
        val m = OpenAiResponsesProvider::class.java.declaredMethods
            .single { it.name == "buildBody" && it.parameterCount == 3 }
            .apply { isAccessible = true }
        return m.invoke(
            responsesProvider(),
            GenerateRequest(prompt = "hi", maxOutputTokens = 16, tools = tools, structuredOutput = structured),
            false,
            emptyList<String>(),
        ) as JsonObject
    }

    // ================================================================
    // 1. 能力位：**声明** ≠ **启用**
    // ================================================================

    @Test
    @DisplayName("★ 能力位默认 false：本地 false / 云端三家 true（声明能力，不等于已启用）")
    fun nativeToolsCapabilityIsDeclaredNotEnabled() {
        // 默认 false ⇒ 既有实现（含测试替身）不改也安全
        assertFalse(
            ProviderCapabilities(
                supportsGrammar = true,
                supportsJsonSchema = true,
                supportsPrefixCache = true,
                needsPrewarm = false,
            ).supportsNativeTools,
            "能力位默认必须是 false —— 否则所有既有 provider 会**静默**开始发 tools",
        )

        assertTrue(cloudProvider().capabilities.supportsNativeTools, "OpenAI 兼容：有能力")
        assertTrue(anthropicProvider().capabilities.supportsNativeTools, "Anthropic：有能力")
        assertTrue(responsesProvider().capabilities.supportsNativeTools, "Responses：有能力")

        // 而且**请求侧的载体默认是空的** ⇒ 今天的请求体不含任何 tools 相关字节
        assertTrue(
            GenerateRequest(prompt = "p", maxOutputTokens = 8).tools.isEmpty(),
            "GenerateRequest.tools 默认必须是空列表（= 今天的行为）",
        )
    }

    // ================================================================
    // 2. 零回退的机械证据（云端 `tools` 为空时逐字符金标准）
    // ================================================================

    @Test
    @DisplayName("★★ 零回退：云端 `tools` 为空时请求体逐字符不变（F7b 之后、S1a 之后各一次）")
    fun cloudRequestBodyWithoutToolsIsPinnedByteForByte() {
        val body = openAiBody(structured = StructuredSpec.Grammar("G"))
        assertEquals(
            "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]," +
                "\"max_tokens\":16,\"stream\":false,\"temperature\":0," +
                "\"response_format\":{\"type\":\"json_object\"}}",
            body.toString(),
            "出厂 `tools` 为空 ⇒ 请求体仍与 F7b 时逐字节相同。★ 与 F7b 那次唯一的差别是：\n" +
                "  旧串里有 `\"enable_thinking\":false`，**现在没有了**（S1a / ADR-035）——\n" +
                "  它是 Qwen3 系专有字段，发给 DeepSeek / 中转站会 400。\n" +
                "  这条金标准的**更新本身就是那次修复的证据**：改动前后只差这一个键。",
        )
        assertFalse(
            body.has("enable_thinking"),
            "★ S1a：键必须**不存在**（不是 null、不是 false）—— 这是「不发」的唯一诚实断言",
        )
    }

    // ================================================================
    // 3. `tools` 非空 ⇒ 发声明，并**撤掉自相矛盾的 `response_format`**
    // ================================================================

    @Test
    @DisplayName("★ tools 非空：OpenAI 兼容发出 function 形状，且**不再发** response_format")
    fun cloudWithToolsSendsToolsAndDropsResponseFormat() {
        val body = openAiBody(tools = specs, structured = StructuredSpec.Grammar("G"))

        assertTrue(body.has("tools"), "有声明就必须发出去")
        assertFalse(
            body.has("response_format"),
            "`json_object`（必须给我 JSON）与 `tools`（用原生工具调用）是**两套矛盾指令** —— " +
                "同时发就是 docs/27 §2.5③ 的病根复发，必须互斥",
        )
        // structured 为 null 时同样不该有 response_format（互斥与有无 structured 无关）
        assertFalse(openAiBody(tools = specs).has("response_format"))

        val tools = body.getAsJsonArray("tools")
        assertEquals(2, tools.size(), "工具声明不许被吞、也不许被复制")
        assertEquals("function", tools[0].asJsonObject.get("type").asString)
        assertEquals(
            NativeToolSchema.canonicalBody(specs[0]),
            tools[0].asJsonObject.getAsJsonObject("function"),
            "工具声明必须与文本轨**同一个源**（canonicalToolJson），不许手写第二份",
        )
    }

    @Test
    @DisplayName("★ 空列表 ⇒ 三家都不加 `tools` 键（不加空数组，避免无谓的形状变化）")
    fun emptyToolsAddNoKeyAnywhere() {
        assertFalse(openAiBody().has("tools"))
        assertFalse(anthropicBody().has("tools"))
        assertFalse(responsesBody().has("tools"))
    }

    // ================================================================
    // 4. 两轨语义一致性 —— F7 唯一能防"两套真相"的办法
    // ================================================================

    @Test
    @DisplayName("★★ 两轨一致：原生数组与 canonical 文本声明**同一组工具/参数/必填性**")
    fun bothTracksDescribeTheSameTools() {
        // 文本轨：canonicalToolJson（进冻结前缀的那份）
        val textTrack = specs.map { JsonParser.parseString(PrefixBuilder.canonicalToolJson(it)).asJsonObject }

        // 原生轨：三家形状各取一次
        val nativeTracks = mapOf(
            "openai" to NativeToolSchema.openAiCompat(specs),
            "anthropic" to NativeToolSchema.anthropic(specs),
            "responses" to NativeToolSchema.responses(specs),
        )

        nativeTracks.forEach { (family, array) ->
            assertEquals(specs.size, array.size(), "$family：工具个数必须一致")
            array.forEachIndexed { i, element ->
                val canonical = textTrack[i]
                val native = summarize(family, element.asJsonObject)

                assertEquals(
                    canonical.get("name").asString,
                    native.getValue("name"),
                    "$family 第 $i 个的**工具名**与文本轨不一致",
                )
                assertEquals(
                    canonical.get("description").asString,
                    native.getValue("description"),
                    "$family 第 $i 个的**描述**与文本轨不一致（描述也是模型选工具的依据）",
                )
                val params = canonical.getAsJsonObject("parameters")
                assertEquals(
                    params.getAsJsonObject("properties").keySet(),
                    native.getValue("propertyNames"),
                    "$family 第 $i 个的**参数集**与文本轨不一致",
                )
                assertEquals(
                    params.getAsJsonArray("required").map { it.asString }.toSet(),
                    native.getValue("requiredNames"),
                    "$family 第 $i 个的**必填集**与文本轨不一致 —— " +
                        "原生 required 列错就是教模型多填/漏填参数",
                )
            }
        }
    }

    /** 把三家形状归一成"语义三元组"，让一致性断言不必关心外壳差异。 */
    private fun summarize(family: String, element: JsonObject): Map<String, Any> = when (family) {
        // `{"type":"function","function":{…}}`
        "openai" -> fromBody(element.getAsJsonObject("function"))
        // `{"name":…,"input_schema":…}`
        "anthropic" -> mapOf(
            "name" to element.get("name").asString,
            "description" to element.get("description").asString,
            "propertyNames" to element.getAsJsonObject("input_schema")
                .getAsJsonObject("properties").keySet(),
            "requiredNames" to element.getAsJsonObject("input_schema")
                .getAsJsonArray("required").map { it.asString }.toSet(),
        )
        // 扁平：`{"type":"function","name":…,"parameters":…}`
        else -> fromBody(element)
    }

    private fun fromBody(body: JsonObject): Map<String, Any> {
        val params = body.getAsJsonObject("parameters")
        return mapOf(
            "name" to body.get("name").asString,
            "description" to body.get("description").asString,
            "propertyNames" to params.getAsJsonObject("properties").keySet(),
            "requiredNames" to params.getAsJsonArray("required").map { it.asString }.toSet(),
        )
    }

    @Test
    @DisplayName("★ 原生形状与 canonical 函数体**深度相等**（三家各自的壳，内核同一个）")
    fun nativeShapesAreWrappedCanonicalBodies() {
        val canonical = NativeToolSchema.canonicalBody(specs[0])

        // OpenAI：整个 function 就是 canonical 体
        assertEquals(
            canonical,
            NativeToolSchema.openAiCompat(specs)[0].asJsonObject.getAsJsonObject("function"),
        )
        // Anthropic：name/description/input_schema(=parameters) 三块都来自 canonical 体
        val a = NativeToolSchema.anthropic(specs)[0].asJsonObject
        assertEquals(canonical.get("name"), a.get("name"))
        assertEquals(canonical.get("description"), a.get("description"))
        assertEquals(canonical.get("parameters"), a.get("input_schema"))
        // Responses：扁平，字段一一对应
        val r = NativeToolSchema.responses(specs)[0].asJsonObject
        assertEquals("function", r.get("type").asString)
        assertEquals(canonical.get("name"), r.get("name"))
        assertEquals(canonical.get("description"), r.get("description"))
        assertEquals(canonical.get("parameters"), r.get("parameters"))
    }

    // ================================================================
    // 5. 自包含 + 确定性（分片拼完就能校验 / 前缀不抖）
    // ================================================================

    @Test
    @DisplayName("★ 声明自包含：required ⊆ properties、无 \$ref、参数都有 type（拼完分片即可校验）")
    fun declarationsAreSelfContained() {
        val all = listOf(
            NativeToolSchema.openAiCompat(specs),
            NativeToolSchema.anthropic(specs),
            NativeToolSchema.responses(specs),
        )
        all.forEach { array ->
            val raw = array.toString()
            assertFalse(raw.contains("\$ref"), "不许用 \$ref —— 模型侧拼完 arguments 后我们无法解析引用")
            array.forEach { element ->
                val params = if (element.asJsonObject.has("function")) {
                    element.asJsonObject.getAsJsonObject("function").getAsJsonObject("parameters")
                } else {
                    (element.asJsonObject.get("input_schema") ?: element.asJsonObject.get("parameters"))
                        .asJsonObject
                }
                val properties = params.getAsJsonObject("properties")
                val required = params.getAsJsonArray("required").map { it.asString }
                assertTrue(
                    properties.keySet().containsAll(required),
                    "required 必须是 properties 的子集（实际 required=$required / properties=${properties.keySet()}）",
                )
                properties.entrySet().forEach { (name, schema) ->
                    assertNotNull(
                        schema.asJsonObject.get("type"),
                        "参数 $name 缺 type —— 拼完的 arguments 没法按类型校验",
                    )
                }
            }
        }
    }

    @Test
    @DisplayName("★ 声明确定性 + 顺序 = 调用方给的顺序（同一批工具两次构造逐字节相同）")
    fun declarationsAreDeterministicAndOrdered() {
        fun firstToolName(array: com.google.gson.JsonArray): String =
            array[0].asJsonObject.getAsJsonObject("function").get("name").asString

        // ① 确定性：同一批声明两次构造必须逐字节相同（否则前缀每轮 miss）
        assertEquals(
            NativeToolSchema.openAiCompat(specs).toString(),
            NativeToolSchema.openAiCompat(specs).toString(),
            "同一批声明两次构造必须逐字节相同（否则前缀每轮 miss）",
        )

        // ② 顺序 = 调用方的候选顺序，既不许排序、也不许去重
        assertEquals("read_file", firstToolName(NativeToolSchema.openAiCompat(specs)))
        assertEquals(
            "build_apk",
            firstToolName(NativeToolSchema.openAiCompat(specs.reversed())),
            "顺序必须跟着调用方走（被'顺手排序'会让 prefix 与文本轨的顺序对不上）",
        )
        assertNotEquals(
            NativeToolSchema.openAiCompat(specs).toString(),
            NativeToolSchema.openAiCompat(specs.reversed()).toString(),
            "输入顺序变了，输出必须跟着变（否则说明顺序被吞了）",
        )
    }

    // ================================================================
    // 6. P0-2 硬前置：原生开 ⇒ **不发**约束解码（三家形状各钉一遍）
    // ================================================================

    /**
     * 各协议表达"强制 JSON"的键名。
     *
     * ⚠️ **按名字列，不是只查 `response_format`**：换个键名就等于绕过了互斥
     * （Responses 的 `text.format` 正是这么来的）。将来若有人再加 `json_mode` /
     * `guided_json` 之类，这里也要跟着红 —— 否则"互斥"只防住了今天这一个名字。
     */
    private fun hasAnyJsonModeField(body: JsonObject): Boolean {
        val flat = listOf("response_format", "json_mode", "grammar", "guided_json", "guided_grammar", "format")
        if (flat.any { body.has(it) }) return true
        // Responses 的容器形状：`text: { format: … }`
        val text = body.get("text")?.takeIf { it.isJsonObject }?.asJsonObject
        return text != null && text.has("format")
    }

    @Test
    @DisplayName("★★ 三家：`tools` 非空 ⇒ 请求体里**没有任何**约束解码字段（键不存在，不是空对象）")
    fun toolsSuppressStructuredOutputInEveryShape() {
        // OpenAI 兼容 / Responses：把 `structuredOutput` **真的传进去**（否则本测试是空转）
        val openAi = openAiBody(tools = specs, structured = StructuredSpec.Grammar("G"))
        val responses = responsesBody(tools = specs, structured = StructuredSpec.Grammar("G"))
        // Anthropic：`buildBody` 没有 structured 参数 ⇒ 传不进去（结构性真空，见下面独立一条）
        val anthropic = anthropicBody(tools = specs)

        mapOf("OpenAI 兼容" to openAi, "Anthropic" to anthropic, "Responses" to responses)
            .forEach { (name, body) ->
                assertTrue(body.has("tools"), "$name：有声明就必须发出去（否则本测试前提不成立）：$body")
                assertFalse(
                    body.has("response_format"),
                    "$name：`response_format` 键**不得存在** —— 不是「发了空对象」，是压根没有这个键：$body",
                )
                assertFalse(
                    hasAnyJsonModeField(body),
                    "★ $name：`tools` 非空时不许发**任何**约束解码字段 —— " +
                        "`json_object` 说的是「必须给我 JSON」、`tools` 说的是「用原生工具调用」，" +
                        "同时发就是两份矛盾指令（`docs/27` §2.5③ 的病根换个位置复发）：$body",
                )
            }
    }

    @Test
    @DisplayName("★★★ 核心：**同一个判断**同时管两件事 —— 只翻转 `tools`，两个键同时反转、其余逐字节相同")
    fun oneJudgmentControlsBothKeys() {
        val withTools = openAiBody(tools = specs, structured = StructuredSpec.Grammar("G"))
        val withoutTools = openAiBody(tools = emptyList(), structured = StructuredSpec.Grammar("G"))

        // ① 双向：同一次判断的两个方向都要成立
        assertTrue(withTools.has("tools"), "有声明就要发")
        assertFalse(withTools.has("response_format"), "有 tools ⇒ 不发约束解码")
        assertFalse(withoutTools.has("tools"), "空列表不加键")
        assertTrue(withoutTools.has("response_format"), "无 tools ⇒ 照旧降级成 json_object（零回退）")

        // ② 只翻转 `tools`：把这两个键摘掉后，其余部分必须**逐字节相同**
        //    ⇒ 若哪天多出一个键跟着变，或判断被复制到第二处，这条会红
        assertEquals(
            withoutTheTwoKeys(withTools),
            withoutTheTwoKeys(withoutTools),
            "★ 翻转 `tools` 只应影响 `tools` 与 `response_format` 这两个键 —— " +
                "其余逐字节相同，才能证明是**同一个判断**在管它们（一旦分叉就会在这里露出来）",
        )
    }

    /** 摘掉 `tools` / `response_format` 后的剩余串（用来证明"只翻转 tools"）。 */
    private fun withoutTheTwoKeys(body: JsonObject): String {
        val copy = JsonObject()
        body.entrySet()
            .filter { it.key != "tools" && it.key != "response_format" }
            .forEach { copy.add(it.key, it.value) }
        return copy.toString()
    }

    @Test
    @DisplayName("★★ Anthropic 是**结构性真空**：本类没有 `buildBody(structured=…)` 这个口子，不是\"忘了发\"")
    fun anthropicHasNoStructuredSeam() {
        val seam = AnthropicProvider::class.java.declaredMethods
            .filter { it.parameterTypes.contains(StructuredSpec::class.java) }
            .map { it.name }
        assertTrue(
            seam.isEmpty(),
            "Anthropic 既没有 GBNF、也没有 `response_format` ⇒ 本类不得出现接收 StructuredSpec 的入口。" +
                "若确实要接（例如改用 `tool_use` 强制 JSON），**必须同时**处理" +
                "「原生 `tools` 非空 ⇒ 不发约束解码」的互斥 + 真机验证，并改本测试。实际：$seam",
        )
        // 对照组：OpenAI 兼容路径**必须**有那个入口 —— 它就是靠它降级的。
        // 这条红了说明降级被搬走了，那就要连同上面的互斥一起重看。
        assertTrue(
            OpenAiCompatProvider::class.java.declaredMethods
                .any { it.parameterTypes.contains(StructuredSpec::class.java) },
            "对照组：`response_format` 的降级必须落在 OpenAI 兼容 provider 里",
        )
    }

    @Test
    @DisplayName("★ Responses 是**会漂移**：`buildBody` 收整个 request（读得到），今天只是没读")
    fun responsesHasTheSeamButDoesNotUseItYet() {
        // 签名证据：它**看得到** structuredOutput（与 Anthropic 的"看不见"不同）
        // ★ 2026-10-19 多模态起 arity 是 3（request, stream, images）
        val m = OpenAiResponsesProvider::class.java.declaredMethods
            .single { it.name == "buildBody" && it.parameterCount == 3 }
        assertTrue(
            m.parameterTypes.contains(GenerateRequest::class.java),
            "Responses 的 buildBody 收的是整个 GenerateRequest ⇒ 读得到 structuredOutput ⇒ 属于\"会漂移\"那一类",
        )

        // 行为证据：即使显式要求 Grammar，也不发任何约束解码字段
        val body = responsesBody(tools = specs, structured = StructuredSpec.Grammar("G"))
        assertFalse(
            hasAnyJsonModeField(body),
            "★ 今天不发 —— ⚠️ 但这是**缺口的症状，不是设计**：走 Responses 这条路时约束解码" +
                "**实际没有**（与 `02-契约规范.md` §6「云端降级成 json_object」不符），是**已知债务**" +
                "（本轮不补：改 wire + 真 Key 验证 = 新的未验面）。$body",
        )
    }
}
