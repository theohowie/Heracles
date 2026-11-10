import { Icon, ICONS, Reveal, SectionHead } from '../ui.jsx'
import { CHANGELOG, WORKS, LIMITS, RUNS, VERSION } from '../data.js'

/* 状态台账：把「能用的」和「还没验证的」并排放，谁都不淡化。
   上面两块是「这一版改了什么」与带日期的实测记录 —— 都能回查，不是营销词。 */
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

        <Reveal className="changelog">
          <div className="changelog-head">
            <span className="changelog-badge">
              <Icon d={ICONS.spark} size={14} /> {VERSION} 这一版改了什么
            </span>
            <span className="changelog-count mono">{CHANGELOG.length} 条</span>
          </div>
          <ul className="changelog-list">
            {CHANGELOG.map((c, i) => (
              <li key={c}>
                <span className="changelog-num mono">{String(i + 1).padStart(2, '0')}</span>
                <span>{c}</span>
              </li>
            ))}
          </ul>
        </Reveal>

        <Reveal className="runs">
          <span className="runs-title mono">最近实测</span>
          <ul className="runs-list">
            {RUNS.map((r, i) => (
              <li key={`${r.date}-${i}`} className="run">
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
            <p className="ledger-note">
              每条都有单测或真机证据；真机那部分见上面的「最近实测」。
            </p>
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
