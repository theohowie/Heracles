# 移植日志（porting-log）

本文件记录 Heracles-taixu-sandbox 的移植过程、每个 Phase 的进度、以及所有
**偏离任务书原始设想**的地方。目的：让后续人工 review 能一眼看出
「哪一步做了什么、为什么这么做、哪里做了妥协」。

> 记录原则：只写**实际发生**的事。没验证过的不写成已验证；
> 上游与任务书冲突的地方必须留痕。

---

## Phase 0：准备与基线确认（2026-10-27）

### 0.1 三个上游的定位结果

任务书给出的三个 URL **全部 404**：

| 任务书地址 | 结果 | 实际仓库 |
|---|---|---|
| `github.com/tianxuan2026/taixu` | 404 | `github.com/wkbin/taixu` |
| `github.com/baicodex/baicodex` | 404 | `github.com/mubai0122/baicodex` |
| `github.com/tianxuan2026/tianxuan` | 404 | `github.com/xiaozhe7772222/tianxuan` |

按任务书 §三 的 fallback 要求，用 GitHub Search API 按项目名 + 描述定位。
`taixu`/`baicodex`/`tianxuan` 三个名字都命中了**同名但无关**的项目
（如 `TianXuan-Chain/tianxuan` 是区块链），逐个核对描述后才确认上述三个。
详见 `UPSTREAM.md` 第 0 节。

**基线 commit（已核实，来自 GitHub API `/commits/{branch}`）：**

| 上游 | commit | 日期 | 协议 |
|---|---|---|---|
| taixu（fork 基线，持续跟踪） | `dc7fcddb88e565929379597bbd811b440d00e34f` | 2026-10-26T02:48:26Z | GPL-3.0 |
| baicodex（一次性移植源） | `fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95` | 2026-10-27T00:05:53Z | GPL-3.0 |
| tianxuan（一次性移植源） | `caad40090a4f2c2edbe54e6eaae60a3dd1de7d21` | 2026-10-26T08:35:46Z | GPL-3.0 |

### 0.2 网络环境的实际约束（影响后续所有步骤）

本机到 GitHub 的链路受限，实测结果：

| 通道 | 结果 |
|---|---|
| `git clone` / `git ls-remote`（https） | `Recv failure: Connection was reset`（反复重试均失败） |
| `codeload.github.com` 整包 zip/tar | 能连上但**被限速到 ~30 KB/s**，60–300 秒超时；taixu 6 MB 的 tar.gz 拿不全 |
| `raw.githubusercontent.com` | 能连，但**同样被限速**（实测 6.9 KB / 60 秒） |
| `api.github.com` | 可用（匿名 60 次/小时限额） |
| `cdn.jsdelivr.net/gh/<repo>@<sha>/<path>` | **可用，约 1 秒/16 KB** ⇒ 采用 |
| Maven Central / Google Maven / 阿里云镜像 | 正常（1.1 MB/s） |

**结论**：改用「GitHub tree API 拿全量文件清单 + jsDelivr 逐文件抓取」。
最终抓取量：taixu 299 文件、baicodex 37 文件、tianxuan 5 文件（共 341 个）。
失败 3 个（`app/src/main/cpp/pty-native.properties` 等构建期生成物，非源码必需）。

> 这一条要留给后续维护者：**本工程无法用 `git clone` 初始化上游**，
> 若 CI 环境网络正常，可以直接 clone；否则照上面的 jsDelivr 方式。

### 0.3 根目录协议总览 md 的定位与格式

- 文件名：**`THIRD_PARTY_NOTICES.md`**（不是 `LICENSES.md` / `NOTICE.md`）
- 现有内容：`# 第三方代码声明` → 引言 → `---` → 唯一一节
  `## core/ — dart_agent_core`（MIT），格式是「`##` 分节 + `- 来源/位置/说明`
  无序列表 + 三反引号围栏内贴 license 全文」
- **Phase 0 只读，未做任何修改**；已备份到 `%TEMP%\THIRD_PARTY_NOTICES.md.bak`
  （sha256 `303836F8…AF038D`），追加在 Phase 5 执行并 `diff` 校验

### 0.4 taixu `runtime/` 与控制面的耦合深度（关键决策依据）

量化结果（对 155 个 runtime Kotlin 文件做 import 扫描）：

- **56 / 155（36%）** 的 runtime 文件 `import top.wkbin.taixu.core.*`
- 高频耦合项：

  | 被依赖类型 | 出现次数 | 性质 |
  |---|---|---|
  | `core.common.logging.AppLogger` | 18 | 日志（可替换） |
  | `core.common.result.AppResult` | 14 | 返回类型（可替换） |
  | `core.common.shell.ShellQuote` | 10 | 工具函数（可直接搬） |
  | `core.common.result.ErrorCode` | 9 | 错误码（可替换） |
  | `core.model.RuntimeState` | 9 | 状态模型（可替换） |
  | `core.common.result.AppError` | 9 | 错误模型（可替换） |
  | `core.datastore.RuntimePreferences` | 7 | **DataStore（必须切断）** |

- 另有 Room DAO（`WorkspaceRepository`/`TerminalSessionRepository`/
  `StorageMountBindingRepository`…）与 DataStore（`SshPreferences`/
  `WorkshopKeystore`…）被 runtime 直接注入。

**判定：耦合过深，不能原样移植。**

如果照搬 runtime：
1. 要么连带搬进 Room + DataStore + Koin —— 那就把**控制面的持久化层**搬进了沙箱，
   违反「沙箱只承担执行面」的架构决策；
2. 要么逐个文件重写 56 个文件的 import —— 成本远超预期，且会引入大量回归风险。

**采取的策略（任务书 §十.3 允许的做法）**：
在 `sandbox-runtime` 里保留**一层极薄的适配器接口**，
把 harness/控制面抽象为「可选的调用方」：

```
sandbox-runtime/src/main/kotlin/com/heracles/sandbox/runtime/SandboxDependencies.kt
  ├── EventSink        命令状态上报（原本走 harness 回调）
  ├── PathResolver     宿主视角 ↔ 沙箱视角换算（原本散落在 RuntimePathManager）
  ├── ChannelQuery     通道查询（原本由 harness 权限层提供）
  └── fileAccess       文件读写（零宽通道，可空）
```

三个接口都有「空安全默认实现」（`NoOpEventSink` / `NormalOnlyChannelQuery`），
**不注入任何东西时沙箱照样能装 rootfs、执行命令、读写文件**，只是不往外报事件。
这样：
- 沙箱不 import 宿主任何类型 ⇒ 可被其它项目复用；
- 不需要搬 Room/DataStore/Koin ⇒ 不把控制面拖进来；
- 56 个文件的耦合**收敛到一个文件**里，后续 rebase 只需盯这一处。

### 0.5 其它已确认的环境事实

- 本机：Windows 11，JDK 21（Zulu 21.0.12），Gradle 8.14.3（已缓存），
  Android SDK `F:\Env\Android-SDK\Sdk`（compileSdk 36 已装），
  NDK 28.2.13676358 已装，CMake 3.22.1 已装
- 真机：`e35e48c6`（Android 17 / SDK 37 / arm64-v8a），
  **已装 Shizuku**（`moe.shizuku.privileged.api`）、**未 root**（`su` 不存在）
  ⇒ 正好覆盖「NORMAL 可用 / SHIZUKU 可探测 / ROOT 必须优雅降级」三条路径
- 上游 taixu 的 AGP 是 9.4.1、Kotlin 2.4.21 —— 太新，本机 AGP 缓存是 8.13.0。
  **本工程不复用 taixu 的版本目录**，独立选定 AGP 8.13.0 + Kotlin 2.2.20
  （见 `gradle/libs.versions.toml`），避免被上游版本管理绑死。

### 0.6 Phase 0 交付物

- [x] `sandbox/UPSTREAM.md`（三个上游 URL + commit + 移植模块映射 + rebase 流程）
- [x] `sandbox/NOTICE`（逐个上游的版权声明、移植模块、commit hash）
- [x] `sandbox/LICENSE`（GPL-3.0 全文，35149 B，与 FSF 官方逐字节一致）
- [x] `sandbox/docs/porting-log.md`（本文件，Phase 0 记录）
- [x] 根目录 `THIRD_PARTY_NOTICES.md` 已定位 + 备份（**未修改**）

---

## Phase 1：搭骨架 + 剥离 taixu 控制面（进行中）

### 1.1 骨架与构建链路

- 按任务书 §五 建立 `sandbox/` 多模块工程（5 个 module）
- 独立 Gradle wrapper（8.14.3，走腾讯云镜像，因为本机访问 services.gradle.org 慢）
- **不继承 taixu 的 `build-logic/`（convention plugins）**：那是 taixu 自己的
  架构治理（architecture-policy.json / 尺寸棘轮 / 模块白名单），
  沙箱是独立工程，带进来只会让 `./gradlew build` 依赖 taixu 的风格约束
- `sandbox-api` 先定稿并**已单独编译通过**（`BUILD SUCCESSFUL`，产出 AAR）

### 1.2 包名重构（在 Phase 1 一开始就做，不等移植完）

按任务书 §八.6 的要求，全部改为 `com.heracles.sandbox.*`：

| 层 | 新包名 |
|---|---|
| AIDL 契约 | `com.heracles.sandbox.api` |
| 执行面 | `com.heracles.sandbox.runtime` |
| 通道 | `com.heracles.sandbox.channel`（含 `.normal/.shizuku/.root/.adb`） |
| 文件 | `com.heracles.sandbox.file` |
| Demo | `com.heracles.sandbox.demo` |

必须**同步**改的三处（任务书点名的坑）：
1. **JNI 符号**：taixu 是 `Java_top_wkbin_taixu_runtime_pty_NativePty_*`，
   沙箱是 `Java_com_heracles_sandbox_runtime_PtySession_*`
2. **AndroidManifest authority**：`com.heracles.sandbox.file.provider`
3. **AIDL 包路径**：`com/heracles/sandbox/api/`

### 1.3 AIDL 契约实现过程中踩到的坑（留给后续）

**坑：`parcelable X { ... }` 结构化声明与 Kotlin 手写 Parcelable 重名冲突。**

第一次把 7 个 AIDL 里的 parcelable 写成结构化声明（`parcelable FileResult { boolean success; ... }`），
`compileDebugKotlin` 报：

```
e: Models.kt:184:12 Redeclaration:
data class FileResult : Parcelable
class FileResult : Any, Parcelable
```

原因：AIDL 的**结构化** `parcelable` 声明会生成同名 Java 类，
与 `Models.kt` 里手写的 Kotlin data class 撞车。

修法：AIDL 改为**裸声明** `parcelable FileResult;`，
字段语义写进 AIDL 注释并用 Kotlin 侧手写 Parcelable 实现。
这样字段的读写顺序由 Kotlin 单点控制，也便于写单测。

> 教训：AIDL 的 parcelable 有两种写法，语义完全不同。
> 想自己控制 Parcel 序列化就用裸声明；想省事就用结构化声明但不要另写 Kotlin 类。

### 1.4 待办

- [x] sandbox-runtime（PTY JNI / ProotEngine / rootfs / ProcessRegistry / Workspace）
- [x] sandbox-channel（四通道）
- [x] sandbox-file（零宽通道 + PathSemantics）
- [x] sandbox-app（demo）
- [x] 根目录协议 md 追加（Phase 5）

---

## Phase 2：定稿 sandbox-api

- 7 个 AIDL + `Models.kt`（5 个手写 Parcelable）+ `ChannelType` / `RiskLevel` /
  `PathView` / `SandboxException`
- `:sandbox-api:assembleDebug` **BUILD SUCCESSFUL**，产出 AAR 51,572 B
- 关键设计：`ISandboxService` **只**暴露四类能力；`ChannelInfo` **不含** allow/deny

### 坑：`oneway interface` 会让 `isCancelled()` 永远返回 false

最初把 `IExecutionCallback` 声明成 `oneway`，编译能过。但 `oneway` 的语义是
**所有方法单向、有返回值的方法被忽略返回值** —— `boolean isCancelled()` 会恒返回
`false`，取消功能**静默失效**（不报错、不崩溃，就是取消不了）。

改成普通 `interface` 后正常。**代价**：回调会阻塞调用方，所以 KDoc 里明确写了
「回调实现绝不能阻塞」。

---

## Phase 3：移植 baicodex 三档权限 + 零宽文件

### 3.1 三档 → 四通道

baicodex 的 `Router.route()` 是 `when (Cfg.workMode) { ROOT/SHIZUKU/NORMAL }`，
即「用户已在设置里选了档位，路由照办」。沙箱把它显式化为 `ChannelSelector.select(preferred, facts)`：

| 上游做法 | 沙箱做法 | 为什么改 |
|---|---|---|
| 全局 `Cfg.workMode` 单例 | `preferred: Int` 参数（-1 = 自动） | 沙箱不该持有全局配置（那是宿主的） |
| 指定档位不可用时**静默降级** | **抛 `CODE_CHANNEL_UNAVAILABLE`** | 「高危操作被降权后仍显示成功」比直接失败危险得多 |
| 无自动选路 | 自动 = 按 `ChannelType` 声明顺序取第一个可用（从最小权限开始） | 确定性默认值，不猜 |

**只取决策结果**：`Router.kt` 里所有 UI 相关（`getString(R.string.dz_*)`、
`zone()` 上色文案）一律不搬。

### 3.2 零宽通道：如实标注边界

上游 `Router.kt` 27–34 行的六条候选变换（原路径 / `/.` / `//` / U+200B 系列）
原样移植（`ZeroWidthFileChannel.variants`）。但**新增了三条硬边界注释**
（`ZeroWidthFileChannel.kt:104-129`）：

1. 作用范围只限 `/storage/emulated/0/Android/{data,obb}`
2. **绕不过 SELinux**（`app_data_file` + `untrusted_app` 域，与路径形态无关）
3. **ROM 打补丁后自动降级**（靠实测而非版本猜测；命中不了返回 `UNSUPPORTED`，
   退回原生路径由真实 IO 报错 —— 不崩、不假装可用）

上游注释只说了「不同 ROM 行为不一致」；沙箱把**能力边界的负面清单**也写清了，
因为开源后一定会被当成「能读任何 App 数据」误用。

### 3.3 路径语义：比上游更严格的两处

baicodex 的 `Workspace.resolve(rawPath)` 把相对路径挂到 `/sdcard/baicodex`，
`Router.map()` 命中不了时返回原路径。沙箱改成：

| 上游 | 沙箱 | 理由 |
|---|---|---|
| 相对路径挂到产品自己的数据根 | **报错** | 沙箱不能内置任何数据根（那是宿主的决定），猜错位置比报错危险 |
| `hostToSandbox` 对 rootfs 外路径伪造一个映射 | **返回 `null`** | 让「无对应物」成为类型上的显式情况 |
| `..` 越界静默钳制到 `/` | **报错** | 静默 clamp 会把「试图逃出 rootfs」变成「变成了根目录」——那是一次真实的越权读 |

### 3.4 Shizuku：compileOnly 的实测证据

- `sandbox-channel` 里 **只有** `ShizukuAccessImpl.kt` import `rikka.shizuku.*`
- 装载走 `Class.forName("…ShizukuAccessImpl")` **字符串反射**，全程 `catch (Throwable)`
- **实证**：解包 `sandbox-channel-debug.aar` 的 `classes.jar` ⇒
  **0 个 `rikka/shizuku/*.class`**；解包最终 APK ⇒ **0 个 rikka 条目**
- 真机验证（设备已装 Shizuku App 但服务未运行）：
  ```
  [SHIZUKU] available = false  risk = MEDIUM
    缺: Shizuku App
    缺: Shizuku 服务运行中
    缺: 本应用被 Shizuku 授权
  ```
  **逐项**报告缺什么，而不是笼统「不可用」。且 NORMAL 通道同时 `available=true` ——
  证明隔离层生效，没把普通模式连坐。

---

## Phase 4：移植 tianxuan 无线 ADB

- `AdbPairingStateMachine.kt`（440 行）抽成**纯 Kotlin 零 Android 依赖**状态机：
  `DISCONNECTED → PAIRING_PORT_PROBE → AUTH_HANDSHAKE → CONNECTING → CONNECTED/FAILED`
- 时间由 `Tick(elapsedMillis)` **从外部喂入**，超时可确定性测试（不 sleep）
- 22 条单测覆盖全状态迁移
- `AdbMdnsDiscovery.kt` 做 `_adb-tls-pairing._tcp` 服务发现

### 一处刻意的上游背离

tianxuan 内嵌 `com.flyfishxu: kadb`（纯 Kotlin ADB 实现，含 RSA/SPAKE2 握手）。
沙箱**没有**引入，改成 `AdbTransport` SPI + 默认外部 adb 二进制实现。

理由：
1. 保持 AAR 依赖面最小（不把 kadb 及其传递依赖拖进每个宿主）
2. 不把自研 RSA/SPAKE2 的风险带进来 —— 那类失败模式**没有真机常态化回归极难维护**
3. 宿主若要纯 Kotlin 实现，注入 `AdbTransport` 即可，通道代码改 0 行

**没有移植无障碍通道**（任务书硬约束）：全仓 `Accessibility|accessibility`
**0 命中**（50 个源文件扫描）。

---

## Phase 5：Demo + 文档 + 协议 md + 真机验证

### 5.1 真机验证记录（**重要：这一节的坑都是编译期发现不了的**）

设备：`e35e48c6`（Android 17 / SDK 37 / arm64-v8a），已装 Shizuku，未 root。

第一次装完跑 ②：`error=13, Permission denied`。逐个排查出 **4 个真机专属问题**，
全部已修并写进 `docs/integration-guide.md` §4：

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| **1** | `Cannot run program ".../files/sandbox/bin/proot": error=13, Permission denied` | **Android 10+ W^X**：`untrusted_app` 不允许从 App data 分区 exec，与 `chmod +x` 无关（`ls -la` 显示 `-rwx------` 也没用） | 直接 exec `nativeLibraryDir` 里的，**不复制** |
| **2** | `CANNOT LINK EXECUTABLE: library "libtalloc.so.2" not found` | `nativeLibraryDir` 不在动态链接器默认搜索路径；且 APK 只能放 `libtalloc.so` 而 proot 的 `DT_NEEDED` 是 `libtalloc.so.2` | ① `hostEnvironment()` 把 `prootBinary.parentFile` 加进 `LD_LIBRARY_PATH`；② 补丁二进制里的 `DT_NEEDED` 字符串（`.2` → `\0\0`） |
| **3** | `library "libandroid-shmem.so" not found` | Termux proot 的另一个动态依赖，之前完全没意识到 | 从上游 baicodex 的 `jniLibs/` 取来一起打包 |
| **4** | PTY 下 `tty` 回答 `not a tty` | guest 里看不到 `/dev/pts` —— fork 的 shell 确实挂在 slave PTY 上（`fd0=/dev/pts/0`），但 guest 内没有设备节点，`isatty()` 判定失败 | `HOST_SYSTEM_BINDINGS` 加 `/dev`、`/dev/pts`、`/proc`、`/sys` |

第 4 个特别隐蔽：**命令本身是"成功"的**（`exit=0`），只是静默退化成非交互模式 ——
`apt` / `vim` / 带颜色的构建输出都会受影响，但日志里看不出来。修完后：
```
fd0=/dev/pts/0
IS_TTY
```

**另外修了一处警告污染**：`-0` 与 `--change-id=0:0` 同时给会让 proot
**每次执行**都往 stderr 打两行
`proot warning: option -i/-0/-S was already specified`
—— 宿主会把它们当成命令输出。只保留 `-0`。

### 5.2 真机验收结果（实跑，非推断）

```
① 装 rootfs
  [1/2] 试内置 minimal rootfs（离线 fallback）…
  （assets 未打包 → 优雅降级，不崩）
  [2/2] 改走 OCI（需要网络）…
    拉取 docker.io/library/alpine:3.20
    0% 正在解析镜像清单… → 20% → 40% → 60% → 80% 下载第 1/1 层…
    0% 正在解包第 1/1 层… → 100% 安装完成
  ✅ OCI rootfs 安装完成：registry-1.docker.io/library/alpine:3.20
     (source=2, 9035903 B, snapshots=0)

② 执行命令
  --- echo hello（管道模式）
      hello
      → exit=0 62ms
  --- aapt2 version
      (rootfs 内没有 aapt2 —— 可 installRootfs 一个带构建工具链的镜像)
      → exit=0 57ms
  --- PTY 模式
      fd0=/dev/pts/0
      IS_TTY
      → exit=0

③ 读写文件
  [HOST] 写 /data/user/0/.../cache/demo-host.txt
    success=true size=26
  [HOST] 读回
    content=hello HOST @ 1793094225078
    一致: ✅
  [SANDBOX] 同一个字符串 "/workspace/demo-sandbox.txt"
    宿主视角等价路径 = /data/user/0/.../files/sandbox/rootfs/workspace/demo-sandbox.txt
    写入 success=true
  ★ 结论：字符串一样，文件不同。

④ 四条通道
  [NORMAL]       available=true   risk=LOW
                 identity=u0_a10306 (uid=10306, pid=…)
                 pty=true crossAppData=false
  [SHIZUKU]      available=false  risk=MEDIUM
                 缺: Shizuku App / 缺: Shizuku 服务运行中 / 缺: 本应用被 Shizuku 授权
  [ROOT]         available=false  risk=HIGH
                 缺: 已 root 的设备（su 二进制）
  [WIRELESS_ADB] available=false  risk=HIGH
                 缺: 可用的 adb 客户端可执行文件
  本机实际可用通道: NORMAL
```

### 5.3 单测

| 模块 | 测试类 | 数量 |
|---|---|---|
| sandbox-runtime | `IncrementalUtf8DecoderTest` | 7 |
| | `OciImageReferenceTest` | 16 |
| | `TarStreamExtractorTest` | 14 |
| sandbox-channel | `ChannelSelectorTest` | 18 |
| | `AdbPairingStateMachineTest` | 22 |
| | `ShizukuIsolationTest` | 9 |
| sandbox-file | `PathSemanticsTest` | 24 |
| **合计（debug 变体）** | | **110 tests / 0 failures / 0 errors / 0 skipped** |

`./gradlew build` 会跑 debug + release 两个变体，实测 **220 项 / 0 失败**。

**变异验证**（证明断言不是空跑，每次都临时破坏 → 必须变红 → 立刻还原）：

| 变异 | 结果 |
|---|---|
| `ChannelSelector.AUTO_ORDER.firstOrNull` → `lastOrNull` | **5 条变红** |
| `PathSemantics.toHost` 映射改成原样返回 | **8 条变红** |
| 禁用 tar 绝对符号链接重写 | `绝对符号链接被重写成相对链接` **变红** |
| 破坏增量 UTF-8 解码（不保留残缺序列） | **5 条变红** |

### 5.4 全量构建

```
cd sandbox && ./gradlew build --no-daemon
BUILD SUCCESSFUL in 2m 34s
```

5 个 module 全部产出：4 个 AAR + 1 个 APK（9.6 MB，含 5 个 native lib）。

### 5.5 根目录协议 md 追加

- 目标文件：`THIRD_PARTY_NOTICES.md`（不是 `LICENSES.md`）
- 追加前备份：`%TEMP%\THIRD_PARTY_NOTICES.md.bak`（sha256 `303836F8…AF038D`）
- 追加内容：sandbox 的 GPL-3.0 条目（组件名 / 协议 / 全文位置 / 上游来源 / commit）
- **diff 校验结果：删除 0 行，新增 18 行** —— 原有 `dart-agent-core` MIT 内容与格式完好
- 追加后 UTF-8 编码校验通过（3077 B，BOM 无，首字节 `23 20`）

---

## 偏离与取舍总表（供 review）

| # | 偏离 | 原因 | 是否影响验收 |
|---|---|---|---|
| 1 | 上游 URL 与任务书不符（404 → 搜索定位） | 任务书给了 fallback 授权 | ❌ 已按 §三 要求记录 |
| 2 | 未复用 taixu 的 `build-logic/` | 那是 taixu 的架构治理，沙箱独立 | ❌ |
| 3 | 引入 `SandboxDependencies.kt` SPI 适配层 | 56/155 文件耦合 core，强拆成本失控 | ❌ 任务书 §十.3 明确允许 |
| 4 | `sandbox-channel` 依赖 `sandbox-runtime` | 要实现 `ChannelQuery`，无环 | ❌ |
| 5 | 无线 ADB 不引入 `kadb`，改 `AdbTransport` SPI | 依赖面最小 + 不自研 RSA/SPAKE2 | ❌ 通道能力不变 |
| 6 | 开源版 APK 不打包内置 rootfs | 体积（几十 MB） | ⚠️ 首次需联网；已在 README 显眼说明 |
| 7 | PRoot 的 `DT_NEEDED` 打了二进制补丁 | APK 只能放 `libtalloc.so`，proot 要 `libtalloc.so.2` | ❌ 已真机验证 |
| 8 | 3 个文件超 600 行（ProotEngine 954 等） | 为保住 demo 的调用签名 | ⚠️ 可后续拆 |

**没有做的**（如实列出）：zstd 层支持、OCI 并发下载、真机验证 ROOT/SHIZUKU/ADB
三条通道的**执行**（只验证了探测与降级 —— 该设备未 root 且 Shizuku 未启动，
属硬件/授权限制，不是代码问题）。


---

## Phase 6：修正「内置」定位 + 补齐 AIDL 服务端（2026-10-27 晚）

### 6.1 背景：两个方向性错误

Phase 5 结束时沙箱「能编译、demo 能跑」，但被追问「软件可以直接用吗」之后核查，
发现**不能**。两处都是我当时的判断失误：

**问题 A：AIDL 服务端根本不存在。**
`ISandboxService` 全仓 11 处提及**全是 KDoc 注释**，`ISandboxService.Stub`
的真实实现 **0 个**；`sandbox-app` 的 manifest 只有 1 个 Activity、0 个 Service。
而 `docs/api-reference.md` 却教宿主去 bind 一个不存在的 Service ——
**文档承诺了不存在的接口，比缺失更糟**。

**问题 B：内置 rootfs 被当成「兜底」，而需求是「内置、不涉及服务器/云端」。**
原设计里内置只是 assets 里可能没有的 fallback，主路径是 OCI。
需求明确后必须反转优先级：**内置是主路径，OCI 才是可选升级**。

### 6.2 修复：内置成为主路径

| 项 | 修复前 | 修复后 |
|---|---|---|
| PRoot 4 个二进制 | `.gitignore` 排除，靠脚本现场取 | **入库**（约 300 KB） |
| 内置 rootfs | 无（assets 空），靠 OCI | **入库 Alpine 3.20 minirootfs（3.8 MB）** |
| 构建期校验 | 无 —— 缺文件照样 BUILD SUCCESSFUL | **缺失/非 ELF/非 gzip → 构建直接失败** |
| rootfs 优先级 | OCI 主 / 内置兜底 | **内置主 / OCI 可选升级** |
| 离线可用性 | ❌ 不可用 | ✅ **断网实测可用** |

构建期强校验（`sandbox-runtime/build.gradle.kts` 的 `preBuild`）检查：
4 个二进制齐全 + 大小 + **AArch64 ELF**（magic + `e_machine=B7 00`）；
内置 rootfs 存在 + gzip magic + 体积阈值。

**已做变异验证**：移走 `libproot.so` → 构建 exit=1 + 明确报错「缺少 PRoot 运行时二进制」。

> 这条是为「Gradle 假成功」补的：之前干净 clone 后 `./gradlew build` 照样
> SUCCESSFUL，但 APK 里 0 个 native lib，装上一点执行就废。
> 这类问题在 CI 里会一路绿灯到用户手上。

### 6.3 修复：真机抓到的 3 个 bug

**Bug 1：`raw.use { detectAndWrap(it) }` 提前关闭 asset 流**（`BundledRootfs.kt`）

真机现象（断网点 ①）：`outcome=CORRUPT / 内置 rootfs 解包时出错：AssetInputStream is closed`
—— 内置 rootfs 明明在 APK 里（9.1 MB），却报「压缩包损坏」，把排查方向
带偏到打包脚本上。

根因：`use {}` 在 lambda 返回时关闭 `raw`，而返回的 `BufferedInputStream` /
`GZIPInputStream` **还要从 raw 读数据**。

修法：流生命周期交给下游 `stream.use {}`；不支持格式时由新增的
`openBundleStream()` 负责关闭（防 fd 泄漏）。

**配套补了 9 个单测**（`BundledRootfsStreamOwnershipTest`）。
**重要教训**：第一版测试用 `ByteArrayInputStream` 包一层，**变异验证没变红**——
因为 `ByteArrayInputStream.close()` 是**空操作**，关掉还能读。改成「关闭后再读
抛 IOException」的假流（模拟真实 `AssetInputStream`）后，注入 bug 才变红 2 条。
**假对象不能假得比真的宽松。**

**Bug 2：AGP 会把 `assets/*.tar.gz` 自动解压成 `*.tar`**

真机 APK 里 assets 是 `rootfs-bundle.tar`（9.1 MB 未压缩），而不是我放的
`rootfs-bundle.tar.gz`（3.8 MB）。这是 AGP `compressDebugAssets` 的固有行为。
`BUNDLE_ASSET_NAMES` 同时列了 `.tar.gz` 与 `.tar`，所以无需干预 ——
但必须写进文档，否则后续维护者会以为打包错了。

**Bug 3：`PtySession.close()` 的 `cancelChildren()` 取消调用方协程**

症状：PTY 步报 `exit=130 / 0ms / cancelled=true`，但命令**实际已成功**
（`fd0=/dev/pts/0`、`IS_TTY` 都打印了）。

根因：`close()` 里 `scope.coroutineContext.cancelChildren()` 作用在**传入的
scope** 上。旧 `ProotEngine.execute()` 每次 new 一次性 scope ⇒ 只打到自己，
无害；换成 `SandboxServiceCore`（长期存活的 supervisor scope）后，
把「正在跑这条命令的协程」一起取消了。

**这是「改用 core」暴露出来的潜伏 bug，不是 core 的 bug。**
修法：`PtySession.open()` 里给会话 `SupervisorJob(parent)` 子作用域。

> 顺带又踩一次 **Gradle 假成功**：改完 `PtySession.kt` 后
> `compileDebugKotlin` 报 `UP-TO-DATE`，但 `kotlin-classes/debug/` 里没有新 class。
> 必须 `--rerun-tasks --no-build-cache`，并用 `javap` 验证 `SupervisorJob`
> 真的进了字节码。

### 6.4 补齐：AIDL 服务端

新增 `sandbox-runtime/.../SandboxService.kt`（460 行，`ISandboxService.Stub` 实现）、
`sandbox-app/.../SandboxServiceHost.kt`（231 行，`:sandbox` 独立进程）、
`sandbox-app/.../AidlClientDemo.kt`（370 行，跨进程演示）。
`SandboxFacade.execute` 改为走 `SandboxServiceCore`（不再 engine 直通）。

**异常映射**（关键决策）：

| 方法 | 出口 |
|---|---|
| execute / installRootfs | `callback.onError(code, message)`，不抛 |
| readFile / writeFile | `FileResult(success=false, errorCode, errorMessage)`，不抛 |
| queryChannels | `emptyList()` + ERROR 日志 |
| snapshotRootfs | `RootfsStatus.NOT_INSTALLED` + ERROR 日志 |
| useBundledRootfs / resetRootfs | 公开 `IllegalStateException`，message 带 `code=xx` |

**踩到的坑**：`android.app.ServiceSpecificException` 是 `@hide`，
**公开 SDK 的 `android.jar` 里不存在**（实测 android-33/34/35/36 全部零命中）。
所以跨 binder 传错误码不能靠抛它 —— 契约里本来就有 `onError(code, message)`。

### 6.5 最终真机验收（**断网**，clean build 后重装）

设备 `e35e48c6`（Android 17），`svc wifi disable; svc data disable` ⇒
`wifi_on=0, mobile_data=0`，并清空 `files/sandbox/rootfs*`。

```
① 装 rootfs
   [1/2] 试内置 minimal rootfs（离线，主路径）…
   ✅ 内置 rootfs 就绪：bundled-minimal (source=1, 9040693 B)      ← 0.3 秒

② 执行命令
   hello / exit=0 519ms
   fd0=/dev/pts/0 · IS_TTY / exit=0 54ms                            ← PTY 正常

⑤ AIDL 跨进程
   代理类型=ISandboxService$Stub$Proxy
   stdout = hello / exit=0 74ms timedOut=false cancelled=false
   文件读写 一致: ✅

进程：com.heracles.sandbox.demo (22166)
      com.heracles.sandbox.demo:sandbox (22320)                      ← 独立进程
```

`source=1` 即 `RootfsStatus.SOURCE_BUNDLED`，`source=2` 才是 OCI。
**断网下拿到 `source=1`**，证明走的是纯本地内置路径。

### 6.6 单测

**119 tests / 0 failures**（debug 变体）；`./gradlew build` 跑双变体 **238 项全绿**。
新增 `BundledRootfsStreamOwnershipTest` 9 条，其中 2 条经变异验证能抓 Bug 1。

### 6.7 未决（留给后续）

1. `snapshotRootfs` 失败返回 `NOT_INSTALLED` 有语义歧义（宿主分不清
   「没装」与「装了但快照失败」）。要修得给 `RootfsStatus` 加 `errorCode`，
   属契约变更，本次未动。
2. `callback == null` 时抛 `IllegalArgumentException`（当前选择：让宿主开发期
   就撞墙，而不是让一次执行静默消失）。
3. 内置 Alpine minirootfs 只有 busybox，**没有 `gcc`/`aapt2`** ——
   构建工具链仍需 OCI 或 `apk add`。这是「3.8 MB 换零网络依赖」的代价。

---

## Phase 7：**工具必须装在 rootfs 里**（bionic vs musl 的教训）

> 本节只保留对沙箱 runtime 有用的结论。
> 「想在 APK 里带一套工具」的尝试已全部回退（见 Phase 9），
> 过程留在这里是因为坑值得记。

### 7.1 结论（最重要的一条）

**沙箱内的工具只能是 rootfs 里的 Linux-native 程序；Android 的 bionic 程序在 PRoot 里跑不了。**

真机实测对比：

| 二进制 | ELF 解释器 | 在 PRoot guest 里 |
|---|---|---|
| `busybox`（Alpine，musl） | `/lib/ld-musl-aarch64.so.1` | ✅ 能跑 |
| Termux 的 `aapt2` / `zip`（bionic） | `/system/bin/linker64` | ❌ `execve` 返回 ENOENT |

现象极具误导性：`command -v aapt2` **找得到路径**，但**执行报 `not found`（exit 127）**。
「not found」不是文件不存在，是**内核找不到 ELF 解释器** —— PRoot 的 guest 命名空间
给不了 bionic 需要的 `/linkerconfig` + `/system/lib64` 视图。

旁证：上游 taixu 的 proot 命令行**不含 `-b /system`**，它也不在 PRoot 里跑 bionic 程序。

### 7.2 那构建设施从哪来？

taixu 的做法（`assets/plugins/android-suite-offline/`）回答了这个问题：
**全部装 linux-aarch64 版进 rootfs**。它的 `DOWNLOADS.md` 列的资源：

| 组件 | 版本形态 |
|---|---|
| JDK 17 | `OpenJDK17U-jdk_aarch64_linux_hotspot`（Linux） |
| aapt2 / aidl / zipalign | `android-sdk-tools-static-aarch64`（Linux 静态） |
| android.jar / build-tools | platform-34 + `build-tools_r35_linux`（只取 JAR/资源，删非 ARM64 ELF） |
| NDK / CMake / Ninja / Flutter | 全部 linux-aarch64 |

### 7.3 附带教训：登录 shell 会重置 PATH

Alpine 的 `/etc/profile` 里有硬编码 `export PATH="/usr/local/sbin:..."`，
而 `sh -lc` 是**登录 shell**，会把调用方设的 PATH **无条件覆盖**。
所以往 guest 注入 PATH 时，必须在命令前再 `export PATH=...:$PATH;` 补一次。
（这条与工具无关，是 runtime 自身的坑，保留。）

---

## Phase 8：**回退** —— 把偏移物全部清掉（2026-10-28）

用户裁定：Heracles 是**一个 APK**，沙箱是**内联在里面的 Android Library**，
不是第二个 App，也不是宿主侧工具集。据此回退：

| 删除项 | 量 | 原因 |
|---|---|---|
| `sandbox-runtime/jniLibs` 里的 57 个工具链库 | 10.23 MB | bionic 版，只能宿主进程跑 = 绕过沙箱 |
| `HostToolchain.kt` | 265 行 | 宿主侧执行器，不是沙箱能力 |
| `SandboxFacade.hostTools` + `MainActivity` 演示段 | 约 45 行 | 同上 |
| `README` 工具链章节 | 约 45 行 | 宣传了错误形态 |
| `porting-log` Phase 7/8 原文 | 约 174 行 | 压缩成上面这版结论 |
| 测试机上的 `com.heracles.sandbox.demo` | 1 个 App | **沙箱不该是能装的东西** |
| `sandbox-app` 的 `com.android.application` | — | 改为 `com.android.library` |

`jniLibs` 从 61 个 / 10.52 MB → **4 个 / 0.29 MB**（只剩 PRoot 运行时）。

`tools/fetch-toolchain.ps1` / `stage-host-toolchain.ps1` 保留，但**标注为
「供 Heracles 控制面参考，不属于沙箱」** —— 它们记录的知识（bionic 不能进 rootfs、
AGP 只收 lib*.so、SONAME 要一起改）对将来做套件时仍有用。

---

## Phase 9：构建能力**放回 rootfs**，真机跑通（2026-10-28）

### 9.1 做了什么

按上游 taixu 的 `android-suite-offline` 路子，新增两个**不属于沙箱核心**的可选件：

| 文件 | 作用 |
|---|---|
| `ToolchainLayout.kt` | rootfs 内套件的目录约定（`/opt/ja`、`/opt/as`、`/opt/gradle`）+ `envPrelude()` |
| `BuildSuiteInstaller.kt` | 下载/离线安装 linux-aarch64 归档到 rootfs，**拒绝 bionic** |

**`jniLibs` 保持 4 个 / 0.29 MB**（只有 PRoot 运行时），**APK 不增长一个字节**。

### 9.2 关键设计：安装器主动拒绝 bionic

解压后抽查所有 ELF 的解释器，发现 `/system/bin/linker64` 就**整体回滚并报错**。
这是把 Phase 7 的教训写进代码，而不是写进注释 ——
免得将来有人「顺手」把 Termux 包塞回来。

### 9.3 真机验证（设备 e35e48c6 / Android 17 / arm64-v8a）

测试方式：`androidTest`（library 模块，桌面上不留图标），用例 `SandboxLoopTest`：

```
DIAG prootReady=true
DIAG rootfs: bundled-minimal (source=1, 9040693 B, snapshots=0)
install result: success=true msg=已安装到 .../files/sandbox/rootfs/opt/as（13 MB）
sandbox which aapt2  = [/opt/as/build-tools/aapt2]                 exit=0
sandbox aapt2 version= [Android Asset Packaging Tool (aapt) 2.19-]  exit=0
sandbox aapt2 stderr = []
echo stdout          = [hello-sandbox]                             exit=0
```

**两条用例均 PASS**：
- `minimumLoop_works` —— 装 rootfs → execute → 读/写 → 查四通道
- `buildSuiteInsideRootfs_runsInSandbox` —— 装套件 → 沙箱内 `aapt2 version`

判定「真的在沙箱里」的依据：`which aapt2` 返回的是 **guest 路径 `/opt/as/build-tools/aapt2`**，
不是宿主 `/data/app/.../lib/arm64/`。

### 9.4 两个必须记住的实现坑

1. **`useLegacyPackaging = true` 不能省**
   AGP 对 targetSdk≥23 默认 `extractNativeLibs=false`：`.so` 留在 APK 里直接 mmap，
   **不解压到 `nativeLibraryDir`**。而沙箱要 `exec` PRoot，那个目录必须真实存在文件。
   现象：`PRoot 二进制不可用（.../lib/arm64/libproot.so）`。
   改成 library 模块时我一度删掉了这个配置，真机测试立刻红。

2. **`ToolchainLayout` 的 KDoc 里不能写 `/opt/*`**
   Kotlin **块注释会嵌套**：KDoc 里出现 `/*` 会开出新注释 ⇒ 整文件解析失败
   （报 `Syntax error: Unclosed comment`）。写成 `/opt/` 就好。

### 9.5 剩下的边界（不掩饰）

| 能力 | 状态 |
|---|---|
| `aapt2` / `aidl` / `zipalign`（rootfs 内） | ✅ 真机验证 |
| `zip`（rootfs 内） | ✅ `apk add zip`（Alpine 的 zip 是 musl） |
| JDK 17 / Gradle（rootfs 内） | ⬜ 安装器已实现，**本次未真机验证**（约 320 MB 下载） |
| 完整 `gradle assembleDebug` | ⬜ 未验证（依赖上面两项） |
| NDK / Flutter | ⬜ 未验证（体积 1 GB / 848 MB） |

**JDK/Gradle 已写好安装器但没在真机跑过** —— 所以不能说「沙箱内能编 APK」，
只能说「构建工具能在沙箱内跑」（aapt2 已证）。
---

## Phase 10：沙箱内 **JDK 17 + Gradle** 跑通（2026-10-28）

### 10.1 先踩了一个 ABI 坑

按 taixu 的 `DOWNLOADS.md` 下 **Temurin JDK 17**（`aarch64_linux_hotspot`）解压进 `/opt/ja`，
真机结果：`java -version` 返回 **127**（exit code 127 = command not found）。

根因不是权限、不是路径，还是**解释器**：

| | 解释器 | 内置 Alpine rootfs |
|---|---|---|
| Temurin JDK | `/lib/ld-linux-aarch64.so.1`（**glibc**） | ❌ 不存在 |
| Alpine busybox/musl | `/lib/ld-musl-aarch64.so.1` | ✅ 存在 |

**Temurin 是 glibc 构建，Alpine 是 musl** —— 和 Phase 7 的 bionic/musl 是同一类问题：
**ABI 不匹配的东西放进去也跑不了。**

> 顺带纠正一个我之前的错判：我说过「按 taixu 的路子装 linux-aarch64 版就行」。
> `linux-aarch64` 还不够 —— 还要区分 **glibc 还是 musl**。taixu 的 rootfs 是 glibc 系，
> 所以它的 Temurin 能用；我们的内置 rootfs 是 Alpine（musl），必须用 musl JDK。

### 10.2 正确做法

内置 Alpine rootfs 用 **Alpine 自己的 musl JDK**：

```
apk add --no-cache openjdk17-jdk
```

### 10.3 还踩了一个 DNS 坑

内置 Alpine minirootfs **没有 `/etc/resolv.conf`** ⇒ DNS 不通 ⇒
`apk update` 报 `temporary error (try again later)`，装不了任何包。

补一份 DNS 后立刻恢复：

```
printf "nameserver <网关>\nnameserver 114.114.114.114\nnameserver 223.5.5.5\n" > /etc/resolv.conf
apk update → OK: 24059 distinct packages available
```

**这条是宿主初始化的一部分**：激活沙箱时若 rootfs 没有 `resolv.conf` 就补一份，
否则用户会以为「沙箱没网」。

### 10.4 还踩了一个 zip 权限坑

Gradle 的 zip 解压后 `bin/gradle` **没有执行位** ⇒ `gradle --version` 返回 **126 Permission denied**。

zip 不保留 Unix 权限位。修法：解压时对 `*/bin/*`、`.sh`、已知工具名显式 `chmod +x`。

### 10.5 真机验证（设备 e35e48c6 / Android 17 / arm64-v8a）

```
apk add openjdk17-jdk: exit=0   tail=[...(29/29) Installing openjdk17-jdk (17.0.16_p8-r0)
                                      OK: 284 MiB in 43 packages]

sandbox java -version: exit=0
  openjdk version "17.0.16" 2025-07-15
  OpenJDK Runtime Environment (build 17.0.16+8-alpine-r0)
  OpenJDK 64-Bit Server VM (build 17.0.16+8-alpine-r0, mixed mode, sharing)

sandbox which java = [/usr/bin/java]

gradle install: success=true msg=已安装到 .../rootfs/opt/gradle（131 MB）

sandbox gradle --version: exit=0
  ------------------------------------------------------------
  Gradle 8.14.2
  ------------------------------------------------------------
  Build time:    2025-06-05 13:32:01 UTC
  Kotlin:        2.0.21
  Launcher JVM:  17.0.16 (Alpine 17.0.16+8-alpine-r0)
  Daemon JVM:    /usr/lib/jvm/java-17-openjdk
```

**`Launcher JVM: 17.0.16 (Alpine …)` 这行是关键证据**：Gradle 跑在沙箱内的
Alpine musl JDK 上，不是宿主进程。

### 10.6 仍然**没有**验证的部分（不掩饰）

| 项 | 状态 |
|---|---|
| `java -version` / `gradle --version`（沙箱内） | ✅ 真机验证 |
| `aapt2 version`（沙箱内） | ✅ 真机验证 |
| **完整 `gradle assembleDebug`** | ❌ **未验证** |
| NDK / Flutter | ❌ 未验证 |

完整构建还缺：`android.jar`（platform-34）、AGP 插件及其 Maven 依赖、
`gradle-wrapper` 的 `distributionUrl` 可能指向外网。
这些不是「跑不起来」，是**还没做** —— 不能据此宣称「沙箱内能编 APK」。

### 10.7 体积账（用户设备侧）

| 装了 | rootfs 增量 |
|---|---|
| openjdk17-jdk（含 jre/jmods，43 个包） | 284 MiB |
| Gradle 8.14.2 | 131 MB |
| android-sdk-tools（aapt2/aidl/zipalign） | 13 MB |

合计约 **430 MB**。**APK 侧仍然是 0**（`jniLibs` 只有 4 个 PRoot 运行时 / 0.29 MB）。
---

## Phase 11：沙箱内**完整产出已签名 APK**（2026-10-28）

### 11.1 达成什么

在 PRoot guest 内跑完整条链，**不依赖任何宿主侧工具**：

```
aapt2 compile → aapt2 link → javac → d8 → zip → zipalign → keytool → apksigner sign → apksigner verify
```

真机实测（设备 e35e48c6 / Android 17 / arm64-v8a），每一步退出码：

```
STEP 1 aapt2 compile  : exit=0
STEP 2 aapt2 link     : exit=0
STEP 3 javac          : exit=0
STEP 4 d8             : exit=0
STEP 5 zip add dex    : exit=0   adding: classes.dex (deflated 44%)
STEP 6 zipalign       : exit=0
STEP 7a keytool       : exit=0   Generating 2,048 bit RSA key pair …
STEP 7b apksigner sign: exit=0
STEP 8 apksigner verify: exit=0
  Signer #1 certificate DN: CN=Sandbox, OU=Test, O=Heracles, C=CN
  Signer #1 certificate SHA-256 digest: de3e3ea28f2c2189…
STEP 9 aapt2 dump badging: exit=0
  package: name='com.example.hello' compileSdkVersion='34'
  minSdkVersion:'29'  targetSdkVersion:'34'
  application-label:'HelloSandbox'
```

### 11.2 产物是真的（从沙箱里拉出来验证）

```
signed.apk  8,605 B   sha256=419afbac2304ee55652326ab18640eb2918e1ce30027646bcdd40cb77aee00f4

AndroidManifest.xml   1232 B
resources.arsc         564 B
classes.dex           1388 B
META-INF/A.SF          412 B     ← v1 签名
META-INF/A.RSA        1249 B
META-INF/MANIFEST.MF   285 B
```

不是空壳：有 `resources.arsc`（aapt2 link 产物）、`classes.dex`（javac+d8 产物）、
`META-INF/A.SF`/`A.RSA`（apksigner 签名产物）。

### 11.3 踩到的坑

| 坑 | 现象 | 修法 |
|---|---|---|
| **rootfs 里的 `/workspace` 是 bind 挂载** | 往 `<rootfs>/workspace` 写文件，guest 里看不到 | 写 rootfs 内不被挂载的路径（如 `/opt/build`） |
| **`apk add` 在 PRoot 下返回 1** | `usr/bin/.apk.xxxx: No such file or directory`，但包其实装好了 | **以结果为准**（查 `command -v javac`），不信 apk 退出码 |
| **卸载测试包会连 rootfs 一起删** | 之前装的 aapt2/JDK/Gradle 全没了 | 测试里每次先确保工具存在（幂等安装） |
| **`run-as` 读不到 `/sdcard`** | SELinux 域不同 | 用 `base64` 经 stdout 传输 |
| **PowerShell `>` 写坏二进制** | 拉出来的 APK 16,812 B，打不开 | 同样改用 base64 |

### 11.4 边界（必须说清）

**已证明**：沙箱内能用**手工工具链**编出并签名一个 APK。

**未证明**：`gradle assembleDebug`（即 AGP 完整构建）。
差别在于 AGP 还需要：
- `gradle-wrapper` 分发（`distributionUrl` 可能指向外网）
- AGP 插件及其 Maven 依赖（`com.android.tools.build:gradle`、Kotlin 插件等）
- 完整的 `build.gradle`/`settings.gradle` 工程结构

所以对外表述应当是：
✅「沙箱内可用 aapt2/javac/d8/zipalign/apksigner 链路产出并签名 APK」
❌ 不能说「沙箱内已能跑 Gradle/AGP 构建真实项目」