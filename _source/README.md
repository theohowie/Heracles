# 站点源码（`gh-pages` 分支）

这个目录是 **Heracles 落地页的全部源码**。它放在 `gh-pages` 分支里，而不是 `master`。

## 为什么在这里

用户裁定（2026-10-27）：**站点相关的一切文件只允许存在于 `gh-pages` 分支**，
其他分支（`master` / `frontend` / 未来的任何分支）不得包含站点文件。

所以这个分支同时承担两个角色：

| 路径 | 内容 | 谁在用 |
|---|---|---|
| `/`（根目录） | `vite build` 的**产物** | GitHub Pages 直接托管 |
| `/_source/` | 站点**源码**（就是本目录） | 人改站点时进来 |

## 结构

```
gh-pages/
├── index.html          ← 构建产物（自动生成，别手改）
├── assets/             ← 构建产物（只保留 index.html 里引用的那两个文件）
├── shots/  video/  logo.png   ← 构建产物（public/ 的拷贝）
├── .nojekyll           ← 关掉 Jekyll 处理
└── _source/            ← 源码（本目录）
    ├── index.html      ← Vite 入口（源码；meta/og 文案也在这里）
    ├── src/
    │   ├── Landing.jsx ← 页面骨架：导航 / 首屏 / 事实带 / 录屏 / 页脚
    │   ├── data.js     ← 全部内容与常量（文案改这里）
    │   ├── ui.jsx      ← 图标、手绘笔迹、Reveal、SectionHead
    │   ├── main.css    ← 设计令牌 + 全部样式
    │   ├── main.jsx
    │   └── parts/      ← Transcript（会话回放）/ Journey / Bento / Reel / Ledger / Download
    ├── public/         ← 静态资源（logo、截图）
    ├── vite.config.js  ← base = '/Heracles/'
    ├── preview.mjs     ← 本地预览静态服务器
    └── package.json  pnpm-lock.yaml
```

## 两条文案纪律（2026-10-30 加）

1. **事实纪律**：`data.js` 里每条产品声明都必须能在仓库里找到依据；
   没被证明的只能写进 `LIMITS`（页面上是「尚未验证」栏）。
   核对过程与证据在 `.dshwork/gh-pages-shots/facts.md`（本机，不入库）。
2. **版本纪律**：可下载的是 **v0.2.2**（2026-10-26 构建），它没有沙箱 / 三作用域记忆 /
   流式语音，而页面描述的是主线。下载区那段「版本对照」就是为这件事写的 ——
   **发新包之后**要一起改：`data.js` 的 `APK / VERSION / APK_SIZE / SHA / SHOT_DATE`、
   下载区对照文案、以及按新包重拍 8 张截图（现在这批是 10-26 的界面）。

## 改站点的流程

```bash
# 1. 拿到本分支
git fetch origin gh-pages
git checkout gh-pages

# 2. 装依赖并改源码
cd _source
pnpm install
pnpm dev            # 开发预览（http://localhost:5173/Heracles/）

# 3. 构建到分支根目录
pnpm build
#    vite.config.js 里已经固定 outDir='..' + emptyOutDir=false；
#    ⚠️ 不要 --emptyOutDir（会连 _source/ 一起删掉）

# 3b. 清掉上一轮的旧 hash 产物（否则 assets/ 会越积越多）
#     只保留根 index.html 里实际引用的那两个文件名：
Get-ChildItem ..\assets -File |
  Where-Object { (Get-Content ..\index.html -Raw) -notmatch [regex]::Escape($_.Name) } |
  Remove-Item -Force

# 4. 提交
cd ..
git add -A
git commit -m "deploy: <改了什么>"
git push origin gh-pages
```

## 本地预览构建产物

```bash
cd _source
node preview.mjs      # http://127.0.0.1:4180/Heracles/
```

`preview.mjs` 直接读 gh-pages 分支根目录（构建产物），只在本地截图时用；正式部署走上面的第 3 步。

## 三条纪律

1. **不要手改根目录的构建产物**（`index.html` / `assets/`）—— 下次 `pnpm build` 会覆盖。
   要改就改 `_source/` 然后重新构建。
2. **不要把站点文件放回 `master`** —— 那是被明确要求禁止的。
3. **改动文案前先看「两条文案纪律」** —— 页面宁可少说，不许说过头。
