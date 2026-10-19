package com.theohowie.heracles.bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import com.theohowie.heracles.MainActivity

/**
 * **聊天任务前台服务**（2026-10-19）。
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
 * ## 与 [AgentBuildService] 的分工
 *
 * 那个是**构建专用**（引擎生命周期耦合），本服务只管"聊天 run 别被系统冻结"。
 * 两者渠道/id 都不同，可以同时存在（构建时聊天通知不会顶掉构建通知）。
 */
class AgentChatService : Service() {

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT).orEmpty()
        // ★ 每次 onStartCommand 都要 startForeground：服务被系统重建时
        //   如果不调，5 秒后就是 ANR（Android 的硬性要求）。
        startForeground(NOTIFICATION_ID, buildNotification(text))
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

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

        @Volatile
        var running: Boolean = false
            private set

        /** run 开始时调用（App 在前台 ⇒ 允许启动 FGS）。 */
        fun start(context: Context) {
            try {
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
    }
}
