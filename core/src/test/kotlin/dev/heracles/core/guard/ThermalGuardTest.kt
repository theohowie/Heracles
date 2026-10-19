package dev.heracles.core.guard

import dev.heracles.core.contract.Contract
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * `ThermalGuard` 的行为门禁 —— `26-编码层工具链与逆向引擎.md` §7.4。
 *
 * ## 为什么边界值要单独测
 *
 * 阈值用 `>` 还是 `>=` 是**最容易写错且最难发现**的一类偏差：
 * 43.0°C 到底停不停？代码与文档一旦不一致，运维时永远对不上。
 * 所以这里把 43.0 / 43.1、20% / 19% 都钉死。
 */
class ThermalGuardTest {

    private fun health(percent: Int, tempTenths: Int, charging: Boolean = false) =
        DeviceHealth(percent, tempTenths, charging)

    @Test
    @DisplayName("正常状态放行")
    fun normalStateAllows() {
        assertTrue(ThermalGuard.check(health(80, 300)) is ThermalVerdict.Allow)
    }

    @Test
    @DisplayName("★ 温度**超过** 43.0°C 才暂停；等于 43.0 不暂停")
    fun temperatureBoundary() {
        assertTrue(
            ThermalGuard.check(health(80, 430)) is ThermalVerdict.Allow,
            "43.0°C 恰好等于阈值，不应暂停（规则是 >，不是 >=）",
        )
        val pause = ThermalGuard.check(health(80, 431))
        assertTrue(pause is ThermalVerdict.Pause, "43.1°C 必须暂停")
        assertTrue((pause as ThermalVerdict.Pause).reason.contains("43.1"), "理由要给出实测温度")
    }

    @Test
    @DisplayName("★ 电量**低于** 20% 且未充电 → 暂停；等于 20% 不暂停")
    fun batteryBoundary() {
        assertTrue(ThermalGuard.check(health(20, 300)) is ThermalVerdict.Allow, "20% 不该暂停")
        assertTrue(ThermalGuard.check(health(19, 300)) is ThermalVerdict.Pause, "19% 必须暂停")
    }

    @Test
    @DisplayName("★ 低电量但**在充电** → 放行（本项目对需求原文的显式细化）")
    fun lowBatteryWhileChargingIsExempt() {
        assertTrue(
            ThermalGuard.check(health(5, 300, charging = true)) is ThermalVerdict.Allow,
            "充电中低电量不该阻断 —— 插入电后电量会自己涨回来",
        )
    }

    @Test
    @DisplayName("★ 温度高**不因充电而豁免**（插电不降温）")
    fun highTempIsNotExemptedByCharging() {
        assertTrue(
            ThermalGuard.check(health(80, 450, charging = true)) is ThermalVerdict.Pause,
            "过热必须暂停，与是否充电无关",
        )
    }

    @Test
    @DisplayName("读不到健康数据 → 放行（宁可少拦一次，不要卡死功能）")
    fun unreadableHealthAllows() {
        assertEquals(ThermalVerdict.Allow, ThermalGuard.check(null))
    }

    @Test
    @DisplayName("阈值来自 Contract，不在本文件里另写字面量")
    fun thresholdsComeFromContract() {
        // 若有人改了 Contract 而忘了这里，这条断言会立刻失败
        val t = Contract.Thermal.BATTERY_TEMP_CEILING_TENTHS_C
        val b = Contract.Thermal.BATTERY_FLOOR_PERCENT
        assertEquals(430, t)
        assertEquals(20, b)
        assertTrue(ThermalGuard.check(health(100, t + 1)) is ThermalVerdict.Pause)
        assertTrue(ThermalGuard.check(health(b - 1, 300)) is ThermalVerdict.Pause)
    }
}
