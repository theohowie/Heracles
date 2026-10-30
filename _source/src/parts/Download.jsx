import { useState } from 'react'
import { Icon, ICONS, Reveal } from '../ui.jsx'
import {
  APK_ALT, APK_PRIMARY, APK_ROUTES, APK_VERSION_CODE,
  PKG, RELEASES, RELEASES_GITHUB, VERSION,
} from '../data.js'

/* 下载区做成一张「构建回执」：左边给你装，右边是这次产物的规格与校验值。
   两条线路都是「点一下就开始下载」的直链：默认国内走 Gitee，源站走 GitHub。
   ⚠️ 两边的产物不是同一个文件（Gitee 是 arm64-only、GitHub 是三 ABI 胖包），
      所以体积与 sha256 按线路分别标注，不混着写。 */
export default function Download() {
  const [copied, setCopied] = useState('')
  const copy = async (sha, key) => {
    try {
      await navigator.clipboard.writeText(sha)
      setCopied(key)
      setTimeout(() => setCopied(''), 1600)
    } catch (e) { /* 剪贴板不可用时静默 */ }
  }

  const primary = APK_PRIMARY
  const alt = APK_ALT

  const specs = [
    ['版本', VERSION],
    ['版本码', APK_VERSION_CODE],
    ['体积', `${primary.size} · ${primary.build}`],
    ['包名', PKG],
    ['系统', 'Android 12+ · arm64'],
    ['许可', 'GPL-3.0'],
    ['签名', 'debug 密钥（alpha）'],
  ]

  return (
    <section className="section section--download" id="download">
      <div className="wrap">
        <Reveal className="receipt">
          <div className="receipt-main">
            <span className="receipt-eyebrow mono">GET THE APK</span>
            <h2 className="receipt-title">装到手机上，<br className="br-sm" />今天就让它改一个文件</h2>
            <p className="receipt-lede">
              首个会话只需要三件事：一个 API Key、一个能授权的目录、一句你想改什么。
              聊天模型在云端（BYOK），Key 只存本机、只进请求头。
            </p>

            <div className="cta-row">
              <a className="btn btn--ink btn--lg" href={primary.url} download>
                <Icon d={ICONS.download} size={18} /> 下载 {VERSION}（{primary.size}）
              </a>
              {alt && (
                <a className="btn btn--ghost btn--lg" href={alt.url} download>
                  从 {alt.label} {alt.hint}下载 <Icon d={ICONS.download} size={16} />
                </a>
              )}
            </div>

            <ul className="routes">
              {APK_ROUTES.filter((r) => r.ready).map((r) => (
                <li key={r.key} className={r.key === primary.key ? 'is-primary' : ''}>
                  <span className="route-dot" aria-hidden="true" />
                  <a href={r.url} download>{r.label} {r.hint}</a>
                  <span className="route-meta mono">{r.size} · {r.build}</span>
                  {r.key === primary.key && <span className="route-tag mono">默认</span>}
                </li>
              ))}
              <li className="routes-note">
                两条都是直链：点一下就开始下载，不经过任何中间页。
                国内默认走 Gitee（{primary.size}，arm64-only，推荐）；GitHub 那份是 {alt ? alt.size : '67.5 MiB'} 的三 ABI 胖包，
                多出来的部分是在手机上根本用不到的原生库 —— 用来核对源站或海外镜像时再走它。
              </li>
            </ul>

            <p className="receipt-note">
              使用 debug 密钥签名，安装时需允许「未知来源」；只支持 arm64 机型。
            </p>

            <div className="receipt-warn">
              <span className="warn-k mono">两个包不是同一个文件</span>
              <p>
                Gitee 那份只保留 arm64 原生库（{primary.size}，sha 见右侧）；GitHub 源站那份是三 ABI 胖包（{alt ? alt.size : '67.5 MiB'}）。
                内容不同、校验值也不同，所以按你要下的那条线路对 sha256。
              </p>
            </div>
          </div>

          <div className="receipt-spec">
            <span className="spec-title mono">BUILD MANIFEST</span>
            <dl className="spec-table">
              {specs.map(([k, v]) => (
                <div className="spec-row" key={k}>
                  <dt>{k}</dt>
                  <dd className={k === '包名' || k === '版本码' ? 'mono' : ''}>{v}</dd>
                </div>
              ))}
            </dl>

            <div className="spec-links">
              <a className="spec-link" href={RELEASES} target="_blank" rel="noreferrer">
                全部版本（Gitee） <Icon d={ICONS.external} size={13} />
              </a>
              <a className="spec-link" href={RELEASES_GITHUB} target="_blank" rel="noreferrer">
                GitHub Release <Icon d={ICONS.external} size={13} />
              </a>
            </div>

            <div className="sha">
              <span className="sha-k mono">sha256 · {primary.label}</span>
              <button type="button" className="copy-btn" onClick={() => copy(primary.sha, primary.key)}>
                <Icon d={ICONS.copy} size={14} /> {copied === primary.key ? '已复制' : '复制'}
              </button>
              <code className="sha-v">
                <span>{primary.sha.slice(0, 32)}</span>
                <span>{primary.sha.slice(32)}</span>
              </code>
            </div>

            {alt && (
              <div className="sha sha--alt">
                <span className="sha-k mono">sha256 · {alt.label}</span>
                <button type="button" className="copy-btn" onClick={() => copy(alt.sha, alt.key)}>
                  <Icon d={ICONS.copy} size={14} /> {copied === alt.key ? '已复制' : '复制'}
                </button>
                <code className="sha-v">
                  <span>{alt.sha.slice(0, 32)}</span>
                  <span>{alt.sha.slice(32)}</span>
                </code>
              </div>
            )}
          </div>
        </Reveal>
      </div>
    </section>
  )
}
