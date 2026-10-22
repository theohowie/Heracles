package dev.heracles.cloud

/**
 * **新旧管线切换** —— `CloudAgentPipeline` vs 旧 `AgentLoop`（2026-10-21）。
 *
 * ## ★ 默认值已于 2026-10-21 翻转：**新管线是默认**
 *
 * | 阶段 | 默认 | 旧管线的角色 |
 * |---|---|---|
 * | 隔离重建期（当天早些时候） | 旧 `AgentLoop` | 主路径 |
 * | **现在（真 Key 验证通过后）** | **`CloudAgentPipeline`** | **fallback（显式退回才用）** |
 *
 * ### 为什么现在可以翻
 *
 * 真 Key 真机验证（`deepseek-v4.1-flash-1017`，tokenrhythm 中转）已跑通：
 * - 22 轮原生工具调用、**并行调用 `calls=2/3`**、**零 400**、**零解析失败**
 * - `read_file` / `write_file` / `update_plan` / `ask_user` 全部真实执行
 * - 同一台设备、同一模型的**旧管线**同期出现「连续 2 轮没有按协议输出」熔断
 *
 * 完整证据见 `.audit/REAL-KEY-VERIFICATION.md`。
 *
 * ### 为什么**保留**旧管线而不是删
 *
 * 1. **它是唯一可回退路径** —— 新管线仍有未验证面（Anthropic / Responses 两轨）
 * 2. 781 条既有测试大量断言钉住旧行为；一次性删会让"改锚点"与"暴露真问题"混在一起
 * 3. 旧路径里有些**对的**东西（配对回填、审批、命令守卫、热熔断）—— 新管线复用它，不是重写
 *
 * ⇒ 旧 `AgentLoop` 标 `@Deprecated`，**代码保留、默认不跑**。
 *
 * ## 切换方式
 *
 * | 手段 | 效果 |
 * |---|---|
 * | 不设任何东西 | **走新管线**（默认） |
 * | `HERACLES_CLOUD_PIPELINE=0`（或 `false`/`off`/`legacy`） | **退回旧管线** |
 * | `CloudPipelineFlags.override = false` | 同上（代码/测试用） |
 * | `adb shell am start … --ez heracles_cloud_pipeline false` | Android 真机退回（`System.getenv` 在 App 里读不到，见下） |
 *
 * ⚠️ **Android 上 `System.getenv` 读不到**（App 不继承 shell 环境；旧代码
 * `AgentLoop.kt:1421` 已踩过这个坑）⇒ 真机调试必须用 intent extra 或 [override]。
 */
object CloudPipelineFlags {

    /**
     * 环境变量名 —— **设成 `0` / `false` / `off` / `legacy` 才退回旧管线**。
     *
     * 语义已翻转：这个变量的作用从"启用新的"变成"退回旧的"。
     * 沿用一个名字是为了让旧的调试脚本不会突然反向生效（设 `=1` 仍然是"要新管线"，
     * 与旧语义一致，不会让人误操作）。
     */
    const val ENV_VAR = "HERACLES_CLOUD_PIPELINE"

    /** 是否**显式要求退回**旧管线。不设 = 不回退（用新管线）。 */
    val legacyRequested: Boolean
        get() = System.getenv(ENV_VAR)?.trim()?.lowercase() in setOf("0", "false", "off", "legacy")

    /**
     * **显式覆盖**（测试 / 装配层注入用）。
     *
     * `null` = 跟随默认（新管线）；`false` = 强制旧管线；`true` = 强制新管线。
     *
     * ⚠️ 只应由装配层在**同一个地方**设置一次。生产代码不要散落着改它。
     * 这是 **Android 上唯一可靠的开关**（见类 KDoc 关于 `System.getenv` 的说明）。
     */
    @Volatile
    var override: Boolean? = null

    /** 最终判定：override 优先，其次环境变量，**默认新管线**。 */
    fun isCloudPipeline(): Boolean = override ?: !legacyRequested

    /**
     * **wire 未被真 Key 验证的 provider 轨** —— 这些自动退回旧管线。
     *
     * ## 为什么必须有这道闸（2026-10-21 自查发现的风险）
     *
     * 本次重构改了**共享的** `NativeToolSchema.canonicalBody`：它现在优先用
     * `ToolSpec.jsonSchema`（**类型化** JSON Schema）而不是 `PrefixBuilder.canonicalToolJson`
     * （旧的**全 string** 形状）。
     *
     * 而 `jsonSchema` **只有新管线**（`CloudPipelineAssembler`）会设置 ⇒ 三条轨的形状变成：
     *
     * | 组合 | 发出的 `tools` 形状 | 真 Key 验证 |
     * |---|---|---|
     * | 新管线 + OpenAI 兼容 | 类型化 Schema | ✅ 已验证（4 轮真机）|
     * | **新管线 + Anthropic** | **类型化 `input_schema`** | ❌ **从未验证** |
     * | **新管线 + Responses** | **类型化扁平 `tools`** | ❌ **从未验证** |
     * | 旧管线 + 任意轨 | 旧的 all-string | ✅ 改动前的出货行为 |
     *
     * ⇒ 如果让这两轨也走新管线，等于**拿未验证的 wire 赌用户**（`AGENTS.md` 的硬规矩：
     * 「wire 变更必须真 Key 验证过才算完成」）。所以：**这两轨自动退回旧管线**，
     * 直到它们被真 Key 验证。
     *
     * ## 什么时候可以删掉这个集合
     *
     * 拿到对应 Key、真机跑通一次（`tools` 形状不被拒 + 原生 `tool_calls` 正常回）即可删除。
     * 删掉前**不要**放宽 —— 这是"未验证"而不是"已知有问题"。
     */
    val UNVERIFIED_BACKENDS: Set<String> = setOf("anthropic", "responses")

    /**
     * 按 **backend 名**判定是否走新管线。
     *
     * 装配层（`AgentBridge`）必须用这个而不是直接调 [isCloudPipeline] ——
     * 否则两道闸（总开关 + 未验证轨）会分裂成两个地方各判一次。
     *
     * @param backend Dart 侧传来的后端名：`cloud` / `anthropic` / `responses`
     */
    fun isCloudPipelineForBackend(backend: String): Boolean =
        isCloudPipeline() && backend !in UNVERIFIED_BACKENDS

    /** 桌面 JVM/CLI 用的属性名（`-Dheracles.cloudpipeline=0` 退回旧管线）。 */
    const val PROP_VAR = "heracles.cloudpipeline"

    /**
     * 从 System Property 读（桌面 JVM/CLI 补充入口）。
     *
     * Android 上 `System.getProperty` 不接 `setprop`（那是 Java 属性，不是 Android 属性）
     * ⇒ 真机上恒为 `null`，**如实标注，不假装可用**。
     */
    fun fromSystemProperty(): Boolean? {
        val v = System.getProperty(PROP_VAR)?.trim()?.lowercase() ?: return null
        return when (v) {
            "0", "false", "off", "legacy" -> false
            "1", "true", "yes", "on" -> true
            else -> null
        }
    }
}
