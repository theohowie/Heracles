package dev.heracles.toolchain

import dev.heracles.workspace.WorkspaceFs
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
// ★ 必须用 Paths.get，**不要用 Path.of**（2026-10-16 由 lint 抓到）
//
// `java.nio.file.Path.of` 是 Java 11 的便捷工厂，但**在 Android 上要求 API 34**
// （`Paths.get` 只要 API 26）。而本项目 minSdk = 31：
// 编译器一声不响，装到 Android 12/13 真机上才会 `NoSuchMethodError` 崩。
//
// 抓它的是 `:android-probe` 的 lint（`NewApi`）。这也是"把 :toolchain 的
// srcDirs 加进 probe"的价值所在 —— 不加就查不到，全绿但真机崩。

/**
 * 工具链各组件的位置 —— `26-编码层工具链与逆向引擎.md` §6.1。
 *
 * ## ★ 为什么不把这些工具打进 APK
 *
 * | 约束 | 来源 | 后果 |
 * |---|---|---|
 * | 发行版体积 < 50 MB | `NFR-10` | `aapt2`+`apksigner`+`d8`+`android.jar` 合计 **40–80 MB** |
 * | 发行版不得含本地模型/大资产 | `AGENTS.md` | 同上 |
 *
 * ⇒ 工具链**按需获取**并存进工作区 `.heracles/toolchain/`。
 * 本类只负责"**在哪儿**"，不负责下载。
 *
 * ## 绝对路径是刻意的
 *
 * 这里返回的是**设备绝对路径**（`/data/...`、`/storage/...`）。
 * 与工作区相对路径的约定不同 —— 因为工具链可以放在工作区之外
 * （Termux 的 `/data/data/com.termux/files/usr/bin`、用户自己 push 的目录）。
 * 把它强行约束在工作区内，反而会让"用户已经装好了 Termux 工具链"
 * 这个真实场景无法复用。
 */
data class ToolchainPaths(
    /** `aapt2`：资源编译与链接 */
    val aapt2: String? = null,
    /**
     * `zipalign`：签名前的对齐（**必须在 apksigner 之前**）。
     *
     * ## ★ 已降级为**可选**（2026-10-16 真机实测，见 ADR-026）
     *
     * **Android 上不存在可用的 `zipalign`**：Termux 的全部 3006 个包里没有，
     * `android-tools` 也不带它；而 Android SDK 自带的是 glibc 的 Linux 二进制，
     * 在 Android 的 bionic 上**根本起不来**。
     *
     * 而没有对齐的 APK **照样能安装**（2026-10-16 真机 `pm install -r` → `Success`），
     * 只是失去"资源/so 按 4 字节对齐、可 mmap 直读"的优化（属于发布质量，不是安装前提）。
     *
     * ⇒ 它**不再列入 [missing]**。有就用，没有就跳过 —— 但必须**明说跳过了**，
     * 不能假装对齐过（H-1 教训：假信息比失败更糟）。
     * 进程内对齐（`ZipFs` 侧实现）登记为后续工作。
     */
    val zipalign: String? = null,
    /** `apksigner`：签名与校验 */
    val apksigner: String? = null,
    /** `d8.jar`：class → dex。**必须用 `java -cp` 调用**（见 [ToolchainPaths.d8Hint]） */
    val d8Jar: String? = null,
    /** `android.jar`：编译期的平台 API 定义 */
    val androidJar: String? = null,
    /**
     * JDK 根目录（其下有 `bin/java`、`bin/javac`）。**可选**。
     *
     * ## 为什么需要它
     *
     * 真机上**没有** `PATH` 里的 `java`/`javac`（Android 不带 JDK），
     * 而整条流水线两处都要用：脚本里的 `javac`，以及 `java -cp d8.jar ... D8`。
     *
     * Termux 的 JDK 装在 `usr/lib/jvm/<版本>/`，把这个根目录定位出来，
     * 构建时注入 `JAVA_HOME` 与 `PATH` 即可（见 `AndroidBuildEngine.envPrefix`）。
     *
     * ## 为什么不列入 [missing]
     *
     * PC 上 JDK 就在 `PATH` 里（脚本自己 `command -v javac` 能找到）。
     * 把它算成硬性缺失会让**PC 侧也构建不了** —— 那是把设备侧的特例
     * 当成了全局前提。设备侧真缺 JDK 时，脚本会在 `javac` 那一步
     * 给出可操作的报错（`exit 2` + 「设备上需要一套 JDK，例如 Termux 的 openjdk-17」）。
     */
    val javaHome: String? = null,
    /** 调试签名密钥（`.jks`）。没有它签不出可安装的 APK */
    val keystore: String? = null,
    /**
     * `baksmali.jar`（dex → smali）。**可选** —— 缺失时逆向只能摊开资源，
     * 不能改代码。
     *
     * 不列入 [missing]：没有它依然能构建 APK，只是**改不了 smali**。
     * 把它算成"工具链不完整"会让本该能用的构建被拦下。
     */
    val baksmaliJar: String? = null,
    /** `smali.jar`（smali → dex）。同上。 */
    val smaliJar: String? = null,
) {
    /** 缺哪些组件（给模型/用户看的名字）。 */
    fun missing(): List<String> = buildList {
        if (aapt2 == null) add("aapt2")
        // ★ 没有 zipalign 不算缺（ADR-026 + ADR-027）：Android 上不存在这个二进制，
        //   而现在对齐根本不由外部工具做 —— 引擎用 :workspace 的 ZipAligner 在进程内对齐。
        if (apksigner == null) add("apksigner")
        if (d8Jar == null) add("d8.jar")
        if (androidJar == null) add("android.jar")
    }

    /**
     * **bionic 前缀树必须挂的 `LD_LIBRARY_PATH` 目录** —— 设备侧跑 Termux 二进制的前提。
     *
     * ## 为什么需要它（2026-10-17 **App 进程内**自检抓到）
     *
     * Termux 的 `java` / `javac` / `aapt2` 都是动态链接到 **bionic** 的，
     * 它们的 `libz.so.1` / `libjli.so` 就在前缀树的 `usr/lib` 里，**不在** Android 系统库里。
     * 没有 `LD_LIBRARY_PATH` 就直接起不来：
     *
     * ```text
     * CANNOT LINK EXECUTABLE "…/bin/java": library "libz.so.1" not found:
     *   needed by …/lib/libjli.so in namespace (default)
     * ```
     *
     * ## 为什么 CLI 那条路一直没暴露它
     *
     * `staging/run-device-engine.ps1` 在设备上跑的包装脚本**自己**导出了
     * `LD_LIBRARY_PATH=$TC/termux/usr/lib:$JH/lib:$JH/lib/server` ——
     * 引擎起进程时继承了它，于是"看起来不需要引擎注入"。
     * **App 进程内没有这层包装**（Shizuku/Stellar 起的 `sh` 是干净的），
     * 所以这条路必须由引擎自己注入（见 `AndroidBuildEngine.envPrefix`）。
     *
     * ## 只在**像 Termux 前缀树**时才给（PC 上返回空）
     *
     * 判据是路径**形状**，不是平台判断：JDK 落在 `<prefix>/usr/lib/jvm/<ver>`，
     * 或 `aapt2` 落在 `<prefix>/usr/bin/`。PC 上（JDK 在 `PATH` 里、javaHome 为 null）
     * 什么都不加 —— 也就不会把宿主的 `/usr/lib` 塞进去。
     */
    fun bionicLibDirs(): List<String> {
        val out = LinkedHashSet<String>()
        javaHome?.let { jhPath ->
            val jh = Paths.get(jhPath)
            // <prefix>/usr/lib/jvm/<ver>  ⇒  <prefix>/usr/lib
            val usrLib = jh.parent?.parent
            if (usrLib != null && usrLib.fileName?.toString() == "lib") {
                out.add(usrLib.toString())
            }
            out.add(jh.resolve("lib").toString())
            out.add(jh.resolve("lib/server").toString())
        }
        aapt2?.let { a ->
            // <prefix>/usr/bin/aapt2  ⇒  <prefix>/usr/lib
            val usr = Paths.get(a).parent?.parent
            if (usr != null && usr.fileName?.toString() == "usr") {
                out.add(usr.resolve("lib").toString())
            }
        }
        return out.toList()
    }

    /** 构建 APK 是否具备全部条件（keystore 可以在构建时自动生成，故不计入）。 */
    fun canBuildApk(): Boolean = missing().isEmpty()

    /**
     * 调用 `apksigner` 的**命令前缀**（已正确加引号，可直接拼进 shell 命令串）。
     *
     * ## 为什么需要它（2026-10-16 真机抓到）
     *
     * `apksigner` 有两种合法形态：
     *
     * | 形态 | 例子 |
     * |---|---|
     * | 可执行包装 | Termux 的 `$PREFIX/bin/apksigner`、SDK 的 `apksigner.bat` |
     * | **只有 jar** | 工具链里平铺的 `apksigner.jar`（SDK build-tools 也带它） |
     *
     * 直接 `"$APKSIGNER" sign …` 遇到 jar 会报 `can't execute: Permission denied`
     * —— jar 没有执行位也不该有。真机上就是这么炸的：定位器找到了根目录的
     * `apksigner.jar`，而包装在 `bin/apksigner`。
     *
     * ⇒ 统一成 `java -jar <jar>`。`java` 由 JDK 提供（设备上路径已注入）。
     *
     * ⚠️ 返回的是**字符串**、不是 argv：调用方要拼 shell 命令串
     * （`ShellRunner` 的接口就是命令串）。用 `java -jar <jar>` 这种
     * 不带引号包裹整体的写法，路径含空格也不会被拆开。
     */
    fun apksignerCommand(): String = when {
        apksigner == null -> ""
        apksigner.endsWith(".jar") -> "java -jar \"$apksigner\""
        else -> "\"$apksigner\""
    }

    /**
     * 给模型的可操作提示 —— **不要只说"缺工具"**。
     *
     * `26` §7.2 的教训：只说"失败"会让 4B 模型开始瞎猜（把缺 aapt2
     * 当成代码问题，然后去改 Java 代码）。必须把**缺什么、放哪里**写清楚。
     */
    fun d8Hint(): String =
        "d8 必须用 `java -Xmx512m -cp <d8.jar> com.android.tools.r8.D8` 调用（" +
            "build-tools 里的 d8 包装脚本**传不进 JVM 参数**，导致无法限制堆大小）。"
}

/**
 * 工具链定位 —— `26-编码层工具链与逆向引擎.md` §6.1。
 *
 * ## 搜索顺序（**顺序即优先级**）
 *
 * 1. 工作区 `.heracles/toolchain/`（Heracles 自己下载/用户 push 的）
 * 2. 环境变量 `HERACLES_TOOLCHAIN` 指向的目录
 * 3. `ANDROID_HOME` / `ANDROID_SDK_ROOT` 下的 `build-tools/<ver>/` 与 `platforms/android-<api>/`
 *    （⚠️ 不要在 KDoc 里写 `build-tools` 加斜杠星号 —— Kotlin 块注释**可嵌套**，
 *    那会开一个永不闭合的嵌套注释，报错信息只说"Unclosed comment"，很难定位）
 * 4. Termux 与常见第三方路径（用户可能早就装好了）
 *
 * ⚠️ **不得假设 `ANDROID_HOME` 存在**（`26` §6.1）：真机上通常根本没有这个变量。
 * 它只是**加分项**，不是前提。
 *
 * ## 为什么是纯函数
 *
 * 输入（root、env、候选目录）全部显式传入 ⇒ 可以在 PC 上用临时目录
 * 完整测出"优先级是否正确"，不必有真设备（`ToolchainLocatorTest`）。
 */
object ToolchainLocator {

    /** 常见第三方位置 —— 用户/前一次会话放工具的惯用目录。**顺序即优先级**。 */
    val COMMON_DIRS: List<String> = listOf(
        "/data/data/com.termux/files/usr/bin",
        "/data/data/com.termux/files/usr/opt",
        // Termux 的 JDK 布局：usr/lib/jvm/<版本>/bin/{java,javac}
        "/data/data/com.termux/files/usr/lib/jvm",
        // ★ 2026-10-16 真机实测的部署位置（`staging/deploy-toolchain.ps1` 推到这里）：
        //   把 Termux 的 bionic 包摊开成一份前缀树，含 aapt2 / JDK / d8.jar / android.jar。
        //   放在 `/data/local/tmp` **之前** —— 否则 `/data/local/tmp` 下的其它临时树
        //   （如真机实测用的 probe 目录）会先被搜到，拿到一套缺依赖的工具。
        "/data/local/tmp/heracles/toolchain",
        "/data/local/tmp/heracles/toolchain/termux/usr/lib/jvm",
        "/data/local/tmp",
        "/sdcard/Download",
        "/sdcard/toolchain",
    )

    /**
     * 递归深度上限。
     *
     * Android SDK 的布局需要 3 层（`build-tools/<ver>/lib/d8.jar`）；
     * **Termux 前缀树需要 5 层**（`usr/lib/jvm/<ver>/bin/javac`，2026-10-16 真机部署布局）。
     * 取 6 留一点余量。
     *
     * ⚠️ 不要为了"能多找到点东西"而调得很大：真正防呆的是 [MAX_VISITED]。
     */
    const val MAX_DEPTH = 6

    /** 单次定位最多看多少个目录 —— 防呆，避免误指向根目录时变成全盘扫描。 */
    const val MAX_VISITED = 2_000

    /**
     * 定位。
     *
     * @param workspaceRoot 工作区根（绝对路径）
     * @param env 环境变量快照
     * @param extraDirs 额外的搜索目录（测试与自定义场景）
     */
    fun locate(
        workspaceRoot: Path,
        env: Map<String, String> = emptyMap(),
        extraDirs: List<Path> = emptyList(),
    ): ToolchainPaths {
        val dirs = buildList {
            add(workspaceRoot.resolve(".heracles/toolchain"))
            env["HERACLES_TOOLCHAIN"]?.takeIf { it.isNotBlank() }?.let { add(Paths.get(it)) }
            listOf("ANDROID_HOME", "ANDROID_SDK_ROOT").forEach { key ->
                env[key]?.takeIf { it.isNotBlank() }?.let { add(Paths.get(it)) }
            }
            COMMON_DIRS.forEach { add(Paths.get(it)) }
            addAll(extraDirs)
        }.filterNotNull()

        fun find(vararg names: String): String? {
            // ★ 名字的**先后顺序 = 优先级**，而且这个优先级要跨目录生效
            //   （2026-10-16 真机抓到的 bug）。
            //
            //   旧写法是"先搜遍第一个名字能命中的任何目录"。曾经的实现把
            //   `names` 全丢给一次递归，于是**同目录内**先命中的名字赢，
            //   跨目录就不是了：设备上 `$TC/` 里躺着 `apksigner.jar`（工具链
            //   jar 平铺在根目录），`bin/apksigner`（真正的可执行包装）在子目录，
            //   结果定位到 `.jar` → 脚本 `"$APKSIGNER" sign` 报
            //   `can't execute: Permission denied`。
            //
            //   现在：**先在整个搜索范围里找 `apksigner`，找不到才退到
            //   `apksigner.bat`，最后才退到 `apksigner.jar`** —— 与调用方写下的
            //   顺序完全一致（也与 PC 侧的直觉一致：可执行文件优先于 jar）。
            val searcher = Searcher()
            for (n in names) {
                for (d in dirs) {
                    searcher.search(d, arrayOf(n), depth = 0)?.let { return it }
                }
            }
            return null
        }

        return ToolchainPaths(
            aapt2 = find("aapt2", "aapt2.exe"),
            zipalign = find("zipalign", "zipalign.exe"),
            apksigner = find("apksigner", "apksigner.bat", "apksigner.jar"),
            d8Jar = find("d8.jar", "lib/d8.jar"),
            androidJar = find("android.jar"),
            // JDK 根 = bin/javac 的上一级（Termux 布局：usr/lib/jvm/java-17-openjdk/bin/javac）
            // 找不到就是 null —— PC 上 JDK 本就在 PATH 里，不注入也照样能构建。
            javaHome = find("javac", "javac.exe")?.let { Paths.get(it).parent?.parent?.toString() },
            keystore = find("heracles.jks"),
            // ★ smali 只认 **3.x** 的 jar：2.5.x 的入口类在 `org.jf.*` 下，而引擎调用的是
            //   `com.android.tools.smali.*`（3.0 起改的包名）—— 放 2.5.x 进来只会得到
            //   `ClassNotFoundException`，所以不再把旧名字列成候选。
            //   `staging/fetch-smali.ps1` 产出的**自包含**合并 jar 就叫这两个名字
            //   （GitHub/Maven 上的 3.x 原始 jar 不含依赖，必须合并，见该脚本注释）。
            baksmaliJar = find("baksmali.jar", "baksmali-3.0.10.jar"),
            smaliJar = find("smali.jar", "smali-3.0.10.jar"),
        )
    }

    /**
     * 有界递归查找。
     *
     * ## 为什么要往下找好几层
     *
     * Android SDK 的真实布局是**深**的：
     *
     * ```
     * <sdk>/build-tools/34.0.0/aapt2
     * <sdk>/build-tools/34.0.0/lib/d8.jar
     * <sdk>/platforms/android-34/android.jar
     * ```
     *
     * 只看一层会**永远找不到**（且表现为"工具链不完整"，
     * 让人以为工具没装，实际是找法不对）。所以按深度递归，
     * 而且支持带斜杠的名字（`lib/d8.jar` 这种能直接命中）。
     *
     * **一次只找一个名字**：名字的先后顺序由 [locate] 里的调用顺序表达
     * （`find("apksigner", "apksigner.bat", "apksigner.jar")` = 优先级从高到低），
     * 逐个名字搜遍全部目录才轮到下一个 —— 见 `find` 里的真机 bug 说明。
     *
     * [MAX_DEPTH] 与 [MAX_VISITED] 是防呆：万一有人把工作区指向
     * `/` 或 `/sdcard`，也不能让扫描变成全盘遍历。计数在**同一次 locate
     * 的全部名字之间共享**，所以"多写几个候选名"不会把预算撑爆。
     *
     * 每次 [locate] 新建一个实例 —— 计数**不是**全局状态（并发调用互不干扰）。
     */
    private class Searcher {
        private var visited = 0

        fun search(dir: Path, names: Array<out String>, depth: Int): String? {
            if (depth > MAX_DEPTH || visited >= MAX_VISITED) return null
            visited++
            for (n in names) {
                val p = dir.resolve(n)
                if (Files.isRegularFile(p)) return p.toString()
            }
            if (!Files.isDirectory(dir)) return null
            val children = runCatching {
                Files.list(dir).use { s -> s.toList() }
            }.getOrNull() ?: return null
            for (child in children.sorted()) {
                if (!Files.isDirectory(child)) continue
                search(child, names, depth + 1)?.let { return it }
            }
            return null
        }
    }
}

/**
 * 构建/逆向类工具的**统一前置校验**（2026-10-18，F6a / ADR-032）。
 *
 * 非 POSIX 工作区（SAF 选来的文件夹）返回**给模型/用户看的拒绝文案**；POSIX 返回 `null`。
 *
 * ## 为什么必须在引擎入口**第一行**
 *
 * SAF 工作区的 `fs.info.rootPath` 是**占位**（进程 CWD，App 里就是 `/`）。
 * 引擎一旦先用它拼了路径（`ZipFs` / `ZipAligner` / 脚本 cwd），就已经在跟**根目录**
 * 打交道了 —— 事后才报错等于没拦（`实测-03` 坑 14：构建从 6 s 变 40 s 就是这么来的）。
 *
 * ## 文案为什么这么写
 *
 * 这段字会被**模型**读到，它要能据此给用户一个**可执行的下一步**，
 * 而不是只知道"失败了"。所以明确给出两条出路（内置应用工作区 / 有真实路径的位置）。
 */
internal fun workspacePathBlocker(fs: WorkspaceFs): String? {
    if (fs.info.hasRealPath) return null
    return "这个工作区没有真实文件路径：它是由系统文件选择器授权的文件夹，" +
        "构建/逆向类工具拿不到绝对路径，用不了（这不是失败，是这条工作区不支持构建）。" +
        "请改用「默认工作区」（侧边栏的 ⊕ → 默认工作区，它有真实路径、可直接构建），" +
        "或把项目放到应用私有目录等有真实路径的位置再构建。"
}
