# 真 Key 真机验证记录 —— 2026-10-21

> 设备：`e35e48c6`（USB）/ `192.168.137.33:40653`（无线，端口会轮换）
> 应用：`com.theohowie.heracles`（Android，Flutter + Kotlin 主框架）
> 中转站：tokenrhythm（OpenAI 兼容），模型 `deepseek-v4.1-flash-1017`
> 管线：**第 1–2 轮经 intent extra 打开；第 3 轮起是默认**（不传任何开关）

---

## 0. 四轮验证总览

| 轮次 | 时间 | 目的 | 结果 |
|---|---|---|---|
| **第 1 轮** | 17:07 | 首次真 Key 打通 wire | ✅ 22 轮工具调用；**暴露 3 个真 bug** |
| 修复 | — | Schema 解析改 Gson、参数去引号、提示词加停止条件 | 887 单测全绿 |
| **第 2 轮** | 19:11 | 验证修复（带 flag 启动） | ✅ 全部命中 |
| **第 3 轮** | 20:11 | 验证**默认值已切新管线**（不传 flag）+ 磁盘落盘 | ✅ 端到端闭环 |
| **第 4 轮** | 20:49–20:55 | **UI 闭环三件套**：计划落盘/恢复、ask_user 弹窗、并行调用 | ✅ **全部取证** |

**一句话结论**：新管线在真机上**跑通了完整闭环** —— 原生工具调用、并行、计划落盘跨重启恢复、
`ask_user` 弹窗交互、文件真实写盘。旧管线同期在同一模型上**熔断**。

---

## 1. 第 4 轮：UI 闭环三件套全部取证（20:49–20:55）

### ① 计划落盘 → 跨 App 重启 → 切会话恢复（**完整闭环**）

**发任务**（"make a plan with three steps then create plancheck.txt"）：

```
[heracles][cloud] pipeline START ... history=0
turn=1 finish=TOOL_CALLS calls=2 toolNames=update_plan,list_files   ← update_plan + 读并发
turn=2 finish=TOOL_CALLS calls=1 toolNames=update_plan
turn=3 finish=TOOL_CALLS calls=1 toolNames=write_file
turn=4 finish=TOOL_CALLS calls=1 toolNames=update_plan
turn=5 finish=TOOL_CALLS calls=1 toolNames=read_file
turn=6 finish=TOOL_CALLS calls=1 toolNames=update_plan
turn=7 finish=STOP      calls=0                                     ← 3 轮探索后直接收工
```

**磁盘证据**：

```
$ ls -lt .../.heracles/plans/ | head -2
-rw-rw---- 168  2026-10-21 20:49  s1792586954756.json     ← 计划真的落盘了

$ cat .../.heracles/plans/s1792586954756.json
[{"text":"制定三步计划","status":"done"},
 {"text":"在工作区根目录创建 plancheck.txt","status":"done"},
 {"text":"读回文件校验内容","status":"done"}]

$ ls -lt .../ | head -2
-rw-rw---- 109  2026-10-21 20:49  plancheck.txt           ← 文件也真的建了
```

**恢复证据**（`am force-stop` → 重开 → 侧边栏切回该会话 → 发消息）：

```
[heracles][cloud] plan restored: 3 steps from .heracles/plans/s1792586954756.json
[heracles][cloud] pipeline START ... history=2
```

⇒ **计划落盘 + 跨重启恢复 + 历史注入，三者一次全证。**

### ② `ask_user` 弹窗：**真的渲染了，且回答后 run 继续**

这是之前"抓不到"的那一项。本轮用 `uiautomator dump` 抓到了弹窗节点
（`content-desc` 就是题目与选项）：

```
clickable 节点：
  [154,694][926,972]   1 让规格真正生效 / 购物车条目升级为 {id,qty,spec}…
  [154,993][926,1271]  2 加结算 / 订单闭环 / 新增 freshmall_orders…
  [154,1292][926,1576] 3 清掉假轮播 + 修 money 口径 + 删遗留测试文件
  [154,1597][926,1820] 4 先只给现状报告，暂不改代码
  [527,1904][695,2030] 跳过
  [716,1904][912,2030] 提交
```

对应日志：`turn=7 toolNames=ask_user`（`raw=689`）。

**点击「跳过」后 run 继续**：

```
turn=8..15  finish=TOOL_CALLS  toolNames 里出现 edit,edit / read_file,read_file
```

⇒ `ask_user` **事件 → 弹窗渲染 → 用户作答 → 挂起释放 → 模型继续**，整条链路通。

### ③ 并行调用：设备上反复出现，且**写类不再并发**

```
turn=1  calls=2  toolNames=update_plan,list_files
turn=2  calls=2  toolNames=read_file,read_file
turn=3  calls=2  toolNames=grep_files,grep_files
turn=4  calls=2  toolNames=grep_files,read_file
turn=10 calls=2  toolNames=edit,edit          ← 写类：请求 2 个，**串行执行**（bug D 修复）
turn=11 calls=2  toolNames=edit,read_file     ← 混合：edit 串行、read 可并发
```

> ⚠️ **并发"真的重叠"由单测墙钟证明**（`CloudParallelConcurrencyTest` 5 条）；
> 设备日志只能证明"一轮收到 N 个调用"。两者互补，别把后者当前者。

---

## 2. 第 3 轮：默认即新管线 + 文件真的写进磁盘

**关键：这次启动命令里没有任何 flag。**

```powershell
adb shell am force-stop com.theohowie.heracles
adb shell am start -n com.theohowie.heracles/.MainActivity   # ← 无 --ez
```

### 日志（原始）

```
[heracles][cloud] pipeline START provider=cloud:deepseek-v4.1-flash-1017 kind=CLOUD
    window=128000 budget=102400 resident=12 disclosable=14
    maxTurns=40 maxToolCalls=200 approval=on askGate=on history=0
[heracles][cloud-turn] turn=1 finish=TOOL_CALLS raw=0  calls=1 tools=12 maxOut=16384 msgs=2 toolNames=write_file
[heracles][cloud-turn] turn=2 finish=TOOL_CALLS raw=0  calls=1 tools=12 maxOut=16384 msgs=4 toolNames=read_file
[heracles][cloud-turn] turn=3 finish=STOP      raw=70 calls=0 tools=12 maxOut=16384 msgs=6 toolNames=-
```

### 磁盘证据（整条链路的闭环）

```
$ adb shell ls -lt /storage/emulated/0/Audiobooks/newproject/ | head -3
-rw-rw---- 1 u0_a239 media_rw 6 2026-10-21 20:11 demo.txt     ← 新建，6 字节

$ adb shell cat /storage/emulated/0/Audiobooks/newproject/demo.txt
hello                                                          ← 内容正确
```

### 这一轮同时证明了什么

| 断言 | 证据 |
|---|---|
| **默认走新管线**（不需要 flag） | 没传 extra，日志仍是 `[heracles][cloud] pipeline START` |
| **`write_file` 真的写进磁盘**（bug C 已修） | `demo.txt` 6 字节、20:11、内容 `hello` |
| **`read_file` 真的能读回**（bug C 已修） | turn 2 `read_file` 后 turn 3 直接收工，无重试 |
| **提示词停止条件生效**（bug B 已修） | **3 轮**完成（修复前同类任务 22 轮） |
| **纯文本即最终回答** | `finish=STOP calls=0 raw=70` |
| **零 400 / 零解析失败** | 全程无 error、无 `Unparseable` |

---

## 3. 第 1 轮：首次打通 wire（同时挖出 3 个真 bug）

`AGENTS.md` 一直记着「真 Key 验证一次都没跑过」。2026-10-21 **17:07** 首次跑通。

### 证据（logcat 原始输出）

```
[heracles][cloud] pipeline flag = true (from intent extra)
[heracles][cloud] pipeline START provider=cloud:deepseek-v4.1-flash-1017 kind=CLOUD
    window=128000 budget=102400 resident=12 disclosable=14
    maxTurns=40 maxToolCalls=200 approval=on askGate=on history=0

turn=1  finish=TOOL_CALLS raw=0 calls=1 tools=12 msgs=2  toolNames=list_files
turn=2  finish=TOOL_CALLS raw=0 calls=1 tools=12 msgs=4  toolNames=find_files
turn=3  finish=TOOL_CALLS raw=0 calls=1 tools=12 msgs=6  toolNames=find_files
turn=4  finish=TOOL_CALLS raw=0 calls=1 tools=12 msgs=8  toolNames=grep_files
turn=6  finish=TOOL_CALLS raw=0 calls=1 tools=12 msgs=12 toolNames=run_shell_command
turn=7  finish=TOOL_CALLS raw=0 calls=1 tools=12 msgs=14 toolNames=read_file
turn=13 finish=TOOL_CALLS raw=0 calls=1 tools=12 msgs=26 toolNames=grep_files
turn=18 finish=TOOL_CALLS raw=0 calls=3 tools=12 msgs=36 toolNames=read_file,grep_files,list_files
turn=22 finish=TOOL_CALLS raw=368 calls=1 tools=12 msgs=47 toolNames=ask_user
```

### 这组日志证明了什么

| 待验证的 wire 假设 | 结论 | 证据 |
|---|---|---|
| 中转站**接受**标准 JSON Schema 的 `tools` | ✅ | `tools=12` 连续 22 轮，**零 400** |
| `integer`/`boolean`/`array` 类型能被服务端处理 | ✅ | 参数校验通过（修复后），模型正常调用 |
| **并行工具调用**真的发生 | ✅ | `calls=3`（turn 18）、`calls=2`（多处）|
| `max_tokens = 16384` 不被服务端拒 | ✅ | `maxOut=16384` 全程无错 |
| 流式 `tool_calls` 分片能被正确拼装 | ✅ | 22 轮全部 `finish=TOOL_CALLS`，无"参数不是合法 JSON" |
| 上下文预算按 128K 生效 | ✅ | `window=128000 budget=102400` |
| **没有"输出无法解析"熔断** | ✅ | 全程无 `Unparseable` |

### 对照：旧管线同期表现

同一台设备、同一模型、旧管线（`AgentLoop` + 文本轨）在同期出现：

> 「模型连续 2 轮没有按协议输出，已停止。最后一次原始输出：（空）」

⇒ **同样的模型、同样的任务，旧管线熔断，新管线跑完 22 轮。** 这是"弃用旧管线"最直接的依据。

---

## 4. 验证中暴露并已修复的**真实 bug**（当时 887 条单测全绿）

### bug A：`ToolSchema.fromRendered` 手写 JSON 扫描器全错（**所有工具失效**）

**症状**：`read_file` 连续 20 轮被拒「参数不符合 Schema」，模型重试到放弃。

**根因**（`SchemaRealWorldTest` 单测复现）：
```
Invalid(detail=未知参数：path（该工具接受：limit, :）)
```
它用 `json.indexOf(",\"")` 找下一个属性，而 `"description"` 的值里**也含 `,"`**
⇒ 解析出 `[limit, :]` 这种垃圾参数名 ⇒ 所有真实参数被判"未知参数" ⇒ **每个工具都废**。

**修法**：改用 Gson（`:agent` 本来就有；这份 JSON 是我们自己 `renderObjectSchema` 产出的）。
**手写 JSON 扫描器是 bug 工厂。**

**门禁**：`SchemaRealWorldTest` 5 条 —— 逐工具核对参数名/类型/required 与声明**逐项一致**。

### bug B：提示词缺"停止条件" ⇒ 简单任务跑 22 轮

**症状**：任务只是"列出工作区文件"，模型跑了 **22 轮**，在
`list_files` → `find_files` → `grep_files` 之间反复试探。

**根因**：系统提示词只说了"看不清就先读"，**没说"看够了就答"**。

**修法**：加一节「什么时候该停」—— 不是"教练"（不限制手段），
而是给**事实性停止条件**：简单任务直接答、拿到信息就停、发现原地打转就停下说明。

**复验**：修复后 "hi" → `calls=0`；"create demo.txt" → **3 轮**完成。

### bug C：`CloudToolValidator` 把**带引号的字符串**交给工具（read/write 全废）

**症状**：`read_file` / `write_file` 全部失败，但日志只显示"调用了它"，看不出失败。

**根因**：`parseObject` 返回原始 JSON 切片：
```
{"path":"a.txt"}  ⇒  args["path"] == "\"a.txt\""   // 带引号！
```
⇒ 工具拿 `"a.txt"` 当路径 ⇒ 文件永远找不到。

**为什么藏了很久**（三重隐身）：
1. **类型校验是对的** —— `checkType` 需要看到引号才能判 `string` ⇒ 校验全绿
2. **日志看不出** —— 诊断日志只记工具名、不记结果
3. **单测看不出** —— 只测"校验是否通过"，没测"值是否原样交给工具"

**修法**：类型校验仍看原始形态，**校验通过后**再去引号 + 解转义（`\"`→`"`、`\n`→换行、`\u4e2d`→中）。
第一版修法在 `parseObject` 里就去引号，导致所有字符串被判 `unknown`，单测立刻抓到。

**门禁**：`ToolArgPassthroughTest` 7 条。

### bug D：`CloudToolExecutor` 忽略 `parallelSafe`，**全部并发**（第 4 轮前自查发现）

**症状**：`executeTurn` 把每条调用都 `async` 并行，注释却写"由 `parallelSafe` 决定"——**代码没看那个声明**。

**后果**：两个 `write_file` 并发写同一文件（竞态）；两个审批调用抢**单槽**队列（第二个 reply 喂错）；
`delete_path` 与 `read_file` 交错。

**修法**：只有 `parallelSafe` 且不在 `neverConcurrent`（= `mutatingTools`）的才并发。

**门禁**：`CloudParallelConcurrencyTest` 5 条，用**墙钟**判定。

---

## 5. 真机操作路径（复现用）

```powershell
# 1. 装 APK
adb -s e35e48c6 install -r app\build\app\outputs\flutter-apk\app-debug.apk

# 2. 启动（默认就是新管线；要退回旧管线加 --ez heracles_cloud_pipeline false）
adb -s e35e48c6 shell "am force-stop com.theohowie.heracles"
adb -s e35e48c6 shell "am start -n com.theohowie.heracles/.MainActivity"

# 3. 看新管线日志
adb -s e35e48c6 logcat -d -v brief | grep -E 'cloud-turn|cloud..pipeline|plan restored'
```

### 本机环境坑（复现时会撞上）

| 坑 | 现象 | 应对 |
|---|---|---|
| **ADB 服务反复崩** | `cannot connect to daemon` / `BindException` | `adb kill-server` → 等 6s → `start-server`，重试 ≤ 8 次 |
| **无线调试端口轮换** | `Connection refused (10061)` | 用 USB 序列号 `e35e48c6` 更稳；或向用户要新端口 |
| **`input text` 对 Flutter 无效（有时）** | 文本进不了输入框 | 先 `input tap` 点中输入框（键盘未弹时 **y≈2130**），再 `input text`，再 `keyevent 62`（空格提交候选）|
| **回车不发送，只换行** | 输入框里出现 `hello\n` | Flutter 的 `TextInputAction.send` 不接管裸 `keyevent 66` ⇒ **必须点发送钮**（键盘弹出态约 **(954,1392)**）|
| **中文拼音输入法破坏 ASCII** | 文本变乱码 | 只用英文；或按 `AGENTS.md` 坑 17 临时 `ime disable` |
| **通知栏 / 锁屏抢焦点** | `mCurrentFocus=NotificationShade` / `mDreamingLockscreen=true` | `cmd statusbar collapse`；锁屏需用户解锁 |
| **Gradle / Kotlin daemon 不稳** | `BindException`、`Kotlin daemon has failed` | `Get-Process java \| Stop-Process -Force` 后重试 2–4 次 |

---

## 6. 本次验证**没有**覆盖到的（如实声明）

1. **只验了 OpenAI 兼容中转站** —— **Anthropic / Responses 两轨仍未真 Key 验证**。
   这是目前**最大的不确定面**：那两轨的 wire 形状完全不同
   （Anthropic 是 `input_schema` + 内容块；Responses 是扁平 `tools` + `output_item` 事件）。
2. **`max_tokens=16384` 只证明"不被拒"，没证明"模型会用满"** ——
   本次任务都不需要长输出。
3. **并行调用的"真并发"由单测墙钟证明，不是设备耗时证明** ——
   设备日志只能证明"一轮收到 N 个调用"。两者互补，口径要说清。
4. **`update_plan` 的面板渲染没截图级证据** —— 计划**事件**与**落盘文件**都已取证，
   但"顶部清单打勾的样子"没有截图（当前会话无图像输入能力）。
5. **`ask_user` 弹窗的多选 / 提交路径未验** —— 只点了「跳过」，「提交」与多选组合未测。
