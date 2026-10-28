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

### N5 模型与思考等级 —— ✅ 已满足（2026-10-25 补 `reasoningLevelsEffective`）

- `ModelCapabilities.supportsReasoning` 已有；推理档位已接线（§3）；
- ★ **新增 `ModelCapability.reasoningLevelsEffective`**（持久化键 `rLv`，前端 N5 对齐）：**切档位（low/high/max）是否真的生效** —— 只有 OpenAI 兼容轨 true（`extra`→`reasoning_effort`），Anthropic/Responses 轨 false（client 不读）。**false 时前端把档位 chip 显示成仅开/关**（不假装有区别）——按前端要求如实标注；能力创建时按 provider 协议自动填。

### N6 全局累计用量 —— ✅ 无后端工作

- 前端聚合方案同意；`SessionUsage` 落盘字段完整（runs/turns/cached/prompt/output 均在 assistant 行与内存聚合里）。

### N7 记忆结构化 —— ✅ 已落地（2026-10-25 确认形状定稿，前端可开工）

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
- Kotlin 侧 `MainActivity.handleDevicePermissions`（全本地同步查询，无 binder 阻塞）

### N9 取消真生效 —— ✅ 已实现

- `CancelToken` 已传入 `agent.run(cancelToken:)`：cancel 时 dio 掐断在途流式请求、框架在轮次/工具边界停，收尾措辞"任务已取消"（`AgentRunResult.cancelled` + `failed` 事件）；
- ⚠️ 验收口径偏差如实说明："2 秒内收到 finished(cancelled) 且进程被杀" —— **在途模型流会被立即掐断**，但**已开始的本 地 shell 命令**走到的是超时机制（工具进程不强制杀，防止误杀用户应用 —— 产品铁律）。如需强杀工作区内的命令进程，另行评估白名单式强杀。

### N10 提问（ask_user） —— ✅ 登记为正式契约

- `questions` 结构不变；补充：提问超时 10 分钟（与审批的 5 分钟独立）、超时按"未回答"如实回给模型（绝不编答案）。

### N11 JEV 决策引擎 —— 前端已落地（2026-10-27），本地推理待后端/宿主接入

- **本机画像**：命令通道 `deviceProfile`（`heracles/command`）→ `{ok, model, totalRamMb, freeStorageMb, appFilesDir}`，宿主已实现（`MainActivity.handleDeviceProfile`，只读：ActivityManager 内存 + filesDir 可用空间/路径）；前端 `AgentBridge.deviceProfile()` 据此做本地模型选型推荐（≥6GB 内存推 2B、≥3.5GB 推 0.8B、否则云端）。
- **云端决策**：前端直连 `/v1/systemone` 兼容接口（Jev 官方 / StartLux 云端 / 自建 startlux-decide），报文：`state={question: 原文}` + 一道 `noul` 题（「推荐用户这样做吗？」）+ `return_thought=true`；概率 ≥0.5 = 推荐。无需后端参与。
- **本地模型文件**：前端负责下载与管理，落在 `<appFilesDir>/jev_models/{0.8b|2b}/`，含 GGUF 权重（StartLux-Decision v1.1，HF 镜像优先）+ BF16 仓库的 tokenizer/config/decision_config.json，完成标记为目录内 `.complete` 文件。
- **本地推理（预留契约）**：`AgentBridge.jevLocalDecide({modelDir, question}) -> Future<double?>`（返回「是」的概率；未接入恒 null，前端如实提示「引擎未接入」）。⚠️ 决策模型不是聊天模型：接入方须用带双向注意力补丁的 llama.cpp + StartLux 读出层（选项字母 logits + decision_config 温度），按普通聊天加载会静默劣化。后端接入后前端零改动即可离线决策。

## 5. 流式与渲染约定 —— ✅ 无异议

后端保持原始粒度不节流；`approval_required`/`context_updated`/`plan_updated` 三类新事件已按 §6.1 登记到本文。

## 6. 兼容与变更规矩 —— ✅ 遵守

- 新事件类型已登记（approval_required / context_updated / plan_updated；approval_request 与 plan_created 保留在 knownTypes 供旧读者，后端不再发送）；
- 事件字段只增（callId/workspaceInside/breakdown/limit/limitSource/planStepsDetailed）；`.jsonl` 只增行类型与字段（tool_call/plan/compact 行 + tool 行的 id 字段）；
- 契约常量以 `contract.dart` 为唯一来源 ✅（同目录另有 `接口.md` 记录后端→前端的实现面，与本文互补：本文是**前端提出的契约**，`接口.md` 是**后端的实现清单**）。

## 7. 待确认 —— 已关账（前端 2026-10-25 全部接受）

> **关账记录**：四个回复（5 分钟超时按 deny / compressor 拆分 / kind 后端定 /
> 白名单 v1 按工具名）前端全部接受；N1 有意偏差（破坏性三件套+shell/APK 无论
> workspaceInside 都拦）接受，弹窗按事件渲染、前端不自行判定。以下原文留档。

1. **审批超时 5 分钟**：✅ 采纳（原 10 分钟已改）；超时按 deny ✅ 且并发 `blocked` 事件（用户要知道弹窗为什么"自己没了"）。
2. **N2 由 compressor 估算器拆分** ✅（同一套系数，口径稳定）；reasoning/summary 恒 0 的原因见 N2 回复。
3. **kind 词表后端定** ✅：`preference / background / habit / other`（随 N7 实现交付）。
4. **「始终允许」粒度**：v1 维持**按工具名**（已实现并持久化）。细化到"工具+参数模式"需要通配匹配设计与审计（白名单变宽即是攻击面），建议作为 N7 之后的独立条目再议；前端弹窗文案可先按"始终允许此工具"表述。
