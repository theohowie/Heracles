# Heracles 前端 ↔ 后端接口约定

> 版本 v1 · 2026-10-24 · 前端（`app/`）提出，后端（`backend/` + Kotlin 薄层）实现
>
> 本文是新版黑白界面落地时的接缝契约。原则：
> **已有的不许改形状**（第 2 节）；**新需要的按第 4 节逐条补**，每条带验收标准；
> 谁改契约先打招呼；落盘 `.jsonl` 格式**只增字段、不改名不删**；枚举按 `name` 持久化、**只许末尾追加**。

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
| `PermissionMode`（manual / workspace / full） | 每次 `run` 必须带入并**真实生效**（见 N1） | 现状：未映射进后端 —— 本次必须修 |
| `ReasoningLevel`（auto / off / low / high / max） | wire 名 = 枚举名小写，**必须与 Kotlin 侧逐字符一致** | 云端映射 `reasoning_effort`；本地只有开/关两态，`ModelCapabilities` 须标注，前端如实展示、不假装有区别 |
| 最大轮次 | 后端常量 `ContractAgent.maxTurns = 40` 为上限来源 | UI 步进器改的是运行参数，不得超过契约上限的校验 |
| `BusySendBehavior`（queue / interrupt） | 纯前端行为：排队 = 前端队列；插队 = 调 `interruptRun` | 后端无感知 |
| `StepDetail`（精简 / 标准 / 详细 / 完全展开） | **纯前端渲染密度**，后端无感知 | 新 UI 的「工作步骤展示」滑杆即此枚举，**四档**（以枚举为准，不做三档） |
| 界面语言 / 外观 / 字号 | 纯前端 | 字号走 `MediaQuery.textScaler` 全局缩放 |
| **流式输出** | **无开关**（产品决策 2026-10-24） | 输出默认流式是核心体验，不提供关闭项；后端保持 `step_delta / reasoning_delta` 增量事件即可 |

## 4. 新界面需要后端补的接口（逐条实现，带验收）

### N1审批门禁真接线

现状（审计 H1）：`CapabilityNeedsApproval` 在工具工厂被翻译成一句普通文本，无挂起、无事件，高危操作无 fail-closed。Kotlin 时代的审批闭环在内核重构时丢失，属回退。

要求：
- 在框架 `beforeToolCall` 钩子拦截需审批的工具调用，`run` **挂起**等待答复（不是先执行后通知）。
- 新增事件 `approval_required`，载荷：`callId`（唯一）、`tool`、`args`（可读预览，命令类给原文）、`risk`（一句话风险说明）、`workspaceInside`（bool，是否在工作区内）。
- 答复走已有 `replyApproval`，但参数升级为结构化：`{callId, decision}`，`decision ∈ {deny, once, always}`；`always` = 把工具名写入 `alwaysAllowedTools` 名单（已有接口），本会话内同工具不再问。
- `PermissionMode` 判定：`manual` = 全部危险操作都拦；`workspace` = `workspaceInside == true` 的改动放行、区外拦；`full` = 不拦（但前端开启该档有二次确认，与后端无关）。
- **fail-closed**：等待答复超时（建议 5 分钟）或前端断开 → 按 `deny` 处理并发 `blocked` 事件，绝不默认放行。
- 验收：`full` 以外模式下执行 `rm` 类命令，前端能收到 `approval_required` 并挂起；答复 deny 后工具不执行且模型收到拒绝结果继续运行。

### N2 上下文分项统计（用量抽屉环图数据源）

现状：`ContextUsage` 只有冻结区/对话两分，不够画环图。

要求新增结构（随 `turn_started` 事件附带，或独立 `context_updated` 事件，每轮至少一次）：

```dart
class UsageBreakdown {
final int limit; // 窗口上限
final String limitSource; // 上限来源说明（沿用现有约定）
final List<UsageCategory> categories;
}
class UsageCategory {
final String key; // 固定键名，只许新增、不许改名
final int tokens; // 估算值，估算系数必须与 Kotlin TextMath 一致
}
// key 约定：system / toolDefs / toolResults / reasoning / assistant / user / summary
```

- 数据来源可用 `window_ratio_compressor` 的估算器按类别拆分；估算即可，但**口径必须稳定**（同一会话内不跳变方法）。
- 前端环图只认这个结构：分类可增（前端忽略不认识的 key 并入「其他」），不可改已有键名。
- 验收：任意一轮后前端能拿到 categories 且 Σ ≈ `ContextUsage.used`（±5%）。

### N3 缓存命中统计口径

现状：`EventCacheStats{cachedTokens, promptTokens, hitRate}` 已有；`SessionUsage` 已聚合。

约定口径（双方按此实现，不再各算各的）：
- 命中率 = `cachedTokens / reportedPromptTokens`，**分母只含 provider 已上报缓存字段的轮次**（未上报轮次不稀释分母）；此口径与 `SessionUsage` 现有注释一致。
- provider 未上报时，前端显示「未上报」而非 0% 或假数 —— 后端只需保证 `cachedTokens == null` 的语义真实。
- 用量抽屉第二页（缓存页）数据 = 当前会话 `SessionUsage` 聚合 + 最近一次 `steadyHitRate`。

### N4 计划状态（灵动岛数据源）

现状：`AgentEvent` 已有 `planSteps / doneCount / activeIndex` 字段，但计划不落盘、恢复会话即丢（审计待办）。

要求：
- 计划每次变化（新建/勾选/改序/关闭）都发一帧完整计划事件：`plan_updated{steps:[{id, title, status}], activeIndex}`，`status ∈ {pending, active, done}`。前端灵动岛只读最后一帧，不做增量拼接。
- 计划随会话落盘（`.jsonl` 只增 `plan` 字段，旧读者忽略），会话恢复时先发一帧 `plan_updated` 还原。
- 无计划时发 `plan_updated{steps: []}` 表示收起灵动岛，不要用 null 兼任「无变化」。
- 验收：任务执行中杀进程重进会话，灵动岛能恢复到关闭前的步骤状态。

### N5 模型与思考等级

- `fetchModels` 须返回：模型 id、显示名、是否端侧、窗口上限、是否支持思考等级区分（`supportsReasoningLevels`，端侧 llama 只有开/关时为 false）。
- 前端模型抽屉、灵动岛与输入区 chip 的「思考 · X」都读同一份运行参数；切换只影响**下一条**消息，不打断进行中的 run（与现有约定一致）。

### N6 全局累计用量（抽屉页脚数据源）

需要：总 Token、会话数、活跃天数、消息数四个累计值。
- **决定：由前端基于 `SessionStore` 聚合**，后端不新增接口；前提是后端保证每会话 `SessionUsage` 落盘完整（runs/turns/cachedTokens 等字段不缺失）。
- 活跃天数口径：有过 run 的自然日去重计数。

### N7 记忆结构化（全局记忆页数据源）

现状：长期记忆是整文件文本（256 KB 上限，整段进 system prompt），前端只能整页展示原文 —— 即用户批评的「毛胚房」。

要求后端（或能力层）提供结构化读写 API（文件内部格式自定，但给前端必须是结构化）：

```dart
class MemoryEntry {
final String id; // 稳定唯一 id
final String kind; // 长期偏好 / 项目背景 / 使用习惯 …
final String text;
final String source; // 来自哪次对话/设置
final int createdAt; // 毫秒时间戳
}
// listMemory() / addMemory(text) / updateMemory(id, text) / deleteMemory(id) / clearMemory()
// memoryCapacity() -> {usedBytes, maxBytes} // maxBytes = ContractMemory.maxBytes
```

- 拼进 system prompt 的行为不变（仍整段注入），但存储层按条目组织；条目增删后重写文件。
- 验收：前端记忆页能逐条删除一条而不影响其他条目在下一轮 prompt 中的出现。

### N8 设备权限状态

- Kotlin 薄层提供统一查询：每项权限返回 `granted / denied / unknown`，前端权限页只读渲染；「去开启」走已有拉起流程（如 `shizukuGrant`）。
- 权限项清单：Shizuku、文件访问、通知、无障碍、悬浮窗。新增权限项时先在本文件登记。

### N9 取消真生效

现状（审计 D1 待定案）：`cancelRun` 疑似只设标志、`CancelToken` 未传入运行循环。

要求：`cancelRun` 必须把取消传进循环，正在进行的模型请求/工具调用应尽快中止，最终以 `finished{stopReason: cancelled}` 收尾；前端停止按钮只认这个终态，不靠本地猜测。
验收：长命令执行中点停止，2 秒内收到 `finished(cancelled)` 且进程被杀。

### N10 提问（ask_user）

已有 `LocalAskGate` + `replyAsk`，约定事件 `questions` 结构不变：`[{id, text, options?}]`；前端以底部弹层呈现，答复后 run 继续。无新增要求，仅登记为正式契约。

## 5. 流式与渲染约定

- 思考（`reasoning_delta`）与正文（`step_delta`）分开事件，前端分开渲染（思考默认折叠为摘要行，正文逐字流式）。
- 工具调用在前端渲染为**单行文字**（图标 + 一句话摘要），明细（参数/结果）点击展开；后端无需为此改事件，摘要由前端按 `StepDetail` 档位从 `args/result` 生成。
- 事件可能高频：前端按帧合并渲染，后端不要自己节流（保持原始粒度，节流是前端的事）。

## 6. 兼容与变更规矩

1. `AgentEvent.type` 新增类型必须先登记到第 2 节清单；前端对未知 type 一律忽略。
2. 事件字段只增不改名、不改类型；枚举只许末尾追加（按 `name` 持久化，读回有兜底）。
3. `.jsonl` 落盘格式只增字段；读者必须忽略未知字段（崩溃级事故防线，见工作约定）。
4. 契约常量以 `backend/lib/src/contract/contract.dart` 为唯一来源，本文只引用不复述数值（上限类数值以那边为准）。
5. 本文件变更 = 契约变更，改前在群里（仓库 issue/PR）打招呼，前后端都确认后再动代码。

## 7. 待确认（请后端回复）

1. N1 审批等待超时取 5 分钟是否合适？超时按 deny 是否接受？
2. N2 分类估算由 compressor 拆分，还是单独估算器？（前端只认输出结构，不关心实现）
3. N7 记忆条目的 `kind` 分类词表由后端定还是前端定？建议后端定、前端只展示。
4. 「始终允许」粒度：现为按工具名。是否需要细化到「工具 + 参数模式」（如只允许 `rm` 工作区内路径）？前端弹窗文案依赖于此。
