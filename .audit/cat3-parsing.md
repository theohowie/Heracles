# 类别 3 审计：解析与容错类小模型限制遗迹

> 审计对象：`D:\AllCode\Agent\Heracles`（只读审计，未改动任何代码/配置/文档）
> 判断标准（AGENTS.md 铁律）：**catch 之后"猜/修/兜底"= 违规 Hack；"如实失败/明确回告"= 合规**。
> 每条均实际读过源码（read/grep），行号可复核。

## 统计摘要

| 项 | 数量 |
|---|---|
| **发现总数** | **50** |
| 必删 | **3** |
| 重写 | **21** |
| 保留（合规，或安全阀） | **26** |

分布：A JSON 解析与 try-catch **18**（必删 1 / 重写 6 / 保留 11）· B 正则修 JSON **10**（1 / 4 / 5）· C 重试与熔断 **8**（0 / 3 / 5）· D 文本轨 vs 原生轨 **8**（1 / 6 / 1）· E 截断/空响应 **6**（0 / 2 / 4）。

一句话结论：**解析器本身大体守住了"不猜"这条铁律**（真正危险的是极少数"静默吞掉失败"的点：`AnthropicProvider.inputOf` → `{}`、JSONL 坏行 → `continue`）；**真正的历史包袱在"文本轨协议"这一整套**（`<write_file>`/`<apply_patch>` + CDATA + `{"tool":…}` 信封 + 教它三种顶层形状的纠正提示），它的存在理由（本地 GBNF 禁转义）已随 ADR-035 消失。

---

## A. JSON 解析与 try-catch

| # | 文件:行号 | 代码摘录（≤6 行） | 在容忍什么 / 做了什么 | 对强模型为何有害（或为何仍必要） | 判定 | 置信度 |
|---|---|---|---|---|---|---|
| A1 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:47` | `val json = runCatching { JsonParser.parseString(text).asJsonObject }.getOrElse { return AgentOutput.Unparseable("不是合法 JSON，也不是 <write_file> 标签") }` | 顶层 JSON 解析失败 ⇒ 返回 Unparseable，**不修、不猜** | 这就是铁律第 3 层的正确形态：不执行任何工具、如实回告。**保留**（但注意它的"不是 <write_file> 标签"文案本身绑定了文本轨，见 B2） | 保留 | 高 |
| A2 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:72-73` | `val argsObj = runCatching { json.getAsJsonObject("args") }.getOrNull()`<br>`val args = argsObj ?: flatArgs(json)` | 没有 `args` 键时，把 `tool` 之外的**所有顶层字段**当参数（`flatArgs`，同文件 254-260） | 这是典型的"替模型补格式"：强模型（尤其原生轨）不会把参数平铺在顶层；而该兜底在 `{"tool":"x","name":"y"}` 这种真实畸形下会把 `name` 静默当参数，**校验器只会在"未知参数"上再失败一次**，白跑一轮。原生轨已无此形态 | 重写 | 高 |
| A3 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:95` | `val entries = json.entrySet()`<br>`if (entries.size == 1) { val (key, value) = entries.first(); if (key in knownTools && value.isJsonObject) { return AgentOutput.ToolRequest(...) } }` | "工具名当顶层键"（`{"apply_patch":{…}}`）归一化 | **不是小模型遗迹**：KDoc 77-94 记录的是 2026-10-19 大模型真机现场；键必须在 `knownTools` 白名单内、未知名仍 Unparseable，且下游 `ToolValidator` 一步不少 ⇒ 属"归一无歧义形状"，**保留** | 保留 | 高 |
| A4 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:142` | `val el = runCatching { JsonParser.parseString(json) }.getOrNull()`<br>`if (el == null !el.isJsonObject) { return AgentOutput.Unparseable("原生 tool_calls 的 arguments 不是合法 JSON 对象：…") }` | 原生 `arguments` 不是合法 JSON 对象 ⇒ Unparseable（不执行） | 原生轨唯一入口的"不猜"守卫，完全合规。空串与 `{}` 视为无参数也是明写的契约 | 保留 | 高 |
| A5 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:244-251` | `out[k] = if (v.isJsonNull) "" else runCatching { v.asString }.getOrElse { v.toString() }` | 参数值一律转字符串（数字/布尔/对象都 `toString()`）；注释说"模型偶尔把数字写成不带引号的形式" | 对强模型是**信息损失 + 掩盖类型错**：原生轨的 `arguments` 本来带类型（`{"limit":200}`），强转字符串后连嵌套对象（`v.toString()` 得到 `{"x":1}` 这样的 JSON 文本）也照样过校验，工具侧只能看到一个字符串。`toString()` 兜底让"模型给了对象"这一层事实彻底消失 | 重写 | 中 |
| A6 | `provider-http/src/main/kotlin/dev/heracles/provider/http/HttpJson.kt:61` | `val el = JsonParser.parseString(raw)`<br>`require(el.isJsonObject) { "期望 JSON 对象，实际收到：" + … }` | 响应不是 JSON 对象 ⇒ 可读的 `HttpJsonException`/IllegalArgumentException | 合规：不猜服务端形状，失败如实抛。`getJson`（75-80）同型 | 保留 | 高 |
| A7 | `provider-http/src/main/kotlin/dev/heracles/provider/http/HttpJson.kt:234` | `runCatching { val o = JsonParser.parseString(raw).asJsonObject; o.getAsJsonObject("error")?.… }`<br>`return raw.take(400)` | 错误体解析失败 ⇒ 回退到原始文本前 400 字 | 合规：只为"把服务端原因读出来"，**不参与任何执行决策**；失败仍有原文兜底，不伪造原因 | 保留 | 高 |
| A8 | `agent/src/main/kotlin/dev/heracles/agent/DuplicateKeys.kt:136` | `} catch (e: Exception) {`<br>`// 纪律：扫不动**不许**静默当作"没重复"`<br>`return Scan.Unusable("遍历失败：${e.message}") }` | 扫描器遍历异常 / 超深 / lenient 语法 ⇒ Unusable | 这是"catch 之后不回退到乐观默认值"的**正面样板**（`Clean` 语义被严格限定为"走完了一个完整值且无重复键"）。`BuildProfileLoader.kt:143-146` 把它当**拒绝**处理，正确 | 保留 | 高 |
| A9 | `agent/src/main/kotlin/dev/heracles/agent/BuildProfileLoader.kt:124` | `val rootEl = try { JsonParser.parseString(raw) } catch (e: Exception) { return invalid(path, "不是合法 JSON：${e.message}") }` | 配置解析失败 ⇒ `Invalid`（带原因）；`load()` 的 catch（104-111）也只是把异常翻译成 `Invalid`，**永不抛、不静默** | 合规。`rejectUnknown` + 重复键 + schemaVersion 三层都"明确失败"，是 H-1 的正确姿势 | 保留 | 高 |
| A10 | `agent/src/main/kotlin/dev/heracles/agent/TaskPlan.kt:131` | `val obj = runCatching { com.google.gson.JsonParser.parseString(raw) }.getOrNull() ?: return null`<br>`if (!obj.isJsonObject) return null` | 计划解析失败 ⇒ `null`（"不造空计划"） | 合规：`fromJson`（115）也走同一条，损坏的落盘文件 ⇒ null，不会造出假进度 | 保留 | 高 |
| A11 | `agent/src/main/kotlin/dev/heracles/agent/TaskPlan.kt:205` | `"done", "completed", "complete", "完成", "已完成" -> Status.done`<br>`"active", "doing", "current", "进行中", "正在做" -> Status.active` | 状态字符串多语言同义词 + 认不出 ⇒ pending | 这是**替小模型补语义**：`update_plan` 的 `status` 是原生 JSON Schema 的枚举（强模型会照 schema 填）；这里把"进行中/正在做"也当合法，意味着**拼错的枚举被静默降级成 pending**，进度条于是"滞后但没有报错"——把模型的格式错误变成无人知道的进度偏差 | 重写 | 中 |
| A12 | `agent/src/main/kotlin/dev/heracles/agent/AskUserArgs.kt:82-83` | `val id = o.get("id")?.takeIf { it.isJsonPrimitive }?.asString`<br>`    ?.takeIf { it.isNotBlank() } ?: "q${i + 1}"` | 缺 `id` 时**自动编号** `q1/q2…`；`multi` 缺省 false；`options` 裸字符串也认（64-107） | 前两条是"形状归一、不猜语义"（KDoc 19-27 明写），但**自动生成 id** 属于"替模型补它没给的东西"：id 是回填答案的键，自动生成后模型看到的 id 与它自己写的不一致（虽然工具/UI 两侧同源，仍是隐式契约）。形状三种都认可保留，自动 id 应改为明确失败 | 重写 | 中 |
| A13 | `agent/src/main/kotlin/dev/heracles/agent/AskUserArgs.kt:26` | `* 形状不对 ⇒ 返回**空列表**（调用方据此报失败）。**绝不**用正则猜、`<br>`* 也绝不把解析失败的字符串当题干塞给用户。` | 解析边界声明 + `parse()` 的"任一题不合法整体失败"（33-44） | 合规的正面样板：部分可用会让人与模型看到的题数不一致，作者选择了整体失败 | 保留 | 高 |
| A14 | `provider-http/src/main/kotlin/dev/heracles/provider/http/OpenAiCompatProvider.kt:240` | `val root = runCatching { JsonParser.parseString(event.payload).asJsonObject }.getOrNull()`<br>`    ?: return@collect // 非 JSON 的心跳块，跳过` | 流里非 JSON 的心跳/坏行 ⇒ 跳过 | 合规：SSE 传输层允许注释/心跳，跳过一行坏数据不等于猜模型意图（且真正的 `error` 分支 257-269 是**读人话再抛**） | 保留 | 高 |
| A15 | `provider-http/src/main/kotlin/dev/heracles/provider/http/AnthropicProvider.kt:434` | `private fun inputOf(json: String): JsonElement =`<br>`  runCatching { com.google.gson.JsonParser.parseString(json.ifBlank { "{}" }) }`<br>`    .getOrNull()?.takeIf { it.isJsonObject } ?: JsonObject()` | 历史回放时 `arguments` 解析不了 ⇒ **退化成空对象 `{}` 发出去** | **最危险的一条**：注释说"绝不编造参数"，但实际是在 wire 上把畸形参数**替换成"没有参数"**。强模型下的后果是：历史里的 `tool_use` 与实际参数不一致，服务端看到的是"模型当初没传参数"，行为不可预测且**没有任何日志**。应改为明确失败/丢弃该轮（原生轨已有配对校验可复用） | 必删 | 高 |
| A16 | `app/android/app/src/main/kotlin/com/theohowie/heracles/bridge/SessionStore.kt:418-421` | `for (line in text.lineSequence()) {`<br>`  val t = line.trim()`<br>`  if (t.isEmpty()) continue`<br>`  val o = runCatching { JSONObject(t) }.getOrNull() ?: continue` | JSONL 坏行 ⇒ **静默跳过** | 这是在容忍"写坏的会话文件"：强模型不背这个锅，但用户会**看不到那条消息且不知道丢了**。它违反同仓库反复强调的"静默 = 放过"（对比 `DuplicateKeys` 的 Unusable、`WorkspaceSnapshot.kt:75-117` 专门写的"读不到 ≠ 空，必须明说"）。至少应留痕/插入一条"第 N 行损坏"的 system 记录 | 重写 | 中 |
| A17 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:1467` | `val parsed = when {`<br>`  nativeCalls.isNotEmpty() -> AgentOutputParser.fromNativeCall(nativeCalls.first())` | 一轮多个原生调用时，**只按第一个**决定"这一轮解析成功与否" | 若第一个参数畸形而第 2-4 个合法，整轮落到 2128-2136：`appendNotExecuted(raw, nativeCalls, VALIDATION)` 把**所有**调用配对回填成"未执行"，合法调用被一起废掉。这不是"猜"，但属"解析失败的爆炸半径过大"——强模型并发调用会常态化 | 重写 | 中 |
| A18 | `app/android/app/src/main/kotlin/com/theohowie/heracles/MainActivity.kt:1271` | `private fun parseReasoningLevel(raw: String?): ReasoningLevel {`<br>`  if (raw.isNullOrBlank()) return ReasoningLevel.AUTO`<br>`  … "auto" -> ReasoningLevel.AUTO`<br>`  else -> { println("HERC-CONFIG 未知推理等级「$raw」→ 回落 AUTO"); ReasoningLevel.AUTO }` | 跨进程字符串弱契约认不出 ⇒ 回落 AUTO + **打日志** | 合规：跨进程版本错位不是模型输出，回落到最保守行为且留痕（对比"静默吞掉"），可保留 | 保留 | 高 |

---

## B. 正则修 JSON / 补格式

> 结论先说：`AgentOutputParser` **没有**出现 `replace("'", "\"")`、补大括号、截取 `{...}` 子串这类典型"正则修 JSON"。它做的三件事——剥 markdown 围栏、CDATA 标签、args 平铺——性质各不相同。

| # | 文件:行号 | 代码摘录（≤6 行） | 在容忍什么 / 做了什么 | 对强模型为何有害（或为何仍必要） | 判定 | 置信度 |
|---|---|---|---|---|---|---|
| B1 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:36` + `:269-283` | `val text = stripFences(raw).trim()`<br>`… if (!t.startsWith("```")) return t`<br>`t = t.substring(firstNewline + 1)`<br>`val lastFence = t.lastIndexOf("```"); if (lastFence >= 0) t = t.substring(0, lastFence)` | 剥 markdown ``` 围栏（可能带 `json` 语言标注） | 只剥"外层包装"，**不修内部语法**，且失败仍落 Unparseable ⇒ 方向是对的。但它是文本轨专属（原生轨的正文/参数不经过它），且 `json_object` 下强模型已很少包壳。可保留为低风险防御，但**不该再被当成主要手段** | 重写 | 中 |
| B2 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:194-220` + `:231-237` | `val shape = CDATA_SHAPES.firstOrNull { text.startsWith("<${it.tag}") } ?: return null`<br>`val pathMatch = PATH_RE.find(text) ?: return AgentOutput.Unparseable(...)`<br>`val open = text.indexOf("<![CDATA[")`<br>`val close = text.lastIndexOf("]]>")`<br>`CdataShape("write_file","content"), CdataShape("apply_patch","patch")` | 自研 `<write_file path=…><![CDATA[…]]></write_file>` / `<apply_patch>` 解析器（正则 + 手工切字符串） | **这是最大的一块历史包袱**。它的存在理由在 `agent/.../ToolZonePlan.kt:52-56` 里写着：本地 GBNF 的 `str ::= [^"\\]*` **禁转义**，代码里的 `"`/`\` 过不了 JSON 通道，所以走 CDATA。该前提已随 ADR-035 删除 ⇒ 强模型有原生 `tools` + `apply_patch`/`write_file` 的 JSON Schema，**不需要第二套写入方言**。保留它 = 维持双轨、让模型有概率把调用写进正文而原生优先会忽略（静默失败，见 D1） | 必删 | 高 |
| B3 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:236` | `private val PATH_RE = Regex("""path\s*=\s*"([^"]*)"""")` | 从标签属性里取 `path` | 若 B2 删除则连坐消失；单独看它是"固定形状的属性提取"，不是修 JSON。**随 B2 一起删**，本身不作为独立 Hack 计 | 保留 | 高 |
| B4 | `agent/src/main/kotlin/dev/heracles/agent/AgentOutputParser.kt:52` | `if (json.has("final") && !json.get("final").isJsonNull) {`<br>`  return AgentOutput.FinalAnswer(json.get("final").asString) }` | 有 `final` 就**优先收工**，不再看 `tool` | 文本轨时代的"收尾判定"：它把"同时给了最终回答与工具调用"这一种**歧义**用固定优先级消解。强模型在原生轨下正文是普通文字（由 1474 兜成 FinalAnswer），这条只在文本轨可达；但它会把"其实还想调工具"的那一轮静默当收工。原生轨普及后应删 | 重写 | 中 |
| B5 | `core/src/main/kotlin/dev/heracles/core/patch/UnifiedPatch.kt:103` | `val m = HUNK_HEADER.find(lines[i])`<br>`if (m == null) {`<br>`  // 修改块之间允许有元信息头；其它意外行一律忽略（宽容解析）`<br>`  i++; continue }` | 修改块之外认不出的行**一律跳过** | "宽容解析"在小模型时代能让模型少写坏（模型常在 diff 前后加解释文字）。但强模型的 `apply_patch` 参数经过 JSON 校验，脏行意味着**模型给了坏补丁**；静默跳过会让"补丁只应用了一半的块"变成"看起来成功"——与同文件 62-66 的原子性声明（失败不得半写入）在精神上冲突。至少应统计"跳过了 N 行"并回执 | 重写 | 中 |
| B6 | `core/src/main/kotlin/dev/heracles/core/patch/UnifiedPatch.kt:119` + `:123-124` | `isMetaLine(raw) -> { /* 跳过 */ }`<br>`raw.startsWith("+") -> …Add(raw.substring(1))`<br>`// 完全空行：多数生成器把"空上下文行"写成空串（省掉前导空格）`<br>`raw.isEmpty() -> body.add(PatchLine.Context(""))` | 跳过 `diff --git`/`index`/`---`/`+++` 等元信息；**空行当上下文行** | 元信息跳过是合理的（模型可能整段粘贴 `git diff` 输出）；但"空行 = 空上下文行"是**替模型补前导空格**——unified diff 里空上下文行应为 `" "`。这个补法一旦猜错，会把空行插进匹配序列（同文件 90-98 已记录过"末尾换行被当空上下文行"的同类 bug），且失败信息是"上下文对不上"，模型无从知道是空格问题 | 重写 | 中 |
| B7 | `core/src/main/kotlin/dev/heracles/core/patch/UnifiedPatch.kt:153` + `:260-261` | `* 3. 0 处命中 → 再用"忽略行尾空白"重试一次（并如实标记）`<br>`private fun sameLine(a: String, b: String, tolerant: Boolean): Boolean =`<br>`  if (tolerant) a.trimEnd() == b.trimEnd() else a == b` | 精确匹配失败后，**忽略行尾空白**再试一次，并用 `whitespaceTolerant` 标记 | **可保留的容错**：范围最窄（只 trimEnd）、只在 0 处命中时用、且**如实回报**（`ApplyResult.Ok.whitespaceTolerant`，工具层 220-224 把它写进回执）。这是"受控且可观测"的容错，与"猜意图"不同 | 保留 | 高 |
| B8 | `core/src/main/kotlin/dev/heracles/core/patch/UnifiedPatch.kt:189` | `hits.size > 1 -> return ApplyResult.Failed(`<br>`  "第 ${n + 1} 个修改块的上下文在文件中出现 ${hits.size} 次，无法确定改哪一处。请补足上下文行使其唯一。"` | 多处命中 ⇒ **拒绝**而不是改第一处 | 合规的正面样板（"猜着改一处是最坏的结果"）；强模型同样受益，应保留 | 保留 | 高 |
| B9 | `core/src/main/kotlin/dev/heracles/core/patch/UnifiedPatch.kt:226-231` | `if (changed == 0) { return ApplyResult.Failed(`<br>`  "补丁里没有任何改动：只有 @@ 块头，没有以 + 或 - 开头的行。…" ) }` | 空补丁 ⇒ **失败**（历史上曾返回 Ok） | 2026-10-19 真机教训的直接修复：不许"报成功但什么都没改"。合规，保留 | 保留 | 高 |
| B10 | `agent/src/main/kotlin/dev/heracles/agent/TaskPlan.kt:141-166` | `// ★★ 单步计划**有效**（2026-10-15 真机实测修复，BUG-3）★★`<br>`if (steps.isEmpty()) return null` | 单步计划也接受（旧实现 `steps.size < 2 ⇒ null`） | 方向正确：删掉的是"为了 UI 好看而拒绝合法输入"的过严规则。但它同时表明**协议层曾为展示效果扭曲解析**——这条留档即可，不需再改 | 保留 | 高 |

---

## C. 无脑重试 / 熔断

> 区分标准：**防死循环的安全阀 = 合理**；**替小模型擦屁股的"再试一次就好" = 有害**。本仓库没有"同一请求自动重放"式的文本轨重试（这是对的），重试只发生在 HTTP 层且边界写死在契约里。

| # | 文件:行号 | 代码摘录（≤6 行） | 在容忍什么 / 做了什么 | 对强模型为何有害（或为何仍必要） | 判定 | 置信度 |
|---|---|---|---|---|---|---|
| C1 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2716` | `const val MAX_IDENTICAL_TOOL_CALLS = 2`<br>`* 超过则**强制停止**。设为 2 的依据：首次端到端实测中模型`<br>`* 在目标已达成后仍重复了 5 次（`实测-08`）。` | 完全相同的工具调用（工具名+全部参数）连续 ≥2 次 ⇒ 硬停 | **合理安全阀**：判据已升级为结构化 `toolSucceeded`（2688-2706），"执行失败后的重试"不计数（2676），硬停时如实说明且 `reachedGoal=false`（1608-1619）。强模型也会陷入重复循环，保留 | 保留 | 高 |
| C2 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:1589-1622` | `if (repeats >= MAX_IDENTICAL_TOOL_CALLS) {`<br>`  val detail = "已连续 $repeats 次请求相同的操作，判定任务已完成并停止。"` | 第二次重复 ⇒ 硬停 + 合成 final + `appendNotExecuted(LOOP)` | 行为正确（不执行、如实报、原生轨配对回填）。**唯文案有问题**："判定任务已完成并停止"是**替模型下结论**——它没完成，只是被拦。见 C3 | 保留 | 高 |
| C3 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:1646-1656` | `val guidance = if (lastFailed) {`<br>`  "**注意：你上一次的操作没有成功，目标尚未达成。**" + …`<br>`} else {`<br>`  "…必须立即输出 {\"final\":\"<对用户的总结>\"} 结束任务。" }` | 重复调用被拦后，给模型一段"教练话术"，成功分支直接教它输出 `{"final":…}` | **文本轨 + 小模型时代的反向教练**：强模型在原生轨下"结束"就是普通文字（2846-2872 明写不需要 JSON 包装），这里却教它写 `{"final":…}`；而"被拦 ⇒ 教它收工"正是 `实测-08` 里"谎称已完成"的温床（KDoc 1627-1639 自己记了这个 bug）。原生轨下应改为"报告被拦的事实、不要宣称完成" | 重写 | 高 |
| C4 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2733` + `:2159-2206` | `const val CONSECUTIVE_UNPARSEABLE_LIMIT = 2`<br>`* 熔断阈值取 2：第一次失败值得重试（可能是偶发的格式漂移）；`<br>`* 连续两次同样的失败说明是**系统性**问题` | 连续 2 轮"输出无法解析" ⇒ **整个任务熔断** | 阈值 2 是**为"正文恒为空"那类本地系统性故障**定的（2161-2168 记录：llama.cpp 把预算烧在思考上）。强模型下一半问题现在是"协议形状漂移"（如 A3 的真机现场），**两轮就熔断等于把可自愈的格式漂移升级成任务失败**；而 `temperature=0` 下"重试必然复现同一错误"这个论点只对**同一提示**成立——2137-2153 恰恰会追加纠正提示，所以纠正后是**新上下文**，不该按"必然复现"处理。建议：阈值区分"纯空响应"(2) 与"形状漂移"(给纠正后至少 3-4 轮) | 重写 | 高 |
| C5 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2173-2176` | `val consecutiveUnparseable = records`<br>`  .takeLast(CONSECUTIVE_UNPARSEABLE_LIMIT)`<br>`  .count { it.verdict.startsWith("输出无法解析") }` | 用**中文字符串前缀**判定"这一轮是解析失败" | 熔断判据建在 verdict 文案上。同仓库 `TurnRecord.kt:31`/`AgentBridge.kt:989` 已经把"靠中文子串猜状态"记为 H-1 类脆弱做法并改成了结构化 `toolState`；这里**漏改**。文案一改（例如加前缀）熔断就静默失效 | 重写 | 高 |
| C6 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2415-2486` | `var attempt = 0`<br>`while (true) { attempt++`<br>`  …`<br>`val clean = text.isEmpty() && reasoning.isEmpty() && terminalCalls.isEmpty()`<br>`if (retryable && clean && attempt <= Contract.Provider.RETRY_MAX_ATTEMPTS) {`<br>`  delay(RETRY_BASE_DELAY_MS * (1L shl (attempt - 1))); continue }` | 429/5xx 退避重试；**只在还没吐出任何内容时**重试；只重试 provider 标 `retryable` 的 | **合规且是范本**：三条边界（未吐内容 / retryable / 次数上限）明写在 `Contract.kt:621-632`。与"无脑重试"完全相反——流中途断开不重试（可能已计费、重放会重复执行）。保留 | 保留 | 高 |
| C7 | `core/src/main/kotlin/dev/heracles/core/contract/Contract.kt:629` | `const val RETRY_MAX_ATTEMPTS = 2`<br>`/** 退避基数（毫秒）：600 → 1200。 */`<br>`const val RETRY_BASE_DELAY_MS = 600L` | 重试次数/退避基数的唯一来源 | 合规（数字集中、理由可查）。属"网络鲁棒性"而非"模型容错"，与强/弱模型无关 | 保留 | 高 |
| C8 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2093` + `core/.../Contract.kt:581` | `if (consecutiveToolFailures >= maxConsecutiveFailures) {`<br>`  val detail = "连续 $consecutiveToolFailures 次工具执行失败，已停止。"` | 连续工具执行失败 6 次 ⇒ 熔断（成功清零、NeedsApproval 不增不清） | 合理安全阀，且判据是 `ToolOutcome.isSuccess` 结构化字段（1858 注释专门记了 `SuccessWithImage` 的坑）。强模型同样需要。`3→6` 的放宽理由（云端模型会自己改）也是对的。保留 | 保留 | 高 |

---

## D. 文本轨 vs 原生 Function Calling

| # | 文件:行号 | 代码摘录（≤6 行） | 在容忍什么 / 做了什么 | 对强模型为何有害（或为何仍必要） | 判定 | 置信度 |
|---|---|---|---|---|---|---|
| D1 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2770-2822` | `val TOOL_PROTOCOL_CLOUD = """`<br>`## 输出格式（三种，不要输出任何其它内容）`<br>`① 任务需要多步时，**先给计划**: {"plan":[…]}`<br>`② 要**改文件**时，用标签 + CDATA …`<br>`<apply_patch path="index.html">`<br>`<![CDATA[` … `]]></apply_patch>` | 文本轨协议全文：教模型用 `{"tool":…}` / `{"final":…}` / `{"plan":…}` / `<write_file>` / `<apply_patch>` | **整份都是历史包袱**。它的核心机制（CDATA 绕转义）理由是本地 GBNF（见 B2 引的 `ToolZonePlan.kt:52-56`），而它现在仍被 `AgentLoop.kt:479-480` 选为**文本轨默认**（`nativeToolsEnabled` 默认 false，见 `:426`）。留着它等于：① 强模型被要求"只输出三种 JSON，不要解释"（正是把强模型当小模型训）；② 与原生轨同时存在时是两套真相（`AgentLoop.kt:2829-2835` 的 KDoc 自己说"模型一半概率写进正文"）。随 B2 一起删，只保留原生轨 | 必删 | 高 |
| D2 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2846-2872` | `val TOOL_PROTOCOL_NATIVE = """`<br>`你**通过原生 function calling** 拿到工具清单…`<br>`- 回答用户时：**直接用普通文字回答**，不需要任何 JSON 包装`<br>`（也兼容一次性 JSON 写法：{"plan":["第一步要做什么","第二步要做什么"]}）`<br>`任务完成时：…（想显式收尾也可以写 {"final":"<回答>"}）` | 原生轨协议；但**同时**兼容文本轨的计划/收尾写法，并保留大段"规则"（改代码优先局部替换、大文件分段…） | 方向正确（"别再逼模型守格式"），但**兼容分支是把文本轨再塞回来**：既然原生轨下正文 = 最终回答（1474-1476），就不该再教 `{"plan":…}` / `{"final":…}`——那正是 A3/B2 那类漂移的诱因；另外 `2852` "最多 4 个"、`2860` 收尾口径等规则应交给 `update_plan` 工具与 schema 表达 | 重写 | 高 |
| D3 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:1474-1476` | `nativeToolsEnabled && textParsed is AgentOutput.Unparseable && raw.isNotBlank() ->`<br>`  AgentOutput.FinalAnswer(raw.trim())` | 原生轨下"正文不是协议 JSON" ⇒ 当**最终回答** | **合规且是这次整改的核心收获**（KDoc 1468-1473：「旧实现把它判成 Unparseable ⇒ 连挂两轮直接熔断」）。保留，并应把这条原则推广到文本轨的退役上 | 保留 | 高 |
| D4 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2143-2153` | `"上次输出无法按协议解析：${parsed.detail}。\n" +`<br>`"只接受三种顶层形状（**顶层键**必须是下列之一）：\n" +`<br>`"· 计划：{\"plan\":[…]} … 调工具：{\"tool\":\"工具名\",\"args\":{…}}" +`<br>`"（**不要**把工具名当顶层键，如 {\"apply_patch\":{…}} 是错的）\n" +`<br>`"· 收尾：{\"final\":\"给用户的回答\"}" +`<br>`"只输出其中一种，不要任何解释。"` | 解析失败后追加的**纠正提示**：教三种顶层形状 | 这是"把输出格式当契约教给模型"的典型反向教练（`AGENTS.md`：抗幻觉不得依赖提示词；且"不要输出任何解释"对强模型是明确的负向指令）。原生轨下根本不需要信封 ⇒ 该提示的存在本身就在维持小模型假设。应在原生轨下改为"报告解析失败 + 说明收到了什么"，不教格式 | 重写 | 高 |
| D5 | `app/lib/widgets/stream_step.dart:46-51` | `static bool isStreamingToolCallStatic(String text) {`<br>`  final t = text.trimLeft();`<br>`  const full = '{"tool"';`<br>`  if (t.length >= full.length) return t.startsWith(full);`<br>`  return full.startsWith(t) && t.length >= 2;` | 流式期间靠**前缀 `{"tool"`** 判定"这轮正文是工具调用"，用于掩蔽不上屏 | 这是**把文本轨协议硬编码进 UI**：原生轨下正文是普通文字（1474-1476），流式时根本没有 `{"tool"` 前缀，这段永远不命中；而用户正文恰好以 `{"tool"` 开头时会被误掩蔽。原生轨成为唯一轨后应删 | 重写 | 中 |
| D6 | `app/lib/screens/chat_screen.dart:4020-4039` | `String stripProtocolShell(String raw) {`<br>`  final s = raw.trim();`<br>`  if (!s.startsWith('{') … !s.endsWith('}')) return raw;  // 见 4022 行`<br>`  try { final j = jsonDecode(s); … if (f is String) return f; if (j.containsKey('tool')) return '';`<br>`  } catch (_) { return raw; } }` | UI 展示层剥掉 `{"final":…}` / `{"tool":…}` 外壳；失败保持原文 | 实现本身诚实（未知形态/非法 JSON 都回原文，KDoc 4015「不猜」），但**它服务的对象在消失**：原生轨下步骤正文就是人话，剥壳函数变成死路径。保留到文本轨退役即可，退役后应删；当前不算有害 | 重写 | 中 |
| D7 | `app/lib/widgets/stream_step.dart:456-485` | `try { final j = jsonDecode(t);`<br>`  if (j is Map && j['tool'] is String) { … target = (args['path'] as String?) ?? '';`<br>`} } catch (_) { return (label: '已中断的工具调用', …) }` | 工具卡片摘要：解析 `{"tool":…}` 取工具名/路径/字数；失败显示"已中断" | 同 D6：文本轨专属（`_ToolSubEntry` 只在 `isStreamingToolCallStatic` 命中时出现，见 152-155）。诚实但将成死代码；`args` 取 `path/content` 也假定文本轨工具集合 | 重写 | 中 |
| D8 | `provider-http/src/main/kotlin/dev/heracles/provider/http/NativeToolSchema.kt:34-38` vs `agent/.../AgentLoop.kt:501-502` | `* ## 只装常驻工具（与披露机制天然冲突）`<br>`* 长尾工具是**逐轮披露**的（ADR-023）…`<br>`* **这是设计取舍，不是遗漏。**`<br>——<br>`internal fun nativeToolSpecs(): List<ToolSpec> =`<br>`  if (nativeToolsEnabled) activeTools().map { it.spec } else emptyList()` | 文档说"只装常驻、长尾继续走文本轨"；实现已改成"装 activeTools()（含已披露长尾）" | 典型的**文档与实现漂移**：按文档读会以为长尾在原生轨不可用，而实际实现（含 490-491 注释）已反转。对强模型无直接害处，但会误导下一次改动（尤其"要不要给长尾也发 tools"这种缓存取舍）。应改 `NativeToolSchema` 的 KDoc | 重写 | 高 |

---

## E. 空响应 / 纯思考 / 截断（finishReason=LENGTH）

| # | 文件:行号 | 代码摘录（≤6 行） | 在容忍什么 / 做了什么 | 对强模型为何有害（或为何仍必要） | 判定 | 置信度 |
|---|---|---|---|---|---|---|
| E1 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2515-2520` | `val status = when {`<br>`  rawText.isNotEmpty() -> AgentEvent.StepEnded.STATUS_OK`<br>`  terminalCalls.isNotEmpty() -> AgentEvent.StepEnded.STATUS_OK`<br>`  else -> AgentEvent.StepEnded.STATUS_EMPTY }` | "正文空但**有原生调用**"= OK；否则 EMPTY 三态 | **合规**：三态而非布尔，且专门修过"原生轨正文空被误报 EMPTY"的假警报（2513-2519 注释）。强模型正常形态，保留 | 保留 | 高 |
| E2 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:1397-1412` | `// · finish —— STOP / LENGTH / ERROR；**LENGTH = 被输出预算截断**`<br>`// · raw/reason —— 正文空 + 思考长 = 模型把预算烧在思考上`<br>`println("[heracles][turn] turn=$turnIndex finish=… raw=… reasoning=… calls=…")` | `FinishReason` 只用于**诊断日志**，不参与决策 | 好的一面：`LENGTH` 从此可见（F7c 修的既有债务）。缺的一面：**全仓没有任何"LENGTH 后补 prompt 再问/续写"的分支**——这本身是**合规**（不猜、不自动续写），但代价是"被截断的工具调用"会走到 `Unparseable`，按 C4 的阈值 2 直接熔断。建议在熔断文案里把 `finish=LENGTH` 明确指出来（当前 2184-2188 只说"最后一轮原始输出"） | 保留 | 高 |
| E3 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:784-794` + `core/.../Contract.kt:661` | `val scaled = when (reasoningLevel) {`<br>`  OFF, AUTO -> base; LOW -> base*2; HIGH -> base*3; MAX -> base*4 }`<br>`return scaled.coerceAtMost(Contract.Inference.MAX_OUTPUT_TOKENS_CAP)` | 输出预算随"思考档位"放大（4096×1..4，封顶 16384） | 这是**为"思考吃光 max_tokens"打的补丁**（KDoc 766-782 记录的实测）。对强模型不算有害（预算足是好事），但它把"模型配置问题"用**客户端乘法**掩盖了；真正的解法是让 provider 的模型能力（`maxOutputTokens`）作来源，而不是按档位拍系数。属"重写为按模型能力取值"，非必删 | 重写 | 中 |
| E4 | `agent/src/main/kotlin/dev/heracles/agent/ThinkingBudget.kt:53-68` + `agent/.../AgentLoop.kt:2443-2451` | `fun reasoningCharBudget(maxOutputTokens: Int): Int {`<br>`  val ratioChars = (maxOutputTokens * MAX_REASONING_BUDGET_RATIO).toInt()`<br>`  val floorChars = MIN_REASONING_BUDGET_TOKENS`<br>`  return maxOf(ratioChars, floorChars) }`<br>`if (ThinkingBudget.shouldForwardReasoning(reasoning.length, maxOutputTokens)) …` | 思考超过"字符预算"后**不再转发给 UI**（`budgetExhausted` 只置位、什么都不做） | KDoc 33-38 已诚实写明"不能减少已消耗 token，只保证 UI 不被拖住"。但对强模型是**负向**：它把"模型在长思考"这件事从用户眼前抹掉（真实是服务端仍在生成），并且 `budgetExhausted` 变量**赋值后从未被读**（2370/2447-2448 三处只有写）⇒ 死代码。思考展示应改为"如实显示长度并允许折叠"，而不是按字符截流 | 重写 | 高 |
| E5 | `agent/src/main/kotlin/dev/heracles/agent/AgentLoop.kt:2184-2188` | `val lastRaw = raw.take(300).ifBlank { "（空）" }`<br>`val detail = "模型连续 $consecutiveUnparseable 轮没有按协议输出，已停止。\n\n" +`<br>`  "最后一次原始输出：\n```\n$lastRaw\n```\n\n" +`<br>`  "请再发一次；如果反复出现，换一个模型，或把推理等级调低…"` | 熔断时**附上最后一次原始输出**（前 300 字）+ 建议 | 合规：把"它到底吐了什么"变成可复核事实（这是 2026-10-19 修的正向改动），保留了。唯一小瑕疵是 `take(300)` 可能截在 JSON 中间，但作为诊断可接受 | 保留 | 高 |
| E6 | 全仓检索结论（无具体行） | 在 `agent/`、`provider-http/`、`app/` 全量 grep `finishReason`/`LENGTH`/`续写`/`补全`：**没有任何"截断后自动补 prompt 再问"的分支** | 不存在"无脑续写"式容错 | 这是**值得记录的"没有"**：没有自动续写 = 不猜、不伪造完整输出，符合铁律。不要为了"体验"补上它；若要处理截断，正确做法是**如实回报 LENGTH + 建议分段写**（协议 2815-2816 已有"大文件分几次写"） | 保留 | 高 |

---

## Top 5 优先级

1. **文本轨整套退役**（`agent/.../AgentLoop.kt:2770-2822` 的 `TOOL_PROTOCOL_CLOUD` + `agent/.../AgentOutputParser.kt:194-220` 与 `:231-237` 的 CDATA 标签解析）。理由链完整：CDATA 的**唯一**理由是本地 GBNF 禁转义（`agent/.../ToolZonePlan.kt:52-56` 自己写着），本地后端已删、原生 `tools` 已接线（`AgentBridge.kt:482`）⇒ 双轨只剩成本（模型把调用写进正文 ⇒ 原生优先忽略 ⇒ 静默失败）。这是类别 3 最大的一块，**必删**。
2. **连续解析失败熔断阈值 2**（`agent/.../AgentLoop.kt:2733` + `2159-2206`）。它在惩罚强模型最常见的"可自愈形状漂移"，而纠正提示（`2143-2153`）已经改变了上下文，"temperature=0 必然复现"的辩护不再成立。**重写**：区分"纯空响应(2)"与"形状漂移(纠正后 3-4 轮)"。
3. **解析失败纠正提示教三种顶层形状**（`agent/.../AgentLoop.kt:2143-2153`）。这是把输出格式当契约教模型（AGENTS.md：抗幻觉不得依赖提示词），且"不要输出任何解释"是明确的反向教练。**重写**：只报告事实，不教信封。
4. **参数平铺兜底 `flatArgs`**（`agent/.../AgentOutputParser.kt:69-74` + `254-260`）。原生轨不会产生"参数在顶层"的形态；该兜底会把畸形 JSON 的字段静默当参数，把"模型写错"变成"未知参数"的二次失败，且 `parseArgs` 的 `toString()` 兜底（`244-251`）进一步把类型错抹平。**重写**。
5. **`AnthropicProvider.inputOf` 把畸形参数静默换成 `{}`**（`provider-http/.../AnthropicProvider.kt:434-438`）。这是全类别里**唯一会静默污染 wire** 的兜底：历史回放时 `tool_use.input` 与模型当初说的不一样，且无日志。**必删**（改为明确失败或按配对校验丢弃）。

---

## 附：已排除的误报（看着像 Hack、实际是协议解析或合规）

| 位置 | 为什么不是"修 JSON"的 Hack |
|---|---|
| `provider-http/.../SseDecoder.kt:85-119`（`handleLine` 的 `substring` / 裁 `\r` / `finish()` 补最后一行） | SSE **传输格式**解析：事件边界是空行、UTF-8 可能被分包切断、`[DONE]` 不是 JSON 需特判。与"模型输出形状"无关，不该动 |
| `provider-http/.../HttpJson.kt:168-174`（过滤 `SseDecoder.DONE_MARKER`） | 同上，协议层常量，不是容错 |
| `provider-http/.../NativeCallAssembler.kt:54-64 / 91-98 / 132-144`（分片字符串拼接、`name` 只取首个非空、Responses 以 `output_item.done` 为准） | 这是**流式 wire 的正确读法**（任一单片都不是合法 JSON，必须攒齐再 parse）。注释 20-35 把三条铁律写死了，是"不猜"的正面样板 |
| `provider-http/.../NativeCallAssembler.kt:214-218`（`argumentsOf` 兼容 `arguments` 是对象） | 已知的真实聚合服务形状差异（文档化），且只做"序列化成字符串"，不做语义归一 |
| `provider-http/.../DataUrl.kt:97-163`（mime 白名单、`image/jpg` 纠正即拒绝） | **拒猜**的范本："纠正就是猜"（22-32、52）。与"修 JSON"相反 |
| `core/.../tool/ToolValidator.kt:41-95`（缺参数/未知参数/长度/控制字符） | 这是**拒执行**的门禁，不是容错；且 58-69 的 `allowEmpty` 是修"校验器自己成为故障源"的正向改动 |
| `app/lib/screens/chat_screen.dart:430-442`（`_restoreView` 的 `jsonDecode` + catch 用默认值） | 解析对象是**本机 SharedPreferences 里的 UI 偏好**，不是模型输出；"脏设置不该让侧边栏打不开"合理 |
| `app/lib/services/agent_bridge.dart:874-880 / 937-939 / 996-999`（`fetchModels` 的 `FormatException`→人话、能力拉取失败返回 null） | 对象是 **provider 的 `/models` 响应**，失败是"显示精度下降"而非执行决策；`fetchModels`（用户手动）仍如实抛人话 |
| `app/lib/screens/settings_screen.dart:1709-1721`（`jsonDecode` 回显，catch 空） | "连接测试"的**展示性**解析，失败仍显示"HTTP 200 连接成功"；不影响任何请求/执行 |
| `app/lib/models/model_capabilities.dart:85-133`（同时认 `context_length`/`contextWindow`/… 多种字段名） | 各家服务端**字段名差异**，不是模型输出形状；且"不认识就 null、不猜值"（83-84 明写） |
| `app/.../SessionStore.kt:270-290 / 591-718`（写 JSONL 的 `JSONObject` 构造、三态 `state`） | 这是**写**方向 + 三态落盘（修 H-1 的假绿卡），不是解析容错 |
| `agent/.../AgentLoop.kt:2228-2261`（`appendNotExecuted` 合成"未执行"结果） | 原生轨**配对回填**要求（否则下一轮 400）；文案取自 `NativeSkip` 四种可枚举，不编措辞 |
| `provider-http/.../OpenAiResponsesProvider.kt:202-204 / AnthropicProvider.kt:244-254`（流提前结束也补发终止块） | 补的是"终止块"而不是"内容"：不补会让原生调用**静默丢失**。是"防静默失败"，不是"猜输出" |
| `agent/.../tools/FsSearchTools.kt:578-600`（`max_results` 超上限收敛、`parseBool` 只认明确写法） | 收敛有 `note` 如实回报；`parseBool` 其余写法**明确失败**（"不猜模型的意思"）。属受控且可观测 |
| `agent/.../AgentLoop.kt:1220-1273`（上下文压缩失败 ⇒ 继续用完整上下文 + 事件告知） | 失败不猜、不丢上下文，且 `compacted` 只压一次（防反复触发）。合规 | 
| `agent/.../AgentLoop.kt:2515-2520`（STATUS_EMPTY） | 已在 E1 计为"保留"；此处再强调：它**不是**"空响应容错"，而是把空响应**如实标注** |
| `agent/.../tools/GitIgnore.kt:29` / `FsSearchTools.kt:486,557`（`.gitignore` 读不到 ⇒ `GitIgnore.EMPTY`） | 容忍的是**本机规则文件**缺失，不是模型输出；且明写"忽略规则是优化，不是主路径"（29 行）。返回 EMPTY = 扫更多文件，不产生错误结论 |
