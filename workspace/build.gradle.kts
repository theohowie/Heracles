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

// 纯 JVM：只依赖 JDK 与 :core。**不允许** Android / 网络库。
// 文件读写是具体副作用，但完全可在 PC 上测试（用临时目录）。
dependencies {
    api(project(":core"))
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
