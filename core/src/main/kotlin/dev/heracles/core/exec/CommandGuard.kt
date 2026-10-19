package dev.heracles.core.exec

/**
 * 命令放行判定 —— `26-编码层工具链与逆向引擎.md` §8.1。
 *
 * ## 为什么必须有它（这是 `AGENTS.md` 硬约束的代码化）
 *
 * `run_shell_command` 让模型获得了**任意 shell**。而 `AGENTS.md` 里有一条
 * 用事故换来的硬约束：
 *
 * > **禁止 kill / force-stop 用户设备上的任何应用。设备是用户的，不是测试沙箱。**
 * > （2026-10-09 事故：我 force-stop 了用户的 `com.liuzh.deviceinfo` 监控 App）
 *
 * 提示词**不是防线**（ADR-017 的教训：4B 模型在否定性约束上不可靠，
 * 而且它能"通过校验、静默走错路"）。所以这条约束必须落在**代码**里，
 * 并且由单元测试守卫（`CommandGuardTest`）。
 *
 * ## ⚠️ 能力边界（不要过度宣称）
 *
 * 这是**正则 + 分段**判定，不是 shell 解析器。已知缺口：
 *
 * | 缺口 | 例子 | 处置 |
 * |---|---|---|
 * | 变量拼接 | `A=for; ${A}ce-stop x` | 拦不住 |
 * | base64 / eval 构造 | `eval "$(echo Zm9yY2Utc3RvcA== \| base64 -d)"` | 拦不住 |
 * | 自定义脚本包装 | `sh ./evil.sh`（脚本内容含 kill） | 拦不住 |
 *
 * **这是刻意的取舍**：目标是防**模型的无意破坏**（它会在"清理进程"时
 * 自然地写出 `kill`/`force-stop`），而不是防一个蓄意攻击者 ——
 * 后者在这个架构里本来就不成立（模型没有理由、也没有持久化动机）。
 *
 * 真要在架构层堵住上面三项，需要沙箱 / seccomp，那是另一个量级的工作。
 * **宁如实声明边界，也不假装它拦得住一切。**
 */
object CommandGuard {

    sealed interface Verdict

    /** 放行 */
    data object Allow : Verdict

    /** **硬拒绝** —— 不提供"确认后执行"的选项 */
    data class Deny(val reason: String) : Verdict

    /** 需用户确认；复用已有的 `ToolOutcome.NeedsApproval` 通路 */
    data class NeedsApproval(val reason: String) : Verdict

    // ---------------------------------------------------------------- 判定

    /**
     * 判定一条命令。
     *
     * 顺序**不可调换**：先全局扫描（`sh -c "…"` 会把危险命令藏在参数里），
     * 再做命令位置检查，最后看破坏性操作。
     */
    fun check(command: String): Verdict {
        val cmd = command.trim()
        if (cmd.isEmpty()) return Deny("命令为空")

        // ① 全局扫描：这些词**无论出现在什么位置**都危险
        //    （因为 sh -c "am force-stop x" 里它是参数，不是命令名）
        val global = GLOBAL_DENY.firstOrNull { it.first.containsMatchIn(cmd) }
        if (global != null) return Deny(global.second)

        // ② 命令位置检查：按 ; && || | 换行 切段，看每段的第一个词
        val segments = cmd.split(SEGMENT_SPLIT).map { it.trim() }.filter { it.isNotEmpty() }
        for (seg in segments) {
            val verb = firstToken(seg).substringAfterLast('/').lowercase()
            when (verb) {
                "kill" -> return Deny(KILL_REASON)
                in DESTRUCTIVE_VERBS -> { /* 交给 ③ 细分 */ }
            }
        }

        // ③ 破坏性操作细分
        for (seg in segments) {
            val tokens = seg.split(Regex("\\s+")).filter { it.isNotEmpty() }
            if (tokens.isEmpty()) continue
            // ★ 命令名**必须**用 firstToken（跳过 `VAR=x` 前导赋值）。
            //   曾经这里写成 tokens[0]，于是 `BUILD=out rm -rf $BUILD` 被判为
            //   命令 "build=out" 而漏放 —— 漏放等于**校验器静默失效**。
            val verb = firstToken(seg).substringAfterLast('/').lowercase()
            val args = tokens.dropWhile { ASSIGNMENT.matches(it) }.drop(1)

            if (verb == "rm") {
                val recursive = args.any {
                    it.startsWith("-") && !it.startsWith("--") && (it.contains('r') || it.contains('R'))
                }
                val targets = args.filterNot { it.startsWith("-") }
                val deadly = targets.firstOrNull { isNeverDeletable(it) }
                if (deadly != null) {
                    return Deny("禁止删除 $deadly —— 这是系统或用户数据区，不是工作区")
                }
                if (recursive) {
                    return NeedsApproval("递归删除（rm -r ${targets.joinToString(" ")}）需要确认")
                }
            }

            if (verb == "pm") {
                val sub = args.firstOrNull()?.lowercase()
                if (sub == "uninstall" || sub == "clear") {
                    return NeedsApproval("pm $sub 会清除应用数据，需要确认")
                }
                if (sub == "install") {
                    return NeedsApproval("安装 / 覆盖安装 APK 需要确认")
                }
            }

            if (verb == "setprop" || verb == "ip" || verb == "mount") {
                return NeedsApproval("$seg 会改变系统状态，需要确认")
            }
        }

        return Allow
    }

    // ---------------------------------------------------------------- 规则

    private val SEGMENT_SPLIT = Regex("""(?:&&|\|\||[;&|\n])""")

    /** 全局禁用词。第二项是给用户看的理由。 */
    private val GLOBAL_DENY: List<Pair<Regex, String>> = listOf(
        Regex("""(^|\s)force-stop(\s|$)""") to
            "禁止 force-stop 任何应用（AGENTS.md 硬约束：设备是用户的，不是测试沙箱）",
        Regex("""(^|\s)am\s+kill(\s|$)""") to
            "禁止用 am kill 杀掉应用（同上）",
        // killall / pkill 无论如何都危险（按名字杀，范围不可控）
        Regex("""(^|\s)(killall|pkill)(\s|$)""") to
            "禁止 killall / pkill —— 按名字杀进程的范围不可控",
        Regex("""(^|\s)reboot(\s|$)""") to "禁止重启设备",
        Regex("""(^|\s)shutdown(\s|$)""") to "禁止关机",
        Regex("""(^|\s)svc\s+power(\s|$)""") to "禁止操作电源状态",
        Regex("""(^|\s)fastboot(\s|$)""") to "禁止进入 fastboot",
        Regex("""(^|\s)setenforce(\s|$)""") to "禁止改动 SELinux 强制模式",
        Regex("""(^|\s)pm\s+disable(\s|$)""") to "禁止停用应用",
        Regex("""\bof=/dev/block\b""") to "禁止直写块设备",
        Regex("""(^|\s)magisk(\s|$)""") to "禁止操作 Magisk",
    )

    private const val KILL_REASON =
        "禁止 kill 进程（AGENTS.md 硬约束；内存不足时只能停自己的 llama-server，" +
            "或请用户处理）"

    /** 需要细分处理的破坏性动词 */
    private val DESTRUCTIVE_VERBS = setOf("rm", "pm", "setprop", "ip", "mount")

    /** 永远不能整目录删的路径（精确匹配） */
    private val NEVER_DELETE_EXACT = setOf(
        "/", "/*", "~", "~/", "~/*",
        "/sdcard", "/storage", "/storage/emulated", "/storage/emulated/0",
        "/system", "/vendor", "/boot", "/proc", "/sys", "/etc", "/root",
        "/data",
    )

    /**
     * 永远不能整目录删的路径（**前缀**匹配）。
     *
     * ⚠️ `/data` **不在**此前缀列表里 —— 因为 `/data/local/tmp` 是本项目
     * 合法的暂存区（ADR-009：llama-server 就 push 在那里）。见 [isNeverDeletable]。
     */
    private val NEVER_DELETE_PREFIX = listOf(
        "/system/", "/vendor/", "/boot/", "/proc/", "/sys/", "/etc/", "/root/",
    )

    private fun isNeverDeletable(rawTarget: String): Boolean {
        val t = rawTarget.trim().trim('"', '\'')
        val norm = if (t.length > 1) t.trimEnd('/') else t
        if (norm in NEVER_DELETE_EXACT) return true
        if (NEVER_DELETE_PREFIX.any { norm.startsWith(it) }) return true
        // /data 下的系统区；但 /data/local/tmp 是允许的工作区
        if (norm == "/data" ) return true
        if (norm.startsWith("/data/") && !norm.startsWith("/data/local/tmp")) return true
        return false
    }

    private fun firstToken(segment: String): String {
        // 跳过形如 `VAR=x` 的前导赋值，取真正的命令名
        val tokens = segment.split(Regex("\\s+")).filter { it.isNotEmpty() }
        return tokens.firstOrNull { !ASSIGNMENT.matches(it) }
            ?: tokens.firstOrNull()
            ?: ""
    }

    private val ASSIGNMENT = Regex("""^[A-Za-z_][A-Za-z0-9_]*=.*$""")
}
