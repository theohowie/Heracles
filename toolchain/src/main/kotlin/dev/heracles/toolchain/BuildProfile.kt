package dev.heracles.toolchain

/**
 * **构建剖面** —— 把"构建一个 APK"从**硬编码管线**变成**一份数据**（P2-2，2026-10-18）。
 *
 * ## 为什么要有它
 *
 * 在此之前，"什么算 Android 项目 / 有哪几步 / 产物叫什么"全部散在
 * [AndroidBuildEngine] 的代码里。想加一个变体（release / 不同 minSdk / 不同产物名）
 * 或第二个平台，就得改引擎 —— 而引擎是**已验证资产**（真机闭环 + 57 条测试），
 * 每改一次都在动地基。
 *
 * ⇒ 把这三类事实收拢成 [BuildProfile]，引擎**按数据跑**：步骤名、探测判据、默认产物名
 * 都从 profile 取一次；将来第二份 profile 只是**多一份数据**，不是多一条分支。
 *
 * ## 本轮的范围（刻意收窄）
 *
 * · **只有内置 Android 一份**，代码常量（[BuildProfiles.ANDROID]），**不做 JSON 外部加载**
 *   —— 那要引入 schema、校验、失败语义与版本兼容，是另一批工作。
 * · **零行为变化**：字段只放**已经在代码里的事实**，步骤名逐字节不变
 *   （它们会进工具结果与 UI，改名等于改产品文案）。
 * · **不加"未来会用到"的字段**：schema 一旦发布就是负债（YAGNI）。
 *
 * ## 字段与理由
 *
 * | 字段 | 来源（现有代码里的事实） |
 * |---|---|
 * | [id] / [displayName] | 新加（标识与人可读名；`id` 未来做 profile 选择用） |
 * | [probe] | `AndroidProjectScaffold.isAndroidProject`：**只看清单文件是否存在** |
 * | [buildScriptName] | `AndroidProjectScaffold.writeBuildScript`：每次构建重写的脚本名 |
 * | [steps] | 引擎 `record(...)` 的四处步骤名与顺序（含哪几步是进程内） |
 * | [artifact] | 引擎 `build(outApk = "app-debug.apk")` 的默认值 |
 *
 * @property probe 探测规则 —— **不许发明新规则**：现有判据只有"清单文件存在"。
 * @property buildScriptName 构建脚本文件名（相对项目根）；引擎注入命令与 scaffold 写盘共用它。
 * @property steps 步骤序列（顺序即执行顺序）；名字进工具结果与 UI，**不许改**。
 * @property artifact 产物约定（默认产物名）。
 */
data class BuildProfile(
    val id: String,
    val displayName: String,
    val probe: Probe,
    val buildScriptName: String,
    val steps: List<Step>,
    val artifact: Artifact,
) {

    /**
     * 探测规则。
     *
     * @property manifestFile 项目根下必须存在的清单文件（相对项目根）。
     *   现有代码的**唯一**判据（`isAndroidProject`），本轮不扩展成"还要有 build_apk.sh"
     *   —— 那会改变行为（空目录会被判成"不是 Android 项目"，而今天它会被 scaffold 补上）。
     */
    data class Probe(val manifestFile: String)

    /**
     * 管线的一步。
     *
     * @property id 稳定标识 —— 引擎按 id 取名字（**数据是唯一真相**，引擎不自己写文案）。
     * @property title 步骤名主体：**进工具结果与 UI，不许改**（改名 = 改产品文案）。
     * @property fixedDetail 固定后缀（静态步骤）；`null` = 细节由引擎运行时拼（动态步骤，
     *   例如"插入 classes.dex（12 字节）"里的字节数）。
     * @property inProcess 是否由**进程内**代码完成（进 `BuildOutcome.steps`，UI/诊断用）。
     */
    data class Step(
        val id: Id,
        val title: String,
        val fixedDetail: String? = null,
        val inProcess: Boolean = false,
    ) {
        /**
         * 步骤的稳定 id —— 引擎用它从 profile 取名字。
         *
         * 名字（`PREPARE` 等）对应 `build_apk.sh` 的两个模式 + 引擎补的两步；
         * **不是**脚本参数本身（参数名仍是 `prepare` / `package`，与步骤 title 是两件事）。
         */
        enum class Id { PREPARE, INSERT_DEX, ALIGN, PACKAGE }

        /**
         * 渲染成"进工具结果的那一行"。
         *
         * 静态步骤（[fixedDetail] 非空）忽略 [dynamicDetail]；动态步骤用它拼细节。
         * `render()` 无参时返回静态全名 —— 测试用它逐字节钉住会不会被改文案。
         */
        fun render(dynamicDetail: String = ""): String = title + (fixedDetail ?: dynamicDetail)
    }

    /**
     * 产物约定。
     *
     * @property defaultName 默认产物名（相对项目目录）。今天唯一的事实是 `app-debug.apk`；
     *   ⚠️ `agent` 侧的 `build_apk` 工具也自带同一个默认值（本轮不碰 `agent`），
     *   两处统一是笔欠账（见 F9a 报告）。
     */
    data class Artifact(val defaultName: String)

    /** 按 id 取一步；缺失是**装配错误**（数据与引擎不一致），当场抛而不是静默跳过。 */
    fun step(id: Step.Id): Step =
        steps.firstOrNull { it.id == id }
            ?: throw IllegalArgumentException("profile「$id」缺少步骤 ${id.name}：${steps.map { it.id }}")
}

/**
 * **内置构建剖面**（本轮只有 Android 一份）。
 *
 * ## 为什么常量放在 `:toolchain` 而不是 `:core` 的 Contract
 *
 * 这些是**构建领域的数据**（步骤名、脚本名），不是跨模块的阈值/契约数字；
 * `Contract` 管的是"魔法数字与全局阈值"。放这里也让将来"第二份 profile 进 `:toolchain`"
 * 不牵扯 `:core`。
 *
 * ⚠️ **不做 JSON 外部加载**（本轮）：那要 schema/校验/失败语义，留到下一批；
 * 现在改 profile = 改这份常量（仍是"一份数据"，只是编译期）。
 */
object BuildProfiles {

    /**
     * Android 清单文件名 —— **唯一来源**。
     *
     * `AndroidProjectScaffold`（写骨架/判定项目）与 [ANDROID] 的探测规则都引用它，
     * 避免同一个字符串两处各写一份。
     */
    const val ANDROID_MANIFEST: String = "AndroidManifest.xml"

    /**
     * 构建脚本文件名 —— **唯一来源**。
     *
     * 由 `AndroidProjectScaffold` 每次构建重写、由引擎拼进 shell 命令（`sh <script> prepare …`）。
     */
    const val BUILD_SCRIPT: String = "build_apk.sh"

    /**
     * Android 剖面 —— `aapt2 → javac → d8 → 插 dex（进程内）→ 对齐（进程内）→ 签名`。
     *
     * 步骤顺序与名字**逐字节来自**改造前的引擎：
     * 1. `prepare（aapt2 compile → link → javac → d8）`
     * 2. `插入 classes.dex（…字节）` —— 设备没有 `zip`，脚本 `exit 10` 交回，引擎进程内插
     * 3. `进程内对齐（4 字节；…）` —— Android 没有 `zipalign`（ADR-026/027），脚本 `exit 11` 交回
     * 4. `package（对齐 → apksigner）`
     */
    val ANDROID: BuildProfile = BuildProfile(
        id = "android",
        displayName = "Android APK（aapt2 → javac → d8 → 进程内对齐 → apksigner）",
        probe = BuildProfile.Probe(manifestFile = ANDROID_MANIFEST),
        buildScriptName = BUILD_SCRIPT,
        steps = listOf(
            BuildProfile.Step(
                id = BuildProfile.Step.Id.PREPARE,
                title = "prepare",
                fixedDetail = "（aapt2 compile → link → javac → d8）",
            ),
            BuildProfile.Step(
                id = BuildProfile.Step.Id.INSERT_DEX,
                title = "插入 classes.dex",
                inProcess = true,
            ),
            BuildProfile.Step(
                id = BuildProfile.Step.Id.ALIGN,
                title = "进程内对齐",
                inProcess = true,
            ),
            BuildProfile.Step(
                id = BuildProfile.Step.Id.PACKAGE,
                title = "package",
                fixedDetail = "（对齐 → apksigner）",
            ),
        ),
        artifact = BuildProfile.Artifact(defaultName = "app-debug.apk"),
    )

    /**
     * Android **release 形态的剖面**（F9b，2026-10-18）—— **只做"换 profile 不崩"的证明**。
     *
     * ## ⚠️ 它不是 release 支持，别对外这么讲
     *
     * 现在 release 与 debug 在**流水线步骤上完全相同**：都走
     * `prepare → 插 dex → 对齐 → 签名`，只有**默认产物名**不同（`app-release.apk`）。
     * release 真正需要的东西 —— **正式签名密钥、混淆/R8、minSdk 变体、zip 压缩级别** ——
     * 一个都还没做。
     *
     * ⇒ 刻意**不做**成 `profiles/android-release.json` 对外发布：那会让人以为"release 已支持"
     * （数据化最怕的"看起来支持"）。等真做 release 语义时，这里升格为可外部配置的变体。
     *
     * 存在的价值就一条：**证明引擎按数据跑** —— 换一份 profile，产物名/展示名跟着变，
     * 而引擎代码不用改（`BuildProfileTest` 用它钉住）。
     */
    val ANDROID_RELEASE: BuildProfile = ANDROID.copy(
        id = "android-release",
        displayName = "Android APK · release（当前与 debug 同一条流水线，仅产物名不同；release 语义未实现）",
        artifact = BuildProfile.Artifact(defaultName = "app-release.apk"),
    )
}
