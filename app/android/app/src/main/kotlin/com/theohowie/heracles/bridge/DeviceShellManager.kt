package com.theohowie.heracles.bridge

import android.content.Context
import android.content.pm.PackageManager
import roro.stellar.Stellar
import rikka.shizuku.Shizuku

/**
 * **双管理器统一入口**（2026-10-16，用户需求「A、C 两个都要支持」）。
 *
 * ## 背景：为什么要同时支持两个
 *
 * · **Shizuku**（`moe.shizuku.privileged.api`）—— 生态主流，ADB 启动
 * · **Stellar**（`roro.stellar.manager`）—— Shizuku 的**深度定制分支**，
 *   支持 ADB **或 Root** 启动，能力更强（含 `grantRuntimePermission` 等
 *   被 Shizuku 弃用的 API）
 *
 * 两者**可共存**（不同包名 / 不同 Provider Authority），用户装哪个都可能。
 * 本类在运行时**自动选择可用的那个** —— 用户不需要关心用的是什么。
 *
 * ## 选择策略（优先级）
 *
 * 1. **Stellar 优先** —— 它能力更强（Root 模式可写系统属性、授予别人权限），
 *    且是用户明确要求接入的
 * 2. 退到 **Shizuku** —— Stellar 未运行/未安装时
 * 3. 都没有 → 返回明确的失败原因，引导用户启动其中之一
 *
 * ## 与 ShizukuManager 的关系
 *
 * `ShizukuManager` 保留（它的 `diagnostics()` 仍被设备权限页使用）；
 * 本类是**执行入口**的统一封装，两者不重复。
 */
object DeviceShellManager {

    const val REQUEST_CODE = 2001

    /** 执行路由：谁在提供 shell 能力 */
    enum class Route(val label: String) {
        /** Stellar 服务（能力更强，优先）*/
        STELLAR("Stellar"),

        /** Shizuku 服务 */
        SHIZUKU("Shizuku"),

        /** 两者都不可用 */
        NONE("无"),
    }

    /** Stellar 的健康状态（含 Root/ADB 模式区分）*/
    data class StellarStatus(
        val available: Boolean,
        val granted: Boolean,
        /** 服务 UID：0=Root，2000=ADB */
        val uid: Int = -1,
    ) {
        /** 是否 Root 模式（能力最强）*/
        val isRoot: Boolean get() = uid == 0
    }

    fun stellarStatus(): StellarStatus = try {
        val ping = Stellar.pingBinder()
        StellarStatus(
            available = ping,
            granted = ping && Stellar.checkSelfPermission(PERMISSION),
            uid = if (ping) runCatching { Stellar.uid }.getOrDefault(-1) else -1,
        )
    } catch (e: Throwable) {
        StellarStatus(false, false)
    }

    fun shizukuStatus(): Triple<Boolean, Boolean, Boolean> = try {
        val ping = Shizuku.pingBinder()
        val pre = runCatching { Shizuku.isPreV11() }.getOrDefault(false)
        val granted = ping && !pre &&
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        Triple(ping, granted, pre)
    } catch (e: Throwable) {
        Triple(false, false, false)
    }

    /** 当前实际路由（Stellar 优先）*/
    fun currentRoute(): Route {
        val s = stellarStatus()
        if (s.available && s.granted) return Route.STELLAR
        val (szPing, szGranted, _) = shizukuStatus()
        if (szPing && szGranted) return Route.SHIZUKU
        return Route.NONE
    }

    /** Stellar 的权限名（Stellar 用多权限模型，基础权限是这个）。*/
    private const val PERMISSION = "stellar"

    /**
     * **请求授权并执行命令**（自动选择管理器）。
     *
     * @param command 以 shell/root 身份执行的命令
     * @param onResult 回调在**未知线程**；`route` 告诉调用方实际走的是谁
     */
    fun requestPermissionAndRun(
        command: String,
        onResult: (success: Boolean, output: String) -> Unit,
    ) {
        // ---- ① Stellar 可用（含未授权 → 弹它的授权框）----
        val s = stellarStatus()
        if (s.available) {
            if (s.granted) {
                runViaStellar(command, onResult)
            } else {
                stellarRequestThenRun(command, onResult)
            }
            return
        }

        // ---- ② 退到 Shizuku ----
        val (szPing, szGranted, _) = shizukuStatus()
        if (szPing) {
            if (szGranted) {
                ShizukuManager.runCommand(command, onResult)
            } else {
                ShizukuManager.requestPermissionAndRun(command, onResult)
            }
            return
        }

        // ---- ③ 都没有 ----
        onResult(
            false,
            "未检测到 Stellar 或 Shizuku 服务 —— 请在其中一个管理器中启动服务",
        )
    }

    /** 强制执行一次（自动选路，不做"已有权限就跳过"的优化）*/
    fun forceRequestAndRun(
        command: String,
        onResult: (success: Boolean, output: String) -> Unit,
    ) {
        val s = stellarStatus()
        if (s.available) {
            stellarRequestThenRun(command, onResult)
            return
        }
        val (szPing, _, _) = shizukuStatus()
        if (szPing) {
            ShizukuManager.forceRequestPermissionAndRun(command, onResult)
            return
        }
        onResult(false, "未检测到 Stellar 或 Shizuku 服务")
    }

    /** Stellar：请求权限 → 授权后执行 */
    private fun stellarRequestThenRun(
        command: String,
        onResult: (success: Boolean, output: String) -> Unit,
    ) {
        val listener =
            object : Stellar.OnRequestPermissionResultListener {
                override fun onRequestPermissionResult(
                    requestCode: Int,
                    allowed: Boolean,
                    onetime: Boolean,
                ) {
                    if (requestCode != REQUEST_CODE) return
                    Stellar.removeRequestPermissionResultListener(this)
                    if (allowed) {
                        runViaStellar(command, onResult)
                    } else {
                        onResult(false, "Stellar 授权被拒绝")
                    }
                }
            }
        Stellar.addRequestPermissionResultListener(listener)
        try {
            Stellar.requestPermission(PERMISSION, REQUEST_CODE)
        } catch (e: Throwable) {
            Stellar.removeRequestPermissionResultListener(listener)
            onResult(false, "无法请求 Stellar 授权：${e.message}")
        }
    }

    /**
     * Stellar：执行命令（UID 2000 shell 或 UID 0 root）。
     *
     * `Stellar.newProcess` 是**公开 API**（Shizuku 已弃用同类方法，
     * Stellar 保留了 —— javap 验证：`public StellarRemoteProcess newProcess(...)`）。
     * 它的流是**普通 InputStream**（不像 Shizuku 的 ParcelFileDescriptor），
     * 所以直接 `bufferedReader()` 即可。
     */
    private fun runViaStellar(
        command: String,
        onResult: (success: Boolean, output: String) -> Unit,
    ) {
        try {
            val process =
                Stellar.newProcess(arrayOf("sh", "-c", command), null, null)
            val output = process.inputStream.bufferedReader().use { it.readText() }
            val err = process.errorStream.bufferedReader().use { it.readText() }
            val code = process.waitFor()
            runCatching { process.destroy() }
            val text = (output + err).trim()
            onResult(code == 0, text.ifEmpty { "exit=$code" })
        } catch (e: Throwable) {
            onResult(false, "Stellar 执行失败：${e.message}")
        }
    }

    /**
     * **诊断信息**（给设备权限页显示）——
     * 把两个管理器的真实状态都摊开，用户不必猜。
     */
    fun diagnostics(): Map<String, Any?> {
        val s = stellarStatus()
        val (szPing, szGranted, szPre) = shizukuStatus()
        val route = currentRoute()
        return mapOf(
            // 统一结论
            "route" to route.label,
            "stellarInstalled" to isInstalled(StellarManagerPackage),
            "stellarRunning" to s.available,
            "stellarGranted" to s.granted,
            "stellarUid" to s.uid,
            "stellarRoot" to s.isRoot,
            "shizukuInstalled" to isInstalled(ShizukuManagerPackage),
            "shizukuPing" to szPing,
            "shizukuGranted" to szGranted,
            "shizukuPreV11" to szPre,
        )
    }

    private const val STELLAR_MANAGER_PACKAGE = "roro.stellar.manager"
    private const val SHIZUKU_MANAGER_PACKAGE = "moe.shizuku.privileged.api"

    /** 为常量取别名（Kotlin 里 const 不能直接引用另一个 const 的同名字符串）*/
    private const val StellarManagerPackage = STELLAR_MANAGER_PACKAGE
    private const val ShizukuManagerPackage = SHIZUKU_MANAGER_PACKAGE

    /** 管理器是否已安装 */
    private fun isInstalled(pkg: String): Boolean = try {
        appContext?.packageManager?.getPackageInfo(pkg, 0) != null
    } catch (e: Throwable) {
        false
    }

    /** 由 MainActivity 注入（诊断需要它查已安装包）*/
    @Volatile
    var appContext: Context? = null
}
