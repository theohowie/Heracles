import { useCallback, useEffect, useRef, useState } from 'react'
import { AnimatePresence, motion, useReducedMotion } from 'framer-motion'
import { Icon, ICONS, Reveal, SectionHead } from '../ui.jsx'
import { GALLERY, SHOT_DATE, VERSION } from '../data.js'

/* 界面：左边一张大图，右边标题/说明 + 缩略图轨 + 箭头。
   自动轮播会在悬停、聚焦、开灯箱、减少动效时停下。 */
export default function Reel() {
  const [i, setI] = useState(0)
  const [open, setOpen] = useState(false)
  const [paused, setPaused] = useState(false)
  const reduce = useReducedMotion()
  const count = GALLERY.length
  const shot = GALLERY[i]
  const stageRef = useRef(null)

  const go = useCallback((d) => setI((v) => (v + d + count) % count), [count])

  useEffect(() => {
    if (paused || open || reduce) return undefined
    const t = setInterval(() => setI((v) => (v + 1) % count), 5600)
    return () => clearInterval(t)
  }, [paused, open, reduce, count])

  useEffect(() => {
    if (!open) return undefined
    const onKey = (e) => {
      if (e.key === 'Escape') setOpen(false)
      if (e.key === 'ArrowRight') go(1)
      if (e.key === 'ArrowLeft') go(-1)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, go])

  return (
    <section className="section section--reel" id="reel">
      <div className="wrap">
        <SectionHead
          index="04" eyebrow="界面"
          title="黑白，Cupertino 化，长在手机上"
          sub="真机实拍，已裁掉系统状态栏。点大图看原尺寸，左右箭头切换。"
          side={<span className="mono">{String(i + 1).padStart(2, '0')} / {String(count).padStart(2, '0')}</span>}
        />

        <Reveal className="reel" onMouseEnter={() => setPaused(true)} onMouseLeave={() => setPaused(false)}>
          <div className="reel-stage" ref={stageRef} onFocus={() => setPaused(true)} onBlur={() => setPaused(false)}>
            <button type="button" className="reel-shot" onClick={() => setOpen(true)} aria-label={`放大查看：${shot.title}`}>
              <AnimatePresence mode="wait" initial={false}>
                <motion.img key={shot.src} src={shot.src} alt={`${shot.title}：${shot.desc}`}
                  loading="lazy"
                  initial={reduce ? false : { opacity: 0, scale: 0.99 }}
                  animate={{ opacity: 1, scale: 1 }}
                  exit={reduce ? undefined : { opacity: 0 }}
                  transition={{ duration: 0.3, ease: [0.22, 1, 0.36, 1] }} />
              </AnimatePresence>
              <span className="shot-hint"><Icon d={ICONS.eye} size={14} /> 看原尺寸</span>
            </button>
          </div>

          <div className="reel-side">
            <div className="reel-nav">
              <button type="button" className="tbtn" onClick={() => go(-1)} aria-label="上一张">
                <Icon d={ICONS.prev} size={16} />
              </button>
              <button type="button" className="tbtn" onClick={() => go(1)} aria-label="下一张">
                <Icon d={ICONS.next} size={16} />
              </button>
              <span className="reel-auto mono">{paused ? '已暂停轮播' : reduce ? '自动轮播已关闭' : '自动轮播中'}</span>
            </div>

            <AnimatePresence mode="wait" initial={false}>
              <motion.div key={shot.title} className="reel-copy"
                initial={reduce ? false : { opacity: 0, y: 8 }}
                animate={{ opacity: 1, y: 0 }}
                exit={reduce ? undefined : { opacity: 0, y: -6 }}
                transition={{ duration: 0.24 }}>
                <h3>{shot.title}</h3>
                <p>{shot.desc}</p>
                <span className="reel-spec mono">{shot.spec}</span>
              </motion.div>
            </AnimatePresence>

            <div className="thumbs" role="tablist" aria-label="界面截图">
              {GALLERY.map((g, n) => (
                <button type="button" key={g.src} role="tab" aria-selected={n === i}
                  className={`thumb${n === i ? ' on' : ''}`} onClick={() => setI(n)} title={g.title}>
                  <img src={g.src} alt="" loading="lazy" />
                  <span className="thumb-name">{g.title}</span>
                </button>
              ))}
            </div>

            <p className="reel-note mono">
              截图取自 {VERSION}（{SHOT_DATE} 前后真机）；主线界面仍在迭代。
            </p>
          </div>
        </Reveal>
      </div>

      <AnimatePresence>
        {open && (
          <motion.div className="lightbox" onClick={() => setOpen(false)}
            initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.22 }}>
            <motion.figure onClick={(e) => e.stopPropagation()}
              initial={reduce ? false : { scale: 0.96, y: 10 }} animate={{ scale: 1, y: 0 }} exit={{ scale: 0.97 }}
              transition={{ type: 'spring', stiffness: 220, damping: 26 }}>
              <img src={shot.src} alt={`${shot.title}：${shot.desc}`} />
              <figcaption>
                <strong>{shot.title}</strong>
                <span>{shot.desc}</span>
                <span className="mono">← → 切换 · Esc 关闭</span>
              </figcaption>
            </motion.figure>
            <button type="button" className="lightbox-x" onClick={() => setOpen(false)} aria-label="关闭">
              <Icon d={ICONS.cross} size={18} />
            </button>
          </motion.div>
        )}
      </AnimatePresence>
    </section>
  )
}
