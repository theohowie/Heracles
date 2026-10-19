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
    // ★ 不是"顺便引的依赖"：`ModelProvider.generateStream()` 的返回类型是 `Flow`，
    //   它出现在 :core 的【公开 API 签名】里 —— 按 Gradle 的 api/implementation 语义，
    //   这必须是 api 而非 implementation，否则 :provider-http 的
    //   `override fun generateStream(...): Flow<StreamChunk>` 会因拿不到 Flow 而编译失败。
    //   这正是 AGENTS.md「:core 不得依赖任何本项目模块」之外唯一允许的一类依赖：
    //   纯 JVM、不碰 android.*（门禁 G1 仍全绿：本行不含 android 包）。
    //   见 docs/25-流式工作步骤.md §5.2。
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")

    testImplementation("org.junit.jupiter:junit-jupiter:5.9.3")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
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

// ---------------------------------------------------------------------------
// 门禁 G1：:core 禁止依赖 android.*（07-开发文档.md §2.1）
//
// 理由：本模块里放的是风险最高的代码 —— 前缀冻结、缓存记账、能力预检。
// 它们必须能在 PC 上毫秒级测试。一旦引入 Android 依赖，这条能力就永久丧失，
// 之后每改一行都要推到手机上跑 30 秒才能验证。
// ---------------------------------------------------------------------------
val forbidAndroidImports = tasks.register("forbidAndroidImports") {
    val srcDir = layout.projectDirectory.dir("src")
    val forbidden = Regex("""^\s*import\s+android\.""", RegexOption.MULTILINE)

    doLast {
        val offenders = srcDir.asFileTree
            .matching { include("**/*.kt") }
            .filter { file -> file.readText().contains(forbidden) }
            .toList()

        if (offenders.size > 0) {
            val detail = offenders.joinToString(separator = "\n") { "  - " + it.path }
            throw GradleException(
                ":core 禁止 import android.*（见 docs/07-开发文档.md §2.1）\n" +
                    "违规文件：\n$detail"
            )
        }
    }
}

tasks.named("compileKotlin") { dependsOn(forbidAndroidImports) }
tasks.named("compileTestKotlin") { dependsOn(forbidAndroidImports) }

// ---------------------------------------------------------------------------
// 门禁 G10：字节码版本必须 <= 61（Java 17）
//
// 背景（2026-10-09 实测发现）：
//   Android 的 D8/R8 只接受 class 文件 major version <= 61。
//   本模块曾用 jvmToolchain(21) 编出 major 65，Android 会直接拒绝：
//     "Unsupported class file major version 65"
//
//   :android-probe 之所以没发现，是因为它从【源码】重新编译；
//   而真实 Android 构建是消费这些模块的【jar】。
//
// 这条门禁防的是"改回 JDK 21 然后 Android 构建崩掉"。
// ---------------------------------------------------------------------------
val verifyBytecodeVersion = tasks.register("verifyBytecodeVersion") {
    val classesDir = layout.buildDirectory.dir("classes/kotlin/main")
    // Android 上限：Java 17 = major 61
    val maxMajor = 61

    doLast {
        val dir = classesDir.get().asFile
        if (!dir.exists()) return@doLast

        val offenders = dir.walkTopDown()
            .filter { it.isFile && it.extension == "class" }
            .mapNotNull { f ->
                val b = f.readBytes()
                if (b.size < 8) return@mapNotNull null
                val major = (b[6].toInt() and 0xFF) * 256 + (b[7].toInt() and 0xFF)
                if (major > maxMajor) "${f.name} (major $major)" else null
            }
            .take(10)
            .toList()

        if (offenders.isNotEmpty()) {
            throw GradleException(
                "字节码版本过高，Android 无法加载（上限 major $maxMajor = Java 17）。\n" +
                    "请把 jvmToolchain 设为 17（见 docs/16-Android兼容性验证.md）。\n" +
                    "违规：\n" + offenders.joinToString("\n") { "  - $it" }
            )
        }
    }
}

tasks.named("compileKotlin") { finalizedBy(verifyBytecodeVersion) }
