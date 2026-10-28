# Heracles 设计语言

> 本文档是 Heracles 前端的视觉与交互唯一口径，由用户逐项拍板、前端逐项
> 落地（2026-10 定稿，随版本演进修订）。改任何界面先对这里：新样式要
> 先做 HTML 预览经用户拍板，再进代码；与本文冲突的旧写法一律以本文为准。

## 1. 总则

- **黑白简约**：默认主题只用黑、白、灰。靠**留白与明度分层**，不靠描边
  堆叠、不靠彩色装饰。语义色（绿/橙/红）只用于状态本身，不做装饰。
- **零 emoji**：界面里不出现 emoji。图标一律**填充式矢量图标**，不用
  线条（描边）图标；图标唯一来源是 `lib/theme/cupertino_kit.dart` 的
  `AppIcons` 对照表与 `lib/widgets/brand_icons.dart` 的品牌图标
  （GitHub 猫、git-branch），不要在界面代码里直接写 `Icons.*`。
- **主题只换颜色不换布局**：外观四档（黑白/柔雾/极光/活力）只改变
  色板与背景（含光晕），任何一档下布局、字阶、圆角、组件规格完全一致。
- **动效要有弹簧感**：切换、展开、抽屉一律弹簧/回弹曲线，不用线性
  硬切。标准弹簧参数见 §4.4。
- **深浅默认跟随系统**（2026-10-28 定）：未手动选过时
  `AppAppearance.system`；用户在外观页选过的以其选择为准。

## 2. 基础令牌

代码源：`lib/theme/app_theme.dart`（`Hue` / `HTxt` / `HRadius` / `HSpace`）。
界面取色一律经 `Hue.of(context)`，禁止硬编码颜色（语义色常量除外）。

### 2.1 色板（Hue，黑白档）

| 令牌 | 浅色 | 深色 | 用途 |
| --- | --- | --- | --- |
| bg | #F7F7F7 | #0A0A0B | 页面底 |
| surface | #FFFFFF | #141415 | 卡面 |
| surfaceAlt | #F0F0F0 | #1C1C1E | 次级面（托盘、胶囊底） |
| border | #E3E3E6 | #2A2A2C | 描边（克制使用） |
| text | #161616 | #F2F2F2 | 主文字 / 反色实心块 |
| textDim | #5C5C5C | #A3A3A3 | 次文字 |
| textFaint | #A3A3A3 | #6E6E73 | 弱文字、占位 |

深色下坐在 surfaceAlt 卡面上的小控件（胶囊、圆钮）要**再提亮一档**
用 `#2C2C2E`，否则与卡面同色消失。

### 2.2 字阶（HTxt，全局统一，不另设字号）

| 令牌 | 规格 | 用途 |
| --- | --- | --- |
| pageTitle | 22 / w700 | 页面大标题 |
| sectionTitle | 13 / w600 | 分组小标题 |
| body | 15 | 正文（基准字号，用户可调 ±） |
| secondary | 13 | 副行、状态值 |
| caption | 12 | 脚注、说明 |

### 2.3 圆角与间距

- 圆角 `HRadius`：sm 6、md 14、lg 20、**xl 24（大卡片与抽屉顶）**、
  pill 999（胶囊）。
- 间距 `HSpace`：xs 4、sm 8、md 12、lg 16、xl 24、xxl 32。

## 3. 主题与背景

- 主题枚举 `AppThemeStyle`：`bw` 黑白（默认）、`mist` 柔雾、
  `aurora` 极光、`vitality` 活力。切换只换 `Hue` 色板与背景。
- **光晕背景**只属于极光/活力两档、且只出现在对话页：三处径向光斑
  从顶部透出（`ThemedBackground`），此时对话页 Scaffold 与顶栏透明；
  黑白/柔雾为纯色底，无光晕。
- 毛玻璃（背景模糊）是**悬浮层专属**质感：只用于输入卡、抽屉、
  轻提示等悬浮元素，不用于普通卡面。

## 4. 核心组件

以下四件是用户点名的「唯一形态」：开关只有弹性开关、离散选项只有
分段控件、按压反馈只有 Pressable、弹层只有上拉抽屉。系统自带的
`Switch`、`CupertinoSegmentedControl`、`PopupMenuButton`、
`CupertinoActionSheet`、居中 `Dialog`、`SnackBar` 在 `lib/` 里
应为**零出现**。

### 4.1 弹性开关 ElasticSwitch

`lib/theme/elastic_switch.dart`。轨道 50×30，滑块高 26；切换时滑块
先**拉伸变宽再回弹**落位（弹性由此而来），轨道色随开/关在
text 与 border 间过渡。关态不是灰掉禁用，只是状态色不同。

```dart
ElasticSwitch(
  value: config.reasonEnabled,
  onChanged: (v) => jev.updateConfig(config.copyWith(reasonEnabled: v)),
)
```

使用纪律：一切二值开关（设置项、权限项）都用它，包括权限页的
运行时权限开关；拨开需要系统授权的，拨动即走系统授权流程，
不要先弹自家确认框。

### 4.2 分段式按钮 StretchSegmented

`lib/theme/stretch_segmented.dart`。离散多档选项的唯一形态：
黑色滑块以**弹簧滑动 + 中途凸起（bulge）**移到目标档，轨道内层用
`ClipRRect(10)` **硬裁剪**——滑块拖到最左/最右档也绝不能溢出轨道
圆角（用户对图定案）。标签色随选中反色。

```dart
StretchSegmented(
  labels: const ['云端', '本地 0.8B', '本地 2B'],
  selected: config.source.index,
  onSelected: (i) => updateSource(JevSource.values[i]),
  trackColor: h.surface,
  blockColor: h.text,
  selectedLabelColor: h.bg,
  labelColor: h.textDim,
)
```

使用纪律：凡 2–5 档互斥选择（思考等级、权限档位、来源等）一律用它；
档位多到放不下或选项是长文本时，改用 §4.4 的单选抽屉，不要硬塞。

### 4.3 回弹式按钮 Pressable

`lib/theme/pressable.dart`。全 App 的按压反馈唯一来源：按下时
整体**缩放至 0.96 并压上一层内阴影**，松手弹簧回弹到 1.0。
它只是效果包装，**自身没有 onTap**——点击手势由子级自己的
GestureDetector/InkWell 承担（历史上在真机吃过 GestureDetector
点不动的教训，卡片类点按优先 Material + InkWell 结构）。

```dart
Pressable(
  borderRadius: BorderRadius.circular(999), // 与子级外形一致，阴影罩层才贴合
  child: Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: /* 38×38 圆钮内容 */,
    ),
  ),
)
```

注意：带 `borderRadius` 时它会把子级放进 Stack 并放松紧约束，
在 Flexible/Row 里用它包裹的胶囊要自己算好宽度（Spacer + 定宽），
不要指望它收缩。

### 4.4 上拉抽屉 BwSheetShell

`lib/widgets/bw_approval.dart`。一切弹层的唯一外壳：

- **三档吸附（detents）**：内容自然高、66%、80% 屏高；拖动在档位间
  以弹簧吸附，弹簧参数 `SpringDescription(mass: 1, stiffness: 320,
  damping: 27)`。
- **壳与表面一体**：抽屉表面填满到屏幕底（下方不留空），拖动时
  **表面与内容要动一起动、不动都不动**（用户铁律，拆成两层跟随
  曾被真机抓出「上拉就字动」）。
- **关闭**：快速下滑甩动，或拖到低于自然高 −110 即关。
- **调用方规矩**：`showModalBottomSheet` 必须
  `backgroundColor: Colors.transparent` + `shape` 零圆角，
  圆角（顶 24）由壳自己负责。

```dart
await showModalBottomSheet<void>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(),
  builder: (sheetCtx) => BwSheetShell(
    onDismissRequest: () => Navigator.of(sheetCtx).pop(),
    child: SafeArea(child: /* 抽屉内容 */),
  ),
);
```

抽屉的三种标准内容形态（都在 `bw_approval.dart`）：

```dart
// 单选：如切模型、切引擎来源、选 API 协议（点选即生效并收起）
final picked = await showBwRadioSheet<JevSource>(
  context,
  title: '引擎来源',
  subtitle: '点选即生效',
  options: JevSource.values,
  current: config.source,
  labelOf: (s) => s.label,
);

// 确认：破坏性动作用 destructive（红色确认键）
final ok = await showBwConfirmSheet(
  context,
  title: '清空决策历史？',
  message: '所有问答记录都会删掉，不可恢复。',
  confirmLabel: '清空',
  destructive: true,
);
```

### 4.5 轻提示 showIosToast（毛玻璃悬浮胶囊）

`lib/theme/cupertino_kit.dart`。2026-10-28 用户在四案预览中选定
D 案（毛玻璃），旧 iOS 风顶部深灰胶囊退役。

- 形态：底部居中悬浮胶囊（全圆角），半透填充 + `BackdropFilter`
  模糊 14 + 细描边。深色：`rgba(28,28,30,.72)` 底、白边 14%、白字；
  浅色：`rgba(250,250,252,.78)` 底、黑边 7%、黑字。带投影
  （黑 30%、blur 30、下移 12）。
- 动效：淡入 + 上浮（240ms easeOut），停留 2.2 秒淡出（200ms），
  点按立即关。
- 位置：无键盘时距底 = 安全区 + 170（让开聊天页输入单元）；
  键盘弹起时贴键盘上方 16。
- 可选前置图标（如麦克风未接入提示带麦克风图标）。

```dart
showIosToast(context, '已保存');
showIosToast(context, '语音识别还没接入，这个按钮先占位', icon: AppIcons.mic);
```

纪律：一切短反馈（保存成功、复制成功、未接入提示）都走它；
需要用户做决定的事**不许**用轻提示，必须用 §4.4 确认抽屉。

## 5. 输入单元（对话页 / 决策页共用）

底部输入区是**两层等宽卡片错位叠放**的托盘形态：后层托盘整卡
下错，仅在下方露出 44 高的信息条带；托盘填充浅色时在卡面上叠
12% 黑（深色用 surface）。前层为输入白卡（圆角 24）：附件区（卡内顶）+
文本区 + 底行控件。生成中白卡带彩虹流光描边。

底行控件规格（工作模式与决策模式**必须同规格**，2026-10-28
用户对图定案，两边不一致就是 bug）：

| 控件 | 规格 |
| --- | --- |
| ＋ 圆钮 | 38×38，填充 surfaceAlt（深色 #2C2C2E），图标 19、textDim |
| 模型/来源胶囊 | **高 38**、横边距 12、字号 14、无边框，填充同圆钮；点按开切换抽屉（§4.4 单选） |
| 权限盾 | 38×38 透明底，图标 22；完全访问档用警示橙 |
| 麦克风占位 | 38×38，同圆钮规格；在**盾与发送之间**（2026-10-28 预留，后续接语音识别；未接入时点按给轻提示） |
| 发送键 | 38 圆，`h.text` 实底 + 同色描边，图标 `AppIcons.send` 19 号；前景反色（深色 #0A0A0B / 浅色白）；忙态按语义换停止/等待图标 |

信息条（托盘下沿带，高 44）：工作区 · 连接 Github · 选择分支
（置灰项如实置灰，未接入的功能不假装）。

## 6. 卡片与页面

- **设置类页面**：小组 = 小字分组标签（sectionTitle）+ 圆角 xl
  卡片；行 = 标题（body）在上、当前值作副行（secondary/textFaint）、
  右侧箭头。进编辑走独立编辑页（如提供商编辑页：字段在上、
  右上「保存」），不在列表里摊开表单。
- **列表卡**（如提供商、决策结果）：surface 底 + border 描边 +
  圆角 lg/xl；状态用 7px 状态点（可用绿 / 不可用 textFaint），
  状态文案如实（未配置就写未配置，未接入就写未接入）。
- **工具/步骤行**：一律**无展开箭头**，整行点按展开收起（箭头
  2026-10-26 全面退役）；行头最小高 44，状态图标 15、间距 8。

## 6.5 命令卡与思考（2026-10-28 用户逐版对预览拍板）

**命令卡**（命令类工具的展开态；没有独立执行界面，执行都在
对话里看）：

- **双层**：上层 = 命令，下层 = 结果；执行中只有上层，结果层
  完成后才出现（外加一行「执行中…」）。
- **无标题行、无「命令/结果」标签**：退出码与复制**悬浮**在
  卡片右上角（胶囊，半透底），不独占一行；退出码 0 灰、非 0 红；
  执行中还没有退出码，只悬浮「复制」。
- 命令第一行 = **状态点 + 执行面名**：沙箱 `SandBox`、手机
  `Shell`（点：成功绿 / 失败红 / 执行中黄），命令紧贴其后一个
  字符位；第 2 行起左侧是**行号**（进到执行面名开头的位置），
  命令紧贴行号——不设统一代码列。标题行文案对应
  「在沙箱/在手机执行了命令」。
- 两层高度按 **6:4** 分上限（命令 168dp / 结果 112dp），不到
  按实际高度；超出卡内滚动，**滑轮细（3dp、低对比）**；长行
  不换行、横向滑；两层滚动内容**末尾留让位空白**（≈悬浮按钮
  宽度），滑到底时末尾文字能完整滑出悬浮按钮下方。
- **不显示执行时间**（卡片、工具行、运行态都不显示）。
- 嵌套滚动：手指在卡内滚卡内，滚到头才带动会话。

**思考**（步骤的推理通道）：

- **无边框不成卡**：一行「思考」+ 纯文本；开关就是「思考」
  两个字本身（点展开、再点收起），没有收起按钮、不显示时间。
- 展开默认：流式中展开，结束后收起；展开后限高内滚（上限
  **不标注**在界面上），滑轮同命令卡的细规格。
- 思考原文只出现在这里一处，正文区不复述。

## 7. 状态与语义色

语义色不随主题变化，深浅两底上都保证对比：成功绿 #22C55E、
警告橙、错误红 #EF4444（以 `app_theme.dart` 的 `HColors` 为准）。
只用于：状态点、权限警示、决策指示灯、置信度概率条、表单校验。
装饰性场合一律黑白灰。

## 8. 已退役清单（不要再引入）

`CupertinoSwitch`、系统分段控件、`PopupMenuButton`、
`CupertinoActionSheet`、居中弹窗（`showDialog` 类）、`SnackBar`、
iOS 顶部灰胶囊轻提示、描边（线条）图标、emoji 图标、工具行展开
箭头、静态写死的版本号（关于页版本必须运行时读真实值）。

## 9. 变更流程

1. 视觉大改先做 **HTML 预览**给用户拍板（选型类给 2–4 案并附
   推荐与理由），拍板后才写代码。
2. 实现后跑全量测试（新行为补测试钉住），`flutter analyze` 零问题。
3. 真机复核以用户截图为准：与原型/拍板稿逐屏对过才能说完成。

---

*本文放在 `docs/` 下（公開），与同目录的 `INTERFACE.md`
（前后端契约）分工：一个管界面长什么样，一个管数据怎么走。*
