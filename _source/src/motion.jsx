import { createContext, useContext, useEffect, useState } from 'react'

/* 动效开关（2026-10-31 用户裁定）
   ----------------------------------------------------------------------------
   站长的要求是「动效要好、要多、要好看」，所以**默认永远开着**：
   不看系统级的 prefers-reduced-motion（那会把轮播、回放、进场动画全关掉，
   用户自己的机器开着「减少动效」时，站点看起来就像坏了）。
   需要关的人可以在导航栏点一下「动效」按钮，选择存 localStorage。 */

const KEY = 'heracles-motion'
const Ctx = createContext({ off: false, toggle: () => {} })

export function MotionProvider({ children }) {
  const [off, setOff] = useState(() => {
    if (typeof window === 'undefined') return false
    try { return window.localStorage.getItem(KEY) === 'off' } catch { return false }
  })

  useEffect(() => {
    document.documentElement.setAttribute('data-motion', off ? 'off' : 'on')
    try { window.localStorage.setItem(KEY, off ? 'off' : 'on') } catch { /* 隐私模式忽略 */ }
  }, [off])

  return (
    <Ctx.Provider value={{ off, toggle: () => setOff((v) => !v) }}>
      {children}
    </Ctx.Provider>
  )
}

/** true = 用户主动关掉了动效（组件里原来叫 reduce，语义一致） */
export const useMotionOff = () => useContext(Ctx).off
export const useMotionToggle = () => {
  const { off, toggle } = useContext(Ctx)
  return { off, toggle }
}
