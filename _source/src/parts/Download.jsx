import { useState } from 'react'
import { Icon, ICONS, Reveal } from '../ui.jsx'
import {
  APK_ALT, APK_PRIMARY, APK_ROUTES, APK_SIZE, APK_VERSION_CODE,
  PKG, RELEASES, SHA, VERSION,
} from '../data.js'

/* 下载区做成一张「构建回执」：左边给你装，右边是这次产物的规格与校验值。
   两条线路都是「点一下就开始下载」的直链：默认国内走 Gitee，源站走 GitHub。 */
export default function Download() {
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(SHA)
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    } catch (e) { /* 剪贴板不可用时静默 */ }
  }

  const specs = [
    ['版本', VERSION],
    ['版本码', APK_VERSION_CODE],
    ['体积', APK_SIZE],
    ['包名', PKG],
    ['系统', 'Android 12+ · arm64'],
    ['许可', 'GPL-3.0'],
    ['签名', 'debug 密钥（alpha）'],
  ]

  const primary = APK_PRIMARY
  const alt = APK_ALT
  const primaryIsGitee = primary.key === 'gitee'

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
                <Icon d={ICONS.download} size={18} /> 下载 {VERSION}（{APK_SIZE}）
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
                  {r.key === primary.key && <span className="route-tag mono">默认</span>}
                </li>
              ))}
              <li className="routes-note">
                两条都是直链：点一下就开始下载，不经过任何中间页。
                {primaryIsGitee ? '国内默认走 Gitee，海外或想核对源站就走 GitHub。' : 'Gitee 国内线路附件上传中，上线后主按钮会自动切过去。'}
              </li>
            </ul>

            <p className="receipt-note">
              使用 debug 密钥签名，安装时需允许「未知来源」；只支持 arm64 机型。
            </p>

            <div className="receipt-warn">
              <span className="warn-k mono">为什么有 67.5 MiB</span>
              <p>
                包内三套原生库（armeabi-v7a / arm64-v8a / x86_64）来自第三方插件，其中
                v7a 与 x86_64 目录缺 Flutter 引擎、在那两个 ABI 上跑不起来 —— 约 20 MiB 是死重。
                安装时系统只会取 arm64，实际占用小于下载体积；更小的 arm64-only 包在评估中。
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
            <a className="spec-link" href={RELEASES} target="_blank" rel="noreferrer">
              全部版本与 Release 说明 <Icon d={ICONS.external} size={13} />
            </a>
            <div className="sha">
              <span className="sha-k mono">sha256</span>
              <button type="button" className="copy-btn" onClick={copy}>
                <Icon d={ICONS.copy} size={14} /> {copied ? '已复制' : '复制'}
              </button>
              <code className="sha-v">
                <span>{SHA.slice(0, 32)}</span>
                <span>{SHA.slice(32)}</span>
              </code>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  )
}
