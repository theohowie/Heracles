pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        // 国内镜像优先（本项目实测 21 MB/s）
        maven("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false

    // ★ 主工程的纯 JVM 模块用这个插件。
    //   版本必须与 kotlin.android 一致，否则两个 Kotlin 编译器会在同一
    //   构建里打架（Gradle 只允许 classpath 上有一个 Kotlin plugin 版本）。
    id("org.jetbrains.kotlin.jvm") version "2.3.20" apply false
}

include(":app")

// ---------------------------------------------------------------------------
// ★ 把主工程的纯 JVM 模块纳入 Flutter 的 Android 构建
//
// 背景（`15-前端选型与通道协议.md` §5）：Flutter 的 `app/android/` 是
// **独立的 Gradle 构建**，与仓库根的 `settings.gradle.kts` 互不相识。
// 要让 Flutter 调用 Kotlin 核心，必须把它们接进来。
//
// 路径：`app/android/../../core` = 仓库根的 `core/`
//
// 只纳入发行版需要的四个模块。**刻意不纳入**：
//   :cli           —— 开发脚手架，不进 APK
//   :android-probe —— 兼容性验证模块，用 AGP 8.7.3，与本构建的 9.0.1 冲突
// ---------------------------------------------------------------------------
include(":core")
project(":core").projectDir = file("../../core")

include(":provider-http")
project(":provider-http").projectDir = file("../../provider-http")

include(":workspace")
project(":workspace").projectDir = file("../../workspace")

include(":agent")
project(":agent").projectDir = file("../../agent")

// :toolchain —— 编码层（构建引擎 / APK 逆向 / 工具链定位）。
// 纯 JVM、不 import android.*，因此可以安全地编进 APK。
// 它只被 :agent 的编码层工具使用（见 docs/09-决策记录.md ADR-021）。
include(":toolchain")
project(":toolchain").projectDir = file("../../toolchain")

// ---------------------------------------------------------------------------
// ★ 强制所有 Android 子项目 compile against ≥ 36
//
// 背景（2026-10-10 实测）：
//   `file_picker` 的 android/build.gradle 写死了 `compileSdk 34`，
//   而它的传递依赖 `flutter_plugin_android_lifecycle` 要求
//   **所有消费者**都 compile against ≥ 36。冲突直接让构建失败：
//
//     :file_picker is currently compiled against android-34
//     :flutter_plugin_android_lifecycle requires ... version 36 or later
//
//   这是**插件配置过时**（file_picker 9.2.3 仍未修），不是我们的代码问题。
//
// ⚠️ 为什么必须在 settings 里用 beforeProject：
//   app/android/build.gradle.kts 里的 `subprojects { evaluationDependsOn(":app") }`
//   会让所有子项目**立即求值**，此后任何 afterEvaluate / plugins.withId
//   都太晚了（实测两者都不生效）。
//   `gradle.beforeProject` 在**每个项目求值之前**触发，是唯一可靠的时机。
// ---------------------------------------------------------------------------
gradle.beforeProject {
    if (this.path == ":") return@beforeProject
    plugins.withId("com.android.library") {
        extensions.findByName("android")?.let { ext ->
            runCatching {
                ext.javaClass
                    .getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(ext, 36)
                logger.lifecycle("[heracles] ${project.name}: compileSdk -> 36")
            }
        }
    }
}
