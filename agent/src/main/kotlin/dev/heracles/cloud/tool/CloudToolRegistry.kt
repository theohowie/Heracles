package dev.heracles.cloud.tool

import dev.heracles.core.tool.CloudParam
import dev.heracles.core.tool.ToolSpec
import dev.heracles.core.tool.cloudToolSpec

/**
 * **云端工具注册表**（`CloudAgentPipeline`，模块一 + 模块五）。
 *
 * ## 它替代了什么
 *
 * 旧 `ToolRegistry`（`core/.../tool/ToolRegistry.kt`）是一个**两段式披露**机制：
 * - 11 个"常驻"工具进冻结前缀，其余 22 个藏进"长尾"
 * - 模型要用长尾工具，必须先 `search_tools("关键词")` 检索，再调真工具 → **多一整轮**
 *
 * 它的核心论据写在 `ToolRegistry.kt:23-29`：
 * > 工具名**枚举在 GBNF 里**，而 GBNF 是**请求参数**、不参与前缀计算
 *
 * **这是 llama.cpp 的性质。** 云端原生 `tools` 数组根本不进 `frozenPrefix`
 * （见 `NativeToolSchema`）⇒ "披露是为了省缓存"这个论据**在云端不成立**。
 * 只剩"工具太多模型会选错"这条 4B 结论 —— 而云端强模型没有这个问题。
 *
 * ⇒ **本类不做披露**：全部工具一次性进 `tools` 数组。
 *
 * ## 模块五的两处修复
 *
 * 1. **`edit` / `apply_patch` 强制常驻**：旧 `ToolZonePlan.RESIDENT` 已 12/12 顶满，
 *    导致 `edit`（2026-10-19 专为"对齐成熟产品形状"新写）被挤到长尾
 *    ⇒ 模型"只用手里有的工具" ⇒ 想不起它 ⇒ 继续整文件重写（而 `edit` 存在的理由正是防这个）。
 *    云端没有 12 格限制，两者都常驻。
 * 2. **低频工具移出常驻**：`apk_*` / `d8_convert` / `zip` 等仍是可用的，
 *    只是不在"每轮都发"的列表里 —— 但仍可通过 `search_tools` 拿到（见 [disclosable]）。
 *
 * ## 为什么还留着 `search_tools`
 *
 * 不是因为它能省缓存，而是因为**工具总数真的会很大**：
 * 11 + 8（Android）+ 4（path）+ 2（web/image）+ N（未来扩展）。
 * 50+ 个工具的 schema 一次发出去，token 成本真实存在（约 50 × 40 token = 2K）。
 * 所以策略是：**高频全发，低频可检索**，而检索**不再阻塞调用**
 * —— 检索结果直接进下一轮 `tools`，模型当轮即可调用。
 */
class CloudToolRegistry(
    /** 每轮**无条件**发给模型的工具（高频）。 */
    val resident: List<CloudTool>,
    /**
     * 可检索的工具（低频）。
     *
     * 与旧机制的关键区别：检索命中后**不消耗推理轮次** ——
     * 装配层会在同一轮内把新工具并入下一轮 `tools`。
     */
    val disclosable: List<CloudTool> = emptyList(),
) {

    private val byNameMap: Map<String, CloudTool> =
        (resident + disclosable).associateBy { it.spec.name }

    init {
        val dup = (resident + disclosable).groupBy { it.spec.name }.filterValues { it.size > 1 }.keys
        require(dup.isEmpty()) { "工具名重复：$dup" }
    }

    fun byName(name: String): CloudTool? = byNameMap[name]

    fun allNames(): List<String> = byNameMap.keys.sorted()

    /** 每轮发给模型的工具集 = 常驻 + 已披露。 */
    fun activeTools(disclosed: Set<String>): List<CloudTool> =
        resident + disclosable.filter { it.spec.name in disclosed }

    /**
     * 检索可披露工具。
     *
     * 排序**必须**确定（得分降序 → 名字升序）：不确定的顺序会让 `tools` 数组抖动，
     * 进而破坏前缀缓存（`02-契约规范.md` §1.1）。
     *
     * 无命中 ⇒ 空列表。**不返回"最接近的几个"** —— 硬凑结果会诱导模型误用工具。
     */
    fun search(query: String, limit: Int = DISCLOSE_LIMIT): List<CloudTool> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return emptyList()
        val terms = q.split(TERM_SPLIT).filter { it.isNotBlank() }
        if (terms.isEmpty()) return emptyList()

        return disclosable
            .map { it to score(it, q, terms) }
            .filter { it.second > 0 }
            .sortedWith(compareByDescending<Pair<CloudTool, Int>> { it.second }.thenBy { it.first.spec.name })
            .take(limit)
            .map { it.first }
    }

    private fun score(tool: CloudTool, lowerQuery: String, terms: List<String>): Int {
        val spec = tool.spec
        val hay = buildString {
            append(spec.name.lowercase()).append(' ')
            append(spec.description.lowercase()).append(' ')
            // ★ 搜索面包含**参数名与描述**（不只是工具名）：
            //   模型常说"分块读取"，而工具叫 read_file 且参数叫 offset
            spec.parameters.forEach { append(it.name.lowercase()).append(' ').append(it.description.lowercase()).append(' ') }
            tool.keywords.forEach { append(it.lowercase()).append(' ') }
        }
        var s = if (hay.contains(lowerQuery)) 2 else 0
        for (t in terms) if (hay.contains(t)) s++
        return s
    }

    companion object {
        /**
         * 一次检索最多披露几个。
         *
         * 12 是**token 成本**折中（12 × ~40 token ≈ 500 token），不是能力限制。
         * 与旧值 6 的区别：旧 6 的理由是"一次披露太多撑爆 C 区（prompt_n 增量目标 150）"
         * —— 那是 4096 上下文时代的 token 预算。
         */
        const val DISCLOSE_LIMIT = 12

        private val TERM_SPLIT = Regex("""[\s,，、;；/|+]+""")
    }
}

/**
 * 一个可被调用的工具（本管线的组织形式）。
 *
 * @param keywords 检索关键词（模型可能说的同义说法）——
 *   只用于 [CloudToolRegistry.search] 的匹配面，不进请求体。
 * @param parallelSafe 可否与其他调用真并发。
 *   默认 `false`（保守）：两个 `write_file` 并发写同一文件、或边删边读会偶发数据错乱。
 *   纯读工具（read/list/grep/find/web_fetch/view_image）声明 `true`。
 * @param isMeta 元工具（`search_tools` / `update_plan` / `ask_user`）——
 *   它们由管线自己拦截执行，不走普通工具路径。
 */
data class CloudTool(
    val spec: ToolSpec,
    /** 执行体。拿到的是**已解析**的参数（JSON 原始文本）。 */
    val run: suspend (Map<String, String>) -> ToolOutcome,
    val parallelSafe: Boolean = false,
    val keywords: List<String> = emptyList(),
    val isMeta: Boolean = false,
) {
    /**
     * 校验用的 Schema 视图 —— 从 [ToolSpec.jsonSchema] **取回**。
     *
     * 取不到（`jsonSchema` 为空、或形状不认识）⇒ `null`
     * ⇒ 校验器按"该工具无 schema"处理（只查未知参数与 10MB 物理闸），
     * **不猜、不构造一个假 schema**。
     *
     * 只算一次（懒加载）：Schema 在工具生命周期内不变。
     */
    val schema: ToolSchema? by lazy {
        spec.jsonSchema?.let { ToolSchema.fromRendered(it) }
    }
}

/** 工具执行结果（本管线自有，不与旧 `agent.ToolOutcome` 耦合）。 */
sealed interface ToolOutcome {
    data class Success(val detail: String) : ToolOutcome

    /** 成功且产物是图片（`view_image`）—— 图片要随下一轮请求发出。 */
    data class SuccessWithImage(val detail: String, val imageDataUrl: String) : ToolOutcome

    data class Failure(val reason: String) : ToolOutcome

    /** 需要用户确认（审批档位）。 */
    data class NeedsApproval(val detail: String) : ToolOutcome
}

/**
 * **构造工具声明** —— 用真实类型，不再全 `string`。
 *
 * 这是模块一的核心：`CloudParam(type = ParamType.Integer)` 会渲染成
 * `"type":"integer"`，模型据此填 `200` 而不是 `"200"`。
 */
object ToolBuilder {

    /** 一个简单的空参数工具（`list_files` 之类）。 */
    fun simple(
        name: String,
        description: String,
        params: List<CloudParam>,
        keywords: List<String> = emptyList(),
        parallelSafe: Boolean = false,
        isMeta: Boolean = false,
        run: suspend (Map<String, String>) -> ToolOutcome,
    ): CloudTool = CloudTool(
        spec = cloudToolSpec(name, description, params),
        run = run,
        parallelSafe = parallelSafe,
        keywords = keywords,
        isMeta = isMeta,
    )
}
