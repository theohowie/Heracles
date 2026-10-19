plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    //
    // ⚠️ 刻意**不**显式声明 `org.jetbrains.kotlin.android`：
    // Flutter 3.44 已迁移到 **Built-in Kotlin**，再手动应用会触发
    //   "applies the Kotlin Gradle Plugin, which will cause build failures"
    // 并且实测会让 `io.flutter.plugin.common.MethodCall` 变成
    // 未解析引用（classpath 上的 Flutter 类被隔离）。
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// ★ 模块级仓库：必须加 JitPack（2026-10-16，Stellar 支持）
//
// ## 为什么加在这里而不是 settings.gradle.kts
//
// 实测：在 `settings.gradle.kts` 里写 `dependencyResolutionManagement {
// repositories { ... maven("https://jitpack.io") } }` **不生效** ——
// Gradle 只查询了 3 个仓库（dl.google / repo.maven.apache.org /
// storage.flutter-io.cn），Stellar 直接 FAILED。原因：Flutter 的插件
// 工程自己有仓库配置，会覆盖/忽略 settings 级声明。
//
// 模块级 `repositories` 是**确定生效**的位置，故写在这里。
// ---------------------------------------------------------------------------
repositories {
    google()
    mavenCentral()
    maven("https://jitpack.io")
    maven("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
}

android {
    namespace = "com.theohowie.heracles"

    // ★ 显式钉死 37，不跟随 flutter.compileSdkVersion（36）。
    //
    // 原因：file_picker 传递依赖的 `flutter_plugin_android_lifecycle`
    // 要求 compileSdk ≥ 37，而 Flutter 3.44.2 默认给的是 36 ——
    // 跟随默认值会直接构建失败（实测）。
    //
    // compileSdk 只影响"用哪个 API 编译"，不改变最低运行版本，
    // 所以抬高它没有兼容性代价。
    compileSdk = 37

    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.theohowie.heracles"

        // ★ 用户决定（2026-10-09）：最低支持 Android 12（API 31）。
        //   这同时满足 java.nio.file 的 API 26+ 要求（见 16-Android兼容性验证.md）。
        //   刻意不跟随 flutter.minSdkVersion —— 那个值随 Flutter 版本浮动，
        //   而最低支持版本是【产品决策】，必须钉死。
        minSdk = 31

        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// ---------------------------------------------------------------------------
// ★ 依赖主工程的 Kotlin 核心
//
// 这四个模块是**已验证的资产**（66 项测试 + 实测 06/07/08/09/10）。
// Flutter 只做展示与输入，核心逻辑全部留在这里
// （见 `15-前端选型与通道协议.md` §2 的硬约束）。
//
// 它们用 `kotlin("jvm")` 插件，产出 Java 17 字节码 ——
// 能被 Android 直接消费（D8/R8 接受 major ≤ 61）。
// ---------------------------------------------------------------------------
dependencies {
    implementation(project(":core"))
    implementation(project(":provider-http"))
    implementation(project(":workspace"))
    implementation(project(":agent"))
    // 编码层工具的后端（构建引擎 / APK 逆向 / 工具链定位）。
    // 见 docs/09-决策记录.md ADR-021 与 docs/12-模块与文件清单.md。
    implementation(project(":toolchain"))

    // 核心用 kotlinx-coroutines；AgentLoop 是 suspend 函数
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // SAF（Storage Access Framework）文档访问 —— 用于路线 A 的实测对比
    implementation("androidx.documentfile:documentfile:1.0.1")

    // ★ Shizuku（2026-10-16 用户需求「接入 shizuku 获取更高权限」）——
    //   api：binder 交互（ping/权限/执行）；provider：跨进程拿 binder（必须注册）
    //   13.1.5 是稳定版（RikkaApps 官方，Maven Central）
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")

    // ★ Stellar（2026-10-16 用户需求「接入 stellar 获取最高权限」）——
    //   Stellar 是 Shizuku 的**深度定制分支**（roro2239），支持 ADB 或 **Root**
    //   启动，能力比 Shizuku 更强（含 grantRuntimePermission 等被 Shizuku
    //   弃用的 API）。
    //
    //   ⚠️ 坐标不是官方文档写的 `com.github.roro2239:Stellar-API`！
    //      实测（核对 JitPack 的 build.log + 逐个探 HTTP）：
    //      顶层 `Stellar-API-1.0.3.pom` 只是**聚合 POM，没有 aar**
    //      → 用文档的坐标必然 "Could not resolve"。
    //      真实构件在子模块：api / shared / aidl，各带 aar。
    //      所以正确坐标是 `com.github.roro2239.Stellar-API:api:1.0.3`
    //      （Gradle 的 group:artifact:version 里，多模块的 group 是
    //       `com.github.用户名.仓库名`，artifact 是模块名）。
    //
    //   与 Shizuku **可共存**（不同包名 + 不同 Provider Authority）——
    //   本 App 同时注册两者的 Provider，运行时按"谁在跑"选择。
    //
    //   ⚠️ 必须同时加 `provider` 模块！`StellarProvider` 类**只在
    //      provider-1.0.3.aar 里**（实测：api/shared/aidl 三个 aar 都没有它，
    //      只有 provider 模块有 —— 与 Shizuku 的 api/provider 分工一致）。
    //      只加 api 会在 Manifest 合并时报 "StellarProvider not found"。
    implementation("com.github.roro2239.Stellar-API:api:1.0.3")
    implementation("com.github.roro2239.Stellar-API:provider:1.0.3")
}

flutter {
    source = "../.."
}
