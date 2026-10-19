package com.theohowie.heracles.bridge

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import dev.heracles.core.contract.Contract
import dev.heracles.core.guard.DeviceHealth
import dev.heracles.core.guard.DeviceHealthSource

/**
 * 真机健康数据来源 —— `26-编码层工具链与逆向引擎.md` §7.4。
 *
 * ## 两个字段来自**两个不同的 API**（这不是冗余，是必须）
 *
 * | 字段 | 来源 | 原因 |
 * |---|---|---|
 * | 电量百分比 | `BatteryManager.BATTERY_PROPERTY_CAPACITY` | 直接给整数百分比，无需换算 |
 * | 温度 / 充电状态 | `ACTION_BATTERY_CHANGED` **粘性广播** | `BatteryManager` 没有温度属性；温度只在广播的 extra 里 |
 *
 * ## `registerReceiver(null, …)` 不是笔误
 *
 * 传 `null` 的 receiver 表示**只读粘性广播的当前值，不注册监听器**。
 * 这样没有任何需要注销的生命周期，也就不可能泄漏。
 *
 * 熔断只需要"此刻"的快照（每 [Contract.Thermal.CHECK_INTERVAL_MS] 读一次），
 * 不需要事件流。
 *
 * ## 读不到就返回 null（**不是**返回"健康"）
 *
 * `null` 表示"这次没读到"。上层 [dev.heracles.core.guard.ThermalGuard] 遇到
 * `null` 会**放行** —— 那是刻意的取舍（宁可少拦一次，也不要把功能莫名堵死），
 * 理由写在那边的类注释里。
 *
 * ## ⚠️ 未在真机验证（2026-10-16 无设备）
 *
 * 已通过 `:android-probe:compileDebugKotlin`。首次真机使用请对照
 * 设置页里的"设备温度"读数是否与系统设置一致。
 */
class SystemHealthSource(private val context: Context) : DeviceHealthSource {

    override suspend fun read(): DeviceHealth? {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            ?: return null

        val percent = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (percent < 0) return null

        val raw: Intent? = try {
            context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (e: Throwable) {
            null
        }
        // 分开写：`try { } catch { } ?: return` 的 elvis 归属容易读错，
        // 也让类型推断停在 `Intent?` 上（实测编译报"可空接收者"）
        val sticky: Intent = raw ?: return null

        // ★ 单位是 0.1°C（Android 原生），**不在这里换算** ——
        //   换算会让"阈值"与"读数"两个数字用不同单位（见 DeviceHealth 注释）
        val temp = sticky.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
        if (temp == Int.MIN_VALUE) return null

        val status = sticky.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL

        return DeviceHealth(
            batteryPercent = percent,
            batteryTempTenthsC = temp,
            charging = charging,
        )
    }
}
