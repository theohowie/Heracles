package com.heracles.sandbox.runtime

/**
 * **沙箱内联网前置（DNS）—— 全仓唯一一份**（2026-11-03）。
 *
 * ## 为什么必须只有一份
 *
 * 内置 Alpine minirootfs **不带 `/etc/resolv.conf`** ⇒ 沙箱里任何域名解析都失败 ⇒
 * `apk add` 直接报 `temporary error (try again later)`，装不上任何包（真机记录见
 * `sandbox/docs/porting-log.md` §10.3）。
 *
 * 历史缺陷（本轮修）：这段准备原先只写成 [ToolchainActivation] 的 `private const`，
 * 于是**只有 T2(JDK) 激活路径会补 DNS**，而 `SandboxEnvManager.installEnv`
 * （Node/Python/Deno/Bun/Go 的真实安装）从不调用它 ⇒ 「JDK 能装、Node 装不上」。
 * 抽成共用常量而不是各写一份，是为了防止两处 DNS 值将来又漂移。
 *
 * ## 语义（改动前请先读）
 *
 * · **只在缺失/为空时写**（`[ ! -s ... ]`），已有配置不覆盖 ⇒ **幂等**；
 * · 不 `chmod`：`printf >` 落盘默认 0644，沙箱内 apk 以 root 读，够用；
 * · 用公网 DNS（阿里 / 114DNS / 腾讯 DNSPod）—— PRoot 走真实网络栈，指望不上宿主 VPN 的 DNS；
 * · ⚠️ 已知边界：**只能走内网 DNS 的网络会失败**，本轮不做「可配置 DNS」。
 */
internal object SandboxNetwork {

    /**
     * **准备网络**：补 `/etc/resolv.conf`。输出含 `wrote`（本次写入）或 `exists`（本来就有），
     * 末尾 `---` 之后是文件实际内容，便于上层如实转述。
     */
    const val PREPARE_NETWORK: String =
        "mkdir -p /etc 2>/dev/null; " +
            "if [ ! -s /etc/resolv.conf ]; then " +
            "printf 'nameserver 223.5.5.5\\nnameserver 114.114.114.114\\n" +
            "nameserver 119.29.29.29\\n' > /etc/resolv.conf; " +
            "echo wrote; else echo exists; fi; " +
            "echo ---; cat /etc/resolv.conf"

    /** 准备网络的超时（与 T2 一致）。 */
    const val PREPARE_TIMEOUT_MS: Long = 30_000L

    /** [PREPARE_NETWORK] 的两种状态字。 */
    const val STATE_WROTE: String = "wrote"
    const val STATE_EXISTS: String = "exists"

    /**
     * 联网失败的特征串（大小写不敏感）。
     *
     * 只收**确定性**的三种：apk/dns 的 `temporary error`、glibc/musl 的
     * `Could not resolve`、内核的 `network is unreachable`。
     * 刻意不收 `failed`/`error` 之类宽串 —— 正常输出里也会出现，会误报。
     */
    private val NETWORK_FAILURE_MARKERS: List<String> = listOf(
        "temporary error",
        "could not resolve",
        "network is unreachable",
    )

    /**
     * 输出里是否存在**联网失败**特征；返回命中的特征串，没有则 null。
     *
     * 调用方必须据此**立即如实失败**，不许吞掉后继续装（否则用户看到的是
     * 「装完了但校验不过」这种误导结论）。
     */
    fun networkFailureOf(output: String): String? =
        NETWORK_FAILURE_MARKERS.firstOrNull { output.contains(it, ignoreCase = true) }

    /**
     * 从 [PREPARE_NETWORK] 的输出里取状态字（`wrote` / `exists`）；取不到返回空串。
     *
     * 只认整行等于状态字 —— 避免把 `cat /etc/resolv.conf` 里偶然出现的同名单词当成状态。
     */
    fun parsePrepState(output: String): String =
        output.lineSequence()
            .map { it.trim() }
            .firstOrNull { it == STATE_WROTE || it == STATE_EXISTS }
            .orEmpty()
}
