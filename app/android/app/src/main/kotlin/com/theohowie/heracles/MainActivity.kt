package com.theohowie.heracles

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.theohowie.heracles.bridge.AgentChatService
import com.theohowie.heracles.bridge.AgentBridge
import com.theohowie.heracles.bridge.DevicePermissionChecker
import com.theohowie.heracles.bridge.DeviceShellManager
import com.theohowie.heracles.bridge.EncodeSelfCheck
import com.theohowie.heracles.bridge.FilePickerBridge
import com.theohowie.heracles.bridge.FolderPickerBridge
import com.theohowie.heracles.bridge.SessionStore
import com.theohowie.heracles.bridge.ShizukuManager
import com.theohowie.heracles.bridge.StorageProbe
import dev.heracles.agent.AgentEvent
import dev.heracles.agent.AgentLoop
import dev.heracles.agent.AgentRunResult
import dev.heracles.agent.ApprovalMode
import dev.heracles.core.provider.ReasoningLevel
import dev.heracles.workspace.WorkspaceStorage
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Flutter 与 Kotlin 核心的桥。
 *
 * ## 概念模型（2026-10-10 修正）
 *
 * ```
 * 工作区 = 用户【选择的一个已有文件夹】
 *    ├── 在里面直接发消息 → 自动新建会话
 *    └── 会话 ⋯重命名 / 🗑删除 / ⭐收藏
 * ```
 *
 * ## 通道
 *
 * | 方法 | 用途 |
 * |---|---|
 * | `pickWorkspace` | **选文件夹**作为工作区（不是"创建"） |
 * | `listWorkspaces` | 列出已登记的工作区 |
 * | `ensureAppWorkspace` | **登记内置「应用工作区」**（App 私有 · 可构建）—— SAF 选不到 `Android/data` |
 * | `removeWorkspace` | 从列表移除（不删文件夹） |
 * | `listSessions` | 某工作区的会话 |
 * | `createSession` | 新建会话 |
 * | `renameSession` / `deleteSession` / `toggleStar` | 会话操作 |
 * | `runAgent` | 跑一次 agent（**自动建会话**） |
 * | `pickFiles` | 选文件/照片 |
 *
 * 另有 **EventChannel `heracles/events`**（2026-10-10 流式）——
 * Kotlin → Dart 单向推送 agent 运行事件，见 [eventSink] 的说明。
 *
 * ## 线程模型
 *
 * handler 跑在主线程；HTTP / 文件 IO / 推理全部切 IO，
 * 否则 UI 会卡死 —— 本地模型一轮 5-20 秒。
 */
class MainActivity : FlutterActivity() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var bridge: AgentBridge
    private lateinit var store: SessionStore
    private lateinit var filePicker: FilePickerBridge
    private lateinit var folderPicker: FolderPickerBridge

    /**
     * **当前在跑的那一轮**（2026-10-13 新增）。
     *
     * ## 为什么需要它
     *
     * 用户实测反馈：「暂停不了？」——
     * 停止按钮**画出来了**（`_SendButton` 的 `busy` 分支显示停止图标），
     * 但点下去只会**又发一条消息**：`onTap` 恒为 `_send`，
     * 而 Kotlin 侧**根本没有取消能力**（整个仓库搜不到 cancel 接口）。
     *
     * ## 取消为什么是可行的（不是硬杀）
     *
     * `HttpJson.postSse` 的 `finally` 里已经 `close()` 输入流 +
     * `disconnect()` 连接 —— **取消协程会打断阻塞中的 `read()`**
     * （S1 建流式时就写好了这条路径，当时是为"页面销毁"准备的）。
     * 所以 `job.cancel()` 能让一次正在生成的请求**真的停下来**，
     * 而不是等它吐完。
     *
     * ## 为什么只留一个引用
     *
     * 一次只允许一个运行（结构性约束：`eventSink` 单字段 +
     * 事件无 session id，并行会混流）。所以一个槽位既足够，
     * 也**如实反映**了系统的真实能力。
     */
    private var runJob: kotlinx.coroutines.Job? = null

    /**
     * **当前 run 的插话队列**（2026-10-13，思考间隙引导）。
     *
     * `handleRunAgent` 每次 run 新建一个并传给 bridge；
     * `interruptRun` 通道往它 offer。run 结束后置 null ——
     * 没有在跑的任务时插话没有意义（那时用户发消息就是正常发送）。
     */
    @Volatile
    private var runInterrupts: AgentLoop.InterruptQueue? = null

    /**
     * 事件流的 Dart 端 sink（`heracles/events`）。
     *
     * `null` = Dart 没在监听（用户还没打开会话页，或页面已销毁）——
     * 此时 [emitEvent] 直接丢弃，不做任何排队：
     * 事件是**实时反馈**，迟到的旧事件没有价值，堆着只会浪费内存。
     */
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    /** 主线程 Handler —— 见 [emitEvent] 为什么要它 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * 会话 `.jsonl` 的**进程内写锁**（2026-10-12，S5）。
     *
     * `SessionStore.appendMessage` 是「读全文 → 追加 → 写全文」，
     * 并发调用会互相覆盖。见 [persistStep] 的说明。
     */
    private val sessionWriteLock = Mutex()

    /**
     * **App 进程内自检的 adb 入口**（2026-10-17）。
     *
     * ```powershell
     * adb shell am start -n com.theohowie.heracles/.MainActivity --ez heracles_encode_selfcheck true
     * ```
     *
     * ## 为什么 UI 按钮之外还要这个入口
     *
     * 「App 进程内这条链路到底通不通」必须能被**脚本复现**（不能只靠人去点按钮）。
     * 两者跑的是**同一个** [EncodeSelfCheck.run]：UI 按钮走 MethodChannel，
     * 这里走 Intent extra。结果既写 logcat（tag `HeraclesEncode`），
     * 也写工作区里的 `encode-selfcheck.txt`（方便 `adb pull` 复核）。
     *
     * ## 为什么要「消费掉」这个 extra
     *
     * 转屏 / 进程重建时同一个 Intent 会再进来一次 —— 不消费就**再跑一遍构建**。
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        maybeRunEncodeSelfCheck()
        // ★ 运行时请求通知权限（2026-10-19，API 33+）——
        //   不请求的话「任务完成通知」永远发不出去，且用户不知道能开。
        //   只在没授权时请求一次（系统会记住"已拒绝"；下次不重复骚扰）。
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTIFICATIONS)
        }
    }

    /**
     * **任务完成通知**（2026-10-19）—— 只在 App **不在前台**时发。
     *
     * ## 为什么需要
     *
     * 用户实测痛点：让 agent 干活后切去别的 App / 锁屏，回来才发现早跑完了
     * （或早失败了）。构建任务有前台服务通知，**聊天任务却没有任何提醒**。
     *
     * ## 为什么用 onResume/onPause 而不是查 Activity 可见性
     *
     * 最小且可靠：`onResume` = 用户正看着；`onPause` = 切走/锁屏（部分机型锁屏
     * 不一定 pause，但这是系统级最佳近似，不需要额外权限）。
     */
    private var appInForeground = false

    override fun onResume() {
        super.onResume()
        appInForeground = true
    }

    override fun onPause() {
        appInForeground = false
        super.onPause()
    }

    /** 建聊天完成通知通道（幂等；IMPORTANCE_DEFAULT 才有提示音/横幅）。 */
    private fun ensureChatChannel() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHAT_CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHAT_CHANNEL_ID,
                "任务完成提醒",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "聊天任务在后台完成或失败时提醒你（关掉它不会中断任务）"
            }
        )
    }

    /**
     * 发一条"任务完成/失败"通知。**前台或未授权时静默跳过** ——
     * 用户正看着界面时再响一声是噪音；没授权就发是无效劳动。
     */
    private fun notifyChatResult(success: Boolean, text: String) {
        if (appInForeground) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        ensureChatChannel()
        val body = text.trim().replace('\n', ' ').take(80).ifEmpty {
            if (success) "任务已完成" else "任务失败"
        }
        val open = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val n = Notification.Builder(this, CHAT_CHANNEL_ID)
            .setContentTitle(if (success) "任务完成" else "任务失败")
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(text.take(500)))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .notify(CHAT_NOTIFY_ID, n)
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
        maybeRunEncodeSelfCheck()
    }

    private fun maybeRunEncodeSelfCheck() {
        if (intent?.getBooleanExtra(EXTRA_ENCODE_SELF_CHECK, false) != true) return
        intent.removeExtra(EXTRA_ENCODE_SELF_CHECK)
        scope.launch(Dispatchers.IO) {
            runCatching { EncodeSelfCheck.run(applicationContext) }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = AgentBridge(applicationContext)
        store = SessionStore(applicationContext)
        filePicker = FilePickerBridge(this)
        folderPicker = FolderPickerBridge(this)

        // ★ 流式通道：Kotlin → Dart 单向推送（`15-前端选型与通道协议.md` §3.1）
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    // ★ 必须清空：页面销毁后 sink 已失效，
                    //   继续往里写会抛 IllegalStateException
                    eventSink = null
                }
            }
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // ---- 工作区 ----
                "pickWorkspace" -> handlePickWorkspace(result)
                "listWorkspaces" -> handleListWorkspaces(result)
                "removeWorkspace" -> handleRemoveWorkspace(call, result)
                // ★ 内置「应用工作区」（2026-10-17）——
                //   编码层要求工作区 App 与 shell 都能写，而真机上唯一满足的
                //   `Android/data/<pkg>/files/**` **选不到**（SAF 不让浏览 Android/data）。
                //   所以这条必须由 App 自己登记。见 [SessionStore.ensureAppWorkspace]。
                "ensureAppWorkspace" -> {
                    scope.launch {
                        val ws = try {
                            withContext(Dispatchers.IO) { store.ensureAppWorkspace() }
                        } catch (e: Throwable) {
                            result.error(
                                "APP_WORKSPACE_FAILED",
                                e.message ?: "创建默认工作区失败",
                                null,
                            )
                            return@launch
                        }
                        result.success(ws)
                    }
                }

                // ---- 会话 ----
                "listSessions" -> handleListSessions(call, result)
                "loadMessages" -> handleLoadMessages(call, result)
                "createSession" -> handleCreateSession(call, result)
                // ★ 新建会话 + 灌入前缀（2026-10-13，回答的「新会话分支」）
                "seedBranch" -> handleSeedBranch(call, result)
                "renameSession" -> handleRenameSession(call, result)
                "deleteSession" -> handleDeleteSession(call, result)
                "toggleStar" -> handleToggleStar(call, result)
                "toggleArchive" -> handleToggleArchive(call, result)

                // ---- 运行 ----
                "runAgent" -> handleRunAgent(call, result)
                // ★ 取消正在跑的那一轮（2026-10-13）——
                //   用户实测："暂停不了？"：停止按钮画出来了但点了只会再发一条。
                //   见 [runJob] 的说明。
                "cancelRun" -> handleCancelRun(result)
                // ★ 向在跑的任务插话（2026-10-13，思考间隙引导）
                "interruptRun" -> handleInterruptRun(call, result)
                // ★ ask_user 的回答（2026-10-16）：UI 弹窗提交 → 工具拿到
                "replyAsk" -> {
                    val text = call.argument<String>("text").orEmpty()
                    bridge.replyAsk(text)
                    result.success(true)
                }
                // ★ 危险操作审批（2026-10-19）：UI 点允许/拒绝 → 挂起的 AgentLoop 拿到
                "replyApproval" -> {
                    val allow = call.argument<Boolean>("allow") ?: false
                    bridge.replyApproval(allow)
                    result.success(true)
                }
                "listDir" -> handleListDir(call, result)
                "pickFiles" -> handlePickFiles(call, result)
                "benchmarkStorage" -> handleBenchmark(call, result)
                // ★ 用量与上下文面板要的两个数（2026-10-11，t13）
                "usageInfo" -> handleUsageInfo(call, result)
                // ★ 设备权限检测（2026-10-16，无线调试/Shizuku/adb 授权引导）
                "devicePermission" -> {
                    // 诊断要查"管理器是否安装"，需要 context
                    DeviceShellManager.appContext = applicationContext
                    result.success(
                        mapOf(
                            "writeSecureSettings" to
                                DevicePermissionChecker.hasWriteSecureSettings(this),
                            "guidance" to DevicePermissionChecker.guidance(this),
                            // ★ 诊断：实际执行路由（Stellar 优先 → Shizuku）
                            //   —— 解释"命令成功但某管理器显示 0 个已授权应用"
                            "shizuku" to DeviceShellManager.diagnostics(),
                        )
                    )
                }
                // ★ Shizuku 授权 + 自动执行 pm grant（2026-10-16 用户反馈完善）
                //
                // ⚠️ Shizuku binder 调用不能在主线程（可能 ANR）—— 全部切 IO。
                // ⚠️ onResult 回调在 Shizuku 的 listener 线程（非 suspend）——
                //    回主线程用 mainHandler.post（不是 withContext，那是 suspend）。
                //
                // ★★ 诚实性（2026-10-16 真机实测教训）★★
                //
                // 用户实测：按钮显示「✅ exit=0」但权限**并未授予**。
                // 根因：`pm grant` 对**未在 Manifest 声明**的权限会 exit 0
                // 却什么都不做（系统日志：`Permission ... isn't requested
                // by package`）—— 典型的"失败装成成功"。
                //
                // 修法：**不信 exit code，执行后真去 `checkSelfPermission`**。
                // 只有系统确认授予才算成功；否则如实报告并给出原因。
                "shizukuGrant" -> {
                    val pkg = packageName
                    scope.launch(Dispatchers.IO) {
                        if (DeviceShellManager.currentRoute() ==
                            DeviceShellManager.Route.NONE &&
                            !DeviceShellManager.stellarStatus().available &&
                            !DeviceShellManager.shizukuStatus().first
                        ) {
                            mainHandler.post {
                                result.success(mapOf(
                                    "success" to false,
                                    "message" to "未检测到 Stellar 或 Shizuku 服务 —— " +
                                        "请先安装并启动其中一个管理器",
                                ))
                            }
                            return@launch
                        }
                        val cmd =
                            "pm grant $pkg android.permission.WRITE_SECURE_SETTINGS"
                        DeviceShellManager.requestPermissionAndRun(cmd) { _, output ->
                            // ★ 关键：以**系统真实状态**为准，而不是命令的输出
                            val granted =
                                DevicePermissionChecker.hasWriteSecureSettings(
                                    applicationContext
                                )
                            mainHandler.post {
                                result.success(
                                    mapOf(
                                        "success" to granted,
                                        "message" to if (granted) {
                                            "权限已授予（无障碍自愈可用）—— " +
                                                "本次通过 ${
                                                    DeviceShellManager.currentRoute().label
                                                }"
                                        } else {
                                            // 诚实报告：命令跑了但没生效，并说明最可能的原因
                                            "命令已执行但权限未生效。\n" +
                                                "系统反馈：${output.ifBlank { "（无输出）" }}\n" +
                                                "常见原因：权限未在 Manifest 声明，" +
                                                "或系统/厂商限制。"
                                        },
                                    )
                                )
                            }
                        }
                    }
                }

                // ★ Shizuku **强制重新申请**（2026-10-16）——
                //   用户反馈「Shizuku 里还是已授权 0 个应用」：
                //   服务端说已授权，但 UI 列表空 —— 因为本 App 的授权是遗留记录，
                //   没走过 Shizuku 的授权弹窗。这里无条件走一次弹窗流程。
                "shizukuForceRequest" -> {
                    scope.launch(Dispatchers.IO) {
                        val hasStellar = DeviceShellManager.stellarStatus().available
                        val hasShizuku = DeviceShellManager.shizukuStatus().first
                        if (!hasStellar && !hasShizuku) {
                            mainHandler.post {
                                result.success(mapOf(
                                    "success" to false,
                                    "message" to "未检测到 Stellar 或 Shizuku 服务",
                                ))
                            }
                            return@launch
                        }
                        val cmd =
                            "pm grant $packageName android.permission.WRITE_SECURE_SETTINGS"
                        DeviceShellManager.forceRequestAndRun(cmd) { _, output ->
                            val granted =
                                DevicePermissionChecker.hasWriteSecureSettings(
                                    applicationContext
                                )
                            mainHandler.post {
                                result.success(
                                    mapOf(
                                        "success" to granted,
                                        "message" to if (granted) {
                                            "已重新申请并确认授权 —— " +
                                                "现在去 ${
                                                    DeviceShellManager.currentRoute().label
                                                } 的「已授权应用」里应该能看到本 App 了"
                                        } else {
                                            "重新申请未生效：${output.ifBlank { "（无输出）" }}"
                                        },
                                    )
                                )
                            }
                        }
                    }
                }

                // ★ App 进程内的编码层自检（2026-10-17）——
                //   把 DeviceShellRunner / AgentBuildService / SystemHealthSource 串起来
                //   在**应用进程里**真跑一遍（这三个类此前只有"编译过、装得上"）。
                //   见 [EncodeSelfCheck]：**不是**产品功能，是给"链路通不通"一个可执行答案。
                "encodeSelfCheck" -> {
                    scope.launch(Dispatchers.IO) {
                        val report = runCatching {
                            EncodeSelfCheck.run(applicationContext)
                        }.getOrElse {
                            "自检失败：${it.javaClass.simpleName}: ${it.message}"
                        }
                        mainHandler.post { result.success(report) }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * 把一个 [AgentEvent] 推到 Dart 端。
     *
     * ## 为什么必须切主线程
     *
     * 事件是从 `AgentLoop` 里发出来的，而 `bridge.run` 整个跑在
     * `Dispatchers.IO`（见 `AgentBridge.run`）。Flutter 的
     * `EventSink.success` **必须在创建它的平台线程（这里是主线程）调用** ——
     * 否则在部分 Flutter 版本上会直接抛
     * `IllegalStateException: Methods marked with @UiThread must be executed on the main thread`。
     *
     * ## 为什么发失败也不上报
     *
     * 流式是**增强**，不是主链路：最终结果仍由 `runAgent` 的
     * MethodChannel 返回值送达。为了一个展示性事件把整轮 agent 搞挂
     * 是本末倒置 —— 所以这里 `runCatching` 吞掉。
     */
    private fun emitEvent(event: AgentEvent) {
        val sink = eventSink ?: return
        val payload = try {
            bridge.toEventMap(event)
        } catch (e: Throwable) {
            return
        }
        mainHandler.post {
            // 二次取 sink：从 IO 线程 post 到主线程执行之间，
            // Dart 可能已经取消监听（切走会话页）
            runCatching { eventSink?.success(payload) }
        }
    }

    // ------------------------------------------------------------ 工作区

    /** 选一个已有文件夹作为工作区（SAF 目录选择器） */
    private fun handlePickWorkspace(result: MethodChannel.Result) {
        runOnUiThread {
            try {
                folderPicker.launch { ws ->
                    if (ws == null) {
                        // 用户取消，或选的位置没有本地路径（如网盘）
                        result.success(null)
                    } else {
                        // addWorkspace 是 suspend —— 回到协程里调
                        scope.launch {
                            try {
                                val saved = store.addWorkspace(
                                    ws["path"] as String,
                                    ws["name"] as String,
                                    (ws["treeUri"] as? String).orEmpty(),
                                )
                                result.success(saved)
                            } catch (e: Throwable) {
                                result.error(
                                    "ADD_WORKSPACE_FAILED",
                                    e.message ?: "无法登记工作区",
                                    null,
                                )
                            }
                        }
                    }
                }
            } catch (e: Throwable) {
                result.error("PICK_FAILED", e.message ?: "无法打开文件夹选择器", null)
            }
        }
    }

    private fun handleListWorkspaces(result: MethodChannel.Result) {
        scope.launch {
            val list = try {
                withContext(Dispatchers.IO) { store.listWorkspaces() }
            } catch (e: Throwable) {
                result.error("LIST_FAILED", e.message ?: "读取工作区失败", null)
                return@launch
            }
            result.success(list)
        }
    }

    /** 从列表移除 —— **不删文件夹本身** */
    private fun handleRemoveWorkspace(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path").orEmpty()
        scope.launch {
            try {
                withContext(Dispatchers.IO) { store.removeWorkspace(path) }
            } catch (e: Throwable) {
                result.error("REMOVE_FAILED", e.message ?: "移除失败", null)
                return@launch
            }
            result.success(true)
        }
    }

    // ------------------------------------------------------------ 会话

    /**
     * 由 workspacePath + treeUri 拿到正确的存储实现。
     *
     * ★ SAF 授权时必须走 [AndroidSafStorage] —— 用 `java.io.File` 会
     * `EPERM (Operation not permitted)`（真机实测）。
     */
    private fun storageOf(workspacePath: String, treeUri: String): WorkspaceStorage =
        store.storageFor(
            path = workspacePath,
            treeUri = treeUri,
            displayName = File(workspacePath).name.ifBlank { "workspace" },
        )

    private fun handleListSessions(call: MethodCall, result: MethodChannel.Result) {
        val ws = call.argument<String>("workspacePath").orEmpty()
        val treeUri = call.argument<String>("treeUri").orEmpty()
        scope.launch {
            val list = try {
                withContext(Dispatchers.IO) { store.sessions(storageOf(ws, treeUri)) }
            } catch (e: Throwable) {
                result.error("SESSIONS_FAILED", e.message ?: "读取会话失败", null)
                return@launch
            }
            result.success(list)
        }
    }

    private fun handleCreateSession(call: MethodCall, result: MethodChannel.Result) {
        val ws = call.argument<String>("workspacePath").orEmpty()
        val treeUri = call.argument<String>("treeUri").orEmpty()
        val title = call.argument<String>("title").orEmpty()
        scope.launch {
            try {
                val id = withContext(Dispatchers.IO) {
                    store.createSession(storageOf(ws, treeUri), title)
                }
                result.success(id)
            } catch (e: Throwable) {
                result.error("CREATE_SESSION_FAILED", e.message ?: "创建会话失败", null)
            }
        }
    }

    /**
     * **新建会话 + 灌入前缀消息**（2026-10-13，回答末尾的「新会话分支」）。
     *
     * ## 为什么不是"在原会话上开分支"
     *
     * 会话必须**严格 append-only**（铁律 1）：append-only 命中 90–99%
     * 可依赖，而分支只有 **25–105%、不可预测**（ADR-001）。
     * 所以"分支"落地成**新建会话 + 复制前缀** —— 新会话从一开始就是
     * 一条干净的 append-only 流。代价是上下文要重新预填充一次
     * （新会话第一轮无缓存命中），这个取舍是**明知的**，不是疏漏。
     *
     * ## 为什么要走 Kotlin 而不是 Dart 拼文件
     *
     * `.jsonl` 的格式与路径由 [SessionStore] 说了算。Dart 侧自己拼
     * 等于复制一份格式知识 —— 格式一改就两地不一致。
     */
    private fun handleSeedBranch(call: MethodCall, result: MethodChannel.Result) {
        val ws = call.argument<String>("workspacePath").orEmpty()
        val treeUri = call.argument<String>("treeUri").orEmpty()
        val title = call.argument<String>("title").orEmpty()
        val entries = call.argument<List<Map<String, String>>>("entries") ?: emptyList()
        scope.launch {
            try {
                val id = withContext(Dispatchers.IO) {
                    val storage = storageOf(ws, treeUri)
                    val sid = store.createSession(storage, title)
                    // 前缀逐条 append —— 与正常落盘同一条路径（同一把锁，
                    // 顺序与 UI 顺序一致）
                    //
                    // ★ 步骤透传（2026-10-15 用户反馈修复）：
                    //   分支要**把思考过程也带过去**（用户原话：
                    //   「分支会话没有把思考过程也分支过去，仅仅分支了正文结论」）。
                    //   步骤以 `role:"step"` 落盘（含 think/stepId/title 等字段），
                    //   这里把 Dart 传来的**全部字段**原样写盘 ——
                    //   读回路径（`loadMessages` → `case 'step'`）就能还原出
                    //   与原会话一模一样的步骤卡片。
                    sessionWriteLock.withLock {
                        for (e in entries) {
                            val role = e["role"] ?: "user"
                            val text = e["text"].orEmpty()
                            if (text.isBlank() && role != "step") continue
                            val record = mutableMapOf<String, Any?>(
                                "role" to role,
                                "text" to text,
                                "ts" to System.currentTimeMillis(),
                            )
                            // step 的附加字段原样透传（think/stepId/title/i/stage/ms）
                            for (k in listOf("think", "stepId", "title", "i", "stage", "ms")) {
                                val v = e[k]
                                if (!v.isNullOrBlank()) record[k] = v
                            }
                            store.appendMessage(storage, sid, record)
                        }
                    }
                    sid
                }
                result.success(id)
            } catch (e: Throwable) {
                result.error("SEED_BRANCH_FAILED", e.message ?: "建立分支失败", null)
            }
        }
    }

    private fun handleRenameSession(call: MethodCall, result: MethodChannel.Result) {        val ws = call.argument<String>("workspacePath").orEmpty()
        val treeUri = call.argument<String>("treeUri").orEmpty()
        val id = call.argument<String>("sessionId").orEmpty()
        val title = call.argument<String>("title").orEmpty()
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    store.renameSession(storageOf(ws, treeUri), id, title)
                }
                result.success(true)
            } catch (e: Throwable) {
                result.error("RENAME_FAILED", e.message ?: "重命名失败", null)
            }
        }
    }

    private fun handleDeleteSession(call: MethodCall, result: MethodChannel.Result) {
        val ws = call.argument<String>("workspacePath").orEmpty()
        val treeUri = call.argument<String>("treeUri").orEmpty()
        val id = call.argument<String>("sessionId").orEmpty()
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    store.deleteSession(storageOf(ws, treeUri), id)
                }
                result.success(true)
            } catch (e: Throwable) {
                result.error("DELETE_FAILED", e.message ?: "删除失败", null)
            }
        }
    }

    private fun handleToggleStar(call: MethodCall, result: MethodChannel.Result) {
        val ws = call.argument<String>("workspacePath").orEmpty()
        val treeUri = call.argument<String>("treeUri").orEmpty()
        val id = call.argument<String>("sessionId").orEmpty()
        scope.launch {
            try {
                val starred = withContext(Dispatchers.IO) {
                    store.toggleStar(storageOf(ws, treeUri), id)
                }
                result.success(starred)
            } catch (e: Throwable) {
                result.error("STAR_FAILED", e.message ?: "收藏失败", null)
            }
        }
    }

    private fun handleToggleArchive(call: MethodCall, result: MethodChannel.Result) {
        val ws = call.argument<String>("workspacePath").orEmpty()
        val treeUri = call.argument<String>("treeUri").orEmpty()
        val id = call.argument<String>("sessionId").orEmpty()
        scope.launch {
            try {
                val archived = withContext(Dispatchers.IO) {
                    store.toggleArchive(storageOf(ws, treeUri), id)
                }
                result.success(archived)
            } catch (e: Throwable) {
                result.error("ARCHIVE_FAILED", e.message ?: "归档失败", null)
            }
        }
    }

    // ------------------------------------------------------------ 运行

    /**
     * 跑一次 agent。
     *
     * ★ **核心行为**：如果没传 `sessionId`，**自动新建一个会话** ——
     * 这就是"在工作区里直接发消息"的行为，与桌面版一致。
     */
    private fun handleRunAgent(call: MethodCall, result: MethodChannel.Result) {
        val workspacePath = call.argument<String>("workspacePath").orEmpty()
        val request = call.argument<String>("request").orEmpty()
        val sessionId = call.argument<String>("sessionId")
        val treeUri = call.argument<String>("treeUri").orEmpty()
        val backend = call.argument<String>("backend") ?: "local"
        val baseUrl = call.argument<String>("baseUrl").orEmpty()
        val apiKey = call.argument<String>("apiKey").orEmpty()
        val modelName = call.argument<String>("modelName").orEmpty()
        val attachments = call.argument<List<Map<String, String>>>("attachments") ?: emptyList()
        // ★ 推理等级（S4 的开关）：`auto` / `off` / `low` / `high` / `max`。
        //   缺省 auto —— **与改造前行为一致**（本地 auto = 关思考）。
        val reasoningLevel = parseReasoningLevel(call.argument<String>("reasoningLevel"))
        // ★ 审批档位（2026-10-19）：manual / workspaceAuto / fullAccess
        //   认不出 ⇒ WORKSPACE_AUTO（与改动前行为一致、最保守）。
        val approvalMode = ApprovalMode.parse(call.argument<String>("permission"))
        // ★ 最大轮次（ADR-033 / P0-1，2026-10-18）—— 用户设置里可调。
        //   `0` / 缺省 = **按后端自动**（本地 8 / 云端 40，见 Contract.Budget），
        //   正数 = 用户显式覆盖。此前这里**从不传** ⇒ 真机恒定 8 轮，
        //   云端模型跑「脚手架 → 改码 → 构建」必然撞墙（docs/27 §2.2）。
        val maxTurns = call.argument<Int>("maxTurns") ?: 0

        if (request.isBlank() && attachments.isEmpty()) {
            result.error("EMPTY_REQUEST", "请求内容为空", null)
            return
        }
        if (workspacePath.isBlank()) {
            result.error("NO_WORKSPACE", "未选择工作区", null)
            return
        }

        // ★ 记下这一轮的 Job —— `cancelRun` 靠它真的停下来（见 [runJob]）
        // ★ 同时挂上本 run 的插话队列 —— `interruptRun` 往里投（2026-10-13）
        val interrupts = AgentLoop.InterruptQueue()
        runInterrupts = interrupts
        // ★ 聊天任务前台服务（2026-10-19）—— 没有它 MIUI 会冻结后台 App，
        //   任务停在半路、完成通知永不触发（真机实测，见 AgentChatService 注释）。
        //   在 Activity 仍在前台时启动（FGS 启动限制要求）。
        AgentChatService.start(this)
        runJob = scope.launch {
            try {
                // ★ SAF 或 POSIX 由 treeUri 决定 —— 会话记录必须走同一个存储
                val storage = storageOf(workspacePath, treeUri)
                // 没有会话就自动建一个 —— "在工作区里直接发消息"
                val sid = sessionId?.takeIf { it.isNotBlank() }
                    ?: withContext(Dispatchers.IO) {
                        store.createSession(storage, deriveTitle(request, attachments))
                    }

                // ★ 用户消息**先落盘**（2026-10-10 严重 bug 修复）
                //
                // 之前只存内存 → 切会话就丢。现在**发消息的瞬间**写盘，
                // 即使模型后面失败，用户的输入也不会丢。
                withContext(Dispatchers.IO) {
                    val attachNames = attachments.mapNotNull { it["name"] }.filter { it.isNotBlank() }
                    // 与运行中的步骤落盘共用一把锁 —— 见 [persistStep] 的说明
                    sessionWriteLock.withLock {
                        store.appendMessage(
                            storage, sid,
                            mapOf(
                                "role" to "user",
                                "text" to request,
                                "ts" to System.currentTimeMillis(),
                                // 附件名随消息一起记，history 里能看到当时传了什么
                                "attach" to if (attachNames.isEmpty()) null
                                else attachNames.joinToString("、"),
                            ),
                        )
                    }
                }

                // ★★ 读出历史对话传给 AgentLoop（2026-10-14）★★
                //
                // ## 修的是什么（用户实测）
                //
                // 用户原话：「让他继续完成任务，他输出了又是**没有记忆了**」
                //
                // 根因：`AgentLoop.run` 每次 `Session.start()` 从零开始 ——
                // 用户看到的对话历史（Dart 侧 messages）与模型实际看到的
                // 上下文（session）**是两套东西**。所以发"继续"时，
                // 模型完全不知道前面做过什么，只能重新问一遍。
                //
                // ## 为什么在这里读（而不是 Dart 传）
                //
                // 会话文件是这个 App 的**唯一事实来源**（工作区里
                // `.heracles/sessions/<id>.jsonl`）—— 从磁盘读保证
                // "模型看到的"与"用户看到的"一致，不会因为 Dart 侧
                // 状态不同步而漂移。
                //
                // ## 取多少轮
                //
                // 最近 [HISTORY_MAX_TURNS] 轮。理由：
                // · 云端上下文很大，但全量塞进去会让每轮成本线性上升
                // · 更早的内容对"继续任务"帮助递减
                // ⚠️ 这是**保守的默认**，将来接压缩/摘要时替换。
                val history = withContext(Dispatchers.IO) {
                    if (sessionId.isNullOrBlank()) {
                        emptyList()
                    } else {
                        runCatching {
                            store.loadMessages(storage, sid)
                                .mapNotNull { m ->
                                    val role = m["role"] as? String
                                    val text = m["text"] as? String
                                    if (text.isNullOrBlank()) null else role to text
                                }
                        }.getOrDefault(emptyList())
                    }
                }.let { msgs ->
                    // 成对切成 (user, assistant)，只取最近 N 轮
                    val pairs = mutableListOf<Pair<String, String>>()
                    var pendingUser: String? = null
                    for ((role, text) in msgs) {
                        when (role) {
                            "user" -> {
                                // 上一条 user 还没配到 assistant（异常情况）→ 丢弃
                                pendingUser = text
                            }
                            "assistant" -> {
                                val u = pendingUser
                                if (u != null) {
                                    pairs.add(u to text)
                                    pendingUser = null
                                }
                            }
                        }
                    }
                    if (pairs.size > HISTORY_MAX_TURNS) {
                        pairs.subList(pairs.size - HISTORY_MAX_TURNS, pairs.size)
                    } else {
                        pairs
                    }
                }

                val runResult = bridge.run(
                    workspacePath = workspacePath,
                    request = request,
                    backend = backend,
                    baseUrl = baseUrl,
                    apiKey = apiKey,
                    modelName = modelName,
                    attachments = attachments,
                    treeUri = treeUri,
                    // ★ 当前会话（2026-10-19）：计划按会话落盘/恢复
                    sessionId = sid,
                    // ★ 审批档位（2026-10-19）：手动审批 / 工作区自动 / 完全访问
                    approvalMode = approvalMode,
                    // ★ 历史对话（2026-10-14）—— 模型据此"记得"之前聊过什么
                    history = history,
                    // ★ 推理等级（S4 的开关传下来；缺省 AUTO = 与旧行为一致）
                    reasoningLevel = reasoningLevel,
                    // ★ 最大轮次（ADR-033）：0 = 按后端自动；>0 = 用户设置覆盖
                    maxTurns = maxTurns,
                    // ★ 流式：每轮的事件即时推到 Dart（主线程，见 emitEvent）。
                    //   这里**只是额外通道** —— 下面的落盘与 result.success
                    //   完全不变，Dart 仍能 await 到完整结果。
                    onEvent = { event -> emitEvent(event) },
                    // ★ ask_user（2026-10-16）：**必须非 null** ——
                    //   注册 AskUserTool 的条件就是它非空。
                    //   实际的"通知 UI 弹窗"走 onEvent 里的 AskUser 事件
                    //   （AgentLoop 在工具挂起前发出）；这里不需要额外动作，
                    //   但保留回调形态以便将来加"等待超时提示"等 UI 行为。
                    onAskUser = { _ -> },
                    // ★ 思考间隙引导（2026-10-13）：run 期间 `interruptRun`
                    //   通道往这个队列投递；AgentLoop 在每轮开始前 drain，
                    //   插话作为 Turn.User append —— 模型下一轮自己看到并调整。
                    interruptQueue = interrupts,
                    // ★★ 过程态落盘（2026-10-12，S5）★★
                    //
                    // 一步一次（`StepEnded` 之后）—— **不是每 token 一次**。
                    // 这样用户中途切会话时，已结束的步骤**已经在磁盘上**，
                    // 切回来就能看到（这正是用户报的 bug）。
                    //
                    // ⚠️ 回调**不是 suspend**（AgentLoop 在 collect 里同步调它），
                    // 而落盘是 suspend 的 —— 所以用一个内层 scope **发出去**。
                    //
                    // 为什么不直接阻塞写：那会卡住 `generateStream` 的 collect，
                    // 让一次磁盘写的时间加到"到下一个 token"的间隔上。
                    // 本类内部所有 `scope.launch` 都在其上排队（单线程 Main
                    // 调度器按提交顺序取出），加上 `sessionWriteLock`，
                    // **落盘顺序仍然与步骤顺序一致**。
                    onStepEnded = { index, stepId, thinking, text, status, durationMs, title ->
                        // ★ 通知栏文案跟着真实步骤走（不是假进度）
                        AgentChatService.update(this@MainActivity, title)
                        scope.launch {
                            persistStep(
                                store, storage, sid,
                                index, stepId, thinking, text, status, durationMs, title,
                            )
                        }
                    },
                )

                // ★ 把这一轮的完整过程写盘（工具调用 + 助手回复）
                //
                // ⚠️ 与运行中的**步骤落盘**（`persistStep`）共用一把锁：
                //    两者都是「读全文 → 追加 → 写全文」，并发会互相覆盖。
                withContext(Dispatchers.IO) {
                    sessionWriteLock.withLock {
                        persistTurns(store, storage, sid, runResult)
                        store.touchSession(storage, sid)
                    }
                }

                val map = bridge.toMap(runResult).toMutableMap()
                map["sessionId"] = sid
                result.success(map)
                // ★ 后台完成提醒（2026-10-19）—— 前台时不打扰
                notifyChatResult(
                    success = true,
                    text = runResult.finalText.ifBlank { runResult.stopReason },
                )
            } catch (e: kotlinx.coroutines.CancellationException) {
                // ★ 用户点了停止（2026-10-13）—— 这是**正常路径**，不是错误。
                //
                // 必须单独接住：CancellationException 若走到下面的
                // `catch (e: Throwable)`，会给 Dart 回一个 "RUN_FAILED"，
                // 用户看到的是"运行失败"而不是"已停止" —— 语义全错。
                //
                // 用 `result.success` 回一个**结构化**的已取消结果：
                // Dart 侧据此把界面切回可用状态，且**不**把半截结果当成
                // 完整回答渲染。
                result.success(
                    mapOf(
                        "cancelled" to true,
                        "stopReason" to "用户已停止",
                        "sessionId" to "", // 取消时不一定有 sid（可能建会话前就停了）
                        "turns" to emptyList<Map<String, Any?>>(),
                        "finalText" to "",
                    )
                )
            } catch (e: Throwable) {
                result.error("RUN_FAILED", e.message ?: e.javaClass.simpleName, null)
                // ★ 后台失败也要提醒（2026-10-19）—— 否则切回来只剩沉默
                notifyChatResult(
                    success = false,
                    text = "运行失败：${e.message ?: e.javaClass.simpleName}",
                )
            } finally {
                // ★ 前台服务与 run 同生命周期（2026-10-19）
                AgentChatService.stop(this@MainActivity)
                // 跑完（成功/失败/取消）都清空槽位 —— 否则取消按钮
                // 会对着一个已结束的 Job 反复 cancel（无害但语义脏）
                runJob = null
                // 插话队列同步作废（2026-10-13）：没有在跑的任务时
                // `interruptRun` 如实回 false —— 那时用户发消息
                // 就是正常发送，不存在"插话"
                runInterrupts = null
            }
        }
    }

    /**
     * **向正在跑的任务插话**（2026-10-13，思考间隙引导）。
     *
     * ## 语义（与"停止"完全不同）
     *
     * 用户原话：「注意不是第一个任务结束，是第一个任务的
     * 当前的思考过程结束了再引导」——
     * 插话**不打断**当前轮；AgentLoop 在当前轮完整结束、
     * 下一轮开始前把它 append 进会话。模型在下一轮自行比对
     * 原任务与插话，决定修改/追加/删除并调整后续任务。
     *
     * ## 没有在跑的任务时
     *
     * 如实回 `false` —— Dart 侧应把这条消息走**正常发送**路径
     * （此时"插话"与"发送"本就是同一件事）。这里不代发，
     * 避免同一句话在两个路径各跑一遍。
     */
    private fun handleInterruptRun(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text").orEmpty()
        val q = runInterrupts
        if (q == null || runJob?.isActive != true) {
            result.success(mapOf("accepted" to false))
            return
        }
        q.offer(text)
        result.success(mapOf("accepted" to true))
    }

    /**
     * **取消当前在跑的一轮**（2026-10-13）。
     *
     * 用户实测反馈：「暂停不了？」—— 停止按钮画出来了，但点下去
     * 只会又发一条消息（`onTap` 恒为 `_send`），因为 Kotlin 侧
     * 从来没有取消能力。
     *
     * ## 这是"真停"而不是"不管它"
     *
     * `job.cancel()` 会传播到 `HttpJson.postSse` 的 `finally`，
     * 那里 `close()` 输入流 + `disconnect()` 连接 ——
     * **阻塞中的 `read()` 被打断**，正在生成的那次请求真的停下。
     * （这条路径 S1 建流式时就写好了，原本是给"页面销毁"用的。）
     *
     * ## 为什么回 `cancelled: false` 而不是报错
     *
     * 没有在跑的东西可取消（用户连点两下、或刚好跑完）——
     * 那是**正常的幂等**，不是错误。报错会让 UI 弹一条无意义的红字。
     */
    private fun handleCancelRun(result: MethodChannel.Result) {
        val job = runJob
        if (job == null || !job.isActive) {
            // 幂等：没有在跑的就如实回"没取消到"
            result.success(mapOf("cancelled" to false))
            return
        }
        job.cancel()
        result.success(mapOf("cancelled" to true))
    }

    /**
     * 把**一个步骤的过程**写进会话记录（2026-10-12，S5）。
     *
     * ## 它修的是什么
     *
     * 用户报的 bug 照录：
     * > "我从会话1切换会话2，前面几轮输出的工作步骤不见了……
     * >  但是它已经生成的步骤会消失"
     *
     * 过程（思考 + 叙述）此前**只有事件、没有落盘**，切会话即消失。
     *
     * ## ★ 写入时机与理由（一句话）
     *
     * **一步一次，在 `StepEnded` 之后** —— 频率与步数同阶（一轮 1 次），
     * 而不是与 token 数同阶；且切走的窗口最小（详见 `SessionStore.appendStep`）。
     *
     * ## ★ 为什么必须串行（`withLock`）
     *
     * `SessionStore.appendMessage` 是**读全文 → 拼一行 → 写全文**。
     * 两个协程同时干这件事会**互相覆盖**（后写的把先写的整段吞掉）。
     * 现在同一会话里有两类写入：
     *   ① 用户消息（`handleRunAgent`，运行前）
     *   ② 步骤（本方法，运行中）
     * 两者在时间上不重叠，但**不能靠"时间上不重叠"来保证正确** ——
     * 那是巧合，不是约束。用一把锁把"读-改-写"护住，代价可忽略
     * （一次锁竞争 = 一次磁盘写的时间）。
     *
     * ⚠️ 这是**进程内**锁。App 只跑一个进程，所以足够；
     * 将来若有跨进程写入者，这里要升级成文件锁。
     */
    private suspend fun persistStep(
        store: SessionStore,
        storage: WorkspaceStorage,
        sessionId: String,
        index: Int,
        stepId: String,
        thinking: String,
        text: String,
        status: String,
        durationMs: Long,
        title: String,
    ) {
        withContext(Dispatchers.IO) {
            sessionWriteLock.withLock {
                store.appendStep(
                    storage,
                    sessionId,
                    mapOf(
                        "index" to index,
                        "stepId" to stepId,
                        "thinking" to thinking,
                        "text" to text,
                        "status" to status,
                        "durationMs" to durationMs,
                        "title" to title,
                    ),
                )
            }
        }
    }

    /**
     * 解析 Dart 传来的推理等级字符串。
     *
     * ## 为什么容错而不是抛
     *
     * 这是个**跨进程弱契约**（字符串），Dart 侧版本可能比 Kotlin 新。
     * 认不出的值若抛异常 → 用户一发消息就报错，而那只是因为多了个档位。
     * 所以**回落到 `AUTO`**（= 与改造前完全一致的行为），
     * 并留一条日志便于排查。
     */
    private fun parseReasoningLevel(raw: String?): ReasoningLevel {
        if (raw.isNullOrBlank()) return ReasoningLevel.AUTO
        return when (raw.lowercase()) {
            "off" -> ReasoningLevel.OFF
            "low" -> ReasoningLevel.LOW
            "high" -> ReasoningLevel.HIGH
            "max" -> ReasoningLevel.MAX
            "auto" -> ReasoningLevel.AUTO
            else -> {
                println("HERC-CONFIG 未知推理等级「$raw」→ 回落 AUTO")
                ReasoningLevel.AUTO
            }
        }
    }

    /**
     * 把一轮 agent 的过程写进会话记录。
     *
     * **每一步都写**（工具调用、助手回复），而不是只写最终结果 ——
     * 否则用户切回来只看到一句总结，中间干了什么全没了。
     */
    private suspend fun persistTurns(
        store: SessionStore,
        storage: dev.heracles.workspace.WorkspaceStorage,
        sessionId: String,
        result: AgentRunResult,
    ) {
        for (t in result.turns) {
            val tc = t.toolCall
            if (tc != null) {
                store.appendMessage(
                    storage, sessionId,
                    mapOf(
                        "role" to "tool",
                        "tool" to tc.tool,
                        "args" to tc.args,
                        "result" to (t.toolResult ?: ""),
                        // ★★ 三态落盘（2026-10-10 修复 H-1）★★
                        //
                        // ## 原来的 bug
                        //
                        // 这里原本写 `"ok" to !t.verdict.contains("失败")` ——
                        // 靠**中文字符串匹配**判成败。而拦截类的 verdict
                        // （"重复调用已拦截（第 2 次）"、"★ 检测到循环，强制停止"）
                        // **都不含「失败」**，于是被落盘成 `ok: true`，
                        // UI 再画出一张**绿色成功卡**：用户以为文件真被改了。
                        //
                        // ## 为什么用 `state` 三态字符串而不是留着 `ok` 布尔
                        //
                        // 布尔**表达不了**三种状态（成功 / 失败 / 被拦截未执行）。
                        // 加一个 `blocked: true` 也能表达，但会留下
                        // "ok 与 blocked 谁是权威"的歧义（ok=true 且 blocked=true
                        // 到底算成功还是拦截？）—— 那种记录迟早会被人读错。
                        //
                        // 所以改成**单一权威字段** `state`，取值恰为三态。
                        // `ok` 仍然写，纯为**向后兼容**旧读取方（见下方注释），
                        // 新代码一律只看 `state`。
                        "state" to when (t.toolState) {
                            dev.heracles.agent.ToolState.succeeded -> "succeeded"
                            dev.heracles.agent.ToolState.failed -> "failed"
                            // 被拦截：**从未执行**。绝不能写成成功。
                            dev.heracles.agent.ToolState.blocked -> "blocked"
                            dev.heracles.agent.ToolState.notRequested -> "blocked"
                        },
                        // 兼容字段：未执行的记 ok=false（旧读取方据此显示"失败"，
                        // 虽然不如"被拦截"准确，但**绝不会误报成功**）
                        "ok" to (t.toolState == dev.heracles.agent.ToolState.succeeded),
                        // ★ 拦截**原因**也要落盘（2026-10-10）
                        //
                        // 不存的话，用户切回会话只看到"已拦截，未执行"，
                        // 却不知道**为什么**被拦 —— 是重复调用？校验不过？
                        // 还是循环硬停？那是用户排查问题最需要的一条信息。
                        // （`verdict` 就是现成的原因文案。）
                        "reason" to t.verdict,
                        "ts" to System.currentTimeMillis(),
                    ),
                )
            }
        }
        if (result.finalText.isNotBlank()) {
            val last = result.turns.lastOrNull()
            store.appendMessage(
                storage, sessionId,
                mapOf(
                    "role" to "assistant",
                    "text" to result.finalText,
                    "cached" to last?.cache?.cachedTokens,
                    "prompt" to (last?.cache?.promptTokens ?: 0),
                    "out" to (last?.cache?.outputTokens ?: 0),
                    "ms" to (last?.wallMs ?: 0L),
                    "ts" to System.currentTimeMillis(),
                ),
            )
        }
    }

    /** 读一个会话的历史消息 */
    private fun handleLoadMessages(call: MethodCall, result: MethodChannel.Result) {
        val ws = call.argument<String>("workspacePath").orEmpty()
        val treeUri = call.argument<String>("treeUri").orEmpty()
        val sid = call.argument<String>("sessionId").orEmpty()
        scope.launch {
            try {
                val msgs = withContext(Dispatchers.IO) {
                    store.loadMessages(storageOf(ws, treeUri), sid)
                }
                result.success(msgs)
            } catch (e: Throwable) {
                result.error("LOAD_MESSAGES_FAILED", e.message ?: "读取会话失败", null)
            }
        }
    }

    /**
     * 从第一次请求推导会话标题。
     *
     * 桌面版也是这么做的（取前几十个字）。
     * 纯附件消息用文件名当标题。
     */
    private fun deriveTitle(request: String, attachments: List<Map<String, String>>): String {
        val t = request.trim().replace('\n', ' ')
        if (t.isNotEmpty()) {
            return if (t.length <= 24) t else t.take(24) + "…"
        }
        val f = attachments.firstOrNull()?.get("name").orEmpty()
        return if (f.isNotEmpty()) "关于 $f" else "新会话"
    }

    /** 列目录（给"文件"视图用） */
    private fun handleListDir(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path").orEmpty()
        scope.launch {
            val entries = withContext(Dispatchers.IO) {
                val d = File(path)
                if (!d.isDirectory) return@withContext emptyList<Map<String, Any?>>()
                d.listFiles()
                    ?.filter { it.name != SessionStore.DOT_DIR }
                    ?.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
                    ?.take(300)
                    ?.map {
                        mapOf(
                            "name" to it.name,
                            "path" to it.absolutePath,
                            "isDir" to it.isDirectory,
                            "size" to if (it.isDirectory) 0L else it.length(),
                        )
                    } ?: emptyList()
            }
            result.success(entries)
        }
    }

    /**
     * 存储访问性能对比 —— 路线 A（SAF）vs 路线 B（POSIX）。
     *
     * 真机测量，不靠猜。
     */
    private fun handleBenchmark(call: MethodCall, result: MethodChannel.Result) {
        val treeUriStr = call.argument<String>("treeUri") ?: ""
        val fileCount = call.argument<Int>("fileCount") ?: 20
        scope.launch {
            val out = withContext(Dispatchers.IO) {
                val m = mutableMapOf<String, Any?>()
                // POSIX 对照组
                m["file"] = StorageProbe.benchmarkFile(applicationContext, fileCount)
                // SAF（需要先通过 pickWorkspace 拿到授权，这里用已持久化的）
                val uri = if (treeUriStr.isNotBlank()) {
                    android.net.Uri.parse(treeUriStr)
                } else {
                    firstPersistedTreeUri()
                }
                if (uri != null) {
                    m["saf"] = StorageProbe.benchmarkSaf(applicationContext, uri, fileCount)
                } else {
                    m["safError"] = "没有已授权的文件夹 —— 先在侧边栏选一个"
                }
                m
            }
            result.success(out)
        }
    }

    /** 取第一个已持久化授权的 tree URI */
    private fun firstPersistedTreeUri(): android.net.Uri? {
        val perms = contentResolver.persistedUriPermissions
        return perms.firstOrNull { it.isWritePermission }?.uri
    }

    /**
     * 用量与上下文面板要的**两个只读数字**（2026-10-11，t13）。
     *
     * | 字段 | 含义 |
     * |---|---|
     * | `frozenTokens` | 上一次 `run()` 的**冻结区**估算（系统提示词 + 工具定义）；`-1` = 还没跑过 |
     * | `contextLimit` | 上下文上限 —— **按后端类型区分**（2026-10-14 用户反馈修复） |
     *
     * ## contextLimit 为什么要分类
     *
     * 用户实测：调基元律动的 `deepseek-v4-flash-0731`（1M 上下文），
     * UI 却显示「已用 56% · 2.3K / 4.1K」—— 把**本地**的 4096
     * 用到了云端模型上。后果不只是显示错：
     * `COMPACTION_TRIGGER_RATIO`（0.8）会按 4K 触发 → 过早压缩会话。
     *
     * 现在由 Dart 侧告知当前是否云端（它才知道用户在用什么 provider）。
     *
     * ## 为什么冻结区只能精确到"估算"
     *
     * `PrefixBuilder` 用的是 `TextMath.estimateTokens`，它**不是真实 tokenizer**
     * （`实测-08`：曾 40% 高估）。所以 Dart 侧**必须**把它标成 `~` ——
     * 否则用户会以为能精确控制预算（`docs/24` §4.2）。
     *
     * 这里**不做** token 分项（工具 vs 系统提示词）：那需要在
     * `PrefixBuilder` 里把拼接过程拆开，改动面大且会碰核心契约。
     * 一期只给"冻结区合计"，够回答"上下文被谁占了"的主要疑问。
     */
    private fun handleUsageInfo(call: MethodCall, result: MethodChannel.Result) {
        // 缺省 true：拿不到参数时按云端算（保守 —— 显示的上限更大，
        // 宁可让用户觉得"还很空"，也不要误报"快满了"引发无谓压缩）
        val isCloud = call.argument<Boolean>("isCloud") ?: true
        result.success(
            mapOf(
                "frozenTokens" to bridge.lastFrozenTokens,
                "contextLimit" to bridge.contextLimitTokens(isCloud),
            )
        )
    }

    private fun handlePickFiles(call: MethodCall, result: MethodChannel.Result) {
        val imagesOnly = call.argument<Boolean>("imagesOnly") ?: false
        val multiple = call.argument<Boolean>("multiple") ?: true
        runOnUiThread {
            try {
                filePicker.launch(
                    imagesOnly = imagesOnly,
                    multiple = multiple,
                    onResult = { list -> result.success(list) },
                    onError = { msg -> result.error("PICK_FAILED", msg, null) },
                )
            } catch (e: Throwable) {
                result.error("PICK_FAILED", e.message ?: "无法打开选择器", null)
            }
        }
    }

    // ------------------------------------------------------------ 生命周期

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

    override fun onDestroy() {
        scope.cancel()
        // 页面销毁 → sink 失效。不置空的话，正在跑的那轮 agent
        // 还会往一个死 sink 里写事件（虽然 runCatching 兜住了，
        // 但白做工 + 掩盖真实错误）
        eventSink = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "heracles/command"

        /**
         * **App 进程内自检的 Intent 开关**（2026-10-17）。
         *
         * `am start … --ez heracles_encode_selfcheck true` —— 见 [onCreate]。
         * 存在的理由：真机验证必须**可脚本复现**，不能只靠人去点按钮。
         */
        private const val EXTRA_ENCODE_SELF_CHECK = "heracles_encode_selfcheck"

        /**
         * **传给模型的历史轮数上限**（2026-10-14）。
         *
         * 用户实测：「让他继续完成任务，他输出了又是**没有记忆了**」——
         * 修法是把历史对话传进 `AgentLoop`。但不能无脑全传：
         * · 云端上下文虽大，全量塞进去会让每轮成本线性上升
         * · 更早的内容对"继续任务"的帮助递减
         *
         * 10 轮是个保守起点 —— 够覆盖"刚才聊了什么"，
         * 又不会让首轮 prompt 过胖。将来接压缩/摘要时替换。
         */
        private const val HISTORY_MAX_TURNS = 10

        /**
         * 事件流通道名。
         *
         * `15-前端选型与通道协议.md` §3.1 的草案写的是 `heracles/event`，
         * 本实现按任务约定用 **`heracles/events`**（复数）。
         * Dart 侧 `AgentBridge` 必须用同一个字符串。
         */
        private const val EVENT_CHANNEL = "heracles/events"

        /** 聊天完成通知（2026-10-19）：通道 + 通知 id（固定 id ⇒ 新任务覆盖旧提醒）。 */
        private const val CHAT_CHANNEL_ID = "heracles_chat_done"
        private const val CHAT_NOTIFY_ID = 2001

        /** 运行时通知权限的 requestCode（与权限名一一对应即可） */
        private const val REQ_POST_NOTIFICATIONS = 1001
    }
}
