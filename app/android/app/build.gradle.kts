// ★ 2026-11-10：正式版签名要用 Properties / File，Kotlin DSL 脚本里
//   不能写全限定名（实测 `java.util.Properties()` 会报 Unresolved reference 'util'），
//   必须像普通 Kotlin 文件一样先 import。
import java.io.File
import java.util.Properties

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

// ---------------------------------------------------------------------------
// ★ 正式版签名（2026-11-10，用户裁定：「后续全部用正式版的」）
//
// ## 为什么以前是 debug 签名
//
// 本文件原来这里是 Flutter 模板留下的 TODO —— `release` 构建套的是
// `signingConfigs.getByName("debug")`。也就是说 **0.4.x 一直到 0.5.1 的发布包
// 全是 Android Debug 证书**（`apksigner verify --print-certs` 实测
// `CN=Android Debug`），只是能装、能跑，**不是正式签名**。用户 2026-11-10 要求
// 改成正式版，故有此段。
//
// ## 凭据从哪来
//
// `app/android/key.properties`（**已 gitignore，永不入库**）：
// ```properties
// storeFile=/绝对路径/heracles-release.jks
// storePassword=…
// keyAlias=heracles
// keyPassword=…
// ```
// 密钥本体在仓库外的私有目录（本机：`.dshwork/staging/.secrets/`）。
//
// ## 没有凭据时会怎样
//
// Debug 构建照常走 Android debug 签名。Release 构建则**硬失败**，绝不回退
// debug —— 否则很容易把「看起来成功」的 debug 证书包再次误发给用户。
// 完整源码 checkout 如果没有本机 key.properties，可以照常 `flutter build apk --debug`；
// release 必须先从受控私密备份恢复正式密钥。
// ---------------------------------------------------------------------------
val heraclesKeyPropsFile = rootProject.file("key.properties")
val heraclesHasReleaseKey = heraclesKeyPropsFile.exists()
val heraclesReleaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
} ||
    gradle.startParameter.taskNames.isEmpty()
if (heraclesReleaseRequested && !heraclesHasReleaseKey) {
    throw GradleException(
        "正式 release 构建被拒绝：缺少 app/android/key.properties。" +
            "恢复仓库外 `.dshwork/staging/.secrets/heracles-release.jks` 与 properties 后再构建。"
    )
}
val heraclesKeyProps = Properties().apply {
    if (heraclesHasReleaseKey) {
        heraclesKeyPropsFile.inputStream().use { load(it) }
    }
}
/** 把 properties 里的相对路径按 `rootProject`（= app/android）解析。 */
fun heraclesStoreFile(): File {
    val raw = heraclesKeyProps.getProperty("storeFile") ?: ""
    val f = File(raw)
    return if (f.isAbsolute) f else rootProject.file(raw)
}

android {
    namespace = "com.theohowie.heracles"

    // 沙箱自检入口需要 BuildConfig.DEBUG 判断（AGP 8+ 默认关闭 buildConfig）
    buildFeatures {
        buildConfig = true
    }

    // ========================================================================
    // ★ 沙箱需要把 native 库**解压**到 nativeLibraryDir
    // ========================================================================
    // Android 10+ 的 W^X 只允许从 nativeLibraryDir exec 程序，而沙箱要 exec
    // `libproot.so`。AGP 对 targetSdk>=23 默认 `extractNativeLibs=false`
    // —— .so 留在 APK 里由 System.loadLibrary 直接 mmap，**不会解压**，
    // 于是 nativeLibraryDir 是空的，沙箱会报「PRoot 二进制不可用」。
    //
    // 代价：这些 .so 在 APK 里改为未压缩存储（体积略增）。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

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

        // ★ ABI 白名单：只打 arm64-v8a（2026-10-30 用户要求，说明见 gradle.properties）。
        //
        // 原因：Flutter 引擎只为 arm64 提供 libflutter.so / libapp.so；插件 AAR
        // （onnxruntime / sherpa-onnx / 沙箱 proot）却把 armeabi-v7a、x86_64 的
        // 原生库也带进来 —— 那两个 ABI 上 App 根本起不来（缺引擎），纯属白占体积
        // （实测 0.3.2：三 ABI 67.5 MB → 仅 arm64 见 apk-info 实测值）。
        //
        // ⚠️ 单靠这一行不生效：Flutter 插件会在 afterEvaluate 里 clear() 掉它，
        //    必须同时有 android/gradle.properties 的 `disable-abi-filtering=true`。
        // ⚠️ 不要改用 `--split-per-abi`：它会把 versionCode 改写成 2000+N，
        //    与 pubspec 的 +N 不一致，后续普通包会变成"降级安装"被拒。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // ⚠️ 顺序有意义：`signingConfigs` 必须在 `buildTypes` **之前**声明，
    //    否则 `signingConfigs.getByName("release")` 在配置期拿不到
    //    （实测报 `SigningConfig with name 'release' not found`）。
    signingConfigs {
        if (heraclesHasReleaseKey) {
            create("release") {
                storeFile = heraclesStoreFile()
                storePassword = heraclesKeyProps.getProperty("storePassword")
                keyAlias = heraclesKeyProps.getProperty("keyAlias")
                keyPassword = heraclesKeyProps.getProperty("keyPassword")
                // v1/v2/v3 都开：v3 便于后续换密钥轮换，v1 兼容极老设备。
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // ★ 用户裁定：release 必须始终用正式密钥；禁止静默回退 debug。
            signingConfig = if (heraclesHasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                // Debug / test tasks may configure all variants eagerly; the top-level
                // guard above already hard-fails any requested release task.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// ---------------------------------------------------------------------------
// ★ 依赖（2026-10-22 起**不含**任何本项目后端模块）
//
// 原来这里有 5 条 `implementation(project(":core"))` 等，指向已被用户删除的
// 纯 JVM 后端模块。后端改用 Dart 重写（`backend/`），Kotlin 侧只剩**设备能力**：
// 文件 IO / shell / 健康读数 / 选择器 / 构建通知 —— 全部在本模块内实现，
// 不依赖任何 `dev.heracles.*` 符号。
// ---------------------------------------------------------------------------
dependencies {
    // 取消 / 超时 / 并发读流 —— 设备通道的运行面需要它
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

    // ========================================================================
    // ★ 内置沙箱（Heracles-taixu-sandbox）—— 内联，不是第二个 App
    // ========================================================================
    // 用**预编译 AAR** 而不是 include 模块，原因：
    //   沙箱是独立 Gradle 工程，用 AGP 8.13 / Kotlin 2.2.20；
    //   本工程是 AGP 9.0.1 / Kotlin 2.3.20（built-in）。
    //   直接 include 会让两套 AGP 在同一构建里打架。
    //   AAR 解耦后：沙箱仍可 `cd sandbox && ./gradlew build` 独立构建，
    //   本工程只依赖产物。**改了沙箱要重新出 AAR**（见 sandbox/README）。
    implementation(files("libs/sandbox-api-release.aar"))
    implementation(files("libs/sandbox-runtime-release.aar"))
    implementation(files("libs/sandbox-channel-release.aar"))
    implementation(files("libs/sandbox-file-release.aar"))

    // ★ 2026-11-02（T0 SAF 黑屏）：JVM 单测。
    //   `PickRequestRegistry` 刻意做成**纯 Kotlin（不 import 任何 android.*）**，
    //   就是为了让它能在 PC 上直接跑单测 —— "Activity 重建后结果还能不能配对"
    //   这种事，靠真机试是碰运气，靠单测是确定性的。
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
