# 类别 4 审计：工具定义 / 工具注册表 / 原生 Function Calling

> 审计对象：`D:\AllCode\Agent\Heracles`（只读审计，未改动任何代码/配置/文档）
> 审计人：Lead（自审）
> 每条均实际读过源码（read/grep），行号可复核。

## 统计摘要

| 项 | 数量 |
|---|---|
| **发现总数** | **13** |
| 必删 | **2** |
| 重写 | **7** |
| 保留（合规 / 安全阀 / 设计取舍） | **4** |

一句话结论：**原生 Function Calling 已经接线且发货态是开的**（`AgentBridge.kt:482` 从 provider 能力位打开），但**工具的参数 Schema 仍然是 GBNF 时代的"全字符串扁平标量"形状**——55 个参数**无一例外**都是 `"type":"string"`，数字/布尔/数组全靠字符串编码再在工具内部二次解析。这不是"过度简化"的风格选择，而是**本地 GBNF 语法无法表达类型**留下的形状，直接削弱了原生 `tools` 的最大优势（模型靠 schema 就能填对类型）。

---

## A. 参数 Schema：全部退化成 string（最高优先级）

### A1 ★★★ 全部 55 个工具参数都是 `"type":"string"`

**证据（声明侧）**：`agent/src/main/kotlin/dev/heracles/agent/tools/*.kt` 全量统计

| 文件 | ToolParam 声明数 |
|---|---|
| `AndroidTools.kt` | 14 |
| `FileTools.kt` | 10 |
| `FsSearchTools.kt` | 7 |
| `PathTools.kt` | 7 |
| `PatchTools.kt` | 6 |
| `ArchiveTools.kt` | 4 |
| `ShellTools.kt` | 3 |
| `MetaTools.kt` | 2 |
| `ImageTools.kt` | 1 |
| `WebTools.kt` | 1 |
| **合计** | **55** |

第二个参数位置（`type`）的取值分布：**`string` 55 / 其它 0**。

**证据（传播侧）**：`core/src/main/kotlin/dev/heracles/core/context/PrefixBuilder.kt:158-159`

```kotlin
append('"').append(escape(p.name)).append("\":{\"type\":\"")
append(escape(p.type)).append("\",\"description\":\"")
```

`p.type` 原样写进 JSON Schema 的 `"type"` 字段 ⇒ 55 个参数在原生 `tools` 数组里**全部声明成 string**（`NativeToolSchema.canonicalBody` 直接解析这份 JSON，见 `provider-http/.../NativeToolSchema.kt:67-68`）。

**证据（成因，代码自己写着）**：`core/src/main/kotlin/dev/heracles/core/tool/ToolSpec.kt:6`

```kotlin
* **只允许扁平标量** —— 嵌套对象是小模型填错的头号来源（`02-契约规范.md` §4.2）。
```

**被压成 string 的语义类型（11 个参数）**：

| 参数名 | 真实语义 | 现在声明成 | 工具内部的二次解析 |
|---|---|---|---|
| `max_results` | integer | string | `FsSearchTools.kt:581` `text.toIntOrNull()` |
| `timeout_sec` | integer | string | `ShellTools.kt:121` `toIntOrNull() ?: DEFAULT` |
| `offset` | integer | string | `FileTools.kt:188` `toIntOrNull()` |
| `limit` | integer | string | `FileTools.kt:193` `toIntOrNull()` |
| `numbered` | boolean | string | `FileTools.kt:180-181` `in setOf("true","1","yes","y")` |
| `replace_all` | boolean | string | `PatchTools.kt:92` `in setOf("true","1","yes")` |
| `recursive` | boolean | string | （PathTools 递归开关） |
| `ignore_case` | boolean | string | （FsSearchTools） |
| `with_smali` | boolean | string | `AndroidTools` `!= "false"` |
| `steps` | **array of objects** | string | `TaskPlan.parseUpdate`（Gson 二次解析） |
| `questions` | **array of objects** | string | `AskUserArgs.parse`（Gson 二次解析） |

**为什么这对强模型有害**

1. **白送掉原生 FC 的核心优势**：GPT-4o 这类模型看 JSON Schema 的 `"type":"integer"` 就会填 `200`；看到 `"type":"string"` 就填 `"200"`。字符串化本身不致命，但**类型信息丢失后 schema 不再自我描述**——模型只能靠 description 里的自然语言提示（"最多返回多少条，默认 40，最多 200"）去猜这是个数字。
2. **布尔参数变成猜词游戏**：`numbered` 的 description 写着"是否给每行加行号…默认 false"，模型可能填 `"假"`、`"False"`、`"0"`、`"no"`、`"否"`。工具只认 `setOf("true","1","yes","y")`（`FileTools.kt:180-181`）⇒ **除 true 系列外一律当 false**，包括模型明确想开启时写的 `"True"`（大小写已 lowercase，OK）但 `"Y"`/`"on"`/`"是"` 全是静默 false。
3. **数组参数被塞进字符串**：`update_plan.steps` 的 description（`MetaTools.kt:32-39`）被迫写成一长串转义 JSON 示例：
   ```
   "JSON 数组，例如 [{\"text\":\"查看项目结构\",\"status\":\"done\"},...]"
   ```
   模型要在**一个字符串参数里**生成合法 JSON 数组，还得自己转义双引号。这正是 GBNF 时代"用 CDATA/标签绕转义"的同一种病，只是换到了参数层。

**判定**：**重写**（`ToolParam.type` 提升为真正的类型，`steps`/`questions` 改成 schema 级 `array`/`object`）· 置信度 **高**

---

### A2 ★★ 参数长度上限 500 字符：`steps` 与 `old_string`/`new_string` 会被误杀

**证据**：`core/src/main/kotlin/dev/heracles/core/tool/ToolValidator.kt:109-115`

```kotlin
private fun limitFor(paramName: String): Int = when (paramName) {
    "content", "text", "body", "code" -> MAX_CONTENT_LENGTH   // 100_000
    "patch", "diff" -> MAX_CONTENT_LENGTH                      // 100_000
    "command" -> MAX_COMMAND_LENGTH                            // 4_000
    else -> MAX_ARG_VALUE_LENGTH                               // 500
}
```

`MAX_ARG_VALUE_LENGTH = 500`（`ToolValidator.kt:123`），注释的理由是：

```kotlin
* 500 是个经验值：联系人名、搜索关键词、应用名都远短于它；
```

**这条规则写于 2026-10-09/10-16，而两个"长文本参数"是后来才加的工具**：

| 参数 | 所属工具 | 白名单里有吗 | 实际上限 | 实测长度 |
|---|---|---|---|---|
| `steps` | `update_plan`（2026-10-19） | ❌ 不在 | **500** | **中文 6 步 = 254 字符**；**英文 6 步 = 513 字符 ⇒ 超限被拒** |
| `old_string` | `edit`（2026-10-19） | ❌ 不在 | **500** | 一个 10 行方法体 ≈ 236 字符；**改一整个类/函数必然超限** |
| `new_string` | `edit`（2026-10-19） | ❌ 不在 | **500** | 同上；**写超过 500 字符的替换文本必然被拒** |
| `questions` | `ask_user`（2026-10-21） | ❌ 不在 | **500** | 2 题带 description = 225 字符；**3–4 题带说明就会超** |

校验器对**每条**工具调用都跑（`AgentLoop.kt:1675/1929`、`TurnRecord.kt:209-210`），原生轨也一样。

**失败表现**：`参数 new_string 超长（612 > 500）` → 模型必须把一次编辑拆成多次小编辑，或退回 `write_file` 整文件重写（而 `apply_patch` 的 `patch` 是白名单 100KB，反而没事）。**同一件事，换个工具名就从 100KB 变成 500 字节**——这是纯粹的命名耦合，不是设计。

⚠️ 注意：这不是"小模型限制"的残留，而是**小模型时代的白名单没跟上新工具**的漏改。但它对强模型的伤害与小模型限制同效：**强模型更愿意一次改一大段**，于是更容易撞墙。

**判定**：**必删**（改成按参数语义/`ToolParam` 声明上限，而不是按名字硬编码白名单）· 置信度 **高**

---

## B. 工具注册表：常驻/长尾两段式披露（为 4B 与省 prefix 设计的架构）

### B1 ★ 常驻上限 12：理由是"4B 在 ~10 个工具后选择准确率下降"

**证据**：`core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:139-152`

```kotlin
* 旧值 **8 / 12 / 3** 是**为本地 4B + 4096 上下文**定的（契约 §4.1：可见工具数过 ~10 后
* 4B 的选择准确率显著下降），随本地一起退场 —— 撤销清单见 `docs/09` ADR-035 的 12 条表。
...
const val FROZEN_LIMIT = 12
```

`core/src/main/kotlin/dev/heracles/core/tool/ToolRegistry.kt:15`

```kotlin
* | 工具不能多 | 契约 §4.1 | **可见工具过多 ⇒ 选择准确率下降**（该条原是对 4B 实测的，云端阈值更宽） |
```

**现状**：`agent/src/main/kotlin/dev/heracles/agent/ToolZonePlan.kt:85-101` 的 `RESIDENT` = **11 个**（10 业务 + `update_plan`），加 `search_tools` 自己 = **12/12 顶满**。测试 `ToolZonePlanTest.kt:93/105` 用断言钉死"11 / 12"。

**影响强模型的具体后果**（这才是要报的点，不是数字本身）：

1. **`edit` 工具被挤到长尾**——它是 2026-10-19 为"对齐成熟产品 `edit(old_string,new_string)` 形状"而新写的（`PatchTools.kt:52-58`），却因为常驻已满 12 只能走 `search_tools` 两段式。模型"只用手里有的工具"（仓库自己的结论，`ToolZonePlan.kt:48`），于是**大概率永远想不起用它，继续整文件重写**——而整文件重写正是 `edit` 存在的理由。
2. **`ToolZonePlan.kt:35-36` 明确写着**："往 RESIDENT 里加第 11 个名字就会把它顶到 12、加第 12 个就在 `buildFrozen` 的 require 上当场抛"。⇒ 想常驻 `edit`，必须先挪走一个业务工具。这是**架构层面的准入限制**，不是调参。
3. `Contract.kt:150` 自己承认要"留空位，不要顶满"，而实际是 12/12 顶满。

**判定**：**重写**（`FROZEN_LIMIT` 的理由已失效；强模型 30–50 个工具的选择准确率仍很高，且原生 `tools` 不进 prefix cache 的话更无成本约束）· 置信度 **高**

---

### B2 ★ 两段式披露（`search_tools`）整体是 4B 时代的缓存妥协

**证据链**：

- `core/src/main/kotlin/dev/heracles/core/tool/ToolRegistry.kt:10-21`：常驻上限是"两条硬约束的交点"——① 冻结区要短（缓存命中率 > 90%）② 工具不能多（4B 选择准确率）
- `agent/src/main/kotlin/dev/heracles/agent/tools/MetaTools.kt:52-59`：`search_tools` 存在的理由同上，"该规律原是在 4B / 约 10 个上实测的"
- `ToolRegistry.kt:23-29`：整个披露机制成立的前提是"工具名枚举在 GBNF 里，GBNF 是请求参数、不进前缀缓存"——**这是 llama.cpp 的性质**

**现状对强模型的实际成本**：

| 成本 | 说明 |
|---|---|
| 多一轮 | 模型想用长尾工具必须先调 `search_tools`，等结果，再调真工具 —— **每次至少多一整轮** |
| 检索失配即静默失败 | 检索是 `haystack.contains(term)` 子串匹配（`ToolRegistry.kt:121-135`），模型说"我要改代码"不在 `edit` 的关键词面里就搜不到 ⇒ 模型回"我做不到"，**没有任何报错** |
| 长尾 22 个工具对模型不可见 | 22 个能力被藏在一次关键词搜索后面 |

⚠️ 但**原生 `tools` 已接线**（`AgentBridge.kt:482`）⇒ `tools` 数组走 `activeTools()`（`AgentLoop.kt:501-502`，含已披露长尾）⇒ **`tools` 数组确实不再受 prefix cache 影响**（它不进 `frozenPrefix`）。于是"披露是为了省前缀"这个核心论据**在原生轨下已经不成立**，只剩"工具太多模型会选错"这条 4B 结论。

**判定**：**重写**（原生轨下应直接把全部工具放进 `tools` 数组，`search_tools` 降级为兼容/可选）· 置信度 **中-高**

---

### B3 `ToolRegistry.search` 的子串匹配 + 人工关键词表（脆弱）

**证据**：`core/src/main/kotlin/dev/heracles/core/tool/ToolRegistry.kt:121-135`

```kotlin
private fun score(spec: ToolSpec, lowerQuery: String, terms: List<String>): Int {
    val hay = buildString { ... }
    var s = if (hay.contains(lowerQuery)) 2 else 0
    for (t in terms) if (hay.contains(t)) s++
    return s
}
```

配合 `core/src/main/kotlin/dev/heracles/core/tool/ToolGroup.kt:24-66`（9 个手工分组的关键词表，含 `IMAGE` 组特意加了 15 个中文整句说法）。

`ToolGroup.kt:52-59` 自己记录了真机事故：`view_image` 早先挂在 FILE 组 ⇒ 搜"查看图片"搜不到 ⇒ 模型回"我没有看图的工具"。

**判定**：**重写**（如保留披露机制，应改为语义检索/BM25；不该继续往关键词表里堆词）· 置信度 **中**

---

### B4 `discloseLimit = 6` / `longTailLimit = 24` 的取舍注释

**证据**：`Contract.kt:160-167`、`170-176`。理由都是"原云端档"，服务于"披露太多撑爆 C 区 / `prompt_n` 增量目标 150"——这是**本地 4096 上下文时代**的 token 预算约束。

**判定**：**保留但降级**（数值本身不致命，但理由已失效，应重新标定）· 置信度 **中**

---

## C. 原生 Function Calling：已接线，但默认值与文档在误导

### C1 ★ 发货态已开原生轨；但类默认 `false` + 大段"刻意不发"KDoc 是过时的

**证据（发货态确实开了）**：`app/android/app/src/main/kotlin/com/theohowie/heracles/bridge/AgentBridge.kt:469-482`

```kotlin
val loop = AgentLoop(
    ...
    nativeToolsEnabled = provider.capabilities.supportsNativeTools,
```

三家云端 provider 的 `supportsNativeTools` 全是 `true`（`OpenAiCompatProvider.kt:103`、`AnthropicProvider.kt:107`、`OpenAiResponsesProvider.kt:84`）⇒ 真机上**原生轨是开的**。

**证据（类默认仍是 false）**：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:426`

```kotlin
private val nativeToolsEnabled: Boolean = false,
```

**问题**：`AgentLoop.kt:395-424` 有约 30 行 KDoc 在论证"默认 false，且这一步**刻意不发**（这不是保守，是安全）"，理由是"响应侧还没落地"。但响应侧**已经落地**（`AgentOutputParser.fromNativeCall`、`Turn.Assistant(nativeCalls)`、`NativeToolCall`、`NativeCallAssembler`、`NativeToolFlowTest` 973 行）。

⇒ **KDoc 与现实脱节**。后果：CLI / 单测默认走文本轨 ⇒ **文本轨永远有"消费者"**，那套 CDATA/信封协议就永远删不掉（这正是类别 3 的最大包袱）。

**判定**：**重写**（KDoc 与默认值二选一改；建议默认 true，让文本轨真的变成"显式关闭才走"的兼容路径）· 置信度 **高**

---

### C2 ★ 文档与实现漂移：`NativeToolSchema` 说"只装常驻"，实现装 `activeTools()`

**证据（文档）**：`provider-http/src/main/kotlin/dev/heracles/provider/http/NativeToolSchema.kt:34-38`

```kotlin
* ## 只装常驻工具（与披露机制天然冲突）
*
* 长尾工具是**逐轮披露**的（ADR-023）。若把它们也塞进 `tools` 数组，数组会随披露
* **变长** ⇒ 前缀每次都抖、缓存命中率全塌。所以数组只装常驻工具；
* 披露工具继续走文本轨。**这是设计取舍，不是遗漏。**
```

**证据（实现）**：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:501-502`

```kotlin
internal fun nativeToolSpecs(): List<dev.heracles.core.tool.ToolSpec> =
    if (nativeToolsEnabled) activeTools().map { it.spec } else emptyList()
```

`activeTools()` = 常驻 + **已披露长尾**。`AgentLoop.kt:483-491` 的 KDoc 已说明反转理由（"只发常驻等于长尾工具彻底不可用"）。

**判定**：**重写**（改 `NativeToolSchema` 的 KDoc，否则下一次改动会按错的文档做）· 置信度 **高**

---

### C3 `NativeSkip.PARALLEL` 的文案与 `MAX_NATIVE_CALLS_PER_TURN = 4` 矛盾（死常量）

**证据**：`agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2898-2899`

```kotlin
/** 一轮收到 ≥2 个调用（`Contract.Tools.MAX_NATIVE_CALLS_PER_TURN = 1`）。 */
const val PARALLEL = "本实现一次只支持一个原生工具调用"
```

而 `Contract.kt:197` 是 **4**，且 v2 已"全部执行"。全仓库 grep `NativeSkip.PARALLEL`：**只有定义，零使用**。

**判定**：**必删**（死常量 + 错误文案；留着会误导下一次改动把并行逻辑改回 1）· 置信度 **高**

---

### C4 `NativeToolSchema.kt` 的"流式分片契约"KDoc 与 v1/v2 口径混写

**证据**：`NativeToolSchema.kt:55-57`

```kotlin
* 3. 一轮里可能有**多个** `tool_calls`（并行调用）—— 我们**只执行一个**
*    （`Contract.Tools.MAX_NATIVE_CALLS_PER_TURN`），≥2 个时**报错并明说收到了几个**，
*    **不许静默丢**（模型会以为它调了三个工具）。
```

实现是"最多执行 4 个，超出的配对回填未执行"（`AgentLoop.kt:1892-1911`），**不是"报错"**。

**判定**：**重写**（改 KDoc）· 置信度 **高**

---

### C5 `ToolValidator` 的"未知参数一律拒绝"在原生轨下过严

**证据**：`core/src/main/kotlin/dev/heracles/core/tool/ToolValidator.kt:48-53`

```kotlin
// 无未知参数 —— 小模型常见错误是臆造参数名
val known = spec.parameters.map { it.name }.toSet()
val unknown = call.args.keys - known
if (unknown.isNotEmpty()) {
    return Result.Invalid("出现未知参数：${unknown.joinToString()}")
}
```

注释直说这是**小模型**的错。而原生轨下模型可能按**它以为的** schema 填——尤其当 schema 全是 string、description 里又举例时。整条调用被拒（不执行），比"忽略多余参数"代价大。

**判定**：**保留但降级**（注释里的理由已被 C2/B1 削弱；但"拒绝未知参数"符合"不猜"铁律，可留）· 置信度 **中**

---

## D. 保留：这些不是小模型遗迹

| # | 位置 | 为什么保留 |
|---|---|---|
| D1 | `ToolZonePlan.kt:127-136` 越档 `require` 当场抛 | **不静默截断**是正确纪律（截断会让模型以为工具不存在） |
| D2 | `AgentTool.parallelSafe` 默认 false（`TurnRecord.kt:184-205`） | 并发安全的保守默认，与模型强弱无关 |
| D3 | `ToolValidator` 的 `allowEmpty` / `optional` 两个正交位（`ToolSpec.kt:38/82`） | 这是**为原生 JSON Schema 的 `required` 服务**的正确设计（`PrefixBuilder.kt:151` 只把 `optional=false` 列进 required） |
| D4 | `update_plan` 的 `execute` 返回失败（`MetaTools.kt:43-44`） | 显式失败优于假装成功，正确 |

---

## Top 5 优先级（本类别）

1. **A2 必删**：`ToolValidator.limitFor` 的 500 字符白名单 —— `edit` 的 `old_string`/`new_string`、`update_plan.steps`、`ask_user.questions` 全被 500 卡住；实测英文 6 步计划 513 字符**直接超限**。这是当下最可能让强模型"莫名改不动文件"的一处。
2. **A1 重写**：55 个参数全是 `"type":"string"` —— 原生 FC 的类型信息全丢，布尔/数字/数组靠猜词。
3. **B1 重写**：常驻 12 上限的理由（4B 选择准确率）已失效，且它把 `edit` 挤到长尾、顶满无余量。
4. **C1 + C2 重写**：`AgentLoop.nativeToolsEnabled` 的过时 KDoc + `NativeToolSchema` 的"只装常驻"错误文档 —— 二者共同维持"文本轨仍有消费者"的假象，是类别 3 那套 CDATA 协议删不掉的根因。
5. **C3 必删**：`NativeSkip.PARALLEL` 死常量（`= 1` 的文案 vs 实际 4）。

## 已排除的误报

| 位置 | 为什么不是遗迹 |
|---|---|
| `AgentBridge.kt:1244` `MAX_ATTACHMENT_CHARS = 8000` | 附件注入是**每轮重发**的真实 token 成本，属合理安全阀 |
| `ToolValidator.MAX_CONTENT_LENGTH = 100_000` | 足够放下正常源文件，合理 |
| `Contract.Tools.RESULT_DIFF_MAX_LINES = 40` | 写回执 diff 上限，**如实报剩余行数**，合理 |
| `Contract.Media.*`（4MB / 4 张） | 多模态图片每轮重计 token，合理 |
| `FsSearchTools` 的 `MAX_RESULTS_CAP = 200` | 注释已明说"不是为本地算的"，且 append-only 会话里超长结果永久占上下文，合理 |
| `search_tools` 无命中时返回 `Failure` 而非"最接近的几个" | **正确**：硬凑结果会诱导误用工具，比"没找到"更糟 |
| `AndroidTools.assertConsistent` / `PathTools.assertConsistent` 启动期抛 | 正确的启动期门禁，防静默退化 |
