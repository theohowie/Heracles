rootProject.name = "heracles"

// 核心逻辑全部是纯 JVM 模块 —— 可在 PC 上毫秒级测试，无需真机、无需 Android SDK。
// Android 前端在 app/（Flutter + Android 壳，独立 Gradle 构建）。
include(":core")
include(":provider-http")
include(":workspace")
include(":toolchain")
include(":agent")

pluginManagement {
    repositories {
        // 国内镜像优先（实测 21 MB/s），Maven Central 兜底
        maven("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        maven("https://mirrors.cloud.tencent.com/nexus/repository/maven-public/")
        mavenCentral()
    }
}
