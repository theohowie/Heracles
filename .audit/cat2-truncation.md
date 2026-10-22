# 类别 2：暴力截断类小模型限制遗迹（只读审计）

> 审计对象：`D:\AllCode\Agent\Heracles`（Kotlin 多模块 + Flutter `app/lib`）
> 审计方式：全仓 grep `.take( / .takeLast( / .dropLast( / .slice( / .substring( / copyOf( / .limit(`，
> 再逐处 `read` 到源码行核对。忽略 `build/`、`.gradle/`、`.kotlin/`、`.git/`、`.dart_tool/`、`.agent-teams/`、`.tmp-*/`。
> 本文件是本次审计**唯一写入**的文件；仓库代码/配置/文档零改动。

## 0. 统计摘要

**共 38 处独立发现**（A 类 12 · B 类 16 · C 类 10）：

| 判定 | 数量 | 含义 |
|---|---|---|
| **必删** | 5 | 上限本身没有存在理由（服务对象已不存在 / 纯小模型时代参数 / 死常量） |
| **放宽** | 7 | 上限类型合理（防炸上下文），但**数值明显偏紧**，且偏紧的理由是 4B/4096 时代 |
| **重写** | 8 | 机制本身有问题（静默截断、"完整日志"名不副实、chars/bytes 单位混用、先全读后截） |
| **保留** | 18 | 真·安全上限（防 OOM / 防炸上下文 / 二进制与图片 / 通知栏 UI），值也在合理区间 |

分节计数：**A 历史 12**（必删 1 / 放宽 4 / 重写 3 / 保留 4）·
**B 工具结果 16**（必删 1 / 放宽 3 / 重写 4 / 保留 8）·
**C 日志与快照 10**（必删 3 / 放宽 0 / 重写 1 / 保留 6）。

另有 **25 处已排除的纯字符串/解析误报** + **8 处"正面证据：这些地方根本不在截断"**，见 §F.1 / §F.2。
另有 **5 条"只标注不改数值"的观察项**（常量漂移、默认开关、同一模式的批量收口建议），见 §F.3。

**判定口径**（本次审计的核心方法论）：
- **(a) 安全上限** = 防 OOM、防单条工具输出炸掉 append-only 上下文、二进制/图片预览、通知栏单行。
  → 标 **保留**，只在"值明显偏紧"时补一句"上限值是否过紧"。
- **(b) 小模型限制** = 为 4B 听话 / 省 4096 上下文而把**正常信息**掐掉。
  判据优先级：① 代码/KDoc 里是否点名 `4B` / `本地` / `小模型` / `4096` / `max_tokens 512` / `llama.cpp`；
  ② 数值是否恰好等于"本地档"历史值（40 行 / 8 轮 / 512 / 500 字符）；
  ③ 该截断是否**静默**（没有 `truncated` 标记或"还有 N 项"计数）。
- 特别地：`ADR-035` 删掉本地后端后，**凡 KDoc 自己承认"成因已不存在但值没动"** 的，一律不是"顺手放宽"而是**遗留**（本报告里 `Contract.FsSearch.DEFAULT_MAX_RESULTS`、`SessionStore.STEP_TEXT_LIMIT` 就是这一类）。

---

## A. 历史记录 / 上下文截断（最高优先级）

> 结论先行：**历史链路里最严重的不是 `Session.render()`（它不截断，见 §F.1 正面证据），
> 而是"进 AgentLoop 之前的跨 run 历史只取 10 轮"和"工作记忆里失败结果只留 80 字符"。
> 这两个都是**静默**的 —— 模型不知道自己被剪了。**

### A1 `HISTORY_MAX_TURNS = 10` —— 跨 run 历史只喂最近 10 轮（**静默丢弃**）

- 文件:行号：`app/android/app/src/main/kotlin/com/theohowie/heracles/MainActivity.kt:1662`
  （截断执行点在 `MainActivity.kt:980-981`；KDoc 见 `:942-947`）

```kotlin
// MainActivity.kt:1662
private const val HISTORY_MAX_TURNS = 10
// MainActivity.kt:980-981
if (pairs.size > HISTORY_MAX_TURNS) {
    pairs.subList(pairs.size - HISTORY_MAX_TURNS, pairs.size)
```

- 截断对象：**传给 `AgentLoop.run(history=…)` 的 (user, assistant) 对**，只保留最后 10 对。
- 理由（原注释，直引）："云端上下文很大，但全量塞进去会让每轮成本线性上升" / "更早的内容对『继续任务』帮助递减" /
  "10 轮是个保守起点 …… ⚠️ 这是**保守的默认**，将来接压缩/摘要时替换"（`MainActivity.kt:944-947`、`:1655-1660`）。
- 为什么是遗迹：这是**纯成本导向的硬剪**，没有 token 预算、没有"还有 N 轮未带入"的标注、
  也不看模型真实上下文（`DEFAULT_CLOUD_CTX = 128_000`，10 轮对话通常远不到 1/10）。
  用户场景「继续完成任务，他输出了又是没有记忆了」就是这条路修出来的，而 10 轮对它只是"够用一点"。
  上下文压缩机制（`AgentLoop.kt:1220-1273`）已经存在，注释里"将来接压缩时替换"的前提**已成立**。
- 判定：**必删**（改为按 token 预算裁剪；至少必须标注"更早的 N 轮未带入"）
- 置信度：**高**（代码路径 + 注释自承"保守默认/将来替换"）

### A2 工作记忆里失败结果 `take(80)`、拦截原因 `take(40)`

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:736`、`:739`

```kotlin
"${r.index}. 失败：${friendlyTool(t.tool)} → ${r.toolResult?.take(80) ?: "未知原因"}"
...
"${r.index}. 被拦截：${friendlyTool(t.tool)}（${r.verdict.take(40)}）"
```

- 截断对象：**每轮都 append 进会话的「你已经完成的工作」**（`renderProgressLedger`，`:726-755`，注入点 `:1329-1332`）。
  失败工具的真实报错只留 **80 字符**，拦截原因只留 **40 字符**。
- 理由：无注释说明；80/40 与"小模型别啰嗦"的取向一致。注意**同一个类**里
  `MAX_IDENTICAL_TOOL_CALLS`（`:2716`）、`CONSECUTIVE_UNPARSEABLE_LIMIT`（`:2733`）都**提成了命名常量**，
  而 80/40 是内联字面量 —— 连本文件自己的习惯都不一致。
- 危害：**失败原因是模型自我纠正的唯一依据**。80 字符通常只够"失败：写入失败：java.lang.Ill…"，
  模型看不到真实原因（例如 `PathEscapeException` 的具体越界路径、`CommandGuard` 的具体规则），
  于是会重试同样的调用 → 撞 `MAX_IDENTICAL_TOOL_CALLS=2`（`:2716`）硬停。
- 判定：**放宽**（至少给到一行可读的完整首行 + 首段，或直接给全文并由 token 预算兜）
- 置信度：**高**（截断存在与位置确定；"偏紧"是工程判断）

### A3 上下文压缩的摘要输出预算 `maxOutputTokens = 1024`

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:1238`（上下文见 `:1228-1246`）

```kotlin
provider.generate(
    dev.heracles.core.provider.GenerateRequest(
        prompt = summaryPrompt,
        maxOutputTokens = 1024,
        structuredOutput = null, // 摘要是自由文本，不约束格式
```

- 截断对象：把**整段会话**压成一段摘要时的输出上限 = **1024 token**（含思考模型的思考）。
- 理由：无（代码里没有取值依据）。
- 为什么是遗迹：同一个文件 `:159-183` 记录了真机实测"`max_tokens=1024` 里思考把预算吃光 → 正文为空 →
  输出无法解析 → 熔断"。摘要在**思考模型**上会**原样复现**这条故障：摘要为空 ⇒ 保持完整上下文继续（`:1246-1250`），
  压缩机制实际上被静默降级成"不压缩"。而且 1024 token 也很难装下"任务目标 + 所有文件路径 + 已完成步骤"。
- 判定：**放宽**（摘要走 `effectiveMaxOutputTokens()` 或单独给一个 4K–8K 量级；并区分"思考预算"）
- 置信度：**高**（`1024` 与同文件已记录的故障阈值同值，这是可推理的隐患）

### A4 过程态落盘 `STEP_TEXT_LIMIT = 4000`（理由仍写着"本地 max_tokens 512"）

- 文件:行号：`app/android/app/src/main/kotlin/com/theohowie/heracles/bridge/SessionStore.kt:71`、`:596-603`
  （理由 KDoc 在 `:47-69`）

```kotlin
const val STEP_TEXT_LIMIT = 4000
...
if (think.length > STEP_TEXT_LIMIT) { think = think.take(STEP_TEXT_LIMIT); cut = true }
if (text.length > STEP_TEXT_LIMIT)  { text  = text.take(STEP_TEXT_LIMIT);  cut = true }
```

- 截断对象：`.jsonl` 里 `role:"step"` 的 `think` 与 `text`，各 **4000 字符**。
- 理由（原注释，直引）："4000 字符 ≈ 2800 token …… 它**大于**本地单轮的输出预算（`max_tokens` 512），
  所以**正常的一轮永远不会被截断**"（`:59-63`）。
- 为什么是遗迹：判据是 **`max_tokens` 512（本地 4B 时代）**。今天默认 `maxOutputTokens = 4096`
  （`AgentLoop.kt:183`），推理档位放大后 `effectiveMaxOutputTokens()` 可到 **16384**（`:784-794` + `Contract.kt:661`）；
  也就是说 **4000 字符的上限已经小于正常一轮的输出**，与注释的"正常一轮永远不会被截断"直接矛盾。
  影响面：只影响落盘的显示态（不进模型上下文），但用户切回会话看到的是被剪的过程，
  且 `truncated:true` 之后的完整内容**在磁盘上已永久丢失**（`.heracles/sessions/*.jsonl` 之外没有第二份副本）。
- 判定：**放宽**（跟随实际输出预算，或按"每步上限 = 单轮输出预算的 1.5 倍"派生；不建议必删 —— 防 `.jsonl` O(n²) 膨胀的理由仍成立）
- 置信度：**高**（注释自承的判据已失效，算术可验证）

### A5 审批弹窗把待签字的参数截到 500 字符（与已修的"看不到完整 patch"自相矛盾）

- 文件:行号：`app/lib/screens/chat_screen.dart:3684-3685`（对照 `:3699-3714`）

```dart
final shownDetail =
    detail.length > 500 ? '${detail.substring(0, 500)}…' : detail;
```

- 截断对象：**危险操作审批弹窗里展示给用户的参数原文**（`path` / `command` / `patch`），上限 500 字符。
- 理由：`:3678` 注释"只展示最有信息量的一段：命令原文 / 路径；太长截断（弹窗不是日志）"。
- 为什么是遗迹：**同一个函数**在 `:3699-3714` 记录了真机 bug ——
  "参数一长，弹窗就报 `BOTTOM OVERFLOWED BY 346 PIXELS` …… 内容被黄色警示条截断 ——
  **用户看不到完整的 patch，却在被要求对这次修改签字**。那不是『观感问题』：审批的全部意义就是『看清楚再点允许』"。
  overflow 已经用 `Flexible + SingleChildScrollView + maxHeight 0.6` 修好了，**但 500 字符的硬剪留在原地**：
  用户现在能滚动了，滚到底仍然只有 500 字符 —— 修的只是"物理截断"，没修"逻辑截断"，问题本质未变。
- 判定：**重写**（审批内容必须给全文；弹窗内已可滚动，500 字符的裁剪只应作用于"摘要行"而非正文）
- 置信度：**高**（同一函数内两段注释互相打脸）

### A6 单轮输出预算默认 `4096`（顶层大模型仍按 4B 的"够用"给）

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:183`（判定逻辑 `:784-794`）

```kotlin
private val maxOutputTokens: Int = 4096,
...
return scaled.coerceAtMost(Contract.Inference.MAX_OUTPUT_TOKENS_CAP)
```

- 截断对象：**模型每轮的输出**（`max_tokens`），默认 4096；档位放大后上限 16384（`Contract.kt:661`）。
- 理由（原注释，直引）："4096 的取舍：足够思考 + 一个完整工具调用（含 CDATA 写文件的中等内容）/
  远小于云端模型的上限" + "本地 llama.cpp 由调用方显式传小值（4096 上下文装不下大输出）"（`:178-182`）。
- 为什么是遗迹：取值理由里 **两条都是本地 4096 上下文**（输出大了挤压输入）。今天云端 128K，
  输出 4K 与 16K 的差别只是钱；而 `finish_reason=LENGTH`（`AgentLoop.kt:1397` 自己记录了"LENGTH = 被输出预算截断"）
  在"整文件写 `write_file` / 长 patch"场景下会**真的发生**，然后走到"输出无法解析"的容错分支。
  注意 `write_file` 的内容参数上限是 100_000 字符（≈ 30–70K token），远大于输出预算 —— 上限之间不自洽。
- 判定：**放宽**（默认提到 8192 或按 provider `maxOutputTokens` 能力派生；档位倍数保留）
- 置信度：**中高**（偏紧成立；"提到多少"是工程判断）

### A7 思考**转发预算**比例 `0.5`（超出后思考不再进 UI）

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:763`；
  执行点 `agent/src/main/kotlin/dev/heracles/agent/ThinkingBudget.kt:53-58`、`AgentLoop.kt:2443-2451`

```kotlin
const val MAX_REASONING_BUDGET_RATIO = 0.5
...
if (ThinkingBudget.shouldForwardReasoning(reasoning.length, maxOutputTokens)) chunk.deltaReasoning else ""
```

- 截断对象：**思考增量转发给 UI 的字符预算**（不是服务端 token，`ThinkingBudget.kt:33-35` 已诚实说明）。
  预算 = `maxOutputTokens * 0.5`，默认档下 = 2048 字符。
- 理由（原注释，直引）：KDoc 整段依据是"4B 把 `max_tokens=512` 全烧在 reasoning_content ⇒ 正文 0 字符 ⇒ 永远不收敛"
  （`Contract.kt:730-762`），以及"本地 llama.cpp（4096 上下文）输入被挤到无处安放"（`:650`）。
- 为什么是遗迹：这条机制**唯一的目的是防 4B 无限思考拖死 UI**。云端顶级模型思考正常，2048 字符之后
  用户就"看不到思考"了，而 UI 的档位开关（Low/High/Max）本意是"想看思考"。副作用还有：
  落盘的 `think` 也是被截流的版本（`AgentLoop.kt:2534-2541`，注释明确"与用户看到的完全一致"）→
  磁盘上也不完整。且 `budgetExhausted`（`:2370`、`:2447-2449`）只置位不消费（全仓仅 3 处引用，无 UI 提示）。
- 判定：**重写**（改为"不截断转发、只做 UI 侧滚动/折叠"，或把预算提升到与输出预算同量级；`0.5` 这个比例不该在云端生效）
- 置信度：**高**（服务对象已删、`budgetExhausted` 是死标志）

### A8 解析熔断时给用户看的"最后一次原始输出"只留 300 字符

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2184-2188`

```kotlin
val lastRaw = raw.take(300).ifBlank { "（空）" }
val detail = "模型连续 $consecutiveUnparseable 轮没有按协议输出，已停止。\n\n" +
    "最后一次原始输出：\n```\n$lastRaw\n```\n\n" +
```

- 截断对象：**给用户的诊断文本**（不进模型上下文）。上限 300 字符。
- 理由：`take(300)` 无注释；`raw` 是模型原始输出，可能含用户数据（`AgentLoop.kt:1402` 的打印纪律不涉及这里）。
- 评价：方向正确（这是"最需要看原文"的时刻），但 300 字符对"输出无法解析"这种事故通常不够 ——
  真正要判断的是"它是不是把调用写进了 reasoning / 是不是 JSON 少了一个括号"，300 字符常切在关键处之前。
- 判定：**保留**（安全/体积考虑成立），但**值偏紧**，建议同 A5 一样：给全文 + 由 UI 滚动
- 置信度：**中**（是否为"小模型遗迹"不确定；更像严谨性不足）

### A9 debug 模式的原始输出预览 `take(600)`

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:1433-1438`

```kotlin
if (debug) {
    println("┌─ 第 $turnIndex 轮 · 原始输出（${raw.length} 字符，finish=${result.finishReason}）")
    println("│ " + raw.take(600).replace("\n", "\n│ "))
    if (raw.length > 600) println("│ …（截断，共 ${raw.length} 字符）")
```

- 截断对象：`HERACLES_DEBUG=1` 时打到 stdout 的原始输出。**不进模型上下文、不进会话**，且**有截断标记 + 总长**。
- 判定：**保留**（终端日志场景，标记齐全）
- 置信度：**高**

### A10 会话标题 / 通知标题的 24 字符截断

- 文件:行号：`app/android/app/src/main/kotlin/com/theohowie/heracles/MainActivity.kt:1489`；
  `app/lib/screens/chat_screen.dart:2555`（同值 24）

```kotlin
return if (t.length <= 24) t else t.take(24) + "…"       // MainActivity.kt:1489
title.length > 24 ? '${title.substring(0, 24)}…' : title  // chat_screen.dart:2555
```

- 截断对象：会话标题（侧边栏单行显示）。**纯 UI 展示**，`+ "…"` 已提示。
- 判定：**保留**
- 置信度：**高**

### A11 文件浏览器 `listDir` 静默只给 300 项

- 文件:行号：`app/android/app/src/main/kotlin/com/theohowie/heracles/MainActivity.kt:1502-1513`

```kotlin
d.listFiles()
    ?.filter { it.name != SessionStore.DOT_DIR }
    ?.sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
    ?.take(300)
    ?.map { mapOf("name" to it.name, "path" to it.absolutePath, ...) }
```

- 截断对象：Flutter「文件」视图的目录列表，**每个目录最多 300 条**。
- 问题：**静默** —— 没有"还有 N 项"、没有总数、也没有 `truncated` 标记；超大目录下用户会以为目录就这么大。
  这违反仓库自己反复写下的纪律（`WorkspaceSnapshot.kt:93-98`、`FsSearchTools.kt:124-128`
  "静默截断比『没找到』更糟"）。它不进模型上下文，但会误导用户对工作区规模的判断。
- 判定：**重写**（返回值加 `total` / `truncated`，UI 显示"共 N 项，仅显示前 300"）
- 置信度：**高**（静默事实可从代码直接读出）

### A12 完成通知的正文 `take(80)` 与 `bigText take(500)`

- 文件:行号：`app/android/app/src/main/kotlin/com/theohowie/heracles/MainActivity.kt:245`、`:261`

```kotlin
val body = text.trim().replace('\n', ' ').take(80).ifEmpty { ... }
...
.setStyle(Notification.BigTextStyle().bigText(text.take(500)))
```

- 截断对象：通知栏单行 + 展开后正文。**系统 UI 物理限制**，且 `ifEmpty` 有兜底文案、`BigTextStyle` 已经放大到 500。
- 判定：**保留**
- 置信度：**高**

---

## B. 工具结果（Observation）截断

> 结论先行：B 类里 **`ToolValidator` 的 500 字符默认上限是本次审计最严重的单项**（会直接拦死
> `edit` / `update_plan` / `ask_user` 的正常输入）；其次是三处 shell 输出上限的"字节/字符"混用与
> "防 OOM 却先全读进内存"的实现。真正的安全上限（网页正文、图片、diff 回执）基本合理。

### B1 ★★ `MAX_ARG_VALUE_LENGTH = 500` 是**按参数名**白名单之外的默认值 → 拦死 `edit` / `update_plan` / `ask_user`

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/tool/ToolValidator.kt:109-123`（默认分支 `:114`，规则 `:73-76`）

```kotlin
private fun limitFor(paramName: String): Int = when (paramName) {
    "content", "text", "body", "code" -> MAX_CONTENT_LENGTH
    "patch", "diff" -> MAX_CONTENT_LENGTH
    "command" -> MAX_COMMAND_LENGTH
    else -> MAX_ARG_VALUE_LENGTH          // ← 500
}
const val MAX_ARG_VALUE_LENGTH = 500
```

- 截断对象：**所有工具调用的参数值长度**，校验失败即 `Result.Invalid("参数 X 超长")` → 整次调用被拦、不执行。
  白名单只覆盖 7 个参数名，其余全落 500。实测受影响的**常驻工具的正常输入**：
  - `edit.old_string` / `edit.new_string`（`PatchTools.kt:78-79`）—— 改一段 >500 字符的代码直接失败。
    **这正是 `edit` 相对 `write_file` 存在的理由**（"精确替换、省 token"，`PatchTools.kt:52-66`），
    超过 500 字符的替换场景（改一整个函数、改一段 XML/smali）**全部不可用**。
  - `update_plan.steps`（`MetaTools.kt:31-40`）—— 要求传**完整**步骤列表 JSON。
    实测字符数：`{"text":"查看项目结构","status":"done"},` = **34** 字符；
    `{"text":"写 index.html 并验证页面渲染","status":"active"},` = **50** 字符。
    ⇒ 计划在 **10 步左右**撞 500（短步骤 12–14 步，长步骤 9–10 步）。
    但更关键的是它**随任务自然增长**：`ToolParam` 没有 `maxLength` 声明、模型也无从知道上限，
    撞上只会得到"参数 steps 超长" —— 而提示词又强制"每完成一步必须调用 `update_plan`"
    （`AgentLoop.kt:2810-2811`、`:2865-2866`）⇒ 计划一长，工具就永久失败 ⇒
    继续撞 `MAX_CONSECUTIVE_FAILURES`（`Contract.kt:581`）。**这是"迟早必然发生"，不是"极端才发生"。**
  - `ask_user.questions`（`FileTools.kt:417-426`）—— 多题 JSON 数组，题面 + 两个选项 ≈ 150–250 字符/题
    ⇒ **2–3 题即可能超 500**（该工具的描述本身就示范了"可以一次问多个问题"，`:412-413`）。
  - 未来的 `find_files`/`grep_files` 参数名都短，暂不受影响；但这是一个**会持续踩的雷**。
- 理由（原注释，直引）："500 是个经验值：联系人名、搜索关键词、应用名都远短于它；
  而**模型失控时最容易的表现就是无限续写同一个参数**"（`ToolValidator.kt:117-122`）。
- 为什么是遗迹：理由本身是"防小模型失控续写"，而机制是**按参数名猜语义**。ADR-031 之后参数由
  **JSON Schema 的 `required`/类型**约束，云端顶级模型不会无故续写；防续写的正确位置是
  "内容类参数给大额度 + 全局 token 预算"，不是"没起名的参数一律 500"。
  注释 `:104-107` 已经记录过两次同类事故（`patch` / `command` 曾经被 500 拦死），**只补了两个名字，没修机制**。
- 判定：**必删**（默认值改为 `MAX_CONTENT_LENGTH` 量级；或按 `ToolParam` 显式声明 `maxLength`，禁止按名字猜）
- 置信度：**高**（可静态推导：`steps`/`old_string` 正常输入必然超 500；且注释自承同类事故已发生两次）

### B2 内容类参数上限 `MAX_CONTENT_LENGTH = 100_000`

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/tool/ToolValidator.kt:135-141`

```kotlin
const val MAX_CONTENT_LENGTH = 100_000
```

- 截断对象：`content` / `text` / `body` / `code` / `patch` / `diff` 的字符数，超限**拒绝**（不是截断）。
- 理由："100 KB —— 足够放下任何正常源文件，同时仍能拦住模型失控式续写"（`:136-140`）。
- 评价：100KB ≈ 25–70K token，对单条工具参数而言已是很大的安全闸；配合 `WorkspaceFs.MAX_READ_BYTES = 1MB`
  （`workspace/.../WorkspaceFs.kt:107`）"读得进但写只能写 100K"的错配值得记一笔，但这不是小模型遗迹。
- 判定：**保留**（略紧：大型单文件生成会撞；但与 A6 的输出预算相比不算瓶颈）
- 置信度：**高**

### B3 `run_shell_command.command` 上限 4000

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/tool/ToolValidator.kt:125-133`

```kotlin
const val MAX_COMMAND_LENGTH = 4_000
```

- 理由："最长合法命令实测 300–1200 字符（d8 的 class 列表），4000 给 3 倍余量"（`:128-131`）。
- 判定：**保留**（依据是实测，且超限是**响亮失败**不是静默）
- 置信度：**高**

### B4 写操作回执 diff `RESULT_DIFF_MAX_LINES = 40`（删/加各 20）

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:210`；
  `agent/src/main/kotlin/dev/heracles/agent/tools/FileTools.kt:76-111`

```kotlin
val cap = Contract.Tools.RESULT_DIFF_MAX_LINES     // 40
...
removed.take(half).forEach { append("- ").append(it) }
if (removed.size > half) append("… 还删了 ${removed.size - half} 行\n")
added.take(half).forEach { append("+ ").append(it) }
```

- 截断对象：`write_file` / `edit` / `apply_patch` 回执里的 diff 行数。**如实报剩余行数**（`:85`、`:108`、`:110`），不静默。
- 判定：**保留**（安全上限，且诚实计数）——但值**偏紧**：40 行里真能用来核对的只有 20+20，
  改一处 30 行的函数就看不全。若要"模型能核对"，60–80 行更合适。
- 置信度：**高**（机制正确；"略紧"是工程判断）

### B5 ★ `FsSearch.DEFAULT_MAX_RESULTS = 40` —— KDoc 自承"成因已不存在但值没动"

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:226-228`；
  `agent/src/main/kotlin/dev/heracles/agent/tools/FsSearchTools.kt:32`（使用点 `:580`）

```kotlin
const val DEFAULT_MAX_RESULTS = 40
// Contract.kt:216-224 KDoc 原文：
// "它此前直接复用 Shell.LOG_EXCERPT_LINES（40），注释说'两者是同一个约束：
//  本地 4096 上下文里一条工具结果最多占多少行'。但 ADR-035 把日志摘录提到 200 ...
//  成因（本地 4096 上下文）已经不存在 ⇒ 一个数的语义变了，不该连坐另一个。
//  ⇒ 值保持 40（零回退 ...）要改它是下一轮的独立决定"
```

- 截断对象：`find_files` / `grep_files` 不传 `max_results` 时的默认返回行数。
- 为什么是遗迹：**40 这个数就是从"本地 4096 上下文"来的**。ADR-035 只解开了绑定、**没有重新取值**，
  KDoc 明确写"要改它是下一轮的独立决定"。对 128K 上下文的云端模型，默认 40 行会频繁触发
  "只显示前 40 处" ⇒ 模型只能收窄 pattern 再搜一次（多烧一整轮），正是 `LogFilter.kt:19-21`
  记录的"信息饥饿"，只是换到了检索工具上。
- 判定：**放宽**（默认提到 100–150；`MAX_RESULTS_CAP=200` 保留）
- 置信度：**高**（"值来自本地 4096"有原文）

### B6 `grep_files` 单行命中 `MAX_LINE_CHARS = 240`

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/tools/FsSearchTools.kt:62`、`:380-388`、`:726`

```kotlin
private const val MAX_LINE_CHARS: Int = 240
...
if (line.length > MAX_LINE_CHARS) { stats.longLinesTruncated++; line.take(MAX_LINE_CHARS) + "…" }
```

- 截断对象：**每条命中行的展示长度**，240 字符；输出末尾如实报"N 行超过 240 字符已截断"（`:726`）。
- 理由（直引）："minified 文件一行可达 100 KB，一条命中就能吃掉整个预算"（`:61`）。
- 评价：防炸上下文的理由成立（真·安全上限），但 240 字符对**正常代码行**也可能切掉关键后半句
  （长链式调用、长字符串）—— 而 `grep` 的价值恰恰是"看到那一行"。
- 判定：**放宽**（400–600；或"命中位置居中截取"而不是从头截）
- 置信度：**中高**（安全性质成立，只是值偏紧且截断方向粗）

### B7 检索的其余闸门：`MAX_RESULTS_CAP=200` / `MAX_VISITED=2000` / `MAX_DEPTH=16`

- 文件:行号：`Contract.kt:237`；`FsSearchTools.kt:41`、`:50`、`:59`、`:494`、`:516`、`:533`、`:712-714`

```kotlin
private const val MAX_DEPTH: Int = 16
private const val MAX_VISITED: Int = 2_000
const val MAX_RESULTS_CAP = 200
```

- 截断对象：结果条数硬上限、遍历条目数、递归深度。**全部如实回报**（`到 2000 个条目上限即停，结果可能不完整`、
  `有 N 个目录超过 16 层未进入`、`max_results 已从 N 收敛到上限 200`）。
- 判定：**保留**（成本闸 + 诚实计数；`MAX_VISITED=2000` 与 `BuildStaging`/`FsOps` 的 2000 同量级，自洽）
- 置信度：**高**

### B8 `web_fetch` 正文 `MAX_TEXT_CHARS = 20_000`

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:256-261`；
  `agent/src/main/kotlin/dev/heracles/agent/tools/WebTools.kt:114-119`

```kotlin
const val MAX_TEXT_CHARS = 20_000
...
val body = if (text.length > Contract.Web.MAX_TEXT_CHARS) {
    text.take(Contract.Web.MAX_TEXT_CHARS) + "\n…（正文已截断，原文 ${text.length} 字符）"
```

- 截断对象：抓取网页转文本后的正文，2 万字符（≈5–8K token），**带原文总长标记**。
- 理由：append-only 会话里永久占位（`Contract.kt:243-247`）。
- 判定：**保留**（安全上限，值慷慨且诚实）
- 置信度：**高**

### B9 ★ shell 全量日志落盘 `take(MAX_CAPTURED_BYTES)`，而表头自称"这是完整日志"

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/tools/ShellTools.kt:174-203`（截断 `:181-185`，表头 `:188-196`）

```kotlin
val capped = if (log.length > Contract.Shell.MAX_CAPTURED_BYTES) {
    log.take(Contract.Shell.MAX_CAPTURED_BYTES)
} else { log }
...
append("# 说明： 这是完整日志。给模型的摘录只有 ")
append(maxExcerptLines).append(" 行 —— 需要细节时读这个文件。\n\n")
```

- 截断对象：写进 `.heracles/logs/shell-*.log` 的"完整日志"正文，上限 `MAX_CAPTURED_BYTES = 8 * 1024 * 1024`（`Contract.kt:335`）。
- 问题：**表头在说谎** —— 超过 8MB 时文件被剪，但表头仍写"这是完整日志"，
  且**没有任何截断标记**。而 `LogFilter.kt:29-30`（"摘录额度**只影响摘录**：落盘的全量日志一行不少"）
  与 `Contract.kt:322-324`（"**不是移除**：全量日志照旧落盘"）反复承诺的正是这条。
  模型被 `run_shell_command` 的 schema 教去 `read_file` 读这个文件（`ShellTools.kt:77`），读到的是半截却以为是全量。
- 判定：**重写**（要么真流式写全量，要么截断时表头改写"已截断，原始 N 字符，保留前 8M"）
- 置信度：**高**（同一文件里"完整日志"与 `take()` 直接矛盾）

### B10 `DeviceShellRunner` 的 8MB 上限：**字符**截在名为 `BYTES` 的常量上

- 文件:行号：`app/android/app/src/main/kotlin/com/theohowie/heracles/bridge/DeviceShellRunner.kt:186-219`
  （Reader `:196-207`，cap `:214-219`）

```kotlin
if (sink.length < Contract.Shell.MAX_CAPTURED_BYTES) {   // length = 字符数
    sink.appendRange(buf, 0, n)
}
...
private fun cap(text: String): String =
    if (text.length > Contract.Shell.MAX_CAPTURED_BYTES) {
        text.take(Contract.Shell.MAX_CAPTURED_BYTES) + "\n…（输出过大，已截断）"
```

- 截断对象：stdout / stderr 各最多 8M **字符**（常量名与 KDoc 说 BYTES）。
- 问题 ①（**主问题**）**单位混用**：`StringBuilder.length` 是 UTF-16 字符数，而 `MAX_CAPTURED_BYTES`
  名义是字节。中文/emoji 输出下实际驻留内存可达标称的 2–3 倍，KDoc 里"防 OOM"的算术不成立；
  同时 stdout 与 stderr **各自** 8M 字符 ⇒ 最坏近 48MB 字符同时驻留。
  问题 ②（**边界条件**）`Reader` 只在 `length < cap` 时追加 ⇒ 累计长度**恰好落在 cap** 时循环停止、
  但 `cap()` 的判据是 `>`（严格大于）⇒ 这一格上**真的丢了尾巴却没有"已截断"标记**。
  跨过 cap 的常见情形（追加后 `length > cap`）标记是有的，所以这是窄边界，但方向是"最该提示的一格反而不提示"。
  修法上两件事一起做：按字节计量 + 由 Reader 置 `truncated` 标志位、`cap()` 无条件据此加标记。
- 判定：**重写**（单位统一 + 截断标志位由读取侧置位，而不是让 `cap()` 靠长度猜）
- 置信度：**高**（单位问题是确定的；边界条件是窄情形，已如实标注）

### B11 `LocalProcessShellRunner.readCapped`：**先 `readAllBytes` 再 take** —— 防爆失效

- 文件:行号：`toolchain/src/main/kotlin/dev/heracles/toolchain/LocalProcessShellRunner.kt:105-129`

```kotlin
private fun readCapped(p: Path): String {
    if (!Files.exists(p)) return ""
    val size = Files.size(p)
    val text = String(Files.readAllBytes(p), charset)     // ← 先把整个文件读进内存
    return if (size > Contract.Shell.MAX_CAPTURED_BYTES) {
        text.take(Contract.Shell.MAX_CAPTURED_BYTES) + "\n…（输出过大，已截断）"
```

- 截断对象：本意是"命令输出夹到 8MB"，但实现是**先全量读入内存再裁剪**。
- 问题：注释写"`-v` 类输出能把磁盘/内存打满"（`:119`）—— **内存这一半完全没防住**：
  一个 500MB 的日志会先 OOM 再谈截断。且 `size`（字节）与 `text.take`（字符）混比。
- 判定：**重写**（流式读取、到上限即停；或 `Files.newInputStream` + `readBytesLimited`——
  后者在 `workspace/.../WorkspaceFs.kt:139` 已经现成，且语义正是"超限抛"）
- 置信度：**高**

### B12 `LogFilter` 的中段扫描截断与尾部兜底

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/text/LogFilter.kt:105-112`、`:132-133`、`:146-185`

```kotlin
val maxScan = Contract.Shell.MAX_CAPTURED_BYTES
val text = if (scannedPartially) {
    val half = maxScan / 2
    rawLog.take(half) + "\n…（日志过长，中段未扫描）…\n" + rawLog.takeLast(half)
}
...
val tailCount = maxLines / TAIL_FALLBACK_DIVISOR          // 200/2 = 100
val tail = lines.takeLast(tailCount).filter { it.isNotBlank() }
```

- 截断对象：① 超大日志的**扫描范围**（首尾各 4M 字符，中段放弃，但有标记 + `scannedPartially` 上报）；
  ② 无错误关键词时退化"末尾 100 行"，并如实报"共 N 行"。
- 评价：**这是全仓做得最规范的一处** —— 每一处截断都有标记、有总数、有 `logFile` 指路（`:216-217`）。
  KDoc（`:8-23`）还完整保留了"40 行是 4B 时代约束、已放宽到 200"的演进记录，没有假装是今天的依据。
- 判定：**保留**（可作为其它截断点的范式）
- 置信度：**高**

### B13 ★ 文本附件 `MAX_ATTACHMENT_CHARS = 8000`

- 文件:行号：`app/android/app/src/main/kotlin/com/theohowie/heracles/bridge/AgentBridge.kt:1244`、
  `:892-903`

```kotlin
const val MAX_ATTACHMENT_CHARS = 8000
...
val body = if (text.length > MAX_ATTACHMENT_CHARS) {
    text.take(MAX_ATTACHMENT_CHARS) + "\n…（已截断，原文 " + text.length + " 字符）"
```

- 截断对象：**用户主动附上的文本文件**注入 prompt 的正文，8000 字符。
- 理由（直引）："8000 字符 ≈ 3000 token —— 已经占掉上下文预算的相当一部分。
  不设上限的话，一个 1MB 的日志会直接把预算挤爆"（`:1238-1242`）。
- 为什么是遗迹：算术基数是**本地 4096 上下文**（3000 token 占 73% 才叫"相当一部分"）。
  今天 `DEFAULT_CLOUD_CTX = 128_000`，8000 字符 ≈ 2.3% —— 用户明明把日志当作**关键证据**附上来，
  却被剪到 8000 字符，且模型拿不到剩下的部分（会基于残缺日志下结论，比不附更危险）。
  同时截断提示只告知用户，**模型看不到"上文被截"这件事**（提示拼在附件块里，模型能看，
  但"原文 12345 字符"这个数对模型没有行动指引）。
- 判定：**放宽**（按 token 预算给，50000 字符量级；或把大附件转为"落盘 + 告知模型用 read_file 分段读"）
- 置信度：**中高**（"3000 token 占预算相当一部分"的判据已失效）

### B14 ★ 图片张数双真相：`MAX_ATTACHMENT_IMAGES = 2` vs `Contract.Media.MAX_IMAGES_PER_RUN = 4`

- 文件:行号：`app/android/app/src/main/kotlin/com/theohowie/heracles/bridge/AgentBridge.kt:1250`、
  `:948`；对照 `core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:284`；
  `agent/.../AgentLoop.kt:1823`、`:2054`

```kotlin
const val MAX_ATTACHMENT_IMAGES = 2                 // AgentBridge.kt:1250
const val MAX_IMAGES_PER_RUN = 4                    // Contract.kt:284
if (out.size >= MAX_ATTACHMENT_IMAGES) break        // AgentBridge.kt:948
if (runImages.size < Contract.Media.MAX_IMAGES_PER_RUN) { runImages += outcome.imageDataUrl }
```

- 截断对象：一次请求能带几张图。用户附件走 2 张，`view_image` 工具走 4 张 —— **同一概念两个上限**，
  直接违反 `Contract.kt:11-12`"禁止在其它文件中出现字面量阈值"。且 `MAX_ATTACHMENT_IMAGES` 不是
  从 `Contract.Media` 派生的（`Contract` 已有 `MAX_IMAGES_PER_RUN`）。
- 判定：**重写**（删除 `MAX_ATTACHMENT_IMAGES`，统一 `Contract.Media.MAX_IMAGES_PER_RUN`；若产品上
  "用户附件"确实要更严，则在 Contract 里明写两个名字并说明关系）
- 置信度：**高**（两个值都有出处，且仓库自己的门禁禁止这种分裂）

### B15 通知栏摘要 `oneLine(maxChars = 120)`

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/tools/AndroidTools.kt:449-461`；
  `Contract.kt:527`

```kotlin
internal fun oneLine(text: String, maxChars: Int = Contract.Progress.SUMMARY_MAX_CHARS): String {
    ...
    return if (line.length <= maxChars) line else line.take(maxChars - 1).trimEnd() + "…"
```

- 截断对象：前台服务通知栏**第一行**；取首个非空行 + 压空白 + 截断加"…"。
- 判定：**保留**（通知栏物理限制，且语义明确）
- 置信度：**高**

### B16 图片单张 `MAX_IMAGE_BYTES = 4MB`（超限**明确失败**而非截断）

- 文件:行号：`agent/src/main/kotlin/dev/heracles/agent/tools/ImageTools.kt:84-89`；
  `Contract.kt:279-284`

```kotlin
if (bytes.size > Contract.Media.MAX_IMAGE_BYTES) {
    return ToolOutcome.Failure("图片太大（… > 上限 …）；请先压缩/缩小后再试")
}
```

- 截断对象：无截断 —— **拒绝**并给可执行建议（正确姿势）。同类还有 `DataUrl.kt:134-157`（解码前粗筛 + 解码后精判）。
- 判定：**保留**
- 置信度：**高**

---

## C. 日志与快照 / 常量遗留

### C1 工作区快照五道上限（**当前默认关，属潜伏项**）

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:100-119`；
  `agent/src/main/kotlin/dev/heracles/agent/WorkspaceSnapshot.kt:86-90`、`:103`、`:258`、`:274-291`；
  开关 `AgentLoop.kt:445`（`= false`）、注入点 `:1351-1360`

```kotlin
const val MAX_SNAPSHOT_ENTRIES = 200
const val MAX_SNAPSHOT_DEPTH = 4
const val MAX_SNAPSHOT_CHARS = 4_000
const val MAX_SNAPSHOT_WALK = 5_000
const val MAX_SNAPSHOT_RECENT = 5
...
private val snapshotInjectionEnabled: Boolean = false   // AgentLoop.kt:445
```

- 截断对象：注入会话的「工作区现状」：200 个文件条目 / 深度 4 / **整块 4000 字符** / 遍历 5000 项 / 最近改动 5 条。
- 评价：机制**非常规范** —— 到上限必写"另有 N 项未列出（已达上限 200）"、遍历被闸住只说"至少 N 个"
  （`WorkspaceSnapshot.kt:121-134`），`clamp()` 从尾部逐行丢并标"已截断 N 行"（`:274-291`）。
  但数值偏紧：4000 字符 ≈ 1.3K token，只够列 100 来个短路径；`MAX_SNAPSHOT_RECENT=5` 也偏少。
  **重要前提**：`snapshotInjectionEnabled` 默认 `false`（"功能要在 F8b 才开"，`:428-445`），
  所以这五道闸今天**一个都不生效** —— 属于"开了就会觉得紧"的潜伏项。
- 判定：**保留**（诚实计数机制是全仓最佳之一），值建议在开启功能时一并放宽（4000 → 8000+）
- 置信度：**高**

### C2 `MAX_SNAPSHOT_WALK = 5000` 的"至少 N 个"降级

- 文件:行号：`WorkspaceSnapshot.kt:197-238`（`:206-231`）、`Contract.kt:109-116`

```kotlin
if (walk.truncated) {
    "至少 ${sorted.size} 个文件（目录过大，遍历已在 ${maxWalk} 项处停止）"
}
```

- 评价：**范式级正确** —— "宁可保守地说下界，也绝不把一个下界当成精确总数"（`:227`）。
- 判定：**保留**
- 置信度：**高**

### C3 ★ `Contract.Context.DEFAULT_CTX = 4096` 仍是 `ProviderConfig.contextSize` 的默认值（本地后端已删）

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:51-52`；
  `core/src/main/kotlin/dev/heracles/core/provider/ModelProvider.kt:80`；
  `app/.../bridge/AgentBridge.kt:835-837`

```kotlin
const val DEFAULT_CTX = 4096                       // "本地后端默认上下文长度"
val contextSize: Int = Contract.Context.DEFAULT_CTX // ModelProvider.kt:80
fun contextLimitTokens(isCloud: Boolean): Int =
    if (isCloud) Contract.Context.DEFAULT_CLOUD_CTX else ProviderConfig().contextSize
```

- 遗留对象：4096 作为**全局默认上下文长度**仍在两处活着。`AgentBridge` 的 `else` 分支今天不可达
  （`backend == "local"` 在 `AgentBridge.kt:218-221` 直接 `error("本地后端已删除")`），
  但只要任何调用方把 `isCloud` 传成 false（或未来新增本地/自建路径），
  `COMPACTION_TRIGGER_RATIO=0.8` 就会按 4096 触发 ⇒ **过早压缩**，这正是 `Contract.kt:57-75` 与
  `AgentBridge.kt:809-834` 用大段 KDoc 记录过的真机 bug（"显示已用 56% · 2.3K / 4.1K"）。
- 判定：**必删**（删 `DEFAULT_CTX` 与 `contextLimitTokens` 的 else 分支；`ProviderConfig.contextSize`
  改为必填或删除——`contextSize` 全仓只剩这一个默认值引用）
- 置信度：**高**（本地后端已删是 ADR-035 的既定事实；残留引用可 grep 证实）

### C4 ★ `Contract.Provider.DEFAULT_MAX_OUTPUT_TOKENS = 96` —— 极小值，且只喂给一个**从未被使用**的字段

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:601-611`；
  `provider-http/src/main/kotlin/dev/heracles/provider/http/AnthropicProvider.kt:91`

```kotlin
const val DEFAULT_MAX_OUTPUT_TOKENS = 96
...
private val maxTokensForMessages: Int = Contract.Provider.DEFAULT_MAX_OUTPUT_TOKENS,
```

- 遗留对象：Anthropic 请求的缺省 `max_tokens` = **96**。
- 两重问题：
  ① **96 是"能力预检"的遗留值** —— KDoc 自承"原先是能力预检的输出上限（本地 GBNF 时代，压低以早停省 decode），
     能力预检子系统已随本地后端删除，但构造默认值仍沿用同一个数"（`:603-609`）。这与"必删"的定义完全吻合。
  ② **`maxTokensForMessages` 全仓只有声明处一处引用**（grep 仅命中 `AnthropicProvider.kt:91`），
     `buildBody` 用的是调用方传入的 `maxOutputTokens`（`:261`、`:267`）⇒ 这个字段**是死的**。
     一旦将来有人"顺手用上它"，Anthropic 的回答会被硬切在 96 token（Anthropic 的 `max_tokens` 是必填硬上限）。
- 判定：**必删**（删常量与死字段；`AnthropicProvider` 的默认值应改由 `GenerateRequest.maxOutputTokens` 唯一决定）
- 置信度：**高**（死字段可 grep 证实；96 的来历有原文自承）

### C5 `Contract.Observation.MAX_ELEMENTS = 60` / `ELEMENT_ID_HEX_LEN = 4` —— **死常量**

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:122-129`

```kotlin
object Observation {
    const val MAX_ELEMENTS = 60
    const val ELEMENT_ID_HEX_LEN = 4
}
```

- 事实：全仓（含测试）**除定义处外零引用**（grep `MAX_ELEMENTS|ELEMENT_ID_HEX_LEN` 仅命中 `Contract.kt:125,128`）。
  "观测表示（元素数上限 60 / 元素 ID 4 位十六进制）"是本地 4B + GBNF 时代"观测结构化表示"设计的一部分，
  随本地退场后没有任何消费者。它不截断任何东西，但**留在契约里会让人以为观测还在被上限约束**。
- 判定：**必删**（连同 `object Observation`）
- 置信度：**高**（零引用可复现）

### C6 `MAX_NATIVE_CALLS_PER_TURN = 4` 与**注释漂移到 `= 1`**

- 文件:行号：`Contract.kt:178-197`；执行点 `AgentLoop.kt:1892-1911`；**过时注释与文案** `AgentLoop.kt:2898-2899`

```kotlin
const val MAX_NATIVE_CALLS_PER_TURN = 4          // Contract.kt:197
...
/** 一轮收到 ≥2 个调用（`Contract.Tools.MAX_NATIVE_CALLS_PER_TURN = 1`）。 */
const val PARALLEL = "本实现一次只支持一个原生工具调用"
```

- 截断对象：一轮最多执行 4 个原生调用，超出部分**配对回填"未执行"**（`AgentLoop.kt:1896-1910`，诚实、不静默丢）。
- 问题：`NativeSkip.PARALLEL` 的注释与文案（"= 1"、"一次只支持一个"）是 v1 的遗留，
  与 v2 的 4 **直接矛盾**（`Contract.kt:181-195` 自己记录了 v1→v2 演进）。文案是**给模型看的**
  （`NativeSkip.text()` 进会话），说"只支持一个"会让模型主动放弃并行。
- 判定：**重写**（只改注释与文案，数值 4 保留）
- 置信度：**高**（同文件内两处自相矛盾）

### C7 `ToolchainPaths.MAX_DEPTH = 6` / `MAX_VISITED = 2000`（定位失败返回 null）

- 文件:行号：`toolchain/src/main/kotlin/dev/heracles/toolchain/ToolchainPaths.kt:236-248`、`:340-347`

```kotlin
const val MAX_DEPTH = 6
const val MAX_VISITED = 2_000
...
if (depth > MAX_DEPTH || visited >= MAX_VISITED) return null
```

- 截断对象：工具链**定位**时的目录遍历深度与条目数。超限返回 `null`（= 没找到）。
- 评价：深度 6 有真机布局依据（Termux 前缀树 5 层，`:239-241`）。风险在于"返回 null"与"真的没有"
  不可区分 —— 若前缀树被放到更深的位置，症状会是"找不到 aapt2"（`:189` 的教训正是"只说失败会让模型瞎猜"）。
  不过这不是截断正常信息，且下游有明确失败文案。
- 判定：**保留**（建议超限时给"扫到上限即停"的区分性文案）
- 置信度：**中**

### C8 `BuildStaging` 三道上限（2000 文件 / 64MB / 深度 32）

- 文件:行号：`Contract.kt:437-462`；`toolchain/.../BuildStaging.kt:66-76`、`:116-166`

- 截断对象：SAF 工作区镜像构建的规模。超限 **抛异常**（"镜像文件数超过上限（2000 个）"），不是静默截断。
- 判定：**保留**（产品行为，且是"拒绝"而非"截断"）
- 置信度：**高**

### C9 `FsOps.MAX_RECURSIVE_ENTRIES/DEPTH` 与 `CHECKPOINT_MAX_BYTES`

- 文件:行号：`Contract.kt:483-501`；`agent/.../tools/PathTools.kt:99-101`、`:421-434`

```kotlin
if (content.toByteArray().size > Contract.FsOps.CHECKPOINT_MAX_BYTES) return false
...
if (count > Contract.FsOps.MAX_RECURSIVE_ENTRIES) { ... "**没有动任何文件**" }
```

- 截断对象：① 写前快照单文件 256KB（超限**不保存**但回执明说）；② 递归删除/移动/复制**预扫描** 2000 项 / 深度 32，
  超限在**动手前**拒绝。
- 判定：**保留**（不可逆操作的成本闸，且"不静默"做到了）
- 置信度：**高**

### C10 `LogFilter` 尾部兜底 `maxLines / 2`

- 文件:行号：`core/src/main/kotlin/dev/heracles/core/text/LogFilter.kt:79-80`、`:129-143`

```kotlin
private const val TAIL_FALLBACK_DIVISOR = 2
...
val tailCount = maxLines / TAIL_FALLBACK_DIVISOR
val tail = lines.takeLast(tailCount).filter { it.isNotBlank() }
```

- 截断对象：退出码非 0 但**没有错误关键词**时，退化取末尾 `200/2 = 100` 行，并写明"共 N 行"。
- 判定：**保留**（`LogFilter.kt:131` 说明"沿用 40 行时代的比例，零回退"；机制诚实：`format()` 会写"共 N 行"）
- 置信度：**高**

---

## D. `Contract.kt` 常量表（全部 `MAX_*` + 与截断相关的数值）

> 说明：本表是"魔法数字集中地"的逐个交代。**标记"见 A/B/C"的行已在上面计数**；
> 其余行是本表独有的补充判定（`保留/无害/非截断`），**不重复计入 38**。
> 文件前缀统一为 `core/src/main/kotlin/dev/heracles/core/contract/Contract.kt`。

| # | 常量（行） | 当前值 | 用途 | 性质 | 判定 |
|---|---|---|---|---|---|
| D1 | `Cache.HIT_RATE_TARGET` :19 / `ALERT` :22 / `ALERT_CONSECUTIVE_TURNS` :25 | 0.90 / 0.70 / 3 | 缓存命中率目标与告警 | 指标阈值（非截断） | 非截断，见类别1/3 |
| D2 | `Cache.PROMPT_N_TARGET` :28 / `PROMPT_N_ALERT` :31 / `PREDICTED_N_TARGET` :34 / `PREDICTED_N_ALERT` :37 | 150 / 500 / 60 / 120 | 每轮 token 预算目标 | 指标阈值（非截断）**且 4 个全仓零引用** | 非截断（疑死常量，交 Lead 判） |
| D3 | `Cache.TURN_LATENCY_*` :40/:43 | 8s / 15s | 单轮墙钟目标 | 指标（非截断） | 非截断 |
| D4 | `Context.COMPACTION_TRIGGER_RATIO` :49 | 0.80 | 上下文压缩触发比例 | 压缩阈值；**依赖上下文上限正确** | 保留（C3 修好后自动正确） |
| D5 | `Context.DEFAULT_CTX` :52 | **4096** | 本地后端默认上下文 | **小模型遗迹（值本身）** | **必删** → **C3** |
| D6 | `Context.DEFAULT_CLOUD_CTX` :76 | 128_000 | 云端兜底上下文 | 保守兜底（注释已说明"真实上限各异"） | 保留（建议按 `/v1/models` 上报优先，已有实现） |
| D7 | `Context.MAX_SNAPSHOT_ENTRIES` :101 | 200 | 快照列出文件数 | 防炸上下文 | 保留（略紧）→ C1 |
| D8 | `Context.MAX_SNAPSHOT_DEPTH` :104 | 4 | 快照递归深度 | 防深树 | 保留 → C1 |
| D9 | `Context.MAX_SNAPSHOT_CHARS` :107 | 4_000 | 快照整块字符硬闸 | 防炸上下文 | 保留（**偏紧**，≈1.3K token）→ C1 |
| D10 | `Context.MAX_SNAPSHOT_WALK` :116 | 5_000 | 遍历成本闸 | 成本闸（非展示） | 保留 → C2 |
| D11 | `Context.MAX_SNAPSHOT_RECENT` :119 | 5 | 最近改动条数 | 展示额度 | 保留（偏紧）→ C1 |
| D12 | `Observation.MAX_ELEMENTS` :125 / `ELEMENT_ID_HEX_LEN` :128 | 60 / 4 | 观测结构化表示 | **零引用死常量** | **必删** → C5 |
| D13 | `Tools.FROZEN_LIMIT` :152 | 12 | 冻结区常驻工具上限 | 工具面（越档**当场抛**，不静默） | 保留（已从本地 8 提到云端 12）；⚠️ **余量注释已漂移**（见下） |
| D14 | `Tools.DISCLOSE_LIMIT` :167 | 6 | `search_tools` 单次披露数 | 工具面 | 保留（KDoc 明确"不要放大到全部"） |
| D15 | `Tools.LONG_TAIL_LIMIT` :176 | 24 | 长尾工具总数 | 工具面（越档抛） | 保留 |
| D16 | `Tools.MAX_NATIVE_CALLS_PER_TURN` :197 | 4 | 单轮执行原生调用数 | 执行预算（超限诚实回填） | 保留（改注释/文案）→ C6 |
| D17 | `Tools.RESULT_DIFF_MAX_LINES` :210 | 40 | 写回执 diff 行数 | 防炸上下文（诚实计数） | 保留（偏紧）→ B4 |
| D18 | `FsSearch.DEFAULT_MAX_RESULTS` :228 | **40** | 检索默认返回行数 | **来自本地 4096（KDoc 自承）** | **放宽** → B5 |
| D19 | `FsSearch.MAX_RESULTS_CAP` :237 | 200 | 检索硬上限 | 上下文刹车 | 保留 → B7 |
| D20 | `Web.MAX_BYTES` :258 | 512KB | 单次下载 | 内存/防炸 | 保留 → B8 |
| D21 | `Web.MAX_TEXT_CHARS` :261 | 20_000 | 进上下文正文 | 防炸上下文（诚实） | 保留 → B8 |
| D22 | `Web.CONNECT_TIMEOUT_MS` :264 / `READ_TIMEOUT_MS` :267 | 15s / 20s | 网络超时 | 超时（非截断） | 非截断 |
| D23 | `Media.MAX_IMAGE_BYTES` :281 | 4MB | 单张图片 | 多模态安全（拒绝而非截断） | 保留 → B16 |
| D24 | `Media.MAX_IMAGES_PER_RUN` :284 | 4 | 单 run 图片张数 | 多模态（每轮计费） | 保留，但**与 2 冲突** → B14 |
| D25 | `Shell.DEFAULT_TIMEOUT_SEC` :297 / `MAX_TIMEOUT_SEC` :307 | 120 / 900 | shell 超时 | 超时（非截断） | 非截断（900s 有 5 倍余量依据） |
| D26 | `Shell.LOG_EXCERPT_LINES` :328 | 200 | 回给模型的日志摘录行数 | 摘录额度（**已从 40 放宽**，诚实） | 保留（本次审计的**正面样本**） |
| D27 | `Shell.LOG_CONTEXT_BEFORE/AFTER` :331/:332 | 5 / 5 | 命中行上下文 | 摘录质量 | 保留 |
| D28 | `Shell.MAX_CAPTURED_BYTES` :335 | **8MB** | 单次命令落盘日志上限 | 防磁盘/内存（**单位被当字符用**） | **重写** → B9/B10/B11 |
| D29 | `Shell.SEARCH_TIMEOUT_SEC` :341 / `PATCH_TIMEOUT_SEC` :344 | 5 / 10 | 元工具超时 | 超时 | 非截断 |
| D30 | `Json.MAX_DEPTH` :360 | 64 | JSON 嵌套扫描上限 | 防栈/业务诚实（明确失败） | 保留 |
| D31 | `Toolchain.DECOMPILE/RECOMPILE/BUILD/SIGN/D8/ARCHIVE_TIMEOUT` :369-374 | 300/300/600/120/180/60 | 构建超时 | 超时（非截断） | 非截断 |
| D32 | `Toolchain.JVM_HEAP` :384 | "512m" | 构建 JVM 堆 | 内存（非截断） | 非截断 |
| D33 | `Toolchain.PROFILE_MAX_CHARS` :410 / `PROFILE_MAX_STEPS` :413 / `PROFILE_MAX_TEXT` :416 | 64KB / 64 / 200 | 构建剖面文件校验 | 防解析爆（**明确抛**） | 保留 |
| D34 | `Toolchain.STAGING_MAX_FILES/BYTES/DEPTH` :456/:459/:462 | 2000 / 64MB / 32 | SAF 镜像规模 | 产品行为（拒绝，不截断） | 保留 → C8 |
| D35 | `FsOps.MAX_RECURSIVE_ENTRIES` :486 / `MAX_RECURSIVE_DEPTH` :489 | 2000 / 32 | 递归删/移/复预扫描 | 不可逆操作闸（动手前拒绝） | 保留 → C9 |
| D36 | `FsOps.CHECKPOINT_MAX_BYTES` :498 | 256KB | 写前快照单文件 | 存储安全（回执明说） | 保留 → C9 |
| D37 | `Thermal.BATTERY_*` :510/:513 / `CHECK_INTERVAL_MS` :516 | 20% / 430 / 5s | 热/电量熔断 | 安全（非截断） | 非截断 |
| D38 | `Progress.SUMMARY_MAX_CHARS` :527 | 120 | 通知栏单行 | UI 物理限制 | 保留 → B15 |
| D39 | `Budget.MAX_TURNS` :570 / `MAX_TOOL_CALLS` :573 / `MAX_CONSECUTIVE_FAILURES` :581 | 40 / 120 / 6 | 单任务预算 | 已从本地 8/30/3 放宽；"40 是工程判断非实测" | 保留（**交 Lead**：是否再放宽） |
| D40 | `Provider.DEFAULT_MAX_OUTPUT_TOKENS` :611 | **96** | Anthropic 缺省 max_tokens | **能力预检遗物 + 死字段** | **必删** → C4 |
| D41 | `Provider.RETRY_MAX_ATTEMPTS` :629 / `RETRY_BASE_DELAY_MS` :632 | 2 / 600ms | 429/5xx 退避 | 重试策略（非截断） | 非截断（见类别3） |
| D42 | `Inference.DEFAULT_THREADS` :638 / `DEFAULT_SLOT` :641 | 4 / 0 | 本地推理线程/slot | **本地专属，今天无消费者** | 非截断（另一类遗留，交 Lead 判） |
| D43 | `Inference.MAX_OUTPUT_TOKENS_CAP` :661 | 16_384 | 档位放大后的输出硬上限 | 输出预算（**LENGTH 截断源**） | 保留（值对云端偏保守）→ A6 相关 |
| D44 | `Stream.READ_BUFFER_BYTES` :678 | 4096 | SSE 读缓冲 | 流式（非截断） | 非截断 |
| D45 | `Stream.FLUSH_INTERVAL_MS` :700 / `FLUSH_MIN_CHARS` :717 | 16ms / 48 | 事件合并 | UI 节流（非截断；"保险丝"不丢字） | 非截断 |
| D46 | `Stream.CHUNK_IDLE_TIMEOUT_SECONDS` :725 | 120s | chunk 间隔超时 | 超时（非截断） | 非截断 |
| D47 | `Stream.MAX_REASONING_BUDGET_RATIO` :763 | **0.5** | 思考**转发**预算比例 | **为 4B/4096 定的可用性刹车** | **重写** → A7 |
| D48 | `Stream.MIN_REASONING_BUDGET_TOKENS` :771 | 64 | 思考预算下限 | 同 D47 的配套 | 随 D47 一起重写 |
| D49 | `Testing.DETERMINISM_RUNS` :777 | 100 | 确定性测试重复次数 | 测试（非截断） | 非截断 |

**D 表小结**：与"截断"直接相关的常量共 **19 个**（D5、D9、D11、D17、D18、D19、D21、D24、D26、D28、
D33、D34、D35、D36、D38、D40、D43、D47、D48），其中 **必删 2**（D5 / D40）、**放宽 1**（D18）、
**重写 2**（D28 / D47）、其余保留。`Contract.kt` 的**整体状况好于预期**：绝大多数上限都写了"为什么是这个数"，
且 **5 处明确记录了"从本地档放宽到云端档"的演进**（`FROZEN_LIMIT` 8→12、`DISCLOSE_LIMIT` 3→6、
`LONG_TAIL_LIMIT` →24、`LOG_EXCERPT_LINES` 40→200、`Budget.*` 8/30/3→40/120/6）——
这说明 ADR-035 的清理在契约层**做得相当彻底**，遗迹主要集中在**契约之外**（B1 的 500、
A1 的 10 轮、B9/B10/B11 的 shell 上限、C4 的 96）。

**顺带记一条与截断无关但会阻碍"加常驻工具"的注释漂移**：`Contract.kt:150` 写"今天实际占用 **11**（10 个常驻 +
`search_tools` 自己）"、`AgentBridge.kt:386` 也写"实际 11/12"、`ToolZonePlan.kt:29-38` 还按"常驻 10 个 +
`search_tools` = 11"叙述 —— 但 `ToolZonePlan.RESIDENT`（`ToolZonePlan.kt:85-101`）实为 **11 项**
（`list_files`/`read_file`/`write_file`/`mkdir`/`save_memory`/`ask_user`/`run_shell_command`/
`find_files`/`grep_files`/`apply_patch`/`update_plan`）⇒ 11 + `search_tools` = **12/12 已顶满**。
只有 `ToolZonePlan.kt:99`（"11 业务常驻 + search_tools = **12/12**（顶满；再加就要先挪走一个）"）
与 `AgentBridge.kt:421`/`:424`（"常驻已 12/12"/"常驻格已满"）才是对的。
⇒ **下一个常驻工具必须先从既有 11 项里挪走一个**，否则 `PrefixBuilder.buildFrozen`
（`PrefixBuilder.kt:60-63`）的 `require` 当场抛。这不是截断遗迹，但审计途中一并核实，避免后续按错误余量加工具。

---

## E. Top 5 优先级（按"对强模型的实际伤害 ÷ 修复成本"排序）

| # | 位置 | 一句话 | 判定 | 为什么排这个位置 |
|---|---|---|---|---|
| **1** | `core/.../tool/ToolValidator.kt:109-123` | `MAX_ARG_VALUE_LENGTH=500` 按参数名白名单猜语义，`edit.old_string/new_string`、`update_plan.steps`、`ask_user.questions` 全落 500 ⇒ **正常编辑/计划直接被拦** | 必删 | 唯一一处会**直接让常驻工具不可用**的截断；注释已记录同类事故两次（`patch`/`command`），只补名未修机制 |
| **2** | `app/.../MainActivity.kt:1662`（+:980-981） | `HISTORY_MAX_TURNS=10` 静默只喂最近 10 轮 ⇒ 模型"没有记忆了" | 必删 | 静默丢历史且不标注；压缩机制已存在，"将来替换"的前提已到；云端上下文 128K 下 10 轮远未到成本红线 |
| **3** | `agent/.../tools/ShellTools.kt:181-198` + `toolchain/.../LocalProcessShellRunner.kt:122-125` | 落盘"完整日志"其实被 `take(8MB)` 剪过且表头**自称完整**；本地 runner 更是**先 `readAllBytes` 再 take**（防爆失效） | 重写 | 假信息（"完整日志"）+ 真 OOM 风险；模型被 schema 教去 `read_file` 读它 |
| **4** | `app/.../bridge/AgentBridge.kt:895-900`（+`:1250` vs `Contract.kt:284`） | 用户主动附上的文本被剪到 8000 字符（≈3000 token，"预算相当一部分"是 4096 时代的算术）；图片张数 2 与 4 双真相 | 放宽 / 重写 | 用户的**关键证据**被掐；双上限违反仓库自己的门禁 |
| **5** | `app/lib/screens/chat_screen.dart:3684-3685` | 审批弹窗把待签字的参数截到 500 字符 —— overflow 修好了，**内容仍看不全**（同函数注释自己说"签字必须看清"） | 重写 | 用户安全边界；修复成本极低（正文给全文，摘要行才截） |

**紧随其后（第 6–8）**：
- `app/.../bridge/SessionStore.kt:71`：`STEP_TEXT_LIMIT=4000` 的理由仍写"大于本地 `max_tokens` 512"，
  而今天默认输出 4096、档位可到 16384 ⇒ **正常一轮已被截**，且磁盘上永久丢失（放宽）。
- `agent/.../AgentLoop.kt:736/739`：工作记忆里失败原因 80 字符、拦截原因 40 字符 ⇒ 模型看不到失败真因，
  重试撞 `MAX_IDENTICAL_TOOL_CALLS=2` 硬停（放宽）。
- `core/.../Contract.kt:763` + `ThinkingBudget.kt:53-58`：思考转发预算 0.5（默认档 2048 字符）后不再展示思考，
  且 `budgetExhausted` 只置位不消费（重写）。

---

## F. 附录：已排除的误报（纯字符串处理，不是截断）

### F.1 正面证据：这些地方**不截断**（容易被误当成"截断点"，实际是正确的）

| 文件:行号 | 事实 |
|---|---|
| `core/.../context/Session.kt:81-92` | `render()` **全量遍历** `turnList`，历史一个字符都不剪。整个 `Session` 类**没有** `update/remove`（`:51-64` KDoc），append-only 在类型层保证 |
| `core/.../context/PrefixBuilder.kt:109-126` + `PrefixAligner.kt:73-104` | 块对齐只做**补齐**（`padToBlockBoundary`），注释明写"若已超过目标则**原样返回（绝不截断）**"（`PrefixAligner.kt:71`） |
| `workspace/.../WorkspaceFs.kt:106-107`、`:139-155` | `readText` 超 1MB **抛异常**；`readBytesLimited` 超限**抛**。"超限抛，不截断"是明文纪律 |
| `toolchain/.../BuildStaging.kt:116-166` | 超 2000 文件 / 64MB **抛**，不截断（class KDoc `:39-45` 写成契约） |
| `agent/.../tools/PathTools.kt:421-434` | 递归删/移/复：**预扫描超限即拒，一个文件都没动** |
| `agent/.../AgentLoop.kt:1084-1091` | `history` 逐对 append 进新会话，**在这里不做任何裁剪**（裁剪发生在 A1 的上游） |
| `workspace/.../ZipFs.kt`、`agent/.../tools/ArchiveTools.kt` | 解压/打包**无任何结果截断**（返回值只有条目数与字节数） |
| `agent/.../tools/ImageTools.kt:84-89`、`provider-http/.../DataUrl.kt:134-157` | 超限**明确失败并给建议**，不做有损裁剪 |

### F.2 纯字符串/解析处理（grep 命中但**不是**截断）

| 文件:行号 | 实际用途 |
|---|---|
| `agent/.../AgentOutputParser.kt:212-215`、`:276`、`:280` | 剥 CDATA 标签、去掉首尾换行、剥 ``` 围栏 —— 结构解析 |
| `core/.../patch/UnifiedPatch.kt:98`、`:120-122` | 去末尾换行后切行；按 `+`/`-`/空格前缀剥首字符 —— diff 语法 |
| `agent/.../tools/PatchTools.kt:125` | `original.substring(0,i) + new + original.substring(i+old.length)` —— **替换拼接**，不是截断 |
| `agent/.../tools/FileTools.kt:258-262` | `splitLines` 去掉末尾空元素（`"a\nb\n"` = 2 行） |
| `agent/.../tools/GitIgnore.kt:83-93` | 逐行去 `!` / 去末尾 `/` / 去前导 `/` —— gitignore 语法 |
| `core/.../exec/CommandGuard.kt:83` | `dropWhile{赋值}.drop(1)` —— 跳过环境变量前缀取命令名 |
| `provider-http/.../SseDecoder.kt:87`、`:99`、`:106` | 去 `\r`、按首个冒号切 `field:value` —— SSE 语法 |
| `provider-http/.../DataUrl.kt:117`、`:129` | 切 `data:` 前缀与 `;base64,` 标记 —— data URL 语法 |
| `app/.../bridge/AndroidSafStorage.kt:62-65` | 解 `content://` URI 的 `primary:` 段 —— 路径还原 |
| `core/.../provider/FakeProvider.kt:195`、`:203`、`:253` | 按 `streamChunkChars` **切片吐流**（测试替身的分块，不是截断）；`:253` 取共同前缀估算命中 |
| `workspace/.../ZipAligner.kt:54`、`:398` | `take(5)` 只取 5 个"未对齐条目"做**示例文案**；`copyOfRange` 复制 EOCD 注释字节 |
| `agent/.../AgentLoop.kt:2174`、`:2334` | `takeLast(N)` 是**计数窗口**（判定连续失败）；`drop(1).take(batchLimit-1)` 是**挑可并发候选**，其余调用后面照常逐个执行 |
| `agent/.../tools/FsSearchTools.kt:733` | 跳过清单只列 3 个样例名（附"等"） |
| `app/lib/models/message.dart:208-212` | `stepId.substring(lastIndexOf('-')+1)` —— 取 `#3` 短形式 |
| `app/lib/screens/chat_screen.dart:1209-1210`、`:1343-1344` | 拆 `stepId|track` 的 buffer key |
| `app/lib/screens/chat_screen.dart:2545` | `_messages.sublist(0, cut+1)` —— **分支复制**前缀消息，不是剪历史 |
| `app/lib/screens/chat_screen.dart:1309` | `summary.length >= cur.text.length ? … ` —— **防内容变少的兜底**，方向与截断相反 |
| `app/lib/widgets/workspace_drawer.dart:1065-1069` | 路径只显示末两层（`…/a/b`）—— 单行展示 |
| `app/lib/services/settings_controller.dart:284-293` | 判"已废弃的本地 provider"（回环 + qwen3.5/llama）—— 迁移逻辑，非截断 |
| `app/lib/services/agent_bridge.dart:795-796`、`:816`、`:903` | 去 baseUrl 尾部 `/`；错误体预览 100 字符 |
| `app/lib/screens/settings_screen.dart:1451-1452`、`:1695`、`:1726`、`:1742` | API Key 只露首尾 4 位（**安全，正确**）；URL 去尾斜杠；回显预览 60；错误体预览 80 |
| `agent/.../AgentOutputParser.kt:145` | `json.take(200)` —— 错误消息里附片段（诊断用） |
| `provider-http/.../HttpJson.kt:64/78`、`:241` | 错误消息里 `take(120)` / `take(400)` —— 诊断片段（**且是安全考量**，防错误体进日志） |
| `provider-http/.../DataUrl.kt:179-186` | `preview` 只留 32 字符 —— **绝不能把整条 data URL 打进日志**（明文安全纪律） |
| `toolchain/.../ApkReverseEngine.kt:316` | 步骤文案里 `take(80)`（异常首行）—— 通知栏/步骤列表 |

### F.3 观察项（不与本次判定冲突，但值得 Lead 知道）

1. **`Contract.Cache` 的 4 个 token 预算常量（`PROMPT_N_TARGET/ALERT`、`PREDICTED_N_TARGET/ALERT`）
   全仓零引用**（grep 仅命中定义处与 `CacheStats.kt` 的一处 KDoc 引用）—— 与 C5 同类的"本地时代死常量"，
   但属类别 1/3 的判定范围，本次只标注。
2. **`AgentLoop.kt:2898-2899` 的注释与文案漂移**（`= 1` / "一次只支持一个" vs 实际 4）会**主动劝模型放弃并行**，已列 C6。
3. **`snapshotInjectionEnabled` 默认 `false`（`AgentLoop.kt:445`）** ⇒ C1 的五道快照上限今天全部不生效；
   一旦 F8b 打开，4000 字符的整块上限会立刻成为瓶颈。
4. **`Contract.FsSearch` / `SessionStore` / `B9` 三处**都属于"KDoc 自己承认成因已不存在、但值没动"的
   同一模式 —— 建议在收口时**一次性**处理这一类，而不是逐条讨论。
5. 本报告未改任何代码；所有行号均来自 `read`/`grep` 实读（`Contract.kt` 779 行全文、`AgentLoop.kt` 关键段
   1000-1300 / 1300-1550 / 1790-1990 / 2150-2400 / 2410-2660 / 2700-2902、`PrefixBuilder.kt` 全文、
   `Session.kt` 全文、`LogFilter.kt` 全文、`ToolValidator.kt` 全文、`WorkspaceSnapshot.kt` 全文、
   `FileTools.kt` 全文、`SessionStore.kt` 关键段 30-150 / 390-470 / 540-660、`AgentBridge.kt` 关键段
   120-270 / 360-600 / 800-970 / 1225-1255、`MainActivity.kt` 关键段 230-280 / 580-600 / 700-770 /
   835-1060 / 1200-1420 / 1475-1520 / 1630-1684 等）。

---

### 附：本类别**不需要做**的清理（免得 Lead 误删）

- **不要删** `LogFilter.kt` 的 `maxScan` 首尾策略与 `format()` 的 `logFile` 指路 —— 这是全仓最诚实的截断。
- **不要删** `WorkspaceSnapshot.clamp()` 的"从尾部逐行丢 + 计数" —— 尾部信息密度更高，方向是对的。
- **不要为了提高上限而删** `MAX_RESULTS_CAP=200` / `MAX_VISITED=2000` / `MAX_SNAPSHOT_WALK=5000` ——
  它们是**成本闸**（SAF 每次 list 是一次 IPC），不是展示闸。
- **不要把** `DataUrl.preview(32)` / `HttpJson.take(400)` / `settings_screen` 的 Key 首尾 4 位
  当成"截断遗迹"放宽 —— 那是防 Key / 防图片载荷进日志的**安全边界**。
