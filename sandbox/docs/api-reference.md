# AIDL 接口参考

本文件逐字段说明 `sandbox-api` 的对外契约。**宿主照此文档即可独立接入**，
无需阅读沙箱实现代码。

- 契约包名：`com.heracles.sandbox.api`
- AIDL 源码：`sandbox-api/src/main/aidl/com/heracles/sandbox/api/`
- Kotlin 模型：`sandbox-api/src/main/kotlin/com/heracles/sandbox/api/`
- 最低 API：29（Android 10）
- 绑定方式：`bindService` + `ISandboxService.Stub.asInterface(binder)`

---

## 目录

1. [`ISandboxService`](#1-isandboxservice)
2. [`IExecutionCallback`](#2-iexecutioncallback)
3. [`ExecutionRequest`](#3-executionrequest)
4. [`ExecutionResult`](#4-executionresult)
5. [`FileResult`](#5-fileresult)
6. [`ChannelInfo`](#6-channelinfo)
7. [`RootfsStatus`](#7-rootfsstatus)
8. [`ChannelType` / `RiskLevel` / `PathView`](#8-枚举)
9. [`SandboxException` 错误码](#9-错误码)
10. [**路径语义**（必读）](#10-路径语义必读)

---

## 1. `ISandboxService`

沙箱对外的**唯一**契约，只暴露四类能力：**执行 / 文件 / 通道查询 / rootfs 管理**。

> **权限决策（允许 / 需确认 / 拒绝）不在本服务内实现。**
> 沙箱只报告「有哪些通道、前置条件是否满足、风险等级多少」，
> 由宿主按自己的信任策略决定放行与否。
> 这是本沙箱能被**其他项目复用**的前提 —— 它不能内置 Heracles 的策略。

| 方法 | 签名 | 阻塞 | 说明 |
|---|---|---|---|
| `execute` | `void execute(in ExecutionRequest, in IExecutionCallback)` | 否 | 在 PRoot 内执行命令，结果经回调上报 |
| `readFile` | `FileResult readFile(String path, int pathView)` | 是 | 读文件，支持零宽通道穿透 |
| `writeFile` | `FileResult writeFile(String path, in byte[], int pathView)` | 是 | 写文件 |
| `queryChannels` | `List<ChannelInfo> queryChannels()` | 是 | 四个通道的可用性与风险 |
| `installRootfs` | `void installRootfs(String ociRef, in IExecutionCallback)` | 否 | OCI 拉取安装（完整环境） |
| `useBundledRootfs` | `void useBundledRootfs()` | 是 | 用 APK 内置 minimal rootfs（离线 fallback） |
| `snapshotRootfs` | `RootfsStatus snapshotRootfs(String name)` | 是 | 快照当前 rootfs（构建前回滚用） |
| `resetRootfs` | `void resetRootfs(String name)` | 是 | 重置到快照 / 清空重装 |

### `execute` 的并发语义

- **非阻塞**：立即返回，过程走回调。宿主可同时发起多次执行。
- **有并发上限**：「前台有界命令」通道有上限（见 `ProcessRegistry`），
  超出时通过 `onError(CODE_BUSY)` **拒绝而不是排队** —— 排队会让超时语义失真。
- **取消**：宿主实现 `IExecutionCallback.isCancelled()` 返回 true 即可；
  沙箱在输出循环里轮询。**不需要额外的 cancel 调用**（避免「cancel 到达时任务已结束」的竞态）。

### `installRootfs` vs `useBundledRootfs`（双策略）

```
离线兜底（没网、第一次打开）           →  useBundledRootfs()          # 内置 Alpine，仅 busybox
更大的环境（有网）                     →  installRootfs("<oci-ref>")  # 换一个发行版镜像
装完还不够：工具要再装                  →  execute("apk add <包名>")
```

> ⚠️ **没有任何 rootfs 镜像自带 `apt`/`gcc`/`aapt2`。**
> PRoot 只提供文件系统视图，**不提供任何工具**；镜像里有什么你才能跑什么。
> Alpine 系只有 busybox；要构建工具得在 rootfs 内 `apk add` 或按
> README「构建工具装在 rootfs 里」装套件。
两个方法**并存且互不覆盖**：装过 OCI 之后仍可 `useBundledRootfs()` 切回内置，
反之亦然。**这条是硬约束** —— 否则用户第一次打开沙箱、在没网的环境下就卡死。

---

## 2. `IExecutionCallback`

执行过程的回调。**方向是双向的**：

| 方法 | 方向 | 说明 |
|---|---|---|
| `onOutput(int stream, String chunk, long sequence)` | 沙箱 → 宿主 | 增量输出 |
| `onProgress(int percent, String message)` | 沙箱 → 宿主 | 长任务进度 |
| `onExit(in ExecutionResult result)` | 沙箱 → 宿主 | 正常结束（含非 0 退出码 / 超时 / 取消） |
| `onError(int code, String message)` | 沙箱 → 宿主 | 沙箱自身出错，此时**不会**有 `onExit` |
| `boolean isCancelled()` | 宿主 → 沙箱（**拉**） | 取消信号 |

### 字段

**`onOutput`**

| 参数 | 类型 | 说明 |
|---|---|---|
| `stream` | `int` | `STREAM_STDOUT=1` / `STREAM_STDERR=2` |
| `chunk` | `String` | 文本片段。UTF-8 已做**增量解码**，不会切坏多字节字符 |
| `sequence` | `long` | 从 0 单调递增，宿主可用于检测丢失/重排 |

**`onProgress`**

| 参数 | 类型 | 说明 |
|---|---|---|
| `percent` | `int` | `0..100`；**负数表示不确定进度**（只更新消息） |
| `message` | `String` | 人类可读阶段描述，可为空串 |

### 关键约定

1. **所有回调都可能来自后台线程。** 宿主实现必须自己切回主线程再更新 UI。
2. **回调实现绝不能阻塞。** 沙箱按顺序投递并等待返回。
3. **`isCancelled()` 必须立即返回且不得阻塞。** 它在输出循环里被高频调用。
4. **`onError` 与 `onExit` 互斥。** 收到 `onError` 就不要再等 `onExit`。

---

## 3. `ExecutionRequest`

> ⚠️ **`workingDirectory` 是"沙箱视角"路径**（PRoot 根文件系统内部），
> 不是宿主 App data 目录路径。见 [§10 路径语义](#10-路径语义必读)。

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `command` | `String` | — | **必填**。由 rootfs 内 `/bin/sh -c` 解释，可带管道/重定向。空串抛 `CODE_INVALID_ARGUMENT` |
| `workingDirectory` | `String` | `/workspace` | 沙箱视角路径 |
| `environment` | `List<String>` | `[]` | 追加环境变量，形如 `"K=V"` |
| `timeoutMillis` | `long` | `0` | 超时（毫秒）；`<=0` 表示不限时 |
| `usePty` | `boolean` | `false` | 是否分配伪终端。交互式/带颜色的构建输出需要 |
| `ptyColumns` | `int` | `80` | PTY 宽；`usePty=false` 时忽略 |
| `ptyRows` | `int` | `24` | PTY 高 |
| `channelType` | `int` | `-1` | 指定通道（`ChannelType` ordinal）；**`-1` = 自动选路** |
| `inputData` | `String` | `""` | 一次性写入 PTY 的 stdin，写完后关闭；空串 = 不喂 |

### 什么时候要 `usePty = true`

- 命令输出有 ANSI 颜色 / 光标控制（`gradle`、`npm`、`aapt2` 的某些子命令）
- 需要真实终端语义（Ctrl+C 中断、`SIGWINCH` 尺寸变化、`isatty()` 返回 true）
- 交互式提示（`read -p`）

否则用 `false`：管道语义更容易捕获完整输出，也没有终端控制字符干扰。

---

## 4. `ExecutionResult`

| 字段 | 类型 | 说明 |
|---|---|---|
| `exitCode` | `int` | 进程退出码 |
| `stdout` | `String` | 聚合 stdout（**已按上限截断**） |
| `stderr` | `String` | 聚合 stderr（已截断） |
| `durationMillis` | `long` | 墙钟耗时 |
| `timedOut` | `boolean` | 是否因超时被杀 |
| `cancelled` | `boolean` | 是否因宿主取消被杀 |
| `truncated` | `boolean` | 聚合文本是否发生过截断 |
| `channelType` | `int` | **实际**使用的通道（`ChannelType` ordinal） |

派生属性：`isSuccess = (exitCode == 0 && !timedOut && !cancelled)`

> ⚠️ **流式增量以 `onOutput` 为准。** `stdout`/`stderr` 只是为了
> 「单次执行结束后一次性取回」的便利，宿主**不应**依赖它拿到全量日志
> （长构建会截断）。要完整日志请自己拼 `onOutput` 的 chunk。

---

## 5. `FileResult`

| 字段 | 类型 | 说明 |
|---|---|---|
| `success` | `boolean` | 是否成功。`false` 时只有 `errorCode`/`errorMessage` 有意义 |
| `path` | `String` | **规范化后实际用到的路径（回显）** |
| `data` | `byte[]` | 读到的字节；写入时为 `null` |
| `size` | `long` | 读/写字节数；失败为 `-1` |
| `lastModified` | `long` | 文件 mtime（epoch millis）；未知为 `-1` |
| `pathView` | `int` | 实际使用的视角（`PathView.HOST=0` / `SANDBOX=1`） |
| `errorCode` | `int` | `SandboxException` 的 `CODE_*`；`0` = 无错误 |
| `errorMessage` | `String` | 可直接展示的说明 |

辅助方法：`asText()` —— `data` 按 UTF-8 解成字符串（非文本文件别用）。

> 💡 **排查技巧**：`exec` 里读得到、`readFile` 读不到时，
> **先比对 `path` 回显**。大概率是 `pathView` 传错了 —— 见 §10。

---

## 6. `ChannelInfo`

| 字段 | 类型 | 说明 |
|---|---|---|
| `type` | `int` | `ChannelType` 的 ordinal |
| `displayName` | `String` | 人类可读通道名 |
| `available` | `boolean` | 前置条件是否**全部**满足 |
| `unavailableReason` | `String` | 不可用原因；可用时为空串 |
| `missingPrerequisites` | `List<String>` | 缺失的前置条件，**可直接展示给用户** |
| `riskLevel` | `int` | `RiskLevel` 的 ordinal |
| `capabilitySummary` | `String` | 该通道能力的一句话摘要 |
| `supportsPty` | `boolean` | 是否支持真实 PTY 语义 |
| `supportsCrossAppData` | `boolean` | 是否能穿透访问其它 App 的 data 目录 |
| `executionIdentity` | `String` | 执行身份（`"u0_a123"` / `"shell"` / `"root"`） |

**顺序保证**：`queryChannels()` 按 `ChannelType` 的**声明顺序**返回
（NORMAL、SHIZUKU、ROOT、WIRELESS_ADB），宿主可直接用 ordinal 建索引。

> ⚠️ **本结构刻意不含「是否允许使用」字段。**
> 沙箱报告事实与风险等级；**放不放行是你的策略**。
> 例如你可以：`HIGH` 默认拒绝、`MEDIUM` 每次确认、`LOW` 直接放行 ——
> 这个映射表由宿主维护，沙箱不参与。

辅助属性：`channelType`（`ChannelType?`）、`risk`（`RiskLevel?`）。

---

## 7. `RootfsStatus`

| 字段 | 类型 | 说明 |
|---|---|---|
| `installed` | `boolean` | 是否有可用 rootfs |
| `source` | `int` | `0`=未安装 / `1`=内置 bundled / `2`=OCI |
| `label` | `String` | 人类可读标识（`"alpine-3.20"` / `"bundled-minimal"`） |
| `ociRef` | `String` | OCI 安装时回显引用；否则空串 |
| `sizeBytes` | `long` | 占用字节；未知 `-1` |
| `snapshotName` | `String` | 当前生效快照名；无快照为空串 |
| `snapshotCount` | `int` | 已有快照数量 |
| `rootfsPath` | `String` | **宿主视角**的 rootfs 根目录绝对路径 |

常量：`RootfsStatus.NOT_INSTALLED`、`SOURCE_NONE/SOURCE_BUNDLED/SOURCE_OCI`。

> ⚠️ `rootfsPath` 是**宿主视角** —— 它真实落在
> `{app.filesDir}/sandbox/rootfs/` 下，宿主可以用普通 `java.io.File` 访问。
> 但沙箱内看到的 `/` 才是这个目录。

---

## 8. 枚举

### `ChannelType`

| 值 | ordinal | 含义 | 前置条件 |
|---|---|---|---|
| `NORMAL` | 0 | 普通 App 身份（`u0_aXXX`） | 无。**永远可用** |
| `SHIZUKU` | 1 | Shizuku 提供的 shell（uid 2000） | 装 Shizuku 并授权 |
| `ROOT` | 2 | su（uid 0） | 设备已 root 且授予 superuser |
| `WIRELESS_ADB` | 3 | 无线 ADB 自调试（shell） | 开发者选项开「无线调试」+ 已完成 `adb pair` |

### `RiskLevel`

| 值 | ordinal | 含义 |
|---|---|---|
| `LOW` | 0 | 影响范围限于本 App 自己的沙箱 |
| `MEDIUM` | 1 | 超出本 App，但限于用户级数据或需用户可感知授权 |
| `HIGH` | 2 | 影响整机：root、系统设置、其它 App 私有数据 |

### `PathView`

**本枚举是沙箱里最容易出错的概念，必读 §10。**

| 值 | `wireValue` | 含义 |
|---|---|---|
| `HOST` | `0` | **宿主进程视角**：真实 Android 文件系统路径。零宽通道只在此视角生效 |
| `SANDBOX` | `1` | **沙箱视角**：PRoot rootfs 内部路径，由 `PathResolver` 映射到宿主路径 |

`fromWire(int)` 会拒绝非法值并抛 `CODE_INVALID_ARGUMENT`。

---

## 9. 错误码

`SandboxException.code` / `onError(code)` / `FileResult.errorCode` 共用这一套。

> 💡 **按码分支比按文案匹配稳。** 错误码是契约的一部分。

| 常量 | 值 | 含义 |
|---|---|---|
| `CODE_INVALID_ARGUMENT` | 1 | 参数非法（空命令、越界路径、非法 `pathView`） |
| `CODE_ROOTFS_NOT_READY` | 2 | rootfs 还没装（既没 OCI 也没内置解包） |
| `CODE_ROOTFS_CORRUPT` | 3 | rootfs 解包/校验失败 |
| `CODE_CHANNEL_UNAVAILABLE` | 4 | 指定的通道当前不可用 |
| `CODE_NO_CHANNEL` | 5 | 没有任何可用通道 |
| `CODE_BUSY` | 6 | 并发超限（前台有界命令通道已满） |
| `CODE_IO` | 7 | 沙箱自身 I/O 失败 |
| `CODE_TIMEOUT` | 8 | 执行超时 |
| `CODE_CANCELLED` | 9 | 被宿主取消 |
| `CODE_INTERNAL` | 10 | 沙箱内部错误（不应发生） |
| `CODE_NETWORK` | 11 | 网络不可用（OCI 拉取、ADB 配对） |
| `CODE_MOUNT_UNKNOWN` | 12 | 引用了**未注册**的 `@name`（不回退猜物理路径） |
| `CODE_MOUNT_READ_ONLY` | 13 | 对**只读挂载点**写入（宿主侧直接拒绝，不进 PRoot） |

---

## 10. 路径语义（必读）

### 10.1 同一个字符串，两个文件

**`/data/data/com.example/app.bin` 这个字符串，在两套语义下指向不同文件：**

```
"/data/data/com.example/app.bin"
 │
 ├── PathView.HOST    → 真实 Android 文件系统路径
 │                       /data/data/com.example/app.bin
 │                       ├─ 零宽通道在这里生效（只对 /storage/emulated/0/Android/{data,obb}）
 │                       └─ 受 SELinux + DAC 限制，通常读不到别的 App 的私有目录
 │
 └── PathView.SANDBOX → PRoot rootfs 内部的 "/data/data/com.example/app.bin"
                        → 实际落在 {filesDir}/sandbox/rootfs/data/data/com.example/app.bin
                        → 是 rootfs 里那个（可能根本不存在的）文件
```

### 10.2 为什么这很危险

`execute()` 里跑的命令，**看到的路径是沙箱视角**（被 PRoot 的 `-b` 绑定重写后）。
而 `readFile()` 传的是**宿主视角**。

于是：

```kotlin
// 宿主以为"写了个配置，然后 cat 一下验证"
service.writeFile("/workspace/conf.json", bytes, PathView.HOST)
// → 写到了宿主文件 {filesDir}/sandbox/rootfs/workspace/conf.json？

// 沙箱执行
var cmd = "cat /workspace/conf.json"
// → PRoot 里 /workspace 被绑定到 rootfs 的 workspace，能读到 —— 巧合对了
```

但换个路径就错：

```kotlin
service.writeFile("/data/local/tmp/x", bytes, PathView.HOST)
// → 写到真实 /data/local/tmp/x（宿主有权限才行）

var cmd = "cat /data/local/tmp/x"
// → PRoot 里 /data/local/tmp/x 指的是 rootfs 内的同名路径，**读不到刚才写的那个**
```

### 10.3 决策表

| 你想做的事 | 用哪个视角 |
|---|---|
| 读写**沙箱内**的文件（rootfs 里的项目、配置） | `SANDBOX` |
| 读写**宿主 App** 的文件（cache、files、外部存储） | `HOST` |
| 读写**别的 App 的 data**（要零宽通道） | `HOST`（只对 `/storage/emulated/0/Android/{data,obb}` 生效） |
| 和目标 APK / 构建产物打交道 | `HOST`（它们在真实文件系统上，不在 rootfs 里） |
| 和 `execute()` 里跑的命令共享文件 | `SANDBOX`（并确保该路径在 rootfs 内） |

### 10.4 排查清单

`exec` 里能读到、`readFile` 读不到（或反过来）时：

1. **先看 `FileResult.path` 回显** —— 那是沙箱实际用到的路径
2. 确认 `pathView` 传的是不是你以为的那个
3. 确认目标路径是否真的在 rootfs 内（`SANDBOX` 视角）或在真实文件系统上（`HOST` 视角）
4. 检查是不是 `..` 穿越被 `PathResolver` 拒掉了（防逃逸出 rootfs）
5. 对 `HOST` 视角：检查 SELinux / DAC 是否允许（普通 App 读不到别的 App 私有目录是**正确行为**）

### 10.5 一句话

> **`execute` 里看见的是沙箱；`readFile(HOST)` 看见的是宿主。**
> 需要跨过去时，用 `PathView` 明确说，不要靠"通常能对上"。

---

---

## 11. MountRegistry（逻辑命名挂载）

> **模型永远只写 `@name/...`，物理路径由宿主解析。**
> 换设备或改共享目录时只改配置表，**模型提示词与历史对话不用动**。

### 11.1 三级结构

```
@name/...          ← 第 1 级：逻辑命名空间（模型只写这个）
   ↓ MountResolver（sandbox-file）
物理路径 / SAF 文档  ← 第 2 级：宿主视角
   ↓ PathSemantics（sandbox-file）
HOST / SANDBOX      ← 第 3 级：两套物理语义
```

`PathSemantics` 保持不变，只做第 2→3 级。MountRegistry 插在它**前面**。

### 11.2 数据模型 `MountEntry`

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | String | 逻辑名，**不含 `@`**；只允许 `[a-z0-9_]+` |
| `backend` | int | `MountBackend.wireValue` |
| `hostPath` | String | 见下面三种 backend |
| `treeUri` | String | `SAF_TREE` 的持久化 tree URI |
| `readOnly` | boolean | true = 宿主侧直接拒绝写入 |
| `bindTo` | String | 可选，绑进 PRoot 的 guest 挂载点 |
| `description` | String | 给模型看的简短说明（可选） |

### 11.3 三种 backend

| backend | `wireValue` | `hostPath` 语义 | 读 | 写 | 能否 bind |
|---|---|---|---|---|---|
| `ROOTFS_RELATIVE` | 0 | **rootfs 内相对路径**（如 `opt/ws`） | `<rootfs>/<hostPath>/<rest>` | 同左 | 可选（`bindTo`） |
| `HOST_PRIVATE_DIR` | 1 | **宿主绝对路径**（如 `/data/data/<pkg>/files/libs`） | `<hostPath>/<rest>` | 同左 | 可选（`bindTo`） |
| `SAF_TREE` | 2 | **不使用**（必须为空） | SAF 文档 API | SAF 文档 API | ❌ 禁止 |

**关键约束（注册时就校验，不等用到才发现）：**

- `ROOTFS_RELATIVE` 的 `hostPath` 必须是**相对**路径、不含 `..`
- `HOST_PRIVATE_DIR` 的 `hostPath` 必须是**绝对**路径、不含 `..`
- `SAF_TREE` 必须有 `content://` 的 `treeUri`，且**不得**设置 `hostPath`
  （SAF 没有可靠物理映射，硬转 `file://` 在 Android 16+ 直接失效）
- `SAF_TREE` **不允许** `bindTo`

### 11.4 解析规则（顺序是硬约束）

1. 模型传 `@name/...`；取前缀查 `MountRegistry`
2. **未注册 → `CODE_MOUNT_UNKNOWN`，绝不回退到物理路径猜测**
   （猜路径会让模型以为拼对了，换设备时才炸，且报错点离原因很远）
3. 命中 `readOnly` 且是写操作 → **宿主侧直接抛 `MountReadOnlyException`**，
   返回 `CODE_MOUNT_READ_ONLY`，**不进 PRoot 靠文件权限兜底**
   （进 PRoot 再失败会变成 EACCES，宿主无法区分「只读挂载」和「磁盘满」）
4. `ROOTFS_RELATIVE` / `HOST_PRIVATE_DIR` → 解析为物理路径 → 交给 `PathSemantics`
5. `SAF_TREE` → **走 SAF 文档 API，不转物理路径**

### 11.5 `execute` 命令里的 `@name`

命令串里的 `@name/...` 在**组装 proot 命令行之前**改写：

```
ExecutionRequest(command = "cat @workspace/x.txt")
   ↓ CommandRewriter.rewriteCommand()      ← 在这里改写
   ↓ ProotExecSpec(commandLine = 已改写, extraBinds = MountBindSource.bindMounts())
   ↓ ProotEngine.buildCommandLine()
```

改写目标是 **guest 路径**（不是宿主路径）：

| 情况 | 改写为 | 原因 |
|---|---|---|
| 配了 `bindTo` | `bindTo + rest` | 绑进去的那个挂载点 |
| `ROOTFS_RELATIVE` 无 `bindTo` | `/` + `hostPath` + rest | guest 的根就是 rootfs |
| `HOST_PRIVATE_DIR` 无 `bindTo` | **报错** | 宿主私有目录在 guest 内不可见 |
| `SAF_TREE` | **报错** | 没有物理路径，命令只能在 PRoot 内跑 |
| `hostPath` 落在标准 bind 覆盖区 | **报错** | 会被 bind 盖住，读到别处 |

标准 bind 覆盖区（见 `ProotEngine`）：
`/workspace` `/root` `/tmp` `/attachments`（沙箱自有）
+ `/dev` `/proc` `/sys` `/apex` `/system` `/system_ext` `/vendor` `/product` `/odm`
`/data/app` `/data/dalvik-cache` `/linkerconfig`（系统绑定）。

### 11.6 只读语义

- 只读条目：**读正常，写被拒**
- 拒绝发生在**宿主侧**，错误码 `CODE_MOUNT_READ_ONLY`，异常类型 `MountReadOnlyException`
  （带 `mountName` / `attemptedPath`，宿主可直接给用户提示「@libs 是只读挂载」）
- **不会**进 PRoot 再靠文件权限兜底

### 11.7 SAF 授权流程（宿主侧做）

```kotlin
// 1. 让用户选目录
val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
    addFlags(
        Intent.FLAG_GRANT_READ_URI_PERMISSION or
        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
    )
}
startActivityForResult(intent, REQ_TREE)

// 2. onActivityResult 里持久化授权（**不做这一步，设备重启后就失效**）
contentResolver.takePersistableUriPermission(
    uri,
    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
)

// 3. 注册挂载点
registry.register(
    MountEntry(
        name = "pc_shared",
        backend = MountBackend.SAF_TREE,
        treeUri = uri.toString(),
        description = "电脑共享目录",
    ),
)
```

> ⚠️ **不要为了读电脑文件申请 `MANAGE_EXTERNAL_STORAGE`。**
> SAF 目录授权已经够用，全盘权限是商店审核的高风险项。

### 11.8 AIDL 上的两个方法

| 方法 | 用途 |
|---|---|
| `registerMount(MountEntry)` | 注册/覆盖；结构非法返回 `CODE_INVALID_ARGUMENT` |
| `listMounts()` | 按注册顺序列出（宿主展示只读状态用） |

这两个**不属于四类核心能力**；`execute` / `readFile` / `writeFile` /
`queryChannels` / rootfs 管理的**签名与语义一字未改**。

为什么需要跨进程暴露：执行面跑在 `:sandbox` 进程，而 `@name` 的解析**必须**
在执行面完成（`SandboxFileService` 在那边），配置只能经 Binder 送过去。

---

## 附：最小接入示例

```kotlin
// 1. 绑定
val conn = object : ServiceConnection {
    override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
        val svc = ISandboxService.Stub.asInterface(binder)

        // 2. 查通道，自己决定放不放行
        val channels = svc.queryChannels()
        val usable = channels.filter { it.available }
        // —— 这里放你自己的信任策略（沙箱不给建议）

        // 3. 装 rootfs（先试内置，没有就联网）
        try {
            svc.useBundledRootfs()
        } catch (e: ServiceSpecificException) {
            svc.installRootfs("docker.io/library/alpine:3.20", progressCallback)
        }

        // 4. 执行
        svc.execute(
            ExecutionRequest(command = "echo hello", workingDirectory = "/workspace"),
            object : IExecutionCallback.Stub() {
                @Volatile var cancelled = false
                override fun onOutput(stream: Int, chunk: String, seq: Long) = print(chunk)
                override fun onProgress(percent: Int, message: String) = Unit
                override fun onExit(result: ExecutionResult) =
                    println("exit=${result.exitCode} in ${result.durationMillis}ms")
                override fun onError(code: Int, message: String) = println("ERR $code: $message")
                override fun isCancelled(): Boolean = cancelled
            }
        )
    }
    override fun onServiceDisconnected(name: ComponentName?) = Unit
}
```

完整可运行的例子见 `sandbox-app/` 的 `ExecuteDemo.kt` / `FileDemo.kt` / `ChannelDemo.kt`，
以及 `docs/integration-guide.md`。
