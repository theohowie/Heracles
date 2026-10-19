// 依赖仓库在 settings.gradle.kts 统一声明（Gradle 9 已弃用 allprojects/subprojects 的侵入式写法）。
// 这里只声明插件版本，供各模块无版本号引用。
plugins {
    kotlin("jvm") version "2.4.21" apply false
}
