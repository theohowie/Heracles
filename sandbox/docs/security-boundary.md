# 安全边界：PRoot **不是**安全沙箱

> ## ⚠️ 必读结论
>
> **PRoot 不提供 namespace / cgroup / seccomp，不是敌对代码隔离。**
> 它解决的是**文件系统污染**和**崩溃恢复**，不是**安全隔离**。
>
> 如果你需要跑不信任的代码、需要防止提权、需要限制资源占用 ——
> **PRoot 给不了你这些**。请用 Android 的 isolatedProcess、
> 虚拟化（pKVM / AVF）、或真正的容器运行时。

这句话是硬要求：**不能省、不能弱化、不能被"沙箱"这个名字带偏**。
本项目叫 "sandbox" 是**文件系统意义的沙箱**（一个独立根文件系统的执行环境），
不是**安全意义的沙箱**（隔离不受信任代码的边界）。

---

## 1. PRoot 到底做了什么

PRoot 通过 **ptrace** 拦截 tracee（被跟踪进程）的系统调用，对**路径参数**
做重写，把 `/workspace/x` 映射到 `<rootfs>/workspace/x`。
它还给 tracee 一个假想的「root 身份」（`-0` 只改 view，不是真提权）。

所以 PRoot 能做到：

- ✅ **文件系统隔离（伪）**：进程看到的 `/` 是一个目录树，`rm -rf /` 只会毁掉这个目录树
- ✅ **崩溃恢复**：rootfs 是普通目录，快照/重置就是 `cp -a` / `rm -rf`
- ✅ **可移植**：同一份 rootfs 能在任何 arm64 Android 上跑
- ✅ **能在里面装/跑 Linux 工具**：前提是**那个 rootfs 里有这些工具**，或者你能联网装

> ⚠️ **修正一条曾经的错话**（2026-10-27）：本文件早先写过
> 「`apt`、`gcc`、`aapt2` 都能跑」。**这句话是错的**，已实测核实：
>
> ```
> $ run-as … sh -c 'command -v aapt2 || echo NONE'
> NONE
> $ … command -v gcc   → NONE
> $ … command -v apt   → NONE（内置 Alpine 用的是 apk，不是 apt）
> ```
>
> PRoot 本身**不提供任何工具**，它只是一个文件系统视图。内置的是
> **Alpine minirootfs（3.8 MB，只有 busybox）**，里面没有 `gcc`/`aapt2`/`apt`/`python3`/`git`。
> 「能跑」和「有得跑」是两件事 —— 把这两者混为一谈就是虚假宣传。
>
> Android 构建工具（`aapt2`/`apksigner`）与 JDK 需要**另外提供**：
> 要么联网 `apk add`（内置 Alpine 有 `apk`），要么由宿主 bind 进来。
> 见 `docs/channel-matrix.md` 与 README 的「内置 rootfs 有什么」一节。

PRoot **做不到**：

- ❌ **不能限制系统调用**：tracee 可以调 `ptrace`、`mount`（在自己的用户命名空间外会失败但会尝试）、
  `ioctl`、任意 `socket` —— 没有 seccomp 过滤器
- ❌ **不能限制资源**：没有 cgroup。一个 fork 炸弹会拖垮整机（沙箱侧有**软性**并发限制，
  但那只是应用层计数，不是内核强制）
- ❌ **不是真正的 namespace**：文件系统 view 是**用户态欺骗**，
  `/proc` 里的内容、`getpid()`、设备节点都是真实的
- ❌ **不能阻止提权**：`-0` 给的假 root 只是 `getuid()` 返回 0，
  任何内核强制的检查仍按真实 uid 走
- ❌ **不能隔离网络**：tracee 与宿主共享网络栈
- ❌ **不能防范恶意代码读取宿主可读的一切**：JNI 层虽然做了 `close_range(3, ~0)`
  防止 fd 泄漏，但 tracee 仍能用 `open()` 打开宿主进程有权限读的任何路径 ——
  PRoot 的路径重写是**可以绕过的**（如通过 `/proc/self/fd`、硬链接、
  或直接对已打开的目录 fd 用 `openat`）

> **2026-10-30 边界加固（ADR-041）**：宿主系统目录（`/proc /sys /system /system_ext
> /vendor /product /odm /apex /data/app /data/dalvik-cache` 等）**已不再 bind**，
> 只保留 `/dev`、`/dev/pts`；guest 的 `/proc`、`/sys` 是 rootfs 内的**空目录**
> （不再是宿主伪文件系统）；环境变量走 `HOST_ALLOWED_ENV_KEYS` 白名单 +
> `hostEnvironment()` 末尾 `check` 兜底；PRoot 带 `--kill-on-exit`。
> 真机实测（App 进程内）：读 `/data/data/<pkg>/files/...`、`shared_prefs`、
> `sessions/*.jsonl`、`memory/*.jsonl`、`/proc/self/root/...`、`..` 穿越 **全部
> `No such file`**；`ls /` 只有 rootfs 目录 + 沙箱挂载点。
> **但边界本质不变**：没有 seccomp（PRoot 靠 ptrace 工作，外部预装过滤器会连
> proot 自己的 ptrace 一起禁掉）、没有 namespace/cgroup、网络与宿主共享、
> `/dev` 与显式挂载由宿主决定 ⇒ **仍然不是强隔离，不得宣称内核级隔离**。
> 可得结论只到：「本 App 可读的宿主私有数据不再被默认暴露给沙箱」。详见
> `.docs/09-决策记录.md` ADR-041、`.docs/实测-20-沙箱边界.md`。

---

## 2. 那么它能防什么、不能防什么（决策表）

| 场景 | PRoot 能不能防 | 说明 |
|---|---|---|
| 用户手滑 `rm -rf /` | ✅ 能 | 只毁掉 rootfs 目录，宿主无事 |
| 构建脚本污染系统 | ✅ 能 | 装的东西都在 rootfs 里 |
| 装错依赖导致环境坏掉 | ✅ 能 | `resetRootfs()` 一键恢复 |
| 不同项目依赖冲突 | ✅ 能 | 不同 rootfs 互不干扰 |
| **模型幻觉写出的破坏性命令** | ⚠️ **部分** | 毁不了宿主系统，但**能毁宿主 App 可写的所有文件**（含 `/sdcard`） |
| **不受信任的第三方脚本恶意读宿主数据** | ⚠️ **部分（2026-10-30 加固后）** | 宿主系统目录已不 bind、guest `/proc`/`/sys` 为空目录、读宿主私有路径实测全 `No such file`；但**仍无 seccomp/namespace/cgroup**，App 自身可读的文件（含显式挂载）、网络、CPU/内存资源仍暴露 —— 不是强隔离（ADR-041） |
| **fork 炸弹 / 内存耗尽** | ❌ **不能** | 无 cgroup，只有应用层软限制 |
| **提权到真实 root** | ❌ 不能（这是好事） | 假 root 不改变内核判定 |
| **提权到 shell（uid 2000）** | ❌ 不能 | 需要 Shizuku/ADB 通道 |
| **跨 App 读私有数据** | ❌ 不能 | 受 SELinux 与 DAC 限制 |

**核心判断**：PRoot 的价值是**「随便折腾，坏了能一键回到干净状态」**，
不是**「跑恶意代码不会出事」**。这两件事必须分开讲，否则开源后一定被误用。

---

## 3. 四条通道各自的真实边界

| 通道 | 执行身份 | 能做什么 | **不能**做什么 | 风险 |
|---|---|---|---|---|
| **NORMAL** | `u0_aXXX`（本 App） | 读写本 App 沙箱内一切；PRoot 内跑 Linux；写 `/sdcard` 自己的部分 | 读别的 App 私有 data；写 `/system`；`pm install` 静默装包 | LOW |
| **SHIZUKU** | `shell`（uid 2000） | 通过 Shizuku 以 shell 身份执行；`pm`、`am`、`settings`、`screencap`、`uiautomator dump` | **不是 root**；不能写 `/system`；不能读别的 App data（除 shell 本身可读的） | MEDIUM |
| **ROOT** | `root`（uid 0） | 几乎一切 | — | HIGH |
| **WIRELESS_ADB** | `shell`（uid 2000，经 adb） | 同 Shizuku，但走网络自调试端口；不依赖 Shizuku App | **不是 root**；需每次配对；端口会轮换；**开启无线调试本身降低设备安全性** | MEDIUM–HIGH |

三条必须说清的事实：

1. **Shizuku 和 ADB 都只是 shell，不是 root。** 它们能做的事远少于 root，
   但远多于普通 App。宿主不应把它们当 root 用。
2. **无线 ADB 需要用户在开发者选项里开「无线调试」并手动配对。**
   沙箱不、也不能自动开启它 —— 那需要用户交互。
3. **沙箱不做权限决策。** 上表的「风险」只是**信息**，
   是否放行、是否每次确认，由宿主的信任策略决定。

---

## 4. 零宽文件通道的边界（必须如实说明）

「零宽文件通道」这个名字容易被误解。它的**实际行为**是：

对 `/storage/emulated/0/Android/{data,obb}` 这类被 Android 11+ 限制的路径，
尝试若干**路径变换**（原路径、`/.`、`//`、插入 U+200B 等），
逐个实测 `File(p).list() != null`，命中哪个就用哪个访问。

**能做**：在自己的设备上读 `/sdcard/Android/data/<别的App>/` 下的文件
（这属于 CVE-2024-43093 一类 ROM 缺陷）。

**不能做**：
- ❌ 读 `/data/data/<别的App>/`（那是真私有目录，要 root/Shizuku）
- ❌ 绕过 SELinux
- ❌ 在已打补丁的 ROM 上工作（会**优雅降级**，不会崩）

**合规立场**：
- 这是**设备所有者对自己设备**的操作工具，不是越权工具
- 上游若修复（ROM 打补丁），本通道**自动失效并降级**，不硬撑、不假装可用
- 宿主若把它用于**非自有意愿**的设备或场景（例如商业取证、他人设备），
  合规责任由宿主承担 —— 本沙箱不为此背书

---

## 5. 沙箱侧实际做了哪些**缓解**（不是安全保证）

虽然 PRoot 不是安全边界，沙箱仍做了这些工程上的缓解，请勿把它们当安全边界：

| 缓解 | 位置 | 说明 |
|---|---|---|
| **fd 泄漏收口** | `pty_bridge.cpp` `close_from(3)` | fork 后 exec 前 `close_range` 关掉继承的宿主 fd（SQLite、DataStore 密文、socket）。**这是缓解，不是隔离** —— tracee 仍能用 `open()` 打开宿主可读的路径 |
| **路径逃逸检查** | `PathResolver.sandboxToHost` | 拒绝 `..` 穿越出 rootfs |
| **前台命令并发上限** | `ProcessRegistry` | 应用层计数，防失控；**不是 cgroup** |
| **执行超时 + 进程组 SIGKILL** | `PtySession` / `ProcessRegistry` | 超时后 `kill(-pid)` 杀整个会话组 |
| **rootfs 层 sha256 校验** | `OciRootfsInstaller` | 防层被篡改；**不防恶意镜像**（恶意镜像里可以有恶意二进制） |
| **内置 rootfs 只用可信源** | `BundledRootfs` | 打包进 APK 的 rootfs 必须来自可信构建 |
| **宿主系统目录不 bind**（2026-10-30） | `ProotEngine.HOST_DEVICE_BINDINGS` | 只保留 `/dev`、`/dev/pts`；`/proc /sys /system /data/app ...` 不再暴露给 guest；纯函数 `hostDeviceBindsFor(exists)` 有单测锁住 |
| **环境变量白名单**（2026-10-30） | `ProotEngine.HOST_ALLOWED_ENV_KEYS` | PRoot 透传 environ ⇒ 白名单 + `check` 兜底，防止宿主敏感 env 泄漏 |
| **`--kill-on-exit`**（2026-10-30） | `ProotEngine.buildCommandLine` | 宿主进程退出时清掉 tracee |
| **`..` / 相对路径拒绝**（既有） | `PathResolver` / bind 校验 | 已由单测 + 真机越权用例锁住（ADR-041） |

**再次强调**：这些缓解的目标是「少出事故」，不是「防住攻击者」。
表里最后两条尤其容易被误读：sha256 校验只能证明「你拉到的层和你请求的层一致」，
**不能证明那个层是安全的**。

---

## 6. 给宿主的建议

如果你要把沙箱接进一个会跑**模型生成命令**的 Agent：

1. **在宿主侧做权限决策**。用 `ChannelInfo.riskLevel` 决定是否需要用户确认。
   `HIGH` 通道（ROOT）默认应该要求显式确认。
2. **把沙箱当"可回滚的工作区"用**，不要当"安全隔离"用。
   每次高风险操作前 `snapshotRootfs("before-x")`。
3. **不要让沙箱进程持有长期凭据**。API Key 不要放进会被 tracee 读到的环境变量。
4. **对 `writeFile(PathView.HOST)` 做路径白名单**。沙箱会照做，
   它不知道哪些宿主路径是敏感的 —— 那是宿主的职责。
5. **别指望 fork 炸弹保护**。需要真的资源限制，请用 Android 的
   `isolatedProcess` 或虚拟化方案。

---

## 7. 一句话总结

> PRoot 让「随便折腾」变得安全**可恢复**，但没有让「运行不受信任的代码」变得**安全**。
> 这两件事的区别，就是这个文件存在的理由。
