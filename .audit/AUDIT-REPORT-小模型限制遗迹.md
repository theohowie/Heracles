# Heracles 项目「小模型限制遗迹」代码考古审计报告

**审计日期**：2026-10-21
**审计范围**：`D:\AllCode\Agent\Heracles` 全仓（143 个 Kotlin 文件 + 38 个 Dart 文件 + 配置/模板）
**审计性质**：**只读**。未修改任何代码/配置/文档（`git status` 中的 13 处 `M` 均为审计开始前既存的工作区改动，与本次审计无关）
**审计分工**：4 个类别并行审计，每条结论均实际打开源文件核对行号；4 份分报告见文末索引

---

## 0. 一句话结论

> **这个项目已经做过一轮相当彻底的后端清理（ADR-035），契约层（`Contract.kt`）反而是全仓最干净的地方。
> 真正还在拖累大模型的遗迹，集中在「契约层之外」的四处：**
>
> 1. **校验器按参数名猜语义** → 常驻工具 `edit` / `update_plan` / `ask_user` 的正常输入被 500 字符上限**拦死**
> 2. **文本轨协议整套还在**（`{"tool":…}` 信封 + `<write_file>` CDATA + 教三种顶层形状的纠正提示）——它唯一的存在理由是「本地 GBNF 禁转义」，而那个前提已经删了半年
> 3. **提示词里的"小模型教练"** → 强制 2 步以上计划、一次只做一步、超 3000 字符分段写 —— 这些会让 GPT-4o 表现**不如它自己**
> 4. **工具参数 Schema 退化成 55 个全 `string`** → 原生 Function Calling 的类型信息全丢，数字/布尔/数组全靠猜词

**总量**：**164 处**发现 —— 必删 **16** · 重写 **64** · 放宽 **7** · 降级 **15** · 保留 **62**

| 类别 | 发现数 | 必删 | 重写 | 放宽 | 降级 | 保留 |
|---|---|---|---|---|---|---|
| 1. Prompt 与配置 | 63 | 6 | 28 | — | 15 | 14 |
| 2. 暴力截断 | 38 | 5 | 8 | 7 | — | 18 |
| 3. 解析与容错 | 50 | 3 | 21 | — | — | 26 |
| 4. 工具定义 | 13 | 2 | 7 | — | — | 4 |
| **合计** | **164** | **16** | **64** | **7** | **15** | **62** |

> ⚠️ **"保留 62" 是本次审计的重要产出**：大量看起来像"限制"的代码其实是**真·安全阀**（防 OOM、防未配对 `tool_calls` 400、防 SSRF、防幻觉、HTTP 退避重试）。报告末尾单列了「不要误删」清单 —— 盲目清理会把架构保证一起拆掉。

---

## 1. P0：立刻处理（正在直接伤害大模型表现）

> 判据：这 7 项要么**让正常操作失败**，要么**主动把模型往更差的做法上引**，要么**静默丢信息**。

### P0-1 ★★★ 校验器 500 字符上限，正在拦死三个常驻工具的正常输入

**文件**：`core/src/main/kotlin/dev/heracles/core/tool/ToolValidator.kt:109-123`

```kotlin
private fun limitFor(paramName: String): Int = when (paramName) {
    "content", "text", "body", "code" -> MAX_CONTENT_LENGTH   // 100_000
    "patch", "diff" -> MAX_CONTENT_LENGTH                      // 100_000
    "command" -> MAX_COMMAND_LENGTH                            // 4_000
    else -> MAX_ARG_VALUE_LENGTH                               // ← 500
}
```

**作用**：在**每次**工具调用执行前做参数长度校验；超限即返回 `Invalid`，**整次调用不执行**。

**为什么是遗迹**：白名单只认 7 个参数名，其余一律 500 字符。而下面这些**后加的工具**恰好用了不在名单里的参数名：

| 参数 | 工具 | 实际上限 | 正常输入长度 |
|---|---|---|---|
| `old_string` / `new_string` | `edit`（2026-10-19 新增） | **500** | 改一个 10 行方法体 ≈ 236；**改一整个函数必然超** |
| `steps` | `update_plan`（2026-10-19 新增） | **500** | 中文 6 步 = 254；**英文 6 步 = 513 ⇒ 实测直接超限** |
| `questions` | `ask_user`（2026-10-21 新增） | **500** | 2 题带 description = 225；3–4 题就超 |

**连锁后果**（这是最要命的部分）：
- `update_plan` 是提示词**强制要求**每完成一步就调用的（`AgentLoop.kt:2810-2811`）⇒ 计划一长，工具**永久失败** ⇒ 撞 `MAX_CONSECUTIVE_FAILURES=6` 熔断
- `edit` 超限后，模型只能退回 `write_file` 整文件重写 —— **而整文件重写正是 `edit` 存在的理由**
- 同一个"改代码"动作，用 `apply_patch`（`patch` 在白名单里，100KB）随便写，用 `edit` 就只有 500 字节 —— **纯粹的命名耦合**

**代码自己记过两次同类事故**（`ToolValidator.kt:104-107`）：`patch` 和 `command` 曾经都被 500 拦死，当时的修法是**往白名单里补名字**，没修机制。这是第三次。

**判定**：**必删机制**（改成参数自声明上限，或默认提到 `MAX_CONTENT_LENGTH` 量级）· 置信度 **高**（可静态推导，且**全仓无任何测试覆盖这条 500 边界**）

---

### P0-2 ★★★ 跨会话历史只喂最近 10 轮，且**静默**

**文件**：`app/android/app/src/main/kotlin/com/theohowie/heracles/MainActivity.kt:1662`（执行点 `:980-981`）

```kotlin
private const val HISTORY_MAX_TURNS = 10
...
if (pairs.size > HISTORY_MAX_TURNS) {
    pairs.subList(pairs.size - HISTORY_MAX_TURNS, pairs.size)
}
```

**作用**：每次 run 把历史 `.jsonl` 里的 (user, assistant) 对**成对裁剪**到最后 10 对，再传给 `AgentLoop.run(history=…)`。

**为什么是遗迹**：
- 这是**纯成本导向的硬剪**，**没有** token 预算、**没有**"更早的 N 轮未带入"标注 ⇒ 模型不知道被剪了，用户也不知道
- 注释自己写着「⚠️ 这是**保守的默认**，将来接压缩/摘要时替换」（`:944-947`）—— 而**上下文压缩机制已经存在**（`AgentLoop.kt:1220-1273`），这个"将来"已经到了
- 云端上下文 `DEFAULT_CLOUD_CTX = 128_000`，10 轮对话通常连 1/10 都不到 ⇒ 省下的钱微不足道，丢掉的是任务连续性

**用户可感知的症状**：正是仓库自己记录的「继续完成任务，他输出了又是没有记忆了」。

**判定**：**必删**（改为按 token 预算裁剪；至少要如实标注"更早 N 轮未带入"）· 置信度 **高**

---

### P0-3 ★★★ 文本轨协议整套：它的存在理由已经删了半年

这是**类别 3 最大的一块历史包袱**，由 4 个互相咬合的部件组成：

| 部件 | 位置 | 作用 |
|---|---|---|
| 文本轨协议全文（760 字，教"只输出三种 JSON，不要任何解释"） | `agent/.../AgentLoop.kt:2770-2822` | 教模型用 `{"tool":…}` / `{"final":…}` / `<write_file>` + CDATA |
| CDATA 标签自研解析器 | `agent/.../AgentOutputParser.kt:194-220`、`:231-237` | 正则切 `<apply_patch path="…"><![CDATA[…]]></…>` |
| 参数平铺兜底 `flatArgs` | `agent/.../AgentOutputParser.kt:69-74`、`:254-260` | 没套 `args` 时把所有顶层字段当参数 |
| 解析失败纠正提示（教三种顶层形状） | `agent/.../AgentLoop.kt:2143-2153` | 失败后追加"只接受三种顶层形状…只输出其中一种，不要任何解释" |

**为什么是遗迹（证据链完整）**：

1. **CDATA 的唯一理由是本地 GBNF 禁转义**，这句话就写在仓库里 —— `agent/.../ToolZonePlan.kt:52-56`：
   > 它的参数走 **JSON 通道**，而本地语法 `str ::= [^"\\]*` **禁转义** ⇒ 代码里的 `"` 与 `\`（smali / XML / Java 字符串）**在本地根本生成不出来**

   本地后端已随 ADR-035 删除 ⇒ 这个前提**不存在**。

2. **原生轨已经接线了**：`app/.../AgentBridge.kt:482` `nativeToolsEnabled = provider.capabilities.supportsNativeTools`，三家云端 provider 全是 `true`。

3. **双轨并存的代价是自己写明的**（`AgentLoop.kt:2829-2835`）：开了原生 `tools` 后若提示词还在教文本方言，**模型有相当概率把调用写进正文**，而"原生优先"会忽略正文 ⇒ **白跑一轮且日志里连一条错误都没有**（静默失败）。

**判定**：**必删整套**（只保留原生轨）· 置信度 **高**

---

### P0-4 ★★ 工具参数 Schema：55 个参数**无一例外**都是 `"type":"string"`

**文件**：`core/.../tool/ToolSpec.kt:6` 定下了规则，`core/.../context/PrefixBuilder.kt:158-159` 把它写进 schema

```kotlin
* **只允许扁平标量** —— 嵌套对象是小模型填错的头号来源（`02-契约规范.md` §4.2）。
```

统计：`agent/.../tools/*.kt` 共 **55 个 `ToolParam` 声明，`type` 取值 100% 是 `"string"`**。

**被压成字符串的语义类型（11 个）**：

| 参数 | 真实类型 | 工具内的二次解析 |
|---|---|---|
| `max_results` / `timeout_sec` / `offset` / `limit` | integer | `toIntOrNull()` |
| `numbered` / `replace_all` / `recursive` / `ignore_case` / `with_smali` | boolean | `in setOf("true","1","yes","y")` |
| `steps` | **array of objects** | Gson 二次解析 |
| `questions` | **array of objects** | Gson 二次解析 |

**为什么伤害大模型**：
- GPT-4o 看 `"type":"integer"` 就会填 `200`；看 `"type":"string"` 就填 `"200"` —— 类型信息丢失后 schema 不再自我描述
- 布尔参数变成猜词游戏：`"True"`/`"Y"`/`"on"`/`"是"` 全被静默当 **false**（只认 `setOf("true","1","yes","y")`）
- `update_plan.steps` 的 description 被迫写成一长串转义 JSON 示例，模型要在**一个字符串里**生成合法 JSON 数组 —— 这正是 GBNF 时代"用 CDATA 绕转义"的同一种病，只是换到了参数层

**判定**：**重写**（`ToolParam.type` 提升为真类型；`steps`/`questions` 改成 schema 级 array）· 置信度 **高**

---

### P0-5 ★★ 提示词里的"小模型教练"三连：会主动把大模型往差的做法上引

**文件**：`agent/.../AgentLoop.kt:2809-2816`（文本轨）、`:2864-2869`（原生轨，**两处都有**）

```text
- 计划要给 **2 步以上**，每步是一句可执行的话
- 给出计划后，**一次只做当前那一步**
- 单个文件很大（超过约 3000 字符）时**分几次**写
```

**为什么是反向教练**（仓库自己的 KDoc 就定义了这个词 —— `AgentLoop.kt:2757`：「那句对 4B 是必要的护栏，对强模型是**反向教练**」）：

| 指令 | 对 4B 的作用 | 对 GPT-4o 的伤害 |
|---|---|---|
| **计划要给 2 步以上** | 防它不给计划 | 单步任务是真实的（"读个文件"）⇒ 逼它**凑一个假的第 2 步**，污染计划质量。讽刺的是 `TaskPlan.kt:141-166` 已经为"单步计划有效"专门修过一次 bug |
| **一次只做当前那一步** | 防它一次做太多出错 | 与**同一份提示词**的 `:2852`「互不依赖的操作可以一次发多个工具调用（最多 4 个）」**正面矛盾** —— 模型收到自相矛盾的指令 |
| **超 3000 字符分几次写** | 4B 的输出量级确实小 | 3000 字符对大模型是**几行代码**。/workspace 里 132.8 KB 的 AgentLoop 要分 40 多次写，每次都积累"半截文件"状态 |

**附带问题**：`:2852` 把"最多 4 个"写死在**提示词**里，真值在 `Contract.Tools.MAX_NATIVE_CALLS_PER_TURN` ⇒ 典型**两处真相**（改一处必漏一处）。

**判定**：**重写**（删掉"2 步以上"和"一次只做一步"；3000 字符阈值按模型输出能力派生）· 置信度 **高**

---

### P0-6 ★★ `AnthropicProvider` 把畸形参数**静默替换成 `{}`** 发到 wire

**文件**：`provider-http/src/main/kotlin/dev/heracles/provider/http/AnthropicProvider.kt:434-438`

```kotlin
private fun inputOf(json: String): com.google.gson.JsonElement =
    runCatching { com.google.gson.JsonParser.parseString(json.ifBlank { "{}" }) }
        .getOrNull()
        ?.takeIf { it.isJsonObject }
        ?: JsonObject()      // ← 解析失败 ⇒ 空对象
```

**作用**：历史回放时，把 assistant 轮里 `tool_use.input` 的原始 arguments 转成 Anthropic 要的对象。

**为什么是遗迹**：注释写着「这里**绝不编造参数**」，但实际行为是**把畸形参数替换成"没有参数"**。后果：会话是 append-only + 每轮无状态重放 ⇒ 服务端看到的 `tool_use` 与模型当初说的**不一致**，行为不可预测，**且没有任何日志**。

这是本次审计中**唯一一处会静默污染 wire 的兜底**。原生轨已有配对校验（`canPairToolResult`）可复用。

**判定**：**必删**（明确失败或按配对校验丢弃）· 置信度 **高**

---

### P0-7 ★★ 压缩摘要的输出预算 `1024`，会把"压缩"静默降级成"不压缩"

**文件**：`agent/.../AgentLoop.kt:1238`

```kotlin
provider.generate(GenerateRequest(
    prompt = summaryPrompt,
    maxOutputTokens = 1024,          // ← 把整段会话压成一段话
```

**为什么是遗迹**：
- 这是本次审计中**唯一一处 <2000 的真实生成预算**（其余 <2000 全是探针，见 §5 误报清单）
- `max_tokens` 是**思考 + 正文共享的单一预算**，而**同一个文件** `:159-183` 就记录了真机实测「`max_tokens=1024` 里思考把预算吃光 → 正文为空 → 输出无法解析 → 熔断」—— 摘要在思考模型上会**原样复现**这条故障
- 摘要为空 ⇒ `:1246-1250` 走"压缩失败，继续使用完整上下文" ⇒ **压缩机制实际上形同虚设**；而 `compacted=true` 在 `:1244` **无论成败**都置位 ⇒ 一个 run 内**不会再压第二次**
- 1024 token 也很难装下"任务目标 + 所有文件路径 + 已完成步骤"

**判定**：**重写**（提到 4K–8K 量级，或复用 `effectiveMaxOutputTokens()`）· 置信度 **高**

---

## 2. P1：高优先（明显拖后腿，但不会立刻让操作失败）

### P1-1 连续解析失败熔断阈值 = 2：把可自愈的格式漂移升级成任务失败

**文件**：`agent/.../AgentLoop.kt:2733`（常量）、`:2159-2206`（熔断逻辑）

```kotlin
const val CONSECUTIVE_UNPARSEABLE_LIMIT = 2
```

**为什么是遗迹**：阈值 2 是**为"正文恒为空"那类本地系统性故障**定的（`:2161-2168` 记录：llama.cpp 把预算烧在思考上）。而大模型下更常见的是**协议形状漂移**（仓库自己记录了真机现场：模型把调用写成 `{"apply_patch":{…}}`，`:79-82`）。

关键反驳：代码用「`temperature=0` 下重试必然复现同一错误」为阈值辩护 —— 但 `:2143-2153` **恰恰会追加纠正提示**，所以第二轮是**新上下文**，不该按"必然复现"处理。

**判定**：**重写**（区分"纯空响应(2)"与"形状漂移(纠正后 3–4 轮)"）· 置信度 **高**

### P1-2 熔断判据建在**中文字符串前缀**上

**文件**：`agent/.../AgentLoop.kt:2173-2176`

```kotlin
val consecutiveUnparseable = records
    .takeLast(CONSECUTIVE_UNPARSEABLE_LIMIT)
    .count { it.verdict.startsWith("输出无法解析") }
```

同仓库已经把"靠中文子串猜状态"记为脆弱做法并改成结构化字段（`TurnRecord.kt`、`AgentBridge.kt:989` 的 H-1 类问题），这里**漏改**。改一句文案（例如加前缀）熔断就**静默失效**。

**判定**：**重写** · 置信度 **高**

### P1-3 审批弹窗把待签字的参数截到 500 字符

**文件**：`app/lib/screens/chat_screen.dart:3684-3685`

```dart
final shownDetail = detail.length > 500 ? '${detail.substring(0, 500)}…' : detail;
```

**最讽刺的地方**：**同一个函数**在 `:3699-3714` 记录了真机 bug 的修复注释 ——
> 「参数一长，弹窗就报 `BOTTOM OVERFLOWED BY 346 PIXELS`……**用户看不到完整的 patch，却在被要求对这次修改签字**。那不是『观感问题』：审批的全部意义就是『看清楚再点允许』」

overflow 已经用可滚动容器修好了，**但 500 字符的硬剪留在原地** ⇒ 修的只是"物理截断"，没修"逻辑截断"。

**判定**：**重写**（正文给全文，只有摘要行才截）· 置信度 **高**

### P1-4 shell "完整日志"在说谎 + 本地 runner 先 OOM 再截断

**文件**：
- `agent/.../tools/ShellTools.kt:181-198` —— 落盘日志被 `take(8MB)` 剪过，表头却写「**这是完整日志**」
- `toolchain/.../LocalProcessShellRunner.kt:105-129` —— **先 `Files.readAllBytes(p)` 全量读入内存，再 take**。注释说要防"`-v` 类输出把磁盘/内存打满"，**内存这一半完全没防住**
- `app/.../DeviceShellRunner.kt:186-219` —— 常量名叫 `MAX_CAPTURED_BYTES`，实际当**字符数**用（中文下内存可达标称 2–3 倍）

**为什么重要**：`run_shell_command` 的 schema **教模型去 `read_file` 读这个"完整日志"**（`ShellTools.kt:77`）⇒ 模型读到半截却以为是全量，然后在错误前提上下结论。

**判定**：**重写** · 置信度 **高**

### P1-5 `STEP_TEXT_LIMIT = 4000`：理由仍写着"大于本地 max_tokens 512"

**文件**：`app/.../bridge/SessionStore.kt:71`（理由 KDoc `:47-69`，执行点 `:596-603`）

原文理由：
> 4000 字符 ≈ 2800 token。它**大于**本地单轮的输出预算（`max_tokens` 512），所以**正常的一轮永远不会被截断**

**算术已失效**：今天默认 `maxOutputTokens = 4096`，推理档位放大后可达 **16384** ⇒ 4000 字符**已经小于正常一轮的输出**。注释承诺的"永远不会被截断"已经是假的，且被剪掉的过程在磁盘上**永久丢失**。

**判定**：**放宽**（跟随实际输出预算派生）· 置信度 **高**

### P1-6 死常量与不可达配置（删了不改任何线上行为）

| 位置 | 是什么 | 证据 |
|---|---|---|
| `Contract.kt:611` `DEFAULT_MAX_OUTPUT_TOKENS = 96` + `AnthropicProvider.kt:91` `maxTokensForMessages` | 本地 GBNF"能力预检"的输出上限；该构造参数**全仓从未被读**（请求体走 `request.maxOutputTokens`） | grep 仅 2 处：定义 + 声明 |
| `Contract.kt:52` `DEFAULT_CTX = 4096` | 本地 llama.cpp 内存实测值；唯一消费者是下一个死分支 | `ProviderConfig.contextSize` |
| `AgentBridge.kt:835-837` `contextLimitTokens()` 的 `else` 分支 | `isCloud` **恒 true**（Dart 侧硬编码 `chat_screen.dart:1991`）⇒ **不可达** | — |
| `Contract.kt:636-641` `DEFAULT_THREADS=4` / `DEFAULT_SLOT=0` | llama.cpp 的 CPU 线程数与 slot 号；`DEFAULT_SLOT` **零消费者** | — |
| `Contract.kt:125/128` `Observation.MAX_ELEMENTS` / `ELEMENT_ID_HEX_LEN` | **零引用**（含测试） | grep 仅定义处 |
| `AgentLoop.kt:2899` `NativeSkip.PARALLEL = "本实现一次只支持一个原生工具调用"` | **零引用**，且文案与 `MAX_NATIVE_CALLS_PER_TURN = 4` 矛盾 | grep 仅定义处 |
| `Contract.kt:28/31/34/37/40/43` `Cache.PROMPT_N_*` / `PREDICTED_N_*` / `TURN_LATENCY_*` | 本地 250 tok/s 时代的验收目标，**零消费者** | 看起来有护栏，实际无人测量 |

**判定**：**必删**（这批删了不改变任何行为，纯降认知负担）· 置信度 **高**

### P1-7 思考转发预算 `0.5`：超出后思考不再进 UI，且标志位是死的

**文件**：`Contract.kt:763`（`MAX_REASONING_BUDGET_RATIO = 0.5`）、`ThinkingBudget.kt:53-58`、`AgentLoop.kt:2443-2451`

- 预算 = `maxOutputTokens * 0.5`，默认档 = 2048 **字符**
- 依据整段是「4B 把 `max_tokens=512` 全烧在 reasoning_content ⇒ 正文 0 字符 ⇒ 永远不收敛」（`Contract.kt:730-762`）
- **副作用**：`budgetExhausted`（`AgentLoop.kt:2370/2447-2448`）**只置位、从不被读** ⇒ 死标志（已逐一 grep 确认）。用户调到 HIGH/MAX 档本意是"想看思考"，2048 字符之后**什么都看不到**
- 落盘的 `think` 也是被截流的版本（`AgentLoop.kt:2534-2541` 明确"与用户看到的完全一致"）⇒ **磁盘上也不完整**

**判定**：**重写**（不截断转发，改为 UI 侧折叠/滚动）· 置信度 **高**

### P1-8 冻结区写着"仅以下这些工具"，与长尾披露机制直接矛盾

**文件**：`core/.../context/PrefixBuilder.kt:70`

```kotlin
sb.append("\n\n## 可用工具（仅以下这些，不得编造工具名）\n")
```

**为什么是逻辑矛盾**：`search_tools` 命中后会把长尾工具变可用（`AgentLoop.kt:565-567`、`MetaTools.kt:122-131`），而冻结区**永久声明「只有以下这些」** ⇒ 模型会**自己否掉刚被披露的工具**。这是文本轨时代"冻结区=全部工具"的假设，在 ADR-023 两段式披露之后**没跟着改**。

**判定**：**重写**（"不得编造工具名"保留 —— 那是必要护栏；"仅以下这些"要改）· 置信度 **高**

---

## 3. P2：结构性重构（收益大，但要设计）

### P2-1 常驻工具 12 格已**顶满**，`edit` 被挤到长尾

**文件**：`agent/.../ToolZonePlan.kt:85-101`（RESIDENT 实为 **11 项**）、`Contract.kt:152`（`FROZEN_LIMIT = 12`）

**当前事实**：11 个业务常驻 + `search_tools` 自己 = **12/12 顶满**。

**三处注释互相矛盾**（这是最容易踩的坑）：

| 位置 | 说的是 | 对不对 |
|---|---|---|
| `Contract.kt:150` | 「实际占用 **11**（10 个常驻 + search_tools）」 | ❌ |
| `AgentBridge.kt:386` | 「实际 11/12」 | ❌ |
| `ToolZonePlan.kt:99`、`AgentBridge.kt:421/424` | 「**12/12 顶满**」 | ✅ |

⇒ **下一个常驻工具必须先挪走一个**，否则 `PrefixBuilder.buildFrozen` 的 `require` 当场抛。

**为什么这伤害大模型**：`edit` 是 2026-10-19 专门为"对齐成熟产品 `edit(old_string,new_string)` 形状"写的（`PatchTools.kt:52-58`），却因常驻已满只能走 `search_tools` 两段式。而仓库自己的结论是**「模型只用手里有的工具」**（`ToolZonePlan.kt:48`）⇒ 它大概率**永远想不起用 `edit`，继续整文件重写** —— 而那正是 `edit` 存在的理由。

**判定**：**重写**（`FROZEN_LIMIT` 的理由「4B 在 ~10 个工具后选择准确率下降」已随本地后端失效）· 置信度 **高**

### P2-2 两段式披露机制（`search_tools`）的核心论据已在原生轨下失效

**证据链**：`ToolRegistry.kt:10-21`、`MetaTools.kt:52-59`

披露机制成立的前提写在 `ToolRegistry.kt:23-29`：
> 工具名**枚举在 GBNF 里**，而 GBNF 是**请求参数** ⇒ 进冻结区的只有 `resident` 的 schema 文本

**这是 llama.cpp 的性质。** 而原生 `tools` 数组**根本不进 `frozenPrefix`** ⇒ 「披露是为了省前缀缓存」这个论据**在原生轨下不成立**，只剩「工具太多模型会选错」这条 4B 结论。

**当下的实际成本**：
- 模型想用长尾工具必须**多跑一整轮**（`search_tools` → 等结果 → 再调真工具）
- 检索是 `haystack.contains(term)` **子串匹配** + 9 张手工关键词表（`ToolGroup.kt:24-66`）⇒ 说法不在词表里就搜不到
- `ToolGroup.kt:52-59` 记录了真机事故：`view_image` 早先挂在 FILE 组 ⇒ 搜"查看图片"搜不到 ⇒ **模型直接回"我没有看图的工具"**

**判定**：**重写**（原生轨下把全部工具直接放进 `tools` 数组，`search_tools` 降级为兼容）· 置信度 **中-高**

### P2-3 `AgentLoop.nativeToolsEnabled` 的过时 KDoc 在维持"文本轨还有消费者"的假象

**文件**：`agent/.../AgentLoop.kt:395-426`

默认 `false`，且配了约 30 行 KDoc 论证「默认 false，且这一步**刻意不发**（这不是保守，是安全）」，理由是"响应侧还没落地"。

**但响应侧早已落地**：`AgentOutputParser.fromNativeCall`、`Turn.Assistant(nativeCalls)`、`NativeToolCall`、`NativeCallAssembler`、`NativeToolFlowTest`（973 行）。

⇒ CLI / 单测默认走文本轨 ⇒ **文本轨永远有"消费者"** ⇒ 那套 CDATA/信封协议在测试层面对齐着，**永远删不掉**。这是 P0-3 删不动的根因。

**判定**：**重写**（默认改 true，让文本轨真的变成"显式关闭才走"）· 置信度 **高**

### P2-4 文档与实现漂移（会误导下一次改动）

| 位置 | 文档说 | 实现是 |
|---|---|---|
| `NativeToolSchema.kt:34-38` | 「只装常驻工具……披露工具继续走文本轨。**这是设计取舍，不是遗漏**」 | `AgentLoop.kt:501-502` 装 `activeTools()`（含已披露长尾） |
| `NativeToolSchema.kt:55-57` | 「一轮多个 `tool_calls`……**只执行一个**，≥2 个时**报错**」 | 最多执行 4 个，超出的配对回填"未执行"（`AgentLoop.kt:1892-1911`） |
| `AgentBridge.kt:72-76` | 「本地代码删除**进行中**」「Dart 侧仍在给自建发 `backend='local'`」 | `:194-222` 已 `error(...)`；Dart 侧早已只剩三协议映射 |
| `Contract.kt:150` / `AgentBridge.kt:386` | 「11/12，留 1 空位」 | **12/12 顶满**（见 P2-1） |

**判定**：**重写**（纯文档，但影响下一次改动的正确性）· 置信度 **高**

### P2-5 `find_files` 的语法能力被"4B 不需要"裁剪

**文件**：`agent/.../tools/FsSearchTools.kt:109-120`

```kotlin
* 不支持 `[abc]` / `{a,b}` —— 那两种会当字面量处理（0 命中，而不是错配）；
* 4B 模型不需要更多语法。
```

`[abc]` / `{a,b}` 是 glob 的**常规子集**，对大模型是基础语法。今天的行为是"当字面量 → 0 命中"，比报错更糟（模型会以为文件不存在）。

**判定**：**重写** · 置信度 **中**

---

## 4. 完整清单：按类别索引

分报告（每份都有逐行原文摘录 + 判定 + 置信度 + 「已排除的误报」附录）：

| 类别 | 文件 | 发现 | 必删 | 重写 | 其他 |
|---|---|---|---|---|---|
| 1. Prompt 与配置 | [`.audit/cat1-prompt-config.md`](.audit/cat1-prompt-config.md) | 63 | 6 | 28 | 降级 15 / 保留 14 |
| 2. 暴力截断 | [`.audit/cat2-truncation.md`](.audit/cat2-truncation.md) | 38 | 5 | 8 | 放宽 7 / 保留 18 |
| 3. 解析与容错 | [`.audit/cat3-parsing.md`](.audit/cat3-parsing.md) | 50 | 3 | 21 | 保留 26 |
| 4. 工具定义 | [`.audit/cat4-tools.md`](.audit/cat4-tools.md) | 13 | 2 | 7 | 保留 4 |

### 按用户要求的四类问题逐条回答

#### ① Prompt 与配置类

**所有系统提示词载体**（唯一的 6 处）：

| 载体 | 位置 | 判定 |
|---|---|---|
| `DEFAULT_SYSTEM_PROMPT`（3 句身份声明） | `AgentLoop.kt:2735-2738` | 降级（极简是好事，但没告诉模型"这是 Android 编码 agent / 有 shell / 有审批档位"） |
| `TOOL_PROTOCOL_CLOUD`（文本轨 760 字） | `AgentLoop.kt:2770-2822` | **必删** |
| `TOOL_PROTOCOL_NATIVE`（原生轨） | `AgentLoop.kt:2846-2872` | 重写（还兼容教文本轨的 `{"plan":…}`/`{"final":…}`） |
| 压缩摘要提示 | `AgentLoop.kt:1228-1232` | 保留（正向教练） |
| 解析失败纠正提示 | `AgentLoop.kt:2143-2153` | 重写 |
| 冻结区工具清单表头 | `PrefixBuilder.kt:70` | 重写（与长尾披露矛盾） |

**严苛指令（14 处，摘最关键的 6 条）**：

| 原文 | 位置 | 判定 |
|---|---|---|
| 「## 输出格式（三种，**不要输出任何其它内容**）」 | `AgentLoop.kt:2771` | **必删**（"不要解释"是明确反向教练） |
| 「**只输出其中一种，不要任何解释**」 | `AgentLoop.kt:2151` | 重写 |
| 「计划要给 **2 步以上**」 | `AgentLoop.kt:2809`、`:2864` | 重写（逼它凑假步骤） |
| 「**一次只做当前那一步**」 | `AgentLoop.kt:2810`、`:2865` | 重写（与"一次发 4 个调用"矛盾） |
| 「超过约 **3000 字符**分几次写」 | `AgentLoop.kt:2815`、`:2869` | 重写（大模型几行代码就超） |
| 「不要编造工具名；只能使用上面列出的工具」 | `AgentLoop.kt:2818` | **保留**（必要护栏） |

**`max_tokens` < 2000 的全部命中项（关键：区分探针与真实预算）**：

| 值 | 位置 | 性质 | 处置 |
|---|---|---|---|
| **1024** | `AgentLoop.kt:1238` | **真实生成预算**（压缩摘要） | **重写** → P0-7 |
| **96** | `Contract.kt:611` + `AnthropicProvider.kt:91` | **死值**（能力预检遗物，构造参数从未被读） | **必删** → P1-6 |
| 1 | `OpenAiCompatProvider.kt:142` | **探活探针**（`load()` 验证 Key + 模型名） | ✅ **误报，保留** |
| 1 | `OpenAiCompatProvider.kt:174` | **预热探针**（`prewarm()` 建前缀缓存） | ✅ **误报，保留** |
| 1 | `settings_screen.dart:1701` | **"测试连接"按钮探针** | ✅ **误报，保留** |
| 4096 | `AgentLoop.kt:183` | 真实预算（发行版**唯一值**，`AgentBridge` 不传参） | 重写 → 建议 8192 |

> 📌 **两条"采集了但送不到执行层"的断线**（已逐层核对调用链）：
>
> | 值 | 采集 | 持久化 | 实际用途 | 有没有送进 `AgentLoop` |
> |---|---|---|---|---|
> | `maxOutputTokens`（中转站常报 384000） | ✅ `settings_screen.dart:1244` | ✅ `settings.dart:236` | **无**（纯存） | ❌ `app/android` 下 grep **0 命中** ⇒ 请求恒用 `4096` |
> | `contextWindow`（常报 1000000） | ✅ `chat_screen.dart:1947` | ✅ `settings.dart:233` | **仅 UI 面板显示**（`chat_screen.dart:2018` `_contextLimit`） | ❌ **未送进 run**：`AgentLoop.contextLimit` 来自 `contextLimitTokens()` 的硬编码 `DEFAULT_CLOUD_CTX = 128_000`（`AgentBridge.kt:526`） |
>
> ⇒ **真实后果**：模型自称 1M 上下文，但压缩仍在 **128K × 0.8 = 102K** 触发；输出上限仍是 **4096** 而非 384000。用户花了功夫"获取可用模型"，拿到的是**只用于显示的数字**。这是配置断线（不是小模型限制），但它让大模型的上下文/输出能力**实际未被用上**。

#### ② 暴力截断类

**历史记录截断**（最高优先级）：

| 位置 | 截断什么 | 上限 | 判定 |
|---|---|---|---|
| `MainActivity.kt:1662`（`:980-981`） | 跨 run 历史 (user, assistant) 对 | **10 轮**，静默 | **必删** → P0-2 |
| `AgentLoop.kt:736/739` | 工作记忆里失败原因 / 拦截原因 | **80 / 40 字符** | 重写（模型看不到失败细节，而失败细节正是它改对的前提） |
| `AgentLoop.kt:2184` | 熔断时给用户看的"最后一次原始输出" | 300 字符 | 保留但偏紧 |

**工具结果（Observation）截断**：

| 位置 | 截断什么 | 上限 | 判定 |
|---|---|---|---|
| `ToolValidator.kt:109-123` | 参数值 | **500**（见 P0-1） | **必删** |
| `ShellTools.kt:181-198` | 落盘"完整日志" | 8MB，且表头**自称完整** | 重写 → P1-4 |
| `LocalProcessShellRunner.kt:105-129` | 命令输出 | 先全读再 take（**先 OOM**） | 重写 → P1-4 |
| `AgentBridge.kt:895-900` / `:1250` | 文本附件 | 8000 字符（"占预算相当一部分"是 4096 时代算术，今天占 2.3%） | 放宽 |
| `AgentBridge.kt:1250` vs `Contract.kt:284` | 图片张数 | **2 vs 4 双真相** | 重写 |
| `SessionStore.kt:596-603` | 落盘 think/text | 4000 字符（理由失效） | 放宽 → P1-5 |
| `chat_screen.dart:3684` | 审批弹窗待签字参数 | 500 字符 | 重写 → P1-3 |

**已确认「不是截断」的关键点**（防误删）：`Session.render()` **不截断**（append-only 铁律）；`LogFilter` 的首尾扫描是全仓最诚实的截断实现（每处都标了总数+`logFile` 指路）；`WorkspaceSnapshot.clamp()`、`WorkspaceFs`/`BuildStaging`/`PathTools` 的"超限**抛**不截断"都是**正确**的。

#### ③ 解析与容错类

**结论：`AgentOutputParser` 大体守住了"解析失败绝不猜"的铁律** —— 里面**没有** `replace("'", "\"")`、补大括号、截 `{...}` 子串这类典型"正则修 JSON"。

**正面样板（不要动）**：
- `DuplicateKeys.kt:136` —— 扫不动**不许**静默当"没重复"，返回 `Unusable`
- `BuildProfileLoader.kt:124` —— 配置解析失败 ⇒ 带原因的 `Invalid`，永不抛、不静默
- `UnifiedPatch.kt:189` —— 多处命中 ⇒ **拒绝**而不是改第一处
- `AgentOutputParser.kt:142` —— 原生 `arguments` 非法 ⇒ `Unparseable`，不执行

**违规的 Hack**：

| 位置 | 在容忍什么 | 判定 |
|---|---|---|
| `AgentOutputParser.kt:194-220` CDATA 解析器 | 替模型解析标签方言 | **必删** → P0-3 |
| `AgentOutputParser.kt:69-74` + `:254-260` `flatArgs` | 参数平铺在顶层时兜底 | 重写 |
| `AgentOutputParser.kt:244-251` `toString()` | 值一律转字符串，类型错被抹平 | 重写 |
| `AgentLoop.kt:2143-2153` 纠正提示 | 教三种顶层形状 | 重写 → P0-3 |
| `AnthropicProvider.kt:434-438` `inputOf` → `{}` | 畸形参数静默变空对象 | **必删** → P0-6 |
| `SessionStore.kt:418-421` | JSONL 坏行静默 `continue` | 重写（违反"读不到≠空必须明说"） |
| `UnifiedPatch.kt:103` | 修改块外认不出的行一律跳过 | 重写（"宽容解析"可能让补丁只应用一半） |
| `UnifiedPatch.kt:123-124` | 空行当空上下文行（替模型补前导空格） | 重写 |
| `TaskPlan.kt:205` | status 认"进行中/正在做"同义词 | 重写（拼错的枚举被静默降级成 pending） |

**无脑重试**：**不存在** —— 这是好消息。全仓**没有**"同一请求自动重放"式重试。重试只在 HTTP 层且三条边界写死在契约里（`Contract.kt:621-632`）：只重试**还没吐内容**的、只重试 provider 标 `retryable` 的、最多 2 次。**合规范本**。

**`finishReason=LENGTH` 容错**：**不存在"自动补 prompt 再问"分支**（全仓 grep 确认）。这是**值得记录的"没有"** —— 不猜、不伪造完整输出，正确。但代价是"被截断的工具调用"会走到 `Unparseable`，然后按 P1-1 的阈值 2 直接熔断。

#### ④ 工具定义类

**是否放弃了原生 Function Calling？** **没有放弃，已经接线并发货态开启**：

```kotlin
// app/.../AgentBridge.kt:482
nativeToolsEnabled = provider.capabilities.supportsNativeTools,
```

三家云端 provider 的 `supportsNativeTools` 全是 `true`（`OpenAiCompatProvider.kt:103`、`AnthropicProvider.kt:107`、`OpenAiResponsesProvider.kt:84`）。响应侧也完整（`NativeToolCall`、`NativeCallAssembler`、`Turn.Assistant(nativeCalls)`、配对回填、并行 v2 最多 4 个、`parallelSafe` 真并发）。

**问题不在"没接"，而在"接了还留着另一条"** ⇒ 见 P0-3 / P2-3。

**参数 Schema 是否被过度简化？** **是，且相当严重** —— 55 个参数 100% 是 `"type":"string"` ⇒ 见 P0-4。

---

## 5. ⚠️ 不要误删：这些是**真·安全阀**，不是小模型遗迹

> 这一节是为了防止"清理"变成"拆掉架构保证"。审计中确认**合理、应当保留**的高风险候选：

| 位置 | 为什么看似可疑 | 为什么必须留 |
|---|---|---|
| `CommandGuard.kt:141` 禁止 `kill` / `force-stop` | 一条硬编码禁令 | **`AGENTS.md` 用户硬约束**（2026-10-09 真事故：force-stop 了用户的监控 App） |
| `ToolValidator.kt:58-93` 空值/控制字符校验 | 一堆"过于严格"的规则 | 每条都是真机 bug 修出来的（`list_files.dir=""` 被拦 → 模型谎称完成；`\n` 被拦 → Markdown 写不出）。**且已用 `allowEmpty` 做成按参数可放宽** |
| `AgentLoop.kt:2688-2706` 重复调用检测 | 会拦合法重试 | 已修好版本：只有"执行**失败**后重试"才放行，成功/被拦才计数。早先版本才是 bug |
| `AgentLoop.kt:1474-1476` 原生轨"正文=最终回答" | 看起来在"容忍不守格式" | **这是本次架构最正确的收获**。旧实现把纯文本判成 `Unparseable` ⇒ 连挂两轮熔断 |
| `search_tools` 无命中返回 `Failure` 而非"最接近的几个" | 看起来不友好 | 硬凑结果会**诱导模型误用工具**，比"没找到"更糟 |
| `ToolZonePlan.kt:127-136` 越档 `require` 当场抛 | 启动期崩溃很凶 | **不静默截断**是正确纪律（截断会让模型以为工具不存在） |
| `Turn.ToolResult` 的配对回填 | 多写一条"未执行" | `tool_calls` 没有配对 `tool_result` ⇒ 服务端 **400**。必须补 |
| `Contract.Web` 的 SSRF 拒绝内网地址 | 限制模型能力 | App 跑在用户手机上，内网地址**真的可达**（路由器后台）。这不是理论风险 |
| `LogFilter` 的首尾扫描 | 中段被跳过 | 全仓最诚实的截断：每处都有标记 + 总数 + `logFile` 指路 |
| `Contract.Provider.RETRY_*` 重试 2 次/600ms | 看起来像"瞎重试" | 三条边界写死：未吐内容 / `retryable` / 上限。**合规范本** |
| `settings_controller.dart:206-229` 删除 `id=local` 旧配置 | 看起来是本地残留 | **正确的数据迁移**：判据精确（回环 + qwen/llama 模型名），**不误删局域网端点** |
| `Contract.Tools.RESULT_DIFF_MAX_LINES = 40` | 写回执被截 | 但**如实报剩余行数**，且 append-only 会话里回执永久占上下文 |
| `Contract.FsSearch.MAX_RESULTS_CAP = 200` | 检索被限 | 注释已明说"不是为本地算的"；append-only 下超长结果**永久**付 prefill |
| `Contract.Media.*` / `Staging` / `FsOps` 各类上限 | 一堆 MAX | 手机内存/存储/递归操作的真实成本闸，与模型强弱无关 |

---

## 6. 建议的执行顺序

| 阶段 | 做什么 | 为什么这个顺序 |
|---|---|---|
| **第 1 步**（半天，零风险） | 删 P1-6 那批**死常量**；改 P2-4 的**文档漂移** | 删了不改变任何行为，纯降认知负担；且先对齐文档才能安全改代码 |
| **第 2 步**（1 天，收益最大） | 修 P0-1（500 字符机制） | 唯一一处**正在让常驻工具失效**的问题；改完 `edit`/`update_plan` 立刻可用 |
| **第 3 步**（1–2 天） | P0-4（参数类型）+ P0-7（摘要预算）+ P1-3（审批弹窗） | 都是局部改动，让原生 FC 的类型信息和长输出真正可用 |
| **第 4 步**（2–3 天，需设计） | P0-3 + P2-3（**文本轨整套退役**） | 需要同步改 `AgentLoop` 默认值、`AgentOutputParser`、Dart 侧 `stream_step.dart`/`chat_screen.dart` 的剥壳逻辑、以及一批测试锚点。**先做 P2-3 改默认值，让文本轨在测试里失去消费者**，再删就安全 |
| **第 5 步**（1 天） | P0-2（历史 10 轮）+ P1-1/P1-2（熔断阈值与判据） | 影响"长任务连续性"的体感问题 |
| **第 6 步**（需产品决策） | P2-1 + P2-2（常驻格/披露机制重构） | 要重新决定"工具面怎么给"，收益大但改动面也大 |

**每一步之后必须做的事**：
- ⚠️ **改 `AgentLoop` 默认值会改冻结前缀的 hash** ⇒ 首次请求 prefix cache 必 miss 一次（预期代价，但要知道）
- ⚠️ **改工具名/参数/描述 = 改冻结前缀** ⇒ 同上
- ⚠️ 仓库有 781 个 Kotlin 测试 + 92 个 Dart 测试，其中大量断言**钉住了当前字符串**（例如 `AgentOutputParser` 的错误文案、`TOOL_PROTOCOL` 的措辞）。**改提示词会红一批测试 —— 那是预期的，要逐条判断是"改锚点"还是"暴露了真问题"**
- ⚠️ `ToolZonePlanTest.kt:93/105` 显式断言「11 个常驻 / 占用 12」，加任何常驻工具前必须先改这条

---

## 7. 审计方法与局限（如实声明）

**方法**：
1. 4 个类别并行审计，每类独立 grep → `read` 精读 → 回到源码核对行号
2. 每条结论都要求**文件:行号 + 原文摘录 + 作用 + 判定 + 置信度**
3. 每份分报告都附「**已排除的误报**」清单（合计 **62 条**）—— 避免主报告误报是本次审计质量的关键
4. Lead 对交叉出现的结论（500 字符上限、`step` 常量、`NativeSkip.PARALLEL`、图片张数双真相、常驻 12 顶满）做了**独立复核**

**局限（必须说清）**：
- **静态审计**：全部结论来自源码阅读 + grep，**没有跑任何测试、没有上真机**。本报告中"会被拦死"这类判断是**静态推导**（可静态推导的部分可信度高，涉及运行时行为的标了中/低置信度）
- **`max_tokens` 偏紧的判断含工程取舍**：提到 8192 还是 16384 是判断，不是实测
- **"强模型在 12 个工具内准确率不退化"是引用外部经验**，本仓库没有自己的实测数据 —— P2-1/P2-2 的判定标了「中-高」而不是「高」
- **文本轨退役的收益是推理性的**：仓库已知原生轨上"模型会把调用写进正文"是真机现象（`AgentLoop.kt:2829-2835` 记录），但"删掉文本轨后具体好多少"**没有测量过**
- ⚠️ **`AGENTS.md` 明确写着「真 Key 验证一次都没跑过」** —— 而 `nativeToolsEnabled` 的接线本身就是 wire 变更。本报告对原生轨的正面评价**建立在代码与单测之上，没有真实 wire 证据**

---

## 8. 分报告索引

| 文件 | 内容 |
|---|---|
| [`.audit/cat1-prompt-config.md`](.audit/cat1-prompt-config.md) | 63 处：提示词载体（6）· 严苛指令（14）· max_tokens（12）· 上下文与缓存假设（12）· 其他小模型配置（19）+ 21 处误报 + 4 处正面证据 |
| [`.audit/cat2-truncation.md`](.audit/cat2-truncation.md) | 38 处：历史截断（12）· 工具结果（16）· 日志与快照（10）+ `Contract.kt` 49 行常量逐个交代 + 27 处误报 + 8 处"根本不截断"的正面证据 |
| [`.audit/cat3-parsing.md`](.audit/cat3-parsing.md) | 50 处：JSON 与 try-catch（18）· 正则修 JSON（10）· 重试熔断（8）· 文本轨 vs 原生轨（8）· 截断与空响应（6）+ 16 处误报 |
| [`.audit/cat4-tools.md`](.audit/cat4-tools.md) | 13 处：参数 Schema（2）· 工具注册表（4）· 原生 FC 接线（5）· 保留项（4）+ 7 处误报 |

---

*本报告为只读审计产物。所有 `文件:行号` 均可在当前工作区复核；未修改仓库任何代码/配置/文档。*
