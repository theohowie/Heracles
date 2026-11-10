/* 站点内容与常量。
   ----------------------------------------------------------------------------
   事实纪律（2026-11-09 按仓库与实跑逐条核对）：
   · 这里的每条产品声明都必须能在仓库里找到依据；
   · 没被证明的东西只能出现在 LIMITS（页面上标为「尚未验证」）；
   · 可下载的包就是本页描述的 v0.5.0（2026-11-09 出包）：版本 / 版本码 / 体积 /
      校验值 / 两条线路都核过，页面上不混着说。
   ⚠️ 切换点：发布新包后要一起改 APK_GITHUB / APK_GITEE / VERSION / APK_SIZE /
      APK_VERSION_CODE / SHA / 版本对照文案。
   ⚠️ 截图纪律：`shots/*-v3.webp` 是 2026-10-30 的真机图（15 张 + 1 张录屏海报），
      继续复用；0.5.0 的新能力没有对应截图，只写文字条目 —— 不许拿旧图充新功能。 */

export const APK_GITHUB = 'https://github.com/theohowie/Heracles/releases/download/v0.5.0/Heracles-v0.5.0-arm64.apk'
export const APK_GITEE = 'https://gitee.com/theohowie/heracles/releases/download/v0.5.0/Heracles-v0.5.0-arm64.apk'

/* 两条线路**同一个包**（2026-11-09 核对）：GitHub 与 Gitee 的 `Heracles-v0.5.0-arm64.apk`
   都是 50,722,096 B = 48.4 MiB 的 arm64-only 构建（versionCode 37 / versionName 0.5.0，
   targetSdk 36、最低 API 31，native-code 仅 arm64-v8a）。
   换版本时两条线路一起换、一起核。 */
export const GITEE_READY = true // 国内线路已就绪 → 默认走 Gitee
export const APK_ROUTES = [
  {
    key: 'gitee', label: 'Gitee', hint: '国内线路', url: APK_GITEE, ready: GITEE_READY,
    size: '48.4 MiB', build: 'arm64-only',
  },
  {
    key: 'github', label: 'GitHub', hint: '源站', url: APK_GITHUB, ready: true,
    size: '48.4 MiB', build: 'arm64-only',
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
/* sha256（2026-11-09）：两条线路是同一个文件，页面只给一份校验值。
   用户拿自己的下载算一次、和这里对一遍就能确认没被换包。 */
export const SHA = 'C563E3E876E682286FF5EFF8F3460EF1D9F76F8CB34D34184414BC6C54B9576B'
export const SHA_SOURCE = 'Gitee / GitHub 同一份文件'
export const VERSION = 'v0.5.0'
export const APK_SIZE = APK_PRIMARY.size
export const APK_VERSION_CODE = '37'
export const PKG = 'com.theohowie.heracles'
/* 截图日期 = 图片本身的日期，**不等于**发布日（发布日 2026-11-09）。
   截图没重拍，就别改这个值 —— 一改就等于声称「这是新界面的实拍」。 */
export const SHOT_DATE = '2026-10-30'
export const SHOT_VERSION = 'v0.3.2'

/* 视频源：本地（GitHub Pages）为默认。若把两个 mp4 也传到码云 Release 附件，
   把地址放进数组最前面 —— 播放器会按顺序自动换源（前一个失败就试下一个）。 */
export const VIDEOS = {
  hero: ['/Heracles/video/hero-loop.mp4'],
  full: ['/Heracles/video/heracles-30s.mp4'],
}

export const SHOT = (name) => `/Heracles/shots/${name}.webp`

/* ---------- 首屏规格条（三个都能复算） ---------- */
export const HERO_SPECS = [
  { value: '632', unit: '项', label: '内核 Dart 单测', note: 'backend/ 纯 Dart，可复跑' },
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
  { n: '01', k: '工具白名单', v: '模型只能调用注册过的工具；每次调用就是一张卡片，点开是上拉抽屉：读了哪个文件、改哪几行、命令输出与退出码都在里面，抽屉标题行常驻退出码（0 绿 / 非 0 红）与复制。长任务执行中随时可以停。' },
  { n: '02', k: '门禁三态', v: '判决层只有放行 / 需确认 / 拒绝；需确认时你选允许一次、始终允许或拒绝。手动审批档下，写文件与 shell 都要你点头。' },
  { n: '03', k: 'append-only', v: '历史只往后追加，写盘前断言前缀不变。同一会话的代价随轮次几乎不变，压缩也更可预测 —— 只在到线那一次动历史。' },
  { n: '04', k: '解析失败不猜', v: '工具参数解析不出来就不执行，如实回告，绝不替你猜一个答案。' },
]

/* ---------- 从上手到出包：这是真序列，所以用 01–04 编号 ---------- */
export const STEPS = [
  {
    key: 'workspace',
    label: '加工作区',
    shot: SHOT('workspace-v3'),
    title: '先把项目放进来',
    body: '用系统文件选择器授权项目目录，或直接用不受限的默认工作区。它读到的是你真实的工程文件，不是上传到云端的副本。',
    points: ['SAF 授权，不复制项目', '支持 /sdcard 上的既有工程', '工作区按路径登记，互不覆盖'],
    spec: '授权目录 · 原地读写',
  },
  {
    key: 'talk',
    label: '说明需求',
    shot: SHOT('chat-v3'),
    title: '像跟人说话一样描述任务',
    body: '说清要改什么，它自己决定调哪些工具。每次调用都是一张卡片，点开是上拉抽屉：读了哪个文件、改了哪几行、命令输出是什么，都留在会话里可回查。',
    points: ['工具卡点开是上拉抽屉', '改文件给出行级 diff', '语音转写、拍照进附件'],
    spec: '工具卡 · 行级 diff',
  },
  {
    key: 'model',
    label: '配模型',
    shot: SHOT('model-v3'),
    title: '模型与思考档位随时切',
    body: '多家提供商并存，默认用哪个一目了然。思考档位与单轮输出上限在同一个抽屉里，切换只对新消息生效，不会打断正在跑的任务。',
    points: ['OpenAI 兼容 / Anthropic / Responses 三轨可配', '思考档位按协议自适应', '轮次与 token 预算默认不设上限'],
    spec: '三轨协议 · 档位自适应',
  },
  {
    key: 'route',
    label: '看清权限与路由',
    shot: SHOT('perms-v3'),
    title: '这条命令会跑在哪，先告诉你',
    body: '设备权限与当前执行路由集中在一页；命令按路由去沙箱或手机 shell。沙箱没就绪就直接拒绝，不会偷偷改到手机上跑。',
    points: ['权限与执行路由一页看清', '沙箱环境按需下载', '产物留在 rootfs，清空重装即回滚'],
    spec: '执行路由 · 未就绪即拒绝',
  },
]

/* ---------- 特性 bento（6 列基准）：span 2 小卡 / 3 半行 / 4 旗舰 ----------
   最后 8 张是 0.5.0 这一版的行为差异；它们没有截图，所以只写文字，不配图。 */
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
    desc: 'backend/ 是纯 Dart 包，632 项单测不依赖 Flutter 与 Android；设备能力由 Kotlin 桥提供，界面层是 Flutter。',
    spec: 'backend/ 可 dart test',
  },
  /* ---------- 0.5.0（2026-11-09） ---------- */
  {
    icon: 'sheet', span: 3,
    title: '工具卡点开是上拉抽屉，不再把对话挤长',
    desc: '卡片上只留入口，点开才是抽屉：命令、输出、diff 都在里面各滚各的。抽屉标题行常驻退出码（0 绿、非 0 红，拿不到就写「未知」）和复制 —— 滑到哪儿都看得见，不用回卡里找。',
    spec: '上拉抽屉 · 标题行常驻退出码与复制',
  },
  {
    icon: 'layers', span: 3,
    title: '压缩改成一条流水线，到线才动历史',
    desc: '占用到 85% 才压，压一次走三步：微压缩先把历史中段的工具输出换成占位符 → 本地会话记忆 → API 结构化摘要。不到线一个字节都不动，所以前缀缓存不会被每轮改写打散。',
    spec: '单阈值 85% · 微压缩 / 会话记忆 / 结构化摘要',
  },
  {
    icon: 'keyboard', span: 2,
    title: '回车是换行，发送走右下按钮',
    desc: '「使用独立发送按钮」默认开着：键盘回车插入换行，长提示可以慢慢写；想回到「回车即发送」，在通用设置里关掉即可。侧边栏只从左边缘拉出，卡片横滑不再把它误开。',
    spec: '默认开 · 通用设置可切回',
  },
  {
    icon: 'gauge', span: 2,
    title: '花费不再被上限掐断',
    desc: '轮次与 token 预算默认不设上限，任务能一直跑到做完；该停的两件事另有护栏：模型反复发完全相同的调用、连续多轮没有任何进展。上下文环图中心的「已用」= 各分项之和，和顶栏是同一个数。',
    spec: '不设上限 · 环图取分项之和',
  },
  {
    icon: 'spark', span: 2,
    title: '技能页接上真数据',
    desc: '内置技能与用户技能一起列，每个都带来源与说明；开关调 setSkillEnabled，再按重读结果回显，不是前端乐观改色。写得不合规的技能文件会如实列进错误里，不装作加载成功。',
    spec: '内置 + 用户 · 启停后重读回显',
  },
  {
    icon: 'clock', span: 2,
    title: '自动化任务：到点只写「待执行」',
    desc: '保存后重新读回来再渲染，不靠乐观的成功提示。调度目前只支持固定间隔：到点写一条「待执行」标记，下次打开或回到 App 时才执行 —— 不假装它在后台一直跑。',
    spec: '固定间隔 · 到点写标记',
  },
  {
    icon: 'cmd', span: 2,
    title: '三条斜杠命令直接改上下文',
    desc: '`/compact` 立即压一次；`/compact focus on …` 带上你关心的重点再压；`/autocompact 0.9` 直接改触发线（0.05–0.95）。阈值存在本地，重启也还在。',
    spec: '/compact · focus on … · /autocompact',
  },
  {
    icon: 'plug', span: 2,
    title: 'MCP 与机器人接入：先如实说没接通',
    desc: 'MCP 的服务器表单与校验规则已经在包里（密钥不许进 env），机器人接入也只给到 OneBot 的字段。通道没落地，提交与连接测试会被拒并写明「未保存」—— 不画假开关，也不写假配置。',
    spec: '页面与校验就位 · 通道未接通',
  },
]

/* ---------- 界面（2026-10-30 真机重拍 · 16 张，竖版 560 宽） ----------
   ⚠️ 这批图是 v0.3.2 的界面。0.5.0 的新能力没有重拍，就别往这里塞条目。 */
export const GALLERY = [
  { src: SHOT('empty-v3'), title: '空态', desc: '开口就是任务：一句话起步，五个建议胶囊', spec: '新会话' },
  { src: SHOT('tool-v3'), title: '工具卡与缓存', desc: '命令与退出码留在卡片上；顶栏实时显示缓存命中', spec: '工具卡' },
  { src: SHOT('ask-v3'), title: '它反过来问你', desc: '拿不准就问：给选项、给「其他」，不猜你的意图', spec: '提问面板' },
  { src: SHOT('queue-v3'), title: '排队与插队', desc: '多个问题排队、逐个回答，也能中途插队先发', spec: '队列' },
  { src: SHOT('usage-v3'), title: '用量与缓存', desc: '命中 / 未命中 / 输出逐项可见，缓存命中 95%', spec: '可复算' },
  { src: SHOT('context-v3'), title: '上下文占用', desc: '1% 已用，按系统提示 / 工具定义 / 消息拆开看', spec: '预算可见' },
  { src: SHOT('jevcard-v3'), title: 'JEV 决策入口', desc: '「有什么拿不准的？交给决策引擎判断」', spec: '决策模式' },
  { src: SHOT('jev-v3'), title: 'JEV 结论', desc: '给「推荐 / 不推荐 + 置信度」，不编理由', spec: '置信度' },
  { src: SHOT('approval-v3'), title: '审批档位', desc: '手动审批 / 工作区内修改 / 完全访问，随时切换', spec: '门禁三档' },
  { src: SHOT('voice-v3'), title: '本地语音输入', desc: '录音中再点一次麦克风结束，边说边出字，录音不上传', spec: '内置 14M 模型' },
  { src: SHOT('attach-v3'), title: '附件', desc: '相机拍照、相册选图、选文件，三种入口一列排开', spec: '拍照即附' },
  { src: SHOT('github-v3'), title: '连接 GitHub', desc: '设备码登录（2A8B-09E9），登录后即可读分支、提交改动', spec: '设备码' },
  { src: SHOT('search-v3'), title: '会话搜索', desc: '按工作区分组，跨会话搜关键词，最近会话带时间', spec: '可检索' },
  { src: SHOT('appearance-v3'), title: '外观', desc: '深浅、主题、玻璃效果与界面字号实时预览', spec: '实时预览' },
  { src: SHOT('settings-v3'), title: '设置首页', desc: '通用 / 记忆 / 权限 / 模型 / 外观，一屏看全', spec: '五个入口' },
  { src: SHOT('about-v3'), title: '关于', desc: '版本、许可与开源信息（图里这版是 0.3.2）', spec: 'GPL-3.0' },
]

/* ---------- 状态台账（基线 = README 头部数字 + 本轮实测；2026-11-09 同步） ---------- */
export const WORKS = [
  '文件工具写工作区 → 沙箱 /opt/ws-real（真机，读回一致）',
  '沙箱执行链路：T0 rootfs / T1 工具内置 / T2 按需下载',
  '待办 / 提问 / 审批 / 切档四面板（真机逐项）',
  '三作用域记忆（会话私有 / 工作区共享 / 全局只读）',
  '本地语音：内置 14M 流式模型，断网可用（真机）',
  '轮间插话与排队发送',
  '工具 / 命令卡片改上拉抽屉：标题行常驻退出码与复制',
  '回车默认换行 + 「使用独立发送按钮」（默认开）',
  '上下文压缩流水线：微压缩 / 会话记忆 / 结构化摘要，85% 单阈值触发一次',
  '/compact、/compact focus on …、/autocompact 0.05–0.95',
  '轮次与 token 预算默认不设上限，单轮输出上限可配',
  '402 余额不足说人话且不重试；环图「已用」= 分项之和',
  '技能页接真数据（内置 + 用户技能，启停后重读回显）',
  '自动化任务页：保存后重读回填，固定间隔到点写「待执行」',
  '会话严格 append-only（写前断言前缀、并发拒写）',
  '审批 fail-closed：答复落盘 once / always / deny',
  'arm64-only 发布包（v0.5.0 · 48.4 MiB，无 v7a / x86_64 死重）',
  '内核 632 项 Dart 单测（cd backend && dart test）',
]

/* 2026-11-09 核对：真 Key 端到端验证**至今一次都没跑过**，这条不许从「尚未验证」里拿走。
   MCP / 机器人接入的通道同样没落地（页面与校验规则在，提交会被拒）——
   两块都如实留在这一栏，不为了好看说成已完成。 */
export const LIMITS = [
  '真 Key 端到端验证（至今一次都没跑过）',
  'Anthropic / Responses 两轨的思考档位未生效（无真 Key 证据）',
  'MCP 服务器通道未接通（页面与校验规则就位，保存会被拒绝）',
  '机器人接入通道未落地（飞书 / OneBot / 微信三张卡，整页如实降级）',
  'JEV 本地推理（档位只能下模型，引擎未接入）',
  'APK 构建 / 逆向五件套未接线（build_apk、apk_* 会明确回「尚未接线」）',
  '记忆三作用域的真机验收台账仍待补',
  '流式语音质量未系统评测（长句 / 强噪声 / 方言）',
  '英文界面暂不支持（选 English 会如实提示）',
  '测试环境：flutter test 并发偶发加载失败，门禁以 backend dart test 为准',
]

/* ---------- 最近实测（带日期，能回查台账） ---------- */
export const RUNS = [
  { date: '2026-11-09', text: '内核 dart test 632/632（打 v0.5.0 包前实跑）', tag: '单测' },
  { date: '2026-11-09', text: 'v0.5.0 出包：50,722,096 B = 48.4 MiB，versionCode 37，arm64-only', tag: '构建' },
  { date: '2026-10-30', text: '文件工具写工作区 → 沙箱 pwd=/opt/ws-real，ls/cat/wc 一致、写回可见', tag: '真机' },
  { date: '2026-10-30', text: '三作用域记忆真机五项全过：迁移 / 幂等 / 全局只读 / 提议晋升 / 会话隔离', tag: '真机' },
  { date: '2026-10-29', text: '长任务前缀缓存：累计 90–95%、稳态 96–99%（1 机型 1 模型 1 会话）', tag: '真机' },
]

/* ---------- v0.5.0 这一版改了什么（逐条能对到仓库里的提交） ---------- */
export const CHANGELOG = [
  '工具与命令卡改成上拉抽屉看详情，不再内联展开；抽屉标题行常驻退出码 + 复制',
  '「使用独立发送按钮」开关（通用设置，默认开）：回车插入换行，发送只走右下按钮',
  '侧边栏收回窄边缘触发；卡片内的横滑不再把抽屉误开',
  '上下文压缩改成流水线：微压缩 → 本地会话记忆 → API 结构化摘要，85% 单阈值只压一次',
  '新增 /compact focus on …（指定压缩重点）与 /autocompact（改触发线 0.05–0.95）',
  '取消轮次与 token 预算：任务不再被上限掐断，停不停由循环检测与「连续无进展」判断',
  '402 余额不足说人话且不重试；上下文环图的「已用」改成各项之和',
  '技能页接真数据；自动化任务页保存后重读回填；MCP / 机器人接入如实标明未接通',
]
