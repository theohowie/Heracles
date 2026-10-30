import { Icon, ICONS, Reveal, SectionHead } from '../ui.jsx'
import { WORKS, LIMITS, RUNS } from '../data.js'

/* 状态台账：把「能用的」和「还没验证的」并排放，谁都不淡化。
   上面那条是带日期的实测记录 —— 能回查台账，不是营销词。 */
export default function Ledger() {
  return (
    <section className="section section--ledger" id="status">
      <div className="wrap">
        <SectionHead
          index="05" eyebrow="状态"
          title="能用的，和还不能用的"
          sub="alpha 阶段。左边是已经跑通的，右边是还没验证的 —— 这份清单只会因为实测而变短。"
          side={<span className="mono">{WORKS.length} 通过 · {LIMITS.length} 待验</span>}
        />

        <Reveal className="runs">
          <span className="runs-title mono">最近实测</span>
          <ul className="runs-list">
            {RUNS.map((r) => (
              <li key={r.date} className="run">
                <span className="run-date mono">{r.date}</span>
                <span className="run-text">{r.text}</span>
                <span className="run-tag mono">{r.tag}</span>
              </li>
            ))}
          </ul>
        </Reveal>

        <div className="ledger">
          <Reveal className="ledger-card ledger-card--ok">
            <div className="ledger-head">
              <span className="ledger-badge"><Icon d={ICONS.check} size={14} /> 已跑通</span>
              <span className="ledger-count mono">{WORKS.length}</span>
            </div>
            <ul>
              {WORKS.map((w) => (
                <li key={w}><Icon d={ICONS.check} size={14} className="mark-ok" />{w}</li>
              ))}
            </ul>
          </Reveal>

          <Reveal className="ledger-card ledger-card--todo" delay={0.07}>
            <div className="ledger-head">
              <span className="ledger-badge"><Icon d={ICONS.alert} size={14} /> 尚未验证</span>
              <span className="ledger-count mono">{LIMITS.length}</span>
            </div>
            <ul>
              {LIMITS.map((w) => (
                <li key={w}><Icon d={ICONS.alert} size={14} className="mark-todo" />{w}</li>
              ))}
            </ul>
            <p className="ledger-note">
              这一栏不下架商品，只说明「还没被证明」。验证一条，划掉一条。
            </p>
          </Reveal>
        </div>
      </div>
    </section>
  )
}
