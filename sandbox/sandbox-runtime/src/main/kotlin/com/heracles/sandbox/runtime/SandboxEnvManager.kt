package com.heracles.sandbox.runtime

/**
 * **沙箱环境画像（V0.4 T0-3，2026-11-02）** —— 隔离等级 + 网络策略 + 镜像/代理。
 *
 * ## 为什么先只做 process(L1)
 *
 * `container` / `vm` 在 Android 上需要额外内核能力（namespace/cgroup 或虚拟化），
 * PRoot 给不了（见 ADR-041）。**只留枚举与接口、明确"未实现"**，比假装支持安全得多。
 *
 * ## L1 的强制力是**策略级**，不是硬隔离
 *
 * 能做到的是：代理环境变量、包管理器配置（npm/pip/apk 指向白名单镜像）、DNS 约束。
 * 做不到的是：阻止一个程序自己 `socket()` 连任意 IP。**文档/UI 必须如实写"策略级"**。
 */
enum class IsolationTier(val wire: String) {
    PROCESS("process"),
    CONTAINER("container"),
    VM("vm");

    companion object {
        fun parse(raw: String?): IsolationTier =
            entries.firstOrNull { it.wire == raw } ?: PROCESS
    }
}

/** 网络策略（默认白名单 = 官方源 + 常见国内镜像）。 */
data class NetworkPolicy(
    /** 只允许白名单（默认 true）。 */
    val whitelistOnly: Boolean = true,
    /** 自由出网开关（**显式打开**；打开后带风险标记）。 */
    val allowAllOutbound: Boolean = false,
    /** 追加的企业 registry/镜像（host 形如 `registry.npmjs.org`）。 */
    val extraHosts: List<String> = emptyList(),
    /** 代理（`http://host:port`；空 = 不设）。 */
    val proxy: String = "",
) {
    /** 风险等级：自由出网 = high；否则 low。 */
    val riskLevel: String get() = if (allowAllOutbound) "high" else "low"

    /** 给 UI 的如实说明（**必须**显示"策略级"）。 */
    val riskNote: String get() = if (allowAllOutbound)
        "已允许自由出网：L1 只能靠代理/包管理器配置约束，无法阻止程序直连任意地址（策略级，非硬隔离）"
    else
        "仅允许白名单源（官方源 + 国内镜像）；强制力为策略级（代理环境变量 + 包管理器配置 + DNS 约束），非硬隔离"

    /** 有效白名单（默认 + 追加）。 */
    fun effectiveHosts(): List<String> =
        (DEFAULT_HOSTS + extraHosts).map { it.trim().lowercase() }.filter { it.isNotEmpty() }.distinct()

    companion object {
        /** 默认白名单：npm / PyPI / Alpine apk 官方源 + 常见国内镜像。 */
        val DEFAULT_HOSTS = listOf(
            "registry.npmjs.org",
            "registry.npmmirror.com",
            "pypi.org",
            "files.pythonhosted.org",
            "pypi.tuna.tsinghua.edu.cn",
            "mirrors.aliyun.com",
            "dl-cdn.alpinelinux.org",
            "mirrors.tuna.tsinghua.edu.cn",
            "goproxy.cn",
            "proxy.golang.org",
            "crates.io",
            "static.crates.io",
        )
    }
}

/** 沙箱环境画像（profile）。 */
data class SandboxProfile(
    val isolationTier: IsolationTier = IsolationTier.PROCESS,
    val network: NetworkPolicy = NetworkPolicy(),
    /** 镜像覆盖：包管理器 → 镜像 URL（空 = 用默认白名单）。 */
    val mirrors: Map<String, String> = emptyMap(),
) {
    /** 该 tier 是否已实现（container/vm = false，**不假实现**）。 */
    val implemented: Boolean get() = isolationTier == IsolationTier.PROCESS

    /** 未实现时的明确说明。 */
    val unimplementedNote: String? get() = if (implemented) null else
        "隔离等级 ${isolationTier.wire} 尚未实现（Android 上 PRoot 无 namespace/cgroup/虚拟化能力，见 ADR-041）；当前只能用 process(L1)"
}

/**
 * **环境安装配方**（Node/Python/Deno/Bun/Go）。
 *
 * 每个配方 = 安装命令 + 来源 + 体积估算 + 校验命令。**估算体积是量级参考，不是承诺**。
 */
data class EnvRecipe(
    val name: String,
    val installCommands: List<String>,
    val verifyCommand: String,
    val source: String,
    val approxBytes: Long,
    val projectManifests: List<String> = emptyList(),
)

object SandboxEnvManager {
    /** 安装命令超时（10 分钟：apk 拉包 + 解压，慢网也够）。 */
    private const val INSTALL_TIMEOUT_MS: Long = 10L * 60L * 1000L

    /** 校验命令超时（`node --version` 这类，正常毫秒级）。 */
    private const val VERIFY_TIMEOUT_MS: Long = 60_000L

    /** 支持的配方（只增）。 */
    val RECIPES: List<EnvRecipe> = listOf(
        EnvRecipe(
            name = "node",
            installCommands = listOf("apk add nodejs npm"),
            verifyCommand = "node --version",
            source = "alpine apk（dl-cdn.alpinelinux.org）",
            approxBytes = 60L * 1024 * 1024,
            projectManifests = listOf("package.json"),
        ),
        EnvRecipe(
            name = "python3",
            installCommands = listOf("apk add python3 py3-pip"),
            verifyCommand = "python3 --version",
            source = "alpine apk（dl-cdn.alpinelinux.org）",
            approxBytes = 90L * 1024 * 1024,
            projectManifests = listOf("pyproject.toml", "setup.py", "requirements.txt"),
        ),
        EnvRecipe(
            name = "deno",
            installCommands = listOf("apk add deno"),
            verifyCommand = "deno --version",
            source = "alpine apk（社区仓库）",
            approxBytes = 45L * 1024 * 1024,
            projectManifests = listOf("deno.json"),
        ),
        EnvRecipe(
            name = "bun",
            installCommands = listOf("npm install -g bun"),
            verifyCommand = "bun --version",
            source = "npm registry（registry.npmjs.org）",
            approxBytes = 35L * 1024 * 1024,
            projectManifests = listOf("bun.lockb", "package.json"),
        ),
        EnvRecipe(
            name = "go",
            installCommands = listOf("apk add go"),
            verifyCommand = "go version",
            source = "alpine apk（dl-cdn.alpinelinux.org）",
            approxBytes = 120L * 1024 * 1024,
            projectManifests = listOf("go.mod"),
        ),
    )

    /** 按名字取配方（不认识 ⇒ null，**不猜**）。 */
    fun recipe(name: String): EnvRecipe? =
        RECIPES.firstOrNull { it.name.equals(name.trim(), ignoreCase = true) }

    /**
     * **项目识别**：根据清单文件名推荐环境（空 = 认不出，**不猜**）。
     *
     * 判断顺序：
     * 1. Flutter（`pubspec.yaml`）先于 Android（gradle）—— Flutter 项目里也有 gradle；
     * 2. **专用清单优先**：`bun.lockb` ⇒ bun、`deno.json` ⇒ deno、`go.mod` ⇒ go、
     *    `pyproject.toml`/`setup.py`/`requirements.txt` ⇒ python3；
     * 3. 最后才用**通用清单** `package.json` ⇒ node（bun 也读 package.json，但只有
     *    出现 `bun.lockb` 时才认 bun —— 否则一个普通 Node 项目会被同时推荐 bun）。
     */
    fun detectProject(fileNames: List<String>): List<String> {
        val names = fileNames.mapNotNull { raw ->
            raw.trim().takeIf { it.isNotEmpty() }?.split('/', '\\')?.last()
        }.toSet()
        if ("pubspec.yaml" in names) return listOf("flutter")
        if ("build.gradle" in names || "build.gradle.kts" in names) return listOf("android")

        val specific = RECIPES.filter { r ->
            r.projectManifests.any { it in names && it != "package.json" }
        }.map { it.name }
        if (specific.isNotEmpty()) return specific
        // 只有 package.json（无 bun.lockb）⇒ node
        if ("package.json" in names) return listOf("node")
        return emptyList()
    }

    /** 安装前的体积/来源确认文案（UI 展示后用户确认再装）。 */
    fun installPreview(name: String): Map<String, Any?>? {
        val r = recipe(name) ?: return null
        return mapOf(
            "name" to r.name,
            "source" to r.source,
            "approxBytes" to r.approxBytes,
            "installCommands" to r.installCommands,
            "verifyCommand" to r.verifyCommand,
        )
    }

    /**
     * **真实安装一个环境**（V0.4 T0-3 执行层，2026-11-02）。
     *
     * 在沙箱里按配方跑安装命令，再跑 `--version` 校验：
     * · **安装前先准备网络（DNS）**：内置 rootfs 不带 `/etc/resolv.conf`，缺它 `apk add`
     *   必报 `temporary error (try again later)`；准备状态随结果以 `networkPrep`
     *   （`wrote` = 本次写入 / `exists` = 本来就有）返回；
     * · 联网失败（`temporary error` / `Could not resolve` / `network is unreachable`）
     *   ⇒ **立即如实失败**并给人话，**不许吞掉后继续装**；
     * · 安装命令失败 ⇒ **如实失败**（带输出尾部），不假装装好；
     * · 校验命令跑不起来 / 没输出 ⇒ 失败（"装了但校验不过"也是问题）；
     * · 成功 ⇒ 返回 `verifiedVersion`（真实 `--version` 输出）。
     *
     * ⚠️ 调用方必须先展示 [installPreview]（体积/来源）让用户确认，再调本方法。
     *
     * @param exec 沙箱命令执行器（`SandboxServiceCore.executeAndWait` 的薄封装，返回 stdout）。
     * @param onProgress 进度回调（人话阶段，如"正在安装 node…"）。
     */
    suspend fun installEnv(
        name: String,
        exec: suspend (command: String, timeoutMillis: Long) -> String,
        onProgress: (String) -> Unit = {},
    ): Map<String, Any?> {
        val r = recipe(name)
            ?: return mapOf(
                "ok" to false,
                "name" to name,
                "error" to "未知环境（不猜）；支持：${RECIPES.joinToString("/") { it.name }}",
            )
        onProgress("开始安装 ${r.name}（来源：${r.source}）")

        // ---- 步骤 0：准备网络（DNS）—— ★ 2026-11-03 修复的核心 ----
        //   原先这一步只写在 ToolchainActivation（T2/JDK 路径），installEnv 从不调用；
        //   而内置 Alpine minirootfs 不带 /etc/resolv.conf ⇒ 沙箱里 `apk add` 必然
        //   报 "temporary error (try again later)" ⇒ Node/Python 在任何网络下都装不上。
        //   与 T2 共用 SandboxNetwork.PREPARE_NETWORK（幂等：只在缺失/为空时写）。
        onProgress("准备网络（DNS）")
        val prepOut = try {
            exec(SandboxNetwork.PREPARE_NETWORK, SandboxNetwork.PREPARE_TIMEOUT_MS)
        } catch (e: Exception) {
            return mapOf(
                "ok" to false,
                "name" to r.name,
                "networkPrep" to "",
                "error" to "沙箱内 DNS 准备失败（命令跑不起来）：${e.message ?: e.javaClass.simpleName}",
                "approxBytes" to r.approxBytes,
            )
        }
        val networkPrep = SandboxNetwork.parsePrepState(prepOut)
        // 连准备 DNS 就报联网错 ⇒ 立即如实失败，不吞掉后继续装。
        SandboxNetwork.networkFailureOf(prepOut)?.let { hit ->
            return networkFailure(r, networkPrep, hit, prepOut)
        }
        // 命令必须明确报告 wrote/exists；否则不能假定 DNS 已就绪。
        if (networkPrep.isEmpty()) {
            return networkFailure(
                r,
                networkPrep,
                "DNS preparation did not report wrote/exists",
                prepOut,
            )
        }

        for (cmd in r.installCommands) {
            onProgress("执行：$cmd")
            val out = try {
                exec(cmd, INSTALL_TIMEOUT_MS)
            } catch (e: Exception) {
                return mapOf(
                    "ok" to false,
                    "name" to r.name,
                    "networkPrep" to networkPrep,
                    "error" to "安装命令失败：${e.message ?: e.javaClass.simpleName}",
                    "approxBytes" to r.approxBytes,
                )
            }
            // ★ 联网失败优先判：这不是"包装不上"，而是"沙箱没网"，必须给人话 + 网络前置输出。
            //   吞掉它继续走，用户只会看到"安装后校验没有输出"这种误导结论。
            SandboxNetwork.networkFailureOf(out)?.let { hit ->
                return networkFailure(r, networkPrep, hit, out)
            }
            if (out.contains("ERROR:") || out.contains("failed", ignoreCase = true)) {
                return mapOf(
                    "ok" to false,
                    "name" to r.name,
                    "networkPrep" to networkPrep,
                    "error" to "安装命令报错：${out.takeLast(400)}",
                    "approxBytes" to r.approxBytes,
                )
            }
        }
        onProgress("校验：${r.verifyCommand}")
        val verifyOut = try {
            exec(r.verifyCommand, VERIFY_TIMEOUT_MS)
        } catch (e: Exception) {
            return mapOf(
                "ok" to false,
                "name" to r.name,
                "error" to "安装后校验失败（命令跑不起来）：${e.message ?: e.javaClass.simpleName}",
            )
        }
        val version = verifyOut.lines().firstOrNull { it.isNotBlank() }?.trim().orEmpty()
        if (version.isEmpty()) {
            return mapOf(
                "ok" to false,
                "name" to r.name,
                "error" to "安装后校验没有输出（可能没装成功）",
            )
        }
        onProgress("完成：$version")
        return mapOf(
            "ok" to true,
            "name" to r.name,
            // 网络前置状态（`wrote` = 本次补了 DNS，`exists` = 本来就有）—— UI 能如实说清
            "networkPrep" to networkPrep,
            "message" to "已安装 ${r.name}",
            "verifiedVersion" to version,
            "approxBytes" to r.approxBytes,
        )
    }

    /**
     * 「沙箱无法联网」的统一返回体（**明确失败，绝不假装装好**）。
     *
     * 为什么单独抽出来：这条错误必须同时带四样东西，否则用户和维护者都没法定位 ——
     *   ① 人话结论（DNS 未配置或宿主无网络）；
     *   ② 命中的特征串（`temporary error` / `Could not resolve` / `network is unreachable`）；
     *   ③ 网络前置的真实状态（`wrote` / `exists` / 取不到则为空）；
     *   ④ 命令输出尾（apk 原文）。
     *
     * ⚠️ 已知边界（本轮不做可配置 DNS）：只能走内网 DNS 的网络会失败 —— 文案里必须提示，
     *    不能让人以为"有 DNS 准备就一定连得上网"。
     */
    private fun networkFailure(
        r: EnvRecipe,
        networkPrep: String,
        hit: String,
        output: String,
    ): Map<String, Any?> = mapOf(
        "ok" to false,
        "name" to r.name,
        "networkPrep" to networkPrep,
        "networkFailure" to hit,
        "error" to (
            "沙箱无法联网（DNS 未配置或宿主无网络）：命中「$hit」。" +
                "若你在只能走内网 DNS 的网络，这里会失败。" +
                "安装未完成（不假装装好）。\n" +
                "  网络前置：${networkPrep.ifEmpty { "未取得状态字" }}\n" +
                "  输出尾：${output.takeLast(400)}"
        ),
        "approxBytes" to r.approxBytes,
    )
}