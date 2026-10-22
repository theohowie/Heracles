package dev.heracles.core.tool

/**
 * 工具参数。
 *
 * **只允许扁平标量** —— 嵌套对象是小模型填错的头号来源（`02-契约规范.md` §4.2）。
 *
 * 位置说明：本文件原计划在 P2 从 `context/PrefixBuilder.kt` 移出（见
 * `12-模块与文件清单.md`）。但 P1 的 `CapabilityGate` 与 `ToolValidator`
 * 都依赖 `ToolSpec`，若 P1 代码从 `context` 包导入工具模型，
 * 会形成"工具层依赖上下文层"的错误方向。**故提前到 P1。**
 */
data class ToolParam(
    val name: String,
    val type: String,
    val description: String,
    /**
     * **该参数允许空字符串**（2026-10-14 真机 bug 修复）。
     *
     * ## 修的是什么
     *
     * 用户实测：模型对 `list_files` 传 `dir: ""`（列出根目录）——
     * 而 [ToolValidator] 有一条"参数值为空 → 非法"的通用规则，
     * 于是**合法的正确调用被拦下**。更糟的是连锁反应：
     * 模型重试一次还是 `""` → 撞上"重复调用拦截" → **放弃并谎称
     * 任务已完成**（文件根本没写）。
     *
     * ## 为什么用标记而不是删掉那条规则
     *
     * "空值非法"对**大多数**参数是对的（`path` / `content` 为空
     * 说明模型没填对）。只有少数参数的契约**明确要求空值合法**
     * （`list_files.dir` 的文档就写着"根目录传空字符串"）。
     *
     * 所以：默认 `false`（保持严格），契约允许的显式声明 `true` ——
     * **校验器与工具契约必须一致**，不能一个说"传空字符串"、
     * 另一个判"为空非法"。
     */
    val allowEmpty: Boolean = false,

    /**
     * **该参数可以不出现**（2026-10-18，F7a —— ADR-031 原生 function calling 的前置）。
     *
     * ## 它解决的是什么
     *
     * 在此之前 [ToolParam] 只有"允许空串"（[allowEmpty]），没有"允许缺键"：
     * [ToolValidator] 用 `spec.parameters.filter { it.name !in call.args }` 判缺参
     * ⇒ **只要声明出来就是必填键**。模型（尤其云端）少写一个键就撞
     * 「缺少必填参数」，而它本可以走实现的默认值（`docs/27` §2.2 记的
     * `build_apk` 缺 `out_apk` 被 blocked 就是这类摩擦）。
     *
     * ## 与 [allowEmpty] **正交**，不要混为一谈
     *
     * | 字段 | 管什么 | 缺键 | 传空串 |
     * |---|---|---|---|
     * | `optional = true` | 能不能**不出现** | 放行 | 仍由 [allowEmpty] 决定 |
     * | `allowEmpty = true` | 空串算不算非法 | 不涉及 | 放行 |
     *
     * 所以 `optional=true, allowEmpty=false` 的语义是"可以不给；但给了就必须有内容"。
     *
     * ## 三个后果（必须知道）
     *
     * 1. **默认 `false` ⇒ 零回退**：既有工具一个字节都不变（测试
     *    `allRequiredToolJsonUnchanged` 钉住）。
     * 2. **会进 JSON Schema 的 `required`**：`PrefixBuilder.canonicalToolJson` 只把
     *    `optional=false` 的参数列进 `"required":[…]` —— 云端原生 function calling
     *    直接把它当 JSON Schema 发出去，列错就是**教模型多填参数**。
     * 3. **改这个字段 = 改冻结前缀的 hash** ⇒ 首次请求 prefix cache 必然 miss 一次。
     *    这是**预期代价**（ADR-031 已记"前缀缓存风险"），不要为了测试好看改回去。
     *
     * ⚠️ `02-契约规范.md` §4.2 现在写的是"**禁止**可选参数（v1 只用 required）"——
     * 那是提示词/GBNF 时代的规则。本字段落地后那条需要更新（文档由框架负责人改）；
     * 云端原生 `tools` 的 `required` **本来就必须只列真必填**，否则模型会以为
     * `offset` / `out_apk` 之类必须给。
     *
     * ## 什么时候才该标 true
     *
     * 只标那些**"键缺失时实现真的会走默认值"**的参数，且默认值要在参数描述里写明。
     * 缺了会让实现**无所适从**或**猜错目标**的参数（例：`build_apk.project_dir` 缺了
     * 会去构建工作区根、还可能在根上自动搭骨架）**保持必填** —— 必填不等于不能传空串，
     * [allowEmpty] 仍可放行显式的 `""`。
     */
    val optional: Boolean = false,
)

/**
 * 工具定义。
 *
 * **必须**同时满足 `02-契约规范.md` §4.2 的命名规范：
 * `snake_case`、动词开头、描述说明"什么时候用"而非"这是什么"。
 */
data class ToolSpec(
    val name: String,
    val description: String,
    val parameters: List<ToolParam> = emptyList(),

    /**
     * **预渲染的完整 JSON Schema**（`CloudAgentPipeline`，2026-10-21）。
     *
     * ## 为什么需要它（[parameters] 表达不了的东西）
     *
     * [parameters] + [ToolParam.type] 是**文本轨时代的形状**：`type` 只有一个字符串，
     * 全仓 55 个参数因此全是 `"string"`。它无法表达：
     * - `integer` / `boolean`（`max_results`、`replace_all`）
     * - `array of objects`（`update_plan.steps`、`ask_user.questions`）
     * - `enum`（`status` 只能是 pending/active/done）
     *
     * 而云端原生 `tools` 吃的就是**标准 JSON Schema** ——
     * 只要把这份字符串原样当 `parameters` 发出去，模型就能按真实类型填参数。
     *
     * ## 零回退保证（结构性，不是靠调用方自觉）
     *
     * 默认 `null` ⇒ **所有既有 ToolSpec 构造点一个字节都不用改**，
     * 而 Provider 侧的逻辑是"有就用、没有就退回旧渲染"
     * （见 `NativeToolSchema.canonicalBody`）⇒ 旧路径请求体逐字节不变。
     *
     * ## 什么时候该填
     *
     * 只有**声明了真实类型**的工具才填（`CloudToolSchema.cloudToolSpec` 会填）。
     * 手写这个字符串是**错误做法**：键序/转义/`required` 都容易写歪，
     * 而它直接影响请求体与缓存前缀 —— 请走 `renderObjectSchema`。
     */
    val jsonSchema: String? = null,
)
