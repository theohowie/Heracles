import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useInView, useReducedMotion } from 'framer-motion'
import { Icon, ICONS } from '../ui.jsx'
import { SESSION, SESSION_NOTES } from '../data.js'

/* ============================================================
   一次任务的回放。
   整段流水一开始就摆在这里（高度稳定、不跳），播放只做一件事：
   把「读到哪了」往下推一格 —— 未来的条目压暗，当前那条提亮。
   走到门禁那一步会停下来等你选允许 / 拒绝，两条分支都写完整。
   面板上明确标注「示例回放 · 非录屏」，不冒充录屏证据。
   ============================================================ */

const DWELL = { you: 1500, plan: 1900, tool: 1400, patch: 1700, gate: 500, deny: 1600, done: 2200 }

function You({ ev }) {
  return (
    <div className="ev ev--you">
      <div className="ev-role"><span className="ev-who">你</span><span className="ev-time">{ev.time}</span></div>
      <p className="ev-say">{ev.text}</p>
    </div>
  )
}

function Plan({ ev }) {
  return (
    <div className="ev ev--plan">
      <div className="ev-role">
        <span className="ev-who"><Icon d={ICONS.dot} size={10} /> 计划</span>
        <span className="ev-time">{ev.note}</span>
      </div>
      <ol className="plan-steps">
        {ev.steps.map((s, i) => (
          <li key={s}><span className="plan-num">{String(i + 1).padStart(2, '0')}</span>{s}</li>
        ))}
      </ol>
    </div>
  )
}

function Tool({ ev }) {
  return (
    <div className="ev ev--tool">
      <div className="tool-head">
        <span className="tool-name">{ev.tool}</span>
        <code className="tool-arg">{ev.arg}</code>
        <span className="tool-meta">{ev.meta}</span>
      </div>
      {ev.surface && <div className="tool-sub">{ev.surface}</div>}
      {ev.result && <pre className="tool-out">{ev.result.join('\n')}</pre>}
    </div>
  )
}

function Patch({ ev }) {
  return (
    <div className="ev ev--patch">
      <div className="tool-head">
        <span className="tool-name">{ev.tool}</span>
        <code className="tool-arg">{ev.arg}</code>
        <span className="patch-stat">{ev.stat}</span>
      </div>
      <pre className="diff">
        {ev.diff.map((l, i) => (
          <span key={i} className={`diff-line diff-${l.t}`}>
            <span className="diff-sign">{l.t === 'add' ? '+' : l.t === 'del' ? '−' : ' '}</span>{l.s.replace(/^[-+] /, '')}
          </span>
        ))}
      </pre>
    </div>
  )
}

function Gate({ ev, decision, live, onDecide }) {
  return (
    <div className={`ev ev--gate${decision ? ' is-done' : ''}`}>
      <div className="gate-head">
        <span className="gate-badge"><Icon d={ICONS.alert} size={13} /> 需要确认</span>
        <span className="tool-name">{ev.tool}</span>
        <code className="tool-arg">{ev.cmd}</code>
      </div>
      <p className="gate-reason">{ev.reason}</p>
      {decision ? (
        <p className={`gate-result gate-result--${decision}`}>
          <Icon d={decision === 'allow' ? ICONS.check : ICONS.cross} size={13} />
          {decision === 'allow' ? '已允许一次 —— 命令执行' : '已拒绝 —— 命令没有执行'}
        </p>
      ) : (
        <div className="gate-actions">
          <button type="button" className="btn btn--ink btn--xs" onClick={() => onDecide('allow')} disabled={!live}>允许一次</button>
          <button type="button" className="btn btn--ghost btn--xs" onClick={() => onDecide('deny')} disabled={!live}>拒绝</button>
          <span className="gate-hint">{live ? '换成你的话，会怎么选？' : '等前面的步骤走完再决定'}</span>
        </div>
      )}
    </div>
  )
}

function Note({ ev }) {
  return (
    <div className={`ev ev--${ev.kind}`}>
      <p className="note-title">{ev.title}</p>
      <p className="note-body">{ev.body}</p>
      {ev.stat && <p className="note-stat">{ev.stat}</p>}
    </div>
  )
}

export default function Transcript() {
  const reduce = useReducedMotion()
  const boxRef = useRef(null)
  const streamRef = useRef(null)
  const inView = useInView(boxRef, { once: true, margin: '-18% 0px' })

  const [decision, setDecision] = useState(null)
  const [pointer, setPointer] = useState(1) // 1-based：指向「当前」那一条
  const [playing, setPlaying] = useState(false)

  // 基础序列 + 门禁后的分支（默认按「允许」搭出整条时间线，选了拒绝再换）
  const timeline = useMemo(() => {
    const out = []
    for (const ev of SESSION.events) {
      out.push(ev)
      if (ev.kind === 'gate') {
        out.push(...ev.branches[decision || 'allow'])
        break
      }
    }
    return out
  }, [decision])

  const gateIndex = useMemo(() => timeline.findIndex((e) => e.kind === 'gate'), [timeline])
  const awaiting = decision === null && pointer - 1 === gateIndex
  const finished = pointer > timeline.length

  useEffect(() => {
    if (!inView) return
    if (reduce) { setDecision('allow'); setPointer(99); setPlaying(false) } else setPlaying(true)
  }, [inView, reduce])

  useEffect(() => {
    if (!playing || awaiting || finished || !inView) return undefined
    const wait = DWELL[timeline[pointer - 1]?.kind] ?? 1500
    const t = setTimeout(() => setPointer((p) => p + 1), wait)
    return () => clearTimeout(t)
  }, [playing, awaiting, finished, pointer, timeline, inView])

  useEffect(() => { if (finished) setPlaying(false) }, [finished])

  // 把「当前」那条滚进视野（面板内部滚动，不带动整页）
  useEffect(() => {
    const box = streamRef.current
    if (!box) return
    const el = box.querySelector('[data-current="true"]')
    if (el) el.scrollIntoView({ block: 'nearest', behavior: reduce ? 'auto' : 'smooth' })
  }, [pointer, reduce])

  const decide = useCallback((d) => {
    setDecision(d)
    setPointer((p) => p + 1)
    setPlaying(true)
  }, [])

  const goto = (n) => {
    const next = Math.max(1, Math.min(n, timeline.length))
    if (decision && next <= gateIndex + 1) setDecision(null)
    setPointer(next)
    setPlaying(false)
  }

  const reset = () => { setDecision(null); setPointer(1); setPlaying(true) }

  const idx = Math.min(pointer, timeline.length)

  return (
    <div className="session" ref={boxRef}>
      <div className="session-head">
        <div className="session-title">
          <span className="session-mark" aria-hidden="true" />
          <strong>{SESSION.title}</strong>
          <span className="session-chips">
            {SESSION.meta.map((m) => <span key={m} className="chip">{m}</span>)}
          </span>
        </div>
        <span className="session-tag">示例回放 · 非录屏</span>
      </div>

      <div className="session-body">
        <div className="stream" ref={streamRef} role="log" aria-live="polite" aria-label="任务回放">
          {timeline.map((ev, i) => {
            const state = reduce ? 'past' : i + 1 < pointer ? 'past' : i + 1 === pointer ? 'current' : 'future'
            return (
              <div key={ev.id} className="ev-wrap" data-current={state === 'current' ? 'true' : undefined}
                data-state={state}>
                {ev.kind === 'you' && <You ev={ev} />}
                {ev.kind === 'plan' && <Plan ev={ev} />}
                {ev.kind === 'tool' && <Tool ev={ev} />}
                {ev.kind === 'patch' && <Patch ev={ev} />}
                {ev.kind === 'gate' && (
                  <Gate ev={ev} decision={decision} live={state === 'current'} onDecide={decide} />
                )}
                {(ev.kind === 'deny' || ev.kind === 'done') && <Note ev={ev} />}
              </div>
            )
          })}
          {(awaiting || (playing && !finished)) && (
            <p className="stream-wait">
              {awaiting ? '等你决定 —— 这期间不会执行任何东西' : '正在往下走…'}
            </p>
          )}
        </div>

        <aside className="session-side" aria-label="这段回放里发生了什么">
          <p className="side-title">这段回放里，你能看见的四件事</p>
          <ol className="side-list">
            {SESSION_NOTES.map((n) => (
              <li key={n.n}>
                <span className="side-num">{n.n}</span>
                <div><strong>{n.k}</strong><p>{n.v}</p></div>
              </li>
            ))}
          </ol>
        </aside>
      </div>

      <div className="session-foot">
        <div className="statusline">
          <span className="dot-live" aria-hidden="true" />
          <span>append-only</span>
          <span className="sep">·</span>
          <span>{idx}/{timeline.length} 事件</span>
          <span className="sep">·</span>
          <span>缓存命中 94%（示例值）</span>
        </div>
        <div className="transport">
          <button type="button" className="tbtn" onClick={() => goto(pointer - 1)} aria-label="上一步" disabled={pointer <= 1}>
            <Icon d={ICONS.prev} size={15} />
          </button>
          <button type="button" className="tbtn tbtn--main"
            onClick={() => (finished ? reset() : setPlaying((p) => !p))}
            aria-label={finished ? '重新播放' : playing ? '暂停' : '继续播放'} disabled={awaiting}>
            <Icon d={finished ? ICONS.refresh : playing ? ICONS.pause : ICONS.play} size={15} />
            <span>{finished ? '重播' : playing ? '暂停' : '播放'}</span>
          </button>
          <button type="button" className="tbtn" onClick={() => goto(pointer + 1)} aria-label="下一步"
            disabled={finished || awaiting}>
            <Icon d={ICONS.next} size={15} />
          </button>
        </div>
      </div>
    </div>
  )
}
