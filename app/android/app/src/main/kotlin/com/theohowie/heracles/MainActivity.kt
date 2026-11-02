package com.theohowie.heracles

import android.Manifest
import android.app.ActivityManager
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import com.theohowie.heracles.bridge.AgentChatService
import com.theohowie.heracles.bridge.AutomationScheduler
import com.theohowie.heracles.bridge.DeviceChannel
import com.theohowie.heracles.bridge.DeviceFs
import com.theohowie.heracles.bridge.DeviceHealth
import com.theohowie.heracles.bridge.DevicePermissionChecker
import com.theohowie.heracles.bridge.DeviceShell
import com.theohowie.heracles.bridge.DeviceShellManager
import com.theohowie.heracles.bridge.BuildTaskProgress
import com.theohowie.heracles.bridge.CameraBridge
import com.theohowie.heracles.bridge.VoiceRecorder
import com.theohowie.heracles.bridge.FilePickerBridge
import com.theohowie.heracles.bridge.FolderPickerBridge
import com.theohowie.heracles.bridge.MemoryStore
import com.theohowie.heracles.bridge.McpConfigBridge
import com.theohowie.heracles.bridge.SandboxBridge
import com.theohowie.heracles.bridge.SkillsBridge
import com.theohowie.heracles.bridge.WorkspaceRegistry
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
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
 * ## 两个通道 + 一条事件流，分工明确
 *
 * | 通道 | 方向 | 内容 |
 * |---|---|---|
 * | `heracles/device`（[DeviceChannel]） | Dart → Kotlin 请求 / 响应 | 设备能力全协议 |
 * | `heracles/command`（本类） | Dart → Kotlin 请求 / 响应 | **工作区登记** + 设备权限引导 + 通知回跳 |
 * | EventChannel `heracles/voice`（[VoiceRecorder]） | Kotlin → Dart 事件流 | 流式语音 PCM 分片（§N13.2，2026-10-29 新增） |
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

    private lateinit var sandbox: SandboxBridge
    private lateinit var registry: WorkspaceRegistry
    private lateinit var deviceFs: DeviceFs
    private lateinit var filePicker: FilePickerBridge
    private lateinit var cameraBridge: CameraBridge
    private lateinit var voiceRecorder: VoiceRecorder
    private lateinit var folderPicker: FolderPickerBridge

    /** ★ V0.4 F1（2026-11-02）：技能目录的文件系统操作（**不解析** front-matter）。 */
    private lateinit var skillsBridge: SkillsBridge

    /** ★ V0.4 F3（2026-11-02）：MCP 配置的持久化（**不做连接测试**）。 */
    private lateinit var mcpBridge: McpConfigBridge

    /** `heracles/command` 通道引用 —— 通知点击回跳要往 Dart 推送。 */
    private var commandChannel: MethodChannel? = null

    /** 冷启动时 Dart 还没注册 handler ⇒ 先把"要打开的会话"存着，等它主动来取。 */
    @Volatile
    private var pendingOpenSession: Map<String, String>? = null

    /** App 是否在前台（决定要不要发"任务完成"通知）。 */
    @Volatile
    private var appInForeground = false

    // ---------------------------------------------------- 首帧看门狗的状态

    /** 当前 Flutter surface 上是否正显示着首帧（`onFlutterUiDisplayed` 的镜像）。 */
    @Volatile
    private var flutterFirstFrameVisible = false

    /** 这个 Activity 实例已经布过一次防（一次只救一次）。 */
    private var firstFrameWatchdogArmed = false

    /** 最近一次重建是不是"系统恢复"（`savedInstanceState != null`）—— 只用于日志归因。 */
    private var lastSavedStateHadState = false

    // ------------------------------------------------------------ 生命周期

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // ★ 归因用：savedInstanceState != null ⇒ 这次是**系统恢复**（App 被回收过），
        //   不是用户主动冷启动。黑屏问题的 logcat 里这条很关键。
        lastSavedStateHadState = savedInstanceState != null
        Log.i(
            TAG,
            "onCreate: savedState=${savedInstanceState != null} " +
                "instance=${hashCode()} process=${android.os.Process.myPid()}",
        )
        // ★ 仅 debug：沙箱自检（由 adb 触发，用户可见行为零变化）
        //   adb shell am start -n com.theohowie.heracles/.MainActivity --ez sandbox.selftest true
        if (BuildConfig.DEBUG && intent?.getBooleanExtra("sandbox.selftest", false) == true) {
            window.decorView.post { sandbox.runSelfTest() }
        }
        // ★ 冷启动：从完成通知点进来（Dart 还没就绪 ⇒ 先存 pending）
        handleNotifyIntent(intent)
        // ★ 运行时请求通知权限（API 33+）——
        //   不请求的话「任务完成通知」永远发不出去，且用户不知道能开。
        //   只在没授权时请求一次（系统会记住"已拒绝"；下次不重复骚扰）。
        //   ★ 2026-10-30（B2）：请求过的痕迹要落 SharedPreferences ——
        //   用户拒两次后系统"不再询问"，权限页点通知只能去系统通知设置页。
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            permissionPrefs().edit()
                .putBoolean(KEY_REQUESTED_NOTIFICATIONS, true)
                .apply()
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_POST_NOTIFICATIONS,
            )
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
        // ★ 仅 debug：热启动时也能触发沙箱自检（冷启动走 onCreate 那条）
        if (BuildConfig.DEBUG && intent.getBooleanExtra("sandbox.selftest", false)) {
            window.decorView.post { sandbox.runSelfTest() }
        }
    }

    override fun onResume() {
        super.onResume()
        appInForeground = true
    }

    override fun onPause() {
        appInForeground = false
        super.onPause()
    }

    /**
     * ★ 首帧看门狗（2026-11-02 T0）：**返回前台 2.5 s 还没有 Flutter 首帧 ⇒ 重建一次**。
     *
     * ## 它治的是什么
     *
     * 用户报「选好文件夹返回 ⇒ 黑屏（不是回到聊天页）」。除了"结果丢失"那个数据层
     * 缺陷，还有一层**渲染层**可能：从 SAF 回来时 Activity/FlutterSurface 被重建，
     * 首帧迟迟不渲染 ⇒ 用户只看到 `LaunchTheme` 的黑底。
     *
     * ## 为什么不能用"硬编码延时"糊过去
     *
     * 加 `sleep(500)` 之类只是赌一次时机，慢设备/低内存下照样黑，而且把正常路径
     * 也拖慢了。这里改成**先观测再动作**：只在"确实没有首帧"时重建，并**记下原因**，
     * 让根因留在 logcat 里可追。
     *
     * ## 三道闸（防误伤）
     *
     * 1. 只有在**本次进程曾渲染过首帧**之后才布防 —— 冷启动本来就慢，别去插手；
     * 2. 有**选择请求在飞**（[FolderPickerBridge.hasPending]）时不动手 ——
     *    重建会把刚要交付的结果打断，那是雪上加霜；
     * 3. 进程级 30 s 冷却，一个实例只救一次 —— 防"重建→还黑→再重建"的循环。
     */
    override fun onPostResume() {
        super.onPostResume()
        // `hasRenderedFirstFrame()` 是 FlutterView 的公开 API（本版本引擎上
        // FlutterEngine 已没有 addIsDisplayingFlutterUiListener，别再照旧文档写）。
        val rendered = flutterViewRendered()
        if (rendered) {
            flutterFirstFrameVisible = true
            everRenderedFirstFrame = true
            return // 已经在显示 ⇒ 没什么可看的（普通后台切回来走这条，零开销）
        }
        flutterFirstFrameVisible = false
        if (!everRenderedFirstFrame || firstFrameWatchdogArmed) return
        firstFrameWatchdogArmed = true
        mainHandler.postDelayed({
            if (isFinishing || isDestroyed) return@postDelayed
            if (flutterViewRendered()) {
                Log.i(TAG, "watchdog: 首帧正常（返回前台后已渲染），不动作")
                flutterFirstFrameVisible = true
                // 归还布防权：下一次 resume 还能再观测
                firstFrameWatchdogArmed = false
                return@postDelayed
            }
            if (::folderPicker.isInitialized && folderPicker.hasPending()) {
                Log.w(
                    TAG,
                    "watchdog: 无首帧，但有一次文件夹选择在飞 ⇒ 不重建（避免打断结果交付）",
                )
                return@postDelayed
            }
            val now = System.currentTimeMillis()
            if (now - lastWatchdogRecoverAt < WATCHDOG_COOLDOWN_MS) {
                Log.w(TAG, "watchdog: 无首帧，但 ${WATCHDOG_COOLDOWN_MS}ms 内已重建过 ⇒ 不再重建")
                return@postDelayed
            }
            lastWatchdogRecoverAt = now
            // ★ 根因证据：把"为什么判它卡住"写清楚，别只留一句 recreate()
            Log.w(
                TAG,
                "watchdog: onPostResume 后 ${WATCHDOG_DELAY_MS}ms 仍无 Flutter 首帧 " +
                    "⇒ 判定 surface 未恢复，recreate() 一次。" +
                    "pending=${::folderPicker.isInitialized} " +
                    "savedState=${lastSavedStateHadState} " +
                    "hasFocus=${hasWindowFocus()}",
            )
            runCatching { recreate() }
        }, WATCHDOG_DELAY_MS)
    }

    /** `FlutterView` 这一帧到底渲染出来没有（看门狗的唯一判据）。 */
    private fun flutterViewRendered(): Boolean = runCatching {
        findViewById<FlutterView>(FlutterActivity.FLUTTER_VIEW_ID)?.hasRenderedFirstFrame() == true
    }.getOrDefault(false)

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
        cameraBridge = CameraBridge(this)
        voiceRecorder = VoiceRecorder(this)
        folderPicker = FolderPickerBridge(this)

        // ★ V0.4 F1/F3（2026-11-02）：技能目录 + MCP 配置（都是"只有宿主能做"的重活）
        skillsBridge = SkillsBridge(ctx)
        mcpBridge = McpConfigBridge(ctx)

        // ★ 设备能力通道（`heracles/device`）—— 协议见 [DeviceChannel]
        DeviceChannel(
            activity = this,
            registry = registry,
            fs = deviceFs,
            shell = DeviceShell(),
            health = DeviceHealth(ctx),
            build = BuildTaskProgress(ctx),
            // ★ 长期记忆（App 全局，与工作区无关）—— `memory.*` 共 12 个方法：
            //   read / append / clear / list / search / delete / userEdit /
            //   propose / proposals / resolveProposal / stats / migrate
            //   （实现见 [MemoryStore]，契约见 docs/INTERFACE.md §N12）
            memory = MemoryStore(ctx),
            filePicker = filePicker,
            folderPicker = folderPicker,
            scope = scope,
            mainHandler = mainHandler,
        ).register(flutterEngine)

        // ★ 内置沙箱（Heracles-taixu-sandbox）—— 内联执行面，不是第二个 App
        //   通道：`heracles/sandbox`（控制）+ `heracles/sandbox/output`（流式输出）
        //
        //   ⚠️ 这段曾在 2026-10-29 合并 `jev-sheets` 时被覆盖掉，真机自检
        //   立刻报「通道不可用」—— 沙箱整套能力静默失效。删这段前想清楚。
        sandbox = SandboxBridge(
            context = ctx,
            scope = scope,
            mainHandler = mainHandler,
        ).also { it.register(flutterEngine) }

        // ★ 命令通道（`heracles/command`）—— 工作区登记 + 权限引导 + 通知回跳
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).also {
            commandChannel = it
            // ★ 进程级"当前活着的通道"引用（2026-11-02 T0）：
        //   选择结果到达时，发起这次选择的那个 Activity 可能已经死了，
        //   它捕获的 commandChannel 指向旧引擎。要推 `workspaceAdded` 给
        //   **重建后的新引擎**，只能查这一份。
        liveCommandChannel = it
    }.setMethodCallHandler { call, result -> handle(call, result) }

        // ★ 流式语音事件流（`heracles/voice`）—— Kotlin → Dart，契约 §N13.2
        //   只增不改：旧包没有这条通道 ⇒ Dart 订阅失败/收不到 chunk。
        //   StreamHandler 的 onListen/onCancel 都在主线程，直接把 sink 交给录音器；
        //   没订阅时 sink 为 null ⇒ [VoiceRecorder] 退化为"只写文件"的旧行为。
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VoiceRecorder.EVENT_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    voiceRecorder.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    voiceRecorder.setEventSink(null)
                }
            },
        )
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // ---- 工作区（登记表在本地 prefs，SAF/POSIX 由 DeviceFs 自行路由） ----
            "pickWorkspace" -> handlePickWorkspace(call, result)
            // 只增（2026-11-02 T0）：Dart 超时后取回已产出的选择结果
            "consumePickWorkspaceResult" -> handleConsumePickWorkspaceResult(call, result)
            "listWorkspaces" -> handleListWorkspaces(result)
            "removeWorkspace" -> handleRemoveWorkspace(call, result)
            "ensureAppWorkspace" -> handleEnsureAppWorkspace(result)

            // ---- 文件 ----
            "pickFiles" -> handlePickFiles(call, result)
            "takePhoto" -> handleTakePhoto(result)
            // ---- 语音录音（2026-10-29，离线识别的录音桥） ----
            "startVoiceRecord" -> reply(result, voiceRecorder.start())
            "stopVoiceRecord" -> reply(result, voiceRecorder.stop())
            "cancelVoiceRecord" -> reply(result, voiceRecorder.cancel())
            "listDir" -> handleListDir(call, result)

            // ---- 设备权限（无线调试 / Shizuku / Stellar 引导） ----
            "devicePermission" -> handleDevicePermission(result)
            // ★ N8（2026-10-25，INTERFACE.md §4.N8）：权限页统一查询
            "devicePermissions" -> handleDevicePermissions(result)
            // ★ 2026-10-27：权限页改弹性开关 —— 开关拨动拉起系统授权流程
            "requestPermission" -> handleRequestPermission(call, result)
            // ★ 2026-10-27：JEV 决策引擎本机检测（机型/内存/存储/私有目录）
            "deviceProfile" -> handleDeviceProfile(result)
            "shizukuGrant" -> handleShizukuGrant(force = false, result = result)
            "shizukuForceRequest" -> handleShizukuGrant(force = true, result = result)

            // ---- 通知点击回跳 ----
            "consumePendingOpen" -> {
                val p = pendingOpenSession
                pendingOpenSession = null
                result.success(p)
            }

            // ---- ★ V0.4 T0-2 后台保活引导（2026-11-02；只引导/只读，不改系统设置）----
            //   电池优化：拉起系统"忽略电池优化"确认页（false = 系统不支持）
            "requestIgnoreBatteryOptimizations" -> reply(
                result,
                AgentChatService.requestIgnoreBatteryOptimizations(this),
            )
            //   OEM 自启：只返回 {brand, path} 给 UI 显示，**不自动跳转**
            "autostartGuide" -> {
                val (brand, path) = AgentChatService.autostartGuide()
                result.success(mapOf("ok" to true, "brand" to brand, "path" to path))
            }
            // ---- ★ V0.4 配套（2026-11-02，契约 §N18；只增方法，旧的都还在）----
            //   keepaliveStatus：聚合真实状态（前台服务运行位 + 电池优化真实值 +
            //   MIUI 口径提醒 + 自启动路径）。**查不到就 false/null + note，不编数据**。
            "keepaliveStatus" -> result.success(AgentChatService.keepaliveStatus(this))
            //   oemGuide(kind)：MIUI 保活三件套（自启动/后台弹出界面/锁屏显示）。
            //   未知 kind ⇒ {ok:false}（Dart 侧已先行校验，这里是第二道闸）。
            "oemGuide" -> {
                val kind = call.argument<String>("kind") ?: ""
                val g = AgentChatService.oemGuide(kind)
                if (g == null) {
                    result.success(mapOf("ok" to false, "error" to "未知的引导类型：$kind"))
                } else {
                    result.success(mapOf("ok" to true, "brand" to g.first, "path" to g.second))
                }
            }
            //   上次 run 是否被系统停止（如实提示，不假装继续）
            "processKilled" -> result.success(
                mapOf(
                    "ok" to true,
                    "killed" to AgentChatService.processKilled(this),
                    "killedAt" to AgentChatService.processKilledAt(this),
                )
            )
            "consumeProcessKilled" -> {
                AgentChatService.consumeProcessKilled(this)
                result.success(mapOf("ok" to true))
            }

            // ---- ★ V0.4 T1-4（2026-11-02）：`notify_user` 工具的宿主能力 ----
            //   权限被拒/通知被关 ⇒ **如实失败**（不假装发送成功）。
            "notifyUser" -> {
                val title = call.argument<String>("title") ?: ""
                val body = call.argument<String>("body") ?: ""
                val id = call.argument<String>("id")
                if (title.isBlank() || body.isBlank()) {
                    result.success(mapOf("ok" to false, "error" to "标题与正文都不能为空"))
                } else if (!notificationsAvailable(this)) {
                    result.success(mapOf(
                        "ok" to false,
                        "error" to "通知权限未开启（请在系统设置里允许 Heracles 发通知）",
                    ))
                } else {
                    val posted = runCatching {
                        postUserNotification(title, body, id)
                        true
                    }.getOrDefault(false)
                    if (posted) {
                        result.success(mapOf("ok" to true, "message" to "已发送通知"))
                    } else {
                        result.success(mapOf("ok" to false, "error" to "发送通知失败（系统拒绝）"))
                    }
                }
            }

            // ---- ★ V0.4 T1-5（2026-11-02）：自动化任务真调度（AlarmManager）----
            //   Dart 侧存任务清单 ⇒ 这里注册周期闹钟；到点只发通知 + 写 pending，
            //   **不假装跑了 agent**（执行由 App 打开后 Dart 侧发起）。
            "automationSave" -> {
                val tasks = call.argument<String>("tasks") ?: "[]"
                val ok = AutomationScheduler.saveTasks(this, tasks)
                result.success(mapOf("ok" to ok, "error" to if (ok) null else "任务清单保存失败"))
            }
            "automationLoad" -> result.success(
                mapOf("ok" to true, "tasks" to AutomationScheduler.loadTasks(this))
            )
            "automationConsumePending" -> result.success(
                mapOf("ok" to true, "taskIds" to AutomationScheduler.consumePending(this))
            )
            "automationCancelAll" -> {
                AutomationScheduler.cancelAll(this)
                result.success(mapOf("ok" to true))
            }

            // ---- ★ V0.4 F1（2026-11-02）：Skills 通道（契约 §N16.1）----
            //   宿主只搬字节 + 存启停表；**合法性由 Dart 的 parseSkillMd 判**
            //   —— 解析器只能有一份，否则会出现"装上了但列表里没有"。
            //   安装要下载/遍历目录 ⇒ 切 IO。
            "skillsList" -> {
                val ws = call.argument<String>("workspace") ?: ""
                scope.launch(Dispatchers.IO) { reply(result, skillsBridge.list(ws)) }
            }
            "skillsSetEnabled" -> {
                val name = call.argument<String>("name") ?: ""
                val enabled = call.argument<Boolean>("enabled") ?: true
                reply(result, skillsBridge.setEnabled(name, enabled))
            }
            "skillsInstall" -> {
                val ws = call.argument<String>("workspace") ?: ""
                val source = call.argument<String>("source") ?: ""
                scope.launch(Dispatchers.IO) { reply(result, skillsBridge.install(ws, source)) }
            }
            "skillsRemove" -> {
                val ws = call.argument<String>("workspace") ?: ""
                val name = call.argument<String>("name") ?: ""
                val path = call.argument<String>("path")
                scope.launch(Dispatchers.IO) { reply(result, skillsBridge.remove(ws, name, path)) }
            }

            // ---- ★ V0.4 F3（2026-11-02）：MCP 配置通道（契约 §N16.2）----
            //   ⚠️ **没有 mcpTest**：宿主没有 MCP 客户端，真连接测试在 Dart 侧
            //   （框架 McpManager）。在 Kotlin 手搓一个握手只能得到假结果。
            "mcpList" -> reply(result, mcpBridge.list())
            "mcpSave" -> {
                @Suppress("UNCHECKED_CAST")
                val server = call.argument<Map<*, *>>("server")
                reply(result, mcpBridge.save(server))
            }
            "mcpDelete" -> {
                val name = call.argument<String>("name") ?: ""
                reply(result, mcpBridge.delete(name))
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

    // ------------------------------------------- 权限小工具（B2，2026-10-30）

    /** 权限请求痕迹的落盘 ——「请求过没有」是判断还能不能弹系统框的关键。 */
    private fun permissionPrefs() =
        getSharedPreferences(PREF_PERMISSIONS, Context.MODE_PRIVATE)

    /**
     * 通知是否**真的**可用：通知总开关（`areNotificationsEnabled`）**且**
     * API 33+ 的运行时权限 `POST_NOTIFICATIONS` 都已授予。
     *
     * 只查其中一个会骗人（B2 修的就是这个）：
     * · 总开关关了但权限 granted ⇒ 旧实现显示「已开」，实际发不出通知；
     * · 权限 denied 但总开关开着 ⇒ 同样发不出。
     */
    private fun notificationsAvailable(ctx: Context): Boolean {
        val runtimeOk = Build.VERSION.SDK_INT < 33 ||
            ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        return runtimeOk && NotificationManagerCompat.from(ctx).areNotificationsEnabled()
    }

    /**
     * **发一条用户通知**（V0.4 T1-4 
otify_user 工具的宿主实现，2026-11-02）。
     *
     * 独立通道 heracles_user_notify（与"任务执行中"2000 / "完成"2001 都不同，
     * 三者可并存）。id 非空时用它做通知 id（同 id 覆盖），否则固定 2002。
     *
     * ⚠️ 调用方**必须先确认** [notificationsAvailable] —— 权限/开关没开时
     * 这里会抛 SecurityException 或静默不发，那是"假成功"的来源。
     */
    @SuppressLint("MissingPermission")
    private fun postUserNotification(title: String, body: String, id: String?) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(USER_NOTIFY_CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(
                    USER_NOTIFY_CHANNEL_ID,
                    "任务提醒",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = "任务完成 / 需要你回来确认时的提醒" }
            )
        }
        val open = PendingIntent.getActivity(
            this,
            3,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notifyId = if (id.isNullOrBlank()) USER_NOTIFY_ID else (id.hashCode() and 0x7fffffff)
        val n = Notification.Builder(this, USER_NOTIFY_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(this).notify(notifyId, n)
    }
    /** 打开本 App 的通知设置页（永久拒绝 / 关闭通知 / 低版本都走这里）。 */
    private fun openNotificationSettings() {        startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }

    // ------------------------------------------------------------ 工作区

    /**
     * 选一个已有文件夹作为工作区（SAF 目录选择器）。
     *
     * **选中即登记**（`path` / `name` / `treeUri` 三字段进 `heracles_workspaces`）——
     * 否则 [DeviceFs] 查不到 SAF 记录，后续读这个目录会用 `java.io.File` 撞 `EPERM`。
     *
     * 用户取消时回 `null`（**沿用旧契约**：Dart 侧据此判断"没选"而不是"出错"）。
     *
     * ## ★★ 为什么回调里跑的是 [processScope] 而不是 [scope]（2026-11-02 T0）★★
     *
     * 这条闭包会被 `FolderPickerBridge` 存进**进程级**登记表，可能在**本 Activity
     * 已经 onDestroy 之后**才被调用（SAF 期间被系统回收 ⇒ 结果落到重建后的新实例）。
     * 而 [scope] 在 `onDestroy` 里被 `cancel()` 了：
     *
     * ```
     * scope.launch { … }        // 协程根本不会启动（scope 已取消）
     * ⇒ 目录永远登记不上，completed 也永远不会被记录
     * ⇒ 用户选了半天，工作区列表里什么都没有
     * ```
     *
     * 换成进程级 scope 后，Activity 死活都不影响"把结果落库"这件纯数据工作。
     */
    private fun handlePickWorkspace(call: MethodCall, result: MethodChannel.Result) {
        // 上次用的目录作为选择器起点（Dart 可传，避免 UI 侧还要存一份）
        val lastUri = call.argument<String>("lastUri").orEmpty()
        // ★ Dart 为每次调用生成 requestId：超时后凭它把结果取回去。
        //   Activity 重建时那条 MethodChannel 已经失效，但结果不能因此丢失。
        val requestId = call.argument<String>("requestId").orEmpty()
        runOnUiThread {
            try {
                folderPicker.launch(lastUri, requestId) { ws ->
                    processScope.launch {
                        val payload = completePickWorkspace(ws)
                        // 先落 completed（在 completePickWorkspace 里）再回包：
                        // 回包打到死通道上也不会丢结果 —— Dart 超时会自己来取。
                        folderPicker.recordCompleted(requestId, payload)
                        runCatching { reply(result, payload) }
                        if (payload != null && payload["ok"] != false) {
                            // ★ Activity 重建后 Dart 是**全新 isolate**，它启动时读的
                            //   工作区列表里没有这个新目录 —— 推一条让它重载。
                            runCatching {
                                liveCommandChannel?.invokeMethod(
                                    "workspaceAdded",
                                    mapOf(
                                        "path" to (payload["path"] as? String).orEmpty(),
                                        "name" to (payload["name"] as? String).orEmpty(),
                                    ),
                                )
                            }
                        }
                    }
                }
            } catch (e: Throwable) {
                folderPicker.recordCompleted(requestId, null)
                reply(result, null)
            }
        }
    }

    /**
     * 取回某个 requestId **已产出但没送达**的选择结果（Dart 超时后的补救）。
     *
     * 没有结果 ⇒ 回 null，Dart 据此走"选择器被系统回收，请重试"分支。
     * 取过即作废（幂等消费，防同一个结果被两次使用）。
     */
    private fun handleConsumePickWorkspaceResult(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val requestId = call.argument<String>("requestId").orEmpty()
        reply(result, folderPicker.consumeCompleted(requestId))
    }

    /**
     * 把 picker 的原始结果落成**给 Dart 的最终 payload**（含工作区登记）。
     *
     * 成功 = 已登记的工作区 Map；取消 = null；失败 = `{ok:false, error, reasonCode?, suggest?}`。
     */
    private suspend fun completePickWorkspace(
        ws: Map<String, Any?>?,
    ): Map<String, Any?>? {
        if (ws == null) return null // 用户取消，或选的位置没有本地路径
        // ★ 受限目录（Android 11+ 系统不授权）/ 网盘：
        //   把**原因 + 出路**原样交给 Dart，让它能显示人话并给出按钮。
        if (ws["ok"] == false) {
            return buildMap {
                put("ok", false)
                put("error", (ws["error"] as? String) ?: "这个位置无法用作工作区")
                (ws["reason"] as? String)?.let { put("reasonCode", it) }
                (ws["suggest"] as? List<*>)?.let { put("suggest", it) }
            }
        }
        val path = ws["path"] as? String
        if (path.isNullOrBlank()) return null
        // 登记失败（目录不存在且无 SAF 授权）→ 如实回 null，不假装成功
        return withContext(Dispatchers.IO) {
            registry.add(path, (ws["name"] as? String).orEmpty(), (ws["treeUri"] as? String).orEmpty())
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

    /**
     * 拍照（**[CameraBridge]**：MediaStore 预留位置 → 系统相机 →
     * 复制进 cache 回真实路径）。成功回 {path, name, size}；
     * 用户取消回 null（Dart 侧 invokeMapMethod 得 null，不是错误）；
     * 真失败才回错误 map。
     */
    private fun handleTakePhoto(result: MethodChannel.Result) {
        runOnUiThread {
            try {
                cameraBridge.launch(
                    onResult = { map -> reply(result, map) },
                    onError = { msg ->
                        reply(result, mapOf("ok" to false, "error" to msg))
                    },
                )
            } catch (e: Throwable) {
                reply(result, mapOf("ok" to false, "error" to (e.message ?: "无法打开相机")))
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
     * **拉起某项权限的系统授权流程**（权限页弹性开关，2026-10-27；
     * 通知 settings 兜底 = **B2，2026-10-30**）。
     *
     * 返回**只增**：`{ok, action, granted}`（旧调用点只读 `ok`，语义不变）。
     * `action ∈ {requested, settings_opened, already_granted}`；
     * `granted` = 拉起**之前**的真实状态（通知项用双条件，见
     * [notificationsAvailable]）。
     *
     * · `notifications`（API 33+）：
     *   ① 已可用（总开关开 && `POST_NOTIFICATIONS` granted）⇒ 不上系统
     *      界面，回 `already_granted`；
     *   ② 没请求过、或系统仍允许再问
     *      （`shouldShowRequestPermissionRationale`）⇒ 落 prefs 请求标记 +
     *      `requestPermissions`，回 `requested`；
     *   ③ **永久拒绝**（系统"不再询问"：rationale=false 且请求过）⇒
     *      打开本 App 通知设置页，回 `settings_opened` —— 否则用户点了
     *      开关什么都不发生（旧实现缺陷）。
     * · `notificationsOff`：关通知只能去通知设置页（系统不许 App 自己
     *   撤销运行时权限）⇒ `settings_opened`；
     * · `accessibility` / `overlay` / `appSettings` / `installPackages`：
     *   只有系统设置页 ⇒ `settings_opened`；
     * · `media` / `camera` / `calendar` / `microphone`：运行时权限 ⇒
     *   `requestPermissions`，回 `requested`；
     * · `automation`：厂商专属，无统一申请方式 ⇒ 如实回未实现。
     *
     * 本方法只负责"拉起"；用户回到 App 后权限页重新查询
     * `devicePermissions` 才是权威状态 —— **不在这里猜点了允许还是拒绝**。
     */
    private fun handleRequestPermission(call: MethodCall, result: MethodChannel.Result) {
        val kind = call.argument<String>("kind").orEmpty()
        val ctx = applicationContext
        var action = "requested"
        try {
            when (kind) {
                "notifications" -> {
                    if (notificationsAvailable(ctx)) {
                        return reply(
                            result,
                            mapOf(
                                "ok" to true,
                                "action" to "already_granted",
                                "granted" to true,
                            ),
                        )
                    }
                    if (Build.VERSION.SDK_INT >= 33) {
                        val prefs = permissionPrefs()
                        val requestedBefore =
                            prefs.getBoolean(KEY_REQUESTED_NOTIFICATIONS, false)
                        val canAskAgain = shouldShowRequestPermissionRationale(
                            Manifest.permission.POST_NOTIFICATIONS,
                        )
                        if (!requestedBefore || canAskAgain) {
                            prefs.edit()
                                .putBoolean(KEY_REQUESTED_NOTIFICATIONS, true)
                                .apply()
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQ_POST_NOTIFICATIONS,
                            )
                            return reply(
                                result,
                                mapOf(
                                    "ok" to true,
                                    "action" to "requested",
                                    "granted" to false,
                                ),
                            )
                        }
                    }
                    // API 33+ 永久拒绝，或 API < 33（本就没有运行时权限）：
                    // 系统不会再弹框 —— 只能去通知设置页手动开。
                    openNotificationSettings()
                    return reply(
                        result,
                        mapOf(
                            "ok" to true,
                            "action" to "settings_opened",
                            "granted" to false,
                        ),
                    )
                }
                "notificationsOff" -> {
                    openNotificationSettings()
                    return reply(
                        result,
                        mapOf(
                            "ok" to true,
                            "action" to "settings_opened",
                            "granted" to notificationsAvailable(ctx),
                        ),
                    )
                }
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
                "microphone" -> requestPermissions(
                    arrayOf(Manifest.permission.RECORD_AUDIO), 4025)
                "calendar" -> requestPermissions(
                    arrayOf(
                        Manifest.permission.READ_CALENDAR,
                        Manifest.permission.WRITE_CALENDAR,
                    ),
                    4024,
                )
                "appSettings" -> {
                    action = "settings_opened"
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                "installPackages" -> {
                    action = "settings_opened"
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                "automation" -> return reply(
                    result,
                    mapOf(
                        "ok" to false,
                        "error" to "厂商专属权限，暂无统一申请方式（接口预留）",
                    ),
                )
                "accessibility" -> {
                    action = "settings_opened"
                    startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                "overlay" -> {
                    action = "settings_opened"
                    startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName"),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
                else -> return reply(
                    result, mapOf("ok" to false, "error" to "未知权限项：$kind"))
            }
            reply(result, mapOf("ok" to true, "action" to action))
        } catch (e: Throwable) {
            reply(result, mapOf("ok" to false, "error" to "拉起失败：${e.message}"))
        }
    }

    /**
     * **本机画像**（2026-10-27，JEV 决策引擎本机检测）——
     * 只读：机型、总运行内存（ActivityManager.MemoryInfo.totalMem）、
     * App 私有目录所在分区的可用空间、私有目录路径（本地模型存放锚点）。
     * 读不到的字段给 0 / 空串，Dart 侧按「检测不可用」如实处理，不编造。
     */
    private fun handleDeviceProfile(result: MethodChannel.Result) {
        val ctx = applicationContext
        val totalRamMb = runCatching {
            val am = ctx.getSystemService(android.content.Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            (mi.totalMem / (1024 * 1024)).toInt()
        }.getOrDefault(0)
        val freeStorageMb = runCatching {
            (ctx.filesDir.freeSpace / (1024 * 1024)).toInt()
        }.getOrDefault(0)
        reply(
            result,
            mapOf(
                "ok" to true,
                "model" to (Build.MODEL ?: ""),
                "totalRamMb" to totalRamMb,
                "freeStorageMb" to freeStorageMb,
                "appFilesDir" to ctx.filesDir.absolutePath,
            ),
        )
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
            // B2（2026-10-30）：总开关 + POST_NOTIFICATIONS 权限**双条件** ——
            // 只查 areNotificationsEnabled() 会在"权限 denied 但总开关开"时
            // 谎报 granted（通知其实发不出去），反之亦然。
            if (notificationsAvailable(ctx)) "granted" else "denied"
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

        // 麦克风（2026-10-29 语音识别）：运行时权限 RECORD_AUDIO。
        val microphone = runCatching {
            if (has(Manifest.permission.RECORD_AUDIO)) "granted" else "denied"
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
            "microphone" to microphone,
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
        // ★ 2026-10-29 埋点：证明系统有没有把结果交回来（含 resultCode）
        android.util.Log.i("HeraclesAct", "onActivityResult req=$requestCode res=$resultCode data=${data != null}")
        when (requestCode) {
            FilePickerBridge.REQUEST_CODE -> {
                if (resultCode == RESULT_OK) filePicker.onActivityResult(data)
                else filePicker.onCancelled()
                return
            }
            CameraBridge.REQUEST_CODE -> {
                // ★★ 2026-10-29 真机证据：**不能相信 resultCode** ★★
                //
                // 实测日志（用户点完相机里的 ✓ 之后）：
                //     HeraclesAct: onActivityResult req=18499 res=0 data=false
                //                                        ↑ 0 = RESULT_CANCELED
                //
                // MIUI 系统相机把照片写进了 MediaStore，却回了"取消"。
                // 旧代码见 res != OK 就 `onCancelled()` ⇒ 清掉待处理状态 ⇒
                // 照片被静默丢弃（用户报的「拍照没有附件」正是这个）。
                //
                // 现在一律交给 `onActivityResult`，由它**按"目标 URI 里到底有没有
                // 内容"**判定成功/取消 —— 这是各家 ROM 相机兼容的通行做法。
                cameraBridge.onActivityResult(data)
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
        private const val TAG = "HeraclesAct"

        /**
         * ★ **进程级协程域**（2026-11-02 T0）—— 专给"必须活过 Activity"的收尾工作。
         *
         * 与实例字段 [scope] 的区别：`scope` 在 `onDestroy` 被 cancel，而 SAF 结果
         * 恰恰可能落在 onDestroy **之后**（Activity 被回收重建）。用 `scope` 去
         * 落库 = 协程根本不启动 = 工作区永远登记不上。
         *
         * ⚠️ 这里**只许放纯数据工作**（写 prefs / 登记表 / 回包）。任何碰窗口、
         *    碰 View、要求 Activity 存活的活儿都不许放进来。
         */
        private val processScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

        /** 重建后**新引擎**上的 `heracles/command`（推送 `workspaceAdded` 用）。 */
        @Volatile
        private var liveCommandChannel: MethodChannel? = null

        /** 首帧看门狗：判定"卡住"的等待时长。 */
        private const val WATCHDOG_DELAY_MS = 2_500L

        /** 首帧看门狗：两次自救之间的冷却（防"重建→还黑→再重建"）。 */
        private const val WATCHDOG_COOLDOWN_MS = 30_000L

        /** 上次自救时刻（进程级）。 */
        @Volatile
        private var lastWatchdogRecoverAt = 0L

        /**
         * 本**进程**曾经渲染过 Flutter 首帧。
         *
         * 必须是进程级而不是实例字段：Activity 被系统回收重建后，新实例的
         * 实例字段是 false —— 而那正是"返回前台黑屏"要治的场景，用实例字段
         * 等于看门狗在最需要它的时候不布防。
         *
         * 同时它保证**冷启动慢**（进程还没渲染过首帧）不会被误判成黑屏。
         */
        @Volatile
        private var everRenderedFirstFrame = false

        /**
         * 命令通道名（**保留旧名**）。
         *
         * 设备能力走另一条 `heracles/device`（见 [DeviceChannel.CHANNEL]）。
         */
        private const val CHANNEL = "heracles/command"

        /** 聊天完成通知（2026-10-19）：通道 + 通知 id（固定 id ⇒ 新任务覆盖旧提醒）。 */
        private const val CHAT_CHANNEL_ID = "heracles_chat_done"
        private const val CHAT_NOTIFY_ID = 2001

        /** 用户通知（V0.4 `notify_user` 工具）：独立通道 + 固定兜底 id。 */
        private const val USER_NOTIFY_CHANNEL_ID = "heracles_user_notify"
        private const val USER_NOTIFY_ID = 2002

        /** 完成通知点击时要打开的会话（2026-10-19） */
        private const val EXTRA_NOTIFY_SESSION = "heracles_notify_session"
        private const val EXTRA_NOTIFY_WORKSPACE = "heracles_notify_workspace"

        /** 运行时通知权限的 requestCode（与权限名一一对应即可） */
        private const val REQ_POST_NOTIFICATIONS = 1001

        /** B2（2026-10-30）：权限请求痕迹落盘 —— 判断"永久拒绝"的依据。 */
        private const val PREF_PERMISSIONS = "heracles_permissions"
        private const val KEY_REQUESTED_NOTIFICATIONS = "requested.notifications"
    }
}
