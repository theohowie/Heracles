# Heracles-taixu-sandbox

> **`Heracles-taixu-sandbox` 是 [taixu](https://github.com/wkbin/taixu) 的 fork，
> 融合了 [baicodex](https://github.com/mubai0122/baicodex) 的三档执行权限门控
> 与零宽文件通道，以及 [tianxuan](https://github.com/xiaozhe7772222/tianxuan)
> 的无线 ADB 通道**，剥离掉 Agent 循环 / UI / 项目模板后，只暴露
> 「执行 / 文件 / 通道查询 / rootfs 管理」四类能力的独立端侧执行沙箱。

一个可以被**任何 Android Agent 项目**复用的执行面。GPL-3.0。

---

## ⚠️ 先读这一句

> **PRoot 不提供 namespace / cgroup / seccomp，不是敌对代码隔离。
> 它解决的是文件系统污染和崩溃恢复。**

本项目叫 "sandbox" 是**文件系统意义**的沙箱（一个独立根文件系统的执行环境），
**不是安全意义**的沙箱（隔离不受信任代码的边界）。

如果你需要跑不信任的代码、需要防止提权、需要限制资源占用 ——
**PRoot 给不了你这些**。请用 Android 的 `isolatedProcess`、pKVM/AVF 虚拟化，
或真正的容器运行时。

详见 [`docs/security-boundary.md`](docs/security-boundary.md)（**必读**）。

---

## 🔌 完全离线内置：不依赖任何服务器 / 云端

**这是本沙箱的核心设计约束。​** 装上 APK 就能用，**不需要联网、不需要账号、
不需要任何后端服务、不需要拉镜像**。

| 依赖项 | 是否内置 | 说明 |
|---|---|---|
| PRoot 运行时（proot + loader + talloc + shmem） | ✅ **打进 APK** | `sandbox-runtime/src/main/jniLibs/arm64-v8a/` |
| rootfs（Alpine 3.20 minirootfs，3.8 MB） | ✅ **打进 APK** | `sandbox-runtime/src/main/assets/rootfs-bundle.tar.gz` |
| 网络 | ❌ **不需要** | 执行、文件读写、通道查询全部本地 |
| 云端 / 服务器 | ❌ **不需要** | 没有任何远程调用 |
| 账号 / 登录 | ❌ **不需要** | 无 |

真机验证（**断网状态**实测，`wifi_on=0`、`mobile_data=0`）：

```
rootfs: bundled-minimal (source=1, 9040693 B)     ← source=1 = 内置
--- echo hello（管道模式）
    hello
    → exit=0 528ms
--- PTY 模式
    fd0=/dev/pts/0
    IS_TTY
```

> `source=1` 是 `RootfsStatus.SOURCE_BUNDLED`，`source=2` 才是 OCI。
> 断网下拿到 `source=1`，证明走的是**纯本地内置路径**。

### OCI 安装是什么定位？

`installRootfs(ociRef)` **仍然保留**，但定位变了：

- **内置是主路径**（默认、离线、开箱即用）—— 但能力有限，只有 busybox
- **OCI 是可选的升级路径**（要 `gcc`/完整工具链时，联网拉一个更大的镜像）

换句话说：**没有网络，沙箱的"执行面"依然完整可用**（能跑脚本、能读写、能快照回滚），
**但"工具"取决于 rootfs 里装了什么**。有网络时可以选择装更强的环境。
`useBundledRootfs()` 与 `installRootfs()` 必须并存，但**优先级已反转**
（早期设计把内置当兜底，现在是主路径）。

> ⚠️ 别把「离线可用」理解成「离线什么都能干」。
> 内置 rootfs 是 3.8 MB 的 Alpine，**没有编译器和 Android 构建工具**。
> 详见下面「内置 rootfs 到底有什么」。

#### 同步到 Heracles（预编译 AAR，不是 include 模块）

Heracles 用**预编译 AAR** 内联本沙箱 —— 因为两套 AGP 版本不同（沙箱 8.13 / Heracles 9.0.1），
直接 `include` 会在同一个构建里打架。

**代价：改了沙箱必须重新出 AAR 并同步**，否则 Heracles 里跑的还是旧代码（旧 bug 还在，很难查）。

```powershell
pwsh -File tools/sync-aar-to-heracles.ps1              # 构建 + 同步 + 校验
pwsh -File tools/sync-aar-to-heracles.ps1 -VerifyOnly  # 只校验（不构建不拷贝）
```

脚本会校验四件事，任一不满足就 exit 1：

1. 4 个 AAR 都存在
2. `sandbox-runtime` 含 `assets/rootfs-bundle.tar*`（内置离线 rootfs）
3. `sandbox-runtime` 含 `jni/arm64-v8a/{libproot,libproot-loader,libpty_bridge}.so`
4. 目标目录 AAR 与本地产物 **sha256 一致**（防"以为同步了其实没同步"）

## 构建期强校验（防止"编过了但一跑就废"）

`sandbox-runtime/build.gradle.kts` 的 `preBuild` 会检查：

- 4 个 PRoot 二进制是否齐全、是否 **AArch64 ELF**（magic + `e_machine=B7 00`）
- 内置 rootfs 是否存在、是否 **gzip**、是否大于阈值

**缺任何一个就直接构建失败**，不会产出一个装上去跑不了的 APK。

> 这条是补的：之前这些产物被 `.gitignore` 排除，干净 clone 后
> `./gradlew build` 照样 SUCCESSFUL，但 APK 里一个 native lib 都没有。
> 已验证：移走 `libproot.so` → 构建 exit=1 + 明确报错。

---

## 这是什么 / 不是什么

### ✅ 是什么

- 一个**独立 Gradle 多模块工程**，`./gradlew build` 就能编，不依赖任何宿主
- 一个**执行面**：在 PRoot rootfs 里真跑命令，**但只能跑 rootfs 里有的东西**
  （内置 Alpine 只有 busybox；`gcc`/`aapt2`/`apt`/`python3`/`git` **都没有**，见下方能力表）
- 一个**文件通道**：读 / 写，含跨 App data 的零宽穿透
- 一个**通道探测器**：普通 App / Shizuku / Root / 无线 ADB 四条通道的可用性与风险
- 一个**完全离线的 rootfs**：内置 Alpine，装完即用；OCI 只是可选升级
- 一个**可回滚的工作区**：快照 / 重置，`rm -rf /` 只毁沙箱不毁系统

### 📋 内置 rootfs 到底有什么（实测，不是猜）

内置的是 **Alpine 3.20 minirootfs（3.8 MB）**，在真机上逐个查过：

| 有 ✅ | 没有 ❌ |
|---|---|
| `sh` `ash` `bash` 风格脚本 | `gcc` / `cc` / `clang` |
| `ls` `cat` `cp` `mv` `rm` `grep` `sed` `awk` | `make` |
| `tar` `gzip` `unzip` `wget` | **`zip`** |
| `apk`（Alpine 包管理器） | `apt`（Alpine 不用 apt） |
| `ping` `ps` `kill` `mount` | `python3` / `git` / `java` |
| | **`aapt2` / `apksigner` / `zipalign`** |

实测命令（真机）：
```
$ run-as … sh -c 'command -v aapt2 || echo NONE'   → NONE
$ … command -v gcc    → NONE
$ … command -v apt    → NONE
```

**这意味着什么：**

| 你想做的事 | 能做吗 | 在哪跑 |
|---|---|---|
| 跑 shell 脚本、改文件、解压 | ✅ 能 | PRoot 内（rootfs 自带 busybox） |
| **`aapt2` / `aidl` / `zipalign`** | ✅ **真机验证** | **rootfs 内** `/opt/as` |
| **`java` / `javac` / `gradle`** | ✅ **真机验证** | **rootfs 内**（musl JDK + `/opt/gradle`） |
| **重新打包 APK（`zip`）** | ✅ 能 | rootfs 内（`apk add zip`，musl 版） |
| **手工链路产出并签名 APK** | ✅ **真机验证** | **rootfs 内**（aapt2→javac→d8→zip→zipalign→apksigner） |
| 完整 AGP 构建（`gradle assembleDebug`） | ⬜ **未验证** | 还缺 AGP 插件及其 Maven 依赖 |
| 反编译（`apktool`） | ⬜ 未验证 | 有 JDK，但 `apktool` 未装 |
### 🔧 构建工具装在 **rootfs 里**，不在 APK 里

沙箱**不提供**任何工具。工具来自 **rootfs**：

| 阶段 | 有什么 | 能干什么 |
|---|---|---|
| 初始（内置 Alpine） | busybox（`sh` `ls` `cp` `tar` `grep` `sed` `unzip` `wget` `apk`…） | 跑脚本、读写、解压 |
| 激活时可选装 | Linux-aarch64 构建套件（JDK17 / Gradle / aapt2 / aidl / zipalign / android.jar） | **沙箱内断网构建 APK** |

构建套件按 [taixu](https://github.com/wkbin/taixu) 的 `android-suite-offline` 路子，
全部是 **linux-aarch64** 版本，装进 rootfs 后用 `execute` 在沙箱内调用：

```
JDK 17        OpenJDK17U-jdk_aarch64_linux_hotspot_*.tar.gz
aapt2/aidl/zipalign   android-sdk-tools-static-aarch64.zip
android.jar   platform-34-*.zip（只取 JAR/资源）
Gradle        gradle-*-bin.zip
NDK/CMake/Ninja/Flutter  可选，体积大（NDK≈1GB，Flutter≈848MB）
```

> ⚠️ **为什么不能把安卓工具打成 APK 原生库？**
> 那些是 **bionic** 版（解释器 `/system/bin/linker64`），只能在宿主进程跑；
> 打进 APK 就等于**绕过沙箱**（隔离/快照/回滚全都不生效）。
> 真机实测过：塞进 jniLibs 后能跑，但那不是沙箱能力 —— 已全部移除（2026-10-28）。

### ⚠️ 内置 Alpine 是 musl，**不能用 Temurin JDK**

Temurin 是 **glibc** 构建（解释器 `/lib/ld-linux-aarch64.so.1`），
而 Alpine 只有 `/lib/ld-musl-aarch64.so.1`。真机实测：解压进 `/opt/ja` 后
`java -version` 直接返回 **127**（内核找不到 ELF 解释器）。

⇒ 内置 rootfs 用 Alpine 自己的 musl JDK：

```
apk add --no-cache openjdk17-jdk      # → /usr/lib/jvm/java-17-openjdk
```

另外内置 minirootfs **没有 `/etc/resolv.conf`**，`apk` 会报
`temporary error (try again later)` —— 宿主激活沙箱时需补一份 DNS。

### ✅ 真机验证（2026-10-28，设备 e35e48c6 / Android 17 / arm64-v8a）

```
# ① aapt2（android-sdk-tools-static-aarch64，13 MB）
install result: success=true  msg=已安装到 .../rootfs/opt/as（13 MB）
sandbox which aapt2  = [/opt/as/build-tools/aapt2]                 exit=0
sandbox aapt2 version= [Android Asset Packaging Tool (aapt) 2.19-]  exit=0

# ② musl JDK 17（apk 装进 rootfs）
apk add openjdk17-jdk → OK: 284 MiB in 43 packages
sandbox java -version → exit=0
  openjdk version "17.0.16" 2025-07-15
  OpenJDK Runtime Environment (build 17.0.16+8-alpine-r0)
sandbox which java    = [/usr/bin/java]

# ③ Gradle 8.14.2（解压到 /opt/gradle）
sandbox gradle --version → exit=0
  Gradle 8.14.2
  Kotlin:        2.0.21
  Launcher JVM:  17.0.16 (Alpine 17.0.16+8-alpine-r0)     ← 跑在沙箱内的 Alpine JDK 上
  Daemon JVM:    /usr/lib/jvm/java-17-openjdk
```

路径全是 **guest 路径**（`/opt/as`、`/usr/bin/java`、`/usr/lib/jvm`），
不是宿主 `/data/app/.../lib/arm64/` —— 这就是「在沙箱里跑」的证据。

### ✅ 沙箱内**完整产出并签名 APK**（2026-10-28 真机）

手工链路，全程 PRoot guest 内，零宿主侧工具：

```
aapt2 compile → aapt2 link → javac → d8 → zip → zipalign → keytool → apksigner
```

每一步退出码都是 0：

```
STEP 1 aapt2 compile   : exit=0
STEP 2 aapt2 link      : exit=0
STEP 3 javac           : exit=0
STEP 4 d8              : exit=0
STEP 5 zip add dex     : exit=0   adding: classes.dex (deflated 44%)
STEP 6 zipalign        : exit=0
STEP 7a keytool        : exit=0   Generating 2,048 bit RSA key pair …
STEP 7b apksigner sign : exit=0
STEP 8 apksigner verify: exit=0   Signer #1 certificate DN: CN=Sandbox, …
STEP 9 aapt2 dump badging: exit=0
  package: name='com.example.hello' compileSdkVersion='34'
  minSdkVersion:'29'  targetSdkVersion:'34'
  application-label:'HelloSandbox'
```

产物从沙箱拉出来验证过（**不是空壳**）：

```
signed.apk  8,605 B
  AndroidManifest.xml 1232 B | resources.arsc 564 B | classes.dex 1388 B
  META-INF/A.SF 412 B | META-INF/A.RSA 1249 B | META-INF/MANIFEST.MF 285 B
```

**仍未验证**：完整 `gradle assembleDebug`（AGP 构建真实项目，还需 AGP 插件
及其 Maven 依赖），以及 NDK / Flutter。
### ❌ 不是什么


| 不是 | 为什么 |
|---|---|
| ❌ **不是安全沙箱** | 无 namespace/cgroup/seccomp。见上 |
| ❌ 不含 Agent 循环 | 那是控制面，由宿主承担 |
| ❌ 不含对话 UI / 工作流编辑器 | 同上 |
| ❌ 不含项目模板体系 | 同上 |
| ❌ **不做权限决策** | 只报告「有哪些通道 + 风险等级」，放不放行是宿主的策略 |
| ❌ 不含无障碍通道 | 开源分发与商店审查风险过高，刻意不移植 |

---

## 5 分钟快速上手

```bash
# 1. 编译（PRoot 运行时与内置 rootfs 都已在仓库里，无需预热）
./gradlew :sandbox-app:assembleDebug

# 2. 装到设备（仅 arm64-v8a）
adb install -r sandbox-app/build/outputs/apk/debug/sandbox-app-debug.apk
```

**不需要联网、不需要跑任何预热脚本** —— 二进制与 rootfs 都随仓库交付。

打开 `Sandbox Demo`，按顺序点按钮：

| 步骤 | 做什么 | 预期 |
|---|---|---|
| **① 装 rootfs** | **内置 Alpine（离线，主路径）**，失败才转 OCI | `✅ 内置 rootfs 就绪`，`source=1` |
| **② 执行命令** | `echo hello`、`aapt2 version`、PTY 测试 | `hello` + `exit=0`；PTY 里 `fd0=/dev/pts/0`、`IS_TTY` |
| **③ 读写文件** | HOST 视角往返 + 两套视角对比 | `一致: ✅`，并看到同一字符串落在不同路径 |
| **④ 查四条通道** | 列出可用性 / 前置条件 / 风险 | NORMAL 可用；其余按设备实况如实报告 |
| **⑤ 跨进程（AIDL）** | bind `:sandbox` 进程走 AIDL 契约 | 与进程内结果一致，且 `ps` 里能看到 `:sandbox` |

全程有实时日志，失败也**如实显示原因与修法**（不隐瞒、不假装成功）。

> 想验证"离线真的能用"：关掉 WiFi 与移动数据后再点 ①，
> 应当仍看到 `source=1`（`SOURCE_BUNDLED`）而不是 `source=2`（OCI）。

---

## 上游关系

```
                    ┌─────────────────────────────────────┐
   基底 fork ──────► │  taixu  (wkbin/taixu)               │  持续跟踪
                    │  dc7fcddb88e5…  GPL-3.0             │
                    │  Android No-Root Linux Runtime      │
                    │  PTY / PRoot / OCI rootfs / 进程账本  │
                    └──────────────┬──────────────────────┘
                                   │ 剥离 harness/UI/template
                    ┌──────────────▼──────────────────────┐
                    │  Heracles-taixu-sandbox             │
                    │  GPL-3.0                            │
                    │  执行面 only                         │
                    └──────┬───────────────────┬──────────┘
                           │ 一次性移植          │ 一次性移植
              ┌────────────▼─────────┐  ┌──────▼──────────────────┐
              │ baicodex             │  │ tianxuan                │
              │ mubai0122/baicodex   │  │ xiaozhe7772222/tianxuan  │
              │ fb4bd5f98bb8…        │  │ caad40090a4f…            │
              │ · 三档权限模型        │  │ · 无线 ADB 通道          │
              │ · 零宽文件通道        │  │ · 配对状态机             │
              └──────────────────────┘  └─────────────────────────┘
```

三个上游都是 **GPL-3.0**，Heracles 本体也是 GPL-3.0，兼容。
**taixu 是持续跟踪的基线**；baicodex 与 tianxuan 是**一次性移植快照**
（commit hash 记录在 [`UPSTREAM.md`](UPSTREAM.md)，不持续跟踪）。

> ⚠️ 公开仓库的 URL 与上游 README 里写的不一定一致 —— 本仓库实际使用的
> 坐标是上面这三个。若发现失效，见 `UPSTREAM.md` 第 0 节记录了定位过程。

---

## 模块结构

```
sandbox/
├── sandbox-api/          唯一对外契约（7 个 AIDL + 数据模型/枚举/错误码）
├── sandbox-runtime/      执行面：PRoot / PTY JNI / rootfs（内置+OCI）/ 进程账本 / 工作区
│   ├── src/main/jniLibs/arm64-v8a/    ← PRoot 运行时（4 个二进制，**入库**）
│   └── src/main/assets/               ← rootfs-bundle.tar.gz（**入库**）
├── sandbox-channel/      四通道：NORMAL / SHIZUKU / ROOT / WIRELESS_ADB
├── sandbox-file/         文件通道 + PathSemantics（两套路径视角）
├── sandbox-app/          可独立运行的 demo（5 分钟闭环 + AIDL 跨进程演示）
├── docs/                 架构 / API / 通道矩阵 / 集成 / 安全边界 / 移植日志
├── tools/                fetch-proot.sh（重新获取/更新 PRoot）· fetch-bundled-rootfs
├── LICENSE               GPL-3.0 全文（35149 B，与 FSF 官方逐字节一致）
├── NOTICE                三个上游的版权声明与移植来源
└── UPSTREAM.md           上游 commit / 移植映射 / rebase 流程
```

> `tools/` 里的脚本现在是**可选工具**（用于更新版本或换 rootfs 发行版），
> 不是构建前置 —— 二进制与 rootfs 都已经在仓库里。

**依赖方向（无环）**：

```
sandbox-app ──┬──► sandbox-channel ──┐
              ├──► sandbox-file ─────┼──► sandbox-api
              └──► sandbox-runtime ◄┘         ▲
                        │                     │
                        └─────────────────────┘
```

`channel` 依赖 `runtime`（要实现 `ChannelQuery` SPI）；`file` 依赖 `runtime`
（用 `PathResolver` 做视角换算）；两者之间**没有**互相依赖。

---

## ABI 支持：**仅 arm64-v8a**

> ⚠️ **本沙箱只支持 arm64-v8a（AArch64）。32 位设备（armeabi-v7a）不支持。**

原因：
1. PTY JNI 层（`libpty_bridge.so`）只编 arm64
2. 内置 PRoot 与 loader 是 AArch64 可执行文件
3. `jniLibs` 里排除了 `armeabi-v7a` / `x86` / `x86_64`

在 32 位设备上会**装不上**（而不是装上后崩溃）—— 这是刻意的取舍：
与其给一个「能装但一跑就崩」的包，不如明确拒绝。

---

## 四类能力（AIDL 契约）

`ISandboxService` 只暴露这些：

```aidl
void      execute(ExecutionRequest, IExecutionCallback)   // PRoot 内执行，支持 PTY
FileResult readFile(path, pathView)                       // 读（含零宽穿透）
FileResult writeFile(path, bytes, pathView)               // 写
List<ChannelInfo> queryChannels()                         // 四通道可用性 + 风险
void      installRootfs(ociRef, IExecutionCallback)       // OCI 按需安装
void      useBundledRootfs()                              // 内置离线 fallback
RootfsStatus snapshotRootfs(name)                         // 快照
void      resetRootfs(name)                               // 重置
```

**权限决策（允许 / 确认 / 拒绝）不在沙箱内实现**，由宿主通过 `ChannelInfo.riskLevel`
自行决定。这是本沙箱能被**其它项目**复用的前提。

逐字段文档：[`docs/api-reference.md`](docs/api-reference.md)。

---

## 文档

| 文件 | 内容 |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | 分层架构：控制面 vs 执行面，SPI 适配层，时序图 |
| [`docs/api-reference.md`](docs/api-reference.md) | AIDL 逐字段文档 + **路径语义**（必读 §10） |
| [`docs/channel-matrix.md`](docs/channel-matrix.md) | 四通道：能做什么 / 前置条件 / 风险等级 |
| [`docs/integration-guide.md`](docs/integration-guide.md) | 宿主如何集成（进程内 + AIDL 两种） |
| [`docs/security-boundary.md`](docs/security-boundary.md) | **PRoot 不是安全边界**（必读） |
| [`docs/porting-log.md`](docs/porting-log.md) | 每个 Phase 的进度与所有偏离记录 |

---

## 两个最容易踩的坑（提前说）

### 1. 两套路径视角

```
"/data/x"
 ├── PathView.HOST    → 真实 Android 文件系统（零宽通道只在此生效）
 └── PathView.SANDBOX → PRoot rootfs 内的 /data/x
```

`execute("cat /data/x")` 走**沙箱视角**；`readFile("/data/x", HOST)` 走**宿主视角**。
同一个字符串可能指向**不同文件** —— 所以 AIDL 里 `pathView` **必填，没有默认值**。

`PathSemantics.kt` 用两个 `@JvmInline value class`（`HostPath` / `SandboxPath`）
在**类型层面**分开，混用直接编译不过。

### 2. Android 10+ 禁止从 App data 目录 exec

不能把 PRoot 复制到 `files/` 再执行（`error=13 Permission denied`，
即便 `chmod +x`）。必须**直接 exec `nativeLibraryDir` 里的**
（W^X 限制）。细节与配套的 `LD_LIBRARY_PATH` / DT_NEEDED 修法见
`docs/integration-guide.md` §4。

---

## 构建要求

| 项 | 要求 |
|---|---|
| JDK | 17+（本仓库用 21） |
| Gradle | 8.14.3（`gradlew` 自带，走腾讯云镜像） |
| AGP / Kotlin | 8.13.0 / 2.2.20 |
| compileSdk / minSdk | 36 / **29**（Android 10） |
| NDK | 28.2.13676358（编 PTY JNI） |
| CMake | 3.22.1 |
| ABI | **仅 arm64-v8a** |

```bash
./gradlew build                    # 全量编译 + 单测
./gradlew :sandbox-app:assembleDebug
```

**不依赖 Heracles 主仓库的任何模块** —— `sandbox/` 可以单独拷出去当独立工程。

---

## 协议

**GPL-3.0**。完整全文见 [`LICENSE`](LICENSE)（35149 字节，与 FSF 官方
`https://www.gnu.org/licenses/gpl-3.0.txt` 的 SHA-256 逐字节一致：
`3972DC9744F6499F0F9B2DBF76696F2AE7AD8AF9B23DDE66D6AF86C9DFB36986`）。

上游版权声明与移植来源见 [`NOTICE`](NOTICE)。

因为上游（taixu / baicodex / tianxuan）是 GPL-3.0 强 copyleft，
**本工程只能以 GPL-3.0 分发**，不能改成 MIT/Apache。

运行时拉取的第三方产物（PRoot 本体、OCI rootfs 镜像内内容、Termux 工具链）
各自适用其上游协议，不受本仓库 LICENSE 覆盖 —— 见 `NOTICE` 第 5 节。

---

## 已知限制（不掩饰）

1. **仅 arm64-v8a**，32 位设备不支持
2. **内置 rootfs 是 Alpine minirootfs（极简）**：有 `busybox`（`sh`/`ls`/`cp`/`tar`…），
   但**没有** `gcc`、`aapt2`、`python`。

   要 `gcc`/JDK 这类则需要联网 `installRootfs()` 更大镜像，或在 rootfs 里 `apk add`
3. **PRoot 不是安全边界**（重复第三遍，因为最重要）
4. 无线 ADB 通道需要 **`AdbTransport` SPI** 的具体实现（默认走外部 adb 二进制）。
   没提供时该通道如实报告不可用，其余三条不受影响
5. **Shizuku 依赖是 `compileOnly`**：宿主不加依赖时 SHIZUKU 通道会报告
   「未打包 shizuku api」。这是**设计如此**（不硬绑定），不是缺陷
6. 零宽通道**只在未打补丁的 ROM 上生效**，补丁后自动降级（不崩、不假装可用）
7. OCI 安装只支持 gzip / 裸 tar 层，不支持 zstd 层（遇到会明确报错并建议换镜像）
8. `snapshotRootfs` 是**全量复制**，不是写时复制 —— rootfs 大时慢且费空间
9. **APK 体积约 13.8 MB**：3.8 MB 内置 Alpine rootfs + 约 300 KB PRoot 运行时。
   构建套件**不打包进 APK**（体积太大），在「激活沙箱」时按需下载到 rootfs。
10. PTY 下 `tty` 命令在某些 busybox 构建里会返回 `not a tty`，但
    `[ -t 0 ]` / `fd0=/dev/pts/0` 均正确 —— 以 `IS_TTY` 为准（见 demo ②）

---

## 相关

- Heracles 本体：https://github.com/theohowie/Heracles
- taixu（基底）：https://github.com/wkbin/taixu
- baicodex（三档权限 + 零宽文件）：https://github.com/mubai0122/baicodex
- tianxuan（无线 ADB）：https://github.com/xiaozhe7772222/tianxuan
