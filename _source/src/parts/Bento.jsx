import { Icon, ICONS, Reveal, SectionHead } from '../ui.jsx'
import { FEATURES } from '../data.js'

/* 特性：bento 网格。只有旗舰卡是黑底（全站唯一深色卡片），
   抗幻觉卡给一道 ink 描边 —— 卡片形状只用来表达「这四件是硬骨头」。 */
const MOUNT_LOG = [
  ['app-workspace/', '← 默认工作区（App 私有）'],
  ['/opt/ws-real', '← 沙箱里的挂载点'],
  ['cat pubspec.yaml', '✓ 两侧一致'],
]

export default function Bento() {
  return (
    <section className="section section--bento" id="features">
      <div className="wrap">
        <SectionHead
          index="03" eyebrow="它不是套壳"
          title="该硬的地方，一个都没省"
          sub="沙箱执行、工具门禁、会话模型、真实工作区 —— 这四件事决定它能不能真的干活。"
          side={<span className="mono">{FEATURES.length} 项</span>}
        />

        <div className="bento">
          {FEATURES.map((f, i) => (
            <Reveal key={f.title} delay={Math.min(i * 0.035, 0.28)}
              className={`cell s${f.span}${f.tone ? ` tone-${f.tone}` : ''}`}>
              <article className={`bento-card${f.span >= 3 ? ' is-wide' : ''}`}>
                <span className="bento-icon"><Icon d={ICONS[f.icon]} size={20} /></span>
                <h3 className="bento-title">{f.title}</h3>
                <p className="bento-desc">{f.desc}</p>
                {f.tone === 'ink' ? (
                  <pre className="mount-log" aria-hidden="true">
                    {MOUNT_LOG.map(([path, note]) => (
                      <span key={path} className="mount-line">
                        <span className="mount-arrow">→</span> {path}
                        <span className="mount-note">{note}</span>
                      </span>
                    ))}
                  </pre>
                ) : (
                  <p className="bento-spec">{f.spec}</p>
                )}
              </article>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  )
}
