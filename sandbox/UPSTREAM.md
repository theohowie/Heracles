# 上游基线与移植来源

本文件是 Heracles-taixu-sandbox 的**上游对照表**。taixu 是持续跟踪的基线；
baicodex 与 tianxuan 是**一次性移植源**（移植当时的 commit 快照，不持续跟踪）。

> 记录时间：2026-10-27
> 记录人：Heracles 沙箱子系统

---

## 0. 任务书给出的 URL 与实际的差异（重要）

任务书给出的三个仓库地址**全部 404**，实际可用地址是下面这一组。
按任务书 §三 的要求「若链接失效，请通过 GitHub 搜索项目名定位正确仓库」，
以下为定位结果，**这是本工程实际使用的坐标**。

| 任务书给出的地址 | 实际状态 | 实际使用的仓库 |
|---|---|---|
| `https://github.com/tianxuan2026/taixu` | 404 Not Found | **`https://github.com/wkbin/taixu`** |
| `https://github.com/baicodex/baicodex` | 404 Not Found | **`https://github.com/mubai0122/baicodex`** |
| `https://github.com/tianxuan2026/tianxuan` | 404 Not Found | **`https://github.com/xiaozhe7772222/tianxuan`** |

定位方法：GitHub Search API 按项目名检索 + 描述匹配。

- `taixu` → `wkbin/taixu`（161 stars，Kotlin，描述 "Android No-Root Linux Runtime ·
  Native Agent Harness · PTY Terminal · Workspace & Tool Ecosystem"，与任务书的
  「PRoot / PTY / runtime」描述完全吻合）
- `baicodex` → `mubai0122/baicodex`（描述明写「三档执行权限」「零宽文件通道」
  「Linux 沙箱」，与任务书的移植目标逐条对应）
- `tianxuan` → `xiaozhe7772222/tianxuan`（描述 "天玄 TaiXuan — 无 Root Android 上的
  PRoot Linux 沙箱与 AI Agent Harness"，是 `wkbin/taixu` 的同一作者的姐妹项目，
  含任务书要求的无线 ADB 通道）

> ⚠️ **命名坑**：搜 `tianxuan` 最热的 `TianXuan-Chain/tianxuan` 是区块链项目，
> 与任务书无关。`xiaozhe7772222/tianxuan` 才是 Kotlin/Android 的那个。

---

## 1. taixu（基底 —— **持续跟踪的上游**）

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/wkbin/taixu |
| 基线 commit | `dc7fcddb88e565929379597bbd811b440d00e34f` |
| commit 日期 | 2026-10-26T02:48:26Z |
| 默认分支 | `main` |
| 协议 | GPL-3.0 |
| 版权 | Copyright (C) 2026 王克斌 |
| 总文件数 | 3419（GitHub tree API，未截断） |
| runtime/ 源文件 | 155 个 Kotlin 文件 + 1 个 AIDL + cpp |

### 从 taixu 移植的模块

| 上游路径 | 沙箱落点 | 说明 |
|---|---|---|
| `runtime/src/main/java/top/wkbin/taixu/runtime/proot/` | `sandbox-runtime/…/ProotEngine.kt` 等 | PRoot 命令行构造、挂载布局、安装器 |
| `runtime/src/main/java/top/wkbin/taixu/runtime/pty/` | `sandbox-runtime/…/PtySession.kt` | PTY 会话管理、增量 UTF-8 解码 |
| `app/src/main/cpp/pty_native.c` | `sandbox-runtime/src/main/cpp/pty_bridge.cpp` | `openpty + fork + setsid + TIOCSCTTY` JNI |
| `app/src/main/cpp/CMakeLists.txt` | `sandbox-runtime/src/main/cpp/CMakeLists.txt` | NDK 构建脚本 |
| `runtime/src/main/java/top/wkbin/taixu/runtime/shell/` | `sandbox-runtime/…/ProcessRegistry.kt` | 前台有界命令 vs 持久进程 |
| `runtime/src/main/java/top/wkbin/taixu/runtime/rootfs/` | `sandbox-runtime/…/OciRootfsInstaller.kt` 等 | OCI 拉取、层校验、tar 流式解包 |
| `runtime/src/main/java/top/wkbin/taixu/runtime/WorkspaceManager.kt` | `sandbox-runtime/…/WorkspaceManager.kt` | 工作区与快照 |

### 明确**不移植**的 taixu 模块

`harness/`、`feature/`、`project-template/`、`tools/`、`app/`（Compose UI）、
`core/database`（Room）、`core/network`、`showerclient/`、`webchat/`、
`virtualdisplay/`、`gui/`（无障碍）、`ftp/`、`remote/`（SSH）、`LocalLlmManager`。

理由：这些属于 Heracles 的**控制面**（决策 / UI / 工作流），沙箱只承担**执行面**。

### 耦合深度实测（Phase 0 结论）

- `runtime/` 共 **155** 个 Kotlin 文件，其中 **56 个**（36%）`import top.wkbin.taixu.core.*`
- 高频耦合点：`AppLogger`(18 处)、`AppResult`(14)、`ShellQuote`(10)、
  `ErrorCode`(9)、`RuntimeState`(9)、`AppError`(9)、`RuntimePreferences`(7)
- 另有 Room DAO（`WorkspaceRepository`、`TerminalSessionRepository`…）与
  DataStore（`RuntimePreferences`、`SshPreferences`…）直接注入

⇒ **结论：耦合过深，不能原样搬。** 详见 `docs/porting-log.md` 与
`sandbox-runtime/…/SandboxDependencies.kt` 里的适配层设计。

---

## 2. baicodex（移植源 —— **一次性快照，不持续跟踪**）

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/mubai0122/baicodex |
| 移植基线 commit | `fb4bd5f98bb8541ab0dcf83fb3b1ee29e6cb9d95` |
| commit 日期 | 2026-10-27T00:05:53Z |
| 默认分支 | `main` |
| 协议 | GPL-3.0 |
| 总文件数 | 244 |

### 移植的模块

| 上游路径 | 沙箱落点 | 移植内容 |
|---|---|---|
| `app/src/main/kotlin/b/ai/exec/Router.kt` | `sandbox-channel/…/ChannelSelector.kt` | 三档选路决策（**只取决策结果，不含 UI**） |
| `app/src/main/kotlin/b/ai/core/Perms.kt` | `sandbox-channel/…/ChannelManager.kt` | 权限状态数据结构 |
| `app/src/main/kotlin/b/ai/exec/Shiz.kt`、`ShizukuShell.kt` | `sandbox-channel/…/shizuku/ShizukuChannel.kt` | Shizuku 通道 |
| `app/src/main/kotlin/b/ai/exec/Root.kt` | `sandbox-channel/…/root/RootChannel.kt` | Root 通道 |
| `app/src/main/kotlin/b/ai/exec/FileOps.kt` | `sandbox-file/…/ZeroWidthFileChannel.kt` | 零宽文件通道 + 路径变换 |
| `app/src/main/kotlin/b/ai/exec/Workspace.kt` | `sandbox-file/…/PathSemantics.kt` | 路径语义（**被重写并显式化**） |

### 明确**不移植**

- 全部 Compose UI：`ui/AskSheet.kt`、`ui/PermUi.kt`、`ui/PermAskUi.kt`、
  `ui/DialogHost.kt`、`ui/ChatScreen.kt`（88KB）等 —— **一行不搬**
- Agent 循环：`agent/Agent.kt`（62KB）、`agent/Tools.kt`（53KB）
- 无障碍：`exec/A11y.kt`、`exec/AutoA11y.kt`、`ui/A11y*Ui.kt`
- 全家桶式的 `core/*`（Cfg/Pet/Skill/Memory/…）

### 关于「零宽文件通道」的如实说明

上游实现（`Router.kt` 27–34 行）的做法是：对 `/storage/emulated/0/Android/data`
（及其 `obb`）路径做**多候选路径变换**，逐个实测 `File(p).list() != null` 是否成立，
命中哪个就用哪个。候选包括原路径、追加 `/.`、`/Android/` → `//Android/`、
插入 U+200B 零宽空格等。

上游注释自己写明这属于 `CVE-2024-43093` 一类问题，且**不同 ROM 行为不一致**，
所以不按版本猜测而是逐个实测。

**沙箱移植时的态度（必须保留这段）**：
1. 只做「逐项实测 + 命中即用」，**不做任何版本指纹猜测**；
2. 能力边界在 `docs/security-boundary.md` 里写清：它只影响
   `/storage/emulated/0/Android/{data,obb}`，**读不到** `/data/data/<pkg>`
   （那需要 root/Shizuku），也**绕不过 SELinux**；
3. 它是**设备所有者对自己设备**的操作工具，不是越权提权工具；
   宿主若要用于他人设备或非自有意愿的场景，由宿主自己承担合规责任。
4. 上游若修复此题（ROM 打补丁），本通道会**自动失效并优雅降级**，
   不会 crash、不会假装可用。

---

## 3. tianxuan（移植源 —— **一次性快照，不持续跟踪**）

| 项 | 值 |
|---|---|
| 仓库 | https://github.com/xiaozhe7772222/tianxuan |
| 移植基线 commit | `caad40090a4f2c2edbe54e6eaae60a3dd1de7d21` |
| commit 日期 | 2026-10-26T08:35:46Z |
| 默认分支 | `main` |
| 协议 | GPL-3.0 |
| 版权 | Copyright (C) 2026 王克斌 |
| 总文件数 | 1618 |

### 移植的模块

| 上游路径 | 沙箱落点 | 移植内容 |
|---|---|---|
| `app/src/main/java/top/wkbin/tianxuan/service/adb/AdbNotificationManager.kt` | `sandbox-channel/…/adb/WirelessAdbChannel.kt` | 无线 ADB 连接与通知 |
| `app/src/main/java/top/wkbin/tianxuan/service/adb/AdbNotificationReceiver.kt` | `sandbox-channel/…/adb/AdbPairingStateMachine.kt` | 配对流程（**抽成独立状态机**） |
| `runtime/src/main/java/top/wkbin/tianxuan/runtime/bridge/adb/EmbeddedAdbManager.kt` | `sandbox-channel/…/adb/` | 内嵌 adb 连接管理 |
| `app/src/main/assets/bin/adb` | 参考（理解连接方式） | adb shell wrapper |

### 明确**不移植（硬约束）**

- **无障碍（Accessibility）通道：一行都不搬。**
  理由：无障碍权限在开源分发与 Play Store 审查中风险过高（可读全屏内容、
  可模拟任意点击）。若宿主需要 GUI 自动化，由**宿主自行**申请无障碍权限；
  沙箱只提供「已授权通道」的调用接口。
- `harness/`、`feature/`、`project-template/`、`webchat/`、`showerclient/`
- 与 taixu 重复的 `runtime/`（taixu 是基线，冲突时以 taixu 为准）

---

## 4. 协议兼容性

三个上游均为 **GPL-3.0**，Heracles 本体也是 **GPL-3.0**。本沙箱
**继承 GPL-3.0**（见 `LICENSE` 全文 35149 B，与 FSF 官方
`https://www.gnu.org/licenses/gpl-3.0.txt` 的 SHA-256 逐字节一致：
`3972DC9744F6499F0F9B2DBF76696F2AE7AD8AF9B23DDE66D6AF86C9DFB36986`）。

因为上游是 GPL-3.0（强 copyleft），本工程**只能**以 GPL-3.0 分发，
不能改成 MIT/Apache —— 这一点在 `NOTICE` 里也写明了。

---

## 5. taixu 的 rebase 流程（供后续维护者）

taixu 是持续跟踪的基线。上游更新后：

```bash
# 1. 记录旧基线（本文件第 1 节的 commit）
git -C <taixu-clone> log --oneline dc7fcddb..origin/main -- runtime/ app/src/main/cpp/

# 2. 逐个评估改动是否需要跟进到 sandbox-runtime
#    重点关注：proot/、pty/、shell/、rootfs/、app/src/main/cpp/

# 3. 跟进完成后更新本文件第 1 节的 commit hash
#    并在 docs/porting-log.md 追加一条 rebase 记录
```

**不要**直接 `git merge` taixu —— 本工程是「剥离后的产物」，
文件路径与包名都已重构（`com.heracles.sandbox.*`），merge 只会产生海量冲突。
正确做法是**按模块手工搬运 + 适配层隔离**。

baicodex / tianxuan **不需要**做这种跟踪：它们是一次性移植源，
记录 commit 只为「将来想复查某段逻辑的出处」。若上游未来修复了零宽通道，
沙箱这边**只按功能降级**处理，不追 commit。
