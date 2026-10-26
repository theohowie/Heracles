import { useState } from 'react'
import { motion, AnimatePresence, useReducedMotion } from 'framer-motion'

const APK = 'https://github.com/theohowie/Heracles/releases/download/v0.2.1/Heracles-v0.2.1.apk'
const RELEASES = 'https://github.com/theohowie/Heracles/releases'
const REPO = 'https://github.com/theohowie/Heracles'
const GITEE = 'https://gitee.com/theohowie/heracles'
const SHA = '9A1227BA4A6ADDABC3997A5065C4AF0FBBF67B39E5DBD55EA8C746B2275944FB'

/* ---------- 内联 SVG 图标（全站不用 emoji） ---------- */
const Icon = ({ d, size = 22 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none"
    stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {d}
  </svg>
)

const ICONS = {
  folder: <><path d="M3 7.5A2.5 2.5 0 0 1 5.5 5h3.2l1.8 2h8A2.5 2.5 0 0 1 21 9.5v7A2.5 2.5 0 0 1 18.5 19h-13A2.5 2.5 0 0 1 3 16.5z" /></>,
  box: <><path d="M21 8 12 3 3 8v8l9 5 9-5z" /><path d="M3 8l9 5 9-5" /><path d="M12 13v8" /></>,
  shield: <><path d="M12 3l7 3v5c0 4.4-3 7.6-7 9-4-1.4-7-4.6-7-9V6z" /><path d="M9.5 12l1.8 1.8 3.4-3.6" /></>,
  link: <><path d="M10 13a5 5 0 0 0 7 0l2-2a5 5 0 0 0-7-7l-1 1" /><path d="M14 11a5 5 0 0 0-7 0l-2 2a5 5 0 0 0 7 7l1-1" /></>,
  key: <><circle cx="8" cy="15" r="4" /><path d="M11 12l8-8" /><path d="M17 6l2 2" /><path d="M15 8l2 2" /></>,
  code: <><path d="M9 8l-4 4 4 4" /><path d="M15 8l4 4-4 4" /></>,
  download: <><path d="M12 4v10" /><path d="M8 10l4 4 4-4" /><path d="M5 18h14" /></>,
  arrow: <><path d="M5 12h13" /><path d="M13 6l6 6-6 6" /></>,
  copy: <><rect x="9" y="9" width="11" height="11" rx="2" /><path d="M15 5H6a2 2 0 0 0-2 2v9" /></>,
}

const FEATURES = [
  { icon: 'folder', title: '真实工作区', desc: '用系统文件选择器授权任意目录（含 /sdcard 上的项目）。列目录、读文件、局部补丁、按文件名与按内容搜索，长文件自动分段。' },
  { icon: 'box', title: '在这台手机上构建 APK', desc: '工具链就绪后走 aapt2 → javac → d8 → 进程内对齐 → 签名，产出可安装的 APK。不需要 Gradle，也不需要另一台电脑。' },
  { icon: 'shield', title: '抗幻觉靠架构', desc: '工具白名单 + 参数门禁三态（允许 / 需要确认 / 拒绝）+ 解析失败绝不猜：不执行，如实回告。' },
  { icon: 'link', title: '会话严格 append-only', desc: '从不改写历史消息，只往后追加。长会话的代价随轮次几乎不变，云端前缀缓存更稳，上下文压缩也更可预测。' },
  { icon: 'key', title: 'BYOK，Key 不出手机', desc: 'API Key 只存本地安全存储、只出现在请求头里，不进日志。任务随时可中断，也可以排队后再发。' },
  { icon: 'code', title: '纯 Dart 内核 + Flutter 前端', desc: 'backend/ 是纯 Dart 包，269 项单测不依赖 Flutter 与 Android；设备能力由 Kotlin 桥提供，界面层是 Flutter。' },
]

const STEPS = [
  {
    key: 'workspace', label: '加工作区', shot: '/Heracles/shots/empty.webp', title: '先把项目放进来',
    body: '侧边栏「选择文件夹」用系统选择器授权项目目录，或使用不受限的默认工作区。授权之后它读到的是你真实的工程文件，不是上传到云端的副本。',
    points: ['SAF 授权，不复制项目', '支持 /sdcard 上的既有工程', '工作区之间互不串台'],
  },
  {
    key: 'talk', label: '说明需求', shot: '/Heracles/shots/chat.webp', title: '像跟人说话一样描述任务',
    body: '说清要改什么，它自己决定调哪些工具。每次调用都是一张可展开的卡片：读了哪个文件、改了哪几行、命令输出是什么，都留在会话里可回查。',
    points: ['工具调用可展开核对', '改文件给出行级 diff', '随时中断、排队发送'],
  },
  {
    key: 'model', label: '配模型', shot: '/Heracles/shots/modelsheet.webp', title: '模型与思考档位随时切',
    body: '多家提供商并存，默认用哪个一目了然。思考档位与最大轮次在同一个抽屉里，切换只对新消息生效，不会打断正在跑的任务。',
    points: ['OpenAI 兼容 / Anthropic / Responses', '思考档位按协议自适应', '最大轮次可限制花费'],
  },
  {
    key: 'build', label: '在手机上出包', shot: '/Heracles/shots/perms.webp', title: '权限与构建都在本机完成',
    body: '设备权限一页看清六项状态与当前执行路由；工具链就绪后即可在手机上完成构建、对齐与签名。手机过热会主动暂停，而不是把任务跑崩。',
    points: ['六项权限与路由诊断', '进程内对齐并自校验', '温度熔断保护'],
  },
]

const GALLERY = [
  { src: '/Heracles/shots/empty.webp', title: '空态' },
  { src: '/Heracles/shots/chat.webp', title: '会话与 diff' },
  { src: '/Heracles/shots/modelsheet.webp', title: '模型与思考' },
  { src: '/Heracles/shots/perms.webp', title: '设备权限' },
  { src: '/Heracles/shots/settings.webp', title: '设置·通用' },
  { src: '/Heracles/shots/home.webp', title: '设置首页' },
  { src: '/Heracles/shots/model.webp', title: '设置·模型' },
  { src: '/Heracles/shots/appearance.webp', title: '设置·外观' },
  { src: '/Heracles/shots/memory.webp', title: '全局记忆' },
]

const WORKS = ['会话与守卫（在途结果不串台）', '审批门禁（允许 / 需确认 / 拒绝）', '取消、排队发送、上下文压缩',
  '设备权限六项总览', '真机宽度下无溢出条纹', '内核 269 项 Dart 单测']
const LIMITS = ['线上字段的真 Key 验证', 'Anthropic / Responses 两条协议轨', '图片多模态',
  '在 SAF 工作区内构建', '多机型覆盖', '正式发布签名']

function Reveal({ children, delay = 0, y = 22, className = '' }) {
  const reduce = useReducedMotion()
  return (
    <motion.div className={className}
      initial={reduce ? false : { opacity: 0, y }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: '-80px' }}
      transition={{ duration: 0.6, delay, ease: [0.22, 1, 0.36, 1] }}>
      {children}
    </motion.div>
  )
}

function Nav() {
  return (
    <header className="nav">
      <a className="brand" href="#top">
        <img src="/Heracles/logo.png" alt="" />
        <span>Heracles</span>
      </a>
      <nav className="nav-links">
        <a href="#how">怎么工作</a>
        <a href="#features">特性</a>
        <a href="#shots">界面</a>
        <a href="#status">状态</a>
      </nav>
      <a className="btn btn-primary btn-sm" href={APK} download>免费下载</a>
    </header>
  )
}

function Hero() {
  const reduce = useReducedMotion()
  return (
    <section className="hero" id="top">
      <div className="hero-bg" />
      <div className="hero-inner">
        <div className="hero-copy">
          <motion.p className="kicker" initial={reduce ? false : { opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }} transition={{ duration: 0.5 }}>
            Android 12+ · arm64 · GPL-3.0
          </motion.p>
          <motion.h1 initial={reduce ? false : { opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.05 }}>
            把手机变成<br />开发机
          </motion.h1>
          <motion.p className="lede" initial={reduce ? false : { opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.12 }}>
            在 Android 手机上的真实工作区里读代码、改文件、跑命令。接上设备侧工具链后，
            还能在这台手机上把工程构建成可安装的 APK。模型走你自己的 API Key，手机上不加载任何模型。
          </motion.p>
          <motion.div className="cta" initial={reduce ? false : { opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.2 }}>
            <a className="btn btn-primary btn-lg" href={APK} download>
              <Icon d={ICONS.download} size={18} /> 下载 v0.2.1（20.9 MB）
            </a>
            <a className="btn btn-ghost btn-lg" href={REPO} target="_blank" rel="noreferrer">
              查看源码 <Icon d={ICONS.arrow} size={18} />
            </a>
          </motion.div>
          <p className="cta-note">点击即开始下载 · 也可以在 <a href={RELEASES} target="_blank" rel="noreferrer">Releases</a> 里挑版本与校验值</p>
        </div>
        <motion.div className="hero-phone" initial={reduce ? false : { opacity: 0, y: 34 }} animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, delay: 0.15 }}>
          <img src="/Heracles/shots/chat.webp" alt="Heracles 会话界面" />
        </motion.div>
      </div>
    </section>
  )
}

function How() {
  const [active, setActive] = useState(0)
  const step = STEPS[active]
  const reduce = useReducedMotion()
  return (
    <section className="section" id="how">
      <Reveal>
        <h2 className="section-title">它是怎么工作的</h2>
        <p className="section-sub">点左边任意一步，右边就是那一步在真机上的样子。</p>
      </Reveal>
      <div className="how">
        <div className="how-tabs" role="tablist" aria-label="工作流程">
          {STEPS.map((s, i) => (
            <button key={s.key} role="tab" aria-selected={i === active}
              className={`how-tab${i === active ? ' on' : ''}`} onClick={() => setActive(i)}>
              <span className="how-num">{String(i + 1).padStart(2, '0')}</span>
              <span>{s.label}</span>
            </button>
          ))}
        </div>
        <div className="how-body">
          <div className="how-text">
            <AnimatePresence mode="wait">
              <motion.div key={step.key}
                initial={reduce ? false : { opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }}
                exit={reduce ? undefined : { opacity: 0, y: -8 }} transition={{ duration: 0.28 }}>
                <h3>{step.title}</h3>
                <p>{step.body}</p>
                <ul>{step.points.map((p) => <li key={p}>{p}</li>)}</ul>
              </motion.div>
            </AnimatePresence>
          </div>
          <div className="how-shot">
            <AnimatePresence mode="wait">
              <motion.img key={step.key} src={step.shot} alt={step.label}
                initial={reduce ? false : { opacity: 0, scale: 0.98 }}
                animate={{ opacity: 1, scale: 1 }} exit={reduce ? undefined : { opacity: 0, scale: 1.01 }}
                transition={{ duration: 0.3 }} />
            </AnimatePresence>
          </div>
        </div>
      </div>
    </section>
  )
}

function Features() {
  return (
    <section className="section" id="features">
      <Reveal>
        <h2 className="section-title">为什么它不只是套壳</h2>
        <p className="section-sub">该硬的地方都硬：工具门禁、会话模型、本机构建。</p>
      </Reveal>
      <div className="cards">
        {FEATURES.map((f, i) => (
          <Reveal key={f.title} delay={i * 0.05} className="card-wrap">
            <div className="card">
              <div className="card-icon"><Icon d={ICONS[f.icon]} /></div>
              <h3>{f.title}</h3>
              <p>{f.desc}</p>
            </div>
          </Reveal>
        ))}
      </div>
    </section>
  )
}

function Shots() {
  const [open, setOpen] = useState(null)
  return (
    <section className="section" id="shots">
      <Reveal>
        <h2 className="section-title">界面</h2>
        <p className="section-sub">真机实拍，已裁掉系统状态栏与手势条。点任意一张放大。</p>
      </Reveal>
      <div className="gallery">
        {GALLERY.map((s) => (
          <button className="gallery-item" key={s.src} onClick={() => setOpen(s)}>
            <img src={s.src} alt={s.title} loading="lazy" />
            <span>{s.title}</span>
          </button>
        ))}
      </div>
      <AnimatePresence>
        {open && (
          <motion.div className="lightbox" onClick={() => setOpen(null)}
            initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
            <motion.img src={open.src} alt={open.title}
              initial={{ scale: 0.96 }} animate={{ scale: 1 }} exit={{ scale: 0.98 }} />
          </motion.div>
        )}
      </AnimatePresence>
    </section>
  )
}

function Status() {
  return (
    <section className="section" id="status">
      <Reveal>
        <h2 className="section-title">能用的，和还不能用的</h2>
        <p className="section-sub">alpha 阶段。左边是跑通过的，右边是还没验证的。</p>
      </Reveal>
      <div className="status-grid">
        <Reveal className="status-card ok">
          <h3>已跑通</h3>
          <ul>{WORKS.map((w) => <li key={w}>{w}</li>)}</ul>
        </Reveal>
        <Reveal delay={0.06} className="status-card todo">
          <h3>尚未验证</h3>
          <ul>{LIMITS.map((w) => <li key={w}>{w}</li>)}</ul>
        </Reveal>
      </div>
    </section>
  )
}

function Download() {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(SHA)
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    } catch (e) { /* 剪贴板不可用时静默 */ }
  }
  return (
    <section className="section" id="download">
      <Reveal>
        <div className="dl">
          <h2>装到手机上试用</h2>
          <p className="dl-sub">release 构建 · 20.9 MB · 包名 com.theohowie.heracles</p>
          <a className="btn btn-primary btn-xl" href={APK} download>
            <Icon d={ICONS.download} size={20} /> 下载 APK
          </a>
          <div className="dl-meta">
            <div><span>版本</span>v0.2.1</div>
            <div><span>系统</span>Android 12+ · arm64</div>
            <div><span>许可</span>GPL-3.0</div>
          </div>
          <div className="dl-sha">
            <span>sha256</span>
            <code>{SHA}</code>
            <button className="copy" onClick={copy}>
              <Icon d={ICONS.copy} size={16} /> {copied ? '已复制' : '复制'}
            </button>
          </div>
          <p className="dl-note">
            release 目前使用 debug 密钥签名，安装时需允许「未知来源」；32 位机型不受支持。
            其它版本与校验值见 <a href={RELEASES} target="_blank" rel="noreferrer">Releases</a>。
          </p>
        </div>
      </Reveal>
    </section>
  )
}

function Footer() {
  return (
    <footer className="footer">
      <div className="foot-inner">
        <div className="foot-brand">
          <img src="/Heracles/logo.png" alt="" />
          <div>
            <strong>Heracles</strong>
            <p>手机上的开发智能体 · GPL-3.0</p>
          </div>
        </div>
        <div className="foot-links">
          <a href={REPO} target="_blank" rel="noreferrer">GitHub</a>
          <a href={GITEE} target="_blank" rel="noreferrer">Gitee</a>
          <a href={RELEASES} target="_blank" rel="noreferrer">Releases</a>
          <a href={`${REPO}/blob/master/LICENSE`} target="_blank" rel="noreferrer">License</a>
          <a href={`${REPO}/blob/master/INTERFACE.md`} target="_blank" rel="noreferrer">接口契约</a>
        </div>
      </div>
      <p className="foot-copy">按「现有状态」提供，不含任何担保 · Copyright © 2026 Theohowie</p>
    </footer>
  )
}

export default function Landing() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <How />
        <Features />
        <Shots />
        <Status />
        <Download />
      </main>
      <Footer />
    </>
  )
}