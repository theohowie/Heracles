package com.theohowie.heracles.bridge

import android.content.pm.PackageManager
import android.os.IBinder
import moe.shizuku.server.IShizukuService
import rikka.shizuku.Shizuku
import rikka.shizuku.ShizukuBinderWrapper

/**
 * **Shizuku 集成管理器**（2026-10-16 用户需求「接入 shizuku 获取更高权限」）。
 *
 * ## 修的是什么
 *
 * 用户实测：「我在 shizuku 上面都找不到本 app 来授权」——
 * 根因：上一批只做了"检测+文案"，**没有集成 Shizuku SDK**。
 * 授权列表靠 [rikka.shizuku.ShizukuProvider]（已注册 Manifest）+
 * `Shizuku.requestPermission()` 触发。
 *
 * ## 为什么用 IShizukuService.newProcess 而不是 Shizuku.newProcess
 *
 * **对着真实 jar 验证的**（javap `dev.rikka.shizuku:api:13.1.5`）：
 * `Shizuku.newProcess` 是 **private**（网上流传的示例代码是错的/过期的）。
 * 公开路径是 [IShizukuService.newProcess]（aidl 包，本类已用）：
 *
 * ```
 * Shizuku.getBinder()
 *   → ShizukuBinderWrapper（处理权限/binder 死亡）
 *   → IShizukuService.Stub.asInterface
 *   → newProcess(...) → IRemoteProcess（含 stdin/stdout/exit）
 * ```
 *
 * ## 能力（授权后，UID 2000 = shell）
 *
 * 一次性解锁：
 * · `pm grant` WRITE_SECURE_SETTINGS（无障碍自愈，ADR-016 P0）
 * · 设备控制层（input/dumpsys/am，Phase 5）
 *
 * ## 线程注意
 *
 * `Shizuku.*` 的 binder 调用**不能在主线程**（可能 ANR），
 * 调用方（MainActivity）必须在 IO 协程里。
 */
object ShizukuManager {

    const val REQUEST_CODE = 2001

    /** Shizuku 是否在运行（App 已装且 binder 存活） */
    fun isAvailable(): Boolean = try {
        Shizuku.pingBinder()
    } catch (e: Exception) {
        false
    }

    /** 是否已获得 Shizuku 授权 */
    fun hasPermission(): Boolean = try {
        isAvailable() && !Shizuku.isPreV11() &&
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    } catch (e: Exception) {
        false
    }

    /**
     * **诊断信息**（2026-10-16，用户反馈「Shizuku 那边怎么还是已授权 0 个应用？」）。
     *
     * ## 为什么需要它
     *
     * 真机现象自相矛盾：
     * · 我们的 `pm grant` **确实以 shell 身份执行成功**（权限真授予了）
     * · 但 Shizuku UI 显示「已授权 **0** 个应用」
     *
     * 可能的原因：本机同时装了 **Stellar（`roro.stellar.manager`）**，
     * 而 Shizuku-API 库**内置 Sui 支持** —— 若 Sui 可用，API 调用会
     * **走 Sui 而不是 Shizuku**（`ShizukuProvider.onCreate` 里
     * `Sui.init()`；`call()` 里 `if (Sui.isSui()) return new Bundle()`）。
     * 那样 Shizuku 的授权列表自然是 0 —— 因为根本没经它。
     *
     * 这个诊断把**实际路由**如实显示给用户，而不是让用户猜。
     */
    fun diagnostics(): Map<String, Any?> {
        val ping = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
        val preV11 = runCatching { Shizuku.isPreV11() }.getOrDefault(false)
        val granted = runCatching {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)
        // Sui 检测：库内置的兼容层（Stellar 等 Sui 系管理器提供）
        val sui = runCatching { rikka.sui.Sui.isSui() }.getOrDefault(false)
        return mapOf(
            "shizukuPing" to ping,
            "shizukuPreV11" to preV11,
            "shizukuGranted" to granted,
            "sui" to sui,
        )
    }

    /** 触发 Shizuku 的授权弹窗（结果经 [OnRequestPermissionResultListener] 异步返回） */
    fun requestPermission() {
        if (!isAvailable()) return
        if (Shizuku.isPreV11()) {
            throw IllegalStateException("Shizuku 版本过旧（pre-v11），请升级 Shizuku App")
        }
        Shizuku.requestPermission(REQUEST_CODE)
    }

    /** 经 Shizuku binder 拿 IShizukuService（每次现取 —— binder 可能死亡重建） */
    private fun service(): IShizukuService {
        val binder: IBinder = Shizuku.getBinder()
            ?: throw IllegalStateException("Shizuku binder 不可用（未启动或已断开）")
        val wrapped = ShizukuBinderWrapper(binder)
        return IShizukuService.Stub.asInterface(wrapped)
    }

    /**
     * **请求授权并在授权后自动执行**（一次性流程，UI 一键完成）。
     *
     * 已有权限 → 直接执行；没有 → 弹 Shizuku 授权框 → 用户同意后执行。
     *
     * @param command 要以 shell(UID 2000) 身份执行的命令
     * @param onResult 回调在**未知线程**（Shizuku listener / IO）——调用方自己切线程
     */
    fun requestPermissionAndRun(
        command: String,
        onResult: (success: Boolean, output: String) -> Unit,
    ) {
        if (!isAvailable()) {
            onResult(false, "Shizuku 未安装或未运行 —— 请先安装并启动 Shizuku")
            return
        }
        if (hasPermission()) {
            runCommand(command, onResult)
            return
        }

        // ⚠️ listener 用 object 表达式（不能用 SAM + lambda 内自引用）：
        //    移除时需要引用 listener 自身 —— SAM lambda 无法在体内引用自己。
        val listener = object : Shizuku.OnRequestPermissionResultListener {
            override fun onRequestPermissionResult(requestCode: Int, grantResult: Int) {
                if (requestCode != REQUEST_CODE) return
                Shizuku.removeRequestPermissionResultListener(this)
                if (grantResult == PackageManager.PERMISSION_GRANTED) {
                    runCommand(command, onResult)
                } else {
                    onResult(false, "Shizuku 授权被拒绝")
                }
            }
        }
        Shizuku.addRequestPermissionResultListener(listener)
        try {
            requestPermission()
        } catch (e: Exception) {
            Shizuku.removeRequestPermissionResultListener(listener)
            onResult(false, "无法请求 Shizuku 授权：${e.message}")
        }
    }

    /**
     * **强制走一次 Shizuku 授权流程**（2026-10-16）。
     *
     * ## 为什么需要（用户反馈「Shizuku 里还是已授权 0 个应用」）
     *
     * 诊断证明：`checkSelfPermission()` 已返回 GRANTED（服务端认为已授权），
     * 但 Shizuku **UI 的授权列表**是空的。
     *
     * 最可能的原因：本 App 的授权是**遗留记录**（包名 `com.theohowie.heracles`
     * 在 2026-10-12 就装过并被授权过），**从未走过 Shizuku 的授权弹窗** ——
     * 而它的列表 UI 收录的是"走过申请流程"的应用。
     *
     * 所以：**无条件调用 `requestPermission()`**（即使已有权限），
     * 让 Shizuku 的弹窗真的出现一次 → 用户同意 → 列表里就有本 App 了。
     *
     * @param onResult 回调在未知线程；成功与否以 [hasPermission] 复核为准
     */
    fun forceRequestPermissionAndRun(
        command: String,
        onResult: (success: Boolean, output: String) -> Unit,
    ) {
        if (!isAvailable()) {
            onResult(false, "Shizuku 未安装或未运行")
            return
        }
        val listener = object : Shizuku.OnRequestPermissionResultListener {
            override fun onRequestPermissionResult(requestCode: Int, grantResult: Int) {
                if (requestCode != REQUEST_CODE) return
                Shizuku.removeRequestPermissionResultListener(this)
                if (grantResult == PackageManager.PERMISSION_GRANTED) {
                    runCommand(command, onResult)
                } else {
                    onResult(false, "Shizuku 授权被拒绝")
                }
            }
        }
        Shizuku.addRequestPermissionResultListener(listener)
        try {
            // 无条件请求 —— 这是让 Shizuku 记录本 App 的唯一途径
            requestPermission()
        } catch (e: Exception) {
            Shizuku.removeRequestPermissionResultListener(listener)
            onResult(false, "无法请求 Shizuku 授权：${e.message}")
        }
    }

    /**
     * 通过 Shizuku 执行 shell 命令（UID 2000 = shell 权限）。
     *
     * 典型命令：`pm grant <pkg> android.permission.WRITE_SECURE_SETTINGS`
     */
    fun runCommand(command: String, onResult: (success: Boolean, output: String) -> Unit) {
        try {
            val process = service().newProcess(arrayOf("sh", "-c", command), null, null)
            // ⚠️ IRemoteProcess 的流是 ParcelFileDescriptor（不是普通流，
            //    没有 bufferedReader）—— 用 AutoCloseInputStream 包装
            val out = android.os.ParcelFileDescriptor.AutoCloseInputStream(
                process.inputStream,
            )
            val errFd = android.os.ParcelFileDescriptor.AutoCloseInputStream(
                process.errorStream,
            )
            val output = out.bufferedReader().use { it.readText() }
            val err = errFd.bufferedReader().use { it.readText() }
            val code = process.waitFor()
            val text = (output + err).trim()
            onResult(code == 0, text.ifEmpty { "exit=$code" })
        } catch (e: Exception) {
            onResult(false, "执行失败：${e.message}")
        }
    }
}
