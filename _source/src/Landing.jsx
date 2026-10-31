import { useEffect, useRef, useState } from 'react'
import { motion, useInView, useReducedMotion, useScroll, useSpring } from 'framer-motion'
import { Icon, ICONS, HandStroke, Reveal, SectionHead } from './ui.jsx'
import { APK, APK_PRIMARY, APK_SIZE, BAND, GITEE, HERO_SPECS, REPO, RELEASES, SHOT, SHOT_DATE, VERSION, VIDEOS } from './data.js'
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
      <img src="/Heracles/logo-96.png" alt="" width="30" height="30" />
      <span className="brand-name">Heracles</span>
    </a>
  )
}

function Nav() {
  const { scrollYProgress } = useScroll()
  const bar = useSpring(scrollYProgress, { stiffness: 180, damping: 30, restDelta: 0.001 })
  const [solid, setSolid] = useState(false)
  const [active, setActive] = useState('')
  const [menu, setMenu] = useState(false)

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

  // 移动端目录：Esc 关掉，滚出视口也关掉
  useEffect(() => {
    if (!menu) return undefined
    const onKey = (e) => { if (e.key === 'Escape') setMenu(false) }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [menu])

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
          <button type="button" className="nav-menu-btn"
            aria-expanded={menu} aria-controls="nav-menu"
            aria-label={menu ? '收起目录' : '打开目录'}
            onClick={() => setMenu((v) => !v)}>
            <Icon d={menu ? ICONS.cross : ICONS.menu} size={18} />
          </button>
        </div>
      </div>
      {menu && (
        <div className="nav-menu" id="nav-menu">
          {NAV.map((n) => (
            <a key={n.href} href={n.href} onClick={() => setMenu(false)}>{n.label}</a>
          ))}
          <a href="#download" onClick={() => setMenu(false)}>下载 APK</a>
        </div>
      )}
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
            <span className="sep">·</span>
            下载走 {APK_PRIMARY.label} {APK_PRIMARY.hint}
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
              <img src={SHOT('hero-v3')} width="560" height="1216"
                alt="Heracles 真机界面：会话里灵动岛显示 5/5 步骤，下面是一条工具卡与 +340/−180 的改动摘要，顶栏显示缓存命中 95%" />
            </div>
            <span className="annot annot--top" aria-hidden="true">
              <span className="annot-text mono">1080 × 2400</span>
              <span className="annot-line" />
            </span>
            <figcaption className="device-cap mono">
              <span className="live-dot" aria-hidden="true" />
              真机实拍 {SHOT_DATE} · 命中 95%
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
  const ref = useRef(null)
  // 视频要进到视口才挂 src（压到 376 KB 了，但仍然不该和首屏抢带宽）
  const near = useInView(ref, { once: true, margin: '0px' })
  const [srcIdx, setSrcIdx] = useState(0)
  const [failed, setFailed] = useState(false)
  return (
    <section className="section section--film" id="film" ref={ref}>
      <div className="wrap">
        <div className="film-head">
          <span className="eyebrow"><span className="eyebrow-num">15s</span>真机录屏</span>
          <p className="film-note mono">
            无声循环 ·
            <a href={VIDEOS.full[0]} target="_blank" rel="noreferrer">看完整 30 秒版本</a>
          </p>
        </div>
        <Reveal className="film">
          <video
            key={`${near}-${srcIdx}`}
            src={near && !failed ? VIDEOS.hero[srcIdx] : undefined}
            poster={SHOT('film-poster')}
            autoPlay={!reduce} muted loop playsInline preload="none"
            aria-label="Heracles 真机操作录屏（无声，15 秒循环）"
            onError={() => {
              // 源挂了就换下一个；全挂了就露出「重试 / 打开原片」的兜底
              if (srcIdx + 1 < VIDEOS.hero.length) setSrcIdx(srcIdx + 1)
              else setFailed(true)
            }}
            onStalled={() => { if (near && srcIdx + 1 < VIDEOS.hero.length) setSrcIdx(srcIdx + 1) }}
          />
          {failed && (
            <div className="film-fallback">
              <span className="mono">录屏没加载出来（可能是网络）</span>
              <button type="button" className="btn btn--ghost btn--xs"
                onClick={() => { setFailed(false); setSrcIdx(0) }}>重试</button>
              <a className="btn btn--ghost btn--xs" href={VIDEOS.full[0]} target="_blank" rel="noreferrer">打开原片</a>
            </div>
          )}
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
          <img src="/Heracles/logo-96.png" alt="" width="34" height="34" />
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
      <main id="main" tabIndex={-1}>
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
