package dev.heracles.agent

/**
 * **"这次工具调用会不会越出工作区"** —— 2026-10-19。
 *
 * ## 为什么需要它（这是「工作区内修改」档位缺失的那一半）
 *
 * 设置里 `PermissionMode.workspaceAuto` 的文案写着：
 * 「工作区内的改动自动执行，**越界仍会询问**」。
 * 但接入档位时只实现了前一半（工作区内的写操作直接放行、危险命令由工具守卫拦），
 * **"越界"根本没有判定** —— 也就是说那句话在当时是**半句空话**。
 *
 * ## 为什么判定放在 `:agent` 而不是各工具里
 *
 * 越界是**策略**（要不要问用户），不是**能力**（能不能做）。
 * 工具层的路径守卫负责"绝对不许出去"（`PathEscapeException`）；
 * 这里负责"出去了要先问一句"。两者分开，才能做到「问一次 ≠ 禁止」。
 *
 * ## 诚实边界
 *
 * 这是**静态可判定的那一部分**：从参数里能直接看出的路径。
 * 它**看不穿** shell 命令（`run_shell_command("rm -rf /")` 里的路径要解析 shell 才能知道）——
 * 那类危险**已经由 `CommandGuard` 的 `NeedsApproval` 覆盖**，两者互补。
 * 本函数刻意**不猜**：判不出来就返回空集（交给工具自己的守卫）。
 */
object WorkspaceBoundary {

    /** 这些参数名表示"一个工作区相对路径"。 */
    private val PATH_ARGS = listOf("path", "dir", "dest", "target", "from", "to", "src")

    /**
     * 返回**疑似越界**的参数值（空集 = 没发现越界）。
     *
     * 判定规则（保守：宁可多报，不可漏报）：
     * 1. 绝对路径（`/…`、`C:\…`、`\…`）
     * 2. 非法协议（`content://`、`file://`）—— 那是**工具自己**的通道，不是模型该填的
     * 3. 规范化后以 `..` 开头（`../../etc/passwd`、`a/../../..`）
     *
     * ⚠️ 只对**会修改**的工具调用有意义；纯读工具不必走这条路。
     */
    fun outOfWorkspaceArgs(args: Map<String, String>): List<String> {
        val hits = mutableListOf<String>()
        for (name in PATH_ARGS) {
            val raw = args[name]?.trim().orEmpty()
            if (raw.isEmpty()) continue
            if (isOutOfWorkspace(raw)) hits += "$name=$raw"
        }
        return hits
    }

    /** 单个值是否越界（见 [outOfWorkspaceArgs] 的三条规则）。 */
    fun isOutOfWorkspace(raw: String): Boolean {
        val v = raw.trim().replace('\\', '/')
        if (v.isEmpty()) return false
        // 1) 绝对路径 / 盘符 / 协议
        if (v.startsWith("/")) return true
        if (v.length >= 2 && v[1] == ':' && v[0].isLetter()) return true
        if (Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://").containsMatchIn(v)) return true
        // 2) 规范化后仍以 .. 开头
        val parts = ArrayDeque<String>()
        for (seg in v.split('/')) {
            when (seg) {
                "", "." -> {}
                ".." -> if (parts.isEmpty()) return true else parts.removeLast()
                else -> parts.addLast(seg)
            }
        }
        return false
    }
}
