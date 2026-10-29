# 集成指南

本文件教你**把 Heracles-taixu-sandbox 接进你自己的 Android Agent 项目**。
按顺序读，大约 15 分钟能跑通。

> **前置提醒**：PRoot 不是安全边界。详见 `docs/security-boundary.md` ——
> 它解决的是「文件系统污染 / 崩溃恢复」，**不是**「跑恶意代码不会出事」。
> 如果你的场景需要真隔离，请用 Android 的 `isolatedProcess` 或虚拟化方案。

---

## 0. 30 秒版本

```kotlin
// 1. 依赖
dependencies {
    implementation("com.heracles.sandbox:sandbox-api:0.1.0")
    implementation("com.heracles.sandbox:sandbox-runtime:0.1.0")
    implementation("com.heracles.sandbox:sandbox-channel:0.1.0")
    implementation("com.heracles.sandbox:sandbox-file:0.1.0")
}

// 2. 装 rootfs（内置优先，失败转 OCI）
rootfs.useBundledRootfs()                       // suspend
    ?: rootfs.installOci("docker.io/library/alpine:3.20") { pct, msg -> }

// 3. 执行
engine.executePiped(spec, scope, listener) { cancelled }

// 4. 查通道
val channels = ChannelManager(context).queryChannels()
```

> 现在是**源码集成**（四个 module 直接拷进你的 Gradle 工程）。
> 发布到 Maven 的坐标是占位，见 §7「发布」。
> 也可以完全不集成源码：把 `sandbox-app` 装成独立 App，通过 AIDL 跨进程调用（§3）。

---

## 1. 两种集成形态，先选一个

| | **进程内（库）** | **跨进程（AIDL Service）** |
|---|---|---|
| 怎么做 | 依赖四个 module，直接调 Kotlin API | bind 一个 Service，走 `ISandboxService` |
| 上手难度 | 低（无 Stub、无绑定、无序列化） | 中（要写 Service + 绑定 + 异常映射） |
| 进程隔离 | 无（同一进程，共享内存与 fd） | 有（binder 边界） |
| 崩溃影响 | 沙箱挂了宿主一起挂 | 沙箱进程挂了宿主可重连 |
| 适合 | 单 App、快速验证、demo | 多 App 复用、想让执行面独立存活 |
| 文档 | 本文件 §2–§6 | 本文件 §3 |

**建议**：先用进程内把闭环跑通（5 分钟），需要进程隔离时再切 AIDL。
两者调用面**刻意同形**（`SandboxFacade.execute` 与 `ISandboxService.execute`
签名一致），切换只改绑定那一层。

---

## 2. 进程内集成（推荐起步）

### 2.1 依赖

把 `sandbox-api` / `sandbox-runtime` / `sandbox-channel` / `sandbox-file`
四个 module 拷进你的工程（或用 `includeBuild`），然后：

```kotlin
// 你的 app/build.gradle.kts
dependencies {
    implementation(project(":sandbox-api"))
    implementation(project(":sandbox-runtime"))
    implementation(project(":sandbox-channel"))
    implementation(project(":sandbox-file"))

    // ★ Shizuku 是 compileOnly，**是否带由你决定**：
    //   带 → SHIZUKU 通道可用（需用户在设备上装 Shizuku 并授权）
    //   不带 → SHIZUKU 通道如实报告「未打包 shizuku api」，其它三条不受影响
    implementation("dev.rikka.shizuku:api:13.1.5")   // 可选
}
```

**必须确认的三件事**：

1. `minSdk >= 29`（沙箱用了 Android 10 起的 API）
2. ABI 只有 `arm64-v8a`：
   ```kotlin
   defaultConfig { ndk { abiFilters += "arm64-v8a" } }
   ```
3. `android:extractNativeLibs="true"`（PRoot 需要从 `nativeLibraryDir` 直接 exec）

### 2.2 装配四个模块

```kotlin
val baseDir = File(context.filesDir, "sandbox").apply { mkdirs() }

// rootfs 管理（同时是 PathResolver）
val rootfs = RootfsManager(baseDir = baseDir, assets = context.assets)

// PRoot 执行核心
val engine = ProotEngine(
    prootBinary        = File(context.applicationInfo.nativeLibraryDir, "libproot.so"),
    loaderBinary       = File(context.applicationInfo.nativeLibraryDir, "libproot-loader.so")
                             .takeIf { it.isFile },
    rootfsHostRoot     = File(rootfs.rootfsHostPath()!!),
    workspaceHostRoot  = File(rootfs.rootfsHostPath()!!, "workspace").apply { mkdirs() },
    homeHostRoot       = File(rootfs.rootfsHostPath()!!, "root").apply { mkdirs() },
    tmpHostRoot        = File(rootfs.rootfsHostPath()!!, "tmp").apply { mkdirs() },
    attachmentsHostRoot= File(context.filesDir, "attachments").apply { mkdirs() },
)

// 文件读写（含零宽通道）
val pathSemantics = PathSemantics { rootfs.rootfsHostPath()?.let { HostPath.parse(it) } }
val files = SandboxFileService(pathSemantics, ZeroWidthFileChannel())

// 四通道
val channels = ChannelManager(context = context)
```

> ⚠️ `engine` 依赖 `rootfs.rootfsHostPath()`，**必须先装 rootfs 再建 engine**。
> 或者把 engine 做成 `by lazy`（见 `sandbox-app/.../SandboxFacade.kt` 的完整写法）。

### 2.3 装 rootfs（**内置是主路径**，OCI 是可选升级）

```kotlin
suspend fun ensureRootfs(onProgress: (Int, String) -> Unit) {
    if (rootfs.status().installed) return

    // ① 内置 rootfs：**离线主路径**。已在仓库里（Alpine minirootfs 3.8 MB），
    //    打进 APK，装上就能用 —— 不联网、不依赖服务器/云端。
    val bundled = rootfs.useBundledRootfs()
    if (bundled.isInstalled) return

    // ② OCI：**可选升级**。要 gcc/apt/完整工具链时才走这条，需要网络。
    rootfs.installOci("docker.io/library/alpine:3.20", onProgress)
}
```

**这个顺序不能反。** 本沙箱的定位是**完全离线内置**（见 README 的
「完全离线内置」一节）：用户拿到 APK、装上、断网也必须能用。
OCI 只是「想要更强环境时」的升级路径。

**为什么两条都要保留**：
- 只有内置 → 环境能力有上限（Alpine minirootfs 没有 `gcc`/`aapt2`）
- 只有 OCI → 没网时完全不可用，且首次体验要等下载

⚠️ **`useBundledRootfs()` 永远不抛异常**（协程取消除外）—— 所有失败都表达在
`BundledRootfsResult.outcome` 里（`NOT_BUNDLED` / `CORRUPT` / `UNSUPPORTED` /
`IO_ERROR`）。**所以不要只用 `runCatching{}.getOrElse{}` 记录失败原因**，
那样「正常失败」会被静默吞掉（这是本工程踩过的坑：离线时内置明明在 APK 里
却装不上，而日志什么都没说）。要按 `outcome` 分支并打印 `result.message`。

需要「内置是硬性要求」的宿主用 `useBundledOrThrow()`，它会把 outcome 翻成
`SandboxException`。
**这是硬约束**，不是可选项。

### 2.4 执行

```kotlin
val spec = ProotExecSpec(
    commandLine = "echo hello",
    workingDirectory = "/workspace",     // ★ 沙箱视角
    timeoutMillis = 60_000,
)

engine.executePiped(
    spec = spec,
    scope = lifecycleScope,
    listener = ProotOutputListener { stream, chunk ->
        when (stream) {
            ProotEngine.STREAM_STDOUT -> appendToUi(chunk)
            ProotEngine.STREAM_STDERR -> appendToUiError(chunk)
        }
    },
    cancelSignal = { userPressedCancel },
)
```

**PTY vs 管道**：

| | `executePiped` | `executePty` |
|---|---|---|
| 语义 | 管道 | 真终端（`fork + setsid + TIOCSCTTY`） |
| `isatty()` | false | **true**（已真机验证 `fd0=/dev/pts/0`） |
| 输出 | stdout/stderr 分开 | 单流（PTY 本质） |
| 适合 | 脚本、构建、CI 式调用 | 交互式工具、带颜色的输出、`apt` |
| 额外参数 | — | `feedStdin`（一次性喂输入） |

### 2.5 文件读写（两套路径视角 —— **最容易错的地方**）

```kotlin
// 宿主视角：真实 Android 路径（App cache、/sdcard、别的 App 的 data）
files.write("/data/user/0/com.me/cache/a.txt", bytes, PathView.HOST)

// 沙箱视角：PRoot rootfs 内路径（实际落在 files/sandbox/rootfs/...）
files.write("/workspace/a.txt", bytes, PathView.SANDBOX)

// 类型安全版（推荐，编译器挡住混用）
files.writeHost(HostPath.parse("/sdcard/b.txt"), bytes)
files.writeSandbox(SandboxPath.parse("/workspace/b.txt"), bytes)
```

**`execute` 里看到的是沙箱视角，`readFile(HOST)` 看到的是宿主视角。**
同一个字符串可能指向**不同文件**。决策表见 `docs/api-reference.md` §10.3。

### 2.6 通道查询（**不做权限决策**）

```kotlin
val channels = channels.queryChannels()      // 顺序固定：NORMAL/SHIZUKU/ROOT/ADB

// ↓ 以下全部是**宿主**的事，沙箱不参与
val verdict = when (channels.first { it.type == ChannelType.ROOT.ordinal }.risk) {
    RiskLevel.HIGH   -> askUserEveryTime()
    RiskLevel.MEDIUM -> askUserOnce()
    else             -> allow()
}
```

沙箱只报告 `available` / `riskLevel` / `missingPrerequisites`。
**把你的信任策略写进沙箱，沙箱就只能被你自己用** —— 这是它不做决策的原因。

---

## 2.7 可选：把「构建套件」装进 rootfs（要编 APK 才需要）

> 这一节是**可选的**。沙箱本身（执行 / 文件 / 通道 / rootfs 管理）不需要任何构建工具。
> 只有当用户说「帮我编个 APK」时，才需要装它。

### 为什么装在 rootfs 里，而不是打进 APK

Android 的 `aapt2`（Termux 那种）是 **bionic** 二进制，解释器是 `/system/bin/linker64`。
在 PRoot 的 guest 里执行会 `execve` 返回 ENOENT —— 真机现象是
`command -v aapt2` 找得到路径、**执行却 `not found`（exit 127）**。

更关键的是：那种程序**只能跑在宿主进程**，等于绕过沙箱 ——
隔离、快照、回滚全都不生效。所以本工程**不在 APK 里带任何构建工具**
（`jniLibs` 只有 4 个 PRoot 运行时）。

rootfs 里要装的是 **linux-aarch64** 版（解释器 `/lib/ld-linux-aarch64.so.1`）。

### 装什么（与上游 taixu 的 android-suite-offline 同源）

| 组件 | 怎么装 | 装到 | 备注 |
|---|---|---|---|
| Android SDK 静态工具 | 归档 `android-sdk-tools-static-aarch64.zip` | `/opt/as` | 无依赖（静态） |
| JDK 17（**Alpine/musl**） | **`apk add --no-cache openjdk17-jdk`** | `/usr/lib/jvm/java-17-openjdk` | ✅ 真机验证 |
| JDK 17（glibc rootfs 才用） | 归档 `OpenJDK17U-jdk_aarch64_linux_hotspot_*.tar.gz` | `/opt/ja` | ⚠️ **Alpine 里跑不了**（127） |
| Gradle | 归档 `gradle-8.14.2-bin.zip` | `/opt/gradle` | 需要 JDK |

> ⚠️ **必须先分清 glibc / musl**
> Temurin 是 glibc 构建，内置 Alpine 是 musl ⇒ 真机实测 `java -version` 返回 **127**。
> 内置 rootfs 一律用 `apk add openjdk17-jdk`。

> ⚠️ **内置 rootfs 没有 `/etc/resolv.conf`** ⇒ `apk` 报 `temporary error`。
> 激活沙箱时要补一份（下面有代码）。

`BuildSuiteCatalog` 里有现成的组件声明（含 sha256）。

### 怎么装

**第一步：确保 guest 有 DNS**（内置 Alpine minirootfs 没有 `/etc/resolv.conf`，
缺了它 `apk` 一律报 `temporary error (try again later)`）：

```kotlin
// 只在缺失时补，不覆盖用户已有配置
sandbox.execute(ExecutionRequest(command =
    "test -s /etc/resolv.conf || " +
    "printf 'nameserver 114.114.114.114\\nnameserver 223.5.5.5\\n' > /etc/resolv.conf"
), callback)
```

**第二步：装工具**（全部在沙箱内执行，不是宿主进程）：

```kotlin
val rootfsRoot = File(filesDir, "sandbox/rootfs")   // rootfs 的宿主视角根目录
val installer = BuildSuiteInstaller(rootfsRoot)

// ① Android SDK 静态工具：约 13 MB，装完就能用 aapt2 / aidl / zipalign
installer.install(BuildSuiteCatalog.ANDROID_SDK_TOOLS) { done, total, stage ->
    // stage = "下载中" / "校验 sha256" / "解压" / "校验 ABI（必须是 linux-aarch64）"
}

// ② JDK：**Alpine 用 apk 装 musl 版**（不要用 Temurin，那是 glibc，跑不了）
sandbox.execute(ExecutionRequest(command =
    "apk add --no-cache openjdk17-jdk"
), callback)   // → /usr/lib/jvm/java-17-openjdk

// ③ Gradle：Java 归档，与 ABI 无关；离线安装（宿主先把 zip 推上来）
installer.installFromLocalArchive(BuildSuiteCatalog.GRADLE, File(filesDir, "gradle-8.14.2-bin.zip"))
```

离线场景用 `installFromLocalArchive(spec, File(...))` ——
宿主把归档推到 App 私有目录再传路径进去。

**安装器会拒绝 bionic 版**：解压后抽查 ELF 解释器，发现 `/system/bin/linker64`
就整体回滚并报错。宁可失败，也不装一个「在沙箱里跑不了的东西」。

### 装完之后怎么调用（**关键：必须带 envPrelude**）

```kotlin
val cmd = ToolchainLayout.envPrelude() + "aapt2 version"
sandbox.execute(ExecutionRequest(command = cmd, workingDirectory = "/"), callback)
```

`envPrelude()` 注入 `PATH` / `JAVA_HOME` / `ANDROID_HOME` /
`GRADLE_USER_HOME` / `TMPDIR`。

> ⚠️ **为什么必须显式带**：`sh -lc` 是**登录 shell**，会读 `/etc/profile`，
> 而 Alpine 的 `/etc/profile` 里有 `export PATH="/usr/local/sbin:..."` ——
> 会把我们设的 PATH **无条件覆盖**。所以只能在命令串前再
> `export PATH=...:$PATH;` 补一次。

### 真机验证（2026-10-28，Android 17 / arm64-v8a）

```
# aapt2 / aidl / zipalign
install result: success=true  msg=已安装到 .../rootfs/opt/as（13 MB）
sandbox which aapt2   = [/opt/as/build-tools/aapt2]                 exit=0
sandbox aapt2 version = [Android Asset Packaging Tool (aapt) 2.19-]  exit=0

# JDK 17（Alpine musl）
apk add openjdk17-jdk  → OK: 284 MiB in 43 packages
sandbox java -version  → exit=0  openjdk version "17.0.16"
                                     OpenJDK Runtime Environment (build 17.0.16+8-alpine-r0)
sandbox which java     = [/usr/bin/java]

# Gradle
sandbox gradle --version → exit=0
  Gradle 8.14.2
  Kotlin:        2.0.21
  Launcher JVM:  17.0.16 (Alpine 17.0.16+8-alpine-r0)
  Daemon JVM:    /usr/lib/jvm/java-17-openjdk
```

`which aapt2` 给的是 **`/opt/as/build-tools/aapt2`**（guest 路径），
不是宿主 `/data/app/.../lib/arm64/`；`Launcher JVM` 也是 Alpine 的 musl JDK
—— 这就是「在沙箱里跑」的证据。

### ✅ 沙箱内完整产出并签名 APK（真机验证）

手工链路，全程在 guest 内：

```
aapt2 compile → aapt2 link → javac → d8 → zip → zipalign → keytool → apksigner
```

```
STEP 1..9 全部 exit=0
STEP 8 apksigner verify: Signer #1 certificate DN: CN=Sandbox, OU=Test, O=Heracles, C=CN
STEP 9 aapt2 dump badging: package: name='com.example.hello' compileSdkVersion='34'

产物：signed.apk 8,605 B
  AndroidManifest.xml 1232 | resources.arsc 564 | classes.dex 1388
  META-INF/A.SF 412 | META-INF/A.RSA 1249 | META-INF/MANIFEST.MF 285
```

需要的额外材料（宿主预置到 rootfs）：

| 文件 | 放哪 | 来源 |
|---|---|---|
| `android.jar`（platform-34） | `/opt/as/platforms/android-34/` | `platform-34-ext7_r03.zip` |
| `d8.jar` | `/opt/tools/` | `build-tools_r35_linux.zip` → `lib/d8.jar` |
| `apksigner.jar` | `/opt/tools/` | 同上 → `lib/apksigner.jar` |

> ⚠️ 这个**不是** `gradle assembleDebug`。完整 AGP 构建还需要 AGP 插件
> 及其 Maven 依赖，目前**未验证**。

### 体积代价（如实说）

### 体积代价（如实说）

| 装到哪 | 占多少 | 谁承担 |
|---|---|---|
| APK | **+0**（不带任何构建工具） | — |
| rootfs（设备存储） | 只装 SDK 工具 ≈13 MB；+JDK ≈190 MB；+Gradle ≈130 MB | 用户设备 |
| NDK / Flutter | ≈1 GB / ≈848 MB | 可选，一般不要 |

---

## 3. 跨进程集成（AIDL）

### 3.1 宿主侧

```kotlin
class SandboxClient(private val context: Context) {

    private var service: ISandboxService? = null

    private val conn = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = ISandboxService.Stub.asInterface(binder)
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            service = null   // 沙箱进程挂了；宿主应重连而不是崩溃
        }
    }

    fun bind() {
        val intent = Intent("com.heracles.sandbox.BIND").apply {
            setPackage("com.heracles.sandbox.service")   // 沙箱 Service 的包名
        }
        context.bindService(intent, conn, Context.BIND_AUTO_CREATE)
    }
}
```

### 3.2 调用 execute

```kotlin
val callback = object : IExecutionCallback.Stub() {
    @Volatile private var cancelled = false

    override fun onOutput(stream: Int, chunk: String, sequence: Long) {
        // ★ 回调来自 binder 线程池，切回主线程再更新 UI
        mainHandler.post {
            when (stream) {
                IExecutionCallback.STREAM_STDOUT -> appendOut(chunk)
                IExecutionCallback.STREAM_STDERR -> appendErr(chunk)
            }
        }
    }

    override fun onProgress(percent: Int, message: String) {
        mainHandler.post { if (percent >= 0) progressBar.progress = percent }
    }

    override fun onExit(result: ExecutionResult) {
        mainHandler.post { showExit(result.exitCode, result.durationMillis) }
    }

    override fun onError(code: Int, message: String) {
        mainHandler.post { showError(code, message) }   // 不会再收到 onExit
    }

    override fun isCancelled(): Boolean = cancelled   // 必须立即返回

    fun cancel() { cancelled = true }
}

service?.execute(
    ExecutionRequest(
        command = "echo hello",
        workingDirectory = "/workspace",
        timeoutMillis = 60_000,
    ),
    callback,
)
```

### 3.3 AIDL 的六个坑（都踩过）

1. **回调来自 binder 线程池**，不是主线程。必须 `post` 回主线程。
2. **回调实现不能阻塞**：沙箱按顺序投递并等待返回。别在里面做 IO。
3. **`isCancelled()` 被高频调用**：实现必须 O(1) 且不加锁（用 `@Volatile Boolean`）。
4. **`onError` 与 `onExit` 互斥**：收到 `onError` 就别再等 `onExit`，否则永远等不到。
5. **别想着跨 binder 抛 `SandboxException`** —— 异常过 binder 会被包成
   `RuntimeException`，`code` 丢失。
   ⚠️ **也不要用 `android.app.ServiceSpecificException`**：它是 `@hide`，
   **公开 SDK 的 `android.jar` 里根本不存在**（实测 android-33/34/35/36 全部零命中），
   编译期就 `Unresolved reference`。
   ⇒ 正确做法：**用 `callback.onError(code, message)` 传错误码**。
6. **同步方法没有 callback 通道**：`readFile`/`writeFile` 把错误塞进
   `FileResult(success=false, errorCode, errorMessage)` 返回（不抛）；
   `queryChannels` 失败返回 `emptyList()`；`snapshotRootfs` 失败返回
   `RootfsStatus.NOT_INSTALLED`。只有 `useBundledRootfs`/`resetRootfs`
   （返回 void、无返回通道）才抛，且用**公开**的 `IllegalStateException`，
   message 里带 `code=xx` 供宿主用正则捞。

### 3.4 沙箱侧（如果你要自己起一个 Service）

```kotlin
class SandboxService : Service() {
    private val core by lazy { SandboxServiceCore(...) }
    private val binder = object : ISandboxService.Stub() {
        override fun execute(request: ExecutionRequest, callback: IExecutionCallback) {
            core.execute(request, callback)      // ← 用 core，不要用 engine 直通
        }
        // … readFile / writeFile / queryChannels / rootfs 同样委托给 core
    }
    override fun onBind(intent: Intent?): IBinder = binder
}
```

> ⚠️ **`execute` 必须走 `SandboxServiceCore`，不要走 `ProotEngine.execute` 直通路径。**
> core 才有：前台命令并发上限（超出 `CODE_BUSY`）、持久进程登记、
> `shutdown()` 时整进程树回收。engine 直通适合 demo，不适合生产。

---

---

## 3.5 命名挂载：Heracles 控制面怎么注册与展示

> 目标：**模型只写 `@name/...`**，物理路径由控制面解析。
> 换设备 / 改共享目录时只改配置表，模型提示词和历史对话不动。

### 3.5.1 启动时注册（控制面）

```kotlin
// Heracles 侧：初始化沙箱后注册挂载点。
// 这些是**配置**，不是代码路径 —— 换设备只改这张表。
val mounts = facade.mounts

// ① 工作区：rootfs 相对路径，读写
mounts.register(
    MountEntry(
        name = "workspace",
        backend = MountBackend.ROOTFS_RELATIVE,
        hostPath = "opt/ws",          // 注意：不要写 "workspace"（会被 bind 盖住）
        description = "当前项目源码与产物",
    ),
)

// ② 共享库：宿主私有目录，只读
mounts.register(
    MountEntry(
        name = "libs",
        backend = MountBackend.HOST_PRIVATE_DIR,
        hostPath = File(filesDir, "libs").absolutePath,
        readOnly = true,
        description = "预置的共享库（只读）",
    ),
)

// ③ 电脑共享目录：SAF（用户授权过的）
mounts.register(
    MountEntry(
        name = "pc_shared",
        backend = MountBackend.SAF_TREE,
        treeUri = persistedTreeUri,   // takePersistableUriPermission 之后的
        description = "电脑同步目录",
    ),
)
```

### 3.5.2 给用户展示只读状态

```kotlin
// 设置页/权限页里列出挂载点，让用户一眼看出哪个只能读
facade.mounts.list().forEach { m ->
    val badge = if (m.readOnly) "只读" else "读写"
    renderRow(prefix = m.prefix, badge = badge, note = m.description)
}
```

写入被拒时宿主拿到的错误是**可区分**的：

```kotlin
try {
    facade.files.write("@libs/x.so", data, PathView.HOST)
} catch (e: MountReadOnlyException) {
    // 直接告诉用户「@libs 是只读挂载」，而不是笼统的「写入失败」
    toast("${e.mountName} 是只读挂载，不能写入")
}
```

### 3.5.3 提示词里只出现 `@name`

```
✅ 正确：把构建产物写到 @workspace/out/app.apk
❌ 错误：把构建产物写到 /data/user/0/com.theohowie.heracles/files/sandbox/rootfs/opt/ws/out/app.apk
```

**物理路径不得出现在提示词、few-shot 示例、历史对话中** ——
一旦出现，换设备或改共享目录时历史对话就全失效了。

### 3.5.4 跨设备场景（构建在手机、运行在电脑）

```
@workspace   → rootfs 内构建产物（沙箱负责“构建”）
@pc_shared   → SAF 目录（宿主负责“交给电脑”）
```

> ⚠️ 沙箱**不提供** Wine / 任何跨平台二进制运行能力。
> 在手机上为电脑交叉编译 exe/dll，是**用 rootfs 内的 mingw-w64 之类的工具链构建**，
> 产物写 `@workspace`，再经 `@pc_shared` 交给电脑。
> **构建归沙箱，运行归目标平台。**

---

## 4. PRoot 运行时（**已内置，无需准备**）

PRoot 是上游产物（GPL-2.0-or-later），但本仓库**已经带齐**这四个二进制，
在 `sandbox-runtime/src/main/jniLibs/arm64-v8a/`：

| 文件 | 来源 | 大小 | 缺了会怎样 |
|---|---|---|---|
| `libproot.so` | Termux proot 包 | 239 KB | 完全无法执行 |
| `libproot-loader.so` | Termux proot 包（`loader`） | 18 KB | `execve("/bin/sh")` 失败 |
| `libtalloc.so` | proot 的动态依赖 | 31 KB | `CANNOT LINK EXECUTABLE` |
| `libandroid-shmem.so` | proot 的动态依赖（Termux 构建） | 14 KB | 同上 |

**正常构建不需要做任何准备。** 构建期有强校验：这 4 个文件缺失、过小、
或不是 AArch64 ELF → **构建直接失败**（`sandbox-runtime/build.gradle.kts` 的 `preBuild`），
不会产出一个装上去跑不了的 APK。

`tools/fetch-proot.sh` 是**可选工具**，只在你想要「换一个 Termux proot 版本」
或「二进制损坏需要重取」时才用：

```bash
bash tools/fetch-proot.sh                 # 从 Termux proot 包取
bash tools/fetch-proot.sh /path/to/proot  # 用你已有的
```

### 四个真机必踩的坑（已在代码里修好，别改回去）

**坑 1：Android 10+ 禁止从 App data 目录 exec。**

```kotlin
// ✗ 错：复制到 files/ 再 exec
val p = File(filesDir, "sandbox/bin/proot").apply { writeBytes(src.readBytes()); setExecutable(true) }
Runtime.getRuntime().exec(p.absolutePath)
// → error=13, Permission denied（即便 ls -la 显示 -rwx------）

// ✓ 对：直接 exec nativeLibraryDir 里的
val p = File(applicationInfo.nativeLibraryDir, "libproot.so")
Runtime.getRuntime().exec(p.absolutePath)
```

原因：Android 10（API 29）起对 app 私有 data 分区施加 **W^X**，
`untrusted_app` 域不允许从 data 目录执行，与文件权限位无关。
`nativeLibraryDir`（`/data/app/.../lib/arm64/`）被单独放行。

**坑 2：`nativeLibraryDir` 不在动态链接器的默认搜索路径里。**

proot 的 `DT_NEEDED` 有 `libtalloc.so.2`，而 APK 里只能叫 `libtalloc.so`。
直接 exec 会报 `CANNOT LINK EXECUTABLE ... library "libtalloc.so.2" not found`。

两处都要做（代码里都做了）：
1. `ProotEngine.hostEnvironment()` 把 `prootBinary.parentFile` 加进 `LD_LIBRARY_PATH`
2. `tools/fetch-proot.sh` 把二进制里的 `libtalloc.so.2` 补成 `libtalloc.so`

**坑 3：guest 里看不到 `/dev/pts` ⇒ PTY 退化成非交互。**

`HOST_SYSTEM_BINDINGS` 必须包含 `/dev`、`/dev/pts`、`/proc`、`/sys`。
缺了 `/dev` 时 `tty` 回答 "not a tty"，`apt`/`vim`/带颜色的构建输出会静默
退化成非交互模式（命令本身还"成功"了，极难排查）。

**坑 4：`-0` 与 `--change-id=0:0` 不能同时给。**
两者是 proot 的同一组互斥选项，同时给会在**每次执行**的 stderr 里打两行警告，
污染宿主的错误捕获。只保留 `-0`。

**坑 5：`PtySession.close()` 的 `cancelChildren()` 会取消调用方协程。**

`close()` 里有 `scope.coroutineContext.cancelChildren()`（用来收掉本会话的
读出协程）。如果 `scope` 就是调用方传进来的那个，这句话会把**调用方自己
正在跑的协程**一起取消。

症状极具迷惑性：命令**实际已成功**（`fd0=/dev/pts/0`、`IS_TTY` 都打印了），
但结果被判成 `exit=130 / 0ms / cancelled=true`（CancellationException 兜底分支）。

为什么长期没暴露：旧的 `ProotEngine.execute()` 每次 new 一个一次性 scope，
打到的只有它自己。换成 `SandboxServiceCore`（长期存活的 supervisor scope）后
才炸。⇒ **这是「改用 core」暴露的潜伏 bug，不是 core 的 bug。**

修法（已落地，别改回去）：`PtySession.open()` 里给会话一个只属于自己的子作用域

```kotlin
val sessionScope = CoroutineScope(
    scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]),
)
```

`SupervisorJob(parent)` 保留「调用方被取消时本会话也跟着取消」的语义，
但 `cancelChildren` 只打得到会话自己的读循环。

---

## 5. 验收清单（照这个自查）

- [ ] `minSdk >= 29`，ABI 只有 `arm64-v8a`，`extractNativeLibs="true"`
- [ ] 四个 PRoot 二进制在 `jniLibs/arm64-v8a/`（见 §4；本仓库已内置）
- [ ] **内置 rootfs 是主路径**：`useBundledRootfs()` 先跑，OCI 只是升级路径
- [ ] 内置 rootfs 失败时**按 `outcome` 分支打印 `result.message`**
      （不能只用 `runCatching{}.getOrElse{}` —— 那样正常失败会被吞掉）
- [ ] **断网验证过一次**：飞行模式/关 WiFi 后仍能装 rootfs 并执行命令
      （`RootfsStatus.source == 1` 即 `SOURCE_BUNDLED`）
- [ ] 执行走 `SandboxServiceCore`（不是 `ProotEngine` 直通 —— 直通没有并发准入
      与进程回收）
- [ ] AIDL 形态下 Service 声明了 `android:process=":sandbox"`
      （执行面崩溃不连坐宿主 UI）
- [ ] 错误码走 `onError(code, message)` / `FileResult.errorCode`，
      **没有**依赖跨 binder 抛异常
- [ ] `readFile/writeFile` 的 `pathView` **显式传**，没有默认值假设
- [ ] 回调里切回主线程再更新 UI
- [ ] `isCancelled()` 是 `@Volatile` 且无锁
- [ ] 宿主的信任策略写在**宿主**里（用 `riskLevel` 做映射），没写进沙箱
- [ ] 读过 `docs/security-boundary.md`，知道 PRoot 不是安全边界

---

## 6. 常见问题

**Q：`NoClassDefFoundError: dev/rikka/shizuku/Shizuku`**
你没有加 `implementation("dev.rikka.shizuku:api")`。这是**正常的降级**：
SHIZUKU 通道会报告不可用，其余三条不受影响。要么加依赖，要么接受降级。

**Q：`UnsatisfiedLinkError: dlopen failed: library "libpty_bridge.so" not found`**
ABI 不对。检查设备是不是 arm64-v8a（`Build.SUPPORTED_ABIS`），
以及 `abiFilters` 是否正确。**32 位设备不支持。**

**Q：`CANNOT LINK EXECUTABLE ... library "libtalloc.so.2" not found`**
见 §4 坑 2，两个修法都要做。

**Q：`proot error: execve("/bin/sh"): No such file or directory`**
rootfs 不完整或 loader 缺失。检查 `rootfs/bin/sh` 是否存在、
`libproot-loader.so` 是否打进 APK。

**Q：执行很慢，第一次尤其慢**
正常。首次要解包 rootfs、proot 要准备 loader、`--link2symlink` 要建目录。
后续快很多。

**Q：能跑 32 位设备吗？**
不能。PTY JNI 与内置 PRoot 都是 AArch64。**在 README 里已明确声明。**

---

## 7. 发布（想发成 AAR 的话）

当前是**源码集成**。要发 Maven 需要：

1. 在根 `build.gradle.kts` 加 `maven-publish` 与 `android { publishing { singleVariant("release") } }`
2. 每个 library module 配 `afterEvaluate { publishing { publications { ... } } }`
3. 坐标为 `com.heracles.sandbox:<module>:<version>`

> ⚠️ **GPL-3.0 义务**：发布 AAR 时必须同时提供**完整对应源码**。
> 这是强 copyleft 的硬性要求，不能用「二进制 + 文档」替代。
> 见 `NOTICE` 与 `LICENSE`。

---

## 8. 最小可运行参考

`sandbox-app/` 是一个**完整可运行**的例子，包含：

| 文件 | 演示什么 |
|---|---|
| `SandboxFacade.kt` | 四个模块怎么装配（**抄这段**） |
| `MainActivity.kt` | 5 分钟闭环 UI：装 rootfs → 执行 → 读写 → 查通道 |
| `ExecuteDemo.kt` | 装 rootfs + 执行（宿主最常抄的一段） |
| `FileDemo.kt` | 两套路径视角对比 |
| `ChannelDemo.kt` | 通道查询 + **宿主侧**策略示例 |

```bash
cd sandbox
bash tools/fetch-proot.sh          # 取 PRoot 二进制
./gradlew :sandbox-app:assembleDebug
adb install sandbox-app/build/outputs/apk/debug/sandbox-app-debug.apk
```

装完打开，按 ①②③④ 顺序点，每步都有实时日志。
