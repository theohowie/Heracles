# 通道能力矩阵

四个通道：**普通 App / Shizuku / Root / 无线 ADB**。
本文件回答三个问题：**能做什么 / 前置条件 / 风险等级**。

> ⚠️ **本文件只描述"事实"，不描述"策略"。**
> 沙箱报告某个通道风险 HIGH，**不代表**沙箱拒绝用它。
> 是否放行、是否每次确认，由**宿主的信任策略**决定。
> 把策略硬编码进沙箱，沙箱就无法被其他项目复用 —— 这是架构底线。

---

## 真机验证状态（2026-10-28）

设备：Android 17 / SDK 37 / arm64-v8a。下面 `available` 与 `reason` 是**通道自己算出来的原样输出**。

| 通道 | 真机 available | reason（原样） | 缺什么 |
|---|---|---|---|
| NORMAL | **true** | — | 无 |
| SHIZUKU | false | `Shizuku 未授权本应用：到权限步骤申请 Shizuku 授权` | 用户启动 Shizuku 并授权 |
| ROOT | false | `设备没有 su：需解锁 bootloader 并刷入 Magisk / KernelSU / APatch` | 设备无 root（物理不可测） |
| WIRELESS_ADB | false | `未找到 adb 可执行文件：需要一个可用的 adb 客户端（Termux 的 android-tools / rootfs 里的 platform-tools / 宿主自带的 arm64 静态 adb），或用环境变量 HERACLES_ADB 指定` | 宿主侧可 exec 的 adb + 用户 `adb pair` |

> ⚠️ **这三条 false 是如实上报，不是缺陷。** 单测覆盖了选路与配对状态机
> （`ChannelSelectorTest` 18 条 / `AdbPairingStateMachineTest` 22 条 / `ShizukuIsolationTest` 9 条），
> 但**「真机上能跑」这件事目前没有证据** —— 对外只说「已实现，真机未验证」。

---

## 总览

| | NORMAL | SHIZUKU | ROOT | WIRELESS_ADB |
|---|---|---|---|---|
| **执行身份** | `u0_aXXX`（本 App） | `shell`（uid 2000） | `root`（uid 0） | `shell`（uid 2000，经 adb） |
| **风险等级** | **LOW** | **MEDIUM** | **HIGH** | **MEDIUM–HIGH** |
| **前置条件** | 无 | 装 Shizuku + 授权 | 设备已 root + superuser 授权 | 开发者选项开「无线调试」+ 已 `adb pair` |
| **永远可用** | ✅ | ❌ | ❌ | ❌ |
| **需要网络** | ❌ | ❌ | ❌ | ✅（本地回环/局域网） |
| **需要用户交互** | ❌ | ✅ 一次授权 | ✅ 每次或记住 | ✅ **每次配对** |

---

## 1. NORMAL —— 普通 App 通道

**为什么存在**：装完就能用，零前置条件。这是沙箱的**兜底通道**，
其它三条通道全部不可用时，它必须仍然工作。

### 能做什么

| 能力 | 说明 |
|---|---|
| ✅ 在 PRoot rootfs 内跑任意 Linux 命令 | **但只有 rootfs 里装了的才有**：内置 Alpine 仅 busybox（`sh` `ls` `cp` `tar` `grep`…）。`apt`/`gcc`/`aapt2`/`python` **默认都没有**，需 `apk add` 或在 rootfs 内装套件（见 README「构建工具装在 rootfs 里」） |
| ✅ 读写本 App 沙箱内的一切 | `{filesDir}` / `{cacheDir}` / PRoot rootfs |
| ✅ 读写外部存储中本 App 可访问的部分 | `/sdcard/Android/data/<本App>`、共享媒体目录 |
| ✅ 零宽通道穿透（**条件性**） | 见下节。只在 ROM 有该缺陷时生效 |
| ✅ 网络访问（受 App 的 INTERNET 权限约束） | |
| ✅ PTY 语义 | `fork + setsid + TIOCSCTTY`，真实终端 |

### 不能做什么

| 不能 | 原因 |
|---|---|
| ❌ 读 `/data/data/<别的App>/` | SELinux + DAC。**零宽通道也做不到**（它只影响 `/sdcard/Android/{data,obb}`） |
| ❌ 写 `/system` `/vendor` | 只读分区 + 权限 |
| ❌ `pm install` 静默装包 / `pm uninstall` | 需要 `INSTALL_PACKAGES`（系统权限） |
| ❌ `am force-stop` 别的 App | 需要 `FORCE_STOP_PACKAGES` |
| ❌ `screencap` / `uiautomator dump` | 需要 shell 身份（`READ_FRAME_BUFFER` / 无障碍） |
| ❌ 真实 root（`-0` 只是假象） | PRoot 的 `-0` 只让 `getuid()` 返回 0 |

### 零宽通道（NORMAL 的子能力）

**它做什么**：对 `/storage/emulated/0/Android/{data,obb}` 尝试多组路径变换
（原路径、追加 `/.`、`/Android/`→`//Android/`、插入 U+200B 等），
逐个实测 `File(p).list() != null`，命中哪个用哪个。

**边界（必须如实告知用户）**：
- ✅ 只影响 `/sdcard/Android/{data,obb}`
- ❌ 读不到 `/data/data/<pkg>`（真私有目录，要 root/Shizuku）
- ❌ 绕不过 SELinux
- ⚠️ 只在**未打补丁**的 ROM 上生效；补丁后**自动降级**，不会崩也不会假装可用
- ⚠️ 属于 CVE-2024-43093 一类 ROM 缺陷。它是**设备所有者对自己设备**的
  操作工具，不是越权工具

---

## 2. SHIZUKU —— Shizuku 通道

**为什么存在**：让没 root 的设备也能拿到 `shell` 身份（uid 2000），
从而做 `pm` / `am` / `screencap` / `uiautomator dump` 这些普通 App 做不了的事。

### 能做什么

| 能力 | 说明 |
|---|---|
| ✅ 以 `shell` 身份执行任意命令 | 通过 Shizuku 的 Binder 用户服务 |
| ✅ `pm install` / `pm uninstall` | shell 有这个权限（会弹系统确认） |
| ✅ `am start` / `am force-stop` 别的 App | shell 权限 |
| ✅ `settings put` 部分系统设置 | 视设置项而定 |
| ✅ `screencap` 截屏 | shell 有 `READ_FRAME_BUFFER` |
| ✅ `uiautomator dump` | 需要 shell |
| ✅ 读 `/data/local/tmp` | shell 自己的目录 |
| ✅ 深读部分 App 的 data | 仅 shell 本身可读的部分（不是全部） |

### 不能做什么

| 不能 | 原因 |
|---|---|
| ❌ 真实 root（uid 0） | **shell ≠ root**。这是最常被误解的一点 |
| ❌ 写 `/system` `/vendor` | 只读分区 |
| ❌ 读任意 App 的私有 data | SELinux 对 shell 域也有约束 |
| ❌ 绕过 SELinux | |

### 前置条件与降级

- **必需**：设备安装 Shizuku（`moe.shizuku.privileged.api`）并授权本 App
- **探测方式**：`compileOnly` 依赖 + **运行期反射/隔离类加载**探测服务是否可用
- **降级路径**：未安装 / 未授权 / 服务未启动 ⇒ `available=false`，
  `missingPrerequisites` 给出可展示的说明，**NORMAL 通道不受影响**
  （这正是 Shizuku 必须 `compileOnly` 的原因：硬绑定会让没装 Shizuku 的设备在
  类加载阶段就崩，把普通模式连坐）

### 敏感点：`force-stop`

⚠️ Shizuku/ADB 通道**能** force-stop 别人的 App。这在某些场景（清后台）是用户想要的，
但也可能打断用户正在用的应用（历史上出过"force-stop 了用户监控 App"的事故）。

**沙箱不做判断** —— 沙箱照做，并在 `ChannelInfo.riskLevel = MEDIUM` 里如实标注。
**宿主应该**决定是否对 `am force-stop` 这类命令单独加确认。

---

## 3. ROOT —— Root 通道

**为什么存在**：设备已 root 时，提供真正的 uid 0 执行能力。

### 能做什么

| 能力 | 说明 |
|---|---|
| ✅ 一切 | 读写 `/system` `/data`、静默装包、改全局设置、加载内核模块… |
| ✅ 读任意 App 私有 data | 真正绕过 DAC |
| ✅ 挂载 / 卸载 | |

### 不能做什么

- 在**未 root** 的设备上什么都不做（`available=false`，优雅降级）
- 绕过硬件的 verified boot（那是 bootloader 层的事）

### 前置条件与降级

- **必需**：设备已 root（`su` 二进制存在）+ 已授予本 App superuser 权限
- **探测方式**：`su -c id` 并检查输出是否含 `uid=0`
- **降级路径**：无 `su` / 被拒绝 / 超时 ⇒ `available=false`，
  `missingPrerequisites` 说明「设备未 root 或未授予 superuser」
- **注意**：部分 root 方案（如 KernelSU 的某些配置）对 `su -c` 有交互确认，
  探测时可能阻塞 —— **必须带超时**

### 风险：HIGH

`HIGH` 的判定依据：**能毁掉整机**（写错分区、删系统文件、改 SELinux 策略）。
宿主对 ROOT 通道的默认策略**应该**是「每次确认」，尤其当命令来自模型生成时。

---

## 4. WIRELESS_ADB —— 无线 ADB 通道

**为什么存在**：不依赖 Shizuku App，直接走 Android 自带的无线调试（
`adb pair` + `adb connect`）。在没有 Shizuku 但用户愿意开无线调试时，
这是拿到 `shell` 身份的唯一路径。

### 能做什么

与 SHIZUKU **基本相同**（都是 shell 身份）：`pm`、`am`、`screencap`、
`uiautomator dump`、`settings`…

### 不能做什么

| 不能 | 原因 |
|---|---|
| ❌ 真实 root | **shell ≠ root**，同 Shizuku |
| ❌ 自动开启无线调试 | 那是用户交互，沙箱不、也不能代劳 |
| ❌ 绕过 SELinux | |

### 前置条件（三件套，缺一不可）

1. **用户手动**在开发者选项里打开「无线调试」
2. **用户手动**完成一次 `adb pair <ip>:<pairPort> <6位配对码>`
   （配对码只能由用户从设备屏幕读出并输入）
3. 端口可达：`adb connect <ip>:<connectPort>` 成功

### 配对状态机

`AdbPairingStateMachine` 把上面第 2 步抽成**可单测的纯状态机**：

```
DISCONNECTED
   ↓ detect(无线调试已开启)
PAIRING_PORT_PROBE     ← mDNS 发现 _adb-tls-pairing._tcp
   ↓ 拿到 pair 端口
AUTH_HANDSHAKE         ← 用户输入 6 位配对码，TLS 密钥交换
   ↓ 配对成功
CONNECTING             ← adb connect <ip>:<connectPort>
   ↓
CONNECTED
```

任一步失败 → `FAILED(reason)`，可重试。

**风险：MEDIUM–HIGH**。判 HIGH 的理由：
- **开启无线调试本身降低设备安全性**（局域网内可连）
- 配对密钥持久化在设备上
- 端口会轮换，但一旦配对成功，同一网络内的连接是长期有效的

判 MEDIUM 的理由：毕竟只是 shell，不是 root。

**宿主的合理策略**：把「开启无线调试」这一步的**告知**做足，
并在配对完成后提示用户可以在不用时关闭无线调试。

---

## 5. 选路优先级（`ChannelSelector` 的默认逻辑）

移植自 baicodex 的三档模型，加了第四通道。**默认优先级**：

```
若宿主显式指定 channelType → 用它（不可用则报 CODE_CHANNEL_UNAVAILABLE，不静默改道）

否则自动选路：
  1. 目标能力只需要普通文件/命令  →  NORMAL     （最小权限原则）
  2. 目标需要 shell 能力          →  SHIZUKU 或 WIRELESS_ADB（谁可用用谁，Shizuku 优先）
  3. 目标需要 root               →  ROOT
  4. 全都不行                     →  CODE_NO_CHANNEL
```

**关键设计**：**能降级就降级**。需要 shell 但 Shizuku 不可用时，
先试 WIRELESS_ADB，再不行才报错 —— 但**绝不**自动升级到 ROOT
（那是提权，必须显式请求）。

> ⚠️ `ChannelSelector` 只产出**建议**。宿主可以完全无视它，
> 自己在 `ChannelInfo` 上做决策 —— 这正是「沙箱不做决策」的体现。

---

## 6. 快速对照：我想做 X，该用哪条通道？

| 我想… | NORMAL | SHIZUKU | ROOT | ADB |
|---|---|---|---|---|
| 在 Linux 里跑 `gcc` / `apt` | ✅ | ✅ | ✅ | ✅ |
| 生成 / 重打包 APK（`aapt2`、`apktool`） | ✅ | ✅ | ✅ | ✅ |
| 读本 App 的 cache | ✅ | ✅ | ✅ | ✅ |
| 读 `/sdcard/Android/data/<别的App>` | ⚠️ 看 ROM | ✅ | ✅ | ✅ |
| 读 `/data/data/<别的App>` | ❌ | ⚠️ 部分 | ✅ | ⚠️ 部分 |
| `pm install` 一个 APK | ❌ | ✅ | ✅ | ✅ |
| 截屏（`screencap`） | ❌ | ✅ | ✅ | ✅ |
| `uiautomator dump` | ❌ | ✅ | ✅ | ✅ |
| 写 `/system/...` | ❌ | ❌ | ✅ | ❌ |
| 改 SELinux 策略 | ❌ | ❌ | ✅ | ❌ |
| 完全离线可用 | ✅ | ✅ | ✅ | ❌ 需配对 |

---

## 7. 三条"不要误解"的提醒

1. **Shizuku ≠ Root，ADB ≠ Root。** 两者都只是 `shell`（uid 2000）。
   它们能做的事比普通 App 多得多，但比 root 少得多。
2. **PRoot 的 `-0` ≠ root。** 它只让 `getuid()` 返回 0，内核检查仍按真实 uid。
   详见 `docs/security-boundary.md`。
3. **风险等级不是使用建议。** 它是**事实描述**。要不要用、要不要确认，
   由宿主的信任策略决定 —— 沙箱刻意不参与。
