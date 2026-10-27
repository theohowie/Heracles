package com.theohowie.heracles

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.os.Environment
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import com.theohowie.heracles.bridge.DeviceChannel
import com.theohowie.heracles.bridge.DeviceFs
import com.theohowie.heracles.bridge.DeviceHealth
import com.theohowie.heracles.bridge.DevicePermissionChecker
import com.theohowie.heracles.bridge.DeviceShell
import com.theohowie.heracles.bridge.DeviceShellManager
import com.theohowie.heracles.bridge.BuildTaskProgress
import com.theohowie.heracles.bridge.FilePickerBridge
import com.theohowie.heracles.bridge.FolderPickerBridge
import com.theohowie.heracles.bridge.MemoryStore
import com.theohowie.heracles.bridge.WorkspaceRegistry
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * **Flutter 的活动壳 + 设备能力命令通道**（2026-10-22 大幅精简）。
 *
 * ## 这一轮改了什么，为什么
 *
 * 项目刚做过一次重构：原来 5 个 Kotlin 后端模块
 * （`:core` / `:provider-http` / `:workspace` / `:toolchain` / `:agent`）
 * **已被用户删除并弃用**，后端改用 Dart 重写（`backend/`）。
 *
 * ⇒ 本类里所有 Agent 相关的东西都**删掉**了：
 *
 * | 删掉 | 原来做什么 |
 * |---|---|
 * | `runAgent` | 跑一轮 agent（逻辑全在 Dart 了） |
 * | `cancelRun` / `interruptRun` | 取消 / 插话 |
 * | `replyAsk` / `replyApproval` | 工具挂起后的用户输入 |
 * | `alwaysAllowedTools` / `clearAlwaysAllowed` | 审批白名单 |
 * | `encodeSelfCheck` / `usageInfo` / `benchmarkStorage` | 诊断 / 用量 / 存储测量 |
 * | EventChannel `heracles/events` | Kotlin → Dart 的事件流 |
 * | 会话相关（`listSessions` / `createSession` / `loadMessages` / `seedBranch` / 重命名 / 删除 / 收藏 / 归档） | 会话 CRUD（已归 Dart） |
 *
 * **保留的是"只有原生才能做"的部分**（见 [DeviceChannel] 的表格）：
 * 文件 IO、shell、健康读数、系统选择器、前台服务通知。
 *
 * ## 两个通道，分工明确
 *
 * | 通道 | 方向 | 内容 |
 * |---|---|---|
 * | `heracles/device`（[DeviceChannel]） | Dart → Kotlin 请求 / 响应 | 设备能力全协议 |
 * | `heracles/command`（本类） | Dart → Kotlin 请求 / 响应 | **工作区登记** + 设备权限引导 + 通知回跳 |
 *
 * 为什么工作区登记留在 `heracles/command` 而没并进 `heracles/device`：
 * 它是**旧的、已验证的**接口，Dart 侧现有代码已经在用（`pickWorkspace` /
 * `listWorkspaces` / `ensureAppWorkspace` …）。这次重构的目标是"能编译 + 只剩设备能力"，
 * 不是重排接口 —— 少改一处就少一处回归面。两边的登记表是**同一个**
 * [WorkspaceRegistry] 实例（Application 级单例由 [configureFlutterEngine] 注入），
 * 所以不存在两份真相。
 *
 * ## 线程模型
 *
 * handler 跑在主线程；文件 IO 切 `Dispatchers.IO`。
 * `result.success` 一律回主线程（Flutter 的 `@UiThread` 要求）。
 */
class MainActivity : FlutterActivity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var registry: WorkspaceRegistry
    private lateinit var deviceFs: DeviceFs
    private lateinit var filePicker: FilePickerBridge
    private lateinit var folderPicker: FolderPickerBridge

    /** `heracles/command` 通道引用 —— 通知点击回跳要往 Dart 推送。 */
    private var commandChannel: MethodChannel? = null

    /** 冷启动时 Dart 还没注册 handler ⇒ 先把"要打开的会话"存着，等它主动来取。 */
    @Volatile
    private var pendingOpenSession: Map<String, String>? = null

    /** App 是否在前台（决定要不要发"任务完成"通知）。 */
    @Volatile
    private var appInForeground = false

    // ------------------------------------------------------------ 生命周期

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // ★ 冷启动：从完成通知点进来（Dart 还没就绪 ⇒ 先存 pending）
        handleNotifyIntent(intent)
        // ★ 运行时请求通知权限（API 33+）——
        //   不请求的话「任务完成通知」永远发不出去，且用户不知道能开。
        //   只在没授权时请求一次（系统会记住"已拒绝"；下次不重复骚扰）。
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTIFICATIONS)
        }
    }

    /**
     * `am start` 打到**已经在前台**的实例时走这里，**不进** [onCreate]。
     *
     * 漏了它就会出现"命令发出去了、什么都没发生" —— 2026-10-17 真机撞到
     * （日志里只有一句 `Warning: Activity not started, intent has been delivered
     * to currently running top-most instance`）。
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 让下面的 `intent` 属性读到**这一次**的 extra（否则还是启动时那个）
        setIntent(intent)
        handleNotifyIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        appInForeground = true
    }

    override fun onPause() {
        appInForeground = false
        super.onPause()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    // ------------------------------------------------------------ 通道挂载

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val ctx = applicationContext
        registry = WorkspaceRegistry(ctx)
        deviceFs = DeviceFs(ctx, registry)
        filePicker = FilePickerBridge(this)
        folderPicker = FolderPickerBridge(this)

        // ★ 设备能力通道（`heracles/device`）—— 协议见 [DeviceChannel]
        DeviceChannel(
            activity = this,
            registry = registry,
            fs = deviceFs,
            shell = DeviceShell(),
            health = DeviceHealth(ctx),
            build = BuildTaskProgress(ctx),
            // ★ 长期记忆（App 全局，与工作区无关）—— `memory.read/append/clear`
            memory = MemoryStore(ctx),
            filePicker = filePicker,
            folderPicker = folderPicker,
            scope = scope,
            mainHandler = mainHandler,
        ).register(flutterEngine)

        // ★ 命令通道（`heracles/command`）—— 工作区登记 + 权限引导 + 通知回跳
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).also { commandChannel = it }.setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ---- 工作区（登记表在本地 prefs，SAF/POSIX 由 DeviceFs 自行路由） ----
            "pickWorkspace" -> handlePickWorkspace(call, result)
            "listWorkspaces" -> handleListWorkspaces(result)
            "removeWorkspace" -> handleRemoveWorkspace(call, result)
            "ensureAppWorkspace" -> handleEnsureAppWorkspace(result)

            // ---- 文件 ----
            "pickFiles" -> handlePickFiles(call, result)
            "listDir" -> handleListDir(call, result)

            // ---- 设备权限（无线调试 / Shizuku / Stellar 引导） ----
            "devicePermission" -> handleDevicePermission(result)
            // ★ N8（2026-10-25，INTERFACE.md §4.N8）：权限页统一查询
            "devicePermissions" -> handleDevicePermissions(result)
            // ★ 2026-10-27：权限页改弹性开关 —— 开关拨动拉起系统授权流程
            "requestPermission" -> handleRequestPermission(call, result)
            "shizukuGrant" -> handleShizukuGrant(force = false, result = result)
            "shizukuForceRequest" -> handleShizukuGrant(force = true, result = result)

            // ---- 通知点击回跳 ----
            "consumePendingOpen" -> {
                val p = pendingOpenSession
                pendingOpenSession = null
                result.success(p)
            }

            else -> result.success(mapOf("ok" to false, "error" to "未知方法：${call.method}"))
        }
    }

    /** 回主线程送结果（Flutter 的 `Result` 是 `@UiThread`）。 */
    private fun reply(result: MethodChannel.Result, value: Any?) {
        if (Thread.currentThread() === mainHandler.looper.thread) {
            runCatching { result.success(value) }
        } else {
            mainHandler.post { runCatching { result.success(value) } }
        }
    }

    // ------------------------------------------------------------ 工作区

    /**
     * 选一个已有文件夹作为工作区（SAF 目录选择器）。
     *
     * **选中即登记**（`path` / `name` / `treeUri` 三字段进 `heracles_workspaces`）——
     * 否则 [DeviceFs] 查不到 SAF 记录，后续读这个目录会用 `java.io.File` 撞 `EPERM`。
     *
     * 用户取消时回 `null`（**沿用旧契约**：Dart 侧据此判断"没选"而不是"出错"）。
     */
    private fun handlePickWorkspace(call: MethodCall, result: MethodChannel.Result) {
        // 上次用的目录作为选择器起点（Dart 可传，避免 UI 侧还要存一份）
        val lastUri = call.argument<String>("lastUri").orEmpty()
        runOnUiThread {
            try {
                folderPicker.launch(lastUri) { ws ->
                    if (ws == null) {
                        // 用户取消，或选的位置没有本地路径（如网盘）
                        reply(result, null)
                        return@launch
                    }
                    // ★ 受限目录（Android 11+ 系统不授权）/ 网盘：
                    //   把**原因 + 出路**原样交给 Dart，让它能显示人话并给出按钮。
                    //   不再回 null（那会退化成一句笼统的"请换一个"）。
                    if (ws["ok"] == false) {
                        val payload = mutableMapOf<String, Any?>(
                            "ok" to false,
                            "error" to ((ws["error"] as? String)
                                ?: "这个位置无法用作工作区"),
                        )
                        (ws["reason"] as? String)?.let { payload["reasonCode"] = it }
                        (ws["suggest"] as? List<*>)?.let { payload["suggest"] = it }
                        reply(result, payload)
                        return@launch
                    }
                    val path = ws["path"] as? String
                    if (path.isNullOrBlank()) {
                        reply(result, null)
                        return@launch
                    }
                    val name = (ws["name"] as? String).orEmpty()
                    val treeUri = (ws["treeUri"] as? String).orEmpty()
                    scope.launch {
                        val saved = withContext(Dispatchers.IO) {
                            registry.add(path, name, treeUri)
                        }
                        // 登记失败（目录不存在且无 SAF 授权）→ 如实回 null，不假装成功
                        reply(result, saved)
                    }
                }
            } catch (e: Throwable) {
                reply(result, null)
            }
        }
    }

    /** 列出已登记的工作区 + 每个的会话数（只数 `sessions.json` 的数组长度）。 */
    private fun handleListWorkspaces(result: MethodChannel.Result) {
        scope.launch {
            val list = withContext(Dispatchers.IO) {
                registry.list().map { e ->
                    val map = e.toMap().toMutableMap()
                    // 「目录还在吗」：SAF 下 `File.isDirectory` 恒为 false（权限组不同）
                    // ⇒ SAF 一律按"存在"处理，失效判定留给真正写入时（与老实现一致）。
                    val exists = if (e.isSaf) true else File(e.path).isDirectory
                    map["exists"] = exists
                    map["sessionCount"] = if (exists) {
                        registry.sessionCount(deviceFs, e)
                    } else {
                        0
                    }
                    map
                }
            }
            reply(result, list)
        }
    }

    /** 从列表移除 —— **不删文件夹本身**。 */
    private fun handleRemoveWorkspace(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path").orEmpty()
        if (path.isBlank()) {
            reply(result, false)
            return
        }
        scope.launch {
            withContext(Dispatchers.IO) { registry.remove(path) }
            reply(result, true)
        }
    }

    /**
     * **登记内置「默认工作区」**（`<externalFilesDir>/app-workspace`）。
     *
     * 为什么必须内置：编码层要求工作区 **App 与 shell 都能写**，而真机上唯一满足的
     * `Android/data/<pkg>/files/` 在 SAF 里**选不到**（系统不让浏览 `Android/data`）。
     * 见 ADR-030 —— 那个目录对用户不完全可见、卸载即丢，是"可构建的沙箱"。
     *
     * 返回形状与 [listWorkspaces] 的条目一致；建不出目录时**如实回 null**。
     */
    private fun handleEnsureAppWorkspace(result: MethodChannel.Result) {
        scope.launch {
            val ws = withContext(Dispatchers.IO) { registry.ensureAppWorkspace() }
            if (ws == null) {
                reply(
                    result,
                    mapOf(
                        "ok" to false,
                        "error" to "无法创建默认工作区：外部私有目录不可用" +
                            "（存储被摘掉或系统限制）",
                    ),
                )
                return@launch
            }
            // 兼容旧契约：成功时回的**就是工作区条目本身**（不带 ok 包装）
            reply(result, ws)
        }
    }

    // ------------------------------------------------------------ 文件

    /** 列目录（给"文件"视图用）—— POSIX + SAF 双路由，走 [DeviceFs]。 */
    private fun handleListDir(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path").orEmpty()
        if (path.isBlank()) {
            reply(result, emptyList<Map<String, Any?>>())
            return
        }
        scope.launch {
            val r = deviceFs.list(path, recursive = false, maxEntries = 300)
            if (r["ok"] != true) {
                // 旧契约：列不出来就是空列表（这个接口只服务 UI 的文件视图，
                // 真正的诊断路径是 `fs.list`，它会把原因说清楚）
                reply(result, emptyList<Map<String, Any?>>())
                return@launch
            }
            @Suppress("UNCHECKED_CAST")
            val entries = r["entries"] as? List<Map<String, Any?>> ?: emptyList()
            // 过滤掉会话目录（`.heracles`）—— 它不是用户的项目内容
            reply(
                result,
                entries.filter { (it["name"] as? String) != WorkspaceRegistry.DOT_DIR },
            )
        }
    }

    /** 选文件 / 照片（**[FilePickerBridge] 会复制进 cache** 并回真实路径）。 */
    private fun handlePickFiles(call: MethodCall, result: MethodChannel.Result) {
        val imagesOnly = call.argument<Boolean>("imagesOnly") ?: false
        val multiple = call.argument<Boolean>("multiple") ?: true
        runOnUiThread {
            try {
                filePicker.launch(
                    imagesOnly = imagesOnly,
                    multiple = multiple,
                    onResult = { list -> reply(result, list) },
                    onError = { msg ->
                        reply(result, mapOf("ok" to false, "error" to msg))
                    },
                )
            } catch (e: Throwable) {
                reply(result, mapOf("ok" to false, "error" to (e.message ?: "无法打开选择器")))
            }
        }
    }

    // ------------------------------------------------------------ 设备权限

    /**
     * 设备权限状态（无线调试 / Shizuku / Stellar 引导用）。
     *
     * `DeviceShellManager.appContext` 是**诊断要用的**（查管理器是否安装），
     * 这里每次注入 —— 它是个 `@Volatile var`，重复赋值无害。
     */
    private fun handleDevicePermission(result: MethodChannel.Result) {
        DeviceShellManager.appContext = applicationContext
        val payload = withContextSync {
            mapOf(
                "writeSecureSettings" to
                    DevicePermissionChecker.hasWriteSecureSettings(this@MainActivity),
                "guidance" to DevicePermissionChecker.guidance(this@MainActivity),
                // ★ 诊断：实际执行路由（Stellar 优先 → Shizuku）
                //   —— 解释"命令成功但某管理器显示 0 个已授权应用"
                "shizuku" to DeviceShellManager.diagnostics(),
            )
        }
        reply(result, payload)
    }

    /**
     * ★ N8（2026-10-25）：设备权限统一查询 —— 每项 granted / denied / unknown。
     *
     * 权限项（INTERFACE.md §4.N8 清单，新增先登记）：
     * - shizuku：Shizuku binder 活着且已授权（Stellar 桌面端不在此列——
     *   它是 shell 路由的实现细节，权限页关心的是"提权通道"）
     * - files：SAF 工作区模式常开（App 私有目录天然可写）；`allFiles`
     *   单列 Android 11+ 的"所有文件访问"（我们按设计不申请，SAF 模式下
     *   denied 是正常态——前端文案要说清，不要渲染成红色警告）
     * - notifications：通知（前台服务/构建进度依赖）
     * - accessibility：无障碍服务（扫描 UI 树用；未在 manifest 声明服务
     *   前恒为 denied —— 如实，不假装）
     * - overlay：悬浮窗（SYSTEM_ALERT_WINDOW）
     *
     * 全部本地同步查询（无 binder 调用），不需要切线程。
     */
    /**
     * **拉起某项权限的系统授权流程**（权限页弹性开关，2026-10-27）。
     *
     * · `notifications`：API 33+ 直接弹运行时授权框（POST_NOTIFICATIONS
     *   已在 Manifest 声明）；低版本无此权限 → 去应用通知设置页；
     * · `notificationsOff`：关通知只能去应用通知设置页（系统不许
     *   App 自己撤销运行时权限）；
     * · `accessibility`：无障碍没有授权弹窗，只能去无障碍设置页；
     * · `overlay`：悬浮窗去它自己的授权页（带包名直达本 App）；
     * · `media` / `camera` / `calendar`：运行时权限，直接弹系统授权框
     *   （2026-10-27 权限页扩容；Manifest 已声明）；
     * · `appSettings`：本 App 的系统详情页 —— 关已授的运行时权限
     *   只能让用户去那里撤销；
     * · `installPackages`：未知来源安装的授权页 —— **预留给安装
     *   流程**（构建出 APK 点安装时调），权限页本身不拨它；
     * · `automation`：屏幕自动化是厂商专属开关（小米「后台弹出
     *   界面」等），无统一申请方式 → 如实回未实现（接口预留）。
     *
     * 本方法只负责"拉起"，结果由权限页回到前台时重新查询
     * `devicePermissions` 得到 —— **不在这里猜用户点了允许还是拒绝**。
     */
    private fun handleRequestPermission(call: MethodCall, result: MethodChannel.Result) {
        val kind = call.argument<String>("kind").orEmpty()
        try {
            when (kind) {
                "notifications" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4021,
                        )
                    } else {
                        startActivity(
                            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            },
                        )
                    }
                }
                "notificationsOff" -> startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    },
                )
                "media" -> requestPermissions(
                    if (Build.VERSION.SDK_INT >= 33)
                        arrayOf(
                            Manifest.permission.READ_MEDIA_IMAGES,
                            Manifest.permission.READ_MEDIA_VIDEO,
                        )
                    else
                        @Suppress("DEPRECATION")
                        arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                    4022,
                )
                "camera" -> requestPermissions(
                    arrayOf(Manifest.permission.CAMERA), 4023)
                "calendar" -> requestPermissions(
                    arrayOf(
                        Manifest.permission.READ_CALENDAR,
                        Manifest.permission.WRITE_CALENDAR,
                    ),
                    4024,
                )
                "appSettings" -> startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                "installPackages" -> startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                "automation" -> return reply(
                    result,
                    mapOf(
                        "ok" to false,
                        "error" to "厂商专属权限，暂无统一申请方式（接口预留）",
                    ),
                )
                "accessibility" -> startActivity(
                    Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                "overlay" -> startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName"),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                else -> return reply(
                    result, mapOf("ok" to false, "error" to "未知权限项：$kind"))
            }
            reply(result, mapOf("ok" to true))
        } catch (e: Throwable) {
            reply(result, mapOf("ok" to false, "error" to "拉起失败：${e.message}"))
        }
    }

    private fun handleDevicePermissions(result: MethodChannel.Result) {
        val ctx = applicationContext
        val shizuku = runCatching {
            val (ping, granted, _) = DeviceShellManager.shizukuStatus()
            when {
                granted -> "granted"
                ping -> "denied"       // 活着但没授权
                else -> "unknown"      // binder 不在（Shizuku 没启动/没装）
            }
        }.getOrDefault("unknown")

        val notifications = runCatching {
            if (NotificationManagerCompat.from(ctx).areNotificationsEnabled()) "granted" else "denied"
        }.getOrDefault("unknown")

        val accessibility = runCatching {
            val enabled = Settings.Secure.getString(
                ctx.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: ""
            // 我们自己的服务（如果将来声明）或任何辅助服务在跑都算 granted
            // —— 权限页语义是"这一类能力当前可用"
            if (enabled.isNotBlank()) "granted" else "denied"
        }.getOrDefault("unknown")

        val overlay = runCatching {
            if (Settings.canDrawOverlays(ctx)) "granted" else "denied"
        }.getOrDefault("unknown")

        val allFiles = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()) "granted" else "denied"
        }.getOrDefault("unknown")

        // ---- 2026-10-27 权限页扩容（INTERFACE.md §4.N8 登记） ----
        // 文件夹访问：有至少一个用户经 SAF 授权的文件夹（工作区）才算
        // granted —— 不再恒 granted（那等于没有这个权限项）。
        val files = runCatching {
            if (registry.list().any { it.isSaf }) "granted" else "denied"
        }.getOrDefault("unknown")

        fun has(perm: String): Boolean =
            ctx.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED

        val media = runCatching {
            val ok = if (Build.VERSION.SDK_INT >= 33) {
                has(Manifest.permission.READ_MEDIA_IMAGES) &&
                    has(Manifest.permission.READ_MEDIA_VIDEO)
            } else {
                @Suppress("DEPRECATION")
                has(Manifest.permission.READ_EXTERNAL_STORAGE)
            }
            if (ok) "granted" else "denied"
        }.getOrDefault("unknown")

        val camera = runCatching {
            if (has(Manifest.permission.CAMERA)) "granted" else "denied"
        }.getOrDefault("unknown")

        val calendar = runCatching {
            if (has(Manifest.permission.READ_CALENDAR) &&
                has(Manifest.permission.WRITE_CALENDAR)) "granted" else "denied"
        }.getOrDefault("unknown")

        val install = runCatching {
            if (Build.VERSION.SDK_INT < 26 ||
                ctx.packageManager.canRequestPackageInstalls()) "granted" else "denied"
        }.getOrDefault("unknown")

        reply(result, mapOf(
            "shizuku" to shizuku,
            "files" to files,
            "allFiles" to allFiles,
            "notifications" to notifications,
            "accessibility" to accessibility,
            "overlay" to overlay,
            "media" to media,
            "camera" to camera,
            "calendar" to calendar,
            // 屏幕自动化：厂商专属，无平台 API 可查 —— 恒 unknown，
            // 前端渲染为「接口预留」，不猜状态。
            "automation" to "unknown",
            "install" to install,
        ))
    }

    /** 同步块的小包装（只为可读性，不切线程 —— 这两个调用都是本地的）。 */
    private fun <T> withContextSync(block: () -> T): T = block()

    /**
     * **Shizuku / Stellar 授权 + 自动执行 `pm grant`**。
     *
     * ## ★★ 诚实性（2026-10-16 真机实测教训，必须保留）★★
     *
     * 用户实测：按钮显示「✅ exit=0」但权限**并未授予**。
     * 根因：`pm grant` 对**未在 Manifest 声明**的权限会 exit 0 却什么都不做
     * （系统日志：`Permission ... isn't requested by package`）——
     * 典型的"失败装成成功"。
     *
     * ⇒ **不信 exit code，执行后真去 `checkSelfPermission`**。
     * 只有系统确认授予才算成功；否则如实报告并给出原因。
     *
     * ## 线程
     *
     * ⚠️ Shizuku binder 调用不能在主线程（可能 ANR）⇒ 全部切 IO。
     * ⚠️ 回调在 Shizuku 的 listener 线程（非 suspend）⇒ 回主线程用 [mainHandler]。
     *
     * @param force true = 无条件走一次授权弹窗（`shizukuForceRequest` 用）：
     *   即使已有权限也请求，让 Shizuku 的「已授权应用」列表里出现本 App
     */
    private fun handleShizukuGrant(force: Boolean, result: MethodChannel.Result) {
        val pkg = packageName
        scope.launch(Dispatchers.IO) {
            val hasStellar = DeviceShellManager.stellarStatus().available
            val hasShizuku = DeviceShellManager.shizukuStatus().first
            if (!hasStellar && !hasShizuku) {
                reply(
                    result,
                    mapOf(
                        "success" to false,
                        "message" to "未检测到 Stellar 或 Shizuku 服务 —— " +
                            "请先安装并启动其中一个管理器",
                    ),
                )
                return@launch
            }

            val cmd = "pm grant $pkg android.permission.WRITE_SECURE_SETTINGS"
            val callback: (Boolean, String) -> Unit = { _, output ->
                // ★ 关键：以**系统真实状态**为准，而不是命令的输出
                val granted = DevicePermissionChecker.hasWriteSecureSettings(applicationContext)
                reply(
                    result,
                    mapOf(
                        "success" to granted,
                        "message" to if (granted) {
                            "权限已授予（无障碍自愈可用）—— " +
                                "本次通过 ${DeviceShellManager.currentRoute().label}"
                        } else {
                            "命令已执行但权限未生效。\n" +
                                "系统反馈：${output.ifBlank { "（无输出）" }}\n" +
                                "常见原因：权限未在 Manifest 声明，或系统/厂商限制。"
                        },
                    ),
                )
            }
            if (force) {
                DeviceShellManager.forceRequestAndRun(cmd, callback)
            } else {
                DeviceShellManager.requestPermissionAndRun(cmd, callback)
            }
        }
    }

    // ------------------------------------------------------------ 通知回跳

    /**
     * 读出"通知点击带过来的会话"，并尝试立刻通知 Dart。
     *
     * 冷启动时 Dart 可能还没注册 handler ⇒ 先存 [pendingOpenSession]，
     * Dart 启动后会调 `consumePendingOpen` 主动取走。
     *
     * ⚠️ 会话本身现在归 Dart，Kotlin 只负责把"桩"送过去 —— 它不知道会话内容。
     */
    private fun handleNotifyIntent(intent: Intent?) {
        val sid = intent?.getStringExtra(EXTRA_NOTIFY_SESSION) ?: return
        intent.removeExtra(EXTRA_NOTIFY_SESSION)
        val ws = intent.getStringExtra(EXTRA_NOTIFY_WORKSPACE).orEmpty()
        intent.removeExtra(EXTRA_NOTIFY_WORKSPACE)
        val payload = mapOf("sessionId" to sid, "workspacePath" to ws)
        pendingOpenSession = payload
        val ch = commandChannel
        if (ch != null) {
            try {
                ch.invokeMethod("openSession", payload)
                pendingOpenSession = null
            } catch (_: Exception) {
                // Dart 还没就绪 —— 留在 pending，等 Dart 来取
            }
        }
    }

    // ------------------------------------------------------------ 选择器回调

    @Deprecated("Flutter embedding 仍走经典回调路径")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            FilePickerBridge.REQUEST_CODE -> {
                if (resultCode == RESULT_OK) filePicker.onActivityResult(data)
                else filePicker.onCancelled()
                return
            }
            FolderPickerBridge.REQUEST_CODE -> {
                if (resultCode == RESULT_OK) folderPicker.onActivityResult(data)
                else folderPicker.onCancelled()
                return
            }
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    companion object {
        /**
         * 命令通道名（**保留旧名**）。
         *
         * 设备能力走另一条 `heracles/device`（见 [DeviceChannel.CHANNEL]）。
         */
        private const val CHANNEL = "heracles/command"

        /** 聊天完成通知（2026-10-19）：通道 + 通知 id（固定 id ⇒ 新任务覆盖旧提醒）。 */
        private const val CHAT_CHANNEL_ID = "heracles_chat_done"
        private const val CHAT_NOTIFY_ID = 2001

        /** 完成通知点击时要打开的会话（2026-10-19） */
        private const val EXTRA_NOTIFY_SESSION = "heracles_notify_session"
        private const val EXTRA_NOTIFY_WORKSPACE = "heracles_notify_workspace"

        /** 运行时通知权限的 requestCode（与权限名一一对应即可） */
        private const val REQ_POST_NOTIFICATIONS = 1001
    }
}
