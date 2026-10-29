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
 *
 * ---------------------------------------------------------------------------
 * 移植来源
 * ---------------------------------------------------------------------------
 * 上游：baicodex (mubai0122/baicodex) @ fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95
 *   原文件：app/src/main/kotlin/b/ai/exec/Shiz.kt
 *           （State 四态 / Perm 五种授权结果 / probe 的真检测顺序 / ask 的超时与永久拒绝判定）
 *
 * ★★★ 本文件是「Shizuku 隔离层」的**无依赖一半** ★★★
 *
 * 设计目的（这是本模块的硬验收项）：
 *
 *   `sandbox-channel` 对 Shizuku 的依赖是 **compileOnly**：编译期有 API，
 *   运行期**默认没有这些类**。若任何一处直接 `import rikka.shizuku.*` 的代码
 *   在类加载期被验证/初始化，缺类就会抛 NoClassDefFoundError，
 *   并且会顺着调用栈把普通 App 通道一起带崩 —— 也就是「装了没用 Shizuku 的
 *   设备上一个 App 都跑不起来」。
 *
 *   因此把「碰 rikka.shizuku 类型的代码」全部关进一个单独的类
 *   （ShizukuAccessImpl，另一个文件），并且：
 *
 *     1. 本文件（接口 + 装载器）**不 import 任何 rikka 类型**；
 *     2. 装载器只用 `Class.forName(字符串常量)` 去拿实现类，**不做静态引用**，
 *        这样 ART 的校验器不会在本类加载时去解析实现类的依赖；
 *     3. 整个装载过程包在 `try { } catch (t: Throwable)` 里 ——
 *        捕获的是 Throwable 而不是 Exception，因为 NoClassDefFoundError /
 *        ExceptionInInitializerError / UnsatisfiedLinkError 都是 Error；
 *     4. 装载失败时返回一个「永远不可用」的实现，通道层照常工作。
 *
 *   运行期想要真正启用 Shizuku，**宿主**（sandbox-app 或 Heracles）需要自己加
 *   `implementation(libs.shizuku.api)` 与 `implementation(libs.shizuku.provider)`，
 *   并在宿主 manifest 里声明 ShizukuProvider。本模块刻意不替宿主做这个决定，
 *   这正是 compileOnly 的语义：**不硬绑定**。
 */

package com.heracles.sandbox.channel.shizuku

import android.content.Context
import com.heracles.sandbox.channel.ShellOutcome

/**
 * Shizuku 的一次探测快照（纯数据，可跨线程传递、可单测）。
 *
 * <p>字段刻意与上游 `Shiz.Probe` 对齐，但把「状态字符串」拆成了几个布尔/整数，
 * 便于 [ShizukuChannel] 自己组装成人读文案（上游把文案塞在探测结果里，
 * 那是 UI 层的习惯，这里不照搬）。
 */
data class ShizukuFacts(
    /** `Shizuku.pingBinder()`：Shizuku 服务进程是否活着。 */
    val binderAlive: Boolean = false,
    /** 设备上是否装了 Shizuku 管理器 App。用来区分「没装」和「没启动」。 */
    val installed: Boolean = false,
    /** `checkSelfPermission() == PERMISSION_GRANTED`：本应用是否已被授权。 */
    val permissionGranted: Boolean = false,
    /** `isPreV11()`：Shizuku 版本太老（< 11），API 不可用。 */
    val preV11: Boolean = false,
    /** 服务端 uid：0 = root 后端，2000 = ADB 后端，-1 = 未知。 */
    val uid: Int = -1,
    /** Shizuku 服务版本号；-1 = 未知。 */
    val version: Int = -1,
    /**
     * 反射装载失败的原因；null 表示 rikka 类在运行期可见、探测结果可信。
     *
     * <p>非 null 时其余字段全部无意义 —— 这是「Shizuku 客户端库没打包进 APK」
     * 的正常降级状态，不是错误。
     */
    val loadError: String? = null,
) {
    /** 只有 binder 活着、已授权、版本够、且类加载成功，才算真正可用。 */
    val usable: Boolean get() = loadError == null && binderAlive && permissionGranted && !preV11
}

/** 申请授权的结果：与上游 `Shiz.Perm` 一一对应。 */
enum class ShizukuPermissionResult {
    /** 已授权（或用户在弹窗里点了允许）。 */
    GRANTED,

    /** 用户点了拒绝（还能再问）。 */
    DENIED,

    /**
     * 用户选过「拒绝且不再询问」。
     *
     * <p>上游注释写明：`shouldShowRequestPermissionRationale()` 为 true 时
     * 再 request 也不会弹窗，只能去 Shizuku 管理器里手动开。
     */
    NEVER_ASK,

    /** Shizuku 服务没在运行。 */
    NO_SERVICE,

    /** 弹窗超时没回应，或 request 本身抛异常。 */
    ERROR,
}

/**
 * 隔离层接口：**只出现 android.* 与沙箱自己的类型**，绝不出现 rikka 类型。
 *
 * <p>实现类（[ShizukuAccessImpl]）用反射装载，见 [ShizukuAccessLoader]。
 * 通过这层，调用方（[ShizukuChannel]）不需要知道底下是不是真的有 Shizuku。
 */
interface ShizukuAccess {

    /**
     * 注入应用上下文（幂等）。
     *
     * <p>必须先于 [exec] 调用：用户服务的 `ComponentName` 要用真实包名，
     * 而本模块是 library，编译期不知道宿主的 applicationId。
     * [ShizukuChannel] 的 [ShizukuChannel.probe] / [ShizukuChannel.exec] 都会先调它，
     * 因此正常路径下调用方不必关心。
     */
    fun attach(context: Context)

    /**
     * 读一次探测快照。**不得抛异常**：内部失败要收敛成 [ShizukuFacts]。
     *
     * @param context 应用上下文；为 null 时实现应报「不可用」而不是抛异常
     *        （[ShizukuChannel] 允许在无 Context 的纯 JVM 环境里被探测）。
     */
    fun facts(context: Context?): ShizukuFacts

    /**
     * 申请授权。**一定会回调一次**（可能同步回调）。
     *
     * <p>只应当在主线程调用（Shizuku 的 requestPermission 有主线程要求）；
     * 实现内部负责把回调切回主线程。
     */
    fun requestPermission(context: Context, onResult: (ShizukuPermissionResult) -> Unit)

    /**
     * 经用户服务以 shell / root 身份执行。
     *
     * <p>**不得抛异常**：任何失败都收敛成 `exitCode = -1`。
     */
    fun exec(command: String, stdin: String?, timeoutMs: Long): ShellOutcome

    /** 清掉用户服务连接与缓存（Shizuku 重启后调用）。 */
    fun reset()
}

/**
 * 「Shizuku 运行期不存在」时的占位实现。
 *
 * <p>这是**正常状态**而不是错误：本模块对 Shizuku 只有 compileOnly 依赖，
 * 宿主没打包客户端库时就是这个结果。此时：
 * - [facts] 返回带 [ShizukuFacts.loadError] 的快照，通道层据此报「不可用」；
 * - [exec] 立刻返回 -1，绝不阻塞、绝不崩溃；
 * - 普通 App 通道完全不受影响（这是硬验收项）。
 */
internal class UnavailableShizukuAccess(
    private val reason: String,
) : ShizukuAccess {

    override fun attach(context: Context) = Unit

    override fun facts(context: Context?): ShizukuFacts = ShizukuFacts(loadError = reason)

    override fun requestPermission(context: Context, onResult: (ShizukuPermissionResult) -> Unit) {
        onResult(ShizukuPermissionResult.NO_SERVICE)
    }

    override fun exec(command: String, stdin: String?, timeoutMs: Long): ShellOutcome = ShellOutcome(
        exitCode = -1,
        output = "[Shizuku] 通道不可用：$reason",
    )

    override fun reset() = Unit
}

/**
 * 反射装载器：这是「不硬绑定」的落地点。
 *
 * <p>三条纪律：
 * 1. **只用字符串常量**引用实现类名 —— 编译期不产生对 [ShizukuAccessImpl] 的
 *    静态引用，因此本类（以及整个通道层）的类加载与 rikka 类无关。
 * 2. **捕获 Throwable**：`NoClassDefFoundError` 是 Error 不是 Exception。
 * 3. **结论缓存**：classloader 的失败不会自愈，反复 forName 只是白花时间；
 *    缓存成 `Result.failure` 后每次直接复用。
 *
 * <p>注意这里是 `internal object` + [load] 返回 [ShizukuAccess]（永不返回 null），
 * 调用点的代码因此可以写成直线，不需要到处判空。
 */
internal object ShizukuAccessLoader {

    /**
     * 实现类的全限定名。
     *
     * <p>**必须与 [ShizukuAccessImpl] 的实际 FQCN 一致**，且该实现类
     * **不得被任何代码静态引用**（只准出现在这个字符串里）。
     * 若改名，编译不会报错 —— 后果只是通道恒不可用，所以有一处
     * 诊断文案会把类名带出来，便于排查。
     */
    private const val IMPL_CLASS: String = "com.heracles.sandbox.channel.shizuku.ShizukuAccessImpl"

    @Volatile
    private var cached: ShizukuAccess? = null

    /**
     * 装载实现；失败时返回 [UnavailableShizukuAccess]（带原因），**永不抛出**。
     *
     * <p>线程安全：最坏情况是并发时多 new 一次实现类，无害（实现自身有 @Volatile 状态）。
     */
    fun load(): ShizukuAccess {
        cached?.let { return it }
        val loaded = try {
            val clazz = Class.forName(IMPL_CLASS)
            val instance = clazz.getDeclaredConstructor().newInstance()
            instance as? ShizukuAccess
                ?: UnavailableShizukuAccess("$IMPL_CLASS 未实现 ShizukuAccess（内部契约错误）")
        } catch (t: Throwable) {
            // 走到这里的正常原因：宿主没把 dev.rikka.shizuku:api 打进 APK，
            // 于是 NoClassDefFoundError / ExceptionInInitializerError。
            UnavailableShizukuAccess(
                "Shizuku 客户端库不在运行期 classpath（$IMPL_CLASS 装载失败：" +
                    "${t.javaClass.simpleName}: ${t.message}）。" +
                    "要启用该通道，宿主需自行依赖 dev.rikka.shizuku:api 并声明 ShizukuProvider。",
            )
        }
        cached = loaded
        return loaded
    }

    /** 清空装载缓存（仅测试用；生产环境 classloader 不会变）。 */
    fun clearForTest() {
        cached = null
    }
}
