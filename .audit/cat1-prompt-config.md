# 类别 1：Prompt 与配置类小模型限制遗迹（只读审计）

> 审计对象：`D:\AllCode\Agent\Heracles`（Kotlin 多模块 + Flutter `app/lib`）
> 审计方式：先按提示词载体（`AgentLoop` / `PrefixBuilder` / `AgentBridge` / `BuildTemplates` / Dart）逐个 `read` 精读，
> 再 grep 严苛措辞与 `max_tokens` / `temperature` / `stop` / `ctx` / 预算常量，最后回到源码行核对行号。
> 忽略 `build/`、`.gradle/`、`.kotlin/`、`.git/`、`.dart_tool/`。
> **本文件是本次审计唯一写入的文件**；仓库代码/配置/文档零改动，未给出任何修改后代码。

---

## 0. 统计摘要

**共 63 处独立发现**：

| 判定 | 数量 | 含义 |
|---|---|---|
| **必删** | **6** | 值/字段/分支已无消费者，且数值来源明确写着"本地能力预检 / llama.cpp / 4096 上下文" |
| **重写** | **28** | 服务对象已不存在或对强模型是**反向教练**：会诱使模型放弃更好的做法，或把真实能力挡在门外 |
| **保留但降级** | **15** | 机制/护栏本身该留，但**依据文案与数值口径**是本地时代，需降级为"工程折中"并去掉 4B/4096 论证 |
| **保留** | **14** | 真·必要护栏（防幻觉、防误执行、网络退避、成本闸），与模型大小无关 |

分节计数：**A 提示词载体 6**（重写 3 / 降级 2 / 保留 1）·
**B 严苛指令 14**（重写 5 / 降级 3 / 保留 6）·
**C max_tokens 12**（必删 2 / 重写 6 / 降级 1 / 保留 3）·
**D 上下文与缓存假设 12**（必删 4 / 重写 4 / 降级 3 / 保留 1）·
**E 其他小模型配置 19**（重写 10 / 降级 6 / 保留 3）。

另有 **21 处已排除的误报**（§G1 三处 `max_tokens=1` 探针 + §G2 十八条看似可疑但合理的实现）
与 **4 处正面证据（已按强模型改好、不要动）**，见 §G。

**判定口径**（本类别核心方法）：

- **(a) 必要护栏** = 防幻觉（编造工具名）、防误执行（猜测性修改）、防格式不可解析、防绕过审批。→ **保留**。
- **(b) 反向教练** = 对 4B "必要的绝对化措辞"在强模型上会**压制它更好的做法**（整文件重抄、一次只做一步、3000 字符分段）。
  判据：`AgentLoop.kt` 自己的 KDoc（`2743-2769`）已经写明判据原文——"那句对 4B 是必要的护栏，对强模型是**反向教练**"。
- **(c) 判定 `必删` 的门槛**：不仅要"看起来是本地值"，还要**证明无消费者**（grep 全仓只有定义处 / 构造参数从未被读 / 分支不可达）。
- **(d) `< 2000` 的 max_tokens 必须区分"探针/心跳"与"真实生成预算"**——本报告把探针全部移入 §G 误报，避免主报告误报。

---

## A. 提示词载体（谁在给模型下指令）

### A1 `DEFAULT_SYSTEM_PROMPT` —— 三句话的身份声明（`AgentLoop.kt:2735-2738`）

```kotlin
const val DEFAULT_SYSTEM_PROMPT =
    "你是 Heracles，一个运行在手机上的开发助手。" +
        "你可以读写工作区里的文件来帮用户完成开发任务。" +
        "先看清现状再动手；不确定项目结构时先用 list_files。"
```

- 作用：唯一进冻结前缀的身份/边界说明。工具用法**全部下沉到工具描述与工具协议**，系统提示刻意极简。
- 判定：**保留但降级**（置信度 中）。极简本身不是小模型限制（强模型不需要长系统提示），
  但它是"4B 时代整份提示词只有 760 字、其余靠工具描述兜"的产物（见 `2745-2749` 关于已删本地档的说明）：
  现在没有任何一句告诉模型"这是 Android 上的编码 agent / 有 shell / 有审批档位 / 无网络假设"，这些信息只散落在工具描述里。

### A2 压缩摘要提示（`AgentLoop.kt:1228-1232`）

```kotlin
append("以下是你（助手）与用户此前的完整交互记录。请把它压缩成一段**供你自己后续使用**的摘要，")
append("必须保留：任务目标、已创建/修改的文件路径及各自状态、关键结论与数据、尚未完成的步骤。")
append("不要寒暄，直接输出摘要正文。\n\n")
```

- 作用：上下文压缩时让模型自摘要，摘要作为新会话的 `Turn.System`（`1252-1261`）。要求保留哪些字段，是**正向教练**。
- 判定：**保留**（置信度 高）。它是"告诉模型要保留什么"，不是"禁止模型做什么"。
  提示词本身没有本地痕迹；**真正的遗迹在它的输出预算 1024**（见 C3）。

### A3 冻结区工具清单表头：`仅以下这些，不得编造工具名`（`core/.../context/PrefixBuilder.kt:70`）

```kotlin
sb.append("\n\n## 可用工具（仅以下这些，不得编造工具名）\n")
```

- 作用：冻结区里工具 schema 的总标题，**每个会话固定发一次**。
- 判定：**重写**（置信度 高）。前半句"不得编造工具名"是必要护栏；**"仅以下这些"与长尾披露机制直接矛盾**：
  `search_tools` 命中后会把长尾工具变可用（`agent/.../tools/MetaTools.kt:122-131`、`AgentLoop.kt:565-567`），
  而冻结区永久声明"只有以下这些"。这是文本轨时代"冻结区=全部工具"的假设，
  在 ADR-023 两段式披露之后没跟着改 ⇒ 模型会**自己否掉刚被披露的工具**。这是配置层的**逻辑矛盾**，不是措辞问题。

### A4 解析失败纠正提示：`只输出其中一种，不要任何解释`（`AgentLoop.kt:2143-2152`）

```kotlin
"上次输出无法按协议解析：${parsed.detail}。\n" +
    "只接受三种顶层形状（**顶层键**必须是下列之一）：\n" +
    "· 计划：{\"plan\":[\"步骤一\",\"步骤二\"]}\n" +
    "· 调工具：{\"tool\":\"工具名\",\"args\":{…}}" + … +
    "只输出其中一种，不要任何解释。"
```

- 作用：`AgentOutput.Unparseable` 分支的纠正提示（真机教训见 `2137-2142`：空泛的"请严格按格式"救不了形状漂移）。
- 判定：**重写**（置信度 中）。这条提示是**文本轨专属**（三种 JSON 顶层形状），
  而原生轨下"正文=普通文字最终回答"是合法路径（`1474-1476`）。虽然原生轨正常不会走到 Unparseable，
  但一旦走到（例如模型输出半截 JSON），框架会**教它退回文本方言**——与 `TOOL_PROTOCOL_NATIVE:2849`
  "不要用 JSON / 标签去描述调用"正面冲突。应按 `nativeToolsEnabled` 分流文案。

### A5 工作记忆台账（`AgentLoop.kt:726-755`）

```kotlin
append("【你已经完成的工作（真实执行记录，不要重新做）】\n")
…
append("\n请基于以上进度继续。**不要重复已经成功的操作**；")
append("如果下一步需要的文件已经读过，直接用它；")
append("如果任务已完成，直接输出 {\"final\":\"<对用户的总结>\"}。")
```

- 作用：每轮把 `records` 渲染成事实回喂模型（修"第 3/4 轮思考极度相似"，见 `690-725`）。
- 判定：**保留但降级**（置信度 中）。"不要重新做"修的是 4B 原地打转；
  对强模型，"已经读过就直接用"会**挡住合理的重读**（文件可能被它自己上一步改过、或被用户外部改动）。
  另外最后一句仍要求 `{"final":…}` JSON 信封，与原生轨的"普通文字收尾"并存（`2860` 已兼容两者，但台账只给 JSON 一种）。

### A6 计划渲染文本：`请只做当前进行中那一步`（`agent/.../TaskPlan.kt:78-90`）

```kotlin
fun render(): String = buildString {
    append("【当前任务计划与进度】\n")
    …
    append("\n请只做**当前进行中**的那一步；做完继续下一步。")
}
```

- 作用：每轮把计划 append 成 `Turn.User`（`AgentLoop.kt:1336`），是"现在该干第几步"的唯一来源。
- 判定：**重写**（置信度 中）。"只做当前那一步"对 4B 是防它乱跳步；对强模型是**人为串行化**，
  与 `Contract.Tools.MAX_NATIVE_CALLS_PER_TURN = 4`（一次发多个独立调用）在同一轮里互相打架（见 B12）。

---

## B. 严苛指令逐条判定（`TOOL_PROTOCOL_CLOUD` / `TOOL_PROTOCOL_NATIVE`）

> 载体：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt`。
> `TOOL_PROTOCOL_CLOUD` 在 **2770-2822**（文本轨），`TOOL_PROTOCOL_NATIVE` 在 **2846-2872**（原生轨）。
> 两档只在 `nativeToolsEnabled` 上二选一（`479-480`），不会同时进请求体。

### B1 `输出格式（三种，不要输出任何其它内容）`（`:2771`）

- 判定：**保留但降级**（高）。文本轨靠正文解析，禁止额外文字是**可解析性**要求，不是小模型限制。
  但"不要输出任何其它内容"会让强模型**连一句"我要做什么"都不写**，用户看到的是黑箱；
  原生轨已经放开这一点（`2851`），文本轨应写成"除上述三种形状外不要添加可被误解析的 JSON"，而不是全面禁言。

### B2 `只在开始时给一次`（计划 JSON 形式）（`:2773`）

- 判定：**重写**（中）。原文：`① 任务需要多步时，**先给计划**（只在开始时给一次）：`。
  它描述的是**旧机制**（首轮一次性 `{"plan":…}`，之后无法修改）。`2808` 与 `2865` 又要求"用 `update_plan` 工具可反复改"，
  ⇒ 同一份协议里"只给一次"和"每步必须改"并存，模型读到的是两条互斥指令。这一条是 `update_plan` 上线前的遗留。

### B3 `拿到任务先分析，再给计划`（`:2807`）

- 判定：**保留**（高）。这是"先想后做"的正向流程要求，与模型大小无关。

### B4 `计划要给 2 步以上`（`:2809`、`:2864`）

```text
- 计划要给 **2 步以上**，每步是一句可执行的话
```

- 判定：**重写**（高）。对 4B，强制多步能逼它产出待办；对强模型，**一句话任务（"把 README 的错别字改了"）
  也被迫编出 2 步以上计划**，制造无意义轮次与 token。原文两处重复（文本轨/原生轨各一份）。

### B5 `一次只做当前那一步`（`:2810`、`:2865`）

```text
- 给出计划后，**一次只做当前那一步**；**每完成一步必须调用 `update_plan`** 把该步标 `done`、
```

- 判定：**重写**（高）。这是本类别**最典型的反向教练**：强模型天然会"读文件 + grep + 改文件"一次做完，
  这条把它钉成一轮一步。它与 `MAX_NATIVE_CALLS_PER_TURN = 4`（`Contract.kt:197`，一次最多 4 个原生调用）
  和 `TOOL_PROTOCOL_NATIVE:2852`（"互不依赖的操作可以一次发多个"）**直接冲突** ⇒ 模型收到矛盾指令。

### B6 `每完成一步必须调用 update_plan`（`:2810-2811`、`:2865-2866`）

```text
- 给出计划后，**一次只做当前那一步**；**每完成一步必须调用 `update_plan`** 把该步标 `done`、
  下一步标 `active` —— 进度条**只认你显式给的状态**，不会因为"某个工具成功了"自动勾（那会撒谎）
```

- 判定：**保留**（高）。原文紧跟一句解释："进度条**只认你显式给的状态**，不会因为'某个工具成功了'自动勾（那会撒谎）"。
  这是 UI 契约（真机教训见 `AgentLoop.kt:2115-2125`），不是模型能力假设。

### B7 `改代码优先局部替换 / 不要为改一行重写整文件`（`:2812-2814`、`:2867-2868`）

- 判定：**保留**（高）。**这正是已经按强模型改好的地方**——`2743-2769` 的 KDoc 明确写：
  去掉了"每次都写全，不要只写片段"这种绝对化措辞，因为"那句对 4B 是必要的护栏，对强模型是**反向教练**"。
  同段还写明代价（改文案 = 首次 prefix cache miss 一次）。属于**正面证据**，不要在清理时误删。

### B8 `单个文件超过约 3000 字符时分几次写`（`:2815-2816`、`:2869`）

```text
- 单个文件很大（超过约 3000 字符）时**分几次**写：先写骨架，再用 `apply_patch` 增量补齐，
  不要每一轮都把整个文件重新写一遍
```

- 判定：**重写**（高）。3000 字符 ≈ 一个 4B 单轮能稳妥吐出的量；GPT-4o 级模型单次输出上限远大于此。
  "分几次写"会制造**中间态半截文件**（若下一轮失败，工作区留下不可编译的骨架），
  而它要防的症状（输出被上限截断）在 `finishReason=LENGTH` 已被如实上报之后**不该用提示词硬防**。

### B9 `不确定文件内容时先 read_file，不要凭猜测修改`（`:2817`、`:2854`）

```text
- 不确定文件内容时先 read_file 看清，不要凭猜测修改          （文本轨 :2817）
- 不确定文件内容时先 `read_file`，不要凭猜测修改            （原生轨 :2854）
```

- 判定：**保留**（高）。抗幻觉的**必要护栏**，与 AGENTS.md "抗幻觉必须由架构保证、不得依赖提示词"并列成立（这里是提示词+工具白名单双保险）。

### B10 `不要编造工具名；只能使用上面列出的工具`（`:2818`）

- 判定：**保留但降级**（高）。防幻觉必要；但"上面列出的"在冻结区里只含常驻工具（`PrefixBuilder.kt:70`），
  被 `search_tools` 披露的长尾工具不在"上面" ⇒ 与 A3 同一处矛盾，措辞需改为"可用工具 = 常驻 + 已披露"。

### B11 `系统每轮都会告诉你「你已经完成的工作」——不要重复已完成的操作`（`:2820-2821`、`:2871`）

- 判定：**保留但降级**（中）。它修的是真机重复循环（`实测-08`：目标达成后仍重复 5 次）。
  但对强模型，"不要重复"会与"验证性重读/重跑测试"冲突（重跑同一个测试是**合法且必要**的）。
  应改为"完成后不要重复**写**操作；读/验证可以重做"。

### B12 `互不依赖的操作可以一次发多个工具调用（最多 4 个）`（`:2852`）

```text
- **互不依赖**的操作可以一次发**多个**工具调用（最多 4 个，系统会依次执行）；
  有依赖就分轮 —— 拿到上一个结果再决定下一步
```

- 判定：**重写**（高）。这句话本身是**正向的**（鼓励批处理），问题在"最多 4 个"写死在**提示词**里，
  真值在 `Contract.Tools.MAX_NATIVE_CALLS_PER_TURN`（`Contract.kt:197`）——典型**两处真相**；
  且它与 B5/B4 矛盾（见 B5）。第二个问题是 `NativeSkip.PARALLEL = "本实现一次只支持一个原生工具调用"`（`AgentLoop.kt:2899`）
  是一条**双重过期的死常量**：v2 已支持 4 个并发（`1875-1893`），而 grep 全仓 `NativeSkip.PARALLEL` **只有定义处、0 引用**
  （其余引用是 `LOOP`/`VALIDATION`/`BUDGET`）⇒ 既没人用、文案又已是假话。

### B13 `不要寒暄，直接输出摘要正文`（`:1231`）

- 判定：**保留**（高）。摘要要作为新会话的 `Turn.System` 原文使用，寒暄会污染后续上下文。

### B14 `需要动工具时：直接发起工具调用，不要用 JSON / 标签去"描述"调用`（`:2849-2850`）

```text
- 需要动工具时：**直接发起工具调用**，不要用 JSON / 标签去"描述"调用
  （那些**不会**被执行，只有真正的工具调用才会）
```

- 判定：**保留**（高）。ADR-031 "原生优先"的硬前置——两套语法并存时模型会把调用写进正文而被忽略（静默失败）。
  这是**架构性**要求，不是模型能力假设。

---

## C. max_tokens / 输出预算（凡 < 2000 必标，并区分探针与真实生成）

> 生产链路：`AgentBridge` 构造 `AgentLoop` 时**不传 `maxOutputTokens`**（`app/.../bridge/AgentBridge.kt:469-534` 的 `AgentLoop(...)` 里没有该参数；
> 全仓 grep `maxOutputTokens` 在 `app/android` 下 0 命中）⇒ **发行版恒为默认 4096**。

| # | 文件:行号 | 代码摘录 | 作用 | 判定 | 置信度 |
|---|---|---|---|---|---|
| C1 | `agent/.../AgentLoop.kt:183` | `private val maxOutputTokens: Int = 4096,` | 每轮真实输出预算（思考+正文共享），发行版唯一来源 | **重写**：4096 的依据里"远小于云端上限""本地由调用方传小值"都过时；强模型 + 思考模型下 4096 仍会`LENGTH`截断（KDoc `159-182` 自己记过 1024 被思考吃光，4096 只是把阈值挪高） | 中 |
| C2 | `agent/.../AgentLoop.kt:784-793` | `LOW -> base * 2` / `HIGH -> base * 3` / `MAX -> base * 4` … `coerceAtMost(MAX_OUTPUT_TOKENS_CAP)` | 按推理档位放大输出预算 | **重写**：倍数阶梯是为"思考吃光预算"打的补丁（`765-782`），且注释里仍写"本地 llama.cpp 的上下文只有 4096——输出预算过大会挤压输入"（`779`）；4096×4=16384 才等于强模型的常规单轮 | 中 |
| C3 | `agent/.../AgentLoop.kt:1238` | `maxOutputTokens = 1024,` | **压缩摘要**的真实生成预算（一次额外 provider 调用） | **重写**：这是 <2000 的**真实生成预算**（不是探针）。摘要把整段历史压成一段话，1024 token 对"任务目标+文件路径+未完成步骤"通常不够 ⇒ 摘要被截断 ⇒ 新会话从残缺摘要重启（且 `1244` 无论成败都标记 `compacted=true`，不会再压第二次） | 高 |
| C4 | `core/.../contract/Contract.kt:611` | `const val DEFAULT_MAX_OUTPUT_TOKENS = 96` | 声称是 Anthropic 的缺省 `max_tokens` | **必删**：KDoc 自述"原先是**能力预检**的输出上限（本地 GBNF 时代，压低以早停省 decode）"（`603-610`），且全仓**无消费者**（grep `DEFAULT_MAX_OUTPUT_TOKENS` 仅定义处 + `AnthropicProvider.kt:91` 的构造默认值） | 高 |
| C5 | `provider-http/.../AnthropicProvider.kt:91` | `private val maxTokensForMessages: Int = Contract.Provider.DEFAULT_MAX_OUTPUT_TOKENS,` | 构造参数 | **必删**：该参数**从未被读**（grep `maxTokensForMessages` 全仓仅此 1 行），请求体走的是 `request.maxOutputTokens`（`:267`）。值 96 是本地探针遗物，留着会让人以为 Anthropic 默认只给 96 token | 高 |
| C6 | `provider-http/.../AnthropicProvider.kt:267` | `addProperty("max_tokens", maxOf(maxOutputTokens, 1))` | Anthropic 必填字段（≥1） | **保留**：`maxOf(...,1)` 是协议下限兜底，不是预算压缩 | 高 |
| C7 | `provider-http/.../OpenAiCompatProvider.kt:457` | `addProperty("max_tokens", maxOutputTokens)` | OpenAI 兼容轨的预算直传 | **保留**：无二次截断，值由上层决定（问题在 C1） | 高 |
| C8 | `provider-http/.../OpenAiResponsesProvider.kt:318` | `addProperty("max_output_tokens", request.maxOutputTokens)` | Responses 轨的预算直传（`max_tokens` 会 400） | **保留**：字段名正确；值同样由上层决定 | 高 |
| C9 | `core/.../contract/Contract.kt:643-661` | `const val MAX_OUTPUT_TOKENS_CAP = 16_384` | 档位放大后的硬上限 | **保留但降级**：数值本身合理（强模型 16K 不算大），但取值依据整段是本地算式（`650` "本地 llama.cpp（4096 上下文）输入被挤到无处安放"、`658` "本地后端由调用方显式传小值（`maxOutputTokens = 1024`）"）——**依据已失效**，值可留 | 中 |
| C10 | `app/lib/models/settings.dart:236`（生产点 `:227`/`:246`/`:253`；采集点 `screens/settings_screen.dart:1244`、`screens/chat_screen.dart:1950`） | `final int? maxOutputTokens;` | 服务端上报的**单次输出上限**，被拉取并持久化 | **重写**：全链路**只存不用**——Kotlin 侧 `GenerateRequest.maxOutputTokens` 没有一处读它（grep `maxOutputTokens` 在 `app/android` 0 命中）。强模型的真实输出上限（中转站常给 384000）被采集后丢弃，请求恒用 4096 ⇒ 采集成本白付、能力白丢 | 高 |
| C11 | `app/android/.../bridge/SessionStore.kt:59-71` | `const val STEP_TEXT_LIMIT = 4000`，KDoc：`4000 字符 ≈ 2800 token … 它大于本地单轮的输出预算（max_tokens 512）` | 单步过程落盘上限（思考/正文各 4000 字符） | **重写**：理由**只对 512 成立**；今天单轮预算是 4096 起步（思考档位可达 16384），4000 字符会**截断正常的一轮思考**（截断本身如实标 `truncated`，不是数据安全问题，但理由是遗迹） | 高 |
| C12 | `app/android/.../bridge/AgentBridge.kt:1236-1244` | `const val MAX_ATTACHMENT_CHARS = 8000`，KDoc：`8000 字符 ≈ 3000 token —— 已经占掉上下文预算的相当一部分` | 单个文本附件注入上限 | **重写**：3000 token 对 128K 云端上下文是 2.3%，"占掉相当一部分"是 4096 时代口径；用户传一份 20KB 日志被静默切掉（`895-897` 有"已截断"标注，但额度本身过紧） | 中 |

**`< 2000` 清单（本类别全部命中项）**：

| 值 | 位置 | 性质 | 处置 |
|---|---|---|---|
| **1024** | `AgentLoop.kt:1238` | **真实生成预算**（压缩摘要） | 见 C3，**重写** |
| **96** | `Contract.kt:611` + `AnthropicProvider.kt:91` | **死值**（能力预检遗物，无消费者） | 见 C4/C5，**必删** |
| **1** | `OpenAiCompatProvider.kt:142`、`:174` | **探针/预热**（`load()` 探活、`prewarm()` 建缓存键） | **§G 误报**，保留 |
| **1** | `app/lib/screens/settings_screen.dart:1701` | **探针**（"测试连接"按钮 `max_tokens:1`） | **§G 误报**，保留 |
| **4096** | `AgentLoop.kt:183` | 真实预算（≥2000，但仍是发行版唯一值） | 见 C1，**重写** |

---

## D. 上下文窗口 / 缓存块 / token 估算假设

### D1 `Contract.Context.DEFAULT_CTX = 4096`（`core/.../contract/Contract.kt:51-52`）—— **必删**

```kotlin
/** 本地后端默认上下文长度（实测：4096 下内存已紧张） */
const val DEFAULT_CTX = 4096
```

- 唯一消费者是 `ProviderConfig.contextSize`（`core/.../provider/ModelProvider.kt:80`），而 `ProviderConfig` 在云端路径上只以 `ProviderConfig()` 空构造出现
  （`AgentBridge.kt:224`、测试大量如此）⇒ 这个 4096 **唯一真实用途**落在 D2 的死分支里。
- 判定：**必删**（高）。注释自述是本地 llama.cpp 内存实测值；本地后端已随 ADR-035 删除。

### D2 `contextLimitTokens()` 的本地分支不可达（`app/.../bridge/AgentBridge.kt:835-837`）—— **必删**

```kotlin
fun contextLimitTokens(isCloud: Boolean): Int =
    if (isCloud) Contract.Context.DEFAULT_CLOUD_CTX
    else ProviderConfig().contextSize
```

- 调用点只有两处：`AgentBridge.kt:526` 传 `backend != "local"`（`backend` 只可能是 `cloud`/`anthropic`/`responses`，见 `194-222`）⇒ **恒 true**；
  `MainActivity.kt:1589` 由 Dart 传 `isCloud`，而 Dart 侧已硬编码 `const isCloud = true`（`app/lib/screens/chat_screen.dart:1991`）。
- 判定：**必删**（高）。`else` 分支 + 4096 是一对**不可达的本地残留**，但 KDoc（`809-834`）仍在教人"本地 4096 / 云端 128K"。

### D3 `ProviderConfig` 的三个本地字段（`core/.../provider/ModelProvider.kt:76-86`）—— **必删**

```kotlin
data class ProviderConfig(
    // --- 本地 ---
    val modelPath: String? = null,
    val contextSize: Int = Contract.Context.DEFAULT_CTX,
    val threads: Int = Contract.Inference.DEFAULT_THREADS,
    // --- 云端 ---
```

- 判定：**必删**（高）。标注自己就是"--- 本地 ---"：`modelPath`（GGUF 路径）、`threads`（CPU 线程）在云端路径上**永远为 null/默认**且无消费者；
  `contextSize` 只被 D2 的死分支读。保留它们等于让 `:core` 契约继续为已删除的后端留接口。

### D4 `DEFAULT_THREADS = 4` / `DEFAULT_SLOT = 0`（`core/.../contract/Contract.kt:636-641`）—— **必删**

```kotlin
/** 实测最优：4 线程（6/8 线程反而更慢） */
const val DEFAULT_THREADS = 4
/** 单 slot 串行（并发会打散 slot 亲和性，违反铁律 1） */
const val DEFAULT_SLOT = 0
```

- 判定：**必删**（高）。`:636` 段落头写着"推理 —— ADR-011、`实测-01`"，这是 **llama.cpp 的 CPU 线程数 / slot 号**；
  `DEFAULT_THREADS` 唯一消费者是 D3 的 `ProviderConfig.threads`，`DEFAULT_SLOT` **全仓 0 消费者**（grep 仅定义处）。云端是 HTTP 调用，这两个概念不存在。

### D5 GBNF 能力位与语法规格仍在 `:core` 契约（`core/.../provider/ModelProvider.kt:32`、`:93-94`）—— **重写**

```kotlin
/** 是否支持 GBNF 语法约束（llama.cpp 支持；云端一般不支持） */
val supportsGrammar: Boolean,
…
/** GBNF 语法（llama.cpp 强约束；云端需降级） */
data class Grammar(val gbnf: String) : StructuredSpec
```

- 判定：**重写**（中）。三家云端 provider 全填 `supportsGrammar = false`（`AnthropicProvider.kt:97`、`OpenAiCompatProvider.kt:91`、`OpenAiResponsesProvider.kt:77`），
  `StructuredSpec.Grammar` 仅剩 `OpenAiCompatProvider.kt:526-530` 的"降级成 `json_object`"分支可达。
  它们不是"小模型限制"的**行为**，而是**词汇表**残留：契约层继续把 GBNF 当成一等概念，读代码的人会以为它还在用。

### D6 `ToolValidator` 仍以 GBNF 为分工前提（`core/.../tool/ToolValidator.kt:6-14`、`:30-33`）—— **重写**

```kotlin
| GBNF 语法 | 输出的**形状**（字段名、类型、工具名在集合内） | 服务端配置问题 |
| 本对象 | 输出的**语义**（必填参数齐全、值合理） | 模型判断问题 |
…
"工具 ${call.tool} 不在可用集合中（语法层本应拦住，说明 GBNF 未生效）"
```

- 判定：**重写**（中）。今天**没有 GBNF**（ADR-035），工具名白名单事实上由 `AgentOutputParser.parse(knownTools)`（`AgentOutputParser.kt:86-101`）与原生 `tools` 数组保证。
  若真机打到这条 `Invalid`，错误文案会把排查引向"GBNF 未生效"——一个已不存在的组件（假线索）。

### D7 `buildFrozenAligned` 的 `cacheBlockTokens` 默认 1（`core/.../context/PrefixBuilder.kt:105-114`）—— **重写**

```kotlin
 *   **本地 llama.cpp 传 1**（token 级精确，不需要补齐，避免浪费 token）。
…
fun buildFrozenAligned(…, cacheBlockTokens: Int = 1, …): FrozenPrefix {
```

- 判定：**重写**（中）。默认值 1 的语义是"不补齐"（`117`），它存在的理由是本地后端 token 级精确。
  今天两个云端 provider 分别传 1024（`OpenAiCompatProvider.kt:76`）与 0（`AnthropicProvider.kt:104`、`OpenAiResponsesProvider.kt:81`），
  默认 1 只在测试里生效 ⇒ 建议默认改成"必须显式给"，否则将来新 provider 忘传时会**静默不补齐**（命中率 0 的旧坑）。

### D8 `PrefixAligner.CLOUD_CACHE_BLOCK_TOKENS = 1024` + `SAFETY_MARGIN = 1.3`（`core/.../context/PrefixAligner.kt:42-64`）—— **保留但降级**

```kotlin
const val CLOUD_CACHE_BLOCK_TOKENS = 1024
…
private const val SAFETY_MARGIN = 1.3
```

- 判定：**保留但降级**（中）。数值是**实测值**（DashScope 1024 块，`实测-07`），且有真实代价算式（补多花输入 vs 命中 0）——不是小模型限制。
  但 KDoc 里"本地 llama.cpp 是 token 级精确，不需要对齐"（`:46`）与 `TextMath` 的估算误差（曾高估 40%）都是本地时代取证；
  换 provider 必须重测这条纪律仍在（`OpenAiCompatProvider.kt:73-76` 有交叉引用）。

### D9 `TextMath.estimateTokens` 的系数按 Qwen 校准（`core/.../text/TextMath.kt:40-59`）—— **重写**

```kotlin
 * 修正后的系数（按 732/1027 反推）：
 * - CJK ≈ 0.7 token / 字（Qwen 对中文压缩得比预期好）
 * - 其它 ≈ 1 token / 3.5 字符
```

- 判定：**重写**（中）。它同时喂**压缩触发**（`Session.estimatedPromptTokens`，`Session.kt:94`）与**块对齐**（`PrefixAligner.kt:81`），
  而系数是 `Qwen3.5-4B` + llama-server 分词器反推的。换成 GPT-4o/Claude 系分词器后偏差方向未知 ⇒ 压缩可能过早或过晚。
  Dart 侧还有一份**同系数复制**（`app/lib/models/session_usage.dart:242-256`），同样是 Qwen 口径。

### D10 `COMPACTION_TRIGGER_RATIO = 0.80`（`Contract.kt:48-49`）—— **保留**

- 判定：**保留**（高）。是**比例**不是绝对 token，与模型无关；配 `DEFAULT_CLOUD_CTX = 128_000` 时在 102K 触发，合理。
  （`:63-64` 提到的"4K 触发→过早压缩"是当年把 4096 当全局默认的 bug，已由 D11 修掉。）

### D11 `DEFAULT_CLOUD_CTX = 128_000`（`Contract.kt:54-76`）—— **保留但降级**

- 判定：**保留但降级**（中）。128K 是"主流云端保守下限"（GPT-4o 128K / DeepSeek 128K / Claude 200K / Qwen-Max 128K），
  这个论证今天仍成立；但它对 1M 上下文的模型仍会**低估上限**（用户实测过 1M 模型显示"已用 56%"的 bug），
  真正解是 C10 那条断线的 capabilities（`contextWindow` 已采集但只在 UI 显示用，没进 `AgentLoop.contextLimit`）。
  ⇒ 值可留，口径要改成"仅在没有服务端上报时兜底"。

### D12 Dart `const isCloud = true`（`app/lib/screens/chat_screen.dart:1987-1991`）—— **保留但降级**

```dart
// ★ 2026-10-18（ADR-035 S4）：本地后端已删除 ⇒ **恒为云端**。
const isCloud = true;
```

- 判定：**保留但降级**（高）。代码诚实（删干净了），但参数还留着 `contextLimitTokens(isCloud:)` 的布尔通道（`AgentBridge.kt:835`、`agent_bridge.dart:172`），
  一路传到 Kotlin 再进 D2 的死分支。是"为已删后端保留的接口形状"，应随 D2 一起收口。

---

## E. 其他小模型时代配置

### E1 **扁平标量 schema：所有工具参数都被声明成 `string`**（`core/.../tool/ToolSpec.kt:3-13`）—— 重写（最高优先级之一）

```kotlin
 * **只允许扁平标量** —— 嵌套对象是小模型填错的头号来源（`02-契约规范.md` §4.2）。
```

- 事实核查：全仓 `ToolParam(...)` 的 `type` 参数**全部是 `"string"`**（`agent/.../tools/*.kt` 逐个读过；`AgentOutputParser.parseArgs` 也"值一律按字符串处理"，`AgentOutputParser.kt:239-250`）。
  连布尔/整数参数也被字符串化：`replace_all`（`PatchTools.kt:80-84`）、`timeout_sec`（`ShellTools.kt:88-93`）、`max_results`（`FsSearchTools.kt:155-159`）。
- 判定：**重写**（高）。理由：这既是**小模型限制的化石**（"嵌套对象是 4B 填错的头号来源"），
  又会在**原生 function calling** 下产生真实退化 —— 发出的 JSON Schema 里 `timeout_sec` 是 `{"type":"string"}`，
  强模型会照 schema 填 `"120"` 而不是 `120`，并且无法用 enum/integer 约束；`ToolValidator.kt:109-115` 的按参数名限长也因为"一切都是字符串"而不得不存在。
  这条不是提示词文案问题，是**工具契约形状**问题，属本类别最值得重写的一处。

### E2 参数长度上限按参数名区分（`core/.../tool/ToolValidator.kt:109-141`）—— 保留但降级

| 常量 | 值 | 依据（原文） | 判定 |
|---|---|---|---|
| `MAX_ARG_VALUE_LENGTH` | **500** | "联系人名、搜索关键词、应用名都远短于它；模型失控时最容易的表现就是无限续写同一个参数" | **保留但降级**（中）：数额合理，但"模型失控"是 4B 口径；对强模型应改为"路径/关键词上限"（语义命名），而不是"通用兜底" |

（同文件 `MAX_COMMAND_LENGTH = 4000`、`MAX_CONTENT_LENGTH = 100_000` 依据是真实设备命令长度与源文件体量，**保留**。）

### E3 工具数量三道上限 `12 / 24 / 6`（`core/.../tool/ToolRegistry.kt:10-21`、`contract/Contract.kt:139-176`）—— 保留但降级

```kotlin
 * 旧值 **8 / 12 / 3** 是**为本地 4B + 4096 上下文**定的（契约 §4.1：可见工具数过 ~10 后
 * 4B 的选择准确率显著下降），随本地一起退场
…
const val FROZEN_LIMIT = 12
```

- 判定：**保留但降级**（中）。值已从 8/12/3 放宽到 12/24/6（正确的方向），但**论证仍是"4B 实测 + 云端阈值更宽"**
  （`ToolRegistry.kt:15`、`AndroidTools.kt:27-28`、`MetaTools.kt:55`、`ToolZonePlan.kt:44`）。
  对 GPT-4o 级模型，12 个常驻工具的"选择准确率"担忧基本消失，而 12 格已经**顶满**（`ToolZonePlan.kt:96-100`：11 业务 + `search_tools` = 12/12），
  ⇒ 新增任何常驻工具都要先挪走一个。这是"本地 8 格"天花板放宽后**还没重新审视**的配置。

### E4 `MAX_IDENTICAL_TOOL_CALLS = 2`（`agent/.../AgentLoop.kt:2708-2716`）—— 重写

```kotlin
 * 设为 2 的依据：首次端到端实测中模型
 * 在目标已达成后仍重复了 5 次（`实测-08`）。给 1 次宽容
 * （可能是合法的重试），第 2 次就判定为循环。
const val MAX_IDENTICAL_TOOL_CALLS = 2
```

- 判定：**重写**（中）。依据是一次 **4B** 的端到端实测。对强模型，"完全相同的调用出现第 2 次"经常是**验证**
  （重跑 `build_apk`、重读被自己改过的文件）。计数逻辑已修好"失败重试不计数"（`2688-2706`），但"成功后再做一次"仍被硬停 ⇒ 会打断验证闭环。

### E5 `CONSECUTIVE_UNPARSEABLE_LIMIT = 2`（`AgentLoop.kt:2718-2733`）—— 保留但降级

```kotlin
 * 用户真机实测：正文恒为空、连续 4 轮「输出无法解析」，
 * 每轮 100+ 秒（本地 llama.cpp 把 max_tokens 全烧在思考上，
 * `content` 为空 —— 根因是请求没带 `enable_thinking=false`，
const val CONSECUTIVE_UNPARSEABLE_LIMIT = 2
```

- 判定：**保留但降级**（中）。熔断本身必要（"重试救不了系统性失败"），但**依据的根因已随 ADR-035 消失**
  （`enable_thinking` 已删、云端不强制 JSON 信封、原生轨纯文本即最终回答 `1474-1476`）。
  今天 2 连击熔断更可能误杀"模型在长思考后吐了半截 JSON"，依据应改为"格式漂移的经验阈值"。

### E6 三个任务预算（`Contract.kt:561-581`）—— 保留

```kotlin
const val MAX_TURNS = 40
const val MAX_TOOL_CALLS = 120
const val MAX_CONSECUTIVE_FAILURES = 6
```

- 判定：**保留**（高）。这是**已经按强模型放宽过**的一组（8→40、30→120、3→6），
  且 KDoc 明确写"⚠️ 8 → 40 是工程判断，不是实测结论"（`559`）——诚实。唯一遗留是 `578` 的"比本地时代的 3 宽一档"仍在引用本地口径（可接受，是历史说明）。

### E7 429/5xx 退避重试（`Contract.kt:613-632`）—— 保留

```kotlin
const val RETRY_MAX_ATTEMPTS = 2
const val RETRY_BASE_DELAY_MS = 600L
```

- 判定：**保留**（高）。手机网络 429/5xx 是常态，且三条边界（只重试未吐内容的、只重试 `retryable`、最多 2 次）写在契约里（`618-628`）。
  与模型大小无关。

### E8 `temperature = 0` 由 OpenAI 兼容 provider 注入（`provider-http/.../OpenAiCompatProvider.kt:465-466`）—— 保留但降级

```kotlin
// ↓ 契约注入：调用方不得设置（02-契约规范.md §5.2）
addProperty("temperature", 0)
```

- 判定：**保留但降级**（高）。`temperature=0` 的目的是**铁律 3（确定性）+ 让失败可复现**（`AgentOutputParser.kt:92` 有交叉引用），
  不是"小模型需要低温才听话" ⇒ 值保留。但 KDoc 里"否则铁律 3 会被悄悄绕过"（`:46`）是本地/CLI 时代的强约束；
  对编码 agent，0 也合理，**只需把论证从"铁律 3"改为"可复现 + 缓存"**。

### E9 Anthropic / Responses 轨**完全不发** temperature（`AnthropicProvider.kt:259-361`、`OpenAiResponsesProvider.kt:209-327`）—— 重写

- 事实核查：这两个 `buildBody` 从头到尾没有 `temperature` 字段（逐行读过；OpenAI 兼容轨有 `:466`）。
  ⇒ 三家轨道的确定性口径**不一致**：OpenAI 兼容 = 0，Anthropic = 服务端默认（1.0），Responses = 默认。
- 判定：**重写**（中）。`ModelProvider.kt:111` 的 `deterministic: Boolean = true` 文档说"provider 必须使用 temperature=0 等确定性参数"，
  但**没有任何 provider 读 `deterministic`**（grep 全仓仅 3 处：定义 + AgentLoop 两处传值）。这是**契约承诺未兑现**，
  且 Anthropic 的默认 1.0 会让"同一上下文复现同一错误"这条排查前提在那一轨失效。

### E10 Dart 侧 `reasoningEffort` / `wantsThinking` 是死代码且与 Kotlin 不一致（`app/lib/models/settings.dart:164-181`）—— 重写

```dart
String? get reasoningEffort => switch (this) {
      ReasoningLevel.low => 'low',
      ReasoningLevel.high => 'high',
      ReasoningLevel.max => 'max',
      _ => null,
    };
```

- 判定：**重写**（高）。两层问题：
  1. **无消费者**：grep `reasoningEffort` / `wantsThinking` 在 `app/` 仅这两处定义，0 调用点 ⇒ 跨进程只传 `reasoningLevel.wire`（`agent_bridge.dart:495`）。
  2. **语义不一致**：Kotlin `OpenAiCompatProvider.kt:545-553` 把 `MAX` 映射成 `"high"`（部分端点无 `max` 档），Dart 这份却映射 `'max'`。
     两份真相里死的那份还是错的那份。

### E11 `AppSettings.isLocalConfig` 的 KDoc 整段在讲 `enable_thinking`（`app/lib/models/settings.dart:576-615`）—— 重写

```dart
/// 用户实测：把 Base URL 配成 `http://192.168.1.10:8090/v1`
/// （**局域网里的 llama.cpp**）—— 旧实现只认 `127.0.0.1` …
/// 请求里**不带** `chat_template_kwargs.enable_thinking=false`。
```

- 判定：**重写**（中）。`:598-609` 已经声明"语义已收窄 / 显式开关已删除"，但**上半段（576-597）仍在用 Qwen3.5 思考吃光 max_tokens 论证这个函数存在**。
  今天 `isLocalConfig` 的真实用途只剩两件：允许不填 Key（`agent_bridge.dart:449`）、自动选 provider 时跳过没 Key 的云端（`settings.dart:679`、`:696`）。
  读代码的人需要自己穿过 40 行失效论证才能明白这一点。

### E12 `HISTORY_MAX_TURNS = 10`（`app/.../MainActivity.kt:1651-1662`、执行点 `:980-981`）—— 重写

```kotlin
 * 10 轮是个保守起点 —— 够覆盖"刚才聊了什么"，
 * 又不会让首轮 prompt 过胖。将来接压缩/摘要时替换。
private const val HISTORY_MAX_TURNS = 10
```

- 判定：**重写**（高）。理由两条（"全量塞进去每轮成本线性上升""更早内容帮助递减"）都是**成本导向的硬剪**，
  且**静默**（`982-984` 直接截，无"还有 N 轮未带入"标注）。压缩机制已于 2026-10-16 落地（`AgentLoop.kt:1185-1273`）——
  KDoc 自己写"将来接压缩/摘要时替换"，**那一天已经来了**。
  ⚠️ 与类别 2 的 A1 是同一处，此处只作**配置口径**记录，不重复计入类别 1 的 Top 5。

### E13 设置页上下文长度说明（`app/lib/screens/settings_screen.dart:1169-1175`）—— 重写

```dart
/// 留空 = 用后端默认（本地 4096 / 云端 128K）。
```

- 判定：**重写**（中）。本地 4096 已不存在；且该字段（`contextLength`）在 Dart 侧**只持久化、不参与任何请求**
  （grep `contextLength` 在 `app/lib` 仅 settings/编辑页，`agent_bridge` 传参里没有它）——与 C10 同类的"配置断线"。

### E14 `AgentBridge` 类 KDoc 仍在描述一条已删除的路径（`app/.../bridge/AgentBridge.kt:52-82`）—— 重写

```kotlin
 * | `local` | llama-server | ⛔ **2026-10-18 起已废弃**（ADR-035；代码删除进行中，见下） |
…
 * S1b/S2 把工具面与预算全部按云端档收敛（**11 个工具的冻结区** + **200 行摘录** +
 * **40 轮 / 120 次调用**），而本地 llama.cpp 是 **4096 上下文** ⇒ 这个组合**几乎必然撑爆**。
```

- 判定：**重写**（中）。`194-222` 已经用 `error(...)` 取代了 `local` 分支（"本地后端已删除"），
  但类文档还写"代码删除进行中"、"Dart 侧仍在给自建发 `backend='local'`"——Dart 侧 `471-475` 早已只剩三协议映射 ⇒ **文档与代码互相矛盾**。

### E15 `run_shell_command` 描述里的"单条即可；有多步请分多次调用"（`agent/.../tools/ShellTools.kt:77-79`）—— 重写

```kotlin
description = "…禁止杀进程、重启设备或删除工作区外的文件。返回的是错误摘录，完整日志会落盘，需要细节时用 read_file 读它。",
ToolParam("command", "string", "要执行的命令，单条即可；有多步请分多次调用，便于定位失败"),
```

- 判定：**重写**（中）。"禁止 kill"是 AGENTS.md 硬约束（**保留**），"多步请分多次调用"是 4B 时代为"定位失败"加的教练：
  强模型熟练用 `&&` / `-c`，强制拆分只会**多烧一轮**（每轮都是完整 prefill + 一次 API 计费）。

### E16 `find_files` 只支持三种通配，理由是"4B 模型不需要更多语法"（`agent/.../tools/FsSearchTools.kt:109-120`）—— 重写

```kotlin
 * 不支持 `[abc]` / `{a,b}` —— 那两种会当字面量处理（0 命中，而不是错配）；
 * 4B 模型不需要更多语法。
```

- 判定：**重写**（中）。`[abc]` / `{a,b}` 是 glob 的常规子集，对强模型是**基础语法**；
  今天的行为是"当字面量处理 → 0 命中"（比报错更糟：模型会以为文件不存在）。描述里已声明限制（`140-141`），所以不是静默，
  但依据句"4B 不需要"表明这是**能力裁剪**而非产品决定。

### E17 全仓仍以"本地 4B 的时延/吞吐"当现状依据的注释（仅注释，不影响行为）—— 保留但降级

| 位置 | 原文要点 |
|---|---|
| `app/lib/screens/chat_screen.dart:134` | `本地模型满载时约 250 token/s`（给 16 ms 合并论证） |
| `app/lib/screens/chat_screen.dart:216`、`:4243` | `本地模型稳态单轮约 20 秒（冷启动 132.8 秒）`（给会话守卫论证） |
| `app/android/.../MainActivity.kt:75` | `否则 UI 会卡死 —— 本地模型一轮 5-20 秒` |
| `app/lib/widgets/input_bar.dart:927-929` | `本地两态提示已移除 … 用户不再用本地模型` |
| `agent/.../AgentEvent.kt:16`、`:55`、`:286` | `一轮本地模型 5–20 秒` / `本地模型不开 thinking…` |
| `core/.../provider/StreamChunk.kt:101-112`、`:134` | `llama-server b11401 + Qwen3.5-4B` 实测表 / `本地 llama.cpp 只有这一个布尔量` |

- 判定：**保留但降级**（低）。16 ms 合并、节奏解耦、`StepStarted` 首帧这些**机制**是对的且必须留（依据换成"云端流式同样逐 chunk 到达、主线程 post 必须有上限"即可）；
  但"250 tok/s"在云端已不成立（`实测-L1` 之后没有任何时延基线）。仅注释问题，不影响行为，故列在最后。

### E18 `Contract.Cache` 的一批"目标值"常量无消费者（`core/.../contract/Contract.kt:16-44`）—— 保留但降级

```kotlin
const val PROMPT_N_TARGET = 150
const val PROMPT_N_ALERT = 500
const val PREDICTED_N_TARGET = 60
const val PREDICTED_N_ALERT = 120
const val TURN_LATENCY_TARGET_MS = 8_000L
const val TURN_LATENCY_FAIL_MS = 15_000L
```

- 判定：**保留但降级**（中）。grep 全仓：`PROMPT_N_*` / `PREDICTED_N_*` / `TURN_LATENCY_*` **零消费者**（只有 `HIT_RATE_TARGET/ALERT` 被测试读）。
  数值本身是"本地 250 tok/s / 8 秒一轮"时代的验收目标（`Stream` 段 `665-669` 直接写"本地模型解码约 250 tok/s"）。
  留着不是错，但会让"验收目标"看起来仍被度量 —— 实际无人测量，这正是 `AGENTS.md` 说的"看起来有护栏"。

### E19 废弃「本地模型」provider 的一次性清理（`app/lib/services/settings_controller.dart:206-229`）—— 保留

```dart
final legacy = providers.where(_isLegacyLocalProvider).toList();
…
// 只删"手机上本机 llama.cpp"这一类（回环地址 + qwen3.5/llama 模型名）：
// 用户自己的**局域网/自建端点**（192.168.x / 域名）不在此列，不能误删。
```

- 判定：**保留**（高）。这是**正确的移民**而非遗迹：判据精确（`:284-293`）、不误删局域网、清 `activeProviderId` 防悬空选择。不得当"本地时代残留"清理掉。

---

## F. 本类别 Top 5 优先级

### 立刻删（无消费者 / 分支不可达，删了不会改变任何线上行为）

| 序 | 目标 | 证据 | 一句话 |
|---|---|---|---|
| **1** | `Contract.Provider.DEFAULT_MAX_OUTPUT_TOKENS = 96` + `AnthropicProvider` 的 `maxTokensForMessages` 构造参数 | `core/.../contract/Contract.kt:611` + `provider-http/.../AnthropicProvider.kt:91` | 一对**死值**：96 是本地 GBNF"能力预检"的输出上限，构造参数从未被读；留着会让人以为 Anthropic 默认只有 96 token |
| **2** | `DEFAULT_CTX = 4096` + `contextLimitTokens()` 的本地分支 + `ProviderConfig` 三个"--- 本地 ---"字段 + `DEFAULT_THREADS/DEFAULT_SLOT` | `Contract.kt:52`、`AgentBridge.kt:835-837`、`ModelProvider.kt:78-81`、`Contract.kt:636-641` | 一整串**不可达的本地配置**：`isCloud` 恒 true（Dart 侧硬编码 `chat_screen.dart:1991`）、`modelPath/threads/slot` 在云端路径上无消费者 |

### 需重写（会实际降级强模型表现，按收益排序）

| 序 | 目标 | 证据 | 一句话 |
|---|---|---|---|
| **3** | 工具协议里的"串行化三连"：`计划要给 2 步以上` / `一次只做当前那一步` / `超过约 3000 字符分几次写`，以及与之矛盾的"一次最多 4 个原生调用" | `AgentLoop.kt:2809-2816`、`:2864-2869`、`:2852` | 同一份提示词里**自相矛盾**：既鼓励一次发 4 个调用，又要求一次只做一步；3000 字符分段是 4B 的输出量级，会制造半截文件 |
| **4** | 压缩摘要的 `maxOutputTokens = 1024` | `AgentLoop.kt:1238` | 唯一一处 **<2000 的真实生成预算**（其余 <2000 全是探针，见 §G）；摘要被截断 ⇒ 压缩后新会话从残缺摘要重启，而且只压一次（`:1244`） |
| **5** | 扁平标量 schema（全部 `type="string"`）+ `maxOutputTokens` / `contextLength` 两条"采集后丢弃"的配置断线 | `core/.../tool/ToolSpec.kt:3-13` + `settings.dart:236`/`:388` | 前者让原生 `tools` 的 JSON Schema 没有 integer/boolean/enum，强模型被迫把数字写成字符串；后者让服务端上报的输出上限/上下文长度到不了请求层（请求恒 4096 / 128K） |

> 补充第 6 项（与类别 2/3 重叠，故不入 Top 5）：`PrefixBuilder.kt:70` 的"仅以下这些"与 `search_tools` 长尾披露**逻辑矛盾**（A3），
> 以及 `NativeSkip.PARALLEL` 的旧文案"本实现一次只支持一个原生工具调用"（`AgentLoop.kt:2899`，v2 已支持 4 个）——两句都是在向模型提供**过期事实**。

---

## G. 已排除的误报（避免主报告误报）

### G1 `max_tokens: 1` —— **全部是探针/心跳，不是生成预算**

| 位置 | 代码 | 为什么合理 |
|---|---|---|
| `provider-http/.../OpenAiCompatProvider.kt:140-144` | `callChatOnce(messages=…"hi", maxOutputTokens = 1, …)` 在 `load()` 里 | **连通性探活 + 验证模型名拼写**；只要服务端回 200 即可，不需要正文。给大预算反而白烧钱 |
| `provider-http/.../OpenAiCompatProvider.kt:168-176` | `prewarm()` 用 `maxOutputTokens = 1` 发 `[SYSTEM(冻结区), USER("ping")]` | 目的是**建立前缀缓存**（消息结构必须与真实请求一致，`149-164`）；1 token 足够让服务端缓存 `SYSTEM` 那段，正文越长越浪费 |
| `app/lib/screens/settings_screen.dart:1701` | `'{"model":"$model","messages":[{"role":"user","content":"hi"}],"max_tokens":1}'` | "测试连接"按钮：读状态码（401/404/超时）就够，`1620-1630` 明说"不该有副作用" |

⇒ 这三处**不得**当"输出预算过小"上报。判定：**保留**。

### G2 其他被排除项

| 位置 | 看起来可疑 | 为什么合理 |
|---|---|---|
| `AgentLoop.kt:1443-1451` | "原生优先，正文不参与执行决策" | 架构决定（一条响应不能有两个"真话"）；不是限制模型，是**消除歧义** |
| `AgentLoop.kt:2115-2125` | "计划推进只认 `update_plan`，工具成功不自动勾" | 真机教训：自动勾会**让进度条撒谎**并污染模型工作记忆 |
| `AgentLoop.kt:2688-2706` | "只数成功/被拦、失败给 1 次宽容" | 这是**已修好**的循环检测（旧版会把合法重试判成重复，导致文件永远写不出来） |
| `AgentLoop.kt:2898-2901` | `NativeSkip` 四种固定文案 | 统一文案是为了"同一事实 N 种措辞"不成为新的不确定源；但 `PARALLEL` 那句**文案已过期**（见 F 补充） |
| `core/.../tool/ToolValidator.kt:58-93` | 空值判非法但尊重 `allowEmpty`、控制字符排除 `\n\r\t` | 真机 bug 修出来的（`list_files.dir=""` 被拦 → 谎称完成；`\n` 被拦 → Markdown 写不出）；**必要护栏** |
| `core/.../tool/ToolValidator.kt:41-53` | 必填缺失 + 未知参数拒绝 | 防"臆造参数名"；且 `optional=true` 已允许缺键（`ToolSpec.kt:82`），不再一刀切 |
| `core/.../exec/CommandGuard.kt:123-124`、`:141` | 禁止 `kill`/`force-stop` | `AGENTS.md` **用户硬约束**（2026-10-09 事故），与模型大小无关 |
| `agent/.../AgentLoop.kt:2805-2808` | 要求先给计划 | 产品需求（用户原话"先拿问题先分析，做一个待办"），非模型限制 |
| `contract/Contract.kt:256-271`（Web）、`:279-285`（Media）、`:100-119`（快照） | 各类上限 | **上下文/内存安全闸**，归类别 2；本类别只记录不进 Top 5 |
| `contract/Contract.kt:437-462`（Staging）、`:483-501`（FsOps） | 文件数/字节/深度上限 | 手机存储与递归操作**成本闸**，与模型无关 |
| `contract/Contract.kt:508-517`（Thermal） | 43.0 °C / 电量 20% 熔断 | 真机热行为实测（`实测-04`），是设备约束 |
| `contract/Contract.kt:629-632` | 重试 2 次 / 退避 600ms | 手机网络 429/5xx 日常，且只重试"还没吐内容"的调用 |
| `contract/Contract.kt:48-49` | 压缩触发 0.80 | 比例阈值，与模型无关；配 128K 时在 102K 触发 |
| `contract/Contract.kt:671-772`（Stream） | 16 ms / 48 字符 / 0.5 思考占比 / 64 token 下限 | 16ms=一帧是**观感上限**；0.5/64 是"思考吃光预算"的**可用性刹车**——机制必须留，只需换掉"本地 250 tok/s"的论证（见 E17） |
| `provider-http/.../AnthropicProvider.kt:267` | `maxOf(maxOutputTokens, 1)` | Anthropic **协议要求** `max_tokens ≥ 1`，不是预算压缩 |
| `agent/.../tools/AndroidTools.kt:118` | `构建较慢，一次只调一次` | 真实成本（aapt2→javac→d8→对齐→签名，真机 1–3 分钟）；重复构建真的会烧设备 |
| `app/lib/services/settings_controller.dart:206-229` | 删除 `id=local` 的旧配置 | **正确的数据迁移**（判据精确、不误删局域网），不是遗迹 |
| `app/lib/screens/settings_screen.dart:994-995` | `provider.isConfigured || AppSettings.isLocalConfig(provider)` | 语义已收窄为"回环/局域网端点允许不填 Key"（E11），**判据本身正确**；只需改注释 |

### G3 正面证据：这些地方**已经**按强模型改好，清理时不要误删

| 位置 | 证据 |
|---|---|
| `AgentLoop.kt:2743-2769` | `TOOL_PROTOCOL_CLOUD` 的 KDoc 明确记录：**去掉**了"每次都写全，不要只写片段"这种绝对化措辞，理由是"那句对 4B 是必要的护栏，对强模型是**反向教练**"；并给出代价（改文案 = 首请求 prefix miss 一次） |
| `AgentLoop.kt:2767-2768` | 诚实标注"**零真机**：这里只保证提示词变了，不保证模型真的开始局部替换" |
| `AgentLoop.kt:1466-1476` | 原生轨下"正文不是 JSON 也合法（纯文本=最终回答）"，且注释点名这正是"为什么要按特定格式输出、限制 LLM 发挥"的来源 |
| `ToolZonePlan.kt:40-50`、`Contract.kt:134-141` | 明确写了"撤销的是**服务于一个已经不存在的前端**的妥协"，不是"顺手放宽" |

---

## H. 附：证据强度与未覆盖说明

- **行号准确性**：本报告每条均先 `read` 到该行再引用；批量结论（"无消费者"/"全仓仅定义处"）均以 `grep` 全仓结果为据。
- **未覆盖**：`docs/*.md` 里的提示词草案（`02-契约规范.md` §4.2 的"禁止可选参数"等）属于文档而非可执行配置，
  本报告只在 D6/E1 处以交叉引用的形式点到（`ToolSpec.kt:70-73` 自己就标注了"文档那条需更新"）。
- **零真机/零真 Key**：本审计是**静态证据**。`TOOL_PROTOCOL_*` 的任何措辞改动都会改冻结前缀字节（`AgentLoop.kt:2765`），
  首次请求 prefix cache 必 miss 一次 —— 这属于改动成本，不是本次审计的判断依据。
