package dev.heracles.core.contract

/**
 * 所有魔法数字与契约常量的**唯一定义处**。
 *
 * 依据：
 *  - `docs/02-契约规范.md`（缓存记账阈值、工具上限、观测上限、安全上限）
 *  - `docs/09-决策记录.md` ADR-011（线程数）
 *  - `docs/实测-01-设备与性能.md`（实测基线）
 *
 * 规则（AGENTS.md）：**禁止**在其它文件中出现字面量阈值。
 * 阈值散落各处必然漂移，而命中率阈值一旦漂移，缓存退化就没人发现。
 */
object Contract {

    /** 缓存记账 —— `02-契约规范.md` §3.2 */
    object Cache {
        /** 稳态命中率目标 */
        const val HIT_RATE_TARGET = 0.90

        /** 命中率告警线 */
        const val HIT_RATE_ALERT = 0.70

        /** 连续多少轮低于告警线才触发告警（避免单轮抖动误报） */
        const val ALERT_CONSECUTIVE_TURNS = 3

        /** 稳态每轮实际计算的 prompt token 目标上限 */
        const val PROMPT_N_TARGET = 150

        /** 超过即说明观测过大，需压缩观测表示 */
        const val PROMPT_N_ALERT = 500

        /** 工具调用输出 token 目标上限 */
        const val PREDICTED_N_TARGET = 60

        /** 超过即说明 system prompt 不够简，或约束解码没生效 */
        const val PREDICTED_N_ALERT = 120

        /** 单轮墙钟目标（P50） */
        const val TURN_LATENCY_TARGET_MS = 8_000L

        /** 单轮墙钟失败线（P95） */
        const val TURN_LATENCY_FAIL_MS = 15_000L
    }

    /** 上下文 —— `02-契约规范.md` §1、§2.3 */
    object Context {
        /** 上下文使用率超过此比例才允许触发压缩 */
        const val COMPACTION_TRIGGER_RATIO = 0.80

        /** 本地后端默认上下文长度（实测：4096 下内存已紧张） */
        const val DEFAULT_CTX = 4096

        /**
         * **云端后端默认上下文长度**（2026-10-14 新增）。
         *
         * ## 为什么需要它
         *
         * 用户实测：调基元律动的 `deepseek-v4-flash-0731`（1M 上下文），
         * UI 却显示「已用 56% · 2.3K / 4.1K」—— 因为 [DEFAULT_CTX]
         * （本地值）被当成了全局默认。
         *
         * 后果不只是显示错：`COMPACTION_TRIGGER_RATIO`（0.8）会按
         * 4K 触发 → **过早压缩会话** → 丢上下文 + 损害缓存命中（铁律 1）。
         *
         * ## 取值依据
         *
         * 128K 是主流云端模型的**保守下限**（GPT-4o 128K、
         * DeepSeek-V3 64K→128K、Claude 200K、Qwen-Max 128K…）。
         * 取保守值保证"显示的使用率"**不会低估**（低估会让用户以为还很空）。
         *
         * ⚠️ 模型真实上限各异 —— 彻底解法是按模型查询
         *（`GET /v1/models` 若返回 context_length 则用它），
         * 当前先给一个不误导的保守值。
         */
        const val DEFAULT_CLOUD_CTX = 128_000

        /**
         * **工作区快照**的上限（F8a / P2-1「跨轮记忆」，2026-10-18）。
         *
         * ## 为什么要有这组数（它不是"防御性编程"，是**契约**）
         *
         * 快照每轮 append 进会话（append-only，铁律 1）⇒ 它**永久占住上下文**。
         * 用户工作区可以很大（整个项目，甚至 `/sdcard` 下的目录树），
         * 没有上限就等于"把工作区当成提示词" ⇒ 一轮就把上下文烧光。
         *
         * ## 三条边（分别管"多少行 / 多深 / 多少字"）
         *
         * · [MAX_SNAPSHOT_ENTRIES]：列出多少个文件（行数）
         * · [MAX_SNAPSHOT_DEPTH]：目录递归深度（防深树爆炸）
         * · [MAX_SNAPSHOT_CHARS]：整块文本的**硬**字符上限（最后一道闸）
         *
         * ## 截断必须**如实计数**
         *
         * 到了上限就写"另有 N 项未列出"。**静默截断**会让模型以为"工作区就这么大"
         * —— 那比不注入更糟：它会在错误的前提上得出"文件不存在"的结论。
         * 遍历本身也被 [MAX_SNAPSHOT_WALK] 兜住；一旦兜住，只能说"**至少** N 个"，
         * **不许**编一个精确总数。
         */
        /** 快照里最多列多少个文件 */
        const val MAX_SNAPSHOT_ENTRIES = 200

        /** 目录递归深度上限（根下第一层 = 1） */
        const val MAX_SNAPSHOT_DEPTH = 4

        /** 整块快照文本的字符上限（硬闸，超出则从尾部截行并标注） */
        const val MAX_SNAPSHOT_CHARS = 4_000

        /**
         * 遍历的条目上限（**成本**闸，不是展示闸）。
         *
         * 要"如实计数"就得知道总数，而总数只能靠遍历；
         * 大工作区遍历一次可能上千次 `list` 调用（SAF 下每次都是 IPC）。
         * ⇒ 遍历到这里就停，并把"总数"降级成"至少"。
         */
        const val MAX_SNAPSHOT_WALK = 5_000

        /** 「最近改动」最多列几个路径 */
        const val MAX_SNAPSHOT_RECENT = 5
    }

    /** 观测表示 —— `02-契约规范.md` §7 */
    object Observation {
        /** 单次观测的元素数上限 */
        const val MAX_ELEMENTS = 60

        /** 元素 ID 的十六进制字符数（内容哈希前 N 位） */
        const val ELEMENT_ID_HEX_LEN = 4
    }

    /**
     * 工具 —— `02-契约规范.md` §4.1、`26-编码层工具链与逆向引擎.md` §5.2
     *
     * ## ⚠️ 2026-10-18（ADR-035）：**不再按后端分级**
     *
     * 本地后端已删除 ⇒ 这里三个上限就是**唯一**一套（原 `Contract.Zone` 的"云端档"提升为唯一真相，
     * `Zone` 对象与全部 `*For(backend)` 分级函数已删）。
     *
     * 旧值 **8 / 12 / 3** 是**为本地 4B + 4096 上下文**定的（契约 §4.1：可见工具数过 ~10 后
     * 4B 的选择准确率显著下降），随本地一起退场 —— 撤销清单见 `docs/09` ADR-035 的 12 条表。
     * ⚠️ **这不是"顺手放宽"**：撤销的是**服务于一个已经不存在的前端**的妥协。
     */
    object Tools {
        /**
         * 冻结区常驻工具上限；超出部分必须经 `search_tools` 元工具暴露。
         *
         * **12** = 原"云端档"。依据：云端模型在 12 个工具内的选择准确率无肉眼可见退化，
         * 且 schema 进前缀的成本对云端可承受。
         *
         * ⚠️ **留空位，不要顶满**：今天实际占用 **11**（10 个常驻 + `search_tools` 自己）。
         */
        const val FROZEN_LIMIT = 12

        /**
         * 每轮 `search_tools` 最多披露几个长尾工具（`26` §5.2）。
         *
         * ## 为什么必须有上限
         *
         * 披露是**两段式**的：搜索 → 命中工具的参数表写入 C 区 → 重建 grammar。
         * 一次披露太多会把 C 区撑爆（每个 schema 约 40 token，
         * 而契约 §3.2 的 `prompt_n` 稳态增量目标只有 150）。
         *
         * 取 **6**（原"云端档"；本地档 3 随本地退场）：云端一次"打包 + 签名"能一站拿全，
         * 而 6 个 schema 进历史尾部对云端上下文可忽略。
         * ⚠️ **不要**顺手把它放大到"一次披露全部" —— 披露面本身就是 `search_tools` 的检索精度。
         */
        const val DISCLOSE_LIMIT = 6

        /**
         * 长尾工具总数上限（`26` §5.2）。
         *
         * **24** = 原"云端档"（常驻放宽后同比例放宽）。
         * ⚠️ **仍是硬墙，不是无限**：长尾也吃 `search_tools` 的检索面（命中过多会把 C 区撑爆）。
         * 越档当场失败，不静默截断 —— 见 [ToolRegistry] 的 `require`。
         */
        const val LONG_TAIL_LIMIT = 24

        /**
         * **一轮最多执行多少个原生工具调用**（ADR-031 响应侧，v2 = 4，2026-10-19）。
         *
         * ## 演进
         *
         * · **v1（≤ 2026-10-19 上午）**：上限 1 —— 只执行第一个，其余配对回填"未执行"。
         *   真机现实：原生 tools 下云端模型经常一次发 2-3 个**独立**调用
         *   （两个 `read_file`、`read_file` + `grep_files`），v1 逼模型多跑一轮。
         * · **v2（2026-10-19 下午）**：上限 **4**，**全部执行（串行）**。
         *   串行不是偷懒：工具层（SAF / 单文件写 / shell）没有并发保证，并发会互相踩。
         *
         * ## 超过上限怎么办
         *
         * 仍然**配对回填"未执行"**并如实说明原因 —— 不静默丢
         * （provider 重放要求每个 `tool_call` 都有对应 `tool_result`，否则 400）。
         *
         * 取 4 的理由：覆盖绝大多数真实请求；再多说明模型在"扫全库"，
         * 那更该用 `grep_files` / `find_files` 一次拿全（10 个单文件读取的上下文成本线性涨）。
         */
        const val MAX_NATIVE_CALLS_PER_TURN = 4

        /**
         * **写操作回执里的 diff 行数上限**（2026-10-19）。
         *
         * ## 为什么写工具要回 diff（而不是"已写入 N 字节"）
         *
         * 会话是 append-only：工具结果一旦写进上下文就**永远在**。所以回执既要
         * **能核对**（模型/用户能看出改了什么），又不能太长（40 行 ≈ 几百 token）。
         *
         * 40 是折中：足够看清一处改动的上下文，又不会让一次改写吃掉半轮预算。
         * 超过上限时**如实截断并报剩余行数**（不静默截断，`FileToolsTest` 会钉住）。
         */
        const val RESULT_DIFF_MAX_LINES = 40
    }

    /**
     * `find_files` / `grep_files` 的**结果行数**额度。
     *
     * ## 为什么要从 [Shell.LOG_EXCERPT_LINES] 里分出来（2026-10-18，ADR-035 S1b）
     *
     * 它此前**直接复用** `Shell.LOG_EXCERPT_LINES`（40），注释说"两者是同一个约束：
     * 本地 4096 上下文里一条工具结果最多占多少行"。
     * 但 ADR-035 把日志摘录提到 **200** ⇒ 复用会让"搜索默认返回 40 行"**悄悄变成 200**，
     * 而成因（本地 4096 上下文）已经不存在 —— **一个数的语义变了，不该连坐另一个**。
     *
     * ⇒ 值**保持 40**（**零回退**：与改动前实际行为逐字节相同），只是把绑定解开。
     * 要改它是**下一轮的独立决定**（涉及检索精度与 token 成本，需要数据）。
     */
    object FsSearch {
        /** 不传 `maxResults` 时的默认结果行数（= 改动前的实际行为） */
        const val DEFAULT_MAX_RESULTS = 40

        /**
         * 模型能要求的硬上限。
         *
         * 200 行是**上下文刹车**：会话是 append-only 的，一条超长工具结果会永远留在
         * 上下文里，之后每轮都付 prefill。真要更多时应当收窄 pattern / dir 再来一次。
         * （原先它是 `FsSearchTools.kt` 里的私有字面量，随本对象一起搬进契约。）
         */
        const val MAX_RESULTS_CAP = 200
    }

    /**
     * `web_fetch`（联网抓取）—— 2026-10-19，对齐成熟智能体的 WebFetch 能力。
     *
     * ## 为什么有硬上限
     *
     * 一个网页可以几 MB，而工具结果会**永久留在 append-only 会话里** ⇒
     * 之后每一轮 prefill 都要付这笔 token。所以：下载字节有上限、进上下文的正文也有上限，
     * 超了**如实截断并说明**（不假装完整）。
     *
     * ## 为什么拒绝内网地址（SSRF）
     *
     * 模型被提示词注入后可能去抓 `http://127.0.0.1:...` / 路由器后台 / 局域网服务。
     * App 跑在用户手机上，那些地址**在设备内网是可达的** —— 这不是理论风险。
     * 判定在 DNS 解析之后做（`InetAddress` 的 loopback/siteLocal/linkLocal），
     * 所以 `2130706433` 这类十进制写法也挡得住。
     */
    object Web {
        /** 单次下载最多读多少字节（512 KB）：够正文，又不至于塞爆内存 */
        const val MAX_BYTES = 512 * 1024

        /** 进上下文的正文最多多少字符（2 万 ≈ 5–8k token，一次工具结果的上限体量） */
        const val MAX_TEXT_CHARS = 20_000

        /** 连接超时（毫秒）—— 手机网络慢，15s 是"能连上"与"别白等"的折中 */
        const val CONNECT_TIMEOUT_MS = 15_000

        /** 读取超时（毫秒）—— 服务端连接上但迟迟不回数据时兜底 */
        const val READ_TIMEOUT_MS = 20_000

        /** 对外的 User-Agent（不伪装浏览器；让站点知道是自动化抓取） */
        const val USER_AGENT = "Heracles/0.1 (Android agent; web_fetch)"
    }

    /**
     * **图片输入**（2026-10-19，多模态 + `view_image` 工具）。
     *
     * 两条上限的理由见 [Web]：工具结果会永久留在 append-only 会话里，
     * 而图片按"每轮重发"处理 ⇒ 张数比体积更要紧。
     */
    object Media {
        /** 单张图片上限：4 MB 原图 base64 后约 5.3 MB 文本 */
        const val MAX_IMAGE_BYTES = 4 * 1024 * 1024

        /** 一个 run 最多带几张图（用户附件 + `view_image` 累计）—— 每张每轮都计 token */
        const val MAX_IMAGES_PER_RUN = 4
    }

    /**
     * 设备端 shell 执行 —— `26-编码层工具链与逆向引擎.md` §4.5。
     *
     * ⚠️ [LOG_EXCERPT_LINES] 自 **ADR-035 S1b** 起是**唯一**一套（原 `Zone.LOCAL_*` 的 40 行
     * 与 `Zone.CLOUD_*`/`logExcerptLinesFor(backend)` 一并删除）。
     * 下面的"为什么是 200"里保留了**当年**的算式与理由 —— 那是真实算过的，
     * 但它服务的前端（本地 4B / 4096）已经不存在，所以**不要**再把它当作"为本地算的"。
     */
    object Shell {
        /** `run_shell_command` 的默认超时（秒）；参数缺失时用它 */
        const val DEFAULT_TIMEOUT_SEC = 120

        /**
         * `run_shell_command` 允许的**最大**超时（秒）。
         *
         * 模型可以传更长的时间，但这里**必须**有上限：一次请求挂 15 分钟以上
         * 会让前端看不到任何反馈（用户以为卡死），也让热熔断的轮询失去意义。
         * 900s（15 分钟）的依据：本阶段最重的单步是 `aapt2 link` + `d8`
         * 全量构建，真机实测均在 1–3 分钟内；15 分钟是 5 倍余量。
         */
        const val MAX_TIMEOUT_SEC = 900

        /**
         * ★ 回给模型的日志摘录**行数硬上限**（`26` §7.3）。
         *
         * 全量日志落盘（[MAX_CAPTURED_BYTES]），进上下文的只有错误摘录。
         * 模型需要更多细节时用 `read_file` 主动去读，比一次吞掉整份日志更省 token。
         *
         * ## 为什么是 200（2026-10-18，F5a / `docs/27` P1-5；ADR-035 S1b 起为唯一档）
         *
         * 1. **够看清一次失败**：javac / aapt2 / d8 的一次失败，首个 error + 上下文 + 连锁
         *    通常落在 40–80 行；构建脚本、`grep -R`、`ls -R` 这类输出真正有用的一段在 200 行内。
         *    只给 40 行 ⇒ 模型看不到全貌，只好再 `read_file` 摸一遍 —— 白烧一整轮（信息饥饿）。
         * 2. **不会灌满上下文**：200 行 ≈ 4–6K token（按 20–30 token/行估），
         *    对云端 128K 上下文是可忽略的一小段；而 append-only 的历史里，"多跑一轮"比这贵得多。
         * 3. **不是移除**：全量日志照旧落盘，需要更多细节时模型仍可 `read_file` 读完整文件。
         *
         * ⚠️ 这是**摘录**额度，不是"日志截断"：落盘的文件从不因此少一行。
         * ⚠️ **已被 [FsSearch] 解耦**：`find_files`/`grep_files` 的默认结果行数**不再**跟这个数走
         *    （它曾直接复用 40；若继续复用，本节改成 200 会让搜索结果默认**悄悄涨 5 倍**）。
         */
        const val LOG_EXCERPT_LINES = 200

        /** 命中行前后各取几行上下文 —— 只看 error 那一行往往缺关键信息（如 javac 的 `^` 指示行） */
        const val LOG_CONTEXT_BEFORE = 5
        const val LOG_CONTEXT_AFTER = 5

        /** 单次命令落盘的原始日志上限（超出则只留首尾，防止磁盘被 `-v` 类输出打满） */
        const val MAX_CAPTURED_BYTES = 8 * 1024 * 1024

        /**
         * `search_tools` 自身的超时（秒）。它不碰外部进程，只是纯内存检索，
         * 给这么小是为了暴露"它不该慢"这件事。
         */
        const val SEARCH_TIMEOUT_SEC = 5

        /** `apply_patch` 超时（秒）—— 纯文本运算，同样不该慢 */
        const val PATCH_TIMEOUT_SEC = 10
    }

    /**
     * JSON **加载期校验**（F9c，2026-10-18）。
     *
     * 目前只有一个常量：重复键检测的**嵌套上限**。
     *
     * - 为什么要有上限：`gson` 对 `{"id":"a","id":"b"}` 是 **last-wins**（静默覆盖、
     *   不报错），要拒绝只能自己扫键；而"扫到多深就不扫"必须**明确失败**，
     *   不许静默停止 —— 静默停止 = 放过深层重复键，正好是要拒的那一类。
     * - 为什么是 64：profile 只描述"探测 / 步骤 / 产物"三项，真实嵌套 ≤ 5，
     *   64 已远超合理值；扫描器**不递归**（显式帧栈）⇒ 这个上限是**业务诚实**，
     *   不是防栈溢出。
     */
    object Json {
        const val MAX_DEPTH = 64
    }

    /**
     * 设备端工具链 —— `26-编码层工具链与逆向引擎.md` §6。
     *
     * 这些超时是**按"手机比 PC 慢 3–5 倍"定的**，不是 PC 上的经验值。
     */
    object Toolchain {
        const val DECOMPILE_TIMEOUT_SEC = 300
        const val RECOMPILE_TIMEOUT_SEC = 300
        const val BUILD_TIMEOUT_SEC = 600
        const val SIGN_TIMEOUT_SEC = 120
        const val D8_TIMEOUT_SEC = 180
        const val ARCHIVE_TIMEOUT_SEC = 60

        /**
         * ★ 传给 `javac` / `d8` / `apktool` / `jadx` 的 JVM 堆上限。
         *
         * 依据 `实测-04-内存与热行为.md`：内存（而非温度）是首要工程约束 ——
         * 可用内存被压到 0.5 GB 时整体代价是 **10× 变慢**。
         * 构建工具若按默认堆（宿主内存的 1/4）申请，会直接把设备拖进
         * 内存回收，比限制堆慢得多。
         */
        const val JVM_HEAP = "512m"

        /** 签名密钥与临时构建目录所在（工作区内，相对于工作区根） */
        const val DIR = ".heracles/toolchain"
        const val BUILD_DIR = ".heracles/build"
        const val LOG_DIR = ".heracles/logs"
        const val KEYSTORE = ".heracles/keys/heracles.jks"

        /**
         * **工作区构建剖面**文件（F9b / P2-2，2026-10-18）。
         *
         * 存在 ⇒ 用它（覆盖内置 Android 剖面）；不存在 ⇒ 用内置（今天的行为）。
         * ⚠️ 放在 `.heracles/` 是**有意的**：那是 App 管理的元数据目录，
         * F6b 的 SAF 镜像会跳过它 —— 而 profile 在镜像**之前**就被引擎持有，所以不受影响。
         */
        const val PROFILE_FILE = ".heracles/build-profile.json"

        /** profile 支持的最高 `schemaVersion`（升级 schema 必须同步加载器与本文档）。 */
        const val PROFILE_SCHEMA_VERSION = 1

        /**
         * profile 文件内容上限（字符数）。
         *
         * 64 KB：一份"探测规则 + 四步管线 + 产物名"的正常 profile 不到 2 KB；
         * 上限的意义是**别让一个配置文件把内存/解析时间撑爆**（它来自工作区，可能是任意文件）。
         */
        const val PROFILE_MAX_CHARS = 64 * 1024

        /** profile 的步骤数上限（内置 Android 是 4 步；64 已远超任何合理管线）。 */
        const val PROFILE_MAX_STEPS = 64

        /** profile 里单个文本字段（id / displayName / title / 文件名 / 相对路径）的字符上限。 */
        const val PROFILE_MAX_TEXT = 200

        /**
         * smali 目录约定（与 apktool 同款，`ApkReverseEngine` 的反汇编/汇编两侧都按它）
         *
         * `classes.dex` → `[SMALI_DIR]/`，`classes2.dex` → `[SMALI_CLASSES_PREFIX]2/` ……
         *
         * ⚠️ 两侧**必须**用同一套映射：反汇编写进哪个目录，汇编就得从那个目录读，
         * 否则模型的改动会被丢在一边（2026-10-16 修过一次同类缺陷）。
         */
        const val SMALI_DIR = "smali"
        const val SMALI_CLASSES_PREFIX = "smali_classes"

        /** 自动生成密钥时用的默认别名与口令（仅本地调试用，不用于分发签名） */
        const val KEY_ALIAS = "heracles"
        const val KEYSTORE_PASS = "android"

        /** 生成 APK 的最低 / 目标 SDK —— 对齐 `AGENTS.md`（最低支持 Android 12） */
        const val MIN_SDK = 31
        const val TARGET_SDK = 34

        /**
         * **SAF staging 镜像**的三道上限（F6b，2026-10-18；F10 收尾迁入契约）。
         *
         * SAF 工作区没有真实路径 ⇒ 构建前要把项目镜像进 App 内部 staging。
         * 镜像的是**用户工作区**（可能任意大）⇒ 必须有上限，否则"拷一份再构建"
         * 会把手机内存 / 存储撑爆。这三个数是**产品行为**（多大的项目还允许镜像构建），
         * 不是实现细节，所以归契约；`BuildStaging` 只引用、不再自带副本。
         *
         * ## 取值依据
         *
         * · [STAGING_MAX_FILES] = 2000：手机上的源码工程通常 100–1500 个文件
         *   （不含 `.heracles` 与构建产物）；2000 已覆盖"中型 App + 资源"，
         *   再大就不是"拷进 staging 构建"该干的事（本上限的全部意义是**别把手机撑爆**）。
         * · [STAGING_MAX_BYTES] = 64 MB：与 [dev.heracles.workspace.MAX_BINARY_BYTES]
         *   （单文件上限）同量级；64 MB 总拷贝在手机上约 1–3 秒，且远小于普通 App 的内存余量。
         * · [STAGING_MAX_DEPTH] = 32：正常工程 10 层以内；32 是防"目录成环 / 病态深树"的兜底
         *   （SAF 不会有符号链接，但假实现 / 未来后端不保证）。
         */
        /** 镜像最多多少个文件 */
        const val STAGING_MAX_FILES = 2_000

        /** 镜像总字节上限 */
        const val STAGING_MAX_BYTES = 64L * 1024 * 1024

        /** 镜像递归深度上限 */
        const val STAGING_MAX_DEPTH = 32
    }

    /**
     * **文件操作（`rm` / `mv` / `cp`）的成本闸**（P1-3，2026-10-18）。
     *
     * ## 为什么这几个数字必须是契约
     *
     * 递归删除 / 复制是**不可逆**操作：一旦开始删，删到一半才发现"目录太大"
     * 就已经晚了（用户项目少了半棵树）。所以工具必须**先整树预扫描**，
     * 在**动手之前**用这里的上限拒绝 —— 这两条闸就是"预扫描阶段"的判据。
     * 放在 `Contract` 而不是工具文件里：它们是**产品行为**（多大的目录算"太大"），
     * 不是某个实现的细节。
     *
     * ## 取值依据
     *
     * · [MAX_RECURSIVE_ENTRIES] = 2000：与 [Toolchain.STAGING_MAX_FILES] 同量级。
     *   手机上正常源码项目 100–1500 个文件；再大的树不该被一次 `rm -r` 掉
     *   （SAF 下每次 `list` 还是一次 IPC，2000 项已是可接受的预扫描成本）。
     * · [MAX_RECURSIVE_DEPTH] = 32：正常工程 10 层以内；32 是防"目录成环 / 病态深树"的兜底。
     */
    object FsOps {

        /** 单次递归操作最多碰多少个条目（文件 + 目录都算）。 */
        const val MAX_RECURSIVE_ENTRIES = 2_000

        /** 递归深度上限（根下第一层 = 1）。 */
        const val MAX_RECURSIVE_DEPTH = 32

        /**
         * **写前快照（checkpoint）的单文件上限**（2026-10-19）。
         *
         * 为什么要上限：快照是**复制原内容**进 `.heracles/checkpoints/`，手机存储有限；
         * 一个 2MB 的生成物每改一次就多一份副本不可接受。
         * 超限时**不静默失败** —— 工具回执里会说明"该文件太大，未保存快照"。
         */
        const val CHECKPOINT_MAX_BYTES = 256 * 1024

        /** 快照目录（相对工作区根）。只保留**最近一次**版本，语义是"撤销刚才那一下"。 */
        const val CHECKPOINT_DIR = ".heracles/checkpoints/latest"
    }

    /**
     * 电量与热熔断 —— `26-编码层工具链与逆向引擎.md` §7.4。
     * 依据 `实测-04-内存与热行为.md` 的热行为数据。
     */
    object Thermal {
        /** 低于此电量暂停任务（不是中止 —— 充电后可续） */
        const val BATTERY_FLOOR_PERCENT = 20

        /** 电池温度上限，单位 0.1 °C（`EXTRA_TEMPERATURE` 的原生单位）⇒ 430 = 43.0 °C */
        const val BATTERY_TEMP_CEILING_TENTHS_C = 430

        /** 熔断检查间隔（毫秒）—— 构建任务期间轮询 */
        const val CHECK_INTERVAL_MS = 5_000L
    }

    /**
     * 长任务进度（前台服务 + 通知栏）—— `26-编码层工具链与逆向引擎.md` §7.1。
     *
     * 只放**跨层共享**的数字：文案长度是"通知栏能看清多少"的工程约束，
     * 而不是某一层的排版偏好 —— 引擎拼、App 显示，两边得用同一个上限。
     */
    object Progress {
        /** 一行摘要（通知栏文案）的最大字符数，超出截断加省略号 */
        const val SUMMARY_MAX_CHARS = 120
    }

    /**
     * **预算**（ADR-033 的"云端档"提升为唯一一套；ADR-035 S1b 删掉分级）。
     *
     * ## 为什么不再分级
     *
     * `docs/27-工具面诊断.md` §3 根因 C：一批约束是**为本地 4B / 4096 上下文**定的
     * （8 轮、40 行摘录、禁转义、常驻 8 个工具），但**云端路径原样继承** ⇒
     * "顶尖模型被小马扎绑住"（实测症状：`达到最大轮次（8），任务未完成`）。
     *
     * ADR-033 的解法是**按后端给两档**；ADR-035 把本地后端整个删掉之后，两档只剩一档 ⇒
     * 分级机制（`isLocalBackend` / `turnsFor` / `toolCallsFor` / `consecutiveFailuresFor`
     * 与全部 `LOCAL_*`）**没有存在理由**，一并删除。这里就是**唯一**一套预算。
     *
     * ## ⚠️ S2：它同时是 `AgentLoop` 的**默认值**（"同一个概念两个名字"已清）
     *
     * S1b 时这里与 `Contract.Safety.DEFAULT_*` 是**两处真相**（发行版走这里，CLI/单测走那边：
     * 8 / 30 / 3）。**S2 把默认值接到这里、删掉 `Contract.Safety`** ⇒
     * 全仓库只有一个"预算"来源：
     *
     * | 入口 | 轮次 | 工具次数 | 连续失败 |
     * |---|---|---|---|
     * | `AgentLoop` 默认（CLI / 单测 / 未传参的调用方） | `MAX_TURNS` | `MAX_TOOL_CALLS` | `MAX_CONSECUTIVE_FAILURES` |
     * | 发行版装配（`AgentBridge`，只覆盖轮次） | 用户设置 `>0` 时覆盖，否则 `MAX_TURNS` | 同上（不再重复传） | 同上 |
     *
     * ## 成本提醒（不许忘）
     *
     * 轮次放宽 ⇒ 最坏情况 API 花费也上升。这些值必须**可被用户调小**
     * （设置里有入口），默认值只是"别在第一步就撞墙"。
     *
     * ⚠️ **8 → 40 是工程判断，不是实测结论**（40 轮跑真机的花费/时长**未验**）。
     */
    object Budget {
        /**
         * 单任务最大轮次。
         *
         * 8 轮连"脚手架 5 个文件 + 构建 + 装"都跑不完（`实测-12` §14.2 实测撞墙）；
         * 40 轮给的是"写到一半还能返工两次"的余量。
         *
         * ⚠️ **工程判断，不是实测结论** —— 真机验收后才能当结论引用。
         */
        const val MAX_TURNS = 40

        /** 单任务工具调用上限（轮次放宽后，工具次数也要跟着放宽） */
        const val MAX_TOOL_CALLS = 120

        /**
         * 连续失败上限。
         *
         * 比本地时代的 3 宽一档（3 → 6）：云端模型偶发格式漂移/参数猜错后**自己会改**，
         * 3 次就停会把可恢复的失败当成系统性问题。⚠️ 这仍是**熔断**，不是无限重试。
         */
        const val MAX_CONSECUTIVE_FAILURES = 6
    }

    /**
     * **S2 已删除 `object Safety`** —— 它只剩两个成员，而且都是"`AgentLoop` 的默认值"：
     * `DEFAULT_MAX_TOOL_CALLS = 30` / `DEFAULT_MAX_CONSECUTIVE_FAILURES = 3`。
     *
     * 那两个数是**本地时代**的值，与 [Budget.MAX_TOOL_CALLS]（120）/
     * [Budget.MAX_CONSECUTIVE_FAILURES]（6）是同一概念的**两份真相**（S1b 起两条 KDoc 互相
     * 交叉引用，明确标注"过渡期"）。S2 把默认值接到 [Budget] 之后，`Safety` 空掉了 ⇒
     * **整个对象删除**，而不是留一个空壳命名空间（空对象只会让人以为"安全阈值还在这里"）。
     *
     * 将来真有"与预算无关的安全阈值"（例如硬上限、不可调的保护值），**再新建** `Safety`
     * 并写清它与 [Budget] 的区别：`Budget` = 用户可调、影响花费；`Safety` = 不许调、影响安全。
     *
     * 历史（**别丢**）：2026-10-18 之前 `MAX_TOOL_CALLS_PER_TASK` 是**死常量**
     * （全仓库只在定义处出现，从未被接线）—— `docs/27` §2.2 把它挖出来，后由 `AgentLoop` 执行。
     */

    /** 云端 provider 的默认值 */
    object Provider {
        /**
         * Anthropic 请求的缺省 `max_tokens`（96）。
         *
         * 历史：这个数原先是"**能力预检**"的输出上限（本地 GBNF 时代，
         * 压低以早停省 decode）。能力预检子系统已随本地后端删除（ADR-035，
         * 2026-10-19），但 [dev.heracles.provider.http.AnthropicProvider] 的
         * 构造默认值仍沿用同一个数 —— **值不变**，这里只把归属和名字说清楚，
         * 避免再指向一个已不存在的模块。
         */
        const val DEFAULT_MAX_OUTPUT_TOKENS = 96

        /**
         * **429 / 5xx 的退避重试**（2026-10-19）。
         *
         * ## 为什么要重试
         *
         * 手机网络下 429（限流）/ 5xx（网关抖动）是日常，不是异常。
         * 旧实现一次失败就结束整轮 run ⇒ 用户看到「运行失败」，还得自己再发一遍。
         *
         * ## 三条边界（写死在契约里）
         *
         * - **只重试还没开始吐内容的调用**：流式中途断开不重试（可能已计费、
         *   重放会重复执行工具）。
         * - **只重试 provider 标了 `retryable` 的**（[dev.heracles.core.provider.ProviderCallException]）：
         *   401/400 重试只会更糟。
         * - 最多 [RETRY_MAX_ATTEMPTS] 次（额外次数），退避按 `base * 2^n`。
         */
        const val RETRY_MAX_ATTEMPTS = 2

        /** 退避基数（毫秒）：600 → 1200。 */
        const val RETRY_BASE_DELAY_MS = 600L
    }

    /** 推理 —— ADR-011、`实测-01` */
    object Inference {
        /** 实测最优：4 线程（6/8 线程反而更慢） */
        const val DEFAULT_THREADS = 4

        /** 单 slot 串行（并发会打散 slot 亲和性，违反铁律 1） */
        const val DEFAULT_SLOT = 0

        /**
         * **单轮输出 token 的硬上限**（2026-10-14）。
         *
         * ## 为什么需要上限
         *
         * 思考模型的**思考也计入 `max_tokens`** —— 若按推理档位
         * 无限放大输出预算，会出现：
         * · 本地 llama.cpp（4096 上下文）输入被挤到无处安放
         * · 云端按 token 计费，简单任务也付长输出的钱
         *
         * ## 取值依据
         *
         * 16384 = 够装"长思考 + 一个 CDATA 写文件调用"，
         * 又远小于主流云端模型的上限（不会因超限被拒）。
         *
         * 本地后端由调用方显式传小值（`maxOutputTokens = 1024`），
         * 这个上限只约束"档位放大后"的结果。
         */
        const val MAX_OUTPUT_TOKENS_CAP = 16_384
    }

    /**
     * 流式 —— `docs/25-流式工作步骤.md` §5.2 / §5.4。
     *
     * 这里的数字全部是**被实测逼出来的**，不是拍脑袋：
     * 本地模型解码约 250 tok/s，逐 token 直接推主线程 = 每秒 250 条
     * `Handler` 消息，UI 必掉帧。所以必须有批量合并。
     */
    object Stream {
        /**
         * SSE 逐行读取的字节缓冲大小。
         *
         * 取 4 KiB：够装下若干个典型 chunk，又不至于让"逐 token"的
         * 实时性被缓冲吃掉（缓冲越大 → 开始吐数据的延迟越高）。
         */
        const val READ_BUFFER_BYTES = 4096

        /**
         * ★★ 事件批量合并的**时间阈值**（毫秒）—— 见 `25-流式工作步骤.md` §5.4。
         *
         * ## 为什么必须有合并（这不是优化，是正确性问题）
         *
         * `MainActivity.eventSink` **必须在主线程调用**（Flutter 平台通道限制）。
         * 本地实测 ~250 tok/s，逐 token 推 = **每秒 250 次主线程 post +
         * 250 次 MethodChannel 调用** ⇒ UI 必然掉帧。
         *
         * **"逐字显示" ≠ "每个 token 过一次通道"**：前者是观感要求，
         * 后者是实现手段，二者可以解耦。
         *
         * ## 为什么是 16 ms
         *
         * 16 ms = 一帧（60 fps）。
         * - **比一帧更细没有意义** —— 屏幕来不及重绘，多出的通道调用纯属浪费
         * - **比一帧粗会看出卡顿** —— 33 ms（30 fps）在逐字场景下肉眼可辨
         *
         * ⇒ 16 ms 是"观感无损"下**最粗**的粒度，也就是主线程压力最小的一档。
         */
        const val FLUSH_INTERVAL_MS = 16L

        /**
         * ★★ 事件批量合并的**字符阈值** —— 即便没到 [FLUSH_INTERVAL_MS]，
         * 攒够这么多字符也立刻推。
         *
         * ## 为什么"时间 + 字符"两个阈值都要
         *
         * | 只有字符阈值 | 只有时间阈值 |
         * |---|---|
         * | 模型慢吞吐 3 个字 → 用户看到"卡住" | 模型猛然吐一大段 → 一次推几千字，卡一帧 |
         *
         * 两个都设，**取先到者**：小步快跑靠时间兜底，大块不积压靠字符兜底。
         *
         * 取 48：约等于一到两句中文。既不会在正常语速下频繁触发，
         * 又能在"突然一大段"时把单次推送的负载限制在合理范围。
         */
        const val FLUSH_MIN_CHARS = 48

        /**
         * 流式下**两个 chunk 之间的最大间隔**（秒）。
         *
         * ⚠️ 这不是"整轮超时"。本地开 thinking 时，模型可能十几秒
         * 一个 token 都不吐（在思考），若把它当整轮超时就会误杀。
         */
        const val CHUNK_IDLE_TIMEOUT_SECONDS = 120L

        /**
         * ★★ **思考占总输出预算的上限比例** —— 本项目的**可用性刹车**。
         *
         * ## 为什么必须有（2026-10-12 实测发现，Captain 升级为硬要求）
         *
         * `max_tokens` 是**思考 + 正文共享的单一预算**。实测（`25` §12.1）：
         *
         * ```
         * 档位 low（开启思考），max_tokens=512
         *   → 512 个 chunk 全部是 reasoning_content
         *   → 正文 0 字符
         *   → finish_reason = length（被截断，不是生成完）
         * ```
         *
         * **后果不是"慢"，是"完全不可用"**：
         *
         * ```
         * 用户开了推理等级（正想看思考）
         *   → 思考吃光全部预算
         *   → 正文 0 字符 ⇒ 没有工具调用、没有最终回答
         *   → agent 永远不收敛，用户以为坏了
         * ```
         *
         * **⇒ 开了思考就彻底不能用。** 这比"慢 5 倍"严重得多。
         *
         * ## 取值 0.5 的理由
         *
         * | 值 | 后果 |
         * |---|---|
         * | 太高（0.8） | 正文只剩 20% 预算，复杂任务仍可能写不完 |
         * | 太低（0.2） | 思考被过早掐断，用户开了思考却几乎看不到 |
         * | **0.5** | 对半分 —— 思考看得到，正文也够用 |
         *
         * ⚠️ 这是**工程折中值，不是实测最优值**。真正的取舍应由用户感知决定，
         * 后续若拿到真实使用数据应当修正。
         */
        const val MAX_REASONING_BUDGET_RATIO = 0.5

        /**
         * 思考预算的**硬下限**（token）。
         *
         * 比例算出的小预算会让短任务几乎无法思考（e.g. `max_tokens=64` ⇒ 32）。
         * 低于此值就按此值给 —— 宁可多给一点，也不要让"开了思考却没思考"。
         */
        const val MIN_REASONING_BUDGET_TOKENS = 64
    }

    /** 测试 —— `07-开发文档.md` §6.2 */
    object Testing {
        /** 确定性测试的重复次数：同一输入构建冻结区 N 次，哈希必须全部相同 */
        const val DETERMINISM_RUNS = 100
    }
}
