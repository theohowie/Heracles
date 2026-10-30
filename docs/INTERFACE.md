# Heracles 前端 ↔ 后端接口约定

> 版本 v1 · 2026-10-24 · 前端（`app/`）提出，后端（`backend/` + Kotlin 薄层）实现
> **后端回复（2026-10-24，kernel-refactor 分支）已逐条附在各条目末尾 —— 状态标记：✅ 已实现（含验收证据）／🔺 已实现但形状有偏差（见回复）／⬜ 未做（带计划）**

---

## 1. 通道总览

| 通道 | 方向 | 说明 |
|---|---|---|
| `AgentBridge.events`（`Stream<AgentEvent>`） | 后端 → 前端 | 运行事件流：轮次、流式增量、工具、计划、提问、缓存统计 |
| `AgentBridge.run / cancelRun / interruptRun` | 前端 → 后端 | 发起/取消/插队一次运行 |
| `AgentBridge.replyAsk / replyApproval` | 前端 → 后端 | 回答提问、答复审批（运行挂起等待） |
| `SessionStore`（会话与用量落盘） | 双向 | 会话列表、消息、每会话用量聚合 |
| Kotlin 薄层（MethodChannel） | 前端 → 设备 | Shizuku、无障碍、悬浮窗、文件授权等设备能力 |

## 2. 已有接口（前端已在用，后端保持兼容，不得改形状）

- `run(...)` → `AgentRunResult{stopReason, finalText, turns, taskWallMs, steadyHitRate}`
- `cancelRun()`、`interruptRun(text)`（插队）
- `replyAsk(Map<String, List<String>>)`、`replyApproval(String decision)`
- `alwaysAllowedTools()` / `clearAlwaysAllowed()` —— 「始终允许」名单（按工具名）
- `fetchModels(...)` / `fetchCapabilitiesOnly(...)` → 模型列表与 `ModelCapabilities`
- `listWorkspaces / listSessions / loadMessages / createSession / renameSession / deleteSession / toggleStar / toggleArchive`
- `contextLimitTokens({isCloud})`、`lastFrozenTokens()`
- `shizukuGrant() / shizukuForceRequest()`
- `AgentEvent` 字段（判别字段 `type`）：`turn_started / model_output / tool_started / tool_finished / blocked / finished / failed / step_started / reasoning_delta / step_delta / step_ended`，以及计划字段 `planSteps / doneCount / activeIndex / reachedGoal / planClosedReason`、提问字段 `questions`、缓存字段 `cache`（`EventCacheStats`）、压缩字段 `beforeTokens / afterTokens`、变更文件 `changeFiles`。

## 3. 设置项如何传给后端（映射表）

| 前端设置（`AppSettings`） | 传给后端的方式 | 备注 |
|---|---|---|
| `PermissionMode`（manual / workspace / full） | 每次 `run` 必须带入并**真实生效**（见 N1） | ~~现状：未映射进后端~~ **✅ 后端回复：已映射**（2026-10-24，`local_agent.dart` 显式传入 `RunOptions.approvalMode`，三档真实生效） |
| `ReasoningLevel`（auto / off / low / high / max） | wire 名 = 枚举名小写，**必须与 Kotlin 侧逐字符一致** | **✅ 后端回复：已接线**（`BackendConfig.reasoningEffort` → 框架 `ModelConfig.extra` → OpenAI 轨 `reasoning_effort`；⚠️ Anthropic/Responses 轨的 client 不读 extra，暂不生效 —— 如实记录） |
| 最大轮次 | 后端常量 `ContractAgent.maxTurns = 40` 为上限来源 | ✅ 一致（`kMaxTurnsOptions` 上限 80 是用户可选档；超出契约值的校验在后端 `RunOptions` 层，超限按契约值截断不报错） |
| `BusySendBehavior`（queue / interrupt） | 纯前端行为：排队 = 前端队列；插队 = 调 `interruptRun` | 后端无感知（注：`interruptRun` 今天恒返 false —— 框架无轮间注入挂载点，插队=停止+重发是当前唯一可用语义，前端勿依赖插队不中断） |
| `StepDetail`（精简 / 标准 / 详细 / 完全展开） | **纯前端渲染密度**，后端无感知 | ✅ 四档以枚举为准 |
| 界面语言 / 外观 / 字号 | 纯前端 | — |
| **流式输出** | **无开关**（产品决策 2026-10-24） | ✅ 后端保持 `step_delta / reasoning_delta` 增量事件 |

## 4. 新界面需要后端补的接口（逐条实现，带验收）

### N1 审批门禁真接线 —— ✅ 已实现（同日按本条形状对齐）

~~现状（审计 H1）：~~ 审计后已于 2026-10-24 接线，并按本条要求升级为契约形状：

- ✅ 框架 `beforeToolCall` 钩子（`_ApprovalHook`）拦截，`run` **挂起**等待答复（`AskGate.requestApproval` 内部 await completer）；
- ✅ 事件 **`approval_required`**（`AgentEvent.kApprovalRequired`），载荷 `callId`（=框架调用 id）/ `tool` / `args`（完整不截断）/ `reason`（=risk 一句话风险说明，另有 `message`=详细说明）/ `workspaceInside`（文件工具 true；shell/APK false —— 静态判不了或在工作区外）；
- ✅ 答复 **`replyApproval({callId, decision})`**，`decision ∈ {deny, once, always}`；`always` 写入 `alwaysAllowedTools`（SharedPreferences，跨启动）+ 本会话免问；callId 不匹配的迟到答复如实返回 false；
- ⚠️ **一处有意偏差**：`workspace` 档的判定不完全按 `workspaceInside` —— **破坏性三件套（delete/move/copy）与 shell/APK 无论 workspaceInside 都拦**（rm 在工作区内也是不可逆操作，删错找不回来）；工作区内放行的只有写/编辑/建目录。前端弹窗按收到的 `approval_required` 渲染即可，无需自行判定。如接受此偏差，本文档 N1 判定行请改；
- ✅ fail-closed：超时（**已采纳 5 分钟**，见 §7.1）或断开 → deny + 发 `blocked` 事件；
- 验收：`backend/test/approval_hook_test.dart`（8 条，含"拒绝后工具不执行、模型收到拒绝结果继续"）+ `app/test/ask_gate_approval_test.dart`（11 条，含 callId 配对/超时 deny+blocked 由实现保证）。

### N2 上下文分项统计 —— ✅ 已实现

- 新事件 **`context_updated`**（`AgentEvent.kContextUpdated`），每轮随 `HeraclesTurnUsage` 发一帧：`breakdown`（key→估算 token）+ `limit` + `limitSource`；
- **后端回复 §7.2：由 compressor 的估算器拆分**（`WindowRatioCompressor.estimateText/estimateMessageTokens` 静态入口，与压缩决策同一套 CJK 系数 —— 口径稳定，同一会话内方法不跳变）；
- 固定 7 键全部给出：`system / toolDefs / toolResults / reasoning / assistant / user / summary`。⚠️ **如实告知**：`reasoning` 与 `summary` 恒为 0（thought 不回放、压缩快照在历史里结构上不可辨识）—— 0 也是"该类存在但当前为空"的如实表达；若前端环图需要非零，得先改框架把两类消息打标记（另行评估）；
- 证据：`backend/test/window_ratio_compressor_test.dart`（7 键齐全 + Σ 对得上总账）；旧的三块侧栏图例已聚合到新键（`usage_sidebar.dart`）。

### N3 缓存命中统计口径 —— ✅ 本就一致

- 命中率 = `cachedTokens / reportedPromptTokens`（分母只含已上报轮次）✅；未上报轮 `cachedTokens == null`（UI 显示"未上报"，不当 0）✅；`steadyHitRate` = 跳过首轮冷启动的轮次平均 ✅。无需改动。

### N4 计划状态 —— ✅ 已实现（同日按本条形状对齐）

- ✅ 计划每次变化发**完整帧 `plan_updated`**（`AgentEvent.kPlanUpdated`）：`planStepsDetailed`（`[{id,title,status}]`，id=`s1/s2/...`）+ 兼容保留 `planSteps/doneCount/activeIndex`；前端只读最后一帧；
- ✅ 计划随会话落盘：每次变化追加 `{role:"plan", steps:[{text,status}]}` 行（append-only，旧行保留可见演化）；
- ✅ 会话恢复时**先发一帧** `plan_updated` 还原（在用户消息落盘之后、一切运行事件之前发出）；无计划时发 `plan_updated{steps:[]}` 表示收起；
- ⚠️ 一处追加：`status` 增加第 4 值 **`cancelled`**（模型可把步骤标记为取消 —— §6.2 允许枚举末尾追加；前端未知值按 pending 渲染即可）；
- 验收：`backend/test/session_history_e2e_test.dart` 3 条（合成消息/多帧取最后/与去重的先后）；杀进程恢复的 UI 验收待真机（灵动岛恢复 = 读同一行）。
- **2026-10-30 新增（B8，只增不改）**：
  - **收尾事件 `plan_closed`**（`AgentEvent.kPlanClosed`，字段 `reachedGoal: bool` / `planClosedReason: String?`）：**只在存在计划时发、只发一次**；成功（`finished` 且步骤全部 `done`/`cancelled`）⇒ `reachedGoal=true, reason=null`；失败/中断/取消/超时/门禁熔断 ⇒ `reachedGoal=false`，`reason` 是**人话**（如"用户停止"/"运行失败：<失败原因>"/"任务被中断"），**不得是空串/堆栈/内部 id**；无计划 ⇒ 不发。前端 `kPlanClosed` 分支与 `restoredPlanFromRow` 已兼容，无需改 UI。
  - **plan 行只增字段** `reachedGoal`/`closedReason`：每次写 plan 行时若已知道收尾信息就带上；**收尾时追加一条最终 plan 行** `{"role":"plan","steps":[…],"reachedGoal":true|false,"closedReason":"…","ts":…}`；旧行缺这两个字段 ⇒ 按 `null`（未知）处理；**不重写旧行、append-only 不变**。
  - 顺序（实测钉死）：**`plan_closed` 事件先于 `finished`/`failed`**；**最终 plan 行在 assistant 行之前**（与既有 plan 行位置一致，重放时计划块在回答上方）。
  - 状态：实现中；真机（5 步任务第 2 步停止 → 重开会话看"已中断"+原因）**未验证**。

### N5 模型与思考等级 —— ✅ 已满足（2026-10-25 补 `reasoningLevelsEffective`）

- `ModelCapabilities.supportsReasoning` 已有；推理档位已接线（§3）；
- ★ **新增 `ModelCapability.reasoningLevelsEffective`**（持久化键 `rLv`，前端 N5 对齐）：**切档位（low/high/max）是否真的生效** —— 只有 OpenAI 兼容轨 true（`extra`→`reasoning_effort`），Anthropic/Responses 轨 false（client 不读）。**false 时前端把档位 chip 显示成仅开/关**（不假装有区别）——按前端要求如实标注；能力创建时按 provider 协议自动填。

### N6 全局累计用量 —— ✅ 无后端工作

- 前端聚合方案同意；`SessionUsage` 落盘字段完整（runs/turns/cached/prompt/output 均在 assistant 行与内存聚合里）。

### N7 记忆结构化 —— ✅ 已落地（2026-10-25 确认形状定稿，前端可开工）

> ⚠️ **2026-10-29 扩展**：N7 已被 **§N12（记忆分层，三作用域）** 扩展 —— 形状只增；
> 旧五方法继续可用但**默认 `global`**，且**全局写入口已关闭**（`memory.append` 永久返回 `E_SCOPE_READONLY`；
> 旧记忆页新增/编辑会收到明确人话错误，这是有意的过渡态）。前端改造按 §N12 + 设计稿 §4.4。

> **给前端的确认**：形状已定稿并入库（`agent_bridge.dart` 的 API 全部可用），
> 全局记忆页可以从整页文本改成结构化卡片了。

- ✅ **实际形状**（与本文 §4.N7 的草案一致 + 两处增补）：
  - API：`AgentBridge.listMemory() / addMemory(text, {kind}) / updateMemory(id, text) / deleteMemory(id) / memoryCapacity()`；
  - 条目：`MemoryEntry { id, kind, text, source, createdAt, expiresAt? }`；
  - `kind` 词表（后端定）：`preference`（长期偏好）/ `background`（项目背景）/ `habit`（使用习惯）/ `other`；
  - 增补① `source`：`'user'`（用户手加）/ `'agent'`（save_memory）/ `'legacy'`（旧纯文本行自动迁移——显示时建议标"旧格式"）；
  - 增补② `expiresAt`（毫秒时间戳，null = 永不过期）—— **过期条目 listMemory 不会返回**（读取即过滤），前端不用自己判；
  - SEC4：`addMemory/updateMemory` 疑似密钥拒收（返回 `MemoryWriteResult.failure`，`error` 字段带原因——前端直接展示）；
  - 存储：`memory.md` 每行一条 JSON（旧格式行读取时迁移为 legacy 条目，不丢内容）；
  - 验收：`listEntries/addEntry/updateEntry/deleteEntry` 单测在 `GlobalMemory`（App 侧），逐条删除不影响其他条目 ✓。

### N8 设备权限状态 —— ✅ 已落地（2026-10-25，前端可接权限页）

- API：`AgentBridge.devicePermissions() -> Map<String, String>`（每项 `granted/denied/unknown`）
- 权限项（新增先登记）：`shizuku`（提权通道：binder 活且已授权；未启动=unknown）/ `files`（文件夹访问：有 ≥1 个 SAF 授权文件夹/工作区 = granted；2026-10-27 起不再恒 granted）/ `allFiles`（Android 11+ 所有文件访问——**我们按设计不申请，denied 是正常态，前端别渲染红色警告**）/ `notifications` / `accessibility` / `overlay` / `media`（图片与视频，2026-10-27 新增）/ `camera`（相机，拍摄接口 `takePhoto` 预留）/ `calendar`（日历读写，后续自动化预留）/ `automation`（屏幕自动化：厂商专属如小米「后台弹出界面」，无平台 API，恒 unknown，接口预留）/ `install`（安装未知应用：状态只读，申请动作在安装 APK 的流程里触发，不在权限页）
- 状态查询只读；拉起授权走命令通道 `requestPermission{kind}`（2026-10-27）：运行时权限（notifications/media/camera/calendar）直接弹系统授权框，无障碍/悬浮窗跳系统设置页，`appSettings` 去本 App 详情页撤销权限，`installPackages` 跳未知来源授权页（**供安装流程调用**），`automation` 如实回未实现；文件夹访问的申请 = 走既有 `pickWorkspace`（SAF 选择器，选中即授权+登记工作区）
- **2026-10-30 修订（B2，只增不改）**：
  - `requestPermission` 返回结构升级为 `{ok, action: "requested" \| "settings_opened" \| "already_granted", granted: bool, error?}`；旧调用方把它当 bool 读时仍按"是否发起/已授权"语义兼容。Dart 新增 `AgentBridge.requestPermissionDetailed(...)` 返回该结构，旧 `requestPermission` 保留。
  - `notifications` 专项：Android 13+ 未授予先弹系统框；若系统已"不再询问"（`shouldShowRequestPermissionRationale==false` 且此前请求过，宿主用 SharedPreferences 记一次性 requested 标记）⇒ **打开 `Settings.ACTION_APP_NOTIFICATION_SETTINGS`（`EXTRA_APP_PACKAGE`）**，返回 `action:"settings_opened"`；`notificationsOff` 继续用同一系统通知设置页。
  - `devicePermissions` 的 `notifications` 判定改为 **`NotificationManagerCompat.areNotificationsEnabled()` + `POST_NOTIFICATIONS` 权限双条件**（总开关关闭时不显示 granted）。
- Kotlin 侧 `MainActivity.handleDevicePermissions`（全本地同步查询，无 binder 阻塞）

### N9 取消真生效 —— ✅ 已实现

- `CancelToken` 已传入 `agent.run(cancelToken:)`：cancel 时 dio 掐断在途流式请求、框架在轮次/工具边界停，收尾措辞"任务已取消"（`AgentRunResult.cancelled` + `failed` 事件）；
- ⚠️ 验收口径偏差如实说明："2 秒内收到 finished(cancelled) 且进程被杀" —— **在途模型流会被立即掐断**，但**已开始的本 地 shell 命令**走到的是超时机制（工具进程不强制杀，防止误杀用户应用 —— 产品铁律）。如需强杀工作区内的命令进程，另行评估白名单式强杀。

### N10 提问（ask_user） —— ✅ 登记为正式契约

- `questions` 结构不变；补充：提问超时 10 分钟（与审批的 5 分钟独立）、超时按"未回答"如实回给模型（绝不编答案）。

### N11 JEV 决策引擎 —— 前端已落地（2026-10-27），本地推理待后端/宿主接入

- **本机画像**：命令通道 `deviceProfile`（`heracles/command`）→ `{ok, model, totalRamMb, freeStorageMb, appFilesDir}`，宿主已实现（`MainActivity.handleDeviceProfile`，只读：ActivityManager 内存 + filesDir 可用空间/路径）；前端 `AgentBridge.deviceProfile()` 据此做本地模型选型推荐（≥6GB 内存推 2B、≥3.5GB 推 0.8B、否则云端）。
- **云端决策（2026-10-29 修订 · 后端服务层已落码）**：POST `https://tokenrhythm.studio/v1/decision`（兼容旧 `/v1/systemone`），`Authorization: Bearer sk_…`，模型**固定 `NeoHorse-Jev-4B`**（任何非精确值——含大小写/空格差异——都被强制纠正并标 `modelCorrected`），**非流式**，1-16 题、请求体 ≤1MiB；**不再发送 `return_thought`**。报文保留一道 `recommend` 题（「推荐用户这样做吗？」）；解析**写死 `answers['recommend']`** —— 若照抄平台文档用别的键名（如 `stop`），200 响应也会被误判「没给 noul」（已踩过的坑）。
  - **端点归一化（五分支，2026-10-29 定稿）**：① 完整 `/decision` → 原样；② `/decisions`、`/systemone` 兼容端点 → 原样（hint 提示平台推荐 `/v1`）；③ 到 `/v1`（含 `/api/v1` 前缀）→ 补 `/decision`（**用户实测可用的填法**，hint 说明）；④ **裸域名 → 请求 `<host>/v1/decision`（不再静默 `/systemone`）** + hint 建议填到 `/v1`；⑤ 其它路径前缀 → 保留前缀补 `/decision` + hint。地址里的 **query/fragment 一律丢弃**（密钥不许进 URL）。`modelsUrlFor` 先归一化再去末段拼 `/models` ⇒ 裸域名 / `/v1` / `/decision` 都得 `<host>/v1/models`。
  - 语义：`422` = 参数/上游限制（**仅首次 422 重试一次**；重试题键**仍是 `recommend`**、只去 `instructions`，**绝不改用文档示例 `stop`**）；`401/403/413/429/5xx/传输错误一律不重试**，按状态码给人话；**无 Key 时三发全 401 ⇒ 鉴权先于参数校验**。
  - 服务层 `decide` 返回 `JevDecisionResult{yesProb, thought, model, diagnostics}`（旧三元组 getter 保留）；失败抛 `JevException(message, diagnostics:)`；`JevController.lastDiagnostics` 供设置页取 hint。`diagnostics` = `{resolvedEndpoint(scheme+host+port+path), httpStatus, serverCode, serverMessage(≤1000 字), traceId, rawBody(≤2048 字节, 脱敏), elapsedMs, modelCorrected, hint, attempts, retriedAfter422, modelsCatalogReadable, transportError, ok, toJson()}`；「取模型目录成功但 decide 422」的 hint = 「鉴权通过、模型目录可读，422 多半是模型权限/参数/上游限制」。
  - 错误体解析：`body.code`/`serverCode`、`body.serverMessage`/`message`、`traceId`（兼容 JSON 字符串 body）；传输错误只用 `DioExceptionType.name`（**不用 `DioException.message`**，防 URL/Key 泄漏）。
  - ⚠️ **真 Key 状态（如实）**：**用户 2026-10-29 在 App 内实测通过（口述证据：模型填 `NeoHorse-Jev-4B`、地址填到 `/v1`）**；**我方无独立真调用证据**（本机未拿 Key 做独立决策），mock 覆盖 5 类错误码 + 归一化 + 422 重试。API Key 只进请求头，日志/异常栈/`rawBody`/`resolvedEndpoint`/`hint` 全部脱敏（有测试锁住）。
- **本地模型文件**：前端负责下载与管理，落在 `<appFilesDir>/jev_models/{0.8b|2b}/`，含 GGUF 权重（StartLux-Decision v1.1，HF 镜像优先）+ BF16 仓库的 tokenizer/config/decision_config.json，完成标记为目录内 `.complete` 文件。
- **本地推理（预留契约）**：`AgentBridge.jevLocalDecide({modelDir, question}) -> Future<double?>`（返回「是」的概率；未接入恒 null，前端如实提示「引擎未接入」）。⚠️ 决策模型不是聊天模型：接入方须用带双向注意力补丁的 llama.cpp + StartLux 读出层（选项字母 logits + decision_config 温度），按普通聊天加载会静默劣化。后端接入后前端零改动即可离线决策。

### N12 记忆分层（三作用域）—— 契约冻结 · 后端落码中（2026-10-29）

> **与 N7 的关系**：本节**扩展** N7，形状只增不改。N7 的五个 API 继续可用，默认作用域 = `global`。
> **状态**：契约已冻结（前端可据此改造记忆页）；**真机验收尚未完成**，验收记录见 `.docs/实测-18-记忆分层.md`
> （未完成前一律标"未验证"，不得宣称已完成）。
> **产品决策依据**：`.docs/记忆系统重设计-2026-10-29.md` §三（设计）与 §六（拍板项）。

#### N12.1 三作用域语义

| 作用域 | 绑定键 | 谁能写 | 注入范围 | 默认开关 |
|---|---|---|---|---|
| `session`（会话私有） | `(workspacePath, sessionId)` | **agent**（`save_memory` 默认）+ 用户 | 只在该会话 | 恒开 |
| `workspace` | `workspacePath` | agent + 用户 | 该工作区所有会话 | 恒开（可关） |
| `global`（全局只读） | 无（App 级） | **仅用户**；agent 只能**提议**，用户确认后晋升 | 所有会话 | 用户开关 `memoryGlobalEnabled`，默认开 |

- 会话私有**不跨会话可见**；全局**只读**：agent 没有直写全局的通道（能力对象层面就没有该方法）。
- 晋升链：agent `propose_global_memory` → `proposals.jsonl` → 用户「晋升/忽略」→ 晋升后 `source='promoted'`。

#### N12.2 存储位置（与旧单文件 `memory.md` 的差异）

```
<工作区>/.heracles/memory/           ← workspace + session 两作用域（Dart 经 fs.*）
  ├── index.json                     ← 派生索引（可重建，绝不当真源）
  ├── workspace.jsonl
  └── session/<sid>.jsonl            ← 每会话一个文件（放工作区，不放 App 私有，防复制工作区串台）

<externalFilesDir>/heracles/memory/  ← global 作用域（只有 Kotlin 能到；走 heracles/device 通道）
  ├── global.jsonl
  ├── proposals.jsonl
  ├── index.json
  ├── migrate.json                   ← 迁移标记（幂等）
  └── legacy/memory.md.<ts>.bak      ← 旧文件备份留档
```

- ★ **会话正文 `.jsonl` 仍严格 append-only，绝不写入任何记忆行**（记忆单独成文件，才能安全 compact）。
- 旧 `<externalFilesDir>/heracles/memory.md` 由 `memory.migrate` 一次性迁入 `global.jsonl`：**先备份、幂等、不丢条目**（JSON 行逐字段保留；legacy 纯文本行原文保留）；迁移失败原文件不动。

#### N12.3 条目行与墓碑（三 scope 同一形状，一行一条 JSON）

```json
{"v":1,"id":"m1791612000000123","scope":"session","sid":"s1791611845161",
 "kind":"preference","text":"…","source":"agent",
 "createdAt":1791612000000,"expiresAt":null}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `v` | 是 | 格式版本，当前 `1`；未知字段原样保留 |
| `id` | 是 | `m<epochMicros>`；同 id 后写者胜（last-wins） |
| `scope` | 是 | `session` / `workspace` / `global`；读时校验，不符 ⇒ 丢弃并计数 |
| `sid` | session 必填 | 强校验锚点：与寻址 `sessionId` 不符的条目一律丢弃（防文件被复制后串台） |
| `kind` | 是 | `preference` / `background` / `habit` / `other`（N7 词表不变） |
| `text` | 是 | 正文；**单条 ≤ 8000 字符**，超限 `E_ENTRY_TOO_LONG` |
| `source` | 是 | `user` / `agent` / `legacy` / `promoted`（淘汰顺序与优先级依赖它） |
| `createdAt` | 是 | 毫秒时间戳 |
| `expiresAt` | 否 | 毫秒；null/缺省 = 永不过期；过期不返回、不注入 |

墓碑（改写一律追加，绝不"清空文件 + 逐条重写"）：

```json
{"v":1,"tomb":"del","ids":["m179…"],"at":1791612100000}
{"v":1,"tomb":"clear","at":1791612200000}
```

`compact`：墓碑/同 id 旧版本占比 ≥ 50%，或文件超该 scope 软预算 80% 时，整体重写为存活条目（写 `.tmp` → `fs.rename` 覆盖）；失败保留原文件并报错，不丢数据。

#### N12.4 寻址与强校验（fail-closed，绝不回落）

```dart
enum MemoryScope { global, workspace, session }
class MemoryAddress { MemoryScope scope; String? sessionId; String? workspacePath; }
```

8 步校验（第 1 步失败即返回，**任何一步失败都不许回落 global/workspace/默认实例**）：

| 步 | 规则 | 失败码 |
|---|---|---|
| 1 | `scope` 与 `sessionId`/`workspacePath` 的必填关系（session⇒sid 必填；workspace⇒path 必填；global⇒二者必须为 null） | `E_SCOPE_MISMATCH` |
| 2 | `sessionId` 匹配 `^s[0-9]{10,16}$`（同时禁止路径分隔符与 `..`） | `E_SID_FORMAT` |
| 3 | `sessionId` 存在于 `sessions.json` | `E_SID_UNKNOWN` |
| 4 | `workspacePath` 非空绝对路径且在工作区登记表里 | `E_WORKSPACE_UNKNOWN` |
| 5 | 解析出的目标文件路径**逐字等于** `(workspacePath, sessionId)` 拼出的规范路径 | `E_PATH_MISMATCH` |
| 6 | 对 `global` 的 agent 写操作 | `E_SCOPE_READONLY`（只有 UI 用户路径可写） |
| 7 | 单条 `text` > 8000 字符 | `E_ENTRY_TOO_LONG` |
| 8 | 读取时条目 `scope`/`sid` 与寻址不符 ⇒ 丢弃 + 计数（`skippedForeign`） | 不报错 |

统一返回形状：成功但为空 = `{"ok":true,"entries":[],"total":0}`；**"空"与"错"绝不同形**。错误 = `{"ok":false,"code":…,"error":人话,"address":{…}}`。

#### N12.5 通道方法（`heracles/device`，Kotlin 侧只负责 global + 提议 + 迁移）

| 方法 | 入参 | 返回 | 说明 |
|---|---|---|---|
| `memory.read` | `{}` | `{ok,text,bytes}` | 兼容保留：返回 `global.jsonl` 原文（供旧 `parseEntries` 直接吃） |
| `memory.append` | `{note}` | `{ok:false,code:"E_SCOPE_READONLY",error:…}` | **语义永久改为拒绝**（全局只读）；保留方法名，让旧调用方拿到明确错误而不是"未知方法" |
| `memory.clear` | `{}` | `{ok}` | 兼容：等价 `userEdit{action:"clear"}`（UI 用户确认后调用） |
| `memory.list` | `{includeExpired?:false, limit?:0}` | `{ok,entries[],total,bytes}` | global 条目 |
| `memory.search` | `{query, limit?:20}` | `{ok,entries[]}` | global 关键词检索（与注入同一分词/打分口径；不注入） |
| `memory.delete` | `{ids:[…]}` 或 `{all:true}` | `{ok,removed,bytes}` | 用户删除 global 条目（等价 userEdit delete） |
| `memory.userEdit` | `{action:"add"\|"update"\|"delete"\|"clear", id?, text?, kind?}` | `{ok,id?,bytes,evicted?}` | **只有用户路径调用**（能力对象不暴露） |
| `memory.propose` | `{note,kind?}` | `{ok,id}` | agent 提议（写 `proposals.jsonl`） |
| `memory.proposals` | `{status?:"pending"}` | `{ok,entries[]}` | UI 待确认列表 |
| `memory.resolveProposal` | `{id,action:"promote"\|"reject"}` | `{ok,entryId?}` | 晋升/忽略（用户动作，agent 不可触发） |
| `memory.stats` | `{}` | `{ok,entries,bytes,limits{…}}` | 存储/注入两组数字 |
| `memory.migrate` | `{}` | `{ok,migrated,alreadyMigrated?,backup?,entries}` | 幂等迁移（先备份、不丢条目、失败原文件不动） |

错误码全集：`E_SCOPE_MISMATCH / E_SCOPE_READONLY / E_SID_FORMAT / E_SID_UNKNOWN / E_WORKSPACE_UNKNOWN / E_PATH_MISMATCH / E_ENTRY_TOO_LONG / E_STORE_IO / E_MIGRATE_FAILED`。**没有"静默成功"分支。**

**实现面核对（2026-10-29 Kotlin 落地后，按真实返回修正/补充）**：

- 新增 4 个**实现面**错误码（不跨层语义，但调用方会看到）：`E_BAD_ARG`（缺参/未知 action/未知 kind/空正文）/ `E_NOT_FOUND`（条目或提议不存在）/ `E_SECRET`（SEC4 拒收）/ `E_UNKNOWN_METHOD`（DeviceChannel 未知方法）。
- `memory.append` 入参放宽为 `{note?}`：**不强制 note**，恒返回 `{ok:false,code:"E_SCOPE_READONLY"}`（任何调用方都拿到同一 code）。
- 返回形状是表内形状的**超集**（旧读者按表内键读不受影响）：`userEdit` 另带 `entries`（`evicted` 恒为数组，空=没淘汰；delete action 也回 `id`）；`delete` 回 `{ok,removed,bytes,entries}`；`resolveProposal` 回 `{ok,id,promoted,entryId?,bytes,entries,evicted}`。
- `memory.stats.limits` 实际键名：存储组 `storageSoftMaxBytes / entriesSoftMax / entryMaxChars`；注入组 `globalWorkspaceInjectMaxChars(6000) / sessionInjectMaxChars(4000) / injectMaxEntriesPerScope(40) / injectCandidateMaxBytes(65536) / retrievalMaxCandidates(200) / summaryMaxChars(40) / windowRatioCap(0.05)`；另带 `scope / expired / fileBytes / pendingProposals / path`。`bytes` = 存活条目序列化字节（≈compact 后大小），`fileBytes` = 磁盘实际字节。
- `memory.migrate` 有**第三态**（设计稿未定义、实现兜底）：`global.jsonl` 非空但 `migrate.json` 缺失 ⇒ `{ok:true,migrated:false,alreadyMigrated:true,reason:"global-jsonl-exists"}`（**不覆盖**、补标记）；无旧文件时回 `{migrated:false,alreadyMigrated:false,reason:"no-legacy-file"}`；`backup` 为相对 `memory/` 的路径（`legacy/memory.md.<epochMillis>.bak`），另有 `legacyMoved`。
- 淘汰顺序实现已被修正为：过期 → 最旧 `agent` → 最旧 `promoted/legacy` → **最旧 `user` 最后动** → 仍放不下 `E_ENTRY_TOO_LONG`（与 §N12.8 一致，KDoc 已改）。
- 单条 8000 字符口径 = **UTF-16 code unit**（Kotlin `String.length` == Dart `String.length`）；含 emoji 时与 Unicode 码点数不同。
- SEC4：旧 Kotlin `MemoryStore` **原本没有密钥闸**，本轮按 backend/App 同源正则**新增**到全部写路径（`userEdit add/update`、`propose`、`resolveProposal(promote)`）。
- `list(limit=0)` 表示不限；`search(limit<=0)` 回落 20。

#### N12.6 AgentBridge（App 侧，统一三作用域）

```dart
Future<List<MemoryEntry>> listMemory({MemoryScope scope = MemoryScope.global,
    String? sessionId, String? workspacePath, bool includeExpired = false});
Future<MemoryWriteResult> addMemory(String text, {MemoryScope scope = MemoryScope.global,
    String? sessionId, String? workspacePath, String kind = 'other'});
Future<MemoryWriteResult> updateMemory(String id, String text, {…同上});
Future<MemoryWriteResult> deleteMemory(String id, {…同上});
Future<MemoryWriteResult> clearMemory({…同上});
Future<List<MemoryEntry>> searchMemory(String query, {MemoryScope scope = …, int limit = 20});
Future<MemoryStats> memoryStats({MemoryScope scope = …, …});          // 存储/注入两组数字
Future<MemoryWriteResult> proposeGlobalMemory(String note, {String kind = 'other'}); // agent 用
Future<List<MemoryProposal>> listMemoryProposals();
Future<MemoryWriteResult> resolveMemoryProposal(String id, {required bool promote});
```

- 旧 `listMemory()/addMemory()/updateMemory()/deleteMemory()/memoryCapacity()` **签名保留、默认 `global`** ⇒ 前端零改动可编译。
- `memoryCapacity()` 形状不变（`usedBytes/maxBytes`），**语义改为"存储软预算"**（`maxBytes` = 该 scope 软预算，不再"到顶拒写"）。
- `MemoryEntry` 只增 `scope`/`sid`（可空，读旧数据为 null）。

#### N12.7 backend 契约（`RunOptions` / 能力 / 工具）

- `RunOptions.memory: MemoryContext?`（新增；非空时优先渲染）；`memoryNote` **保留并标 `@Deprecated`**（CLI/测试仍在用；两者都不传 = 旧行为）。
- `_buildSystemPrompts()` 顺序：默认提示 → 宿主追加（宪法/快照/RAG）→ **global 段 → workspace 段 → session 段 → 冲突尾注**；session 最后（最易变，保前缀缓存）；空段不输出。
- `MemoryCapability` 只增默认实现方法：`defaultWriteScope`（默认 `session`）/`appendScoped(scope,note,{kind})`（默认退化 `append`）/`readScope(scope,{sessionId})`（默认退化 `read`）/`proposeGlobal(note,{kind})`（默认返回"不支持"）；老宿主不改也能编译。
- 工具：`save_memory(note, scope?)`，`scope ∈ {session, workspace}`，默认 `session`；传 `global` **明确拒绝并指路 `propose_global_memory`**（不静默纠正）；新增 `propose_global_memory({note,kind?})`；**工具面 32 → 33**。

#### N12.8 预算：存储 ≠ 注入（两个独立常量族，互不推导）

**存储预算**（软预算；超限**淘汰**，不是拒写）：

| scope | 软预算 | 条目软上限 | 单条上限 |
|---|---|---|---|
| global | 8 MB | 5000 | 8000 字符 |
| workspace | 16 MB | 5000 | 8000 字符 |
| session（每会话） | 512 KB | 300 | 8000 字符 |

淘汰顺序（确定性，禁止随机）：① 过期 → ② 最旧 `source=agent` → ③ 最旧 `user/promoted/legacy`（user 最后动）→ ④ 仍放不下才拒写 `E_ENTRY_TOO_LONG`（绝不写半条）。回报 `evicted:[id…]`（**不静默丢条目**）。**不做 LRU**（读变写、抖缓存；KDoc 注明是有意取舍）。

**注入预算**（每轮 token 花销，与存储量无关）：

| 项 | 默认值 |
|---|---|
| global + workspace 注入上限 | 6000 字符合计（global 先占） |
| session 注入上限 | 4000 字符 |
| 每 scope 最多条数 | 40 |
| 检索候选窗 | 64 KB / scope（或 200 条）；超出只存不注，可用 `searchMemory` 显式查 |
| 窗口自适应 | `min(常量, modelWindowTokens × 5%)`（必须真实现） |
| 单条摘要长度 | 40 字符（无关键词命中时压缩；**不再"无命中就全量返回"**） |

注入段渲染规则：按 `source=user/promoted` 优先 → 关键词得分降序 → `createdAt` 降序排序；得分 >0 给全文，=0 压 40 字摘要；**整条取舍、绝不从中间截断**；超预算尾注「（另有 N 条未注入，可在记忆页查看）」；跨层冲突规则**只在最末出现一次**（会话私有 > 工作区 > 全局；与当前对话冲突以对话为准）。

#### N12.9 设置项（新增，需登记到 §3 映射表）

| 键 | 默认 | 说明 |
|---|---|---|
| `memoryGlobalEnabled` | `true` | 关掉后宿主不读 global（也不注入），**数据保留** |
| `memoryPooling` | `false` | 池化解析结果（默认关；开时必须 key=(scope,scopeId) 强校验） |

#### N12.10 兼容与过渡态（如实）

- `memory.append` 永久 `E_SCOPE_READONLY` 是**有意的过渡态**：旧记忆页在改造前新增/编辑会收到明确人话错误，这不是 bug；前端按设计稿 §4.4 改造后自然消失。
- ★ **过渡期数据风险（必须在真机验收前消除）**：旧记忆页的"编辑/删除"仍走 `GlobalMemory.updateEntry/deleteEntry` = `clear` + 逐条 `append`；而 `append` 已永久只读 ⇒ 会**先清空 global 再回写失败 = 丢整份全局记忆**。因此 **App 侧 AgentBridge 必须先切到 `memory.userEdit`（task-8b）再装包做真机记忆验收**；在此之前，真机测试**禁止**在记忆页编辑/删除全局条目（只读展示/提议晋升可以）。
- `memory.read`/`memory.clear` 行为保持（global）。
- ⚠️ **技术原因（为什么旧记忆页在 wiring 落地前不许动）**：迁移后 `memory.read().text` 是 **JSONL + 墓碑行**；旧 `parseEntries`（只认 `- <ISO> — text` 行）会读出 0 条 ⇒ 旧 UI 显示空、而旧"编辑/删除"走 clear+append 会清空文件。Task-8b 在 AgentBridge 切 `memory.userEdit` 后此问题消失。
- 旧数据：`memory.md` 迁移后保备份；读取代码对 JSON 行与 legacy 纯文本行都容忍。
- 验收状态：Kotlin 通道与 backend 渲染落码中；**真机迁移/会话隔离/全局只读/提议晋升四项均未验证**，完成前不得对外宣称"已完成"。

### N13 流式语音（方案 A）—— D2 已拍板 · 实现中（2026-10-29）

> **决策**：用户 2026-10-29 拍板**方案 A**（新增流式识别模型 + 边说边出字），旧整段识别保留兼容与回退。
> **现状（已核实）**：`VoiceRecorder.kt` 只写 PCM 文件、通道仅 `voice.start/stop/cancel`；`voice_asr.dart` 用 sherpa `OfflineRecognizer` + SenseVoiceSmall 整段识别；`sherpa_onnx 2.0.1` 自带 `OnlineRecognizer`（无需加依赖）；`VoiceModelController` 已有「下载 + 字节校验 + `.complete`」的模型管理。
> **状态**：契约冻结；**落码中，真机未验证**（真机验收见 `.docs/实测-19-流式语音.md`，完成前标"未验证"）。

#### N13.1 数据流与边界（谁负责什么）

```
[Kotlin] AudioRecord（16kHz/16bit/mono，~100ms 分片）
   → EventChannel('heracles/voice')  {type:'chunk', sessionId, seq, pcm(Uint8List)}
   → [Dart 主 isolate] 只做转发/节流/取消，不解码
   → [Dart 独立 isolate] OnlineRecognizer：acceptWaveform → isReady → decode → getResult
   → [Dart 主 isolate] 节流 200–300ms 发 VoicePartial{sessionId, text, isFinal}
   → [UI 前端线] 展示累积草稿（本侧不写界面）
```

- **音频绝不上第三方云**；解码只在设备本机 isolate 内。
- **主 isolate 不做解码/IO**；`OnlineRecognizer` 的绑定在 isolate 内初始化（与现有 `voice_asr.dart` 的 isolate 纪律一致）。
- **60 秒上限与 `RECORD_AUDIO` 权限语义不变**（超时/无权限走现有路径）。

#### N13.2 通道增量（只增不改）

| 名称 | 方向 | 形状 | 说明 |
|---|---|---|---|
| `EventChannel('heracles/voice')` | Kotlin → Dart | `{type:"chunk", sessionId, seq:int, pcm:Uint8List, sampleRate:16000}` | 边录边发；`seq` 单调递增（从 0），Dart 据此丢弃乱序/重复片；`type:"end"` 表示录音正常结束 |
| `voice.start/stop/cancel` | Dart → Kotlin | **不变**（旧三方法保留） | 旧包没有 `heracles/voice` 事件流 ⇒ Dart 检测不到流时**回退整段识别** |

错误语义：`voice.start` 在无权限时仍返回既有 `{ok:false,...}`；EventChannel 建立失败/旧包 ⇒ 触发回退，**不报运行失败**。

#### N13.3 `VoicePartial`（进程内事件，AgentBridge）

```dart
class VoicePartial {
  final String sessionId;
  final String text;      // ★ 累积整段草稿（不是增量片段）
  final bool isFinal;     // true = 本轮识别定稿（静音断句/停止/结束时）
  final int seq;          // 该会话内的序号（从 0 递增）
  final int tsMs;
}
```

- **节流**：同一 session 两次 `VoicePartial` 间隔 ≥200ms 且 ≤300ms（尾部必须尽快 flush）；`isFinal=true` 立即发、不节流。
- 语义：`text` 只增不减（定稿后新一句从空白或续接由 VAD 决定）；**绝不每 100ms 重发整段录音**（那不是流式，是把旧结果刷新一遍）。
- 取消：`voice.cancel` 后立即停发 partial；已发出的 partial 保留（UI 决定是否清除）。

#### N13.4 模型与回退（2026-10-30 修订：内置小模型，开箱即用）

| 项 | 规则 |
|---|---|
| **内置流式模型（默认）** | **14M 中文 streaming zipformer int8 随 APK assets 内置**（encoder int8 21,621,684 / decoder int8 1,888,682 / joiner int8 1,795,562 / tokens 48,697，合计 **≈24.2 MiB**；来源 HF `csukuangfj/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23`）。首次启动/首次点麦克风时**幂等解压**到 `<filesDir>/voice_models/streaming-zipformer-zh-14m/`（逐文件字节校验 + `.complete`），**用户无需下载、无网可用**；模型在 filesDir ⇒ **卸载即删** |
| 可选高精度模型 | 旧的 ~200MB 中英双语流式模型降级为**可选**（设置页手动下载），**绝不作使用前提**；API 保留 |
| 回退 | **仅**在内置解压失败 / 模型加载失败 / 旧包无 `heracles/voice` 事件流时回退现有整段识别，并如实提示「流式不可用，用整段识别」 |
| 加载失败 | 回退整段识别（不阻断语音输入） |
| 识别质量 | 流式结果与离线结果可能不一致（内置模型更小，中文优先）；**不承诺逐字一致**，语义 = "边说边出草稿、结束后以最终结果为准" |
| 状态 | ⚠️ 实现中；真机（全新安装/断网）未验证 —— 完成前标"未验证" |

#### N13.5 验收（真机，未完成前标"未验证"）

1) 边说边出字（partial 间隔 200–300ms，文本单调增长）；2) 静音 ~800ms 断句出 `isFinal`；3) 取消后不再收 partial；
4) 60 秒上限仍生效；5) 无权限时降级正确；6) **内置模型解压/加载失败才回退**整段识别且提示如实（正常情况用户无需下载任何模型）；7) `.complete` 幂等不被破坏；8) **全新安装/清除数据 + 断网**下也能流式出字。

> **2026-10-30 真机验收（B1）**：断网首次点麦克风 ⇒ 私有目录幂等解压出 4 文件 + `.complete`（字节与 assets 一致）；`[voice] partial` seq 0→14、chars 0→15、语音期间间隔 **200–300ms**；`isFinal=true` 只在真断句（2 次）与停止收尾（1 次）出现（VAD 静音期重复 final 已修）；停止后文本提交到输入框（截图留档，日志不含正文）。**未验证**：取消（前端无入口，仅单测）、整段 SenseVoice 回退出字（非本轮验收项）、逐字准确度（不承诺）。

## 5. 流式与渲染约定 —— ✅ 无异议

后端保持原始粒度不节流；`approval_required`/`context_updated`/`plan_updated` 三类新事件已按 §6.1 登记到本文。

## 6. 兼容与变更规矩 —— ✅ 遵守

- 新事件类型已登记（approval_required / context_updated / plan_updated；approval_request 与 plan_created 保留在 knownTypes 供旧读者，后端不再发送）；
- 事件字段只增（callId/workspaceInside/breakdown/limit/limitSource/planStepsDetailed）；`.jsonl` 只增行类型与字段（tool_call/plan/compact 行 + tool 行的 id 字段；**2026-10-29 新增**：step 行可带 prompt/cached/out（cached 为 null 不写键），新增 `role:"approval"` 与 `role:"ask"` 结果行，字段见 §N12.10 与 `接口.md` §7.2；旧值 `'allow'|'allow_always'` 仍接受但落盘统一 `once/always/deny`；**D6 已拍板**：tool 行只增 `surface`/`exitCode`/`command`（取不到就不写键，回放由前端接））；
- 契约常量以 `contract.dart` 为唯一来源 ✅（同目录另有 `接口.md` 记录后端→前端的实现面，与本文互补：本文是**前端提出的契约**，`接口.md` 是**后端的实现清单**）。

## 7. 待确认 —— 已关账（前端 2026-10-25 全部接受）

> **关账记录**：四个回复（5 分钟超时按 deny / compressor 拆分 / kind 后端定 /
> 白名单 v1 按工具名）前端全部接受；N1 有意偏差（破坏性三件套+shell/APK 无论
> workspaceInside 都拦）接受，弹窗按事件渲染、前端不自行判定。以下原文留档。

1. **审批超时 5 分钟**：✅ 采纳（原 10 分钟已改）；超时按 deny ✅ 且并发 `blocked` 事件（用户要知道弹窗为什么"自己没了"）。
2. **N2 由 compressor 估算器拆分** ✅（同一套系数，口径稳定）；reasoning/summary 恒 0 的原因见 N2 回复。
3. **kind 词表后端定** ✅：`preference / background / habit / other`（随 N7 实现交付）。
4. **「始终允许」粒度**：v1 维持**按工具名**（已实现并持久化）。细化到"工具+参数模式"需要通配匹配设计与审计（白名单变宽即是攻击面），建议作为 N7 之后的独立条目再议；前端弹窗文案可先按"始终允许此工具"表述。

---

## 8. 沙箱（内联执行面）—— 给前端的接口（2026-10-28）

> **一句话**：沙箱是**内联在本 APK 里的执行面**（PRoot + Alpine rootfs），不是第二个 App，
> 也不是「更高权限的 shell」。它解决的是**文件系统污染与崩溃恢复** ——
> 命令在 rootfs 里跑，产物/缓存/半成品都留在 rootfs，随时可整块回滚。
>
> ⚠️ **PRoot 不提供 namespace / cgroup / seccomp，不是敌对代码隔离。**
> 界面上**不要**把它描述成"安全沙箱"。

### 8.1 与设备 shell 的区别（别在 UI 上混为一谈）

| | 在哪跑 | 身份 | 用途 |
|---|---|---|---|
| `AgentBridge`/`DeviceShell` 的 `exec.run` | 真实手机 | App / Shizuku / Root | 操作**真实系统**（装包、读系统文件…） |
| **沙箱 `SandboxService.execute`** | PRoot rootfs 内 | 沙箱内假 root | 跑**项目构建 / 脚本**，不碰真实系统 |

两条路**刻意不合并**。UI 上如果同时暴露，建议分两个入口并标注清楚（"在手机上" vs "在沙箱里"）。

### 8.2 Dart API（已实现，`app/lib/services/sandbox_service.dart`）

```dart
import 'package:heracles/services/sandbox_service.dart';

final sandbox = SandboxService();          // 构造零副作用
```

| 方法 | 返回 | 说明 |
|---|---|---|
| `status()` | `SandboxStatus` | 查状态，**无副作用**。`installed` = 沙箱已激活 |
| `activate({String? ociRef})` | `SandboxStatus` | **激活 = 装 rootfs**。内置优先（离线），OCI 兜底（要网） |
| `execute(command, {workdir, timeoutMs, usePty})` | `SandboxSubmit` | **提交即返回**（带 `id`），输出走下面三条流 |
| `outputStream` / `doneStream` / `errorStream` | `Stream<…>` | 流式 stdout/stderr、完成、错误 |
| `readFile(path)` / `writeFile(path, text)` | `SandboxFileResult` | `path` 支持 `@name/...` |
| `registerMount({...})` | `SandboxFileResult` | 注册命名挂载点（见 8.4） |
| `listMounts()` | `List<SandboxMount>` | 给用户展示挂载点与**只读徽标** |
| `queryChannels()` | `List<SandboxChannelInfo>` | 四条通道的可用性与风险（**不含 allow/deny**） |
| `dispose()` | — | 页面销毁时调 |

**`execute` 是流式的**，典型用法：

```dart
final done = Completer<SandboxExecResult>();
final subOut = sandbox.outputStream.listen((c) => appendToView(c.chunk));
final subSub = sandbox.doneStream.listen((d) { if (!done.isCompleted) done.complete(d.result); });
final subErr = sandbox.errorStream.listen((e) { /* 见 8.3 */ });

final submit = await sandbox.execute('echo hi', workdir: '/');
if (!submit.ok) { /* submit.error 是人话 */ }
final result = await done.future;     // result.exitCode / stdout / stderr / durationMs
```

> `execute` 会**自动挂上流式通道**，前端不用手工接线；但页面销毁时请 `dispose()`。

> **2026-10-30（B5，只增）**：工作区打通的语义 —— **宿主 agent 的 shell 执行路径**在 App 工作区有物理路径时默认 `workdir=/opt/ws-real`（工作区经 `@userws` 挂载到该路径；见 `device_capabilities` 的 `userws.isMounted ? '/opt/ws-real' : '/workspace'`）；⚠️ `SandboxService.execute` 的**默认参数仍是 `/workspace`**（前端直接调 `execute()` 时未变）。SAF 工作区无物理路径 ⇒ 不 bind、保持 `/workspace`，并在结果/提示里**如实说明"沙箱与用户工作区是两套文件系统"**。`@userws` 注册是**应用层幂等**（先 `listMounts` 命中同名+bindTo 则跳过）；底层 `registerMount` 本身是"注册或覆盖"。通道参数只增（`workdir` 已存在）。

### 8.3 错误码（可直接据此给用户明确提示，不要笼统说"失败了"）

| 常量 | 值 | 含义 | UI 建议 |
|---|---|---|---|
| `kSandboxCodeRootfsNotReady` | 2 | rootfs 还没装 | 引导点「激活沙箱」 |
| `kSandboxCodeMountUnknown` | 12 | 引用了未注册的 `@name` | 提示"挂载点不存在"，并列出可用挂载点 |
| `kSandboxCodeMountReadOnly` | 13 | 往**只读挂载点**写入 | 明确说 `@libs 是只读挂载`，不要显示"权限不足" |

`SandboxFileResult` 上有便利判断：`isReadOnly` / `isUnknownMount`；
`SandboxExecError` 上有 `isReadOnlyMount` / `isUnknownMount` / `isRootfsNotReady`。

### 8.4 命名挂载：**模型和 UI 都只出现 `@name`**

模型永远只写 `@workspace/out/app.apk` 这种**逻辑路径**，物理路径由后端解析。

- ✅ 界面上显示：`@workspace`、`@libs（只读）`、`@pc_shared`
- ❌ **绝对不要**在 UI、提示词、few-shot、历史对话里显示物理路径
  （如 `/data/user/0/com.theohowie.heracles/files/sandbox/rootfs/opt/ws/...`）——
  一旦出现，换设备或改共享目录后这些路径全失效

`SandboxMount` 字段：`name` / `prefix`（= `@name`）/ `backend` / `readOnly` / `bindTo` / `description`。

三种 `backend`（`SandboxMountBackend`）：`rootfsRelative`(0) / `hostPrivateDir`(1) / `safTree`(2)。
一般 UI 不需要区分，只要**如实显示 `readOnly`**。

> **2026-10-30（B5）新增 `@userws`**：App 工作区（`.../files/app-workspace`）的读写挂载，guest 侧绑定到 `/opt/ws-real`（`/opt` 在 `ALLOWED_BIND_TARGETS` 白名单内）。**SAF 工作区没有物理路径 ⇒ 不可 bind**：此时不出现 `@userws`，UI/模型提示里如实说"两套文件系统、用文件工具读写工作区"。guest 只能看到工作区与显式挂载（不得看到 sessions/keys/memory）。

### 8.5 建议的 UI（最小可用）

1. **沙箱卡片**：`已激活 / 未激活` + `rootfsSummary` 一行 + `激活` 按钮（调 `activate()`）
   - 激活会解包 ~9 MB、耗时几秒，**要有进度态**（按钮转圈即可）
   - 失败如实显示（内置失败时会尝试 OCI，没网就失败）
2. **挂载点列表**：`@name` + `只读/读写` 徽标 + `description`
3. **执行输出**：流式追加，`stdout`/`stderr` 可用颜色区分；结束显示退出码与耗时

### 8.6 权限决策不在沙箱

`queryChannels()` 只回答「有哪些通道、可用吗、风险几级」，**没有 allow/deny**。
放不放行由门禁（`PermissionMode` / `approval_required`）决定 —— 前端**不要**拿通道可用性当授权依据。

### 8.7 当前边界（如实，别在 UI 上过度承诺）

| 能力 | 状态 |
|---|---|
| 激活（内置 rootfs，离线） | ✅ 真机验证 |
| 沙箱内执行命令 + 流式输出 | ✅ 真机验证 |
| 命名挂载读写（`@workspace`） | ✅ 真机验证 |
| 只读挂载拒绝写入 | ✅ 单测 + 设备验证 |
| SAF 目录（`@pc_shared`） | ⚠️ 代码已实现，**真实授权流程未真机验证** |
| Shizuku / Root / 无线 ADB 通道 | ⚠️ 代码与单测有，**真机未验证**（Shizuku 未运行 / 设备无 root / 需 `adb pair`） |
| 沙箱内跑 `aapt2`/`javac`/`gradle` | ✅ 已验证（含签出 APK）；**AGP 完整构建未验证** |
| 工作区打通（`@userws` → `/opt/ws-real`，默认 workdir） | ✅ 2026-10-30 真机验证：文件工具写工作区 → 沙箱 `pwd=/opt/ws-real`、`ls/cat/wc -l` 正确、写回后文件工具可见；SAF 工作区 `workdir=/workspace` + 如实提示"两套 FS" |
| 边界加固（越权读全失败 / `--kill-on-exit` / 最小 bind / seccomp 评估） | ✅ 2026-10-30 真机验证：读 `/data/data/<pkg>/files`、`shared_prefs`、`sessions`、`memory`、`/proc/self/root`、`..` 穿越**全部 No such file**；正常 `echo/ls/date/tar` 未受影响；单测 83/83。**seccomp 不可行**（PRoot 依赖 ptrace），ADR-041。⚠️ **不得**对外宣称"内核级强隔离"——真实边界 = Android 应用沙箱 + PRoot 文件系统视图；T2 构建套件加固后**未复验** |

### 8.8 验收方式（前端自测）

```powershell
cd app
flutter test test\sandbox_service_test.dart      # 14 条，覆盖通道缺失/解码/流式/错误码
flutter analyze                                   # 期望 No issues found!
```

真机侧由后端负责（`--dart-define=SANDBOX_SELFTEST=true` 的守卫自检，release 不带）。