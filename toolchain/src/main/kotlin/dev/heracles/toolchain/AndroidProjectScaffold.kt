package dev.heracles.toolchain

import dev.heracles.core.contract.Contract
import dev.heracles.workspace.WorkspaceFs

/**
 * **Android 项目脚手架** —— `26-编码层工具链与逆向引擎.md` §9（需求模块 6）。
 *
 * ## 目标：把"从零写一个能编译的项目"变成"填空"
 *
 * `实测-08`：4B 模型写项目骨架的失败率极高，且失败点集中在
 * **记不住的东西**（命名空间、`aapt2` 参数顺序、`android:exported` 这类
 * 新版本必填属性）——而不是表达不出来。
 *
 * ⇒ 骨架由模板固定，模型只需要给三个参数：目录、包名、应用名。
 */
class AndroidProjectScaffold(
    private val fs: WorkspaceFs,
    /**
     * 构建脚本文件名（P2-2，2026-10-18）：由 [BuildProfile.buildScriptName] 传入，
     * **默认值 = 内置 Android 剖面**，既有 `AndroidProjectScaffold(fs)` 调用点零改动。
     */
    private val scriptName: String = BuildProfiles.BUILD_SCRIPT,
) {

    /**
     * 包名合法性 —— **必须校验**。
     *
     * 包名会同时变成：`AndroidManifest.xml` 的 `package=` 属性、
     * `R.java` 的 `package` 声明、以及 Java 源文件所在目录。
     * 三者不一致的典型症状是 `javac` 报 "找不到符号 R" ——
     * 从错误信息完全看不出根因是"包名里有个大写字母"。
     *
     * ⇒ 在**写入之前**就拒绝，并说清规则。
     */
    private val packageRule = Regex("^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$")

    /**
     * 创建一个最小可编译的 Android 项目。
     *
     * @return 写入的**工作区相对路径**列表（顺序即写入顺序）
     * @throws IllegalArgumentException 包名非法时（在写任何文件之前抛出）
     */
    suspend fun create(
        projectDir: String,
        pkg: String = BuildTemplates.DEFAULT_PACKAGE,
        appName: String = "Heracles Hello",
    ): List<String> {
        val dir = projectDir.trim().trimEnd('/')
        require(packageRule.matches(pkg)) {
            "包名非法：$pkg —— 只能用小写字母、数字、下划线，且至少两段（如 com.example.app）；" +
                "不允许大写字母与短横线"
        }
        val pkgDir = pkg.replace('.', '/')
        val name = xmlEscape(appName)

        val files = linkedMapOf(
            "$dir/${BuildProfiles.ANDROID_MANIFEST}" to BuildTemplates.MANIFEST.replace("__PACKAGE__", pkg),
            "$dir/src/$pkgDir/MainActivity.java" to
                BuildTemplates.MAIN_ACTIVITY.replace("__PACKAGE__", pkg),
            "$dir/res/values/strings.xml" to
                BuildTemplates.STRINGS_XML.replace("__APP_NAME__", name),
            "$dir/res/layout/activity_main.xml" to BuildTemplates.LAYOUT_XML,
        )

        val written = ArrayList<String>(files.size)
        for ((path, content) in files) {
            fs.writeText(path, content)
            written.add(path)
        }
        written.add(writeBuildScript(dir))
        return written
    }

    /**
     * 写入构建脚本。
     *
     * 每次构建都重写 —— **模板改了要能生效**（否则用户升级后又得手工删脚本）。
     * 代价是用户对脚本的本地修改会被覆盖，所以脚本头部写明
     * "由 Heracles 生成"（见模板注释）。
     */
    suspend fun writeBuildScript(projectDir: String): String {
        val dir = projectDir.trim().trimEnd('/')
        val path = if (dir.isEmpty()) scriptName else "$dir/$scriptName"
        fs.writeText(path, BuildTemplates.script())
        return path
    }

    /** 目录里是否已经有一个 Android 项目（看清单文件）。 */
    suspend fun isAndroidProject(projectDir: String): Boolean {
        val dir = projectDir.trim().trimEnd('/')
        val manifest = if (dir.isEmpty()) {
            BuildProfiles.ANDROID_MANIFEST
        } else {
            "$dir/${BuildProfiles.ANDROID_MANIFEST}"
        }
        return fs.exists(manifest)
    }

    /** 构建脚本的工作区相对路径。 */
    fun buildScriptPath(projectDir: String): String {
        val dir = projectDir.trim().trimEnd('/')
        return if (dir.isEmpty()) scriptName else "$dir/$scriptName"
    }

    /** 构建目录（工作区相对）—— 脚本与引擎共用这个约定。 */
    fun buildDir(projectDir: String): String {
        val dir = projectDir.trim().trimEnd('/')
        val b = Contract.Toolchain.BUILD_DIR
        return if (dir.isEmpty()) b else "$dir/$b"
    }

    private fun xmlEscape(s: String): String = s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&apos;")
}
