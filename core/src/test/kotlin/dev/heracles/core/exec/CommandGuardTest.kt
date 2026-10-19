package dev.heracles.core.exec

import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.DisplayName
import org.junit.jupiter.api.Test

/**
 * `CommandGuard` 的行为门禁 —— `26-编码层工具链与逆向引擎.md` §8.1。
 *
 * ## 为什么这个测试不能省
 *
 * `AGENTS.md` 有一条**用事故换来**的硬约束：
 * 禁止 kill / force-stop 用户设备上的任何应用（2026-10-09 我 force-stop 了
 * 用户的 `com.liuzh.deviceinfo` 监控 App）。
 *
 * 而 `run_shell_command` 给了模型任意 shell —— 提示词不是防线（ADR-017），
 * **代码 + 测试**才是。这个文件就是那条约束的守卫。
 */
class CommandGuardTest {

    private fun deny(cmd: String): String {
        val v = CommandGuard.check(cmd)
        assertTrue(v is CommandGuard.Deny, "「$cmd」应当被硬拒绝，实际是 $v")
        return (v as CommandGuard.Deny).reason
    }

    private fun allow(cmd: String) {
        val v = CommandGuard.check(cmd)
        assertTrue(v is CommandGuard.Allow, "「$cmd」应当放行，实际是 $v")
    }

    private fun needsApproval(cmd: String) {
        val v = CommandGuard.check(cmd)
        assertTrue(v is CommandGuard.NeedsApproval, "「$cmd」应当需确认，实际是 $v")
    }

    // ------------------------------------------------------------- 禁止杀应用

    @Test
    @DisplayName("★ force-stop 一律硬拒绝（AGENTS.md 事故约束）")
    fun forceStopIsDenied() {
        deny("am force-stop com.example.app")
        deny("am  force-stop  com.foo")
        deny("force-stop com.foo")
        // ★ 藏在 sh -c 的参数里也要拦得住 —— 这是全局扫描存在的理由
        deny("""sh -c "am force-stop com.foo"""")
        deny("adb shell am force-stop com.foo")
    }

    @Test
    @DisplayName("★ kill / killall / pkill 一律硬拒绝")
    fun killIsDenied() {
        deny("kill 1234")
        deny("kill -9 1234")
        deny("/system/bin/kill 1234")
        deny("killall com.foo")
        deny("pkill -f foo")
        deny("am kill com.foo")
    }

    @Test
    @DisplayName("设备级操作（reboot / shutdown / fastboot / setenforce）硬拒绝")
    fun deviceLevelOpsDenied() {
        deny("reboot")
        deny("reboot recovery")
        deny("shutdown")
        deny("svc power reboot")
        deny("fastboot flash boot boot.img")
        deny("setenforce 0")
        deny("pm disable com.foo")
        deny("dd if=/dev/zero of=/dev/block/mmcblk0")
    }

    // ------------------------------------------------------------- 数据破坏

    @Test
    @DisplayName("★ 删根目录 / 用户数据区硬拒绝")
    fun destructiveRootRemovalDenied() {
        deny("rm -rf /")
        deny("rm -rf /*")
        deny("rm -rf /sdcard")
        deny("rm -rf /storage/emulated/0")
        deny("rm -rf /system")
        deny("rm -rf /data")
        deny("rm -rf /data/data")
        deny("rm -rf ~")
    }

    @Test
    @DisplayName("★ /data/local/tmp 例外 —— 它是 ADR-009 的合法暂存区")
    fun dataLocalTmpIsNotBlanketDenied() {
        // 不是 Deny（能否执行仍要用户确认，因为它是递归删除）
        val v = CommandGuard.check("rm -rf /data/local/tmp/llama-old")
        assertTrue(v !is CommandGuard.Deny, "/data/local/tmp 不应被硬拒绝，实际是 $v")
    }

    @Test
    @DisplayName("工作区内的递归删除 → 需确认（不是硬拒绝）")
    fun recursiveWorkspaceRemovalNeedsApproval() {
        needsApproval("rm -rf build")
        needsApproval("rm -r out")
        needsApproval("rm -rf .heracles/build")
        // 前导赋值也要能识别出命令是 rm
        needsApproval("BUILD=out rm -rf \$BUILD")
    }

    // ------------------------------------------------------------- 正常放行

    @Test
    @DisplayName("构建工作流的正常命令必须放行（否则工具链没法用）")
    fun normalBuildCommandsAreAllowed() {
        allow("ls -la")
        allow("aapt2 compile --dir res -o build/res.zip")
        allow("javac -J-Xmx512m -d build/classes src/MainActivity.java")
        allow("echo hi && ls -la")
        allow("grep -n TODO src/MainActivity.java")
        allow("apksigner verify --print-certs out.apk")
        allow("rm stale.txt")
    }

    @Test
    @DisplayName("安装 / 卸载 / 清数据 → 需确认")
    fun packageOpsNeedApproval() {
        needsApproval("pm install -r out.apk")
        needsApproval("pm uninstall com.example.app")
        needsApproval("pm clear com.example.app")
    }

    @Test
    @DisplayName("空命令直接拒绝")
    fun blankCommandDenied() {
        deny("")
        deny("   ")
    }

    @Test
    @DisplayName("分段判定：危险命令在任一段都要拦（不能只看第一段）")
    fun dangerInLaterSegmentIsCaught() {
        deny("echo start && am force-stop com.foo")
        deny("ls; kill 1")
        deny("ls | reboot")
    }
}
