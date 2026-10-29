// sandbox-api —— 唯一的对外契约模块
//
// 只包含 AIDL 接口与 Kotlin 数据模型/枚举/异常，**不含任何实现**。
// 任何宿主项目（Heracles 本体或第三方 Android Agent）只要依赖这个 AAR，
// 就能拿到完整的执行/文件/通道/rootfs 契约。
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.heracles.sandbox.api"
    compileSdk = 36

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")
    }

    buildFeatures {
        aidl = true
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
