/* 站点内容与常量。
   ----------------------------------------------------------------------------
   事实纪律（2026-10-30 逐条核对过仓库，见 .dshwork/gh-pages-shots/facts.md）：
   · 这里的每条产品声明都必须能在仓库里找到依据；
   · 没被证明的东西只能出现在 LIMITS（页面上标为「尚未验证」）；
   · 可下载的包是 v0.2.2（2026-10-26），页面描述的主线能力与它并不完全一致，
     这一点在下载区如实写明，不混着说。
   ⚠️ 切换点：发布新包后要同时改 APK / VERSION / APK_SIZE / SHA / 版本对照文案，
      并按新包重拍截图（现在这 8 张是 2026-10-26 的界面）。 */

export const APK_GITHUB = 'https://github.com/theohowie/Heracles/releases/download/v0.3.2/Heracles-v0.3.2.apk'
export const APK_GITEE = 'https://gitee.com/theohowie/heracles/releases/download/v0.3.2/Heracles-v0.3.2.apk'

/* 两条线路**同一个包**（2026-10-30 复核）：GitHub 与 Gitee 的 `Heracles-v0.3.2.apk`
   都是 50,453,248 B = 48.1 MiB 的 arm64-only 构建（versionCode 6 / versionName 0.3.2，
   aapt2 读出 native-code 仅 arm64-v8a）。换版本时两条线路一起换、一起核。 */
export const GITEE_READY = true // 国内线路已就绪 → 默认走 Gitee
export const APK_ROUTES = [
  {
    key: 'gitee', label: 'Gitee', hint: '国内线路', url: APK_GITEE, ready: GITEE_READY,
    size: '48.1 MiB', build: 'arm64-only',
  },
  {
    key: 'github', label: 'GitHub', hint: '源站', url: APK_GITHUB, ready: true,
    size: '48.1 MiB', build: 'arm64-only',
  },
]
export const APK_PRIMARY = GITEE_READY ? APK_ROUTES[0] : APK_ROUTES[1]
export const APK_ALT = GITEE_READY ? APK_ROUTES[1] : null
export const APK = APK_PRIMARY.url

/* 「更多版本 / 校验值」优先跳码云（用户裁定 2026-10-30） */
export const RELEASES = 'https://gitee.com/theohowie/heracles/releases'
export const RELEASES_GITHUB = 'https://github.com/theohowie/Heracles/releases'
export const REPO = 'https://github.com/theohowie/Heracles'
export const GITEE = 'https://gitee.com/theohowie/heracles'
/* sha256 双向核对过（2026-10-30）：码云那份下载后实算 = A7C2AD5D…；
   GitHub API 的 asset.digest 也是 sha256:a7c2ad5d…，字节数同为 50,453,248 B
   ⇒ 两条线路确实是同一个文件。 */
export const SHA = 'A7C2AD5DB88663CE9BCDC59C0857CA041692D5867DE747C3D3E52B9EC817F6C5'
export const SHA_SOURCE = 'Gitee / GitHub 同一份文件'
export const VERSION = 'v0.3.2'
export const APK_SIZE = APK_PRIMARY.size
export const APK_VERSION_CODE = '6'
export const PKG = 'com.theohowie.heracles'
export const SHOT_DATE = '2026-10-26'

export const SHOT = (name) => `/Heracles/shots/${name}.webp`

/* ---------- 首屏规格条（三个都能复算） ---------- */
export const HERO_SPECS = [
  { value: '417', unit: '项', label: '内核 Dart 单测', note: 'backend/ 纯 Dart，可复跑' },
  { value: '90–99%', unit: '', label: '长任务缓存命中', note: '真机实测，累计/稳态' },
  { value: '33', unit: '个', label: '受控工具', note: '白名单 + 门禁三态' },
]

/* ---------- 事实带：只放机制，不放形容词 ---------- */
export const BAND = [
  { k: 'BYOK', v: 'Key 只存本地，只进请求头' },
  { k: 'append-only', v: '会话只追加，从不改写历史' },
  { k: '沙箱', v: 'PRoot + Alpine，产物可回滚' },
  { k: 'GPL-3.0', v: '源码、契约、设计文档全开源' },
]

/* ---------- 一次任务的回放（面板上明确标注「示例回放 · 非录屏」） ----------
   事件词汇与产品一致：工具回调 / plan / 门禁（deny·once·always）/ append-only。
   门禁那一步把两条分支都写出来 —— 拒绝就是不执行，这不是配置，是产品行为。 */
export const SESSION = {
  title: '新会话',
  meta: ['deepseek-v4.1', '默认工作区', 'append-only'],
  events: [
    {
      id: 'ask',
      kind: 'you',
      text: '在设置里加一个「深色模式」开关，和「外观」放一起。',
      time: '10:12',
    },
    {
      id: 'plan',
      kind: 'plan',
      steps: ['读外观页，确认开关该放哪', '打补丁：新增开关 + 主题联动', '跑一次检查'],
      note: '3 步 · 预计读 1 个文件',
    },
    {
      id: 'read',
      kind: 'tool',
      tool: 'read_file',
      arg: 'app/lib/screens/appearance_screen.dart',
      meta: '417 行 · 12 ms',
      surface: '工作区内',
    },
    {
      id: 'patch',
      kind: 'patch',
      tool: 'apply_patch',
      arg: 'app/lib/screens/appearance_screen.dart',
      stat: '+14 −0',
      diff: [
        { t: 'ctx', s: '  // 外观' },
        { t: 'del', s: '- ListTile(title: Text(\'浅色\')),' },
        { t: 'add', s: '+ SwitchListTile(' },
        { t: 'add', s: '+   title: Text(\'深色模式\'),' },
        { t: 'add', s: '+   value: theme.isDark,' },
        { t: 'add', s: '+   onChanged: theme.setDark,' },
        { t: 'add', s: '+ ),' },
      ],
    },
    {
      id: 'gate',
      kind: 'gate',
      tool: 'run_shell_command',
      cmd: 'git status --short',
      reason: '静态判不了它是否只在工作区内 —— 需要你确认',
      branches: {
        allow: [
          {
            id: 'shell',
            kind: 'tool',
            tool: 'run_shell_command',
            arg: 'git status --short',
            meta: 'exit 0 · 手机 shell',
            result: [' M app/lib/screens/appearance_screen.dart'],
          },
          {
            id: 'done',
            kind: 'done',
            title: '1 个文件 +14 −0，开关在「外观」第 3 行。',
            body: '没有动别的文件，也没有新建文件。',
            stat: '7 次工具调用 · 缓存命中 94%（示例值）',
          },
        ],
        deny: [
          {
            id: 'denied',
            kind: 'deny',
            title: '已拒绝，命令没有执行。',
            body: '我不跑它，只回报刚才的改动位置 —— 你也可以让我换一种方式核对。',
          },
          {
            id: 'done-deny',
            kind: 'done',
            title: '任务结束：1 个被拒绝的工具没有执行。',
            body: '改动已经落在工作区里，随时可以回滚。',
            stat: '6 次工具调用 · 0 次未授权执行',
          },
        ],
      },
    },
  ],
}

/* 回放右侧的注解：解释「你刚才看到的」背后的机制 */
export const SESSION_NOTES = [
  { n: '01', k: '工具白名单', v: '模型只能调用注册过的工具；每次调用都是一张可展开的卡片：读了哪个文件、改哪几行、命令输出是什么。长任务执行中随时可以停。' },
  { n: '02', k: '门禁三态', v: '判决层只有放行 / 需确认 / 拒绝；需确认时你选允许一次、始终允许或拒绝。手动审批档下，写文件与 shell 都要你点头。' },
  { n: '03', k: 'append-only', v: '历史只往后追加，写盘前断言前缀不变。同一会话的代价随轮次几乎不变，压缩也更可预测。' },
  { n: '04', k: '解析失败不猜', v: '工具参数解析不出来就不执行，如实回告，绝不替你猜一个答案。' },
]

/* ---------- 从上手到出包：这是真序列，所以用 01–04 编号 ---------- */
export const STEPS = [
  {
    key: 'workspace',
    label: '加工作区',
    shot: SHOT('empty-v2'),
    title: '先把项目放进来',
    body: '用系统文件选择器授权项目目录，或直接用不受限的默认工作区。它读到的是你真实的工程文件，不是上传到云端的副本。',
    points: ['SAF 授权，不复制项目', '支持 /sdcard 上的既有工程', '工作区按路径登记，互不覆盖'],
    spec: '授权目录 · 原地读写',
  },
  {
    key: 'talk',
    label: '说明需求',
    shot: SHOT('chat-v2'),
    title: '像跟人说话一样描述任务',
    body: '说清要改什么，它自己决定调哪些工具。每次调用都是一张可展开的卡片：读了哪个文件、改了哪几行、命令输出是什么，都留在会话里可回查。',
    points: ['工具调用可展开核对', '改文件给出行级 diff', '语音转写、拍照进附件'],
    spec: '工具卡 · 行级 diff',
  },
  {
    key: 'model',
    label: '配模型',
    shot: SHOT('modelsheet-v2'),
    title: '模型与思考档位随时切',
    body: '多家提供商并存，默认用哪个一目了然。思考档位与最大轮次在同一个抽屉里，切换只对新消息生效，不会打断正在跑的任务。',
    points: ['OpenAI 兼容 / Anthropic / Responses 三轨可配', '思考档位按协议自适应', '最大轮次可限制花费'],
    spec: '三轨协议 · 档位自适应',
  },
  {
    key: 'route',
    label: '看清权限与路由',
    shot: SHOT('perms-v2'),
    title: '这条命令会跑在哪，先告诉你',
    body: '设备权限与当前执行路由集中在一页；命令按路由去沙箱或手机 shell。沙箱没就绪就直接拒绝，不会偷偷改到手机上跑。',
    points: ['权限与执行路由一页看清', '沙箱环境按需下载', '产物留在 rootfs，清空重装即回滚'],
    spec: '执行路由 · 未就绪即拒绝',
  },
]

/* ---------- 特性 bento（6 列基准）：span 2 小卡 / 3 半行 / 4 旗舰 ---------- */
export const FEATURES = [
  {
    icon: 'box', span: 4, tone: 'ink',
    title: '默认工作区挂进沙箱，改完命令就能读',
    desc: 'App 自建的默认工作区有物理路径，会挂到沙箱的 /opt/ws-real：文件工具改的东西，命令立刻读得到。SAF 授权的目录没有物理路径、挂不进去，那时沙箱只看得见它自己那份；清空重装只清 rootfs，工作区里的改动要你自己回滚。',
    spec: '真机已验证 · 写回后两侧一致',
  },
  {
    icon: 'shield', span: 2, tone: 'mark',
    title: '抗幻觉靠架构',
    desc: '工具白名单 + 参数门禁三态（放行 / 需确认 / 拒绝）+ 解析失败绝不猜：不执行，如实回告。',
    spec: '白名单 · fail-closed',
  },
  {
    icon: 'terminal', span: 2,
    title: '内联执行沙箱',
    desc: '自带 PRoot + Alpine rootfs：命令在独立文件系统里跑，工作区按需挂进 /opt/ws-real；aapt2 / aidl / zipalign 随包，JDK 与 Gradle 按需下载。',
    spec: '独立 rootfs · 可回滚',
  },
  {
    icon: 'folder', span: 2,
    title: '真实工作区',
    desc: '用系统文件选择器授权任意目录（含 /sdcard 上的项目）。列目录、读文件、局部补丁、按文件名与按内容搜索。',
    spec: 'SAF · 原地读写',
  },
  {
    icon: 'eye', span: 2,
    title: '执行过程看得见',
    desc: '长任务收进灵动岛：收起是步骤数字轨道，展开是完整待办。该问就问、该批就批，每一次工具调用都落进 JSONL 可回查。',
    spec: '步骤轨道 · 全量留痕',
  },
  {
    icon: 'key', span: 2,
    title: 'BYOK，Key 不出手机',
    desc: 'API Key 只存本地安全存储、只出现在请求头里，不进日志。任务随时可中断，也可以排队后再发。',
    spec: '本地存储 · 不进日志',
  },
  {
    icon: 'mic', span: 2,
    title: '语音识别在本地跑',
    desc: '内置 14M 中文流式模型，随包带着、断网可用：点一下边说边出字，录音不上传。拍照直接进附件。',
    spec: '本地推理 · 断网可用',
  },
  {
    icon: 'compass', span: 2,
    title: 'JEV 决策模式',
    desc: '纠结「该不该」时问一句：云端专用决策模型给「推荐 / 不推荐 + 置信度」。它只给结论、不编理由；答不上就直说。',
    spec: '结论 + 置信度',
  },
  {
    icon: 'link', span: 3,
    title: '会话严格 append-only',
    desc: '从不改写历史消息，只往后追加。长会话的代价随轮次几乎不变，云端前缀缓存更稳，上下文压缩也更可预测。',
    spec: '只追加 · 压缩可预测',
  },
  {
    icon: 'code', span: 3,
    title: '纯 Dart 内核 + Flutter 前端',
    desc: 'backend/ 是纯 Dart 包，417 项单测不依赖 Flutter 与 Android；设备能力由 Kotlin 桥提供，界面层是 Flutter。',
    spec: 'backend/ 可 dart test',
  },
]

/* ---------- 界面 ---------- */
export const GALLERY = [
  { src: SHOT('empty-v2'), title: '空态', desc: '开口就是任务：一句话起步，五个建议胶囊', spec: '新会话' },
  { src: SHOT('chat-v2'), title: '会话与工具调用', desc: '工具卡可展开，改哪几行、跑什么命令都留痕', spec: '工具卡' },
  { src: SHOT('generating-v2'), title: '生成中', desc: '彩虹光圈 + 停止键，随时打断长任务', spec: '可中断' },
  { src: SHOT('modelsheet-v2'), title: '模型与思考', desc: '多家 provider、思考档位、最大轮次一处切换', spec: '三轨协议' },
  { src: SHOT('perms-v2'), title: '设备权限', desc: '权限与执行路由集中在一页', spec: '执行路由' },
  { src: SHOT('home-v2'), title: '设置首页', desc: '通用 / 记忆 / 权限 / 模型 / 外观', spec: '五个入口' },
  { src: SHOT('appearance-v2'), title: '外观', desc: '深浅与主题、玻璃效果实时预览', spec: '实时预览' },
  { src: SHOT('about-v2'), title: '关于', desc: '版本、许可与开源信息', spec: 'GPL-3.0' },
]

/* ---------- 状态台账（基线 = README §10「已知限制与未验证」+ 头部数字） ---------- */
export const WORKS = [
  '文件工具写工作区 → 沙箱 /opt/ws-real（真机，读回一致）',
  '沙箱执行链路：T0 rootfs / T1 工具内置 / T2 按需下载',
  '待办 / 提问 / 审批 / 切档四面板（真机逐项）',
  '三作用域记忆（会话私有 / 工作区共享 / 全局只读）',
  '本地语音：内置 14M 流式模型，断网可用（真机）',
  '轮间插话与排队发送（v0.3.2 修复后可用）',
  '会话严格 append-only（写前断言前缀、并发拒写）',
  '审批 fail-closed：答复落盘 once / always / deny',
  '取消、上下文压缩三级（40% / 60% / 80%）',
  '内核 417 项 Dart 单测（cd backend && dart test）',
]

export const LIMITS = [
  'release 用 debug 密钥签名（换正式密钥需卸载重装）',
  '线上字段的真 Key 验证（含 JEV 云端决策）',
  'Anthropic / Responses 两条协议轨（无真 Key 证据）',
  '模型读图 / 图片多模态（重构后未复验）',
  'JEV 本地推理（档位只能下模型，引擎未接入）',
  'APK 构建 / 逆向五件套未接线（build_apk、apk_* 会明确回「尚未接线」）',
  '记忆三作用域的真机验收台账仍待补',
  '流式语音质量未系统评测（长句 / 强噪声 / 方言）',
  '只支持 arm64：包内 armeabi-v7a / x86_64 是第三方插件库的死重，那两个 ABI 跑不起来',
  '英文界面暂不支持（选 English 会如实提示）',
  '测试环境：flutter test 并发偶发加载失败，门禁以 backend dart test 为准',
]

/* ---------- 最近实测（带日期，能回查台账） ---------- */
export const RUNS = [
  { date: '2026-10-30', text: '文件工具写工作区 → 沙箱 pwd=/opt/ws-real，ls/cat/wc 一致、写回可见', tag: '真机' },
  { date: '2026-10-30', text: '三作用域记忆真机五项全过：迁移 / 幂等 / 全局只读 / 提议晋升 / 会话隔离', tag: '真机' },
  { date: '2026-10-29', text: '长任务前缀缓存：累计 90–95%、稳态 96–99%（1 机型 1 模型 1 会话）', tag: '真机' },
]
