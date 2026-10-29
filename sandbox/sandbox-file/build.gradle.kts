// sandbox-file —— 零宽文件通道（移植自 baicodex）
//
// 移植来源：baicodex (mubai0122/baicodex @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95)
//   - 原 b/ai/exec/FileOps.kt（22627 B）中的路径穿透 / data 目录直读逻辑
//
// ★ 关键设计：`PathSemantics.kt` 显式区分「宿主视角」与「沙箱视角」的路径语义。
//   taixu 的 PRoot `-b` 绑定会把沙箱内路径映射到宿主路径，baicodex 的零宽通道
//   则直接以宿主路径访问；两者叠加时同一个字符串可能指向不同文件 ——
//   本模块用类型把它钉死，禁止混用。
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.heracles.sandbox.file"
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
    implementation(project(":sandbox-runtime"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit)
}
