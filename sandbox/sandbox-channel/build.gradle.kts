// sandbox-channel —— 通道发现与自动选路
//
// 移植来源：
//   - baicodex (mubai0122/baicodex @ fb4bd5f)：三档权限模型的通道发现/选路/风险等级
//   - tianxuan (xiaozhe7772222/tianxuan @ caad400)：无线 ADB 通道与配对状态机
//
// ★ 本模块只产出「决策结果」：当前有哪些通道、前置条件是否满足、风险等级多少。
//   **不含任何 UI 弹窗**，也不含「允许/确认/拒绝」的判断 —— 那是宿主的信任策略。
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.heracles.sandbox.channel"
    compileSdk = 36

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

dependencies {
    api(project(":sandbox-api"))
    // ★ ChannelManager 必须实现 runtime 的 ChannelQuery SPI（任务契约要求），
    //   因此本模块需要 runtime 在**编译期**可见。
    //   依赖方向：channel → runtime → api，与 file → runtime、file → channel 一起
    //   仍然无环（runtime 只依赖 api）。
    //   用 implementation 而非 api：runtime 的 ChannelQuery 不应强迫
    //   本模块的下游也把它带上编译类路径（宿主自己已经直接依赖 runtime）。
    implementation(project(":sandbox-runtime"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)

    // ★ Shizuku 必须 compileOnly：编译期才有 API，运行期靠探测。
    //   若改成 implementation，没装 Shizuku 的设备会在类加载阶段就崩，
    //   普通 App 通道会被连坐。这是硬约束。
    compileOnly(libs.shizuku.api)

    testImplementation(libs.junit)
}
