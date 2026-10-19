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

dependencies {
    api(project(":core"))

    // JDK 自带 java.net.http.HttpClient，不引入 OkHttp/Retrofit
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("com.google.code.gson:gson:2.9.1")

    testImplementation("org.junit.jupiter:junit-jupiter:5.9.3")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

// 中文测试名与输出：Windows 默认 GBK，必须显式指定 UTF-8
tasks.withType<Test>().configureEach {
    jvmArgs("-Dfile.encoding=UTF-8", "-Dstdout.encoding=UTF-8", "-Dstderr.encoding=UTF-8")
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = true
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
