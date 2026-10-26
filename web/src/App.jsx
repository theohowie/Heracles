import { motion, useReducedMotion } from 'framer-motion'

const APK = 'https://github.com/theohowie/Heracles/releases/download/v0.2.0/Heracles-v0.2.0.apk'
const REPO = 'https://github.com/theohowie/Heracles'
const GITEE = 'https://gitee.com/theohowie/heracles'
const RELEASES = 'https://github.com/theohowie/Heracles/releases'
const SHA = 'F9F1E087AEF64D5333E27CDDC8813E51A2F9C4B0886B8A60CA0DAAD85D327DBC'

const SHOTS = [
  { src: '/Heracles/shots/empty.webp', title: '空态', desc: '想做什么，直接说' },
  { src: '/Heracles/shots/chat.webp', title: '会话', desc: '改文件带 diff，工具调用可展开' },
  { src: '/Heracles/shots/modelsheet.webp', title: '模型与思考', desc: '一个抽屉切换模型 / 档位 / 轮次' },
  { src: '/Heracles/shots/perms.webp', title: '设备权限', desc: '六项总览 + 执行路由诊断' },
  { src: '/Heracles/shots/settings.webp', title: '设置·通用', desc: '工作步骤 / 忙时发送 / 最大轮次' },
  { src: '/Heracles/shots/home.webp', title: '设置首页', desc: '通用 / 记忆 / 权限 / 模型 / 外观' },
  { src: '/Heracles/shots/model.webp', title: '设置·模型', desc: '多家提供商，默认一目了然' },
  { src: '/Heracles/shots/appearance.webp', title: '设置·外观', desc: '深浅 / 四套主题 / 玻璃效果' },
  { src: '/Heracles/shots/memory.webp', title: '全局记忆', desc: '偏好与项目约定' },
  { src: '/Heracles/shots/input.webp', title: '输入区', desc: '模型与思考档位胶囊', wide: true },
  { src: '/Heracles/shots/wsmenu.webp', title: '工作区长按', desc: '新建会话 / 从列表移除', wide: true },
]

const FEATURES = [
  { icon: '📁', title: '手机上的真实工作区', desc: 'SAF 授权任意目录（含 /sdcard 上的项目），列目录、读文件、局部补丁、按名与按内容搜索。' },
  { icon: '📦', title: '直接在这台手机上构建 APK', desc: '设备侧工具链就绪后，走 aapt2 → javac → d8 → 进程内对齐 → 签名，不需要 Gradle，也不需要电脑。' },
  { icon: '🛡️', title: '抗幻觉靠架构', desc: '工具白名单 + 参数门禁三态（允许 / 需要确认 / 拒绝）+ 解析失败绝不猜：不执行、如实回告。' },
  { icon: '🔗', title: '会话严格 append-only', desc: '从不改写历史消息，只往后追加；长会话代价随轮次几乎不变，云端前缀缓存更稳。' },
  { icon: '🔑', title: 'BYOK，Key 不出手机', desc: 'API Key 只存本地安全存储、只出现在请求头里，不进日志。任务随时可中断、可排队。' },
  { icon: '🧩', title: '纯 Dart 内核 + Flutter 前端', desc: 'backend/ 是纯 Dart 包（269 项单测），能直接 dart test；设备能力由 Kotlin 桥提供。' },
]

const STEPS = [
  { n: '01', title: '装 APK', desc: '直链下载 20.6 MB，arm64 手机、Android 12+ 即可安装。' },
  { n: '02', title: '配模型', desc: '选协议、填 Base URL 与 API Key、选模型名 —— 建议用支持 function calling 的模型。' },
  { n: '03', title: '加工作区开聊', desc: '侧边栏选文件夹（SAF 授权）或用默认工作区，然后像跟人说话一样描述任务。' },
]

const WORKS = ['会话与守卫', '审批门禁', '取消与排队发送', '设备权限总览', '上下文压缩', '内核 269 项单测']
const LIMITS = ['线上字段的真 Key 验证', 'Anthropic / Responses 两条协议轨', '图片多模态', 'SAF 工作区内构建', '其它机型覆盖', '正式发布签名']

function Reveal({ children, delay = 0, y = 24, className = '' }) {
  const reduce = useReducedMotion()
  return (
    <motion.div
      className={className}
      initial={reduce ? false : { opacity: 0, y }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: '-80px' }}
      transition={{ duration: 0.6, delay, ease: [0.22, 1, 0.36, 1] }}
    >
      {children}
    </motion.div>
  )
}

function Nav() {
  return (
    <header className="nav">
      <a className="nav-brand" href="#top">
        <img src="/Heracles/logo.png" alt="" />
        <span>Heracles</span>
      </a>
      <nav className="nav-links">
        <a href="#features">特性</a>
        <a href="#shots">界面</a>
        <a href="#how">开始</a>
        <a href="#status">状态</a>
      </nav>
      <a className="btn btn-primary btn-sm" href={APK}>下载 APK</a>
    </header>
  )
}

function Hero() {
  const reduce = useReducedMotion()
  return (
    <section className="hero" id="top">
      <div className="blob blob-a" />
      <div className="blob blob-b" />
      <div className="grid-overlay" />
      <div className="hero-inner">
        <div className="hero-copy">
          <motion.div
            className="pill"
            initial={reduce ? false : { opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5 }}
          >
            v0.2.0 · Android 12+ · GPL-3.0
          </motion.div>
          <motion.h1
            initial={reduce ? false : { opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.05 }}
          >
            把手机变成
            <span className="grad">开发机</span>
          </motion.h1>
          <motion.p
            className="lede"
            initial={reduce ? false : { opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.12 }}
          >
            在 Android 手机上的真实工作区里读代码、改文件、跑命令；
            接上设备侧工具链后，还能直接在这台手机上把工程构建成可安装的 APK。
            模型走你自己的 API Key，手机上不加载模型。
          </motion.p>
          <motion.div
            className="cta"
            initial={reduce ? false : { opacity: 0, y: 18 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.2 }}
          >
            <a className="btn btn-primary btn-lg" href={APK}>
              ⬇ 下载 APK · 20.6 MB
            </a>
            <a className="btn btn-ghost btn-lg" href={REPO} target="_blank" rel="noreferrer">
              查看源码
            </a>
          </motion.div>
          <motion.p
            className="cta-note"
            initial={reduce ? false : { opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.8, delay: 0.3 }}
          >
            点击即开始下载 · arm64 · 免费开源 · 也可以在 <a href={RELEASES} target="_blank" rel="noreferrer">Releases</a> 里挑版本
          </motion.p>
        </div>

        <motion.div
          className="hero-phone"
          initial={reduce ? false : { opacity: 0, y: 40, rotate: -2 }}
          animate={{ opacity: 1, y: 0, rotate: 0 }}
          transition={{ duration: 0.9, delay: 0.15, ease: [0.22, 1, 0.36, 1] }}
        >
          <div className="phone-glow" />
          <motion.img
            src="/Heracles/shots/chat.webp"
            alt="Heracles 会话界面"
            animate={reduce ? {} : { y: [0, -14, 0] }}
            transition={{ duration: 6, repeat: Infinity, ease: 'easeInOut' }}
          />
        </motion.div>
      </div>
    </section>
  )
}

function Shots() {
  const reduce = useReducedMotion()
  const row = [...SHOTS, ...SHOTS]
  return (
    <section className="section" id="shots">
      <Reveal>
        <h2 className="section-title">真机界面</h2>
        <p className="section-sub">
          都是真机（Android 17 / arm64）实拍，已裁掉系统状态栏与手势条 —— 不是美化 mockup。
        </p>
      </Reveal>
      <div className={`marquee ${reduce ? 'marquee-static' : ''}`}>
        <div className="marquee-track">
          {row.map((s, i) => (
            <figure className={`shot${s.wide ? ' wide' : ''}`} key={i}>
              <img src={s.src} alt={s.title} loading="lazy" />
              <figcaption>
                <strong>{s.title}</strong>
                <span>{s.desc}</span>
              </figcaption>
            </figure>
          ))}
        </div>
      </div>
    </section>
  )
}

function Features() {
  return (
    <section className="section" id="features">
      <Reveal>
        <h2 className="section-title">它凭什么能用</h2>
        <p className="section-sub">不是"接个大模型套壳"，该硬的地方都硬。</p>
      </Reveal>
      <div className="cards">
        {FEATURES.map((f, i) => (
          <Reveal key={f.title} delay={i * 0.06} className="card-wrap">
            <div className="card">
              <div className="card-icon">{f.icon}</div>
              <h3>{f.title}</h3>
              <p>{f.desc}</p>
            </div>
          </Reveal>
        ))}
      </div>
    </section>
  )
}

function How() {
  return (
    <section className="section" id="how">
      <Reveal>
        <h2 className="section-title">三步用起来</h2>
        <p className="section-sub">五分钟，从装包到跑通第一个任务。</p>
      </Reveal>
      <div className="steps">
        {STEPS.map((s, i) => (
          <Reveal key={s.n} delay={i * 0.1} className="step-wrap">
            <div className="step">
              <div className="step-n">{s.n}</div>
              <h3>{s.title}</h3>
              <p>{s.desc}</p>
            </div>
          </Reveal>
        ))}
      </div>
    </section>
  )
}

function Status() {
  return (
    <section className="section" id="status">
      <Reveal>
        <h2 className="section-title">能用的，和还不能用的</h2>
        <p className="section-sub">alpha 阶段：接口、UI、工具面都还会变。下面如实写。</p>
      </Reveal>
      <div className="status-grid">
        <Reveal className="status-card ok">
          <h3>✅ 已在真机跑通</h3>
          <ul>{WORKS.map((w) => <li key={w}>{w}</li>)}</ul>
        </Reveal>
        <Reveal delay={0.08} className="status-card todo">
          <h3>⬜ 尚未验证</h3>
          <ul>{LIMITS.map((w) => <li key={w}>{w}</li>)}</ul>
        </Reveal>
      </div>
    </section>
  )
}

function Download() {
  const reduce = useReducedMotion()
  return (
    <section className="section" id="download">
      <Reveal>
        <div className="dl">
          <motion.div
            className="dl-glow"
            animate={reduce ? {} : { opacity: [0.35, 0.6, 0.35] }}
            transition={{ duration: 5, repeat: Infinity, ease: 'easeInOut' }}
          />
          <h2>现在就能装在手机上试</h2>
          <p className="dl-sub">release 构建 · 20.6 MB · 包名 com.theohowie.heracles · 版本 0.2.0</p>
          <a className="btn btn-primary btn-xl" href={APK}>⬇ 直接下载 APK</a>
          <div className="dl-meta">
            <div><span>适用</span>arm64 · Android 12+</div>
            <div><span>签名</span>debug keystore（暂）</div>
            <div className="dl-sha"><span>sha256</span><code>{SHA}</code></div>
          </div>
          <p className="dl-verified">
            ✅ 这个包已在一台真机（Android 17 / arm64）上覆盖安装并冒烟：冷启 <strong>825 ms</strong>、
            运行日志无异常、界面无溢出条纹。
          </p>
          <p className="dl-note">
            ⚠️ 这是 alpha 阶段：release 暂用 debug 密钥签名，安装时需允许「未知来源」；
            32 位手机装上也起不来。其它版本见 <a href={RELEASES} target="_blank" rel="noreferrer">Releases</a>。
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
      <p className="foot-copy">按"现有状态"提供，不含任何担保 · Copyright © 2026 Theohowie</p>
    </footer>
  )
}

export default function App() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Shots />
        <Features />
        <How />
        <Status />
        <Download />
      </main>
      <Footer />
    </>
  )
}