// sandbox-runtime —— fork 自 taixu runtime/ 的执行面
//
// 负责：PRoot 执行核心、PTY 会话、OCI rootfs 安装、APK 内置 rootfs 解包、
// 进程注册表、工作区管理。**不含** Agent 循环 / UI / 项目模板。
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.heracles.sandbox.runtime"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 29
        consumerProguardFiles("consumer-rules.pro")

        // ★ 只编 arm64-v8a：PTY JNI 与内置 PRoot/loader 都是 AArch64。
        //   32 位设备不支持 —— 这句话必须同时出现在 README 里。
        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=none")
                cppFlags += listOf("-O2")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // PRoot 的 tracee loader 与 PRoot 本体都是**可执行载荷**而不是 JNI 库，
    // 必须保留原始字节（AGP 的 strip 会破坏它们）。
    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libproot-loader.so"
            keepDebugSymbols += "**/libproot.so"
            excludes += listOf("**/armeabi-v7a/*.so", "**/x86/*.so", "**/x86_64/*.so")
        }
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

// ============================================================================
// ★ 构建期强校验：内置运行时缺失就**直接失败**，不允许「编过了但一跑就废」
// ============================================================================
// 背景（这是本工程真实踩过的坑）：
//   PRoot 的四个二进制曾经放在 .gitignore 里，干净 clone 后
//   `./gradlew build` **照样 BUILD SUCCESSFUL** —— 但打出的 APK 里
//   一个 native lib 都没有，装上一点「执行」就报错。
//   这类"假成功"在 CI 里会一路绿灯到用户手上。
//
// 现在的要求：
//   1. 四个 proot 二进制必须在 jniLibs/arm64-v8a/ 下（缺了 → 构建失败）
//   2. 内置 rootfs（assets/rootfs-bundle.bin）必须在（缺了 → 构建失败）
//   3. 二进制必须是 AArch64 ELF（magic 7F 45 4C 46 + e_machine B7 00）
//   4. rootfs 必须是 gzip（magic 1F 8B）且大于阈值
//
// 「内置 rootfs 是主路径」是**架构决策**（本沙箱不依赖服务器/云端）：
//   用户拿到 APK 装上就应该能用，不需要联网、不需要拉 OCI。
//   所以它不再是"可选兜底"，而是必需产物。
val requiredNativeBinaries = listOf(
    "libproot.so" to 100_000L,
    "libproot-loader.so" to 10_000L,
    "libtalloc.so" to 10_000L,
    "libandroid-shmem.so" to 5_000L,
)

tasks.configureEach {
    if (name == "preBuild") {
        doFirst {
            val jniDir = layout.projectDirectory.dir("src/main/jniLibs/arm64-v8a").asFile

            // ---- 1. PRoot 二进制齐全性 ----
            requiredNativeBinaries.forEach { (fileName, minBytes) ->
                val f = File(jniDir, fileName)
                check(f.isFile) {
                    buildString {
                        appendLine("缺少 PRoot 运行时二进制：${f.absolutePath}")
                        appendLine()
                        appendLine("本沙箱是**内置离线**设计：运行时二进制必须随仓库交付，")
                        appendLine("不能靠「用户自己想办法」。请执行（在 POSIX 环境下）：")
                        appendLine("    bash tools/fetch-proot.sh")
                        appendLine()
                        appendLine("或在没有 bash/dpkg 的环境下从可信来源手工放置以上 4 个文件。")
                        append("详见 README「构建要求」与 docs/integration-guide.md §4。")
                    }
                }
                check(f.length() >= minBytes) {
                    "PRoot 运行时二进制过小，可能下载不完整或被 strip 破坏：" +
                        "${f.name} = ${f.length()} B（要求 >= $minBytes B）"
                }

                // ---- 3. AArch64 ELF 校验 ----
                val head = f.inputStream().use { input -> ByteArray(20).also { input.read(it) } }
                check(head.size >= 20 &&
                    head[0] == 0x7F.toByte() && head[1] == 'E'.code.toByte() &&
                    head[2] == 'L'.code.toByte() && head[3] == 'F'.code.toByte()
                ) { "不是 ELF 文件：${f.name}（magic 应为 7F 45 4C 46）" }
                check(head[18] == 0xB7.toByte() && head[19] == 0x00.toByte()) {
                    "不是 AArch64 ELF：${f.name}（e_machine 应为 B7 00，实际 " +
                        "${String.format("%02X %02X", head[18], head[19])}）" +
                        " —— 本沙箱只支持 arm64-v8a"
                }
            }

            // ---- 2 + 4. 内置 rootfs ----
            val bundledCandidates = listOf("rootfs-bundle.bin", "rootfs-bundle.tar.gz", "rootfs-bundle.tar")
            val assetDir = layout.projectDirectory.dir("src/main/assets").asFile
            val bundled = bundledCandidates
                .map { File(assetDir, it) }
                .firstOrNull { it.isFile && it.length() > 0 }

            check(bundled != null) {
                buildString {
                    appendLine("缺少内置 rootfs：${assetDir.absolutePath}/{rootfs-bundle.bin,rootfs-bundle.tar.gz,rootfs-bundle.tar}")
                    appendLine()
                    appendLine("★ 本沙箱是**内置离线沙箱**（不依赖服务器/云端），")
                    appendLine("  内置 rootfs 是主路径而不是可选兜底。请放入：")
                    appendLine("    src/main/assets/rootfs-bundle.bin")
                    appendLine()
                    appendLine("  可用 scripts/fetch-bundled-rootfs 从 Alpine 镜像获取（约 3.8 MB），")
                    append("  见 README「构建要求」。")
                }
            }
            check(bundled.length() > 500_000L) {
                "内置 rootfs 过小（${bundled.length()} B），不像一个可用的 rootfs"
            }
            if (bundled.name.endsWith(".gz")) {
                val magic = bundled.inputStream().use { input -> ByteArray(2).also { input.read(it) } }
                check(magic[0] == 0x1F.toByte() && magic[1] == 0x8B.toByte()) {
                    "内置 rootfs 扩展名是 .tar.gz 但内容不是 gzip（magic 应为 1F 8B）"
                }
            }
        }
    }
}

// ============================================================================
// ★ 构建期第 2 道：**能力宣称核对**（防止文档说假话）
// ============================================================================
// 真实教训：本工程 README 曾写「在 PRoot rootfs 里真跑 Linux 命令（gcc、aapt2、apt…）」，
// security-boundary.md 曾写「apt、gcc、aapt2 都能跑」。
// 真机实测三样**全部不存在**（`command -v aapt2` → NONE）。
//
// 这不是错别字，是**虚假宣传**：PRoot 只提供文件系统视图，不提供任何工具。
// 「能跑」和「有得跑」是两件事。
//
// 光靠「以后注意」没用，所以把核对做成构建的一部分：
//   tools/verify-claims.ps1 把「文档宣称的工具」与「rootfs 里真实存在的工具」
//   机械比对，不一致就失败。
//
// 注意：只在 Windows（有 PowerShell）上跑。其他平台跳过并给出提示 ——
// 跳过而不是静默通过，避免让人误以为「已经核对过了」。
val verifyClaimsScript = rootProject.file("tools/verify-claims.ps1")

tasks.register<Exec>("verifyCapabilityClaims") {
    group = "verification"
    description = "核对 README/docs 里宣称可用的工具是否真的在 rootfs 里（防止虚假宣传）"

    onlyIf {
        // 脚本依赖 PowerShell；非 Windows 上跳过
        System.getProperty("os.name").startsWith("Windows") && verifyClaimsScript.isFile
    }

    workingDir(rootProject.projectDir)
    commandLine(
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", verifyClaimsScript.absolutePath,
    )

    // 文档或 rootfs 变了就要重跑
    inputs.file(verifyClaimsScript)
    inputs.file(rootProject.file("README.md"))
    inputs.file(rootProject.file("docs/security-boundary.md"))
    rootProject.file("sandbox-runtime/src/main/assets").listFiles()?.forEach { asset ->
        if (asset.isFile) inputs.file(asset)
    }
}

tasks.named("preBuild") {
    dependsOn("verifyCapabilityClaims")
}

dependencies {
    api(project(":sandbox-api"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit)
}
