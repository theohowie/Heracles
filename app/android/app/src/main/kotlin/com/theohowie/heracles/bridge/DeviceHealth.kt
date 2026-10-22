package com.theohowie.heracles.bridge

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * **设备健康读数**（2026-10-22）—— `heracles/device` 通道里 `health.read` 的实现。
 *
 * 替代已删除的 `SystemHealthSource`（它实现的是 `:core` 的 `DeviceHealthSource` 接口）。
 * 现在只产出通道要的三个字段，**不再有任何熔断逻辑** —— 熔断归 Dart 后端。
 *
 * ## 三个字段来自**两个不同的 API**（这不是冗余，是必须）
 *
 * | 字段 | 来源 | 原因 |
 * |---|---|---|
 * | `battery`（百分比） | `BatteryManager.BATTERY_PROPERTY_CAPACITY` | 直接给整数百分比 |
 * | `tempC` / `charging` | `ACTION_BATTERY_CHANGED` **粘性广播** | `BatteryManager` 没有温度属性 |
 *
 * ## `registerReceiver(null, …)` 不是笔误
 *
 * 传 `null` 的 receiver 表示**只读粘性广播的当前值，不注册监听器** ——
 * 没有生命周期，也就不可能泄漏。熔断只需要"此刻"的快照。
 *
 * ## 读不到就返回 **null**（**不许编造**）
 *
 * 这是安全熔断的输入。返回一个假的"健康"会让熔断在设备已经发烫时放行；
 * 返回假的"发烫"会无故阻断用户的构建。
 * ⇒ 单个字段读不到就 `null`，并让 `ok` 仍然为 true（**问到了，只是没有值**）。
 * 整个读取流程都失败时 `ok=false` + `error`，让 Dart 侧能区分"没值"与"问不到"。
 */
class DeviceHealth(private val context: Context) {

    /** `health.read` → `{ok, battery:int?, tempC:double?, charging:bool?}` */
    suspend fun read(): Map<String, Any?> = withContext(Dispatchers.IO) {
        try {
            val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
                ?: return@withContext failure("系统没有提供电池服务（BatteryManager 不可用）")

            // ---- ① 电量百分比 ----
            // getIntProperty 读不到时返回 Int.MIN_VALUE；负数一律视为"没读到"
            val rawPercent = runCatching {
                bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            }.getOrDefault(Int.MIN_VALUE)
            val battery: Int? = if (rawPercent < 0 || rawPercent > 100) null else rawPercent

            // ---- ② 温度 + ③ 充电状态（粘性广播）----
            val sticky: Intent? = runCatching {
                context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            }.getOrNull()

            // ★ 单位：EXTRA_TEMPERATURE 是 **0.1 °C**（Android 原生）。
            //   通道契约要的是 **°C**（double），所以这里 /100f 换算一次 ——
            //   换算放在 Kotlin 而不是 Dart，因为"原始单位是什么"只有 Android 这边知道。
            val tempTenths = sticky?.getIntExtra(
                BatteryManager.EXTRA_TEMPERATURE,
                Int.MIN_VALUE,
            ) ?: Int.MIN_VALUE
            val tempC: Double? = if (tempTenths == Int.MIN_VALUE || tempTenths <= 0) {
                null
            } else {
                tempTenths / 100.0
            }

            val status = sticky?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val charging: Boolean? = when (status) {
                BatteryManager.BATTERY_STATUS_CHARGING,
                BatteryManager.BATTERY_STATUS_FULL,
                -> true
                BatteryManager.BATTERY_STATUS_DISCHARGING,
                BatteryManager.BATTERY_STATUS_NOT_CHARGING,
                -> false
                // UNKNOWN / 读不到 ⇒ **null**，不要默认成"没在充电"
                else -> null
            }

            // 三个字段全 read 不到 ⇒ 这不是"健康"，是"问不到" —— 如实报失败
            if (battery == null && tempC == null && charging == null) {
                return@withContext failure(
                    "读不到电池状态（系统未返回电量/温度/充电信息）—— " +
                        "可能是模拟器或厂商 ROM 屏蔽了该广播"
                )
            }

            mapOf(
                "ok" to true,
                "battery" to battery,
                "tempC" to tempC,
                "charging" to charging,
            )
        } catch (e: Throwable) {
            failure("读取设备健康数据失败：${e.javaClass.simpleName}: ${e.message}")
        }
    }

    private fun failure(reason: String): Map<String, Any?> =
        mapOf(
            "ok" to false,
            "error" to reason,
            // 读不到就是 null，**不填任何编造值**
            "battery" to null,
            "tempC" to null,
            "charging" to null,
        )
}
