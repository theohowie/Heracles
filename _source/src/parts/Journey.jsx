import { useEffect, useRef, useState } from 'react'
import { motion, useInView } from 'framer-motion'
import { Icon, ICONS, SectionHead } from '../ui.jsx'
import { useMotionOff } from '../motion.jsx'
import { STEPS } from '../data.js'

/* 上手路径：真序列（所以有 01–04 编号）。
   桌面端左侧滚动、右侧手机贴在视口里切换；小于 1000px 时每步自带截图。
   截图延后到本节快进入视口才挂 src —— 首屏不该为这 4 张图付流量。 */
export default function Journey() {
  const [active, setActive] = useState(0)
  const listRef = useRef(null)
  const sectionRef = useRef(null)
  const reduce = useMotionOff()
  const near = useInView(sectionRef, { once: true, margin: '300px 0px' })

  useEffect(() => {
    const root = listRef.current
    if (!root) return undefined
    const els = Array.from(root.querySelectorAll('[data-step]'))
    if (!els.length || typeof IntersectionObserver === 'undefined') return undefined
    const io = new IntersectionObserver((entries) => {
      entries.forEach((en) => {
        if (en.isIntersecting) setActive(Number(en.target.getAttribute('data-step')))
      })
    }, { rootMargin: '-48% 0px -48% 0px', threshold: 0 })
    els.forEach((el) => io.observe(el))
    return () => io.disconnect()
  }, [])

  const step = STEPS[active]

  return (
    <section className="section section--journey" id="journey" ref={sectionRef}>
      <div className="wrap">
        <SectionHead
          index="02" eyebrow="上手路径"
          title={<>四步，从空会话到<br className="br-lg" />一次真实改动</>}
          sub="左边是真机上会走的顺序，右边跟着换。每一步都能回退，也都留痕。"
          side={<span className="mono">04 STEPS</span>}
        />

        <div className="journey">
          <div className="journey-list" ref={listRef}>
            {STEPS.map((s, i) => (
              <article className="step" key={s.key} data-step={i} data-active={i === active}>
                <div className="step-top">
                  <span className="step-num">{String(i + 1).padStart(2, '0')}</span>
                  <span className="step-label">{s.label}</span>
                  <span className="step-spec">{s.spec}</span>
                </div>
                <h3 className="step-title">{s.title}</h3>
                <p className="step-body">{s.body}</p>
                <ul className="step-points">
                  {s.points.map((p) => <li key={p}><Icon d={ICONS.check} size={14} />{p}</li>)}
                </ul>
                <figure className="step-shot-inline">
                  {near && <img src={s.shot} alt={`${s.label}：${s.title}`} loading="lazy" />}
                </figure>
              </article>
            ))}
          </div>

          <div className="journey-stage" aria-hidden="true">
            <div className="stage-sticky">
              <div className="phone">
                <div className="phone-frame">
                  {/* 四张图叠在一起做交叉淡入淡出：不卸载，所以滚动时不会闪白 */}
                  {STEPS.map((s, i) => (
                    <motion.img key={s.key} src={near ? s.shot : undefined} alt=""
                      className={`phone-img${i === active ? ' on' : ''}`}
                      animate={reduce ? undefined : { opacity: i === active ? 1 : 0, scale: i === active ? 1 : 0.99 }}
                      initial={false}
                      transition={{ duration: 0.4, ease: [0.22, 1, 0.36, 1] }} />
                  ))}
                </div>
              </div>
              <p className="stage-cap mono">{String(active + 1).padStart(2, '0')} / 04 · {step.label}</p>
              <div className="stage-dots">
                {STEPS.map((s, i) => (
                  <span key={s.key} className={`sdot${i === active ? ' on' : ''}`} />
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
