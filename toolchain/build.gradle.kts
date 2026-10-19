plugins {
    kotlin("jvm")
}

group = "dev.heracles"
version = "0.2.0-phase2"

kotlin {
    jvmToolchain(21)
    compilerOptions {
        // ★ Android 兼容：输出 Java 17 字节码（major 61）。
        //   见 docs/16-Android兼容性验证.md 与门禁 G10。
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

// 纯 JVM 模块（阶段二「编码层」，见 docs/26-编码层工具链与逆向引擎.md）。
//
// 定位：把"设备端工具链"的**领域逻辑**（定位工具链、编排构建流水线、
// 编排逆向闭环）从 Android 宿主里剥离出来，从而：
//   · 可在 PC 上毫秒级测试（用假 ShellRunner，不起真进程）
//   · 不依赖 android.*（门禁 G1 精神）
//
// ★ 只经 :core 的 ShellRunner 接口触达设备 —— 不得自己 new ProcessBuilder。
dependencies {
    api(project(":core"))
    implementation(project(":workspace"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")

    testImplementation("org.junit.jupiter:junit-jupiter:5.9.3")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = true
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
tasks.withType<Test>().configureEach {
    jvmArgs("-Dfile.encoding=UTF-8", "-Dstdout.encoding=UTF-8", "-Dstderr.encoding=UTF-8")
}
