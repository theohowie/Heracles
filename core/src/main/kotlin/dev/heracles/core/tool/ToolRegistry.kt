package dev.heracles.core.tool

import dev.heracles.core.contract.Contract

/**
 * 工具注册表 —— `26-编码层工具链与逆向引擎.md` §5、`02-契约规范.md` §4.1。
 *
 * ## 为什么需要"常驻 / 长尾"两分
 *
 * 常驻上限（今天 [Contract.Tools.FROZEN_LIMIT] = 12）不是审美要求，是**两条硬约束的交点**：
 *
 * | 约束 | 来源 | 后果 |
 * |---|---|---|
 * | 冻结区要短 | 缓存命中率 > 90%（验收 2.1） | 工具 schema 进冻结区 ⇒ 每个都吃 `cache_n` 的前缀预算 |
 * | 工具不能多 | 契约 §4.1 | **可见工具过多 ⇒ 选择准确率下降**（该条原是对 4B 实测的，云端阈值更宽） |
 *
 * 而本阶段要加 10 个工具（`26` §4.2）。⇒ 只能：**少量常驻 + 其余按需披露**。
 *
 * ⚠️ **2026-10-18（ADR-035 S1b）**：原先的 8 / 12 / 3 是**为本地 4B** 定的，云端按
 * `Contract.Zone.*For(backend)` 放宽；本地后端删除后 `Zone` 与全部 `For(backend)` 已删，
 * 这里只剩**一套**上限（`Contract.Tools`）。"按后端传参"的装配逻辑不再存在。
 *
 * ## 与 grammar 的关系（`26` §2.1 的关键发现）
 *
 * 工具名**枚举在 GBNF 里**，而 GBNF 是**请求参数**、不进前缀缓存；
 * 进冻结区的只有 [resident] 的 schema 文本。
 *
 * ⇒ [namesFor] 返回的集合可以**随轮次增长**（披露一个就加一个），
 * 而冻结区**逐字节不变** ⇒ 缓存不塌。这是本设计能成立的前提。
 */
class ToolRegistry(
    /** 常驻工具 —— 进冻结区，会话内逐字节恒定 */
    val resident: List<ToolSpec>,
    /** 长尾工具 —— 只在 `search_tools` 命中后披露，schema 本身**不进**冻结区 */
    val longTail: List<ToolSpec> = emptyList(),
    /** 显式分组（`26` §5）：name → group。用于把同义说法纳入检索面 */
    private val groups: Map<String, ToolGroup> = emptyMap(),
    /**
     * 常驻上限 —— 默认 [Contract.Tools.FROZEN_LIMIT]（12）。
     *
     * 保留成参数是为了**测试能构造越档场景**（`ToolRegistryTest`）与将来调参，
     * 不再是"按后端给档"（那套已随 ADR-035 删除）。
     */
    private val maxFrozen: Int = Contract.Tools.FROZEN_LIMIT,
    /**
     * 长尾上限 —— 默认 [Contract.Tools.LONG_TAIL_LIMIT]（24）。
     *
     * 长尾不吃前缀缓存，但**吃检索面**：长尾越多，`search_tools` 越容易把一个
     * "看起来像"的工具排到前面，模型就会选错。
     */
    private val maxLongTail: Int = Contract.Tools.LONG_TAIL_LIMIT,
    /**
     * 每次检索最多披露几个 —— 默认 [Contract.Tools.DISCLOSE_LIMIT]（6）。
     *
     * 披露 = 把该工具的参数表写进历史尾部（可变区）。一次披露太多会把 C 区撑爆
     * （契约 §3.2 的 `prompt_n` 增量目标只有 150）。
     */
    val discloseLimit: Int = Contract.Tools.DISCLOSE_LIMIT,
) {

    init {
        // 越限就**构造即失败** —— 让它成为一个启动期错误，而不是运行期静默退化。
        // 静默退化的后果是命中率缓慢下滑，几周后才发现（那正是本清单存在的理由）。
        require(resident.size <= maxFrozen) {
            "常驻工具 ${resident.size} 个，超过上限 maxFrozen=$maxFrozen" +
                "（Contract.Tools.FROZEN_LIMIT = ${Contract.Tools.FROZEN_LIMIT}）。" +
                "请把多出来的移到 longTail 走 search_tools：" +
                resident.map { it.name }
        }
        require(longTail.size <= maxLongTail) {
            "长尾工具 ${longTail.size} 个，超过上限 maxLongTail=$maxLongTail" +
                "（Contract.Tools.LONG_TAIL_LIMIT = ${Contract.Tools.LONG_TAIL_LIMIT}）。" +
                "工具太多会让模型选错：" + longTail.map { it.name }
        }
        require(discloseLimit >= 1) {
            "discloseLimit 必须 ≥ 1（否则 search_tools 永远披露不出东西），收到 $discloseLimit"
        }
        val dup = (resident + longTail).groupBy { it.name }.filterValues { it.size > 1 }.keys
        require(dup.isEmpty()) { "工具名重复：$dup" }
    }

    /** 全部工具（常驻在前，按名字典序保证确定性） */
    val all: List<ToolSpec> get() = resident + longTail

    fun byName(name: String): ToolSpec? = all.firstOrNull { it.name == name }

    /**
     * 检索长尾工具。
     *
     * 排序**必须**确定（得分降序 → 名字升序）：不确定的顺序会让冻结区/语法
     * 内容随机的抖动，那正是 `02-契约规范.md` §1.1 禁止的事。
     *
     * @return 至多 [limit] 个；无命中就是空列表 —— **不返回"最接近的几个"**。
     *   硬凑结果会诱导模型去用一个不该用的工具（比"没找到"更糟）。
     *
     *   默认值取本注册表的 [discloseLimit]（本地 3 = 旧行为；云端按档放宽）。
     */
    fun search(query: String, limit: Int = discloseLimit): List<ToolSpec> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return emptyList()
        val terms = q.split(TERM_SPLIT).filter { it.isNotBlank() }
        if (terms.isEmpty()) return emptyList()

        return longTail
            .map { it to score(it, q, terms) }
            .filter { it.second > 0 }
            .sortedWith(compareByDescending<Pair<ToolSpec, Int>> { it.second }.thenBy { it.first.name })
            .take(limit)
            .map { it.first }
    }

    /**
     * grammar 要枚举的工具名集合 —— 常驻 + 已披露。
     *
     * 结果**必须**排序（`02-契约规范.md` §1.2：工具必须按名字典序排列），
     * 否则同一状态会生成不同 grammar ⇒ 可复现性丧失。
     */
    fun namesFor(disclosed: Set<String> = emptySet()): List<String> =
        (resident.map { it.name } + longTail.map { it.name }.filter { it in disclosed }).sorted()

    private fun score(spec: ToolSpec, lowerQuery: String, terms: List<String>): Int {
        val hay = buildString {
            append(spec.name.lowercase()).append(' ')
            append(spec.description.lowercase()).append(' ')
            spec.parameters.forEach { append(it.name.lowercase()).append(' ') }
            groups[spec.name]?.let { g ->
                append(g.label.lowercase()).append(' ')
                g.keywords.forEach { append(it.lowercase()).append(' ') }
            }
        }
        // 整个查询串直接命中（中文常见：没有空格分隔，切词切不开）
        var s = if (hay.contains(lowerQuery)) 2 else 0
        for (t in terms) if (hay.contains(t)) s++
        return s
    }

    private companion object {
        /** 中英文都切：空格 / 常见标点 */
        val TERM_SPLIT = Regex("""[\s,，、;；/|+]+""")
    }
}
