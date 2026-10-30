import { motion, useReducedMotion, useInView } from 'framer-motion'
import { useRef } from 'react'

/* ---------- 内联 SVG 图标（全站不用 emoji） ---------- */
export const Icon = ({ d, size = 20, className = '', strokeWidth = 1.6 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" className={className}
    stroke="currentColor" strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    {d}
  </svg>
)

export const ICONS = {
  folder: <><path d="M3 7.5A2.5 2.5 0 0 1 5.5 5h3.2l1.8 2h8A2.5 2.5 0 0 1 21 9.5v7A2.5 2.5 0 0 1 18.5 19h-13A2.5 2.5 0 0 1 3 16.5z" /></>,
  box: <><path d="M21 8 12 3 3 8v8l9 5 9-5z" /><path d="M3 8l9 5 9-5" /><path d="M12 13v8" /></>,
  shield: <><path d="M12 3l7 3v5c0 4.4-3 7.6-7 9-4-1.4-7-4.6-7-9V6z" /><path d="M9.5 12l1.8 1.8 3.4-3.6" /></>,
  link: <><path d="M10 13a5 5 0 0 0 7 0l2-2a5 5 0 0 0-7-7l-1 1" /><path d="M14 11a5 5 0 0 0-7 0l-2 2a5 5 0 0 0 7 7l1-1" /></>,
  key: <><circle cx="8" cy="15" r="4" /><path d="M11 12l8-8" /><path d="M17 6l2 2" /><path d="M15 8l2 2" /></>,
  code: <><path d="M9 8l-4 4 4 4" /><path d="M15 8l4 4-4 4" /></>,
  download: <><path d="M12 4v10" /><path d="M8 10l4 4 4-4" /><path d="M5 18h14" /></>,
  arrow: <><path d="M5 12h13" /><path d="M13 6l6 6-6 6" /></>,
  arrowDown: <><path d="M12 5v13" /><path d="M6 13l6 6 6-6" /></>,
  copy: <><rect x="9" y="9" width="11" height="11" rx="2" /><path d="M15 5H6a2 2 0 0 0-2 2v9" /></>,
  terminal: <><rect x="2.5" y="4" width="19" height="16" rx="2.5" /><path d="M6.5 9l3.5 3-3.5 3" /><path d="M12.5 15h5" /></>,
  eye: <><path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12z" /><circle cx="12" cy="12" r="2.8" /></>,
  mic: <><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5.5 11.5a6.5 6.5 0 0 0 13 0" /><path d="M12 18v3" /></>,
  compass: <><circle cx="12" cy="12" r="9" /><path d="M15.5 8.5l-2 5-5 2 2-5z" /></>,
  play: <><path d="M8 5.5l10 6.5L8 18.5z" /></>,
  pause: <><path d="M9 5v14" /><path d="M15 5v14" /></>,
  prev: <><path d="M15 5l-7 7 7 7" /></>,
  next: <><path d="M9 5l7 7-7 7" /></>,
  check: <><path d="M4.5 12.5l5 5 10-11" /></>,
  cross: <><path d="M6 6l12 12" /><path d="M18 6L6 18" /></>,
  alert: <><path d="M12 4l9 16H3z" /><path d="M12 10v4" /><path d="M12 17.2v.1" /></>,
  external: <><path d="M14 4h6v6" /><path d="M20 4l-9 9" /><path d="M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4" /></>,
  github: <><path d="M9 19c-4 .8-4-2-5.5-2.5M15 21v-3.4c0-1 .3-1.8.9-2.4-3.2-.4-5-1.9-5-5.2 0-1.2.4-2.3 1.1-3-.2-.7-.2-1.6.1-2.4 0 0 1.4.1 3 1.5 1.8-.5 3.6-.5 5.4 0 1.6-1.4 3-1.5 3-1.5.3.8.3 1.7.1 2.4.7.7 1.1 1.8 1.1 3 0 3.3-1.8 4.8-5 5.2.6.6.9 1.5.9 2.6V21" /></>,
  refresh: <><path d="M3.5 12a8.5 8.5 0 0 1 14.6-5.9L21 9" /><path d="M21 4v5h-5" /><path d="M20.5 12a8.5 8.5 0 0 1-14.6 5.9L3 15" /><path d="M3 20v-5h5" /></>,
  dot: <><circle cx="12" cy="12" r="3.2" fill="currentColor" stroke="none" /></>,
}

/* ---------- 手绘笔迹（呼应品牌那个手写 H 标记） ----------
   pathLength 动画 = 一笔画出来的效果；配合 non-scaling-stroke 保证任意尺寸下都是同样粗细。 */
export const HAND = {
  circle: 'M186 26C168 10 120 3 74 6C34 9 8 24 6 47C4 72 34 96 92 103C148 110 200 100 211 78C219 60 205 36 168 20',
  underline: 'M6 12C42 4 96 3 152 6C178 8 200 10 214 12',
  arrow: 'M9 8C24 20 35 33 41 47M41 47l-10-9M41 47l-12-3',
}

export function HandStroke({ kind = 'circle', delay = 0.2, className = '' }) {
  const reduce = useReducedMotion()
  return (
    <svg className={`hand hand--${kind} ${className}`} viewBox="0 0 220 110" fill="none"
      preserveAspectRatio="none" aria-hidden="true">
      <motion.path d={HAND[kind]} stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
        initial={reduce ? { pathLength: 1 } : { pathLength: 0, opacity: 0 }}
        whileInView={{ pathLength: 1, opacity: 1 }}
        viewport={{ once: true, margin: '-60px' }}
        transition={reduce ? { duration: 0 } : { duration: 0.9, delay, ease: [0.65, 0, 0.35, 1], opacity: { duration: 0.12, delay } }} />
    </svg>
  )
}

/* ---------- 进场 ---------- */
export function Reveal({ children, delay = 0, y = 20, className = '', as = 'div', ...rest }) {
  const reduce = useReducedMotion()
  const Comp = motion[as] || motion.div
  return (
    <Comp className={className}
      initial={reduce ? false : { opacity: 0, y }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, margin: '-70px' }}
      transition={{ duration: 0.62, delay, ease: [0.22, 1, 0.36, 1] }}
      {...rest}>
      {children}
    </Comp>
  )
}

/* ---------- 小节标题：mono 索引 + 发丝线 ---------- */
export function SectionHead({ index, eyebrow, title, sub, side }) {
  return (
    <Reveal className="head">
      <div className="head-top">
        <span className="eyebrow">{index && <span className="eyebrow-num">{index}</span>}{eyebrow}</span>
        <span className="head-rule" aria-hidden="true" />
        {side && <span className="head-side">{side}</span>}
      </div>
      <h2 className="h2">{title}</h2>
      {sub && <p className="head-sub">{sub}</p>}
    </Reveal>
  )
}

/* ---------- 需要「已进入视口」才启动的东西 ---------- */
export function useSeen(ref, margin = '-15% 0px') {
  return useInView(ref, { once: true, margin })
}
export function useViewportRef() {
  return useRef(null)
}
