package com.theohowie.heracles.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import com.theohowie.heracles.MainActivity

/**
 * **聊天任务前台服务**（2026-10-19；**2026-11-02 V0.4 补保活**）。
 *
 * ## 解决什么（真机实测发现，不是推演）
 *
 * 上一轮的「任务完成通知」在真机上**从未触发**：发一个 `sleep 40` 的任务、
 * 按 Home 切后台，70 秒后会话仍停在 turn 1 —— **MIUI 把后台 App 冻结了**，
 * 协程与网络全停。任务根本没跑完，自然没有"完成"可言。
 *
 * ⇒ 「后台继续跑」的前提是**前台服务**（构建任务早就有 `AgentBuildService`，
 * 聊天任务却没有）。本服务与它同模式：
 *
 * · run 开始 ⇒ `start()`（此时 App 在前台，满足 FGS 启动限制）
 * · 每个步骤结束 ⇒ `update(标题)`（通知栏文案跟着真实步骤走）
 * · run 结束（成功/失败/取消）⇒ `stop()`
 *
 * ## 2026-11-02 保活补强（V0.4 T0-2）
 *
 * | 项 | 为什么 |
 * |---|---|
 * | `START_STICKY` | 系统杀掉后尽量重建服务；配合 [stop] 的显式停止 |
 * | `onTaskRemoved` | 用户从最近任务划掉 App 时**不静默死**：写"进程被停止"标记并如实告知 |
 * | `PARTIAL_WAKE_LOCK` | 熄屏后 CPU 仍可跑（**run 结束必须释放**，否则是耗电事故） |
 * | `stopWithTask=false` | 划掉任务不连带停服务（清单里也要配） |
 *
 * ## 与 [AgentBuildService] 的分工
 *
 * 那个是**构建专用**（引擎生命周期耦合），本服务只管"聊天 run 别被系统冻结"。
 * 两者渠道/id 都不同，可以同时存在（构建时聊天通知不会顶掉构建通知）。
 */
class AgentChatService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        // ★ 每次 onStartCommand 都要 startForeground：服务被系统重建时
        //   如果不调，5 秒后就是 ANR（Android 的硬性要求）。
        startForeground(NOTIFICATION_ID, buildNotification(text))
        acquireWakeLock()
        // ★ START_STICKY：系统内存回收杀掉后尽量重建（重建时 intent 为 null，
        //   下面用兜底文案；真正的"继续任务"由宿主的 checkpoint 恢复负责，
        //   本服务**不假装**任务还在跑）。
        return START_STICKY
    }

    /**
     * 用户从「最近任务」划掉 App 时调用。
     *
     * **不静默死**：记录 `process_killed` 标记（宿主下次打开时如实提示
     * "上次任务被系统停止"，而不是假装继续）。同时释放 wakelock。
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        markProcessKilled()
        releaseWakeLock()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ---------------------------------------------------------------- wakelock

    /**
     * 拿 **PARTIAL** wake lock（熄屏也能跑 CPU；不亮屏、不耗电在屏幕上）。
     *
     * ⚠️ 纪律：**必须**在 [stop] / [onTaskRemoved] / [onDestroy] 释放 ——
     * 常驻不释放的 wakelock 是真实的耗电事故，比"任务没跑完"更糟。
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        runCatching {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "heracles:chat-run",
            ).apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_TIMEOUT_MS)
            }
        }
    }

    private fun releaseWakeLock() {
        runCatching {
            wakeLock?.let { if (it.isHeld) it.release() }
        }
        wakeLock = null
    }

    /** 写"进程被系统停止"标记（宿主下次打开时读，如实提示）。 */
    private fun markProcessKilled() {
        runCatching {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean(KEY_PROCESS_KILLED, true)
                .putLong(KEY_KILLED_AT, System.currentTimeMillis())
                .apply()
        }
    }

    private fun ensureChannel() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "任务执行中",
                // LOW：状态提示，不该响铃/震动（完成时才提醒 —— 见 MainActivity 的完成通知）
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "聊天任务在后台执行时的常驻提示（关掉它不会中断任务）"
                setShowBadge(false)
            }
        )
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            2,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Heracles 正在执行任务")
            .setContentText(text.ifBlank { "正在处理…" })
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            // API 31+：前台服务的通知默认会被延迟约 10 秒；
            // 用户切走的头几秒正是最需要"它在干活"的时候。
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "heracles_chat_running"

        /** 与完成通知（2001）不同的 id —— 两者可以同时存在 */
        private const val NOTIFICATION_ID = 2000
        private const val EXTRA_TEXT = "text"

        /** wakelock 上限（毫秒）：2 小时。超时自动释放，防止"忘了释放"变成耗电事故。 */
        private const val WAKE_LOCK_TIMEOUT_MS = 2L * 60L * 60L * 1000L

        private const val PREFS = "heracles_chat_service"
        private const val KEY_PROCESS_KILLED = "process_killed"
        private const val KEY_KILLED_AT = "killed_at"

        @Volatile
        var running: Boolean = false
            private set

        /** run 开始时调用（App 在前台 ⇒ 允许启动 FGS）。 */
        fun start(context: Context) {
            try {
                // 新 run 开始 ⇒ 清掉上次"被系统停止"的标记（那次提示已经消费过）。
                runCatching {
                    context.getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                        .remove(KEY_PROCESS_KILLED)
                        .apply()
                }
                context.startForegroundService(
                    Intent(context, AgentChatService::class.java)
                        .putExtra(EXTRA_TEXT, "正在处理你的请求…")
                )
                running = true
            } catch (_: Exception) {
                // 启动限制/系统拒绝 —— 不能让"保活失败"把整个 run 弄崩
            }
        }

        /** 每个步骤结束时更新通知文案（真实步骤，不是假进度）。 */
        fun update(context: Context, text: String) {
            if (!running) return
            runCatching {
                context.startService(
                    Intent(context, AgentChatService::class.java)
                        .putExtra(EXTRA_TEXT, text)
                )
            }
        }

        /** run 结束（成功/失败/取消）时调用。 */
        fun stop(context: Context) {
            running = false
            runCatching { context.stopService(Intent(context, AgentChatService::class.java)) }
        }

        /**
         * **上次 run 是否被系统停止**（宿主打开 App 时读；读完应调 [consumeProcessKilled]）。
         *
         * 用于如实提示「上次任务被系统停止，可从进度继续」，**不假装任务还在跑**。
         */
        fun processKilled(context: Context): Boolean = runCatching {
            context.getSharedPreferences(PREFS, MODE_PRIVATE)
                .getBoolean(KEY_PROCESS_KILLED, false)
        }.getOrDefault(false)

        /** 被停止的时间戳（0 = 无记录）。 */
        fun processKilledAt(context: Context): Long = runCatching {
            context.getSharedPreferences(PREFS, MODE_PRIVATE).getLong(KEY_KILLED_AT, 0L)
        }.getOrDefault(0L)

        /** 提示消费后清标记（避免每次打开都提示）。 */
        fun consumeProcessKilled(context: Context) {
            runCatching {
                context.getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .remove(KEY_PROCESS_KILLED)
                    .apply()
            }
        }

        /**
         * **忽略电池优化引导**（只引导，不改系统设置）。
         *
         * 返回 false = 系统不支持该 Intent（调用方应显示人话说明，而不是静默失败）。
         */
        fun requestIgnoreBatteryOptimizations(context: Context): Boolean = runCatching {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
            val pm = context.getSystemService(POWER_SERVICE) as PowerManager
            if (pm.isIgnoringBatteryOptimizations(context.packageName)) return true
            context.startActivity(
                Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(android.net.Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        }.getOrDefault(false)

        /**
         * **OEM 自启引导数据**（只给数据，不自动跳转）。
         *
         * 返回 `厂商 → 人话路径`；宿主设置页按厂商显示对应文案。
         * 认不出厂商 ⇒ 返回通用文案（**不编造具体路径**）。
         */
        fun autostartGuide(): Pair<String, String> {
            val brand = (Build.BRAND + " " + Build.MANUFACTURER).lowercase()
            return when {
                brand.contains("xiaomi") || brand.contains("redmi") ->
                    "小米/Redmi" to "设置 → 应用设置 → 应用管理 → Heracles → 自启动（允许）"
                brand.contains("huawei") || brand.contains("honor") ->
                    "华为/荣耀" to "设置 → 应用 → 应用启动管理 → Heracles → 手动管理（允许自启动）"
                brand.contains("oppo") || brand.contains("realme") ->
                    "OPPO/realme" to "设置 → 电池 → 应用耗电管理 → Heracles → 允许后台运行"
                brand.contains("vivo") || brand.contains("iqoo") ->
                    "vivo/iQOO" to "设置 → 电池 → 后台耗电管理 → Heracles → 允许后台高耗电"
                brand.contains("samsung") ->
                    "三星" to "设置 → 电池 → 后台使用限制 → 把 Heracles 加入「永不休眠」"
                else -> "通用" to "设置 → 电池 → 找到 Heracles → 允许后台运行/不受限制（不同机型路径不同）"
            }
        }
    }
}

