import { useState } from 'react'
import { Icon, ICONS, Reveal } from '../ui.jsx'
import { APK, APK_SIZE, PKG, RELEASES, SHA, SHOT_DATE, VERSION } from '../data.js'

/* 下载区做成一张「构建回执」：左边给你装，右边是这次产物的规格与校验值。 */
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
    ['体积', APK_SIZE],
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
              <a className="btn btn--ink btn--lg" href={APK} download>
                <Icon d={ICONS.download} size={18} /> 下载 {VERSION}（{APK_SIZE}）
              </a>
              <a className="btn btn--ghost btn--lg" href={RELEASES} target="_blank" rel="noreferrer">
                其它版本 <Icon d={ICONS.external} size={16} />
              </a>
            </div>
            <p className="receipt-note">
              使用 debug 密钥签名，安装时需允许「未知来源」；32 位机型不受支持。
            </p>
            <div className="receipt-warn">
              <span className="warn-k mono">版本对照</span>
              <p>
                这个包是 {VERSION}（{SHOT_DATE} 构建）：沙箱、流式语音、三作用域记忆、JEV、git
                都不在里面（工具 21 个，权限页 6 行）。想用这些主线能力，照 README 从源码构建 ——
                其中尚未验证的部分仍待验证。
              </p>
            </div>
          </div>

          <div className="receipt-spec">
            <span className="spec-title mono">BUILD MANIFEST</span>
            <dl className="spec-table">
              {specs.map(([k, v]) => (
                <div className="spec-row" key={k}>
                  <dt>{k}</dt>
                  <dd className={k === '包名' ? 'mono' : ''}>{v}</dd>
                </div>
              ))}
            </dl>
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
