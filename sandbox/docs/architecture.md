# 架构：控制面 vs 执行面

Heracles-taixu-sandbox 是一条**分界线**。线的一边是「谁来决定要不要做」，
另一边是「怎么真的做出来」。沙箱只负责后者。

---

## 1. 一句话架构

> **控制面（宿主）决定做什么；执行面（沙箱）负责做出来并如实上报结果。**

沙箱**不**决定：

- 这条命令该不该跑（允许 / 需确认 / 拒绝）
- 这个通道该不该用（风险高就默认禁用？那是宿主的策略）
- 对话怎么组织、工作流怎么编排、项目模板长什么样

沙箱**只**回答：

- 现在有哪些通道可用、各自前置条件是否满足、风险等级是多少
- 命令在 PRoot 里跑出什么（stdout/stderr/exitCode/耗时/是否超时/是否被取消）
- 某个路径读到了什么字节、写成功了没有

---

## 2. 分层图

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          控制面 / CONTROL PLANE                          │
│                          （宿主，不在本仓库）                             │
│                                                                          │
│   ┌────────────────┐  ┌────────────────┐  ┌──────────────────────────┐  │
│   │  Agent 循环     │  │  对话 / UI      │  │  信任策略（允许/确认/拒绝）│  │
│   │  （工具调用）    │  │  （Compose…）   │  │  ← 沙箱刻意不实现         │  │
│   └────────┬───────┘  └────────────────┘  └───────────┬──────────────┘  │
│            │                                           │                 │
│            │  ① 调 AIDL ② 读 ChannelInfo.riskLevel ③ 自己决定放行        │
└────────────┼───────────────────────────────────────────┼─────────────────┘
             │                                           │
             │        AIDL 边界（唯一契约）               │
             ▼                                           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                   执行面 / EXECUTION PLANE（本仓库）                      │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  sandbox-api  —— 唯一对外契约                                      │  │
│  │    ISandboxService (execute / readFile / writeFile /                │  │
│  │                     queryChannels / installRootfs /                 │  │
│  │                     useBundledRootfs / snapshotRootfs / resetRootfs)│  │
│  │    IExecutionCallback (onOutput / onProgress / onExit /             │  │
│  │                        onError / isCancelled)                       │  │
│  │    ExecutionRequest / ExecutionResult / FileResult /                │  │
│  │    ChannelInfo / RootfsStatus / ChannelType / RiskLevel /           │  │
│  │    PathView / SandboxException                                      │  │
│  └────────────────────────────┬───────────────────────────────────────┘  │
│                               │                                          │
│        ┌──────────────────────┼──────────────────────┐                   │
│        ▼                      ▼                      ▼                   │
│  ┌───────────────┐  ┌──────────────────┐  ┌──────────────────────────┐  │
│  │sandbox-channel│  │ sandbox-runtime  │  │  sandbox-file            │  │
│  │               │  │                  │  │                          │  │
│  │ ChannelManager│  │ ProotEngine      │  │ SandboxFileService       │  │
│  │ ChannelSelector  │ PtySession(+JNI) │  │ ZeroWidthFileChannel     │  │
│  │               │  │ OciRootfsInstaller│ │ PathSemantics            │  │
│  │ NORMAL        │  │ BundledRootfs    │  │ SandboxFileProvider      │  │
│  │ SHIZUKU       │  │ ProcessRegistry  │  │                          │  │
│  │ ROOT          │  │ WorkspaceManager │  │                          │  │
│  │ WIRELESS_ADB  │  │ RootfsManager    │  │                          │  │
│  └───────┬───────┘  └────────┬─────────┘  └───────────┬──────────────┘  │
│          │                   │                        │                 │
│          │   SPI（沙箱内部唯一允许的跨模块方式）        │                 │
│          │   EventSink / PathResolver / ChannelQuery / fileAccess       │
│          └───────────────────┴────────────────────────┘                 │
│                                                                          │
│                       ┌──────────────────────┐                          │
│                       │  sandbox-app (demo)  │  ← 5 分钟闭环的活证据     │
│                       └──────────────────────┘                          │
└──────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                            设备 / DEVICE                                 │
│                                                                          │
│  PRoot 进程（用户态 ptrace 路径重写）                                     │
│    └─ rootfs（OCI 拉取 或 APK 内置解包）                                  │
│         ├─ /workspace   ←──── 宿主 {filesDir}/sandbox/rootfs/workspace   │
│         ├─ /usr /bin /etc …                                              │
│         └─ /proc /dev /sys（由 -b 绑定）                                  │
│                                                                          │
│  ★ PRoot 不是安全边界：无 namespace / cgroup / seccomp                    │
│    （详见 docs/security-boundary.md —— 这句话是硬要求，不可省）           │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 为什么要有 SPI 适配层

taixu 的 `runtime/` 原本与它的 `core/`（Room + DataStore + Koin + AppLogger）
深度耦合：155 个 runtime 文件里有 56 个 import 了 `top.wkbin.taixu.core.*`。

**直接搬** ⇒ 要么把 Room/DataStore 拖进沙箱（= 把控制面搬进来），
要么重写 56 个文件的依赖（成本失控）。

**采用的方案**：在 `sandbox-runtime` 里放一层**极薄**的 SPI，把「调用方」
抽象成一个可注入对象：

| SPI | 原本是什么 | 现在是什么 |
|---|---|---|
| `EventSink` | harness 的会话回调 | 宿主可选注入；默认 `NoOpEventSink` |
| `PathResolver` | 散落在 `RuntimePathManager` 里的路径拼接 | 单点收口，强制显式视角 |
| `ChannelQuery` | harness 权限层直接调用 | 由 `sandbox-channel` 实现并注入 |
| `fileAccess` | harness 的 FileOps | 由 `sandbox-file` 实现并注入，可空 |

三条硬纪律：

1. **沙箱绝不 import 宿主任何类型**（否则只能给 Heracles 用）
2. **所有 SPI 都有空实现**（不注入也能装 rootfs、跑命令、读写文件）
3. **模块依赖无环**：`api ← runtime ← {channel, file}`，`app → 全部`

---

## 4. 一次 `execute` 的完整时序

```
宿主                       ISandboxService       ChannelSelector    ProotEngine     设备(rootfs)
 │                              │                     │                │              │
 │ ① execute(req, cb)           │                     │                │              │
 ├─────────────────────────────>│                     │                │              │
 │                              │ ② selectChannel(-1) │                │              │
 │                              ├────────────────────>│                │              │
 │                              │    NORMAL(可用)      │                │              │
 │                              │<────────────────────┤                │              │
 │                              │ ③ 校验 rootfs 是否就绪               │              │
 │                              ├──────────────────────────────────────────────────>│
 │                              │ ④ 组装 proot 命令行（-r/-b/-w/-0）   │              │
 │                              ├─────────────────────>│                │              │
 │                              │                     │ ⑤ fork+exec    │              │
 │                              │                     ├───────────────>│              │
 │   cb.onProgress(0,"启动")     │                     │                │              │
 │<─────────────────────────────┤                     │                │              │
 │                              │                     │ ⑥ stdout 增量   │              │
 │   cb.onOutput(1, "hello\n",0)│                     │<───────────────┤              │
 │<─────────────────────────────┤                     │                │              │
 │                              │                     │ ⑦ 进程退出      │              │
 │                              │                     │<───────────────┤              │
 │   cb.onExit(ExecutionResult) │                     │                │              │
 │<─────────────────────────────┤                     │                │              │
```

**取消**是「拉」模型：沙箱在输出循环里周期性调 `cb.isCancelled()`，
返回 true 就向**进程组**发 SIGTERM，宽限期后 SIGKILL。宿主只需改一个
volatile 标志，不需要额外调用 `cancel()` —— 也就没有「cancel 到达时任务已结束」
的竞态。

---

## 5. 路径的两套语义（最容易错的地方）

见 `sandbox-file/.../PathSemantics.kt` 与 `docs/api-reference.md` 的路径章节。

```
同一个字符串 "/data/data/com.example/app.bin"
 │
 ├── PathView.HOST    → 真实 Android 文件系统路径
 │                       零宽通道在这里生效，能穿透到别的 App 的 data
 │
 └── PathView.SANDBOX → PRoot rootfs 内部的 "/data/data/..."
                         实际落在 {filesDir}/sandbox/rootfs/data/data/...
                         宿主进程自己看不见 "/workspace"，除非经 PathResolver 换算
```

**关键结论**：`execute()` 里跑的 `cat /data/data/x` 走**沙箱视角**（被 PRoot 重写），
而 `readFile("/data/data/x", HOST)` 走**宿主视角**。两者能读到的范围不同，
结果也可能不同。所以 AIDL 里 `pathView` 是**必填**参数，没有默认值。

---

## 6. 双 rootfs 策略

```
                       ┌─────────────────────────┐
                       │  RootfsManager          │
                       │  （统一入口 / 状态机）   │
                       └───────────┬─────────────┘
                                   │
                 ┌─────────────────┴──────────────────┐
                 ▼                                    ▼
    ┌────────────────────────┐          ┌──────────────────────────┐
    │ installRootfs(ociRef)  │          │ useBundledRootfs()       │
    │ **可选升级**，按需下载  │          │ **默认主路径**，APK 内置  │
    │                        │          │                          │
    │ alpine:3.20 ~4MB       │          │ assets/rootfs-bundle     │
    │ → 拉 manifest/config   │          │   .tar.gz (Alpine 3.8MB) │
    │ → 逐层 sha256 校验      │          │ → 解包到 rootfs/         │
    │ → tar 流式解包(whiteout)│          │ 只有 busybox，零网络依赖  │
    └────────────────────────┘          └──────────────────────────┘
```

**优先级**：内置是主路径（离线、秒级、开箱即用），OCI 是"想要更强工具链时"的
可选升级。**没有网络时沙箱依然能跑**（能执行、能读写、能快照回滚）。

> ⚠️ 「能跑」≠「什么都有」：内置 Alpine 只有 busybox，
> **没有 `gcc`/`aapt2`/`zip`/`python3`/`git`/`java`**（真机实测）。
> 需要这些工具时走 OCI、或联网 `apk add`、或由宿主 bind 进来。
> 详见 README 的「内置 rootfs 到底有什么」。

`useBundledRootfs()` 在 assets 缺失时**必须优雅失败**并返回
`CODE_ROOTFS_NOT_READY`，不得崩溃 —— 让宿主能给出「请联网安装」的提示。

---

## 7. 模块依赖图（编译期，无环）

```
        sandbox-app
       ╱     │     ╲
      ╱      │      ╲
channel   file    runtime
    │       │        │
    └───────┴────────┴──> sandbox-api
```

`file` 依赖 `runtime` 是因为 `PathSemantics` 需要 `PathResolver` 做视角换算。
`channel` 与 `file` 之间**没有**依赖 —— 它们只通过 `sandbox-api` 的数据类型交流。
