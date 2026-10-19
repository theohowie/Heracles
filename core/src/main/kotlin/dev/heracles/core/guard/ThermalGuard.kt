package dev.heracles.core.guard

/**
 * 设备健康快照 —— `26-编码层工具链与逆向引擎.md` §7.4。
 *
 * ## 为什么是"快照"而不是"监听"
 *
 * 熔断只需要在**任务开始前**和**任务进行中**各检查几次。注册广播监听器
 * 会引入生命周期管理（注册/注销/泄漏），而收益是"能提前几秒知道"——
 * 与复杂度不成比例。轮询即可（间隔见 [dev.heracles.core.contract.Contract.Thermal.CHECK_INTERVAL_MS]）。
 */
data class DeviceHealth(
    /** 电量百分比 0–100 */
    val batteryPercent: Int,
    /**
     * 电池温度，单位 **0.1 °C**。430 = 43.0 °C。
     *
     * 单位沿用 Android `BatteryManager.EXTRA_TEMPERATURE` 的原生单位，
     * **不在这一层换算** —— 换算会让"阈值"和"读数"两个数字用不同单位，
     * 是经典的埋雷点。
     */
    val batteryTempTenthsC: Int,
    /** 是否在充电 */
    val charging: Boolean,
) {
    val tempCelsius: Double get() = batteryTempTenthsC / 10.0
}

/**
 * 健康数据的来源 —— 在 Android 侧由 `BatteryManager` 实现，
 * 测试侧给假数据。`null` 表示**读不到**（不是"健康"）。
 */
interface DeviceHealthSource {
    /** 读一次当前状态；读不到返回 null */
    suspend fun read(): DeviceHealth?
}

/** 熔断判定结果。 */
sealed interface ThermalVerdict {
    /** 可以继续干活 */
    data object Allow : ThermalVerdict

    /**
     * 暂停。**不是中止** —— 充电 / 降温后可以继续，
     * 已完成的工作不丢（见 `26` §7.4：任务状态落盘）。
     */
    data class Pause(val reason: String) : ThermalVerdict
}

/**
 * 电量 / 温度熔断 —— `26-编码层工具链与逆向引擎.md` §7.4。
 *
 * ## 依据
 *
 * `实测-04-内存与热行为.md`：设备在长时间构建下**热**起来之后，
 * 不是"慢一点"，而是进入**持续降频**——之后每一轮都在为这次过热付代价。
 * 所以到阈值就**停下来**，比"硬扛着跑完"总耗时更短。
 *
 * ## 一条对需求的**显式细化**（不要当成需求原文）
 *
 * 需求原文：「构建任务期间检测电量 < 20% 或温度 > 43°C 时暂停任务」。
 *
 * 本项目在**低电量**分支上多加了一个条件：**充电中不停**。
 *
 * 理由：这条规则要防的是"跑到一半没电，白干"。插着电时这个前提不成立，
 * 而停下来反而浪费——尤其是从 19% 插上电、涨到 20% 又要等的情况。
 * 温度分支**没有**类似豁免：温度高就是真的高，插电不解决。
 *
 * 如果你要的是**字面**语义（哪怕充电也停在 20%），把
 * [LOW_BATTERY_EXEMPT_WHEN_CHARGING] 改成 false 即可，测试两条分支都覆盖了。
 */
object ThermalGuard {

    /** 低电量 + 充电时是否豁免。见类注释的"显式细化"一节。 */
    const val LOW_BATTERY_EXEMPT_WHEN_CHARGING = true

    fun check(health: DeviceHealth?): ThermalVerdict {
        // 读不到健康数据 ≠ 健康。但也**不能**因此把任务堵死 ——
        // 真机上 BatteryManager 偶发读不到，直接 Pause 会让工具莫名不可用。
        // 取"放行"，同时这是**明确记录的取舍**：宁可少拦一次，不要卡死。
        if (health == null) return ThermalVerdict.Allow

        if (health.batteryTempTenthsC > TEMP_CEILING) {
            return ThermalVerdict.Pause(
                "设备温度 ${health.tempCelsius}°C 已超过 ${TEMP_CEILING / 10.0}°C。" +
                    "继续构建会进入持续降频，反而更慢。请让设备降温（移开充电器、取下保护壳、待机几分钟）后继续。"
            )
        }

        val lowBattery = health.batteryPercent < BATTERY_FLOOR
        val exempt = LOW_BATTERY_EXEMPT_WHEN_CHARGING && health.charging
        if (lowBattery && !exempt) {
            return ThermalVerdict.Pause(
                "电量 ${health.batteryPercent}% 低于 ${BATTERY_FLOOR}%，且未在充电。" +
                    "构建可能中途断电导致工作作废。请先充电再继续。"
            )
        }

        return ThermalVerdict.Allow
    }

    /**
     * 阈值直接取自 [dev.heracles.core.contract.Contract] ——
     * 魔法数字只允许有一个定义处（`AGENTS.md` 硬约束）。
     */
    private val TEMP_CEILING
        get() = dev.heracles.core.contract.Contract.Thermal.BATTERY_TEMP_CEILING_TENTHS_C
    private val BATTERY_FLOOR
        get() = dev.heracles.core.contract.Contract.Thermal.BATTERY_FLOOR_PERCENT
}
