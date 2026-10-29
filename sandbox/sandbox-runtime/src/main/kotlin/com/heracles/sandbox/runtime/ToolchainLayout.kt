/*
 * Copyright (C) 2026 Heracles-taixu-sandbox contributors
 *
 * SPDX-License-Identifier: GPL-3.0
 *
 * This file is part of Heracles-taixu-sandbox.
 *
 * Heracles-taixu-sandbox is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Heracles-taixu-sandbox is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Heracles-taixu-sandbox.  If not, see <https://www.gnu.org/licenses/>.
 */

package com.heracles.sandbox.runtime

/**
 * rootfs 内构建套件的**目录布局约定**。
 *
 * ============================================================================
 * 为什么要有这个文件（一句话）
 * ============================================================================
 * 沙箱内的工具**只能装在 rootfs 里**，而且必须是 **linux-aarch64** 版本。
 *
 * 不能把 Android 的 bionic 程序（Termux 的 `aapt2` / `zip`）打进来 ——
 * 它们的 ELF 解释器是 `/system/bin/linker64`，在 PRoot guest 里 `execve`
 * 返回 ENOENT（真机实测 `command -v aapt2` 找得到、执行 `not found`）。
 * 更关键的是：那种程序**只能在宿主进程跑**，等于绕过沙箱，隔离/快照/回滚全失效。
 *
 * 详见 `docs/porting-log.md` Phase 7。
 *
 * ============================================================================
 * 布局（全部落在 rootfs 内，guest 视角）
 * ============================================================================
 * ```
 * /opt/ja                 JDK 17（linux-aarch64）
 * /opt/as                 Android SDK（platforms/android-XX/android.jar + build-tools）
 * /opt/gradle             Gradle 发行版
 * /root/.gradle           Gradle 缓存（放 rootfs 内，随快照回滚）
 * /workspace              工作区（宿主的项目目录绑进来）
 * ```
 *
 * 为什么是 `/opt/` 而不是 `/usr/`：
 *   - `/usr` 属于发行版自身，往里塞东西会让「重置 rootfs」语义变模糊
 *   - `/opt` 是「额外装的软件」的约定位置，清空它 = 回到干净基线
 *
 * ============================================================================
 * 与 taixu 的对应关系
 * ============================================================================
 * 上游 taixu 用 `assets/plugins/android-suite-offline/` 装套件，
 * 目标是 `/opt/taixu/tools/android-suite-offline/`，并且同样**全部是
 * linux-aarch64 版本**（见其 `DOWNLOADS.md`：Temurin JDK aarch64_linux、
 * android-sdk-tools-static-aarch64、cmake/ninja linux-aarch64…）。
 *
 * 本沙箱不照搬它的目录名（那是它的产品命名），只沿用**同一套做法**：
 * 下载 linux-aarch64 归档 → 校验 → 解压进 rootfs → 加进 guest PATH。
 */
object ToolchainLayout {

    /** 套件在 guest 内的根目录。 */
    const val GUEST_ROOT = "/opt"

    /** JDK 17 解压目录（guest 视角）。 */
    const val GUEST_JDK = "$GUEST_ROOT/ja"

    /** Android SDK 目录（platform + build-tools）。 */
    const val GUEST_ANDROID_SDK = "$GUEST_ROOT/as"

    /** Gradle 发行版目录。 */
    const val GUEST_GRADLE = "$GUEST_ROOT/gradle"

    /** Gradle 用户缓存（放在 rootfs 内，跟着快照一起回滚）。 */
    const val GUEST_GRADLE_HOME = "/root/.gradle"

    /**
     * 装了套件之后，guest 里应当存在的关键命令。
     *
     * 用途有两个：
     *   1. `docs/integration-guide.md` 里写清「装完之后能验证什么」
     *   2. 真机验收时逐项 `command -v`（**不猜、不假装**）
     *
     * 注意：`aapt2` / `zipalign` 来自 `android-sdk-tools-static-aarch64`，
     * 不需要 JDK；`gradle` / `apksigner` / `d8` 才需要 JDK。
     */
    val EXPECTED_COMMANDS = listOf(
        // 只依赖 Android SDK 的静态工具
        "aapt2",
        "aidl",
        "zipalign",
        // 依赖 JDK 的 JVM 工具
        "java",
        "javac",
        "gradle",
    )

    /**
     * Alpine 通过 `apk add openjdk17-jdk` 装出来的 JDK 家目录。
     *
     * ★ 内置 rootfs 是 Alpine（**musl**），必须用 Alpine 自己的 musl 版 JDK。
     * Temurin 那类是 **glibc** 构建，解释器 `/lib/ld-linux-aarch64.so.1`，
     * 而 Alpine 只有 `/lib/ld-musl-aarch64.so.1` ⇒ 真机实测 `java -version`
     * 直接返回 **127**（内核找不到 ELF 解释器）。
     * 这与 Phase 7 的 bionic/musl 是同一类问题：**ABI 不匹配放进去也跑不了**。
     */
    const val ALPINE_JDK_HOME = "/usr/lib/jvm/java-17-openjdk"

    /**
     * 生成注入 guest 环境变量的片段（**每条命令前都要带**）。
     *
     * 为什么不能只靠 `ProotEngine.guestEnvironment()` 里的 PATH：
     * `/bin/sh -lc` 是**登录 shell**，会读 `/etc/profile`，而 Alpine 的
     * `/etc/profile` 里有 `export PATH="/usr/local/sbin:..."` —— 会把我们
     * 设的 PATH **无条件覆盖**。所以只能在命令串前面再补一次。
     *
     * @param jdkHome JDK 家目录。
     *   - Alpine 的 musl JDK：用 [ALPINE_JDK_HOME]（`apk add` 装的）
     *   - 自备的 linux-aarch64 JDK：用 [GUEST_JDK]（解压到 `/opt/ja` 的）
     *
     * 用法（宿主侧组装命令时）：
     * ```
     * val cmd = ToolchainLayout.envPrelude() + "gradle --version"
     * ```
     */
    fun envPrelude(jdkHome: String = GUEST_JDK): String = buildString {
        append("export PATH=\"")
        append("$jdkHome/bin:$GUEST_GRADLE/bin:$GUEST_ANDROID_SDK/build-tools:$GUEST_ANDROID_SDK/platform-tools:\$PATH")
        append("\"; ")
        append("export JAVA_HOME=\"$jdkHome\"; ")
        append("export ANDROID_HOME=\"$GUEST_ANDROID_SDK\"; ")
        append("export ANDROID_SDK_ROOT=\"$GUEST_ANDROID_SDK\"; ")
        append("export GRADLE_USER_HOME=\"$GUEST_GRADLE_HOME\"; ")
        // Android 上没有 /tmp；JDK 工具必须给它一个可写临时目录，否则
        // java/javac 会在启动阶段就失败（TMPDIR 指向 rootfs 内的 /tmp）。
        append("export TMPDIR=\"/tmp\"; ")
    }

    /**
     * 给 JVM 工具的必要参数。
     *
     * Android 上没有 `/tmp` 与用户 home，JDK 工具默认会写 `/tmp/hsperfdata_*`，
     * 失败后有些工具会**静默降级或直接崩**。统一带上这两个参数最稳。
     */
    val JVM_FLAGS = listOf(
        "-Djava.io.tmpdir=/tmp",
        "-Duser.home=/root",
    )
}
