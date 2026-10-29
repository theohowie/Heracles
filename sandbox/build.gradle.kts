// Heracles-taixu-sandbox — 根构建脚本
//
// 本工程是**独立**的 Gradle 多模块工程：不引用 Heracles 主仓库的任何模块，
// 单独 `./gradlew build` 即可编译，单独分发即可被其他 Android Agent 项目复用。
//
// 上游关系（详见 UPSTREAM.md）：
//   - 基底 fork：taixu (wkbin/taixu) @ dc7fcddb88e565929379597bbd811b440d00e34f
//   - 一次性移植：baicodex (mubai0122/baicodex) @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95
//   - 一次性移植：tianxuan (xiaozhe7772222/tianxuan) @ caad40090a4f2c2edbe54e6eaae60a3dd1de7d21
//
// 协议：GPL-3.0（见 LICENSE / NOTICE）

plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
}
