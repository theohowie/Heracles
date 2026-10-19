plugins {
    kotlin("jvm")
}

group = "dev.heracles"
version = "0.1.0-phase1"

kotlin {
    jvmToolchain(21)
    compilerOptions {
        // ★ Android 兼容：输出 Java 17 字节码（major 61）。
        //   Android 的 D8/R8 只接受到 61；JDK 21 默认产出 65，会被拒绝。
        //   本机只装了 JDK 21，所以用 21 编译、target 降到 17。
        //   见 docs/16-Android兼容性验证.md 与门禁 G10。
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

// 把 :core 的机制、provider 的后端、workspace 的文件串成完整对话轮次。
// 保持纯 JVM —— 这样整个 agent 循环都能在 PC 上毫秒级回归。
dependencies {
    api(project(":core"))
    implementation(project(":workspace"))
    // 编码层工具（build_apk / apk_* / d8_convert）的后端引擎。
    // 方向是单向的：:toolchain 只依赖 :core 与 :workspace，不认识 :agent ⇒ 无环。
    // 详见 docs/09-决策记录.md ADR-021。
    implementation(project(":toolchain"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    // 解析模型输出 —— 云端没有 GBNF，只能自己解析 JSON（见 AgentOutputParser）
    implementation("com.google.code.gson:gson:2.9.1")

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
