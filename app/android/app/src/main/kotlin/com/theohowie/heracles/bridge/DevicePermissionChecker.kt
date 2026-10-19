package com.theohowie.heracles.bridge

import android.content.Context
import android.content.pm.PackageManager

/**
 * **设备权限状态检测**（2026-10-16，用户需求「接入 Shizuku/stellar/无线调试获取 adb 权限」）。
 *
 * ## 本批范围（用户确认：先做授权引导，完整 shell 能力下批）
 *
 * 检测 + 引导 —— **不做**任何越权尝试：
 * · 检测 `WRITE_SECURE_SETTINGS` 是否已授予（无障碍自愈的钥匙，ADR-016）
 * · 未授予时给出**精确的引导文案**（三渠道：无线调试 / Shizuku / 电脑 adb）
 *
 * ## 为什么第一优先是 WRITE_SECURE_SETTINGS 而不是"通用 shell"
 *
 * ADR-016 已定案：无障碍自愈是 P0（FR-12.2），它的钥匙是这一个权限。
 * 通用 shell（input/dumpsys/am）是设备控制层的能力增强（Phase 5），
 * 两者共用**同一个授权动作**（`pm grant` 一次就都有）——
 * 所以引导只做一次，权限的效果是复用的。
 *
 * ## 三渠道说明（引导文案的依据，docs/10 §2）
 *
 * | 渠道 | 用户操作 | 前提 |
 * |---|---|---|
 * | **电脑 adb** | `adb shell pm grant <pkg> android.permission.WRITE_SECURE_SETTINGS` | 需电脑 |
 * | **无线调试**（Android 11+）| 开发者选项 → 无线调试 → 配对后同一命令（手机上的终端 App 或本 App 将来的引导执行器）| Android 11+ |
 * | **Shizuku** | 装 Shizuku → adb 或无线启动 → App 内点"通过 Shizuku 授权" | 装第三方 App |
 */
object DevicePermissionChecker {

    const val WRITE_SECURE_SETTINGS = "android.permission.WRITE_SECURE_SETTINGS"

    /** `WRITE_SECURE_SETTINGS` 是否已授予（无障碍自愈可用） */
    fun hasWriteSecureSettings(context: Context): Boolean =
        context.checkSelfPermission(WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * 引导文案：**按当前状态给出下一步**。
     *
     * · 已授予 → 空（不需要引导）
     * · 未授予 → 三渠道的具体操作步骤（无线调试优先 —— 无需电脑和第三方）
     */
    fun guidance(context: Context): String {
        if (hasWriteSecureSettings(context)) return ""
        val pkg = context.packageName
        return """
            |Heracles 需要一个一次性授权（用于无障碍自愈等设备能力）。
            |三种方式任选其一：
            |
            |① 无线调试（推荐，Android 11+，无需电脑）
            |   开发者选项 → 无线调试 → 配对后，在终端执行：
            |   adb shell pm grant $pkg $WRITE_SECURE_SETTINGS
            |
            |② 电脑 adb（最简单，如果你在电脑旁）
            |   手机连电脑后执行同上命令。
            |
            |③ Shizuku（已安装 Shizuku 的用户）
            |   启动 Shizuku 后在本 App 设置里点「通过 Shizuku 授权」。
        """.trimMargin()
    }
}
