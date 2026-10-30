import { useEffect, useState } from 'react'
import { motion, useReducedMotion, useScroll, useSpring } from 'framer-motion'
import { Icon, ICONS, HandStroke, Reveal, SectionHead } from './ui.jsx'
import { APK, APK_SIZE, BAND, GITEE, HERO_SPECS, REPO, RELEASES, SHOT, SHOT_DATE, VERSION } from './data.js'
import Transcript from './parts/Transcript.jsx'
import Journey from './parts/Journey.jsx'
import Bento from './parts/Bento.jsx'
import Reel from './parts/Reel.jsx'
import Ledger from './parts/Ledger.jsx'
import Download from './parts/Download.jsx'

const NAV = [
  { href: '#session', label: '怎么工作', id: 'session' },
  { href: '#features', label: '特性', id: 'features' },
  { href: '#reel', label: '界面', id: 'reel' },
  { href: '#status', label: '状态', id: 'status' },
]

function Logo() {
  return (
    <a className="brand" href="#top" aria-label="Heracles 首页">
      <img src="/Heracles/logo.png" alt="" width="30" height="30" />
      <span className="brand-name">Heracles</span>
    </a>
  )
}

function Nav() {
  const { scrollYProgress } = useScroll()
  const bar = useSpring(scrollYProgress, { stiffness: 180, damping: 30, restDelta: 0.001 })
  const [solid, setSolid] = useState(false)
  const [active, setActive] = useState('')

  useEffect(() => {
    const onScroll = () => setSolid(window.scrollY > 8)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  // 当前读到哪一节：只用来给导航一个淡淡的「你现在在这」
  useEffect(() => {
    if (typeof IntersectionObserver === 'undefined') return undefined
    const targets = NAV.map((n) => document.getElementById(n.id)).filter(Boolean)
    if (!targets.length) return undefined
    const io = new IntersectionObserver((entries) => {
      entries.forEach((en) => { if (en.isIntersecting) setActive(en.target.id) })
    }, { rootMargin: '-45% 0px -50% 0px', threshold: 0 })
    targets.forEach((t) => io.observe(t))
    return () => io.disconnect()
  }, [])

  return (
    <header className={`nav${solid ? ' is-solid' : ''}`}>
      <div className="nav-inner wrap">
        <Logo />
        <nav className="nav-links" aria-label="页面导航">
          {NAV.map((n) => (
            <a key={n.href} className={`nav-link${active === n.id ? ' on' : ''}`}
              href={n.href} aria-current={active === n.id ? 'true' : undefined}>{n.label}</a>
          ))}
        </nav>
        <div className="nav-right">
          <span className="nav-ver mono">{VERSION}</span>
          <a className="btn btn--ink btn--sm" href="#download">下载 APK</a>
        </div>
      </div>
      <motion.span className="nav-progress" style={{ scaleX: bar }} aria-hidden="true" />
    </header>
  )
}

/* 首屏：左侧一句话立论，右侧是真实的手机界面 + 一处工程标注。
   那个手绘圈是整站唯一的「手写笔迹」，用来把注意力钉在「手机」两个字上。 */
function Hero() {
  const reduce = useReducedMotion()
  return (
    <section className="hero" id="top">
      <div className="hero-grid-bg" aria-hidden="true" />
      <div className="wrap hero-grid">
        <div className="hero-copy">
          <p className="hero-eyebrow mono">
            <span className="live-dot" aria-hidden="true" />
            ANDROID 12+ · ARM64 · GPL-3.0
          </p>
          <h1 className="h1">
            把<span className="mark">手机<HandStroke kind="circle" delay={0.5} /></span>
            <br />变成开发机
          </h1>
          <p className="lede">
            在你的手机上读真实工程、改真实文件、跑真实命令。构建与脚本走内联沙箱，
            真机上已手动编出并签名过 APK —— 一键构建工具还在接线。
            聊天模型在云端（你自己的 API Key），语音识别在设备本地。
          </p>
          <div className="cta-row">
            <a className="btn btn--ink btn--lg" href={APK} download>
              <Icon d={ICONS.download} size={18} /> 下载 {VERSION}（{APK_SIZE}）
            </a>
            <a className="btn btn--ghost btn--lg" href="#session">
              看它干一次活 <Icon d={ICONS.arrowDown} size={17} />
            </a>
          </div>
          <p className="hero-note mono">
            源码在 <a href={REPO} target="_blank" rel="noreferrer">GitHub</a>
            <span className="sep">·</span>
            <a href={GITEE} target="_blank" rel="noreferrer">Gitee</a>
            <span className="sep">·</span>
            <a href={RELEASES} target="_blank" rel="noreferrer">校验值</a>
          </p>

          <ul className="specs">
            {HERO_SPECS.map((s) => (
              <li className="spec" key={s.label}>
                <span className="spec-v mono">{s.value}<em>{s.unit}</em></span>
                <span className="spec-l">{s.label}</span>
                <span className="spec-n mono">{s.note}</span>
              </li>
            ))}
          </ul>
        </div>

        <motion.div className="hero-stage"
          initial={reduce ? false : { opacity: 0, y: 26 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.9, delay: 0.18, ease: [0.22, 1, 0.36, 1] }}>
          <figure className="device">
            <div className="device-frame">
              <img src={SHOT('chat-v2')} width="560" height="1156"
                alt="Heracles 真机界面：一个会话里，用户要求跑 date 命令，模型先说明思路，再以工具卡展示执行结果" />
            </div>
            <span className="annot annot--top" aria-hidden="true">
              <span className="annot-text mono">1080 × 2400</span>
              <span className="annot-line" />
            </span>
            <figcaption className="device-cap mono">
              <span className="live-dot" aria-hidden="true" />
              真机实拍 {SHOT_DATE} · 命中 99%
            </figcaption>
          </figure>
        </motion.div>
      </div>
    </section>
  )
}

/* 事实带：四件事，全是机制，不是你夸我我夸你 */
function Band() {
  return (
    <div className="band">
      <div className="wrap band-inner">
        {BAND.map((b) => (
          <div className="band-item" key={b.k}>
            <span className="band-k mono">{b.k}</span>
            <span className="band-v">{b.v}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

function Film() {
  const reduce = useReducedMotion()
  return (
    <section className="section section--film" id="film">
      <div className="wrap">
        <div className="film-head">
          <span className="eyebrow"><span className="eyebrow-num">15s</span>真机录屏</span>
          <p className="film-note mono">
            无声循环 ·
            <a href="/Heracles/video/heracles-30s.mp4" target="_blank" rel="noreferrer">看完整 30 秒版本</a>
          </p>
        </div>
        <Reveal className="film">
          <video src="/Heracles/video/hero-loop.mp4" poster={SHOT('home-v2')}
            autoPlay={!reduce} muted loop playsInline preload="metadata"
            aria-label="Heracles 真机操作录屏（无声，15 秒循环）" />
        </Reveal>
      </div>
    </section>
  )
}

function SessionSection() {
  return (
    <section className="section section--session" id="session">
      <div className="wrap">
        <SectionHead
          index="01" eyebrow="一次任务的全过程"
          title={<>它不会说「我已经改好了」，<br className="br-lg" />它会把每一步摊开给你看</>}
          sub="下面这段是示例回放：读文件、打补丁、过门禁、跑命令，每一步都是产品里真会出现的卡片。门禁那一步由你决定。"
          side={<span className="mono">PLAY / PAUSE</span>}
        />
        <Transcript />
      </div>
    </section>
  )
}

function Footer() {
  return (
    <footer className="foot">
      <div className="wrap foot-inner">
        <div className="foot-brand">
          <img src="/Heracles/logo.png" alt="" width="34" height="34" />
          <div>
            <strong>Heracles</strong>
            <p className="mono">手机上的开发智能体 · GPL-3.0</p>
          </div>
        </div>
        <nav className="foot-links" aria-label="相关链接">
          <a href={REPO} target="_blank" rel="noreferrer">GitHub <Icon d={ICONS.external} size={13} /></a>
          <a href={GITEE} target="_blank" rel="noreferrer">Gitee <Icon d={ICONS.external} size={13} /></a>
          <a href={RELEASES} target="_blank" rel="noreferrer">Releases <Icon d={ICONS.external} size={13} /></a>
          <a href={`${REPO}/blob/master/LICENSE`} target="_blank" rel="noreferrer">License <Icon d={ICONS.external} size={13} /></a>
          <a href={`${REPO}/blob/master/docs/INTERFACE.md`} target="_blank" rel="noreferrer">接口契约 <Icon d={ICONS.external} size={13} /></a>
        </nav>
      </div>
      <div className="wrap foot-line">
        <span className="mono">alpha · {VERSION} · 按「现有状态」提供，不含任何担保</span>
        <span className="mono">Copyright © 2026 Theohowie</span>
      </div>
    </footer>
  )
}

export default function Landing() {
  return (
    <div className="page">
      <a className="skip" href="#main">跳到正文</a>
      <Nav />
      <main id="main">
        <Hero />
        <Band />
        <Film />
        <SessionSection />
        <Journey />
        <Bento />
        <Reel />
        <Ledger />
        <Download />
      </main>
      <Footer />
    </div>
  )
}
