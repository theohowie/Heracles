import { useEffect, useRef, useState } from 'react'
import { motion, AnimatePresence, useReducedMotion, useMotionValue, useTransform } from 'framer-motion'

// ⚠️ v0.3.1 APK 已出包（49.7 MB，台账 .dshwork/temp/release-apks/）但 GitHub Release 尚未发布
// —— 在 Release 发出来之前不能切链接，否则下载 404。切换点：APK / 版本文案（Hero 与 Download 两处）。
const APK = 'https://github.com/theohowie/Heracles/releases/download/v0.2.2/Heracles-v0.2.2.apk'
const RELEASES = 'https://github.com/theohowie/Heracles/releases'
const REPO = 'https://github.com/theohowie/Heracles'
const GITEE = 'https://gitee.com/theohowie/heracles'
const SHA = '3530158C4319917419B3307401DD36214F391472578D7B83E4FDDF230765FDD2'

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
  terminal: <><rect x="2.5" y="4" width="19" height="16" rx="2.5" /><path d="M6.5 9l3.5 3-3.5 3" /><path d="M12.5 15h5" /></>,
  eye: <><path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12z" /><circle cx="12" cy="12" r="2.8" /></>,
  mic: <><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0" /><path d="M12 18v3" /></>,
  compass: <><circle cx="12" cy="12" r="9" /><path d="M15.5 8.5l-2 5-5 2 2-5z" /></>,
}

const FEATURES = [
  { icon: 'folder', title: '真实工作区', desc: '用系统文件选择器授权任意目录（含 /sdcard 上的项目）。列目录、读文件、局部补丁、按文件名与按内容搜索，长文件自动分段。' },
  { icon: 'terminal', title: '内联执行沙箱', desc: 'APK 里自带 PRoot + Alpine rootfs：命令在独立的文件系统里跑，产物与半成品都留在里面，可整块回滚。轻量面内置，编译环境按需下载。' },
  { icon: 'box', title: '在这台手机上构建 APK', desc: '工具链就绪后走 aapt2 → javac → d8 → 进程内对齐 → 签名，产出可安装的 APK。不需要 Gradle，也不需要另一台电脑。' },
  { icon: 'shield', title: '抗幻觉靠架构', desc: '工具白名单 + 参数门禁三态（允许 / 需要确认 / 拒绝）+ 解析失败绝不猜：不执行，如实回告。' },
  { icon: 'eye', title: '执行过程看得见', desc: '长任务收进灵动岛：收起是步骤数字轨道，展开是完整待办。该问就问、该批就批，每一次工具调用都留痕可回查。' },
  { icon: 'link', title: '会话严格 append-only', desc: '从不改写历史消息，只往后追加。长会话的代价随轮次几乎不变，云端前缀缓存更稳，上下文压缩也更可预测。' },
  { icon: 'key', title: 'BYOK，Key 不出手机', desc: 'API Key 只存本地安全存储、只出现在请求头里，不进日志。任务随时可中断，也可以排队后再发。' },
  { icon: 'mic', title: '语音与相机输入', desc: 'SenseVoice 本地识别，点一下把字填进输入框；拍照直接进附件，发出去的图片成图留存、可看大图——识别与成像都在手机上完成。' },
  { icon: 'compass', title: 'JEV 决策模式', desc: '纠结「该不该」时问一句：专用决策模型只管是非与置信度，理由由你当前的对话模型像朋友一样补写。云端开箱即用，本地小模型档位可下载；答不上来就直说，绝不编一个答案。' },
  { icon: 'code', title: '纯 Dart 内核 + Flutter 前端', desc: 'backend/ 是纯 Dart 包，379 项单测不依赖 Flutter 与 Android；设备能力由 Kotlin 桥提供，界面层是 Flutter。' },
]

const STEPS = [
  {
    key: 'workspace', label: '加工作区', shot: '/Heracles/shots/empty-v2.webp', title: '先把项目放进来',
    body: '侧边栏「选择文件夹」用系统选择器授权项目目录，或使用不受限的默认工作区。授权之后它读到的是你真实的工程文件，不是上传到云端的副本。',
    points: ['SAF 授权，不复制项目', '支持 /sdcard 上的既有工程', '工作区之间互不串台'],
  },
  {
    key: 'talk', label: '说明需求', shot: '/Heracles/shots/chat-v2.webp', title: '像跟人说话一样描述任务',
    body: '说清要改什么，它自己决定调哪些工具。每次调用都是一张可展开的卡片：读了哪个文件、改了哪几行、命令输出是什么，都留在会话里可回查。',
    points: ['工具调用可展开核对', '改文件给出行级 diff', '语音转写、拍照即附'],
  },
  {
    key: 'model', label: '配模型', shot: '/Heracles/shots/modelsheet-v2.webp', title: '模型与思考档位随时切',
    body: '多家提供商并存，默认用哪个一目了然。思考档位与最大轮次在同一个抽屉里，切换只对新消息生效，不会打断正在跑的任务。',
    points: ['OpenAI 兼容 / Anthropic / Responses', '思考档位按协议自适应', '最大轮次可限制花费'],
  },
  {
    key: 'build', label: '在手机上出包', shot: '/Heracles/shots/perms-v2.webp', title: '权限与构建都在本机完成',
    body: '设备权限一页看清六项状态与当前执行路由；构建与脚本在沙箱 rootfs 里跑，工具链就绪后在手机上完成对齐与签名。手机过热会主动暂停，而不是把任务跑崩。',
    points: ['六项权限与路由诊断', '沙箱环境按需下载', '进程内对齐并自校验', '温度熔断保护'],
  },
]

const GALLERY = [
  { src: '/Heracles/shots/empty-v2.webp', title: '空态', desc: '开口就是任务：一句话起步，五个建议胶囊' },
  { src: '/Heracles/shots/chat-v2.webp', title: '会话与工具调用', desc: '工具卡可展开，改哪几行、跑什么命令都留痕' },
  { src: '/Heracles/shots/generating-v2.webp', title: '生成中', desc: '彩虹光圈 + 停止键，随时打断长任务' },
  { src: '/Heracles/shots/modelsheet-v2.webp', title: '模型与思考', desc: '多家 provider、思考档位、最大轮次一处切换' },
  { src: '/Heracles/shots/perms-v2.webp', title: '设备权限', desc: '六项状态与执行路由，一页看清' },
  { src: '/Heracles/shots/home-v2.webp', title: '设置首页', desc: '通用 / 记忆 / 权限 / 模型 / 外观' },
  { src: '/Heracles/shots/appearance-v2.webp', title: '外观', desc: '深浅与主题、玻璃效果实时预览' },
  { src: '/Heracles/shots/about-v2.webp', title: '关于', desc: '版本、许可与开源信息' },
]

const WORKS = ['会话与守卫（在途结果不串台）', '审批门禁（允许 / 需确认 / 拒绝）', '待办 / 提问 / 审批 / 切档四面板（真机实测）',
  '沙箱执行链路（真机端到端）', '本地语音识别、拍照即附', '取消、排队发送、上下文压缩',
  '设备权限六项总览', '长任务缓存命中 90–96%（真机实测）', '内核 379 项 Dart 单测']
const LIMITS = ['线上字段的真 Key 验证（含 JEV 决策）', 'Anthropic / Responses 两条协议轨', '模型读图（附件已就绪，读图未验）',
  'JEV 本地推理引擎（档位可下载，接入中）', '在 SAF 工作区内构建', '多机型覆盖', '正式发布签名', '三作用域记忆（重构进行中）']

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
            在 Android 手机上的真实工作区里读代码、改文件、跑命令——构建与脚本走内联沙箱。
            接上设备侧工具链后，还能在这台手机上把工程构建成可安装的 APK。模型走你自己的 API Key，手机上不加载任何模型。
          </motion.p>
          <motion.div className="cta" initial={reduce ? false : { opacity: 0, y: 16 }} animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.2 }}>
            <a className="btn btn-primary btn-lg" href={APK} download>
              <Icon d={ICONS.download} size={18} /> 下载 v0.2.2（20.9 MB）
            </a>
            <a className="btn btn-ghost btn-lg" href={REPO} target="_blank" rel="noreferrer">
              查看源码 <Icon d={ICONS.arrow} size={18} />
            </a>
          </motion.div>
          <p className="cta-note">点击即开始下载 · 也可以在 <a href={RELEASES} target="_blank" rel="noreferrer">Releases</a> 里挑版本与校验值</p>
        </div>
        <motion.div className="hero-video" initial={reduce ? false : { opacity: 0, y: 34 }} animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, delay: 0.15 }}>
          <video src="/Heracles/video/hero-loop.mp4" poster="/Heracles/shots/chat-v2.webp"
            autoPlay muted loop playsInline preload="auto" />
          <a className="hero-video-more" href="/Heracles/video/heracles-30s.mp4" target="_blank" rel="noreferrer">
            看完整 30 秒版本
          </a>
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
        <p className="section-sub">该硬的地方都硬：沙箱执行、工具门禁、会话模型、本机构建。</p>
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
  const shots = GALLERY
  const count = shots.length
  const [index, setIndex] = useState(0)
  const [open, setOpen] = useState(null)
  const [paused, setPaused] = useState(false)
  const [cw, setCw] = useState(1180)
  const wrapRef = useRef(null)
  const reduce = useReducedMotion()

  // 容器宽度（决定居中偏移）
  useEffect(() => {
    const el = wrapRef.current
    if (!el) return undefined
    const ro = new ResizeObserver(([e]) => setCw(e.contentRect.width))
    ro.observe(el)
    setCw(el.getBoundingClientRect().width)
    return () => ro.disconnect()
  }, [])

  // 自动轮播（悬停/灯箱时暂停）
  useEffect(() => {
    if (paused || open || reduce) return undefined
    const t = setInterval(() => setIndex((i) => (i + 1) % count), 4200)
    return () => clearInterval(t)
  }, [paused, open, reduce, count])

  const step = (d) => setIndex((i) => (i + d + count) % count)

  // 鼠标 3D 倾斜
  const mx = useMotionValue(0)
  const my = useMotionValue(0)
  const rotY = useTransform(mx, [-0.5, 0.5], [9, -9])
  const rotX = useTransform(my, [-0.5, 0.5], [-7, 7])
  const onMove = (e) => {
    const r = e.currentTarget.getBoundingClientRect()
    mx.set((e.clientX - r.left) / r.width - 0.5)
    my.set((e.clientY - r.top) / r.height - 0.5)
  }
  const onLeave = () => { mx.set(0); my.set(0) }

  const CARD = cw < 700 ? 232 : 300
  const GAP = cw < 700 ? 14 : 24
  const offset = (cw - CARD) / 2 - index * (CARD + GAP)
  const cur = shots[index]

  return (
    <section className="section" id="shots">
      <Reveal>
        <h2 className="section-title">界面</h2>
        <p className="section-sub">真机实拍（已裁掉系统状态栏）。拖动、点箭头或圆点切换，点图看大图。</p>
      </Reveal>

      <div className="carousel" ref={wrapRef}
        onMouseEnter={() => setPaused(true)} onMouseLeave={() => { setPaused(false); onLeave() }}>
        <motion.div className="carousel-track drag" style={{ x: offset }}
          animate={{ x: offset }}
          transition={{ type: 'spring', stiffness: 120, damping: 20, mass: 0.9 }}
          drag="x"
          dragConstraints={{ left: 0, right: 0 }}
          dragElastic={0.12}
          onDragEnd={(e, info) => {
            if (info.offset.x < -60 || info.velocity.x < -400) step(1)
            else if (info.offset.x > 60 || info.velocity.x > 400) step(-1)
          }}>
          {shots.map((s, i) => {
            const active = i === index
            return (
              <motion.button
                key={s.src}
                className={`slide${active ? ' on' : ''}`}
                style={{ width: CARD, marginRight: GAP }}
                onClick={() => (active ? setOpen(s) : setIndex(i))}
                animate={{
                  scale: active ? 1 : 0.86,
                  opacity: active ? 1 : 0.5,
                  filter: active ? 'blur(0px)' : 'blur(1.5px)',
                }}
                transition={{ type: 'spring', stiffness: 160, damping: 22 }}
              >
                {active && !reduce ? (
                  <motion.div className="slide-tilt" onMouseMove={onMove}
                    style={{ rotateY: rotY, rotateX: rotX, transformPerspective: 900 }}>
                    <img src={s.src} alt={s.title} />
                  </motion.div>
                ) : (
                  <div className="slide-tilt"><img src={s.src} alt={s.title} /></div>
                )}
              </motion.button>
            )
          })}
        </motion.div>

        <button className="nav-arrow prev" onClick={() => step(-1)} aria-label="上一张">‹</button>
        <button className="nav-arrow next" onClick={() => step(1)} aria-label="下一张">›</button>
      </div>

      <div className="carousel-caption">
        <AnimatePresence mode="wait">
          <motion.div key={cur.title}
            initial={reduce ? false : { opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            exit={reduce ? undefined : { opacity: 0, y: -8 }}
            transition={{ duration: 0.25 }}>
            <strong>{cur.title}</strong>
            <span>{cur.desc}</span>
          </motion.div>
        </AnimatePresence>
      </div>

      <div className="dots">
        {shots.map((s, i) => (
          <button key={s.src} className={`dot${i === index ? ' on' : ''}`} onClick={() => setIndex(i)} aria-label={s.title} />
        ))}
      </div>

      <AnimatePresence>
        {open && (
          <motion.div className="lightbox" onClick={() => setOpen(null)}
            initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
            <motion.img src={open.src} alt={open.title}
              initial={{ scale: 0.94, y: 12 }} animate={{ scale: 1, y: 0 }} exit={{ scale: 0.96 }}
              transition={{ type: 'spring', stiffness: 200, damping: 24 }} />
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
            <div><span>版本</span>v0.2.2</div>
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
          <a href={`${REPO}/blob/master/docs/INTERFACE.md`} target="_blank" rel="noreferrer">接口契约</a>
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