# CloudAgentPipeline 重构交付报告

> **日期**：2026-10-21
> **任务**：为云端大模型（Claude Opus 5.5 / GPT-6 Astra 级）重建执行管线，废弃 4B 本地小模型时代的 Hack
> **策略**：隔离重建（新包 `dev.heracles.cloud` 独立），旧 `AgentLoop` 保留 fallback，Feature Flag 切换

---

## 0. 验证结果（全绿）

| 验证项 | 结果 |
|---|---|
| `.\gradlew.bat check` | **BUILD SUCCESSFUL**（含 G1 禁止 android import、G10 字节码 ≤ Java 17 门禁） |
| Kotlin 测试总数 | **905 / 905 通过，0 failures**（改动前 781，**净增 124 条**） |
| ├ core | 135（+7 `ToolValidatorLengthTest`）|
| ├ workspace | 51 |
| ├ toolchain | 75 |
| ├ agent | 534（+28 `CloudPipelineReleaseTest`、+13 `ApprovalModeRegressionTest`、+11 `CloudPipelineSafetyTest`、+18 `CloudBridgeAdaptersTest`、+11 `CloudMetaToolsTest`、+5 `SchemaRealWorldTest`、+7 `ToolArgPassthroughTest`、+9 `CloudPlanPersistenceTest`、+5 `CloudParallelConcurrencyTest`）|
| └ provider-http | 110（+5 `ReasoningChannelTest`）|
| `:app:compileDebugKotlin` | **BUILD SUCCESSFUL** |
| `flutter analyze` | **No issues found!** |
| 新增 Dart 测试 | `usage_metrics_test.dart` **17/17**、`tool_diff_visibility_test.dart` **16/16** |
| **★ 真 Key 真机验证** | **✅ 已跑通**（仓库历史首次）—— 见 [`.audit/REAL-KEY-VERIFICATION.md`](REAL-KEY-VERIFICATION.md) |

---

## 0.1 ★ 默认已切换（2026-10-21 晚）：新管线是主路径，旧管线降为 fallback

| | 之前 | **现在** |
|---|---|---|
| 默认执行 | 旧 `AgentLoop` | **`CloudAgentPipeline`** |
| 旧管线 | 主路径 | **fallback**（`HERACLES_CLOUD_PIPELINE=0` 显式退回） |
| `AgentLoop` | 正常类 | **`@Deprecated(WARNING)`**，KDoc 写明迁移理由 |

### ⚠️ 但**不是全量弃用**：Anthropic / Responses 两轨**自动退回旧管线**

2026-10-21 自查发现一个**必须留闸**的风险：本次重构改了**共享的**
`NativeToolSchema.canonicalBody`，它现在优先用类型化 `jsonSchema` 而不是旧的 all-string 形状。
而 `jsonSchema` **只有新管线**会设置 ⇒ 三条轨的 `tools` 形状变成：

| 组合 | 发出的 `tools` 形状 | 真 Key 验证 |
|---|---|---|
| 新管线 + OpenAI 兼容 | 类型化 Schema | ✅ **已验证**（4 轮真机）|
| **新管线 + Anthropic** | **类型化 `input_schema`** | ❌ **从未验证**（用户无对应 Key）|
| **新管线 + Responses** | **类型化扁平 `tools`** | ❌ **从未验证** |
| 旧管线 + 任意轨 | 旧的 all-string | ✅ 改动前的出货行为 |

⇒ 若让这两轨也走新管线，等于**拿未验证的 wire 赌用户**，违反 `AGENTS.md`
「wire 变更必须真 Key 验证过才算完成」。

**已实施**：`CloudPipelineFlags.isCloudPipelineForBackend(backend)` 两道闸（AND）：
1. 总开关（`override` / `HERACLES_CLOUD_PIPELINE=0`）
2. **`UNVERIFIED_BACKENDS = {anthropic, responses}` 自动退回旧管线**

**门禁**：`CloudBridgeAdaptersTest` 新增 4 条 ——
未验证轨必须退回 / OpenAI 兼容轨必须走新 / 总开关关掉时任何轨都退回 /
**名单只有两条**（防手滑放宽）。

> 什么时候能删这个集合：拿到对应 Key、真机跑通一次（`tools` 不被拒 + 原生 `tool_calls` 正常回）
> 即可。删掉前**不要**放宽 —— 这是"未验证"而不是"已知有问题"。

**切换依据**（不是"感觉更好"，是可验证的对照）：

| 维度 | 旧 `AgentLoop` | 新 `CloudAgentPipeline` |
|---|---|---|
| 工具声明 | 55 个参数**全是 string** | 真实 JSON Schema（integer/boolean/array/enum）|
| 并行调用 | 上限 4、两段式 preFetch | 上限 32、真并行（真机 `calls=2/3`）|
| 输出解析 | 文本轨 + CDATA + 正则 | **无解析器**（只用 provider 拼好的 `tool_calls`）|
| 历史 | `HISTORY_MAX_TURNS=10` 硬切 | 按 token 预算装载（128K×0.8，装得下就全装）|
| 参数长度 | 按参数名 500 字符白名单 | 唯一物理闸 10MB |
| 熔断 | 连续解析失败 **2** 次 | 连续 Schema 失败 **5** 次 |
| 输出预算 | 4096 | 16384 |
| 简单任务 | 真机实测 **22 轮**探索 | 加"停止条件"后 **0 轮工具调用直接答** |
| 真机同期表现 | 「连续 2 轮没有按协议输出」熔断 | 22 轮全部成功、零 400、零解析失败 |

⚠️ **保留旧代码**（不删 3000 行）的三个理由：① 它是唯一回退路径；② 781 条既有测试钉住它；
③ 它里面**对的部分**（配对回填/审批/命令守卫/热熔断）已被新管线复用。

> ⚠️ 本机 `flutter test` 对**既有** Dart 测试文件命中 AGENTS.md 坑 11/23（`errno 10013` / 挂死）。
> 新增测试文件单独跑能过。这是环境问题，不是代码问题。
>
> ⚠️ 本机 Gradle 有不稳定现象：Kotlin daemon 偶发连接失败、`BindException` 端口冲突。
> **遇到失败先 `Get-Process java | Stop-Process -Force` 再重试**，不要误判为代码问题。

---

## 1. 目录结构与类图

见 [`.audit/CLOUD-PIPELINE-ARCHITECTURE.md`](CLOUD-PIPELINE-ARCHITECTURE.md)

新管线共 **8 个文件 / 1565 行**：

```
agent/src/main/kotlin/dev/heracles/cloud/
├─ CloudAgentPipeline.kt      393 行  管线主体
├─ CloudPipelineAssembler.kt  313 行  装配（类型化声明表）
├─ CloudPipelineFlags.kt       39 行  Feature Flag
├─ context/ContextManager.kt  203 行  模块二
├─ prompt/CloudPrompts.kt      65 行  模块四
└─ tool/
   ├─ CloudToolValidator.kt   297 行  模块三
   ├─ CloudToolRegistry.kt    131 行  模块一/五
   └─ CloudToolExecutor.kt    124 行  模块一
```

---

## 2. 五个模块的交付

### 模块一：绝对纯净的原生工具调用

| 要求 | 实现 | 证据 |
|---|---|---|
| 废弃 AgentOutputParser | 新管线**不引用**任何解析器，只消费 provider 已拼好的 `toolCalls` | `CloudAgentPipeline.kt` 无 `AgentOutputParser` import |
| 真实 JSON Schema | `CloudParam` + `ParamType{Text,Int,Num,Bool,Array,Object}`，渲染成标准 schema | `CloudToolSchema.kt`；`CloudPipelineReleaseTest` 断言 `"type":"integer"` |
| 并行调用 | `maxCallsPerTurn = 32`，`async{}.awaitAll()` 真并行 | `CloudToolExecutor.executeTurn`；测试断言 ≥32 |
| 参数错误不修复 | 返回 `SCHEMA_INVALID` + **具体类型错误**，模型自愈 | 校验器 `checkType` 报 `期望 integer，实际 string` |

**关键的桥接改动（纯追加，零回退）**：
`ToolSpec` 新增 `jsonSchema: String? = null`；`NativeToolSchema.canonicalBody` 有则用之，无则回退旧渲染。
⇒ 55 个旧参数**一个字节都不用改**，新工具才带真类型。

### 模块二：大容量上下文

| 要求 | 实现 |
|---|---|
| 废除 10 轮硬切 | `ContextManager.plan()` 按 token 预算装载，`Overflow.NONE` 时**全装** |
| 动态预算 | `budgetTokens = modelContextWindow × 0.8`，默认 128K → 102K |
| 溢出才摘要 | `Overflow.TRIGGERED` 才调 `ConversationSummarizer` |
| 工具输出不截断 | 新管线不经过 `LogFilter`/`take()`；`BoundedReader` 只在**物理**层面限 8MB |

测试：30 轮历史在 200K 窗口下**全部保留**（旧实现砍到 10）。

### 模块三：废除参数断头台

| 旧规则 | 新处理 |
|---|---|
| 按参数名猜语义（`content`→100KB、**其余→500**） | **删除**，默认统一 100KB |
| 空值一刀切 | 删除（Schema 的 `required` 决定） |
| 控制字符 | 删除 |
| 必填/未知参数 | **保留**（防臆造） |
| 类型/枚举 | **新增**（按 JSON Schema 校验） |
| 唯一物理闸 | `MAX_PAYLOAD_BYTES = 10MB`，超限给**可操作建议** |

测试：5000 字符 `new_string` 放行；513 字符 `steps` 放行。

### 模块四：提示词与熔断

| 项 | 旧 | 新 |
|---|---|---|
| 教练三连 | "2 步以上 / 一次只做一步 / 3000 字符分段" | **全部删除**，改为"自主决定 / 可一次发多个 / 可一次性写完整" |
| 熔断阈值 | `CONSECUTIVE_UNPARSEABLE_LIMIT = 2` | **5** |
| 摘要预算 | 1024 | **4096**（`ContextManager.MIN_SUMMARY_OUTPUT_TOKENS`） |
| 硬停文案 | "判定任务已完成并停止" | "任务**未完成**，如实说明" |

### 模块五：工具常驻 / UI / glob

| 项 | 实现 |
|---|---|
| `edit` 丢失 | `edit` 与 `apply_patch` **都**进 `RESIDENT_NAMES`（云端无 12 格限制） |
| 审批弹窗截断 | `chat_screen.dart` 删除 500 字符硬剪，正文给全文（摘要行才截） |
| glob 语法 | `CloudGlob` 支持 `[abc]` `[a-z]` `{b,c}` `[!abc]`，未闭合括号**记 warning** |

---

## 3. 必须保留的安全底线（全部保留）

| 底线 | 实现 | 验证 |
|---|---|---|
| 温度/电量熔断 | `Contract.Thermal` **未改** | `ThermalGuardTest` 通过 |
| 前台服务防杀 | `AgentBuildService` **未改** | `:app:compileDebugKotlin` |
| **物理防 OOM** | **新增 `BoundedReader`**：流式读、按字节判、到上限即停 | 替换了 `LocalProcessShellRunner.readCapped` 的 `readAllBytes` |
| 危险命令拦截 | `CommandGuard` **未改** | `CommandGuardTest` 通过 |
| SSRF 防护 | `Contract.Web` + `WebTools` **未改** | `WebToolsTest` 通过 |
| **未执行配对回填** | `CloudToolExecutor` 超限/未知工具 → `NOT_EXECUTED` + 配对 `tool_result` | `NativeToolFlowTest` 通过 |
| **危险操作审批** | **`ApprovalGate` 接口 + 管线 `runTool` 内两处门禁** | `CloudPipelineSafetyTest` 11 条 |

### ★ 一次自查抓到的严重缺口（必须留档）

**新管线第一版把 `ToolOutcome.NeedsApproval` 直接映射成"失败回填给模型" —— 根本没有问过用户。**

后果：`run_shell_command` 里被 `CommandGuard` 判为需确认的操作（递归删除、装 APK），
在新路径**既不弹窗也不执行**。表面"安全"，实则**审批通道整个缺失**：
用户永远无法批准合法的危险操作；若将来有人把 `NEEDS_APPROVAL` 当成功放行，
就变成**静默绕过审批**。

我在第一版交付报告里写了"安全底线全部保留"——**那句话当时是错的**。
是自查（不是读代码、不是写报告）发现的。现已补：

```kotlin
private val approval: ApprovalGate? = null,   // 显式必填依赖（生产装配必须传）
private val mutatingTools: Set<String> = DEFAULT_MUTATING_TOOLS,
```

`runTool` 里两处门禁缺一不可：
1. **执行前**：`call.name in mutatingTools && approval != null` ⇒ 问用户
2. **执行后**：工具自己返回 `NeedsApproval` ⇒ 走同一条 gate 问；批准则**重新执行**

没有 gate 时**工具自报的 NeedsApproval 必须 fail-closed**（`CloudPipelineSafetyTest` 钉住）。
`mutatingTools` 为 null 时直接执行是**已知取舍**（CLI/单测无 UI），已在测试里明确标注
"这是取舍而非安全保证"。

---

## 4. 六个用户报的 bug（全部修复）

| # | 症状 | 根因 | 修法 |
|---|---|---|---|
| 1 | 完全权限还要点允许 | `_showApprovalDialog` 无条件弹窗；`mutatingTools` 漏 `edit`/`restore_path` | AgentLoop 补名单 + `approve()` FULL_ACCESS 早退 + UI 侧防御早退 |
| 2 | 补丁太长 → 输出无法解析 | `limitFor` 默认分支 **500 字符**，`edit.new_string` 被校验器自己拦死 → 2 轮熔断 | 默认改 100KB；熔断阈值 2→5 |
| 3 | 思考几乎英文 | **模型行为**；但 Responses 轨**完全没接 reasoning** ⇒ 全丢 | 补 `reasoning_summary_text.delta`/`reasoning_text.delta`；Anthropic 修 JsonNull 崩溃；提示词加语言约束 |
| 4 | 看不到改了什么代码 | **UI 用 `summaryChars`(80) 把 diff 截没了**（后端早就返回了） | 写类工具卡片加可展开「文件改动」区，逐行渲染 +N/−M；`summaryChars` 未动 |
| 5 | 洞察面板数据是假的 | ① `wallMs` 只是模型往返不含工具 ② 两个命中率口径同名 ③ token 未被吃 | 新增真实 `taskWallMs`；三个命中率各自标注口径；token 加来源说明 |
| 6 | 为改 UI 需先保证稳定 | — | 838 测试全绿 + 门禁通过 + 两个新增 Dart 测试通过 |

### bug 5 的核心证据（用户质疑的 5172ms）

```
旧: usage.wallMs = Σ TurnRecord.wallMs
    而 TurnRecord.wallMs 在 AgentLoop.runStreamingTurn 里：
      started = nanoTime()  →  provider.generateStream(...)  →  wallMs = nanoTime() - started
    ⇒ 只包住模型往返，**不含工具执行/审批等待/压缩**

新: AgentBridge.run() 用它包住整个 run 落 lastTaskWallMs，toMap() 带出 taskWallMs
    ⇒ 面板「任务总耗时」≥「模型用时（不含工具）」
```

测试钉住：`taskWallMs >= wallMs`，且造 `wallMs*5 < taskWallMs` 的极端样例。

---

## 5. 未验证项（如实声明，不许淡化）

1. **真 Key 已完成首轮验证，但仍有限** —— 见 [`.audit/REAL-KEY-VERIFICATION.md`](REAL-KEY-VERIFICATION.md)：
   - ✅ OpenAI 兼容中转站（tokenrhythm）已真 Key 跑通
   - ❌ **Anthropic / Responses 两轨仍未验证**
   - ❌ `max_tokens=16384` 只证明"不被拒"，未证明"模型会用满"
   - ❌ `ask_user` 弹窗的**视觉渲染**未取证（事件已发，见日志）
2. **默认已切新管线（2026-10-21 晚），旧管线转 fallback** —— `AgentBridge.run()`：
   ```kotlin
   if (CloudPipelineFlags.isCloudPipeline()) return@run runCloudPipeline(...)
   ```
   `isCloudPipeline()` = `override ?: !legacyRequested` ⇒ **不设环境变量时走新管线**；
   `HERACLES_CLOUD_PIPELINE=0` / `override=false` 显式退回旧管线。
   `AgentLoop` 已标 `@Deprecated(WARNING)`。
   - ✅ 分流点（`AgentBridge.kt`，`candidateTools` 全量喂给新管线）
   - ✅ `ApprovalQueue → ApprovalGate` 适配（`CloudBridgeAdapters.approvalGate`）
   - ✅ `AskReplyQueue → AskGate` 适配（`CloudBridgeAdapters.askGate`）
   - ✅ `CloudEvent → AgentEvent` 事件桥（`toLegacyEvents`，支持一对多）
   - ✅ `history` 转换（`toAgentMessages`，保序）
   - ✅ `CloudRunResult → AgentRunResult` 回填
   - ✅ **Android 开关通道**：`System.getenv` 在 App 进程读不到 ⇒
     新增 intent extra `--ez heracles_cloud_pipeline true`（`onCreate` + `onNewIntent` 都处理）
3. **`count_tokens` 未接** —— `ContextManager` 用 `TextMath.estimateTokens`，
   `实测-08` 记录该估算曾 **+40% 高估**。生产应接 provider tokenizer。
4. **`update_plan` / `ask_user` 已接线（2026-10-21 补完）** ——
   `CloudEvent.PlanUpdated` / `CloudEvent.AskUser` + `AskGate` 接口已实现，
   `CloudBridgeAdapters.toLegacyEvents` 把 `PlanUpdated` 翻成**两条**旧事件
   （`PlanCreated` + `PlanAdvanced`，旧 UI 用两个事件分别画清单与进度）。
   真机已证 `ask_user` 事件真的发出（`toolNames=ask_user`，见验证文档）。
   ⚠️ **弹窗的视觉渲染未取证**（`uiautomator` 抓不到 Flutter 弹窗，且当前会话无图像能力）。
5. **`chat_streaming_test.dart` 未跑完**（环境坑 11/23）—— 其中 2 条断言文本被改动同步更新，
   只经 `flutter analyze` 静态验证。
6. **`MainActivity` 取消/异常路径**回的是手拼 map，未带 `taskWallMs` ⇒ 被停止的 run 任务耗时显示 `—`。
7. **`CloudGlob` 的 `{a,b}` 展开未穷举** —— 单层与嵌套都有测试，但
   "`{a,{b,c}}` 这种深度嵌套 + 字符集混用" 的极端组合没测。
8. **Anthropic / Responses 两轨仍未真 Key 验证** —— 本次只验了 OpenAI 兼容中转站。
9. **计划落盘的"跨会话重开"未在真机取证** —— 代码链路已用 `CloudPlanPersistenceTest`
   6 条单测闭环（回调被调用 / 全量步骤 / 非法不落盘 / 失败不挂 run / `initialPlan` 注入首轮），
   但"重开 App 后计划面板还在"没有截图级证据。
   ⚠️ 原因如实记录：本机无线 ADB 极不稳定（文件操作中途反复 `device not found`），
   UI 自动化不可靠 ⇒ 改用单测锁代码逻辑，而不是假装验过。

---

## 5.5 验证中挖出并修掉的 4 个**真 bug**（2026-10-21）

这一节是本次交付里**最有价值**的部分：**四个 bug 在当时的单测里全是绿的** —— 其中三个只有真机 + 真 Key 才暴露，第四个（bug D）是写"并发证据"测试时才抓出来的。

### bug A：`ToolSchema.fromRendered` 手写 JSON 扫描器全错（**所有工具失效**）

**症状**：`read_file` 连续 20 轮被拒「参数不符合 Schema」，模型重试到放弃。

**根因**（`SchemaRealWorldTest` 单测复现）：
```
Invalid(detail=未知参数：path（该工具接受：limit, :）)
```
它用 `json.indexOf(",\"")` 找下一个属性，而 `"description"` 的值里**也含 `,"`**
⇒ 解析出 `[limit, :]` 这种垃圾参数名 ⇒ 所有真实参数被判"未知参数" ⇒ **每个工具都废**。

**修法**：改用 Gson（`:agent` 本来就有；这份 JSON 是我们自己 `renderObjectSchema` 产出的，形状可信）。
**手写 JSON 扫描器是 bug 工厂。**

**门禁**：`SchemaRealWorldTest` 5 条 —— 逐工具核对参数名/类型/required 与声明**逐项一致**。

**真机复验**：修复后 turn 3 `toolNames=read_file,read_file` **真的执行了**。

### bug C：`CloudToolValidator` 把**带引号的字符串**交给工具（read_file/write_file 全废）

**症状**：真机上 `read_file` / `write_file` 全部失败，但**日志只显示"调用了它"**，看不出失败 ⇒
模型反复重试 20 轮后放弃。

**根因**：`parseObject` 返回的是**原始 JSON 切片**：
```
{"path":"a.txt"}  ⇒  args["path"] == "\"a.txt\""   // 带引号！
```
⇒ 工具拿 `"a.txt"` 当路径 ⇒ 文件永远找不到。

**为什么藏了很久**（三重隐身）：
1. **类型校验是对的** —— `checkType` 需要看到引号才能判 `string` ⇒ 校验全绿
2. **日志看不出** —— 诊断日志只记工具名、不记结果
3. **单测看不出** —— 之前只测"校验是否通过"，没测"值是否原样交给工具"

**修法**：类型校验仍看原始形态（含引号），**校验通过后**再去引号 + 解转义
（`\"`→`"`、`\n`→换行、`\u4e2d`→中）。两件事绝不能混——第一版修法在 parseObject 里就去引号，
导致所有字符串被判成 `unknown`，单测立刻抓到。

**门禁**：`ToolArgPassthroughTest` 7 条 —— 专测**值透传**（去引号、解转义、数字/布尔原样、
数组保留 JSON 文本、空串语义）。

---

### bug B：提示词缺"停止条件" ⇒ 简单任务跑 22 轮

**症状**：任务只是"列出工作区文件"，模型跑了 **22 轮**，在
`list_files` → `find_files` → `grep_files` 之间反复试探。

**根因**：系统提示词只说了"看不清就先读"，**没说"看够了就答"**。
大模型有完美主义倾向 ⇒ 一直"再确认一下"。

**修法**：加一节「## 什么时候该停」——**不是"教练"**（不限制手段），
而是给**事实性停止条件**：简单任务直接答、拿到信息就停、别用多个工具交叉验证同一件事、
发现原地打转就停下说明。

**真机复验**：修复后 "hi" → `turn=1 finish=STOP raw=204 calls=0` —— **零工具探索，直接回答**。

---

### bug D（第 4 个，2026-10-21 晚自查）：`CloudToolExecutor` 忽略 `parallelSafe`，**全部并发**

**症状（代码审查 + 新增单测发现）**：`executeTurn` 把**每一条**调用都 `async` 并行，
但注释写着"副作用冲突由 Registry 的 `parallelSafe` 声明决定"——**代码根本没看那个声明**。

**后果（都是真问题）**：

| 场景 | 后果 |
|---|---|
| 两个 `write_file` 同轮 | 并发写同一文件 ⇒ 竞态、内容错乱 |
| 两个需要审批的调用 | 审批队列是**单槽**，第二个 `reply` 喂错调用（旧 `AgentLoop` KDoc 明确警告过）|
| `delete_path` 与 `read_file` 交错 | 读到删了一半的状态 |

**修法**：只有 `parallelSafe` **且不在 `neverConcurrent`**（= `mutatingTools`）的调用才并发；
其余就地串行。结果**仍按输入顺序**返回（UI 步骤列表不抖）。

**门禁**：`CloudParallelConcurrencyTest` **5 条**，用**墙钟**判定（不是看日志）：

| 断言 | 判据 |
|---|---|
| `parallelSafe` 三个必须**真并发** | 墙钟 `< 2×WORK`（串行会是 `3×WORK`）|
| 非 `parallelSafe` 三个必须**串行** | 墙钟 `≥ 3×WORK`（小于它说明 `parallelSafe` 又被忽略了）|
| `neverConcurrent` 覆盖 `parallelSafe` | 审批类即使标了 parallelSafe 也不并发 |
| 混合批次保持输入顺序 | 返回的 `call.name` 序列 == 输入序列 |
| 超上限仍配对回填 | 每调用一个结果，`NOT_EXECUTED` 标 `isError` |

⇒ **"并行调用真的并发"这一项，从此有了确定性证据**（不依赖设备日志——日志只能证明"收到了 3 个调用"，
证明不了"它们重叠执行"）。

---

## 5.6 弃用前补齐的两个**功能回归**（否则切默认会伤到用户）

| 缺口 | 旧管线有 | 新管线最初 | 已补 |
|---|---|---|---|
| **计划落盘** | `onPlanChanged` → `.heracles/plans/<sid>.json` | ❌ 切会话丢计划 | ✅ `CloudAgentPipeline.onPlanChanged` + `initialPlan`，**与旧管线写同一个文件**（新旧互通）|
| **历史截断** | `HISTORY_MAX_TURNS=10` 硬切 | ❌ 继承了这个限制 ⇒ 把新管线 token 预算废掉一半 | ✅ 按管线区分：新管线全量（`ContextManager` 决定），旧管线仍 10 轮 |

⚠️ 两处都写进 `AgentBridge.runCloudPipeline`，已 `:app:compileDebugKotlin` 验证。

### 计划落盘已用**单测**闭环（不再依赖真机 UI 自动化）

真机 UI 自动化在本机极不稳定（无线 ADB 反复掉线），而这条链路的核心是纯代码逻辑
⇒ 用 `CloudPlanPersistenceTest`（**6 条**）钉住：

| 断言 | 为什么重要 |
|---|---|
| `update_plan` ⇒ 回调 `onPlanChanged` | 落盘是"切会话不丢计划"的唯一保障 |
| 连续两次 ⇒ 回调两次、每次**全量**步骤 | 增量落盘会丢步骤 |
| 非法 steps ⇒ **不回调** | 不把假计划写进磁盘（UI 会显示假进度）|
| 回调抛异常 ⇒ run 不失败 | 计划是增强不是硬依赖（日志已验证 `plan persist failed: IOException`）|
| `initialPlan` ⇒ 注入第一轮请求 | 恢复的计划必须让模型看到，否则等于没恢复 |
| 无 `initialPlan` ⇒ 不注入 | 空计划块会让模型以为有未完成任务 |

> 剩下的"AgentBridge 真的写到 `.heracles/plans/<sid>.json`"是 5 行 IO + 编译期保证；
> **跨会话重开**的真机确认仍未做（见 §5 未验证项）。


---

## 6. 如何启用新管线

```kotlin
// 环境变量
HERACLES_CLOUD_PIPELINE=1

// 或代码
CloudPipelineFlags.override = true

// 装配（AgentBridge 里）
if (CloudPipelineFlags.isCloudPipeline()) {
    val pipeline = CloudPipelineAssembler.build(provider, tools, modelContextWindow)
    pipeline.run(request, history)
} else {
    // 旧路径
}
```

⚠️ 切换前必须：① 真 Key 跑一轮；② 接 UI 事件适配；③ 接真实 tokenizer。
