// sandbox-app —— **开发期验证壳**（com.android.library，不是产品）
// ============================================================================
// ⚠️ 这不是产品的一部分
// ============================================================================
// Heracles 是**一个 APK**。沙箱是内联在 Heracles APK 里的 Android Library
// （sandbox-api / runtime / channel / file 四个模块）。
//
// 本模块 `sandbox-app` 只是开发期用来验证沙箱自身是否可用的**壳**：
//
//   - 它是 **com.android.library**，不是 application ⇒ 不产生 applicationId、
//     不可安装、不出现在桌面、不进 Heracles 的最终 APK；
//   - 它**没有 launcher intent-filter**（见 AndroidManifest.xml）；
//   - 验证方式：挂 androidTest（见 src/androidTest/），
//     临时装一个测试 APK 跑用例，跑完卸载 —— 不是给用户装的东西。
//
// 之前这个模块被写成 `com.android.application` 并带桌面图标，
// 结果在测试机上多出一个 `com.heracles.sandbox.demo` 的 App —— 那是偏移，
// 已纠正（2026-10-28）。
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.heracles.sandbox.demo"
    compileSdk = 36

    defaultConfig {
        // ★ 没有 applicationId：library 模块不产生安装身份。
        minSdk = 29
        // 验证壳需要在设备上跑，所以声明 targetSdk 便于 AGP 做兼容检查
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // ========================================================================
    // ★ 关键：必须把 native 库**解压**到 nativeLibraryDir
    // ========================================================================
    // 为什么不能省（真机踩过）：
    //   AGP 对 targetSdk>=23 的默认策略是 `extractNativeLibs=false` ——
    //   .so 以「未压缩」形式留在 APK 里，由 System.loadLibrary 直接 mmap 加载，
    //   **不会解压到 nativeLibraryDir**。
    //
    //   但沙箱需要 **exec** PRoot：Android 10+ 的 W^X 只允许从
    //   `nativeLibraryDir` 执行程序，而那个目录只有在解压后才有文件。
    //   没解压时表现为：`PRoot 二进制不可用（.../lib/arm64/libproot.so）`。
    //
    //   `useLegacyPackaging = true` 强制解压（对应 manifest 的
    //   `android:extractNativeLibs="true"`，两者要一致）。
    //   代价：APK 变大一点（未压缩体积），但换到「能 exec」。
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // 只带 arm64-v8a（与 runtime 一致）
            excludes += listOf("**/armeabi-v7a/*.so", "**/x86/*.so", "**/x86_64/*.so")
        }
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

dependencies {
    implementation(project(":sandbox-api"))
    implementation(project(":sandbox-runtime"))
    implementation(project(":sandbox-channel"))
    implementation(project(":sandbox-file"))

    implementation(libs.androidx.core.ktx)
    // 验证壳里保留了 MainActivity（ComponentActivity）：它**不是** launcher，
    // 只是给宿主/调试器按需启动的参考 UI，所以仍需要 activity 依赖。
    implementation(libs.androidx.activity)
    implementation(libs.kotlinx.coroutines.android)

    // 设备侧验证用（不参与产品）
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
}
