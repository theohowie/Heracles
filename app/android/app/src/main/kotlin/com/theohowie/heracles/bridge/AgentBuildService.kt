package com.theohowie.heracles.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.theohowie.heracles.MainActivity

/**
 * **构建前台服务** —— `26-编码层工具链与逆向引擎.md` §7.1。需求模块 5。
 *
 * ## 它解决什么：LMK 不会因为"App 在后台"就把构建杀掉
 *
 * Android 的低内存杀手（LMK）按**进程优先级**回收。App 退到后台后，
 * 进程从 foreground 掉到 cached —— 那是**第一个**被杀的一档。
 * 而一次 `aapt2 + javac + d8` 全量构建在真机上要**1–3 分钟**
 * （`26` §7.1 实测），用户在这段时间里几乎必然会切走。
 *
 * ⇒ 只要有一个前台服务在跑，进程优先级就是 foreground，
 * LMK 不会因为"内存紧张"而把它回收。这就是本类存在的全部理由。
 *
 * ## 两个容易写错的点
 *
 * ### ① 前台服务**必须**在 5 秒内 `startForeground`，否则直接崩
 *
 * 所以 `onStartCommand` 的第一件事就是 `startForeground`，
 * 不允许在前面做任何可能阻塞的事（读文件、起线程）。
 *
 * ### ② API 34+ 要求声明**类型**，且类型必须与清单里的权限匹配
 *
 * 构建属于 `dataSync`。清单里必须同时有
 * `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />`，
 * 否则 `startForeground` 抛 `SecurityException` —— 而且报错信息只会说
 * "not allowed to start foreground service"，不会告诉你缺哪条权限。
 *
 * ## 通知是"给用户看的进度"，不是装饰
 *
 * 一个跑两分钟、界面已经切走、却没有任何提示的后台服务，
 * 用户只会以为 App 卡死了。进度文案就是它的可观测性。
 *
 * ## ⚠️ 真机验证状态
 *
 * 2026-10-17 真机（Android 17）：服务起得来（自检 `① isRunning=true`）、
 * 构建期间通知栏在位、构建日志见 `实测-12` §13。**自启停**由
 * [com.theohowie.heracles.bridge.BuildTaskProgress] 接在工具层（见 `26` §6.4）。
 */
class AgentBuildService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // ★ 第一步就必须是它（见类注释 ①）；显式给类型，不靠清单推断
        startForeground(NOTIFICATION_ID, buildNotification(currentText), SERVICE_TYPE)
        running = true
        currentText = intent?.getStringExtra(EXTRA_TEXT) ?: "准备构建…"
        updateNotification(currentText)

        return when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                START_NOT_STICKY
            }
            // 构建任务由 App 自己的协程持有。服务被系统重启后**没有**任务在跑，
            // START_STICKY 会留下一个"假装在工作"的通知 —— 比不重启更糟。
            else -> START_NOT_STICKY
        }
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun ensureChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            "构建任务",
            // LOW：构建进度不该响铃/震动 —— 它是状态，不是提醒
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "编译 APK / 反编译时的进度提示（关掉它不会中断构建）"
            setShowBadge(false)
        }
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Heracles 正在构建")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(open)
            .setOngoing(true)          // 不可划掉 —— 划掉会让用户以为任务停了
            .setOnlyAlertOnce(true)    // 更新时不重复打扰
            // ★ API 31+「前台服务通知**延迟**」的对策（2026-10-17 真机抓到，见 `实测-12` §13.4）：
            //   默认行为下，**App 在前台**时启动的前台服务，其通知会被系统**延迟约 10 秒**
            //   才显示（防"两秒钟的任务也闪一下通知"）。构建通常远超 10 s，看上去没事；
            //   但用户切走前的头几秒恰恰是最需要"它在干活"的几秒。
            //   IMMEDIATE = 立刻显示。minSdk = 31 ⇒ 这个常量永远可用。
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification(text))
    }

    companion object {
        private const val CHANNEL_ID = "heracles-build"
        private const val NOTIFICATION_ID = 0x4865 // 'He'
        private const val EXTRA_TEXT = "text"

        const val ACTION_STOP = "com.theohowie.heracles.STOP_BUILD"

        @Volatile
        private var running = false

        @Volatile
        private var currentText = "准备构建…"

        /** 服务是否在跑（前端可据此显示"后台构建中"）。 */
        fun isRunning(): Boolean = running

        /**
         * 通知栏里**现在有没有**本服务的通知。
         *
         * 与 [isRunning] 分开是有意的：`running` 只说明"服务在跑"，
         * **不说明用户看得见进度**（权限被拒 / 渠道被关 / 厂商 ROM 都会让通知不显示）。
         * 自检要验的正是后者 —— 一个"跑着但没通知"的前台服务，用户眼里就是 App 卡死。
         *
         * 需要 API 23+（`getActiveNotifications`），本项目 `minSdk = 31`。
         */
        fun isNotificationVisible(context: Context): Boolean {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            return nm.activeNotifications.any {
                it.id == NOTIFICATION_ID && it.packageName == context.packageName
            }
        }

        /** 开始（或更新）前台服务，并写入一行进度文案。 */
        fun start(context: Context, text: String = "准备构建…") {
            currentText = text
            val i = Intent(context, AgentBuildService::class.java).apply {
                putExtra(EXTRA_TEXT, text)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(i)
            } else {
                context.startService(i)
            }
        }

        /**
         * 更新进度。
         *
         * 服务没在跑时**静默忽略** —— 让调用方不必先查状态。
         * （显式启动由 [start] 负责，避免"构建失败也留下一个通知"。）
         */
        fun progress(context: Context, text: String) {
            currentText = text
            if (!running) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val n = Notification.Builder(context, CHANNEL_ID)
                .setContentTitle("Heracles 正在构建")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .build()
            nm.notify(NOTIFICATION_ID, n)
        }

        /** 结束并撤掉通知。构建任务无论成功失败都**必须**调它。 */
        fun stop(context: Context) {
            running = false
            context.stopService(Intent(context, AgentBuildService::class.java))
        }

        /**
         * 服务类型：`dataSync`。
         *
         * 供清单与本类**共用同一个语义** —— 两边不一致是 API 34+ 上
         * `startForeground` 直接失败的经典原因，且报错不指向类型。
         * 清单里的 `android:foregroundServiceType="dataSync"` 与
         * `FOREGROUND_SERVICE_DATA_SYNC` 权限必须同时存在。
         */
        val SERVICE_TYPE: Int = ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
    }
}
