package com.theohowie.heracles.bridge

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject

/**
 * **自动化任务调度器**（V0.4 T1-5，2026-11-02）—— 用 **AlarmManager**（Android 内置，
 * 无新依赖）做真实定时；触发后**不假装跑了 agent**，而是：
 *
 * 1. 发一条"任务到点了"通知（用户可点进来）；
 * 2. 写 `pending_automation` 标记（App 打开时由 Dart 侧真正发起 run）。
 *
 * ## 为什么不直接在这里跑 agent
 *
 * agent 在 **Dart/Flutter 侧**（`LocalAgentExecutor`），Kotlin 服务里没有它。
 * 硬在 Receiver 里跑等于再造一个执行栈（两套真相）。所以这里只做**可靠触发**，
 * 执行由 App 前台完成 —— 与 T0-2 的"进程被杀 → checkpoint 恢复"同一思路：
 * **不假装**、可恢复。
 *
 * ## 进程死可恢复
 *
 * 任务清单持久化在 SharedPreferences（JSON）；AlarmManager 的 `setRepeating`
 * 在重启后失效 ⇒ 开机时 `BootReceiver` 重新注册（见 [BootReceiver]）。
 */
object AutomationScheduler {
    private const val PREFS = "heracles_automation"
    private const val KEY_TASKS = "tasks"
    private const val KEY_PENDING = "pending"

    /** 保存/更新任务清单（JSON 字符串，由 Dart 侧生成）。 */
    fun saveTasks(context: Context, tasksJson: String): Boolean = runCatching {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_TASKS, tasksJson).apply()
        rescheduleAll(context)
        true
    }.getOrDefault(false)

    fun loadTasks(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_TASKS, "[]") ?: "[]"

    /** 取出并清空"到点待执行"的标记（App 打开时调用）。 */
    fun consumePending(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_PENDING, "[]") ?: "[]"
        prefs.edit().remove(KEY_PENDING).apply()
        return raw
    }

    /** 按已保存的任务清单重新注册所有闹钟。 */
    fun rescheduleAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val tasks = runCatching { JSONArray(loadTasks(context)) }.getOrElse { JSONArray() }
        for (i in 0 until tasks.length()) {
            val t = tasks.optJSONObject(i) ?: continue
            if (!t.optBoolean("enabled", true)) continue
            val id = t.optString("id", "")
            if (id.isBlank()) continue
            val minutes = t.optInt("intervalMinutes", 0)
            if (t.optString("schedule", "interval") != "interval" || minutes <= 0) {
                // cron 解析未实现 ⇒ 不注册（不假装支持）；Dart 侧会如实提示
                continue
            }
            registerInterval(context, am, id, minutes)
        }
    }

    private fun registerInterval(
        context: Context,
        am: AlarmManager,
        id: String,
        minutes: Int,
    ) {
        val pi = PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            Intent(context, AutomationReceiver::class.java)
                .putExtra("taskId", id)
                .setAction(ACTION_FIRE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val intervalMs = minutes.toLong() * 60_000L
        // ★ setInexactRepeating：不需要精确到毫秒，且省电（Android 官方推荐用于周期任务）；
        //   精确闹钟需要 SCHEDULE_EXACT_ALARM 权限，不该为一个后台提醒去要。
        am.setInexactRepeating(
            AlarmManager.RTC_WAKEUP,
            System.currentTimeMillis() + intervalMs,
            intervalMs,
            pi,
        )
    }

    fun cancelAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val tasks = runCatching { JSONArray(loadTasks(context)) }.getOrElse { JSONArray() }
        for (i in 0 until tasks.length()) {
            val id = tasks.optJSONObject(i)?.optString("id", "") ?: continue
            if (id.isBlank()) continue
            val pi = PendingIntent.getBroadcast(
                context,
                id.hashCode(),
                Intent(context, AutomationReceiver::class.java).setAction(ACTION_FIRE),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            am.cancel(pi)
        }
    }

    const val ACTION_FIRE = "com.theohowie.heracles.AUTOMATION_FIRE"
}

/** **到点触发**：发通知 + 写 pending 标记（**不假装跑了 agent**）。 */
class AutomationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != AutomationScheduler.ACTION_FIRE) return
        val taskId = intent.getStringExtra("taskId").orEmpty()
        if (taskId.isBlank()) return
        runCatching {
            val prefs = context.getSharedPreferences("heracles_automation", Context.MODE_PRIVATE)
            val old = prefs.getString("pending", "[]") ?: "[]"
            val arr = runCatching { JSONArray(old) }.getOrElse { JSONArray() }
            arr.put(taskId)
            prefs.edit().putString("pending", arr.toString()).apply()
        }
        // 通知：告诉用户"有个定时任务到点了"，点进来由 App 执行
        runCatching {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as android.app.NotificationManager
            if (nm.getNotificationChannel("heracles_automation") == null) {
                nm.createNotificationChannel(
                    android.app.NotificationChannel(
                        "heracles_automation",
                        "定时任务",
                        android.app.NotificationManager.IMPORTANCE_DEFAULT,
                    )
                )
            }
            val open = PendingIntent.getActivity(
                context,
                4,
                Intent(context, com.theohowie.heracles.MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val n = android.app.Notification.Builder(context, "heracles_automation")
                .setContentTitle("定时任务到点了")
                .setContentText("打开 Heracles 继续执行（任务 id: $taskId）")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentIntent(open)
                .setAutoCancel(true)
                .build()
            nm.notify(2003, n)
        }
    }
}

/** **开机重注册**：AlarmManager 的周期闹钟在重启后失效。 */
class AutomationBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        runCatching { AutomationScheduler.rescheduleAll(context) }
    }
}
