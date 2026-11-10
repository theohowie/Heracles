/// `app/lib/screens/**` 的英文词条。
///
/// **归属：前端界面线（fe-ui）**。别人不要往这里加。
///
/// 规则：
/// - key = 代码里的中文原文，**逐字一致**（含全角标点、空格、`…`）。
/// - 只放**用户可见**的文案；注释、日志、debugPrint、异常技术细节不翻。
/// - 技术名词保留原样：MCP / JSONL / append-only / BYOK / PRoot / token / diff / commit。
/// - 缺失的条目在英文模式下会退回中文（安全回退），所以可以分批补。
///
/// ## v0.5.1 第一版覆盖范围（fe-ui，2026-11-10）
///
/// `app/lib/screens/**` 里**已经包了 `tr()` 的**中文字面量全部有英译（254 条），
/// 分布在 13 个页面文件：settings 141 / chat 49 / sandbox 22 / voice 19 /
/// jev_settings 16 / robot 12 / automation 11 / mcp 8 / skills 8 /
/// jev_local 7 / search 7 / archived 6 / oss 1。
///
/// ⚠️ **没覆盖的**（英文下仍显示中文，属已知缺口）：
/// - 含运行时插值（`$var`）的句子 —— 字典 key 承载不了变量，需改 `tr(args:)` 后再补；
/// - `app/lib/widgets/**` 的文案（顶栏、输入条、抽屉、工具卡等）—— 归组件线 `en_widgets.dart`；
/// - 模型名 / 工具名 / URL / `/命令` / 异常技术细节 —— 按设计不翻。
library;

Map<String, String> get enScreens => const <String, String>{
      'GitHub 仓库': 'GitHub repository',
      '流式输出': 'Streaming output',
      '行为': 'Behavior',
      '逐字显示模型回复': 'Show the model\u2019s reply token by token',
      '长任务在后台继续跑需要的系统设置。Android 不保证永不被杀；这里只显示真实状态与引导，不假装“开了就一直跑”。':
          'The system settings long tasks need to keep running in the background. Android doesn\u2019t guarantee an app is never killed; this page shows the real state and guidance rather than pretending that turning something on keeps the app running forever.',
      '本机检测': 'On-device checks',
      '本地模型': 'Local models',
      '云端': 'Cloud',
      '本地': 'Local',
      '语音输入': 'Voice input',
      '语音模型': 'Voice models',
      '扫描问题（这些技能没有生效）':
          'Scan problems (these skills are not active)',

      // ── 设置：首页 / 通用 / 模型 / 外观 / 关于 ────────────────────────────
      '设置': 'Settings',
      '通用': 'General',
      '通用设置': 'General settings',
      '显示': 'Display',
      '外观': 'Appearance',
      '主题': 'Theme',
      '深浅': 'Light / dark',
      '界面语言': 'Language',
      '中文 / English；未翻译的条目仍显示中文':
          '中文 / English; strings not translated yet still show Chinese',
      '界面字号': 'Interface font size',
      '界面字号 · 工作步骤 · 繁忙发送 · 最大轮次':
          'Font size · Work steps · Sending while busy · Max rounds',
      '字号大小': 'Font size',
      '全局字阶按比例缩放，拖动实时预览':
          'Scales the whole type scale proportionally, with a live preview while dragging',
      '小': 'Small',
      '大': 'Large',
      '工作步骤展示': 'Work step display',
      '选择希望看到多少工具调用细节':
          'Choose how much tool-call detail you want to see',
      '繁忙时发送': 'Sending while busy',
      '使用独立发送按钮': 'Use a separate send button',
      '开启后键盘回车插入换行，发送只走右下按钮；关闭则为回车即发送':
          'When on, Enter inserts a newline and only the button sends; when off, Enter sends.',
      '最大轮次': 'Max rounds',
      '自动 = 云端 40 轮（默认）。轮次越多，单次任务能做的步骤越多，但可能跑更久；云端按轮计费，花费也更多。':
          'Auto = 40 rounds on cloud (default). More rounds mean more steps per task, but possibly longer runs; cloud rounds are billed, so it also costs more.',
      '图标风格': 'Icon style',
      '玻璃效果': 'Glass effect',
      '面板使用半透明毛玻璃质感': 'Panels use a translucent frosted-glass look',
      '始终开启': 'Always on',
      '智能体': 'Agent',
      '模型': 'Models',
      '记忆': 'Memory',
      '全局记忆': 'Global memory',
      '会话私有记忆只在该会话里生效 · 进入某个会话查看':
          'Session-only memory applies to that session alone · open a session to view it',
      '模型提议': 'Model suggestions',
      '模型提议的全局记忆，只有你确认后才会对所有会话生效':
          'Global memories suggested by the model only apply to all sessions after you confirm them',
      '晋升为全局': 'Promote to global',
      '忽略': 'Ignore',
      '暂无记忆': 'No memories yet',
      '写下要长期记住的事…': 'Write something worth remembering long-term…',
      '清空记忆': 'Clear memory',
      '清空': 'Clear',
      '删除这条记忆？': 'Delete this memory?',
      '存储软预算': 'Storage soft budget',
      '注入预算': 'Injection budget',
      '按任务检索后注入；没命中的条目压成摘要':
          'Retrieved by task and injected; items that don\u2019t match are compressed into a summary',
      '上限为契约默认值（§N12.8），B1 接入后以宿主回报为准':
          'Limits fall back to the contract defaults (§N12.8); once B1 lands, the host\u2019s reported values take precedence',
      '添加': 'Add',
      '添加模型提供商': 'Add a model provider',
      '编辑': 'Edit',
      '设为默认': 'Set as default',
      '恢复默认模型': 'Restore the default model',
      '删除这个提供商？': 'Delete this provider?',
      '同时清除已保存的 API Key': 'Also clear the saved API key',
      '尚未配置': 'Not configured',
      '未配置': 'Not configured',
      '例如：我的 DeepSeek': 'e.g. My DeepSeek',
      'API 协议': 'API protocol',
      '手填模型 ID（目录外也可直接发送）':
          'Type a model ID (IDs outside the catalog can be sent directly)',
      '模型选择器中将不显示任何模型；目录外 ID 仍可直接发送。':
          'No models will appear in the model picker; IDs outside the catalog can still be sent directly.',
      '获取可用模型': 'Fetch available models',
      '说明': 'Notes',
      '编码层自检': 'Encoding-layer self-check',
      '跑一遍编码层自检': 'Run the encoding-layer self-check',
      '诊断与自检': 'Diagnostics & self-check',
      '设备权限': 'Device permissions',
      '后台运行': 'Background running',
      '保活状态 · 电池优化 · 自启动':
          'Keep-alive status · Battery optimization · Autostart',
      '权限': 'Permissions',
      '权限说明': 'Permission notes',
      '授权引导': 'Authorization guide',
      '三种授权方式任选其一：': 'Pick any one of the three authorization methods:',
      '通过 Shizuku 一键授权': 'Authorize in one tap via Shizuku',
      '重新向 Shizuku 申请授权（收录本 App）':
          'Request Shizuku authorization again (register this app)',
      '我已执行授权，刷新状态': 'I\u2019ve authorized it — refresh status',
      '一切正常 —— 无障碍被系统关闭时会自动恢复，无需干预。':
          'All good — if accessibility gets turned off by the system it recovers automatically; no action needed.',
      '长任务在后台继续跑需要的系统设置。Android 不保证永不被杀；这里只显示真实状态与引导，不假装"开了就一直跑"。':
          'The system settings long tasks need to keep running in the background. Android doesn\u2019t guarantee an app is never killed; this page shows the real state and guidance rather than pretending that turning something on keeps the app running forever.',
      '新会话的默认权限': 'Default permission for new sessions',
      '决定工具执行前是否需要你确认':
          'Whether tool calls need your approval before running',
      '单次任务最多执行的工具轮次': 'Maximum tool rounds per task',
      '审批时选过「始终允许」的工具': 'Tools you chose "Always allow" for',
      '已始终允许的工具': 'Tools always allowed',
      '任务执行中发消息如何处理': 'How messages sent mid-run are handled',
      '语音识别': 'Voice recognition',
      '沙箱': 'Sandbox',
      '搜索服务': 'Search service',
      'endpoint 配置 · 仅免鉴权': 'Endpoint configuration · No auth only',
      '机器人接入': 'Bot access',
      '飞书 · QQ(OneBot) · 微信官方': 'Feishu · QQ (OneBot) · WeChat Official',
      '已归档对话': 'Archived chats',
      '应用': 'App',
      '关于': 'About',
      '关于 Heracles': 'About Heracles',
      '开源与反馈': 'Open source & feedback',
      '开源许可证': 'Open-source licenses',
      '问题反馈': 'Feedback',
      '© 2026 Heracles 项目 · 开源软件': '© 2026 The Heracles Project · Open source',
      '版本信息': 'Version info',
      '当前版本': 'Current version',
      '构建号': 'Build number',
      '运行平台': 'Platform',
      '开发框架': 'Framework',
      '默认': 'Default',

      // ── 设置：关于页正文 / 首启说明 ─────────────────────────────────────
      '在手机上开发': 'Develop on your phone',
      '手机上的开发智能体': 'A development agent on your phone',
      'Heracles 是一个装在手机里的开发智能体：一句话说清需求，它就在你的手机上读文件、改代码、跑命令，把 App 构建、解包、重打包成能直接安装的成品——从想法到装上手机，一台手机全搞定。':
          'Heracles is a development agent that lives on your phone: describe what you need in one sentence and it reads files, edits code and runs commands on your phone — building, unpacking and repackaging apps into something installable. From idea to installed app, all on one phone.',
      '它能做什么': 'What it can do',
      '代码、文本、文档': 'Code, text, documents',
      '本机构建与改包': 'Build & repackage on device',
      '接入你自己的模型': 'Connect your own models',
      '填入各提供商的 API 密钥即可使用其模型。':
          'Enter an API key for a provider to use its models.',
      '任务计划看得见': 'See the task plan',
      '记得住你的习惯': 'Remembers your habits',
      '危险操作先经你确认': 'Risky operations ask you first',
      '数据去向透明': 'Transparent about where data goes',
      'Key 只存在这台手机上': 'Your key stays on this phone only',
      '安全与隐私': 'Security & privacy',
      '在手机上真跑一遍：起前台服务 → 读温度/电量 → 定位工具链 → 建 Hello World → 构建 → 拆包核对。':
          'Actually run it on the phone: start the foreground service → read temperature/battery → locate the toolchain → create Hello World → build → unpack and verify.',
      '构建要 1–3 分钟，期间请不要切走应用…':
          'The build takes 1–3 minutes; please don\u2019t switch away from the app…',
      '当前执行路由：': 'Current execution route:',
      'Dart 内核': 'Dart core',
      '启动自检': 'Startup self-check',
      '+ 添加': '+ Add',

      // ── 聊天页：空态 / 顶栏 / 排队 / 建议 ────────────────────────────────
      '还没有配置模型 API Key —— 填好才能开始对话':
          'No model API key configured yet — fill one in to start chatting',
      '去设置': 'Open settings',
      '先选一个工作区': 'Choose a workspace first',
      '上下文': 'Context',
      '引擎': 'Engine',
      '回答': 'Answer',
      '状态': 'Status',
      '文件': 'Files',
      '命中': 'Hits',
      '关闭': 'Close',
      '取消': 'Cancel',
      '重试': 'Retry',
      '知道了': 'Got it',
      '打开': 'Open',
      '删除': 'Delete',
      '删除会话': 'Delete session',
      '会话名称': 'Session name',
      '重命名会话': 'Rename session',
      '加载更早消息': 'Load earlier messages',
      '正在加载更早消息…': 'Loading earlier messages…',
      '压缩上下文': 'Compact context',
      '拍照': 'Take a photo',
      '照片': 'Photos',
      '相机': 'Camera',
      '截图、图片': 'Screenshots, images',
      '选择文件夹': 'Choose folder',
      '分支名，例如 feature/login': 'Branch name, e.g. feature/login',
      '新建分支': 'New branch',
      '创建并切换': 'Create and switch',
      '模型需要你的回答': 'The model needs your answer',
      '等待您的回答': 'Waiting for your answer',
      '暂时收起': 'Collapse for now',
      '5 分钟内有效': 'Valid for 5 minutes',
      '改选子文件夹': 'Pick a different subfolder',
      '使用「默认工作区」': 'Use the default workspace',
      'App 自带的目录，不受这个限制，创建后可以直接开始干活。':
          'A folder bundled with the app; not subject to this restriction, and you can start working right after creating it.',
      '点进去选一个具体的项目文件夹（子文件夹可以正常授权）。':
          'Open it and choose a specific project folder (subfolders can be authorized normally).',
      '立即发送（插话）': 'Send now (interrupt)',
      '置顶（下一个发）': 'Move to top (send next)',
      '编辑排队消息': 'Edit queued message',
      '保存后替换这条排队内容；附件与队列位置不变。':
          'Saving replaces this queued message; attachments and queue position stay the same.',
      '点一条可编辑；跑完当前任务会自动发出':
          'Tap one to edit; it\u2019s sent automatically when the current task finishes',
      '点这一行编辑': 'Tap this row to edit',

      // ── 沙箱页 ───────────────────────────────────────────────────────────
      '执行通道': 'Execution channels',
      '挂载点': 'Mount points',
      '编译环境': 'Build toolchain',
      '环境': 'Environment',
      '管理': 'Manage',
      '激活沙箱': 'Activate sandbox',
      '正在解包 rootfs…': 'Unpacking rootfs…',
      '激活后显示。沙箱通过 @名字 访问外部目录。':
          'Shown once activated. The sandbox reaches external folders via @name.',
      '暂无挂载点。': 'No mount points yet.',
      '暂无通道信息。': 'No channel information yet.',
      'PRoot 就绪': 'PRoot ready',
      'PRoot 尚未就绪，命令暂时无法在沙箱执行。':
          'PRoot is not ready yet; commands can\u2019t run in the sandbox for now.',
      '通道只展示可用性，放不放行由权限门禁决定。':
          'Channels only show availability; whether they\u2019re allowed is up to the permission gate.',
      '重置沙箱': 'Reset sandbox',
      '重置沙箱？': 'Reset the sandbox?',
      '重置': 'Reset',
      '整块回滚，清掉环境与产物':
          'Rolls everything back, clearing the environment and its output',
      '沙箱里的环境、产物和缓存会被整块清掉，回到未激活状态。挂载点指向的外部文件不受影响。':
          'The sandbox environment, its output and caches are cleared entirely, returning to the inactive state. Files that mount points refer to are unaffected.',
      '安装位置': 'Install location',
      '卸载编译环境': 'Uninstall the build toolchain',
      '卸载编译环境？': 'Uninstall the build toolchain?',
      '卸载': 'Uninstall',
      '下载': 'Download',
      '下载编译环境？': 'Download the build toolchain?',
      '需要下载约 415 MB（JDK 17 + Gradle + android.jar）。建议在 Wi-Fi 下进行；中断后可以续传。':
          'This downloads about 415 MB (JDK 17 + Gradle + android.jar). Wi-Fi is recommended; an interrupted download can resume.',

      // ── 语音设置页 ───────────────────────────────────────────────────────
      '语音识别说明': 'About voice recognition',
      '流式识别（内置）': 'Streaming recognition (built in)',
      '重新安装': 'Reinstall',
      '确认卸载': 'Confirm uninstall',
      '卸载语音输入？': 'Uninstall voice input?',
      '删除语音模型？': 'Delete the voice models?',
      '会删除内置流式模型（约 24 MB）与 SenseVoice（若已下载），语音输入随即不可用；可随时在本页「重新安装」。':
          'This deletes the built-in streaming model (~24 MB) and SenseVoice (if downloaded), after which voice input stops working; you can reinstall any time from this page.',
      '删除 SenseVoice 后仍可用内置流式识别；需要时可重新下载。':
          'After deleting SenseVoice the built-in streaming recognizer still works; you can download it again whenever you need it.',
      '该目录下两套模型（内置流式 + SenseVoice）在「卸载语音输入」时一并删除；卸载 App 也会一并删除。录音不上传。':
          'Both models in that directory (built-in streaming + SenseVoice) are deleted together when you uninstall voice input; uninstalling the app deletes them too. Recordings are never uploaded.',

      // ── JEV（决策引擎）设置页 ────────────────────────────────────────────
      'JEV 决策引擎': 'JEV decision engine',
      '本地配置': 'Local configuration',
      '模型目录': 'Model catalog',
      '预置基元律动：https://tokenrhythm.studio/v1/decision':
          'Built-in TokenRhythm: https://tokenrhythm.studio/v1/decision',
      '两种填法：① 完整端点 https://tokenrhythm.studio/v1/decision；② 只填到 https://tokenrhythm.studio/v1，应用自动补 /decision。':
          'Two ways to fill it in: ① the full endpoint https://tokenrhythm.studio/v1/decision; ② stop at https://tokenrhythm.studio/v1 and the app appends /decision.',
      '平台密钥，sk_ 开头': 'Platform key, starts with sk_',
      '基元律动固定 NeoHorse-Jev-4B': 'TokenRhythm pins NeoHorse-Jev-4B',
      '已按固定 ID 发送': 'Sent using the fixed ID',
      '改完点右上角「保存」；获取模型与测试连接用的是框里当前填的值，不用先保存。':
          'Tap Save in the top right when done; fetching models and testing the connection use the values currently in the fields, so you don\u2019t need to save first.',
      '引擎来源（云端 / 本地）在决策页输入框左下角点按切换；这里编辑云端接口，本地模型与本机检测在下方「本地配置」里。':
          'The engine source (cloud / local) is switched from the pill at the bottom-left of the decision page input; here you edit the cloud endpoint, while local models and on-device checks live under "Local configuration" below.',
      '理由生成暂不支持（后续版本提供）：决策只给结论与概率。':
          'Reasoning generation isn\u2019t supported yet (coming in a later version): decisions only return the conclusion and probability.',
      '原始响应体：': 'Raw response body:',
      '原始响应体：（无）': 'Raw response body: (none)',
      '复制详情': 'Copy details',

      // ── 本地引擎页 ───────────────────────────────────────────────────────
      '重新检测': 'Re-detect',
      '检测不可用（宿主未返回本机信息）。云端决策不受影响。':
          'Detection unavailable (the host didn\u2019t return on-device info). Cloud decisions are unaffected.',
      '本地推理引擎尚未接入：模型可以先下载备好，引擎由后端接入后即可离线决策；现在想体验，先用云端。权重为 StartLux-Decision（CC BY-NC 4.0，非商业使用），经 Hugging Face 下载（镜像优先）；另含引擎所需的tokenizer 与决策配置文件。':
          'The local inference engine isn\u2019t wired up yet: you can download models ahead of time, and once the backend connects the engine you can make decisions offline; to try it now, use the cloud. Weights are StartLux-Decision (CC BY-NC 4.0, non-commercial use), downloaded via Hugging Face (mirror first); it also includes the tokenizer and decision config files the engine needs.',

      // ── 搜索服务设置页 ───────────────────────────────────────────────────
      '搜索 endpoint': 'Search endpoint',
      'endpoint（免鉴权搜索服务）': 'endpoint (search service without auth)',
      '清除': 'Remove',
      '配置读取失败（环境问题），本页暂不能编辑。错误信息已脱敏。':
          'Failed to read the configuration (an environment issue), so this page can\u2019t be edited right now. The error message has been redacted.',
      'web_search 未配置时的提示是「尚未配置搜索服务：请在设置里填写搜索 endpoint 后重试」——配置好这里之后，该提示自然消失。':
          'When web_search is unconfigured it reports "Search service not configured: fill in the search endpoint in Settings and retry" — once this is set up, that message goes away on its own.',
      '读取失败': 'Read failed',

      // ── 技能页 ───────────────────────────────────────────────────────────
      '技能': 'Skills',
      '技能列表读取失败': 'Failed to read the skill list',
      '技能通道不可用': 'Skill channel unavailable',
      '安装 / 卸载（下一批）': 'Install / uninstall (next batch)',
      '当前版本还不能从 App 里安装/卸载技能包：内置技能随版本发行，用户技能靠把目录放进 `.heracles/skills/`。通道落地后这里会给出安装入口。':
          'This version can\u2019t install or remove skill packs from the app: built-in skills ship with the release, and user skills come from a directory placed under `.heracles/skills/`. An install entry point will appear here once the channel lands.',
      '还没有用户技能。把技能放在工作区的 `.heracles/skills/<名字>/SKILL.md`，重启任务后出现在这里。':
          'No user skills yet. Put skills in `.heracles/skills/<name>/SKILL.md` inside the workspace and they\u2019ll show up here after you restart the task.',
      '技能只影响"模型看到什么说明"，不绕过工具审批门禁：技能里要求的命令/写文件仍走同一套 Allow / NeedsApproval / Deny 判定。':
          'Skills only affect the instructions the model sees; they don\u2019t bypass the tool approval gate: commands and file writes a skill asks for still go through the same Allow / NeedsApproval / Deny decision.',

      // ── MCP 页 ───────────────────────────────────────────────────────────
      'MCP 服务器': 'MCP servers',
      '名称': 'Name',
      '启用': 'Enabled',
      '传输方式': 'Transport',
      '校验规则（后端 validateMcpServer）':
          'Validation rules (backend validateMcpServer)',
      '当前版本没有 MCP 通道：不能增删改服务器、也读不到连接状态。下面只是表单骨架，提交会明确告诉你"未保存"。':
          'This version has no MCP channel: servers can\u2019t be added, edited or removed, and connection status can\u2019t be read. The form below is only a skeleton; submitting tells you plainly that nothing was saved.',

      // ── 自动化页 ─────────────────────────────────────────────────────────
      '自动化任务': 'Automations',
      '新建自动化任务': 'New automation task',
      '标题': 'Title',
      '提示词': 'Prompt',
      '间隔（分钟）': 'Interval (minutes)',
      '按 cron 表达式': 'By cron expression',
      '当前版本只支持固定间隔；cron 未实现':
          'This version only supports fixed intervals; cron isn\u2019t implemented',
      '到点后在你下次打开/回到 App 时自动执行；App 没打开时只提醒。':
          'Runs when you next open or return to the app; while the app is closed you only get a reminder.',
      '还没有自动化任务。点右上角 + 新建一条（定时提醒）。':
          'No automations yet. Tap + in the top right to create one (a scheduled reminder).',
      '保存': 'Save',

      // ── 机器人接入页 ─────────────────────────────────────────────────────
      '必须知道的': 'What you must know',
      '模式': 'Mode',
      '地址': 'Address',
      'accessToken（掩码显示）': 'accessToken (masked)',
      '启停': 'Start/stop',
      '连接测试': 'Connection test',
      '接口未接通：本轮只有表单骨架，还不能保存或连接':
          'Interface not connected yet: this round only ships a form skeleton — saving and connecting don\u2019t work yet',
      '正向 WebSocket（ws://）｜反向 WebSocket':
          'Forward WebSocket (ws://) | Reverse WebSocket',
      '需要：后端 §N19 机器人接入通道（OneBot 收发、事件回传、离线消息队列与配置落盘）。落地后此卡自动激活，状态四态：未配置 / 连接中 / 已连接 / 失败。':
          'Requires the backend §N19 bot channel (OneBot send/receive, event callback, offline message queue and config persistence). Once it lands this card activates automatically, with four states: not configured / connecting / connected / failed.',
      '下一批（需云中继）：手机没网时收不到消息，需要一台中继来代理事件。':
          'Next batch (needs a cloud relay): without network the phone receives no messages; a relay is needed to proxy events.',
      '· 手机离线时消息排队：Bot 收到的消息不会丢，回到 App 后按序处理。\n· Bot 不能绕过审批：危险操作仍需手机确认，与聊天页同一套 Allow / NeedsApproval / Deny 判定。':
          '· Messages queue while the phone is offline: what the bot receives isn\u2019t lost and is processed in order once you return to the app.\n· Bots can\u2019t bypass approvals: risky operations still need confirmation on the phone, using the same Allow / NeedsApproval / Deny gate as the chat page.',

      // ── 归档会话页 ───────────────────────────────────────────────────────
      '没有已归档的对话': 'No archived chats',
      '取消归档': 'Unarchive',
      '回档': 'Restore',
      '开源许可': 'Open-source licenses',
    };
