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
// ★ 本构建**只**含 `:app`（2026-10-22，Dart 重写）
//
// 原来这里还 include 了 5 个纯 JVM 模块：
//   :core / :provider-http / :workspace / :agent / :toolchain
// 它们指向 `app/android/../../core` 等路径。**那些目录已被用户删除**
// （后端改用 Dart 重写，见 `docs/DART-MIGRATION-AUDIT-2026-10-22.md` §2.1），
// 于是 Gradle 在**配置阶段**就失败：
//
//   Configuring project ':workspace' without an existing directory is not allowed
//
// ⇒ 不要从 git 恢复那 5 个目录、不要重新 include。Kotlin 侧现在**只有设备能力**
//   （`heracles/device` 通道：文件 IO / shell / 健康读数 / 选择器 / 构建通知）。
// ---------------------------------------------------------------------------

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
